//! Where the box somebody types a text into goes, and how big it is.
//!
//! Specification §9.3. The box is an opaque sheet over the picture, and it
//! is a window of its own: whatever it covers cannot be seen or clicked. It
//! was once four lines tall whatever was in it and stopped only at the
//! bottom of the monitor, so at the largest size, opened low in the
//! selection, it lay over the toolbar and the colour row -- which are how
//! the text being typed is given another colour (task 1104).
//!
//! The rules, the same on both hosts:
//!
//!  * **As tall as what is in it**: one line to begin with, a line more for
//!    each line break. `line` is the height of one line in the font the
//!    host draws with, which the host measures; this file never guesses it.
//!  * **Inside the selection**: a new text starts no lower than one line
//!    above the selection's bottom edge ([`origin`]), and its box stops
//!    growing there ([`rect`]). What is typed past that scrolls in the box.
//!  * **Clear of the toolbar**: the box ends above any toolbar rectangle it
//!    would otherwise reach. Where one line cannot avoid it -- a text
//!    opened for editing again that already sits there -- the host gives a
//!    press on the toolbar to the toolbar ([`on_toolbar`]).

use crate::geom::{Point, Rect};
use crate::style;

/// The narrowest a box is, in ems of the font: room to see a few
/// characters before the box scrolls sideways.
pub const MIN_EMS: i32 = 4;
/// And never narrower than this many points, for the smallest sizes.
pub const MIN_WIDTH: u32 = 40;

/// The narrowest box for a font `font_px` pixels tall.
pub fn min_width(font_px: i32, scale: f64) -> i32 {
    (font_px * MIN_EMS).max(style::px(MIN_WIDTH, scale))
}

/// How many lines `text` is: one, and one more for each line break.
pub fn lines(text: &str) -> i32 {
    1 + text.matches('\n').count() as i32
}

fn overlaps_across(r: Rect, x: i32, w: i32) -> bool {
    r.x < x + w && r.right() > x
}

/// Where a new text starts for a press at `click` inside `selection`: the
/// press itself, pulled up and to the left just far enough that one line
/// `line` tall and `min_w` wide is inside the selection and above any of
/// `keep_clear` that lies inside it (the toolbar, when the selection is as
/// tall as the monitor and the toolbar has nowhere else to go).
///
/// A selection smaller than one line, or narrower than `min_w`, cannot hold
/// the box: the text then starts at the selection's own top or left edge.
pub fn origin(click: Point, line: i32, min_w: i32, selection: Rect, keep_clear: &[Rect]) -> Point {
    let mut bottom = selection.bottom();
    for r in keep_clear {
        let inside = r.y > selection.y && r.y < selection.bottom() && overlaps_across(*r, selection.x, selection.w);
        if inside {
            bottom = bottom.min(r.y);
        }
    }
    let y = click.y.min(bottom - line).max(selection.y);
    let x = click.x.min(selection.right() - min_w).max(selection.x);
    Point::new(x, y)
}

/// The box for a text at `at` holding `lines` lines of height `line`.
///
/// Its width runs to the selection's right edge, and is at least `min_w`
/// (stopped at the monitor's edge). Its height is a whole number of lines:
/// as many as the text has, but no more than fit above the selection's
/// bottom edge -- or the monitor's, for a text that is not in the selection
/// at all -- and above the top of any of `keep_clear` below it. Never less
/// than one line: what is being typed has to be seen.
pub fn rect(at: Point, lines: i32, line: i32, min_w: i32, selection: Rect, monitor: Rect, keep_clear: &[Rect]) -> Rect {
    let line = line.max(1);
    let w = (selection.right() - at.x).max(min_w).min(monitor.right() - at.x).max(1);
    let in_selection = at.y >= selection.y && at.y < selection.bottom();
    let mut limit = if in_selection { selection.bottom() } else { monitor.bottom() };
    for r in keep_clear {
        // Below the text's first row, or holding it: one that holds it
        // leaves no room at all, and the one line is all there is.
        if r.bottom() > at.y && overlaps_across(*r, at.x, w) {
            limit = limit.min(r.y);
        }
    }
    let fit = ((limit - at.y) / line).max(1);
    Rect::new(at.x, at.y, w, lines.clamp(1, fit) * line)
}

