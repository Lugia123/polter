//! The pixel work: the frozen screen, the mosaic, the highlighter, and the
//! composed image that is the only thing allowed to leave.
//!
//! Buffers are **B, G, R, X** rows, top row first -- what GDI hands over and
//! takes back, so the host never converts. The fourth byte is ignored on the
//! way in and written 255.
//!
//! # What leaves, and what cannot
//!
//! [`Frozen`] is a monitor as it was when the screenshot started. It has no
//! method that encodes it and none that hands its bytes out for writing: it
//! can only be read *from*, by [`Composed::new`]. [`Composed`] is the
//! selection after the mosaics have been applied, and every way out of this
//! crate -- [`Composed::png`], [`Composed::dib`], [`Composed::tiles`] -- is a
//! method of it. So a file, a clipboard image or a tile that still showed
//! what a mosaic covers would have to be produced by code that does not go
//! through here, and there is none (§9.5: the original does not land).

use crate::annot::{Item, Shape};
use crate::geom::{Point, Rect};
use crate::glass::Glass;
use crate::style;
use crate::Image;

/// A monitor's picture at the moment the screenshot was triggered.
pub struct Frozen {
    /// The monitor's rectangle on the virtual screen.
    rect: Rect,
    bgrx: Vec<u8>,
}

impl Frozen {
    /// `None` when `bgrx` is not `rect.w * rect.h * 4` bytes.
    pub fn new(rect: Rect, bgrx: Vec<u8>) -> Option<Frozen> {
        (rect.w > 0 && rect.h > 0 && bgrx.len() == rect.w as usize * rect.h as usize * 4)
            .then_some(Frozen { rect, bgrx })
    }

    pub fn rect(&self) -> Rect {
        self.rect
    }

    /// Copy the part of this picture that falls in `dst_rect` into `dst`, a
    /// buffer covering `dst_rect`. For the overlay's own display of it.
    pub fn show(&self, dst: &mut [u8], dst_rect: Rect) {
        blit(dst, dst_rect, &self.bgrx, self.rect);
    }

    /// The glass this picture is seen through outside the selection, made
    /// once (`glass`): blurred, or -- `frosted` false, for a system that
    /// asks for less transparency -- only darkened.
    pub fn glass(&self, scale: f64, frosted: bool) -> Option<Glass> {
        if frosted {
            Glass::new(self.rect, &self.bgrx, scale)
        } else {
            Glass::plain(self.rect, &self.bgrx)
        }
    }

    /// The part `area` of one frame of the overlay into `dst` (covering
    /// `dst_rect`): `glass` everywhere, this picture where `hole` is
    /// ([`Glass::frame`]). For the overlay's own display, like [`Self::show`].
    pub fn frame(&self, glass: &Glass, dst: &mut [u8], dst_rect: Rect, hole: Option<Rect>, area: Rect) {
        glass.frame(dst, dst_rect, &self.bgrx, hole, area);
    }

    /// The same with something on its way ([`Glass::frame_layers`]).
    pub fn frame_layers(&self, glass: &Glass, dst: &mut [u8], dst_rect: Rect, layers: &[(Rect, u32)], area: Rect) {
        glass.frame_layers(dst, dst_rect, &self.bgrx, layers, area);
    }

    fn pixel(&self, x: i32, y: i32) -> &[u8] {
        let at = ((y - self.rect.y) as usize * self.rect.w as usize + (x - self.rect.x) as usize) * 4;
        &self.bgrx[at..at + 4]
    }
}

/// Copy the overlap of two buffers, each covering a rectangle of the same
/// coordinate space.
pub fn blit(dst: &mut [u8], dst_rect: Rect, src: &[u8], src_rect: Rect) {
    let Some(both) = dst_rect.intersect(src_rect) else { return };
    if dst.len() != dst_rect.w as usize * dst_rect.h as usize * 4
        || src.len() != src_rect.w as usize * src_rect.h as usize * 4
    {
        return;
    }
    let n = both.w as usize * 4;
    for y in both.y..both.bottom() {
        let s = ((y - src_rect.y) as usize * src_rect.w as usize + (both.x - src_rect.x) as usize) * 4;
        let d = ((y - dst_rect.y) as usize * dst_rect.w as usize + (both.x - dst_rect.x) as usize) * 4;
        dst[d..d + n].copy_from_slice(&src[s..s + n]);
    }
}

/// Copy the part `part` of `src` into `dst`, each a buffer covering its own
/// rectangle of the same coordinate space. Nothing outside `part` is
/// written, and nothing where the two buffers do not both reach.
pub fn blit_part(dst: &mut [u8], dst_rect: Rect, src: &[u8], src_rect: Rect, part: Rect) {
    let Some(both) = dst_rect.intersect(src_rect).and_then(|b| b.intersect(part)) else { return };
    if dst.len() != dst_rect.w as usize * dst_rect.h as usize * 4
        || src.len() != src_rect.w as usize * src_rect.h as usize * 4
    {
        return;
    }
    let n = both.w as usize * 4;
    for y in both.y..both.bottom() {
        let s = ((y - src_rect.y) as usize * src_rect.w as usize + (both.x - src_rect.x) as usize) * 4;
        let d = ((y - dst_rect.y) as usize * dst_rect.w as usize + (both.x - dst_rect.x) as usize) * 4;
        dst[d..d + n].copy_from_slice(&src[s..s + n]);
    }
}

/// Where two pictures of the same size differ, as rectangles in their own
/// coordinates: one for each band of `band` rows that holds a difference,
/// as wide as the differences in it reach. **What a window has to be given
/// to turn the one into the other** -- copying these rectangles from `b`
/// over `a` makes `a` equal `b` -- so a frame costs the screen only what
/// changed in it, whatever it was that changed. Empty when they are equal;
/// everything when they are not the same size.
pub fn changed(a: &[u8], b: &[u8], w: usize, h: usize, band: usize) -> Vec<Rect> {
    if a.len() != w * h * 4 || b.len() != w * h * 4 || w == 0 || h == 0 {
        return vec![Rect::new(0, 0, w as i32, h as i32)];
    }
    let band = band.max(1);
    let mut out = Vec::new();
    for top in (0..h).step_by(band) {
        let (mut y0, mut y1, mut x0, mut x1) = (usize::MAX, 0, usize::MAX, 0);
        for y in top..(top + band).min(h) {
            let (ra, rb) = (&a[y * w * 4..(y + 1) * w * 4], &b[y * w * 4..(y + 1) * w * 4]);
            if ra == rb {
                continue;
            }
            let first = ra.chunks_exact(4).zip(rb.chunks_exact(4)).position(|(p, q)| p != q).unwrap_or(0);
            let last = ra.chunks_exact(4).zip(rb.chunks_exact(4)).rposition(|(p, q)| p != q).unwrap_or(w - 1);
            y0 = y0.min(y);
            y1 = y;
            x0 = x0.min(first);
            x1 = x1.max(last);
        }
        if y0 != usize::MAX {
            out.push(Rect::new(x0 as i32, y0 as i32, (x1 - x0 + 1) as i32, (y1 - y0 + 1) as i32));
        }
    }
    out
}

