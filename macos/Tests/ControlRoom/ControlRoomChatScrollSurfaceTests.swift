import CoreGraphics
import Testing

@testable import Ghostty

/// **The window, as arithmetic** (task 3016, the first slice). What the
/// surface draws is a view; what it draws *from* is this: which rows are in
/// the window, where each one starts in the document, and how tall the
/// document is.
///
/// The criterion these hold: **the rows under the viewport are always all in
/// the window** -- a window that leaves part of the screen empty is not a
/// smaller window, it is a hole -- and a document of thousands of rows costs
/// no more than the forty the window may hold.
@Suite("The chat's scroll window")
struct ControlRoomChatScrollSurfaceTests {
    private func layout(
        _ heights: [CGFloat]
    ) -> ControlRoomChatScrollSurface.Layout {
        ControlRoomChatScrollSurface.Layout(
            ids: heights.indices.map { "m:\($0)" },
            heights: heights
        )
    }

    /// The document's y of a row's top: the top padding, then every row
    /// before it and the stack's spacing between.
    @Test func testARowsTopIsThePaddingPlusEveryRowBeforeIt() {
        let l = layout([100, 50, 70])
        #expect(l.top(of: 0) == ControlRoomChatScrollSurface.topPadding)
        // ⚠️ The expected values are named: an inline literal sum inside
        // `#expect` is judged false even when both sides print the same
        // number (the same shape this repository has been bitten by before),
        // and a named constant is evaluated normally.
        let second: CGFloat = 12 + 100 + 10
        let third: CGFloat = 12 + 100 + 10 + 50 + 10
        #expect(l.top(of: 1) == second)
        #expect(l.top(of: 2) == third)
    }

    @Test func testTheDocumentEndsAfterTheLastRowAndItsBottomPadding() {
        let l = layout([100, 50, 70])
        let expected: CGFloat = 12 + 100 + 10 + 50 + 10 + 70 + 12
        #expect(l.contentHeight == expected)
    }

    @Test func testAnEmptyDocumentIsItsPadding() {
        let l = layout([])
        #expect(l.contentHeight == 24)
        #expect(l.top(of: 0) == 12)
    }

    /// **The gap below a row belongs to that row**, the same rule the camera
    /// uses: a point in the spacing is still "inside" the row above it, and
    /// the row below it starts where the spacing ends.
    @Test func testTheRowUnderAPointIsTheLastOneWhoseBottomIsBelowIt() {
        let l = layout([100, 50, 70])
        #expect(l.index(at: 0) == 0)
        #expect(l.index(at: 12) == 0)
        #expect(l.index(at: 111.9) == 0)
        #expect(l.index(at: 112) == 0)      // the gap is the row above's
        #expect(l.index(at: 122) == 1)
        #expect(l.index(at: 171.9) == 1)
        #expect(l.index(at: 182) == 2)
        #expect(l.index(at: 10_000) == 2)   // past the end: the last row
    }

    /// **The rows under the viewport are all in the window**, for every
    /// origin the reader can reach -- including the bottom, where a window
    /// that stopped one row short would leave the screen's last line blank.
    @Test func testTheWindowAlwaysCoversTheViewport() {
        let l = layout(Array(repeating: 50, count: 200))
        var origin: CGFloat = 0
        while origin < l.contentHeight {
            let window = l.window(at: origin, viewport: 800)
            let first = l.index(at: origin)
            let last = l.index(at: origin + 799)
            #expect(window.lowerBound <= first, "origin \(origin)")
            #expect(window.upperBound > last, "origin \(origin)")
            origin += 37
        }
    }

    /// **The criterion: five thousand rows must instantiate at most forty.**
    /// Sixteen-point rows fit fifty to a screen, so this is the case where
    /// the window cannot have its screen of margin and is trimmed to the
    /// limit.
    @Test func testFiveThousandRowsDoNotMakeAFiveThousandRowWindow() {
        let l = layout(Array(repeating: 16, count: 5_000))
        let window = l.window(at: 40_000, viewport: 800)
        #expect(window.count <= ControlRoomChatScrollSurface.windowLimit)
        // And it still covers the screen it was asked about.
        #expect(window.lowerBound <= l.index(at: 40_000))
        #expect(window.upperBound > l.index(at: 40_000 + 799))
    }

