import Combine
import Foundation
import OSLog

/// Something that can put a block off until later and take it back again.
///
/// The feed never sleeps and never spins: every "look again" is one of these,
/// and the tests hand in a scheduler they can step by hand, so a state
/// machine that waits is tested without waiting (`ControlRoomChatTimerScheduler`
/// is the production one).
protocol ControlRoomChatScheduling: AnyObject {
    /// Arrange `work` once, after `delay`; the token takes it back.
    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> UUID
    func cancel(_ token: UUID)
}

/// The production scheduler: a one-shot `Timer` on the main run loop, which
/// is where the chat page already lives.
final class ControlRoomChatTimerScheduler: ControlRoomChatScheduling {
    private var timers: [UUID: Timer] = [:]

    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> UUID {
        let token = UUID()
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
            self?.timers.removeValue(forKey: token)
            work()
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[token] = timer
        return token
    }

    func cancel(_ token: UUID) {
        timers.removeValue(forKey: token)?.invalidate()
    }

    deinit {
        for timer in timers.values { timer.invalidate() }
    }
}

/// One group's chat, as the page shows it (task 2791; the bootstrap and live
/// state machine, task 2800 S2c-2a).
///
/// **One feed, one group.** `ControlRoomChatContainer` already makes one per
/// group and keeps at most four, so this class holds this group's messages
/// and nothing else. Asking it for another group throws the old group's
/// identity away rather than layering a second group over it.
///
/// **Two sources, one window.** `chat_history_begin` gives a live snapshot
/// taken when the scan started; `group_read` gives what people are still
/// saying. A finished history page (`chat_history_poll`) gives older
/// messages, which go in front of both. Every message is placed by the
/// core's own `anchor` -- never by its text, its array position or its
/// `seq` -- and a `live_anchor` on a message is an alias for the temporary
/// identity the same message had before it was written down. `Row.id` is the
/// **first** anchor this feed saw for that message, which is what a list
/// needs to be stable across the identity becoming canonical.
///
/// **What is kept is bounded**: the newest 500 messages and 4 MiB of their
/// text and identity strings (the contract's own boundary, not the process's
/// memory). Dropping a message from the front drops its aliases too, so the
/// windows behind them cannot grow with the night.
///
/// **Not drawing, not scrolling, not Markdown.** Those are later slices'.
final class ControlRoomChatFeed: ObservableObject {
    typealias D = ControlRoomChatData
    typealias H = ControlRoomChatHistory
    typealias Ctx = ControlRoomChatContext

    /// What the door answers, in this file's own spelling.
    enum Reply: Equatable {
        /// The core's own bytes.
        case answer(String)
        /// Nothing yet: the core has no reading, and nothing is drawn.
        case notReady
        /// Refused, with words worth writing down.
        case refused(String)
    }

    typealias Ask = (String) -> Reply

    /// One row: **`id` is stable**, the first core anchor this message was
    /// seen under; `message` is the canonical one and may change as the core
    /// learns the message's persisted identity.
    struct Row: Identifiable, Equatable {
        let id: String
        var message: D.Message
    }

    /// Where the first screen is. `loading` is not `empty`: a bootstrap or a
    /// history page still out is a page that has not answered yet, and a
    /// `pending` poll drawn as "nothing here" is the failure this state
    /// exists to stop.
    enum Load: Equatable {
        case idle
        /// A begin or the first history page is outstanding.
        case loading
        /// A page has answered and there are rows.
        case ready
        /// A page has answered and there are none.
        case empty
        /// The scan was cancelled before it answered. **Not empty**: a
        /// cancelled first screen has not said the group is quiet.
        case cancelled
        /// The scan ended over damaged records, or restarted its captured
        /// range, without reaching a clean end. **Not empty and not an
        /// error**: the answer is incomplete, and saying "no messages" would
        /// be a completeness claim the core did not make.
        case gap
        /// Loading has stopped at an error; the rows already drawn stay.
        case failed(String)
    }

    /// Where loading further back stands (DESIGN-v2 §4/§14; the contract's
    /// budget/at_end/gap states). Every one of these is drawn differently;
    /// an empty page that still has a resume token is `.scanning`, never
    /// "the beginning of the log".
    enum Older: Equatable {
        /// No page is out. `canLoadOlder` says whether one may be asked for.
        case idle
        /// The person asked for older messages and its begin is out.
        case loading
        /// An empty `budget` page advanced the scan; the next one is on its
        /// way without the person pressing anything.
        case scanning
        /// The scan reached the beginning of its captured range.
        case atEnd
        /// The scan stopped with records it could not read on the way, and
        /// no resume point past them. **Not `atEnd`**: nothing here says the
        /// beginning was reached.
        case gap
        /// A scan was cancelled before it answered.
        case cancelled
        /// A page could not be read; `historyTail` keeps the token so the
        /// person can ask again.
        case failed(String)
    }

    /// What the history scan last said after its page. Kept for the slice
    /// that loads further back; **this one never follows it**.
    struct HistoryTail: Equatable {
        var stop: H.Stop
        var nextToken: String?
        var restarted: Bool
        var gap: Bool
    }

    /// How often the live read looks again while the page is in front.
    static let livePeriod: TimeInterval = 2
    /// How long a `pending` history page waits before its next poll.
    static let historyPollDelay: TimeInterval = 0.2
    /// How long a live read that said `more` waits before its catch-up.
    static let catchUpDelay: TimeInterval = 0.2
    /// The window: the newest this many messages ...
    static let windowLimit = 500
    /// ... and at most this many bytes of their text and identity strings.
    static let windowBytes = 4 * 1024 * 1024
    /// The begin request's page size.
    static let historyLimit = 50
    /// How many rows on each side of the reader's own row the window keeps
    /// when it has to drop something, and how many of the newest it never
    /// drops. **Dropping the oldest is wrong while somebody reads history**:
    /// the page just asked for is the oldest one, and it would go before it
    /// was ever seen. The view tells the feed which message its viewport
    /// starts on (`reading(anchor:)`); `trim` keeps that neighbourhood and
    /// the live tail, and drops outside them.
    static let keepAboveReader = 100
    static let keepBelowReader = 100
    static let keepLiveTail = 50
    /// An empty budget page carries the scan on after this long. A delay and
    /// not a recursive call: the next page is a fresh scheduled turn.
    static let olderAdvanceDelay: TimeInterval = 0.05

    @Published private(set) var rows: [Row] = []
    @Published private(set) var state: Load = .idle
    /// A problem worth saying that is not a stopped load (a refused live
    /// read, a malformed reply): the rows already drawn stay on screen.
    @Published private(set) var trouble: String?
    /// A load stopped at an error **the person** can ask for again. The
    /// feed never takes this as permission to retry by itself: `TooLarge`
    /// keeps its token and waits, and an expired job gets one automated
    /// bootstrap per visible visit and then stops here.
    @Published private(set) var canReload = false

    /// Loading further back, drawn at the top of the list (DESIGN-v2 §4).
    @Published private(set) var older: Older = .idle

    /// The two cursors a search-located window carries (around/context).
    /// **No generic next token**: each direction has its own, and a released
    /// edge makes its token stale rather than silently crossing it.
    struct ContextTail: Equatable {
        var olderToken: String?
        var newerToken: String?
        var olderAtEnd: Bool
        var newerAtEnd: Bool
    }

    @Published private(set) var context: ContextTail?
    /// The message a search result located, for the transient highlight and
    /// the view's scroll restore.
    @Published private(set) var locatedAnchor: String?
    /// A locate is out and has not answered yet. **A different state from
    /// `locateTrouble`**: "still asking" and "the core said no" are the two
    /// things the search panel has to tell apart (DESIGN-v2 §11.3).
    @Published private(set) var locating = false
    @Published private(set) var locateTrouble: String?
    @Published private(set) var contextOlderStale = false
    @Published private(set) var contextNewerStale = false

    /// The group's own description (`chat_metadata`): the header's brief and
    /// member count. **Not a job**: the contract says this is non-blocking
    /// in-memory access, so it is asked once when the group starts and again
    /// when the header asks; nothing here schedules a retry that would make
    /// a core without the method look like a slow one.
    enum MetadataState: Equatable {
        case idle
        case loading
        case ready(ControlRoomChatMetadata.Group)
        case failed(String)
    }

