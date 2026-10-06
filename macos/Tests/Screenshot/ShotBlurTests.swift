import Foundation
import Testing
@testable import Ghostty

/// The frozen picture out of focus, and which part of it is sharp
/// (`dev-docs/poltergeist/screenshot.md`, 9.8.6 and 9.8.7).
struct ShotBlurTests {
    private func picture(_ width: Int, _ height: Int, _ colour: (Int, Int) -> (UInt8, UInt8, UInt8)) -> ShotBlur.Picture {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(x, y)
                bytes[(y * width + x) * 4] = c.0
                bytes[(y * width + x) * 4 + 1] = c.1
                bytes[(y * width + x) * 4 + 2] = c.2
            }
        }
        return ShotBlur.Picture(width: width, height: height, rgbx: bytes)!
    }

    private func red(_ p: ShotBlur.Picture, _ x: Int, _ y: Int) -> Int { Int(p.rgbx[(y * p.width + x) * 4]) }

    @Test func thePlanIsTheOneTheSpecificationTabulates() {
        // 9.8.6.3: three points outside the selection, twelve under a plate.
        #expect(ShotBlur.plan(sigma: 3, scale: 1) == .init(k: 2, radius: 1))
        #expect(ShotBlur.plan(sigma: 3, scale: 1.5) == .init(k: 2, radius: 2))
        #expect(ShotBlur.plan(sigma: 3, scale: 2) == .init(k: 4, radius: 1))
        #expect(ShotBlur.plan(sigma: 12, scale: 1) == .init(k: 2, radius: 6))
        #expect(ShotBlur.plan(sigma: 12, scale: 1.5) == .init(k: 2, radius: 9))
        #expect(ShotBlur.plan(sigma: 12, scale: 2) == .init(k: 4, radius: 6))
        // A blur that is asked for is never no blur.
        #expect(ShotBlur.plan(sigma: 0.1, scale: 1).radius == 1)
    }

    @Test func shrinkingTakesTheMeanOfEachBlockAndOfWhatThereIsAtTheEdge() {
        // 5 x 3 shrunk by 2 is 3 x 2; the last column and row are cut short.
        let p = picture(5, 3) { x, y in (UInt8(x * 10 + y * 100), 0, 0) }
        let s = ShotBlur.shrunk(p, by: 2)
        #expect(s.width == 3 && s.height == 2)
        #expect(red(s, 0, 0) == (0 + 10 + 100 + 110) / 4)
        #expect(red(s, 2, 0) == (40 + 140) / 2)
        #expect(red(s, 0, 1) == (200 + 210) / 2)
        #expect(red(s, 2, 1) == 240)
    }

    @Test func aFlatPictureStaysFlatAndAnEdgeSpreadsByTheRadius() {
        let flat = picture(40, 12) { _, _ in (90, 160, 30) }
        #expect(ShotBlur.boxBlurred(flat, radius: 3, passes: 3) == flat)

        // Black on the left, white from x = 20. One pass of radius 2 touches
        // two pixels each side of the edge and no more.
        let edge = picture(40, 6) { x, _ in x < 20 ? (0, 0, 0) : (255, 255, 255) }
        let once = ShotBlur.boxBlurred(edge, radius: 2, passes: 1)
        #expect(red(once, 17, 3) == 0)
        #expect(red(once, 18, 3) == 51)
        #expect(red(once, 19, 3) == 102)
        #expect(red(once, 20, 3) == 153)
        #expect(red(once, 21, 3) == 204)
        #expect(red(once, 22, 3) == 255)
        // And nothing leaks out at the picture's own edges.
        #expect(red(once, 0, 0) == 0 && red(once, 39, 5) == 255)
    }

    @Test func outsideTheSelectionIsDarkerByTheDataAndAnEdgeIsAsSoftAsThreePoints() throws {
        // 9.8.13 D: white reads 240, black 0, and a hard edge becomes one
        // whose 10%-90% width is about 2.56 sigma: 15 px at scale 2.
        let p = picture(400, 40) { x, _ in x < 200 ? (0, 0, 0) : (255, 255, 255) }
        let prepared = try #require(ShotBlur.prepare(p, scale: 2))
        #expect(prepared.k == 4)
        let out = prepared.outside
        #expect(out.width == 400 && out.height == 40)
        let white = Int((255 * (1 - ShotLook.Colour.outsideDim.a)).rounded())
        #expect(red(out, 390, 20) == white)
        #expect(red(out, 5, 20) == 0)
        let low = (0..<400).first { red(out, $0, 20) >= white / 10 }!
        let high = (0..<400).first { red(out, $0, 20) >= white * 9 / 10 }!
        #expect((12...20).contains(high - low), "the edge is \(high - low) px wide")
        // Centred on where the edge was.
        #expect(abs((low + high) / 2 - 200) <= 2)
    }

    @Test func aPlateIsBlurredMoreAndIsDarkerAndMoreVivid() throws {
        // Flat grey under a plate comes out at half its brightness.
        let grey = picture(400, 200) { _, _ in (200, 200, 200) }
        let prepared = try #require(ShotBlur.prepare(grey, scale: 2))
        let plate = try #require(ShotBlur.plate(from: prepared, scale: 2, rect: PixelRect(100, 60, 120, 40)))
        #expect(plate.width == 120 && plate.height == 40)
        #expect(red(plate, 60, 20) == Int(200 * ShotLook.Glass.plateBrightness))

        // A colour moves away from its own grey by the saturation.
        let tinted = picture(400, 200) { _, _ in (200, 100, 100) }
        let prepared2 = try #require(ShotBlur.prepare(tinted, scale: 2))
        let plate2 = try #require(ShotBlur.plate(from: prepared2, scale: 2, rect: PixelRect(100, 60, 120, 40)))
        let r = Double(plate2.rgbx[0]), g = Double(plate2.rgbx[1])
        // In: 100 apart. Out: 100 x 1.5 x 0.5 = 75 apart.
        #expect(abs((r - g) - 100 * ShotLook.Glass.plateSaturation * ShotLook.Glass.plateBrightness) <= 2)

        // The part asked for is the part given: a plate over the right half
        // of a split picture is light, over the left dark.
        let split = picture(800, 100) { x, _ in x < 400 ? (0, 0, 0) : (255, 255, 255) }
        let prepared3 = try #require(ShotBlur.prepare(split, scale: 2))
        let left = try #require(ShotBlur.plate(from: prepared3, scale: 2, rect: PixelRect(40, 20, 100, 40)))
        let right = try #require(ShotBlur.plate(from: prepared3, scale: 2, rect: PixelRect(660, 20, 100, 40)))
        #expect(red(left, 50, 20) == 0)
        #expect(red(right, 50, 20) == Int(255 * ShotLook.Glass.plateBrightness))
        // And one across the edge is soft across it: no hard step.
        let across = try #require(ShotBlur.plate(from: prepared3, scale: 2, rect: PixelRect(340, 20, 120, 40)))
        let steps = (1..<120).map { abs(red(across, $0, 20) - red(across, $0 - 1, 20)) }
        #expect(steps.max()! <= 6, "the biggest step is \(steps.max()!)")
    }
}

