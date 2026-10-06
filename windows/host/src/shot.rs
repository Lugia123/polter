//! Taking a screenshot: freeze every monitor, choose a window or drag a
//! region, annotate, and hand the result on.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md` §3 and §4, shared with
//! macOS. **The rules are in `polter-shots`** (`geom`, `annot`, `dclick`),
//! where they have tests that run off Windows; this file is the windows, the
//! GDI and the clipboard around them. `shots.rs` is the paste half.
//!
//! # Coordinates
//!
//! One space throughout: **physical pixels on the virtual screen**. The host
//! is per-monitor DPI aware, so monitor rectangles, window bounds, the cursor
//! and mouse messages all arrive in it already, and a `BitBlt` from the screen
//! is in it too. Nothing here multiplies by a scale factor -- a monitor's DPI
//! is used only to size the things *drawn* (line widths, the toolbar, text)
//! and for the `scale` the sidecar reports. An overlay window's client
//! coordinates are the virtual screen's minus its monitor's origin; the
//! image's are the virtual screen's minus the selection's origin.
//!
//! # Threads
//!
//! Everything but the mouse hook is on the window thread. The hook
//! (`hook_proc`) runs on a thread of its own with its own message loop,
//! shares no lock with the window thread, does not log, and reaches the
//! window thread only through `PostMessageW`, which does not wait. **So a
//! window thread that is stuck cannot hold up the mouse**: a low-level hook
//! that is slow stalls the pointer for the whole machine, and this one's
//! slowest path is one atomic load, one `GetAsyncKeyState` per modifier and a
//! post.
//!
//! # The session is taken out before anything that dispatches
//!
//! The state lives in a thread-local `RefCell`. Window procedures re-enter
//! (`DestroyWindow`, `SetFocus`, `ShowWindow` all send messages to this same
//! procedure), so every handler decides what to do inside a short borrow,
//! returns an [`Act`], and performs it with the borrow released.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::ffi::c_void;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU8, Ordering};
use std::sync::Mutex;

use polter_shots::annot::{self, Annotation, Labels, Meta, Source};
use polter_shots::dclick::{Detector, Mods, Press, Rule, Setting, Verdict};
use polter_shots::geom::{self, Handle, Hit, Point, Rect};
use polter_shots::name::Stamp;
use windows::core::{w, PWSTR};
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, GlobalFree, COLORREF, HANDLE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardSequenceNumber, OpenClipboard, RegisterClipboardFormatW,
    SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::SystemInformation::{GetLocalTime, GetSystemTime};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, GetDoubleClickTime, RegisterHotKey, ReleaseCapture, SetCapture, SetFocus,
    UnregisterHotKey, MOD_NOREPEAT, VK_CONTROL, VK_ESCAPE, VK_LWIN, VK_MENU, VK_RETURN, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::plogf;

/// The id this host registers the screenshot hotkey under. `quick.rs` has
/// `0xB0`; ids are per window, and this one is registered on a window of its
/// own, so the two could not collide even if they were equal.
const HOTKEY_ID: i32 = 0xB1;

/// Posted to the control window. `WM_APP + 33` and `+ 34`, free when written
/// (`grep 'WM_APP +'`) -- and private to this window class in any case.
const WM_SHOT_MOUSE: u32 = WM_APP + 33;
const WM_SHOT_NOTE: u32 = WM_APP + 34;

/// `CF_DIB`, numerically, as in `shots.rs`.
const CF_DIB: u32 = 8;

/// Red, yellow, blue, white: the four the specification asks for, red first.
const COLOURS: [COLORREF; 4] =
    [COLORREF(0x0028_28E6), COLORREF(0x0000_C8FA), COLORREF(0x00F0_6E28), COLORREF(0x00FF_FFFF)];
/// The selection's frame and handles.
const ACCENT: COLORREF = COLORREF(0x00F0_A01E);

// ---------------------------------------------------------------- state

struct Mon {
    rect: Rect,
    dpi: u32,
    /// The frozen picture of this monitor.
    bmp: HBITMAP,
    hwnd: HWND,
}

/// A top-level window as it was when the screen was frozen.
struct Win {
    hwnd: isize,
    rect: Rect,
}

struct Sel {
    rect: Rect,
    mon: usize,
    /// The window this selection is, while it is still exactly that window.
    /// Resizing or moving it makes it a region.
    window: Option<isize>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Tool {
    Rect,
    Arrow,
    Pen,
    Text,
    Number,
}

const TOOLS: [Tool; 5] = [Tool::Rect, Tool::Arrow, Tool::Pen, Tool::Text, Tool::Number];
/// Toolbar cells after the five tools.
const CELL_COLOUR: usize = 5;
const CELL_UNDO: usize = 6;
const CELL_CANCEL: usize = 7;
const CELL_DONE: usize = 8;
const CELLS: usize = 9;
const GLYPHS: [&str; CELLS] = ["▭", "↗", "✎", "A", "①", "●", "↶", "✕", "✓"];

enum Drag {
    None,
    /// Button down with no selection yet: a click picks the window under it,
    /// a drag makes a region.
    Picking { down: Point },
    Resize(Handle),
    Move { last: Point },
    /// A rectangle or an arrow being drawn.
    Shape { start: Point },
    Pen,
}

struct Editing {
    edit: HWND,
    /// Where the text goes, virtual screen.
    at: Point,
    /// The index of the number this is the caption of, or `None` for a text
    /// annotation of its own.
    caption_of: Option<usize>,
    colour: usize,
    font: HFONT,
}

struct Session {
    mons: Vec<Mon>,
    wins: Vec<Win>,
    hover: Option<(usize, Rect)>,
    /// A region being dragged out, before the button comes up.
    forming: Option<(Rect, usize)>,
    sel: Option<Sel>,
    /// Annotations in virtual-screen pixels, each with its colour.
    items: Vec<(Annotation, usize)>,
    /// The annotation being drawn.
    live: Option<Annotation>,
    tool: Option<Tool>,
    colour: usize,
    drag: Drag,
    editing: Option<Editing>,
    /// The pane window that had the keyboard when the shot was triggered, if
    /// Polter was the foreground application -- where the result is sent.
    origin_pane: Option<isize>,
    prev_fg: HWND,
}

thread_local! {
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

/// Whether a session is open, for the hook thread, which cannot look.
static ACTIVE: AtomicBool = AtomicBool::new(false);
/// The control window, for the hook thread to post to.
static CONTROL: AtomicIsize = AtomicIsize::new(0);
/// The mouse trigger's modifiers as bits (see `mods_bits`); 0 is off.
static MOUSE_TRIGGER: AtomicU8 = AtomicU8::new(0);
/// Annotation lines waiting to be pasted, each after its image's path.
static NOTES: Mutex<VecDeque<(NoteTarget, String)>> = Mutex::new(VecDeque::new());

#[derive(Clone, Copy)]
enum NoteTarget {
    /// A pane id, from the clipboard callback.
    Pane(u64),
    /// A pane window.
    Hwnd(isize),
}

fn with<R>(f: impl FnOnce(&mut Session) -> R) -> Option<R> {
    SESSION.with(|s| s.try_borrow_mut().ok().and_then(|mut s| s.as_mut().map(f)))
}

fn scaled(px: i32, dpi: u32) -> i32 {
    (px * dpi.max(96) as i32 + 48) / 96
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

fn now() -> Stamp {
    stamp(unsafe { GetLocalTime() })
}

fn stamp(t: windows::Win32::Foundation::SYSTEMTIME) -> Stamp {
    Stamp {
        year: t.wYear,
        month: t.wMonth as u8,
        day: t.wDay as u8,
        hour: t.wHour as u8,
        minute: t.wMinute as u8,
        second: t.wSecond as u8,
        milli: t.wMilliseconds,
    }
}

// ----------------------------------------------------- startup, triggers

/// Create the control window, register the hotkey on it and start the mouse
/// hook. Once, at startup.
///
/// **A window of its own rather than the first frame**: a hotkey belongs to
/// the window it was registered on and dies with it, and the first terminal
/// window can be closed while others stay open.
pub fn init() {
    unsafe {
        let hinst = GetModuleHandleW(None).unwrap_or_default();
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(control_proc),
            hInstance: hinst.into(),
            lpszClassName: w!("PolterShotControl"),
            ..Default::default()
        };
        let overlay = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            // Double clicks are asked for: one on the selection finishes.
            style: CS_DBLCLKS,
            lpfnWndProc: Some(overlay_proc),
            hInstance: hinst.into(),
            lpszClassName: w!("PolterShot"),
            hCursor: LoadCursorW(None, IDC_CROSS).unwrap_or_default(),
            ..Default::default()
        };
        // absence: means it was not reached -- both classes registered
        if RegisterClassExW(&wc) == 0 || RegisterClassExW(&overlay) == 0 {
            // process-wide: screenshots are one facility for the whole process
            plogf!("[shot] RegisterClassExW failed (err={}); screenshots are unavailable", GetLastError().0);
            return;
        }
        let control = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterShotControl"),
            w!(""),
            WINDOW_STYLE::default(),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            Some(hinst.into()),
            None,
        );
        let Ok(control) = control else {
            // process-wide: screenshots are one facility for the whole process
            plogf!("[shot] the control window could not be created; screenshots are unavailable");
            return;
        };
        CONTROL.store(control.0 as isize, Ordering::Release);
        register_hotkey(control);
    }
    read_mouse_trigger();
    start_hook();
}

