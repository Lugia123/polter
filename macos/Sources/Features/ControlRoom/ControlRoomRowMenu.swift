import Foundation

/// What the menu on a group's row holds (tasks 1660 and 1661, design v21 `01`, `02`,
/// `06`): which items, in which order, between which lines, for the state
/// the group is in. Nothing here draws, and nothing here acts -- the host
/// turns each `Item` into a menu item and an action.
///
/// **The two hosts hold one rule.** The Windows host's
/// `windows/control-room/src/rowmenu.rs` has the same function, and
/// `tools/control-room-hosts-agree.py` prints both for every state below
/// and compares them line for line (`group_menu ...`).
///
/// The rules, from the user's list (2026-10-16):
/// - Items that need a supervisor are **left out**, not greyed, when there
///   is none: a right-click menu holds only what can be used.
/// - With no supervisor the first group starts one: on the last session
///   and on a new one when there is a last session, "Start Supervisor…"
///   alone when the group never kept one.
/// - "Let the control room take over…" only for a supervisor that is
///   running with no hooks (#1635), next to "Jump to Supervisor".
/// - An archived group's menu is three items: reveal, unarchive, delete.
/// - A group of items with nothing left in it is left out with its line;
///   no line at either end.
enum ControlRoomRowMenu {
    /// The supervisor, as the menu needs it.
    enum Supervisor: String, CaseIterable {
        /// None running.
        case none
        /// Running, its hooks reporting.
        case hooked
        /// Running with no hooks: started by hand (#1635).
        case hookless
    }

    struct State: Equatable {
        var archived: Bool
        var supervisor: Supervisor
        /// The group kept the last session its supervisor ran. Only asked
        /// with no supervisor.
        var resumable: Bool
        var pinned: Bool
        var muted: Bool
    }

    /// One item. The raw value is what both hosts print.
    enum Item: String, CaseIterable {
        case jumpToSupervisor = "jump_to_supervisor"
        case takeOver = "take_over"
        case startResume = "start_resume"
        case startNew = "start_new"
        case start
        case reportProgress = "report_progress"
        case closeIdleWorkers = "close_idle_workers"
        case reveal
        case copySupervisorID = "copy_supervisor_id"
        case pin
        case unpin
        case mute
        case unmute
        case rename
        case editNote = "edit_note"
        case project
        case archive
        case unarchive
        case delete
        // In the submenus.
        case muteHour = "mute_hour"
        case muteTomorrow = "mute_tomorrow"
        case muteForever = "mute_forever"
        case openProject = "open_project"
        case saveProject = "save_project"
        case linkProject = "link_project"

        /// What it opens, for the two that open a submenu.
        var submenu: [Item]? {
            switch self {
            case .mute: return [.muteHour, .muteTomorrow, .muteForever]
            case .project: return [.openProject, .saveProject, .linkProject]
            default: return nil
            }
        }
    }

    enum Entry: Equatable {
        case item(Item)
        case separator
    }

    /// The menu for a group in `state`, top to bottom.
    static func entries(_ state: State) -> [Entry] {
        let groups: [[Item]]
        if state.archived {
            groups = [[.reveal], [.unarchive], [.delete]]
        } else {
            let has = state.supervisor != .none
            var go: [Item] = []
            switch state.supervisor {
            case .none: go = state.resumable ? [.startResume, .startNew] : [.start]
            case .hooked: go = [.jumpToSupervisor]
            case .hookless: go = [.jumpToSupervisor, .takeOver]
            }
            groups = [
                go,
                has ? [.reportProgress, .closeIdleWorkers] : [],
                has ? [.reveal, .copySupervisorID] : [.reveal],
                [state.pinned ? .unpin : .pin, state.muted ? .unmute : .mute],
                [.rename, .editNote, .project],
                [.archive, .delete],
            ]
        }
        var out: [Entry] = []
        for group in groups where !group.isEmpty {
            if !out.isEmpty { out.append(.separator) }
            out += group.map(Entry.item)
        }
        return out
    }

    /// Every state, in the order the hosts' comparison prints them:
    /// archived, then the supervisor, then resumable, pinned, muted, each
    /// false before true.
    static var everyState: [State] {
        var all: [State] = []
        for archived in [false, true] {
            for supervisor in Supervisor.allCases {
                for resumable in [false, true] {
                    for pinned in [false, true] {
                        for muted in [false, true] {
                            all.append(State(archived: archived, supervisor: supervisor,
                                             resumable: resumable, pinned: pinned, muted: muted))
                        }
                    }
                }
            }
        }
        return all
    }

    /// The line both hosts print for `state`.
    static func line(_ state: State) -> String {
        func bit(_ b: Bool) -> String { b ? "1" : "0" }
        let items = entries(state).map { entry -> String in
            switch entry {
            case .separator: return "-"
            case .item(let item): return item.rawValue + (item.submenu == nil ? "" : ">")
            }
        }
        return "group_menu archived=\(bit(state.archived)) sup=\(state.supervisor.rawValue) "
            + "resumable=\(bit(state.resumable)) pinned=\(bit(state.pinned)) muted=\(bit(state.muted)) "
            + "items=\(items.joined(separator: " "))"
    }
}
