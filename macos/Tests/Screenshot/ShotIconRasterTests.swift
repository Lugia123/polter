import Foundation
import Testing
@testable import Ghostty

/// One icon into a button cell, and that it is the same pixels as the other
/// host's (`dev-docs/poltergeist/screenshot.md`, 9.8.5). The Windows host's
/// tests are `windows/shots/src/icon.rs`, case for case.
struct ShotIconRasterTests {
    /// How far this rasteriser's box may be from the generator's, in pixels
    /// on each edge, and how far the count of inked pixels may be, as a
    /// share. The three implementations do the same arithmetic, so the
    /// expected difference is none; the allowance is for a platform whose
    /// floating point rounds one sample the other way.
    private let edge = 1
    private let count = 0.02

    @Test func everyIconLandsWhereTheGeneratorSays() {
        #expect(ShotLook.icons.count == 21, "sixteen buttons and five sizes of T")
        var exact = 0
        var total = 0
        for icon in ShotLook.icons {
            #expect(icon.ink.count == 3, "\(icon.key): scales 1, 1.5 and 2")
            for want in icon.ink {
                #expect(want.cell == ShotStyle.px(Int(ShotLook.Size.button), scale: want.scale), "\(icon.key): the cell")
                let got = ShotIconRaster.mask(icon, cell: want.cell, scale: want.scale).ink
                let at = "\(icon.key) at scale \(want.scale)"
                #expect(abs(got.x - want.x) <= edge, "\(at): left \(got.x) for \(want.x)")
                #expect(abs(got.y - want.y) <= edge, "\(at): top \(got.y) for \(want.y)")
                #expect(abs((got.x + got.w) - (want.x + want.w)) <= edge, "\(at): right \(got.x + got.w) for \(want.x + want.w)")
                #expect(abs((got.y + got.h) - (want.y + want.h)) <= edge, "\(at): bottom \(got.y + got.h) for \(want.y + want.h)")
                let off = Double(abs(got.count - want.count))
                #expect(off <= Double(want.count) * count, "\(at): \(got.count) inked pixels for \(want.count)")
                total += 1
                if got == ShotIconRaster.InkBox(x: want.x, y: want.y, w: want.w, h: want.h, count: want.count) {
                    exact += 1
                }
            }
        }
        // The allowance above is for another platform. Here the answer is
        // the generator's to the pixel, and a build where it stops being so
        // has changed the rule.
        #expect(exact == total, "\(exact) of \(total) boxes are the generator's exactly")
    }

    @Test func theInkIsCentredInTheCellAndStaysInsideIt() throws {
        for key in ShotLook.toolbarIcons {
            let icon = try #require(ShotLook.icon(key))
            let ink = ShotIconRaster.mask(icon, cell: 56, scale: 2).ink
            // The artboard is 40 px in a 56 px cell: 8 px of margin, less
            // the half unit of slack the live area leaves.
            #expect(ink.x >= 8 && ink.y >= 8, "\(key): starts at (\(ink.x), \(ink.y))")
            #expect(ink.x + ink.w <= 48 && ink.y + ink.h <= 48, "\(key): ends at (\(ink.x + ink.w), \(ink.y + ink.h))")
        }
    }

    @Test func theFiveSizesOfTGrow() throws {
        let boxes = try ShotLook.fontIcons.map { ShotIconRaster.mask(try #require(ShotLook.icon($0)), cell: 56, scale: 2).ink }
        #expect(boxes.count == 5)
        for i in 1..<boxes.count {
            #expect(boxes[i].w > boxes[i - 1].w && boxes[i].h > boxes[i - 1].h, "\(boxes[i - 1]) then \(boxes[i])")
        }
    }

    @Test func aStrokeIsAsWideAsItIsToldToBe() throws {
        // The straight line runs corner to corner; across its middle the ink
        // is the stroke's width along the diagonal: 1.75 units * 40 / 24 px,
        // times the square root of two along a row.
        let m = ShotIconRaster.mask(try #require(ShotLook.icon("line")), cell: 56, scale: 2)
        let inked = (0..<56).filter { m.alpha[28 * 56 + $0] >= 128 }.count
        let want = ShotLook.IconGrid.stroke * 40.0 / 24.0 * 2.0.squareRoot()
        #expect(abs(Double(inked) - want) <= 1.0, "\(inked) px across for \(want)")
    }

    @Test func thePointerIsSolidAndTheRectangleIsHollow() throws {
        func share(_ key: String) throws -> Double {
            let ink = ShotIconRaster.mask(try #require(ShotLook.icon(key)), cell: 56, scale: 2).ink
            return Double(ink.count) / Double(ink.w * ink.h)
        }
        #expect(try share("select") >= 0.45)
        #expect(try share("rect") <= 0.45)
    }

    @Test func aFainterPartIsFainter() throws {
        // The mosaic's corner squares are solid and its edge squares 38%.
        let m = ShotIconRaster.mask(try #require(ShotLook.icon("mosaic")), cell: 56, scale: 2)
        func at(_ ux: Double, _ uy: Double) -> UInt8 {
            m.alpha[Int(8.0 + uy * 40.0 / 24.0) * 56 + Int(8.0 + ux * 40.0 / 24.0)]
        }
        #expect(at(6, 6) == 255)
        #expect(at(12, 6) == UInt8((0.38 * 255.0 + 0.5).rounded(.down)))
        #expect(at(0.5, 0.5) == 0)
    }

    @Test func nothingIsDrawnIntoNoCell() throws {
        let m = ShotIconRaster.mask(try #require(ShotLook.icon("done")), cell: 0, scale: 2)
        #expect(m.alpha.isEmpty)
        #expect(m.ink == ShotIconRaster.InkBox(x: 0, y: 0, w: 0, h: 0, count: 0))
    }
}
