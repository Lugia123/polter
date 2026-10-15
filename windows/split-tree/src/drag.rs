//! Picking a pane up and putting it down somewhere else, and the same for a
//! tab, minus the windows (task 1549).
//!
//! **Where this came from.** The macOS host's split drag (task 1508):
//! `SurfaceDragGrip.swift` (where a pane is picked up, and when a press is a
//! drag), `TerminalSplitDropZone` in `TerminalSplitTreeView.swift` (the four
//! zones and their highlight), `SurfaceGrabHandle.swift` (the handle a pane
//! with no title is picked up by), `SurfaceDragSource.swift` and
//! `BaseTerminalController.swift` (what letting go does). The rules are the
//! same rules in the same order; every place they differ is marked
//! `Deviation:`.
//!
//! **Why tabs are in here too.** A tab dragged out of its strip is the same
//! gesture with the same three endings -- somewhere of ours, nowhere, or
//! cancelled -- and the host's own tests only run on Windows. Out here they
//! run on the machine the port is written on.
//!
//! **Nothing in this file knows a window.** Rectangles are in device pixels,
//! Y-down, like the rest of the crate; lengths the design gives in points are
//! multiplied by the window's scale here and nowhere else.

use crate::{NewSplit, PaneId, Rect, Tree};

// ------------------------------------------------------------------ grips

/// `drag-handle`, as this needs it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Setting {
    Always,
    Auto,
    Never,
}

impl Setting {
    /// The config's own spelling (`@tagName` of the core's `DragHandle`).
    /// **Anything else is `Auto`**, which is the config's default: a value
    /// the host cannot read must not take dragging away.
    pub fn parse(s: &str) -> Setting {
        match s {
            "always" => Setting::Always,
            "never" => Setting::Never,
            _ => Setting::Auto,
        }
    }
}

/// Where a pane can be picked up, if anywhere.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Grip {
    /// By its title.
    Title,
    /// By the handle at the top middle of the terminal.
    Handle,
    /// Not at all.
    None,
}

/// What the pane's situation is, for the two questions below.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Situation {
    /// It wears a frame with a title.
    pub titled: bool,
    /// Its terminal is on the control room's right-hand side. Nothing is
    /// dragged there, **whatever `drag-handle` says**, `always` included
    /// (task 1566). Deviation: macOS asks this twice, `lent` for the
    /// placeholder in the pane and `controlRoom` for the terminal on the
    /// right-hand side, because there they are two views; here the pane is
    /// the one window, moved, and this is both.
    pub lent: bool,
    /// Its tab has more than one pane. With `auto` a tab of one pane cannot
    /// be picked up, by a handle or by a title, fullscreen or not: it moves
    /// by its tab (task 1566). It used to keep the handle unless the window
    /// was fullscreen.
    pub split: bool,
}

/// Where the pane is picked up (`SurfaceDragGrip.place`).
pub fn place(setting: Setting, s: Situation) -> Grip {
    if s.lent {
        return Grip::None;
    }
    let allowed = match setting {
        Setting::Always => true,
        Setting::Never => false,
        Setting::Auto => s.split,
    };
    if !allowed {
        return Grip::None;
    }
    if s.titled {
        Grip::Title
    } else {
        Grip::Handle
    }
}

/// What the title of a titled pane does.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TitleGrip {
    /// Held and moved, it drags the pane; clicked, it focuses it.
    Drag,
    /// Clicked, it focuses the pane. It does not drag, and the pointer over
    /// it says nothing about dragging.
    Click,
    /// Nothing at all.
    None,
}

/// What a title does (`SurfaceDragGrip.titleGrip`, task 1514 on macOS).
///
/// **`drag-handle` decides whether a pane is dragged, not whether its title
/// can be clicked.** Only a lent pane's placeholder takes no click: its
/// terminal is in the control room.
pub fn title_grip(setting: Setting, s: Situation) -> TitleGrip {
    if s.lent {
        return TitleGrip::None;
    }
    match place(setting, Situation { titled: true, ..s }) {
        Grip::Title => TitleGrip::Drag,
        Grip::Handle | Grip::None => TitleGrip::Click,
    }
}

/// How far, in points, the pointer has to move held down on a title before
/// it is a drag and not a click. The handle has none: it does nothing else.
pub const TITLE_DRAG_THRESHOLD_PT: f64 = 4.0;

/// The same, for a tab in the strip.
///
/// Deviation: macOS leaves a tab to the system. This is the title's number,
/// so the two things a person drags in a Polter window start at the same
/// distance -- and it is in points, so 200% does not halve it, which the
/// strip's old four device pixels did.
pub const TAB_DRAG_THRESHOLD_PT: f64 = 4.0;

/// A length in points, in device pixels at `scale`.
pub fn px(points: f64, scale: f64) -> f64 {
    points * scale
}

/// Whether the pointer, held down at `start`, has gone far enough to `now`
/// to be a drag: straight-line distance, as macOS measures it.
///
/// Deviation from the strip this replaces, which looked at `x` alone: a tab
/// pulled straight down out of its strip is a drag too, now that a tab can
/// leave its window.
pub fn is_drag(start: (f64, f64), now: (f64, f64), threshold: f64) -> bool {
    (now.0 - start.0).hypot(now.1 - start.1) >= threshold
}

