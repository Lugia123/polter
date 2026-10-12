//! One selection chip's move from where it was to where it is now, written
//! out: whether it moves at all, and if so where it is, how large and how
//! far lifted, at every moment until it is still.
//!
//! **This is the macOS host's `ControlRoomChipSlide`, line for line** --
//! the same spring, the same lift, the same moment at which it counts as
//! still -- and `tools/control-room-hosts-agree.py` holds the two to the
//! same numbers at the same moments. What is this host's alone is `Run`:
//! here the chip is drawn a frame at a time, so the slide is asked where
//! the chip is *now*, and **told when to stop asking** (`Frame::last`).
//!
//! Nothing here bends what is under the chip. That is glass, which this
//! host does not have.

use std::sync::OnceLock;

use crate::layout::{spring, Rect};
use crate::look::selection;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Plan {
    /// The chip is simply at the new place: the system has animations off,
    /// there is nowhere to come from, or nowhere to go.
    Jump,
    /// It slides in from this far away (where it was, less where it is).
    Slide { dx: f64, dy: f64 },
}

/// `animations` is the system's own setting for whether anything inside a
/// window moves (`SPI_GETCLIENTAREAANIMATION`).
pub fn plan(from: Option<Rect>, to: Rect, animations: bool) -> Plan {
    let Some(from) = from else { return Plan::Jump };
    if !animations {
        return Plan::Jump;
    }
    let dx = (from.x + from.w / 2.0) - (to.x + to.w / 2.0);
    let dy = (from.y + from.h / 2.0) - (to.y + to.h / 2.0);
    if dx == 0.0 && dy == 0.0 {
        return Plan::Jump;
    }
    Plan::Slide { dx, dy }
}

/// How fast the spring's progress is changing at `t` seconds, per second.
pub fn speed(t: f64) -> f64 {
    let (period, damping) = (selection::SPRING_PERIOD, selection::SPRING_DAMPING);
    if t <= 0.0 || period <= 0.0 {
        return 0.0;
    }
    let omega = 2.0 * std::f64::consts::PI / period;
    if damping >= 1.0 {
        return omega * omega * t * (-omega * t).exp();
    }
    let wd = omega * (1.0 - damping * damping).sqrt();
    (-damping * omega * t).exp() * omega * omega / wd * (wd * t).sin()
}

/// When the spring first has only `remaining` of the way left to go.
pub fn reaches(remaining: f64) -> f64 {
    let period = selection::SPRING_PERIOD;
    let step = period / 1000.0;
    let mut t = 0.0;
    while t < period * 20.0 && spring::progress(t) < 1.0 - remaining {
        t += step;
    }
    t
}

/// After how long the spring stays within `within` of its end.
pub fn settles(within: f64) -> f64 {
    let period = selection::SPRING_PERIOD;
    if period <= 0.0 || within <= 0.0 {
        return 0.0;
    }
    let step = period / 1000.0;
    // Walk back from well past the end to the last moment it was out.
    let mut t = period * 20.0;
    while t > 0.0 && (1.0 - spring::progress(t)).abs() <= within {
        t -= step;
    }
    t + step
}

/// When the chip starts back down.
pub fn lands_at() -> f64 {
    static AT: OnceLock<f64> = OnceLock::new();
    *AT.get_or_init(|| reaches(selection::LIFT_LANDS_WITH_REMAINING))
}

/// When it is still.
pub fn duration() -> f64 {
    static AT: OnceLock<f64> = OnceLock::new();
    *AT.get_or_init(|| settles(selection::SETTLED_WITHIN))
}

/// Whether a slide that began `t` seconds ago is over. The same moment
/// `Run::frame` first says `last`.
pub fn over(t: f64) -> bool {
    t >= duration()
}

/// How far the chip is lifted at `t`: up to 1 in `LIFT_IN`, there until
/// `lands_at`, and down again by the time it is still.
pub fn lift(t: f64) -> f64 {
    let (lands, end) = (lands_at(), duration());
    if t <= 0.0 || t >= end {
        return 0.0;
    }
    if t < selection::LIFT_IN {
        return t / selection::LIFT_IN;
    }
    if t <= lands {
        return 1.0;
    }
    let x = (t - lands) / (end - lands);
    // Eased, so that it does not drop off a corner.
    1.0 - x * x * (3.0 - 2.0 * x)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sample {
    /// From where it will rest.
    pub dx: f64,
    pub dy: f64,
    /// Along the way it is going, and across it; 1 is its own size.
    pub along: f64,
    pub across: f64,
}

/// The chip at `t` seconds into a slide of (`dx`, `dy`).
pub fn sample(t: f64, dx: f64, dy: f64, lift_scale: f64) -> Sample {
    let left = 1.0 - spring::progress(t);
    let lifted = 1.0 + lift_scale * lift(t);
    // Fastest is what an undamped spring of this period would reach.
    let fastest = 2.0 * std::f64::consts::PI / selection::SPRING_PERIOD;
    let quick = (speed(t).abs() / fastest).min(1.0);
    Sample {
        dx: dx * left,
        dy: dy * left,
        along: lifted * (1.0 + selection::STRETCH_ALONG * quick),
        across: lifted * (1.0 - selection::SQUEEZE_ACROSS * quick),
    }
}

/// One slide in progress: between which two places, and how much the chip
/// grows while it is in the air (`LIFT_SCALE_ROW` or
/// `LIFT_SCALE_WINDOW_TAB`).
///
/// `to` is where the chip rests **now**. A host hands in the selected
/// thing's place as it is at this frame, so a list that is laid out again
/// in the middle of a slide still ends the slide exactly on its row.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Run {
    pub from: Rect,
    pub to: Rect,
    pub lift_scale: f64,
}

