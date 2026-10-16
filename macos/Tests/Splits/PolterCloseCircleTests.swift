import CoreGraphics
import SwiftUI
import Testing
@testable import Ghostty

/// The close button of a pane's title and a stack's tab, as the window's own
/// tabs draw theirs on macOS (task 1642).
struct PolterCloseCircleTests {
    private typealias Circle = PolterCloseCircle

    @Test func theSizesAreTheSystemTabsButton() {
        // Read off macOS 26's tab bar: an 18pt square, a disc 16 across.
        #expect(Circle.side == 18)
        #expect(Circle.disc == 16)
        #expect(Circle.stroke == 1.1)
        // Inked across: the box plus the round ends.
        #expect(abs(Circle.cross + Circle.stroke - 7.5) < 0.001)
    }

    @Test func theDiscsLeftEdgeIsOnTheTextsAndTheSquareIsCentredUpAndDown() {
        // A stack tab: 28 high, its name 12 in.
        let frame = Circle.frame(textLeading: 12, height: 28)
        #expect(frame == CGRect(x: 11, y: 5, width: 18, height: 18))
        let disc = Circle.disc(in: frame)
        #expect(disc == CGRect(x: 12, y: 6, width: 16, height: 16))
        #expect(disc.minX == 12)
        #expect(disc.midY == 14)
        // A plain title: 32 high, its name 10 in.
        #expect(Circle.disc(in: Circle.frame(textLeading: 10, height: 32)) == CGRect(x: 10, y: 8, width: 16, height: 16))
    }

    /// What the text is drawn through: everything but a column from the
    /// band's start to 2.5 past the disc's right edge (28), the whole height.
    @Test func theHoleIsAColumnToJustPastTheDisc() {
        let band = CGRect(x: 0, y: 0, width: 200, height: 28)
        let hole = Circle.Hole(textLeading: 12).path(in: band)
        // Asked of the CGPath by the even-odd rule, which is how the mask
        // fills it (`FillStyle(eoFill: true)`): SwiftUI's own
        // `Path.contains(_:eoFill:)` answers "inside" at the disc's centre
        // either way (measured, macOS 26).
        func drawn(_ x: CGFloat, _ y: CGFloat) -> Bool { hole.cgPath.contains(CGPoint(x: x, y: y), using: .evenOdd) }
        // The disc's centre, and past its edge up to 30.5: cut.
        #expect(!drawn(20, 14))
        #expect(!drawn(29.5, 14))
        // Where the foot of a `t` beside the disc was left as a speck by a
        // round cut: at the baseline, past the curve.
        #expect(!drawn(29.5, 21.5))
        // The corners a round cut would have left, top and bottom.
        #expect(!drawn(12, 1))
        #expect(!drawn(29, 27))
        // Past the column: drawn.
        #expect(drawn(31, 14))
        #expect(drawn(31, 1))
        #expect(drawn(100, 14))
    }

    @Test func theHoleFollowsABandThatDoesNotStartAtZero() {
        let hole = Circle.Hole(textLeading: 12).path(in: CGRect(x: 40, y: 10, width: 200, height: 28)).cgPath
        #expect(!hole.contains(CGPoint(x: 60, y: 24), using: .evenOdd))
        #expect(!hole.contains(CGPoint(x: 20, y: 24), using: .evenOdd), "outside the band altogether")
        #expect(hole.contains(CGPoint(x: 140, y: 24), using: .evenOdd))
    }

    @Test func pressedIsDeeperThanShownInBothThemes() {
        #expect(Circle.discPressed.light > Circle.discShown.light)
        #expect(Circle.discPressed.dark > Circle.discShown.dark)
    }
}
