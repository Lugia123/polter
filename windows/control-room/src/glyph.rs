//! The four status glyphs as shapes (`control-room.md`, 3.5 items 2 and 3).
//!
//! The macOS host draws the system's symbols. Windows has none of them, so
//! these are the design's own paths, on its 14-unit artboard. A host scales
//! them to the box it is given and fills them; which one to draw is the
//! core's answer and arrives as `shown`.
//!
//! Each shape carries a `level`: how much of the glyph's colour is there, 0
//! to 1. A level of 0 cuts a hole in what is under it (the mark inside the
//! triangle); the spinner's lines differ only in level.

use crate::look::status;
use crate::snapshot::Shown;

#[derive(Debug, Clone, PartialEq)]
pub enum Outline {
    /// Corners in order, closed.
    Polygon(Vec<(f64, f64)>),
    /// `x, y, w, h` and the corner radius.
    RoundRect(f64, f64, f64, f64, f64),
    /// The box an ellipse fills: `x, y, w, h`.
    Ellipse(f64, f64, f64, f64),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Shape {
    pub outline: Outline,
    pub level: f64,
}

fn full(outline: Outline) -> Shape {
    Shape { outline, level: 1.0 }
}

fn cut(outline: Outline) -> Shape {
    Shape { outline, level: 0.0 }
}

/// The shapes of a glyph, in the order to fill them. `spin_step` is which
/// of the spinner's lines is brightest (`pulse::spin_step`); the others
/// ignore it. Nothing for `Shown::None`.
/// The glyph of a terminal the person is holding: two bars, as the design
/// draws them on the status glyphs' own artboard (`06-panes`). The macOS
/// host's `PaneHeldGlyph` is the same two from the same numbers.
pub fn held() -> Vec<Shape> {
    vec![full(Outline::RoundRect(3.8, 3.0, 2.4, 8.0, 0.8)), full(Outline::RoundRect(7.8, 3.0, 2.4, 8.0, 0.8))]
}

/// The two marks a group's row can carry beside its name (task 1661,
/// design v21 `05`): pinned, a solid pushpin; muted, a bell drawn in line
/// with a slash through it. On the status glyphs' own artboard and drawn
/// in a quieter ink than they are, so that they are not read as a status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mark {
    Pinned,
    Muted,
    /// The supervisor's flag (task 1692): `TabMark.supervisor`'s ⚑, a pole
    /// round at its ends and a pennant notched at its free end. The macOS
    /// host's `PaneSupervisorMark` is the same from the same numbers.
    Supervisor,
    /// The supervisor's flag lowered (task 1700, `pane-color-interface.md`
    /// §1.3): ⚐, the same pole and pennant with the pennant hollow -- it has
    /// been quiet a long time.
    SupervisorLowered,
    /// A coloured pane's dot in its badge (task 1700): a disc on the
    /// glyphs' artboard, as the design's `dot_svg` draws it (r 4 about the
    /// middle).
    Dot,
}