/// The config was reloaded: the hotkey and the mouse trigger may have moved.
pub fn config_changed() {
    let control = HWND(CONTROL.load(Ordering::Acquire) as *mut c_void);
    if control.0.is_null() {
        return;
    }
    // Unregistering one that is not registered fails, and that is fine.
    let _ = unsafe { UnregisterHotKey(Some(control), HOTKEY_ID) };
    register_hotkey(control);
    read_mouse_trigger();
}

/// `screenshot-mouse-trigger`, as the core hands it over: modifier bits, 0
/// for `none`. Ctrl+Shift, the core's default here, when it cannot be asked.
fn read_mouse_trigger() {
    const KEY: &str = "screenshot-mouse-trigger";
    let cfg = crate::config_handle();
    let mut bits: std::os::raw::c_uint = 0;
    let ok = !cfg.is_null()
        && unsafe { (crate::api().config_get)(cfg, &mut bits as *mut _ as *mut c_void, KEY.as_ptr(), KEY.len()) };
    if ok {
        set_mouse_trigger(Setting::from_bits(bits));
    } else {
        // process-wide: one mouse trigger for the whole process
        plogf!("[shot] {KEY} could not be read; assuming ctrl+shift");
        set_mouse_trigger(Setting::On(Mods::CTRL_SHIFT));
    }
}

/// The `screenshot` action arriving from the core: the menu, the command
/// palette, or the keybind pressed while a terminal has the keyboard.
pub fn from_action() {
    // process-wide: a screenshot is of the screen, not of the window asking
    plogf!("[shot] the screenshot action arrived from the core");
    begin(None);
}

/// Register the global hotkey from the core's binding for `screenshot`.
///
/// **Every outcome has its own line**, for the reason `quick.rs` gives: a
/// hotkey that failed to register and a key nobody pressed are the same
/// silence afterwards.
fn register_hotkey(control: HWND) {
    use crate::keys::Lookup;
    let trigger = match crate::keys::trigger_lookup("screenshot") {
        Lookup::Bound(t) => t,
        Lookup::Unbound => {
            // process-wide: the hotkey is registered once for the process
            plogf!(
                "[shot] the config has no keybind for `screenshot` (or this core does not know \
                 the action); no hotkey registered"
            );
            return;
        }
        Lookup::NoLookup | Lookup::NoConfig => {
            // process-wide: the hotkey is registered once for the process
            plogf!("[shot] the keybind for `screenshot` could not be looked up; no hotkey registered");
            return;
        }
    };
    let Some((mods, vk, combo)) = crate::quick::hotkey_from_trigger(trigger) else {
        // process-wide: the hotkey is registered once for the process
        plogf!(
            "[shot] `screenshot` IS bound (tag={} key=0x{:x} mods=0x{:x} = {:?}) but this host cannot \
             turn it into a RegisterHotKey combination; no hotkey registered",
            trigger.tag,
            trigger.key,
            trigger.mods,
            crate::keys::format_trigger(trigger)
        );
        notify_hotkey_failure(&format!("{:?}", crate::keys::format_trigger(trigger)));
        return;
    };
    let r = unsafe { RegisterHotKey(Some(control), HOTKEY_ID, mods | MOD_NOREPEAT, vk) };
    // Read before anything else can overwrite it, and only on failure.
    let err = if r.is_ok() { 0 } else { unsafe { GetLastError().0 } };
    if r.is_ok() {
        // process-wide: the hotkey is registered once for the process
        plogf!(
            "[shot] hotkey {combo} registered (true at startup; Windows does not report a later \
             takeover). Registered is not the same as reachable: an input-language hotkey on the \
             same keys is taken by the system first, and then `[shot] hotkey pressed` never appears"
        );
    } else {
        // process-wide: the hotkey is registered once for the process
        plogf!(
            "[shot] hotkey {combo} FAILED err={err}{}; screenshots cannot be started from the \
             keyboard in this session",
            if err == 1409 { " (ERROR_HOTKEY_ALREADY_REGISTERED: another program owns it)" } else { "" }
        );
        notify_hotkey_failure(&combo);
    }
}

/// The one visible notice that the shortcut is not working.
fn notify_hotkey_failure(combo: &str) {
    let body = tr("The screenshot shortcut {} is in use by another program. Change it with keybind = …=screenshot.")
        .replace("{}", combo);
    let shown = crate::notify::on_notification(None, Some(tr("Screenshot")), Some(body));
    // process-wide: the hotkey is registered once for the process
    plogf!("[shot] hotkey failure notice for {combo}: shown={shown}");
}

fn mods_bits(m: Mods) -> u8 {
    (m.ctrl as u8) | (m.shift as u8) << 1 | (m.alt as u8) << 2 | (m.win as u8) << 3
}

fn bits_mods(b: u8) -> Mods {
    Mods { ctrl: b & 1 != 0, shift: b & 2 != 0, alt: b & 4 != 0, win: b & 8 != 0 }
}

/// Set what the mouse trigger is (`screenshot-mouse-trigger`). The hook reads
/// it on every press, so this takes effect at once.
pub fn set_mouse_trigger(setting: Setting) {
    let bits = match setting {
        Setting::Off => 0,
        Setting::On(m) => mods_bits(m),
    };
    MOUSE_TRIGGER.store(bits, Ordering::Release);
    // process-wide: one mouse trigger for the whole process
    plogf!("[shot] mouse trigger: {:?}", setting);
}

/// Start the thread that owns the low-level mouse hook.
fn start_hook() {
    let spawned = std::thread::Builder::new().name("polter-shot-hook".into()).spawn(|| unsafe {
        crate::name_this_thread("polter-shot-hook");
        let hinst = GetModuleHandleW(None).unwrap_or_default();
        let hook = SetWindowsHookExW(WH_MOUSE_LL, Some(hook_proc), Some(hinst.into()), 0);
        match &hook {
            // process-wide: one mouse hook for the whole process
            Ok(_) => plogf!("[shot] mouse hook installed on its own thread"),
            // process-wide: one mouse hook for the whole process
            Err(e) => plogf!("[shot] mouse hook NOT installed ({e}); ctrl+shift double click will not work"),
        }
        if hook.is_err() {
            return;
        }
        // A low-level hook is called through this thread's message loop; with
        // no loop it is never called and the system drops it after a timeout.
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    });
    if let Err(e) = spawned {
        // process-wide: one mouse hook for the whole process
        plogf!("[shot] the mouse hook thread could not be started: {e}");
    }
}

