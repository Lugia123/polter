//! Dragging a pane to another split, tab or window by its title or its
//! handle; and the two things drawn over the terminals that go with it, the
//! handle's dots and the veil over a pane without the keyboard (task 1549).
//!
//! **What is decided where.** Every rule -- where a pane is picked up, when
//! a press is a drag, which zone the pointer is in, what letting go does,
//! when another tab comes to the front, when the dots show -- is
//! `polter_split_tree::drag`, held there to the macOS host's answers and
//! tested off Windows. This file is the part that needs Windows: the
//! pointer, the capture, the windows drawn over the panes, and the calls
//! into the tab model that move a pane (`tabs::move_pane`,
//! `tabs::pane_to_new_window`).
//!
//! **Deviation: no system drag session.** macOS hands the gesture to
//! `NSDraggingSession`. Every window a pane can be let go on is one of ours,
//! on this thread, so here it is a mouse capture on the frame the pane was
//! picked up in, and the pointer is read with `GetCursorPos` in screen
//! coordinates -- which a pointer over another window, or over none, still
//! has. The other deviation that follows: there is no 0.2 scale picture of
//! the terminal under the pointer, which a GL child window cannot be asked
//! for; the pointer is the move cursor for the length of the drag.
//!
//! **The windows drawn over the terminals are layered popups owned by the
//! frame**, not children: a terminal is a GL child window and nothing a
//! sibling paints can be translucent over it. Owned, they stay above their
//! frame and nothing else, go with it when it is minimised, and are
//! destroyed with it. `WS_EX_TRANSPARENT` passes every click through to the
//! terminal underneath, which is also why the handle is pressed through the
//! terminal's own window procedure (`handle_press`) and not through its dots.
//!
//! **Main thread only.** The state is a `thread_local`; no window call is
//! made with it borrowed (`borrow-across-dispatch.py`).

use std::cell::RefCell;
use std::time::Instant;

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture, TrackMouseEvent, TME_LEAVE, TRACKMOUSEEVENT, VK_ESCAPE};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_split_tree::drag::{self, Dwell, Ending, Grip, Over, Setting, Situation, StripTarget, TitleGrip};
use polter_split_tree::{PaneId, Rect};

use crate::tabs::{self, TabId};
use crate::{plogf, wlogf};

/// How often a drag looks again while the pointer is still: a dwell over a
/// tab has to end without the pointer moving, and the bar under that tab
/// fills as it goes -- so a frame's worth, not a tenth of a second.
const DWELL_TICK_MS: u32 = 16;
const TIMER_DWELL: usize = 0xD2A6;

/// The pointer's business with a pane. **Names the pane, never a position**:
/// a drag can move it, and the tab it is in.
enum Gesture {
    Idle,
    /// Down on a title or a handle; not yet far enough to be a drag.
    Pressed {
        frame: isize,
        pane: PaneId,
        at: POINT,
        threshold: f64,
        /// Moving it drags it (`TitleGrip::Drag`, or the handle).
        drags: bool,
        /// Letting go without a drag gives it the keyboard (a title). The
        /// handle does nothing else, as on macOS.
        clicks: bool,
    },
    Dragging(Drag),
}

struct Drag {
    /// Where it was picked up; the frame holding the capture.
    frame: isize,
    pane: PaneId,
    /// Its tab had more than one pane when it was picked up.
    from_split: bool,
    dwell: Dwell<(isize, u64)>,
    began: Instant,
}

/// What a layered popup over a terminal is for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    /// The half of a pane a dropped pane would go into.
    Zone,
    /// The veil over a pane that does not have the keyboard.
    Dim,
    /// The dots of a pane's handle.
    Handle,
}

/// One popup, and what it was last shown as -- so a sync that changes
/// nothing calls nothing.
struct Layer {
    hwnd: isize,
    kind: Kind,
    owner: isize,
    pane: PaneId,
    shown: Option<(RECT, u32, u8)>,
}

thread_local! {
    static GESTURE: RefCell<Gesture> = const { RefCell::new(Gesture::Idle) };
    static LAYERS: RefCell<Vec<Layer>> = const { RefCell::new(Vec::new()) };
    /// The pane the pointer is over, for the handle's dots under `auto`.
    static POINTER_PANE: RefCell<Option<isize>> = const { RefCell::new(None) };
}

// ----------------------------------------------------------------- config