    @Published private(set) var metadata: MetadataState = .idle

    /// Where the window released a run of messages, if it did. **An explicit
    /// gap, not a false neighbour**: the rows on either side of it are still
    /// what they say, but records between them are no longer held, and the
    /// header/list draws that boundary and offers `reloadClearingGap()`.
    /// `trimmedBefore` names the first kept row when records older than it
    /// went; `trimmedAfter` names the last kept row before a released run in
    /// the middle (between the reading window and the live tail).
    @Published private(set) var trimmedBefore: String?
    @Published private(set) var trimmedAfter: String?

    var hasTrimmedGap: Bool { trimmedBefore != nil || trimmedAfter != nil }

    /// The stable identity of the message the reader's viewport starts on,
    /// as the view last said. **Trim only**: it never moves the reader and
    /// nothing is drawn from it. Nil before the view has reported one, and
    /// then `trim` falls back to the oldest-first rule.
    private(set) var readingAnchor: String?
    /// How far into that message the reader was, kept with the id so a page
    /// that is shown again comes back to the same line rather than to the
    /// top of the same row.
    private(set) var readingOffset: Double = 0

    /// The position a re-displayed page restores to, if it has one.
    var savedReading: ControlRoomChatAnchor.Anchor? {
        readingAnchor.map { ControlRoomChatAnchor.Anchor(id: $0, offset: readingOffset) }
    }

    /// Whether a page older than the window can be asked for now. A page
    /// already out is not asked for again: `loadOlder` refuses while
    /// `.loading` or `.scanning`, and the list's top edge calls it on every
    /// scroll event while the reader stays there.
    var canLoadOlder: Bool {
        guard historyTail?.nextToken != nil else { return false }
        switch older {
        case .loading, .scanning: return false
        default: return true
        }
    }

    /// The messages, oldest first, without the display identity.
    var messages: [D.Message] { rows.map(\.message) }

    /// How many live aliases the window still holds. A reader for the bound
    /// test: an alias must go when its row does, or the index grows all
    /// night while the list does not.
    var aliasCount: Int { byAlias.count }
    /// The bytes the window is charging, by `cost`.
    var retainedBytes: Int { bytes }

    /// The group this feed holds; nil until it is first shown.
    private(set) var group: String?
    /// What the history scan last answered about loading further back.
    private(set) var historyTail: HistoryTail?
    /// This core run's identity, as the core named it.
    private(set) var session: String?

    /// How often the live read looks again; the tests shorten it.
    var period: TimeInterval = ControlRoomChatFeed.livePeriod

    private let ask: Ask
    private let scheduler: ControlRoomChatScheduling

