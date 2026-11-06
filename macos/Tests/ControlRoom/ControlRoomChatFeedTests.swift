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
        restarted: Bool = false,
        session: String = "s1",
        job: String? = nil
    ) -> String {
        let tokenField = token.map { "\"\($0)\"" } ?? "null"
        return """
        {"ok":true,"state":"ready","job_id":"\(job ?? jobID)","group":"polter",\
        "session":"\(session)","messages":[\(messages.joined(separator: ","))],\
        "stop":"\(stop)","next_token":\(tokenField),"restarted":\(restarted),"gap":\(gap)}
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

    /// A gap with no resume point is a whole answer, not a malformed one --
    /// and **not an empty chat**: the scan did not reach a clean end, so the
    /// page says the records were damaged rather than that there are none.
    @Test func testAnAnsweredGapPageIsNotAnEmptyChat() {
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
        #expect(rig.feed.state == .gap)
        #expect(rig.feed.historyTail?.stop == .gap)
        #expect(rig.feed.historyTail?.nextToken == nil)
        #expect(rig.feed.historyTail?.gap == true)
        #expect(rig.feed.older == .gap)
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

    // MARK: - Loading older pages (contract §History)

    private let olderToken = String(repeating: "b", count: 32)
    private let nextOlderToken = String(repeating: "c", count: 32)

    /// **An empty `budget` page is progress, not an empty chat.** The first
    /// screen carries on from the token it named, through a scheduled turn,
    /// and only the page that answers with records (or ends) is drawn.
    @Test func testAnEmptyBudgetFirstPageCarriesOnInsteadOfShowingEmpty() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(messages: [], stop: "budget", token: self.olderToken))
                }
                return .answer(self.ready(messages: [self.message(anchor: "p:1")]))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .loading)
        #expect(rig.feed.older == .scanning)
        #expect(rig.feed.rows.isEmpty)
        // Scheduled, not called from inside the page's handler.
        #expect(rig.door.methods("chat_history_begin").count == 1)

        #expect(rig.scheduler.run(0.05))
        #expect(rig.door.last("chat_history_begin")?["resume_token"] as? String == olderToken)

        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .ready)
        #expect(rig.feed.older == .atEnd)
        #expect(rig.feed.rows.map(\.id) == ["p:1"])
    }

    /// The person's "load earlier" is the **plain history begin with a
    /// resume token** -- no around/context mode -- and its page goes in
    /// front of the rows already drawn.
    @Test func testLoadOlderUsesTheResumeTokenAndPutsThePageInFront() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:8"), self.message(anchor: "p:9")],
                    stop: "at_end", token: nil
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        #expect(rig.feed.older == .idle)
        #expect(rig.feed.canLoadOlder)

        rig.feed.loadOlder()
        #expect(rig.feed.older == .loading)
        #expect(rig.door.last("chat_history_begin")?["resume_token"] as? String == olderToken)
        #expect(rig.door.last("chat_history_begin")?["mode"] == nil)

        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:8", "p:9", "p:10"])
        #expect(rig.feed.older == .atEnd)
        #expect(!rig.feed.canLoadOlder)
    }

    /// **The chunk sizes are the request's, not the drawing's.** The first
    /// screen and each upward page both ask for 100 (task 3016 §5: the
    /// prefetch's three-viewport margin is spent against pages this size), and
    /// the upward page still carries the resume token and no mode.
    @Test func testTheFirstScreenAndEveryOlderPageAskForAHundred() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.status("pending"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        #expect(rig.door.methods("chat_history_begin").count == 1)
        #expect(rig.door.last("chat_history_begin")?["limit"] as? Int == Feed.firstChunk)
        #expect(Feed.firstChunk == 100)

        rig.scheduler.run(0.2)
        #expect(rig.feed.canLoadOlder)

        rig.feed.loadOlder()
        #expect(rig.door.methods("chat_history_begin").count == 2)
        #expect(rig.door.last("chat_history_begin")?["limit"] as? Int == Feed.olderChunk)
        #expect(rig.door.last("chat_history_begin")?["resume_token"] as? String == olderToken)
        #expect(Feed.olderChunk == 100)
    }

    /// **Loading older is only rows.** A window of more than a thousand
    /// messages is built by paging back one chunk at a time: `rows.count`
    /// grows by exactly one chunk per page, `state` never leaves `.ready`,
    /// and nothing is trimmed.
    @Test func testPagingBackGrowsTheRowsWithoutTouchingTheStateOrTheGap() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    let first = (0..<Feed.firstChunk).map {
                        self.message(anchor: "p:\(1000 + $0)")
                    }
                    return .answer(self.ready(
                        messages: first, stop: "full", token: self.olderToken
                    ))
                }
                let base = 1000 - (polls - 1) * Feed.olderChunk
                let page = (0..<Feed.olderChunk).map {
                    self.message(anchor: "p:\(base + $0)")
                }
                return .answer(self.ready(
                    messages: page, stop: "full", token: self.olderToken
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.count == Feed.firstChunk)
        #expect(rig.feed.state == .ready)

        var lastCount = rig.feed.rows.count
        for _ in 0..<23 {
            rig.feed.loadOlder()
            // The state belongs to the first screen; loading older is not a
            // UI event and never turns it back to `.loading`.
            #expect(rig.feed.state == .ready)
            rig.scheduler.run(0.2)
            #expect(rig.feed.state == .ready)
            #expect(rig.feed.rows.count == lastCount + Feed.olderChunk)
            lastCount = rig.feed.rows.count
        }
        #expect(rig.feed.rows.count >= 1000)
        #expect(rig.feed.trimmedBefore == nil)
        #expect(rig.feed.trimmedAfter == nil)
    }

    /// An older page still on its way leaves a body that already has rows
    /// `.ready` -- the placeholder's spinner belongs to a first screen that
    /// has nothing to draw.
    @Test func testAnOlderPageOnItsWayLeavesTheStateReady() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                switch polls {
                case 1:
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                case 2:
                    return .answer(self.status("pending"))
                default:
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:9")],
                        stop: "at_end", token: nil
                    ))
                }
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .ready)

        rig.feed.loadOlder()
        #expect(rig.feed.state == .ready)
        rig.scheduler.run(0.2) // still pending
        #expect(rig.feed.state == .ready)
        #expect(rig.feed.older == .loading)

        rig.scheduler.run(0.2) // the page lands
        #expect(rig.feed.state == .ready)
        #expect(rig.feed.rows.map(\.id) == ["p:9", "p:10"])
    }

    /// Five calls while a page is out are **one** request; a page that
    /// failed may be asked for again from the same token.
    @Test func testFiveLoadOlderCallsSendOneRequestAndAFailureMayBeRetried() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.failure("Reader"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        let begins = rig.door.methods("chat_history_begin").count

        for _ in 0..<5 { rig.feed.loadOlder() }
        #expect(rig.door.methods("chat_history_begin").count == begins + 1)
        #expect(rig.feed.older == .loading)

        // The page fails: the token stays, but the top edge is held back for
        // one cooldown -- the view asks on every scroll event near the top,
        // and a failure that is re-askable at once is a request storm.
        rig.scheduler.run(0.2)
        #expect(rig.feed.older == .failed("Reader"))
        #expect(!rig.feed.canLoadOlder)
        for _ in 0..<5 { rig.feed.loadOlder() }
        #expect(rig.door.methods("chat_history_begin").count == begins + 1)

        // The live read is the other 2 s item, hence two steps to the
        // cooldown's expiry.
        #expect(rig.scheduler.run(2))
        #expect(rig.scheduler.run(2))
        #expect(rig.feed.canLoadOlder)
        rig.feed.loadOlder()
        #expect(rig.door.methods("chat_history_begin").count == begins + 2)
        #expect(rig.door.last("chat_history_begin")?["resume_token"] as? String == olderToken)
    }

    /// **A damaged empty page is not carried on.** The scan stops instead of
    /// following the token, `settleOlder` records the gap, and the token
    /// stays in `historyTail` for a fresh ask.
    @Test func testAnEmptyBudgetPageWithAGapIsNotAdvanced() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.ready(
                    messages: [], stop: "budget", token: self.nextOlderToken,
                    gap: true
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.loadOlder()
        rig.scheduler.run(0.2)

        #expect(rig.scheduler.count(at: 0.05) == 0)
        #expect(rig.feed.older == .idle)
        #expect(rig.feed.historyTail?.gap == true)
        #expect(rig.feed.historyTail?.nextToken == nextOlderToken)
    }

    /// **Empty pages are followed only so far.** A core that keeps answering
    /// "empty, here is another token" is left alone after
    /// `maxAutomaticAdvances`; the scan stops with a reason and the token
    /// stays for the person's next ask.
    @Test func testTooManyEmptyPagesStopTheAutomaticScan() {
        let rig = Rig()
        var polls = 0
        var tokenSeq = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                tokenSeq += 1
                let token = String(repeating: String(tokenSeq % 10), count: 32)
                return .answer(self.ready(
                    messages: [], stop: "budget", token: token
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.loadOlder()
        rig.scheduler.run(0.2) // the first empty page schedules an advance

        for _ in 0..<Feed.maxAutomaticAdvances {
            #expect(rig.scheduler.run(0.05))
            rig.scheduler.run(0.2)
        }
        #expect(rig.feed.older
            == .failed("the history scan kept advancing over empty pages"))
        #expect(rig.scheduler.count(at: 0.05) == 0)
        #expect(rig.feed.historyTail?.nextToken != nil)
    }

    /// **An older page is not inserted under a moving hand.** While the view
    /// reports the reader active, the page's rows, its tail and its `older`
    /// word all wait; `canLoadOlder` is false so the top edge cannot send a
    /// second request; `readerIdle()` lands the whole page in one step.
    @Test func testAnOlderPageIsHeldWhileTheReaderMoves() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:9")],
                    stop: "at_end", token: nil
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])

        rig.feed.readerActive(true)
        rig.feed.loadOlder()
        rig.scheduler.run(0.2) // the page arrives while the hand is on
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        #expect(!rig.feed.canLoadOlder)
        #expect(rig.feed.older == .loading)
        #expect(rig.feed.historyTail?.nextToken == olderToken)

        rig.feed.readerIdle()
        #expect(rig.feed.rows.map(\.id) == ["p:9", "p:10"])
        #expect(rig.feed.older == .atEnd)
        #expect(rig.feed.historyTail?.nextToken == nil)
        #expect(!rig.feed.canLoadOlder)
    }

    /// **A gesture keeps asking** (M3). One page per gesture is the "scroll
    /// stops to load" the person reported: while the hand is on the list the
    /// feed holds each page and asks for the next from the token it just
    /// received, and `readerIdle()` lands the whole queue as **one rows
    /// change** (one correction), not one per page.
    @Test func testAGestureQueuesSeveralOlderPagesAndMergesThemAtOnce() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken))
                }
                // p:9, p:8, ... each with a token of its own.
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:\(20 - polls)")],
                    stop: "full", token: self.olderToken))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])

        rig.feed.readerActive(true)
        rig.feed.loadOlder()
        // Let several pages land while the hand stays on the list.
        for _ in 0..<8 { rig.scheduler.run(0.2) }

        // Nothing has been inserted: the map is still the first screen.
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        // **The pipeline kept asking**: each held page sent the next begin.
        #expect(rig.door.methods("chat_history_begin").count >= 3)
        #expect(!rig.feed.canLoadOlder)

        rig.feed.readerIdle()
        // One merge: every held page arrived, oldest first, in one change.
        #expect(rig.feed.rows.count > 2)
        #expect(rig.feed.rows.last?.id == "p:10")
        #expect(rig.feed.rows.first?.id != "p:10")
    }

    /// `readerIdle()` with nothing held changes nothing at all.
    @Test func testReaderIdleWithNothingHeldIsANoOp() {
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
        rig.feed.readerIdle()
        #expect(rig.door.requests.count == requests)
        #expect(rig.feed.rows.isEmpty)
    }

    /// **A located window has its own older cursor.** `locate` clears
    /// `historyTail`, so the plain resume page has nothing to continue from;
    /// the top edge still has to work, through the context cursor -- once
    /// per page, with the context page's own size, and with `state` left
    /// alone. The upward context page is held like every other one.
    @Test func testLoadOlderInALocatedWindowUsesTheContextCursorOnce() {
        let rig = Rig()
        let job = String(repeating: "a", count: 32)
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(job: job))
            case "chat_history_poll":
                polls += 1
                switch polls {
                case 1:
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "at_end", token: nil, job: job
                    ))
                case 2:
                    return .answer("""
                    {"ok":true,"state":"ready","mode":"around","job_id":"\(job)",\
                    "group":"polter","session":"s1",\
                    "messages":[\(self.message(seq: 1, log: 1, anchor: "p:10"))],\
                    "stop":"full","older_token":"\(self.olderToken)","newer_token":null,\
                    "older_at_end":false,"newer_at_end":true,\
                    "gap":false,"restarted":false,"target_index":0}
                    """)
                default:
                    return .answer("""
                    {"ok":true,"state":"ready","mode":"context","job_id":"\(job)",\
                    "group":"polter","session":"s1",\
                    "messages":[\(self.message(seq: 0, log: 0, anchor: "p:9"))],\
                    "stop":"full","older_token":"\(self.nextOlderToken)","newer_token":null,\
                    "older_at_end":false,"newer_at_end":true,\
                    "gap":false,"restarted":false,"direction":"older"}
                    """)
                }
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.locate(anchor: "p:10", location: nil)
        rig.scheduler.run(0.2)
        #expect(rig.feed.context != nil)
        #expect(rig.feed.state == .ready)

        let begins = rig.door.methods("chat_history_begin").count
        rig.feed.readerActive(true)
        for _ in 0..<5 { rig.feed.loadOlder() }
        #expect(rig.door.methods("chat_history_begin").count == begins + 1)
        let sent = rig.door.last("chat_history_begin")
        #expect(sent?["mode"] as? String == "context")
        #expect(sent?["limit"] as? Int == Feed.contextChunk)
        #expect(sent?["resume_token"] as? String == olderToken)
        #expect(rig.feed.state == .ready)

        // Held while the hand is on; landed in one step on idle.
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        #expect(!rig.feed.canLoadOlder)
        rig.feed.readerIdle()
        #expect(rig.feed.rows.map(\.id) == ["p:9", "p:10"])
        #expect(rig.feed.context?.olderToken == nextOlderToken)
        #expect(rig.feed.state == .ready)
    }

    /// **A stop ends the gesture with the showing.** A stop during a drag
    /// must not leave "the hand is on the list" standing into the next
    /// showing: a page would then be held for a hand that is no longer
    /// there. After a stop and a return the top edge asks again, and the
    /// page lands without `readerIdle()`.
    @Test func testStopDoesNotLeaveTheReaderHoldingTheNextPage() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:9")],
                    stop: "at_end", token: nil
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)

        rig.feed.readerActive(true)
        rig.feed.loadOlder()
        rig.scheduler.run(0.2) // held
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        #expect(!rig.feed.canLoadOlder)

        rig.feed.stop()
        rig.feed.start(group: "polter")
        #expect(rig.feed.canLoadOlder)
        rig.feed.loadOlder()
        rig.scheduler.run(0.2)
        // Landed without `readerIdle()`: a stale flag would have held it.
        #expect(rig.feed.rows.map(\.id) == ["p:9", "p:10"])
    }

    /// **A held older page must not roll the newer cursor back.** While it
    /// waits, a newer page can land; that page's answer is the later word
    /// for the newer direction, so the older page's stale `newer_token` is
    /// not written over it.
    @Test func testAHeldContextPageDoesNotRollBackTheNewerCursor() {
        let rig = Rig()
        let job = String(repeating: "a", count: 32)
        let aroundOlder = String(repeating: "b", count: 32)
        let aroundNewer = String(repeating: "c", count: 32)
        let olderNext = String(repeating: "d", count: 32)
        let staleNewer = String(repeating: "e", count: 32)
        let newerOlder = String(repeating: "f", count: 32)
        let newerNext = String(repeating: "1", count: 32)
        var stage = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(job: job))
            case "chat_history_poll":
                switch stage {
                case 0:
                    return .answer("""
                    {"ok":true,"state":"ready","mode":"around","job_id":"\(job)",\
                    "group":"polter","session":"s1",\
                    "messages":[\(self.message(seq: 1, log: 1, anchor: "p:10"))],\
                    "stop":"full","older_token":"\(aroundOlder)","newer_token":"\(aroundNewer)",\
                    "older_at_end":false,"newer_at_end":false,\
                    "gap":false,"restarted":false,"target_index":0}
                    """)
                case 1:
                    return .answer("""
                    {"ok":true,"state":"ready","mode":"context","job_id":"\(job)",\
                    "group":"polter","session":"s1",\
                    "messages":[\(self.message(seq: 0, log: 0, anchor: "p:9"))],\
                    "stop":"full","older_token":"\(olderNext)","newer_token":"\(staleNewer)",\
                    "older_at_end":false,"newer_at_end":false,\
                    "gap":false,"restarted":false,"direction":"older"}
                    """)
                default:
                    return .answer("""
                    {"ok":true,"state":"ready","mode":"context","job_id":"\(job)",\
                    "group":"polter","session":"s1",\
                    "messages":[\(self.message(seq: 2, log: 2, anchor: "p:11"))],\
                    "stop":"full","older_token":"\(newerOlder)","newer_token":"\(newerNext)",\
                    "older_at_end":false,"newer_at_end":true,\
                    "gap":false,"restarted":false,"direction":"newer"}
                    """)
                }
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.feed.locate(anchor: "p:10", location: nil)
        rig.scheduler.run(0.2) // the around window
        #expect(rig.feed.context?.olderToken == aroundOlder)
        #expect(rig.feed.context?.newerToken == aroundNewer)

        rig.feed.readerActive(true)
        rig.feed.loadOlder()
        stage = 1
        rig.scheduler.run(0.2) // the older page is held
        #expect(rig.feed.rows.map(\.id) == ["p:10"])

        rig.feed.loadContextNewer()
        stage = 2
        rig.scheduler.run(0.2) // a newer page lands while the older is held
        #expect(rig.feed.rows.map(\.id) == ["p:10", "p:11"])

        rig.feed.readerIdle()
        #expect(rig.feed.rows.map(\.id) == ["p:9", "p:10", "p:11"])
        // The older side advanced; the newer side kept the later word.
        #expect(rig.feed.context?.olderToken == olderNext)
        #expect(rig.feed.context?.newerToken == newerNext)
        #expect(rig.feed.context?.newerAtEnd == true)
    }

    /// **A held page must not kill a newer request still out.** While an
    /// older page waits, a newer page can already be in flight; the older
    /// page's late landing must not clear that job's id (its polls would
    /// stop and its answer go unread) nor its pending direction.
    @Test func testAHeldContextPageLeavesAnOutstandingNewerJobAlive() {
        let rig = Rig()
        let job = String(repeating: "a", count: 32)
        // **Distinct job ids**: the core never reuses one, and the feed's
        // "is this my job?" test is by id. A fixture that reused one id
        // would make the held page look like it owned the newer request.
        let olderJob = String(repeating: "d", count: 32)
        let newerJob = String(repeating: "e", count: 32)
        let aroundOlder = String(repeating: "b", count: 32)
        let aroundNewer = String(repeating: "c", count: 32)
        var beginsSent = 0
        var stage = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                beginsSent += 1
                switch beginsSent {
                case 1, 2: return .answer(self.begin(job: job))
                case 3: return .answer(self.begin(job: olderJob))
                default: return .answer(self.begin(job: newerJob))
                }
            case "chat_history_poll":
                switch stage {
                case 0:
                    return .answer("""
                    {"ok":true,"state":"ready","mode":"around","job_id":"\(job)",\
                    "group":"polter","session":"s1",\
                    "messages":[\(self.message(seq: 1, log: 1, anchor: "p:10"))],\
                    "stop":"full","older_token":"\(aroundOlder)","newer_token":"\(aroundNewer)",\
                    "older_at_end":false,"newer_at_end":false,\
                    "gap":false,"restarted":false,"target_index":0}
                    """)
                case 1:
                    return .answer("""
                    {"ok":true,"state":"ready","mode":"context","job_id":"\(olderJob)",\
                    "group":"polter","session":"s1",\
                    "messages":[\(self.message(seq: 0, log: 0, anchor: "p:9"))],\
                    "stop":"full","older_token":"\(aroundOlder)","newer_token":"\(aroundNewer)",\
                    "older_at_end":false,"newer_at_end":false,\
                    "gap":false,"restarted":false,"direction":"older"}
                    """)
                default:
                    return .answer("""
                    {"ok":true,"state":"pending","job_id":"\(newerJob)",\
                    "group":"polter","session":"s1"}
                    """)
                }
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.feed.locate(anchor: "p:10", location: nil)
        rig.scheduler.run(0.2)
        #expect(rig.feed.context != nil)

        rig.feed.readerActive(true)
        rig.feed.loadOlder()
        stage = 1
        rig.scheduler.run(0.2) // held
        #expect(rig.feed.rows.map(\.id) == ["p:10"])

        let begins = rig.door.methods("chat_history_begin").count
        rig.feed.loadContextNewer() // begin answered; its poll is out
        #expect(rig.door.methods("chat_history_begin").count == begins + 1)

        rig.feed.readerIdle() // the older page lands with the newer job out
        #expect(rig.feed.rows.map(\.id) == ["p:9", "p:10"])

        // **The newer job is still held.** Its pending answer schedules the
        // next poll; a cleared id would stop the loop here.
        stage = 2
        #expect(rig.scheduler.run(0.2))
        #expect(rig.scheduler.count(at: 0.2) == 1)
    }

    /// **The located window is a screen and a half each way.** A 10+10 page
    /// would leave the lower half of the screen empty; the feed asks for
    /// `locateWindowRows` (1.5 x the viewport, clamped to the core's 99).
    @Test func testALocatedWindowAsksForMoreThanOneScreenEachWay() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.feed.locate(anchor: "p:1", location: nil)
        let sent = rig.door.last("chat_history_begin")
        #expect(sent?["mode"] as? String == "around")
        #expect(sent?["before"] as? Int == 24)
        #expect(sent?["after"] as? Int == 24)
        #expect(Feed.defaultViewportRows == 16)

        rig.feed.viewportRows = 80
        #expect(rig.feed.locateWindowRows == 99)
        rig.feed.viewportRows = 2
        #expect(rig.feed.locateWindowRows == 10)
    }

    /// **Every locate is an event, and only a locate is.** The view keys its
    /// land effect on `locateEpoch`: the same anchor located twice must move
    /// it twice, a failed locate must move it, and a stop or a reload -- which
    /// move `generation` for their own reasons -- must not.
    @Test func testLocateEpochMovesForEveryLocateAndEveryFailedLocateOnly() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        let born = rig.feed.locateEpoch
        rig.feed.locate(anchor: "p:1", location: nil)
        let first = rig.feed.locateEpoch
        #expect(first != born)
        rig.feed.locate(anchor: "p:1", location: nil)
        #expect(rig.feed.locateEpoch != first)

        let afterLocates = rig.feed.locateEpoch
        rig.feed.stop()
        rig.feed.start(group: "polter")
        rig.feed.reload()
        #expect(rig.feed.locateEpoch == afterLocates)
    }

    /// **A failed locate is an event and brings the live read back.** The
    /// failure itself must be visible even when the anchor was already nil,
    /// and `locate()` cancelled the live schedule at its first line -- a
    /// failure that leaves it cancelled means this group never shows a new
    /// message again, which reads as "nobody is talking".
    @Test func testAFailedLocateMovesTheEpochAndRestoresTheLiveRead() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer("not a poll answer")
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        let born = rig.feed.locateEpoch
        rig.feed.locate(anchor: "p:2", location: nil)
        let located = rig.feed.locateEpoch
        #expect(located != born)

        #expect(rig.scheduler.run(0.2))
        #expect(rig.feed.locateTrouble == "malformed locate reply")
        #expect(rig.feed.locateEpoch != located)

        let reads = rig.door.methods("group_read").count
        #expect(rig.scheduler.run(2))
        #expect(rig.door.methods("group_read").count == reads + 1)
    }

    /// An empty older budget page schedules one more look; a token that
    /// repeats is not asked again (the scan made no progress), so a quiet or
    /// broken range cannot become a loop.
    @Test func testAnEmptyOlderBudgetPageAdvancesOnceAndARepeatedTokenStops() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                switch polls {
                case 1:
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                case 2:
                    return .answer(self.ready(
                        messages: [], stop: "budget", token: self.nextOlderToken
                    ))
                default:
                    // The same resume point the scan was already at.
                    return .answer(self.ready(
                        messages: [], stop: "budget", token: self.nextOlderToken
                    ))
                }
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.loadOlder()
        rig.scheduler.run(0.2)

        #expect(rig.feed.older == .scanning)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        #expect(rig.door.methods("chat_history_begin").count == 2)
        #expect(rig.scheduler.count(at: 0.05) == 1)

        #expect(rig.scheduler.run(0.05))
        #expect(rig.door.methods("chat_history_begin").count == 3)
        #expect(rig.door.last("chat_history_begin")?["resume_token"] as? String == nextOlderToken)

        rig.scheduler.run(0.2)
        #expect(rig.feed.older == .failed("the history scan stopped advancing"))
        #expect(rig.scheduler.count(at: 0.05) == 0)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
    }

    /// A cancelled older scan says so, keeps the token, and may be asked for
    /// again from that same token.
    @Test func testCancellingAnOlderScanKeepsItsPlaceAndCanResume() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.status("pending"))
            case "chat_history_cancel":
                return .answer(self.status("cancelled"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.loadOlder()
        rig.feed.cancelOlder()

        #expect(rig.feed.older == .cancelled)
        #expect(rig.door.methods("chat_history_cancel").count == 1)
        #expect(rig.feed.canLoadOlder)

        rig.feed.loadOlder()
        #expect(rig.feed.older == .loading)
        #expect(rig.door.last("chat_history_begin")?["resume_token"] as? String == olderToken)
    }

    /// Leaving the page while an older page is out says it was cancelled --
    /// not still loading, and not finished.
    @Test func testStoppingWhileAnOlderPageIsOutSaysCancelled() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.status("pending"))
            case "chat_history_cancel":
                return .answer(self.status("cancelled"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.loadOlder()
        rig.feed.stop()
        #expect(rig.feed.older == .cancelled)
        #expect(rig.feed.canLoadOlder)
    }

    /// `stop` cancels the continuation job **and** drops an answer already on
    /// its way; the rows it had are still there when the page comes back.
    @Test func testStopCancelsTheOlderJobAndDropsItsLateAnswer() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.status("pending"))
            case "chat_history_cancel":
                return .answer(self.status("cancelled"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.loadOlder()
        let latePoll = rig.scheduler.take(0.2)

        rig.feed.stop()
        #expect(rig.door.methods("chat_history_cancel").count == 1)
        #expect(rig.scheduler.count == 0)

        let before = rig.door.requests.count
        latePoll?()
        #expect(rig.door.requests.count == before)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
    }

    /// **The page just asked for must not be evicted the moment it is
    /// merged.** Past the ceiling, one whole block leaves from the end
    /// farthest from the reader. With the reader at the top -- where
    /// `loadOlder` has just put the new page -- the oldest block is what
    /// they are looking at, so the newest block goes instead, and the kept
    /// rows stay one contiguous run.
    @Test func testPastTheCeilingTheFarBlockGoesAndTheLoadedPageStays() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    // The first screen: exactly the ceiling.
                    let first = (1...Feed.retainedLimit).map {
                        self.message(
                            seq: UInt64($0), log: UInt64($0),
                            anchor: "p:\($0)", liveAnchor: "lp:\($0)")
                    }
                    return .answer(
                        self.ready(messages: first, stop: "full", token: self.olderToken))
                }
                let older = (1...50).map {
                    self.message(seq: 0, log: UInt64($0), anchor: "h:\($0)", liveAnchor: "lh:\($0)")
                }
                return .answer(self.ready(messages: older, stop: "full", token: self.nextOlderToken))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.count == Feed.retainedLimit)
        // The view is looking at the oldest row it holds: the top edge.
        rig.feed.reading(anchor: "p:1")

        rig.feed.loadOlder()
        rig.scheduler.run(0.2)

        // 5050 rows in, one block of 100 out from the newest end: 4950 kept.
        #expect(rig.feed.rows.count == Feed.retainedLimit + 50 - Feed.firstChunk)
        #expect(rig.feed.rows.first?.id == "h:1")
        #expect(rig.feed.rows.contains { $0.id == "h:50" })
        #expect(rig.feed.rows.contains { $0.id == "p:1" })
        #expect(rig.feed.rows.last?.id == "p:\(Feed.retainedLimit - Feed.firstChunk)")

        // **What went is one contiguous run at the far end**, never a hole
        // dug out of the middle, and it is said out loud.
        let kept = Set(rig.feed.rows.map(\.id))
        #expect(rig.feed.trimmedAfter == "p:\(Feed.retainedLimit - Feed.firstChunk)")
        #expect(rig.feed.trimmedBefore == nil)
        #expect(((Feed.retainedLimit - Feed.firstChunk + 1)...Feed.retainedLimit)
            .allSatisfy { !kept.contains("p:\($0)") })
        // The released rows' aliases went with them.
        #expect(rig.feed.aliasCount == rig.feed.rows.count)

        // **Back to the newest is a fresh bootstrap, not a scroll.** The
        // block that went was the newest one, so the newest rows may simply
        // not be there any more; the list's gap boundary offers the same
        // recovery.
        let beginsBefore = rig.door.methods("chat_history_begin").count
        rig.feed.returnToLatest()
        #expect(rig.feed.trimmedAfter == nil)
        #expect(rig.feed.trimmedBefore == nil)
        #expect(rig.door.methods("chat_history_begin").count == beginsBefore + 1)

        let again = rig.door.methods("chat_history_begin").count
        rig.feed.reloadClearingGap()
        #expect(rig.feed.trimmedAfter == nil)
        #expect(rig.feed.trimmedBefore == nil)
        #expect(rig.door.methods("chat_history_begin").count == again + 1)
    }

    /// **`at_end` alone is not completeness.** A page that reached the end
    /// over damaged records, or after its captured range restarted, is a
    /// gap: the first screen must not say "no messages" and the older loader
    /// must not say "the beginning".
    @Test func testAnEndWithGapOrRestartIsNotACompleteEnd() {
        for (gap, restarted) in [(true, false), (false, true), (true, true)] {
            let rig = Rig()
            rig.door.reply = { request in
                switch Door.method(request) {
                case "chat_history_begin":
                    return .answer(self.begin(snapshot: []))
                case "chat_history_poll":
                    return .answer(self.ready(
                        messages: [], stop: "at_end", token: nil, gap: gap, restarted: restarted
                    ))
                default:
                    return .notReady
                }
            }
            rig.feed.start(group: "polter")
            rig.scheduler.run(0.2)
            #expect(rig.feed.state == .gap)
            #expect(rig.feed.older == .gap)
            #expect(rig.feed.state != .empty)
            #expect(rig.feed.older != .atEnd)
        }

        // The same answer with rows already held is a ready body with an
        // older gap, never an empty one.
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: [
                    self.message(seq: 1, log: 0, anchor: "p:1"),
                ]))
            case "chat_history_poll":
                return .answer(self.ready(
                    messages: [], stop: "at_end", token: nil, gap: true
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .ready)
        #expect(rig.feed.older == .gap)
    }

    /// A continuation begin that decoded to a real job but is not this
    /// window's answer (another core run here) is not merged; **its scan is
    /// cancelled**, because nothing else holds its id.
    @Test func testAnUnacceptedStartedContinuationIsCancelled() {
        let rig = Rig()
        var polls = 0
        var begins = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                // The first begin is the bootstrap's; any later one is the
                // older page's and answers from another core run.
                begins += 1
                if begins == 1 { return .answer(self.begin(snapshot: [])) }
                return .answer(self.begin(session: "s2", job: self.job2))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.status("pending"))
            case "chat_history_cancel":
                return .answer(self.status("cancelled"))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.loadOlder()

        #expect(rig.feed.older == .failed("Expired"))
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        let cancels = rig.door.methods("chat_history_cancel")
        #expect(cancels.count == 1)
        #expect(Door.params(cancels[0])?["job_id"] as? String == job2)
    }

    // MARK: - Coming back to a page

    /// **A stopped page is resumed, not rebuilt.** Its body is kept and the
    /// live read carries on from its own cursor; a fresh bootstrap here would
    /// merge the newest history page in front of the older rows already held.
    @Test func testReturningAfterStopResumesLiveAndKeepsTheBody() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:10")],
                    stop: "full", token: self.olderToken
                ))
            case "group_read":
                return .answer(self.live(next: 11, messages: [
                    self.message(seq: 11, log: 11, anchor: "p:11"),
                ]))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])

        rig.feed.reading(anchor: "p:10", offset: 12)
        // **Within one showing the place is kept**: a layout change (the
        // search sidebar opening, a narrower window) never stops the feed.
        #expect(rig.feed.savedReading == .init(id: "p:10", offset: 12))
        rig.feed.stop()
        let begins = rig.door.methods("chat_history_begin").count
        rig.feed.start(group: "polter")
        #expect(rig.door.methods("chat_history_begin").count == begins)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        // **But a stop ends the showing**, and the place belongs to the
        // showing (task 2999 ②): the page comes back at the latest message,
        // not on the line it was left at -- which could be a stale one, or
        // one `loadOlder`'s fallback wrote while the reader never moved.
        #expect(rig.feed.savedReading == nil)

        rig.scheduler.run(2)
        #expect(rig.feed.rows.map(\.id) == ["p:10", "p:11"])
        _ = polls
    }

    /// **A begin snapshot is not a finished first screen.** If the history
    /// page was still pending (or was cancelled by leaving) there is no
    /// `historyTail` yet; returning must rebuild, or the older records are
    /// never asked for again.
    @Test func testReturningWhileTheFirstHistoryPageWasPendingRebuilds() {
        let rig = Rig()
        var begins = 0
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                begins += 1
                return .answer(self.begin(snapshot: [
                    self.message(seq: 1, log: 1, anchor: "p:1"),
                ]))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.status("pending"))
                }
                return .answer(self.ready(messages: [
                    self.message(anchor: "p:0"),
                    self.message(anchor: "p:1"),
                ]))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:1"])
        #expect(!rig.feed.firstScreenReady)

        rig.feed.stop()
        rig.feed.start(group: "polter")
        #expect(begins == 2)
        rig.scheduler.run(0.2)
        #expect(rig.feed.firstScreenReady)
        #expect(rig.feed.rows.map(\.id) == ["p:0", "p:1"])
    }

    /// The resumed page can still load further back, from the token it kept,
    /// and that older page goes in **front** -- never a fresh newest page.
    @Test func testReturningAfterStopKeepsTheOlderToken() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(
                        messages: [self.message(anchor: "p:10")],
                        stop: "full", token: self.olderToken
                    ))
                }
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:8"), self.message(anchor: "p:9")],
                    stop: "at_end", token: nil
                ))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.stop()
        rig.feed.start(group: "polter")
        #expect(rig.feed.canLoadOlder)

        let begins = rig.door.methods("chat_history_begin").count
        rig.feed.loadOlder()
        #expect(rig.door.methods("chat_history_begin").count == begins + 1)
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:8", "p:9", "p:10"])
    }

    /// A core that restarted while the page was hidden is a **whole
    /// replacement**, not a merge: the old run's rows go when the new
    /// snapshot is valid.
    @Test func testACoreRestartAfterReturnReplacesTheBody() {
        let rig = Rig()
        var begins = 0
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                begins += 1
                let first = begins == 1
                return .answer(self.begin(
                    session: first ? "s1" : "s2",
                    job: first ? self.jobID : self.job2,
                    liveSince: first ? 5 : 1,
                    snapshot: [self.message(
                        seq: 1, log: 0, anchor: first ? "p:1" : "p:2",
                        text: first ? "one" : "two"
                    )]
                ))
            case "chat_history_poll":
                polls += 1
                // The first screen must have settled before a return can be
                // a resume rather than a rebuild.
                return .answer(self.ready(messages: [], stop: "at_end", token: nil))
            case "group_read":
                return .answer(self.live(session: "s2", next: 1, messages: []))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.firstScreenReady)
        #expect(rig.feed.rows.map(\.message.text) == ["one"])
        rig.feed.stop()
        rig.feed.start(group: "polter")
        #expect(begins == 1) // resumed, not rebuilt

        rig.scheduler.run(2) // live: another run
        #expect(begins == 2)
        #expect(rig.feed.session == "s2")
        #expect(rig.feed.rows.map(\.message.text) == ["two"])
        _ = polls
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

    /// Live messages past the ceiling: whole blocks leave from the oldest
    /// end (no reader has reported an anchor), a dropped message takes its
    /// live aliases with it, and the amount that left is a multiple of the
    /// block size.
    @Test func testLiveMessagesPastTheCeilingDropWholeOldBlocksWithTheirAliases() {
        let rig = Rig()
        let count = Feed.retainedLimit + 1
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            case "group_read":
                let messages = (1...count).map { i in
                    self.message(seq: UInt64(i), log: UInt64(i), anchor: "p:\(i)", liveAnchor: "l:s1:\(i)")
                }
                return .answer(self.live(next: UInt64(count), messages: messages))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(2)

        let kept = Feed.retainedLimit + 1 - Feed.firstChunk
        #expect(rig.feed.rows.count == kept)
        #expect(count - rig.feed.rows.count == Feed.firstChunk)
        #expect(rig.feed.rows.first?.id == "p:\(Feed.firstChunk + 1)")
        #expect(rig.feed.trimmedBefore == "p:\(Feed.firstChunk + 1)")
        #expect(rig.feed.trimmedAfter == nil)
        #expect(rig.feed.aliasCount == kept)
    }

    /// **The memory bound is not a reason to draw nothing.** The ceiling is
    /// lowered so a few small messages reach it: over it, the window keeps
    /// at least one row, says where the rest went, and stays a body the view
    /// can draw -- an empty `rows` under `.ready` is the header over a blank
    /// list. This is a **defensive invariant** (a 64 KiB record cannot fill
    /// 32 MiB with fewer than a hundred rows); it stays because the row
    /// ceiling alone would allow ~312 MiB.
    @Test func testTheByteBoundNeverEmptiesTheWindow() {
        let rig = Rig()
        // Rows are ~29 bytes each: three are over a 100-byte ceiling.
        rig.feed.byteLimit = 100
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                // Settle the first screen first: `.loading` belongs to a
                // screen with nothing to draw.
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:0")],
                    stop: "at_end", token: nil
                ))
            case "group_read":
                let messages = (1...3).map { i in
                    self.message(seq: UInt64(i), log: UInt64(i), anchor: "p:\(i)")
                }
                return .answer(self.live(next: 3, messages: messages))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.state == .ready)
        // The view has not reported a reader, so no block stands in as one.
        rig.feed.reading(anchor: nil)

        rig.scheduler.run(2)
        #expect(rig.feed.rows.count >= 1)
        #expect(rig.feed.trimmedBefore != nil)
        #expect(rig.feed.state == .ready)
        #expect(rig.feed.retainedBytes <= rig.feed.byteLimit)
    }

    /// **The byte ceiling wins, but it never cuts the block the reader is
    /// standing in** (R2-5 plus the invariant the old test pinned). Three
    /// rows are over a 60-byte ceiling and the camera is on the oldest one;
    /// the window is one block wide, so `trim` yields entirely and drops
    /// nothing -- emptying or cutting the only block would leave the reader
    /// on an evicted row, which draws as a header over a blank list. The
    /// byte ceiling is allowed to lose here; the reader's block is not.
    @Test func testTheByteCeilingNeverCutsTheBlockTheReaderIsIn() {
        let rig = Rig()
        rig.feed.byteLimit = 60
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:0")],
                    stop: "at_end", token: nil
                ))
            case "group_read":
                let messages = (1...2).map { i in
                    self.message(seq: UInt64(i), log: UInt64(i), anchor: "p:\(i)")
                }
                return .answer(self.live(next: 2, messages: messages))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        rig.feed.reading(anchor: "p:0")

        rig.scheduler.run(2)
        // The reader's block is the only block: nothing may be dropped, so
        // the byte ceiling yields and every row stays.
        #expect(rig.feed.rows.map(\.id) == ["p:0", "p:1", "p:2"])
        #expect(rig.feed.trimmedBefore == nil)
        #expect(rig.feed.trimmedAfter == nil)
    }

    /// **The row reserve on each side of the camera** (R1-5): past the row
    /// ceiling with the camera in the middle, the *farther* end goes and at
    /// least `retainedEachSide` rows stay on the near side.
    @Test func testTheFartherEndGoesAndTheCameraKeepsItsNeighbourhood() {
        let rig = Rig()
        let side = Feed.retainedEachSide
        let count = Feed.retainedLimit
        var sent = false
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            case "group_read":
                guard !sent else {
                    return .answer(self.live(next: UInt64(count + 1), messages: []))
                }
                sent = true
                let messages = (1...count).map { i in
                    self.message(seq: UInt64(i), log: UInt64(i), anchor: "p:\(i)")
                }
                return .answer(self.live(next: UInt64(count), messages: messages))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(2)
        #expect(rig.feed.rows.count == count)

        // The camera sits 3000 rows from the front and 1999 from the back;
        // the front is the farther end, so the oldest block goes.
        rig.feed.reading(anchor: "p:3001")
        rig.door.reply = { request in
            guard Door.method(request) == "group_read" else { return .notReady }
            return .answer(self.live(
                next: UInt64(count + 1),
                messages: [self.message(
                    seq: UInt64(count + 1), log: UInt64(count + 1),
                    anchor: "p:\(count + 1)")]))
        }
        rig.scheduler.run(2)
        #expect(rig.feed.rows.count == count + 1 - Feed.firstChunk)
        #expect(rig.feed.rows.first?.id == "p:\(Feed.firstChunk + 1)")
        #expect(rig.feed.rows.last?.id == "p:\(count + 1)")
        #expect(rig.feed.trimmedBefore != nil)
        #expect(rig.feed.trimmedAfter == nil)
        // The camera's neighbourhood survives on the side behind it.
        let index = rig.feed.rows.firstIndex { $0.id == "p:3001" } ?? -1
        #expect(index >= 0)
        #expect(rig.feed.rows.count - 1 - index >= side)
    }

    /// **A jump to a row that is not loaded asks once, and a row that is
    /// already here asks for nothing** (task 3016 §6). The second call while
    /// the around is on its way must not restart a job whose window is about
    /// to land.
    @Test func testJumpToALoadedRowAsksForNothingAndAnUnloadedOneAsksOnce() {
        let rig = Rig()
        let job = String(repeating: "a", count: 32)
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(job: job))
            case "chat_history_poll":
                polls += 1
                guard polls == 1 else { return .answer(self.status("pending")) }
                return .answer(self.ready(
                    messages: [self.message(anchor: "p:10")],
                    stop: "at_end", token: nil, job: job))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])

        // The row is loaded: the view scrolls and the feed is not asked.
        let begins = rig.door.methods("chat_history_begin").count
        rig.feed.jump(to: "p:10")
        #expect(rig.door.methods("chat_history_begin").count == begins)

        // A row that is not loaded is one around...
        rig.feed.jump(to: "p:2")
        #expect(rig.door.methods("chat_history_begin").count == begins + 1)
        #expect(rig.feed.locatedAnchor == "p:2")
        // ... and a second ask for the same row while it is out is none.
        rig.feed.jump(to: "p:2")
        #expect(rig.door.methods("chat_history_begin").count == begins + 1)
    }

    /// The byte bound is the contract's own (text and identity strings), and
    /// a single message bigger than the whole budget is said out loud
    /// instead of being cut. The ceiling is lowered for the test: with 64 KiB
    /// records the production one cannot be reached with a hundred rows.
    @Test func testTheByteBoundAndAWholeMessageTooLarge() {
        let rig = Rig()
        rig.feed.byteLimit = 25_000
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin": return .answer(self.begin(snapshot: []))
            case "chat_history_poll": return .answer(self.status("pending"))
            case "group_read":
                // 400 rows of ~130 bytes are well over 25,000, with enough
                // rows that whole blocks are what goes.
                let big = String(repeating: "x", count: 100)
                let messages = (1...400).map { i in
                    self.message(seq: UInt64(i), log: 0, anchor: "l:s1:\(i)", text: big)
                }
                return .answer(self.live(next: 400, messages: messages))
            default: return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(2)
        #expect(rig.feed.retainedBytes <= rig.feed.byteLimit)
        // Whole blocks left, never rows picked out of the middle.
        #expect(rig.feed.rows.count % Feed.firstChunk == 0)
        #expect(rig.feed.rows.count < 400)

        // One message over the whole budget: refused, not truncated.
        rig.door.reply = { request in
            guard Door.method(request) == "group_read" else { return .notReady }
            let huge = String(repeating: "y", count: rig.feed.byteLimit + 1)
            return .answer(self.live(next: 401, messages: [
                self.message(seq: 401, log: 0, anchor: "l:s1:401", text: huge),
            ]))
        }
        let before = rig.feed.rows.count
        rig.scheduler.run(2)
        #expect(rig.feed.rows.count == before)
        #expect(rig.feed.state == .failed("TooLarge"))
        #expect(rig.feed.canReload)
    }

    // MARK: - Locating a search result

    /// A reply that is not a poll answer **ends the locate and says why**.
    /// The old handler returned without scheduling another poll, so the
    /// panel waited on "locating" for ever (task 2982, review M2).
    @Test func testAMalformedLocatePollEndsTheLocate() {
        let rig = Rig()
        let job = String(repeating: "a", count: 32)
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer("""
                {"ok":true,"state":"pending","job_id":"\(job)",\
                "group":"polter","session":"s1"}
                """)
            case "chat_history_poll":
                return .answer("not a poll answer")
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.feed.locate(anchor: "p:2", location: nil)
        #expect(rig.feed.locating)
        #expect(rig.feed.locateTrouble == nil)
        // The anchor is written before the window exists.
        #expect(rig.feed.locatedAnchor == "p:2")
        #expect(rig.scheduler.run(0.2))
        #expect(!rig.feed.locating)
        #expect(rig.feed.locateTrouble == "malformed locate reply")
        // **A failed locate must not leave its row drawn as the located
        // one** (task 2999 ④): the failure rolled the optimistic anchor back.
        #expect(rig.feed.locatedAnchor == nil)
    }

    /// **A located window whose target did not survive its own trim is
    /// said, not drawn as a window with no mark in it** (task 2999 ④).
    /// `replaceWindow` trims to the window's bound, and with no reading
    /// anchor yet it drops from the front -- the target can be what goes.
    @Test func testATargetTheWindowDroppedIsSaid() {
        let rig = Rig()
        let job = String(repeating: "a", count: 32)
        // One more than the ceiling, the target first: the oldest block goes,
        // and the target goes with it.
        let messages = (0...Feed.retainedLimit).map {
            self.message(seq: UInt64($0), log: UInt64($0), anchor: "p:\($0)")
        }
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer("""
                {"ok":true,"state":"pending","job_id":"\(job)",\
                "group":"polter","session":"s1"}
                """)
            case "chat_history_poll":
                return .answer("""
                {"ok":true,"state":"ready","mode":"around","job_id":"\(job)",\
                "group":"polter","session":"s1",\
                "messages":[\(messages.joined(separator: ","))],\
                "stop":"full","older_token":null,"newer_token":null,\
                "older_at_end":false,"newer_at_end":false,\
                "gap":false,"restarted":false,"target_index":0}
                """)
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.feed.locate(anchor: "p:0", location: nil)
        #expect(rig.scheduler.run(0.2))
        #expect(rig.feed.locateTrouble == "TargetNotInWindow")
        #expect(!rig.feed.rows.contains { $0.id == "p:0" })
    }

    /// **A locate is a page generation like any other, and the Markdown
    /// store must hear about it at once.** `start`, `stop` and `restartLoad`
    /// all hand the store the new generation right after moving it; the
    /// locate moved it and said nothing until the around page came back.
    /// A row that outlives the replacement is re-instantiated under the new
    /// generation *before* that answer arrives: it releases its old demand
    /// and asks again, and the store -- still on the old generation --
    /// refused. Nothing asked again, so the row drew its original Markdown
    /// for ever (task 2994: "the body degrades to raw Markdown after a
    /// locate, and does not recover").
    @Test func testALocateHandsTheStoreTheNewGenerationBeforeTheRowsAskAgain() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                return .answer(self.begin(snapshot: []))
            case "chat_history_poll":
                return .answer(self.ready(messages: [
                    self.message(anchor: "p:1"),
                ]))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        #expect(rig.scheduler.run(0.2))
        #expect(rig.feed.rows.map(\.id) == ["p:1"])

        // The row on screen was born on this page generation and asked for
        // its Markdown under it.
        let born = rig.feed.generation
        rig.feed.markdown.acquire("p:1", group: "polter", generation: born)
        rig.executor.runNextParse()
        rig.executor.deliverNext()
        guard case .markdown = rig.feed.markdown.content(
            id: "p:1", group: "polter", generation: born, text: "hi"
        ) else {
            Issue.record("the row never reached a document")
            return
        }

        // The person picks a search result. The generation moves now; the
        // around page (and the rows it carries) is still in flight, so the
        // view is re-rendered with the old rows and the new generation: it
        // releases the old demand and asks again.
        rig.feed.locate(anchor: "p:1", location: nil)
        #expect(rig.feed.generation != born)
        rig.feed.markdown.release("p:1", group: "polter", generation: born)
        rig.feed.markdown.acquire(
            "p:1", group: "polter", generation: rig.feed.generation)

        // The body draws Markdown, not the original text -- and it is the
        // Markdown path that carries the word-level search highlight.
        guard case .markdown = rig.feed.markdown.content(
            id: "p:1", group: "polter", generation: rig.feed.generation, text: "hi"
        ) else {
            Issue.record("the row fell back to its original text after the locate")
            return
        }
    }
}
