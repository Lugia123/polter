import SwiftUI

/// Everything the editor draws, gathered in one value.
///
/// A value rather than a live reference to the terminal: the editor is a
/// window that can outlive the tab it was opened from, and reading a dead
/// surface through a captured pointer is how that goes wrong. The window's
/// owner replaces this whenever the core says something changed, which is
/// what makes a pick made *in* the editor show up *in* the editor.
struct PersonaEditorModel: Equatable {
    /// Which terminal this is about, in the words the tab uses.
    var terminalTitle: String = ""

    var state: PersonaState = .none
    var personas: [Persona] = []

    /// Whether anything has reported the persona list at all -- a different
    /// fact from the list being empty. See `PersonaCatalog.isKnown`.
    var personasKnown: Bool = false
    var face: PersonaFace = .init()
    var inventory: HostInventory = .unknown

    /// The user put this terminal out of reach. Nothing may re-equip it,
    /// a supervisor included (roles.md §7.2). Looking is still allowed.
    var shielded: Bool = false

    var currentPersona: Persona? {
        guard let key = state.key else { return nil }
        return personas.first { $0.key == key }
    }
}

/// Holds the model for one open editor window.
///
/// SwiftUI needs something to observe; a plain value handed in at open time
/// would leave the window showing the state as it was when it opened, which
/// on this particular window means a user clicking a role and watching
/// nothing happen.
@MainActor
final class PersonaEditorState: ObservableObject {
    @Published var model: PersonaEditorModel

    init(_ model: PersonaEditorModel) {
        self.model = model
    }
}

/// Pick a role for one terminal, switch one skill or one slot by hand, and
/// see what the agent CLI has installed globally that no role covers.
///
/// The third of those is **read-only on purpose and says so on screen.**
/// roles.md §4 draws the line: Polter maintains what it handed out and only
/// shows what it did not. The inventory is there so the user can tell that
/// their archer has no argus from Polter but has it anyway, because the host
/// installed it globally -- not so that anything here can switch it off. A
/// read-only pane without that sentence printed in it sends people hunting
/// for the switch, so the sentence is in the view, not only in this comment.
struct PersonaEditorView: View {
    @ObservedObject var state: PersonaEditorState

    var onSelectPersona: (String?) -> Void
    var onToggleSkill: (PersonaFace.Entry, Bool) -> Void
    var onToggleMCP: (PersonaFace.Entry, Bool) -> Void
    var onResetToPersona: () -> Void
    var onClose: () -> Void

