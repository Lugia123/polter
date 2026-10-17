//! The frames round the panes of a split terminal tab
//! (`dev-docs/poltergeist/control-room.md`, 12.6.1 and 12.6.3).
//!
//! **Nothing here decides which frame a pane wears, where it goes or what
//! it draws.** All three are `polter_control_room::pane` -- `drawn`,
//! `frame_px` / `well_px`, `build` -- which is tested without a window and
//! held to the macOS host's answers by `tools/control-room-hosts-agree.py`.
//! This file is the part that needs Windows: reading the setting, asking the
//! core which terminal a pane is, and painting.
//!
//! **How a frame is on screen.** A pane is a child window with a surface
//! bound to it for life (`windows/AGENTS.md`), so a frame cannot be drawn
//! round the terminal by the terminal. Instead `tabs::layout` puts each
//! pane's window where `pane::well_px` says -- under its title, inside its
//! border -- and the frame window, which already paints whatever its
//! children do not cover, paints the frames there (`strip::paint` calls
//! [`paint`]). The split tree is told nothing: it still tiles the whole
//! content area, and the dividers stay on its seams, which are now the
//! middle of the gap between two frames.
//!
//! **Nothing here owns a timer.** A frame is repainted when a layout runs,
//! when the snapshot changes what one says, and when the keyboard moves. A
//! working terminal's spinner is drawn standing still.
//!
//! **Main thread only**: the snapshot is a `thread_local` there
//! (`control_room_source`), and so is every window call.

use std::cell::{Cell, RefCell};

