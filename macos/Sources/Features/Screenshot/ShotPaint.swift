import Foundation

/// A small canvas the overlay's own furniture is painted on -- the toolbar's
/// plate, its cells, the rings and the glow -- one pixel at a time
/// (`dev-docs/poltergeist/screenshot.md`, 9.8.4 and 9.8.6).
///
/// CoreGraphics would draw all of this, and draw it well; the other host has
/// GDI, which has no anti-aliasing, no soft shadow and no per-pixel alpha.
/// What is drawn here is arithmetic on distances, which is the same on both:
/// every shape is a rounded rectangle or a circle, and how much of a pixel a
/// shape covers is how far the pixel's centre is from the shape's edge.
///
/// Colours are premultiplied and kept as `Double`, 0 to 1, so that laying
/// one thing over another is one line and nothing is rounded until the end.
struct ShotCanvas {
    let width: Int
    let height: Int
    /// R, G, B, A for each pixel, top row first, premultiplied.
    private(set) var pixels: [Double]

    init(width: Int, height: Int) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        pixels = [Double](repeating: 0, count: self.width * self.height * 4)
    }

    /// A rectangle with rounded corners, in the canvas's pixels. Not
    /// whole numbers: half a pixel is half a pixel.
    struct Shape: Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var radius: Double

        /// The same shape grown by `d` on every side (shrunk when negative),
        /// its corners with it.
        func grown(by d: Double) -> Shape {
            Shape(x: x - d, y: y - d, w: w + 2 * d, h: h + 2 * d, radius: max(radius + d, 0))
        }

        static func circle(cx: Double, cy: Double, diameter: Double) -> Shape {
            Shape(x: cx - diameter / 2, y: cy - diameter / 2, w: diameter, h: diameter, radius: diameter / 2)
        }

        /// How far `(px, py)` is from the edge: negative inside, positive
        /// outside.
        func distance(_ px: Double, _ py: Double) -> Double {
            let r = min(radius, min(w, h) / 2)
            let qx = abs(px - (x + w / 2)) - (w / 2 - r)
            let qy = abs(py - (y + h / 2)) - (h / 2 - r)
            let ox = max(qx, 0), oy = max(qy, 0)
            return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
        }
    }

    /// A colour, not premultiplied, each part 0 to 1.
    struct Ink: Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        init(_ c: ShotLook.RGBA, times alpha: Double = 1) {
            r = Double(c.r) / 255
            g = Double(c.g) / 255
            b = Double(c.b) / 255
            a = c.a * alpha
        }

        init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        /// This colour part of the way to `other`.
        func mixed(with other: Ink, _ t: Double) -> Ink {
            Ink(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
        }
    }

    /// Lay `ink`, thinned by `coverage`, over the pixel at `k`.
    @inline(__always)
    private mutating func over(_ k: Int, _ ink: Ink, _ coverage: Double) {
        let a = ink.a * coverage
        guard a > 0 else { return }
        let keep = 1 - a
        pixels[k] = ink.r * a + pixels[k] * keep
        pixels[k + 1] = ink.g * a + pixels[k + 1] * keep
        pixels[k + 2] = ink.b * a + pixels[k + 2] * keep
        pixels[k + 3] = a + pixels[k + 3] * keep
    }

    private struct Span {
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int
    }

    /// The pixels a shape and `reach` around it can touch.
    private func span(_ s: Shape, reach: Double) -> Span? {
        let x0 = max(Int((s.x - reach).rounded(.down)), 0), x1 = min(Int((s.x + s.w + reach).rounded(.up)), width)
        let y0 = max(Int((s.y - reach).rounded(.down)), 0), y1 = min(Int((s.y + s.h + reach).rounded(.up)), height)
        return x0 < x1 && y0 < y1 ? Span(x0: x0, x1: x1, y0: y0, y1: y1) : nil
    }

    /// How much of a pixel whose centre is `d` from an edge is inside it.
    @inline(__always)
    private static func coverage(_ d: Double) -> Double { min(max(0.5 - d, 0), 1) }

    /// Fill `shape` with `ink`.
    mutating func fill(_ shape: Shape, _ ink: Ink) {
        guard ink.a > 0, let s = span(shape, reach: 1) else { return }
        for y in s.y0..<s.y1 {
            for x in s.x0..<s.x1 {
                let c = Self.coverage(shape.distance(Double(x) + 0.5, Double(y) + 0.5))
                if c > 0 { over((y * width + x) * 4, ink, c) }
            }
        }
    }

    /// A line `thickness` wide just inside the edge of `shape`.
    mutating func strokeInside(_ shape: Shape, thickness: Double, _ ink: Ink) {
        guard ink.a > 0, thickness > 0, let s = span(shape, reach: 1) else { return }
        for y in s.y0..<s.y1 {
            for x in s.x0..<s.x1 {
                let d = shape.distance(Double(x) + 0.5, Double(y) + 0.5)
                // Inside the shape and not inside the shape shrunk by the
                // line's thickness.
                let c = Self.coverage(d) - Self.coverage(d + thickness)
                if c > 0 { over((y * width + x) * 4, ink, c) }
            }
        }
    }

    /// A line `thickness` wide just outside the edge of `shape`.
    mutating func strokeOutside(_ shape: Shape, thickness: Double, _ ink: Ink) {
        strokeInside(shape.grown(by: thickness), thickness: thickness, ink)
    }

    /// The share of a Gaussian of deviation `sigma` that lies further than
    /// `d` from its middle, on one side: a half at no distance, nothing far
    /// away -- and all of it far away on the other side, which is what a
    /// blurred edge is.
    static func tail(_ d: Double, sigma: Double) -> Double {
        guard sigma > 0 else { return d <= 0 ? 0.5 : 0 }
        return 0.5 * erfc(d / (sigma * 2.0.squareRoot()))
    }

    /// The glow of a ring along the edge of `shape`: `ink`, strongest on the
    /// edge and fading on both sides of it (9.8.4.2).
    mutating func glow(_ shape: Shape, sigma: Double, _ ink: Ink) {
        let reach = sigma * 3
        guard ink.a > 0, let s = span(shape, reach: reach) else { return }
        for y in s.y0..<s.y1 {
            for x in s.x0..<s.x1 {
                let d = abs(shape.distance(Double(x) + 0.5, Double(y) + 0.5))
                if d < reach { over((y * width + x) * 4, ink, Self.tail(d, sigma: sigma)) }
            }
        }
    }

    /// The shadow `shape` casts: itself, moved down by `dy` and blurred by
    /// `sigma`, in `ink`. Laid under whatever is already there.
    mutating func shadow(of shape: Shape, dy: Double, sigma: Double, _ ink: Ink) {
        let cast = Shape(x: shape.x, y: shape.y + dy, w: shape.w, h: shape.h, radius: shape.radius)
        let reach = sigma * 3
        guard ink.a > 0, let s = span(cast, reach: reach) else { return }
        for y in s.y0..<s.y1 {
            for x in s.x0..<s.x1 {
                let d = cast.distance(Double(x) + 0.5, Double(y) + 0.5)
                guard d < reach else { continue }
                // Inside it is all shadow; across the edge it falls away as
                // a blurred edge does: half at the edge itself.
                let a = ink.a * (sigma > 0 ? Self.tail(d, sigma: sigma) : Self.coverage(d))
                let k = (y * width + x) * 4
                // Under: only where nothing has been painted yet.
                let room = 1 - pixels[k + 3]
                pixels[k] += ink.r * a * room
                pixels[k + 1] += ink.g * a * room
                pixels[k + 2] += ink.b * a * room
                pixels[k + 3] += a * room
            }
        }
    }

    /// Fill `shape` with a picture: `picture`'s top left pixel is at
    /// `(left, top)` of the canvas. Pixels of the shape the picture does
    /// not reach are left alone.
    mutating func fill(_ shape: Shape, with picture: ShotBlur.Picture, left: Int, top: Int) {
        guard let s = span(shape, reach: 1) else { return }
        for y in s.y0..<s.y1 {
            let py = y - top
            guard py >= 0, py < picture.height else { continue }
            for x in s.x0..<s.x1 {
                let px = x - left
                guard px >= 0, px < picture.width else { continue }
                let c = Self.coverage(shape.distance(Double(x) + 0.5, Double(y) + 0.5))
                guard c > 0 else { continue }
                let p = (py * picture.width + px) * 4
                over((y * width + x) * 4, Ink(
                    r: Double(picture.rgbx[p]) / 255, g: Double(picture.rgbx[p + 1]) / 255,
                    b: Double(picture.rgbx[p + 2]) / 255, a: 1), c)
            }
        }
    }

    /// Lay an icon's coverage over the canvas in `ink`, its top left pixel
    /// at `(left, top)`.
    mutating func stamp(_ mask: ShotIconRaster.Mask, left: Int, top: Int, _ ink: Ink) {
        guard ink.a > 0 else { return }
        for my in 0..<mask.cell {
            let y = top + my
            guard y >= 0, y < height else { continue }
            for mx in 0..<mask.cell {
                let x = left + mx
                guard x >= 0, x < width else { continue }
                let a = mask.alpha[my * mask.cell + mx]
                if a > 0 { over((y * width + x) * 4, ink, Double(a) / 255) }
            }
        }
    }

    /// The canvas as bytes: R, G, B, A, premultiplied, top row first.
    var rgba: [UInt8] {
        pixels.map { UInt8(min(max(($0 * 255).rounded(), 0), 255)) }
    }

    /// A pixel's colour, not premultiplied: each part 0 to 255, alpha 0 to 1.
    struct Pixel: Equatable {
        var r: Int
        var g: Int
        var b: Int
        var a: Double
    }

    /// The colour at a pixel. For tests.
    func colour(_ x: Int, _ y: Int) -> Pixel {
        guard x >= 0, y >= 0, x < width, y < height else { return Pixel(r: 0, g: 0, b: 0, a: 0) }
        let k = (y * width + x) * 4
        let a = pixels[k + 3]
        guard a > 0 else { return Pixel(r: 0, g: 0, b: 0, a: 0) }
        func part(_ v: Double) -> Int { Int((v / a * 255).rounded()) }
        return Pixel(r: part(pixels[k]), g: part(pixels[k + 1]), b: part(pixels[k + 2]), a: a)
    }
}