thread_local! {
    /// The hook thread's memory of the previous press. Only that thread
    /// touches it.
    static DETECTOR: RefCell<Detector> = const { RefCell::new(Detector::new()) };
}

fn held(vk: u16) -> bool {
    unsafe { GetAsyncKeyState(vk as i32) < 0 }
}

/// The low-level mouse hook. **Runs for every mouse event on the machine**,
/// so it does nothing it does not have to: no lock, no log, no call that
/// waits on another thread. See the module documentation.
unsafe extern "system" fn hook_proc(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let msg = wp.0 as u32;
        if code == HC_ACTION as i32 && (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP) {
            let bits = MOUSE_TRIGGER.load(Ordering::Acquire);
            // While a session is open every click is the overlay's own.
            let trigger = if bits == 0 || ACTIVE.load(Ordering::Acquire) {
                Setting::Off
            } else {
                Setting::On(bits_mods(bits))
            };
            let verdict = if msg == WM_LBUTTONUP {
                DETECTOR.with(|d| d.borrow_mut().release())
            } else {
                let ev = &*(lp.0 as *const MSLLHOOKSTRUCT);
                let press = Press {
                    time_ms: ev.time,
                    x: ev.pt.x,
                    y: ev.pt.y,
                    mods: Mods {
                        ctrl: held(VK_CONTROL.0),
                        shift: held(VK_SHIFT.0),
                        alt: held(VK_MENU.0),
                        win: held(VK_LWIN.0) || held(VK_RWIN.0),
                    },
                };
                let rule = Rule {
                    interval_ms: GetDoubleClickTime(),
                    width: GetSystemMetrics(SM_CXDOUBLECLK),
                    height: GetSystemMetrics(SM_CYDOUBLECLK),
                    trigger,
                };
                let v = DETECTOR.with(|d| d.borrow_mut().press(press, &rule));
                if v == Verdict::Trigger {
                    let control = HWND(CONTROL.load(Ordering::Acquire) as *mut c_void);
                    let _ = PostMessageW(
                        Some(control),
                        WM_SHOT_MOUSE,
                        WPARAM(ev.pt.x as u32 as usize),
                        LPARAM(ev.pt.y as isize),
                    );
                }
                v
            };
            if verdict != Verdict::Pass {
                // Eaten: the application under the pointer never sees it.
                return LRESULT(1);
            }
        }
        CallNextHookEx(None, code, wp, lp)
    }
}

unsafe extern "system" fn control_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_HOTKEY if wp.0 as i32 == HOTKEY_ID => {
            // process-wide: the hotkey fires whatever is in front
            plogf!("[shot] hotkey pressed");
            begin(None);
            LRESULT(0)
        }
        WM_SHOT_MOUSE => {
            let at = Point::new(wp.0 as u32 as i32, lp.0 as i32);
            // process-wide: the mouse trigger fires whatever is under the pointer
            plogf!("[shot] ctrl+shift double click at ({},{})", at.x, at.y);
            begin(Some(at));
            LRESULT(0)
        }
        WM_SHOT_NOTE => {
            paste_notes();
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

/// Queue an annotation line to be pasted into a pane once the paste that is
/// in progress has finished. Called from the clipboard callback when a paste
/// reuses a screenshot that has annotations.
pub fn paste_note_later(pane: u64, note: String) {
    queue_note(NoteTarget::Pane(pane), note);
}

fn queue_note(target: NoteTarget, note: String) {
    NOTES.lock().unwrap_or_else(|e| e.into_inner()).push_back((target, note));
    let control = HWND(CONTROL.load(Ordering::Acquire) as *mut c_void);
    if control.0.is_null() || unsafe { PostMessageW(Some(control), WM_SHOT_NOTE, WPARAM(0), LPARAM(0)) }.is_err() {
        // process-wide: the queue belongs to the process, not to a window
        plogf!("[shot] an annotation line could not be queued for pasting: no control window");
    }
}

/// The second paste: the line describing the annotations, after the path.
fn paste_notes() {
    loop {
        let next = NOTES.lock().unwrap_or_else(|e| e.into_inner()).pop_front();
        let Some((target, note)) = next else { return };
        let (surface, what) = match target {
            NoteTarget::Pane(id) => (crate::tabs::surface_of_pane(id), format!("pane={id}")),
            NoteTarget::Hwnd(h) => (crate::tabs::surface_of(HWND(h as *mut c_void)), format!("pane window {h:#x}")),
        };
        if surface.is_null() {
            // process-wide: the pane this was for has gone, so there is no window to name
            plogf!("[shot] annotation line for {what} not pasted: that pane has no surface any more");
            continue;
        }
        unsafe { (crate::api().surface_text)(surface, note.as_ptr() as *const _, note.len()) };
        // process-wide: reported by pane, which is unique in the process
        plogf!("[shot] annotation line pasted into {what}: {} chars", note.chars().count());
    }
}

// ------------------------------------------------------------ the freeze

unsafe extern "system" fn monitor_cb(
    mon: HMONITOR,
    _dc: HDC,
    rect: *mut RECT,
    data: LPARAM,
) -> windows::core::BOOL {
    unsafe {
        let out = &mut *(data.0 as *mut Vec<(Rect, u32)>);
        let r = *rect;
        let (mut dx, mut dy) = (96u32, 96u32);
        let _ = GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
        out.push((Rect::from_ltrb(r.left, r.top, r.right, r.bottom), dx));
    }
    true.into()
}

/// The bounds a person would call the window's: DWM's extended frame, which
/// leaves out the invisible resize border `GetWindowRect` includes.
fn window_bounds(hwnd: HWND) -> Option<Rect> {
    unsafe {
        let mut r = RECT::default();
        let size = std::mem::size_of::<RECT>() as u32;
        if DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut RECT as *mut c_void, size).is_err()
            && GetWindowRect(hwnd, &mut r).is_err()
        {
            return None;
        }
        let rect = Rect::from_ltrb(r.left, r.top, r.right, r.bottom);
        (!rect.is_empty()).then_some(rect)
    }
}

unsafe extern "system" fn window_cb(hwnd: HWND, data: LPARAM) -> windows::core::BOOL {
    unsafe {
        let out = &mut *(data.0 as *mut Vec<Win>);
        if IsWindowVisible(hwnd).as_bool() && !IsIconic(hwnd).as_bool() {
            // Cloaked: on another virtual desktop, or a suspended store app's
            // placeholder. Visible to `IsWindowVisible`, not to a person.
            let mut cloaked = 0u32;
            let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut u32 as *mut c_void, 4);
            if cloaked == 0 {
                if let Some(rect) = window_bounds(hwnd) {
                    out.push(Win { hwnd: hwnd.0 as isize, rect });
                }
            }
        }
    }
    true.into()
}

