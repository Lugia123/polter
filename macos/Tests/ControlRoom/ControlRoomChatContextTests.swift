import Foundation
import Testing

@testable import Ghostty

/// Around and context (contract Root exact context response supplement):
/// two explicit cursors, a mode that names the shape, a target index that
/// must really be the target, and no generic `next_token`.
struct ControlRoomChatContextTests {
    typealias C = ControlRoomChatContext

    private let jobID = String(repeating: "a", count: 32)
    private let older = String(repeating: "b", count: 32)
    private let newer = String(repeating: "c", count: 32)

    private func message(anchor: String, location: String? = nil) -> String {
        let locationField = location.map { ",\"location\":\"\($0)\"" } ?? ""
        return """
        {"seq":0,"log_seq":1,"from":"0x0000000000000001","from_self":false,\
        "author":"worker","at_ms":1700000000000,"summary":false,"channel":0,\
        "text":"hi","mentions":null,"role":null,"anchor":"\(anchor)",\
        "live_anchor":null,"content_version":0\(locationField)}
        """
    }

    private func page(
        mode: String,
        body: String,
        targetIndex: String? = nil,
        direction: String? = nil,
        nextToken: String? = nil
    ) -> String {
        let target = targetIndex.map { ",\"target_index\":\($0)" } ?? ""
        let dir = direction.map { ",\"direction\":\"\($0)\"" } ?? ""
        let next = nextToken.map { ",\"next_token\":\"\($0)\"" } ?? ""
        return """
        {"ok":true,"state":"ready","job_id":"\(jobID)","group":"polter",\
        "session":"s1","mode":"\(mode)",\(body)\(target)\(dir)\(next),\
        "stop":"at_end","gap":false,"restarted":false}
        """
    }

    private let body = """
    "messages":[{"seq":0,"log_seq":1,"from":"0x1","from_self":false,"author":"w",\
    "at_ms":1,"summary":false,"channel":0,"text":"a","mentions":null,"role":null,\
    "anchor":"p:1","live_anchor":null,"content_version":0},\
    {"seq":0,"log_seq":2,"from":"0x1","from_self":false,"author":"w",\
    "at_ms":2,"summary":false,"channel":0,"text":"b","mentions":null,"role":null,\
    "anchor":"p:2","live_anchor":null,"content_version":0}],\
    "older_token":"\(String(repeating: "b", count: 32))",\
    "newer_token":"\(String(repeating: "c", count: 32))",\
    "older_at_end":false,"newer_at_end":true
    """

    // MARK: - Around

    @Test func testAroundNamesItsTargetAndItsTwoCursors() {
        guard case let .ready(around)? = C.decodeAround(
            page(mode: "around", body: body, targetIndex: "1")
        ) else {
            Issue.record("a valid around page was not read")
            return
        }
        #expect(around.targetIndex == 1)
        #expect(around.target?.anchor == "p:2")
        #expect(around.page.olderToken == older)
        #expect(around.page.newerToken == newer)
        #expect(around.page.olderAtEnd == false)
        #expect(around.page.newerAtEnd == true)
        #expect(around.page.messages.map(\.anchor) == ["p:1", "p:2"])
    }

