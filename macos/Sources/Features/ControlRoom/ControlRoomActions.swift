import Foundation

/// What the person does in the control room, as the core takes it
/// (`src/poltergeist/ControlAct.zig`): one JSON request, carried out or
/// refused by name.
///
/// **This builds the request and reads the answer, and decides nothing.**
/// Whether a prompt is still the one that was on screen is the core's to
/// say: an action on a row hands back the `since_ms` and `event_ms` the row
/// was drawn from, exactly as they came, and the core refuses when they no
/// longer hold.
///
/// The call into the core is handed in as a closure, so everything here
/// runs without it.
///
/// **Nothing in the control room sends `approve`, `refuse` or `reply`
/// today.** The rows only tell (the user, 2026-10-12); the three acts stay
/// here because the core still takes them (`ControlAct.zig`) and this is
/// the one place that knows how to write them. What is sent is `seen`,
/// and the two the person does about a group rather than to a terminal:
/// `new_group` and `start_supervisor`.
struct ControlRoomActions {
    /// Sends one request. Returns nil when it was done, or the refusal's
    /// name as the core wrote it.
    typealias Send = (_ json: Data) -> String?

    let send: Send

    enum Act: Equatable {
        case seen(group: String)
        /// The person looked at the row of a terminal that is in no group.
        case seenTerminal(String)
        /// Until its state changes; or, with a time, until then (wall clock).
        case snooze(group: String, untilMs: UInt64? = nil)
        case unsnooze(group: String)
        case approve(ControlRoomList.Target)
        case refuse(ControlRoomList.Target)
        case reply(ControlRoomList.Target, text: String)
        /// Make a group by the name that was typed.
        case newGroup(name: String)
        /// Start a supervisor for a group that has none. A nil role or
        /// directory is the one the core's snapshot names.
        case startSupervisor(group: String, role: String? = nil, cwd: String? = nil,
                             session: ControlRoomStartChoice.Session? = nil)
        /// The person said OK to the first sweep of old records (task 1511).
        case retentionAgree
        /// "Fix" on a card that reads "Failed" (task 1560): the core tells
        /// the card's supervisor. The row's id is all it needs -- which
        /// card, as last drawn, is the core's to look up.
        case fix(group: String)
        /// The same, on the row of a terminal that is in no group.
        case fixTerminal(String)
        /// "Let the control room take over?" on a group's supervisor, once
        /// the person said yes to the core's question (task 1635).
        case takeOver(group: String)
        // The group row's menu (task 1660; `issue-fix/1659-interface.md`).
        case pin(group: String)
        case unpin(group: String)
        /// Until then (wall clock); nil for until it is unmuted.
        case mute(group: String, untilMs: UInt64?)
        case unmute(group: String)
        case archive(group: String)
        case unarchive(group: String)
        case renameGroup(from: String, to: String)
        case setBrief(group: String, brief: String)
        /// The two counts the question showed: the core refuses with
        /// `Stale`, deleting nothing, when they no longer hold.
        case deleteGroup(group: String, members: Int, openTasks: Int)
        case askSupervisor(group: String, ask: Ask)
    }

    /// The two things the group row's menu asks a supervisor to do: the
    /// core types a sentence of its own for each (task 1659).
    enum Ask: CaseIterable {
        case reportProgress
        case closeIdleWorkers
    }

    /// Why an action was not done. `name` is the core's word for it and is
    /// what a log should carry; `message` is what the person reads.
    struct Refusal: Error, Equatable {
        var name: String

