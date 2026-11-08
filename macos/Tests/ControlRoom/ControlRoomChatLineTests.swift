import CoreGraphics
import Foundation
import Testing

@testable import Ghostty

/// **The line model's arithmetic** (task 3081, design §29.7).
///
/// The fixtures are one small conversation: three rows of 30, 48 and 80
/// points at a 16-point quantum, so the rows hold 2, 3 and 5 lines and the
/// document holds 10. Every expected number below is read off that fixture by
/// hand; the tests that matter are the ones the supervisor named: the
/// **round trip** `b -> y -> b`, the **top clamp**, **loading keeps `b`**, and
/// **reflow moves the line number but not the anchor**.
struct ControlRoomChatLineTests {
    typealias Table = ControlRoomChatLineTable
    typealias Bar = ControlRoomChatLineBar

    private let quantum: CGFloat = 16
    private let gap: CGFloat = 10
    private let topPadding: CGFloat = 12
    private let bottomPadding: CGFloat = 12

    /// `a` 30 (2 lines), `b` 48 (3), `c` 80 (5): document 10 lines, tops at
    /// 12 / 52 / 110 and bottoms at 42 / 100 / 190.
    private var base: Table {
        Table(
            ids: ["a", "b", "c"],
            heights: [30, 48, 80],
            spacing: gap,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            lineHeight: quantum
        )
    }

    // MARK: - Counting

    /// **The newest slice is line 1 and loading older rows cannot renumber it.**
    @Test func testLinesAreCountedFromTheNewestEnd() {
        let table = base
        #expect(table.totalLines == 10)
        #expect(table.lineCounts == [2, 3, 5])
        #expect(table.linesNewer == [8, 5, 0])
        // The top slice of the oldest row is the last line; the bottom slice
        // of the newest row is the first.
        #expect(table.line(ofRow: 0, slot: 0) == 10)
        #expect(table.line(ofRow: 0, slot: 1) == 9)
        #expect(table.line(ofRow: 2, slot: 0) == 5)
        #expect(table.line(ofRow: 2, slot: 4) == 1)
        #expect(table.rowAndSlot(ofLine: 10)?.index == 0)
        #expect(table.rowAndSlot(ofLine: 10)?.slot == 0)
        #expect(table.rowAndSlot(ofLine: 1)?.index == 2)
        #expect(table.rowAndSlot(ofLine: 1)?.slot == 4)
    }

    /// A row's height is split evenly, so its own bottom stays exact.
    @Test func testASliceIsTheRowsOwnHeightDividedEvenly() {
        let table = base
        #expect(table.slotHeight(ofRow: 0) == 15)
        #expect(table.slotHeight(ofRow: 1) == 16)
        #expect(table.slotHeight(ofRow: 2) == 16)
        // Row `a`: 12 + 15 = 27, then 42 (its bottom).
        #expect(table.yBottom(ofLine: 10) == 27)
        #expect(table.yBottom(ofLine: 9) == 42)
        // Row `b`: 68 / 84 / 100.
        #expect(table.yBottom(ofLine: 8) == 68)
        #expect(table.yBottom(ofLine: 6) == 100)
        // Row `c`: 126 ... 190.
        #expect(table.yBottom(ofLine: 5) == 126)
        #expect(table.yBottom(ofLine: 1) == 190)
        #expect(table.contentBottom == 190 + bottomPadding)
    }

    // MARK: - The hard criterion

    /// **`b -> its top edge -> b` is the identity**, for every line, the two
    /// ends and every slice boundary included (supervisor, #3081). If any
    /// writer of `camera.place` is one point off, this is where it shows.
    @Test func testTheBottomLineRoundTripsThroughItsTopEdge() {
        let table = base
        let viewport: CGFloat = 100
        for line in 1...table.totalLines {
            let bottom = table.yBottom(ofLine: line)
            #expect(bottom != nil)
            #expect(table.line(atBottomEdge: bottom!) == line)
            let top = table.yTop(ofLine: line, viewport: viewport)
            #expect(top != nil)
            #expect(table.line(atBottomEdge: top! + viewport) == line)
            #expect(table.line(viewportTop: top!, viewport: viewport) == line)
        }
    }

