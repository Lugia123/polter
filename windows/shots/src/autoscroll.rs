//! The program scrolls a long screenshot for the person (#1197).
//!
//! The person chooses the region and presses "Long Screenshot"; from then
//! on the program turns the wheel over the region, a notch at a time, takes
//! a frame after each, and stops when the page stops moving. The rules are
//! the ones macOS uses: four notches with nothing moving is the bottom, four
//! that cannot be followed is a page that cannot be joined, and the height limit is the
//! limit. **Nothing here touches the screen**: the host asks, after every
//! frame, what to do next, and does it.

use crate::geom::{Point, Rect};
use crate::stitch::Step;

/// How long a notch is given to start moving before a frame that shows
/// nothing is taken to mean "nothing moved": the page may be slow to begin.
pub const SETTLE_MS: u64 = 150;
/// Notches in a row that moved nothing: the bottom (macOS's number).
pub const STILL_LIMIT: u32 = 4;
/// Notches in a row whose frame could not be joined: give up, keep what is joined.
pub const BLIND_LIMIT: u32 = 4;

/// The person's pointer, which a long screenshot takes over the region for
/// the wheel and has to give back **however it ends** (task 1200: it went
/// back on Enter and not on Esc, because the giving back hung on one exit).
///
/// The giving back is done by `release`, once, and by `Drop` if nobody
/// called it, so an exit that was never written is still an exit that
/// gives it back: Esc, the bottom, the height limit, a page that cannot be
/// followed, the frozen picture closed, the session going away. `restore`
/// is what moves the pointer (the host's `SetCursorPos`).
pub struct PointerGuard<F: FnMut(Point)> {
    was: Option<Point>,
    restore: F,
}

impl<F: FnMut(Point)> PointerGuard<F> {
    /// `was`: where the pointer was, if that could be read.
    pub fn new(was: Option<Point>, restore: F) -> PointerGuard<F> {
        PointerGuard { was, restore }
    }

    /// Give the pointer back now. A second call, and the drop after it, do nothing.
    pub fn release(&mut self) {
        if let Some(p) = self.was.take() {
            (self.restore)(p);
        }
    }
}

impl<F: FnMut(Point)> Drop for PointerGuard<F> {
    fn drop(&mut self) {
        self.release();
    }
}

/// Why it stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stopped {
    Bottom,
    Limit,
    /// The page moves in a way that cannot be followed.
    Lost,
}

/// What to do after a frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Nothing yet: the page is still moving or the notch is still being given its time.
    Wait,
    /// Turn the wheel one notch ([`AutoScroll::turned`] after doing so).
    Wheel,
    /// That is all of it: finish with what is joined.
    Stop(Stopped),
}

#[derive(Clone, Debug, Default)]
pub struct AutoScroll {
    turned_at: Option<u64>,
    still: u32,
    blind: u32,
}

impl AutoScroll {
    pub fn new() -> AutoScroll {
        AutoScroll::default()
    }

    /// The host turned the wheel at time `now` (milliseconds, any clock
    /// that does not go back).
    pub fn turned(&mut self, now: u64) {
        self.turned_at = Some(now);
    }

    /// Whether the last notch has had its time.
    fn settled(&self, now: u64) -> bool {
        self.turned_at.is_none_or(|t| now.saturating_sub(t) >= SETTLE_MS)
    }

    /// What the frame just offered to the stitcher turned out to be, and
    /// what to do about it.
    pub fn after_frame(&mut self, step: Step, now: u64) -> Verdict {
        match step {
            // The picture is still changing, or is not this session's: look again.
            Step::Moving | Step::WrongSize => Verdict::Wait,
            Step::Full => Verdict::Stop(Stopped::Limit),
            // Moved: the next notch at once, the page has shown it can scroll.
            Step::Added(_) | Step::Seen | Step::Back => {
                self.still = 0;
                self.blind = 0;
                Verdict::Wheel
            }
            // The first frame, steady: begin.
            Step::First => Verdict::Wheel,
            Step::Unchanged | Step::Lost if self.turned_at.is_none() => Verdict::Wheel,
            Step::Unchanged | Step::Lost if !self.settled(now) => Verdict::Wait,
            Step::Unchanged => {
                self.still += 1;
                if self.still >= STILL_LIMIT {
                    Verdict::Stop(Stopped::Bottom)
                } else {
                    Verdict::Wheel
                }
            }
            Step::Lost => {
                self.blind += 1;
                if self.blind >= BLIND_LIMIT {
                    Verdict::Stop(Stopped::Lost)
                } else {
                    Verdict::Wheel
                }
            }
        }
    }
}

