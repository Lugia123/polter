import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// What the split divider's arithmetic has to hold for a drag to land where
/// the pointer is (task 2646).
///
/// **Why this file exists.** `SplitView.swift` was not in the macOS logic
/// tests' list at all -- `macos/Sources/Features/Splits` was not a watched
/// directory -- so the seam, the two rectangles and the divider's grab box
/// were code no test had ever run. A drag that "stopped working" then has no
/// reading either way: green could not mean working, because nothing asked.
/// The arithmetic is `SplitViewLayout`'s now.
///
/// **What is held.** Three invariants, each of which a person feels:
///
///  1. the divider is drawn **on the seam** the two rectangles meet at;
///  2. the two rectangles **account for the whole split**: the right one ends
///     at the far edge, and the line between them falls in the gap they leave
///     -- so no strip of the split view belongs to no pane;
///  3. the divider is grabbed in a box `visible + invisible` wide, **centred
///     on the seam** -- `Divider`'s `Color.clear` hit box.
///
/// ⚠️ **Values are compared through named `let`s, never as literals inside
/// `#expect`.** `#expect(f(x) == 10.0 / 400.0)` is **false** where
/// `let want: CGFloat = 10.0 / 400.0; #expect(f(x) == want)` is true: the
/// macro re-evaluates the literal division in a way that does not round the
/// same (`0.025` against `0.025`, both printing equal). Measured on this file
/// on 2026-11-02 -- three assertions were red for that reason alone, and the
/// failing value and the expected one printed as the same number.
struct SplitViewDragTests {
    private typealias Layout = SplitViewLayout

    private let increments = NSSize(width: 1, height: 1)

    /// Sizes a split view is at, from a small pane to a large window.
    private let sizes = [CGSize(width: 400, height: 300), CGSize(width: 801, height: 447), CGSize(width: 1200, height: 800)]

    /// Fractions the split is at: even, either side of even, and the two ends.
    /// `0.499` is here because the two rectangles are rounded to whole points
    /// and a fraction just off a half is where that rounding shows.
    private let splits: [CGFloat] = [0.1, 0.25, 0.499, 0.5, 0.75, 0.9]

    private let directions = [SplitViewDirection.horizontal, .vertical]

