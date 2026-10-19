//! Where a terminal was, while it is being shown somewhere else: the last
//! frame it drew here, frosted, under the sentence that says where it went
//! (task 1758; macOS's `ControlRoomElsewhere.swift`, function for function).
//!
//! **The frame is a still picture**, taken once as the terminal leaves and
//! never changed while it goes on drawing elsewhere. Over all of it lies a
//! thin veil of the terminal's ground (`look::elsewhere::VEIL`), thin
//! enough that the frame can still be told for the screen it was; the words
//! are kept readable by a shade behind them -- more of the ground at the
//! middle, falling away all the way out with no flat part and no edge.
//!
//! This file is the arithmetic: how small the frame is kept, how big the
//! shade is, how it falls, how much of it the middle needs. The host blurs
//! and paints. The constants are the generated `look::elsewhere`, the same
//! numbers macOS reads, and the tests are macOS's, run against this host's
//! own themes.

use crate::lend::{Detail, Loan};
use crate::look::elsewhere as e;

/// The size a frame of `w` x `h` pixels is kept at: no larger than
/// `FRAME_LONGEST_SIDE` on its longer side, never enlarged, its shape
/// unchanged. `None` for a frame with no size.
pub fn kept_size(w: f64, h: f64) -> Option<(f64, f64)> {
    if w < 1.0 || h < 1.0 {
        return None;
    }
    let scale = (e::FRAME_LONGEST_SIDE / w.max(h)).min(1.0);
    Some(((w * scale).round().max(1.0), (h * scale).round().max(1.0)))
}

/// The ellipse the shade fills, round words of `words` in a place of
/// `place`: half the place's shorter side each way, and more where the
/// words are long, so that the corners of their box are never far out in
/// it. It may be larger than the place, which cuts it.
pub fn shade_size(words: (f64, f64), place: (f64, f64)) -> (f64, f64) {
    let least = place.0.min(place.1);
    (least.max(words.0 / e::SHADE_WORDS_WITHIN), least.max(words.1 / e::SHADE_WORDS_WITHIN))
}

/// How much of the middle's amount is left, by how far out from the middle
/// (0) to the ellipse's edge (1): a Gaussian, lowered so that it is nothing
/// at the edge. 49 points, close enough that the straight lines a gradient
/// draws between them are the curve. `(left, at)`.
pub fn shade_fall() -> Vec<(f64, f64)> {
    let bell = |out: f64| (-(out * out) / (2.0 * e::SHADE_SPREAD * e::SHADE_SPREAD)).exp();
    let edge = bell(1.0);
    (0..=48)
        .map(|step| {
            let out = step as f64 / 48.0;
            ((bell(out) - edge) / (1.0 - edge), out)
        })
        .collect()
}

/// `shade_fall` between its points, as a gradient draws it.
pub fn shade_left(out: f64) -> f64 {
    if out <= 0.0 {
        return 1.0;
    }
    let fall = shade_fall();
    for pair in fall.windows(2) {
        let ((il, ia), (ol, oa)) = (pair[0], pair[1]);
        if out <= oa {
            return il + (ol - il) * (out - ia) / (oa - ia);
        }
    }
    0.0
}

/// How far out in the shade the corners of the words' box are.
pub fn shade_corner(words: (f64, f64), place: (f64, f64)) -> f64 {
    let (ew, eh) = shade_size(words, place);
    if ew <= 0.0 || eh <= 0.0 {
        return 1.0;
    }
    let (x, y) = (words.0 / ew, words.1 / eh);
    (x * x + y * y).sqrt()
}

/// The amount of shade at its middle: whatever leaves `SHADE` at the
/// corners of the words' box.
pub fn shade_at_middle(words: (f64, f64), place: (f64, f64)) -> f64 {
    let left = shade_left(shade_corner(words, place));
    if left > 0.0 {
        (e::SHADE / left).min(1.0)
    } else {
        1.0
    }
}

/// How much of the terminal's ground is over the frame at the corners of
/// the words' box, veil and shade together: 1 is none of the frame showing.
/// Everywhere else under the words there is more.
pub fn ground_under_words(words: (f64, f64), place: (f64, f64)) -> f64 {
    let shade = shade_at_middle(words, place) * shade_left(shade_corner(words, place));
    1.0 - (1.0 - e::VEIL) * (1.0 - shade)
}

