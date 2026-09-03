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

//! # Why this is a GUI subsystem binary
//!
//! **A console subsystem binary launched from Explorer is given a console
//! window by Windows, and nobody asked for it.** That window was Polter's
//! second window: it opened beside the terminal and scrolled, because
//! `log_line` printed every line to stdout and `GHOSTTY_LOG=stderr` sent
//! libghostty's own log to the same place. It is a black box a user cannot
//! close without killing the program.
//!
//! **The debug build carries the same attribute, and that is deliberate.**
//! The obvious concession -- hide it in release, keep it in debug -- makes the
//! debug build differ from the shipped one *on exactly the axis being fixed*:
//! whether this process has a console decides whether a console child
//! (a `.ps1` plugin) inherits ours or is given a window of its own. A build
//! that cannot reproduce the defect cannot be used to verify the repair.
//!
//! **What a console was carrying, and where each part went instead.** Nothing
//! here may quietly become "no output":
//!
//!  - `log_line`'s stdout copy: **deleted**. The file copy was always the one
//!    this program trusts (flushed per line; it is the artifact that leaves
//!    the machine), and the stdout copy also took Rust's global stdout lock on
//!    a path the watchdog must never block on -- see `wd_log`.
//!  - libghostty's log, which on Windows has **no sink but stderr**
//!    (`global.zig` parses `GHOSTTY_LOG` into a struct whose only other field
//!    is macOS unified logging): `adopt_std_handles` gives stderr a real file
//!    when Windows gave us nothing, so those lines keep landing in the log.
//!  - the default panic hook's backtrace, which also goes to stderr: same
//!    answer, and that is why `adopt_std_handles` runs *before*
//!    `install_panic_hook`.
//!
//! **What this does cost**: a `+action` run by hand from a terminal
//! (`polter-host.exe +chat`) no longer paints on that terminal -- a GUI
//! subsystem process does not attach to the console that started it. A
//! `+mcp` server started by an agent CLI is unaffected, because there the
//! stdio handles are inherited pipes rather than a console. Giving the CLI
//! path its console back means `AttachConsole(ATTACH_PARENT_PROCESS)` and is
//! deliberately not done here; it is its own change with its own reading.
#![windows_subsystem = "windows"]

mod ctxmenu;
mod divider;
mod dnd;
mod ffi;
mod keys;
mod hud;
mod keyseq;
mod menu;
mod mouse;
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
mod theme;
mod tsf;
mod uia;

use ffi::*;
use std::cell::RefCell;
use std::ffi::{c_void, CString};
use std::rc::Rc;
use std::sync::atomic::{AtomicPtr, AtomicU32, AtomicU64, Ordering};

use windows::core::{s, w, Interface, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{InvalidateRect, HBRUSH};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, GetModuleHandleW, GetProcAddress, LoadLibraryA,
};
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

// ------------------------------------------------ are these two a pair?

/// The commit this host was built from, or empty when git could not say.
/// Stamped by `build.rs`.
pub const HOST_COMMIT: &str = env!("POLTER_HOST_COMMIT");
/// `"1"` when the host's tree had uncommitted changes at build time.
pub const HOST_DIRTY: &str = env!("POLTER_HOST_DIRTY");

/// The core's own fallback when git was unavailable to *it*
/// (`src/build/Config.zig`). It is a real-looking hex string and means
/// "unknown", so it must never take part in a comparison.
const CORE_UNKNOWN: &str = "0000000";

/// What the version string the core reports says about which tree it came
/// from, or `None`.
///
/// The core reports something like `1.3.2-HEAD-+1fe09f51b`: a semantic
/// version whose build metadata is the short commit. **This parses somebody
/// else's format**, which is the one genuinely fragile step in this check --
/// so every way of failing lands in `None`, and `None` is neither a match nor
/// a mismatch.
fn core_commit(version: &str) -> Option<&str> {
    // Build metadata is everything after the last `+`, by SemVer.
    let tail = version.rsplit_once('+')?.1;
    if tail.is_empty() || tail == CORE_UNKNOWN {
        return None;
    }
    if !tail.chars().all(|c| c.is_ascii_hexdigit()) || tail.len() < 4 || tail.len() > 40 {
        return None;
    }
    Some(tail)
}

/// Do two abbreviated hashes name the same commit?
///
/// **A prefix comparison, and not out of laziness.** Both sides abbreviate
/// with git's own rule, which lengthens as a repository grows, so the two
/// stamps can legitimately differ in length while naming one commit.
/// Comparing them as equal strings would report a mismatch for a reason that
/// has nothing to do with the question -- and a false alarm here costs the
/// whole line, because a line that cries wolf is a line that gets skipped.
fn same_commit(a: &str, b: &str) -> bool {
    let n = a.len().min(b.len());
    n >= 4 && a[..n].eq_ignore_ascii_case(&b[..n])
}

/// **Say whether the host and the core it just loaded are a pair.**
///
/// # Why this is a verdict and not two more facts
///
/// `[build]` already prints sha, size and mtime for all three binaries, and
/// on the day this mattered **all of that was in the log and nobody compared
/// it**. A `ghostty-internal.dll` twenty-one hours older than the host had
/// been in front of us the whole time. So the missing thing was never data;
/// printing two more hashes would have changed nothing. **The missing thing
/// was a judgement, made by the machine, once, out loud.**
///
/// # Why sha and mtime cannot answer this
///
/// A file's own hash says "this is that file". It does not say "this file and
/// that other one were built together" -- two individually correct binaries
/// from builds a day apart both hash correctly. `mtime` is weaker still:
/// copying changes it, and release builds here are not reproducible, so equal
/// sources do not imply equal hashes in either direction.
///
/// # Three outcomes, and the third is not a quiet version of the first
///
/// Unknown is its own answer. It must not read as agreement (two absences
/// comparing equal would manufacture one) **and it must not read as
/// disagreement** (a format this cannot parse would then raise an alarm on a
/// perfectly matched pair, and the alarm would be believed once and ignored
/// thereafter).
fn log_pairing(core_version: &str) {
    let dirty = HOST_DIRTY == "1";
    match (HOST_COMMIT.is_empty(), core_commit(core_version)) {
        (false, Some(core)) if same_commit(HOST_COMMIT, core) => {
            // process-wide: which build this process is, not a fact about any
            // one window
            plogf!(
                "[build] host and ghostty-internal.dll are a pair (both from {HOST_COMMIT})"
            );
            if dirty {
                // process-wide: as above
                plogf!(
                    "[build] but the host was built from a tree with uncommitted changes, so \
                     the same commit does not mean the same source. (The core carries no such \
                     flag, so nothing here can say whether its tree was clean.)"
                );
            }
        }

        (false, Some(core)) => {
            // process-wide: as above
            plogf!(
                "[build] MISMATCH: the host was built from {}{}, ghostty-internal.dll from {}.",
                HOST_COMMIT,
                if dirty { " (dirty)" } else { "" },
                core
            );
            // process-wide: as above
            plogf!(
                "[build] These are different trees. Anything added to the core after {core} is \
                 not in this process."
            );
            // **The line this whole check exists for.**
            //
            // Without it the reading stops at "the versions differ", which is
            // a tidy fact nobody acts on. What actually happened is that a
            // feature present in the source behaved exactly like a feature
            // nobody had written -- and the person looking at it went hunting
            // in the wrong place. The failure is silent by construction: an
            // action the core does not recognise is declined, and a declined
            // action is indistinguishable from an absent one.
            //
            // process-wide: as above
            plogf!(
                "[build] It will not fail loudly: an action the core does not know is declined \
                 in silence, so a feature written after {core} looks exactly like a feature \
                 nobody ever wrote."
            );
        }

        (host_missing, parsed) => {
            let which = if host_missing && parsed.is_none() {
                "neither side"
            } else if host_missing {
                "the host"
            } else {
                "ghostty-internal.dll"
            };
            // process-wide: as above
            plogf!(
                "[build] cannot tell whether the host and ghostty-internal.dll are a pair: \
                 {which} reports a commit this build can read (core version string was {:?}).",
                core_version
            );
            // process-wide: as above
            plogf!("[build] This is not agreement, and it is not disagreement. It is 'not checked'.");
        }
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
    use std::io::Write as _;
    // **The file is the only copy, and it always was the one we trust**: it is
    // flushed on every line and it is the artifact that leaves the machine.
    // There used to be a `println!` here as well. It went with the console
    // window (see the `windows_subsystem` note at the top of this file), and
    // it took two hazards with it: Rust's global stdout lock, which the
    // watchdog must never be able to block on (`wd_log`), and a banner
    // printed onto the stdout that a `+mcp` server speaks its protocol over.
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
/// Key messages that were sitting in the queue when the pump was asked.
///
/// **This counter is what makes "no swallows" a reading.** A probe that only
/// prints when something is wrong cannot tell "it did not happen" from "the
/// probe was not looking" -- which is exactly how a log with `TSF ate` zero
/// times came to be treated as evidence and was not.
static PUMP_KEYS_SEEN: AtomicU32 = AtomicU32::new(0);
/// …and how many of those the pump handed back to us.
static PUMP_KEYS_RETURNED: AtomicU32 = AtomicU32::new(0);
/// …and how many vanished: removed from the queue by the pump and never
/// returned. See `pump_probe` for why this path leaves no other trace.
static PUMP_SWALLOWED: AtomicU32 = AtomicU32::new(0);
/// The keyboard layout in force the last time a key message went past, so a
/// change can be logged at the moment it matters rather than polled.
static LAST_HKL: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
/// The bits of `WM_KEY*` lParam that name the key rather than describe the
/// moment: scan code (16-23) and the extended flag (24). Everything else --
/// repeat count, context code, and the previous/transition state bits that
/// broke two versions of the pump probe -- varies between two observations of
/// one message.
const KEY_IDENTITY_LPARAM: isize = 0x01FF_0000;

/// Key messages kept away from TSF because the core called them bindings.
static INTERCEPTED: AtomicU32 = AtomicU32::new(0);
/// Set while an intercepted key is being translated and dispatched, so the
/// few lines that trace that window can be printed without tracing every key.
static TRACING_INTERCEPT: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
/// How many intercepted keys have been traced. Bounded: this is a question,
/// not a permanent feature.
static TRACED: AtomicU32 = AtomicU32::new(0);

/// Whether the current dispatch is one we are tracing (`keys.rs` asks).
pub fn tracing_intercept() -> bool {
    TRACING_INTERCEPT.load(std::sync::atomic::Ordering::Acquire)
}

/// One line of the interception trace.
///
/// # What this is measuring, and why guessing was not allowed
///
/// Intercepting a chord mid-composition ends the composition, and the
/// half-typed syllable reaches the terminal. The first explanation was that
/// the host's own focus move -- opening a tab, then `SetFocus` on the new
/// pane -- was what ended it, and a guard was put around that. **A real
/// machine refuted it by timestamp**: the composition ended **38ms after the
/// key was kept from TSF and 5ms before the tab existed**, so it was already
/// over before the focus moved at all.
///
/// **That is the same mistake twice in one evening**: finding something that
/// genuinely does end a composition, and stopping there, when an earlier
/// cause was sitting in front of it.
///
/// So this brackets the four steps between the two known timestamps.
/// Wherever `[ime] OnEndComposition` falls among these lines is the step that
/// ended it -- and the two candidates need opposite fixes:
///
///   * **inside `TranslateMessage`** -- TSF is reacting to a key it saw go
///     past the pump without being offered to it. Nothing we call; the guard
///     has to cover the whole window instead.
///   * **inside `DispatchMessageW`** -- something on our own dispatch path
///     does it, and that thing can be found and addressed directly.
pub fn trace_intercept(where_: &str) {
    if !tracing_intercept() {
        return;
    }
    // process-wide: a step in the message pump, which serves the thread
    plogf!("[key] trace {}", where_);
}

/// Whether the "pump returned a different key" diagnostic has been printed.
static MISMATCH_LOGGED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// How many `[key] pump swallowed` lines to print before going quiet.
///
/// **Reaching it prints a line saying so.** A cap that saturates in silence
/// converts "the line is absent" from a reading into nothing at all, which is
/// the fault this whole probe exists to remove; the total is printed at exit
/// either way.
const SWALLOW_LOG_CAP: u32 = 40;

/// `composing`, if TSF is up and is not mid-borrow.
///
/// `None` means "could not ask", and is printed as such: the difference
/// between *not composing* and *unable to tell* is the whole reason this is
/// in the line at all.
fn composing_now() -> Option<bool> {
    IME.with(|c| {
        c.borrow()
            .as_ref()
            .and_then(|st| st.ime.try_borrow().ok().map(|i| i.composing))
    })
}

/// Log the keyboard layout when it changes, at the moment a key goes past.
///
/// **Not a `WM_INPUTLANGCHANGE` handler**, deliberately: that message goes to
/// whichever window has focus, and the question here is "what layout was in
/// force for *this* key". Reading it beside the key ties the two together
/// without depending on which window a message happened to reach.
fn log_hkl_if_changed() {
    use windows::Win32::UI::Input::KeyboardAndMouse::GetKeyboardLayout;
    let hkl = unsafe { GetKeyboardLayout(0) }.0 as usize;
    if LAST_HKL.swap(hkl, Ordering::Relaxed) == hkl {
        return;
    }
    // process-wide: the layout belongs to the thread, not to any one window
    plogf!(
        "[key] keyboard layout now HKL=0x{:08x} (langid 0x{:04x})",
        hkl,
        (hkl & 0xFFFF) as u16
    );
}
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

/// **The first frame**, read from an atomic rather than the state lock.
///
/// **`content_bounds` needs this and cannot take the lock**: it is called
/// from inside `layout`'s critical section, so a `state()` in there would
/// re-enter a non-re-entrant mutex -- on the anomaly path, which is to say
/// the path that only runs when something is already wrong. The lock scanner
/// caught it; the atomic is the same value without the hazard.
///
/// **It is the first frame, not "the" frame, and the difference is now real.**
/// One atomic held the answer to "which window?" for the whole process while
/// there was only ever one window to be the answer. There can be two now, and
/// this still names the first -- so every remaining reader of it is a place
/// that has not yet been asked which window it means. They are not silently
/// correct any more; they are silently *about window 1*. `winid::all()` is
/// the enumeration; `is_primary_frame` is the honest test for the two callers
/// that genuinely mean "the original one".
pub fn frame_hwnd_cached() -> HWND {
    HWND(HWND_G.load(Ordering::Acquire))
}

/// Is this the frame the process started with?
///
/// Used where a fact is genuinely singular no matter how many windows there
/// are -- the remembered window geometry is one rectangle in one file, so a
/// second window dragged across the screen must not overwrite where the first
/// one sits. **Asked explicitly rather than assumed**: before there was a
/// second window every `hwnd` in the frame's window procedure satisfied this
/// by accident, and code that relies on an accident reads exactly like code
/// that checked.
pub fn is_primary_frame(hwnd: HWND) -> bool {
    !hwnd.0.is_null() && hwnd.0 == HWND_G.load(Ordering::Acquire)
}

/// Make a top-level frame window, show it, and register it.
///
/// **One function, because the second window has to be made the same way as
/// the first.** This was thirty lines inside `main`, which is a fine place
/// for it right up until something else needs a window -- and then the
/// natural move is to write a second, shorter version of it somewhere else,
/// and the two drift. The parts that differ between the first frame and the
/// later ones are the parameter, not a second copy.
///
/// `primary` is what the first frame gets and no other: it publishes itself
/// into `HWND_G` and into `State.frame`, both of which are single-valued and
/// **both of which still assume one window**. A second frame deliberately
/// does not touch either -- overwriting them would not give window 2 a state
/// of its own, it would take window 1's away, and every reading would carry
/// on looking healthy while the strip, the layout and the session geometry
/// all quietly followed the newest window. Giving each window its own state
/// is B1-a; this function's job is to not prejudge it.
fn create_frame(hinst: HINSTANCE, primary: bool) -> Option<HWND> {
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterHost"),
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
    };
    // **Reported, not `expect`ed.** `main` still treats a failed first frame
    // as fatal, but a `new_window` that cannot get a window must leave the
    // windows that exist alone -- panicking the process because the second
    // window failed is a worse outcome than the one being reported.
    let hwnd = match hwnd {
        Ok(h) => h,
        Err(e) => {
            // process-wide: there is no window for this line to be about --
            // the failure to make one is the whole of what it reports
            plogf!("[win] CreateWindowExW(frame) failed: {e:?}");
            return None;
        }
    };

    let dpi = unsafe { GetDpiForWindow(hwnd) } as f64;
    let scale = if dpi > 0.0 { dpi / 96.0 } else { 1.0 };
    if primary {
        HWND_G.store(hwnd.0 as *mut c_void, Ordering::Release);
    }
    // **Both registries, in one call, before anything can ask either of
    // them.** `winid::created` records the identity *and* the state -- see
    // its own documentation for why those two cannot be two statements here.
    //
    // It has to happen before `ShowWindow`, because showing a window
    // dispatches messages -- `WM_SIZE`, `WM_PAINT` -- and every one of those
    // handlers asks about the window's tabs. A frame that is visible before
    // it is tracked spends those messages being told it does not exist, and
    // the strip paints empty.
    //
    // Nothing between `CreateWindowExW` and this point can be counted as a
    // window by anybody, because nothing has asked yet.
    winid::created(hwnd);
    // **This window's own scale, measured from this window.** It used to be
    // one number for the process written only by the first frame, so a second
    // frame on a different display drew at the first one's DPI. Set after
    // `add_window`, because there is nothing to set it on before that.
    if let Some(mut w) = tabs::window(hwnd) {
        w.scale = scale;
    }

    shell::init_frame(hwnd);

    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
    }
    // **After `created`, so the tag in this line is one `winid` has already
    // paired with the handle.** Logged per window rather than process-wide
    // because dpi and scale are this window's, and the day the two frames sit
    // on displays of different DPI these two lines are the reading that says
    // so.
    wlogf!(hwnd, "[win] frame dpi={} scale={} primary={}", dpi, scale, primary);
    Some(hwnd)
}

