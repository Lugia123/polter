import Foundation

/// The one way a chat request reaches the core (task 2800, S2c-1 contract
/// §2), and the request bodies that go through it (§3).
///
/// **One call, in a buffer whose size is known before it.** The core's
/// `ghostty_app_chat_read` follows the `copyJsonOut` rule: it answers the
/// number of bytes the reply needs, writes the body only when that many
/// bytes plus a NUL fit the caller's buffer, and always reports the need on
/// a second call. Asking the size first and then calling again is therefore
/// unnecessary, and the second call is a second chance for the answer to
/// disagree with the size that was measured. Every request here gets the
/// same 96 KiB + 1 buffer, one call, and no retry.
///
/// **Nothing in this file names `GhosttyKit`**: the call is handed in, so the
/// length rules and the strict UTF-8 reading are testable without an app,
/// and `ControlRoomChatCoreAdapter` is the only caller that supplies the
/// real function.
enum ControlRoomChatTransport {
    /// How many bytes of reply body this host will ever accept, not counting
    /// the NUL the buffer keeps after them.
    static let bodyLimit = 96 * 1024

    /// What one request came to.
    enum Outcome: Equatable {
        /// The core's own bytes, already known to be UTF-8.
        case answer(String)
        /// Nothing yet: the core has no reading.
        case notReady
        /// Refused, with words worth writing down.
        case refused(String)
    }

    /// The core, as this file can call it: the request's bytes, a buffer
    /// that is exactly `bodyLimit + 1` long, and the reply's length.
    typealias Call = (
        _ request: UnsafeBufferPointer<CChar>,
        _ out: UnsafeMutableBufferPointer<CChar>
    ) -> Int

    /// Ask once.
    ///
    /// `n == 0` is "nothing yet"; a negative reading, or one longer than the
    /// buffer, is a refusal and the buffer is **not** parsed; 1...`bodyLimit`
    /// is the body, read to exactly `n` bytes and refused unless it is
    /// UTF-8. Never retried, and never asked a second time.
    static func read(_ request: String, call: Call) -> Outcome {
        var bytes = Array(request.utf8CString)
        bytes.removeLast()
        // The last byte stays 0 for the core's NUL, as `copyJsonOut` writes
        // it. The buffer is allocated before the call, at the one size this
        // host uses.
        var buffer = [CChar](repeating: 0, count: bodyLimit + 1)
        let n = bytes.withUnsafeBufferPointer { req in
            buffer.withUnsafeMutableBufferPointer { out in
                call(req, out)
            }
        }

        if n == 0 { return .notReady }
        if n < 0 { return .refused("chat read answered \(n) bytes") }
        if n > bodyLimit {
            return .refused("chat read needs \(n) bytes; the buffer holds \(bodyLimit)")
        }
        let body = buffer.prefix(n).map { UInt8(bitPattern: $0) }
        guard let text = String(bytes: body, encoding: .utf8) else {
            return .refused("chat read answered bytes that are not UTF-8")
        }
        return .answer(text)
    }
}

/// The three history calls' and the live read's request bodies (task 2800,
/// S2c-1 contract §3).
///
/// **Encoded, not concatenated**: `group` is arbitrary text (it may carry
/// quotes, newlines or CJK) and the ids and tokens are checked before the
/// ABI is reached, so a malformed request is a failure here rather than a
/// call that means something else. `resume_token` is omitted, not written as
/// null, when there is none -- the core treats an unknown key as a different
/// request.
enum ControlRoomChatRequest {
    /// What one request body could not be.
    enum Invalid: String, Error, Equatable {
        /// `request_id` must be 1...128 UTF-8 bytes.
        case requestID
        /// `limit` must be 1...200.
        case limit
        /// `job_id` must be exactly 32 lowercase hex characters.
        case jobID
        /// `resume_token` must be exactly 32 lowercase hex characters.
        case resumeToken
        /// An anchor is 1...512 UTF-8 bytes.
        case anchor
        /// Around's window is 0...99 on each side and at most 200 records
        /// with the target.
        case window
        /// A location hint, when present, is not empty.
        case location
        /// A raw reference is 1...4096 UTF-8 bytes.
        case reference
    }

    /// The bound the core enforces on `request_id`.
    static let requestIDLimit = 128
    /// The core's default when `limit` is left out, and the range it accepts.
    static let defaultLimit = 50
    static let limitRange = 1...200

