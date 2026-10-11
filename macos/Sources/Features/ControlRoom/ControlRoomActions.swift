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
struct ControlRoomActions {
    /// Sends one request. Returns nil when it was done, or the refusal's
    /// name as the core wrote it.
    typealias Send = (_ json: Data) -> String?

    let send: Send

    enum Act: Equatable {
        case seen(group: String)
        /// Until its state changes; or, with a time, until then (wall clock).
        case snooze(group: String, untilMs: UInt64? = nil)
        case unsnooze(group: String)
        case approve(ControlRoomList.Target)
        case refuse(ControlRoomList.Target)
        case reply(ControlRoomList.Target, text: String)
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
        }
    }

    private static func aimed(_ act: String, at target: ControlRoomList.Target) -> [String: Any] {
        var request: [String: Any] = ["act": act, "terminal": target.terminal, "since_ms": target.sinceMs]
        // Handed back exactly as it came; a row that had none sends none
        // and the core answers for that.
        if let eventMs = target.eventMs { request["event_ms"] = eventMs }
        return request
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
        // Only a row the core says has not been looked at is worth saying
        // anything about.
        guard let row, row.unseen else { return }
        let mine = generation
        let group = row.id
        later(dwell) { [weak self] in
            guard let self, self.generation == mine, self.selected == group, self.isInFront() else { return }
            self.markSeen(group)
        }
    }
}
