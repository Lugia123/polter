import SwiftUI

/// Where a page gets the overall reading: the `overall` page, asked the way
/// the performance page asks for its own (task 2149, handoff §6). **A page
/// and not a field of the control room's snapshot**, so that this row can be
/// added on the mac today without changing what both hosts are held to by
/// `tools/control-room-hosts-agree.py` -- Windows draws the row and the
/// group strip in the last slice.
///
/// Asked while the control room is open and the application is active, and
/// not otherwise: a control room nobody is looking at does not wake
/// (`dev-docs/poltergeist/control-room.md`, 13.2).
///
/// The door is handed in as `ControlRoomOverall.Ask` rather than as the
/// real `ControlRoomPageSource`: that type names `GhosttyKit`, and this file
/// is built into `tools/mac-logic-tests` as well as into the application
/// (`tools/mac-logic-tests.json`). The controller closes the gap.
final class ControlRoomOverallFeed: ObservableObject {
    @Published private(set) var answer: ControlRoomOverall.Answer?

    private var timer: Timer?
    private var period: TimeInterval = 2
    private var said: String?
    private let ask: ControlRoomOverall.Ask

    /// **The whole of Polter.** The left panel's bottom line and the overall
    /// view ask this one.
    static let wholeRequest = "{\"page\":\"overall\"}"

    /// The request, which a page about one group sets to the same page with
    /// a group named (`ControlRoomGroupStrip.request`): the strip under the
    /// group page's grid reads the same reading the overall view draws,
    /// taken from the same place.
    var request = wholeRequest

    init(ask: @escaping ControlRoomOverall.Ask) {
        self.ask = ask
    }

    func start() {
        arm(period)
        Ghostty.logger.notice("control room: an overall reading is in sight; asking every \(self.period)s")
        fetch()
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        Ghostty.logger.notice("control room: the overall reading is out of sight; its timer is stopped")
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
        guard NSApp.isActive else { return }
        switch ask(request) {
        case let .answer(text):
            answer = (try? ControlRoomOverall.decode(Data(text.utf8))) ?? answer
            said = nil
            Ghostty.logger.notice("control room: the overall reading has an answer")
        case .notReady:
            // **"No answer yet" is not a fault and is not written down as
            // one**: before the first reading the core answers nothing, and
            // this row is simply not there.
            break
        case let .refused(why):
            // A refusal with words, said once each time the words change: a
            // line every two seconds saying the same is not a report.
            guard why != said else { return }
            said = why
            Ghostty.logger.notice("control room: the overall reading was refused (\(why, privacy: .public))")
        }
    }
}

/// The left panel's bottom line (task 2149, handoff §6): the application's
/// own cost and the machine's swap and free disk, and a small curve.
///
/// **The words are the host's and the verdicts are the core's**: which of
/// the numbers is in the warning ink, and whether the disk part is in the
/// bad one, arrive as `rising` and `diskLow` (`ControlRoomOverall`).
///
/// **A press puts the overall view on the right** (slice 2): the row is the
/// entry to it, and it says so by the mark at its left edge while that view
/// is the one in front -- the same chip-and-rail the group rows use.
struct ControlRoomOverallRow: View {
    typealias Look = ControlRoomLook
    typealias Entry = ControlRoomOverall.Entry
    typealias Layout = ControlRoomOverall.EntryLayout

    var answer: ControlRoomOverall.Answer
    var width: CGFloat
    /// **This row is the one in front**: the overall view is on the right
    /// side. The right side then shows no group's terminal, so nothing is
    /// hidden by this -- the same reason a group's row marks itself.
    var selected = false
    /// Open the overall view (or come back to the group, when this is the
    /// row already in front and the press is a second one).
    var onPress: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    private var theme: Look.Theme { Look.theme(scheme) }

    var body: some View {
        let e = ControlRoomOverall.entry(answer)
        let at = ControlRoomOverall.entryLayout(width: width)
        let curve = ControlRoomOverall.curve(answer.machine, nowS: answer.polter.series.nowS, rect: at.curve)
        ZStack(alignment: .topLeading) {
            // The chip's ground while this row is the one in front: the
            // design's selected row.
            if selected {
                RoundedRectangle(cornerRadius: CGFloat(Look.OverallEntry.radius), style: .continuous)
                    .fill(theme.perfCard.color)
                    .frame(width: at.chip.width, height: at.chip.height)
            }
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(Look.OverallEntry.gap)) {
                Text(e.app).fontWeight(Look.weight(Look.Font.weightEmphasis)).foregroundStyle(theme.text.color)
                HStack(alignment: .firstTextBaseline, spacing: CGFloat(Look.OverallEntry.gap) / 2) {
                    Text(e.size)
                        .foregroundStyle(e.rising ? theme.levelWarn1.color : theme.text.color)
                        .fontWeight(e.rising ? Look.weight(Look.Font.weightEmphasis) : .regular)
                    // The design's `.up`: the mark is there while the swap is
                    // rising, and it is the core's verdict that puts it there.
                    if e.rising {
                        Text(ControlRoomOverall.risingMark)
                            .foregroundStyle(theme.levelWarn1.color)
                            .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    }
                }
            }
            .lineLimit(1)
            .frame(width: at.line1.width, height: at.line1.height, alignment: .leading)
            .offset(x: at.line1.minX, y: at.line1.minY)
            diskLine(e, at: at, theme: theme)
            if curve.line.count >= 2 {
                Path { p in p.addLines(curve.line) }
                    .stroke(e.rising ? theme.levelWarn1.color : theme.line.color,
                            style: StrokeStyle(lineWidth: CGFloat(Look.Line.stroke), lineCap: .round, lineJoin: .round))
                    .frame(width: at.curve.width, height: at.curve.height)
                    .offset(x: at.curve.minX, y: at.curve.minY)
            }
        }
        .frame(width: at.chip.width, height: at.chip.height, alignment: .topLeading)
        .offset(x: at.chip.minX)
        // **The rail at the left edge while this row is the one in front**,
        // which is what the design draws for the selected row and what the
        // group rows' chip says in their own way.
        .overlay(alignment: .topLeading) {
            if selected {
                RoundedRectangle(cornerRadius: CGFloat(Look.OverallEntry.railRadius), style: .continuous)
                    .fill(theme.text.color)
                    .frame(width: at.rail.width, height: at.rail.height)
                    .offset(x: at.rail.minX, y: at.rail.minY)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onPress() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(e.app) \(e.size). \(e.machine)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The second line, with the disk's own number in the bad ink when the
    /// core says the disk is under its line. **Split where the core's own
    /// sentence has that number in it**, so the words stay one string a
    /// translator places; the rest of the line is the secondary ink.
    @ViewBuilder
    private func diskLine(_ e: Entry, at: Layout, theme: Look.Theme) -> some View {
        let disk = answer.machine.diskFreeMib.map(ControlRoomOverall.size) ?? ""
        let ink = e.diskLow && e.saysDisk ? theme.levelKilled : theme.textSecondary
        Group {
            if e.saysDisk, let r = e.machine.range(of: disk) {
                HStack(spacing: 0) {
                    Text(String(e.machine[e.machine.startIndex..<r.lowerBound])).foregroundStyle(theme.textSecondary.color)
                    Text(disk).foregroundStyle(ink.color)
                    Text(String(e.machine[r.upperBound...])).foregroundStyle(theme.textSecondary.color)
                }
                .lineLimit(1)
            } else {
                Text(e.machine).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            }
        }
        .frame(width: at.line2.width, height: at.line2.height, alignment: .leading)
        .offset(x: at.line2.minX, y: at.line2.minY)
    }
}
