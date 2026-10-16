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
//!    The chip's shadow is flat pieces (`tabstrip::shadow`), and what the
//!    slide has is place, size, lift and the two ways a row is written
//!    (`scene::Lit`).
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
use windows::Win32::UI::Input::KeyboardAndMouse::{SetFocus, VK_DOWN, VK_ESCAPE, VK_RETURN, VK_UP};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_control_room::act::{self, Dwell, SeenMarker};
use polter_control_room::glyph::{self, Outline};
use polter_control_room::layout::{self, ListLayout, Rect, Room};
use polter_control_room::lend::{Detail, Effect, Event, Lending, Place};
use polter_control_room::list::{self, List, Selection};
use polter_control_room::look::{self, selection, side, status, Rgba, Theme};
use polter_control_room::rules;
use polter_control_room::pulse;
use polter_control_room::scene::{self, Align, Face, Item, Lit, Part, Piece, Side, Style, View};
use polter_control_room::slide;
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
/// Once a second while a line under a row is due to fold away (task 1661).
const TIMER_UNDER: usize = 3;

/// How many mask pixels a device pixel is drawn from, each way. GDI's
/// shapes have hard edges; a shape drawn this much larger and averaged down
/// has soft ones.
const SS: i32 = 4;

/// A slide in progress. Where it ends is not kept: it ends on the selected
/// row, wherever the list has that row at the frame being drawn.
struct Slide {
    from: Rect,
    started: std::time::Instant,
    /// How many times its timer has fired, for the line that says it stopped.
    ticks: u32,
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
    /// In the panel's client pixels: left, top, right, bottom -- the part
    /// of the row that is seen, when it is scrolled half out of the list's
    /// room.
    pub rect: (i32, i32, i32, i32),
    /// Scrolled wholly out of the list's room (task 1657): no rectangle,
    /// and `IsOffscreen` says so.
    pub offscreen: bool,
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
/// Where the person is may have changed: a window came to the front or
/// left it (task 1505). Posted by `presence_may_have_changed`.
const WM_ROOM_PRESENCE: u32 = WM_APP + 66;

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
    let r = rows.iter().find(|r| r.group == group && !r.offscreen)?;
    Some(RECT { left: r.rect.0, top: r.rect.1, right: r.rect.2, bottom: r.rect.3 })
}

