//! The window's tab strip as the control room's look has it: a track, a
//! bright chip on the selected tab, and nothing behind the others
//! (`control-room.md`, 3.5 item 4).
//!
//! The strip itself is the host's (`strip.rs`): where the tabs are, what is
//! clicked, what is dragged. This says only what the track and the chip
//! are -- where, how round, which colour -- so that the host places and
//! never measures, and so that it can be tested off Windows.
//!
//! **Everything here is in device pixels, and whole ones.** The strip is
//! laid out in pixels already; a rectangle from here has no half pixel in
//! it at any scale, so a straight edge of the chip is one row of pixels and
//! never two at half strength.

use crate::layout::Rect;
use crate::look::{radius, stack_tab, window_tab, Rgba, Theme};
use crate::scene::over;

const WHITE: Rgba = Rgba { r: 255, g: 255, b: 255, a: 1.0 };
const BLACK: Rgba = Rgba { r: 0, g: 0, b: 0, a: 1.0 };

fn px(points: f64, scale: f64) -> f64 {
    (points * scale).round().max(1.0)
}

/// The track: from the first tab's left edge to the last one's right, as
/// high as the table says, in the middle of a strip `strip_h` high.
pub fn track(left: f64, right: f64, strip_h: f64, scale: f64) -> Rect {
    let h = px(window_tab::TRACK_HEIGHT, scale).min(strip_h);
    let pad = px(window_tab::TRACK_PADDING, scale);
    Rect { x: left.round() - pad, y: ((strip_h - h) / 2.0).floor(), w: (right.round() - left.round()).max(0.0) + 2.0 * pad, h }
}

/// Where the chip rests on a tab whose slot is `slot`: the slot's own
/// width, the table's height, in the middle of the strip -- so it sits
/// inside the track with the track's padding around it.
pub fn chip(slot: Rect, strip_h: f64, scale: f64) -> Rect {
    let h = px(window_tab::HEIGHT, scale).min(strip_h);
    // The same top as the track's, plus the padding: the gap above the
    // chip is the padding exactly, and the one below takes the odd pixel.
    let track_h = px(window_tab::TRACK_HEIGHT, scale).min(strip_h);
    let top = ((strip_h - track_h) / 2.0).floor() + ((track_h - h) / 2.0).floor();
    Rect { x: slot.x.round(), y: top, w: slot.w.round().max(0.0), h }
}

/// A pill's corner, for a shape this high: never more than half of it.
pub fn corner(of: Rect, scale: f64, track: bool) -> f64 {
    let want = px(if track { radius::WINDOW_TAB_TRACK } else { radius::WINDOW_TAB }, scale);
    want.min((of.h / 2.0).floor())
}

/// The track's colour on a strip whose ground is `ground`: a step darker.
pub fn track_color(ground: Rgba, theme: &Theme) -> Rgba {
    over(ground, theme.window_tab_track, 1.0)
}

/// The chip: white mixed into the track by the table's amount. `lift` is 0
/// at rest and 1 in the air, where it is a little more see-through.
pub fn chip_color(ground: Rgba, theme: &Theme, lift: f64) -> Rgba {
    let tint = theme.selection_tint + (theme.selection_tint_moving - theme.selection_tint) * lift.clamp(0.0, 1.0);
    over(track_color(ground, theme), WHITE, tint)
}

/// The faint band just inside the chip's edge: darker in the light theme,
/// lighter in the dark one.
pub fn chip_edge(ground: Rgba, theme: &Theme, lift: f64) -> Rgba {
    let toward = if theme.selection_edge < 0.0 { BLACK } else { WHITE };
    over(chip_color(ground, theme, lift), toward, theme.selection_edge.abs())
}

/// What is under the pointer and not selected.
pub fn hover_color(ground: Rgba, theme: &Theme) -> Rgba {
    over(track_color(ground, theme), theme.window_tab_hover, 1.0)
}

