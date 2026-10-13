import AppKit
import SwiftUI

/// The editing state of the role library window: which role is selected,
/// the copy being edited, and whether it differs from what was saved.
///
/// A copy rather than editing in place, because the library is the core's
/// and changes only when a save succeeds. A field typed into and never saved
/// must not look saved -- in the list, in the launch menu, or anywhere else.
@MainActor
final class RoleLibraryEditor: ObservableObject {
    @Published var selection: String?
    @Published var draft: Role?
    @Published private(set) var original: Role?
    @Published var isNew = false
    @Published var activeCli: String?
    @Published var status: String?

    /// Which part of the role is on screen. Kept across roles on purpose:
    /// somebody going down the list tuning MCP servers wants to stay on
    /// the MCP tab.
    @Published var tab: RoleEditorTab = .basics

    /// Whether the key field still follows the name. It stops the moment
    /// the person types a key of their own.
    @Published var keyFollowsName = true

    /// The official skill on screen, when it is one of those and not a
    /// role: its name, and its whole text as it is being edited.
    @Published private(set) var skill: String?
    @Published var skillText = ""
    @Published private(set) var skillSaved = ""

    let library: RoleLibrary

    init(library: RoleLibrary) {
        self.library = library
    }

    var isDirty: Bool {
        if skill != nil { return skillText != skillSaved }
        guard let draft else { return false }
        return isNew || draft != original
    }

    // MARK: Selection

    /// Select a role, asking first when leaving unsaved changes behind.
    func select(_ key: String?) {
        guard key != draft?.key || isNew || skill != nil else { return }
        // Cancelled: the list draws its highlight from `selection`, which
        // has not moved, so there is nothing to put back.
        guard confirmLeavingDraft() else { return }
        load(key)
    }

    /// Put an official skill on screen in place of a role.
    func selectSkill(_ name: String) {
        guard name != skill, confirmLeavingDraft() else { return }
        load(nil)
        loadSkill(name)
    }

    private func loadSkill(_ name: String) {
        let text = library.skills.skills.first { $0.name == name }?.source ?? ""
        skill = name
        skillText = text
        skillSaved = text
    }

    var selectedSkill: OfficialSkill? {
        skill.flatMap { name in library.skills.skills.first { $0.name == name } }
    }

    private func load(_ key: String?) {
        skill = nil
        selection = key
        isNew = false
        status = nil
        let role = key.flatMap { k in library.catalog.roles.first { $0.key == k } }
        original = role
        draft = role
        activeCli = role?.clis.first?.cli
    }

    /// After the library changed underneath: keep the draft, but refresh
    /// what "saved" means for it, and drop a selection that is gone.
    func libraryChanged() {
        if let name = skill {
            if !isDirty { loadSkill(name) }
            return
        }
        guard !isNew, let key = draft?.key ?? selection else { return }
        if let fresh = library.catalog.roles.first(where: { $0.key == key }) {
            if !isDirty { draft = fresh }
            original = fresh
        } else if !isDirty {
            load(nil)
        }
    }

    /// True when it is fine to throw the draft away. The same question the
    /// settings window asks when leaving the section or closing.
    private func confirmLeavingDraft() -> Bool {
        SettingsUnsaved.confirmLeaving(
            self,
            message: String(localized: "Save changes to this role?", comment: "角色库：切换/关闭前有未保存修改"))
    }

    // MARK: Editing

    func newRole() {
        guard confirmLeavingDraft() else { return }
        let taken = Set(library.catalog.roles.map(\.key))
        let name = String(localized: "New Role", comment: "角色库：新建角色的默认名字")
        var role = Role(key: Role.suggestedKey(for: "", avoiding: taken), name: name)
        // The first CLI there is, so that the list to pick from is on the
        // screen straight away instead of behind one more click.
        if let first = library.clis.clis.first {
            role.clis = [RoleCliChoice(cli: first.key)]
        }
        selection = nil
        isNew = true
        keyFollowsName = true
        original = nil
        draft = role
        activeCli = role.clis.first?.cli
        status = nil
    }

    func duplicate() {
        guard let source = draft, confirmLeavingDraft() else { return }
        let taken = Set(library.catalog.roles.map(\.key))
        var role = source
        // A copy of a built-in role is the user's: theirs to change, and
        // saved under a key of its own.
        role.builtin = false
        role.official = nil
        role.name = String(format: String(localized: "%@ Copy", comment: "角色库：复制角色后的默认名字，%@ 是原名"), source.displayName)
        role.summary = source.displaySummary
        role.key = Role.suggestedKey(for: source.key, avoiding: taken)
        selection = nil
        isNew = true
        keyFollowsName = false
        original = nil
        draft = role
        activeCli = role.clis.first?.cli
        status = nil
    }

    func nameChanged() {
        guard isNew, keyFollowsName, let name = draft?.name else { return }
        let taken = Set(library.catalog.roles.map(\.key))
        draft?.key = Role.suggestedKey(for: name, avoiding: taken)
    }

    func setCli(_ cli: String, used: Bool) {
        guard var role = draft else { return }
        if used {
            if role.choice(for: cli) == nil { role.clis.append(RoleCliChoice(cli: cli)) }
            activeCli = cli
        } else {
            role.clis.removeAll { $0.cli == cli }
            if activeCli == cli { activeCli = role.clis.first?.cli }
        }
        draft = role
    }

    func updateChoice(_ cli: String, _ change: (inout RoleCliChoice) -> Void) {
        guard var role = draft, let i = role.clis.firstIndex(where: { $0.cli == cli }) else { return }
        change(&role.clis[i])
        draft = role
    }

    // MARK: Saving

    @discardableResult
    func save() -> Bool {
        if let name = skill {
            if let error = library.putSkill(name, text: skillText) {
                status = error
                return false
            }
            status = nil
            loadSkill(name)
            return true
        }
        guard let role = draft else { return true }
        if isNew && library.catalog.roles.contains(where: { $0.key == role.key }) {
            status = String(localized: "Another role already uses this key.", comment: "角色库：新建角色的 key 与已有角色重复")
            return false
        }
        if let error = library.put(role) {
            status = error
            return false
        }
        isNew = false
        status = nil
        selection = role.key
        original = library.catalog.roles.first { $0.key == role.key } ?? role
        draft = original
        return true
    }

