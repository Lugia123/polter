//! The frosted glass outside the selection, and putting a frame together
//! out of it (`dev-docs/poltergeist/screenshot.md`, 9.8.6 to 9.8.9).
//!
//! Outside the selection the frozen picture is blurred and a little darker;
//! inside it is the picture itself. **None of that is the system's
//! compositor**: what is blurred is the frozen picture's own pixels, here,
//! so the two hosts get the same thing and it does not depend on which
//! Windows this is.
//!
//! The blur is done **once**, when the screenshot begins ([`Glass::new`]).
//! Dragging a selection only ever copies: the blurred picture where the
//! hole is not, the frozen one where it is ([`Glass::frame`]), and only in
//! the rectangle that can have changed since the frame before ([`dirty`]).
//! A frame that blurred anything would be late, and a selection whose clear
//! part lags its own outline is the thing this is built to never show.
//!
//! The Gaussian is the one the specification gives, the same on both hosts:
//! shrink by `k`, three box blurs of radius `r` each way, stretch back with
//! bilinear interpolation. `k` and `r` come from the scale ([`factor`],
//! [`radius`]) and the sigmas from `look.rs`.

use crate::geom::Rect;
use crate::look::{colour, glass};
use crate::pixels::blit_part;

/// How many times smaller the picture is made before it is blurred.
pub fn factor(scale: f64) -> usize {
    if scale >= glass::DOWNSAMPLE_SCALE_AT_LEAST {
        glass::DOWNSAMPLE_HI as usize
    } else {
        glass::DOWNSAMPLE_LO as usize
    }
}

/// The radius of each box blur, on the picture made `k` times smaller, for
/// a Gaussian of `sigma` points: three boxes `2r + 1` wide one after
/// another have a variance of `((2r + 1)^2 - 1) / 4`.
pub fn radius(sigma: f64, scale: f64) -> usize {
    let s = sigma * scale / factor(scale) as f64;
    ((((4.0 * s * s + 1.0).sqrt() - 1.0) / 2.0).round() as usize).max(1)
}

