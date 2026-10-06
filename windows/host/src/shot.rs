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
use std::ffi::c_void;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU32, AtomicU8, Ordering};
use std::sync::Mutex;

use polter_shots::agent;
use polter_shots::annot::{self, By, Display, Item, Labels, Meta, Shape, Source, Terminal, Tile};
use polter_shots::dclick::{Detector, Mods, Press, Rule, Setting, Verdict};
use polter_shots::editor::{Editor, Effect, Export, Measure, Monitor, Window};
use polter_shots::geom::{self, Handle, Point, Rect};
use polter_shots::name::Stamp;
use polter_shots::overlay::Key;
use polter_shots::paste::{Later, MAX_TILES_PASTED, SECOND_PASTE_DELAY_MS};
use polter_shots::pixels::{self, Composed, Frozen, TILE_HEIGHT, TILE_OVERLAP};
use polter_shots::stitch::{Step, Stitcher};
use polter_shots::style::{self, Prefs, Tool};
use polter_shots::toolbar::{self, Button, Layout};
use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, GlobalFree, COLORREF, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
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
    GetAsyncKeyState, GetDoubleClickTime, GetKeyState, RegisterHotKey, ReleaseCapture, SetCapture, SetFocus,
    UnregisterHotKey, MOD_NOREPEAT, VK_CONTROL, VK_ESCAPE, VK_LWIN, VK_MENU, VK_RETURN, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::plogf;

/// The id this host registers the screenshot hotkey under. `quick.rs` has
/// `0xB0`; ids are per window, and this one is registered on a window of its
/// own, so the two could not collide even if they were equal.
const HOTKEY_ID: i32 = 0xB1;

/// Posted to the control window. `WM_APP + 33`, free when written
/// (`grep 'WM_APP +'`) -- and private to this window class in any case.
const WM_SHOT_MOUSE: u32 = WM_APP + 33;

/// `CF_DIB`, numerically, as in `shots.rs`.
const CF_DIB: u32 = 8;

/// The selection's frame and handles.
const ACCENT: COLORREF = COLORREF(0x00F0_A01E);


// ---------------------------------------------------------------- state

struct Mon {
    rect: Rect,
    dpi: u32,
    hwnd: HWND,
    /// This monitor as it was when the screenshot began. In memory only, and
    /// gone when the session is.
    frozen: Frozen,
}

/// The native text box while something is being typed.
struct EditCtl {
    hwnd: HWND,
    font: HFONT,
    /// Where it was last put, in virtual-screen pixels: `fit_edit` moves it
    /// only when this changes, and says so in the log when it does.
    rect: Rect,
    /// The parts of it on the toolbar **that it can still draw in** although
    /// they are cut out of its window, in virtual-screen pixels. Empty for a
    /// box that keeps clear, and empty for one whose cut the system honours
    /// -- which is what its window class is for (`register_text_class`), so
    /// this is empty unless that did not work (`keep_toolbar_clear`).
    on_toolbar: Vec<Rect>,
}

/// One screenshot in progress. What it *does* is `editor`
/// (`polter_shots::editor`); this is the windows around it.
struct Session {
    editor: Editor,
    mons: Vec<Mon>,
    edit: Option<EditCtl>,
    /// The id of the pane that had the keyboard when the shot was triggered,
    /// if Polter was the foreground application -- where the result is sent.
    /// An id rather than a window: ids are never reused, window handles are.
    origin_pane: Option<u64>,
    prev_fg: HWND,
    /// What the tools remembered when the session began, to know whether
    /// there is anything to save when it ends.
    prefs_at_start: Prefs,
    /// A long screenshot being taken.
    long: Option<LongShot>,
}

/// A long screenshot in progress: the frames stitched so far, and what the
/// last frame turned out to be (for the hint beside the toolbar).
struct LongShot {
    stitcher: Stitcher,
    /// The overlay that has the hole in it and owns the timer.
    hwnd: HWND,
    /// The selection: the rectangle of the screen each frame is.
    rect: Rect,
    last: Step,
    frames: u32,
    lost: u32,
    /// Frames held back because the screen was still changing
    /// (`Stitcher::offer`). Not dropped: the next steady one is joined.
    moving: u32,
}

/// One progress line for every this many frames of a long screenshot.
const LONG_LOG_EVERY: u32 = 10;

/// The overlay window's timer that takes a frame.
const TIMER_LONG: usize = 2;
/// How often, in milliseconds.
const LONG_INTERVAL_MS: u32 = 120;