/// Open a session: freeze the screen and put an overlay on every monitor.
/// `preselect` is where a mouse trigger happened; the window there starts
/// out selected.
fn begin(preselect: Option<Point>) {
    // absence: means it was not reached -- no session was open, and the
    // `[shot] begin` line that follows says so
    if ACTIVE.swap(true, Ordering::AcqRel) {
        // process-wide: one session at a time for the whole process
        plogf!("[shot] a screenshot is already in progress; trigger ignored");
        return;
    }
    unsafe {
        let prev_fg = GetForegroundWindow();
        let origin_pane = crate::tabs::is_frame(prev_fg)
            .then(|| crate::tabs::active_pane_hwnd(prev_fg))
            .flatten()
            .map(|h| h.0 as isize);

        // The windows first, in z-order, **before any overlay exists** -- so
        // the list cannot contain one, and "the topmost window under the
        // cursor" needs no exception for our own.
        let mut wins: Vec<Win> = Vec::new();
        let _ = EnumWindows(Some(window_cb), LPARAM(&mut wins as *mut _ as isize));
        let mut found: Vec<(Rect, u32)> = Vec::new();
        let _ = EnumDisplayMonitors(None, None, Some(monitor_cb), LPARAM(&mut found as *mut _ as isize));

        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let mut mons = Vec::new();
        for (rect, dpi) in found {
            let bmp = CreateCompatibleBitmap(screen, rect.w, rect.h);
            let old = SelectObject(mem, bmp.into());
            // CAPTUREBLT so layered windows are in the picture.
            let ok = BitBlt(mem, 0, 0, rect.w, rect.h, Some(screen), rect.x, rect.y, SRCCOPY | CAPTUREBLT);
            SelectObject(mem, old);
            if ok.is_err() {
                // process-wide: about a monitor, not about a terminal window
                plogf!("[shot] monitor {:?} could not be captured (err={}); left out", rect, GetLastError().0);
                let _ = DeleteObject(bmp.into());
                continue;
            }
            mons.push(Mon { rect, dpi, bmp, hwnd: HWND::default() });
        }
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if mons.is_empty() {
            // process-wide: one session at a time for the whole process
            plogf!("[shot] no monitor could be captured; nothing to select from");
            ACTIVE.store(false, Ordering::Release);
            return;
        }

        let rects: Vec<Rect> = wins.iter().map(|w| w.rect).collect();
        let mon_rects: Vec<Rect> = mons.iter().map(|m| m.rect).collect();
        let sel = preselect.and_then(|p| {
            let mon = geom::monitor_at(&mon_rects, p)?;
            let (i, rect) = geom::pick_window(&rects, p, mon_rects[mon])?;
            Some(Sel { rect, mon, window: Some(wins[i].hwnd) })
        });
        // process-wide: one session at a time for the whole process
        plogf!(
            "[shot] begin: {} monitor(s) {:?}, {} window(s), foreground={:?} polter_pane={:?}, preselected={:?}",
            mons.len(),
            mons.iter().map(|m| (m.rect.x, m.rect.y, m.rect.w, m.rect.h, m.dpi)).collect::<Vec<_>>(),
            wins.len(),
            prev_fg.0,
            origin_pane,
            sel.as_ref().map(|s| s.rect)
        );
        SESSION.with(|s| {
            *s.borrow_mut() = Some(Session {
                mons,
                wins,
                hover: None,
                forming: None,
                sel,
                items: Vec::new(),
                live: None,
                tool: None,
                colour: 0,
                drag: Drag::None,
                editing: None,
                origin_pane,
                prev_fg,
            })
        });

        // The overlays, created with no borrow held: creation and showing
        // both call `overlay_proc`.
        let hinst = GetModuleHandleW(None).unwrap_or_default();
        let mut first = HWND::default();
        for (i, rect) in mon_rects.iter().enumerate() {
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                w!("PolterShot"),
                w!("Polter"),
                WS_POPUP,
                rect.x,
                rect.y,
                rect.w,
                rect.h,
                None,
                None,
                Some(hinst.into()),
                None,
            );
            let Ok(hwnd) = hwnd else {
                // process-wide: about a monitor, not about a terminal window
                plogf!("[shot] no overlay for monitor {:?} (err={})", rect, GetLastError().0);
                continue;
            };
            with(|s| s.mons[i].hwnd = hwnd);
            let _ = ShowWindow(hwnd, SW_SHOWNA);
            if first.0.is_null() {
                first = hwnd;
            }
        }
        // absence: means it was not reached -- at least one overlay exists,
        // and `[shot] overlays shown` follows
        if first.0.is_null() {
            // process-wide: one session at a time for the whole process
            plogf!("[shot] no overlay window could be created; cancelled");
            end(false);
            return;
        }
        // The keyboard, for Esc, Enter and the text tool. A hotkey press
        // grants the right to take the foreground; a mouse trigger may not,
        // and then the first click on the overlay does it instead.
        let took = SetForegroundWindow(first).as_bool();
        let _ = SetFocus(Some(first));
        // process-wide: one session at a time for the whole process
        plogf!("[shot] overlays shown; SetForegroundWindow={took}");
    }
}

/// Close the session: overlays gone, bitmaps freed, foreground handed back.
/// Returns the session's state for `finish` to use, already detached.
fn end(log_cancel: bool) -> Option<Session> {
    let session = SESSION.with(|s| s.try_borrow_mut().ok().and_then(|mut s| s.take()));
    ACTIVE.store(false, Ordering::Release);
    let session = session?;
    unsafe {
        if let Some(e) = &session.editing {
            let _ = DestroyWindow(e.edit);
            let _ = DeleteObject(e.font.into());
        }
        let _ = ReleaseCapture();
        for m in &session.mons {
            if !m.hwnd.0.is_null() {
                let _ = DestroyWindow(m.hwnd);
            }
        }
        if !session.prev_fg.0.is_null() {
            let _ = SetForegroundWindow(session.prev_fg);
        }
    }
    if log_cancel {
        // process-wide: one session at a time for the whole process
        plogf!("[shot] cancelled: clipboard untouched, nothing written");
        free(&session);
        return None;
    }
    Some(session)
}

fn free(session: &Session) {
    for m in &session.mons {
        let _ = unsafe { DeleteObject(m.bmp.into()) };
    }
}

// --------------------------------------------------------------- drawing

struct Pens {
    dpi: u32,
}

impl Pens {
    fn width(&self) -> i32 {
        scaled(3, self.dpi)
    }
    fn font_px(&self) -> i32 {
        scaled(20, self.dpi)
    }
    fn radius(&self) -> i32 {
        scaled(13, self.dpi)
    }
}

fn text_font(px: i32, bold: bool) -> HFONT {
    unsafe {
        CreateFontW(
            -px,
            0,
            0,
            0,
            if bold { 700 } else { 400 },
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            0,
            w!("Segoe UI"),
        )
    }
}

/// Where a number's caption starts, given the number's centre.
fn caption_at(at: Point, p: &Pens) -> Point {
    Point::new(at.x + p.radius() + scaled(6, p.dpi), at.y - p.font_px() * 2 / 3)
}

/// Draw annotations given in virtual-screen pixels into a DC whose origin is
/// `origin`. **The one routine for both the overlay and the saved image**, so
/// what is saved is what was shown.
unsafe fn draw_items<'a>(
    hdc: HDC,
    items: impl Iterator<Item = (&'a Annotation, usize)>,
    origin: Point,
    p: &Pens,
) {
    unsafe {
        let font = text_font(p.font_px(), true);
        let old_font = SelectObject(hdc, font.into());
        SetBkMode(hdc, TRANSPARENT);
        for (item, colour) in items {
            let colour = COLOURS[colour % COLOURS.len()];
            let pen = CreatePen(PS_SOLID, p.width(), colour);
            let brush = CreateSolidBrush(colour);
            let old_pen = SelectObject(hdc, pen.into());
            let old_brush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
            SetTextColor(hdc, colour);
            let at = |q: Point| q.relative_to(origin);
            match item {
                Annotation::Rect { rect } => {
                    let r = rect.relative_to(origin);
                    let _ = Rectangle(hdc, r.x, r.y, r.right(), r.bottom());
                }
                Annotation::Arrow { from, to } => {
                    let (a, b) = (at(*from), at(*to));
                    let _ = MoveToEx(hdc, a.x, a.y, None);
                    let _ = LineTo(hdc, b.x, b.y);
                    if let Some(head) = geom::arrow_head(a, b, p.width() * 5) {
                        SelectObject(hdc, brush.into());
                        let pts = head.map(|q| POINT { x: q.x, y: q.y });
                        let _ = Polygon(hdc, &pts);
                    }
                }
                Annotation::Pen { points } => {
                    let pts: Vec<POINT> = points.iter().map(|q| at(*q)).map(|q| POINT { x: q.x, y: q.y }).collect();
                    let _ = Polyline(hdc, &pts);
                }
                Annotation::Text { at: q, text } => {
                    let q = at(*q);
                    let _ = TextOutW(hdc, q.x, q.y, &wide(text));
                }
                Annotation::Number { n, at: q, text } => {
                    let c = at(*q);
                    let r = p.radius();
                    SelectObject(hdc, brush.into());
                    let _ = Ellipse(hdc, c.x - r, c.y - r, c.x + r, c.y + r);
                    // The digit, in whichever of black and white the colour
                    // does not swallow (white and yellow take black).
                    let digit = wide(&n.to_string());
                    let mut size = SIZE::default();
                    let _ = GetTextExtentPoint32W(hdc, &digit, &mut size);
                    let light = colour.0 == COLOURS[1].0 || colour.0 == COLOURS[3].0;
                    SetTextColor(hdc, COLORREF(if light { 0 } else { 0x00FF_FFFF }));
                    let _ = TextOutW(hdc, c.x - size.cx / 2, c.y - size.cy / 2, &digit);
                    SetTextColor(hdc, colour);
                    if !text.is_empty() {
                        let t = caption_at(*q, p).relative_to(origin);
                        let _ = TextOutW(hdc, t.x, t.y, &wide(text));
                    }
                }
            }
            SelectObject(hdc, old_pen);
            SelectObject(hdc, old_brush);
            let _ = DeleteObject(pen.into());
            let _ = DeleteObject(brush.into());
        }
        SelectObject(hdc, old_font);
        let _ = DeleteObject(font.into());
    }
}

