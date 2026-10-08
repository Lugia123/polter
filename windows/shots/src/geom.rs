//! The geometry of choosing what to capture: rectangles on the virtual
//! screen, which monitor and which window a point is on, the drag that makes
//! a selection, the handles that adjust one.
//!
//! **One coordinate space, and it is physical pixels.** The host is
//! per-monitor DPI aware, so every number it is handed -- a monitor's
//! rectangle, a window's bounds, the cursor, a mouse message -- is already in
//! physical pixels on the virtual screen, whatever each monitor's scaling is.
//! Nothing here multiplies by a scale factor, and that absence is the design:
//! the saved image is in physical pixels because nothing ever left them. The
//! only conversions are translations: virtual screen to a monitor's overlay
//! window ([`Point::relative_to`] the monitor's origin) and virtual screen to
//! the image (relative to the selection's origin).
//!
//! Rectangles are half-open: `x..x+w`, `y..y+h`.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Point {
    pub x: i32,
    pub y: i32,
}

impl Point {
    pub const fn new(x: i32, y: i32) -> Point {
        Point { x, y }
    }

    /// This point in a space whose origin is `origin`.
    pub fn relative_to(self, origin: Point) -> Point {
        Point::new(self.x - origin.x, self.y - origin.y)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Rect {
        Rect { x, y, w, h }
    }

    /// From the left, top, right, bottom a Win32 `RECT` carries.
    pub fn from_ltrb(l: i32, t: i32, r: i32, b: i32) -> Rect {
        Rect::new(l, t, r - l, b - t)
    }

    /// The rectangle with `a` and `b` at opposite corners, whichever way the
    /// drag went.
    pub fn spanning(a: Point, b: Point) -> Rect {
        Rect::new(a.x.min(b.x), a.y.min(b.y), (a.x - b.x).abs(), (a.y - b.y).abs())
    }

    pub fn right(&self) -> i32 {
        self.x + self.w
    }

    pub fn bottom(&self) -> i32 {
        self.y + self.h
    }

    pub fn origin(&self) -> Point {
        Point::new(self.x, self.y)
    }

    pub fn is_empty(&self) -> bool {
        self.w <= 0 || self.h <= 0
    }

    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.x && p.x < self.right() && p.y >= self.y && p.y < self.bottom()
    }

    /// The part of this rectangle inside `other`, if any.
    pub fn intersect(&self, other: Rect) -> Option<Rect> {
        let r = Rect::from_ltrb(
            self.x.max(other.x),
            self.y.max(other.y),
            self.right().min(other.right()),
            self.bottom().min(other.bottom()),
        );
        (!r.is_empty()).then_some(r)
    }

    /// `p` moved onto this rectangle if it was outside. The right and bottom
    /// edges count: a drag that ends on them selects up to them.
    pub fn clamp(&self, p: Point) -> Point {
        Point::new(p.x.clamp(self.x, self.right()), p.y.clamp(self.y, self.bottom()))
    }

    /// This rectangle in a space whose origin is `origin`.
    pub fn relative_to(self, origin: Point) -> Rect {
        Rect::new(self.x - origin.x, self.y - origin.y, self.w, self.h)
    }
}

/// How far the pointer travels with the button down before a press is a drag
/// rather than a click, in pixels.
pub const DRAG_THRESHOLD: i32 = 4;

/// Whether a press at `down` that has reached `now` is a drag: more than
/// [`DRAG_THRESHOLD`] pixels along either axis.
pub fn is_drag(down: Point, now: Point) -> bool {
    (now.x - down.x).abs().max((now.y - down.y).abs()) > DRAG_THRESHOLD
}

/// Which monitor `p` is on.
pub fn monitor_at(monitors: &[Rect], p: Point) -> Option<usize> {
    monitors.iter().position(|m| m.contains(p))
}

/// The free selection a drag from `down` to `now` makes.
///
/// **A selection does not cross monitors.** It is confined to `monitor`, the
/// one the drag started on: `now` is pulled back onto it. `None` while the
/// rectangle has no area.
pub fn drag_selection(down: Point, now: Point, monitor: Rect) -> Option<Rect> {
    let r = Rect::spanning(monitor.clamp(down), monitor.clamp(now));
    (!r.is_empty()).then_some(r)
}

