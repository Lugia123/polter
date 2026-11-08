import CoreGraphics
import Foundation

/// **The chat's lines, as arithmetic** (task 3081, design §29.7).
///
/// A line is a **scroll quantum**: `lineHeight` points of the stack as it is
/// actually laid out. One step of the wheel, one row of the index bar and one
/// unit of the drag are all this same line, and the position of the list is
/// **the line at the viewport's bottom edge** (`b`, `1` = newest).
///
/// **Why a row is split evenly instead of being measured per line.** SwiftUI
/// reports a whole message's frame, not the frames of the lines inside it.
/// A row of height `H` therefore holds `n = max(1, round(H / lineHeight))`
/// lines, each `H / n` tall -- so the row's own bottom is exact, and the line
/// inside it is never more than half a quantum off. The cost is stated where
/// it is paid: a fenced block's physical lines are **not** aligned with these
/// slices; only a plain paragraph's wrapping is.
///
/// **The numbering runs from the newest end.** Line `1` is the bottom-most
/// slice of the newest plan row; line `totalLines` is the top-most slice of
/// the oldest. Appending older rows above the reader therefore **never
/// renumbers a line near the newest end** -- which is what "loading keeps `b`"
/// means (design §29.7 rule 6).
///
/// **Every row counts**, boundary marks included (`start` / `end` / `gap`):
/// they take vertical room, and the bar and the wheel must traverse it. There
/// is deliberately no second notion of "content line" (supervisor, #3081).
///
/// **The vertical rule is the one the camera already uses.** A row's top is
/// `topPadding` plus the rows above it plus their `spacing`; the gap below a
/// row belongs to that row, exactly like `ControlRoomChatCamera.place` and
/// `Layout.index(at:)`. `line(atBottomEdge:)` is total: every y maps to the
/// line whose bottom is at or above it, so any writer of `camera.place` gets
/// one consistent `b` (supervisor, #3081 hard criterion).
struct ControlRoomChatLineTable {
    /// Coordinates within this many points of a boundary are read as **on**
    /// it. Small enough to be invisible, large enough to absorb the rounding
    /// of a measured frame.
    static let boundaryTolerance: CGFloat = 0.000_001

    /// The plan's row ids, in document order (oldest first, like `feed.rows`).
    let ids: [String]
    /// Each row's rendered height, aligned with `ids`. Estimates are allowed:
    /// a row that has not been drawn is an estimate here for the same reason
    /// it is one in `Layout` -- it is replaced the moment the row is measured.
    let heights: [CGFloat]
    /// The stack's spacing between rows, in points.
    let spacing: CGFloat
    /// The list's padding above the first row, in points.
    let topPadding: CGFloat
    /// The list's padding below the last row, in points. It is **not** part of
    /// a line: at `b == 1` the newest line sits on the viewport's bottom edge
    /// and this padding is below it (clipped), which is what §29.7 rule 2 asks.
    let bottomPadding: CGFloat
    /// One line, in points. At least 1 so a caller cannot divide by zero.
    let lineHeight: CGFloat

    /// How many lines each row holds, aligned with `ids`.
    let lineCounts: [Int]
    /// **How many lines are newer than a row** (below it), aligned with `ids`.
    /// The top-most slice of row `i` is `linesNewer[i] + lineCounts[i]`; its
    /// bottom-most slice is `linesNewer[i] + 1`.
    let linesNewer: [Int]
    /// `Σ lineCounts`.
    let totalLines: Int

    private let rowTops: [CGFloat]

    init(
        ids: [String],
        heights: [CGFloat],
        spacing: CGFloat,
        topPadding: CGFloat,
        bottomPadding: CGFloat,
        lineHeight: CGFloat
    ) {
        precondition(ids.count == heights.count, "one height per row")
        let quantum = max(1, lineHeight)
        let clipped = heights.map { max(0, $0) }
        self.ids = ids
        self.heights = clipped
        self.spacing = max(0, spacing)
        self.topPadding = max(0, topPadding)
        self.bottomPadding = max(0, bottomPadding)
        self.lineHeight = quantum

        var tops = [CGFloat]()
        tops.reserveCapacity(ids.count)
        var y = max(0, topPadding)
        for height in clipped {
            tops.append(y)
            y += height + max(0, spacing)
        }
        self.rowTops = tops

        var counts = [Int]()
        counts.reserveCapacity(ids.count)
        for height in clipped {
            counts.append(max(1, Int((height / quantum).rounded())))
        }
        self.lineCounts = counts

        var newer = [Int](repeating: 0, count: ids.count)
        var running = 0
        if !ids.isEmpty {
            for index in stride(from: ids.count - 1, through: 0, by: -1) {
                newer[index] = running
                running += counts[index]
            }
        }
        self.linesNewer = newer
        self.totalLines = running
    }

    /// The document's top edge, as the table measures it.
    var contentTop: CGFloat { ids.isEmpty ? topPadding : rowTops[0] }

    /// The document's bottom, including the bottom padding: the same number
    /// `Layout.contentHeight` answers.
    var contentBottom: CGFloat {
        guard let last = ids.indices.last else { return topPadding + bottomPadding }
        return rowTops[last] + heights[last] + bottomPadding
    }

    /// One slice's height inside a row. `0` for a row with no height (it still
    /// occupies one degenerate line).
    func slotHeight(ofRow index: Int) -> CGFloat {
        guard lineCounts.indices.contains(index), lineCounts[index] > 0 else { return 0 }
        return heights[index] / CGFloat(lineCounts[index])
    }

