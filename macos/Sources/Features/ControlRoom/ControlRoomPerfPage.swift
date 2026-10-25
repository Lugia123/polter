import GhosttyKit
import SwiftUI

/// What the right side's pages ask the core (task 2015, API.md §2):
/// `ghostty_app_control_page`, a JSON request answered in JSON, by the
/// persona buffer rule -- asked twice with the same request, the second
/// answer is the first one's bytes.
///
/// **For a test machine only**: while the core answers nothing (0, its
/// "not ready" -- which is all it answers until Q3 and Q4 are in), the
/// file `POLTER_TEST_RESOURCES_JSON` or `POLTER_TEST_TASKS_JSON` names is
/// read instead, said to be about the group asked for. The Windows host
/// does the same (`control_room_source::test_answer`). With an answer from
/// the core, neither is read.
struct ControlRoomPageSource {
    enum Failure: Error, Equatable {
        case notReady
        case unreadable(String)
    }

    var ask: (String) -> Result<String, Failure>

    static let none = ControlRoomPageSource { _ in .failure(.notReady) }

    static func core(_ ghostty: Ghostty.App) -> ControlRoomPageSource {
        ControlRoomPageSource { [weak ghostty] request in
            guard let app = ghostty?.app else { return .failure(.notReady) }
            let bytes = Array(request.utf8CString.dropLast())
            let need = bytes.withUnsafeBufferPointer { req in
                Int(ghostty_app_control_page(app, req.baseAddress, UInt(req.count), nil, 0))
            }
            guard need > 0 else { return testAnswer(request) }
            var buffer = [CChar](repeating: 0, count: need + 1)
            let wrote = bytes.withUnsafeBufferPointer { req in
                buffer.withUnsafeMutableBufferPointer { out in
                    Int(ghostty_app_control_page(app, req.baseAddress, UInt(req.count), out.baseAddress, UInt(out.count)))
                }
            }
            guard wrote > 0, wrote <= need else { return .failure(.unreadable("it changed size between asking and reading")) }
            guard let text = String(bytes: buffer.prefix(wrote).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                return .failure(.unreadable("the answer is not UTF-8"))
            }
            return .success(text)
        }
    }

    private static var said: Set<String> = []

    /// The fake answer, when a variable names one; not ready otherwise.
    static func testAnswer(_ request: String) -> Result<String, Failure> {
        let variable: String
        if request.contains("\"page\":\"resources\"") {
            variable = "POLTER_TEST_RESOURCES_JSON"
        } else if request.contains("\"page\":\"tasks\"") {
            variable = "POLTER_TEST_TASKS_JSON"
        } else {
            return .failure(.notReady)
        }
        guard let path = ProcessInfo.processInfo.environment[variable] else { return .failure(.notReady) }
        if !said.contains(variable) {
            said.insert(variable)
            Ghostty.logger.notice("control room: the core answers nothing; a page is reading \(path, privacy: .public) (\(variable, privacy: .public)); said once")
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure(.unreadable("\(variable): cannot read \(path)"))
        }
        // The fake answers are about a group called web-app.
        struct Asked: Decodable { var group: String }
        guard let asked = try? JSONDecoder().decode(Asked.self, from: Data(request.utf8)),
              let quoted = String(data: (try? JSONEncoder().encode(asked.group)) ?? Data(), encoding: .utf8) else {
            return .failure(.unreadable("BadRequest"))
        }
        let replaced = text.replacingOccurrences(of: "\"group\": \"web-app\"", with: "\"group\": \(quoted)",
                                                 range: text.range(of: "\"group\": \"web-app\""))
        return .success(replaced)
    }
}

/// The same door in the spelling `ControlRoomOverall` can compile against
/// (task 2149): that type and the row that draws it are built into
/// `tools/mac-logic-tests` as well as into the application
/// (`tools/mac-logic-tests.json`), and this file names `GhosttyKit`, so the
/// two cannot share a type. The three outcomes stay three: **"nothing yet"
/// is not a refusal**, and only the refusal is worth writing down.
extension ControlRoomPageSource {
    var overallAsk: ControlRoomOverall.Ask {
        { request in
            switch ask(request) {
            case let .success(text): return .answer(text)
            case .failure(.notReady): return .notReady
            case let .failure(.unreadable(why)): return .refused(why)
            }
        }
    }
}

