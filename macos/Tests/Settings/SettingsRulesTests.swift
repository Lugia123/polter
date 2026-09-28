import CoreGraphics
import Testing
@testable import Ghostty

/// Covers `SettingsRules`: the settings window's routes, sizes and
/// unsaved-changes rule (settings.md §2.2, §2.4, §3.1), without a window.
///
/// The window itself is not built here: that needs the app on screen, and
/// what it adds on top of these rules -- where AppKit puts a frame, which
/// view SwiftUI draws -- is checked on a running instance and recorded in
/// `dev-docs/poltergeist/settings-checklist.md`.
struct SettingsRulesTests {
    // MARK: Sizes

    @Test func firstOpeningIsTheFullSizeCentredOnABigScreen() {
        let area = CGRect(x: 0, y: 25, width: 1800, height: 1130)
        let frame = SettingsRules.firstFrame(in: area)
        #expect(frame.size == CGSize(width: 1180, height: 800))
        #expect(frame.midX == area.midX)
        #expect(frame.midY == area.midY)
    }

    /// A screen too small for 1180x800 gets 90% of it, each side on its own.
    @Test func firstOpeningIsCutToNinetyPercent() {
        let area = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let frame = SettingsRules.firstFrame(in: area)
        #expect(frame.width == 1152)
        #expect(frame.height == 648)
        #expect(frame.midX == area.midX)
        #expect(frame.midY == area.midY)
    }

    @Test func onlyTheSideThatDoesNotFitIsCut() {
        let frame = SettingsRules.firstFrame(in: CGRect(x: 0, y: 0, width: 2560, height: 800))
        #expect(frame.width == 1180)
        #expect(frame.height == 720)
    }

    @Test func aResizeIsHeldAtTheMinimum() {
        #expect(SettingsRules.clamped(CGSize(width: 600, height: 400)) == CGSize(width: 900, height: 620))
        #expect(SettingsRules.clamped(CGSize(width: 600, height: 700)) == CGSize(width: 900, height: 700))
        #expect(SettingsRules.clamped(CGSize(width: 1000, height: 400)) == CGSize(width: 1000, height: 620))
        #expect(SettingsRules.clamped(CGSize(width: 900, height: 620)) == CGSize(width: 900, height: 620))
        #expect(SettingsRules.clamped(CGSize(width: 1320, height: 900)) == CGSize(width: 1320, height: 900))
    }

