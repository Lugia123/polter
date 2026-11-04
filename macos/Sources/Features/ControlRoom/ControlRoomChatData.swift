import Foundation

/// A group's chat as the core will hand it over (task 2791, #2791): the
/// batch `ghostty_app_chat_read` answers, and one message inside it.
///
/// **Decoding only.** Nothing here asks the core, draws anything, or decides
/// what a page shows: this file is the shape the host agrees to read, written
/// down where a test can hold it without an app
/// (`tools/mac-logic-tests.json`). What is drawn of a message is a later
/// slice's.
///
/// **The properties are the repository's own spelling and the wire's is
/// `CodingKeys`'**, the way every other reading in this directory is written
/// (`ControlRoomWorkdirs`, `ControlRoomResources`): a host reads a
/// snake_case wire into camelCase fields, and the mapping is stated in one
/// place instead of being implied by the property names.
enum ControlRoomChatData {
    /// The whole answer to one live read.
    ///
    /// ⚠️ **`cursor`, `next` and `since` belong to the live read**: they are
    /// the group's per-run `seq` and have nothing to do with `log_seq`,
    /// which is where a message sits in the log on disk. `next` is what to
    /// pass as `since` to carry on from this batch. A history page's records
    /// have `seq = 0` and are identified by their `anchor`; they never move
    /// these numbers.
    ///
    /// `session` is **this core run's identity** (contract §8). Live anchors
    /// are meaningful only inside one session, so the host keeps the value
    /// and treats a changed one as a different run, not a different group.
    ///
    /// `more` says the batch was cut short and there is more waiting right
    /// now.
    struct Batch: Decodable, Equatable {
        var group: String
        var session: String
        var cursor: UInt64
        var next: UInt64
        var more: Bool
        var messages: [Message]
    }

    /// One message.
    struct Message: Decodable, Equatable {
        /// The group's own count, **restarted at 1 with every core run**:
        /// an identity inside one run, never a cursor. A history record has
        /// `0` here, because a record on disk has no place in that count.
        var seq: UInt64
        /// Where this sits in the log on disk, and the number the live read
        /// walks by. 0 for a message never written down.
        var logSeq: UInt64
        /// The terminal that said it, as `0x…`; the person's own id is all
        /// zeroes.
        var from: String
        /// **Whether this is the person at the keyboard.** The core knows
        /// and says so; a host that compared `from` against a zero id would
        /// be deciding a fact the core already holds.
        var fromSelf: Bool
        /// The name the speaking terminal had **when it spoke**, which is
        /// what its tab showed then. An id cannot be matched against
        /// anything on screen.
        var author: String
        /// Real wall-clock milliseconds, so this can be shown as a time of
        /// day.
        var atMs: Int64
        /// True when this stands in for messages the supervisor compacted
        /// away: a summary, not something anybody said.
        var summary: Bool
        /// 0 is the public channel; anything else is a task's number.
        var channel: UInt64
        /// The body, already cut to the core's own limit when it was posted.
        var text: String

        /// **The core's identity for this message** (contract §8): an
        /// opaque string, `p:<log_seq>` for a record on disk and
        /// `l:<session>:<seq>` for a live message that has none. The host
        /// keeps it as written and never builds one from text, an array
        /// index or a `seq`: a made-up fallback would silently merge two
        /// messages the core keeps apart.
        var anchor: String

        /// The live identity this message also had, when it arrived from
        /// the live read. Later the same message comes back from history
        /// with its persisted `anchor`, and this is what lets the two be
        /// recognised as one. `nil` on a record that was already persisted
        /// when it was read.
        var liveAnchor: String?

        /// Bumped by the core when a message's content changes; today it is
        /// 0. A cache keyed by `anchor` must also key by this.
        var contentVersion: UInt64

        /// The terminals this named, each with the title it had then.
        ///
        /// ⚠️ **Nil is "the line did not record them", not "it named
        /// nobody"** -- which is what a message that named nobody is, and
        /// the empty array says that. The two look the same to a reader who
        /// folds them (`ChatLog.Entry.mentions` keeps the same distinction
        /// one side of the wire), and drawing last week's message as one
        /// that deliberately addressed nobody is the failure.
        var mentions: [Mention]?

        /// The role the speaker wore then; `""` for a terminal in no role,
        /// and nil on the same terms as `mentions`.
        var role: String?

        private enum CodingKeys: String, CodingKey {
            case seq, from, author, summary, channel, text, mentions, role, anchor
            case logSeq = "log_seq"
            case fromSelf = "from_self"
            case atMs = "at_ms"
            case liveAnchor = "live_anchor"
            case contentVersion = "content_version"
        }
    }

    /// One terminal a message named.
    struct Mention: Decodable, Equatable {
        /// The core's terminal id, as `0x…`.
        var id: String
        /// The title it had when the message was posted. **Absent when it
        /// was empty** -- the line leaves the key out rather than writing
        /// `""`, so a missing title and an empty one are one fact here.
        var title: String?
    }
}
