import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// Covers `ProjectsRules`: the settings window's Projects section without a
/// window or a directory (settings.md §6).
struct ProjectsRulesTests {
    // MARK: Route

    @Test func aRouteSelectsTheProjectItNames() {
        #expect(ProjectsRules.projectToSelect(item: "b", bound: "c", names: ["a", "b", "c"]) == "b")
    }

    @Test func withNoneNamedTheCurrentWindowsProjectIsSelected() {
        #expect(ProjectsRules.projectToSelect(item: nil, bound: "c", names: ["a", "b", "c"]) == "c")
    }

    @Test func aNameThatIsGoneCountsAsNoneNamed() {
        #expect(ProjectsRules.projectToSelect(item: "gone", bound: "c", names: ["a", "c"]) == "c")
        #expect(ProjectsRules.projectToSelect(item: "gone", bound: "gone too", names: ["a", "c"]) == "a")
    }

    @Test func withNothingElseTheFirstIsSelected() {
        #expect(ProjectsRules.projectToSelect(item: nil, bound: nil, names: ["a", "b"]) == "a")
        #expect(ProjectsRules.projectToSelect(item: nil, bound: nil, names: []) == nil)
    }

    // MARK: Rename

    private let others: [(name: String, filename: String)] = [("Notes", "Notes.json"), ("a/b", "a_b.json")]

    @Test func aFreeNameIsAccepted() {
        #expect(ProjectsRules.renameVerdict(current: "x", proposed: "  fresh ", others: others, ruleFilename: "fresh.json") == .ok("fresh"))
    }

    @Test func anotherProjectsNameIsRefused() {
        #expect(ProjectsRules.renameVerdict(current: "x", proposed: "Notes", others: others, ruleFilename: "Notes.json") == .taken("Notes"))
    }

    /// `a:b` is a different name from `a/b`, but both are saved as `a_b.json`.
    @Test func aNameSavedUnderAnotherProjectsFileIsRefused() {
        #expect(ProjectsRules.renameVerdict(current: "x", proposed: "a:b", others: others, ruleFilename: "a_b.json") == .taken("a/b"))
    }

    /// `notes.json` and `Notes.json` are one file on a case-insensitive disk.
    @Test func aFileDifferingOnlyInCaseIsRefused() {
        #expect(ProjectsRules.renameVerdict(current: "x", proposed: "notes", others: others, ruleFilename: "notes.json") == .taken("Notes"))
    }

    @Test func theSameNameIsNothingToDoAndAnEmptyOneIsRefused() {
        #expect(ProjectsRules.renameVerdict(current: "x", proposed: " x ", others: others, ruleFilename: "x.json") == .unchanged)
        #expect(ProjectsRules.renameVerdict(current: "x", proposed: "   ", others: others, ruleFilename: nil) == .empty)
    }

    /// Changing only the case of one's own name is a rename, not a clash:
    /// the project's own file is not among `others`.
    @Test func changingOnlyTheCaseOfOnesOwnNameIsAllowed() {
        #expect(ProjectsRules.renameVerdict(current: "Notes", proposed: "notes", others: [("a/b", "a_b.json")], ruleFilename: "notes.json") == .ok("notes"))
    }

    // MARK: Copy name

    @Test func aCopyIsNamedAfterItsOriginal() {
        let base = ProjectsRules.copyName(of: "work") { _ in false }
        #expect(base.hasPrefix("work"))
        #expect(base != "work")
    }

    @Test func aCopyNameThatIsTakenIsNumbered() {
        let base = ProjectsRules.copyName(of: "work") { _ in false }
        let taken: Set<String> = [base, "\(base) 2"]
        #expect(ProjectsRules.copyName(of: "work") { taken.contains($0) } == "\(base) 3")
    }

    // MARK: Versions

    private func version(_ current: Bool, _ t: TimeInterval, panes: Int = 1) -> ProjectsRules.Version {
        .init(isCurrent: current, savedAt: Date(timeIntervalSince1970: t), paneCount: panes)
    }

    @Test func withoutAPreviousVersionThereIsOnlyTheCurrent() {
        #expect(ProjectsRules.versions(current: version(true, 100), previous: nil) == [version(true, 100)])
    }