    // MARK: - Building

    /// The live read. `since` is the group's own in-memory `seq`, never a
    /// `log_seq` and never a history token.
    static func live(group: String, since: UInt64) -> String {
        encode("group_read", LiveParams(group: group, since: since))
    }

    /// The group's brief and members (`chat_metadata`, frozen contract
    /// §Metadata). Read-only: no cursor, no seen mark, no write.
    static func metadata(group: String) -> String {
        encode("chat_metadata", MetadataParams(group: group))
    }

    /// A new scan's first request. A repeated begin must pass the **same**
    /// `requestID` and parameters: the core answers it with the original
    /// begin reply rather than rebuilding the snapshot.
    static func begin(
        group: String,
        requestID: String,
        limit: Int = defaultLimit,
        resumeToken: String? = nil
    ) throws -> String {
        let idBytes = requestID.utf8.count
        guard idBytes >= 1, idBytes <= requestIDLimit else { throw Invalid.requestID }
        guard limitRange.contains(limit) else { throw Invalid.limit }
        if let resumeToken, !isOpaqueID(resumeToken) { throw Invalid.resumeToken }
        return encode(
            "chat_history_begin",
            BeginParams(group: group, requestID: requestID, limit: limit, resumeToken: resumeToken)
        )
    }

    /// One poll of an existing scan. The id is checked here, before the ABI.
    static func poll(jobID: String) throws -> String {
        guard isOpaqueID(jobID) else { throw Invalid.jobID }
        return encode("chat_history_poll", JobParams(jobID: jobID))
    }

    /// One cancel of an existing scan. The id is checked here, before the
    /// ABI; a cancel is idempotent in the core.
    static func cancel(jobID: String) throws -> String {
        guard isOpaqueID(jobID) else { throw Invalid.jobID }
        return encode("chat_history_cancel", JobParams(jobID: jobID))
    }

    /// The target and its immediate neighbours around one anchor
    /// (`chat_history_begin {mode:"around"}`). `location` is the core's own
    /// hint from the message, passed back exactly; nil when there is none.
    /// **No limit and no resume token**: the window is `before`/`after`.
    static func aroundBegin(
        group: String,
        requestID: String,
        anchor: String,
        before: Int = 10,
        after: Int = 10,
        location: String? = nil
    ) throws -> String {
        let idBytes = requestID.utf8.count
        guard idBytes >= 1, idBytes <= requestIDLimit else { throw Invalid.requestID }
        guard (0...99).contains(before), (0...99).contains(after),
              before + after + 1 <= 200
        else { throw Invalid.window }
        guard !anchor.isEmpty, anchor.utf8.count <= 512 else { throw Invalid.anchor }
        if let location, location.isEmpty { throw Invalid.location }
        return encode(
            "chat_history_begin",
            AroundParams(
                group: group, requestID: requestID, anchor: anchor,
                before: before, after: after, location: location
            )
        )
    }

    /// Resolve the file reference a message carries
    /// (`chat_history_begin {mode:"reference"}`). `location` is the core's own
    /// hint from the message, passed back exactly; nil when there is none.
    /// **No limit, no resume token, no before/after**: the source and the raw
    /// reference are the whole question.
    static func referenceBegin(
        group: String,
        requestID: String,
        anchor: String,
        originalReference: String,
        location: String? = nil
    ) throws -> String {
        let idBytes = requestID.utf8.count
        guard idBytes >= 1, idBytes <= requestIDLimit else { throw Invalid.requestID }
        guard !anchor.isEmpty, anchor.utf8.count <= 512 else { throw Invalid.anchor }
        let referenceBytes = originalReference.utf8.count
        guard referenceBytes >= 1, referenceBytes <= 4096 else { throw Invalid.reference }
        if let location, location.isEmpty { throw Invalid.location }
        return encode(
            "chat_history_begin",
            ReferenceParams(
                group: group, requestID: requestID, anchor: anchor,
                originalReference: originalReference, location: location
            )
        )
    }

    /// More of one direction from the cursor a previous context page returned
    /// (`chat_history_begin {mode:"context"}`). **The token binds the
    /// direction**; there is no direction or anchor field here.
    static func contextBegin(
        group: String,
        requestID: String,
        resumeToken: String,
        limit: Int = defaultLimit
    ) throws -> String {
        let idBytes = requestID.utf8.count
        guard idBytes >= 1, idBytes <= requestIDLimit else { throw Invalid.requestID }
        guard limitRange.contains(limit) else { throw Invalid.limit }
        guard isOpaqueID(resumeToken) else { throw Invalid.resumeToken }
        return encode(
            "chat_history_begin",
            ContextParams(
                group: group, requestID: requestID, resumeToken: resumeToken, limit: limit
            )
        )
    }