use windows::Win32::Foundation::{COLORREF, HWND, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::GetClientRect;

use polter_control_room::look;
use polter_control_room::pane::{self, Drawn, Place, Px, Title};
use polter_control_room::panestack::{self, Geometry, Hit};
use polter_control_room::snapshot::BarShown;
use polter_control_room::rules;
use polter_split_tree::{PaneId, Rect as TreeRect};

use crate::control_room_source::{self as source, Data};
use crate::ffi::Surface;
use crate::i18n::tr;
use crate::{tabs, wlogf};

thread_local! {
    /// The title the pointer is over: its window, its pane, and whether it
    /// is on the close cross. None when it is over no title. What shows the
    /// cross on a pane without the keyboard, and lights it.
    static HOVER: Cell<Option<(isize, PaneId, bool)>> = const { Cell::new(None) };
    /// What the pointer is over on a stack's strip: the window, the place
    /// (its shown pane), and what it is (task 1583).
    static STRIP_HOVER: Cell<Option<(isize, PaneId, Hit)>> = const { Cell::new(None) };
    /// Every strip as it was last painted, for what a point on it is
    /// without measuring words again: the window, the frame's rectangle in
    /// its pixels, the members in the order of their tabs, the scale, and
    /// where it all was.
    static STRIPS: RefCell<Vec<Strip>> = const { RefCell::new(Vec::new()) };
    /// How far each stack's tabs are scrolled, by window and by the stack's
    /// first-made member -- which stays while the place shows another.
    /// With the three things that, changing, bring the tab in front back
    /// into view even after the wheel -- which it is, how many there are,
    /// how wide the strip is -- and whether the person scrolled the tabs
    /// with the wheel since those last changed (task 1599: until they do,
    /// the tab in front is kept in view on every paint).
    static OFFSETS: RefCell<Vec<Offset>> = const { RefCell::new(Vec::new()) };
}

/// Where one stack's tabs are scrolled to, and what decides whether the
/// next paint brings the tab in front back into view.
struct Offset {
    key: (isize, PaneId),
    offset: f64,
    changed_by: (usize, usize, i32),
    wheeled: bool,
}

/// One strip as it was last painted.
#[derive(Clone)]
pub struct Strip {
    frame: isize,
    /// The place: the pane its frame shows.
    place: PaneId,
    rect: Px,
    members: Vec<PaneId>,
    scale: f64,
    geometry: Geometry,
}

/// The terminals of a place that holds a stack, as the last layout left it.
#[derive(Clone, PartialEq, Debug)]
pub struct Stacked {
    /// In the order of the tabs.
    pub members: Vec<PaneId>,
    /// Which of them is in front.
    pub current: usize,
    /// Each one's terminal, as the snapshot spells one.
    pub keys: Vec<Option<String>>,
    /// What each one's own pane calls it.
    pub names: Vec<String>,
}

impl Stacked {
    /// The key a stack's scroll is kept under: its first-made member.
    fn id(&self) -> PaneId {
        self.members.iter().copied().min().unwrap_or(0)
    }
}

/// One pane showing in the tab in front, as the last layout left it.
#[derive(Clone, PartialEq, Debug)]
pub struct One {
    pub pane: PaneId,
    /// The terminal in it, as the snapshot spells one; none when the core
    /// gave the surface no id.
    pub key: Option<String>,
    /// What the pane calls itself, for a terminal the snapshot does not
    /// list.
    pub own_name: String,
    /// What it wears; none when it is drawn as it always was.
    pub drawn: Option<Drawn>,
    /// Where its frame is, in the frame window's pixels. The cell the tree
    /// gave it when nothing in the tab is framed.
    pub rect: Px,
    /// The terminals stacked in this place, when there is more than one:
    /// its title is then a strip of tabs (task 1583).
    pub stack: Option<Stacked>,
}

/// What a window's content area holds besides its panes.
#[derive(Clone, PartialEq, Debug, Default)]
pub struct Frames {
    /// Where the panes were when this was worked out; none before the
    /// first layout, and for a tab that is not a terminal's.
    pub place: Option<Place>,
    /// The ground shows between the panes, and the frames are painted.
    pub ground: bool,
    pub panes: Vec<One>,
}

/// What a layout needs that must be asked for before the window's state is
/// locked: the setting, and which terminal each pane of the tab in front
/// is.
pub struct Asked {
    enabled: bool,
    keys: Vec<(PaneId, String)>,
}

/// `poltergeist-pane-frames`. On when it cannot be read, which is its
/// default.
fn enabled() -> bool {
    let cfg = crate::config_handle();
    let Some(api) = crate::api_opt() else { return true };
    if cfg.is_null() {
        return true;
    }
    let mut on = true;
    let key = "poltergeist-pane-frames";
    unsafe { (api.config_get)(cfg, &mut on as *mut bool as *mut std::ffi::c_void, key.as_ptr(), key.len()) };
    on
}

impl Asked {
    /// **Call with the window's state unlocked**: it takes the lock for the
    /// list of panes and lets it go before it asks the core anything.
    pub fn ask(frame: HWND) -> Asked {
        let panes: Vec<(PaneId, usize)> = match tabs::window(frame) {
            Some(win) => win.tabs.get(win.active).map(|t| t.panes().iter().map(|p| (p.id, p.surface)).collect()).unwrap_or_default(),
            None => Vec::new(),
        };
        let keys = match crate::api_opt() {
            Some(api) => panes
                .into_iter()
                .filter(|(_, s)| *s != 0)
                .filter_map(|(id, s)| {
                    let terminal = unsafe { (api.surface_poltergeist_id)(s as Surface) };
                    (terminal != 0).then(|| (id, rules::key(terminal)))
                })
                .collect(),
            None => Vec::new(),
        };
        Asked { enabled: enabled(), keys }
    }

    fn key(&self, pane: PaneId) -> Option<&str> {
        self.keys.iter().find(|(id, _)| *id == pane).map(|(_, k)| k.as_str())
    }

    /// The terminals of a place, with their keys, from what the layout
    /// knows: `members` in tab order with each one's own name, `shown` the
    /// one in front.
    pub fn stacked(&self, members: Vec<(PaneId, String)>, shown: PaneId) -> Stacked {
        let current = members.iter().position(|(id, _)| *id == shown).unwrap_or(0);
        Stacked {
            keys: members.iter().map(|(id, _)| self.key(*id).map(str::to_string)).collect(),
            names: members.iter().map(|(_, n)| n.clone()).collect(),
            members: members.into_iter().map(|(id, _)| id).collect(),
            current,
        }
    }

    /// The frames of a tab whose showing panes are `visible` -- each with
    /// the rectangle the tree gave it, the name its pane has, and its
    /// stack when it holds one -- and, for each pane, where its window goes.
    /// Called by `tabs::layout` with the window's state locked; it touches
    /// no window.
    ///
    /// `thickness` is the dividers' (`divider::scaled_thickness`): a pane
    /// that wears no frame gives up the pixels of the divider on each of its
    /// seams (`polter_split_tree::clear_of_dividers`, #58), because nothing
    /// else keeps the divider window off its cells.
    pub fn work_out(&self, visible: &[(PaneId, TreeRect, String, Option<Stacked>)], bounds: TreeRect, scale: f64, thickness: f64) -> (Frames, Vec<(PaneId, TreeRect)>) {
        // The quick terminal is a window of its own with one surface and no
        // tabs (`quick.rs`); it never comes through here.
        let place = Place { enabled: self.enabled, quick_terminal: false, alone: visible.len() == 1 };
        let drawn = wears(visible.iter().map(|(id, _, name, stack)| (self.key(*id), name.as_str(), stack.as_ref())), place);
        let ground = pane::ground_shows(&drawn);
        let px = |r: &TreeRect| Px { x: r.x as i32, y: r.y as i32, w: r.w as i32, h: r.h as i32 };
        let area = px(&bounds);
        let mut panes = Vec::new();
        let mut windows = Vec::new();
        for ((id, cell, name, stack), drawn) in visible.iter().zip(drawn) {
            let cell_px = px(cell);
            let (rect, window) = match (&drawn, ground) {
                (Some(d), true) => {
                    let rect = pane::frame_px(cell_px, area, scale);
                    let well = pane::well_px(rect, d.wears, scale);
                    (rect, TreeRect::new(well.x as f64, well.y as f64, well.w as f64, well.h as f64))
                }
                // Not framed: the pane is its cell, less the dividers on its
                // seams (#58). A framed one needs no such thing -- its
                // window is already inside its frame, and the divider lies
                // in the gap between two frames.
                (Some(_), false) | (None, _) => (cell_px, polter_split_tree::clear_of_dividers(*cell, bounds, thickness)),
            };
            windows.push((*id, window));
            panes.push(One { pane: *id, key: self.key(*id).map(str::to_string), own_name: name.clone(), drawn, rect, stack: stack.clone() });
        }
        (Frames { place: Some(place), ground, panes }, windows)
    }
}

/// What each of some panes wears at `place`, from the snapshot as it is.
///
/// **A place holding a stack is always framed** -- alone in its tab, and
/// with the setting off: a stack with no strip is terminals nobody can
/// reach (macOS's `PaneStackRules.Choices`). It wears the frame of the one
/// in front, and its title says nothing: the strip stands where it would.
fn wears<'a>(panes: impl Iterator<Item = (Option<&'a str>, &'a str, Option<&'a Stacked>)>, place: Place) -> Vec<Option<Drawn>> {
    source::with(|data| {
        let terminals = match data {
            Data::Ready(r) => Some(r.snapshot.terminals.as_slice()),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        };
        panes
            .map(|(key, name, stack)| match stack {
                Some(s) => {
                    let model = model(s, terminals, &[]);
                    Some(Drawn { wears: panestack::wears(&model), title: Title { name: String::new(), shown: BarShown::None, word: String::new() } })
                }
                None => pane::drawn(key, name, place, terminals),
            })
            .collect()
    })
}