/// Fill `rect` of a buffer covering `dst_rect` with black.
pub fn black_out(dst: &mut [u8], dst_rect: Rect, rect: Rect) {
    let Some(r) = rect.intersect(dst_rect) else { return };
    for y in r.y..r.bottom() {
        let d = ((y - dst_rect.y) as usize * dst_rect.w as usize + (r.x - dst_rect.x) as usize) * 4;
        for px in dst[d..d + r.w as usize * 4].chunks_exact_mut(4) {
            px.copy_from_slice(&[0, 0, 0, 255]);
        }
    }
}

/// Lay `rgb` over `rect` of a buffer covering `dst_rect`, `alpha` parts of
/// 256 of it: 256 is the colour itself.
pub fn blend(dst: &mut [u8], dst_rect: Rect, rect: Rect, rgb: (u8, u8, u8), alpha: u32) {
    if dst.len() != dst_rect.w.max(0) as usize * dst_rect.h.max(0) as usize * 4 {
        return;
    }
    let Some(r) = rect.intersect(dst_rect) else { return };
    let alpha = alpha.min(256);
    for y in r.y..r.bottom() {
        let d = ((y - dst_rect.y) as usize * dst_rect.w as usize + (r.x - dst_rect.x) as usize) * 4;
        for px in dst[d..d + r.w as usize * 4].chunks_exact_mut(4) {
            for (c, ink) in px[..3].iter_mut().zip([rgb.2, rgb.1, rgb.0]) {
                *c = ((*c as u32 * (256 - alpha) + ink as u32 * alpha) / 256) as u8;
            }
            px[3] = 255;
        }
    }
}

/// Darken everything in `dst` (a buffer covering `dst_rect`) outside `keep`,
/// to about 57% -- how the overlay shows what is and is not selected.
pub fn dim(dst: &mut [u8], dst_rect: Rect, keep: Option<Rect>) {
    if dst.len() != dst_rect.w.max(0) as usize * dst_rect.h.max(0) as usize * 4 {
        return;
    }
    let keep = keep.and_then(|k| k.intersect(dst_rect));
    let w = dst_rect.w as usize;
    for (y, row) in dst.chunks_exact_mut(w * 4).enumerate() {
        let y = dst_rect.y + y as i32;
        // The columns of this row that stay bright, as offsets into it.
        let bright = match keep {
            Some(k) if y >= k.y && y < k.bottom() => (k.x - dst_rect.x) as usize..(k.right() - dst_rect.x) as usize,
            _ => 0..0,
        };
        for (x, px) in row.chunks_exact_mut(4).enumerate() {
            if !bright.contains(&x) {
                for c in &mut px[..3] {
                    *c = (*c as u32 * 145 / 255) as u8;
                }
            }
        }
    }
}

// ----------------------------------------------------------------- mosaic

/// How a side of `len` pixels is cut into blocks of `block`: `(start,
/// length)` for each, in order (§9.7).
///
/// The remainder `r = len mod block` decides the last block. **Less than
/// half a block is merged into the block before it** (so the last one is
/// `block + r` long); half a block or more stands as a block of its own. A
/// sliver of a block averages over so few pixels that it shows what is under
/// it -- a one-pixel column is that column. A side shorter than one block is
/// one block.
pub fn spans(len: i32, block: i32) -> Vec<(i32, i32)> {
    if len <= 0 {
        return Vec::new();
    }
    let block = block.max(1);
    if len <= block {
        return vec![(0, len)];
    }
    let (whole, rest) = (len / block, len % block);
    let mut out: Vec<(i32, i32)> = (0..whole).map(|i| (i * block, block)).collect();
    if rest * 2 >= block {
        out.push((whole * block, rest));
    } else if let Some(last) = out.last_mut() {
        last.1 += rest;
    }
    out
}

/// An 8-bit channel reduced to its top five bits, the low three refilled
/// from the top so that 0 stays 0 and 255 stays 255.
pub fn five_bits(v: u8) -> u8 {
    let q = v >> 3;
    (q << 3) | (q >> 2)
}

/// The mosaic of `rect` (virtual screen) at `block` pixels, computed from
/// the frozen picture: the part of `rect` on the monitor, and its pixels.
///
/// Every block comes out one colour, and that colour depends on nothing but
/// the average of the block's own pixels, each channel's integer sum divided
/// by the count and cut to five bits. **So the output carries one number per
/// block and nothing else**: rearranging the pixels inside a block in any
/// way that keeps their sum leaves it byte for byte the same, which is the
/// property the tests state.
pub fn mosaic(frozen: &Frozen, rect: Rect, block: i32) -> Option<(Rect, Vec<u8>)> {
    let r = rect.intersect(frozen.rect())?;
    let mut out = vec![0u8; r.w as usize * r.h as usize * 4];
    for (by, bh) in spans(r.h, block) {
        for (bx, bw) in spans(r.w, block) {
            let mut sum = [0u64; 3];
            for y in by..by + bh {
                for x in bx..bx + bw {
                    let p = frozen.pixel(r.x + x, r.y + y);
                    for c in 0..3 {
                        sum[c] += p[c] as u64;
                    }
                }
            }
            let n = bw as u64 * bh as u64;
            let colour = [five_bits((sum[0] / n) as u8), five_bits((sum[1] / n) as u8), five_bits((sum[2] / n) as u8), 255];
            for y in by..by + bh {
                let row = (y as usize * r.w as usize + bx as usize) * 4;
                for px in out[row..row + bw as usize * 4].chunks_exact_mut(4) {
                    px.copy_from_slice(&colour);
                }
            }
        }
    }
    Some((r, out))
}

