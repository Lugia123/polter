//! Smooth shapes laid straight into a picture's pixels: rounded rectangles,
//! the ring round a chosen cell, its glow, an icon's ink.
//!
//! GDI has no anti-aliasing and cannot lay one colour over another at part
//! strength, and the overlay's look (`screenshot.md` §9.8) is made of both.
//! So nothing here goes through a device context: each shape says how much
//! of each pixel it covers and that much of its colour is laid over what is
//! there. Coordinates are virtual-screen pixels and may be fractions; a
//! pixel's centre is at its coordinate and a half.
//!
//! Buffers are B, G, R, X, top row first, as everywhere in this crate.

use crate::geom::Rect;
use crate::icon::Mask;
use crate::look::Rgba;

/// A rectangle whose edges need not be on pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Box2 {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Box2 {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Box2 {
        Box2 { x, y, w, h }
    }

    pub fn of(r: Rect) -> Box2 {
        Box2 { x: r.x as f64, y: r.y as f64, w: r.w as f64, h: r.h as f64 }
    }

    /// Smaller by `by` on every side; larger for a negative `by`.
    pub fn inset(self, by: f64) -> Box2 {
        Box2 { x: self.x + by, y: self.y + by, w: (self.w - 2.0 * by).max(0.0), h: (self.h - 2.0 * by).max(0.0) }
    }

    pub fn moved(self, dx: f64, dy: f64) -> Box2 {
        Box2 { x: self.x + dx, y: self.y + dy, ..self }
    }

    /// A square of side `side` centred where `self` is centred.
    pub fn centred(self, side: f64) -> Box2 {
        Box2 { x: self.x + (self.w - side) / 2.0, y: self.y + (self.h - side) / 2.0, w: side, h: side }
    }

    /// The whole pixels this reaches, grown by `by`.
    pub fn pixels(self, by: f64) -> Rect {
        Rect::from_ltrb(
            (self.x - by).floor() as i32,
            (self.y - by).floor() as i32,
            (self.x + self.w + by).ceil() as i32,
            (self.y + self.h + by).ceil() as i32,
        )
    }

    /// How far the point is outside the rectangle with corners rounded by
    /// `radius`; negative inside it.
    pub fn distance(self, radius: f64, px: f64, py: f64) -> f64 {
        let r = radius.min(self.w / 2.0).min(self.h / 2.0).max(0.0);
        let qx = (px - (self.x + self.w / 2.0)).abs() - (self.w / 2.0 - r);
        let qy = (py - (self.y + self.h / 2.0)).abs() - (self.h / 2.0 - r);
        (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt() + qx.max(qy).min(0.0) - r
    }
}

/// How much of a pixel is inside an edge its centre is `d` outside of.
fn cover(d: f64) -> f64 {
    (0.5 - d).clamp(0.0, 1.0)
}

/// The complementary error function, to seven places (Abramowitz and
/// Stegun 7.1.26).
pub fn erfc(x: f64) -> f64 {
    let t = 1.0 / (1.0 + 0.3275911 * x.abs());
    let y = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429)))) * (-x * x).exp();
    if x >= 0.0 {
        y
    } else {
        2.0 - y
    }
}

/// A picture being painted on: `bits` covers `rect`. Nothing is ever
/// written outside `clip`.
pub struct Surface<'a> {
    pub bits: &'a mut [u8],
    pub rect: Rect,
    pub clip: Rect,
}