/// What a stack's strip says, from the snapshot's terminals and the core's
/// order of who is waiting.
fn model(s: &Stacked, terminals: Option<&[polter_control_room::snapshot::Terminal]>, pulses: &[&str]) -> panestack::PaneStack {
    let members: Vec<(Option<&str>, &str)> = s.keys.iter().zip(&s.names).map(|(k, n)| (k.as_deref(), n.as_str())).collect();
    panestack::stack(&members, s.current, terminals, pulses)
}

/// What a change of the snapshot or of the setting asks of one window.
enum Stale {
    Nothing,
    /// A title says something else; every frame is where it was.
    Paint,
    /// A pane wears a different frame, or one where it had none: the
    /// terminals have to move.
    Layout,
}

fn stale(frame: HWND, on: bool) -> Stale {
    let Some(mut win) = tabs::window(frame) else { return Stale::Nothing };
    let Some(place) = win.pane_frames.place else { return Stale::Nothing };
    if place.enabled != on {
        return Stale::Layout;
    }
    let now = wears(win.pane_frames.panes.iter().map(|p| (p.key.as_deref(), p.own_name.as_str(), p.stack.as_ref())), place);
    let moved = win.pane_frames.panes.iter().zip(&now).any(|(p, d)| p.drawn.as_ref().map(|d| d.wears) != d.as_ref().map(|d| d.wears));
    if moved {
        return Stale::Layout;
    }
    // A strip says what its members' titles would, and it is worked out
    // when it is painted: any stack is painted again.
    let said = win.pane_frames.panes.iter().zip(&now).any(|(p, d)| p.drawn != *d || p.stack.is_some());
    if !said {
        return Stale::Nothing;
    }
    for (p, d) in win.pane_frames.panes.iter_mut().zip(now) {
        p.drawn = d;
    }
    Stale::Paint
}

/// The snapshot changed (`control_room_source::fetch`): every window whose
/// frames now say something else is repainted, and one whose panes now wear
/// different frames is laid out again. A window nothing changed for is not
/// touched.
pub fn snapshot_changed() {
    let frames: Vec<isize> = tabs::with_windows(|ws| ws.iter().map(|w| w.frame).collect());
    let on = enabled();
    for raw in frames {
        let frame = HWND(raw as *mut core::ffi::c_void);
        match stale(frame, on) {
            Stale::Nothing => {}
            Stale::Paint => repaint(frame),
            Stale::Layout => {
                wlogf!(frame, "[panes] a pane wears a different frame; laying the tab out again");
                tabs::layout(frame);
            }
        }
    }
}

