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
/// status -- the glyph and the word. Not how long it has waited: that was
/// here once and told the person nothing they could act on.
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
    /// What the core says about the selected group's supervisor; nil when
    /// it says nothing, and then nothing is offered.
    var start: ControlRoomList.SupervisorStart?
    var roles: [ControlRoomList.SupervisorRole] = []
    var chooseRole: Bool = false
    /// Why the last press of "Start Supervisor" did nothing.
    var refusal: String?
    var onStart: (_ role: String?, _ cwd: String?) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(spacing: CGFloat(Look.Side.rowGap)) {
            Text(Self.words(for: detail, start: start))
                .foregroundStyle(theme.textSecondary.color)
            if case let .noSupervisor(group) = detail, let start, start.canStart {
                ControlRoomStartSupervisor(
                    start: start, roles: roles, chooseRole: chooseRole, refusal: refusal, onStart: onStart)
                    // A pick is about one group: another group starts from
                    // what the core names for it.
                    .id(group)
            }
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
    static func words(for detail: ControlRoomLending.Detail,
                      start: ControlRoomList.SupervisorStart? = nil) -> String {
        switch detail {
        case .nothingSelected:
            return String(localized: "Select a group to see its supervisor.", comment: "总控台：没有选中任何群时右栏的说明")
        case .noSupervisor:
            // Which of these it is is the core's word (`state`, `failed`).
            switch (start?.state, start?.failed) {
            case (.starting, _):
                return String(localized: "Starting the supervisor…", comment: "总控台：点了启动总管以后，总管还没连上的那一段，右栏的说明")
            case (.failed, .terminalNeverOpened):
                return String(localized: "The supervisor did not start: its tab never opened.",
                              comment: "总控台：启动总管失败，标签页没开出来")
            case (.failed, .agentNeverConnected):
                return String(localized: "The supervisor did not start: its tab opened, but no agent connected from it. Its tab shows why.",
                              comment: "总控台：启动总管失败，标签页开了但里面的 agent 没有连上 Polter")
            case (.failed, .terminalClosed):
                return String(localized: "The supervisor did not start: its tab was closed first.",
                              comment: "总控台：启动总管失败，标签页在 agent 连上之前被关掉了")
            case (.failed, _):
                return String(localized: "The supervisor did not start.", comment: "总控台：启动总管失败，没有更具体的原因")
            default:
                return String(localized: "This group has no supervisor.", comment: "总控台：选中的群没有总管时右栏的说明")
            }
        case .supervisorGone:
            return String(localized: "The supervisor's terminal is no longer open.", comment: "总控台：总管的终端已经关掉时右栏的说明")
        case .takenBack:
            return String(localized: "The supervisor's terminal is in its own tab.", comment: "总控台：终端被要回原处以后右栏的说明")
        case .terminal:
            return ""
        }
    }
}

/// What the right-hand side offers for a group with no supervisor: the role
/// and the directory one would be started in, and the button that starts
/// it (`control-room.md`, 7.5).
///
/// **This is on the right-hand side, not on a row.** A row still has
/// nothing to press but itself (`tools/control-room-rows-only-tell.py`).
///
/// Which role and which directory are the core's (`start.role`,
/// `start.cwd`) until the person picks another; what is sent is only what
/// they picked. Whether there is a choice of role to show is the core's
/// word too.
struct ControlRoomStartSupervisor: View {
    typealias Look = ControlRoomLook

    let start: ControlRoomList.SupervisorStart
    let roles: [ControlRoomList.SupervisorRole]
    let chooseRole: Bool
    let refusal: String?
    let onStart: (_ role: String?, _ cwd: String?) -> Void

    /// What the person picked; nil while they have picked nothing.
    @State private var role: String?
    @State private var cwd: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        let gap = CGFloat(Look.Side.rowItemGap)
        VStack(spacing: CGFloat(Look.Side.rowGap)) {
            if chooseRole {
                HStack(spacing: gap) {
                    Text(String(localized: "Role", comment: "角色"))
                        .foregroundStyle(theme.textSecondary.color)
                    Picker("", selection: Binding(get: { role ?? start.role ?? "" }, set: { role = $0 })) {
                        ForEach(roles) { Text($0.displayName).tag($0.key) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            HStack(spacing: gap) {
                Text(String(localized: "Directory", comment: "总控台：启动总管时，总管在哪个目录里启动"))
                    .foregroundStyle(theme.textSecondary.color)
                Text(Self.shown(cwd ?? start.cwd))
                    .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(cwd ?? start.cwd)
                Button(action: chooseDirectory) {
                    Text(String(localized: "Choose…", comment: "总控台：启动总管时，换一个目录的按钮"))
                        .foregroundStyle(theme.attentionText.color)
                }
                .buttonStyle(.plain)
            }
            Button(action: { onStart(role, cwd) }, label: {
                Text(String(localized: "Start Supervisor", comment: "总控台：没有总管的群，右栏上启动一个总管的主按钮"))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(theme.attentionText.color)
                    .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
                    .padding(.vertical, CGFloat(Look.Side.rowPaddingY))
                    .overlay(
                        RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
                            .strokeBorder(theme.attentionText.color, lineWidth: CGFloat(Look.Line.hairline)))
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            if let refusal {
                Text(refusal)
                    .foregroundStyle(theme.problemTextOnSupervisorBar.color)
            }
        }
    }

    /// The directory as it is shown: the home directory as `~`.
    static func shown(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !path.isEmpty else {
            return String(localized: "Where the tab starts", comment: "总控台：启动总管时没有可用的默认目录，新标签页在哪就在哪")
        }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let from = cwd ?? start.cwd
        if !from.isEmpty { panel.directoryURL = URL(fileURLWithPath: from, isDirectory: true) }
        panel.prompt = String(localized: "Choose", comment: "总控台：选目录面板上的确认按钮")
        panel.begin { answer in
            guard answer == .OK, let url = panel.url else { return }
            cwd = url.path
        }
    }
}
