//! The mark of a page of a project on a window tab (task 1796): two
//! stacked pages outlined in the project's colour, and a glow of that
//! colour round them, as the user chose it (design 1796 v6, "S").
//!
//! Both are worked out here, without a window, so the two hosts draw the
//! same thing from the same numbers (`look::project_mark`):
//!
//! - [`shapes`] are the pages, on the glyphs' 14-unit artboard, as
//!   [`glyph`](crate::glyph) shapes: filled in order, a level of 0 cutting
//!   a hole. The back page is drawn only where the front one is not.
//! - [`glow`] is how much glow each pixel round the mark gets, 0 to 1. Only
//!   this coverage is blurred; the colour is the project's everywhere. It
//!   is laid on with screen -- `out = bg + (screen(bg, c) - bg) * a` -- which
//!   never makes a pixel darker than what is under it. A glow blurred as a
//!   colour with straight alpha, or laid on with source-over, is the grey
//!   ring the user saw on light tabs in v5.
//! - [`strength`] is how strong a mark is in each state: a tab not in front
//!   has its mark mixed toward the tab's ground, and its glow is that much
//!   weaker.
//!
//! The macOS host has the same as `ProjectMark.swift`;
//! `tools/control-room-hosts-agree.py` holds the two to one table.

use crate::glyph::{Outline, Shape};
use crate::look::project_mark as pm;
use crate::look::{status, Rgba};

/// Which tab a mark is on, as far as its strength goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Rest,
    Hover,
    Selected,
}

impl State {
    pub const ALL: [State; 3] = [State::Rest, State::Hover, State::Selected];

    pub fn name(self) -> &'static str {
        match self {
            State::Rest => "rest",
            State::Hover => "hover",
            State::Selected => "selected",
        }
    }
}

/// How much of the project's colour a mark in `state` has, 0 to 1.
pub fn strength(state: State, dark: bool) -> f64 {
    match (state, dark) {
        (State::Selected, _) => pm::SELECTED,
        (State::Hover, true) => pm::HOVER_DARK,
        (State::Hover, false) => pm::HOVER_LIGHT,
        (State::Rest, true) => pm::REST_DARK,
        (State::Rest, false) => pm::REST_LIGHT,
    }
}

/// `c` mixed `amount` of the way from `ground` toward it: the colour a
/// mark in a state is drawn in, on a ground the host knows.
pub fn toward(ground: Rgba, c: Rgba, amount: f64) -> Rgba {
    let t = amount.clamp(0.0, 1.0);
    let mix = |g: u8, v: u8| (g as f64 + (v as f64 - g as f64) * t).round().clamp(0.0, 255.0) as u8;
    Rgba { r: mix(ground.r, c.r), g: mix(ground.g, c.g), b: mix(ground.b, c.b), a: 1.0 }
}

/// The two pages, on the artboard (`status::ARTBOARD` units a side).
pub fn shapes() -> Vec<Shape> {
    let ring = |x0: f64, y0: f64, x1: f64, y1: f64| {
        let (w, l) = (x1 - x0, pm::LINE);
        [
            Shape { outline: Outline::RoundRect(x0, y0, w, y1 - y0, pm::PAGE_RADIUS), level: 1.0 },
            Shape { outline: Outline::RoundRect(x0 + l, y0 + l, w - 2.0 * l, y1 - y0 - 2.0 * l, (pm::PAGE_RADIUS - l).max(0.0)), level: 0.0 },
        ]
    };
    let k = pm::FRONT_CLEAR;
    let mut out = Vec::new();
    out.extend(ring(pm::BACK_X0, pm::BACK_Y0, pm::BACK_X1, pm::BACK_Y1));
    // The back page stops short of the front one, so the glow shows inside
    // the front page too.
    out.push(Shape {
        outline: Outline::RoundRect(
            pm::FRONT_X0 - k,
            pm::FRONT_Y0 - k,
            pm::FRONT_X1 - pm::FRONT_X0 + 2.0 * k,
            pm::FRONT_Y1 - pm::FRONT_Y0 + 2.0 * k,
            pm::PAGE_RADIUS + k,
        ),
        level: 0.0,
    });
    out.extend(ring(pm::FRONT_X0, pm::FRONT_Y0, pm::FRONT_X1, pm::FRONT_Y1));
    out
}