/// Ask for the content area to be painted again, when it has frames in it.
/// The keyboard moving from one pane to another comes here: a supervisor's
/// frame says whether the keyboard is in it.
pub fn repaint(frame: HWND) {
    let framed = tabs::window(frame).is_some_and(|w| w.pane_frames.ground);
    if !framed {
        return;
    }
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return;
        }
        rc.top = crate::strip::strip_h(tabs::scale_of(frame));
        let _ = InvalidateRect(Some(frame), Some(&rc), false);
    }
}

/// Light or dark for the frames in `frame`: its terminal's background, as
/// the strip and the control room (`termcolor::chrome`, task 1550).
fn dark(frame: HWND) -> bool {
    crate::termcolor::chrome(frame).dark
}

fn colorref(c: look::Rgba) -> COLORREF {
    COLORREF((c.r as u32) | ((c.g as u32) << 8) | ((c.b as u32) << 16))
}

/// The colour between the frames of this window, when its tab in front has
/// frames; none when it has not. A divider paints itself this colour, so
/// that the gap it lies in is one colour across.
pub fn ground_color(frame: HWND) -> Option<COLORREF> {
    // The window's lock is let go before `dark`, which takes it again to
    // find the pane in front (`termcolor::ground`).
    let ground = tabs::window(frame).is_some_and(|w| w.pane_frames.ground);
    ground.then(|| colorref(look::theme(dark(frame)).window_base))
}

/// Paint the content area `below` the strip, into `hdc`: the ground and
/// every frame on it. **False when this window has no frames**, and then
/// nothing was painted and the caller clears the area as it always has.
pub fn paint(frame: HWND, hdc: HDC, below: RECT) -> bool {
    let (frames, focused, scale) = match tabs::window(frame) {
        Some(win) if win.pane_frames.ground => {
            let focused = win.tabs.get(win.active).and_then(|t| t.terminal()).map(|t| t.focused);
            (win.pane_frames.clone(), focused, win.scale.max(0.1))
        }
        Some(_) => return false,
        None => return false,
    };
    let (w, h) = (below.right - below.left, below.bottom - below.top);
    if w <= 0 || h <= 0 {
        return true;
    }
    let theme = look::theme(dark(frame));
    // The terminal's own `background`, as the dividers read it; the
    // design's when it cannot be read.
    let well = match crate::divider::terminal_background() {
        Some(c) => look::Rgba { r: (c.0 & 0xff) as u8, g: ((c.0 >> 8) & 0xff) as u8, b: ((c.0 >> 16) & 0xff) as u8, a: 1.0 },
        None => theme.terminal_background,
    };
    let translate = |s: &str| tr(s);
    // Once, into memory, and blitted: the ground and then the frames
    // straight onto the window would show the ground through every title
    // for a moment on each paint. The panes are clipped out of the blit
    // (`WS_CLIPCHILDREN` on the frame window).
    unsafe {
        let mem = CreateCompatibleDC(Some(hdc));
        let bmp = CreateCompatibleBitmap(hdc, w, h);
        let old = SelectObject(mem, bmp.into());
        let all = RECT { left: 0, top: 0, right: w, bottom: h };
        let brush = CreateSolidBrush(colorref(theme.window_base));
        FillRect(mem, &all, brush);
        let _ = DeleteObject(brush.into());
        let alone = frames.place.is_none_or(|p| p.alone);
        let hover = HOVER.get().filter(|(f, _, _)| *f == frame.0 as isize);
        let mut strips = Vec::new();
        for one in &frames.panes {
            let Some(drawn) = &one.drawn else { continue };
            if let Some(stack) = &one.stack {
                let view = pane::View { theme, scale, focused: focused == Some(one.pane), well, close: false };
                let items = pane::build(one.rect, drawn, &view, &translate);
                crate::control_room::paint_scene(mem, scale, one.rect.x - below.left, one.rect.y - below.top, &items);
                strips.push(paint_strip(frame, mem, one, stack, drawn.wears, theme, well, scale, below));
                continue;
            }
            let hovered = hover.is_some_and(|(_, p, _)| p == one.pane);
            let close = pane::close_shows(alone, focused == Some(one.pane), hovered);
            let view = pane::View { theme, scale, focused: focused == Some(one.pane), well, close };
            let items = pane::build(one.rect, drawn, &view, &translate);
            crate::control_room::paint_scene(mem, scale, one.rect.x - below.left, one.rect.y - below.top, &items);
            if close {
                let c = pane::close_px(one.rect, drawn.wears, scale);
                let lit = hover.is_some_and(|(_, p, on)| p == one.pane && on);
                let at = RECT { left: c.x - below.left, top: c.y - below.top, right: c.right() - below.left, bottom: c.bottom() - below.top };
                crate::strip::draw_cross(mem, at, colorref(pane::close_ink(drawn.wears, theme, lit)), scale);
            }
        }
        STRIPS.with(|all| {
            let mut all = all.borrow_mut();
            all.retain(|s| s.frame != frame.0 as isize);
            all.extend(strips);
        });
        let _ = BitBlt(hdc, below.left, below.top, w, h, Some(mem), 0, 0, SRCCOPY);
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
    }
    true
}