/// Whether a press has become a drag: past `threshold`, or -- with none, the
/// handle's case -- as soon as the pointer has moved at all. A move message
/// that arrives with the pointer where it went down (Windows sends one after
/// a click) is not a drag.
pub fn started(start: (f64, f64), now: (f64, f64), threshold: f64) -> bool {
    if threshold <= 0.0 {
        return start != now;
    }
    is_drag(start, now, threshold)
}

// ----------------------------------------------------------------- handle

/// The handle's size, in points (`SurfaceGrabHandle.handleSize`).
pub const HANDLE_W_PT: f64 = 80.0;
pub const HANDLE_H_PT: f64 = 12.0;
/// How much of the pane's height, from the top, shows the handle under the
/// pointer (`hoverHeightFactor`).
pub const HOVER_HEIGHT_FACTOR: f64 = 0.2;

/// Where the handle is in a pane at `pane`: the top middle.
pub fn handle_rect(pane: Rect, scale: f64) -> Rect {
    let w = px(HANDLE_W_PT, scale).min(pane.w);
    let h = px(HANDLE_H_PT, scale).min(pane.h);
    Rect::new(pane.x + (pane.w - w) / 2.0, pane.y, w, h)
}

/// The band across the top of the pane that shows the handle with `auto`.
pub fn hover_band(pane: Rect, scale: f64) -> Rect {
    let h = pane.h.min((pane.h * HOVER_HEIGHT_FACTOR).max(px(HANDLE_H_PT, scale)));
    Rect::new(pane.x, pane.y, pane.w, h)
}

/// Whether the handle's dots are drawn (`SurfaceGrabHandle.ellipsisVisible`).
/// Asked only of a pane whose grip is `Handle`.
///
/// - `pointer`: where the pointer is, when it is over this pane.
/// - `cursor_visible`: the terminal has not hidden the pointer while typing.
pub fn handle_shown(setting: Setting, pane: Rect, scale: f64, pointer: Option<(f64, f64)>, dragging: bool, cursor_visible: bool) -> bool {
    match setting {
        Setting::Always => return true,
        Setting::Never => return false,
        Setting::Auto => {}
    }
    if !cursor_visible {
        return false;
    }
    if dragging {
        return true;
    }
    pointer.is_some_and(|p| contains(&hover_band(pane, scale), p))
}

/// The dots are brighter with the pointer on the handle itself.
pub const HANDLE_OPACITY_HOVER: f64 = 0.8;
pub const HANDLE_OPACITY: f64 = 0.3;

pub fn contains(r: &Rect, p: (f64, f64)) -> bool {
    p.0 >= r.x && p.0 < r.x + r.w && p.1 >= r.y && p.1 < r.y + r.h
}

// ------------------------------------------------------------------ zones

/// Which side of the pane it is over that a dragged pane would go.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Zone {
    Top,
    Bottom,
    Left,
    Right,
}

impl Zone {
    /// Which edge `p` is nearest, relative to the pane's size -- four
    /// triangles cut by the diagonals (`TerminalSplitDropZone.calculate`).
    /// **Ties go left, right, top, bottom**, in that order, as on macOS.
    pub fn at(pane: Rect, p: (f64, f64)) -> Zone {
        let rx = (p.0 - pane.x) / pane.w.max(1.0);
        let ry = (p.1 - pane.y) / pane.h.max(1.0);
        let (left, right, top, bottom) = (rx, 1.0 - rx, ry, 1.0 - ry);
        let min = left.min(right).min(top).min(bottom);
        if min == left {
            Zone::Left
        } else if min == right {
            Zone::Right
        } else if min == top {
            Zone::Top
        } else {
            Zone::Bottom
        }
    }

    /// The half of the pane that lights up for this zone.
    pub fn highlight(self, pane: Rect) -> Rect {
        let (hw, hh) = (pane.w / 2.0, pane.h / 2.0);
        match self {
            Zone::Top => Rect::new(pane.x, pane.y, pane.w, hh),
            Zone::Bottom => Rect::new(pane.x, pane.y + pane.h - hh, pane.w, hh),
            Zone::Left => Rect::new(pane.x, pane.y, hw, pane.h),
            Zone::Right => Rect::new(pane.x + pane.w - hw, pane.y, hw, pane.h),
        }
    }

    /// Where the dropped pane goes, as a split.
    pub fn direction(self) -> NewSplit {
        match self {
            Zone::Top => NewSplit::Up,
            Zone::Bottom => NewSplit::Down,
            Zone::Left => NewSplit::Left,
            Zone::Right => NewSplit::Right,
        }
    }
}

/// How opaque the highlight is (`accentColor.opacity(0.3)`).
pub const HIGHLIGHT_OPACITY: f64 = 0.3;

// ------------------------------------------------------------------ veils

/// How opaque the veil over a pane without the keyboard is, from
/// `unfocused-split-opacity`: `1 - opacity`, with the config's own clamp to
/// [0.15, 1] applied again here so a value from anywhere else cannot make a
/// pane vanish (`Config.zig` clamps on load; macOS reads it the same way).
pub fn veil_opacity(unfocused_split_opacity: f64) -> f64 {
    let o = if unfocused_split_opacity.is_finite() { unfocused_split_opacity } else { 1.0 };
    1.0 - o.clamp(0.15, 1.0)
}

