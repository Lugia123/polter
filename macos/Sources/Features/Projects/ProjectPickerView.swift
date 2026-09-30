import SwiftUI

/// The two ways this picker gets opened, each shaping what the list of
/// projects does when a row is picked. Managing projects is the settings
/// window's Projects section now (settings.md §6).
enum ProjectPickerMode: Equatable {
    /// Tab right-click / `Project` menu "Save as Project...". `currentPaneCount`
    /// is shown next to the "New Project" row so saving into a new project
    /// and overwriting an existing one both show what's about to be written.
    case saveAs(currentPaneCount: Int)
    /// Tab right-click / `Project` menu "Load Project...".
    case load
}

/// The list-and-act UI shared by "Save as Project" and "Load Project" --
/// and by the "save before closing?" prompt, which presents this in
/// `.saveAs` mode. One list, two behaviors for picking a row, kept in one
/// view so the surfaces can't drift into showing different metadata for the
/// same project.
struct ProjectPickerView: View {
    let mode: ProjectPickerMode
    let store: ProjectStore

    /// The name to save under -- a brand new one, or an existing entry's
    /// (after the overwrite confirm below), which is what overwrites it:
    /// see `ProjectStore.Entry`, where the name *is* the on-disk identity.
    var onSave: (String) -> Void = { _ in }
    var onLoad: (ProjectStore.Entry) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @State private var entries: [ProjectStore.Entry] = []
    @State private var newName: String = ""
    @State private var pendingOverwrite: ProjectStore.Entry?
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
        }
    }

    /// A typed name that is already a project's is that project being
    /// replaced: it asks first, exactly as picking its row does (#980).
    /// It used to save straight away -- overwriting the project and moving
    /// the tab's binding with no question asked.
    private func createNew() {
        switch ProjectsRules.saveAsStep(store.nameVerdict(current: nil, proposed: newName)) {
        case .save(let name):
            onSave(name)
        case .confirmOverwrite(let existing):
            // The row the name clashes with, read fresh: if it went away in
            // the meantime, show the list as it is now rather than save.
            if let entry = store.entry(name: existing) {
                pendingOverwrite = entry
            } else {
                reload()
            }
        case .nothing:
            return
        }
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
        }
    }

    private var overwriteTitle: String {
        String(localized: "Overwrite Project?", comment: "覆盖确认框标题")
    }

    // Both of these stay on one line -- the Chinese-strings checker only
    // sees `String(localized:` when the literal starts on the same line as
    // the call.
    private func overwriteMessage(for entry: ProjectStore.Entry) -> String {
        String(localized: "\"\(entry.name)\" already has \(String(entry.paneCount)) pane(s), saved \(Self.dateFormatter.string(from: entry.savedAt)). The replaced version is kept as the previous version.", comment: "覆盖确认框正文，参数依次是项目名、面板数、保存时间")
    }

    private func currentPaneCountLabel(_ count: Int) -> String {
        String(localized: "Saves this tab: \(String(count)) pane(s)", comment: "另存为项目：新建行下方，提示会存下当前 tab 的几个面板")
    }

    private func subtitle(for entry: ProjectStore.Entry) -> String {
        String(localized: "\(String(entry.paneCount)) pane(s) · saved \(Self.dateFormatter.string(from: entry.savedAt))", comment: "项目列表每一行的副标题：面板数和保存时间")
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
}
