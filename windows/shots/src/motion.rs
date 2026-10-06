//! What changes over a moment instead of at once (`screenshot.md` §9.8.4.0
//! and §9.8.7): a cell lighting up under the pointer, the clear window
//! giving way to the next one, the rest of the screen going to glass as a
//! selection is dragged out.
//!
//! **Nothing here blurs and nothing here draws**: a transition is two
//! pictures that already exist, mixed by a share that moves with time. The
//! host asks, for the time it is, which shares to use ([`Holes::layers`],
//! [`Crossfade::apply`]) and whether anything is still moving
//! ([`Holes::busy`]) -- which is the only reason for it to keep a timer.
//! Times are milliseconds, from wherever the host counts.

use crate::chrome::State;
use crate::geom::Rect;
use crate::look::transition_ms;

/// A share on its way from one value to another, in a straight line.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fade {
    from: f64,
    to: f64,
    start: f64,
    ms: f64,
}

impl Fade {
    pub fn new(from: f64, to: f64, start: f64, ms: f64) -> Fade {
        Fade { from, to, start, ms }
    }

    /// Where it has got to at `now`.
    pub fn at(&self, now: f64) -> f64 {
        if self.ms <= 0.0 || now >= self.start + self.ms {
            return self.to;
        }
        self.from + (self.to - self.from) * ((now - self.start) / self.ms).clamp(0.0, 1.0)
    }

    pub fn done(&self, now: f64) -> bool {
        self.ms <= 0.0 || now >= self.start + self.ms
    }
}

/// One monitor's clear part over time. What is clear now is `hole`; what
/// was clear a moment ago is still partly so, and goes.
#[derive(Clone, Debug, Default)]
pub struct Holes {
    /// Whether a first frame has been shown. The first is as it is: a
    /// screenshot does not fade in.
    seen: bool,
    /// The hole of the frame before, and whether it was a selection (made
    /// or being dragged) rather than the window under the pointer.
    last: Option<(Rect, bool)>,
    /// The window under the pointer coming clear.
    rising: Option<Fade>,
    /// What was clear and is going to glass.
    fading: Vec<(Rect, Fade)>,
}

impl Holes {
    pub fn new() -> Holes {
        Holes::default()
    }

    /// This frame's hole on `monitor` is `hole`; `chosen` when it is a
    /// selection. Called once for every frame, before [`Self::layers`].
    ///
    /// * The window under the pointer changed: the old one goes to glass
    ///   and the new one comes clear, over `WINDOW_SWITCH`.
    /// * A selection began to be dragged out: **from this frame the hole
    ///   is the dragged rectangle, whole**, and what was clear before goes
    ///   to glass round it over `DRAG_START`.
    /// * A selection moved or changed size: nothing fades. The hole is
    ///   where the outline is, in the same frame, every frame.
    /// * The whole monitor (no window to pick) neither fades nor comes
    ///   clear: mixing every pixel of a monitor is the one transition that
    ///   costs a frame's worth of work for each frame, and it is cut.
    ///
    /// `animate` false -- the system's animations are off -- and every
    /// change is at once.
    pub fn step(&mut self, hole: Option<Rect>, chosen: bool, monitor: Rect, now: f64, animate: bool) {
        self.fading.retain(|(_, f)| !f.done(now));
        if self.rising.is_some_and(|f| f.done(now)) {
            self.rising = None;
        }
        let next = hole.map(|r| (r, chosen));
        if next == self.last {
            return;
        }
        let was = std::mem::replace(&mut self.last, next);
        if !std::mem::replace(&mut self.seen, true) {
            return;
        }
        if !animate {
            self.rising = None;
            self.fading.clear();
            return;
        }
        // The same rectangle, now a selection (a click on the window under
        // the pointer): nothing moves. And a selection that only moved.
        let same = was.map(|w| w.0) == next.map(|n| n.0);
        let moved = matches!((was, next), (Some((_, true)), Some((_, true))));
        if same || moved {
            if same {
                self.rising = None;
            }
            return;
        }
        if let Some((old, _)) = was {
            // It goes from as clear as it had got.
            let share = self.rising.map_or(1.0, |f| f.at(now));
            let ms = if chosen { transition_ms::DRAG_START } else { transition_ms::WINDOW_SWITCH };
            if old != monitor && share > 0.0 {
                self.fading.push((old, Fade::new(share, 0.0, now, ms)));
            }
        }
        self.rising = match next {
            Some((r, false)) if r != monitor => {
                // One that was on its way out comes back from where it was.
                let from = match self.fading.iter().position(|(f, _)| *f == r) {
                    Some(i) => self.fading.remove(i).1.at(now),
                    None => 0.0,
                };
                Some(Fade::new(from, 1.0, now, transition_ms::WINDOW_SWITCH))
            }
            _ => None,
        };
    }

