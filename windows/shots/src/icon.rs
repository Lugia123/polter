//! Drawing one icon of the screenshot toolbar into a button cell
//! (`dev-docs/poltergeist/screenshot.md`, 9.8.5).
//!
//! The icons are data ([`crate::look`], generated from
//! `src/input/screenshot-look.json`) and this is the one rule that turns
//! them into pixels. The macOS host has the same rule in
//! `ShotIconRaster.swift` and the generator has it in Python; the three do
//! the arithmetic in the same order, and each host's test is that its own
//! answer is the generator's ([`crate::look::Icon::ink`]). That is what
//! makes the two toolbars one toolbar: GDI has no anti-aliasing and no
//! round joins, CoreGraphics has both, and drawing the same shapes with
//! each would give two sets of icons that only resemble one another.
//!
//! **The rule.** The 24-unit artboard is `points * scale` pixels on a side,
//! centred in the cell. A pixel's coverage by a part is the share of its
//! sixteen sample points -- a 4 x 4 grid -- that are inside the fill
//! (even-odd), or within half the stroke's width of the path, which is
//! exactly what a stroke with round caps and round joins is. A curve is
//! sixteen straight pieces. Parts are laid over one another in order.
//!
//! What comes out is coverage, not colour: the caller tints it.

use crate::look::{icon_grid, Cmd, Icon, Paint};

/// A curve becomes this many straight pieces.
const CUBIC_STEPS: usize = 16;
/// A pixel is sampled on a grid this many points on a side.
const GRID: usize = 4;

/// An icon's coverage: `cell * cell` bytes, top row first, 0 to 255.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mask {
    pub cell: i32,
    pub alpha: Vec<u8>,
}

/// The box of the pixels at least half covered, and how many there are.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InkBox {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub count: i32,
}

type Seg = (f64, f64, f64, f64);

/// Each subpath as points in pixels, and whether it was closed.
fn polylines(cmds: &[Cmd], f: f64, off: f64) -> Vec<(Vec<(f64, f64)>, bool)> {
    let mut subs: Vec<(Vec<(f64, f64)>, bool)> = Vec::new();
    for c in cmds {
        match *c {
            Cmd::Move(x, y) => subs.push((vec![(x * f + off, y * f + off)], false)),
            Cmd::Line(x, y) => {
                if let Some(cur) = subs.last_mut() {
                    cur.0.push((x * f + off, y * f + off));
                }
            }
            Cmd::Cubic(ax, ay, bx, by, ex, ey) => {
                let Some(cur) = subs.last_mut() else { continue };
                let Some(&(x0, y0)) = cur.0.last() else { continue };
                let (x1, y1) = (ax * f + off, ay * f + off);
                let (x2, y2) = (bx * f + off, by * f + off);
                let (x3, y3) = (ex * f + off, ey * f + off);
                for s in 1..=CUBIC_STEPS {
                    let t = s as f64 / CUBIC_STEPS as f64;
                    let u = 1.0 - t;
                    let a = u * u * u;
                    let b = 3.0 * u * u * t;
                    let cc = 3.0 * u * t * t;
                    let d = t * t * t;
                    cur.0.push((a * x0 + b * x1 + cc * x2 + d * x3, a * y0 + b * y1 + cc * y2 + d * y3));
                }
            }
            Cmd::Close => {
                if let Some(cur) = subs.last_mut() {
                    cur.1 = true;
                }
            }
        }
    }
    subs
}

/// The pieces of the subpaths; `close_all` joins every end to its start,
/// which is what a fill does with a path nobody closed.
fn segments(subs: &[(Vec<(f64, f64)>, bool)], close_all: bool) -> Vec<Seg> {
    let mut segs = Vec::new();
    for (pts, closed) in subs {
        for pair in pts.windows(2) {
            segs.push((pair[0].0, pair[0].1, pair[1].0, pair[1].1));
        }
        if (*closed || close_all) && pts.len() > 1 {
            let (last, first) = (pts[pts.len() - 1], pts[0]);
            segs.push((last.0, last.1, first.0, first.1));
        }
    }
    segs
}

/// The square of the distance from a point to a piece.
fn dist2(px: f64, py: f64, seg: &Seg) -> f64 {
    let (x1, y1, x2, y2) = *seg;
    let (dx, dy) = (x2 - x1, y2 - y1);
    let ll = dx * dx + dy * dy;
    let mut t = 0.0;
    if ll > 0.0 {
        t = ((px - x1) * dx + (py - y1) * dy) / ll;
        if t < 0.0 {
            t = 0.0;
        } else if t > 1.0 {
            t = 1.0;
        }
    }
    let (ex, ey) = (x1 + t * dx - px, y1 + t * dy - py);
    ex * ex + ey * ey
}