    /// A point in the gap below a row belongs to that row's bottom slice, the
    /// same rule the camera's `place` and `Layout.index(at:)` use. A point
    /// exactly on the next row's top is still the gap's row.
    @Test func testAGapBelowARowBelongsToThatRow() {
        let table = base
        // Row `a` ends at 42; the next row starts at 52.
        #expect(table.line(atBottomEdge: 47) == 9)
        #expect(table.line(atBottomEdge: 52) == 9)
        #expect(table.line(atBottomEdge: 52.001) == 8)
        // Inside a slice is that slice; just above its bottom is the slice.
        #expect(table.line(atBottomEdge: 20) == 10)
        #expect(table.line(atBottomEdge: 30) == 9)
        #expect(table.line(atBottomEdge: 42) == 9)
    }

    // MARK: - The top clamp

    /// **The clamp is the line that just fills the screen.** With a
    /// 100-point viewport, the oldest 6 lines (and the gaps between them)
    /// reach 114 points; the 5th line reaches only 88, so the deepest
    /// reachable bottom line is `10 - 6 + 1 = 5`. One line further and the
    /// viewport's top edge is at 0 while the first row starts at 12: a blank
    /// strip, which is exactly what the clamp forbids.
    @Test func testTheTopClampIsTheLineThatJustFillsTheScreen() {
        let table = base
        let viewport: CGFloat = 100
        #expect(table.fillLines(viewport: viewport) == 6)
        #expect(table.maxLine(viewport: viewport) == 5)
        let top = table.yTop(ofLine: 5, viewport: viewport)
        #expect(top != nil)
        #expect(top! == 26)
        #expect(top! > 0)
        // The position the clamp refuses: its top edge is 0, above the first
        // row at 12.
        #expect(table.yTop(ofLine: 6, viewport: viewport) == 0)
        // A whole document shorter than the viewport has nowhere to go.
        let short = Table(
            ids: ["only"], heights: [40], spacing: gap,
            topPadding: topPadding, bottomPadding: bottomPadding,
            lineHeight: quantum
        )
        #expect(short.fillLines(viewport: viewport) == short.totalLines)
        #expect(short.maxLine(viewport: viewport) == 1)
    }

    // MARK: - Loading

    /// **Appending older rows above the reader leaves `b` alone** (design
    /// §29.7 rule 6): the numbering starts at the newest end, so a row's line
    /// number does not depend on how much older history was loaded.
    @Test func testPrependingOlderRowsLeavesTheBottomLineNumberAlone() {
        let before = base
        let anchorRow = "b"
        let anchorSlot = 1
        let beforeIndex = before.ids.firstIndex(of: anchorRow)!
        let lineBefore = before.line(ofRow: beforeIndex, slot: anchorSlot)
        #expect(lineBefore == 7)

        let after = Table(
            ids: ["o1", "o2", "a", "b", "c"],
            heights: [40, 60, 30, 48, 80],
            spacing: gap,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            lineHeight: quantum
        )
        let afterIndex = after.ids.firstIndex(of: anchorRow)!
        #expect(after.line(ofRow: afterIndex, slot: anchorSlot) == lineBefore)
        // The total grew, the newest line did not move.
        #expect(after.totalLines == 17)
        #expect(after.line(ofRow: after.ids.firstIndex(of: "c")!, slot: 4) == 1)
    }

    // MARK: - Reflow

    /// **A re-wrapped row changes its line number, not the anchor.** The same
    /// message, at the same point inside it, moves from line 7 to line 11 when
    /// row `b` grows from 3 lines to 7; the point 20 into the row still lands
    /// in the same row's slice.
    @Test func testAReformattedRowMovesTheLineNumberNotTheAnchor() {
        let before = base
        let anchorRow = "b"
        let anchorOffset: CGFloat = 20
        let beforeIndex = before.ids.firstIndex(of: anchorRow)!
        let anchorY = before.yBottom(ofLine: before.line(ofRow: beforeIndex, slot: 0)!)!
            - before.slotHeight(ofRow: beforeIndex) + anchorOffset
        #expect(before.line(atBottomEdge: anchorY) == 7)

        // Row `b` wraps from 48 to 112 points: 7 lines instead of 3.
        let after = Table(
            ids: ["a", "b", "c"],
            heights: [30, 112, 80],
            spacing: gap,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            lineHeight: quantum
        )
        let afterIndex = after.ids.firstIndex(of: anchorRow)!
        #expect(after.lineCounts[afterIndex] == 7)
        let lineAfter = after.line(atBottomEdge: anchorY)!
        #expect(lineAfter == 11)
        #expect(lineAfter != before.line(atBottomEdge: anchorY)!)
        // The anchor is still in the same row, and the same point is inside
        // the slice the new line names.
        let (row, slot) = after.rowAndSlot(ofLine: lineAfter)!
        #expect(after.ids[row] == anchorRow)
        let sliceBottom = after.yBottom(ofLine: lineAfter)!
        let sliceTop = sliceBottom - after.slotHeight(ofRow: row)
        #expect(anchorY >= sliceTop)
        #expect(anchorY <= sliceBottom)
        #expect(slot == 1)
    }

