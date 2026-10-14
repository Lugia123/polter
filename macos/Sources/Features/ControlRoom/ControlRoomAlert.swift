import Foundation

/// The control room calling the person (task 1505; the design's section 9).
///
/// **Whether, when and how often are the core's** (`ControlNotify.zig`):
/// this side is told "call now, about this group" and says it. What is
/// here is the words, and what the control room tells the core about
/// where the person is. No AppKit and no GhosttyKit, so both can be
/// checked on their own.
enum ControlRoomAlert {
    /// The three waits that call the person, as the core names them
    /// (`ghostty_control_room_alert_kind_e`).
    enum Kind: Equatable {
        case needsApproval, needsAnswer, failed
    }

    /// The key in a notification's `userInfo` that says which group it is
    /// about: clicking it goes there.
    static let groupKey = "polterControlRoomGroup"

    /// The notification's title: who waits, and for what.
    static func title(kind: Kind, group: String) -> String {
        switch kind {
        case .needsApproval:
            return String(format: String(localized: "%@ is waiting for your approval", comment: "总控台系统通知标题：某群在等你审批，%@ 是群名"), group)
        case .needsAnswer:
            return String(format: String(localized: "%@ is waiting for your answer", comment: "总控台系统通知标题：某群在等你回答，%@ 是群名"), group)
        case .failed:
            return String(format: String(localized: "%@ has stopped on an error", comment: "总控台系统通知标题：某群出错停下了，%@ 是群名"), group)
        }
    }

    /// The body: what it waits on, in its own words, with the worker's
    /// name when it is a worker; and how many more of the same
    /// supervisor's groups wait, since one supervisor is one notification.
    static func body(who: String, text: String, more: Int) -> String {
        var lines: [String] = []
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (who.isEmpty, said.isEmpty) {
        case (true, true): break
        case (true, false): lines.append(said)
        case (false, true): lines.append(who)
        case (false, false): lines.append("\(who): \(said)")
        }
        if more == 1 {
            lines.append(String(localized: "1 more group of the same supervisor is waiting too.", comment: "总控台系统通知：同一个总管还有 1 个群也在等"))
        } else if more > 1 {
            lines.append(String(format: String(localized: "%lld more groups of the same supervisor are waiting too.", comment: "总控台系统通知：同一个总管还有几个群也在等，%lld 是个数"), more))
        }
        return lines.joined(separator: "\n")
    }

    /// Whether the control room is what the person is looking at: its
    /// window has the keyboard, in the application that is active, and is
    /// not on its way out.
    ///
    /// **Not whether the window is "visible" by its occlusion state** (task
    /// 1531). The first version asked that as well, and on the eleventh
    /// round the control room was never in front however it came there --
    /// and the right column read "showing in the supervisor's tab", which is
    /// what the same controller draws when it thinks its window is covered.
    /// A key window of the active application is on screen; the occlusion
    /// state adds nothing but a way to be wrong.
    static func inFront(appActive: Bool, windowIsKey: Bool, closing: Bool) -> Bool {
        appActive && windowIsKey && !closing
    }

    /// The control room's half of where the person is: in front or not,
    /// and which cards are on screen. Said to the core when it changes and
    /// at no other time (`ghostty_app_control_presence`).
    struct Presence: Equatable {
        var inFront = false
        var cards: [String] = []

        /// What to say for these facts: out of front, no card is in sight,
        /// whatever the list holds.
        static func of(inFront: Bool, cards: [String]) -> Presence {
            Presence(inFront: inFront, cards: inFront ? cards : [])
        }

        /// The JSON the core reads. The cards in the order given; the core
        /// reads them as a set.
        var json: String {
            let names = cards.map(Self.quoted)
            return "{\"in_front\":\(inFront ? "true" : "false"),\"cards\":[\(names.joined(separator: ","))]}"
        }

        /// A JSON string: the same escaping the Windows host writes
        /// (`alert::Presence::json`).
        static func quoted(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
    }

    /// Remembers what was last said, so the same thing is not said twice.
    struct PresenceReporter {
        private(set) var said: Presence?

        /// The JSON to send for `now`, or nil when it is what was said last.
        mutating func report(_ now: Presence) -> String? {
            // Out of front, no card is in sight. The same cards in another
            // order are the same sight: compared as sets, because an order
            // here would be this host's to decide.
            let now = Presence(inFront: now.inFront, cards: now.inFront ? now.cards : [])
            if let said, said.inFront == now.inFront, Set(said.cards) == Set(now.cards) { return nil }
            said = now
            return now.json
        }
    }
}
