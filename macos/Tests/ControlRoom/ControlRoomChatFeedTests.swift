import Foundation
import Testing

@testable import Ghostty

/// The chat page's state machine (task 2800 S2c-2a): the bootstrap's first
/// screen, the live read beside it, one history scan at a time, and the
/// stable-identity window the rows live in.
///
/// **The door and the clock are injected.** `Ask` is a closure and the feed
/// only ever waits through `ControlRoomChatScheduling`, so every interleaving
/// below is driven by hand -- no `sleep`, no run loop, and no timer that
/// makes a failing test look like a slow one.
struct ControlRoomChatFeedTests {
    typealias Feed = ControlRoomChatFeed

    private let jobID = String(repeating: "a", count: 32)
    private let job2 = String(repeating: "b", count: 32)

    // MARK: - The wire, written the way the core writes it

    private func message(
        seq: UInt64 = 0,
        log: UInt64 = 10,
        anchor: String,
        liveAnchor: String? = nil,
        text: String = "hi",
        author: String = "worker",
        role: String? = nil,
        mentions: String = "null",
        contentVersion: UInt64 = 0
    ) -> String {
        let live = liveAnchor.map { "\"\($0)\"" } ?? "null"
        let roleField = role.map { "\"\($0)\"" } ?? "null"
        return """
        {"seq":\(seq),"log_seq":\(log),"from":"0x0000000000000001","from_self":false,\
        "author":"\(author)","at_ms":1700000000000,"summary":false,"channel":0,\
        "text":"\(text)","mentions":\(mentions),"role":\(roleField),"anchor":"\(anchor)",\
        "live_anchor":\(live),"content_version":\(contentVersion)}
        """
    }

    private func begin(
        group: String = "polter",
        session: String = "s1",
        job: String? = nil,
        liveSince: UInt64 = 5,
        historyUpper: UInt64 = 100,
        snapshot: [String] = []
    ) -> String {
        """
        {"ok":true,"state":"pending","job_id":"\(job ?? jobID)","group":"\(group)",\
        "session":"\(session)","live_since":\(liveSince),"history_upper":\(historyUpper),\
        "live_snapshot":[\(snapshot.joined(separator: ","))]}
        """
    }

    private func live(
        group: String = "polter",
        session: String = "s1",
        next: UInt64,
        more: Bool = false,
        messages: [String] = []
    ) -> String {
        """
        {"ok":true,"group":"\(group)","session":"\(session)","cursor":0,"since":0,\
        "next":\(next),"more":\(more),"messages":[\(messages.joined(separator: ","))]}
        """
    }

    private func status(_ state: String) -> String {
        """
        {"ok":true,"state":"\(state)","job_id":"\(jobID)","group":"polter","session":"s1"}
        """
    }

    private func ready(
        messages: [String] = [],
        stop: String = "at_end",
        token: String? = nil,
        gap: Bool = false,
        session: String = "s1",
        job: String? = nil
    ) -> String {
        let tokenField = token.map { "\"\($0)\"" } ?? "null"
        return """
        {"ok":true,"state":"ready","job_id":"\(job ?? jobID)","group":"polter",\
        "session":"\(session)","messages":[\(messages.joined(separator: ","))],\
        "stop":"\(stop)","next_token":\(tokenField),"restarted":false,"gap":\(gap)}
        """
    }

    private func failure(_ code: String, job: String? = nil) -> String {
        """
        {"ok":false,"error":"\(code)","job_id":"\(job ?? jobID)","group":"polter","session":"s1"}
        """
    }

    private func gateFailure(_ code: String) -> String {
        "{\"error\":\"\(code)\"}"
    }

    // MARK: - The rig

    private final class Door {
        var requests: [String] = []
        var reply: (String) -> Feed.Reply = { _ in .notReady }

        func ask(_ request: String) -> Feed.Reply {
            requests.append(request)
            return reply(request)
        }

        func methods(_ name: String) -> [String] {
            requests.filter { Self.method($0) == name }
        }

