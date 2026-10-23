//! The control room's snapshot: fetched once for the whole host, then handed
//! to whoever draws from it.
//!
//! **One fetch per notice, and none without one**
//! (`dev-docs/poltergeist/control-room.md`, 5.4). The core says
//! `control_room_changed`; this asks for the snapshot once, decodes it once,
//! and every reader -- the panel, and every window's tab strip, which draws a
//! status glyph on each terminal tab -- reads the copy kept here. There is no
//! timer that fetches. Every fetch writes one line with its number
//! (`[control-room] fetch #N`), and that is what a criterion reads: sixty
//! seconds with nothing changing must add no such line.
//!
//! **Nothing here decides anything.** What a tab carries is
//! `polter_control_room::pulse::tab_status`; this passes it the three keys it
//! asks for and hands back what it said.
//! `tools/control-room-hosts-do-not-decide.py` reads this file.
//!
//! **Main thread only, apart from `announce`.** The core's notice arrives on
//! whichever thread the core is on, and the snapshot export is "app thread
//! only", so the notice is turned into a posted message and everything else
//! happens where the windows live. That is why the state is a `thread_local`
//! and there is no lock.

use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

use windows::Win32::Foundation::{HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::InvalidateRect;
use windows::Win32::UI::WindowsAndMessaging::{
    GetClientRect, KillTimer, PostMessageW, SetTimer, SystemParametersInfoW, SPI_GETCLIENTAREAANIMATION,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, WM_APP,
};

use polter_control_room::list::List;
use polter_control_room::pulse;
use polter_control_room::rules;
use polter_control_room::snapshot::{self, Shown, Snapshot};

use crate::{plogf, tabs};

/// Posted to a frame when the core has said the snapshot changed.
pub const WM_POLTER_CONTROL_ROOM: u32 = WM_APP + 60;

/// A notice has arrived and its fetch has not happened yet. Several notices
/// before the message is handled are one fetch.
static PENDING: AtomicBool = AtomicBool::new(false);

/// The `rev` the last notice carried, for the fetch's line: a fetch that
/// reads a different `rev` from the one it was told about is worth seeing.
static ANNOUNCED: AtomicU64 = AtomicU64::new(0);

/// How many times the snapshot has been asked for, for the life of the
/// process.
static FETCHES: AtomicU32 = AtomicU32::new(0);

pub struct Ready {
    pub snapshot: Snapshot,
    pub list: List,
    /// What it says about projects: whether the core has been told, what
    /// it asks of this host, and each group's project.
    pub projects: polter_projects::orders::Told,
}

/// What there is to draw from.
///
/// **Three things, kept apart**: nothing has been worked out yet, something
/// arrived that could not be read, and a snapshot. The first two are drawn
/// as a sentence each -- never as an empty list, which says "there are no
/// groups" and is a different fact from either.
pub enum Data {
    NotYet,
    Unreadable(String),
    Ready(Box<Ready>),
}

thread_local! {
    static DATA: RefCell<Data> = const { RefCell::new(Data::NotYet) };
    /// The animation timer's id, 0 when it is not running.
    static TICKER: Cell<usize> = const { Cell::new(0) };
    /// Something that moves was painted since the last tick.
    static WANTED: Cell<bool> = const { Cell::new(false) };
}

/// The core's `control_room_changed`. **Safe from any thread**: it sets a
/// flag and posts a message.
pub fn announce(rev: u64) {
    ANNOUNCED.store(rev, Ordering::Release);
    if PENDING.swap(true, Ordering::AcqRel) {
        // absence: normal -- a notice that arrived while one was already
        // waiting is the same fetch.
        return;
    }
    let frame = tabs::overlay_frame();
    if frame.0.is_null() {
        // process-wide: there is no window to post to, so nothing draws a
        // snapshot either; the flag stays set and the next notice with a
        // window finds it.
        PENDING.store(false, Ordering::Release);
        plogf!("[control-room] snapshot changed, but there is no window to tell; not fetched");
        return;
    }
    if unsafe { PostMessageW(Some(frame), WM_POLTER_CONTROL_ROOM, WPARAM(0), LPARAM(0)) }.is_err() {
        PENDING.store(false, Ordering::Release);
        // process-wide: the snapshot is the application's, not a window's
        plogf!("[control-room] snapshot changed, but the notice could not be posted; not fetched");
    }
}

/// The posted notice, on the window's thread: fetch once and tell everybody.
pub fn on_message() {
    if !PENDING.swap(false, Ordering::AcqRel) {
        return;
    }
    fetch();
}

/// Ask again without waiting to be told: after an act the core refused
/// because the row was out of date (`Refusal::means_look_again`).
pub fn look_again() {
    fetch();
}

fn fetch() {
    let n = FETCHES.fetch_add(1, Ordering::Relaxed) + 1;
    let data = read();
    // process-wide: the snapshot is the application's, not a window's
    match &data {
        Data::NotYet => plogf!("[control-room] fetch #{}: the core has worked nothing out yet", n),
        Data::Unreadable(why) => plogf!("[control-room] fetch #{}: UNREADABLE: {}", n, why),
        Data::Ready(r) => plogf!(
            "[control-room] fetch #{}: rev {} (the last notice said rev {})",
            n,
            r.snapshot.rev,
            ANNOUNCED.load(Ordering::Acquire)
        ),
    }
    DATA.with(|d| *d.borrow_mut() = data);
    redraw_everything();
    crate::control_room::snapshot_changed();
    // The frames round the panes of a split tab say what the snapshot says
    // of each terminal.
    crate::pane_frames::snapshot_changed();
    // What the core asks about projects, and the first chance to tell it
    // what projects there are. With the borrow gone: telling it calls `act`.
    let projects = with(|d| match d {
        Data::Ready(r) => Some(r.projects.clone()),
        _ => None,
    });
    if let Some(projects) = projects {
        crate::project_session::told(&projects);
    }
    // Whether the core says to ask about a group's project now (task 1714).
    crate::project_link_ui::soon();
}

fn read() -> Data {
    let Some(api) = crate::api_opt() else { return Data::NotYet };
    let app = crate::app_opt();
    if app.is_null() {
        return Data::NotYet;
    }
    // The persona buffer rule: the real length back, one NUL after it when
    // it fits. Zero bytes means none has been worked out yet.
    let need = unsafe { (api.app_control_snapshot)(app, std::ptr::null_mut(), 0) };
    if need == 0 {
        return Data::NotYet;
    }
    let mut buf = vec![0u8; need + 1];
    let wrote = unsafe { (api.app_control_snapshot)(app, buf.as_mut_ptr(), buf.len()) };
    if wrote == 0 || wrote > need {
        return Data::Unreadable("it changed size between asking and reading".into());
    }
    let Ok(text) = std::str::from_utf8(&buf[..wrote]) else {
        return Data::Unreadable("it is not UTF-8".into());
    };
    match snapshot::decode(text) {
        Ok(mut snapshot) => {
            // The words beside each glyph come as English msgids: said in
            // the person's language here, before anything measures them.
            snapshot.translate_words(&|w| crate::i18n::tr(w));
            let list = List::from_snapshot(&snapshot);
            // The part about projects is read on its own
            // (`polter_projects::orders`), and strictly: an order this build
            // does not know is said, not skipped.
            let projects = polter_projects::orders::decode(text).unwrap_or_else(|why| {
                // process-wide: the snapshot is the application's, not a window's
                plogf!("[control-room] the snapshot's projects could not be read: {}", why);
                Default::default()
            });
            Data::Ready(Box::new(Ready { snapshot, list, projects }))
        }
        Err(e) => Data::Unreadable(format!("{e:?}")),
    }
}

/// What one of the right side's pages shows (task 2015, API.md §2):
/// `request` is the page's JSON request, and the answer is the core's JSON,
/// or why there is none -- `NoExport` from a core without the call,
/// `NotReady` before it has worked anything out. Either way a test
/// machine's fake answer is read in its place (`test_answer`), when one is
/// named. App thread only.
pub fn page(request: &str) -> Result<String, String> {
    let Some(api) = crate::api_opt() else { return Err("NotReady".into()) };
    let Some(ask) = api.app_control_page else { return test_answer(request) };
    let app = crate::app_opt();
    if app.is_null() {
        return Err("NotReady".into());
    }
    // Twice with the same request: the length, then the same answer into a
    // buffer that holds it (the core keeps what it worked out between).
    let need = unsafe { ask(app, request.as_ptr(), request.len(), std::ptr::null_mut(), 0) };
    if need == 0 {
        // The core has the call and nothing to say yet -- 5001485cb's stub
        // says nothing ever (group seq 243): a fake answer stands in for
        // it, as for a core without the call; without one, not ready.
        return test_answer(request).map_err(|why| if why == "NoExport" { "NotReady".into() } else { why });
    }
    let mut buf = vec![0u8; need + 1];
    let wrote = unsafe { ask(app, request.as_ptr(), request.len(), buf.as_mut_ptr(), buf.len()) };
    if wrote == 0 || wrote > need {
        return Err("it changed size between asking and reading".into());
    }
    String::from_utf8(buf[..wrote].to_vec()).map_err(|_| "it is not UTF-8".into())
}

/// **For a test machine only, and only while the core has no answer** --
/// no `ghostty_app_control_page`, or one that says nothing yet (task 2039;
/// the mac host's rule, group seq 245): a page's answer read from the
/// file `POLTER_TEST_RESOURCES_JSON` (the performance page) or
/// `POLTER_TEST_TASKS_JSON` (the task page) names -- the fake answers in
/// `windows/control-room/testdata/` -- so that the pages can be measured on
/// a real machine before the core can answer. The first use of each is in
/// the log. A core with an answer is never second-guessed: neither
/// variable is read then.
fn test_answer(request: &str) -> Result<String, String> {
    static SAID_RESOURCES: AtomicBool = AtomicBool::new(false);
    static SAID_TASKS: AtomicBool = AtomicBool::new(false);
    let (var, said) = if request.contains(r#""page":"resources""#) {
        ("POLTER_TEST_RESOURCES_JSON", &SAID_RESOURCES)
    } else if request.contains(r#""page":"tasks""#) {
        ("POLTER_TEST_TASKS_JSON", &SAID_TASKS)
    } else {
        return Err("NoExport".into());
    };
    let Some(path) = std::env::var_os(var) else { return Err("NoExport".into()) };
    // absence: depends -- it is said the first time only; the file is read
    // on every ask after that and not said again.
    if !said.swap(true, Ordering::Relaxed) {
        // process-wide: the variable is the process's, not a window's
        plogf!("[control-room] the core has no answer for a page: it is reading {:?} ({}); said once", path, var);
    }
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{var}: {e}"))?;
    // The fake answers are about a group called web-app: it is said to be
    // about the group asked for, or the page would not take it.
    let group = match polter_control_room::json::parse(request).ok().as_ref().and_then(|v| v.get("group")) {
        Some(polter_control_room::json::Value::Str(g)) => g.clone(),
        _ => return Err("BadRequest".into()),
    };
    Ok(text.replacen("\"group\": \"web-app\"", &format!("\"group\": {}", polter_control_room::json::quote(&group)), 1))
}

/// Read what there is. The closure must not call back into this module.
pub fn with<R>(f: impl FnOnce(&Data) -> R) -> R {
    DATA.with(|d| f(&d.borrow()))
}

/// The glyph a terminal tab carries on its window's tab strip, and whether
/// it is the one that breathes there; none when nothing is drawn.
///
/// `window`, `tab` and `showing` are the host's own numbers
/// (`WindowState::id`, `TabId`), put into the snapshot's spelling to be
/// tested for equality.
pub fn tab_glyph(window: u64, tab: u64, showing: Option<u64>) -> Option<(Shown, bool)> {
    with(|data| {
        let snapshot = match data {
            Data::NotYet => None,
            Data::Unreadable(_) => None,
            Data::Ready(r) => Some(&r.snapshot),
        };
        let showing = showing.map(rules::key);
        let status = pulse::tab_status(snapshot, &rules::key(tab), &rules::key(window), showing.as_deref());
        pulse::draws_on_window_tab(status.shown).then_some((status.shown, status.pulses))
    })
}

/// One act of the person's, sent home. `Err` is the core's name for why it
/// was not done.
pub fn act(request: &str) -> Result<(), String> {
    let Some(api) = crate::api_opt() else { return Err("NoApp".into()) };
    let app = crate::app_opt();
    if app.is_null() {
        return Err("NoApp".into());
    }
    let mut err = [0u8; 128];
    let ok = unsafe { (api.app_control_act)(app, request.as_ptr(), request.len(), err.as_mut_ptr(), err.len()) };
    if ok {
        return Ok(());
    }
    let end = err.iter().position(|&b| b == 0).unwrap_or(err.len());
    Err(String::from_utf8_lossy(&err[..end]).into_owned())
}

// ---------------------------------------------------------------- redrawing

/// Every window's tab strip, repainted: each draws its tabs' glyphs from the
/// snapshot.
fn redraw_everything() {
    let frames: Vec<(isize, f64)> = tabs::with_windows(|ws| ws.iter().map(|w| (w.frame, w.scale)).collect());
    for (frame, scale) in frames {
        let hwnd = HWND(frame as *mut core::ffi::c_void);
        let mut rc = RECT::default();
        unsafe {
            if GetClientRect(hwnd, &mut rc).is_err() {
                continue;
            }
            rc.bottom = crate::strip::strip_h(scale);
            let _ = InvalidateRect(Some(hwnd), Some(&rc), false);
        }
    }
}

// ---------------------------------------------------------------- animation
//
// A glyph that breathes and a spinner that turns need a clock. **The clock
// exists only while something that moves is on screen**: whoever paints such
// a thing says `wants_ticks()`, the tick repaints, and a tick that finds
// nobody asked since the last one stops the timer. So a window with nothing
// waiting and nothing working is woken by this exactly never
// (`control-room.md`, 13.2), and nothing has to remember to stop it.

/// How often a moving glyph is redrawn, in milliseconds.
const TICK_MS: u32 = 100;

/// Whether the system animates what is inside windows. Off, and nothing here
/// moves: the shapes and the two colours still tell the four apart.
pub fn animations_on() -> bool {
    let mut on = windows::core::BOOL(1);
    let asked = unsafe {
        SystemParametersInfoW(
            SPI_GETCLIENTAREAANIMATION,
            0,
            Some(&mut on as *mut _ as *mut core::ffi::c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    asked.is_err() || on.as_bool()
}

/// Something that moves was just painted. Starts the clock if it is not
/// running; does nothing when the system has animations off.
pub fn wants_ticks() {
    if !animations_on() {
        return;
    }
    WANTED.with(|w| w.set(true));
    TICKER.with(|t| {
        // absence: means it was not reached -- the clock was already
        // running, or the system has animations off (the return above).
        if t.get() == 0 {
            let id = unsafe { SetTimer(None, 0, TICK_MS, Some(tick)) };
            t.set(id);
            // process-wide: one clock for every window's glyphs
            plogf!("[control-room] animation clock started (timer {})", id);
        }
    });
}

/// Seconds on the animation clock, for `pulse::opacity` and
/// `pulse::spin_step`.
pub fn clock() -> f64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64()
}

unsafe extern "system" fn tick(_hwnd: HWND, _msg: u32, id: usize, _time: u32) {
    if !WANTED.with(|w| w.replace(false)) {
        // Nobody painted anything that moves since the last tick.
        let _ = unsafe { KillTimer(None, id) };
        TICKER.with(|t| t.set(0));
        // process-wide: one clock for every window's glyphs
        plogf!("[control-room] animation clock stopped: nothing on screen moves");
        return;
    }
    redraw_everything();
    crate::control_room::tick();
}