        /// A sentence for the person, in their language. A refusal this
        /// build has no sentence for still says that nothing was done and
        /// names itself: silence here would read as success.
        var message: String {
            switch name {
            case "PromptGone":
                return String(localized: "That prompt has changed. Nothing was sent.",
                              comment: "总控台：批准/拒绝时提示已经不是原来那个")
            case "NothingToReplyTo":
                return String(localized: "It is not waiting for a reply right now.",
                              comment: "总控台：回一句时对方不在等回答")
            case "Stale":
                return String(localized: "It has moved on since this was shown. Nothing was sent.",
                              comment: "总控台：回一句时状态已经变了")
            case "EmptyText":
                return String(localized: "There is nothing to send.",
                              comment: "总控台：回一句时内容为空")
            case "UserPresent":
                return String(localized: "Someone typed in that terminal a moment ago. Nothing was sent.",
                              comment: "总控台：那个终端十秒内有人打过字")
            case "DraftInLine":
                return String(localized: "That terminal has text waiting in its input line. Nothing was sent.",
                              comment: "总控台：那个终端输入行里有没提交的字")
            case "ChildExited":
                return String(localized: "The program in that terminal has ended.",
                              comment: "总控台：那个终端里的进程已经退出")
            case "KeyFailed":
                return String(localized: "The key did not reach the program.",
                              comment: "总控台：按键没有送到程序")
            case "UnknownTerminal":
                return String(localized: "That terminal is no longer there.",
                              comment: "总控台：终端已经不在了")
            case "NoSuchGroup":
                return String(localized: "That group is no longer there.",
                              comment: "总控台：群已经不在了")
            case "SnoozeInThePast":
                return String(localized: "That time has already passed.",
                              comment: "总控台：先放着到某个时刻，但时刻已过")
            case "SupervisorPage":
                return String(localized: "The group's supervisor is on this page, so it stays in the group's project.",
                              comment: "项目：想把一页移出项目，但这个群的总管在这一页上")
            case "BadName":
                return String(localized: "A group's name is lowercase letters, digits and dashes, 48 at most.",
                              comment: "总控台：新建群时名字不合规则（空的也是）")
            case "GroupExists":
                return String(localized: "There is already a group by that name.",
                              comment: "总控台：新建群时重名")
            case "TooManyGroups":
                return String(localized: "There is no room for another group.",
                              comment: "总控台：新建群时群的数量到了上限")
            case "HasSupervisor":
                return String(localized: "This group already has a supervisor.",
                              comment: "总控台：启动总管时这个群已经有总管了")
            case "AlreadyStarting":
                return String(localized: "A supervisor is already being started for this group.",
                              comment: "总控台：启动总管时已经有一个在启动")
            case "NoSupervisorRole":
                return String(localized: "There is no role that makes a supervisor. Add one in the role library.",
                              comment: "总控台：启动总管时角色库里没有总管角色")
            case "NoSuchPersona":
                return String(localized: "That role no longer exists.",
                              comment: "角色库保存失败时显示的原因")
            case "NotASupervisorRole":
                return String(localized: "That role does not make a supervisor.",
                              comment: "总控台：启动总管时选的角色不是总管角色")
            case "NoCli":
                return String(localized: "This role isn't set up for any agent CLI yet. Pick one in the role library.",
                              comment: "角色启动失败时显示的原因")
            case "NotAbsolute", "NoSuchDirectory", "NotADirectory":
                return String(localized: "That directory is not there.",
                              comment: "总控台：启动总管时选的目录不存在")
            case "OpenFailed", "NoRuntime":
                return String(localized: "No tab could be opened for it.",
                              comment: "总控台：启动总管时开不出标签页")
            case "NothingToFix":
                return String(localized: "It is no longer failing. Nothing was sent.",
                              comment: "总控台：点「修复」时这张卡片已经不是出错")
            case "AlreadyNotified":
                return String(localized: "The supervisor has already been told.",
                              comment: "总控台：点「修复」时已经通知过总管、卡片也没变")
            case "NoAgent":
                return String(localized: "No agent is connected in that terminal, so nothing was typed. It is kept in the group.",
                              comment: "总控台：点「修复」时要打字的终端里没有连着的 agent，话留在群里")
            case "NoSuchTerminal":
                return String(localized: "That terminal is no longer there.",
                              comment: "总控台：终端已经不在了")
            case "NotStartedByHand":
                return String(localized: "There is nothing here the control room can take over.",
                              comment: "总控台：点「让总控台接管？」时，这个总管不是手动启动、能被认出来的那种")
            case "AlreadyTakingOver":
                return String(localized: "The control room is already taking over a supervisor.",
                              comment: "总控台：点「让总控台接管？」时已有一次接管在进行")
            case "EmptyName":
                return String(localized: "A group's name can't be empty.", comment: "总控台：行内改名，名字删空了")
            case "RenameFailed":
                return String(localized: "The group could not be renamed.",
                              comment: "总控台：改名在核心里失败了（比如写不进磁盘）")
            case "RenameBlocked":
                return String(localized: "Records by that name are still on disk from a group that was deleted. Pick another name.",
                              comment: "总控台：改名时新名字下还留着以前删掉的群的记录")
            case "RenameBusy":
                return String(localized: "Another Polter is renaming a group right now. Try again in a few seconds.",
                              comment: "总控台：改名时另一个 Polter 正在改名")
            case "RenameUnfinished":
                return String(localized: "An earlier rename was left unfinished. Restart Polter, then try again.",
                              comment: "总控台：改名时上一次改名没做完")
            case "RenameDeferred":
                return String(localized: "The rename will finish the next time Polter starts; until then the group keeps its old name.",
                              comment: "总控台：改名要等下次启动才能做完")
            case "DeleteFailed":
                return String(localized: "The group is off the list, but some of its records could not be deleted.",
                              comment: "总控台：删除群时群已经从列表删掉了，但有记录没删掉")
            case "MuteInThePast":
                return String(localized: "That time has already passed.",
                              comment: "总控台：先放着到某个时刻，但时刻已过")
            case "NoSupervisor":
                return String(localized: "This group has no supervisor.",
                              comment: "总控台：右侧没有总管时的说明")
            case "NoExecutable":
                return String(localized: "Polter could not find its own program to start the role with.",
                              comment: "总控台：启动总管时找不到 Polter 自己的可执行文件")
            default:
                return String(localized: "Nothing was done (\(name)).",
                              comment: "总控台：核心拒绝了动作，原因是括号里的名字")
            }
        }
    }

