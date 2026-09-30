import AppKit
import SwiftUI

/// The settings window, laid out on one grid (settings.md §2.3a): a band
/// across the top, the body, a band across the bottom. The rules between
/// them run the whole width and are drawn here, once, not by each block.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var library: RoleLibrary
    @ObservedObject var editor: RoleLibraryEditor
    @ObservedObject var projects: ProjectsModel
    /// The window's minimum, as content size (settings.md §2.2).
    var minimumContent: CGSize

    private typealias L = SettingsLayout

    @FocusState private var sectionsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                search
                    .frame(width: L.sidebar)
                vRule
                breadcrumb
            }
            .frame(height: L.top)
            hRule
            HStack(spacing: 0) {
                sections
                    .frame(width: L.sidebar)
                vRule
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            hRule
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: L.sidebar)
                vRule
                bar
                    .frame(maxWidth: .infinity)
            }
            .frame(height: L.bottom)
        }
        .frame(minWidth: minimumContent.width, maxWidth: .infinity,
               minHeight: minimumContent.height, maxHeight: .infinity)
        .onAppear {
            SettingsWindowController.logger.info("settings: view up model=\(ObjectIdentifier(model).debugDescription, privacy: .public)")
        }
    }

    private var hRule: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: L.rule)
    }

    private var vRule: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: L.rule)
    }

    // MARK: Top band

    /// Search and breadcrumb are the same height and font, both centred in
    /// the band, so their text shares a baseline.
    private var search: some View {
        TextField(String(localized: "Search", comment: "设置窗口：侧栏搜索框占位文字"), text: $model.search)
            .textFieldStyle(.plain)
            .padding(.horizontal, L.rowGap)
            .frame(height: L.control)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .padding(.leading, L.sidebarSearchEdges.left)
            .padding(.trailing, L.sidebar - L.sidebarSearchEdges.right)
    }

    private var breadcrumb: some View {
        Text(crumb)
            .lineLimit(1)
            .frame(height: L.control)
            .padding(.leading, L.ContentEdge.breadcrumbText)
            .padding(.trailing, L.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var crumb: String {
        var item: String?
        var hidden = false
        if model.section == .roles, let draft = editor.draft {
            item = draft.displayName.isEmpty ? draft.key : draft.displayName
            hidden = RoleLibraryView.listing(library: library, editor: editor, query: model.search).selectionHidden
        } else if model.section == .projects, let name = projects.selected?.name {
            item = name
            hidden = projects.listing(query: model.search).selectionHidden
        }
        return SettingsRules.breadcrumb(section: model.section.title, item: item, hiddenBySearch: hidden)
    }

    // MARK: Body

    /// Drawn rows rather than a `List`: a list's cells carry insets of
    /// their own that SwiftUI does not let us set, and the highlight has to
    /// share its edges with the search box above it.
    private var sections: some View {
        VStack(spacing: L.rowGap / 4) {
            ForEach(SettingsSection.allCases) { section in
                SettingsRow(selected: model.section == section, inset: L.padSidebar) {
                    Label(section.title, systemImage: section.symbol)
                }
                .onTapGesture {
                    // Focus first, the switch on the next turn: the switch can
                    // ask about unsaved changes, and a modal question asked
                    // before the focus has moved leaves it, once answered, in
                    // the column that did not ask (#896 W35).
                    sectionsFocused = true
                    DispatchQueue.main.async { model.go(section) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, L.rowGap)
        // ↑↓ like the list this replaced.
        .settingsListFocus()
        .focused($sectionsFocused)
        .onMoveCommand { direction in
            guard let delta = direction.rowDelta,
                  let next = SettingsRules.step(from: model.section, in: SettingsSection.allCases, by: delta)
            else { return }
            model.go(next)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .roles:
            HStack(spacing: 0) {
                roles(.list)
                    .frame(width: L.list)
                vRule
                roles(.detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .projects:
            HStack(spacing: 0) {
                projectsPart(.list)
                    .frame(width: L.list)
                vRule
                projectsPart(.detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .plugins:
            Text(String(localized: "Coming in a later update.", comment: "设置窗口：项目/插件栏目第一期的占位文字"))
                .foregroundStyle(.secondary)
        case .general:
            VStack(alignment: .leading, spacing: L.rowGap) {
                // The host's own file opener, not `open_config`: that now
                // opens this window.
                Button(String(localized: "Open config file…", comment: "设置窗口：通用栏目，用外部编辑器打开配置文件")) {
                    (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                }
                Spacer()
            }
            .padding(L.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Bottom band

    /// Present in every section, empty where a section has nothing to put
    /// there, so the body does not change height between sections.
    @ViewBuilder
    private var bar: some View {
        switch model.section {
        case .roles: roles(.bar)
        case .projects: projectsPart(.bar)
        case .plugins, .general: Color.clear
        }
    }

    private func projectsPart(_ part: ProjectsView.Part) -> some View {
        ProjectsView(model: projects, part: part, filter: model.search)
    }

    private func roles(_ part: RoleLibraryView.Part) -> some View {
        RoleLibraryView(
            library: library,
            editor: editor,
            part: part,
            filter: model.search,
            canLaunch: { RoleLibraryOpener.launchSurface != nil },
            onLaunch: { role, cli in RoleLibraryOpener.launch(role: role, cli: cli) })
    }
}

/// One selectable row of a column: a highlight `inset` in from the column's
/// edges, and its content `pad - inset` inside that, so the text lands on
/// the column's content edge.
struct SettingsRow<Content: View>: View {
    var selected: Bool
    var inset: CGFloat = SettingsLayout.rowInset
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsLayout.pad - inset)
        .padding(.vertical, SettingsLayout.rowGap / 2)
        .frame(minHeight: SettingsLayout.control)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear))
        .contentShape(Rectangle())
        .padding(.horizontal, inset)
    }
}

extension View {
    /// Takes keyboard focus, for ↑↓ in a list of drawn rows, without the
    /// focus ring around the whole column (the highlight already shows
    /// where you are).
    @ViewBuilder
    func settingsListFocus() -> some View {
        if #available(macOS 14.0, *) {
            focusable().focusEffectDisabled()
        } else {
            focusable()
        }
    }
}

extension MoveCommandDirection {
    /// ↑ is -1, ↓ is 1; ← and → do nothing in a list.
    var rowDelta: Int? {
        switch self {
        case .up: -1
        case .down: 1
        default: nil
        }
    }
}