pub fn mark(mark: Mark) -> Vec<Shape> {
    match mark {
        Mark::Supervisor => vec![
            full(Outline::RoundRect(2.5, 0.9, 1.4, 12.4, 0.7)),
            full(Outline::Polygon(vec![(3.9, 2.1), (11.5, 2.1), (9.6, 5.0), (11.5, 7.9), (3.9, 7.9)])),
        ],
        Mark::SupervisorLowered => vec![
            full(Outline::RoundRect(2.5, 0.9, 1.4, 12.4, 0.7)),
            full(Outline::Polygon(vec![(3.9, 2.1), (11.5, 2.1), (9.6, 5.0), (11.5, 7.9), (3.9, 7.9)])),
            cut(Outline::Polygon(vec![(5.1, 3.2), (9.4, 3.2), (8.2, 5.0), (9.4, 6.8), (5.1, 6.8)])),
        ],
        Mark::Dot => vec![full(Outline::Ellipse(3.0, 3.0, 8.0, 8.0))],
        Mark::Pinned => vec![
            // The head, the body widening to the plate, and the needle.
            full(Outline::RoundRect(4.0, 1.0, 6.0, 2.2, 1.0)),
            full(Outline::Polygon(vec![(4.9, 3.0), (9.1, 3.0), (10.0, 7.8), (4.0, 7.8)])),
            full(Outline::RoundRect(2.5, 7.6, 9.0, 1.6, 0.8)),
            full(Outline::RoundRect(6.35, 9.0, 1.3, 4.2, 0.65)),
        ],
        Mark::Muted => {
            // A line from the upper left to the lower right, as a band of
            // half-width `h` about its centre line.
            let band = |h: f64| {
                let (a, b) = ((2.0, 1.5), (12.0, 12.5));
                let (dx, dy): (f64, f64) = (b.0 - a.0, b.1 - a.1);
                let len = (dx * dx + dy * dy).sqrt();
                let (nx, ny) = (-dy / len * h, dx / len * h);
                Outline::Polygon(vec![(a.0 + nx, a.1 + ny), (b.0 + nx, b.1 + ny), (b.0 - nx, b.1 - ny), (a.0 - nx, a.1 - ny)])
            };
            vec![
                // The bell in line: a dome on straight sides, its inside
                // cut out, standing on its rim, the clapper under it.
                full(Outline::Ellipse(3.0, 1.5, 8.0, 8.0)),
                full(Outline::Polygon(vec![(3.0, 5.5), (11.0, 5.5), (11.6, 9.4), (2.4, 9.4)])),
                cut(Outline::Ellipse(4.3, 2.8, 5.4, 5.4)),
                cut(Outline::Polygon(vec![(4.3, 5.5), (9.7, 5.5), (10.2, 9.0), (3.8, 9.0)])),
                full(Outline::RoundRect(1.6, 8.6, 10.8, 1.4, 0.7)),
                full(Outline::Ellipse(5.9, 10.4, 2.2, 2.2)),
                // The slash, with a gap cut either side of it.
                cut(band(1.6)),
                full(band(0.65)),
            ]
        }
    }
}

pub fn shapes(shown: Shown, spin_step: usize) -> Vec<Shape> {
    let a = status::ARTBOARD;
    match shown {
        // A speech bubble with its tail at the lower left.
        Shown::NeedsYou => vec![
            full(Outline::RoundRect(1.0, 1.5, 12.0, 9.0, 2.5)),
            full(Outline::Polygon(vec![(3.5, 9.5), (3.5, 13.0), (7.5, 9.5)])),
        ],
        // A triangle with an exclamation mark cut out of it.
        Shown::Trouble => vec![
            full(Outline::Polygon(vec![(7.0, 1.0), (13.5, 12.5), (0.5, 12.5)])),
            cut(Outline::RoundRect(6.3, 4.8, 1.4, 4.2, 0.7)),
            cut(Outline::Ellipse(6.2, 9.8, 1.6, 1.6)),
        ],
        Shown::DoneUnseen => {
            let d = status::DONE_UNSEEN_DOT;
            vec![full(Outline::Ellipse((a - d) / 2.0, (a - d) / 2.0, d, d))]
        }
        Shown::Working => spokes(spin_step),
        Shown::None => Vec::new(),
    }
}

