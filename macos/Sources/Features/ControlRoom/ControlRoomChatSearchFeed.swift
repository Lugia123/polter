import Combine
import OSLog
import Foundation

/// One group's search, driven through the real chat door (contract §Search).
///
/// **The sidebar's state is `ControlRoomChatSidebarState`.** This class owns
/// the clock, the job and the generation; it hands pages to that state and
/// never draws. Every request carries a generation captured when it was
/// sent, and a reply from a generation that has moved on is dropped before it
/// can touch the results.
///
/// The one line this file writes is `search: q=… hit=… hasQuery=…`, and it
/// exists for a reading the core cannot produce by itself (see the comment
/// where it is emitted).
///
/// **A new query cancels the old scan.** Typing stops the debounce and the
/// job; submitting starts one begin. A `budget` page that found nothing is
/// carried on through a **scheduled** turn from its resume token, never a
/// recursive call and never the same token twice.
final class ControlRoomChatSearchFeed: ObservableObject {
    /// Where `search: q=… hit=… hasQuery=…` goes: the same `chat-window`
    /// category every other reading of this page is taken from.
    private static let searchLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-window"
    )

    /// **The core's own rule for "is the query in this text"**
    /// (`rpc.zig:6358 nextMatch`): byte by byte, ASCII case folded, everything
    /// else exact. Written once here rather than borrowing a Unicode-aware
    /// `range(of:)`, because the question is whether *the core's* rule holds
    /// in what the renderer was handed.
    static func asciiContains(_ hay: String, _ needle: String) -> Bool {
        let h = Array(hay.utf8)
        let n = Array(needle.utf8)
        guard !n.isEmpty, h.count >= n.count else { return false }
        func fold(_ byte: UInt8) -> UInt8 {
            (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
        }
        for start in 0...(h.count - n.count) {
            var k = 0
            while k < n.count, fold(h[start + k]) == fold(n[k]) { k += 1 }
            if k == n.count { return true }
        }
        return false
    }

    typealias S = ControlRoomChatSearch
    typealias Reply = ControlRoomChatFeed.Reply
    typealias Ask = ControlRoomChatFeed.Ask

    static let debounceDelay: TimeInterval = 0.25
    static let pollDelay: TimeInterval = 0.2
    static let advanceDelay: TimeInterval = 0.05
    static let retryDelay: TimeInterval = 2
    static let limit = 50

    @Published private(set) var state = ControlRoomChatSidebarState()
    /// The group this search is about; nil until opened for one.
    private(set) var group: String?

    private let ask: Ask
    private let scheduler: ControlRoomChatScheduling
    private var started = false
    private var generation: UInt64 = 0

    private var debounceToken: UUID?
    private var retryToken: UUID?
    private var pollToken: UUID?
    private var advanceToken: UUID?
    private var jobID: String?
    private var requestID: String?
    /// The core run the results belong to, as the begin named it.
    private var session: String?
    /// A resume point a failed reply named (e.g. TooLarge). Kept so Try Again
    /// asks from there rather than from the beginning.
    private var failureToken: String?
    private var query = ""
    private var resumeToken: String?
    /// The token the current continuation began at, to catch a scan that
    /// names the same place twice.
    private var lastToken: String?

    /// Whether any part of a scan is out: a begin, a poll, a retry or a
    /// scheduled continuation. **Nothing may start a second scan while one
    /// is in flight** -- a second begin would lose the first job id and the
    /// first poll token.
    private var inFlight: Bool {
        jobID != nil || requestID != nil || retryToken != nil
            || pollToken != nil || advanceToken != nil
    }

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

    // MARK: - The page's moments

    func start(group: String) {
        if let old = self.group, old != group {
            // **A new group is not the old one's search**: stop its clock and
            // job, drop its results, and invalidate every answer.
            cancelScheduling()
            cancelJob()
            generation &+= 1
            state = ControlRoomChatSidebarState()
        }
        self.group = group
        started = true
        // **Coming back continues the question that was here**, from its
        // page cursor if it had one; it does not start a fresh search that
        // would clear the results. A paused scan is left paused and continued
        // by Load more.
        guard state.mode == .search, !state.submitted.isEmpty, jobID == nil else { return }
        switch state.search {
        case .idle, .cancelled, .failed:
            retry()
        default:
            break
        }
    }

    func stop() {
        started = false
        generation &+= 1
        cancelScheduling()
        cancelJob()
        state.pause()
    }

    // MARK: - The slot

    func openSearch() {
        state.openSearch()
    }

    func close() {
        cancelScheduling()
        cancelJob()
        generation &+= 1
        // A page that was out is over; reopening must not find a spinner.
        state.pause()
        state.close()
    }

    /// Switching to a preview: **no search is written while it is shown**,
    /// and the scan is stopped. The snapshot keeps the results and their
    /// cursor, with any in-flight state paused.
    func openPreview(_ source: ControlRoomChatSidebarState.PreviewSource) {
        cancelScheduling()
        cancelJob()
        generation &+= 1
        state.pause()
        state.openPreview(source)
    }

    func backToSearch() {
        state.backToSearch()
    }

    /// Ask the current question again: from the page cursor when there is
    /// one, otherwise a fresh begin, keeping the hits already found.
    func retry() {
        guard state.mode == .search, !inFlight, !state.query.isEmpty else { return }
        cancelScheduling()
        generation &+= 1
        guard let canonical = try? ControlRoomChatQuery.canonical(state.query) else {
            finish("BadParams")
            return
        }
        query = canonical
        state.retryAnswering()
        // The failed reply's own point is more current than an older page
        // cursor the state happens to still hold.
        begin(token: failureToken ?? state.nextToken)
    }

    func select(_ anchor: String) { state.select(anchor) }

    func previewReady() { state.previewReady() }
    func previewFailed(_ code: String) { state.previewFailed(code) }

    // MARK: - Typing

    /// The field changed. **The old scan is stopped first**: its answers are
    /// for different words and must not be drawn under these.
    func setQuery(_ text: String) {
        guard state.mode == .search else { return }
        // **A panel that is re-created hands back the text it was given.**
        // That is not an edit, and it must not clear the results the slot
        // still holds.
        guard text != state.query else { return }
        cancelScheduling()
        cancelJob()
        generation &+= 1
        state.typing(text)
        guard ControlRoomChatQuery.trim(text).isEmpty == false else { return }
        debounceToken = scheduler.after(Self.debounceDelay) { [weak self] in
            self?.debounceToken = nil
            self?.submitNow()
        }
    }

    /// Return pressed, or the debounce fired.
    func submitNow() {
        guard state.mode == .search else { return }
        cancelScheduling()
        cancelJob()
        generation &+= 1
        guard let canonical = state.submit() else { return }
        query = canonical
        session = nil
        failureToken = nil
        begin(token: nil)
    }

    /// The person asked for the next page of the same query.
    func loadMore() {
        guard state.mode == .search, !inFlight, state.hasMore, let token = state.nextToken else { return }
        cancelScheduling()
        generation &+= 1
        begin(token: token)
    }

    func cancel() {
        generation &+= 1
        cancelScheduling()
        cancelJob()
        finish(nil, cancelled: true)
    }

    // MARK: - One begin and its polls

    private func begin(token: String?) {
        guard started, group != nil else { return }
        requestID = ControlRoomChatRequest.newRequestID()
        resumeToken = token
        lastToken = token
        jobID = nil
        state.beginAnswering()
        sendBegin()
    }

    private func sendBegin() {
        guard started, let group, let requestID else { return }
        let generation = self.generation
        guard let request = try? ControlRoomChatRequest.searchBegin(
            group: group, requestID: requestID, query: query,
            limit: Self.limit, resumeToken: resumeToken
        ) else {
            finish("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            retry(token: requestID, after: Self.retryDelay, generation: generation)
        case let .refused(why):
            finish(why)
        case let .answer(text):
            handleBegin(text, requestID: requestID, generation: generation)
        }
    }

    private func retry(token requestID: String, after delay: TimeInterval, generation: UInt64) {
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
        guard let outcome = S.decodeBegin(text) else {
            guard accepted else { return }
            finish("malformed search reply")
            return
        }
        switch outcome {
        case let .failed(failure):
            guard accepted else { return }
            if let named = failure.group, named != group { finish("CursorMismatch"); return }
            if let named = failure.session, session != nil, named != session {
                finish("CursorMismatch")
                return
            }
            if failure.error == "Busy" {
                retry(token: requestID, after: Self.pollDelay, generation: generation)
            } else {
                failureToken = failure.nextToken
                finish(failure.error)
            }
        case let .started(status):
            guard accepted else {
                cancelUnaccepted(status.jobID)
                return
            }
            guard status.group == group,
                  status.query == query,
                  session == nil || status.session == session
            else {
                cancelUnaccepted(status.jobID)
                finish(status.query == nil || status.query != query
                    ? "CursorMismatch" : "BadParams")
                return
            }
            session = status.session
            failureToken = nil
            jobID = status.jobID
            self.requestID = nil
            schedulePoll(generation: generation)
        }
    }

    private func schedulePoll(generation: UInt64) {
        guard pollToken == nil, jobID != nil, started else { return }
        pollToken = scheduler.after(Self.pollDelay) { [weak self] in
            self?.pollToken = nil
            guard let self, self.generation == generation else { return }
            self.poll(jobID: self.jobID, generation: generation)
        }
    }

    private func poll(jobID: String?, generation: UInt64) {
        guard started, let jobID else { return }
        guard let request = try? ControlRoomChatRequest.searchPoll(jobID: jobID) else {
            finish("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            schedulePoll(generation: generation)
        case let .refused(why):
            finish(why)
        case let .answer(text):
            handlePoll(text, jobID: jobID, generation: generation)
        }
    }

    private func handlePoll(_ text: String, jobID: String, generation: UInt64) {
        guard let outcome = S.decodePoll(text) else {
            guard generation == self.generation else { return }
            finish("malformed search reply")
            return
        }
        switch outcome {
        case let .pending(status):
            guard generation == self.generation else { return }
            guard status.jobID == jobID,
                  status.group == group,
                  status.query == query,
                  session == nil || status.session == session
            else {
                // An answer for another job is not this job ending: keep
                // asking for the one that is out rather than locking.
                schedulePoll(generation: generation)
                return
            }
            schedulePoll(generation: generation)
        case let .cancelled(status):
            // A cancel may come without the echoed query; what it may not
            // omit is the job it cancels.
            guard generation == self.generation else { return }
            guard status.jobID == jobID,
                  status.group == group,
                  status.query == nil || status.query == query,
                  session == nil || status.session == session
            else {
                finish("CursorMismatch")
                return
            }
            finish(nil, cancelled: true)
        case let .ready(page):
            guard generation == self.generation else {
                cancelUnaccepted(page.jobID)
                return
            }
            guard page.jobID == jobID,
                  page.group == group,
                  page.query == query,
                  session == nil || page.session == session
            else {
                if page.jobID != jobID {
                    cancelUnaccepted(page.jobID)
                } else {
                    // This job answered with a page that is not ours; stop
                    // it before ending the request.
                    cancelJob()
                }
                finish("CursorMismatch")
                return
            }
            if session == nil { session = page.session }
            self.jobID = nil
            // **The one instrument for "the result's summary does not contain
            // the query"** (2026-11-08). The core cannot emit such a hit:
            // `snippetOf` returns nil when the query is not in the record's
            // text and that row is dropped (`rpc.zig:6288`). So a `0` here
            // means the *rendering* took something other than `hit.snippet`
            // (or the query that reached the core was not the one typed).
            // `hasQuery` uses the core's own rule -- ASCII case ignored,
            // everything else exact -- not a second one.
            for hit in page.results {
                Self.searchLog.notice(
                    "search: q=\"\(page.query, privacy: .public)\" hit=\(hit.message.anchor, privacy: .public) hasQuery=\(Self.asciiContains(hit.snippet, page.query) ? 1 : 0, privacy: .public)"
                )
            }
            state.absorb(page)
            // **An empty budget page is progress.** Carry the scan on from
            // its token, once, in a scheduled turn; a repeated token is a
            // scan that is not advancing.
            if page.results.isEmpty, page.stop == .budget, let next = page.nextToken {
                guard next != lastToken else {
                    state.fail("the search scan stopped advancing")
                    return
                }
                scheduleAdvance(token: next, generation: generation)
            }
        case let .failed(failure):
            guard generation == self.generation else {
                if let named = failure.jobID { cancelUnaccepted(named) }
                return
            }
            if let named = failure.group, named != group { finish("CursorMismatch"); return }
            if let named = failure.session, session != nil, named != session {
                finish("CursorMismatch")
                return
            }
            if let named = failure.jobID, named != jobID {
                // An answer about another job says nothing about this one;
                // it must not leave this request in flight for ever.
                cancelUnaccepted(named)
                finish(failure.error)
                return
            }
            switch failure.error {
            case "Busy":
                schedulePoll(generation: generation)
            default:
                failureToken = failure.nextToken
                finish(failure.error)
            }
        }
    }

    private func scheduleAdvance(token: String, generation: UInt64) {
        guard advanceToken == nil else { return }
        advanceToken = scheduler.after(Self.advanceDelay) { [weak self] in
            self?.advanceToken = nil
            guard let self, self.generation == generation else { return }
            self.begin(token: token)
        }
    }

    // MARK: - Cancellation

    /// A terminal answer: nothing is in flight any more, and every scheduled
    /// turn for this question goes. **Without this, `inFlight` stays true and
    /// no retry can ever start.**
    private func finish(
        _ code: String?,
        cancelled isCancelled: Bool = false
    ) {
        // A known job must be cancelled, not merely forgotten: the core is
        // still scanning for an answer nobody will draw.
        cancelJob()
        requestID = nil
        jobID = nil
        if let retryToken { scheduler.cancel(retryToken) }
        if let pollToken { scheduler.cancel(pollToken) }
        if let advanceToken { scheduler.cancel(advanceToken) }
        retryToken = nil
        pollToken = nil
        advanceToken = nil
        if isCancelled { state.cancel() } else if let code { state.fail(code) }
    }

    private func cancelUnaccepted(_ jobID: String) {
        guard jobID != self.jobID else { return }
        guard let request = try? ControlRoomChatRequest.searchCancel(jobID: jobID) else { return }
        _ = ask(request)
    }

    private func cancelJob() {
        requestID = nil
        guard let jobID else { return }
        self.jobID = nil
        guard let request = try? ControlRoomChatRequest.searchCancel(jobID: jobID) else { return }
        _ = ask(request)
    }

    private func cancelScheduling() {
        if let debounceToken { scheduler.cancel(debounceToken) }
        if let retryToken { scheduler.cancel(retryToken) }
        if let pollToken { scheduler.cancel(pollToken) }
        if let advanceToken { scheduler.cancel(advanceToken) }
        debounceToken = nil
        retryToken = nil
        pollToken = nil
        advanceToken = nil
    }
}
