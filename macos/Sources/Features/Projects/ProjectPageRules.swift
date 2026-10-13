import Foundation

/// What the interface does about a tab being a page of a project: which
/// tabs "Save as Project" offers, what the menus say and offer, and whether
/// closing a page asks first. Decided here, drawn elsewhere
/// (`ProjectSaveAsView`, `TerminalWindow`'s tab menu, the `Project` menu,
/// `TerminalController+Projects.swift`).
///
/// Foundation-only, so every rule can be run without the app
/// (`tools/mac-logic-tests`).
enum ProjectPageRules {
    // MARK: Save as Project

    /// One tab of the window "Save as Project" was asked in.
    struct Tab: Equatable {
        let id: Int
        let title: String
        let panes: Int
        /// The project it is a page of already, if any.
        let project: String?
        /// Whether it is the tab the person asked from.
        let isCurrent: Bool
    }

    /// What stands at the right of a tab's row.
    enum Note: Equatable {
        /// The tab the person asked from.
        case thisPage
        case panes(Int)
        /// A page of a project already: it cannot be saved into another.
        case inProject(String)
    }

    struct Row: Equatable {
        let id: Int
        let title: String
        let note: Note
        /// False for a tab that is a page of a project already. **A tab is
        /// a page of at most one project**: two projects each saving the
        /// same tab would each write its panes' scrollback, under numbers
        /// that mean something else in the other.
        let canCheck: Bool
    }

    /// One row per tab, in the order of the tabs.
    static func saveAsRows(_ tabs: [Tab]) -> [Row] {
        tabs.map { tab in
            if let project = tab.project {
                return Row(id: tab.id, title: tab.title, note: .inProject(project), canCheck: false)
            }
            return Row(id: tab.id, title: tab.title, note: tab.isCurrent ? .thisPage : .panes(tab.panes), canCheck: true)
        }
    }

    /// What is checked when the sheet opens: **the tab it was asked from
    /// and no other** -- and not even that one when it is a page of a
    /// project already.
    static func initiallyChecked(_ tabs: [Tab]) -> Set<Int> {
        Set(tabs.filter { $0.isCurrent && $0.project == nil }.map(\.id))
    }

    /// The tabs a save takes, in the order of the tabs: the checked ones
    /// that can be. A check left on a row that cannot be checked is not a
    /// way round the rule.
    static func tabsToSave(checked: Set<Int>, rows: [Row]) -> [Int] {
        rows.filter { $0.canCheck && checked.contains($0.id) }.map(\.id)
    }