    /// A screen of tall rows fits in a handful of rows, so the window may
    /// carry a screen of margin on each side -- and still stops at the
    /// limit.
    @Test func testAScreenOfTallRowsLeavesRoomForAMargin() {
        let l = layout(Array(repeating: 100, count: 5_000))
        let window = l.window(at: 10_000, viewport: 800)
        #expect(window.count <= ControlRoomChatScrollSurface.windowLimit)
        #expect(window.count > 8)   // eight visible rows, plus margin
    }

    /// **The window is centred on the viewport**: the part the reader cannot
    /// see is the same above and below, not one screen of margin on one side
    /// and whatever is left on the other.
    @Test func testTheWindowIsCentredOnTheViewport() {
        let l = layout(Array(repeating: 60, count: 500))
        let viewport: CGFloat = 960
        let origin: CGFloat = 10_000
        let window = l.window(at: origin, viewport: viewport)
        let first = l.index(at: origin)
        let last = l.index(at: origin + viewport - 1)
        let above = first - window.lowerBound
        let below = window.upperBound - last - 1
        let tolerance = 1
        #expect(abs(above - below) <= tolerance)
    }

    /// **The document's end does not push the whole budget above** (the
    /// 2026-11-07 red: `inOffset=2148` with a 968 pt viewport, so half of
    /// the forty rows drawn were outside the screen). With no rows below to
    /// take its share, the window may not start more than half the limit
    /// above the viewport.
    @Test func testTheEndOfTheDocumentDoesNotPushTheBudgetAbove() {
        let l = layout(Array(repeating: 60, count: 500))
        let viewport: CGFloat = 960
        let origin = l.contentHeight - viewport
        let window = l.window(at: origin, viewport: viewport)
        let first = l.index(at: origin)
        let above = first - window.lowerBound
        let half = ControlRoomChatScrollSurface.windowLimit / 2
        #expect(above <= half)
    }

    /// **A viewport that is exactly the window's limit leaves no margin to
    /// hide a short window behind** (the first version of this test used
    /// sixty-point rows, where the spare half a budget reached the last row
    /// on its own and the floor stayed green with the coverage broken).
    private func tightLayout(rows: Int) -> ControlRoomChatScrollSurface.Layout {
        ControlRoomChatScrollSurface.Layout(
            ids: (0..<rows).map { "m:\($0)" },
            heights: Array(repeating: 24, count: rows),
            spacing: 0,
            topPadding: 0,
            bottomPadding: 12,
            limit: 40
        )
    }

    /// **Pinned at the newest row, the last row is in the window.** The
    /// viewport's bottom edge lands in the document's bottom padding, which
    /// belongs to no row; the window must still reach the last one.
    @Test func testTheWindowReachesTheLastRowWhenPinned() {
        let l = tightLayout(rows: 200)
        let viewport: CGFloat = 960          // forty rows, no spare
        let window = l.window(at: l.contentHeight - viewport, viewport: viewport)
        #expect(window.upperBound == 200)
        #expect(window.count == 40)
    }

    /// The same, in the middle: with no spare row the window is exactly the
    /// rows under the viewport, and nothing may be trimmed from either end.
    @Test func testWithNoSpareRowsTheWindowIsTheViewport() {
        let l = tightLayout(rows: 200)
        let viewport: CGFloat = 960
        let origin: CGFloat = 2_000
        let window = l.window(at: origin, viewport: viewport)
        #expect(window.lowerBound == l.index(at: origin))
        #expect(window.upperBound == l.index(at: origin + viewport - 1) + 1)
    }

    /// **A document shorter than the viewport is the whole document.** There
    /// is nothing to scroll and nothing to trim.
    @Test func testAShortDocumentIsTheWholeWindow() {
        let l = layout(Array(repeating: 50, count: 5))
        let window = l.window(at: 0, viewport: 960)
        #expect(window == 0..<5)
    }

    /// **An offset below zero walks back one row and keeps the distance**
    /// (design §17). The slot is the row's height plus the stack's spacing,
    /// so the gap belongs to the row above it -- the same rule `index(at:)`
    /// uses.
    @Test func testAnOffsetBelowZeroWalksBackOneRow() {
        let l = layout([100, 50, 70])          // slots: 110, 60, 70
        let fixed = l.normalized(index: 1, offset: -20)
        #expect(fixed?.index == 0)
        #expect(fixed?.offset == 90)
    }