    private var model: PersonaEditorModel { state.model }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    choosePersona
                    handedOut
                    openingPrompt
                    onlyOnRestart
                    installed
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 600)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.terminalTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(model.state.displayName(in: model.personas)
                 ?? String(localized: "No Role", comment: "角色菜单：清掉这个终端的角色"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if model.shielded {
                caption(String(
                    localized: "Agents are kept out of this terminal, so its role cannot be changed",
                    comment: "角色菜单：护盾的终端拒绝一切换装，对总管也一样；用词跟「不让 agent 碰此终端」对齐，好让用户认出是自己勾的那一项"),
                    symbol: "lock")
            }

            // The same line the menu shows, for the same reason: a pick that
            // only takes hold on the next start must never read as one that
            // already took hold.
            if let note = model.state.hostClass.pendingRestartNote {
                caption(note, symbol: "clock.arrow.circlepath")
            }

            if model.state.key != nil && !model.state.agentPresent {
                caption(String(
                    localized: "No agent is connected here, so nothing is wearing this yet",
                    comment: "角色菜单：这个终端里没有 agent 连着 Polter，角色存着但没兑现"),
                    symbol: "person.slash")
            }

            // A file that failed to load keeps the previous one in effect
            // (contract §①) -- so the list below is real, just old, and the
            // only place the user can find out is here.
            //
            // The lead-in says which kind of trouble it is, because the two
            // ask different things of the user: fix the file, versus reopen
            // the menu. The core's own words go underneath -- a lead-in
            // without them swallows a diagnosable error, and them without a
            // lead-in is a sentence with no subject.
            if let kind = model.face.errorKind, let lead = Self.errorLead(kind) {
                caption(lead, symbol: "exclamationmark.triangle")
            }
            if let error = model.face.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: Choose a Role

    private var choosePersona: some View {
        section(String(localized: "Choose a Role", comment: "角色编辑器：分区名，选一个角色")) {
            if !model.personasKnown {
                note(String(localized: "Nothing has reported which roles exist yet",
                            comment: "角色菜单：角色清单还没接上来源，不是「一个都没定义」"))
            } else if model.personas.isEmpty {
                note(String(localized: "No roles are defined",
                            comment: "角色菜单：用户还没定义任何角色"))
            } else {
                ForEach(model.personas) { persona in
                    pickerRow(
                        title: persona.key == model.state.key
                            ? (model.state.displayName(in: model.personas) ?? persona.name)
                            : persona.name,
                        selected: persona.key == model.state.key,
                        action: { onSelectPersona(persona.key) })
                }
            }

            Divider()
            pickerRow(
                title: String(localized: "No Role", comment: "角色菜单：清掉这个终端的角色"),
                selected: model.state.key == nil,
                action: { onSelectPersona(nil) })
        }
    }

    private func pickerRow(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.shielded)
    }

    // MARK: What This Terminal Hands Out

    private var handedOut: some View {
        section(String(localized: "What This Terminal Hands Out",
                       comment: "角色编辑器：分区名，这个终端此刻实际交出去的技能与 MCP")) {
            if !model.face.isKnown {
                // Its own sentence, not the persona list's and not the
                // inventory's. Three different things can be unreported
                // here -- which personas exist, what this terminal hands
                // out, what the machine has installed -- and each one sends
                // the user somewhere different. Sharing a string between
                // them is the same collapse this pane exists to avoid.
                note(String(localized: "Nothing has reported what this terminal hands out yet",
                            comment: "角色编辑器：生效集还没接上来源，不是「什么都没交出去」"))
            } else if model.face.isEmpty {
                note(String(localized: "This terminal hands out nothing yet",
                            comment: "角色编辑器：这个终端此刻的生效集是空的"))
            } else {
                if !model.face.skills.isEmpty {
                    subheading(String(localized: "Skills", comment: "角色编辑器：分区名，技能"))
                    ForEach(model.face.skills) { entry in
                        entryRow(entry) { onToggleSkill(entry, $0) }
                    }
                }

                if !model.face.mcp.isEmpty {
                    subheading(String(localized: "MCP Servers",
                                      comment: "角色编辑器：分区名，MCP 服务器"))
                    ForEach(model.face.mcp) { entry in
                        entryRow(entry) { onToggleMCP(entry, $0) }
                    }
                }

                // Only offered once there is something to undo. An always-on
                // button reads as "this role has been changed" on a terminal
                // where nothing has been.
                if model.face.deviates {
                    Button(String(localized: "Reset to the Role",
                                  comment: "角色编辑器：把生效集恢复成角色声明的样子")) {
                        onResetToPersona()
                    }
                    .disabled(model.shielded)
                    .padding(.top, 6)
                }
            }
        }
    }

    private func entryRow(
        _ entry: PersonaFace.Entry,
        toggle: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { entry.enabled }, set: { toggle($0) })) {
                Text(entry.name)
            }
            .toggleStyle(.checkbox)
            .disabled(model.shielded)

            Spacer()

            // The slot's own state comes before the deviation badge, and
            // only two of its four states say anything here.
            //
            // `granted` and `withheld` are already on screen -- the tick box
            // says exactly that -- so repeating them would put a line on
            // every row, and the row that matters would be lost in it. That
            // is not hypothetical: `withheld` is what every slot reports
            // today, so a note there would be noise on all of them while
            // `broken` is the one nobody must miss.
            if let note = Self.slotNote(entry.slot) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.isDeviation {
                Text(entry.enabled
                     ? String(localized: "Added by hand",
                              comment: "角色编辑器：这一项不在角色声明里，是手动加上的")
                     : String(localized: "Switched off by hand",
                              comment: "角色编辑器：这一项在角色声明里，被手动关掉了"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Opening Prompt

    /// Polter's own role prompt, named rather than quoted: it is delivered
    /// through the tool surface instead of placed as a file (roles.md §2),
    /// and the text itself lives in the file the user wrote.
    @ViewBuilder
    private var openingPrompt: some View {
        if let prompt = model.currentPersona?.prompt, !prompt.isEmpty {
            section(String(localized: "Opening Prompt",
                           comment: "角色编辑器：分区名，角色自己的开场提示词")) {
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Only Applied on Restart

    @ViewBuilder
    private var onlyOnRestart: some View {
        if let hint = model.currentPersona?.hint, !hint.isEmpty {
            section(String(localized: "Only Applied on Restart",
                           comment: "角色编辑器：分区名，角色里只有重启才兑现的那一半")) {
                if let modelName = hint.model {
                    Text(verbatim: "model: \(modelName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(hint.disableHostPlugins, id: \.self) { name in
                    Text(verbatim: "− \(name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Installed on This Machine

    private var installed: some View {
        section(String(localized: "Installed on This Machine",
                       comment: "角色编辑器：分区名，这台机器上 agent CLI 全局装了什么，只读")) {
            Text(String(
                localized: "Shown so you can see what a role doesn't cover. Polter doesn't change any of this.",
                comment: "角色编辑器：只读区的说明。没有这句话用户会去找开关"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.inventory.isKnown {
                note(String(localized: "Nothing has reported what's installed here yet",
                            comment: "角色编辑器：只读清单还没接上来源，不是「什么都没装」"))
            } else {
                inventoryList(String(localized: "Plugins", comment: "角色编辑器：分区名，插件"),
                              model.inventory.plugins)
                inventoryList(String(localized: "Skills", comment: "角色编辑器：分区名，技能"),
                              model.inventory.skills)
                inventoryList(String(localized: "MCP Servers",
                                     comment: "角色编辑器：分区名，MCP 服务器"),
                              model.inventory.mcpServers)

                // Right under the number it qualifies, because on its own
                // that number is a lower bound that looks like a count.
                if !model.inventory.slotBudgetComplete {
                    caption(String(
                        localized: "Some agents' configuration couldn't be read, so this count may be low",
                        comment: "角色编辑器：槽位数旁边——有 agent 的配置没读到，这个数是下界不是真值"),
                        symbol: "questionmark.circle")
                }
            }
        }
    }

    /// One category, or the reason there is no list for it.
    ///
    /// The four cases are not decoration: "nobody checked where these live"
    /// sends the user to check a path, "there is nothing there" sends them
    /// to install something, and a failure sends them to the error. Drawn
    /// as one empty section they would send them nowhere.
    @ViewBuilder
    private func inventoryList(_ title: String, _ section: HostInventorySection) -> some View {
        subheading(title)
        switch section {
        case .unknownLocation:
            note(String(localized: "Nobody has checked where this agent keeps these yet",
                        comment: "角色编辑器：只读清单，这一类东西这家 agent 放在哪没人核实过——不是「没装」"))
        case .absent:
            note(String(localized: "Looked there, and nothing is installed",
                        comment: "角色编辑器：只读清单，路径已知、那儿确实什么都没有"))
        case .failed(let message):
            note(String(localized: "Couldn't read what's installed here",
                        comment: "角色编辑器：只读清单，读不出来；这是前缀，后面接核心给的错误原文"))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .read(let names) where names.isEmpty:
            // Same sentence as `.absent`: to the user these are one fact.
            note(String(localized: "Looked there, and nothing is installed",
                        comment: "角色编辑器：只读清单，路径已知、那儿确实什么都没有"))
        case .read(let names):
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Chrome

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Done", comment: "角色编辑器：关掉窗口")) { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subheading(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.top, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What a slot's state adds to what the tick box already says.
    ///
    /// `nil` for the two states the box covers. An unrecognised state is
    /// also `nil`: a status this build does not know is not one it should be
    /// writing a sentence about.
    static func slotNote(_ slot: PersonaFace.SlotStatus?) -> String? {
        switch slot {
        case .broken:
            // The one state `enabled` cannot express: the persona granted
            // it and the server would not come up. A user who reads that as
            // "my role didn't give it to me" goes and edits the wrong thing.
            return String(
                localized: "This server didn't start. Your role isn't what's withholding it.",
                comment: "角色编辑器：槽位 broken —— 上游服务器没起来，不是角色没给")
        case .transparent:
            // Outside Polter. Worth saying because the persona is not what
            // is deciding here, and the agent has more than this row admits.
            return String(
                localized: "Polter isn't managing this server, so the agent sees all of it",
                comment: "角色编辑器：槽位 transparent —— 在 Polter 之外，上游工具原样透传")
        case .granted, .withheld, .none:
            return nil
        }
    }

    /// The sentence that goes above the core's error text, chosen by
    /// `error_kind` rather than by matching on the message: prose is not a
    /// way to tell two failures apart.
    static func errorLead(_ kind: String) -> String? {
        switch kind {
        case "parse":
            return String(
                localized: "The roles file could not be read, so the previous one is still in use",
                comment: "角色编辑器：personas.json 没加载成功，整份没生效、用的是上一份")
        case "stale_id":
            return String(
                localized: "This menu is out of date. Close it and open it again",
                comment: "角色编辑器：菜单是按旧版生效集建的，点的那一项已经不存在了")
        default:
            return nil
        }
    }

    private func caption(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