    // MARK: Remembered frame

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)

    @Test func aFrameOnTheScreenIsUsed() {
        let frame = CGRect(x: 200, y: 150, width: 1320, height: 900)
        #expect(SettingsRules.isReachable(frame, titleBar: 32, screens: [screen]))
    }

    /// Unplugged the screen it was on: nothing of it is on the one left.
    @Test func aFrameOffEveryScreenIsNotUsed() {
        let frame = CGRect(x: 2000, y: 150, width: 1320, height: 900)
        #expect(!SettingsRules.isReachable(frame, titleBar: 32, screens: [screen]))
    }

    /// The body shows but the title bar is above the usable area, where it
    /// cannot be dragged back.
    @Test func aFrameWhoseTitleBarIsOffScreenIsNotUsed() {
        let frame = CGRect(x: 200, y: 400, width: 1320, height: 900)
        #expect(frame.intersects(screen))
        #expect(!SettingsRules.isReachable(frame, titleBar: 32, screens: [screen]))
    }

    @Test func aFrameOnTheSecondScreenIsUsed() {
        let second = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 2000, y: 100, width: 1180, height: 800)
        #expect(SettingsRules.isReachable(frame, titleBar: 32, screens: [screen, second]))
    }

    // MARK: Routes

    private let roles = ["polter-supervisor", "dev-worker", "test-worker"]

    @Test func aNamedRoleIsSelected() {
        #expect(SettingsRules.roleToSelect(item: "test-worker", fresh: true, last: "dev-worker", roles: roles)
                == .select("test-worker"))
        #expect(SettingsRules.roleToSelect(item: "test-worker", fresh: false, last: nil, roles: roles)
                == .select("test-worker"))
    }

    @Test func aNewWindowWithNoRoleNamedTakesTheLastOne() {
        #expect(SettingsRules.roleToSelect(item: nil, fresh: true, last: "dev-worker", roles: roles)
                == .select("dev-worker"))
    }

    @Test func aNewWindowWithNoRoleAndNoLastTakesTheFirst() {
        #expect(SettingsRules.roleToSelect(item: nil, fresh: true, last: nil, roles: roles)
                == .select("polter-supervisor"))
        #expect(SettingsRules.roleToSelect(item: nil, fresh: true, last: "deleted", roles: roles)
                == .select("polter-supervisor"))
    }

    /// The menu bar with no terminal behind it names no role: an open window
    /// stays on what it shows rather than jumping away from the person's work.
    @Test func anOpenWindowWithNoRoleNamedKeepsItsSelection() {
        #expect(SettingsRules.roleToSelect(item: nil, fresh: false, last: "dev-worker", roles: roles) == .keep)
    }

    @Test func aRoleThatNoLongerExistsCountsAsNoneNamed() {
        #expect(SettingsRules.roleToSelect(item: "deleted", fresh: false, last: nil, roles: roles) == .keep)
        #expect(SettingsRules.roleToSelect(item: "deleted", fresh: true, last: "test-worker", roles: roles)
                == .select("test-worker"))
    }

    @Test func noRolesSelectsNothing() {
        #expect(SettingsRules.roleToSelect(item: nil, fresh: true, last: nil, roles: []) == .select(nil))
    }

    // MARK: Search

    private let items: [(key: String, name: String)] = [
        ("polter-supervisor", "Polter 总管"), ("dev-worker", "开发 Worker"), ("test-worker", "测试 Worker"),
    ]

    @Test func anEmptySearchShowsEverything() {
        let l = SettingsRules.listing(items: items, query: "  ", selection: "dev-worker")
        #expect(l.visible == ["polter-supervisor", "dev-worker", "test-worker"])
        #expect(!l.noMatch)
        #expect(!l.selectionHidden)
    }

    @Test func aSearchMatchesNameOrKeyIgnoringCase() {
        #expect(SettingsRules.listing(items: items, query: "WORKER", selection: nil).visible == ["dev-worker", "test-worker"])
        #expect(SettingsRules.listing(items: items, query: "总管", selection: nil).visible == ["polter-supervisor"])
        #expect(SettingsRules.listing(items: items, query: "dev-", selection: nil).visible == ["dev-worker"])
    }

    /// Other roles match, the one on screen does not: the list shows the
    /// matches and the breadcrumb says the selection is not among them.
    @Test func aSearchThatHidesTheSelectionSaysSo() {
        let l = SettingsRules.listing(items: items, query: "总管", selection: "test-worker")
        #expect(l.visible == ["polter-supervisor"])
        #expect(!l.noMatch)
        #expect(l.selectionHidden)
    }

    /// Nothing matches: the list says so rather than standing empty beside
    /// an editor that still shows a role (the state the first grid shot had).
    @Test func aSearchThatMatchesNothingSaysSo() {
        let l = SettingsRules.listing(items: items, query: "角色", selection: "test-worker")
        #expect(l.visible.isEmpty)
        #expect(l.noMatch)
        #expect(l.selectionHidden)
    }

    @Test func noSelectionIsNeverHidden() {
        #expect(!SettingsRules.listing(items: items, query: "角色", selection: nil).selectionHidden)
    }

    /// Checked by shape rather than wording: the wording is in
    /// Localizable.strings and differs by language.
    @Test func theBreadcrumbNotesAHiddenItem() {
        let plain = SettingsRules.breadcrumb(section: "S", item: "Tester", hiddenBySearch: false)
        let hidden = SettingsRules.breadcrumb(section: "S", item: "Tester", hiddenBySearch: true)
        #expect(plain == "S › Tester")
        #expect(hidden.hasPrefix("S › Tester"))
        #expect(hidden != plain)
        #expect(SettingsRules.breadcrumb(section: "S", item: nil, hiddenBySearch: true) == "S")
    }

    // MARK: Arrow keys

    private let keys = ["a", "b", "c"]

    @Test func downAndUpMoveOneRow() {
        #expect(SettingsRules.step(from: "a", in: keys, by: 1) == "b")
        #expect(SettingsRules.step(from: "b", in: keys, by: 1) == "c")
        #expect(SettingsRules.step(from: "c", in: keys, by: -1) == "b")
    }

    /// The ends hold: ↓ on the last row stays there, it does not wrap to the top.
    @Test func theEndsHold() {
        #expect(SettingsRules.step(from: "c", in: keys, by: 1) == "c")
        #expect(SettingsRules.step(from: "a", in: keys, by: -1) == "a")
    }

    /// Nothing selected, or a selection the search has hidden: ↓ starts at
    /// the top and ↑ at the bottom of what is shown.
    @Test func fromNothingDownIsFirstAndUpIsLast() {
        #expect(SettingsRules.step(from: nil, in: keys, by: 1) == "a")
        #expect(SettingsRules.step(from: nil, in: keys, by: -1) == "c")
        #expect(SettingsRules.step(from: "hidden", in: keys, by: 1) == "a")
        #expect(SettingsRules.step(from: "hidden", in: keys, by: -1) == "c")
    }

    @Test func anEmptyListGoesNowhere() {
        #expect(SettingsRules.step(from: "a", in: [String](), by: 1) == nil)
    }

    /// The sidebar steps through its sections in their order.
    @Test func theSidebarStepsThroughItsSections() {
        let all = SettingsSection.allCases
        #expect(SettingsRules.step(from: SettingsSection.roles, in: all, by: 1) == .projects)
        #expect(SettingsRules.step(from: SettingsSection.general, in: all, by: 1) == .general)
        #expect(SettingsRules.step(from: SettingsSection.plugins, in: all, by: -1) == .projects)
    }

    // MARK: Unsaved changes

    /// Records what `mayLeave` did, so each answer's side effects can be
    /// told apart: asked or not, saved or not, reverted or not.
    private final class Pane {
        var asked = 0, saved = 0, reverted = 0
        var answer: SettingsRules.UnsavedAnswer = .cancel
        var saveSucceeds = true

        func leave(dirty: Bool) -> Bool {
            SettingsRules.mayLeave(
                dirty: dirty,
                ask: { self.asked += 1; return self.answer },
                save: { self.saved += 1; return self.saveSucceeds },
                revert: { self.reverted += 1 })
        }
    }

    @Test func nothingUnsavedLeavesWithoutAsking() {
        let pane = Pane()
        #expect(pane.leave(dirty: false))
        #expect(pane.asked == 0)
        #expect(pane.saved == 0)
        #expect(pane.reverted == 0)
    }

    @Test func saveLeavesWhenTheSaveWorks() {
        let pane = Pane()
        pane.answer = .save
        #expect(pane.leave(dirty: true))
        #expect(pane.asked == 1)
        #expect(pane.saved == 1)
        #expect(pane.reverted == 0)
    }

    /// The section shows why; the window stays where it is.
    @Test func aFailedSaveStays() {
        let pane = Pane()
        pane.answer = .save
        pane.saveSucceeds = false
        #expect(!pane.leave(dirty: true))
        #expect(pane.saved == 1)
        #expect(pane.reverted == 0)
    }

    @Test func dontSaveThrowsTheChangesAwayAndLeaves() {
        let pane = Pane()
        pane.answer = .dontSave
        #expect(pane.leave(dirty: true))
        #expect(pane.saved == 0)
        #expect(pane.reverted == 1)
    }

    @Test func cancelStaysWithTheChangesKept() {
        let pane = Pane()
        pane.answer = .cancel
        #expect(!pane.leave(dirty: true))
        #expect(pane.asked == 1)
        #expect(pane.saved == 0)
        #expect(pane.reverted == 0)
    }
}