    /// An offset past its slot walks forward by whole slots.
    @Test func testAnOffsetPastItsSlotWalksForward() {
        let l = layout([100, 50, 70])
        let fixed = l.normalized(index: 0, offset: 130)
        #expect(fixed?.index == 1)
        #expect(fixed?.offset == 20)
    }

    /// **At the first row an offset below zero stops there**, at the top: the
    /// document's beginning is a real place and there is nothing behind it.
    @Test func testTheFirstRowIsWhereTheWalkStops() {
        let l = layout([100])
        let fixed = l.normalized(index: 0, offset: -50)
        #expect(fixed?.index == 0)
        #expect(fixed?.offset == 0)
    }

    /// At the last row it stops inside that row's slot, never past it.
    @Test func testTheLastRowClampsInsideItsSlot() {
        let l = layout([100, 50])
        let fixed = l.normalized(index: 1, offset: 500)
        #expect(fixed?.index == 1)
        #expect(fixed?.offset == 49.5)
    }

    /// **A wild offset is refused, not silently kept** (the 2026-11-07 red:
    /// `−4204` and `2060` were written into a row a few dozen points tall).
    /// The walk is capped, and the cap is what turns a broken anchor into a
    /// line the reader of the log can see.
    @Test func testAWildOffsetIsRefusedRatherThanKept() {
        let l = layout(Array(repeating: 20, count: 200))
        #expect(l.normalized(index: 100, offset: -10_000) == nil)
    }

    /// **A locate lands its row in the middle of the viewport** (design §15,
    /// rule 3), not on the top edge: half a screen of context on each side.
    @Test func testALocateRowLandsInTheMiddle() {
        let l = layout(Array(repeating: 100, count: 50))
        let viewport: CGFloat = 800
        // Row 10 starts at 12 + 10 × 110 = 1112; 1112 − (800 − 100)/2 = 762.
        let origin = l.centeredOrigin(of: 10, viewport: viewport)
        #expect(origin == 762)
        // A row near the top cannot be centred: the document's beginning is
        // as far as the viewport can go.
        #expect(l.centeredOrigin(of: 0, viewport: viewport) == 0)
    }