/// `src` (`w` by `h`, B G R X) made `k` times smaller: each pixel the
/// average of a `k` by `k` block. A block that hangs over the right or the
/// bottom edge is the average of the part of it there is.
pub fn downsample(src: &[u8], w: usize, h: usize, k: usize) -> (Vec<u8>, usize, usize) {
    let k = k.max(1);
    let (sw, sh) = (w.div_ceil(k), h.div_ceil(k));
    let mut out = vec![255u8; sw * sh * 4];
    for sy in 0..sh {
        let (y0, y1) = (sy * k, ((sy + 1) * k).min(h));
        for sx in 0..sw {
            let (x0, x1) = (sx * k, ((sx + 1) * k).min(w));
            let mut sum = [0u32; 3];
            for y in y0..y1 {
                for p in src[(y * w + x0) * 4..(y * w + x1) * 4].chunks_exact(4) {
                    sum[0] += p[0] as u32;
                    sum[1] += p[1] as u32;
                    sum[2] += p[2] as u32;
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let d = (sy * sw + sx) * 4;
            for c in 0..3 {
                out[d + c] = ((sum[c] + n / 2) / n) as u8;
            }
        }
    }
    (out, sw, sh)
}

/// One box blur along one line of `n` pixels `stride` bytes apart: a
/// sliding sum, so its cost does not depend on `r`. Past either end the
/// line goes on as its last pixel.
fn box_line(src: &[u8], dst: &mut [u8], n: usize, stride: usize, r: usize) {
    let win = (2 * r + 1) as u32;
    let at = |i: isize| (i.clamp(0, n as isize - 1) as usize) * stride;
    for c in 0..3 {
        let mut sum: u32 = (-(r as isize)..=r as isize).map(|i| src[at(i) + c] as u32).sum();
        for i in 0..n {
            dst[i * stride + c] = ((sum + win / 2) / win) as u8;
            sum += src[at(i as isize + r as isize + 1) + c] as u32;
            sum -= src[at(i as isize - r as isize) + c] as u32;
        }
    }
}

/// `passes` box blurs of radius `r`, each across and then down, in place.
pub fn box_blur(img: &mut [u8], w: usize, h: usize, r: usize, passes: usize) {
    if w == 0 || h == 0 || img.len() != w * h * 4 {
        return;
    }
    let mut tmp = img.to_vec();
    for _ in 0..passes {
        for y in 0..h {
            box_line(&img[y * w * 4..(y + 1) * w * 4], &mut tmp[y * w * 4..(y + 1) * w * 4], w, 4, r);
        }
        for x in 0..w {
            box_line(&tmp[x * 4..], &mut img[x * 4..], h, w * 4, r);
        }
    }
}

/// `src` (`sw` by `sh`), which is a picture made `k` times smaller,
/// stretched back to `w` by `h` with bilinear interpolation, every channel
/// then put through `tone` (a table of 256). The rows are shared out among
/// `threads` threads: this is most of what the blur costs, and each row is
/// its own.
pub fn upsample(src: &[u8], sw: usize, sh: usize, w: usize, h: usize, k: usize, tone: &[u8; 256], threads: usize) -> Vec<u8> {
    let mut out = vec![255u8; w * h * 4];
    if sw == 0 || sh == 0 || w == 0 || h == 0 {
        return out;
    }
    // Where pixel `i` of the big picture is on the small one, in 256ths:
    // the centre of the small pixel it came from is at `(i + 0.5) / k - 0.5`.
    let place = |i: usize, n: usize| {
        let f = ((i * 256 + 128) / k) as isize - 128;
        let f = f.clamp(0, (n as isize - 1) * 256) as usize;
        (f >> 8, ((f >> 8) + 1).min(n - 1), (f & 255) as u32)
    };
    let columns: Vec<(usize, usize, u32)> = (0..w).map(|x| place(x, sw)).collect();
    let rows = |first: usize, band: &mut [u8]| {
        for (dy, line) in band.chunks_exact_mut(w * 4).enumerate() {
            let (y0, y1, wy) = place(first + dy, sh);
            let (r0, r1) = (&src[y0 * sw * 4..(y0 + 1) * sw * 4], &src[y1 * sw * 4..(y1 + 1) * sw * 4]);
            for (px, (x0, x1, wx)) in line.chunks_exact_mut(4).zip(&columns) {
                for c in 0..3 {
                    let a = r0[x0 * 4 + c] as u32 * (256 - wx) + r0[x1 * 4 + c] as u32 * wx;
                    let b = r1[x0 * 4 + c] as u32 * (256 - wx) + r1[x1 * 4 + c] as u32 * wx;
                    px[c] = tone[((a * (256 - wy) + b * wy + (1 << 15)) >> 16) as usize];
                }
            }
        }
    };
    let threads = threads.clamp(1, h);
    if threads == 1 {
        rows(0, &mut out);
    } else {
        let per = h.div_ceil(threads);
        std::thread::scope(|s| {
            for (i, band) in out.chunks_mut(per * w * 4).enumerate() {
                let rows = &rows;
                s.spawn(move || rows(i * per, band));
            }
        });
    }
    out
}

/// What a channel becomes under black laid over it at `alpha`.
fn darker(alpha: f64) -> [u8; 256] {
    std::array::from_fn(|c| (c as f64 * (1.0 - alpha)).round() as u8)
}

/// How many threads the one blur at the start is shared among.
pub fn threads() -> usize {
    std::thread::available_parallelism().map_or(1, |n| n.get()).min(8)
}

/// What a monitor's overlay is put together from, made once when the
/// screenshot begins and dropped with it.
pub struct Glass {
    rect: Rect,
    /// What is shown outside the hole, as large as the monitor: the frozen
    /// picture blurred and darkened -- or only darkened ([`Glass::plain`]).
    outside: Vec<u8>,
    /// The frozen picture `k` times smaller, not blurred: what the toolbar's
    /// plate, the tooltip and the labels are made of (9.8.6.2).
    small: Vec<u8>,
    small_size: (usize, usize),
    k: usize,
    /// Whether `outside` is blurred. Not, when the system asks for less
    /// transparency.
    frosted: bool,
}

impl Glass {
    /// For the frozen picture `bgrx` of the monitor at `rect`, at `scale`.
    /// `None` when `bgrx` is not that monitor's size.
    ///
    /// **This is the one place anything is blurred.** It takes tens of
    /// milliseconds for a large monitor (the benchmark at the end of this
    /// file), which a session's first frame can wait for and no other frame
    /// may.
    pub fn new(rect: Rect, bgrx: &[u8], scale: f64) -> Option<Glass> {
        let (w, h) = (rect.w.max(0) as usize, rect.h.max(0) as usize);
        if w == 0 || h == 0 || bgrx.len() != w * h * 4 {
            return None;
        }
        let k = factor(scale);
        let (small, sw, sh) = downsample(bgrx, w, h, k);
        let mut soft = small.clone();
        box_blur(&mut soft, sw, sh, radius(glass::OUTSIDE_BLUR_SIGMA, scale), glass::BOX_PASSES as usize);
        let outside = upsample(&soft, sw, sh, w, h, k, &darker(colour::OUTSIDE_DIM.a), threads());
        Some(Glass { rect, outside, small, small_size: (sw, sh), k, frosted: true })
    }

    /// The same without the blur, for a system that asks for less
    /// transparency: outside the hole the picture is only darker, and by
    /// more (9.8.10). Nothing is made smaller, so there is no `small`.
    pub fn plain(rect: Rect, bgrx: &[u8]) -> Option<Glass> {
        let (w, h) = (rect.w.max(0) as usize, rect.h.max(0) as usize);
        if w == 0 || h == 0 || bgrx.len() != w * h * 4 {
            return None;
        }
        let tone = darker(colour::OUTSIDE_DIM_OPAQUE.a);
        let mut outside = bgrx.to_vec();
        for px in outside.chunks_exact_mut(4) {
            for c in &mut px[..3] {
                *c = tone[*c as usize];
            }
            px[3] = 255;
        }
        Some(Glass { rect, outside, small: Vec::new(), small_size: (0, 0), k: 1, frosted: false })
    }

    pub fn rect(&self) -> Rect {
        self.rect
    }

    pub fn is_frosted(&self) -> bool {
        self.frosted
    }

    /// The frozen picture made smaller, its size, and by how much: for the
    /// plates. Empty for [`Glass::plain`].
    pub fn small(&self) -> (&[u8], (usize, usize), usize) {
        (&self.small, self.small_size, self.k)
    }

    /// The glass a plate at `rect` is made of -- the toolbar's, a tooltip's,
    /// a label's -- as a picture of `rect`'s size (9.8.6.2): the frozen
    /// picture under it blurred by twelve points, its colours made stronger
    /// by half, its brightness halved, and the plate's tint laid over that.
    /// Whatever is under it, the result is between about `#131415` and
    /// `#3E4041`, which is what white ink is drawn on.
    ///
    /// Blurred from the picture made smaller, not from what is shown
    /// outside the selection: this blur is four times wider, and only the
    /// plate's few pixels are worked on. Without frost
    /// ([`Glass::plain`]) the plate is its opaque colour.
    pub fn plate(&self, rect: Rect, scale: f64) -> Vec<u8> {
        let (w, h) = (rect.w.max(0) as usize, rect.h.max(0) as usize);
        let mut out = vec![255u8; w * h * 4];
        if !self.frosted || self.small.is_empty() {
            let c = colour::PLATE_OPAQUE;
            out.chunks_exact_mut(4).for_each(|p| p.copy_from_slice(&[c.b, c.g, c.r, 255]));
            return out;
        }
        let (sw, sh) = self.small_size;
        let (k, r) = (self.k as i32, radius(glass::PLATE_BLUR_SIGMA, scale));
        // The part of the small picture under the plate, and as far round
        // it as three blurs of `r` reach.
        let reach = 3 * r as i32 + 1;
        let local = rect.relative_to(self.rect.origin());
        let x0 = (local.x.div_euclid(k) - reach).clamp(0, sw as i32 - 1);
        let y0 = (local.y.div_euclid(k) - reach).clamp(0, sh as i32 - 1);
        let x1 = ((local.right() + k - 1).div_euclid(k) + reach).clamp(x0 + 1, sw as i32);
        let y1 = ((local.bottom() + k - 1).div_euclid(k) + reach).clamp(y0 + 1, sh as i32);
        let (pw, ph) = ((x1 - x0) as usize, (y1 - y0) as usize);
        let mut part = vec![255u8; pw * ph * 4];
        for y in 0..ph {
            let from = ((y0 as usize + y) * sw + x0 as usize) * 4;
            part[y * pw * 4..(y + 1) * pw * 4].copy_from_slice(&self.small[from..from + pw * 4]);
        }
        box_blur(&mut part, pw, ph, r, glass::BOX_PASSES as usize);

        let tint = colour::PLATE_TINT;
        let place = |i: i32, first: i32, n: usize| {
            let f = ((i as f64 + 0.5) / k as f64 - 0.5 - first as f64).clamp(0.0, n as f64 - 1.0);
            (f.floor() as usize, (f.floor() as usize + 1).min(n - 1), f.fract())
        };
        for y in 0..h {
            let (ya, yb, wy) = place(local.y + y as i32, y0, ph);
            for x in 0..w {
                let (xa, xb, wx) = place(local.x + x as i32, x0, pw);
                let mut bgr = [0f64; 3];
                for (c, v) in bgr.iter_mut().enumerate() {
                    let at = |px: usize, py: usize| part[(py * pw + px) * 4 + c] as f64;
                    *v = (at(xa, ya) * (1.0 - wx) + at(xb, ya) * wx) * (1.0 - wy) + (at(xa, yb) * (1.0 - wx) + at(xb, yb) * wx) * wy;
                }
                let luma = glass::LUMA_B * bgr[0] + glass::LUMA_G * bgr[1] + glass::LUMA_R * bgr[2];
                let d = (y * w + x) * 4;
                for (c, ink) in [tint.b, tint.g, tint.r].into_iter().enumerate() {
                    let strong = ((luma + (bgr[c] - luma) * glass::PLATE_SATURATION) * glass::PLATE_BRIGHTNESS).clamp(0.0, 255.0);
                    out[d + c] = (strong * (1.0 - tint.a) + ink as f64 * tint.a).round() as u8;
                }
            }
        }
        out
    }

    /// Put the part `area` of one frame into `dst`, a buffer covering
    /// `dst_rect`: the blurred picture, and `original` -- the frozen
    /// picture, a buffer covering this monitor -- wherever `hole` is.
    /// **Copies and nothing else.** Nothing outside `area` is written.
    pub fn frame(&self, dst: &mut [u8], dst_rect: Rect, original: &[u8], hole: Option<Rect>, area: Rect) {
        blit_part(dst, dst_rect, &self.outside, self.rect, area);
        if let Some(clear) = hole.and_then(|h| h.intersect(area)) {
            blit_part(dst, dst_rect, original, self.rect, clear);
        }
    }

    /// The same for a frame in which something is on its way
    /// (`motion::Holes`): each of `layers` is a rectangle and how much of
    /// `original` shows in it, in parts of 256, laid down in order -- what
    /// is going to glass first, the hole itself last and whole. Still only
    /// the two pictures there already are; nothing is blurred.
    pub fn frame_layers(&self, dst: &mut [u8], dst_rect: Rect, original: &[u8], layers: &[(Rect, u32)], area: Rect) {
        blit_part(dst, dst_rect, &self.outside, self.rect, area);
        let sizes_agree = dst.len() == dst_rect.w.max(0) as usize * dst_rect.h.max(0) as usize * 4
            && original.len() == self.outside.len();
        for (rect, share) in layers {
            let Some(r) = rect.intersect(area).and_then(|r| r.intersect(self.rect)).and_then(|r| r.intersect(dst_rect)) else { continue };
            if *share >= 256 {
                blit_part(dst, dst_rect, original, self.rect, r);
            } else if *share > 0 && sizes_agree {
                let share = *share as i32;
                for y in r.y..r.bottom() {
                    let d = ((y - dst_rect.y) as usize * dst_rect.w as usize + (r.x - dst_rect.x) as usize) * 4;
                    let g = ((y - self.rect.y) as usize * self.rect.w as usize + (r.x - self.rect.x) as usize) * 4;
                    for i in 0..r.w as usize * 4 {
                        let (glass, clear) = (self.outside[g + i] as i32, original[g + i] as i32);
                        dst[d + i] = (glass + ((clear - glass) * share + 128).div_euclid(256)) as u8;
                    }
                }
            }
        }
    }

    /// Make what was drawn over the glass outside `hole` fainter: in the
    /// part of `area` that is not in `hole`, `dst` keeps `keep` (0 to 1) of
    /// its difference from the glass. An annotation that reaches out of
    /// the selection is drawn whole and then put through this, so that it
    /// is seen to go on -- and seen not to be in the picture (9.8.11A.5).
    pub fn veil(&self, dst: &mut [u8], dst_rect: Rect, hole: Rect, area: Rect, keep: f64) {
        if dst.len() != dst_rect.w.max(0) as usize * dst_rect.h.max(0) as usize * 4 {
            return;
        }
        let Some(r) = area.intersect(dst_rect).and_then(|r| r.intersect(self.rect)) else { return };
        let keep = (keep.clamp(0.0, 1.0) * 256.0).round() as i32;
        for y in r.y..r.bottom() {
            let d0 = ((y - dst_rect.y) as usize * dst_rect.w as usize + (r.x - dst_rect.x) as usize) * 4;
            let g0 = ((y - self.rect.y) as usize * self.rect.w as usize + (r.x - self.rect.x) as usize) * 4;
            let inside = if y >= hole.y && y < hole.bottom() { hole.x..hole.right() } else { 0..0 };
            for i in 0..r.w as usize {
                if inside.contains(&(r.x + i as i32)) {
                    continue;
                }
                for c in 0..3 {
                    let (under, over) = (self.outside[g0 + i * 4 + c] as i32, dst[d0 + i * 4 + c] as i32);
                    dst[d0 + i * 4 + c] = (under + ((over - under) * keep + 128).div_euclid(256)) as u8;
                }
            }
        }
    }
}

/// `r` grown by `by` on every side.
fn grown(r: Rect, by: i32) -> Rect {
    Rect::new(r.x - by, r.y - by, r.w + 2 * by, r.h + 2 * by)
}

fn around(a: Rect, b: Rect) -> Rect {
    Rect::from_ltrb(a.x.min(b.x), a.y.min(b.y), a.right().max(b.right()), a.bottom().max(b.bottom()))
}

/// The one rectangle of `monitor` that has to be put together again when
/// the hole was `before` and is now `after`: what holds both, grown by
/// `ring` pixels -- the selection's outline and its handles, which are
/// drawn round the hole and move with it. `None` when nothing changed.
///
/// Everything outside it is as the frame before left it: a pixel is the
/// blurred picture or the frozen one according to whether the hole holds
/// it, and that answer changes only for pixels in one hole and not the
/// other.
pub fn dirty(before: Option<Rect>, after: Option<Rect>, ring: i32, monitor: Rect) -> Option<Rect> {
    if before == after {
        return None;
    }
    let both = match (before, after) {
        (Some(a), Some(b)) => around(a, b),
        (Some(a), None) | (None, Some(a)) => a,
        (None, None) => return None,
    };
    grown(both, ring.max(0)).intersect(monitor)
}

/// The part of monitor `index` (at `monitor`) that is shown as it is while
/// the rest is glass (9.8.7), or `None` when all of it is glass.
///
/// A selection, or one being dragged out, is the hole on its own monitor
/// and leaves every other monitor all glass. With neither, the monitor the
/// pointer is on shows the window under it clear -- or all of itself, when
/// there is no window there to pick -- and a monitor the pointer is not on
/// is all glass.
pub fn hole(
    index: usize,
    monitor: Rect,
    selection: Option<(usize, Rect)>,
    forming: Option<(usize, Rect)>,
    hover: Option<(usize, Rect)>,
    pointer_on: Option<usize>,
) -> Option<Rect> {
    if let Some((on, rect)) = selection.or(forming) {
        return (on == index).then(|| rect.intersect(monitor)).flatten();
    }
    if pointer_on != Some(index) {
        return None;
    }
    match hover {
        Some((on, rect)) if on == index => rect.intersect(monitor),
        _ => Some(monitor),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geom::Point;

    #[test]
    fn the_shrink_and_the_radius_are_the_specifications_table() {
        // Scale: k, r for the 3 pt blur outside, r for the plate's 12 pt.
        for (scale, k, outside, plate) in [(1.0, 2, 1, 6), (1.5, 2, 2, 9), (2.0, 4, 1, 6)] {
            assert_eq!(factor(scale), k, "{scale}");
            assert_eq!(radius(glass::OUTSIDE_BLUR_SIGMA, scale), outside, "{scale}");
            assert_eq!(radius(glass::PLATE_BLUR_SIGMA, scale), plate, "{scale}");
        }
        assert_eq!((glass::OUTSIDE_BLUR_SIGMA, glass::PLATE_BLUR_SIGMA, glass::BOX_PASSES), (3.0, 12.0, 3.0));
        // Between the rows: 4 from 175% up, and never a radius of nothing.
        assert_eq!((factor(1.25), factor(1.74), factor(1.75), factor(3.0)), (2, 2, 4, 4));
        assert_eq!(radius(0.1, 1.0), 1);
    }

    fn flat(rect: Rect, grey: u8) -> Vec<u8> {
        let mut v = vec![grey; rect.w as usize * rect.h as usize * 4];
        v.chunks_exact_mut(4).for_each(|p| p[3] = 255);
        v
    }
    fn blue(buf: &[u8], rect: Rect, x: i32, y: i32) -> u8 {
        buf[((y - rect.y) as usize * rect.w as usize + (x - rect.x) as usize) * 4]
    }
    /// A picture with something in every pixel: no two neighbours alike.
    fn busy(rect: Rect) -> Vec<u8> {
        let mut seed = 12345u32;
        let mut v = vec![255u8; rect.w as usize * rect.h as usize * 4];
        for p in v.chunks_exact_mut(4) {
            for c in &mut p[..3] {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                *c = (seed >> 24) as u8;
            }
        }
        v
    }

    #[test]
    fn a_flat_picture_stays_flat_and_is_six_percent_darker() {
        for scale in [1.0, 1.5, 2.0] {
            // Sides that no shrink divides: the last blocks hang over.
            let rect = Rect::new(-40, 30, 131, 77);
            let g = Glass::new(rect, &flat(rect, 255), scale).unwrap();
            // 255 x 0.94.
            assert!(g.outside.chunks_exact(4).all(|p| p == [240, 240, 240, 255]), "scale {scale}");
            let g = Glass::new(rect, &flat(rect, 0), scale).unwrap();
            assert!(g.outside.chunks_exact(4).all(|p| p == [0, 0, 0, 255]), "scale {scale}");
            assert!(g.is_frosted());
            let (small, (sw, sh), k) = g.small();
            assert_eq!((sw, sh, k), (131usize.div_ceil(factor(scale)), 77usize.div_ceil(factor(scale)), factor(scale)));
            assert_eq!(small.len(), sw * sh * 4);
        }
        // A buffer that is not the monitor's size is refused, not read.
        assert!(Glass::new(Rect::new(0, 0, 10, 10), &[0; 396], 1.0).is_none());
        assert!(Glass::new(Rect::new(0, 0, 0, 10), &[], 1.0).is_none());
        assert!(Glass::plain(Rect::new(0, 0, 10, 10), &[0; 396]).is_none());
    }

    /// How many pixels a hard edge takes to go from a tenth of the way to
    /// nine tenths of it, along row `y`.
    fn rise(buf: &[u8], rect: Rect, y: i32) -> i32 {
        let row: Vec<u8> = (rect.x..rect.right()).map(|x| blue(buf, rect, x, y)).collect();
        let (lo, hi) = (*row.iter().min().unwrap() as f64, *row.iter().max().unwrap() as f64);
        let first = row.iter().position(|v| *v as f64 > lo + (hi - lo) * 0.1).unwrap();
        let last = row.iter().position(|v| *v as f64 >= lo + (hi - lo) * 0.9).unwrap();
        last as i32 - first as i32
    }

    #[test]
    fn a_hard_edge_is_spread_over_what_three_points_of_blur_spread_it() {
        // Left half black, right half white (9.8.13 D). A Gaussian takes
        // 2.56 sigmas from 10% to 90%: 7.7 pt, so 8, 12 and 15 px.
        for (scale, least, most) in [(1.0, 6, 11), (1.5, 9, 16), (2.0, 12, 20)] {
            let rect = Rect::new(0, 0, 400, 64);
            let mut pic = flat(rect, 0);
            for (i, p) in pic.chunks_exact_mut(4).enumerate() {
                if i % 400 >= 200 {
                    p[..3].fill(255);
                }
            }
            let g = Glass::new(rect, &pic, scale).unwrap();
            let got = rise(&g.outside, rect, 32);
            assert!((least..=most).contains(&got), "scale {scale}: {got} px");
            // Far from the edge it is the flat value on either side.
            assert_eq!((blue(&g.outside, rect, 20, 32), blue(&g.outside, rect, 380, 32)), (0, 240), "scale {scale}");
            // And the same on every row: the edge is still straight.
            assert_eq!(rise(&g.outside, rect, 5), got);
            // With less transparency asked for nothing is blurred: the edge
            // is where it was, between 0 and 255 x 0.57.
            let p = Glass::plain(rect, &pic).unwrap();
            assert_eq!((blue(&p.outside, rect, 199, 32), blue(&p.outside, rect, 200, 32)), (0, 145));
            assert!(!p.is_frosted() && p.small().0.is_empty());
        }
    }

    #[test]
    fn blurring_on_several_threads_is_blurring_on_one() {
        let (w, h, k) = (97, 53, 2);
        let pic = busy(Rect::new(0, 0, w as i32, h as i32));
        let (small, sw, sh) = downsample(&pic, w, h, k);
        let tone = darker(0.06);
        let one = upsample(&small, sw, sh, w, h, k, &tone, 1);
        for n in [2, 3, 8, 500] {
            assert_eq!(upsample(&small, sw, sh, w, h, k, &tone, n), one, "{n} threads");
        }
    }

    #[test]
    fn in_the_hole_a_frame_is_the_picture_and_outside_it_the_glass() {
        let rect = Rect::new(100, 50, 240, 160);
        let pic = busy(rect);
        let g = Glass::new(rect, &pic, 1.5).unwrap();
        let hole = Rect::new(150, 80, 90, 60);
        let mut frame = flat(rect, 7);
        g.frame(&mut frame, rect, &pic, Some(hole), rect);
        let mut inside = 0;
        for y in rect.y..rect.bottom() {
            for x in rect.x..rect.right() {
                let at = ((y - rect.y) as usize * rect.w as usize + (x - rect.x) as usize) * 4;
                if hole.contains(Point::new(x, y)) {
                    // Not a tolerance: the picture, byte for byte.
                    assert_eq!(frame[at..at + 4], pic[at..at + 4], "({x},{y}) in the hole");
                    inside += 1;
                } else {
                    assert_eq!(frame[at..at + 4], g.outside[at..at + 4], "({x},{y}) outside it");
                }
            }
        }
        assert_eq!(inside, 90 * 60);
        // The glass is not the picture: a busy picture blurred differs
        // nearly everywhere, so the two halves above are two things.
        let same = pic.chunks_exact(4).zip(g.outside.chunks_exact(4)).filter(|(a, b)| a == b).count();
        assert!(same < 240 * 160 / 50, "{same}");
        // No hole: all glass. A hole off the monitor: all glass too.
        let mut none = flat(rect, 7);
        g.frame(&mut none, rect, &pic, None, rect);
        assert_eq!(none, g.outside);
        let mut off = flat(rect, 7);
        g.frame(&mut off, rect, &pic, Some(Rect::new(900, 900, 50, 50)), rect);
        assert_eq!(off, g.outside);
        // Only `area` is written.
        let mut part = flat(rect, 7);
        let area = Rect::new(140, 70, 30, 30);
        g.frame(&mut part, rect, &pic, Some(hole), area);
        for y in rect.y..rect.bottom() {
            for x in rect.x..rect.right() {
                let at = ((y - rect.y) as usize * rect.w as usize + (x - rect.x) as usize) * 4;
                if area.contains(Point::new(x, y)) {
                    assert_eq!(part[at..at + 4], frame[at..at + 4]);
                } else {
                    assert_eq!(part[at..at + 3], [7, 7, 7], "({x},{y}) is outside the area");
                }
            }
        }
    }

    #[test]
    fn putting_only_the_dirty_rectangle_together_again_gives_the_whole_new_frame() {
        let rect = Rect::new(0, 0, 320, 200);
        let pic = busy(rect);
        let g = Glass::new(rect, &pic, 2.0).unwrap();
        let whole = |hole: Option<Rect>| {
            let mut f = flat(rect, 0);
            g.frame(&mut f, rect, &pic, hole, rect);
            f
        };
        let r = |x, y, w, h| Some(Rect::new(x, y, w, h));
        // Moved, grown, shrunk, moved somewhere else entirely, to and from
        // the whole monitor, to and from no hole at all, off the monitor's
        // edge -- and not changed.
        let pairs = [
            (r(40, 30, 100, 80), r(46, 33, 100, 80)),
            (r(40, 30, 100, 80), r(40, 30, 160, 120)),
            (r(40, 30, 160, 120), r(60, 50, 20, 20)),
            (r(10, 10, 40, 40), r(250, 150, 60, 40)),
            (r(40, 30, 100, 80), Some(rect)),
            (Some(rect), r(200, 100, 50, 50)),
            (None, r(40, 30, 100, 80)),
            (r(40, 30, 100, 80), None),
            (None, Some(rect)),
            (r(280, 170, 100, 80), r(-20, -20, 60, 60)),
            (r(40, 30, 100, 80), r(40, 30, 100, 80)),
            (None, None),
        ];
        for ring in [0, 5, 10] {
            for (before, after) in pairs {
                // The frame before, and into it only the dirty rectangle of
                // the frame after.
                let mut frame = whole(before);
                let d = dirty(before, after, ring, rect);
                if let Some(d) = d {
                    g.frame(&mut frame, rect, &pic, after, d);
                    assert_eq!(d.intersect(rect), Some(d), "inside the monitor");
                }
                assert!(frame == whole(after), "{before:?} -> {after:?} ring {ring}: a pixel outside {d:?} was left as it was");
                assert_eq!(d.is_none(), before.map(|b| b.intersect(rect)) == after.map(|a| a.intersect(rect)) && before == after);
            }
        }
        // A step of a drag is a little more than the selection, not the
        // screen: 100x80 moved by (6,3) with a ring of 10 is 126x103.
        assert_eq!(dirty(r(40, 30, 100, 80), r(46, 33, 100, 80), 10, rect), r(30, 20, 126, 103));
        // The ring holds the outline and the handles the hole takes with
        // it: every pixel within `ring` of either hole is in it.
        let d = dirty(r(100, 60, 50, 40), r(104, 60, 50, 40), 10, rect).unwrap();
        for p in [Point::new(90, 50), Point::new(163, 109), Point::new(90, 109), Point::new(163, 50)] {
            assert!(d.contains(p), "{p:?}");
        }
    }

    #[test]
    fn what_reaches_out_of_the_selection_is_seen_fainter_there_and_whole_inside() {
        let rect = Rect::new(0, 0, 200, 100);
        let g = Glass::new(rect, &flat(rect, 255), 1.0).unwrap();
        let hole = Rect::new(50, 20, 100, 60);
        let mut frame = flat(rect, 0);
        g.frame(&mut frame, rect, &flat(rect, 255), Some(hole), rect);
        // A red bar drawn across the selection's right edge.
        let bar = Rect::new(120, 40, 60, 10);
        crate::pixels::blend(&mut frame, rect, bar, (230, 40, 40), 256);
        g.veil(&mut frame, rect, hole, bar, 0.4);
        let at = |f: &[u8], x: usize, y: usize| (f[(y * 200 + x) * 4 + 2], f[(y * 200 + x) * 4 + 1], f[(y * 200 + x) * 4]);
        // Inside: as drawn. Outside: 40% of it over the glass (240).
        assert_eq!(at(&frame, 130, 45), (230, 40, 40));
        assert_eq!(at(&frame, 160, 45), (236, 160, 160), "240 + (230 - 240) x 0.4, 240 + (40 - 240) x 0.4");
        // Outside the area nothing is touched, in or out of the hole.
        assert_eq!((at(&frame, 160, 60), at(&frame, 100, 45)), ((240, 240, 240), (255, 255, 255)));
        // All of it kept, or none: as drawn, or the glass.
        let mut whole = frame.clone();
        g.veil(&mut whole, rect, hole, bar, 1.0);
        assert_eq!(whole, frame);
        g.veil(&mut whole, rect, hole, bar, 0.0);
        assert_eq!((at(&whole, 160, 45), at(&whole, 130, 45)), ((240, 240, 240), (230, 40, 40)));
    }

    #[test]
    fn a_frame_with_something_on_its_way_is_the_two_pictures_mixed_and_whole_in_the_hole() {
        let rect = Rect::new(0, 0, 120, 80);
        let pic = flat(rect, 255);
        let g = Glass::new(rect, &pic, 1.0).unwrap();
        let (going, hole) = (Rect::new(10, 10, 60, 40), Rect::new(50, 30, 50, 40));
        let mut frame = flat(rect, 7);
        g.frame_layers(&mut frame, rect, &pic, &[(going, 128), (hole, 256)], rect);
        let at = |x: usize, y: usize| frame[(y * 120 + x) * 4];
        // Glass (240), halfway to the picture (255), and the picture: the
        // hole is whole where the two overlap -- it is laid down last.
        assert_eq!((at(5, 5), at(20, 20), at(60, 40), at(90, 60)), (240, 248, 255, 255));
        // Nothing of the going one, and all of it: glass, and the picture.
        let mut none = flat(rect, 7);
        g.frame_layers(&mut none, rect, &pic, &[(going, 0)], rect);
        assert_eq!(none, g.outside);
        // With only a whole hole it is `frame`.
        let (mut a, mut b) = (flat(rect, 7), flat(rect, 9));
        g.frame_layers(&mut a, rect, &pic, &[(hole, 256)], rect);
        g.frame(&mut b, rect, &pic, Some(hole), rect);
        assert_eq!(a, b);
        // And only `area` is written.
        let mut part = flat(rect, 7);
        g.frame_layers(&mut part, rect, &pic, &[(going, 128)], Rect::new(0, 0, 30, 30));
        assert_eq!((part[(20 * 120 + 20) * 4], part[(20 * 120 + 40) * 4]), (248, 7));
    }

    #[test]
    fn a_plate_is_dark_glass_whatever_is_under_it() {
        let rect = Rect::new(0, 0, 600, 300);
        let plate = Rect::new(40, 100, 520, 80);
        let rgb = |v: &[u8], x: usize, y: usize| (v[(y * 520 + x) * 4 + 2], v[(y * 520 + x) * 4 + 1], v[(y * 520 + x) * 4]);
        for scale in [1.0, 1.5, 2.0] {
            // On white: half of it under 66% of the tint, #3E4041. On
            // black: the tint alone at 66%, #131415 (§9.8.13 D).
            let white = Glass::new(rect, &flat(rect, 255), scale).unwrap().plate(plate, scale);
            assert_eq!(white.len(), 520 * 80 * 4);
            assert_eq!((rgb(&white, 0, 0), rgb(&white, 260, 40), rgb(&white, 519, 79)), ((0x3E, 0x40, 0x40), (0x3E, 0x40, 0x40), (0x3E, 0x40, 0x40)), "the specification's #3E4041, rounded as the arithmetic rounds it");
            let black = Glass::new(rect, &flat(rect, 0), scale).unwrap().plate(plate, scale);
            assert_eq!(rgb(&black, 260, 40), (0x13, 0x14, 0x15));
            // On red the red is stronger than white's own: colours are
            // made stronger before they are darkened.
            let mut red = flat(rect, 0);
            red.chunks_exact_mut(4).for_each(|p| p[2] = 255);
            let on_red = Glass::new(rect, &red, scale).unwrap().plate(plate, scale);
            assert_eq!(rgb(&on_red, 260, 40), (80, 20, 21));
            // A hard edge under the plate is spread wide: black to white at
            // x = 300 is still not either 60 px to each side of it at 200%.
            let mut edge = flat(rect, 0);
            for (i, p) in edge.chunks_exact_mut(4).enumerate() {
                if i % 600 >= 300 {
                    p[..3].fill(255);
                }
            }
            let over = Glass::new(rect, &edge, scale).unwrap().plate(plate, scale);
            let row: Vec<u8> = (0..520).map(|x| rgb(&over, x, 40).0).collect();
            assert!(row.windows(2).all(|w| w[0] <= w[1]), "darker to lighter, left to right");
            assert_eq!((row[0], row[519]), (0x13, 0x3E));
            let soft = row.iter().filter(|v| **v > 0x13 + 2 && **v < 0x3E - 2).count() as f64;
            // A Gaussian of 12 pt spends about 2.56 sigmas between a tenth
            // and nine tenths; more than a sigma and a half is plenty to
            // tell it from the 3 pt blur outside the selection.
            assert!(soft > 12.0 * scale * 1.5 && soft < 12.0 * scale * 5.0, "scale {scale}: {soft} px");
        }
        // Less transparency: the opaque colour, nothing of the picture.
        let plain = Glass::plain(rect, &busy(rect)).unwrap().plate(plate, 2.0);
        assert!(plain.chunks_exact(4).all(|p| p == [0x40, 0x3F, 0x3D, 255]));
        // A plate that hangs off the monitor is still a picture its size.
        let g = Glass::new(rect, &flat(rect, 255), 1.0).unwrap();
        let hanging = g.plate(Rect::new(500, 280, 200, 60), 1.0);
        assert_eq!(hanging.len(), 200 * 60 * 4);
        assert!(hanging.chunks_exact(4).all(|p| p == [0x40, 0x40, 0x3E, 255]));
    }

    #[test]
    fn what_is_clear_follows_the_selection_then_the_pointer() {
        let (a, b) = (Rect::new(0, 0, 1920, 1080), Rect::new(1920, 0, 2560, 1440));
        let win = Rect::new(300, 200, 800, 600);
        // Nothing selected, the pointer over a window on the first monitor:
        // that window is clear there, and the other monitor is all glass.
        assert_eq!(hole(0, a, None, None, Some((0, win)), Some(0)), Some(win));
        assert_eq!(hole(1, b, None, None, Some((0, win)), Some(0)), None);
        // Over the desktop, no window to pick: that whole monitor is clear.
        assert_eq!(hole(0, a, None, None, None, Some(0)), Some(a));
        assert_eq!(hole(1, b, None, None, None, Some(0)), None);
        // The pointer nowhere this code knows of: glass everywhere.
        assert_eq!(hole(0, a, None, None, None, None), None);
        // A window that hangs off the monitor is clear as far as the monitor goes.
        let hanging = Rect::new(1700, 900, 800, 600);
        assert_eq!(hole(0, a, None, None, Some((0, hanging)), Some(0)), Some(Rect::new(1700, 900, 220, 180)));
        // What is picked is the whole monitor: clear, all of it.
        assert_eq!(hole(1, b, None, None, Some((1, b)), Some(1)), Some(b));
        // A selection being dragged out is the hole, whatever is under the
        // pointer; so is a finished one; and both leave the other monitor
        // all glass, pointer or no pointer.
        let drag = Rect::new(400, 300, 50, 20);
        assert_eq!(hole(0, a, None, Some((0, drag)), Some((0, win)), Some(0)), Some(drag));
        assert_eq!(hole(0, a, Some((0, drag)), None, Some((0, win)), Some(1)), Some(drag));
        assert_eq!(hole(1, b, Some((0, drag)), None, None, Some(1)), None);
        assert_eq!(hole(1, b, None, Some((0, drag)), Some((1, b)), Some(1)), None);
    }

    /// Not a test of anything: how long the one blur and one frame take on
    /// the machine this is run on.
    ///
    ///     cargo test --release -p polter-shots glass::tests::how_long -- --ignored --nocapture
    #[test]
    #[ignore = "a measurement, run by hand"]
    fn how_long_the_blur_and_a_frame_take() {
        use std::time::Instant;
        fn median(mut runs: Vec<f64>) -> (f64, f64, f64) {
            runs.sort_by(|a, b| a.total_cmp(b));
            (runs[runs.len() / 2], runs[0], runs[runs.len() - 1])
        }
        fn time(n: usize, mut f: impl FnMut()) -> (f64, f64, f64) {
            median((0..n).map(|_| {
                let t = Instant::now();
                f();
                t.elapsed().as_secs_f64() * 1e3
            }).collect())
        }
        println!("threads for the blur: {}", threads());
        for (w, h, scale) in [(2560, 1568, 1.5), (3840, 2160, 2.0)] {
            let rect = Rect::new(0, 0, w, h);
            let pic = busy(rect);
            let (k, r) = (factor(scale), radius(glass::OUTSIDE_BLUR_SIGMA, scale));
            println!("{w}x{h} at {scale}: {} px, k={k} r={r}", w * h);
            let mut made = None;
            let (m, lo, hi) = time(9, || made = Glass::new(rect, &pic, scale));
            println!("  the blur, once (as shipped)            median {m:7.2} ms  (min {lo:.2}, max {hi:.2}, n=9)");
            let (m, lo, hi) = time(9, || {
                let (small, sw, sh) = downsample(&pic, w as usize, h as usize, k);
                let mut soft = small.clone();
                box_blur(&mut soft, sw, sh, r, 3);
                std::hint::black_box(upsample(&soft, sw, sh, w as usize, h as usize, k, &darker(0.06), 1));
            });
            println!("  the blur, once, on one thread          median {m:7.2} ms  (min {lo:.2}, max {hi:.2}, n=9)");
            let g = made.unwrap();
            let mut frame = vec![0u8; pic.len()];
            // A selection 1600x1000 and the same moved by 24 px each way.
            let (before, after) = (Rect::new(500, 300, 1600, 1000), Rect::new(524, 324, 1600, 1000));
            let (m, lo, hi) = time(15, || g.frame(&mut frame, rect, &pic, Some(after), rect));
            println!("  a frame, the whole monitor             median {m:7.2} ms  (min {lo:.2}, max {hi:.2}, n=15)");
            let ring = (crate::look::annotation::DIRTY_RING * scale).round() as i32;
            let d = dirty(Some(before), Some(after), ring, rect).unwrap();
            let (m, lo, hi) = time(15, || g.frame(&mut frame, rect, &pic, Some(after), d));
            println!("  a frame, the dirty rectangle {}x{}  median {m:7.2} ms  (min {lo:.2}, max {hi:.2}, n=15)", d.w, d.h);
            std::hint::black_box(&frame);
        }
    }
}