    /// What is clear at `now` and how much, in parts of 256, in the order
    /// to lay it down: what is going first, this frame's hole last and
    /// over it.
    pub fn layers(&self, now: f64) -> Vec<(Rect, u32)> {
        let parts = |share: f64| (share.clamp(0.0, 1.0) * 256.0).round() as u32;
        let mut out: Vec<(Rect, u32)> = self.fading.iter().map(|(r, f)| (*r, parts(f.at(now)))).collect();
        if let Some((r, _)) = self.last {
            out.push((r, self.rising.map_or(256, |f| parts(f.at(now)))));
        }
        out
    }

    /// Whether anything is still on its way at `now`.
    pub fn busy(&self, now: f64) -> bool {
        self.fading.iter().any(|(_, f)| !f.done(now)) || self.rising.is_some_and(|f| !f.done(now))
    }
}

/// How long the toolbar takes to go from cells in the states `before` to
/// `after` (§9.8.4.0). `None`: nothing changed. `Some(0.0)`: at once --
/// **a press always is**, whatever else changed with it, and so is a cell
/// becoming one that can or cannot be pressed.
pub fn cells_change(before: &[State], after: &[State]) -> Option<f64> {
    if before == after {
        return None;
    }
    if before.len() != after.len() {
        // Another property row: the cells are other cells.
        return Some(if after.contains(&State::Down) { 0.0 } else { transition_ms::RELEASE });
    }
    let pairs = || before.iter().zip(after).filter(|(a, b)| a != b);
    let lit = |s: &State| matches!(s, State::Selected | State::SelectedHover);
    let over = |s: &State| matches!(s, State::Hover | State::SelectedHover);
    if pairs().any(|(a, b)| (*b == State::Down && *a != State::Down) || *a == State::Off || *b == State::Off) {
        return Some(0.0);
    }
    Some(if pairs().any(|(a, _)| *a == State::Down) {
        transition_ms::RELEASE
    } else if pairs().any(|(a, b)| lit(a) && !lit(b)) {
        transition_ms::DESELECT
    } else if pairs().any(|(a, b)| over(a) && !over(b)) {
        transition_ms::HOVER_OUT
    } else {
        transition_ms::HOVER_IN
    })
}

/// A rectangle of the screen going from what it showed to what it is to
/// show: the toolbar, when a cell's state changes.
pub struct Crossfade {
    rect: Rect,
    before: Vec<u8>,
    fade: Fade,
}

impl Crossfade {
    /// From what `shown` (a picture covering `shown_rect`) has in `rect`
    /// now. `None` when `rect` is not on it.
    pub fn new(shown: &[u8], shown_rect: Rect, rect: Rect, now: f64, ms: f64) -> Option<Crossfade> {
        let rect = rect.intersect(shown_rect)?;
        if shown.len() != shown_rect.w as usize * shown_rect.h as usize * 4 {
            return None;
        }
        let mut before = vec![0u8; rect.w as usize * rect.h as usize * 4];
        crate::pixels::blit(&mut before, rect, shown, shown_rect);
        Some(Crossfade { rect, before, fade: Fade::new(0.0, 1.0, now, ms) })
    }

    pub fn done(&self, now: f64) -> bool {
        self.fade.done(now)
    }

