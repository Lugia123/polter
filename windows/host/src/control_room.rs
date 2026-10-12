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
//!  * **No keyboard way out.** With the panel focused the terminal's key
//!    path is not running, so no binding fires: up, down and Enter are
//!    handled here and nothing else is. Leaving is a click on another tab.
//!    (`dev-docs/windows/control-room.md` 2.1 has the plan: `ghostty_app_key`
//!    and a closed table of tab bindings.)
//!  * **No UI Automation provider.** A screen reader finds the tab and
//!    nothing in it.
//!  * **No soft shadows, and no refraction on the chip**: GDI has no blur.
//!  * **The selection is kept for the life of the process only**, not across
//!    a restart.
//!  * **Which group is selected when it first opens** is whichever was
//!    selected last, or none: "the first group with an agent in it" needs a
//!    field the snapshot does not carry in this tree yet.

use std::cell::RefCell;
use std::ffi::c_void;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{SetFocus, VK_DOWN, VK_RETURN, VK_UP};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_control_room::act::{self, Dwell, SeenMarker};
use polter_control_room::glyph::{self, Outline};
use polter_control_room::layout::{self, ListLayout, Rect, Room};
use polter_control_room::list::{self, List};
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
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
    /// The selected group, by name. **Outside `State` on purpose**: closing
    /// the control room's tab destroys the panel, and opening it again
    /// should find the same group selected.
    static SELECTION: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn selection() -> Option<String> {
    SELECTION.with(|s| s.borrow().clone())
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
        STATE.with(|s| {
            *s.borrow_mut() =
                Some(State { hwnd: hwnd.0 as isize, slide: None, seen: SeenMarker::default(), dwell: None })
        });
        // A group that went away while the control room was closed must not
        // leave a selection pointing at nothing.
        reconcile_selection();
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
    reconcile_selection();
    // A row that has just become unseen while it sits selected is worth a
    // wait of its own -- but never by cutting short one already running.
    let waiting = STATE.with(|s| s.borrow().as_ref().is_some_and(|st| st.dwell.is_some()));
    if !waiting {
        arm_seen(hwnd);
    }
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

/// Drop a selection the list no longer has.
fn reconcile_selection() {
    let kept = selection();
    let now = source::with(|data| match data {
        Data::Ready(r) => list::restored_selection(&r.list, kept.as_deref()).map(str::to_string),
        // Nothing to check it against: keep it until there is.
        Data::NotYet => kept.clone(),
        Data::Unreadable(_) => kept.clone(),
    });
    SELECTION.with(|s| *s.borrow_mut() = now);
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
        return;
    }
    let g = geometry(hwnd);
    // Both ends of the slide, from the one layout the list has now.
    let ends = source::with(|data| match data {
        Data::Ready(r) => {
            let at = ListLayout::new(&r.list, g.room.panel.h);
            let from = chip_now(&at, selection().as_deref()).0;
            Some((from, at.chip(id.as_deref())))
        }
        Data::NotYet => None,
        Data::Unreadable(_) => None,
    });
    SELECTION.with(|s| *s.borrow_mut() = id.clone());
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
}

/// Tell the marker what is selected now, and start its wait if it asks for
/// one.
fn arm_seen(hwnd: HWND) {
    let selected = selection();
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
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_SETFOCUS => {
            // The one TSF document manager of this thread belongs to the
            // terminals; hand it back while a window that takes no text has
            // the keyboard (`palette.rs` has the contract). A pane's own
            // `WM_SETFOCUS` takes it again.
            crate::ime_focus(false);
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
        Data::Ready(r) => ListLayout::new(&r.list, g.room.panel.h)
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
    let selected = selection();
    let theme = look::theme(dark());
    let go = source::with(|data| {
        let row = match data {
            Data::Ready(r) => selected.as_deref().and_then(|id| r.list.row(id)),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        };
        scene::build_right(row, g.room.right.w, g.room.right.h, theme, g.scale, &|s| tr(s)).go
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
        let (items, right) = source::with(|data| match data {
            Data::Ready(r) => {
                let list: &List = &r.list;
                let lay = ListLayout::new(list, g.room.panel.h);
                let (chip, lift) = chip_now(&lay, selected.as_deref());
                let window = crate::tabs::window(GetAncestor(hwnd, GA_ROOT)).map(|w| polter_control_room::rules::key(w.id));
                let pulsing = pulse::pulsing_row(&r.snapshot.pulses, window.as_deref(), None);
                let view = View { theme, scale: g.scale, selection: selected.as_deref(), chip, lift, pulsing };
                let row = selected.as_deref().and_then(|id| list.row(id));
                (
                    scene::build(list, &lay, &view, &translate),
                    scene::build_right(row, g.room.right.w, g.room.right.h, theme, g.scale, &translate),
                )
            }
            Data::NotYet => (
                scene::build_message(side::WIDTH, g.room.panel.h, theme, g.scale, tr(scene::msg::NOT_YET)),
                scene::build_right(None, g.room.right.w, g.room.right.h, theme, g.scale, &translate),
            ),
            Data::Unreadable(why) => (
                scene::build_message(
                    side::WIDTH,
                    g.room.panel.h,
                    theme,
                    g.scale,
                    list::fill(&tr(scene::msg::UNREADABLE), why),
                ),
                scene::build_right(None, g.room.right.w, g.room.right.h, theme, g.scale, &translate),
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
        let _ = BitBlt(hdc, 0, 0, rc.right, rc.bottom, Some(mem), 0, 0, SRCCOPY);
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        let _ = EndPaint(hwnd, &ps);
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
                let mut r = at.rect(*rect);
                let font = fonts.get(style);
                let old = SelectObject(dc, font.into());
                SetTextColor(dc, rgb(style.color));
                let mut wide: Vec<u16> = text.encode_utf16().collect();
                let how = match align {
                    Align::Left => DT_LEFT,
                    Align::Right => DT_RIGHT,
                    Align::Centre => DT_CENTER,
                };
                DrawTextW(dc, &mut wide, &mut r, how | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
                SelectObject(dc, old);
            },
            Item::Line { rect, parts } => unsafe { paint_line(dc, at, at.rect(*rect), parts, fonts, t) },
        }
    }
}

unsafe fn text_width(dc: HDC, font: HFONT, text: &str) -> i32 {
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

unsafe fn paint_piece(dc: HDC, at: Px, piece: &Piece, mut r: RECT, fonts: &mut Fonts, t: f64, ellipsis: bool) {
    match piece {
        Piece::Words { text, style } => unsafe {
            let font = fonts.get(style);
            let old = SelectObject(dc, font.into());
            SetTextColor(dc, rgb(style.color));
            let mut wide: Vec<u16> = text.encode_utf16().collect();
            let cut = if ellipsis { DT_END_ELLIPSIS } else { DT_NOCLIP };
            DrawTextW(dc, &mut wide, &mut r, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | cut);
            SelectObject(dc, old);
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
    let mut lead = r.left;
    for part in parts {
        match part.side {
            Side::Lead => {
                lead += at.len(part.gap);
                let w = unsafe { part_width(dc, at, part, fonts) };
                let box_ = RECT { left: lead, top: r.top, right: lead + w, bottom: r.bottom };
                unsafe { paint_piece(dc, at, &part.piece, box_, fonts, t, false) };
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