/// Whether a pane wears the veil: its tab is split and it is not the pane
/// with the keyboard -- the one its tab last focused, so the veil does not
/// flicker on while the keyboard is on its way.
pub fn dimmed(split: bool, focused: bool) -> bool {
    split && !focused
}

/// Whether a colour reads as light, by the luminance macOS uses
/// (`NSColor.isLightColor`: above 0.5).
pub fn is_light(r: u8, g: u8, b: u8) -> bool {
    let l = 0.299 * r as f64 + 0.587 * g as f64 + 0.114 * b as f64;
    l / 255.0 > 0.5
}

/// The handle's three dots in a handle `w` x `h` pixels at `scale`: each
/// `(x, y, diameter)`. Two and a half points across, two and a half apart,
/// centred, and three points above the middle (the glyph's `offset(y: -3)`
/// in a twelve-point band).
pub fn dots(w: f64, h: f64, scale: f64) -> [(f64, f64, f64); 3] {
    let d = (2.5 * scale).max(2.0);
    let gap = 2.5 * scale;
    let span = 3.0 * d + 2.0 * gap;
    let x0 = (w - span) / 2.0;
    let y = ((h - d) / 2.0 - 3.0 * scale).max(0.0);
    [(x0, y, d), (x0 + d + gap, y, d), (x0 + 2.0 * (d + gap), y, d)]
}

/// The pixels one dot of [`dots`] covers: `(left, top, right, bottom)`,
/// right and bottom exclusive, `round(d)` across and never under 2.
///
/// **Its own rounding, not each edge rounded** (#1579 V8). Rounding left
/// and right separately turned a 2.5px dot at 100% into a 2x2 box
/// (33.75..36.25 -> 34..36), and Windows' `Ellipse` with no pen leaves out
/// the right column and the bottom row of its box, so what was drawn was
/// one pixel. The host still adds that column and row back for its brush
/// (`panedrag.rs`); this is the box the dot is meant to fill.
pub fn dot_box(x: f64, y: f64, d: f64) -> (i32, i32, i32, i32) {
    let side = (d.round() as i32).max(2);
    let (l, t) = (x.round() as i32, y.round() as i32);
    (l, t, l + side, t + side)
}

// ------------------------------------------------------------ the ending

/// What is under the pointer while a pane is dragged.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Over {
    /// A pane of ours, in the zone given. `own` when it is the pane being
    /// dragged.
    Pane { pane: PaneId, zone: Zone, own: bool },
    /// A gap in a strip, at this index (`StripTarget::Insert`).
    Strip(usize),
    /// One of our windows, but no pane in it and no gap of a strip: the
    /// middle of a tab, a frame's ground, the control room.
    Window,
    /// None of our windows.
    Outside,
}

/// What letting go does.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Ending {
    /// Split `onto` and put the pane there.
    Move { onto: PaneId, zone: Zone },
    /// The pane gets a window of its own where the pointer is.
    NewWindow,
    /// The pane becomes a tab of its own at this index of the strip it was
    /// let go over, in front.
    NewTab(usize),
    /// It stays where it was.
    Nothing,
}

/// What letting go over `over` does.
///
/// - Onto itself: nothing; it is not a target (macOS hides its drop zone).
/// - Into a gap of a strip: a tab of its own there (task 1557). Whether
///   there is a gap at all -- not on its own strip for a pane alone in its
///   tab -- is `strip_target`'s to say.
/// - Onto a window of ours that is not a pane or a gap: nothing, as a drop
///   that found no target.
/// - Outside every window: a window of its own -- **only from a tab that is
///   split**. A pane alone in its tab already is one (`surfaceTree.isSplit`
///   guard in `ghosttySurfaceDragEndedNoTarget`).
/// - Cancelled with Esc: nothing, wherever the pointer is.
pub fn ending(over: Over, from_split: bool, cancelled: bool) -> Ending {
    if cancelled {
        return Ending::Nothing;
    }
    match over {
        Over::Pane { own: true, .. } => Ending::Nothing,
        Over::Pane { pane, zone, own: false } => Ending::Move { onto: pane, zone },
        Over::Strip(index) => Ending::NewTab(index),
        Over::Window => Ending::Nothing,
        Over::Outside if from_split => Ending::NewWindow,
        Over::Outside => Ending::Nothing,
    }
}

/// The drop zone to light, while the pointer is over `over`: none over the
/// pane being dragged, and none where letting go would do nothing.
pub fn lit(over: Over) -> Option<(PaneId, Zone)> {
    match over {
        Over::Pane { pane, zone, own: false } => Some((pane, zone)),
        Over::Pane { own: true, .. } | Over::Strip(_) | Over::Window | Over::Outside => None,
    }
}

