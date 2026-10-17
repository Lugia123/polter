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

    /// The supervisor of the group on `row` (task 1635): hookless only
    /// where the core offers to take it over -- the question it would ask
    /// is in the snapshot. One it could not recognise, or is still asking
    /// about, has nothing to offer here and is only jumped to. A supervisor
    /// is one the frame has a title for: the core named it and it is open.
    /// The Windows host's is `rowmenu::sup_of`.
    static func supervisor(of row: ControlRoomList.Row) -> Supervisor {
        guard let title = row.supervisor else { return .none }
        let offered = title.takeOver.map { $0.offered && $0.confirm != nil } ?? false
        return offered ? .hookless : .hooked
    }

    struct State: Equatable {
        var archived: Bool
        var supervisor: Supervisor
        /// The group kept the last session its supervisor ran. Only asked
        /// with no supervisor.
        var resumable: Bool
        var pinned: Bool
        var muted: Bool
        /// How many agent CLIs a supervisor can be started in here: the
        /// core's default role's whose plugins are on (task 1677). Two or
        /// more make "with a new session" a submenu of them; the menu tells
        /// only one from more.
        var clis: Int = 1
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
            // "Going on" can only be the last supervisor's CLI, and asks
            // nothing; a new session asks which when there is a choice
            // (`opens`).
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

    /// Whether `item` opens a submenu in `state`: the two fixed ones, and
    /// "with a new session" when there is more than one CLI to start it in
    /// (02A, task 1677) -- its items are those CLIs (`cliSubmenu`).
    static func opens(_ item: Item, in state: State) -> Bool {
        item.submenu != nil || (item == .startNew && state.clis > 1)
    }

    /// Every state, in the order the hosts' comparison prints them:
    /// archived, then the supervisor, then resumable, pinned, muted, CLIs,
    /// each false (one) before true (two).
    static var everyState: [State] {
        var all: [State] = []
        for archived in [false, true] {
            for supervisor in Supervisor.allCases {
                for resumable in [false, true] {
                    for pinned in [false, true] {
                        for muted in [false, true] {
                            for clis in [1, 2] {
                                all.append(State(archived: archived, supervisor: supervisor,
                                                 resumable: resumable, pinned: pinned, muted: muted, clis: clis))
                            }
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
            case .item(let item): return item.rawValue + (opens(item, in: state) ? ">" : "")
            }
        }
        return "group_menu archived=\(bit(state.archived)) sup=\(state.supervisor.rawValue) "
            + "resumable=\(bit(state.resumable)) pinned=\(bit(state.pinned)) muted=\(bit(state.muted)) "
            + "clis=\(state.clis) items=\(items.joined(separator: " "))"
    }

    /// The id of the item that starts a supervisor in a new session of a CLI.
    static let startNewCli = "start_new_cli:"

    /// What "with a new session ›" opens: one item per CLI, in the core's
    /// order (the role's), each with whether it is the one the group's last
    /// supervisor used -- which says so on its right ("Last used"). The
    /// Windows host's `rowmenu::cli_submenu`.
    static func cliSubmenu(_ clis: [String], last: String?) -> [(id: String, last: Bool)] {
        clis.map { (startNewCli + $0, $0 == last) }
    }

    /// The CLI an item of that submenu starts; nil for any other item.
    static func cli(of id: String) -> String? {
        guard id.hasPrefix(startNewCli) else { return nil }
        let cli = String(id.dropFirst(startNewCli.count))
        return cli.isEmpty ? nil : cli
    }

    /// How the comparison prints that submenu (`rowmenu::cli_submenu_line`).
    static func cliSubmenuLine(_ clis: [String], last: String?) -> String {
        let items = cliSubmenu(clis, last: last).map { $0.last ? $0.id + "*" : $0.id }
        return "group_submenu start_new clis=\(clis.joined(separator: ",")) last=\(last ?? "-") "
            + "items=\(items.joined(separator: " "))"
    }
}

// MARK: What became of an ask being tried again (task 1671)

extension ControlRoomRowMenu {
    /// What a "not delivered, will try again" line under a row becomes, now
    /// that a snapshot says how the row's last ask went. The Windows host's
    /// `act::follow_ask`; `hosts-agree` compares the two.
    enum AskNow: Equatable {
        /// Nothing to change.
        case keep
        /// The ask the line is about is this message: wait for its end.
        case wait(UInt64)
        /// It went in: the line says it was asked, and folds away.
        case delivered
        /// It was given up on, for this reason (the core's code).
        case gaveUp(String)
    }

    /// `waitingOn` is the message the line already knows it is about; nil
    /// until a snapshot has said. The line was put there by the ask's own
    /// answer, so the first ask the core says is being tried again is that
    /// one -- and a later message than the one waited on is a later ask by
    /// the person, which is the line's now. **An earlier one never is**: a
    /// snapshot from before the answer can still arrive, saying how the ask
    /// before went.
    static func followAsk(waitingOn: UInt64?, ask: ControlRoomList.AskState?) -> AskNow {
        guard let ask else { return .keep }
        let ours = waitingOn.map { ask.seq >= $0 } ?? (ask.stage == .retrying)
        guard ours else { return .keep }
        switch ask.stage {
        case .retrying: return waitingOn == ask.seq ? .keep : .wait(ask.seq)
        case .delivered: return .delivered
        case .gaveUp: return .gaveUp(ask.code ?? "")
        }
    }

    /// The cases `hosts-agree` runs both hosts over (`act::follow_ask_cases`).
    static let followAskCases: [(UInt64?, ControlRoomList.AskState?)] = {
        typealias Said = ControlRoomList.AskState
        return [
            (nil, nil),
            (nil, Said(seq: 7, stage: .retrying, code: "DraftInLine")),
            (nil, Said(seq: 7, stage: .delivered, code: nil)),
            (nil, Said(seq: 7, stage: .gaveUp, code: "UserPresent")),
            (7, nil),
            (7, Said(seq: 7, stage: .retrying, code: "DraftInLine")),
            (7, Said(seq: 7, stage: .delivered, code: nil)),
            (7, Said(seq: 7, stage: .gaveUp, code: "UserPresent")),
            (7, Said(seq: 6, stage: .delivered, code: nil)),
            (7, Said(seq: 6, stage: .retrying, code: "DraftInLine")),
            (7, Said(seq: 9, stage: .retrying, code: "UserPresent")),
            (7, Said(seq: 9, stage: .delivered, code: nil)),
        ]
    }()

    /// One line of `hosts-agree` for a case of `followAsk`.
    static func followAskLine(waitingOn: UInt64?, ask: ControlRoomList.AskState?) -> String {
        let on = waitingOn.map(String.init) ?? "none"
        let said = ask.map { "\($0.seq):\($0.stage.rawValue):\($0.code ?? "-")" } ?? "none"
        let now: String
        switch followAsk(waitingOn: waitingOn, ask: ask) {
        case .keep: now = "keep"
        case .wait(let seq): now = "wait \(seq)"
        case .delivered: now = "delivered"
        case .gaveUp(let code): now = "gave_up \(code)"
        }
        return "follow_ask on=\(on) said=\(said) -> \(now)"
    }
}
