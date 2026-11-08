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

/// **Where each group was left, kept across the chat being closed** (design
/// §23.1, the Q1 gap; task 3070).
///
/// `close(at:)` destroys a chat's feed and its view, and the reading anchor
/// lives only in the feed -- so opening a fifth group, or renaming one, took
/// the first group's place with it. The container keeps the last few here
/// instead.
///
/// **The key is the group's name**, because that is the core's identity:
/// `GroupRename.zig` says it in one line -- "A group's name is its identity.
/// There is no id behind it" -- and a rename rewrites every record's `group`
/// field. A rename therefore *moves* an entry (`renamed(from:to:)`); it does
/// not leave one under a name nothing will ask for again.
///
/// **Bounded, and it has to be**: a night opens more groups than a session
/// has rows for, and a place that is never asked for again is dead weight.
/// Least recently *used* goes first -- `get` counts as use.
struct ControlRoomChatReadingPlaces {
    struct Place: Equatable {
        var id: String
        var offset: Double
    }

    /// How many groups are remembered. Eight is "the ones a person goes back
    /// to in a sitting", and it is four more than the chats kept open.
    static let capacity = 8

    /// Oldest use first.
    private(set) var order: [String] = []
    private var places: [String: Place] = [:]

    var count: Int { order.count }

    /// The place `group` was left at, if it is still remembered. **A read
    /// counts as a use**: asking is how a person comes back to it.
    mutating func get(_ group: String) -> Place? {
        guard let place = places[group] else { return nil }
        order = ControlRoomChatRules.lookedAt(group, in: order)
        return place
    }

    /// Remember `place` for `group`, dropping the least recently used when
    /// that makes one too many. **A place is only ever put when the reader
    /// really had one** -- a group opened and left unread puts nothing, which
    /// is what keeps "read" and "not read" two answers.
    mutating func put(_ place: Place, for group: String) {
        places[group] = place
        // **`lookedAt` only moves a group it already holds** (its doc says
        // the caller makes an unknown one): a group's first place is appended
        // here.
        order.removeAll { $0 == group }
        order.append(group)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            places[oldest] = nil
        }
    }

    /// **A renamed group is the same document**: its place moves with the
    /// name. Called only when the core has accepted the rename -- a refused
    /// one left both names as they were.
    mutating func renamed(from: String, to: String) {
        guard let place = places.removeValue(forKey: from) else { return }
        order.removeAll { $0 == from }
        put(place, for: to)
    }
}
