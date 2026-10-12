import SwiftUI

/// The frame a supervisor's terminal wears on the control room's right-hand
/// side (`control-room.md`, 3.5, item 6): a border all round, its top edge
/// thickened into a title bar, floating over the window's ground.
///
/// **The frame itself is `PaneFrameView`**, which the panes of a split
/// terminal tab draw too (`PaneFrameSplit`); this is that view as a
/// supervisor's, with the design's terminal ground inside. The stacked
/// tabs the design puts where the title bar is are a later piece.
///
/// The title is a `ControlRoomList.SupervisorTitle`, which is the core's
/// words.
struct ControlRoomSupervisorFrame<Content: View>: View {
    /// What the bar says while the frame holds a terminal.
    var title: ControlRoomList.SupervisorTitle?
    /// What it says while the frame holds a sentence: the group's name, or
    /// nothing when no group is selected.
    var caption: String?
    /// The terminal inside has the keyboard.
    var focused: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        PaneFrameView(wears: .supervisor, title: title.map(PaneFrame.Title.init), caption: caption, focused: focused, content: content)
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
    /// The selected row is one terminal on its own, not a group: the
    /// sentences are about that terminal.
    var alone: Bool = false
    var onStart: (_ role: String?, _ cwd: String?) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(spacing: CGFloat(Look.Side.rowGap)) {
            Text(Self.words(for: detail, start: start, alone: alone))
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

    /// One sentence for each way of having no terminal to show
    /// (`ControlRoomLending.words`).
    static func words(for detail: ControlRoomLending.Detail,
                      start: ControlRoomList.SupervisorStart? = nil, alone: Bool = false) -> String {
        ControlRoomLending.words(for: detail, start: start, alone: alone)
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
