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
use std::sync::{mpsc, Arc, Mutex};

use polter_shots::agent;
use polter_shots::annot::{self, By, Display, Item, Labels, Meta, Shape, Source, Terminal, Tile};
use polter_shots::chrome;
use polter_shots::dclick::{Detector, Mods, Setting, Verdict};
use polter_shots::editor::{Cursor, Editor, Effect, Export, Measure, Monitor, Window};
use polter_shots::geom::{self, Point, Rect};
use polter_shots::glass::Glass;
use polter_shots::look;
use polter_shots::motion;
use polter_shots::paint::{Box2, Surface};
use polter_shots::name::Stamp;
use polter_shots::overlay::Key;
use polter_shots::paste::{Later, MAX_TILES_PASTED};
use polter_shots::pixels::{self, Composed, Frozen, TILE_HEIGHT, TILE_OVERLAP};
use polter_shots::stitch::{Step, Stitcher};
use polter_shots::style::{self, Prefs};
use polter_shots::textbox::{self, Typed};
use polter_shots::toolbar;
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
    GetAsyncKeyState, GetKeyState, RegisterHotKey, ReleaseCapture, SetCapture, SetFocus,
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
/// Posted to the control window by a thread that has finished a monitor's
/// frosted glass (`glass_arrived`). `WM_APP + 47`, free when written
/// (`grep 'WM_APP +'`: 35 is `shot_agent::WM_AGENT_DONE`, on this same
/// window, which is why the number is not the next one along).
const WM_SHOT_GLASS: u32 = WM_APP + 47;
/// How long the first frame waits for the frosted glass, in milliseconds.
/// A monitor whose glass is not made by then is shown darkened only, as it
/// is for a system that asks for less transparency, until its glass
/// arrives. The macOS host waits as long: both read the one number in
/// `src/input/screenshot-look.json`.
const GLASS_WAIT_MS: u64 = look::glass::WAIT_MS as u64;

/// `CF_DIB`, numerically, as in `shots.rs`.
const CF_DIB: u32 = 8;


// ---------------------------------------------------------------- state

struct Mon {
    rect: Rect,
    dpi: u32,
    hwnd: HWND,
    /// This monitor as it was when the screenshot began. In memory only, and
    /// gone when the session is. Shared with the thread that blurs it,
    /// which only reads it and may outlive the session by a moment.
    frozen: Arc<Frozen>,
    /// What that picture is seen through outside the selection, and what
    /// the toolbar's plate is made of (`polter_shots::glass`). Blurred once,
    /// on a thread of its own; until that is done -- if it takes longer
    /// than the first frame waits -- the picture only darkened.
    glass: Glass,
    /// What this monitor's overlay window is showing, pixel for pixel: the
    /// last frame composed. The next one is compared with it and the window
    /// is given only where they differ (`paint`).
    shown: Option<Canvas>,
    /// The canvas the frame before that was in, to compose the next into.
    spare: Option<Canvas>,
    /// What is clear on this monitor, over time: the hole, and what was the
    /// hole a moment ago and is still going to glass (`motion::Holes`).
    holes: motion::Holes,
    /// Whether this overlay's `TIMER_MOVING` is set.
    moving: bool,
}

/// The native text box while something is being typed.
struct EditCtl {
    hwnd: HWND,
    font: HFONT,
    /// Where it was last put, in virtual-screen pixels: `fit_edit` moves it
    /// only when this changes, and says so in the log when it does.
    rect: Rect,
    /// What it holds, as last read back from it (`read_edit`), and what an
    /// input method is composing in it. **This is what the overlay draws**:
    /// the control draws nothing (`hide_box`), and painting asks it nothing.
    typed: Typed,
    /// Whether the caret is in the shown half of its blink.
    caret_on: bool,
}

/// One screenshot in progress. What it *does* is `editor`
/// (`polter_shots::editor`); this is the windows around it.
struct Session {
    editor: Editor,
    mons: Vec<Mon>,
    edit: Option<EditCtl>,
    /// The id of the pane that had the keyboard when the shot was triggered,
    /// if Polter was the foreground application -- the sidecar's `terminal`,
    /// and nothing else: the result is not sent there, the person pastes it.
    /// An id rather than a window: ids are never reused, window handles are.
    origin_pane: Option<u64>,
    prev_fg: HWND,
    /// What the tools remembered when the session began, to know whether
    /// there is anything to save when it ends.
    prefs_at_start: Prefs,
    /// A long screenshot being taken.
    long: Option<LongShot>,
    /// The toolbar's icons as drawn so far (`chrome::Icons`).
    icons: chrome::Icons,
    /// When the session was triggered: what "late" is counted from.
    began: std::time::Instant,
    /// Where a monitor's frosted glass arrives when it was not made in
    /// time for the first frame: the monitor's index, the glass, and how
    /// long making it took. **The session's own**: a thread still blurring
    /// when the session ends sends into a channel nobody holds, and what it
    /// made is dropped there -- it has no way to reach a later session, or
    /// anything that has been freed.
    late: mpsc::Receiver<(usize, Option<Glass>, f64)>,
    /// Whether changes take a moment (`motion`). Not, when the system's own
    /// animations are switched off: then every change is one frame.
    animate: bool,
    /// The states the toolbar's cells were last drawn in, and the toolbar
    /// on its way from what it showed then to what it shows now.
    cells: Vec<chrome::State>,
    fade: Option<motion::Crossfade>,
    /// The cell the pointer is resting on and whether it has rested long
    /// enough for its tooltip to show (`tip_follows`).
    tip: (Option<toolbar::Button>, bool),
    /// The colours the overlay's own parts are drawn in: the look's, or the
    /// system's in high-contrast mode (`tones`).
    tones: chrome::Tones,
    /// How many frames were composed, the longest any took and all of them
    /// together in milliseconds, and how many pixels the windows were given:
    /// said once, when the session ends.
    frames: (u32, f64, f64, u64),
    /// Until when the magnifier says the colour was copied (`tick_ms`).
    copied_until: u64,
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
    /// The program turns the wheel (#1197): what to do after each frame.
    auto: polter_shots::autoscroll::AutoScroll,
    /// Where the pointer was before it was put over the region; given
    /// back when the long screenshot ends.
    pointer_before: Option<POINT>,
    /// Where the wheel goes (`autoscroll::wheel_point`).
    wheel_at: Point,
}

/// One progress line for every this many frames of a long screenshot.
const LONG_LOG_EVERY: u32 = 10;

/// The overlay window's timer that takes a frame.
const TIMER_LONG: usize = 2;
/// The overlay window's timer that blinks the text box's caret.
const TIMER_CARET: usize = 3;
/// The overlay window's timer while something is on its way (`motion`): a
/// frame each time it fires. **Set only while something is moving** and
/// killed by the first frame that finds nothing is (`paint`).
const TIMER_MOVING: usize = 5;
/// How often, in milliseconds: about a frame at 60 Hz.
const MOVING_INTERVAL_MS: u32 = 16;
/// The overlay window's timer that shows a tooltip once the pointer has
/// rested on a cell for `look::transition_ms::TIP_DELAY`.
const TIMER_TIP: usize = 4;
/// The overlay window's timer that takes "Copied" off the magnifier.
const TIMER_COPIED: usize = 6;
/// How long it stays, in milliseconds.
const COPIED_MS: u32 = look::transition_ms::COPIED_FLASH as u32;
/// How often, in milliseconds.
const LONG_INTERVAL_MS: u32 = 120;