/// A frame that is **not** the first one. See `create_frame`.
///
/// Exists so `tabs.rs` cannot pass `primary: true` by getting a boolean the
/// wrong way round -- there is exactly one caller entitled to that, it is in
/// this file, and a bare `bool` at a call site in another module is the kind
/// of argument that is read as "yes, make a frame" rather than "yes, and let
/// it claim to be the original".
pub fn create_frame_secondary(hinst: HINSTANCE) -> Option<HWND> {
    create_frame(hinst, false)
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

/// Content scale **of the window the input method is composing in**.
///
/// `ghostty_surface_ime_point` answers in unscaled units; every pixel this
/// host hands to Windows is physical. Which window's scale that is matters
/// once the two can differ: a caret rectangle scaled by the other monitor's
/// DPI puts the candidate list next to the wrong glyph.
fn scale() -> f64 {
    let hwnd = IME.with(|c| {
        c.borrow()
            .as_ref()
            .and_then(|st| st.ime.try_borrow().ok().map(|i| i.hwnd))
    });
    // A pane window, so its frame is its parent.
    let frame = match hwnd {
        Some(h) if !h.0.is_null() => unsafe { GetParent(h) }.unwrap_or_default(),
        _ => HWND(std::ptr::null_mut()),
    };
    tabs::scale_of(frame)
}

// ------------------------------------------------- bridge used by tsf.rs
//
// tsf.rs deliberately knows nothing about libghostty. These functions are the
// entire surface between the composition and the terminal.

pub fn ime_log(msg: &str) {
    log_line(&format!("[ime] {msg}"));
}

/// Set while the host is rearranging its own windows.
///
/// **This exists because "the composition ended" and "the user finished a
/// word" are not the same event, and TSF reports only the first.**
///
/// `OnEndComposition` fires for both, with the same signature and with the
/// composed text still in the buffer either way. The handler used to commit
/// whatever it found there, on the stated assumption that a cancelled
/// composition arrives with an empty buffer. **That holds for a composition
/// the user abandoned and not for one the host interrupted**: the person
/// pressed `ctrl+shift+t`, got a new tab *and* the half-typed word `ni`.
///
/// # It used to be called `REFOCUSING`, and the name was itself a wrong answer
///
/// The first two explanations both blamed focus -- `SetFocus` on the new
/// pane, then focus generally -- and both were refuted by timestamps: the
/// composition ended before any focus moved. **The actual trigger is
/// `ShowWindow(SW_HIDE)` on the pane that is carrying the composition**, in
/// the layout pass that runs when panes are rearranged.
///
/// The name is now about what the host is doing rather than about which
/// mechanism was guessed to matter, **because two of those guesses have
/// already been wrong and the name outlived both.**
static HOST_SHUFFLING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Run `body` with [`HOST_SHUFFLING`] set, so a composition ended by the
/// window shuffling inside it is discarded rather than committed.
///
/// **A guard rather than a pair of calls**: `ShowWindow` (and `SetFocus`)
/// re-enter through TSF and can end the composition **synchronously**, so the
/// flag has to be up for the whole of the operation and down afterwards even
/// if something in between returns early.
pub fn with_host_shuffle<R>(body: impl FnOnce() -> R) -> R {
    use std::sync::atomic::Ordering;
    struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            HOST_SHUFFLING.store(false, Ordering::Release);
        }
    }
    HOST_SHUFFLING.store(true, Ordering::Release);
    let _g = Guard;
    body()
}

/// Whether a composition ending right now is one the host caused.
pub fn ending_because_of_host_shuffle() -> bool {
    HOST_SHUFFLING.load(std::sync::atomic::Ordering::Acquire)
}

/// The surface the input method is composing into.
///
/// **The window TSF is attached to, not "the active tab".** They were the
/// same answer while there was one window, and they are not now: the IME
/// document is retargeted at a particular pane by `ime_set_window`, so that
/// pane is what a composition belongs to. Asking for the active tab of the
/// first window instead would deliver a candidate the user picked in window 2
/// into window 1 -- and it would look entirely normal at the call site.
/// The pane a composition started in, for as long as it is in flight.
///
/// # Sending the right thing to the wrong pane
///
/// `ime_surface()` answers "the pane the input method is pointed at **now**".
/// That is the correct answer to a different question. When a composition is
/// interrupted by the host rearranging panes, the retarget has already
/// happened by the time the composition ends, so the preedit clear went to the
/// pane that had just been created:
///
/// ```text
/// set_preedit("ni") -> surface 0x…40f0     <- pane 1, where the typing was
/// [pane] 6 surface = 0x…7bc0               <- a new pane
/// set_preedit("ni") -> surface 0x…7bc0     <- pane 6
/// set_preedit("")   -> surface 0x…7bc0     <- pane 6
/// ```
///
/// Pane 1 never got the clear, so the underlined `ni` stayed on it: enter did
/// not run it and backspace did not delete it, because as far as the terminal
/// was concerned there was nothing there.
///
/// **The log had been telling the truth the whole time.** Every one of those
/// lines printed a real surface; nobody had asked *which* surface. **A line
/// that prints a correct value and a line that prints the correct object are
/// not the same line.**
///
/// So the pane is remembered when the composition starts and used until it
/// ends. **The hwnd is stored rather than the surface pointer**: a pane can be
/// destroyed mid-composition, and `surface_of` then answers null, where a
/// stale pointer would answer something that looks usable.
static COMPOSING_HWND: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Called from `tsf.rs` when a composition starts and ends.
pub fn ime_composition_owner(hwnd: Option<HWND>) {
    COMPOSING_HWND.store(
        hwnd.map(|h| h.0).unwrap_or(std::ptr::null_mut()),
        Ordering::Release,
    );
}

/// The surface a composition's text belongs to: the pane it started in while
/// one is in flight, otherwise whatever the IME is pointed at now.
fn composing_surface() -> ffi::Surface {
    let h = COMPOSING_HWND.load(Ordering::Acquire);
    if !h.is_null() {
        let s = tabs::surface_of(HWND(h));
        if !s.is_null() {
            return s;
        }
        // The pane went away mid-composition. Falling through is right: there
        // is nothing to draw on, and `ime_surface` will say so too.
    }
    ime_surface()
}

fn ime_surface() -> ffi::Surface {
    let hwnd = IME.with(|c| {
        c.borrow()
            .as_ref()
            .and_then(|st| st.ime.try_borrow().ok().map(|i| i.hwnd))
    });
    match hwnd {
        Some(h) if !h.0.is_null() => tabs::surface_of(h),
        _ => std::ptr::null_mut(),
    }
}

/// Hand the in-flight composition to the core so it draws it at the cursor.
///
/// # The empty string is the interesting call, and it used to fail in silence
///
/// Clearing the preedit is how the underlined text under the cursor goes
/// away. When a composition is discarded, that clear is the *only* thing that
/// removes it -- and if it does not happen, an unremovable `ni` sits on the
/// screen following the caret: enter does not run it, backspace does not
/// delete it, because as far as the terminal is concerned it is not there.
///
/// **The skip below was unreported**, and that made two very different faults
/// produce the same screen:
///
///   * the clear was never issued, because `ime_surface()` could not resolve
///     one (`try_borrow` losing to a TSF callback already inside the store,
///     or `ime.hwnd` pointing at a pane that has gone);
///   * the clear *was* issued and something afterwards drew the overlay again.
///
/// They need opposite fixes and they look identical from a chair, so the skip
/// now says so. **A silent early return is a fork in the diagnosis that leaves
/// no trace of which way it went.**
pub fn ime_set_preedit(text: &str) {
    let s = composing_surface();
    if s.is_null() {
        ime_log(&format!(
            "set_preedit({:?}) SKIPPED: no surface to send it to \
             (clearing an empty preedit is how the overlay is removed, so a skip \
             here leaves it on screen)",
            text
        ));
        return;
    }
    ime_log(&format!("set_preedit({:?}) -> surface {:?}", text, s));
    unsafe { (api().surface_preedit)(s, text.as_ptr() as *const _, text.len()) };
}