    /// **Observation only** (task 2875): off unless the process says
    /// `POLTER_CHAT_TRACE=1`. At most 16 lines per feed lifetime -- never
    /// reset by a retry or a new start -- and nothing is formatted when off
    /// (`@autoclosure`, evaluated into a local before interpolating). A
    /// dedicated `Logger`, not `Ghostty.logger`: this file is Foundation and
    /// must not name the app's namespace. Fields are group, generation and a
    /// state word; never ids, tokens, bodies or replies.
    private static let traceOn =
        ProcessInfo.processInfo.environment["POLTER_CHAT_TRACE"] == "1"
    private static let traceLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-trace"
    )
    private var traced = 0

    private func trace(_ what: @autoclosure () -> String) {
        guard Self.traceOn, traced < 16 else { return }
        let line = what()
        traced += 1
        Self.traceLog.notice("\(line, privacy: .public)")
    }
    /// This feed's parsed Markdown, with its own lifetime and generation
    /// (task 2800 C2b-1). It is handed values only; the page reads documents
    /// out of it and never parses in `body`.
    let markdown: ControlRoomChatMarkdownStore

    /// **The page's lifecycle generation.** A row carries the one it first
    /// appeared under; `stop`, a new session and a group change each move it,
    /// which is how a release from the page before this one is ignored.
    @Published private(set) var generation: UInt64 = 0
    private var liveNext: UInt64 = 0
    private var bootstrapID: String?
    private var jobID: String?
    /// **The begin answering is not the first screen being read.** A begin
    /// snapshot can fill rows while its history page is still pending or has
    /// been cancelled; resuming such a page on return would leave
    /// `historyTail` nil and never ask for the older records again. This is
    /// true only once a history page has settled the first screen.
    private(set) var firstScreenReady = false
    /// The continuation scan's own job, begin id and resume token. It is a
    /// separate job from the bootstrap's: older pages can be asked for while
    /// the live read keeps running, and one must not cancel the other.
    private var olderJobID: String?
    private var olderRequestID: String?
    private var olderToken: String?
    /// Whether the page out now was asked for by a person or by the scan
    /// continuing through an empty budget page. Only the drawing differs.
    private var olderAutomatic = false
    private var started = false
    private var bootstrapped = false
    /// A bootstrap whose snapshot must **replace** the body rather than
    /// merge into it: the session changed, so the old rows are another
    /// run's messages. They stay on screen until that snapshot is valid.
    private var replacing = false
    /// One rebootstrap is allowed after `Expired`/`NoSuchJob`; a second stop
    /// is manual.
    private var reloadedOnce = false

    private var liveToken: UUID?
    private var pollToken: UUID?
    private var catchUpToken: UUID?
    /// The continuation scan's poll and its retry after `notReady`.
    private var olderPollToken: UUID?
    private var olderRetryToken: UUID?
    /// An empty `budget` page's next begin is **scheduled**, never called
    /// from inside the handler that read the page: a long quiet range would
    /// otherwise be one unbroken recursion on the page's thread.
    private var olderAdvanceToken: UUID?
    /// The locate job: around first, then one context page at a time.
    private var locateJobID: String?
    private var locateRequestID: String?
    private var locateAnchor: String?
    private var locateLocation: String?
    private var locatePollToken: UUID?
    private var locateRetryToken: UUID?

    private var byAnchor: [String: String] = [:]
    private var byAlias: [String: String] = [:]
    private var aliasesOf: [String: Set<String>] = [:]
    private var bytes = 0

    /// `@escaping` because the door outlives the call that hands it in.
    init(
        ask: @escaping Ask,
        scheduler: ControlRoomChatScheduling = ControlRoomChatTimerScheduler(),
        markdown: ControlRoomChatMarkdownStore = ControlRoomChatMarkdownStore()
    ) {
        self.ask = ask
        self.scheduler = scheduler
        self.markdown = markdown
    }

    deinit {
        // Nothing keeps asking once the container has dropped the feed.
        if let liveToken { scheduler.cancel(liveToken) }
        if let pollToken { scheduler.cancel(pollToken) }
        if let catchUpToken { scheduler.cancel(catchUpToken) }
        if let olderPollToken { scheduler.cancel(olderPollToken) }
        if let olderRetryToken { scheduler.cancel(olderRetryToken) }
        cancelJob()
    }

    // MARK: - The page's two moments

    /// The page is in front, on `group`. **The same group already running is
    /// not started again**: a repeated `start` must not make a second job or
    /// a second timer.
    func start(group: String) {
        if self.group == group, started { return }
        if self.group != group {
            leaveGroup()
            self.group = group
        }
        started = true
        generation += 1
        trace("start group=\(group) gen=\(generation)")
        reloadedOnce = false
        // **Coming back is not a first screen.** A page with a body, a known
        // session and a bootstrap already answered keeps its reading window,
        // its anchor and its released-run markers; a fresh bootstrap would
        // merge the newest history page in front of older rows it does not
        // follow from (reversed order and a false neighbour). What is
        // resumed is the live read from `liveNext`; a core that restarted is
        // caught by its session in `handleLive`, which replaces the body in
        // one step.
        if firstScreenReady, bootstrapped, !rows.isEmpty, session != nil {
            requestMetadata(clear: false)
            // A located window is a history reading position: new messages
            // do not append themselves to it. Returning to latest restarts.
            if locatedAnchor == nil { armLive() }
            armOlderAfterResume()
            return
        }
        // A bootstrap is the first screen again; the older scan it may have
        // been in the middle of is another lifecycle's, and its token is not
        // this scan's.
        older = .idle
        olderAutomatic = false
        historyTail = nil
        syncMarkdown()
        requestMetadata(clear: true)
        startBootstrap()
    }

    /// On resume, a page the person had started is no longer out; the top
    /// edge may ask again from the token `historyTail` still holds.
    private func armOlderAfterResume() {
        if older == .loading || older == .scanning { older = .cancelled }
        olderAutomatic = false
        syncMarkdown()
    }

    /// The page is out of sight. **Unconditional**: the scheduler is cleared
    /// and a known job is cancelled even when no timer was outstanding, and
    /// every answer from before this moment is dropped by its generation.
    /// The rows stay, so coming back shows what was there.
    func stop() {
        let wasStarted = started
        started = false
        generation += 1
        if wasStarted { trace("stop group=\(self.group ?? "-") gen=\(generation)") }
        cancelScheduling()
        cancelJob()
        // A page that was out is not out any more, and no answer will come:
        // the top edge says it was cancelled rather than spinning.
        if older == .loading || older == .scanning { older = .cancelled }
        syncMarkdown()
    }

    /// The person asked a stopped load to try again.
    func reload() {
        restartLoad(clearingGap: false)
    }

    /// The window released a run of records and the person asked to read
    /// them again. **This is the only recovery a host can offer without a
    /// forward history cursor**: the body is started again from the newest
    /// records, so the two sides of the released run cannot lie next to each
    /// other any more. The list draws the gap boundary with this action.
    func reloadClearingGap() {
        restartLoad(clearingGap: true)
    }

    private func restartLoad(clearingGap: Bool) {
        guard started else { return }
        generation += 1
        cancelScheduling()
        cancelJob()
        if clearingGap { clearWindow() }
        // **`session` is kept** so that the new begin can tell a retry of the
        // same run (merge the snapshot) from a new run (replace the body).
        liveNext = 0
        bootstrapped = false
        firstScreenReady = false
        reloadedOnce = false
        canReload = false
        trouble = nil
        older = .idle
        olderAutomatic = false
        historyTail = nil
        context = nil
        locatedAnchor = nil
        locateTrouble = nil
        locating = false
        contextOlderStale = false
        contextNewerStale = false
        state = .loading
        syncMarkdown()
        requestMetadata(clear: false)
        startBootstrap()
    }

    // MARK: - The group's own description

    /// Ask again when the header opens its member list. An answer already
    /// ready stays on screen until the new one arrives; a failure does not
    /// erase it either.
    func refreshMetadata() {
        requestMetadata(clear: false)
    }

    private func requestMetadata(clear: Bool) {
        guard started, let group else { return }
        if clear { metadata = .loading }
        let generation = self.generation
        let request = ControlRoomChatRequest.metadata(group: group)
        switch ask(request) {
        case .notReady:
            // A core that does not know the method yet is not an error the
            // header should shout about; the snapshot's own row still names
            // the group.
            if case .loading = metadata { metadata = .idle }
        case let .refused(why):
            metadata = .failed(why)
        case let .answer(text):
            guard generation == self.generation, self.group == group else { return }
            guard let outcome = ControlRoomChatMetadata.decode(text) else {
                metadata = .failed("malformed metadata reply")
                return
            }
            switch outcome {
            case let .ready(facts):
                guard facts.group == group else {
                    metadata = .failed("BadParams")
                    return
                }
                metadata = .ready(facts)
            case let .failed(code):
                metadata = .failed(code)
            }
        }
    }

    // MARK: - Bootstrap

    private func leaveGroup() {
        generation += 1
        started = false
        cancelScheduling()
        cancelJob()
        session = nil
        liveNext = 0
        bootstrapID = nil
        bootstrapped = false
        firstScreenReady = false
        replacing = false
        reloadedOnce = false
        rows = []
        byAnchor = [:]
        byAlias = [:]
        aliasesOf = [:]
        bytes = 0
        readingAnchor = nil
        readingOffset = 0
        trimmedBefore = nil
        trimmedAfter = nil
        historyTail = nil
        older = .idle
        olderAutomatic = false
        metadata = .idle
        context = nil
        locatedAnchor = nil
        locateTrouble = nil
        locating = false
        contextOlderStale = false
        contextNewerStale = false
        state = .idle
        trouble = nil
        canReload = false
        syncMarkdown()
    }

    /// A fresh bootstrap: new `request_id`, `limit` 50 and no resume token.
    /// A retry of the same begin reuses the id and parameters.
    private func startBootstrap() {
        bootstrapID = ControlRoomChatRequest.newRequestID()
        bootstrapped = false
        firstScreenReady = false
        canReload = false
        state = .loading
        sendBegin()
    }

    private func sendBegin() {
        guard started, let group, let id = bootstrapID else { return }
        let generation = self.generation
        guard let request = try? ControlRoomChatRequest.begin(
            group: group, requestID: id, limit: Self.historyLimit
        ) else {
            stopWithError("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            trace("begin group=\(group) gen=\(generation) notReady")
            retryBegin(after: period, generation: generation)
        case let .refused(why):
            trace("begin group=\(group) gen=\(generation) refused")
            stopWithError(why)
        case let .answer(text):
            trace("begin group=\(group) gen=\(generation) answer")
            handleBegin(text, generation: generation)
        }
    }

    private func retryBegin(after delay: TimeInterval, generation: UInt64) {
        guard pollToken == nil else { return }
        pollToken = scheduler.after(delay) { [weak self] in
            self?.pollToken = nil
            guard let self, self.generation == generation else { return }
            self.sendBegin()
        }
    }

    private func handleBegin(_ text: String, generation: UInt64) {
        guard let outcome = H.decodeBegin(text) else {
            guard generation == self.generation else { return }
            trace("decode group=\(self.group ?? "-") gen=\(generation) malformed")
            stopWithError("malformed begin reply")
            return
        }
        let accepted = generation == self.generation
        switch outcome {
        case let .failed(failure):
            guard accepted else { return }
            trace("decode group=\(self.group ?? "-") gen=\(generation) rejected")
            switch failure.error {
            case "Busy":
                // The same request, next tick: a new id would be a new scan.
                retryBegin(after: Self.historyPollDelay, generation: generation)
            case "Expired", "NoSuchJob":
                if !rebootstrapOnce(generation: generation) {
                    stopWithError(failure.error)
                }
            default:
                stopWithError(failure.error)
            }

        case let .started(page):
            let matched = page.group == group
            trace("decode group=\(self.group ?? "-") gen=\(generation) started match=\(matched ? "yes" : "no")")
            // **A scan the page did not wait for must not keep running.**
            // The reply named a real job; whether it is stale, for another
            // group, or from a page generation that is gone, cancel it
            // unless it is a job this feed already holds.
            guard accepted, matched else {
                cancelUnaccepted(page.jobID)
                return
            }
            if let session, session != page.session {
                // The run changed under us: the old rows are another run's
                // identities. Replace them only once this snapshot is here.
                replacing = true
            }
            if replacing {
                clearWindow()
            }
            replacing = false
            session = page.session
            liveNext = page.liveSince
            jobID = page.jobID
            historyTail = nil
            older = .idle
            bootstrapped = true
            // `reloadedOnce` is **not** reset here: one automated
            // rebootstrap is the budget, and a begin that succeeds after
            // one round must not buy another for ever.
            canReload = false
            trouble = nil
            for message in page.liveSnapshot {
                if !absorb(message) { break }
            }
            syncMarkdown()
            if case .failed = state { return }
            // **Still loading**: the begin is a snapshot, not the older page
            // that answers what came before it. A pending history poll is
            // not an empty chat.
            state = .loading
            armLive()
            schedulePoll(generation: generation)
        }
    }

    /// `Expired`/`NoSuchJob` while a load is running: one fresh bootstrap,
    /// then stop for the person.
    private func rebootstrapOnce(generation: UInt64) -> Bool {
        guard !reloadedOnce else { return false }
        reloadedOnce = true
        cancelScheduling()
        jobID = nil
        liveNext = 0
        bootstrapped = false
        state = .loading
        startBootstrap()
        return true
    }

    // MARK: - Live

    private func armLive() {
        guard started, liveToken == nil else { return }
        if case .failed = state { return }
        liveToken = scheduler.after(period) { [weak self] in
            self?.liveToken = nil
            self?.live()
        }
    }

    private func live() {
        guard started, let group, session != nil else { return }
        let generation = self.generation
        let request = ControlRoomChatRequest.live(group: group, since: liveNext)
        switch ask(request) {
        case .notReady:
            // The core is briefly away: the rows stay, and the next visible
            // tick asks again.
            break
        case let .refused(why):
            trouble = why
        case let .answer(text):
            handleLive(text, generation: generation)
        }
        armLive()
    }

    private func handleLive(_ text: String, generation: UInt64) {
        guard generation == self.generation, let group else { return }
        guard let batch = Self.decode(text) else {
            trouble = "malformed live reply"
            return
        }
        guard batch.group == group else { return }
        if let session, batch.session != session {
            sessionChanged()
            return
        }
        if session == nil { session = batch.session }
        for message in batch.messages {
            if !absorb(message) { break }
        }
        let advanced = batch.next > liveNext
        if advanced { liveNext = batch.next }
        if batch.more {
            if advanced {
                scheduleCatchUp(generation: generation)
            } else {
                // Asking again would be asking the same question for ever.
                trouble = "the live read stopped advancing"
            }
        } else {
            trouble = nil
        }
        syncMarkdown()
    }

    private func scheduleCatchUp(generation: UInt64) {
        guard catchUpToken == nil else { return }
        catchUpToken = scheduler.after(Self.catchUpDelay) { [weak self] in
            self?.catchUpToken = nil
            guard let self, self.generation == generation else { return }
            self.live()
        }
    }

    /// The core started a new run: the old job, water mark and temporary
    /// identities are another run's. The body stays until the new snapshot
    /// arrives, then replaces it in one step.
    private func sessionChanged() {
        generation += 1
        cancelScheduling()
        cancelJob()
        // The rows stay on screen until the new snapshot replaces them, but
        // every answer already being parsed for the old run is stale now.
        syncMarkdown()
        session = nil
        liveNext = 0
        bootstrapped = false
        firstScreenReady = false
        // **Not `reloadedOnce`**: that budget belongs to one visible
        // lifecycle, and a core that keeps restarting must not buy a fresh
        // automated bootstrap with every session.
        replacing = true
        older = .idle
        olderAutomatic = false
        historyTail = nil
        context = nil
        locatedAnchor = nil
        locateTrouble = nil
        locating = false
        contextOlderStale = false
        contextNewerStale = false
        state = .loading
        trouble = nil
        requestMetadata(clear: true)
        startBootstrap()
    }

    // MARK: - History

    private func schedulePoll(generation: UInt64) {
        guard pollToken == nil, jobID != nil, started else { return }
        pollToken = scheduler.after(Self.historyPollDelay) { [weak self] in
            self?.pollToken = nil
            guard let self, self.generation == generation else { return }
            self.pollHistory(generation: generation)
        }
    }

    /// One poll, one request. A `pending` reply arranges the next one; it
    /// never calls itself, so a scan that is slow cannot take the page's
    /// thread and never returns.
    private func pollHistory(generation: UInt64) {
        guard generation == self.generation, started,
              let group, let jobID
        else { return }
        guard let request = try? ControlRoomChatRequest.poll(jobID: jobID) else {
            stopWithError("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            trace("poll group=\(group) gen=\(generation) notReady")
            schedulePoll(generation: generation)
        case let .refused(why):
            trace("poll group=\(group) gen=\(generation) refused")
            // No retry: the request itself was refused, and asking it again
            // would be the same refusal. The rows already drawn stay.
            trouble = why
            self.jobID = nil
            canReload = true
            if rows.isEmpty { state = .failed(why) } else { state = .ready }
        case let .answer(text):
            trace("poll group=\(group) gen=\(generation) answer")
            handlePoll(text, jobID: jobID, generation: generation, group: group)
        }
    }

    private func handlePoll(_ text: String, jobID: String, generation: UInt64, group: String) {
        guard let outcome = H.decodePoll(text) else {
            guard generation == self.generation else { return }
            trace("poll-decode group=\(group) gen=\(generation) malformed")
            stopWithError("malformed history reply")
            return
        }
        switch outcome {
        case .pending:
            guard generation == self.generation else { return }
            trace("poll-decode group=\(group) gen=\(generation) pending")
            schedulePoll(generation: generation)

        case .cancelled:
            guard generation == self.generation else { return }
            trace("poll-decode group=\(group) gen=\(generation) cancelled")
            self.jobID = nil
            // A cancelled scan is not a page and not an answer about the
            // history; it must not leave the page saying it is still
            // loading for ever, and it must not say the group is empty.
            state = rows.isEmpty ? .cancelled : .ready
            // Nothing was learned about the group; the person may ask again.
            canReload = rows.isEmpty

        case let .ready(page):
            let matched = page.jobID == jobID && page.group == group
                && (session == nil || page.session == session)
            trace("poll-decode group=\(group) gen=\(generation) ready match=\(matched ? "yes" : "no")")
            guard generation == self.generation, page.jobID == jobID, page.group == group,
                  session == nil || page.session == session
            else {
                // A page this window will not draw may name a scan nobody
                // else will poll; stop it unless it is one we hold.
                cancelUnaccepted(page.jobID)
                return
            }
            if session == nil { session = page.session }
            mergeHistory(page.messages)
            historyTail = HistoryTail(
                stop: page.stop,
                nextToken: page.nextToken,
                restarted: page.restarted,
                gap: page.gap
            )
            self.jobID = nil
            canReload = false
            trouble = nil
            // **An empty `budget` page is progress, not the beginning**
            // (contract §"Ready"): the scan used its 2 MiB without finding a
            // record and named where to carry on. Asking again from that
            // token is what reads the first screen at all for a large log
            // whose recent range is quiet.
            if page.messages.isEmpty, page.stop == .budget, let token = page.nextToken {
                if rows.isEmpty {
                    state = .loading
                } else if case .loading = state {
                    state = .ready
                }
                scheduleOlderAdvance(token: token, generation: generation)
                return
            }
            settleOlder(page)
            settleFirstScreen(page)
            firstScreenReady = true

        case let .failed(failure):
            let isExpired = failure.error == "Expired" || failure.error == "NoSuchJob"
            trace("poll-decode group=\(group) gen=\(generation) \(isExpired ? "expired" : "failed")")
            guard generation == self.generation else {
                if let named = failure.jobID { cancelUnaccepted(named) }
                return
            }
            if let named = failure.jobID, named != jobID {
                cancelUnaccepted(named)
                return
            }
            switch failure.error {
            case "Expired", "NoSuchJob":
                if !rebootstrapOnce(generation: generation) {
                    stopWithError(failure.error)
                }
            case "TooLarge":
                // Keep the token the core named, and **do not** go round
                // again on it: a bigger page is a later slice's question.
                historyTail = nil
                self.jobID = nil
                stopWithError(failure.error)
            case "Busy":
                schedulePoll(generation: generation)
            default:
                self.jobID = nil
                stopWithError(failure.error)
            }
        }
    }

    // MARK: - Loading older pages

    /// The view is looking at `id` at its top edge. Told on every scroll that
    /// moves it; the only reader is `trim`.
    func reading(anchor id: String?, offset: Double = 0) {
        readingAnchor = id
        readingOffset = offset
    }

    /// The person asked for what came before the window (DESIGN-v2 §4: the
    /// top edge's own request). A page already out is not asked for again.
    func loadOlder() {
        guard started, group != nil, let token = historyTail?.nextToken else { return }
        switch older {
        case .loading, .scanning: return
        default: break
        }
        beginContinuation(token: token, automatic: false)
    }

    /// The person stopped the scan that is out. The token it was reading from
    /// stays in `historyTail`, so "continue loading" resumes rather than
    /// starting over.
    func cancelOlder() {
        switch older {
        case .loading, .scanning: break
        default: return
        }
        cancelOlderJob()
        olderRequestID = nil
        olderToken = nil
        older = .cancelled
        if case .loading = state {
            state = rows.isEmpty ? .cancelled : .ready
        }
    }

    /// Start one continuation page from `token`. `automatic` is an empty
    /// `budget` page carrying the scan on; the drawing says "scanning"
    /// instead of "loading", but the request is the same one.
    private func beginContinuation(token: String, automatic: Bool) {
        guard started, group != nil, historyTail?.nextToken == token else { return }
        olderAutomatic = automatic
        olderRequestID = ControlRoomChatRequest.newRequestID()
        olderToken = token
        olderJobID = nil
        older = automatic ? .scanning : .loading
        sendContinuationBegin()
    }

    private func sendContinuationBegin() {
        guard started, let group, let requestID = olderRequestID,
              let token = olderToken
        else { return }
        let generation = self.generation
        guard let request = try? ControlRoomChatRequest.begin(
            group: group, requestID: requestID, limit: Self.historyLimit, resumeToken: token
        ) else {
            failOlder("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            trace("older-begin group=\(group) gen=\(generation) notReady")
            retryContinuationBegin(after: period, generation: generation)
        case let .refused(why):
            trace("older-begin group=\(group) gen=\(generation) refused")
            failOlder(why)
        case let .answer(text):
            handleContinuationBegin(text, requestID: requestID, generation: generation)
        }
    }

    /// The same `request_id` again: a `Busy` begin is the same question, not
    /// a new scan (the core answers the original reply for a repeated id).
    private func retryContinuationBegin(after delay: TimeInterval, generation: UInt64) {
        guard olderRetryToken == nil else { return }
        olderRetryToken = scheduler.after(delay) { [weak self] in
            self?.olderRetryToken = nil
            guard let self, self.generation == generation else { return }
            self.sendContinuationBegin()
        }
    }

    /// A late answer is reclaimed by both its generation and its request id:
    /// a stop or a cancelled scan leaves no `olderRequestID`, and a newer
    /// page's answer must not be taken for the one that was outstanding.
    ///
    /// **Reclaiming the reply is not enough**: a begin that decoded to a
    /// real `job_id` started a scan on the core, and an answer this feed
    /// will not adopt leaves nobody to poll or cancel it. So an unaccepted
    /// started reply is cancelled best-effort -- unless its id is a job this
    /// feed already holds (then it is not unaccepted, it is in use).
    private func handleContinuationBegin(
        _ text: String,
        requestID: String,
        generation: UInt64
    ) {
        let accepted = generation == self.generation && olderRequestID == requestID
        guard let outcome = H.decodeBegin(text) else {
            guard accepted else { return }
            failOlder("malformed begin reply")
            return
        }
        switch outcome {
        case let .failed(failure):
            guard accepted else { return }
            switch failure.error {
            case "Busy":
                retryContinuationBegin(after: Self.historyPollDelay, generation: generation)
            default:
                failOlder(failure.error)
            }
        case let .started(page):
            guard accepted else {
                cancelUnaccepted(page.jobID)
                return
            }
            guard page.group == group else {
                cancelUnaccepted(page.jobID)
                failOlder("BadParams")
                return
            }
            // A page from another core run is not this window's history
            // (contract: anchors name one session). The live read will
            // rebuild; do not merge it here, and do not leave its scan
            // running.
            guard session == nil || page.session == session else {
                cancelUnaccepted(page.jobID)
                failOlder("Expired")
                return
            }
            if session == nil { session = page.session }
            olderJobID = page.jobID
            // The begin has answered: a second copy of the same reply has
            // no outstanding request to answer any more.
            olderRequestID = nil
            scheduleContinuationPoll(generation: generation)
        }
    }

    private func scheduleContinuationPoll(generation: UInt64) {
        guard olderPollToken == nil, olderJobID != nil, started else { return }
        olderPollToken = scheduler.after(Self.historyPollDelay) { [weak self] in
            self?.olderPollToken = nil
            guard let self, self.generation == generation else { return }
            self.pollContinuation(generation: generation)
        }
    }

    private func pollContinuation(generation: UInt64) {
        guard generation == self.generation, started,
              let group, let olderJobID
        else { return }
        guard let request = try? ControlRoomChatRequest.poll(jobID: olderJobID) else {
            failOlder("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            trace("older-poll group=\(group) gen=\(generation) notReady")
            scheduleContinuationPoll(generation: generation)
        case let .refused(why):
            trace("older-poll group=\(group) gen=\(generation) refused")
            failOlder(why)
        case let .answer(text):
            handleContinuationPoll(text, jobID: olderJobID, generation: generation, group: group)
        }
    }

    private func handleContinuationPoll(
        _ text: String,
        jobID: String,
        generation: UInt64,
        group: String
    ) {
        guard let outcome = H.decodePoll(text) else {
            guard generation == self.generation else { return }
            failOlder("malformed history reply")
            return
        }
        switch outcome {
        case .pending:
            guard generation == self.generation else { return }
            scheduleContinuationPoll(generation: generation)
        case .cancelled:
            guard generation == self.generation else { return }
            self.olderJobID = nil
            older = .cancelled
            if case .loading = state { state = rows.isEmpty ? .cancelled : .ready }
        case let .ready(page):
            guard generation == self.generation, page.jobID == jobID, page.group == group,
                  session == nil || page.session == session
            else {
                cancelUnaccepted(page.jobID)
                return
            }
            if session == nil { session = page.session }
            mergeHistory(page.messages)
            historyTail = HistoryTail(
                stop: page.stop,
                nextToken: page.nextToken,
                restarted: page.restarted,
                gap: page.gap
            )
            self.olderJobID = nil
            trouble = nil
            // **An empty budget page is progress.** The contract says so in
            // one line, and this is the host half of it: continue from the
            // token it named, but never from the token already used -- that
            // would scan the same range for ever and look like a slow disk.
            if page.messages.isEmpty, page.stop == .budget, let next = page.nextToken {
                guard next != olderToken else {
                    failOlder("the history scan stopped advancing")
                    return
                }
                scheduleOlderAdvance(token: next, generation: generation)
                return
            }
            settleOlder(page)
            olderToken = nil
            if case .loading = state {
                settleFirstScreen(page)
                firstScreenReady = true
            }
        case let .failed(failure):
            guard generation == self.generation else {
                if let named = failure.jobID { cancelUnaccepted(named) }
                return
            }
            if let named = failure.jobID, named != jobID {
                cancelUnaccepted(named)
                return
            }
            switch failure.error {
            case "Busy":
                scheduleContinuationPoll(generation: generation)
            default:
                failOlder(failure.error)
            }
        }
    }

    /// The state `page` leaves the older loader in. **Completeness is not
    /// `stop == atEnd` alone**: the contract says only `at_end && !gap &&
    /// !restarted` is complete. A page that says `at_end` over damaged
    /// records, or after its captured range restarted, is a gap -- it must
    /// not draw "已到最早记录" and it must not draw an empty chat.
    private func settleOlder(_ page: H.Ready) {
        if page.gap || page.restarted {
            older = page.nextToken == nil ? .gap : .idle
            return
        }
        if page.stop == .atEnd {
            older = .atEnd
        } else if page.nextToken == nil {
            older = .gap
        } else {
            older = .idle
        }
    }

    /// What the first screen's answer may say. `empty` is a completeness
    /// claim and is made only for a clean end; anything else answered with
    /// no rows is `.gap`.
    private func settleFirstScreen(_ page: H.Ready) {
        if rows.isEmpty {
            state = Self.complete(page) ? .empty : .gap
        } else {
            state = .ready
        }
    }

    private static func complete(_ page: H.Ready) -> Bool {
        page.stop == .atEnd && !page.gap && !page.restarted
    }

    /// Carry an empty `budget` page on from `token`, **after this turn**.
    /// One scheduled look per page, never a call from inside the handler
    /// that read the last one.
    private func scheduleOlderAdvance(token: String, generation: UInt64) {
        guard olderAdvanceToken == nil, started else { return }
        older = .scanning
        olderAdvanceToken = scheduler.after(Self.olderAdvanceDelay) { [weak self] in
            self?.olderAdvanceToken = nil
            guard let self, self.generation == generation else { return }
            self.beginContinuation(token: token, automatic: true)
        }
    }

    /// A page that could not be read. The resume token stays in
    /// `historyTail`, so the person's "try again" asks for the same range
    /// rather than starting over.
    private func failOlder(_ why: String) {
        olderJobID = nil
        olderRequestID = nil
        olderToken = nil
        older = .failed(why)
        if case .loading = state {
            state = rows.isEmpty ? .failed(why) : .ready
            canReload = true
        }
    }

    /// A reply named a job this feed will not adopt. **Cancel it, unless the
    /// id is one the feed is already holding**: that id is in use, and a
    /// cancel here would stop the page we are waiting for.
    private func cancelUnaccepted(_ jobID: String) {
        guard jobID != self.jobID, jobID != olderJobID else { return }
        guard let request = try? ControlRoomChatRequest.cancel(jobID: jobID) else { return }
        _ = ask(request)
    }

    /// Best effort, once: a continuation job nobody will read is still a job
    /// scanning the disk.
    private func cancelOlderJob() {
        if let olderPollToken { scheduler.cancel(olderPollToken) }
        if let olderRetryToken { scheduler.cancel(olderRetryToken) }
        if let olderAdvanceToken { scheduler.cancel(olderAdvanceToken) }
        if let locatePollToken { scheduler.cancel(locatePollToken) }
        if let locateRetryToken { scheduler.cancel(locateRetryToken) }
        olderPollToken = nil
        olderRetryToken = nil
        olderAdvanceToken = nil
        guard let olderJobID else { return }
        self.olderJobID = nil
        guard let request = try? ControlRoomChatRequest.cancel(jobID: olderJobID) else { return }
        _ = ask(request)
    }

    private func stopWithError(_ why: String) {
        trouble = why
        state = .failed(why)
        canReload = true
        cancelScheduling()
    }

    // MARK: - Search locate (around and context)

    /// Locate a search result's **original conversation**, not a filtered
    /// list: around the exact anchor, with both directions' cursors. The
    /// target is read directly (never by paging history until it is found).
    /// The slot is closed or a new search begins: **a refusal about the
    /// last result is not a word about this one**. The highlighted row and
    /// its window stay -- only the notice goes.
    func clearLocateNotice() {
        if !locating { locateTrouble = nil }
    }

    func locate(anchor: String, location: String?) {
        guard started, let group else { return }
        cancelJob()
        cancelScheduling()
        generation &+= 1
        locateTrouble = nil
        locating = true
        locatedAnchor = anchor
        context = nil
        contextOlderStale = false
        contextNewerStale = false
        locateRequestID = ControlRoomChatRequest.newRequestID()
        locateJobID = nil
        sendLocateBegin(group: group, anchor: anchor, location: location)
    }

    /// The window's edge was released: re-anchor around the retained edge
    /// rather than following a token that would cross the released run.
    func reanchorOlder() {
        guard let edge = rows.first?.id else { return }
        locate(anchor: edge, location: nil)
    }

    func reanchorNewer() {
        guard let edge = rows.last?.id else { return }
        locate(anchor: edge, location: nil)
    }

    /// Back to the newest conversation: a fresh first screen, with the
    /// located highlight and both cursors gone.
    func returnToLatest() {
        locatedAnchor = nil
        context = nil
        contextOlderStale = false
        contextNewerStale = false
        locateTrouble = nil
        locating = false
        restartLoad(clearingGap: true)
    }

    func loadContextOlder() {
        guard let context, let token = context.olderToken,
              !context.olderAtEnd, !contextOlderStale,
              locateJobID == nil, started, let group
        else { return }
        contextOlderStale = false
        sendContextBegin(group: group, token: token, direction: .older)
    }

    func loadContextNewer() {
        guard let context, let token = context.newerToken,
              !context.newerAtEnd, !contextNewerStale,
              locateJobID == nil, started, let group
        else { return }
        contextNewerStale = false
        sendContextBegin(group: group, token: token, direction: .newer)
    }

    private func sendLocateBegin(group: String, anchor: String, location: String?) {
        guard let requestID = locateRequestID else { return }
        locateAnchor = anchor
        locateLocation = location
        let generation = self.generation
        guard let request = try? ControlRoomChatRequest.aroundBegin(
            group: group, requestID: requestID, anchor: anchor, location: location
        ) else {
            failLocate("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            scheduleLocateRetry(after: period, generation: generation) { [weak self] in
                self?.sendLocateBegin(group: group, anchor: anchor, location: location)
            }
        case let .refused(why):
            failLocate(why)
        case let .answer(text):
            handleLocateBegin(text, requestID: requestID, generation: generation)
        }
    }

    private func scheduleLocateRetry(
        after delay: TimeInterval,
        generation: UInt64,
        _ work: @escaping () -> Void
    ) {
        guard locateRetryToken == nil else { return }
        locateRetryToken = scheduler.after(delay) { [weak self] in
            self?.locateRetryToken = nil
            guard let self, self.generation == generation else { return }
            work()
        }
    }

    private func handleLocateBegin(_ text: String, requestID: String, generation: UInt64) {
        let accepted = generation == self.generation && locateRequestID == requestID
        guard let outcome = Ctx.decodeBegin(text) else {
            if accepted { failLocate("malformed locate reply") }
            return
        }
        switch outcome {
        case let .failed(failure):
            guard accepted else { return }
            if failure.error == "Busy" {
                scheduleLocateRetry(after: Self.historyPollDelay, generation: generation) {
                    [weak self] in
                    guard let self, let group = self.group,
                          let anchor = self.locateAnchor
                    else { return }
                    self.sendLocateBegin(
                        group: group, anchor: anchor, location: self.locateLocation
                    )
                }
            } else {
                failLocate(failure.error)
            }
        case let .started(status):
            guard accepted else {
                cancelLocateUnaccepted(status.jobID)
                return
            }
            guard status.group == group, session == nil || status.session == session else {
                cancelLocateUnaccepted(status.jobID)
                failLocate("CursorMismatch")
                return
            }
            session = status.session
            locateJobID = status.jobID
            locateRequestID = nil
            scheduleLocatePoll(generation: generation)
        }
    }

    private func scheduleLocatePoll(generation: UInt64) {
        guard locatePollToken == nil, locateJobID != nil, started else { return }
        locatePollToken = scheduler.after(Self.historyPollDelay) { [weak self] in
            self?.locatePollToken = nil
            guard let self, self.generation == generation,
                  let jobID = self.locateJobID
            else { return }
            self.pollLocate(jobID: jobID, generation: generation)
        }
    }

    private func pollLocate(jobID: String, generation: UInt64) {
        guard let request = try? ControlRoomChatRequest.poll(jobID: jobID) else {
            failLocate("BadParams")
            return
        }
        switch ask(request) {
        case .notReady:
            scheduleLocatePoll(generation: generation)
        case let .refused(why):
            failLocate(why)
        case let .answer(text):
            handleLocatePoll(text, jobID: jobID, generation: generation)
        }
    }

    private func handleLocatePoll(_ text: String, jobID: String, generation: UInt64) {
        guard generation == self.generation else { return }
        // **A reply that is not a poll answer ends this locate** rather than
        // stopping the loop without a word: the old `else { return }` left
        // `locating` true for ever and no poll scheduled, which the panel
        // can only draw as "still looking" (task 2982, review M2).
        guard let outcome = Ctx.decodePoll(text) else {
            failLocate("malformed locate reply")
            return
        }
        switch outcome {
        case let .pending(status):
            guard status.jobID == jobID, status.group == group,
                  session == nil || status.session == session
            else { scheduleLocatePoll(generation: generation); return }
            scheduleLocatePoll(generation: generation)
        case let .cancelled(status):
            guard status.jobID == jobID, status.group == group else {
                failLocate("CursorMismatch")
                return
            }
            failLocate("Cancelled")
        case let .failed(failure):
            failLocate(failure.error)
        case let .around(around):
            guard around.page.jobID == jobID, around.page.group == group,
                  session == nil || around.page.session == session
            else {
                failLocate("CursorMismatch")
                return
            }
            if session == nil { session = around.page.session }
            // **The anchor is published before the rows**, so the list's
            // rows-change handler can see that this replacement is a locate
            // and must not follow the bottom.
            locatedAnchor = around.target?.anchor
            replaceWindow(around.page.messages)
            context = ContextTail(
                olderToken: around.page.olderToken,
                newerToken: around.page.newerToken,
                olderAtEnd: around.page.olderAtEnd,
                newerAtEnd: around.page.newerAtEnd
            )
            older = .idle
            historyTail = nil
            firstScreenReady = true
            locateJobID = nil
            locateTrouble = nil
            locating = false
            state = rows.isEmpty ? .empty : .ready
            if let locatedAnchor {
                reading(anchor: locatedAnchor, offset: 0)
            }
        case let .context(page):
            handleContext(page, jobID: jobID)
        }
    }

    private func sendContextBegin(
        group: String, token: String, direction: ControlRoomChatContext.Direction
    ) {
        locateRequestID = ControlRoomChatRequest.newRequestID()
        locateJobID = nil
        let generation = self.generation
        guard let requestID = locateRequestID,
              let request = try? ControlRoomChatRequest.contextBegin(
                group: group, requestID: requestID, resumeToken: token
              )
        else {
            failLocate("BadParams")
            return
        }
        pendingContextDirection = direction
        pendingContextToken = token
        switch ask(request) {
        case .notReady:
            scheduleLocateRetry(after: period, generation: generation) { [weak self] in
                self?.sendContextBegin(group: group, token: token, direction: direction)
            }
        case let .refused(why):
            failLocate(why)
        case let .answer(text):
            handleContextBegin(text, generation: generation, direction: direction)
        }
    }

    private var pendingContextDirection: ControlRoomChatContext.Direction?
    private var pendingContextToken: String?

    private func handleContextBegin(
        _ text: String, generation: UInt64, direction: ControlRoomChatContext.Direction
    ) {
        guard generation == self.generation, let group = self.group else { return }
        guard let outcome = Ctx.decodeBegin(text) else {
            failLocate("malformed context reply")
            return
        }
        switch outcome {
        case let .failed(failure):
            if failure.error == "Busy" {
                scheduleLocateRetry(after: Self.historyPollDelay, generation: generation) {
                    [weak self] in
                    guard let self, let token = self.pendingContextToken else { return }
                    self.sendContextBegin(group: group, token: token, direction: direction)
                }
            } else {
                failLocate(failure.error)
            }
        case let .started(status):
            guard status.group == group, session == nil || status.session == session else {
                cancelLocateUnaccepted(status.jobID)
                failLocate("CursorMismatch")
                return
            }
            session = status.session
            locateJobID = status.jobID
            locateRequestID = nil
            scheduleLocatePoll(generation: generation)
        }
    }

    private func handleContext(_ page: ControlRoomChatContext.Context, jobID: String) {
        guard page.page.jobID == jobID, page.page.group == group,
              session == nil || page.page.session == session
        else {
            failLocate("CursorMismatch")
            return
        }
        if session == nil { session = page.page.session }
        if let pending = pendingContextDirection, pending != page.direction {
            failLocate("CursorMismatch")
            return
        }
        pendingContextDirection = nil
        pendingContextToken = nil
        let beforeFirst = rows.first?.id
        let beforeLast = rows.last?.id
        if page.direction == .older {
            mergeHistory(page.page.messages)
        } else {
            appendHistory(page.page.messages)
        }
        context = ContextTail(
            olderToken: page.page.olderToken,
            newerToken: page.page.newerToken,
            olderAtEnd: page.page.olderAtEnd,
            newerAtEnd: page.page.newerAtEnd
        )
        locateJobID = nil
        locateTrouble = nil
        locating = false
        // **A released edge makes a cursor stale.** The page's own edge must
        // still be at the window's end; if trim released it, the next request
        // would cross a run nobody kept. Re-anchoring around the retained
        // edge is the recovery; the host never advances that token.
        let expectedFirst = page.direction == .older
            ? page.page.messages.first?.anchor : beforeFirst
        let expectedLast = page.direction == .newer
            ? page.page.messages.last?.anchor : beforeLast
        if let expectedFirst, rows.first?.id != expectedFirst {
            contextOlderStale = true
        }
        if let expectedLast, rows.last?.id != expectedLast {
            contextNewerStale = true
        }
        if case .loading = state { state = rows.isEmpty ? .empty : .ready }
    }

    private func failLocate(_ why: String) {
        locateTrouble = why
        locating = false
        locateJobID = nil
        locateRequestID = nil
        cancelLocateScheduling()
    }

    private func cancelLocateUnaccepted(_ jobID: String) {
        guard jobID != locateJobID else { return }
        guard let request = try? ControlRoomChatRequest.cancel(jobID: jobID) else { return }
        _ = ask(request)
    }

    private func cancelLocateScheduling() {
        if let locatePollToken { scheduler.cancel(locatePollToken) }
        if let locateRetryToken { scheduler.cancel(locateRetryToken) }
        locatePollToken = nil
        locateRetryToken = nil
    }

    private func cancelLocateJob() {
        cancelLocateScheduling()
        guard let locateJobID else { return }
        self.locateJobID = nil
        guard let request = try? ControlRoomChatRequest.cancel(jobID: locateJobID) else { return }
        _ = ask(request)
    }

    // MARK: - The located window

    private func replaceWindow(_ messages: [D.Message]) {
        clearWindow()
        readingAnchor = nil
        readingOffset = 0
        trimmedBefore = nil
        trimmedAfter = nil
        for message in messages {
            let row = Row(id: message.anchor, message: message)
            byAnchor[message.anchor] = row.id
            if let live = message.liveAnchor {
                aliasesOf[row.id, default: []].insert(live)
                byAlias[live] = row.id
            }
            bytes += Self.cost(message)
            rows.append(row)
        }
        trim()
        syncMarkdown()
    }

    /// A newer context page: appended after the window, overlapping rows
    /// updated where they are.
    private func appendHistory(_ messages: [D.Message]) {
        for message in messages {
            if let hit = byAnchor[message.anchor] ?? message.liveAnchor.flatMap({ byAlias[$0] }) {
                apply(message, to: hit)
            } else {
                let row = Row(id: message.anchor, message: message)
                byAnchor[message.anchor] = row.id
                if let live = message.liveAnchor {
                    aliasesOf[row.id, default: []].insert(live)
                    byAlias[live] = row.id
                }
                bytes += Self.cost(message)
                rows.append(row)
            }
        }
        trim()
        syncMarkdown()
    }

    // MARK: - Scheduling lifetime

    /// Hand the Markdown store this feed's current truth. **Values only**:
    /// the store may parse off the main thread, so it is given copies of the
    /// text and the identity, never the feed or the core behind it.
    ///
    /// Called once at the end of each top-level change rather than from a
    /// `rows` observer: a batch of 500 messages mutates the array many times
    /// inside one merge, and one snapshot per merge is what keeps that
    /// linear.
    private func syncMarkdown() {
        let named = group ?? ""
        let snapshots = rows.map { row in
            ControlRoomChatMarkdownStore.Snapshot(
                id: row.id,
                group: named,
                anchor: row.message.anchor,
                version: row.message.contentVersion,
                text: row.message.text
            )
        }
        markdown.update(
            group: named,
            generation: generation,
            rows: snapshots,
            active: started
        )
    }

    private func cancelScheduling() {
        if let liveToken { scheduler.cancel(liveToken) }
        if let pollToken { scheduler.cancel(pollToken) }
        if let catchUpToken { scheduler.cancel(catchUpToken) }
        if let olderPollToken { scheduler.cancel(olderPollToken) }
        if let olderRetryToken { scheduler.cancel(olderRetryToken) }
        if let olderAdvanceToken { scheduler.cancel(olderAdvanceToken) }
        if let locatePollToken { scheduler.cancel(locatePollToken) }
        if let locateRetryToken { scheduler.cancel(locateRetryToken) }
        liveToken = nil
        pollToken = nil
        catchUpToken = nil
        olderPollToken = nil
        olderRetryToken = nil
        olderAdvanceToken = nil
        locatePollToken = nil
        locateRetryToken = nil
    }

    /// Best effort, once: a job whose answer nobody will read is still a job
    /// scanning the disk. A cancel that fails is not reported -- it must not
    /// raise a notification or merge an old page.
    private func cancelJob() {
        // **Every job.** `stop`/`deinit` cancel the bootstrap, the older
        // scan and the locate job together: one left running is a job
        // scanning a disk for an answer nobody will draw.
        cancelOlderJob()
        cancelLocateJob()
        guard let jobID else { return }
        self.jobID = nil
        guard let request = try? ControlRoomChatRequest.cancel(jobID: jobID) else { return }
        _ = ask(request)
    }

    // MARK: - The window

    /// Read a batch: the same envelope `group_read` answers with.
    static func decode(_ text: String) -> D.Batch? {
        try? JSONDecoder().decode(D.Batch.self, from: Data(text.utf8))
    }

    /// The bytes this message counts for, by the contract's own list: the
    /// body, the identity strings the window keeps, the author, the role and
    /// the mentions. Not the process's memory.
    static func cost(_ m: D.Message) -> Int {
        var total = m.text.utf8.count + m.author.utf8.count + m.from.utf8.count
        total += m.anchor.utf8.count
        if let role = m.role { total += role.utf8.count }
        if let live = m.liveAnchor { total += live.utf8.count }
        if let mentions = m.mentions {
            for mention in mentions {
                total += mention.id.utf8.count
                if let title = mention.title { total += title.utf8.count }
            }
        }
        return total
    }

    /// Place one message: by its anchor, else by its live alias, updating the
    /// row it already is; otherwise a new row. Returns false when the message
    /// does not fit the window at all.
    @discardableResult
    private func absorb(_ m: D.Message) -> Bool {
        if Self.cost(m) > Self.windowBytes {
            stopWithError("TooLarge")
            return false
        }
        let byA = byAnchor[m.anchor]
        let byL = m.liveAnchor.flatMap { byAlias[$0] }
        if let a = byA, let l = byL, a != l {
            // Two rows turn out to be one message. **The one that was here
            // first keeps its display id**, whichever map found it.
            let keepA = (rows.firstIndex { $0.id == a } ?? 0) <= (rows.firstIndex { $0.id == l } ?? .max)
            let keep = keepA ? a : l
            let drop = keepA ? l : a
            mergeRow(drop, into: keep)
            apply(m, to: keep)
            return true
        }
        if let hit = byA ?? byL {
            apply(m, to: hit)
        } else {
            insert(m)
        }
        return true
    }

    private func apply(_ m: D.Message, to id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let old = rows[i].message
        bytes += Self.cost(m) - Self.cost(old)
        if old.anchor != m.anchor {
            if byAnchor[old.anchor] == id { byAnchor.removeValue(forKey: old.anchor) }
            aliasesOf[id, default: []].insert(old.anchor)
            byAlias[old.anchor] = id
            byAnchor[m.anchor] = id
        }
        // **Even when it equals the canonical anchor**: a message that is
        // only live today can come back persisted tomorrow carrying this as
        // its `live_anchor`, and the alias is how the two are one row.
        if let live = m.liveAnchor {
            aliasesOf[id, default: []].insert(live)
            byAlias[live] = id
        }
        rows[i].message = m
        trim()
    }

    private func insert(_ m: D.Message) {
        let row = Row(id: m.anchor, message: m)
        byAnchor[m.anchor] = row.id
        if let live = m.liveAnchor {
            aliasesOf[row.id, default: []].insert(live)
            byAlias[live] = row.id
        }
        bytes += Self.cost(m)
        if m.seq > 0 {
            // A live message: ordered by the core's own `seq` among live
            // rows. Never against a `log_seq`, and never against a history
            // record's `seq` (which is 0).
            if let i = rows.firstIndex(where: { $0.message.seq > m.seq }) {
                rows.insert(row, at: i)
            } else {
                rows.append(row)
            }
        } else {
            rows.append(row)
        }
        trim()
    }

    /// Older messages: each page is old→new and goes in front of everything
    /// already held, overlapping rows updated where they are.
    private func mergeHistory(_ messages: [D.Message]) {
        if messages.contains(where: { Self.cost($0) > Self.windowBytes }) {
            stopWithError("TooLarge")
            return
        }
        var older: [Row] = []
        for m in messages {
            if let hit = byAnchor[m.anchor] ?? m.liveAnchor.flatMap({ byAlias[$0] }) {
                apply(m, to: hit)
            } else {
                let row = Row(id: m.anchor, message: m)
                byAnchor[m.anchor] = row.id
                if let live = m.liveAnchor {
                    aliasesOf[row.id, default: []].insert(live)
                    byAlias[live] = row.id
                }
                bytes += Self.cost(m)
                older.append(row)
            }
        }
        if !older.isEmpty {
            rows.insert(contentsOf: older, at: 0)
            // **A view that has not reported its anchor yet must not lose
            // the page it just asked for.** Until it does, the merged page's
            // newest row stands in for the reader -- it is the row nearest
            // where the reader was -- so trim keeps it and what surrounds
            // it. The view replaces this with the real anchor on its next
            // scroll.
            if readingAnchor == nil { readingAnchor = older.last?.id }
        }
        trim()
        syncMarkdown()
    }

    private func mergeRow(_ dropID: String, into keepID: String) {
        guard let i = rows.firstIndex(where: { $0.id == dropID }) else { return }
        let dropped = rows.remove(at: i)
        bytes -= Self.cost(dropped.message)
        if let canonical = byAnchor[dropped.message.anchor], canonical == dropID {
            byAnchor.removeValue(forKey: canonical)
            aliasesOf[keepID, default: []].insert(canonical)
            byAlias[canonical] = keepID
        }
        for alias in aliasesOf.removeValue(forKey: dropID) ?? [] {
            aliasesOf[keepID, default: []].insert(alias)
            byAlias[alias] = keepID
        }
    }

    /// The window's edge. **Not simply the oldest row**: while somebody is
    /// reading history the oldest row is the page they just asked for. The
    /// reader's own row and a window either side of it stay; the newest
    /// messages stay as a tail of their own; what goes is outside both.
    /// A dropped message takes its aliases with it.
    private func trim() {
        while rows.count > Self.windowLimit || bytes > Self.windowBytes {
            guard let i = trimIndex() else { break }
            let row = rows.remove(at: i)
            bytes -= Self.cost(row.message)
            forget(row)
            // The run is at one end of the kept window or at the boundary
            // between the reading window and the live tail -- never picked
            // out of the middle. Say so, so the list can draw the boundary
            // and the person can reload rather than read a false neighbour.
            if i == 0 {
                trimmedBefore = rows.first?.id
            } else {
                trimmedAfter = rows[i - 1].id
            }
        }
        if bytes < 0 { bytes = 0 }
    }

    /// Which row to drop, or nil when nothing may go. Without a reader's
    /// anchor (the view has not reported one yet) this is the oldest, as it
    /// has always been.
    private func trimIndex() -> Int? {
        guard !rows.isEmpty else { return nil }
        guard let readingAnchor,
              let reader = rows.firstIndex(where: { $0.id == readingAnchor })
        else { return 0 }
        // 1. Older than the window above the reader: this is the far side
        //    of the page they are reading, not the page itself.
        if reader > Self.keepAboveReader { return 0 }
        // 2. Newer than the window below the reader, and before the live
        //    tail. The live tail is kept on its own: the newest messages are
        //    what a reader coming back to the bottom expects to find.
        let firstLive = rows.count - Self.keepLiveTail
        let candidate = max(reader + 1, reader + Self.keepBelowReader + 1)
        if candidate < firstLive { return candidate }
        // 3. Every row is inside the two windows: the oldest goes, never the
        //    reader's own row.
        if reader > 0 { return 0 }
        if firstLive > 1 { return 1 }
        return nil
    }

    private func forget(_ row: Row) {
        if byAnchor[row.message.anchor] == row.id {
            byAnchor.removeValue(forKey: row.message.anchor)
        }
        for alias in aliasesOf.removeValue(forKey: row.id) ?? [] {
            if byAlias[alias] == row.id { byAlias.removeValue(forKey: alias) }
        }
    }

    private func clearWindow() {
        rows = []
        byAnchor = [:]
        byAlias = [:]
        aliasesOf = [:]
        bytes = 0
        readingAnchor = nil
        readingOffset = 0
        trimmedBefore = nil
        trimmedAfter = nil
    }
}
