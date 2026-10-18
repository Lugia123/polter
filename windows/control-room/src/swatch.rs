//! The colours in a pane's right-click menu: two rows of five dots, each
//! row one item of the menu, a dot picked with one click (task 1700). The
//! user, 2026-10-18: the colours stay laid out flat in the menu as macOS
//! has them, not behind a submenu, because it is something done often.
//!
//! **A Win32 menu has no row of choices.** One item is one command, so the
//! host draws each row itself and works out which dot a click or a key
//! meant from where the row is. That working out is here, where it can be
//! tested off Windows; the host only draws and hooks the menu's messages.
//!
//! In whole device pixels, like [`crate::tabstrip`].

use crate::layout::Rect;

/// How many dots a row holds. The palette is ten -- none and nine colours --
/// in two rows, the shape macOS's menu has.
pub const PER_ROW: usize = 5;

/// The row's own numbers, until the look table carries them.
pub mod size {
    /// A dot across, in points: a little bigger than the tab's, since this
    /// one is aimed at.
    pub const DOT: f64 = 16.0;
    /// From one dot's left edge to the next one's.
    pub const PITCH: f64 = 22.0;
    /// Above and below the dots, inside the item.
    pub const PAD_Y: f64 = 3.0;
}

/// How high a row's item is at `scale`: what the host answers
/// `WM_MEASUREITEM` with.
pub fn item_height(scale: f64) -> f64 {
    (size::DOT * scale).round() + 2.0 * (size::PAD_Y * scale).round()
}

/// How wide the dots of a row are, from the first one's left edge.
pub fn row_width(scale: f64) -> f64 {
    (size::PITCH * scale).round() * (PER_ROW as f64 - 1.0) + (size::DOT * scale).round()
}

/// Where the dots of a row whose item is `item` go, the first one's left
/// edge at `left` -- the host passes where the menu's words start, so the
/// dots line up under them.
pub fn dots(item: Rect, left: f64, scale: f64) -> [Rect; PER_ROW] {
    let d = (size::DOT * scale).round();
    let pitch = (size::PITCH * scale).round();
    let y = item.y + ((item.h - d) / 2.0).floor();
    std::array::from_fn(|i| Rect { x: (left + i as f64 * pitch).round(), y, w: d, h: d })
}

/// Which dot of the row a point in it is: the one whose column it is in,
/// a column being the dot and half the gap on either side, so that a click
/// between two dots goes to the nearer and none goes nowhere. Left of the
/// first column or right of the last, none.
pub fn hit(item: Rect, left: f64, scale: f64, x: f64) -> Option<usize> {
    let ds = dots(item, left, scale);
    let half_gap = ((size::PITCH - size::DOT) * scale / 2.0).floor();
    let first = ds[0].x - half_gap;
    let last = ds[PER_ROW - 1].x + ds[PER_ROW - 1].w + half_gap;
    if x < first || x >= last {
        return None;
    }
    let pitch = (size::PITCH * scale).round();
    Some((((x - first) / pitch).floor() as usize).min(PER_ROW - 1))
}

/// A key pressed while a row is the menu's current item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Left,
    Right,
}

/// Which dot is current after `key`, from `at`: one along, and no further
/// than either end -- the row does not wrap, so holding a key ends on the
/// end dot rather than going round.
pub fn step(at: usize, key: Key) -> usize {
    match key {
        Key::Left => at.saturating_sub(1),
        Key::Right => (at + 1).min(PER_ROW - 1),
    }
}

/// The colour a dot of the palette is, as an index into its ten: row `row`
/// (0 or 1), dot `at`.
pub fn index(row: usize, at: usize) -> usize {
    row * PER_ROW + at.min(PER_ROW - 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCALES: [f64; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];

    fn item(scale: f64) -> Rect {
        Rect { x: 0.0, y: 40.0 * scale, w: 260.0 * scale, h: item_height(scale) }
    }

    #[test]
    fn every_dot_is_hit_at_its_middle_and_its_edges() {
        for scale in SCALES {
            let left = (28.0 * scale).round();
            for (i, d) in dots(item(scale), left, scale).iter().enumerate() {
                for x in [d.x, d.x + d.w / 2.0, d.x + d.w - 1.0] {
                    assert_eq!(hit(item(scale), left, scale, x), Some(i), "x={x} at {scale}");
                }
            }
        }
    }

    #[test]
    fn between_two_dots_goes_to_the_nearer_and_outside_the_row_to_none() {
        for scale in SCALES {
            let left = (28.0 * scale).round();
            let ds = dots(item(scale), left, scale);
            for i in 0..PER_ROW - 1 {
                let (a, b) = (ds[i], ds[i + 1]);
                let gap = b.x - (a.x + a.w);
                assert_eq!(hit(item(scale), left, scale, a.x + a.w), Some(i), "just right of {i} at {scale}");
                assert_eq!(hit(item(scale), left, scale, b.x - 1.0), Some(i + 1), "just left of {} at {scale}", i + 1);
                assert!(gap >= 1.0);
            }
            assert_eq!(hit(item(scale), left, scale, 0.0), None, "the menu's own margin at {scale}");
            assert_eq!(hit(item(scale), left, scale, item(scale).w - 1.0), None, "past the last at {scale}");
        }
    }

    #[test]
    fn the_dots_are_whole_pixels_inside_their_item() {
        for scale in SCALES {
            let it = item(scale);
            for d in dots(it, (28.0 * scale).round(), scale) {
                assert!([d.x, d.y, d.w, d.h].iter().all(|v| v.fract() == 0.0), "{d:?} at {scale}");
                assert!(d.y >= it.y && d.y + d.h <= it.y + it.h, "{d:?} outside {it:?} at {scale}");
            }
            assert_eq!(row_width(scale), {
                let ds = dots(it, 0.0, scale);
                ds[PER_ROW - 1].x + ds[PER_ROW - 1].w
            });
        }
    }

    #[test]
    fn a_key_moves_one_dot_and_stops_at_the_ends() {
        assert_eq!(step(0, Key::Left), 0);
        assert_eq!(step(0, Key::Right), 1);
        assert_eq!(step(PER_ROW - 1, Key::Right), PER_ROW - 1);
        assert_eq!(step(3, Key::Left), 2);
    }

    #[test]
    fn the_two_rows_are_the_ten_colours_in_order() {
        let all: Vec<usize> = (0..2).flat_map(|r| (0..PER_ROW).map(move |a| index(r, a))).collect();
        assert_eq!(all, (0..10).collect::<Vec<_>>());
    }
}