/// `drag-handle`, read when it is asked for; `auto` when it cannot be read.
fn setting() -> Setting {
    let cfg = crate::config_handle();
    let Some(api) = crate::api_opt() else { return Setting::Auto };
    if cfg.is_null() {
        return Setting::Auto;
    }
    let mut p: *const std::ffi::c_char = std::ptr::null();
    let key = "drag-handle";
    let ok = unsafe { (api.config_get)(cfg, &mut p as *mut _ as *mut std::ffi::c_void, key.as_ptr(), key.len()) };
    if !ok || p.is_null() {
        return Setting::Auto;
    }
    Setting::parse(unsafe { std::ffi::CStr::from_ptr(p) }.to_str().unwrap_or(""))
}

/// The veil's colour and opacity: `unfocused-split-fill` (the terminal's
/// `background` when it is not set) at `1 - unfocused-split-opacity`, the
/// macOS host's arithmetic.
fn veil() -> (COLORREF, f64) {
    let cfg = crate::config_handle();
    let Some(api) = crate::api_opt() else { return (COLORREF(0), 0.0) };
    if cfg.is_null() {
        return (COLORREF(0), 0.0);
    }
    let mut opacity: f64 = 0.7;
    let key = "unfocused-split-opacity";
    unsafe { (api.config_get)(cfg, &mut opacity as *mut f64 as *mut std::ffi::c_void, key.as_ptr(), key.len()) };
    let mut c = crate::ffi::ConfigColor::default();
    let key = "unfocused-split-fill";
    let fill = unsafe { (api.config_get)(cfg, &mut c as *mut _ as *mut std::ffi::c_void, key.as_ptr(), key.len()) }
        .then(|| COLORREF(c.r as u32 | (c.g as u32) << 8 | (c.b as u32) << 16))
        .or_else(crate::divider::terminal_background)
        .unwrap_or(COLORREF(0));
    (fill, drag::veil_opacity(opacity))
}

/// The accent the zone is lit in: the system's highlight colour.
fn accent() -> COLORREF {
    COLORREF(unsafe { GetSysColor(COLOR_HIGHLIGHT) })
}

/// The dots' colour: the terminal's foreground side of its background.
fn dots_color() -> COLORREF {
    match crate::divider::terminal_background() {
        Some(c) if drag::is_light((c.0 & 0xff) as u8, ((c.0 >> 8) & 0xff) as u8, ((c.0 >> 16) & 0xff) as u8) => COLORREF(0),
        Some(_) | None => COLORREF(0x00ffffff),
    }
}

// --------------------------------------------------------------- the pane

/// What the rules need to know about `pane`, from the window it is in.
fn situation(frame: HWND, pane: PaneId) -> Option<(Situation, f64)> {
    let win = tabs::window(frame)?;
    let tab = win.tabs.iter().find(|t| t.panes().iter().any(|p| p.id == pane))?;
    let split = tab.terminal().is_some_and(|t| t.tree.is_split());
    let lent = win.shown_on_loan().is_some_and(|l| l.pane == pane);
    let titled = win.pane_frames.ground && win.pane_frames.panes.iter().any(|p| p.pane == pane && p.drawn.is_some());
    Some((Situation { titled, lent, split }, win.scale.max(0.1)))
}

fn cursor() -> POINT {
    let mut p = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut p);
    }
    p
}

fn client_rect(hwnd: HWND) -> Rect {
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    Rect::new(0.0, 0.0, (rc.right - rc.left) as f64, (rc.bottom - rc.top) as f64)
}

fn to_screen(owner: HWND, r: Rect) -> RECT {
    let mut tl = POINT { x: r.x.round() as i32, y: r.y.round() as i32 };
    unsafe {
        let _ = ClientToScreen(owner, &mut tl);
    }
    RECT { left: tl.x, top: tl.y, right: tl.x + r.w.round() as i32, bottom: tl.y + r.h.round() as i32 }
}

// ----------------------------------------------------------------- press

/// A press on the frame's content area, at `(x, y)` in its pixels. **True
/// when it was on a pane's title**, and then this has taken it.
pub fn title_press(frame: HWND, x: i32, y: i32) -> bool {
    let Some(pane) = crate::pane_frames::title_at(frame, x, y) else { return false };
    let Some((s, scale)) = situation(frame, pane) else { return false };
    match drag::title_grip(setting(), s) {
        // A lent pane's placeholder: its terminal is in the control room.
        TitleGrip::None => {
            wlogf!(frame, "[drag] press on pane {}'s title: it is lent to the control room, so nothing", pane);
        }
        TitleGrip::Drag => press(frame, pane, drag::px(drag::TITLE_DRAG_THRESHOLD_PT, scale), true, true),
        TitleGrip::Click => press(frame, pane, 0.0, false, true),
    }
    true
}

