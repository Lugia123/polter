//! What a clipboard `CF_DIB` decodes to.
//!
//! A packed DIB is a `BITMAPINFOHEADER` (or its V4/V5 extension), then
//! optionally three colour masks, then optionally a palette, then the rows.
//! **Every way of getting it wrong still yields a picture**: rows read top
//! down when they are stored bottom up give an upside-down image, the wrong
//! channel order gives blue faces, and forgetting that rows are padded to four
//! bytes gives a picture that shears -- but only at widths not divisible by
//! four, so the first test image somebody tries (probably 4 wide) passes.
//!
//! The host asks the clipboard for `CF_DIB` only. Windows synthesises it from
//! `CF_BITMAP` and from `CF_DIBV5`, so the one request covers all three, the
//! way `CF_UNICODETEXT` covers `CF_TEXT`.

use crate::Image;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DibError {
    /// Shorter than its own header, masks, palette and rows say it is.
    Truncated,
    /// `biSize` is not a header this reads (the 12-byte OS/2 one, or junk).
    UnsupportedHeader(u32),
    /// RLE, JPEG or PNG inside a DIB: not something a screenshot produces.
    UnsupportedCompression(u32),
    UnsupportedDepth(u16),
    /// Zero or negative width, or zero height.
    BadDimensions,
    /// More pixels than [`MAX_PIXELS`].
    TooLarge,
    /// A paletted pixel names a colour the palette does not have.
    BadPaletteIndex,
}

/// 16384 x 8192. A header is attacker-controlled input as far as this crate
/// is concerned -- anything can put anything on the clipboard -- and its two
/// dimensions are what the allocation below is sized from.
pub const MAX_PIXELS: u64 = 1 << 27;

const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;

fn u16_at(b: &[u8], at: usize) -> Result<u16, DibError> {
    b.get(at..at + 2).map(|s| u16::from_le_bytes([s[0], s[1]])).ok_or(DibError::Truncated)
}

fn u32_at(b: &[u8], at: usize) -> Result<u32, DibError> {
    b.get(at..at + 4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]])).ok_or(DibError::Truncated)
}

/// One channel of a pixel, as a mask over the pixel's integer value.
#[derive(Clone, Copy)]
struct Channel {
    mask: u32,
    shift: u32,
    max: u32,
}

impl Channel {
    fn new(mask: u32) -> Self {
        let shift = if mask == 0 { 0 } else { mask.trailing_zeros() };
        Channel { mask, shift, max: mask >> shift }
    }

    /// The channel scaled to 0..=255. An absent channel (mask 0) reads 0.
    fn get(&self, px: u32) -> u8 {
        let v = (px & self.mask) >> self.shift;
        match self.max {
            0 => 0,
            255 => v as u8,
            // Rounded, so a 5-bit 31 is 255 and not 248.
            max => ((v as u64 * 255 + max as u64 / 2) / max as u64) as u8,
        }
    }
}

