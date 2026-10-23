import Foundation
import Testing
@testable import Ghostty

/// The Windows host's `tasks` and `tasks_scene` expectations, from the same
/// fake answers.
struct TasksTests {
    typealias T = ControlRoomTasks
    static let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/control-room/testdata")
    func open() throws -> Data { try Data(contentsOf: Self.dir.appendingPathComponent("tasks-open.json")) }
    func closed() throws -> Data { try Data(contentsOf: Self.dir.appendingPathComponent("tasks-closed.json")) }
    func replaced(_ d: Data, _ a: String, _ b: String) -> Data {
        var s = String(data: d, encoding: .utf8)!
        s.replaceSubrange(s.range(of: a)!, with: b)
        return Data(s.utf8)
    }

    @Test func testTheFakeAnswersAreReadWhole() throws {
        let t = try T.decode(open())
        #expect(same(t.open.count, 6))
        #expect(t.closed.isEmpty)
        #expect(same(t.closed_count, 8))
        let opened = t.open.filter { $0.detail != nil }
        #expect(same(opened.count, 1))
        #expect(opened[0].bold)
        let d = opened[0].detail!
        #expect(same(d.log.filter { if case .gap = $0 { return true } else { return false } }.count, 2))
        if case let .event(_, _, _, last)? = d.log.last { #expect(last) } else { Issue.record("the last line is an event") }
        #expect(same(d.said.count, 4))
        #expect(same(t.hints.count, 4))
        let c = try T.decode(closed())
        #expect(same(c.closed.count, 8))
        #expect(c.closed.allSatisfy { $0.glyph == .closed && !$0.bold })
        #expect(same(c.inOrder.count, 14))
    }

    /// A glyph or a kind of line this build does not know: that symbol, or
    /// that line, is left out and said -- no longer the page (group seq 309).
    @Test func aGlyphOrALineThisBuildDoesNotKnowCostsOnlyItsItem() throws {
        let g = try T.decode(replaced(open(), "\"glyph\": \"working\"", "\"glyph\": \"sleeping\""))
        #expect(g.open.filter { $0.glyph == nil }.count == 1)
        #expect(g.missing.contains { $0.hasSuffix(".glyph") })
        let e = try T.decode(replaced(open(), "\"entry\": \"gap\"", "\"entry\": \"pause\""))
        #expect(e.missing.contains { $0.hasSuffix(".entry") })
        #expect(throws: T.DecodeError.refused("NoSuchTask")) { try T.decode(Data("{\"error\":\"NoSuchTask\"}".utf8)) }
    }

    @Test func testTheRequestSaysTheOpenTaskOnlyWhenThereIsOne() {
        #expect(T.request(group: "web-app", openTask: 215, closed: false) == "{\"page\":\"tasks\",\"group\":\"web-app\",\"open_task\":215,\"closed\":false}")
        #expect(T.request(group: "a\"b", openTask: nil, closed: true) == "{\"page\":\"tasks\",\"group\":\"a\\\"b\",\"closed\":true}")
    }

    @Test func testTheArrowsGoThroughInOrderAndStopAtTheEnds() throws {
        let t = try T.decode(closed())
        #expect(same(T.step(t, from: nil, down: true), 214))
        #expect(same(T.step(t, from: 214, down: false), 214))
        #expect(same(T.step(t, from: 219, down: true), 213))
        #expect(same(T.step(t, from: 206, down: true), 206))
        #expect(same(T.step(t, from: 999, down: true), 214))
    }

    @Test func testTheColumnsStandAsV9HasThem() {
        // A line 1000 wide from x 24 on Windows; here from 0.
        let c = T.columns(width: 1000)
        #expect(same(c[0].x, 12)); #expect(same(c[0].width, 26))
        #expect(same(c[1].x, 38)); #expect(same(c[1].width, 60))
        #expect(same(c[2].x, 98)); #expect(same(c[2].width, 104))
        #expect(same(c[3].x, 202))
        #expect(same(c[5].x + c[5].width, 988)); #expect(same(c[5].width, 96))
        #expect(c[4].x + c[4].width == c[5].x); #expect(same(c[4].width, 120))
        #expect(c[3].x + c[3].width == c[4].x)
    }

    @Test func testEachStateWearsItsOwnSymbolAndColourKey() {
        let t = ControlRoomLook.theme(dark: true)
        #expect(T.Glyph.allCases.map(T.symbol) == ["circle", "clock", "minus.circle", "checkmark.circle", "checkmark", "xmark.circle"])
        #expect(T.color(.working, theme: t) == t.taskWorking)
        #expect(T.color(.closed, theme: t) == t.taskClosed)
        #expect(T.color(.cancelled, theme: t) == t.taskCancelled)
    }
}

/// Both sides one type, so that a literal takes the other side's -- what
/// XCTAssertEqual's one generic parameter did.
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