thread_local! {
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

/// Whether the bundled annotation font was found and loaded.
static FONT_OK: AtomicBool = AtomicBool::new(false);
/// Set by Save: `finish` also puts a copy of the picture in Downloads.
static SAVE_COPY: AtomicBool = AtomicBool::new(false);
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
/// What a paste of a screenshot still owes its pane -- a long one's later
/// tiles, the line of text -- each due a while after the path that answered
/// the paste and each addressed to a pane **by id**. A pane id comes out of one
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
/// **That style is what would let the control draw although its window
/// region is empty** (task 1107, read on the test machine with part of the
/// box cut out: `box draws there=true (class CS_PARENTDC=true)`, and
/// `false` with this class). A window of such a class draws through its
/// parent's clipping, and its own window region is not part of that.
/// Without the style the box's device context is its own window, and a
/// window with nothing in its region cannot put a pixel anywhere by any
/// road -- `WM_PAINT`, a key, the caret. The overlay draws the text
/// instead (`draw_text_box`), over the picture and under the toolbar.
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
        let toast = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(toast_proc),
            hInstance: hinst.into(),
            lpszClassName: w!("PolterShotToast"),
            ..Default::default()
        };
        // absence: means it was not reached -- all three classes registered
        if RegisterClassExW(&wc) == 0 || RegisterClassExW(&overlay) == 0 || RegisterClassExW(&toast) == 0 {
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
    begin();
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

/// Whether the click that is the mouse trigger is kept from the application
/// under the pointer -- the press and its release both, or neither.
///
/// **The one place this is decided.** Eaten, the trigger's modifiers and a
/// click are no longer that application's gesture for as long as Polter
/// runs (extending a selection, a link into a new tab); passed on, the
/// application acts on a click that was meant for the screenshot. The
/// specification (§3.1) has it eaten.
const EAT_TRIGGER_CLICK: bool = true;

thread_local! {
    /// The hook thread's memory of whether the next release is the
    /// trigger's. Only that thread touches it.
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
                let down = Mods {
                    ctrl: held(VK_CONTROL.0),
                    shift: held(VK_SHIFT.0),
                    alt: held(VK_MENU.0),
                    win: held(VK_LWIN.0) || held(VK_RWIN.0),
                };
                let v = DETECTOR.with(|d| d.borrow_mut().press(down, trigger));
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
            if verdict != Verdict::Pass && EAT_TRIGGER_CLICK {
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
            begin();
            LRESULT(0)
        }
        WM_SHOT_MOUSE => {
            let at = Point::new(wp.0 as u32 as i32, lp.0 as i32);
            let mods = bits_mods((wp.0 >> 32) as u8);
            // Where it happened is for this line only: the session opens as
            // the hotkey opens it, with nothing selected.
            // process-wide: the mouse trigger fires whatever is under the pointer
            plogf!("[shot] {} click at ({},{})", mods.label(), at.x, at.y);
            begin();
            LRESULT(0)
        }
        WM_TIMER if wp.0 == TIMER_NOTES => {
            paste_notes();
            LRESULT(0)
        }
        WM_SHOT_GLASS => {
            glass_arrived();
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

/// Queue `text` to be pasted into pane `pane`, `delay_ms` from now: one of
/// the pastes that follow a screenshot's path, kept apart from it and from
/// each other so the program in the terminal reads them apart. A long
/// screenshot's tiles go in one after another this way.
///
/// Called from the clipboard callback, when a paste made by hand reuses a
/// screenshot (`shots::image_text`) -- and from nowhere else: finishing a
/// screenshot pastes nothing.
///
/// `what` is what the text is, for the log: a line that says "annotation
/// line pasted" about a tile's path sends whoever reads it looking for an
/// annotation.
pub fn paste_later(pane: u64, text: String, delay_ms: u64, what: &'static str) {
    let now = tick_ms();
    NOTES.lock().unwrap_or_else(|e| e.into_inner()).push(now, delay_ms, (pane, what), text);
    arm_notes_timer(now);
}

/// Drop what is still waiting to be pasted into pane `pane`, and say how
/// many pieces that was. For a paste into a pane whose last paste has not
/// finished arriving.
pub fn forget_pastes(pane: u64) -> usize {
    let dropped = NOTES.lock().unwrap_or_else(|e| e.into_inner()).forget(|(p, _)| *p == pane);
    arm_notes_timer(tick_ms());
    dropped
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
/// Nothing is selected, whatever the trigger was.
fn begin() {
    SAVE_COPY.store(false, Ordering::Release);
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

        let began = std::time::Instant::now();
        let screen = GetDC(None);
        let frosted = !less_transparency() && !crate::theme::high_contrast();
        let (made, late) = mpsc::channel::<(usize, Option<Glass>, f64)>();
        let control = CONTROL.load(Ordering::Acquire);
        let mut taken: Vec<(Rect, u32, Arc<Frozen>)> = Vec::new();
        for (rect, dpi) in found {
            let Some(frozen) = grab(screen, rect) else {
                // process-wide: about a monitor, not about a terminal window
                plogf!("[shot] monitor {:?} could not be captured (err={}); left out", rect, GetLastError().0);
                continue;
            };
            let frozen = Arc::new(frozen);
            if frosted {
                // The one blur of the session, on a thread of its own: the
                // overlay does not wait for it past `GLASS_WAIT_MS`. The
                // thread reads the frozen picture and sends what it made;
                // it touches no window and no canvas.
                let (index, scale, picture, made) = (taken.len(), f64::from(dpi.max(96)) / 96.0, frozen.clone(), made.clone());
                let spawned = std::thread::Builder::new().name("polter-shot-glass".into()).spawn(move || {
                    crate::name_this_thread("polter-shot-glass");
                    let began = std::time::Instant::now();
                    let glass = picture.glass(scale, true);
                    // Nobody listening is a session that has ended: fine.
                    let _ = made.send((index, glass, began.elapsed().as_secs_f64() * 1e3));
                    let _ = PostMessageW(Some(HWND(control as *mut c_void)), WM_SHOT_GLASS, WPARAM(0), LPARAM(0));
                });
                if let Err(e) = spawned {
                    // process-wide: about a monitor, not about a terminal window
                    plogf!("[shot] no thread to frost monitor {:?} ({e}); it is darkened only", rect);
                }
            }
            taken.push((rect, dpi, frozen));
        }
        drop(made);
        // The first frame waits this long for the glass and no longer.
        let mut frosted_glass: Vec<Option<(Glass, f64)>> = taken.iter().map(|_| None).collect();
        let deadline = began + std::time::Duration::from_millis(GLASS_WAIT_MS);
        while frosted && frosted_glass.iter().any(|g| g.is_none()) {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            match late.recv_timeout(left) {
                Ok((index, Some(glass), took)) if index < frosted_glass.len() => frosted_glass[index] = Some((glass, took)),
                Ok(_) => {}
                // Out of time, or every thread has ended.
                Err(_) => break,
            }
        }
        let in_time = frosted_glass.iter().filter(|g| g.is_some()).count();
        let mut mons = Vec::new();
        for ((rect, dpi, frozen), arrived) in taken.into_iter().zip(frosted_glass) {
            let scale = f64::from(dpi.max(96)) / 96.0;
            let glass = match arrived {
                Some((glass, took)) => {
                    log_glass(rect, scale, took, true);
                    Some(glass)
                }
                // Darkened only: for good when that is what was asked for,
                // until the frosted one arrives when it is late.
                None => frozen.glass(scale, false),
            };
            let Some(glass) = glass else {
                // process-wide: about a monitor, not about a terminal window
                plogf!("[shot] monitor {:?} has no glass (its picture is not its size); left out", rect);
                continue;
            };
            mons.push(Mon { rect, dpi, hwnd: HWND::default(), frozen, glass, shown: None, spare: None, holes: motion::Holes::new(), moving: false });
        }
        // process-wide: one session at a time for the whole process
        plogf!(
            "[shot] glass: {in_time} of {} monitor(s) frosted in time for the first frame (waited {:.1} ms of the {GLASS_WAIT_MS} ms it \
             may; frosting wanted={frosted}); the others are darkened only until theirs arrives",
            mons.len(),
            began.elapsed().as_secs_f64() * 1e3
        );
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
        let editor = Editor::new(monitors, wins, prefs.clone());
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
                Some(Session {
                    editor,
                    mons,
                    edit: None,
                    origin_pane,
                    prev_fg,
                    prefs_at_start: prefs,
                    long: None,
                    icons: chrome::Icons::new(),
                    began,
                    late,
                    animate: animations_on(),
                    cells: Vec::new(),
                    fade: None,
                    tip: (None, false),
                    tones: tones(),
                    frames: (0, 0.0, 0.0, 0),
                    copied_until: 0,
                })
        });
        // Where the pointer is, before the first frame: the window under it
        // is the clear one from the start, not from the first mouse move.
        let mut at = POINT::default();
        if GetCursorPos(&mut at).is_ok() {
            with(|s| s.editor.pointer_move(Point::new(at.x, at.y), Mods::NONE));
        }

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
    let (frames, slowest, all, given) = session.frames;
    let whole: u64 = session.mons.iter().map(|m| m.rect.w as u64 * m.rect.h as u64).sum();
    // process-wide: one session at a time for the whole process
    plogf!(
        "[shot] frames: {frames} composed in {:.1} s, the slowest in {slowest:.1} ms, {:.1} ms each on average; the windows \
         were given {given} px in all, {:.2} monitors' worth (all monitors are {whole} px)",
        session.began.elapsed().as_secs_f64(),
        if frames > 0 { all / f64::from(frames) } else { 0.0 },
        if whole > 0 { given as f64 / whole as f64 } else { 0.0 }
    );
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


const INK: COLORREF = COLORREF(0x00FF_FFFF);

/// Whether the system asks for less transparency (Settings >
/// Personalisation > Colours > Transparency effects, off): then nothing is
/// blurred, the plates are opaque and nothing glows (§9.8.10).
fn less_transparency() -> bool {
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let mut value = 1u32;
    let mut len = std::mem::size_of::<u32>() as u32;
    let read = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("EnableTransparency"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut value as *mut u32 as *mut c_void),
            Some(&mut len),
        )
    };
    read.is_ok() && value == 0
}

/// The colours the overlay's own parts are drawn in. The look's, unless the
/// system is in high-contrast mode: then the system's own, which the person
/// chose in order to see -- button face and text for the plates and what is
/// on them, the highlight for what is chosen, grey text for what cannot be
/// pressed (`theme.rs` has the same rule for the rest of the host).
fn tones() -> chrome::Tones {
    if !crate::theme::high_contrast() {
        return chrome::Tones::LOOK;
    }
    let sys = |index: SYS_COLOR_INDEX| {
        let c = unsafe { GetSysColor(index) };
        look::Rgba { r: (c & 0xFF) as u8, g: ((c >> 8) & 0xFF) as u8, b: ((c >> 16) & 0xFF) as u8, a: 1.0 }
    };
    chrome::Tones {
        ink: sys(COLOR_BTNTEXT),
        ink_dim: sys(COLOR_BTNTEXT),
        ink_off: sys(COLOR_GRAYTEXT),
        accent: sys(COLOR_HIGHLIGHT),
        on_accent: sys(COLOR_HIGHLIGHTTEXT),
        plate: sys(COLOR_BTNFACE),
        plate_edge: sys(COLOR_BTNTEXT),
    }
}

/// Whether the system animates what is inside windows (Settings >
/// Accessibility > Visual effects > Animation effects). Off, and nothing
/// here takes a moment either (§9.8.7).
fn animations_on() -> bool {
    let mut on = windows::core::BOOL(1);
    let asked = unsafe {
        SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, Some(&mut on as *mut _ as *mut c_void), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0))
    };
    asked.is_err() || on.as_bool()
}

fn log_glass(rect: Rect, scale: f64, took: f64, in_time: bool) {
    // process-wide: about a monitor, not about a terminal window
    plogf!(
        "[shot] glass for monitor {}x{} at scale {scale}: made in {took:.1} ms on a thread of its own ({} thread(s) for the \
         stretch); in time for the first frame={in_time} (shrunk {}x, box radius {})",
        rect.w,
        rect.h,
        polter_shots::glass::threads(),
        polter_shots::glass::factor(scale),
        polter_shots::glass::radius(look::glass::OUTSIDE_BLUR_SIGMA, scale)
    );
}

