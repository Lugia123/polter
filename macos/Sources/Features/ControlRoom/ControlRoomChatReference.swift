import Foundation

/// A message's file reference, resolved by the core (contract §File reference
/// source validation, and the Root reference identity/ownership supplement).
///
/// **The source is an identity, not a path the host worked out.** It carries
/// the canonical anchor, the core-verified live alias (if any), the optional
/// location hint and the exact raw reference. A host accepts it only when the
/// group, session, job and raw reference have already been validated **and**
/// either the canonical anchor is the one asked for or the requested anchor is
/// exactly the source's live alias. Nothing here guesses a near identity.
///
/// **The ticket is handed over once.** Minting is the core's; from the moment
/// a ready reply names the token the host owns it: every reject, late answer
/// or close path must give an unadopted token back, and a slot that adopted it
/// closes on replacement, eviction or close. A job cache expiring is not a
/// close.
enum ControlRoomChatReference {
    typealias H = ControlRoomChatHistory

    /// The core's identity for the resolved reference.
    struct Source: Equatable {
        var anchor: String
        /// **Only a core-verified alias**, nil when there is none. A host
        /// never derives it from the requested anchor.
        var liveAnchor: String?
        /// The core's position hint, exactly as written.
        var location: String?
        var originalReference: String
    }

    struct Failure: Decodable, Equatable {
        var error: String
        var jobID: String?
        var group: String?
        var session: String?

        private enum CodingKeys: String, CodingKey {
            case error, group, session
            case jobID = "job_id"
        }
    }

    /// A ready reference reply. `fileOpen` is the **existing `files_open`
    /// output, byte-for-byte** (including its refusal shape), kept as compact
    /// JSON text so the existing ticket/descriptor parser reads it and no
    /// second spelling of that shape is invented here.
    struct Ready: Equatable {
        var jobID: String
        var group: String
        var session: String
        var source: Source
        var fileOpen: String
    }

    enum Outcome: Equatable {
        case ready(Ready)
        case failed(Failure)
    }

    // MARK: - Decoding