/// Covers `SettingsLayout`'s left edges (settings.md §2.3a): the numbers the
/// views place themselves with, so a column whose parts start at different
/// x cannot be put together from them.
struct SettingsLayoutTests {
    private typealias L = SettingsLayout

    /// Breadcrumb text, list row text and the bottom bar's + button, all
    /// measured from the list column's left rule.
    @Test func aColumnHasOneContentEdge() {
        #expect(L.ContentEdge.breadcrumbText == L.pad)
        #expect(L.ContentEdge.listText == L.pad)
        #expect(L.ContentEdge.bottomBar == L.pad)
    }

    @Test func theSearchBoxAndTheHighlightShareTheirEdges() {
        #expect(L.sidebarSearchEdges.left == L.sidebarHighlightEdges.left)
        #expect(L.sidebarSearchEdges.right == L.sidebarHighlightEdges.right)
        #expect(L.sidebarSearchEdges.left == L.padSidebar)
        #expect(L.sidebar - L.sidebarSearchEdges.right == L.padSidebar)
    }

    @Test func everySpacingIsAMultipleOfFour() {
        for v in [L.top, L.bottom, L.sidebar, L.list, L.control, L.pad, L.rowGap, L.groupGap,
                  L.label, L.labelGap, L.padSidebar, L.rowInset, L.rowTextInset] {
            #expect(v.truncatingRemainder(dividingBy: 4) == 0, "\(v)")
        }
    }

    /// The same numbers settings-win has in `polter-settings-shell`.
    @Test func theGridMatchesTheSpec() {
        #expect(L.top == 52)
        #expect(L.bottom == 52)
        #expect(L.sidebar == 220)
        #expect(L.list == 260)
        #expect(L.pad == 16)
        #expect(L.padSidebar == 8)
        #expect(L.label == 120)
    }
}