/// Whether row `group` is scrolled wholly out of sight; false for a group
/// not listed, which is gone rather than off screen.
pub fn uia_row_offscreen(group: &str) -> bool {
    UIA_ROWS.lock().ok().is_some_and(|rows| rows.iter().any(|r| r.group == group && r.offscreen))
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

/// Go to the control room with `group` selected: a click on a notification
/// it raised (task 1505). Opening it, when it is closed, starts on the kept
/// selection, so that is set first; an open one is told to select it. On
/// the window thread, where the balloon's click arrives.
pub fn go_to(group: &str) {
    KEPT.with(|k| *k.borrow_mut() = Some(group.to_string()));
    let _ = uia_select(group);
    let frame = crate::tabs::overlay_frame();
    crate::tabs::post_op(frame, crate::tabs::Op::ToggleControlRoom, "control_room_alert click");
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
    /// How far the rows are scrolled up, in points (task 1657). **Not in
    /// `State`**: `list_layout` reads it, and is called from inside
    /// borrows of `STATE`.
    static SCROLLED: std::cell::Cell<f64> = const { std::cell::Cell::new(0.0) };
    /// The row the rows were last scrolled to bring into sight: a
    /// selection that is not this one -- made here, by the core, or by a
    /// screen reader -- is brought into sight at the next paint.
    static REVEALED: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Scroll the rows to `to` points, kept to what they can be. A chip on its
/// way moves with the rows, so that it goes on from where it is seen.
/// Whether anything moved.
fn set_scroll(hwnd: HWND, at: &ListLayout, to: f64) -> bool {
    let to = layout::scroll::kept(to, at.content_height, at.viewport);
    let by = to - at.scrolled;
    if by == 0.0 {
        return false;
    }
    SCROLLED.with(|s| s.set(to));
    // A name being typed moves with its row -- later, outside the caller's
    // look at the source (`place_rename` takes its own).
    if rename_handles().is_some() {
        let _ = unsafe { PostMessageW(Some(hwnd), WM_ROOM_RENAME, WPARAM(3), LPARAM(0)) };
    }
    STATE.with(|s| {
        if let Some(sl) = s.borrow_mut().as_mut().and_then(|st| st.slide.as_mut()) {
            sl.from.y -= by;
        }
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    true
}

/// Bring row `id` wholly into sight by the least scroll, as `at` is
/// scrolled now, and remember that it was (`REVEALED`).
fn reveal(hwnd: HWND, at: &ListLayout, id: Option<&str>) {
    if let Some(to) = at.reveal(id) {
        set_scroll(hwnd, at, to);
    }
    REVEALED.with(|r| *r.borrow_mut() = id.map(str::to_string));
}

fn selection() -> Option<String> {
    STATE.with(|s| s.borrow().as_ref().and_then(|st| st.selection.current().map(str::to_string)))
}

fn panel() -> Option<HWND> {
    STATE.with(|s| s.borrow().as_ref().map(|st| HWND(st.hwnd as *mut c_void)))
}

/// The top-level window the panel is in, when there is a panel. The UI
/// thread's answer: anywhere else there is none (`STATE` is per thread).
/// For a control room alert that has to flash a taskbar button and names
/// no window of its own (task 1575).
pub fn frame_of_panel() -> Option<HWND> {
    let root = unsafe { GetAncestor(panel()?, GA_ROOT) };
    (!root.0.is_null()).then_some(root)
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
            // Its children are clipped out of its own painting: the field a
            // new group is named in is one, and a paint is one blit of the
            // whole panel.
            WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
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
    // A group the person just made is selected as soon as it is listed.
    select_made(hwnd);
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
    Geometry { scale, room: Room::new(rc.right as f64 / scale, rc.bottom as f64 / scale).with_note(note_open()) }
}

/// Light or dark for the control room in `hwnd`'s window: **its terminal's
/// background**, as the strip and the frame round it (`termcolor::chrome`,
/// the macOS rule, task 1550). It used to be the system's setting, which put
/// a light control room inside a dark strip on a light system.
fn dark(hwnd: HWND) -> bool {
    crate::termcolor::chrome(unsafe { GetAncestor(hwnd, GA_ROOT) }).dark
}

/// Whether the control room is what the person is looking at: its panel is
/// showing, and its window is the one in front.
fn in_front(hwnd: HWND) -> bool {
    unsafe { IsWindowVisible(hwnd).as_bool() && GetForegroundWindow() == GetAncestor(hwnd, GA_ROOT) }
}

// ----------------------------------------------------------------- selecting

/// Where the chip is right now, in the panel's points; how far it is
/// lifted; and whether it is on its way. Where it is on the way is
/// `slide::Run`'s to say; this only tells it the time.
fn chip_now(at: &ListLayout, selected: Option<&str>) -> (Option<Rect>, f64, bool) {
    let Some(rest) = at.chip(selected) else { return (None, 0.0, false) };
    STATE.with(|s| {
        let st = s.borrow();
        match st.as_ref().and_then(|st| st.slide.as_ref()) {
            Some(sl) => {
                let run = slide::Run { from: sl.from, to: rest, lift_scale: selection::LIFT_SCALE_ROW };
                let frame = run.frame(sl.started.elapsed().as_secs_f64());
                (Some(frame.chip), frame.lift, !frame.last)
            }
            None => (Some(rest), 0.0, false),
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
    // The row brought into sight first, so that both ends of the slide are
    // where they are seen after it (task 1657).
    source::with(|data| {
        if let Data::Ready(r) = data {
            reveal(hwnd, &list_layout(hwnd, &r.list, g.room.panel.h), id.as_deref());
        }
    });
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
    // Whether it slides at all is the rule's: not with the system's
    // animations off, not from nowhere, not to where it already is.
    let slides = match ends {
        Some((from, Some(to))) => match slide::plan(from, to, source::animations_on()) {
            slide::Plan::Slide { .. } => from.map(|from| Slide { from, started: std::time::Instant::now(), ticks: 0 }),
            slide::Plan::Jump => None,
        },
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
    // A refused "Fix" is said while there is a button to press again.
    let stands = FIX_REFUSAL.with(|f| f.borrow().as_ref().map(|(row, _)| row.clone())).map(|row| {
        source::with(|data| match data {
            Data::Ready(r) => act::fix_refusal_stands(&row, r.list.rows()),
            Data::NotYet => false,
            Data::Unreadable(_) => false,
        })
    });
    if stands == Some(false) {
        FIX_REFUSAL.with(|f| *f.borrow_mut() = None);
    }
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
        request.map(|r| (r, dwell.row))
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

// --------------------------------------- a new group, and a supervisor for one
//
// The two things the person does about a group rather than to a terminal
// (`control-room.md`, 6.4). What they say, where they are and when they are
// offered is `polter_control_room` -- `scene::name_field`, `build_start`,
// `rules::made_group_to_select`, `act::Refusal` -- and is tested there. Here
// is the part that needs a window: a field to type a name in, a menu of
// roles, the system's folder picker.

/// The field a new group's name is typed in: the system's own edit control,
/// so that an input method composes in it as it does anywhere else.
struct NameField {
    edit: isize,
    font: isize,
    brush: isize,
    old_proc: isize,
    /// Why the name as typed made no group.
    refusal: Option<String>,
}

/// What the person picked for the supervisor about to be started, for one
/// group, and what the last press came to.
#[derive(Default, Clone)]
struct StartPicks {
    group: Option<String>,
    role: Option<String>,
    cwd: Option<String>,
    /// Which session, when the two are offered; none until one is pressed.
    session: Option<act::Session>,
    refusal: Option<String>,
}

thread_local! {
    static NAMING: RefCell<Option<NameField>> = const { RefCell::new(None) };
    /// A group the person has just made, until the core lists it.
    static AWAITED: RefCell<Option<String>> = const { RefCell::new(None) };
    static PICKS: RefCell<StartPicks> = RefCell::new(StartPicks::default());
    /// Why the last "Fix" was refused (task 1560), and on which row: said
    /// beside its button until it is pressed again or the card stops
    /// offering it (`act::fix_refusal_stands`).
    static FIX_REFUSAL: RefCell<Option<(String, String)>> = const { RefCell::new(None) };
}

/// The field's window, when a group is being named. **A copy, taken with the
/// borrow already over**: what is done with it next -- giving it the
/// keyboard, reading it, destroying it -- sends messages back into this
/// thread, and `name_proc` reads `NAMING` on every one of them.
fn name_edit() -> Option<isize> {
    NAMING.with(|n| n.borrow().as_ref().map(|f| f.edit))
}

/// Stop naming: what the field held, for the caller to let go of, with
/// `NAMING` already empty and not borrowed.
fn take_name_field() -> Option<NameField> {
    NAMING.with(|n| n.borrow_mut().take())
}

/// The field said Return (1) or Escape / lost the keyboard (0). Posted, so
/// that the field is not destroyed inside its own procedure.
const WM_ROOM_NAME: u32 = WM_APP + 64;

/// `EM_SETLIMITTEXT`, which the `windows` crate keeps with the common
/// controls rather than with the messages.
const EM_SETLIMITTEXT: u32 = 0x00C5;

/// What to tell the person for the core's name of why something was not
/// done.
fn refusal_words(name: &str) -> String {
    list::fill(&tr(act::Refusal::parse(name).message()), name)
}

fn panel_origin(g: &Geometry) -> Px {
    Px { scale: g.scale, ox: (g.room.panel.x * g.scale).round() as i32, oy: (g.room.panel.y * g.scale).round() as i32 }
}

/// "New group" was pressed: put the field where the header was and give it
/// the keyboard.
fn begin_naming(hwnd: HWND) {
    if let Some(edit) = name_edit() {
        unsafe {
            let _ = SetFocus(Some(HWND(edit as *mut c_void)));
        }
        return;
    }
    let g = geometry(hwnd);
    // With no list there is no header to put it in.
    let header = source::with(|data| match data {
        Data::Ready(r) => Some(list_layout(hwnd, &r.list, g.room.panel.h).header),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    let Some(header) = header else { return };
    let at = panel_origin(&g).rect(scene::name_field(header).1);
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    unsafe {
        let hinst: HINSTANCE = windows::Win32::System::LibraryLoader::GetModuleHandleW(None).map(Into::into).unwrap_or_default();
        let made = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            at.left,
            at.top,
            (at.right - at.left).max(1),
            (at.bottom - at.top).max(1),
            Some(hwnd),
            None,
            Some(hinst),
            None,
        );
        let edit = match made {
            Ok(h) => h,
            Err(e) => {
                wlogf!(frame, "[control-room] new group: the name field could not be made: {e:?}");
                return;
            }
        };
        let dpi = (g.scale * 96.0).round() as i32;
        let font = crate::uifont::make(dpi, look::font::BODY.round() as i32, look::font::WEIGHT_BODY.round() as i32, crate::uifont::mono_face());
        SendMessageW(edit, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        // A group's name is 48 at most; a little more can be typed, so that
        // the core is the one to say it is too long.
        SendMessageW(edit, EM_SETLIMITTEXT, Some(WPARAM(64)), Some(LPARAM(0)));
        let brush = CreateSolidBrush(rgb(scene::panel_color(look::theme(dark(hwnd)))));
        // The control's own procedure is on record before ours is put in
        // front of it: ours passes on to it from its first message.
        let old_proc = GetWindowLongPtrW(edit, GWLP_WNDPROC);
        NAMING.with(|n| {
            *n.borrow_mut() = Some(NameField { edit: edit.0 as isize, font: font.0 as isize, brush: brush.0 as isize, old_proc, refusal: None })
        });
        let proc_: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = name_proc;
        SetWindowLongPtrW(edit, GWLP_WNDPROC, proc_ as usize as isize);
        let _ = SetFocus(Some(edit));
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
    wlogf!(frame, "[control-room] new group: naming");
}

/// Take the field away. `focus` hands the keyboard back to the panel.
fn end_naming(hwnd: HWND, focus: bool) {
    let Some(field) = take_name_field() else { return };
    unsafe {
        if focus {
            let _ = SetFocus(Some(hwnd));
        }
        let _ = DestroyWindow(HWND(field.edit as *mut c_void));
        let _ = DeleteObject(HFONT(field.font as *mut c_void).into());
        let _ = DeleteObject(HBRUSH(field.brush as *mut c_void).into());
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

/// Return in the field: make the group. A name the core refuses is said
/// under the field, which stays.
fn submit_name(hwnd: HWND) {
    // Copied out in a statement of its own: nothing of `NAMING` is held
    // past this line, and what follows sends messages.
    let edit = name_edit();
    let Some(edit) = edit else { return };
    let mut buf = [0u16; 128];
    let n = unsafe { GetWindowTextW(HWND(edit as *mut c_void), &mut buf) }.max(0) as usize;
    let name = String::from_utf16_lossy(&buf[..n.min(buf.len())]);
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let Some(request) = act::encode(&act::Act::NewGroup { name: &name }) else { return };
    match source::act(&request) {
        Ok(()) => {
            let made = rules::made_group_name(&name).to_string();
            AWAITED.with(|a| *a.borrow_mut() = Some(made.clone()));
            wlogf!(frame, "[control-room] new group {:?} made; selected when the core lists it", made);
            end_naming(hwnd, true);
            select_made(hwnd);
        }
        Err(why) => {
            wlogf!(frame, "[control-room] new group {:?} refused: {}", name, why);
            NAMING.with(|n| {
                if let Some(f) = n.borrow_mut().as_mut() {
                    f.refusal = Some(refusal_words(&why));
                }
            });
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
        }
    }
}

/// Select the group the person just made, once the core lists it.
fn select_made(hwnd: HWND) {
    let awaited = AWAITED.with(|a| a.borrow().clone());
    let listed = source::with(|data| match data {
        Data::Ready(r) => rules::made_group_to_select(awaited.as_deref(), &r.list).map(str::to_string),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    if let Some(group) = listed {
        AWAITED.with(|a| *a.borrow_mut() = None);
        select(hwnd, Some(group));
    }
}

unsafe extern "system" fn name_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let old = NAMING.with(|n| n.borrow().as_ref().map(|f| f.old_proc));
    let parent = unsafe { GetParent(hwnd) }.unwrap_or_default();
    unsafe {
        match msg {
            WM_KEYDOWN if wp.0 as u16 == VK_RETURN.0 => {
                let _ = PostMessageW(Some(parent), WM_ROOM_NAME, WPARAM(1), LPARAM(0));
                return LRESULT(0);
            }
            WM_KEYDOWN if wp.0 as u16 == VK_ESCAPE.0 => {
                let _ = PostMessageW(Some(parent), WM_ROOM_NAME, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            // Otherwise the edit control beeps on Return and Escape.
            WM_CHAR if wp.0 == 0x0D || wp.0 == 0x1B => return LRESULT(0),
            // Clicking anywhere else, or the tab going behind, gives up.
            WM_KILLFOCUS => {
                let _ = PostMessageW(Some(parent), WM_ROOM_NAME, WPARAM(0), LPARAM(1));
            }
            _ => {}
        }
        match old {
            Some(old) => CallWindowProcW(std::mem::transmute::<isize, WNDPROC>(old), hwnd, msg, wp, lp),
            None => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// What the person picked for `group`; nothing when their picks are about
/// another group.
fn picks_for(group: Option<&str>) -> StartPicks {
    PICKS.with(|p| {
        let p = p.borrow();
        if group.is_some() && p.group.as_deref() == group {
            p.clone()
        } else {
            StartPicks::default()
        }
    })
}

fn pick(group: &str, change: impl FnOnce(&mut StartPicks)) {
    PICKS.with(|p| {
        let mut p = p.borrow_mut();
        if p.group.as_deref() != Some(group) {
            *p = StartPicks { group: Some(group.to_string()), ..Default::default() };
        }
        change(&mut p);
    });
}

/// What starting a supervisor offers for the selected group just now.
fn start_scene(g: &Geometry, theme: &Theme) -> scene::Start {
    let detail = detail();
    let selected = selection();
    let picks = picks_for(selected.as_deref());
    let home = std::env::var("USERPROFILE").unwrap_or_default();
    source::with(|data| {
        let ready = match data {
            Data::Ready(r) => r,
            Data::NotYet => return scene::Start::default(),
            Data::Unreadable(_) => return scene::Start::default(),
        };
        let row = selected.as_deref().and_then(|id| ready.list.row(id));
        let view = scene::StartView {
            roles: &ready.list.supervisor_roles,
            choose_role: ready.list.choose_supervisor_role,
            role: picks.role.as_deref(),
            cwd: picks.cwd.as_deref(),
            session: picks.session,
            refusal: picks.refusal.as_deref(),
            home: &home,
        };
        scene::build_start(&detail, row, g.room.right.w, theme, &view, &|s| tr(s))
    })
}

/// The role's line was pressed: a menu of the roles the core lists.
fn choose_role(hwnd: HWND, group: &str) {
    let roles: Vec<(String, String)> = source::with(|data| match data {
        Data::Ready(r) => r.list.supervisor_roles.iter().map(|role| (role.key.clone(), scene::role_name(role, &|s| tr(s)))).collect(),
        Data::NotYet => Vec::new(),
        Data::Unreadable(_) => Vec::new(),
    });
    if roles.is_empty() {
        return;
    }
    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        for (i, (_, name)) in roles.iter().enumerate() {
            let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
            let _ = AppendMenuW(menu, MF_STRING, i + 1, PCWSTR(wide.as_ptr()));
        }
        let mut at = POINT::default();
        let _ = GetCursorPos(&mut at);
        let picked = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, at.x, at.y, None, hwnd, None);
        let _ = DestroyMenu(menu);
        picked.0 as usize
    };
    if let Some((key, _)) = chosen.checked_sub(1).and_then(|i| roles.get(i)) {
        pick(group, |p| p.role = Some(key.clone()));
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }
}

/// The directory's line was pressed: the system's folder picker, opened
/// where the supervisor would start now.
fn choose_directory(hwnd: HWND, group: &str) {
    let from = picks_for(Some(group)).cwd.or_else(|| {
        source::with(|data| match data {
            Data::Ready(r) => r.list.row(group).and_then(|row| row.start.as_ref()).map(|s| s.cwd.clone()),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        })
    });
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    if let Some(dir) = crate::general_ui::pick_folder(frame, from.as_deref().unwrap_or("")) {
        pick(group, |p| p.cwd = Some(dir));
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }
}

/// "Start Supervisor" was pressed. What becomes of it arrives in the next
/// snapshot; a refusal is kept to be said under the button.
fn start_supervisor(hwnd: HWND, group: &str) {
    let picks = picks_for(Some(group));
    // Which session is said only while the choice is on screen
    // (`act::session_sent`); whether it is is the core's word.
    let offered = source::with(|data| match data {
        Data::Ready(r) => scene::offers_session(r.list.row(group).and_then(|row| row.start.as_ref())),
        Data::NotYet => false,
        Data::Unreadable(_) => false,
    });
    start_supervisor_as(hwnd, group, act::session_sent(offered, picks.session));
}

/// Start the group's supervisor on `session`, in the role and directory
/// picked for it (or the core's): the start button's, and the row menu's
/// two starts, which say the session themselves (task 1661).
fn start_supervisor_as(hwnd: HWND, group: &str, session: Option<act::Session>) {
    let picks = picks_for(Some(group));
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let Some(request) = act::encode(&act::Act::StartSupervisor { group, role: picks.role.as_deref(), cwd: picks.cwd.as_deref(), session }) else { return };
    match source::act(&request) {
        Ok(()) => {
            wlogf!(frame, "[control-room] start supervisor for {:?} (role {:?}, in {:?}, session {:?}) taken", group, picks.role, picks.cwd, session.map(|s| s.name()));
            pick(group, |p| p.refusal = None);
        }
        Err(why) => {
            wlogf!(frame, "[control-room] start supervisor for {:?} refused: {}", group, why);
            let words = refusal_words(&why);
            pick(group, |p| p.refusal = Some(words));
        }
    }
    unsafe {
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

// ------------------------------------------------------- the menu on a row
//
// What it holds is `rowmenu` (the same rule as the macOS host's, compared by
// `tools/control-room-hosts-agree.py`); here is the system's menu, and what
// each item does. **Not all of it can be done yet**: pinning, muting,
// archiving, deleting, renaming, the group's note, the project, and the two
// sentences to the supervisor are the later parts of task 1661 (each needs
// a dialog, a field or a panel); until each is there it is in the menu
// greyed, in its place.

/// The items this host can do today.
fn row_item_works(id: &str) -> bool {
    matches!(
        id,
        "jump_to_supervisor"
            | "start_resume"
            | "start_new"
            | "start"
            | "reveal"
            | "copy_supervisor_id"
            | "pin"
            | "unpin"
            | "mute_hour"
            | "mute_tomorrow"
            | "mute_forever"
            | "unmute"
            | "archive"
            | "delete"
            | "edit_note"
            | "report_progress"
            | "close_idle_workers"
            | "rename"
    )
}

/// The menu on the row under client point `x, y`, if there is one: at the
/// pointer, for that row -- whichever is selected.
fn row_menu(hwnd: HWND, x: i32, y: i32) {
    let g = geometry(hwnd);
    let (px, py) = (x as f64 / g.scale - g.room.panel.x, y as f64 / g.scale - g.room.panel.y);
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    // An archived group's row: its own three items (task 1661).
    let put_away = source::with(|data| match data {
        Data::Ready(r) => list_layout(hwnd, &r.list, g.room.panel.h).archived_at(px, py).and_then(|n| r.list.archived.iter().find(|a| a.name == n).cloned()),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    if let Some(a) = put_away {
        archived_menu(hwnd, x, y, &a);
        return;
    }
    // The row, and the state its menu is made from.
    let found = source::with(|data| match data {
        Data::Ready(r) => {
            let id = list_layout(hwnd, &r.list, g.room.panel.h).row_at(px, py)?.to_string();
            let row = r.list.row(&id)?;
            if row.alone.is_some() {
                // A terminal in no group: there is no group to act on.
                return Some((id, None));
            }
            let state = polter_control_room::rowmenu::State {
                // An archived group has no row here; its menu is the
                // archived section's.
                archived: false,
                pinned: row.pinned,
                muted: row.muted.is_some(),
                // A supervisor that reports no hooks (task 1635) is not
                // told apart here yet.
                sup: if row.steward.is_some() { polter_control_room::rowmenu::Sup::Hooked } else { polter_control_room::rowmenu::Sup::None },
                resumable: scene::offers_session(row.start.as_ref()),
            };
            Some((id, Some((state, row.muted))))
        }
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    let Some((group, state)) = found else { return };
    let Some((state, muted)) = state else {
        wlogf!(frame, "[control-room] row menu: {:?} is a terminal in no group; no menu", group);
        return;
    };
    let entries = polter_control_room::rowmenu::entries(state);
    // The right-hand column: when a mute would end, and when the one in
    // force does, by this machine's clock.
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
    let offset = crate::projects_ui::local_offset() * 1000;
    let when = |id: &str| -> Option<String> {
        let until = match id {
            "unmute" => muted.and_then(|m| m.until_ms)?,
            "mute_hour" | "mute_tomorrow" => act::mute_until(id, now, offset)??,
            _ => return None,
        };
        let (words, at) = polter_control_room::rowmenu::when(until, now, offset);
        Some(list::fill(&tr(words), &at))
    };
    // What each id the menu hands back means: an index into this, plus one.
    let mut ids: Vec<&'static str> = Vec::new();
    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        let label = |id: &str| -> Vec<u16> {
            let mut words = polter_control_room::rowmenu::label(id).map(tr).unwrap_or_else(|| id.to_string());
            if let Some(at) = when(id) {
                words = format!("{words}\t{at}");
            }
            words.encode_utf16().chain(std::iter::once(0)).collect()
        };
        for entry in &entries {
            match *entry {
                polter_control_room::rowmenu::Entry::Separator => {
                    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                }
                polter_control_room::rowmenu::Entry::Item { id, submenu: true } => {
                    let Ok(sub) = CreatePopupMenu() else { continue };
                    for &child in polter_control_room::rowmenu::submenu(id) {
                        ids.push(child);
                        let flags = if row_item_works(child) { MF_STRING } else { MF_STRING | MF_GRAYED };
                        let _ = AppendMenuW(sub, flags, ids.len(), PCWSTR(label(child).as_ptr()));
                    }
                    let flags = if polter_control_room::rowmenu::submenu(id).iter().any(|c| row_item_works(c)) {
                        MF_POPUP | MF_STRING
                    } else {
                        MF_POPUP | MF_STRING | MF_GRAYED
                    };
                    let _ = AppendMenuW(menu, flags, sub.0 as usize, PCWSTR(label(id).as_ptr()));
                }
                polter_control_room::rowmenu::Entry::Item { id, submenu: false } => {
                    ids.push(id);
                    let flags = if row_item_works(id) { MF_STRING } else { MF_STRING | MF_GRAYED };
                    let _ = AppendMenuW(menu, flags, ids.len(), PCWSTR(label(id).as_ptr()));
                }
            }
        }
        let mut at = POINT { x, y };
        let _ = ClientToScreen(hwnd, &mut at);
        let picked = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, at.x, at.y, None, hwnd, None);
        // Destroys the submenus with it.
        let _ = DestroyMenu(menu);
        picked.0 as usize
    };
    let Some(&id) = chosen.checked_sub(1).and_then(|i| ids.get(i)) else {
        wlogf!(frame, "[control-room] row menu on {:?}: dismissed", group);
        return;
    };
    wlogf!(frame, "[control-room] row menu on {:?}: {}", group, id);
    row_item(hwnd, &group, id);
}

/// What a row menu's item does, for group `group`.
fn row_item(hwnd: HWND, group: &str, id: &str) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let row = source::with(|data| match data {
        Data::Ready(r) => r.list.row(group).cloned(),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    let Some(row) = row else {
        wlogf!(frame, "[control-room] row menu: {:?} is no longer listed; {} not done", group, id);
        return;
    };
    match id {
        "jump_to_supervisor" => match row.steward.as_deref() {
            Some(key) => {
                let went = crate::tabs::go_to_terminal(key);
                wlogf!(frame, "[control-room] go to supervisor {} of {:?} -> {}", key, group, went);
            }
            None => wlogf!(frame, "[control-room] go to supervisor: {:?} has none", group),
        },
        "start_resume" => start_supervisor_as(hwnd, group, Some(act::Session::Last)),
        "start_new" => start_supervisor_as(hwnd, group, Some(act::Session::New)),
        "start" => start_supervisor_as(hwnd, group, None),
        // The group's record, where the core keeps it (task 1659's
        // `record_dir`).
        "reveal" => match row.record_dir.clone().filter(|d| !d.is_empty()) {
            Some(dir) => {
                if !crate::shellopen::detached(Some(frame), "[control-room] show group folder", dir) {
                    wlogf!(frame, "[control-room] show in Explorer for {:?}: Explorer could not be started", group);
                }
            }
            None => wlogf!(frame, "[control-room] show in Explorer: the core names no directory for {:?}", group),
        },
        "copy_supervisor_id" => match row.steward.as_deref() {
            Some(key) => {
                let copied = crate::tabs::copy_to_clipboard(key);
                wlogf!(frame, "[control-room] copy supervisor id of {:?}: {:?}", group, copied);
            }
            None => wlogf!(frame, "[control-room] copy supervisor id: {:?} has none", group),
        },
        "pin" => row_act(hwnd, group, &act::Act::Pin { group }),
        "unpin" => row_act(hwnd, group, &act::Act::Unpin { group }),
        "unmute" => row_act(hwnd, group, &act::Act::Unmute { group }),
        "mute_hour" | "mute_tomorrow" | "mute_forever" => {
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
            if let Some(until_ms) = act::mute_until(id, now, crate::projects_ui::local_offset() * 1000) {
                row_act(hwnd, group, &act::Act::Mute { group, until_ms });
            }
        }
        // Asked first, in the one question box this host has
        // (`projects_ui::ask_with_default`): archiving says yes on Return,
        // deleting says no (`confirm`).
        "archive" => {
            let q = polter_control_room::confirm::archive(&row, &|s| tr(s));
            if ask(frame, &q) {
                row_act(hwnd, group, &act::Act::Archive { group });
            }
        }
        "delete" => delete_group(hwnd, group, row.delete_cost, row.project_name.as_deref()),
        "edit_note" => open_note(hwnd, group, &row.brief),
        "report_progress" => ask_supervisor(hwnd, group, act::Ask::Report),
        "close_idle_workers" => ask_supervisor(hwnd, group, act::Ask::CloseIdle),
        "rename" => begin_rename(hwnd, group),
        _ => wlogf!(frame, "[control-room] row menu: {} is not done on this host yet (task 1661)", id),
    }
}

/// Ask `q`; whether its first button was pressed.
fn ask(frame: HWND, q: &polter_control_room::confirm::Question) -> bool {
    crate::projects_ui::ask_with_default(frame, "[control-room]", &q.main, &q.body, &q.buttons, q.default, q.warning) == Some(0)
}

/// "Delete Group…": asked with what the core says it would take, and sent
/// with those numbers. If they are not what it would take by then (`Stale`:
/// somebody joined, a task was opened), nothing was deleted, and the
/// person is asked again with the numbers as they are now -- once.
fn delete_group(hwnd: HWND, group: &str, cost: Option<polter_control_room::snapshot::DeleteCost>, project: Option<&str>) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let mut cost = cost.unwrap_or(polter_control_room::snapshot::DeleteCost { members: 0, open_tasks: 0 });
    for _ in 0..2 {
        let q = polter_control_room::confirm::delete(group, cost, project, &|s| tr(s));
        if !ask(frame, &q) {
            wlogf!(frame, "[control-room] delete {:?}: not confirmed", group);
            return;
        }
        let what = act::Act::DeleteGroup { group, members: cost.members, open_tasks: cost.open_tasks };
        let Some(request) = act::encode(&what) else { return };
        match source::act(&request) {
            Ok(()) => {
                wlogf!(frame, "[control-room] {} taken", request);
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                return;
            }
            Err(why) if act::Refusal::parse(&why) == act::Refusal::Stale => {
                wlogf!(frame, "[control-room] {} refused: Stale; asking again", request);
                let now = source::with(|data| match data {
                    Data::Ready(r) => r.list.row(group).map(|row| row.delete_cost),
                    Data::NotYet => None,
                    Data::Unreadable(_) => None,
                });
                match now {
                    Some(c) => cost = c.unwrap_or(cost),
                    None => return,
                }
            }
            Err(why) => {
                wlogf!(frame, "[control-room] {} refused: {}", request, why);
                // Off the list but not all of it off the disk: said, since
                // the dialog said it would all go (task 1659's DeleteFailed).
                if act::Refusal::parse(&why) == act::Refusal::DeleteFailed {
                    let _ = crate::projects_ui::ask_with_default(frame, "[control-room]", &refusal_words(&why), "", &[tr("OK")], 0, true);
                }
                return;
            }
        }
    }
}

// ------------------------------------------------- the group's brief, at the right
//
// "Edit Group Note…" on a row's menu (task 1661, design v21 `04-B`): a panel
// at the right of the room, the supervisor's side narrower for it
// (`Room::with_note`, which `tabs::layout` asks too, so that the terminal
// shown there moves out of its way). What it says and where its box is is
// `scene::build_note`; the box and the two buttons are the system's, the
// buttons drawn as the settings window's (`project_picker::draw_button`).
// One brief at a time. "Save" sends it; the other button -- "Close" while
// nothing is changed, "Discard Changes" once something is -- and Escape in
// the box close it without.

const ID_NOTE_FIELD: u16 = 0x7101;
const ID_NOTE_SAVE: u16 = 0x7102;
const ID_NOTE_DISCARD: u16 = 0x7103;
/// Escape in the brief's box.
const WM_ROOM_NOTE: u32 = WM_APP + 67;

struct NoteEdit {
    group: String,
    /// The brief as the core had it when the panel opened.
    original: String,
    field: isize,
    save: isize,
    discard: isize,
    font: isize,
    brush: isize,
    old_proc: isize,
}

thread_local! {
    static NOTE: RefCell<Option<NoteEdit>> = const { RefCell::new(None) };
}
/// Whether a brief is open, for `tabs::layout` -- which asks from inside
/// its own lock, where `NOTE` is not to be borrowed. One control room per
/// process, so one bit.
static NOTE_OPEN: AtomicBool = AtomicBool::new(false);

/// Whether the brief's panel is open in the control room.
pub fn note_open() -> bool {
    NOTE_OPEN.load(Ordering::Acquire)
}

/// The open brief's group, its brief as it was, and its three controls --
/// copied out, so that nothing that talks to the controls does so with
/// `NOTE` borrowed (`note_proc` borrows it).
#[derive(Clone)]
struct NoteHandles {
    group: String,
    original: String,
    field: isize,
    save: isize,
    discard: isize,
    font: isize,
}

fn note_handles() -> Option<NoteHandles> {
    NOTE.with(|n| {
        n.borrow().as_ref().map(|f| NoteHandles {
            group: f.group.clone(),
            original: f.original.clone(),
            field: f.field,
            save: f.save,
            discard: f.discard,
            font: f.font,
        })
    })
}

fn note_text(field: isize) -> String {
    let h = HWND(field as *mut c_void);
    let n = unsafe { GetWindowTextLengthW(h) }.max(0) as usize;
    let mut buf = vec![0u16; n + 1];
    let got = unsafe { GetWindowTextW(h, &mut buf) }.max(0) as usize;
    // The box's lines end in CR LF; the brief's in LF.
    String::from_utf16_lossy(&buf[..got]).replace("\r\n", "\n")
}

/// What the panel draws now, and where its controls go; none when no
/// brief is open.
fn note_scene(hwnd: HWND, g: &Geometry, theme: &Theme) -> Option<scene::Note> {
    let r = g.room.note?;
    let h = note_handles()?;
    let text = note_text(h.field);
    let band = (polter_settings_shell::grid::BOTTOM as f64).min(r.h);
    let _ = hwnd;
    Some(scene::build_note(&h.group, layout::Rect { x: 0.0, y: 0.0, w: r.w, h: r.h }, theme, g.scale, text.chars().count(), text != h.original, band, &|s| tr(s)))
}

/// Put the box and the buttons where the scene says, in this window's
/// pixels; and the left button's words, which say whether anything would
/// be thrown away.
fn place_note(hwnd: HWND) {
    let g = geometry(hwnd);
    let theme = look::theme(dark(hwnd));
    let (Some(r), Some(note)) = (g.room.note, note_scene(hwnd, &g, theme)) else { return };
    let Some(NoteHandles { field, save, discard, original, .. }) = note_handles() else { return };
    let dirty = note_text(field) != original;
    let px = |v: f64| (v * g.scale).round() as i32;
    let (ox, oy) = (px(r.x), px(r.y));
    let inset = scene::NOTE_FIELD_INSET;
    let f = note.field;
    let grid = polter_settings_shell::grid::CONTROL_H as f64;
    let wide = polter_settings_shell::grid::ACTION_W[2] as f64;
    let gap = polter_settings_shell::grid::BUTTONS_GAP as f64;
    let b = note.buttons;
    let top = b.y + (b.h - grid) / 2.0;
    unsafe {
        let _ = MoveWindow(HWND(field as *mut c_void), ox + px(f.x + inset), oy + px(f.y + inset), px((f.w - 2.0 * inset).max(1.0)), px((f.h - 2.0 * inset).max(1.0)), true);
        let _ = MoveWindow(HWND(save as *mut c_void), ox + px(b.x + b.w - wide), oy + px(top), px(wide), px(grid), true);
        let _ = MoveWindow(HWND(discard as *mut c_void), ox + px(b.x + b.w - 2.0 * wide - gap), oy + px(top), px(wide), px(grid), true);
        let words: Vec<u16> = tr(if dirty { "Discard Changes" } else { "Close" }).encode_utf16().chain(std::iter::once(0)).collect();
        let _ = SetWindowTextW(HWND(discard as *mut c_void), PCWSTR(words.as_ptr()));
    }
}

fn open_note(hwnd: HWND, group: &str, brief: &str) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    if let Some(NoteHandles { group: was, field, original, .. }) = note_handles() {
        let dirty = note_text(field) != original;
        if was == group || dirty {
            // Its own again, or another's with changes not saved: the one
            // open stays, with the keyboard.
            wlogf!(frame, "[control-room] brief: {:?} stays open (asked for {:?}, changed={})", was, group, dirty);
            let _ = unsafe { SetFocus(Some(HWND(field as *mut c_void))) };
            return;
        }
        close_note(hwnd);
    }
    let g = geometry(hwnd);
    let dpi = (g.scale * 96.0).round() as i32;
    unsafe {
        let hinst: HINSTANCE = windows::Win32::System::LibraryLoader::GetModuleHandleW(None).map(Into::into).unwrap_or_default();
        let make = |class: PCWSTR, style: WINDOW_STYLE, id: u16| {
            CreateWindowExW(WINDOW_EX_STYLE(0), class, PCWSTR::null(), WS_CHILD | WS_VISIBLE | WS_TABSTOP | style, 0, 0, 1, 1, Some(hwnd), Some(HMENU(id as usize as *mut c_void)), Some(hinst), None)
        };
        let field = make(w!("EDIT"), WS_VSCROLL | WINDOW_STYLE((ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN) as u32), ID_NOTE_FIELD);
        let save = make(w!("BUTTON"), WINDOW_STYLE(BS_DEFPUSHBUTTON as u32), ID_NOTE_SAVE);
        let discard = make(w!("BUTTON"), WINDOW_STYLE(BS_PUSHBUTTON as u32), ID_NOTE_DISCARD);
        let (Ok(field), Ok(save), Ok(discard)) = (field, save, discard) else {
            wlogf!(frame, "[control-room] brief: its box or buttons could not be made");
            return;
        };
        let font = crate::uifont::make(dpi, look::font::BODY.round() as i32, look::font::WEIGHT_BODY.round() as i32, crate::uifont::ui_face());
        for h in [field, save, discard] {
            SendMessageW(h, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        }
        crate::theme::for_frame(frame).dress_scrollbars(field);
        let text: Vec<u16> = brief.replace('\n', "\r\n").encode_utf16().chain(std::iter::once(0)).collect();
        let _ = SetWindowTextW(field, PCWSTR(text.as_ptr()));
        let saving: Vec<u16> = tr("Save").encode_utf16().chain(std::iter::once(0)).collect();
        let _ = SetWindowTextW(save, PCWSTR(saving.as_ptr()));
        let brush = CreateSolidBrush(rgb(look::theme(dark(hwnd)).window_base));
        let old_proc = GetWindowLongPtrW(field, GWLP_WNDPROC);
        NOTE.with(|n| {
            *n.borrow_mut() = Some(NoteEdit {
                group: group.to_string(),
                original: brief.to_string(),
                field: field.0 as isize,
                save: save.0 as isize,
                discard: discard.0 as isize,
                font: font.0 as isize,
                brush: brush.0 as isize,
                old_proc,
            })
        });
        let proc_: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = note_proc;
        SetWindowLongPtrW(field, GWLP_WNDPROC, proc_ as usize as isize);
        NOTE_OPEN.store(true, Ordering::Release);
        place_note(hwnd);
        // The terminal on the right moves out of the panel's way.
        crate::tabs::layout(frame);
        let _ = SetFocus(Some(field));
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
    wlogf!(frame, "[control-room] brief of {:?}: open ({} characters)", group, brief.chars().count());
}

/// Close the brief's panel, keeping nothing that was not saved.
fn close_note(hwnd: HWND) {
    let Some(f) = NOTE.with(|n| n.borrow_mut().take()) else { return };
    NOTE_OPEN.store(false, Ordering::Release);
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    unsafe {
        let _ = SetFocus(Some(hwnd));
        for h in [f.field, f.save, f.discard] {
            let _ = DestroyWindow(HWND(h as *mut c_void));
        }
        let _ = DeleteObject(HFONT(f.font as *mut c_void).into());
        let _ = DeleteObject(HBRUSH(f.brush as *mut c_void).into());
        crate::tabs::layout(frame);
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
    wlogf!(frame, "[control-room] brief of {:?}: closed", f.group);
}

/// "Save": the core keeps it, and the panel closes. Refused, it stays open
/// with what was typed, and says so in the log.
fn save_note(hwnd: HWND) {
    let Some(NoteHandles { group, field, .. }) = note_handles() else { return };
    let text = note_text(field);
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let Some(request) = act::encode(&act::Act::SetBrief { group: &group, brief: &text }) else { return };
    match source::act(&request) {
        Ok(()) => {
            wlogf!(frame, "[control-room] brief of {:?}: saved ({} characters)", group, text.chars().count());
            close_note(hwnd);
        }
        Err(why) => wlogf!(frame, "[control-room] brief of {:?}: saving refused: {}", group, why),
    }
}

unsafe extern "system" fn note_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let old = NOTE.with(|n| n.borrow().as_ref().map(|f| f.old_proc));
    let parent = unsafe { GetParent(hwnd) }.unwrap_or_default();
    unsafe {
        match msg {
            // Escape is the left button's: close, keeping nothing unsaved.
            WM_KEYDOWN if wp.0 as u16 == VK_ESCAPE.0 => {
                let _ = PostMessageW(Some(parent), WM_ROOM_NOTE, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            WM_CHAR if wp.0 == 0x1B => return LRESULT(0),
            _ => {}
        }
        match old {
            Some(old) => CallWindowProcW(std::mem::transmute::<isize, WNDPROC>(old), hwnd, msg, wp, lp),
            None => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// ------------------------------------------------- the line under a row
//
// Why a new name was refused, or that the supervisor was asked something
// (task 1661, design v21 `03` and `07`): one line under the row, which the
// layout makes room for (`layout::Extras::lines_under`). "Asked" folds
// away after `group_note::FEEDBACK_SECONDS`; a failure stays until the
// next ask, and a refusal until the name is put right or given up.

thread_local! {
    static UNDER: RefCell<Vec<(String, scene::UnderLine, Option<std::time::Instant>)>> = const { RefCell::new(Vec::new()) };
    /// The archived section is open. Folded each time the control room is
    /// made: the design has it "收起" by default.
    static ARCHIVED_OPEN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Put `line` under row `group`, in place of any it had; `fold` after so
/// long, or never.
fn say_under(hwnd: HWND, group: &str, line: Option<scene::UnderLine>, fold: Option<std::time::Duration>) {
    let until = fold.map(|d| std::time::Instant::now() + d);
    UNDER.with(|u| {
        let mut u = u.borrow_mut();
        u.retain(|(id, _, _)| id != group);
        if let Some(line) = line {
            u.push((group.to_string(), line, until));
        }
    });
    if until.is_some() {
        unsafe {
            SetTimer(Some(hwnd), TIMER_UNDER, 1000, None);
        }
    }
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// Fold away what is due; whether anything is still waiting to.
fn prune_under() -> bool {
    let now = std::time::Instant::now();
    UNDER.with(|u| {
        let mut u = u.borrow_mut();
        u.retain(|(_, _, until)| until.is_none_or(|t| t > now));
        u.iter().any(|(_, _, until)| until.is_some())
    })
}

/// "Ask the Supervisor for a Progress Report" / "… to Close Idle Workers":
/// the core types its sentence into the supervisor. Said under the row as
/// asked, never as done.
fn ask_supervisor(hwnd: HWND, group: &str, ask: act::Ask) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let Some(request) = act::encode(&act::Act::AskSupervisor { group, ask }) else { return };
    match source::act(&request) {
        Ok(()) => {
            wlogf!(frame, "[control-room] {} taken", request);
            say_under(hwnd, group, Some(scene::UnderLine::Asked(ask)), Some(std::time::Duration::from_secs_f64(look::group_note::FEEDBACK_SECONDS)));
        }
        Err(why) => {
            wlogf!(frame, "[control-room] {} refused: {}", request, why);
            let (words, retried) = act::not_delivered(&why);
            say_under(hwnd, group, Some(scene::UnderLine::NotDelivered { why: tr(words), retried }), None);
        }
    }
}

/// The menu on an archived group's row: show its record, take it out of
/// the archive, or delete it.
fn archived_menu(hwnd: HWND, x: i32, y: i32, a: &polter_control_room::snapshot::Archived) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let state = polter_control_room::rowmenu::State { archived: true, sup: polter_control_room::rowmenu::Sup::None, resumable: false, pinned: false, muted: false };
    let mut ids: Vec<&'static str> = Vec::new();
    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        for entry in polter_control_room::rowmenu::entries(state) {
            match entry {
                polter_control_room::rowmenu::Entry::Separator => {
                    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                }
                polter_control_room::rowmenu::Entry::Item { id, .. } => {
                    ids.push(id);
                    let words: Vec<u16> = polter_control_room::rowmenu::label(id).map(tr).unwrap_or_else(|| id.to_string()).encode_utf16().chain(std::iter::once(0)).collect();
                    let _ = AppendMenuW(menu, MF_STRING, ids.len(), PCWSTR(words.as_ptr()));
                }
            }
        }
        let mut at = POINT { x, y };
        let _ = ClientToScreen(hwnd, &mut at);
        let picked = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, at.x, at.y, None, hwnd, None);
        let _ = DestroyMenu(menu);
        picked.0 as usize
    };
    let Some(&id) = chosen.checked_sub(1).and_then(|i| ids.get(i)) else { return };
    wlogf!(frame, "[control-room] archived {:?}: {}", a.name, id);
    match id {
        "reveal" => match a.record_dir.clone().filter(|d| !d.is_empty()) {
            Some(dir) => {
                if !crate::shellopen::detached(Some(frame), "[control-room] show group folder", dir) {
                    wlogf!(frame, "[control-room] show in Explorer for {:?}: Explorer could not be started", a.name);
                }
            }
            None => wlogf!(frame, "[control-room] show in Explorer: the core names no directory for {:?}", a.name),
        },
        "unarchive" => row_act(hwnd, &a.name, &act::Act::Unarchive { group: &a.name }),
        "delete" => delete_group(hwnd, &a.name, a.delete_cost, None),
        _ => {}
    }
}

// ------------------------------------------------------- renaming a row
//
// "Rename Group…" (task 1661, design v21 `03`): the name becomes a field
// where it is, all of it selected. Return renames; Escape gives up;
// clicking elsewhere renames too (as Finder does). A name the core refuses
// is said under the row in red, the field underlined in red, and stays to
// be put right.

struct RenameField {
    group: String,
    edit: isize,
    font: isize,
    brush: isize,
    old_proc: isize,
}

thread_local! {
    static RENAME: RefCell<Option<RenameField>> = const { RefCell::new(None) };
}
/// Return (1), Escape (0) or the field losing the keyboard (2).
const WM_ROOM_RENAME: u32 = WM_APP + 68;

fn rename_handles() -> Option<(String, isize)> {
    RENAME.with(|r| r.borrow().as_ref().map(|f| (f.group.clone(), f.edit)))
}

/// Where the name being changed is, in this window's pixels: on the row's
/// first line, from the text column to the row's end.
fn rename_rect(hwnd: HWND, group: &str) -> Option<RECT> {
    let g = geometry(hwnd);
    let row = source::with(|data| match data {
        Data::Ready(r) => {
            let lay = list_layout(hwnd, &r.list, g.room.panel.h);
            let rect = lay.chip(Some(group))?;
            let waiting = r.list.waiting.iter().any(|w| w.id == group);
            Some((rect, waiting))
        }
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    })?;
    let (rect, waiting) = row;
    let text_x = rect.x + side::ROW_PADDING_X + side::GLYPH + side::ROW_ITEM_GAP;
    let (top, h) = if waiting { (rect.y + side::ROW_PADDING_Y, side::ROW_LINE1_HEIGHT) } else { (rect.y, side::QUIET_ROW_HEIGHT) };
    let line = layout::Rect { x: text_x, y: top, w: (rect.x + rect.w - side::ROW_PADDING_X - text_x).max(1.0), h };
    Some(panel_origin(&g).rect(line))
}

fn begin_rename(hwnd: HWND, group: &str) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    if let Some((was, edit)) = rename_handles() {
        if was == group {
            let _ = unsafe { SetFocus(Some(HWND(edit as *mut c_void))) };
            return;
        }
        end_rename(hwnd);
    }
    let Some(at) = rename_rect(hwnd, group) else { return };
    let g = geometry(hwnd);
    let waiting = source::with(|data| match data {
        Data::Ready(r) => r.list.waiting.iter().any(|w| w.id == group),
        Data::NotYet => false,
        Data::Unreadable(_) => false,
    });
    unsafe {
        let hinst: HINSTANCE = windows::Win32::System::LibraryLoader::GetModuleHandleW(None).map(Into::into).unwrap_or_default();
        let made = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            at.left,
            at.top,
            (at.right - at.left).max(1),
            (at.bottom - at.top).max(1),
            Some(hwnd),
            None,
            Some(hinst),
            None,
        );
        let Ok(edit) = made else {
            wlogf!(frame, "[control-room] rename {:?}: the field could not be made", group);
            return;
        };
        let dpi = (g.scale * 96.0).round() as i32;
        // The name's own face and size: the field is the name, editable.
        let size = if waiting { look::font::GROUP_NAME } else { look::font::BODY };
        let font = crate::uifont::make(dpi, size.round() as i32, look::font::WEIGHT_BODY.round() as i32, crate::uifont::mono_face());
        SendMessageW(edit, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        SendMessageW(edit, EM_SETLIMITTEXT, Some(WPARAM(64)), Some(LPARAM(0)));
        let text: Vec<u16> = group.encode_utf16().chain(std::iter::once(0)).collect();
        let _ = SetWindowTextW(edit, PCWSTR(text.as_ptr()));
        SendMessageW(edit, windows::Win32::UI::Controls::EM_SETSEL, Some(WPARAM(0)), Some(LPARAM(-1)));
        let brush = CreateSolidBrush(rgb(scene::panel_color(look::theme(dark(hwnd)))));
        let old_proc = GetWindowLongPtrW(edit, GWLP_WNDPROC);
        RENAME.with(|r| *r.borrow_mut() = Some(RenameField { group: group.to_string(), edit: edit.0 as isize, font: font.0 as isize, brush: brush.0 as isize, old_proc }));
        let proc_: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = rename_proc;
        SetWindowLongPtrW(edit, GWLP_WNDPROC, proc_ as usize as isize);
        let _ = SetFocus(Some(edit));
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
    wlogf!(frame, "[control-room] rename {:?}: typing", group);
}

/// Take the field away, and with it any refusal said under the row.
fn end_rename(hwnd: HWND) {
    let Some(f) = RENAME.with(|r| r.borrow_mut().take()) else { return };
    say_under(hwnd, &f.group, None, None);
    unsafe {
        let _ = DestroyWindow(HWND(f.edit as *mut c_void));
        let _ = DeleteObject(HFONT(f.font as *mut c_void).into());
        let _ = DeleteObject(HBRUSH(f.brush as *mut c_void).into());
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

/// The field said Return, or lost the keyboard: rename to what it says. The
/// same name is giving up. Refused, the reason goes under the row and the
/// field stays (with the keyboard, after Return).
fn commit_rename(hwnd: HWND, keep_focus: bool) {
    let Some((group, edit)) = rename_handles() else { return };
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let to = {
        let h = HWND(edit as *mut c_void);
        let n = unsafe { GetWindowTextLengthW(h) }.max(0) as usize;
        let mut buf = vec![0u16; n + 1];
        let got = unsafe { GetWindowTextW(h, &mut buf) }.max(0) as usize;
        String::from_utf16_lossy(&buf[..got])
    };
    if to == group {
        end_rename(hwnd);
        return;
    }
    let Some(request) = act::encode(&act::Act::RenameGroup { from: &group, to: &to }) else { return };
    match source::act(&request) {
        Ok(()) => {
            wlogf!(frame, "[control-room] {} taken", request);
            end_rename(hwnd);
            // The selection follows the group to its new name.
            if selection().as_deref() == Some(group.as_str()) {
                select(hwnd, Some(to));
            }
        }
        Err(why) => {
            wlogf!(frame, "[control-room] {} refused: {}", request, why);
            let words = refusal_words(&why);
            say_under(hwnd, &group, Some(scene::UnderLine::Refused(words)), None);
            // The row grew a line: the field goes where its name now is.
            place_rename(hwnd);
            if keep_focus {
                let _ = unsafe { SetFocus(Some(HWND(edit as *mut c_void))) };
            }
        }
    }
}

/// Keep the field on the name: after a scroll, a resize, a line under it.
fn place_rename(hwnd: HWND) {
    let Some((group, edit)) = rename_handles() else { return };
    let Some(at) = rename_rect(hwnd, &group) else {
        // Its row is gone: renamed elsewhere, deleted, archived.
        end_rename(hwnd);
        return;
    };
    unsafe {
        let _ = MoveWindow(HWND(edit as *mut c_void), at.left, at.top, (at.right - at.left).max(1), (at.bottom - at.top).max(1), true);
    }
}

unsafe extern "system" fn rename_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    let old = RENAME.with(|r| r.borrow().as_ref().map(|f| f.old_proc));
    let parent = unsafe { GetParent(hwnd) }.unwrap_or_default();
    unsafe {
        match msg {
            WM_KEYDOWN if wp.0 as u16 == VK_RETURN.0 => {
                let _ = PostMessageW(Some(parent), WM_ROOM_RENAME, WPARAM(1), LPARAM(0));
                return LRESULT(0);
            }
            WM_KEYDOWN if wp.0 as u16 == VK_ESCAPE.0 => {
                let _ = PostMessageW(Some(parent), WM_ROOM_RENAME, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            WM_CHAR if wp.0 == 0x0D || wp.0 == 0x1B => return LRESULT(0),
            WM_KILLFOCUS => {
                let _ = PostMessageW(Some(parent), WM_ROOM_RENAME, WPARAM(2), LPARAM(0));
            }
            _ => {}
        }
        match old {
            Some(old) => CallWindowProcW(std::mem::transmute::<isize, WNDPROC>(old), hwnd, msg, wp, lp),
            None => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Send one of the row menu's acts. What it changes arrives in the next
/// snapshot; a refusal is logged (the only one these have is the group
/// being gone, which the next list shows).
fn row_act(hwnd: HWND, group: &str, what: &act::Act) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let Some(request) = act::encode(what) else { return };
    match source::act(&request) {
        Ok(()) => wlogf!(frame, "[control-room] {} for {:?} taken", request, group),
        Err(why) => wlogf!(frame, "[control-room] {} for {:?} refused: {}", request, group, why),
    }
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// "Fix" on a card that reads "Failed" (task 1560): the core tells the
/// card's supervisor, and the next list greys the button. A refusal is
/// kept beside it, and the button stays to be pressed again.
fn fix(hwnd: HWND, row: &str, request: &str) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    match source::act(request) {
        Ok(()) => {
            wlogf!(frame, "[control-room] fix on {:?} taken", row);
            FIX_REFUSAL.with(|f| *f.borrow_mut() = None);
        }
        Err(why) => {
            wlogf!(frame, "[control-room] fix on {:?} refused: {}", row, why);
            let words = refusal_words(&why);
            FIX_REFUSAL.with(|f| *f.borrow_mut() = Some((row.to_string(), words)));
        }
    }
    unsafe {
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

fn inside(r: Rect, x: f64, y: f64) -> bool {
    x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
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
            report_presence(hwnd);
            LRESULT(0)
        }
        WM_ROOM_PRESENCE => {
            report_presence(hwnd);
            LRESULT(0)
        }
        // The name field said Return (1), or Escape / lost the keyboard (0).
        WM_ROOM_NAME => {
            if wp.0 == 1 {
                submit_name(hwnd);
            } else {
                // Having lost the keyboard, it does not take it back.
                end_naming(hwnd, lp.0 == 0);
            }
            LRESULT(0)
        }
        // The brief's two buttons, and what is typed in its box.
        WM_COMMAND => {
            let (id, code) = ((wp.0 & 0xFFFF) as u16, ((wp.0 >> 16) & 0xFFFF) as u32);
            match (id, code) {
                (ID_NOTE_SAVE, BN_CLICKED) => save_note(hwnd),
                (ID_NOTE_DISCARD, BN_CLICKED) => close_note(hwnd),
                (ID_NOTE_FIELD, EN_CHANGE) => {
                    // The count and whether it is saved, and the left
                    // button's words.
                    place_note(hwnd);
                    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                }
                _ => return unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
            }
            LRESULT(0)
        }
        WM_ROOM_NOTE => {
            close_note(hwnd);
            LRESULT(0)
        }
        WM_ROOM_RENAME => {
            match wp.0 {
                0 => end_rename(hwnd),
                1 => commit_rename(hwnd, true),
                3 => place_rename(hwnd),
                // Clicking elsewhere renames, as Finder does; refused, the
                // field stays where it is without the keyboard.
                _ => commit_rename(hwnd, false),
            }
            LRESULT(0)
        }
        // The brief's buttons, drawn as the settings window's are.
        WM_NOTIFY => {
            let cd = unsafe { &*(lp.0 as *const windows::Win32::UI::Controls::NMCUSTOMDRAW) };
            let ours = note_handles().map(|f| (f.font, [f.save, f.discard]));
            if let Some((font, buttons)) = ours {
                if cd.hdr.code == windows::Win32::UI::Controls::NM_CUSTOMDRAW
                    && crate::theme::custom_drawing()
                    && buttons.contains(&(cd.hdr.hwndFrom.0 as isize))
                    && cd.dwDrawStage == windows::Win32::UI::Controls::CDDS_PREPAINT
                {
                    crate::project_picker::draw_button(cd, HFONT(font as *mut c_void));
                    return LRESULT(windows::Win32::UI::Controls::CDRF_SKIPDEFAULT as isize);
                }
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // The field is drawn on the panel's own colour, in its ink.
        WM_CTLCOLOREDIT if NOTE.with(|n| n.borrow().as_ref().is_some_and(|f| f.field == lp.0)) => {
            let theme = look::theme(dark(hwnd));
            let brush = NOTE.with(|n| n.borrow().as_ref().map(|f| f.brush)).unwrap_or(0);
            let dc = HDC(wp.0 as *mut c_void);
            unsafe {
                SetTextColor(dc, rgb(theme.text));
                SetBkColor(dc, rgb(theme.window_base));
            }
            LRESULT(brush)
        }
        WM_CTLCOLOREDIT if RENAME.with(|r| r.borrow().as_ref().is_some_and(|f| f.edit == lp.0)) => {
            let theme = look::theme(dark(hwnd));
            let brush = RENAME.with(|r| r.borrow().as_ref().map(|f| f.brush)).unwrap_or(0);
            let dc = HDC(wp.0 as *mut c_void);
            unsafe {
                SetTextColor(dc, rgb(theme.text));
                SetBkColor(dc, rgb(scene::panel_color(theme)));
            }
            LRESULT(brush)
        }
        WM_CTLCOLOREDIT => {
            let brush = NAMING.with(|n| n.borrow().as_ref().map(|f| f.brush));
            match brush {
                Some(brush) => {
                    let theme = look::theme(dark(hwnd));
                    let dc = HDC(wp.0 as *mut c_void);
                    unsafe {
                        SetTextColor(dc, rgb(theme.text));
                        SetBkColor(dc, rgb(scene::panel_color(theme)));
                    }
                    LRESULT(brush)
                }
                None => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
            }
        }
        WM_PAINT => {
            paint(hwnd);
            LRESULT(0)
        }
        WM_SIZE => {
            place_note(hwnd);
            place_rename(hwnd);
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            LRESULT(0)
        }
        // Over what a press goes somewhere from, the pointer is the hand.
        // Everywhere else it is the class's arrow, which is what not
        // answering this gets.
        WM_SETCURSOR if (lp.0 & 0xffff) as u32 == HTCLIENT => {
            let mut at = POINT::default();
            let over = unsafe { GetCursorPos(&mut at).is_ok() && ScreenToClient(hwnd, &mut at).as_bool() };
            if over && goes_at(hwnd, at.x, at.y) {
                unsafe {
                    let _ = SetCursor(LoadCursorW(None, IDC_HAND).ok());
                }
                return LRESULT(1);
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        // The wheel scrolls the rows (task 1657), three quiet rows a notch;
        // a list that fits has nothing to scroll and leaves it be.
        WM_MOUSEWHEEL => {
            let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
            let g = geometry(hwnd);
            // The paint it asks for tells the core which cards are in sight.
            source::with(|data| {
                if let Data::Ready(r) = data {
                    let at = list_layout(hwnd, &r.list, g.room.panel.h);
                    let by = polter_control_room::panestack::scroll(0, delta, WHEEL_ROWS * side::QUIET_ROW_HEIGHT);
                    set_scroll(hwnd, &at, at.scrolled + by);
                }
            });
            LRESULT(0)
        }
        // The menu on a group's row (task 1661). On the up, as the tab
        // strip's: pressing and sliding off is a way out.
        WM_RBUTTONUP => {
            let (x, y) = point(lp);
            row_menu(hwnd, x, y);
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
                    // Decided here and not in the paint: a panel that is
                    // not being painted -- hidden, minimised -- still gets
                    // its timer stopped.
                    let ended = STATE.with(|s| {
                        let mut st = s.borrow_mut();
                        let Some(st) = st.as_mut() else { return Some((0, 0.0)) };
                        let Some(sl) = st.slide.as_mut() else { return Some((0, 0.0)) };
                        sl.ticks += 1;
                        let t = sl.started.elapsed().as_secs_f64();
                        if !slide::over(t) {
                            return None;
                        }
                        let said = (sl.ticks, t);
                        st.slide = None;
                        Some(said)
                    });
                    unsafe {
                        if let Some((ticks, t)) = ended {
                            let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
                            // absence: means it has not stopped -- after a
                            // `selected` line that slid, no line of this kind
                            // is a slide timer still running.
                            wlogf!(
                                GetAncestor(hwnd, GA_ROOT),
                                "[control-room] slide over after {} tick(s), {:.0} ms; its timer is stopped",
                                ticks,
                                t * 1000.0
                            );
                        }
                        // The frame that says it is over is drawn too: that
                        // is the one with the chip exactly on its row.
                        let _ = InvalidateRect(Some(hwnd), None, false);
                    }
                }
                TIMER_SEEN => seen_due(hwnd),
                TIMER_UNDER => {
                    if !prune_under() {
                        let _ = unsafe { KillTimer(Some(hwnd), TIMER_UNDER) };
                    }
                    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                }
                _ => {}
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe {
                let _ = KillTimer(Some(hwnd), TIMER_SLIDE);
                let _ = KillTimer(Some(hwnd), TIMER_SEEN);
            }
            // Closed is not in front: nothing on it is in sight any more.
            say_presence(polter_control_room::alert::Presence::default());
            STATE.with(|s| {
                let mut st = s.borrow_mut();
                if st.as_ref().is_some_and(|st| st.hwnd == hwnd.0 as isize) {
                    *st = None;
                }
            });
            // The name field goes with the panel (the system destroys the
            // child); what it held is let go of here.
            if let Some(field) = take_name_field() {
                unsafe {
                    let _ = DeleteObject(HFONT(field.font as *mut c_void).into());
                    let _ = DeleteObject(HBRUSH(field.brush as *mut c_void).into());
                }
            }
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
            // A control room opened again starts at the top, and brings
            // its selection into sight from there.
            SCROLLED.with(|s| s.set(0.0));
            REVEALED.with(|r| *r.borrow_mut() = None);
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

/// How many quiet rows one notch of the wheel scrolls the list.
const WHEEL_ROWS: f64 = 3.0;

fn click(hwnd: HWND, x: i32, y: i32) {
    let g = geometry(hwnd);
    let (px, py) = (x as f64 / g.scale, y as f64 / g.scale);
    // The archived section's header opens and closes it; its rows are not
    // selected -- their menu is what there is to do with them (task 1661).
    let archived = source::with(|data| match data {
        Data::Ready(r) => {
            let lay = list_layout(hwnd, &r.list, g.room.panel.h);
            let (ax, ay) = (px - g.room.panel.x, py - g.room.panel.y);
            Some(lay.on_archived_header(ax, ay) as u8 * 2 + lay.archived_at(ax, ay).is_some() as u8)
        }
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    match archived {
        Some(2) => {
            let open = !ARCHIVED_OPEN.with(|o| o.get());
            ARCHIVED_OPEN.with(|o| o.set(open));
            wlogf!(unsafe { GetAncestor(hwnd, GA_ROOT) }, "[control-room] archived section {}", if open { "opened" } else { "closed" });
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            return;
        }
        Some(1) => return,
        _ => {}
    }
    // A row of the list.
    let row = source::with(|data| match data {
        Data::Ready(r) => list_layout(hwnd, &r.list, g.room.panel.h)
            .row_at(px - g.room.panel.x, py - g.room.panel.y)
            .map(str::to_string),
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    // "New group", at the right end of the list's header. Before the rows:
    // while a name is being put right, what says why lies over the first.
    let pressed_new = source::with(|data| match data {
        Data::Ready(r) => inside(scene::new_group_hit(list_layout(hwnd, &r.list, g.room.panel.h).header), px - g.room.panel.x, py - g.room.panel.y),
        Data::NotYet => false,
        Data::Unreadable(_) => false,
    });
    if pressed_new {
        begin_naming(hwnd);
        return;
    }
    // The OK of the notice that the first sweep of old records waits for
    // the person (task 1511): in the room the layout left under the header.
    let pressed_ok = source::with(|data| match data {
        Data::Ready(r) => list_layout(hwnd, &r.list, g.room.panel.h)
            .notice
            .is_some_and(|n| inside(scene::retention_ok_hit(n), px - g.room.panel.x, py - g.room.panel.y)),
        Data::NotYet => false,
        Data::Unreadable(_) => false,
    });
    if pressed_ok {
        let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
        if let Some(request) = act::encode(&act::Act::RetentionAgree) {
            match source::act(&request) {
                Ok(()) => wlogf!(frame, "[control-room] first sweep agreed to"),
                Err(why) => wlogf!(frame, "[control-room] agreeing to the first sweep refused: {}", why),
            }
        }
        return;
    }
    // "Fix" on a failed card (task 1560): a press on the button is the
    // button's, not the row's. A greyed one takes the press as the row.
    let pressed_fix = source::with(|data| match data {
        Data::Ready(r) => {
            let lay = list_layout(hwnd, &r.list, g.room.panel.h);
            // Not a button scrolled out from under the pointer.
            let y = py - g.room.panel.y;
            if y < lay.viewport.y || y >= lay.viewport.y + lay.viewport.h {
                return None;
            }
            r.list.waiting.iter().find_map(|w| {
                let rect = lay.chip(Some(&w.id))?;
                if !inside(scene::fix_hit(rect), px - g.room.panel.x, py - g.room.panel.y) {
                    return None;
                }
                Some((w.id.clone(), act::fix_act(w).and_then(|a| act::encode(&a))?))
            })
        }
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    if let Some((id, request)) = pressed_fix {
        fix(hwnd, &id, &request);
        return;
    }
    if row.is_some() {
        select(hwnd, row);
        return;
    }
    let selected = selection();
    let theme = look::theme(dark(hwnd));
    // What starting a supervisor offers, when the core says one can be.
    let offered = start_scene(&g, theme);
    let (rx, ry) = (px - g.room.right.x, py - g.room.right.y);
    if let Some(group) = selected.clone() {
        if offered.start.is_some_and(|r| inside(r, rx, ry)) {
            start_supervisor(hwnd, &group);
            return;
        }
        if offered.role.is_some_and(|r| inside(r, rx, ry)) {
            choose_role(hwnd, &group);
            return;
        }
        if offered.directory.is_some_and(|r| inside(r, rx, ry)) {
            choose_directory(hwnd, &group);
            return;
        }
        if let Some((session, _)) = offered.sessions.iter().find(|(_, r)| inside(*r, rx, ry)) {
            let session = *session;
            pick(&group, |p| p.session = Some(session));
            unsafe {
                let _ = InvalidateRect(Some(hwnd), None, false);
            }
            return;
        }
    }
    if goes_at(hwnd, x, y) {
        go_to_supervisor(hwnd);
    }
}

/// Whether a press at this point of the panel goes to the supervisor's own
/// tab: it is in another window, and the point is on the right-hand side
/// (`scene::Right::go`). What a click asks, and what the pointer's shape
/// says before one.
fn goes_at(hwnd: HWND, x: i32, y: i32) -> bool {
    let g = geometry(hwnd);
    let (px, py) = (x as f64 / g.scale, y as f64 / g.scale);
    let detail = detail();
    let selected = selection();
    let theme = look::theme(dark(hwnd));
    let go = source::with(|data| {
        let row = match data {
            Data::Ready(r) => selected.as_deref().and_then(|id| r.list.row(id)),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        };
        scene::build_right(&detail, row, g.room.right.w, g.room.right.h, theme, g.scale, false, &|s| tr(s)).go
    });
    go.is_some_and(|go| inside(go, px - g.room.right.x, py - g.room.right.y))
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
        let face = if mono { crate::uifont::mono_face() } else { crate::uifont::ui_face() };
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
    // A brief whose group is gone -- renamed, deleted, archived -- closes.
    let gone = NOTE.with(|n| n.borrow().as_ref().map(|f| f.group.clone())).filter(|group| {
        source::with(|data| match data {
            Data::Ready(r) => r.list.row(group).is_none(),
            Data::NotYet => false,
            Data::Unreadable(_) => false,
        })
    });
    if gone.is_some() {
        close_note(hwnd);
    }
    let g = geometry(hwnd);
    let theme = look::theme(dark(hwnd));
    let selected = selection();
    // A selection not made by `select` -- the core's, a screen reader's --
    // is brought into sight here; and a list grown shorter keeps the rows
    // scrolled no further than they can be.
    source::with(|data| {
        if let Data::Ready(r) = data {
            let at = list_layout(hwnd, &r.list, g.room.panel.h);
            SCROLLED.with(|s| s.set(at.scrolled));
            if REVEALED.with(|r| *r.borrow() != selected) {
                reveal(hwnd, &at, selected.as_deref());
            }
        }
    });
    let t = source::clock();
    let translate = |s: &str| tr(s);
    let detail = detail();
    let in_terminal = crate::tabs::keyboard_in_lent(unsafe { GetAncestor(hwnd, GA_ROOT) });
    // Whether a new group is being named, and why the name made none.
    let naming: Option<Option<String>> = NAMING.with(|n| n.borrow().as_ref().map(|f| f.refusal.clone()));
    let fix_refusal: Option<(String, String)> = FIX_REFUSAL.with(|f| f.borrow().clone());
    let fix_refusal = fix_refusal.as_ref().map(|(row, why)| (row.as_str(), why.as_str()));
    let offered = start_scene(&g, theme);

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
        // What shows through the chip while it slides, and the chip's box.
        let mut under_chip: Option<(RECT, Vec<Item>)> = None;
        let (items, right) = source::with(|data| match data {
            Data::Ready(r) => {
                let list: &List = &r.list;
                let lay = list_layout(hwnd, list, g.room.panel.h);
                // Which cards are wholly on screen, for where the person is
                // (task 1505). Told to the core after the paint.
                if let Ok(mut cards) = CARDS.lock() {
                    *cards = polter_control_room::alert::in_sight(&lay);
                }
                let (chip, lift, sliding) = chip_now(&lay, selected.as_deref());
                let window = crate::tabs::window(GetAncestor(hwnd, GA_ROOT)).map(|w| polter_control_room::rules::key(w.id));
                // By the row's identity: a group's name, or the row of a
                // terminal that is in no group.
                let pulsing = pulse::pulsing_row_id(&r.snapshot.pulses, window.as_deref(), None);
                let pulsing = pulsing.as_deref();
                // Whether a group is being named is the same in both passes:
                // the field's outline and what says why a name made no
                // group do not change while the chip is on its way.
                let naming_view = naming.as_ref().map(|refusal| scene::Naming { refusal: refusal.as_deref() });
                // On its way the chip is on no row: outside it nothing reads
                // as selected, and what does is drawn through its outline
                // below.
                let lit = if sliding { Lit::Nobody } else { Lit::Selection };
                let view = View { theme, scale: g.scale, selection: selected.as_deref(), lit, chip, lift, pulsing, naming: naming_view, fix_refusal };
                if sliding {
                    if let Some(chip) = chip {
                        let inside =
                            View { theme, scale: g.scale, selection: selected.as_deref(), lit: Lit::Every, chip: Some(chip), lift, pulsing, naming: naming_view, fix_refusal };
                        under_chip = Some((at.rect(chip), scene::build(list, &lay, &inside, &translate)));
                    }
                }
                let row = selected.as_deref().and_then(|id| list.row(id));
                // What a UI Automation client is told, from the same list and
                // the same layout this paint draws.
                let spoken: Vec<UiaRow> = list
                    .rows()
                    .filter_map(|r| {
                        let row = lay.chip(Some(&r.id))?;
                        // Only the part in the list's room.
                        let (top, bottom) = (row.y.max(lay.viewport.y), (row.y + row.h).min(lay.viewport.y + lay.viewport.h));
                        let rc = at.rect(Rect { y: top, h: (bottom - top).max(0.0), ..row });
                        Some(UiaRow {
                            group: r.id.clone(),
                            name: scene::spoken(r, &translate),
                            selected: selected.as_deref() == Some(r.id.as_str()),
                            rect: (rc.left, rc.top, rc.right, rc.bottom),
                            offscreen: bottom <= top,
                        })
                    })
                    .collect();
                if let Ok(mut rows) = UIA_ROWS.lock() {
                    *rows = spoken;
                }
                let mut items = scene::build(list, &lay, &view, &translate);
                // What the list draws besides its rows (task 1661).
                let under: Vec<(String, scene::UnderLine)> = UNDER.with(|u| u.borrow().iter().map(|(id, line, _)| (id.clone(), line.clone())).collect());
                let open = ARCHIVED_OPEN.with(|o| o.get());
                items.extend(scene::build_extras(list, &lay, &view, &under, open, crate::projects_ui::local_offset() * 1000, &translate));
                (items, scene::build_right(&detail, row, g.room.right.w, g.room.right.h, theme, g.scale, in_terminal, &translate))
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
        if let Some((box_, inside)) = &under_chip {
            // The same panel with every row written as selected, drawn only
            // where the chip is: the chip's edge is the line between the
            // two ways of writing a row.
            let r = at.len(look::radius::ROW) * 2;
            let outline = CreateRoundRectRgn(box_.left, box_.top, box_.right + 1, box_.bottom + 1, r, r);
            if !outline.is_invalid() {
                let saved = SaveDC(mem);
                SelectClipRgn(mem, Some(outline));
                paint_items(mem, at, inside, &mut fonts, t);
                let _ = RestoreDC(mem, saved);
                let _ = DeleteObject(outline.into());
            }
        }
        if scene::moves(&items) {
            source::wants_ticks();
        }

        // The group's brief, at the right, when it is being edited.
        if let (Some(r), Some(note)) = (g.room.note, note_scene(hwnd, &g, theme)) {
            let at = Px { scale: g.scale, ox: (r.x * g.scale).round() as i32, oy: (r.y * g.scale).round() as i32 };
            paint_items(mem, at, &note.items, &mut fonts, t);
        }
        // The right side.
        if g.room.right.w > 0.0 {
            let at = Px { scale: g.scale, ox: (g.room.right.x * g.scale).round() as i32, oy: (g.room.right.y * g.scale).round() as i32 };
            paint_items(mem, at, &right.items, &mut fonts, t);
            // Under the sentence of a group with no supervisor: what
            // starting one offers.
            paint_items(mem, at, &offered.items, &mut fonts, t);
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
    report_presence(hwnd);
}

// ------------------------------------------------------- where the person is

/// The cards wholly on screen at the last paint (`alert::in_sight`).
static CARDS: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// What the core was last told, so the same is not said twice.
static PRESENCE: Mutex<Option<polter_control_room::alert::Reporter>> = Mutex::new(None);

/// A window came to the front or left it: the control room may have come
/// into the person's sight or gone out of it. Posted; safe from anywhere on
/// the window thread, and nothing when there is no panel.
pub fn presence_may_have_changed() {
    let panel = PANEL.load(Ordering::Acquire);
    if panel != 0 {
        let _ = unsafe { PostMessageW(Some(HWND(panel as *mut c_void)), WM_ROOM_PRESENCE, WPARAM(0), LPARAM(0)) };
    }
}

/// Tell the core whether the control room is in front and which cards are
/// on screen in it, when that changed (`ghostty_app_control_presence`): its
/// notifications are not sent about a card the person can see. "In front"
/// is this panel's window being the foreground one -- per window, not per
/// application.
fn report_presence(hwnd: HWND) {
    let front = in_front(hwnd);
    let cards = if front { CARDS.lock().map(|c| c.clone()).unwrap_or_default() } else { Vec::new() };
    say_presence(polter_control_room::alert::Presence { in_front: front, cards });
}

fn say_presence(now: polter_control_room::alert::Presence) {
    let json = match PRESENCE.lock() {
        Ok(mut p) => p.get_or_insert_with(Default::default).report(now),
        Err(_) => return,
    };
    let Some(json) = json else { return };
    // Only when it changed (`alert::Reporter`). The line a notification
    // decision can be checked against: on the Mac this was never true and
    // nothing said so (task 1531).
    // process-wide: the control room is one per process
    crate::plogf!("[control-room] presence {json}");
    let Some(api) = crate::api_opt() else { return };
    let app = crate::app_opt();
    if app.is_null() {
        return;
    }
    let mut err = [0u8; 64];
    let ok = unsafe { (api.app_control_presence)(app, json.as_ptr(), json.len(), err.as_mut_ptr(), err.len()) };
    if !ok {
        let end = err.iter().position(|&b| b == 0).unwrap_or(err.len());
        // process-wide: the control room is one per process
        crate::plogf!("[control-room] presence refused: {}", String::from_utf8_lossy(&err[..end]));
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
            // In pairs: a rect saves the clip there is and narrows it, none
            // puts the saved one back -- so a clip a caller set round all of
            // this (the chip's outline) stays.
            Item::Clip { rect: Some(rect) } => unsafe {
                let r = at.rect(*rect);
                SaveDC(dc);
                IntersectClipRect(dc, r.left, r.top, r.right, r.bottom);
            },
            Item::Clip { rect: None } => unsafe {
                let _ = RestoreDC(dc, -1);
            },
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
        let extras = layout::Extras {
            lines_under: UNDER.with(|u| u.borrow().iter().map(|(id, _, _)| id.clone()).collect()),
            archived: list.archived.iter().map(|a| a.name.clone()).collect(),
            archived_open: ARCHIVED_OPEN.with(|o| o.get()),
        };
        let lay = ListLayout::measured_with(
            list,
            height,
            &|text, code| {
                let font = if code { mono } else { ui };
                layout::wrap(text, &|s| fit_chars(dc, font, s, width)).len()
            },
            &extras,
        );
        ReleaseDC(Some(hwnd), dc);
        lay.scrolled_to(SCROLLED.with(|s| s.get()))
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

/// How wide each of `words` is in points, in the font its style names at
/// `scale`: what a stack's strip measures its tabs by (task 1583,
/// `pane_frames`), with the fonts the scene painter draws them in.
pub(crate) unsafe fn measure_words(dc: HDC, scale: f64, words: &[(&str, Style)]) -> Vec<f64> {
    let mut fonts = Fonts { dpi: (scale * 96.0).round() as i32, made: Vec::new() };
    words
        .iter()
        .map(|(text, style)| unsafe { text_width(dc, fonts.get(style), text) } as f64 / scale.max(0.1))
        .collect()
}

unsafe fn part_width(dc: HDC, at: Px, part: &Part, fonts: &mut Fonts) -> i32 {
    match &part.piece {
        Piece::Words { text, style } => unsafe { text_width(dc, fonts.get(style), text) },
        Piece::Glyph { size, .. } => at.len(*size),
        Piece::Held { size, .. } | Piece::Mark { size, .. } => at.len(*size),
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
        // A terminal the person is holding: two bars, in the box a status
        // glyph has. It does not move.
        Piece::Held { color, size } => {
            let side = at.len(*size);
            let top = r.top + (r.bottom - r.top - side) / 2;
            unsafe { draw_shapes(dc, r.left, top, side, &glyph::held(), *color, 1.0) };
        }
        Piece::Mark { mark, color, size } => {
            let side = at.len(*size);
            let top = r.top + (r.bottom - r.top - side) / 2;
            unsafe { draw_shapes(dc, r.left, top, side, &glyph::mark(*mark), *color, 1.0) };
        }
    }
}

/// One line of parts. Where each goes, and which of them gives way when
/// they do not all fit, is `scene::place_line`, which is tested; this
/// measures the words and paints.
unsafe fn paint_line(dc: HDC, at: Px, r: RECT, parts: &[Part], fonts: &mut Fonts, t: f64) {
    let measured: Vec<(Side, i32, i32)> = parts.iter().map(|p| (p.side, at.len(p.gap), unsafe { part_width(dc, at, p, fonts) })).collect();
    for (part, placed) in parts.iter().zip(scene::place_line(r.left, r.right, &measured)) {
        let Some(placed) = placed else { continue };
        let box_ = RECT { left: placed.left, top: r.top, right: placed.right, bottom: r.bottom };
        unsafe { paint_piece(dc, at, &part.piece, box_, fonts, t, placed.cut) };
    }
}

/// A rounded rectangle. A small one is drawn with soft corners; a large one
/// (the panel itself) with GDI's own, because a mask that size is tens of
/// megabytes a paint and its corners sit on a ground nearly its own colour.
pub(crate) unsafe fn round(dc: HDC, r: RECT, radius: i32, color: Rgba, edge: Option<Rgba>) {
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
    unsafe { draw_shapes(dc, x, y, side, &glyph::shapes(shown, spin), color, opacity) };
}

/// Shapes on the status glyphs' artboard, in a square `side` pixels across
/// with its top left at `x, y`.
unsafe fn draw_shapes(dc: HDC, x: i32, y: i32, side: i32, shapes: &[glyph::Shape], color: Rgba, opacity: f64) {
    if shapes.is_empty() || side <= 0 {
        return;
    }
    let unit = (side * SS) as f64 / status::ARTBOARD;
    let u = |v: f64| (v * unit).round() as i32;
    unsafe {
        blend(dc, x, y, side, side, color, opacity, &|m| {
            for shape in shapes {
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