    /// The request for an act, as the core's file header writes it.
    static func request(for act: Act) -> [String: Any] {
        switch act {
        case .seen(let group):
            return ["act": "seen", "group": group]
        case .seenTerminal(let terminal):
            return ["act": "seen", "terminal": terminal]
        case .snooze(let group, let untilMs):
            var request: [String: Any] = ["act": "snooze", "group": group]
            if let untilMs { request["until_ms"] = untilMs }
            return request
        case .unsnooze(let group):
            return ["act": "unsnooze", "group": group]
        case .approve(let target):
            return aimed("approve", at: target)
        case .refuse(let target):
            return aimed("refuse", at: target)
        case .reply(let target, let text):
            // A reply is checked against `since_ms` only: the core's table
            // has no `event_ms` for it.
            return ["act": "reply", "terminal": target.terminal, "since_ms": target.sinceMs, "text": text]
        case .newGroup(let name):
            return ["act": "new_group", "name": name]
        case .startSupervisor(let group, let role, let cwd, let session):
            // Left out when the person picked neither: the core then uses
            // the ones its snapshot named. Which session is sent only
            // while the choice is on screen
            // (`ControlRoomStartChoice.sessionSent`).
            var request: [String: Any] = ["act": "start_supervisor", "group": group]
            if let role { request["role"] = role }
            if let cwd { request["cwd"] = cwd }
            if let session { request["session"] = session.rawValue }
            return request
        case .retentionAgree:
            return ["act": "retention_agree"]
        case .fix(let group):
            return ["act": "fix", "group": group]
        case .fixTerminal(let terminal):
            return ["act": "fix", "terminal": terminal]
        case .takeOver(let group):
            return ["act": "take_over", "group": group]
        case .pin(let group):
            return ["act": "pin", "group": group]
        case .unpin(let group):
            return ["act": "unpin", "group": group]
        case .mute(let group, let untilMs):
            // No time: muted until it is unmuted.
            var request: [String: Any] = ["act": "mute", "group": group]
            if let untilMs { request["until_ms"] = untilMs }
            return request
        case .unmute(let group):
            return ["act": "unmute", "group": group]
        case .archive(let group):
            return ["act": "archive", "group": group]
        case .unarchive(let group):
            return ["act": "unarchive", "group": group]
        case .renameGroup(let from, let to):
            return ["act": "rename_group", "from": from, "to": to]
        case .setBrief(let group, let brief):
            return ["act": "set_brief", "group": group, "brief": brief]
        case .deleteGroup(let group, let members, let openTasks):
            return ["act": "delete_group", "group": group, "members": members, "open_tasks": openTasks]
        case .askSupervisor(let group, let ask):
            let word: String
            switch ask {
            case .reportProgress: word = "report"
            case .closeIdleWorkers: word = "close_idle"
            }
            return ["act": "ask_supervisor", "group": group, "ask": word]
        }
    }

    private static func aimed(_ act: String, at target: ControlRoomList.Target) -> [String: Any] {
        var request: [String: Any] = ["act": act, "terminal": target.terminal, "since_ms": target.sinceMs]
        // Handed back exactly as it came; a row that had none sends none
        // and the core answers for that.
        if let eventMs = target.eventMs { request["event_ms"] = eventMs }
        return request
    }