/// How much of the terminal's ground lies over the frame at a point
/// `(dx, dy)` from the middle of the words, veil and shade together, for a
/// shade of `ellipse` (`shade_size`) whose middle amount is `middle`
/// (`shade_at_middle`): 1 is none of the frame showing. macOS draws this as
/// a veil over the whole place and an elliptical gradient behind the words;
/// a host without gradients works it out for each pixel, and this is that.
pub fn ground_at(dx: f64, dy: f64, ellipse: (f64, f64), middle: f64) -> f64 {
    let (rx, ry) = (ellipse.0 / 2.0, ellipse.1 / 2.0);
    let out = if rx > 0.0 && ry > 0.0 { ((dx / rx).powi(2) + (dy / ry).powi(2)).sqrt() } else { 1.0 };
    let shade = middle * shade_left(out);
    1.0 - (1.0 - e::VEIL) * (1.0 - shade)
}

/// The widths of the three boxes whose blurs, one after another, come
/// closest to a Gaussian of `sigma` (the standard "three box blurs"
/// approximation): odd, so each is centred on its pixel.
pub fn box_widths(sigma: f64) -> [usize; 3] {
    let n = 3.0;
    let ideal = (12.0 * sigma * sigma / n + 1.0).sqrt();
    let mut lower = ideal.floor() as i64;
    if lower % 2 == 0 {
        lower -= 1;
    }
    let lower = lower.max(1);
    let upper = lower + 2;
    let m = ((12.0 * sigma * sigma - n * (lower * lower) as f64 - 4.0 * n * lower as f64 - 3.0 * n) / (-4.0 * lower as f64 - 4.0)).round() as i64;
    let mut out = [0usize; 3];
    for (i, w) in out.iter_mut().enumerate() {
        *w = if (i as i64) < m { lower } else { upper } as usize;
    }
    out
}

/// Blur `px` -- `w` x `h` pixels of four bytes each, rows top down -- by
/// about `sigma` (`BLUR`, in the kept frame's own pixels), every channel
/// alike. **The edge is repeated outwards**, as macOS's `clampedToExtent`
/// does, so the blur does not fade the picture's own edges to nothing.
pub fn blur(px: &mut [u8], w: usize, h: usize, sigma: f64) {
    if w == 0 || h == 0 || px.len() < w * h * 4 {
        return;
    }
    let mut tmp = vec![0u8; w * h * 4];
    for width in box_widths(sigma) {
        let r = (width / 2) as i64;
        box_pass(px, &mut tmp, w, h, r, true);
        box_pass(&tmp, px, w, h, r, false);
    }
}

/// One box blur of radius `r` along rows (`along_rows`) or columns, from
/// `src` into `dst`, the edge repeated.
fn box_pass(src: &[u8], dst: &mut [u8], w: usize, h: usize, r: i64, along_rows: bool) {
    let (len, lines) = if along_rows { (w, h) } else { (h, w) };
    let at = |line: usize, i: usize| if along_rows { (line * w + i) * 4 } else { (i * w + line) * 4 };
    let span = (2 * r + 1) as u32;
    for line in 0..lines {
        for c in 0..4 {
            let clamp = |i: i64| i.clamp(0, len as i64 - 1) as usize;
            let mut sum: u32 = (-r..=r).map(|k| src[at(line, clamp(k)) + c] as u32).sum();
            for i in 0..len {
                dst[at(line, i) + c] = ((sum + span / 2) / span) as u8;
                let leaving = src[at(line, clamp(i as i64 - r)) + c] as u32;
                let coming = src[at(line, clamp(i as i64 + r + 1)) + c] as u32;
                sum = sum + coming - leaving;
            }
        }
    }
}

