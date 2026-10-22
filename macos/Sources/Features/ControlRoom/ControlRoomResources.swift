import Foundation
import CoreGraphics

/// The performance page's data and where its parts go (task 2015, Q7;
/// `polter-artifacts/2015/API.md` §2.1, ui-v4): the core's answer to a
/// `resources` request, read; each card's curve kept between answers; and
/// the page's geometry -- the same numbers as the Windows host's
/// `perf_scene`, from the same look keys.
///
/// **Every word is the core's**, already in the person's language; the
/// numbers that come with them are only for the arc, the curve and the
/// grid. A tone, a span or a row this build cannot read fails the decode.
/// No SwiftUI here: what can be wrong without looking wrong is tested in a
/// package of its own.
enum ControlRoomResources {
    typealias Level = ControlRoomResourceLevel

    enum Span: String, Decodable, Equatable {
        case day, week
    }

    /// Words in a tone; the tone nil where the core gives none.
    struct Toned: Decodable, Equatable {
        var tone: Level?
        var text: String
    }

    struct Machine: Decodable, Equatable {
        struct Text: Decodable, Equatable {
            /// "整机", before the reading; nil when the core writes none.
            var label: String?
            /// Nil when the core could not read it (API.md §2.0): not drawn.
            /// Every field §2.0's table lets be null is optional here, and an
            /// optional takes the key null or left out alike.
            var mem: String?
            var mem_of: String?
            /// Nil when the core has none to say -- the Windows core reads
            /// no swap (group seq 274) -- the key left out or null: that
            /// item is not drawn, and the rest of the page is (group seq
            /// 276: a missing field one item needs never empties the page).
            var swap: String?
            /// Nil when it could not be read: not drawn at all.
            var pressure: String?
            var panes: String
            var day: String
        }
        var text: Text
        var pressure_tone: Level?
    }

    struct Cell: Decodable, Equatable {
        var cell: Int
        var text: String
    }

    struct Hover: Decodable, Equatable {
        var cell: Int
        var lines: [Toned]
    }

    /// One terminal's line of cells (API.md calls them `panes`: they are
    /// terminals, not the control room's rows).
    struct Pane: Decodable, Equatable {
        var id: String
        var name: String
        var cells: [Level]
        var hover: [Hover]
    }

    struct SpanWords: Decodable, Equatable {
        var span: Span
        var text: String
    }

    struct Legend: Decodable, Equatable {
        var tone: Level
        var text: String
    }

    struct Grid: Decodable, Equatable {
        var span: Span
        var title: String
        var subtitle: String
        /// The two buttons; empty from a core that writes none.
        var spans: [SpanWords]?
        var legend: [Legend]
        var cells: Int
        var axis: [Cell]
        var panes: [Pane]
    }

    struct Dial: Decodable, Equatable {
        /// 0 and up; past 1 is drawn as 1.
        var fraction: Double
        /// The warnings' places on the arc, first warning first.
        var ticks: [Double]
        var big: String
        var unit: String
        var cap: String
    }

    struct Lines: Decodable, Equatable {
        struct Usage: Decodable, Equatable {
            var value: String
            var rest: String
        }
        /// Nil before the pane's first reading (API.md §2.0).
        var r1: Usage?
        var r2: Toned?
        var r3: Toned?
    }

    struct Foot: Decodable, Equatable {
        var left: String
        var right: String
    }

    struct Card: Decodable, Equatable {
        var id: String
        var name: String
        var role: String?
        var badge: Toned?
        var tone: Level
        var dial: Dial
        var lines: Lines
        var foot: Foot
        /// The kill line in bytes; nil when unset.
        var line_at: UInt64?
        /// `[ms, bytes]`: all of them in a `full` answer, the new ones
        /// otherwise (`Curves`).
        var points: [[UInt64]]
    }

