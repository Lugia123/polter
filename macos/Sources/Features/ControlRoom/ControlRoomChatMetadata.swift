import Foundation

/// The group's own description, as the core hands it over (`chat_metadata`,
/// contract §Metadata, frozen 2026-11-05).
///
/// **Decoding only.** Nothing here asks the core or draws anything: the feed
/// asks, the header draws. The shape is strict on purpose -- a reply that
/// says `ok` without the brief, the members or the two counts is not a
/// metadata answer, and turning it into an empty one would draw "no brief,
/// no members" over a group that has both.
///
/// `member_count` is the true count and `members_truncated` says the list was
/// cut at the core's bound (200). The two are never inferred from
/// `members.count`: a cut list is not a group of that many people.
enum ControlRoomChatMetadata {
    /// One terminal in the group, as the core knows it now.
    struct Member: Decodable, Equatable {
        var id: String
        /// The name its tab shows; may be empty.
        var title: String
        /// `""` for a terminal in no role, nil when the core did not say.
        var role: String?
    }

    /// The answer to `chat_metadata`.
    struct Group: Decodable, Equatable {
        var group: String
        var brief: String
        var members: [Member]
        var memberCount: UInt32
        var membersTruncated: Bool

        private enum CodingKeys: String, CodingKey {
            case group, brief, members
            case memberCount = "member_count"
            case membersTruncated = "members_truncated"
        }
    }

    enum Outcome: Equatable {
        case ready(Group)
        case failed(String)
    }

    /// A failure is read before a success, as every reading in this
    /// directory does. An error and `ok=true` in one reply is neither.
    static func decode(_ text: String) -> Outcome? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return nil }
        if let error = probe.error {
            guard probe.ok != true else { return nil }
            return .failed(error)
        }
        guard probe.ok == true,
              let group = try? JSONDecoder().decode(Group.self, from: data)
        else { return nil }
        return .ready(group)
    }

    private struct Probe: Decodable {
        var ok: Bool?
        var error: String?
    }
}