/// Darken `r` (client coordinates) by blending black over it.
unsafe fn dim(hdc: HDC, black: HDC, r: Rect) {
    if r.is_empty() {
        return;
    }
    let blend = BLENDFUNCTION { BlendOp: 0, BlendFlags: 0, SourceConstantAlpha: 110, AlphaFormat: 0 };
    let _ = unsafe { AlphaBlend(hdc, r.x, r.y, r.w, r.h, black, 0, 0, 1, 1, blend) };
}

fn fill(hdc: HDC, r: Rect, colour: COLORREF) {
    unsafe {
        let brush = CreateSolidBrush(colour);
        let rc = RECT { left: r.x, top: r.y, right: r.right(), bottom: r.bottom() };
        FillRect(hdc, &rc, brush);
        let _ = DeleteObject(brush.into());
    }
}

fn frame(hdc: HDC, r: Rect, colour: COLORREF, thickness: i32) {
    fill(hdc, Rect::new(r.x, r.y, r.w, thickness), colour);
    fill(hdc, Rect::new(r.x, r.bottom() - thickness, r.w, thickness), colour);
    fill(hdc, Rect::new(r.x, r.y, thickness, r.h), colour);
    fill(hdc, Rect::new(r.right() - thickness, r.y, thickness, r.h), colour);
}

/// The toolbar's rectangle on the virtual screen and the side of one cell.
fn toolbar(sel: &Sel, mon: &Mon) -> (Rect, i32) {
    let cell = scaled(36, mon.dpi);
    let size = (cell * CELLS as i32, cell);
    let at = geom::toolbar_origin(sel.rect, size, mon.rect, scaled(8, mon.dpi));
    (Rect::new(at.x, at.y, size.0, size.1), cell)
}

fn toolbar_cell(sel: &Sel, mon: &Mon, p: Point) -> Option<usize> {
    let (bar, cell) = toolbar(sel, mon);
    bar.contains(p).then(|| ((p.x - bar.x) / cell) as usize).filter(|i| *i < CELLS)
}

unsafe fn paint(hwnd: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        with(|s| {
            let Some(i) = s.mons.iter().position(|m| m.hwnd == hwnd) else { return };
            let mon = &s.mons[i];
            let (w, h) = (mon.rect.w, mon.rect.h);
            let o = mon.rect.origin();
            let pens = Pens { dpi: mon.dpi };

            // Everything is drawn into a bitmap and shown in one blit.
            let mem = CreateCompatibleDC(Some(hdc));
            let back = CreateCompatibleBitmap(hdc, w, h);
            let old_back = SelectObject(mem, back.into());
            let src = CreateCompatibleDC(Some(hdc));
            let old_src = SelectObject(src, mon.bmp.into());
            let _ = BitBlt(mem, 0, 0, w, h, Some(src), 0, 0, SRCCOPY);
            SelectObject(src, old_src);

            // What is in focus on this monitor: the selection, the region
            // being dragged, or the window under the cursor.
            let sel = s.sel.as_ref().filter(|x| x.mon == i).map(|x| x.rect);
            let forming = s.forming.filter(|f| f.1 == i).map(|f| f.0);
            let hover = if s.sel.is_none() && s.forming.is_none() {
                s.hover.filter(|x| x.0 == i).map(|x| x.1)
            } else {
                None
            };
            let focus = sel.or(forming).or(hover).map(|r| r.relative_to(o));

            // Dim everything outside it.
            let black_bmp = CreateCompatibleBitmap(hdc, 1, 1);
            let old_black = SelectObject(src, black_bmp.into());
            let _ = SetPixel(src, 0, 0, COLORREF(0));
            match focus {
                Some(f) => {
                    dim(mem, src, Rect::new(0, 0, w, f.y));
                    dim(mem, src, Rect::new(0, f.bottom(), w, h - f.bottom()));
                    dim(mem, src, Rect::new(0, f.y, f.x, f.h));
                    dim(mem, src, Rect::new(f.right(), f.y, w - f.right(), f.h));
                    frame(mem, f, ACCENT, scaled(2, mon.dpi));
                }
                None => dim(mem, src, Rect::new(0, 0, w, h)),
            }
            SelectObject(src, old_black);
            let _ = DeleteObject(black_bmp.into());
            let _ = DeleteDC(src);

            if let Some(sel_ref) = s.sel.as_ref().filter(|x| x.mon == i) {
                let f = sel_ref.rect.relative_to(o);
                let all = s.items.iter().map(|(a, c)| (a, *c)).chain(s.live.iter().map(|a| (a, s.colour)));
                draw_items(mem, all, o, &pens);

                // Handles, when the selection is what the mouse adjusts.
                if s.tool.is_none() {
                    let g = scaled(4, mon.dpi);
                    for handle in Handle::ALL {
                        let c = handle.at(f);
                        fill(mem, Rect::new(c.x - g, c.y - g, g * 2, g * 2), ACCENT);
                    }
                }

                // Size, in pixels of the image.
                let ui = text_font(scaled(14, mon.dpi), false);
                let old_font = SelectObject(mem, ui.into());
                SetBkMode(mem, OPAQUE);
                SetBkColor(mem, COLORREF(0x0020_2020));
                SetTextColor(mem, COLORREF(0x00FF_FFFF));
                let label = wide(&format!(" {} × {} ", f.w, f.h));
                let ly = if f.y >= scaled(22, mon.dpi) { f.y - scaled(22, mon.dpi) } else { f.y + scaled(4, mon.dpi) };
                let _ = TextOutW(mem, f.x, ly, &label);
                SelectObject(mem, old_font);
                let _ = DeleteObject(ui.into());

                // The toolbar.
                let (bar, cell) = toolbar(sel_ref, mon);
                let bar = bar.relative_to(o);
                fill(mem, bar, COLORREF(0x0030_3030));
                let glyphs = text_font(cell * 5 / 9, false);
                let old_font = SelectObject(mem, glyphs.into());
                SetBkMode(mem, TRANSPARENT);
                for (n, glyph) in GLYPHS.iter().enumerate() {
                    let c = Rect::new(bar.x + cell * n as i32, bar.y, cell, cell);
                    if n < TOOLS.len() && s.tool == Some(TOOLS[n]) {
                        fill(mem, c, COLORREF(0x0060_6060));
                    }
                    SetTextColor(mem, if n == CELL_COLOUR { COLOURS[s.colour] } else { COLORREF(0x00FF_FFFF) });
                    let mut text = wide(glyph);
                    let mut rc = RECT { left: c.x, top: c.y, right: c.right(), bottom: c.bottom() };
                    DrawTextW(mem, &mut text, &mut rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
                }
                SelectObject(mem, old_font);
                let _ = DeleteObject(glyphs.into());
            }

            let _ = BitBlt(hdc, 0, 0, w, h, Some(mem), 0, 0, SRCCOPY);
            SelectObject(mem, old_back);
            let _ = DeleteObject(back.into());
            let _ = DeleteDC(mem);
        });
        let _ = EndPaint(hwnd, &ps);
    }
}