    func revert() {
        if let name = skill {
            status = nil
            loadSkill(name)
        } else if isNew {
            load(nil)
        } else {
            load(draft?.key)
        }
    }

    func delete() {
        guard let role = draft, !role.builtin else { return }
        if isNew {
            load(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Delete the role \"%@\"?", comment: "角色库：删除确认，%@ 是角色名"), role.name)
        alert.informativeText = String(localized: "Terminals wearing it are taken out of it. Agents already running keep running.", comment: "角色库：删除角色的后果")
        alert.addButton(withTitle: String(localized: "Delete", comment: "角色库：删除按钮"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "角色库：取消"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let error = library.delete(role.key) {
            status = error
            return
        }
        load(nil)
    }
}

// MARK: Official roles and skills

extension RoleLibraryEditor {
    /// What "Restore Factory Settings" would act on: an official role or
    /// an official skill that has been changed. Nil when there is nothing
    /// to put back, which is when the button is greyed.
    var restorable: RoleOfficial? {
        let official = skill != nil ? selectedSkill?.official : (isNew ? nil : original?.official)
        return official?.canRestore == true ? official : nil
    }

    /// Whether the thing on screen is one "Restore Factory Settings" is
    /// about at all; the button is only there when it is.
    var showsRestore: Bool {
        skill != nil || (!isNew && draft?.builtin == true)
    }

    private func confirm(_ message: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel", comment: "角色库：取消"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func restore() {
        let button = String(localized: "Restore", comment: "角色库：恢复出厂设置确认框里的确认按钮")
        if let name = skill {
            guard confirm(
                String(format: String(localized: "Restore \"%@\" to factory settings?", comment: "角色库：恢复出厂设置的确认，%@ 是角色名或 skill 名"), name),
                String(localized: "Your changes to it are removed, along with anything typed here and not saved. This can't be undone.", comment: "角色库：恢复出厂设置的后果"),
                button: button) else { return }
            status = library.restoreSkill(name)
            loadSkill(name)
            return
        }
        guard let role = original, role.builtin else { return }
        guard confirm(
            String(format: String(localized: "Restore \"%@\" to factory settings?", comment: "角色库：恢复出厂设置的确认，%@ 是角色名或 skill 名"), role.name),
            String(localized: "Your changes to it are removed, along with anything typed here and not saved. This can't be undone.", comment: "角色库：恢复出厂设置的后果"),
            button: button) else { return }
        var code = library.restore(role.key, everything: false)
        if code == "OverridesUnreadable" {
            // One role cannot be taken out of a file nobody can read. The
            // core will set the whole file aside, and only when told to --
            // so the person is told what that costs first.
            guard confirm(
                String(localized: "The file that holds your changes can't be read.", comment: "角色库：恢复出厂设置时改动文件读不了，第二次确认的标题"),
                String(localized: "Restoring will put every official role and skill back to factory settings, not only this one. The file is kept beside the role library, renamed, so nothing in it is lost.", comment: "角色库：恢复出厂设置时改动文件读不了，第二次确认的说明"),
                button: String(localized: "Restore All", comment: "角色库：把全部官方角色与 skill 恢复出厂设置")) else { return }
            code = library.restore(role.key, everything: true)
        }
        load(role.key)
        status = code.map(RoleLibrary.message(for:))
    }

    /// "Keep mine": the notice that the official role has changed goes,
    /// and what was changed here stays.
    func keepMine() {
        if let name = skill {
            // The text is untouched, so what is being typed stays as it is.
            status = library.acknowledgeSkill(name)
            return
        }
        guard let key = original?.key else { return }
        let wasDirty = isDirty
        status = library.acknowledge(key)
        if !wasDirty { load(key) }
    }

    func adopt(_ key: String) {
        status = library.adopt(key)
    }
}

extension RoleLibraryEditor: SettingsPane {}

/// The three parts of a role the editor shows one at a time.
enum RoleEditorTab: Hashable { case basics, skills, mcp }

/// The role library: every role, and one of them being edited. The
/// settings window lays it out on its grid (settings.md §2.3a), so it comes
/// in three parts placed separately: the list column, the editor column,
/// and the one bar across the bottom band.
struct RoleLibraryView: View {
    enum Part { case list, detail, bar }

    @ObservedObject var library: RoleLibrary
    @ObservedObject var editor: RoleLibraryEditor
    var part: Part

    @FocusState private var listFocused: Bool

    /// The settings window's search text: roles whose name or key contains
    /// it, ignoring case. Empty shows them all.
    var filter: String = ""

    /// Asked each time the footer is drawn: a terminal window can open or
    /// close while this one stays up.
    var canLaunch: () -> Bool
    var onLaunch: (Role, String) -> Void

    var body: some View {
        switch part {
        case .list:
            sidebar
                // Once, on the one part that is always there with the others.
                .onChange(of: library.catalog) { _ in editor.libraryChanged() }
        case .detail:
            detail
        case .bar:
            bar
        }
    }

    // MARK: Sidebar

    /// Drawn rows rather than a `List`, for the same reason as the
    /// settings sidebar: the text has to start on the column's content edge
    /// (settings.md §2.3a), and a list's cell insets are not ours to set.
    private var sidebar: some View {
        let listing = Self.listing(library: library, editor: editor, query: filter)
        return ScrollViewReader { scroller in ScrollView {
            VStack(spacing: SettingsLayout.rowGap / 4) {
                // A role being made is kept whatever the search says: it is
                // the one on screen, and it has no row of its own to find.
                if editor.isNew, let draft = editor.draft {
                    SettingsRow(selected: true) { roleRow(draft, unsaved: true) }
                }
                ForEach(listing.visible, id: \.self) { key in
                    if let role = library.catalog.roles.first(where: { $0.key == key }) {
                        SettingsRow(selected: !editor.isNew && editor.selection == key) {
                            roleRow(role, unsaved: false)
                        }
                        .id(key)
                        .onTapGesture {
                            // As in the sidebar: focus lands before any
                            // unsaved-changes question is asked.
                            listFocused = true
                            DispatchQueue.main.async { editor.select(key) }
                        }
                    }
                }
                if listing.noMatch {
                    SettingsRow(selected: false) {
                        Text(String(localized: "No matching roles", comment: "设置窗口：搜索后角色列表里一个都不剩"))
                            .foregroundStyle(.secondary)
                    }
                }
                officialSkillRows
            }
            .padding(.vertical, SettingsLayout.rowGap)
        }
        // A row chosen with ↑↓, or by a route from elsewhere, is scrolled to.
        .onChange(of: editor.selection) { key in
            if let key { scroller.scrollTo(key) }
        }
        .onChange(of: editor.skill) { name in
            if let name { scroller.scrollTo(Self.skillRowID(name)) }
        } }
        .settingsListFocus()
        .focused($listFocused)
        .onMoveCommand { direction in
            // One list to the arrow keys, as it is one list to the eye: the
            // roles, then the official skills under them.
            let rows = listing.visible.map(ListedRow.role) + shownSkills.map { ListedRow.skill($0.name) }
            let current: ListedRow? = editor.skill.map(ListedRow.skill)
                ?? (editor.isNew ? nil : editor.selection.map(ListedRow.role))
            guard let delta = direction.rowDelta,
                  let next = SettingsRules.step(from: current, in: rows, by: delta)
            else { return }
            switch next {
            case .role(let key): editor.select(key)
            case .skill(let name): editor.selectSkill(name)
            }
        }
        .overlay { sidebarEmptyState }
    }

    /// The skills Polter ships, under the roles: the same list, because a
    /// role is where a person meets them, and the same mark.
    /// A row of the list column: a role, or an official skill.
    enum ListedRow: Equatable {
        case role(String)
        case skill(String)
    }

    static func skillRowID(_ name: String) -> String { "official-skill:" + name }

    /// The official skills the search leaves.
    private var shownSkills: [OfficialSkill] {
        library.skills.skills.filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
        }
    }

    @ViewBuilder
    private var officialSkillRows: some View {
        let shown = shownSkills
        if !shown.isEmpty {
            Divider().padding(.vertical, SettingsLayout.rowGap)
            SettingsRow(selected: false) {
                Text(String(localized: "Official Skills", comment: "角色库：列表下半的分组标题，Polter 自带的 skill"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { skill in
                SettingsRow(selected: editor.skill == skill.name) {
                    HStack(spacing: 6) {
                        Text(skill.name).lineLimit(1)
                        OfficialMark()
                        if skill.official.canRestore || (editor.skill == skill.name && editor.isDirty) {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .id(Self.skillRowID(skill.name))
                .onTapGesture {
                    listFocused = true
                    DispatchQueue.main.async { editor.selectSkill(skill.name) }
                }
            }
        }
    }

    /// What the search leaves of the list. The breadcrumb asks the same
    /// question, so both come from here.
    static func listing(library: RoleLibrary, editor: RoleLibraryEditor, query: String) -> SettingsRules.Listing {
        SettingsRules.listing(
            items: library.catalog.roles.map { ($0.key, $0.displayName) },
            query: query,
            selection: editor.isNew ? nil : editor.draft?.key)
    }

    /// New, Duplicate, Delete: at the left end of the bottom bar, under the
    /// list they act on.
    private var listButtons: some View {
            HStack(spacing: SettingsLayout.rowGap / 2) {
                iconButton("plus", help: String(localized: "New Role", comment: "角色库：新建角色的默认名字")) {
                    editor.newRole()
                }
                .disabled(library.catalog.error != nil)
                iconButton("plus.square.on.square", help: String(localized: "Duplicate Role", comment: "角色库：复制所选角色")) {
                    editor.duplicate()
                }
                .disabled(editor.draft == nil || library.catalog.error != nil)
                iconButton("minus", help: String(localized: "Delete Role", comment: "角色库：删除所选角色")) {
                    editor.delete()
                }
                .disabled(editor.draft == nil || editor.draft?.builtin == true || library.catalog.error != nil)
            }
    }

    @ViewBuilder
    private var sidebarEmptyState: some View {
        if library.catalog.roles.isEmpty && !editor.isNew {
            VStack(spacing: 6) {
                if !library.catalog.loaded {
                    Text(String(localized: "Reading the role library…", comment: "角色库：还没读到角色文件"))
                } else {
                    Text(String(localized: "No roles yet", comment: "角色库：一个角色都没有"))
                        .font(.headline)
                    Text(String(localized: "A role is a saved way to start an agent CLI: which skills and MCP servers it keeps, and what it's told.", comment: "角色库：空列表时解释角色是什么"))
                        .font(SettingsFont.minimum)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "New Role", comment: "角色库：新建角色的默认名字")) { editor.newRole() }
                        .padding(.top, 4)
                }
            }
            .foregroundStyle(.secondary)
            .padding()
        }
    }

    private func roleRow(_ role: Role, unsaved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(role.displayName.isEmpty ? role.key : role.displayName)
                    .lineLimit(1)
                if role.builtin {
                    OfficialMark()
                }
                if unsaved || (role.key == editor.draft?.key && editor.isDirty) || role.official?.canRestore == true {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .help(unsaved || (role.key == editor.draft?.key && editor.isDirty)
                              ? String(localized: "Unsaved changes", comment: "角色库：有未保存的修改")
                              : String(localized: "Changed from factory settings", comment: "角色库：官方角色或 skill 被改过的圆点说明"))
                }
            }
            Text(role.clis.isEmpty
                 ? String(localized: "No agent CLI", comment: "角色库：列表行副标题，这个角色还没选 CLI")
                 : role.clis.map { library.clis.label(for: $0.cli) }.joined(separator: " · "))
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let error = library.catalog.error {
                banner(String(localized: "The role library file has an error in it. Roles can't be changed here until it's fixed.", comment: "角色库：personas.json 解析失败的横幅"), detail: error)
            }
            if let why = library.catalog.overridesError {
                banner(String(localized: "Your changes to official roles couldn't be read, so they are not in use.", comment: "角色库：官方角色的改动文件整份读不了"), detail: why)
            }
            ForEach(library.catalog.shadowed) { mine in
                shadowedBanner(mine)
            }
            if let skill = editor.selectedSkill {
                officialNotice(skill.official, name: nil)
                ScrollView {
                    skillEditor(skill)
                        .padding(SettingsLayout.pad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let draft = editor.draft {
                if !editor.isNew, let official = editor.original?.official {
                    officialNotice(official, name: draft.name)
                }
                tabBar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsLayout.groupGap) {
                        Group {
                            switch editor.tab {
                            case .basics:
                                basics
                                instructions
                                polterSection
                                cliPicker
                                if let cli = editor.activeCli, editor.draft?.choice(for: cli) != nil {
                                    RoleCliStartEditor(library: library, editor: editor, cliKey: cli)
                                }
                            case .skills, .mcp:
                                itemsTab(editor.tab == .skills ? .skill : .mcp)
                            }
                        }
                    }
                    .padding(SettingsLayout.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Text(String(localized: "Select a role, or make a new one.", comment: "角色库：右侧没有选中角色时的提示"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// "3/40" for the tab label: kept of installed, for the CLI on screen.
    private func count(_ kind: AgentCliItem.Kind) -> String? {
        guard let key = editor.activeCli,
              let cli = library.clis.cli(key),
              let choice = editor.draft?.choice(for: key) else { return nil }
        let all = cli.items(kind)
        guard !all.isEmpty else { return nil }
        let sel = kind == .skill ? choice.skills : choice.mcp
        return "\(all.filter { $0.locked || sel.isOn($0.id) }.count)/\(all.count)"
    }

    private var tabBar: some View {
        Picker("", selection: $editor.tab) {
            Text(String(localized: "Basics", comment: "角色库：tab 名，角色基本信息")).tag(RoleEditorTab.basics)
            Text(count(.skill).map { String(format: String(localized: "Skills %@", comment: "角色库：tab 名，%@ 是保留数/总数，如 3/40"), $0) }
                 ?? String(localized: "Skills", comment: "角色编辑器：分区名，技能"))
                .tag(RoleEditorTab.skills)
            Text(count(.mcp).map { String(format: String(localized: "MCP %@", comment: "角色库：tab 名，%@ 是保留数/总数"), $0) }
                 ?? String(localized: "MCP", comment: "角色库：tab 名，MCP 服务器"))
                .tag(RoleEditorTab.mcp)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding(.horizontal, SettingsLayout.pad)
        .padding(.vertical, SettingsLayout.rowGap + 4)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func itemsTab(_ kind: AgentCliItem.Kind) -> some View {
        let clis = editor.draft?.clis ?? []
        if clis.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                note(String(localized: "Pick an agent CLI under Basics first: skills and MCP servers belong to a CLI.", comment: "角色库：还没选 CLI 时 skill/MCP tab 的提示"))
                Button(String(localized: "Go to Basics", comment: "角色库：跳到基本信息 tab")) { editor.tab = .basics }
            }
        } else {
            if clis.count > 1 {
                Picker("", selection: Binding(
                    get: { editor.activeCli ?? clis[0].cli },
                    set: { editor.activeCli = $0 })) {
                    ForEach(clis) { choice in
                        Text(library.clis.label(for: choice.cli)).tag(choice.cli)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            if let cli = editor.activeCli ?? clis.first?.cli {
                RoleCliItemsEditor(library: library, editor: editor, cliKey: cli, kind: kind)
            }
        }
    }

    /// Whether the role on screen is an official one: its name, its
    /// description and what it grants are shown and cannot be changed.
    private var locked: Bool { editor.draft?.builtin == true }

    /// What an official role or skill has to say for itself, above it:
    /// that the shipped one has changed since it was changed here, or that
    /// what was changed here could not be read. Nothing when neither.
    @ViewBuilder
    private func officialNotice(_ official: RoleOfficial, name: String?) -> some View {
        switch official.state {
        case .modifiedStale:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    let fields = Array(Set(official.stale.map(RoleOfficial.fieldName))).sorted().joined(separator: ", ")
                    Label(fields.isEmpty
                          ? String(localized: "The official version has changed", comment: "角色库：官方版本有更新（官方 skill，没有字段可点名）")
                          : String(format: String(localized: "The official version has changed: %@", comment: "角色库：官方版本有更新，%@ 是哪几部分"), fields),
                          systemImage: "arrow.triangle.2.circlepath")
                    Text(String(localized: "The official version of what you changed here has changed since. Yours is still the one in use.", comment: "角色库：官方版本有更新的第二行"))
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(String(localized: "Keep Mine", comment: "角色库：官方版本有更新时，知道了，仍用我的")) { editor.keepMine() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsLayout.pad)
            .padding(.vertical, SettingsLayout.rowGap + 4)
            .background(Color.accentColor.opacity(0.08))
        case .unknown:
            banner(String(localized: "Your changes weren't read, so the factory settings are in use.", comment: "角色库：这个官方角色或 skill 的改动读不出来"),
                   detail: official.reason ?? "")
        case .pristine, .modified:
            EmptyView()
        }
    }

    /// A role of the person's that the file holds under a key Polter now
    /// ships a role under: said, with the one thing they can do about it.
    private func shadowedBanner(_ mine: RoleCatalog.Shadowed) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(String(format: String(localized: "Your role \"%1$@\" has the key %2$@, which is now an official role's. Yours is kept in the file but isn't in use.", comment: "角色库：用户文件里有一个角色用了官方 key；%1$@ 是它的名字，%2$@ 是 key"), mine.name, mine.key),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(String(localized: "Keep It Under a New Key", comment: "角色库：把占了官方 key 的自建角色改个 key 留下")) { editor.adopt(mine.key) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsLayout.pad)
        .padding(.vertical, SettingsLayout.rowGap + 4)
        .background(Color.orange.opacity(0.08))
    }

    /// An official skill: its name, which is its file's and cannot change,
    /// where it stands, and its whole text.
    private func skillEditor(_ skill: OfficialSkill) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.groupGap) {
            VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
                labeled(String(localized: "Name", comment: "角色库：字段名，角色名")) {
                    lockedField(skill.name, monospaced: true)
                }
                labeled(String(localized: "Status", comment: "角色库：官方 skill 的状态行标签")) {
                    Text(Self.stateText(skill.official))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            section(String(localized: "Skill Text", comment: "角色库：分区名，官方 skill 的正文")) {
                TextEditor(text: $editor.skillText)
                    .font(.body.monospaced())
                    .frame(minHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                note(String(localized: "Takes effect as soon as it's saved. When an agent that is already running reads the new text depends on the tool it uses.", comment: "角色库：官方 skill 保存后何时生效"))
            }
        }
    }

    static func stateText(_ official: RoleOfficial) -> String {
        switch official.state {
        case .pristine: return String(localized: "Factory settings", comment: "角色库：官方 skill 的状态，没改过")
        case .modified: return String(localized: "Changed", comment: "角色库：官方 skill 的状态，改过")
        case .modifiedStale: return String(localized: "Changed · The official version has changed", comment: "角色库：官方 skill 的状态，改过且官方版本后来也变了")
        case .unknown: return String(format: String(localized: "Your changes weren't read: %@", comment: "角色库：官方 skill 的状态，改动读不出来，%@ 是原因"), official.reason ?? "")
        }
    }

    /// A field that is shown and cannot be changed, with the lock that
    /// says so.
    private func lockedField(_ text: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "lock.fill")
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .help(String(localized: "Part of the official version. It can't be changed.", comment: "角色库：官方角色或 skill 里锁住的字段的说明"))
        }
    }

    private func banner(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(detail)
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsLayout.pad)
        .padding(.vertical, SettingsLayout.rowGap + 4)
        .background(Color.orange.opacity(0.08))
    }

    private var draftBinding: Binding<Role> {
        Binding(get: { editor.draft ?? Role(key: "", name: "") }, set: { editor.draft = $0 })
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
            labeled(String(localized: "Name", comment: "角色库：字段名，角色名")) {
                if locked {
                    lockedField(editor.draft?.name ?? "")
                } else {
                    TextField("", text: draftBinding.name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: editor.draft?.name ?? "") { _ in editor.nameChanged() }
                }
            }
            labeled(String(localized: "Key", comment: "角色库：字段名，角色的 key（英文标识）")) {
                if editor.isNew {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("", text: Binding(
                            get: { editor.draft?.key ?? "" },
                            set: { editor.draft?.key = $0; editor.keyFollowsName = false }))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        let key = editor.draft?.key ?? ""
                        Text(Role.isValidKey(key)
                             ? String(localized: "Lowercase letters, digits and dashes. It can't be changed after saving.", comment: "角色库：key 的规则说明")
                             : String(localized: "Only lowercase letters, digits and dashes, at most 32.", comment: "角色库：key 不合规时的提示"))
                            .font(SettingsFont.minimum)
                            .foregroundStyle(Role.isValidKey(key) ? Color.secondary : Color.red)
                    }
                } else {
                    Text(editor.draft?.key ?? "")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            labeled(String(localized: "Description", comment: "角色库：字段名，角色的一句话说明")) {
                if locked {
                    lockedField(editor.draft?.summary ?? "")
                } else {
                    TextField(String(localized: "What this role is for, for whoever picks it", comment: "角色库：说明字段的占位提示"),
                              text: draftBinding.summary)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var instructions: some View {
        section(String(localized: "Instructions", comment: "角色库：分区名，启动时附加给 agent 的指令")) {
            VStack(spacing: 0) {
                TextEditor(text: draftBinding.instructions)
                    .font(.body)
                    .frame(height: instructionsHeight)
                ResizeGrip(height: $instructionsHeight, range: 100...900)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            note(String(localized: "Added to the agent's system prompt when it starts. Leave it empty to add nothing. Drag the bottom edge to make the box taller.", comment: "角色库：指令字段的解释"))
        }
    }

    /// Remembered between windows and launches: somebody who writes long
    /// instructions wants the tall box every time, not once.
    @AppStorage("RoleLibrary.instructionsHeight") private var instructionsHeight: Double = 240

    private var polterBinding: Binding<RolePolter> {
        Binding(get: { editor.draft?.polter ?? RolePolter() }, set: { editor.draft?.polter = $0 })
    }

    private var polterSection: some View {
        section(String(localized: "Polter", comment: "角色库：分区名，这个角色启动的终端在 Polter 里是什么身份")) {
            VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
                formControl {
                    Toggle(String(localized: "Make this terminal a supervisor", comment: "角色库：Polter 选项，启动后设为总管"),
                           isOn: polterBinding.supervisor)
                        .disabled(locked)
                }
                formControl {
                    Toggle(String(localized: "Let the supervisor answer this terminal's permission prompts", comment: "角色库：Polter 选项，允许总管替你回答权限问题"),
                           isOn: polterBinding.mayAuthorise)
                        .disabled(locked)
                }
                formControl {
                    Toggle(String(localized: "Shield it: no tool can reach it, a supervisor's included", comment: "角色库：Polter 选项，护盾"),
                           isOn: polterBinding.shielded)
                        .disabled(locked)
                }
                formControl {
                    note(locked
                         ? String(localized: "These three are part of the official role and can't be changed. Duplicate the role to make one of your own.", comment: "角色库：官方角色的前三个 Polter 选项锁住")
                         : String(localized: "These three give the terminal something, so only you can set them, here. A supervisor that edits roles can't change them.", comment: "角色库：前三个 Polter 选项只有用户能改"))
                }

                let p = editor.draft?.polter ?? RolePolter()
                formControl {
                    Toggle(String(localized: "Hand it to the supervisor to watch", comment: "角色库：Polter 选项，启动后交给当前总管监管"),
                           isOn: polterBinding.watch)
                        .disabled(p.supervisor || p.shielded)
                        .help(String(localized: "The supervisor that started it, or the only one there is. With several and you starting it, nobody.", comment: "角色库：交给总管监管的规则说明"))
                }
                formControl { HStack(spacing: SettingsLayout.rowGap) {
                    Toggle(String(localized: "Report it as still after", comment: "角色库：Polter 选项，静止多久算卡住，后接分钟数"),
                           isOn: Binding(
                            get: { editor.draft?.polter.quietMs != nil },
                            set: { editor.draft?.polter.quietMs = $0 ? 10 * 60_000 : nil }))
                    if let ms = p.quietMs {
                        Stepper(value: Binding(
                            get: { max(1, ms / 60_000) },
                            set: { editor.draft?.polter.quietMs = $0 * 60_000 }), in: 1...240) {
                            Text(String(format: String(localized: "%d min", comment: "角色库：静止阈值的分钟数"), max(1, ms / 60_000)))
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
                .disabled(p.shielded) }
                labeled(String(localized: "Open in", comment: "角色库：Polter 选项，点角色时在哪打开")) {
                    // As wide as its longest choice where there is room for
                    // that, and no wider than the column where there is
                    // not: at the window's narrowest the choice is longer
                    // than the column, and a control that will not give
                    // way pushes the whole page wider than the window.
                    ViewThatFits(in: .horizontal) {
                        openInPicker.fixedSize()
                        openInPicker
                    }
                }
                formControl {
                    note(String(localized: "Applied once, when the role starts an agent CLI. Putting the role on a terminal that's already running changes its tools, not these.", comment: "角色库：Polter 选项何时生效"))
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private var cliPicker: some View {
        section(String(localized: "Agent CLIs", comment: "角色库：分区名，这个角色可以启动哪些 CLI")) {
            if library.clis.stale && library.clis.clis.isEmpty {
                formControl { HStack(spacing: SettingsLayout.rowGap) {
                    ProgressView().controlSize(.small)
                    note(String(localized: "Reading what's installed…", comment: "角色库：正在读取各 CLI 装了什么"))
                } }
            } else if library.clis.clis.isEmpty {
                formControl {
                    note(String(localized: "No plugin that manages an agent CLI is installed and switched on.", comment: "角色库：没有任何 CLI 适配插件"))
                }
            } else {
                ForEach(library.clis.clis) { cli in
                    formControl { HStack(spacing: SettingsLayout.rowGap) {
                        Toggle(isOn: Binding(
                            get: { editor.draft?.choice(for: cli.key) != nil },
                            set: { editor.setCli(cli.key, used: $0) })) {
                            Text(cli.label)
                        }
                        .toggleStyle(.checkbox)
                        if cli.installed == false {
                            Text(String(format: String(localized: "%@ isn't on this machine's PATH", comment: "角色库：CLI 程序没找到，%@ 是程序名"), cli.bin))
                                .font(SettingsFont.minimum)
                                .foregroundStyle(.orange)
                        }
                        if cli.error != nil {
                            Text(String(localized: "Its plugin couldn't list what's installed", comment: "角色库：适配插件读取清单失败"))
                                .font(SettingsFont.minimum)
                                .foregroundStyle(.orange)
                        }
                    } }
                }
                // Choices for a CLI no plugin offers any more are still in
                // the role; say so rather than hide them.
                ForEach(editor.draft?.clis.filter { library.clis.cli($0.cli) == nil } ?? []) { orphan in
                    formControl { HStack(spacing: SettingsLayout.rowGap) {
                        Toggle(isOn: Binding(get: { true }, set: { editor.setCli(orphan.cli, used: $0) })) {
                            Text(orphan.cli).font(.body.monospaced())
                        }
                        .toggleStyle(.checkbox)
                        Text(String(localized: "No plugin manages this CLI any more", comment: "角色库：角色里配了某 CLI，但对应插件已不在"))
                            .font(SettingsFont.minimum)
                            .foregroundStyle(.orange)
                    } }
                }
                if let clis = editor.draft?.clis, clis.count > 1 {
                    formControl {
                        Picker("", selection: Binding(
                            get: { editor.activeCli ?? clis[0].cli },
                            set: { editor.activeCli = $0 })) {
                            ForEach(clis) { choice in
                                Text(library.clis.label(for: choice.cli)).tag(choice.cli)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }
            }
        }
    }

    /// The one bar in the bottom band: list buttons at the list's left edge,
    /// then the status line, then Launch / Revert / Save on the right.
    private var bar: some View {
        HStack(spacing: SettingsLayout.rowGap) {
            listButtons
                .padding(.trailing, SettingsLayout.rowGap)
            // The words take what is left between the buttons on either
            // side and wrap inside it: a sentence longer than the space --
            // a translation, or this one at the window's narrowest -- goes
            // onto a second line of the band rather than up against the
            // button beside it.
            Group {
                if let status = editor.status {
                    Label(status, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if let reason = editor.skill == nil ? launchBlockedReason : nil {
                    // Written out rather than a tooltip: a reason nobody
                    // hovers over is no reason (settings.md §4).
                    Text(reason)
                        .foregroundStyle(.secondary)
                } else if editor.isDirty {
                    Text(String(localized: "Unsaved changes", comment: "角色库：有未保存的修改"))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .font(SettingsFont.minimum)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if editor.showsRestore {
                Button(String(localized: "Restore Factory Settings…", comment: "角色库：把官方角色或官方 skill 恢复成出厂的")) { editor.restore() }
                    .disabled(editor.restorable == nil)
            }
            if editor.skill == nil { launchButton }
            Button(String(localized: "Discard Changes", comment: "角色库：放弃未保存的修改，回到已保存的版本")) { editor.revert() }
                .disabled(!editor.isDirty)
            Button(String(localized: "Save", comment: "角色库：保存按钮")) { editor.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.isDirty || library.catalog.error != nil)
        }
        .controlSize(.large)
        .padding(.leading, SettingsLayout.ContentEdge.bottomBar)
        .padding(.trailing, SettingsLayout.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Why Launch is greyed out, shown in the footer; nil when it isn't.
    private var launchBlockedReason: String? {
        if !canLaunch() {
            return String(localized: "Open a terminal window first; the new tab goes beside it.", comment: "角色库：没有终端窗口时无法启动")
        }
        if editor.isDirty {
            return String(localized: "Save the role before launching it.", comment: "角色库：有未保存修改时不能启动")
        }
        if (editor.draft?.clis ?? []).isEmpty {
            return String(localized: "Pick an agent CLI under Basics to launch this role.", comment: "角色库：角色没选 CLI 时不能启动")
        }
        return nil
    }

    private var openInPicker: some View {
        Picker("", selection: polterBinding.open) {
            Text(String(localized: "Here when at a prompt, else a new tab", comment: "角色库：打开位置，自动")).tag(RolePolter.Open.auto)
            Text(String(localized: "Always a new tab", comment: "角色库：打开位置，始终新标签页")).tag(RolePolter.Open.tab)
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var launchButton: some View {
        let clis = editor.draft?.clis ?? []
        let blocked = launchBlockedReason != nil
        let help = String(localized: "Open a new tab and start the agent CLI in it wearing this role.", comment: "角色库：启动按钮的说明")
        if clis.count > 1 {
            Menu(String(localized: "Launch", comment: "角色库：用这个角色启动")) {
                ForEach(clis) { choice in
                    Button(library.clis.label(for: choice.cli)) {
                        if let role = editor.draft { onLaunch(role, choice.cli) }
                    }
                }
            }
            .fixedSize()
            .disabled(blocked)
            .help(help)
        } else {
            Button(String(localized: "Launch", comment: "角色库：用这个角色启动")) {
                if let role = editor.draft, let cli = clis.first { onLaunch(role, cli.cli) }
            }
            .disabled(blocked)
            .help(help)
        }
    }

    // MARK: Chrome

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        formRow(title, content: content)
    }
}

/// The mark on a role or a skill Polter ships. Words in a thin outline: a
/// lock said "cannot be changed", which is no longer what official means.
struct OfficialMark: View {
    var body: some View {
        Text(String(localized: "Official", comment: "角色库：官方角色与官方 skill 的标志"))
            .font(SettingsFont.minimum)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .help(String(localized: "Comes with Polter. What you change in it can be put back with Restore Factory Settings.", comment: "角色库：官方标志的说明"))
    }
}

/// How one CLI is started for the role being edited: model and arguments.
/// On the Basics tab; what the CLI keeps is on the other two.
struct RoleCliStartEditor: View {
    @ObservedObject var library: RoleLibrary
    @ObservedObject var editor: RoleLibraryEditor
    var cliKey: String

    @State private var argsText = ""

    private var choice: RoleCliChoice? { editor.draft?.choice(for: cliKey) }

    /// A command line, not a sentence, so it is not translated.
    private static let argsExample = "--permission-mode auto"

    var body: some View {
        section(String(format: String(localized: "Starting %@", comment: "角色库：分区名，%@ 是 CLI 名，启动参数"), library.clis.label(for: cliKey))) {
            formRow(String(localized: "Model", comment: "角色库：字段名，模型")) {
                TextField(String(localized: "The CLI's default", comment: "角色库：模型字段占位，留空用 CLI 默认"), text: Binding(
                    get: { choice?.model ?? "" },
                    set: { value in editor.updateChoice(cliKey) { $0.model = value } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            formRow(String(localized: "Extra Arguments", comment: "角色库：字段名，额外命令行参数")) {
                VStack(alignment: .leading, spacing: 3) {
                    TextField(Self.argsExample, text: $argsText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onChange(of: argsText) { value in
                            editor.updateChoice(cliKey) { $0.args = RoleArgs.split(value) }
                        }
                    note(String(localized: "Added to the command line as typed. Quote anything with a space in it.", comment: "角色库：额外参数的说明"))
                }
            }
        }
        .onAppear { argsText = RoleArgs.join(choice?.args ?? []) }
        .onChange(of: cliKey) { _ in argsText = RoleArgs.join(choice?.args ?? []) }
        .onChange(of: editor.original) { _ in argsText = RoleArgs.join(choice?.args ?? []) }
    }
}

/// The skills, or the MCP servers, one CLI has, each with a switch: one
/// tab each, so the servers are not at the bottom of a long list of skills.
struct RoleCliItemsEditor: View {
    @ObservedObject var library: RoleLibrary
    @ObservedObject var editor: RoleLibraryEditor
    var cliKey: String
    var kind: AgentCliItem.Kind

    @State private var search = ""

    private var cli: AgentCli? { library.clis.cli(cliKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let cli {
                if let error = cli.error {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Its plugin couldn't list what's installed", comment: "角色库：适配插件读取清单失败"))
                            Text(error).font(SettingsFont.minimum).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(kind == .skill
                              ? String(localized: "Filter skills", comment: "角色库：skill tab 的搜索框占位")
                              : String(localized: "Filter MCP servers", comment: "角色库：MCP tab 的搜索框占位"),
                              text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        library.reloadClis(refresh: true)
                    } label: {
                        if library.clis.refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Read what's installed again", comment: "角色库：重新读取已安装项"))
                }

                RoleItemSection(
                    title: kind == .skill
                        ? String(localized: "Skills", comment: "角色编辑器：分区名，技能")
                        : String(localized: "MCP Servers", comment: "角色编辑器：分区名，MCP 服务器"),
                    kind: kind, cli: cli, cliKey: cliKey, search: search, editor: editor)

                ForEach(cli.notes, id: \.self) { note(String($0)) }
            } else if library.clis.stale {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    note(String(localized: "Reading what's installed…", comment: "角色库：正在读取各 CLI 装了什么"))
                }
            } else {
                note(String(localized: "No plugin manages this CLI any more", comment: "角色库：角色里配了某 CLI，但对应插件已不在"))
            }
        }
        // A new tab or CLI starts unfiltered: a filter left over from the
        // other list hides things for no visible reason.
        .onChange(of: kind) { _ in search = "" }
        .onChange(of: cliKey) { _ in search = "" }
    }
}

/// One kind of thing -- skills, or MCP servers -- with its default, its
/// groups, and a switch per item.
struct RoleItemSection: View {
    var title: String
    var kind: AgentCliItem.Kind
    var cli: AgentCli
    var cliKey: String
    var search: String
    @ObservedObject var editor: RoleLibraryEditor

    @State private var collapsed: Set<String> = []

    private var selection: RoleSelection {
        let choice = editor.draft?.choice(for: cliKey)
        return (kind == .skill ? choice?.skills : choice?.mcp) ?? RoleSelection()
    }

    private func update(_ change: (inout RoleSelection) -> Void) {
        editor.updateChoice(cliKey) { choice in
            if kind == .skill { change(&choice.skills) } else { change(&choice.mcp) }
        }
    }

    private var all: [AgentCliItem] { cli.items(kind) }

    private var visible: [AgentCliItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || ($0.group ?? $0.source).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let sel = selection
        let onCount = all.filter { $0.locked || sel.isOn($0.id) }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(String(format: String(localized: "%lld of %lld kept", comment: "角色库：保留了多少项，例如 12 of 40 kept"), onCount, all.count))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Keep All", comment: "角色库：当前筛选下全部保留")) {
                    update { s in for item in visible where !item.locked { s.set(item.id, on: true) } }
                }
                .buttonStyle(.link)
                .disabled(visible.isEmpty)
                Button(String(localized: "Turn All Off", comment: "角色库：当前筛选下全部关掉")) {
                    update { s in for item in visible where !item.locked { s.set(item.id, on: false) } }
                }
                .buttonStyle(.link)
                .disabled(visible.isEmpty)
            }

            Toggle(isOn: Binding(
                get: { sel.keepByDefault },
                set: { keep in update { $0.setDefault(keep, keeping: all.map(\.id)) } })) {
                Text(kind == .skill
                     ? String(localized: "Keep skills installed later", comment: "角色库：以后新装的 skill 默认保留")
                     : String(localized: "Keep MCP servers added later", comment: "角色库：以后新加的 MCP 默认保留"))
                    .font(SettingsFont.minimum)
            }
            .toggleStyle(.checkbox)
            .help(String(localized: "What happens to anything that isn't listed here yet, such as something installed tomorrow or a project's own.", comment: "角色库：默认项开关的说明"))

            if all.isEmpty {
                Text(kind == .skill
                     ? String(localized: "No skills are installed for this CLI.", comment: "角色库：这个 CLI 没有 skill")
                     : String(localized: "No MCP servers are configured for this CLI.", comment: "角色库：这个 CLI 没有 MCP"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
            } else if visible.isEmpty {
                Text(String(localized: "Nothing matches the filter.", comment: "角色库：筛选无结果"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
            }

            ForEach(RoleItemGroup.groups(visible)) { group in
                groupView(group, selection: sel)
            }

            let missing = sel.except.filter { id in
                id.hasPrefix(kind == .skill ? "skill:" : "mcp:") && !all.contains { $0.id == id }
            }
            if !missing.isEmpty {
                Text(String(format: String(localized: "Also in this role but not installed here: %@", comment: "角色库：角色里提到但本机没装的项，%@ 是列表"), missing.joined(separator: ", ")))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func groupView(_ group: RoleItemGroup, selection sel: RoleSelection) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        let on = group.items.filter { $0.locked || sel.isOn($0.id) }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(SettingsFont.minimum.weight(.semibold))
                            .frame(width: 12)
                        Text(group.title).font(SettingsFont.minimum.weight(.semibold))
                        Text(verbatim: "\(on)/\(group.items.count)")
                            .font(SettingsFont.minimum.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { on == group.items.count },
                    set: { keep in update { s in for item in group.items where !item.locked { s.set(item.id, on: keep) } } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(String(localized: "Keep or turn off everything in this group", comment: "角色库：整组开关"))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)

            if let summary = group.summary, !summary.isEmpty, !isCollapsed {
                Text(summary)
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }

            if !isCollapsed {
                Divider()
                ForEach(group.items) { item in
                    RoleItemRow(
                        item: item,
                        groupName: group.id.hasPrefix("plugin:") ? group.title : nil,
                        groupSummary: group.summary,
                        isOn: item.locked || sel.isOn(item.id),
                        onToggle: { on in update { $0.set(item.id, on: on) } })
                    if item.id != group.items.last?.id {
                        Divider().padding(.leading, 34)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.18)))
    }
}

/// One skill or MCP server: a switch, its name, and what it is for -- the
/// whole description, a click away when it is long.
struct RoleItemRow: View {
    var item: AgentCliItem
    var groupName: String?
    /// The group header's text. A plugin's MCP server has no description
    /// of its own and carries the plugin's; under that plugin's header it
    /// would only say the same paragraph twice.
    var groupSummary: String?
    var isOn: Bool
    var onToggle: (Bool) -> Void

    @State private var expanded = false

    private var displayName: String {
        if let groupName, item.name.hasPrefix(groupName + ":") {
            return String(item.name.dropFirst(groupName.count + 1))
        }
        return item.name
    }

    private var isLong: Bool {
        item.summary.count > 160 || item.summary.contains("\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.locked)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .textSelection(.enabled)
                    if item.locked {
                        Image(systemName: "lock.fill")
                            .font(SettingsFont.minimum)
                            .foregroundStyle(.secondary)
                            .help(String(localized: "Always kept: this is how the agent reaches Polter.", comment: "角色库：polter 自己的 MCP 不能关"))
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(SettingsFont.minimum.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !item.summary.isEmpty && item.summary == groupSummary {
                    EmptyView()
                } else if item.summary.isEmpty {
                    Text(String(localized: "No description", comment: "角色库：这一项没有说明"))
                        .font(SettingsFont.minimum)
                        .italic()
                        .foregroundStyle(.tertiary)
                } else {
                    Text(item.summary)
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if isLong {
                        Button(expanded
                               ? String(localized: "Show Less", comment: "角色库：收起说明")
                               : String(localized: "Show More", comment: "角色库：展开完整说明")) {
                            expanded.toggle()
                        }
                        .buttonStyle(.link)
                        .font(SettingsFont.minimum)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .opacity(item.locked ? 0.8 : 1)
    }
}

// MARK: - Shared chrome

@ViewBuilder
private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
        Text(title).font(.headline)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

/// A form row: a right-aligned label in the label column, the control in
/// the control column (settings.md §2.3a). Every control of a form sits in
/// that column, checkboxes and pop-ups included.
func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.labelGap) {
        Text(title)
            .frame(width: SettingsLayout.label, alignment: .trailing)
            .foregroundStyle(.secondary)
        content()
    }
}

/// A row with no label of its own: the control still starts in the control
/// column, so it lines up with the labelled rows above and below it.
func formControl<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 0) {
        content()
    }
    .padding(.leading, SettingsLayout.label + SettingsLayout.labelGap)
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(SettingsFont.minimum)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

/// A strip under a box that makes it taller or shorter when dragged.
///
/// SwiftUI's `TextEditor` has no resize handle of its own on macOS, and a
/// fixed height is either too small for real instructions or too big for
/// an empty role.
struct ResizeGrip: View {
    @Binding var height: Double
    var range: ClosedRange<Double>

    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(hovering ? 0.12 : 0.05))
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 3)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = start ?? height
                    start = base
                    height = min(range.upperBound, max(range.lowerBound, base + value.translation.height))
                }
                .onEnded { _ in start = nil })
        .help(String(localized: "Drag to resize", comment: "角色库：拖动调整输入框高度"))
    }
}
