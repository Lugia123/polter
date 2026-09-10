import SwiftUI

/// The three ways this picker gets opened, each shaping what the list of
/// projects does when a row is picked.
enum ProjectPickerMode: Equatable {
    /// Tab right-click / `Project` menu "Save as Project...". `currentPaneCount`
    /// is shown next to the "New Project" row so saving into a new project
    /// and overwriting an existing one both show what's about to be written.
    case saveAs(currentPaneCount: Int)
    /// Tab right-click / `Project` menu "Load Project...".
    case load
    /// `Project` menu "Manage Projects...".
    case manage
}

/// The list-and-act UI shared by "Save as Project", "Load Project", and
/// "Manage Projects" -- and by the "save before closing?" prompt, which
/// presents this in `.saveAs` mode. One list, three behaviors for picking a
/// row, kept in one view so the three surfaces can't drift into showing
/// different metadata for the same project.
struct ProjectPickerView: View {
    let mode: ProjectPickerMode
    let store: ProjectStore

    /// The name to save under -- a brand new one, or an existing entry's
    /// (after the overwrite confirm below), which is what overwrites it:
    /// see `ProjectStore.Entry`, where the name *is* the on-disk identity.
    var onSave: (String) -> Void = { _ in }
    var onLoad: (ProjectStore.Entry) -> Void = { _ in }
    var onDelete: (ProjectStore.Entry) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @State private var entries: [ProjectStore.Entry] = []
    @State private var newName: String = ""
    @State private var pendingOverwrite: ProjectStore.Entry?
    @State private var pendingDelete: ProjectStore.Entry?
    @FocusState private var newNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding([.top, .horizontal])
                .padding(.bottom, 8)

            if case .saveAs = mode {
                newProjectRow
                Divider()
            }

            if entries.isEmpty {
                emptyState
            } else {
                List(entries) { entry in
                    row(for: entry)
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "项目选择界面：取消按钮")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 420, height: 380)
        .onAppear { reload() }
        .alert(
            overwriteTitle,
            isPresented: overwriteAlertBinding,
            presenting: pendingOverwrite
        ) { entry in
            Button(String(localized: "Cancel", comment: "覆盖确认框：取消按钮"), role: .cancel) {}
            Button(String(localized: "Overwrite", comment: "覆盖确认框：覆盖按钮"), role: .destructive) {
                onSave(entry.name)
            }
        } message: { entry in
            Text(overwriteMessage(for: entry))
        }
        .alert(
            String(localized: "Delete Project?", comment: "删除确认框标题"),
            isPresented: deleteAlertBinding,
            presenting: pendingDelete
        ) { entry in
            Button(String(localized: "Cancel", comment: "删除确认框：取消按钮"), role: .cancel) {}
            Button(String(localized: "Delete", comment: "删除确认框：删除按钮"), role: .destructive) {
                onDelete(entry)
                entries.removeAll { $0.id == entry.id }
            }
        } message: { entry in
            // One line -- see the note above `overwriteMessage`.
            Text(String(localized: "\"\(entry.name)\" will be permanently deleted.", comment: "删除确认框正文，参数是项目名"))
        }
    }

    // MARK: - Rows

    private var newProjectRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "New Project Name", comment: "另存为项目：新建项目的名字输入框占位文字"),
                    text: $newName
                )
                .focused($newNameFocused)
                .onSubmit(createNew)
                .textFieldStyle(.roundedBorder)

                Button(String(localized: "Save", comment: "另存为项目：新建并保存按钮")) {
                    createNew()
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if case .saveAs(let currentPaneCount) = mode {
                Text(currentPaneCountLabel(currentPaneCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func row(for entry: ProjectStore.Entry) -> some View {
        Button {
            handleTap(entry)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text(subtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .manage = mode {
                    Button {
                        pendingDelete = entry
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(String(localized: "No Saved Projects", comment: "项目列表为空时的占位文字"))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func handleTap(_ entry: ProjectStore.Entry) {
        switch mode {
        case .saveAs:
            pendingOverwrite = entry
        case .load:
            onLoad(entry)
        case .manage:
            // Manage-mode rows only act through the trash button; tapping
            // the row itself does nothing so a stray click can't delete.
            break
        }
    }

    private func createNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }

    private func reload() {
        entries = store.list()
        if case .saveAs = mode {
            newNameFocused = true
        }
    }

    // MARK: - Copy

    private var title: String {
        switch mode {
        case .saveAs: return String(localized: "Save as Project", comment: "项目选择界面标题：另存为项目")
        case .load: return String(localized: "Load Project", comment: "项目选择界面标题：加载项目")
        case .manage: return String(localized: "Manage Projects", comment: "项目选择界面标题：管理项目")
        }
    }

    private var overwriteTitle: String {
        String(localized: "Overwrite Project?", comment: "覆盖确认框标题")
    }

    // Both of these stay on one line -- the Chinese-strings checker only
    // sees `String(localized:` when the literal starts on the same line as
    // the call.
    private func overwriteMessage(for entry: ProjectStore.Entry) -> String {
        String(localized: "\"\(entry.name)\" already has \(entry.paneCount) pane(s), saved \(Self.dateFormatter.string(from: entry.savedAt)). Overwriting it can't be undone.", comment: "覆盖确认框正文，参数依次是项目名、面板数、保存时间")
    }

    private func currentPaneCountLabel(_ count: Int) -> String {
        String(localized: "Saves this tab: \(count) pane(s)", comment: "另存为项目：新建行下方，提示会存下当前 tab 的几个面板")
    }

    private func subtitle(for entry: ProjectStore.Entry) -> String {
        String(localized: "\(entry.paneCount) pane(s) · saved \(Self.dateFormatter.string(from: entry.savedAt))", comment: "项目列表每一行的副标题：面板数和保存时间")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var overwriteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingOverwrite != nil },
            set: { if !$0 { pendingOverwrite = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })
    }
}
