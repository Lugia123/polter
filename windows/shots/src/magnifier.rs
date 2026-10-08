//! The magnifier beside the pointer (#1197): a small glass plate with the
//! pixels around the pointer made big, and under them the pointer's
//! coordinates and the colour of the pixel it is on.
//!
//! It helps to place an edge exactly: it is shown while there is no
//! selection and the pointer hovers, and through the whole of dragging a
//! selection out, by a handle, or by its middle; it goes when the selection
//! is settled and annotating begins. **All of the geometry is here and pure**
//! -- what is sampled, where the plate goes, what the words say -- and the
//! host only draws it.
//!
//! The numbers (how many pixels are sampled, how big each is drawn, the
//! plate's padding) and its colours are the shared look's ([`LOOK`]).

use crate::geom::{Point, Rect};
use crate::look::{colour, size};
use crate::pixels::{self, Frozen};
use crate::style::px_f;

/// What the plate is made of, in points: the shared look's
/// (`look::size::MAGNIFIER_*`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Params {
    /// Pixels sampled across and down; odd, so one is in the middle.
    pub cells: i32,
    /// How big each sampled pixel is drawn.
    pub cell: f64,
    /// Padding round the picture and the words.
    pub pad: f64,
    /// Between the pointer and the plate.
    pub offset: f64,
    /// Between the picture and the words, and between the two lines.
    pub gap: f64,
    /// The colour's swatch, a square this big.
    pub swatch: f64,
    /// The picture's corners.
    pub radius: f64,
    pub grid_line: f64,
    pub centre_line: f64,
}

/// The look's numbers.
pub const LOOK: Params = Params {
    cells: size::MAGNIFIER_CELLS as i32,
    cell: size::MAGNIFIER_CELL,
    pad: size::MAGNIFIER_PAD,
    offset: size::MAGNIFIER_OFFSET,
    gap: size::MAGNIFIER_ROW_GAP,
    swatch: size::MAGNIFIER_SWATCH,
    radius: size::MAGNIFIER_IMAGE_RADIUS,
    grid_line: size::MAGNIFIER_GRID_LINE,
    centre_line: size::MAGNIFIER_CENTRE_LINE,
};

/// A colour as `#RRGGBB`.
pub fn hex((r, g, b): (u8, u8, u8)) -> String {
    format!("#{r:02X}{g:02X}{b:02X}")
}

/// The pointer's place on its monitor, in that monitor's physical pixels:
/// `x, y`.
pub fn coordinates(pointer: Point, monitor: Rect) -> String {
    format!("{}, {}", pointer.x - monitor.x, pointer.y - monitor.y)
}

/// The pixels of `frozen` around `pointer`: `cells` across and down, row by
/// row, the pointer's own in the middle. `None` where the grid runs off the
/// picture.
pub fn sample(frozen: &Frozen, pointer: Point, cells: i32) -> Vec<Option<(u8, u8, u8)>> {
    let half = cells / 2;
    let mut out = Vec::with_capacity((cells * cells).max(0) as usize);
    for dy in -half..=half {
        for dx in -half..=half {
            out.push(frozen.rgb_at(Point::new(pointer.x + dx, pointer.y + dy)));
        }
    }
    out
}

/// The size of the picture part, in pixels.
pub fn picture_size(p: &Params, scale: f64) -> i32 {
    p.cells * px_f(p.cell, scale)
}

/// The plate for words `text` big (the wider of its lines, and their
/// total height): the picture over the words, padding all round.
pub fn plate_size(p: &Params, text: (i32, i32), scale: f64) -> (i32, i32) {
    let pad = px_f(p.pad, scale);
    let pic = picture_size(p, scale);
    (pic.max(text.0) + 2 * pad, pad + pic + px_f(p.gap, scale) + text.1 + pad)
}

/// Which side of the pointer the plate is on, on each axis: `true` is the
/// other side than the default (right, below). What the session remembers
/// from one pointer move to the next ([`place_from`]).
pub type Flipped = (bool, bool);

