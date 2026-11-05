import Foundation
import Testing

@testable import Ghostty

/// A parse executor a test steps by hand: one half is the work that would run
/// off the main thread, the other is the answer coming back. Nothing here
/// sleeps, so "the parse had not run when the main flow returned" is an
/// assertion rather than a hope.
final class ManualMarkdownExecutor: ControlRoomChatMarkdownExecutor {
    private var starts: [() -> Void] = []
    private var finishes: [() -> Void] = []
    /// How many parse blocks the store has **ever** handed over. `starts`
    /// is a work queue and drains as the test runs it; this is the count the
    /// assertions mean.
    private var performed = 0

    var startsCount: Int { performed }
    var finishesCount: Int { finishes.count }

    func perform(_ work: @escaping () -> Void) {
        performed += 1
        starts.append(work)
    }

    func finish(_ work: @escaping () -> Void) {
        finishes.append(work)
    }

    /// Run the next parse block, which is where the production answer is
    /// produced; its completion is queued, not applied.
    func runNextParse() {
        guard !starts.isEmpty else { return }
        starts.removeFirst()()
    }

    /// Apply the next completed answer.
    func deliverNext() {
        guard !finishes.isEmpty else { return }
        finishes.removeFirst()()
    }
}

/// The redraws a store asked for, and a way to deliver them without a run
/// loop: the production one is one turn of the main queue.
private final class ManualRedraws {
    private var work: [() -> Void] = []
    var count: Int { work.count }

    func ask(_ run: @escaping () -> Void) { work.append(run) }

    func deliver() {
        while !work.isEmpty { work.removeFirst()() }
    }
}

/// The feed's Markdown store (task 2800 C2b-1, contract v2): the window is a
/// set of values, the rows on screen are the demand, and only the demanded
/// keys missing from a bounded, pinned cache are parsed.
struct ControlRoomChatMarkdownStoreTests {
    typealias Store = ControlRoomChatMarkdownStore

    private func row(
        _ n: Int,
        group: String = "polter",
        version: UInt64 = 1,
        text: String = "# hi"
    ) -> Store.Snapshot {
        Store.Snapshot(id: "r\(n)", group: group, anchor: "p:\(n)", version: version, text: text)
    }

    private func content(
        _ store: Store,
        _ row: Store.Snapshot,
        generation: UInt64 = 1
    ) -> Store.Content {
        store.content(id: row.id, group: row.group, generation: generation, text: row.text)
    }

    private func drain(_ executor: ManualMarkdownExecutor, _ times: Int) {
        for _ in 0..<times {
            executor.runNextParse()
            executor.deliverNext()
        }
    }

    /// ⚠️ **The raw window is not a parse request.** Five hundred resident
    /// rows with ten rows instantiated parse ten times; twenty repetitions of
    /// an empty live/window sync neither parse more nor downgrade the ten.
    @Test func testOnlyInstantiatedRowsAreParsedAndEmptySyncsChangeNothing() {
        let executor = ManualMarkdownExecutor()
        let store = Store(executor: executor)
        let rows = (1...500).map { row($0) }

        store.update(group: "polter", generation: 1, rows: rows, active: true)
        #expect(executor.startsCount == 0)

        for n in 1...10 {
            store.acquire("r\(n)", group: "polter", generation: 1)
        }
        drain(executor, 10)
        #expect(executor.startsCount == 10)

        for _ in 0..<20 {
            store.update(group: "polter", generation: 1, rows: rows, active: true)
        }
        #expect(executor.startsCount == 10)
        for n in 1...10 {
            #expect(content(store, row(n)) != .pending(text: "# hi"))
            guard case .markdown = content(store, row(n)) else {
                Issue.record("row \(n) was downgraded by an empty sync")
                return
            }
        }
    }

    /// Scrolling to a new set of rows parses the new demand and does not
    /// re-queue the rows that left.
    @Test func testNewDemandParsesAndReleasedRowsAreNotRequeued() {
        let executor = ManualMarkdownExecutor()
        let store = Store(executor: executor)
        let rows = (1...500).map { row($0) }
        store.update(group: "polter", generation: 1, rows: rows, active: true)

        for n in 1...10 { store.acquire("r\(n)", group: "polter", generation: 1) }
        drain(executor, 10)
        #expect(executor.startsCount == 10)

        for n in 1...10 { store.release("r\(n)", group: "polter", generation: 1) }
        for _ in 0..<5 {
            store.update(group: "polter", generation: 1, rows: rows, active: true)
        }
        #expect(executor.startsCount == 10)
        #expect(content(store, row(1)) == .plain(text: "# hi"))

        for n in 11...20 { store.acquire("r\(n)", group: "polter", generation: 1) }
        drain(executor, 10)
        #expect(executor.startsCount == 20)
    }

