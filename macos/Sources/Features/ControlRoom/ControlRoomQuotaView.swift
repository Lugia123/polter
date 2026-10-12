import SwiftUI

/// The allowance block at the bottom of the group list (`control-room.md`,
/// 3.6): on an ordinary day one line, each account and how much of it is
/// used; an account at or past the limit line is opened out above it, with
/// a bar and when it comes back.
///
/// It draws a `ControlRoomQuota` and decides nothing about it. Every size
/// and colour is `ControlRoomLook`'s and every position is
/// `ControlRoomQuotaLayout`'s.
///
/// **Nothing here can be pressed.** It says how close the limit is; what to
/// do about it -- stop a group, wait, start nothing new -- is the
/// person's.
struct ControlRoomQuotaView: View {
    typealias Look = ControlRoomLook
    typealias Quota = ControlRoomQuota

    var quota: Quota
    /// Stops every motion. For still pictures.
    var still: Bool = false
    /// Whose clock a moment is written on. For still pictures.
    var timeZone: TimeZone = .current

    @Environment(\.colorScheme) private var scheme

    private var theme: Look.Theme { Look.theme(scheme) }
    private var padX: CGFloat { CGFloat(Look.Quota.paddingX) }

    var body: some View {
        let layout = ControlRoomQuotaLayout(quota: quota)
        VStack(alignment: .leading, spacing: 0) {
            theme.lineFaint.color
                .frame(height: CGFloat(Look.Line.hairline))
                .padding(.horizontal, padX)
                .padding(.bottom, CGFloat(Look.Quota.separatorSpaceBelow))
            ForEach(Array(zip(quota.alerts, layout.parts).enumerated()), id: \.offset) { _, pair in
                part(pair.0, note: pair.1.note)
                    .frame(height: pair.1.height, alignment: .top)
            }
            if let line = quota.line {
                self.line(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: layout.height, alignment: .top)
        .font(.system(size: CGFloat(Look.Font.body)))
        .monospacedDigit()
        .foregroundStyle(theme.text.color)
    }

    // MARK: Pieces

    /// The one line: the label, and each account with its number.
    private func line(_ line: Quota.Line) -> some View {
        HStack(spacing: CGFloat(Look.Quota.labelGap)) {
            Text(Quota.labelText(line.label))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            if line.entries.isEmpty {
                Text(Quota.noneYetText)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .help(Quota.noneYetHelp)
            } else {
                HStack(spacing: CGFloat(Look.Quota.entryGap)) {
                    ForEach(Array(line.entries.enumerated()), id: \.offset) { _, entry in
                        self.entry(entry)
                    }
                }
            }
        }
        .padding(.horizontal, padX)
        .frame(height: CGFloat(Look.Quota.lineHeight))
    }

    /// One account in the line: its name a step back, its number in the
    /// main colour -- unless the number is old, and then both step back and
    /// it says how old.
    private func entry(_ entry: Quota.Entry) -> some View {
        let number = Quota.entryNumber(entry)
        return (Text(Quota.name(entry.family) + " ").foregroundColor(theme.textSecondary.color)
            + Text(number).foregroundColor(numberInk(entry.state)))
            .lineLimit(1)
            .fixedSize()
            .help(Quota.help(for: entry, timeZone: timeZone))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Quota.spoken(entry))
    }

    /// The colour of what follows an account's name. The core's word for
    /// the state picks it; no number is looked at.
    private func numberInk(_ state: Quota.Entry.State) -> Color {
        switch state {
        case .fresh:
            return theme.text.color
        case .stale, .recovered, .unreadable:
            return theme.textSecondary.color
        }
    }

    /// An account opened out: which and how much in red, when it comes
    /// back at the right, the bar across, and the way out under it when the
    /// core names one.
    private func part(_ alert: Quota.Alert, note: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CGFloat(Look.Quota.alertGlyphGap)) {
                if alert.level == .out {
                    ControlRoomGlyph(shown: .trouble, still: true)
                        .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                }
                Text(Quota.alertTitle(alert))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(theme.problemTextOnRow.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: CGFloat(Look.Quota.labelGap))
                Text(Quota.whenText(alert, timeZone: timeZone))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: CGFloat(Look.Quota.alertTitleHeight))
            bar(alert)
                .padding(.top, CGFloat(Look.Quota.barSpaceAbove))
                .padding(.bottom, CGFloat(Look.Quota.barSpaceBelow))
            if note, let out = Quota.wayOutText(alert) {
                Text(out)
                    .lineLimit(1)
                    .frame(height: CGFloat(Look.Quota.noteLineHeight), alignment: .leading)
                    .padding(.bottom, CGFloat(Look.Quota.notePaddingBottom))
            }
        }
        .padding(.horizontal, padX)
        .padding(.top, CGFloat(Look.Quota.alertPaddingTop))
        .help(Quota.help(for: alert, timeZone: timeZone))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Quota.spoken(alert))
    }

    /// The bar: a track, and as much of it filled as is used. An old
    /// number's is a line round the same length and not filled, so that it
    /// does not read as a measurement taken now.
    private func bar(_ alert: Quota.Alert) -> some View {
        let radius = CGFloat(Look.Quota.barRadius)
        let height = CGFloat(Look.Quota.barHeight)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return GeometryReader { proxy in
            let filled = max(CGFloat(Look.Quota.barMinFill), proxy.size.width * CGFloat(alert.used) / 100)
            ZStack(alignment: .leading) {
                shape.fill(theme.line.color)
                if alert.stale != nil {
                    shape.strokeBorder(theme.textTertiary.color, lineWidth: CGFloat(Look.Line.stroke))
                        .frame(width: filled)
                } else {
                    shape.fill(theme.problem.color)
                        .frame(width: filled)
                }
            }
        }
        .frame(height: height)
    }
}