    /// **The divider is drawn on the seam between the two panes.**
    /// `splitterPoint` is where `SplitView` puts the `Divider`
    /// (`.position`); the left rectangle's far edge is where the left pane
    /// ends. If these drift apart the line is drawn over one pane and its
    /// grab box centred on the other.
    @Test func theDividerIsDrawnOnTheSeamBetweenTheTwoPanes() {
        for size in sizes {
            for split in splits {
                for direction in directions {
                    let left = Layout.leftRect(direction: direction, split: split, size: size, increments: increments)
                    let point = Layout.splitterPoint(direction: direction, size: size, leftRect: left)
                    switch direction {
                    case .horizontal:
                        #expect(point.x == left.maxX,
                                "size \(size) split \(split): the divider is at x=\(point.x), the left pane ends at \(left.maxX)")
                        let halfHeight: CGFloat = size.height / 2
                        #expect(point.y == halfHeight)
                    case .vertical:
                        #expect(point.y == left.maxY,
                                "size \(size) split \(split): the divider is at y=\(point.y), the top pane ends at \(left.maxY)")
                        let halfWidth: CGFloat = size.width / 2
                        #expect(point.x == halfWidth)
                    }
                }
            }
        }
    }

    /// **The two panes and the line account for the whole split.** The right
    /// rectangle ends at the split view's far edge, and the two rectangles
    /// leave between them exactly half the visible line -- the line is centred
    /// on the seam, so its far half is that gap and its near half overlaps the
    /// pane before it.
    ///
    /// ⚠️ **This is the invariant a "the divider stopped moving" bug would
    /// break**: a right rectangle that did not reach the edge, or a seam that
    /// was not where the line is drawn, is a strip of the split view that no
    /// pane answers a click in.
    @Test func theTwoPanesAndTheLineAccountForTheWholeSplit() {
        let halfLine: CGFloat = Layout.visibleSize / 2
        for size in sizes {
            for split in splits {
                for direction in directions {
                    let left = Layout.leftRect(direction: direction, split: split, size: size, increments: increments)
                    let right = Layout.rightRect(direction: direction, split: split, size: size, leftRect: left,
                                                 increments: increments)
                    let point = Layout.splitterPoint(direction: direction, size: size, leftRect: left)
                    switch direction {
                    case .horizontal:
                        #expect(right.maxX == size.width,
                                "size \(size) split \(split): the right pane ends at \(right.maxX), not at \(size.width)")
                        #expect(left.minX == 0)
                        #expect(right.minX - left.maxX == halfLine,
                                "size \(size) split \(split): the gap between the panes is \(right.minX - left.maxX), not half the line")
                        // The line's far edge is where the right pane begins.
                        #expect(right.minX == point.x + halfLine)
                    case .vertical:
                        #expect(right.maxY == size.height,
                                "size \(size) split \(split): the bottom pane ends at \(right.maxY), not at \(size.height)")
                        #expect(left.minY == 0)
                        #expect(right.minY - left.maxY == halfLine,
                                "size \(size) split \(split): the gap between the panes is \(right.minY - left.maxY), not half the line")
                        #expect(right.minY == point.y + halfLine)
                    }
                }
            }
        }
    }

    /// **The seam is where it is drawn, in points.** The three tests above are
    /// all *relations* between the pieces, and a change that moves the seam and
    /// both panes together keeps every one of them: measured -- adding half a
    /// line to the left rectangle instead of taking it away (`-=` to `+=`)
    /// moved the line a whole point and left all three green. What a person
    /// sees is the number, so the number is pinned here, for the fraction the
    /// split view opens at and for a few others.
    ///
    /// The value is `floor(size × split − line/2)` at whole-point increments:
    /// `400 × 0.5 − 0.5 = 199.5`, and the remainder against `increments` of 1
    /// takes the half back off. The right pane begins half a line further on,
    /// so the two of them and the line are the whole width.
    @Test func theSeamIsWhereItIsDrawnInPoints() {
        func seam(_ width: CGFloat, _ split: CGFloat) -> CGFloat {
            let size = CGSize(width: width, height: 300)
            return Layout.leftRect(direction: .horizontal, split: split, size: size, increments: increments).maxX
        }
        let at400Half: CGFloat = 199
        let at801Half: CGFloat = 400
        let at1200Quarter: CGFloat = 299
        let at400Tenth: CGFloat = 39
        #expect(seam(400, 0.5) == at400Half)
        #expect(seam(801, 0.5) == at801Half)
        #expect(seam(1200, 0.25) == at1200Quarter)
        #expect(seam(400, 0.1) == at400Tenth)
        // And the divider's grab box is centred on it: the middle of the box is
        // the seam, to within the half line the box is measured by.
        let box = Layout.grabBox(seam: seam(400, 0.5))
        let middle = (box.lowerBound + box.upperBound) / 2
        #expect(middle == at400Half)
    }

    /// **The divider is grabbed in a box `visible + invisible` wide, centred
    /// on the seam.** `Divider` makes exactly that box hit-testable
    /// (`Color.clear.contentShape(Rectangle())`); a pointer outside it lands
    /// on a pane and drags nothing, which is what a divider that "does not
    /// move" is made of.
    @Test func theDividerIsGrabbedInABoxCentredOnTheSeam() {
        let visible: CGFloat = 1
        let invisible: CGFloat = 6
        #expect(Layout.visibleSize == visible)
        #expect(Layout.invisibleSize == invisible)
        let box = Layout.grabBox(seam: 199)
        let want: CGFloat = 3.5
        #expect(box.lowerBound == 199 - want)
        #expect(box.upperBound == 199 + want)
        // Symmetric about the seam whatever the seam is.
        for seam in [CGFloat(0), 0.5, 199, 400.25, 1000] {
            let b = Layout.grabBox(seam: seam)
            #expect(seam - b.lowerBound == b.upperBound - seam)
            #expect(b.upperBound - b.lowerBound == visible + invisible)
        }
    }

    /// **A drag becomes the fraction the pointer's position means**, and the
    /// two ends keep `minSize` of a pane. This is `dragGesture`'s one line,
    /// which nothing could call before.
    @Test func aDragBecomesTheFractionThePointerIsAt() {
        let size = CGSize(width: 400, height: 300)
        let minSize: CGFloat = 10
        func at(_ x: CGFloat) -> CGFloat {
            Layout.dragged(direction: .horizontal, size: size, location: CGPoint(x: x, y: 150), minSize: minSize)
        }
        let seventhTenths: CGFloat = 0.7
        #expect(at(280) == seventhTenths)
        let threeTenths: CGFloat = 0.3
        #expect(Layout.dragged(direction: .vertical, size: size, location: CGPoint(x: 200, y: 90), minSize: minSize) == threeTenths)
        // The ends give up `minSize` of a pane, not more.
        let leftEnd: CGFloat = 10.0 / 400.0
        let rightEnd: CGFloat = 390.0 / 400.0
        #expect(at(0) == leftEnd)
        #expect(at(1000) == rightEnd)
        // Past the left end is the left end, however far past.
        #expect(at(-500) == leftEnd)
    }
}
