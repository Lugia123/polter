import AppKit
import SwiftUI

/// The members table's columns: the alias box, the role, what the seat is in
/// this squad, and the mark that opens it. Fixed widths rather than a
/// `Grid`, so the header and the rows measure the same and a row's alias box
/// lines up under the word above it.
private let squadAliasColumn: CGFloat = 140
private let squadRequiredColumn: CGFloat = 110
private let squadChevronColumn: CGFloat = 18

/// The squad templates page (#2434): the templates the core keeps, the one
/// being edited, and the seats inside it.
///
/// It is a settings section like the roles page, so it is laid out on the
/// window's one grid (`SettingsLayout`) and comes in the same three parts
/// placed separately: the list column, the detail column, and the one bar
/// across the bottom band.
///
/// **Nothing about a template is decided here.** Which keys are valid, how
/// long an alias may be, whether a role may join at all -- those are the
/// core's (`src/poltergeist/squad.zig`) and `SquadRules` repeats exactly the
/// few of them a page has to answer before the person presses Save.

/// The editing state of the squads page: which template is selected, the copy
/// being edited, and which seat's own page is open.
///
/// A copy rather than editing in place, for the reason `RoleLibraryEditor`
/// states: the library is the core's and changes only when a save succeeds, so
/// a field typed into and never saved must not look saved anywhere else.
@MainActor
final class SquadLibraryEditor: ObservableObject {
    @Published var selection: String?
    @Published var draft: Squad?
    @Published private(set) var original: Squad?
    @Published var isNew = false
    @Published var status: String?

    /// The seat whose settings page is open, by alias. An alias is the
    /// member's identity inside the template (`SquadMember.id`), and aliases
    /// are only typed on the template's own page -- so this does not slip onto
    /// another seat while the person is looking at it.
    @Published var member: String?

    /// Whether the "add a member" panel is up.
    @Published var adding = false

    let library: SquadLibrary

    init(library: SquadLibrary) {
        self.library = library
    }

    var isDirty: Bool {
        guard let draft else { return false }
        return isNew || draft != original
    }

    // MARK: Selection

    /// Select a template, asking first when leaving unsaved changes behind.
    func select(_ key: String?) {
        guard key != draft?.key || isNew else { return }
        // Cancelled: the list draws its highlight from `selection`, which has
        // not moved, so there is nothing to put back.
        guard confirmLeavingDraft() else { return }
        load(key)
    }

    private func load(_ key: String?) {
        selection = key
        isNew = false
        status = nil
        member = nil
        adding = false
        let squad = key.flatMap { k in library.catalog.squads.first { $0.key == k } }
        original = squad
        draft = squad
    }

    /// After the library changed underneath: keep the draft, refresh what
    /// "saved" means for it, drop a selection that is gone, and go back to the
    /// template when the seat on screen is no longer in it.
    func libraryChanged() {
        guard !isNew, let key = draft?.key ?? selection else { return }
        if let fresh = library.catalog.squads.first(where: { $0.key == key }) {
            if !isDirty { draft = fresh }
            original = fresh
        } else if !isDirty {
            load(nil)
            return
        }
        if let member, draft?.member(member) == nil { self.member = nil }
    }

    /// True when it is fine to throw the draft away. The same question the
    /// settings window asks when leaving the section or closing.
    private func confirmLeavingDraft() -> Bool {
        SettingsUnsaved.confirmLeaving(
            self,
            message: String(localized: "Save changes to this squad template?", comment: "小队模版：切换/关闭前有未保存修改"))
    }

    // MARK: The list

    func newSquad() {
        guard confirmLeavingDraft() else { return }
        let taken = Set(library.catalog.squads.map(\.key))
        let name = String(localized: "New Squad Template", comment: "小队模版：新建模版的默认名字")
        selection = nil
        isNew = true
        original = nil
        // `Squad.blank` is the one spelled-out empty template, so a new one
        // cannot quietly arrive with members or with `empty` saying otherwise.
        draft = Squad.blank(key: SquadRules.suggestedKey(for: name, avoiding: taken), name: name)
        member = nil
        adding = false
        status = nil
    }

