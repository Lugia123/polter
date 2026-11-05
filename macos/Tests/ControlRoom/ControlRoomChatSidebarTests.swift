import Foundation
import Testing

@testable import Ghostty

/// The chat's one right-hand slot: closed, search or preview (contract
/// §Search; DESIGN-v2 §11). Every state a search can be in is distinct, the
/// results of a new query cannot be mixed with the old ones, and a preview
/// opened from a search comes back to the same query, hits and selection.
struct ControlRoomChatSidebarTests {
    typealias State = ControlRoomChatSidebarState
    typealias S = ControlRoomChatSearch

    private func message(anchor: String) -> String {
        """
        {"seq":0,"log_seq":1,"from":"0x0000000000000001","from_self":false,\
        "author":"worker","at_ms":1700000000000,"summary":false,"channel":0,\
        "text":"a批量b","mentions":null,"role":null,"anchor":"\(anchor)",\
        "live_anchor":null,"content_version":0}
        """
    }

    private func ready(
        anchors: [String],
        stop: String = "at_end",
        token: String? = nil,
        gap: Bool = false,
        restarted: Bool = false
    ) -> S.Ready {
        let tokenField = token.map { "\"\($0)\"" } ?? "null"
        let hits = anchors.map { anchor in
            """
            {"message":\(message(anchor: anchor)),"snippet":"a批量b",\
            "snippet_start":0,"ranges":[{"start":1,"end":7}]}
            """
        }.joined(separator: ",")
        let json = """
        {"ok":true,"state":"ready","job_id":"\(String(repeating: "a", count: 32))",\
        "group":"polter","session":"s1","query":"批量","results":[\(hits)],\
        "stop":"\(stop)","next_token":\(tokenField),"restarted":\(restarted),\
        "gap":\(gap)}
        """
        guard case let .ready(page)? = S.decodePoll(json) else {
            fatalError("fixture did not decode")
        }
        return page
    }

    private let token = String(repeating: "b", count: 32)

    // MARK: - The slot

    @Test func testTheSlotIsOneOfThreeAndNeverTwo() {
        var state = State()
        #expect(state.mode == .closed)

        state.openSearch()
        #expect(state.mode == .search)
        #expect(state.preview == .none)

        let source = State.PreviewSource(group: "polter", anchor: "p:1", reference: "a.md")
        state.openPreview(source)
        #expect(state.mode == .preview)
        #expect(state.preview == .loading(source))

        state.previewReady()
        #expect(state.preview == .ready(source))

        state.openSearch()
        #expect(state.mode == .search)
        #expect(state.preview == .none)

        state.openPreview(source)
        state.close()
        #expect(state.mode == .closed)
        #expect(state.preview == .none)
    }

    // MARK: - Typing and submitting

    @Test func testAnEmptyOrWhitespaceQueryIsNeverSent() {
        var state = State()
        state.openSearch()
        #expect(state.search == .idle)

        state.typing("   ")
        #expect(state.search == .emptyQuery)
        #expect(state.submit() == nil)

        state.typing(" 批量 ")
        #expect(state.search == .waiting)
        #expect(state.submit() == "批量")
        #expect(state.search == .searching)
        #expect(state.query == " 批量 ")
        #expect(state.submitted == "批量")
    }

    /// A new query discards the old hits, cursor and selection: a page for
    /// the previous words can never be drawn under the new ones.
    @Test func testANewQueryClearsTheOldResults() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.absorb(ready(anchors: ["p:1"], stop: "full", token: token))
        state.select("p:1")
        #expect(state.hits.count == 1)
        #expect(state.selected == "p:1")