/// The block size a mosaic annotation uses: its step, the monitor's scale
/// and the short side of its own rectangle.
pub fn block_of(rect: Rect, level: u8, scale: f64) -> i32 {
    style::mosaic_block(level, scale, rect.w.min(rect.h))
}

/// Draw every mosaic among `items` into `dst`, a buffer covering `dst_rect`.
/// Each is computed from the frozen picture, never from another mosaic's
/// output, so overlapping ones do not compound.
pub fn apply_mosaics(dst: &mut [u8], dst_rect: Rect, frozen: &Frozen, items: &[Item], scale: f64) {
    for item in items {
        if let Shape::Mosaic(rect) = item.shape {
            if let Some((at, pixels)) = mosaic(frozen, rect, block_of(rect, item.level, scale)) {
                blit(dst, dst_rect, &pixels, at);
            }
        }
    }
}

// ------------------------------------------------------------ highlighter

/// Lay a highlighter stroke over `dst`, a buffer covering `dst_rect`.
///
/// The colour goes on at 40% the way a marker does, by multiplying: each
/// channel becomes `dst x (255 - 0.4 x (255 - c)) / 255`, so white paper
/// takes the colour and black text stays black. **A stroke is laid once**,
/// however often it crosses itself: the pixels it covers are found first and
/// each is darkened one time.
pub fn highlight(dst: &mut [u8], dst_rect: Rect, points: &[Point], width: i32, rgb: (u8, u8, u8)) {
    if dst.len() != dst_rect.w.max(0) as usize * dst_rect.h.max(0) as usize * 4 || points.is_empty() {
        return;
    }
    let radius = width.max(1) as f64 / 2.0;
    let reach = radius.ceil() as i32;
    let (w, h) = (dst_rect.w as usize, dst_rect.h as usize);
    let mut covered = vec![false; w * h];
    let single = [points[0], points[0]];
    let segments: Vec<&[Point]> = if points.len() == 1 { vec![&single[..]] } else { points.windows(2).collect() };
    for s in segments {
        let (a, b) = (s[0], s[1]);
        let area = Rect::from_ltrb(
            a.x.min(b.x) - reach,
            a.y.min(b.y) - reach,
            a.x.max(b.x) + reach + 1,
            a.y.max(b.y) + reach + 1,
        );
        let Some(area) = area.intersect(dst_rect) else { continue };
        for y in area.y..area.bottom() {
            for x in area.x..area.right() {
                if crate::annot::dist_to_segment(Point::new(x, y), a, b) <= radius {
                    covered[(y - dst_rect.y) as usize * w + (x - dst_rect.x) as usize] = true;
                }
            }
        }
    }
    // Buffer order is B, G, R.
    let factor = [rgb.2, rgb.1, rgb.0].map(|c| 255 - (2 * (255 - c as u32) + 2) / 5);
    for (px, on) in dst.chunks_exact_mut(4).zip(covered) {
        if on {
            for c in 0..3 {
                px[c] = ((px[c] as u32 * factor[c] + 127) / 255) as u8;
            }
        }
    }
}

// --------------------------------------------------------------- composed

/// How tall a tile of a long screenshot may be, and how much two neighbours
/// share (§9.6).
pub const TILE_HEIGHT: u32 = 1800;
pub const TILE_OVERLAP: u32 = 120;

/// Where the tiles of an image `height` tall start and how tall each is.
/// Every tile but the last is `max` tall; each starts `max - overlap` below
/// the one before; the last ends at the image's bottom.
pub fn tile_spans(height: u32, max: u32, overlap: u32) -> Vec<(u32, u32)> {
    let max = max.max(1);
    let step = max.saturating_sub(overlap).max(1);
    let mut out = Vec::new();
    let mut y = 0;
    while height > 0 {
        let h = max.min(height - y);
        out.push((y, h));
        if y + h >= height {
            break;
        }
        y += step;
    }
    out
}

/// The selection as it will leave: cut from the frozen picture, blacked out
/// where it must be, mosaics applied. See the module documentation for why
/// this type is the only door.
pub struct Composed {
    rect: Rect,
    bgrx: Vec<u8>,
}

impl Composed {
    /// Compose `selection` from the frozen picture.
    ///
    /// Order: the picture, then `redact` rectangles painted black (panes an
    /// agent must not see), then the mosaics among `items`. The other
    /// annotations are drawn afterwards by the host, through [`Self::draw`].
    /// `None` when the selection does not lie on the monitor.
    ///
    /// **The black goes on before the mosaics are computed, not just before
    /// they are drawn.** A mosaic laid over a redacted pane averages black,
    /// not the pane: a block's colour is a number about what is under it,
    /// and that would be the pane's contents leaving at one value per block.
    pub fn new(frozen: &Frozen, selection: Rect, items: &[Item], scale: f64, redact: &[Rect]) -> Option<Composed> {
        let rect = selection.intersect(frozen.rect())?;
        let blacked;
        let source = if redact.is_empty() {
            frozen
        } else {
            let mut copy = frozen.bgrx.clone();
            for r in redact {
                black_out(&mut copy, frozen.rect, *r);
            }
            blacked = Frozen { rect: frozen.rect, bgrx: copy };
            &blacked
        };
        let mut bgrx = vec![0u8; rect.w as usize * rect.h as usize * 4];
        source.show(&mut bgrx, rect);
        apply_mosaics(&mut bgrx, rect, source, items, scale);
        Some(Composed { rect, bgrx })
    }

    /// A composed image from pixels that never were a `Frozen`: a long
    /// screenshot's stitched frames, which carry no annotations.
    pub fn from_stitched(width: u32, bgrx: Vec<u8>) -> Option<Composed> {
        let row = width as usize * 4;
        if row == 0 || bgrx.is_empty() || bgrx.len() % row != 0 {
            return None;
        }
        Some(Composed { rect: Rect::new(0, 0, width as i32, (bgrx.len() / row) as i32), bgrx })
    }

    /// The rectangle of the virtual screen this image is.
    pub fn rect(&self) -> Rect {
        self.rect
    }

    pub fn size(&self) -> (u32, u32) {
        (self.rect.w as u32, self.rect.h as u32)
    }