    struct Answer: Decodable, Equatable {
        var group: String
        /// The next request's `since`.
        var seq: UInt64
        var full: Bool
        var period_ms: UInt64
        var now_ms: UInt64
        var machine: Machine
        var now_line: String
        var now_note: String
        var grid: Grid
        var cards: [Card]
    }

    enum DecodeError: Error, Equatable {
        /// The core's own refusal: never an empty page.
        case refused(String)
        /// A pane with not exactly `grid.cells` cells, or a point that is
        /// not `[ms, bytes]`: it would be drawn against the wrong times.
        case shape(String)
    }

    /// The answer, read.
    static func decode(_ data: Data) throws -> Answer {
        struct Refusal: Decodable { var error: String }
        if let refusal = try? JSONDecoder().decode(Refusal.self, from: data) {
            throw DecodeError.refused(refusal.error)
        }
        let a = try JSONDecoder().decode(Answer.self, from: data)
        for pane in a.grid.panes where pane.cells.count != a.grid.cells {
            throw DecodeError.shape("grid.panes[\(pane.id)].cells")
        }
        for card in a.cards where card.points.contains(where: { $0.count != 2 }) {
            throw DecodeError.shape("cards[\(card.id)].points")
        }
        return a
    }

    /// The request for `group`'s page: `since` the last answer's `seq`, 0
    /// the first time.
    static func request(group: String, span: Span, since: UInt64) -> String {
        let quoted = ControlRoomPageRequest.quoted(group)
        return "{\"page\":\"resources\",\"group\":\(quoted),\"span\":\"\(span.rawValue)\",\"since\":\(since)}"
    }

    /// The most points a card keeps: five minutes at one every two seconds.
    static let keptPoints = 150

    /// Each card's curve, kept between answers: a full answer replaces them
    /// all, a later one adds to the end, a card no longer there is
    /// forgotten, and past `keptPoints` the oldest go.
    struct Curves: Equatable {
        private(set) var byID: [String: [(UInt64, UInt64)]] = [:]
        /// The `since` of the next request.
        private(set) var since: UInt64 = 0

        static func == (a: Curves, b: Curves) -> Bool {
            a.since == b.since && a.byID.keys == b.byID.keys
                && a.byID.allSatisfy { k, v in b.byID[k].map { $0.elementsEqual(v, by: ==) } ?? false }
        }

        mutating func take(_ a: Answer) {
            var next: [String: [(UInt64, UInt64)]] = [:]
            for card in a.cards {
                var pts = a.full ? [] : (byID[card.id] ?? [])
                pts += card.points.map { ($0[0], $0[1]) }
                if pts.count > keptPoints { pts.removeFirst(pts.count - keptPoints) }
                next[card.id] = pts
            }
            byID = next
            since = a.seq
        }

        func points(_ id: String) -> [(UInt64, UInt64)] { byID[id] ?? [] }
    }

    /// How long the curve shows: as many periods as a card keeps points.
    static func curveSpan(_ a: Answer) -> UInt64 { UInt64(keptPoints) * a.period_ms }

    /// The last `spanMs` of `points` in `rect`: the line's points, and the
    /// kill line's height. The top of the scale is a little over the kill
    /// line, or twice and more the highest point when there is none.
    static func curve(_ points: [(UInt64, UInt64)], lineAt: UInt64?, rect: CGRect, nowMs: UInt64, spanMs: UInt64)
        -> (line: [CGPoint], killY: CGFloat?) {
        let span = max(spanMs, 1)
        let start = nowMs >= span ? nowMs - span : 0
        let shown = points.filter { $0.0 >= start && $0.0 <= nowMs }
        let highest = Double(shown.map(\.1).max() ?? 0)
        let top = lineAt.map { Double($0) * 1.08 } ?? max(highest * 2.2, 1)
        // Saturating: a point from before the window is at its left edge, never a wrapped number.
        let x = { (t: UInt64) in rect.minX + CGFloat(Double(t >= start ? t - start : 0) / Double(span)) * rect.width }
        let y = { (v: Double) in rect.minY + rect.height - 1 - (rect.height - 2) * CGFloat(min(v, top) / top) }
        let line = shown.count >= 2 ? shown.map { CGPoint(x: x($0.0), y: y(Double($0.1))) } : []
        return (line, lineAt.map { y(Double($0)) })
    }
}

