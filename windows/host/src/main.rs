//! Polter's Windows host: a terminal window, its tabs, its keyboard and its
//! input method, driven by libghostty.
//!
//! Branding: everything user-visible here is **Polter** -- the window classes,
//! the default window title, the log header, the binary name. Internal
//! artifacts keep the upstream Ghostty names (ghostty-internal.dll,
//! ghostty-vt.dll, the C API symbols) so that merging upstream stays cheap.
//! This is the same split macOS already uses. See docs/windows/development.md
//! section 4.2.
//!
//! Four contracts this host must satisfy. **None of them fails loudly**, which
//! is why each one is written down where it is honoured:
//!
//!  1. `CS_OWNDC` on the class of the window a surface is bound to --
//!     `wgl.init()` calls `GetDC` once and holds that HDC for the life of the
//!     GL context. Without a per-window DC that handle comes from a 5-entry
//!     system cache and is not ours to keep. Here that is the *surface* class
//!     (`tabs.rs`), not the frame: one surface, one HWND, for its whole life.
//!  2. Swallow `WM_ERASEBKGND` -- otherwise GDI paints the class background
//!     over the GL back buffer and the result flickers.
//!  3. Push size and DPI -- `ghostty_surface_config_s` has no width/height;
//!     the core hardcodes 800x600 until the host calls `set_size`, and it
//!     never learns about a DPI change unless `set_content_scale` is called.
//!  4. Offer every keystroke to `ITfKeystrokeMgr` **before** dispatching it,
//!     and do not dispatch what it takes. Reversing that order does not fail
//!     -- it just drops the occasional key while typing.
//!
//! Two threads matter. `action_cb` arrives on whichever thread the core is on,
//! so anything that touches windows is queued and run on the main thread; see
//! `tabs.rs`. TSF is apartment-bound to the main thread and is only ever
//! touched from there.

mod ctxmenu;
mod divider;
mod dnd;
mod ffi;
mod keys;
mod hud;
mod keyseq;
mod menu;
mod overlay;
mod palette;
mod plugins;
mod prompt;
mod settings_ui;
mod quick;
mod reopen;
mod session;
mod winid;
mod search;
mod shell;
mod strip;
mod tabs;
mod tsf;

use ffi::*;
use std::cell::RefCell;
use std::ffi::{c_void, CString};
use std::rc::Rc;
use std::sync::atomic::{AtomicPtr, AtomicU32, AtomicU64, Ordering};

use windows::core::{s, w, Interface, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{InvalidateRect, HBRUSH};
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryA};
use windows::Win32::UI::HiDpi::{
    GetDpiForWindow, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::WindowsAndMessaging::*;

// ---------------------------------------------------------------- logging

/// Wall clock, same format the on-screen clock uses, so a screenshot and
/// this log can be lined up against each other directly.
fn now_str() -> String {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!(
        "{:02}:{:02}:{:02}.{:03}",
        t.wHour, t.wMinute, t.wSecond, t.wMilliseconds
    )
}

/// Where the log goes: `POLTER_HOST_LOG` if set, else
/// `polter-host-<pid>.log` next to the exe.
///
/// **The pid is not decoration.** Earlier builds all wrote
/// `C:\\app\\polter-host.log`, so an older host left running on the test
/// machine appended to the same file as a new one -- and a heartbeat from the
/// old process read as proof that the new process's message loop was alive
/// while it was in fact deadlocked before ever reaching it. One file per
/// process makes that mistake impossible to make again.
/// The file whose presence asks for a state dump. Deleted as it is read, so
/// one write produces exactly one dump.
fn dumpstate_path() -> Option<std::path::PathBuf> {
    Some(plugins::user_dir()?.parent()?.join("dumpstate"))
}

fn log_path() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("POLTER_HOST_LOG") {
        return std::path::PathBuf::from(p);
    }
    let name = format!("polter-host-{}.log", std::process::id());
    match std::env::current_exe() {
        Ok(exe) => exe.with_file_name(name),
        Err(_) => std::path::PathBuf::from(name),
    }
}

/// The identity of one binary: SHA-256 prefix, byte size, and mtime.
///
/// **This exists because identity was being checked at the wrong moment.**
/// All day the three of us compared hashes *at the moment of transfer* --
/// and then read logs and screenshots that could not say which binary
/// produced them. A user reported two different behaviours and it turned out
/// he had opened two different snapshots out of seventeen in one directory.
///
/// Printing it here moves "which build is this?" from a recollection to a
/// reading, for us and for anyone who sends us a screenshot.
///
/// SHA-256 comes from `BCryptHash`, which Windows provides -- no new
/// dependency, and no hand-written cryptography. If it fails the line still
/// prints, with the hash marked unavailable: **a build identity that refuses
/// to print because one of its three fields is missing would be worse than
/// one that prints two.**
fn binary_identity(path: &std::path::Path) -> String {
    use windows::Win32::Security::Cryptography::{BCryptHash, BCRYPT_SHA256_ALG_HANDLE};

    let name = path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "?".into());

    let meta = std::fs::metadata(path);
    let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
    let mtime = meta
        .as_ref()
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let sha = match std::fs::read(path) {
        Ok(bytes) => {
            let mut out = [0u8; 32];
            let rc = unsafe { BCryptHash(BCRYPT_SHA256_ALG_HANDLE, None, &bytes, &mut out) };
            if rc.is_ok() {
                out[..8].iter().map(|b| format!("{:02x}", b)).collect()
            } else {
                "unavailable".to_string()
            }
        }
        Err(_) => "unreadable".to_string(),
    };

    format!(
        "{} sha256={} size={} mtime={}",
        name, sha, size, mtime
    )
}

/// Print the identity of everything this process is made of.
///
/// The two DLLs are looked up next to the exe, which is where
/// `LoadLibraryA` finds them: **the same resolution order, so this cannot
/// report a file the process did not load.**
/// The main loop's iteration count, published so another thread can read it.
///
/// The loop keeps its own `ticks` local; this is a copy, written every
/// iteration. **It is deliberately the same number the `[loop]` heartbeat
/// prints**, so the two lines can be compared instead of being two
/// independent stories about the same thing.
static TICKS: AtomicU64 = AtomicU64::new(0);

/// The watchdog's ping, answered by the main window procedure.
///
/// **The counter alone cannot tell the two stalls apart.** A nested modal
/// loop -- someone holding the context menu open, dragging the window -- stops
/// our loop exactly as a deadlock does, and `ticks` freezes identically. But a
/// modal loop is still `GetMessage`/`DispatchMessage`, so a *posted* message
/// is delivered; a thread blocked in a call answers nothing. Reading a number
/// can never separate them. Asking a question can.
static WD_PONG: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Posted by the watchdog to the frame window once per poll.
pub const WM_WD_PING: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 9;

/// A fixed-size line builder that never allocates.
///
/// Exists only for the alarm path below. Anything that reaches for the heap is
/// unusable there; see `alarm` for why.
struct Line {
    b: [u8; Line::CAP],
    n: usize,
    /// Set when something did not fit. **Silent truncation would eat the end
    /// of the line, and the end of the alarm line is where the claim lives.**
    truncated: bool,
}

impl Line {
    /// Buffer size. Tied to the longest line this can build by the test
    /// `alarm_line_fits`, which builds that line with every number at its
    /// widest. **Adding a field to the alarm makes that test fail**, which is
    /// the whole point: the previous version had a comfortable margin and
    /// nothing connecting it to the line it had to hold.
    /// 260 bytes is the widest this line can be (every number at `u64::MAX`);
    /// the rest is room for a phrase to grow before anyone has to think about
    /// it again. **The margin is not the safety here -- `alarm_line_fits` is.**
    const CAP: usize = 320;

    fn new() -> Self {
        Line { b: [0; Line::CAP], n: 0, truncated: false }
    }
    fn s(&mut self, t: &str) {
        for &c in t.as_bytes() {
            if self.n < self.b.len() {
                self.b[self.n] = c;
                self.n += 1;
            } else {
                self.truncated = true;
            }
        }
    }
    fn u(&mut self, mut v: u64) {
        if v == 0 {
            return self.s("0");
        }
        let mut d = [0u8; 20];
        let mut i = 0;
        while v > 0 {
            d[i] = b'0' + (v % 10) as u8;
            v /= 10;
            i += 1;
        }
        while i > 0 {
            i -= 1;
            if self.n < self.b.len() {
                self.b[self.n] = d[i];
                self.n += 1;
            } else {
                self.truncated = true;
            }
        }
    }
    /// Two digits, so a timestamp reads like the ones `log_line` writes.
    fn u2(&mut self, v: u64) {
        if v < 10 {
            self.s("0");
        }
        self.u(v);
    }
}

/// Write one line for the watchdog. **Does no stdout.**
///
/// `log_line` starts with `println!`, which takes Rust's global stdout lock,
/// and the main thread uses the same function. If the main thread is stuck
/// inside a stdout write -- redirected into a pipe whose reader has stopped,
/// which is how this process is run on the test machine -- it holds that lock,
/// and a watchdog that called `log_line` would block on its own `println!`.
/// That is a third meaning for "no `[wd]` lines", and the worst one: the
/// watchdog gagged by the very stall it exists to report.
///
/// ⚠️ **This still allocates** (`format!` at every call site, `now_str`, and
/// the path conversion inside `open`), so it is fine for the healthy cadence
/// and unusable for the alarm. The alarm uses `alarm` below.
fn wd_log(msg: &str) {
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path())
    {
        let _ = writeln!(f, "[{}] {msg}", now_str());
        let _ = f.flush();
    }
}

/// Write the alarm line **without allocating anything**.
///
/// **The path that only runs when something is wrong is the path that gets to
/// be wrong**, and this one had a specific way to be wrong: the alarm fires
/// when the main thread is not running, and one reason a thread stops running
/// is that it holds the process heap lock. Every obvious way to build this
/// line -- `format!`, `now_str`, even `OpenOptions::open` converting the path
/// -- wants the heap. The watchdog would then block in the allocator instead
/// of reporting, and **its silence is exactly how "the watchdog is broken"
/// reads.** So: the handle is opened once while things are healthy and kept,
/// the digits are written by hand, and the timestamp comes from a struct the
/// kernel fills in.
fn alarm(f: &std::fs::File, line: &Line) {
    use std::io::Write as _;
    let _ = (&mut { f }).write_all(&line.b[..line.n]);
}

/// Build the "main thread blocked" line. Allocation-free, and shared with the
/// test that pins it against `Line::CAP`.
fn blocked_line(pid: u64, secs: u64, ticks: u64, seq: u64, pong: u64, tid: u64) -> Line {
    let mut l = Line::new();
    stamp_into(&mut l);
    l.s("[wd] pid=");
    l.u(pid);
    l.s(" MAIN THREAD BLOCKED ");
    l.u(secs);
    l.s("s: ticks frozen at ");
    l.u(ticks);
    l.s(", ping ");
    l.u(seq);
    l.s(" UNANSWERED (last answered ");
    l.u(pong);
    l.s("), tid=");
    l.u(tid);
    l.s(" -- nothing on this line was allocated\n");
    l
}

/// Local time into a `Line`, allocation-free.
fn stamp_into(line: &mut Line) {
    use windows::Win32::System::SystemInformation::GetLocalTime;
    let t = unsafe { GetLocalTime() };
    line.s("[");
    line.u2(t.wHour as u64);
    line.s(":");
    line.u2(t.wMinute as u64);
    line.s(":");
    line.u2(t.wSecond as u64);
    line.s("] ");
}

