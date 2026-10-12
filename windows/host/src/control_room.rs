//! The control room's panel: the one window inside the control room's tab.
//!
//! **This file paints and passes things on. It works nothing out.** What is
//! drawn, where, in which face, weight and colour is
//! `polter_control_room::scene` -- a list of rectangles, words and glyphs --
//! and everything below is the walk over that list into GDI. Which row a
//! click lands on is `ListLayout::row_at`; where the arrow keys go is
//! `list::move_selection`; when looking at a group counts as having seen it
//! is `act::SeenMarker`. The host cannot be run off Windows, so anything
//! here that could be wrong without looking wrong belongs in that crate,
//! where it has tests. `tools/control-room-hosts-do-not-decide.py` reads
//! this file for a row being compared, counted or sorted.
//!
//! **A child window of the frame, like a pane, and not a surface.** The tab
//! model holds it as `tabs::Body::ControlRoom`; `tabs::layout` places it
//! over the content area when its tab is in front and hides it otherwise,
//! and `tabs::focus_active` gives it the keyboard. There is at most one in
//! the application (`tabs::control_rooms`).
//!
//! **Main thread only**: every entry here is a window procedure or is called
//! from one, so the state is a `thread_local` and there is no lock.
//!
//! # Not done in this file yet
//!
//!  * **UI Automation reaches the rows and nothing else** (`uia.rs`): each
//!    group is a list item with what it says and whether it is selected.
//!    The headers, the time band and the right side are not in the tree,
//!    and no event is raised when the selection or a row changes.
//!  * **A supervisor in another window is not shown here**, only pointed
//!    at: moving a terminal between frames is not built. One in a tab of
//!    this window is shown, by `tabs::layout` putting its pane where
//!    `scene::terminal_rect` says.
//!  * **No soft shadows, and no refraction on the chip**: GDI has no blur.
//!  * **The selection is kept for the life of the process only**, not across
//!    a restart.

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::Mutex;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{SetFocus, VK_DOWN, VK_RETURN, VK_UP};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_control_room::act::{self, Dwell, SeenMarker};
use polter_control_room::glyph::{self, Outline};
use polter_control_room::layout::{self, ListLayout, Rect, Room};
use polter_control_room::lend::{Detail, Effect, Event, Lending, Place};
use polter_control_room::list::{self, List, Selection};
use polter_control_room::look::{self, selection, side, status, Rgba, Theme};
use polter_control_room::pulse;
use polter_control_room::scene::{self, Align, Face, Item, Part, Piece, Side, Style, View};
use polter_control_room::snapshot::Shown;

use polter_split_tree::Rect as TreeRect;

use crate::control_room_source::{self as source, Data};
use crate::i18n::tr;
use crate::{plogf, wlogf};

const CLASS: PCWSTR = w!("PolterControlRoom");

/// The chip's slide: one frame every 16 ms while it is in the air.
const TIMER_SLIDE: usize = 1;
/// The wait before a selected, unseen group counts as seen. One shot.
const TIMER_SEEN: usize = 2;

/// How many mask pixels a device pixel is drawn from, each way. GDI's
/// shapes have hard edges; a shape drawn this much larger and averaged down
/// has soft ones.
const SS: i32 = 4;

struct Slide {
    from: Rect,
    to: Rect,
    started: std::time::Instant,
}

struct State {
    hwnd: isize,
    slide: Option<Slide>,
    seen: SeenMarker,
    dwell: Option<Dwell>,
    /// Which group is selected and whose choice that was
    /// (`list::Selection` has the whole rule).
    selection: Selection,
    /// An Alt chord was just performed here, so the `WM_SYSCHAR` that
    /// follows it is not an unknown menu mnemonic to beep at.
    swallow_syschar: bool,
    /// Which terminal is shown on the right, and what the right side says
    /// when none is (`polter_control_room::lend`).
    lending: Lending,
}

/// One row as a UI Automation client is told about it.
///
/// **Owned, and behind a lock rather than in the `thread_local` above**:
/// a provider is called on UI Automation's own thread, where this window's
/// state does not exist. The list is rewritten at the end of every paint,
/// so what a client reads is what is on screen.
#[derive(Clone)]
pub struct UiaRow {
    /// The group's name, which is its identity -- never its place.
    pub group: String,
    /// What the row says when read out (`scene::spoken`).
    pub name: String,
    pub selected: bool,
    /// In the panel's client pixels: left, top, right, bottom.
    pub rect: (i32, i32, i32, i32),
}

static UIA_ROWS: Mutex<Vec<UiaRow>> = Mutex::new(Vec::new());
/// The panel's window, for a provider's thread; 0 when there is none.
static PANEL: AtomicIsize = AtomicIsize::new(0);

/// Whether the panel there is now has finished a paint (`paint` says so in
/// the log, once a panel).
static PAINTED: AtomicBool = AtomicBool::new(false);
/// The group a client asked to have selected, on its way to the window's
/// thread.
static UIA_SELECT: Mutex<Option<String>> = Mutex::new(None);

/// Posted to the panel when `UIA_SELECT` has something in it.
const WM_ROOM_SELECT: u32 = WM_APP + 61;
/// Posted to the panel when what it shows on the right may have to change:
/// see `request_sync`.
const WM_ROOM_SYNC: u32 = WM_APP + 63;

/// Something happened that may change which terminal the control room
/// shows: its tab came to the front or left it, a pane or a tab was closed,
/// a tab was moved to another window.
///
/// **Posted, never done in place.** Most callers are inside `tabs::layout`
/// or a close path, and what this leads to is another layout. Safe from any
/// thread; nothing when there is no panel.
pub fn request_sync() {
    let panel = PANEL.load(Ordering::Acquire);
    if panel != 0 {
        let _ = unsafe { PostMessageW(Some(HWND(panel as *mut c_void)), WM_ROOM_SYNC, WPARAM(0), LPARAM(0)) };
    }
}