/// Where the performance page's parts go, from its top left, scrolled up
/// by `scroll` (`perf_scene::layout` on Windows: the same numbers).
struct ControlRoomPerfLayout: Equatable {
    typealias Card = ControlRoomLook.PerfCard
    typealias Grid = ControlRoomLook.PerfGrid
    typealias Page = ControlRoomLook.PerfPage

    var summary: CGRect
    /// The machine's line, inside it.
    var top: CGRect
    var gridHead: CGRect
    var labelX: CGFloat
    var cellsX: CGFloat
    var rowsTop: CGFloat
    var panes: Int
    var span: ControlRoomResources.Span
    var cells: Cells
    var axis: CGRect
    var cardsHead: CGRect
    var cards: [CGRect]
    /// How tall the page is, unscrolled.
    var contentHeight: CGFloat

    /// How many cards stand side by side in `inner` points: as many whole
    /// cards as fit with `between` between them, and never none.
    static func columns(_ inner: CGFloat) -> Int {
        max(Int(((inner + CGFloat(Card.between)) / (CGFloat(Card.width) + CGFloat(Card.between))).rounded(.down)), 1)
    }

    /// **Not in the look yet**: the least a cell and the gap between two are
    /// scaled to (group seq 223, the supervisor's numbers).
    enum Pending {
        static let minCell: CGFloat = 8
        static let minCellGap: CGFloat = 2
    }

    /// How the history's cells stand in the room the overview has for them
    /// (`perf_scene::Cells` on Windows, the same rule): at the look's size
    /// when they fit; scaled down together, square, no smaller than
    /// `Pending.minCell` when they do not; and when even that is too wide,
    /// the newest that fit, against the right end, from `first`.
    struct Cells: Equatable {
        var size: CGFloat
        var gap: CGFloat
        var groupGap: CGFloat
        var first: Int
        var count: Int
        var span: ControlRoomResources.Span
        /// Where the first drawn cell's left edge is, from the room's left.
        var lead: CGFloat

        static func daysBetween(_ span: ControlRoomResources.Span, _ a: Int, _ b: Int) -> Int {
            span == .week ? b / Int(Grid.dayGroup) - a / Int(Grid.dayGroup) : 0
        }

        static func width(_ span: ControlRoomResources.Span, count: Int, from: Int, size: CGFloat, gap: CGFloat, groupGap: CGFloat) -> CGFloat {
            guard count > 0, from < count else { return 0 }
            let n = CGFloat(count - from)
            return n * size + (n - 1) * gap + CGFloat(daysBetween(span, from, count - 1)) * groupGap
        }

        static func fit(_ span: ControlRoomResources.Span, count: Int, room: CGFloat) -> Cells {
            let full = width(span, count: count, from: 0, size: CGFloat(Grid.cell), gap: CGFloat(Grid.cellGap), groupGap: CGFloat(Grid.groupGap))
            var size = CGFloat(Grid.cell), gap = CGFloat(Grid.cellGap), groupGap = CGFloat(Grid.groupGap)
            if full > room, full > 0 {
                let k = room / full
                size = max(size * k, Pending.minCell)
                gap = max(gap * k, Pending.minCellGap)
                groupGap = max(groupGap * k, Pending.minCellGap)
            }
            var first = 0
            while first + 1 < count && width(span, count: count, from: first, size: size, gap: gap, groupGap: groupGap) > room + 1e-9 {
                first += 1
            }
            let lead = first > 0 ? max(room - width(span, count: count, from: first, size: size, gap: gap, groupGap: groupGap), 0) : 0
            return Cells(size: size, gap: gap, groupGap: groupGap, first: first, count: count, span: span, lead: lead)
        }

