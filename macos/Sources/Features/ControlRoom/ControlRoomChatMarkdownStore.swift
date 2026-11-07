import Combine
import Foundation

/// Where a Markdown parse runs and where its answer comes back (task 2800
/// C2b-1, contract §线程与内存).
///
/// **A hand-in, so a test can hold the two halves apart.** The production
/// one is a serial background queue and a main-queue completion; a test hands
/// in one that only records the blocks, which is how "nothing was parsed
/// before the main flow returned" can be asserted instead of slept at.
protocol ControlRoomChatMarkdownExecutor: AnyObject {
    /// Run `work` on the one serial parse executor.
    func perform(_ work: @escaping () -> Void)
    /// Run `work` back where the store lives.
    func finish(_ work: @escaping () -> Void)
}

/// The production executor: one serial background queue, completions on the
/// main queue. `ControlRoomChatMarkdown.parse` is Foundation's and has no
/// affinity to either.
final class ControlRoomChatMarkdownBackgroundExecutor: ControlRoomChatMarkdownExecutor {
    /// **One lane for every feed.** The container may hold four feeds, each
    /// with its own store; one executing parse at a time is a property of
    /// the machine, not of one store, so the queue is shared.
    private static let queue = DispatchQueue(
        label: "polter.controlroom.chat.markdown",
        qos: .background
    )

    func perform(_ work: @escaping () -> Void) {
        Self.queue.async(execute: work)
    }

    func finish(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}

/// One feed's parsed messages (task 2800 C2b-1, contract v2): the only place
/// the page's Markdown is parsed, and the only place its answers are kept.
///
/// ⚠️ **The feed's raw window is not a parse request.** Five hundred messages
/// may be resident and only ten rows instantiated; only the instantiated rows
/// ask for work, through `acquire`. An empty live answer that changes nothing
/// asks for nothing, so it cannot re-parse the window or turn a drawn row
/// back into plain text.
///
/// **It is told values, never the core.** `update` is handed the group, the
/// feed's generation, and the window rows' `(id, anchor, contentVersion,
/// text)` snapshots; the executor is handed a `String` and returns a
/// `Document`. Nothing here can reach `Ghostty.App`, a surface or the C ABI,
/// so a parse that outlives the page cannot touch a released app.
///
/// **One parse at a time, off the main thread.** A request is queued by
/// identity -- group, opaque anchor and version -- so the same row asked for
/// twice is parsed once. A result is published only while all three still
/// match, and only while its generation is the feed's current one: a group
/// switch, `stop`, a new session or the feed going away each move the
/// generation, and the answer that was already running is dropped when it
/// comes back.
///
/// **Admission is a budget, not a queue-length.** Pinned entries (the rows
/// actually instantiated now) plus the source bytes already promised to the
/// queue and the one parse in flight are counted against the 200-message /
/// 4 MiB parse cache. A demand that does not fit is `deferredBudget`: it is
/// not queued, is shown as its original text with a word about the budget,
/// and is only tried again when the demand set changes -- never on a timer.
final class ControlRoomChatMarkdownStore: ObservableObject {
    typealias Key = ControlRoomChatMarkdown.Cache.Key
    typealias Document = ControlRoomChatMarkdown.Document

    /// One window row, as the store needs it. A value: the text is copied on
    /// the way in, so the background parse holds no message.
    struct Snapshot: Equatable {
        /// The feed's stable display id (`Feed.Row.id`).
        var id: String
        var group: String
        var anchor: String
        var version: UInt64
        var text: String

        var key: Key { Key(group: group, anchor: anchor, version: version) }
        var cost: Int { text.utf8.count }
    }

    /// What a row draws now.
    enum Content: Equatable {
        case markdown(Document)
        /// Admitted and waiting for the one serial parse (queued or running).
        case pending(text: String)
        /// Demanded, but the budget has no room for it: its original text,
        /// **not** a spinner and not a retry of its own.
        case deferredBudget(text: String)
        /// Not demanded yet (a row that has not been instantiated), or a
        /// demand whose window row is gone.
        case plain(text: String)
    }