/// One axis of the plate: `p` is the pointer, `len` the plate, `[lo, hi)`
/// the monitor. The default side is after the pointer (`p + offset`), the
/// other before it. Returns where the plate starts and which side it is on.
///
/// - Leaving the default side takes only that it does not fit.
/// - **Coming back to it takes one more `offset` of room**, so a pointer
///   that rests on the line where it just fits, and shakes a pixel, does
///   not make the plate jump from one side to the other and back.
/// - A side that does not hold the plate is left whatever else is true.
fn axis(p: i32, len: i32, lo: i32, hi: i32, offset: i32, flipped: bool) -> (i32, bool) {
    let after = p + offset;
    let before = p - offset - len;
    let after_fits = after + len <= hi;
    let before_fits = before >= lo;
    let flipped = if flipped {
        // Back to the default only with room to spare, or when this side is full.
        !(after_fits && after + offset + len <= hi || !before_fits)
    } else {
        !after_fits
    };
    // On a monitor too small to hold it either way, the plate is clamped
    // inside, the top-left winning over the bottom-right.
    let at = if flipped { before } else { after };
    (at.min(hi - len).max(lo), flipped)
}

/// Where the plate goes, for a pointer that was where `from` says the plate
/// was: right of the pointer and below it, the other side of the pointer
/// where it would run off `monitor`, on both axes independently, and kept
/// on the side it is on until there is room to spare for the other
/// (`axis`). Returns the plate and the sides it is on now: what to hand back
/// at the next move.
pub fn place_from(pointer: Point, size: (i32, i32), monitor: Rect, offset: i32, from: Flipped) -> (Rect, Flipped) {
    let (x, fx) = axis(pointer.x, size.0, monitor.x, monitor.right(), offset, from.0);
    let (y, fy) = axis(pointer.y, size.1, monitor.y, monitor.bottom(), offset, from.1);
    (Rect::new(x, y, size.0, size.1), (fx, fy))
}

/// Where the plate goes with no memory: the first placement.
pub fn place(pointer: Point, size: (i32, i32), monitor: Rect, offset: i32) -> Rect {
    place_from(pointer, size, monitor, offset, (false, false)).0
}

/// The rectangle of the picture inside a plate at `plate`.
pub fn picture_at(plate: Rect, p: &Params, scale: f64) -> Rect {
    let pad = px_f(p.pad, scale);
    let s = picture_size(p, scale);
    Rect::new(plate.x + (plate.w - s) / 2, plate.y + pad, s, s)
}

/// The rectangle of sample `(col, row)` inside the picture.
pub fn cell_at(picture: Rect, p: &Params, scale: f64, col: i32, row: i32) -> Rect {
    let c = px_f(p.cell, scale);
    Rect::new(picture.x + col * c, picture.y + row * c, c, c)
}

/// The rows of `r` that fall inside `picture` with its corners rounded by
/// `radius`: each as the part of the row that is inside.
fn rounded_rows(r: Rect, picture: Rect, radius: i32) -> impl Iterator<Item = Rect> {
    let radius = radius.min(picture.w / 2).min(picture.h / 2).max(0);
    (r.y..r.bottom()).filter_map(move |y| {
        // How far in from each side this row of the picture starts.
        let rows_from_edge = (y - picture.y).min(picture.bottom() - 1 - y);
        let inset = if rows_from_edge >= radius {
            0
        } else {
            let dy = (radius - rows_from_edge) as f64 - 0.5;
            let dx = ((radius * radius) as f64 - dy * dy).max(0.0).sqrt();
            radius - dx.round() as i32
        };
        let (x0, x1) = (r.x.max(picture.x + inset), r.right().min(picture.right() - inset));
        (x1 > x0).then(|| Rect::new(x0, y, x1 - x0, 1))
    })
}

fn blend_rgba(dst: &mut [u8], dst_rect: Rect, r: Rect, c: crate::look::Rgba) {
    pixels::blend(dst, dst_rect, r, (c.r, c.g, c.b), (c.a * 256.0).round() as u32);
}