    /// `dst` (covering `dst_rect`) holds what is to be shown in the end;
    /// make it what is shown at `now`. Nothing outside the rectangle is
    /// touched.
    pub fn apply(&self, dst: &mut [u8], dst_rect: Rect, now: f64) {
        let Some(r) = self.rect.intersect(dst_rect) else { return };
        if dst.len() != dst_rect.w as usize * dst_rect.h as usize * 4 {
            return;
        }
        let t = (self.fade.at(now) * 256.0).round() as i32;
        for y in r.y..r.bottom() {
            let d = ((y - dst_rect.y) as usize * dst_rect.w as usize + (r.x - dst_rect.x) as usize) * 4;
            let b = ((y - self.rect.y) as usize * self.rect.w as usize + (r.x - self.rect.x) as usize) * 4;
            for i in 0..r.w as usize * 4 {
                let (from, to) = (self.before[b + i] as i32, dst[d + i] as i32);
                dst[d + i] = (from + ((to - from) * t + 128).div_euclid(256)) as u8;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MON: Rect = Rect::new(0, 0, 1920, 1080);
    const A: Rect = Rect::new(100, 100, 600, 400);
    const B: Rect = Rect::new(900, 300, 500, 500);

    #[test]
    fn a_fade_is_a_straight_line_that_ends() {
        let f = Fade::new(0.0, 1.0, 1000.0, 120.0);
        assert_eq!((f.at(900.0), f.at(1000.0), f.at(1060.0), f.at(1120.0), f.at(5000.0)), (0.0, 0.0, 0.5, 1.0, 1.0));
        assert!(!f.done(1119.0) && f.done(1120.0));
        // No time at all: there already.
        let at_once = Fade::new(0.2, 0.9, 1000.0, 0.0);
        assert!(at_once.done(1000.0));
        assert_eq!(at_once.at(1000.0), 0.9);
    }

    #[test]
    fn the_first_frame_is_as_it_is_and_the_window_under_the_pointer_changes_over_120_ms() {
        let mut h = Holes::new();
        h.step(Some(A), false, MON, 0.0, true);
        assert_eq!(h.layers(0.0), [(A, 256)], "a screenshot does not fade in");
        assert!(!h.busy(0.0));
        // The same window, frame after frame: nothing starts.
        h.step(Some(A), false, MON, 50.0, true);
        assert!(!h.busy(50.0));
        // The pointer goes to another window.
        h.step(Some(B), false, MON, 1000.0, true);
        assert_eq!(h.layers(1000.0), [(A, 256), (B, 0)]);
        assert!(h.busy(1000.0));
        h.step(Some(B), false, MON, 1060.0, true);
        assert_eq!(h.layers(1060.0), [(A, 128), (B, 128)]);
        h.step(Some(B), false, MON, 1120.0, true);
        assert_eq!(h.layers(1120.0), [(B, 256)]);
        assert!(!h.busy(1120.0), "and then nothing is moving");
    }

    #[test]
    fn a_change_of_mind_goes_on_from_where_things_had_got_to() {
        let mut h = Holes::new();
        h.step(Some(A), false, MON, 0.0, true);
        h.step(Some(B), false, MON, 1000.0, true);
        // A quarter of the way, back to the first window.
        h.step(Some(A), false, MON, 1030.0, true);
        assert_eq!(h.layers(1030.0), [(B, 64), (A, 192)], "each from where it was");
        // A full 120 ms from there, linear.
        assert_eq!(h.layers(1090.0), [(B, 32), (A, 224)]);
        h.step(Some(A), false, MON, 1150.0, true);
        assert_eq!(h.layers(1150.0), [(A, 256)]);
    }

    #[test]
    fn a_selection_dragged_out_is_clear_at_once_and_what_was_clear_goes_round_it() {
        let mut h = Holes::new();
        h.step(Some(A), false, MON, 0.0, true);
        // The drag begins: its rectangle, small at first.
        let drag = |n: i32| Rect::new(300, 200, 10 * n, 8 * n);
        h.step(Some(drag(1)), true, MON, 1000.0, true);
        assert_eq!(h.layers(1000.0), [(A, 256), (drag(1), 256)], "the hole is the rectangle from this frame");
        // It grows with every frame; the hole is always whole, and only
        // the window goes -- no fade is added for a selection that moved.
        for (n, now, share) in [(5, 1030.0, 192), (9, 1060.0, 128), (20, 1090.0, 64)] {
            h.step(Some(drag(n)), true, MON, now, true);
            assert_eq!(h.layers(now), [(A, share), (drag(n), 256)], "at {now}");
        }
        h.step(Some(drag(30)), true, MON, 1120.0, true);
        assert_eq!(h.layers(1120.0), [(drag(30), 256)]);
        assert!(!h.busy(1120.0));
        // Moved and resized afterwards: at once, every time.
        h.step(Some(drag(31)), true, MON, 2000.0, true);
        assert_eq!(h.layers(2000.0), [(drag(31), 256)]);
        assert!(!h.busy(2000.0));
    }

    #[test]
    fn a_click_on_the_window_under_the_pointer_moves_nothing() {
        let mut h = Holes::new();
        h.step(Some(A), false, MON, 0.0, true);
        h.step(Some(A), true, MON, 1000.0, true);
        assert_eq!(h.layers(1000.0), [(A, 256)]);
        assert!(!h.busy(1000.0));
    }

    #[test]
    fn the_whole_monitor_is_cut_and_so_is_everything_with_animations_off() {
        // No window under the pointer: the monitor, clear, at once; and a
        // drag out of it does not fade a monitor's worth of pixels.
        let mut h = Holes::new();
        h.step(Some(A), false, MON, 0.0, true);
        h.step(Some(MON), false, MON, 1000.0, true);
        assert_eq!(h.layers(1000.0), [(A, 256), (MON, 256)]);
        h.step(Some(Rect::new(5, 5, 50, 50)), true, MON, 2000.0, true);
        assert_eq!(h.layers(2000.0), [(Rect::new(5, 5, 50, 50), 256)]);
        assert!(!h.busy(2000.0));
        // A monitor the pointer left: all glass, its window fading.
        let mut h = Holes::new();
        h.step(Some(A), false, MON, 0.0, true);
        h.step(None, false, MON, 1000.0, true);
        assert_eq!(h.layers(1060.0), [(A, 128)]);
        // Animations off: whatever changes, it is there.
        let mut h = Holes::new();
        h.step(Some(A), false, MON, 0.0, false);
        h.step(Some(B), false, MON, 1000.0, false);
        assert_eq!(h.layers(1000.0), [(B, 256)]);
        assert!(!h.busy(1000.0));
    }

    #[test]
    fn a_press_is_at_once_and_everything_else_takes_the_time_the_look_gives() {
        use State::*;
        let ms = |a: &[State], b: &[State]| cells_change(a, b);
        assert_eq!(ms(&[Normal, Selected], &[Normal, Selected]), None);
        assert_eq!(ms(&[Normal], &[Hover]), Some(80.0));
        assert_eq!(ms(&[Hover], &[Normal]), Some(120.0));
        // From one cell to its neighbour: the one being left decides.
        assert_eq!(ms(&[Hover, Normal], &[Normal, Hover]), Some(120.0));
        assert_eq!(ms(&[Selected], &[SelectedHover]), Some(80.0));
        // Pressed: at once -- and the cell that was chosen lets go with it.
        assert_eq!(ms(&[Hover, Selected], &[Down, Normal]), Some(0.0));
        assert_eq!(ms(&[Normal], &[Down]), Some(0.0));
        // Let go: to chosen, or (Undo, Cancel) back to under the pointer.
        assert_eq!(ms(&[Down], &[SelectedHover]), Some(120.0));
        assert_eq!(ms(&[Down], &[Hover]), Some(120.0));
        assert_eq!(ms(&[Selected, Normal], &[Normal, Selected]), Some(100.0), "chosen by a key");
        // Can no longer be pressed, or can again: at once.
        assert_eq!(ms(&[Normal], &[Off]), Some(0.0));
        assert_eq!(ms(&[Off, Hover], &[Normal, Normal]), Some(0.0));
        // Another property row.
        assert_eq!(ms(&[Normal], &[Normal, Normal]), Some(120.0));
        assert_eq!(ms(&[Normal], &[Down, Normal]), Some(0.0));
    }

    #[test]
    fn a_crossfade_goes_from_what_was_shown_to_what_is_to_be_and_touches_nothing_else() {
        let whole = Rect::new(0, 0, 40, 30);
        let shown = vec![40u8; 40 * 30 * 4];
        let rect = Rect::new(10, 5, 20, 10);
        let c = Crossfade::new(&shown, whole, rect, 1000.0, 100.0).unwrap();
        let at = |now: f64| {
            let mut target = vec![200u8; 40 * 30 * 4];
            c.apply(&mut target, whole, now);
            (target[(8 * 40 + 15) * 4], target[0], target[(4 * 40 + 15) * 4], target[(8 * 40 + 30) * 4])
        };
        // In the rectangle: what was shown, halfway, what is to be.
        // Outside it: what is to be, always.
        assert_eq!(at(1000.0), (40, 200, 200, 200));
        assert_eq!(at(1050.0), (120, 200, 200, 200));
        assert_eq!(at(1100.0), (200, 200, 200, 200));
        assert!(!c.done(1099.0) && c.done(1100.0));
        // A rectangle off the picture is no crossfade; one partly off is
        // the part that is on.
        assert!(Crossfade::new(&shown, whole, Rect::new(100, 100, 5, 5), 0.0, 100.0).is_none());
        let edge = Crossfade::new(&shown, whole, Rect::new(30, 20, 50, 50), 0.0, 100.0).unwrap();
        let mut target = vec![200u8; 40 * 30 * 4];
        edge.apply(&mut target, whole, 0.0);
        assert_eq!((target[(25 * 40 + 35) * 4], target[(25 * 40 + 29) * 4]), (40, 200));
    }
}
