import Foundation
import Testing

@testable import Ghostty

/// The reference desk's real consumer path: a begin, a poll, an accepted
/// source and an adoption effect; a rejected identity and the token's return;
/// and the raw Markdown destination.
struct ControlRoomChatReferenceDeskTests {
    typealias Desk = ControlRoomChatReferenceDesk
    typealias R = ControlRoomChatReference

    private let jobID = String(repeating: "a", count: 32)
    private let token = "abcdef0123456789abcdef0123456789"

    private func status(_ state: String) -> String {
        """
        {"ok":true,"state":"\(state)","job_id":"\(jobID)","group":"polter","session":"s1"}
        """
    }

    private func ready(anchor: String = "p:2", live: String? = nil) -> String {
        let liveField = live.map { "\"\($0)\"" } ?? "null"
        return """
        {"ok":true,"state":"ready","job_id":"\(jobID)","group":"polter",\
        "session":"s1","mode":"reference",\
        "source":{"anchor":"\(anchor)","live_anchor":\(liveField),\
        "location":null,"original_reference":"docs/a.md"},\
        "file_open":{"ok":true,"token":"\(token)",\
        "info":{"name":"a.md","kind":"file","size":1,"mtime_ns":"1","editable":false},\
        "plugin":{"status":"matched","key":"edit-text","reads":"file",\
        "render":"page","page":"index.html","plugin_dir":"/tmp/p"}}}
        """
    }

    private final class Door {
        var reply: (String) -> ControlRoomChatFeed.Reply = { _ in .notReady }
        func ask(_ request: String) -> ControlRoomChatFeed.Reply { reply(request) }
    }

    private final class Scheduler: ControlRoomChatScheduling {
        private var items: [(UUID, TimeInterval, () -> Void)] = []
        func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> UUID {
            let id = UUID(); items.append((id, delay, work)); return id
        }
        func cancel(_ token: UUID) { items.removeAll { $0.0 == token } }
        func run(_ delay: TimeInterval) {
            guard let i = items.firstIndex(where: { abs($0.1 - delay) < 0.0001 }) else { return }
            let work = items.remove(at: i).2
            work()
        }
    }

    @Test func testAnAcceptedPageIsAdoptedWithItsResolvedIdentity() {
        let door = Door()
        let scheduler = Scheduler()
        door.reply = { request in
            guard let data = request.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String
            else { return .notReady }
            switch method {
            case "chat_history_begin": return .answer(self.status("pending"))
            case "chat_history_poll": return .answer(self.ready())
            default: return .notReady
            }
        }
        let desk = Desk(ask: door.ask, scheduler: scheduler)
        var effect: Desk.Effect?
        desk.onEffect = { effect = $0 }
        desk.resolve(cell: "cell", group: "polter", anchor: "p:2",
                     location: nil, reference: "docs/a.md")
        scheduler.run(0.2)

        guard case let .adopt(cell, got, presentation, closeOld, anchor, location)? = effect else {
            Issue.record("no adoption effect")
            return
        }
        #expect(cell == "cell")
        #expect(got == token)
        #expect(closeOld == nil)
        #expect(anchor == "p:2")
        #expect(location == nil)
        if case .pluginPage = presentation {} else {
            Issue.record("a matched page was not a page")
        }
    }

    /// A source that is not the request's still gives its token back, and
    /// the page is told to clear its body.
    @Test func testARejectedSourceReturnsItsToken() {
        let door = Door()
        let scheduler = Scheduler()
        door.reply = { request in
            guard let data = request.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String
            else { return .notReady }
            switch method {
            case "chat_history_begin": return .answer(self.status("pending"))
            default: return .answer(self.ready(anchor: "p:9"))
            }
        }
        let desk = Desk(ask: door.ask, scheduler: scheduler)
        var effect: Desk.Effect?
        desk.onEffect = { effect = $0 }
        desk.resolve(cell: "cell", group: "polter", anchor: "p:2",
                     location: nil, reference: "docs/a.md")
        scheduler.run(0.2)

        guard case let .close(_, got, code)? = effect else {
            Issue.record("no close effect")
            return
        }
        #expect(got == token)
        #expect(code == "AnchorStale")
    }

    @Test func testARawMarkdownDestinationIsSentAsWritten() {
        let text = "see [doc](docs/a.md) and [x](docs/a\\(b\\).md \"t\")"
        #expect(ControlRoomChatRawReference.destination(
            for: URL(string: "docs/a.md")!, in: text
        ) == "docs/a.md")
        // **The raw spelling is kept**, backslashes and all; only the
        // comparison unescapes it.
        #expect(ControlRoomChatRawReference.destination(
            for: URL(string: "docs/a(b).md")!, in: text
        ) == "docs/a\\(b\\).md")
    }
}