    /// Draw on top of what is here: the annotations that are not mosaics.
    /// The closure gets the pixels and the rectangle they cover.
    pub fn draw(&mut self, f: impl FnOnce(&mut [u8], Rect)) {
        // Whatever is left in the fourth byte does not matter: every way
        // out goes through `Image::from_bgrx`, which ignores it.
        f(&mut self.bgrx, self.rect);
    }

    fn image_of(&self, y: u32, height: u32) -> Option<Image> {
        let row = self.rect.w as usize * 4;
        let bytes = self.bgrx.get(y as usize * row..(y + height) as usize * row)?;
        Image::from_bgrx(self.rect.w as u32, height, bytes)
    }

    /// The image as a PNG: the file that is saved.
    pub fn png(&self) -> Option<Vec<u8>> {
        crate::encode::png(&self.image_of(0, self.rect.h as u32)?)
    }

    /// The image as a packed DIB: what goes on the clipboard as `CF_DIB`.
    pub fn dib(&self) -> Option<Vec<u8>> {
        Some(crate::dib::encode(&self.image_of(0, self.rect.h as u32)?))
    }

    /// How many bytes `dib` would be, without making it.
    pub fn dib_len(&self) -> usize {
        dib_len(self.rect.w as usize, self.rect.h as usize)
    }

    /// `dib`, unless it would be larger than [`CLIPBOARD_DIB_LIMIT`]: a
    /// long screenshot 2560 by 20000 is some 200 MB uncompressed, and the
    /// clipboard then carries the PNG alone, as the macOS side always does.
    /// `None` for "too large" as well as "could not be made"; `dib_len`
    /// says which.
    pub fn clipboard_dib(&self) -> Option<Vec<u8>> {
        if !dib_fits_the_clipboard(self.rect.w as usize, self.rect.h as usize) {
            return None;
        }
        self.dib()
    }

    /// The image cut into tiles for a long screenshot: each tile's `y` in
    /// the whole image, its height, and its PNG.
    pub fn tiles(&self, max: u32, overlap: u32) -> Vec<(u32, u32, Vec<u8>)> {
        tile_spans(self.rect.h as u32, max, overlap)
            .into_iter()
            .filter_map(|(y, h)| Some((y, h, crate::encode::png(&self.image_of(y, h)?)?)))
            .collect()
    }
}

/// The largest bitmap put on the clipboard as `CF_DIB`, in bytes.
pub const CLIPBOARD_DIB_LIMIT: usize = 64 << 20;

/// The size of a `w` by `h` picture as a packed 32-bit DIB: its header and
/// four bytes a pixel.
pub fn dib_len(w: usize, h: usize) -> usize {
    40 + w * h * 4
}

