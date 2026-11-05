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

    /// **The page just asked for must not be trimmed away the moment it is
    /// merged.** With 500 rows and the reader at the top, an older page goes
    /// in front; the window then drops from the other side of the reader,
    /// keeping both the new page and the live tail.
    @Test func testTheWindowKeepsTheOlderPageTheReaderJustAskedFor() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_history_begin":
                let snapshot = (1...500).map {
                    self.message(seq: UInt64($0), log: UInt64($0), anchor: "p:\($0)")
                }
                return .answer(self.begin(snapshot: snapshot))
            case "chat_history_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(messages: [], stop: "full", token: self.olderToken))
                }
                let older = (1...50).map {
                    self.message(seq: 0, log: UInt64($0), anchor: "h:\($0)")
                }
                return .answer(self.ready(messages: older, stop: "at_end", token: nil))
            default:
                return .notReady
            }
        }
        rig.feed.start(group: "polter")
        rig.scheduler.run(0.2)
        #expect(rig.feed.rows.count == Feed.windowLimit)
        rig.feed.reading(anchor: "p:1")

        rig.feed.loadOlder()
        rig.scheduler.run(0.2)

        #expect(rig.feed.rows.count == Feed.windowLimit)
        #expect(rig.feed.rows.first?.id == "h:1")
        #expect(rig.feed.rows.contains { $0.id == "h:50" })
        #expect(rig.feed.rows.contains { $0.id == "p:1" })
        #expect(rig.feed.rows.last?.id == "p:500")

        // **What went is one contiguous run at the boundary between the
        // reading window and the live tail**, not a hole picked out of the
        // middle, and it is said out loud.
        let kept = Set(rig.feed.rows.map(\.id))
        let missing = (102...151).map { "p:\($0)" }.filter { !kept.contains($0) }
        #expect(missing.count == 50)
        #expect(rig.feed.trimmedAfter == "p:101")
        #expect(rig.feed.trimmedBefore == nil)

        // The released run can be read again: the list's gap boundary offers
        // this, and it starts the body again from the newest records.
        let beginsBefore = rig.door.methods("chat_history_begin").count
        rig.feed.reloadClearingGap()
        #expect(rig.feed.trimmedAfter == nil)
        #expect(rig.feed.trimmedBefore == nil)
        #expect(rig.door.methods("chat_history_begin").count == beginsBefore + 1)
        #expect(rig.feed.rows.count == Feed.windowLimit)
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
        rig.feed.stop()
        let begins = rig.door.methods("chat_history_begin").count
        rig.feed.start(group: "polter")
        #expect(rig.door.methods("chat_history_begin").count == begins)
        #expect(rig.feed.rows.map(\.id) == ["p:10"])
        // The reading line survives the tab, not just the row.
        #expect(rig.feed.savedReading == .init(id: "p:10", offset: 12))

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
        #expect(rig.scheduler.run(0.2))
        #expect(!rig.feed.locating)
        #expect(rig.feed.locateTrouble == "malformed locate reply")
    }
}
