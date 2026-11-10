import SwiftUI

/// The overall view's own reading: the `overall` page with no group named,
/// asked the way the left panel's bottom line asks it (task 2149, slice 2).
///
/// **A feed of its own and not the panel's**, because the page and the row
/// are two views with two lifetimes: the panel's line is there while the
/// list is, and this is there while the whole of Polter is in front.
struct ControlRoomOverallPane: View {
    typealias U = ControlRoomOverall
    typealias Look = ControlRoomLook

    /// The door, in the spelling this file can compile against
    /// (`ControlRoomOverall.Ask`): nil -- and then the page says so -- when
    /// there is no core.
    var ask: U.Ask?

    @StateObject private var feed: ControlRoomOverallFeed
    /// Which span the chart draws. **The host's own**, so it lives here and
    /// not in the answer.
    @State private var span: U.Span = .day
    /// Which of the table's headings the reader has closed (task 3113).
    /// The host's own for the same reason `span` is: what a reader has
    /// folded away is not a fact about the machine.
    @State private var folded: Set<String> = []

    @Environment(\.colorScheme) private var scheme

    init(ask: U.Ask?) {
        self.ask = ask
        _feed = StateObject(wrappedValue: ControlRoomOverallFeed(ask: ask ?? { _ in .notReady }))
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                if let answer = feed.answer {
                    ControlRoomOverallPage(answer: answer, span: $span, folded: $folded)
                        .frame(width: proxy.size.width, alignment: .topLeading)
                } else {
                    Color.clear.frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        // **The ground, whether or not there is a reading yet** (task 2149,
        // slice 2, the reviewer's second must-fix). `Color.clear` above is
        // the right thing for the pane's own inside -- there is nothing to
        // draw -- but it is not a ground: with none, whatever the frame was
        // drawing under this pane showed through, and on a group with no
        // terminal that was the "start a supervisor" sentence and its button,
        // visible and clickable under a view that had taken the whole right
        // side. The pane takes the right side from the moment it is in front,
        // so it is opaque from the moment it is in front.
        .background(Look.theme(scheme).terminalBackground.color)
        .onAppear {
            feed.request = ControlRoomOverallFeed.wholeRequest
            feed.start()
        }
        .onDisappear { feed.stop() }
    }
}

/// The overall view (task 2149, handoff §6, the third of slice 2's three
/// blocks): **all of Polter** -- what it costs, what it has cost over the
/// last day or week, and which of its processes is doing it -- drawn where
/// the supervisor's terminal was.
///
/// **The core decides, this draws.** Every number here arrives as a field
/// (`OverallPage.render`): the four figures, the stacked layers, the
/// moment the chart's right edge is, the row that is rising and by how much,
/// the machine's two curves, and the process table with each row's group
/// already named. Nothing here compares two rows, sorts them or weighs a
/// slope (`tools/control-room-hosts-do-not-decide.py`). What is local is
/// what a host is for: the words in the person's language, which of the two
/// spans the switch is showing, and where the parts of the page go
/// (`ControlRoomOverall.layout`).
///
/// **The design's `02-overall-leak`** (`perf5.py`'s `overall`): four figures
/// across the top, the chart and its legend under them, the machine's two
/// curves side by side, and the process table taking what is left.
///
/// Every box is in `ControlRoomOverall.layout`'s own coordinates, which are
/// the page's: a part is drawn at its rect less that rect's own origin, so
/// that the page's edges and the chart's inside cannot be worked out from
/// two readings.
struct ControlRoomOverallPage: View {
    typealias Look = ControlRoomLook
    typealias U = ControlRoomOverall
    typealias Page = Look.OverallPage

    var answer: U.Answer
    /// Which of the two spans the chart draws. **The host's own**, like the
    /// performance page's: which of two windows a reader is looking at is
    /// not a fact about the machine.
    @Binding var span: U.Span
    /// The table's headings the reader has closed (task 3113), by the
    /// core's own category. The host's own for the reason `span` is.
    @Binding var folded: Set<String>

    @Environment(\.colorScheme) private var scheme

    private var theme: Look.Theme { Look.theme(scheme) }

    var body: some View {
        GeometryReader { proxy in
            let at = U.layout(width: proxy.size.width, rising: answer.polter.rise != nil)
            // **The table's lines, worked out once** and used for both the
            // table's own height and how tall the page is: two readings of
            // the same list would be two answers about how many lines there
            // are, and the page would end above or below its own table.
            // The folded headings are the reader's, so the same list moves
            // with them (task 3113).
            let lines = U.tableLines(answer.polter, folded: folded)
            ZStack(alignment: .topLeading) {
                figures(at)
                chart(at)
                curves(at)
                processTable(at, lines: lines)
            }
            .frame(width: proxy.size.width,
                   height: at.contentHeight + U.tableHeight(rows: lines.count + 1),
                   alignment: .topLeading)        }
        .background(theme.terminalBackground.color)
    }

    // MARK: - The four figures

    @ViewBuilder
    private func figures(_ at: U.Layout) -> some View {
        ForEach(Array(at.kpis.enumerated()), id: \.offset) { i, rect in
            figure(i, rect: rect)
        }
    }

