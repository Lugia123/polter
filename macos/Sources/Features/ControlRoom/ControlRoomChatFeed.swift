import Combine
import Foundation

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
        /// Loading has stopped at an error; the rows already drawn stay.
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

    private var generation: UInt64 = 0
    private var liveNext: UInt64 = 0
    private var bootstrapID: String?
    private var jobID: String?
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

    private var byAnchor: [String: String] = [:]
    private var byAlias: [String: String] = [:]
    private var aliasesOf: [String: Set<String>] = [:]
    private var bytes = 0

    /// `@escaping` because the door outlives the call that hands it in.
    init(ask: @escaping Ask, scheduler: ControlRoomChatScheduling = ControlRoomChatTimerScheduler()) {
        self.ask = ask
        self.scheduler = scheduler
    }

    deinit {
        // Nothing keeps asking once the container has dropped the feed.
        if let liveToken { scheduler.cancel(liveToken) }
        if let pollToken { scheduler.cancel(pollToken) }
        if let catchUpToken { scheduler.cancel(catchUpToken) }
        cancelJob()
    }

    // MARK: - The page's two moments

    /// The page is in front, on `group`. **The same group already running is
    /// not started again**: a repeated `start` must not make a second job or
    /// a second timer.
    func start(group: String) {
        if self.group == group {
            if started { return }
        } else {
            leaveGroup()
            self.group = group
        }
        started = true
        generation += 1
        reloadedOnce = false
        startBootstrap()
    }

    /// The page is out of sight. **Unconditional**: the scheduler is cleared
    /// and a known job is cancelled even when no timer was outstanding, and
    /// every answer from before this moment is dropped by its generation.
    /// The rows stay, so coming back shows what was there.
    func stop() {
        started = false
        generation += 1
        cancelScheduling()
        cancelJob()
    }

    /// The person asked a stopped load to try again.
    func reload() {
        guard started else { return }
        generation += 1
        cancelScheduling()
        cancelJob()
        // **`session` is kept** so that the new begin can tell a retry of the
        // same run (merge the snapshot) from a new run (replace the body).
        liveNext = 0
        bootstrapped = false
        reloadedOnce = false
        canReload = false
        trouble = nil
        state = .loading
        startBootstrap()
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
        replacing = false
        reloadedOnce = false
        rows = []
        byAnchor = [:]
        byAlias = [:]
        aliasesOf = [:]
        bytes = 0
        historyTail = nil
        state = .idle
        trouble = nil
        canReload = false
    }

    /// A fresh bootstrap: new `request_id`, `limit` 50 and no resume token.
    /// A retry of the same begin reuses the id and parameters.
    private func startBootstrap() {
        bootstrapID = ControlRoomChatRequest.newRequestID()
        bootstrapped = false
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
            retryBegin(after: period, generation: generation)
        case let .refused(why):
            stopWithError(why)
        case let .answer(text):
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
        guard generation == self.generation else { return }
        guard let outcome = H.decodeBegin(text) else {
            stopWithError("malformed begin reply")
            return
        }
        switch outcome {
        case let .failed(failure):
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
            guard page.group == group else { return }
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
            bootstrapped = true
            // `reloadedOnce` is **not** reset here: one automated
            // rebootstrap is the budget, and a begin that succeeds after
            // one round must not buy another for ever.
            canReload = false
            trouble = nil
            for message in page.liveSnapshot {
                if !absorb(message) { break }
            }
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
        session = nil
        liveNext = 0
        bootstrapped = false
        // **Not `reloadedOnce`**: that budget belongs to one visible
        // lifecycle, and a core that keeps restarting must not buy a fresh
        // automated bootstrap with every session.
        replacing = true
        state = .loading
        trouble = nil
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
            schedulePoll(generation: generation)
        case let .refused(why):
            // No retry: the request itself was refused, and asking it again
            // would be the same refusal. The rows already drawn stay.
            trouble = why
            self.jobID = nil
            canReload = true
            if rows.isEmpty { state = .failed(why) } else { state = .ready }
        case let .answer(text):
            handlePoll(text, jobID: jobID, generation: generation, group: group)
        }
    }

    private func handlePoll(_ text: String, jobID: String, generation: UInt64, group: String) {
        guard generation == self.generation else { return }
        guard let outcome = H.decodePoll(text) else {
            stopWithError("malformed history reply")
            return
        }
        switch outcome {
        case .pending:
            schedulePoll(generation: generation)

        case .cancelled:
            self.jobID = nil
            // A cancelled scan is not a page and not an answer about the
            // history; it must not leave the page saying it is still
            // loading for ever.
            state = rows.isEmpty ? .empty : .ready

        case let .ready(page):
            guard page.jobID == jobID, page.group == group,
                  session == nil || page.session == session
            else { return }
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
            state = rows.isEmpty ? .empty : .ready

        case let .failed(failure):
            if let named = failure.jobID, named != jobID { return }
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

    private func stopWithError(_ why: String) {
        trouble = why
        state = .failed(why)
        canReload = true
        cancelScheduling()
    }

    // MARK: - Scheduling lifetime

    private func cancelScheduling() {
        if let liveToken { scheduler.cancel(liveToken) }
        if let pollToken { scheduler.cancel(pollToken) }
        if let catchUpToken { scheduler.cancel(catchUpToken) }
        liveToken = nil
        pollToken = nil
        catchUpToken = nil
    }

    /// Best effort, once: a job whose answer nobody will read is still a job
    /// scanning the disk. A cancel that fails is not reported -- it must not
    /// raise a notification or merge an old page.
    private func cancelJob() {
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
        if !older.isEmpty { rows.insert(contentsOf: older, at: 0) }
        trim()
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

    /// The window's edge: newest messages kept, and a dropped message takes
    /// its aliases with it.
    private func trim() {
        while rows.count > Self.windowLimit || bytes > Self.windowBytes {
            guard !rows.isEmpty else { break }
            let row = rows.removeFirst()
            bytes -= Self.cost(row.message)
            forget(row)
        }
        if bytes < 0 { bytes = 0 }
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
    }
}