/// The topmost window under `p`: its index in `windows` and the part of it
/// on `monitor`.
///
/// `windows` is in z-order, topmost first, and must not include the overlay
/// windows themselves -- the host takes the list before it creates them.
pub fn pick_window(windows: &[Rect], p: Point, monitor: Rect) -> Option<(usize, Rect)> {
    let i = windows.iter().position(|w| w.contains(p))?;
    windows[i].intersect(monitor).map(|r| (i, r))
}

/// One of the eight places a selection can be resized from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handle {
    NW,
    N,
    NE,
    E,
    SE,
    S,
    SW,
    W,
}

impl Handle {
    pub const ALL: [Handle; 8] =
        [Handle::NW, Handle::NE, Handle::SE, Handle::SW, Handle::N, Handle::E, Handle::S, Handle::W];

    /// Which edges this handle moves: (west, north, east, south).
    fn edges(self) -> (bool, bool, bool, bool) {
        match self {
            Handle::NW => (true, true, false, false),
            Handle::N => (false, true, false, false),
            Handle::NE => (false, true, true, false),
            Handle::E => (false, false, true, false),
            Handle::SE => (false, false, true, true),
            Handle::S => (false, false, false, true),
            Handle::SW => (true, false, false, true),
            Handle::W => (true, false, false, false),
        }
    }