/// A press inside a terminal's own window, at `(x, y)` in its pixels.
/// **True when it was on the pane's handle**: then this has taken it, and
/// the terminal is not told.
pub fn handle_press(pane_hwnd: HWND, x: i32, y: i32) -> bool {
    let Some((frame, _, pane)) = tabs::pane_of(pane_hwnd) else { return false };
    let Some((s, scale)) = situation(frame, pane) else { return false };
    if drag::place(setting(), s) != Grip::Handle {
        return false;
    }
    if !drag::contains(&drag::handle_rect(client_rect(pane_hwnd), scale), (x as f64, y as f64)) {
        return false;
    }
    // The handle has no threshold: it does nothing but drag.
    press(frame, pane, 0.0, true, false);
    true
}

fn press(frame: HWND, pane: PaneId, threshold: f64, drags: bool, clicks: bool) {
    let at = cursor();
    GESTURE.with(|g| *g.borrow_mut() = Gesture::Pressed { frame: frame.0 as isize, pane, at, threshold, drags, clicks });
    unsafe {
        SetCapture(frame);
    }
}

/// Whether a press or a drag of a pane is under way.
pub fn active() -> bool {
    GESTURE.with(|g| !matches!(*g.borrow(), Gesture::Idle))
}

// ------------------------------------------------------------------ move

enum Step {
    Wait,
    Begin { frame: isize, pane: PaneId },
    Track,
}

/// The pointer moved while the frame holds the capture. **True when a pane
/// gesture took it**; the strip's own drag is the other owner of the
/// capture.
pub fn on_move() -> bool {
    let now = cursor();
    let step = GESTURE.with(|g| match &*g.borrow() {
        Gesture::Idle => None,
        Gesture::Pressed { frame, pane, at, threshold, drags, .. } => {
            let moved = drag::started((at.x as f64, at.y as f64), (now.x as f64, now.y as f64), *threshold);
            Some(if *drags && moved {
                Step::Begin { frame: *frame, pane: *pane }
            } else {
                Step::Wait
            })
        }
        Gesture::Dragging(_) => Some(Step::Track),
    });
    match step {
        None => return false,
        Some(Step::Wait) => return true,
        Some(Step::Begin { frame, pane }) => begin(HWND(frame as *mut core::ffi::c_void), pane),
        Some(Step::Track) => {}
    }
    track(now);
    true
}

fn begin(frame: HWND, pane: PaneId) {
    let from_split = situation(frame, pane).is_some_and(|(s, _)| s.split);
    GESTURE.with(|g| {
        *g.borrow_mut() = Gesture::Dragging(Drag { frame: frame.0 as isize, pane, from_split, dwell: Dwell::default(), began: Instant::now() });
    });
    unsafe {
        SetTimer(Some(frame), TIMER_DWELL, DWELL_TICK_MS, Some(dwell_tick));
        if let Ok(c) = LoadCursorW(None, IDC_SIZEALL) {
            SetCursor(Some(c));
        }
    }
    wlogf!(frame, "[drag] pane {} picked up (its tab {} split)", pane, if from_split { "is" } else { "is not" });
}

unsafe extern "system" fn dwell_tick(_frame: HWND, _msg: u32, _id: usize, _time: u32) {
    if GESTURE.with(|g| matches!(*g.borrow(), Gesture::Dragging(_))) {
        track(cursor());
    }
}

/// What is under the pointer, for a drag of `dragged`.
struct Target {
    over: Over,
    /// The frame it is over, when it is one.
    frame: Option<HWND>,
    /// What lights up, on the screen.
    lit: Option<RECT>,
    /// A tab of a frame's strip that is not the one in front, under the
    /// middle of which the pointer is (`StripTarget::BringForward`).
    tab: Option<(HWND, TabId)>,
}

thread_local! {
    /// The frame whose strip shows a dragged pane's hint, so that moving to
    /// another one, or letting go, takes it away there.
    static HINTED: RefCell<Option<isize>> = const { RefCell::new(None) };
}

