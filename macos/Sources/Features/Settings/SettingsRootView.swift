import AppKit
import SwiftUI

/// The settings window, laid out on one grid (settings.md §2.3a): a band
/// across the top, the body, a band across the bottom. The rules between
/// them run the whole width and are drawn here, once, not by each block.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var library: RoleLibrary
    @ObservedObject var editor: RoleLibraryEditor
    @ObservedObject var plugins: PluginsPane
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
            hidden = false
        } else if model.section == .projects, let name = projects.selected?.name {
            item = name
            hidden = false
        } else if model.section == .general {
            item = model.general.group.title
        }
        if model.section == .plugins, let plugin = plugins.plugin {
            item = plugin.name
            hidden = false
        }
        if model.results != nil {
            return String(localized: "Search", comment: "设置窗口：侧栏搜索框占位文字")
        }
        return SettingsRules.breadcrumb(section: model.section.title, item: item, hiddenBySearch: hidden)
    }

    // MARK: Body

    /// Drawn rows rather than a `List`: a list's cells carry insets of
    /// their own that SwiftUI does not let us set, and the highlight has to
    /// share its edges with the search box above it.
    private var sections: some View {
        ScrollView {
            VStack(spacing: L.rowGap / 4) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsRow(selected: sidebarSelection == .section(section), inset: L.padSidebar) {
                        Label(section.title, systemImage: section.symbol)
                    }
                    .onTapGesture {
                        // Focus first, the switch on the next turn: the switch can
                        // ask about unsaved changes, and a modal question asked
                        // before the focus has moved leaves it, once answered, in
                        // the column that did not ask (#896 W35).
                        sectionsFocused = true
                        DispatchQueue.main.async { go(.section(section)) }
                    }

                    // Each plugin is a page of settings of its own, so the
                    // Plugins section lists them here, under itself, with
                    // their dots (settings.md §2.3, §5.1).
                    if section == .plugins {
                        PluginSidebarRows(
                            pane: plugins,
                            query: "",
                            selected: { sidebarSelection == .plugin($0) },
                            onSelect: { key in
                                sectionsFocused = true
                                DispatchQueue.main.async { go(.plugin(key)) }
                            })
                    }
                }
            }
            .padding(.top, L.rowGap)
        }
        .searchDimmed(model.results != nil)
        // ↑↓ like the list this replaced, through the plugins too.
        .settingsListFocus()
        .focused($sectionsFocused)
        .onMoveCommand { direction in
            guard let delta = direction.rowDelta,
                  let next = SettingsRules.step(from: sidebarSelection, in: sidebarEntries, by: delta)
            else { return }
            go(next)
        }
    }

    /// A row of the sidebar: a section, or one plugin under Plugins.
    private enum SidebarEntry: Hashable {
        case section(SettingsSection)
        case plugin(String)
    }

    /// The rows in order, as ↑↓ walks them: the plugins the search leaves,
    /// right after Plugins.
    private var sidebarEntries: [SidebarEntry] {
        SettingsSection.allCases.flatMap { section -> [SidebarEntry] in
            guard section == .plugins else { return [.section(section)] }
            return [.section(section)] + plugins.listing(query: "").visible.map { .plugin($0) }
        }
    }

    /// In Plugins with one chosen, that plugin's row is the highlighted one
    /// rather than the section's.
    private var sidebarSelection: SidebarEntry {
        if model.section == .plugins, let key = plugins.selection { return .plugin(key) }
        return .section(model.section)
    }

    private func go(_ entry: SidebarEntry) {
        switch entry {
        case .section(let section): model.go(section)
        case .plugin(let key): model.goPlugin(key)
        }
    }

    /// While there is a search the detail area is the list of what was
    /// found; the columns beside it stay where they were, greyed and out of
    /// reach, and nothing in them is filtered (screenshot.md §12.2).
    @ViewBuilder
    private var content: some View {
        let searching = model.results != nil
        switch model.section {
        case .roles:
            HStack(spacing: 0) {
                roles(.list)
                    .frame(width: L.list)
                    .searchDimmed(searching)
                vRule
                detail(searching) { roles(.detail) }
            }
        case .plugins:
            detail(searching) { PluginsView(pane: plugins, part: .detail) }
        case .projects:
            HStack(spacing: 0) {
                projectsPart(.list)
                    .frame(width: L.list)
                    .searchDimmed(searching)
                vRule
                detail(searching) { projectsPart(.detail) }
            }
        case .general:
            HStack(spacing: 0) {
                generalPart(.list)
                    .frame(width: L.list)
                    .searchDimmed(searching)
                vRule
                detail(searching) { generalPart(.detail) }
            }
        }
    }

    @ViewBuilder
    private func detail<Page: View>(_ searching: Bool, @ViewBuilder page: () -> Page) -> some View {
        // The detail area is whatever the columns to its left leave, and
        // what is in it is laid out inside that -- it is not asked how
        // wide it would like to be. A page that wants more than there is
        // (a control that will not shrink, at the window's narrowest) is
        // cut at the right edge; it used to make the whole row wider than
        // the window, and the row, centred, moved every rule in it a few
        // points to the left of the same rule in the bands above and below.
        Color.clear
            .overlay(alignment: .topLeading) {
                Group {
                    if searching {
                        SettingsSearchResults(model: model)
                    } else {
                        page()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
    }

    // MARK: Bottom band

    /// Present in every section, empty where a section has nothing to put
    /// there, so the body does not change height between sections.
    @ViewBuilder
    private var bar: some View {
        if model.results != nil {
            // The bar belongs to the page the results are covering.
            Color.clear
        } else {
            sectionBar
        }
    }

    @ViewBuilder
    private var sectionBar: some View {
        switch model.section {
        case .roles: roles(.bar)
        case .plugins: PluginsView(pane: plugins, part: .bar)
        case .projects: projectsPart(.bar)
        case .general: generalPart(.bar)
        }
    }

    private func generalPart(_ part: GeneralView.Part) -> some View {
        GeneralView(model: model.general, part: part)
    }

    private func projectsPart(_ part: ProjectsView.Part) -> some View {
        ProjectsView(model: projects, part: part, filter: "")
    }

    private func roles(_ part: RoleLibraryView.Part) -> some View {
        RoleLibraryView(
            library: library,
            editor: editor,
            part: part,
            filter: "",
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
    /// A column the search results are beside: still there, greyed, and
    /// not to be clicked while the results are what the window is showing.
    func searchDimmed(_ dimmed: Bool) -> some View {
        opacity(dimmed ? 0.35 : 1).allowsHitTesting(!dimmed)
    }

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
