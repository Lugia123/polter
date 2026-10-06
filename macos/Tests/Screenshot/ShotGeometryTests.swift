import CoreGraphics
import Testing
@testable import Ghostty

/// The selection rules of `dev-docs/poltergeist/screenshot.md`, 3.2.
struct ShotGeometryTests {
    /// A 1000×800 display.
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: Click or drag

    @Test func fourPointsIsStillAClickAndFiveIsADrag() {
        let start = CGPoint(x: 100, y: 100)
        #expect(!ShotGeometry.isDrag(from: start, to: start))
        #expect(!ShotGeometry.isDrag(from: start, to: CGPoint(x: 104, y: 100)))
        #expect(!ShotGeometry.isDrag(from: start, to: CGPoint(x: 100, y: 96)))
        #expect(ShotGeometry.isDrag(from: start, to: CGPoint(x: 105, y: 100)))
        #expect(ShotGeometry.isDrag(from: start, to: CGPoint(x: 100, y: 95)))
        // Either axis is enough, and they are not added together.
        #expect(!ShotGeometry.isDrag(from: start, to: CGPoint(x: 104, y: 104)))
    }

    // MARK: Regions

    @Test func aDragInAnyDirectionIsTheSameRectangle() {
        let expected = CGRect(x: 100, y: 200, width: 300, height: 150)
        let corners = [
            (CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 350)),
            (CGPoint(x: 400, y: 350), CGPoint(x: 100, y: 200)),
            (CGPoint(x: 400, y: 200), CGPoint(x: 100, y: 350)),
            (CGPoint(x: 100, y: 350), CGPoint(x: 400, y: 200)),
        ]
        for (a, b) in corners {
            #expect(ShotGeometry.rect(from: a, to: b, within: screen) == expected)
        }
    }

    @Test func aDragOffTheDisplayStopsAtItsEdge() {
        // Started on this display, ended on the one to its right.
        let right = ShotGeometry.rect(
            from: CGPoint(x: 900, y: 100), to: CGPoint(x: 1400, y: 300), within: screen)
        #expect(right == CGRect(x: 900, y: 100, width: 100, height: 200))

        // And off the top left corner.
        let corner = ShotGeometry.rect(
            from: CGPoint(x: 50, y: 60), to: CGPoint(x: -30, y: -40), within: screen)
        #expect(corner == CGRect(x: 0, y: 0, width: 50, height: 60))
    }

    // MARK: Windows

    private let windows: [ShotGeometry.Window] = [
        // Front to back: a small one on top of a large one.
        .init(frame: CGRect(x: 300, y: 300, width: 200, height: 100), app: "Front", title: "small"),
        .init(frame: CGRect(x: 100, y: 100, width: 600, height: 500), app: "Back", title: "large"),
        // Half off the right edge.
        .init(frame: CGRect(x: 900, y: 600, width: 300, height: 100), app: "Edge", title: nil),
    ]

    @Test func thePointPicksTheTopmostWindowUnderIt() {
        let onBoth = ShotGeometry.window(at: CGPoint(x: 350, y: 350), in: windows, within: screen)
        #expect(onBoth?.window.app == "Front")
        #expect(onBoth?.visible == CGRect(x: 300, y: 300, width: 200, height: 100))

        let onlyBack = ShotGeometry.window(at: CGPoint(x: 150, y: 150), in: windows, within: screen)
        #expect(onlyBack?.window.app == "Back")
        #expect(onlyBack?.visible == CGRect(x: 100, y: 100, width: 600, height: 500))
    }

    @Test func aPointOnTheDesktopPicksNothing() {
        #expect(ShotGeometry.window(at: CGPoint(x: 50, y: 50), in: windows, within: screen) == nil)
        #expect(ShotGeometry.window(at: CGPoint(x: 350, y: 350), in: [], within: screen) == nil)
    }

    @Test func aWindowHalfOffTheDisplayIsSelectedAsFarAsTheDisplayGoes() {
        let edge = ShotGeometry.window(at: CGPoint(x: 950, y: 650), in: windows, within: screen)
        #expect(edge?.window.app == "Edge")
        #expect(edge?.visible == CGRect(x: 900, y: 600, width: 100, height: 100))
    }

    // MARK: Handles

    private let selection = CGRect(x: 200, y: 100, width: 400, height: 300)

    @Test func thereAreEightHandlesOnTheCornersAndTheMiddles() {
        let expected: [(ShotGeometry.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: 200, y: 100)), (.top, CGPoint(x: 400, y: 100)),
            (.topRight, CGPoint(x: 600, y: 100)), (.right, CGPoint(x: 600, y: 250)),
            (.bottomRight, CGPoint(x: 600, y: 400)), (.bottom, CGPoint(x: 400, y: 400)),
            (.bottomLeft, CGPoint(x: 200, y: 400)), (.left, CGPoint(x: 200, y: 250)),
        ]
        #expect(ShotGeometry.Handle.allCases.count == 8)
        for (handle, point) in expected {
            #expect(ShotGeometry.point(of: handle, on: selection) == point)
            // And a press there takes hold of that one.
            #expect(ShotGeometry.handle(at: point, on: selection) == handle)
        }
    }

    @Test func aPressNearAHandleTakesItAndOneFurtherOffDoesNot() {
        let slop = ShotGeometry.handleSlop
        #expect(ShotGeometry.handle(at: CGPoint(x: 600 + slop, y: 400 - slop), on: selection) == .bottomRight)
        #expect(ShotGeometry.handle(at: CGPoint(x: 600 + slop + 1, y: 400), on: selection) == nil)
        // The middle of the selection is not a handle.
        #expect(ShotGeometry.handle(at: CGPoint(x: 400, y: 250), on: selection) == nil)
    }

    @Test func onASmallSelectionTheNearerHandleWins() {
        // Six points wide: the left and right handles are both in reach of
        // either press, and `right` comes first in the list.
        let small = CGRect(x: 100, y: 100, width: 6, height: 100)
        #expect(ShotGeometry.handle(at: CGPoint(x: 101, y: 150), on: small) == .left)
        #expect(ShotGeometry.handle(at: CGPoint(x: 105, y: 150), on: small) == .right)
    }

    @Test func aCornerMovesTwoEdgesAndASideMovesOne() {
        let corner = ShotGeometry.resize(
            selection, dragging: .bottomRight, to: CGPoint(x: 700, y: 450), within: screen)
        #expect(corner == CGRect(x: 200, y: 100, width: 500, height: 350))

        let topLeft = ShotGeometry.resize(
            selection, dragging: .topLeft, to: CGPoint(x: 150, y: 50), within: screen)
        #expect(topLeft == CGRect(x: 150, y: 50, width: 450, height: 350))

        // A side handle ignores the other axis of the pointer.
        let side = ShotGeometry.resize(
            selection, dragging: .right, to: CGPoint(x: 650, y: 700), within: screen)
        #expect(side == CGRect(x: 200, y: 100, width: 450, height: 300))

        let top = ShotGeometry.resize(
            selection, dragging: .top, to: CGPoint(x: 0, y: 150), within: screen)
        #expect(top == CGRect(x: 200, y: 150, width: 400, height: 250))
    }

    @Test func draggingPastTheOppositeEdgeTurnsTheSelectionOver() {
        let flipped = ShotGeometry.resize(
            selection, dragging: .left, to: CGPoint(x: 700, y: 0), within: screen)
        #expect(flipped == CGRect(x: 600, y: 100, width: 100, height: 300))
    }

    @Test func resizingStopsAtTheDisplay() {
        let clamped = ShotGeometry.resize(
            selection, dragging: .bottomRight, to: CGPoint(x: 5000, y: 5000), within: screen)
        #expect(clamped == CGRect(x: 200, y: 100, width: 800, height: 700))
    }

    @Test func movingKeepsTheSizeAndStopsAtTheDisplay() {
        let moved = ShotGeometry.move(selection, by: CGSize(width: 50, height: -30), within: screen)
        #expect(moved == CGRect(x: 250, y: 70, width: 400, height: 300))

        let farRight = ShotGeometry.move(selection, by: CGSize(width: 5000, height: 5000), within: screen)
        #expect(farRight == CGRect(x: 600, y: 500, width: 400, height: 300))

        let farLeft = ShotGeometry.move(selection, by: CGSize(width: -5000, height: -5000), within: screen)
        #expect(farLeft == CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    // MARK: Toolbar

    private let toolbar = CGSize(width: 300, height: 40)

    @Test func theToolbarGoesUnderTheSelectionRightAligned() {
        let placed = ShotGeometry.toolbar(size: toolbar, for: selection, within: screen)
        #expect(placed.placement == .below)
        #expect(placed.origin == CGPoint(x: 300, y: 408))
    }

    @Test func withNoRoomUnderItGoesAbove() {
        let low = CGRect(x: 200, y: 400, width: 400, height: 380)
        let placed = ShotGeometry.toolbar(size: toolbar, for: low, within: screen)
        #expect(placed.placement == .above)
        #expect(placed.origin == CGPoint(x: 300, y: 352))
    }

    @Test func withNoRoomEitherWayItGoesInside() {
        let placed = ShotGeometry.toolbar(size: toolbar, for: screen, within: screen)
        #expect(placed.placement == .inside)
        #expect(placed.origin == CGPoint(x: 700, y: 752))
    }

    @Test func theToolbarStaysOnTheDisplay() {
        // A narrow selection at the left edge: right-aligning would put the
        // toolbar off the display.
        let narrow = CGRect(x: 0, y: 100, width: 50, height: 100)
        let placed = ShotGeometry.toolbar(size: toolbar, for: narrow, within: screen)
        #expect(placed.origin.x == 0)
    }

    @Test func exactlyEnoughRoomUnderIsRoom() {
        // maxY + gap + height == 800.
        let snug = CGRect(x: 200, y: 100, width: 400, height: 652)
        #expect(ShotGeometry.toolbar(size: toolbar, for: snug, within: screen).placement == .below)
        let onePointMore = CGRect(x: 200, y: 100, width: 400, height: 653)
        #expect(ShotGeometry.toolbar(size: toolbar, for: onePointMore, within: screen).placement == .above)
    }

    // MARK: Pixels

    @Test func theSavedImageIsInPhysicalPixels() {
        let image2x = CGSize(width: 2000, height: 1600)
        #expect(ShotGeometry.pixelRect(selection, scale: 2, imageSize: image2x)
            == CGRect(x: 400, y: 200, width: 800, height: 600))

        let image1x = CGSize(width: 1000, height: 800)
        #expect(ShotGeometry.pixelRect(selection, scale: 1, imageSize: image1x) == selection)
    }

    @Test func edgesAreRoundedNotTheSize() {
        // 1.5×: left 100.4→151 (150.6), right 300.4→451 (450.6). The width is
        // 300, the distance between the rounded edges -- not round(200×1.5).
        let rect = CGRect(x: 100.4, y: 10, width: 200, height: 20)
        let pixels = ShotGeometry.pixelRect(rect, scale: 1.5, imageSize: CGSize(width: 1500, height: 1200))
        #expect(pixels == CGRect(x: 151, y: 15, width: 300, height: 30))

        // Two selections sharing an edge share it in pixels too.
        let a = ShotGeometry.pixelRect(
            CGRect(x: 0, y: 0, width: 33.3, height: 10), scale: 1.5, imageSize: CGSize(width: 1500, height: 1200))
        let b = ShotGeometry.pixelRect(
            CGRect(x: 33.3, y: 0, width: 40, height: 10), scale: 1.5, imageSize: CGSize(width: 1500, height: 1200))
        #expect(a.maxX == b.minX)
    }

    @Test func pixelsNeverLeaveTheImage() {
        let whole = ShotGeometry.pixelRect(
            CGRect(x: -10, y: -10, width: 2000, height: 2000), scale: 2, imageSize: CGSize(width: 2000, height: 1600))
        #expect(whole == CGRect(x: 0, y: 0, width: 2000, height: 1600))
    }
}