/// Watch the main thread from a thread that cannot be blocked by it.
///
/// **Why this exists, stated as what the existing probe cannot see.** The
/// `[state]` sentinel in `tabs.rs` reports a lock that was contended for five
/// seconds. That makes it a lock-contention detector, not a liveness detector,
/// and it is blind to three deaths: one somewhere other than the lock, one
/// that dies *holding* the lock, and a single-threaded stall where nothing
/// calls `state()` again -- and that last one is exactly the case in which it
/// can never emit a line.
///
/// ⚠️ **What silence here does and does not mean, in three separate claims,
/// because merging them is how the last version of this comment came to say
/// something false.**
///
///  1. **Measured.** Nothing on this thread writes to stdout, and the alarm
///     branch contains no allocating call. `windows/tools/watchdog-alarm-path.py`
///     checks both and fails its own canaries first, so this is a reading.
///  2. The alarm line is built in a stack buffer with a handle opened in
///     advance. The claim that buys is exactly the one the checker prints,
///     copied rather than restated because restating it is how it grew:
///     `NOT CHECKED: whether that branch can allocate indirectly -- names only`.
///  3. **Unverified.** That the watchdog still speaks while the main thread is
///     stuck inside a stdout write, or is holding the process heap lock, has
///     never been demonstrated. Producing that state on purpose needs a stuck
///     pipe reader we have no reliable way to arrange. **It stays unverified
///     until someone measures it, not until someone finds the argument
///     convincing.**
///
/// Every line carries the pid, because the log path can be pinned with
/// `POLTER_HOST_LOG` and then two processes write one file: two agreeing
/// readings out of one wrong process is a shape that has caught us already.
fn start_watchdog() {
    use windows::Win32::System::Threading::{GetCurrentProcessId, GetCurrentThreadId};
    use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

    const POLL: std::time::Duration = std::time::Duration::from_secs(2);
    // Two polls, so one slow iteration is not called a stall.
    const STALL_AFTER: std::time::Duration = std::time::Duration::from_secs(4);
    const HEARTBEAT: std::time::Duration = std::time::Duration::from_secs(60);

    let main_tid = unsafe { GetCurrentThreadId() };
    let pid = unsafe { GetCurrentProcessId() };

    let spawned = std::thread::Builder::new()
        .name("polter-watchdog".into())
        .spawn(move || {
            let tid = unsafe { GetCurrentThreadId() };
            // Opened here, while the process is healthy, and kept for the life
            // of the thread: the alarm path must not open anything.
            let alarm_file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(log_path())
                .ok();
            if alarm_file.is_none() {
                wd_log("[wd] could not open the alarm handle; the BLOCKED line \
                        will be unavailable this run");
            }
            wd_log(&format!(
                "[wd] pid={pid} tid={tid} up, watching main tid={main_tid}, \
                 poll={}s stall_after={}s",
                POLL.as_secs(),
                STALL_AFTER.as_secs()
            ));

            let mut seq: u64 = 0;
            let mut last_ticks = TICKS.load(Ordering::Relaxed);
            let mut last_progress = std::time::Instant::now();
            let mut last_heartbeat = std::time::Instant::now();
            let mut announced = false;

            loop {
                // Ask before waiting, so the answer has the whole poll to
                // arrive.
                seq += 1;
                let frame = crate::frame_hwnd_cached();
                if !frame.0.is_null() {
                    let _ = unsafe {
                        PostMessageW(Some(frame), WM_WD_PING, WPARAM(seq as usize), LPARAM(0))
                    };
                }
                std::thread::sleep(POLL);

                let ticks = TICKS.load(Ordering::Relaxed);
                let pong = WD_PONG.load(Ordering::Relaxed);

                if ticks != last_ticks {
                    if announced {
                        wd_log(&format!(
                            "[wd] pid={pid} resumed after {:.1}s, ticks={ticks}",
                            last_progress.elapsed().as_secs_f64()
                        ));
                        announced = false;
                    }
                    last_ticks = ticks;
                    last_progress = std::time::Instant::now();
                } else if last_progress.elapsed() >= STALL_AFTER {
                    // **Said every poll, on purpose.** A stall announced once
                    // and then quiet is indistinguishable from a stall that
                    // took the process with it; a line every two seconds says
                    // which, and the growing number is the reading.
                    announced = true;
                    if pong == seq {
                        let stalled = last_progress.elapsed().as_secs_f64();
                        wd_log(&format!(
                            "[wd] pid={pid} PUMP BUSY {stalled:.1}s: ticks frozen at \
                             {ticks}, ping {seq} ANSWERED -- a nested modal loop \
                             (menu, window move/size) is dispatching. Not a fault."
                        ));
                    } else if let Some(f) = alarm_file.as_ref() {
                        // **Not `format!`.** See `alarm`: this branch runs
                        // exactly when the main thread is not running, and one
                        // way for a thread to stop running is holding the heap
                        // lock -- which would park the watchdog in the
                        // allocator and produce silence instead of a report.
                        let mut l = blocked_line(
                            pid as u64,
                            last_progress.elapsed().as_secs(),
                            ticks,
                            seq,
                            pong,
                            tid as u64,
                        );
                        if l.truncated {
                            // Cannot grow the buffer here, but silence about
                            // it is worse than a short line.
                            l.s("[TRUNCATED]");
                        }
                        alarm(f, &l);
                    }
                    last_heartbeat = std::time::Instant::now();
                }

                if last_heartbeat.elapsed() >= HEARTBEAT {
                    last_heartbeat = std::time::Instant::now();
                    wd_log(&format!(
                        "[wd] pid={pid} watching, ticks={ticks} pong={pong}"
                    ));
                }
            }
        });

    if let Err(e) = spawned {
        // **Loud, because the alternative is a log with no `[wd]` lines that
        // reads exactly like a healthy run.**
        logf!("[wd] FAILED to start the watchdog: {e:?} -- no liveness data this run");
    }
}

fn log_build_identity() {
    // **A known answer, because three matching hashes prove nothing on their
    // own.** The cross-implementation check we have been relying on -- these
    // three values also computed on the build machine, by a different SHA-256
    // -- is the stronger floor of the two, but it needs both sides present.
    // This one works when only the log is in front of you, which is the
    // situation this whole line exists for: a hash that silently returned a
    // constant would read exactly like a real one, and "all three lines look
    // like hashes" is not evidence that any of them is.
    {
        const EMPTY_SHA256_PREFIX: &str = "e3b0c44298fc1c14";
        use windows::Win32::Security::Cryptography::{BCryptHash, BCRYPT_SHA256_ALG_HANDLE};
        let mut out = [0u8; 32];
        let rc = unsafe { BCryptHash(BCRYPT_SHA256_ALG_HANDLE, None, &[], &mut out) };
        let got: String = out[..8].iter().map(|b| format!("{:02x}", b)).collect();
        logf!(
            "[build] sha256 self-test: \"\" -> {} (want {}) {}",
            got,
            EMPTY_SHA256_PREFIX,
            if rc.is_ok() && got == EMPTY_SHA256_PREFIX {
                "ok"
            } else {
                "MISMATCH -- treat every hash below as unverified"
            }
        );
    }

    let Ok(exe) = std::env::current_exe() else {
        logf!("[build] current_exe() failed; no identity available");
        return;
    };
    logf!("[build] {}", binary_identity(&exe));
    for dll in ["ghostty-internal.dll", "ghostty-vt.dll"] {
        logf!("[build] {}", binary_identity(&exe.with_file_name(dll)));
    }
}

pub fn log_line(msg: &str) {
    let s = &format!("[{}] {}", now_str(), msg);
    println!("{s}");
    use std::io::Write as _;
    let _ = std::io::stdout().flush();
    // A redirected stdout is block-buffered, so a crash would lose everything.
    // The file copy is flushed on every line and is the one we trust.
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path())
    {
        let _ = writeln!(f, "{s}");
        let _ = f.flush();
    }
}

#[macro_export]
macro_rules! logf {
    ($($a:tt)*) => { $crate::log_line(&format!($($a)*)) };
}

// ------------------------------------------------------------ global state

static APP: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
/// The config the app was built with. Kept because the settings UI asks it for
/// diagnostics, and `ghostty_config_get_diagnostic` takes the handle.
static CONFIG: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static API: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_G: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static CELL_W: AtomicU32 = AtomicU32::new(0);
static CELL_H: AtomicU32 = AtomicU32::new(0);
/// Whether to call ghostty_surface_draw from the window procedure.
/// Off by default: the renderer thread owns the WGL context, so a
/// main-thread draw has no context current. See docs/windows/status.md.
static DRAW_ON_PAINT: AtomicU32 = AtomicU32::new(0);
/// How many key messages `ITfKeystrokeMgr` claimed before dispatch.
static TSF_ATE: AtomicU32 = AtomicU32::new(0);
/// How many times WM_PAINT actually made the *main thread* call
/// ghostty_surface_draw. Without this number, a clean-looking resize proves
/// nothing: it could just mean no paint was ever requested.
static PAINTS: AtomicU32 = AtomicU32::new(0);

thread_local! {
    /// The composition, and the store TSF talks to. Single-threaded on
    /// purpose: TSF is apartment-bound and every call here arrives on the
    /// message loop's thread.
    static IME: RefCell<Option<ImeState>> = const { RefCell::new(None) };
}

struct ImeState {
    /// The composition. Shared with the store, and reached from here only to
    /// retarget it at another tab's window.
    ime: Rc<RefCell<tsf::Ime>>,
    store: windows::core::ComObject<tsf::TextStore>,
    thread_mgr: windows::Win32::UI::TextServices::ITfThreadMgr,
    doc_mgr: windows::Win32::UI::TextServices::ITfDocumentMgr,
    _ctx: windows::Win32::UI::TextServices::ITfContext,
}

/// The frame window, read from an atomic rather than the state lock.
///
/// **`content_bounds` needs this and cannot take the lock**: it is called
/// from inside `layout`'s critical section, so a `state()` in there would
/// re-enter a non-re-entrant mutex -- on the anomaly path, which is to say
/// the path that only runs when something is already wrong. The lock scanner
/// caught it; the atomic is the same value without the hazard.
pub fn frame_hwnd_cached() -> HWND {
    HWND(HWND_G.load(Ordering::Acquire))
}

pub fn api() -> &'static Api {
    unsafe { &*(API.load(Ordering::Acquire) as *const Api) }
}

/// Whether the main thread should draw in WM_PAINT (the `--draw-on-paint`
/// experiment from M1; the renderer thread drives redraw otherwise).
pub fn draw_on_paint() -> bool {
    DRAW_ON_PAINT.load(Ordering::Relaxed) == 1
}

/// Count one main-thread paint and return the running total.
pub fn paint_tick() -> u32 {
    PAINTS.fetch_add(1, Ordering::Relaxed) + 1
}

/// Content scale. `ghostty_surface_ime_point` answers in unscaled units;
/// every pixel this host hands to Windows is physical.
fn scale() -> f64 {
    tabs::state().scale
}

// ------------------------------------------------- bridge used by tsf.rs
//
// tsf.rs deliberately knows nothing about libghostty. These functions are the
// entire surface between the composition and the terminal.

pub fn ime_log(msg: &str) {
    log_line(&format!("[ime] {msg}"));
}

/// Hand the in-flight composition to the core so it draws it at the cursor.
pub fn ime_set_preedit(text: &str) {
    let s = tabs::active_surface();
    if s.is_null() {
        return;
    }
    unsafe { (api().surface_preedit)(s, text.as_ptr() as *const _, text.len()) };
}

/// The user chose a candidate: feed it to the terminal as input.
pub fn ime_commit(text: &str) {
    let s = tabs::active_surface();
    if s.is_null() {
        return;
    }
    unsafe { (api().surface_text)(s, text.as_ptr() as *const _, text.len()) };
}

pub fn ime_cell_size() -> (i32, i32) {
    (
        CELL_W.load(Ordering::Acquire).max(1) as i32,
        CELL_H.load(Ordering::Acquire).max(1) as i32,
    )
}

/// Columns a UTF-16 run occupies, measured with the terminal's own table.
///
/// Three different counts live in this function and conflating any two is the
/// classic way to put a candidate window slightly off: `units` are what an ACP
/// indexes, `cps` are what the width table consumes, and the return value is
/// cells. A character outside the BMP is 2 units, 1 codepoint, and usually 2
/// cells -- all three differ, which is why none of them is used as a stand-in
/// for another.
pub fn ime_columns(units: &[u16]) -> i32 {
    if units.is_empty() {
        return 0;
    }
    let cps: Vec<u32> = char::decode_utf16(units.iter().copied())
        .map(|r| r.map(|c| c as u32).unwrap_or(0xFFFD))
        .collect();
    let f = api().grapheme_width;
    let mut total: i32 = 0;
    let mut i: usize = 0;
    while i < cps.len() {
        let mut w: u8 = 0;
        let used = unsafe { f(cps.as_ptr().add(i), cps.len() - i, &mut w) };
        if used == 0 {
            break; // documented: only when len == 0
        }
        total += w as i32;
        i += used;
    }
    total
}

/// The cursor cell as a client-area rectangle in physical pixels, in the
/// coordinates of the active tab's window.
///
/// `ghostty_surface_ime_point` gives a midpoint and a bottom edge in unscaled
/// units (see the note in ffi.rs); this turns that back into the cell.
pub fn ime_caret_cell() -> Option<RECT> {
    let s = tabs::active_surface();
    if s.is_null() {
        return None;
    }
    let (cw, ch) = ime_cell_size();
    let (mut x, mut y, mut w, mut h) = (0f64, 0f64, 0f64, 0f64);
    unsafe { (api().surface_ime_point)(s, &mut x, &mut y, &mut w, &mut h) };
    // NOTE: `w` is ignored here on purpose. The core scales x/y/height by the
    // content scale but not width (Surface.zig says so, and says the reason is
    // unknown), so the four numbers are not in the same unit. Columns are
    // measured here instead, which needs no width from the core. At the test
    // machine's 96 dpi the discrepancy is invisible; on a scaled display it
    // would not be, so this is a real thing to re-check there.
    let _ = w;
    let sc = scale();
    let mid_x = x * sc;
    let bottom = y * sc;
    let cell_h = if h > 0.0 { (h * sc) as i32 } else { ch };
    let left = (mid_x as i32) - cw / 2;
    Some(RECT {
        left,
        top: bottom as i32 - cell_h,
        right: left + cw,
        bottom: bottom as i32,
    })
}

/// Tell TSF the composition moved without its text changing.
pub fn ime_layout_changed() {
    let store = IME.with(|c| c.borrow().as_ref().map(|st| st.store.clone()));
    if let Some(store) = store {
        store.notify_layout_change();
    }
}

pub fn ime_focus(on: bool) {
    let pair = IME.with(|c| {
        c.borrow()
            .as_ref()
            .map(|st| (st.thread_mgr.clone(), st.doc_mgr.clone()))
    });
    if let Some((tm, dm)) = pair {
        unsafe {
            let _ = if on { tm.SetFocus(&dm) } else { tm.SetFocus(None) };
        }
    }
}

/// Let TSF know a new tab's window exists, so focusing it finds a document.
pub fn ime_attach(hwnd: HWND) {
    let pair = IME.with(|c| {
        c.borrow()
            .as_ref()
            .map(|st| (st.thread_mgr.clone(), st.doc_mgr.clone()))
    });
    if let Some((tm, dm)) = pair {
        unsafe {
            let _ = tm.AssociateFocus(hwnd, &dm);
        }
    }
}