    /// Whether "Save as Project" can be pressed: there is a name, and at
    /// least one tab to save.
    static func canSave(name: String, checked: Set<Int>, rows: [Row]) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !tabsToSave(checked: checked, rows: rows).isEmpty
    }

    static func text(_ note: Note) -> String {
        switch note {
        case .thisPage: return String(localized: "This page", comment: "存为项目：当前这一页那一行右边的字")
        case .panes(let count): return String(localized: "\(String(count)) pane(s)", comment: "存为项目：每一页那一行右边写这一页有几格")
        case .inProject(let name): return String(localized: "Already in the project \"\(name)\"", comment: "存为项目：已属于别的项目的页那一行右边的字，参数是项目名")
        }
    }

    // MARK: The menus

    /// The line at the top of the `Project` menu, which cannot be chosen:
    /// which project the tab in front is a page of.
    static func menuHeader(project: String?) -> String {
        guard let project else {
            return String(localized: "This page is in no project", comment: "项目菜单顶上那一行：当前页不属于任何项目")
        }
        return String(localized: "This page is in the project \"\(project)\"", comment: "项目菜单顶上那一行：当前页属于哪个项目，参数是项目名")
    }

    /// The things the `Project` menu and a tab's own menu do to a page.
    enum Item: Equatable, CaseIterable {
        case saveAs
        case open
        case manage
        /// Put this tab into a project that exists.
        case addTo
        case rename
        /// Take this page out of its project; the tab stays open.
        case takeOut
        /// Close every page of the project. They stay its pages.
        case closeProject
    }

    /// Whether `item` can be chosen for a tab that is a page of `project`
    /// (nil: of none).
    ///
    /// The three that act on the project need one. "Add to Project" needs
    /// there to be none -- a tab is a page of at most one. "Save as
    /// Project" is always offered: the sheet it opens says which tabs it
    /// can take.
    static func offered(_ item: Item, pageOf project: String?) -> Bool {
        switch item {
        case .saveAs, .open, .manage: return true
        case .addTo: return project == nil
        case .rename, .takeOut, .closeProject: return project != nil
        }
    }

    /// "Take This Page Out of the Project", naming the project when the
    /// tab has one -- so that the item says what it would be taken out of,
    /// which "Close Project" beside it does not.
    static func takeOutTitle(project: String?) -> String {
        guard let project else {
            return String(localized: "Take This Page Out of the Project", comment: "项目菜单／标签页右键：把这一页移出项目（这一页不属于项目时，灰着）")
        }
        return String(localized: "Take This Page Out of \"\(project)\"", comment: "项目菜单／标签页右键：把这一页移出项目，参数是项目名")
    }

    // MARK: Closing a page

    /// What a person chose to have happen from now on when a page closes.
    /// Stored under `closeChoiceKey`; "ask" is what nothing stored means.
    enum CloseChoice: String, CaseIterable {
        case ask
        /// Close it, and it stays a page: the project brings it back.
        case keep
        /// Close it and take it out of the project.
        case takeOut
    }

    static let closeChoiceKey = "ProjectClosePageChoice"

    /// How a page comes to be closing.
    enum CloseScope: Equatable, CaseIterable {
        /// The one tab, by itself.
        case tab
        /// Its whole window.
        case window
        /// "Close Project".
        case project
        case quit
    }

    enum CloseStep: Equatable {
        case ask
        case close(takingOut: Bool)
    }

    /// What happens when a tab closes.
    ///
    /// **Closing a page is not taking it out**: left alone, the project
    /// brings it back the next time it is opened. So the only question is
    /// whether to take it out as well, and it is asked only where the
    /// answer could be wanted: one page closed by itself, of a project
    /// that has other pages open. A window closing, the project closing
    /// and the application quitting are a person putting the project away,
    /// not thinning it; a project's last open page closing is the project
    /// being closed. None of those asks, and none takes anything out.
    static func closeStep(
        pageOf project: String?,
        otherPagesOpen: Int,
        scope: CloseScope,
        choice: CloseChoice
    ) -> CloseStep {
        guard project != nil, scope == .tab, otherPagesOpen > 0 else { return .close(takingOut: false) }
        switch choice {
        case .ask: return .ask
        case .keep: return .close(takingOut: false)
        case .takeOut: return .close(takingOut: true)
        }
    }

    /// What is remembered after the question was answered: the answer, when
    /// "don't ask again" was ticked with it; otherwise what it was.
    static func choice(afterTakingOut takingOut: Bool, dontAskAgain: Bool, was: CloseChoice) -> CloseChoice {
        guard dontAskAgain else { return was }
        return takingOut ? .takeOut : .keep
    }

    static func text(_ choice: CloseChoice) -> String {
        switch choice {
        case .ask: return String(localized: "Ask each time", comment: "设置·项目：关掉项目里的一页时——每次都问")
        case .keep: return String(localized: "Keep it in the project", comment: "设置·项目：关掉项目里的一页时——不问，留在项目里")
        case .takeOut: return String(localized: "Take it out of the project", comment: "设置·项目：关掉项目里的一页时——不问，同时移出项目")
        }
    }

    // MARK: How big a project is

    /// "3 pages · 7 panes": a project is counted whole, not by its first
    /// page.
    static func size(pages: Int, panes: Int) -> String {
        String(localized: "\(String(pages)) page(s) · \(String(panes)) pane(s)", comment: "项目的大小：几页几格，参数依次是页数、格数")
    }
}

extension ProjectFile {
    /// How many pages the project has, in every window.
    var pageCount: Int { tabs.count }

    /// How many panes the project has, on every page.
    var totalPaneCount: Int { tabs.reduce(0) { $0 + $1.leafCount } }
}