    /// One figure: what it is, the number, and the one line under it that
    /// says whether it is all right. **Which line that is, and its ink, come
    /// from the core's own verdicts** (`swap_growth.rising`, `disk_low`);
    /// the words are the host's.
    @ViewBuilder
    private func figure(_ i: Int, rect: CGRect) -> some View {
        let parts = figureParts(i)
        let label = parts.label
        let value = parts.value
        let unit = parts.unit
        let sub = parts.sub
        let tone = parts.tone
        VStack(alignment: .leading, spacing: 0) {
            Text(label).foregroundStyle(theme.textSecondary.color).lineLimit(1)
                .frame(height: CGFloat(Page.kpiLine), alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .font(.system(size: CGFloat(Look.Font.kpiValue), weight: .semibold))
                    .foregroundStyle(theme.text.color)
                Text(unit).foregroundStyle(theme.textSecondary.color)
            }
            .lineLimit(1)
            .padding(.top, CGFloat(Page.kpiValueTop))
            .frame(height: CGFloat(Page.kpiValueHeight), alignment: .leading)
            Text(sub)
                .foregroundStyle(tone.ink(theme).color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: CGFloat(Page.kpiLine), alignment: .leading)
        }
        .padding(.horizontal, CGFloat(Page.cardPadX))
        .padding(.vertical, CGFloat(Page.cardPadY))
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(card(radius: CGFloat(Page.cardRadius), edge: tone.edge(theme)))
        .offset(x: rect.minX, y: rect.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)\(unit). \(sub)")
    }

    /// What one figure says: its label, the number, its unit, the line under
    /// it, and the ink. **A plain function rather than a `switch` inside the
    /// view builder**, so that SwiftUI's result builder has nothing to infer
    /// here -- the builder had the five `let`s and the `switch` as views.
    private func figureParts(_ i: Int) -> (label: String, value: String, unit: String,
                                           sub: String, tone: Tone) {
        let w = words
        switch i {
        case 0:
            // **The whole tree, as the row that opens this view draws it**
            // (task 3012): the figure is what the system charges to Polter,
            // and the process table below is how it comes apart. A core
            // without `tree_mib` leaves the figure on Polter's own rows.
            let size = U.size(answer.polter.treeMib ?? answer.totalMib)
            return (w.totalLabel, Self.number(size), Self.unit(size), w.steady, .normal)
        case 1:
            return (w.cpuLabel, answer.cpuCores, w.cores, w.steady, .normal)
        case 2:
            let swap = answer.machine.swapUsedMib.map(U.size)
            let unit = swap.map { Self.unit($0) + (answer.machine.swapTotalMib.map { t in " / " + U.size(t) } ?? "") } ?? ""
            return (w.swapLabel, swap.map(Self.number) ?? w.notRead, unit,
                    answer.machine.swapRising ? w.swapRate(answer.machine.swapSlopeMibPerHour) : w.steady,
                    answer.machine.swapRising ? .warn : .normal)
        default:
            let disk = answer.machine.diskFreeMib.map(U.size)
            return (w.diskLabel, disk.map(Self.number) ?? w.notRead, disk.map(Self.unit) ?? "",
                    answer.machine.diskLow ? w.diskLine(answer.machine.diskLowLineMib) : w.steady,
                    answer.machine.diskLow ? .bad : .normal)
        }
    }

    /// "22.4" from "22.4 GB": the number and its unit are set at two sizes
    /// in a figure, so the one string `size` writes is split where `size`
    /// puts the space.
    private static func number(_ size: String) -> String {
        guard let i = size.firstIndex(of: " ") else { return size }
        return String(size[size.startIndex..<i])
    }

    private static func unit(_ size: String) -> String {
        guard let i = size.firstIndex(of: " ") else { return "" }
        return String(size[i...])
    }

    /// The three inks a figure is outlined and written in: **the core's own
    /// verdict**, and nothing this side worked out.
    private enum Tone {
        case normal, warn, bad

        func ink(_ t: Look.Theme) -> Look.RGBA {
            switch self {
            case .normal: t.textSecondary
            case .warn: t.levelWarn1Text
            case .bad: t.levelKilledText
            }
        }

        func edge(_ t: Look.Theme) -> Look.RGBA? {
            switch self {
            case .normal: nil
            case .warn: t.levelWarn1Edge
            case .bad: t.levelKilledEdge
            }
        }
    }

    // MARK: - The chart

    @ViewBuilder
    private func chart(_ at: U.Layout) -> some View {
        let layers = answer.polter.series.layers(span)
        let stack = U.stack(layers)
        let step = answer.polter.series.stepS(span)
        // **Every box inside the chart comes from `layout`**, less the
        // chart's own inside: the chart's contents and the page's outside
        // were otherwise two answers about where the chart's contents begin.
        let inside = at.chartInner
        let plot = at.plot.offsetBy(dx: -inside.minX, dy: -inside.minY)
        let gutter = at.plotGutter.offsetBy(dx: -inside.minX, dy: -inside.minY)
        let head = at.chartHead.offsetBy(dx: -inside.minX, dy: -inside.minY)
        let note = at.riseNote.offsetBy(dx: -inside.minX, dy: -inside.minY)
        // **The card is `at.chart`, and the contents are placed against the
        // card's own inside** (task 3090). The two must be one reading of
        // where the card is: the parts above are in card-inside coordinates,
        // so the stack is offset by the card's padding and the whole card by
        // the page's `at.chart` -- once, and never by `at.chartInner.min`
        // as well. That double offset was what put every part a card's own
        // height below its card: the title in the card's middle, the plot's
        // labels under it on the next card.
        ZStack(alignment: .topLeading) {
            // The card's ground, at the card's rect -- not at the inside's,
            // which is two paddings smaller and would leave the plot's right
            // end and its hour labels outside the card.
            card(radius: CGFloat(Page.cardRadius))
            ZStack(alignment: .topLeading) {
                chartHead(stack: stack, layers: layers)
                    .offset(x: head.minX, y: head.minY)
                if let rise = answer.polter.rise {
                    Text(words.riseSentence(rise))
                        .foregroundStyle(theme.levelWarn2Text.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: note.width, height: note.height, alignment: .leading)
                        .offset(x: note.minX, y: note.minY)
                }
                plotCanvas(stack: stack, step: step, rect: plot, gutter: gutter,
                           rise: answer.polter.rise)
            }
            .frame(width: inside.width, height: inside.height, alignment: .topLeading)
            .offset(x: CGFloat(Page.cardPadX), y: CGFloat(Page.cardPadY))
        }
        .frame(width: at.chart.width, height: at.chart.height, alignment: .topLeading)
        .offset(x: at.chart.minX, y: at.chart.minY)
    }