/// Show what a dragged pane would do in `frame`'s strip -- or, with no
/// frame, in nobody's -- taking it away from the strip that had it.
fn hint(frame: Option<HWND>, gap: Option<usize>, dwell: Option<(TabId, f64)>) {
    let want = frame.filter(|_| gap.is_some() || dwell.is_some());
    let was = HINTED.with(|h| std::mem::replace(&mut *h.borrow_mut(), want.map(|f| f.0 as isize)));
    if let Some(w) = was.filter(|w| Some(*w) != want.map(|f| f.0 as isize)) {
        let w = HWND(w as *mut core::ffi::c_void);
        if tabs::is_frame(w) {
            crate::strip::set_pane_hint(w, None, None);
        }
    }
    if let Some(f) = want {
        crate::strip::set_pane_hint(f, gap, dwell);
    }
}

/// `home` is the frame the pane was picked up in, and `from_split` whether
/// its tab had other panes: a pane alone in its tab is offered no gap in
/// its own strip (`strip_target`'s `alone`).
fn target_at(pt: POINT, dragged: PaneId, home: isize, from_split: bool) -> Target {
    let nothing = |over| Target { over, frame: None, lit: None, tab: None };
    let hit = unsafe { WindowFromPoint(pt) };
    if hit.0.is_null() {
        return nothing(Over::Outside);
    }
    let root = unsafe { GetAncestor(hit, GA_ROOT) };
    if !tabs::is_frame(root) {
        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(root, Some(&mut pid)) };
        // Any window of ours counts as somewhere, the way macOS asks
        // `NSApplication.shared.windows`: letting go over the settings
        // window does not open a terminal window behind it.
        return nothing(if pid == unsafe { GetCurrentProcessId() } { Over::Window } else { Over::Outside });
    }
    let mut at = pt;
    unsafe {
        let _ = ScreenToClient(root, &mut at);
    }
    let sh = crate::strip::strip_h(tabs::scale_of(root));
    if at.y < sh {
        let (spans, ids, active) = crate::strip::pane_drag_tabs(root);
        let alone = !from_split && root.0 as isize == home;
        let (over, tab) = match drag::strip_target(at.x as f64, &spans, Some(active), alone) {
            StripTarget::Insert(gap) => (Over::Strip(gap), None),
            StripTarget::BringForward(i) => (Over::Window, ids.get(i).map(|t| (root, *t))),
            StripTarget::Nothing => (Over::Window, None),
        };
        return Target { over, frame: Some(root), lit: None, tab };
    }
    let p = (at.x as f64, at.y as f64);
    for (pane, px) in crate::pane_frames::showing(root) {
        let r = Rect::new(px.x as f64, px.y as f64, px.w as f64, px.h as f64);
        if !drag::contains(&r, p) {
            continue;
        }
        let zone = drag::Zone::at(r, p);
        let over = Over::Pane { pane, zone, own: pane == dragged };
        let lit = drag::lit(over).map(|(_, z)| to_screen(root, z.highlight(r)));
        return Target { over, frame: Some(root), lit, tab: None };
    }
    Target { over: Over::Window, frame: Some(root), lit: None, tab: None }
}

fn track(pt: POINT) {
    let Some((pane, began, home, from_split)) = GESTURE.with(|g| match &*g.borrow() {
        Gesture::Dragging(d) => Some((d.pane, d.began, d.frame, d.from_split)),
        Gesture::Idle | Gesture::Pressed { .. } => None,
    }) else {
        return;
    };
    let t = target_at(pt, pane, home, from_split);
    let key = t.tab.map(|(f, id)| (f.0 as isize, id.0));
    let now = began.elapsed().as_secs_f64();
    let (switch, waiting) = GESTURE.with(|g| match &mut *g.borrow_mut() {
        Gesture::Dragging(d) => (d.dwell.at(key, now), d.dwell.tab().zip(d.dwell.progress(now))),
        Gesture::Idle | Gesture::Pressed { .. } => (None, None),
    });
    if let Some((f, id)) = switch {
        let frame = HWND(f as *mut core::ffi::c_void);
        wlogf!(frame, "[drag] pane {} held over tab {} for {}s; bringing it to the front", pane, id, drag::TAB_DWELL_SECS);
        tabs::activate_tab(frame, TabId(id));
    }
    let gap = match t.over {
        Over::Strip(gap) => Some(gap),
        Over::Pane { .. } | Over::Window | Over::Outside => None,
    };
    hint(t.frame, gap, waiting.map(|((_, id), p)| (TabId(id), p)));
    match (t.frame, t.lit) {
        (Some(owner), Some(rc)) => show(Kind::Zone, owner, 0, rc, accent().0, (drag::HIGHLIGHT_OPACITY * 255.0).round() as u8),
        _ => hide_kind(Kind::Zone),
    }
    unsafe {
        if let Ok(c) = LoadCursorW(None, IDC_SIZEALL) {
            SetCursor(Some(c));
        }
    }
}

