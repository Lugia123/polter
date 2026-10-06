//! Pixels to PNG bytes.

use crate::Image;

/// The eight bytes every PNG starts with.
pub const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

/// Whether `bytes` are a PNG by their first eight bytes. For the clipboard's
/// own `PNG` format, whose contents are written as they are.
pub fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(&SIGNATURE)
}

/// Encode as an 8-bit PNG: RGB when every pixel is opaque, RGBA otherwise.
///
/// Opaque images drop the alpha channel because a screenshot is the common
/// case and it is a quarter of the data. `None` when the image's buffer is
/// not `width * height * 4` bytes or either dimension is zero.
pub fn png(image: &Image) -> Option<Vec<u8>> {
    let pixels = image.width as usize * image.height as usize;
    if pixels == 0 || image.rgba.len() != pixels * 4 {
        return None;
    }
    let opaque = image.rgba.chunks_exact(4).all(|p| p[3] == 255);
    let mut out = Vec::new();
    {
        let mut e = ::png::Encoder::new(&mut out, image.width, image.height);
        e.set_depth(::png::BitDepth::Eight);
        e.set_color(if opaque { ::png::ColorType::Rgb } else { ::png::ColorType::Rgba });
        // A paste is answered on the window thread, so this is the fast
        // setting; on screen content it still comes out a small fraction of
        // the raw size.
        e.set_compression(::png::Compression::Fast);
        let mut w = e.write_header().ok()?;
        if opaque {
            let rgb: Vec<u8> = image.rgba.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
            w.write_image_data(&rgb).ok()?;
        } else {
            w.write_image_data(&image.rgba).ok()?;
        }
        w.finish().ok()?;
    }
    Some(out)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Decode with the `png` crate's reader, expanding RGB to RGBA.
    pub(crate) fn read_back(bytes: &[u8]) -> (Image, ::png::ColorType) {
        let mut r = ::png::Decoder::new(bytes).read_info().unwrap();
        let mut buf = vec![0; r.output_buffer_size()];
        let info = r.next_frame(&mut buf).unwrap();
        buf.truncate(info.buffer_size());
        assert_eq!(info.bit_depth, ::png::BitDepth::Eight);
        let rgba = match info.color_type {
            ::png::ColorType::Rgba => buf,
            ::png::ColorType::Rgb => buf.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
            other => panic!("unexpected colour type {other:?}"),
        };
        (Image { width: info.width, height: info.height, rgba }, info.color_type)
    }

    fn image(width: u32, height: u32, alpha: u8) -> Image {
        let rgba = (0..width * height)
            .flat_map(|i| [(i * 7) as u8, (i * 13) as u8, (i * 29) as u8, alpha])
            .collect();
        Image { width, height, rgba }
    }

    #[test]
    fn the_bytes_are_a_png_of_the_stated_size() {
        let bytes = png(&image(5, 3, 255)).unwrap();
        assert!(is_png(&bytes));
        // IHDR is the first chunk: length, "IHDR", then width and height,
        // big-endian. Read here by offset, not through the decoder.
        assert_eq!(&bytes[12..16], b"IHDR");
        assert_eq!(u32::from_be_bytes(bytes[16..20].try_into().unwrap()), 5);
        assert_eq!(u32::from_be_bytes(bytes[20..24].try_into().unwrap()), 3);
    }

    #[test]
    fn an_opaque_image_comes_back_pixel_for_pixel_as_rgb() {
        let i = image(5, 3, 255);
        let (back, colour) = read_back(&png(&i).unwrap());
        assert_eq!(back, i);
        assert_eq!(colour, ::png::ColorType::Rgb);
    }

    #[test]
    fn an_image_with_alpha_keeps_it() {
        let mut i = image(5, 3, 255);
        i.rgba[7] = 10;
        let (back, colour) = read_back(&png(&i).unwrap());
        assert_eq!(back, i);
        assert_eq!(colour, ::png::ColorType::Rgba);
    }

    #[test]
    fn a_buffer_that_does_not_match_its_dimensions_is_refused() {
        let mut i = image(5, 3, 255);
        i.rgba.pop();
        assert_eq!(png(&i), None);
        // One byte too many, which dropping the alpha channel would hide.
        i.rgba.extend([255, 255]);
        assert_eq!(png(&i), None);
        assert_eq!(png(&Image { width: 0, height: 3, rgba: vec![] }), None);
    }

    #[test]
    fn is_png_reads_the_signature() {
        assert!(!is_png(b""));
        assert!(!is_png(b"\x89PNG\r\n\x1a"));
        assert!(!is_png(b"GIF89a.."));
        assert!(is_png(b"\x89PNG\r\n\x1a\nrest"));
    }

    /// The whole of what a paste does to a clipboard bitmap: a bottom-up
    /// `CF_DIB` in, a PNG out whose top-left pixel is the picture's top-left.
    #[test]
    fn a_clipboard_bitmap_becomes_a_png_the_right_way_up() {
        let mut dib = crate::dib::tests::header(3, 2, 24, 0, 0);
        dib.extend([255, 0, 0, 255, 255, 255, 0, 0, 0, 0xEE, 0xEE, 0xEE]); // bottom: blue white black
        dib.extend([0, 0, 255, 0, 255, 0, 255, 0, 0, 0xEE, 0xEE, 0xEE]); // top: red green blue
        let bytes = png(&crate::dib::decode(&dib).unwrap()).unwrap();
        let (back, _) = read_back(&bytes);
        assert_eq!((back.width, back.height), (3, 2));
        assert_eq!(
            back.rgba,
            [
                255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, // red green blue
                0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255, // blue white black
            ]
        );
    }
}