/// The performance page's answers for one group, asked every `period_ms`
/// while the page is in front and the application is active (API.md
/// §2.1), and nothing asked otherwise.
final class ControlRoomPerfFeed: ObservableObject {
    typealias Res = ControlRoomResources

    @Published private(set) var answer: Res.Answer?
    @Published private(set) var curves = Res.Curves()
    @Published var span: Res.Span = .day
    @Published var hovered: (row: Int, cell: Int)?

    private var group: String?
    private var timer: Timer?
    private var period: TimeInterval = 2
    private var said: String?
    /// The page's width, for what it draws of an answer (`drewLine`).
    var width: CGFloat = 0
    /// The last `drewLine` written; another is written when it differs.
    private var drew: String?
    /// What the canvas last said it drew (`canvasDrew`).
    private var canvasSaid: String?
    /// What the last answer lacked, as last said.
    private var saidMissing: [String] = []
    let source: ControlRoomPageSource

    init(source: ControlRoomPageSource) {
        self.source = source
    }

    /// Start asking for `group`'s page: from nothing when it is another
    /// group's or another span's.
    func start(group: String) {
        if self.group != group {
            self.group = group
            answer = nil
            curves = Res.Curves()
            hovered = nil
        }
        drew = nil
        arm(period)
        Ghostty.logger.notice("control room: performance page of \(group, privacy: .public) in front; asking every \(self.period)s")
        fetch()
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        Ghostty.logger.notice("control room: performance page out of sight; its timer is stopped")
    }

    func pick(_ span: Res.Span) {
        guard span != self.span else { return }
        self.span = span
        answer = nil
        curves = Res.Curves()
        hovered = nil
        drew = nil
        fetch()
    }

    /// `grid.span`, `grid.cells` and the first terminal's cell count as the
    /// core sent them, and the cells and days drawn of them at `width`.
    static func drewLine(_ a: Res.Answer, width: CGFloat) -> String {
        let cells = ControlRoomPerfLayout(a, width: width).cells
        let first = a.grid.panes.first.map { "\($0.cells.count)" } ?? "none"
        return "answer span=\(a.grid.span.rawValue) cells=\(a.grid.cells) first pane=\(first); "
            + "drew \(cells.drawn) cells from \(cells.first) in \(cells.groups) group(s), \(Int(cells.size)) pt at width \(Int(width))"
    }

    /// The grid's canvas drew `columns` columns in `groups` groups for the
    /// layout `key`: said when it changes, beside `drewLine`, so that what
    /// was worked out and what was drawn can be read against each other.
    func canvasDrew(_ key: String, _ counted: (columns: Int, groups: Int)) {
        let line = "canvas drew \(counted.columns) columns in \(counted.groups) group(s) (\(key))"
        guard line != canvasSaid else { return }
        canvasSaid = line
        Ghostty.logger.notice("control room: performance page: \(line, privacy: .public)")
    }

