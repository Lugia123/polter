import Foundation
import Testing

@testable import Ghostty

/// The search through the real door: one debounced query, a generation that
/// drops stale answers, a scheduled continuation for an empty budget page,
/// and a cancel that is sent rather than assumed.
struct ControlRoomChatSearchFeedTests {
    typealias Feed = ControlRoomChatSearchFeed
    typealias State = ControlRoomChatSidebarState

    private let jobID = String(repeating: "a", count: 32)
    private let nextToken = String(repeating: "b", count: 32)

    // MARK: - Fixtures

    private func message(anchor: String) -> String {
        """
        {"seq":0,"log_seq":1,"from":"0x0000000000000001","from_self":false,\
        "author":"worker","at_ms":1700000000000,"summary":false,"channel":0,\
        "text":"a批量b","mentions":null,"role":null,"anchor":"\(anchor)",\
        "live_anchor":null,"content_version":0}
        """
    }

    private func hit(_ anchor: String) -> String {
        """
        {"message":\(message(anchor: anchor)),"snippet":"a批量b",\
        "snippet_start":0,"ranges":[{"start":1,"end":7}]}
        """
    }

    private func status(_ state: String) -> String {
        """
        {"ok":true,"state":"\(state)","job_id":"\(jobID)","group":"polter",\
        "session":"s1","query":"批量"}
        """
    }

    private func ready(
        anchors: [String] = [],
        stop: String = "at_end",
        token: String? = nil,
        gap: Bool = false,
        restarted: Bool = false
    ) -> String {
        let tokenField = token.map { "\"\($0)\"" } ?? "null"
        let hits = anchors.map { self.hit($0) }.joined(separator: ",")
        return """
        {"ok":true,"state":"ready","job_id":"\(jobID)","group":"polter",\
        "session":"s1","query":"批量","results":[\(hits)],"stop":"\(stop)",\
        "next_token":\(tokenField),"restarted":\(restarted),"gap":\(gap)}
        """
    }

    // MARK: - The rig

    private final class Door {
        var requests: [String] = []
        var reply: (String) -> ControlRoomChatFeed.Reply = { _ in .notReady }

        func ask(_ request: String) -> ControlRoomChatFeed.Reply {
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

        var count: Int { items.count }

        func count(at delay: TimeInterval) -> Int {
            items.filter { abs($0.delay - delay) < 0.0001 }.count
        }

        func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> UUID {
            let token = UUID()
            items.append(Item(token: token, delay: delay, work: work))
            return token
        }

        func cancel(_ token: UUID) {
            items.removeAll { $0.token == token }
        }

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
        lazy var feed = Feed(ask: door.ask, scheduler: scheduler)
    }

    private func startSearch(_ rig: Rig) {
        rig.feed.start(group: "polter")
        rig.feed.openSearch()
        rig.feed.setQuery(" 批量 ")
    }

    // MARK: - Debounce and one query

