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
    /// The last frame the terminal drew here before the person took it
    /// back; nil when it has not been drawn here.
    var lastFrame: CGImage?
    var onStart: (_ role: String?, _ cwd: String?, _ session: ControlRoomStartChoice.Session?, _ cli: String?) -> Void = { _, _, _, _ in }
    /// Go to the tab of the terminal a supervisor is being started in.
    var goToTerminal: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if case .takenBack = detail {
            // The terminal is somewhere else: the one case of having none
            // where a press brings it here.
            ControlRoomElsewhere(
                frame: lastFrame,
                sentence: Self.words(for: detail, start: start, alone: alone),
                action: ControlRoomElsewhere.switchHere,
                perform: askFor)
                // The frame's inner corners, as the terminal itself has.
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorInner), style: .continuous))
        } else {
            sentence
        }
    }

    /// Every other way of having no terminal: a sentence, and for a group
    /// with no supervisor what starts one.
    ///
    /// **What does not fit scrolls here.** The window does not grow to
    /// hold it and is not kept from being made smaller by it
    /// (`ControlRoomWindowSize`): on a narrow right-hand side the
    /// sentences wrap to many lines, and those are reached by scrolling.
    /// With room to spare it sits in the middle, as it always did.
    private var sentence: some View {
        GeometryReader { place in
            ScrollView(.vertical) {
                words
                    .frame(maxWidth: .infinity, minHeight: place.size.height)
            }
        }
    }

    private var words: some View {
        let theme = Look.theme(scheme)
        return VStack(spacing: CGFloat(Look.Side.rowGap)) {
            Text(Self.words(for: detail, start: start, alone: alone))
                .foregroundStyle(theme.textSecondary.color)
            if case .noSupervisor = detail, let start, start.state == .starting, start.asking,
               let terminal = start.terminal {
                Button(String(localized: "Go to Its Tab", comment: "总控台：总管在自己的标签页里等用户回答问题时，右栏的按钮：跳到那个标签页")) {
                    goToTerminal(terminal)
                }
            }
            if case let .noSupervisor(group) = detail, let start, start.canStart {
                ControlRoomStartSupervisor(
                    start: start, project: ProjectLink.latest?.groups[group],
                    roles: roles, chooseRole: chooseRole, refusal: refusal, onStart: onStart)
                    // A pick is about one group: another group starts from
                    // what the core names for it.
                    .id(group)
            }
        }
        .font(.system(size: CGFloat(Look.Font.body)))
        .multilineTextAlignment(.center)
        .padding(CGFloat(Look.Space.frameToContent))
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
///
/// Under the directory it says what the group's last supervisor was, when
/// the core has a record of one, and -- only when the core says that
/// supervisor's session can be gone on with -- offers going on with it or
/// starting a new one. When it cannot, a sentence says why instead
/// (`ControlRoomStartChoice`).
struct ControlRoomStartSupervisor: View {
    typealias Look = ControlRoomLook
    typealias Choice = ControlRoomStartChoice

    let start: ControlRoomList.SupervisorStart
    /// What the core says of this group's project; nil when it says
    /// nothing. Starting opens the project when it says so
    /// (`ProjectLink.startTitle`), and then the directory is not asked for:
    /// the supervisor's pane has its own.
    let project: ProjectLink.GroupProject?
    let roles: [ControlRoomList.SupervisorRole]
    let chooseRole: Bool
    let refusal: String?
    let onStart: (_ role: String?, _ cwd: String?, _ session: ControlRoomStartChoice.Session?, _ cli: String?) -> Void

    /// What the person picked; nil while they have picked nothing.
    @State private var role: String?
    @State private var cwd: String?
    @State private var session: ControlRoomStartChoice.Session?
    @State private var cli: String?

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
            if project?.start != .project {
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
            }
            if let parts = Choice.lastSupervisorParts(start, startingIn: cwd ?? start.cwd) {
                // The CLI's name not read yet (task 1741): a place where it
                // will be, never its key.
                HStack(spacing: 0) {
                    Text(parts.before)
                    nameBar(theme)
                    Text(parts.after)
                }
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityElement(children: .combine)
            } else if let said = Choice.lastSupervisorText(start, startingIn: cwd ?? start.cwd) {
                Text(said)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let choice = Choice.cliChoice(start, roles: roles, role: role, picked: cli)
            if choice.shown {
                // One grid, so the CLI rings and the session rings share a
                // left edge (01a/01b): picking another CLI greys a ring and
                // moves none.
                Grid(alignment: .leading, horizontalSpacing: gap, verticalSpacing: 0) {
                    GridRow {
                        Text(Choice.cliRowText)
                            .foregroundStyle(theme.textSecondary.color)
                        cliRings(choice, theme)
                    }
                    if choice.resume != .hidden {
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            sessionSlot(choice, theme)
                        }
                    }
                }
            } else if choice.resume != .hidden {
                sessionSlot(choice, theme)
            }
            if let why = Choice.resumeSaid(choice, last: start.last) {
                Text(why)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Not while the last session is still looked for, unless a new
            // one was picked (task 1741): `Choice.startEnabled`.
            let canPress = Choice.startEnabled(choice, picked: session)
            let ink = canPress ? theme.attentionText.color : theme.textTertiary.color
            Button(action: {
                // The CLI the choice has on, whenever it has one: the same
                // the core would pick when it is the core's, and the
                // person's when they picked (`scene::cli_choice`).
                onStart(role, cwd, Choice.sessionSent(choice, picked: session), choice.picked)
            }, label: {
                Text(ProjectLink.startTitle(project))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(ink)
                    .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
                    .padding(.vertical, CGFloat(Look.Side.rowPaddingY))
                    .overlay(
                        RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
                            .strokeBorder(ink, lineWidth: CGFloat(Look.Line.hairline)))
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .disabled(!canPress)
            if let note = ProjectLink.startNote(project) {
                Text(note)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refusal {
                Text(refusal)
                    .foregroundStyle(theme.problemTextOnSupervisorBar.color)
            }
        }
    }

    /// Where the sessions are, always two lines high so that nothing under
    /// it moves when the look for the last one ends (task 1741): the two
    /// sessions; while looking, a spinner and "Looking for…" over "New
    /// session"; looked for and not to be had, "Didn't find…" -- why, on
    /// hover and to a screen reader -- over "New session", on.
    @ViewBuilder
    private func sessionSlot(_ choice: Choice.CliChoice, _ theme: Look.Theme) -> some View {
        let gap = CGFloat(Look.Side.rowItemGap)
        let mark = CGFloat(Look.Side.glyph)
        let row = CGFloat(Look.Side.quietRowHeight)
        switch choice.resume {
        case .checking, .missing:
            let looking = choice.resume == .checking
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: gap) {
                    if looking {
                        ControlRoomGlyph(shown: .working, size: mark)
                    } else {
                        Color.clear.frame(width: mark, height: mark)
                    }
                    Text(looking ? Choice.lookingText : Choice.missingText)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .frame(height: row)
                .help(Choice.resumeTooltip(choice, last: start.last) ?? "")
                .accessibilityElement(children: .combine)
                .accessibilityHint(Choice.resumeTooltip(choice, last: start.last) ?? "")
                radio(Choice.optionText(.new), on: looking ? session == .new : true, off: false, theme) {
                    session = .new
                }
            }
        default:
            sessionChoice(theme, greyed: choice.resume == .greyed)
        }
    }

    /// A CLI's name not read yet (task 1741): a bar where it will be.
    private func nameBar(_ theme: Look.Theme, width: CGFloat = 72) -> some View {
        RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row) / 2, style: .continuous)
            .fill(theme.lineFaint.color)
            .frame(width: width, height: CGFloat(Look.Font.body) * 0.8)
            .accessibilityLabel(Choice.lookingText)
    }

    /// The two sessions a start can use, one to a line, the one in use
    /// marked: a ring filled in the attention colour, never a grey ground.
    /// `greyed` (01b): the CLI picked cannot go on with the last session,
    /// so that option stays where it was, greyed and not pickable, and the
    /// new one is the one in use -- the reason is the line under it.
    private func sessionChoice(_ theme: Look.Theme, greyed: Bool) -> some View {
        let picked = greyed ? .new : (session ?? .last)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Choice.Session.allCases, id: \.self) { one in
                let off = greyed && one == .last
                radio(Choice.optionText(one), on: one == picked, off: off, theme) { session = one }
                    .accessibilityHint(off ? (Choice.resumeSaid(
                        Choice.cliChoice(start, roles: roles, role: role, picked: cli), last: start.last) ?? "") : "")
            }
        }
    }

    /// One ring per CLI the role can start in (01a), the same rings as the
    /// sessions below, so the two read as one group.
    private func cliRings(_ choice: Choice.CliChoice, _ theme: Look.Theme) -> some View {
        HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
            ForEach(choice.clis, id: \.key) { one in
                // Its name not read yet (task 1741): a bar, never the key.
                radio(Choice.cliName(key: one.key, label: one.label) ?? one.key,
                      on: one.key == choice.picked, off: false, theme, pending: !start.clisRead) { cli = one.key }
            }
        }
    }

    /// One ring and its words: filled in the attention colour when on,
    /// greyed and inert when `off`.
    /// `pending`: the words are a name not read yet (task 1741), drawn as
    /// a bar where it will be.
    private func radio(_ text: String, on: Bool, off: Bool, _ theme: Look.Theme, pending: Bool = false,
                       pick: @escaping () -> Void) -> some View {
        let mark = CGFloat(Look.Side.glyph)
        return Button(action: pick, label: {
            HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
                Circle()
                    .strokeBorder(
                        on ? theme.attentionText.color : (off ? theme.textTertiary.color : theme.textSecondary.color),
                        lineWidth: on ? mark / 3 : CGFloat(Look.Line.stroke))
                    .frame(width: mark, height: mark)
                if pending {
                    nameBar(theme, width: 56)
                } else {
                    Text(text)
                        .foregroundStyle(off ? theme.textTertiary.color : theme.text.color)
                }
            }
            .frame(height: CGFloat(Look.Side.quietRowHeight))
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .disabled(off)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The directory as it is shown: the home directory as `~`.
    static func shown(_ path: String, home: String = NSHomeDirectory()) -> String {
        ControlRoomStartChoice.shownDirectory(path, home: home)
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