        state.typing("另一")
        #expect(state.hits.isEmpty)
        #expect(state.selected == nil)
        #expect(state.nextToken == nil)
        #expect(!state.complete)
        #expect(state.search == .waiting)
    }

    // MARK: - Pages and completeness

    /// An empty page that is not complete is **still scanning**, never "no
    /// results"; only a clean end may say there are none.
    @Test func testAnEmptyIncompletePageIsStillScanning() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()

        state.absorb(ready(anchors: [], stop: "budget", token: token))
        #expect(state.search == .scanningMore)
        #expect(state.hits.isEmpty)
        #expect(state.hasMore)

        state.absorb(ready(anchors: [], stop: "at_end"))
        #expect(state.search == .noResults)
        #expect(!state.hasMore)
    }

    @Test func testResultsAreDeduplicatedByAnchorAndKeepScanningState() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()

        state.absorb(ready(anchors: ["p:3", "p:2"], stop: "full", token: token))
        #expect(state.search == .scanningMore)
        #expect(state.hits.map(\.message.anchor) == ["p:3", "p:2"])

        state.absorb(ready(anchors: ["p:2", "p:1"], stop: "at_end"))
        #expect(state.search == .results)
        #expect(state.hits.map(\.message.anchor) == ["p:3", "p:2", "p:1"])
        #expect(state.complete)
    }

    /// A gap or a restarted range is not a complete search, even at the end.
    @Test func testAGapOrRestartIsNotComplete() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.absorb(ready(anchors: ["p:1"], stop: "at_end", gap: true))
        #expect(!state.complete)
        #expect(state.dirty)
        #expect(state.search == .results)

        state.absorb(ready(anchors: [], stop: "at_end", restarted: true))
        #expect(!state.complete)
        #expect(state.dirty)
        #expect(state.search == .results)
    }

    @Test func testFailureAndCancellationAreDifferentStatesAndKeepHits() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.absorb(ready(anchors: ["p:1"]))

        state.fail("CursorMismatch")
        #expect(state.search == .failed("CursorMismatch"))
        #expect(state.hits.count == 1)

        state.cancel()
        #expect(state.search == .cancelled)
        #expect(state.hits.count == 1)
    }

    @Test func testOnlyAResultInTheListCanBeSelected() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.absorb(ready(anchors: ["p:1"]))
        state.select("p:9")
        #expect(state.selected == nil)
        state.select("p:1")
        #expect(state.selected == "p:1")
        #expect(state.selectedHit?.message.anchor == "p:1")
    }

    /// **A dirty page is sticky.** A later clean end cannot take back that
    /// records were damaged: completeness is never restored mid-search.
    @Test func testADirtyPageKeepsALaterCleanEndIncomplete() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.absorb(ready(anchors: ["p:2"], stop: "full", token: token, gap: true))
        #expect(state.dirty)
        #expect(state.search == .scanningMore)
        state.absorb(ready(anchors: ["p:1"], stop: "at_end"))
        #expect(!state.complete)
        #expect(state.dirty)
        #expect(state.search == .results)
    }

    /// A fresh search starts from nothing; a retry keeps what is here.
    @Test func testAFreshSubmitClearsTheAccumulatedResults() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.absorb(ready(anchors: ["p:1"], stop: "full", token: token))
        #expect(!state.hits.isEmpty)

        _ = state.submit()
        #expect(state.hits.isEmpty)
        #expect(state.nextToken == nil)
        #expect(!state.complete)
        #expect(!state.dirty)
        #expect(state.search == .searching)
    }

    /// Closing or previewing ends an in-flight page but keeps the results a
    /// later opening can continue from.
    @Test func testPauseEndsAnInFlightStateButKeepsResults() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.pause()
        #expect(state.search == .idle)

        state.absorb(ready(anchors: ["p:1"], stop: "full", token: token))
        #expect(state.search == .scanningMore)
        state.pause()
        // Paused is **not** still scanning: it has results and a cursor and
        // no job; Load more continues it.
        #expect(state.search == .paused)
        #expect(state.hits.count == 1)
        #expect(state.nextToken == token)
    }

    /// The hit list is bounded; dropping the oldest matches is said, and a
    /// fresh search is the recovery.
    @Test func testTheHitListIsBoundedAndSaidSo() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        let anchors = (1...(State.hitLimit + 1)).map { "p:\($0)" }
        state.absorb(ready(anchors: anchors))
        #expect(state.hits.count == State.hitLimit)
        #expect(state.hitsTrimmed)
        // The sliding window keeps the edge being scanned, not the newest:
        // p:1 fell off the front and p:501 is here to continue from.
        #expect(state.hits.first?.message.anchor == "p:2")
        #expect(state.hits.last?.message.anchor == "p:\(State.hitLimit + 1)")
    }

    // MARK: - Preview and back

    /// Opening a preview from a search remembers the query, hits, selection
    /// and cursor; going back restores all of them.
    @Test func testPreviewFromSearchReturnsToTheSameResults() {
        var state = State()
        state.openSearch()
        state.typing("批量")
        _ = state.submit()
        state.absorb(ready(anchors: ["p:3", "p:2"], stop: "full", token: token))
        state.select("p:2")

        let source = State.PreviewSource(group: "polter", anchor: "p:2", reference: "a.md")
        state.openPreview(source)
        #expect(state.mode == .preview)
        state.previewFailed("NotAFileReference")
        #expect(state.preview == .failed(source, "NotAFileReference"))

        state.backToSearch()
        #expect(state.mode == .search)
        #expect(state.query == "批量")
        #expect(state.submitted == "批量")
        #expect(state.hits.map(\.message.anchor) == ["p:3", "p:2"])
        #expect(state.selected == "p:2")
        #expect(state.nextToken == token)
        #expect(state.search == .scanningMore)
        #expect(state.saved == nil)
    }

    /// A preview not opened from a search has nothing to go back to and
    /// closes the slot instead of showing an empty search.
    @Test func testPreviewWithoutASearchClosesOnBack() {
        var state = State()
        let source = State.PreviewSource(group: "polter", anchor: "p:1", reference: "a.md")
        state.openPreview(source)
        state.backToSearch()
        #expect(state.mode == .closed)
    }
}