        /// How many are drawn, and in how many days a week's are: what the
        /// page drew, for the line `ControlRoomPerfFeed` writes.
        var drawn: Int { max(count - first, 0) }
        var groups: Int {
            guard drawn > 0 else { return 0 }
            return span == .week ? Self.daysBetween(span, first, count - 1) + 1 : 1
        }

        /// The left of `cell` from the room's left; nil for one before
        /// `first`, which is not drawn.
        func offset(_ cell: Int) -> CGFloat? {
            guard cell >= first, cell < count else { return nil }
            return lead + CGFloat(cell - first) * (size + gap) + CGFloat(Self.daysBetween(span, first, cell)) * groupGap
        }
    }

    init(_ a: ControlRoomResources.Answer, width: CGFloat, scroll: CGFloat = 0) {
        let x0 = CGFloat(Page.padding)
        let inner = max(width - 2 * CGFloat(Page.padding), 0)
        let y0 = CGFloat(Page.padding) - scroll
        top = CGRect(x: x0 + CGFloat(Page.summaryPadX), y: y0 + CGFloat(Page.summaryPadY),
                     width: max(inner - 2 * CGFloat(Page.summaryPadX), 0), height: CGFloat(Page.machineHeight))
        gridHead = CGRect(x: top.minX, y: top.maxY + CGFloat(Page.summaryLayerGap), width: top.width, height: CGFloat(Grid.headHeight))
        rowsTop = gridHead.maxY + CGFloat(Grid.rowsTop)
        panes = a.grid.panes.count
        let n = CGFloat(panes)
        let rowsH = panes == 0 ? 0 : n * CGFloat(Grid.rowHeight) + (n - 1) * CGFloat(Grid.rowGap)
        axis = CGRect(x: top.minX, y: rowsTop + rowsH + CGFloat(Grid.axisGap), width: top.width, height: CGFloat(Grid.axisHeight))
        summary = CGRect(x: x0, y: y0, width: inner, height: axis.maxY + CGFloat(Page.summaryPadY) - y0)
        cardsHead = CGRect(x: x0 + CGFloat(Page.cardsTitleInset), y: summary.maxY + CGFloat(Page.cardsTitleTop),
                           width: max(inner - 2 * CGFloat(Page.cardsTitleInset), 0), height: CGFloat(Page.cardsTitleHeight))
        let cardsTop = cardsHead.maxY + CGFloat(Page.cardsTop)
        let cols = Self.columns(inner)
        let step = (x: CGFloat(Card.width + Card.between), y: CGFloat(Card.height + Card.between))
        cards = a.cards.indices.map { i in
            CGRect(x: x0 + CGFloat(i % cols) * step.x, y: cardsTop + CGFloat(i / cols) * step.y,
                   width: CGFloat(Card.width), height: CGFloat(Card.height))
        }
        labelX = top.minX
        cellsX = top.minX + CGFloat(Grid.labelWidth + Grid.labelGap)
        span = a.grid.span
        cells = Cells.fit(a.grid.span, count: a.grid.cells, room: max(top.width - CGFloat(Grid.labelWidth + Grid.labelGap), 0))
        contentHeight = (cards.last?.maxY ?? cardsTop) + CGFloat(Page.padding) + scroll
    }

    func maxScroll(_ height: CGFloat) -> CGFloat { max(contentHeight - height, 0) }

    /// The machine's line in the order it is drawn.
    enum MachineItem: Int, CaseIterable {
        case label, mem, swap, pressure, panes, day
    }

    /// **Which go first when the line is too narrow** (group seq 263: not
    /// every item cut to "…"): the day, the terminals, the swap, the label,
    /// the pressure. The memory never goes. The Windows host's
    /// `perf_scene::machine_item::DROP_ORDER`.
    static let machineDropOrder: [MachineItem] = [.day, .panes, .swap, .label, .pressure]

