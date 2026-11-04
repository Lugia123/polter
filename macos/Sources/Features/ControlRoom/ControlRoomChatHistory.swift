import Foundation

/// The replies to the three bounded history calls (task 2800, S2c-1
/// contract §3).
///
/// **Each reply is decoded by the shape of the request that was sent.**
/// There is deliberately no one reply type with every field optional: a
/// begin that lacks its snapshot, a ready page that lacks its stop reason,
/// and a pending poll that claims to have messages would all decode
/// successfully and then be drawn as something they are not.
///
/// **An error is read before a state.** The core's failures are not the
/// success shape: a scan that failed answers `ok=false,error,job_id,group,
/// session` (a `TooLarge` adds `next_token`), and a refusal made before any
/// scan existed (`Expired`, `NoSuchJob`, `Busy`, `LogsClosed`, `BadParams`)
/// answers with `error` alone. An unknown code is kept as the core wrote it,
/// for diagnosis, and is never turned into an empty page.
///
/// **A malformed reply is `nil`, not an empty outcome**: the caller can tell
/// "the core said nothing yet" (a valid `pending`) from "this host could not
/// read what the core said", which is not a quiet chat.
enum ControlRoomChatHistory {
    /// Why a ready page stopped. `too_large` is not here: a page that would
    /// not fit is a failure with the token that names the record which did
    /// not fit, never a ready page.
    enum Stop: String, Decodable, Equatable {
        case atEnd = "at_end"
        case full
        case budget
        /// The scan reached the bottom of the log with damaged records on
        /// the way. **Not every gap has a resume point**: when it does not,
        /// `nextToken` is nil and that is a whole answer, not a malformed
        /// one and not a clean end.
        case gap
    }

    /// A failure the core named. The gate-level codes carry only `error`;
    /// the post-begin ones also carry the job's identity, and `TooLarge`
    /// carries the token to resume at.
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

    /// The identity a pending, cancelled or begin reply carries.
    struct Status: Decodable, Equatable {
        var jobID: String
        var group: String
        var session: String

        private enum CodingKeys: String, CodingKey {
            case group, session
            case jobID = "job_id"
        }
    }

    /// A scan that has started, with the live snapshot taken at the moment
    /// it began. `liveSince` is the live read's water mark; `historyUpper`
    /// is the log's persisted head. They are different numbers and are never
    /// compared.
    struct Begin: Decodable, Equatable {
        var jobID: String
        var group: String
        var session: String
        var liveSince: UInt64
        var historyUpper: UInt64
        var liveSnapshot: [ControlRoomChatData.Message]

        private enum CodingKeys: String, CodingKey {
            case group, session
            case jobID = "job_id"
            case liveSince = "live_since"
            case historyUpper = "history_upper"
            case liveSnapshot = "live_snapshot"
        }
    }

    /// One finished page. **`next_token` is a required key** even when its
    /// value is null: a page that never said whether it can be resumed is
    /// not a page that ended, and reading the two as one is how a truncated
    /// scan looks like the beginning of the log.
    struct Ready: Decodable, Equatable {
        var jobID: String
        var group: String
        var session: String
        var messages: [ControlRoomChatData.Message]
        var stop: Stop
        var nextToken: String?
        var restarted: Bool
        var gap: Bool

        private enum CodingKeys: String, CodingKey {
            case group, session, messages, stop, restarted, gap
            case jobID = "job_id"
            case nextToken = "next_token"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            jobID = try c.decode(String.self, forKey: .jobID)
            group = try c.decode(String.self, forKey: .group)
            session = try c.decode(String.self, forKey: .session)
            messages = try c.decode([ControlRoomChatData.Message].self, forKey: .messages)
            stop = try c.decode(Stop.self, forKey: .stop)
            restarted = try c.decode(Bool.self, forKey: .restarted)
            gap = try c.decode(Bool.self, forKey: .gap)
            guard c.contains(.nextToken) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.nextToken,
                    .init(codingPath: c.codingPath, debugDescription: "a ready page must say whether it can be resumed")
                )
            }
            nextToken = try c.decodeIfPresent(String.self, forKey: .nextToken)
        }
    }

    enum BeginOutcome: Equatable {
        case started(Begin)
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

    /// A begin is a snapshot, never a page: its state must be `pending` and
    /// its identity and both water marks must be present. A poll's pending
    /// reply cannot pass for one.
    static func decodeBegin(_ text: String) -> BeginOutcome? {
        guard let data = data(of: text) else { return nil }
        switch head(of: data) {
        case .malformed:
            return nil
        case .failure(let failure):
            return .failed(failure)
        case .state(let state):
            guard state == "pending",
                  let begin = try? JSONDecoder().decode(Begin.self, from: data)
            else { return nil }
            return .started(begin)
        }
    }

    /// One poll: still running, cancelled, a finished page, or a failure.
    static func decodePoll(_ text: String) -> PollOutcome? {
        guard let data = data(of: text) else { return nil }
        switch head(of: data) {
        case .malformed:
            return nil
        case .failure(let failure):
            return .failed(failure)
        case .state(let state):
            switch state {
            case "pending":
                guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
                return .pending(status)
            case "cancelled":
                guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
                return .cancelled(status)
            case "ready":
                guard let page = try? JSONDecoder().decode(Ready.self, from: data) else { return nil }
                guard resumable(page) else { return nil }
                return .ready(page)
            default:
                // Unknown success state: not a shape this host can act on.
                return nil
            }
        }
    }

    /// A cancel answers `cancelled` or a failure and nothing else: a `ready`
    /// page is not the answer to a cancel.
    static func decodeCancel(_ text: String) -> CancelOutcome? {
        guard let data = data(of: text) else { return nil }
        switch head(of: data) {
        case .malformed:
            return nil
        case .failure(let failure):
            return .failed(failure)
        case .state(let state):
            guard state == "cancelled",
                  let status = try? JSONDecoder().decode(Status.self, from: data)
            else { return nil }
            return .cancelled(status)
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
        /// `ok=true`, with the state the core named (which may be missing,
        /// in which case the caller's stricter shape decides).
        case state(String)
        case malformed
    }

    private static func head(of data: Data) -> Head {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            return .malformed
        }
        if probe.error != nil {
            // An error and `ok=true` are two answers in one reply: not a
            // shape this host can honour, and not a page.
            guard probe.ok != true,
                  let failure = try? JSONDecoder().decode(Failure.self, from: data)
            else { return .malformed }
            return .failure(failure)
        }
        guard probe.ok == true, let state = probe.state else { return .malformed }
        return .state(state)
    }

    /// The stop reason and the resume point must not disagree: an end has no
    /// token, a full or budget page must name one, and a gap may or may not.
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

    private static func data(of text: String) -> Data? {
        text.data(using: .utf8)
    }
}