// ---------------------------------------------------------------- ending

/// The button came up while the frame holds the capture. **True when a
/// pane gesture took it.**
pub fn on_up() -> bool {
    let was = GESTURE.with(|g| std::mem::replace(&mut *g.borrow_mut(), Gesture::Idle));
    match was {
        Gesture::Idle => false,
        Gesture::Pressed { frame, pane, clicks, .. } => {
            unsafe {
                let _ = ReleaseCapture();
            }
            let frame = HWND(frame as *mut core::ffi::c_void);
            if clicks {
                // The click gives the pane the keyboard -- the same call a
                // click inside the terminal makes.
                match tabs::pane_hwnd(frame, pane) {
                    Some(h) => tabs::focus_pane_at(h),
                    None => wlogf!(frame, "[drag] click on pane {}'s title: it is gone", pane),
                }
            }
            true
        }
        Gesture::Dragging(d) => {
            finish(d, None);
            true
        }
    }
}

/// End a drag: where the pointer is now, unless `cancelled` says why not.
fn finish(d: Drag, cancelled: Option<&str>) {
    let frame = HWND(d.frame as *mut core::ffi::c_void);
    unsafe {
        let _ = KillTimer(Some(frame), TIMER_DWELL);
        let _ = ReleaseCapture();
    }
    hide_kind(Kind::Zone);
    hint(None, None, None);
    let pt = cursor();
    let t = target_at(pt, d.pane, d.frame, d.from_split);
    let ending = drag::ending(t.over, d.from_split, cancelled.is_some());
    if let Some(why) = cancelled {
        wlogf!(frame, "[drag] pane {} put back: {}", d.pane, why);
        sync(frame);
        return;
    }
    match (ending, t.frame) {
        (Ending::Move { onto, zone }, Some(dst)) => {
            tabs::move_pane(frame, d.pane, dst, onto, zone.direction());
        }
        (Ending::Move { onto, .. }, None) => {
            wlogf!(frame, "[drag] pane {} let go on pane {} in no window; nothing", d.pane, onto);
        }
        (Ending::NewTab(index), Some(dst)) => {
            tabs::pane_to_new_tab(frame, d.pane, dst, index);
        }
        (Ending::NewTab(index), None) => {
            wlogf!(frame, "[drag] pane {} let go in gap {} of no window; nothing", d.pane, index);
        }
        (Ending::NewWindow, _) => {
            let hinst: HINSTANCE = unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }.map(Into::into).unwrap_or_default();
            tabs::pane_to_new_window(frame, d.pane, pt, hinst);
        }
        (Ending::Nothing, _) => {
            wlogf!(frame, "[drag] pane {} let go where it does nothing ({:?}); it stays", d.pane, t.over);
        }
    }
    if tabs::is_frame(frame) {
        sync(frame);
    }
}

/// Stop whatever pane gesture is under way, as if it had not started.
pub fn cancel(why: &str) {
    let was = GESTURE.with(|g| std::mem::replace(&mut *g.borrow_mut(), Gesture::Idle));
    match was {
        Gesture::Idle => {}
        Gesture::Pressed { .. } => unsafe {
            let _ = ReleaseCapture();
        },
        Gesture::Dragging(d) => finish(d, Some(why)),
    }
}

/// The frame lost the capture. A gesture that is still under way did not
/// end by the button coming up -- Alt+Tab, a dialog -- and is put back.
pub fn capture_lost() {
    if active() {
        cancel("the capture was taken away");
    }
}

/// From the message loop, before a key is dispatched: Esc while something
/// is being dragged cancels it, and goes nowhere else. **True when it was
/// taken.**
pub fn pre_translate(msg: &MSG) -> bool {
    if msg.message != WM_KEYDOWN || msg.wParam.0 as u16 != VK_ESCAPE.0 {
        return false;
    }
    if active() {
        cancel("Esc");
        return true;
    }
    crate::strip::cancel_drag("Esc")
}

// ---------------------------------------------------------------- cursor

/// `WM_SETCURSOR` over a frame's content area: the move cursor over a title
/// that drags. **True when it was answered.**
pub fn title_cursor(frame: HWND) -> bool {
    let mut at = cursor();
    unsafe {
        let _ = ScreenToClient(frame, &mut at);
    }
    let Some(pane) = crate::pane_frames::title_at(frame, at.x, at.y) else { return false };
    let Some((s, _)) = situation(frame, pane) else { return false };
    if drag::title_grip(setting(), s) != TitleGrip::Drag {
        return false;
    }
    set_move_cursor()
}