    /// A full cache keeps the rows it is pinning. The next demand is
    /// `deferredBudget` -- its original text said plainly, no spinner, no
    /// self-retry -- and one release lets it in.
    @Test func testCacheFullKeepsPinnedRowsAndDefersTheRestUntilOneIsReleased() {
        let executor = ManualMarkdownExecutor()
        let store = Store(
            executor: executor,
            cache: .init(maxEntries: 2, maxBytes: 1_000_000)
        )
        let rows = (1...5).map { row($0) }
        store.update(group: "polter", generation: 1, rows: rows, active: true)

        for n in 1...3 { store.acquire("r\(n)", group: "polter", generation: 1) }
        drain(executor, 2)
        #expect(executor.startsCount == 2)
        #expect(content(store, row(3)) == .deferredBudget(text: "# hi"))

        for _ in 0..<20 {
            store.update(group: "polter", generation: 1, rows: rows, active: true)
        }
        #expect(executor.startsCount == 2)
        #expect(content(store, row(3)) == .deferredBudget(text: "# hi"))

        store.release("r1", group: "polter", generation: 1)
        drain(executor, 1)
        #expect(executor.startsCount == 3)
        guard case .markdown = content(store, row(3)) else {
            Issue.record("the deferred row was not admitted after a release")
            return
        }
        #expect(content(store, row(1)) == .plain(text: "# hi"))
    }

    /// Only one over-budget message may be held by a row at a time; a second
    /// waits as plain text with the budget said out loud, and releasing the
    /// first lets it in.
    @Test func testOnlyOneOversizedMessageIsHeld() {
        let executor = ManualMarkdownExecutor()
        let store = Store(
            executor: executor,
            cache: .init(maxEntries: 10, maxBytes: 4)
        )
        let first = Store.Snapshot(id: "r1", group: "polter", anchor: "p:1", version: 1, text: "12345")
        let second = Store.Snapshot(id: "r2", group: "polter", anchor: "p:2", version: 1, text: "67890")
        store.update(group: "polter", generation: 1, rows: [first, second], active: true)

        store.acquire("r1", group: "polter", generation: 1)
        drain(executor, 1)
        #expect(executor.startsCount == 1)
        #expect(store.cachedCount == 0)
        guard case .markdown = content(store, first) else {
            Issue.record("the one oversized message was not shown")
            return
        }

        store.acquire("r2", group: "polter", generation: 1)
        #expect(content(store, second) == .deferredBudget(text: "67890"))

        store.release("r1", group: "polter", generation: 1)
        drain(executor, 1)
        #expect(executor.startsCount == 2)
        guard case .markdown = content(store, second) else {
            Issue.record("the released oversized slot was not reused")
            return
        }
        #expect(content(store, first) == .plain(text: "12345"))
    }

    /// A new generation drops the old answer, and an old release cannot
    /// release the new page's demand.
    @Test func testStaleCompletionAndStaleReleaseDoNotTouchTheNewGeneration() {
        let executor = ManualMarkdownExecutor()
        let store = Store(executor: executor)
        let rows = [row(1)]
        store.update(group: "polter", generation: 1, rows: rows, active: true)
        store.acquire("r1", group: "polter", generation: 1)
        executor.runNextParse() // generation 1 answer on its way

        store.update(group: "polter", generation: 2, rows: rows, active: true)
        store.acquire("r1", group: "polter", generation: 2)
        // The old page's release names generation 1: it must not release the
        // generation-2 demand.
        store.release("r1", group: "polter", generation: 1)

        executor.deliverNext() // generation 1 completes: dropped
        #expect(store.document(group: "polter", anchor: "p:1", version: 1) == nil)
        #expect(executor.startsCount == 2)

        executor.runNextParse()
        executor.deliverNext()
        guard case .markdown = content(store, row(1), generation: 2) else {
            Issue.record("the old release took the new demand with it")
            return
        }
        #expect(content(store, row(1), generation: 1) == .plain(text: "# hi"))
    }

