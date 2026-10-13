import SwiftUI

/// "Save as Project": a name, and which tabs of this window become the
/// project's pages. What is listed, what is ticked to begin with and when
/// the button can be pressed are `ProjectPageRules`; this draws them.
///
/// On one grid: every text and every control starts at `Grid.pad`, a row's
/// title starts one checkbox and one gap in from that, and everything at
/// the right ends at the width less `Grid.pad`.
struct ProjectSaveAsView: View {
    enum Grid {
        static let width: CGFloat = 460
        static let pad: CGFloat = 20
        static let row: CGFloat = 28
        static let gap: CGFloat = 8
        static let check: CGFloat = 14
        /// As many rows as are shown before the list scrolls.
        static let rowsShown = 6
    }

    let tabs: [ProjectPageRules.Tab]
    let store: ProjectStore
    /// The name, and the ids of the tabs to save, in the order of the tabs.
    var onSave: (String, [Int]) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var checked: Set<Int> = []
    @State private var pendingOverwrite: ProjectStore.Entry?
    @FocusState private var nameFocused: Bool

    private var rows: [ProjectPageRules.Row] { ProjectPageRules.saveAsRows(tabs) }

    /// The window's content size, known before it is shown so that it can
    /// be centred (see `ProjectPicker`).
    static func size(rows: Int) -> CGSize {
        let listed = CGFloat(min(max(rows, 1), Grid.rowsShown)) * Grid.row
        // pad, name label, field, gap, list label, list, gap, sentence
        // (two lines), gap, buttons, pad.
        return CGSize(width: Grid.width, height: Grid.pad + 20 + Grid.gap + Grid.row + 16 + 20 + Grid.gap + listed + 16 + 36 + 16 + Grid.row + Grid.pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Name", comment: "存为项目：名字一栏的标题"))
                .frame(height: 20)
            TextField(String(localized: "New Project Name", comment: "另存为项目：新建项目的名字输入框占位文字"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
                .frame(height: Grid.row)
                .padding(.top, Grid.gap)

            Text(String(localized: "Tabs of this window to save", comment: "存为项目：下面列出本窗口各页的那一栏标题"))
                .frame(height: 20)
                .padding(.top, 16)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        pageRow(row)
                    }
                }
            }
            .frame(height: CGFloat(min(max(rows.count, 1), Grid.rowsShown)) * Grid.row)
            .padding(.top, Grid.gap)

            Text(String(localized: "Once saved, these tabs are saved back to the project whenever their layout changes. There is no need to save again.", comment: "存为项目：框底下说明后果的那句话"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 36, alignment: .topLeading)
                .padding(.top, 16)

            HStack(spacing: Grid.gap) {
                Spacer()
                Button(String(localized: "Cancel", comment: "项目选择界面：取消按钮")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save as Project", comment: "项目选择界面标题：另存为项目")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ProjectPageRules.canSave(name: name, checked: checked, rows: rows))
            }
            .frame(height: Grid.row)
            .padding(.top, 16)
        }
        .font(SettingsFont.minimum)
        .padding(Grid.pad)
        .frame(width: Grid.width, height: Self.size(rows: rows.count).height, alignment: .topLeading)
        .onAppear {
            checked = ProjectPageRules.initiallyChecked(tabs)
            nameFocused = true
        }
        .alert(
            String(localized: "Overwrite Project?", comment: "覆盖确认框标题"),
            isPresented: Binding(get: { pendingOverwrite != nil }, set: { if !$0 { pendingOverwrite = nil } }),
            presenting: pendingOverwrite
        ) { entry in
            Button(String(localized: "Cancel", comment: "覆盖确认框：取消按钮"), role: .cancel) {}
            Button(String(localized: "Overwrite", comment: "覆盖确认框：覆盖按钮"), role: .destructive) {
                onSave(entry.name, ProjectPageRules.tabsToSave(checked: checked, rows: rows))
            }
        } message: { entry in
            Text(String(localized: "\"\(entry.name)\" already has \(ProjectPageRules.size(pages: entry.pageCount, panes: entry.totalPaneCount)), saved \(Self.dateFormatter.string(from: entry.savedAt)). The replaced version is kept as the previous version.", comment: "存为项目：覆盖确认框正文，参数依次是项目名、几页几格、保存时间"))
        }
    }

    private func pageRow(_ row: ProjectPageRules.Row) -> some View {
        HStack(spacing: Grid.gap) {
            Toggle("", isOn: Binding(
                get: { row.canCheck && checked.contains(row.id) },
                set: { on in
                    if on { checked.insert(row.id) } else { checked.remove(row.id) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: Grid.check)
                .disabled(!row.canCheck)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.canCheck ? .primary : .tertiary)
            Spacer(minLength: Grid.gap)
            Text(ProjectPageRules.text(row.note))
                .lineLimit(1)
                .foregroundStyle(row.canCheck ? .secondary : .tertiary)
        }
        .frame(height: Grid.row)
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.canCheck else { return }
            if checked.contains(row.id) { checked.remove(row.id) } else { checked.insert(row.id) }
        }
    }

    /// A typed name that is already a project's is that project being
    /// replaced: it asks first (#980).
    private func save() {
        let ids = ProjectPageRules.tabsToSave(checked: checked, rows: rows)
        guard ProjectPageRules.canSave(name: name, checked: checked, rows: rows) else { return }
        switch ProjectsRules.saveAsStep(store.nameVerdict(current: nil, proposed: name)) {
        case .save(let name):
            onSave(name, ids)
        case .confirmOverwrite(let existing):
            pendingOverwrite = store.entry(name: existing)
        case .nothing:
            return
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