/// A rectangle in points from a frame's corner, in the pixels of a
/// device context whose origin is `(ox, oy)` from it -- rounded the way the
/// scene painter rounds, so what is placed and what is painted meet.
fn px_rect(ox: i32, oy: i32, scale: f64, r: polter_control_room::layout::Rect) -> RECT {
    let p = |v: f64| (v * scale).round() as i32;
    RECT { left: ox + p(r.x), top: oy + p(r.y), right: ox + p(r.x + r.w), bottom: oy + p(r.y + r.h) }
}

/// Paint one stack's strip over its frame's top, and say where it all was
/// (task 1583). The strip is `panestack`'s; this measures the words, keeps
/// the scroll, and draws what a scene has no item for: the close buttons,
/// the plus and the fades at the ends.
#[allow(clippy::too_many_arguments)]
unsafe fn paint_strip(frame: HWND, mem: HDC, one: &One, stack: &Stacked, wears: pane::Wears, theme: &look::Theme, well: look::Rgba, scale: f64, below: RECT) -> Strip {
    use polter_control_room::look::{font, stack_tab as t};
    use polter_control_room::scene::{Face, Style};
    let (model, status) = source::with(|data| {
        let (terminals, pulses) = match data {
            Data::Ready(r) => (Some(r.snapshot.terminals.as_slice()), r.snapshot.pulses.iter().map(|p| p.terminal.as_str()).collect::<Vec<_>>()),
            Data::NotYet | Data::Unreadable(_) => (None, Vec::new()),
        };
        let model = model(stack, terminals, &pulses);
        // The status at the right end is what the title of the one in front
        // would say there.
        let place = Place { enabled: true, quick_terminal: false, alone: false };
        let shown_key = stack.keys.get(stack.current).and_then(|k| k.as_deref());
        let shown_name = stack.names.get(stack.current).map(String::as_str).unwrap_or("");
        let status = pane::drawn(shown_key, shown_name, place, terminals).map(|d| d.title).unwrap_or_else(|| panestack::status_title(&model, ""));
        (model, status)
    });
    let mono = |weight| Style { size: font::BODY, weight, face: Face::Mono, color: theme.text };
    let ui = |weight| Style { size: font::BODY, weight, face: Face::Ui, color: theme.text };
    let roles: Vec<Option<String>> = model.members.iter().map(|m| m.role.map(tr)).collect();
    let mut words: Vec<(&str, polter_control_room::scene::Style)> = Vec::new();
    for (m, role) in model.members.iter().zip(&roles) {
        words.push((m.name.as_str(), mono(font::WEIGHT_EMPHASIS)));
        words.push((role.as_deref().unwrap_or(""), ui(font::WEIGHT_BODY)));
    }
    words.push((status.word.as_str(), ui(font::WEIGHT_EMPHASIS)));
    let measured = unsafe { crate::control_room::measure_words(mem, scale, &words) };
    let wants: Vec<f64> = roles.iter().enumerate().map(|(i, role)| panestack::wanted(measured[2 * i], role.as_ref().map(|_| measured[2 * i + 1]))).collect();
    let status_w = panestack::status_width(&status, measured[measured.len() - 1]);

    let key = (frame.0 as isize, stack.id());
    let changed_by = (model.current, model.members.len(), one.rect.w);
    let was = OFFSETS.with(|o| o.borrow().iter().find(|x| x.key == key).map(|x| (x.offset, x.changed_by, x.wheeled)));
    let changed = was.is_none_or(|(_, by, _)| by != changed_by);
    // A change of the three clears the wheel: the tab in front comes back.
    let wheeled = !changed && was.is_some_and(|(_, _, w)| w);
    let geometry = panestack::geometry(wears, one.rect.w as f64 / scale, &wants, model.current, status_w, was.map_or(0.0, |(v, _, _)| v), changed, wheeled);
    OFFSETS.with(|o| {
        let mut o = o.borrow_mut();
        o.retain(|x| x.key != key);
        o.push(Offset { key, offset: geometry.offset, changed_by, wheeled });
    });

    let lit = STRIP_HOVER.get().filter(|(f, p, _)| *f == frame.0 as isize && *p == one.pane).map(|(_, _, h)| h);
    let hovered = match lit {
        Some(Hit::Tab(i) | Hit::Close(i)) => Some(i),
        _ => None,
    };
    let view = panestack::View { theme, scale, well, hovered };
    let translate = |s: &str| tr(s);
    let drawn = panestack::build(&geometry, &model, wears, &status, &view, &translate);
    let (ox, oy) = (one.rect.x - below.left, one.rect.y - below.top);
    let row = px_rect(ox, oy, scale, geometry.row());
    // **In `Drawn`'s order**: what the tabs stand on first, then the tabs,
    // then what goes over them. The band was once painted last and covered
    // every tab, leaving only the close buttons and the plus (task 1583,
    // the first real machine).
    unsafe {
        crate::control_room::paint_scene(mem, scale, ox, oy, &drawn.under);
        let saved = SaveDC(mem);
        let _ = IntersectClipRect(mem, row.left, row.top, row.right, row.bottom);
        crate::control_room::paint_scene(mem, scale, ox, oy, &drawn.row);
        // What is past an edge fades out there.
        let (left, right) = geometry.fades();
        let fade = ((t::REVERSE_ARC_RADIUS + t::SCROLL_FADE) * scale).round() as i32;
        if left {
            fade_out(mem, RECT { right: row.left + fade, ..row }, colorref(drawn.band), true);
        }
        if right {
            fade_out(mem, RECT { left: row.right - fade, ..row }, colorref(drawn.band), false);
        }
        let _ = RestoreDC(mem, saved);
        crate::control_room::paint_scene(mem, scale, ox, oy, &drawn.over);
        let (current_ink, _) = panestack::inks(wears, theme);
        for (m, r) in &drawn.closes {
            let on = lit == Some(Hit::Close(*m));
            crate::strip::draw_cross(mem, px_rect(ox, oy, scale, *r), colorref(if on { current_ink } else { drawn.ink }), scale);
        }
        draw_plus(mem, px_rect(ox, oy, scale, drawn.add), colorref(if lit == Some(Hit::Add) { current_ink } else { drawn.ink }), scale);
        // The lit terminal's tab in the stack (task 1690): its ground and a
        // dot at its left breathe, in front or behind.
        for (i, member) in stack.members.iter().enumerate() {
            let Some(a) = crate::highlight::pane_breath(frame, *member) else { continue };
            let Some(r) = geometry.tab_rect(i) else { continue };
            let r = px_rect(ox, oy, scale, r);
            let clipped = RECT { left: r.left.max(row.left), right: r.right.min(row.right), ..r };
            if clipped.right <= clipped.left {
                continue;
            }
            let radius = (t::CORNER_RADIUS * scale).round() as i32;
            crate::highlight::paint_tab(mem, clipped, radius, frame, a, drawn.band);
            let d = (crate::highlight::TAB_DOT * scale).round().max(2.0) as i32;
            let top = (r.top + r.bottom - d) / 2;
            let left = r.left + (4.0 * scale).round() as i32;
            if left + d <= clipped.right && left >= clipped.left {
                crate::control_room::round(mem, RECT { left, top, right: left + d, bottom: top + d }, d / 2, crate::highlight::accent(frame, a), None);
            }
        }
    }
    Strip { frame: frame.0 as isize, place: one.pane, rect: one.rect, members: stack.members.clone(), scale, geometry }
}