/// `WM_SETCURSOR` over a terminal: the move cursor over its handle. **True
/// when it was answered.**
pub fn handle_cursor(pane_hwnd: HWND) -> bool {
    let Some((frame, _, pane)) = tabs::pane_of(pane_hwnd) else { return false };
    let Some((s, scale)) = situation(frame, pane) else { return false };
    if drag::place(setting(), s) != Grip::Handle {
        return false;
    }
    let mut at = cursor();
    unsafe {
        let _ = ScreenToClient(pane_hwnd, &mut at);
    }
    if !drag::contains(&drag::handle_rect(client_rect(pane_hwnd), scale), (at.x as f64, at.y as f64)) {
        return false;
    }
    set_move_cursor()
}

fn set_move_cursor() -> bool {
    match unsafe { LoadCursorW(None, IDC_SIZEALL) } {
        Ok(c) => {
            unsafe { SetCursor(Some(c)) };
            true
        }
        Err(_) => false,
    }
}

/// The pointer moved over a terminal: the handle's dots under `auto` follow
/// it.
pub fn pane_pointer(pane_hwnd: HWND) {
    let key = pane_hwnd.0 as isize;
    let was = POINTER_PANE.with(|p| p.borrow_mut().replace(key));
    if was != Some(key) {
        let mut tme = TRACKMOUSEEVENT { cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32, dwFlags: TME_LEAVE, hwndTrack: pane_hwnd, dwHoverTime: 0 };
        unsafe {
            let _ = TrackMouseEvent(&mut tme);
        }
    }
    if let Some((frame, _, _)) = tabs::pane_of(pane_hwnd) {
        sync_handles(frame);
    }
}

/// The pointer left a terminal.
pub fn pane_pointer_left(pane_hwnd: HWND) {
    let key = pane_hwnd.0 as isize;
    POINTER_PANE.with(|p| {
        let mut p = p.borrow_mut();
        if *p == Some(key) {
            *p = None;
        }
    });
    if let Some((frame, _, _)) = tabs::pane_of(pane_hwnd) {
        sync_handles(frame);
    }
}

// ---------------------------------------------------------------- layers

/// Put the dots and the veils of `frame` where its panes are now. Called at
/// the end of every layout, when the keyboard moves, and when the frame
/// moves.
pub fn sync(frame: HWND) {
    sync_veils(frame);
    sync_handles(frame);
}

/// The panes showing in the tab in front, with their windows.
fn showing_panes(frame: HWND) -> Vec<(PaneId, HWND, bool)> {
    let Some(win) = tabs::window(frame) else { return Vec::new() };
    let Some(tab) = win.tabs.get(win.active) else { return Vec::new() };
    let focused = tab.focused();
    tab.panes().iter().map(|p| (p.id, HWND(p.hwnd as *mut core::ffi::c_void), Some(p.id) == focused)).collect()
}

fn window_rect(h: HWND) -> RECT {
    let mut rc = RECT::default();
    unsafe {
        let _ = GetWindowRect(h, &mut rc);
    }
    rc
}

fn sync_veils(frame: HWND) {
    let split = tabs::window(frame).and_then(|w| w.tabs.get(w.active).and_then(|t| t.terminal().map(|t| t.tree.is_split()))).unwrap_or(false);
    let (fill, opacity) = veil();
    let alpha = (opacity * 255.0).round() as u8;
    let shown_frame = unsafe { IsWindowVisible(frame).as_bool() && !IsIconic(frame).as_bool() };
    let mut want = Vec::new();
    for (pane, h, focused) in showing_panes(frame) {
        let visible = unsafe { IsWindowVisible(h).as_bool() };
        if shown_frame && visible && drag::dimmed(split, focused) && alpha > 0 {
            want.push((pane, window_rect(h), alpha));
        }
    }
    apply(Kind::Dim, frame, &want, fill.0);
}