    /// What "this row has been looked at" is said as, for the row with this
    /// id among `rows`; nil when no such row is listed any more.
    ///
    /// A group's row is seen by the group's name. A terminal that is in no
    /// group has no group to name, and for as long as only the first was
    /// sent, what such a terminal finished stayed "not looked at" and what
    /// it raised could not be withdrawn. Which kind a row is the list
    /// already says (`alone`); nothing is worked out from its id.
    static func seen(rowId: String, in rows: [ControlRoomList.Row]) -> Act? {
        guard let row = rows.first(where: { $0.id == rowId }) else { return nil }
        if let alone = row.alone { return .seenTerminal(alone.terminal) }
        return .seen(group: row.id)
    }

    /// What "Fix" on `row` is said as; nil when the row offers no button
    /// to press -- none, or one already pressed. A lone terminal's row is
    /// fixed by its terminal, as `seen` is.
    static func fix(_ row: ControlRoomList.Row) -> Act? {
        guard row.fix == .offered else { return nil }
        if let alone = row.alone { return .fixTerminal(alone.terminal) }
        return .fix(group: row.id)
    }

    /// Do it. Success says nothing; a refusal is thrown, by name.
    func perform(_ act: Act) throws {
        guard let json = try? JSONSerialization.data(
            withJSONObject: Self.request(for: act), options: [.sortedKeys]) else {
            throw Refusal(name: "BadRequest")
        }
        if let refused = send(json) {
            // The core cuts the name to the buffer it is given; an empty one
            // is still a refusal.
            throw Refusal(name: refused.isEmpty ? "Refused" : refused)
        }
    }
}

/// Marks a group seen once its row has stayed selected for a moment with
/// the control room in front (`control-room.md`, 4.3: "stopped, and not
/// looked at yet").
///
/// **Selecting is not looking.** Arrowing past a row on the way to another
/// must not clear it, so nothing is sent until the row has been the
/// selection for `dwell`. And a control room that is not in front is not
/// being looked at, however long its selection has stood.
///
/// This is one deferred call per selection and never a repeating one. The
/// deferring is handed in, so a test can decide when the moment has passed.
final class ControlRoomSeenTracker {
    typealias Later = (_ after: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let dwell: TimeInterval
    private let later: Later
    private let isInFront: () -> Bool
    private let markSeen: (String) -> Void
    /// Counts selections, so that a deferred call can tell whether it is
    /// still about the current one.
    private var generation = 0
    private var selected: String?
    /// Whether the selected row was unseen the last time it was heard of:
    /// what tells "it has just stopped, in front of the person" from "it is
    /// still as it was".
    private var selectedUnseen = false

    init(dwell: TimeInterval = ControlRoomLook.Selection.seenAfter,
         later: @escaping Later,
         isInFront: @escaping () -> Bool,
         markSeen: @escaping (String) -> Void) {
        self.dwell = dwell
        self.later = later
        self.isInFront = isInFront
        self.markSeen = markSeen
    }

    /// The selection is now `row` (nil for none). Call it on every change,
    /// and again when the control room comes to the front with a row
    /// already selected.
    func selectionChanged(to row: ControlRoomList.Row?) {
        generation += 1
        selected = row?.id
        selectedUnseen = row?.unseen ?? false
        // Only a row the core says has not been looked at is worth saying
        // anything about. A group's and a lone terminal's alike: which of
        // the two is said at the end is `ControlRoomActions.seen(rowId:in:)`.
        // (A lone terminal's row was left out here while `seen` could only
        // name a group; it can name a terminal now.)
        guard let row, row.unseen else { return }
        wait(for: row.id)
    }

    /// A new list has arrived. `row` is the selected row as it is now (nil
    /// for none, and for a row the person did not select themselves).
    ///
    /// **A row that stops while the person is on it is seen like any
    /// other**: they selected it, the control room is in front, and its
    /// supervisor's terminal is beside the list -- they watched it finish.
    /// So the moment starts when the core first says "not looked at", and
    /// the same wait and the same check of being in front follow. Without
    /// this the row stayed unseen until the person selected something else
    /// and came back (verify-cr-03). A row that was already unseen is left
    /// alone: every list would otherwise start the moment over and it
    /// would never pass.
    func listChanged(to row: ControlRoomList.Row?) {
        guard row?.id == selected else {
            // The selection is not what it was: a change like any other.
            selectionChanged(to: row)
            return
        }
        let was = selectedUnseen
        selectedUnseen = row?.unseen ?? false
        guard let row, row.unseen, !was else { return }
        generation += 1
        wait(for: row.id)
    }

    private func wait(for group: String) {
        let mine = generation
        later(dwell) { [weak self] in
            guard let self, self.generation == mine, self.selected == group, self.isInFront() else { return }
            self.markSeen(group)
        }
    }
}