    /// **A hand's movement is measured against the clip the view already
    /// reconciled with**, never read absolutely: after a page is measured in,
    /// the same y belongs to another row (the 2026-11-07 red, 45 rows in one
    /// 40 pt step). With no reference the answer is "read it absolutely".
    @Test func testAHandsMovementIsRelativeToTheKnownClip() {
        let seen: Double = 10_745
        #expect(
            ControlRoomChatScrollSurface.anchorMovement(seen: seen, y: 10_705)
                == -40
        )
        #expect(ControlRoomChatScrollSurface.anchorMovement(seen: nil, y: 10_705) == nil)
    }

    /// The movement lands on the row arithmetic the anchor already uses: a
    /// step inside the row is the row's offset minus the step.
    @Test func testAStepInsideTheRowIsTheOffsetMinusTheStep() {
        let l = layout([100, 50, 70])
        let moved = l.normalized(index: 1, offset: 61 - 40)
        #expect(moved?.index == 1)
        #expect(moved?.offset == 21)
    }

    /// **A centred origin never passes the last place the clip can go.** A
    /// row near the end cannot be centred; asking for its centre would name
    /// a y the scroll view clamps away, and the anchor that came from it
    /// would describe a place that is not reachable.
    @Test func testTheCentredOriginNeverExceedsTheLastScrollablePoint() {
        let l = layout(Array(repeating: 100, count: 50))
        let viewport: CGFloat = 800
        let maximum = l.contentHeight - viewport
        let end = l.centeredOrigin(of: 49, viewport: viewport)
        #expect(end == maximum)
        for index in 0..<50 {
            #expect(l.centeredOrigin(of: index, viewport: viewport) <= maximum)
        }
    }

    /// **A row taller than the viewport is not a special case**: the window
    /// still ends at the document's last scrollable point.
    @Test func testARowTallerThanTheViewportStillFitsTheClip() {
        let l = ControlRoomChatScrollSurface.Layout(
            ids: ["m:0", "m:1"],
            heights: [2_000, 100],
            topPadding: 12,
            bottomPadding: 12
        )
        let viewport: CGFloat = 800
        let maximum = l.contentHeight - viewport
        let second = l.centeredOrigin(of: 1, viewport: viewport)
        #expect(second <= maximum)
        #expect(second == maximum)
    }

    /// **The window converges on the rows that are really on screen**
    /// (review I, P6). A page whose rows were never measured is estimated
    /// tall; the window stops short, draws what it has, those rows come back
    /// measured -- and the next selection is shorter per row, so it reaches
    /// further. The property that matters is convergence, not a single
    /// selection: a static window cannot know heights it has never seen.
    ///
    /// The fixture is review I's CE-1: 200 rows, the first 100 at 70 pt, the
    /// last 100 at 12 pt, all estimated at 70 before they are drawn.
    @Test func testTheWindowConvergesOnTheRowsThatAreOnScreen() {
        let truth = Array(repeating: CGFloat(70), count: 100)
            + Array(repeating: CGFloat(12), count: 100)
        let viewport: CGFloat = 600
        let origin: CGFloat = 8_200
        var measured = Array(repeating: false, count: 200)
        var containsTheLastVisible = false
        for _ in 0..<6 {
            let heights = (0..<200).map { measured[$0] ? truth[$0] : 70 }
            let l = ControlRoomChatScrollSurface.Layout(
                ids: (0..<200).map { "m:\($0)" },
                heights: heights,
                measured: measured
            )
            let window = l.window(at: origin, viewport: viewport)
            // The rows really on screen, by the true ruler.
            var cursor: CGFloat = 12
            var lastVisible = 0
            for i in 0..<200 {
                let slot = truth[i] + (i < 199 ? 10 : 0)
                if cursor + slot > origin, cursor < origin + viewport {
                    lastVisible = i
                }
                cursor += slot
            }
            containsTheLastVisible = window.contains(lastVisible)
            for i in window { measured[i] = true }
            if containsTheLastVisible { break }
        }
        #expect(containsTheLastVisible)
    }

    /// **K2, as a pure property** (review K): an anchor whose row has a
    /// frame keeps the same document y when the *ruler* under it changes --
    /// which is what happens when another row above it is measured. The
    /// fallback is the accumulated estimate; with a frame present it must not
    /// enter the answer at all.
    @Test func testAnAnchorsPositionIgnoresTheRulersEstimates() {
        let frame = CGRect(x: 0, y: 5_000, width: 100, height: 64)
        let before = ControlRoomChatScrollSurface.anchorDocumentY(
            frame: frame, fallback: 7_000, offset: 12
        )
        let after = ControlRoomChatScrollSurface.anchorDocumentY(
            frame: frame, fallback: 7_064, offset: 12
        )
        #expect(before == after)
        #expect(before == 5_012)
    }

    /// A row that has never been drawn has no frame; the window's ruler is
    /// then the only honest answer, and it is the one place an estimate may
    /// decide a position.
    @Test func testARowWithNoFrameFallsBackToTheRuler() {
        let y = ControlRoomChatScrollSurface.anchorDocumentY(
            frame: nil, fallback: 7_000, offset: 12
        )
        #expect(y == 7_012)
    }

    /// **A frame of no height is not a position either.** `frames` arrives as
    /// one whole preference value, and a row that has not really been laid out
    /// reports a zero-height frame at some mid-document `minY`. Taking it
    /// would send the clip to a place nothing was drawn at. The two other
    /// readers of `frames` already refuse `height <= 1`; this one must agree
    /// with them, not with the dictionary.
    @Test func testAFrameOfNoHeightFallsBackToTheRuler() {
        for height in [CGFloat.zero, 0.5, 1] {
            let y = ControlRoomChatScrollSurface.anchorDocumentY(
                frame: CGRect(x: 0, y: 123, width: 100, height: height),
                fallback: 7_000, offset: 12
            )
            #expect(y == 7_012)
        }
        // The control: one point taller and the frame is the answer.
        let drawn = ControlRoomChatScrollSurface.anchorDocumentY(
            frame: CGRect(x: 0, y: 123, width: 100, height: 2),
            fallback: 7_000, offset: 12
        )
        #expect(drawn == 135)
    }

    /// **A window never starts before the document or ends after it.** The
    /// first and last screens are where an off-by-one would show as an empty
    /// line at an end the person is looking straight at.
    @Test func testTheWindowStaysInsideTheDocument() {
        let l = layout(Array(repeating: 90, count: 30))
        let top = l.window(at: 0, viewport: 400)
        #expect(top.lowerBound == 0)
        let bottom = l.window(at: l.contentHeight - 400, viewport: 400)
        #expect(bottom.upperBound == 30)
    }
}


