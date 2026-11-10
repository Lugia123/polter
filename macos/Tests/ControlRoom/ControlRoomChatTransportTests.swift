import Foundation
import Testing

@testable import Ghostty

/// The single ABI call and the request bodies (task 2800, S2c-1 contract
/// §2/§3): the call happens once in a fixed buffer, the length rules hold,
/// and a request is escaped by the encoder rather than by string
/// concatenation.
struct ControlRoomChatTransportTests {
    typealias Transport = ControlRoomChatTransport
    typealias Request = ControlRoomChatRequest

    // MARK: - One call, one buffer

    /// **A reply within the core's own budget costs one call**, in a buffer
    /// of 96 KiB + 1: the first size is the core's page budget, and the
    /// second call is only for a live page above it.
    @Test func testTheCoreIsCalledOnceInTheFixedBuffer() {
        let request = #"{"method":"group_read","params":{"group":"polter","since":7}}"#
        var calls = 0
        var seenRequest = ""
        var seenCapacity = 0
        let outcome = Transport.read(request) { bytes, out in
            calls += 1
            seenRequest = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            seenCapacity = out.count
            out[0] = 0x61
            out[1] = 0x62
            return 2
        }
        #expect(calls == 1)
        #expect(seenRequest == request)
        #expect(seenCapacity == Transport.bodyLimit + 1)
        #expect(outcome == .answer("ab"))
    }

    /// A body of exactly 96 KiB is an answer, and the last byte of the
    /// buffer is still there for the core's NUL.
    @Test func testExactlyNinetySixKiBIsAnAnswer() {
        let body = Array(repeating: UInt8(ascii: "a"), count: Transport.bodyLimit)
        let outcome = Transport.read("{}") { _, out in
            #expect(out.count == Transport.bodyLimit + 1)
            for (i, byte) in body.enumerated() { out[i] = CChar(bitPattern: byte) }
            return body.count
        }
        if case let .answer(text) = outcome {
            #expect(text.utf8.count == Transport.bodyLimit)
        } else {
            Issue.record("expected an answer, got \(outcome)")
        }
    }

    /// **One byte over the core's budget is now an answer, not a refusal**
    /// (the user's `chat read needs 104317 bytes; the buffer holds 98304`).
    /// The first call is asked at 96 KiB + 1; the reply's length is the
    /// signal to grow, and the same request is asked again at that length.
    @Test func testAReplyOverTheBudgetIsReadAtItsOwnSize() {
        // The user's own reading, kept as the shape this exists for.
        let needed = 104_317
        var calls = 0
        var firstCapacity = 0
        var secondCapacity = 0
        let outcome = Transport.read("{}") { _, out in
            calls += 1
            if calls == 1 {
                firstCapacity = out.count
                return needed           // does not fit: nothing written
            }
            secondCapacity = out.count
            for i in 0..<needed { out[i] = CChar(bitPattern: UInt8(ascii: "a")) }
            return needed
        }
        #expect(calls == 2)
        #expect(firstCapacity == Transport.bodyLimit + 1)
        #expect(secondCapacity == needed + 1)
        if case let .answer(text) = outcome {
            #expect(text.utf8.count == needed)
        } else {
            Issue.record("expected an answer, got \(outcome)")
        }
    }