/// Which gaps between tabs get a line, out of `count` tabs: gap `g` is the
/// one between tab `g` and tab `g + 1`, so there is none before the first
/// or after the last. The Mac's rule: a line only between two plain tabs,
/// and none on either side of the selected tab, the one under the pointer
/// (on its body or its close cross) or the one in the hand.
///
/// **By index, not by where the chip is.** The chip is narrower than its
/// slot, so a test of "is this line under the chip" let the selected tab
/// keep both its lines (task 1562). While the chip slides to a newly
/// selected tab, `selected` is the one it is going to.
pub fn separator_gaps(count: usize, selected: Option<usize>, hover: Option<usize>, dragged: Option<usize>) -> Vec<usize> {
    let marked = |i: usize| [selected, hover, dragged].contains(&Some(i));
    (0..count.saturating_sub(1)).filter(|&g| !marked(g) && !marked(g + 1)).collect()
}

/// The short line in gap `g`: one pixel wide at `x` (the left tab's right
/// edge), in the middle of the strip.
pub fn separator(x: f64, strip_h: f64, scale: f64) -> Rect {
    let h = px(stack_tab::SEPARATOR_HEIGHT, scale).min(strip_h);
    Rect { x: x.round(), y: ((strip_h - h) / 2.0).floor(), w: 1.0, h }
}

/// How much darker the line is than the track under it, in levels of each
/// channel. Read off the Mac: on macOS 26 the system's line between two
/// plain tabs is (34,37,44) on a bar of (38,41,48) -- 4 levels darker, dark
/// theme (verify-cr-11/b1-real-drag-two-tabs.png, x 466-467, y 172-188).
/// The old `theme.line` here was white at 15%, about 35 levels *brighter*,
/// which is what made it read as a leftover from square tabs. The light
/// theme takes the same step; no light reading off the Mac backs it yet.
pub const SEPARATOR_STEP: u8 = 4;

pub fn separator_color(ground: Rgba, theme: &Theme) -> Rgba {
    let t = track_color(ground, theme);
    let step = |c: u8| c.saturating_sub(SEPARATOR_STEP);
    Rgba { r: step(t.r), g: step(t.g), b: step(t.b), a: 1.0 }
}

/// A tab that is being dragged: brighter than the chip, so that it reads
/// as picked up.
pub fn dragged_color(ground: Rgba, theme: &Theme) -> Rgba {
    over(chip_color(ground, theme, 0.0), WHITE, theme.selection_tint)
}

/// A tab's title: the main colour on the chip, a step back off it.
pub fn title_color(theme: &Theme, on_chip: bool) -> Rgba {
    if on_chip { theme.text } else { theme.text_secondary }
}

