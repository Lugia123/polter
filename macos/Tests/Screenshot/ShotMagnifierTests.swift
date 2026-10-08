import Foundation
import Testing
@testable import Ghostty

/// The magnifier beside the pointer (task 1196, 7; specification 9.9).
struct ShotMagnifierTests {
    typealias Pt = PixelPoint
    private let display = PixelRect(0, 0, 1920, 1080)

    @Test func theSampleIsOddAndCentredOnThePointer() {
        #expect(ShotMagnifier.cells == 15)
        #expect(ShotMagnifier.cells % 2 == 1)
        let r = ShotMagnifier.sample(around: Pt(100, 50))
        #expect(r == PixelRect(93, 43, 15, 15))
        // The middle cell of the sample is the pointer's pixel.
        #expect(r.x + r.w / 2 == 100 && r.y + r.h / 2 == 50)
        // At the corner it reaches off the display, which is not an error.
        #expect(ShotMagnifier.sample(around: Pt(0, 0)).x == -7)
    }

    @Test func theMetricsAreWholePixelsAtEveryScale() {
        for scale in [1.0, 1.5, 2.0, 3.0] {
            let m = ShotMagnifier.Metrics(scale: scale, textHeight: 20)
            #expect(m.cell * m.cells == m.image)
            #expect(m.cell == Int((8 * scale).rounded()))
            #expect(m.plateWidth == m.image + 2 * m.pad)
            #expect(m.plateHeight == m.pad + m.image + m.gap + 2 * m.rowHeight + m.pad)
            #expect(m.rowHeight >= 20 && m.rowHeight >= m.swatch, "a row holds its text and the swatch")
        }
        let two = ShotMagnifier.Metrics(scale: 2, textHeight: 30)
        #expect(two.image == 240 && two.cell == 16 && two.plateWidth == 240 + 2 * two.pad)
    }

    @Test func thePlateIsBelowAndRightOfThePointerAndFlipsAtTheEdges() {
        let plate = (w: 256, h: 340)
        func at(_ x: Int, _ y: Int) -> PixelRect {
            ShotMagnifier.place(pointer: Pt(x, y), plate: plate, offset: 32, display: display)
        }
        #expect(at(500, 300) == PixelRect(532, 332, 256, 340))
        // Not enough room on the right: on its left.
        #expect(at(1800, 300) == PixelRect(1800 - 32 - 256, 332, 256, 340))
        // Not enough room below: above.
        #expect(at(500, 900) == PixelRect(532, 900 - 32 - 340, 256, 340))
        // Both: up and to the left.
        #expect(at(1900, 1070) == PixelRect(1900 - 32 - 256, 1070 - 32 - 340, 256, 340))
        // Exactly enough room is room.
        #expect(at(1920 - 32 - 256, 1080 - 32 - 340) == PixelRect(1920 - 256, 1080 - 340, 256, 340))
    }

    @Test func thePlateIsOnTheDisplayAndNeverCoversThePixelUnderThePointer() {
        var checked = 0
        for (w, h) in [(256, 340), (512, 680)] {
            for y in stride(from: 0, to: 1080, by: 7) {
                for x in stride(from: 0, to: 1920, by: 11) {
                    let p = Pt(x, y)
                    let r = ShotMagnifier.place(pointer: p, plate: (w, h), offset: 32, display: display)
                    #expect(display.intersect(r) == r, "on the display at \(p)")
                    #expect(!r.contains(p), "the pixel under the pointer at \(p) is not under the plate \(r)")
                    checked += 1
                }
            }
        }
        #expect(checked > 20_000)
        // A second display, whose pixels start somewhere other than zero.
        let second = PixelRect(1920, 0, 2560, 1440)
        let r = ShotMagnifier.place(pointer: Pt(4470, 1430), plate: (256, 340), offset: 32, display: second)
        #expect(second.intersect(r) == r && !r.contains(Pt(4470, 1430)))
    }

    @Test func theWordsAreTheDisplaysOwnPixelsAndAnUpperCaseHex() {
        #expect(ShotMagnifier.hex(.init(r: 0x1A, g: 0x2B, b: 0x3C)) == "#1A2B3C")
        #expect(ShotMagnifier.hex(.init(r: 0, g: 0, b: 0)) == "#000000")
        #expect(ShotMagnifier.hex(.init(r: 255, g: 171, b: 5)) == "#FFAB05")
        #expect(ShotMagnifier.coordinates(Pt(10, 20), display: PixelRect(0, 0, 100, 100)) == "10, 20")
        // On the second of two displays the numbers are that display's.
        #expect(ShotMagnifier.coordinates(Pt(2000, 20), display: PixelRect(1920, 0, 100, 100)) == "80, 20")
    }

    @Test func onlyCommandCCopies() {
        #expect(ShotMagnifier.isCopyKey(.letter("c"), mods: [.command]))
        #expect(ShotMagnifier.isCopyKey(.letter("C"), mods: [.command]))
        #expect(!ShotMagnifier.isCopyKey(.letter("c"), mods: []))
        #expect(!ShotMagnifier.isCopyKey(.letter("c"), mods: [.command, .shift]))
        #expect(!ShotMagnifier.isCopyKey(.letter("v"), mods: [.command]))
        #expect(!ShotMagnifier.isCopyKey(.escape, mods: [.command]))
    }

    @Test func theGridIsEveryCellBoundaryAndTheCentreIsTheMiddleCell() {
        #expect(ShotMagnifier.gridOffsets(cells: 15, cell: 16) == (0...15).map { $0 * 16 })
        #expect(ShotMagnifier.centreCell(cells: 15, cell: 16) == PixelRect(112, 112, 16, 16))
        #expect(ShotMagnifier.centreCell(cells: 3, cell: 4) == PixelRect(4, 4, 4, 4))
    }

    @Test func aFrozenPictureGivesItsOwnPixelsAndThePlaceOffTheDisplayIsTheOutsideColour() throws {
        // 4 x 2, each pixel a different grey, on a display whose origin is
        // (10, 0) in the editor's space.
        var bytes: [UInt8] = []
        for i in 0..<8 { bytes += [UInt8(i * 10), UInt8(i * 10 + 1), UInt8(i * 10 + 2), 255] }
        let frozen = try #require(FrozenImage(rect: PixelRect(10, 0, 4, 2), rgbx: bytes))
        #expect(frozen.colour(at: Pt(10, 0)) == .init(r: 0, g: 1, b: 2))
        #expect(frozen.colour(at: Pt(13, 1)) == .init(r: 70, g: 71, b: 72))
        #expect(frozen.colour(at: Pt(9, 0)) == nil)
        #expect(frozen.colour(at: Pt(10, 2)) == nil)
        let outside = ShotStyle.RGB(r: 9, g: 8, b: 7)
        let patch = frozen.patch(PixelRect(9, -1, 3, 3), outside: outside)
        // Row -1 is all outside; row 0 starts with column 9, outside.
        #expect(Array(patch[0..<4]) == [9, 8, 7, 255])
        #expect(Array(patch[12..<16]) == [9, 8, 7, 255])
        #expect(Array(patch[16..<20]) == [0, 1, 2, 255], "column 10, row 0")
        #expect(Array(patch[20..<24]) == [10, 11, 12, 255])
        #expect(patch.count == 3 * 3 * 4)
    }
}
