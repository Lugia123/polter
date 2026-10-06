import Foundation
import Testing
@testable import Ghostty

/// The selection's geometry in whole pixels
/// (`dev-docs/poltergeist/screenshot.md`, 3.2).
struct PixelGeometryTests {
    private typealias Pt = PixelPoint
    private let display = PixelRect(0, 0, 2000, 1600)
    private let selection = PixelRect(400, 200, 800, 600)

    @Test func aRectangleContainsItsNearEdgesAndNotItsFarOnes() {
        let r = PixelRect(10, 20, 30, 40)
        #expect(r.contains(Pt(10, 20)))
        #expect(r.contains(Pt(39, 59)))
        #expect(!r.contains(Pt(40, 20)))
        #expect(!r.contains(Pt(10, 60)))
        #expect(r.right == 40)
        #expect(r.bottom == 60)
        #expect(PixelRect.spanning(Pt(40, 60), Pt(10, 20)) == r)
        #expect(PixelRect(left: 10, top: 20, right: 40, bottom: 60) == r)
    }

    @Test func rectanglesMeetOnlyWhereTheyShareAPixel() {
        let a = PixelRect(0, 0, 10, 10)
        #expect(a.intersect(PixelRect(5, 5, 10, 10)) == PixelRect(5, 5, 5, 5))
        // Touching edges share nothing.
        #expect(a.intersect(PixelRect(10, 0, 10, 10)) == nil)
        #expect(a.intersect(PixelRect(50, 50, 1, 1)) == nil)
        #expect(a.clamp(Pt(-5, 50)) == Pt(0, 10))
    }

    @Test func fourPixelsIsStillAClickAndFiveIsADrag() {
        let down = Pt(100, 100)
        #expect(!PixelGeometry.isDrag(from: down, to: Pt(104, 100)))
        #expect(!PixelGeometry.isDrag(from: down, to: Pt(104, 96)))
        #expect(PixelGeometry.isDrag(from: down, to: Pt(105, 100)))
        #expect(PixelGeometry.isDrag(from: down, to: Pt(100, 95)))
    }