fn repaint() {
    let windows: Vec<HWND> = with(|s| s.mons.iter().map(|m| m.hwnd).collect()).unwrap_or_default();
    for h in windows {
        if !h.0.is_null() {
            let _ = unsafe { InvalidateRect(Some(h), None, false) };
        }
    }
}

// ----------------------------------------------------------------- input

/// What a handler decided, performed once the session is no longer borrowed.
enum Act {
    None,
    Repaint,
    Capture,
    Release,
    Cancel,
    Finish,
    /// Open the text box at this point, for a text annotation or a caption.
    Edit { at: Point, caption_of: Option<usize> },
    CommitEdit,
    CancelEdit,
}

fn button_down(s: &mut Session, p: Point) -> Act {
    if s.editing.is_some() {
        // A click away from the box keeps what was typed.
        return Act::CommitEdit;
    }
    let mon_rects: Vec<Rect> = s.mons.iter().map(|m| m.rect).collect();
    if let Some(sel) = &s.sel {
        let mon = &s.mons[sel.mon];
        if let Some(cell) = toolbar_cell(sel, mon, p) {
            return match cell {
                CELL_COLOUR => {
                    s.colour = (s.colour + 1) % COLOURS.len();
                    Act::Repaint
                }
                CELL_UNDO => {
                    s.items.pop();
                    Act::Repaint
                }
                CELL_CANCEL => Act::Cancel,
                CELL_DONE => Act::Finish,
                n => {
                    // The same tool again puts it down: back to adjusting
                    // the selection.
                    s.tool = if s.tool == Some(TOOLS[n]) { None } else { Some(TOOLS[n]) };
                    Act::Repaint
                }
            };
        }
        let inside = sel.rect.contains(p);
        match s.tool {
            Some(_) if !inside => Act::None,
            Some(Tool::Rect) | Some(Tool::Arrow) => {
                s.drag = Drag::Shape { start: p };
                Act::Capture
            }
            Some(Tool::Pen) => {
                s.drag = Drag::Pen;
                s.live = Some(Annotation::Pen { points: vec![p] });
                Act::Capture
            }
            Some(Tool::Text) => Act::Edit { at: p, caption_of: None },
            Some(Tool::Number) => {
                let plain: Vec<Annotation> = s.items.iter().map(|(a, _)| a.clone()).collect();
                let n = annot::next_number(&plain);
                s.items.push((Annotation::Number { n, at: p, text: String::new() }, s.colour));
                let pens = Pens { dpi: mon.dpi };
                Act::Edit { at: caption_at(p, &pens), caption_of: Some(s.items.len() - 1) }
            }
            None => match geom::hit(sel.rect, p, scaled(6, mon.dpi)) {
                Hit::Handle(h) => {
                    s.drag = Drag::Resize(h);
                    Act::Capture
                }
                Hit::Inside => {
                    s.drag = Drag::Move { last: p };
                    Act::Capture
                }
                // Outside with nothing drawn yet: choose again. With
                // annotations it would throw them away, so it does nothing.
                Hit::Outside if s.items.is_empty() => {
                    s.sel = None;
                    s.hover = geom::monitor_at(&mon_rects, p).and_then(|m| {
                        let rects: Vec<Rect> = s.wins.iter().map(|w| w.rect).collect();
                        geom::pick_window(&rects, p, mon_rects[m]).map(|(_, r)| (m, r))
                    });
                    s.drag = Drag::Picking { down: p };
                    Act::Capture
                }
                Hit::Outside => Act::None,
            },
        }
    } else {
        s.drag = Drag::Picking { down: p };
        Act::Capture
    }
}

fn mouse_move(s: &mut Session, p: Point) -> Act {
    if s.editing.is_some() {
        return Act::None;
    }
    let mon_rects: Vec<Rect> = s.mons.iter().map(|m| m.rect).collect();
    match &mut s.drag {
        Drag::None => {
            if s.sel.is_some() {
                return Act::None;
            }
            let rects: Vec<Rect> = s.wins.iter().map(|w| w.rect).collect();
            let hover = geom::monitor_at(&mon_rects, p)
                .and_then(|m| geom::pick_window(&rects, p, mon_rects[m]).map(|(_, r)| (m, r)));
            if hover == s.hover {
                return Act::None;
            }
            s.hover = hover;
        }
        Drag::Picking { down } => {
            let down = *down;
            if !geom::is_drag(down, p) {
                return Act::None;
            }
            // Confined to the monitor the drag started on.
            let Some(m) = geom::monitor_at(&mon_rects, down) else { return Act::None };
            s.forming = geom::drag_selection(down, p, mon_rects[m]).map(|r| (r, m));
        }
        Drag::Resize(h) => {
            let h = *h;
            if let Some(sel) = &mut s.sel {
                sel.rect = geom::resize(sel.rect, h, p, mon_rects[sel.mon]);
                sel.window = None;
            }
        }
        Drag::Move { last } => {
            let delta = Point::new(p.x - last.x, p.y - last.y);
            *last = p;
            if let Some(sel) = &mut s.sel {
                sel.rect = geom::move_by(sel.rect, delta, mon_rects[sel.mon]);
                sel.window = None;
            }
        }
        Drag::Shape { start } => {
            let start = *start;
            let Some(sel) = &s.sel else { return Act::None };
            let end = sel.rect.clamp(p);
            s.live = Some(match s.tool {
                Some(Tool::Arrow) => Annotation::Arrow { from: start, to: end },
                _ => Annotation::Rect { rect: Rect::spanning(start, end) },
            });
        }
        Drag::Pen => {
            let Some(sel) = &s.sel else { return Act::None };
            let q = sel.rect.clamp(p);
            if let Some(Annotation::Pen { points }) = &mut s.live {
                if points.last() != Some(&q) {
                    points.push(q);
                }
            }
        }
    }
    Act::Repaint
}

fn button_up(s: &mut Session, p: Point) -> Act {
    match std::mem::replace(&mut s.drag, Drag::None) {
        Drag::None => return Act::None,
        Drag::Picking { .. } => {
            if let Some((rect, mon)) = s.forming.take() {
                s.sel = Some(Sel { rect, mon, window: None });
            } else {
                // A click: the window under the cursor, as it was frozen.
                // Asked of the click's own position rather than taken from
                // `hover`, which is only as fresh as the last mouse move.
                let mon_rects: Vec<Rect> = s.mons.iter().map(|m| m.rect).collect();
                let rects: Vec<Rect> = s.wins.iter().map(|w| w.rect).collect();
                s.sel = geom::monitor_at(&mon_rects, p).and_then(|mon| {
                    let (i, rect) = geom::pick_window(&rects, p, mon_rects[mon])?;
                    Some(Sel { rect, mon, window: Some(s.wins[i].hwnd) })
                });
            }
            s.hover = None;
        }
        Drag::Resize(_) | Drag::Move { .. } => {}
        Drag::Shape { .. } | Drag::Pen => {
            let keep = match &s.live {
                Some(Annotation::Rect { rect }) => !rect.is_empty(),
                Some(Annotation::Arrow { from, to }) => from != to,
                Some(Annotation::Pen { points }) => points.len() > 1,
                _ => false,
            };
            if let Some(a) = s.live.take().filter(|_| keep) {
                s.items.push((a, s.colour));
            }
        }
    }
    Act::Release
}

/// Right click and its keyboard twin step back once: out of the text box,
/// then out of the selection, then out of the screenshot.
fn step_back(s: &mut Session) -> Act {
    if s.editing.is_some() {
        Act::CancelEdit
    } else if s.sel.is_some() || s.forming.is_some() {
        s.sel = None;
        s.forming = None;
        s.items.clear();
        s.live = None;
        s.tool = None;
        s.drag = Drag::None;
        Act::Release
    } else {
        Act::Cancel
    }
}

