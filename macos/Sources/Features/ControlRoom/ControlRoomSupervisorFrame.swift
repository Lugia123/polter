import SwiftUI

/// The frame a supervisor's terminal wears on the control room's right-hand
/// side (`control-room.md`, 3.5, item 6): a border all round, its top edge
/// thickened into a title bar, floating over the window's ground.
///
/// **Only the control room draws this.** The splits of an ordinary terminal
/// tab are not touched; the three frames for those are a later piece
/// (`v0.10.md`, B6), and so are the stacked tabs the design puts where this
/// title bar is.
///
/// Every size and colour is `ControlRoomLook`'s. The title is a
/// `ControlRoomList.SupervisorTitle`, which is the core's words.
struct ControlRoomSupervisorFrame<Content: View>: View {
    typealias Look = ControlRoomLook

    /// What the bar says while the frame holds a terminal.
    var title: ControlRoomList.SupervisorTitle?
    /// What it says while the frame holds a sentence: the group's name, or
    /// nothing when no group is selected.
    var caption: String?
    /// The terminal inside has the keyboard.
    var focused: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        let bezel = CGFloat(Look.Space.supervisorBezel)
        let hairline = CGFloat(Look.Line.hairline)
        let outer = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorOuter), style: .continuous)
        let inner = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorInner), style: .continuous)
        VStack(spacing: 0) {
            ControlRoomSupervisorBar(title: title, caption: caption)
                .frame(height: CGFloat(Look.Pane.barHeight))
                .padding(.horizontal, bezel + CGFloat(Look.Pane.supervisorBarPaddingX))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.terminalBackground.color)
                .clipShape(inner)
                .overlay(inner.strokeBorder(theme.supervisorTerminalEdge.color, lineWidth: hairline))
                .padding([.horizontal, .bottom], bezel)
        }
        .background(
            outer
                .fill(theme.supervisorBezel.color)
                .overlay(
                    // A highlight along the top edge only.
                    outer.strokeBorder(theme.supervisorHighlight.color, lineWidth: hairline)
                        .mask(alignment: .top) { Rectangle().frame(height: CGFloat(Look.Radius.supervisorOuter)) }
                )
        )
        // The line round it, deeper while the terminal has the keyboard.
        .background(
            outer.inset(by: -hairline)
                .strokeBorder((focused ? theme.supervisorEdgeFocused : theme.supervisorEdge).color, lineWidth: hairline)
        )
        .background(
            outer.shadowOutside(Look.Pane.supervisorFloats
                ? [(theme.supervisorShadowAlpha, Look.Pane.frameShadowBlur / 2, Look.Pane.frameShadowY)]
                : [])
        )
    }
}

/// The title bar: the name and what it is on the left; on the right its
/// status -- the glyph, the word, how long it has waited.
struct ControlRoomSupervisorBar: View {
    typealias Look = ControlRoomLook

    var title: ControlRoomList.SupervisorTitle?
    var caption: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        HStack(spacing: CGFloat(Look.Pane.barGap)) {
            if let title {
                Text(title.name)
                    .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(localized: "Supervisor", comment: "总控台：右栏总管框标题条上，名字后面说明身份的字"))
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize()
                Spacer(minLength: CGFloat(Look.Pane.barGap))
                status(title, theme: theme)
            } else {
                Text(caption ?? "")
                    .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: CGFloat(Look.Font.body)))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func status(_ title: ControlRoomList.SupervisorTitle, theme: Look.Theme) -> some View {
        if title.shown != .none || !title.word.isEmpty {
            HStack(spacing: CGFloat(Look.Side.statusWordGap)) {
                ControlRoomGlyph(shown: title.shown)
                Text(title.word)
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(wordColor(title.shown, theme: theme))
                    .fixedSize()
            }
        }
        if let minutes = title.waitedMin {
            Text(String(localized: "\(String(minutes)) min", comment: "总控台：今天累计让你等了多少分钟"))
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize()
        }
    }

    /// The colour of the status word on this bar: the table's, including
    /// where a red word is not red.
    private func wordColor(_ shown: ControlRoomList.Shown, theme: Look.Theme) -> Color {
        switch shown {
        case .needsYou, .doneUnseen: return theme.attentionText.color
        case .trouble: return theme.problemTextOnSupervisorBar.color
        case .working, .none: return theme.textSecondary.color
        }
    }
}

/// What the right-hand side says when there is no terminal on it.
struct ControlRoomDetailMessage: View {
    typealias Look = ControlRoomLook

    let detail: ControlRoomLending.Detail
    let askFor: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(spacing: CGFloat(Look.Side.rowGap)) {
            Text(Self.words(for: detail))
                .foregroundStyle(theme.textSecondary.color)
            if case .takenBack = detail {
                Button(action: askFor) {
                    Text(String(localized: "Show It Here", comment: "总控台：终端被要回原处以后，右栏上把它再放过来的按钮"))
                        .foregroundStyle(theme.attentionText.color)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: CGFloat(Look.Font.body)))
        .multilineTextAlignment(.center)
        .padding(CGFloat(Look.Space.frameToContent))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One sentence for each way of having no terminal to show. Never
    /// empty: a blank right-hand side reads as something broken.
    static func words(for detail: ControlRoomLending.Detail) -> String {
        switch detail {
        case .nothingSelected:
            return String(localized: "Select a group to see its supervisor.", comment: "总控台：没有选中任何群时右栏的说明")
        case .noSupervisor:
            return String(localized: "This group has no supervisor.", comment: "总控台：选中的群没有总管时右栏的说明")
        case .supervisorGone:
            return String(localized: "The supervisor's terminal is no longer open.", comment: "总控台：总管的终端已经关掉时右栏的说明")
        case .takenBack:
            return String(localized: "The supervisor's terminal is in its own tab.", comment: "总控台：终端被要回原处以后右栏的说明")
        case .terminal:
            return ""
        }
    }
}