    @Test func aDragOffTheDisplayStopsAtItsEdgeAndOneWithNoAreaIsNothing() {
        #expect(PixelGeometry.dragSelection(from: Pt(1900, 100), to: Pt(2400, 300), within: display)
            == PixelRect(1900, 100, 100, 200))
        #expect(PixelGeometry.dragSelection(from: Pt(100, 100), to: Pt(100, 300), within: display) == nil)
    }

    @Test func theTopmostWindowUnderThePointIsPickedAndCutToTheDisplay() {
        let windows = [PixelRect(300, 300, 200, 100), PixelRect(100, 100, 600, 500), PixelRect(1900, 600, 300, 100)]
        #expect(PixelGeometry.pickWindow(windows, at: Pt(350, 350), within: display)?.index == 0)
        #expect(PixelGeometry.pickWindow(windows, at: Pt(150, 150), within: display)?.index == 1)
        #expect(PixelGeometry.pickWindow(windows, at: Pt(1950, 650), within: display)?.visible
            == PixelRect(1900, 600, 100, 100))
        #expect(PixelGeometry.pickWindow(windows, at: Pt(50, 50), within: display) == nil)
    }

    @Test func aPressTakesAHandleTheInsideOrNothingAndACornerBeatsASide() {
        #expect(PixelGeometry.hit(selection, at: Pt(1202, 798), grip: 6) == .handle(.se))
        #expect(PixelGeometry.hit(selection, at: Pt(800, 203), grip: 6) == .handle(.n))
        #expect(PixelGeometry.hit(selection, at: Pt(800, 500), grip: 6) == .inside)
        #expect(PixelGeometry.hit(selection, at: Pt(100, 100), grip: 6) == .outside)
        // A selection so small that a corner and a side are both in reach.
        let small = PixelRect(100, 100, 8, 8)
        #expect(PixelGeometry.hit(small, at: Pt(101, 103), grip: 6) == .handle(.nw))
    }

    @Test func aCornerMovesTwoEdgesASideOneAndPastTheOppositeEdgeItTurnsOver() {
        #expect(PixelGeometry.resize(selection, dragging: .se, to: Pt(1300, 900), within: display)
            == PixelRect(400, 200, 900, 700))
        #expect(PixelGeometry.resize(selection, dragging: .e, to: Pt(1300, 1500), within: display)
            == PixelRect(400, 200, 900, 600))
        #expect(PixelGeometry.resize(selection, dragging: .w, to: Pt(1400, 0), within: display)
            == PixelRect(1200, 200, 200, 600))
        // Stopped at the display.
        #expect(PixelGeometry.resize(selection, dragging: .se, to: Pt(9000, 9000), within: display)
            == PixelRect(400, 200, 1600, 1400))
        // Never thinner than one pixel.
        #expect(PixelGeometry.resize(selection, dragging: .w, to: Pt(1200, 0), within: display).w == 1)
        #expect(PixelGeometry.resize(selection, dragging: .w, to: Pt(1200, 0), within: display).x == 1200)
    }

    @Test func movingKeepsTheSizeAndStopsAtTheDisplay() {
        #expect(PixelGeometry.move(selection, by: Pt(50, -30), within: display) == PixelRect(450, 170, 800, 600))
        #expect(PixelGeometry.move(selection, by: Pt(9000, 9000), within: display) == PixelRect(1200, 1000, 800, 600))
        #expect(PixelGeometry.move(selection, by: Pt(-9000, -9000), within: display) == PixelRect(0, 0, 800, 600))
    }

    @Test func theToolbarGoesUnderThenAboveThenInside() {
        let bar = (w: 600, h: 80)
        #expect(PixelGeometry.toolbarOrigin(for: selection, bar: bar, within: display, gap: 16) == Pt(600, 816))
        let low = PixelRect(400, 800, 800, 760)
        #expect(PixelGeometry.toolbarOrigin(for: low, bar: bar, within: display, gap: 16) == Pt(600, 704))
        #expect(PixelGeometry.toolbarOrigin(for: display, bar: bar, within: display, gap: 16) == Pt(1400, 1504))
        // Exactly enough room under is room.
        let snug = PixelRect(400, 200, 800, 1304)
        #expect(PixelGeometry.toolbarOrigin(for: snug, bar: bar, within: display, gap: 16).y == 1520)
        // A narrow selection at the left edge keeps the bar on the display.
        let narrow = PixelRect(0, 200, 50, 100)
        #expect(PixelGeometry.toolbarOrigin(for: narrow, bar: bar, within: display, gap: 16).x == 0)
    }

    @Test func anArrowsHeadIsATipAndTwoBarbsAndNoLengthIsNoHead() {
        #expect(PixelGeometry.arrowHead(from: Pt(0, 0), to: Pt(100, 0), size: 20) == [Pt(100, 0), Pt(80, 10), Pt(80, -10)])
        #expect(PixelGeometry.arrowHead(from: Pt(0, 0), to: Pt(0, 100), size: 20) == [Pt(0, 100), Pt(-10, 80), Pt(10, 80)])
        #expect(PixelGeometry.arrowHead(from: Pt(5, 5), to: Pt(5, 5), size: 20) == nil)
    }

    @Test func theEightHandlesSitOnTheCornersAndTheMiddles() {
        let r = PixelRect(100, 100, 201, 101)
        #expect(PixelHandle.nw.at(r) == Pt(100, 100))
        #expect(PixelHandle.se.at(r) == Pt(301, 201))
        // The middle of an odd side is rounded down, as it is on the other host.
        #expect(PixelHandle.n.at(r) == Pt(200, 100))
        #expect(PixelHandle.e.at(r) == Pt(301, 150))
        #expect(PixelHandle.all.count == 8)
    }
}
