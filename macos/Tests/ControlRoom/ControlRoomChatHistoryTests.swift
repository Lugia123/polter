import Foundation
import Testing

@testable import Ghostty

/// The three history replies (task 2800, S2c-1 contract §3): an error is
/// read before a state, each call's success shape is its own, and a reply
/// that is missing what its state promises is malformed rather than an empty
/// outcome.
struct ControlRoomChatHistoryTests {
    typealias History = ControlRoomChatHistory

    private let jobID = String(repeating: "a", count: 32)
    private let nextToken = String(repeating: "b", count: 32)

    // MARK: - Fixtures

    private func message(
        seq: UInt64 = 0,
        log: UInt64 = 10,
        anchor: String = "p:10",
        liveAnchor: String? = nil,
        contentVersion: UInt64 = 0
    ) -> String {
        let live = liveAnchor.map { "\"\($0)\"" } ?? "null"
        return """
        {"seq":\(seq),"log_seq":\(log),"from":"0x0000000000000001","from_self":false,\
        "author":"worker","at_ms":1700000000000,"summary":false,"channel":0,"text":"hi",\
        "mentions":null,"role":null,"anchor":"\(anchor)","live_anchor":\(live),\
        "content_version":\(contentVersion)}
        """
    }

    private func status(_ state: String) -> String {
        """
        {"ok":true,"state":"\(state)","job_id":"\(jobID)","group":"polter","session":"s1"}
        """
    }

    private func begin(
        state: String = "pending",
        liveSince: UInt64 = 7,
        historyUpper: UInt64 = 9,
        session: String? = "s1",
        snapshot: String? = nil
    ) -> String {
        let sessionField = session.map { "\"session\":\"\($0)\"," } ?? ""
        let snapshotField = snapshot.map { ",\"live_snapshot\":[\($0)]" } ?? ""
        return """
        {"ok":true,"state":"\(state)","job_id":"\(jobID)","group":"polter",\
        \(sessionField)"live_since":\(liveSince),"history_upper":\(historyUpper)\(snapshotField)}
        """
    }

    private func ready(
        stop: String,
        token: String?,
        gap: Bool = false,
        messages: String? = nil,
        session: String? = "s1"
    ) -> String {
        let tokenField = token.map { "\"\($0)\"" } ?? "null"
        let sessionField = session.map { "\"session\":\"\($0)\"," } ?? ""
        let messagesField = messages ?? message()
        return """
        {"ok":true,"state":"ready","job_id":"\(jobID)","group":"polter",\(sessionField)\
        "messages":[\(messagesField)],"stop":"\(stop)","next_token":\(tokenField),\
        "restarted":false,"gap":\(gap)}
        """
    }

    // MARK: - Begin is a snapshot, not a pending poll

    /// A begin carries both water marks and the live snapshot it froze; a
    /// poll's pending reply has none of that and cannot pass for one.
    @Test func testABeginIsASnapshotAndAPendingPollIsNotOne() {
        guard case let .started(page)? = History.decodeBegin(begin(snapshot: message())) else {
            Issue.record("a begin with its snapshot was not read as one")
            return
        }
        #expect(page.jobID == jobID)
        #expect(page.group == "polter")
        #expect(page.session == "s1")
        #expect(page.liveSince == 7)
        #expect(page.historyUpper == 9)
        #expect(page.liveSnapshot.count == 1)
        #expect(page.liveSnapshot[0].anchor == "p:10")

        #expect(History.decodeBegin(status("pending")) == nil)
        #expect(History.decodeBegin(begin(state: "ready", snapshot: message())) == nil)
        #expect(History.decodeBegin(begin(session: nil, snapshot: message())) == nil)
        #expect(History.decodeBegin(begin(snapshot: nil)) == nil)
    }

    /// Pending and cancelled polls both carry the job's identity, and no
    /// page.
    @Test func testPendingAndCancelledPollsCarryTheirIdentity() {
        guard case let .pending(pending)? = History.decodePoll(status("pending")) else {
            Issue.record("a pending poll was not read as one")
            return
        }
        #expect(pending.jobID == jobID)
        #expect(pending.group == "polter")
        #expect(pending.session == "s1")

        guard case let .cancelled(cancelled)? = History.decodePoll(status("cancelled")) else {
            Issue.record("a cancelled poll was not read as cancelled")
            return
        }
        #expect(cancelled.jobID == jobID)
    }

    // MARK: - A ready page and its resume point

    /// A full or budget page must name the record it will resume at; an end
    /// must not; a gap may or may not, and **a gap without a token is a
    /// whole answer**, not a malformed one and not a clean end.
    @Test func testAReadyPageAndItsResumePointAgree() {
        guard case let .ready(full)? = History.decodePoll(ready(stop: "full", token: nextToken)) else {
            Issue.record("a full page with a token was not read")
            return
        }
        #expect(full.nextToken == nextToken)
        #expect(full.stop == .full)
        #expect(full.messages.count == 1)

        guard case .ready? = History.decodePoll(ready(stop: "at_end", token: nil)) else {
            Issue.record("an end without a token was not read")
            return
        }
        guard case .ready? = History.decodePoll(ready(stop: "gap", token: nil, gap: true)) else {
            Issue.record("a gap without a token is a whole answer")
            return
        }
        guard case .ready? = History.decodePoll(ready(stop: "gap", token: nextToken, gap: true)) else {
            Issue.record("a gap with a token was not read")
            return
        }

        #expect(History.decodePoll(ready(stop: "at_end", token: nextToken)) == nil)
        #expect(History.decodePoll(ready(stop: "full", token: nil)) == nil)
        #expect(History.decodePoll(ready(stop: "budget", token: nil)) == nil)
        #expect(History.decodePoll(ready(stop: "too_large", token: nextToken)) == nil)
        #expect(History.decodePoll(ready(stop: "weird", token: nil)) == nil)
    }