    /// The machine's line as it can be drawn, the fullest first: those of
    /// `present` that stay as each in `machineDropOrder` goes in turn. The
    /// page draws the first that fits whole (`ViewThatFits`), which is
    /// `perf_scene::keep_by_priority` measured by SwiftUI.
    static func machineVariants(present: Set<MachineItem>) -> [[MachineItem]] {
        var kept = MachineItem.allCases.filter { present.contains($0) || $0 == .mem }
        var out = [kept]
        for item in machineDropOrder where kept.contains(item) {
            kept.removeAll { $0 == item }
            out.append(kept)
        }
        return out
    }

    /// Where the axis's words go, or nil for one left out: `marks[i]` is a
    /// drawn cell's left edge and its word's width, in order. The first word
    /// starts at its cell's left, the last ends at its cell's right, the rest
    /// are centred on theirs -- and **one that would come nearer than `gap`
    /// to another is not drawn** (group seq 263: "昨天…" lay over "06:00").
    /// The last ("now") is placed first, then the first, then the rest from
    /// the left. The Windows host's `perf_scene::axis_places`.
    static func axisPlaces(_ marks: [(left: CGFloat, width: CGFloat)], size: CGFloat, gap: CGFloat) -> [CGFloat?] {
        let n = marks.count
        func want(_ i: Int) -> CGFloat {
            let (left, w) = marks[i]
            if i == n - 1 && n > 1 { return left + size - w }
            if i == 0 { return left }
            return left + size / 2 - w / 2
        }
        var placed = [CGFloat?](repeating: nil, count: n)
        let order = n > 0 ? [n - 1] + Array(0..<(n - 1)) : []
        for i in order {
            let x = want(i), w = marks[i].width
            let clear = placed.indices.allSatisfy { j in
                guard let xj = placed[j] else { return true }
                return x + w + gap <= xj + 1e-9 || xj + marks[j].width + gap <= x + 1e-9
            }
            if clear { placed[i] = x }
        }
        return placed
    }

    func rowRect(_ row: Int) -> CGRect {
        CGRect(x: labelX, y: rowsTop + CGFloat(row) * CGFloat(Grid.rowHeight + Grid.rowGap),
               width: CGFloat(Grid.labelWidth), height: CGFloat(Grid.rowHeight))
    }

    /// One cell: square, in the middle of its row's height; nil for one
    /// before the first drawn (`Cells`).
    func cellRect(_ row: Int, _ cell: Int) -> CGRect? {
        let r = rowRect(row)
        guard let dx = cells.offset(cell) else { return nil }
        return CGRect(x: cellsX + dx, y: r.minY + (CGFloat(Grid.rowHeight) - cells.size) / 2, width: cells.size, height: cells.size)
    }

    /// Every cell the grid draws, row by row: what the canvas draws and
    /// what the page's log line counts, from one place (task 2039 round 4,
    /// group seq 289: the line said 42 cells in 7 days, the screen showed
    /// 48 in none).
    func drawnCells() -> [(row: Int, cell: Int, rect: CGRect)] {
        var out: [(row: Int, cell: Int, rect: CGRect)] = []
        for row in 0..<panes {
            for cell in cells.first..<max(cells.count, cells.first) {
                if let r = cellRect(row, cell) { out.append((row, cell, r)) }
            }
        }
        return out
    }

    /// How many columns `rects` stand in, and in how many groups: a gap
    /// wider than the cells' own starts another. Counted off the rectangles,
    /// not off `Cells`, so that the two can be held against each other.
    static func columnsAndGroups(_ rects: [CGRect], gap: CGFloat) -> (columns: Int, groups: Int) {
        var xs: [CGFloat] = []
        for r in rects where !xs.contains(where: { abs($0 - r.minX) < 0.01 }) { xs.append(r.minX) }
        xs = xs.reduce(into: []) { acc, x in
            let at = acc.firstIndex { $0 > x } ?? acc.count
            acc.insert(x, at: at)
        }
        guard let size = rects.first?.width, !xs.isEmpty else { return (0, 0) }
        var groups = 1
        for (a, b) in zip(xs, xs.dropFirst()) where b - a - size > gap + 0.01 { groups += 1 }
        return (xs.count, groups)
    }

