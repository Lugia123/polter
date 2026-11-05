import Foundation

/// The group search's replies (contract §Search, frozen 2026-11-05).
///
/// **Decoding only.** The sidebar state machine asks and draws; nothing here
/// asks the core. Each reply is read by the shape of the call that was sent:
/// a poll's pending state is not a page, and a page missing its stop reason
/// or its resume point is malformed rather than an empty result set.
///
/// A `Hit` is a message and a **snippet that is not the source**: the full
/// `Message` carries identity and metadata, the snippet is a bounded slice of
/// its raw text, and `ranges` are UTF-8 byte half-open offsets **relative to
/// the snippet**. They are validated against the snippet's scalar boundaries
/// here, once, so no view has to guess what a byte offset means.
enum ControlRoomChatSearch {
    typealias D = ControlRoomChatData

    enum Stop: String, Decodable, Equatable {
        case full
        case budget
        case atEnd = "at_end"
        case gap
    }

    struct Failure: Decodable, Equatable {
        var error: String
        var jobID: String?
        var group: String?
        var session: String?
        var nextToken: String?

        private enum CodingKeys: String, CodingKey {
            case error, group, session
            case jobID = "job_id"
            case nextToken = "next_token"
        }
    }

    struct Status: Decodable, Equatable {
        var jobID: String
        var group: String
        var session: String
        /// The core's canonical query, echoed on pending/ready. Nil from a
        /// begin that did not say; never invented from the typed text.
        var query: String?

        private enum CodingKeys: String, CodingKey {
            case group, session, query
            case jobID = "job_id"
        }
    }

    /// One matching message. `ranges` are non-empty, non-overlapping and
    /// inside `snippet`; a hit that breaks that is not drawn.
    struct Hit: Decodable, Equatable {
        var message: D.Message
        var snippet: String
        var snippetStart: UInt32
        /// UTF-8 byte half-open ranges, relative to `snippet`.
        var ranges: [HitRange]

        private enum CodingKeys: String, CodingKey {
            case message, snippet, ranges
            case snippetStart = "snippet_start"
        }
    }

    struct HitRange: Decodable, Equatable {
        var start: UInt32
        var end: UInt32
    }

    struct Ready: Decodable, Equatable {
        var jobID: String
        var group: String
        var session: String
        var query: String
        var results: [Hit]
        var stop: Stop
        var nextToken: String?
        var restarted: Bool
        var gap: Bool

