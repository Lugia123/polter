import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The pixel work: the frozen display, the mosaic, the highlighter, and the
// composed image that is the only thing allowed to leave. A port of the
// Windows host's `pixels.rs`; see `PixelGeometry.swift`.
//
// Buffers are **R, G, B, X** rows, top row first. (The Windows host's are
// B, G, R, X; every rule below is per channel, so the two give the same
// picture.) The fourth byte is ignored on the way in and written 255.
//
// # What leaves, and what cannot
//
// `FrozenImage` is a display as it was when the screenshot started. It has
// no method that encodes it and none that hands its bytes out for writing:
// it can only be read *from*, by `ComposedImage`. `ComposedImage` is the
// selection after the redactions and mosaics have been applied, and every
// way out -- `png`, `tiles`, `cgImage` -- is a method of it. So a file, a
// clipboard image or a tile that still showed what a mosaic covers would
// have to be produced by code that does not go through here
// (`dev-docs/poltergeist/screenshot.md`, 9.5: the original does not land).

/// A display's picture at the moment the screenshot was triggered.
struct FrozenImage {
    /// The display's rectangle in its own pixel space: origin zero.
    let rect: PixelRect
    fileprivate let rgbx: [UInt8]

    /// Nil when `rgbx` is not `rect.w × rect.h × 4` bytes.
    init?(rect: PixelRect, rgbx: [UInt8]) {
        guard rect.w > 0, rect.h > 0, rgbx.count == rect.w * rect.h * 4 else { return nil }
        self.rect = rect
        self.rgbx = rgbx
    }

    /// Copy the part of this picture that falls in `dstRect` into `dst`, a
    /// buffer covering `dstRect`. For the overlay's own display of it.
    func show(into dst: inout [UInt8], covering dstRect: PixelRect) {
        ShotPixels.blit(into: &dst, covering: dstRect, from: rgbx, covering: rect)
    }

    fileprivate func pixelOffset(_ x: Int, _ y: Int) -> Int {
        ((y - rect.y) * rect.w + (x - rect.x)) * 4
    }
}

enum ShotPixels {
    /// How tall a tile of a long screenshot may be, and how much two
    /// neighbours share (9.6).
    static let tileHeight = 1800
    static let tileOverlap = 120

    /// Copy the overlap of two buffers, each covering a rectangle of the
    /// same coordinate space.
    static func blit(into dst: inout [UInt8], covering dstRect: PixelRect, from src: [UInt8], covering srcRect: PixelRect) {
        guard let both = dstRect.intersect(srcRect),
              dst.count == dstRect.w * dstRect.h * 4,
              src.count == srcRect.w * srcRect.h * 4 else { return }
        let n = both.w * 4
        for y in both.y..<both.bottom {
            let s = ((y - srcRect.y) * srcRect.w + (both.x - srcRect.x)) * 4
            let d = ((y - dstRect.y) * dstRect.w + (both.x - dstRect.x)) * 4
            dst.replaceSubrange(d..<(d + n), with: src[s..<(s + n)])
        }
    }

    /// Fill `rect` of a buffer covering `dstRect` with black.
    static func blackOut(_ dst: inout [UInt8], covering dstRect: PixelRect, rect: PixelRect) {
        guard dst.count == max(dstRect.w, 0) * max(dstRect.h, 0) * 4,
              let r = rect.intersect(dstRect) else { return }
        for y in r.y..<r.bottom {
            var d = ((y - dstRect.y) * dstRect.w + (r.x - dstRect.x)) * 4
            for _ in 0..<r.w {
                dst[d] = 0
                dst[d + 1] = 0
                dst[d + 2] = 0
                dst[d + 3] = 255
                d += 4
            }
        }
    }

    // MARK: Mosaic