    @Test func versionsAreNewestFirst() {
        #expect(ProjectsRules.versions(current: version(true, 200), previous: version(false, 100, panes: 3))
            == [version(true, 200), version(false, 100, panes: 3)])
    }

    /// After a restore the kept version is the newer one; it still sorts by
    /// time, and which is current is carried, not implied by position.
    @Test func aPreviousVersionNewerThanTheCurrentSortsFirst() {
        let list = ProjectsRules.versions(current: version(true, 100), previous: version(false, 200))
        #expect(list == [version(false, 200), version(true, 100)])
    }

    @Test func equalTimesPutTheCurrentFirst() {
        #expect(ProjectsRules.versions(current: version(true, 100), previous: version(false, 100)).first?.isCurrent == true)
    }

    // MARK: Banner

    @Test func aDeleteShowsTheBannerAndTheNextReplacesIt() {
        #expect(ProjectsRules.banner(after: .deleted("a"), current: nil) == "a")
        #expect(ProjectsRules.banner(after: .deleted("b"), current: "a") == "b")
    }

    @Test func undoingTakesTheBannerAwayAndAFailedUndoKeepsIt() {
        #expect(ProjectsRules.banner(after: ProjectsRules.BannerEvent<String>.undone, current: "a") == nil)
        #expect(ProjectsRules.banner(after: ProjectsRules.BannerEvent<String>.undoFailed, current: "a") == "a")
    }

    // MARK: Thumbnail

    @Test func oneLeafFillsTheThumbnail() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(ProjectsRules.cells(of: .leaf(0), in: rect, gap: 4) == [.init(leaf: 0, frame: rect)])
    }

    /// The core's `horizontal` is side by side: the first child on the left.
    @Test func aSideBySideSplitCutsTheWidth() {
        let cells = ProjectsRules.cells(
            of: .split(sideBySide: true, ratio: 0.5, .leaf(0), .leaf(1)),
            in: CGRect(x: 0, y: 0, width: 304, height: 200), gap: 4)
        #expect(cells == [
            .init(leaf: 0, frame: CGRect(x: 0, y: 0, width: 150, height: 200)),
            .init(leaf: 1, frame: CGRect(x: 154, y: 0, width: 150, height: 200)),
        ])
    }

    @Test func anOverUnderSplitCutsTheHeightByItsRatio() {
        let cells = ProjectsRules.cells(
            of: .split(sideBySide: false, ratio: 0.25, .leaf(0), .leaf(1)),
            in: CGRect(x: 0, y: 0, width: 300, height: 204), gap: 4)
        #expect(cells == [
            .init(leaf: 0, frame: CGRect(x: 0, y: 0, width: 300, height: 50)),
            .init(leaf: 1, frame: CGRect(x: 0, y: 54, width: 300, height: 150)),
        ])
    }

    @Test func nestedSplitsTileTheRectWithoutOverlap() {
        let tree: ProjectsRules.Pane = .split(
            sideBySide: true, ratio: 0.5, .leaf(0),
            .split(sideBySide: false, ratio: 0.5, .leaf(1), .leaf(2)))
        let cells = ProjectsRules.cells(of: tree, in: CGRect(x: 0, y: 0, width: 304, height: 204), gap: 4)
        #expect(cells.map(\.leaf) == [0, 1, 2])
        #expect(cells[1].frame == CGRect(x: 154, y: 0, width: 150, height: 100))
        #expect(cells[2].frame == CGRect(x: 154, y: 104, width: 150, height: 100))
        for i in cells.indices {
            for j in cells.indices where j > i {
                #expect(!cells[i].frame.intersects(cells[j].frame))
            }
        }
    }

    @Test func aRatioOutOfRangeLeavesNoNegativeCell() {
        let cells = ProjectsRules.cells(
            of: .split(sideBySide: true, ratio: 1.7, .leaf(0), .leaf(1)),
            in: CGRect(x: 0, y: 0, width: 104, height: 50), gap: 4)
        #expect(cells.allSatisfy { $0.frame.width >= 0 && $0.frame.height >= 0 })
        #expect(cells[0].frame.width == 100)
    }

    // MARK: Labels

    @Test func aPaneIsLabelledWithItsDirectorysLastPart() {
        #expect(ProjectsRules.directoryLabel("/home/me/src/polter/", home: "/home/me") == "polter")
        #expect(ProjectsRules.directoryLabel("/home/me", home: "/home/me/") == "~")
        #expect(ProjectsRules.directoryLabel("/", home: "/home/me") == "/")
        #expect(ProjectsRules.directoryLabel("", home: "/home/me") == "")
    }

    @Test func directoriesAreListedOnceInPaneOrder() {
        #expect(ProjectsRules.directories(["/b", "", "/a", "/b"]) == ["/b", "/a"])
    }

    // MARK: Search

    @Test func aSearchStaysInTheSectionOnScreenWhenItMatchesThere() {
        #expect(SettingsRules.sectionForSearch(current: .projects, searchable: [.roles, .projects], matching: [.roles, .projects]) == .projects)
    }

    @Test func aSearchGoesToTheFirstSectionThatMatches() {
        #expect(SettingsRules.sectionForSearch(current: .roles, searchable: [.roles, .projects], matching: [.projects]) == .projects)
        #expect(SettingsRules.sectionForSearch(current: .general, searchable: [.roles, .projects], matching: [.roles, .projects]) == .roles)
    }

    @Test func aSearchThatMatchesNothingStaysInASearchableSection() {
        #expect(SettingsRules.sectionForSearch(current: .projects, searchable: [.roles, .projects], matching: []) == .projects)
        #expect(SettingsRules.sectionForSearch(current: .general, searchable: [.roles, .projects], matching: []) == .roles)
    }
}