impl Tree {
    /// Move `pane` next to `onto`, inside this one tree: the same pane, out
    /// of where it was and into a split with `onto` on the side `dir` says
    /// (`splitDidDrop`, the same-window branch).
    ///
    /// Refused when the two are the same pane or either is not here; the
    /// tree is not changed then.
    ///
    /// Either may be stacked behind another (task 1583): `pane` leaves its
    /// stack -- the next tab takes its place if it was shown -- and `onto`
    /// names its place, whichever of the place's terminals it is.
    pub fn moving(&self, pane: PaneId, onto: PaneId, dir: NewSplit) -> Result<Tree, crate::Error> {
        let Some(place) = self.shown_for(onto) else { return Err(crate::Error::PaneNotFound) };
        if pane == place || !self.contains(pane) {
            return Err(crate::Error::PaneNotFound);
        }
        let without = self.remove(pane);
        // Taking `pane` out may have put another of its stack in front of
        // the place it was dropped on.
        let place = without.shown_for(onto).ok_or(crate::Error::PaneNotFound)?;
        without.insert(pane, place, dir)
    }
}

// --------------------------------------------------------- other tabs

/// How long a dragged pane has to stay over the middle of another tab for
/// that tab to come to the front -- the same as macOS's
/// `TabStripDrop.dwell` (task 1557). It was 2.5 s, macOS's own tab-bar
/// spring loading as measured in verify-cr-09 (DECISIONS.md 1, now
/// superseded); the user waited without knowing whether anything was coming.
pub const TAB_DWELL_SECS: f64 = 0.8;

/// Whether a dragged pane has been over the same tab long enough for it to
/// come to the front. `T` is whatever names a tab to the caller.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Dwell<T: Copy + PartialEq> {
    over: Option<(T, f64)>,
}

impl<T: Copy + PartialEq> Default for Dwell<T> {
    fn default() -> Self {
        Dwell { over: None }
    }
}

impl<T: Copy + PartialEq> Dwell<T> {
    /// The pointer is over `tab` (none: over no tab, or over the one in
    /// front, which has nothing to switch to) at `now`, in seconds. **Some
    /// once**, the first time the same tab has been under it for the whole
    /// dwell; moving off and back starts again.
    pub fn at(&mut self, tab: Option<T>, now: f64) -> Option<T> {
        match (tab, self.over) {
            (None, _) => {
                self.over = None;
                None
            }
            (Some(t), Some((was, since))) if was == t => {
                if since.is_finite() && now - since >= TAB_DWELL_SECS {
                    // Spent: the tab is in front now, and saying so again
                    // would switch to it twice.
                    self.over = Some((t, f64::INFINITY));
                    return Some(t);
                }
                None
            }
            (Some(t), _) => {
                self.over = Some((t, now));
                None
            }
        }
    }

    /// How far along the dwell is at `now`, 0 to 1, for the bar under the
    /// tab; none when there is no tab to bring forward or it has come.
    pub fn progress(&self, now: f64) -> Option<f64> {
        match self.over {
            Some((_, since)) if since.is_finite() => Some(((now - since) / TAB_DWELL_SECS).clamp(0.0, 1.0)),
            _ => None,
        }
    }

    /// The tab being waited on.
    pub fn tab(&self) -> Option<T> {
        match self.over {
            Some((t, since)) if since.is_finite() => Some(t),
            _ => None,
        }
    }
}

// ------------------------------------------------- a pane over a strip

/// What a pane dragged over a tab strip would do there (task 1557). The
/// macOS host has the same rule in `TabStripDrop.target`; the tests below
/// name the same cases as `TabStripDropTests`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StripTarget {
    /// Let go here and the pane becomes a new tab at this index: before the
    /// tab that has it now, or at the end when it is the count.
    Insert(usize),
    /// Hold here and this tab comes to the front.
    BringForward(usize),
    /// Nothing: the middle of the tab in front, or a pane that is already a
    /// tab of its own on its own strip.
    Nothing,
}

/// What the pointer at `x` over a strip of `tabs` (each `(left, right)`,
/// left to right) means.
///
/// - Within a quarter of a tab's width of its left or right edge, or in
///   the gap between two tabs: the gap on that side.
/// - Past the last tab: after it. Before the first: before it.
/// - The rest of a tab, its middle half: that tab comes to the front,
///   unless it is `selected` already.
/// - `alone`: the pane is the only one of a tab in this strip. Making it a
///   new tab here would leave everything as it was, so no gap is offered;
///   bringing another tab forward still is.
///
/// The quarter lines themselves belong to the middle.
pub fn strip_target(x: f64, tabs: &[(f64, f64)], selected: Option<usize>, alone: bool) -> StripTarget {
    let gap = |i: usize| if alone { StripTarget::Nothing } else { StripTarget::Insert(i) };
    let (Some(first), Some(last)) = (tabs.first(), tabs.last()) else {
        return StripTarget::Nothing;
    };
    if x < first.0 {
        return gap(0);
    }
    if x > last.1 {
        return gap(tabs.len());
    }
    for (i, &(l, r)) in tabs.iter().enumerate() {
        if x < l {
            return gap(i);
        }
        if x > r {
            continue;
        }
        let quarter = (r - l) / 4.0;
        if x < l + quarter {
            return gap(i);
        }
        if x > r - quarter {
            return gap(i + 1);
        }
        return if selected == Some(i) { StripTarget::Nothing } else { StripTarget::BringForward(i) };
    }
    gap(tabs.len())
}