    /// How a side of `length` pixels is cut into blocks of `block`: the
    /// start and length of each, in order (9.7).
    ///
    /// The remainder `r = length mod block` decides the last block. **Less
    /// than half a block is merged into the block before it** (so the last
    /// one is `block + r` long); half a block or more stands as a block of
    /// its own. A sliver of a block averages over so few pixels that it
    /// shows what is under it -- a one-pixel column *is* that column. A side
    /// shorter than one block is one block.
    static func spans(length: Int, block: Int) -> [(start: Int, length: Int)] {
        guard length > 0 else { return [] }
        let block = max(block, 1)
        if length <= block { return [(0, length)] }
        let whole = length / block, rest = length % block
        var out: [(start: Int, length: Int)] = (0..<whole).map { ($0 * block, block) }
        if rest * 2 >= block {
            out.append((whole * block, rest))
        } else if !out.isEmpty {
            out[out.count - 1].length += rest
        }
        return out
    }

    /// An 8-bit channel reduced to its top five bits, the low three
    /// refilled from the top so that 0 stays 0 and 255 stays 255.
    static func fiveBits(_ value: UInt8) -> UInt8 {
        let q = value >> 3
        return (q << 3) | (q >> 2)
    }

    /// The mosaic of `rect` at `block` pixels, computed from the frozen
    /// picture: the part of `rect` on the display, and its pixels.
    ///
    /// Every block comes out one colour, and that colour depends on nothing
    /// but the average of the block's own pixels, each channel's integer
    /// sum divided by the count and cut to five bits. **So the output
    /// carries one number per block and nothing else**: rearranging the
    /// pixels inside a block in any way that keeps their sum leaves it byte
    /// for byte the same, which is the property the tests state.
    static func mosaic(of frozen: FrozenImage, rect: PixelRect, block: Int) -> (rect: PixelRect, rgbx: [UInt8])? {
        guard let r = rect.intersect(frozen.rect) else { return nil }
        var out = [UInt8](repeating: 0, count: r.w * r.h * 4)
        frozen.rgbx.withUnsafeBufferPointer { source in
            for (by, bh) in spans(length: r.h, block: block) {
                for (bx, bw) in spans(length: r.w, block: block) {
                    var sum: (UInt64, UInt64, UInt64) = (0, 0, 0)
                    for y in by..<(by + bh) {
                        var at = frozen.pixelOffset(r.x + bx, r.y + y)
                        for _ in 0..<bw {
                            sum.0 += UInt64(source[at])
                            sum.1 += UInt64(source[at + 1])
                            sum.2 += UInt64(source[at + 2])
                            at += 4
                        }
                    }
                    let n = UInt64(bw * bh)
                    let colour = (
                        fiveBits(UInt8(sum.0 / n)), fiveBits(UInt8(sum.1 / n)), fiveBits(UInt8(sum.2 / n))
                    )
                    for y in by..<(by + bh) {
                        var at = (y * r.w + bx) * 4
                        for _ in 0..<bw {
                            out[at] = colour.0
                            out[at + 1] = colour.1
                            out[at + 2] = colour.2
                            out[at + 3] = 255
                            at += 4
                        }
                    }
                }
            }
        }
        return (r, out)
    }

    /// The block size a mosaic annotation uses: its step, the display's
    /// scale and the short side of its own rectangle.
    static func block(of rect: PixelRect, level: Int, scale: Double) -> Int {
        ShotStyle.mosaicBlock(level: level, scale: scale, shortSide: min(rect.w, rect.h))
    }

    /// Draw every mosaic among `items` into `dst`, a buffer covering
    /// `dstRect`. Each is computed from the frozen picture, never from
    /// another mosaic's output, so overlapping ones do not compound.
    static func applyMosaics(_ dst: inout [UInt8], covering dstRect: PixelRect, from frozen: FrozenImage, items: [Annotation], scale: Double) {
        for item in items {
            guard case let .mosaic(rect) = item.shape,
                  let made = mosaic(of: frozen, rect: rect, block: block(of: rect, level: item.level, scale: scale)) else { continue }
            blit(into: &dst, covering: dstRect, from: made.rgbx, covering: made.rect)
        }
    }