/// Draw the samples into `dst` (covering `dst_rect`) on `picture`, its
/// corners rounded: each as a block of its colour, a faint grid between
/// them, and the middle one ringed -- dark outside, light inside -- so the
/// pixel the pointer is on can be told on any colour.
pub fn draw_picture(dst: &mut [u8], dst_rect: Rect, picture: Rect, samples: &[Option<(u8, u8, u8)>], p: &Params, scale: f64) {
    let cells = p.cells;
    if samples.len() != (cells * cells) as usize {
        return;
    }
    let radius = px_f(p.radius, scale);
    let off = colour::MAGNIFIER_OFF_SCREEN;
    for row in 0..cells {
        for col in 0..cells {
            let r = cell_at(picture, p, scale, col, row);
            // Off the screen: the look's neutral.
            let rgb = samples[(row * cells + col) as usize].unwrap_or((off.r, off.g, off.b));
            for part in rounded_rows(r, picture, radius) {
                pixels::blend(dst, dst_rect, part, rgb, 256);
            }
        }
    }
    let c = px_f(p.cell, scale);
    let line = px_f(p.grid_line, scale);
    for i in 1..cells {
        for part in rounded_rows(Rect::new(picture.x + i * c, picture.y, line, picture.h), picture, radius) {
            blend_rgba(dst, dst_rect, part, colour::MAGNIFIER_GRID);
        }
        for part in rounded_rows(Rect::new(picture.x, picture.y + i * c, picture.w, line), picture, radius) {
            blend_rgba(dst, dst_rect, part, colour::MAGNIFIER_GRID);
        }
    }
    let mid = cell_at(picture, p, scale, cells / 2, cells / 2);
    let w = px_f(p.centre_line, scale);
    for (grow, ink) in [(0, colour::MAGNIFIER_CENTRE_OUTER), (w, colour::MAGNIFIER_CENTRE_INNER)] {
        let r = Rect::new(mid.x + grow, mid.y + grow, mid.w - 2 * grow, mid.h - 2 * grow);
        if r.w <= 2 * w || r.h <= 2 * w {
            continue;
        }
        blend_rgba(dst, dst_rect, Rect::new(r.x, r.y, r.w, w), ink);
        blend_rgba(dst, dst_rect, Rect::new(r.x, r.bottom() - w, r.w, w), ink);
        blend_rgba(dst, dst_rect, Rect::new(r.x, r.y + w, w, r.h - 2 * w), ink);
        blend_rgba(dst, dst_rect, Rect::new(r.right() - w, r.y + w, w, r.h - 2 * w), ink);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MON: Rect = Rect::new(0, 0, 1920, 1080);
    const P: Params = LOOK;

    fn frozen() -> Frozen {
        // 40 x 30 at (100, 50): the pixel at (x, y) is (x, y, 7) in R, G, B.
        let rect = Rect::new(100, 50, 40, 30);
        let mut bgrx = Vec::new();
        for y in 0..30u8 {
            for x in 0..40u8 {
                bgrx.extend([7, y + 50, x + 100, 0]);
            }
        }
        Frozen::new(rect, bgrx).unwrap()
    }

    #[test]
    fn a_colour_is_six_capital_hex_digits_after_a_hash() {
        assert_eq!(hex((0, 0, 0)), "#000000");
        assert_eq!(hex((255, 128, 10)), "#FF800A");
    }

    #[test]
    fn coordinates_are_the_monitors_own_pixels() {
        assert_eq!(coordinates(Point::new(2000, 30), Rect::new(1920, 0, 1920, 1080)), "80, 30");
    }

    #[test]
    fn the_sample_has_the_pointers_pixel_in_the_middle_and_nothing_off_the_picture() {
        let f = frozen();
        let s = sample(&f, Point::new(120, 60), 5);
        assert_eq!(s.len(), 25);
        assert_eq!(s[12], Some((120, 60, 7)), "the middle");
        assert_eq!(s[0], Some((118, 58, 7)), "top-left");
        assert_eq!(s[24], Some((122, 62, 7)), "bottom-right");
        // At the picture's own corner, half of the grid is off it.
        let s = sample(&f, Point::new(100, 50), 5);
        assert_eq!(s[0], None);
        assert_eq!(s[12], Some((100, 50, 7)));
        assert_eq!(s.iter().filter(|c| c.is_some()).count(), 9);
    }

    #[test]
    fn the_plate_is_right_and_below_and_flips_at_the_monitors_edges() {
        let size = (200, 260);
        let off = 18;
        assert_eq!(place(Point::new(500, 400), size, MON, off), Rect::new(518, 418, 200, 260));
        // No room to the right: left of the pointer. Below: above it.
        assert_eq!(place(Point::new(1800, 400), size, MON, off), Rect::new(1582, 418, 200, 260));
        assert_eq!(place(Point::new(500, 1000), size, MON, off), Rect::new(518, 722, 200, 260));
        assert_eq!(place(Point::new(1800, 1000), size, MON, off), Rect::new(1582, 722, 200, 260));
        // Exactly fitting does not flip.
        assert_eq!(place(Point::new(1920 - 218, 400), size, MON, off).x, 1920 - 200);
    }

    #[test]
    fn the_plate_never_leaves_the_monitor_on_the_left_or_top() {
        let r = place(Point::new(10, 10), (400, 400), Rect::new(0, 0, 300, 300), 18);
        assert!(r.x >= 0 && r.y >= 0);
    }

    #[test]
    fn the_plate_holds_the_picture_and_the_words_with_padding() {
        let (w, h) = plate_size(&P, (100, 40), 1.0);
        assert_eq!((w, h), (120 + 16, 8 + 120 + 6 + 40 + 8));
        let (w, _) = plate_size(&P, (300, 40), 2.0);
        assert_eq!(w, 300 + 32, "wide words widen the plate");
        let pic = picture_at(Rect::new(0, 0, w, 300), &P, 2.0);
        assert_eq!(pic.w, 240);
        assert_eq!(pic.x * 2 + pic.w, w, "centred");
    }

    #[test]
    fn the_middle_cell_is_ringed_and_the_others_wear_their_colours() {
        // At 200%: each sample 16 pixels, the rings 3 wide.
        let scale = 2.0;
        let picture = Rect::new(0, 0, 240, 240);
        let mut dst = vec![0u8; 240 * 240 * 4];
        let mut samples = vec![Some((10, 200, 30)); 225];
        samples[0] = None;
        draw_picture(&mut dst, picture, picture, &samples, &P, scale);
        let at = |x: usize, y: usize| {
            let i = (y * 240 + x) * 4;
            (dst[i + 2], dst[i + 1], dst[i])
        };
        assert_eq!(at(6, 6), (32, 32, 32), "off the screen: the look's neutral");
        assert_eq!(at(0, 0), (0, 0, 0), "the rounded corner is not painted");
        // A cell's inside, clear of the grid line.
        assert_eq!(at(16 * 3 + 8, 16 * 3 + 8), (10, 200, 30));
        // The ring: dark outside (the colour under 85% black), light inside
        // it, then the colour itself.
        let (mid, w) = (7 * 16, px_f(P.centre_line, scale) as usize);
        let outer = at(mid + 1, mid + 1);
        assert!(outer.0 < 5 && outer.1 < 40 && outer.2 < 6, "{outer:?}");
        assert_eq!(at(mid + w + 1, mid + w + 1), (255, 255, 255), "the light ring is inside the dark one");
        assert_eq!(at(mid + 2 * w + 1, mid + 2 * w + 1), (10, 200, 30));
    }

    /// The magnifier as the product draws it, on a made-up screen, for a
    /// person to look at. The words are the host's (GDI) and are not here:
    /// the two lines under the picture are empty, with the swatch.
    ///
    ///     SHOT_CHROME_DIR=/tmp/out cargo test --release -p polter-shots magnifier::tests::pictures -- --ignored
    #[test]
    #[ignore = "writes pictures, run by hand"]
    fn pictures_of_the_magnifier_for_a_person_to_look_at() {
        use crate::chrome::{label, Tones};
        use crate::glass::Glass;
        use crate::paint::Surface;
        let Ok(dir) = std::env::var("SHOT_CHROME_DIR") else { return };
        for (scale, tag) in [(1.0, "100"), (1.5, "150"), (2.0, "200")] {
            let rect = Rect::new(0, 0, (700.0 * scale) as i32, (470.0 * scale) as i32);
            let mut bgrx = vec![255u8; rect.w as usize * rect.h as usize * 4];
            for (i, px) in bgrx.chunks_exact_mut(4).enumerate() {
                let (x, y) = ((i % rect.w as usize) as i32, (i / rect.w as usize) as i32);
                let on = ((x / 3) + (y / 3)) % 2 == 0;
                let c: (u8, u8, u8) = match (x / (60.0 * scale) as i32 % 4, on) {
                    (0, _) => (230, 40, 40),
                    (1, true) => (45, 184, 77),
                    (2, true) => (47, 111, 237),
                    _ => (247, 247, 249),
                };
                px[..3].copy_from_slice(&[c.2, c.1, c.0]);
            }
            let frozen = Frozen::new(rect, bgrx.clone()).unwrap();
            let glass = Glass::new(rect, &bgrx, scale).unwrap();
            let mut out = bgrx.clone();
            let p = LOOK;
            // Two pointers: one with room, one at the right-bottom corner (flipped).
            for at in [Point::new((200.0 * scale) as i32, (120.0 * scale) as i32), Point::new(rect.w - 30, rect.h - 20)] {
                let text = ((90.0 * scale) as i32, (36.0 * scale) as i32);
                let size = plate_size(&p, text, scale);
                let plate = place(at, size, rect, px_f(p.offset, scale));
                if let Some(mut on) = Surface::new(&mut out, rect) {
                    label(&mut on, &glass, plate, scale, &Tones::LOOK);
                }
                let picture = picture_at(plate, &p, scale);
                draw_picture(&mut out, rect, picture, &sample(&frozen, at, p.cells), &p, scale);
                let swatch = (14.0 * scale) as i32;
                let top = picture.bottom() + px_f(p.gap, scale) + (18.0 * scale) as i32 + 4;
                pixels::blend(&mut out, rect, Rect::new(plate.x + px_f(p.pad, scale), top, swatch, swatch), frozen.rgb_at(at).unwrap(), 256);
            }
            let image = crate::Image::from_bgrx(rect.w as u32, rect.h as u32, &out).unwrap();
            std::fs::write(format!("{dir}/magnifier-{tag}pct.png"), crate::encode::png(&image).unwrap()).unwrap();
        }
    }

    // ---- the corners and the hysteresis (#1199 follow-up; as macOS)

    /// The four corners, as a person sees them: the pointer 5 px from each
    /// corner of a 700x470 piece of screen, at 100% and 150%.
    ///
    ///     SHOT_CHROME_DIR=/tmp/out cargo test --release -p polter-shots magnifier::tests::corners -- --ignored
    #[test]
    #[ignore = "writes pictures, run by hand"]
    fn corners_of_the_screen_pictured_for_a_person_to_look_at() {
        use crate::chrome::{label, Tones};
        use crate::glass::Glass;
        use crate::paint::Surface;
        let Ok(dir) = std::env::var("SHOT_CHROME_DIR") else { return };
        for (scale, tag) in [(1.0, "100"), (1.5, "150")] {
            let rect = Rect::new(0, 0, (700.0 * scale) as i32, (470.0 * scale) as i32);
            let mut bgrx = vec![255u8; rect.w as usize * rect.h as usize * 4];
            for (i, px) in bgrx.chunks_exact_mut(4).enumerate() {
                let (x, y) = ((i % rect.w as usize) as i32, (i / rect.w as usize) as i32);
                let on = ((x / 3) + (y / 3)) % 2 == 0;
                let c: (u8, u8, u8) = match (x / (60.0 * scale) as i32 % 4, on) {
                    (0, _) => (230, 40, 40),
                    (1, true) => (45, 184, 77),
                    (2, true) => (47, 111, 237),
                    _ => (247, 247, 249),
                };
                px[..3].copy_from_slice(&[c.2, c.1, c.0]);
            }
            let frozen = Frozen::new(rect, bgrx.clone()).unwrap();
            let glass = Glass::new(rect, &bgrx, scale).unwrap();
            let p = LOOK;
            let d = 5;
            for (name, at) in [
                ("top-left", Point::new(d, d)),
                ("top-right", Point::new(rect.w - 1 - d, d)),
                ("bottom-left", Point::new(d, rect.h - 1 - d)),
                ("bottom-right", Point::new(rect.w - 1 - d, rect.h - 1 - d)),
            ] {
                let mut out = bgrx.clone();
                let text = ((90.0 * scale) as i32, (36.0 * scale) as i32);
                let size = plate_size(&p, text, scale);
                let (plate, _) = place_from(at, size, rect, px_f(p.offset, scale), (false, false));
                if let Some(mut on) = Surface::new(&mut out, rect) {
                    label(&mut on, &glass, plate, scale, &Tones::LOOK);
                }
                let picture = picture_at(plate, &p, scale);
                draw_picture(&mut out, rect, picture, &sample(&frozen, at, p.cells), &p, scale);
                let swatch = (14.0 * scale) as i32;
                let top = picture.bottom() + px_f(p.gap, scale) + (18.0 * scale) as i32 + 4;
                pixels::blend(&mut out, rect, Rect::new(plate.x + px_f(p.pad, scale), top, swatch, swatch), frozen.rgb_at(at).unwrap(), 256);
                // The pointer's pixel, marked, so that the gap can be seen.
                pixels::blend(&mut out, rect, Rect::new(at.x - 1, at.y - 1, 3, 3), (0, 0, 0), 256);
                let image = crate::Image::from_bgrx(rect.w as u32, rect.h as u32, &out).unwrap();
                std::fs::write(format!("{dir}/corner-{name}-{tag}pct.png"), crate::encode::png(&image).unwrap()).unwrap();
            }
        }
    }

    /// One pointer and one plate size give the same sides however many
    /// times the frame is composed: the session keeps them in a cell that
    /// is written where the plate is placed (`shot.rs`), so this holds it up.
    #[test]
    fn placing_again_with_what_was_returned_changes_nothing() {
        let m = Rect::new(0, 0, 1920, 1080);
        let mut was = (false, false);
        for x in (0..1920).step_by(7).chain((0..1920).step_by(7).rev()) {
            for y in [3, 540, 1076] {
                let (plate, now) = place_from(Point::new(x, y), SIZE, m, OFF, was);
                assert_eq!(place_from(Point::new(x, y), SIZE, m, OFF, now), (plate, now), "({x}, {y})");
                was = now;
            }
        }
    }


    const OFF: i32 = size::MAGNIFIER_OFFSET as i32;
    const SIZE: (i32, i32) = (220, 300);

    fn contains(m: Rect, r: Rect) -> bool {
        r.x >= m.x && r.y >= m.y && r.right() <= m.right() && r.bottom() <= m.bottom()
    }

    #[test]
    fn at_every_corner_and_edge_the_plate_is_inside_clear_of_the_pointer_and_one_offset_away() {
        let m = Rect::new(100, 50, 1440, 900);
        let (r, b) = (m.right() - 1, m.bottom() - 1);
        for d in [0, 1, 5] {
            // (pointer, which axes flip)
            let cases = [
                (Point::new(m.x + d, m.y + d), (false, false)),
                (Point::new(r - d, m.y + d), (true, false)),
                (Point::new(m.x + d, b - d), (false, true)),
                (Point::new(r - d, b - d), (true, true)),
                (Point::new(m.x + m.w / 2, m.y + d), (false, false)),
                (Point::new(m.x + m.w / 2, b - d), (false, true)),
                (Point::new(m.x + d, m.y + m.h / 2), (false, false)),
                (Point::new(r - d, m.y + m.h / 2), (true, false)),
            ];
            for (p, flips) in cases {
                let (plate, now) = place_from(p, SIZE, m, OFF, (false, false));
                assert!(contains(m, plate), "{p:?} -> {plate:?}");
                assert!(!plate.contains(p), "{p:?} is under {plate:?}");
                assert_eq!(now, flips, "{p:?}");
                // Exactly one offset from the pointer on each axis, on whichever side.
                let gap_x = if now.0 { p.x - plate.right() } else { plate.x - p.x };
                let gap_y = if now.1 { p.y - plate.bottom() } else { plate.y - p.y };
                assert_eq!((gap_x, gap_y), (OFF, OFF), "{p:?}");
            }
        }
    }

    #[test]
    fn a_pointer_shaking_on_the_line_where_the_plate_just_fits_does_not_make_it_jump() {
        let m = Rect::new(0, 0, 1920, 1080);
        // The pointer x where the default side just fits, and a pixel either way.
        let edge = m.right() - OFF - SIZE.0;
        let mut flips = 0;
        let mut was = (false, false);
        let mut last = None;
        for i in 0..40 {
            let p = Point::new(edge + (i % 2), 500);
            let (plate, now) = place_from(p, SIZE, m, OFF, was);
            if let Some(l) = last {
                if l != now.0 {
                    flips += 1;
                }
            }
            last = Some(now.0);
            was = now;
            assert!(contains(m, plate));
        }
        assert!(flips <= 1, "{flips} jumps");
        // Without memory the same shake does jump every time.
        let jumps = (0..40).filter(|i| place(Point::new(edge + 1 - (i % 2), 500), SIZE, m, OFF).x != place(Point::new(edge + 1, 500), SIZE, m, OFF).x).count();
        assert!(jumps >= 20, "the shake is on the line: {jumps}");
    }

    #[test]
    fn the_way_out_and_the_way_back_are_an_offset_apart() {
        let m = Rect::new(0, 0, 1920, 1080);
        let out = (0..m.right()).find(|x| place_from(Point::new(*x, 500), SIZE, m, OFF, (false, false)).1 .0).unwrap();
        // Back from the flipped side, moving left: the first x that is default again.
        let back = (0..out).rev().find(|x| !place_from(Point::new(*x, 500), SIZE, m, OFF, (true, false)).1 .0).unwrap();
        assert!(out - back >= OFF, "out at {out}, back at {back}");
        // The same on the vertical axis.
        let out = (0..m.bottom()).find(|y| place_from(Point::new(500, *y), SIZE, m, OFF, (false, false)).1 .1).unwrap();
        let back = (0..out).rev().find(|y| !place_from(Point::new(500, *y), SIZE, m, OFF, (false, true)).1 .1).unwrap();
        assert!(out - back >= OFF, "out at {out}, back at {back}");
    }

    #[test]
    fn a_side_that_cannot_hold_the_plate_is_always_left() {
        let m = Rect::new(0, 0, 1920, 1080);
        // Flipped, at the left edge: before-side cannot hold it, so the plate goes after.
        let (_, now) = place_from(Point::new(10, 500), SIZE, m, OFF, (true, true));
        assert_eq!(now, (false, false));
        // Where the default side fits but with no room to spare, and the
        // other side does not fit at all: the plate must not stay on the
        // side that has none.
        let narrow = Rect::new(0, 0, 300, 800);
        let (plate, now) = place_from(Point::new(50, 400), SIZE, narrow, OFF, (true, false));
        assert_eq!(now.0, false, "a full side is left even without room to spare on the other");
        assert!(contains(narrow, plate));
        // Not flipped, at the right edge: goes before.
        let (_, now) = place_from(Point::new(1915, 1075), SIZE, m, OFF, (false, false));
        assert_eq!(now, (true, true));
    }

    #[test]
    fn on_a_monitor_too_small_for_it_the_plate_is_still_on_it() {
        let m = Rect::new(10, 20, 200, 250);
        for p in [Point::new(10, 20), Point::new(209, 269), Point::new(100, 100)] {
            let (plate, _) = place_from(p, SIZE, m, OFF, (false, false));
            assert_eq!((plate.x, plate.y), (m.x, m.y), "{p:?}: the top-left wins");
        }
    }

    #[test]
    fn a_pointer_outside_the_monitor_still_gets_a_plate_inside_it() {
        let m = Rect::new(0, 0, 1920, 1080);
        for from in [(false, false), (true, true)] {
            let (plate, _) = place_from(Point::new(m.right() + 2 * OFF + 10, m.bottom() + 2 * OFF + 10), SIZE, m, OFF, from);
            assert!(contains(m, plate), "{plate:?}: not past the right and bottom edges");
        }
    }

    #[test]
    fn a_long_walk_keeps_the_plate_on_the_monitor_and_off_the_pointer() {
        let m = Rect::new(0, 0, 1280, 800);
        let mut seed = 0x2545F491u32;
        let mut next = |n: i32| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            (seed % n as u32) as i32
        };
        let mut p = Point::new(640, 400);
        let mut was = (false, false);
        for _ in 0..5000 {
            p = Point::new((p.x + next(41) - 20).clamp(0, m.w - 1), (p.y + next(41) - 20).clamp(0, m.h - 1));
            let (plate, now) = place_from(p, SIZE, m, OFF, was);
            was = now;
            assert!(contains(m, plate), "{p:?} -> {plate:?}");
            assert!(!plate.contains(p), "{p:?} under {plate:?}");
        }
    }

    #[test]
    fn a_cell_off_the_monitor_is_the_off_screen_colour() {
        let samples = sample(&frozen(), Point::new(0, 0), 3);
        assert_eq!(samples[0], None);
        let mut dst = vec![0u8; 100 * 100 * 4];
        let picture = Rect::new(0, 0, 3 * 10, 3 * 10);
        draw_picture(&mut dst, Rect::new(0, 0, 100, 100), picture, &samples, &Params { cells: 3, cell: 10.0, ..LOOK }, 1.0);
        let o = colour::MAGNIFIER_OFF_SCREEN;
        let px = &dst[(5 * 100 + 5) * 4..][..4];
        assert_eq!((px[2], px[1], px[0]), (o.r, o.g, o.b), "the first cell, off the monitor");
    }
}