/// The x of the insertion mark for gap `index`: midway between the two tabs
/// on either side, or on the outer edge of the first or last.
pub fn mark_x(index: usize, tabs: &[(f64, f64)]) -> Option<f64> {
    if tabs.is_empty() || index > tabs.len() {
        return None;
    }
    Some(if index == 0 {
        tabs[0].0
    } else if index == tabs.len() {
        tabs[index - 1].1
    } else {
        (tabs[index - 1].1 + tabs[index].0) / 2.0
    })
}

// ------------------------------------------------------------------ tabs

/// What is under the pointer while a tab is dragged.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TabOver<W: Copy + PartialEq> {
    /// Its own window. The strip reorders under the pointer as it moves, so
    /// letting go here keeps the order the drag has made.
    Home,
    /// Another window of ours, at `index` in its strip -- or at its end,
    /// when the pointer is not over the strip.
    Other { window: W, index: usize },
    /// None of our windows.
    Outside,
}

/// What letting go of a tab does.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TabEnding<W: Copy + PartialEq> {
    /// Where the drag put it in its own strip, it stays.
    Stay,
    /// Back where it was picked up: cancelled, or the capture was lost.
    Restore,
    /// Into another window's strip, at `index`. A window left with no tab
    /// closes.
    Join { window: W, index: usize },
    /// A window of its own where the pointer is.
    NewWindow,
}

/// What letting go over `over` does to a tab from a window of `tabs_home`.
///
/// **The only tab of a window does not get a new window**: it already has
/// one, and the "move" would destroy a frame and build the same one round
/// it (`move_tab_to_new_window`'s own refusal). It can still join another
/// window.
pub fn tab_ending<W: Copy + PartialEq>(over: TabOver<W>, tabs_home: usize, cancelled: bool) -> TabEnding<W> {
    if cancelled {
        return TabEnding::Restore;
    }
    match over {
        TabOver::Home => TabEnding::Stay,
        TabOver::Other { window, index } => TabEnding::Join { window, index },
        TabOver::Outside if tabs_home > 1 => TabEnding::NewWindow,
        TabOver::Outside => TabEnding::Stay,
    }
}