/// A monitor's frosted glass was made after the first frame had to be
/// shown: it takes the place of the darkened picture, and the overlay is
/// painted again. Nothing here if the session it was made for has ended --
/// what the thread sent went into that session's channel and was dropped
/// with it.
fn glass_arrived() {
    let arrived = with(|s| {
        let mut n = 0;
        while let Ok((index, glass, took)) = s.late.try_recv() {
            let (Some(glass), Some(mon)) = (glass, s.mons.get_mut(index)) else { continue };
            log_glass(mon.rect, f64::from(mon.dpi.max(96)) / 96.0, took, false);
            // process-wide: about a monitor, not about a terminal window
            plogf!(
                "[shot] glass for monitor {index} arrived {:.1} ms after the trigger, {:.1} ms after the first frame stopped \
                 waiting; the monitor is frosted from the next frame",
                s.began.elapsed().as_secs_f64() * 1e3,
                (s.began.elapsed().as_secs_f64() * 1e3 - GLASS_WAIT_MS as f64).max(0.0)
            );
            mon.glass = glass;
            n += 1;
        }
        n
    })
    .unwrap_or(0);
    if arrived > 0 {
        repaint();
    }
}

fn ink_ref(c: look::Rgba) -> COLORREF {
    rgb_ref((c.r, c.g, c.b))
}

/// The overlay's own words -- the selection's size, a tooltip, the long
/// screenshot's status -- in the system's menu font at the monitor's DPI,
/// which is the smallest any text of ours may be (`uifont`).
struct Words {
    dc: HDC,
    font: HFONT,
    saved: i32,
    origin: Point,
}

impl Words {
    unsafe fn on(canvas: &Canvas, dpi: u32) -> Words {
        unsafe {
            let saved = SaveDC(canvas.dc);
            // 12 px is the menu's own size on an unchanged system; the
            // font made is the menu's or that, whichever is larger.
            let font = crate::uifont::make(dpi as i32, 12, 400, w!("Segoe UI"));
            SelectObject(canvas.dc, font.into());
            SetBkMode(canvas.dc, TRANSPARENT);
            Words { dc: canvas.dc, font, saved, origin: canvas.rect.origin() }
        }
    }

    fn size(&self, text: &str) -> (i32, i32) {
        let mut size = SIZE::default();
        let _ = unsafe { GetTextExtentPoint32W(self.dc, &wide(text), &mut size) };
        (size.cx, size.cy)
    }

    /// `text` with its top-left corner at `at` (virtual-screen pixels).
    fn put(&self, at: Point, text: &str, colour: look::Rgba) {
        let l = at.relative_to(self.origin);
        unsafe {
            SetTextColor(self.dc, ink_ref(colour));
            let _ = TextOutW(self.dc, l.x, l.y, &wide(text));
        }
    }
}

impl Drop for Words {
    fn drop(&mut self) {
        unsafe {
            let _ = RestoreDC(self.dc, self.saved);
            let _ = DeleteObject(self.font.into());
        }
    }
}

/// Everything monitor `i`'s overlay shows, drawn into `canvas`, which is the
/// size of the monitor. Every pixel of it is written.
///
/// **Nothing is blurred here.** The glass was made when the session began;
/// a frame is that glass, the frozen picture where the hole is, and what is
/// drawn over them (§9.8.8). The hole and the selection's outline are the
/// same rectangle read from the same `Editor` in the same call, so there is
/// no frame in which one has moved and the other has not.
unsafe fn compose_overlay(s: &mut Session, i: usize, canvas: &Canvas, now: f64) {
    // What is clear, and what was and is still going (`motion::Holes`).
    let chosen = s.editor.selection().is_some_and(|x| x.monitor == i) || s.editor.forming().is_some_and(|f| f.1 == i);
    let (hole, rect, animate) = (s.editor.hole(i), s.mons[i].rect, s.animate);
    s.mons[i].holes.step(hole, chosen, rect, now, animate);
    let clear = s.mons[i].holes.layers(now);
    // The icons are drawn once and kept; taken out while `s` is read.
    let mut icons = std::mem::take(&mut s.icons);
    unsafe { compose_into(s, i, canvas, &clear, &mut icons) };
    s.icons = icons;
}

unsafe fn compose_into(s: &Session, i: usize, canvas: &Canvas, clear: &[(Rect, u32)], icons: &mut chrome::Icons) {
    unsafe {
        let mon = &s.mons[i];
        let e = &s.editor;
        let scale = f64::from(mon.dpi.max(96)) / 96.0;
        let glass = &mon.glass;
        let tones = &s.tones;
        // Whether anything glows: only on frosted glass.
        let frosted = glass.is_frosted();

        // What is in focus on this monitor: the selection, the region
        // being dragged, or the window under the cursor. The rest is glass.
        let sel = e.selection().filter(|x| x.monitor == i).map(|x| x.rect);
        let forming = e.forming().filter(|f| f.1 == i).map(|f| f.0);
        mon.frozen.frame_layers(glass, canvas.bits(), mon.rect, clear, mon.rect);

        // The mosaics are in the picture -- including the one being dragged
        // out, so its size is chosen by what it hides.
        pixels::apply_mosaics(canvas.bits(), mon.rect, &mon.frozen, e.items(), scale);
        if let Some(live) = e.live() {
            pixels::apply_mosaics(canvas.bits(), mon.rect, &mon.frozen, std::slice::from_ref(live), scale);
        }

        let hide = e.text_box().and_then(|t| t.editing);
        let mosaic = |it: &Item| matches!(it.shape, Shape::Mosaic(_));
        // A number being given its sentence is drawn as it will be closed.
        let edited = e.number_in_edit();
        let order = e.draw_order();
        let shown: Vec<(usize, &Item)> = order
            .into_iter()
            .map(|(i, it)| match &edited {
                Some((n, copy)) if *n == i => (i, copy),
                _ => (i, it),
            })
            .collect();
        let drawn = shown.into_iter().filter(|(_, it)| !mosaic(it));
        let live = e.live().filter(|it| !mosaic(it)).map(|it| (usize::MAX, it));
        draw_items(canvas, drawn.chain(live), scale, hide);
        // What reaches out of the selection will not be in the picture: it
        // is drawn whole and then made fainter out there (§9.8.11A.5).
        if let Some(sel) = sel {
            for item in e.items().iter().chain(e.live()) {
                let b = item.bounds(scale);
                let b = Rect::new(b.x - 2, b.y - 2, b.w + 4, b.h + 4);
                if b.intersect(sel) != Some(b) {
                    glass.veil(canvas.bits(), mon.rect, sel, b, look::annotation::OUTSIDE_OPACITY);
                }
            }
        }
        // What is being typed: over the annotations, under everything
        // of the overlay's own -- the toolbar is drawn after it.
        draw_text_box(s, i, canvas);

        let surface = || Surface::new(canvas.bits(), mon.rect);
        if let Some(mut on) = surface() {
            match (sel, forming) {
                (Some(sel), _) => {
                    chrome::selection(&mut on, sel, e.knobs(), scale, tones);
                    // The selected annotation: over every annotation, under
                    // the toolbar.
                    if let Some(marked) = e.marked() {
                        if marked.framed {
                            chrome::annotation_frame(&mut on, marked.ink, scale, frosted, tones);
                        }
                        for (at, how) in marked.grips {
                            chrome::grip(&mut on, at, how, scale, frosted, tones);
                        }
                    }
                }
                (None, Some(forming)) => chrome::selection(&mut on, forming, false, scale, tones),
                (None, None) => {
                    // The window that a click would take. Not the whole
                    // monitor: that is "no window", and has no outline.
                    if let Some((_, window)) = e.hover().filter(|h| h.0 == i && h.1 != mon.rect) {
                        chrome::window_outline(&mut on, window, scale, tones);
                    }
                }
            }
        }

        let words = Words::on(canvas, mon.dpi);
        let plate = |r: Rect| {
            if let Some(mut on) = surface() {
                chrome::label(&mut on, glass, r, scale, tones);
            }
        };
        // Its size, in pixels of the image.
        if let Some(r) = sel.or(forming) {
            let text = format!("{} × {}", r.w, r.h);
            let tag = chrome::size_label(r, words.size(&text), scale, mon.rect);
            plate(tag.plate);
            words.put(tag.text, &text, tones.ink);
        }
        if let (Some(sel), Some(layout)) = (sel, e.layout()) {
            if let Some(mut on) = surface() {
                chrome::toolbar(&mut on, glass, &layout, &e.cells(), e.props(), scale, icons, tones);
            }
            // The lines of words beside the toolbar, one after another.
            let whole = layout.plate();
            let between = style::px_f(look::size::TIP_OFFSET, scale);
            let mut before = 0;
            if let Some(long) = &s.long {
                before += draw_long_status(canvas, &words, glass, tones, long, whole, sel, scale, mon.rect) + between;
            }
            if !font_ok() {
                let text = tr(toolbar::FONT_MISSING);
                let tag = chrome::line(whole, before, words.size(&text), scale, mon.rect);
                plate(tag.plate);
                words.put(tag.text, &text, tones.ink);
                before += tag.plate.h + between;
            }
            // A tooltip, once the pointer has rested on the cell (`tip_follows`).
            let rested = e.hover_button().filter(|b| s.tip == (Some(*b), true));
            if let Some((button, cell)) = rested.and_then(|b| layout.rect_of(b).map(|r| (b, r))) {
                let name = tr(toolbar::name(button, e.props()));
                let key = toolbar::shortcut(button);
                let tip = chrome::tooltip(cell, whole, before, words.size(&name), key.as_deref().map(|k| words.size(k)), scale, mon.rect);
                plate(tip.plate);
                words.put(tip.name, &name, tones.ink);
                if let (Some((key_plate, at)), Some(key)) = (tip.key, &key) {
                    if let Some(mut on) = surface() {
                        chrome::key_plate(&mut on, key_plate, scale, tones);
                    }
                    words.put(at, key, tones.ink_dim);
                }
            }
        }
        // What a shape being reshaped measures, beside the pointer.
        if let (Some(text), Some(at)) = (e.reshape_tag(), e.pointer().filter(|p| mon.rect.contains(*p))) {
            let tag = chrome::pointer_tag(at, words.size(&text), scale, mon.rect);
            plate(tag.plate);
            words.put(tag.text, &text, tones.ink);
        }
        // The magnifier: last, over everything but the pointer.
        if let Some(at) = e.magnifier().filter(|p| mon.rect.contains(*p)) {
            let params = &polter_shots::magnifier::LOOK;
            let coords = polter_shots::magnifier::coordinates(at, mon.rect);
            let colour = mon.frozen.rgb_at(at);
            let code = colour.map(polter_shots::magnifier::hex).unwrap_or_default();
            let said = if s.copied_until > tick_ms() { format!("{code}  {}", tr(toolbar::COPIED)) } else { code };
            let (c, h) = (words.size(&coords), words.size(&said));
            let swatch = style::px_f(params.swatch, scale);
            let between = style::px_f(params.gap, scale);
            let second = swatch + between + h.0;
            let line_h = h.1.max(swatch);
            let text = (c.0.max(second), c.1 + between + line_h);
            let size = polter_shots::magnifier::plate_size(params, text, scale);
            let offset = style::px_f(params.offset, scale);
            let plate_rect = polter_shots::magnifier::place(at, size, mon.rect, offset);
            plate(plate_rect);
            let picture = polter_shots::magnifier::picture_at(plate_rect, params, scale);
            let samples = polter_shots::magnifier::sample(&mon.frozen, at, params.cells);
            polter_shots::magnifier::draw_picture(canvas.bits(), mon.rect, picture, &samples, params, scale);
            let top = picture.bottom() + style::px_f(params.gap, scale);
            let left = plate_rect.x + (plate_rect.w - text.0) / 2;
            words.put(Point::new(left, top), &coords, tones.ink);
            let line = top + c.1 + between;
            if let Some(rgb) = colour {
                pixels::blend(canvas.bits(), mon.rect, Rect::new(left, line + (line_h - swatch) / 2, swatch, swatch), rgb, 256);
            }
            words.put(Point::new(left + swatch + between, line + (line_h - h.1) / 2), &said, tones.ink);
        }
    }
}

