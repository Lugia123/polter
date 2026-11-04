import Foundation
import Testing

@testable import Ghostty

/// The chat page's reading of an answer and what it does with it
/// (`ControlRoomChatFeed`, `ControlRoomChatData`).
///
/// **The door is a closure here**, which is what the three-outcome `Ask`
/// buys: every case below runs with no core and no window, and the one
/// outcome a window cannot tell from another -- "nothing yet" against "the
/// answer never came" -- is asserted directly.
struct ControlRoomChatFeedTests {
    typealias Feed = ControlRoomChatFeed

    private func answer(group: String = "polter", cursor: UInt64 = 3, next: UInt64 = 3,
                        more: Bool = false, messages: String) -> String {
        """
        {"ok":true,"group":"\(group)","cursor":\(cursor),"since":0,"next":\(next),\
        "more":\(more),"messages":[\(messages)]}
        """
    }

    private func message(_ seq: UInt64, _ log: UInt64, _ text: String,
                         mentions: String = "null", role: String = "null",
                         self_: Bool = false) -> String {
        """
        {"seq":\(seq),"log_seq":\(log),"from":"0x0000000000000001","from_self":\(self_),\
        "author":"worker","at_ms":1700000000000,"summary":false,"channel":0,\
        "text":"\(text)","mentions":\(mentions),"role":\(role)}
        """
    }

    // MARK: - The one reading that is easy to get wrong

    /// ⚠️ **`null` and `[]` are two facts, and a reader that folds them
    /// draws a message that addressed nobody as one whose mentions were
    /// lost.** The core keeps the distinction (`ChatLog.Entry.mentions`)
    /// and the wire carries it; this is the host's half of the same rule.
    @Test func testAMessageThatNamedNobodyIsNotEmptyForNotRecorded() throws {
        let recorded = try #require(Feed.decode(answer(messages: message(1, 10, "hi", mentions: "[]"))))
        #expect(recorded.messages[0].mentions == [])

        let notRecorded = try #require(Feed.decode(answer(messages: message(1, 10, "hi", mentions: "null"))))
        #expect(notRecorded.messages[0].mentions == nil)

        // The same split for the role, which is written as `""` rather than
        // left out when the line knows there was none.
        let noRole = try #require(Feed.decode(answer(messages: message(1, 10, "hi", role: "\"\""))))
        #expect(noRole.messages[0].role == "")
    }

    @Test func testTheNamesTheCoreWritesAreTheOnesRead() throws {
        let batch = try #require(Feed.decode(answer(messages: message(1, 10, "hi", self_: true))))
        #expect(batch.group == "polter")
        #expect(batch.cursor == 3)
        #expect(batch.next == 3)
        #expect(batch.more == false)
        #expect(batch.messages[0].logSeq == 10)
        #expect(batch.messages[0].fromSelf)
        #expect(batch.messages[0].atMs == 1700000000000)
    }

    /// A mention carries the title the terminal had when it was named, and a
    /// title that was empty is left out rather than written as `""`.
    @Test func testAMentionHoldsTheTitleItHadThen() throws {
        let m = message(1, 10, "hi", mentions: #"[{"id":"0x0000000000000002","title":"worker"}]"#)
        let batch = try #require(Feed.decode(answer(messages: m)))
        #expect(batch.messages[0].mentions?.first?.id == "0x0000000000000002")
        #expect(batch.messages[0].mentions?.first?.title == "worker")
    }

    @Test func testSomethingElseEntirelyIsNotAnAnswer() {
        #expect(Feed.decode("") == nil)
        #expect(Feed.decode("{\"refused\":\"access\"}") == nil)
    }

    // MARK: - What the feed does with an answer

    /// ⚠️ **An answer about another group is thrown away.** Switching groups
    /// while a request is in flight is ordinary; merging that batch would
    /// put one group's words under another group's name.
    @Test func testAnAnswerAboutAnotherGroupIsNotThisGroupsMessages() {
        let feed = Feed { _ in .answer(self.answer(group: "other", messages: self.message(1, 10, "theirs"))) }
        feed.start(group: "polter")
        #expect(feed.messages.isEmpty)
        #expect(feed.trouble?.contains("other") == true)
    }

    /// The same message in two batches is kept once, and the cursor only
    /// moves forward.
    @Test func testABatchThatRepeatsItselfAddsNothingAndDoesNotWalkBack() throws {
        let one = try #require(Feed.decode(answer(cursor: 1, next: 10, messages: message(1, 10, "hi"))))
        let feed = Feed { _ in .notReady }
        feed.start(group: "polter")
        #expect(feed.take(one, for: "polter") == 1)
        #expect(feed.take(one, for: "polter") == 0)
        #expect(feed.messages.count == 1)
    }

    /// **Nothing yet is not a fault**: it is not drawn and it is not said,
    /// while a refusal is a sentence worth keeping.
    @Test func testNothingYetAndARefusalAreTwoDifferentThings() {
        let quiet = Feed { _ in .notReady }
        quiet.start(group: "polter")
        #expect(quiet.trouble == nil)

        let refused = Feed { _ in .refused("NoSuchGroup") }
        refused.start(group: "polter")
        #expect(refused.trouble == "NoSuchGroup")
    }

    // MARK: - The request

    @Test func testTheRequestIsTheEnvelopeTheToolSpeaks() {
        #expect(Feed.request(group: "polter", since: 7)
            == #"{"method":"group_read","params":{"group":"polter","since":7}}"#)
        #expect(Feed.request(group: "a\"b", since: 0).contains(#""group":"a\"b""#))
    }
}