/// Decode a packed DIB -- the bytes of a `CF_DIB` clipboard handle.
///
/// Uncompressed 1, 4, 8, 16, 24 and 32 bit images, `BI_RGB` or
/// `BI_BITFIELDS`, bottom-up or top-down.
///
/// **Alpha.** A 32-bit `BI_RGB` DIB formally has no alpha: the fourth byte is
/// unused, and most writers leave it 0 -- which read as alpha would make every
/// ordinary screenshot fully transparent. Some writers do put alpha there. So
/// the byte is taken as alpha only when at least one pixel has it non-zero;
/// when all are zero the image is opaque.
pub fn decode(dib: &[u8]) -> Result<Image, DibError> {
    let header = u32_at(dib, 0)?;
    if !(40..=1024).contains(&header) {
        return Err(DibError::UnsupportedHeader(header));
    }
    let header = header as usize;
    if dib.len() < header {
        return Err(DibError::Truncated);
    }
    let w = u32_at(dib, 4)? as i32;
    let h = u32_at(dib, 8)? as i32;
    let depth = u16_at(dib, 14)?;
    let compression = u32_at(dib, 16)?;
    let colours_used = u32_at(dib, 32)? as u64;

    if w <= 0 || h == 0 || h == i32::MIN {
        return Err(DibError::BadDimensions);
    }
    // A negative height is how a DIB says its first row is the top one.
    let top_down = h < 0;
    let (width, height) = (w as u64, h.unsigned_abs() as u64);
    if width * height > MAX_PIXELS {
        return Err(DibError::TooLarge);
    }
    if !matches!(depth, 1 | 4 | 8 | 16 | 24 | 32) {
        return Err(DibError::UnsupportedDepth(depth));
    }
    if compression != BI_RGB && !(compression == BI_BITFIELDS && matches!(depth, 16 | 32)) {
        return Err(DibError::UnsupportedCompression(compression));
    }

    // Where the masks are, and how far they push the rest.
    //
    // With the 40-byte header the three masks *follow* it and move the pixels
    // by 12 bytes. With a V4/V5 header they are fields *of* it (at 40, 44, 48,
    // alpha at 52) and move nothing.
    let mut after_header = header as u64;
    let (r, g, b, a) = match (compression, depth) {
        (BI_BITFIELDS, _) => {
            let alpha = if header >= 56 { u32_at(dib, 52)? } else { 0 };
            if header == 40 {
                after_header += 12;
            }
            (u32_at(dib, 40)?, u32_at(dib, 44)?, u32_at(dib, 48)?, alpha)
        }
        (_, 16) => (0x7C00, 0x03E0, 0x001F, 0),
        (_, 32) => (0x00FF_0000, 0x0000_FF00, 0x0000_00FF, 0xFF00_0000),
        _ => (0x00FF_0000, 0x0000_FF00, 0x0000_00FF, 0),
    };
    let (r, g, b, a) = (Channel::new(r), Channel::new(g), Channel::new(b), Channel::new(a));

    // The palette: required below 16 bits, permitted (and skipped) above.
    let palette_len = match (depth <= 8, colours_used) {
        (true, 0) => 1u64 << depth,
        (true, n) => n.min(1 << depth),
        (false, n) => n,
    };
    let palette_at = after_header;
    let pixels_at = palette_at + palette_len * 4;
    // Rows are padded to a multiple of four bytes.
    let stride = (width * depth as u64 + 31) / 32 * 4;
    let end = pixels_at + stride * height;
    if (dib.len() as u64) < end {
        return Err(DibError::Truncated);
    }
    let (palette_at, pixels_at, stride) = (palette_at as usize, pixels_at as usize, stride as usize);
    let (width, height) = (width as usize, height as usize);

    let mut rgba = vec![0u8; width * height * 4];
    let mut any_alpha = false;
    for y in 0..height {
        let stored = if top_down { y } else { height - 1 - y };
        let row = &dib[pixels_at + stored * stride..][..stride];
        let out = &mut rgba[y * width * 4..][..width * 4];
        for x in 0..width {
            let o = &mut out[x * 4..x * 4 + 4];
            if depth <= 8 {
                let bit = x * depth as usize;
                // Paletted pixels are packed most significant bits first.
                let shift = 8 - depth as usize - bit % 8;
                let index = (row[bit / 8] >> shift) as usize & ((1 << depth) - 1);
                if index as u64 >= palette_len {
                    return Err(DibError::BadPaletteIndex);
                }
                // A palette entry is blue, green, red, reserved.
                let c = &dib[palette_at + index * 4..][..4];
                o.copy_from_slice(&[c[2], c[1], c[0], 255]);
                continue;
            }
            let px = match depth {
                16 => u16::from_le_bytes([row[x * 2], row[x * 2 + 1]]) as u32,
                24 => u32::from_le_bytes([row[x * 3], row[x * 3 + 1], row[x * 3 + 2], 0]),
                _ => u32::from_le_bytes([row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]]),
            };
            let alpha = a.get(px);
            any_alpha |= alpha != 0;
            o.copy_from_slice(&[r.get(px), g.get(px), b.get(px), alpha]);
        }
    }
    if depth > 8 && !any_alpha {
        for px in rgba.chunks_exact_mut(4) {
            px[3] = 255;
        }
    }
    Ok(Image { width: width as u32, height: height as u32, rgba })
}