    // MARK: Highlighter

    /// Lay a highlighter stroke over `dst`, a buffer covering `dstRect`.
    ///
    /// The colour goes on at 40% the way a marker does, by multiplying:
    /// each channel becomes `dst × (255 − 0.4 × (255 − c)) / 255`, so white
    /// paper takes the colour and black text stays black. **A stroke is
    /// laid once**, however often it crosses itself: the pixels it covers
    /// are found first and each is darkened one time.
    static func highlight(_ dst: inout [UInt8], covering dstRect: PixelRect, points: [PixelPoint], width: Int, colour: ShotStyle.RGB) {
        guard dst.count == max(dstRect.w, 0) * max(dstRect.h, 0) * 4, !points.isEmpty else { return }
        let radius = Double(max(width, 1)) / 2
        let reach = Int(radius.rounded(.up))
        let w = dstRect.w
        var covered = [Bool](repeating: false, count: w * dstRect.h)

        var segments: [(PixelPoint, PixelPoint)] = []
        if points.count == 1 {
            segments.append((points[0], points[0]))
        } else {
            for i in 0..<(points.count - 1) { segments.append((points[i], points[i + 1])) }
        }
        for (a, b) in segments {
            let area = PixelRect(
                left: min(a.x, b.x) - reach, top: min(a.y, b.y) - reach,
                right: max(a.x, b.x) + reach + 1, bottom: max(a.y, b.y) + reach + 1)
            guard let clipped = area.intersect(dstRect) else { continue }
            for y in clipped.y..<clipped.bottom {
                for x in clipped.x..<clipped.right
                where Annotation.distanceToSegment(PixelPoint(x, y), a, b) <= radius {
                    covered[(y - dstRect.y) * w + (x - dstRect.x)] = true
                }
            }
        }

        func factor(_ c: UInt8) -> UInt32 { 255 - (2 * (255 - UInt32(c)) + 2) / 5 }
        let factors = (factor(colour.r), factor(colour.g), factor(colour.b))
        for (i, on) in covered.enumerated() where on {
            let at = i * 4
            dst[at] = UInt8((UInt32(dst[at]) * factors.0 + 127) / 255)
            dst[at + 1] = UInt8((UInt32(dst[at + 1]) * factors.1 + 127) / 255)
            dst[at + 2] = UInt8((UInt32(dst[at + 2]) * factors.2 + 127) / 255)
        }
    }

    // MARK: Tiles

    /// Where the tiles of an image `height` tall start and how tall each
    /// is. Every tile but the last is `max` tall; each starts `max −
    /// overlap` below the one before; the last ends at the image's bottom.
    static func tileSpans(height: Int, max maxHeight: Int = tileHeight, overlap: Int = tileOverlap) -> [(y: Int, height: Int)] {
        let maxHeight = max(maxHeight, 1)
        let step = max(maxHeight - overlap, 1)
        var out: [(y: Int, height: Int)] = []
        var y = 0
        while height > 0 {
            let h = min(maxHeight, height - y)
            out.append((y, h))
            if y + h >= height { break }
            y += step
        }
        return out
    }

    // MARK: Redaction

    /// The rectangles to paint black in a capture of `capture`, in the
    /// capture's own coordinates: each shielded pane's rectangle cut to the
    /// capture and moved so that the capture's corner is the origin
    /// (`dev-docs/poltergeist/screenshot.md`, 10.1). A pane that does not
    /// reach into the capture is not in the result.
    ///
    /// `panes` and `capture` are in the same space, one display's pixels.
    /// Nothing here knows whether a pane is covered by another window, on
    /// purpose: it is painted either way.
    static func redactions(panes: [PixelRect], in capture: PixelRect) -> [PixelRect] {
        panes.compactMap { $0.intersect(capture)?.relative(to: capture.origin) }
    }
}