/// The progress spinner: short lines round a centre, one bright and the
/// rest fading behind it. The same arithmetic as the macOS host's `Spinner`.
fn spokes(step: usize) -> Vec<Shape> {
    let a = status::ARTBOARD;
    let count = status::WORKING_SPIN_STEPS as usize;
    let w = status::WORKING_SPOKE_WIDTH;
    let h = status::WORKING_SPOKE_LENGTH;
    let inset = status::WORKING_SPOKE_INSET;
    let faint = status::WORKING_SPOKE_MIN_OPACITY;
    let c = a / 2.0;
    (0..count)
        .map(|n| {
            // 0 is the bright one; the one just ahead of it is faintest.
            let behind = (step + count - n % count) % count;
            let ahead = (count - behind) % count;
            let level = if behind == 0 {
                1.0
            } else {
                faint + (1.0 - faint) * (ahead as f64 - 1.0) / (count as f64 - 1.0)
            };
            let turn = (n as f64) * 2.0 * std::f64::consts::PI / count as f64;
            let (sin, cos) = turn.sin_cos();
            // The line stands above the centre before it is turned.
            let corners = [(-w / 2.0, -c + inset), (w / 2.0, -c + inset), (w / 2.0, -c + inset + h), (-w / 2.0, -c + inset + h)];
            let turned = corners.iter().map(|(x, y)| (c + x * cos - y * sin, c + x * sin + y * cos)).collect();
            Shape { outline: Outline::Polygon(turned), level }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bounds(o: &Outline) -> (f64, f64, f64, f64) {
        match o {
            Outline::Polygon(p) => {
                let xs = p.iter().map(|q| q.0);
                let ys = p.iter().map(|q| q.1);
                (
                    xs.clone().fold(f64::MAX, f64::min),
                    ys.clone().fold(f64::MAX, f64::min),
                    xs.fold(f64::MIN, f64::max),
                    ys.fold(f64::MIN, f64::max),
                )
            }
            Outline::RoundRect(x, y, w, h, _) | Outline::Ellipse(x, y, w, h) => (*x, *y, x + w, y + h),
        }
    }

    #[test]
    fn every_glyph_stays_on_the_artboard() {
        for shown in [Shown::NeedsYou, Shown::Trouble, Shown::DoneUnseen, Shown::Working] {
            for step in 0..8 {
                for s in shapes(shown, step) {
                    let (l, t, r, b) = bounds(&s.outline);
                    assert!(l >= 0.0 && t >= 0.0 && r <= status::ARTBOARD && b <= status::ARTBOARD, "{shown:?} {s:?}");
                }
            }
        }
    }

    #[test]
    fn nothing_is_drawn_for_none_and_something_for_each_of_the_four() {
        assert!(shapes(Shown::None, 0).is_empty());
        for shown in [Shown::NeedsYou, Shown::Trouble, Shown::DoneUnseen, Shown::Working] {
            assert!(!shapes(shown, 0).is_empty(), "{shown:?}");
        }
    }

    #[test]
    fn the_four_are_told_apart_by_shape_and_not_only_by_colour() {
        let all: Vec<_> =
            [Shown::NeedsYou, Shown::Trouble, Shown::DoneUnseen, Shown::Working].iter().map(|s| shapes(*s, 0)).collect();
        for i in 0..all.len() {
            for j in i + 1..all.len() {
                assert_ne!(all[i], all[j]);
            }
        }
    }

    #[test]
    fn the_done_dot_is_the_size_the_table_gives_and_centred() {
        let s = shapes(Shown::DoneUnseen, 0);
        assert_eq!(s, vec![full(Outline::Ellipse(4.0, 4.0, 6.0, 6.0))]);
    }

    #[test]
    fn the_spinner_has_one_bright_line_and_it_is_the_step() {
        for step in 0..8 {
            let s = shapes(Shown::Working, step);
            assert_eq!(s.len(), 8);
            let bright: Vec<usize> = s.iter().enumerate().filter(|(_, x)| x.level == 1.0).map(|(n, _)| n).collect();
            assert_eq!(bright, vec![step]);
            // The line ahead of the bright one is the faintest.
            let ahead = &s[(step + 1) % 8];
            assert!((ahead.level - status::WORKING_SPOKE_MIN_OPACITY).abs() < 1e-9, "{}", ahead.level);
            assert!(s.iter().all(|x| x.level >= status::WORKING_SPOKE_MIN_OPACITY - 1e-9));
        }
    }

    #[test]
    fn the_mark_in_the_triangle_is_a_hole() {
        let s = shapes(Shown::Trouble, 0);
        assert_eq!(s.iter().filter(|x| x.level == 0.0).count(), 2);
        assert_eq!(s[0].level, 1.0);
    }
}