struct ShotVeilTests {
    private let whole = PixelRect(0, 0, 3600, 2338)
    private let a = PixelRect(100, 100, 800, 600)
    private let b = PixelRect(1200, 300, 900, 700)

    @Test func whatIsSharpOnADisplay() {
        func focus(
            _ index: Int, selection: (Int, PixelRect)? = nil, forming: (Int, PixelRect)? = nil,
            hover: (Int, PixelRect)? = nil, pointer: Int? = nil
        ) -> ShotVeil.Focus {
            ShotVeil.focus(
                display: index, whole: whole,
                selection: selection.map { (display: $0.0, rect: $0.1) },
                forming: forming.map { (display: $0.0, rect: $0.1) },
                hover: hover.map { (display: $0.0, rect: $0.1) },
                pointerDisplay: pointer)
        }
        // The window under the pointer; the other display is all out of focus.
        #expect(focus(0, hover: (0, a), pointer: 0) == .window(a))
        #expect(focus(1, hover: (0, a), pointer: 0) == .nothing)
        // No window to choose: the display the pointer is on is all sharp.
        #expect(focus(0, pointer: 0) == .window(whole))
        #expect(focus(1, pointer: 0) == .nothing)
        // The region being dragged out, and the selection, come first.
        #expect(focus(0, forming: (0, b), hover: (0, a), pointer: 0) == .region(b))
        #expect(focus(0, selection: (0, b), hover: (0, a), pointer: 0) == .region(b))
        #expect(focus(1, selection: (0, b), pointer: 1) == .nothing)
    }