fn point_of(hwnd: HWND, lp: LPARAM) -> Option<Point> {
    let (x, y) = ((lp.0 & 0xFFFF) as i16 as i32, ((lp.0 >> 16) & 0xFFFF) as i16 as i32);
    with(|s| s.mons.iter().find(|m| m.hwnd == hwnd).map(|m| Point::new(x + m.rect.x, y + m.rect.y))).flatten()
}

fn perform(hwnd: HWND, act: Act) {
    match act {
        Act::None => {}
        Act::Repaint => repaint(),
        Act::Capture => {
            unsafe { SetCapture(hwnd) };
            repaint();
        }
        Act::Release => {
            let _ = unsafe { ReleaseCapture() };
            repaint();
        }
        Act::Cancel => {
            end(true);
        }
        Act::Finish => finish(),
        Act::Edit { at, caption_of } => open_edit(at, caption_of),
        Act::CommitEdit => close_edit(true),
        Act::CancelEdit => close_edit(false),
    }
}

unsafe extern "system" fn overlay_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let act = match msg {
        WM_PAINT => {
            unsafe { paint(hwnd) };
            return LRESULT(0);
        }
        // Painted whole in WM_PAINT; erasing first would flash.
        WM_ERASEBKGND => return LRESULT(1),
        WM_MOUSEMOVE => point_of(hwnd, lp).and_then(|p| with(|s| mouse_move(s, p))),
        WM_LBUTTONDOWN => point_of(hwnd, lp).and_then(|p| with(|s| button_down(s, p))),
        WM_LBUTTONDBLCLK => point_of(hwnd, lp).and_then(|p| {
            with(|s| {
                // With no tool in hand a double click on the selection is
                // "done". With one, it is just the second of two clicks.
                let on_selection = s.sel.as_ref().is_some_and(|sel| sel.rect.contains(p));
                let on_toolbar = s.sel.as_ref().is_some_and(|sel| toolbar_cell(sel, &s.mons[sel.mon], p).is_some());
                if s.tool.is_none() && on_selection && !on_toolbar && s.editing.is_none() {
                    Act::Finish
                } else {
                    button_down(s, p)
                }
            })
        }),
        WM_LBUTTONUP => point_of(hwnd, lp).and_then(|p| with(|s| button_up(s, p))),
        WM_RBUTTONDOWN => with(step_back),
        // Alt+F4 on an overlay closes the session, not one monitor's window.
        WM_CLOSE => Some(Act::Cancel),
        WM_KEYDOWN => {
            let vk = wp.0 as u16;
            let ctrl = unsafe { GetAsyncKeyState(VK_CONTROL.0 as i32) } < 0;
            with(|s| {
                if vk == VK_ESCAPE.0 {
                    Act::Cancel
                } else if vk == VK_RETURN.0 && s.sel.is_some() {
                    Act::Finish
                } else if ctrl && vk == b'Z' as u16 {
                    s.items.pop();
                    Act::Repaint
                } else {
                    Act::None
                }
            })
        }
        _ => return unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    };
    perform(hwnd, act.unwrap_or(Act::None));
    LRESULT(0)
}

// ------------------------------------------------------------- text box

/// Open a native `EDIT` at `at` for typing a text annotation or a number's
/// caption. **A real edit control, so the input method works in it** -- an
/// IME composes into a window that implements the text protocols, and this
/// one already does.
fn open_edit(at: Point, caption_of: Option<usize>) {
    let Some((parent, mon_rect, dpi, sel_rect, colour)) = with(|s| {
        let sel = s.sel.as_ref()?;
        let m = &s.mons[sel.mon];
        Some((m.hwnd, m.rect, m.dpi, sel.rect, s.colour))
    })
    .flatten() else {
        return;
    };
    let pens = Pens { dpi };
    let local = at.relative_to(mon_rect.origin());
    let height = pens.font_px() + scaled(8, dpi);
    let width = (sel_rect.right() - at.x).max(scaled(160, dpi)).min(mon_rect.right() - at.x).max(scaled(40, dpi));
    unsafe {
        let edit = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            w!(""),
            WS_CHILD | WS_VISIBLE | WS_BORDER | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            local.x,
            local.y,
            width,
            height,
            Some(parent),
            None,
            None,
            None,
        );
        let Ok(edit) = edit else {
            // process-wide: the overlay is not a terminal window
            plogf!("[shot] the text box could not be created (err={})", GetLastError().0);
            return;
        };
        let font = text_font(pens.font_px(), true);
        SendMessageW(edit, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        let prev = SetWindowLongPtrW(edit, GWLP_WNDPROC, edit_proc as *const () as isize);
        SetWindowLongPtrW(edit, GWLP_USERDATA, prev);
        with(|s| s.editing = Some(Editing { edit, at, caption_of, colour, font }));
        let _ = SetForegroundWindow(parent);
        let _ = SetFocus(Some(edit));
    }
    repaint();
}

/// Close the text box. `keep` puts what was typed into the annotation;
/// otherwise it is dropped (a number keeps its circle either way).
fn close_edit(keep: bool) {
    // Taken out first: destroying the box sends it WM_KILLFOCUS, which asks
    // for this same close and must find nothing left to do.
    let Some(e) = with(|s| s.editing.take()).flatten() else { return };
    let text = unsafe {
        let mut buf = vec![0u16; GetWindowTextLengthW(e.edit).max(0) as usize + 1];
        let n = GetWindowTextW(e.edit, &mut buf).max(0) as usize;
        String::from_utf16_lossy(&buf[..n])
    };
    let text = text.trim().to_string();
    let parent = unsafe { GetParent(e.edit) }.ok();
    unsafe {
        let _ = DestroyWindow(e.edit);
        let _ = DeleteObject(e.font.into());
    }
    with(|s| {
        if !keep || text.is_empty() {
            return;
        }
        match e.caption_of {
            Some(i) => {
                if let Some((Annotation::Number { text: caption, .. }, _)) = s.items.get_mut(i) {
                    *caption = text;
                }
            }
            None => s.items.push((Annotation::Text { at: e.at, text }, e.colour)),
        }
    });
    if let Some(parent) = parent {
        let _ = unsafe { SetFocus(Some(parent)) };
    }
    repaint();
}

/// Enter keeps, Escape drops, and losing the keyboard keeps. An `EDIT` eats
/// the first two and tells nobody, hence the subclass (as in `prompt.rs`).
unsafe extern "system" fn edit_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if msg == WM_KEYDOWN && wp.0 as u16 == VK_RETURN.0 {
            close_edit(true);
            return LRESULT(0);
        }
        if msg == WM_KEYDOWN && wp.0 as u16 == VK_ESCAPE.0 {
            close_edit(false);
            return LRESULT(0);
        }
        // The beep an `EDIT` makes for Enter and Escape arrives as WM_CHAR.
        if msg == WM_CHAR && (wp.0 == 13 || wp.0 == 27) {
            return LRESULT(0);
        }
        if msg == WM_KILLFOCUS {
            // The box is destroyed by this; nothing is forwarded to it after.
            close_edit(true);
            return LRESULT(0);
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = std::mem::transmute(prev);
        f(hwnd, msg, wp, lp)
    }
}

// ------------------------------------------------------------ the result

/// The program and title of a window, for the sidecar. Either may be absent.
fn window_names(hwnd: isize) -> (Option<String>, Option<String>) {
    let hwnd = HWND(hwnd as *mut c_void);
    unsafe {
        let mut buf = [0u16; 512];
        let n = GetWindowTextW(hwnd, &mut buf).max(0) as usize;
        let title = (n > 0).then(|| String::from_utf16_lossy(&buf[..n]));
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        let app = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok().and_then(|process| {
            let mut path = [0u16; 1024];
            let mut len = path.len() as u32;
            let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(path.as_mut_ptr()), &mut len);
            let _ = CloseHandle(process);
            ok.ok()?;
            let full = String::from_utf16_lossy(&path[..len as usize]);
            Path::new(&full).file_stem().map(|s| s.to_string_lossy().to_string())
        });
        (app, title)
    }
}

