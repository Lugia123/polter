//! The little glass notice shown once the screenshot is over (#1197): that
//! the picture was saved to Downloads, that it could not be, that a long
//! screenshot ended because the page could not be followed.
//!
//! **A window of its own, not the overlay**: by then the overlay is gone,
//! and the notice must not take the keyboard from whatever the person goes
//! back to -- it is shown without being activated and takes itself away
//! after [`SHOW_MS`]. It is put in the bottom-right corner of the monitor
//! the screenshot was on: the selection is gone and was what the person was
//! looking at, and a corner is the one place a notice there cannot cover.
//! All the arithmetic is here; the host draws.

use crate::geom::Rect;
use crate::look::size;
use crate::style::px_f;

/// How long it stays, in milliseconds.
pub const SHOW_MS: u32 = 2400;
/// Its distance from the monitor's edges, in points.
pub const INSET: f64 = 24.0;
/// The widest it gets, in points; longer words go on a second line.
pub const MAX_WIDTH: f64 = 480.0;

/// `msgid` -- already translated -- with `{name}` replaced.
pub fn with_name(text: &str, name: &str) -> String {
    text.replace("{name}", name)
}

/// `text` broken into lines no wider than `max` by `measure` (the width of a
/// string in pixels): at a space when there is one in the line, else
/// between characters (Chinese has no spaces). Never an empty list.
pub fn wrap(text: &str, max: i32, measure: impl Fn(&str) -> i32) -> Vec<String> {
    let mut lines = Vec::new();
    let mut line = String::new();
    for ch in text.chars() {
        let mut next = line.clone();
        next.push(ch);
        if measure(&next) <= max || line.is_empty() {
            line = next;
            continue;
        }
        // Over: break at the last space in the line if it has one.
        match line.rfind(' ') {
            Some(i) if ch != ' ' => {
                lines.push(line[..i].to_string());
                line = format!("{}{ch}", line[i + 1..].to_string());
            }
            _ => {
                lines.push(std::mem::take(&mut line));
                if ch != ' ' {
                    line.push(ch);
                }
            }
        }
    }
    if !line.is_empty() || lines.is_empty() {
        lines.push(line);
    }
    lines
}

/// The plate for `lines` of text, each `(width, height)` by the host's
/// measure: the widest line and all their heights, with the padding of the
/// look's labels all round.
pub fn plate_size(lines: &[(i32, i32)], scale: f64) -> (i32, i32) {
    let (px, py) = (px_f(size::SIZE_LABEL_PAD_X, scale), px_f(size::SIZE_LABEL_PAD_Y, scale));
    let w = lines.iter().map(|l| l.0).max().unwrap_or(0);
    let h: i32 = lines.iter().map(|l| l.1).sum();
    (w + 2 * px, h + 2 * py)
}

/// Where the plate goes: the monitor's bottom-right corner, inset.
pub fn place(plate: (i32, i32), monitor: Rect, scale: f64) -> Rect {
    let inset = px_f(INSET, scale);
    let x = (monitor.right() - inset - plate.0).max(monitor.x);
    let y = (monitor.bottom() - inset - plate.1).max(monitor.y);
    Rect::new(x, y, plate.0, plate.1)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Ten pixels a character.
    fn ten(s: &str) -> i32 {
        s.chars().count() as i32 * 10
    }

    #[test]
    fn the_name_goes_in_where_the_word_for_it_is() {
        assert_eq!(with_name("Saved to Downloads: {name}", "a.png"), "Saved to Downloads: a.png");
        assert_eq!(with_name("已保存到「下载」：{name}", "a.png"), "已保存到「下载」：a.png");
        assert_eq!(with_name("Copied", "a.png"), "Copied");
    }

    #[test]
    fn a_short_text_is_one_line_and_a_long_one_breaks_at_a_space() {
        assert_eq!(wrap("Copied", 100, ten), ["Copied"]);
        assert_eq!(wrap("aaa bbb ccc", 70, ten), ["aaa bbb", "ccc"]);
        assert_eq!(wrap("aaa bbb ccc ddd", 70, ten), ["aaa bbb", "ccc ddd"]);
        assert_eq!(wrap("", 70, ten), [""], "never none");
    }

    #[test]
    fn what_has_no_spaces_breaks_between_characters_and_a_long_word_is_cut() {
        assert_eq!(wrap("一二三四五六", 30, ten), ["一二三", "四五六"]);
        assert_eq!(wrap("abcdefghij", 40, ten), ["abcd", "efgh", "ij"]);
        // Nothing is lost by breaking: the lines, joined, are the text.
        let text = "The page could not be followed any further, so the picture ends here.";
        let lines = wrap(text, 200, ten);
        assert!(lines.iter().all(|l| ten(l) <= 200), "{lines:?}");
        assert_eq!(lines.join(" "), text);
    }

    #[test]
    fn the_plate_is_the_widest_line_and_all_the_heights_with_padding() {
        assert_eq!(plate_size(&[(100, 16), (60, 16)], 1.0), (100 + 16, 32 + 10));
        assert_eq!(plate_size(&[(100, 32)], 2.0), (100 + 32, 32 + 20));
    }

    #[test]
    fn it_sits_in_the_bottom_right_corner_and_stays_on_the_monitor() {
        let mon = Rect::new(1920, 0, 1920, 1080);
        assert_eq!(place((300, 40), mon, 1.0), Rect::new(3840 - 24 - 300, 1080 - 24 - 40, 300, 40));
        assert_eq!(place((300, 40), mon, 2.0), Rect::new(3840 - 48 - 300, 1080 - 48 - 40, 300, 40));
        let small = Rect::new(0, 0, 200, 100);
        let r = place((300, 40), small, 1.0);
        assert!(r.x >= 0 && r.y >= 0, "a plate wider than the monitor starts at its edge");
    }
}