/// The plus: two strokes through the middle of `r`, a font's body across.
unsafe fn draw_plus(dc: HDC, r: RECT, color: COLORREF, scale: f64) {
    unsafe {
        let pen = CreatePen(PS_SOLID, (1.0 * scale).max(1.0) as i32, color);
        let old = SelectObject(dc, pen.into());
        let half = (5.0 * scale).round() as i32;
        let (cx, cy) = ((r.left + r.right) / 2, (r.top + r.bottom) / 2);
        let _ = MoveToEx(dc, cx - half, cy, None);
        let _ = LineTo(dc, cx + half + 1, cy);
        let _ = MoveToEx(dc, cx, cy - half, None);
        let _ = LineTo(dc, cx, cy + half + 1);
        SelectObject(dc, old);
        let _ = DeleteObject(pen.into());
    }
}

/// `color` over `r`, solid at one end and gone at the other: solid at the
/// left when `solid_left`. One row of premultiplied pixels, stretched.
unsafe fn fade_out(dc: HDC, r: RECT, color: COLORREF, solid_left: bool) {
    let w = (r.right - r.left).max(1);
    let h = (r.bottom - r.top).max(1);
    unsafe {
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: 1,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
        let Ok(bmp) = CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) else { return };
        if bits.is_null() {
            let _ = DeleteObject(bmp.into());
            return;
        }
        let px = std::slice::from_raw_parts_mut(bits as *mut u32, w as usize);
        let (r8, g8, b8) = (color.0 & 0xff, (color.0 >> 8) & 0xff, (color.0 >> 16) & 0xff);
        for (i, p) in px.iter_mut().enumerate() {
            let along = (i as f64 + 0.5) / w as f64;
            let a = if solid_left { 1.0 - along } else { along };
            let a8 = (a * 255.0).round() as u32;
            let pre = |c: u32| (c * a8 + 127) / 255;
            *p = (a8 << 24) | (pre(r8) << 16) | (pre(g8) << 8) | pre(b8);
        }
        let src = CreateCompatibleDC(Some(dc));
        let old = SelectObject(src, bmp.into());
        let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
        let _ = AlphaBlend(dc, r.left, r.top, w, h, src, 0, 0, w, 1, blend);
        SelectObject(src, old);
        let _ = DeleteDC(src);
        let _ = DeleteObject(bmp.into());
    }
}

