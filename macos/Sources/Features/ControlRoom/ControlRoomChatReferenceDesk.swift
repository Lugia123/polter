import Combine
import Foundation

/// Resolves a message's file reference through the chat door and hands the
/// resulting ticket to **one** preview slot (Root reference identity/
/// ownership supplement).
///
/// **It owns the job, the identity check and the ledger; it does not own the
/// store or the core.** An adoption is published as an `Effect`; the page
/// applies it to `PreviewSlot.Store` and closes old tickets through the
/// existing `PreviewTicket.Source`. Everything here is testable without an
/// app.
///
/// Rules carried from the contract:
/// - the source is accepted only when the canonical anchor is the requested
///   one or the requested anchor is exactly the core's live alias;
/// - a rejected/late reply still returns its unadopted token (effect
///   `.close`), even if no feed property ever held it;
/// - one slot holds one token; adopting replaces and returns the old;
/// - a ready reply is consumed once; `AlreadyOwned` never closes the owner;
/// - **a chat reference must be a matched plugin page or a browser plugin**;
///   `.file` (nothing matched) and `.unavailable` are refusals, never a
///   silent fallback to the file.
final class ControlRoomChatReferenceDesk: ObservableObject {
    typealias R = ControlRoomChatReference
    typealias Reply = ControlRoomChatFeed.Reply
    typealias Ask = ControlRoomChatFeed.Ask

    static let pollDelay: TimeInterval = 0.2
    static let retryDelay: TimeInterval = 2

    enum Effect: Equatable {
        /// Hand the ticket to `cell`; `closeOld` is that slot's previous
        /// token and must be closed by the caller.
        case adopt(
            cell: String, token: String,
            presentation: PreviewTicket.Presentation,
            closeOld: String?,
            anchor: String,
            location: String?
        )
        /// A token the host will not adopt: the caller closes it. Nil when
        /// the reply carried no ticket (a refusal).
        case close(cell: String, token: String?, code: String)
    }

    struct Refusal: Equatable {
        var cell: String
        var code: String
    }

    struct Source: Equatable {
        var group: String
        var anchor: String
        var location: String?
        var reference: String
    }

    @Published private(set) var effect: Effect?
    /// Called on the main thread whenever an effect is published; the page
    /// applies it to the store/tickets. A callback as well as the published
    /// value so a page that does not observe the object still acts.
    var onEffect: ((Effect) -> Void)?
    @Published private(set) var refusal: Refusal?
    /// The cell a reference is being resolved for, so the page can show it.
    @Published private(set) var busyCell: String?

    private let ask: Ask
    private let scheduler: ControlRoomChatScheduling
    private var coordinator = ControlRoomChatPreviewCoordinator()

    private var generation: UInt64 = 0
    private var requestID: String?
    private var jobID: String?
    private var session: String?
    private var pollToken: UUID?
    private var retryToken: UUID?
    private var cell: String?
    private var source: Source?

    init(
        ask: @escaping Ask,
        scheduler: ControlRoomChatScheduling = ControlRoomChatTimerScheduler()
    ) {
        self.ask = ask
        self.scheduler = scheduler
    }

    deinit {
        cancelScheduling()
        cancelJob()
    }

    // MARK: - The person's click

    func resolve(
        cell: String,
        group: String,
        anchor: String,
        location: String?,
        reference: String
    ) {
        guard !reference.isEmpty else { return }
        cancelScheduling()
        cancelJob()
        generation &+= 1
        self.cell = cell
        source = Source(
            group: group, anchor: anchor, location: location, reference: reference
        )
        session = nil
        effect = nil
        refusal = nil
        busyCell = cell
        requestID = ControlRoomChatRequest.newRequestID()
        sendBegin()
    }

    /// The slot is closing or being replaced before an answer: stop the job.
    func cancel(cell: String) {
        guard busyCell == cell else { return }
        generation &+= 1
        cancelScheduling()
        cancelJob()
        busyCell = nil
    }

    /// The slot's owner is gone: the token it adopted comes back for closing.
    @discardableResult
    func close(cell: String) -> String? {
        cancel(cell: cell)
        return coordinator.close(slot: cell)
    }

    func token(of cell: String) -> String? { coordinator.token(of: cell) }

    func clearEffect() { effect = nil }

    private func publish(_ next: Effect) {
        effect = next
        onEffect?(next)
    }
    func clearRefusal() { refusal = nil }

    // MARK: - One begin and its polls

    private func sendBegin() {
        guard let requestID, let source else { return }
        let generation = self.generation
        guard let request = try? ControlRoomChatRequest.referenceBegin(
            group: source.group, requestID: requestID,
            anchor: source.anchor, originalReference: source.reference,
            location: source.location
        ) else {
            finish(cell: cell, code: "BadParams", token: nil)
            return
        }
        switch ask(request) {
        case .notReady:
            guard generation == self.generation else { return }
            retry(requestID: requestID, after: Self.retryDelay, generation: generation)
        case let .refused(why):
            guard generation == self.generation else { return }
            finish(cell: cell, code: why, token: nil)
        case let .answer(text):
            handleBegin(text, requestID: requestID, generation: generation)
        }
    }

