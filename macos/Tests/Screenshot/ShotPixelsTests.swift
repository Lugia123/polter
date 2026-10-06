import Foundation
import ImageIO
import Testing
@testable import Ghostty

/// The Windows host's `pixels.rs` tests, with the same fixtures and the
/// same numbers (`dev-docs/poltergeist/screenshot.md`, 9.5, 9.7 and 10.1).
/// Channel order is R, G, B here and B, G, R there; the expectations are
/// written per channel.
struct ShotPixelsTests {
    /// A display that is not at the origin, as one on the left of the
    /// primary is not.
    private static let mon = PixelRect(-200, 50, 160, 120)

    private func px(_ buffer: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        ShotFixtures.pixel(buffer, width: width, x, y)
    }

    private func decode(_ png: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = out.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? (image.width, image.height, out) : nil
    }

    // MARK: Blocks

    private func spans(_ length: Int, _ block: Int) -> [[Int]] {
        ShotPixels.spans(length: length, block: block).map { [$0.start, $0.length] }
    }

    @Test func aSideIsCutIntoBlocksAndASliverJoinsItsNeighbour() {
        #expect(spans(40, 10) == [[0, 10], [10, 10], [20, 10], [30, 10]])
        // Four left over is under half a block: it joins the last one.
        #expect(spans(44, 10) == [[0, 10], [10, 10], [20, 10], [30, 14]])
        // Five is half: it stands.
        #expect(spans(45, 10) == [[0, 10], [10, 10], [20, 10], [30, 10], [40, 5]])
        #expect(spans(49, 10) == [[0, 10], [10, 10], [20, 10], [30, 10], [40, 9]])
        #expect(spans(10, 7) == [[0, 10]])
        #expect(spans(11, 7) == [[0, 7], [7, 4]])
        #expect(spans(41, 10) == [[0, 10], [10, 10], [20, 10], [30, 11]])
        #expect(spans(3, 10) == [[0, 3]])
        #expect(spans(10, 10) == [[0, 10]])
        #expect(spans(0, 10).isEmpty)
    }

    @Test func theBlocksCoverTheSideExactlyAndNoneIsASliver() {
        for block in 1...40 {
            for length in 1...200 {
                let s = ShotPixels.spans(length: length, block: block)
                #expect(s[0].start == 0)
                #expect(s.map(\.length).reduce(0, +) == length, "length \(length) block \(block)")
                for i in 1..<max(s.count, 1) {
                    #expect(s[i - 1].start + s[i - 1].length == s[i].start)
                }
                if length >= block {
                    #expect(s.allSatisfy { $0.length * 2 >= block }, "length \(length) block \(block)")
                }
            }
        }
    }

    @Test func fiveBitsKeepsTheEndsAndOnlyThirtyTwoValues() {
        #expect(ShotPixels.fiveBits(0) == 0)
        #expect(ShotPixels.fiveBits(255) == 255)
        #expect(ShotPixels.fiveBits(0b1010_1111) == 0b1010_1101)
        let distinct = Set((0...255).map { ShotPixels.fiveBits(UInt8($0)) })
        #expect(distinct.count == 32)
    }

    // MARK: Mosaic

    @Test func everyBlockOfAMosaicIsOneColour() throws {
        let frozen = ShotFixtures.frozen(Self.mon, seed: 1)
        let rect = PixelRect(-190, 60, 97, 53)
        let made = try #require(ShotPixels.mosaic(of: frozen, rect: rect, block: 16))
        #expect(made.rect == rect)
        var colours = Set<[UInt8]>()
        for (by, bh) in ShotPixels.spans(length: 53, block: 16) {
            for (bx, bw) in ShotPixels.spans(length: 97, block: 16) {
                let first = px(made.rgbx, 97, bx, by)
                var uniform = true
                for y in by..<(by + bh) {
                    for x in bx..<(bx + bw) where px(made.rgbx, 97, x, y) != first { uniform = false }
                }
                #expect(uniform, "block at (\(bx),\(by))")
                #expect(first[3] == 255)
                // Cut to five bits.
                #expect(first[..<3].allSatisfy { $0 == ShotPixels.fiveBits($0) })
                colours.insert(first)
            }
        }
        // Noise does not average to one colour everywhere.
        #expect(colours.count > 1)
    }