    static func decode(_ text: String) -> Outcome? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decodeReady(data)
    }

    private static func decodeReady(_ data: Data) -> Outcome? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? String {
            guard object["ok"] as? Bool != true,
                  let failure = try? JSONDecoder().decode(Failure.self, from: data)
            else { return nil }
            return .failed(failure)
        }
        guard object["ok"] as? Bool == true,
              object["state"] as? String == "ready",
              object["mode"] as? String == "reference",
              object["next_token"] == nil,
              object["direction"] == nil,
              object["target_index"] == nil,
              let jobID = object["job_id"] as? String,
              let group = object["group"] as? String,
              let session = object["session"] as? String,
              let rawSource = object["source"] as? [String: Any],
              let source = decodeSource(rawSource),
              let rawOpen = object["file_open"] as? [String: Any],
              let openData = try? JSONSerialization.data(
                withJSONObject: rawOpen, options: [.sortedKeys]
              ),
              let fileOpen = String(data: openData, encoding: .utf8)
        else { return nil }
        return .ready(Ready(
            jobID: jobID, group: group, session: session,
            source: source, fileOpen: fileOpen
        ))
    }

    private enum Head {
        case failure(Failure)
        case state(String)
    }

    private static func head(of data: Data) -> Head? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? String {
            guard object["ok"] as? Bool != true,
                  let failure = try? JSONDecoder().decode(Failure.self, from: data)
            else { return nil }
            return .failure(failure)
        }
        guard object["ok"] as? Bool == true, let state = object["state"] as? String else {
            return nil
        }
        return .state(state)
    }

    private static func decodeSource(_ object: [String: Any]) -> Source? {
        guard let anchor = object["anchor"] as? String, !anchor.isEmpty,
              let reference = object["original_reference"] as? String, !reference.isEmpty,
              // The two nullable keys must be **present**: "did not say" and
              // "said null" are different facts in this contract.
              object.keys.contains("live_anchor"),
              object.keys.contains("location")
        else { return nil }
        let live = object["live_anchor"]
        let location = object["location"]
        guard live is NSNull || live is String,
              location is NSNull || location is String
        else { return nil }
        return Source(
            anchor: anchor,
            liveAnchor: live as? String,
            location: location as? String,
            originalReference: reference
        )
    }

    struct Status: Decodable, Equatable {
        var jobID: String
        var group: String
        var session: String

        private enum CodingKeys: String, CodingKey {
            case group, session
            case jobID = "job_id"
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

    static func decodeBegin(_ text: String) -> BeginOutcome? {
        guard let data = text.data(using: .utf8), let head = head(of: data) else { return nil }
        switch head {
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
        guard let data = text.data(using: .utf8), let head = head(of: data) else { return nil }
        switch head {
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
                guard case let .ready(ready)? = decodeReady(data) else { return nil }
                return .ready(ready)
            default:
                return nil
            }
        }
    }

    // MARK: - Acceptance

    enum Accept: Equatable {
        /// The source is this request's, and the ticket may be adopted.
        case accepted
        /// The reply is not this request's (stale, late, wrong group/session/
        /// job/reference). **Its ticket, if any, must be given back.**
        case rejected(String)
    }

    /// Whether a ready reply may be adopted. The caller has already checked
    /// the raw reference, group, session and job; this is the identity rule
    /// that remains: canonical equality, or the requested anchor being the
    /// source's **live alias** exactly.
    static func accepts(
        source: Source,
        requestedAnchor: String,
        requestedReference: String
    ) -> Accept {
        guard source.originalReference == requestedReference else {
            return .rejected("ReferenceNotFound")
        }
        if source.anchor == requestedAnchor { return .accepted }
        if let live = source.liveAnchor, live == requestedAnchor { return .accepted }
        return .rejected("AnchorStale")
    }
}

/// Who owns a preview ticket. **One slot, one token, and one handover per
/// ready reply.** The existing `PreviewSlot.Store` already keeps one token
/// per cell; this coordinator is the single place that decides whether a
/// token is adopted, replaced or given back, so the two cannot disagree.
///
/// - adopting into a slot that already holds another token returns the old
///   one to close;
/// - a token another slot holds is `alreadyOwned`, and the existing owner is
///   never closed;
/// - a ready reply is consumed once: a second handling of the same identity
///   closes nothing;
/// - a rejected/late token that no slot adopted is returned to the refusing
///   path, which closes it;
/// - closing a slot returns its token, and a job cache expiring is not a
///   close.
struct ControlRoomChatPreviewCoordinator: Equatable {
    private var owners: [String: String] = [:]
    private var tokenOwners: [String: String] = [:]
    private var consumed: Set<String> = []
    private var consumedOrder: [String] = []
    /// One handover per reply is remembered for a bounded window, not for the
    /// life of the app.
    static let consumedLimit = 128

    enum Adoption: Equatable {
        /// `closeOld` is the slot's previous token; `closeNew` is the ticket
        /// just handed over when the reply was a duplicate (always nil on a
        /// real adoption).
        case adopted(closeOld: String?, closeNew: String?)
        case alreadyOwned(String)
        /// This ready reply was already handled once.
        case duplicate
    }

    mutating func adopt(
        token: String,
        slot: String,
        ready identity: String
    ) -> Adoption {
        guard !consumed.contains(identity) else { return .duplicate }
        remember(identity)
        if let other = tokenOwners[token], other != slot {
            return .alreadyOwned(other)
        }
        let old = owners[slot]
        owners[slot] = token
        tokenOwners[token] = slot
        if let old, old != token {
            tokenOwners.removeValue(forKey: old)
            return .adopted(closeOld: old, closeNew: nil)
        }
        return .adopted(closeOld: nil, closeNew: nil)
    }

    /// The refusing path: close the token **only if no slot owns it**, and
    /// only the first time this reply is seen.
    @discardableResult
    mutating func reject(
        token: String,
        ready identity: String
    ) -> String? {
        guard !consumed.contains(identity) else { return nil }
        remember(identity)
        guard tokenOwners[token] == nil else { return nil }
        return token
    }

    /// A slot is replaced, evicted or closed.
    @discardableResult
    mutating func close(slot: String) -> String? {
        guard let token = owners.removeValue(forKey: slot) else { return nil }
        tokenOwners.removeValue(forKey: token)
        return token
    }

    func token(of slot: String) -> String? { owners[slot] }
    func isAdopted(_ token: String) -> Bool { tokenOwners[token] != nil }

    private mutating func remember(_ identity: String) {
        consumed.insert(identity)
        consumedOrder.append(identity)
        if consumedOrder.count > Self.consumedLimit {
            let gone = consumedOrder.removeFirst()
            consumed.remove(gone)
        }
    }
}
