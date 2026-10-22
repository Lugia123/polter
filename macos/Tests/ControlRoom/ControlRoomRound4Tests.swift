import Foundation
import Testing
import AppKit
@testable import Ghostty

/// Round 4 (group seq 263): the same expectations as the Windows host's
/// `perf_scene` tests for the axis and the machine's line.
struct Round4Tests {
    typealias L = ControlRoomPerfLayout

    @Test func testAxisWordsNeverComeNearerThanTheGapAndNowIsAlwaysDrawn() {
        #expect(L.axisPlaces([(0, 50), (20, 30), (100, 30)], size: 10, gap: 12) == [0, nil, 80])
        #expect(L.axisPlaces([(0, 90), (100, 30)], size: 10, gap: 12) == [nil, 80])
        #expect(L.axisPlaces([(0, 30), (100, 30), (300, 30)], size: 10, gap: 12) == [0, 90, 280])
        #expect(L.axisPlaces([], size: 10, gap: 12) == [])
    }

    @Test func testTheMachineLineDropsWholeItemsInTheWindowsOrderAndNeverTheMemory() {
        let all = Set(L.MachineItem.allCases)
        let v = L.machineVariants(present: all)
        #expect(v.first == [.label, .mem, .swap, .pressure, .panes, .day])
        #expect(v.map(\.count) == [6, 5, 4, 3, 2, 1])
        #expect(v[1] == [.label, .mem, .swap, .pressure, .panes], "the day first")
        #expect(v[2] == [.label, .mem, .swap, .pressure], "then the terminals")
        #expect(v[3] == [.label, .mem, .pressure], "then the swap")
        #expect(v[4] == [.mem, .pressure], "then the label")
        #expect(v.last == [.mem])
        // Without a pressure there is one variant less, and the memory is
        // there even when not said to be.
        #expect(L.machineVariants(present: [.swap, .day]) == [[.mem, .swap, .day], [.mem, .swap], [.mem]])
    }

    @Test func testAWeeksDrawnCellsAreCountedInDays() {
        let week = L.Cells.fit(.week, count: 42, room: 10_000)
        #expect(same(week.drawn, 42))
        #expect(same(week.groups, 7))
        let day = L.Cells.fit(.day, count: 48, room: 10_000)
        #expect(same(day.groups, 1))
        // Only the newest 39 drawn: their days, not the week's.
        let narrow = L.Cells.fit(.week, count: 42, room: 300)
        #expect(narrow.first > 0)
        #expect(narrow.drawn == 42 - narrow.first)
        #expect(narrow.groups == 41 / 6 - narrow.first / 6 + 1)
    }

    @Test func testReturnIsTheTaskPagesOnlyWithTheKeyboardNoModifierAndNoTextBox() {
        typealias T = ControlRoomTasks
        #expect(T.returnIsThePages(keyCode: 36, modifiers: 0, pageHasKeyboard: true, textHasKeyboard: false))
        #expect(T.returnIsThePages(keyCode: 76, modifiers: 0, pageHasKeyboard: true, textHasKeyboard: false), "keypad Enter")
        #expect(!(T.returnIsThePages(keyCode: 36, modifiers: 0, pageHasKeyboard: false, textHasKeyboard: false)))
        #expect(!(T.returnIsThePages(keyCode: 36, modifiers: 0, pageHasKeyboard: true, textHasKeyboard: true)))
        #expect(!(T.returnIsThePages(keyCode: 36, modifiers: NSEvent.ModifierFlags.command.rawValue, pageHasKeyboard: true, textHasKeyboard: false)))
        #expect(!(T.returnIsThePages(keyCode: 8, modifiers: 0, pageHasKeyboard: true, textHasKeyboard: false)), "c")
    }

    /// The Windows core sends no swap (group seq 274): the page is drawn
    /// without it, whether the key is left out or null.
    @Test func testAnAnswerWithoutTheSwapIsStillAPage() throws {
        let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/control-room/testdata")
        let text = try String(contentsOf: dir.appendingPathComponent("resources-day.json"), encoding: .utf8)
        let line = "   \"swap\": \"交换 1.2 GB\",\n"
        #expect(text.contains(line), "the fixture's swap line is where this test looks")
        let without = text.replacingOccurrences(of: line, with: "")
        let null = text.replacingOccurrences(of: line, with: "   \"swap\": null,\n")
        for variant in [without, null] {
            let a = try ControlRoomResources.decode(Data(variant.utf8))
            #expect(a.machine.text.swap == nil)
            #expect(a.machine.text.mem == "23.9")
        }
        #expect(try ControlRoomResources.decode(Data(text.utf8)).machine.text.swap == "交换 1.2 GB")
    }

    /// Every field API.md §2.0's table lets be null, null at once, and keys
    /// this build does not know (`testdata/resources-nulls.json`,
    /// `tasks-nulls.json`; the Windows host reads the same two).
    @Test func testEveryFieldTheAPILetsBeNullIsReadAsNilAndUnknownKeysAreIgnored() throws {
        let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/control-room/testdata")
        let r = try ControlRoomResources.decode(Data(contentsOf: dir.appendingPathComponent("resources-nulls.json")))
        let m = r.machine.text
        #expect(m.mem == nil); #expect(m.mem_of == nil); #expect(m.swap == nil); #expect(m.pressure == nil)
        #expect(r.machine.pressure_tone == nil)
        #expect(!(r.cards.isEmpty))
        for c in r.cards {
            #expect(c.role == nil); #expect(c.badge == nil); #expect(c.lines.r1 == nil)
            #expect(c.lines.r2 == nil); #expect(c.lines.r3 == nil); #expect(c.line_at == nil)
        }
        let tones = r.grid.panes.flatMap { $0.hover.flatMap { $0.lines.map(\.tone) } }
        #expect(!(tones.isEmpty))
        #expect(tones.allSatisfy { $0 == nil })
        #expect(same(r.grid.cells, 48))

        let t = try ControlRoomTasks.decode(Data(contentsOf: dir.appendingPathComponent("tasks-nulls.json")))
        let log = t.open.compactMap(\.detail).flatMap(\.log)
        var events = 0
        for line in log {
            if case let .event(at, who, _, _) = line {
                events += 1
                #expect(at == nil); #expect(who == nil)
            }
        }
        #expect(events > 0)
    }
}

/// Both sides one type, so that a literal takes the other side's -- what
/// XCTAssertEqual's one generic parameter did.
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