/// Where the pointer goes so the wheel reaches the page: the middle of the
/// region -- or, if the toolbar lies over the middle, the middle of the part
/// of the region above it, else below it.
pub fn wheel_point(region: Rect, bar: Option<Rect>) -> Point {
    let middle = Point::new(region.x + region.w / 2, region.y + region.h / 2);
    let Some(bar) = bar.filter(|b| b.contains(middle)) else { return middle };
    let above = bar.y - region.y;
    let below = region.bottom() - bar.bottom();
    if above >= below {
        Point::new(middle.x, region.y + above / 2)
    } else {
        Point::new(middle.x, bar.bottom() + below / 2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(a: &mut AutoScroll, now: u64) -> Verdict {
        a.turned(now);
        Verdict::Wheel
    }

    #[test]
    fn it_begins_on_the_first_steady_frame_and_goes_on_while_the_page_moves() {
        let mut a = AutoScroll::new();
        assert_eq!(a.after_frame(Step::Moving, 0), Verdict::Wait);
        assert_eq!(a.after_frame(Step::First, 10), Verdict::Wheel);
        turn(&mut a, 10);
        assert_eq!(a.after_frame(Step::Moving, 130), Verdict::Wait, "mid-scroll");
        assert_eq!(a.after_frame(Step::Added(300), 250), Verdict::Wheel);
    }

    #[test]
    fn four_notches_that_move_nothing_are_the_bottom_and_each_has_its_time() {
        let mut a = AutoScroll::new();
        a.after_frame(Step::First, 0);
        turn(&mut a, 0);
        // A frame right after the notch, before the page began: not counted.
        assert_eq!(a.after_frame(Step::Unchanged, 50), Verdict::Wait);
        assert_eq!(a.after_frame(Step::Unchanged, 200), Verdict::Wheel);
        turn(&mut a, 200);
        assert_eq!(a.after_frame(Step::Unchanged, 250), Verdict::Wait);
        assert_eq!(a.after_frame(Step::Unchanged, 400), Verdict::Wheel);
        turn(&mut a, 400);
        assert_eq!(a.after_frame(Step::Unchanged, 560), Verdict::Wheel);
        turn(&mut a, 560);
        assert_eq!(a.after_frame(Step::Unchanged, 720), Verdict::Stop(Stopped::Bottom), "the fourth");
    }

    #[test]
    fn a_page_that_moves_again_starts_the_count_over() {
        let mut a = AutoScroll::new();
        a.after_frame(Step::First, 0);
        turn(&mut a, 0);
        assert_eq!(a.after_frame(Step::Unchanged, 200), Verdict::Wheel);
        turn(&mut a, 200);
        assert_eq!(a.after_frame(Step::Unchanged, 400), Verdict::Wheel);
        turn(&mut a, 400);
        assert_eq!(a.after_frame(Step::Added(100), 600), Verdict::Wheel);
        turn(&mut a, 600);
        assert_eq!(a.after_frame(Step::Unchanged, 800), Verdict::Wheel, "the third in all, the first since");
        turn(&mut a, 800);
        assert_eq!(a.after_frame(Step::Unchanged, 1000), Verdict::Wheel);
        turn(&mut a, 1000);
        assert_eq!(a.after_frame(Step::Unchanged, 1200), Verdict::Wheel, "three since: not yet");
    }

    #[test]
    fn the_limit_and_a_page_that_cannot_be_followed_end_it_with_what_is_joined() {
        let mut a = AutoScroll::new();
        a.after_frame(Step::First, 0);
        assert_eq!(a.after_frame(Step::Full, 10), Verdict::Stop(Stopped::Limit));
        let mut a = AutoScroll::new();
        a.after_frame(Step::First, 0);
        turn(&mut a, 0);
        for i in 1..BLIND_LIMIT as u64 {
            assert_eq!(a.after_frame(Step::Lost, i * 200), Verdict::Wheel);
            turn(&mut a, i * 200);
        }
        assert_eq!(a.after_frame(Step::Lost, BLIND_LIMIT as u64 * 200), Verdict::Stop(Stopped::Lost));
    }

    #[test]
    fn the_pointer_goes_to_the_middle_of_the_region_and_off_the_toolbar() {
        let region = Rect::new(100, 100, 800, 600);
        assert_eq!(wheel_point(region, None), Point::new(500, 400));
        assert_eq!(wheel_point(region, Some(Rect::new(0, 900, 1000, 80))), Point::new(500, 400), "toolbar elsewhere");
        // The toolbar over the middle, near the bottom: the part above it.
        let bar = Rect::new(300, 380, 400, 320);
        let p = wheel_point(region, Some(bar));
        assert!(region.contains(p) && !bar.contains(p), "{p:?}");
        // Over the top part: below.
        let bar = Rect::new(300, 100, 400, 320);
        let p = wheel_point(region, Some(bar));
        assert!(region.contains(p) && !bar.contains(p), "{p:?}");
    }

    #[test]
    fn the_pointer_is_given_back_once_on_every_way_out() {
        use std::cell::RefCell;
        let moves = RefCell::new(Vec::new());
        let guard = || PointerGuard::new(Some(Point::new(7, 9)), |p| moves.borrow_mut().push(p));
        // Dropped without a word: Esc, a session that goes away, any exit
        // nobody wrote a line for.
        drop(guard());
        assert_eq!(moves.borrow().len(), 1, "dropped");
        // Released, as the finish and the leaving do, and then dropped.
        let mut g = guard();
        g.release();
        assert_eq!(moves.borrow().len(), 2, "released");
        g.release();
        drop(g);
        assert_eq!(moves.borrow().len(), 2, "once, however many ways it is asked");
        assert!(moves.borrow().iter().all(|p| *p == Point::new(7, 9)));
        // A pointer that could not be read is not moved anywhere.
        drop(PointerGuard::new(None, |p| moves.borrow_mut().push(p)));
        assert_eq!(moves.borrow().len(), 2);
    }
}
