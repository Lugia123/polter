import Foundation
import Testing

@testable import Ghostty

/// A message's file reference (Root reference identity/ownership supplement):
/// the exact source shape, the two identity rules, and one ticket per slot.
struct ControlRoomChatReferenceTests {
    typealias R = ControlRoomChatReference
    typealias Coord = ControlRoomChatPreviewCoordinator

    private let jobID = String(repeating: "a", count: 32)

    private func ready(
        anchor: String = "p:2",
        liveAnchor: String? = nil,
        location: String? = nil,
        reference: String = "docs/a.md",
        mode: String = "reference",
        extra: String = ""
    ) -> String {
        let live = liveAnchor.map { "\"\($0)\"" } ?? "null"
        let loc = location.map { "\"\($0)\"" } ?? "null"
        return """
        {"ok":true,"state":"ready","job_id":"\(jobID)","group":"polter",\
        "session":"s1","mode":"\(mode)",\
        "source":{"anchor":"\(anchor)","live_anchor":\(live),\
        "location":\(loc),"original_reference":"\(reference)"},\
        "file_open":{"ok":true,"token":"t1","rel":"docs/a.md"}\(extra)}
        """
    }

    // MARK: - Decoding

    @Test func testAReadyReferenceCarriesItsExactSourceAndTicket() {
        guard case let .ready(result)? = R.decode(
            ready(anchor: "p:2", liveAnchor: "l:s1:9", location: "gen/3:offset=42")
        ) else {
            Issue.record("a valid reference reply was not read")
            return
        }
        #expect(result.source.anchor == "p:2")
        #expect(result.source.liveAnchor == "l:s1:9")
        #expect(result.source.location == "gen/3:offset=42")
        #expect(result.source.originalReference == "docs/a.md")
        #expect(result.fileOpen.contains("\"token\":\"t1\""))
    }

    /// The source must say `live_anchor` and `location`, even when both are
    /// null. "Did not say" is not "said none".
    @Test func testTheNullKeysMustBePresent() {
        let noLive = ready().replacingOccurrences(of: "\"live_anchor\":null,", with: "")
        #expect(R.decode(noLive) == nil)
        let noLocation = ready().replacingOccurrences(of: "\"location\":null,", with: "")
        #expect(R.decode(noLocation) == nil)
    }

    @Test func testAReferenceReadyRejectsTheOtherShapes() {
        #expect(R.decode(ready(mode: "around")) == nil)
        #expect(R.decode(ready(anchor: "")) == nil)
        #expect(R.decode(ready(reference: "")) == nil)
        #expect(R.decode(ready(extra: ",\"next_token\":\"x\"")) == nil)
        #expect(R.decode(ready(extra: ",\"direction\":\"older\"")) == nil)
        #expect(R.decode(ready(extra: ",\"target_index\":0")) == nil)
        let noOpen = ready().replacingOccurrences(
            of: ",\"file_open\":{\"ok\":true,\"token\":\"t1\",\"rel\":\"docs/a.md\"}", with: ""
        )
        #expect(R.decode(noOpen) == nil)
    }

    @Test func testAFailureIsReadBeforeAReadyReply() {
        let failure = """
        {"ok":false,"error":"ReferenceNotFound","job_id":"\(jobID)","group":"polter","session":"s1"}
        """
        guard case let .failed(f)? = R.decode(failure) else {
            Issue.record("a failure was not read")
            return
        }
        #expect(f.error == "ReferenceNotFound")
        #expect(R.decode(#"{"error":"NotAFileReference"}"#) != nil)
    }

    // MARK: - Identity

    private let source = R.Source(
        anchor: "p:2",
        liveAnchor: "l:s1:9",
        location: nil,
        originalReference: "docs/a.md"
    )

