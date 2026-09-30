import AppKit
import SwiftUI

/// The Projects section of the settings window (settings.md §6): every saved
/// project, and what can be done to one. Nothing here is a draft -- each
/// action is done to the files at once -- so the section has no unsaved
/// state and no Revert / Save.
@MainActor
final class ProjectsModel: ObservableObject {
    let store: ProjectStore

    @Published private(set) var entries: [ProjectStore.Entry] = []
    /// The selected project's name.
    @Published private(set) var selection: String?
    /// The last delete, until the window closes or the next delete.
    @Published private(set) var deleted: ProjectStore.Trashed?
    /// Why the last action failed, in the bottom bar; cleared by the next.
    @Published var status: String?

    init(store: ProjectStore = .shared) {
        self.store = store
    }

    var selected: ProjectStore.Entry? {
        selection.flatMap { name in entries.first { $0.name == name } }
    }

    /// Read the directory again, keeping the selection when it is still
    /// there and otherwise taking the first.
    func reload() {
        entries = store.list()
        if selected == nil { selection = entries.first?.name }
    }

    func select(_ name: String?) {
        selection = name
    }

    /// Where a route lands (§3.1): the named project, else the current
    /// window's, else the first.
    func route(to item: String?) {
        reload()
        select(ProjectsRules.projectToSelect(
            item: item,
            bound: TerminalController.preferredParent?.boundProject,
            names: entries.map(\.name)))
    }

    func listing(query: String) -> SettingsRules.Listing {
        SettingsRules.listing(
            items: entries.map { ($0.name, $0.name) },
            query: query,
            selection: selection)
    }

    /// The tab a project is bound to, by title; nil when none is.
    func holder(of entry: ProjectStore.Entry) -> String? {
        store.holderTitle(name: entry.name)
    }

    // MARK: Actions

    /// Run `action`; on failure say why in the bar. Always reads the
    /// directory again afterwards, so the list shows what is on disk.
    private func attempt(_ action: () throws -> Void) {
        status = nil
        do {
            try action()
        } catch {
            status = error.localizedDescription
        }
        reload()
    }

    /// The tab "Open" goes beside, and "Overwrite with Current Tab" takes
    /// its layout from: the terminal the settings window was opened over.
    var currentTab: TerminalController? { TerminalController.preferredParent }

    func open() {
        guard let entry = selected, let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        attempt { try TerminalController.load(entry, ghostty: ghostty, beside: currentTab?.window) }
    }

    func rename(to name: String) {
        guard let entry = selected else { return }
        attempt {
            let renamed = try store.rename(entry, to: name)
            selection = renamed.name
        }
    }

    func duplicate() {
        guard let entry = selected else { return }
        attempt {
            let copy = try store.duplicate(entry)
            selection = copy.name
        }
    }

    func overwriteWithCurrentTab() {
        guard let entry = selected, let tab = currentTab else { return }
        attempt { try tab.saveAndBind(name: entry.name) }
    }

    func delete() {
        guard let entry = selected else { return }
        let index = entries.firstIndex(of: entry)
        attempt {
            let trashed = try store.trash(entry)
            deleted = ProjectsRules.banner(after: .deleted(trashed), current: deleted)
            selection = nil
        }
        // The row that took its place, rather than jumping to the top.
        if let index, !entries.isEmpty {
            selection = entries[min(index, entries.count - 1)].name
        }
    }

    func undoDelete() {
        guard let trashed = deleted else { return }
        attempt {
            do {
                try store.untrash(trashed)
                deleted = ProjectsRules.banner(after: .undone, current: deleted)
                selection = trashed.name
            } catch {
                deleted = ProjectsRules.banner(after: .undoFailed, current: deleted)
                throw error
            }
        }
    }

    func restorePrevious() {
        guard let entry = selected else { return }
        attempt { try store.restorePrevious(entry) }
    }

    func revealInFinder() {
        guard let entry = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }
}

/// The section's three parts, placed on the settings grid the way the role
/// library's are (settings.md §2.3a): the list column, the detail column,
/// and the one bar across the bottom band.
struct ProjectsView: View {
    enum Part { case list, detail, bar }

    @ObservedObject var model: ProjectsModel
    var part: Part
    var filter: String = ""

    private typealias L = SettingsLayout