thread_local! {
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

/// Whether the bundled annotation font was found and loaded.
static FONT_OK: AtomicBool = AtomicBool::new(false);
/// Whether the text box is open, for the message pump (`keys_are_raw`).
static TEXT_OPEN: AtomicBool = AtomicBool::new(false);

/// Whether key messages on this thread are the overlay's tool keys and must
/// reach it untouched by the input method.
///
/// **The overlay's letters are commands** -- `R` is the rectangle tool -- and
/// the main loop's pump is built for a terminal, where a letter under a
/// Chinese input method is the start of a composition. With the overlay in
/// front and that input method on, the pump (`ITfMessagePump::PeekMessageW`)
/// took the key off the queue and never handed it back: the log said
/// `[key] pump swallowed msg=0x100 vk=0x52 ... binding=no` and there was no
/// `[shot] key` line (task 1090). So while a session is open the pump is
/// asked not to route keys through TSF -- except while the text box is open,
/// which is the one place the input method is the point.
pub fn keys_are_raw() -> bool {
    ACTIVE.load(Ordering::Acquire) && !TEXT_OPEN.load(Ordering::Acquire)
}
static ACTIVE: AtomicBool = AtomicBool::new(false);
/// The control window, for the hook thread to post to.
static CONTROL: AtomicIsize = AtomicIsize::new(0);
/// The mouse trigger's modifiers as bits (see `mods_bits`); 0 is off.
static MOUSE_TRIGGER: AtomicU8 = AtomicU8::new(0);
/// Annotation lines waiting to be pasted, each a while after its image's
/// path and each addressed to a pane **by id**. A pane id comes out of one
/// counter and is never handed out twice, so a pane closed while its line
/// waits resolves to nothing; it cannot resolve to a different pane.
static NOTES: Mutex<Later<(u64, &'static str)>> = Mutex::new(Later::new());
/// The control window's timer for `NOTES`.
const TIMER_NOTES: usize = 1;
/// How many `[shot] key` lines have been written (see `log_key`).
static KEYS_LOGGED: AtomicU32 = AtomicU32::new(0);
const KEY_LOG_CAP: u32 = 200;

/// Whether `PolterShotText` is registered (`register_text_class`).
static TEXT_CLASS: AtomicBool = AtomicBool::new(false);

/// The text box's window class: the system's `EDIT` in everything but one
/// class style, `CS_PARENTDC`.
///
/// **That style is why cutting the toolbar out of the box did not keep the
/// box from drawing there** (task 1107, read on the test machine: `box draws
/// there=true (class CS_PARENTDC=true)`). A window of such a class draws
/// through its parent's clipping, and its own window region is not part of
/// that. Without the style the box's device context is its own window, cut
/// included, so the control cannot put a pixel on the toolbar by any road --
/// `WM_PAINT`, a key, the caret -- and nothing has to be drawn back after it.
///
/// Drawing it back after every message the box handled is what this
/// replaces. That made the box's procedure a source of the very messages it
/// answered by drawing, and the window thread never came back from opening
/// such a box (package 31c90b552: `MAIN THREAD BLOCKED`, the thread running).
unsafe fn register_text_class(hinst: HINSTANCE) {
    unsafe {
        let mut wc = WNDCLASSEXW { cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32, ..Default::default() };
        if let Err(e) = GetClassInfoExW(None, w!("EDIT"), &mut wc) {
            // process-wide: screenshots are one facility for the whole process
            plogf!("[shot] the EDIT class could not be read ({e}); the text box is a plain EDIT");
            return;
        }
        wc.cbSize = std::mem::size_of::<WNDCLASSEXW>() as u32;
        wc.style &= !(CS_PARENTDC | CS_GLOBALCLASS);
        wc.hInstance = hinst;
        wc.lpszClassName = w!("PolterShotText");
        // absence: means it was not reached -- the class registered
        if RegisterClassExW(&wc) == 0 {
            // process-wide: screenshots are one facility for the whole process
            plogf!("[shot] the text box's class could not be registered (err={}); the text box is a plain EDIT", GetLastError().0);
            return;
        }
        TEXT_CLASS.store(true, Ordering::Release);
    }
}

fn with<R>(f: impl FnOnce(&mut Session) -> R) -> Option<R> {
    SESSION.with(|s| s.try_borrow_mut().ok().and_then(|mut s| s.as_mut().map(f)))
}

fn scaled(px: i32, dpi: u32) -> i32 {
    (px * dpi.max(96) as i32 + 48) / 96
}

pub(crate) fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

pub(crate) fn now() -> Stamp {
    stamp(unsafe { GetLocalTime() })
}

pub(crate) fn stamp(t: windows::Win32::Foundation::SYSTEMTIME) -> Stamp {
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
        register_text_class(hinst.into());
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
    load_font();
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

/// The one visible notice that the shortcut is not working. The words are
/// the core's two msgids; the combination is added after them, outside the
/// translated text -- it is a key, not a word.
fn notify_hotkey_failure(combo: &str) {
    let body = format!("{}\n{combo}", tr(toolbar::HOTKEY_TAKEN));
    let shown = crate::notify::on_notification(None, Some(tr(toolbar::HOTKEY_FAILED)), Some(body));
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
            Err(e) => plogf!("[shot] mouse hook NOT installed ({e}); the mouse trigger will not work"),
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
                    // x in the low half, and in the high half the modifier
                    // bits this press was matched against -- so the line
                    // that reports the trigger names what was actually held.
                    let _ = PostMessageW(
                        Some(control),
                        WM_SHOT_MOUSE,
                        WPARAM((bits as usize) << 32 | ev.pt.x as u32 as usize),
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
            let mods = bits_mods((wp.0 >> 32) as u8);
            // process-wide: the mouse trigger fires whatever is under the pointer
            plogf!("[shot] {} double click at ({},{})", mods.label(), at.x, at.y);
            begin(Some(at));
            LRESULT(0)
        }
        WM_TIMER if wp.0 == TIMER_NOTES => {
            paste_notes();
            LRESULT(0)
        }
        crate::shot_agent::WM_AGENT_DONE => {
            crate::shot_agent::deliver_finished();
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

pub(crate) fn tick_ms() -> u64 {
    unsafe { windows::Win32::System::SystemInformation::GetTickCount64() }
}

/// Queue an annotation line to be pasted into pane `pane`,
/// `SECOND_PASTE_DELAY_MS` from now -- the second of the two pastes, kept
/// apart from the first so the program in the terminal reads them apart.
///
/// Called after a screenshot's path has been pasted, and from the clipboard
/// callback when a paste made by hand reuses a screenshot that has
/// annotations.
pub fn paste_note_later(pane: u64, note: String) {
    paste_later(pane, note, SECOND_PASTE_DELAY_MS, "annotation line");
}

/// Queue `text` to be pasted into pane `pane`, `delay_ms` from now. A long
/// screenshot's tiles go in one after another this way, each its own paste.
///
/// `what` is what the text is, for the log: a line that says "annotation
/// line pasted" about a tile's path sends whoever reads it looking for an
/// annotation.
fn paste_later(pane: u64, text: String, delay_ms: u64, what: &'static str) {
    let now = tick_ms();
    NOTES.lock().unwrap_or_else(|e| e.into_inner()).push(now, delay_ms, (pane, what), text);
    arm_notes_timer(now);
}

/// Set the control window's timer for the next line due, or stop it when
/// none is waiting.
fn arm_notes_timer(now: u64) {
    let control = HWND(CONTROL.load(Ordering::Acquire) as *mut c_void);
    let next = NOTES.lock().unwrap_or_else(|e| e.into_inner()).next_in(now);
    unsafe {
        match next {
            None => {
                let _ = KillTimer(Some(control), TIMER_NOTES);
            }
            // At least a millisecond: a timer of 0 is rounded up by the
            // system anyway, and this says so.
            Some(wait) => {
                // absence: means it was not reached -- the timer was set, and
                // the line's own `annotation line pasted` (or `not pasted`)
                // follows when it fires
                if control.0.is_null() || SetTimer(Some(control), TIMER_NOTES, wait.clamp(1, 60_000) as u32, None) == 0 {
                    // process-wide: the queue belongs to the process, not to a window
                    plogf!(
                        "[shot] the timer for an annotation line could not be set (err={}); the line \
                         stays queued and is not pasted",
                        GetLastError().0
                    );
                }
            }
        }
    }
}

/// The second paste: every annotation line that has fallen due, each into
/// the pane it was queued for and no other.
///
/// **The pane is looked up again now, by id.** If it was closed while the
/// line waited there is no surface and the line is dropped, with a line here
/// saying so. Which pane has the keyboard by now is not asked: the line
/// belongs with the path, and goes where the path went.
fn paste_notes() {
    let now = tick_ms();
    let due = NOTES.lock().unwrap_or_else(|e| e.into_inner()).take_due(now);
    for ((pane, what), note) in due {
        let surface = crate::tabs::surface_of_pane(pane);
        if surface.is_null() {
            // process-wide: the pane this was for has gone, so there is no window to name
            plogf!("[shot] {what} for pane={pane} not pasted: that pane was closed while it waited");
            continue;
        }
        unsafe { (crate::api().surface_text)(surface, note.as_ptr() as *const _, note.len()) };
        // process-wide: reported by pane id, which is unique in the process
        plogf!("[shot] {what} pasted into pane={pane}: {} chars", note.chars().count());
    }
    arm_notes_timer(now);
}

// ------------------------------------------------------------ the freeze

pub(crate) unsafe extern "system" fn monitor_cb(
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

pub(crate) unsafe extern "system" fn window_cb(hwnd: HWND, data: LPARAM) -> windows::core::BOOL {
    unsafe {
        let out = &mut *(data.0 as *mut Vec<Window>);
        if IsWindowVisible(hwnd).as_bool() && !IsIconic(hwnd).as_bool() {
            // Cloaked: on another virtual desktop, or a suspended store app's
            // placeholder. Visible to `IsWindowVisible`, not to a person.
            let mut cloaked = 0u32;
            let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut u32 as *mut c_void, 4);
            if cloaked == 0 {
                if let Some(rect) = window_bounds(hwnd) {
                    out.push(Window { id: hwnd.0 as usize as u64, rect });
                }
            }
        }
    }
    true.into()
}

/// Open a session: freeze the screen and put an overlay on every monitor.
/// `preselect` is where a mouse trigger happened; the window there starts
/// out selected.

/// Read a rectangle of the screen into a `Frozen`: the monitor as it is now,
/// before any overlay exists.
pub(crate) unsafe fn grab(screen: HDC, rect: Rect) -> Option<Frozen> {
    unsafe {
        let canvas = Canvas::new(screen, rect)?;
        // CAPTUREBLT so layered windows are in the picture.
        let ok = BitBlt(canvas.dc, 0, 0, rect.w, rect.h, Some(screen), rect.x, rect.y, SRCCOPY | CAPTUREBLT);
        let _ = GdiFlush();
        if ok.is_err() {
            return None;
        }
        Frozen::new(rect, canvas.bits().to_vec())
    }
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
            .and_then(crate::tabs::pane_of)
            .map(|(_, _, id)| id);

        // The windows first, in z-order, **before any overlay exists** -- so
        // the list cannot contain one, and "the topmost window under the
        // cursor" needs no exception for our own.
        let mut wins: Vec<Window> = Vec::new();
        let _ = EnumWindows(Some(window_cb), LPARAM(&mut wins as *mut _ as isize));
        let mut found: Vec<(Rect, u32)> = Vec::new();
        let _ = EnumDisplayMonitors(None, None, Some(monitor_cb), LPARAM(&mut found as *mut _ as isize));

        let screen = GetDC(None);
        let mut mons = Vec::new();
        for (rect, dpi) in found {
            match grab(screen, rect) {
                Some(frozen) => mons.push(Mon { rect, dpi, hwnd: HWND::default(), frozen }),
                // process-wide: about a monitor, not about a terminal window
                None => plogf!("[shot] monitor {:?} could not be captured (err={}); left out", rect, GetLastError().0),
            }
        }
        ReleaseDC(None, screen);
        if mons.is_empty() {
            // process-wide: one session at a time for the whole process
            plogf!("[shot] no monitor could be captured; nothing to select from");
            ACTIVE.store(false, Ordering::Release);
            return;
        }

        let prefs = load_prefs();
        let monitors: Vec<Monitor> =
            mons.iter().map(|m| Monitor { rect: m.rect, scale: f64::from(m.dpi.max(96)) / 96.0 }).collect();
        let window_count = wins.len();
        let editor = Editor::new(monitors, wins, prefs.clone(), preselect);
        // process-wide: one session at a time for the whole process
        plogf!(
            "[shot] begin: {} monitor(s) {:?}, {} window(s), foreground={:?} polter_pane={:?}, preselected={:?}",
            mons.len(),
            mons.iter().map(|m| (m.rect.x, m.rect.y, m.rect.w, m.rect.h, m.dpi)).collect::<Vec<_>>(),
            window_count,
            prev_fg.0,
            origin_pane,
            editor.selection().map(|s| s.rect)
        );
        let mon_rects: Vec<Rect> = mons.iter().map(|m| m.rect).collect();
        SESSION.with(|s| {
            *s.borrow_mut() =
                Some(Session { editor, mons, edit: None, origin_pane, prev_fg, prefs_at_start: prefs, long: None })
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
                WS_POPUP | WS_CLIPCHILDREN,
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
            // No input method on the overlay itself: its keys are commands.
            // The text box is a child with a context of its own and keeps it.
            let _ = windows::Win32::UI::Input::Ime::ImmAssociateContext(hwnd, windows::Win32::UI::Input::Ime::HIMC::default());
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
        plogf!("[shot] overlays shown; SetForegroundWindow={took}; annotation font loaded={}", font_ok());
    }
}

/// Close the session: overlays gone, the frozen pictures freed with it,
/// foreground handed back. Returns the session for `finish` to use, already
/// detached; `None` when it was cancelled.
fn end(cancelled: bool) -> Option<Session> {
    let session = SESSION.with(|s| s.try_borrow_mut().ok().and_then(|mut s| s.take()));
    ACTIVE.store(false, Ordering::Release);
    TEXT_OPEN.store(false, Ordering::Release);
    let session = session?;
    unsafe {
        if let Some(e) = &session.edit {
            let _ = DestroyWindow(e.hwnd);
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
    // What each tool was last used with, for the next screenshot.
    if *session.editor.prefs() != session.prefs_at_start {
        save_prefs(session.editor.prefs());
    }
    if cancelled {
        // process-wide: one session at a time for the whole process
        plogf!("[shot] cancelled: clipboard untouched, nothing written");
        return None;
    }
    Some(session)
}

// ------------------------------------------------------- tools' memory

fn prefs_path() -> Option<std::path::PathBuf> {
    crate::project::resolve_state_dir().map(|d| d.join("shot-tools.json"))
}

/// The colour and step each tool was last used with. Anything unreadable is
/// the defaults (`Prefs::from_json`), and so is no file at all.
fn load_prefs() -> Prefs {
    prefs_path().and_then(|p| std::fs::read_to_string(p).ok()).map(|t| Prefs::from_json(&t)).unwrap_or_default()
}

fn save_prefs(prefs: &Prefs) {
    let Some(path) = prefs_path() else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Err(e) = std::fs::write(&path, prefs.to_json()) {
        // process-wide: the overlay is not a terminal window
        plogf!("[shot] the tools' colours and sizes were not saved to {}: {e}", path.display());
    }
}

// --------------------------------------------------------------- the font

/// Where the bundled annotation font is: `polter\fonts` under the resources
/// directory -- the one this host found its skills and plugins in
/// (`announce_resources_dir`), not a path worked out again here.
fn font_path() -> Option<std::path::PathBuf> {
    let resources = std::env::var_os("POLTER_RESOURCES_DIR").filter(|v| !v.is_empty())?;
    Some(std::path::PathBuf::from(resources).join("polter").join("fonts").join("NotoSansSC-Regular.otf"))
}

const FONT_FACE: PCWSTR = w!("Noto Sans SC");

fn font_ok() -> bool {
    FONT_OK.load(Ordering::Acquire)
}

/// Make the bundled font available to this process, and only to it.
///
/// **Missing is said, here and on the toolbar, and not papered over**
/// (§9.1): text is then drawn in the system's font, which is not the font
/// the other platform draws in, and nobody would know why the two pictures
/// differ.
fn load_font() {
    let path = font_path();
    let added = path.as_ref().map_or(0, |p| {
        let wide: Vec<u16> = p.to_string_lossy().encode_utf16().chain(Some(0)).collect();
        unsafe { AddFontResourceExW(PCWSTR(wide.as_ptr()), FR_PRIVATE, None) }
    });
    FONT_OK.store(added > 0, Ordering::Release);
    // process-wide: one font for the whole process
    plogf!(
        "[shot] annotation font {:?}: {}",
        path,
        if added > 0 { "loaded" } else { "NOT loaded; text falls back to Segoe UI and the toolbar says so" }
    );
}

/// The font annotations are written in, `px` pixels tall.
fn annot_font(px: i32) -> HFONT {
    make_font(px, if font_ok() { FONT_FACE } else { w!("Segoe UI") })
}

/// The font the overlay's own words (size label, tooltips) are in.
fn ui_font(px: i32) -> HFONT {
    make_font(px, w!("Segoe UI"))
}

fn make_font(px: i32, face: PCWSTR) -> HFONT {
    unsafe {
        CreateFontW(
            -px,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            0,
            face,
        )
    }
}

/// Text measured by GDI in the annotation font: what `Editor` hit-tests
/// text against.
pub(crate) struct Gdi;

impl Measure for Gdi {
    fn text(&self, text: &str, font_px: i32) -> (i32, i32) {
        unsafe {
            let dc = CreateCompatibleDC(None);
            let font = annot_font(font_px);
            let old = SelectObject(dc, font.into());
            let mut rc = RECT::default();
            let mut t = wide(text);
            DrawTextW(dc, &mut t, &mut rc, DT_CALCRECT | DT_NOPREFIX);
            SelectObject(dc, old);
            let _ = DeleteObject(font.into());
            let _ = DeleteDC(dc);
            (rc.right - rc.left, rc.bottom - rc.top)
        }
    }
}

// --------------------------------------------------------------- drawing

/// A 32-bit top-down bitmap GDI can draw into and this code can read and
/// write as bytes: B, G, R, X rows, the format `polter_shots::pixels` works
/// in. Covers `rect` of the virtual screen.
pub(crate) struct Canvas {
    pub(crate) dc: HDC,
    dib: HBITMAP,
    old: HGDIOBJ,
    bits: *mut u8,
    rect: Rect,
}

impl Canvas {
    pub(crate) unsafe fn new(like: HDC, rect: Rect) -> Option<Canvas> {
        unsafe {
            let dc = CreateCompatibleDC(Some(like));
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: rect.w,
                    // Negative: the first row in memory is the top one.
                    biHeight: -rect.h,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits: *mut c_void = std::ptr::null_mut();
            match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
                Ok(dib) if !bits.is_null() => {
                    let old = SelectObject(dc, dib.into());
                    Some(Canvas { dc, dib, old, bits: bits as *mut u8, rect })
                }
                _ => {
                    let _ = DeleteDC(dc);
                    None
                }
            }
        }
    }

    /// The pixels. GDI batches its drawing, so it is flushed first: what GDI
    /// was asked to draw is in these bytes by the time they are read.
    pub(crate) fn bits(&self) -> &mut [u8] {
        unsafe {
            let _ = GdiFlush();
            std::slice::from_raw_parts_mut(self.bits, self.rect.w as usize * self.rect.h as usize * 4)
        }
    }
}

impl Drop for Canvas {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.dib.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

fn rgb_ref((r, g, b): (u8, u8, u8)) -> COLORREF {
    COLORREF(r as u32 | (g as u32) << 8 | (b as u32) << 16)
}

fn colour_ref(index: u8) -> COLORREF {
    rgb_ref(style::COLOURS[index as usize % style::COLOURS.len()])
}

/// Black or white, whichever shows on this colour (the digit in a number's
/// circle, the paper under the text being typed).
fn ink_on((r, g, b): (u8, u8, u8)) -> COLORREF {
    let luma = (299 * r as u32 + 587 * g as u32 + 114 * b as u32) / 1000;
    COLORREF(if luma > 150 { 0 } else { 0x00FF_FFFF })
}

/// Draw the annotations that are not mosaics onto `canvas`, in the order
/// given. **The one routine for both the overlay and the saved image**, so
/// what is saved is what was shown. Mosaics are already in the pixels
/// (`pixels::apply_mosaics`) and are skipped here.
///
/// `hide_text_of` is the annotation whose text the text box is showing
/// instead: its words are not drawn twice.
pub(crate) unsafe fn draw_items<'a>(
    canvas: &Canvas,
    items: impl Iterator<Item = (usize, &'a Item)>,
    scale: f64,
    hide_text_of: Option<usize>,
) {
    unsafe {
        let hdc = canvas.dc;
        let o = canvas.rect.origin();
        SetBkMode(hdc, TRANSPARENT);
        for (index, item) in items {
            let colour = rgb_ref(item.colour_rgb());
            let width = item.stroke_px(scale);
            let brush_style = LOGBRUSH { lbStyle: BS_SOLID, lbColor: colour, lbHatch: 0 };
            // Round ends and joins: a thick freehand stroke with square ones
            // is a row of notches.
            let pen = ExtCreatePen(
                PS_GEOMETRIC | PS_SOLID | PS_ENDCAP_ROUND | PS_JOIN_ROUND,
                width as u32,
                &brush_style,
                None,
            );
            let brush = CreateSolidBrush(colour);
            let old_pen = SelectObject(hdc, pen.into());
            let old_brush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
            let font = annot_font(style::font_px(item.level, scale));
            let old_font = SelectObject(hdc, font.into());
            SetTextColor(hdc, colour);
            let at = |q: Point| q.relative_to(o);
            let hidden = hide_text_of == Some(index);
            match &item.shape {
                Shape::Mosaic(_) => {}
                Shape::Rect(r) => {
                    let r = r.relative_to(o);
                    let _ = Rectangle(hdc, r.x, r.y, r.right(), r.bottom());
                }
                Shape::Ellipse(r) => {
                    let r = r.relative_to(o);
                    let _ = Ellipse(hdc, r.x, r.y, r.right(), r.bottom());
                }
                Shape::Line { from, to } => {
                    let (a, b) = (at(*from), at(*to));
                    let _ = MoveToEx(hdc, a.x, a.y, None);
                    let _ = LineTo(hdc, b.x, b.y);
                }
                Shape::Arrow { from, to } => {
                    let (a, b) = (at(*from), at(*to));
                    let _ = MoveToEx(hdc, a.x, a.y, None);
                    let _ = LineTo(hdc, b.x, b.y);
                    if let Some(head) = geom::arrow_head(a, b, width * 5) {
                        SelectObject(hdc, brush.into());
                        let pts = head.map(|q| POINT { x: q.x, y: q.y });
                        let _ = Polygon(hdc, &pts);
                    }
                }
                Shape::Pen(points) => {
                    let pts: Vec<POINT> = points.iter().map(|q| at(*q)).map(|q| POINT { x: q.x, y: q.y }).collect();
                    let _ = Polyline(hdc, &pts);
                }
                Shape::Highlighter(points) => {
                    // Not GDI's to draw: it multiplies into what is there.
                    pixels::highlight(
                        canvas.bits(),
                        canvas.rect,
                        points,
                        width,
                        item.colour_rgb(),
                    );
                }
                Shape::Text { at: q, text, size } => {
                    if !hidden {
                        let q = at(*q);
                        let mut rc = RECT { left: q.x, top: q.y, right: q.x + size.0, bottom: q.y + size.1 };
                        DrawTextW(hdc, &mut wide(text), &mut rc, DT_NOPREFIX | DT_NOCLIP);
                    }
                }
                Shape::Number { n, at: q, text, size } => {
                    let c = at(*q);
                    let r = annot::number_radius(item.level, scale);
                    SelectObject(hdc, brush.into());
                    SelectObject(hdc, GetStockObject(NULL_PEN));
                    let _ = Ellipse(hdc, c.x - r, c.y - r, c.x + r + 1, c.y + r + 1);
                    let digit = wide(&n.to_string());
                    let mut extent = SIZE::default();
                    let _ = GetTextExtentPoint32W(hdc, &digit, &mut extent);
                    SetTextColor(hdc, ink_on(item.colour_rgb()));
                    let _ = TextOutW(hdc, c.x - extent.cx / 2, c.y - extent.cy / 2, &digit);
                    SetTextColor(hdc, colour);
                    if !text.is_empty() && !hidden {
                        let t = annot::caption_at(*q, item.level, scale, size.1).relative_to(o);
                        let mut rc = RECT { left: t.x, top: t.y, right: t.x + size.0, bottom: t.y + size.1 };
                        DrawTextW(hdc, &mut wide(text), &mut rc, DT_NOPREFIX | DT_NOCLIP);
                    }
                }
            }
            SelectObject(hdc, old_font);
            SelectObject(hdc, old_pen);
            SelectObject(hdc, old_brush);
            let _ = DeleteObject(font.into());
            let _ = DeleteObject(pen.into());
            let _ = DeleteObject(brush.into());
        }
    }
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

const BAR: COLORREF = COLORREF(0x0030_3030);
const BAR_ACTIVE: COLORREF = COLORREF(0x0068_6868);
const BAR_HOVER: COLORREF = COLORREF(0x0048_4848);
const INK: COLORREF = COLORREF(0x00FF_FFFF);
const INK_OFF: COLORREF = COLORREF(0x0080_8080);

/// Draw one toolbar button's picture into `r` (canvas coordinates).
///
/// Shapes are drawn as shapes rather than taken from a font: a glyph that a
/// machine's fonts do not have comes out as an empty box, and a toolbar of
/// empty boxes cannot be used. The three that stay glyphs (undo, redo and
/// the two marks) were seen to draw on the test machine.
unsafe fn draw_icon(hdc: HDC, button: Button, r: Rect, scale: f64, ink: COLORREF) {
    unsafe {
        let line = style::px(2, scale).max(1);
        let pen = CreatePen(PS_SOLID, line, ink);
        let brush = CreateSolidBrush(ink);
        let old_pen = SelectObject(hdc, pen.into());
        let old_brush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
        // The picture's box: the button less a quarter all round.
        let m = r.w / 4;
        let (l, t, rt, b) = (r.x + m, r.y + m, r.right() - m, r.bottom() - m);
        let (cx, cy) = (r.x + r.w / 2, r.y + r.h / 2);
        let glyph = |s: &str, px: i32| {
            let font = ui_font(px);
            let old = SelectObject(hdc, font.into());
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, ink);
            let mut rc = RECT { left: r.x, top: r.y, right: r.right(), bottom: r.bottom() };
            DrawTextW(hdc, &mut wide(s), &mut rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
            SelectObject(hdc, old);
            let _ = DeleteObject(font.into());
        };
        let stroke = |pts: &[(i32, i32)]| {
            let pts: Vec<POINT> = pts.iter().map(|(x, y)| POINT { x: *x, y: *y }).collect();
            let _ = Polyline(hdc, &pts);
        };
        match button {
            Button::Tool(Tool::Select) => {
                // A pointer: an arrow from the top-left.
                SelectObject(hdc, brush.into());
                let pts = [(l, t), (l, b), (l + (rt - l) / 3, b - (b - t) / 3), (rt - m / 2, b - (b - t) / 3)]
                    .map(|(x, y)| POINT { x, y });
                let _ = Polygon(hdc, &pts);
            }
            Button::Tool(Tool::Rect) => {
                let _ = Rectangle(hdc, l, t + m / 3, rt, b - m / 3);
            }
            Button::Tool(Tool::Ellipse) => {
                let _ = Ellipse(hdc, l, t + m / 3, rt, b - m / 3);
            }
            Button::Tool(Tool::Line) => stroke(&[(l, b), (rt, t)]),
            Button::Tool(Tool::Arrow) => {
                stroke(&[(l, b), (rt, t)]);
                stroke(&[(rt - (rt - l) / 2, t), (rt, t), (rt, t + (b - t) / 2)]);
            }
            Button::Tool(Tool::Pen) => {
                let q = (rt - l) / 4;
                stroke(&[(l, b), (l + q, t + q), (l + 2 * q, b - q), (l + 3 * q, t), (rt, t + q)]);
            }
            Button::Tool(Tool::Highlighter) => {
                let thick = CreatePen(PS_SOLID, line * 3, ink);
                SelectObject(hdc, thick.into());
                stroke(&[(l, cy), (rt, cy)]);
                SelectObject(hdc, pen.into());
                let _ = DeleteObject(thick.into());
            }
            Button::Tool(Tool::Text) => glyph("A", r.h * 5 / 9),
            Button::Tool(Tool::Number) => {
                let _ = Ellipse(hdc, l, t, rt, b);
                glyph("1", r.h * 4 / 9);
            }
            Button::Tool(Tool::Mosaic) => {
                // Four squares of a chequerboard.
                let (hw, hh) = ((rt - l) / 2, (b - t) / 2);
                let _ = Rectangle(hdc, l, t, rt, b);
                fill(hdc, Rect::new(l, t, hw, hh), ink);
                fill(hdc, Rect::new(l + hw, t + hh, rt - l - hw, b - t - hh), ink);
            }
            Button::Undo => glyph("↶", r.h * 5 / 9),
            Button::Redo => glyph("↷", r.h * 5 / 9),
            Button::Long => {
                // A tall page and an arrow down it.
                let _ = Rectangle(hdc, l + m / 2, t - m / 3, rt - m / 2, b + m / 3);
                stroke(&[(cx, t + m / 3), (cx, b - m / 4)]);
                stroke(&[(cx - m / 2, b - m / 4 - m / 2), (cx, b - m / 4), (cx + m / 2, b - m / 4 - m / 2)]);
            }
            Button::Cancel => glyph("✕", r.h * 5 / 9),
            Button::Done => glyph("✓", r.h * 5 / 9),
            Button::Colour(c) => {
                fill(hdc, r, colour_ref(c));
            }
            Button::Level(level) => {
                // A dot that grows with the step.
                SelectObject(hdc, brush.into());
                let radius = (r.w * (level as i32 + 1)) / 12 + 1;
                let _ = Ellipse(hdc, cx - radius, cy - radius, cx + radius + 1, cy + radius + 1);
            }
        }
        SelectObject(hdc, old_pen);
        SelectObject(hdc, old_brush);
        let _ = DeleteObject(pen.into());
        let _ = DeleteObject(brush.into());
    }
}

/// The toolbar, the tooltip of the button under the pointer, and -- when the
/// bundled font is missing -- a line saying so.
unsafe fn draw_toolbar(canvas: &Canvas, editor: &Editor, layout: &Layout, scale: f64, monitor: Rect) {
    unsafe {
        let hdc = canvas.dc;
        let o = canvas.rect.origin();
        fill(hdc, layout.bar.relative_to(o), BAR);
        if let Some(row) = layout.props {
            fill(hdc, row.relative_to(o), BAR);
        }
        let (colour, level) = editor.current();
        for (button, rect) in &layout.buttons {
            let r = rect.relative_to(o);
            let current = match *button {
                Button::Tool(t) => editor.tool() == t,
                Button::Colour(c) => c == colour,
                Button::Level(l) => l == level,
                _ => false,
            };
            let enabled = match *button {
                Button::Undo => editor.can_undo(),
                Button::Redo => editor.can_redo(),
                _ => true,
            };
            let hovered = editor.hover_button() == Some(*button) && enabled;
            match *button {
                Button::Colour(_) => {
                    // The current colour wears a ring.
                    if current {
                        let ring = style::px(2, scale);
                        frame(hdc, Rect::new(r.x - ring * 2, r.y - ring * 2, r.w + ring * 4, r.h + ring * 4), INK, ring);
                    }
                }
                _ if current => fill(hdc, r, BAR_ACTIVE),
                _ if hovered => fill(hdc, r, BAR_HOVER),
                _ => {}
            }
            draw_icon(hdc, *button, r, scale, if enabled { INK } else { INK_OFF });
        }

        let font = ui_font(style::px(14, scale));
        let old_font = SelectObject(hdc, font.into());
        SetBkMode(hdc, OPAQUE);
        SetBkColor(hdc, COLORREF(0x0020_2020));
        SetTextColor(hdc, INK);
        let label = |text: &str, x: i32, y: i32| {
            let text = wide(&format!(" {text} "));
            let mut size = SIZE::default();
            let _ = GetTextExtentPoint32W(hdc, &text, &mut size);
            // Kept on the monitor sideways.
            let x = x.min(monitor.right() - o.x - size.cx).max(monitor.x - o.x);
            let _ = TextOutW(hdc, x, y, &text);
            size.cy
        };
        let below = layout.props.map_or(layout.bar.bottom(), |r| r.bottom()) - o.y + style::px(4, scale);
        let mut next_line = below;
        if !font_ok() {
            next_line += label(&tr(toolbar::FONT_MISSING), layout.bar.x - o.x, next_line) + style::px(2, scale);
        }
        if let Some((button, rect)) =
            editor.hover_button().and_then(|b| layout.rect_of(b).map(|r| (b, r.relative_to(o))))
        {
            let tip = toolbar::tooltip(button, editor.props(), tr);
            label(&tip, rect.x, next_line.max(rect.bottom() + style::px(4, scale)));
        }
        SelectObject(hdc, old_font);
        let _ = DeleteObject(font.into());
    }
}

/// Everything monitor `i`'s overlay shows, drawn into a canvas the size of
/// the monitor. `like` is a device context of that overlay.
unsafe fn compose_overlay(s: &Session, i: usize, like: HDC) -> Option<Canvas> {
    unsafe {
        {
            let mon = &s.mons[i];
            let canvas = Canvas::new(like, mon.rect)?;
            let e = &s.editor;
            let scale = e.scale();
            let o = mon.rect.origin();

            // The frozen picture, with the mosaics in it -- including the one
            // being dragged out, so its size is chosen by what it hides.
            mon.frozen.show(canvas.bits(), mon.rect);
            pixels::apply_mosaics(canvas.bits(), mon.rect, &mon.frozen, e.items(), scale);
            if let Some(live) = e.live() {
                pixels::apply_mosaics(canvas.bits(), mon.rect, &mon.frozen, std::slice::from_ref(live), scale);
            }

            // What is in focus on this monitor: the selection, the region
            // being dragged, or the window under the cursor. The rest dims.
            let sel = e.selection().filter(|x| x.monitor == i).map(|x| x.rect);
            let forming = e.forming().filter(|f| f.1 == i).map(|f| f.0);
            let hover = if e.selection().is_none() && e.forming().is_none() {
                e.hover().filter(|x| x.0 == i).map(|x| x.1)
            } else {
                None
            };
            let focus = sel.or(forming).or(hover);
            pixels::dim(canvas.bits(), mon.rect, focus);

            let hide = e.text_box().and_then(|t| t.editing);
            let mosaic = |it: &Item| matches!(it.shape, Shape::Mosaic(_));
            let drawn = e.draw_order().into_iter().filter(|(_, it)| !mosaic(it));
            let live = e.live().filter(|it| !mosaic(it)).map(|it| (usize::MAX, it));
            draw_items(&canvas, drawn.chain(live), scale, hide);

            let mem = canvas.dc;
            if let Some(f) = focus {
                frame(mem, f.relative_to(o), ACCENT, scaled(2, mon.dpi));
            }
            if let Some(sel) = sel {
                let f = sel.relative_to(o);
                let g = scaled(4, mon.dpi);
                let knob = |c: Point| fill(mem, Rect::new(c.x - g, c.y - g, g * 2, g * 2), ACCENT);
                match e.selected().and_then(|k| e.items().get(k)) {
                    // The selected annotation: its grips, or its outline
                    // when it can only be moved.
                    Some(item) => {
                        let grips = item.grips();
                        if grips.is_empty() {
                            frame(mem, item.bounds(scale).relative_to(o), ACCENT, 1);
                        }
                        for (_, at) in grips {
                            knob(at.relative_to(o));
                        }
                    }
                    // Otherwise the selection's own handles, while the
                    // select tool is what the mouse is.
                    None if e.tool() == Tool::Select => {
                        for handle in Handle::ALL {
                            knob(handle.at(f));
                        }
                    }
                    None => {}
                }

                // Size, in pixels of the image.
                let ui = ui_font(scaled(14, mon.dpi));
                let old_font = SelectObject(mem, ui.into());
                SetBkMode(mem, OPAQUE);
                SetBkColor(mem, COLORREF(0x0020_2020));
                SetTextColor(mem, INK);
                let label = wide(&format!(" {} × {} ", f.w, f.h));
                let ly = if f.y >= scaled(22, mon.dpi) { f.y - scaled(22, mon.dpi) } else { f.y + scaled(4, mon.dpi) };
                let _ = TextOutW(mem, f.x, ly, &label);
                SelectObject(mem, old_font);
                let _ = DeleteObject(ui.into());

                if let Some(layout) = e.layout() {
                    draw_toolbar(&canvas, e, &layout, scale, mon.rect);
                    if let Some(long) = &s.long {
                        draw_long_status(&canvas, long, &layout, sel, scale, mon.rect);
                    }
                }
            }
            Some(canvas)
        }
    }
}

unsafe fn paint(hwnd: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        with(|s| {
            let Some(i) = s.mons.iter().position(|m| m.hwnd == hwnd) else { return };
            let Some(canvas) = compose_overlay(s, i, hdc) else { return };
            let mon = &s.mons[i];
            let _ = BitBlt(hdc, 0, 0, mon.rect.w, mon.rect.h, Some(canvas.dc), 0, 0, SRCCOPY);
            toolbar_over_text_box(s, i, &canvas);
        });
        let _ = EndPaint(hwnd, &ps);
    }
}

/// Draw `canvas` -- monitor `i`'s overlay as just composed -- into the parts
/// of the text box that lie on the toolbar and that the box can still draw
/// in. **Only ever from the overlay's own `WM_PAINT`**, and with nothing to
/// do unless the box's window class failed at its one job
/// (`register_text_class`): `on_toolbar` is empty otherwise.
///
/// Through a device context that is not clipped by the overlay's children,
/// so that what is seen there does not depend on how the two windows are
/// clipped against each other.
unsafe fn toolbar_over_text_box(s: &Session, i: usize, canvas: &Canvas) {
    let Some(edit) = s.edit.as_ref().filter(|e| !e.on_toolbar.is_empty()) else { return };
    if s.editor.selection().map(|x| x.monitor) != Some(i) {
        return;
    }
    let mon = &s.mons[i];
    unsafe {
        // `DCX_CACHE` alone: no `DCX_CLIPCHILDREN`, and no `DCX_USESTYLE`
        // to bring the window's own `WS_CLIPCHILDREN` back in.
        let dc = GetDCEx(Some(mon.hwnd), None, DCX_CACHE);
        if dc.is_invalid() {
            return;
        }
        // A caret drawn in the box is an inversion; drawing under a shown
        // one leaves its ghost when it is next taken away.
        let hid = HideCaret(Some(edit.hwnd)).is_ok();
        for r in &edit.on_toolbar {
            let l = r.relative_to(mon.rect.origin());
            let _ = BitBlt(dc, l.x, l.y, l.w, l.h, Some(canvas.dc), l.x, l.y, SRCCOPY);
        }
        if hid {
            let _ = ShowCaret(Some(edit.hwnd));
        }
        ReleaseDC(Some(mon.hwnd), dc);
    }
}

/// The text box has drawn and may have drawn on the toolbar: have the
/// overlay paint those parts again, in its own time.
///
/// **This asks; it draws nothing.** `InvalidateRect` sends no message and
/// returns at once, the overlay's `WM_PAINT` comes when the queue is
/// otherwise empty, and any number of these before it are one paint. Nothing
/// the overlay does while painting is on `textbox::box_draws`'s list, so a
/// paint cannot ask for the next one.
///
/// Nothing at all for a box with nothing in `on_toolbar` -- every box that
/// keeps clear, and every box whose cut the system honours.
fn toolbar_again_after_box() {
    let Some((overlay, parts)) = with(|s| {
        let e = s.edit.as_ref().filter(|e| !e.on_toolbar.is_empty())?;
        let m = &s.mons[s.editor.selection()?.monitor];
        Some((m.hwnd, e.on_toolbar.iter().map(|r| r.relative_to(m.rect.origin())).collect::<Vec<Rect>>()))
    })
    .flatten() else {
        return;
    };
    for l in parts {
        let rc = RECT { left: l.x, top: l.y, right: l.right(), bottom: l.bottom() };
        let _ = unsafe { InvalidateRect(Some(overlay), Some(&rc), false) };
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

/// The modifiers as they were when the key message being handled was made.
///
/// **`GetKeyState`, not `GetAsyncKeyState`, and that is the whole of defect
/// D1 (task 1085).** `GetKeyState` is the keyboard as of the message this
/// thread is processing; `GetAsyncKeyState` is the keyboard right now. For a
/// chord pressed and released faster than this thread gets to it -- every
/// injected `Ctrl+Z`, and a real one behind a slow repaint -- "right now"
/// already has Ctrl up, and the `Z` was taken for a bare `Z`. Every other key
/// handler in this host reads `GetKeyState`; the hook (`held`) is the one
/// place the asynchronous state is the right one, because a low-level hook
/// runs before the event reaches any thread's synchronised state.
fn key_mods() -> Mods {
    let down = |vk: u16| unsafe { GetKeyState(vk as i32) } < 0;
    Mods {
        ctrl: down(VK_CONTROL.0),
        shift: down(VK_SHIFT.0),
        alt: down(VK_MENU.0),
        win: down(VK_LWIN.0) || down(VK_RWIN.0),
    }
}

/// One line per key the overlay receives: which key, the modifiers the
/// decision was made with, and what was decided.
///
/// `async_ctrl` is the reading the decision is *not* made with, printed
/// beside the one it is: where the two differ, this line is the evidence for
/// D1's cause (`ctrl=true async_ctrl=false` on a chord that arrived late).
fn log_key(vk: u16, mods: Mods, does: Key, annotations: usize) {
    // absence: depends -- after KEY_LOG_CAP lines in one process it means
    // nothing, and the cap's own line says when that happened; before it, no
    // line means the overlay's window procedure was not sent a WM_KEYDOWN
    // (the key went to the text box, to another window, or was not delivered)
    let n = KEYS_LOGGED.fetch_add(1, Ordering::Relaxed) + 1;
    if n <= KEY_LOG_CAP {
        // process-wide: the overlay is not a terminal window
        plogf!(
            "[shot] key vk=0x{vk:02x} mods={} async_ctrl={} annotations={annotations} -> {}",
            mods.label(),
            held(VK_CONTROL.0),
            does.label()
        );
    }
    if n == KEY_LOG_CAP {
        // process-wide: about the log, not a window
        plogf!("[shot] key: reached the {KEY_LOG_CAP} line cap; further keys are handled but not printed");
    }
}

fn point_of(hwnd: HWND, lp: LPARAM) -> Option<Point> {
    let (x, y) = ((lp.0 & 0xFFFF) as i16 as i32, ((lp.0 >> 16) & 0xFFFF) as i16 as i32);
    with(|s| s.mons.iter().find(|m| m.hwnd == hwnd).map(|m| Point::new(x + m.rect.x, y + m.rect.y))).flatten()
}

/// Do what `Editor` asked for, with the session no longer borrowed: most of
/// these send messages back to this thread's window procedures.
fn perform(hwnd: HWND, effect: Effect) {
    match effect {
        Effect::None => {}
        Effect::Repaint => repaint(),
        Effect::Capture => {
            unsafe { SetCapture(hwnd) };
            repaint();
        }
        Effect::Release => {
            let _ = unsafe { ReleaseCapture() };
            repaint();
        }
        Effect::Cancel => {
            end(true);
        }
        Effect::Finish => finish(),
        Effect::Long => start_long(),
        Effect::LeaveLong => stop_long(),
        Effect::OpenText => open_edit(),
        Effect::RestyleText => restyle_edit(),
        Effect::CommitText => commit_edit(),
    }
}

unsafe extern "system" fn overlay_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let effect = match msg {
        WM_PAINT => {
            unsafe { paint(hwnd) };
            return LRESULT(0);
        }
        // Painted whole in WM_PAINT; erasing first would flash.
        WM_ERASEBKGND => return LRESULT(1),
        WM_MOUSEMOVE => point_of(hwnd, lp).and_then(|p| with(|s| s.editor.pointer_move(p, key_mods()))),
        WM_LBUTTONDOWN => point_of(hwnd, lp).and_then(|p| with(|s| s.editor.pointer_down(p, key_mods(), &Gdi))),
        WM_LBUTTONDBLCLK => point_of(hwnd, lp).and_then(|p| with(|s| s.editor.double_click(p, key_mods(), &Gdi))),
        WM_LBUTTONUP => point_of(hwnd, lp).and_then(|p| with(|s| s.editor.pointer_up(p))),
        WM_RBUTTONDOWN => with(|s| s.editor.right_click()),
        // Alt+F4 on an overlay closes the session, not one monitor's window.
        WM_CLOSE => Some(Effect::Cancel),
        WM_TIMER if wp.0 == TIMER_LONG => {
            long_tick();
            return LRESULT(0);
        }
        WM_KEYDOWN => {
            let vk = wp.0 as u16;
            let mods = key_mods();
            with(|s| {
                let before = s.editor.items().len();
                let (key, effect) = s.editor.key(vk, mods, &Gdi);
                log_key(vk, mods, key, before);
                effect
            })
        }
        // The text box asks what colours to draw itself in: the text's own.
        WM_CTLCOLOREDIT => {
            let colour = with(|s| s.editor.text_box().map(|t| t.colour)).flatten().unwrap_or(0);
            unsafe {
                let dc = HDC(wp.0 as *mut c_void);
                // Dark paper under light ink, light under dark.
                let paper = if ink_on(style::COLOURS[colour as usize % style::COLOURS.len()]).0 == 0 { COLORREF(0x0030_3030) } else { COLORREF(0x00FF_FFFF) };
                SetTextColor(dc, colour_ref(colour));
                SetBkColor(dc, paper);
                SetDCBrushColor(dc, paper);
                return LRESULT(GetStockObject(DC_BRUSH).0 as isize);
            }
        }
        _ => return unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    };
    perform(hwnd, effect.unwrap_or(Effect::None));
    LRESULT(0)
}

// ---------------------------------------------------------- long screenshot

/// Enter long-screenshot mode (`Editor` already has): open the selection to
/// the live screen and start taking frames.
///
/// **The overlay gets a hole where the selection is.** A window region is
/// the one thing that does both jobs at once: what is under the hole shows
/// (the live page), and the mouse over the hole is not ours at all, so the
/// wheel scrolls the application underneath with no forwarding to get wrong.
///
/// The overlays are also taken out of screen capture, so a toolbar that had
/// to sit inside a selection as tall as the monitor is not in the frames.
fn start_long() {
    let Some((hwnd, mon_rect, sel, bar, overlays)) = with(|s| {
        let sel = *s.editor.selection()?;
        let m = &s.mons[sel.monitor];
        let bar = s.editor.layout().map(|l| l.bar);
        Some((m.hwnd, m.rect, sel.rect, bar, s.mons.iter().map(|m| m.hwnd).collect::<Vec<_>>()))
    })
    .flatten() else {
        return;
    };
    let Some(stitcher) = Stitcher::new(sel.w as usize, sel.h as usize) else { return };
    with(|s| s.long = Some(LongShot { stitcher, hwnd, rect: sel, last: Step::Unchanged, frames: 0, lost: 0, moving: 0 }));
    unsafe {
        let o = mon_rect.origin();
        let local = sel.relative_to(o);
        let region = CreateRectRgn(0, 0, mon_rect.w, mon_rect.h);
        let hole = CreateRectRgn(local.x, local.y, local.right(), local.bottom());
        CombineRgn(Some(region), Some(region), Some(hole), RGN_DIFF);
        let _ = DeleteObject(hole.into());
        // A toolbar inside the selection stays part of the window.
        if let Some(bar) = bar.and_then(|b| b.intersect(sel)) {
            let b = bar.relative_to(o);
            let keep = CreateRectRgn(b.x, b.y, b.right(), b.bottom());
            CombineRgn(Some(region), Some(region), Some(keep), RGN_OR);
            let _ = DeleteObject(keep.into());
        }
        // The system owns the region from here.
        SetWindowRgn(hwnd, Some(region), true);
        let mut excluded = 0;
        for h in &overlays {
            if !h.0.is_null() && SetWindowDisplayAffinity(*h, WDA_EXCLUDEFROMCAPTURE).is_ok() {
                excluded += 1;
            }
        }
        let timer = SetTimer(Some(hwnd), TIMER_LONG, LONG_INTERVAL_MS, None);
        // process-wide: the overlay is not a terminal window
        plogf!(
            "[shot] long screenshot started: frames of {:?} every {LONG_INTERVAL_MS} ms; {excluded} of {} overlay(s) \
             excluded from capture; timer={}",
            sel,
            overlays.len(),
            timer != 0
        );
    }
    repaint();
}

/// Leave long-screenshot mode without finishing: cover the selection again.
fn stop_long() {
    let Some((long, overlays)) =
        with(|s| s.long.take().map(|l| (l, s.mons.iter().map(|m| m.hwnd).collect::<Vec<_>>()))).flatten()
    else {
        return;
    };
    unsafe {
        let _ = KillTimer(Some(long.hwnd), TIMER_LONG);
        SetWindowRgn(long.hwnd, None, true);
        for h in overlays {
            if !h.0.is_null() {
                let _ = SetWindowDisplayAffinity(h, WDA_NONE);
            }
        }
    }
    // process-wide: the overlay is not a terminal window
    plogf!(
        "[shot] long screenshot left without finishing: {} frame(s), {} dropped, {} held back as still moving, {} px collected and discarded",
        long.frames,
        long.lost,
        long.moving,
        long.stitcher.total_height()
    );
    repaint();
}

/// Take one frame of the selection as it is on the live screen and hand it
/// to the stitcher.
fn long_tick() {
    let Some(rect) = with(|s| s.long.as_ref().map(|l| l.rect)).flatten() else { return };
    let frame = unsafe {
        let screen = GetDC(None);
        let frame = Canvas::new(screen, rect).and_then(|canvas| {
            BitBlt(canvas.dc, 0, 0, rect.w, rect.h, Some(screen), rect.x, rect.y, SRCCOPY | CAPTUREBLT)
                .ok()
                .map(|()| canvas.bits().to_vec())
        });
        ReleaseDC(None, screen);
        frame
    };
    let Some(frame) = frame else { return };
    let changed = with(|s| {
        let long = s.long.as_mut()?;
        // Only a frame that is the one before it, pixel for pixel, is
        // joined (screenshot.md §9.7): one caught mid-scroll or half
        // painted is `Moving` and waits for the next.
        let step = long.stitcher.offer(&frame);
        long.frames += 1;
        match step {
            Step::Lost => long.lost += 1,
            Step::Moving => long.moving += 1,
            _ => {}
        }
        if long.frames % LONG_LOG_EVERY == 0 {
            // absence: depends -- one line per LONG_LOG_EVERY frames, so a session of fewer frames than that has none; the start and finish lines are not gated
            // process-wide: the overlay is not a terminal window
            plogf!(
                "[shot] long screenshot frame {}: {} px so far, {} dropped for want of overlap, {} held back as still moving; this frame -> {:?}",
                long.frames,
                long.stitcher.total_height(),
                long.lost,
                long.moving,
                step
            );
        }
        // What the hint shows follows the last frame that said something:
        // an unchanged frame, or one held back, does not clear "scroll
        // more slowly".
        let shown = if matches!(step, Step::Unchanged | Step::Moving) { long.last } else { step };
        // The status line also changes on the frame that makes it say the
        // region keeps changing.
        let restless = step == Step::Moving
            && long.moving == toolbar::LONG_RESTLESS_AFTER
            && toolbar::long_restless(long.stitcher.never_steady(), long.moving);
        let changed = shown != long.last || matches!(step, Step::Added(_)) || restless;
        if step == Step::Full && long.last != Step::Full {
            // process-wide: the overlay is not a terminal window
            plogf!("[shot] long screenshot reached the {} px limit; no more is added", polter_shots::stitch::MAX_HEIGHT);
            unsafe {
                let _ = KillTimer(Some(long.hwnd), TIMER_LONG);
            }
        }
        long.last = shown;
        Some(changed)
    })
    .flatten()
    .unwrap_or(false);
    if changed {
        repaint();
    }
}

/// Beside the toolbar: how tall the picture is so far, what the last frame
/// meant, and a small copy of the picture beside the selection.
unsafe fn draw_long_status(canvas: &Canvas, long: &LongShot, layout: &Layout, sel: Rect, scale: f64, monitor: Rect) {
    unsafe {
        let hdc = canvas.dc;
        let o = canvas.rect.origin();
        let font = ui_font(style::px(14, scale));
        let old_font = SelectObject(hdc, font.into());
        SetBkMode(hdc, OPAQUE);
        SetBkColor(hdc, COLORREF(0x0020_2020));
        SetTextColor(hdc, INK);
        // Until the first new rows are joined the line says what to do.
        let added = long.stitcher.total_height() > long.rect.h as usize;
        let restless = toolbar::long_restless(long.stitcher.never_steady(), long.moving);
        let hint = toolbar::long_hint(long.last, added, restless).map(|h| format!(" — {}", tr(h))).unwrap_or_default();
        let text = wide(&format!(" {} {} px{hint} ", tr(toolbar::LONG), long.stitcher.total_height()));
        let at = Point::new(layout.bar.x, layout.bar.bottom() + style::px(4, scale)).relative_to(o);
        let _ = TextOutW(hdc, at.x, at.y, &text);
        SelectObject(hdc, old_font);
        let _ = DeleteObject(font.into());

        // The preview: right of the selection, or left of it, or not at all.
        let gap = style::px(12, scale);
        let width = style::px(120, scale);
        let x = if sel.right() + gap + width <= monitor.right() {
            sel.right() + gap
        } else if sel.x - gap - width >= monitor.x {
            sel.x - gap - width
        } else {
            return;
        };
        let room = (monitor.h - gap * 2).max(1);
        let Some((w, h, bits)) = long.stitcher.thumbnail(width as usize, room as usize) else { return };
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w as i32,
                biHeight: -(h as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let top = (sel.y.max(monitor.y + gap)).min(monitor.bottom() - gap - h as i32).max(monitor.y);
        let dest = Point::new(x, top).relative_to(o);
        SetDIBitsToDevice(
            hdc,
            dest.x,
            dest.y,
            w as u32,
            h as u32,
            0,
            0,
            0,
            h as u32,
            bits.as_ptr() as *const c_void,
            &info,
            DIB_RGB_COLORS,
        );
        frame(hdc, Rect::new(dest.x - 1, dest.y - 1, w as i32 + 2, h as i32 + 2), ACCENT, 1);
    }
}

// ------------------------------------------------------------- text box

/// Open a native `EDIT` for the text `Editor` is about to take. **A real
/// edit control, so the input method works in it** -- an IME composes into a
/// window that implements the text protocols, and this one already does.
/// Several lines: Enter is a line break, Ctrl+Enter and Esc end it.
fn open_edit() {
    let Some((parent, mon_rect, scale, tb)) = with(|s| {
        let sel = *s.editor.selection()?;
        let m = &s.mons[sel.monitor];
        Some((m.hwnd, m.rect, s.editor.scale(), s.editor.text_box()?.clone()))
    })
    .flatten() else {
        return;
    };
    let font_px = style::font_px(tb.level, scale);
    // As tall as what is in it and inside the selection (`textbox`). It was
    // `font_px * 4` whatever was typed, stopped only by the monitor: 264 px
    // at the largest size on a 144 DPI screen, over the toolbar (task 1104).
    let Some(rect) = with(|s| s.editor.text_rect(polter_shots::textbox::lines(&tb.text), &Gdi)).flatten() else {
        // The editor has a box the host cannot place: end it, as below.
        commit_edit();
        return;
    };
    let local = rect.relative_to(mon_rect.origin());
    let (width, height) = (rect.w, rect.h);
    let initial: Vec<u16> = tb.text.replace('\n', "\r\n").encode_utf16().chain(Some(0)).collect();
    unsafe {
        let edit = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            // `EDIT` itself only if the class could not be made.
            if TEXT_CLASS.load(Ordering::Acquire) { w!("PolterShotText") } else { w!("EDIT") },
            PCWSTR(initial.as_ptr()),
            // No border: the box is whole lines tall, and a border would
            // take two pixels of the last one. Its paper is what shows it.
            WS_CHILD | WS_VISIBLE | WINDOW_STYLE((ES_MULTILINE | ES_AUTOVSCROLL | ES_AUTOHSCROLL | ES_WANTRETURN) as u32),
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
            commit_edit();
            return;
        };
        let font = annot_font(font_px);
        SendMessageW(edit, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        let prev = SetWindowLongPtrW(edit, GWLP_WNDPROC, edit_proc as *const () as isize);
        SetWindowLongPtrW(edit, GWLP_USERDATA, prev);
        // The caret after what is already there.
        const EM_SETSEL: u32 = 0x00B1;
        let end = GetWindowTextLengthW(edit).max(0);
        SendMessageW(edit, EM_SETSEL, Some(WPARAM(end as usize)), Some(LPARAM(end as isize)));
        with(|s| s.edit = Some(EditCtl { hwnd: edit, font, rect, on_toolbar: Vec::new() }));
        keep_toolbar_clear(edit, rect);
        log_edit(rect, polter_shots::textbox::lines(&tb.text), "opened");
        // The one time the input method is wanted: see `keys_are_raw`.
        TEXT_OPEN.store(true, Ordering::Release);
        let _ = SetForegroundWindow(parent);
        let _ = SetFocus(Some(edit));
    }
    repaint();
}

/// The text's colour or size changed while it is being typed: the box
/// follows, so what is seen while typing is what will be drawn.
fn restyle_edit() {
    let Some((edit, old, level, scale)) = with(|s| {
        let e = s.edit.as_ref()?;
        Some((e.hwnd, e.font, s.editor.text_box()?.level, s.editor.scale()))
    })
    .flatten() else {
        return;
    };
    unsafe {
        let font = annot_font(style::font_px(level, scale));
        SendMessageW(edit, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        with(|s| {
            if let Some(e) = &mut s.edit {
                e.font = font;
            }
        });
        let _ = DeleteObject(old.into());
        let _ = InvalidateRect(Some(edit), None, true);
        let _ = SetFocus(Some(edit));
    }
    // Another size is another line height, and for a new text possibly
    // another place (`Editor::set_level`).
    fit_edit();
    repaint();
}

/// Put the text box where `Editor::text_rect` says it goes for what is in
/// it now: a line taller for each line break, never past the selection's
/// bottom edge. Called after anything that may have changed the text or
/// its size; does nothing when the box is already there.
fn fit_edit() {
    const EM_GETLINECOUNT: u32 = 0x00BA;
    const EM_GETFIRSTVISIBLELINE: u32 = 0x00CE;
    const EM_LINESCROLL: u32 = 0x00B6;
    let Some((edit, was, parent_origin)) = with(|s| {
        let e = s.edit.as_ref()?;
        let sel = s.editor.selection()?;
        Some((e.hwnd, e.rect, s.mons[sel.monitor].rect.origin()))
    })
    .flatten() else {
        return;
    };
    // The control's own count: with ES_AUTOHSCROLL a line is never wrapped,
    // so this is the line breaks and one.
    let lines = unsafe { SendMessageW(edit, EM_GETLINECOUNT, None, None).0 }.max(1) as i32;
    let Some(rect) = with(|s| s.editor.text_rect(lines, &Gdi)).flatten() else {
        return;
    };
    if rect == was {
        return;
    }
    let local = rect.relative_to(parent_origin);
    unsafe {
        let _ = SetWindowPos(edit, None, local.x, local.y, rect.w, rect.h, SWP_NOZORDER | SWP_NOACTIVATE);
        // Enter on the last line scrolls the text up a line before the box
        // has grown to hold it. If everything fits again, show it from the
        // top; if it does not, the control keeps the caret in view itself.
        let line = with(|s| s.editor.text_box().map(|t| s.editor.text_line(t.level, &Gdi))).flatten().unwrap_or(1);
        let first = SendMessageW(edit, EM_GETFIRSTVISIBLELINE, None, None).0 as i32;
        if first > 0 && lines * line <= rect.h {
            SendMessageW(edit, EM_LINESCROLL, Some(WPARAM(0)), Some(LPARAM(-(first as isize))));
        }
    }
    with(|s| {
        if let Some(e) = &mut s.edit {
            e.rect = rect;
        }
    });
    keep_toolbar_clear(edit, rect);
    log_edit(rect, lines, "now");
    repaint();
}

/// The toolbar is above the text box, always: whatever of the box would lie
/// over either toolbar row is cut out of the box's window, so it is neither
/// drawn there nor pressed there, and the press reaches the toolbar.
///
/// `textbox::rect` already keeps a box off the toolbar wherever it can.
/// What is left is a text opened for editing again whose first line sits
/// where the toolbar now is; this is for that one.
///
/// **The cut settles who is pressed; whether it settles what is seen is
/// asked of the system each time and logged** (task 1107). With the box's
/// own class it should: `box draws there=false`. If the answer is ever
/// `true`, the parts are remembered and the overlay is asked to paint them
/// again after the box draws (`toolbar_again_after_box`).
fn keep_toolbar_clear(edit: HWND, rect: Rect) {
    let keep = with(|s| s.editor.text_keep_clear()).unwrap_or_default();
    let holes = polter_shots::textbox::covered(rect, &keep);
    // Nothing is drawn back while the cut is being changed.
    with(|s| {
        if let Some(e) = &mut s.edit {
            e.on_toolbar.clear();
        }
    });
    unsafe {
        if holes.is_empty() {
            // The whole window again. The system owns a region once set.
            let _ = SetWindowRgn(edit, None, true);
            return;
        }
        let region = CreateRectRgn(0, 0, rect.w, rect.h);
        for h in &holes {
            let l = h.relative_to(rect.origin());
            let hole = CreateRectRgn(l.x, l.y, l.right(), l.bottom());
            let _ = CombineRgn(Some(region), Some(region), Some(hole), RGN_DIFF);
            let _ = DeleteObject(hole.into());
        }
        let _ = SetWindowRgn(edit, Some(region), true);
    }
    // Which window can still draw there once the cut is made, as the system
    // answers it. `box draws there` true means the box's own device context
    // ignores its window region (what `CS_PARENTDC` does, and the class made
    // in `register_text_class` is without it); `overlay draws there` false
    // would mean `WS_CLIPCHILDREN` keeps the overlay out of the box's whole
    // rectangle, cut or not.
    let (box_draws, overlay_draws, parent_dc) = unsafe {
        let first = holes[0];
        let visible = |dc: HDC, r: Rect| {
            let rc = RECT { left: r.x, top: r.y, right: r.right(), bottom: r.bottom() };
            !dc.is_invalid() && RectVisible(dc, &rc).as_bool()
        };
        let own = GetDC(Some(edit));
        let box_draws = visible(own, first.relative_to(rect.origin()));
        ReleaseDC(Some(edit), own);
        let parent = GetParent(edit).unwrap_or_default();
        let mut origin = POINT::default();
        let _ = ClientToScreen(parent, &mut origin);
        let clipped = GetDCEx(Some(parent), None, DCX_CACHE | DCX_CLIPCHILDREN);
        let overlay_draws = visible(clipped, first.relative_to(Point::new(origin.x, origin.y)));
        ReleaseDC(Some(parent), clipped);
        (box_draws, overlay_draws, GetClassLongW(edit, GCL_STYLE) & CS_PARENTDC.0 != 0)
    };
    let again = polter_shots::textbox::to_draw_back(holes.clone(), box_draws);
    let then = if again.is_empty() { "nothing is drawn back" } else { "the overlay paints them again after the box draws" };
    with(|s| {
        if let Some(e) = &mut s.edit {
            e.on_toolbar = again;
        }
    });
    // process-wide: the overlay is not a terminal window
    plogf!(
        "[shot] text box: {} part(s) of it are under the toolbar and were cut out of it; in the first, box draws there={box_draws} \
         (class CS_PARENTDC={parent_dc}), overlay draws there={overlay_draws}; {then}",
        holes.len()
    );
}

fn log_edit(rect: Rect, lines: i32, what: &str) {
    let (line, font, sel) = with(|s| {
        let t = s.editor.text_box()?;
        Some((s.editor.text_line(t.level, &Gdi), style::font_px(t.level, s.editor.scale()), s.editor.selection()?.rect))
    })
    .flatten()
    .unwrap_or((0, 0, Rect::new(0, 0, 0, 0)));
    // process-wide: the overlay is not a terminal window
    plogf!(
        "[shot] text box {}: {}x{} px at ({},{}), {} line(s) typed, a line is {} px (font {} px); selection {}x{} at ({},{})",
        what,
        rect.w,
        rect.h,
        rect.x,
        rect.y,
        lines,
        line,
        font,
        sel.w,
        sel.h,
        sel.x,
        sel.y
    );
}

/// Close the text box and hand what was typed to `Editor`, which decides
/// what it becomes (nothing, if nothing was typed).
///
/// **This is re-entered, and `Editor::close_text` is what makes that
/// harmless.** `DestroyWindow` below makes the box lose the keyboard;
/// `edit_proc` answers `WM_KILLFOCUS` by calling this function again, from
/// inside the first call and before the first has handed over the text. The
/// second call must do nothing whatsoever -- it once ended the box with an
/// empty string, and every text annotation was lost without a line in the
/// log (task 1090). `close_text` says `true` to exactly one caller.
///
/// Keep the order of steps the same as `host_commit` in
/// `polter-shots/src/editor.rs`, which is this function with the windows
/// taken out and is what the tests re-enter.
fn commit_edit() {
    if !with(|s| s.editor.close_text()).unwrap_or(false) {
        return;
    }
    // From here this call owns the close. The native control may be absent
    // (it failed to open); then there is nothing to read.
    let edit = with(|s| s.edit.take()).flatten();
    let text = edit.as_ref().map_or(String::new(), |e| unsafe {
        let mut buf = vec![0u16; GetWindowTextLengthW(e.hwnd).max(0) as usize + 1];
        let n = GetWindowTextW(e.hwnd, &mut buf).max(0) as usize;
        String::from_utf16_lossy(&buf[..n])
    });
    let parent = edit.as_ref().and_then(|e| unsafe { GetParent(e.hwnd) }.ok());
    TEXT_OPEN.store(false, Ordering::Release);
    if let Some(e) = &edit {
        unsafe {
            // Re-enters this function through WM_KILLFOCUS; see above.
            let _ = DestroyWindow(e.hwnd);
            let _ = DeleteObject(e.font.into());
        }
    }
    let counts = with(|s| {
        let before = s.editor.items().len();
        s.editor.end_text(&text, &Gdi);
        (before, s.editor.items().len())
    });
    // process-wide: the overlay is not a terminal window
    plogf!(
        "[shot] text box closed: {} char(s) read from it (native control present: {}); annotations {:?}",
        text.chars().count(),
        edit.is_some(),
        counts.map(|(before, after)| format!("{before} -> {after}"))
    );
    if let Some(parent) = parent {
        let _ = unsafe { SetFocus(Some(parent)) };
    }
    repaint();
}

/// Ctrl+Enter and Escape end the typing and keep it; so does losing the
/// keyboard. Plain Enter is a line break and is the control's own. While an
/// input method is composing, Escape reaches the IME and not this procedure
/// (it arrives as `VK_PROCESSKEY`), so it cancels the composition only.
unsafe extern "system" fn edit_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        let ctrl = GetKeyState(VK_CONTROL.0 as i32) < 0;
        if msg == WM_KEYDOWN && (wp.0 as u16 == VK_ESCAPE.0 || (wp.0 as u16 == VK_RETURN.0 && ctrl)) {
            commit_edit();
            return LRESULT(0);
        }
        // What those two keys leave behind as characters: Escape, and the
        // line feed Ctrl+Enter makes.
        if msg == WM_CHAR && (wp.0 == 27 || wp.0 == 10) {
            return LRESULT(0);
        }
        if msg == WM_KILLFOCUS {
            // The box is destroyed by this; nothing is forwarded to it after.
            commit_edit();
            return LRESULT(0);
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = std::mem::transmute(prev);
        let r = f(hwnd, msg, wp, lp);
        // Whatever may have added or removed a line: a key, a character, a
        // paste, a cut, an undo, an input method finishing. The box follows
        // what is in it (`fit_edit` does nothing when nothing changed).
        const WM_IME_ENDCOMPOSITION: u32 = 0x010E;
        const WM_IME_COMPOSITION: u32 = 0x010F;
        if matches!(msg, WM_CHAR | WM_KEYDOWN | WM_PASTE | WM_CUT | WM_CLEAR | WM_UNDO | WM_IME_ENDCOMPOSITION | WM_IME_COMPOSITION) {
            fit_edit();
        }
        // A box that can draw on the toolbar although that part is cut out
        // of it (there is none unless its class failed; see
        // `register_text_class`): after a message it draws by, the overlay
        // is asked to paint there again. Asked, never drawn from here, and
        // only for the messages on a list -- drawing here after everything
        // but a few questions is what stopped the window thread.
        if polter_shots::textbox::box_draws(msg, wp.0 & 0x0001 != 0) {
            toolbar_again_after_box();
        }
        r
    }
}

// ------------------------------------------------------------ the result

/// The program, title and process of a window, for the sidecar. Any may be
/// absent.
pub(crate) fn window_names(hwnd: u64) -> (Option<String>, Option<String>, Option<u32>) {
    let hwnd = HWND(hwnd as usize as *mut c_void);
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
        (app, title, (pid != 0).then_some(pid))
    }
}

/// `light` or `dark`: what the system asks applications to draw themselves
/// in right now (screenshot.md §11), read when the screenshot is written.
///
/// This used to go by this host's own background, which is the same dark
/// colour whatever the setting, so every sidecar said `dark` (the test
/// machine, 94bf0b56a, with the setting on light and switched both ways).
pub(crate) fn appearance() -> String {
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let mut value = 0u32;
    let mut len = std::mem::size_of::<u32>() as u32;
    let read = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("AppsUseLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut value as *mut u32 as *mut c_void),
            Some(&mut len),
        )
    };
    polter_shots::agent::appearance(read.is_ok().then_some(value)).to_string()
}

/// The first seven characters of `HEAD` in `cwd` and whether a tracked file has changes, if
/// `cwd` is in a git repository and git answers within 300 ms. Otherwise
/// nothing -- a screenshot does not wait for git (§11).
pub(crate) fn git_of(cwd: &str) -> Option<(String, bool)> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let cwd = cwd.to_string();
    let (tx, rx) = std::sync::mpsc::channel();
    let spawned = std::thread::Builder::new().name("polter-shot-git".into()).spawn(move || {
        crate::name_this_thread("polter-shot-git");
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&cwd)
                .args(args)
                .creation_flags(CREATE_NO_WINDOW)
                .stdin(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        };
        // Seven characters of HEAD; dirty for tracked files only
        // (`agent::git_state`, the same reading as the macOS side).
        let answer = run(&["rev-parse", "HEAD"]).and_then(|head| {
            run(&["status", "--porcelain", "--untracked-files=no"]).and_then(|changes| agent::git_state(&head, &changes))
        });
        let _ = tx.send(answer);
    });
    spawned.ok()?;
    rx.recv_timeout(std::time::Duration::from_millis(300)).ok().flatten()
}

/// The file name of the last shot of the same window (§11), found among the
/// newest sidecars in `dir`.
pub(crate) fn previous_in(dir: &Path, image: &str, app: Option<&str>, title: Option<&str>) -> Option<String> {
    // Without both names there is no "same window" to look for.
    app.filter(|a| !a.is_empty())?;
    title.filter(|t| !t.is_empty())?;
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|d| d.ok()?.file_name().into_string().ok())
        .filter(|n| matches!(polter_shots::name::parse(n), Some((_, polter_shots::name::Kind::Json))))
        .collect();
    // Names sort by time. The newest two hundred are enough to look through:
    // a week of shots is all the directory keeps.
    names.sort_unstable_by(|a, b| b.cmp(a));
    let earlier: Vec<_> = names
        .iter()
        .take(200)
        .filter_map(|n| std::fs::read_to_string(dir.join(n)).ok())
        .filter_map(|t| agent::identity(&t))
        .collect();
    agent::previous(&earlier, image, app, title)
}

/// The terminal id (`0x…`) of the terminal in pane `pane`, as the agent
/// tools name it: `ghostty_surface_poltergeist_id`, sixteen hex digits. The
/// core answers 0 for a surface that is no terminal, and then the sidecar
/// leaves `terminal.id` out.
pub(crate) fn terminal_id_of(pane: u64) -> Option<String> {
    let surface = crate::tabs::surface_of_pane(pane);
    if surface.is_null() {
        return None;
    }
    let id = unsafe { (crate::api().surface_poltergeist_id)(surface) };
    agent::terminal_id(id)
}

/// Whether a session of the user's own is open.
pub(crate) fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

/// The control window, for other threads to post to.
pub(crate) fn control_window() -> HWND {
    HWND(CONTROL.load(Ordering::Acquire) as *mut c_void)
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
/// `polter_shots::annot::EN`, looked up one by one.
fn labels() -> [String; 11] {
    let en = annot::EN;
    [
        en.header,
        en.text,
        en.rect,
        en.ellipse,
        en.line,
        en.arrow,
        en.pen,
        en.highlighter,
        en.mosaic,
        en.separator,
        en.see,
    ]
    .map(tr)
}

/// The selection as it leaves: cut from the frozen picture with the mosaics
/// applied (`Composed::new`), the other annotations drawn on top.
///
/// **`Composed` is the only thing with a way out** -- `png`, `dib` and
/// `tiles` are its methods -- so the file, the clipboard image and the tiles
/// cannot be the picture a mosaic was meant to hide.
fn compose(mon: &Mon, export: &Export) -> Option<Composed> {
    let mut composed = Composed::new(&mon.frozen, export.selection.rect, &export.on_screen, export.scale, &[])?;
    let mut drawn = false;
    composed.draw(|bits, rect| unsafe {
        let screen = GetDC(None);
        let canvas = Canvas::new(screen, rect);
        ReleaseDC(None, screen);
        let Some(canvas) = canvas else { return };
        canvas.bits().copy_from_slice(bits);
        let others = export.on_screen.iter().enumerate().filter(|(_, it)| !matches!(it.shape, Shape::Mosaic(_)));
        draw_items(&canvas, others, export.scale, None);
        bits.copy_from_slice(canvas.bits());
        drawn = true;
    });
    drawn.then_some(composed)
}

/// Done: the composed image to the clipboard and to a file, the sidecar
/// beside it, and -- if Polter was in front when this started -- the path and
/// the annotation line into the pane that had the keyboard.
fn finish() {
    commit_edit();
    let Some(export) = with(|s| s.editor.export()).flatten() else { return };
    // A long screenshot's frames, taken out before the windows go.
    let long = with(|s| s.long.take()).flatten();
    if let Some(l) = &long {
        let _ = unsafe { KillTimer(Some(l.hwnd), TIMER_LONG) };
        // process-wide: the overlay is not a terminal window
        plogf!(
            "[shot] long screenshot finished: {} frame(s), {} dropped for want of overlap, {} held back as still moving, {} px tall",
            l.frames,
            l.lost,
            l.moving,
            l.stitcher.total_height()
        );
        if l.stitcher.never_steady() {
            // process-wide: the overlay is not a terminal window
            plogf!(
                "[shot] long screenshot: the region never held still for two frames in a row, so nothing was joined; \
                 the picture is the first frame taken, {} px tall",
                l.rect.h
            );
        }
    }
    let Some(session) = end(false) else { return };
    let sel = export.selection;
    let Some(mon) = session.mons.get(sel.monitor) else { return };
    let composed = match &long {
        // Stitched frames carry no annotations and need no composing.
        Some(l) => l.stitcher.finish().and_then(|(width, rows)| Composed::from_stitched(width, rows)),
        None => compose(mon, &export),
    };
    let Some(composed) = composed else {
        // process-wide: the overlay is not a terminal window
        plogf!("[shot] the selection {:?} could not be composed; nothing written", sel.rect);
        return;
    };
    let no_items: Vec<Item> = Vec::new();
    let Some(png) = composed.png() else {
        // process-wide: the overlay is not a terminal window
        plogf!("[shot] the image could not be encoded; nothing written");
        return;
    };
    // The bitmap every program reads -- unless it would be past the limit
    // (a tall long screenshot is hundreds of megabytes uncompressed), and
    // then the clipboard carries the PNG alone.
    let dib = composed.clipboard_dib();
    if dib.is_none() {
        // process-wide: the overlay is not a terminal window
        plogf!(
            "[shot] no bitmap on the clipboard: it would be {} bytes, over the {} byte limit; the PNG alone goes on it",
            composed.dib_len(),
            polter_shots::pixels::CLIPBOARD_DIB_LIMIT
        );
    }
    let size = composed.size();
    let items = if long.is_some() { &no_items } else { &export.on_image };
    // A long screenshot is also cut into tiles: the pieces a CLI can read
    // without shrinking them. One tile would be the picture itself.
    let tiles = if long.is_some() { composed.tiles(TILE_HEIGHT, TILE_OVERLAP) } else { Vec::new() };
    let tiles = if tiles.len() > 1 { tiles } else { Vec::new() };
    let source = match sel.window {
        Some(id) => {
            let (app, title, pid) = window_names(id);
            // The window's own bounds as they were frozen, which the
            // selection is the on-monitor part of.
            let window_rect = session.editor.window_rect(id);
            Source::Window { app, title, pid, window_rect, selection_rect: sel.rect }
        }
        None => Source::Region { selection_rect: sel.rect },
    };

    // 1. The clipboard: the bitmap every program reads, and the PNG beside
    //    it for the ones that prefer that.
    let (on_clipboard, seq) = unsafe {
        // Opened in the control window's name: with no owner window,
        // `EmptyClipboard` leaves the clipboard ownerless and the
        // documentation says `SetClipboardData` then fails.
        let control = HWND(CONTROL.load(Ordering::Acquire) as *mut c_void);
        let opened = OpenClipboard(Some(control)).is_ok();
        let mut ok = false;
        if opened {
            let _ = EmptyClipboard();
            let bitmap = dib.as_deref().map(|d| set_clipboard(CF_DIB, d));
            let png_format = RegisterClipboardFormatW(w!("PNG"));
            let png_ok = png_format != 0 && set_clipboard(png_format, &png);
            // With a bitmap, it is the bitmap that has to have gone on;
            // without one, the PNG is all there is.
            ok = bitmap.unwrap_or(png_ok);
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
            plogf!("[shot] done {}x{} but NOT saved: {why}. On the clipboard: {on_clipboard}", size.0, size.1);
            return;
        }
    };
    let taken = taken.get();
    let image_name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    // The tiles beside it: `<name>-1.png`, `-2.png`, ...
    let mut tile_entries = Vec::new();
    let mut tile_paths = Vec::new();
    for (i, (y, height, bytes)) in tiles.iter().enumerate() {
        let name = polter_shots::name::tile(&image_name, i + 1);
        let tile_path = path.with_file_name(&name);
        match std::fs::write(&tile_path, bytes) {
            Ok(()) => {
                tile_entries.push(Tile { image: name, y: *y, height: *height });
                tile_paths.push(tile_path);
            }
            // process-wide: the overlay is not a terminal window
            Err(e) => plogf!("[shot] tile {} NOT written: {e}", tile_path.display()),
        }
    }
    // The pane the shot was triggered from, when Polter was in front: its
    // id when the host can learn it (`terminal_id_of`), its directory, and
    // that directory's git state.
    let cwd = session.origin_pane.and_then(crate::tabs::cwd_of_pane);
    let id = session.origin_pane.and_then(terminal_id_of).unwrap_or_default();
    let terminal = (session.origin_pane.is_some() && (cwd.is_some() || !id.is_empty()))
        .then(|| Terminal { id, git: cwd.as_deref().and_then(git_of), cwd: cwd.clone() });
    let (source_app, source_title) = match &source {
        Source::Window { app, title, .. } => (app.clone(), title.clone()),
        Source::Region { .. } => (None, None),
    };
    let previous =
        path.parent().and_then(|d| previous_in(d, &image_name, source_app.as_deref(), source_title.as_deref()));
    let meta = Meta {
        image: image_name,
        taken,
        utc_offset_minutes: polter_shots::name::utc_offset_minutes(&taken, &utc),
        size,
        scale: export.scale,
        by: By::User,
        display: Some(Display { index: sel.monitor, size: (mon.rect.w as u32, mon.rect.h as u32), scale: export.scale }),
        appearance: Some(appearance()),
        source,
        terminal,
        previous,
        tiles: tile_entries,
        redacted: Vec::new(),
    };
    let json = path.with_extension("json");
    let sidecar_written = std::fs::write(&json, annot::sidecar(&meta, items));
    let words = labels();
    let l = Labels {
        header: &words[0],
        text: &words[1],
        rect: &words[2],
        ellipse: &words[3],
        line: &words[4],
        arrow: &words[5],
        pen: &words[6],
        highlighter: &words[7],
        mosaic: &words[8],
        separator: &words[9],
        see: &words[10],
    };
    // What is pasted: an ordinary shot's own path, or a long one's tiles --
    // at most `MAX_TILES_PASTED` of them, with a line saying so when there
    // are more.
    let pasted_tiles = tile_paths.len().min(MAX_TILES_PASTED);
    let note = if long.is_some() {
        let en = annot::LONG_EN;
        let w = [en.header, en.tiles, en.whole, en.separator, en.see].map(tr);
        let ll = annot::LongLabels { header: &w[0], tiles: &w[1], whole: &w[2], separator: &w[3], see: &w[4] };
        annot::long_line(meta.size, tile_paths.len(), pasted_tiles, &path.to_string_lossy(), &json.to_string_lossy(), &ll)
    } else {
        annot::line(meta.size, items, &json.to_string_lossy(), &l)
    };

    // A paste made later by hand finds this file by the clipboard's sequence
    // number instead of saving the clipboard's bitmap a second time.
    if on_clipboard {
        crate::shots::remember(seq, path.clone(), note.clone());
    }
    // process-wide: the overlay is not a terminal window
    plogf!(
        "[shot] done: {}x{} px at scale {} from {:?}, {} annotation(s) ({} drawn in all), {} tile(s); saved {}; \
         sidecar {}; clipboard={on_clipboard} (sequence {seq})",
        size.0,
        size.1,
        meta.scale,
        sel.rect,
        items.len(),
        session.editor.items().len(),
        meta.tiles.len(),
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
    let surface = crate::tabs::surface_of_pane(pane);
    if surface.is_null() {
        // process-wide: the pane this was for has gone, so there is no window to name
        plogf!("[shot] the pane that had the keyboard (pane={pane}) was closed meanwhile; nothing pasted");
        return;
    }
    // One path for an ordinary shot; for a long one its tiles, each a paste
    // of its own, spaced like the annotation line is from the path.
    let paths: Vec<&std::path::PathBuf> =
        if tile_paths.is_empty() { vec![&path] } else { tile_paths.iter().take(pasted_tiles).collect() };
    let quoted: Vec<String> = paths.iter().map(|p| polter_droppath::quote(&p.to_string_lossy())).collect();
    let text = &quoted[0];
    unsafe { (crate::api().surface_text)(surface, text.as_ptr() as *const _, text.len()) };
    // process-wide: reported by pane id, which is unique in the process
    plogf!(
        "[shot] path pasted into pane={pane}: {text:?}; {} more path(s) to follow, one every \
         {SECOND_PASTE_DELAY_MS} ms; a line of text to follow in {} ms: {}",
        quoted.len() - 1,
        SECOND_PASTE_DELAY_MS * quoted.len() as u64,
        note.is_some()
    );
    for (i, later) in quoted.iter().enumerate().skip(1) {
        paste_later(pane, later.clone(), SECOND_PASTE_DELAY_MS * i as u64, "tile path");
    }
    if let Some(note) = note {
        let what = if long.is_some() { "long-screenshot line" } else { "annotation line" };
        paste_later(pane, note, SECOND_PASTE_DELAY_MS * quoted.len() as u64, what);
    }
}
