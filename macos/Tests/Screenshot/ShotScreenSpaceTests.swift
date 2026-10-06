import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// Two displays of different densities side by side: a laptop panel at two
/// pixels to the point and an external one at one, to its right and lower.
struct ShotScreenSpaceTests {
    private typealias Pt = PixelPoint
    private let space = ShotScreenSpace([
        .init(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixels: .init(3024, 1964)),
        .init(frame: CGRect(x: 1512, y: 100, width: 1920, height: 1080), pixels: .init(1920, 1080)),
    ])

    @Test func displaysAreLaidSideBySideInWholePixels() {
        #expect(space.displays == [
            .init(rect: PixelRect(0, 0, 3024, 1964), scale: 2),
            .init(rect: PixelRect(3024, 0, 1920, 1080), scale: 1),
        ])
        // In the system's points the second starts at 1512, which is in the
        // middle of the first one's pixels; here they do not overlap.
        #expect(space.displays[0].rect.intersect(space.displays[1].rect) == nil)
    }

    @Test func aScaleIsReadOffThePictureAndNotAssumed() {
        let odd = ShotScreenSpace([.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), pixels: .init(1500, 750))])
        #expect(odd.displays[0].scale == 1.5)
        let empty = ShotScreenSpace([.init(frame: .zero, pixels: .init(10, 10))])
        #expect(empty.displays[0].scale == 1, "a display with no width divides nothing")
    }

    @Test func aPointIsOnTheDisplayWhoseFrameHoldsIt() {
        #expect(space.display(at: CGPoint(x: 10, y: 10)) == 0)
        #expect(space.display(at: CGPoint(x: 1511.5, y: 10)) == 0)
        #expect(space.display(at: CGPoint(x: 1512, y: 150)) == 1)
        #expect(space.display(at: CGPoint(x: 1512, y: 50)) == nil, "beside the first and above the second")
    }

    @Test func aPointBecomesThePixelItFallsIn() {
        #expect(space.pixel(ofLocal: CGPoint(x: 10, y: 20), on: 0) == Pt(20, 40))
        #expect(space.pixel(ofLocal: CGPoint(x: 10.5, y: 20.75), on: 0) == Pt(21, 41))
        #expect(space.pixel(ofLocal: CGPoint(x: 10.5, y: 20.75), on: 1) == Pt(3024 + 10, 20))
        #expect(space.pixel(ofGlobal: CGPoint(x: 1612, y: 150)) == Pt(3024 + 100, 50))
        #expect(space.pixel(ofGlobal: CGPoint(x: 100, y: 50)) == Pt(200, 100))
        #expect(space.pixel(ofGlobal: CGPoint(x: -5, y: 0)) == nil)
    }

    @Test func aPointOffTheDisplayIsBroughtToItsNearestPixel() {
        #expect(space.pixel(ofLocal: CGPoint(x: -3, y: -3), on: 0) == Pt(0, 0))
        #expect(space.pixel(ofLocal: CGPoint(x: 5000, y: 5000), on: 0) == Pt(3023, 1963))
        #expect(space.pixel(ofLocal: CGPoint(x: -3, y: 2000), on: 1) == Pt(3024, 1079))
        #expect(space.pixel(ofLocal: CGPoint(x: 1920, y: 1080), on: 1) == Pt(3024 + 1919, 1079), "the far edge is not a pixel")
    }

    @Test func aPixelGoesBackToWhereItsCornerIs() {
        #expect(space.local(Pt(20, 40), on: 0) == CGPoint(x: 10, y: 20))
        #expect(space.local(Pt(21, 41), on: 0) == CGPoint(x: 10.5, y: 20.5))
        #expect(space.local(Pt(3024 + 10, 20), on: 1) == CGPoint(x: 10, y: 20))
        #expect(space.local(PixelRect(20, 40, 100, 60), on: 0) == CGRect(x: 10, y: 20, width: 50, height: 30))
        #expect(space.local(PixelRect(3024 + 10, 20, 100, 60), on: 1) == CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    @Test func whatLeavesIsInTheDisplaysOwnPixels() {
        #expect(space.displayLocal(PixelRect(3024 + 10, 20, 100, 60), on: 1) == PixelRect(10, 20, 100, 60))
        #expect(space.displayLocal(PixelRect(10, 20, 100, 60), on: 0) == PixelRect(10, 20, 100, 60))
        #expect(space.fromDisplayLocal(PixelRect(10, 20, 100, 60), on: 1) == PixelRect(3024 + 10, 20, 100, 60))
        #expect(space.fromDisplayLocal(space.displayLocal(PixelRect(4000, 7, 5, 6), on: 1), on: 1) == PixelRect(4000, 7, 5, 6))
    }

    @Test func aWindowIsThePartOfItOnEachDisplay() {
        // Wholly on the first.
        #expect(space.pixels(ofGlobal: CGRect(x: 100, y: 50, width: 400, height: 300), on: 0)
            == PixelRect(200, 100, 800, 600))
        #expect(space.pixels(ofGlobal: CGRect(x: 100, y: 50, width: 400, height: 300), on: 1) == nil)
        // Across both: its left 112 points on the first, the rest on the
        // second, whose top is 100 points lower.
        let across = CGRect(x: 1400, y: 200, width: 500, height: 300)
        #expect(space.pixels(ofGlobal: across, on: 0) == PixelRect(2800, 400, 224, 600))
        #expect(space.pixels(ofGlobal: across, on: 1) == PixelRect(3024, 100, 388, 300))
        // Edges between pixels go to the nearest boundary.
        #expect(space.pixels(ofGlobal: CGRect(x: 10.2, y: 10.3, width: 100.1, height: 50.4), on: 0)
            == PixelRect(left: 20, top: 21, right: 221, bottom: 121))
        // Hanging off the top left.
        #expect(space.pixels(ofGlobal: CGRect(x: -50, y: -20, width: 100, height: 100), on: 0)
            == PixelRect(0, 0, 100, 160))
        #expect(space.pixels(ofGlobal: CGRect(x: 100, y: 50, width: 0, height: 300), on: 0) == nil)
    }

    @Test func windowsKeepTheirOrderAndAreListedOncePerDisplay() {
        let windows = space.windows([
            .init(id: 7, frame: CGRect(x: 1400, y: 200, width: 500, height: 300)),
            .init(id: 3, frame: CGRect(x: 100, y: 50, width: 400, height: 300)),
            .init(id: 9, frame: CGRect(x: 5000, y: 5000, width: 10, height: 10)),
        ])
        #expect(windows == [
            .init(id: 7, rect: PixelRect(2800, 400, 224, 600)),
            .init(id: 7, rect: PixelRect(3024, 100, 388, 300)),
            .init(id: 3, rect: PixelRect(200, 100, 800, 600)),
        ])
    }

    @Test func theEditorPicksTheWindowUnderAGlobalPoint() throws {
        let windows = space.windows([
            .init(id: 7, frame: CGRect(x: 1400, y: 200, width: 500, height: 300)),
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ])
        let at = try #require(space.pixel(ofGlobal: CGPoint(x: 1600, y: 300)))
        let editor = ShotEditor(displays: space.displays, windows: windows, prefs: ToolPrefs(), preselect: at)
        #expect(editor.selection == .init(rect: PixelRect(3024, 100, 388, 300), display: 1, window: 7))
        #expect(editor.scale == 1)
    }
}
