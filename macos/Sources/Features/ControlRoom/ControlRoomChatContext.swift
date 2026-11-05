import Foundation

/// The two direct-location replies (contract §History and direct around, with
/// the Root exact context response supplement): `mode:"around"` and
/// `mode:"context"`.
///
/// **Neither uses the generic `next_token`.** They carry their own two
/// cursors (`older_token`, `newer_token`), the two end flags, and a `mode`
/// that says which shape the page is. A page that carries `next_token` is not
/// one of these -- accepting it would give the host two names for one cursor
/// and one of them would be wrong after a merge.
///
/// **Around names its target**, and the target must be the message at
/// `target_index` in the page. Context says which direction it extended and
/// returns the cursor for that direction; the caller never crosses a record
/// it did not keep.
enum ControlRoomChatContext {
    typealias D = ControlRoomChatData
    typealias H = ControlRoomChatHistory

    enum Direction: String, Decodable, Equatable {
        case older
        case newer
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

    /// Both shapes share the page's body, stop reason and cursor pair.
    struct Page: Equatable {
        var jobID: String
        var group: String
        var session: String
        var messages: [D.Message]
        var olderToken: String?
        var newerToken: String?
        var olderAtEnd: Bool
        var newerAtEnd: Bool
        var stop: H.Stop
        var gap: Bool
        var restarted: Bool
    }

    struct Around: Equatable {
        var page: Page
        /// The resolved target's index in `page.messages`.
        var targetIndex: Int

        var target: D.Message? {
            page.messages.indices.contains(targetIndex)
                ? page.messages[targetIndex]
                : nil
        }
    }

    struct Context: Equatable {
        var page: Page
        /// Which side this page extended.
        var direction: Direction
    }

    enum AroundOutcome: Equatable {
        case ready(Around)
        case failed(Failure)
    }

    enum BeginOutcome: Equatable {
        case started(H.Status)
        case failed(Failure)
    }

    /// A begin for a history job whose page will be around or context. The
    /// begin itself is the common pending status; the watermarks are not
    /// this host's business here.
    static func decodeBegin(_ text: String) -> BeginOutcome? {
        guard let data = data(of: text), let head = head(of: data) else { return nil }
        switch head {
        case let .failure(failure):
            return .failed(failure)
        case let .state(state):
            guard state == "pending",
                  let status = try? JSONDecoder().decode(H.Status.self, from: data)
            else { return nil }
            return .started(status)
        }
    }

    enum PollOutcome: Equatable {
        case pending(H.Status)
        case cancelled(H.Status)
        case around(Around)
        case context(Context)
        case failed(Failure)
    }

    /// A poll of a history job whose ready page may be around or context.
    /// Pending/cancelled carry the common status; a ready page is read by
    /// the `mode` it names. A legacy history ready (no mode) is deliberately
    /// **not** this decoder's answer.
    static func decodePoll(_ text: String) -> PollOutcome? {
        guard let data = data(of: text) else { return nil }
        guard let head = head(of: data) else { return nil }
        switch head {
        case let .failure(failure):
            return .failed(failure)
        case let .state(state):
            switch state {
            case "pending", "cancelled":
                guard let status = try? JSONDecoder().decode(H.Status.self, from: data) else {
                    return nil
                }
                return state == "pending" ? .pending(status) : .cancelled(status)
            case "ready":
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mode = object["mode"] as? String
                else { return nil }
                switch mode {
                case "around":
                    guard case let .ready(around)? = decodeAround(text) else { return nil }
                    return .around(around)
                case "context":
                    guard case let .ready(context)? = decodeContext(text) else { return nil }
                    return .context(context)
                default:
                    return nil
                }
            default:
                return nil
            }
        }
    }

    enum ContextOutcome: Equatable {
        case ready(Context)
        case failed(Failure)
    }

    // MARK: - Decoding

    static func decodeAround(_ text: String) -> AroundOutcome? {
        guard let data = data(of: text) else { return nil }
        guard let head = head(of: data) else { return nil }
        switch head {
        case let .failure(failure):
            return .failed(failure)
        case .state("ready"):
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["mode"] as? String == "around",
                  object["next_token"] == nil,
                  object["target_index"] != nil,
                  object["direction"] == nil,
                  let body = decodePage(object),
                  let targetIndex = object["target_index"] as? Int,
                  body.messages.indices.contains(targetIndex)
            else { return nil }
            return .ready(Around(page: body, targetIndex: targetIndex))
        case .state:
            return nil
        }
    }

    static func decodeContext(_ text: String) -> ContextOutcome? {
        guard let data = data(of: text) else { return nil }
        guard let head = head(of: data) else { return nil }
        switch head {
        case let .failure(failure):
            return .failed(failure)
        case .state("ready"):
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["mode"] as? String == "context",
                  object["next_token"] == nil,
                  object["target_index"] == nil,
                  let raw = object["direction"] as? String,
                  let direction = Direction(rawValue: raw),
                  let body = decodePage(object)
            else { return nil }
            return .ready(Context(page: body, direction: direction))
        case .state:
            return nil
        }
    }

    // MARK: - The shared page

    private static func decodePage(_ object: [String: Any]) -> Page? {
        guard let jobID = object["job_id"] as? String,
              let group = object["group"] as? String,
              let session = object["session"] as? String,
              let rawMessages = object["messages"] as? [Any],
              let stopRaw = object["stop"] as? String,
              let stop = H.Stop(rawValue: stopRaw),
              let olderAtEnd = object["older_at_end"] as? Bool,
              let newerAtEnd = object["newer_at_end"] as? Bool,
              let gap = object["gap"] as? Bool,
              let restarted = object["restarted"] as? Bool,
              object.keys.contains("older_token"),
              object.keys.contains("newer_token")
        else { return nil }

        var messages: [D.Message] = []
        for raw in rawMessages {
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let message = try? JSONDecoder().decode(D.Message.self, from: data)
            else { return nil }
            messages.append(message)
        }
        // A target's neighbours are unfiltered messages, so every message in
        // an around/context page has a real anchor.
        guard messages.allSatisfy({ !$0.anchor.isEmpty }) else { return nil }

        return Page(
            jobID: jobID,
            group: group,
            session: session,
            messages: messages,
            olderToken: object["older_token"] as? String,
            newerToken: object["newer_token"] as? String,
            olderAtEnd: olderAtEnd,
            newerAtEnd: newerAtEnd,
            stop: stop,
            gap: gap,
            restarted: restarted
        )
    }

    // MARK: - The common head

    private struct Probe: Decodable {
        var ok: Bool?
        var state: String?
        var error: String?
    }

    private enum Head {
        case state(String)
        case failure(Failure)
    }

    private static func head(of data: Data) -> Head? {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            return nil
        }
        if probe.error != nil {
            guard probe.ok != true,
                  let failure = try? JSONDecoder().decode(Failure.self, from: data)
            else { return nil }
            return .failure(failure)
        }
        guard probe.ok == true, let state = probe.state else { return nil }
        return .state(state)
    }

    private static func data(of text: String) -> Data? {
        text.data(using: .utf8)
    }
}