/// The terminal shown on the right took or gave up the keyboard: the frame
/// round it says which, so it is drawn again.
pub fn repaint() {
    if let Some(hwnd) = panel() {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
}

fn detail() -> Detail {
    STATE.with(|s| s.borrow().as_ref().map(|st| st.lending.detail().clone()).unwrap_or(Detail::NothingSelected))
}

/// Tell the lending what is selected now and where its supervisor is, and
/// do what it says: which pane of this window the layout shows on the
/// right, if any.
///
/// **Everything it is told is asked for fresh**: whether the panel is
/// showing, the selection, the supervisor the core names for it, and which
/// window that terminal is in. So it can be called after anything, any
/// number of times; with nothing changed the lending says "nothing to do".
fn sync_loan(hwnd: HWND) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let showing = unsafe { IsWindowVisible(hwnd) }.as_bool();
    let group = selection();
    let supervisor = source::with(|data| match data {
        Data::Ready(r) => group.as_deref().and_then(|id| r.list.row(id)).and_then(|row| row.steward.clone()),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    let place = match supervisor.as_deref().and_then(crate::tabs::place_of_terminal) {
        Some((home, _)) if home == frame => Place::Here,
        Some(_) => Place::Elsewhere,
        None => Place::Gone,
    };
    // Another tab of this window in front, or not shown yet: nothing is
    // borrowed, and the right side still says what is selected (task 1441
    // -- it used to be told "closing", and forgot).
    let event = if showing { Event::Selected { group, supervisor, place } } else { Event::OutOfSight { group, supervisor, place } };
    let effects = STATE.with(|s| s.borrow_mut().as_mut().map(|st| st.lending.handle(event)).unwrap_or_default());
    if effects.is_empty() {
        return;
    }
    for effect in &effects {
        match effect {
            // The pane never left its tab, so "back" is the layout no
            // longer putting it here; with its home gone there is nothing
            // to put anywhere.
            Effect::GiveBack { terminal, to_home, focus: _ } => {
                crate::tabs::set_lent(frame, None);
                wlogf!(frame, "[control-room] gave back terminal {} (home still there: {})", terminal, to_home);
            }
            Effect::Borrow(loan) => match crate::tabs::place_of_terminal(&loan.terminal) {
                Some((home, pane)) if home == frame => {
                    crate::tabs::set_lent(frame, Some(pane));
                    wlogf!(frame, "[control-room] showing terminal {} (pane {}) for {:?}", loan.terminal, pane, loan.group);
                }
                // It went between the asking and the doing; the next sync
                // says so.
                _ => wlogf!(frame, "[control-room] terminal {} for {:?} is not in this window any more; not shown", loan.terminal, loan.group),
            },
        }
    }
    if showing {
        crate::tabs::layout(frame);
    }
    unsafe {
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

/// The rows as they were last painted. Safe from any thread.
pub fn uia_rows() -> Vec<UiaRow> {
    UIA_ROWS.lock().map(|g| g.clone()).unwrap_or_default()
}

/// Where a group's row was last painted, in the panel's client pixels;
/// none for a group that is not listed. **The one place a client's
/// rectangle comes from**: it is the rectangle the paint drew the row in.
pub fn uia_row_rect(group: &str) -> Option<RECT> {
    let rows = UIA_ROWS.lock().ok()?;
    let r = rows.iter().find(|r| r.group == group)?;
    Some(RECT { left: r.rect.0, top: r.rect.1, right: r.rect.2, bottom: r.rect.3 })
}

/// The groups listed just before and just after `group`, by name. Found by
/// walking the list for the group itself, never by adding to a position:
/// the list is re-sent whenever anything changes, and a position is only
/// right for the list it was taken from.
pub fn uia_neighbours(group: &str) -> Option<(Option<String>, Option<String>)> {
    let rows = UIA_ROWS.lock().ok()?;
    let mut before: Option<&UiaRow> = None;
    let mut it = rows.iter();
    while let Some(row) = it.next() {
        if row.group == group {
            return Some((before.map(|r| r.group.clone()), it.next().map(|r| r.group.clone())));
        }
        before = Some(row);
    }
    None
}

/// Select a group for a UI Automation client. Safe from any thread: the
/// selecting happens on the window's own, by a posted message. False when
/// there is no panel to tell.
pub fn uia_select(group: &str) -> bool {
    let panel = PANEL.load(Ordering::Acquire);
    if panel == 0 {
        return false;
    }
    if let Ok(mut pending) = UIA_SELECT.lock() {
        *pending = Some(group.to_string());
    }
    unsafe { PostMessageW(Some(HWND(panel as *mut c_void)), WM_ROOM_SELECT, WPARAM(0), LPARAM(0)) }.is_ok()
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
    /// The group the person last selected, by name. **Outside `State` on
    /// purpose**: closing the control room's tab destroys the panel, and
    /// opening it again should find the same group selected. A selection
    /// the core made for them is not kept: a control room reopened with no
    /// choice of the person's own starts on the core's group again.
    static KEPT: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn selection() -> Option<String> {
    STATE.with(|s| s.borrow().as_ref().and_then(|st| st.selection.current().map(str::to_string)))
}

fn panel() -> Option<HWND> {
    STATE.with(|s| s.borrow().as_ref().map(|st| HWND(st.hwnd as *mut c_void)))
}

// ------------------------------------------------------------------ lifetime

/// Make the panel as a child of `frame`, hidden, at `bounds`. `tabs::layout`
/// shows it.
pub fn create(frame: HWND, hinst: HINSTANCE, bounds: TreeRect) -> Option<HWND> {
    if let Some(existing) = panel() {
        // The tab model is what says there is one; a panel with no tab is
        // this file's own leak, and making a second would hide it.
        wlogf!(frame, "[control-room] BUG: a panel already exists ({:?}); not making another", existing.0);
        return None;
    }
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            lpszClassName: CLASS,
            ..Default::default()
        };
        // Registering twice fails with "class already exists", which is the
        // second opening of the control room and not an error.
        let _ = RegisterClassExW(&wc);
        let made = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            CLASS,
            PCWSTR::null(),
            WS_CHILD | WS_CLIPSIBLINGS,
            bounds.x as i32,
            bounds.y as i32,
            (bounds.w as i32).max(1),
            (bounds.h as i32).max(1),
            Some(frame),
            None,
            Some(hinst),
            None,
        );
        let hwnd = match made {
            Ok(h) => h,
            Err(e) => {
                wlogf!(frame, "[control-room] CreateWindowExW failed: {e:?}");
                return None;
            }
        };
        PANEL.store(hwnd.0 as isize, Ordering::Release);
        PAINTED.store(false, Ordering::Release);
        let kept = KEPT.with(|k| k.borrow().clone());
        STATE.with(|s| {
            *s.borrow_mut() = Some(State {
                hwnd: hwnd.0 as isize,
                slide: None,
                seen: SeenMarker::default(),
                dwell: None,
                selection: Selection::opened(kept),
                swallow_syschar: false,
                lending: Lending::default(),
            })
        });
        // The snapshot there already is, if there is one, is this control
        // room's first: a group that went away while it was closed is
        // dropped, and with nothing selected it starts where the core says.
        take_snapshot();
        arm_seen(hwnd);
        Some(hwnd)
    }
}

/// Destroy the panel. Its state goes in `WM_DESTROY`, so that a panel
/// destroyed with its parent frame is forgotten the same way.
pub fn destroy(hwnd: HWND) {
    unsafe {
        let _ = DestroyWindow(hwnd);
    }
}

/// A new snapshot is in `control_room_source`.
pub fn snapshot_changed() {
    let Some(hwnd) = panel() else { return };
    take_snapshot();
    // A row that stops while the person is on it is seen like any other:
    // the wait starts when the core first says "not looked at", and a row
    // that was already unseen is left alone, or every list would start the
    // wait over (`SeenMarker::list_changed`; a wait already running is
    // never cut short by this).
    list_changed(hwnd);
    // The supervisor the core names may have changed, or gone.
    sync_loan(hwnd);
    unsafe {
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

/// The animation clock ticked (`control_room_source`).
pub fn tick() {
    let Some(hwnd) = panel() else { return };
    unsafe {
        if IsWindowVisible(hwnd).as_bool() {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }
}

/// Tell the selection about the snapshot there is now. With none that can
/// be read there is nothing to check it against, and it stands.
fn take_snapshot() {
    source::with(|data| match data {
        Data::Ready(r) => STATE.with(|s| {
            if let Some(st) = s.borrow_mut().as_mut() {
                st.selection.snapshot(&r.list, r.snapshot.open_on.as_deref());
            }
        }),
        Data::NotYet => {}
        Data::Unreadable(_) => {}
    });
}

// ------------------------------------------------------------------ geometry

struct Geometry {
    scale: f64,
    room: Room,
}

fn geometry(hwnd: HWND) -> Geometry {
    let scale = unsafe { GetDpiForWindow(hwnd) }.max(96) as f64 / 96.0;
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    Geometry { scale, room: Room::new(rc.right as f64 / scale, rc.bottom as f64 / scale) }
}

fn dark() -> bool {
    // The system's own setting; a configured window theme is not read yet.
    crate::shot::appearance() == "dark"
}

/// Whether the control room is what the person is looking at: its panel is
/// showing, and its window is the one in front.
fn in_front(hwnd: HWND) -> bool {
    unsafe { IsWindowVisible(hwnd).as_bool() && GetForegroundWindow() == GetAncestor(hwnd, GA_ROOT) }
}

// ----------------------------------------------------------------- selecting

/// Where the chip is right now, in the panel's points.
fn chip_now(at: &ListLayout, selected: Option<&str>) -> (Option<Rect>, f64) {
    let rest = at.chip(selected);
    STATE.with(|s| {
        let st = s.borrow();
        match st.as_ref().and_then(|st| st.slide.as_ref()) {
            Some(slide) => {
                let t = slide.started.elapsed().as_secs_f64();
                // In the air for the first half of the way, as on macOS.
                let lift = if t < selection::SPRING_PERIOD / 2.0 { 1.0 } else { 0.0 };
                (Some(layout::chip_between(slide.from, slide.to, t)), lift)
            }
            None => (rest, 0.0),
        }
    })
}

fn select(hwnd: HWND, id: Option<String>) {
    if id == selection() {
        // The same row again changes nothing on the left. The right side is
        // still asked: with nothing to do it does nothing, and a row that
        // was lit with the right side behind it (task 1441) could not be
        // brought up to date by clicking it, which is the first thing a
        // person tries.
        sync_loan(hwnd);
        return;
    }
    let g = geometry(hwnd);
    // Both ends of the slide, from the one layout the list has now.
    let ends = source::with(|data| match data {
        Data::Ready(r) => {
            let at = list_layout(hwnd, &r.list, g.room.panel.h);
            let from = chip_now(&at, selection().as_deref()).0;
            Some((from, at.chip(id.as_deref())))
        }
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    // The person's own choice, and what a reopened control room starts on.
    KEPT.with(|k| *k.borrow_mut() = id.clone());
    STATE.with(|s| {
        if let Some(st) = s.borrow_mut().as_mut() {
            st.selection.choose(id.clone());
        }
    });
    let slides = match ends {
        Some((Some(from), Some(to))) if source::animations_on() => Some(Slide { from, to, started: std::time::Instant::now() }),
        _ => None,
    };
    let sliding = slides.is_some();
    STATE.with(|s| {
        if let Some(st) = s.borrow_mut().as_mut() {
            st.slide = slides;
        }
    });
    unsafe {
        if sliding {
            SetTimer(Some(hwnd), TIMER_SLIDE, 16, None);
        } else {
            let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
        }
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
    wlogf!(unsafe { GetAncestor(hwnd, GA_ROOT) }, "[control-room] selected {:?}", id);
    arm_seen(hwnd);
    // Another group's supervisor on the right; the keyboard stays here.
    sync_loan(hwnd);
}

/// Tell the marker what is selected now, and start its wait if it asks for
/// one.
fn arm_seen(hwnd: HWND) {
    // A group the core selected for the person is on screen and is not a
    // look: the marker is told nothing is selected until they choose it.
    let selected = STATE
        .with(|s| s.borrow().as_ref().and_then(|st| st.selection.is_a_look().then(|| st.selection.current().map(str::to_string))))
        .flatten();
    let dwell = source::with(|data| {
        let row = match data {
            Data::Ready(r) => selected.as_deref().and_then(|id| r.list.row(id)),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        };
        STATE.with(|s| s.borrow_mut().as_mut().and_then(|st| st.seen.selection_changed(row)))
    });
    let waits = dwell.is_some();
    STATE.with(|s| {
        if let Some(st) = s.borrow_mut().as_mut() {
            st.dwell = dwell;
        }
    });
    unsafe {
        if waits {
            SetTimer(Some(hwnd), TIMER_SEEN, (selection::SEEN_AFTER * 1000.0) as u32, None);
        } else {
            let _ = KillTimer(Some(hwnd), TIMER_SEEN);
        }
    }
}

/// A new list has arrived: tell the marker the selected row as it is now,
/// and start a wait if that is news.
fn list_changed(hwnd: HWND) {
    let selected = STATE
        .with(|s| s.borrow().as_ref().and_then(|st| st.selection.is_a_look().then(|| st.selection.current().map(str::to_string))))
        .flatten();
    let dwell = source::with(|data| {
        let row = match data {
            Data::Ready(r) => selected.as_deref().and_then(|id| r.list.row(id)),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        };
        STATE.with(|s| s.borrow_mut().as_mut().and_then(|st| st.seen.list_changed(row)))
    });
    // None is "nothing new": whatever wait is running goes on.
    let Some(dwell) = dwell else { return };
    STATE.with(|s| {
        if let Some(st) = s.borrow_mut().as_mut() {
            st.dwell = Some(dwell);
        }
    });
    unsafe {
        SetTimer(Some(hwnd), TIMER_SEEN, (selection::SEEN_AFTER * 1000.0) as u32, None);
    }
}

/// The wait is over: send `seen` if the marker still says so.
fn seen_due(hwnd: HWND) {
    unsafe {
        let _ = KillTimer(Some(hwnd), TIMER_SEEN);
    }
    let front = in_front(hwnd);
    let request = STATE.with(|s| {
        let mut st = s.borrow_mut();
        let st = st.as_mut()?;
        let dwell = st.dwell.take()?;
        let request = st.seen.due(&dwell, front).and_then(|a| act::encode(&a));
        request.map(|r| (r, dwell.group))
    });
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    match request {
        Some((request, group)) => match source::act(&request) {
            Ok(()) => wlogf!(frame, "[control-room] seen sent for {:?}", group),
            Err(name) => {
                let refusal = act::Refusal::parse(&name);
                wlogf!(frame, "[control-room] seen for {:?} refused: {} ({:?})", group, name, refusal);
                if refusal.means_look_again() {
                    source::look_again();
                }
            }
        },
        // not-gated: the condition is the event -- the selection moved on,
        // or the control room was not in front when the wait ended.
        None => wlogf!(frame, "[control-room] seen not sent: selection moved, or not in front (in_front={})", front),
    }
}

/// "Go to its tab" for the selected group.
fn go_to_supervisor(hwnd: HWND) {
    let selected = selection();
    let steward = source::with(|data| match data {
        Data::Ready(r) => selected.as_deref().and_then(|id| r.list.row(id)).and_then(|row| row.steward.clone()),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    match steward {
        Some(key) => {
            let went = crate::tabs::go_to_terminal(&key);
            wlogf!(frame, "[control-room] go to supervisor {} of {:?} -> {}", key, selected, went);
        }
        None => wlogf!(frame, "[control-room] go to supervisor: {:?} has none, or nothing is selected", selected),
    }
}

// -------------------------------------------------------------------- wndproc

fn point(lp: LPARAM) -> (i32, i32) {
    ((lp.0 & 0xffff) as i16 as i32, ((lp.0 >> 16) & 0xffff) as i16 as i32)
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_ERASEBKGND => LRESULT(1),
        // The panel draws its rows itself and has no child windows, so the
        // default provider has nothing to list: a client would find the
        // window and no rows in it.
        WM_GETOBJECT => match crate::uia::on_get_object_control_room(hwnd, wp, lp) {
            Some(r) => r,
            None => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
        },
        WM_ROOM_SELECT => {
            let wanted = UIA_SELECT.lock().ok().and_then(|mut p| p.take());
            // Only a group that is listed now: the client's list may be a
            // snapshot old.
            let listed = wanted.filter(|g| {
                source::with(|data| match data {
                    Data::Ready(r) => r.list.row(g).is_some(),
                    Data::NotYet => false,
                    Data::Unreadable(_) => false,
                })
            });
            match listed {
                Some(group) => select(hwnd, Some(group)),
                None => wlogf!(unsafe { GetAncestor(hwnd, GA_ROOT) }, "[control-room] a UI Automation client asked for a group that is not listed; nothing selected"),
            }
            LRESULT(0)
        }
        // Shown or hidden: its tab came to the front or left it. Posted,
        // because this arrives from inside `tabs::layout`.
        WM_SHOWWINDOW => {
            request_sync();
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // **And the way it is actually shown.** `tabs::layout` hides the
        // panel with `ShowWindow`, which sends the message above, and shows
        // it with `SetWindowPos(.., SWP_SHOWWINDOW)`, which does not: the
        // panel heard that it had gone and never that it was back (task
        // 1441: back from another tab, and on first opening, the right side
        // said "select a group" beside a lit row). This message comes for
        // both, and says which in its flags.
        WM_WINDOWPOSCHANGED => {
            let pos = lp.0 as *const WINDOWPOS;
            if !pos.is_null() {
                let flags = unsafe { (*pos).flags };
                if flags.contains(SWP_SHOWWINDOW) || flags.contains(SWP_HIDEWINDOW) {
                    request_sync();
                }
            }
            // `DefWindowProcW` is what turns this into `WM_SIZE`.
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_ROOM_SYNC => {
            sync_loan(hwnd);
            LRESULT(0)
        }
        WM_PAINT => {
            paint(hwnd);
            LRESULT(0)
        }
        WM_SIZE => {
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            unsafe {
                let _ = SetFocus(Some(hwnd));
            }
            let (x, y) = point(lp);
            click(hwnd, x, y);
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let key = wp.0 as u16;
            let step = if key == VK_UP.0 {
                Some(-1)
            } else if key == VK_DOWN.0 {
                Some(1)
            } else {
                None
            };
            if let Some(step) = step {
                let current = selection();
                let next = source::with(|data| match data {
                    Data::Ready(r) => list::move_selection(&r.list, current.as_deref(), step).map(str::to_string),
                    Data::NotYet => None,
                    Data::Unreadable(_) => None,
                });
                if next.is_some() {
                    select(hwnd, next);
                }
                return LRESULT(0);
            }
            if key == VK_RETURN.0 {
                go_to_supervisor(hwnd);
                return LRESULT(0);
            }
            // Not the list's: a binding, perhaps (`control_room_keys.rs`).
            if crate::control_room_keys::handle(hwnd, wp, lp) {
                return LRESULT(0);
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // A key with Alt held arrives as this, and the default bindings for
        // "go to tab N" are Alt chords. **One not performed goes on to
        // `DefWindowProcW`**: Alt+F4 and the window menu live there.
        WM_SYSKEYDOWN => {
            if crate::control_room_keys::handle(hwnd, wp, lp) {
                STATE.with(|s| {
                    if let Some(st) = s.borrow_mut().as_mut() {
                        st.swallow_syschar = true;
                    }
                });
                return LRESULT(0);
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // The character half of an Alt chord this window just performed.
        // Left to `DefWindowProcW` it is an unknown menu mnemonic, and that
        // is a beep.
        WM_SYSCHAR => {
            let swallow = STATE.with(|s| s.borrow_mut().as_mut().is_some_and(|st| std::mem::take(&mut st.swallow_syschar)));
            if swallow {
                return LRESULT(0);
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_SETFOCUS => {
            // The one TSF document manager of this thread belongs to the
            // terminals; hand it back while a window that takes no text has
            // the keyboard (`palette.rs` has the contract). A pane's own
            // `WM_SETFOCUS` takes it again.
            crate::ime_focus(false);
            // The keyboard is on the list now, not in the terminal shown
            // beside it; the frame round that terminal says so.
            crate::tabs::keyboard_on_the_list(unsafe { GetAncestor(hwnd, GA_ROOT) });
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            // Coming to the front with a row already selected is a look.
            let waiting = STATE.with(|s| s.borrow().as_ref().is_some_and(|st| st.dwell.is_some()));
            if !waiting {
                arm_seen(hwnd);
            }
            LRESULT(0)
        }
        WM_TIMER => {
            match wp.0 {
                TIMER_SLIDE => {
                    let settled = STATE.with(|s| {
                        let mut st = s.borrow_mut();
                        let Some(st) = st.as_mut() else { return true };
                        let done = st.slide.as_ref().is_none_or(|sl| layout::chip_settled(sl.started.elapsed().as_secs_f64()));
                        if done {
                            st.slide = None;
                        }
                        done
                    });
                    unsafe {
                        if settled {
                            let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
                        }
                        let _ = InvalidateRect(Some(hwnd), None, false);
                    }
                }
                TIMER_SEEN => seen_due(hwnd),
                _ => {}
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe {
                let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
                let _ = KillTimer(Some(hwnd), TIMER_SEEN);
            }
            STATE.with(|s| {
                let mut st = s.borrow_mut();
                if st.as_ref().is_some_and(|st| st.hwnd == hwnd.0 as isize) {
                    *st = None;
                }
            });
            // Whatever was shown on the right is no longer shown: it never
            // left its own tab, so that is all "giving it back" is.
            crate::tabs::set_lent(unsafe { GetAncestor(hwnd, GA_ROOT) }, None);
            // A client holding a row of a panel that is gone is told it is
            // gone, not handed the last list.
            let _ = PANEL.compare_exchange(hwnd.0 as isize, 0, Ordering::AcqRel, Ordering::Acquire);
            if let Ok(mut rows) = UIA_ROWS.lock() {
                rows.clear();
            }
            // process-wide: the panel is one per process
            plogf!("[control-room] panel destroyed");
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

fn click(hwnd: HWND, x: i32, y: i32) {
    let g = geometry(hwnd);
    let (px, py) = (x as f64 / g.scale, y as f64 / g.scale);
    // A row of the list.
    let row = source::with(|data| match data {
        Data::Ready(r) => list_layout(hwnd, &r.list, g.room.panel.h)
            .row_at(px - g.room.panel.x, py - g.room.panel.y)
            .map(str::to_string),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    if row.is_some() {
        select(hwnd, row);
        return;
    }
    // "Go to its tab" on the right.
    let detail = detail();
    let selected = selection();
    let theme = look::theme(dark());
    let go = source::with(|data| {
        let row = match data {
            Data::Ready(r) => selected.as_deref().and_then(|id| r.list.row(id)),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        };
        scene::build_right(&detail, row, g.room.right.w, g.room.right.h, theme, g.scale, false, &|s| tr(s)).go
    });
    if let Some(go) = go {
        let (rx, ry) = (px - g.room.right.x, py - g.room.right.y);
        if rx >= go.x && rx < go.x + go.w && ry >= go.y && ry < go.y + go.h {
            go_to_supervisor(hwnd);
        }
    }
}

// --------------------------------------------------------------------- paint

fn rgb(c: Rgba) -> COLORREF {
    COLORREF((c.r as u32) | ((c.g as u32) << 8) | ((c.b as u32) << 16))
}

/// Points to device pixels, from an origin in pixels.
#[derive(Clone, Copy)]
struct Px {
    scale: f64,
    ox: i32,
    oy: i32,
}

impl Px {
    fn len(&self, v: f64) -> i32 {
        (v * self.scale).round() as i32
    }
    fn rect(&self, r: Rect) -> RECT {
        let left = self.ox + self.len(r.x);
        let top = self.oy + self.len(r.y);
        RECT { left, top, right: self.ox + self.len(r.x + r.w), bottom: self.oy + self.len(r.y + r.h) }
    }
}

/// The fonts one paint uses, made as they are asked for and deleted when it
/// ends.
struct Fonts {
    dpi: i32,
    made: Vec<((i32, i32, bool), HFONT)>,
}

impl Fonts {
    fn get(&mut self, style: &Style) -> HFONT {
        let mono = match style.face {
            Face::Ui => false,
            Face::Mono => true,
        };
        let key = (style.size.round() as i32, style.weight.round() as i32, mono);
        if let Some((_, f)) = self.made.iter().find(|(k, _)| *k == key) {
            return *f;
        }
        // `uifont::make` never goes below the system's menu font at this
        // DPI, whatever size is asked for.
        let face = if mono { w!("Consolas") } else { w!("Segoe UI") };
        let f = crate::uifont::make(self.dpi, key.0, key.1, face);
        self.made.push((key, f));
        f
    }
}

impl Drop for Fonts {
    fn drop(&mut self) {
        for (_, f) in self.made.drain(..) {
            unsafe {
                let _ = DeleteObject(f.into());
            }
        }
    }
}

fn paint(hwnd: HWND) {
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(hwnd, &mut ps) };
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    if rc.right <= 0 || rc.bottom <= 0 {
        let _ = unsafe { EndPaint(hwnd, &ps) };
        return;
    }
    let g = geometry(hwnd);
    let theme = look::theme(dark());
    let selected = selection();
    let t = source::clock();
    let translate = |s: &str| tr(s);
    let detail = detail();
    let in_terminal = crate::tabs::keyboard_in_lent(unsafe { GetAncestor(hwnd, GA_ROOT) });

    // Everything is drawn once, into memory, and blitted: the chip's slide
    // repaints sixty times a second.
    unsafe {
        let mem = CreateCompatibleDC(Some(hdc));
        let bmp = CreateCompatibleBitmap(hdc, rc.right, rc.bottom);
        let old = SelectObject(mem, bmp.into());
        SetBkMode(mem, TRANSPARENT);
        fill_rect(mem, &rc, theme.window_base);
        let mut fonts = Fonts { dpi: (g.scale * 96.0).round() as i32, made: Vec::new() };

        // The list panel.
        let at = Px { scale: g.scale, ox: (g.room.panel.x * g.scale).round() as i32, oy: (g.room.panel.y * g.scale).round() as i32 };
        // With no list to draw there are no rows to tell a client about.
        let readable = source::with(|data| match data {
            Data::Ready(_) => true,
            Data::NotYet => false,
            Data::Unreadable(_) => false,
        });
        if !readable {
            if let Ok(mut rows) = UIA_ROWS.lock() {
                rows.clear();
            }
        }
        let (items, right) = source::with(|data| match data {
            Data::Ready(r) => {
                let list: &List = &r.list;
                let lay = list_layout(hwnd, list, g.room.panel.h);
                let (chip, lift) = chip_now(&lay, selected.as_deref());
                let window = crate::tabs::window(GetAncestor(hwnd, GA_ROOT)).map(|w| polter_control_room::rules::key(w.id));
                let pulsing = pulse::pulsing_row(&r.snapshot.pulses, window.as_deref(), None);
                let view = View { theme, scale: g.scale, selection: selected.as_deref(), chip, lift, pulsing };
                let row = selected.as_deref().and_then(|id| list.row(id));
                // What a UI Automation client is told, from the same list and
                // the same layout this paint draws.
                let spoken: Vec<UiaRow> = list
                    .rows()
                    .filter_map(|r| {
                        let rc = at.rect(lay.chip(Some(&r.id))?);
                        Some(UiaRow {
                            group: r.id.clone(),
                            name: scene::spoken(r, &translate),
                            selected: selected.as_deref() == Some(r.id.as_str()),
                            rect: (rc.left, rc.top, rc.right, rc.bottom),
                        })
                    })
                    .collect();
                if let Ok(mut rows) = UIA_ROWS.lock() {
                    *rows = spoken;
                }
                (
                    scene::build(list, &lay, &view, &translate),
                    scene::build_right(&detail, row, g.room.right.w, g.room.right.h, theme, g.scale, in_terminal, &translate),
                )
            }
            Data::NotYet => (
                scene::build_message(side::WIDTH, g.room.panel.h, theme, g.scale, tr(scene::msg::NOT_YET)),
                scene::build_right(&detail, None, g.room.right.w, g.room.right.h, theme, g.scale, in_terminal, &translate),
            ),
            Data::Unreadable(why) => (
                scene::build_message(
                    side::WIDTH,
                    g.room.panel.h,
                    theme,
                    g.scale,
                    list::fill(&tr(scene::msg::UNREADABLE), why),
                ),
                scene::build_right(&detail, None, g.room.right.w, g.room.right.h, theme, g.scale, in_terminal, &translate),
            ),
        });
        paint_items(mem, at, &items, &mut fonts, t);
        if scene::moves(&items) {
            source::wants_ticks();
        }

        // The right side.
        if g.room.right.w > 0.0 {
            let at = Px { scale: g.scale, ox: (g.room.right.x * g.scale).round() as i32, oy: (g.room.right.y * g.scale).round() as i32 };
            paint_items(mem, at, &right.items, &mut fonts, t);
        }

        drop(fonts);
        // Once a panel: the last thing a paint does before it is on screen.
        // A panel that opened and never says this died drawing (task 1439
        // had nothing after `opened as`, and four runs to learn that much).
        // absence: depends -- after an `opened as` with no line of this
        // kind, the panel never finished a paint; on any later paint of the
        // same panel the silence is only "not the first".
        if !PAINTED.swap(true, Ordering::AcqRel) {
            wlogf!(
                GetAncestor(hwnd, GA_ROOT),
                "[control-room] first paint drawn: {} item(s) in the list, {} on the right, {}x{}",
                items.len(),
                right.items.len(),
                rc.right,
                rc.bottom
            );
        }
        let _ = BitBlt(hdc, 0, 0, rc.right, rc.bottom, Some(mem), 0, 0, SRCCOPY);
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        let _ = EndPaint(hwnd, &ps);
    }
}

/// Paint a scene that is not the control room's own: the frames round the
/// panes of a split tab (`pane_frames.rs`), into `dc`, with the scene's
/// origin at `ox, oy` in its pixels. Here because this file is the one
/// place words are handed to the system (`draw_text`).
///
/// # Safety
/// `dc` must be a live device context.
pub(crate) unsafe fn paint_scene(dc: HDC, scale: f64, ox: i32, oy: i32, items: &[Item]) {
    let mut fonts = Fonts { dpi: (scale * 96.0).round() as i32, made: Vec::new() };
    unsafe {
        SetBkMode(dc, TRANSPARENT);
        paint_items(dc, Px { scale, ox, oy }, items, &mut fonts, source::clock());
    }
}

unsafe fn fill_rect(dc: HDC, r: &RECT, color: Rgba) {
    unsafe {
        let brush = CreateSolidBrush(rgb(color));
        FillRect(dc, r, brush);
        let _ = DeleteObject(brush.into());
    }
}

unsafe fn paint_items(dc: HDC, at: Px, items: &[Item], fonts: &mut Fonts, t: f64) {
    for item in items {
        match item {
            Item::Fill { rect, color } => {
                let mut r = at.rect(*rect);
                // A line thinner than a pixel is still a pixel.
                r.bottom = r.bottom.max(r.top + 1);
                unsafe { fill_rect(dc, &r, *color) };
            }
            Item::Round { rect, radius, color, edge } => unsafe {
                round(dc, at.rect(*rect), at.len(*radius), *color, *edge)
            },
            Item::Text { rect, text, style, align } => unsafe {
                let r = at.rect(*rect);
                let how = match align {
                    Align::Left => DT_LEFT,
                    Align::Right => DT_RIGHT,
                    Align::Centre => DT_CENTER,
                };
                draw_text(dc, fonts.get(style), style.color, text, r, how | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
            },
            Item::Line { rect, parts } => unsafe { paint_line(dc, at, at.rect(*rect), parts, fonts, t) },
            // Running text, a line at a time: GDI's own wrapping sets lines
            // at the font's height, and the row was laid out at the
            // design's (`ASK_LINE_HEIGHT`). Where the lines break is
            // `layout::block_lines`, with this font's own measurement --
            // the same one the row's height came from (`list_layout`).
            Item::Block { rect, text, style, lines } => unsafe {
                let r = at.rect(*rect);
                let font = fonts.get(style);
                let width = r.right - r.left;
                let shown = layout::block_lines(text, *lines, &|s| fit_chars(dc, font, s, width));
                let each = (r.bottom - r.top) / (*lines).max(1) as i32;
                for (i, line) in shown.iter().enumerate() {
                    let top = r.top + i as i32 * each;
                    let box_ = RECT { left: r.left, top, right: r.right, bottom: top + each };
                    // Only the last can be longer than the box: it carries
                    // everything that did not fit, and is cut at its end.
                    draw_text(dc, font, style.color, line, box_, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
                }
            },
        }
    }
}

/// The one place this file hands words to the system to be drawn.
///
/// **Words that are not there are not handed over** -- `scene::draws`. The
/// call takes a counted slice, an empty string is a count of 0 and a pointer
/// to nothing, and `USER32` on Windows 11 build 26200 reads through that
/// pointer: an access violation inside `USER32.dll`, in the middle of
/// `WM_PAINT`, with nothing in the log after the line that opened the panel.
/// That is how the control room died on its first real machine (task 1439,
/// four openings out of four), as soon as a row had a status the core gives
/// no word for, or a wait it gives no reason for. The screenshot overlay
/// died of the same thing before it (task 1199, `shot.rs`).
///
/// `windows/tools/control-room-hands-user32-no-empty-text.py` holds this
/// file to it: `DrawTextW` and `GetTextExtentPoint32W` appear here and in
/// `text_width`, behind the question, and nowhere else.
unsafe fn draw_text(dc: HDC, font: HFONT, color: Rgba, text: &str, mut r: RECT, how: DRAW_TEXT_FORMAT) {
    if !scene::draws(text) {
        return;
    }
    unsafe {
        let old = SelectObject(dc, font.into());
        SetTextColor(dc, rgb(color));
        let mut wide: Vec<u16> = text.encode_utf16().collect();
        DrawTextW(dc, &mut wide, &mut r, how);
        SelectObject(dc, old);
    }
}

/// How many characters from the start of `text` fit in `width` pixels of
/// `font`. Nothing is asked about nothing (`draw_text`).
unsafe fn fit_chars(dc: HDC, font: HFONT, text: &str, width: i32) -> usize {
    if !scene::draws(text) {
        return 0;
    }
    unsafe {
        let old = SelectObject(dc, font.into());
        let wide: Vec<u16> = text.encode_utf16().collect();
        let mut fit = 0i32;
        let mut size = SIZE::default();
        // A pointer and a count, as everywhere here: `text` is not empty
        // (asked above), so the pointer is to something.
        let _ = GetTextExtentExPointW(dc, PCWSTR(wide.as_ptr()), wide.len() as i32, width.max(0), Some(&mut fit), None, &mut size);
        SelectObject(dc, old);
        // The answer is in UTF-16 units; the question was in characters.
        let mut units = 0usize;
        let mut chars = 0usize;
        for c in text.chars() {
            units += c.len_utf16();
            if units > fit.max(0) as usize {
                break;
            }
            chars += 1;
        }
        chars
    }
}

/// The list's layout, with what each waiting row waits on measured in the
/// fonts it will be drawn in, at this window's scale: how many lines a step
/// takes is how many `layout::wrap` makes of it with `fit_chars`. **Every
/// place that needs the layout asks here** -- the paint, the slide's two
/// ends, the click, the rows a screen reader is told -- so that they agree
/// about how high a row is.
fn list_layout(hwnd: HWND, list: &List, height: f64) -> ListLayout {
    let scale = unsafe { GetDpiForWindow(hwnd) }.max(96) as f64 / 96.0;
    let width = (layout::ask_width() * scale).round() as i32;
    let mut fonts = Fonts { dpi: (scale * 96.0).round() as i32, made: Vec::new() };
    let face = |code: bool| Style {
        size: look::font::BODY,
        weight: look::font::WEIGHT_BODY,
        face: if code { Face::Mono } else { Face::Ui },
        color: Rgba { r: 0, g: 0, b: 0, a: 1.0 },
    };
    let (ui, mono) = (fonts.get(&face(false)), fonts.get(&face(true)));
    unsafe {
        let dc = GetDC(Some(hwnd));
        let lay = ListLayout::measured(list, height, &|text, code| {
            let font = if code { mono } else { ui };
            layout::wrap(text, &|s| fit_chars(dc, font, s, width)).len()
        });
        ReleaseDC(Some(hwnd), dc);
        lay
    }
}

/// How wide `text` is in `font`. Nothing is as wide as nothing, and is not
/// asked about (`draw_text`).
unsafe fn text_width(dc: HDC, font: HFONT, text: &str) -> i32 {
    if !scene::draws(text) {
        return 0;
    }
    unsafe {
        let old = SelectObject(dc, font.into());
        let wide: Vec<u16> = text.encode_utf16().collect();
        let mut size = SIZE::default();
        let _ = GetTextExtentPoint32W(dc, &wide, &mut size);
        SelectObject(dc, old);
        size.cx
    }
}

unsafe fn part_width(dc: HDC, at: Px, part: &Part, fonts: &mut Fonts) -> i32 {
    match &part.piece {
        Piece::Words { text, style } => unsafe { text_width(dc, fonts.get(style), text) },
        Piece::Glyph { size, .. } => at.len(*size),
    }
}

unsafe fn paint_piece(dc: HDC, at: Px, piece: &Piece, r: RECT, fonts: &mut Fonts, t: f64, ellipsis: bool) {
    match piece {
        Piece::Words { text, style } => unsafe {
            let cut = if ellipsis { DT_END_ELLIPSIS } else { DT_NOCLIP };
            draw_text(dc, fonts.get(style), style.color, text, r, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | cut);
        },
        Piece::Glyph { shown, color, size, pulses } => {
            let side = at.len(*size);
            let top = r.top + (r.bottom - r.top - side) / 2;
            let opacity = if *pulses && source::animations_on() { pulse::opacity(t) } else { 1.0 };
            unsafe { draw_glyph(dc, r.left, top, side, *shown, *color, opacity) };
        }
    }
}

/// One line of parts: the leading ones from the left, the trailing ones
/// from the right, and the rest in what is left between them.
unsafe fn paint_line(dc: HDC, at: Px, r: RECT, parts: &[Part], fonts: &mut Fonts, t: f64) {
    // Where the trailing parts begin: a leading part stops there. In a
    // line as wide as the list's rows it never gets that far; in the title
    // of a narrow pane a long name would otherwise be written over the
    // pane's state. One that would is cut short with an ellipsis, and one
    // with no room at all is not drawn.
    let mut limit = r.right;
    for part in parts {
        match part.side {
            Side::Trail => limit -= unsafe { part_width(dc, at, part, fonts) } + at.len(part.gap),
            Side::Lead => {}
            Side::Rest => {}
        }
    }
    let mut lead = r.left;
    for part in parts {
        match part.side {
            Side::Lead => {
                lead += at.len(part.gap);
                let w = unsafe { part_width(dc, at, part, fonts) };
                let right = (lead + w).min(limit);
                if right > lead {
                    let box_ = RECT { left: lead, top: r.top, right, bottom: r.bottom };
                    unsafe { paint_piece(dc, at, &part.piece, box_, fonts, t, right < lead + w) };
                }
                lead += w;
            }
            Side::Trail => {}
            Side::Rest => {}
        }
    }
    let mut trail = r.right;
    for part in parts.iter().rev() {
        match part.side {
            Side::Trail => {
                let w = unsafe { part_width(dc, at, part, fonts) };
                let box_ = RECT { left: trail - w, top: r.top, right: trail, bottom: r.bottom };
                unsafe { paint_piece(dc, at, &part.piece, box_, fonts, t, false) };
                trail -= w + at.len(part.gap);
            }
            Side::Lead => {}
            Side::Rest => {}
        }
    }
    for part in parts {
        match part.side {
            Side::Rest => {
                let left = lead + at.len(part.gap);
                if trail > left {
                    let box_ = RECT { left, top: r.top, right: trail, bottom: r.bottom };
                    unsafe { paint_piece(dc, at, &part.piece, box_, fonts, t, true) };
                }
            }
            Side::Lead => {}
            Side::Trail => {}
        }
    }
}

/// A rounded rectangle. A small one is drawn with soft corners; a large one
/// (the panel itself) with GDI's own, because a mask that size is tens of
/// megabytes a paint and its corners sit on a ground nearly its own colour.
unsafe fn round(dc: HDC, r: RECT, radius: i32, color: Rgba, edge: Option<Rgba>) {
    let (w, h) = (r.right - r.left, r.bottom - r.top);
    if w <= 0 || h <= 0 {
        return;
    }
    const SOFT_LIMIT: i64 = 400_000;
    if (w as i64) * (h as i64) > SOFT_LIMIT {
        unsafe {
            let pen = CreatePen(PS_SOLID, 1, rgb(edge.unwrap_or(color)));
            let brush = CreateSolidBrush(rgb(color));
            let old_pen = SelectObject(dc, pen.into());
            let old_brush = SelectObject(dc, brush.into());
            let _ = RoundRect(dc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
            SelectObject(dc, old_pen);
            SelectObject(dc, old_brush);
            let _ = DeleteObject(pen.into());
            let _ = DeleteObject(brush.into());
        }
        return;
    }
    let d = radius * 2 * SS;
    unsafe {
        if let Some(edge) = edge {
            // The edge first, as the whole shape; the fill over it, one
            // device pixel in.
            blend(dc, r.left, r.top, w, h, edge, 1.0, &|m| {
                let _ = RoundRect(m, 0, 0, w * SS + 1, h * SS + 1, d, d);
            });
            let inner = ((radius - 1).max(0)) * 2 * SS;
            blend(dc, r.left, r.top, w, h, color, 1.0, &|m| {
                let _ = RoundRect(m, SS, SS, (w - 1) * SS + 1, (h - 1) * SS + 1, inner, inner);
            });
        } else {
            blend(dc, r.left, r.top, w, h, color, 1.0, &|m| {
                let _ = RoundRect(m, 0, 0, w * SS + 1, h * SS + 1, d, d);
            });
        }
    }
}

/// One status glyph, in a square `side` pixels across with its top left at
/// `x, y`. Also what a window tab draws (`strip.rs`).
///
/// # Safety
/// `dc` must be a live device context.
pub unsafe fn draw_glyph(dc: HDC, x: i32, y: i32, side: i32, shown: Shown, color: Rgba, opacity: f64) {
    let spin = if source::animations_on() { pulse::spin_step(source::clock()) } else { 0 };
    let shapes = glyph::shapes(shown, spin);
    if shapes.is_empty() || side <= 0 {
        return;
    }
    let unit = (side * SS) as f64 / status::ARTBOARD;
    let u = |v: f64| (v * unit).round() as i32;
    unsafe {
        blend(dc, x, y, side, side, color, opacity, &|m| {
            for shape in &shapes {
                let level = (shape.level.clamp(0.0, 1.0) * 255.0).round() as u32;
                let brush = CreateSolidBrush(COLORREF(level | (level << 8) | (level << 16)));
                let old = SelectObject(m, brush.into());
                match &shape.outline {
                    Outline::Polygon(points) => {
                        let pts: Vec<POINT> = points.iter().map(|(px, py)| POINT { x: u(*px), y: u(*py) }).collect();
                        let _ = Polygon(m, &pts);
                    }
                    Outline::RoundRect(rx, ry, rw, rh, rr) => {
                        let _ = RoundRect(m, u(*rx), u(*ry), u(rx + rw) + 1, u(ry + rh) + 1, u(*rr * 2.0), u(*rr * 2.0));
                    }
                    Outline::Ellipse(ex, ey, ew, eh) => {
                        let _ = Ellipse(m, u(*ex), u(*ey), u(ex + ew) + 1, u(ey + eh) + 1);
                    }
                }
                SelectObject(m, old);
                let _ = DeleteObject(brush.into());
            }
        });
    }
}

unsafe fn dib(w: i32, h: i32) -> Option<(HBITMAP, *mut u32)> {
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            // Top down, so row 0 is the top row.
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bits: *mut c_void = std::ptr::null_mut();
    let bmp = unsafe { CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0) }.ok()?;
    if bits.is_null() {
        unsafe {
            let _ = DeleteObject(bmp.into());
        }
        return None;
    }
    Some((bmp, bits as *mut u32))
}

/// Lay a shape over `dst` in one colour, with soft edges.
///
/// `draw` paints the shape into a mask `SS` times larger each way, in
/// greys: white is all of the colour, black none. The mask is averaged down
/// to coverage and blended. The brush is whatever `draw` selects; the pen is
/// none, and the default brush is white.
unsafe fn blend(dst: HDC, x: i32, y: i32, w: i32, h: i32, color: Rgba, opacity: f64, draw: &dyn Fn(HDC)) {
    if w <= 0 || h <= 0 {
        return;
    }
    unsafe {
        let (mw, mh) = (w * SS, h * SS);
        let Some((mask, mask_bits)) = dib(mw, mh) else { return };
        let Some((out, out_bits)) = dib(w, h) else {
            let _ = DeleteObject(mask.into());
            return;
        };
        let mdc = CreateCompatibleDC(None);
        let old_mask = SelectObject(mdc, mask.into());
        let old_pen = SelectObject(mdc, GetStockObject(NULL_PEN));
        let old_brush = SelectObject(mdc, GetStockObject(WHITE_BRUSH));
        draw(mdc);
        let _ = GdiFlush();
        SelectObject(mdc, old_brush);
        SelectObject(mdc, old_pen);

        let m = std::slice::from_raw_parts(mask_bits as *const u32, (mw * mh) as usize);
        let o = std::slice::from_raw_parts_mut(out_bits, (w * h) as usize);
        let full = (SS * SS * 255) as f64;
        let amount = opacity.clamp(0.0, 1.0) * color.a.clamp(0.0, 1.0);
        for py in 0..h {
            for px in 0..w {
                let mut sum = 0u32;
                for sy in 0..SS {
                    let row = ((py * SS + sy) * mw + px * SS) as usize;
                    for sx in 0..SS as usize {
                        sum += m[row + sx] & 0xff;
                    }
                }
                let a = sum as f64 / full * amount;
                // Premultiplied, as `AlphaBlend` wants it.
                let ch = |c: u8| (c as f64 * a).round() as u32;
                o[(py * w + px) as usize] =
                    (((a * 255.0).round() as u32) << 24) | (ch(color.r) << 16) | (ch(color.g) << 8) | ch(color.b);
            }
        }

        let odc = CreateCompatibleDC(None);
        let old_out = SelectObject(odc, out.into());
        let how = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
        let _ = AlphaBlend(dst, x, y, w, h, odc, 0, 0, w, h, how);
        SelectObject(odc, old_out);
        SelectObject(mdc, old_mask);
        let _ = DeleteDC(odc);
        let _ = DeleteDC(mdc);
        let _ = DeleteObject(out.into());
        let _ = DeleteObject(mask.into());
    }
}

/// The theme a window tab's glyph is drawn in. The strip is the same dark
/// colour whatever the system's setting, so it is the dark table's.
fn strip_theme() -> &'static Theme {
    look::theme(true)
}

/// Draw the status glyph of one window tab, ending at `right` in a strip
/// `sh` pixels high, and say where the tab's title must now end.
///
/// **What it draws is asked for, not worked out**: `tab_glyph` hands back
/// what `pulse::tab_status` and `pulse::draws_on_window_tab` said for this
/// tab of this window. A tab the snapshot does not list -- the control
/// room's own, or a terminal the core has not placed -- carries nothing,
/// and `right` comes back unchanged.
///
/// # Safety
/// `dc` must be a live device context.
pub unsafe fn draw_tab_glyph(dc: HDC, frame: HWND, tab: u64, showing: Option<u64>, right: i32, sh: i32, scale: f64) -> i32 {
    let Some(window) = crate::tabs::window(frame).map(|w| w.id) else {
        return right;
    };
    let Some((shown, pulses)) = source::tab_glyph(window, tab, showing) else {
        return right;
    };
    let side = (look::window_tab::GLYPH * scale).round() as i32;
    let left = right - side;
    let theme = strip_theme();
    let opacity = if pulses && source::animations_on() { pulse::opacity(source::clock()) } else { 1.0 };
    unsafe { draw_glyph(dc, left, (sh - side) / 2, side, shown, scene::glyph_color(theme, shown), opacity) };
    if scene::glyph_moves(shown, pulses) {
        source::wants_ticks();
    }
    left - (look::window_tab::COLUMN_GAP * scale).round() as i32
}