/// The chip's shadow, as flat pieces to lay down before it, furthest first:
/// each a rectangle, how round, and its colour -- `under`, which is what the
/// shadow falls on, darkened. Opaque, like every colour a host is handed.
///
/// **An approximation, and it says so.** A shadow is a blur and this host
/// has none, so each of the table's two shadows is one flat piece: the
/// chip's shape grown by half the blur, moved down by the offset, at half
/// the strength. Lifted, the offset and the blur are the moving ones, so
/// the shadow reaches further -- which is the part of "lifted" this can
/// show. Pieces that would not stand a whole pixel clear of the chip are
/// left out rather than drawn as a smear.
pub fn shadow(chip: Rect, radius: f64, under: Rgba, theme: &Theme, lift: f64, scale: f64) -> Vec<(Rect, f64, Rgba)> {
    let lift = lift.clamp(0.0, 1.0);
    let mix = |rest: f64, moving: f64| rest + (moving - rest) * lift;
    let pieces = [
        (mix(theme.selection_halo_blur, theme.selection_halo_moving_blur), 0.0, mix(theme.selection_halo_alpha, theme.selection_halo_moving_alpha)),
        (
            mix(theme.selection_shadow_blur, theme.selection_shadow_moving_blur),
            mix(theme.selection_shadow_y, theme.selection_shadow_moving_y),
            mix(theme.selection_shadow_alpha, theme.selection_shadow_moving_alpha),
        ),
    ];
    let mut out = Vec::new();
    for (blur, y, alpha) in pieces {
        let grow = (blur / 2.0 * scale).round();
        let down = (y * scale).round();
        if grow < 1.0 && down < 1.0 {
            continue;
        }
        out.push((
            Rect { x: chip.x - grow, y: chip.y - grow + down, w: chip.w + 2.0 * grow, h: chip.h + 2.0 * grow },
            radius + grow,
            over(under, BLACK, alpha / 2.0),
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look;

    const SCALES: [f64; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];
    /// The strip's own ground in the host (`strip.rs`).
    const GROUND: Rgba = Rgba { r: 0x1d, g: 0x1f, b: 0x20, a: 1.0 };

    fn whole(r: Rect) -> bool {
        [r.x, r.y, r.w, r.h].iter().all(|v| v.fract() == 0.0)
    }

    #[test]
    fn nothing_has_half_a_pixel_in_it_at_any_scale() {
        for scale in SCALES {
            let strip_h = (30.0 * scale as f64).round();
            // A slot as the strip lays it out, and one that arrives off the
            // grid from a slide.
            for slot_x in [44.0, 263.0, 263.4, 263.5] {
                let slot = Rect { x: slot_x, y: 0.0, w: (220.0 * scale).floor() - 1.0, h: strip_h };
                let c = chip(slot, strip_h, scale);
                assert!(whole(c), "chip {c:?} at {scale}");
                assert!(corner(c, scale, false).fract() == 0.0);
                for lift in [0.0, 0.4, 1.0] {
                    for (r, radius, _) in shadow(c, corner(c, scale, false), GROUND, look::theme(true), lift, scale) {
                        assert!(whole(r) && radius.fract() == 0.0, "shadow {r:?} at {scale}");
                    }
                }
            }
            let t = track(44.0, 900.0, strip_h, scale);
            assert!(whole(t), "track {t:?} at {scale}");
            let s = separator(263.0, strip_h, scale);
            assert!(whole(s) && s.w == 1.0 && s.y > t.y && s.y + s.h < t.y + t.h, "separator {s:?} at {scale}");
        }
    }

    #[test]
    fn the_chip_sits_in_the_track_with_the_tables_padding_around_it() {
        for scale in SCALES {
            let strip_h = (30.0 * scale as f64).round();
            let slot = Rect { x: 44.0, y: 0.0, w: 200.0, h: strip_h };
            let t = track(slot.x, slot.x + slot.w, strip_h, scale);
            let c = chip(slot, strip_h, scale);
            let pad = (window_tab::TRACK_PADDING * scale).round();
            assert_eq!(c.x - t.x, pad, "left at {scale}");
            assert_eq!((t.x + t.w) - (c.x + c.w), pad, "right at {scale}");
            let (above, below) = (c.y - t.y, (t.y + t.h) - (c.y + c.h));
            assert!(above >= 1.0 && below >= above && below - above <= 1.0, "{above} above, {below} below at {scale}");
            // And the track is inside the strip.
            assert!(t.y >= 0.0 && t.y + t.h <= strip_h);
            // Both are pills.
            assert_eq!(corner(c, scale, false), (c.h / 2.0).floor().min((radius::WINDOW_TAB * scale).round()));
            assert!(corner(t, scale, true) <= t.h / 2.0);
        }
    }

    #[test]
    fn at_the_designs_own_scale_it_is_the_designs_numbers() {
        // v14 GRID: a track 28 high, a tab 24 high, 2 between.
        let slot = Rect { x: 10.0, y: 0.0, w: 198.0, h: 30.0 };
        let t = track(10.0, 208.0, 30.0, 1.0);
        let c = chip(slot, 30.0, 1.0);
        assert_eq!((t.h, c.h, c.y - t.y), (28.0, 24.0, 2.0));
        assert_eq!((corner(t, 1.0, true), corner(c, 1.0, false)), (14.0, 12.0));
    }

    #[test]
    fn the_track_is_darker_than_the_strip_and_the_chip_is_the_brightest_thing_on_it() {
        let light = |c: Rgba| c.r as u32 + c.g as u32 + c.b as u32;
        for dark in [true, false] {
            let theme = look::theme(dark);
            let ground = if dark { GROUND } else { theme.window_base };
            let (track, rest, hover) = (track_color(ground, theme), chip_color(ground, theme, 0.0), hover_color(ground, theme));
            assert!(light(track) < light(ground), "dark={dark}");
            assert!(light(rest) > light(ground) && light(rest) > light(hover), "dark={dark}");
            // In the air it is more see-through: nearer the track.
            let moving = chip_color(ground, theme, 1.0);
            assert!(light(moving) < light(rest) && light(moving) > light(track), "dark={dark}");
            // The band inside the edge goes the way the table says.
            let edge = chip_edge(ground, theme, 0.0);
            assert_eq!(light(edge) > light(rest), theme.selection_edge > 0.0, "dark={dark}");
            assert!(light(dragged_color(ground, theme)) > light(rest), "dark={dark}");
            // Selected reads stronger than not.
            assert_ne!(title_color(theme, true), title_color(theme, false));
        }
    }

    #[test]
    fn the_dark_chip_on_the_designs_ground_is_the_colour_the_design_measured() {
        // `surface_window_tab_selected` was read off the rendered design:
        // the same arithmetic over the design's own ground must land on it.
        let theme = look::theme(true);
        let made = chip_color(theme.window_base, theme, 0.0);
        let said = theme.surface_window_tab_selected;
        for (a, b) in [(made.r, said.r), (made.g, said.g), (made.b, said.b)] {
            assert!((a as i32 - b as i32).abs() <= 2, "{made:?} against {said:?}");
        }
    }

    #[test]
    fn a_lifted_chips_shadow_reaches_further_and_none_is_a_smear() {
        let c = Rect { x: 100.0, y: 3.0, w: 200.0, h: 24.0 };
        for dark in [true, false] {
            let theme = look::theme(dark);
            let reach = |lift: f64, scale: f64| {
                shadow(c, 12.0, GROUND, theme, lift, scale).iter().map(|(r, _, _)| r.y + r.h).fold(c.y + c.h, f64::max) - (c.y + c.h)
            };
            for scale in SCALES {
                assert!(reach(1.0, scale) > reach(0.0, scale), "dark={dark} at {scale}");
                for lift in [0.0, 1.0] {
                    for (r, radius, color) in shadow(c, 12.0, GROUND, theme, lift, scale) {
                        // Around the chip, not under a corner of it.
                        assert!(r.x <= c.x && r.x + r.w >= c.x + c.w && r.y + r.h >= c.y + c.h);
                        assert!(radius >= 12.0);
                        // Darker than what it falls on, and opaque.
                        assert!(color.a == 1.0 && color.r < GROUND.r, "{color:?}");
                    }
                }
            }
        }
    }

    #[test]
    fn a_line_only_between_two_plain_tabs() {
        let gaps = separator_gaps;
        // Nothing marked: every gap, none before the first or after the last.
        assert_eq!(gaps(5, None, None, None), vec![0, 1, 2, 3]);
        assert_eq!(gaps(1, None, None, None), Vec::<usize>::new());
        assert_eq!(gaps(0, Some(0), None, None), Vec::<usize>::new());
        // Each of the three, first, middle, last: both its sides go.
        for one in 0..3 {
            let mark = |i: usize| {
                let mut m = [None, None, None];
                m[one] = Some(i);
                gaps(5, m[0], m[1], m[2])
            };
            assert_eq!(mark(0), vec![1, 2, 3], "kind {one} first");
            assert_eq!(mark(2), vec![0, 3], "kind {one} middle");
            assert_eq!(mark(4), vec![0, 1, 2], "kind {one} last");
        }
        // Overlapping: selected and hovered the same tab, dragged elsewhere.
        assert_eq!(gaps(6, Some(2), Some(2), None), vec![0, 3, 4]);
        assert_eq!(gaps(6, Some(1), Some(2), None), vec![3, 4]);
        assert_eq!(gaps(6, Some(0), Some(5), Some(3)), vec![1]);
        assert_eq!(gaps(3, Some(0), Some(1), Some(2)), Vec::<usize>::new());
        // An index past the end marks nothing.
        assert_eq!(gaps(3, Some(7), None, None), vec![0, 1]);
    }

    #[test]
    fn the_line_is_a_few_levels_off_the_track_the_way_the_macs_is() {
        for dark in [true, false] {
            let theme = look::theme(dark);
            let ground = if dark { GROUND } else { theme.window_base };
            let (track, line) = (track_color(ground, theme), separator_color(ground, theme));
            for (t, l) in [(track.r, line.r), (track.g, line.g), (track.b, line.b)] {
                let d = l as i32 - t as i32;
                assert!((4..=6).contains(&d.abs()), "dark={dark}: {d} levels");
                assert!(d < 0, "dark={dark}: darker than the track, as on the Mac");
            }
            assert_eq!(line.a, 1.0);
        }
    }
}