        func last(_ name: String) -> [String: Any]? {
            requests.last { Self.method($0) == name }.flatMap(Self.params)
        }

        static func json(_ request: String) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        }

        static func method(_ request: String) -> String? {
            json(request)?["method"] as? String
        }

        static func params(_ request: String) -> [String: Any]? {
            json(request)?["params"] as? [String: Any]
        }
    }

    private final class TestScheduler: ControlRoomChatScheduling {
        private struct Item {
            let token: UUID
            let delay: TimeInterval
            let work: () -> Void
        }

        private var items: [Item] = []
        private(set) var cancelled: [UUID] = []

        var count: Int { items.count }

        func delays() -> [TimeInterval] { items.map(\.delay) }

        func count(at delay: TimeInterval) -> Int {
            items.filter { abs($0.delay - delay) < 0.0001 }.count
        }

        func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> UUID {
            let token = UUID()
            items.append(Item(token: token, delay: delay, work: work))
            return token
        }

        func cancel(_ token: UUID) {
            cancelled.append(token)
            items.removeAll { $0.token == token }
        }

        /// Take one scheduled block without running it -- a response that
        /// was already on its way when the page was left.
        func take(_ delay: TimeInterval) -> (() -> Void)? {
            guard let i = items.firstIndex(where: { abs($0.delay - delay) < 0.0001 }) else {
                return nil
            }
            return items.remove(at: i).work
        }

        @discardableResult
        func run(_ delay: TimeInterval) -> Bool {
            guard let work = take(delay) else { return false }
            work()
            return true
        }
    }

    private final class Rig {
        let door = Door()
        let scheduler = TestScheduler()
        /// Parsing is driven by hand; these tests are about the feed, and a
        /// real background parse would run under an assertion.
        let executor = ManualMarkdownExecutor()
        lazy var markdown = ControlRoomChatMarkdownStore(executor: executor)
        lazy var feed = Feed(ask: door.ask, scheduler: scheduler, markdown: markdown)
    }

    // MARK: - The first screen

    /// The live snapshot is not the older page. Until the history scan
    /// answers, a page with an empty snapshot is **loading**, not empty --
    /// and the persisted messages it then answers with are the first screen.
    @Test func testTheFirstScreenComesFromPersistedHistoryWhenLiveIsEmpty() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                return .answer(self.ready(messages: [
                    self.message(anchor: "p:1"),
                    self.message(anchor: "p:2"),
                ]))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        #expect(rig.feed.state == .loading)
        #expect(rig.feed.rows.isEmpty)

        #expect(rig.scheduler.run(0.2))
        #expect(rig.feed.state == .ready)
        #expect(rig.feed.rows.map(\.id) == ["p:1", "p:2"])
        #expect(rig.feed.historyTail?.stop == .atEnd)
        #expect(rig.feed.historyTail?.nextToken == nil)
    }

    /// A pending poll is a page that has not answered; it is never drawn as
    /// an empty chat, and it arranges exactly one next poll rather than
    /// calling itself.
    @Test func testAPendingHistoryPageIsNotAnEmptyChatAndDoesNotRecurse() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        #expect(rig.feed.state == .loading)
        #expect(rig.scheduler.count(at: 0.2) == 1)

        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .loading)
        #expect(rig.feed.rows.isEmpty)
        #expect(rig.door.methods("chat_history_poll").count == 1)
        #expect(rig.scheduler.count(at: 0.2) == 1)
    }

    /// A page that answered with no messages is empty, and a gap with no
    /// resume point is a whole answer, not a malformed one.
    @Test func testAnAnsweredEmptyPageIsEmptyAndAGapWithoutATokenIsKept() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                return .answer(self.ready(messages: [], stop: "gap", token: nil, gap: true))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .empty)
        #expect(rig.feed.historyTail?.stop == .gap)
        #expect(rig.feed.historyTail?.nextToken == nil)
        #expect(rig.feed.historyTail?.gap == true)
    }

    // MARK: - One message, one row

    /// A snapshot, the live read between it and a history page, and the page
    /// itself all name the same messages; the overlap updates rows instead
    /// of adding them, and the live message between them is not lost.
    @Test func testSnapshotLiveAndHistoryOverlapWithoutDuplicates() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: [
                    self.message(seq: 1, log: 10, anchor: "p:10", liveAnchor: "l:s1:1"),
                ]))
            case "group_read":
                return .answer(self.live(next: 2, messages: [
                    self.message(seq: 2, log: 0, anchor: "l:s1:2", liveAnchor: "l:s1:2"),
                ]))
            case "chat_history_poll":
                return .answer(self.ready(messages: [
                    self.message(anchor: "p:9"),
                    self.message(anchor: "p:10"),
                    self.message(anchor: "p:11", liveAnchor: "l:s1:2"),
                ]))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        #expect(rig.feed.rows.map(\.id) == ["p:10"])

        rig.scheduler.run(2)
        #expect(rig.feed.rows.map(\.id) == ["p:10", "l:s1:2"])

        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:9", "p:10", "l:s1:2"])
        #expect(rig.feed.messages.map(\.anchor) == ["p:9", "p:10", "p:11"])
        #expect(rig.feed.rows.count == 3)
    }

    /// The live identity is a temporary one: when the same message comes
    /// back persisted, the row keeps the display id it first had and its
    /// canonical anchor becomes the persisted one.
    @Test func testALiveIdentityBecomesPersistedWithoutANewRow() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                return .answer(self.ready(messages: [
                    self.message(seq: 9, log: 0, anchor: "l:s1:9", liveAnchor: "l:s1:9"),
                ]))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.count == 1)
        #expect(rig.feed.rows[0].id == "l:s1:9")

        // The same message, now written down: a different canonical anchor,
        // with the old one as its live alias.
        rig.door.reply = { request in
            switch Door.method(request) {
            case "group_read":
                return .answer(self.live(next: 9, messages: [
                    self.message(seq: 0, log: 9, anchor: "p:9", liveAnchor: "l:s1:9"),
                ]))
            default: return .notReady
            }
        }
        rig.scheduler.run(2)
        #expect(rig.feed.rows.count == 1)
        #expect(rig.feed.rows[0].id == "l:s1:9")
        #expect(rig.feed.rows[0].message.anchor == "p:9")
    }

    /// Several history records carry `seq = 0` and are still several rows:
    /// the anchor is the identity, not the count.
    @Test func testEveryHistoryRecordWithSeqZeroIsItsOwnRow() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                return .answer(self.ready(messages: [
                    self.message(seq: 0, anchor: "p:1"),
                    self.message(seq: 0, anchor: "p:2"),
                    self.message(seq: 0, anchor: "p:3"),
                ]))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:1", "p:2", "p:3"])
    }

    // MARK: - Runs, sessions, leaving

    /// A live answer from a new core run is another run's world: the old job
    /// is cancelled, a fresh bootstrap goes out, and the old body stays on
    /// screen until the new snapshot is valid, then is replaced in one step.
    @Test func testANewSessionRebuildsAndReplacesTheBody() {
        let rig = Rig()
        var begins = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                begins += 1
                let first = begins == 1
                return .answer(self.begin(
                    session: first ? "s1" : "s2",
                    job: first ? self.jobID : self.job2,
                    liveSince: first ? 5 : 1,
                    snapshot: [self.message(seq: 0, anchor: first ? "p:1" : "p:2", text: first ? "one" : "two")]
                ))
            case "chat_history_poll":
                return .answer(self.status("pending"))
            case "group_read":
                return .answer(self.live(session: "s2", next: 1, messages: []))
            case "chat_history_cancel":
                return .answer(self.status("cancelled"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        #expect(rig.feed.rows.map(\.message.text) == ["one"])

        rig.scheduler.run(2)
        #expect(begins == 2)
        #expect(rig.feed.session == "s2")
        #expect(rig.feed.rows.map(\.message.text) == ["two"])
        #expect(rig.door.methods("chat_history_cancel").count == 1)

        // The new run's water mark, not the old one's.
        rig.scheduler.run(2)
        #expect(rig.door.last("group_read")?["since"] as? UInt64 == 1)
    }

    /// Leaving stops the clock and cancels a known job even though nothing
    /// else would; an answer already on its way is dropped, not merged.
    @Test func testStopCancelsTheJobAndDropsALateAnswer() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        #expect(rig.scheduler.count == 2) // the live read and the history poll

        let latePoll = rig.scheduler.take(0.2)
        rig.feed.stop()
        #expect(rig.door.methods("chat_history_cancel").count == 1)
        #expect(rig.scheduler.count == 0)

        let before = rig.door.requests.count
        latePoll?()
        #expect(rig.door.requests.count == before)
        #expect(rig.feed.rows.isEmpty)
    }

    /// A repeated start of the group already in front is not a second job
    /// and not a second timer.
    @Test func testStartingTheSameGroupAgainIsNotASecondJob() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        let requests = rig.door.requests.count
        let scheduled = rig.scheduler.count

        rig.feed.start(group: "polter")
        #expect(rig.door.requests.count == requests)
        #expect(rig.scheduler.count == scheduled)
    }

    // MARK: - Retries and stops

    /// `Busy` retries the **same** begin: same request id and parameters.
    @Test func testBusyRetriesTheSameBeginRequest() {
        let rig = Rig()
        var begins = 0
        rig.door.reply = { request in
            guard Door.method(request) == "chat_history_begin" else { return .notReady }
            begins += 1
            return begins == 1 ? .answer(self.failure("Busy")) : .answer(self.begin(snapshot: []))
        }
        rig.feed.start(group: "polter")
        #expect(begins == 1)
        #expect(rig.scheduler.count(at: 0.2) == 1)

        rig.scheduler.run(0.2)
        #expect(begins == 2)
        let ids = rig.door.methods("chat_history_begin").compactMap {
            Door.params($0)?["request_id"] as? String
        }
        #expect(ids.count == 2)
        #expect(ids[0] == ids[1])
        #expect(rig.feed.state == .loading)
    }

    /// A job that expired gets one fresh bootstrap and then stops with a
    /// button rather than making a new one every tick.
    @Test func testAnExpiredJobIsRebootstrappedOnceThenStopsForThePerson() {
        let rig = Rig()
        var begins = 0
        var current = jobID
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                begins += 1
                current = begins == 1 ? self.jobID : self.job2
                return .answer(self.begin(job: current, snapshot: []))
            case "chat_history_poll":
                return .answer(self.failure("Expired", job: current))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(begins == 2)

        rig.scheduler.run(0.2)
        #expect(begins == 2)
        #expect(rig.feed.state == .failed("Expired"))
        #expect(rig.feed.canReload)
    }

    /// Not ready and refused are different: the first is not said and keeps
    /// asking; the second is said and the rows already drawn stay.
    @Test func testNotReadyKeepsAskingWhileRefusedKeepsTheBodyAndIsSaid() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: [self.message(seq: 1, log: 0, anchor: "l:s1:1")]))
            case "chat_history_poll":
                return .answer(self.ready(messages: []))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .ready)

        rig.scheduler.run(2) // the live read: not ready
        #expect(rig.feed.rows.count == 1)
        #expect(rig.feed.trouble == nil)
        #expect(rig.scheduler.count(at: 2) == 1) // asked again

        rig.door.reply = { _ in .refused("NoSuchGroup") }
        rig.scheduler.run(2)
        #expect(rig.feed.rows.count == 1)
        #expect(rig.feed.trouble == "NoSuchGroup")
    }

    /// `more` is permission for one more look, not a loop: a core that says
    /// more without moving its cursor is diagnosed and left alone.
    @Test func testMoreThatDoesNotAdvanceStopsCatchingUp() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            case "group_read":
                return .answer(self.live(next: 5, more: true, messages: []))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(2)

        #expect(rig.feed.trouble == "the live read stopped advancing")
        #expect(rig.scheduler.count(at: 0.2) == 1) // only the history poll
        rig.scheduler.run(0.2)
        #expect(rig.door.methods("group_read").count == 1)
    }

    /// A live read that does advance and says more is allowed one more
    /// scheduled look.
    @Test func testMoreThatAdvancesArrangesOneCatchUp() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            case "group_read":
                return .answer(self.live(next: 6, more: true, messages: []))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(2)
        #expect(rig.scheduler.count(at: 0.2) == 2) // the poll and the catch-up
    }

    // MARK: - The page's Markdown

    /// The feed hands its real rows to its Markdown store, and the row's
    /// content changes from plain text to a document when the parse is
    /// delivered -- through the store's own production entry point.
    @Test func testTheFeedHandsRealRowsToTheMarkdownStore() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: [
                    self.message(seq: 0, anchor: "p:1", text: "# hi"),
                ]))
            case "chat_history_poll":
                return .answer(self.status("pending"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        // The raw window alone asks for nothing.
        #expect(rig.executor.startsCount == 0)
        #expect(rig.feed.markdown.content(
            id: "p:1", group: "polter", generation: rig.feed.generation, text: "# hi"
        ) == .plain(text: "# hi"))

        rig.feed.markdown.acquire("p:1", group: "polter", generation: rig.feed.generation)
        #expect(rig.executor.startsCount == 1)
        #expect(rig.feed.markdown.content(
            id: "p:1", group: "polter", generation: rig.feed.generation, text: "# hi"
        ) == .pending(text: "# hi"))

        rig.executor.runNextParse()
        rig.executor.deliverNext()
        guard case .markdown = rig.feed.markdown.content(
            id: "p:1", group: "polter", generation: rig.feed.generation, text: "# hi"
        ) else {
            Issue.record("the feed's row never reached a document")
            return
        }
    }

    // MARK: - The window's edge

    /// The list keeps the newest 500, and a dropped message takes its live
    /// aliases with it.
    @Test func testTheWindowKeepsTheNewestFiveHundredAndDropsTheirAliases() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            case "group_read":
                let messages = (1...501).map { i in
                    self.message(seq: UInt64(i), log: UInt64(i), anchor: "p:\(i)", liveAnchor: "l:s1:\(i)")
                }
                return .answer(self.live(next: 501, messages: messages))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(2)
        #expect(rig.feed.rows.count == Feed.windowLimit)
        #expect(rig.feed.rows.first?.id == "p:2")
        #expect(rig.feed.aliasCount == Feed.windowLimit)
    }

    /// The byte bound is the contract's own (text and identity strings), and
    /// a single message bigger than the whole budget is said out loud
    /// instead of being cut.
    @Test func testTheByteBoundAndAWholeMessageTooLarge() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            case "group_read":
                let big = String(repeating: "x", count: 9000)
                let messages = (1...500).map { i in
                    self.message(seq: UInt64(i), log: 0, anchor: "l:s1:\(i)", text: big)
                }
                return .answer(self.live(next: 500, messages: messages))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(2)
        #expect(rig.feed.retainedBytes <= Feed.windowBytes)
        #expect(rig.feed.rows.count < Feed.windowLimit)

        // One message over the whole budget: refused, not truncated.
        rig.door.reply = { request in
            guard Door.method(request) == "group_read" else { return .notReady }
            let huge = String(repeating: "y", count: Feed.windowBytes + 1)
            return .answer(self.live(next: 501, messages: [
                self.message(seq: 501, log: 0, anchor: "l:s1:501", text: huge),
            ]))
        }
        let before = rig.feed.rows.count
        rig.scheduler.run(2)
        #expect(rig.feed.rows.count == before)
        #expect(rig.feed.state == .failed("TooLarge"))
        #expect(rig.feed.canReload)
    }
}
