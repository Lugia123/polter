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

/// Where the plate goes in the corners and along the lines where it flips
/// (task 1198, the magnifier's placement).
struct ShotMagnifierPlacementTests {
    typealias Pt = PixelPoint
    private let display = PixelRect(0, 0, 2400, 1400)
    private let plate = (w: 272, h: 430)
    private let offset = 32

    private func place(_ x: Int, _ y: Int, _ previous: ShotMagnifier.Flip = .init()) -> ShotMagnifier.Placement {
        ShotMagnifier.placement(pointer: Pt(x, y), plate: plate, offset: offset, display: display, previous: previous)
    }

    @Test func inEveryCornerAndOnEveryEdgeThePlateIsOnTheDisplayAndOffThePointer() {
        let last = Pt(display.right - 1, display.bottom - 1)
        let xs = [0, 1, 5, 1200, last.x - 5, last.x - 1, last.x]
        let ys = [0, 1, 5, 700, last.y - 5, last.y - 1, last.y]
        for x in xs {
            for y in ys {
                let r = place(x, y).rect
                #expect(display.intersect(r) == r, "on the display at \(x),\(y): \(r)")
                #expect(!r.contains(Pt(x, y)), "the pointer's pixel is free at \(x),\(y)")
                // The gap to the pointer is the offset, on whichever side.
                let gapX = r.x >= x ? r.x - x : x - r.right
                let gapY = r.y >= y ? r.y - y : y - r.bottom
                #expect(gapX == offset && gapY == offset, "gap \(gapX),\(gapY) at \(x),\(y)")
            }
        }
    }

    @Test func theBottomRightCornerPutsItAboveAndToTheLeft() {
        let p = place(2399, 1399)
        #expect(p.flip == .init(x: true, y: true))
        #expect(p.rect == PixelRect(2399 - 32 - 272, 1399 - 32 - 430, 272, 430))
        #expect(place(0, 0).flip == .init())
        #expect(place(2399, 0).flip == .init(x: true, y: false))
        #expect(place(0, 1399).flip == .init(x: false, y: true))
    }

    @Test func aDisplayAsBigAsTwoPlatesHasNoPlaceWhereNeitherSideFits() {
        // Neither side fits only where the room is under twice (offset +
        // plate): 608 px across, 924 px down. At exactly that every pointer
        // has a side.
        let exact = PixelRect(0, 0, 608, 924)
        for x in stride(from: 0, to: exact.w, by: 3) {
            for y in stride(from: 0, to: exact.h, by: 3) {
                let r = ShotMagnifier.place(pointer: Pt(x, y), plate: plate, offset: offset, display: exact)
                #expect(exact.intersect(r) == r && !r.contains(Pt(x, y)), "\(x),\(y)")
            }
        }
        // Smaller, the plate is clamped on the display (and may cover the
        // pointer): never off it.
        let small = PixelRect(0, 0, 560, 880)
        for x in stride(from: 0, to: small.w, by: 5) {
            for y in stride(from: 0, to: small.h, by: 5) {
                let r = ShotMagnifier.place(pointer: Pt(x, y), plate: plate, offset: offset, display: small)
                #expect(small.intersect(r) == r, "\(x),\(y): \(r)")
            }
        }
    }

    @Test func aSideKeptIsGivenUpWhenItNoLongerFits() {
        // Taken on the left at the right edge; carried to the left edge,
        // where the left no longer fits: back to the right whatever the
        // room is at the right.
        #expect(place(100, 500, .init(x: true, y: false)).flip.x == false)
        #expect(place(500, 100, .init(x: false, y: true)).flip.y == false)
        // On a display too narrow for the usual room to go back, with the
        // left not fitting but the right just fitting: the right.
        let narrow = PixelRect(0, 0, 420, 1400)
        let held = ShotMagnifier.placement(
            pointer: Pt(100, 500), plate: plate, offset: offset, display: narrow, previous: .init(x: true, y: false))
        #expect(held.flip.x == false && held.rect.x == 100 + offset)
        // Where the left still fits and the right is only just enough, it is kept.
        #expect(place(display.right - offset - plate.w - 1, 500, .init(x: true, y: false)).flip.x == true)
    }

    @Test func aPointerOnTheLineWhereItFlipsDoesNotMakeItJump() {
        // The line: where the plate would just not fit on the right.
        let line = display.right - offset - plate.w
        func sides(_ path: [Int], remembering: Bool) -> [Bool] {
            var flip = ShotMagnifier.Flip()
            return path.map { x in
                let now = ShotMagnifier.placement(
                    pointer: Pt(x, 500), plate: plate, offset: offset, display: display,
                    previous: remembering ? flip : .init())
                flip = now.flip
                return now.flip.x
            }
        }
        // A pixel either way, forty times.
        let jitter = (0..<40).map { line + ($0 % 2 == 0 ? 0 : 1) }
        func changes(_ s: [Bool]) -> Int { zip(s, s.dropFirst()).filter { $0 != $1 }.count }
        #expect(changes(sides(jitter, remembering: false)) == 39, "forgetting, it jumps every time")
        #expect(changes(sides(jitter, remembering: true)) <= 1, "remembering, it settles")
        // Out to the edge and back, a pixel at a time: one flip each way,
        // and the way back is `offset` further from the edge than the way out.
        let out = Array(stride(from: line - 100, through: line + 100, by: 1))
        let there = sides(out, remembering: true)
        #expect(changes(there) == 1)
        let flippedAt = out[there.firstIndex(of: true) ?? 0]
        let back = Array(out.reversed())
        let returning = sides(back, remembering: true)
        // Starting flipped (as the walk out ended), find where it lets go.
        var flip = ShotMagnifier.Flip(x: true, y: false)
        var letGoAt = Int.min
        for x in back {
            flip = ShotMagnifier.placement(pointer: Pt(x, 500), plate: plate, offset: offset, display: display, previous: flip).flip
            if !flip.x { letGoAt = x; break }
        }
        #expect(flippedAt - letGoAt >= offset, "out at \(flippedAt), back at \(letGoAt)")
        #expect(returning.last == false)
    }

    @Test func eachMoveOfAWalkKeepsThePlateOnTheDisplayAndOffThePointer() {
        var flip = ShotMagnifier.Flip()
        var seed: UInt64 = 7
        var p = Pt(1200, 700)
        for _ in 0..<5000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let dx = Int((seed >> 33) % 41) - 20, dy = Int((seed >> 13) % 41) - 20
            p = Pt(min(max(p.x + dx * 9, 0), 2399), min(max(p.y + dy * 9, 0), 1399))
            let now = ShotMagnifier.placement(pointer: p, plate: plate, offset: offset, display: display, previous: flip)
            flip = now.flip
            #expect(display.intersect(now.rect) == now.rect && !now.rect.contains(p), "\(p) \(now.rect)")
        }
    }
}
