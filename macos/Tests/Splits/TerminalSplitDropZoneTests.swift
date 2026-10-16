import Testing
import Foundation
@testable import Ghostty

struct TerminalSplitDropZoneTests {
    private let standardSize = CGSize(width: 100, height: 100)

    // MARK: - Basic Edge Detection

    @Test func topEdge() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 5), in: standardSize)
        #expect(zone == .top)
    }

    @Test func bottomEdge() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 95), in: standardSize)
        #expect(zone == .bottom)
    }

    @Test func leftEdge() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 5, y: 50), in: standardSize)
        #expect(zone == .left)
    }

    @Test func rightEdge() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 95, y: 50), in: standardSize)
        #expect(zone == .right)
    }

    // MARK: - Corner Tie-Breaking
    // When distances are equal, the check order determines the result:
    // left -> right -> top -> bottom

    @Test func topLeftCornerSelectsLeft() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 0, y: 0), in: standardSize)
        #expect(zone == .left)
    }

    @Test func topRightCornerSelectsRight() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 100, y: 0), in: standardSize)
        #expect(zone == .right)
    }

    @Test func bottomLeftCornerSelectsLeft() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 0, y: 100), in: standardSize)
        #expect(zone == .left)
    }

    @Test func bottomRightCornerSelectsRight() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 100, y: 100), in: standardSize)
        #expect(zone == .right)
    }

    // MARK: - Center Point (All Distances Equal)

    @Test func centerSelectsLeft() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 50), in: standardSize)
        #expect(zone == .left)
    }

    // MARK: - Non-Square Aspect Ratio

    @Test func rectangularViewTopEdge() {
        let size = CGSize(width: 200, height: 100)
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 100, y: 10), in: size)
        #expect(zone == .top)
    }

    @Test func rectangularViewLeftEdge() {
        let size = CGSize(width: 200, height: 100)
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 10, y: 50), in: size)
        #expect(zone == .left)
    }

    @Test func tallRectangleTopEdge() {
        let size = CGSize(width: 100, height: 200)
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 10), in: size)
        #expect(zone == .top)
    }

    // MARK: - Out-of-Bounds Points

    @Test func pointLeftOfViewSelectsLeft() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: -10, y: 50), in: standardSize)
        #expect(zone == .left)
    }

    @Test func pointAboveViewSelectsTop() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: -10), in: standardSize)
        #expect(zone == .top)
    }

    @Test func pointRightOfViewSelectsRight() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 110, y: 50), in: standardSize)
        #expect(zone == .right)
    }

    @Test func pointBelowViewSelectsBottom() {
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 110), in: standardSize)
        #expect(zone == .bottom)
    }

    // MARK: - Diagonal Regions (Triangular Zones)

    @Test func upperLeftTriangleSelectsLeft() {
        // Point in the upper-left triangle, closer to left than top
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 20, y: 30), in: standardSize)
        #expect(zone == .left)
    }

    @Test func upperRightTriangleSelectsRight() {
        // Point in the upper-right triangle, closer to right than top
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 80, y: 30), in: standardSize)
        #expect(zone == .right)
    }

    @Test func lowerLeftTriangleSelectsLeft() {
        // Point in the lower-left triangle, closer to left than bottom
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 20, y: 70), in: standardSize)
        #expect(zone == .left)
    }

    @Test func lowerRightTriangleSelectsRight() {
        // Point in the lower-right triangle, closer to right than bottom
        let zone = TerminalSplitDropZone.calculate(at: CGPoint(x: 80, y: 70), in: standardSize)
        #expect(zone == .right)
    }

    // MARK: - The middle: onto the pane's stack (task 1633)

    @Test func theMiddleFortyPercentStacks() {
        for p in [CGPoint(x: 50, y: 50), CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 70), CGPoint(x: 30, y: 70)] {
            #expect(TerminalSplitDropZone.calculate(at: p, in: standardSize, middle: true) == .middle)
        }
    }

    @Test func justOutsideTheMiddleIsAnEdgeAsBefore() {
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 29, y: 50), in: standardSize, middle: true) == .left)
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 71, y: 50), in: standardSize, middle: true) == .right)
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 29), in: standardSize, middle: true) == .top)
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 71), in: standardSize, middle: true) == .bottom)
    }

    @Test func theMiddleIsShareOfEachSideNotOfTheShortOne() {
        // A wide pane: 40% across is 160 of 400, 40% down 40 of 100.
        let wide = CGSize(width: 400, height: 100)
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 125, y: 50), in: wide, middle: true) == .middle)
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 115, y: 50), in: wide, middle: true) == .left)
    }

    @Test func withoutAMiddleItIsTheFourSides() {
        // A tab dragged over a pane (#1558) is offered the four sides only.
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 50), in: standardSize, middle: false) == .left)
        #expect(TerminalSplitDropZone.calculate(at: CGPoint(x: 50, y: 50), in: standardSize) == .left)
    }

    @Test func aPanesMiddleIsInertToItsOwnStackAndAbsentWithoutStacks() {
        #expect(TerminalSplitDropZone.middle(draggedFromInside: false, holdsStacks: true) == .stacks)
        // The pane itself, or one of its stack picked up by its tab: the
        // middle is there (so it does not fall to a side and split it out)
        // and does nothing.
        #expect(TerminalSplitDropZone.middle(draggedFromInside: true, holdsStacks: true) == .inert)
        // The quick terminal keeps no stacks: the four sides.
        #expect(TerminalSplitDropZone.middle(draggedFromInside: false, holdsStacks: false) == .absent)
        #expect(TerminalSplitDropZone.middle(draggedFromInside: true, holdsStacks: false) == .absent)
    }
}