/// Where the chat's one right-hand slot goes (task 2982, the supervisor's
/// ruling of 2026-11-05): the threshold is the preview rule's 800, the slot
/// is 330, and below the threshold the message column is not squeezed.
struct ControlRoomChatSidebarLayoutTests {
    typealias Layout = ControlRoomChatSidebarLayout

    @Test func testClosedGivesTheWholePageToTheMessageColumn() {
        let split = Layout.split(pageW: 1000, open: false)
        #expect(split.messageWidth == 1000)
        #expect(split.sidebarWidth == 0)
        #expect(!split.overlay)
    }

    @Test func testAPageAtTheThresholdPutsTheSlotBesideIt() {
        let split = Layout.split(pageW: 800, open: true)
        #expect(!split.overlay)
        #expect(split.sidebarWidth == 330)
        #expect(split.messageWidth == 470)
        #expect(split.sidebarX == 470)
    }

    @Test func testOnePointUnderTheThresholdIsOverTheRightEdge() {
        let split = Layout.split(pageW: 799, open: true)
        #expect(split.overlay)
        #expect(split.sidebarWidth == 330)
        // **Not squeezed**: the message column keeps the page's width.
        #expect(split.messageWidth == 799)
        #expect(split.sidebarX == 469)
    }

    @Test func testAWidePageLeavesTheMessageColumnTheRest() {
        let split = Layout.split(pageW: 1600, open: true)
        #expect(!split.overlay)
        #expect(split.sidebarWidth == 330)
        #expect(split.messageWidth == 1270)
    }

    @Test func testDegenerateWidthsNeverGoNegative() {
        for width in [CGFloat(0), -5, .nan, .infinity] {
            let split = Layout.split(pageW: width, open: true)
            #expect(split.messageWidth >= 0)
            #expect(split.sidebarWidth >= 0)
            #expect(split.sidebarX >= 0)
        }
    }
}