/// Point the composition at another tab's window.
///
/// `try_borrow_mut` rather than `borrow_mut`: TSF calls back into the store
/// from inside our own stack frames, and a panic here would be a crash in the
/// middle of somebody's typing. A miss means the caret rectangle is measured
/// against the previous window until the next focus change, which is visible
/// and recoverable.
pub fn ime_set_window(hwnd: HWND) {
    IME.with(|c| {
        if let Some(st) = c.borrow().as_ref() {
            match st.ime.try_borrow_mut() {
                Ok(mut ime) => ime.hwnd = hwnd,
                Err(_) => logf!("[ime] set_window skipped: composition in flight"),
            }
        }
    });
}

/// Stand up TSF for this thread and point it at the terminal window.
///
/// Order matters: the document manager has to exist and be associated with the
/// HWND before the window can take focus, or the first composition goes
/// nowhere. Called after the first surface exists so `ime_caret_cell` has
/// something to answer with.
fn ime_init(hwnd: HWND) -> bool {
    use windows::core::ComObject;
    use windows::Win32::System::Com::*;
    use windows::Win32::UI::TextServices::*;
    unsafe {
        if let Err(e) = CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok() {
            logf!("[ime] CoInitializeEx failed: {e:?}");
            return false;
        }
        let thread_mgr: ITfThreadMgr =
            match CoCreateInstance(&CLSID_TF_ThreadMgr, None, CLSCTX_INPROC_SERVER) {
                Ok(t) => t,
                Err(e) => {
                    logf!("[ime] CoCreateInstance(TF_ThreadMgr) failed: {e:?}");
                    return false;
                }
            };
        let ex: ITfThreadMgrEx = match thread_mgr.cast() {
            Ok(x) => x,
            Err(e) => {
                logf!("[ime] ITfThreadMgrEx cast failed: {e:?}");
                return false;
            }
        };
        let mut client_id = 0u32;
        if let Err(e) = ex.ActivateEx(&mut client_id, 0) {
            logf!("[ime] ActivateEx failed: {e:?}");
            return false;
        }
        logf!("[ime] ActivateEx ok, clientId={client_id}");

        let doc_mgr = match thread_mgr.CreateDocumentMgr() {
            Ok(d) => d,
            Err(e) => {
                logf!("[ime] CreateDocumentMgr failed: {e:?}");
                return false;
            }
        };

        let ime = Rc::new(RefCell::new(tsf::Ime::new(hwnd)));
        let store: ComObject<tsf::TextStore> = tsf::TextStore::new(ime.clone()).into();
        let punk: windows::core::IUnknown = store.to_interface();

        let mut ctx: Option<ITfContext> = None;
        let mut edit_cookie = 0u32;
        if let Err(e) = doc_mgr.CreateContext(client_id, 0, &punk, &mut ctx, &mut edit_cookie) {
            logf!("[ime] CreateContext failed: {e:?}");
            return false;
        }
        let ctx = match ctx {
            Some(c) => c,
            None => {
                logf!("[ime] CreateContext gave no context");
                return false;
            }
        };
        if let Err(e) = doc_mgr.Push(&ctx) {
            logf!("[ime] Push failed: {e:?}");
            return false;
        }
        let _ = thread_mgr.AssociateFocus(hwnd, &doc_mgr);
        let _ = thread_mgr.SetFocus(&doc_mgr);
        logf!("[ime] context pushed, editCookie={edit_cookie}  <<< TSF READY");

        IME.with(|c| {
            *c.borrow_mut() = Some(ImeState {
                ime,
                store,
                thread_mgr,
                doc_mgr,
                _ctx: ctx,
            });
        });
        true
    }
}

// -------------------------------------------------------------- callbacks

extern "C" fn cb_wakeup(_ud: *mut c_void) {}

// ------------------------------------------------------------- clipboard
//
// **Both of these were stubs, and the copy path reported success while doing
// nothing** -- the one shape of defect that no amount of checking the logs
// would have caught, because its log was green. What was missing was not the
// knowledge of how to write a clipboard (`tabs::copy_to_clipboard` has been
// complete since the tab titles needed it) but the wiring, and on the read
// side half the entry points: `ghostty_surface_complete_clipboard_request`
// was never even resolved from the DLL, which is what made a hard-coded
// `false` the only self-consistent thing `cb_read_clipboard` could return.

/// A paste has been asked for. **Returning `true` is a promise**, see
/// `ffi::ReadClipboardCb`: the core has allocated `state` and will only free
/// it if we return `false` or complete the request. Every failure path below
/// therefore returns `false`, and there is no path that returns `true`
/// without having called `complete_clipboard_request` first.
extern "C" fn cb_read_clipboard(ud: *mut c_void, kind: u32, state: *mut c_void) -> bool {
    let pane = ud as u64;
    if kind != ffi::CLIPBOARD_STANDARD {
        // See `cb_write_clipboard` for why this is refused rather than mapped.
        logf!("[clip] read kind={} pane={} -> refused: no selection clipboard on Windows", kind, pane);
        return false;
    }
    let surface = tabs::surface_of_pane(pane);
    if surface.is_null() {
        logf!("[clip] read kind={} pane={} -> false: no surface for that pane", kind, pane);
        return false;
    }
    let text = match tabs::read_clipboard_text() {
        Ok(t) => t,
        Err(why) => {
            logf!("[clip] read kind={} pane={} -> false: {}", kind, pane, why);
            return false;
        }
    };
    // An interior NUL cannot be handed to a C string API. Truncating at it is
    // what every other apprt does, and it is said out loud rather than
    // silently producing a shorter paste.
    let cut = text.find('\0');
    if let Some(at) = cut {
        logf!("[clip] read pane={}: clipboard text has a NUL at {}; truncated there", pane, at);
    }
    let text = &text[..cut.unwrap_or(text.len())];
    let Ok(c) = std::ffi::CString::new(text) else {
        logf!("[clip] read kind={} pane={} -> false: could not make a C string", kind, pane);
        return false;
    };
    logf!("[clip] read kind={} pane={} -> {} chars, completing", kind, pane, text.chars().count());
    // **`confirmed: false`.** `clipboard-paste-protection` defaults to true,
    // and this is what keeps it working: the core gets to look at the text
    // and ask before pasting something that could run on arrival. Passing
    // `true` here would answer that question on the user's behalf, always.
    unsafe {
        (api().surface_complete_clipboard_request)(surface, c.as_ptr(), state, false);
    }
    true
}

/// The core looked at the text and wants it confirmed before pasting.
///
/// **This fires on any ordinary multi-line paste** (`Surface.zig:6678`:
/// unbracketed text that is not `input.paste.isSafe`), so it is not an exotic
/// path -- leaving it empty, as it was, means pasting a two-line command
/// silently does nothing. That is the same defect this task exists to fix,
/// one level down.
///
/// So it asks. A `MessageBox` is not the dialog `s4.md` §J wants (macOS has
/// 195 lines of `ClipboardConfirmation` with the text shown in full), and it
/// is recorded as that block still being unwritten -- but the alternative is
/// a paste that works for one line and not for two.
///
/// **A refusal does not leak, and the way out is worth stating.** The only
/// exported entry point is `complete_clipboard_request`, so "cancel" has to be
/// spelled as a completion that does nothing. `embedded.zig:800-832` only
/// keeps the request when the completion throws `UnsafePaste` /
/// `UnauthorizedPaste`; every other outcome, errors included, falls through to
/// `alloc.destroy(state)`. So completing with an **empty string** frees it:
///
///  * `.paste` -> `completeClipboardPaste` returns at `if (data.len == 0)`,
///    which is its **first** line, ahead of the safety check. Nothing is
///    pasted and no error is thrown.
///  * `.osc_52_read` -> replies with an empty OSC 52 payload, which is the
///    right answer to a read the user declined: the client gets its reply and
///    learns nothing about the clipboard.
///
/// **`confirmed: true`, and the reason is the OSC 52 branch, not the paste
/// one.** For `.paste` either value works, because the length check is
/// reached first. For `.osc_52_read`, `confirmed: false` with
/// `clipboard-read = ask` throws `UnauthorizedPaste` again
/// (`Surface.zig:6591`), which calls straight back into this function --
/// round and round, and the state is never released.
extern "C" fn cb_confirm_read_clipboard(
    ud: *mut c_void,
    s: *const std::os::raw::c_char,
    state: *mut c_void,
    req: u32,
) {
    let pane = ud as u64;
    let text = if s.is_null() {
        String::new()
    } else {
        unsafe { std::ffi::CStr::from_ptr(s) }.to_string_lossy().to_string()
    };
    let surface = tabs::surface_of_pane(pane);
    logf!(
        "[clip] paste confirmation requested: pane={} req={} {} chars, {} lines",
        pane,
        req,
        text.chars().count(),
        text.lines().count()
    );
    if surface.is_null() {
        logf!("[clip] paste confirmation: no surface for pane {}; not pasting", pane);
        return;
    }

    // Enough of it to judge by, and not so much that the box does not fit.
    let mut preview: String = text.chars().take(400).collect();
    if text.chars().count() > 400 {
        preview.push_str("\n…");
    }
    let body = format!(
        "要粘贴的内容有 {} 行，其中可能含有会立即执行的字符。\n\n{}\n\n确定要粘贴吗？",
        text.lines().count(),
        preview
    );
    let yes = unsafe {
        let b: Vec<u16> = body.encode_utf16().chain(Some(0)).collect();
        let t: Vec<u16> = "确认粘贴".encode_utf16().chain(Some(0)).collect();
        MessageBoxW(
            Some(tabs::frame_hwnd()),
            windows::core::PCWSTR(b.as_ptr()),
            windows::core::PCWSTR(t.as_ptr()),
            MB_YESNO | MB_ICONWARNING,
        ) == IDYES
    };
    logf!("[clip] paste confirmation: pane={} answered {}", pane, if yes { "yes" } else { "no" });
    if !yes {
        // **Not `.osc_52_write`.** That branch hands the string straight to
        // `setClipboard`, so completing it with an empty one would *clear*
        // the user's clipboard rather than leave it alone. It cannot arrive
        // here today -- `setClipboard` returns no error, so it never reaches
        // the catch that calls this function -- but the day it can, emptying
        // the clipboard on a refusal is not the failure to discover late.
        if req == ffi::CLIPBOARD_REQUEST_OSC_52_WRITE {
            logf!(
                "[clip] declined an OSC 52 write; not completing it, because an empty completion would clear the clipboard"
            );
            return;
        }
        let empty = std::ffi::CString::default();
        unsafe {
            (api().surface_complete_clipboard_request)(surface, empty.as_ptr(), state, true);
        }
        logf!("[clip] paste declined; completed empty so the core releases the request");
        return;
    }
    unsafe {
        (api().surface_complete_clipboard_request)(surface, s, state, true);
    }
}

/// Something asked for text to be put on the clipboard.
///
/// **The payload is an array of `{mime, data}` pairs, not a string.** Read as
/// one C string it yields the mime type, so a copy would put `text/plain` on
/// the clipboard and report success -- which is this defect exactly, with a
/// different cause.
extern "C" fn cb_write_clipboard(
    ud: *mut c_void,
    kind: u32,
    content: *const ffi::ClipboardContent,
    n: usize,
    confirm: bool,
) {
    let pane = ud as u64;
    if kind != ffi::CLIPBOARD_STANDARD {
        // **Refused rather than mapped onto the one clipboard Windows has.**
        // `supports_selection_clipboard` is false and the core gates on it,
        // so this should not arrive from a normal path -- but OSC 52 can ask
        // directly, and honouring it would let a remote program overwrite the
        // clipboard the user is actually holding, through an action the user
        // never took.
        logf!("[clip] write kind={} pane={} -> refused: Windows has one clipboard and we declare no selection support", kind, pane);
        return;
    }
    if confirm {
        // `clipboard-write` defaults to `allow`, so reaching here means the
        // user set it to `ask`. We cannot ask, so we must not answer.
        logf!("[clip] write kind={} pane={} -> refused: clipboard-write=ask and this host has no confirmation UI", kind, pane);
        return;
    }
    if content.is_null() || n == 0 {
        logf!("[clip] write kind={} pane={} -> nothing to write (count={})", kind, pane, n);
        return;
    }
    let items = unsafe { std::slice::from_raw_parts(content, n) };
    let read = |p: *const std::os::raw::c_char| -> Option<String> {
        if p.is_null() {
            return None;
        }
        Some(unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().to_string())
    };
    // Prefer plain text; fall back to the first entry that has any data, so a
    // core that sends only some other text-ish mime still copies something.
    let chosen = items
        .iter()
        .map(|c| (read(c.mime).unwrap_or_default(), read(c.data)))
        .filter(|(_, d)| d.is_some())
        .max_by_key(|(m, _)| u8::from(m.starts_with("text/plain")));
    let Some((mime, Some(data))) = chosen else {
        logf!("[clip] write kind={} pane={} count={} -> nothing to write: every entry had a null data pointer", kind, pane, n);
        return;
    };
    match tabs::copy_to_clipboard(&data) {
        Ok(()) => logf!(
            "[clip] write kind={} pane={} count={} mime={:?} len={} -> ok",
            kind, pane, n, mime, data.chars().count()
        ),
        // **"Wrote" and "wrote successfully" are two lines on purpose.** The
        // defect being fixed here was the gap between them.
        Err(why) => logf!(
            "[clip] write kind={} pane={} count={} mime={:?} len={} -> FAILED: {}",
            kind, pane, n, mime, data.chars().count(), why
        ),
    }
}
/// A surface asked to be closed -- its shell exited, or something asked for
/// it to go. `userdata` is the pane id we put in `ghostty_surface_config_s`,
/// which is the only thing that says *which* pane this is: with splits,
/// quitting the whole process here would close three panes because one shell
/// exited.
extern "C" fn cb_close_surface(ud: *mut c_void, _confirm: bool) {
    let id = ud as u64;
    logf!("[action] close_surface pane={}", id);
    if id == 0 {
        // No pane id means we cannot tell which one; closing nothing is safer
        // than closing the wrong one.
        logf!("[action] close_surface with no pane id -- ignored");
        return;
    }
    tabs::post_op(tabs::Op::ClosePane(id));
}

