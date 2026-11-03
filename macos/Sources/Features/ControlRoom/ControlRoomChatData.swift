import Foundation

/// A group's chat as the core will hand it over (task 2791, #2791): the
/// batch `ghostty_app_chat_read` answers, and one message inside it.
///
/// **Decoding only.** Nothing here asks the core, draws anything, or decides
/// what a page shows: the door is not in this tree yet (#2778 is building
/// it), so this file is the shape the host agrees to read, written down
/// where a test can hold it without an app (`tools/mac-logic-tests.json`).
/// What is drawn of a message is a later slice's.
///
/// **The properties are the repository's own spelling and the wire's is
/// `CodingKeys`'**, the way every other reading in this directory is written
/// (`ControlRoomWorkdirs`, `ControlRoomResources`): a host reads a
/// snake_case wire into camelCase fields, and the mapping is stated in one
/// place instead of being implied by the property names.
enum ControlRoomChatData {
    /// The whole answer to one request.
    ///
    /// `cursor` is where the core's log has got to and `next` is what to
    /// pass as `since` to carry on from this batch; both are the log's
    /// numbers (`log_seq`), not the group's per-run `seq`, which restarts
    /// at 1 every time the core does. `more` says the batch was cut short
    /// and there is more waiting right now.
    struct Batch: Decodable, Equatable {
        var group: String
        var cursor: UInt64
        var next: UInt64
        var more: Bool
        var messages: [Message]
    }

    /// One message.
    struct Message: Decodable, Equatable {
        /// The group's own count, **restarted at 1 with every core run**:
        /// an identity inside one run, never a cursor.
        var seq: UInt64
        /// Where this sits in the log on disk, and the number both `next`
        /// and a walk back through history page by. 0 for a message never
        /// written down.
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
            case seq, from, author, summary, channel, text, mentions, role
            case logSeq = "log_seq"
            case fromSelf = "from_self"
            case atMs = "at_ms"
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