    private func retry(requestID: String, after delay: TimeInterval, generation: UInt64) {
        guard retryToken == nil else { return }
        retryToken = scheduler.after(delay) { [weak self] in
            self?.retryToken = nil
            guard let self, self.generation == generation,
                  self.requestID == requestID
            else { return }
            self.sendBegin()
        }
    }

    private func handleBegin(_ text: String, requestID: String, generation: UInt64) {
        let accepted = generation == self.generation && self.requestID == requestID
        guard let outcome = R.decodeBegin(text) else {
            if accepted { finish(cell: cell, code: "malformed reference reply", token: nil) }
            return
        }
        switch outcome {
        case let .failed(failure):
            guard accepted else { return }
            if let named = failure.group, named != source?.group {
                finish(cell: cell, code: "CursorMismatch", token: nil)
                return
            }
            if let named = failure.session, session != nil, named != session {
                finish(cell: cell, code: "CursorMismatch", token: nil)
                return
            }
            if failure.error == "Busy" {
                retry(requestID: requestID, after: Self.pollDelay, generation: generation)
            } else {
                finish(cell: cell, code: failure.error, token: nil)
            }
        case let .started(status):
            guard accepted else {
                cancelReferenceJob(status.jobID)
                return
            }
            guard let source, status.group == source.group,
                  session == nil || status.session == session
            else {
                cancelReferenceJob(status.jobID)
                finish(cell: cell, code: "CursorMismatch", token: nil)
                return
            }
            session = status.session
            jobID = status.jobID
            self.requestID = nil
            schedulePoll(generation: generation)
        }
    }

    private func schedulePoll(generation: UInt64) {
        guard pollToken == nil, let jobID, busyCell != nil else { return }
        pollToken = scheduler.after(Self.pollDelay) { [weak self] in
            self?.pollToken = nil
            guard let self, self.generation == generation else { return }
            self.poll(jobID: jobID, generation: generation)
        }
    }

    private func poll(jobID: String, generation: UInt64) {
        guard let request = try? ControlRoomChatRequest.poll(jobID: jobID) else {
            finish(cell: cell, code: "BadParams", token: nil)
            return
        }
        switch ask(request) {
        case .notReady:
            guard generation == self.generation else { return }
            schedulePoll(generation: generation)
        case let .refused(why):
            guard generation == self.generation else { return }
            finish(cell: cell, code: why, token: nil)
        case let .answer(text):
            handlePoll(text, jobID: jobID, generation: generation)
        }
    }

    private func handlePoll(_ text: String, jobID: String, generation: UInt64) {
        let decoded = R.decodePoll(text)
        // **Decode before the generation check**: a late ready page still
        // carries a ticket, and its owner has to get it back even though the
        // navigation it belonged to has moved on.
        guard generation == self.generation else {
            if case let .ready(ready)? = decoded {
                release(ready: ready, cell: cell ?? "", code: "CursorMismatch",
                        cancelCurrent: false)
            }
            return
        }
        guard let outcome = decoded else {
            let token = tokenFrom(reply: text)
            releaseRaw(
                token: token, cell: cell ?? "",
                identity: "malformed|\(jobID)", code: "malformed reference reply",
                cancelCurrent: true
            )
            return
        }
        switch outcome {
        case let .pending(status):
            guard status.jobID == jobID, matches(status.group, status.session) else {
                schedulePoll(generation: generation)
                return
            }
            schedulePoll(generation: generation)
        case let .cancelled(status):
            guard status.jobID == jobID, matches(status.group, status.session) else {
                finish(cell: cell, code: "CursorMismatch", token: nil)
                return
            }
            finish(cell: cell, code: "Cancelled", token: nil)
        case let .failed(failure):
            if let named = failure.group, named != source?.group {
                finish(cell: cell, code: "CursorMismatch", token: nil)
                return
            }
            if let named = failure.session, session != nil, named != session {
                finish(cell: cell, code: "CursorMismatch", token: nil)
                return
            }
            finish(cell: cell, code: failure.error, token: nil)
        case let .ready(ready):
            handleReady(ready, jobID: jobID, generation: generation)
        }
    }