    /// The required fields of a ready page are required: a page missing its
    /// identity or its flags is not the page this host drew.
    @Test func testAReadyPageMissingItsFieldsIsMalformed() {
        #expect(History.decodePoll(ready(stop: "full", token: nextToken, session: nil)) == nil)

        let noRestarted = ready(stop: "full", token: nextToken)
            .replacingOccurrences(of: ",\"restarted\":false", with: "")
        #expect(History.decodePoll(noRestarted) == nil)

        let noToken = ready(stop: "full", token: nextToken)
            .replacingOccurrences(of: ",\"next_token\":\"\(nextToken)\"", with: "")
        #expect(History.decodePoll(noToken) == nil)
    }

    /// A cancel takes `cancelled` or a failure and nothing else: a ready
    /// page is not the answer to a cancel.
    @Test func testACancelTakesOnlyCancelledOrAFailure() {
        guard case .cancelled? = History.decodeCancel(status("cancelled")) else {
            Issue.record("a cancelled reply was not read")
            return
        }
        #expect(History.decodeCancel(status("ready")) == nil)
        #expect(History.decodeCancel(status("pending")) == nil)
        #expect(History.decodeCancel(status("started")) == nil)
    }

    // MARK: - Failures

    /// A failure is read before a state. `TooLarge` keeps the token that
    /// names the record which did not fit; a gate-level error has nothing
    /// but its code; an unknown code is kept as written.
    @Test func testAFailureIsReadFirstAndItsCodeIsKept() {
        let tooLarge = """
        {"ok":false,"error":"TooLarge","job_id":"\(jobID)","group":"polter",\
        "session":"s1","next_token":"\(nextToken)"}
        """
        guard case let .failed(t)? = History.decodePoll(tooLarge) else {
            Issue.record("TooLarge was not read as a failure")
            return
        }
        #expect(t.error == "TooLarge")
        #expect(t.jobID == jobID)
        #expect(t.group == "polter")
        #expect(t.session == "s1")
        #expect(t.nextToken == nextToken)

        guard case let .failed(gate)? = History.decodeBegin(#"{"error":"Expired"}"#) else {
            Issue.record("a gate-level error was not read")
            return
        }
        #expect(gate.error == "Expired")
        #expect(gate.jobID == nil)

        guard case let .failed(unknown)? = History.decodeCancel(#"{"ok":false,"error":"Mystery"}"#) else {
            Issue.record("an unknown code was not kept")
            return
        }
        #expect(unknown.error == "Mystery")
    }

    /// A reply that says both success and error is neither, and an error
    /// does not become an empty page.
    @Test func testSuccessAndErrorInOneReplyIsMalformed() {
        #expect(History.decodeBegin(#"{"ok":true,"state":"pending","error":"Busy"}"#) == nil)
        #expect(History.decodePoll(#"{"state":"pending"}"#) == nil)
        #expect(History.decodePoll(#"{"ok":false}"#) == nil)
        #expect(History.decodeBegin("") == nil)
        #expect(History.decodeBegin("not json") == nil)
    }

    // MARK: - The message shape

    /// `anchor` and `content_version` are required, and a live message's
    /// `live_anchor` is kept as written; the host never builds either.
    @Test func testAMessageWithoutItsAnchorOrVersionIsMalformed() {
        let noAnchor = message().replacingOccurrences(of: ",\"anchor\":\"p:10\"", with: "")
        #expect(History.decodePoll(ready(stop: "full", token: nextToken, messages: noAnchor)) == nil)

        let noVersion = message().replacingOccurrences(of: ",\"content_version\":0", with: "")
        #expect(History.decodePoll(ready(stop: "full", token: nextToken, messages: noVersion)) == nil)

        guard case let .ready(page)? = History.decodePoll(
            ready(stop: "full", token: nextToken, messages: message(seq: 9, log: 0, anchor: "l:s1:9", liveAnchor: "l:s1:9"))
        ) else {
            Issue.record("a live message with its live anchor was not read")
            return
        }
        #expect(page.messages[0].anchor == "l:s1:9")
        #expect(page.messages[0].liveAnchor == "l:s1:9")
    }

    /// A `UInt64` above 2^53 is read exactly: no `Double` on the way.
    @Test func testALargeUInt64DoesNotPassThroughADouble() {
        let large: UInt64 = 9_007_199_254_740_993
        guard case let .started(page)? = History.decodeBegin(
            begin(liveSince: large, historyUpper: 9, snapshot: message(contentVersion: large))
        ) else {
            Issue.record("a begin with a large watermark was not read")
            return
        }
        #expect(page.liveSince == large)
        #expect(page.liveSnapshot[0].contentVersion == large)
    }
}