/// The pane whose title is under `(x, y)`, in the frame window's pixels;
/// none where there is no title (task 1549). A title is the band of a frame
/// above the terminal's window: from the frame's top to the well's.
pub fn title_at(frame: HWND, x: i32, y: i32) -> Option<PaneId> {
    let win = tabs::window(frame)?;
    if !win.pane_frames.ground {
        return None;
    }
    let scale = win.scale.max(0.1);
    win.pane_frames.panes.iter().find_map(|one| {
        let drawn = one.drawn.as_ref()?;
        let well = pane::well_px(one.rect, drawn.wears, scale);
        let inside = x >= one.rect.x && x < one.rect.right() && y >= one.rect.y && y < well.y;
        inside.then_some(one.pane)
    })
}

/// The pane whose close cross is under `(x, y)`, in the frame window's
/// pixels (task 1583). Only where a cross can show: a framed pane of a
/// split tab. The pointer being there is the hover that shows it.
pub fn close_at(frame: HWND, x: i32, y: i32) -> Option<PaneId> {
    // A stack's tab's close button closes that member (task 1583).
    if let Some((_, members, Hit::Close(i))) = strip_at(frame, x, y) {
        return members.get(i).copied();
    }
    let win = tabs::window(frame)?;
    if !win.pane_frames.ground || win.pane_frames.place.is_none_or(|p| p.alone) {
        return None;
    }
    let scale = win.scale.max(0.1);
    win.pane_frames.panes.iter().find_map(|one| {
        let drawn = one.drawn.as_ref()?;
        // A stack's title is its strip, which has its own (`strip_at`).
        if one.stack.is_some() {
            return None;
        }
        let c = pane::close_px(one.rect, drawn.wears, scale);
        let inside = x >= c.x && x < c.right() && y >= c.y && y < c.bottom();
        inside.then_some(one.pane)
    })
}

/// Close one pane, as its title's cross or its «Close Terminal» row asks
/// (`via`, for the log): the core's `close_surface` on that pane's
/// terminal -- the keyboard's path, so a running program is asked about by
/// the same rule (`tabs::close_pane_asking` is where the answer arrives).
pub fn close(frame: HWND, pane: PaneId, via: &str) {
    let surface = tabs::pane_hwnd(frame, pane).map(tabs::surface_of).unwrap_or(std::ptr::null_mut());
    if surface.is_null() {
        wlogf!(frame, "[panes] {via} on pane {pane}: it has no terminal; nothing");
        return;
    }
    let ok = crate::binding_on(surface, "close_surface");
    wlogf!(frame, "[panes] {via} on pane {pane} -> close_surface ok={}", ok as u8);
}

/// What is under `(x, y)` on a stack's strip, in the frame window's
/// pixels, as the strip was last painted: the place, its members in tab
/// order, and what the point is. None off every strip.
pub fn strip_at(frame: HWND, x: i32, y: i32) -> Option<(PaneId, Vec<PaneId>, Hit)> {
    STRIPS.with(|all| {
        all.borrow().iter().filter(|s| s.frame == frame.0 as isize).find_map(|s| {
            let at = ((x - s.rect.x) as f64 / s.scale, (y - s.rect.y) as f64 / s.scale);
            match panestack::hit(&s.geometry, at) {
                Hit::Outside => None,
                h => Some((s.place, s.members.clone(), h)),
            }
        })
    })
}

/// The pointer moved over the frame window's client area: which title it
/// is over, and whether on the cross; which part of a stack's strip.
/// Repaints only when that changed.
pub fn on_mouse_move(frame: HWND, x: i32, y: i32) {
    let strip = strip_at(frame, x, y).map(|(place, _, hit)| (frame.0 as isize, place, hit));
    let title = if strip.is_some() { None } else { title_at(frame, x, y).map(|pane| (frame.0 as isize, pane, close_at(frame, x, y) == Some(pane))) };
    let a = HOVER.replace(title) != title;
    let b = STRIP_HOVER.replace(strip) != strip;
    if a || b {
        repaint(frame);
    }
}