    private func arm(_ seconds: TimeInterval) {
        if timer != nil, seconds == period { return }
        period = seconds
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.fetch() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fetch() {
        guard let group, NSApp.isActive else { return }
        let request = Res.request(group: group, span: span, since: curves.since)
        let result = source.ask(request).flatMap { text -> Result<Res.Answer, ControlRoomPageSource.Failure> in
            do { return .success(try Res.decode(Data(text.utf8))) } catch { return .failure(.unreadable("\(error)")) }
        }
        switch result {
        case let .success(a) where a.group == group:
            curves.take(a)
            answer = a
            said = nil
            // What the core left out, said when it changes (group seq 309):
            // those items are not drawn, and the rest is.
            if a.missing != saidMissing {
                if !a.missing.isEmpty {
                    Ghostty.logger.notice("control room: performance page of \(group, privacy: .public): the answer is missing \(ControlRoomAnswerReader.words(a.missing), privacy: .public); those are not drawn")
                }
                saidMissing = a.missing
            }
            // What the core said of the grid and what the page drew of it
            // (group seq 264, 265: a week drawn as 48 ungrouped cells --
            // the core's or the host's?). When it changes, and after each
            // start or span picked: every answer would be a line every two
            // seconds saying the same.
            let line = Self.drewLine(a, width: width)
            if line != drew {
                drew = line
                Ghostty.logger.notice("control room: performance page of \(group, privacy: .public): \(line, privacy: .public)")
            }
            let seconds = max(TimeInterval(a.period_ms) / 1000, 0.25)
            if seconds != period { arm(seconds) }
        case .success:
            // About another group: the selection moved between asking and now.
            break
        case let .failure(why):
            let words = "\(why)"
            if said != words {
                said = words
                Ghostty.logger.notice("control room: performance page of \(group, privacy: .public): no answer (\(words, privacy: .public))")
            }
        }
    }
}

/// The performance page (ui-v4): the overview -- the machine's line, the
/// span buttons, the history grid with its legend and axis -- and a card a
/// terminal. Every word is the core's; where things go is
/// `ControlRoomPerfLayout`, the Windows host's numbers.
struct ControlRoomPerfPage: View {
    typealias Look = ControlRoomLook
    typealias Res = ControlRoomResources
    typealias PerfLayout = ControlRoomPerfLayout
    typealias Card = Look.PerfCard
    typealias Grid = Look.PerfGrid
    typealias Page = Look.PerfPage

    var group: String
    @StateObject private var feed: ControlRoomPerfFeed
    /// The group's own cost, split four ways (task 2149, handoff §6): the
    /// same `overall` page the left panel's bottom line reads, this one
    /// asked about the group the page is showing. **A second reader of one
    /// page**, not a second page: both draw `ControlRoomOverall.decode` of
    /// the core's one reading.
    @StateObject private var overall: ControlRoomOverallFeed
    /// Whether this page has that strip at all: no door to the core, no
    /// strip, and the cards stand where they did.
    private let showsStrip: Bool

    @Environment(\.colorScheme) private var scheme

    init(group: String, source: ControlRoomPageSource, overallAsk: ControlRoomOverall.Ask? = nil) {
        self.group = group
        _feed = StateObject(wrappedValue: ControlRoomPerfFeed(source: source))
        _overall = StateObject(wrappedValue: ControlRoomOverallFeed(ask: overallAsk ?? { _ in .notReady }))
        self.showsStrip = overallAsk != nil
    }

    /// The group this page's strip is about, from the overall reading: nil
    /// while there is none, and nil for an answer that is not about this
    /// group -- a selection that moved between asking and now.
    private var stripGroup: ControlRoomOverall.Group? {
        overall.answer.flatMap { ControlRoomOverall.group($0, named: group) }
    }

    private var stripHeight: CGFloat { stripGroup == nil ? 0 : ControlRoomOverall.groupStripHeight }

