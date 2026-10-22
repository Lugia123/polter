import Foundation
import Testing
@testable import Ghostty

/// Mac round 4's leftovers (group seq 290).
struct M6Tests {
    typealias T = ControlRoomTasks
    typealias L = ControlRoomPerfLayout

    /// 0x373c's steps: press #2 (opened), ↓ to #3, Return -- #3 is opened
    /// and #2 shut, and the line says #3 opened; Return again shuts #3.
    @Test func testReturnActsOnTheSelectedTask() {
        var (selected, open) = T.afterPress(2, open: nil)
        #expect(same(selected, 2)); #expect(same(open, 2))
        selected = 3 // ↓ moves only the selection
        (selected, open) = T.afterReturn(selected: selected, open: open, first: 2)
        #expect(same(selected, 3)); #expect(same(open, 3), "the selected one opened, the other shut")
        (selected, open) = T.afterReturn(selected: selected, open: open, first: 2)
        #expect(open == nil, "the open one shut")
        // Nothing selected: the first.
        #expect(same(T.afterReturn(selected: nil, open: nil, first: 7).open, 7))
        #expect(T.afterReturn(selected: nil, open: nil, first: nil).selected == nil)
        // A press on the open one shuts it and keeps it selected.
        #expect(T.afterPress(3, open: 3).open == nil)
        #expect(same(T.afterPress(3, open: 3).selected, 3))
    }

    /// What the canvas draws (`drawnCells`), counted off the rectangles,
    /// is what `Cells` says was drawn: a week in 42 cells and 7 days, a day
    /// in 48 and one, a narrow day in its newest cells.
    @Test func testTheDrawnCellsAreTheCellsTheLineCounts() throws {
        let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/control-room/testdata")
        for (file, width, columns, groups) in [("resources-week.json", 1388.0, 42, 7), ("resources-day.json", 1388.0, 48, 1), ("resources-day.json", 448.0, -1, 1)] {
            let a = try ControlRoomResources.decode(Data(contentsOf: dir.appendingPathComponent(file)))
            let at = L(a, width: CGFloat(width))
            let drawn = at.drawnCells()
            #expect(drawn.count == at.cells.drawn * a.grid.panes.count, Comment(rawValue: file))
            let counted = L.columnsAndGroups(drawn.map(\.rect), gap: at.cells.gap)
            #expect(counted.columns == at.cells.drawn, "\(file) at \(width)")
            #expect(counted.groups == at.cells.groups, "\(file) at \(width)")
            if columns > 0 {
                #expect(counted.columns == columns, Comment(rawValue: file))
                #expect(counted.groups == groups, Comment(rawValue: file))
            }
        }
    }
}

/// Both sides one type, so that a literal takes the other side's -- what
/// XCTAssertEqual's one generic parameter did.
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