/// The selection as it will leave: cut from the frozen picture, blacked out
/// where it must be, mosaics applied. The only door; see the top of this
/// file.
struct ComposedImage {
    /// The rectangle of the display this image is.
    private(set) var rect: PixelRect
    private var rgbx: [UInt8]

    var width: Int { rect.w }
    var height: Int { rect.h }

    /// Compose `selection` from the frozen picture.
    ///
    /// Order: the picture, then `redact` rectangles painted black (panes an
    /// agent must not see), then the mosaics among `items`. The other
    /// annotations are drawn afterwards, through `draw`. Nil when the
    /// selection does not lie on the display.
    ///
    /// **The black goes on before the mosaics are computed, not just
    /// before they are drawn.** A mosaic laid over a redacted pane averages
    /// black, not the pane: a block's colour is a number about what is
    /// under it, and that would be the pane's contents leaving at one value
    /// per block.
    init?(frozen: FrozenImage, selection: PixelRect, items: [Annotation], scale: Double, redact: [PixelRect]) {
        guard let rect = selection.intersect(frozen.rect) else { return nil }
        let source: FrozenImage
        if redact.isEmpty {
            source = frozen
        } else {
            var copy = frozen.rgbx
            for r in redact { ShotPixels.blackOut(&copy, covering: frozen.rect, rect: r) }
            guard let blacked = FrozenImage(rect: frozen.rect, rgbx: copy) else { return nil }
            source = blacked
        }
        var out = [UInt8](repeating: 0, count: rect.w * rect.h * 4)
        source.show(into: &out, covering: rect)
        ShotPixels.applyMosaics(&out, covering: rect, from: source, items: items, scale: scale)
        self.rect = rect
        self.rgbx = out
    }

    /// A composed image from pixels that never were a `FrozenImage`: a long
    /// screenshot's stitched frames, which carry no annotations, or an
    /// existing screenshot read back to be annotated.
    init?(width: Int, rgbx: [UInt8]) {
        let row = width * 4
        guard row > 0, !rgbx.isEmpty, rgbx.count % row == 0 else { return nil }
        self.rect = PixelRect(0, 0, width, rgbx.count / row)
        self.rgbx = rgbx
    }

    /// Draw on top of what is here: the annotations that are not mosaics.
    /// The closure gets the pixels and the rectangle they cover.
    mutating func draw(_ body: (inout [UInt8], PixelRect) -> Void) {
        body(&rgbx, rect)
    }

    /// One pixel, for tests and for nothing else.
    func pixel(x: Int, y: Int) -> ShotStyle.RGB {
        let at = (y * rect.w + x) * 4
        return ShotStyle.RGB(r: rgbx[at], g: rgbx[at + 1], b: rgbx[at + 2])
    }

    /// Rows `y ..< y + height` as a `CGImage`.
    func cgImage(y: Int = 0, height: Int? = nil) -> CGImage? {
        let height = height ?? rect.h
        let row = rect.w * 4
        guard y >= 0, height > 0, y + height <= rect.h else { return nil }
        // `noneSkipLast` below: the fourth byte is not alpha and is not
        // read, so the image is opaque whatever was left in it.
        let bytes = Data(rgbx[(y * row)..<((y + height) * row)])
        guard let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: rect.w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The image as a PNG: the file that is saved, and what goes on the
    /// clipboard.
    func png() -> Data? {
        cgImage().flatMap(Self.png)
    }

    /// The image cut into tiles for a long screenshot: each tile's `y` in
    /// the whole image, its height, and its PNG.
    func tiles(max: Int = ShotPixels.tileHeight, overlap: Int = ShotPixels.tileOverlap) -> [(y: Int, height: Int, png: Data)] {
        ShotPixels.tileSpans(height: rect.h, max: max, overlap: overlap).compactMap { span in
            guard let image = cgImage(y: span.y, height: span.height), let data = Self.png(image) else { return nil }
            return (span.y, span.height, data)
        }
    }
}