    @FocusState private var listFocused: Bool
    @State private var confirmingDelete = false
    @State private var confirmingOverwrite = false
    @State private var confirmingRestore = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        switch part {
        case .list: list
        case .detail: detail
        case .bar: bar
        }
    }

    // MARK: List

    private var list: some View {
        let listing = model.listing(query: filter)
        return VStack(spacing: 0) {
            if let deleted = model.deleted {
                deletedBanner(deleted)
            }
            ScrollViewReader { scroller in ScrollView {
                VStack(spacing: L.rowGap / 4) {
                    ForEach(listing.visible, id: \.self) { name in
                        if let entry = model.entries.first(where: { $0.name == name }) {
                            SettingsRow(selected: model.selection == name) { row(entry) }
                                .id(name)
                                .onTapGesture {
                                    listFocused = true
                                    model.select(name)
                                }
                        }
                    }
                    if listing.noMatch {
                        SettingsRow(selected: false) {
                            Text(String(localized: "No matching projects", comment: "设置窗口·项目：搜索后项目列表里一个都不剩"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, L.rowGap)
            }
            .onChange(of: model.selection) { name in
                if let name { scroller.scrollTo(name) }
            } }
            .settingsListFocus()
            .focused($listFocused)
            .onMoveCommand { direction in
                guard let delta = direction.rowDelta,
                      let next = SettingsRules.step(from: model.selection, in: listing.visible, by: delta)
                else { return }
                model.select(next)
            }
            .overlay {
                if model.entries.isEmpty {
                    Text(String(localized: "No Saved Projects", comment: "项目列表为空时的占位文字"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.reload() }
    }

    private func row(_ entry: ProjectStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).lineLimit(1)
            Text(Self.summary(entry))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "Deleted <name>  [Undo]", over the list, until the window closes or
    /// the next delete (settings.md §6.2).
    private func deletedBanner(_ deleted: ProjectStore.Trashed) -> some View {
        HStack(spacing: L.rowGap) {
            Text(String(localized: "Deleted \(deleted.name)", comment: "设置窗口·项目：删除后列表顶部的横幅，参数是项目名"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(String(localized: "Undo", comment: "设置窗口·项目：撤销删除")) { model.undoDelete() }
        }
        .font(.callout)
        .padding(.horizontal, L.pad)
        .frame(height: L.control + L.rowGap)
        .background(Color.accentColor.opacity(0.10))
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selected {
            ScrollView {
                ProjectDetail(model: model, entry: entry,
                              rename: {
                                  newName = entry.name
                                  renaming = true
                              },
                              restore: { confirmingRestore = true })
                    .padding(L.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .alert(String(localized: "Rename Project", comment: "设置窗口·项目：重命名对话框标题"), isPresented: $renaming) {
                TextField(String(localized: "Name", comment: "设置窗口·项目：重命名输入框占位"), text: $newName)
                Button(String(localized: "Cancel", comment: "设置窗口·项目：取消"), role: .cancel) {}
                Button(String(localized: "Rename", comment: "设置窗口·项目：重命名确认按钮")) { model.rename(to: newName) }
            } message: {
                Text(renameMessage(entry))
            }
            .alert(String(localized: "Restore Previous Version?", comment: "恢复上一版确认框标题"), isPresented: $confirmingRestore) {
                Button(String(localized: "Cancel", comment: "恢复上一版确认框：取消按钮"), role: .cancel) {}
                Button(String(localized: "Restore", comment: "恢复上一版确认框：恢复按钮")) { model.restorePrevious() }
            } message: {
                // One line -- the Chinese-strings checker only sees
                // `String(localized:` when the literal starts on the call's line.
                Text(String(localized: "\"\(entry.name)\" goes back to its layout before the last change. The current version is kept, so doing this again undoes it.", comment: "恢复上一版确认框正文，参数是项目名"))
            }
        } else {
            VStack {
                Spacer()
                Text(String(localized: "Select a project. Save a tab as a project from its right-click menu.", comment: "设置窗口·项目：右侧没有选中项目时的提示"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(L.pad)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func renameMessage(_ entry: ProjectStore.Entry) -> String {
        if let holder = model.holder(of: entry) {
            return String(localized: "The tab \"\(holder)\" stays bound to it under the new name.", comment: "设置窗口·项目：重命名对话框说明，项目已绑定到某个标签页，参数是标签页标题")
        }
        return String(localized: "The project's file, its previous version and its scrollback move with it.", comment: "设置窗口·项目：重命名对话框说明")
    }

    // MARK: Bar

    /// Copy and Delete at the left end, under the list; the status line;
    /// Overwrite with Current Tab and Open on the right.
    private var bar: some View {
        let entry = model.selected
        let tab = model.currentTab
        return HStack(spacing: L.rowGap) {
            HStack(spacing: L.rowGap / 2) {
                iconButton("plus.square.on.square", help: String(localized: "Duplicate Project", comment: "设置窗口·项目：复制一份")) {
                    model.duplicate()
                }
                .disabled(entry == nil)
                iconButton("minus", help: String(localized: "Delete Project", comment: "设置窗口·项目：删除所选项目")) {
                    confirmingDelete = true
                }
                .disabled(entry == nil)
            }
            .padding(.trailing, L.rowGap)
            if let status = model.status {
                Label(status, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if entry != nil, tab == nil {
                // Written out rather than a tooltip (settings.md §4).
                Text(String(localized: "Open a terminal window to overwrite a project with its tab.", comment: "设置窗口·项目：没有终端窗口时无法用当前标签页覆盖"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(String(localized: "Overwrite with Current Tab…", comment: "设置窗口·项目：用发起设置窗口的那个窗口的当前标签页覆盖所选项目")) {
                confirmingOverwrite = true
            }
            .disabled(entry == nil || tab == nil)
            Button(String(localized: "Open", comment: "设置窗口·项目：打开所选项目，同「加载项目…」")) { model.open() }
                .keyboardShortcut(.defaultAction)
                .disabled(entry == nil)
        }
        .controlSize(.large)
        .padding(.leading, L.ContentEdge.bottomBar)
        .padding(.trailing, L.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(String(localized: "Delete Project?", comment: "删除确认框标题"), isPresented: $confirmingDelete) {
            Button(String(localized: "Cancel", comment: "删除确认框：取消按钮"), role: .cancel) {}
            Button(String(localized: "Delete", comment: "删除确认框：删除按钮"), role: .destructive) { model.delete() }
        } message: {
            Text(String(localized: "\"\(entry?.name ?? "")\" moves to the Trash. You can undo this until you close this window.", comment: "设置窗口·项目：删除确认框正文，参数是项目名"))
        }
        .alert(String(localized: "Overwrite Project?", comment: "覆盖确认框标题"), isPresented: $confirmingOverwrite) {
            Button(String(localized: "Cancel", comment: "覆盖确认框：取消按钮"), role: .cancel) {}
            Button(String(localized: "Overwrite", comment: "覆盖确认框：覆盖按钮"), role: .destructive) { model.overwriteWithCurrentTab() }
        } message: {
            Text(String(localized: "\"\(entry?.name ?? "")\" is replaced by the tab \"\(tab?.window?.title ?? "")\" (\(String(tab?.surfaceTree.count ?? 0)) pane(s)), and that tab saves to it from now on. The replaced layout is kept as the previous version.", comment: "设置窗口·项目：用当前标签页覆盖的确认框正文，参数依次是项目名、标签页标题、pane 数"))
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Text

    static func summary(_ entry: ProjectStore.Entry) -> String {
        String(localized: "\(String(entry.paneCount)) pane(s) · saved \(dateFormatter.string(from: entry.savedAt))", comment: "项目列表每一行的副标题：面板数和保存时间")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// What the detail column shows for one project: its name, the layout
/// thumbnail, the facts about it, and its versions.
private struct ProjectDetail: View {
    @ObservedObject var model: ProjectsModel
    let entry: ProjectStore.Entry
    var rename: () -> Void
    var restore: () -> Void

    private typealias L = SettingsLayout

    var body: some View {
        let file = model.store.document(entry)
        let leaves = file?.root.map(Self.leaves) ?? []
        VStack(alignment: .leading, spacing: L.groupGap) {
            HStack(alignment: .firstTextBaseline, spacing: L.rowGap) {
                Text(entry.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: L.rowGap)
                Button(String(localized: "Rename…", comment: "设置窗口·项目：重命名按钮"), action: rename)
                Button(String(localized: "Show in Finder", comment: "设置窗口·项目：在 Finder 中显示项目文件")) {
                    model.revealInFinder()
                }
            }

            if let root = file?.root {
                ProjectThumbnail(pane: Self.pane(root), leaves: leaves)
                    .frame(height: 200)
            }

            VStack(alignment: .leading, spacing: L.rowGap) {
                formRow(String(localized: "Saved", comment: "设置窗口·项目：字段名，上次保存时间")) {
                    Text(ProjectsView.dateFormatter.string(from: entry.savedAt))
                }
                formRow(String(localized: "Panes", comment: "设置窗口·项目：字段名，pane 数")) {
                    Text(String(entry.paneCount))
                }
                formRow(String(localized: "Directories", comment: "设置窗口·项目：字段名，涉及的目录")) {
                    let dirs = ProjectsRules.directories(leaves.map(\.cwd))
                    VStack(alignment: .leading, spacing: 2) {
                        if dirs.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        }
                        ForEach(dirs, id: \.self) { dir in
                            Text((dir as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
                formRow(String(localized: "Scrollback", comment: "设置窗口·项目：字段名，scrollback 占用空间")) {
                    Text(ByteCountFormatter.string(fromByteCount: model.store.scrollbackBytes(entry), countStyle: .file))
                }
                formRow(String(localized: "Autosave", comment: "设置窗口·项目：字段名，自动保存状态")) {
                    Text(autosave)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: L.rowGap) {
                Text(String(localized: "Version History", comment: "设置窗口·项目：版本历史分组标题"))
                    .font(.headline)
                let versions = model.store.versions(entry)
                ForEach(Array(versions.enumerated()), id: \.offset) { _, version in
                    formControl {
                        HStack(spacing: L.rowGap) {
                            Text(ProjectsView.dateFormatter.string(from: version.savedAt))
                                .monospacedDigit()
                            Text(String(localized: "\(String(version.paneCount)) pane(s)", comment: "设置窗口·项目：版本历史一行的 pane 数"))
                                .foregroundStyle(.secondary)
                            if version.isCurrent {
                                Text(String(localized: "Current", comment: "设置窗口·项目：版本历史里当前的那一版"))
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(String(localized: "Restore…", comment: "设置窗口·项目：恢复到这一版"), action: restore)
                            }
                        }
                    }
                }
                if versions.count < 2 {
                    formControl {
                        Text(String(localized: "An earlier version is kept when a save changes the layout: a pane added or closed, or a split turned.", comment: "设置窗口·项目：只有当前版本时解释什么时候会有上一版"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var autosave: String {
        guard let holder = model.holder(of: entry) else {
            return String(localized: "Not bound to an open tab.", comment: "设置窗口·项目：自动保存状态，没有绑定到打开的标签页")
        }
        return String(localized: "Bound to the tab \"\(holder)\"; saved automatically as it changes, last at \(ProjectsView.dateFormatter.string(from: entry.savedAt)).", comment: "设置窗口·项目：自动保存状态，参数依次是标签页标题、上次自动保存时间")
    }

    struct Leaf {
        var cwd: String
        var title: String
    }

    static func leaves(_ node: ProjectNode) -> [Leaf] {
        switch node {
        case .leaf(let cwd, let title, _, _): [Leaf(cwd: cwd, title: title)]
        case .split(_, _, let left, let right): leaves(left) + leaves(right)
        }
    }

    /// The tree with each leaf numbered in the order `leaves` lists them.
    static func pane(_ node: ProjectNode) -> ProjectsRules.Pane {
        var next = 0
        func walk(_ node: ProjectNode) -> ProjectsRules.Pane {
            switch node {
            case .leaf:
                defer { next += 1 }
                return .leaf(next)
            case .split(let direction, let ratio, let left, let right):
                let first = walk(left)
                return .split(sideBySide: direction == .horizontal, ratio: ratio, first, walk(right))
            }
        }
        return walk(node)
    }
}

/// The layout thumbnail (settings.md §6.1): the split tree drawn as boxes,
/// each labelled with its directory's last part and its title.
private struct ProjectThumbnail: View {
    let pane: ProjectsRules.Pane
    let leaves: [ProjectDetail.Leaf]

    var body: some View {
        GeometryReader { geometry in
            let cells = ProjectsRules.cells(of: pane, in: CGRect(origin: .zero, size: geometry.size), gap: 4)
            ZStack(alignment: .topLeading) {
                ForEach(cells, id: \.leaf) { cell in
                    let leaf = cell.leaf < leaves.count ? leaves[cell.leaf] : nil
                    VStack(spacing: 2) {
                        Text(ProjectsRules.directoryLabel(leaf?.cwd ?? ""))
                            .font(.callout.weight(.medium))
                        if let title = leaf?.title, !title.isEmpty {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(4)
                    .frame(width: cell.frame.width, height: cell.frame.height)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor)))
                    .offset(x: cell.frame.minX, y: cell.frame.minY)
                }
            }
        }
    }
}
