import Foundation
import Testing

@testable import Ghostty

/// The group search's wire (contract §Search): each reply read by the call
/// that sent it, byte ranges validated against the snippet once, and a query
/// canonicalised before it is ever encoded.
struct ControlRoomChatSearchTests {
    typealias S = ControlRoomChatSearch
    typealias Q = ControlRoomChatQuery

    private let jobID = String(repeating: "a", count: 32)
    private let token = String(repeating: "b", count: 32)

    private func message(anchor: String = "p:1", text: String = "a批量b") -> String {
        """
        {"seq":0,"log_seq":1,"from":"0x0000000000000001","from_self":false,\
        "author":"worker","at_ms":1700000000000,"summary":false,"channel":0,\
        "text":"\(text)","mentions":null,"role":null,"anchor":"\(anchor)",\
        "live_anchor":null,"content_version":0}
        """
    }

    private func hit(
        anchor: String = "p:1",
        snippet: String = "a批量b",
        start: UInt32 = 1,
        end: UInt32 = 7
    ) -> String {
        """
        {"message":\(message(anchor: anchor)),"snippet":"\(snippet)",\
        "snippet_start":0,"ranges":[{"start":\(start),"end":\(end)}]}
        """
    }

    private func status(_ state: String, query: String? = "批量") -> String {
        let queryField = query.map { ",\"query\":\"\($0)\"" } ?? ""
        return """
        {"ok":true,"state":"\(state)","job_id":"\(jobID)","group":"polter",\
        "session":"s1"\(queryField)}
        """
    }

    private func ready(
        results: [String] = [],
        stop: String = "at_end",
        token: String? = nil,
        gap: Bool = false,
        restarted: Bool = false,
        query: String = "批量"
    ) -> String {
        let tokenField = token.map { "\"\($0)\"" } ?? "null"
        return """
        {"ok":true,"state":"ready","job_id":"\(jobID)","group":"polter",\
        "session":"s1","query":"\(query)",\
        "results":[\(results.joined(separator: ","))],"stop":"\(stop)",\
        "next_token":\(tokenField),"restarted":\(restarted),"gap":\(gap)}
        """
    }

    // MARK: - Lifecycle states

    @Test func testBeginIsPendingAndCancelledIsNotAReadyPage() {
        guard case .started? = S.decodeBegin(status("pending")) else {
            Issue.record("a pending begin was not read")
            return
        }
        #expect(S.decodeBegin(status("ready")) == nil)
        guard case .cancelled? = S.decodePoll(status("cancelled")) else {
            Issue.record("a cancelled poll was not read")
            return
        }
        #expect(S.decodePoll(status("ready")) == nil)
    }

    /// **Completeness is only `at_end && !gap && !restarted`.** A full or
    /// budget page is not complete, and a gap/restart is not complete even
    /// at the end.
    @Test func testCompletenessNeedsACleanEnd() {
        let cases: [(String, String?, Bool, Bool, Bool)] = [
            ("at_end", nil, false, false, true),
            ("full", token, false, false, false),
            ("budget", token, false, false, false),
            ("at_end", nil, true, false, false),
            ("at_end", nil, false, true, false),
            ("gap", nil, true, false, false),
        ]
        for (stop, next, gap, restarted, expected) in cases {
            let text = ready(stop: stop, token: next, gap: gap, restarted: restarted)
            guard case let .ready(page)? = S.decodePoll(text) else {
                Issue.record("a valid page was rejected: \(stop)")
                continue
            }
            #expect(page.complete == expected)
        }
    }

    @Test func testAReadyPageAndItsResumePointAgree() {
        guard case .ready? = S.decodePoll(ready(results: [hit()], stop: "full", token: token)) else {
            Issue.record("a full page was not read")
            return
        }
        #expect(S.decodePoll(ready(stop: "full", token: nil)) == nil)
        #expect(S.decodePoll(ready(stop: "at_end", token: token)) == nil)
        #expect(S.decodePoll(ready(stop: "budget", token: nil)) == nil)
        #expect(S.decodePoll(ready(stop: "weird", token: nil)) == nil)
    }

    // MARK: - Snippets and byte ranges

    /// A range must fall on scalar boundaries of the snippet. Cutting one
    /// Chinese character in half is a malformed page, not a highlight moved
    /// to a plausible place.
    @Test func testARangeOnANonScalarBoundaryIsMalformed() {
        // "a批量b": 批 is UTF-8 bytes 1..4; 2 is inside it.
        #expect(S.decodePoll(ready(results: [hit(start: 2, end: 7)])) == nil)
        #expect(S.decodePoll(ready(results: [hit(start: 1, end: 6)])) == nil)
        // The scalar boundaries themselves are fine.
        #expect(S.decodePoll(ready(results: [hit(start: 1, end: 4)])) != nil)
        #expect(S.decodePoll(ready(results: [hit(start: 4, end: 7)])) != nil)
    }

    @Test func testRangesMustBeInsideAndNonEmptyAndOrdered() {
        #expect(S.decodePoll(ready(results: [hit(start: 1, end: 99)])) == nil)
        #expect(S.decodePoll(ready(results: [hit(start: 7, end: 7)])) == nil)
        #expect(S.decodePoll(ready(results: [hit(start: 4, end: 1)])) == nil)

        let twoOverlapping = """
        {"message":\(message()),"snippet":"a批量b","snippet_start":0,\
        "ranges":[{"start":1,"end":4},{"start":3,"end":7}]}
        """
        #expect(S.decodePoll(ready(results: [twoOverlapping])) == nil)

        let forty = (0..<33).map { _ in "{\"start\":1,\"end\":4}" }.joined(separator: ",")
        let tooMany = """
        {"message":\(message()),"snippet":"a批量b","snippet_start":0,"ranges":[\(forty)]}
        """
        #expect(S.decodePoll(ready(results: [tooMany])) == nil)
    }