    /// The line number of a row's slice: `slot` counts from the row's **top**
    /// (`0`), so `slot == lineCounts[i] - 1` is the slice nearest the newest
    /// end, the one with the smallest number.
    func line(ofRow index: Int, slot: Int) -> Int? {
        guard lineCounts.indices.contains(index) else { return nil }
        let count = lineCounts[index]
        let bounded = min(max(0, slot), count - 1)
        return linesNewer[index] + count - bounded
    }

    /// The row and slice a line number names. `nil` only for an empty table.
    func rowAndSlot(ofLine line: Int) -> (index: Int, slot: Int)? {
        guard totalLines > 0 else { return nil }
        let wanted = min(max(1, line), totalLines)
        for index in ids.indices {
            let bottom = linesNewer[index] + 1
            let top = bottom + lineCounts[index] - 1
            if wanted >= bottom, wanted <= top {
                return (index, top - wanted)
            }
        }
        return nil
    }

    /// The document's y of a line's **bottom** edge.
    func yBottom(ofLine line: Int) -> CGFloat? {
        guard let (index, slot) = rowAndSlot(ofLine: line) else { return nil }
        return rowTops[index] + CGFloat(slot + 1) * slotHeight(ofRow: index)
    }

    /// The document's y the viewport's **top** edge takes when `line` sits on
    /// the viewport's bottom edge. Not clamped here: the surface clamps the
    /// clip to `[0, contentBottom - viewport]`.
    func yTop(ofLine line: Int, viewport: CGFloat) -> CGFloat? {
        guard let bottom = yBottom(ofLine: line) else { return nil }
        return bottom - max(0, viewport)
    }

    /// **The line at the viewport's bottom edge**: the line whose bottom is at
    /// or above `edge`, with the line just above an exact boundary chosen (so
    /// `yTop(ofLine:)` round-trips). A point in the gap below a row belongs to
    /// that row, as everywhere else in this file.
    func line(atBottomEdge edge: CGFloat) -> Int? {
        guard totalLines > 0, !ids.isEmpty else { return nil }
        // Above the first row is the oldest line: the nearest thing there is.
        if edge <= rowTops[0] + Self.boundaryTolerance {
            return totalLines
        }
        // The last row whose top is strictly above the edge. The strict
        // comparison is what puts an edge exactly on the next row's top in
        // the gap above it, not in that row.
        var row = 0
        for index in ids.indices where rowTops[index] + Self.boundaryTolerance < edge {
            row = index
        }
        let count = lineCounts[row]
        let slotHeight = heights[row] / CGFloat(count)
        let rowBottom = rowTops[row] + heights[row]
        let slot: Int
        if edge >= rowBottom - Self.boundaryTolerance || slotHeight <= Self.boundaryTolerance {
            // The gap below a row belongs to its bottom slice.
            slot = count - 1
        } else {
            // The smallest slot whose bottom is at or below `edge`; at an
            // exact boundary the tolerance moves it to the slice above.
            let raw = (edge - rowTops[row] - Self.boundaryTolerance) / slotHeight
            slot = min(count - 1, max(0, Int(ceil(raw)) - 1))
        }
        return line(ofRow: row, slot: slot)
    }

    /// The line at the bottom edge of a viewport whose top is `origin`.
    func line(viewportTop origin: CGFloat, viewport: CGFloat) -> Int? {
        line(atBottomEdge: origin + max(0, viewport))
    }

    /// **The smallest number of lines, measured from the oldest end, that
    /// fills the viewport.** Inter-row spacing counts; the padding above the
    /// first row does not (the clamp puts the first row's top on the viewport
    /// edge, never the padding). `totalLines` when the whole document is
    /// shorter than the viewport.
    func fillLines(viewport: CGFloat) -> Int {
        guard totalLines > 0 else { return 0 }
        let target = max(0, viewport)
        guard target > 0 else { return 0 }
        var sum: CGFloat = 0
        var count = 0
        for index in ids.indices {
            let slice = heights[index] / CGFloat(lineCounts[index])
            for _ in 0..<lineCounts[index] {
                sum += slice
                count += 1
                if sum >= target { return count }
            }
            if index < ids.count - 1 { sum += spacing }
        }
        return totalLines
    }

    /// **The highest `b` that still fills the viewport** (design §29.7 rule 4).
    /// Larger than this and the viewport would show blank space above the
    /// oldest line; the top padding is what makes the first unreachable
    /// position look empty, so the clamp stops one line short of it.
    func maxLine(viewport: CGFloat) -> Int {
        guard totalLines > 0 else { return 1 }
        let fill = max(1, fillLines(viewport: viewport))
        return max(1, totalLines - fill + 1)
    }

    /// **How many plan rows the lines `line ... line + lines - 1` touch.** The
    /// feed's page size is in rows; the bar's unit is lines; this is the one
    /// conversion between them.
    func rowsCovered(fromLine line: Int, lines: Int) -> Int {
        guard totalLines > 0, lines > 0 else { return 0 }
        let bottom = min(totalLines, max(1, line))
        let top = min(totalLines, max(bottom, line + lines - 1))
        // Line numbers grow towards the oldest end, i.e. towards **smaller**
        // row indices; the bottom line therefore names the higher index.
        guard let bottomRow = rowAndSlot(ofLine: bottom),
              let topRow = rowAndSlot(ofLine: top) else { return 0 }
        return max(1, bottomRow.index - topRow.index + 1)
    }
}