/// The user chose a candidate: feed it to the terminal as input.
pub fn ime_commit(text: &str) {
    let s = composing_surface();
    if s.is_null() {
        // Same reason as `ime_set_preedit`: a silent skip here means the
        // chosen text vanished, which reads as "the IME dropped my word".
        ime_log(&format!("commit({:?}) SKIPPED: no surface to send it to", text));
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
    let s = ime_surface();
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
                // **The frame, not the surface.** A pane is not a
                // registered window, so `wlogf!` would tag this line `w?` and
                // the line would say nothing about which terminal it is
                // reporting; `GA_ROOT` walks the child up to the frame it
                // lives in.
                //
                // It used to be worse than an unnameable line: `winid::of`
                // registered any handle it was handed, so a pane here minted
                // a "window" that is not one and `count()` -- the number the
                // shutdown rule reads -- carried it forever. `of` only looks
                // now, which is why the cost of getting this wrong is a
                // missing name rather than a process that will not exit.
                Err(_) => wlogf!(
                    unsafe { GetAncestor(hwnd, GA_ROOT) },
                    "[ime] set_window skipped: composition in flight"
                ),
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
            // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
            plogf!("[ime] CoInitializeEx failed: {e:?}");
            return false;
        }
        let thread_mgr: ITfThreadMgr =
            match CoCreateInstance(&CLSID_TF_ThreadMgr, None, CLSCTX_INPROC_SERVER) {
                Ok(t) => t,
                Err(e) => {
                    // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
                    plogf!("[ime] CoCreateInstance(TF_ThreadMgr) failed: {e:?}");
                    return false;
                }
            };
        let ex: ITfThreadMgrEx = match thread_mgr.cast() {
            Ok(x) => x,
            Err(e) => {
                // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
                plogf!("[ime] ITfThreadMgrEx cast failed: {e:?}");
                return false;
            }
        };
        let mut client_id = 0u32;
        if let Err(e) = ex.ActivateEx(&mut client_id, 0) {
            // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
            plogf!("[ime] ActivateEx failed: {e:?}");
            return false;
        }
        // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
        plogf!("[ime] ActivateEx ok, clientId={client_id}");

        let doc_mgr = match thread_mgr.CreateDocumentMgr() {
            Ok(d) => d,
            Err(e) => {
                // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
                plogf!("[ime] CreateDocumentMgr failed: {e:?}");
                return false;
            }
        };

        let ime = Rc::new(RefCell::new(tsf::Ime::new(hwnd)));
        let store: ComObject<tsf::TextStore> = tsf::TextStore::new(ime.clone()).into();
        let punk: windows::core::IUnknown = store.to_interface();

        let mut ctx: Option<ITfContext> = None;
        let mut edit_cookie = 0u32;
        if let Err(e) = doc_mgr.CreateContext(client_id, 0, &punk, &mut ctx, &mut edit_cookie) {
            // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
            plogf!("[ime] CreateContext failed: {e:?}");
            return false;
        }
        let ctx = match ctx {
            Some(c) => c,
            None => {
                // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
                plogf!("[ime] CreateContext gave no context");
                return false;
            }
        };
        if let Err(e) = doc_mgr.Push(&ctx) {
            // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
            plogf!("[ime] Push failed: {e:?}");
            return false;
        }
        let _ = thread_mgr.AssociateFocus(hwnd, &doc_mgr);
        let _ = thread_mgr.SetFocus(&doc_mgr);
        // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
        plogf!("[ime] context pushed, editCookie={edit_cookie}  <<< TSF READY");

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
            // The confirmation is modal over a window; which one is the
            // same gap every panel has. See `tabs::overlay_frame`.
            Some(tabs::overlay_frame()),
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
        // process-wide: with no pane id there is no window to name -- that is
        // exactly what this line reports
        plogf!("[action] close_surface with no pane id -- ignored");
        return;
    }
    // **The window comes from the pane, not from the target.** This callback
    // is handed a pane id and nothing else -- there is no `Target` here -- and
    // the pane is in exactly one window. Asking `frame_hwnd()` instead would
    // send a shell that exited in window 2 to close a pane in window 1, which
    // has one: it would close *some other pane*, because pane ids are unique
    // and the lookup would simply find nothing to remove.
    match tabs::frame_of_pane(id) {
        Some(frame) => tabs::post_op(frame, tabs::Op::ClosePane(id), "close_surface callback"),
        // process-wide: the pane is in no window this host is tracking, which
        // is the fact being reported
        None => plogf!("[ops] ClosePane pane={} is in no live window; not queued", id),
    }
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

/// The window an action came from: the one owning the surface it was aimed at.
///
/// **This is the answer `post_op` needs, and the reason it is a lookup rather
/// than a default.** Every queued action used to run on the first window,
/// because the queue woke the first window and nothing carried an address.
/// The address was available the whole time -- the core says which surface it
/// is acting on, and a surface is in exactly one window.
///
/// `None` is a real answer, not a gap to be papered over: an app-targeted
/// action names no surface and therefore no window. Its callers refuse rather
/// than pick one.
fn origin_window(target: &Target) -> Option<HWND> {
    tabs::frame_of_surface(target_surface(target)?)
}

/// Queue an op against the window an action came from.
///
/// **The refusal is here, once, rather than at nineteen call sites.** The
/// thing this must never do is fall back to a window -- an action with no
/// window that runs on "the current one" is a tab appearing in a window
/// nobody asked, with a log that reads entirely normal.
/// One `[action]` line, from the window the action came from.
///
/// **Every arm of `cb_action` is about one window** -- the core performed
/// something for a surface, and `origin` is the frame that surface lives in.
/// With two windows open, `[action] new_tab` says nothing a reader can use;
/// with the origin in front of it, it says which window just grew a tab.
///
/// The `None` arm is not a fallback: an action that names no surface is a
/// fact about the process, and it says so rather than picking a window. Both
/// halves go through `wlogf!`/`plogf!`, so the log checker still sees a
/// classified site here -- and `alogf!` itself is spelled out in that
/// checker, because a macro it does not know about is a site it cannot see.
macro_rules! alogf {
    ($origin:expr, $($a:tt)*) => {{
        match $origin {
            Some(__f) => $crate::wlogf!(__f, $($a)*),
            // process-wide: the action named no surface, so there is no window
            // this line could belong to
            None => $crate::plogf!($($a)*),
        }
    }};
}

fn queue_from(origin: Option<HWND>, op: tabs::Op, from: &'static str) -> bool {
    match origin {
        Some(frame) => {
            tabs::post_op(frame, op, from);
            true
        }
        None => {
            // process-wide: the action named no surface, so there is no window
            // for this line to belong to -- which is the fact being reported
            plogf!("[ops] {} from {}: the action names no window; not queued", op.name(), from);
            false
        }
    }
}

extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    use tabs::Op;
    // Resolved once, at the top, so every arm below answers "which window"
    // the same way and a new arm cannot answer it differently by accident.
    let origin = origin_window(&target);
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
            // **The target travels with the needle.** The core says which
            // surface it started searching; without passing it on, the host
            // knows a search is open and not whose, and everything it sends
            // back goes to whichever surface happens to be focused. See
            // `search::Model::surface`.
            search::on_start(
                action.as_cstr().and_then(|c| c.to_str().ok()),
                target_surface(&target),
            );
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
                alogf!(origin, "[action] open_config: the core reported no path");
                return false;
            }
            let bytes = unsafe { std::slice::from_raw_parts(s.ptr as *const u8, s.len) };
            let path = String::from_utf8_lossy(bytes).into_owned();
            unsafe { (api().string_free)(s) };

            if mode != 0 {
                alogf!(origin, "[action] open_config mode {} not supported; opening with the OS", mode);
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
            alogf!(origin, "[action] open_config {:?} -> {}", path, ok);
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
            // process-wide: a fact about what libghostty publishes on this
            // platform, the same for every window there will ever be
            plogf!(
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
            alogf!(origin, "[action] poltergeist chat requested");
            // **Our own path, not the name `polter`.**
            //
            // This used to be the literal `"polter +chat"`, which asks
            // `CreateProcessW` to search for a program of that name -- the
            // application directory, the working directory, the system
            // directories, then `PATH`. On Windows nothing puts Polter on
            // `PATH`, so the search found nothing and the menu item did
            // nothing. A process already knows where it is; asking the
            // operating system to go and look for it is the step that could
            // fail, and removing it is cheaper than any of the ways to make
            // the search succeed.
            //
            // **The path is quoted as one unit and never taken apart.** The
            // quotes are not a workaround for spaces, they are what keeps the
            // whole answer one value: `splitWindowsShell` in the core reads
            // the quoted run as a single argument and
            // `windowsCreateCommandLine` re-quotes it on the way to
            // `CreateProcessW`. Before that pair existed a path with a space
            // in it could not be expressed here at all -- and the directory
            // this is developed in has one.
            let Some(exe) = own_exe_path() else {
                alogf!(origin, "[action] chat: cannot find our own executable; not opening");
                return true;
            };
            let command = format!("\"{exe}\" +chat");
            alogf!(origin, "[action] chat command: {command}");
            queue_from(
                origin,
                tabs::Op::NewTabWith(tabs::NewTab {
                    command: Some(command),
                    chat: true,
                    ..Default::default()
                }),
                "toggle_poltergeist_chat action",
            );
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
                    alogf!(origin, "[action] readonly={} surface={:?}", on, s);
                }
                None => alogf!(origin, "[action] readonly={} with no surface (tag={}); dropped", on, target.tag),
            }
            true
        }

        ACTION_INITIAL_SIZE => {
            // `iw`/`ih` rather than `w`/`h`: `w` is the window below.
            let (iw, ih) = action.as_size();
            alogf!(origin, "[action] initial_size {}x{}", iw, ih);
            // **The window the surface is in.** `reset_window_size` resizes
            // one window back to what its own first surface asked for; one
            // copy for the process meant the second window remembered the
            // first one's size.
            match origin.and_then(tabs::window) {
                Some(mut w) if w.initial.is_none() => w.initial = Some((iw, ih)),
                Some(_) => {}
                // process-wide: the action names no window, so there is
                // nothing to record the size against
                None => plogf!("[action] initial_size names no window; not recorded"),
            }
            true
        }
        ACTION_CELL_SIZE => {
            let (w, h) = action.as_size();
            CELL_W.store(w, Ordering::Release);
            CELL_H.store(h, Ordering::Release);
            alogf!(origin, "[action] cell_size {}x{}", w, h);
            true
        }

        // The core knows the terminal cannot be smaller than a few cells, and
        // Win32 has a message for exactly that. macOS ignores this action and
        // constrains through AppKit instead, so there is no reference
        // implementation to copy.
        ACTION_SIZE_LIMIT => {
            let (min_w, min_h, max_w, max_h) = action.as_size_limit();
            // `WM_GETMINMAXINFO` is answered per frame, so the limit is
            // stored per frame. Shared, a limit derived from one window's
            // cell grid became the floor the other could not be dragged
            // below.
            match origin.and_then(tabs::window) {
                Some(mut w) => {
                    w.min_w = min_w;
                    w.min_h = min_h;
                    w.max_w = max_w;
                    w.max_h = max_h;
                }
                // process-wide: the action names no window to limit
                None => plogf!("[action] size_limit names no window; not applied"),
            }
            alogf!(
                origin,
                "[action] size_limit min {}x{} max {}x{} (0 max = unlimited)",
                min_w, min_h, max_w, max_h
            );
            true
        }

        ACTION_SET_TITLE => {
            if let Some(t) = action.as_cstr() {
                let t = t.to_string_lossy().to_string();
                alogf!(origin, "[action] set_title {:?}", t);
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
                    Some(s) => {
                        queue_from(origin, Op::SetTabTitle { surface: s as usize, title: t }, "set_title action");
                    }
                    None => alogf!(origin, "[action] set_title with no surface (tag={}); tab label unchanged", target.tag),
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
                    alogf!(origin, "[action] pwd {:?} surface={:?} attached={}", cwd, s, attached as u8);
                }
                None => alogf!(origin, "[action] pwd {:?} with no surface (tag={}); dropped", cwd, target.tag),
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
                alogf!(origin, "[action] set_tab_title {:?}", t);
                match target_surface(&target) {
                    Some(s) => {
                        queue_from(origin, Op::SetTabTitle { surface: s as usize, title: t }, "set_title action");
                    }
                    None => alogf!(origin, "[action] set_tab_title with no surface (tag={}); dropped", target.tag),
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
            // **Resolved once and passed on.** This arm knew which terminal
            // the mark was for and told nobody: `set_mark_for_surface` got it,
            // the notification below did not, and so the menu's own line could
            // not say which terminal -- or which window -- it was about. The
            // surface was here the whole time.
            let surface = target_surface(&target);
            let found =
                surface.is_some_and(|s| tabs::set_mark_for_surface(s, role as u8, shielded));
            // The surface's own right-click menu wants the same three bits.
            // It reads them back out of `tabs::mark_for_surface`; this call
            // is the notification that they changed, not a second copy.
            crate::ctxmenu::on_poltergeist_mark(
                surface.unwrap_or(std::ptr::null_mut()),
                role,
                shielded,
            );
            alogf!(
                origin,
                "[action] poltergeist_mark role={} shielded={} surface={:?} matched={}",
                role, shielded, target.surface, found
            );
            true
        }

        ACTION_COPY_TITLE_TO_CLIPBOARD => {
            alogf!(origin, "[action] copy_title_to_clipboard");
            queue_from(origin, Op::CopyTitleToClipboard, "copy_title_to_clipboard action")
        }

        ACTION_NEW_SPLIT => {
            let dir = action.as_i32();
            alogf!(origin, "[action] new_split dir={}", dir);
            queue_from(origin, Op::NewSplit(dir), "new_split action")
        }
        ACTION_GOTO_SPLIT => {
            let v = action.as_i32();
            alogf!(origin, "[action] goto_split {}", v);
            queue_from(origin, Op::GotoSplit(v), "goto_split action")
        }
        ACTION_RESIZE_SPLIT => {
            let (amount, dir) = action.as_resize_split();
            alogf!(origin, "[action] resize_split {} dir={}", amount, dir);
            queue_from(origin, Op::ResizeSplit(amount, dir), "resize_split action")
        }
        ACTION_EQUALIZE_SPLITS => {
            alogf!(origin, "[action] equalize_splits");
            queue_from(origin, Op::EqualizeSplits, "equalize_splits action")
        }
        ACTION_TOGGLE_SPLIT_ZOOM => {
            alogf!(origin, "[action] toggle_split_zoom");
            queue_from(origin, Op::ToggleSplitZoom, "toggle_split_zoom action")
        }

        ACTION_TOGGLE_QUICK_TERMINAL => {
            alogf!(origin, "[action] toggle_quick_terminal");
            queue_from(origin, Op::ToggleQuickTerminal, "toggle_quick_terminal action")
        }
        ACTION_NEW_TAB => {
            alogf!(origin, "[action] new_tab");
            queue_from(origin, Op::NewTab, "new_tab action")
        }
        ACTION_CLOSE_TAB => {
            let mode = action.as_i32();
            alogf!(origin, "[action] close_tab mode={}", mode);
            queue_from(origin, Op::CloseTab(mode), "close_tab action")
        }
        ACTION_GOTO_TAB => {
            let v = action.as_i32();
            alogf!(origin, "[action] goto_tab {}", v);
            queue_from(origin, Op::GotoTab(v), "goto_tab action")
        }
        ACTION_MOVE_TAB => {
            let d = action.as_isize();
            alogf!(origin, "[action] move_tab {}", d);
            queue_from(origin, Op::MoveTabBy(d), "move_tab action")
        }

        ACTION_TOGGLE_FULLSCREEN => {
            alogf!(origin, "[action] toggle_fullscreen mode={}", action.as_i32());
            queue_from(origin, Op::ToggleFullscreen, "toggle_fullscreen action")
        }
        ACTION_TOGGLE_MAXIMIZE => {
            alogf!(origin, "[action] toggle_maximize");
            queue_from(origin, Op::ToggleMaximize, "toggle_maximize action")
        }
        ACTION_RESET_WINDOW_SIZE => {
            alogf!(origin, "[action] reset_window_size");
            queue_from(origin, Op::ResetWindowSize, "reset_window_size action")
        }

        ACTION_RENDERER_HEALTH => {
            alogf!(origin, "[action] renderer_health (payload[0]={})", action.payload[0]);
            true
        }
        ACTION_PRESENT_TERMINAL => {
            alogf!(origin, "[action] present_terminal");
            queue_from(origin, Op::PresentTerminal, "present_terminal action")
        }
        // **Per surface, because a pointer shape is about one pane.** After a
        // split the pointer is over exactly one of them, and a shape stored
        // once for the process would put the pane under the pointer's shape on
        // whichever pane redrew last.
        //
        // **Recording it is only half.** The pane's window class carries
        // `IDC_ARROW`, so `DefWindowProc` restores the arrow on the next mouse
        // message; `mouse::apply`, called from the pane's `WM_SETCURSOR`, is
        // what makes the recorded shape survive the pointer moving. See
        // `mouse.rs`.
        ACTION_MOUSE_SHAPE => {
            let shape = action.as_i32();
            match target_surface(&target) {
                Some(s) => {
                    let p = mouse::record_shape(s as usize, shape);
                    // **The fidelity is in the line, not implied by it.** A
                    // shape that fell back to the arrow and a shape that was
                    // mapped correctly are indistinguishable on screen.
                    alogf!(
                        origin,
                        "[action] mouse_shape {} ({}) -> {} [{}]",
                        shape, p.shape, p.cursor_name, p.fidelity.name()
                    );
                }
                None => alogf!(
                    origin,
                    "[action] mouse_shape {} with no surface (tag={}); dropped",
                    shape, target.tag
                ),
            }
            true
        }

        // `ghostty_action_mouse_visibility_e`: 0 visible, 1 hidden.
        //
        // **The post is the point.** Windows sends `WM_SETCURSOR` when the
        // pointer moves, and the core hides the pointer when the user *types*
        // -- so waiting for `WM_SETCURSOR` would hide it never while looking
        // like an implementation. The pane hides it on the thread that owns
        // the window, and only if the pointer is actually over that pane.
        ACTION_MOUSE_VISIBILITY => {
            let v = action.as_i32();
            let hidden = v == 1;
            match target_surface(&target) {
                Some(s) => {
                    mouse::record_visibility(s as usize, hidden);
                    let posted = match tabs::pane_hwnd_of_surface(s) {
                        Some(pane) => unsafe {
                            PostMessageW(
                                Some(pane),
                                mouse::WM_POLTER_MOUSE_VISIBILITY,
                                WPARAM(0),
                                LPARAM(0),
                            )
                            .is_ok()
                        },
                        // The quick terminal's surface is not a pane, so there
                        // is no pane window to post to. Its shape still
                        // follows -- `tabs::surface_of` falls through to it --
                        // and only this immediate hide is out of reach.
                        None => false,
                    };
                    alogf!(
                        origin,
                        "[action] mouse_visibility {} (hidden={}) posted={}",
                        v, hidden as u8, posted as u8
                    );
                }
                None => alogf!(
                    origin,
                    "[action] mouse_visibility {} with no surface (tag={}); dropped",
                    v, target.tag
                ),
            }
            true
        }
        ACTION_RING_BELL => {
            alogf!(origin, "[action] ring_bell");
            true
        }
        ACTION_CONFIG_CHANGE | ACTION_RELOAD_CONFIG => {
            settings_ui::request_errors();
            alogf!(origin, "[action] config_change/reload_config");
            true
        }
        ACTION_SHOW_CHILD_EXITED => {
            alogf!(origin, "[action] show_child_exited");
            true
        }

        // **A second top-level window.** Queued rather than made here for the
        // reason every window-making action is queued: this arrives on
        // whichever thread the core is on, and creating a window off the
        // thread that owns them is undefined in Win32.
        //
        // **This is also the row `文件 ▸ 新建窗口` has always sent.** The menu
        // dispatches core actions by name, so wiring the action wires the
        // menu -- there is no second path to forget, which is the asymmetry
        // that made three of the four *close* routes look complete.
        ACTION_NEW_WINDOW => {
            // **Tagged with the window that asked**, which is the only window
            // this line can be about: the new one does not exist yet. When
            // the action is app-targeted there is no asking window either,
            // and the line says that rather than naming a plausible one.
            match origin {
                Some(from) => wlogf!(from, "[action] new_window requested"),
                // process-wide: an app-targeted action names no window, and
                // the window it is about to make does not exist yet
                None => plogf!("[action] new_window requested (target tag={})", target.tag),
            }
            queue_from(origin, Op::NewWindow, "new_window action")
        }

        // **The window comes from the action's own target.** The stand-in
        // that used to be here read `frame_hwnd()` and said so in a comment:
        // "the line is true because there is only one window for it to be
        // true of". It is not true any more. This is the route the command
        // palette and the key bindings take, so with two windows open the
        // stand-in would close **the first** window every time, whichever one
        // the person was looking at -- and a single-window test passes either
        // way, which is exactly what the old comment predicted about itself.
        ACTION_CLOSE_WINDOW | ACTION_QUIT => {
            let owner = if target.tag == ffi::TARGET_SURFACE {
                tabs::frame_of_surface(target.surface)
            } else {
                // `TARGET_APP`: the union holds no surface (see ffi.rs), so
                // there is genuinely no window in this message. Reading the
                // field anyway is how a per-window fact gets recorded against
                // a pointer that names nothing.
                None
            };
            match owner {
                Some(frame) => {
                    winid::close_requested(frame, winid::CloseVia::CoreCloseWindow);
                    alogf!(origin, "[action] close_window/quit tag={} -> w{}", action.tag, winid::of(frame));
                    // **The same terminus as the other three.** This route
                    // used to call `window_finished` directly, which recorded
                    // the window as gone and quit without ever destroying it
                    // -- indistinguishable from correct while there was one
                    // window and `PostQuitMessage` took the window down
                    // anyway.
                    winid::close_window_now(frame);
                    true
                }
                None => {
                    // **Refused, not guessed.** Closing "the first window"
                    // because this one did not say which is a wrong answer
                    // that looks like a working feature; returning false is
                    // what the core does with any action a host declines, and
                    // it leaves a line saying why.
                    // process-wide: the action named no window, which is the fact being reported
                    plogf!(
                        "[action] close_window/quit tag={} names no window (target tag={}); \
                         nothing closed",
                        action.tag,
                        target.tag
                    );
                    false
                }
            }
        }
        ACTION_RENDER => true,

        // **An action this host does not answer leaves a line.**
        //
        // This arm was bare `_ => false`, and `new_window` fell through it
        // for the whole life of the port: the menu row was not greyed, so a
        // person could click `文件 ▸ 新建窗口`, and **nothing happened and
        // nothing was written anywhere**. The only reading of that defect was
        // the screen -- and "I clicked it and nothing happened" is the one
        // report that cannot be checked afterwards against a log.
        //
        // Rate-limited rather than unconditional: some of these arrive on
        // every frame from the core, and a line per frame is how a log stops
        // being read at all. First sighting of each tag, then every 500th.
        tag => {
            let n = UNHANDLED.fetch_add(1, Ordering::Relaxed) + 1;
            let first = UNHANDLED_SEEN
                .lock()
                .map(|mut v| {
                    let fresh = !v.contains(&tag);
                    if fresh {
                        v.push(tag);
                    }
                    fresh
                })
                .unwrap_or(false);
            if first || n % 500 == 0 {
                // process-wide: the core asked this host for something it does
                // not implement; no window is involved in the refusal
                plogf!(
                    "[action] tag={} is not implemented by this host; returning false \
                     (#{} unhandled so far{})",
                    tag,
                    n,
                    if first { ", first of this tag" } else { "" }
                );
            }
            false
        }
    }
}