    /// `snippet_start` must name the same bytes in the full message, on a
    /// scalar boundary. A snippet sliced from another place is not a
    /// highlight we can draw against this message.
    @Test func testTheSnippetMustBeTheMessageTextAtSnippetStart() {
        let wrongStart = """
        {"message":\(message()),"snippet":"批量","snippet_start":0,\
        "ranges":[{"start":0,"end":6}]}
        """
        #expect(S.decodePoll(ready(results: [wrongStart])) == nil)

        let rightStart = """
        {"message":\(message()),"snippet":"批量","snippet_start":1,\
        "ranges":[{"start":0,"end":6}]}
        """
        #expect(S.decodePoll(ready(results: [rightStart])) != nil)
    }

    @Test func testASnippetIsBoundedAndCarriesItsOwnText() {
        let tooBig = String(repeating: "x", count: 513)
        #expect(S.decodePoll(ready(results: [hit(snippet: tooBig)])) == nil)

        let emptyRanges = """
        {"message":\(message()),"snippet":"a批量b","snippet_start":0,"ranges":[]}
        """
        #expect(S.decodePoll(ready(results: [emptyRanges])) == nil)
    }

    @Test func testAFailureIsReadFirstAndKeptAsWritten() {
        let failure = """
        {"ok":false,"error":"CursorMismatch","job_id":"\(jobID)","group":"polter","session":"s1"}
        """
        guard case let .failed(f)? = S.decodePoll(failure) else {
            Issue.record("a failure was not read")
            return
        }
        #expect(f.error == "CursorMismatch")
        #expect(f.jobID == jobID)
        guard case let .failed(gate)? = S.decodeBegin(#"{"error":"NotARead"}"#) else {
            Issue.record("a gate refusal was not read")
            return
        }
        #expect(gate.error == "NotARead")
        #expect(gate.jobID == nil)
        #expect(S.decodeBegin(#"{"ok":true,"state":"pending","error":"Busy"}"#) == nil)
    }

    // MARK: - The query

    @Test func testOnlyAsciiWhitespaceIsTrimmed() {
        #expect(Q.trim(" \t\n\u{0B}\u{0C}\r批量 \t") == "批量")
        #expect(Q.trim("\u{00A0}批量\u{00A0}") == "\u{00A0}批量\u{00A0}")
        #expect(Q.trim("   ") == "")
        #expect(throws: Q.Invalid.empty) { try Q.canonical(" \t\n") }
    }

    @Test func testTheQueryIsOneTo256Utf8Bytes() throws {
        let short = try Q.canonical("批量")
        let longest = try Q.canonical(String(repeating: "a", count: 256))
        #expect(short == "批量")
        #expect(longest.utf8.count == 256)
        #expect(throws: Q.Invalid.tooLong) {
            try Q.canonical(String(repeating: "a", count: 257))
        }
        // 85 three-byte scalars are 255 bytes; 86 are 258.
        let cjk = try Q.canonical(String(repeating: "批", count: 85))
        #expect(cjk.utf8.count == 255)
        #expect(throws: Q.Invalid.tooLong) {
            try Q.canonical(String(repeating: "批", count: 86))
        }
    }

    /// The host does not fold case or normalise: the core owns that rule.
    @Test func testTheHostDoesNotFoldOrNormaliseTheQuery() throws {
        let upper = try Q.canonical("Batch")
        let lower = try Q.canonical("batch")
        #expect(upper == "Batch")
        #expect(lower == "batch")
    }

    // MARK: - Requests

    @Test func testSearchBeginCarriesTheCanonicalQueryAndOptionalToken() throws {
        let request = try ControlRoomChatRequest.searchBegin(
            group: "polter", requestID: "id-1", query: " 批量 ", resumeToken: token
        )
        let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        #expect(object?["method"] as? String == "chat_search_begin")
        let params = object?["params"] as? [String: Any]
        #expect(params?["group"] as? String == "polter")
        #expect(params?["query"] as? String == "批量")
        #expect(params?["resume_token"] as? String == token)

        let fresh = try ControlRoomChatRequest.searchBegin(
            group: "polter", requestID: "id-1", query: "批量"
        )
        #expect(!fresh.contains("resume_token"))
        #expect(throws: Q.Invalid.empty) {
            try ControlRoomChatRequest.searchBegin(group: "polter", requestID: "id", query: "  ")
        }
        #expect(throws: ControlRoomChatRequest.Invalid.jobID) {
            try ControlRoomChatRequest.searchPoll(jobID: "not-a-job")
        }
        #expect(throws: ControlRoomChatRequest.Invalid.jobID) {
            try ControlRoomChatRequest.searchCancel(jobID: "not-a-job")
        }
        let poll = try ControlRoomChatRequest.searchPoll(jobID: jobID)
        let cancel = try ControlRoomChatRequest.searchCancel(jobID: jobID)
        #expect(poll.contains("chat_search_poll"))
        #expect(cancel.contains("chat_search_cancel"))
    }
}