/// The surface an action was aimed at, or `None`.
///
/// **`ghostty_target_u` is a union whose only member is a surface**, so when
/// the tag says `APP` that field is not a surface -- it is whatever happened
/// to be in those eight bytes. Reading it unconditionally is how a per-surface
/// fact gets filed against a pointer that names nothing, and the result looks
/// exactly like a correct program until two surfaces disagree.
///
/// One function so that every arm that needs a target asks the same question;
/// three arms doing it inline is three chances for the fourth to forget.
fn target_surface(target: &Target) -> Option<Surface> {
    if target.tag != ffi::TARGET_SURFACE || target.surface.is_null() {
        return None;
    }
    Some(target.surface)
}

extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    use tabs::Op;
    match action.tag {
        // The core owns the command list and the actions; the host only
        // renders and dispatches. Queued rather than done inline: `cb_action`
        // can arrive on the core's thread, and showing a window off the
        // owning thread is undefined.
        ffi::ACTION_TOGGLE_COMMAND_PALETTE => {
            palette::request_toggle();
            true
        }

        // Search: the core owns the search, the host owns a text box and a
        // counter. All four only copy and post -- `cb_action` can be on the
        // core's thread, and the `start_search` needle is only valid for the
        // duration of this call.
        ffi::ACTION_START_SEARCH => {
            search::on_start(action.as_cstr().and_then(|c| c.to_str().ok()));
            true
        }
        ffi::ACTION_END_SEARCH => {
            search::on_end();
            true
        }
        ffi::ACTION_SEARCH_TOTAL => {
            search::on_count(Some(action.as_isize()), None);
            true
        }
        ffi::ACTION_SEARCH_SELECTED => {
            search::on_count(None, Some(action.as_isize()));
            true
        }

        // The pending-key indicator.
        ffi::ACTION_KEY_SEQUENCE => {
            let (active, tag, key, mods) = action.as_key_sequence();
            keyseq::on_key_sequence(active, tag, key, mods);
            true
        }
        ffi::ACTION_KEY_TABLE => {
            let (tag, name) = action.as_key_table();
            keyseq::on_key_table(tag, name.as_deref());
            true
        }

        // The read-only badge. The core owns the state; the host paints the
        // last thing it said.
        // The core decides *where* the config is and asks the host to open
        // it; only the opening is ours. Mode 1 wants it in an editor in a new
        // terminal window, which needs a surface with a command -- logged
        // rather than silently treated as mode 0, because "it opened the wrong
        // way" is a bug report and "nothing happened" is not.
        ffi::ACTION_OPEN_CONFIG => {
            let mode = action.as_i32();
            let s = unsafe { (api().config_open_path)() };
            if s.ptr.is_null() || s.len == 0 {
                logf!("[action] open_config: the core reported no path");
                return false;
            }
            let bytes = unsafe { std::slice::from_raw_parts(s.ptr as *const u8, s.len) };
            let path = String::from_utf8_lossy(bytes).into_owned();
            unsafe { (api().string_free)(s) };

            if mode != 0 {
                logf!("[action] open_config mode {} not supported; opening with the OS", mode);
            }
            let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
            let r = unsafe {
                windows::Win32::UI::Shell::ShellExecuteW(
                    None,
                    windows::core::w!("open"),
                    windows::core::PCWSTR(wide.as_ptr()),
                    windows::core::PCWSTR::null(),
                    windows::core::PCWSTR::null(),
                    SW_SHOWNORMAL,
                )
            };
            // ShellExecuteW returns a fake HINSTANCE; <= 32 means it failed.
            let ok = r.0 as usize > 32;
            logf!("[action] open_config {:?} -> {}", path, ok);
            ok
        }

        // **Read-only is per surface, and this arm used to drop `target`.**
        // One `AtomicBool` for the whole process is why a split showed the
        // right-hand pane's menu with the left-hand pane's tick: both panes
        // were reading one flag that whichever surface spoke last had set.
        // Float the window. The mode is `ghostty_action_float_window_e`
        // (on / off / toggle), and it is a *window* property, so the target
        // does not have to be a surface.
        ffi::ACTION_FLOAT_WINDOW => {
            prompt::request_float(action.as_i32());
            true
        }

        // The title box. **The payload is the whole point**: one tag carries
        // three different requests (surface / tab / window), and an arm that
        // ignored it would rename the wrong thing while looking correct.
        ffi::ACTION_PROMPT_TITLE => {
            // **The target rides along.** The typed name is sent back through
            // a binding, and a binding with no surface goes to whichever one
            // has focus -- so a title box opened on a pane that is not
            // focused would rename the focused one instead, and look right
            // doing it.
            prompt::request_title(action.as_i32(), target_surface(&target));
            true
        }

        // **Not built, and each says why rather than falling through.** A tag
        // that reaches `_ => false` is indistinguishable from one that was
        // never sent; these two lines are the difference between "this host
        // does not do that yet" and "the menu is broken".
        ffi::ACTION_INSPECTOR => {
            logf!(
                "[action] inspector requested (mode {}), but libghostty publishes no renderer for \
                 it outside Apple: ghostty_inspector_metal_* in include/ghostty.h sits inside \
                 #ifdef __APPLE__. Not a missing host feature -- a missing C API.",
                action.as_i32()
            );
            false
        }
        // **Two fields are the whole of it**, the same two `Ghostty.App.swift`'s
        // `openChat` sets: the command to run, and the flag that tells the core
        // requests from this surface speak for the person at the keyboard.
        //
        // `toggle_` is the core's name for it; this opens one and does not
        // close it again. Closing the chat tab is closing a tab, which the
        // strip already does -- and a toggle that hunted for "the chat tab" to
        // close would need to decide which one when there are two.
        ffi::ACTION_TOGGLE_POLTERGEIST_CHAT => {
            logf!("[action] poltergeist chat requested");
            tabs::post_op(tabs::Op::NewTabWith(tabs::NewTab {
                command: Some("polter +chat".to_string()),
                chat: true,
                ..Default::default()
            }));
            true
        }

        ffi::ACTION_READONLY => {
            let on = action.as_i32() != 0;
            // The tag is checked because the union only holds a surface: an
            // app-targeted action's `surface` field is not one, and recording
            // a per-surface fact against it would key the table on garbage.
            match target_surface(&target) {
                Some(s) => {
                    hud::on_readonly_for(s as usize, on);
                    logf!("[action] readonly={} surface={:?}", on, s);
                }
                None => logf!("[action] readonly={} with no surface (tag={}); dropped", on, target.tag),
            }
            true
        }

        ACTION_INITIAL_SIZE => {
            let (w, h) = action.as_size();
            logf!("[action] initial_size {}x{}", w, h);
            let mut st = tabs::state();
            if st.initial.is_none() {
                st.initial = Some((w, h));
            }
            true
        }
        ACTION_CELL_SIZE => {
            let (w, h) = action.as_size();
            CELL_W.store(w, Ordering::Release);
            CELL_H.store(h, Ordering::Release);
            logf!("[action] cell_size {}x{}", w, h);
            true
        }

        // The core knows the terminal cannot be smaller than a few cells, and
        // Win32 has a message for exactly that. macOS ignores this action and
        // constrains through AppKit instead, so there is no reference
        // implementation to copy.
        ACTION_SIZE_LIMIT => {
            let (min_w, min_h, max_w, max_h) = action.as_size_limit();
            {
                let mut st = tabs::state();
                st.min_w = min_w;
                st.min_h = min_h;
                st.max_w = max_w;
                st.max_h = max_h;
            }
            logf!(
                "[action] size_limit min {}x{} max {}x{} (0 max = unlimited)",
                min_w, min_h, max_w, max_h
            );
            true
        }

        ACTION_SET_TITLE => {
            if let Some(t) = action.as_cstr() {
                let t = t.to_string_lossy().to_string();
                logf!("[action] set_title {:?}", t);
                let mut wide: Vec<u16> = t.encode_utf16().collect();
                wide.push(0);
                let h = HWND_G.load(Ordering::Acquire);
                if !h.is_null() {
                    unsafe {
                        let _ = SetWindowTextW(HWND(h), PCWSTR(wide.as_ptr()));
                    }
                }
                // The window title and the tab label track the same string
                // until something calls set_tab_title with its own.
                //
                // **The tab half is per surface.** The window's caption is
                // genuinely the window's -- whichever terminal is in front
                // names it -- but the tab label belongs to the tab this came
                // from, and that is not always the tab in front.
                match target_surface(&target) {
                    Some(s) => tabs::post_op(Op::SetTabTitle { surface: s as usize, title: t }),
                    None => logf!("[action] set_title with no surface (tag={}); tab label unchanged", target.tag),
                }
            }
            true
        }
        // **Per surface, and this is the arm that makes "reopen" land in the
        // right directory.** Using the active tab here would file tab A's
        // directory against tab B -- and nothing would show it until a
        // reopened tab started somewhere the user had never been.
        ffi::ACTION_PWD => {
            let Some(cwd) = action.as_cstr().map(|c| c.to_string_lossy().to_string()) else {
                return true;
            };
            match target_surface(&target) {
                Some(s) => {
                    let attached = tabs::set_cwd_for_surface(s, cwd.clone());
                    // `attached=0` is not a failure: `pwd` arrives from inside
                    // `surface_new`, before the tab exists, and is held until
                    // it does. It is logged because "held" and "lost" would
                    // otherwise look the same.
                    logf!("[action] pwd {:?} surface={:?} attached={}", cwd, s, attached as u8);
                }
                None => logf!("[action] pwd {:?} with no surface (tag={}); dropped", cwd, target.tag),
            }
            true
        }

        // **Per surface, and it used to drop the target.** A program in a
        // background tab -- a build printing its progress into the title --
        // renamed whichever tab was in front instead of its own. The guard
        // added for user-named tabs made that worse rather than better: the
        // stray title could then be refused by the *front* tab's override,
        // leaving the background tab's name permanently stale with nothing
        // reporting either half.
        ACTION_SET_TAB_TITLE => {
            if let Some(t) = action.as_cstr() {
                let t = t.to_string_lossy().to_string();
                logf!("[action] set_tab_title {:?}", t);
                match target_surface(&target) {
                    Some(s) => tabs::post_op(Op::SetTabTitle { surface: s as usize, title: t }),
                    None => logf!("[action] set_tab_title with no surface (tag={}); dropped", target.tag),
                }
            }
            true
        }
        // **Read off `target`, not off the active tab.** Every other action
        // here queues an `Op` that lands on whichever tab is active when the
        // queue runs, which is right for a title the focused shell just set.
        // A mark is different: it can be made on a terminal that is not in
        // front -- from the tab strip's own right-click menu, or by a
        // supervisor elsewhere -- and applying it to the active tab would put
        // the tick on the wrong row while looking entirely normal.
        //
        // Done inline rather than queued because it touches no window: it
        // writes two fields under the same lock every `Op` would have taken.
        ffi::ACTION_POLTERGEIST_MARK => {
            let (role, shielded) = action.as_poltergeist_mark();
            let found = target_surface(&target)
                .is_some_and(|s| tabs::set_mark_for_surface(s, role as u8, shielded));
            // The surface's own right-click menu wants the same three bits.
            // It reads them back out of `tabs::mark_for_surface`; this call
            // is the notification that they changed, not a second copy.
            crate::ctxmenu::on_poltergeist_mark(role, shielded);
            logf!(
                "[action] poltergeist_mark role={} shielded={} surface={:?} matched={}",
                role, shielded, target.surface, found
            );
            true
        }

        ACTION_COPY_TITLE_TO_CLIPBOARD => {
            logf!("[action] copy_title_to_clipboard");
            tabs::post_op(Op::CopyTitleToClipboard);
            true
        }

        ACTION_NEW_SPLIT => {
            let dir = action.as_i32();
            logf!("[action] new_split dir={}", dir);
            tabs::post_op(Op::NewSplit(dir));
            true
        }
        ACTION_GOTO_SPLIT => {
            let v = action.as_i32();
            logf!("[action] goto_split {}", v);
            tabs::post_op(Op::GotoSplit(v));
            true
        }
        ACTION_RESIZE_SPLIT => {
            let (amount, dir) = action.as_resize_split();
            logf!("[action] resize_split {} dir={}", amount, dir);
            tabs::post_op(Op::ResizeSplit(amount, dir));
            true
        }
        ACTION_EQUALIZE_SPLITS => {
            logf!("[action] equalize_splits");
            tabs::post_op(Op::EqualizeSplits);
            true
        }
        ACTION_TOGGLE_SPLIT_ZOOM => {
            logf!("[action] toggle_split_zoom");
            tabs::post_op(Op::ToggleSplitZoom);
            true
        }

        ACTION_TOGGLE_QUICK_TERMINAL => {
            logf!("[action] toggle_quick_terminal");
            tabs::post_op(Op::ToggleQuickTerminal);
            true
        }
        ACTION_NEW_TAB => {
            logf!("[action] new_tab");
            tabs::post_op(Op::NewTab);
            true
        }
        ACTION_CLOSE_TAB => {
            let mode = action.as_i32();
            logf!("[action] close_tab mode={}", mode);
            tabs::post_op(Op::CloseTab(mode));
            true
        }
        ACTION_GOTO_TAB => {
            let v = action.as_i32();
            logf!("[action] goto_tab {}", v);
            tabs::post_op(Op::GotoTab(v));
            true
        }
        ACTION_MOVE_TAB => {
            let d = action.as_isize();
            logf!("[action] move_tab {}", d);
            tabs::post_op(Op::MoveTabBy(d));
            true
        }

        ACTION_TOGGLE_FULLSCREEN => {
            logf!("[action] toggle_fullscreen mode={}", action.as_i32());
            tabs::post_op(Op::ToggleFullscreen);
            true
        }
        ACTION_TOGGLE_MAXIMIZE => {
            logf!("[action] toggle_maximize");
            tabs::post_op(Op::ToggleMaximize);
            true
        }
        ACTION_RESET_WINDOW_SIZE => {
            logf!("[action] reset_window_size");
            tabs::post_op(Op::ResetWindowSize);
            true
        }

        ACTION_RENDERER_HEALTH => {
            logf!("[action] renderer_health (payload[0]={})", action.payload[0]);
            true
        }
        ACTION_PRESENT_TERMINAL => {
            logf!("[action] present_terminal");
            tabs::post_op(Op::PresentTerminal);
            true
        }
        ACTION_MOUSE_SHAPE | ACTION_MOUSE_VISIBILITY => true,
        ACTION_RING_BELL => {
            logf!("[action] ring_bell");
            true
        }
        ACTION_CONFIG_CHANGE | ACTION_RELOAD_CONFIG => {
            settings_ui::request_errors();
            logf!("[action] config_change/reload_config");
            true
        }
        ACTION_SHOW_CHILD_EXITED => {
            logf!("[action] show_child_exited");
            true
        }

        // `new_window` is still unimplemented: a second frame is a second
        // top-level window with its own tab set, which is the next batch.
        // Returning false is the honest answer and is what macOS does for
        // the nine actions it does not implement either.
        ACTION_CLOSE_WINDOW | ACTION_QUIT => {
            // **`frame_hwnd()` here is a stand-in and is marked as one.** The
            // action carries a target, but a target is a *surface*, and the
            // window that owns it cannot be asked for until there is more than
            // one. B1 has to replace this; until then the line is true because
            // there is only one window for it to be true of.
            winid::close_requested(tabs::frame_hwnd(), winid::CloseVia::CoreCloseWindow);
            logf!("[action] close_window/quit tag={}", action.tag);
            winid::window_finished(tabs::frame_hwnd());
            true
        }
        ACTION_RENDER => true,
        _ => false,
    }
}