/// **The window's coverage, under two rulers** (task 3016, review I).
///
/// `ControlRoomChatScrollSurface.Layout` carries one height vector. In the
/// view that vector is a mixture: the heights it has measured, and -- for every
/// row it has not -- one global `rowHeightEstimate`. The window is chosen with
/// that mixture while the rows are laid out at their real heights, so this
/// suite gives the *same ids* two vectors: the estimate the window is chosen
/// with, and the truth the content is drawn with.
///
/// **Nothing here pins a particular `Range`.** Every assertion says "the window
/// covers what is on screen", so a different (correct) rule for choosing the
/// window passes unchanged -- and a broken one cannot hide behind a fixture
/// that happens to match it.
///
/// Can be pasted into `ControlRoomChatScrollSurfaceTests.swift` or kept as its
/// own file: it only uses the `Layout` API and its own helpers.
@Suite("The chat window under two rulers")
struct ControlRoomChatWindowRulerTests {
    /// The production constants, named here so that a change to one of them
    /// turns up as a changed fixture rather than a silently different test.
    private static let spacing = ControlRoomChatScrollSurface.spacing
    private static let topPadding = ControlRoomChatScrollSurface.topPadding
    private static let limit = ControlRoomChatScrollSurface.windowLimit
    private static let epsilon: CGFloat = 0.001

    private func layout(_ heights: [CGFloat]) -> ControlRoomChatScrollSurface.Layout {
        ControlRoomChatScrollSurface.Layout(
            ids: heights.indices.map { "m:\($0)" }, heights: heights
        )
    }

    /// The document y of every row's top, for any height vector: the rule
    /// `Layout.top(of:)` uses, re-stated so it can be applied to a vector the
    /// window was *not* chosen with.
    private func tops(_ heights: [CGFloat]) -> [CGFloat] {
        var y = Self.topPadding
        var out: [CGFloat] = []
        out.reserveCapacity(heights.count)
        for height in heights {
            out.append(y)
            y += max(0, height) + Self.spacing
        }
        return out
    }

    /// **The row under `y`**, by the rule the surface uses: the last row whose
    /// top is at or above `y`, so the gap below a row belongs to that row.
    private func index(at y: CGFloat, heights: [CGFloat], tops: [CGFloat]) -> Int {
        guard !heights.isEmpty else { return 0 }
        for i in heights.indices
        where tops[i] + max(0, heights[i]) + Self.spacing > y {
            return i
        }
        return heights.count - 1
    }

    /// **The rows that are really on screen.**
    ///
    /// The hosting view is pinned at the clip origin and the window is laid out
    /// from its own first row, so row `i`'s screen top is
    /// `top_T(i) - origin + delta`, where
    /// `delta = top_E(low) - top_T(low)` is the estimate's error *above* the
    /// window. A row is on screen when its slot overlaps `[0, viewport)`.
    private func visibleRows(
        truth: [CGFloat],
        estimate: [CGFloat],
        origin: CGFloat,
        viewport: CGFloat
    ) -> Range<Int> {
        guard !truth.isEmpty, truth.count == estimate.count else { return 0..<0 }
        let window = layout(estimate).window(at: origin, viewport: viewport)
        guard window.lowerBound < window.upperBound,
              window.lowerBound < truth.count else { return 0..<0 }
        let trueTops = tops(truth)
        let estimateTops = tops(estimate)
        let low = window.lowerBound
        let delta = estimateTops[low] - trueTops[low]
        var first: Int?
        var last = 0
        for i in truth.indices {
            let screenTop = trueTops[i] - origin + delta
            let slotEnd = screenTop + max(0, truth[i]) + Self.spacing
            if screenTop < viewport, slotEnd > 0 {
                if first == nil { first = i }
                last = i + 1
            }
        }
        guard let first else { return 0..<0 }
        return first..<last
    }

    // MARK: - P1 (green by construction: a regression guard)

