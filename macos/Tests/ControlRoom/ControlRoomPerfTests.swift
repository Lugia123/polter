import Foundation
import Testing
@testable import Ghostty

/// The Windows host's `perf` and `perf_scene` expectations, from the same
/// fake answers (`windows/control-room/testdata`).
struct PerfTests {
    typealias R = ControlRoomResources
    typealias L = ControlRoomPerfLayout
    static let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/control-room/testdata")
    func day() throws -> Data { try Data(contentsOf: Self.dir.appendingPathComponent("resources-day.json")) }
    func week() throws -> Data { try Data(contentsOf: Self.dir.appendingPathComponent("resources-week.json")) }
    func edited(_ d: Data, after: String, _ from: String, _ to: String) -> Data {
        var s = String(data: d, encoding: .utf8)!
        let start = s.range(of: after)!.lowerBound
        let r = s.range(of: from, range: start..<s.endIndex)!
        s.replaceSubrange(r, with: to)
        return Data(s.utf8)
    }

    @Test func testTheFakeAnswersAreReadWhole() throws {
        let a = try R.decode(day())
        #expect(same(a.cards.count, 8))
        #expect(a.grid.span == .day)
        #expect(same(a.grid.cells, 48))
        #expect(same(a.grid.panes.count, 8))
        #expect(a.machine.text.label == "整机")
        #expect(a.grid.spans?.map(\.span) == [.day, .week])
        let ocr = a.cards.first { $0.name == "ocr-mask" }!
        #expect(ocr.tone == .killed)
        #expect(ocr.badge?.tone == .killed)
        #expect((ocr.dial?.fraction ?? 0) > 1)
        #expect(same(ocr.points.count, 150))
        let me = a.cards.first { $0.role == "你的终端" }!
        #expect(me.line_at == nil)
        #expect(me.dial?.ticks.isEmpty == true)
        let w = try R.decode(week())
        #expect(w.grid.span == .week)
        #expect(same(w.grid.cells, 42))
    }

    /// A value this build does not know costs what it is drawn as, and is
    /// said -- no longer the page (group seq 309). The Windows host's
    /// expectations.
    @Test func aToneOrSpanThisBuildDoesNotKnowCostsOnlyItsItem() throws {
        let d = try day()
        let whole = try R.decode(d)
        #expect(whole.missing == [])
        let card = try R.decode(edited(d, after: "\"cards\"", "\"tone\": \"warn2\"", "\"tone\": \"warn9\""))
        #expect(card.missing.contains { $0.hasPrefix("cards[") && $0.hasSuffix(".tone") }, Comment(rawValue: "\(card.missing)"))
        let span = try R.decode(edited(d, after: "\"grid\"", "\"span\": \"day\"", "\"span\": \"month\""))
        #expect(span.missing.contains("grid.span"))
        #expect(span.grid.panes.isEmpty && span.grid.axis.isEmpty, "no grid without its span")
        #expect(!span.cards.isEmpty, "and the rest is drawn")
        let gone = try R.decode(edited(d, after: "\"panes\": [", "\"none\",", "\"gone\","))
        #expect(gone.missing.contains { $0.hasPrefix("grid.panes[0].cells[") }, Comment(rawValue: "\(gone.missing)"))
        let short = try R.decode(edited(d, after: "\"panes\": [", "\"none\",", ""))
        #expect(short.grid.panes.count == whole.grid.panes.count - 1)
        #expect(short.missing.contains("grid.panes[0].cells"))
        #expect(try R.decode(edited(d, after: "\"panes\": [", "\"none\",", "\"ok\",")).missing == [])
        #expect(throws: R.DecodeError.refused("NoSuchGroup")) { try R.decode(Data("{\"error\":\"NoSuchGroup\"}".utf8)) }
        #expect(throws: R.DecodeError.noGroup) { try R.decode(edited(d, after: "{", "\"group\":", "\"gruop\":")) }
    }

    @Test func testTheRequestQuotesTheGroup() {
        #expect(R.request(group: "web\"app", span: .week, since: 12) == "{\"page\":\"resources\",\"group\":\"web\\\"app\",\"span\":\"week\",\"since\":12}")
    }

    @Test func testCurvesAreReplacedAddedToAndCutAt150() throws {
        var a = try R.decode(day())
        var c = R.Curves()
        c.take(a)
        let id = a.cards[0].id
        #expect(same(c.points(id).count, 150))
        #expect(c.since == a.seq)
        let last = c.points(id).last!
        a.full = false
        a.seq += 1
        for i in a.cards.indices { a.cards[i].points = [[last.0 + 2000, 1], [last.0 + 4000, 2]] }
        let third = c.points(id)[2]
        c.take(a)
        #expect(same(c.points(id).count, 150))
        #expect(c.points(id)[0] == third)
        #expect(c.points(id).last! == (last.0 + 4000, 2))
        a.cards = [a.cards[0]]
        a.full = true
        c.take(a)
        #expect(same(c.points(id).count, 2))
        #expect(c.points(try R.decode(day()).cards[1].id).isEmpty)
    }