/// The chip at one moment of a slide.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Frame {
    pub chip: Rect,
    /// 0 at rest, 1 in the air: what the chip's colour and its shadow go by.
    pub lift: f64,
    /// The slide is over: the chip is at rest, exactly, and **whatever was
    /// redrawing it stops**. Every frame from here on says the same.
    pub last: bool,
}

impl Run {
    pub fn frame(&self, t: f64) -> Frame {
        if over(t) {
            return Frame { chip: self.to, lift: 0.0, last: true };
        }
        let centre = |r: Rect| (r.x + r.w / 2.0, r.y + r.h / 2.0);
        let ((fx, fy), (tx, ty)) = (centre(self.from), centre(self.to));
        let (dx, dy) = (fx - tx, fy - ty);
        let s = sample(t, dx, dy, self.lift_scale);
        // The size goes with the place: a tall row to a short one shrinks
        // on the way.
        let p = spring::progress(t);
        let (w, h) = (self.from.w + (self.to.w - self.from.w) * p, self.from.h + (self.to.h - self.from.h) * p);
        let sideways = dx.abs() >= dy.abs();
        let (w, h) = if sideways { (w * s.along, h * s.across) } else { (w * s.across, h * s.along) };
        Frame { chip: Rect { x: tx + s.dx - w / 2.0, y: ty + s.dy - h / 2.0, w, h }, lift: lift(t), last: false }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TAB_WAS: Rect = Rect { x: 0.0, y: 0.0, w: 293.0, h: 24.0 };
    const TAB_NOW: Rect = Rect { x: 588.0, y: 0.0, w: 292.0, h: 24.0 };

    #[test]
    fn a_chip_slides_only_with_somewhere_to_come_from_and_animations_on() {
        assert_eq!(plan(Some(TAB_WAS), TAB_NOW, true), Plan::Slide { dx: -587.5, dy: 0.0 });
        // The system has animations off: it is simply there.
        assert_eq!(plan(Some(TAB_WAS), TAB_NOW, false), Plan::Jump);
        assert_eq!(plan(None, TAB_NOW, true), Plan::Jump);
        assert_eq!(plan(Some(TAB_NOW), TAB_NOW, true), Plan::Jump);
        // Down a list is a slide as much as along a bar.
        let was = Rect { x: 6.0, y: 38.0, w: 368.0, h: 100.0 };
        let now = Rect { x: 6.0, y: 146.0, w: 368.0, h: 80.0 };
        assert_eq!(plan(Some(was), now, true), Plan::Slide { dx: 0.0, dy: -98.0 });
    }

    #[test]
    fn the_slide_is_over_when_it_stays_within_the_tables_fraction_of_its_end() {
        let end = duration();
        // The design: "still at about 0.45 s".
        assert!(end > 0.38 && end < 0.47, "{end}");
        let mut t = end;
        while t < end + 2.0 {
            assert!((1.0 - spring::progress(t)).abs() <= selection::SETTLED_WITHIN, "out again at {t}");
            t += 0.001;
        }
        assert!((1.0 - spring::progress(end - 0.002)).abs() > selection::SETTLED_WITHIN);
    }

    #[test]
    fn the_chip_is_up_for_the_way_and_down_by_the_time_it_is_still() {
        let lands = lands_at();
        // It starts down with three tenths of the way still to go.
        assert!((spring::progress(lands) - (1.0 - selection::LIFT_LANDS_WITH_REMAINING)).abs() < 0.01);
        assert!(lands > selection::LIFT_IN && lands < duration());
        assert_eq!(lift(0.0), 0.0);
        assert!((lift(selection::LIFT_IN / 2.0) - 0.5).abs() < 0.001);
        assert_eq!(lift((selection::LIFT_IN + lands) / 2.0), 1.0);
        assert_eq!(lift(duration()), 0.0);
        // And it only comes down once it has started to.
        let mut t = lands;
        let mut before = lift(t);
        while t < duration() {
            t += 0.005;
            let now = lift(t);
            assert!(now <= before, "rose again at {t}");
            before = now;
        }
    }

    #[test]
    fn the_springs_speed_is_how_fast_its_progress_changes() {
        for t in [0.02, 0.1, 0.2, 0.3] {
            let h = 1e-6;
            let measured = (spring::progress(t + h) - spring::progress(t - h)) / (2.0 * h);
            assert!((measured - speed(t)).abs() < 1e-4, "at {t}");
        }
    }

    #[test]
    fn a_slide_starts_where_the_chip_was_passes_its_place_and_comes_back() {
        let scale = selection::LIFT_SCALE_WINDOW_TAB;
        assert_eq!(sample(0.0, -587.5, 0.0, scale), Sample { dx: -587.5, dy: 0.0, along: 1.0, across: 1.0 });
        let mut furthest: f64 = 0.0;
        let (mut longest, mut widest, mut narrowest): (f64, f64, f64) = (1.0, 1.0, 1.0);
        let mut t = 0.0;
        while t < duration() {
            let s = sample(t, -587.5, 0.0, scale);
            furthest = furthest.max(s.dx);
            longest = longest.max(s.along);
            widest = widest.max(s.across);
            narrowest = narrowest.min(s.across);
            t += 1.0 / 120.0;
        }
        // About 4% of the way past, and back.
        assert!(furthest > 587.5 * 0.03 && furthest < 587.5 * 0.05, "{furthest}");
        // In the air it is larger by the table's lift, longer along the way
        // by no more than the stretch, and never wider across than lifted.
        assert!(longest > 1.0 + scale);
        assert!(longest <= (1.0 + scale) * (1.0 + selection::STRETCH_ALONG));
        assert!(widest <= 1.0 + scale);
        assert!(narrowest >= 1.0 - selection::SQUEEZE_ACROSS);
    }

    #[test]
    fn the_first_frame_is_where_the_chip_was_and_the_last_is_rest_itself() {
        let run = Run { from: TAB_WAS, to: TAB_NOW, lift_scale: selection::LIFT_SCALE_WINDOW_TAB };
        let first = run.frame(0.0);
        assert_eq!(first, Frame { chip: TAB_WAS, lift: 0.0, last: false });
        // Not nearly at rest: at rest. When the redrawing stops, nothing
        // may be left a pixel off.
        let last = run.frame(duration());
        assert_eq!(last, Frame { chip: TAB_NOW, lift: 0.0, last: true });
    }

    #[test]
    fn a_slide_says_it_is_over_once_and_for_good() {
        // What stops the timer: a host redraws while `last` is false and
        // kills its timer the first time it is true.
        let run = Run { from: TAB_WAS, to: TAB_NOW, lift_scale: selection::LIFT_SCALE_WINDOW_TAB };
        let mut t = 0.0;
        let mut frames = 0;
        while !run.frame(t).last {
            frames += 1;
            t += 0.016;
            assert!(frames < 1000, "the slide never ends");
        }
        // A 16 ms timer draws it in about 26 frames.
        assert!((20..=32).contains(&frames), "{frames}");
        for later in [t, t + 0.016, t + 1.0, t + 3600.0] {
            assert_eq!(run.frame(later), Frame { chip: TAB_NOW, lift: 0.0, last: true });
        }
    }

    #[test]
    fn a_row_slides_down_the_list_and_changes_height_on_the_way() {
        let was = Rect { x: 6.0, y: 38.0, w: 368.0, h: 100.0 };
        let now = Rect { x: 6.0, y: 146.0, w: 368.0, h: 80.0 };
        let run = Run { from: was, to: now, lift_scale: selection::LIFT_SCALE_ROW };
        let mid = run.frame(lands_at());
        assert!(!mid.last);
        assert_eq!(mid.lift, 1.0);
        // On the way: below where it was, above where it will be.
        let centre = mid.chip.y + mid.chip.h / 2.0;
        assert!(centre > 88.0 && centre < 186.0, "{centre}");
        // It keeps to its column: a move down does not push it sideways.
        assert!((mid.chip.x + mid.chip.w / 2.0 - 190.0).abs() < 1e-9);
        // Between the two heights, and a little more for being in the air.
        assert!(mid.chip.h > 80.0 && mid.chip.h < 100.0 * (1.0 + selection::LIFT_SCALE_ROW) * (1.0 + selection::STRETCH_ALONG));
        // Lifted, it is wider than the row by the lift less the squeeze.
        assert!(mid.chip.w > 368.0 * (1.0 + selection::LIFT_SCALE_ROW) * (1.0 - selection::SQUEEZE_ACROSS) - 1e-9);
        assert!(mid.chip.w <= 368.0 * (1.0 + selection::LIFT_SCALE_ROW));
    }
}