/// How many rows of a frame are compared at a time: a change is given to
/// the window as one rectangle for each band of this many rows it touches.
const BAND: usize = 64;

/// Compose monitor `hwnd`'s frame and give the window what differs from the
/// frame it is showing.
///
/// **The whole frame is composed, in memory, and only what changed in it is
/// sent to the screen** (`pixels::changed`): moving a selection sends the
/// strip it left and the strip it took, a tooltip its own rectangle, the
/// caret its few pixels. Sending is the part that is slow where there is no
/// graphics card -- the test machine is such a one -- and what is not sent
/// cannot be late. Nothing has to say what it changed; a change nobody
/// thought of is found by the comparison like any other.
unsafe fn paint(hwnd: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        with(|s| {
            let Some(i) = s.mons.iter().position(|m| m.hwnd == hwnd) else { return };
            let rect = s.mons[i].rect;
            let Some(canvas) = s.mons[i].spare.take().or_else(|| Canvas::new(hdc, rect)) else { return };
            let began = std::time::Instant::now();
            let now = s.began.elapsed().as_secs_f64() * 1e3;
            compose_overlay(s, i, &canvas, now);
            // The toolbar, when a cell's state changed, goes from what it
            // showed to what it shows over the time the look gives -- a
            // press at once (`motion::cells_change`).
            if s.editor.selection().is_some_and(|x| x.monitor == i) {
                let states: Vec<chrome::State> = s.editor.cells().iter().map(|c| c.state).collect();
                if let Some(ms) = motion::cells_change(&s.cells, &states) {
                    let plate = s.editor.layout().map(|l| l.plate());
                    s.fade = match (&s.mons[i].shown, plate) {
                        (Some(shown), Some(plate)) if ms > 0.0 && s.animate && !s.cells.is_empty() => {
                            motion::Crossfade::new(shown.bits(), rect, plate, now, ms)
                        }
                        _ => None,
                    };
                    s.cells = states;
                }
                if s.fade.as_ref().is_some_and(|f| f.done(now)) {
                    s.fade = None;
                }
                if let Some(fade) = &s.fade {
                    fade.apply(canvas.bits(), rect, now);
                }
            }
            // A frame for as long as something is on its way, and not one
            // more: the timer is killed by the frame that finds nothing is.
            let busy = s.mons[i].holes.busy(now) || s.fade.is_some();
            if busy != s.mons[i].moving {
                s.mons[i].moving = busy;
                if busy {
                    SetTimer(Some(hwnd), TIMER_MOVING, MOVING_INTERVAL_MS, None);
                } else {
                    let _ = KillTimer(Some(hwnd), TIMER_MOVING);
                }
            }
            let whole = Rect::new(0, 0, rect.w, rect.h);
            let first = s.mons[i].shown.is_none();
            let changed = match &s.mons[i].shown {
                Some(shown) => pixels::changed(shown.bits(), canvas.bits(), rect.w as usize, rect.h as usize, BAND),
                None => vec![whole],
            };
            let took = began.elapsed().as_secs_f64() * 1e3;
            // Not the paint's own device context: that one is clipped to
            // what was declared invalid, which is nothing (`repaint`).
            let direct = GetDC(Some(hwnd));
            for r in &changed {
                let _ = BitBlt(direct, r.x, r.y, r.w, r.h, Some(canvas.dc), r.x, r.y, SRCCOPY);
            }
            ReleaseDC(Some(hwnd), direct);
            // And whatever the system itself wants painted again.
            let _ = BitBlt(hdc, 0, 0, rect.w, rect.h, Some(canvas.dc), 0, 0, SRCCOPY);
            let given: u64 = changed.iter().map(|r| r.w as u64 * r.h as u64).sum();
            s.frames = (s.frames.0 + 1, s.frames.1.max(took), s.frames.2 + took, s.frames.3 + given);
            // absence: depends -- one line for each monitor's first frame;
            // a session whose overlay was never painted has none
            if first {
                // process-wide: about a monitor, not about a terminal window
                plogf!(
                    "[shot] first frame of monitor {i}: composed in {took:.1} ms, {given} px given to the window; on the screen \
                     {:.1} ms after the trigger (frosted={})",
                    s.began.elapsed().as_secs_f64() * 1e3,
                    s.mons[i].glass.is_frosted()
                );
            }
            s.mons[i].spare = s.mons[i].shown.replace(canvas);
        });
        let _ = EndPaint(hwnd, &ps);
    }
}

/// Draw the text box of monitor `i` into `canvas`: the dashed frame, what
/// is selected, the words with their halo, what an input method is
/// composing, and the caret. **From `EditCtl::typed` alone** -- the native
/// control is asked nothing here, so painting cannot be the cause of a
/// message to it, and so not of another painting (`textbox::changes_box`).
///
/// The words are drawn the way a finished text annotation is (`draw_items`:
/// `DrawTextW` in the annotation font from the box's corner), so what is
/// typed is where it will be. Nothing is drawn under them: the box has no
/// paper (§9.8).
unsafe fn draw_text_box(s: &Session, i: usize, canvas: &Canvas) {
    let (Some(e), Some(tb)) = (s.edit.as_ref(), s.editor.text_box()) else { return };
    if s.editor.selection().map(|x| x.monitor) != Some(i) {
        return;
    }
    let scale = s.editor.scale();
    let b = e.rect;
    let font_px = style::font_px(tb.level, scale);
    let line = s.editor.text_line(tb.level, &Gdi);
    let v = textbox::view(&e.typed, b.w, line, font_px, scale, &Gdi);
    let rgb = style::COLOURS[tb.colour as usize % style::COLOURS.len()];
    let at = |r: Rect| Rect::new(r.x + b.x, r.y + b.y, r.w, r.h);

    textbox::draw_frame(canvas.bits(), canvas.rect, b, scale);
    for r in &v.selected {
        if let Some(r) = at(*r).intersect(b) {
            pixels::blend(canvas.bits(), canvas.rect, r, SELECTED, (polter_shots::look::text_box::SELECTION_ALPHA * 256.0).round() as u32);
        }
    }
    let underline = v.underline.and_then(|u| at(u).intersect(b));
    unsafe {
        let font = annot_font(font_px);
        // The words into `dc`, whose top-left pixel is `origin` of the
        // virtual screen, clipped to the box.
        let words = |dc: HDC, origin: Point, colour: COLORREF| {
            let saved = SaveDC(dc);
            let l = b.relative_to(origin);
            IntersectClipRect(dc, l.x, l.y, l.right(), l.bottom());
            SelectObject(dc, font.into());
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, colour);
            let q = Point::new(b.x + v.origin.x, b.y + v.origin.y).relative_to(origin);
            let mut rc = RECT { left: q.x, top: q.y, right: q.x + 1, bottom: q.y + 1 };
            DrawTextW(dc, &mut wide(&v.text), &mut rc, DT_NOPREFIX | DT_NOCLIP);
            let _ = RestoreDC(dc, saved);
        };
        // The halo first, from how much of each pixel the words cover:
        // white on black in a sheet of their own, the underline with them.
        let reach = textbox::halo_reach(scale);
        let mask_rect = Rect::new(b.x - reach, b.y - reach, b.w + 2 * reach, b.h + 2 * reach);
        if let Some(sheet) = Canvas::new(canvas.dc, mask_rect) {
            words(sheet.dc, mask_rect.origin(), INK);
            if let Some(u) = underline {
                fill(sheet.dc, u.relative_to(mask_rect.origin()), INK);
            }
            let mask: Vec<u8> =
                sheet.bits().chunks_exact(4).map(|p| ((p[0] as u32 + p[1] as u32 + p[2] as u32) / 3) as u8).collect();
            textbox::halo(canvas.bits(), canvas.rect, &mask, mask_rect, textbox::inverse(rgb), scale);
        }
        words(canvas.dc, canvas.rect.origin(), rgb_ref(rgb));
        let _ = DeleteObject(font.into());
    }
    if let Some(u) = underline {
        pixels::blend(canvas.bits(), canvas.rect, u, rgb, 256);
    }
    if e.caret_on {
        textbox::draw_caret(canvas.bits(), canvas.rect, at(v.caret), b, rgb, scale);
    }
}