    /// Where the handle is drawn on `sel`.
    pub fn at(self, sel: Rect) -> Point {
        let (w, n, e, s) = self.edges();
        let x = if w { sel.x } else if e { sel.right() } else { sel.x + sel.w / 2 };
        let y = if n { sel.y } else if s { sel.bottom() } else { sel.y + sel.h / 2 };
        Point::new(x, y)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    Handle(Handle),
    Inside,
    Outside,
}

/// What of the selection is under `p`. A handle is hit within `grip` pixels
/// of its centre; corners are asked first, so on a small selection where
/// handles overlap the corner wins.
pub fn hit(sel: Rect, p: Point, grip: i32) -> Hit {
    for h in Handle::ALL {
        let c = h.at(sel);
        if (p.x - c.x).abs() <= grip && (p.y - c.y).abs() <= grip {
            return Hit::Handle(h);
        }
    }
    if sel.contains(p) {
        Hit::Inside
    } else {
        Hit::Outside
    }
}

/// `sel` with `handle` dragged to `to`, kept inside `bounds`.
///
/// Dragging an edge past its opposite flips the rectangle rather than
/// producing a negative size, and it never gets smaller than one pixel.
pub fn resize(sel: Rect, handle: Handle, to: Point, bounds: Rect) -> Rect {
    let to = bounds.clamp(to);
    let (w, n, e, s) = handle.edges();
    let (mut l, mut t, mut r, mut b) = (sel.x, sel.y, sel.right(), sel.bottom());
    if w {
        l = to.x;
    }
    if e {
        r = to.x;
    }
    if n {
        t = to.y;
    }
    if s {
        b = to.y;
    }
    let (l, r) = at_least_one(l.min(r), l.max(r), bounds.x, bounds.right());
    let (t, b) = at_least_one(t.min(b), t.max(b), bounds.y, bounds.bottom());
    Rect::from_ltrb(l, t, r, b)
}

fn at_least_one(lo: i32, hi: i32, min: i32, max: i32) -> (i32, i32) {
    if hi > lo {
        (lo, hi)
    } else if lo < max {
        (lo, lo + 1)
    } else {
        (max - 1, max).max((min, min + 1))
    }
}

/// `sel` moved by `delta` without changing size, stopped at `bounds`' edges.
pub fn move_by(sel: Rect, delta: Point, bounds: Rect) -> Rect {
    let x = (sel.x + delta.x).min(bounds.right() - sel.w).max(bounds.x);
    let y = (sel.y + delta.y).min(bounds.bottom() - sel.h).max(bounds.y);
    Rect::new(x, y, sel.w, sel.h)
}

/// Where the toolbar goes: under the selection, or above it when there is no
/// room under, or inside its bottom edge when there is no room above either
/// (a selection as tall as the monitor). Its right edge lines up with the
/// selection's, pulled back onto the monitor -- **except inside the bottom
/// edge, where it is centred on the selection** (#1197, as on macOS): there
/// the selection is the whole screen and a bar in its corner is one more
/// thing in the way.
pub fn toolbar_origin(sel: Rect, bar: (i32, i32), monitor: Rect, gap: i32) -> Point {
    let (bw, bh) = bar;
    let (y, inside) = if sel.bottom() + gap + bh <= monitor.bottom() {
        (sel.bottom() + gap, false)
    } else if sel.y - gap - bh >= monitor.y {
        (sel.y - gap - bh, false)
    } else {
        (sel.bottom() - gap - bh, true)
    };
    let x = if inside { sel.x + (sel.w - bw) / 2 } else { sel.right() - bw };
    let x = x.min(monitor.right() - bw).max(monitor.x);
    Point::new(x, y)
}

/// The three corners of an arrow's head: the tip at `to`, then the two ends
/// of its base, `size` pixels back along the shaft and `size / 2` to either
/// side. `None` for an arrow with no length, which has no direction.
pub fn arrow_head(from: Point, to: Point, size: i32) -> Option<[Point; 3]> {
    let (dx, dy) = ((to.x - from.x) as f64, (to.y - from.y) as f64);
    let len = (dx * dx + dy * dy).sqrt();
    if len == 0.0 {
        return None;
    }
    let (ux, uy) = (dx / len, dy / len);
    let size = size as f64;
    let (bx, by) = (to.x as f64 - ux * size, to.y as f64 - uy * size);
    let (px, py) = (-uy * size / 2.0, ux * size / 2.0);
    let at = |x: f64, y: f64| Point::new(x.round() as i32, y.round() as i32);
    Some([to, at(bx + px, by + py), at(bx - px, by - py)])
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: fn(i32, i32) -> Point = Point::new;
    const R: fn(i32, i32, i32, i32) -> Rect = Rect::new;

    /// Two monitors side by side with different scaling, as Windows reports
    /// them to a per-monitor-aware process: a 2560x1440 primary at the origin
    /// and a 3840x2160 one to its *left*, so its coordinates are negative.
    const PRIMARY: Rect = Rect::new(0, 0, 2560, 1440);
    const LEFT: Rect = Rect::new(-3840, -200, 3840, 2160);

    #[test]
    fn a_drag_in_either_direction_is_the_same_rectangle() {
        assert_eq!(Rect::spanning(P(10, 20), P(110, 70)), R(10, 20, 100, 50));
        assert_eq!(Rect::spanning(P(110, 70), P(10, 20)), R(10, 20, 100, 50));
        assert_eq!(Rect::spanning(P(110, 20), P(10, 70)), R(10, 20, 100, 50));
    }

    #[test]
    fn a_rectangle_is_half_open() {
        let r = R(10, 20, 100, 50);
        assert!(r.contains(P(10, 20)));
        assert!(r.contains(P(109, 69)));
        assert!(!r.contains(P(110, 69)));
        assert!(!r.contains(P(109, 70)));
        assert!(!r.contains(P(9, 20)));
        assert_eq!(Rect::from_ltrb(10, 20, 110, 70), r);
        assert_eq!((r.right(), r.bottom()), (110, 70));
    }

    #[test]
    fn four_pixels_is_a_click_and_five_is_a_drag() {
        let d = P(100, 100);
        assert!(!is_drag(d, P(100, 100)));
        assert!(!is_drag(d, P(104, 96)));
        assert!(is_drag(d, P(105, 100)));
        assert!(is_drag(d, P(100, 95)));
        // Along both axes at once it is still the larger one that counts.
        assert!(!is_drag(d, P(104, 104)));
    }

    #[test]
    fn a_point_is_on_the_monitor_that_contains_it() {
        let m = [PRIMARY, LEFT];
        assert_eq!(monitor_at(&m, P(0, 0)), Some(0));
        assert_eq!(monitor_at(&m, P(-1, 0)), Some(1));
        assert_eq!(monitor_at(&m, P(-3840, -200)), Some(1));
        assert_eq!(monitor_at(&m, P(2559, 1439)), Some(0));
        // Above the primary, beside the taller left monitor: on neither.
        assert_eq!(monitor_at(&m, P(100, -100)), None);
    }

    #[test]
    fn a_drag_makes_the_rectangle_between_its_ends() {
        assert_eq!(drag_selection(P(100, 100), P(300, 250), PRIMARY), Some(R(100, 100, 200, 150)));
        assert_eq!(drag_selection(P(100, 100), P(100, 250), PRIMARY), None, "no width yet");
    }

    #[test]
    fn a_drag_onto_the_next_monitor_stops_at_the_edge_of_the_first() {
        // Started on the primary, dragged left across onto the other one.
        assert_eq!(drag_selection(P(200, 100), P(-500, 300), PRIMARY), Some(R(0, 100, 200, 200)));
        // And the other way, from the left monitor onto the primary.
        assert_eq!(drag_selection(P(-200, 100), P(500, 300), LEFT), Some(R(-200, 100, 200, 200)));
        // Off the bottom-right corner: up to the last pixel, not past it.
        assert_eq!(
            drag_selection(P(2500, 1400), P(9000, 9000), PRIMARY),
            Some(R(2500, 1400, 60, 40))
        );
    }

    #[test]
    fn the_image_keeps_virtual_screen_pixels_one_for_one() {
        // A selection on the left monitor, and a mark inside it.
        let sel = R(-3000, 100, 1280, 800);
        let mark = P(-2588, 196);
        // In the overlay window covering that monitor:
        assert_eq!(sel.relative_to(LEFT.origin()), R(840, 300, 1280, 800));
        assert_eq!(mark.relative_to(LEFT.origin()), P(1252, 396));
        // In the saved image: same size as selected, mark relative to it.
        assert_eq!(sel.relative_to(sel.origin()), R(0, 0, 1280, 800));
        assert_eq!(mark.relative_to(sel.origin()), P(412, 96));
    }

    #[test]
    fn the_topmost_window_under_the_cursor_is_picked() {
        // Topmost first: a small dialog over a browser over the desktop.
        let windows = [R(400, 300, 300, 200), R(100, 100, 1200, 900), R(0, 0, 2560, 1440)];
        assert_eq!(pick_window(&windows, P(500, 400), PRIMARY), Some((0, windows[0])));
        assert_eq!(pick_window(&windows, P(150, 150), PRIMARY), Some((1, windows[1])));
        assert_eq!(pick_window(&windows, P(2000, 1200), PRIMARY), Some((2, windows[2])));
        assert_eq!(pick_window(&windows[..2], P(2000, 1200), PRIMARY), None);
    }

    #[test]
    fn a_picked_window_is_cut_to_the_monitor_the_cursor_is_on() {
        // A window straddling both monitors.
        let windows = [R(-300, 100, 800, 600)];
        assert_eq!(pick_window(&windows, P(100, 200), PRIMARY), Some((0, R(0, 100, 500, 600))));
        assert_eq!(pick_window(&windows, P(-100, 200), LEFT), Some((0, R(-300, 100, 300, 600))));
        // A maximised window's frame hangs a few pixels off its monitor.
        let maximised = [R(-8, -8, 2576, 1456)];
        assert_eq!(pick_window(&maximised, P(5, 5), PRIMARY), Some((0, PRIMARY)));
    }

    #[test]
    fn handles_sit_on_the_corners_and_the_middle_of_each_edge() {
        let s = R(100, 200, 300, 100);
        assert_eq!(Handle::NW.at(s), P(100, 200));
        assert_eq!(Handle::N.at(s), P(250, 200));
        assert_eq!(Handle::NE.at(s), P(400, 200));
        assert_eq!(Handle::E.at(s), P(400, 250));
        assert_eq!(Handle::SE.at(s), P(400, 300));
        assert_eq!(Handle::S.at(s), P(250, 300));
        assert_eq!(Handle::SW.at(s), P(100, 300));
        assert_eq!(Handle::W.at(s), P(100, 250));
    }

    #[test]
    fn a_point_hits_a_handle_the_inside_or_nothing() {
        let s = R(100, 200, 300, 100);
        assert_eq!(hit(s, P(402, 298), 4), Hit::Handle(Handle::SE));
        assert_eq!(hit(s, P(96, 250), 4), Hit::Handle(Handle::W));
        assert_eq!(hit(s, P(95, 250), 4), Hit::Outside);
        assert_eq!(hit(s, P(200, 240), 4), Hit::Inside);
        assert_eq!(hit(s, P(500, 240), 4), Hit::Outside);
        // On a selection so small the handles overlap, the corner wins.
        assert_eq!(hit(R(100, 200, 6, 6), P(100, 201), 4), Hit::Handle(Handle::NW));
    }

    #[test]
    fn a_handle_moves_only_its_own_edges() {
        let s = R(100, 200, 300, 100);
        assert_eq!(resize(s, Handle::E, P(450, 999), PRIMARY), R(100, 200, 350, 100));
        assert_eq!(resize(s, Handle::N, P(999, 150), PRIMARY), R(100, 150, 300, 150));
        assert_eq!(resize(s, Handle::SW, P(50, 350), PRIMARY), R(50, 200, 350, 150));
        assert_eq!(resize(s, Handle::NE, P(420, 180), PRIMARY), R(100, 180, 320, 120));
    }

    #[test]
    fn dragging_an_edge_past_its_opposite_flips_the_selection() {
        let s = R(100, 200, 300, 100);
        assert_eq!(resize(s, Handle::E, P(40, 0), PRIMARY), R(40, 200, 60, 100));
        assert_eq!(resize(s, Handle::S, P(0, 120), PRIMARY), R(100, 120, 300, 80));
    }

    #[test]
    fn a_resize_stays_on_the_monitor_and_never_reaches_zero() {
        let s = R(100, 200, 300, 100);
        assert_eq!(resize(s, Handle::E, P(9000, 0), PRIMARY), R(100, 200, 2460, 100));
        assert_eq!(resize(s, Handle::W, P(-50, 0), PRIMARY), R(0, 200, 400, 100));
        // Onto its own opposite edge: one pixel, not none.
        assert_eq!(resize(s, Handle::E, P(100, 0), PRIMARY), R(100, 200, 1, 100));
        // At the monitor's far edge the one pixel is taken from inside it.
        let edge = R(2500, 200, 60, 100);
        assert_eq!(resize(edge, Handle::W, P(2560, 0), PRIMARY), R(2559, 200, 1, 100));
    }

    #[test]
    fn moving_keeps_the_size_and_stops_at_the_monitor() {
        let s = R(100, 200, 300, 100);
        assert_eq!(move_by(s, P(50, -20), PRIMARY), R(150, 180, 300, 100));
        assert_eq!(move_by(s, P(-500, -500), PRIMARY), R(0, 0, 300, 100));
        assert_eq!(move_by(s, P(9000, 9000), PRIMARY), R(2260, 1340, 300, 100));
        assert_eq!(move_by(R(-3000, 0, 300, 100), P(5000, 0), LEFT), R(-300, 0, 300, 100));
    }

    #[test]
    fn the_toolbar_goes_below_then_above_then_inside() {
        let bar = (360, 40);
        assert_eq!(toolbar_origin(R(100, 200, 600, 300), bar, PRIMARY, 8), P(340, 508));
        // No room below: above.
        assert_eq!(toolbar_origin(R(100, 1000, 600, 420), bar, PRIMARY, 8), P(340, 952));
        // The whole monitor selected: inside the bottom edge.
        assert_eq!(toolbar_origin(PRIMARY, bar, PRIMARY, 8), P(1100, 1392), "inside: centred, not at the right");
    }

    #[test]
    fn the_toolbar_stays_on_the_monitor_sideways() {
        let bar = (360, 40);
        // A narrow selection at the left edge: the bar would start off-screen.
        assert_eq!(toolbar_origin(R(0, 200, 100, 300), bar, PRIMARY, 8), P(0, 508));
        assert_eq!(toolbar_origin(R(-3840, 0, 100, 300), bar, LEFT, 8), P(-3840, 308));
    }

    #[test]
    fn an_arrow_head_points_along_the_shaft() {
        assert_eq!(arrow_head(P(0, 0), P(100, 0), 10), Some([P(100, 0), P(90, 5), P(90, -5)]));
        assert_eq!(arrow_head(P(0, 0), P(0, -100), 10), Some([P(0, -100), P(5, -90), P(-5, -90)]));
        assert_eq!(arrow_head(P(100, 0), P(0, 0), 10), Some([P(0, 0), P(10, -5), P(10, 5)]));
        assert_eq!(arrow_head(P(7, 7), P(7, 7), 10), None);
    }
}