/// Where a tab dropped at `x` lands in a strip whose tabs start at `first`
/// and are `width` wide, with `n` of them: before the tab whose middle is
/// right of the pointer, so the gap nearest the pointer.
pub fn insertion_index(x: f64, first: f64, width: f64, n: usize) -> usize {
    if width <= 0.0 {
        return n;
    }
    let slot = ((x - first) / width + 0.5).floor();
    (slot.max(0.0) as usize).min(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    const LONE: Situation = Situation { titled: false, lent: false, split: false };

    #[test]
    fn the_veil_is_what_the_opacity_leaves_and_never_hides_a_pane() {
        assert!((veil_opacity(0.7) - 0.3).abs() < 1e-9);
        assert_eq!(veil_opacity(1.0), 0.0);
        assert!((veil_opacity(0.0) - 0.85).abs() < 1e-9);
        assert!((veil_opacity(f64::NAN) - 0.0).abs() < 1e-9);
        assert!(dimmed(true, false));
        assert!(!dimmed(true, true));
        assert!(!dimmed(false, false), "a pane alone in its tab is never veiled");
    }

    #[test]
    fn light_is_luminance_above_a_half() {
        assert!(is_light(255, 255, 255));
        assert!(!is_light(0, 0, 0));
        assert!(!is_light(0x28, 0x2c, 0x34));
        assert!(is_light(0xfd, 0xf6, 0xe3));
    }

    #[test]
    fn the_dots_are_centred_and_inside_the_handle() {
        for scale in [1.0, 1.5, 2.0] {
            let (w, h) = (80.0 * scale, 12.0 * scale);
            let d = dots(w, h, scale);
            let left = d[0].0;
            let right = w - (d[2].0 + d[2].2);
            assert!((left - right).abs() < 1e-9, "{scale}");
            assert!(d.iter().all(|(x, y, s)| *x >= 0.0 && *y >= 0.0 && x + s <= w && y + s <= h), "{scale}");
        }
    }

    #[test]
    fn a_dot_is_two_and_a_half_points_across_at_every_scale() {
        // #1579 V8: at 100% each dot was drawn one pixel across.
        for (scale, side) in [(1.0, 3), (1.25, 3), (1.5, 4), (2.0, 5)] {
            let (w, h) = (80.0 * scale, 12.0 * scale);
            let boxes: Vec<_> = dots(w, h, scale).iter().map(|(x, y, d)| dot_box(*x, *y, *d)).collect();
            for (l, t, r, b) in &boxes {
                assert_eq!((r - l, b - t), (side, side), "scale {scale}");
                assert!(*l >= 0 && *t >= 0 && *r as f64 <= w && *b as f64 <= h, "scale {scale}");
            }
            assert!(boxes.windows(2).all(|p| p[0].2 < p[1].0), "the dots stay apart at {scale}");
        }
    }

    #[test]
    fn the_config_spelling_is_read_and_anything_else_is_auto() {
        assert_eq!(Setting::parse("always"), Setting::Always);
        assert_eq!(Setting::parse("never"), Setting::Never);
        assert_eq!(Setting::parse("auto"), Setting::Auto);
        assert_eq!(Setting::parse(""), Setting::Auto);
    }

    #[test]
    fn a_titled_pane_is_picked_up_by_its_title_and_an_untitled_one_by_the_handle() {
        let split = Situation { split: true, ..LONE };
        assert_eq!(place(Setting::Auto, Situation { titled: true, ..split }), Grip::Title);
        assert_eq!(place(Setting::Auto, split), Grip::Handle);
        assert_eq!(place(Setting::Always, Situation { titled: true, ..split }), Grip::Title);
        assert_eq!(place(Setting::Always, split), Grip::Handle);
        assert_eq!(place(Setting::Never, split), Grip::None);
    }

    #[test]
    fn auto_alone_in_its_tab_has_no_grip() {
        // Fullscreen or not: it moves by its tab (task 1566).
        assert_eq!(place(Setting::Auto, LONE), Grip::None);
        assert_eq!(place(Setting::Auto, Situation { titled: true, ..LONE }), Grip::None);
    }

    #[test]
    fn always_alone_in_its_tab_keeps_the_grip_and_never_has_none() {
        assert_eq!(place(Setting::Always, LONE), Grip::Handle);
        assert_eq!(place(Setting::Always, Situation { titled: true, ..LONE }), Grip::Title);
        assert_eq!(place(Setting::Never, LONE), Grip::None);
        assert_eq!(place(Setting::Never, Situation { titled: true, ..LONE }), Grip::None);
    }

    #[test]
    fn a_lent_pane_has_no_grip_and_its_title_takes_no_click() {
        // Task 1566: `always` included, split or not.
        for setting in [Setting::Always, Setting::Auto, Setting::Never] {
            for split in [false, true] {
                for titled in [false, true] {
                    let lent = Situation { titled, lent: true, split };
                    assert_eq!(place(setting, lent), Grip::None, "{setting:?} split={split} titled={titled}");
                    assert_eq!(title_grip(setting, lent), TitleGrip::None, "{setting:?} split={split}");
                }
            }
        }
    }

    #[test]
    fn never_takes_the_drag_away_from_a_title_but_not_the_click() {
        let split = Situation { titled: true, split: true, ..LONE };
        assert_eq!(title_grip(Setting::Auto, split), TitleGrip::Drag);
        assert_eq!(title_grip(Setting::Never, split), TitleGrip::Click);
        let alone = Situation { titled: true, ..LONE };
        assert_eq!(title_grip(Setting::Auto, alone), TitleGrip::Click);
        assert_eq!(title_grip(Setting::Always, alone), TitleGrip::Drag);
    }

    #[test]
    fn four_points_is_a_drag_at_every_scale_and_three_is_not() {
        for scale in [1.0, 1.5, 2.0] {
            let t = px(TITLE_DRAG_THRESHOLD_PT, scale);
            assert!(is_drag((10.0, 10.0), (10.0 + 4.0 * scale, 10.0), t), "{scale}");
            assert!(!is_drag((10.0, 10.0), (10.0 + 3.0 * scale, 10.0), t), "{scale}");
        }
        // Straight down counts: a tab pulled out of its strip.
        assert!(is_drag((0.0, 0.0), (0.0, 8.0), px(TAB_DRAG_THRESHOLD_PT, 2.0)));
        // Diagonal: 3,3 is 4.24 from where it started.
        assert!(is_drag((0.0, 0.0), (3.0, 3.0), 4.0));
    }

    #[test]
    fn the_handle_starts_on_any_movement_and_not_on_none() {
        assert!(!started((5.0, 5.0), (5.0, 5.0), 0.0));
        assert!(started((5.0, 5.0), (6.0, 5.0), 0.0));
        assert!(!started((5.0, 5.0), (7.0, 5.0), 4.0));
        assert!(started((5.0, 5.0), (9.0, 5.0), 4.0));
    }

    #[test]
    fn the_handle_is_eighty_by_twelve_points_at_the_top_middle() {
        let pane = Rect::new(100.0, 50.0, 400.0, 300.0);
        assert_eq!(handle_rect(pane, 1.0), Rect::new(260.0, 50.0, 80.0, 12.0));
        assert_eq!(handle_rect(pane, 2.0), Rect::new(220.0, 50.0, 160.0, 24.0));
        // Never wider than the pane.
        let narrow = Rect::new(0.0, 0.0, 50.0, 300.0);
        assert_eq!(handle_rect(narrow, 1.0).w, 50.0);
    }

    #[test]
    fn auto_shows_the_handle_in_the_top_fifth_of_the_pane_only() {
        let pane = Rect::new(0.0, 0.0, 400.0, 300.0);
        let at = |y: f64| handle_shown(Setting::Auto, pane, 1.0, Some((200.0, y)), false, true);
        assert!(at(0.0));
        assert!(at(59.0));
        assert!(!at(60.0));
        assert!(!handle_shown(Setting::Auto, pane, 1.0, None, false, true));
        assert!(handle_shown(Setting::Auto, pane, 1.0, None, true, true));
        assert!(!handle_shown(Setting::Auto, pane, 1.0, Some((200.0, 1.0)), false, false));
        assert!(handle_shown(Setting::Always, pane, 1.0, None, false, false));
        assert!(!handle_shown(Setting::Never, pane, 1.0, Some((200.0, 1.0)), true, true));
        // A short pane still has a band as tall as the handle.
        let short = Rect::new(0.0, 0.0, 400.0, 30.0);
        assert!(handle_shown(Setting::Auto, short, 1.0, Some((200.0, 11.0)), false, true));
    }

    #[test]
    fn the_zone_is_the_nearest_edge_relative_to_the_panes_size() {
        let pane = Rect::new(0.0, 0.0, 400.0, 100.0);
        assert_eq!(Zone::at(pane, (10.0, 50.0)), Zone::Left);
        assert_eq!(Zone::at(pane, (390.0, 50.0)), Zone::Right);
        assert_eq!(Zone::at(pane, (200.0, 5.0)), Zone::Top);
        assert_eq!(Zone::at(pane, (200.0, 95.0)), Zone::Bottom);
        // Relative, not absolute: 60px from the left of a 400-wide pane is
        // 0.15, nearer than 20px from the top of a 100-high one, 0.2.
        assert_eq!(Zone::at(pane, (60.0, 20.0)), Zone::Left);
        // Dead centre ties all four; left wins, as on macOS.
        assert_eq!(Zone::at(pane, (200.0, 50.0)), Zone::Left);
    }

    #[test]
    fn the_highlight_is_the_half_on_the_zones_side() {
        let pane = Rect::new(10.0, 20.0, 400.0, 100.0);
        assert_eq!(Zone::Top.highlight(pane), Rect::new(10.0, 20.0, 400.0, 50.0));
        assert_eq!(Zone::Bottom.highlight(pane), Rect::new(10.0, 70.0, 400.0, 50.0));
        assert_eq!(Zone::Left.highlight(pane), Rect::new(10.0, 20.0, 200.0, 100.0));
        assert_eq!(Zone::Right.highlight(pane), Rect::new(210.0, 20.0, 200.0, 100.0));
        assert_eq!(Zone::Top.direction(), NewSplit::Up);
        assert_eq!(Zone::Right.direction(), NewSplit::Right);
    }

    #[test]
    fn letting_go_moves_onto_another_pane_and_nowhere_else() {
        let left = Zone::Left;
        assert_eq!(ending(Over::Pane { pane: 2, zone: left, own: false }, true, false), Ending::Move { onto: 2, zone: left });
        assert_eq!(ending(Over::Pane { pane: 1, zone: left, own: true }, true, false), Ending::Nothing);
        assert_eq!(ending(Over::Window, true, false), Ending::Nothing);
        assert_eq!(lit(Over::Pane { pane: 1, zone: left, own: true }), None);
        assert_eq!(lit(Over::Pane { pane: 2, zone: left, own: false }), Some((2, left)));
    }

    #[test]
    fn outside_every_window_a_split_pane_gets_a_window_and_a_lone_one_does_not() {
        assert_eq!(ending(Over::Outside, true, false), Ending::NewWindow);
        assert_eq!(ending(Over::Outside, false, false), Ending::Nothing);
    }

    #[test]
    fn esc_cancels_wherever_the_pointer_is() {
        assert_eq!(ending(Over::Outside, true, true), Ending::Nothing);
        assert_eq!(ending(Over::Pane { pane: 2, zone: Zone::Top, own: false }, true, true), Ending::Nothing);
        assert_eq!(ending(Over::Strip(1), true, true), Ending::Nothing);
    }

    #[test]
    fn let_go_in_a_gap_of_a_strip_a_pane_becomes_a_tab_there_and_no_zone_is_lit() {
        assert_eq!(ending(Over::Strip(2), true, false), Ending::NewTab(2));
        assert_eq!(ending(Over::Strip(0), false, false), Ending::NewTab(0), "alone, onto another window's strip");
        assert_eq!(lit(Over::Strip(2)), None);
    }

    #[test]
    fn a_move_inside_one_tree_takes_the_pane_out_and_splits_the_target() {
        // a | b | c  ->  drag c onto a's top  ->  (c / a) | b
        let t = Tree::with_pane(1).insert(2, 1, NewSplit::Right).unwrap().insert(3, 2, NewSplit::Right).unwrap();
        let moved = t.moving(3, 1, NewSplit::Up).unwrap();
        let want = Tree::with_pane(1).insert(2, 1, NewSplit::Right).unwrap().insert(3, 1, NewSplit::Up).unwrap();
        assert_eq!(moved, want);
        assert_eq!(moved.len(), 3);
        assert_eq!(t.moving(1, 1, NewSplit::Up), Err(crate::Error::PaneNotFound));
        assert_eq!(t.moving(9, 1, NewSplit::Up), Err(crate::Error::PaneNotFound));
    }

    #[test]
    fn the_dwell_is_eight_tenths_of_a_second() {
        assert_eq!(TAB_DWELL_SECS, 0.8);
    }

    #[test]
    fn a_tab_comes_to_the_front_once_after_the_whole_dwell_on_it() {
        let mut d = Dwell::default();
        assert_eq!(d.at(Some(7), 0.0), None);
        assert_eq!(d.progress(0.4), Some(0.5));
        assert_eq!(d.at(Some(7), 0.79), None);
        assert_eq!(d.at(Some(7), 0.81), Some(7));
        assert_eq!(d.at(Some(7), 2.0), None, "only once");
        assert_eq!(d.progress(2.0), None, "no bar once it has come");
    }

    #[test]
    fn moving_off_and_back_starts_again() {
        let mut d = Dwell::default();
        d.at(Some(7), 0.0);
        d.at(None, 0.5);
        assert_eq!(d.progress(0.5), None);
        d.at(Some(7), 1.0);
        assert_eq!(d.at(Some(7), 1.75), None);
        assert_eq!(d.at(Some(7), 1.85), Some(7));
    }

    #[test]
    fn another_tab_starts_its_own_dwell() {
        let mut d = Dwell::default();
        d.at(Some(7), 0.0);
        assert_eq!(d.at(Some(8), 0.7), None);
        assert_eq!(d.at(Some(8), 1.0), None);
        assert_eq!(d.at(Some(8), 1.6), Some(8));
    }

    /// Three tabs 100 wide with a gap of 4: 0-100, 104-204, 208-308.
    const STRIP: [(f64, f64); 3] = [(0.0, 100.0), (104.0, 204.0), (208.0, 308.0)];

    fn over(x: f64, selected: usize, alone: bool) -> StripTarget {
        strip_target(x, &STRIP, Some(selected), alone)
    }

    #[test]
    fn the_left_quarter_of_a_tab_is_the_gap_before_it() {
        assert_eq!(over(105.0, 0, false), StripTarget::Insert(1));
        assert_eq!(over(128.9, 0, false), StripTarget::Insert(1));
    }

    #[test]
    fn the_right_quarter_of_a_tab_is_the_gap_after_it() {
        assert_eq!(over(179.1, 0, false), StripTarget::Insert(2));
        assert_eq!(over(204.0, 0, false), StripTarget::Insert(2));
    }

    #[test]
    fn the_quarter_lines_belong_to_the_middle() {
        assert_eq!(over(129.0, 0, false), StripTarget::BringForward(1));
        assert_eq!(over(179.0, 0, false), StripTarget::BringForward(1));
    }

    #[test]
    fn the_gap_between_two_tabs_is_that_gap() {
        assert_eq!(over(102.0, 0, false), StripTarget::Insert(1));
        assert_eq!(over(206.0, 0, false), StripTarget::Insert(2));
    }

    #[test]
    fn past_the_last_tab_is_after_it() {
        assert_eq!(over(309.0, 0, false), StripTarget::Insert(3));
        assert_eq!(over(2000.0, 0, false), StripTarget::Insert(3));
    }

    #[test]
    fn before_the_first_tab_is_before_it() {
        assert_eq!(over(-5.0, 0, false), StripTarget::Insert(0));
        assert_eq!(over(10.0, 0, false), StripTarget::Insert(0));
    }

    #[test]
    fn an_empty_strip_means_nothing() {
        assert_eq!(strip_target(10.0, &[], None, false), StripTarget::Nothing);
    }

    #[test]
    fn the_middle_of_the_tab_in_front_is_nothing() {
        assert_eq!(over(50.0, 0, false), StripTarget::Nothing);
        assert_eq!(over(50.0, 1, false), StripTarget::BringForward(0));
    }

    #[test]
    fn a_pane_alone_in_its_tab_is_offered_no_gap_on_its_own_strip() {
        assert_eq!(over(10.0, 0, true), StripTarget::Nothing);
        assert_eq!(over(102.0, 0, true), StripTarget::Nothing);
        assert_eq!(over(2000.0, 0, true), StripTarget::Nothing);
    }

    #[test]
    fn a_pane_alone_in_its_tab_can_still_bring_another_tab_forward() {
        assert_eq!(over(150.0, 0, true), StripTarget::BringForward(1));
    }

    #[test]
    fn the_mark_sits_in_the_gap_or_on_the_outer_edge() {
        assert_eq!(mark_x(0, &STRIP), Some(0.0));
        assert_eq!(mark_x(1, &STRIP), Some(102.0));
        assert_eq!(mark_x(3, &STRIP), Some(308.0));
        assert_eq!(mark_x(4, &STRIP), None);
    }

    #[test]
    fn a_tab_let_go_outside_gets_a_window_unless_it_is_the_only_one() {
        assert_eq!(tab_ending::<u8>(TabOver::Outside, 2, false), TabEnding::NewWindow);
        assert_eq!(tab_ending::<u8>(TabOver::Outside, 1, false), TabEnding::Stay);
        assert_eq!(tab_ending(TabOver::Other { window: 5u8, index: 0 }, 1, false), TabEnding::Join { window: 5, index: 0 });
        assert_eq!(tab_ending::<u8>(TabOver::Home, 3, false), TabEnding::Stay);
        assert_eq!(tab_ending(TabOver::Other { window: 5u8, index: 0 }, 3, true), TabEnding::Restore);
    }

    #[test]
    fn a_dropped_tab_goes_into_the_gap_nearest_the_pointer() {
        // Three tabs 100 wide from x=46.
        assert_eq!(insertion_index(0.0, 46.0, 100.0, 3), 0);
        assert_eq!(insertion_index(95.0, 46.0, 100.0, 3), 0);
        assert_eq!(insertion_index(97.0, 46.0, 100.0, 3), 1);
        assert_eq!(insertion_index(300.0, 46.0, 100.0, 3), 3);
        assert_eq!(insertion_index(900.0, 46.0, 100.0, 3), 3);
        assert_eq!(insertion_index(50.0, 46.0, 0.0, 3), 3);
    }
}