    @Test func testAroundRequiresItsModeTargetAndNoGenericToken() {
        #expect(C.decodeAround(page(mode: "context", body: body, targetIndex: "1")) == nil)
        #expect(C.decodeAround(page(mode: "around", body: body)) == nil)
        #expect(C.decodeAround(page(mode: "around", body: body, targetIndex: "2")) == nil)
        #expect(C.decodeAround(page(mode: "around", body: body, targetIndex: "1",
                                     direction: "older")) == nil)
        #expect(C.decodeAround(page(mode: "around", body: body, targetIndex: "1",
                                     nextToken: newer)) == nil)
    }

    // MARK: - Context

    @Test func testContextSaysWhichDirectionItExtended() {
        guard case let .ready(context)? = C.decodeContext(
            page(mode: "context", body: body, direction: "older")
        ) else {
            Issue.record("a valid context page was not read")
            return
        }
        #expect(context.direction == .older)
        #expect(context.page.olderToken == older)
        #expect(context.page.newerToken == newer)

        guard case let .ready(newerPage)? = C.decodeContext(
            page(mode: "context", body: body, direction: "newer")
        ) else {
            Issue.record("a newer context page was not read")
            return
        }
        #expect(newerPage.direction == .newer)
    }

    @Test func testContextRejectsAMissingDirectionTargetIndexOrGenericToken() {
        #expect(C.decodeContext(page(mode: "context", body: body)) == nil)
        #expect(C.decodeContext(page(mode: "context", body: body, direction: "sideways")) == nil)
        #expect(C.decodeContext(page(mode: "context", body: body,
                                     targetIndex: "0", direction: "older")) == nil)
        #expect(C.decodeContext(page(mode: "context", body: body,
                                     direction: "older", nextToken: older)) == nil)
        #expect(C.decodeContext(page(mode: "around", body: body, direction: "older")) == nil)
    }

    @Test func testAFailureIsReadBeforeAReadyPage() {
        let failure = """
        {"ok":false,"error":"AnchorStale","job_id":"\(jobID)","group":"polter","session":"s1"}
        """
        guard case let .failed(f)? = C.decodeAround(failure) else {
            Issue.record("a failure was not read")
            return
        }
        #expect(f.error == "AnchorStale")
        #expect(C.decodeContext(#"{"error":"AnchorNotVisible"}"#) != nil)
    }

    // MARK: - The message's location hint

    @Test func testTheLocationHintIsKeptAsWrittenAndMayBeAbsent() throws {
        let withHint = page(
            mode: "around",
            body: body.replacingOccurrences(
                of: "\"anchor\":\"p:1\"",
                with: "\"anchor\":\"p:1\",\"location\":\"gen/3:offset=42\""
            ),
            targetIndex: "0"
        )
        guard case let .ready(around)? = C.decodeAround(withHint) else {
            Issue.record("a message with a location hint was not read")
            return
        }
        #expect(around.page.messages[0].location == "gen/3:offset=42")
        #expect(around.page.messages[1].location == nil)
    }

    // MARK: - Requests

    @Test func testAroundRequestCarriesModeWindowAndOptionalLocationOnly() throws {
        let request = try ControlRoomChatRequest.aroundBegin(
            group: "polter", requestID: "id", anchor: "p:2",
            before: 3, after: 4, location: "gen/3:offset=42"
        )
        let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        #expect(object?["method"] as? String == "chat_history_begin")
        let params = object?["params"] as? [String: Any]
        #expect(params?["mode"] as? String == "around")
        #expect(params?["anchor"] as? String == "p:2")
        #expect(params?["before"] as? Int == 3)
        #expect(params?["after"] as? Int == 4)
        #expect(params?["location"] as? String == "gen/3:offset=42")
        #expect(params?["limit"] == nil)
        #expect(params?["resume_token"] == nil)

        let noHint = try ControlRoomChatRequest.aroundBegin(
            group: "polter", requestID: "id", anchor: "p:2"
        )
        #expect(!noHint.contains("location"))
        #expect(throws: ControlRoomChatRequest.Invalid.window) {
            try ControlRoomChatRequest.aroundBegin(
                group: "polter", requestID: "id", anchor: "p:2", before: 100
            )
        }
        // **99 + 99 + 1 = 199 is inside the frozen contract's window**
        // (counts 0...99 and before + after + 1 <= 200, `2793-core-contract`
        // §around), so this encodes rather than throws. The old expectation
        // here named a window the contract allows; 100 is the refused one,
        // above.
        let widest = try ControlRoomChatRequest.aroundBegin(
            group: "polter", requestID: "id", anchor: "p:2", before: 99, after: 99
        )
        #expect(widest.contains("\"before\":99"))
        #expect(widest.contains("\"after\":99"))
        #expect(throws: ControlRoomChatRequest.Invalid.anchor) {
            try ControlRoomChatRequest.aroundBegin(
                group: "polter", requestID: "id", anchor: ""
            )
        }
        #expect(throws: ControlRoomChatRequest.Invalid.location) {
            try ControlRoomChatRequest.aroundBegin(
                group: "polter", requestID: "id", anchor: "p:2", location: ""
            )
        }
    }

    @Test func testContextRequestCarriesOnlyItsTokenAndLimit() throws {
        let request = try ControlRoomChatRequest.contextBegin(
            group: "polter", requestID: "id", resumeToken: older, limit: 25
        )
        let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        #expect(params?["mode"] as? String == "context")
        #expect(params?["resume_token"] as? String == older)
        #expect(params?["limit"] as? Int == 25)
        #expect(params?["anchor"] == nil)
        #expect(params?["before"] == nil)
        #expect(params?["after"] == nil)
        #expect(params?["location"] == nil)
        #expect(throws: ControlRoomChatRequest.Invalid.resumeToken) {
            try ControlRoomChatRequest.contextBegin(
                group: "polter", requestID: "id", resumeToken: "short"
            )
        }
    }
}