    /// The chart's title row: what it is, the layers named, and the
    /// switch between the two spans.
    @ViewBuilder
    private func chartHead(stack: U.Stack, layers: [U.Layer]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CGFloat(Page.chartHeadGap)) {
            Text(words.chartTitle).fontWeight(Look.weight(Look.Font.weightEmphasis)).foregroundStyle(theme.text.color)
            Text(words.chartSubtitle).foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: CGFloat(Page.chartHeadGap))
            HStack(spacing: CGFloat(Page.chartLegendGap)) {
                legend(layers)
                spanSwitch
            }
        }
        .lineLimit(1)
        .frame(height: CGFloat(Page.chartHeadHeight), alignment: .leading)
    }

    /// The legend's entries, **named from the core's own layers and in its
    /// order**: the host draws the stack it was handed and does not work out
    /// which layer is which (`Layer.name`). Two of them now: the main
    /// process, and the terminals (task 3113, second round).
    @ViewBuilder
    private func legend(_ layers: [U.Layer]) -> some View {
        HStack(spacing: CGFloat(Page.chartLegendGap)) {
            ForEach(Array(layers.enumerated()), id: \.offset) { i, layer in
                HStack(spacing: CGFloat(Page.legendSwatchGap)) {
                    RoundedRectangle(cornerRadius: CGFloat(Page.legendSwatchRadius), style: .continuous)
                        .fill(layerInk(i).color)
                        .frame(width: CGFloat(Page.legendSwatch), height: CGFloat(Page.legendSwatch))
                    Text(words.layerName(layer.name)).foregroundStyle(theme.textSecondary.color)
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
    }

    /// The two layers' inks, in the order the core stacks them (task 3113,
    /// second round: the main process and the terminals). **The band that
    /// is rising is the warning one** while the core says something is
    /// rising -- that is what makes a leak visible in the picture
    /// (`02-overall-leak`).
    private func layerInk(_ i: Int) -> Look.RGBA {
        switch i {
        case 0: theme.segSupervisor
        case 1: answer.polter.rise == nil ? theme.segWorkers : theme.stripWarn
        default: theme.segOwn
        }
    }

    /// The two spans, as the design's `.seg5`: the one in front is a chip.
    private var spanSwitch: some View {
        HStack(spacing: CGFloat(Page.spanGap)) {
            ForEach(U.Span.allCases, id: \.self) { s in
                Button { span = s } label: {
                    Text(s.label)
                        .fontWeight(s == span ? Look.weight(Look.Font.weightEmphasis) : Look.weight(Look.Font.weightBody))
                        .foregroundStyle((s == span ? theme.text : theme.textSecondary).color)
                        .padding(.horizontal, CGFloat(Page.spanPadX))
                        .frame(height: CGFloat(Page.spanHeight))
                        .background(
                            RoundedRectangle(cornerRadius: CGFloat(Page.spanRadius), style: .continuous)
                                .fill(s == span ? theme.perfCard.color : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(s == span ? .isSelected : [])
            }
        }
        .padding(CGFloat(Page.spanPad))
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Page.spanBoxRadius), style: .continuous)
                .strokeBorder(theme.lineFaint.color, lineWidth: CGFloat(Look.Line.hairline)))
    }

    /// The chart itself: the three bands stacked, the grid, the labels of
    /// both axes, and the rise line.
    ///
    /// **Every y is `U.stackY` and every x is `U.cellBand`**, so the bands,
    /// the grid and the labels cannot be placed from three readings of one
    /// scale.
    @ViewBuilder
    private func plotCanvas(stack: U.Stack, step: UInt64, rect: CGRect, gutter: CGRect,
                            rise: U.Rise?) -> some View {
        ZStack(alignment: .topLeading) {
            // The grid, at each quarter of the scale and the floor, with the
            // value it stands at in the gutter at the left.
            ForEach(Array(0..<Int(Page.plotGridLines)), id: \.self) { k in
                let parts = max(1, Int(Page.plotGridLines) - 1)
                let v = stack.maxMib * UInt64(k) / UInt64(parts)
                let y = U.stackY(v, of: stack.maxMib, in: rect)
                theme.lineFaint.color
                    .frame(width: rect.width, height: CGFloat(Look.Line.hairline))
                    .offset(x: rect.minX, y: y)
                Text(label(v))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: gutter.width, height: CGFloat(Page.plotLabelHeight), alignment: .trailing)
                    .offset(x: gutter.minX, y: y - CGFloat(Page.plotLabelHeight) / 2)
            }
            // The bands, from the bottom layer up: each is the area between
            // its own top edge and the one below it.
            ForEach(Array(stack.tops.indices), id: \.self) { i in
                band(i, stack: stack, rect: rect)
                    .fill(layerInk(i).color)
            }
            // **The rise line: the moment the core says the climbing began**,
            // placed from its own `now_s` and the span's own step, never from
            // the answer's clock (`U.riseMarkX`).
            if let rise, let x = U.riseMarkX(sinceS: rise.sinceS, nowS: answer.polter.series.nowS,
                                             stepS: step, cells: stack.cells, in: rect) {
                Path { p in
                    p.move(to: CGPoint(x: x, y: rect.minY))
                    p.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
                .stroke(theme.levelWarn2.color,
                        style: StrokeStyle(lineWidth: CGFloat(Look.Line.stroke),
                                           dash: [CGFloat(Page.riseDash), CGFloat(Page.riseDash)]))
            }
            hours(rect, cells: stack.cells)
        }
    }

    /// One layer's band: its top edge across the box, closed along the edge
    /// below it. **The two edges are one reading** -- `stack.top(i)` and
    /// `stack.base(i, …)` -- so a band cannot be drawn against a different
    /// layer's row than the one over it.
    private func band(_ i: Int, stack: U.Stack, rect: CGRect) -> Path {
        Path { p in
            let cells = stack.cells
            guard cells > 0 else { return }
            let top = stack.top(i)
            func at(_ j: Int, upper: Bool) -> CGPoint {
                let cell = U.cellBand(j, of: cells, in: rect)
                let v = upper ? (j < top.count ? top[j] : 0) : stack.base(i, j)
                return CGPoint(x: cell.minX, y: U.stackY(v, of: stack.maxMib, in: rect))
            }
            p.move(to: at(0, upper: false))
            for j in 0..<cells { p.addLine(to: at(j, upper: false)) }
            // The last cell's right edge, so the band reaches the box's own
            // right end rather than stopping a cell short of it.
            let last = U.cellBand(cells - 1, of: cells, in: rect)
            p.addLine(to: CGPoint(x: last.maxX, y: at(cells - 1, upper: false).y))
            p.addLine(to: CGPoint(x: last.maxX, y: at(cells - 1, upper: true).y))
            for j in stride(from: cells - 1, through: 0, by: -1) { p.addLine(to: at(j, upper: true)) }
            p.closeSubpath()
        }
    }

    /// The moments along the bottom, counted back from the core's own
    /// `run_started` by the box's own span: the chart shows a window, and
    /// its two ends are what a reader compares (`U.cellBand` places the
    /// cells, so these labels are the same axis).
    @ViewBuilder
    private func hours(_ rect: CGRect, cells: Int) -> some View {
        if cells > 0, let started = words.clock(answer.polter.runStarted) {
            let marks = 4
            ForEach(Array(0..<marks), id: \.self) { k in
                let t = words.stamp(started, plusCells: Double(cells) * Double(k) / Double(marks - 1), span: span)
                Text(t)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: CGFloat(Page.plotLabelHeight), alignment: .leading)
                    .offset(x: rect.minX + rect.width * CGFloat(k) / CGFloat(marks - 1)
                              - (k == marks - 1 ? 36 : 0),
                            y: rect.maxY + CGFloat(Page.plotAxisGap))
            }
        }
    }

    /// MiB on the y axis, in GB as everything else on this page is.
    private func label(_ mib: UInt64) -> String {
        mib >= 1024 ? String(format: "%.0f", Double(mib) / 1024) : "\(mib)"
    }

    // MARK: - The machine's two curves

    @ViewBuilder
    private func curves(_ at: U.Layout) -> some View {
        mini(title: words.swapTitle, subtitle: words.swapSubtitle,
             right: answer.machine.swapUsedMib.map { U.size($0) } ?? words.notRead,
             tone: answer.machine.swapRising ? .warn : .normal,
             points: answer.machine.swapHour, lineAt: nil, rect: at.minis[0])
        mini(title: words.diskTitle, subtitle: words.diskSubtitle,
             right: answer.machine.diskFreeMib.map(U.size) ?? words.notRead,
             tone: answer.machine.diskLow ? .bad : .normal,
             points: answer.machine.diskHour, lineAt: answer.machine.diskLowLineMib, rect: at.minis[1])
    }

    @ViewBuilder
    private func mini(title: String, subtitle: String, right: String, tone: Tone,
                      points: [(UInt64, UInt64)], lineAt: UInt64?, rect: CGRect) -> some View {
        // Inside the card: the head, then the curve, both from the card's own
        // padding. **The curve is scaled into a box at its own origin and
        // the box is placed once** (`U.miniCurve`): the rect handed to
        // `ControlRoomResources.curve` used to already carry the card's
        // origin, which the view then added again -- the line drew a
        // padding right and a head's height low, its newest points outside
        // the card's bottom right (task 3113).
        let headH = CGFloat(Page.miniHeadHeight)
        let (box, place) = U.miniCurve(in: rect)
        // **The right-hand edge is the core's `now_s`**, the same moment the
        // chart above ends at, so that the two curves and the stacked chart
        // are read against one clock and not three (task 2149, slice 2, the
        // reviewer's suggestion). `now_s` is 0 only when the answer carries
        // no `series` at all, and then the points' own newest moment is used
        // rather than drawing nothing: a curve that vanished because a
        // neighbouring block was missing would read as "no reading".
        let nowS = answer.polter.series.nowS
        let drawn = ControlRoomResources.curve(points, lineAt: lineAt, rect: box,
                                               now: nowS > 0 ? nowS : (points.map(\.0).max() ?? 0),
                                               span: UInt64(24 * 60 * 60))
        ZStack(alignment: .topLeading) {
            HStack(spacing: CGFloat(Page.miniHeadGap)) {
                Text(title).fontWeight(Look.weight(Look.Font.weightEmphasis)).foregroundStyle(theme.text.color)
                Text(subtitle).foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: CGFloat(Page.miniHeadGap))
                Text(right).foregroundStyle(tone.ink(theme).color)
            }
            .lineLimit(1)
            .frame(width: rect.width - 2 * CGFloat(Page.cardPadX), height: headH, alignment: .leading)
            .offset(x: CGFloat(Page.cardPadX), y: CGFloat(Page.cardPadY))
            // **The line the disk is judged against**, drawn where the core
            // says it is (`disk_low_line_mib`): a line and not a rise.
            if let killY = drawn.killY {
                theme.levelKilled.color
                    .frame(width: box.width, height: CGFloat(Look.Line.hairline))
                    .offset(x: place.x, y: place.y + killY)
            }
            if drawn.line.count >= 2 {
                Path { p in p.addLines(drawn.line) }
                    .stroke(tone == .normal ? theme.perfCurve.color : tone.ink(theme).color,
                            style: StrokeStyle(lineWidth: CGFloat(Look.Line.stroke),
                                               lineCap: .round, lineJoin: .round))
                    .frame(width: box.width, height: box.height)
                    .offset(x: place.x, y: place.y)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(card(radius: CGFloat(Page.cardRadius)))
        .offset(x: rect.minX, y: rect.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(subtitle) \(right)")
    }

    // MARK: - The process table

    @ViewBuilder
    private func processTable(_ at: U.Layout, lines: [U.TableLine]) -> some View {
        let headH = CGFloat(Page.tableHeadHeight)
        let rowH = CGFloat(Page.tableRowHeight)
        let height = CGFloat(Page.tableTop) + headH + CGFloat(lines.count) * rowH
        ZStack(alignment: .topLeading) {
            tableHead()
                .offset(x: CGFloat(Page.cardPadX), y: CGFloat(Page.tableTop))
            // One flat list of lines, in the core's order: a group's heading
            // and then its rows, both as `U.tableLines` worked them out of
            // the core's own two lists.
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                lineView(line)
                    .offset(x: 0, y: CGFloat(Page.tableTop) + headH + CGFloat(i) * rowH)
            }
        }
        .frame(width: at.table.width, height: height, alignment: .topLeading)
        .background(card(radius: CGFloat(Page.cardRadius)))
        .offset(x: at.table.minX, y: at.table.minY)
    }

    @ViewBuilder
    private func lineView(_ line: U.TableLine) -> some View {
        switch line {
        case let .section(s): groupRow(s)
        case let .grouping(g): groupingRow(g)
        // **A row with a group is under a group's heading** (a chat, task
        // 3119), one layer in from the main process's own rows -- which
        // carry no group.
        case let .process(p): processRow(p, indent: p.group == nil ? 0 : CGFloat(Page.tableNameIndent))
        case let .terminal(p): terminalRow(p)
        case let .child(c): childRow(c)
        case let .more(n): moreRow(n)
        }
    }

    /// **A group of the table** (task 3119): the first layer under the main
    /// process. Its line is the core's name for the group and the core's own
    /// count and total; the terminals and the chat that carry that name stand
    /// under it. The whole line takes a press, as the category headings' do.
    ///
    /// **The empty name is the rows in no group**, and it is drawn with the
    /// host's words for that -- a fact the core sent (`group: ""`), not a
    /// group the host invented.
    private func groupingRow(_ g: U.TableGroup) -> some View {
        let key = U.groupKey(g.group)
        let closed = folded.contains(key)
        let name = g.group.isEmpty ? words.noGroup : g.group
        return Button {
            if closed { folded.remove(key) } else { folded.insert(key) }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: CGFloat(Page.tableTwistGap)) {
                    Image(systemName: closed ? "chevron.right" : "chevron.down")
                        .font(.system(size: CGFloat(Look.Font.body)))
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: CGFloat(Page.tableTwist))
                    Text(name)
                        .fontWeight(Look.weight(Look.Font.weightEmphasis))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                    Text("\(g.count)").foregroundStyle(theme.textTertiary.color)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(U.size(g.totalMib))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(theme.text.color)
                    .frame(width: CGFloat(Page.colMemory), alignment: .trailing)
                Spacer(minLength: CGFloat(Page.colHistory))
            }
            .padding(.leading, CGFloat(Page.tablePadX))
            .padding(.trailing, CGFloat(Page.tablePadX))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: CGFloat(Page.tableRowHeight), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(g.count) \(U.size(g.totalMib))")
        .accessibilityValue(closed ? words.collapsed : words.expanded)
        .accessibilityAddTraits(.isButton)
    }

    /// **A terminal, as its own group** (task 3113, second round): the
    /// table's third category heading used to stand over these rows, and it
    /// was a word for a shape of process -- one that named the row after a
    /// part of what it weighs. The heading is the terminal now: its title
    /// and id, the number of processes in its tree, and what the tree
    /// holds, and the processes it started stand under it.
    ///
    /// The whole line takes a press, as the category headings' do: a reader
    /// aiming at a 14-point triangle is aiming at nothing.
    private func terminalRow(_ p: U.Process) -> some View {
        let key = U.foldKey(p)
        let closed = folded.contains(key)
        return Button {
            if closed { folded.remove(key) } else { folded.insert(key) }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: CGFloat(Page.tableTwistGap)) {
                    Image(systemName: closed ? "chevron.right" : "chevron.down")
                        .font(.system(size: CGFloat(Look.Font.body)))
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: CGFloat(Page.tableTwist))
                    Text(U.rowName(p))
                        .fontWeight(Look.weight(Look.Font.weightEmphasis))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                        // The name is a title and then the id that says which
                        // terminal it is: a tail cut would eat the id.
                        .truncationMode(.middle)
                    Text("\(p.count)").foregroundStyle(theme.textTertiary.color)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(U.size(p.memMib))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle((p.rising ? theme.levelWarn2Text : theme.text).color)
                    .frame(width: CGFloat(Page.colMemory), alignment: .trailing)
                Spacer(minLength: CGFloat(Page.colHistory))
            }
            // **The second layer under its group's heading** (task 3119):
            // its triangle one indent in, so that a terminal is not read as
            // a heading of the same rank as the group over it.
            .padding(.leading, CGFloat(Page.tablePadX) + CGFloat(Page.tableNameIndent))
            .padding(.trailing, CGFloat(Page.tablePadX))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: CGFloat(Page.tableRowHeight), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(U.rowName(p)) \(p.count) \(U.size(p.memMib))")
        .accessibilityValue(closed ? words.collapsed : words.expanded)
        .accessibilityAddTraits(.isButton)
    }

    /// **"and N more processes"** under a terminal's list: the row carries
    /// the tree's heaviest `Overall.max_children` processes, and this says
    /// how many are not drawn rather than letting the list read as the
    /// whole tree (task 3113, second round).
    private func moreRow(_ n: UInt64) -> some View {
        HStack(spacing: 0) {
            Text(words.moreProcesses(n))
                .foregroundStyle(theme.textTertiary.color)
                .lineLimit(1)
                .padding(.leading, CGFloat(Page.tableNameIndent) * 2 + CGFloat(Page.tableTwist)
                            + CGFloat(Page.tableTwistGap))
                .frame(width: CGFloat(Page.colName), alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.trailing, CGFloat(Page.tablePadX))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CGFloat(Page.tableRowHeight), alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.moreProcesses(n))
    }

    /// **One process inside the terminal above it** (task 3113, second
    /// round): its name, what it holds, and its pid. It is what the
    /// terminal's total came apart into, so the two are read one under the
    /// other.
    private func childRow(_ c: U.Process.Child) -> some View {
        HStack(spacing: 0) {
            Text(c.name)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, CGFloat(Page.tableNameIndent) * 2 + CGFloat(Page.tableTwist)
                            + CGFloat(Page.tableTwistGap))
                .frame(width: CGFloat(Page.colName), alignment: .leading)
            cell("", width: CGFloat(Page.colGroup), align: .leading)
            cell(U.size(c.memMib), width: CGFloat(Page.colMemory), align: .trailing)
            cell("", width: CGFloat(Page.colHistory), align: .leading)
            cell("", width: CGFloat(Page.colCpu), align: .trailing)
            cell("\(c.pid)", width: CGFloat(Page.colPid), align: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.trailing, CGFloat(Page.tablePadX))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CGFloat(Page.tableRowHeight), alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.name) \(U.size(c.memMib))")
    }

    private func tableHead() -> some View {
        let w = words
        return HStack(spacing: 0) {
            cell(w.colName, width: CGFloat(Page.colName), align: .leading)
            cell(w.colGroup, width: CGFloat(Page.colGroup), align: .leading)
            cell(w.colMemory, width: CGFloat(Page.colMemory), align: .trailing)
            cell(w.colHistory, width: CGFloat(Page.colHistory), align: .leading)
            cell(w.colCpu, width: CGFloat(Page.colCpu), align: .trailing)
            cell(w.colPid, width: CGFloat(Page.colPid), align: .trailing)
            Spacer(minLength: 0)
        }
        .frame(height: CGFloat(Page.tableHeadHeight), alignment: .leading)
    }

    /// One group's line: **the core's own name for it and the core's own two
    /// numbers**, drawn as they come. The words are the host's
    /// (`words.sectionName`), the category and both numbers are the core's
    /// (`U.Section`): how many rows are under this heading and what they add
    /// up to were counted there.
    ///
    /// **The line is the button that closes the heading** (task 3113): the
    /// triangle was a picture and a press did nothing. The heading keeps
    /// its count and its total while it is closed, so a reader who folded a
    /// group away still sees what it costs.
    private func groupRow(_ s: U.Section) -> some View {
        let key = U.sectionKey(s.category)
        let closed = folded.contains(key)
        return Button {
            if closed { folded.remove(key) } else { folded.insert(key) }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: CGFloat(Page.tableTwistGap)) {
                    Image(systemName: closed ? "chevron.right" : "chevron.down")
                        .font(.system(size: CGFloat(Look.Font.body)))
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: CGFloat(Page.tableTwist))
                    Text(words.sectionName(s.category))
                        .fontWeight(Look.weight(Look.Font.weightEmphasis))
                        .foregroundStyle(theme.textSecondary.color)
                    Text("\(s.count)").foregroundStyle(theme.textTertiary.color)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(U.size(s.totalMib))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(theme.text.color)
                    .frame(width: CGFloat(Page.colMemory), alignment: .trailing)
                Spacer(minLength: CGFloat(Page.colHistory))
            }
            .padding(.leading, CGFloat(Page.tablePadX))
            .padding(.trailing, CGFloat(Page.tablePadX))
            // **One row is `tableRowHeight` tall and no more** (task 3090). It
            // used to take the whole table's height and centre its line in it:
            // every row then overlapped the one under it, and the table's lines
            // piled up in the middle with a blank where they should have been.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: CGFloat(Page.tableRowHeight), alignment: .leading)
            // The whole line takes a press, not just the triangle: a reader
            // aiming at a 14-point chevron is aiming at nothing.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(words.sectionName(s.category)) \(s.count)")
        .accessibilityValue(closed ? words.collapsed : words.expanded)
        .accessibilityAddTraits(.isButton)
    }

    /// One process. **The orange mark at the left is the core's `rising`**,
    /// and only where it says so.
    private func processRow(_ p: U.Process, indent: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(U.rowName(p))
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
                // **The middle, not the tail**: a row's name is the
                // terminal's title and then its id, and a tail cut would
                // eat the id -- the half that says which terminal it is
                // (task 3113).
                .truncationMode(.middle)
                .padding(.leading, CGFloat(Page.tableNameIndent) + indent)
                .frame(width: CGFloat(Page.colName), alignment: .leading)
            cell(p.group ?? "—", width: CGFloat(Page.colGroup), align: .leading)
            Text(U.size(p.memMib))
                .foregroundStyle((p.rising ? theme.levelWarn2Text : theme.text).color)
                .fontWeight(p.rising ? Look.weight(Look.Font.weightEmphasis) : .regular)
                .frame(width: CGFloat(Page.colMemory), alignment: .trailing)
            cell(p.alive ? "" : words.died(p.diedAt), width: CGFloat(Page.colHistory), align: .leading)
            cell(words.cores(p.cpuDecimals), width: CGFloat(Page.colCpu), align: .trailing)
            cell("\(p.pid)", width: CGFloat(Page.colPid), align: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.trailing, CGFloat(Page.tablePadX))
        // The row's own height, as `groupRow` above (task 3090): a row that
        // takes the whole table's height draws its line in the middle of the
        // table and over every row under it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CGFloat(Page.tableRowHeight), alignment: .leading)
        // The orange mark at the left edge of a row that is rising, over the
        // whole row: the design's `tr.leak`.
        .overlay(alignment: .leading) {
            if p.rising {
                theme.levelWarn2.color.frame(width: CGFloat(Page.tableLeakBar))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(U.rowName(p)) \(U.size(p.memMib))")
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: align)
    }

    // MARK: - The page's own pieces

    /// A card's ground: the faint fill, the hairline at its edge -- the
    /// verdict's own ink where a figure has one -- and the corner the look
    /// gives it.
    private func card(radius: CGFloat, edge: Look.RGBA? = nil) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(theme.perfCard.color)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder((edge ?? theme.perfCardEdge).color,
                              lineWidth: edge == nil ? CGFloat(Look.Line.hairline) : CGFloat(Page.cardEdge)))
    }

    // MARK: - The words

    private var words: Words { Words() }

    /// Every word this page says, in the person's language. **One struct**,
    /// so that the same sentence cannot be written twice and drift.
    private struct Words {
        // The first figure is the whole tree (task 3012), so it is named the
        // same way the row that opens this view names it.
        let totalLabel = String(localized: "Polter and its children", comment: "总控台：整体视图第一块，Polter 加上它开起来的终端")
        let cpuLabel = String(localized: "Polter CPU", comment: "总控台：整体视图第二块，Polter 的 CPU")
        let swapLabel = String(localized: "Swap", comment: "总控台：整体视图第三块，交换区")
        let diskLabel = String(localized: "Disk left", comment: "总控台：整体视图第四块，启动盘剩余")
        let cores = String(localized: " cores", comment: "总控台：整体视图 CPU 那一块数字后面的单位")
        let steady = String(localized: "→ steady", comment: "总控台：整体视图某一项没有在涨时，数字下面那一行")
        let notRead = String(localized: "not read", comment: "总控台：整体视图某一项读不到时的代替字")
        let chartTitle = String(localized: "Memory Polter is using", comment: "总控台：整体视图面积图的标题")
        let chartSubtitle = String(localized: "GB, two layers stacked, the top edge is the total",
                                   comment: "总控台：整体视图面积图标题右边的小字")
        let swapTitle = String(localized: "Swap", comment: "总控台：整体视图第一条小曲线的标题")
        let swapSubtitle = String(localized: "the machine, last 24 hours",
                                  comment: "总控台：整体视图交换区小曲线标题右边的小字")
        let diskTitle = String(localized: "Disk left", comment: "总控台：整体视图第二条小曲线的标题")
        let diskSubtitle = String(localized: "startup disk, dashed line = 15 GB",
                                  comment: "总控台：整体视图磁盘小曲线标题右边的小字")
        let colName = String(localized: "Process", comment: "总控台：整体视图进程表表头第一列")
        let colGroup = String(localized: "Group", comment: "总控台：整体视图进程表表头第二列")
        let colMemory = String(localized: "Memory", comment: "总控台：整体视图进程表表头第三列")
        let colHistory = String(localized: "Last 24 hours", comment: "总控台：整体视图进程表表头第四列")
        let colCpu = String(localized: "CPU", comment: "总控台：整体视图进程表表头第五列")
        let colPid = String(localized: "Process ID", comment: "总控台：整体视图进程表表头第六列")
        /// **The heading for the rows in no group** (task 3119): a terminal
        /// nobody has put in one is still a terminal, and the layer says so
        /// rather than being dropped. The fact (the core's `group: ""`) is
        /// the core's; these are the host's words for it, and the same
        /// string the control room already calls a thing in no group.
        let noGroup = String(localized: "No group", comment: "总控台：整体视图进程表，不属于任何群的终端那一层的标题")

        /// The two category headings' names, **from the core's own
        /// category**: the words are the host's, and which category is
        /// which is not.
        ///
        /// **There is no heading over the terminals** (task 3113, second
        /// round): each terminal is its own group, named by the terminal
        /// itself (`U.rowName`). The case for a `terminals` heading is kept
        /// for an answer that still carries one; this core does not.
        func sectionName(_ category: String) -> String {
            switch category {
            case "chats": String(localized: "Embedded chats", comment: "总控台：整体视图进程表第二组")
            case "terminals": String(localized: "Terminals", comment: "总控台：整体视图进程表里终端那一组的标题，只有旧答复会带这一组")
            default: String(localized: "The main process", comment: "总控台：整体视图进程表第一组")
            }
        }

        /// The legend's words (task 3113, second round: **two layers**) --
        /// the main process, and the terminals, chats and workers in one
        /// band. The `chats` case is what a one-release-older answer's
        /// legend says; `terminals` is what this core sends.
        func layerName(_ name: String) -> String {
            switch name {
            case "chats": String(localized: "Embedded chats", comment: "总控台：整体视图面积图图例第二项，只有旧答复会带这一层")
            case "terminals": String(localized: "Terminals", comment: "总控台：整体视图面积图图例第二项，这一层是各终端和群聊的整棵树")
            default: String(localized: "The main process", comment: "总控台：整体视图面积图图例第一项")
            }
        }

        /// **How many of a terminal's processes the list did not show**
        /// (task 3113, second round): the number is the core's, the words
        /// are the host's.
        func moreProcesses(_ n: UInt64) -> String {
            String(format: String(localized: "and %d more processes",
                                  comment: "总控台：整体视图进程表，一个终端下面的进程只列了最重的若干个，这一行说还有多少没列"),
                   Int(n))
        }

        /// What a group's line says to a screen reader when it is closed
        /// or open: the words are the host's, the count beside them is the
        /// core's.
        let collapsed = String(localized: "collapsed", comment: "总控台：整体视图进程表，被收起的组，读屏念的值")
        let expanded = String(localized: "expanded", comment: "总控台：整体视图进程表，展开的组，读屏念的值")

        /// The rate the core worked out, with its own sign: the arrow is
        /// drawn only while it is rising, which is the core's verdict.
        func swapRate(_ slope: Int) -> String {
            String(format: String(localized: "%@ an hour", comment: "总控台：整体视图交换区那一块，每小时涨多少"),
                   ControlRoomOverall.rate(slope))
        }

        func diskLine(_ mib: UInt64?) -> String {
            String(format: String(localized: "below %@, the system starts closing apps",
                                  comment: "总控台：整体视图磁盘那一块，低于这条线时系统会开始关应用"),
                   mib.map(ControlRoomOverall.size) ?? "15 GB")
        }

        /// **The one sentence about the row that is rising**: who, how much
        /// over the window, and at what rate. Every number in it is the
        /// core's; the words around them are the translator's.
        func riseSentence(_ r: U.Rise) -> String {
            let who = r.group.map { "\(sectionName(r.category)) \($0)" } ?? sectionName(r.category)
            return String(format: String(localized: "%@ has been rising since %@: %@ in all, now %@ an hour",
                                         comment: "总控台：整体视图面积图上那条竖虚线的说明：谁在涨、从什么时候起、一共涨了多少、现在每小时多少"),
                          who, r.since ?? "", ControlRoomOverall.size(r.roseMib),
                          ControlRoomOverall.rate(r.slopeMibPerHour))
        }

        /// Tenths of a core as a reader reads them.
        func cores(_ ds: UInt64) -> String {
            String(format: "%.1f", Double(ds) / 10)
        }

        func died(_ at: String?) -> String {
            at.map { String(format: String(localized: "ended %@",
                                           comment: "总控台：整体视图进程表，已经结束的进程，参数是结束时刻"), $0) } ?? ""
        }

        /// The moment the core's `run_started` names.
        func clock(_ iso: String) -> Date? {
            ISO8601DateFormatter().date(from: iso)
        }

        /// A moment `cells` cells along the box from its left edge, written
        /// for the span: the clock for the day, the date and clock for the
        /// week.
        func stamp(_ from: Date, plusCells cells: Double, span: ControlRoomOverall.Span) -> String {
            let step = span == .day ? 300.0 : 1800.0
            let at = from.addingTimeInterval(cells * step)
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = span == .day ? "HH:mm" : "M/d HH:mm"
            return f.string(from: at)
        }
    }
}