    @Test func testCards242By196With16BetweenAsManyARowAsFit() throws {
        #expect(same(L.columns(242), 1))
        #expect(same(L.columns(242 * 2 + 16 - 0.5), 1))
        #expect(same(L.columns(242 * 2 + 16), 2))
        #expect(same(L.columns(4 * 242 + 3 * 16), 4))
        #expect(same(L.columns(10), 1))
        let at = L(try R.decode(day()), width: 1040)
        #expect(at.cards.allSatisfy { $0.width == 242 && $0.height == 196 })
        #expect(same(at.cards[1].minX - at.cards[0].minX, 258))
        #expect(same(at.cards[4].minY - at.cards[0].minY, 212))
        #expect(at.cards[4].minX == at.cards[0].minX)
    }

    @Test func testACardsPartsAreWhereUiV4MeasuredThem() {
        let g = L.cardGrid(CGRect(x: 100, y: 50, width: 242, height: 196))
        let at = { (r: CGRect) in [r.minX - 100, r.minY - 50] }
        #expect(at(g.r1) == [132, 40]); #expect(at(g.r2) == [132, 72])
        #expect(at(g.r3) == [132, 100]); #expect(at(g.r4) == [132, 128])
        #expect(at(g.dial) == [14, 40]); #expect(at(g.foot) == [14, 164])
        #expect(at(g.cap) == [14, 126])
        #expect(same(g.foot.maxY + 12, 50 + 196))
    }

    @Test func testTheOverviewHoldsTheMachineLineTheHeadingTheRowsAndTheAxis() throws {
        let at = L(try R.decode(day()), width: 1040)
        #expect([at.summary.minX, at.summary.minY] == [12, 12])
        #expect([at.top.minX, at.top.minY, at.top.height] == [28, 24, 32])
        #expect(same(at.gridHead.minY, 66))
        #expect(same(at.rowsTop, 94))
        let axisY: CGFloat = 94 + 144 + 28 + 6
        #expect(at.axis.minY == axisY)
        #expect(at.summary.maxY == at.axis.maxY + 12)
        #expect(at.cardsHead.minY == at.summary.maxY + 12)
        #expect(at.cards[0].minY == at.cardsHead.maxY + 8)
        #expect(same(at.cellsX, 172))
        // A 1040-wide page has 840 of room for the cells (1040 less the
        // page's and the box's padding and the names' 144) and needs 765 at
        // the look's size -- so they are drawn 840/765 of the way up:
        // 14.274509803921569 square with 3.2941176470588238 between, and the
        // row runs to its end. Task 2234, the user: at 13 and 3 the last
        // cell's right edge was at 172 + 752, 88 pt short of it.
        let c0 = at.cellRect(0, 0)!
        #expect(same(c0.minX, 172))
        #expect(abs((Double(c0.width)) - 14.274509803921569) <= 1e-9)
        #expect(abs((Double(c0.minY)) - (94 + (18 - 14.274509803921569) / 2)) <= 1e-9)
        #expect(abs((Double(at.cellRect(0, 47)!.maxX)) - (172 + 840)) <= 1e-9)
        #expect(at.contentHeight == at.cards[7].maxY + 12)
    }

    /// The day boundaries and the gap between them, at the room the cells
    /// need exactly (711 for a week: 42 of 13 with 41 of 3 and 6 of 7; 765
    /// for a day) -- where nothing is scaled, so the numbers are the look's.
    /// A wider room scales them up: `testAWideRoomDrawsTheCellsBiggerAndUsesItAll`.
    @Test func testTheWeekStandsInDaysWithAGapBetween() throws {
        let w = L.Cells.fit(.week, count: 42, room: 711)
        #expect(same(w.offset(5), 80))
        #expect(same(w.offset(6), 96 + 7))
        let weekEnd: CGFloat = 656 + 42
        #expect(w.offset(41) == weekEnd)
        #expect(same(L.Cells.fit(.day, count: 48, room: 765).offset(41), 656))
    }

    /// Task 2234, the user: the grid did not grow with the window, so a wide
    /// window left a wide empty right-hand side. The cells are drawn to the
    /// room they have now -- up as well as down -- and no bigger than
    /// `Pending.maxCell`.
    @Test func testAWideRoomDrawsTheCellsBiggerAndUsesItAll() throws {
        let a = try R.decode(day())
        // A page 1200 wide leaves the cells 1000 (1200 less the page's and
        // the box's padding and the names' 144), against the 765 they need
        // at the look's size: 1000/765 of 13 is 16.99346405228758.
        let at = L(a, width: 1200)
        #expect(at.cells.size > 13)
        #expect(abs((Double(at.cells.size)) - 1000 / 765 * 13) <= 1e-9)
        // Filled to the room's end, the way the narrow end is: the last
        // cell's right edge is `cellsX + 1000`, and none of them was
        // dropped to fit the rest.
        #expect(abs((Double(at.cellRect(0, 47)!.maxX)) - (Double(at.cellsX) + 1000)) <= 1e-9)
        #expect(at.cellRect(0, 47)!.maxX <= at.summary.maxX)
        #expect(same(at.cells.first, 0))
        #expect(same(at.cells.drawn, 48))
        // A window wider still stops the cell at `Pending.maxCell`: past
        // that the empty side comes back, which is the cap and not the
        // bug -- the user's number, to be looked at again if it reads as
        // empty.
        let wide = L(a, width: 3000)
        #expect(same(wide.cells.size, L.Pending.maxCell))
        #expect(wide.cellRect(0, 47)!.maxX < wide.summary.maxX, "past the cap the rest is left empty")
        // A week too: 42 of 13 with 41 of 3 and 6 of 7 need 711, and at
        // 1200 the room is 1000.
        let w = try R.decode(week())
        #expect(abs((Double(L(w, width: 1200).cells.size)) - 1000 / 711 * 13) <= 1e-9)
    }