/// How many actions this host has declined, and which tags have been seen.
///
/// **A tag is reported the first time and then counted**, because the two
/// questions a reader has are different: "is this action wired up?" is
/// answered once, and "is something hammering us with an action we ignore?"
/// is answered by a number.
static UNHANDLED: AtomicU32 = AtomicU32::new(0);
static UNHANDLED_SEEN: std::sync::Mutex<Vec<u32>> = std::sync::Mutex::new(Vec::new());

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

            // Accessibility. **Before anything that could answer it by
            // accident**: `WM_GETOBJECT` arrives with several different
            // object ids, and only one of them is the UI Automation tree --
            // `uia::on_get_object` answers `None` for the rest, including
            // MSAA's `OBJID_CLIENT`, and those go to `DefWindowProcW`
            // unchanged. Returning a provider for the wrong object id is how
            // a window comes to look like it has two conflicting trees.
            WM_GETOBJECT => match uia::on_get_object(hwnd, wp, lp) {
                Some(r) => r,
                None => DefWindowProcW(hwnd, msg, wp, lp),
            },

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
                // **Only the first frame's geometry is remembered.** The session file
                // holds one rectangle, so a second window dragged somewhere would
                // overwrite where the first one sits -- and the symptom is a window
                // that comes back in the wrong place next launch, blamed on nothing.
                // Giving each window its own remembered geometry is a bigger change
                // than B1-e; refusing to write the wrong one is not.
                if is_primary_frame(hwnd) {
                    session::mark_dirty();
                }
                // **Which terminal window the person is on, recorded here and
                // nowhere else.** The low word distinguishes activation from
                // deactivation; only activation is a new answer, and a
                // deactivation is not "no window" -- clicking a panel
                // deactivates the frame the panel belongs to.
                //
                // This runs in the frame window procedure, and the class it
                // serves (`PolterHost`) belongs to `create_frame` alone -- so
                // a panel taking the focus cannot reach this line. That is why
                // `tabs::overlay_frame` can be a record rather than a query.
                if (wp.0 & 0xFFFF) as u32 != WA_INACTIVE {
                    tabs::note_activated(hwnd);
                }
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
                // **Only the first frame's geometry is remembered.** The session file
                // holds one rectangle, so a second window dragged somewhere would
                // overwrite where the first one sits -- and the symptom is a window
                // that comes back in the wrong place next launch, blamed on nothing.
                // Giving each window its own remembered geometry is a bigger change
                // than B1-e; refusing to write the wrong one is not.
                if is_primary_frame(hwnd) {
                    session::mark_dirty();
                }
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
                // **Only the first frame's geometry is remembered.** The session file
                // holds one rectangle, so a second window dragged somewhere would
                // overwrite where the first one sits -- and the symptom is a window
                // that comes back in the wrong place next launch, blamed on nothing.
                // Giving each window its own remembered geometry is a bigger change
                // than B1-e; refusing to write the wrong one is not.
                if is_primary_frame(hwnd) {
                    session::mark_dirty();
                }
                ime_layout_changed();
                LRESULT(0)
            }

            // The core's cell-derived floor, expressed to Windows.
            WM_GETMINMAXINFO => {
                tabs::apply_min_max(hwnd, lp.0 as *mut MINMAXINFO);
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
                tabs::focus_active(hwnd);
                LRESULT(0)
            }

            WM_DPICHANGED => {
                let dpi = (wp.0 & 0xFFFF) as f64;
                let scale = dpi / 96.0;
                // **Only the window the message arrived at.** This is the
                // one place a second monitor's DPI enters the host, and with
                // one `scale` for the process, dragging window 2 onto a
                // different display rescaled window 1's strip and panes too.
                if let Some(mut w) = tabs::window(hwnd) {
                    w.scale = scale;
                }
                let s = tabs::active_surface(hwnd);
                if !s.is_null() {
                    (api().surface_set_content_scale)(s, scale, scale);
                }
                tabs::layout(hwnd);
                wlogf!(hwnd, "[win] dpi changed -> scale {}", scale);
                LRESULT(0)
            }

            // The global hotkey. It arrives here even when Polter is not the
            // foreground application -- that is the entire point of it, and
            // the reason it is a `RegisterHotKey` and not an accelerator.
            WM_HOTKEY => {
                // process-wide: the hotkey is registered once for the process
                // and fires whatever is in front -- the window it happens to
                // be delivered to is an accident of registration, not a fact
                // about which terminal the person meant
                plogf!("[quick] hotkey pressed (foreground={:?})", GetForegroundWindow().0);
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
                // **The tabs go before the window does.** Windows destroys a
                // frame's children with it, but it knows nothing about the
                // surfaces bound to them -- so without this the shells in a
                // closed window keep running with no window attached. It was
                // invisible while closing a window meant leaving the process.
                tabs::close_all_tabs_of(hwnd);
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
                // **After `window_finished`, not before.** That call takes
                // the count this window is still in, decides whether the
                // process is finished, and logs it; dropping the state first
                // would be one route answering "how many windows are left"
                // with a number that has already had this one taken off it.
                tabs::remove_window(hwnd);
                // The strip's own per-window state goes the same way, and for
                // a reason the tab state does not have: Windows recycles
                // `HWND`s, so an entry left under a dead handle can be found
                // again by the next window that gets it.
                strip::forget(hwnd);
                // **Last, because it is the only moment both registries have
                // finished with this window.** Anywhere earlier it would be
                // reading one of the two legitimate disagreements. See
                // `winid::empty_agrees` for why it checks zero and nothing
                // else.
                winid::empty_agrees(hwnd);
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
            // process-wide: the resources directory is one per process; every window reads the same one
            plogf!("[res] POLTER_RESOURCES_DIR already set to {:?}; leaving it", v);
            report_resources_dir(std::path::Path::new(&v));
            return;
        }
    }

    // `<exe dir>/../share/ghostty`, which is the layout `zig build` produces
    // (`bin/` beside `share/`) and the one the core's own climb expects.
    let Ok(exe) = std::env::current_exe() else {
        // process-wide: the resources directory is one per process; every window reads the same one
        plogf!("[res] current_exe() failed; POLTER_RESOURCES_DIR not set, so plugins, skills, themes and shell integration will all be absent");
        return;
    };
    let Some(bin) = exe.parent() else {
        // process-wide: the resources directory is one per process; every window reads the same one
        plogf!("[res] the executable has no parent directory; POLTER_RESOURCES_DIR not set");
        return;
    };

    // Two candidates: a `share/` beside the executable (a flat deployment,
    // which is how a test build is handed out), and one a level up next to
    // `bin/` (the layout `zig build` produces and the core's own climb
    // expects).
    //
    // # The order is the specific one first, and that is a fix rather than a
    // preference
    //
    // It used to be the other way round, because that was the canonical
    // install layout and the flat one read as the special case. **Nothing had
    // decided what should happen when both exist**, and on the test machine
    // both did: a build unpacked into `D:\polter\polter-<commit>\` found
    // `D:\polter\share\ghostty`, left over from an older deployment, and
    // used it.
    //
    // **That failure is worse than the one this function already reports.**
    // A missing directory leaves a line saying so, and somebody can read it.
    // This one logged a directory, logged that all four of its parts were
    // present, and then ran another version's plugins and themes -- so the
    // report that comes back is "the theme is wrong" and "a plugin behaves
    // oddly", with nothing in it about resources at all.
    //
    // Checking the flat location first cannot cost the canonical layout
    // anything: an install with `bin/` beside `share/` has no `share/` next
    // to the executable, so it falls through. The reverse is not true, which
    // is the whole asymmetry -- **the more specific location is the one that
    // cannot be claimed by accident.**
    //
    // Deliberately overriding from outside is still possible and still comes
    // first: `POLTER_RESOURCES_DIR`, handled above.
    //
    // **`parent()` rather than joining `..`**, so the path that reaches the
    // log and the environment is already normalised. The old form printed
    // `…\polter-<commit>\..\share\ghostty`, which reads as "inside the
    // package" unless somebody notices the two dots.
    let up = bin.parent().map(|p| p.join("share").join("ghostty"));
    let candidates: Vec<(std::path::PathBuf, &str)> = match up {
        Some(u) => vec![
            (bin.join("share").join("ghostty"), "beside the executable"),
            (u, "one level above the executable, NOT part of this package"),
        ],
        None => vec![(bin.join("share").join("ghostty"), "beside the executable")],
    };
    for (cand, where_) in &candidates {
        if cand.join("poltergeist").is_dir() {
            let s = cand.to_string_lossy().into_owned();
            std::env::set_var("POLTER_RESOURCES_DIR", &s);
            // **Where it came from, in words, on the same line.** A reader
            // comparing two paths character by character is a reader who will
            // eventually not bother; a clause saying which of the two it is
            // does not need comparing.
            // process-wide: the resources directory is one per process; every window reads the same one
            plogf!("[res] POLTER_RESOURCES_DIR = {:?} ({})", s, where_);
            report_resources_dir(cand);
            return;
        }
    }

    // **Nothing was set, and this says what was looked at.** Setting a path
    // that fails the core's probe is the same as setting nothing, so guessing
    // would buy nothing and would cost the reader this list.
    // process-wide: the resources directory is one per process; every window reads the same one
    plogf!(
        "[res] no resources directory found next to the executable; POLTER_RESOURCES_DIR left unset. Looked at: {}",
        candidates
            .iter()
            .map(|(c, w)| format!("{:?} ({})", c.to_string_lossy(), w))
            .collect::<Vec<_>>()
            .join(", ")
    );
    // process-wide: the resources directory is one per process; every window reads the same one
    plogf!(
        "[res] consequence: plugins, skills, themes and shell integration are all unavailable, and none of them reports its own absence"
    );
}

/// One line naming what is actually in the directory.
///
/// **Each of the four is checked separately**, because each is a different
/// feature going quiet and the core reports none of them.
fn report_resources_dir(dir: &std::path::Path) {
    let has = |sub: &str| dir.join(sub).is_dir();
    // process-wide: the resources directory is one per process; every window reads the same one
    plogf!(
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
        // process-wide: a null surface names no window; that is the report
        plogf!("[action] binding {:?} asked for on a null surface; nothing done", name);
        return false;
    }
    unsafe { (api().surface_binding_action)(surface, name.as_ptr(), name.len()) }
}

/// Drive a binding on **the first window's** focused surface.
///
/// The accelerators and the menu reach this without saying which window they
/// came from. That is a gap rather than a decision: threading the window
/// through the accelerator table is its own change. Written down here so the
/// next reader sees an assumption instead of an answer.
pub fn binding(name: &str) -> bool {
    let s = tabs::active_surface(tabs::overlay_frame());
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
            surface_mouse_button: sym!(internal, "ghostty_surface_mouse_button"),
            surface_mouse_pos: sym!(internal, "ghostty_surface_mouse_pos"),
            surface_mouse_scroll: sym!(internal, "ghostty_surface_mouse_scroll"),
            surface_read_text: sym!(internal, "ghostty_surface_read_text"),
            surface_free_text: sym!(internal, "ghostty_surface_free_text"),
            cli_try_action: sym!(internal, "ghostty_cli_try_action"),
            codepoint_width: sym!(vt, "ghostty_unicode_codepoint_width"),
            grapheme_width: sym!(vt, "ghostty_unicode_grapheme_width"),
        })
    }
}

// ------------------------------------------------------- dying out loud

/// Where the log goes, resolved once while the process is healthy.
///
/// **Resolved at hook install, not at panic time.** `log_path` reads an
/// environment variable and asks for the executable's path; neither takes a
/// lock, but both allocate, and the panic path is the one place where doing
/// less is worth more than doing it lazily.
static PANIC_LOG: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();

/// Set while the hook is running, so a panic *inside* the hook does not
/// recurse into it.
static IN_PANIC_HOOK: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Write bytes to the real stderr handle, **taking no Rust lock**.
///
/// `eprintln!` goes through `std::io::Stderr`, which holds a lock. That lock
/// is re-entrant for the same thread and would almost certainly be fine --
/// and "almost certainly fine" is the wrong standard for the one code path
/// that only ever runs when something has already gone wrong.
fn raw_stderr(bytes: &[u8]) {
    use windows::Win32::System::Console::{GetStdHandle, STD_ERROR_HANDLE};
    unsafe {
        if let Ok(h) = GetStdHandle(STD_ERROR_HANDLE) {
            if !h.is_invalid() {
                let mut wrote = 0u32;
                let _ = windows::Win32::Storage::FileSystem::WriteFile(
                    h,
                    Some(bytes),
                    Some(&mut wrote),
                    None,
                );
            }
        }
    }
}