    var body: some View {
        let theme = Look.theme(scheme)
        GeometryReader { proxy in
            ScrollView(.vertical) {
                if let a = feed.answer {
                    let at = PerfLayout(a, width: proxy.size.width, stripHeight: stripHeight)
                    content(a, at: at, theme: theme)
                        .frame(width: proxy.size.width, height: at.contentHeight, alignment: .topLeading)
                } else {
                    Color.clear.frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .onAppear { feed.width = proxy.size.width }
            .onChange(of: proxy.size.width) { feed.width = $0 }
        }
        .background(theme.terminalBackground.color)
        .onAppear {
            feed.start(group: group)
            if showsStrip {
                overall.request = ControlRoomOverall.groupRequest(group: group)
                overall.start()
            }
        }
        .onDisappear {
            feed.stop()
            overall.stop()
        }
        .onChange(of: group) {
            feed.start(group: $0)
            guard showsStrip else { return }
            overall.request = ControlRoomOverall.groupRequest(group: $0)
            overall.start()
        }
    }

    @ViewBuilder
    private func content(_ a: Res.Answer, at: PerfLayout, theme: Look.Theme) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: CGFloat(Card.radiusMac), style: .continuous)
                .fill(theme.perfCard.color)
                .overlay(RoundedRectangle(cornerRadius: CGFloat(Card.radiusMac), style: .continuous)
                    .strokeBorder(theme.perfCardEdge.color, lineWidth: CGFloat(Look.Line.hairline)))
                .frame(width: at.summary.width, height: at.summary.height)
                .offset(x: at.summary.minX, y: at.summary.minY)
            machine(a, theme: theme)
                .frame(width: at.top.width, height: at.top.height)
                .offset(x: at.top.minX, y: at.top.minY)
            gridHead(a, theme: theme)
                .frame(width: at.gridHead.width, height: at.gridHead.height)
                .offset(x: at.gridHead.minX, y: at.gridHead.minY)
            ForEach(Array(a.grid.panes.enumerated()), id: \.offset) { i, pane in
                let r = at.rowRect(i)
                Text(pane.name)
                    .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                    .foregroundStyle(feed.hovered?.row == i ? theme.text.color : theme.textSecondary.color)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: r.width, height: r.height, alignment: .leading)
                    .offset(x: r.minX, y: r.minY)
            }
            cells(a, at: at, theme: theme)
            // Only the words of drawn cells, on the same cells' places, and
            // none nearer another than the label gap (`axisPlaces`).
            let marks = a.grid.axis.filter { at.cells.offset($0.cell) != nil }
            let face = SafeFace(size: CGFloat(Look.Font.body))
            let widths = marks.map { (left: at.cellsX + (at.cells.offset($0.cell) ?? 0), width: SafeTextMeasure.width($0.text, in: face).rounded(.up)) }
            let places = PerfLayout.axisPlaces(widths, size: at.cells.size, gap: CGFloat(Grid.labelGap))
            ForEach(Array(marks.enumerated()), id: \.offset) { i, mark in
                if let x = places[i] {
                    Text(mark.text)
                        .foregroundStyle(theme.textTertiary.color)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: at.axis.height)
                        .offset(x: x, y: at.axis.minY)
                }
            }
            // The line over the cards: the note on the right goes first when
            // the two do not fit whole (group seq 289, as the machine's
            // line). The line itself is one string of the core's; only it
            // left, and still too long, it is cut.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(a.now_line).fixedSize()
                    Spacer(minLength: CGFloat(Page.machineItemGap))
                    Text(a.now_note).fixedSize()
                }
                Text(a.now_line).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .frame(width: at.cardsHead.width, height: at.cardsHead.height)
            .offset(x: at.cardsHead.minX, y: at.cardsHead.minY)
            // The group's own cost, split four ways, between the box above
            // and the cards below (task 2149, handoff §6). **Drawn only when
            // the overall answer carries this group**, so a page whose core
            // has nothing yet looks exactly as it did.
            if let strip = at.strip, let g = stripGroup {
                ControlRoomGroupOwnRow(group: g)
                    .frame(width: strip.width, height: strip.height)
                    .offset(x: strip.minX, y: strip.minY)
            }
            ForEach(Array(zip(a.cards, at.cards).enumerated()), id: \.offset) { _, pair in
                ControlRoomPerfCard(card: pair.0, points: feed.curves.points(pair.0.id), nowMs: a.now_ms,
                                    spanMs: Res.curveSpan(a), theme: theme)
                    .frame(width: pair.1.width, height: pair.1.height)
                    .offset(x: pair.1.minX, y: pair.1.minY)
            }
            if let h = feed.hovered, let lines = a.grid.panes[safe: h.row]?.hover.first(where: { $0.cell == h.cell })?.lines,
               at.cellRect(h.row, h.cell) != nil {
                tip(lines, at: at, row: h.row, cell: h.cell, theme: theme)
            }
        }
        .font(.system(size: CGFloat(Look.Font.body)))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(point):
                let cell = at.cell(at: point, cells: a.grid.cells)
                if cell?.row != feed.hovered?.row || cell?.cell != feed.hovered?.cell { feed.hovered = cell }
            case .ended:
                if feed.hovered != nil { feed.hovered = nil }
            }
        }
    }

    /// The machine's line, and the span buttons at its right end.
    private func machine(_ a: Res.Answer, theme: Look.Theme) -> some View {
        let m = a.machine.text
        let gap = CGFloat(Page.machineItemGap)
        var present: Set<PerfLayout.MachineItem> = [.mem]
        if !(m.label ?? "").isEmpty { present.insert(.label) }
        if !(m.swap ?? "").isEmpty { present.insert(.swap) }
        if !(m.pressure ?? "").isEmpty { present.insert(.pressure) }
        if !m.panes.isEmpty { present.insert(.panes) }
        if !m.day.isEmpty { present.insert(.day) }
        return HStack(spacing: 0) {
            // As many items as fit, each whole (`machineVariants`).
            ViewThatFits(in: .horizontal) {
                ForEach(Array(PerfLayout.machineVariants(present: present).enumerated()), id: \.offset) { _, kept in
                    machineItems(a, kept: kept, theme: theme)
                }
            }
            Spacer(minLength: gap)
            HStack(spacing: CGFloat(Page.segGap)) {
                ForEach(a.grid.spans ?? [], id: \.span) { s in
                    let on = s.span == a.grid.span
                    Button { feed.pick(s.span) } label: {
                        Text(s.text)
                            .fontWeight(on ? .semibold : .regular)
                            .foregroundStyle(on ? theme.text.color : theme.textSecondary.color)
                            .frame(height: CGFloat(Page.segHeight))
                            .overlay(alignment: .bottom) {
                                // A short rule under the one in front; no grey ground.
                                if on {
                                    theme.text.color.frame(height: CGFloat(Page.segRule))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The machine's line with only `kept`, each whole.
    private func machineItems(_ a: Res.Answer, kept: [PerfLayout.MachineItem], theme: Look.Theme) -> some View {
        let m = a.machine.text
        return HStack(spacing: CGFloat(Page.machineItemGap)) {
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(Page.summaryPadX) / 2) {
                if kept.contains(.label), let label = m.label { Text(label).foregroundStyle(theme.textSecondary.color) }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let mem = m.mem {
                        Text(mem).font(.system(size: CGFloat(Card.fontBig), weight: .semibold)).foregroundStyle(theme.text.color)
                    }
                    if let of = m.mem_of { Text(of).foregroundStyle(theme.textSecondary.color) }
                }
            }
            if kept.contains(.swap), let swap = m.swap { Text(swap).foregroundStyle(theme.textSecondary.color) }
            if kept.contains(.pressure), let pressure = m.pressure {
                Text(pressure).foregroundStyle(a.machine.pressure_tone?.ink(theme)?.text.color ?? theme.textSecondary.color)
            }
            if kept.contains(.panes) { Text(m.panes).foregroundStyle(theme.textSecondary.color) }
            if kept.contains(.day) { Text(m.day).foregroundStyle(theme.textSecondary.color) }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// The grid's heading: the title and what a cell is on the left, the
    /// legend on the right -- each whole or not at all: the subtitle goes
    /// first, then the legend (group seq 263), as on Windows.
    private func gridHead(_ a: Res.Answer, theme: Look.Theme) -> some View {
        ViewThatFits(in: .horizontal) {
            gridHeadLine(a, subtitle: true, legend: true, theme: theme)
            gridHeadLine(a, subtitle: false, legend: true, theme: theme)
            gridHeadLine(a, subtitle: false, legend: false, theme: theme)
        }
    }

    private func gridHeadLine(_ a: Res.Answer, subtitle: Bool, legend: Bool, theme: Look.Theme) -> some View {
        HStack(spacing: CGFloat(Grid.labelGap)) {
            Text(a.grid.title).fontWeight(.semibold).foregroundStyle(theme.text.color).fixedSize()
            if subtitle {
                Text(a.grid.subtitle).foregroundStyle(theme.textSecondary.color).fixedSize()
            }
            Spacer(minLength: 0)
            if legend {
                ForEach(Array(a.grid.legend.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: CGFloat(Grid.legendGap)) {
                        RoundedRectangle(cornerRadius: CGFloat(Grid.cellRadius))
                            .fill(cellColor(entry.tone, theme: theme))
                            .frame(width: CGFloat(Grid.legendSwatch), height: CGFloat(Grid.legendSwatch))
                        Text(entry.text).foregroundStyle(theme.textSecondary.color).fixedSize()
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private func cellColor(_ level: Res.Level, theme: Look.Theme) -> Color {
        switch level {
        case .none: theme.levelNone.color
        case .ok: theme.levelOk.color
        default: level.ink(theme)?.base.color ?? theme.levelNone.color
        }
    }

    /// The cells: one canvas, so a week's grid is not hundreds of views.
    ///
    /// **What it draws is `drawnCells`, and it says so** (group seq 289: the
    /// log said 42 cells in 7 days while the screen kept 48 in none -- the
    /// day's -- after "7 天" was picked). A bare window redraws a canvas
    /// whose numbers change, so why this one kept its picture is not known;
    /// it is now a new canvas whenever its cells are laid out differently
    /// (`.id`), and the line it writes as it draws is what it drew.
    private func cells(_ a: Res.Answer, at: PerfLayout, theme: Look.Theme) -> some View {
        let hovered = feed.hovered
        let drawn = at.drawnCells()
        let key = "\(at.span.rawValue) \(at.cells.count) from \(at.cells.first) at \(at.cells.size)"
        return Canvas { ctx, _ in
            feed.canvasDrew(key, PerfLayout.columnsAndGroups(drawn.map(\.rect), gap: at.cells.gap))
            for d in drawn {
                    let i = d.row, k = d.cell, r = d.rect
                    guard let level = a.grid.panes[safe: i]?.cells[safe: k] else { continue }
                    let shape = Path(roundedRect: r, cornerRadius: CGFloat(Grid.cellRadius))
                    ctx.fill(shape, with: .color(cellColor(level, theme: theme)))
                    if hovered?.row == i && hovered?.cell == k {
                        ctx.stroke(shape, with: .color(theme.text.color), lineWidth: 1)
                    } else if level == .killed, let ink = level.ink(theme) {
                        ctx.stroke(shape, with: .color(ink.edge.color), lineWidth: 1)
                    }
            }
            // Earlier cells than there is room for: a faint mark at the
            // left of the first drawn -- no words of the host's own.
            if at.cells.first > 0, at.panes > 0 {
                let top = at.rowRect(0).minY, bottom = at.rowRect(at.panes - 1).maxY
                let cx = at.cellsX + at.cells.lead - CGFloat(Grid.labelGap) / 2, mid = (top + bottom) / 2
                var mark = Path()
                mark.move(to: CGPoint(x: cx + 2, y: mid - 4))
                mark.addLine(to: CGPoint(x: cx - 2, y: mid))
                mark.addLine(to: CGPoint(x: cx + 2, y: mid + 4))
                ctx.stroke(mark, with: .color(theme.textTertiary.color), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .id(key)
    }

    private func tip(_ lines: [Res.Toned], at: PerfLayout, row: Int, cell: Int, theme: Look.Theme) -> some View {
        let face = SafeFace(size: CGFloat(Look.Font.body), weight: .semibold)
        let widest = lines.map { SafeTextMeasure.width($0.text, in: face).rounded(.up) }.max() ?? 0
        let r = at.tipRect(row: row, cell: cell, lines: lines.count, width: widest) ?? .zero
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .fontWeight(line.tone?.ink(theme) != nil ? .semibold : .regular)
                    .foregroundStyle(line.tone?.ink(theme)?.text.color ?? theme.text.color)
                    .lineLimit(1)
                    .frame(height: CGFloat(Grid.tipLineHeight))
            }
        }
        .padding(.horizontal, CGFloat(Grid.tipPadX))
        .padding(.vertical, CGFloat(Grid.tipPadY))
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: CGFloat(Grid.tipRadius), style: .continuous).fill(theme.perfTip.color))
        .overlay(RoundedRectangle(cornerRadius: CGFloat(Grid.tipRadius), style: .continuous)
            .strokeBorder(theme.perfTipEdge.color, lineWidth: CGFloat(Look.Line.hairline)))
        .offset(x: r.minX, y: r.minY)
        .allowsHitTesting(false)
    }
}

/// One terminal's card (ui-v4): its name, role and badge; the dial with
/// its number and what it is measured against; the four lines; the foot.
struct ControlRoomPerfCard: View {
    typealias Look = ControlRoomLook
    typealias Res = ControlRoomResources
    typealias PerfLayout = ControlRoomPerfLayout
    typealias Card = Look.PerfCard

    var card: Res.Card
    var points: [(UInt64, UInt64)]
    var nowMs: UInt64
    var spanMs: UInt64
    var theme: Look.Theme

    var body: some View {
        let frame = CGRect(x: 0, y: 0, width: CGFloat(Card.width), height: CGFloat(Card.height))
        let g = PerfLayout.cardGrid(frame)
        let ink = card.tone.ink(theme)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: CGFloat(Card.radiusMac), style: .continuous)
                .fill(theme.perfCard.color)
                .overlay(RoundedRectangle(cornerRadius: CGFloat(Card.radiusMac), style: .continuous)
                    .strokeBorder(ink?.edge.color ?? theme.perfCardEdge.color, lineWidth: ink == nil ? CGFloat(Look.Line.hairline) : 1))
            head(ink: ink).place(g.head)
            // Only when the core said how full it is (`ControlRoomResources.readCard`).
            if let d = card.dial {
                dial(d, g, ink: ink)
                Text(d.cap).foregroundStyle(theme.textTertiary.color).lineLimit(1)
                    .frame(width: g.cap.width, height: g.cap.height).place(g.cap)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let r1 = card.lines.r1 {
                    Text(r1.value).font(.system(size: CGFloat(Card.fontValue), weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(r1.rest).foregroundStyle(theme.textTertiary.color)
                }
            }
            .lineLimit(1)
            .frame(width: g.r1.width, height: g.r1.height, alignment: .leading).place(g.r1)
            toned(card.lines.r2, none: theme.textTertiary).frame(width: g.r2.width, height: g.r2.height, alignment: .leading).place(g.r2)
            toned(card.lines.r3, none: theme.textSecondary).frame(width: g.r3.width, height: g.r3.height, alignment: .leading).place(g.r3)
            curve(g.r4)
            HStack {
                Text(card.foot.left).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if !card.foot.right.isEmpty { Text(card.foot.right).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(theme.textTertiary.color)
            .monospacedDigit()
            .frame(width: g.foot.width, height: g.foot.height).place(g.foot)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    }

    private func head(ink: Res.Level.Ink?) -> some View {
        HStack(spacing: CGFloat(Card.badgePadX)) {
            Text(card.name).font(.system(size: CGFloat(Look.Font.body), weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.middle)
            if let role = card.role { Text(role).foregroundStyle(theme.textTertiary.color).lineLimit(1).fixedSize() }
            Spacer(minLength: 0)
            if let badge = card.badge {
                let bi = badge.tone?.ink(theme)
                Text(badge.text).fontWeight(.semibold)
                    .foregroundStyle(bi?.text.color ?? theme.textSecondary.color)
                    .padding(.horizontal, CGFloat(Card.badgePadX))
                    .frame(height: CGFloat(Card.badgeHeight))
                    .background(RoundedRectangle(cornerRadius: CGFloat(Card.badgeRadius)).fill(bi?.badge.color ?? .clear))
                    .fixedSize()
            }
        }
        .frame(width: CGFloat(Card.width - 2 * Card.padX), height: CGFloat(Card.head))
    }

    private func toned(_ t: Res.Toned?, none: Look.RGBA) -> some View {
        let ink = t?.tone?.ink(theme)
        return Text(t?.text ?? "")
            .fontWeight(ink != nil ? .semibold : .regular)
            .foregroundStyle(ink?.text.color ?? none.color)
            .lineLimit(1).truncationMode(.tail)
    }

    private func dial(_ d: Res.Dial, _ g: PerfLayout.CardGrid, ink: Res.Level.Ink?) -> some View {
        let centre = CGPoint(x: g.dial.midX, y: g.dial.midY)
        let radius = CGFloat(Card.dialRadius)
        let from = Card.dialStartDegrees, sweep = Card.dialOpenDegrees
        let fill = min(max(d.fraction, 0), 1)
        func arc(_ to: Double) -> Path {
            // Increasing angles, drawn clockwise on the screen (y down).
            Path { p in p.addArc(center: centre, radius: radius, startAngle: .degrees(from), endAngle: .degrees(from + to), clockwise: false) }
        }
        let stroke = StrokeStyle(lineWidth: CGFloat(Card.dialStroke), lineCap: .round)
        var ticks: [(Double, Look.RGBA)] = d.ticks.enumerated().compactMap { i, t in
            (i == 0 ? Res.Level.warn1 : Res.Level.warn2).ink(theme).map { (t, $0.base) }
        }
        if card.line_at != nil, let k = Res.Level.killed.ink(theme) { ticks.append((1, k.base)) }
        let bigFace = Font.system(size: CGFloat(Card.fontBig), weight: .semibold)
        return ZStack(alignment: .topLeading) {
            arc(sweep).stroke(theme.perfDialTrack.color, style: stroke)
            if fill > 0 {
                arc(sweep * fill).stroke((ink?.base ?? theme.levelOkArc).color, style: stroke)
            }
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                let a = from + sweep * min(max(tick.0, 0), 1)
                Path { p in
                    p.move(to: PerfLayout.onCircle(centre, radius: CGFloat(Card.dialTickInner), degrees: a))
                    p.addLine(to: PerfLayout.onCircle(centre, radius: CGFloat(Card.dialTickOuter), degrees: a))
                }
                .stroke(tick.1.color, style: StrokeStyle(lineWidth: CGFloat(Card.dialTickStroke), lineCap: .round))
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(d.big).font(bigFace)
                    .foregroundStyle(card.tone == .killed ? (ink?.text ?? theme.text).color : theme.text.color)
                Text(d.unit).foregroundStyle(theme.textSecondary.color)
            }
            .frame(width: g.dial.width, height: 28)
            .place(CGRect(x: g.dial.minX, y: centre.y - 14, width: g.dial.width, height: 28))
        }
        .monospacedDigit()
    }

    private func curve(_ rect: CGRect) -> some View {
        let c = Res.curve(points, lineAt: card.line_at, rect: rect, now: nowMs, span: spanMs)
        return ZStack(alignment: .topLeading) {
            if c.line.count >= 2 {
                Path { p in
                    p.addLines(c.line)
                    p.addLine(to: CGPoint(x: c.line[c.line.count - 1].x, y: rect.maxY))
                    p.addLine(to: CGPoint(x: c.line[0].x, y: rect.maxY))
                    p.closeSubpath()
                }
                .fill(theme.perfCurveFill.color)
                Path { p in p.addLines(c.line) }
                    .stroke(theme.perfCurve.color, style: StrokeStyle(lineWidth: CGFloat(Card.curveStroke), lineCap: .round, lineJoin: .round))
            }
            if let y = c.killY, let k = Res.Level.killed.ink(theme) {
                Path { p in p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y)) }
                    .stroke(k.base.color, style: StrokeStyle(lineWidth: CGFloat(Card.lineStroke), dash: [CGFloat(Card.curveDash), CGFloat(Card.curveGap)]))
            }
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// At `rect`'s top left, in its parent's top-left-aligned stack.
    func place(_ rect: CGRect) -> some View {
        offset(x: rect.minX, y: rect.minY)
    }
}