// ------------------------------------------------------------- window proc

/// This window's DPI, for the metrics that have a per-DPI form.
pub fn dpi_for(hwnd: HWND) -> u32 {
    let dpi = unsafe { GetDpiForWindow(hwnd) };
    if dpi == 0 {
        96
    } else {
        dpi
    }
}

/// The two halves of an `lParam` carrying a point. Signed, because a captured
/// pointer dragged off the left edge reports negative x, and reading it
/// unsigned makes the tab jump to the far right.
fn lo_i16(lp: LPARAM) -> i32 {
    (lp.0 & 0xFFFF) as u16 as i16 as i32
}
fn hi_i16(lp: LPARAM) -> i32 {
    ((lp.0 >> 16) & 0xFFFF) as u16 as i16 as i32
}

/// The frame. It owns the tab strip, the window-level state, and nothing
/// else: keys, text and the IME live on the surface windows (`tabs.rs`),
/// because those know which surface they belong to.
extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            // The watchdog's ping. Answering is one atomic store, so this arm
            // cannot itself be the thing that blocks -- and its arrival here
            // at all is the reading: it means this thread is still
            // dispatching, even if our own loop is not running.
            m if m == WM_WD_PING => {
                WD_PONG.store(wp.0 as u64, Ordering::Relaxed);
                LRESULT(0)
            }
            // The frame owns the strip only; it must still never let GDI
            // erase, or the strip flickers on every resize.
            WM_ERASEBKGND => LRESULT(1),

            // --- the custom frame. See shell.rs for why each one is here. ---
            WM_NCCALCSIZE => match shell::nc_calc_size(hwnd, wp, lp) {
                Some(r) => r,
                None => DefWindowProcW(hwnd, msg, wp, lp),
            },
            WM_NCHITTEST => shell::hit_test(hwnd, lo_i16(lp), hi_i16(lp)),
            WM_NCMOUSEMOVE => {
                shell::nc_hover(hwnd, wp.0 as isize);
                DefWindowProcW(hwnd, msg, wp, lp)
            }
            WM_NCMOUSELEAVE => {
                shell::nc_hover(hwnd, 0);
                DefWindowProcW(hwnd, msg, wp, lp)
            }
            WM_NCLBUTTONDOWN => {
                if shell::nc_click(hwnd, wp.0 as isize) {
                    LRESULT(0)
                } else {
                    DefWindowProcW(hwnd, msg, wp, lp)
                }
            }
            // The caption's colours differ when the window is not the active
            // one, and nothing else would ask us to repaint for that.
            WM_ACTIVATE => {
                // One of the three messages that change where the window is
                // -- the same three `LastWindowPosition` saves on. **Marked,
                // not written**: a drag delivers `WM_MOVE` continuously, and
                // the main loop is what touches the disk.
                session::mark_dirty();
                let _ = InvalidateRect(Some(hwnd), None, false);
                DefWindowProcW(hwnd, msg, wp, lp)
            }

            WM_PAINT => {
                strip::paint(hwnd);
                LRESULT(0)
            }

            // The strip owns the pointer while it is over it.
            WM_LBUTTONDOWN => {
                strip::on_button_down(hwnd, lo_i16(lp), hi_i16(lp));
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                strip::on_mouse_move(hwnd, lo_i16(lp), hi_i16(lp));
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                strip::on_button_up(hwnd, lo_i16(lp), hi_i16(lp));
                LRESULT(0)
            }
            WM_LBUTTONDBLCLK => {
                strip::on_double_click(hwnd, lo_i16(lp), hi_i16(lp));
                LRESULT(0)
            }
            WM_MOUSELEAVE => {
                strip::on_mouse_leave(hwnd);
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                strip::on_wheel(hwnd, ((wp.0 >> 16) & 0xFFFF) as i16);
                LRESULT(0)
            }

            // The right button over the strip. **Two messages, because the
            // strip is two things**: the tabs answer `HTCLIENT` (see
            // `shell::hit_test`) and so send client mouse messages, while the
            // empty space answers `HTCAPTION` so the window can be dragged by
            // it -- and a caption never sends `WM_RBUTTONUP` at all. Handling
            // only the first would leave `s4.md` §3.3's third menu
            // unreachable, and the symptom would be a menu that "sometimes"
            // does not appear.
            //
            // On the up, not the down: pressing and sliding off has to be a
            // way out of a menu, the same as it is for the close cross.
            WM_RBUTTONUP => {
                strip::on_right_click(hwnd, lo_i16(lp), hi_i16(lp));
                LRESULT(0)
            }
            WM_NCRBUTTONUP => {
                if strip::on_nc_right_click(hwnd, lo_i16(lp), hi_i16(lp)) {
                    LRESULT(0)
                } else {
                    // Not ours: the window's own system menu, which is still
                    // the right answer for the rest of the caption.
                    DefWindowProcW(hwnd, msg, wp, lp)
                }
            }

            // The frame resizes; the active child follows and tells the core.
            WM_SIZE => {
                session::mark_dirty();
                tabs::layout(hwnd);
                // The dividers are synced by `layout` itself, from inside it.
                // The grid sign is measured after, so it reads the client rect
                // the child actually ended up with rather than the one it had
                // a moment ago.
                hud::on_frame_resized();
                LRESULT(0)
            }

            // The composition is somewhere else on screen now even though its
            // text did not change. TSF does not come back to ask on its own.
            WM_MOVE => {
                session::mark_dirty();
                ime_layout_changed();
                LRESULT(0)
            }

            // The core's cell-derived floor, expressed to Windows.
            WM_GETMINMAXINFO => {
                tabs::apply_min_max(lp.0 as *mut MINMAXINFO);
                LRESULT(0)
            }

            // Queued tab/window mutations run here, on the thread that owns
            // the windows. See tabs.rs.
            tabs::WM_POLTER_OP => {
                let app = APP.load(Ordering::Acquire);
                let hinst: HINSTANCE = GetModuleHandleW(None).unwrap().into();
                tabs::run_ops(hwnd, app, hinst);
                LRESULT(0)
            }

            // The frame never types. Hand the keyboard to the tab.
            WM_SETFOCUS => {
                tabs::focus_active();
                LRESULT(0)
            }

            WM_DPICHANGED => {
                let dpi = (wp.0 & 0xFFFF) as f64;
                let scale = dpi / 96.0;
                {
                    let mut st = tabs::state();
                    st.scale = scale;
                }
                let s = tabs::active_surface();
                if !s.is_null() {
                    (api().surface_set_content_scale)(s, scale, scale);
                }
                tabs::layout(hwnd);
                logf!("[win] dpi changed -> scale {}", scale);
                LRESULT(0)
            }

            // The global hotkey. It arrives here even when Polter is not the
            // foreground application -- that is the entire point of it, and
            // the reason it is a `RegisterHotKey` and not an accelerator.
            WM_HOTKEY => {
                logf!("[quick] hotkey pressed (foreground={:?})", GetForegroundWindow().0);
                let app = APP.load(Ordering::Acquire);
                let hinst: HINSTANCE = GetModuleHandleW(None).unwrap().into();
                quick::toggle(app, hinst);
                LRESULT(0)
            }

            // **Asked to close, before anything has been destroyed.** The X
            // and Alt+F4 both arrive here; they are one entry point because
            // the user cannot tell them apart either.
            WM_CLOSE => {
                winid::close_requested(hwnd, winid::CloseVia::WindowXOrAltF4);
                DefWindowProcW(hwnd, msg, wp, lp)
            }

            WM_DESTROY => {
                // The count, and whether that count means the process is
                // finished, on one line. Today the answer is always "quit",
                // because there is one window; B1-e is the change that makes
                // the two facts able to disagree.
                // Same point as the other three. Windows has already torn the
                // window down by the time this arrives, so the record is made
                // here rather than earlier -- and `destroyed` is idempotent,
                // so a route that recorded it on the way in is not counted
                // twice.
                winid::window_finished(hwnd);
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Drive a binding by name on the active surface. Returns what the core
/// said: false means it could not parse or could not perform it, and that
/// distinction is worth logging rather than swallowing.
/// Tell the core where the bundled resources are, and say so out loud.
///
/// # Why this has to exist at all
///
/// Four features are read out of one directory -- Poltergeist **plugins**
/// (`App.zig`'s `{resources}/polter/plugins`), **skills**, **themes**, and
/// **shell integration** -- and on Windows the host found none of them.
/// `os/resourcesdir.zig` says it plainly: *an empty resources directory is
/// not an error*. So all four simply did nothing, with no line anywhere
/// saying why, and the eight `provision.ps1` files shipped with the plugins
/// had never once been executed.
///
/// # Two routes, each the other's floor
///
/// `resourcesDir()` finds the directory two ways:
///
///  - **the environment variable**, which is what this function sets; and
///  - **climbing from the executable**, looking for
///    `<dir>/share/terminfo/ghostty.terminfo` and then using
///    `<dir>/share/ghostty`.
///
/// Both are done deliberately. The climb survives somebody copying the build
/// somewhere by hand and never reading our documentation; the variable makes
/// "the host knows where its resources are" a readable line in the log rather
/// than an inference. If one is wrong the other still works, and the log says
/// which one was in play.
///
/// # The variable is not taken at face value by the core
///
/// `resourcesdir.zig` calls `looksLikeOurs()` on it, which tests for one
/// subdirectory: `poltergeist`. **Setting a path that does not pass that test
/// is exactly equivalent to setting nothing**, and the core reports neither.
/// That is why `has_poltergeist` is its own field below rather than folded
/// into a single "looks fine" -- it is the core's own probe, quoted, so a
/// reader can tell "the variable was ignored" from "the variable was used and
/// the directory was thin".
///
/// # And passing that probe does not mean the rest is there
///
/// One subdirectory decides whether the whole directory counts. The other
/// three are reported separately for the same reason: a bundle with
/// `poltergeist/` and nothing else passes the core's check and then fails to
/// produce a single plugin, theme or shell integration -- silently, four
/// times over.
fn announce_resources_dir() {
    // Already set by whoever launched us: leave it, and say we did. A test
    // harness pointing at a build tree is a legitimate reason to override,
    // and silently replacing it would make that impossible to notice.
    if let Ok(v) = std::env::var("POLTER_RESOURCES_DIR") {
        if !v.is_empty() {
            logf!("[res] POLTER_RESOURCES_DIR already set to {:?}; leaving it", v);
            report_resources_dir(std::path::Path::new(&v));
            return;
        }
    }

    // `<exe dir>/../share/ghostty`, which is the layout `zig build` produces
    // (`bin/` beside `share/`) and the one the core's own climb expects.
    let Ok(exe) = std::env::current_exe() else {
        logf!("[res] current_exe() failed; POLTER_RESOURCES_DIR not set, so plugins, skills, themes and shell integration will all be absent");
        return;
    };
    let Some(bin) = exe.parent() else {
        logf!("[res] the executable has no parent directory; POLTER_RESOURCES_DIR not set");
        return;
    };

    // Two candidates, in order. The second is for a flat deployment -- an exe
    // and a `share/` beside it, no `bin/` -- which is how this has actually
    // been put on the test machine, and getting it wrong there would look
    // exactly like getting it wrong everywhere.
    let candidates = [
        bin.join("..").join("share").join("ghostty"),
        bin.join("share").join("ghostty"),
    ];
    for cand in &candidates {
        if cand.join("poltergeist").is_dir() {
            let s = cand.to_string_lossy().into_owned();
            std::env::set_var("POLTER_RESOURCES_DIR", &s);
            logf!("[res] POLTER_RESOURCES_DIR = {:?}", s);
            report_resources_dir(cand);
            return;
        }
    }

    // **Nothing was set, and this says what was looked at.** Setting a path
    // that fails the core's probe is the same as setting nothing, so guessing
    // would buy nothing and would cost the reader this list.
    logf!(
        "[res] no resources directory found next to the executable; POLTER_RESOURCES_DIR left unset. Looked at: {}",
        candidates
            .iter()
            .map(|c| format!("{:?}", c.to_string_lossy()))
            .collect::<Vec<_>>()
            .join(", ")
    );
    logf!(
        "[res] consequence: plugins, skills, themes and shell integration are all unavailable, and none of them reports its own absence"
    );
}

/// One line naming what is actually in the directory.
///
/// **Each of the four is checked separately**, because each is a different
/// feature going quiet and the core reports none of them.
fn report_resources_dir(dir: &std::path::Path) {
    let has = |sub: &str| dir.join(sub).is_dir();
    logf!(
        "[res] exists={} has_poltergeist={} has_shell-integration={} has_polter/plugins={} has_themes={}",
        dir.is_dir(),
        // The core's own probe (`looksLikeOurs`). False here means the
        // variable above is ignored entirely and silently.
        has("poltergeist"),
        has("shell-integration"),
        dir.join("polter").join("plugins").is_dir(),
        has("themes"),
    );
}

/// The config handle, for the settings UI's diagnostics.
pub fn config_handle() -> ffi::Config {
    CONFIG.load(Ordering::Acquire)
}

/// Drive a binding on **a named surface**, rather than on whichever one has
/// focus.
///
/// **`binding` below is the wrong function whenever the caller knows which
/// terminal it means** -- a menu opened on one pane, an action the core asked
/// for on a particular surface. Resolving to the focused surface there is the
/// defect that has now been found five separate times in this port, and it is
/// invisible: with one pane the two are the same, and with two panes the wrong
/// one changes.
pub fn binding_on(surface: ffi::Surface, name: &str) -> bool {
    if surface.is_null() {
        logf!("[action] binding {:?} asked for on a null surface; nothing done", name);
        return false;
    }
    unsafe { (api().surface_binding_action)(surface, name.as_ptr(), name.len()) }
}

pub fn binding(name: &str) -> bool {
    let s = tabs::active_surface();
    if s.is_null() {
        return false;
    }
    unsafe { (api().surface_binding_action)(s, name.as_ptr(), name.len()) }
}

// ------------------------------------------------------------- gl probe

/// The pixel format set on a window's DC, or 0 if none has been set.
///
/// **Why this stands in for a log line inside libghostty.** `wgl.init` must
/// call `SetPixelFormat` on the DC of the HWND it was handed before it can
/// create a context, and a pixel format is a property of that window's DC --
/// so it is readable from here, on this thread, without the core telling us
/// anything. libghostty's own `std.log` does not reach the process stderr on
/// Windows (docs/windows/status.md, section 5.2), so this is the cheapest
/// observation available about whether WGL ever bound to our window at all.
///
/// A format that stays 0 forever means the core never got as far as our HWND.
/// A non-zero one means it did, and the black screen is downstream of that.
fn pixel_format_of(hwnd: HWND) -> i32 {
    use windows::Win32::Graphics::Gdi::{GetDC, ReleaseDC};
    use windows::Win32::Graphics::OpenGL::GetPixelFormat;
    if hwnd.0.is_null() {
        return -1;
    }
    unsafe {
        let hdc = GetDC(Some(hwnd));
        if hdc.is_invalid() {
            return -1;
        }
        let pf = GetPixelFormat(hdc);
        // CS_OWNDC: this is the window's own DC, so releasing it is a no-op
        // and does not disturb the one wgl.zig is holding.
        ReleaseDC(Some(hwnd), hdc);
        pf
    }
}

/// A hint about whether anything has ever been presented into the window.
///
/// Reading a GL window's front buffer through GDI is not guaranteed to work,
/// so this is a hint and not a measurement: **a black answer proves nothing,
/// a non-black answer proves the driver put something there.** It is here
/// because the host has no way to count `SwapBuffers` -- that call lives in
/// `wgl.zig` on the renderer thread -- and "the renderer presented a frame"
/// is otherwise unobservable from this side.
/// The colour at one point of a window's client area.
///
/// **Superseded `center_pixel` as the resize criterion, and the reason is the
/// criterion, not the code.** When a window grows, Windows keeps the old bits
/// and only invalidates what is new -- so the centre shows the *previous*
/// frame whether or not the renderer ever drew at the new size. A criterion
/// read there is blind to exactly the failure it exists to catch: it says
/// "still not black" in both the working case and the broken one.
///
/// The centre is still logged, because "the whole thing went black" is a
/// different failure and that is where it shows.
fn pixel_at(hwnd: HWND, x: i32, y: i32) -> u32 {
    use windows::Win32::Graphics::Gdi::{GetDC, GetPixel, ReleaseDC};
    if hwnd.0.is_null() {
        return 0xFFFF_FFFF;
    }
    unsafe {
        let hdc = GetDC(Some(hwnd));
        if hdc.is_invalid() {
            return 0xFFFF_FFFF;
        }
        let p = GetPixel(hdc, x, y);
        ReleaseDC(Some(hwnd), hdc);
        p.0
    }
}

/// A point inside the new client area that was **outside the old one**.
///
/// Those pixels cannot have come from the previous frame under any
/// preservation scheme, so a colour read there is a statement about the new
/// size and nothing else.
///
/// A fixed corner would not do: the top-right is newly exposed only when the
/// *width* grew, and a resize that only grows the height would be checked at
/// a point the old canvas still covers -- the same blindness, moved.
/// `None` means nothing grew, and then there is no such point and the
/// criterion does not apply.
fn newly_exposed_point(old: (i32, i32), new: (i32, i32)) -> Option<(i32, i32)> {
    let (ow, oh) = old;
    let (nw, nh) = new;
    // A few pixels in from the edge: window borders and rounding can put the
    // very last column somewhere that is nobody's canvas.
    const INSET: i32 = 4;
    if nw > ow + INSET * 2 {
        Some((ow + (nw - ow) / 2, (nh / 2).max(INSET)))
    } else if nh > oh + INSET * 2 {
        Some(((nw / 2).max(INSET), oh + (nh - oh) / 2))
    } else {
        None
    }
}

#[cfg(test)]
mod resize_criterion_tests {
    use super::newly_exposed_point;

    /// The property, not the formula: whatever point comes back must be
    /// somewhere the old canvas could not have painted.
    fn assert_outside(old: (i32, i32), new: (i32, i32)) {
        let (x, y) = newly_exposed_point(old, new).expect("something grew, so a point exists");
        assert!(
            x >= old.0 || y >= old.1,
            "point ({x},{y}) is inside the old {}x{} -- the old canvas covers it",
            old.0,
            old.1
        );
        assert!(x < new.0 && y < new.1, "point ({x},{y}) is outside the new {new:?}");
    }

    #[test]
    fn a_wider_window_is_probed_in_the_new_column() {
        assert_outside((984, 631), (1224, 631));
    }

    /// The case a fixed top-right corner would get wrong: the width did not
    /// change, so every x is still covered by the old canvas and only a large
    /// y is new.
    #[test]
    fn a_taller_window_is_probed_in_the_new_row() {
        assert_outside((984, 631), (984, 820));
        let (_, y) = newly_exposed_point((984, 631), (984, 820)).unwrap();
        assert!(y >= 631, "a height-only growth must be probed below the old bottom");
    }

    #[test]
    fn growing_both_ways_still_lands_outside() {
        assert_outside((984, 631), (1224, 820));
    }

    #[test]
    fn nothing_grew_has_no_point() {
        assert_eq!(newly_exposed_point((984, 631), (984, 631)), None);
        assert_eq!(newly_exposed_point((984, 631), (800, 500)), None);
    }

    /// A growth of a pixel or two is inside the border inset, and a point
    /// there says more about window chrome than about the renderer.
    #[test]
    fn a_growth_smaller_than_the_inset_does_not_count() {
        assert_eq!(newly_exposed_point((984, 631), (988, 631)), None);
        assert_eq!(newly_exposed_point((984, 631), (984, 635)), None);
    }
}

fn center_pixel(hwnd: HWND) -> u32 {
    use windows::Win32::Graphics::Gdi::{GetDC, GetPixel, ReleaseDC};
    if hwnd.0.is_null() {
        return 0xFFFF_FFFF;
    }
    unsafe {
        let mut rc = RECT::default();
        if GetClientRect(hwnd, &mut rc).is_err() {
            return 0xFFFF_FFFF;
        }
        let hdc = GetDC(Some(hwnd));
        if hdc.is_invalid() {
            return 0xFFFF_FFFF;
        }
        let p = GetPixel(hdc, (rc.right - rc.left) / 2, (rc.bottom - rc.top) / 2);
        ReleaseDC(Some(hwnd), hdc);
        p.0
    }
}

/// One-time detail once a format shows up: enough to say whether it is the
/// hardware, double-buffered, OpenGL format the renderer asked for.
fn log_pixel_format(hwnd: HWND, pf: i32) {
    use windows::Win32::Graphics::Gdi::{GetDC, ReleaseDC};
    use windows::Win32::Graphics::OpenGL::{DescribePixelFormat, PIXELFORMATDESCRIPTOR};
    unsafe {
        let hdc = GetDC(Some(hwnd));
        if hdc.is_invalid() {
            return;
        }
        let mut pfd = PIXELFORMATDESCRIPTOR::default();
        let n = DescribePixelFormat(
            hdc,
            pf,
            std::mem::size_of::<PIXELFORMATDESCRIPTOR>() as u32,
            Some(&mut pfd),
        );
        ReleaseDC(Some(hwnd), hdc);
        if n == 0 {
            logf!("[gl] pixel format {} set, but DescribePixelFormat failed", pf);
            return;
        }
        // 0x04 PFD_DRAW_TO_WINDOW, 0x20 PFD_SUPPORT_OPENGL, 0x100 PFD_DOUBLEBUFFER
        logf!(
            "[gl] pixel format {} on {:?}: flags=0x{:x} (window={} opengl={} double={}) color={} depth={}",
            pf,
            hwnd.0,
            pfd.dwFlags.0,
            pfd.dwFlags.0 & 0x04 != 0,
            pfd.dwFlags.0 & 0x20 != 0,
            pfd.dwFlags.0 & 0x100 != 0,
            pfd.cColorBits,
            pfd.cDepthBits
        );
    }
}

// -------------------------------------------------------------------- main

fn load_api() -> Option<Api> {
    unsafe {
        let internal = LoadLibraryA(s!("ghostty-internal.dll")).ok()?;
        logf!("LoadLibrary ghostty-internal.dll -> ok");
        let vt = LoadLibraryA(s!("ghostty-vt.dll")).ok()?;
        logf!("LoadLibrary ghostty-vt.dll -> ok");

        macro_rules! sym {
            ($lib:expr, $name:literal) => {{
                let p = GetProcAddress($lib, s!($name));
                if p.is_none() {
                    logf!("FATAL missing symbol {}", $name);
                    return None;
                }
                std::mem::transmute(p.unwrap())
            }};
        }

        Some(Api {
            init: sym!(internal, "ghostty_init"),
            config_new: sym!(internal, "ghostty_config_new"),
            info: sym!(internal, "ghostty_info"),
            config_open_path: sym!(internal, "ghostty_config_open_path"),
            string_free: sym!(internal, "ghostty_string_free"),
            config_diagnostics_count: sym!(internal, "ghostty_config_diagnostics_count"),
            config_get_diagnostic: sym!(internal, "ghostty_config_get_diagnostic"),
            config_get: sym!(internal, "ghostty_config_get"),
            config_load_default_files: sym!(internal, "ghostty_config_load_default_files"),
            config_finalize: sym!(internal, "ghostty_config_finalize"),
            app_new: sym!(internal, "ghostty_app_new"),
            app_tick: sym!(internal, "ghostty_app_tick"),
            surface_config_new: sym!(internal, "ghostty_surface_config_new"),
            surface_new: sym!(internal, "ghostty_surface_new"),
            surface_draw: sym!(internal, "ghostty_surface_draw"),
            surface_set_size: sym!(internal, "ghostty_surface_set_size"),
            surface_set_content_scale: sym!(internal, "ghostty_surface_set_content_scale"),
            surface_set_focus: sym!(internal, "ghostty_surface_set_focus"),
            surface_free: sym!(internal, "ghostty_surface_free"),
            surface_binding_action: sym!(internal, "ghostty_surface_binding_action"),
            surface_complete_clipboard_request: sym!(
                internal,
                "ghostty_surface_complete_clipboard_request"
            ),
            surface_key: sym!(internal, "ghostty_surface_key"),
            surface_text: sym!(internal, "ghostty_surface_text"),
            surface_preedit: sym!(internal, "ghostty_surface_preedit"),
            surface_ime_point: sym!(internal, "ghostty_surface_ime_point"),
            codepoint_width: sym!(vt, "ghostty_unicode_codepoint_width"),
            grapheme_width: sym!(vt, "ghostty_unicode_grapheme_width"),
        })
    }
}

fn main() {
    let _ = std::fs::remove_file(log_path());
    logf!(
        "=== Polter host (Windows) === pid={} log={}",
        std::process::id(),
        log_path().display()
    );

    if std::env::args().any(|a| a == "--draw-on-paint") {
        DRAW_ON_PAINT.store(1, Ordering::Relaxed);
        logf!("NOTE: --draw-on-paint enabled (main-thread draw; see status.md)");
    }

    log_build_identity();

    let api_box = match load_api() {
        Some(a) => Box::leak(Box::new(a)),
        None => {
            logf!("FATAL could not load libghostty");
            return;
        }
    };
    API.store(api_box as *mut Api as *mut c_void, Ordering::Release);

    unsafe {
        // Proves ghostty-vt.dll is not merely loaded but callable, and that
        // the width table the IME needs is reachable from here.
        // U+4F60 (你) must be 2 cells; 'A' must be 1.
        let wide = (api_box.codepoint_width)(0x4F60);
        let narrow = (api_box.codepoint_width)(0x41);
        logf!(
            "vt width table: U+4F60 -> {} cells, 'A' -> {} cells",
            wide, narrow
        );
    }

    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    // **Turn on libghostty's own logging before initialising it.**
    //
    // `docs/windows/status.md` carried this as a debt -- "libghostty's log is
    // invisible on the test machine, so every real-machine failure costs a
    // guess" -- and it was promoted to a blocker the moment a hang landed
    // *inside* `ghostty_surface_free`, where the only thing that can say what
    // it is waiting on is the core itself.
    //
    // It turns out not to need any change to the core. `global.zig` reads
    // `GHOSTTY_LOG` and parses it into `GlobalState.Logging`, whose `stderr`
    // field **defaults to false for lib artifacts** (`app_runtime == .none`)
    // and whose only other sink is macOS unified logging -- which on Windows
    // leaves no sink at all. Setting the variable turns stderr back on, and
    // this host is a console subsystem binary, so stderr is the same stream
    // the log file already captures.
    //
    // An existing value is left alone: whoever set it meant it.
    match std::env::var("GHOSTTY_LOG") {
        Ok(v) => logf!("GHOSTTY_LOG already set to {:?}; leaving it", v),
        Err(_) => {
            std::env::set_var("GHOSTTY_LOG", "stderr");
            logf!("GHOSTTY_LOG=stderr (core logging to this process's stderr)");
        }
    }

    // **Before `ghostty_init`, because the core reads it during startup.**
    announce_resources_dir();

    // ghostty_init takes (argc, argv); argv is a non-optional pointer on the
    // Zig side, so hand it a real one rather than null.
    let arg0 = CString::new("polter-host.exe").unwrap();
    let argv: [*const std::os::raw::c_char; 2] = [arg0.as_ptr(), std::ptr::null()];
    let rc = unsafe { (api_box.init)(1, argv.as_ptr()) };
    logf!("ghostty_init -> {}", rc);
    if rc != 0 {
        logf!("FATAL ghostty_init failed");
        return;
    }

    let config = unsafe {
        let c = (api_box.config_new)();
        (api_box.config_load_default_files)(c);
        (api_box.config_finalize)(c);
        c
    };
    CONFIG.store(config, Ordering::Release);
    logf!("config ready ({:?})", config);

    let rt = RuntimeConfig {
        userdata: std::ptr::null_mut(),
        supports_selection_clipboard: false,
        wakeup_cb: cb_wakeup,
        action_cb: cb_action,
        read_clipboard_cb: cb_read_clipboard,
        confirm_read_clipboard_cb: cb_confirm_read_clipboard,
        write_clipboard_cb: cb_write_clipboard,
        close_surface_cb: cb_close_surface,
    };

    let app = unsafe { (api_box.app_new)(&rt, config) };
    if app.is_null() {
        logf!("FATAL ghostty_app_new returned null");
        return;
    }
    APP.store(app, Ordering::Release);
    logf!("ghostty_app_new -> {:?}", app);

    // ---- windows ----
    //
    // Two classes. The frame owns the tab strip and the window state; each tab
    // is a child of the frame and owns exactly one surface. CS_OWNDC lives on
    // the *surface* class, because that is the window wgl.zig takes and keeps
    // a DC for (Contract 1).
    let hinst: HINSTANCE = unsafe { GetModuleHandleW(None).unwrap().into() };

    let frame_class = w!("PolterHost");
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wndproc),
        hInstance: hinst,
        lpszClassName: frame_class,
        hbrBackground: HBRUSH(std::ptr::null_mut()),
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW).unwrap_or_default() },
        ..Default::default()
    };
    if unsafe { RegisterClassExW(&wc) } == 0 {
        logf!("FATAL RegisterClassExW(frame) failed");
        return;
    }

    let surf_class = w!("PolterSurface");
    let wc2 = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        // Contract 1: per-window DC, because wgl.zig keeps the HDC.
        style: CS_OWNDC | CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(tabs::surface_wndproc),
        hInstance: hinst,
        lpszClassName: surf_class,
        // Contract 2 (belt and braces): no class background brush at all.
        hbrBackground: HBRUSH(std::ptr::null_mut()),
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW).unwrap_or_default() },
        ..Default::default()
    };
    if unsafe { RegisterClassExW(&wc2) } == 0 {
        logf!("FATAL RegisterClassExW(surface) failed");
        return;
    }

    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            frame_class,
            w!("Polter"),
            // **WS_CLIPCHILDREN is load-bearing now.** The frame paints its
            // own content area (see strip::paint), and without this it would
            // paint straight over the panes -- children are only excluded
            // from a parent's drawing when the parent says so.
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1000,
            700,
            None,
            None,
            Some(hinst),
            None,
        )
    }
    .expect("CreateWindowExW");
    HWND_G.store(hwnd.0 as *mut c_void, Ordering::Release);
    logf!("frame hwnd = {:?}", hwnd.0);

    shell::init_frame(hwnd);

    let dpi = unsafe { GetDpiForWindow(hwnd) } as f64;
    let scale = if dpi > 0.0 { dpi / 96.0 } else { 1.0 };
    logf!("dpi={} scale={}", dpi, scale);
    {
        let mut st = tabs::state();
        st.frame = hwnd.0 as isize;
        st.scale = scale;
    }

    // A static prompt cannot distinguish "renderer still drawing" from
    // "renderer frozen" -- Windows blits the client area during a move either
    // way. --clock types a ticking clock into the shell so the screen has
    // something that visibly advances.
    if std::env::args().any(|a| a == "--clock") {
        tabs::set_initial_input(
            "powershell -NoProfile -Command \"while($true){Get-Date -Format HH:mm:ss.fff; \
             Start-Sleep -Milliseconds 250}\"\r\n",
        );
        logf!("--clock: the first tab will run a ticking clock");
    }

    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
    }
    // **Before anything else mentions it.** `winid::of` would name this window
    // the first time some other line talked about it, which is enough for
    // reading a log and not enough for counting: the shutdown rule turns on
    // how many windows exist, and a window that has not logged yet does not
    // exist to a lazy registry.
    winid::created(hwnd);

    // ---- put the window back where it was
    //
    // **After `ShowWindow`, because the geometry is only read while the window
    // is visible** -- and the same rule applies to writing it, so restoring
    // into a hidden window would be saved back as nothing.
    //
    // The two halves are gated separately, the way `LastWindowPosition` does
    // it: a person who wrote `window-position-x` into their config asked for
    // that position every launch, and handing them the place they dragged it
    // to last time is not what they asked for. **`config_get` returning false
    // is the "they did not set it" signal** -- `?i16` reports false when null.
    {
        let mut px: i16 = 0;
        let key = "window-position-x";
        let has_x = unsafe {
            (api().config_get)(config, &mut px as *mut i16 as *mut c_void, key.as_ptr(), key.len())
        };
        let mut py: i16 = 0;
        let key = "window-position-y";
        let has_y = unsafe {
            (api().config_get)(config, &mut py as *mut i16 as *mut c_void, key.as_ptr(), key.len())
        };
        // **The size half cannot use `initial_size`, and the reason is a
        // one-way implication.** `Surface.zig:2017` returns early unless
        // *both* `window-width` and `window-height` are set, so the action
        // never arrives for someone who configured only the width -- and
        // reading its absence as "no size configured" would then let the
        // remembered size overwrite the half they did configure. "The action
        // came, so they set it" is true; "the action did not come, so they
        // did not" is not.
        //
        // So both are read here, the same way the position is. **The test is
        // the value, not the return, and that difference is not an
        // inconsistency**: `window-width` is `u32 = 0` and always readable, so
        // 0 is its "unset" -- a zero-wide window is not a thing anyone asks
        // for. `window-position-x` is `?i16`, where 0 is a position somebody
        // may well want, so there the *return value* is the only honest
        // signal.
        let mut cw: u32 = 0;
        let key = "window-width";
        let _ = unsafe {
            (api().config_get)(config, &mut cw as *mut u32 as *mut c_void, key.as_ptr(), key.len())
        };
        let mut ch: u32 = 0;
        let key = "window-height";
        let _ = unsafe {
            (api().config_get)(config, &mut ch as *mut u32 as *mut c_void, key.as_ptr(), key.len())
        };
        let configured_size = cw != 0 || ch != 0;
        wlogf!(hwnd, 
            "[session] config: window-position set={} ({},{}), window-size set={} ({}x{}), \
             initial_size seen={}",
            has_x || has_y,
            px,
            py,
            configured_size,
            cw,
            ch,
            tabs::state().initial.is_some()
        );
        session::restore(hwnd, !(has_x || has_y), !configured_size);
    }

    // Before the first tab, because the first tab can be closed. `reopen.rs`
    // keeps the stack and `tabs.rs` builds the tabs; this is the one line
    // where the two are introduced.
    tabs::install_reopen_opener();
    logf!("[reopen] opener installed; stack {:?}", reopen::stack_depth());

    // ---- first tab ----
    if !tabs::create_tab(hwnd, app, hinst) {
        logf!("FATAL could not create the first tab");
        return;
    }
    tabs::layout(hwnd);
    logf!("tab count = {}", tabs::count());

    // TSF is stood up against the first tab's window; every later tab is
    // associated with the same document manager as it is created.
    let first = tabs::active_hwnd();
    if !first.0.is_null() && ime_init(first) {
        logf!("[ime] TSF up; switch to a Chinese IME and type");
        unsafe {
            let _ = SetFocus(Some(first));
        }
    } else {
        logf!("[ime] TSF init FAILED -- terminal still works, IME does not");
    }

    // The self-test drives the same entry point the accelerators do, so a
    // green run is evidence about the action path, not about the keyboard.
    // Each step logs observable state before and after, so the log alone
    // says whether the window actually changed -- "returned true" is not
    // the same claim as "the window moved".
    // `--striptest`: the tab strip drives itself and prints what it did.
    // See `strip::script_step`.
    let striptest = std::env::args().any(|a| a == "--striptest");
    let mut strip_step = 0usize;
    let mut strip_running = striptest;
    if striptest {
        logf!("--striptest: the strip will exercise itself, one step per ~0.6s");
    }

    // `--qttest`: the quick terminal drops in and out on its own, printing
    // the monitor and the work area it chose alongside the result.
    let qttest = std::env::args().any(|a| a == "--qttest");
    let mut qt_step = 0usize;
    let mut qt_running = qttest;
    if qttest {
        logf!("--qttest: the quick terminal will exercise itself");
    }

    // `--write-settings-fixture <path>`: emit the file the Zig test reads, from
    // the product's own writer, and exit. **The fixture has to come out of the
    // shipped binary**; one generated by a copy of the code proves the copy.
    {
        let mut args = std::env::args();
        while let Some(a) = args.next() {
            if a == "--write-settings-fixture" {
                let path = args.next().unwrap_or_default();
                let ok = plugins::write_fixture(&path);
                std::process::exit(if ok { 0 } else { 1 });
            }
        }
    }

    let selftest = std::env::args().any(|a| a == "--selftest");
    // Stops the script once it has finished. **Not a tidiness fix.** Without
    // it the last step's "after" line reprints every tick forever, and then
    // "stuck on step N" and "finished step N and idle" look identical at the
    // tail of the log -- which is the one question this script exists to
    // answer. `--striptest` says `striptest done`; this now does the same.
    let mut selftest_running = selftest;
    let script: &[(&str, &str)] = &[
        ("new_tab", "expect tab count 1 -> 2"),
        ("new_tab", "expect tab count 2 -> 3"),
        ("goto_tab:1", "expect active -> 1"),
        ("next_tab", "expect active -> 2"),
        ("move_tab:1", "expect active tab shifts right"),
        ("toggle_maximize", "expect IsZoomed false -> true"),
        ("toggle_maximize", "expect IsZoomed true -> false"),
        ("toggle_fullscreen", "expect style loses WS_OVERLAPPEDWINDOW"),
        ("toggle_fullscreen", "expect style restored"),
        ("copy_title_to_clipboard", "expect clipboard = active tab title"),
        // The read-only badge has no key of its own: the core ships no default
        // bind for `toggle_readonly` and it is not in the host accelerator
        // table either, so this script is the only way it gets exercised
        // without a hand-written config. Two steps, because "the badge came
        // up" and "the badge went away again" are different claims and the
        // second one is the one a stuck overlay would fail.
        ("toggle_readonly", "expect a [hud] readonly on line"),
        ("toggle_readonly", "expect a [hud] readonly off line"),
        ("close_tab:this", "expect tab count 3 -> 2"),
    ];
    let mut step = 0usize;
    if selftest {
        logf!("--selftest: {} steps, one per second", script.len());
    }

    // After the frame exists, so the palette can centre on it, and after the
    // config exists, so it has commands to show.
    palette::init(hinst, config);
    // The quick terminal, and the global hotkey that reaches it when Polter
    // is not the foreground application. Created hidden; the hotkey is
    // registered on the frame, which is where WM_HOTKEY will arrive.
    quick::init(hinst, config, hwnd);
    search::init(hinst);
    keyseq::init(hinst);
    hud::init(hinst);
    divider::init(hinst);
    settings_ui::init(hinst);
    // A config that failed to parse is the one thing worth interrupting a
    // start-up for: the terminal comes up looking normal and behaving like a
    // default install, with the reason only in a log nobody opened.
    settings_ui::request_errors();

    start_watchdog();
    logf!("entering message loop; renderer thread drives redraw");

    // ---- loop ----
    //
    // Two things have to happen here that a plain PeekMessage loop does not do,
    // and neither of them fails visibly -- the symptom of missing either is
    // "the IME looks switched on but nothing composes", or a key dropped now
    // and then while typing:
    //
    //  1. Pump through `ITfMessagePump`, so TSF sees the queue.
    //  2. Offer WM_KEY* to `ITfKeystrokeMgr` first, and stop if it takes them.
    //
    // Falls back to the plain pump if TSF never came up, so a broken IME still
    // leaves a usable terminal.
    use windows::Win32::UI::TextServices::{ITfKeystrokeMgr, ITfMessagePump};
    let pump: Option<ITfMessagePump> =
        IME.with(|c| c.borrow().as_ref().and_then(|st| st.thread_mgr.cast().ok()));
    let keystrokes: Option<ITfKeystrokeMgr> =
        IME.with(|c| c.borrow().as_ref().and_then(|st| st.thread_mgr.cast().ok()));

    // `--selfresize`: five seconds in, resize the frame once, from the host
    // itself, and log the centre pixel before and after.
    //
    // The open question is whether a resize *after* the context was built is
    // followed by the renderer -- the constraint in development.md 5.2 says
    // the window must already be its final size at `surface_new`, but not why.
    // If resizes are simply not followed, then dragging a window edge breaks
    // the terminal, which is a far worse defect than an init-time rule.
    //
    // Doing it from inside removes the two things that made this unmeasurable
    // by hand: mouse coordinates (two coordinate systems, one wrong click) and
    // a screenshot as the read-out. A black terminal after the resize shows up
    // here as `center_pixel` going to 0x000000, which is a number in a log.
    let selfresize = std::env::args().any(|a| a == "--selfresize");
    // The size before the resize, so the "after" step can work out which part
    // of the window is new. Kept here rather than re-measured because by then
    // the old size is gone.
    let mut resize_before: Option<(i32, i32)> = None;
    if selfresize {
        logf!("--selfresize: the host will resize its own window once, at ~5s");
    }

    let mut msg = MSG::default();
    let mut ticks: u64 = 0;
    let mut pf_logged = false;
    'outer: loop {
        unsafe {
            loop {
                let got = match &pump {
                    Some(p) => {
                        let mut ok = windows::core::BOOL(0);
                        p.PeekMessageW(
                            &mut msg,
                            HWND(std::ptr::null_mut()),
                            0,
                            0,
                            PM_REMOVE.0,
                            &mut ok,
                        )
                        .is_ok()
                            && ok.0 != 0
                    }
                    None => PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool(),
                };
                if !got {
                    break;
                }
                if msg.message == WM_QUIT {
                    break 'outer;
                }

                let mut eaten = false;
                if let Some(k) = &keystrokes {
                    match msg.message {
                        WM_KEYDOWN | WM_SYSKEYDOWN => {
                            if k.TestKeyDown(msg.wParam, msg.lParam)
                                .map(|b| b.as_bool())
                                .unwrap_or(false)
                            {
                                eaten = k
                                    .KeyDown(msg.wParam, msg.lParam)
                                    .map(|b| b.as_bool())
                                    .unwrap_or(false);
                            }
                        }
                        WM_KEYUP | WM_SYSKEYUP => {
                            if k.TestKeyUp(msg.wParam, msg.lParam)
                                .map(|b| b.as_bool())
                                .unwrap_or(false)
                            {
                                eaten = k
                                    .KeyUp(msg.wParam, msg.lParam)
                                    .map(|b| b.as_bool())
                                    .unwrap_or(false);
                            }
                        }
                        _ => {}
                    }
                }
                // A key TSF takes is never dispatched, so the surface window
                // never sees it and `keys.rs` cannot log it. This is the only
                // place that can tell "the core declined the key" apart from
                // "the core was never offered the key", and those two have the
                // same symptom: nothing happens.
                if eaten {
                    let n = TSF_ATE.fetch_add(1, Ordering::Relaxed) + 1;
                    if n <= 40 {
                        logf!(
                            "[key] TSF ate msg=0x{:x} vk=0x{:02x} (not dispatched)",
                            msg.message,
                            msg.wParam.0 as u16
                        );
                    }
                } else {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
            (api_box.app_tick)(app);
        }
        ticks += 1;
        TICKS.store(ticks, Ordering::Relaxed);

        // One self-test step per ~1.2s, starting after 2s so the first
        // surface has settled.
        if selftest_running && ticks > 250 && ticks % 150 == 0 && step < script.len() {
            let (act, expect) = script[step];
            step += 1;
            let zoomed = unsafe { IsZoomed(hwnd).as_bool() };
            let style = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) } as u32;
            logf!(
                "[selftest {}/{}] {:?} -- {}  (before: tabs={} active={} zoomed={} style=0x{:x})",
                step,
                script.len(),
                act,
                expect,
                tabs::count(),
                tabs::active_index() + 1,
                zoomed,
                style
            );
            let ok = binding(act);
            logf!(
                "[selftest {}/{}] binding_action returned {}",
                step,
                script.len(),
                ok
            );
        }
        // The state *after* the queued op has run, one second later.
        if selftest_running && ticks > 250 && ticks % 150 == 75 && step > 0 {
            let zoomed = unsafe { IsZoomed(hwnd).as_bool() };
            let style = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) } as u32;
            logf!(
                "[selftest {}/{}] after: tabs={} active={} zoomed={} style=0x{:x}",
                step,
                script.len(),
                tabs::count(),
                tabs::active_index() + 1,
                zoomed,
                style
            );
            if step == script.len() {
                logf!("[selftest] selftest done -- {} steps executed", step);
                selftest_running = false;
            }
        }

        if selfresize && ticks == 625 {
            let sw = tabs::active_hwnd();
            let mut rc = RECT::default();
            unsafe {
                let _ = GetClientRect(sw, &mut rc);
            }
            resize_before = Some((rc.right - rc.left, rc.bottom - rc.top));
            logf!(
                "[resize] before: surface client {}x{} center_pixel=0x{:06x}",
                rc.right - rc.left,
                rc.bottom - rc.top,
                center_pixel(sw)
            );
            unsafe {
                let _ = SetWindowPos(hwnd, None, 0, 0, 1240, 820, SWP_NOMOVE | SWP_NOZORDER);
            }
            logf!("[resize] frame SetWindowPos -> 1240x820 issued");
        }
        if selfresize && ticks == 750 {
            let sw = tabs::active_hwnd();
            let mut rc = RECT::default();
            unsafe {
                let _ = GetClientRect(sw, &mut rc);
            }
            let new = (rc.right - rc.left, rc.bottom - rc.top);
            logf!(
                "[resize] after: surface client {}x{} center_pixel=0x{:06x}",
                new.0,
                new.1,
                center_pixel(sw)
            );

            // **The criterion.** The centre above says whether the window went
            // black; this says whether anything was drawn at the new size at
            // all, which is the thing the centre cannot see.
            match resize_before.and_then(|old| newly_exposed_point(old, new).map(|p| (old, p))) {
                Some((old, (px, py))) => {
                    let c = pixel_at(sw, px, py);
                    logf!(
                        "[resize] new-region pixel at ({},{}) = 0x{:06x}  (was outside {}x{}; \
                         0x000000 means nothing was drawn there)",
                        px,
                        py,
                        c,
                        old.0,
                        old.1
                    );
                }
                None => logf!(
                    "[resize] nothing grew ({:?} -> {:?}); the new-region criterion does not apply",
                    resize_before,
                    new
                ),
            }
        }

        // One striptest step per ~0.6s, starting after 2s so the first
        // surface has settled. Slow enough that each step's messages are
        // pumped before the next one runs -- which matters, because the
        // question being asked is whether a repaint happened.
        if qt_running && ticks > 250 && ticks % 100 == 0 {
            let hinst: HINSTANCE = unsafe { GetModuleHandleW(None).unwrap().into() };
            qt_running = quick::script_step(app, hinst, qt_step);
            qt_step += 1;
        }

        if strip_running && ticks > 250 && ticks % 75 == 0 {
            strip_running = strip::script_step(hwnd, strip_step);
            strip_step += 1;
        }

        // ~1s at 8ms/iteration. This is the *main thread's* pulse: if a
        // nested modal loop (window move/size) blocks the pump, these lines
        // stop appearing, which is exactly the condition we want to observe.
        // Twice a second: often enough that a kill a moment after a drag still
        // has the new position, rare enough that dragging a window is not a
        // write per frame.
        if ticks % 62 == 0 {
            session::flush_if_dirty(hwnd);
        }

        if ticks % 125 == 0 {
            let sw = tabs::active_hwnd();
            let pf = pixel_format_of(sw);
            if pf > 0 && !pf_logged {
                pf_logged = true;
                log_pixel_format(sw, pf);
            }
            logf!(
                "[loop] pid={} main-thread alive, ticks={} main_thread_paints={} \
                 surface_pixel_format={} center_pixel=0x{:06x}",
                unsafe { windows::Win32::System::Threading::GetCurrentProcessId() },
                ticks,
                PAINTS.load(Ordering::Relaxed),
                pf,
                center_pixel(sw)
            );
        }
        // ---- P-1: every window's state line, at a moment the tester picks
        //
        // **A file, not a hotkey and not a timer.** A timer prints each
        // window's line whenever that window happens to change, and comparing
        // two such lines is comparing two different moments -- which is the
        // one thing this reading must not do, since the question is whether
        // one window moved while the other did not. A hotkey would go through
        // the key path, and the key path is where this port's injector is
        // blind. A sentinel file is a trigger the tester holds: write it, and
        // the next tick prints one line per window and deletes it.
        if ticks % 12 == 0 {
            if let Some(mark) = dumpstate_path() {
                if mark.exists() {
                    let _ = std::fs::remove_file(&mark);
                    let wins = winid::all();
                    // process-wide: the dump spans every window, so it belongs
                    // to none of them; the per-window lines follow it
                    plogf!("[dump] state of {} window(s), taken at one instant", wins.len());
                    for w in wins {
                        strip::log_state(w, "dump");
                    }
                }
            }
        }

        std::thread::sleep(std::time::Duration::from_millis(8));
    }

    // ---- P-3: what leaving actually did, once, and only when leaving
    //
    // **Printed after the message loop, which is the only place that means
    // "really exiting".** A line printed next to `PostQuitMessage` would be
    // printed by every path that asks to quit, including the ones B1-e is
    // about to make not quit.
    let open_tabs = tabs::count();
    session::flush_if_dirty(hwnd);
    // process-wide: the process is leaving; by this point no window is left
    // for the line to be about
    plogf!("[main] exiting: session flushed, {} tabs were open", open_tabs);
}


#[cfg(test)]
mod wd_tests {
    use super::*;

    /// **The buffer and the line it must hold, connected.**
    ///
    /// The two numbers used to sit apart -- a 256-byte buffer and a line that
    /// happened to be about 234 bytes -- with nothing between them but the
    /// arithmetic somebody did once. This builds the line with every number at
    /// its widest, so a new field, or a longer phrase, fails here instead of
    /// quietly losing the end of the alarm.
    #[test]
    fn alarm_line_fits() {
        let l = blocked_line(u64::MAX, u64::MAX, u64::MAX, u64::MAX, u64::MAX, u64::MAX);
        assert!(
            !l.truncated,
            "the alarm line no longer fits in Line::CAP ({} bytes); it needs {}+",
            Line::CAP,
            l.n
        );
    }

    /// The flag is not decorative: prove it turns on.
    #[test]
    fn truncation_is_reported() {
        let mut l = Line::new();
        for _ in 0..Line::CAP + 1 {
            l.s("x");
        }
        assert!(l.truncated);
    }
}