/// **Say so in the log file before dying.**
///
/// Without this, a panic in this program leaves *no evidence anywhere we
/// collect*. Three separate reasons, and each of them alone is enough:
///
///  - `[main] exiting` is printed **after** the message loop, so no abnormal
///    termination reaches it.
///  - The default hook writes to **stderr**, and `log_line` writes stdout and
///    the file. Nothing tees stderr into the file, and the file is the only
///    artifact anybody collects off the test machine.
///  - The process is launched detached, so its console -- this is a
///    `WINDOWS_CUI` binary, measured, not assumed -- is attached to nobody.
///
/// The result is that "no panic, no stderr, no exiting line" was recorded as
/// an unexplained death **twice**, when those three readings are true of
/// every panic this binary can have. They were never facts about the defect;
/// they were facts about where we were looking.
///
/// # What it takes no lock for, and why that is the whole design
///
/// **A panic hook runs before unwinding, so every lock the panicking thread
/// holds is still held.** A hook that needs one of them deadlocks -- a hung
/// process, which is harder to diagnose than the crash it replaced -- or
/// panics again, and `panic while panicking` aborts immediately with *less*
/// output than the default hook would have produced.
///
/// So this path touches nothing the rest of the program locks:
///
///  - the log path is already resolved (`PANIC_LOG`);
///  - the file is opened fresh here, so no shared handle and no `Mutex`;
///  - stderr is written through `WriteFile`, not `std::io::Stderr`;
///  - **it does not call `logf!`/`wlogf!`.** `wlogf!` would ask `winid` for a
///    window number, which takes `FRAMES` -- and a panic inside anything that
///    already holds `FRAMES` would then hang instead of reporting.
///
/// # What it does not catch, said out loud
///
/// Only Rust panics. An access violation, a stack overflow, an `abort()` from
/// the C side, an OOM kill: none of them come through here and none will
/// write a line. **That is not a shortcoming, it is the reading this buys.**
/// After this exists, a silent death with an empty log *rules panics out* --
/// which is a fact nobody could establish before.
fn install_panic_hook() {
    let _ = PANIC_LOG.set(log_path());
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        use std::sync::atomic::Ordering as O;
        // A panic inside this hook must not come back round. It gets one
        // fixed line through the lock-free path and nothing else.
        if IN_PANIC_HOOK.swap(true, O::SeqCst) {
            raw_stderr(b"[panic] panicked while reporting a panic; giving up\n");
            return;
        }

        let thread = std::thread::current();
        let name = thread.name().unwrap_or("<unnamed>").to_string();
        let where_ = match info.location() {
            Some(l) => format!("{}:{}:{}", l.file(), l.line(), l.column()),
            None => "<no location>".to_string(),
        };
        // `PanicHookInfo::payload_as_str` is not stable in this edition, so
        // the two shapes the standard library actually produces are read
        // directly. Anything else is reported as unrenderable rather than
        // silently becoming an empty message.
        let payload = info.payload();
        let msg = if let Some(s) = payload.downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = payload.downcast_ref::<String>() {
            s.clone()
        } else {
            "<panic payload is not a string>".to_string()
        };

        let line = format!(
            "[{}] [panic] thread {:?} panicked at {}: {}\n",
            now_str(),
            name,
            where_,
            msg
        );

        // The file first: it is the artifact that leaves the machine.
        if let Some(path) = PANIC_LOG.get() {
            use std::io::Write as _;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                let _ = f.write_all(line.as_bytes());
                let _ = f.flush();
            }
        }
        raw_stderr(line.as_bytes());

        IN_PANIC_HOOK.store(false, O::SeqCst);
        // **The default hook still runs.** It prints the backtrace, which
        // this does not reproduce; taking that away to add a log line would
        // trade one kind of evidence for another.
        previous(info);
    }));
}

/// `--panic-test[=MODE]`: panic on purpose, so the hook can be shown to work.
///
/// **A hook nobody has seen speak is indistinguishable from no hook**, and
/// the way that failure presents itself is the next silent death being
/// recorded as unexplained again -- except that this time everyone believes
/// the instrument is installed.
///
/// Three modes, because "the hook writes a line" is easy in the easy case and
/// silent deaths do not happen in the easy case:
///
///  - `--panic-test` -- plain panic on the main thread.
///  - `--panic-test=locked` -- panic **while holding the window-state lock**,
///    which is the case the design above exists for: a hook that reached for
///    that lock would hang here instead of reporting.
///  - `--panic-test=thread` -- panic on a spawned thread. In a debug build
///    (`panic = "abort"` is set only on `[profile.release]`) this kills the
///    thread and **leaves the process running**, so the log line is the only
///    evidence the thread ever died.
///
/// It is an instrument, not a detour: nothing about the ordinary path changes
/// because this exists, and without the argument none of it runs.
fn maybe_panic_test() {
    let Some(arg) = std::env::args().find(|a| a.starts_with("--panic-test")) else {
        return;
    };
    let mode = arg.strip_prefix("--panic-test=").unwrap_or("plain").to_string();
    logf!("--panic-test={mode}: panicking on purpose to prove the hook speaks");
    match mode.as_str() {
        "locked" => {
            tabs::with_windows_mut(|_ws| {
                panic!("--panic-test=locked: panicking with the window-state lock held");
            });
        }
        "thread" => {
            let h = std::thread::Builder::new()
                .name("polter-panic-test".into())
                .spawn(|| panic!("--panic-test=thread: panicking off the main thread"))
                .expect("could not spawn the panic-test thread");
            // Joining an already-panicked thread returns `Err`; reported
            // rather than unwrapped, because unwrapping here would panic a
            // second time and confuse the reading this test exists to give.
            let joined_ok = h.join().is_ok();
            logf!(
                "--panic-test=thread: the thread has ended (joined_ok={joined_ok}); \
                 the process is still running, which is the point"
            );
        }
        _ => panic!("--panic-test: panicking on the main thread on purpose"),
    }
}

/// This executable's own full path.
///
/// **The string the operating system gives back is used whole and is never
/// taken apart.** `GetModuleFileNameW` already answers the question "where am
/// I", correctly for a renamed executable and for one copied somewhere else,
/// because it reports the module that is actually loaded rather than anything
/// derived from `argv[0]` or from `PATH`. Every bug this function exists to
/// avoid comes from *doing something* to that answer -- joining it to a
/// directory, splitting it on a separator, re-resolving it -- and the
/// directory this repository lives in has a space in its name, so a split
/// would be wrong on the machine it is developed on.
///
/// The caller quotes it as one unit. That is not "handling spaces"; it is the
/// same rule -- the path stays one value from here to `CreateProcessW`.
fn own_exe_path() -> Option<String> {
    // 32K units: the documented ceiling for a path with the `\\?\` prefix.
    // Sized once rather than grown, because the retry loop is the part that
    // gets the truncation case wrong.
    let mut buf = vec![0u16; 32768];
    let n = unsafe { GetModuleFileNameW(None, &mut buf) } as usize;
    if n == 0 || n >= buf.len() {
        // process-wide: this is about the executable, not any window
        plogf!("[cli] GetModuleFileNameW failed or truncated (n={n})");
        return None;
    }
    Some(String::from_utf16_lossy(&buf[..n]))
}

/// Did the command line ask for a `+action`?
///
/// Answered here as well as by the core because two things depend on it
/// before the core is initialised, and one of them is not obvious: a CLI
/// action is a **terminal program**, and this host otherwise turns on
/// `GHOSTTY_LOG=stderr`. Logging to stderr underneath a full-screen TUI
/// scribbles over it. The other is that there is no reason to open a window.
fn cli_action_requested() -> bool {
    std::env::args().skip(1).any(|a| a.starts_with('+'))
}

/// Say whether the tester's notes are beside this program.
///
/// # Why this is a reading and not a pointer
///
/// The obvious line is "see TESTING.md next to this program". **That sentence
/// is false whenever the file was not copied**, which is the case it exists
/// to help with -- and a false line is worse than none, because someone who
/// looks and finds nothing concludes the log is stale rather than that the
/// packaging missed a file.
///
/// So this looks, and says which. **Present**: go and read it. **Absent**:
/// there is such a document and this copy did not come with one, so ask for
/// it. Nothing here can make the file arrive; what it can do is make its
/// absence visible instead of silent, which is the same bargain the build
/// identity line above strikes with a mismatched pair.
///
/// A missing file is not an error and nothing is refused because of it.
fn log_testing_notes() {
    let beside = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|d| d.join("TESTING.md")));
    match beside {
        // process-wide: a file beside the executable; no window is involved
        Some(p) if p.is_file() => plogf!("[build] tester's notes: {}", p.display()),
        // process-wide: as above -- the absence of a file beside the
        // executable belongs to the process, not to any window
        Some(p) => plogf!(
            "[build] tester's notes: NOT here ({} does not exist). \
             There is such a document; this copy did not come with one, so ask \
             whoever built it for TESTING.md.",
            p.display()
        ),
        // process-wide: as above
        None => plogf!(
            "[build] tester's notes: cannot tell -- this program cannot find its own \
             directory, so it cannot say whether TESTING.md is beside it."
        ),
    }
}

/// Give this process a stdout and a stderr **when Windows gave it none**.
///
/// # What this is for
///
/// A GUI subsystem process started from Explorer has no console, so
/// `GetStdHandle` answers with nothing for both streams. Two things write
/// there and have nowhere else to go: libghostty's log (`GHOSTTY_LOG=stderr`
/// is the only sink the core has on Windows) and the default panic hook's
/// backtrace. Pointing the missing handles at the log file keeps both, so
/// "the window is gone" cannot quietly also mean "the log is gone".
///
/// # Only the ones nobody gave us, and that rule is the whole design
///
/// A handle we already have came from whoever started us, and it is theirs,
/// not ours to redirect: a tester running `polter-host.exe > out.log 2>&1`
/// asked for that file, and an agent CLI that started `polter-host.exe +mcp`
/// handed us a **pipe it is speaking a protocol over**. Redirecting either
/// would be this change taking away output while claiming to take away a
/// window. So each stream is examined on its own and an existing one is left
/// exactly alone.
///
/// # Ordering
///
/// After `write_log_bom`, which is a `File::create` and therefore truncates:
/// a handle opened before it would be pointing into a file that then went
/// back to length zero. Before `install_panic_hook`, so that the default
/// hook's backtrace -- which this program does not reproduce itself -- has
/// somewhere to land from the first moment it could be needed.
///
/// The file handle is opened `FILE_APPEND_DATA` and deliberately never
/// closed. Append access is what makes the interleaving safe: every write
/// goes to the end of the file as one operation, so the core writing through
/// this handle and `log_line` opening the same path per line cannot land on
/// top of each other.
///
/// Returns the line to log about what it did. **It is returned rather than
/// logged here because the log banner has not been written yet**, and a line
/// above the banner is a line a reader cannot attribute to this run.
fn adopt_std_handles() -> String {
    use std::os::windows::ffi::OsStrExt as _;
    use windows::Win32::Storage::FileSystem::{
        CreateFileW, FILE_APPEND_DATA, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE,
        OPEN_ALWAYS,
    };
    use windows::Win32::System::Console::{
        GetStdHandle, SetStdHandle, STD_ERROR_HANDLE, STD_HANDLE, STD_OUTPUT_HANDLE,
    };

    let have = |id: STD_HANDLE| -> bool {
        match unsafe { GetStdHandle(id) } {
            Ok(h) => !h.is_invalid(),
            Err(_) => false,
        }
    };

    let missing: Vec<(STD_HANDLE, &str)> = [(STD_OUTPUT_HANDLE, "stdout"), (STD_ERROR_HANDLE, "stderr")]
        .into_iter()
        .filter(|(id, _)| !have(*id))
        .collect();

    if missing.is_empty() {
        return "[stdio] stdout and stderr both came from whoever started us;                 leaving them alone"
            .to_string();
    }

    let mut wide: Vec<u16> = log_path().as_os_str().encode_wide().collect();
    wide.push(0);
    let file = unsafe {
        CreateFileW(
            PCWSTR::from_raw(wide.as_ptr()),
            FILE_APPEND_DATA.0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            None,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            None,
        )
    };
    let Ok(file) = file else {
        // Said out loud: from here the core's log and any backtrace have
        // nowhere to go, and the shape of that failure is silence.
        return format!(
            "[stdio] {} missing and the log file could not be opened for them;              libghostty's log and any panic backtrace have NO sink this run",
            missing.iter().map(|(_, n)| *n).collect::<Vec<_>>().join(" and ")
        );
    };

    let mut adopted: Vec<&str> = Vec::new();
    let mut refused: Vec<&str> = Vec::new();
    for (id, name) in missing {
        match unsafe { SetStdHandle(id, file) } {
            Ok(()) => adopted.push(name),
            Err(_) => refused.push(name),
        }
    }

    let mut line = format!("[stdio] no console: {} now point at this log file", adopted.join(" and "));
    if !refused.is_empty() {
        line.push_str(&format!("; SetStdHandle refused {}", refused.join(" and ")));
    }
    line
}

/// Start the log file with a UTF-8 byte order mark.
///
/// # The log was never written wrong; it was read wrong
///
/// `log_line` hands a Rust `String` to `writeln!`, which writes its UTF-8
/// bytes and nothing else -- there is no re-encoding anywhere in this host.
/// So a line reading `commit="浣犲搱濂?"` is not a mangled write. It is a
/// correct file **decoded as GBK**, which is what several standard Windows
/// tools do by default on a Chinese system: Windows PowerShell 5.1's
/// `Get-Content` uses the ANSI code page unless told otherwise, and so does
/// `type` in a console whose code page is 936.
///
/// **The trailing `?` is the tell**: it is a lossy replacement, which only
/// happens on the way *in*, not on the way out.
///
/// # So why change anything
///
/// Because "the file is fine, you read it wrong" is a fact that has to be
/// known before it helps, and the person reading a log at 3am does not know
/// it. **A three-byte mark makes the file say what it is**, and the same
/// tools then decode it correctly with no argument: PowerShell, Notepad, VS
/// Code and Windows' own editors all honour it.
///
/// **What it costs**, said plainly: the three bytes sit at the start of the
/// first line, so a `findstr` pattern anchored to the very beginning of the
/// file will not match. The first line is the startup banner, which nobody
/// anchors to.
fn write_log_bom() {
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::File::create(log_path()) {
        let _ = f.write_all("\u{feff}".as_bytes());
    }
}

