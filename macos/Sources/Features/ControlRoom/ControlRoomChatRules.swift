import Foundation

/// What the chat page decides without a view (task 2015, M4a): the command
/// a group's chat runs and which chats go when too many are kept.
enum ControlRoomChatRules {
    /// How many chats are kept; the Windows host's `chat_page` keeps as
    /// many.
    static let kept = 4

    /// One argument for the shell that runs the command: in single quotes,
    /// a single quote inside it closed, escaped and opened again.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `--embedded`: the one group, no list of groups beside it, and no
    /// way to another (C2, 8d782a892; group seq 251).
    static func command(group: String) -> String {
        "polter +chat " + shellQuoted("--group=" + group) + " --embedded"
    }

    /// Which of `order` -- the chats' groups, the one looked at longest ago
    /// first -- go so that `kept` remain: the first ones, never `front`.
    /// Kept in that order as they are looked at (`lookedAt`), so nothing is
    /// compared to find the oldest.
    static func overKept(_ order: [String], front: String?, kept: Int = kept) -> [String] {
        Array(order.filter { $0 != front }.prefix(max(0, order.count - kept)))
    }

    /// `order` after `group` is looked at: it goes last.
    static func lookedAt(_ group: String, in order: [String]) -> [String] {
        order.filter { $0 != group } + (order.contains(group) ? [group] : [])
    }
}