    /// 0x4881, group seq 220 (the Windows host): at the window's first size
    /// the cells ran past the frame. Narrower they shrink, square; narrower
    /// still, the newest that fit stand against the right end.
    @Test func testTooNarrowTheCellsShrinkAndThenOnlyTheNewestAreDrawn() throws {
        let a = try R.decode(day())
        let fits = L(a, width: 600 + 144 + 32 + 24)
        #expect(same(fits.cells.first, 0))
        #expect(fits.cells.size < 13)
        #expect(fits.cells.size > 8)
        let last = fits.cellRect(0, 47)!
        #expect(abs((Double(last.maxX)) - (Double(fits.cellsX + 600))) <= 1e-9)
        #expect(last.width == last.height)
        let narrow = L(a, width: 588)
        #expect(same(narrow.cells.size, 8))
        #expect(same(narrow.cells.gap, 2))
        #expect(same(narrow.cells.first, 48 - 39))
        #expect(narrow.cellRect(0, narrow.cells.first - 1) == nil)
        #expect(narrow.cellRect(0, 47)!.maxX == narrow.cellsX + 388)
        #expect(narrow.cellRect(0, 47)!.maxX <= narrow.summary.maxX)
        #expect(narrow.cell(at: CGPoint(x: narrow.cellsX + 1, y: narrow.rowsTop + 5), cells: 48)! == (0, narrow.cells.first))
    }

    @Test func testAPressFindsItsCellAndTheGapsFindNone() throws {
        let at = L(try R.decode(day()), width: 1040)
        let c = at.cellRect(3, 10)!
        #expect(at.cell(at: CGPoint(x: c.minX + 1, y: c.minY + 1), cells: 48)! == (3, 10))
        // The gap is `cells.gap` wide whatever the cells are scaled to
        // (3.294 at this width), so a point past the cell's right edge is
        // in it.
        #expect(at.cell(at: CGPoint(x: c.maxX + 1, y: c.minY + 1), cells: 48) == nil)
        #expect(at.cell(at: CGPoint(x: c.minX + 1, y: c.minY - 1), cells: 48) == nil)
    }

    @Test func testScrolledEverythingMovesUpAndTheHeightStays() throws {
        let a = try R.decode(day())
        let p = L(a, width: 1040), q = L(a, width: 1040, scroll: 100)
        #expect(q.cards[5].minY == p.cards[5].minY - 100)
        // Scaled cells put the middle of a row at a number that is not
        // exact, so this is compared the way the other measurements are.
        #expect(abs(Double(q.cellRect(1, 1)!.minY - (p.cellRect(1, 1)!.minY - 100))) <= 1e-9)
        #expect(p.contentHeight == q.contentHeight)
        #expect(same(p.maxScroll(p.contentHeight + 50), 0))
    }

    @Test func testTheTipIsAtTheCellsLeftLevelWithIt() throws {
        let at = L(try R.decode(day()), width: 1040)
        let t = at.tipRect(row: 3, cell: 46, lines: 4, width: 200)!
        let c = at.cellRect(3, 46)!
        #expect(t.maxX + 8 == c.minX)
        #expect(same(t.height, 100))
        #expect(t.minY + 10 + 10 == c.midY)
    }

    @Test func testTheCurveShowsItsSpanUnderItsScale() throws {
        let rect = CGRect(x: 0, y: 0, width: 96, height: 28)
        let now: UInt64 = 1_000_000, g: UInt64 = 1 << 30
        let pts: [(UInt64, UInt64)] = [(now - 400_000, 5 * g), (now - 300_000, 0), (now - 150_000, 10 * g), (now, 30 * g)]
        let c = R.curve(pts, lineAt: 19 * g, rect: rect, now: now, span: 300_000)
        #expect(c.line.map(\.x) == [0, 48, 96])
        #expect(same(c.line[0].y, 27))
        #expect(same(c.line[2].y, 1))
        #expect(abs((Double(c.killY!)) - (27 - 26 / 1.08)) <= 1e-9)
        #expect(R.curve(pts, lineAt: nil, rect: rect, now: now, span: 300_000).killY == nil)
        #expect(R.curve(Array(pts[3...]), lineAt: nil, rect: rect, now: now, span: 300_000).line.isEmpty)
        #expect(try R.curveSpan(R.decode(day())) == 300_000)
    }
}

/// Both sides one type, so that a literal takes the other side's -- what
/// XCTAssertEqual's one generic parameter did.
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