    func duplicate() {
        guard let source = draft, confirmLeavingDraft() else { return }
        let taken = Set(library.catalog.squads.map(\.key))
        var squad = source
        // A copy is the person's, so it carries no supervisor's reason and
        // says it is the person's own. Saved under a key of its own.
        squad.origin = .user
        squad.reason = ""
        squad.name = String(format: String(localized: "%@ Copy", comment: "小队模版：复制模版后的默认名字，%@ 是原名"), source.displayName)
        squad.key = SquadRules.suggestedKey(for: source.key, avoiding: taken)
        selection = nil
        isNew = true
        original = nil
        draft = squad
        member = nil
        adding = false
        status = nil
    }

    // MARK: Saving

    /// Why an alias of the draft cannot be saved, by the seat's position in
    /// the list -- asked of `SquadRules.aliasProblems`, so the live marking
    /// and the check Save makes are one answer rather than two that could
    /// drift apart.
    var aliasProblems: [Int: String] {
        guard let draft else { return [:] }
        return SquadRules.aliasProblems(draft.members)
    }

    var hasAliasProblem: Bool { !aliasProblems.isEmpty }

    var hasSummaryProblem: Bool {
        guard let draft else { return false }
        return SquadRules.byteLength(draft.summary) > SquadRules.maxSummaryLength
    }

    @discardableResult
    func save() -> Bool {
        guard let squad = draft else { return true }
        // The button is greyed while an alias is wrong; this is the same
        // question asked once more, so a save that got past the button (a
        // keyboard shortcut, a route in from elsewhere) says why instead of
        // writing something the core will refuse.
        if let why = aliasProblems.keys.sorted().first.flatMap({ aliasProblems[$0] }) {
            status = why
            return false
        }
        if hasSummaryProblem {
            status = String(format: String(localized: "At most %d characters.", comment: "小队模版：别名过长，%d 是上限"), SquadRules.maxSummaryLength)
            return false
        }
        if isNew && library.catalog.squads.contains(where: { $0.key == squad.key }) {
            status = String(localized: "Another squad template already uses this key.", comment: "小队模版：新建模版的 key 与已有模版重复")
            return false
        }
        if !SquadRules.isValidKey(squad.key) {
            status = String(localized: "A key has to be 1 to 32 lower-case letters, digits or dashes.", comment: "小队模版：key 的字符集不合格")
            return false
        }
        if let error = library.put(squad) {
            status = error
            return false
        }
        isNew = false
        selection = squad.key
        original = library.catalog.squads.first { $0.key == squad.key } ?? squad
        draft = original
        member = nil
        adding = false
        status = nil
        return true
    }

    func revert() {
        if isNew {
            load(nil)
        } else {
            load(draft?.key)
        }
    }