/// The selection as an image, annotations drawn on it.
unsafe fn compose(session: &Session, sel: &Sel) -> Option<polter_shots::Image> {
    unsafe {
        let mon = &session.mons[sel.mon];
        let (w, h) = (sel.rect.w, sel.rect.h);
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let src = CreateCompatibleDC(Some(screen));
        ReleaseDC(None, screen);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                // Negative: the first row in memory is the top one.
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let dib = CreateDIBSection(Some(mem), &info, DIB_RGB_COLORS, &mut bits, None, 0);
        let image = match dib {
            Ok(dib) if !bits.is_null() => {
                let old_mem = SelectObject(mem, dib.into());
                let old_src = SelectObject(src, mon.bmp.into());
                let from = sel.rect.relative_to(mon.rect.origin());
                let _ = BitBlt(mem, 0, 0, w, h, Some(src), from.x, from.y, SRCCOPY);
                SelectObject(src, old_src);
                let pens = Pens { dpi: mon.dpi };
                draw_items(mem, session.items.iter().map(|(a, c)| (a, *c)), sel.rect.origin(), &pens);
                let _ = GdiFlush();
                let bytes = std::slice::from_raw_parts(bits as *const u8, w as usize * h as usize * 4);
                let image = polter_shots::Image::from_bgrx(w as u32, h as u32, bytes);
                SelectObject(mem, old_mem);
                let _ = DeleteObject(dib.into());
                image
            }
            _ => None,
        };
        let _ = DeleteDC(mem);
        let _ = DeleteDC(src);
        image
    }
}

/// Put one format on the open clipboard. The block is the clipboard's once
/// `SetClipboardData` takes it, and ours to free until then.
unsafe fn set_clipboard(format: u32, bytes: &[u8]) -> bool {
    unsafe {
        let Ok(h) = GlobalAlloc(GMEM_MOVEABLE, bytes.len()) else { return false };
        let p = GlobalLock(h);
        if p.is_null() {
            let _ = GlobalFree(Some(h));
            return false;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        let _ = GlobalUnlock(h);
        let ok = SetClipboardData(format, Some(HANDLE(h.0))).is_ok();
        if !ok {
            let _ = GlobalFree(Some(h));
        }
        ok
    }
}

/// The words of the annotation line in the app's language. The msgids are
/// `src/input/screenshot.zig`'s -- `polter_shots::annot::EN` is that list --
/// so they are looked up, not written again here.
fn labels() -> [String; 7] {
    let en = annot::EN;
    [en.header, en.text, en.rect, en.arrow, en.pen, en.separator, en.see].map(tr)
}

/// Done: the composed image to the clipboard and to a file, the sidecar
/// beside it, and -- if Polter was in front when this started -- the path and
/// the annotation line into the pane that had the keyboard.
fn finish() {
    close_edit(true);
    if with(|s| s.sel.is_none()).unwrap_or(true) {
        return;
    }
    let Some(session) = end(false) else { return };
    let Some(sel) = session.sel.as_ref() else {
        free(&session);
        return;
    };
    let image = unsafe { compose(&session, sel) };
    let dpi = session.mons[sel.mon].dpi;
    let origin = sel.rect.origin();
    let items: Vec<Annotation> = session.items.iter().map(|(a, _)| a.relative_to(origin)).collect();
    let source = match sel.window {
        Some(hwnd) => {
            let (app, title) = window_names(hwnd);
            Source::Window { app, title }
        }
        None => Source::Region,
    };
    free(&session);
    let Some(image) = image else {
        // process-wide: the overlay is not a terminal window
        plogf!("[shot] the selection {:?} could not be composed; nothing written", sel.rect);
        return;
    };
    let Some(png) = polter_shots::encode::png(&image) else {
        // process-wide: the overlay is not a terminal window
        plogf!("[shot] the image could not be encoded; nothing written");
        return;
    };

    // 1. The clipboard: the bitmap every program reads, and the PNG beside
    //    it for the ones that prefer that.
    let dib = polter_shots::dib::encode(&image);
    let (on_clipboard, seq) = unsafe {
        // Opened in the control window's name: with no owner window,
        // `EmptyClipboard` leaves the clipboard ownerless and the
        // documentation says `SetClipboardData` then fails.
        let control = HWND(CONTROL.load(Ordering::Acquire) as *mut c_void);
        let opened = OpenClipboard(Some(control)).is_ok();
        let mut ok = false;
        if opened {
            let _ = EmptyClipboard();
            ok = set_clipboard(CF_DIB, &dib);
            let png_format = RegisterClipboardFormatW(w!("PNG"));
            if png_format != 0 {
                let _ = set_clipboard(png_format, &png);
            }
            let _ = CloseClipboard();
        }
        (ok, GetClipboardSequenceNumber())
    };

    // 2. The file and its sidecar.
    let taken = Cell::new(now());
    let utc = stamp(unsafe { GetSystemTime() });
    let clock = || {
        taken.set(now());
        taken.get()
    };
    let pause = || std::thread::sleep(std::time::Duration::from_millis(1));
    let saved = crate::shots::dir()
        .ok_or_else(|| "no LOCALAPPDATA, so nowhere to save it".to_string())
        .and_then(|dir| polter_shots::store::write_new(&dir, clock, pause, &png).map_err(|e| e.to_string()));
    let path = match saved {
        Ok(p) => p,
        Err(why) => {
            // process-wide: the overlay is not a terminal window
            plogf!(
                "[shot] done {}x{} but NOT saved: {why}. On the clipboard: {on_clipboard}",
                image.width, image.height
            );
            return;
        }
    };
    let taken = taken.get();
    let meta = Meta {
        image: path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        taken,
        utc_offset_minutes: polter_shots::name::utc_offset_minutes(&taken, &utc),
        size: (image.width, image.height),
        scale: f64::from(dpi) / 96.0,
        source,
    };
    let json = path.with_extension("json");
    let sidecar_written = std::fs::write(&json, annot::sidecar(&meta, &items));
    let words = labels();
    let l = Labels {
        header: &words[0],
        text: &words[1],
        rect: &words[2],
        arrow: &words[3],
        pen: &words[4],
        separator: &words[5],
        see: &words[6],
    };
    let note = annot::line(meta.size, &items, &json.to_string_lossy(), &l);

    // A paste made later by hand finds this file by the clipboard's sequence
    // number instead of saving the clipboard's bitmap a second time.
    if on_clipboard {
        crate::shots::remember(seq, path.clone(), note.clone());
    }
    // process-wide: the overlay is not a terminal window
    plogf!(
        "[shot] done: {}x{} px at scale {} from {:?}, {} annotation(s); saved {}; sidecar {}; \
         clipboard={on_clipboard} (sequence {seq})",
        image.width,
        image.height,
        meta.scale,
        sel.rect,
        items.len(),
        path.display(),
        match &sidecar_written {
            Ok(()) => "written".to_string(),
            Err(e) => format!("NOT written: {e}"),
        }
    );

    // 3. Into the pane, if Polter was in front: the path, then the line, as
    //    two pastes.
    let Some(pane) = session.origin_pane else {
        // process-wide: the overlay is not a terminal window
        plogf!("[shot] Polter was not the foreground application when this started; nothing pasted");
        return;
    };
    let surface = crate::tabs::surface_of(HWND(pane as *mut c_void));
    if surface.is_null() {
        // process-wide: the pane this was for has gone, so there is no window to name
        plogf!("[shot] the pane that had the keyboard ({pane:#x}) has no surface any more; nothing pasted");
        return;
    }
    let text = polter_droppath::quote(&path.to_string_lossy());
    unsafe { (crate::api().surface_text)(surface, text.as_ptr() as *const _, text.len()) };
    // process-wide: reported by pane window, which is unique in the process
    plogf!("[shot] path pasted into pane window {pane:#x}: {text:?}; annotation line to follow: {}", note.is_some());
    if let Some(note) = note {
        queue_note(NoteTarget::Hwnd(pane), note);
    }
}