/// How much glow each pixel round a mark gets, in a square of `side`
/// pixels whose top left is `reach` points above and left of the mark's.
#[derive(Clone, Debug, PartialEq)]
pub struct Glow {
    /// Points from the glow's square to the mark's, on each side.
    pub reach: f64,
    /// Pixels a side.
    pub side: usize,
    /// Row by row from the top, 0 to 1.
    pub a: Vec<f64>,
}

impl Glow {
    /// The coverage at pixel `(x, y)`; 0 outside.
    pub fn at(&self, x: usize, y: usize) -> f64 {
        if x < self.side && y < self.side {
            self.a[y * self.side + x]
        } else {
            0.0
        }
    }

    /// Every pixel's coverage added up: one number to compare two hosts by.
    pub fn total(&self) -> f64 {
        self.a.iter().sum()
    }
}

/// Points round the mark's square that the glow can reach: its circle and
/// three of its blur's sigmas, whole.
pub fn reach() -> f64 {
    (pm::GLOW_RADIUS + 3.0 * pm::GLOW_BLUR - status::ARTBOARD / 2.0).ceil()
}

/// The glow of a mark drawn `scale` pixels a point, at `strength`
/// ([`strength`]).
pub fn glow(scale: f64, strength: f64) -> Glow {
    let reach = reach();
    let span = status::ARTBOARD + 2.0 * reach;
    let side = (span * scale).ceil() as usize;
    // A pixel's middle, in points from the mark's top left.
    let pt = |i: usize| (i as f64 + 0.5) / scale - reach;
    let mid = status::ARTBOARD / 2.0;

    let mut disc = vec![0.0; side * side];
    let mut core = vec![0.0; side * side];
    let (g, cr) = (pm::CORE_GAP, pm::CORE_RADIUS);
    let half = mid + g;
    for y in 0..side {
        for x in 0..side {
            let (px, py) = (pt(x), pt(y));
            let d = ((px - mid).powi(2) + (py - mid).powi(2)).sqrt();
            disc[y * side + x] = ((pm::GLOW_RADIUS - d) * scale + 0.5).clamp(0.0, 1.0);
            // The signed distance to the core's rounded square.
            let qx = (px - mid).abs() - (half - cr);
            let qy = (py - mid).abs() - (half - cr);
            let outside = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt();
            let sd = outside + qx.max(qy).min(0.0) - cr;
            core[y * side + x] = (0.5 - sd * scale).clamp(0.0, 1.0);
        }
    }
    let disc = blur(&disc, side, pm::GLOW_BLUR * scale);
    let core = blur(&core, side, pm::CORE_BLUR * scale);
    let k = pm::GLOW_STRENGTH * strength;
    let a = disc.iter().zip(&core).map(|(d, c)| (d * k * (1.0 - c * (1.0 - pm::CORE_KEEP))).clamp(0.0, 1.0)).collect();
    Glow { reach, side, a }
}

/// A Gaussian blur of `sigma` pixels, across and then down; what is past
/// the edge counts as 0.
fn blur(v: &[f64], side: usize, sigma: f64) -> Vec<f64> {
    if sigma <= 0.0 {
        return v.to_vec();
    }
    let r = (3.0 * sigma).ceil() as i64;
    let mut kernel: Vec<f64> = (-r..=r).map(|i| (-((i * i) as f64) / (2.0 * sigma * sigma)).exp()).collect();
    let sum: f64 = kernel.iter().sum();
    for w in &mut kernel {
        *w /= sum;
    }
    let pass = |src: &[f64], across: bool| {
        let mut out = vec![0.0; side * side];
        for y in 0..side {
            for x in 0..side {
                let mut acc = 0.0;
                for (j, w) in kernel.iter().enumerate() {
                    let o = j as i64 - r;
                    let (sx, sy) = if across { (x as i64 + o, y as i64) } else { (x as i64, y as i64 + o) };
                    if sx >= 0 && sy >= 0 && (sx as usize) < side && (sy as usize) < side {
                        acc += w * src[sy as usize * side + sx as usize];
                    }
                }
                out[y * side + x] = acc;
            }
        }
        out
    };
    pass(&pass(v, true), false)
}

