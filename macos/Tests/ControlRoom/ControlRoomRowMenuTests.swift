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
        #expect(Menu.everyState.count == 96)
        for state in Menu.everyState {
            let e = Menu.entries(state)
            #expect(e.first != .separator && e.first != nil)
            #expect(e.last != .separator)
            #expect(!zip(e, e.dropFirst()).contains { $0 == .separator && $1 == .separator })
        }
    }

    /// 02A (task 1677): with more than one CLI a new session asks which,
    /// going on with the last one does not; with one the menu is today's;
    /// a group with no session to go on with keeps its one start.
    @Test func moreThanOneCliMakesANewSessionASubmenuOfThem() {
        func line(_ resumable: Bool, _ clis: Int, _ sup: Menu.Supervisor = .none) -> String {
            Menu.line(.init(archived: false, supervisor: sup, resumable: resumable, pinned: false, muted: false, clis: clis))
        }
        #expect(line(true, 2).hasSuffix("clis=2 items=start_resume start_new> - reveal - pin mute> - rename edit_note project> - archive delete"))
        #expect(line(true, 1).hasSuffix("clis=1 items=start_resume start_new - reveal - pin mute> - rename edit_note project> - archive delete"))
        #expect(line(false, 2).hasSuffix("items=start - reveal - pin mute> - rename edit_note project> - archive delete"))
        #expect(line(true, 2, .hooked).replacingOccurrences(of: "clis=2", with: "clis=1") == line(true, 1, .hooked))

        let clis = ["claude-code", "codex"]
        #expect(Menu.cliSubmenu(clis, last: "claude-code").map(\.id) == ["start_new_cli:claude-code", "start_new_cli:codex"])
        #expect(Menu.cliSubmenu(clis, last: "claude-code").map(\.last) == [true, false])
        #expect(Menu.cliSubmenu(clis, last: "other").allSatisfy { !$0.last })
        #expect(Menu.cli(of: "start_new_cli:codex") == "codex")
        #expect(Menu.cli(of: "start_new_cli:") == nil)
        #expect(Menu.cli(of: "start_new") == nil)
        #expect(Menu.cliSubmenuLine(clis, last: "codex")
            == "group_submenu start_new clis=claude-code,codex last=codex items=start_new_cli:claude-code start_new_cli:codex*")
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