    /// The same anchor at a new version is a new demand; the old answer is
    /// not drawn under the new version.
    @Test func testANewVersionIsANewDemandAndTheOldAnswerIsNotDrawn() {
        let executor = ManualMarkdownExecutor()
        let store = Store(executor: executor)
        let old = row(1, version: 1, text: "# old")
        store.update(group: "polter", generation: 1, rows: [old], active: true)
        store.acquire("r1", group: "polter", generation: 1)
        executor.runNextParse()

        let new = row(1, version: 2, text: "# new")
        store.update(group: "polter", generation: 1, rows: [new], active: true)
        executor.deliverNext() // the version-1 answer: no demand any more
        #expect(content(store, new) == .pending(text: "# new"))

        executor.runNextParse()
        executor.deliverNext()
        guard case .markdown = content(store, new) else {
            Issue.record("the new version never got its own document")
            return
        }
        #expect(store.document(group: "polter", anchor: "p:1", version: 2) != nil)
    }

    /// Repeating `acquire` for the same row is one demand and one parse.
    @Test func testRepeatedAcquireIsIdempotent() {
        let executor = ManualMarkdownExecutor()
        let store = Store(executor: executor)
        let rows = [row(1)]
        store.update(group: "polter", generation: 1, rows: rows, active: true)
        store.acquire("r1", group: "polter", generation: 1)
        store.acquire("r1", group: "polter", generation: 1)
        drain(executor, 1)
        #expect(executor.startsCount == 1)
        #expect(store.cachedCount == 1)
    }

    /// Demand is admitted in instantiation order up to the cache's own
    /// budget; the rest are deferred, not queued.
    @Test func testAdmissionStopsAtTheCacheBudgetAndTheRestAreDeferred() {
        let executor = ManualMarkdownExecutor()
        let store = Store(executor: executor)
        let rows = (1...500).map { row($0) }
        store.update(group: "polter", generation: 1, rows: rows, active: true)
        for n in 1...500 { store.acquire("r\(n)", group: "polter", generation: 1) }

        #expect(executor.startsCount == 1)
        #expect(store.queuedCount == Store.cacheEntries - 1)
        #expect(content(store, row(Store.cacheEntries + 1))
            == .deferredBudget(text: "# hi"))
    }

    /// **A demand the cache can already answer must say so.** `reconsider`
    /// queues only what it has to parse; a cached key queues nothing, so no
    /// completion publishes and nothing asks the row to draw again. On the
    /// real app the whole trace stopped at `admitted=5`: no parse, no second
    /// `content`, and the located rows kept their original Markdown for ever
    /// (task 2994). One redraw is the missing turn.
    @Test func testADemandAnsweredFromTheCacheAsksForARedraw() {
        let executor = ManualMarkdownExecutor()
        let redraws = ManualRedraws()
        let store = Store(executor: executor, redraw: redraws.ask)
        let rows = [row(1)]
        store.update(group: "polter", generation: 1, rows: rows, active: true)
        store.acquire("r1", group: "polter", generation: 1)
        drain(executor, 1)
        #expect(store.cachedCount == 1)

        // The page moves on: the demand is dropped, the document stays.
        store.update(group: "polter", generation: 2, rows: rows, active: true)
        #expect(redraws.count == 0)
        let before = store.revision

        store.acquire("r1", group: "polter", generation: 2)
        #expect(redraws.count == 1)

        redraws.deliver()
        #expect(store.revision == before &+ 1)
        guard case .markdown = content(store, row(1), generation: 2) else {
            Issue.record("a row admitted from the cache still draws its original text")
            return
        }
    }

    /// The other half: a demand that has to be parsed asks for no redraw of
    /// its own -- the parse's completion is what publishes.
    @Test func testADemandThatMustBeParsedDoesNotAskForARedraw() {
        let executor = ManualMarkdownExecutor()
        let redraws = ManualRedraws()
        let store = Store(executor: executor, redraw: redraws.ask)
        store.update(group: "polter", generation: 1, rows: [row(1)], active: true)
        store.acquire("r1", group: "polter", generation: 1)
        #expect(redraws.count == 0)
        #expect(executor.startsCount == 1)
    }
}
