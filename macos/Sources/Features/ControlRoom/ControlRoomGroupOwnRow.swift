import SwiftUI

/// The row under the history grid on a group's performance page (task 2149,
/// handoff §6, the second of slice 2's three blocks): **this group's cost,
/// split four ways** -- a segmented bar, a four-entry legend, and a 300-point
/// card for the group's own part at the right.
///
/// **The core decides, this reads.** The four parts in MiB, whether the
/// group's own part is rising, how many tasks it has, how big its record is
/// and which process its chat is all arrive as fields (`OverallPage.render`'s
/// `groups[]`); the four widths come from `ControlRoomOverall.groupBar` and
/// the two verdicts from `ControlRoomOverall.ownCardTone`. Nothing here adds
/// a terminal up or weighs a slope
/// (`tools/control-room-hosts-do-not-decide.py`). What is local is what a
/// host is for: the words in the person's language and where the parts of
/// one row go.
///
/// **The picture is the design's `01-group-perf`** (`perf5.css`'s `.comp`):
/// the bar's box takes what is left and the card is `card_width` wide at the
/// right, the legend wraps under the bar on the lines reserved for it
/// (`group_strip.legend_rows`), and the four segments abut -- the design's
/// two-point gaps would take a constant off every segment, and the segments'
/// widths are the shares the handoff asks to be proportional.
struct ControlRoomGroupOwnRow: View {
    typealias Look = ControlRoomLook
    typealias U = ControlRoomOverall
    typealias G = ControlRoomOverall.Group
    typealias Strip = Look.GroupStrip

    var group: G

    @Environment(\.colorScheme) private var scheme

    private var theme: Look.Theme { Look.theme(scheme) }

    /// The four parts, left to right: one segment of the bar, one legend
    /// entry, one ink. **The three lists are one list here**, so that a
    /// segment and the legend entry beside it cannot come from two orders.
    private var legend: [(name: String, value: String, tone: U.Tone, ink: Look.RGBA)] {
        let p = group.parts
        let own = group.own
        let ownTone = U.ownCardTone(own)
        return [
            (words.supervisor, U.size(p.supervisorMib), .normal, theme.segSupervisor),
            (words.workers, U.size(p.workersMib), .normal, theme.segWorkers),
            (words.yours, U.size(p.yoursMib), .normal, theme.segYours),
            (words.groupItself, U.size(p.ownMib), ownTone, ownTone == .warn ? theme.stripWarn : theme.segOwn),
        ]
    }

    private var words: Words { Words(group: group) }