/// Whether a press at `p` is the toolbar's even though the box is there:
/// the toolbar is asked first, always.
pub fn on_toolbar(p: Point, keep_clear: &[Rect]) -> bool {
    keep_clear.iter().any(|r| r.contains(p))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::style::{Props, FONTS, LEVELS};
    use crate::toolbar;

    /// A line of the annotation font is taller than its size; the hosts
    /// measure it. This is near what Noto Sans SC gives and is only a
    /// stand-in: nothing here depends on the ratio.
    fn line_of(font_px: i32) -> i32 {
        (font_px * 29 + 19) / 20
    }

    fn bars(selection: Rect, monitor: Rect, scale: f64) -> Vec<Rect> {
        let l = toolbar::layout(selection, monitor, scale, Props::Font);
        let mut out = vec![l.bar];
        out.extend(l.props);
        out
    }

    fn within(inner: Rect, outer: Rect) -> bool {
        inner.x >= outer.x && inner.y >= outer.y && inner.right() <= outer.right() && inner.bottom() <= outer.bottom()
    }

    /// The reading the test machine brought back (task 1104): a 900x500
    /// selection at 144 DPI, the largest size, opened at (1450,650).
    #[test]
    fn the_box_the_test_machine_measured_no_longer_reaches_the_toolbar() {
        let (scale, monitor) = (1.5, Rect::new(0, 0, 2560, 1600));
        let selection = Rect::from_ltrb(1350, 300, 2250, 800);
        let keep = bars(selection, monitor, scale);
        let font = style::font_px(4, scale);
        assert_eq!(font, 66);
        // What it was: four lines whatever was typed, 264 px, to y = 914,
        // over a toolbar that starts under the selection at 812.
        assert_eq!(keep[0].y, 812);
        assert!(650 + font * 4 > keep[0].y);

        let line = line_of(font);
        let at = origin(Point::new(1450, 650), line, min_width(font, scale), selection, &keep);
        assert_eq!(at, Point::new(1450, 650), "there is room: the text starts where it was pressed");
        let one = rect(at, 1, line, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(one, Rect::new(1450, 650, 800, line));
        // It grows a line at a time and stops at the selection's bottom.
        let two = rect(at, 2, line, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(two.h, (2 * line).min((800 - 650) / line * line));
        let many = rect(at, 40, line, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(many.h, (800 - 650) / line * line);
        assert!(many.bottom() <= selection.bottom());
        for r in &keep {
            assert_eq!(many.intersect(*r), None);
        }
    }

    #[test]
    fn at_every_size_and_scale_the_box_is_in_the_selection_whole_lines_tall_and_off_the_toolbar() {
        for scale in [1.0, 1.5, 2.0] {
            let monitor = Rect::new(0, 0, 2560, 1600);
            // Under it, over it (no room under), and inside its bottom edge
            // (as tall as the monitor): the three places a toolbar goes.
            for selection in [Rect::from_ltrb(400, 300, 1300, 800), Rect::from_ltrb(400, 900, 1300, 1590), Rect::from_ltrb(400, 0, 1300, 1600)] {
                let keep = bars(selection, monitor, scale);
                for level in 0..LEVELS {
                    let font = style::font_px(level, scale);
                    let (line, min_w) = (line_of(font), min_width(font, scale));
                    // Pressed at the top, in the middle, and on the last
                    // pixel row; and at the left, and on the last column.
                    for click_y in [selection.y, selection.y + selection.h / 2, selection.bottom() - 1] {
                        for click_x in [selection.x, selection.x + selection.w / 2, selection.right() - 1] {
                            let click = Point::new(click_x, click_y);
                            if on_toolbar(click, &keep) {
                                // That press is the toolbar's, not a text.
                                continue;
                            }
                            let at = origin(click, line, min_w, selection, &keep);
                            for typed in [1, 2, 3, 50] {
                                let b = rect(at, typed, line, min_w, selection, monitor, &keep);
                                let what = format!("scale {scale} selection {selection:?} level {level} click {click:?} lines {typed}: {b:?}");
                                assert!(within(b, selection), "{what}");
                                assert_eq!(b.h % line, 0, "{what}");
                                assert!(b.h >= line && b.h <= typed * line, "{what}");
                                assert!(b.w >= min_w, "{what}");
                                for r in &keep {
                                    assert_eq!(b.intersect(*r), None, "{what} meets {r:?}");
                                }
                                // One line where it was pressed, when it fits there.
                                if typed == 1 && click.y + line <= selection.bottom() && !keep.iter().any(|r| r.y > click.y && r.y < click.y + line) {
                                    assert_eq!(at.y, click.y, "{what}");
                                    assert_eq!(b.h, line, "{what}");
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_new_text_is_pulled_only_as_far_as_one_line_needs() {
        let selection = Rect::from_ltrb(100, 100, 700, 500);
        // Room: where it was pressed.
        assert_eq!(origin(Point::new(300, 200), 30, 120, selection, &[]), Point::new(300, 200));
        // On the bottom row: up by a line, less the row it was on.
        assert_eq!(origin(Point::new(300, 499), 30, 120, selection, &[]), Point::new(300, 470));
        assert_eq!(origin(Point::new(300, 470), 30, 120, selection, &[]), Point::new(300, 470));
        assert_eq!(origin(Point::new(300, 471), 30, 120, selection, &[]), Point::new(300, 470));
        // On the last column: left until the narrowest box fits.
        assert_eq!(origin(Point::new(699, 200), 30, 120, selection, &[]), Point::new(580, 200));
        // A toolbar inside the selection's bottom edge is the floor instead.
        let bar = Rect::new(300, 440, 400, 50);
        assert_eq!(origin(Point::new(350, 430), 30, 120, selection, &[bar]), Point::new(350, 410));
        // One outside it is not: the selection's edge already keeps clear.
        let under = Rect::new(300, 508, 400, 50);
        assert_eq!(origin(Point::new(350, 499), 30, 120, selection, &[under]), Point::new(350, 470));
        // A selection that cannot hold a line: its own corner.
        let thin = Rect::from_ltrb(100, 100, 150, 110);
        assert_eq!(origin(Point::new(140, 105), 30, 120, thin, &[]), Point::new(100, 100));
    }

    #[test]
    fn a_text_edited_again_outside_the_selection_stops_at_the_toolbar_or_the_monitor() {
        let monitor = Rect::new(0, 0, 1920, 1080);
        let selection = Rect::from_ltrb(100, 100, 700, 500);
        // Left behind above the selection when it was moved: the selection
        // is not its floor, the monitor is.
        let above = rect(Point::new(200, 20), 99, 30, 120, selection, monitor, &[]);
        assert_eq!((above.y, above.h), (20, (1080 - 20) / 30 * 30));
        // Beside the toolbar's top: it ends there.
        let bar = Rect::new(300, 508, 400, 40);
        let beside = rect(Point::new(350, 20), 99, 30, 120, selection, monitor, &[bar]);
        assert_eq!(beside.bottom(), 20 + (508 - 20) / 30 * 30);
        assert!(beside.bottom() <= bar.y);
        // A toolbar off to the side of the box is no floor.
        let aside = rect(Point::new(720, 20), 2, 30, 120, selection, monitor, &[Rect::new(900, 30, 100, 40)]);
        assert_eq!(aside.h, 60);
        // Sitting on the toolbar already: one line, and the press is the
        // toolbar's all the same.
        let on = rect(Point::new(350, 520), 3, 30, 120, selection, monitor, &[bar]);
        assert_eq!(on.h, 30);
        assert!(on_toolbar(Point::new(360, 525), &[bar]));
        assert!(!on_toolbar(Point::new(360, 560), &[bar]));
    }

    #[test]
    fn the_width_runs_to_the_selections_edge_and_is_never_too_narrow_to_type_in() {
        let monitor = Rect::new(0, 0, 1920, 1080);
        let selection = Rect::from_ltrb(100, 100, 700, 500);
        assert_eq!(rect(Point::new(300, 200), 1, 30, 120, selection, monitor, &[]).w, 400);
        // Past the selection's right edge (a text left there): the least.
        assert_eq!(rect(Point::new(690, 200), 1, 30, 120, selection, monitor, &[]).w, 120);
        // At the monitor's edge there is only what there is.
        assert_eq!(rect(Point::new(1900, 200), 1, 30, 120, selection, monitor, &[]).w, 20);
        for (level, points) in FONTS.iter().enumerate() {
            assert_eq!(min_width(style::font_px(level as u8, 1.0), 1.0), (*points as i32 * MIN_EMS).max(40));
        }
    }

    #[test]
    fn a_line_break_is_a_line() {
        assert_eq!(lines(""), 1);
        assert_eq!(lines("abc"), 1);
        assert_eq!(lines("a\nb"), 2);
        assert_eq!(lines("a\n"), 2);
        assert_eq!(lines("\n\n"), 3);
    }
}
