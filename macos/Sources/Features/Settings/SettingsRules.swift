import CoreGraphics
import Foundation

// The settings window's rules, with no AppKit in them: routes, sizes, and
// when leaving a section may throw work away. Kept apart so that they can be
// tested without a window, a screen or an app (settings.md §2, §3).

/// The sections of the settings window, in sidebar order. The raw values are
/// the route names in `dev-docs/poltergeist/settings.md` §3.1, shared with the
/// Windows host.
enum SettingsSection: String, CaseIterable, Identifiable {
    case roles, projects, plugins, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roles: String(localized: "Roles", comment: "设置窗口：侧栏栏目，角色")
        case .projects: String(localized: "Projects", comment: "设置窗口：侧栏栏目，项目")
        case .plugins: String(localized: "Plugins", comment: "设置窗口：侧栏栏目，插件")
        case .general: String(localized: "General", comment: "设置窗口：侧栏栏目，通用")
        }
    }

    var symbol: String {
        switch self {
        case .roles: "person.crop.circle"
        case .projects: "square.grid.2x2"
        case .plugins: "puzzlepiece.extension"
        case .general: "gearshape"
        }
    }
}

/// Where the settings window should land: a section, and optionally one
/// item in it (a role key, a project name, a plugin key).
struct SettingsRoute: Equatable {
    var section: SettingsSection
    var item: String?

    static func roles(_ key: String? = nil) -> Self { .init(section: .roles, item: key) }
}

enum SettingsRules {
    /// settings.md §2.2, in points, for the whole window frame.
    static let firstSize = CGSize(width: 1180, height: 800)
    static let minimumSize = CGSize(width: 900, height: 620)

    /// The first opening: `firstSize`, cut to 90% of the screen's usable
    /// area where that is smaller, centred in it.
    static func firstFrame(in area: CGRect) -> CGRect {
        let size = CGSize(
            width: min(firstSize.width, area.width * 0.9),
            height: min(firstSize.height, area.height * 0.9))
        return CGRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    /// A size the person drags to, held at the minimum.
    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    /// Whether a remembered frame can still be used: its title bar -- the
    /// part it is dragged by -- has to be on some screen's usable area. A
    /// frame whose body shows but whose title bar is under the menu bar or
    /// off every screen cannot be moved back, so it is not used.
    static func isReachable(_ frame: CGRect, titleBar: CGFloat, screens: [CGRect]) -> Bool {
        let bar = CGRect(x: frame.minX, y: frame.maxY - titleBar, width: frame.width, height: titleBar)
        return screens.contains { !$0.intersection(bar).isEmpty }
    }

    enum RoleChoice: Equatable {
        /// Leave the selection as it is.
        case keep
        /// Select this role, or none.
        case select(String?)
    }

    /// Which role a route to the Roles section selects (§3.1): the one it
    /// names; with none named, a newly opened window takes the last one
    /// chosen, else the first, and an open window keeps what it shows. A
    /// named role that no longer exists counts as none named.
    static func roleToSelect(item: String?, fresh: Bool, last: String?, roles: [String]) -> RoleChoice {
        if let item, roles.contains(item) { return .select(item) }
        guard fresh else { return .keep }
        if let last, roles.contains(last) { return .select(last) }
        return .select(roles.first)
    }

    /// What a search leaves of a list (settings.md §2.3a).
    struct Listing: Equatable {
        /// The keys still shown, in order.
        var visible: [String]
        /// Nothing is left: the list says so instead of standing empty.
        var noMatch: Bool
        /// The item being shown in the editor is not among them: the
        /// breadcrumb says so.
        var selectionHidden: Bool
    }

    /// Filter `items` (key and display name) by `query`: case-insensitive,
    /// on either, ignoring surrounding spaces. An empty query shows all.
    static func listing(items: [(key: String, name: String)], query: String, selection: String?) -> Listing {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            return Listing(visible: items.map(\.key), noMatch: false, selectionHidden: false)
        }
        let visible = items
            .filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.key.localizedCaseInsensitiveContains(needle) }
            .map(\.key)
        return Listing(
            visible: visible,
            noMatch: visible.isEmpty,
            selectionHidden: selection.map { !visible.contains($0) } ?? false)
    }

    /// `Section › item`, `Section` when nothing is chosen, and a note after
    /// the item when a search has hidden it from the list.
    static func breadcrumb(section: String, item: String?, hiddenBySearch: Bool) -> String {
        guard let item else { return section }
        let shown = hiddenBySearch
            ? String(format: String(localized: "%@ (not in the search results)", comment: "设置窗口：面包屑，%@ 是条目名，它被搜索过滤掉了"), item)
            : item
        return "\(section) › \(shown)"
    }

    /// Where ↑ (`by: -1`) or ↓ (`by: 1`) goes from `current` in a list of
    /// `keys`. It stops at the ends rather than wrapping. From nothing
    /// selected -- or a selection the list no longer shows -- ↓ goes to the
    /// first row and ↑ to the last. An empty list goes nowhere.
    static func step<Key: Equatable>(from current: Key?, in keys: [Key], by delta: Int) -> Key? {
        guard !keys.isEmpty else { return nil }
        guard let current, let i = keys.firstIndex(of: current) else {
            return delta >= 0 ? keys.first : keys.last
        }
        return keys[min(max(i + delta, 0), keys.count - 1)]
    }

    enum UnsavedAnswer { case save, dontSave, cancel }

    /// Whether it is fine to leave a section or an item (§2.4). Asks only
    /// when there is something unsaved; a failed save stays, Don't Save
    /// throws the changes away, Cancel stays with them kept.
    static func mayLeave(
        dirty: Bool,
        ask: () -> UnsavedAnswer,
        save: () -> Bool,
        revert: () -> Void
    ) -> Bool {
        guard dirty else { return true }
        switch ask() {
        case .save: return save()
        case .dontSave:
            revert()
            return true
        case .cancel: return false
        }
    }
}