/// Whether a `w` by `h` picture goes on the clipboard as a bitmap: up to
/// the limit, and the limit itself.
pub fn dib_fits_the_clipboard(w: usize, h: usize) -> bool {
    dib_len(w, h) <= CLIPBOARD_DIB_LIMIT
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Not a test: what keeping the frame before costs, against keeping
    /// only a hash of each 64 x 64 tile of it (task 1116, which asked
    /// whether the second canvas is worth its 33 MB on a 4K monitor).
    ///
    ///     cargo test --release -p polter-shots pixels::tests::how_long -- --ignored --nocapture
    #[test]
    #[ignore = "a measurement, run by hand"]
    fn how_long_comparing_two_frames_takes_against_hashing_one() {
        use std::time::Instant;
        fn median(mut runs: Vec<f64>) -> f64 {
            runs.sort_by(|a, b| a.total_cmp(b));
            runs[runs.len() / 2]
        }
        for (w, h) in [(2560usize, 1568usize), (3840, 2160)] {
            let mut g = Lcg(9);
            let a: Vec<u8> = (0..w * h * 4).map(|_| g.next() as u8).collect();
            let mut b = a.clone();
            // A toolbar cell's worth of change.
            for y in 900..956 {
                for x in 1200..1256 {
                    b[(y * w + x) * 4] ^= 0x55;
                }
            }
            let compare = median((0..9).map(|_| {
                let t = Instant::now();
                std::hint::black_box(changed(&a, &b, w, h, 64));
                t.elapsed().as_secs_f64() * 1e3
            }).collect());
            // One multiply-and-fold hash for each 64 x 64 tile.
            let hash = median((0..9).map(|_| {
                let t = Instant::now();
                let mut tiles = vec![0u64; w.div_ceil(64) * h.div_ceil(64)];
                for y in 0..h {
                    for (tx, chunk) in b[y * w * 4..(y + 1) * w * 4].chunks(64 * 4).enumerate() {
                        let tile = &mut tiles[(y / 64) * w.div_ceil(64) + tx];
                        for word in chunk.chunks_exact(8) {
                            *tile = (*tile ^ u64::from_le_bytes(word.try_into().unwrap())).wrapping_mul(0x9E37_79B9_7F4A_7C15);
                        }
                    }
                }
                std::hint::black_box(tiles);
                t.elapsed().as_secs_f64() * 1e3
            }).collect());
            let rects = changed(&a, &b, w, h, 64);
            println!(
                "{w}x{h}: comparing with the frame before {compare:.2} ms -> {:?} ({} px to send); hashing 64x64 tiles {hash:.2} ms -> \
                 one tile of 4096 px to send; the frame before is {:.1} MB, the hashes {:.2} MB",
                rects,
                rects.iter().map(|r| r.w * r.h).sum::<i32>(),
                (w * h * 4) as f64 / 1e6,
                (w.div_ceil(64) * h.div_ceil(64) * 8) as f64 / 1e6
            );
        }
    }

    /// The host blurs on a thread of its own and does not wait for it: the
    /// thread shares the frozen picture, sends what it made, and may find
    /// nobody listening.
    #[test]
    fn glass_made_on_another_thread_is_the_same_glass_and_may_be_made_for_nobody() {
        use std::sync::{mpsc, Arc};
        let rect = Rect::new(10, 20, 120, 90);
        let mut g = Lcg(5);
        let frozen = Arc::new(Frozen::new(rect, (0..120 * 90 * 4).map(|_| g.next() as u8).collect()).unwrap());
        let here = frozen.glass(1.5, true).unwrap();
        let mut frame_here = vec![0u8; 120 * 90 * 4];
        frozen.frame(&here, &mut frame_here, rect, Some(Rect::new(30, 40, 50, 30)), rect);

        let (made, late) = mpsc::channel();
        let picture = frozen.clone();
        let worker = std::thread::spawn(move || made.send(picture.glass(1.5, true)).is_ok());
        let there = late.recv().unwrap().unwrap();
        assert!(worker.join().unwrap(), "somebody was listening");
        let mut frame_there = vec![0u8; 120 * 90 * 4];
        frozen.frame(&there, &mut frame_there, rect, Some(Rect::new(30, 40, 50, 30)), rect);
        assert!(frame_here == frame_there);
        // Until it arrives the monitor is darkened only -- and in the hole
        // the two are the same picture, so nothing in the selection moves
        // when the one takes the place of the other.
        let plain = frozen.glass(1.5, false).unwrap();
        let mut frame_plain = vec![0u8; 120 * 90 * 4];
        frozen.frame(&plain, &mut frame_plain, rect, Some(Rect::new(30, 40, 50, 30)), rect);
        assert!(!plain.is_frosted() && there.is_frosted() && frame_plain != frame_there);
        for y in 40..70usize {
            let row = ((y - 20) * 120 + 20) * 4;
            assert_eq!(frame_plain[row..row + 50 * 4], frame_there[row..row + 50 * 4]);
        }

        // The session ended before the blur did: nobody holds the other
        // end. The thread finishes, what it made is dropped, and the
        // picture is freed when the thread lets go of it -- not before.
        let (made, late) = mpsc::channel::<Option<Glass>>();
        drop(late);
        let picture = frozen.clone();
        let weak = Arc::downgrade(&frozen);
        drop(frozen);
        let worker = std::thread::spawn(move || made.send(picture.glass(1.5, true)).is_ok());
        assert!(!worker.join().unwrap(), "nobody was listening, and that is not an error");
        assert!(weak.upgrade().is_none(), "the picture went with the last one holding it");
    }

    #[test]
    fn what_changed_between_two_frames_is_enough_to_make_one_from_the_other() {
        let (w, h) = (97usize, 150usize);
        let mut seed = 7u32;
        let mut noise = || {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            (seed >> 24) as u8
        };
        let a: Vec<u8> = (0..w * h * 4).map(|_| noise()).collect();
        // Nothing changed: nothing to give the window.
        assert!(changed(&a, &a, w, h, 16).is_empty());
        // A pixel; a rectangle; two things far apart; the last row and
        // column; everything.
        let cases: Vec<Vec<Rect>> = vec![
            vec![Rect::new(40, 70, 1, 1)],
            vec![Rect::new(10, 20, 30, 40)],
            vec![Rect::new(2, 3, 5, 5), Rect::new(80, 130, 10, 12)],
            vec![Rect::new(96, 0, 1, 150), Rect::new(0, 149, 97, 1)],
            vec![Rect::new(0, 0, 97, 150)],
        ];
        let whole = Rect::new(0, 0, w as i32, h as i32);
        for touched in cases {
            let mut b = a.clone();
            for r in &touched {
                for y in r.y..r.bottom() {
                    for x in r.x..r.right() {
                        let at = (y as usize * w + x as usize) * 4;
                        b[at] = b[at].wrapping_add(1);
                    }
                }
            }
            for band in [1, 16, 64, 1000] {
                let rects = changed(&a, &b, w, h, band);
                // Copy just those from the new frame over the old one.
                let mut made = a.clone();
                for r in &rects {
                    blit_part(&mut made, whole, &b, whole, *r);
                }
                assert!(made == b, "{touched:?} band {band}: {rects:?} left a pixel as it was");
                // And not the whole picture for a small change.
                let area: i32 = rects.iter().map(|r| r.w * r.h).sum();
                let least: i32 = touched.iter().map(|r| r.w * r.h).sum();
                if touched.len() == 1 && band <= 16 {
                    assert_eq!(area, least, "{touched:?} band {band}: exactly what changed");
                }
            }
        }
        // Pictures of different sizes: all of it.
        assert_eq!(changed(&a, &a[..40], w, h, 16), [whole]);
    }
    use crate::annot::tests::it;
    use crate::encode::tests::read_back;

    /// A small deterministic generator, so the tests need no dependency and
    /// say the same thing every run.
    pub(crate) struct Lcg(pub u64);
    impl Lcg {
        pub(crate) fn next(&mut self) -> u32 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (self.0 >> 33) as u32
        }
    }

    /// A monitor full of noise: every pixel different from its neighbours,
    /// which is the hardest thing to hide.
    pub(crate) fn noise(rect: Rect, seed: u64) -> Frozen {
        let mut g = Lcg(seed);
        let bgrx = (0..rect.w * rect.h).flat_map(|_| { let v = g.next(); [v as u8, (v >> 8) as u8, (v >> 16) as u8, 0] }).collect();
        Frozen::new(rect, bgrx).unwrap()
    }

    fn px(buf: &[u8], width: i32, x: i32, y: i32) -> [u8; 4] {
        let at = (y * width + x) as usize * 4;
        buf[at..at + 4].try_into().unwrap()
    }

    const MON: Rect = Rect::new(-200, 50, 160, 120);

    #[test]
    fn dimming_darkens_everything_but_the_kept_rectangle() {
        let rect = Rect::new(10, 10, 4, 3);
        let mut buf = vec![200u8; 4 * 3 * 4];
        dim(&mut buf, rect, Some(Rect::new(11, 11, 2, 1)));
        let dark = [113, 113, 113, 200];
        let bright = [200, 200, 200, 200];
        assert_eq!(px(&buf, 4, 0, 0), dark);
        assert_eq!(px(&buf, 4, 0, 1), dark);
        assert_eq!(px(&buf, 4, 1, 1), bright);
        assert_eq!(px(&buf, 4, 2, 1), bright);
        assert_eq!(px(&buf, 4, 3, 1), dark);
        assert_eq!(px(&buf, 4, 1, 2), dark);
        // Nothing kept, or a rectangle elsewhere: all of it.
        let mut all = vec![200u8; 4 * 3 * 4];
        dim(&mut all, rect, None);
        assert!(all.chunks_exact(4).all(|p| p == dark));
        let mut off = vec![200u8; 4 * 3 * 4];
        dim(&mut off, rect, Some(Rect::new(500, 500, 9, 9)));
        assert_eq!(off, all);
    }

    #[test]
    fn a_side_is_cut_into_blocks_and_a_sliver_joins_its_neighbour() {
        assert_eq!(spans(40, 10), [(0, 10), (10, 10), (20, 10), (30, 10)]);
        // Remainder 4 of 10: less than half, merged -- the last block is 14.
        assert_eq!(spans(44, 10), [(0, 10), (10, 10), (20, 10), (30, 14)]);
        // Remainder 5 of 10: half, a block of its own.
        assert_eq!(spans(45, 10), [(0, 10), (10, 10), (20, 10), (30, 10), (40, 5)]);
        assert_eq!(spans(49, 10), [(0, 10), (10, 10), (20, 10), (30, 10), (40, 9)]);
        // An odd block: 2 x 3 < 7 merges, 2 x 4 >= 7 does not.
        assert_eq!(spans(10, 7), [(0, 10)]);
        assert_eq!(spans(11, 7), [(0, 7), (7, 4)]);
        // One pixel over: never a one-pixel block.
        assert_eq!(spans(41, 10), [(0, 10), (10, 10), (20, 10), (30, 11)]);
        // Shorter than a block, or exactly one: one block.
        assert_eq!(spans(3, 10), [(0, 3)]);
        assert_eq!(spans(10, 10), [(0, 10)]);
        assert_eq!(spans(0, 10), []);
    }

    #[test]
    fn the_blocks_cover_the_side_exactly_and_none_is_a_sliver() {
        for block in 1..=40 {
            for len in 1..=200 {
                let s = spans(len, block);
                assert_eq!(s[0].0, 0);
                assert_eq!(s.iter().map(|b| b.1).sum::<i32>(), len, "len {len} block {block}");
                assert!(s.windows(2).all(|w| w[0].0 + w[0].1 == w[1].0), "contiguous");
                if len >= block {
                    assert!(s.iter().all(|b| b.1 * 2 >= block), "len {len} block {block}: {s:?}");
                }
            }
        }
    }

    #[test]
    fn five_bits_keeps_the_ends_and_only_thirty_two_values() {
        assert_eq!((five_bits(0), five_bits(255)), (0, 255));
        assert_eq!(five_bits(0b1010_1111), 0b1010_1101);
        let distinct: std::collections::BTreeSet<u8> = (0..=255).map(five_bits).collect();
        assert_eq!(distinct.len(), 32);
    }

    /// The first property of §9.5: inside every block all pixels are equal.
    #[test]
    fn every_block_of_a_mosaic_is_one_colour() {
        let frozen = noise(MON, 1);
        // 97 x 53 at block 16: columns 6 blocks (last 17), rows 3 + a 5-px
        // remainder merged into the third.
        let rect = Rect::new(-190, 60, 97, 53);
        let (at, out) = mosaic(&frozen, rect, 16).unwrap();
        assert_eq!(at, rect);
        let mut colours = std::collections::BTreeSet::new();
        for (by, bh) in spans(53, 16) {
            for (bx, bw) in spans(97, 16) {
                let first = px(&out, 97, bx, by);
                for y in by..by + bh {
                    for x in bx..bx + bw {
                        assert_eq!(px(&out, 97, x, y), first, "block at ({bx},{by}), pixel ({x},{y})");
                    }
                }
                assert_eq!(first[3], 255);
                assert!(first[..3].iter().all(|c| *c == five_bits(*c)), "cut to five bits");
                colours.insert(first);
            }
        }
        assert!(colours.len() > 1, "noise does not average to one colour everywhere");
    }

    /// The second property of §9.5: rearranging the pixels inside each block
    /// -- which keeps each block's average -- changes nothing in the output.
    #[test]
    fn rearranging_the_pixels_inside_each_block_gives_the_same_bytes() {
        let rect = Rect::new(-190, 60, 97, 53);
        let original = noise(MON, 2);
        let (_, before) = mosaic(&original, rect, 16).unwrap();

        let mut shuffled = original.bgrx.clone();
        let mut g = Lcg(99);
        let at = |x: i32, y: i32| ((y - MON.y) * MON.w + (x - MON.x)) as usize * 4;
        for (by, bh) in spans(53, 16) {
            for (bx, bw) in spans(97, 16) {
                let mut cells: Vec<usize> = (by..by + bh)
                    .flat_map(|y| (bx..bx + bw).map(move |x| (x, y)))
                    .map(|(x, y)| at(rect.x + x, rect.y + y))
                    .collect();
                // Fisher-Yates over the block's own pixels.
                for i in (1..cells.len()).rev() {
                    let j = g.next() as usize % (i + 1);
                    let (a, b) = (cells[i], cells[j]);
                    for c in 0..4 {
                        shuffled.swap(a + c, b + c);
                    }
                    cells.swap(i, j);
                }
            }
        }
        assert_ne!(shuffled, original.bgrx, "the rearrangement did rearrange something");
        let (_, after) = mosaic(&Frozen::new(MON, shuffled).unwrap(), rect, 16).unwrap();
        assert_eq!(after, before);
    }

    #[test]
    fn a_blocks_colour_is_the_average_of_its_pixels_cut_to_five_bits() {
        // One 2 x 2 block: B 10,20,30,41 -> 25 (floor of 25.25) -> 24|… .
        let bgrx = vec![10, 0, 255, 0, 20, 0, 255, 0, 30, 0, 255, 0, 41, 8, 255, 0];
        let frozen = Frozen::new(Rect::new(0, 0, 2, 2), bgrx).unwrap();
        let (_, out) = mosaic(&frozen, Rect::new(0, 0, 2, 2), 2).unwrap();
        assert_eq!(px(&out, 2, 0, 0), [five_bits(25), five_bits(2), 255, 255]);
        assert_eq!(px(&out, 2, 1, 1), px(&out, 2, 0, 0));
    }

    #[test]
    fn a_mosaic_hanging_off_the_monitor_is_the_part_that_is_on_it() {
        let frozen = noise(MON, 3);
        let (at, out) = mosaic(&frozen, Rect::new(-250, 0, 100, 100), 20).unwrap();
        assert_eq!(at, Rect::new(-200, 50, 50, 50));
        assert_eq!(out.len(), 50 * 50 * 4);
        assert!(mosaic(&frozen, Rect::new(500, 500, 10, 10), 20).is_none());
    }

    #[test]
    fn overlapping_mosaics_are_each_made_from_the_original() {
        let frozen = noise(MON, 4);
        let (a, b) = (Rect::new(-190, 60, 60, 60), Rect::new(-160, 80, 60, 60));
        let items = [it(Shape::Mosaic(a)), it(Shape::Mosaic(b))];
        let mut buf = vec![0u8; (MON.w * MON.h * 4) as usize];
        frozen.show(&mut buf, MON);
        apply_mosaics(&mut buf, MON, &frozen, &items, 1.0);
        // Where they overlap, the later one shows -- exactly as it would alone.
        let (_, alone) = mosaic(&frozen, b, block_of(b, 1, 1.0)).unwrap();
        for y in 0..60 {
            for x in 0..60 {
                assert_eq!(px(&buf, MON.w, b.x - MON.x + x, b.y - MON.y + y), px(&alone, 60, x, y));
            }
        }
    }

    #[test]
    fn the_highlighter_multiplies_and_a_stroke_is_laid_once() {
        let rect = Rect::new(0, 0, 40, 40);
        let mut buf = vec![255u8; 40 * 40 * 4];
        // Black text on the white page.
        for c in 0..3 {
            buf[(10 * 40 + 20) * 4 + c] = 0;
        }
        // A stroke that crosses itself at (20,10)..: out and back along one row.
        let stroke = [Point::new(5, 10), Point::new(35, 10), Point::new(5, 10)];
        highlight(&mut buf, rect, &stroke, 8, style::COLOURS[2]);
        // Yellow #FFD400 at 40%: B 255 -> 255 - 0.4*255 = 153, G -> 238, R -> 255.
        assert_eq!(px(&buf, 40, 10, 10), [153, 238, 255, 255]);
        assert_eq!(px(&buf, 40, 10, 13), [153, 238, 255, 255], "within half the width");
        assert_eq!(px(&buf, 40, 10, 15), [255, 255, 255, 255], "outside it");
        assert_eq!(px(&buf, 40, 20, 10), [0, 0, 0, 255], "black stays black");
        assert_eq!(px(&buf, 40, 2, 10), [153, 238, 255, 255], "the round end");
        assert_eq!(px(&buf, 40, 0, 10), [255, 255, 255, 255]);
    }

    #[test]
    fn a_highlighter_stroke_partly_off_the_buffer_marks_only_what_is_on_it() {
        let rect = Rect::new(100, 100, 10, 10);
        let mut buf = vec![255u8; 10 * 10 * 4];
        highlight(&mut buf, rect, &[Point::new(90, 105), Point::new(104, 105)], 4, (255, 0, 0));
        assert_eq!(px(&buf, 10, 0, 5), [153, 153, 255, 255]);
        assert_eq!(px(&buf, 10, 9, 5), [255, 255, 255, 255]);
        // Wholly off it: nothing, and no panic.
        highlight(&mut buf, rect, &[Point::new(0, 0), Point::new(5, 5)], 4, (255, 0, 0));
    }

    #[test]
    fn tiles_are_at_most_the_limit_tall_and_share_their_overlap() {
        assert_eq!(tile_spans(1000, 1800, 120), [(0, 1000)]);
        assert_eq!(tile_spans(1800, 1800, 120), [(0, 1800)]);
        assert_eq!(tile_spans(1801, 1800, 120), [(0, 1800), (1680, 121)]);
        assert_eq!(tile_spans(5000, 1800, 120), [(0, 1800), (1680, 1800), (3360, 1640)]);
        assert_eq!(tile_spans(0, 1800, 120), []);
        for height in [1, 1799, 1800, 1801, 3480, 3481, 20000] {
            let t = tile_spans(height, 1800, 120);
            assert!(t.iter().all(|(_, h)| *h <= 1800));
            assert_eq!(t.last().map(|(y, h)| y + h), Some(height), "the last tile ends at the bottom");
            assert!(t.windows(2).all(|w| w[0].0 + w[0].1 - w[1].0 == 120), "neighbours share 120 px");
        }
    }

    // ------------------------------------------------ what leaves (§9.5.3)

    /// A selection with a mosaic over part of it, and what the mosaic's
    /// rectangle looks like in the frozen original.
    fn composed_with_a_mosaic() -> (Composed, Frozen, Rect) {
        let frozen = noise(MON, 7);
        let selection = Rect::new(-180, 60, 120, 100);
        let secret = Rect::new(-150, 80, 64, 48);
        let c = Composed::new(&frozen, selection, &[it(Shape::Mosaic(secret))], 1.0, &[]).unwrap();
        (c, noise(MON, 7), secret)
    }

    /// Asserts that `image` -- something that left -- shows the mosaic where
    /// the secret was and not the original: every block one colour, and no
    /// pixel of the region equal to the original's at the same place except
    /// by the accident of matching its block's average.
    fn assert_the_secret_did_not_leave(image: &Image, image_origin: Point, frozen: &Frozen, secret: Rect) {
        let block = block_of(secret, 1, 1.0);
        let local = secret.relative_to(image_origin);
        let at = |x: i32, y: i32| -> [u8; 3] {
            let i = ((y * image.width as i32 + x) * 4) as usize;
            [image.rgba[i], image.rgba[i + 1], image.rgba[i + 2]]
        };
        let mut same_as_original = 0;
        for (by, bh) in spans(secret.h, block) {
            for (bx, bw) in spans(secret.w, block) {
                // A tile may hold only some rows of a block: the ones it has.
                let mut first = None;
                for y in by..by + bh {
                    for x in bx..bx + bw {
                        if local.y + y < 0 || local.y + y >= image.height as i32 {
                            continue;
                        }
                        let first = *first.get_or_insert(at(local.x + x, local.y + y));
                        assert_eq!(at(local.x + x, local.y + y), first, "a block that is not one colour left");
                        let o = frozen.pixel(secret.x + x, secret.y + y);
                        if [o[2], o[1], o[0]] == first {
                            same_as_original += 1;
                        }
                    }
                }
            }
        }
        assert!(same_as_original < 4, "{same_as_original} pixels of the original left");
    }

    #[test]
    fn the_saved_file_is_the_composed_image() {
        let (c, frozen, secret) = composed_with_a_mosaic();
        let (image, _) = read_back(&c.png().unwrap());
        assert_eq!((image.width, image.height), (120, 100));
        assert_the_secret_did_not_leave(&image, c.rect().origin(), &frozen, secret);
        // And outside the mosaic it *is* the original: the check above is
        // not passing because everything was blanked.
        let o = frozen.pixel(-180, 60);
        assert_eq!(image.rgba[..3], [o[2], o[1], o[0]]);
    }

    #[test]
    fn the_clipboard_image_is_the_composed_image() {
        let (c, frozen, secret) = composed_with_a_mosaic();
        let image = crate::dib::decode(&c.dib().unwrap()).unwrap();
        assert_eq!((image.width, image.height), (120, 100));
        assert_the_secret_did_not_leave(&image, c.rect().origin(), &frozen, secret);
    }

    #[test]
    fn every_tile_is_cut_from_the_composed_image() {
        let (c, frozen, secret) = composed_with_a_mosaic();
        // Tiles of 40 with 10 shared: the secret (rows 20..68) spans three.
        let tiles = c.tiles(40, 10);
        assert_eq!(tiles.iter().map(|t| (t.0, t.1)).collect::<Vec<_>>(), [(0, 40), (30, 40), (60, 40)]);
        for (y, h, png) in &tiles {
            let (image, _) = read_back(png);
            assert_eq!((image.width, image.height), (120, *h));
            let origin = Point::new(c.rect().x, c.rect().y + *y as i32);
            assert_the_secret_did_not_leave(&image, origin, &frozen, secret);
        }
    }

    #[test]
    fn the_check_itself_fails_on_an_image_that_was_not_composed() {
        // The floor for the three tests above: hand the checker the
        // original pixels and it must object.
        let frozen = noise(MON, 7);
        let selection = Rect::new(-180, 60, 120, 100);
        let raw = Composed::new(&frozen, selection, &[], 1.0, &[]).unwrap();
        let (image, _) = read_back(&raw.png().unwrap());
        let secret = Rect::new(-150, 80, 64, 48);
        let caught = std::panic::catch_unwind(|| {
            assert_the_secret_did_not_leave(&image, selection.origin(), &noise(MON, 7), secret)
        });
        assert!(caught.is_err());
    }

    #[test]
    fn a_redacted_rectangle_is_black_and_a_mosaic_over_it_averages_black() {
        let frozen = noise(MON, 8);
        let selection = Rect::new(-180, 60, 100, 100);
        let pane = Rect::new(-170, 70, 60, 60);
        // One mosaic wholly inside the pane, one wholly outside it.
        let inside = Rect::new(-160, 80, 32, 32);
        let outside = Rect::new(-100, 80, 16, 16);
        let items = [it(Shape::Mosaic(inside)), it(Shape::Mosaic(outside))];
        let c = Composed::new(&frozen, selection, &items, 1.0, &[pane]).unwrap();
        let (image, _) = read_back(&c.png().unwrap());
        let at = |x: i32, y: i32| {
            let i = (((y - selection.y) * 100 + (x - selection.x)) * 4) as usize;
            [image.rgba[i], image.rgba[i + 1], image.rgba[i + 2]]
        };
        assert_eq!(at(-165, 75), [0, 0, 0], "inside the pane, outside the mosaic");
        for (x, y) in [(-160, 80), (-145, 95), (-129, 111)] {
            assert_eq!(at(x, y), [0, 0, 0], "the mosaic over the pane saw black, not the pane");
        }
        assert_ne!(at(-95, 85), [0, 0, 0], "a mosaic elsewhere still averages the picture");
        let o = frozen.pixel(-100, 150);
        assert_eq!(at(-100, 150), [o[2], o[1], o[0]], "elsewhere untouched");
    }

    #[test]
    fn what_the_host_draws_on_top_is_in_what_leaves() {
        let (mut c, _, _) = composed_with_a_mosaic();
        c.draw(|bits, rect| {
            assert_eq!(rect, Rect::new(-180, 60, 120, 100));
            bits[..4].copy_from_slice(&[1, 2, 3, 0]);
        });
        let (image, _) = read_back(&c.png().unwrap());
        assert_eq!(image.rgba[..4], [3, 2, 1, 255], "B, G, R in; R, G, B out; opaque whatever was written");
    }

    #[test]
    fn a_selection_is_cut_to_the_monitor_and_one_off_it_is_nothing() {
        let frozen = noise(MON, 9);
        let c = Composed::new(&frozen, Rect::new(-250, 0, 100, 100), &[], 1.0, &[]).unwrap();
        assert_eq!(c.rect(), Rect::new(-200, 50, 50, 50));
        assert!(Composed::new(&frozen, Rect::new(900, 900, 10, 10), &[], 1.0, &[]).is_none());
        assert!(Frozen::new(MON, vec![0; 7]).is_none());
    }

    #[test]
    fn stitched_frames_become_a_composed_image_of_their_own_height() {
        let c = Composed::from_stitched(3, vec![9; 3 * 4 * 5]).unwrap();
        assert_eq!(c.size(), (3, 5));
        assert!(Composed::from_stitched(3, vec![9; 13]).is_none());
        assert!(Composed::from_stitched(0, vec![]).is_none());
    }

    #[test]
    fn a_bitmap_past_the_limit_is_not_made_for_the_clipboard() {
        let small = Composed::from_stitched(3, vec![9; 3 * 4 * 5]).unwrap();
        assert_eq!(small.dib().unwrap().len(), small.dib_len());
        assert_eq!(small.dib_len(), dib_len(3, 5));
        assert_eq!(small.clipboard_dib(), small.dib());
        // The limit is 64 MiB and is itself allowed.
        assert_eq!(CLIPBOARD_DIB_LIMIT, 64 * 1024 * 1024);
        let rows = (CLIPBOARD_DIB_LIMIT - 40) / 4 / 2560;
        assert!(dib_fits_the_clipboard(2560, rows));
        assert!(!dib_fits_the_clipboard(2560, rows + 1));
        assert_eq!(dib_len(2, (CLIPBOARD_DIB_LIMIT - 40) / 8), CLIPBOARD_DIB_LIMIT);
        assert!(dib_fits_the_clipboard(2, (CLIPBOARD_DIB_LIMIT - 40) / 8));
        // The case it is for: a long screenshot as tall as they get.
        assert!(!dib_fits_the_clipboard(2560, 20_000));
        let tall = Composed::from_stitched(4096, vec![0; 4096 * 4 * 4097]).unwrap();
        assert!(tall.dib_len() > CLIPBOARD_DIB_LIMIT);
        assert_eq!(tall.clipboard_dib(), None);
    }
}