    /// Bumped when what a row should draw changes, so a SwiftUI body reading
    /// `content` is asked to draw again.
    @Published private(set) var revision = 0

    private struct Demand {
        var group: String
        var generation: UInt64
    }

    private let executor: ControlRoomChatMarkdownExecutor
    private var cache = ControlRoomChatMarkdown.Cache()
    /// The single oversized message allowed to be shown from a row's own hold
    /// (over the cache's byte budget), and only while that row is demanded.
    private var oversized: (key: Key, document: Document)?
    /// The oversized key admission chose; its parse must not go through the
    /// cache (it would not fit) but through `oversized`.
    private var admittedOversized: Key?

    private var group = ""
    private var generation: UInt64 = 0
    private var active = false

    private var window: [String: Snapshot] = [:]
    private var windowSignature: [String] = []

    private var demands: [String: Demand] = [:]
    private var demandOrder: [String] = []

    /// Keys the current demands admitted, and keys they could not admit.
    private var admitted: Set<Key> = []
    private var deferred: Set<Key> = []

    private var queue: [Key] = []
    private var queued: Set<Key> = []
    private var sources: [Key: String] = [:]
    private var inFlight: Key?
    /// One redraw asked for and not yet delivered, so five rows admitted in
    /// one update are one turn of the main queue.
    private var redrawPending = false
    private let redraw: (@escaping () -> Void) -> Void

    init(
        executor: ControlRoomChatMarkdownExecutor = ControlRoomChatMarkdownBackgroundExecutor(),
        cache: ControlRoomChatMarkdown.Cache = .init(
            maxEntries: ControlRoomChatMarkdownStore.cacheEntries,
            maxBytes: ControlRoomChatMarkdownStore.cacheBytes
        ),
        /// **How "a drawn row's answer changed" reaches SwiftUI**: one turn
        /// of the main queue in production, a recorder in a test. It is a
        /// value because the store must be told, not sleep.
        redraw: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        }
    ) {
        self.executor = executor
        self.cache = cache
        self.redraw = redraw
    }

    /// The parse cache's budget and the window's own bound.
    static let cacheEntries = 200
    static let cacheBytes = 4 * 1024 * 1024
    static let queueLimit = 500

    // MARK: - The feed's window

    /// The feed's whole visible truth: its group, its generation, its window
    /// rows, and whether it is in front.
    ///
    /// **A no-change sync does nothing.** The live read answers every two
    /// seconds; an answer that brought no new message and no changed version
    /// leaves the signature identical, so the demanded set is not rebuilt
    /// and nothing already parsed is asked for again.
    func update(group: String?, generation: UInt64, rows: [Snapshot], active: Bool) {
        let named = group ?? ""
        var changed = false
        if named != self.group || generation != self.generation {
            self.group = named
            self.generation = generation
            changed = true
        }
        if active != self.active {
            self.active = active
            changed = true
        }

        self.window = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let signature = rows.map { "\($0.id)|\($0.anchor)|\($0.version)" }
        if signature != windowSignature {
            windowSignature = signature
            changed = true
        }

        guard active else {
            // Off the page: its demands, its queued work and the row-held
            // oversized document all go. The cache stays (bounded, unpinned).
            demands.removeAll()
            demandOrder.removeAll()
            clearWork()
            cache.setPinned([])
            return
        }

        // A demand from another generation or group is not this page's.
        let before = demands.count
        demands = demands.filter { $0.value.group == named && $0.value.generation == generation }
        demandOrder.removeAll { demands[$0] == nil }
        if demands.count != before { changed = true }

        if changed { reconsider() }
    }

    // MARK: - Demand