    // MARK: - The bar

    /// The thumb sits at the bottom at the newest end and at the top at the
    /// clamp, and its length is the share of the document one screen covers.
    @Test func testTheThumbSitsAtTheEndsItShould() {
        let g = Bar.geometry(
            b: 1, totalLines: 100, fillLines: 10, trackH: 300,
            minThumb: 36, tickSpacing: 5
        )
        #expect(g.scrollableLines == 90)
        #expect(g.maxLine == 91)
        #expect(g.thumbH == 36)
        #expect(g.stepLines == 2)
        #expect(g.thumbY == 264)

        let top = Bar.geometry(
            b: 91, totalLines: 100, fillLines: 10, trackH: 300,
            minThumb: 36, tickSpacing: 5
        )
        #expect(top.thumbY == 0)

        let middle = Bar.geometry(
            b: 46, totalLines: 100, fillLines: 10, trackH: 300,
            minThumb: 36, tickSpacing: 5
        )
        #expect(middle.thumbY == 132)

        // A document that fits on one screen: a full thumb, no travel, no
        // position.
        let short = Bar.geometry(
            b: 1, totalLines: 9, fillLines: 9, trackH: 300,
            minThumb: 36, tickSpacing: 5
        )
        #expect(short.thumbH == 300)
        #expect(short.thumbY == 0)
        #expect(short.maxLine == 1)
    }

    /// A drag lands on a line, snapped to the drawn steps, never past either
    /// end.
    @Test func testADragLandsOnALineAndNeverPastTheEnds() {
        #expect(Bar.seekLine(fraction: 1, totalLines: 100, fillLines: 10, stepLines: 2) == 1)
        #expect(Bar.seekLine(fraction: 0, totalLines: 100, fillLines: 10, stepLines: 2) == 91)
        #expect(Bar.seekLine(fraction: 0.5, totalLines: 100, fillLines: 10, stepLines: 2) == 47)
        #expect(Bar.seekLine(fraction: -1, totalLines: 100, fillLines: 10, stepLines: 2) == 91)
        #expect(Bar.seekLine(fraction: 2, totalLines: 100, fillLines: 10, stepLines: 2) == 1)
        // Nothing to scroll: the only line is the newest.
        #expect(Bar.seekLine(fraction: 0, totalLines: 9, fillLines: 9, stepLines: 1) == 1)
    }

    /// One drawn tick stands for one line while they fit, and for a run once
    /// they do not.
    @Test func testAStepIsHowManyLinesOneTickStandsFor() {
        func step(_ total: Int, _ fill: Int) -> Int {
            Bar.geometry(
                b: 1, totalLines: total, fillLines: fill, trackH: 300,
                minThumb: 36, tickSpacing: 5
            ).stepLines
        }
        #expect(step(70, 10) == 1)
        #expect(step(71, 11) == 1)
        #expect(step(72, 12) == 1)
        #expect(step(73, 13) == 1)
        #expect(step(75, 14) == 2)
        #expect(step(670, 10) == 11)
        let fractions = Bar.tickFractions(totalLines: 100, fillLines: 10, stepLines: 2)
        #expect(fractions.count == 46)
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        #expect(Bar.tickFractions(totalLines: 9, fillLines: 9, stepLines: 1) == [0])
    }

    // MARK: - The feed's page size

    /// The viewport's rows are the rows its lines touch, so the feed's page
    /// size and the bar read one division, not two.
    @Test func testTheViewportRowsAreTheRowsItsLinesTouch() {
        let table = base
        #expect(table.rowsCovered(fromLine: 5, lines: 6) == 3)
        #expect(table.rowsCovered(fromLine: 1, lines: 1) == 1)
        #expect(table.rowsCovered(fromLine: 1, lines: 100) == 3)
        let empty = Table(
            ids: [], heights: [], spacing: gap,
            topPadding: topPadding, bottomPadding: bottomPadding,
            lineHeight: quantum
        )
        #expect(empty.totalLines == 0)
        #expect(empty.line(atBottomEdge: 0) == nil)
        #expect(empty.maxLine(viewport: 100) == 1)
        #expect(empty.rowsCovered(fromLine: 1, lines: 1) == 0)
    }
}