fn sync_handles(frame: HWND) {
    let set = setting();
    let pointer = POINTER_PANE.with(|p| *p.borrow());
    let dragging = GESTURE.with(|g| match &*g.borrow() {
        Gesture::Dragging(d) => Some(d.pane),
        Gesture::Idle | Gesture::Pressed { .. } => None,
    });
    let shown_frame = unsafe { IsWindowVisible(frame).as_bool() && !IsIconic(frame).as_bool() };
    let mut want = Vec::new();
    for (pane, h, _) in showing_panes(frame) {
        if !shown_frame || !unsafe { IsWindowVisible(h).as_bool() } {
            continue;
        }
        let Some((s, scale)) = situation(frame, pane) else { continue };
        if drag::place(set, s) != Grip::Handle {
            continue;
        }
        let rect = client_rect(h);
        let at = (pointer == Some(h.0 as isize)).then(|| {
            let mut p = cursor();
            unsafe {
                let _ = ScreenToClient(h, &mut p);
            }
            (p.x as f64, p.y as f64)
        });
        let hidden = crate::mouse::hidden(tabs::surface_of(h) as usize);
        if !drag::handle_shown(set, rect, scale, at, dragging == Some(pane), !hidden) {
            continue;
        }
        let on_handle = at.is_some_and(|p| drag::contains(&drag::handle_rect(rect, scale), p));
        let opacity = if on_handle { drag::HANDLE_OPACITY_HOVER } else { drag::HANDLE_OPACITY };
        want.push((pane, to_screen(h, drag::handle_rect(rect, scale)), (opacity * 255.0).round() as u8));
    }
    apply(Kind::Handle, frame, &want, dots_color().0);
}

/// Show exactly the layers of `kind` over `frame` that `want` lists, and
/// hide the rest of that kind there.
fn apply(kind: Kind, frame: HWND, want: &[(PaneId, RECT, u8)], color: u32) {
    let owner = frame.0 as isize;
    let stale: Vec<isize> = LAYERS.with(|l| {
        l.borrow()
            .iter()
            .filter(|x| x.kind == kind && x.owner == owner && x.shown.is_some() && !want.iter().any(|(p, _, _)| *p == x.pane))
            .map(|x| x.hwnd)
            .collect()
    });
    for h in stale {
        hide_one(h);
    }
    for (pane, rc, alpha) in want {
        show(kind, frame, *pane, *rc, color, *alpha);
    }
}

/// Show one layer of `kind` for `pane` over `owner` at `rc`, making it the
/// first time.
fn show(kind: Kind, owner: HWND, pane: PaneId, rc: RECT, color: u32, alpha: u8) {
    let key = owner.0 as isize;
    // The zone is one window for the whole process: there is one drag.
    let found = LAYERS.with(|l| {
        l.borrow().iter().find(|x| x.kind == kind && (kind == Kind::Zone || (x.owner == key && x.pane == pane))).map(|x| (x.hwnd, x.owner, x.shown))
    });
    let (hwnd, was_owner, was_shown) = match found {
        Some(f) => f,
        None => {
            let Some(h) = create(owner, kind) else { return };
            LAYERS.with(|l| l.borrow_mut().push(Layer { hwnd: h.0 as isize, kind, owner: key, pane, shown: None }));
            (h.0 as isize, key, None)
        }
    };
    let now = Some((rc, color, alpha));
    if was_shown == now && was_owner == key {
        return;
    }
    let h = HWND(hwnd as *mut core::ffi::c_void);
    unsafe {
        if was_owner != key {
            SetWindowLongPtrW(h, GWLP_HWNDPARENT, key);
        }
        SetWindowLongPtrW(h, GWLP_USERDATA, color as isize);
        let flags = match kind {
            Kind::Handle => LWA_COLORKEY | LWA_ALPHA,
            Kind::Zone | Kind::Dim => LWA_ALPHA,
        };
        let _ = SetLayeredWindowAttributes(h, COLORREF(KEY), alpha, flags);
        // **Not raised over the screen.** An owned popup already stays above
        // its frame, and goes up with it when it is brought forward; raising
        // one to the top from a layout would put a veil over whatever other
        // program is in front of a frame that is behind. The dots go above
        // the veils, which is only a question while their frame is in front.
        // The zone is always raised: it is shown only under the pointer of a
        // drag, over whichever window the pointer is on -- which may be above
        // the frame that made it.
        let raise = match kind {
            Kind::Zone => true,
            Kind::Handle => GetForegroundWindow() == owner,
            Kind::Dim => false,
        };
        let order = if raise { SWP_NOACTIVATE | SWP_SHOWWINDOW } else { SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOZORDER };
        let _ = SetWindowPos(h, Some(HWND_TOP), rc.left, rc.top, (rc.right - rc.left).max(1), (rc.bottom - rc.top).max(1), order);
        let _ = InvalidateRect(Some(h), None, true);
    }
    LAYERS.with(|l| {
        if let Some(x) = l.borrow_mut().iter_mut().find(|x| x.hwnd == hwnd) {
            x.owner = key;
            x.pane = pane;
            x.shown = now;
        }
    });
}