/// A packed DIB of `image`, to put on the clipboard as `CF_DIB`: a 40-byte
/// header, 32 bits, `BI_RGB`, bottom-up -- the plainest form there is, which
/// every program that pastes pictures reads.
///
/// The image is written opaque whatever its alpha: the fourth byte of a
/// `BI_RGB` DIB is formally unused, and readers disagree about it.
pub fn encode(image: &Image) -> Vec<u8> {
    let (w, h) = (image.width as usize, image.height as usize);
    let mut out = Vec::with_capacity(40 + w * h * 4);
    out.extend((40u32).to_le_bytes());
    out.extend((image.width as i32).to_le_bytes());
    out.extend((image.height as i32).to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(32u16.to_le_bytes());
    out.extend(BI_RGB.to_le_bytes());
    out.extend(((w * h * 4) as u32).to_le_bytes());
    out.extend([0u8; 16]);
    for y in (0..h).rev() {
        for p in image.rgba[y * w * 4..][..w * 4].chunks_exact(4) {
            out.extend([p[2], p[1], p[0], 255]);
        }
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A 40-byte `BITMAPINFOHEADER`.
    pub(crate) fn header(w: i32, h: i32, depth: u16, compression: u32, colours_used: u32) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend(40u32.to_le_bytes());
        v.extend(w.to_le_bytes());
        v.extend(h.to_le_bytes());
        v.extend(1u16.to_le_bytes());
        v.extend(depth.to_le_bytes());
        v.extend(compression.to_le_bytes());
        v.extend([0u8; 12]); // size of image, two resolutions
        v.extend(colours_used.to_le_bytes());
        v.extend(0u32.to_le_bytes());
        assert_eq!(v.len(), 40);
        v
    }

    const RED: [u8; 4] = [255, 0, 0, 255];
    const GREEN: [u8; 4] = [0, 255, 0, 255];
    const BLUE: [u8; 4] = [0, 0, 255, 255];
    const WHITE: [u8; 4] = [255, 255, 255, 255];
    const BLACK: [u8; 4] = [0, 0, 0, 255];

    fn px(i: &Image, x: u32, y: u32) -> [u8; 4] {
        let at = ((y * i.width + x) * 4) as usize;
        i.rgba[at..at + 4].try_into().unwrap()
    }

    /// 3 wide, 2 high, 24 bit, bottom-up: the stored first row is the bottom.
    /// Three pixels are nine bytes, so each row carries three bytes of padding
    /// -- filled with 0xEE here so that reading them as pixels shows.
    fn three_by_two_24() -> Vec<u8> {
        let mut v = header(3, 2, 24, BI_RGB, 0);
        // Stored row 0 = bottom row: blue, white, black. Bytes are B, G, R.
        v.extend([255, 0, 0, 255, 255, 255, 0, 0, 0, 0xEE, 0xEE, 0xEE]);
        // Stored row 1 = top row: red, green, blue.
        v.extend([0, 0, 255, 0, 255, 0, 255, 0, 0, 0xEE, 0xEE, 0xEE]);
        v
    }

    #[test]
    fn a_bottom_up_bitmap_comes_out_top_row_first() {
        let i = decode(&three_by_two_24()).unwrap();
        assert_eq!((i.width, i.height), (3, 2));
        assert_eq!([px(&i, 0, 0), px(&i, 1, 0), px(&i, 2, 0)], [RED, GREEN, BLUE]);
        assert_eq!([px(&i, 0, 1), px(&i, 1, 1), px(&i, 2, 1)], [BLUE, WHITE, BLACK]);
    }

    #[test]
    fn a_negative_height_is_already_top_row_first() {
        let mut v = header(3, -2, 24, BI_RGB, 0);
        v.extend([0, 0, 255, 0, 255, 0, 255, 0, 0, 0xEE, 0xEE, 0xEE]);
        v.extend([255, 0, 0, 255, 255, 255, 0, 0, 0, 0xEE, 0xEE, 0xEE]);
        let i = decode(&v).unwrap();
        assert_eq!([px(&i, 0, 0), px(&i, 1, 0), px(&i, 2, 0)], [RED, GREEN, BLUE]);
        assert_eq!([px(&i, 0, 1), px(&i, 1, 1), px(&i, 2, 1)], [BLUE, WHITE, BLACK]);
    }

    #[test]
    fn thirty_two_bit_with_an_unused_fourth_byte_is_opaque() {
        let mut v = header(2, 1, 32, BI_RGB, 0);
        v.extend([0, 0, 255, 0, 0, 255, 0, 0]); // red, green; fourth byte 0
        let i = decode(&v).unwrap();
        assert_eq!([px(&i, 0, 0), px(&i, 1, 0)], [RED, GREEN]);
    }

    #[test]
    fn thirty_two_bit_with_alpha_in_use_keeps_it() {
        let mut v = header(2, 1, 32, BI_RGB, 0);
        v.extend([0, 0, 255, 128, 0, 255, 0, 0]);
        let i = decode(&v).unwrap();
        assert_eq!([px(&i, 0, 0), px(&i, 1, 0)], [[255, 0, 0, 128], [0, 255, 0, 0]]);
    }

    #[test]
    fn bitfields_after_a_forty_byte_header_move_the_pixels_by_twelve() {
        // Masks that are *not* the default order: red in the low byte.
        let mut v = header(2, 1, 32, BI_BITFIELDS, 0);
        v.extend(0x0000_00FFu32.to_le_bytes());
        v.extend(0x0000_FF00u32.to_le_bytes());
        v.extend(0x00FF_0000u32.to_le_bytes());
        v.extend([255, 0, 0, 0, 0, 0, 255, 0]); // red, blue under these masks
        let i = decode(&v).unwrap();
        assert_eq!([px(&i, 0, 0), px(&i, 1, 0)], [RED, BLUE]);
    }

    #[test]
    fn a_v5_header_carries_its_masks_inside_it() {
        let mut v = header(1, 1, 32, BI_BITFIELDS, 0);
        v[0..4].copy_from_slice(&124u32.to_le_bytes());
        v.extend(0x00FF_0000u32.to_le_bytes()); // red
        v.extend(0x0000_FF00u32.to_le_bytes()); // green
        v.extend(0x0000_00FFu32.to_le_bytes()); // blue
        v.extend(0xFF00_0000u32.to_le_bytes()); // alpha
        v.resize(124, 0);
        v.extend([10, 20, 30, 40]); // B, G, R, A
        let i = decode(&v).unwrap();
        assert_eq!(px(&i, 0, 0), [30, 20, 10, 40]);
    }

    #[test]
    fn sixteen_bit_is_five_five_five_scaled_to_full_range() {
        let mut v = header(2, 1, 16, BI_RGB, 0);
        v.extend(0x7FFFu16.to_le_bytes()); // every channel 31
        v.extend(0x7C00u16.to_le_bytes()); // red 31
        let i = decode(&v).unwrap();
        assert_eq!([px(&i, 0, 0), px(&i, 1, 0)], [WHITE, RED]);
    }

    #[test]
    fn a_one_bit_bitmap_reads_its_palette_most_significant_bit_first() {
        let mut v = header(10, 1, 1, BI_RGB, 0);
        v.extend([0, 0, 0, 0, 255, 255, 255, 0]); // palette: black, white (BGRX)
        // 10 pixels: 1000 0000 01.. -> white, then black, last one white.
        v.extend([0b1000_0000, 0b0100_0000, 0, 0]);
        let i = decode(&v).unwrap();
        assert_eq!(px(&i, 0, 0), WHITE);
        assert_eq!(px(&i, 1, 0), BLACK);
        assert_eq!(px(&i, 8, 0), BLACK);
        assert_eq!(px(&i, 9, 0), WHITE);
    }

    #[test]
    fn an_eight_bit_bitmap_with_a_short_palette() {
        let mut v = header(2, 1, 8, BI_RGB, 2);
        v.extend([0, 0, 255, 0, 255, 0, 0, 0]); // red, blue
        v.extend([1, 0, 0, 0]);
        let i = decode(&v).unwrap();
        assert_eq!([px(&i, 0, 0), px(&i, 1, 0)], [BLUE, RED]);

        let at = v.len() - 4;
        v[at] = 2; // a colour the two-entry palette does not have
        assert_eq!(decode(&v), Err(DibError::BadPaletteIndex));
    }

    #[test]
    fn a_bitmap_shorter_than_it_claims_is_refused() {
        let whole = three_by_two_24();
        assert!(decode(&whole).is_ok());
        assert_eq!(decode(&whole[..whole.len() - 1]), Err(DibError::Truncated));
        assert_eq!(decode(&whole[..39]), Err(DibError::Truncated));
        assert_eq!(decode(&[]), Err(DibError::Truncated));
    }

    #[test]
    fn dimensions_that_cannot_be_an_image_are_refused() {
        assert_eq!(decode(&header(0, 1, 24, BI_RGB, 0)), Err(DibError::BadDimensions));
        assert_eq!(decode(&header(-3, 1, 24, BI_RGB, 0)), Err(DibError::BadDimensions));
        assert_eq!(decode(&header(1, 0, 24, BI_RGB, 0)), Err(DibError::BadDimensions));
        assert_eq!(decode(&header(1, i32::MIN, 24, BI_RGB, 0)), Err(DibError::BadDimensions));
    }

    #[test]
    fn a_header_claiming_a_huge_image_is_refused_before_allocating() {
        assert_eq!(decode(&header(i32::MAX, i32::MAX, 32, BI_RGB, 0)), Err(DibError::TooLarge));
        assert_eq!(decode(&header(16385, 8192, 32, BI_RGB, 0)), Err(DibError::TooLarge));
    }

    #[test]
    fn an_encoded_image_is_a_bottom_up_thirty_two_bit_dib() {
        // Top row red, green; bottom row blue, white. Alpha is not kept.
        let image = Image { width: 2, height: 2, rgba: [RED, [0, 255, 0, 9], BLUE, WHITE].concat() };
        let dib = encode(&image);
        assert_eq!(dib.len(), 40 + 16);
        assert_eq!(u32_at(&dib, 0), Ok(40));
        assert_eq!((u32_at(&dib, 4), u32_at(&dib, 8)), (Ok(2), Ok(2)), "positive height: bottom-up");
        assert_eq!((u16_at(&dib, 12), u16_at(&dib, 14), u32_at(&dib, 16)), (Ok(1), Ok(32), Ok(BI_RGB)));
        assert_eq!(u32_at(&dib, 20), Ok(16));
        // The first stored row is the bottom one, each pixel B, G, R, 255.
        assert_eq!(&dib[40..], [255, 0, 0, 255, 255, 255, 255, 255, 0, 0, 255, 255, 0, 255, 0, 255]);
        let back = decode(&dib).unwrap();
        assert_eq!(back.rgba, [RED, GREEN, BLUE, WHITE].concat());
    }

    #[test]
    fn what_it_does_not_read_it_says() {
        assert_eq!(decode(&header(1, 1, 8, 1, 0)), Err(DibError::UnsupportedCompression(1)));
        assert_eq!(decode(&header(1, 1, 24, BI_BITFIELDS, 0)), Err(DibError::UnsupportedCompression(3)));
        assert_eq!(decode(&header(1, 1, 2, BI_RGB, 0)), Err(DibError::UnsupportedDepth(2)));
        let mut core = header(1, 1, 24, BI_RGB, 0);
        core[0..4].copy_from_slice(&12u32.to_le_bytes());
        assert_eq!(decode(&core), Err(DibError::UnsupportedHeader(12)));
    }
}