/// Screen `c` onto `bg` by `a`: `bg + (screen(bg, c) - bg) * a`, which is
/// never darker than `bg` in any channel.
pub fn screen(bg: (u8, u8, u8), c: Rgba, a: f64) -> (u8, u8, u8) {
    let one = |b: u8, v: u8| {
        let (b, v) = (b as f64 / 255.0, v as f64 / 255.0);
        let s = 1.0 - (1.0 - b) * (1.0 - v);
        ((b + (s - b) * a.clamp(0.0, 1.0)) * 255.0).round().clamp(0.0, 255.0) as u8
    };
    (one(bg.0, c.r), one(bg.1, c.g), one(bg.2, c.b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_glow_is_round_and_strongest_off_the_mark_and_none_at_its_edge() {
        let g = glow(2.0, 1.0);
        assert_eq!(g.side, ((status::ARTBOARD + 2.0 * g.reach) * 2.0).ceil() as usize);
        let n = g.side;
        // Symmetric both ways: the same glow on every side of the mark.
        for y in 0..n {
            for x in 0..n {
                assert!((g.at(x, y) - g.at(n - 1 - x, y)).abs() < 1e-9);
                assert!((g.at(x, y) - g.at(x, n - 1 - y)).abs() < 1e-9);
            }
        }
        // Nothing reaches the square's edge.
        for i in 0..n {
            assert!(g.at(i, 0) < 1e-3 && g.at(0, i) < 1e-3, "the edge has glow at {i}");
        }
        // In the clear core only `core_keep` of it is left: less there than
        // just outside the core.
        let mid = n / 2;
        let core_px = ((g.reach + status::ARTBOARD / 2.0) * 2.0) as usize;
        let outside = ((g.reach - pm::CORE_GAP - 0.75) * 2.0) as usize;
        assert!(g.at(mid, core_px) < g.at(mid, outside), "core {} outside {}", g.at(mid, core_px), g.at(mid, outside));
        assert!(g.at(mid, core_px) > 0.0, "some is kept under the mark");
        // Never more than the glow's strength.
        assert!(g.a.iter().all(|a| *a <= pm::GLOW_STRENGTH + 1e-9));
    }

    #[test]
    fn a_weaker_state_is_a_weaker_glow() {
        let full = glow(1.0, 1.0).total();
        let rest = glow(1.0, strength(State::Rest, true)).total();
        assert!((rest / full - pm::REST_DARK).abs() < 1e-9);
    }

    #[test]
    fn screen_never_darkens() {
        let c = Rgba { r: 42, g: 123, b: 218, a: 1.0 };
        for bg in [(0, 0, 0), (34, 39, 46), (240, 241, 242), (255, 255, 255), (200, 20, 90)] {
            for a in [0.0, 0.3, 1.0] {
                let out = screen(bg, c, a);
                assert!(out.0 >= bg.0 && out.1 >= bg.1 && out.2 >= bg.2, "{bg:?} {a} -> {out:?}");
            }
        }
        assert_eq!(screen((10, 20, 30), c, 0.0), (10, 20, 30));
    }

    #[test]
    fn the_front_page_is_drawn_last_and_cuts_the_back_one() {
        let s = shapes();
        assert_eq!(s.len(), 5);
        assert_eq!(s.iter().map(|s| s.level).collect::<Vec<_>>(), vec![1.0, 0.0, 0.0, 1.0, 0.0]);
    }

    #[test]
    fn toward_goes_from_the_ground_to_the_colour() {
        let (g, c) = (Rgba { r: 0, g: 100, b: 200, a: 1.0 }, Rgba { r: 200, g: 100, b: 0, a: 1.0 });
        assert_eq!(toward(g, c, 0.0), g);
        assert_eq!(toward(g, c, 1.0), c);
        assert_eq!(toward(g, c, 0.5), Rgba { r: 100, g: 100, b: 100, a: 1.0 });
    }
}