    private func handleReady(_ ready: R.Ready, jobID: String, generation: UInt64) {
        guard generation == self.generation,
              ready.jobID == jobID,
              let cell,
              let source,
              ready.group == source.group,
              session == nil || ready.session == session
        else {
            // A late or foreign reply: its ticket, if any, must go back,
            // but it must not cancel the request that replaced it.
            release(ready: ready, cell: cell ?? "", code: "CursorMismatch",
                    cancelCurrent: false)
            return
        }
        if session == nil { session = ready.session }
        switch R.accepts(
            source: ready.source,
            requestedAnchor: source.anchor,
            requestedReference: source.reference
        ) {
        case let .rejected(code):
            release(ready: ready, cell: cell, code: code)
            return
        case .accepted:
            break
        }

        switch PreviewTicket.read(ready.fileOpen) {
        case let .failure(.refused(why)):
            finish(cell: cell, code: why, token: nil)
        case .failure:
            release(ready: ready, cell: cell, code: "unreadable ticket")
        case let .success(answer):
            guard case .some(.matched)? = answer.plugin else {
                // **No plugin matched is not a browser and not the file.**
                release(ready: ready, cell: cell, code: "PluginUnavailable",
                        token: answer.token)
                return
            }
            switch answer.presentation {
            case .pluginPage, .browser:
                break
            case .file, .unavailable:
                release(ready: ready, cell: cell, code: "PluginUnavailable",
                        token: answer.token)
                return
            }
            let identity = "\(jobID)|\(ready.source.anchor)|\(ready.source.originalReference)"
            switch coordinator.adopt(token: answer.token, slot: cell, ready: identity) {
            case let .adopted(closeOld, _):
                publish(.adopt(
                    cell: cell, token: answer.token,
                    presentation: answer.presentation, closeOld: closeOld,
                    anchor: ready.source.anchor, location: ready.source.location
                ))
                complete()
            case let .alreadyOwned(owner):
                // The owner keeps it; this reply is not adopted and there is
                // no second ticket to close (it is the same token).
                refusal = Refusal(cell: cell, code: "AlreadyOwned:\(owner)")
                publish(.close(cell: cell, token: nil, code: "AlreadyOwned"))
                complete()
            case .duplicate:
                complete()
            }
        }
    }

    // MARK: - Ending

    private func matches(_ group: String, _ session: String) -> Bool {
        guard let source else { return false }
        return group == source.group && (self.session == nil || self.session == session)
    }

    /// Give a token back for a reply this desk will not adopt.
    private func release(
        ready: R.Ready,
        cell: String,
        code: String,
        token: String? = nil,
        cancelCurrent: Bool = true
    ) {
        let identity = "\(ready.jobID)|\(ready.source.anchor)|\(ready.source.originalReference)"
        var toClose = token
        if toClose == nil, case let .success(answer) = PreviewTicket.read(ready.fileOpen) {
            toClose = answer.token
        }
        if toClose == nil { toClose = tokenFrom(fileOpen: ready.fileOpen) }
        releaseRaw(
            token: toClose, cell: cell, identity: identity, code: code,
            cancelCurrent: cancelCurrent
        )
    }

    /// **Responsibility for a minted token comes before full validation.**
    /// Even when the descriptor is unreadable, a valid token in the reply is
    /// given back; nothing else about the reply is trusted.
    private func releaseRaw(
        token: String?,
        cell: String,
        identity: String,
        code: String,
        cancelCurrent: Bool
    ) {
        var closeToken: String?
        if let token {
            closeToken = coordinator.reject(token: token, ready: identity)
        }
        publish(.close(cell: cell, token: closeToken, code: code))
        if cancelCurrent {
            cancelScheduling()
            cancelJob()
            requestID = nil
            jobID = nil
            busyCell = nil
        }
    }

    private func tokenFrom(reply: String) -> String? {
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // Only a reference ready can hand a ticket over; a token
              // anywhere else is not this job's.
              object["mode"] as? String == "reference",
              object["state"] as? String == "ready",
              let open = object["file_open"] as? [String: Any]
        else { return nil }
        return validToken(open["token"] as? String)
    }

    private func tokenFrom(fileOpen: String) -> String? {
        guard let data = fileOpen.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return validToken(object["token"] as? String)
    }

    private func validToken(_ token: String?) -> String? {
        guard let token, token.utf8.count == 32,
              token.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              })
        else { return nil }
        return token
    }

    private func cancelReferenceJob(_ jobID: String) {
        guard let request = try? ControlRoomChatRequest.cancel(jobID: jobID) else { return }
        _ = ask(request)
    }

    private func complete() {
        cancelScheduling()
        cancelJob()
        requestID = nil
        jobID = nil
        busyCell = nil
    }

    private func finish(cell: String?, code: String, token: String?) {
        let slot = cell ?? ""
        cancelScheduling()
        cancelJob()
        requestID = nil
        jobID = nil
        busyCell = nil
        refusal = Refusal(cell: slot, code: code)
        // The page must clear the previous body and show this failure.
        publish(.close(cell: slot, token: token, code: code))
    }

    private func cancelJob() {
        guard let jobID else { return }
        self.jobID = nil
        guard let request = try? ControlRoomChatRequest.cancel(jobID: jobID) else { return }
        _ = ask(request)
    }

    private func cancelScheduling() {
        if let pollToken { scheduler.cancel(pollToken) }
        if let retryToken { scheduler.cancel(retryToken) }
        pollToken = nil
        retryToken = nil
    }
}