/// Even-odd: whether a ray to the right crosses the edges an odd number of
/// times.
fn inside(px: f64, py: f64, edges: &[Seg]) -> bool {
    let mut odd = false;
    for &(x1, y1, x2, y2) in edges {
        if (y1 > py) != (y2 > py) && px < (x2 - x1) * (py - y1) / (y2 - y1) + x1 {
            odd = !odd;
        }
    }
    odd
}

/// `icon` drawn into a cell `cell` pixels on a side, on a display scaled by
/// `scale`. A cell smaller than the artboard cuts the icon off; it is not
/// made to fit.
pub fn mask(icon: &Icon, cell: i32, scale: f64) -> Mask {
    let cell = cell.max(0);
    let side = cell as usize;
    let f = icon_grid::POINTS * scale / icon_grid::ARTBOARD;
    let off = (cell as f64 - icon_grid::POINTS * scale) / 2.0;
    let mut alpha = vec![0.0f64; side * side];
    for part in icon.parts {
        let subs = polylines(part.cmds, f, off);
        let fill = matches!(part.paint, Paint::Fill | Paint::FillAndStroke);
        let stroke = matches!(part.paint, Paint::Stroke | Paint::FillAndStroke);
        let half = if stroke { part.width * f / 2.0 } else { 0.0 };
        let half2 = half * half;
        let outline = segments(&subs, false);
        let edges = if fill { segments(&subs, true) } else { Vec::new() };

        // Nothing of the part is outside its points' box grown by half the
        // stroke, so only those pixels are looked at.
        let (mut l, mut t, mut r, mut b) = (f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
        for (pts, _) in &subs {
            for &(x, y) in pts {
                l = l.min(x);
                t = t.min(y);
                r = r.max(x);
                b = b.max(y);
            }
        }
        if !l.is_finite() {
            continue;
        }
        let x_lo = ((l - half).floor() as i64).max(0) as usize;
        let x_hi = ((r + half).ceil() as i64).clamp(0, side as i64) as usize;
        let y_lo = ((t - half).floor() as i64).max(0) as usize;
        let y_hi = ((b + half).ceil() as i64).clamp(0, side as i64) as usize;

        for py in y_lo..y_hi {
            for px in x_lo..x_hi {
                let mut hits = 0usize;
                for j in 0..GRID {
                    for i in 0..GRID {
                        let sx = px as f64 + (i as f64 + 0.5) / GRID as f64;
                        let sy = py as f64 + (j as f64 + 0.5) / GRID as f64;
                        let mut on = fill && inside(sx, sy, &edges);
                        if !on && stroke {
                            on = outline.iter().any(|s| dist2(sx, sy, s) <= half2);
                        }
                        if on {
                            hits += 1;
                        }
                    }
                }
                if hits > 0 {
                    let cov = hits as f64 / (GRID * GRID) as f64 * part.opacity;
                    let k = py * side + px;
                    alpha[k] = alpha[k] + cov * (1.0 - alpha[k]);
                }
            }
        }
    }
    Mask { cell, alpha: alpha.iter().map(|a| (a * 255.0 + 0.5).floor() as u8).collect() }
}

impl Mask {
    /// Where the ink is: the pixels at least half covered. All zeros when
    /// there are none.
    pub fn ink(&self) -> InkBox {
        let side = self.cell.max(0) as usize;
        let (mut x0, mut y0, mut x1, mut y1, mut n) = (side as i32, side as i32, -1, -1, 0);
        for y in 0..side {
            for x in 0..side {
                if self.alpha[y * side + x] >= 128 {
                    n += 1;
                    x0 = x0.min(x as i32);
                    x1 = x1.max(x as i32);
                    y0 = y0.min(y as i32);
                    y1 = y1.max(y as i32);
                }
            }
        }
        if n == 0 {
            return InkBox { x: 0, y: 0, w: 0, h: 0, count: 0 };
        }
        InkBox { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1, count: n }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look;
    use crate::style;

    /// How far this rasteriser's box may be from the generator's, in pixels
    /// on each edge, and how far the count of inked pixels may be, as a
    /// share. The three implementations do the same arithmetic, so the
    /// expected difference is none; the allowance is for a platform whose
    /// floating point rounds one sample the other way.
    const EDGE: i32 = 1;
    const COUNT: f64 = 0.02;

    #[test]
    fn every_icon_lands_where_the_generator_says() {
        assert_eq!(look::ICONS.len(), 20, "fifteen buttons and five sizes of T");
        let mut exact = 0;
        let mut total = 0;
        for icon in look::ICONS {
            assert_eq!(icon.ink.len(), 3, "{}: scales 1, 1.5 and 2", icon.key);
            for want in icon.ink {
                assert_eq!(want.cell, style::px(look::size::BUTTON as u32, want.scale), "{}: the cell", icon.key);
                let got = mask(icon, want.cell, want.scale).ink();
                let at = format!("{} at scale {}", icon.key, want.scale);
                assert!((got.x - want.x).abs() <= EDGE, "{at}: left {} for {}", got.x, want.x);
                assert!((got.y - want.y).abs() <= EDGE, "{at}: top {} for {}", got.y, want.y);
                assert!(
                    ((got.x + got.w) - (want.x + want.w)).abs() <= EDGE,
                    "{at}: right {} for {}",
                    got.x + got.w,
                    want.x + want.w
                );
                assert!(
                    ((got.y + got.h) - (want.y + want.h)).abs() <= EDGE,
                    "{at}: bottom {} for {}",
                    got.y + got.h,
                    want.y + want.h
                );
                let off = (got.count - want.count).abs() as f64;
                assert!(off <= want.count as f64 * COUNT, "{at}: {} inked pixels for {}", got.count, want.count);
                total += 1;
                if (got.x, got.y, got.w, got.h, got.count) == (want.x, want.y, want.w, want.h, want.count) {
                    exact += 1;
                }
            }
        }
        // The allowance above is for another platform. Here the answer is
        // the generator's to the pixel, and a build where it stops being so
        // has changed the rule.
        assert_eq!(exact, total, "{exact} of {total} boxes are the generator's exactly");
    }

    #[test]
    fn the_ink_is_centred_in_the_cell_and_stays_inside_it() {
        for key in look::TOOLBAR_ICONS {
            let icon = look::icon(key).unwrap();
            let m = mask(icon, 56, 2.0);
            let ink = m.ink();
            // The artboard is 40 px in a 56 px cell: 8 px of margin, less
            // the half unit of slack the live area leaves.
            assert!(ink.x >= 8 && ink.y >= 8, "{key}: starts at ({}, {})", ink.x, ink.y);
            assert!(ink.x + ink.w <= 48 && ink.y + ink.h <= 48, "{key}: ends at ({}, {})", ink.x + ink.w, ink.y + ink.h);
        }
    }

    #[test]
    fn the_five_sizes_of_t_grow() {
        let boxes: Vec<InkBox> =
            look::FONT_ICONS.iter().map(|k| mask(look::icon(k).unwrap(), 56, 2.0).ink()).collect();
        assert_eq!(boxes.len(), 5);
        for pair in boxes.windows(2) {
            assert!(pair[1].w > pair[0].w && pair[1].h > pair[0].h, "{pair:?}");
        }
    }

    #[test]
    fn a_stroke_is_as_wide_as_it_is_told_to_be() {
        // The straight line runs corner to corner; across its middle the ink
        // is the stroke's width along the diagonal: 1.75 units * 40 / 24 px,
        // times the square root of two along a row.
        let m = mask(look::icon("line").unwrap(), 56, 2.0);
        let row = 28;
        let inked = (0..56).filter(|x| m.alpha[row * 56 + x] >= 128).count();
        let want = look::icon_grid::STROKE * 40.0 / 24.0 * std::f64::consts::SQRT_2;
        assert!((inked as f64 - want).abs() <= 1.0, "{inked} px across for {want:.2}");
    }

    #[test]
    fn the_pointer_is_solid_and_the_rectangle_is_hollow() {
        let share = |key: &str| {
            let ink = mask(look::icon(key).unwrap(), 56, 2.0).ink();
            ink.count as f64 / (ink.w * ink.h) as f64
        };
        assert!(share("select") >= 0.45, "select fills {:.2} of its box", share("select"));
        assert!(share("rect") <= 0.45, "rect fills {:.2} of its box", share("rect"));
    }

    #[test]
    fn a_fainter_part_is_fainter() {
        // The mosaic's corner squares are solid and its edge squares 38%.
        let m = mask(look::icon("mosaic").unwrap(), 56, 2.0);
        let at = |ux: f64, uy: f64| m.alpha[(8.0 + uy * 40.0 / 24.0) as usize * 56 + (8.0 + ux * 40.0 / 24.0) as usize];
        assert_eq!(at(6.0, 6.0), 255);
        assert_eq!(at(12.0, 6.0), (0.38f64 * 255.0 + 0.5).floor() as u8);
        assert_eq!(at(0.5, 0.5), 0);
    }

    #[test]
    fn nothing_is_drawn_into_no_cell() {
        let m = mask(look::icon("done").unwrap(), 0, 2.0);
        assert!(m.alpha.is_empty());
        assert_eq!(m.ink(), InkBox { x: 0, y: 0, w: 0, h: 0, count: 0 });
    }
}