    var body: some View {
        let h = U.groupStripHeight
        GeometryReader { proxy in
            let at = layout(width: proxy.size.width)
            HStack(alignment: .top, spacing: CGFloat(Strip.gap)) {
                leftBox(at: at, height: h)
                    .frame(width: at.leftWidth, height: h, alignment: .topLeading)
                card(at: at)
                    .frame(width: at.cardWidth, height: h, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: h, alignment: .topLeading)
        }
        .frame(height: U.groupStripHeight)        // **Nothing here is set below the body size**, which is the smallest
        // the control room draws (the user's rule, 2026-10-18: no text
        // smaller than the system's menu face). Said once for the row, so
        // that a `Text` added later cannot pick its own size; the card's
        // value is the one that is set larger.
        .font(.system(size: CGFloat(Look.Font.body)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    // MARK: - The bar and its legend

    @ViewBuilder
    private func leftBox(at: Layout, height: CGFloat) -> some View {
        let segs = U.groupBar(group.parts, width: at.barWidth)
        VStack(alignment: .leading, spacing: 0) {
            // The title, and what a segment is, at the same line as the
            // design's `.comp .cb .h`.
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(Strip.gap)) {
                Text(words.title).fontWeight(Look.weight(Look.Font.weightEmphasis)).foregroundStyle(theme.text.color)
                Text(words.subtitle).foregroundStyle(theme.textSecondary.color)
            }
            .lineLimit(1)
            .frame(height: CGFloat(Strip.headHeight), alignment: .leading)
            // The four segments, abutting, in the bar's own rectangle.
            HStack(spacing: 0) {
                ForEach(Array(segs.enumerated()), id: \.offset) { i, r in
                    Rectangle()
                        .fill(legend[i].ink.color)
                        .frame(width: max(0, r.width), height: CGFloat(Strip.barHeight))
                }
            }
            // The bar's ground, so that a group that costs nothing still
            // shows the bar there is nothing in. `bar_radius` rounds it; the
            // segments are clipped to it.
            .frame(width: max(0, at.barWidth), height: CGFloat(Strip.barHeight), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: CGFloat(Strip.barRadius), style: .continuous).fill(theme.lineFaint.color))
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(Strip.barRadius), style: .continuous))
            .padding(.top, CGFloat(Strip.barTop))
            legendRow(at: at)
                .padding(.top, CGFloat(Strip.legendTop))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CGFloat(Strip.padX))
        .padding(.vertical, CGFloat(Strip.padY))
        .frame(width: at.leftWidth, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: CGFloat(Strip.boxRadius), style: .continuous).fill(theme.perfCard.color))
        .overlay(RoundedRectangle(cornerRadius: CGFloat(Strip.boxRadius), style: .continuous)
            .strokeBorder(theme.perfCardEdge.color, lineWidth: CGFloat(Look.Line.hairline)))
    }

    /// The four entries, wrapped onto the lines `legend_rows` reserves for
    /// them: as many as fit on a line with `legend_gap_x` between two, and
    /// the rest on the next.
    @ViewBuilder
    private func legendRow(at: Layout) -> some View {
        let lines = legendLines(width: at.barWidth)
        VStack(alignment: .leading, spacing: CGFloat(Strip.legendGapY)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: CGFloat(Strip.legendGapX)) {
                    ForEach(line, id: \.self) { i in
                        HStack(spacing: CGFloat(Strip.legendSwatchGap)) {
                            RoundedRectangle(cornerRadius: CGFloat(Strip.legendSwatchRadius), style: .continuous)
                                .fill(legend[i].ink.color)
                                .overlay(RoundedRectangle(cornerRadius: CGFloat(Strip.legendSwatchRadius), style: .continuous)
                                    .strokeBorder(i == 3 ? theme.segOwnEdge.color : .clear, lineWidth: CGFloat(Look.Line.hairline)))
                                .frame(width: CGFloat(Strip.legendSwatch), height: CGFloat(Strip.legendSwatch))
                            Text(legend[i].name).foregroundStyle(theme.textSecondary.color)
                            Text(legend[i].value)
                                .fontWeight(Look.weight(Look.Font.weightEmphasis))
                                .foregroundStyle(legend[i].tone == .warn ? theme.levelWarn2Text.color : theme.text.color)
                        }
                        .lineLimit(1)
                        .fixedSize()
                    }
                }
                .frame(height: CGFloat(Strip.legendRow), alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(height: legendBlockHeight, alignment: .topLeading)
    }

    private var legendBlockHeight: CGFloat { U.groupStripLegendHeight }

    /// **An entry goes on the next line only while the core's own four are
    /// still four**: the four entries are `Parts.inOrder`, and the wrapping
    /// is where they are drawn, not how many there are
    /// (`tools/control-room-hosts-do-not-decide.py`).
    private func legendLines(width: CGFloat) -> [[Int]] {
        let room = max(0, width)
        var lines: [[Int]] = [[]]
        var used: CGFloat = 0
        for i in legend.indices {
            let w = entryWidth(i)
            if !lines[lines.count - 1].isEmpty, used + CGFloat(Strip.legendGapX) + w > room {
                lines.append([])
                used = 0
            }
            if !lines[lines.count - 1].isEmpty { used += CGFloat(Strip.legendGapX) }
            used += w
            lines[lines.count - 1].append(i)
        }
        return lines
    }

    private func entryWidth(_ i: Int) -> CGFloat {
        // The face the legend is actually drawn in: the body size, and the
        // value at the emphasis weight. Measured through `SafeFace` and
        // `SafeTextMeasure`, as every measurement in the control room is --
        // a measurement straight at CoreText took the app down once (task
        // 1718, 1753).
        let face = SafeFace(size: CGFloat(Look.Font.body))
        let strong = SafeFace(size: CGFloat(Look.Font.body), weight: .semibold)
        let dot = CGFloat(Strip.legendSwatch) + CGFloat(Strip.legendSwatchGap)
        // Between a name and its number: the design puts them in one
        // `inline-flex` with no gap of its own, so this is the one space a
        // reader needs and not a designed number.
        let gap: CGFloat = 4
        return dot + SafeTextMeasure.width(legend[i].name, in: face).rounded(.up) + gap
            + SafeTextMeasure.width(legend[i].value, in: strong).rounded(.up)
    }

    // MARK: - The group-itself card

    @ViewBuilder
    private func card(at: Layout) -> some View {
        let tone = U.ownCardTone(group.own)
        let warn = tone == .warn
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(Strip.gap)) {
                Text(words.groupItself).fontWeight(Look.weight(Look.Font.weightEmphasis)).foregroundStyle(theme.text.color)
                Spacer(minLength: 0)
                // **The tag is the core's verdict and not a second reading**:
                // drawn only while `own.growth.rising` is true, and it is what
                // the card's ground turns orange for.
                if warn {
                    Text(words.rising)
                        .fontWeight(Look.weight(Look.Font.weightEmphasis))
                        .foregroundStyle(theme.levelWarn2Text.color)
                        .padding(.horizontal, CGFloat(Strip.tagPadX))
                        .frame(height: CGFloat(Strip.tagHeight))
                        .background(RoundedRectangle(cornerRadius: CGFloat(Strip.tagRadius), style: .continuous).fill(theme.stripWarn.color))
                }
            }
            .lineLimit(1)
            .frame(height: CGFloat(Strip.tagHeight), alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(Strip.gap)) {
                Text(U.size(group.own.chatMib))
                    .font(.system(size: CGFloat(Look.PerfCard.fontValue), weight: .semibold))
                    .foregroundStyle(theme.text.color)
                Text(words.rate(group.own))                    .foregroundStyle(warn ? theme.levelWarn2Text.color : theme.textSecondary.color)
            }
            .lineLimit(1)
            .frame(height: CGFloat(Strip.cardValueHeight), alignment: .leading)
            .padding(.top, CGFloat(Strip.cardLineGap))
            foot(words.foot1)
            foot(words.foot2)
                .padding(.top, CGFloat(Strip.cardFootGap))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CGFloat(Strip.padX))
        .padding(.vertical, CGFloat(Strip.padY))
        .frame(width: at.cardWidth, height: U.groupStripHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: CGFloat(Strip.cardRadius), style: .continuous).fill(theme.perfCard.color))
        .overlay(RoundedRectangle(cornerRadius: CGFloat(Strip.cardRadius), style: .continuous)
            .strokeBorder(warn ? theme.stripWarnEdge.color : theme.perfCardEdge.color,
                          lineWidth: CGFloat(Look.Line.hairline)))
    }

    private func foot(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: CGFloat(Strip.legendRow), alignment: .leading)
    }

    // MARK: - Words and place

    /// The row's own two widths, from the look: the card is `card_width` at
    /// the right and the bar's box takes the rest. **One place**, so that
    /// the HStack's two frames and the bar's own rectangle cannot be worked
    /// out from two readings (the rule `ControlRoomPerfLayout` follows for
    /// the page).
    private struct Layout {
        var leftWidth: CGFloat
        var cardWidth: CGFloat
        var barWidth: CGFloat
    }

    private func layout(width: CGFloat) -> Layout {
        let w = max(0, width)
        let card = min(CGFloat(Strip.cardWidth), w)
        let left = max(0, w - card - CGFloat(Strip.gap))
        return Layout(leftWidth: left, cardWidth: card, barWidth: max(0, left - 2 * CGFloat(Strip.padX)))
    }

    /// Every word this row says, in the person's language. **A struct of its
    /// own so that the words are one place**: the legend's names are drawn
    /// three times over (in the bar's legend, in the card and in the
    /// accessibility label) and a second copy is a second answer.
    private struct Words {
        let title = String(localized: "This group's cost", comment: "总控台：群性能页分段条上面的标题")
        let subtitle = String(localized: "GB, one segment each, width by memory", comment: "总控台：群性能页分段条标题右边的小字，说明一段是什么")
        let supervisor = String(localized: "Supervisor", comment: "总控台：群性能页分段条图例，总管的终端")
        let workers = String(localized: "Workers", comment: "总控台：群性能页分段条图例，这个群的 worker 加起来")
        let yours = String(localized: "Your terminals", comment: "总控台：群性能页分段条图例，用户自己在这个群里的终端")
        let groupItself = String(localized: "The group itself", comment: "总控台：群性能页分段条图例，也是右边那张卡的标题")
        let rising = String(localized: "Rising", comment: "总控台：群性能页「群自己」卡右上角，在涨时的小标签")
        /// The direction mark is the core's verdict; the words after it are
        /// the translator's.
        func rate(_ own: U.Own) -> String {
            let mark = own.rising ? U.risingMark : "→"
            return mark + " " + String(format: String(localized: "%@ an hour", comment: "总控台：群性能页「群自己」卡上的涨速，前面已经有一个方向箭头，参数是每小时涨了多少"),
                                        U.rate(own.slopeMibPerHour))
        }
        let foot1: String
        let foot2: String

        init(group: G) {
            let own = group.own
            if own.rising, let since = own.since {
                foot1 = String(format: String(localized: "Embedded chat %@ · rising since %@", comment: "总控台：群性能页「群自己」卡，第一行脚注，在涨时：内嵌群聊占多少、从几点起一直在涨"),
                               U.size(own.chatMib), since)
            } else if let pid = own.chatPid {
                foot1 = String(format: String(localized: "Embedded chat %@ · process %d", comment: "总控台：群性能页「群自己」卡，第一行脚注，不在涨时：内嵌群聊占多少、进程号"),
                               U.size(own.chatMib), Int(pid))
            } else {
                foot1 = String(localized: "No embedded chat is running", comment: "总控台：群性能页「群自己」卡，这个群没有内嵌群聊在跑")
            }
            foot2 = String(format: String(localized: "Tasks %d (%d open) · Group record %@", comment: "总控台：群性能页「群自己」卡，第二行脚注：任务总数、开着的、群记录大小"),
                           Int(own.tasks), Int(own.tasksOpen), U.record(own.recordBytes))
        }
    }

    /// The words and the numbers as one line, for a reader who cannot see
    /// the bar: the four parts and the card's own numbers.
    private var accessibility: String {
        var out = "\(words.title). "
        for entry in legend {
            out += "\(entry.name) \(entry.value). "
        }
        out += "\(words.groupItself) \(U.size(group.own.chatMib)). \(words.foot1) \(words.foot2)"
        return out
    }
}
