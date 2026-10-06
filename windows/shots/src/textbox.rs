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

/// The parts of the box at `rect` that lie on the toolbar: what the host
/// takes out of the box, so that the toolbar is what is pressed there and
/// what is seen there. Empty for every box [`rect`] could keep clear.
pub fn covered(rect: Rect, keep_clear: &[Rect]) -> Vec<Rect> {
    keep_clear.iter().filter_map(|r| rect.intersect(*r)).collect()
}

/// Of the parts taken out of the box ([`covered`]), the ones the toolbar
/// has to be drawn back into after the box draws: all of them if the system
/// says the box can still draw there, none if it cannot.
///
/// None is the expected answer. Taking them out of a plain `EDIT` was not
/// enough to see the toolbar (task 1107: the press went through and the
/// box's paper stayed), because that class draws through its parent's
/// clipping; the host's box is of a class that does not.
pub fn to_draw_back(covered: Vec<Rect>, box_draws_there: bool) -> Vec<Rect> {
    if box_draws_there {
        covered
    } else {
        Vec::new()
    }
}

/// Whether window message `msg` is one the text box draws by, so that a box
/// which can draw on the toolbar ([`to_draw_back`]) has the overlay painted
/// there again after it. `left_down`: the left button is held, which is what
/// makes a mouse move a selection being dragged.
///
/// **A list of the messages that draw, not everything but a list of those
/// that do not.** It was the second, with seven questions excepted, and
/// drawing the toolbar back was itself a source of messages to the box that
/// were not among the seven (showing and hiding the caret is announced to
/// whoever listens, and a listener answers by asking the window for its
/// object): the window thread drew, was asked, drew again, and never read
/// its queue (package 31c90b552). A message missing from this list costs
/// the box's paper on the toolbar until the overlay next paints; one too
/// many on the other kind of list cost the program.
///
/// Nothing the overlay's painting sends or causes may be here. The test
/// below names those.
pub fn box_draws(msg: u32, left_down: bool) -> bool {
    match msg {
        WM_MOUSEMOVE => left_down,
        _ => DRAWS.contains(&msg),
    }
}