    @Test func testCanonicalEqualityAndTheVerifiedLiveAliasAreAccepted() {
        #expect(R.accepts(source: source, requestedAnchor: "p:2",
                          requestedReference: "docs/a.md") == .accepted)
        #expect(R.accepts(source: source, requestedAnchor: "l:s1:9",
                          requestedReference: "docs/a.md") == .accepted)
        #expect(R.accepts(source: source, requestedAnchor: "p:9",
                          requestedReference: "docs/a.md") == .rejected("AnchorStale"))
        #expect(R.accepts(source: source, requestedAnchor: "p:2",
                          requestedReference: "docs/b.md") == .rejected("ReferenceNotFound"))
    }

    /// A host with no core-verified alias cannot accept a live anchor that
    /// merely looks like one.
    @Test func testAnAbsentAliasIsNotInvented() {
        let noAlias = R.Source(
            anchor: "p:2", liveAnchor: nil, location: nil,
            originalReference: "docs/a.md"
        )
        #expect(R.accepts(source: noAlias, requestedAnchor: "l:s1:9",
                          requestedReference: "docs/a.md") == .rejected("AnchorStale"))
    }

    // MARK: - Ticket ownership

    /// One slot, one token: adopting a second replaces the first and hands
    /// the old token back to be closed.
    @Test func testAdoptingASecondTicketReplacesTheOldOneAtomically() {
        var coord = Coord()
        let first = coord.adopt(token: "t1", slot: "A", ready: "r1")
        let second = coord.adopt(token: "t2", slot: "A", ready: "r2")
        #expect(first == .adopted(closeOld: nil, closeNew: nil))
        #expect(second == .adopted(closeOld: "t1", closeNew: nil))
        #expect(coord.token(of: "A") == "t2")
        #expect(!coord.isAdopted("t1"))
        #expect(coord.isAdopted("t2"))
    }

    /// Another slot holding the token is refused; its owner is not closed.
    @Test func testASecondSlotNeverTakesOrClosesTheOwnersTicket() {
        var coord = Coord()
        _ = coord.adopt(token: "t1", slot: "A", ready: "r1")
        let other = coord.adopt(token: "t1", slot: "B", ready: "r2")
        #expect(other == .alreadyOwned("A"))
        #expect(coord.token(of: "A") == "t1")
        #expect(coord.token(of: "B") == nil)
    }

    /// One ready reply is handed over once; handling it again closes nothing.
    @Test func testAReadyReplyIsConsumedOnce() {
        var coord = Coord()
        _ = coord.adopt(token: "t1", slot: "A", ready: "r1")
        #expect(coord.adopt(token: "t1", slot: "A", ready: "r1") == .duplicate)
        #expect(coord.reject(token: "t1", ready: "r1") == nil)
    }

    /// A rejected or late token that no slot adopted is given back exactly
    /// once; one an owner holds is never closed by this path.
    @Test func testARejectedTokenIsReturnedOnceAndOnlyIfUnadopted() {
        var coord = Coord()
        #expect(coord.reject(token: "t9", ready: "r9") == "t9")
        #expect(coord.reject(token: "t9", ready: "r9") == nil)

        _ = coord.adopt(token: "t1", slot: "A", ready: "r1")
        #expect(coord.reject(token: "t1", ready: "r2") == nil)
    }

    @Test func testClosingASlotReturnsOnlyItsToken() {
        var coord = Coord()
        _ = coord.adopt(token: "t1", slot: "A", ready: "r1")
        _ = coord.adopt(token: "t2", slot: "B", ready: "r2")
        #expect(coord.close(slot: "A") == "t1")
        #expect(coord.token(of: "A") == nil)
        #expect(coord.token(of: "B") == "t2")
    }

    // MARK: - Request    // MARK: - Request

    @Test func testTheReferenceRequestCarriesTheRawReferenceAndNoOtherWindow() throws {
        let request = try ControlRoomChatRequest.referenceBegin(
            group: "polter", requestID: "id", anchor: "p:2",
            originalReference: "docs/a.md", location: "gen/3:offset=42"
        )
        let object = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        #expect(params?["mode"] as? String == "reference")
        #expect(params?["anchor"] as? String == "p:2")
        #expect(params?["original_reference"] as? String == "docs/a.md")
        #expect(params?["location"] as? String == "gen/3:offset=42")
        #expect(params?["limit"] == nil)
        #expect(params?["resume_token"] == nil)
        #expect(params?["before"] == nil)
        #expect(params?["after"] == nil)

        #expect(throws: ControlRoomChatRequest.Invalid.reference) {
            try ControlRoomChatRequest.referenceBegin(
                group: "polter", requestID: "id", anchor: "p:2", originalReference: ""
            )
        }
        #expect(throws: ControlRoomChatRequest.Invalid.anchor) {
            try ControlRoomChatRequest.referenceBegin(
                group: "polter", requestID: "id", anchor: "", originalReference: "a"
            )
        }
    }
}
