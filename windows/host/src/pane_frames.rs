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

use windows::Win32::Foundation::{COLORREF, HWND, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::GetClientRect;

use polter_control_room::look;
use polter_control_room::pane::{self, Drawn, Place, Px};
use polter_control_room::rules;
use polter_split_tree::{PaneId, Rect as TreeRect};

use crate::control_room_source::{self as source, Data};
use crate::ffi::Surface;
use crate::i18n::tr;
use crate::{tabs, wlogf};

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

    /// The frames of a tab whose showing panes are `visible` -- each with
    /// the rectangle the tree gave it and the name its pane has -- and, for
    /// each pane, where its window goes. Called by `tabs::layout` with the
    /// window's state locked; it touches no window.
    pub fn work_out(&self, visible: &[(PaneId, TreeRect, String)], bounds: TreeRect, scale: f64) -> (Frames, Vec<(PaneId, TreeRect)>) {
        // The quick terminal is a window of its own with one surface and no
        // tabs (`quick.rs`); it never comes through here.
        let place = Place { enabled: self.enabled, quick_terminal: false, alone: visible.len() == 1 };
        let drawn = wears(visible.iter().map(|(id, _, name)| (self.key(*id), name.as_str())), place);
        let ground = pane::ground_shows(&drawn);
        let px = |r: &TreeRect| Px { x: r.x as i32, y: r.y as i32, w: r.w as i32, h: r.h as i32 };
        let area = px(&bounds);
        let mut panes = Vec::new();
        let mut windows = Vec::new();
        for ((id, cell, name), drawn) in visible.iter().zip(drawn) {
            let cell_px = px(cell);
            let (rect, window) = match (&drawn, ground) {
                (Some(d), true) => {
                    let rect = pane::frame_px(cell_px, area, scale);
                    let well = pane::well_px(rect, d.wears, scale);
                    (rect, TreeRect::new(well.x as f64, well.y as f64, well.w as f64, well.h as f64))
                }
                // Nothing in this tab is framed: the pane is its cell.
                (Some(_), false) | (None, _) => (cell_px, *cell),
            };
            windows.push((*id, window));
            panes.push(One { pane: *id, key: self.key(*id).map(str::to_string), own_name: name.clone(), drawn, rect });
        }
        (Frames { place: Some(place), ground, panes }, windows)
    }
}

/// What each of some panes wears at `place`, from the snapshot as it is.
fn wears<'a>(panes: impl Iterator<Item = (Option<&'a str>, &'a str)>, place: Place) -> Vec<Option<Drawn>> {
    source::with(|data| {
        let terminals = match data {
            Data::Ready(r) => Some(r.snapshot.terminals.as_slice()),
            Data::NotYet => None,
            Data::Unreadable(_) => None,
        };
        panes.map(|(key, name)| pane::drawn(key, name, place, terminals)).collect()
    })
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
    let now = wears(win.pane_frames.panes.iter().map(|p| (p.key.as_deref(), p.own_name.as_str())), place);
    let moved = win.pane_frames.panes.iter().zip(&now).any(|(p, d)| p.drawn.as_ref().map(|d| d.wears) != d.as_ref().map(|d| d.wears));
    if moved {
        return Stale::Layout;
    }
    let said = win.pane_frames.panes.iter().zip(&now).any(|(p, d)| p.drawn != *d);
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

fn dark() -> bool {
    // The system's own setting, as the control room reads it.
    crate::shot::appearance() == "dark"
}

fn colorref(c: look::Rgba) -> COLORREF {
    COLORREF((c.r as u32) | ((c.g as u32) << 8) | ((c.b as u32) << 16))
}

/// The colour between the frames of this window, when its tab in front has
/// frames; none when it has not. A divider paints itself this colour, so
/// that the gap it lies in is one colour across.
pub fn ground_color(frame: HWND) -> Option<COLORREF> {
    tabs::window(frame).is_some_and(|w| w.pane_frames.ground).then(|| colorref(look::theme(dark()).window_base))
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
    let theme = look::theme(dark());
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
        for one in &frames.panes {
            let Some(drawn) = &one.drawn else { continue };
            let view = pane::View { theme, scale, focused: focused == Some(one.pane), well };
            let items = pane::build(one.rect, drawn, &view, &translate);
            crate::control_room::paint_scene(mem, scale, one.rect.x - below.left, one.rect.y - below.top, &items);
        }
        let _ = BitBlt(hdc, below.left, below.top, w, h, Some(mem), 0, 0, SRCCOPY);
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
    }
    true
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

/// Where each pane showing in the tab in front is, frame and all, in the
/// frame window's pixels: what a dragged pane can be let go on.
pub fn showing(frame: HWND) -> Vec<(PaneId, Px)> {
    tabs::window(frame).map(|w| w.pane_frames.panes.iter().map(|p| (p.pane, p.rect)).collect()).unwrap_or_default()
}