    /// A row was instantiated: it asks, and only asks. Repeated `acquire` is
    /// idempotent; a row from a newer generation replaces the old demand, so
    /// the release that follows for the old one cannot release it.
    func acquire(_ id: String, group: String, generation: UInt64) {
        guard active, group == self.group, generation == self.generation else { return }
        if let existing = demands[id],
           existing.group == group, existing.generation == generation {
            return
        }
        if demands[id] == nil { demandOrder.append(id) }
        demands[id] = Demand(group: group, generation: generation)
        reconsider()
        // **A demand the cache can already answer changes what the row draws,
        // and nothing else says so.** `reconsider` queues only what it has to
        // parse; a cached key queues nothing, so no completion publishes, and
        // the row that has just been admitted goes on drawing its original
        // text for ever (task 2994: demand=5, admitted=5, and not one further
        // `content` call in the log). Ask for one redraw.
        if let snapshot = window[id], cache.contains(snapshot.key) {
            redrawSoon()
        }
    }

    /// One turn of the run loop, at most one outstanding: the rows' bodies
    /// read `content`, so `revision` is what asks them again.
    private func redrawSoon() {
        guard !redrawPending else { return }
        redrawPending = true
        redraw { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            self.revision &+= 1
        }
    }

    /// A row went away. **A release carrying an older generation is not this
    /// row's release**: the demand it would match belongs to a page that has
    /// already moved on.
    func release(_ id: String, group: String, generation: UInt64) {
        guard let demand = demands[id],
              demand.group == group,
              demand.generation == generation
        else { return }
        demands.removeValue(forKey: id)
        demandOrder.removeAll { $0 == id }
        reconsider()
    }

    /// What this row draws, as of now. **A lookup, not a parse**: it is read
    /// from `body`.
    func content(id: String, group: String, generation: UInt64, text: String) -> Content {
        guard let demand = demands[id],
              demand.group == group,
              demand.generation == generation,
              generation == self.generation,
              let snapshot = window[id]
        else { return .plain(text: text) }

        let key = snapshot.key
        if let document = cache.document(key) {
            return .markdown(document)
        }
        if let oversized, oversized.key == key {
            return .markdown(oversized.document)
        }
        if key == inFlight || queued.contains(key) || admitted.contains(key) {
            return .pending(text: text)
        }
        if deferred.contains(key) {
            return .deferredBudget(text: text)
        }
        return .plain(text: text)
    }

    /// **What `content` would answer, and why** -- read only, for a row's
    /// `form:` line. It mirrors the branches of `content` above; if one changes,
    /// the other must. The point is to tell the *reasons* apart that all look
    /// like "this row got shorter": a missing demand, another group, a
    /// generation the store has moved past, a row outside its window, a key
    /// that is queued/admitted, a parse over budget, or a cache miss.
    func form(id: String, group: String, generation: UInt64) -> String {
        guard let demand = demands[id] else { return "plain:no-demand" }
        if demand.group != group { return "plain:other-group" }
        if demand.generation != generation { return "plain:demand-gen" }
        if generation != self.generation { return "plain:store-gen" }
        guard let snapshot = window[id] else { return "plain:no-window" }
        let key = snapshot.key
        if cache.document(key) != nil { return "markdown:cache" }
        if let oversized, oversized.key == key { return "markdown:oversized" }
        if key == inFlight { return "pending:inFlight" }
        if queued.contains(key) { return "pending:queued" }
        if admitted.contains(key) { return "pending:admitted" }
        if deferred.contains(key) { return "deferred:budget" }
        return "plain:uncached"
    }

    /// The store's own generation, for the same line.
    var formGeneration: UInt64 { generation }

    /// The kept document for one identity, or nil. For tests and inspection.
    func document(group: String, anchor: String, version: UInt64) -> Document? {
        cache.document(Key(group: group, anchor: anchor, version: version))
    }

    // MARK: - Admission

