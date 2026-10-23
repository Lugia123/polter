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
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.dir.appendingPathComponent("\(name).json")) }
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
        // c is no longer among them: it is at the strip's right (#2083).
        #expect(same(t.hints.count, 3))
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
        // #2083: the filter box's words, "" while it is empty, none without it.
        // The selected one, for what Enter says it will do.
        #expect(T.request(group: "g", openTask: 215, closed: false, selected: 218) == "{\"page\":\"tasks\",\"group\":\"g\",\"open_task\":215,\"selected\":218,\"closed\":false}")
        #expect(T.request(group: "g", openTask: nil, closed: false, filter: "") == "{\"page\":\"tasks\",\"group\":\"g\",\"closed\":false,\"filter\":\"\"}")
        #expect(T.request(group: "g", openTask: nil, closed: false, filter: "批\"量") == "{\"page\":\"tasks\",\"group\":\"g\",\"closed\":false,\"filter\":\"批\\\"量\"}")
    }

    /// #2083: the closed tasks' line and its key, the strip's right-hand
    /// key -- the core's words, read as they are.
    @Test func theClosedLineAndItsKeysAreTheCores() throws {
        let t = try T.decode(open())
        #expect(t.closed_title == "已隐藏 8 条已关闭或已取消的任务")
        #expect(t.closed_key == T.Hint(key: "c", text: "或点这一行显示"))
        #expect(t.hint_closed == T.Hint(key: "c", text: "显示已关闭的 8 条"))
        #expect(t.filter == nil && t.no_match == nil)
        #expect(t.open.allSatisfy { $0.title_parts == nil })
        let c = try T.decode(closed())
        #expect(c.closed_title == "已关闭或已取消的 8 条")
        #expect(c.hint_closed?.text == "隐藏已关闭的")
        // None closed: no line, and nothing said of it at the right.
        let n = try T.decode(fixture("tasks-nulls"))
        #expect(n.closed_title == nil && n.closed_key == nil && n.hint_closed == nil)
    }

    /// #2083: the core's own answers (0x1c0de's examples, made by
    /// TaskPage.zig) read whole: nothing missing.
    @Test func theCoresOwnAnswersAreReadWhole() throws {
        for name in ["core-tasks-filtered", "core-tasks-no_match", "core-tasks-expanded", "core-tasks-closed_shown"] {
            let t = try T.decode(fixture(name))
            #expect(t.missing == [], "\(name)")
            #expect(same(t.hints.count, 3))
        }
        let f = try T.decode(fixture("core-tasks-filtered"))
        let parts = try #require(f.open.first?.title_parts)
        #expect(parts.map(\.text).joined() == f.open[0].title)
        #expect(parts.contains { $0.hit })
        let n = try T.decode(fixture("core-tasks-no_match"))
        #expect(n.open.isEmpty && n.no_match != nil && n.closed_title == nil)
    }

    /// #2083: **the core filters** and cuts each title where it found the
    /// words; the page draws the pieces and says what the core says.
    @Test func aFilteredAnswerIsReadPieceByPiece() throws {
        let t = try T.decode(fixture("tasks-filter"))
        #expect(t.filter == T.Filter(prompt: "按标题筛选", text: "批量", count: "2 / 6 条", clear: T.Hint(key: "Esc", text: "清空")))
        #expect(same(t.open.map(\.id), [216, 218]))
        for task in t.open {
            let parts = try #require(task.title_parts)
            #expect(parts.map(\.text).joined() == task.title)
            #expect(parts.filter(\.hit).map(\.text) == ["批量"])
        }
        // None closed holds it: no closed line.
        #expect(t.closed_title == nil)
        #expect(t.missing == [])
        let m = try T.decode(fixture("tasks-nomatch"))
        #expect(m.open.isEmpty)
        #expect(m.no_match == T.NoMatch(title: "没有标题里含「弹窗」的任务", detail: "已关闭的也找过了。按 Esc 清空筛选。"))
        #expect(m.missing == [])
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

    /// #2083: narrower than `title_min` for the title, the idle column goes
    /// and the owner's narrows: at 630 the title still has its 200.
    @Test func narrowTheIdleColumnGoes() {
        let wide = T.columns(width: 630)
        #expect(same(wide[3].width, 200)); #expect(same(wide[5].width, 96)); #expect(same(wide[4].width, 120))
        let narrow = T.columns(width: 629)
        #expect(same(narrow[5].width, 0)); #expect(same(narrow[4].width, 96))
        #expect(same(narrow[4].x + narrow[4].width, 617))
        #expect(same(narrow[3].width, 617 - 96 - 202))
    }

    @Test func testEachStateWearsItsOwnSymbolAndColourKey() {
        let t = ControlRoomLook.theme(dark: true)
        #expect(T.Glyph.allCases.map(T.symbol) == ["circle", "clock", "minus.circle", "checkmark.circle", "checkmark", "xmark.circle"])
        #expect(T.color(.working, theme: t) == t.taskWorking)
        #expect(T.color(.closed, theme: t) == t.taskClosed)
        #expect(T.color(.cancelled, theme: t) == t.taskCancelled)
    }

    /// The Windows host's nominal widths (`perf_scene` tests' `nominal`): a
    /// cell a character, two a wide one, `StackTab.nominalCellWidth` each.
    static func nominal(_ s: String) -> CGFloat {
        CGFloat(s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }) * CGFloat(ControlRoomLook.StackTab.nominalCellWidth)
    }

    /// The goal a line at a time (#2060), as the chat's brief is: each line
    /// wrapped on its own, the empty ones skipped, two rows at most. The
    /// rows the Windows host's `tasks_scene::goal_rows` gives for the same
    /// lines and widths.
    @Test func theGoalIsItsLinesEachWrappedAndTwoRowsAtMost() {
        let lines = ["第 5 轮进行中（2026-10-22）：", "", "- frontend：列表多选和工具条", "- api: PATCH /api/tasks"]
        #expect(T.goalRows(lines, width: 1000, measure: Self.nominal) == [lines[0], lines[2]])
        // The first line wrapping to two leaves no room for the second --
        // and breaks where the Windows host breaks it.
        #expect(T.goalRows(lines, width: 160, measure: Self.nominal) == ["第 5", "轮进行中（2026-10-2"])
        #expect(T.goalRows([], width: 1000, measure: Self.nominal) == [])
        #expect(T.goalRows([lines[3]], width: 1000, measure: Self.nominal) == [lines[3]])
        // A closing mark never begins a row: the character before goes
        // down with it (推出), as `tasks_scene::break_before`.
        #expect(T.wrap("一二三四五。六七", width: 5 * 16, measure: Self.nominal) == ["一二三四", "五。六七"])
    }

    @Test func theGoalLinesAreRead() throws {
        let t = try T.decode(open())
        #expect(t.goal_lines == [t.goal])
        #expect(t.missing == [])
    }
}

/// Both sides one type, so that a literal takes the other side's -- what
/// XCTAssertEqual's one generic parameter did.
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