    @Test func aWindowFadesInAndTheOneBeforeItFadesOut() {
        // An eighth of a second, so that the halves and quarters below are
        // exact in binary and can be compared outright.
        var fade = ShotVeil.Fade(duration: 0.125)
        fade.set(.window(a), at: 8)
        #expect(fade.layers(at: 8) == [])
        #expect(fade.layers(at: 8.0625) == [.init(rect: a, alpha: 0.5)])
        #expect(fade.layers(at: 8.125) == [.init(rect: a, alpha: 1)])
        #expect(fade.isMoving(at: 8.0625) && !fade.isMoving(at: 8.125))

        // On to another window: both are on screen, the new one on top.
        fade.set(.window(b), at: 16)
        #expect(fade.layers(at: 16.03125) == [.init(rect: a, alpha: 0.75), .init(rect: b, alpha: 0.25)])
        #expect(fade.layers(at: 16.125) == [.init(rect: b, alpha: 1)])

        // Back before it is over: each carries on from where it is.
        fade.set(.window(a), at: 32)
        fade.set(.window(b), at: 32.0625)
        #expect(fade.layers(at: 32.0625) == [.init(rect: a, alpha: 0.5), .init(rect: b, alpha: 0.5)])
        #expect(fade.layers(at: 32.125) == [.init(rect: a, alpha: 0.25), .init(rect: b, alpha: 0.75)])
        fade.settle(at: 33)
        #expect(fade.touched == [b])
    }

    @Test func aRegionIsSharpAtOnceAndLeavesNoTrail() {
        var fade = ShotVeil.Fade(duration: 0.12)
        fade.set(.window(a), at: 1)
        // Dragging starts: the region is whole on its first frame, and the
        // window it started in fades away under it.
        let r1 = PixelRect(300, 300, 10, 10)
        fade.set(.region(r1), at: 2)
        #expect(fade.layers(at: 2).last == .init(rect: r1, alpha: 1))
        #expect(fade.layers(at: 2).first == .init(rect: a, alpha: 1))
        // The next frame of the drag: the region moved, and the place it was
        // is not still fading.
        let r2 = PixelRect(300, 300, 60, 40)
        fade.set(.region(r2), at: 2.01)
        let layers = fade.layers(at: 2.01)
        #expect(!layers.contains { $0.rect == r1 })
        #expect(layers.last == .init(rect: r2, alpha: 1))
        // And when the window has gone, only the region is left.
        #expect(fade.layers(at: 2.2) == [.init(rect: r2, alpha: 1)])
        #expect(!fade.isMoving(at: 2.2))
    }

    @Test func withMotionReducedEverythingIsAtOnce() {
        var fade = ShotVeil.Fade(duration: 0)
        fade.set(.window(a), at: 5)
        #expect(fade.layers(at: 5) == [.init(rect: a, alpha: 1)])
        fade.set(.window(b), at: 6)
        #expect(fade.layers(at: 6) == [.init(rect: b, alpha: 1)])
        #expect(!fade.isMoving(at: 6))
    }

    @Test func theDirtyRectangleHoldsTheOldAndTheNewAndARing() {
        let dirty = ShotVeil.dirty([a, b], ring: 10, within: whole)
        #expect(dirty == PixelRect(left: 90, top: 90, right: 2110, bottom: 1010))
        // Cut to the display, and nothing from nothing.
        #expect(ShotVeil.dirty([PixelRect(-50, -50, 100, 100)], ring: 10, within: whole) == PixelRect(0, 0, 60, 60))
        #expect(ShotVeil.dirty([], ring: 10, within: whole) == nil)
        #expect(ShotVeil.dirty([PixelRect(5000, 5000, 10, 10)], ring: 10, within: whole) == nil)
    }
}
