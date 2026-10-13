import Testing
import Foundation
@testable import Ghostty

/// What the interface does about a tab being a page of a project
/// (`ProjectPageRules`).
@Suite
struct ProjectPageRulesTests {
    private typealias Rules = ProjectPageRules

    private let tabs = [
        Rules.Tab(id: 1, title: "polter", panes: 2, project: nil, isCurrent: false),
        Rules.Tab(id: 2, title: "web-app", panes: 3, project: nil, isCurrent: true),
        Rules.Tab(id: 3, title: "argus-site", panes: 1, project: "argus", isCurrent: false),
    ]

    // MARK: Save as Project

    @Test func saveAsListsEveryTabAndOnlyTheCurrentOneIsChecked() {
        let rows = Rules.saveAsRows(tabs)
        #expect(rows == [
            Rules.Row(id: 1, title: "polter", note: .panes(2), canCheck: true),
            Rules.Row(id: 2, title: "web-app", note: .thisPage, canCheck: true),
            // A page of another project: said so, and cannot be taken.
            Rules.Row(id: 3, title: "argus-site", note: .inProject("argus"), canCheck: false),
        ])
        #expect(Rules.initiallyChecked(tabs) == [2])
    }

    /// The tab asked from is itself a page of a project: nothing is
    /// checked, and it cannot be.
    @Test func aCurrentTabThatIsAlreadyAPageIsNotOffered() {
        let own = [
            Rules.Tab(id: 1, title: "a", panes: 1, project: nil, isCurrent: false),
            Rules.Tab(id: 2, title: "b", panes: 1, project: "p", isCurrent: true),
        ]
        #expect(Rules.initiallyChecked(own).isEmpty)
        #expect(Rules.saveAsRows(own)[1] == Rules.Row(id: 2, title: "b", note: .inProject("p"), canCheck: false))
    }

    @Test func savingNeedsANameAndATabThatCanBeTaken() {
        let rows = Rules.saveAsRows(tabs)
        #expect(Rules.canSave(name: "new", checked: [2], rows: rows))
        #expect(!Rules.canSave(name: "   ", checked: [2], rows: rows))
        #expect(!Rules.canSave(name: "new", checked: [], rows: rows))
        // A check on the row that cannot be checked is not a tab to save.
        #expect(!Rules.canSave(name: "new", checked: [3], rows: rows))
        #expect(Rules.tabsToSave(checked: [3, 2, 1], rows: rows) == [1, 2])
    }

    // MARK: The menus

    @Test func theMenuSaysWhichProjectAndOffersWhatFits() {
        #expect(Rules.menuHeader(project: "polter").contains("polter"))
        #expect(Rules.menuHeader(project: nil) != Rules.menuHeader(project: "polter"))
        #expect(Rules.takeOutTitle(project: "polter").contains("polter"))

        let inOne = Rules.Item.allCases.filter { Rules.offered($0, pageOf: "polter") }
        #expect(inOne == [.saveAs, .open, .manage, .rename, .takeOut, .closeProject])
        let inNone = Rules.Item.allCases.filter { Rules.offered($0, pageOf: nil) }
        #expect(inNone == [.saveAs, .open, .manage, .addTo])
    }

    // MARK: Closing a page

    /// **Asked only for one page closed by itself, of a project that has
    /// others open** -- and never taken out without being asked or told.
    @Test func closingAPageAsksOnlyWhereTheAnswerCouldBeWanted() {
        func step(_ project: String? = "p", others: Int = 2, _ scope: Rules.CloseScope = .tab, _ choice: Rules.CloseChoice = .ask) -> Rules.CloseStep {
            Rules.closeStep(pageOf: project, otherPagesOpen: others, scope: scope, choice: choice)
        }
        #expect(step() == .ask)
        // A tab of no project.
        #expect(step(nil) == .close(takingOut: false))
        // The project's last open page: that is the project being closed.
        #expect(step(others: 0) == .close(takingOut: false))
        // The window, the project, the application: put away, not thinned
        // -- whatever was chosen for single pages.
        for scope in Rules.CloseScope.allCases where scope != .tab {
            for choice in Rules.CloseChoice.allCases {
                #expect(step("p", others: 2, scope, choice) == .close(takingOut: false))
            }
        }
        // Told not to ask.
        #expect(step("p", others: 2, .tab, .keep) == .close(takingOut: false))
        #expect(step("p", others: 2, .tab, .takeOut) == .close(takingOut: true))
        #expect(step(nil, others: 2, .tab, .takeOut) == .close(takingOut: false))
        #expect(step("p", others: 0, .tab, .takeOut) == .close(takingOut: false))
    }

    @Test func theAnswerIsRememberedOnlyWhenAskedTo() {
        #expect(Rules.choice(afterTakingOut: true, dontAskAgain: false, was: .ask) == .ask)
        #expect(Rules.choice(afterTakingOut: true, dontAskAgain: true, was: .ask) == .takeOut)
        #expect(Rules.choice(afterTakingOut: false, dontAskAgain: true, was: .ask) == .keep)
        // What is stored is what the setting reads back.
        for choice in Rules.CloseChoice.allCases {
            #expect(Rules.CloseChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(Set(Rules.CloseChoice.allCases.map(Rules.text)).count == 3)
    }

    // MARK: How big a project is

    @Test func aProjectIsCountedWhole() {
        func leaf(_ cwd: String) -> ProjectNode { .leaf(cwd: cwd, title: "", history: "", scrollback: "", agent: .none) }
        let file = ProjectFile(
            name: "p", savedAt: 1, group: nil,
            windows: [
                ProjectWindow(frame: nil, front: 0, tabs: [
                    ProjectTab(root: leaf("/a")),
                    ProjectTab(root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/b"), right: leaf("/c"))),
                ]),
                ProjectWindow(frame: nil, front: 0, tabs: [ProjectTab(root: leaf("/d"))]),
            ],
            nextScrollback: nil)
        #expect(file.pageCount == 3)
        #expect(file.totalPaneCount == 4)
        // Not the first page's one pane.
        #expect(file.paneCount == 1)
        let text = Rules.size(pages: file.pageCount, panes: file.totalPaneCount)
        #expect(text.contains("3") && text.contains("4"))
    }
}