        private enum CodingKeys: String, CodingKey {
            case group, session, query, results, stop, restarted, gap
            case jobID = "job_id"
            case nextToken = "next_token"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            jobID = try c.decode(String.self, forKey: .jobID)
            group = try c.decode(String.self, forKey: .group)
            session = try c.decode(String.self, forKey: .session)
            query = try c.decode(String.self, forKey: .query)
            results = try c.decode([Hit].self, forKey: .results)
            stop = try c.decode(Stop.self, forKey: .stop)
            restarted = try c.decode(Bool.self, forKey: .restarted)
            gap = try c.decode(Bool.self, forKey: .gap)
            guard c.contains(.nextToken) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.nextToken,
                    .init(codingPath: c.codingPath,
                          debugDescription: "a search page must say whether it can be resumed")
                )
            }
            nextToken = try c.decodeIfPresent(String.self, forKey: .nextToken)
        }

        /// Completeness is the contract's: only a clean end of the captured
        /// range. `full`/`budget` pages are not complete, and a gap or a
        /// restart is never complete even if the scan reached its end.
        var complete: Bool {
            stop == .atEnd && !gap && !restarted
        }
    }

    enum BeginOutcome: Equatable {
        case started(Status)
        case failed(Failure)
    }

    enum PollOutcome: Equatable {
        case pending(Status)
        case cancelled(Status)
        case ready(Ready)
        case failed(Failure)
    }

    enum CancelOutcome: Equatable {
        case cancelled(Status)
        case failed(Failure)
    }

    // MARK: - Decoding

    static func decodeBegin(_ text: String) -> BeginOutcome? {
        guard let data = data(of: text) else { return nil }
        switch head(of: data) {
        case .malformed:
            return nil
        case let .failure(failure):
            return .failed(failure)
        case let .state(state):
            guard state == "pending",
                  let status = try? JSONDecoder().decode(Status.self, from: data)
            else { return nil }
            return .started(status)
        }
    }

    static func decodePoll(_ text: String) -> PollOutcome? {
        guard let data = data(of: text) else { return nil }
        switch head(of: data) {
        case .malformed:
            return nil
        case let .failure(failure):
            return .failed(failure)
        case let .state(state):
            switch state {
            case "pending", "cancelled":
                guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
                    return nil
                }
                return state == "pending" ? .pending(status) : .cancelled(status)
            case "ready":
                guard let page = try? JSONDecoder().decode(Ready.self, from: data),
                      resumable(page),
                      hitsValid(page.results)
                else { return nil }
                return .ready(page)
            default:
                return nil
            }
        }
    }

    static func decodeCancel(_ text: String) -> CancelOutcome? {
        guard let data = data(of: text) else { return nil }
        switch head(of: data) {
        case .malformed:
            return nil
        case let .failure(failure):
            return .failed(failure)
        case let .state(state):
            guard state == "cancelled",
                  let status = try? JSONDecoder().decode(Status.self, from: data)
            else { return nil }
            return .cancelled(status)
        }
    }

    // MARK: - Validation

    /// A snippet is a bounded slice; ranges are UTF-8 byte offsets on scalar
    /// boundaries, non-overlapping, at least one. **One bad range makes the
    /// page malformed** rather than a page with a highlight silently moved
    /// to cut a character in half.
    static func hitsValid(_ hits: [Hit]) -> Bool {
        hits.allSatisfy(valid)
    }

    private static func valid(_ hit: Hit) -> Bool {
        guard hit.snippet.utf8.count <= 512 else { return false }
        guard !hit.ranges.isEmpty, hit.ranges.count <= 32 else { return false }

        // **The snippet must really be the stored text at `snippet_start`.**
        // A range is applied to this snippet, so a snippet that is not the
        // message's own bytes at a scalar boundary would highlight a slice
        // the message does not contain.
        let text = Array(hit.message.text.utf8)
        let snippetBytes = Array(hit.snippet.utf8)
        let start = Int(hit.snippetStart)
        let textBoundaries = scalarBoundaries(hit.message.text)
        guard textBoundaries.contains(start),
              start + snippetBytes.count <= text.count,
              Array(text[start..<(start + snippetBytes.count)]) == snippetBytes
        else { return false }

        let boundaries = scalarBoundaries(hit.snippet)
        let total = hit.snippet.utf8.count
        var previousEnd: UInt32 = 0
        for range in hit.ranges {
            guard range.start < range.end,
                  range.end <= UInt32(total),
                  boundaries.contains(Int(range.start)),
                  boundaries.contains(Int(range.end)),
                  range.start >= previousEnd
            else { return false }
            previousEnd = range.end
        }
        return true
    }

    /// Every UTF-8 byte offset at which a scalar may begin, plus the end.
    private static func scalarBoundaries(_ text: String) -> Set<Int> {
        var offsets: Set<Int> = [0]
        var offset = 0
        for scalar in text.unicodeScalars {
            offset += String(scalar).utf8.count
            offsets.insert(offset)
        }
        return offsets
    }

    private static func resumable(_ page: Ready) -> Bool {
        switch page.stop {
        case .atEnd:
            return page.nextToken == nil
        case .full, .budget:
            return page.nextToken?.isEmpty == false
        case .gap:
            guard let token = page.nextToken else { return true }
            return !token.isEmpty
        }
    }

    // MARK: - The shape every reply starts with

    private struct Probe: Decodable {
        var ok: Bool?
        var state: String?
        var error: String?
    }

    private enum Head {
        case failure(Failure)
        case state(String)
        case malformed
    }

    private static func head(of data: Data) -> Head {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            return .malformed
        }
        if probe.error != nil {
            guard probe.ok != true,
                  let failure = try? JSONDecoder().decode(Failure.self, from: data)
            else { return .malformed }
            return .failure(failure)
        }
        guard probe.ok == true, let state = probe.state else { return .malformed }
        return .state(state)
    }

    private static func data(of text: String) -> Data? {
        text.data(using: .utf8)
    }

    /// The hit's ranges as Swift string ranges for drawing. The wire's are
    /// UTF-8 **byte** offsets; treating them as character offsets would
    /// highlight the middle of a Chinese character. Boundaries were validated
    /// at decode, and a range that still cannot be mapped is dropped rather
    /// than moved.
    static func stringRanges(
        _ snippet: String,
        ranges: [HitRange]
    ) -> [Range<String.Index>] {
        var mapped: [Range<String.Index>] = []
        for range in ranges {
            let utf8 = snippet.utf8
            guard let start = utf8.index(
                    utf8.startIndex, offsetBy: Int(range.start), limitedBy: utf8.endIndex
                  ),
                  let end = utf8.index(
                    utf8.startIndex, offsetBy: Int(range.end), limitedBy: utf8.endIndex
                  ),
                  let stringStart = String.Index(start, within: snippet),
                  let stringEnd = String.Index(end, within: snippet)
            else { continue }
            mapped.append(stringStart..<stringEnd)
        }
        return mapped
    }
}

/// The query's own rules (contract §Search): trim ASCII whitespace, 1...256
/// UTF-8 bytes after trimming, literal substring (the core folds ASCII case;
/// the host does not normalize anything).
enum ControlRoomChatQuery {
    enum Invalid: String, Error, Equatable {
        case empty
        case tooLong
    }

    static let byteLimit = 256

    /// The ASCII whitespace the contract names: HT LF VT FF CR SPACE.
    private static let trimmable: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]

    static func trim(_ text: String) -> String {
        var bytes = Array(text.utf8)
        var start = 0
        var end = bytes.count
        while start < end, trimmable.contains(bytes[start]) { start += 1 }
        while end > start, trimmable.contains(bytes[end - 1]) { end -= 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// The query to send, or why there is nothing to send. A whitespace-only
    /// query is empty; it is never sent as "match everything".
    static func canonical(_ text: String) throws -> String {
        let trimmed = trim(text)
        guard !trimmed.isEmpty else { throw Invalid.empty }
        guard trimmed.utf8.count <= byteLimit else { throw Invalid.tooLong }
        return trimmed
    }
}