    /// Typing is not a request: the debounce fires once, and the begin carries
    /// the canonical query.
    @Test func testTypingIsDebouncedAndTheBeginCarriesTheCanonicalQuery() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_search_begin": return .answer(self.status("pending"))
            case "chat_search_poll":
                return .answer(self.ready(anchors: ["p:1"]))
            default: return .notReady
            }
        }
        startSearch(rig)
        #expect(rig.feed.state.search == .waiting)
        #expect(rig.door.methods("chat_search_begin").isEmpty)

        #expect(rig.scheduler.run(0.25))
        #expect(rig.feed.state.search == .searching)
        #expect(rig.door.last("chat_search_begin")?["query"] as? String == "批量")

        rig.scheduler.run(0.2)
        #expect(rig.feed.state.search == .results)
        #expect(rig.feed.state.hits.map(\.message.anchor) == ["p:1"])
        #expect(rig.feed.state.complete)
    }

    /// A new query cancels the scan that is out and drops its later answer.
    @Test func testANewQueryCancelsTheOldScanAndDropsItsAnswer() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_search_begin": return .answer(self.status("pending"))
            case "chat_search_poll": return .answer(self.status("pending"))
            case "chat_search_cancel": return .answer(self.status("cancelled"))
            default: return .notReady
            }
        }
        startSearch(rig)
        rig.scheduler.run(0.25)
        #expect(rig.door.methods("chat_search_begin").count == 1)
        let latePoll = rig.scheduler.take(0.2)
        #expect(latePoll != nil)

        rig.feed.setQuery("另一")
        #expect(rig.door.methods("chat_search_cancel").count == 1)
        #expect(rig.feed.state.search == .waiting)

        let before = rig.door.requests.count
        latePoll?()
        #expect(rig.door.requests.count == before)
        #expect(rig.feed.state.hits.isEmpty)
    }

    // MARK: - Continuation

    /// An empty `budget` page schedules one continuation from its token; the
    /// next begin carries it and no mode of its own.
    @Test func testAnEmptyBudgetPageContinuesFromItsToken() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_search_begin": return .answer(self.status("pending"))
            case "chat_search_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(stop: "budget", token: self.nextToken))
                }
                return .answer(self.ready(anchors: ["p:1"]))
            default: return .notReady
            }
        }
        startSearch(rig)
        rig.scheduler.run(0.25)
        rig.scheduler.run(0.2)
        #expect(rig.feed.state.search == .scanningMore)
        #expect(rig.door.methods("chat_search_begin").count == 1)
        #expect(rig.scheduler.count(at: 0.05) == 1)

        rig.scheduler.run(0.05)
        #expect(rig.door.methods("chat_search_begin").count == 2)
        #expect(rig.door.last("chat_search_begin")?["resume_token"] as? String == nextToken)
        #expect(rig.door.last("chat_search_begin")?["query"] as? String == "批量")

        rig.scheduler.run(0.2)
        #expect(rig.feed.state.search == .results)
    }

    /// The same token twice is a scan that is not advancing: said, not asked
    /// again.
    @Test func testARepeatedTokenStopsTheSearch() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_search_begin": return .answer(self.status("pending"))
            case "chat_search_poll":
                polls += 1
                return .answer(self.ready(stop: "budget", token: self.nextToken))
            default: return .notReady
            }
        }
        startSearch(rig)
        rig.scheduler.run(0.25)
        rig.scheduler.run(0.2)
        rig.scheduler.run(0.05)
        rig.scheduler.run(0.2)
        #expect(rig.feed.state.search == .failed("the search scan stopped advancing"))
        #expect(rig.scheduler.count(at: 0.05) == 0)
    }

    @Test func testLoadMoreUsesThePageToken() {
        let rig = Rig()
        var polls = 0
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_search_begin": return .answer(self.status("pending"))
            case "chat_search_poll":
                polls += 1
                if polls == 1 {
                    return .answer(self.ready(anchors: ["p:2"], stop: "full", token: self.nextToken))
                }
                return .answer(self.ready(anchors: ["p:1"]))
            default: return .notReady
            }
        }
        startSearch(rig)
        rig.scheduler.run(0.25)
        rig.scheduler.run(0.2)
        #expect(rig.feed.state.search == .scanningMore)
        #expect(rig.feed.state.hasMore)

        rig.feed.loadMore()
        #expect(rig.door.last("chat_search_begin")?["resume_token"] as? String == nextToken)
        rig.scheduler.run(0.2)
        #expect(rig.feed.state.search == .results)
        #expect(rig.feed.state.hits.map(\.message.anchor) == ["p:2", "p:1"])
    }

    @Test func testCancellingSendsTheCallAndSaysCancelled() {
        let rig = Rig()
        rig.door.reply = { request in
            switch Door.method(request) {
            case "chat_search_begin": return .answer(self.status("pending"))
            case "chat_search_poll": return .answer(self.status("pending"))
            case "chat_search_cancel": return .answer(self.status("cancelled"))
            default: return .notReady
            }
        }
        startSearch(rig)
        rig.scheduler.run(0.25)
        rig.feed.cancel()
        #expect(rig.door.methods("chat_search_cancel").count == 1)
        #expect(rig.feed.state.search == .cancelled)
    }
}