    /// The cell under `point`, as `(row, cell)`: only a drawn one.
    func cell(at point: CGPoint, cells _: Int) -> (row: Int, cell: Int)? {
        for row in 0..<panes {
            for c in cells.first..<max(cells.count, cells.first) {
                guard let r = cellRect(row, c) else { continue }
                if point.x >= r.minX && point.x < r.maxX && point.y >= r.minY && point.y < r.maxY { return (row, c) }
            }
        }
        return nil
    }

    /// Where a card's parts go, from its rect (ui-v4's grid).
    struct CardGrid: Equatable {
        var head: CGRect
        var dial: CGRect
        var cap: CGRect
        var r1: CGRect
        var r2: CGRect
        var r3: CGRect
        var r4: CGRect
        var foot: CGRect
    }

    static func cardGrid(_ card: CGRect) -> CardGrid {
        let x = card.minX + CGFloat(Card.padX)
        let inner = CGFloat(Card.width - 2 * Card.padX)
        let head = CGRect(x: x, y: card.minY + CGFloat(Card.padY), width: inner, height: CGFloat(Card.head))
        let body = head.maxY + CGFloat(Card.gap)
        let col = x + CGFloat(Card.dial + Card.dialGap)
        let row = { (y: CGFloat, h: Double) in CGRect(x: col, y: y, width: CGFloat(Card.column), height: CGFloat(h)) }
        let r1 = row(body, Card.row1)
        let r2 = row(r1.maxY + CGFloat(Card.rowGap), Card.row2)
        let r3 = row(r2.maxY + CGFloat(Card.rowGap), Card.row3)
        let r4 = row(r3.maxY + CGFloat(Card.rowGap), Card.row4)
        return CardGrid(head: head,
                        dial: CGRect(x: x, y: body, width: CGFloat(Card.dial), height: CGFloat(Card.dial)),
                        cap: CGRect(x: x, y: body + CGFloat(Card.dialCapTop), width: CGFloat(Card.dial), height: CGFloat(Card.dialCapHeight)),
                        r1: r1, r2: r2, r3: r3, r4: r4,
                        foot: CGRect(x: x, y: body + CGFloat(Card.body + Card.gap), width: inner, height: CGFloat(Card.foot)))
    }

    /// The tip about `(row, cell)` with `lines` lines `width` wide: at the
    /// cell's left, `tipOffset` from it, its first line level with the cell.
    func tipRect(row: Int, cell: Int, lines: Int, width: CGFloat) -> CGRect? {
        guard let c = cellRect(row, cell) else { return nil }
        let w = width + 2 * CGFloat(Grid.tipPadX)
        let h = CGFloat(lines) * CGFloat(Grid.tipLineHeight) + 2 * CGFloat(Grid.tipPadY)
        let x = max(c.minX - CGFloat(Grid.tipOffset) - w, CGFloat(Page.padding))
        let y = c.midY - CGFloat(Grid.tipLineHeight) / 2 - CGFloat(Grid.tipPadY)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A point on the dial's circle, `degrees` clockwise from three o'clock
    /// on a screen (y down).
    static func onCircle(_ centre: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(cos(a)), y: centre.y + radius * CGFloat(sin(a)))
    }
}

/// What the pages' requests to the core are made of (task 2015, API.md).
enum ControlRoomPageRequest {
    /// `s` as a JSON string, quotes included: the group's name inside a
    /// request. Written out rather than through `JSONEncoder`, whose
    /// `throws` a string can never reach and SwiftLint will not let be
    /// forced.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
