import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// The Project menu while the control room is the window with the keyboard
/// (`ControlRoomRules.projectItemOffered`), and the small heading that sets
/// the terminals in no group apart from the groups
/// (`ControlRoomListLayout.waitingLoneHeader`, `quietLoneHeader`).
///
/// **What these are not.** That the menu's items reach the control room's
/// controller, that a project opens as a tab, and what the heading looks
/// like are in the app and on a screen; nothing here starts either.
struct ControlRoomProjectMenuTests {
    typealias Rules = ControlRoomRules
    typealias Look = ControlRoomLook

    // MARK: The Project menu

    @Test func loadingAndManagingNeedNoTerminal() {
        // All three were greyed in the control room, so a project could
        // not be loaded from it at all.
        for lent in [false, true] {
            let load = Rules.projectItemOffered(.load, lentTerminalHasTab: lent)
            #expect(load == true)
            let manage = Rules.projectItemOffered(.manage, lentTerminalHasTab: lent)
            #expect(manage == true)
        }
    }

    @Test func savingIsOfferedOnlyWhileATerminalsTabIsThereToSave() {
        // The control room is not a tab that can be saved: what is saved
        // is the tab of the terminal it shows.
        let shown = Rules.projectItemOffered(.saveAs, lentTerminalHasTab: true)
        #expect(shown == true)
        let none = Rules.projectItemOffered(.saveAs, lentTerminalHasTab: false)
        #expect(none == false)
    }

    @Test func everyItemOfTheMenuHasAnAnswer() {
        // Three items in the menu, three here: one added there without a
        // case here does not compile, and this says how many that is.
        #expect(Rules.ProjectItem.allCases.count == 3)
    }

    @Test func aLoadedProjectOpensAmongTheControlRoomsTabsAndComesInFront() {
        // The person chose it from the menu: it is theirs to see. "Behind"
        // is for a tab an agent asked for, and that rule still says so.
        let beside = Rules.loadedProjectTab(tabsBesideControlRoom: true, anyTerminalWindow: true)
        #expect(beside == .inFront(of: .controlRooms))
        let agents = Rules.newTab(asker: nil, controlRoomInFront: true,
                                  tabsBesideControlRoom: true, anyTerminalWindow: true)
        #expect(agents == .behind(.controlRooms))
        // With no terminal tab beside the control room: the terminal
        // window used last, and with none at all the first tab beside the
        // control room -- in front, like the others.
        let elsewhere = Rules.loadedProjectTab(tabsBesideControlRoom: false, anyTerminalWindow: true)
        #expect(elsewhere == .inFront(of: .frontmost))
        let nowhere = Rules.loadedProjectTab(tabsBesideControlRoom: false, anyTerminalWindow: false)
        #expect(nowhere == .inFront(of: .controlRooms))
    }

    // MARK: The terminals in no group are not shown

    private func snapshot() throws -> ControlRoomSnapshot {
        try JSONDecoder().decode(ControlRoomSnapshot.self, from: ControlRoomListTests.fixture())
    }

    @Test func aTerminalInNoGroupHasNoRow() throws {
        // The user, 2026-10-13: the rows of these terminals read as groups
        // nobody had made. The core still lists them; nothing draws them.
        let snapshot = try snapshot()
        let listed = try #require(snapshot.ungrouped)
        #expect(listed.count == 1)
        let list = ControlRoomList(snapshot: snapshot)
        let anyAlone = list.rows.contains { $0.alone != nil }
        #expect(!anyAlone)
        let ids = list.rows.map(\.id)
        #expect(ids == ["web-app", "web-app-docs", "mobile", "billing", "docs-site", "infra", "design-system", "notes"])
        // Nor is there anywhere for one in the panel.
        let layout = ControlRoomListLayout(list: list, height: 900)
        #expect(layout.rows["terminal:0x00000000000000c1"] == nil)
        #expect(layout.rows.count == 8)
    }

    @Test func theHeadingTheRowsAndTheDockAreOneNumber() throws {
        // Three places say how many are waiting: the list's heading, the
        // rows under it, and the Dock. With the lone terminals' rows gone
        // they must not be in any of the three.
        let snapshot = try snapshot()
        let list = ControlRoomList(snapshot: snapshot)
        let rows = list.waiting.count
        #expect(rows == 5)
        #expect(list.waitingCount == rows)
        #expect(list.waitingHeader?.count == rows)
        #expect(list.waitingHeader?.of == .groups)
        let dock = ControlRoomRules.dockBadge(needsMe: snapshot.needs_me, bells: nil)
        #expect(dock == String(rows))
        #expect(list.waitingHeaderText.contains(String(rows)))
        // The second heading and its rows too.
        #expect(list.quietCount == list.quiet.count)
    }

    @Test func aRowForSuchATerminalIsOnlyMadeWhenAskedFor() throws {
        // What such a row says is still under test (`ControlRoomListTests`),
        // through the one switch nothing in the app turns on.
        let snapshot = try snapshot()
        let asked = ControlRoomList(snapshot: snapshot, loneRows: true)
        let alone = asked.rows.filter { $0.alone != nil }.map(\.id)
        #expect(alone == ["terminal:0x00000000000000c1"])
    }
}