/// Whose frame is drawn under what the right-hand side says, given the one
/// frame kept (`frozen`: the terminal it was taken from). Only that same
/// terminal's, and only where the side says it is somewhere else: taken
/// back to its own tab -- macOS's one case -- and, on this host, in another
/// window (`lend::Place::Elsewhere`). Every other way of having no terminal
/// there gets the flat ground.
pub fn frame_for<'a, F>(detail: &Detail, frozen: Option<(&str, &'a F)>) -> Option<&'a F> {
    let loan: &Loan = match detail {
        Detail::TakenBack(l) | Detail::Elsewhere(l) => l,
        Detail::NothingSelected | Detail::NoSupervisor { .. } | Detail::SupervisorGone { .. } | Detail::Terminal(_) => return None,
    };
    let (terminal, frame) = frozen?;
    (terminal == loan.terminal).then_some(frame)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::{self, Rgba};

    fn loan(group: &str, terminal: &str) -> Loan {
        Loan { group: group.into(), terminal: terminal.into() }
    }

    #[test]
    fn the_frame_under_it_is_the_one_taken_from_that_terminal() {
        let frame = 7u8;
        assert_eq!(frame_for(&Detail::TakenBack(loan("billing", "t1")), Some(("t1", &frame))), Some(&7));
        assert_eq!(frame_for(&Detail::Elsewhere(loan("billing", "t1")), Some(("t1", &frame))), Some(&7));
        // Another terminal's last frame is not this one's.
        assert_eq!(frame_for(&Detail::TakenBack(loan("search", "t2")), Some(("t1", &frame))), None);
        // Never drawn here: the flat ground.
        assert_eq!(frame_for::<u8>(&Detail::TakenBack(loan("billing", "t1")), None), None);
        // The other ways of having no terminal are not "it is over there".
        for d in [
            Detail::NothingSelected,
            Detail::NoSupervisor { group: "billing".into() },
            Detail::SupervisorGone { group: "billing".into() },
            Detail::Terminal(loan("billing", "t1")),
        ] {
            assert_eq!(frame_for(&d, Some(("t1", &frame))), None, "{d:?}");
        }
    }

    #[test]
    fn a_frame_is_kept_small_and_in_its_own_shape() {
        assert_eq!(kept_size(2600.0, 1600.0), Some((640.0, 394.0)));
        assert_eq!(kept_size(800.0, 3200.0), Some((160.0, 640.0)));
        assert_eq!(kept_size(300.0, 200.0), Some((300.0, 200.0)));
        assert_eq!(kept_size(0.0, 0.0), None);
    }

    fn luminance(c: Rgba) -> f64 {
        let ch = |v: u8| {
            let c = v as f64 / 255.0;
            if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        };
        0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    fn contrast(text: Rgba, under: (f64, f64, f64)) -> f64 {
        let a = luminance(text);
        let ground = |v: f64| {
            let c = v / 255.0;
            if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        };
        let b = 0.2126 * ground(under.0) + 0.7152 * ground(under.1) + 0.0722 * ground(under.2);
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    /// macOS's cases: one short word to a sentence the width of a wide
    /// pane, one line to a wrapped four; a sliver of a split to a window.
    fn cases() -> Vec<((f64, f64), (f64, f64))> {
        let mut out = Vec::new();
        for w in [40.0, 150.0, 190.0, 300.0, 600.0, 900.0] {
            for h in [16.0, 40.0, 60.0, 80.0] {
                for place in [(120.0, 90.0), (360.0, 240.0), (900.0, 560.0), (2200.0, 1300.0)] {
                    out.push(((w, h), place));
                }
            }
        }
        out
    }

    #[test]
    fn the_words_can_be_read_over_any_frame_at_all() {
        // All white and all black are the two a frame can be furthest from
        // the ground. Both lines keep 4.5:1 in both of this host's themes.
        for (words, place) in cases() {
            let over = ground_under_words(words, place);
            for dark in [true, false] {
                let theme = look::theme(dark);
                let g = theme.terminal_background;
                for frame in [0.0, 255.0] {
                    let under = (
                        g.r as f64 * over + frame * (1.0 - over),
                        g.g as f64 * over + frame * (1.0 - over),
                        g.b as f64 * over + frame * (1.0 - over),
                    );
                    assert!(contrast(theme.text_secondary, under) >= 4.5, "{words:?} in {place:?}, dark={dark}, frame={frame}");
                    assert!(contrast(theme.attention_text, under) >= 4.5, "{words:?} in {place:?}, dark={dark}, frame={frame}");
                }
            }
        }
    }

    #[test]
    fn the_corners_of_the_words_are_never_far_out_in_the_shade() {
        for (words, place) in cases() {
            let corner = shade_corner(words, place);
            assert!(corner <= 0.37, "{words:?} in {place:?}: {corner}");
            let middle = shade_at_middle(words, place);
            assert!(middle < 1.0);
            assert!((middle * shade_left(corner) - e::SHADE).abs() < 0.000001);
        }
    }

    #[test]
    fn the_shade_reaches_half_the_places_shorter_side() {
        assert_eq!(shade_size((40.0, 40.0), (900.0, 560.0)), (560.0, 560.0));
        let long = shade_size((300.0, 40.0), (900.0, 560.0));
        assert!(long.0 > 1100.0);
        assert_eq!(long.1, 560.0);
    }

    #[test]
    fn the_shade_falls_away_all_the_way_out_with_no_flat_part_and_no_edge() {
        let fall = shade_fall();
        assert_eq!(fall.first().copied(), Some((1.0, 0.0)));
        assert!(fall.last().unwrap().0.abs() < 0.000001);
        assert_eq!(fall.last().unwrap().1, 1.0);
        for pair in fall.windows(2) {
            let ((il, ia), (ol, oa)) = (pair[0], pair[1]);
            assert!(ol < il, "a flat part at {oa}");
            assert!(il - ol < 0.05, "an edge at {oa}");
            assert!(oa > ia);
        }
        assert!(shade_left(0.9) < 0.05);
    }

    #[test]
    fn the_ground_at_a_point_is_the_veil_and_the_shade_together() {
        let (words, place) = ((190.0, 40.0), (900.0, 560.0));
        let ellipse = shade_size(words, place);
        let middle = shade_at_middle(words, place);
        // At the corners of the words' box it is what the arithmetic above
        // says is there.
        let corner = ground_at(words.0 / 2.0, words.1 / 2.0, ellipse, middle);
        assert!((corner - ground_under_words(words, place)).abs() < 0.000001);
        // More at the middle, the veil alone out past the ellipse.
        assert!(ground_at(0.0, 0.0, ellipse, middle) > corner);
        assert!((ground_at(ellipse.0, 0.0, ellipse, middle) - e::VEIL).abs() < 0.000001);
    }

    #[test]
    fn three_boxes_come_out_odd_and_near_the_gaussian() {
        let b = box_widths(e::BLUR);
        assert!(b.iter().all(|w| w % 2 == 1), "{b:?}");
        // Three boxes of these widths have this variance; it is the
        // Gaussian's, near enough.
        let variance: f64 = b.iter().map(|&w| ((w * w) as f64 - 1.0) / 12.0).sum();
        assert!((variance.sqrt() - e::BLUR).abs() < 0.5, "{b:?} -> {}", variance.sqrt());
    }

    #[test]
    fn a_blur_keeps_a_flat_picture_flat_up_to_its_edges() {
        // The edge repeated outwards: no darkening at the border.
        let (w, h) = (40, 30);
        let mut px = vec![200u8; w * h * 4];
        blur(&mut px, w, h, e::BLUR);
        assert!(px.iter().all(|&v| v == 200));
    }

    #[test]
    fn a_blur_spreads_a_point_evenly_and_keeps_what_there_was() {
        let (w, h) = (61, 61);
        let mut px = vec![0u8; w * h * 4];
        let mid = (30 * w + 30) * 4;
        for c in 0..4 {
            px[mid + c] = 255;
        }
        // Spread over many pixels a single 255 rounds away, so a block.
        for y in 25..36 {
            for x in 25..36 {
                for c in 0..4 {
                    px[(y * w + x) * 4 + c] = 255;
                }
            }
        }
        let before: u64 = px.iter().map(|&v| v as u64).sum();
        blur(&mut px, w, h, 4.0);
        let at = |x: usize, y: usize| px[(y * w + x) * 4];
        // Symmetric about the middle, falling away from it.
        assert_eq!(at(20, 30), at(40, 30));
        assert_eq!(at(30, 20), at(30, 40));
        assert!(at(30, 30) > at(20, 30) && at(20, 30) > at(10, 30));
        // What there was is still there, give or take the rounding.
        let after: u64 = px.iter().map(|&v| v as u64).sum();
        assert!((after as i64 - before as i64).abs() < (w * h * 4) as i64 / 2, "{before} -> {after}");
    }

    #[test]
    fn the_veil_alone_leaves_the_frame_to_be_seen() {
        assert!(e::VEIL <= 0.7);
    }
}