fn main() {
    let _ = std::fs::remove_file(log_path());
    // **Before the first line, and before the panic hook.** A mark written
    // later would sit in the middle of the file, where it is not a mark but a
    // stray character.
    write_log_bom();
    // **After the mark and before the hook**, for the two reasons written on
    // the function. Its verdict is logged below rather than here, because
    // there is no banner above this point to attribute a line to.
    let stdio = adopt_std_handles();
    // **First, ahead of the banner.** Everything below can panic, and a panic
    // before the hook is installed leaves exactly the evidence the last two
    // silent deaths left: none.
    install_panic_hook();
    logf!(
        "=== Polter host (Windows) === pid={} log={}",
        std::process::id(),
        log_path().display()
    );
    logf!("{stdio}");
    maybe_panic_test();

    if std::env::args().any(|a| a == "--draw-on-paint") {
        DRAW_ON_PAINT.store(1, Ordering::Relaxed);
        logf!("NOTE: --draw-on-paint enabled (main-thread draw; see status.md)");
    }

    log_build_identity();
    log_testing_notes();

    let api_box = match load_api() {
        Some(a) => Box::leak(Box::new(a)),
        None => {
            logf!("FATAL could not load libghostty");
            return;
        }
    };
    API.store(api_box as *mut Api as *mut c_void, Ordering::Release);

    // **As early as the core can be asked, and before anything uses it.** The
    // verdict is worth most to a reader who has not yet started explaining a
    // symptom to themselves -- once "this feature was never written" is in
    // their head, a line further down the log is read as being about
    // something else.
    {
        let info = unsafe { (api_box.info)() };
        let version = if info.version.is_null() || info.version_len == 0 {
            String::new()
        } else {
            let bytes =
                unsafe { std::slice::from_raw_parts(info.version as *const u8, info.version_len) };
            String::from_utf8_lossy(bytes).into_owned()
        };
        log_pairing(&version);
    }

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
    //
    // # Everything above stops applying under a `+action`
    //
    // **Read this before deleting the guard below.** The person most likely
    // to delete it is the one who arrives here wanting exactly what the
    // paragraphs above argue for: they are debugging `+chat`, they can see no
    // core logging, and turning it back on is one line away.
    //
    // What happens when they do is not "more output". `+chat` is a
    // **full-screen TUI drawing on this same stderr**, so a log line is
    // painted into the middle of it. The symptom is a chat window with
    // debris in it, which reads as a broken TUI -- so the change that caused
    // it is the last place anyone looks.
    //
    // **The escape hatch is already here and needs no edit**: the `Ok` arm
    // above honours an explicit `GHOSTTY_LOG`. Set it in the environment for
    // the run you are debugging, and redirect stderr somewhere the TUI is
    // not. That gets the logging without leaving it on for every user who
    // opens the chat.
    //
    // This host's own log file is unaffected either way -- `logf!` writes
    // there, not to stderr -- so a `+action` still leaves a record.
    match std::env::var("GHOSTTY_LOG") {
        Ok(v) => logf!("GHOSTTY_LOG already set to {:?}; leaving it", v),
        Err(_) if cli_action_requested() => {
            // process-wide: a logging sink for the whole process, decided
            // before any window exists
            plogf!("[cli] +action: leaving GHOSTTY_LOG unset so the TUI owns stderr");
        }
        Err(_) => {
            std::env::set_var("GHOSTTY_LOG", "stderr");
            logf!("GHOSTTY_LOG=stderr (core logging to this process's stderr)");
        }
    }

    // **Before `ghostty_init`, because the core reads it during startup.**
    announce_resources_dir();

    // ghostty_init takes (argc, argv); argv is a non-optional pointer on the
    // Zig side, so hand it a real one rather than null.
    //
    // **This argv is not where the core gets our arguments on Windows.**
    // `global.zig` takes the real command line from `GetCommandLineW()` on
    // this target, because `std.process.Args.Vector` there is a WTF-16
    // command-line string and not an argv array. This pair is still passed
    // because the parameter is non-optional; it is not read.
    let arg0 = CString::new("polter-host.exe").unwrap();
    let argv: [*const std::os::raw::c_char; 2] = [arg0.as_ptr(), std::ptr::null()];
    let rc = unsafe { (api_box.init)(1, argv.as_ptr()) };
    logf!("ghostty_init -> {}", rc);
    if rc != 0 {
        logf!("FATAL ghostty_init failed");
        return;
    }

    // **A `+action` ends here, and the call does not come back.**
    //
    // The same line `macos/Sources/App/main.swift` has. It is placed after
    // `ghostty_init` because that is what fills in `global.action()` -- before
    // it there is nothing to run -- and before any window is made, because a
    // CLI action is a terminal program and has no window.
    //
    // Until `global.zig` was taught to read `GetCommandLineW()` this was inert
    // on Windows: the core parsed an action out of an empty string and got
    // null, so `polter-host.exe +chat` opened an ordinary shell. That is the
    // half of "terminal group chat does nothing" that is on this side.
    if cli_action_requested() {
        // process-wide: a CLI action runs before any window exists, and this
        // path never makes one
        plogf!("[cli] a +action was asked for; handing over to the core");
        unsafe { (api_box.cli_try_action)() };
        // Reached only if the core found nothing to run -- a `+` argument
        // that is not an action name. **Said out loud rather than falling
        // through into a window**, because a typo that silently opens a
        // terminal looks like the action ran.
        // process-wide: same path, still no window -- that is what the line says
        plogf!("[cli] the core did not recognise it; not opening a window");
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

    let Some(hwnd) = create_frame(hinst, true) else {
        logf!("FATAL could not create the first frame");
        return;
    };

    // A static prompt cannot distinguish "renderer still drawing" from
    // "renderer frozen" -- Windows blits the client area during a move either
    // way. --clock types a ticking clock into the shell so the screen has
    // something that visibly advances.
    // `--ops-delay=N`: hold each queued op N milliseconds before running it.
    //
    // **A stopwatch on the existing path, not a second path.** It is what
    // makes "move the focus between queueing and running" an experiment
    // somebody can actually perform: without it the two happen in the same
    // millisecond and there is no interval to act in. See `tabs::set_ops_delay`
    // for why the delay is applied to running rather than to queueing -- the
    // other version of this hook reads identically and makes every experiment
    // that uses it vacuous.
    if let Some(v) = std::env::args().find_map(|a| a.strip_prefix("--ops-delay=").map(str::to_owned))
    {
        match v.parse::<u64>() {
            Ok(ms) => tabs::set_ops_delay(ms),
            // process-wide: an argument the process was started with, before
            // any window exists to attribute it to
            Err(_) => plogf!("[ops] --ops-delay={:?} is not a number; the hook stays off", v),
        }
    }

    if std::env::args().any(|a| a == "--clock") {
        tabs::set_initial_input(
            "powershell -NoProfile -Command \"while($true){Get-Date -Format HH:mm:ss.fff; \
             Start-Sleep -Milliseconds 250}\"\r\n",
        );
        logf!("--clock: the first tab will run a ticking clock");
    }

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
            tabs::window(hwnd).map(|w| w.initial.is_some()).unwrap_or(false)
        );
        session::restore(hwnd, !(has_x || has_y), !configured_size);
    }

    // Before the first tab, because the first tab can be closed. `reopen.rs`
    // keeps the stack and `tabs.rs` builds the tabs; this is the one line
    // where the two are introduced.
    tabs::install_reopen_opener();
    // process-wide: one closed-tab stack for the whole process, installed once
    // at startup -- there is no window for this line to belong to, and the
    // stack it reports is shared by all of them
    plogf!("[reopen] opener installed; stack {:?}", reopen::stack_depth());

    // ---- first tab ----
    if !tabs::create_tab(hwnd, app, hinst) {
        logf!("FATAL could not create the first tab");
        return;
    }
    tabs::layout(hwnd);
    logf!("tab count = {}", tabs::count(hwnd));

    // TSF is stood up against the first tab's window; every later tab is
    // associated with the same document manager as it is created.
    let first = tabs::active_hwnd(hwnd);
    if !first.0.is_null() && ime_init(first) {
        // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
        plogf!("[ime] TSF up; switch to a Chinese IME and type");
        unsafe {
            let _ = SetFocus(Some(first));
        }
    } else {
        // process-wide: TSF is one per thread -- one manager, one document, one context for the whole process; this line reports a step of that single setup
        plogf!("[ime] TSF init FAILED -- terminal still works, IME does not");
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
                // **What was waiting before we asked** -- see `PUMP_SWALLOWED`.
                //
                // `ITfMessagePump::PeekMessageW` is called with `PM_REMOVE`, so
                // TSF takes the message off the queue and then decides whether
                // to hand it back. **A key it removes and does not return
                // leaves no trace anywhere**: `TestKeyDown` is never asked, so
                // there is no `TSF ate` line; nothing is dispatched, so there
                // is no `[key]` line. That is not a hypothetical -- a log with
                // 3,530 lines and `TSF ate` zero times still lost two
                // keydowns.
                //
                // `PM_NOREMOVE` only looks. It does not change which code the
                // key goes through, only whether we can see that it did.
                let mut waiting = MSG::default();
                let waiting_key = if PeekMessageW(
                    &mut waiting,
                    None,
                    WM_KEYFIRST,
                    WM_KEYLAST,
                    PM_NOREMOVE,
                )
                .as_bool()
                {
                    // **Only the parts of a key message that identify the
                    // key.** Two earlier versions of this got it wrong, and the
                    // way they were wrong is worth more than the fix.
                    //
                    // The first compared `time` as well; that was removed on
                    // the theory that a message passing through
                    // `ITfKeystrokeMgr` can come back with a different
                    // timestamp. **That theory was not wrong, it was
                    // incomplete** -- the identity still never matched, and the
                    // diagnostic below finally named the field:
                    //
                    // ```
                    // expected  lp=0x40310001
                    // returned  lp=0x00310001
                    // ```
                    //
                    // The difference is `0x40000000`, **bit 30 of lParam: the
                    // previous key state.** It describes the keyboard at the
                    // moment of observation, not the key -- so it can and does
                    // differ between two looks at the same message. Bit 31
                    // (transition state) is the same kind of thing.
                    //
                    // **Finding one field that really does vary is what stopped
                    // the search**, and there was a second one behind it. So
                    // this now keeps only what cannot drift: the message, the
                    // virtual key, and lParam's scan code (bits 16-23) with its
                    // extended flag (bit 24).
                    Some((
                        waiting.message,
                        waiting.wParam.0,
                        waiting.lParam.0 & KEY_IDENTITY_LPARAM,
                    ))
                } else {
                    None
                };

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

                if let Some(id) = waiting_key {
                    PUMP_KEYS_SEEN.fetch_add(1, Ordering::Relaxed);
                    log_hkl_if_changed();
                    let returned = got
                        && (msg.message, msg.wParam.0, msg.lParam.0 & KEY_IDENTITY_LPARAM) == id;
                    if returned {
                        PUMP_KEYS_RETURNED.fetch_add(1, Ordering::Relaxed);
                    } else {
                        // Not returned. It may simply still be queued -- the
                        // pump is allowed to hand back something else first --
                        // so being gone is the part that means anything.
                        let mut after = MSG::default();
                        let still = PeekMessageW(
                            &mut after,
                            None,
                            WM_KEYFIRST,
                            WM_KEYLAST,
                            PM_NOREMOVE,
                        )
                        .as_bool()
                            && (
                                after.message,
                                after.wParam.0,
                                after.lParam.0 & KEY_IDENTITY_LPARAM,
                            ) == id;

                        // **Reported once, whichever branch we are in.**
                        //
                        // The first version only spoke when the pump had handed
                        // back a *key* message. It happened to fire -- and that
                        // was luck: had the pump returned something else, or
                        // nothing, it would have stayed silent and `returned=0`
                        // would have been an unexplained number all over again.
                        // **A diagnostic that only covers one branch has a
                        // silence that means several different things**, which
                        // is the fault it was added to remove.
                        if !MISMATCH_LOGGED.swap(true, Ordering::Relaxed) {
                            // process-wide: about the probe, not a window
                            plogf!(
                                "[key] pump probe: expected msg=0x{:x} wp=0x{:x} lp=0x{:x}; \
                                 got={} returned msg=0x{:x} wp=0x{:x} lp=0x{:x}; \
                                 still_queued={} (reported once. When got=false the returned \
                                 fields are stale and mean nothing.)",
                                id.0, id.1, id.2,
                                got,
                                msg.message, msg.wParam.0,
                                msg.lParam.0 & KEY_IDENTITY_LPARAM,
                                still
                            );
                        }

                        if !still {
                            let n = PUMP_SWALLOWED.fetch_add(1, Ordering::Relaxed) + 1;
                            if n <= SWALLOW_LOG_CAP {
                                // process-wide: the pump serves the thread
                                plogf!(
                                    "[key] pump swallowed msg=0x{:x} vk=0x{:02x} \
                                     (removed from the queue and never returned; \
                                     composing={:?} {})",
                                    id.0,
                                    id.1 as u16,
                                    composing_now(),
                                    crate::keys::binding_probe(
                                        id.0,
                                        WPARAM(id.1),
                                        LPARAM(id.2),
                                    )
                                );
                            }
                            if n == SWALLOW_LOG_CAP {
                                // process-wide: about the log, not a window
                                plogf!(
                                    "[key] pump swallowed: reached the {} line cap; further ones \
                                     are counted, not printed. The total is on the exit line.",
                                    SWALLOW_LOG_CAP
                                );
                            }
                        }
                    }
                }

                if !got {
                    break;
                }
                if msg.message == WM_QUIT {
                    break 'outer;
                }

                // **Chords that are ours are not offered to TSF at all.**
                //
                // While an input method composes, TSF claims keys before the
                // core is ever asked -- a real machine showed `ctrl`, `shift`
                // and `c` all taken with `composing=Some(true)`, so every
                // application shortcut was dead for as long as a candidate
                // window was open. This is the one point where that can be
                // changed: `TestKeyDown` is the earliest we are consulted, and
                // a key TSF takes never reaches a window procedure at all.
                //
                // # Only `performable=no`, and that is not a safety margin
                //
                // We ask the core here, and the core will decide again after
                // dispatch. Two evaluations, and state could differ between
                // them -- **except for exactly the class we intercept**: a
                // binding that is *not* `performable` does not depend on
                // terminal state, which is what "not performable" means. So
                // the one kind of key we take away is the one kind whose two
                // answers cannot disagree. **The risk is not mitigated here,
                // it is absent.**
                //
                // Intercepting a `performable` binding would be the opposite:
                // the core would decline it after we had already taken it from
                // the input method, the host accelerator table would decline
                // it too, and the key would be handled by nobody -- **worse
                // than today, where at least the IME uses it.**
                //
                // # What this changes outside composition, and when that stops
                //   being harmless
                //
                // This is not conditional on composing -- deliberately: the
                // `composing` flag is unreliable for the first key of a
                // composition, and it is not needed, because that first key is
                // a bare letter and answers `binding=no` anyway. **One less
                // piece of state is one less thing to be wrong.**
                //
                // The consequence is that input methods now never see any
                // chord we bind non-performably, composing or not. **Today
                // that costs nothing**, because nothing in our table is a
                // chord an IME wants: `ctrl+space` (IME on/off), `ctrl+.`
                // (punctuation width) and `ctrl+shift` (layout switch) are all
                // unbound by us.
                //
                // **That is a sentence about today.** The day somebody binds
                // one of them -- and we added eight bindings in a single
                // afternoon -- this line takes it away from the input method
                // silently: no error, no log, the key simply stops doing what
                // the IME user expects. Check that list before adding a chord
                // with `ctrl` and no `shift`.
                let ours = crate::keys::ask_binding(msg.message, msg.wParam, msg.lParam);
                if ours.may_intercept() {
                    // Trace only the first few, and only these: the question
                    // is where one interception loses a composition, not what
                    // every key does.
                    let t = TRACED.fetch_add(1, Ordering::Relaxed) + 1;
                    TRACING_INTERCEPT.store(t <= 10, Ordering::Release);
                    let n = INTERCEPTED.fetch_add(1, Ordering::Relaxed) + 1;
                    if n <= 40 {
                        // process-wide: the pump serves the thread, and this
                        // says what the pump did with a message
                        plogf!(
                            "[key] kept from TSF msg=0x{:x} vk=0x{:02x} composing={:?} \
                             ({})",
                            msg.message,
                            msg.wParam.0 as u16,
                            composing_now(),
                            ours.label()
                        );
                    }
                    if n == 40 {
                        // process-wide: about the log, not a window
                        plogf!(
                            "[key] kept from TSF: reached the 40 line cap; further ones are \
                             counted, not printed. The total is on the exit line."
                        );
                    }
                }

                // Not offered to TSF when it is ours: it falls through to
                // `TranslateMessage` + `DispatchMessageW` below, exactly as if
                // TSF had been asked and had declined.
                let mut eaten = false;
                if let Some(k) = &keystrokes.as_ref().filter(|_| !ours.may_intercept()) {
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
                            "[key] TSF ate msg=0x{:x} vk=0x{:02x} composing={:?} {} \
                             (not dispatched)",
                            msg.message,
                            msg.wParam.0 as u16,
                            composing_now(),
                            // **The same answer the decision used**, not a
                            // second call: two calls could disagree, and a log
                            // line that disagrees with the branch it is
                            // describing is worse than no line.
                            ours.label()
                        );
                    }
                    // **Say when the cap is reached.** Without this the line
                    // stops appearing and "no more were eaten" and "we stopped
                    // writing them down" become the same reading -- which is
                    // how a count of forty came to look like a count of forty
                    // events rather than a saturated counter.
                    if n == 40 {
                        // process-wide: about the log, not a window
                        plogf!(
                            "[key] TSF ate: reached the 40 line cap; further ones are counted, \
                             not printed. The total is on the exit line."
                        );
                    }
                } else {
                    trace_intercept("before TranslateMessage");
                    let _ = TranslateMessage(&msg);
                    trace_intercept("after TranslateMessage / before DispatchMessageW");
                    DispatchMessageW(&msg);
                    trace_intercept("after DispatchMessageW");
                }
                TRACING_INTERCEPT.store(false, Ordering::Release);
            }
            (api_box.app_tick)(app);
        }
        ticks += 1;
        TICKS.store(ticks, Ordering::Relaxed);

        // **Every window's queue, every tick, whether or not the hook is on.**
        //
        // `WM_POLTER_OP` still wakes the target window the moment something is
        // queued, so nothing here changes when an op runs in an ordinary run.
        // What it adds is a second driver that does not depend on a posted
        // message arriving -- which is what a held-back op needs, because the
        // message that would have run it has already been dispatched and
        // consumed.
        //
        // **Deliberately not gated on `ops_delay_ms() > 0`.** Gating it would
        // mean the hook changes which code drives the queue, and an
        // instrument that changes the path is measuring a different program
        // from the one that ships. This way the driver is the same in both
        // cases and the hook's whole effect is one comparison against a
        // timestamp.
        for w in winid::all() {
            tabs::run_ops(w, app, hinst);
        }

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
                tabs::count(hwnd),
                tabs::active_index(hwnd) + 1,
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
                tabs::count(hwnd),
                tabs::active_index(hwnd) + 1,
                zoomed,
                style
            );
            if step == script.len() {
                logf!("[selftest] selftest done -- {} steps executed", step);
                selftest_running = false;
            }
        }

        if selfresize && ticks == 625 {
            let sw = tabs::active_hwnd(hwnd);
            let mut rc = RECT::default();
            unsafe {
                let _ = GetClientRect(sw, &mut rc);
            }
            resize_before = Some((rc.right - rc.left, rc.bottom - rc.top));
            wlogf!(hwnd, 
                "[resize] before: surface client {}x{} center_pixel=0x{:06x}",
                rc.right - rc.left,
                rc.bottom - rc.top,
                center_pixel(sw)
            );
            unsafe {
                let _ = SetWindowPos(hwnd, None, 0, 0, 1240, 820, SWP_NOMOVE | SWP_NOZORDER);
            }
            wlogf!(hwnd, "[resize] frame SetWindowPos -> 1240x820 issued");
        }
        if selfresize && ticks == 750 {
            let sw = tabs::active_hwnd(hwnd);
            let mut rc = RECT::default();
            unsafe {
                let _ = GetClientRect(sw, &mut rc);
            }
            let new = (rc.right - rc.left, rc.bottom - rc.top);
            wlogf!(hwnd, 
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
                    wlogf!(hwnd, 
                        "[resize] new-region pixel at ({},{}) = 0x{:06x}  (was outside {}x{}; \
                         0x000000 means nothing was drawn there)",
                        px,
                        py,
                        c,
                        old.0,
                        old.1
                    );
                }
                None => wlogf!(
                    hwnd,
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
            let sw = tabs::active_hwnd(hwnd);
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
    let open_tabs = tabs::count(hwnd);
    session::flush_if_dirty(hwnd);
    // process-wide: the process is leaving; by this point no window is left
    // for the line to be about
    plogf!("[main] exiting: session flushed, {} tabs were open", open_tabs);
    // **The counters, so an absence becomes a reading.**
    //
    // `swallowed=0` means nothing on its own -- it is also what a probe that
    // never ran prints. Next to `seen`, it says how many key messages went
    // past while the probe was watching, and only then is the zero worth
    // something.
    //
    let (seen, returned, swallowed) = (
        PUMP_KEYS_SEEN.load(Ordering::Relaxed),
        PUMP_KEYS_RETURNED.load(Ordering::Relaxed),
        PUMP_SWALLOWED.load(Ordering::Relaxed),
    );
    // process-wide: totals for the process
    plogf!(
        "[key] pump totals: seen={} returned={} swallowed={} tsf_ate={} kept_from_tsf={}",
        seen,
        returned,
        swallowed,
        TSF_ATE.load(Ordering::Relaxed),
        INTERCEPTED.load(Ordering::Relaxed)
    );
    // **The floor for the counter above, and it exists because the first
    // version shipped without one.** That version recorded all seventeen key
    // messages of a run as "swallowed" -- the identity check never matched
    // once -- and the numbers looked like a discovery rather than a broken
    // probe. `seen` is what gave it away, by being exactly equal to
    // `swallowed`.
    //
    // **A probe that cannot report its own failure hands you seventeen
    // findings instead of one fault**, so this says it plainly: in any run
    // where keys were pressed at all, some of them must have come back.
    if seen > 0 && returned == 0 {
        // process-wide: about the probe, not a window
        plogf!(
            "[key] pump probe is BROKEN: {} key message(s) went past and not one was \
             recognised coming back, so `swallowed={}` counts nothing but the check \
             failing. Do not read it as evidence of lost keys.",
            seen,
            swallowed
        );
    }
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

#[cfg(test)]
mod pairing_tests {
    use super::{core_commit, same_commit};

    /// The shape the core actually reports: a semantic version whose build
    /// metadata is the abbreviated commit.
    #[test]
    fn the_commit_comes_out_of_a_real_version_string() {
        assert_eq!(core_commit("1.3.2-HEAD-+1fe09f51b"), Some("1fe09f51b"));
        assert_eq!(core_commit("0.1.71-feature/v0.4+abc1234"), Some("abc1234"));
    }

    /// **Every way of failing to parse lands on `None`, and `None` is neither
    /// answer.**
    ///
    /// This is the rule the whole check turns on. The host's own commit is
    /// compiled in and never parsed, so a parse failure here cannot produce a
    /// false *match* -- it produces a false *mismatch*, which is worse in the
    /// way that matters: an alarm on a correctly matched pair is believed
    /// once and skipped forever after, and this line is worth something only
    /// while it is still read.
    #[test]
    fn anything_unparseable_is_unknown_rather_than_wrong() {
        for v in [
            "",                       // the core said nothing
            "1.3.2",                  // no build metadata at all
            "1.3.2-HEAD-+",           // a `+` with nothing after it
            "1.3.2-HEAD-+zzzz",       // not hexadecimal
            "1.3.2-HEAD-+ab",         // too short to mean anything
            "1.3.2+0123456789abcdef0123456789abcdef012345678", // too long to be a hash
            "some entirely new format the core grew later",
        ] {
            assert_eq!(core_commit(v), None, "{v:?} must be unknown, not a verdict");
        }
    }

    /// The core's own "git could not tell me" fallback is a real-looking hex
    /// string. **Two fallbacks comparing equal would manufacture a match out
    /// of two absences**, so it has to be refused by name.
    #[test]
    fn the_cores_unknown_fallback_is_not_a_commit() {
        assert_eq!(core_commit("1.3.2-HEAD-+0000000"), None);
    }

    /// Both sides abbreviate with git's own rule, which lengthens as a
    /// repository grows. **A length difference is not a mismatch**, and
    /// treating it as one would raise an alarm on a matched pair.
    #[test]
    fn a_shorter_abbreviation_of_the_same_commit_still_matches() {
        assert!(same_commit("1fe09f51b", "1fe09f5"));
        assert!(same_commit("1fe09f5", "1fe09f51b"));
        assert!(same_commit("ABC1234", "abc1234"), "hex case must not matter");
    }

    /// **The floor for the test above.** If `same_commit` answered `true` for
    /// everything -- which is what a too-eager prefix rule does -- the
    /// previous test would pass and the check would never fire again.
    #[test]
    fn different_commits_do_not_match() {
        assert!(!same_commit("1fe09f51b", "2fe09f51b"));
        assert!(!same_commit("abc1234", "abc1235"));
        // Too little in common to be an abbreviation of anything.
        assert!(!same_commit("ab", "abc1234"), "a stub must not match by prefix");
        assert!(!same_commit("", "abc1234"));
    }
}
