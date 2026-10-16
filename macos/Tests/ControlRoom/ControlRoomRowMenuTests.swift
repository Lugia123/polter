import Testing
@testable import Ghostty

/// The menu on a group's row (tasks 1660 and 1661): the four menus of the
/// design's `02-menu-four-states`, an archived group's, and that no state
/// makes an empty group or a line at an end. The Windows host's
/// `rowmenu.rs` has the same tests; `tools/control-room-hosts-agree.py`
/// holds the two rules to one answer for every state.
struct ControlRoomRowMenuTests {
    typealias Menu = ControlRoomRowMenu

    func items(_ archived: Bool, _ sup: Menu.Supervisor, _ resumable: Bool, _ pinned: Bool, _ muted: Bool) -> String {
        let line = Menu.line(.init(archived: archived, supervisor: sup, resumable: resumable, pinned: pinned, muted: muted))
        return String(line.split(separator: "items=", maxSplits: 1)[1])
    }

    @Test func theFourMenusTheUserChose() {
        #expect(items(false, .hooked, false, false, false)
            == "jump_to_supervisor - report_progress close_idle_workers - reveal copy_supervisor_id - pin mute> - rename edit_note project> - archive delete")
        #expect(items(false, .none, true, false, false)
            == "start_resume start_new - reveal - pin mute> - rename edit_note project> - archive delete")
        #expect(items(false, .hookless, false, false, false)
            == "jump_to_supervisor take_over - report_progress close_idle_workers - reveal copy_supervisor_id - pin mute> - rename edit_note project> - archive delete")
        #expect(items(false, .hooked, false, true, true)
            == "jump_to_supervisor - report_progress close_idle_workers - reveal copy_supervisor_id - unpin unmute - rename edit_note project> - archive delete")
    }

    @Test func anOldGroupHasOneStartAndAnArchivedOneThreeItems() {
        #expect(items(false, .none, false, false, false) == "start - reveal - pin mute> - rename edit_note project> - archive delete")
        for sup in Menu.Supervisor.allCases {
            #expect(items(true, sup, true, true, true) == "reveal - unarchive - delete")
        }
    }

    @Test func noMenuHasAnEmptyGroupOrALineAtAnEnd() {
        #expect(Menu.everyState.count == 48)
        for state in Menu.everyState {
            let e = Menu.entries(state)
            #expect(e.first != .separator && e.first != nil)
            #expect(e.last != .separator)
            #expect(!zip(e, e.dropFirst()).contains { $0 == .separator && $1 == .separator })
        }
    }

    /// Which supervisor a row's menu is made for (task 1635): "take over"
    /// only where the core offers it -- docs-site, recognised and started by
    /// hand -- and not for design-system, whose CLI nobody recognised.
    @Test func takeOverIsOfferedWhereTheCoreOffersIt() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        let sup = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.id, Menu.supervisor(of: $0)) })
        #expect(sup["docs-site"] == .hookless)
        #expect(sup["design-system"] == .hooked)
        #expect(sup["web-app"] == .hooked)
        var none = try #require(list.rows.first)
        none.supervisor = nil
        #expect(Menu.supervisor(of: none) == .none)
    }
}
