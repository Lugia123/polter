import CoreGraphics
import Foundation

// The Projects section's rules, with no AppKit and no project store in them:
// which project a route selects, when a new name is refused, what a copy is
// called, the version list, the "deleted -- undo" banner, and the layout
// thumbnail's rectangles (settings.md §6). Kept apart, like `SettingsRules`,
// so that each can be tested without a window or a directory.

enum ProjectsRules {
    // MARK: Route

    /// Which project a route to the Projects section selects (§3.1): the one
    /// it names; else the project the current window is bound to; else the
    /// first. A name that no longer exists counts as none named.
    static func projectToSelect(item: String?, bound: String?, names: [String]) -> String? {
        if let item, names.contains(item) { return item }
        if let bound, names.contains(bound) { return bound }
        return names.first
    }

    // MARK: Rename

    enum NameVerdict: Equatable {
        /// Go ahead.
        case ok(String)
        /// The same name as now: nothing to do.
        case unchanged
        case empty
        /// Another project already has this name, or a name that is saved
        /// under the same file.
        case taken(String)
    }

    /// Whether `proposed` may become the name of the project called
    /// `current`. `others` is every *other* project: its name, and the file
    /// it is saved in. `ruleFilename` is the file the new name would be
    /// saved in (`ProjectFilename.forNewFile`).
    ///
    /// Filenames compare ignoring case: APFS and NTFS both default to
    /// case-insensitive, so `Notes.json` and `notes.json` are one file and
    /// a rename onto it would overwrite a project.
    static func renameVerdict(
        current: String,
        proposed: String,
        others: [(name: String, filename: String)],
        ruleFilename: String?
    ) -> NameVerdict {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let ruleFilename else { return .empty }
        if name == current { return .unchanged }
        if let clash = others.first(where: {
            $0.name == name || $0.filename.caseInsensitiveCompare(ruleFilename) == .orderedSame
        }) {
            return .taken(clash.name)
        }
        return .ok(name)
    }

    /// The name a copy of `name` gets: "<name> Copy", then "<name> Copy 2",
    /// "<name> Copy 3", … -- the first that `isTaken` does not refuse.
    /// `isTaken` is asked with the same check a rename makes, so a copy is
    /// never named onto another project's file.
    static func copyName(of name: String, isTaken: (String) -> Bool) -> String {
        let base = String(format: String(localized: "%@ Copy", comment: "设置窗口·项目：复制一份的默认名字，%@ 是原名"), name)
        if !isTaken(base) { return base }
        var n = 2
        while isTaken("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Versions

    struct Version: Equatable {
        /// The file as it is now, rather than the one kept before it.
        var isCurrent: Bool
        var savedAt: Date
        var paneCount: Int
    }

    /// The versions a project can go back to, newest first (§6.2). The
    /// store keeps at most one earlier version (`.prev`), so this is the
    /// current file and, when there is one, that. A `.prev` can be *newer*
    /// than the current file -- restoring swaps the two -- so they are
    /// ordered by time, and which one is current is said, not implied by
    /// the order. Equal times put the current one first.
    static func versions(current: Version, previous: Version?) -> [Version] {
        var all = [current]
        if let previous { all.append(previous) }
        return all.sorted {
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            return $0.isCurrent && !$1.isCurrent
        }
    }

    // MARK: Undo after delete

    /// The "Deleted <name> [Undo]" banner (§6.2): there from a delete until
    /// the window closes or the next delete, which replaces it. Undoing
    /// takes it away; an undo that fails keeps it, so the person can see
    /// what is still in the Trash.
    enum BannerEvent<Token> {
        case deleted(Token)
        case undone
        case undoFailed
    }

    static func banner<Token>(after event: BannerEvent<Token>, current: Token?) -> Token? {
        switch event {
        case .deleted(let token): token
        case .undone: nil
        case .undoFailed: current
        }
    }

    // MARK: Thumbnail

    /// A project's split tree, reduced to what the thumbnail draws.
    indirect enum Pane: Equatable {
        case leaf(Int)
        /// `sideBySide`: the two children sit left and right (the core's
        /// `horizontal`); otherwise top and bottom. `ratio` is the first
        /// child's share.
        case split(sideBySide: Bool, ratio: Double, Pane, Pane)
    }

    struct Cell: Equatable {
        /// Which leaf, in the tree's left-to-right order.
        var leaf: Int
        var frame: CGRect
    }

    /// Cut `rect` the way `pane` is split, leaving `gap` between siblings.
    /// A ratio outside 0...1 (a hand-edited file) is held to it, so no cell
    /// has a negative size. Y grows downwards, as in SwiftUI.
    static func cells(of pane: Pane, in rect: CGRect, gap: CGFloat) -> [Cell] {
        switch pane {
        case .leaf(let leaf):
            return [Cell(leaf: leaf, frame: rect)]
        case .split(let sideBySide, let ratio, let first, let second):
            let share = CGFloat(min(max(ratio, 0), 1))
            if sideBySide {
                let room = max(rect.width - gap, 0)
                let w = (room * share).rounded()
                let a = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
                let b = CGRect(x: rect.minX + w + gap, y: rect.minY, width: room - w, height: rect.height)
                return cells(of: first, in: a, gap: gap) + cells(of: second, in: b, gap: gap)
            } else {
                let room = max(rect.height - gap, 0)
                let h = (room * share).rounded()
                let a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
                let b = CGRect(x: rect.minX, y: rect.minY + h + gap, width: rect.width, height: room - h)
                return cells(of: first, in: a, gap: gap) + cells(of: second, in: b, gap: gap)
            }
        }
    }

    /// What a pane's cell is labelled with: the last part of its directory
    /// (`~` for the home directory itself, `/` for the root), empty for a
    /// pane saved without one.
    static func directoryLabel(_ cwd: String, home: String = NSHomeDirectory()) -> String {
        guard !cwd.isEmpty else { return "" }
        var path = cwd
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var trimmedHome = home
        while trimmedHome.count > 1 && trimmedHome.hasSuffix("/") { trimmedHome.removeLast() }
        if path == trimmedHome { return "~" }
        if path == "/" { return "/" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Every directory the panes are in, once each, in the order the panes
    /// come; panes with none are left out.
    static func directories(_ cwds: [String]) -> [String] {
        var seen = Set<String>()
        return cwds.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