/// The pointer left the frame window: no title or strip is under it.
pub fn on_mouse_leave(frame: HWND) {
    let mine = |f: isize| f == frame.0 as isize;
    let a = HOVER.get().is_some_and(|(f, _, _)| mine(f));
    let b = STRIP_HOVER.get().is_some_and(|(f, _, _)| mine(f));
    if a {
        HOVER.set(None);
    }
    if b {
        STRIP_HOVER.set(None);
    }
    if a || b {
        repaint(frame);
    }
}

/// A wheel over a stack's strip that has more tabs than room: they scroll
/// sideways, up and down turned sideways (`panestack::scroll`). **True when
/// it was a strip's**, and then the window's own tabs are not scrolled.
pub fn on_wheel(frame: HWND, x: i32, y: i32, delta_x: i32, delta_y: i32) -> bool {
    let found = STRIPS.with(|all| {
        all.borrow().iter().find(|s| {
            s.frame == frame.0 as isize && {
                let at = ((x - s.rect.x) as f64 / s.scale, (y - s.rect.y) as f64 / s.scale);
                panestack::hit(&s.geometry, at) != Hit::Outside
            }
        }).map(|s| (s.members.iter().copied().min().unwrap_or(0), s.geometry.scrolled(panestack::scroll(delta_x, delta_y, panestack::WHEEL_LINE)), s.geometry.offset))
    });
    let Some((id, to, was)) = found else { return false };
    if to != was {
        let key = (frame.0 as isize, id);
        OFFSETS.with(|o| {
            if let Some(e) = o.borrow_mut().iter_mut().find(|x| x.key == key) {
                e.offset = to;
                // Left where the person put it until one of the three changes.
                e.wheeled = true;
            }
        });
        repaint(frame);
    }
    true
}

/// Where a terminal let go at `(x, y)` would go on a stack's strip: the
/// place, the insertion among its tabs, and the caret to show there, in the
/// frame window's pixels. None off every strip, and over its plus.
pub fn strip_drop_at(frame: HWND, x: i32, y: i32) -> Option<(PaneId, usize, RECT)> {
    STRIPS.with(|all| {
        all.borrow().iter().filter(|s| s.frame == frame.0 as isize).find_map(|s| {
            let at = ((x - s.rect.x) as f64 / s.scale, (y - s.rect.y) as f64 / s.scale);
            match panestack::hit(&s.geometry, at) {
                Hit::Outside | Hit::Add => None,
                Hit::Tab(_) | Hit::Close(_) | Hit::Strip => {
                    let index = s.geometry.insertion(at.0);
                    let cx = s.rect.x + (s.geometry.caret_x(index) * s.scale).round() as i32;
                    let row = s.geometry.row();
                    let top = s.rect.y + ((row.y + row.h - polter_control_room::look::stack_tab::HEIGHT + 4.0) * s.scale).round() as i32;
                    let bottom = s.rect.y + ((row.y + row.h - 4.0) * s.scale).round() as i32;
                    let w = (2.0 * s.scale).round().max(2.0) as i32;
                    Some((s.place, index, RECT { left: cx - w / 2, top, right: cx - w / 2 + w, bottom }))
                }
            }
        })
    })
}

/// A press on a stack's strip (task 1583). **True when it was a strip's**,
/// and then this has taken it: a tab is brought to the front, the plus
/// makes a new terminal in the place. A close button is the caller's,
/// acted on at release like the title's (`close_at`).
pub fn strip_press(frame: HWND, x: i32, y: i32) -> bool {
    let Some((place, members, hit)) = strip_at(frame, x, y) else { return false };
    match hit {
        Hit::Tab(i) => match members.get(i) {
            Some(m) => {
                let ok = tabs::show_member(frame, *m);
                wlogf!(frame, "[stack] tab {} of place {} pressed -> pane {} shown={}", i, place, m, ok as u8);
            }
            None => wlogf!(frame, "[stack] tab {} of place {} pressed: no such member", i, place),
        },
        Hit::Add => {
            wlogf!(frame, "[stack] plus on place {} pressed", place);
            tabs::post_op(frame, tabs::Op::PaneStack(polter_split_tree::stack::Verb::New, Some(place)), "stack plus");
        }
        Hit::Close(_) | Hit::Strip | Hit::Outside => {}
    }
    true
}

/// Where each pane showing in the tab in front is, frame and all, in the
/// frame window's pixels: what a dragged pane can be let go on.
pub fn showing(frame: HWND) -> Vec<(PaneId, Px)> {
    tabs::window(frame).map(|w| w.pane_frames.panes.iter().map(|p| (p.pane, p.rect)).collect()).unwrap_or_default()
}