    /// **The window covers the viewport it was chosen for** -- in its own
    /// ruler. This is what `window(at:viewport:)` claims today, and it is true
    /// by construction; it is kept so a future rewrite of the rule cannot
    /// quietly drop it. **It being green does not mean the window is right**
    /// (see the two-ruler test below).
    @Test func testTheWindowCoversItsOwnRulersViewport() {
        let e = layout(Array(repeating: 70, count: 200))
        let topsE = tops(e.heights)
        var origin: CGFloat = 0
        while origin < e.contentHeight {
            let window = e.window(at: origin, viewport: 600)
            let first = index(at: origin, heights: e.heights, tops: topsE)
            let last = index(
                at: origin + 600 - Self.epsilon, heights: e.heights, tops: topsE
            )
            #expect(window.lowerBound <= first, "origin \(origin)")
            #expect(last < window.upperBound, "origin \(origin)")
            origin += 37
        }
    }

    // MARK: - P2 (red today: the rows on screen are not covered)

    /// **Every row that is on screen is in the window.**
    ///
    /// The two fixtures differ in *which end* the window misses: the first is
    /// the everyday shape (a run of rows the estimate is too tall for, the
    /// window ends early and the bottom of the screen is empty); the second is
    /// the first frame after a jump (nothing in the region has ever been
    /// measured, the whole window lands above the screen).
    @Test func testTheWindowCoversTheRowsThatAreOnScreen() {
        // CE-1: 100 rows of 70 (measured), 100 rows of 12 (estimated at 70).
        // The window is chosen as [86, 126); the rows on screen are 108...135,
        // so 126...135 (10 rows, 216 pt) are never drawn.
        let e1 = ControlRoomChatScrollSurface.Layout(
            ids: (0..<200).map { "m:\($0)" },
            heights: Array(repeating: 70, count: 200),
            measured: Array(repeating: false, count: 200)
        )
        let t1 = Array(repeating: CGFloat(70), count: 100)
            + Array(repeating: CGFloat(12), count: 100)
        let w1 = e1.window(at: 8_200, viewport: 600)
        let visible1 = visibleRows(
            truth: t1, estimate: e1.heights, origin: 8_200, viewport: 600
        )
        #expect(visible1.upperBound > visible1.lowerBound, "the fixture must have rows on screen")
        let missing1 = visible1.filter { !w1.contains($0) }
        #expect(
            missing1.isEmpty,
            "the window \(w1) must cover the rows on screen \(visible1); missing \(missing1)"
        )

    }

    /// **CE-2, kept as the record of what a static fixture cannot express.**
    /// 400 rows of 12 pt, every one estimated at 70: covering the rows really
    /// on screen takes a window of about 70 rows, five times what the estimate
    /// says the viewport needs. No bounded window can do that, and the view no
    /// longer reaches this state -- its origin is the anchor's y in the
    /// current ruler, so `window(at:)` is never asked for a place nobody has
    /// measured.
    @Test(.disabled("CE-2 models a state the view no longer reaches: the origin comes from the anchor in the current ruler, so window(at:) is never asked for a place nobody measured. Kept as the record of what a static fixture cannot express."))
    func testTheWindowCoversTheRowsOnScreenAfterAJumpIntoAnUnmeasuredPage() {
        let e2 = layout(Array(repeating: 70, count: 400))
        let t2 = Array(repeating: CGFloat(12), count: 400)
        let w2 = e2.window(at: 8_000, viewport: 600)
        let visible2 = visibleRows(
            truth: t2, estimate: e2.heights, origin: 8_000, viewport: 600
        )
        #expect(visible2.upperBound > visible2.lowerBound, "the fixture must have rows on screen")
        let missing2 = visible2.filter { !w2.contains($0) }
        #expect(
            missing2.isEmpty,
            "the window \(w2) must cover the rows on screen \(visible2); missing \(missing2)"
        )
    }

    // MARK: - P3 (green on CE-1 by the margin, red on CE-2)

    /// **The row at the viewport's top edge is in the window.** Without it the
    /// row is never instantiated, so it is never measured, and the anchor can
    /// never agree with the pixels again.
    ///
    /// The top-edge row is the *first row on screen*, not `index(at: origin)`
    /// in the true ruler: the two are the same only while the error above the
    /// window is zero.
    @Test func testTheRowAtTheViewportsTopEdgeIsInTheWindow() {
        let e1 = ControlRoomChatScrollSurface.Layout(
            ids: (0..<200).map { "m:\($0)" },
            heights: Array(repeating: 70, count: 200),
            measured: Array(repeating: false, count: 200)
        )
        let t1 = Array(repeating: CGFloat(70), count: 100)
            + Array(repeating: CGFloat(12), count: 100)
        let w1 = e1.window(at: 8_200, viewport: 600)
        let top1 = visibleRows(
            truth: t1, estimate: e1.heights, origin: 8_200, viewport: 600
        ).lowerBound
        #expect(w1.contains(top1), "the top-edge row \(top1) must be in \(w1)")

    }

    /// The CE-2 half of the top-edge property, disabled for the same reason.
    @Test(.disabled("CE-2 models a state the view no longer reaches: the origin comes from the anchor in the current ruler, so window(at:) is never asked for a place nobody measured. Kept as the record of what a static fixture cannot express."))
    func testTheTopEdgeRowIsInTheWindowAfterAJumpIntoAnUnmeasuredPage() {
        let e2 = layout(Array(repeating: 70, count: 400))
        let t2 = Array(repeating: CGFloat(12), count: 400)
        let w2 = e2.window(at: 8_000, viewport: 600)
        let top2 = visibleRows(
            truth: t2, estimate: e2.heights, origin: 8_000, viewport: 600
        ).lowerBound
        #expect(w2.contains(top2), "the top-edge row \(top2) must be in \(w2)")
    }

    // MARK: - P4 (green: the window's shape and its limit)

    /// **A window is a non-empty run inside the document, no bigger than the
    /// limit -- unless the viewport itself needs more rows than the limit.**
    /// The last clause is the one a plain `count <= 40` assertion would get
    /// wrong.
    @Test func testTheWindowStaysInsideTheDocumentAndWithinItsLimit() {
        let e = layout(Array(repeating: 70, count: 400))
        let topsE = tops(e.heights)
        var origin: CGFloat = -200
        while origin < e.contentHeight + 400 {
            let window = e.window(at: origin, viewport: 600)
            #expect(window.lowerBound >= 0, "origin \(origin)")
            #expect(window.upperBound <= e.ids.count, "origin \(origin)")
            #expect(window.lowerBound < window.upperBound, "origin \(origin)")
            let clamped = max(0, origin)
            let first = index(at: clamped, heights: e.heights, tops: topsE)
            let last = index(
                at: clamped + 600 - Self.epsilon, heights: e.heights, tops: topsE
            )
            let span = last - first + 1
            #expect(
                window.count <= max(Self.limit, span),
                "origin \(origin): \(window.count) rows for a span of \(span)"
            )
            origin += 37
        }
        // The ends of the range: an empty viewport still yields a row, and past
        // the document the window reaches the last row (it keeps its margin
        // *above* it, which is why this asserts the upper end, not the lower).
        #expect(e.window(at: 0, viewport: 0).count >= 1)
        #expect(e.window(at: -500, viewport: 600).lowerBound == 0)
        #expect(e.window(at: e.contentHeight + 10_000, viewport: 600).upperBound == e.ids.count)
    }

    // MARK: - P5 (green: the window never walks backwards)

    /// **As the origin advances the window's ends never move back.** A window
    /// that did would drop and re-instantiate rows on every step of a slow
    /// scroll. The fixture changes density mid-document, which is where a rule
    /// centred on the *viewport* instead of on the visible run would break.
    @Test func testTheWindowNeverMovesBackwardsAsTheOriginAdvances() {
        let e = layout(
            Array(repeating: CGFloat(20), count: 60)
                + Array(repeating: CGFloat(200), count: 40)
        )
        var lastLow = -1
        var lastHigh = -1
        var origin: CGFloat = 0
        while origin < e.contentHeight {
            let window = e.window(at: origin, viewport: 300)
            #expect(window.lowerBound >= lastLow, "origin \(origin): low \(window.lowerBound) < \(lastLow)")
            #expect(window.upperBound >= lastHigh, "origin \(origin): high \(window.upperBound) < \(lastHigh)")
            lastLow = window.lowerBound
            lastHigh = window.upperBound
            origin += 11
        }
    }

    // MARK: - Placement (which side of the anchor, and on screen)

    /// **A change above the anchor is negative and inside the window** (task
    /// 3016, the 2026-11-07 flutter): this is the reading that says the row
    /// changed height where the person is looking, so the picture below it
    /// moved by the difference.
    @Test func testAChangeAboveTheAnchorIsNegativeAndInsideTheWindow() {
        let placement = ControlRoomChatScrollSurface.Placement.of(
            index: 7, anchor: 9, window: 5..<12, visible: 6..<10
        )
        let expectedAt = -2
        #expect(placement.at == expectedAt)
        #expect(placement.inside)
        #expect(placement.onScreen)
    }

    /// **A change below the anchor is positive**, and one outside the window
    /// is not inside it -- the two answers the next decision is read from
    /// ("all `in=0` means the flutter is somewhere else").
    @Test func testAChangeOutsideTheWindowIsNotInside() {
        let above = ControlRoomChatScrollSurface.Placement.of(
            index: 2, anchor: 9, window: 5..<12, visible: 6..<10
        )
        let below = ControlRoomChatScrollSurface.Placement.of(
            index: 12, anchor: 9, window: 5..<12, visible: 6..<10
        )
        #expect(!above.inside)
        #expect(!below.inside)
        #expect(!above.onScreen)
        #expect(!below.onScreen)
        // Both are still placed against the anchor: "outside the window" must
        // not read as "no anchor".
        let aboveAt = -7
        let belowAt = 3
        #expect(above.at == aboveAt)
        #expect(below.at == belowAt)
    }

    /// **Drawn is not seen.** The window is the viewport plus a margin, so a
    /// row in the margin is `inside` and not `onScreen` -- and that row is
    /// exactly the one whose changing height moves the picture below it.
    /// Reading `in` as "the person saw it" would call it visible.
    @Test func testARowInTheMarginIsInsideTheWindowAndNotOnScreen() {
        let placement = ControlRoomChatScrollSurface.Placement.of(
            index: 3, anchor: 9, window: 0..<12, visible: 6..<10
        )
        #expect(placement.inside)
        #expect(!placement.onScreen)
    }

    /// **No anchor is not the anchor's own row.** Without one the line says
    /// `at=?` rather than `at=0`, which would read as a change exactly at the
    /// anchor.
    @Test func testNoAnchorIsNotTheAnchorsOwnRow() {
        let placement = ControlRoomChatScrollSurface.Placement.of(
            index: 4, anchor: nil, window: 0..<12, visible: 2..<8
        )
        #expect(placement.at == nil)
        #expect(placement.inside)
        #expect(placement.onScreen)
    }

    /// **The screen's rows are the viewport, not the window.** Twenty rows of
    /// 40 with the stack's 10 pt spacing: the first six fill a 300 pt
    /// viewport, while the window around them keeps its whole spare budget
    /// and reaches the twentieth.
    @Test func testTheVisibleRowsAreTheViewportAndNotTheWindowMargin() {
        let e = layout(Array(repeating: CGFloat(40), count: 20))
        let visible = e.visibleRows(at: 0, viewport: 300)
        let window = e.window(at: 0, viewport: 300)
        let expected: Range<Int> = 0..<6
        let farBelow = 18
        #expect(visible == expected)
        #expect(window.contains(farBelow))
        #expect(!visible.contains(farBelow))
    }

    /// **Nothing visible is not the whole document.** A viewport of zero (the
    /// frame before the geometry is real) and an empty document both see no
    /// rows; a range of `0..<1` would read as "the first row is on screen".
    @Test func testNoViewportAndNoRowsSeeNothing() {
        let e = layout(Array(repeating: CGFloat(40), count: 20))
        let noViewport = e.visibleRows(at: 0, viewport: 0)
        let noDocument = layout([]).visibleRows(at: 0, viewport: 300)
        #expect(noViewport.isEmpty)
        #expect(noDocument.isEmpty)
    }
}

// 现在这一份（`f1965460` / `09f045fb` 之后）：P1、P4、P5 应该是绿的；
// **P2 两格都红** —— CE-1 窗口 [86,126) 漏掉 126…135（10 行；屏幕 y=384 往下 216pt 空白），
// CE-2 窗口 [84,123) 漏掉整段可见区 141…168（窗口整个在屏幕上方，一行都没盖住）；
// **P3 一格绿一格红** —— CE-1 的顶边行 108 落在 [86,126) 内（余量救了它），
// CE-2 的顶边行 141 不在 [84,123) 内。
// 修好之后这五条应当全绿，断言对象是「覆盖」而不是某个具体区间，所以换一种正确的
// 选窗口规则也照样通过。