const WM_MOUSEMOVE: u32 = 0x0200;
/// `WM_SETFOCUS`, `WM_PAINT`, `WM_SETFONT`; `EM_SETSEL`, `EM_LINESCROLL`,
/// `EM_REPLACESEL`; `WM_KEYDOWN`, `WM_CHAR`, `WM_IME_ENDCOMPOSITION`,
/// `WM_IME_COMPOSITION`; the left button down, up and twice, the wheel;
/// `WM_CUT`, `WM_PASTE`, `WM_CLEAR`, `WM_UNDO`.
const DRAWS: [u32; 18] = [
    0x0007, 0x000F, 0x0030, 0x00B1, 0x00B6, 0x00C2, 0x0100, 0x0102, 0x010E, 0x010F, 0x0201, 0x0202, 0x0203, 0x020A, 0x0300,
    0x0302, 0x0303, 0x0304,
];

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

    /// The reading the test machine brought back (task 1107): a text typed
    /// at the largest size on the selection's bottom row, the selection's
    /// bottom edge then dragged from 800 to 720, the text opened again. Its
    /// box was 800x96 at (1450,704) and these four points on the toolbar's
    /// first row were the box's white paper.
    #[test]
    fn the_box_the_test_machine_measured_covers_the_toolbar_where_it_read_white() {
        let (scale, monitor) = (1.5, Rect::new(0, 0, 2560, 1600));
        let selection = Rect::from_ltrb(1350, 300, 2250, 720);
        let keep = bars(selection, monitor, scale);
        let read_white = [Point::new(1560, 762), Point::new(2220, 762), Point::new(2000, 745), Point::new(2000, 790)];

        let font = style::font_px(4, scale);
        let at = Point::new(1450, 704);
        let large = rect(at, 1, 96, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(large, Rect::new(1450, 704, 800, 96), "the box the log gave");
        let parts = covered(large, &keep);
        // Both rows: the log's `2 part(s)`.
        assert_eq!(parts.len(), 2);
        for p in read_white {
            assert!(parts.iter().any(|r| r.contains(p)), "{p:?} is not in {parts:?}");
        }
        // Every part is the box's and the toolbar's both, and nothing of
        // the box that is on the toolbar is left out.
        for r in &parts {
            assert!(within(*r, large) && keep.iter().any(|k| within(*r, *k)), "{r:?}");
        }
        let on_both: i64 = keep.iter().filter_map(|k| large.intersect(*k)).map(|r| r.w as i64 * r.h as i64).sum();
        assert_eq!(parts.iter().map(|r| r.w as i64 * r.h as i64).sum::<i64>(), on_both);
        assert!(on_both > 0);
        // The colour row "could be seen": the box reaches two pixel rows of it.
        assert_eq!(parts[1].h, large.bottom() - keep[1].y);
        assert!(parts[1].h < 4);

        // The third size, 39 px a line: "the toolbar was drawn again". One
        // part is still under the box -- and none of the four points is.
        let small = rect(at, 1, 39, min_width(style::font_px(2, scale), scale), selection, monitor, &keep);
        assert_eq!(small, Rect::new(1450, 704, 800, 39));
        let parts = covered(small, &keep);
        assert_eq!(parts.len(), 1);
        assert_eq!((parts[0].y, parts[0].bottom()), (keep[0].y, small.bottom()));
        for p in read_white {
            assert!(!small.contains(p), "{p:?}");
        }

        // A box that keeps clear has nothing to give back.
        assert!(covered(Rect::new(1450, 600, 800, 96), &keep).is_empty());
        assert!(covered(large, &[]).is_empty());
    }

    #[test]
    fn nothing_is_drawn_back_into_a_box_that_cannot_draw_on_the_toolbar() {
        let holes = vec![Rect::new(1450, 730, 800, 40), Rect::new(1450, 776, 800, 24)];
        // The system honours the cut: nothing to do, for any box.
        assert!(to_draw_back(holes.clone(), false).is_empty());
        // It does not: every part, as it was.
        assert_eq!(to_draw_back(holes.clone(), true), holes);
        // No part on the toolbar is nothing either way.
        assert!(to_draw_back(Vec::new(), true).is_empty());
    }

    /// The overlay paints the toolbar again after the box handles one of
    /// these. What that painting sends to the box, or has others send, must
    /// never be one of them: that is a loop, and it stopped the window
    /// thread once.
    #[test]
    fn what_painting_the_toolbar_again_sends_the_box_does_not_ask_for_another_painting() {
        // WM_GETOBJECT: what a listener sends on hearing the caret was
        // hidden or shown, which painting there does.
        assert!(!box_draws(0x003D, false));
        // The caret's own timer.
        assert!(!box_draws(0x0118, false));
        // What the system asks of a window under the pointer, and what
        // `fit_edit` and closing the box ask of it.
        for asked in [0x0084, 0x0020, 0x000D, 0x000E, 0x0087, 0x00BA, 0x00CE] {
            assert!(!box_draws(asked, false), "{asked:#06x}");
        }
        // Being cut, moved, and ended: `keep_toolbar_clear` and `commit_edit`.
        for told in [0x0046, 0x0047, 0x0083, 0x0085, 0x0014, 0x0003, 0x0005, 0x0008, 0x0002, 0x0082] {
            assert!(!box_draws(told, false), "{told:#06x}");
        }
        // A pointer passing over is not a selection being dragged.
        assert!(!box_draws(WM_MOUSEMOVE, false));
        assert!(box_draws(WM_MOUSEMOVE, true));
        // A held button changes nothing else.
        assert!(!box_draws(0x003D, true));

        // And it is a list: the ones named and no other, of every message
        // number there is below the application's own.
        let named: Vec<u32> = (0..0x0400).filter(|m| box_draws(*m, false)).collect();
        assert_eq!(named, DRAWS);
        for typed in [0x000F, 0x0100, 0x0102, 0x010F] {
            assert!(box_draws(typed, false), "{typed:#06x}");
        }
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
