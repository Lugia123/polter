import SwiftUI

/// What this picker is opened for. Saving has its own sheet now
/// (`ProjectSaveAsView`), and managing projects is the settings window's
/// Projects section (settings.md §6); what is left here is choosing one to
/// open.
enum ProjectPickerMode: Equatable {
    /// Tab right-click / `Project` menu "Load Project...".
    case load

    /// The picker window's title.
    var title: String {
        switch self {
        case .load: return String(localized: "Load Project", comment: "项目选择界面标题：加载项目")
        }
    }
}

/// The list of projects to open one from: search, and a row per project
/// saying how big it is and when it was saved.
struct ProjectPickerView: View {
    let mode: ProjectPickerMode
    let store: ProjectStore

    var onLoad: (ProjectStore.Entry) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @State private var entries: [ProjectStore.Entry] = []
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    /// The window's content size. `ProjectPicker` sizes the window to this
    /// before centering it: a hosting window has no size until it is shown,
    /// and centering it then leaves it up and to the right of the middle.
    static let size = CGSize(width: 420, height: 380)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            Divider()

            if entries.isEmpty {
                emptyState(String(localized: "No Saved Projects", comment: "项目列表为空时的占位文字"))
            } else if visibleEntries.isEmpty {
                emptyState(String(localized: "No matching projects", comment: "设置窗口·项目：搜索后项目列表里一个都不剩"))
            } else {
                List(visibleEntries) { entry in
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
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { reload() }
    }

    // MARK: - Rows

    private var searchRow: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search", comment: "搜索框占位文字"), text: $query)
                .focused($searchFocused)
                .onSubmit(loadOnlyMatch)
                .textFieldStyle(.roundedBorder)
        }
        .padding([.top, .horizontal])
        .padding(.bottom, 8)
    }

    /// What the search leaves of the list: the same rule the settings
    /// window's Projects section filters by.
    private var visibleEntries: [ProjectStore.Entry] {
        let visible = SettingsRules.listing(
            items: entries.map { ($0.name, $0.name) },
            query: query,
            selection: nil).visible
        return entries.filter { visible.contains($0.name) }
    }

    private func row(for entry: ProjectStore.Entry) -> some View {
        Button {
            handleTap(entry)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text(subtitle(for: entry))
                        .font(SettingsFont.minimum)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func handleTap(_ entry: ProjectStore.Entry) {
        onLoad(entry)
    }

    /// Return in the search field loads the project when the search has
    /// narrowed the list to one; with more left it is still a choice.
    private func loadOnlyMatch() {
        let visible = visibleEntries
        guard visible.count == 1 else { return }
        onLoad(visible[0])
    }

    private func reload() {
        entries = store.list()
        searchFocused = true
    }

    // MARK: - Copy

    private func subtitle(for entry: ProjectStore.Entry) -> String {
        String(localized: "\(ProjectPageRules.size(pages: entry.pageCount, panes: entry.totalPaneCount)) · saved \(Self.dateFormatter.string(from: entry.savedAt))", comment: "项目列表每一行的副标题：几页几格和保存时间")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