impl<'a> Surface<'a> {
    /// `None` when `bits` is not `rect`'s size.
    pub fn new(bits: &'a mut [u8], rect: Rect) -> Option<Surface<'a>> {
        (rect.w > 0 && rect.h > 0 && bits.len() == rect.w as usize * rect.h as usize * 4).then_some(Surface { bits, rect, clip: rect })
    }

    /// Lay `alpha` (0 to 1) of `rgb` over the pixel at `(x, y)`.
    fn put(&mut self, x: i32, y: i32, rgb: (u8, u8, u8), alpha: f64) {
        if alpha <= 0.0 {
            return;
        }
        let at = ((y - self.rect.y) as usize * self.rect.w as usize + (x - self.rect.x) as usize) * 4;
        let a = alpha.min(1.0);
        for (c, ink) in self.bits[at..at + 3].iter_mut().zip([rgb.2, rgb.1, rgb.0]) {
            *c = (*c as f64 + (ink as f64 - *c as f64) * a).round() as u8;
        }
        self.bits[at + 3] = 255;
    }

    /// Every pixel of `area` that may be written, with `amount` saying how
    /// much of `colour` goes on the pixel whose centre is given.
    fn each(&mut self, area: Rect, colour: Rgba, amount: impl Fn(f64, f64) -> f64) {
        let Some(r) = area.intersect(self.rect).and_then(|r| r.intersect(self.clip)) else { return };
        for y in r.y..r.bottom() {
            for x in r.x..r.right() {
                let a = amount(x as f64 + 0.5, y as f64 + 0.5) * colour.a;
                self.put(x, y, (colour.r, colour.g, colour.b), a);
            }
        }
    }

    /// Lay `colour` over the one pixel at `(x, y)`.
    pub fn fill_one(&mut self, x: i32, y: i32, colour: Rgba) {
        self.each(Rect::new(x, y, 1, 1), colour, |_, _| 1.0);
    }

    /// Whole pixels of one colour: for lines that must not be smoothed.
    pub fn fill(&mut self, r: Rect, colour: Rgba) {
        self.each(r, colour, |_, _| 1.0);
    }

    /// A filled rectangle with corners rounded by `radius`.
    pub fn rounded(&mut self, b: Box2, radius: f64, colour: Rgba) {
        self.each(b.pixels(1.0), colour, |x, y| cover(b.distance(radius, x, y)));
    }

    /// A line `width` wide along the **inside** of `b`'s edge: its outer
    /// side is the edge itself.
    pub fn ring(&mut self, b: Box2, radius: f64, width: f64, colour: Rgba) {
        let inner = b.inset(width);
        let inner_radius = (radius - width).max(0.0);
        self.each(b.pixels(1.0), colour, |x, y| (cover(b.distance(radius, x, y)) - cover(inner.distance(inner_radius, x, y))).max(0.0));
    }

    /// A line `width` wide along the **outside** of `b`'s edge.
    pub fn outline(&mut self, b: Box2, radius: f64, width: f64, colour: Rgba) {
        self.ring(b.inset(-width), radius + width, width, colour);
    }

    /// The glow of a chosen cell: brightest on `b`'s edge and falling away
    /// on both sides of it as a Gaussian of `sigma` pixels does,
    /// `colour.a x 1/2 x erfc(d / (sigma x sqrt 2))` at `d` from the edge.
    pub fn glow(&mut self, b: Box2, radius: f64, sigma: f64, colour: Rgba) {
        let s = sigma.max(0.01) * std::f64::consts::SQRT_2;
        self.each(b.pixels(sigma * 3.0 + 1.0), colour, |x, y| 0.5 * erfc(b.distance(radius, x, y).abs() / s));
    }

    /// A shape's soft shadow: `b` blurred by `sigma`, and only where
    /// `over` (the shape itself, which is drawn on top) is not.
    pub fn shadow(&mut self, b: Box2, radius: f64, sigma: f64, over: Box2, colour: Rgba) {
        let s = sigma.max(0.01) * std::f64::consts::SQRT_2;
        self.each(b.pixels(sigma * 3.0 + 1.0), colour, |x, y| 0.5 * erfc(b.distance(radius, x, y) / s) * (1.0 - cover(over.distance(radius, x, y))));
    }

    /// An icon's ink: `mask` with its top-left pixel at `(x, y)`.
    pub fn ink(&mut self, x: i32, y: i32, mask: &Mask, colour: Rgba) {
        let side = mask.cell.max(0);
        let Some(r) = Rect::new(x, y, side, side).intersect(self.rect).and_then(|r| r.intersect(self.clip)) else { return };
        for py in r.y..r.bottom() {
            for px in r.x..r.right() {
                let a = mask.alpha[(py - y) as usize * side as usize + (px - x) as usize] as f64 / 255.0;
                self.put(px, py, (colour.r, colour.g, colour.b), a * colour.a);
            }
        }
    }

    /// A picture `image` (B, G, R, X, covering `at`) laid on through the
    /// rounded rectangle `b`: the toolbar's glass.
    pub fn picture(&mut self, at: Rect, image: &[u8], b: Box2, radius: f64) {
        if image.len() != at.w.max(0) as usize * at.h.max(0) as usize * 4 {
            return;
        }
        let Some(r) = at.intersect(self.rect).and_then(|r| r.intersect(self.clip)) else { return };
        for y in r.y..r.bottom() {
            for x in r.x..r.right() {
                let s = ((y - at.y) as usize * at.w as usize + (x - at.x) as usize) * 4;
                let a = cover(b.distance(radius, x as f64 + 0.5, y as f64 + 0.5));
                self.put(x, y, (image[s + 2], image[s + 1], image[s]), a);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WHITE: Rgba = Rgba { r: 255, g: 255, b: 255, a: 1.0 };
    const BLUE: Rgba = Rgba { r: 0x41, g: 0x9C, b: 0xFF, a: 1.0 };

    fn sheet(rect: Rect, grey: u8) -> Vec<u8> {
        vec![grey; rect.w as usize * rect.h as usize * 4]
    }
    fn at(buf: &[u8], rect: Rect, x: i32, y: i32) -> (u8, u8, u8) {
        let i = ((y - rect.y) as usize * rect.w as usize + (x - rect.x) as usize) * 4;
        (buf[i + 2], buf[i + 1], buf[i])
    }

    #[test]
    fn the_error_function_is_the_one_in_the_tables() {
        for (x, want) in [(0.0, 1.0), (0.5, 0.4795001), (1.0, 0.1572992), (2.0, 0.0046777), (-1.0, 1.8427008)] {
            assert!((erfc(x) - want).abs() < 1e-6, "erfc({x}) = {}", erfc(x));
        }
    }

    #[test]
    fn a_rounded_rectangle_is_whole_inside_gone_outside_and_soft_only_on_its_edge() {
        let rect = Rect::new(10, 10, 60, 40);
        let mut buf = sheet(rect, 0);
        let b = Box2::new(20.0, 16.0, 28.0, 28.0);
        Surface::new(&mut buf, rect).unwrap().rounded(b, 7.0, WHITE);
        // The middle, and the middle of each side right up to it.
        for (x, y) in [(34, 30), (20, 30), (47, 30), (34, 16), (34, 43)] {
            assert_eq!(at(&buf, rect, x, y), (255, 255, 255), "({x},{y})");
        }
        // One pixel out on every side: untouched.
        for (x, y) in [(19, 30), (48, 30), (34, 15), (34, 44)] {
            assert_eq!(at(&buf, rect, x, y), (0, 0, 0), "({x},{y})");
        }
        // The corner is cut off -- the corner pixel itself is empty -- and
        // the arc is neither all nor nothing somewhere along it.
        assert_eq!(at(&buf, rect, 20, 16), (0, 0, 0));
        let soft = (0..7).filter(|i| !matches!(at(&buf, rect, 20 + i, 22 - i).0, 0 | 255)).count();
        assert!(soft >= 1);
        // As much ink as its area: 28 x 28 less the four corners' squares
        // plus their quarter discs.
        let ink: f64 = buf.chunks_exact(4).map(|p| p[0] as f64 / 255.0).sum();
        let want = 28.0 * 28.0 - (4.0 - std::f64::consts::PI) * 49.0;
        assert!((ink - want).abs() < want * 0.01, "{ink} for {want}");
        // On a half-pixel edge the pixel is half covered.
        let mut buf = sheet(rect, 0);
        Surface::new(&mut buf, rect).unwrap().rounded(Box2::new(20.5, 16.0, 20.0, 20.0), 0.0, WHITE);
        assert_eq!(at(&buf, rect, 20, 26).0, 128);
    }

    #[test]
    fn a_ring_is_as_wide_as_it_is_said_to_be_and_inside_the_edge() {
        // A 56 px cell at 200%: the ring is 3 px, its outer side the edge.
        let rect = Rect::new(0, 0, 80, 80);
        let mut buf = sheet(rect, 0);
        let b = Box2::new(12.0, 12.0, 56.0, 56.0);
        Surface::new(&mut buf, rect).unwrap().ring(b, 14.0, 3.0, BLUE);
        let row: Vec<(u8, u8, u8)> = (8..24).map(|x| at(&buf, rect, x, 40)).collect();
        let blue = (0x41, 0x9C, 0xFF);
        assert_eq!(row[..4], [(0, 0, 0); 4], "outside the cell");
        assert_eq!(row[4..7], [blue; 3], "three pixels of ring from the edge in");
        assert_eq!(row[7..], [(0, 0, 0); 9], "and nothing inside it");
        assert_eq!(at(&buf, rect, 40, 40), (0, 0, 0));
        // An outline is the same on the other side of the edge.
        let mut buf = sheet(rect, 0);
        Surface::new(&mut buf, rect).unwrap().outline(b, 0.0, 2.0, BLUE);
        assert_eq!((at(&buf, rect, 9, 40), at(&buf, rect, 10, 40), at(&buf, rect, 11, 40), at(&buf, rect, 12, 40)), ((0, 0, 0), blue, blue, (0, 0, 0)));
    }

    #[test]
    fn the_glow_is_the_tables_at_every_distance_from_the_edge() {
        // Sigma 2, peak 40%: 0.200 on the edge, then 0.123, 0.063, 0.027,
        // 0.009 at 1 to 4 away and nothing from 5 (§9.8.4.2), both sides.
        let rect = Rect::new(0, 0, 100, 100);
        let mut buf = sheet(rect, 0);
        let b = Box2::new(30.5, 30.0, 40.0, 40.0);
        let glow = Rgba { a: 0.4, ..WHITE };
        Surface::new(&mut buf, rect).unwrap().glow(b, 0.0, 2.0, glow);
        // The pixel whose centre is on the left edge is at x = 30.
        for (d, want) in [(0, 0.200), (1, 0.123), (2, 0.063), (3, 0.027), (4, 0.009), (6, 0.0)] {
            let (out, inn) = (at(&buf, rect, 30 - d, 50).0 as f64 / 255.0, at(&buf, rect, 30 + d, 50).0 as f64 / 255.0);
            assert!((out - want).abs() < 0.004, "{d} px outside: {out} for {want}");
            assert!((inn - want).abs() < 0.004, "{d} px inside: {inn} for {want}");
        }
    }

    #[test]
    fn a_shadow_falls_below_the_shape_and_never_on_it() {
        let rect = Rect::new(0, 0, 200, 120);
        let mut buf = sheet(rect, 255);
        let plate = Box2::new(40.0, 30.0, 120.0, 40.0);
        let black = Rgba { r: 0, g: 0, b: 0, a: 0.3 };
        Surface::new(&mut buf, rect).unwrap().shadow(plate.moved(0.0, 4.0), 12.0, 7.0, plate, black);
        // Nothing on the plate.
        assert_eq!(at(&buf, rect, 100, 50), (255, 255, 255));
        // Darker under it than over it, and gone far away.
        let (under, over) = (at(&buf, rect, 100, 72).0, at(&buf, rect, 100, 27).0);
        assert!(under < over && over < 255, "{under} {over}");
        assert!(under > 255 - 77, "never more than 30%");
        assert_eq!(at(&buf, rect, 100, 110), (255, 255, 255));
    }

    #[test]
    fn nothing_is_written_outside_the_clip_or_off_the_picture() {
        let rect = Rect::new(0, 0, 40, 40);
        let mut buf = sheet(rect, 0);
        let mut s = Surface::new(&mut buf, rect).unwrap();
        s.clip = Rect::new(10, 10, 10, 10);
        s.rounded(Box2::new(-50.0, -50.0, 200.0, 200.0), 5.0, WHITE);
        s.glow(Box2::new(-5.0, -5.0, 30.0, 30.0), 3.0, 2.0, BLUE);
        s.fill(Rect::new(-9, -9, 99, 99), WHITE);
        let lit = buf.chunks_exact(4).filter(|p| p[0] != 0).count();
        assert_eq!(lit, 100);
        assert!(Surface::new(&mut buf[..12], rect).is_none());
    }

    #[test]
    fn a_picture_shows_through_its_rounded_shape_only() {
        let rect = Rect::new(0, 0, 60, 40);
        let mut buf = sheet(rect, 0);
        let at_rect = Rect::new(10, 10, 40, 20);
        let image = vec![200u8; 40 * 20 * 4];
        Surface::new(&mut buf, rect).unwrap().picture(at_rect, &image, Box2::of(at_rect), 8.0);
        assert_eq!(at(&buf, rect, 30, 20), (200, 200, 200));
        assert_eq!(at(&buf, rect, 10, 10), (0, 0, 0), "the corner is cut off");
        assert_eq!(at(&buf, rect, 9, 20), (0, 0, 0));
    }
}