/// What is selected in the text box is shown by the accent colour laid
/// under it, as much of it as the look says (35%, the same on both hosts).
const SELECTED: (u8, u8, u8) = (polter_shots::look::colour::ACCENT.r, polter_shots::look::colour::ACCENT.g, polter_shots::look::colour::ACCENT.b);

fn repaint() {
    let windows: Vec<HWND> = with(|s| s.mons.iter().map(|m| m.hwnd).collect()).unwrap_or_default();
    // Asked to paint with nothing declared invalid: `paint` finds what to
    // give the window by comparing frames, and a window declared invalid is
    // a whole window sent. Not "one pixel is invalid" either -- while a long
    // screenshot is taken the overlay has a hole in it, and a pixel in the
    // hole is no part of the window, so declaring it invalid asks for
    // nothing at all.
    for h in windows {
        if !h.0.is_null() {
            let _ = unsafe { RedrawWindow(Some(h), None, None, RDW_INTERNALPAINT) };
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
        Effect::CopyColour => copy_colour(hwnd),
        Effect::Save => {
            SAVE_COPY.store(true, Ordering::Release);
            finish();
        }
    }
}

unsafe extern "system" fn overlay_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    // A press in the text box is the box's: where the caret goes, what is
    // selected. The control has no window to press (`hide_box`), so the
    // press is handed to it, in its own coordinates; it takes the mouse
    // until the button is up, as it would have.
    if matches!(msg, WM_LBUTTONDOWN | WM_LBUTTONDBLCLK) {
        if let Some((edit, l)) = point_of(hwnd, lp).and_then(box_at) {
            let at = ((l.y as u16 as isize) << 16) | (l.x as u16 as isize);
            unsafe { SendMessageW(edit, msg, Some(wp), Some(LPARAM(at))) };
            return LRESULT(0);
        }
    }
    if msg == WM_SETCURSOR {
        let mut at = POINT::default();
        if unsafe { GetCursorPos(&mut at) }.is_ok() {
            let p = Point::new(at.x, at.y);
            let shape = if box_at(p).is_some() {
                IDC_IBEAM
            } else {
                // What the pointer is over says what a press there would do
                // (§9.8.11A.4).
                match with(|s| s.editor.cursor(p, key_mods())).unwrap_or(Cursor::Tool) {
                    Cursor::Tool => IDC_CROSS,
                    Cursor::Arrow => IDC_ARROW,
                    Cursor::Move => IDC_SIZEALL,
                    Cursor::UpDown => IDC_SIZENS,
                    Cursor::LeftRight => IDC_SIZEWE,
                    Cursor::Diagonal => IDC_SIZENWSE,
                    Cursor::AntiDiagonal => IDC_SIZENESW,
                }
            };
            unsafe { SetCursor(LoadCursorW(None, shape).ok()) };
            return LRESULT(1);
        }
    }
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
        WM_TIMER if wp.0 == TIMER_MOVING => {
            let _ = unsafe { RedrawWindow(Some(hwnd), None, None, RDW_INTERNALPAINT) };
            return LRESULT(0);
        }
        WM_TIMER if wp.0 == TIMER_COPIED => {
            let _ = unsafe { KillTimer(Some(hwnd), TIMER_COPIED) };
            repaint();
            return LRESULT(0);
        }
        WM_TIMER if wp.0 == TIMER_TIP => {
            let _ = unsafe { KillTimer(Some(hwnd), TIMER_TIP) };
            with(|s| s.tip.1 = s.tip.0.is_some() && s.tip.0 == s.editor.hover_button());
            repaint();
            return LRESULT(0);
        }
        WM_TIMER if wp.0 == TIMER_CARET => {
            with(|s| {
                if let Some(e) = &mut s.edit {
                    e.caret_on = !e.caret_on;
                }
            });
            repaint_text_box();
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
        _ => return unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    };
    perform(hwnd, effect.unwrap_or(Effect::None));
    tip_follows(hwnd);
    LRESULT(0)
}