    func delete() {
        guard let squad = draft else { return }
        if isNew {
            load(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Delete the squad template \"%@\"?", comment: "小队模版：删除确认，%@ 是模版名"), squad.name)
        alert.informativeText = String(localized: "Tasks already opened with it keep the seats they have. Nothing that is running is stopped.", comment: "小队模版：删除模版的后果")
        alert.addButton(withTitle: String(localized: "Delete", comment: "角色库：删除按钮"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "角色库：取消"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let error = library.delete(squad.key) {
            status = error
            return
        }
        load(nil)
    }

    // MARK: Members

    /// Put a role in as a seat. The alias starts as the role's key, numbered
    /// when that name is taken: typing one is the person's job, but a seat with
    /// no name is a seat the core refuses (`aliasProblem` says so).
    func addMember(_ role: Role) {
        guard var squad = draft else { return }
        let alias = uniqueAlias(basedOn: role.key.isEmpty ? "member" : role.key, in: squad)
        squad.members.append(SquadMember(
            alias: alias,
            role: role.key,
            required: false,
            lead: squad.members.isEmpty,
            override: .none))
        squad.empty = false
        draft = squad
        member = alias
        adding = false
    }

    private func uniqueAlias(basedOn base: String, in squad: Squad) -> String {
        func cut(_ text: String) -> String { String(text.prefix(SquadRules.maxAliasLength)) }
        var candidate = cut(base)
        var n = 2
        while squad.members.contains(where: { $0.alias == candidate }) {
            let suffix = "-\(n)"
            candidate = cut(String(base.prefix(SquadRules.maxAliasLength - suffix.count)) + suffix)
            n += 1
        }
        return candidate
    }

    func removeMember(_ alias: String) {
        guard var squad = draft else { return }
        squad.members.removeAll { $0.alias == alias }
        squad.empty = squad.members.isEmpty
        if member == alias { member = nil }
        draft = squad
    }

    /// Change the seat named by `alias`. Not for the alias itself -- see
    /// `updateMember(at:)`.
    func updateMember(_ alias: String, _ change: (inout SquadMember) -> Void) {
        guard var squad = draft, let i = squad.members.firstIndex(where: { $0.alias == alias }) else { return }
        change(&squad.members[i])
        draft = squad
    }

    /// Change the seat at `index`, which is the only way to change an alias:
    /// looking a seat up **by the alias being typed** finds the wrong one the
    /// moment two of them are the same, which is exactly the state the red
    /// marking is for.
    func updateMember(at index: Int, _ change: (inout SquadMember) -> Void) {
        guard var squad = draft, squad.members.indices.contains(index) else { return }
        change(&squad.members[index])
        draft = squad
    }
}

extension SquadLibraryEditor: SettingsPane {}

/// The squads page: every template, and one of them being edited.
struct SquadLibraryView: View {
    enum Part { case list, detail, bar }

    @ObservedObject var library: SquadLibrary
    @ObservedObject var editor: SquadLibraryEditor
    /// The role library's roles: what a seat is built on, and the only place
    /// the page can learn a role's name and whether it is a supervisor's.
    var roles: [Role]
    var part: Part

    /// The settings window's search text: templates whose name or key contains
    /// it, ignoring case. Empty shows them all.
    var filter: String = ""

    @FocusState private var listFocused: Bool

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

    // MARK: List column

    private var sidebar: some View {
        let listing = Self.listing(library: library, editor: editor, query: filter)
        return ScrollViewReader { scroller in ScrollView {
            VStack(spacing: SettingsLayout.rowGap / 4) {
                // A template being made is kept whatever the search says: it is
                // the one on screen and it has no row of its own to find.
                if editor.isNew, let draft = editor.draft {
                    SettingsRow(selected: true) { squadRow(draft, unsaved: true) }
                }
                ForEach(listing.visible, id: \.self) { key in
                    if let squad = library.catalog.squads.first(where: { $0.key == key }) {
                        SettingsRow(selected: !editor.isNew && editor.selection == key) {
                            squadRow(squad, unsaved: false)
                        }
                        .id(key)
                        .onTapGesture {
                            // As in the roles list: focus lands before any
                            // unsaved-changes question is asked.
                            listFocused = true
                            DispatchQueue.main.async { editor.select(key) }
                        }
                    }
                }
                if listing.noMatch {
                    SettingsRow(selected: false) {
                        Text(String(localized: "No matching squad templates", comment: "设置窗口：搜索后小队模版列表里一个都不剩"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, SettingsLayout.rowGap)
        }
        // A row chosen with ↑↓, or by a route from elsewhere, is scrolled to.
        .onChange(of: editor.selection) { key in
            if let key { scroller.scrollTo(key) }
        } }
        .settingsListFocus()
        .focused($listFocused)
        .onMoveCommand { direction in
            guard let delta = direction.rowDelta,
                  let next = SettingsRules.step(
                    from: editor.isNew ? nil : editor.selection,
                    in: listing.visible,
                    by: delta)
            else { return }
            editor.select(next)
        }
        .overlay { sidebarEmptyState }
    }

    /// What the search leaves of the list. The breadcrumb asks the same
    /// question, so both come from here.
    static func listing(library: SquadLibrary, editor: SquadLibraryEditor, query: String) -> SettingsRules.Listing {
        SettingsRules.listing(
            items: library.catalog.squads.map { ($0.key, $0.displayName) },
            query: query,
            selection: editor.isNew ? nil : editor.draft?.key)
    }

    @ViewBuilder
    private var sidebarEmptyState: some View {
        if library.catalog.squads.isEmpty && !editor.isNew {
            VStack(spacing: 6) {
                if !library.catalog.loaded {
                    Text(String(localized: "Reading the squad templates…", comment: "小队模版：还没读到模版文件"))
                } else {
                    Text(String(localized: "No squad templates yet", comment: "小队模版：一个模版都没有"))
                        .font(.headline)
                    Text(String(localized: "A template is the set of seats a task is handed out to: an alias, the role it is built on, and what that seat does differently.", comment: "小队模版：空列表时解释模版是什么"))
                        .font(SettingsFont.minimum)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "New Squad Template", comment: "小队模版：新建模版的默认名字")) { editor.newSquad() }
                        .padding(.top, 4)
                }
            }
            .foregroundStyle(.secondary)
            .padding()
        }
    }

    private func squadRow(_ squad: Squad, unsaved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OfficialMark.gap) {
                Text(squad.displayName).lineLimit(1)
                if squad.origin == .supervisor {
                    Text(String(localized: "Supervisor's", comment: "小队模版：列表行的标记，这个模版是总管建的"))
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.secondary)
                }
                if unsaved || (squad.key == editor.draft?.key && editor.isDirty) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .help(String(localized: "Unsaved changes", comment: "角色库：有未保存的修改"))
                }
            }
            Text(squad.summary.isEmpty ? SquadRules.memberCountText(squad) : squad.summary)
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: Detail column

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let error = library.catalog.error {
                banner(String(localized: "The squad templates file has an error in it. Templates can't be changed here until it's fixed.", comment: "小队模版：squads.json 解析失败的横幅"), detail: error)
            }
            if let draft = editor.draft {
                if let member = editor.member, draft.member(member) != nil {
                    memberPage(draft, alias: member)
                } else {
                    squadPage(draft)
                }
            } else {
                Spacer()
                Text(String(localized: "Select a squad template, or make a new one.", comment: "小队模版：右侧没有选中模版时的提示"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func squadPage(_ squad: Squad) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.groupGap) {
                basics
                memberTable(squad)
            }
            .padding(SettingsLayout.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var draftBinding: Binding<Squad> {
        Binding(get: { editor.draft ?? Squad(key: "", name: "") }, set: { editor.draft = $0 })
    }

    /// The name, and -- while the template is new -- the key that follows it.
    /// A key is a route name (`dev-docs/poltergeist/settings.md` §3.1) shared
    /// with the Windows host, so an existing one is shown but not typed into: a
    /// changed key would write a second template rather than rename this one.
    private var nameBinding: Binding<String> {
        Binding(
            get: { editor.draft?.name ?? "" },
            set: { name in
                editor.draft?.name = name
                guard editor.isNew else { return }
                let taken = Set(library.catalog.squads.map(\.key))
                editor.draft?.key = SquadRules.suggestedKey(for: name, avoiding: taken)
            })
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
            formRow(String(localized: "Name", comment: "角色库：字段名，角色名")) {
                TextField("", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
            }
            formRow(String(localized: "Key", comment: "角色库：字段名，角色的内部 key")) {
                if editor.isNew {
                    TextField("", text: draftBinding.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                } else {
                    lockedField(editor.draft?.key ?? "", monospaced: true, why: String(localized: "A key is what the Windows host calls this template too, so it is set once and does not change.", comment: "小队模版：已存在的模版 key 不可改的说明"))
                }
            }
            formRow(String(localized: "Description", comment: "小队模版：字段名，模版的说明")) {
                TextField("", text: draftBinding.summary)
                    .textFieldStyle(.roundedBorder)
            }
            if SquadRules.byteLength(editor.draft?.summary ?? "") > SquadRules.maxSummaryLength {
                formControl {
                    note(String(format: String(localized: "At most %d characters.", comment: "小队模版：别名过长，%d 是上限"), SquadRules.maxSummaryLength))
                }
            }
            if editor.draft?.origin == .supervisor {
                formControl {
                    note(String(localized: "Made by a supervisor, which is why it carries a reason. Saving it here keeps that reason.", comment: "小队模版：总管建的模版在页面上的说明"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Members table

    private func memberTable(_ squad: Squad) -> some View {
        let problems = editor.aliasProblems
        return section(String(localized: "Members", comment: "小队模版：分区名，成员")) {
            VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
                if !squad.members.isEmpty {
                    memberHeader
                }
                if squad.members.isEmpty {
                    note(String(localized: "No members yet. A template with no members can be saved; opening a task with it makes a squad with no seats.", comment: "小队模版：成员为空时的说明"))
                }
                ForEach(Array(squad.members.enumerated()), id: \.offset) { index, member in
                    memberRow(index: index, member: member, problem: problems[index])
                }
                addMemberButton
            }
        }
    }

    /// The three columns the rows below are read across: alias, role, and
    /// what the seat is in this squad.
    private var memberHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.labelGap) {
            Text(String(localized: "Alias", comment: "小队模版：成员表列标题，别名"))
                .frame(width: squadAliasColumn, alignment: .leading)
            Text(String(localized: "Role", comment: "小队模版：成员表列标题，角色"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "In the squad", comment: "小队模版：成员表列标题，必选还是可选"))
                .frame(width: squadRequiredColumn, alignment: .leading)
            Spacer().frame(width: squadChevronColumn)
        }
        .font(SettingsFont.minimum)
        .foregroundStyle(.secondary)
    }

    private func memberRow(index: Int, member: SquadMember, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.labelGap) {
                TextField(roleName(member.role), text: memberAliasBinding(index))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: squadAliasColumn)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(problem == nil ? Color.clear : Color.red))
                VStack(alignment: .leading, spacing: 1) {
                    Text(roleName(member.role)).lineLimit(1)
                    Text(roleSummary(member.role))
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: requiredBinding(index)) {
                    Text(String(localized: "Required", comment: "小队模版：成员行，必选")).tag(true)
                    Text(String(localized: "Optional", comment: "小队模版：成员行，可选")).tag(false)
                }
                .labelsHidden()
                .frame(width: squadRequiredColumn)
                Button {
                    editor.member = member.alias
                } label: {
                    Image(systemName: "chevron.right").frame(width: squadChevronColumn)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "What this seat changes about its role.", comment: "小队模版：成员行行尾按钮的说明"))
            }
            // The alias is what the task panel and the squad's channel call
            // this seat by, so a name that cannot be used is said under the box
            // it was typed into -- and Save stays greyed.
            if let problem {
                Text(problem)
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if member.roleMissing {
                Text(String(localized: "The role this seat names is not in the role library any more.", comment: "小队模版：成员的角色已经不在角色库里"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if member.supervisorRole {
                Text(String(localized: "This role is a supervisor, and a supervisor cannot be a member: take the seat out, or stop the role being one.", comment: "小队模版：成员的角色是总管角色时的说明"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive) {
                editor.removeMember(member.alias)
            } label: {
                Label(String(localized: "Remove Member", comment: "小队模版：右键菜单，移除成员"), systemImage: "trash")
            }
        }
    }

    private func memberAliasBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let members = editor.draft?.members, members.indices.contains(index) else { return "" }
                return members[index].alias
            },
            set: { alias in editor.updateMember(at: index) { $0.alias = alias } })
    }

    private func requiredBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let members = editor.draft?.members, members.indices.contains(index) else { return false }
                return members[index].required
            },
            set: { on in editor.updateMember(at: index) { $0.required = on } })
    }

    /// The roles that may join, and **the two supervisor kinds are not listed
    /// at all** rather than shown greyed (`FINAL.md`, v5 item 6): a row that
    /// cannot be picked is a row that invites a click.
    private var addMemberButton: some View {
        let addable = SquadRules.addable(roles)
        return HStack(spacing: SettingsLayout.rowGap) {
            Button(String(localized: "Add Member…", comment: "小队模版：添加成员")) { editor.adding = true }
                .disabled(addable.isEmpty || library.catalog.error != nil)
                .popover(isPresented: $editor.adding, arrowEdge: .bottom) {
                    addMemberPanel(addable)
                }
            if addable.isEmpty {
                note(String(localized: "There is no role here that may join a squad.", comment: "小队模版：角色库里没有能加入小队的角色时说明"))
            }
        }
    }

    private func addMemberPanel(_ addable: [Role]) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
            Text(String(localized: "Add a member", comment: "小队模版：添加成员弹层标题"))
                .font(.headline)
            ScrollView {
                VStack(spacing: SettingsLayout.rowGap / 4) {
                    ForEach(addable, id: \.key) { role in
                        SettingsRow(selected: false) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(role.displayName.isEmpty ? role.key : role.displayName)
                                    .lineLimit(1)
                                if !role.displaySummary.isEmpty {
                                    Text(role.displaySummary)
                                        .font(SettingsFont.minimum)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onTapGesture { editor.addMember(role) }
                    }
                }
            }
            .frame(width: 260, height: 200)
            note(String(localized: "A supervisor role can't join a squad, so none of them is listed here.", comment: "小队模版：添加成员弹层里，总管角色不列出的说明"))
        }
        .padding(SettingsLayout.pad)
    }

    private func roleName(_ key: String) -> String {
        guard let role = roles.first(where: { $0.key == key }) else { return key }
        return role.displayName.isEmpty ? role.key : role.displayName
    }

    private func roleSummary(_ key: String) -> String {
        roles.first(where: { $0.key == key })?.displaySummary ?? ""
    }

    // MARK: One seat's page

    @ViewBuilder
    private func memberPage(_ squad: Squad, alias: String) -> some View {
        if let member = squad.member(alias), let role = roles.first(where: { $0.key == member.role }) {
            seatNotice(squad, member, role)
            ScrollView {
                memberForm(member, role: role)
                    .padding(SettingsLayout.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let member = squad.member(alias) {
            // The role is gone from the library, so there is nothing to
            // inherit from and nothing to show as its own. The core says the
            // same thing with `role_missing`.
            banner(
                String(localized: "This seat is built on a role that is not in the role library.", comment: "小队模版：成员页，角色不在了"),
                detail: member.role)
            Spacer()
        }
    }

    /// What this page is, above it: which seat of which template, what it is
    /// built on, and what the marks under the fields mean. The style is the
    /// roles page's "the official version has changed" bar
    /// (`RoleLibraryView.swift`), so the two read as the same kind of notice.
    private func seatNotice(_ squad: Squad, _ member: SquadMember, _ role: Role) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(format: String(localized: "\"%@\" in %@ — built on the role %@", comment: "小队模版：成员页顶部提示条，%1$@ 是别名，%2$@ 是模版名，%3$@ 是角色名"),
                           member.alias, squad.displayName, role.displayName),
                    systemImage: "arrow.triangle.branch")
                Text(String(localized: "What says it is inherited follows the role. What you change here is this seat's and no other's.", comment: "小队模版：成员页顶部提示条的第二行"))
                    .font(SettingsFont.minimum)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(String(localized: "Back to the Template", comment: "小队模版：从成员页回到模版页")) { editor.member = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsLayout.pad)
        .padding(.vertical, SettingsLayout.rowGap + 4)
        .background(Color.accentColor.opacity(0.08))
    }

    private func memberForm(_ member: SquadMember, role: Role) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.groupGap) {
            section(String(localized: "Identity", comment: "小队模版：成员页分区名，身份")) {
                VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
                    formRow(String(localized: "Alias", comment: "小队模版：成员表列标题，别名")) {
                        lockedField(member.alias, why: String(localized: "A seat's name inside the squad. It is edited on the template's own page, beside the other seats.", comment: "小队模版：成员页别名只读的说明"))
                    }
                    formRow(String(localized: "Name", comment: "角色库：字段名，角色名")) {
                        lockedField(role.displayName, why: String(localized: "The role's own. A seat is not given a name of its own.", comment: "小队模版：成员页名称只读的说明"))
                    }
                    formRow(String(localized: "Key", comment: "角色库：字段名，角色的内部 key")) {
                        lockedField(role.key, monospaced: true, why: String(localized: "The role's own, and what the core stores this seat against.", comment: "小队模版：成员页 key 只读的说明"))
                    }
                    formRow(String(localized: "Description", comment: "小队模版：字段名，模版的说明")) {
                        lockedField(role.displaySummary, why: String(localized: "The role's own. A seat changes the CLI, what the agent is told, and its skills -- nothing about who it is.", comment: "小队模版：成员页描述只读的说明"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            section(String(localized: "Instructions", comment: "角色库：分区名，给 agent 的指令")) {
                MemberInstructions(editor: editor, alias: member.alias)
            }
            section(String(localized: "Agent CLI", comment: "角色库：分区名，Agent CLI")) {
                cliRow(member, role: role)
            }
        }
    }

    /// Which CLI this seat starts in. Present-and-set is this seat's word,
    /// absent is the role's (`SquadOverride.cli`), and the mark under the
    /// control says which -- the same place the General page puts its notes.
    private func cliRow(_ member: SquadMember, role: Role) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
            formRow(String(localized: "CLI", comment: "角色库：字段名，Agent CLI")) {
                Picker("", selection: cliBinding(member)) {
                    Text(role.clis.isEmpty
                         ? String(localized: "The role's own", comment: "小队模版：成员页 CLI 选择，跟着角色")
                         : String(format: String(localized: "The role's own (%@)", comment: "小队模版：成员页 CLI 选择，%@ 是角色自己的 CLI"), role.clis.map(\.cli).joined(separator: ", ")))
                        .tag("")
                    ForEach(role.clis, id: \.cli) { choice in
                        Text(choice.cli).tag(choice.cli)
                    }
                }
                .labelsHidden()
            }
            formControl {
                mark(
                    member.override.cli == nil ? .inherited : .overridden,
                    back: member.override.cli == nil
                        ? nil
                        : { editor.updateMember(member.alias) { $0.override.cli = nil } })
            }
        }
    }

    private func cliBinding(_ member: SquadMember) -> Binding<String> {
        Binding(
            get: { member.override.cli ?? "" },
            set: { key in editor.updateMember(member.alias) { $0.override.cli = key.isEmpty ? nil : key } })
    }

    // MARK: Bottom band

    private var listButtons: some View {
        HStack(spacing: SettingsLayout.rowGap / 2) {
            iconButton("plus", help: String(localized: "New Squad Template", comment: "小队模版：新建模版的默认名字")) {
                editor.newSquad()
            }
            .disabled(library.catalog.error != nil)
            iconButton("plus.square.on.square", help: String(localized: "Duplicate Squad Template", comment: "小队模版：复制所选模版")) {
                editor.duplicate()
            }
            .disabled(editor.draft == nil || library.catalog.error != nil)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// The one bar in the bottom band: list buttons at the list's left edge,
    /// then the status line, then Save, Discard Changes and the deletion.
    private var bar: some View {
        HStack(spacing: SettingsLayout.rowGap) {
            listButtons
                .padding(.trailing, SettingsLayout.rowGap)
            Group {
                if let status = editor.status {
                    Label(status, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if editor.hasAliasProblem {
                    Text(String(localized: "Two seats of this squad have the same alias.", comment: "小队模版：别名重复时底栏提示"))
                        .foregroundStyle(.red)
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
            Button(String(localized: "Save", comment: "角色库：保存按钮")) { editor.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.isDirty || editor.hasAliasProblem || editor.hasSummaryProblem || library.catalog.error != nil)
            Button(String(localized: "Discard Changes", comment: "角色库：放弃未保存的修改，回到已保存的版本")) { editor.revert() }
                .disabled(!editor.isDirty)
            Button(String(localized: "Delete Squad Template", comment: "小队模版：删除模版按钮")) { editor.delete() }
                .foregroundStyle(.red)
                .disabled(editor.draft == nil || editor.isNew || library.catalog.error != nil)
        }
        .controlSize(.large)
        .padding(.leading, SettingsLayout.ContentEdge.bottomBar)
        .padding(.trailing, SettingsLayout.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chrome

    /// 「继承自角色」or「小队覆盖」under a field, with the way back to the
    /// role when it can be taken (`FINAL.md` decision 2: the marks go under
    /// the boxes, where the General page puts its notes).
    private func mark(_ source: SquadFieldSource, back: (() -> Void)? = nil) -> some View {
        HStack(spacing: SettingsLayout.rowGap) {
            Text(source.mark)
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
            if source == .overridden, let back {
                Button(String(localized: "Follow the role again", comment: "小队模版：把字段恢复成继承角色")) { back() }
                    .buttonStyle(.link)
                    .font(SettingsFont.minimum)
            }
        }
    }

    /// A field that is shown and cannot be changed, with the lock that says so
    /// and why it cannot be.
    private func lockedField(_ text: String, monospaced: Bool = false, why: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "lock.fill")
                .font(SettingsFont.minimum)
                .foregroundStyle(.secondary)
                .help(why)
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
}

/// The instructions field of one seat: the role's text until the person types,
/// and this seat's from then on -- **including an empty box**, which is the
/// seat saying "this one gets none" (`SquadOverride.instructions`). That is why
/// the mark, and not the text, is what tells the two apart.
private struct MemberInstructions: View {
    @ObservedObject var editor: SquadLibraryEditor
    var alias: String

    @AppStorage("SquadLibrary.instructionsHeight") private var height: Double = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: text)
                .font(.body)
                .frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(String(localized: "Instructions", comment: "角色库：分区名，给 agent 的指令"))
            ResizeGrip(height: $height, range: 100...900)
            if source == .inherited {
                markText
            } else {
                HStack(spacing: SettingsLayout.rowGap) {
                    markText
                    Button(String(localized: "Follow the role again", comment: "小队模版：把字段恢复成继承角色")) {
                        editor.updateMember(alias) { $0.override.instructions = nil }
                    }
                    .buttonStyle(.link)
                    .font(SettingsFont.minimum)
                }
            }
        }
    }

    private var markText: some View {
        Text(source.mark)
            .font(SettingsFont.minimum)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: Binding<String> {
        Binding(
            get: { editor.draft?.member(alias)?.override.instructions ?? "" },
            set: { typed in editor.updateMember(alias) { $0.override.instructions = typed } })
    }

    private var source: SquadFieldSource {
        (editor.draft?.member(alias)?.override.instructions) == nil ? .inherited : .overridden
    }
}

/// The shared chrome this file needs and `RoleLibraryView.swift` keeps to
/// itself (`private` there is private to that file): a titled section, and a
/// secondary line under a control.
@ViewBuilder
private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: SettingsLayout.rowGap) {
        Text(title).font(.headline)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(SettingsFont.minimum)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