    @Test func rearrangingThePixelsInsideEachBlockGivesTheSameBytes() throws {
        let rect = PixelRect(-190, 60, 97, 53)
        let original = ShotFixtures.noise(pixels: Self.mon.w * Self.mon.h, seed: 2)
        let before = try #require(ShotPixels.mosaic(
            of: FrozenImage(rect: Self.mon, rgbx: original)!, rect: rect, block: 16))

        var shuffled = original
        var g = ShotLcg(99)
        func at(_ x: Int, _ y: Int) -> Int { ((y - Self.mon.y) * Self.mon.w + (x - Self.mon.x)) * 4 }
        for (by, bh) in ShotPixels.spans(length: 53, block: 16) {
            for (bx, bw) in ShotPixels.spans(length: 97, block: 16) {
                var cells: [Int] = []
                for y in by..<(by + bh) {
                    for x in bx..<(bx + bw) { cells.append(at(rect.x + x, rect.y + y)) }
                }
                var i = cells.count - 1
                while i >= 1 {
                    let j = Int(g.next()) % (i + 1)
                    let a = cells[i], b = cells[j]
                    for c in 0..<4 { shuffled.swapAt(a + c, b + c) }
                    cells.swapAt(i, j)
                    i -= 1
                }
            }
        }
        // The rearrangement did rearrange something.
        #expect(shuffled != original)
        let after = try #require(ShotPixels.mosaic(
            of: FrozenImage(rect: Self.mon, rgbx: shuffled)!, rect: rect, block: 16))
        #expect(after.rgbx == before.rgbx)
    }

    @Test func aBlocksColourIsTheAverageOfItsPixelsCutToFiveBits() throws {
        // Four pixels: one channel averages 25.25, one 2, one is 255.
        let rgbx: [UInt8] = [10, 0, 255, 0, 20, 0, 255, 0, 30, 0, 255, 0, 41, 8, 255, 0]
        let frozen = try #require(FrozenImage(rect: PixelRect(0, 0, 2, 2), rgbx: rgbx))
        let made = try #require(ShotPixels.mosaic(of: frozen, rect: PixelRect(0, 0, 2, 2), block: 2))
        #expect(px(made.rgbx, 2, 0, 0) == [ShotPixels.fiveBits(25), ShotPixels.fiveBits(2), 255, 255])
        #expect(px(made.rgbx, 2, 1, 1) == px(made.rgbx, 2, 0, 0))
    }

    @Test func aMosaicHangingOffTheDisplayIsThePartThatIsOnIt() throws {
        let frozen = ShotFixtures.frozen(Self.mon, seed: 3)
        let made = try #require(ShotPixels.mosaic(of: frozen, rect: PixelRect(-250, 0, 100, 100), block: 20))
        #expect(made.rect == PixelRect(-200, 50, 50, 50))
        #expect(made.rgbx.count == 50 * 50 * 4)
        #expect(ShotPixels.mosaic(of: frozen, rect: PixelRect(500, 500, 10, 10), block: 20) == nil)
    }

    @Test func overlappingMosaicsAreEachMadeFromTheOriginal() throws {
        let frozen = ShotFixtures.frozen(Self.mon, seed: 4)
        let a = PixelRect(-190, 60, 60, 60), b = PixelRect(-160, 80, 60, 60)
        let items = [ShotFixtures.item(.mosaic(a)), ShotFixtures.item(.mosaic(b))]
        var buffer = [UInt8](repeating: 0, count: Self.mon.w * Self.mon.h * 4)
        frozen.show(into: &buffer, covering: Self.mon)
        ShotPixels.applyMosaics(&buffer, covering: Self.mon, from: frozen, items: items, scale: 1)
        let alone = try #require(ShotPixels.mosaic(
            of: frozen, rect: b, block: ShotPixels.block(of: b, level: 1, scale: 1)))
        var same = true
        for y in 0..<60 {
            for x in 0..<60
            where px(buffer, Self.mon.w, b.x - Self.mon.x + x, b.y - Self.mon.y + y) != px(alone.rgbx, 60, x, y) {
                same = false
            }
        }
        #expect(same)
    }

    // MARK: Highlighter

    @Test func theHighlighterMultipliesAndAStrokeIsLaidOnce() {
        let rect = PixelRect(0, 0, 40, 40)
        var buffer = [UInt8](repeating: 255, count: 40 * 40 * 4)
        for c in 0..<3 { buffer[(10 * 40 + 20) * 4 + c] = 0 }
        // Out and back over the same pixels.
        let stroke = [PixelPoint(5, 10), PixelPoint(35, 10), PixelPoint(5, 10)]
        ShotPixels.highlight(&buffer, covering: rect, points: stroke, width: 8, colour: ShotStyle.colours[2])
        // Yellow (#FFD400) at 40% on white, once: 255, 238, 153.
        #expect(px(buffer, 40, 10, 10) == [255, 238, 153, 255])
        // Within half the width.
        #expect(px(buffer, 40, 10, 13) == [255, 238, 153, 255])
        // Outside it.
        #expect(px(buffer, 40, 10, 15) == [255, 255, 255, 255])
        // Black stays black.
        #expect(px(buffer, 40, 20, 10) == [0, 0, 0, 255])
        // The round end.
        #expect(px(buffer, 40, 2, 10) == [255, 238, 153, 255])
        #expect(px(buffer, 40, 0, 10) == [255, 255, 255, 255])
    }

    @Test func aHighlighterStrokePartlyOffTheBufferMarksOnlyWhatIsOnIt() {
        let rect = PixelRect(100, 100, 10, 10)
        var buffer = [UInt8](repeating: 255, count: 10 * 10 * 4)
        let red = ShotStyle.RGB(r: 255, g: 0, b: 0)
        ShotPixels.highlight(
            &buffer, covering: rect, points: [PixelPoint(90, 105), PixelPoint(104, 105)], width: 4, colour: red)
        #expect(px(buffer, 10, 0, 5) == [255, 153, 153, 255])
        #expect(px(buffer, 10, 9, 5) == [255, 255, 255, 255])
        // Wholly off it: nothing happens, and nothing is out of bounds.
        let before = buffer
        ShotPixels.highlight(
            &buffer, covering: rect, points: [PixelPoint(0, 0), PixelPoint(5, 5)], width: 4, colour: red)
        #expect(buffer == before)
    }

    // MARK: Tiles

    private func tiles(_ height: Int) -> [[Int]] {
        ShotPixels.tileSpans(height: height, max: 1800, overlap: 120).map { [$0.y, $0.height] }
    }

    @Test func tilesAreAtMostTheLimitTallAndShareTheirOverlap() {
        #expect(tiles(1000) == [[0, 1000]])
        #expect(tiles(1800) == [[0, 1800]])
        #expect(tiles(1801) == [[0, 1800], [1680, 121]])
        #expect(tiles(5000) == [[0, 1800], [1680, 1800], [3360, 1640]])
        #expect(tiles(0).isEmpty)
        for height in [1, 1799, 1800, 1801, 3480, 3481, 20000] {
            let t = tiles(height)
            #expect(t.allSatisfy { $0[1] <= 1800 })
            // The last tile ends at the bottom.
            #expect(t.last.map { $0[0] + $0[1] } == height)
            for i in 1..<max(t.count, 1) {
                // Neighbours share 120 px.
                #expect(t[i - 1][0] + t[i - 1][1] - t[i][0] == 120)
            }
        }
    }

    // MARK: What leaves

    private static let selection = PixelRect(-180, 60, 120, 100)
    private static let secret = PixelRect(-150, 80, 64, 48)

    private func composedWithAMosaic() -> ComposedImage {
        ComposedImage(
            frozen: ShotFixtures.frozen(Self.mon, seed: 7), selection: Self.selection,
            items: [ShotFixtures.item(.mosaic(Self.secret))], scale: 1, redact: [])!
    }

    /// How many pixels of the secret region in `image` are still what the
    /// frozen picture had there, and whether every block is one colour.
    private func leak(
        in image: (width: Int, height: Int, rgba: [UInt8]), origin: PixelPoint
    ) -> (uniform: Bool, sameAsOriginal: Int) {
        let original = ShotFixtures.noise(pixels: Self.mon.w * Self.mon.h, seed: 7)
        let block = ShotPixels.block(of: Self.secret, level: 1, scale: 1)
        let local = Self.secret.relative(to: origin)
        var uniform = true
        var same = 0
        for (by, bh) in ShotPixels.spans(length: Self.secret.h, block: block) {
            for (bx, bw) in ShotPixels.spans(length: Self.secret.w, block: block) {
                var first: [UInt8]?
                for y in by..<(by + bh) {
                    for x in bx..<(bx + bw) {
                        let iy = local.y + y
                        if iy < 0 || iy >= image.height { continue }
                        let at = (iy * image.width + local.x + x) * 4
                        let here = Array(image.rgba[at..<(at + 3)])
                        if first == nil { first = here }
                        if here != first { uniform = false }
                        let o = ((Self.secret.y + y - Self.mon.y) * Self.mon.w + (Self.secret.x + x - Self.mon.x)) * 4
                        if Array(original[o..<(o + 3)]) == here { same += 1 }
                    }
                }
            }
        }
        return (uniform, same)
    }

    @Test func theSavedFileIsTheComposedImage() throws {
        let composed = composedWithAMosaic()
        let png = try #require(composed.png())
        let image = try #require(decode(png))
        #expect(image.width == 120)
        #expect(image.height == 100)
        let leaked = leak(in: image, origin: composed.rect.origin)
        #expect(leaked.uniform)
        #expect(leaked.sameAsOriginal < 4)
        // Outside the mosaic the picture is the frozen one.
        let original = ShotFixtures.noise(pixels: Self.mon.w * Self.mon.h, seed: 7)
        let o = ((60 - Self.mon.y) * Self.mon.w + (-180 - Self.mon.x)) * 4
        #expect(Array(image.rgba[..<3]) == Array(original[o..<(o + 3)]))
    }

    @Test func everyTileIsCutFromTheComposedImage() throws {
        let composed = composedWithAMosaic()
        let tiles = composed.tiles(max: 40, overlap: 10)
        #expect(tiles.map { [$0.y, $0.height] } == [[0, 40], [30, 40], [60, 40]])
        for tile in tiles {
            let image = try #require(decode(tile.png))
            #expect(image.width == 120)
            #expect(image.height == tile.height)
            let leaked = leak(
                in: image, origin: PixelPoint(composed.rect.x, composed.rect.y + tile.y))
            #expect(leaked.uniform)
            #expect(leaked.sameAsOriginal < 4)
        }
    }

    @Test func theCheckItselfFailsOnAnImageThatWasNotComposed() throws {
        // The same selection with no mosaic: the check above has to see the
        // secret in it, or it is not a check.
        let raw = try #require(ComposedImage(
            frozen: ShotFixtures.frozen(Self.mon, seed: 7), selection: Self.selection,
            items: [], scale: 1, redact: []))
        let png = try #require(raw.png())
        let image = try #require(decode(png))
        let leaked = leak(in: image, origin: Self.selection.origin)
        #expect(!leaked.uniform)
        #expect(leaked.sameAsOriginal > 1000)
    }

    @Test func aRedactedRectangleIsBlackAndAMosaicOverItAveragesBlack() throws {
        let frozen = ShotFixtures.frozen(Self.mon, seed: 8)
        let selection = PixelRect(-180, 60, 100, 100)
        let pane = PixelRect(-170, 70, 60, 60)
        let inside = PixelRect(-160, 80, 32, 32)
        let outside = PixelRect(-100, 80, 16, 16)
        let items = [ShotFixtures.item(.mosaic(inside)), ShotFixtures.item(.mosaic(outside))]
        let composed = try #require(ComposedImage(
            frozen: frozen, selection: selection, items: items, scale: 1, redact: [pane]))
        func at(_ x: Int, _ y: Int) -> ShotStyle.RGB { composed.pixel(x: x - selection.x, y: y - selection.y) }
        let black = ShotStyle.RGB(r: 0, g: 0, b: 0)
        // Inside the pane, outside the mosaic.
        #expect(at(-165, 75) == black)
        // The mosaic over the pane saw black, not the pane.
        for (x, y) in [(-160, 80), (-145, 95), (-129, 111)] { #expect(at(x, y) == black) }
        // A mosaic elsewhere still averages the picture.
        #expect(at(-95, 85) != black)
        // Elsewhere untouched.
        let original = ShotFixtures.noise(pixels: Self.mon.w * Self.mon.h, seed: 8)
        let o = ((150 - Self.mon.y) * Self.mon.w + (-100 - Self.mon.x)) * 4
        #expect(at(-100, 150) == ShotStyle.RGB(r: original[o], g: original[o + 1], b: original[o + 2]))
    }

    @Test func whatIsDrawnOnTopIsInWhatLeaves() throws {
        var composed = composedWithAMosaic()
        var seen: PixelRect?
        composed.draw { bytes, rect in
            seen = rect
            bytes.replaceSubrange(0..<4, with: [1, 2, 3, 0])
        }
        #expect(seen == Self.selection)
        let png = try #require(composed.png())
        let image = try #require(decode(png))
        // Opaque whatever was written to the fourth byte.
        #expect(Array(image.rgba[..<4]) == [1, 2, 3, 255])
    }

    @Test func aSelectionIsCutToTheDisplayAndOneOffItIsNothing() {
        let frozen = ShotFixtures.frozen(Self.mon, seed: 9)
        let cut = ComposedImage(
            frozen: frozen, selection: PixelRect(-250, 0, 100, 100), items: [], scale: 1, redact: [])
        #expect(cut?.rect == PixelRect(-200, 50, 50, 50))
        let off = ComposedImage(
            frozen: frozen, selection: PixelRect(900, 900, 10, 10), items: [], scale: 1, redact: [])
        #expect(off == nil)
        #expect(FrozenImage(rect: Self.mon, rgbx: [UInt8](repeating: 0, count: 7)) == nil)
    }

    @Test func stitchedFramesBecomeAComposedImageOfTheirOwnHeight() {
        let composed = ComposedImage(width: 3, rgbx: [UInt8](repeating: 9, count: 3 * 4 * 5))
        #expect(composed?.width == 3)
        #expect(composed?.height == 5)
        #expect(ComposedImage(width: 3, rgbx: [UInt8](repeating: 9, count: 13)) == nil)
        #expect(ComposedImage(width: 0, rgbx: []) == nil)
    }

    // MARK: Redaction

    @Test func aShieldedPaneIsPaintedWhereItReachesIntoTheCapture() {
        let capture = PixelRect(100, 50, 400, 300)
        let panes = [
            // Wholly inside.
            PixelRect(150, 100, 100, 80),
            // Half off the left and top.
            PixelRect(50, 0, 100, 100),
            // Wholly outside.
            PixelRect(600, 400, 50, 50),
            // Touching the edge shares no pixel with it.
            PixelRect(500, 100, 20, 20),
            // Larger than the capture.
            PixelRect(0, 0, 1000, 1000),
        ]
        #expect(ShotPixels.redactions(panes: panes, in: capture) == [
            PixelRect(50, 50, 100, 80),
            PixelRect(0, 0, 50, 50),
            PixelRect(0, 0, 400, 300),
        ])
        #expect(ShotPixels.redactions(panes: [], in: capture).isEmpty)
    }

    @Test func blackingOutTouchesOnlyTheRectangle() {
        let rect = PixelRect(10, 10, 4, 3)
        var buffer = [UInt8](repeating: 200, count: 4 * 3 * 4)
        ShotPixels.blackOut(&buffer, covering: rect, rect: PixelRect(11, 11, 2, 5))
        #expect(px(buffer, 4, 0, 0) == [200, 200, 200, 200])
        #expect(px(buffer, 4, 1, 1) == [0, 0, 0, 255])
        #expect(px(buffer, 4, 2, 2) == [0, 0, 0, 255])
        #expect(px(buffer, 4, 3, 1) == [200, 200, 200, 200])
        #expect(px(buffer, 4, 1, 0) == [200, 200, 200, 200])
    }
}