/// Keep the tooltip to the cell the pointer is on: a tooltip shows half a
/// second after the pointer came to rest on a cell and goes the moment it
/// leaves (§9.8.4.0). Called after every event the overlay handled; does
/// nothing unless the cell under the pointer changed.
fn tip_follows(hwnd: HWND) {
    let Some(now) = with(|s| {
        let over = s.editor.hover_button();
        (over != s.tip.0).then(|| {
            let shown = s.tip.1;
            s.tip = (over, false);
            (over, shown)
        })
    })
    .flatten() else {
        return;
    };
    unsafe {
        // Killing one that is not set fails, and that is fine.
        let _ = KillTimer(Some(hwnd), TIMER_TIP);
        if now.0.is_some() {
            SetTimer(Some(hwnd), TIMER_TIP, look::transition_ms::TIP_DELAY as u32, None);
        }
    }
    // The one that was showing goes now.
    if now.1 {
        repaint();
    }
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
        let bar = s.editor.layout().map(|l| l.plate());
        Some((m.hwnd, m.rect, sel.rect, bar, s.mons.iter().map(|m| m.hwnd).collect::<Vec<_>>()))
    })
    .flatten() else {
        return;
    };
    let Some(stitcher) = Stitcher::new(sel.w as usize, sel.h as usize) else { return };
    // The wheel goes to the window under the pointer: the middle of the
    // region, off the toolbar if that lies over it.
    let wheel_at = polter_shots::autoscroll::wheel_point(sel, bar);
    let mut before = POINT::default();
    let pointer_before = unsafe { GetCursorPos(&mut before) }.is_ok().then_some(before);
    with(|s| {
        s.long = Some(LongShot {
            stitcher,
            hwnd,
            rect: sel,
            last: Step::Unchanged,
            frames: 0,
            lost: 0,
            moving: 0,
            auto: polter_shots::autoscroll::AutoScroll::new(),
            pointer_before,
            wheel_at,
        })
    });
    unsafe {
        let _ = SetCursorPos(wheel_at.x, wheel_at.y);
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

/// The pointer goes back to where the person had it.
fn give_back_pointer(long: &LongShot) {
    if let Some(p) = long.pointer_before {
        let _ = unsafe { SetCursorPos(p.x, p.y) };
    }
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
        give_back_pointer(&long);
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
    let mut verdict = polter_shots::autoscroll::Verdict::Wait;
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
        verdict = long.auto.after_frame(step, tick_ms());
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
    use polter_shots::autoscroll::Verdict;
    match verdict {
        Verdict::Wait => {}
        Verdict::Wheel => {
            // Every notch from where the wheel is meant to go: the person's
            // own pointer may have wandered off the page since the last.
            if let Some(at) = with(|s| s.long.as_ref().map(|l| l.wheel_at)).flatten() {
                unsafe {
                    let _ = SetCursorPos(at.x, at.y);
                }
                crate::shot_agent::wheel_down();
                with(|s| {
                    if let Some(l) = &mut s.long {
                        l.auto.turned(tick_ms());
                    }
                });
            }
        }
        Verdict::Stop(why) => {
            // process-wide: the overlay is not a terminal window
            plogf!("[shot] long screenshot scrolled by the program: stopped at the {why:?}; finishing with what is joined");
            if let Some((hwnd, mon, dpi)) = with(|s| {
                let l = s.long.as_ref()?;
                let m = s.mons.iter().find(|m| m.hwnd == l.hwnd)?;
                Some((l.hwnd, m.rect, m.dpi))
            })
            .flatten()
            {
                perform(hwnd, Effect::Finish);
                // The picture ends here, and the person is told why.
                if why == polter_shots::autoscroll::Stopped::Lost {
                    show_toast(&tr(toolbar::LONG_FOLLOWED), mon, dpi);
                }
            }
        }
    }
}

/// Beside the toolbar: how tall the picture is so far, what the last frame
/// meant, and a small copy of the picture beside the selection.
unsafe fn draw_long_status(
    canvas: &Canvas,
    words: &Words,
    glass: &Glass,
    tones: &chrome::Tones,
    long: &LongShot,
    plate: Rect,
    sel: Rect,
    scale: f64,
    monitor: Rect,
) -> i32 {
    // Until the first new rows are joined the line says what to do.
    let added = long.stitcher.total_height() > long.rect.h as usize;
    let restless = toolbar::long_restless(long.stitcher.never_steady(), long.moving);
    let said = format!("{} {} px", tr(toolbar::LONG), long.stitcher.total_height());
    // The program turns the wheel: "scroll slowly" is no advice to give.
    // What it says while it works is `toolbar::LONG_AUTO`.
    let hint = match toolbar::long_hint(long.last, added, restless) {
        Some(toolbar::LONG_SLOWER | toolbar::LONG_HINT) | None => Some(toolbar::LONG_AUTO),
        other => other,
    }
    .map(|h| format!(" — {}", tr(h)))
    .unwrap_or_default();
    let (a, b) = (words.size(&said), words.size(&hint));
    let (tag, dot) = chrome::status(plate, 0, (a.0 + b.0, a.1.max(b.1)), scale, monitor);
    if let Some(mut on) = Surface::new(canvas.bits(), canvas.rect) {
        chrome::label(&mut on, glass, tag.plate, scale, tones);
        chrome::status_dot(&mut on, dot, scale);
    }
    words.put(tag.text, &said, tones.ink);
    words.put(Point::new(tag.text.x + a.0, tag.text.y), &hint, tones.ink_dim);

    // The preview: right of the selection, or left of it, or not at all.
    let gap = style::px(12, scale);
    let width = style::px(120, scale);
    let x = if sel.right() + gap + width <= monitor.right() {
        sel.right() + gap
    } else if sel.x - gap - width >= monitor.x {
        sel.x - gap - width
    } else {
        return tag.plate.h;
    };
    let room = (monitor.h - gap * 2).max(1);
    let Some((w, h, bits)) = long.stitcher.thumbnail(width as usize, room as usize) else { return tag.plate.h };
    let top = (sel.y.max(monitor.y + gap)).min(monitor.bottom() - gap - h as i32).max(monitor.y);
    let at = Rect::new(x, top, w as i32, h as i32);
    pixels::blit(canvas.bits(), canvas.rect, &bits, at);
    if let Some(mut on) = Surface::new(canvas.bits(), canvas.rect) {
        on.outline(Box2::of(at), 0.0, style::px_f(look::size::SELECTION_LINE, scale) as f64, tones.accent);
    }
    tag.plate.h
}

// ------------------------------------------------------------- text box

/// Open a native `EDIT` for the text `Editor` is about to take. **A real
/// edit control, so the input method works in it** -- an IME composes into a
/// window that implements the text protocols, and this one already does.
/// Several lines: Enter is a line break, Ctrl+Enter and Esc end it.
///
/// **It holds the text and draws none of it.** The control keeps the
/// keyboard, the selection, the undo stack and the clipboard, and scrolls
/// to keep the caret's line in view; its window region is empty
/// (`hide_box`), and the overlay draws what it holds (`draw_text_box`) with
/// no paper under it.
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
    let Some(rect) = with(|s| s.editor.text_rect(&tb.text, &Gdi)).flatten() else {
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
            // take two pixels of the last one.
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
        no_margins(edit);
        hide_box(edit, rect);
        let prev = SetWindowLongPtrW(edit, GWLP_WNDPROC, edit_proc as *const () as isize);
        SetWindowLongPtrW(edit, GWLP_USERDATA, prev);
        // The caret after what is already there.
        const EM_SETSEL: u32 = 0x00B1;
        let end = GetWindowTextLengthW(edit).max(0);
        SendMessageW(edit, EM_SETSEL, Some(WPARAM(end as usize)), Some(LPARAM(end as isize)));
        with(|s| s.edit = Some(EditCtl { hwnd: edit, font, rect, typed: Typed::default(), caret_on: true }));
        log_edit(rect, textbox::lines(&tb.text), "opened");
        // The one time the input method is wanted: see `keys_are_raw`.
        TEXT_OPEN.store(true, Ordering::Release);
        let _ = SetForegroundWindow(parent);
        let _ = SetFocus(Some(edit));
        read_edit(edit);
        // The caret is the overlay's to blink, at the system's own pace
        // (0 and INFINITE both mean a caret that does not blink).
        let blink = GetCaretBlinkTime();
        if blink != 0 && blink != u32::MAX {
            SetTimer(Some(parent), TIMER_CARET, blink, None);
        }
        // Who has the keyboard now, as the system says it: the control has
        // no pixel of its own, and this is where that would show.
        let mut gui = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        let asked = GetGUIThreadInfo(0, &mut gui).is_ok();
        // process-wide: the overlay is not a terminal window
        plogf!(
            "[shot] text box: the keyboard is the box's={} (focus {:#x}, box {:#x}; asked={asked})",
            gui.hwndFocus == edit,
            gui.hwndFocus.0 as usize,
            edit.0 as usize
        );
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
        no_margins(edit);
        with(|s| {
            if let Some(e) = &mut s.edit {
                e.font = font;
            }
        });
        let _ = DeleteObject(old.into());
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
    // The text as it is now, with what an input method is composing where
    // the caret is: the box is as wide as the longest line of it.
    let text = unsafe {
        let mut units = vec![0u16; GetWindowTextLengthW(edit).max(0) as usize + 1];
        let n = GetWindowTextW(edit, &mut units).max(0) as usize;
        units.truncate(n);
        let comp = with(|s| s.edit.as_ref().map(|e| (e.typed.comp.clone(), e.typed.sel.0))).flatten();
        if let Some((comp, at)) = comp.filter(|c| !c.0.is_empty()) {
            let at = at.min(units.len());
            units.splice(at..at, comp);
        }
        String::from_utf16_lossy(&units)
    };
    let Some(rect) = with(|s| s.editor.text_rect(&text, &Gdi)).flatten() else {
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
    log_edit(rect, lines, "now");
    read_edit(edit);
    repaint();
}

/// The control's own margins, none: its first character is at the box's
/// left edge, where a finished text's is. Setting a font puts them back.
unsafe fn no_margins(edit: HWND) {
    const EM_SETMARGINS: u32 = 0x00D3;
    // EC_LEFTMARGIN | EC_RIGHTMARGIN
    unsafe { SendMessageW(edit, EM_SETMARGINS, Some(WPARAM(3)), Some(LPARAM(0))) };
}

/// Take every pixel away from the text box: its window region is made
/// empty. It is still a window, still shown, still the one with the
/// keyboard -- but it draws nowhere and nothing can be pressed on it, so
/// the picture shows where it is, the toolbar is over it wherever the two
/// meet, and a press there is the overlay's to hand on (`box_at`).
///
/// **Whether the system keeps the control from drawing is asked and
/// logged**, once for each box (task 1107: a plain `EDIT` drew in parts cut
/// out of it; `register_text_class` is why this one does not). `box draws`
/// true would be the control's paper over the picture, and the line says so
/// rather than leaving it to be seen.
unsafe fn hide_box(edit: HWND, rect: Rect) {
    unsafe {
        // The system owns a region once it is set.
        let _ = SetWindowRgn(edit, Some(CreateRectRgn(0, 0, 0, 0)), true);
        let visible = |dc: HDC, r: Rect| {
            let rc = RECT { left: r.x, top: r.y, right: r.right(), bottom: r.bottom() };
            !dc.is_invalid() && RectVisible(dc, &rc).as_bool()
        };
        let own = GetDC(Some(edit));
        let box_draws = visible(own, Rect::new(0, 0, rect.w, rect.h));
        ReleaseDC(Some(edit), own);
        let parent = GetParent(edit).unwrap_or_default();
        let mut origin = POINT::default();
        let _ = ClientToScreen(parent, &mut origin);
        let clipped = GetDCEx(Some(parent), None, DCX_CACHE | DCX_CLIPCHILDREN);
        let overlay_draws = visible(clipped, rect.relative_to(Point::new(origin.x, origin.y)));
        ReleaseDC(Some(parent), clipped);
        let parent_dc = GetClassLongW(edit, GCL_STYLE) & CS_PARENTDC.0 != 0;
        let then = if box_draws { "THE BOX'S OWN PAPER IS OVER THE PICTURE" } else { "the overlay draws the text" };
        // process-wide: the overlay is not a terminal window
        plogf!(
            "[shot] text box: its window region is empty; box draws there={box_draws} (class CS_PARENTDC={parent_dc}), \
             overlay draws there={overlay_draws}; {then}"
        );
    }
}

/// The text box, if `p` is in it and not on the toolbar: its window and
/// `p` in its own coordinates. The toolbar is asked first, always
/// (`textbox::on_toolbar`).
fn box_at(p: Point) -> Option<(HWND, Point)> {
    with(|s| {
        let e = s.edit.as_ref()?;
        (e.rect.contains(p) && !textbox::on_toolbar(p, &s.editor.text_keep_clear())).then(|| (e.hwnd, p.relative_to(e.rect.origin())))
    })
    .flatten()
}

/// Have the overlay paint the text box again, in its own time.
/// `InvalidateRect` sends nothing and returns at once.
fn repaint_text_box() {
    let Some((overlay, l)) = with(|s| {
        let e = s.edit.as_ref()?;
        let m = &s.mons[s.editor.selection()?.monitor];
        Some((m.hwnd, textbox::damage(e.rect, s.editor.scale()).relative_to(m.rect.origin())))
    })
    .flatten() else {
        return;
    };
    let rc = RECT { left: l.x, top: l.y, right: l.right(), bottom: l.bottom() };
    let _ = unsafe { InvalidateRect(Some(overlay), Some(&rc), false) };
}

/// Read back what the control holds -- its text, what is selected and
/// which end the caret is at, how far it has scrolled -- into
/// `EditCtl::typed`, have the overlay paint it, and tell the input method
/// where the caret now is.
///
/// **Every message this sends is a question** (`textbox::HOST_READS`), and
/// none of them is one `edit_proc` reads the control back after
/// (`textbox::changes_box`): reading cannot ask for another reading.
fn read_edit(edit: HWND) {
    const EM_GETSEL: u32 = 0x00B0;
    const EM_GETFIRSTVISIBLELINE: u32 = 0x00CE;
    const EM_POSFROMCHAR: u32 = 0x00D6;
    if !with(|s| s.edit.as_ref().is_some_and(|e| e.hwnd == edit)).unwrap_or(false) {
        return;
    }
    let (units, sel, caret_at_start, first_line, scroll_x) = unsafe {
        let mut units = vec![0u16; GetWindowTextLengthW(edit).max(0) as usize + 1];
        let n = GetWindowTextW(edit, &mut units).max(0) as usize;
        units.truncate(n);
        let (mut from, mut to) = (0u32, 0u32);
        SendMessageW(edit, EM_GETSEL, Some(WPARAM(&mut from as *mut u32 as usize)), Some(LPARAM(&mut to as *mut u32 as isize)));
        // Where the control has a character, in its own coordinates;
        // nothing for one past the end.
        let place = |i: u32| {
            let r = SendMessageW(edit, EM_POSFROMCHAR, Some(WPARAM(i as usize)), None).0;
            (r != -1).then(|| ((r & 0xFFFF) as i16 as i32, ((r >> 16) & 0xFFFF) as i16 as i32))
        };
        // The first character is at the left edge until the control
        // scrolls sideways (`no_margins`).
        let scroll_x = if n > 0 { place(0).map_or(0, |p| -p.0) } else { 0 };
        // The control does not say which end of a selection the caret is
        // at; the system's caret, which it still moves, does.
        let mut caret = POINT::default();
        let caret_at_start = from < to && GetCaretPos(&mut caret).is_ok() && place(from).is_some_and(|p| p.1 == caret.y && (p.0 - caret.x).abs() <= 2);
        let first_line = SendMessageW(edit, EM_GETFIRSTVISIBLELINE, None, None).0 as i32;
        (units, (from as usize, to as usize), caret_at_start, first_line, scroll_x)
    };
    with(|s| {
        if let Some(e) = &mut s.edit {
            e.typed = Typed { units, sel, caret_at_start, first_line, scroll_x, comp: std::mem::take(&mut e.typed.comp), comp_caret: e.typed.comp_caret };
            // Something happened: the caret is shown, whatever half of its
            // blink it was in.
            e.caret_on = true;
        }
    });
    repaint_text_box();
    place_ime(edit);
}

/// Where the caret is drawn: its rectangle on the virtual screen, the box,
/// and the height of a line.
fn caret_place() -> Option<(Rect, Rect, i32)> {
    with(|s| {
        let (e, tb) = (s.edit.as_ref()?, s.editor.text_box()?);
        let scale = s.editor.scale();
        let line = s.editor.text_line(tb.level, &Gdi);
        let v = textbox::view(&e.typed, e.rect.w, line, style::font_px(tb.level, scale), scale, &Gdi);
        Some((Rect::new(v.caret.x + e.rect.x, v.caret.y + e.rect.y, v.caret.w, v.caret.h), e.rect, line))
    })
    .flatten()
}

/// Tell the input method where the caret is, so its candidates open beside
/// what is being composed and not on it: the composition's place, and a
/// rectangle -- the caret's line -- the candidate window keeps off.
fn place_ime(edit: HWND) {
    use windows::Win32::UI::Input::Ime::{
        ImmGetContext, ImmReleaseContext, ImmSetCandidateWindow, ImmSetCompositionWindow, CANDIDATEFORM, CFS_EXCLUDE, CFS_POINT,
        COMPOSITIONFORM,
    };
    let Some((caret, b, line)) = caret_place() else { return };
    // In the control's own coordinates, which start at the box's corner.
    let l = caret.relative_to(b.origin());
    let row = (l.y + l.h / 2).div_euclid(line.max(1)) * line.max(1);
    let area = RECT { left: 0, top: row, right: b.w, bottom: row + line };
    unsafe {
        let himc = ImmGetContext(edit);
        if himc.0.is_null() {
            return;
        }
        let comp = COMPOSITIONFORM { dwStyle: CFS_POINT, ptCurrentPos: POINT { x: l.x, y: row }, rcArea: area };
        let _ = ImmSetCompositionWindow(himc, &comp);
        let cand = CANDIDATEFORM { dwIndex: 0, dwStyle: CFS_EXCLUDE, ptCurrentPos: POINT { x: l.x, y: row + line }, rcArea: area };
        let _ = ImmSetCandidateWindow(himc, &cand);
        let _ = ImmReleaseContext(edit, himc);
    }
}

/// The input method has something to say about what it is composing
/// (`WM_IME_COMPOSITION`, whose `lParam` is `flags`). What it committed
/// goes into the control as typing does -- one step to undo; what it is
/// still composing is kept beside the control's text and drawn at the
/// caret (`textbox::view`), because the control would show it in a window
/// of the system's own, with paper.
fn ime_composition(edit: HWND, flags: u32) {
    use windows::Win32::UI::Input::Ime::{
        ImmGetCompositionStringW, ImmGetContext, ImmReleaseContext, GCS_COMPSTR, GCS_CURSORPOS, GCS_RESULTSTR, IME_COMPOSITION_STRING,
    };
    const EM_REPLACESEL: u32 = 0x00C2;
    let (mut committed, comp, comp_caret) = unsafe {
        let himc = ImmGetContext(edit);
        if himc.0.is_null() {
            return;
        }
        let read = |what: IME_COMPOSITION_STRING| {
            let bytes = ImmGetCompositionStringW(himc, what, None, 0);
            let mut units = vec![0u16; bytes.max(0) as usize / 2];
            if !units.is_empty() {
                ImmGetCompositionStringW(himc, what, Some(units.as_mut_ptr() as *mut c_void), bytes as u32);
            }
            units
        };
        let committed = if flags & GCS_RESULTSTR.0 != 0 { read(GCS_RESULTSTR) } else { Vec::new() };
        let comp = read(GCS_COMPSTR);
        let comp_caret = (ImmGetCompositionStringW(himc, GCS_CURSORPOS, None, 0).max(0) as usize & 0xFFFF).min(comp.len());
        let _ = ImmReleaseContext(edit, himc);
        (committed, comp, comp_caret)
    };
    let (was, now) = with(|s| {
        let e = s.edit.as_mut()?;
        let was = e.typed.comp.len();
        e.typed.comp = comp;
        e.typed.comp_caret = comp_caret;
        Some((was, e.typed.comp.len()))
    })
    .flatten()
    .unwrap_or((0, 0));
    // The first and the last of a composition, not every key of it.
    // absence: depends -- with an input method composing and no line, the
    // box's procedure never got WM_IME_COMPOSITION (the method is not one
    // that asks the application to draw); with none composing it is silent
    if (was == 0) != (now == 0) || !committed.is_empty() {
        let at = caret_place().map(|(c, _, _)| (c.x, c.bottom()));
        // process-wide: the overlay is not a terminal window
        plogf!(
            "[shot] text box: the input method is composing {now} unit(s) (was {was}), committed {}; the caret it is told of is at {at:?}",
            committed.len()
        );
    }
    if committed.is_empty() {
        read_edit(edit);
        // What is being composed is as wide as what is typed.
        fit_edit();
    } else {
        committed.push(0);
        // Read back by `edit_proc` after it, as anything typed is.
        unsafe { SendMessageW(edit, EM_REPLACESEL, Some(WPARAM(1)), Some(LPARAM(committed.as_ptr() as isize))) };
        fit_edit();
    }
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
    if let Some(parent) = parent {
        // Killing one that was never set fails, and that is fine.
        let _ = unsafe { KillTimer(Some(parent), TIMER_CARET) };
    }
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
        // The input method. What it composes is the overlay's to draw, so
        // none of this reaches the control or the system's default, which
        // would open a composition window with paper of its own over the
        // picture (seen on the test machine, task 1106: `MSCTFIME
        // Composition`, black on white whatever colour was chosen).
        const WM_IME_STARTCOMPOSITION: u32 = 0x010D;
        const WM_IME_ENDCOMPOSITION: u32 = 0x010E;
        const WM_IME_COMPOSITION: u32 = 0x010F;
        const WM_IME_SETCONTEXT: u32 = 0x0281;
        const WM_IME_REQUEST: u32 = 0x0288;
        const IMR_QUERYCHARPOSITION: usize = 0x0006;
        // ISC_SHOWUICOMPOSITIONWINDOW: the system is not to show one.
        let lp = if msg == WM_IME_SETCONTEXT { LPARAM(lp.0 & !0x8000_0000isize) } else { lp };
        match msg {
            WM_IME_STARTCOMPOSITION => {
                place_ime(hwnd);
                return LRESULT(0);
            }
            WM_IME_COMPOSITION => {
                ime_composition(hwnd, lp.0 as u32);
                return LRESULT(0);
            }
            WM_IME_ENDCOMPOSITION => {
                ime_composition(hwnd, 0);
                return LRESULT(0);
            }
            // Where is the character being composed? At the caret the
            // overlay draws, which is the only one there is to see.
            WM_IME_REQUEST if wp.0 == IMR_QUERYCHARPOSITION && lp.0 != 0 => {
                if let Some((caret, b, line)) = caret_place() {
                    let ask = &mut *(lp.0 as *mut windows::Win32::UI::Input::Ime::IMECHARPOSITION);
                    ask.pt = POINT { x: caret.x, y: caret.y };
                    ask.cLineHeight = line as u32;
                    ask.rcDocument = RECT { left: b.x, top: b.y, right: b.right(), bottom: b.bottom() };
                    return LRESULT(1);
                }
            }
            // A box of the plain class could draw although it has no
            // region (`register_text_class`): then it is at least never
            // asked to. What it draws unasked -- a key, its caret -- it
            // still would, and `hide_box` has said so in the log.
            WM_PAINT if !TEXT_CLASS.load(Ordering::Acquire) => {
                let _ = ValidateRect(Some(hwnd), None);
                return LRESULT(0);
            }
            WM_ERASEBKGND if !TEXT_CLASS.load(Ordering::Acquire) => return LRESULT(1),
            _ => {}
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = std::mem::transmute(prev);
        let r = f(hwnd, msg, wp, lp);
        // Whatever may have added or removed a line: a key, a character, a
        // paste, a cut, an undo. The box follows what is in it (`fit_edit`
        // does nothing when nothing changed).
        if textbox::may_change_lines(msg) {
            fit_edit();
        }
        // The control draws nothing, so after anything that may have
        // changed what it holds it is read back and the overlay paints.
        // Only for the messages on a list, and reading back sends none of
        // them -- doing something here after everything but a few
        // questions is what stopped the window thread (31c90b552).
        if textbox::changes_box(msg, wp.0 & 0x0001 != 0) {
            read_edit(hwnd);
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

/// Ctrl+C with the magnifier up: the colour under the pointer, as `#RRGGBB`
/// text, goes on the clipboard and the magnifier says so for a moment. The
/// screenshot goes on.
fn copy_colour(hwnd: HWND) {
    let Some(code) = with(|s| {
        let at = s.editor.magnifier()?;
        let mon = s.mons.iter().find(|m| m.rect.contains(at))?;
        mon.frozen.rgb_at(at).map(polter_shots::magnifier::hex)
    })
    .flatten() else {
        return;
    };
    let units: Vec<u8> = code.encode_utf16().chain(Some(0)).flat_map(|u| u.to_le_bytes()).collect();
    let ok = unsafe {
        let control = HWND(CONTROL.load(Ordering::Acquire) as *mut c_void);
        let mut ok = false;
        if OpenClipboard(Some(control)).is_ok() {
            let _ = EmptyClipboard();
            ok = set_clipboard(13, &units); // CF_UNICODETEXT
            let _ = CloseClipboard();
        }
        ok
    };
    // process-wide: the overlay is not a terminal window
    plogf!("[shot] magnifier: colour {code} copied={ok}");
    if ok {
        with(|s| s.copied_until = tick_ms() + u64::from(COPIED_MS));
        unsafe { SetTimer(Some(hwnd), TIMER_COPIED, COPIED_MS, None) };
        repaint();
    }
}

// ------------------------------------------------------------- toast

/// The notice that outlives the session (`polter_shots::toast`): a window of
/// its own, shown without taking the keyboard, that takes itself away.
struct Toast {
    hwnd: HWND,
    canvas: Canvas,
}

thread_local! {
    static TOAST: RefCell<Option<Toast>> = const { RefCell::new(None) };
}

const TIMER_TOAST_END: usize = 1;

unsafe extern "system" fn toast_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                TOAST.with(|t| {
                    if let Some(t) = t.borrow().as_ref().filter(|t| t.hwnd == hwnd) {
                        let _ = BitBlt(hdc, 0, 0, t.canvas.rect.w, t.canvas.rect.h, Some(t.canvas.dc), 0, 0, SRCCOPY);
                    }
                });
                let _ = EndPaint(hwnd, &ps);
                LRESULT(0)
            }
            WM_TIMER if wp.0 == TIMER_TOAST_END => {
                close_toast();
                LRESULT(0)
            }
            // Never the keyboard, never the mouse: a click goes to what is under it.
            WM_MOUSEACTIVATE => LRESULT(3), // MA_NOACTIVATE
            WM_NCHITTEST => LRESULT(-1),    // HTTRANSPARENT
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

fn close_toast() {
    if let Some(t) = TOAST.with(|t| t.borrow_mut().take()) {
        unsafe {
            let _ = KillTimer(Some(t.hwnd), TIMER_TOAST_END);
            let _ = DestroyWindow(t.hwnd);
        }
    }
}

/// Show `text` on a small glass plate in the bottom-right corner of
/// `monitor` for `toast::SHOW_MS`. The plate is made of what is on the
/// screen under it, blurred, as the overlay's own plates are -- so it looks
/// like them; the window has the plate's rounded shape.
fn show_toast(text: &str, monitor: Rect, dpi: u32) {
    close_toast();
    unsafe {
        let screen = GetDC(None);
        let made = (|| {
            let scale = f64::from(dpi.max(96)) / 96.0;
            // Measured on a canvas of no size of its own.
            let probe = Canvas::new(screen, Rect::new(0, 0, 1, 1))?;
            let (lines, sizes) = {
                let words = Words::on(&probe, dpi);
                let lines = polter_shots::toast::wrap(text, style::px_f(polter_shots::toast::MAX_WIDTH, scale), |s| words.size(s).0);
                let sizes: Vec<(i32, i32)> = lines.iter().map(|l| words.size(l)).collect();
                (lines, sizes)
            };
            let plate = polter_shots::toast::plate_size(&sizes, scale);
            let rect = polter_shots::toast::place(plate, monitor, scale);
            let canvas = Canvas::new(screen, rect)?;
            let frozen = grab(screen, rect)?;
            frozen.show(canvas.bits(), rect);
            let glass = frozen.glass(scale, !less_transparency())?;
            let tones = tones();
            if let Some(mut on) = Surface::new(canvas.bits(), rect) {
                chrome::label(&mut on, &glass, rect, scale, &tones);
            }
            {
                let words = Words::on(&canvas, dpi);
                let (px, py) = (style::px_f(look::size::SIZE_LABEL_PAD_X, scale), style::px_f(look::size::SIZE_LABEL_PAD_Y, scale));
                let mut y = rect.y + py;
                for (line, size) in lines.iter().zip(&sizes) {
                    words.put(Point::new(rect.x + px, y), line, tones.ink);
                    y += size.1;
                }
            }
            Some((rect, canvas, scale))
        })();
        ReleaseDC(None, screen);
        let Some((rect, canvas, scale)) = made else {
            // process-wide: the toast is for the whole process
            plogf!("[shot] toast: could not be made for {text:?}");
            return;
        };
        let hinst = GetModuleHandleW(None).unwrap_or_default();
        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            w!("PolterShotToast"),
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
            // process-wide: the toast is for the whole process
            plogf!("[shot] toast: no window (err={})", GetLastError().0);
            return;
        };
        let r = style::px_f(look::size::LABEL_RADIUS, scale) * 2;
        let region = CreateRoundRectRgn(0, 0, rect.w + 1, rect.h + 1, r, r);
        SetWindowRgn(hwnd, Some(region), true);
        TOAST.with(|t| *t.borrow_mut() = Some(Toast { hwnd, canvas }));
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        SetTimer(Some(hwnd), TIMER_TOAST_END, polter_shots::toast::SHOW_MS, None);
        // process-wide: the toast is for the whole process
        plogf!("[shot] toast: {text:?} at {rect:?} for {} ms", polter_shots::toast::SHOW_MS);
    }
}

/// The person's Downloads folder, as the system knows it (it can be moved);
/// never a path written into the program.
fn downloads_dir() -> Option<std::path::PathBuf> {
    use windows::Win32::System::Com::CoTaskMemFree;
    use windows::Win32::UI::Shell::{FOLDERID_Downloads, SHGetKnownFolderPath, KF_FLAG_DEFAULT};
    unsafe {
        let p = SHGetKnownFolderPath(&FOLDERID_Downloads, KF_FLAG_DEFAULT, None).ok()?;
        let path = p.to_string().ok().map(std::path::PathBuf::from);
        CoTaskMemFree(Some(p.0 as *const c_void));
        path
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

/// Done: the composed image to the clipboard and to a file, and the sidecar
/// beside it. **Nothing is pasted**, whether or not Polter was in front when
/// this started: a path arriving in whichever pane had the keyboard is one
/// the person has to delete when it was meant for another. They paste it,
/// and that paste (`shots::image_text`) finds the file, a long one's tiles,
/// and the line.
fn finish() {
    commit_edit();
    let Some(export) = with(|s| s.editor.export()).flatten() else { return };
    // A long screenshot's frames, taken out before the windows go.
    let long = with(|s| s.long.take()).flatten();
    if let Some(l) = &long {
        let _ = unsafe { KillTimer(Some(l.hwnd), TIMER_LONG) };
        give_back_pointer(l);
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
            if SAVE_COPY.swap(false, Ordering::AcqRel) {
                show_toast(&tr(toolbar::SAVE_FAILED), mon.rect, mon.dpi);
            }
            return;
        }
    };
    // Save: the same picture, once more, in the person's Downloads folder
    // under the same name, over nothing that is there (`store::write_copy`).
    if SAVE_COPY.swap(false, Ordering::AcqRel) {
        let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        match downloads_dir().ok_or_else(|| "the Downloads folder is not known".to_string()).and_then(|d| {
            polter_shots::store::write_copy(&d, &name, &png).map_err(|e| format!("{}: {e}", d.display()))
        }) {
            Ok(copy) => {
                // process-wide: the overlay is not a terminal window
                plogf!("[shot] save: a copy is {}", copy.display());
                let file = copy.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                show_toast(&polter_shots::toast::with_name(&tr(toolbar::SAVED), &file), mon.rect, mon.dpi);
            }
            Err(why) => {
                // process-wide: the overlay is not a terminal window
                plogf!("[shot] save: the copy in Downloads was NOT written: {why}");
                show_toast(&tr(toolbar::SAVE_FAILED), mon.rect, mon.dpi);
            }
        }
    }
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
    // The line that ends a paste of this shot: its annotations, or for a
    // long one -- pasted as its tiles, at most `MAX_TILES_PASTED` of them --
    // how many tiles there are, when some were left out.
    let pasted_tiles = tile_paths.len().min(MAX_TILES_PASTED);
    let note = if long.is_some() {
        let en = annot::LONG_EN;
        let w = [en.header, en.tiles, en.whole, en.separator, en.see].map(tr);
        let ll = annot::LongLabels { header: &w[0], tiles: &w[1], whole: &w[2], separator: &w[3], see: &w[4] };
        annot::long_line(meta.size, tile_paths.len(), pasted_tiles, &path.to_string_lossy(), &json.to_string_lossy(), &ll)
    } else {
        annot::line(meta.size, items, &json.to_string_lossy(), &l)
    };

    // A paste made by hand finds this file, its tiles and its line by the
    // clipboard's sequence number, instead of saving the clipboard's bitmap
    // a second time.
    if on_clipboard {
        crate::shots::remember(seq, path.clone(), tile_paths, note);
    }
    // process-wide: the overlay is not a terminal window
    plogf!(
        "[shot] done: {}x{} px at scale {} from {:?}, {} annotation(s) ({} drawn in all), {} tile(s); saved {}; \
         sidecar {}; clipboard={on_clipboard} (sequence {seq}); nothing pasted",
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
}