    /// Rebuild the admitted set from the current demands, in the order the
    /// rows were first instantiated. This is the only place that decides who
    /// may parse; a timer or an empty live answer never calls it.
    private func reconsider() {
        let ordered = demandOrder.filter {
            guard let demand = demands[$0] else { return false }
            return demand.group == group && demand.generation == generation && window[$0] != nil
        }

        var newAdmitted: Set<Key> = []
        var newDeferred: Set<Key> = []
        var bytes = 0
        var oversizedKey: Key?

        for id in ordered {
            guard let snapshot = window[id] else { continue }
            let key = snapshot.key
            if newAdmitted.contains(key) { continue }

            if snapshot.cost > cache.maxBytes {
                // One message over the whole budget may still be shown from
                // the row itself; a second at the same time waits.
                if oversizedKey == nil {
                    oversizedKey = key
                    newAdmitted.insert(key)
                } else {
                    newDeferred.insert(key)
                }
                continue
            }
            if newAdmitted.count + 1 > cache.maxEntries || bytes + snapshot.cost > cache.maxBytes {
                newDeferred.insert(key)
                continue
            }
            newAdmitted.insert(key)
            bytes += snapshot.cost
        }

        admitted = newAdmitted
        deferred = newDeferred
        admittedOversized = oversizedKey
        // A pinned entry never yields to a background completion; its pin is
        // its demand, and it is dropped the moment the demand is.
        cache.setPinned(admitted)
        if let oversized, !admitted.contains(oversized.key) {
            self.oversized = nil
        }

        // Rebuild the queue from the admitted keys that are not in hand, in
        // demand order. Work for a row that lost its demand is not kept.
        queue.removeAll()
        queued.removeAll()
        sources.removeAll()
        var seen: Set<Key> = []
        for id in ordered {
            guard let snapshot = window[id], admitted.contains(snapshot.key),
                  !seen.contains(snapshot.key)
            else { continue }
            seen.insert(snapshot.key)
            // The oversized document is in hand even though it is not in the
            // cache (it would not fit): do not parse it again on the next
            // demand change.
            if cache.contains(snapshot.key) || oversized?.key == snapshot.key
                || snapshot.key == inFlight { continue }
            guard queue.count < Self.queueLimit else { break }
            queue.append(snapshot.key)
            queued.insert(snapshot.key)
            sources[snapshot.key] = snapshot.text
        }
        pump()
    }

    // MARK: - The one parse

    private func pump() {
        guard active else { return }
        while inFlight == nil, !queue.isEmpty {
            let key = queue.removeFirst()
            queued.remove(key)
            guard !cache.contains(key), admitted.contains(key),
                  let text = sources.removeValue(forKey: key)
            else { continue }

            inFlight = key
            let generation = self.generation
            let executor = self.executor
            // The parse sees a `String` and nothing else -- no app, no feed,
            // no message value that could reach one.
            executor.perform { [weak self] in
                let document = ControlRoomChatMarkdown.parse(text)
                executor.finish { [weak self] in
                    self?.complete(key: key, document: document, text: text, generation: generation)
                }
            }
        }
    }

    private func complete(key: Key, document: Document, text: String, generation: UInt64) {
        inFlight = nil
        guard generation == self.generation else {
            // Another page's answer: dropped, not published. If the same
            // identity is demanded by the page that is here now, its parse
            // was skipped while this one ran, so it is asked again under the
            // current generation.
            if active, admitted.contains(key), !cache.contains(key) {
                sources[key] = text
                queued.insert(key)
                queue.insert(key, at: 0)
            }
            pump()
            return
        }
        if key == admittedOversized {
            oversized = (key, document)
            revision &+= 1
        } else if admitted.contains(key) {
            if cache.keep(document, text: text, for: key, pinned: true) {
                revision &+= 1
            } else {
                // The budget changed while it was being parsed: show the
                // original text rather than looping on the same task.
                deferred.insert(key)
                admitted.remove(key)
                cache.unpin(key)
                revision &+= 1
            }
        } else {
            // No demand any more (released while it ran): it may join the
            // ordinary bounded cache, but it pins nothing and publishes
            // nothing.
            cache.keep(document, text: text, for: key, pinned: false)
        }
        pump()
    }

    private func clearWork() {
        queue.removeAll()
        queued.removeAll()
        sources.removeAll()
        admitted.removeAll()
        deferred.removeAll()
        admittedOversized = nil
        oversized = nil
    }

    // MARK: - Bounds, for the tests and for the reader

    var cachedCount: Int { cache.count }
    var queuedCount: Int { queue.count }
    var isParsing: Bool { inFlight != nil }
}
