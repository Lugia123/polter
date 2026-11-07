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
/// **What is kept is a window, not the history** (task 3016 R4): `rows` is
/// the document the lazy list is handed, and `above`/`below` are the rows
/// read from the core that the reader has not reached (or has passed).
/// The view moves five rows at a time between them, so a scroll never
/// inserts a page; the request may still be coarse, because a round trip is
/// the expensive part. **The aprons are not a queue held for a gesture**:
/// rows land there at once and the window feeds from them immediately.
///
/// **What is kept is bounded**: `retainedLimit` rows and 32 MiB of their
/// text and identity strings, across the document and both aprons. Past a
/// ceiling records leave from the far apron first -- never a row out of the
/// middle -- and a dropped message takes its aliases with it, so the maps
/// behind them cannot grow with the night. A dropped run is a real gap and
/// is said so; a row moving between the document and an apron is not.
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
    /// budget/at_end/gap states). **None of these is a drawing**: the page's
    /// top edge no longer shows loading, cancellation or failure, because
    /// loading an older page is invisible -- the scroll bar's total (the
    /// number of rows loaded) is the only evidence of it. What is left here
    /// are its three jobs: refuse a second request while one is out, keep a
    /// failure askable again from the same token, and answer
    /// `canLoadOlder`. An empty page that still has a resume token is
    /// `.scanning`, never "the beginning of the log".
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

    /// **The first screen is fetched whole**: twelve screens of the rows the
    /// pane shows, in one request, because the reader has not scrolled yet
    /// and there is nothing to pace (task 3016 R4; the capacity red aligned
    /// it with the ten-screen margin). Before the pane has measured itself
    /// this is the conservative default -- twelve screens of the default
    /// sixteen rows -- since waiting for the measurement would wait for the
    /// first screen to produce it.
    static let firstChunkFallback = 192
    /// **The later pages are their own size each time.** A page asks for
    /// what the five-screen margin is missing, with a floor so one round
    /// trip brings back more than a handful; `ControlRoomChatWindow` computes
    /// it and `loadOlder(limit:)` carries it.
    static let olderChunkFloor = ControlRoomChatWindow.requestFloor
    /// The context page's own size. **Not the plain resume page's** (they
    /// are different questions and may be tuned apart). Its own window is
    /// around the located row, so the page is a screen and a half either
    /// way, and the search page's limit lives in `ControlRoomChatSearchFeed`.
    static let contextChunk = 50

    /// **How much of the conversation one showing keeps.** A chat page is a
    /// fixed window onto an endless stream: the window never says how much
    /// is behind it, so the old 500-row bound (a screen's worth, kept as
    /// though it were the document's own end) is gone. Five thousand rows is
    /// the row ceiling; past it rows leave **one whole block at a time, from
    /// the end farthest from the reader**, so what is kept stays one
    /// contiguous run and the scroll bar's total (`rows.count`) is the only
    /// thing that changes.
    ///
    /// **The row ceiling alone would not bound memory.** A record on disk is
    /// at most ~64 KiB (`ChatLog.zig`), so five thousand rows could hold
    /// ~312 MiB of text -- and `aroundVerified` admits records up to 96 KiB.
    /// That is exactly why the byte ceiling below stays: it is the bound
    /// that is actually felt.
    static let retainedLimit = 5000
    /// ... and at most this many bytes of their text and identity strings.
    /// **Thirty-two megabytes, the same number the Windows host keeps**: a
    /// 4 MiB ceiling would fill long before five thousand rows in any group
    /// whose messages average more than 800 bytes, which would make
    /// `retainedLimit` a promise the byte bound never lets be kept. The
    /// structure behind the rows (`byAnchor`, `byAlias`, `aliasesOf`) costs
    /// roughly another megabyte or two at this size. Over the byte ceiling,
    /// whole blocks go the same way.
    static let retainedBytes = 32 * 1024 * 1024

    /// An empty budget page carries the scan on after this long. A delay and
    /// not a recursive call: the next page is a fresh scheduled turn.
    static let olderAdvanceDelay: TimeInterval = 0.05
    /// How long a failed older page holds the top edge back before it may be
    /// asked for again. **A failure must not become a request storm**: the
    /// view asks for older records on every scroll event near the top, so a
    /// failure that is re-askable at once is one request per event while the
    /// core keeps refusing. This also covers a located window's context
    /// cursor, whose failures end in `failLocate`.
    static let olderFailureCooldown: TimeInterval = 2
    /// How many empty `budget` pages the scan may carry itself through
    /// before it stops. The contract lets a quiet range take more than one
    /// page, but a core that keeps answering "empty, here is another token"
    /// must not be followed for ever. The resume token stays in
    /// `historyTail`, so the person's next ask continues from it.
    static let maxAutomaticAdvances = 8

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

    /// Loading further back. **Not drawn**: the view no longer turns any of
    /// these into a row at the top of the list (DESIGN-v2 §4); see `Older`
    /// for the three jobs this state keeps.
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
    /// **A locate's own event counter.** `generation` also moves for
    /// reasons that are not a locate (a stop, a reload, a session change),
    /// so it cannot tell the view "a locate happened again" -- and a second
    /// locate of the same anchor, or a second failure, changes nothing else
    /// the view can see (`locatedAnchor` nil -> nil is no change). This
    /// moves at the start of every `locate()` call -- before it decides
    /// whether it can run -- and again when a locate fails.
    @Published private(set) var locateEpoch: UInt64 = 0
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
    /// went; `trimmedAfter` names the last kept row when the newest end was
    /// released instead (the reader was at the top loading older pages, so
    /// the far block was the newest one). Both mark a released run of whole
    /// blocks at an end of the kept window, never a hole in the middle.
    @Published private(set) var trimmedBefore: String?
    @Published private(set) var trimmedAfter: String?

    var hasTrimmedGap: Bool { trimmedBefore != nil || trimmedAfter != nil }

    /// **A released run is only drawn where the window really ends.** The
    /// document is a sliding window: its top row is not the oldest record
    /// while the apron in front of it still holds rows, so a gap mark there
    /// would claim a hole that is not one. The marker is for a record the
    /// ceiling dropped and cannot read back.
    var trimmedBeforeAtEdge: String? { above.isEmpty ? trimmedBefore : nil }
    var trimmedAfterAtEdge: String? { below.isEmpty ? trimmedAfter : nil }

    /// Whether an older page may still be read. **The document's edge is not
    /// the history's end** (R4): the in-memory window moves, and what is
    /// knowable is the scan's own word.
    var hasEarlier: Bool {
        if let context {
            return context.olderToken != nil && !context.olderAtEnd
        }
        if older == .atEnd || older == .gap { return false }
        return historyTail?.nextToken != nil
    }

    /// The mirror, for a located window's lower edge. A plain window's
    /// newest end is the live tail, which is always the end.
    var hasNewer: Bool {
        guard let context else { return false }
        return context.newerToken != nil && !context.newerAtEnd
    }

    /// **The real beginning**: the scan said there is nothing older, and
    /// nothing is held above the document that has not been drawn yet. A
    /// located window answers with its own older cursor -- `older` belongs
    /// to the plain scan, which a locate cleared.
    var reachedBeginning: Bool {
        if let context { return context.olderAtEnd && above.isEmpty }
        return older == .atEnd && above.isEmpty
    }

    /// **The real end**: nothing is held below the document, **nothing was
    /// ever dropped from that end**, and a located window's newer cursor is
    /// spent. The dropped check is `trimmedAfter`, not its at-edge variant:
    /// a record the ceiling took is missing whether or not the apron beside
    /// it is empty, and claiming the end while a run is gone would be a
    /// false "this is the newest message".
    var reachedEnd: Bool {
        below.isEmpty && trimmedAfter == nil
            && (context.map { $0.newerAtEnd } ?? true)
    }

    /// The stable identity of the message the reader's viewport starts on,
    /// as the view last said. **Trim only**: it never moves the reader and
    /// nothing is drawn from it. Nil before the view has reported one, and
    /// then `trim` treats the oldest block as the far one.
    private(set) var readingAnchor: String?
    /// How far into that message the reader was, kept with the id so a page
    /// that is shown again comes back to the same line rather than to the
    /// top of the same row.
    private(set) var readingOffset: Double = 0

    /// The position a re-displayed page restores to, if it has one.
    var savedReading: ControlRoomChatCamera.Place? {
        readingAnchor.map { ControlRoomChatCamera.Place(id: $0, offset: readingOffset) }
    }

    /// Whether a page older than the window can be asked for now. A page
    /// already out is not asked for again: the top edge calls `loadOlder` on
    /// every scroll event while the reader stays there, so this is what keeps
    /// that to one request. **A failed page is not askable again until its
    /// cooldown passes** (`olderFailureCooldown`), or a core that keeps
    /// refusing would get one request per event.
    ///
    /// **A located window has its own older cursor.** `locate` clears
    /// `historyTail`, so after a search result lands the resume token the
    /// plain path needs is gone; the context cursor is what may still ask.
    var canLoadOlder: Bool {
        guard !olderCoolingDown else { return false }
        if let context {
            return context.olderToken != nil && !context.olderAtEnd
                && !contextOlderStale
                && locateJobID == nil && locateRequestID == nil
        }
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

    /// **How much this showing keeps.** The two static defaults are the
    /// production ceiling; these instances are what `trim` and the
    /// per-message `TooLarge` check actually read, so a test can reach the
    /// edge with a handful of small messages instead of building five
    /// thousand rows or thirty-two megabytes of text.
    var rowLimit = ControlRoomChatFeed.retainedLimit
    var byteLimit = ControlRoomChatFeed.retainedBytes

    /// How many rows the page's viewport shows, as the view last reported.
    /// **The feed cannot measure this**: it holds messages, not heights. The
    /// view sets it from its own frames when it knows the real value; until
    /// then `defaultViewportRows` stands for one ordinary chat screen.
    var viewportRows = ControlRoomChatFeed.defaultViewportRows
    /// Whether the view has actually measured the viewport. **Not inferred
    /// from the number**: a measured pane may show fewer rows than the
    /// default, and the first screen's size must follow the measurement
    /// rather than a comparison with a guess.
    var viewportMeasured = false
    /// ~800 pt of pane at ~50 pt per ordinary row.
    static let defaultViewportRows = 16

    /// The `before`/`after` a located window asks for. **One and a half
    /// viewports each way**: the new page has no boundary strip saying
    /// "there is more below", so a 10+10 window would leave half the screen
    /// empty until the person scrolls. At least 10 keeps the old minimum;
    /// the core's own hard limit is 99 a side (`aroundBegin`).
    var locateWindowRows: Int {
        min(99, max(10, Int((Double(viewportRows) * 1.5).rounded(.up))))
    }

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
    /// A failed older page's cooling-off. While it stands, `canLoadOlder` is
    /// false and `loadOlder` refuses: the top edge must not turn one refusal
    /// into one request per scroll event.
    private var olderCoolingDown = false
    private var olderCooldownToken: UUID?
    /// Empty `budget` pages carried on since the last real ask, against
    /// `maxAutomaticAdvances`. A person's request resets it.
    private var automaticAdvances = 0
    /// When the page out now was asked for, for the block log.
    private var pageAskedMs: Int64 = 0
    /// **What was read but is not in the document** (task 3016 R4): older
    /// rows the reader has not reached yet, oldest first, with the last one
    /// nearest the document; and newer rows the window has passed, oldest
    /// first, with the first one nearest the document.
    ///
    /// **These are aprons, not a queue.** A page lands here at once -- this
    /// is not the old "hold the page for the gesture" -- and the view feeds
    /// the document from here five rows at a time. Keeping the rows on the
    /// far side is what lets a reader who has scrolled up come back down:
    /// dropping them would need a forward history cursor the core does not
    /// have.
    private(set) var above: [Row] = []
    private(set) var below: [Row] = []
    /// How many rows are loaded outside the document, for the view's window
    /// arithmetic and for a test to read.
    var aboveCount: Int { above.count }
    var belowCount: Int { below.count }
    /// A row's height in points, as the view has measured it. The feed
    /// cannot measure rows; it uses this to turn "half a screen" and a
    /// request's deficit into counts. **A measurement, not a constant**: the
    /// same margin is 250 rows of 16 pt and 13 rows of 300 pt (review C, M5).
    var rowHeightEstimate = ControlRoomChatWindow.defaultRowHeight
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
        if let olderCooldownToken { scheduler.cancel(olderCooldownToken) }
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
            // **The page comes back at the newest message** (task 3002), and
            // with a window that may have been left in the middle of history
            // (R4) that is a rebuild, not a scroll: the document is put back
            // around the newest loaded rows, and the pinned projection then
            // lands on the real last message rather than on the end of a
            // window the reader walked away from.
            if locatedAnchor == nil {
                goToLatest()
                armLive()
            }
            armOlderAfterResume()
            return
        }
        // A bootstrap is the first screen again; the older scan it may have
        // been in the middle of is another lifecycle's, and its token is not
        // this scan's.
        older = .idle
        olderAutomatic = false
        automaticAdvances = 0
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
        automaticAdvances = 0
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
        // **A stop ends the showing, and the reader's place is the showing's,
        // not the group's.** The rows stay so coming back shows what was
        // there, but the page comes back **at the latest message**: a reading
        // anchor kept across a stop reopened the group on a stale line --
        // possibly one `loadOlder`'s fallback wrote while the reader had not
        // moved at all (task 2999 ②). Restoring a place is for a layout
        // change *within* one showing (the search sidebar opening, a narrower
        // window), which does not stop the feed.
        readingAnchor = nil
        readingOffset = 0
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
        automaticAdvances = 0
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
        above = []
        below = []
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
        automaticAdvances = 0
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

    /// **How many rows the first screen asks for** (R4): twelve screens of
    /// the rows the pane has measured, or the conservative default before the
    /// probe has attached. A retry of the same begin reuses the id and the
    /// same number, so the core's answer is the same question.
    private var firstScreenLimit: Int {
        let rows = viewportMeasured
            ? ControlRoomChatWindow.firstScreenRows(viewportRows: viewportRows)
            : Self.firstChunkFallback
        return min(ControlRoomChatWindow.maxRequestRows, max(1, rows))
    }
    /// The limit the bootstrap out now was sent with. **A retry of the same
    /// begin reuses it**, so the core is answering the same question even if
    /// the pane has been measured since.
    private var bootstrapLimit = ControlRoomChatFeed.firstChunkFallback

    /// A fresh bootstrap: new `request_id`, the first screen's limit and no
    /// resume token. A retry of the same begin reuses the id and parameters.
    private func startBootstrap() {
        bootstrapID = ControlRoomChatRequest.newRequestID()
        bootstrapped = false
        firstScreenReady = false
        canReload = false
        state = .loading
        pageAskedMs = nowMs()
        bootstrapLimit = firstScreenLimit
        sendBegin()
    }

    private func sendBegin() {
        guard started, let group, let id = bootstrapID else { return }
        let generation = self.generation
        guard let request = try? ControlRoomChatRequest.begin(
            group: group, requestID: id, limit: bootstrapLimit
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
        automaticAdvances = 0
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
            let before = rows.count
            mergeHistory(page.messages)
            logBlock(asked: pageAskedMs, before: before, after: rows.count, pages: 1)
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
            // whose recent range is quiet. `olderAdvance` says where that
            // stops (damage, a restarted range, or too many empty pages).
            if let advance = olderAdvance(page) {
                switch advance {
                case let .carryOn(token):
                    if rows.isEmpty {
                        state = .loading
                    } else if case .loading = state {
                        state = .ready
                    }
                    scheduleOlderAdvance(token: token, generation: generation)
                case let .stop(why):
                    if let why {
                        failOlder(why)
                    } else {
                        settleOlder(page)
                        settleFirstScreen(page)
                        firstScreenReady = true
                    }
                }
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

    // MARK: - The window (task 3016 R4, amended by review C)

    /// **Move buffered rows into the document's front.** At most `n` rows
    /// and at most `maxHeight` of estimated height, **one rows change per
    /// call** (review C, M8): the view asks for one step and the list is
    /// handed one step, not five separate updates.
    ///
    /// **An empty apron is not a stop** (review C, M6): the view asks the
    /// core for more when the margin is short whether or not this returns
    /// rows, and the document stays where it is until they arrive -- a blank
    /// list would be a worse answer than the loaded edge.
    @discardableResult
    func feedOlder(rows n: Int, maxHeight: Double) -> Int {
        guard started, n > 0, !above.isEmpty else { return 0 }
        let take = stepCount(n, maxHeight: maxHeight, available: above.count)
        guard take > 0 else { return 0 }
        let moved = Array(above.suffix(take))
        above.removeLast(take)
        rows.insert(contentsOf: moved, at: 0)
        syncMarkdown()
        return take
    }

    /// The mirror: buffered newer rows onto the document's end. The same
    /// one-update rule.
    @discardableResult
    func feedNewer(rows n: Int, maxHeight: Double) -> Int {
        guard started, n > 0, !below.isEmpty else { return 0 }
        let take = stepCount(n, maxHeight: maxHeight, available: below.count)
        guard take > 0 else { return 0 }
        let moved = Array(below.prefix(take))
        below.removeFirst(take)
        rows.append(contentsOf: moved)
        syncMarkdown()
        return take
    }

    /// **Release rows from the document's front into the apron.** The camera
    /// row never leaves. One rows change.
    @discardableResult
    func releaseOlder(count n: Int) -> Int {
        guard started, n > 0, let anchor = readingAnchor,
              let index = rows.firstIndex(where: { $0.id == anchor })
        else { return 0 }
        let take = min(n, index)
        guard take > 0 else { return 0 }
        let moved = Array(rows.prefix(take))
        rows.removeFirst(take)
        above.append(contentsOf: moved)
        syncMarkdown()
        return take
    }

    /// The mirror: release from the document's end into the newer apron.
    @discardableResult
    func releaseNewer(count n: Int) -> Int {
        guard started, n > 0, let anchor = readingAnchor,
              let index = rows.firstIndex(where: { $0.id == anchor })
        else { return 0 }
        let take = min(n, rows.count - index - 1)
        guard take > 0 else { return 0 }
        let moved = Array(rows.suffix(take))
        rows.removeLast(take)
        below.insert(contentsOf: moved, at: 0)
        syncMarkdown()
        return take
    }

    /// **The teleport to the newest end** (R1-8/R4): the document is rebuilt
    /// from the newest loaded rows, one rows change, so the next pinned
    /// projection lands on the real last message rather than on the end of a
    /// window the reader walked away from.
    func goToLatest() {
        guard started, !below.isEmpty else { return }
        let loaded = above + rows + below
        let keep = max(1, Int(ControlRoomChatWindow.firstScreenScreens * Double(viewportRows)))
        let take = min(keep, loaded.count)
        above = Array(loaded.prefix(loaded.count - take))
        rows = Array(loaded.suffix(take))
        below = []
        readingAnchor = rows.last?.id
        readingOffset = 0
        trim()
        syncMarkdown()
    }

    /// **A teleport to a row this feed already holds but the document does
    /// not**: rebuild the document around it, ±twelve screens, one rows
    /// change.
    /// False when the id is not loaded at all -- that is the core's question
    /// (`jump(to:)`'s around).
    @discardableResult
    func recentre(on id: String) -> Bool {
        guard started else { return false }
        let target = byAnchor[id] ?? byAlias[id] ?? id
        if rows.contains(where: { $0.id == target }) { return true }
        let loaded = above + rows + below
        guard let index = loaded.firstIndex(where: { $0.id == target }) else {
            return false
        }
        let keep = max(1, Int(ControlRoomChatWindow.retainScreens * Double(viewportRows)))
        let start = max(0, min(index - keep / 2, loaded.count - keep))
        let end = min(loaded.count, start + keep)
        above = Array(loaded[..<start])
        rows = Array(loaded[start..<end])
        below = Array(loaded[end...])
        readingAnchor = target
        readingOffset = 0
        trim()
        syncMarkdown()
        return true
    }

    /// How many rows one call may move: the caller's row cap, the height
    /// the caller allows, and what the apron actually holds.
    private func stepCount(_ n: Int, maxHeight: Double, available: Int) -> Int {
        let height = max(1, rowHeightEstimate)
        var take = min(n, available)
        if maxHeight > 0 {
            take = min(take, max(1, Int((maxHeight / height).rounded(.down))))
        }
        return max(0, take)
    }


    /// The person (or the view near its top edge) asked for what came
    /// before the window. A page already out is not asked for again, so
    /// calling this on every scroll event sends one request, not twenty.
    ///
    /// **One entry for both kinds of window.** A located window (`context !=
    /// nil`) has no `historyTail` -- `locate` cleared it -- so the plain
    /// resume token would do nothing there; the same gesture routes to the
    /// context cursor instead. The view can call this at the top edge
    /// without knowing which kind of window it is showing.
    ///
    /// **Loading older is not a UI event.** It adds rows and moves `older`;
    /// it never touches `state`: a page that already has rows stays
    /// `.ready` while an older page is out, `.loading` belongs to a first
    /// screen that has nothing to draw yet.
    ///
    /// `limit` is **how many rows the five-screen margin is missing**, as
    /// `ControlRoomChatWindow` computed it (review C, M6), not a fixed page:
    /// a fixed hundred in a group of long messages is thirty screens sitting
    /// in an apron.
    func loadOlder(limit: Int = ControlRoomChatFeed.olderChunkFloor) {
        guard started, group != nil, !olderCoolingDown else { return }
        if context != nil {
            loadContextOlder()
            return
        }
        guard let token = historyTail?.nextToken else { return }
        switch older {
        case .loading, .scanning: return
        default: break
        }
        beginContinuation(token: token, automatic: false, limit: limit)
    }

    /// **The view's one teleport primitive** (task 3016 §6). A row already in
    /// the loaded window is a scroll and the view's own business; this is the
    /// *change of map* half -- an `around` window centred on the row, after
    /// which the row is in `rows` and the view projects onto it.
    ///
    /// **Idempotent with a locate already on its way**: the search panel and
    /// a locate's own epoch both arrive through here, and a second `around`
    /// for the same anchor would restart a job whose window is about to land.
    func jump(to id: String) {
        guard started, let group else { return }
        // **A row already loaded is a change of window, not a request**
        // (R4): the document is rebuilt around it, one rows change, and the
        // view projects onto it. Asking the core for a map it already has
        // would be the slow teleport this model is for.
        if recentre(on: id) { return }
        if locating, locateAnchor == id { return }
        locate(anchor: id, location: nil)
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
    private func beginContinuation(token: String, automatic: Bool, limit: Int) {
        guard started, group != nil, historyTail?.nextToken == token else { return }
        olderAutomatic = automatic
        if !automatic { automaticAdvances = 0 }
        olderRequestID = ControlRoomChatRequest.newRequestID()
        olderToken = token
        olderJobID = nil
        olderLimit = limit
        older = automatic ? .scanning : .loading
        sendContinuationBegin()
    }

    /// What the page out now asked for. A retry of the same begin is the
    /// same question -- the core answers the original reply for a repeated
    /// id -- so the limit must travel with the id.
    private var olderLimit = ControlRoomChatFeed.olderChunkFloor

    private func sendContinuationBegin() {
        guard started, let group, let requestID = olderRequestID,
              let token = olderToken
        else { return }
        let generation = self.generation
        guard let request = try? ControlRoomChatRequest.begin(
            group: group, requestID: requestID, limit: olderLimit, resumeToken: token
        ) else {
            failOlder("BadParams")
            return
        }
        pageAskedMs = nowMs()
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
            self.olderJobID = nil
            // **A page lands at once** (R4): into the older apron, and the
            // view feeds the document from there five rows at a time. There
            // is no gesture to wait for -- the five-row step is what makes
            // the insertion invisible, not a delay.
            finishContinuation(page, generation: generation)
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

    /// Land a continuation page: put it where it belongs, take its tail,
    /// settle the loader.
    ///
    /// **The first screen is the document; every later page is an apron.**
    /// The first screen is fetched whole because the reader has not
    /// scrolled; after that the document grows five rows at a time from
    /// here, and this page is a buffer of the reader's next few screens.
    private func finishContinuation(_ page: H.Ready, generation: UInt64) {
        if firstScreenReady {
            let before = above.count
            bufferOlder(page.messages)
            logBlock(asked: pageAskedMs, before: before, after: above.count, pages: 1)
        } else {
            let before = rows.count
            mergeHistory(page.messages)
            logBlock(asked: pageAskedMs, before: before, after: rows.count, pages: 1)
        }
        historyTail = HistoryTail(
            stop: page.stop,
            nextToken: page.nextToken,
            restarted: page.restarted,
            gap: page.gap
        )
        trouble = nil
        // **An empty budget page is progress.** The contract says so in one
        // line, and this is the host half of it: continue from the token it
        // named, but never from the token already used -- that would scan
        // the same range for ever and look like a slow disk. `olderAdvance`
        // also stops at damage, at a restarted range, and after too many
        // empty pages in a row.
        if let advance = olderAdvance(page) {
            switch advance {
            case let .carryOn(next):
                guard next != olderToken else {
                    failOlder("the history scan stopped advancing")
                    return
                }
                scheduleOlderAdvance(token: next, generation: generation)
            case let .stop(why):
                if let why {
                    failOlder(why)
                } else {
                    settleOlder(page)
                    olderToken = nil
                }
            }
            return
        }
        settleOlder(page)
        olderToken = nil
        if case .loading = state {
            settleFirstScreen(page)
            firstScreenReady = true
        }
    }

    /// **A page older than the document goes into the older apron**: it is
    /// what the reader's next few screens are fed from. Records already held
    /// update the row that holds them -- a reread of the same range must not
    /// become a second row -- and the rest go in front of the apron, which
    /// is ordered oldest first.
    ///
    /// **The document does not change here.** That is what keeps one page
    /// from being a visible insertion (R4); `feedOlder` moves five rows at a
    /// time when the view asks.
    private func bufferOlder(_ messages: [D.Message]) {
        guard !messages.contains(where: { Self.cost($0) > byteLimit }) else {
            stopWithError("TooLarge")
            return
        }
        var fresh: [Row] = []
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
                fresh.append(row)
            }
        }
        if !fresh.isEmpty {
            above.insert(contentsOf: fresh, at: 0)
        }
        trim()
        syncMarkdown()
    }

    /// The newer mirror: a context page after the document goes into the
    /// newer apron, oldest first.
    private func bufferNewer(_ messages: [D.Message]) {
        guard !messages.contains(where: { Self.cost($0) > byteLimit }) else {
            stopWithError("TooLarge")
            return
        }
        var fresh: [Row] = []
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
                fresh.append(row)
            }
        }
        if !fresh.isEmpty {
            below.append(contentsOf: fresh)
        }
        trim()
        syncMarkdown()
    }

    /// **The criterion-2 instrument** (task 3016): one line per block, so
    /// "how long did a page take" and "how many rows did it bring" are read
    /// off the log rather than judged by eye. `asked` is the request's own
    /// send time; the merge timestamp is shared by a queue that lands
    /// together.
    private static let blockLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-block"
    )
    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func logBlock(
        asked: Int64,
        mergedAt: Int64? = nil,
        before: Int,
        after: Int,
        pages: Int
    ) {
        let merged = mergedAt ?? nowMs()
        Self.blockLog.notice(
            "block: asked=\(asked, privacy: .public) merged=\(merged, privacy: .public) took=\(merged - asked, privacy: .public) rows=\(before, privacy: .public)->\(after, privacy: .public) pages=\(pages, privacy: .public)"
        )
    }

    /// The state `page` leaves the older loader in. **Completeness is not
    /// `stop == atEnd` alone**: the contract says only `at_end && !gap &&
    /// !restarted` is complete. A page that says `at_end` over damaged
    /// records, or after its captured range restarted, is a gap -- it must
    /// not draw "已到最早记录" and it must not draw an empty chat.
    private func settleOlder(_ page: H.Ready) {
        automaticAdvances = 0
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
    /// What an empty `budget` page may do next, or nil when it is a real
    /// page. **The termination rules are explicit**:
    ///
    /// - a page over damaged records, or after its captured range restarted,
    ///   is **not** carried on: `settleOlder` records the gap, and the token
    ///   stays in `historyTail` for a fresh ask;
    /// - a clean empty page is progress, but only up to
    ///   `maxAutomaticAdvances` in a row. Past that the scan stops with a
    ///   reason; the same token is never retried by the scan itself, and the
    ///   person's next ask starts a new run with a fresh budget.
    private enum OlderAdvance {
        case carryOn(String)
        case stop(why: String?)
    }

    private func olderAdvance(_ page: H.Ready) -> OlderAdvance? {
        guard page.messages.isEmpty, page.stop == .budget, let token = page.nextToken
        else { return nil }
        if page.gap || page.restarted { return .stop(why: nil) }
        guard automaticAdvances < Self.maxAutomaticAdvances else {
            return .stop(why: "the history scan kept advancing over empty pages")
        }
        return .carryOn(token)
    }

    private func scheduleOlderAdvance(token: String, generation: UInt64) {
        guard olderAdvanceToken == nil, started else { return }
        automaticAdvances += 1
        older = .scanning
        olderAdvanceToken = scheduler.after(Self.olderAdvanceDelay) { [weak self] in
            self?.olderAdvanceToken = nil
            guard let self, self.generation == generation else { return }
            // **An empty page carries no rows, so the size does not matter**:
            // the same floor keeps the scan moving.
            self.beginContinuation(
                token: token, automatic: true,
                limit: ControlRoomChatFeed.olderChunkFloor
            )
        }
    }

    /// A page that could not be read. The resume token stays in
    /// `historyTail`, so the person's "try again" asks for the same range
    /// rather than starting over -- **after the cooldown**: an immediately
    /// re-askable failure is one request per scroll event while the core
    /// keeps refusing.
    private func failOlder(_ why: String) {
        olderJobID = nil
        olderRequestID = nil
        olderToken = nil
        older = .failed(why)
        if case .loading = state {
            state = rows.isEmpty ? .failed(why) : .ready
            canReload = true
        }
        holdOlderBack()
    }

    /// Stop the top edge asking again for one cooldown period. Scheduled on
    /// the feed's own clock, so a test steps it instead of waiting.
    private func holdOlderBack() {
        guard olderCooldownToken == nil else { return }
        let generation = self.generation
        olderCoolingDown = true
        olderCooldownToken = scheduler.after(Self.olderFailureCooldown) { [weak self] in
            self?.olderCooldownToken = nil
            guard let self, self.generation == generation else { return }
            self.olderCoolingDown = false
        }
    }

    /// A new lifecycle (or the person cancelling) is not held back by a
    /// failure from the old one.
    private func clearOlderCooldown() {
        if let olderCooldownToken { scheduler.cancel(olderCooldownToken) }
        olderCooldownToken = nil
        olderCoolingDown = false
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
        // **The view's land-and-highlight effect is keyed on this**, not on
        // `generation` (which also moves for a stop, a reload and a session
        // change) and not on the anchor's value (a second locate of the same
        // result must land again). A successful locate does not move it
        // again, or one locate would land twice.
        locateEpoch &+= 1
        cancelJob()
        cancelScheduling()
        generation &+= 1
        // **The new generation reaches the Markdown store now, not when the
        // around page lands.** The view is re-rendered before that answer
        // arrives: a row that outlives the replacement is handed the new
        // generation, releases its old demand and asks again. A store still
        // on the old generation refused that ask, nothing asked again, and
        // the row drew its original Markdown for ever -- no rendered body,
        // and no word-level search highlight, which only the Markdown path
        // has. `start`, `stop`, `restartLoad` and a session change all hand
        // the store the new generation at once; the locate is the one that
        // did not (task 2994).
        syncMarkdown()
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

    /// One context page in either direction. **Idempotent like the plain
    /// older load**: while a begin or a poll is out (`locateRequestID` /
    /// `locateJobID`) the next call refuses, so the top edge's per-event call
    /// is one request. **A body with rows keeps its `state`**: the around
    /// page settled it, and a context page only adds rows; the one place a
    /// state word is written is the `case .loading` guard in `handleContext`,
    /// which cannot fire for a body that already has rows. A failure holds
    /// both directions back for `olderFailureCooldown` (`failLocate`).
    func loadContextOlder() {
        guard let context, let token = context.olderToken,
              !context.olderAtEnd, !contextOlderStale,
              locateJobID == nil, locateRequestID == nil,
              !olderCoolingDown, started, let group
        else { return }
        contextOlderStale = false
        sendContextBegin(group: group, token: token, direction: .older)
    }

    func loadContextNewer() {
        guard let context, let token = context.newerToken,
              !context.newerAtEnd, !contextNewerStale,
              locateJobID == nil, locateRequestID == nil,
              !olderCoolingDown, started, let group
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
            group: group, requestID: requestID, anchor: anchor,
            before: locateWindowRows, after: locateWindowRows,
            location: location
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
            // **The target must be a row the window kept.** `replaceWindow`
            // trims to the window's bound, and with no reading anchor yet it
            // drops from the front -- which can be the target itself. A
            // located window whose row is not there has nothing to mark and
            // nothing to put the viewport on; say so rather than leave the
            // list at the top of a window with no mark in it (task 2999 ④).
            switch locatedAnchor {
            case let target? where byAnchor[target] != nil:
                reading(anchor: target, offset: 0)
            case .some:
                locateTrouble = "TargetNotInWindow"
            case .none:
                locateTrouble = "NoTarget"
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
                group: group, requestID: requestID, resumeToken: token,
                limit: Self.contextChunk
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
        // **A context page lands at once too** (R4): the same aprons the
        // plain scan fills, fed to the document five rows at a time. There
        // is no hold to wait out, so a reader inside a located window gets
        // the same smoothness as one reading the live conversation.
        applyContext(page, jobID: jobID, expectedDirection: pendingContextDirection)
    }

    /// Land a context page: put it in its apron, take both cursors, and say
    /// which edge was released.
    private func applyContext(
        _ page: ControlRoomChatContext.Context,
        jobID: String,
        expectedDirection: ControlRoomChatContext.Direction?
    ) {
        guard page.page.jobID == jobID, page.page.group == group,
              session == nil || page.page.session == session
        else {
            failLocate("CursorMismatch")
            return
        }
        if session == nil { session = page.page.session }
        if let expectedDirection, expectedDirection != page.direction {
            failLocate("CursorMismatch")
            return
        }
        pendingContextDirection = nil
        pendingContextToken = nil
        let beforeFirst = loadedFirstID
        let beforeLast = loadedLastID
        if page.direction == .older {
            bufferOlder(page.page.messages)
        } else {
            bufferNewer(page.page.messages)
        }
        context = ContextTail(
            olderToken: page.page.olderToken,
            newerToken: page.page.newerToken,
            olderAtEnd: page.page.olderAtEnd,
            newerAtEnd: page.page.newerAtEnd
        )
        if locateJobID == jobID { locateJobID = nil }
        locateTrouble = nil
        locating = false
        // **A released edge makes a cursor stale.** The page's own edge must
        // still be at the loaded set's end; if the ceiling dropped it, the
        // next request would cross a run nobody kept. Re-anchoring around
        // the retained edge is the recovery; the host never advances that
        // token. **The loaded edge, not the document's**: the document is a
        // window that moves, and its first row is meant to change.
        let expectedFirst = page.direction == .older
            ? page.page.messages.first?.anchor : beforeFirst
        let expectedLast = page.direction == .newer
            ? page.page.messages.last?.anchor : beforeLast
        if let expectedFirst, loadedFirstID != expectedFirst {
            contextOlderStale = true
        }
        if let expectedLast, loadedLastID != expectedLast {
            contextNewerStale = true
        }
        if case .loading = state { state = rows.isEmpty ? .empty : .ready }
    }

    /// The oldest row this feed still holds, whether it is in the document
    /// or in the older apron.
    private var loadedFirstID: String? { above.first?.id ?? rows.first?.id }
    /// The newest row this feed still holds.
    private var loadedLastID: String? { below.last?.id ?? rows.last?.id }

    private func failLocate(_ why: String) {
        // **A failure must not look like a success.** `locate()` writes the
        // anchor optimistically, before the window around it exists; leaving
        // it there drew the row it named as the located one while nothing
        // had landed (task 2999 ④). Only a locate is rolled back: a context
        // page's failure arrives after the around window did, with
        // `locating` already false, and the window it was reading is still
        // the right one.
        if locating {
            locatedAnchor = nil
            // **Only a locate's own failure moves the epoch.** This method
            // also carries a located window's context failures, and those
            // arrive with `locatedAnchor` still standing and `locating`
            // already false: bumping there would make the view treat a
            // failed "older context" page as a new locate and drag the
            // reader back to the search target. A second failure of the
            // same anchor must still be observable, so it moves here.
            locateEpoch &+= 1
        }
        locateTrouble = why
        locating = false
        locateJobID = nil
        locateRequestID = nil
        cancelLocateScheduling()
        // **The live read comes back.** `locate()` cancelled the schedule at
        // its first line; a locate that fails must not leave the group
        // without a live read -- after a search jump became the main path,
        // one failure would mean this group never shows a new message again,
        // which reads as "nobody is talking". `armLive` is idempotent (it
        // does nothing while a token stands).
        armLive()
        // A located window's cursor is loaded from the same top edge as the
        // plain one, so its failures need the same cooling-off: otherwise
        // every scroll event re-asks a core that has already refused.
        holdOlderBack()
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
        // A cooldown belongs to the lifecycle that failed; the next one
        // starts unheld.
        clearOlderCooldown()
    }

    /// Best effort, once: a job whose answer nobody will read is still a job
    /// scanning the disk. A cancel that fails is not reported -- it must not
    /// raise a notification or merge an old page.
    private func cancelJob() {
        // **Every job of a lifecycle already gone.** `stop`/`deinit` cancel
        // the bootstrap, the older scan and the locate job together: one
        // left running is a job scanning a disk for an answer nobody will
        // draw. A buffered row needs no canceling: it is already ours, and a
        // lifecycle change empties the aprons with the document.
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
        if Self.cost(m) > byteLimit {
            stopWithError("TooLarge")
            return false
        }
        let byA = byAnchor[m.anchor]
        let byL = m.liveAnchor.flatMap { byAlias[$0] }
        if let a = byA, let l = byL, a != l {
            // Two rows turn out to be one message. **The one that was here
            // first keeps its display id**, whichever map found it -- and
            // "here first" is its place in the loaded sequence, not its
            // place in the document: the two rows may be on different sides
            // of the window now (R4's aprons).
            let keepA = loadedIndex(of: a) <= loadedIndex(of: l)
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
        guard let i = storeIndex(of: id) else { return }
        let old = storeMessage(at: i)
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
        setStoreMessage(m, at: i)
        trim()
    }

    /// Where a loaded row lives: the document, or one of the aprons. **A
    /// message the reader has scrolled past is still held** (R4), and a live
    /// read may update it.
    private enum Store {
        case document(Int)
        case above(Int)
        case below(Int)
    }

    private func storeIndex(of id: String) -> Store? {
        if let i = rows.firstIndex(where: { $0.id == id }) { return .document(i) }
        if let i = above.firstIndex(where: { $0.id == id }) { return .above(i) }
        if let i = below.firstIndex(where: { $0.id == id }) { return .below(i) }
        return nil
    }

    /// A row's place in the loaded sequence (older apron, document, newer
    /// apron), or `.max` when it is not loaded. Used to keep the earlier of
    /// two rows that turn out to be one message.
    private func loadedIndex(of id: String) -> Int {
        if let i = above.firstIndex(where: { $0.id == id }) { return i }
        if let i = rows.firstIndex(where: { $0.id == id }) { return above.count + i }
        if let i = below.firstIndex(where: { $0.id == id }) {
            return above.count + rows.count + i
        }
        return .max
    }

    private func storeMessage(at store: Store) -> D.Message {
        switch store {
        case let .document(i): return rows[i].message
        case let .above(i): return above[i].message
        case let .below(i): return below[i].message
        }
    }

    private func setStoreMessage(_ m: D.Message, at store: Store) {
        switch store {
        case let .document(i): rows[i].message = m
        case let .above(i): above[i].message = m
        case let .below(i): below[i].message = m
        }
    }

    private func insert(_ m: D.Message) {
        let row = Row(id: m.anchor, message: m)
        byAnchor[m.anchor] = row.id
        if let live = m.liveAnchor {
            aliasesOf[row.id, default: []].insert(live)
            byAlias[live] = row.id
        }
        bytes += Self.cost(m)
        // **A live message belongs to the newest end of what is loaded**, and
        // when the reader has walked away from it the document no longer
        // holds that end (R4). Appending to the document there would put a
        // new message under rows the reader has not reached yet.
        if !below.isEmpty {
            below.append(row)
            trim()
            return
        }
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
        if messages.contains(where: { Self.cost($0) > byteLimit }) {
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
        guard let store = storeIndex(of: dropID) else { return }
        let dropped = storeMessage(at: store)
        switch store {
        case let .document(i): rows.remove(at: i)
        case let .above(i): above.remove(at: i)
        case let .below(i): below.remove(at: i)
        }
        bytes -= Self.cost(dropped)
        if let canonical = byAnchor[dropped.anchor], canonical == dropID {
            byAnchor.removeValue(forKey: canonical)
            aliasesOf[keepID, default: []].insert(canonical)
            byAlias[canonical] = keepID
        }
        for alias in aliasesOf.removeValue(forKey: dropID) ?? [] {
            aliasesOf[keepID, default: []].insert(alias)
            byAlias[alias] = keepID
        }
    }

    /// **The memory ceiling** -- not the window's shape. The window moves
    /// rows between the document and its aprons by height
    /// (`ControlRoomChatWindow`); this only runs when the retainer itself is
    /// over its bound, and it drops records for real.
    ///
    /// **The far apron goes first, a step at a time**, because a dropped
    /// record is gone: there is no forward history cursor to read it back
    /// with, so the list must say a run was released rather than draw a
    /// false neighbour. Only when both aprons are empty does the document
    /// itself give -- from the end farthest from the camera, never the
    /// camera's own row, and never the last row (the list below a `.ready`
    /// header must have something to draw).
    ///
    /// **The bytes outrank the row ceiling** (R2-5): both are backstops now,
    /// and a global `rowLimit` of five thousand is no longer the shape of
    /// the window.
    private func trim() {
        var guardCount = 0
        while bytes > byteLimit || retainedRows > rowLimit {
            guardCount += 1
            if guardCount > 10_000 { break }
            if !trimOneBlock() { break }
        }
        if bytes < 0 { bytes = 0 }
    }

    private var retainedRows: Int { rows.count + above.count + below.count }

    /// One block out of the far apron, else one block out of the document's
    /// far end. False when there is nothing that may go.
    private func trimOneBlock() -> Bool {
        let block = Self.trimBlockRows
        let cameraIndex = readingAnchor.flatMap { anchor in
            rows.firstIndex(where: { $0.id == anchor })
        }
        // The apron farthest from the camera gives first: with no camera,
        // the older one is the far one.
        let olderIsFar: Bool
        if let cameraIndex {
            // The far side is the one with more rows between it and the
            // camera. A reader at the document's top is nearest the older
            // apron, so the newer end is what gives.
            olderIsFar = cameraIndex >= rows.count - cameraIndex - 1
        } else {
            olderIsFar = true
        }
        if olderIsFar, !above.isEmpty {
            drop(above.prefix(min(block, above.count)), from: .above)
            trimmedBefore = loadedFirstID
            return true
        }
        if !below.isEmpty {
            drop(below.suffix(min(block, below.count)), from: .below)
            trimmedAfter = loadedLastID
            return true
        }
        // **The aprons are empty**: the document itself gives, from the far
        // end, and a real gap is said. Never the camera's row and never the
        // last row.
        guard rows.count > 1 else { return false }
        guard let cameraIndex else {
            let take = min(block, rows.count - 1)
            drop(rows.prefix(take), from: .documentFront)
            trimmedBefore = rows.first?.id
            return true
        }
        let front = cameraIndex
        let back = rows.count - cameraIndex - 1
        if front >= back, front > 0 {
            let take = min(block, front)
            drop(rows.prefix(take), from: .documentFront)
            trimmedBefore = rows.first?.id
            return true
        }
        if back > 0 {
            let take = min(block, back)
            drop(rows.suffix(take), from: .documentBack)
            trimmedAfter = rows.last?.id
            return true
        }
        return false
    }

    /// **How many records one ceiling drop may take.** An eviction block, in
    /// the units the page was once read in -- small enough that the list's
    /// own total does not lurch.
    static let trimBlockRows = 5

    private enum DropSide {
        case above
        case below
        case documentFront
        case documentBack
    }

    private func drop(_ rows: ArraySlice<Row>, from side: DropSide) {
        for row in rows {
            bytes -= Self.cost(row.message)
            forget(row)
        }
        switch side {
        case .above:
            above.removeFirst(rows.count)
        case .below:
            below.removeLast(rows.count)
        case .documentFront:
            self.rows.removeFirst(rows.count)
        case .documentBack:
            self.rows.removeLast(rows.count)
        }
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
        above = []
        below = []
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