    /// **The live ceiling is 4 MiB, and a reply past it is refused with both
    /// numbers named.** The buffer is filled with bytes that are not UTF-8,
    /// so the refusal is provably about the length and not about the bytes;
    /// and nothing past the first call is written or parsed.
    @Test func testAReplyOverFourMiBIsRefusedByNameAndIsNotParsed() {
        var calls = 0
        let outcome = Transport.read("{}") { _, out in
            calls += 1
            out[0] = CChar(bitPattern: 0xFF)
            return Transport.maxBodyLimit + 1
        }
        #expect(calls == 1)
        #expect(outcome == .refused(
            "chat read needs \(Transport.maxBodyLimit + 1) bytes; the cap is \(Transport.maxBodyLimit)"))
    }

    /// A live read can gain a message between the two calls: a length that
    /// grew is asked again, and the answer is the one that fit.
    @Test func testAReplyThatGrowsBetweenCallsIsAskedAgain() {
        let first = Transport.bodyLimit + 1
        let second = Transport.bodyLimit + 10
        var calls = 0
        let outcome = Transport.read("{}") { _, out in
            calls += 1
            switch calls {
            case 1:
                return first            // fits nowhere in 96 KiB + 1
            case 2:
                return second           // grew; 96 KiB + 2 is too small
            default:
                for i in 0..<second { out[i] = CChar(bitPattern: UInt8(ascii: "b")) }
                return second
            }
        }
        #expect(calls == 3)
        if case let .answer(text) = outcome {
            #expect(text.utf8.count == second)
        } else {
            Issue.record("expected an answer, got \(outcome)")
        }
    }

    /// A reply that keeps growing is a caller to stop: it is refused after
    /// `growAttempts` grows rather than asking for ever.
    @Test func testAReplyThatKeepsGrowingIsStopped() {
        var calls = 0
        let outcome = Transport.read("{}") { _, out in
            calls += 1
            return out.count        // always one byte more than this buffer
        }
        #expect(calls == Transport.growAttempts + 1)
        if case let .refused(why) = outcome {
            #expect(why.hasPrefix("chat read kept growing; the last reading was "))
        } else {
            Issue.record("expected a refusal, got \(outcome)")
        }
    }

    /// A negative injected reading is a transport failure, not a body.
    @Test func testANegativeReadingIsRefused() {
        let outcome = Transport.read("{}") { _, out in
            out[0] = CChar(bitPattern: 0xFF)
            return -1
        }
        #expect(outcome == .refused("chat read answered -1 bytes"))
    }

    /// Zero is "nothing yet"; a short body that is not UTF-8 is a refusal.
    /// The two must not look the same.
    @Test func testZeroAndInvalidUTF8AreDifferent() {
        let nothing = Transport.read("{}") { _, _ in 0 }
        #expect(nothing == .notReady)

        let broken = Transport.read("{}") { _, out in
            out[0] = CChar(bitPattern: 0xC3)
            out[1] = CChar(bitPattern: 0x28)
            return 2
        }
        #expect(broken == .refused("chat read answered bytes that are not UTF-8"))
    }

    /// Only the first `n` bytes are read: what the core left after them is
    /// not part of the answer.
    @Test func testOnlyTheFirstNBytesAreParsed() {
        let outcome = Transport.read("{}") { _, out in
            out[0] = CChar(bitPattern: UInt8(ascii: "o"))
            out[1] = CChar(bitPattern: UInt8(ascii: "k"))
            out[2] = CChar(bitPattern: 0xFF)
            return 2
        }
        #expect(outcome == .answer("ok"))
    }

    // MARK: - Request bodies

    private struct LiveWire: Decodable {
        struct Params: Decodable {
            var group: String
            var since: UInt64
        }
        var method: String
        var params: Params
    }

    private struct BeginWire: Decodable {
        struct Params: Decodable {
            var group: String
            var requestID: String
            var limit: Int
            var resumeToken: String?
            private enum CodingKeys: String, CodingKey {
                case group, limit
                case requestID = "request_id"
                case resumeToken = "resume_token"
            }
        }
        var method: String
        var params: Params
    }

    private struct JobWire: Decodable {
        struct Params: Decodable {
            var jobID: String
            private enum CodingKeys: String, CodingKey { case jobID = "job_id" }
        }
        var method: String
        var params: Params
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// A group name is text, not a fragment: quotes, newlines and CJK all
    /// survive the round trip, and `since` is a `UInt64` that never passes
    /// through a `Double` (this one is above 2^53).
    @Test func testALiveRequestEscapesTheGroupAndKeepsALargeSince() throws {
        let group = "a\"b\n中文"
        let since: UInt64 = 9_007_199_254_740_993
        let wire = try JSONDecoder().decode(LiveWire.self, from: Data(Request.live(group: group, since: since).utf8))
        #expect(wire.method == "group_read")
        #expect(wire.params.group == group)
        #expect(wire.params.since == since)
    }

    /// A begin carries its default limit and leaves `resume_token` out
    /// entirely when there is none.
    @Test func testABeginOmitsAMissingResumeToken() throws {
        let text = try Request.begin(group: "polter", requestID: Request.newRequestID())
        let wire = try JSONDecoder().decode(BeginWire.self, from: Data(text.utf8))
        #expect(wire.method == "chat_history_begin")
        #expect(wire.params.limit == Request.defaultLimit)
        #expect(wire.params.resumeToken == nil)
        let params = try #require(try object(text)["params"] as? [String: Any])
        #expect(params["resume_token"] == nil)
        #expect(params["group"] as? String == "polter")
    }

    /// A resume token is kept as the text it is, not decoded into a cursor.
    @Test func testABeginKeepsItsResumeTokenAsText() throws {
        let token = String(repeating: "a", count: 31) + "0"
        let text = try Request.begin(group: "g", requestID: "r", limit: 200, resumeToken: token)
        let wire = try JSONDecoder().decode(BeginWire.self, from: Data(text.utf8))
        #expect(wire.params.limit == 200)
        #expect(wire.params.resumeToken == token)
    }

    /// The bounds are refused before the ABI is reached: `request_id`
    /// 1...128 UTF-8 bytes, `limit` 1...200, and an opaque id is exactly 32
    /// lowercase hex characters.
    @Test func testTheBoundsAreRefusedBeforeTheCall() throws {
        #expect(throws: Request.Invalid.requestID) {
            try Request.begin(group: "g", requestID: "")
        }
        #expect(throws: Request.Invalid.requestID) {
            try Request.begin(group: "g", requestID: String(repeating: "x", count: 129))
        }
        #expect(throws: Request.Invalid.limit) {
            try Request.begin(group: "g", requestID: "r", limit: 0)
        }
        #expect(throws: Request.Invalid.limit) {
            try Request.begin(group: "g", requestID: "r", limit: 201)
        }
        #expect(throws: Request.Invalid.resumeToken) {
            try Request.begin(group: "g", requestID: "r", resumeToken: "short")
        }
        let longest = String(repeating: "x", count: 128)
        let text = try Request.begin(group: "g", requestID: longest, limit: 1)
        let wire = try JSONDecoder().decode(BeginWire.self, from: Data(text.utf8))
        #expect(wire.params.requestID == longest)
    }

    /// Poll and cancel take one id, the same opaque form, and say which call
    /// they are.
    @Test func testPollAndCancelNameTheirJob() throws {
        let id = String(repeating: "0", count: 31) + "f"
        let poll = try JSONDecoder().decode(JobWire.self, from: Data(Request.poll(jobID: id).utf8))
        #expect(poll.method == "chat_history_poll")
        #expect(poll.params.jobID == id)
        let cancel = try JSONDecoder().decode(JobWire.self, from: Data(Request.cancel(jobID: id).utf8))
        #expect(cancel.method == "chat_history_cancel")
        #expect(cancel.params.jobID == id)
    }

    /// The id form is the contract's: 32 lowercase hex, no upper case and no
    /// other length.
    @Test func testTheOpaqueIdFormIsLowercaseHexOfThirtyTwo() throws {
        #expect(Request.isOpaqueID(String(repeating: "a", count: 32)))
        #expect(!Request.isOpaqueID(String(repeating: "A", count: 32)))
        #expect(!Request.isOpaqueID(String(repeating: "a", count: 31)))
        #expect(!Request.isOpaqueID(String(repeating: "a", count: 33)))
        #expect(!Request.isOpaqueID(String(repeating: "g", count: 32)))
        #expect(throws: Request.Invalid.jobID) { try Request.poll(jobID: "not-a-job") }
        #expect(throws: Request.Invalid.jobID) { try Request.cancel(jobID: "not-a-job") }
    }
}
