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

mod ffi;
mod keys;
mod tabs;
mod tsf;

use ffi::*;
use std::cell::RefCell;
use std::ffi::{c_void, CString};
use std::rc::Rc;
use std::sync::atomic::{AtomicPtr, AtomicU32, Ordering};

use windows::core::{s, w, Interface, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::HBRUSH;
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryA};
use windows::Win32::UI::HiDpi::{
    GetDpiForWindow, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
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

extern "C" fn cb_read_clipboard(_ud: *mut c_void, _kind: u32, _state: *mut c_void) -> bool {
    false
}
extern "C" fn cb_confirm_read_clipboard(
    _ud: *mut c_void,
    _s: *const std::os::raw::c_char,
    _state: *mut c_void,
    _req: u32,
) {
}
extern "C" fn cb_write_clipboard(
    _ud: *mut c_void,
    _kind: u32,
    _content: *const c_void,
    _n: usize,
    _confirm: bool,
) {
}
extern "C" fn cb_close_surface(_ud: *mut c_void, _confirm: bool) {
    logf!("[action] close_surface -> quitting");
    unsafe { PostQuitMessage(0) };
}

extern "C" fn cb_action(_app: App, _target: Target, action: Action) -> bool {
    use tabs::Op;
    match action.tag {
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
                tabs::post_op(Op::SetTabTitle(t));
            }
            true
        }
        ACTION_SET_TAB_TITLE => {
            if let Some(t) = action.as_cstr() {
                let t = t.to_string_lossy().to_string();
                logf!("[action] set_tab_title {:?}", t);
                tabs::post_op(Op::SetTabTitle(t));
            }
            true
        }
        ACTION_COPY_TITLE_TO_CLIPBOARD => {
            logf!("[action] copy_title_to_clipboard");
            tabs::post_op(Op::CopyTitleToClipboard);
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
            tabs::post_op(Op::MoveTab(d));
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
            logf!("[action] close_window/quit tag={}", action.tag);
            unsafe { PostQuitMessage(0) };
            true
        }
        ACTION_RENDER => true,
        _ => false,
    }
}

// ------------------------------------------------------------- window proc

/// The frame. It owns the tab strip, the window-level state, and nothing
/// else: keys, text and the IME live on the surface windows (`tabs.rs`),
/// because those know which surface they belong to.
extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            // The frame owns the strip only; it must still never let GDI
            // erase, or the strip flickers on every resize.
            WM_ERASEBKGND => LRESULT(1),

            WM_PAINT => {
                tabs::paint_strip(hwnd);
                LRESULT(0)
            }

            // The frame resizes; the active child follows and tells the core.
            WM_SIZE => {
                tabs::layout(hwnd);
                LRESULT(0)
            }

            // The composition is somewhere else on screen now even though its
            // text did not change. TSF does not come back to ask on its own.
            WM_MOVE => {
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

            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Drive a binding by name on the active surface. Returns what the core
/// said: false means it could not parse or could not perform it, and that
/// distinction is worth logging rather than swallowing.
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
            WS_OVERLAPPEDWINDOW,
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
    let selftest = std::env::args().any(|a| a == "--selftest");
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
        ("close_tab:this", "expect tab count 3 -> 2"),
    ];
    let mut step = 0usize;
    if selftest {
        logf!("--selftest: {} steps, one per second", script.len());
    }

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

        // One self-test step per ~1.2s, starting after 2s so the first
        // surface has settled.
        if selftest && ticks > 250 && ticks % 150 == 0 && step < script.len() {
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
        if selftest && ticks > 250 && ticks % 150 == 75 && step > 0 {
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
                logf!("[selftest] done -- {} steps executed", step);
            }
        }

        if selfresize && ticks == 625 {
            let sw = tabs::active_hwnd();
            let mut rc = RECT::default();
            unsafe {
                let _ = GetClientRect(sw, &mut rc);
            }
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
            logf!(
                "[resize] after: surface client {}x{} center_pixel=0x{:06x}",
                rc.right - rc.left,
                rc.bottom - rc.top,
                center_pixel(sw)
            );
        }

        // ~1s at 8ms/iteration. This is the *main thread's* pulse: if a
        // nested modal loop (window move/size) blocks the pump, these lines
        // stop appearing, which is exactly the condition we want to observe.
        if ticks % 125 == 0 {
            let sw = tabs::active_hwnd();
            let pf = pixel_format_of(sw);
            if pf > 0 && !pf_logged {
                pf_logged = true;
                log_pixel_format(sw, pf);
            }
            logf!(
                "[loop] main-thread alive, ticks={} main_thread_paints={} \
                 surface_pixel_format={} center_pixel=0x{:06x}",
                ticks,
                PAINTS.load(Ordering::Relaxed),
                pf,
                center_pixel(sw)
            );
        }
        std::thread::sleep(std::time::Duration::from_millis(8));
    }

    logf!("exiting");
}