    /// A group search's first or resumed request (`chat_search_begin`).
    /// **The query is canonical before it is encoded**: trimmed ASCII
    /// whitespace, 1...256 UTF-8 bytes, never an empty "match everything".
    static func searchBegin(
        group: String,
        requestID: String,
        query: String,
        limit: Int = defaultLimit,
        resumeToken: String? = nil
    ) throws -> String {
        let idBytes = requestID.utf8.count
        guard idBytes >= 1, idBytes <= requestIDLimit else { throw Invalid.requestID }
        guard limitRange.contains(limit) else { throw Invalid.limit }
        if let resumeToken, !isOpaqueID(resumeToken) { throw Invalid.resumeToken }
        let canonical = try ControlRoomChatQuery.canonical(query)
        return encode(
            "chat_search_begin",
            SearchBeginParams(
                group: group, requestID: requestID, query: canonical,
                limit: limit, resumeToken: resumeToken
            )
        )
    }

    /// One poll of a search job; the same lifecycle as history.
    static func searchPoll(jobID: String) throws -> String {
        guard isOpaqueID(jobID) else { throw Invalid.jobID }
        return encode("chat_search_poll", JobParams(jobID: jobID))
    }

    /// One cancel of a search job (idempotent in the core).
    static func searchCancel(jobID: String) throws -> String {
        guard isOpaqueID(jobID) else { throw Invalid.jobID }
        return encode("chat_search_cancel", JobParams(jobID: jobID))
    }

    /// A fresh request id for a begin. `UUID().uuidString` is 36 ASCII
    /// characters, inside the core's 128-byte bound.
    static func newRequestID() -> String {
        UUID().uuidString
    }

    /// The contract's opaque id: 32 lowercase hex characters, kept as text
    /// rather than decoded into bytes (the core compares the text).
    static func isOpaqueID(_ text: String) -> Bool {
        guard text.utf8.count == 32 else { return false }
        return text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    // MARK: - Wire shapes

    private struct Envelope<Params: Encodable>: Encodable {
        var method: String
        var params: Params
    }

    private struct LiveParams: Encodable {
        var group: String
        var since: UInt64
    }

    private struct MetadataParams: Encodable {
        var group: String
    }

    private struct AroundParams: Encodable {
        var mode = "around"
        var group: String
        var requestID: String
        var anchor: String
        var before: Int
        var after: Int
        var location: String?

        private enum CodingKeys: String, CodingKey {
            case mode, group, anchor, before, after, location
            case requestID = "request_id"
        }
    }

    private struct ContextParams: Encodable {
        var mode = "context"
        var group: String
        var requestID: String
        var resumeToken: String
        var limit: Int

        private enum CodingKeys: String, CodingKey {
            case mode, group, limit
            case requestID = "request_id"
            case resumeToken = "resume_token"
        }
    }

    private struct ReferenceParams: Encodable {
        var mode = "reference"
        var group: String
        var requestID: String
        var anchor: String
        var originalReference: String
        var location: String?

        private enum CodingKeys: String, CodingKey {
            case mode, group, anchor, location
            case requestID = "request_id"
            case originalReference = "original_reference"
        }
    }

    private struct SearchBeginParams: Encodable {
        var group: String
        var requestID: String
        var query: String
        var limit: Int
        var resumeToken: String?

        private enum CodingKeys: String, CodingKey {
            case group, query, limit
            case requestID = "request_id"
            case resumeToken = "resume_token"
        }
    }

    private struct BeginParams: Encodable {
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

    private struct JobParams: Encodable {
        var jobID: String

        private enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
        }
    }

    private static func encode<Params: Encodable>(_ method: String, _ params: Params) -> String {
        let envelope = Envelope(method: method, params: params)
        // Encoding this package's own small shapes cannot fail for a reason
        // the caller could act on; an empty body is a request the core
        // refuses, never one it silently serves.
        guard let data = try? JSONEncoder().encode(envelope),
              let text = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"BadRequest\"}" }
        return text
    }
}