fn hide_one(hwnd: isize) {
    unsafe {
        let _ = ShowWindow(HWND(hwnd as *mut core::ffi::c_void), SW_HIDE);
    }
    LAYERS.with(|l| {
        if let Some(x) = l.borrow_mut().iter_mut().find(|x| x.hwnd == hwnd) {
            x.shown = None;
        }
    });
}

fn hide_kind(kind: Kind) {
    let shown: Vec<isize> = LAYERS.with(|l| l.borrow().iter().filter(|x| x.kind == kind && x.shown.is_some()).map(|x| x.hwnd).collect());
    for h in shown {
        hide_one(h);
    }
}

/// The frame is going: Windows destroys the windows it owns, and this drops
/// them from the list -- a recycled handle must not find somebody else's.
pub fn forget(frame: HWND) {
    let key = frame.0 as isize;
    LAYERS.with(|l| l.borrow_mut().retain(|x| x.owner != key));
}

/// The colour a handle's window is cleared to, which the colour key makes
/// see-through: the dots are all that shows.
const KEY: u32 = 0x00ff00ff;

static REGISTERED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn init(hinst: HINSTANCE) {
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        lpfnWndProc: Some(layer_proc),
        hInstance: hinst,
        lpszClassName: w!("PolterLayer"),
        ..Default::default()
    };
    if unsafe { RegisterClassExW(&wc) } == 0 {
        // absence: means it was not reached -- the class registered.
        // process-wide: one window class for the process
        plogf!("[drag] RegisterClassExW(PolterLayer) failed; nothing will be drawn over the terminals");
        return;
    }
    REGISTERED.store(true, std::sync::atomic::Ordering::Release);
}

fn create(owner: HWND, kind: Kind) -> Option<HWND> {
    if !REGISTERED.load(std::sync::atomic::Ordering::Acquire) {
        return None;
    }
    let hinst: HINSTANCE = unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }.map(Into::into).unwrap_or_default();
    let made = unsafe {
        CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            w!("PolterLayer"),
            None,
            WS_POPUP,
            0,
            0,
            1,
            1,
            Some(owner),
            None,
            Some(hinst),
            None,
        )
    };
    match made {
        Ok(h) => {
            unsafe {
                SetWindowLongPtrW(h, GWLP_ID, kind as isize);
                // Straight above its frame, not at the top of the screen: a
                // new window starts at the top, and a frame that is behind
                // another program's window would get a veil over that
                // program. Below whatever is above the frame is just above
                // the frame.
                let above = GetWindow(owner, GW_HWNDPREV).ok().filter(|w| !w.0.is_null());
                let _ = SetWindowPos(h, Some(above.unwrap_or(HWND_TOP)), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            }
            Some(h)
        }
        Err(e) => {
            wlogf!(owner, "[drag] could not make the {:?} layer: {e:?}", kind);
            None
        }
    }
}

extern "system" fn layer_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            // Click-through even where the colour key does not make it so.
            WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                let mut rc = RECT::default();
                let _ = GetClientRect(hwnd, &mut rc);
                let color = COLORREF(GetWindowLongPtrW(hwnd, GWLP_USERDATA) as u32);
                let handle = GetWindowLongPtrW(hwnd, GWLP_ID) == Kind::Handle as isize;
                if handle {
                    let back = CreateSolidBrush(COLORREF(KEY));
                    FillRect(hdc, &rc, back);
                    let _ = DeleteObject(back.into());
                    let dpi = windows::Win32::UI::HiDpi::GetDpiForWindow(hwnd).max(96) as f64 / 96.0;
                    for (x, y, d) in drag::dots(rc.right as f64, rc.bottom as f64, dpi) {
                        let b = CreateSolidBrush(color);
                        let old = SelectObject(hdc, b.into());
                        let pen = SelectObject(hdc, GetStockObject(NULL_PEN));
                        let _ = Ellipse(hdc, x.round() as i32, y.round() as i32, (x + d).round() as i32, (y + d).round() as i32);
                        SelectObject(hdc, pen);
                        SelectObject(hdc, old);
                        let _ = DeleteObject(b.into());
                    }
                } else {
                    let b = CreateSolidBrush(color);
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                }
                let _ = EndPaint(hwnd, &ps);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}
