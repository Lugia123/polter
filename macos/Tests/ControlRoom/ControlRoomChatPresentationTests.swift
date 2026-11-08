import CoreGraphics
import Foundation
import Testing

@testable import Ghostty

/// The message list's own rules (task 2969 B): where a released run is drawn,
/// what a row says about time and metadata, and where the reader's anchor is
/// after a layout change.
///
/// **The list inputs are real**: whole id arrays and the feed's two gap
/// markers, not one field at a time. A plan that draws p:101 next to p:152 is
/// the defect this suite exists to catch.
struct ControlRoomChatPresentationTests {
    typealias P = ControlRoomChatPresentation
    typealias A = ControlRoomChatAnchor
    typealias C = ControlRoomChatCamera
    typealias I = ControlRoomChatIndexBar
    typealias W = ControlRoomChatWindow

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func ms(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        return Int64(utc.date(from: parts)!.timeIntervalSince1970 * 1000)
    }

    // MARK: - The drawn list

    /// A released run between two kept messages is its own row: the two
    /// messages are not adjacent in the plan.
    @Test func testAReleasedRunIsItsOwnRow() {
        let rows = P.listRows(
            order: ["p:101", "p:152"],
            trimmedBefore: nil,
            trimmedAfter: "p:101"
        )
        #expect(rows == [
            .message(id: "p:101"),
            .gap(.after("p:101")),
            .message(id: "p:152"),
        ])
        #expect(rows.filter { if case .message = $0 { return true } else { return false } }.count == 2)
    }

    /// Records older than the first kept message went: said above it.
    @Test func testAGapBeforeTheFirstKeptMessageIsDrawnFirst() {
        let rows = P.listRows(
            order: ["p:2", "p:3"],
            trimmedBefore: "p:2",
            trimmedAfter: nil
        )
        #expect(rows == [
            .gap(.before("p:2")),
            .message(id: "p:2"),
            .message(id: "p:3"),
        ])
    }

    @Test func testAContiguousWindowHasNoGapRow() {
        let rows = P.listRows(order: ["p:1", "p:2"], trimmedBefore: nil, trimmedAfter: nil)
        #expect(rows == [.message(id: "p:1"), .message(id: "p:2")])
    }

    /// The row `trimmedAfter` named may itself have been released since. The
    /// gap is still real, and **it is newer than everything kept** -- the
    /// window slid past it -- so it is said after the last row. A top gap
    /// would claim the missing records are older than what is drawn.
    @Test func testAnUnplaceableGapIsStillSaid() {
        let rows = P.listRows(
            order: ["p:200", "p:201"],
            trimmedBefore: nil,
            trimmedAfter: "p:101"
        )
        #expect(rows == [
            .message(id: "p:200"),
            .message(id: "p:201"),
            .gap(.after("p:201")),
        ])
    }

    /// Every row the list draws has its own stable identity, and a message's
    /// is never the same as a gap's.
    @Test func testPlanRowIdsAreStableAndDistinct() {
        let rows = P.listRows(
            order: ["p:1", "p:2"],
            trimmedBefore: nil,
            trimmedAfter: "p:1"
        )
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows[0].id == "m:p:1")
        #expect(rows[1].id == "g:after:p:1")
    }

    // MARK: - Time and dates

    @Test func testADayDividerOnlyWhenTheLocalDayChanges() {
        let morning = ms(2026, 11, 4, 9, 0)
        let evening = ms(2026, 11, 4, 23, 0)
        let tomorrow = ms(2026, 11, 5, 0, 1)
        #expect(P.needsDayDivider(previous: nil, current: morning, calendar: utc))
        #expect(!P.needsDayDivider(previous: morning, current: evening, calendar: utc))
        #expect(P.needsDayDivider(previous: evening, current: tomorrow, calendar: utc))
        #expect(P.dayKey(atMs: morning, calendar: utc) == 20_261_104)
        #expect(P.dayKey(atMs: tomorrow, calendar: utc) == 20_261_105)
    }

    @Test func testTheClockIsTheLocalParts() {
        #expect(P.timeText(atMs: 0, calendar: utc) == "00:00:00")
        #expect(P.timeText(atMs: 3_661_000, calendar: utc) == "01:01:01")
        #expect(P.timeText(atMs: ms(2026, 11, 4, 10, 12) + 5_000, calendar: utc) == "10:12:05")
    }

    // MARK: - Role, channel, mentions, brief

    /// A mention keeps the title it was named with; the id is only the
    /// fallback a line that recorded no title has.
    @Test func testAMentionUsesItsRecordedTitleThenItsId() {
        #expect(P.mentionText(.init(id: "0x01", title: "总管")) == "@总管")
        #expect(P.mentionText(.init(id: "0x01", title: nil)) == "@0x01")
        #expect(P.mentionText(.init(id: "0x01", title: "")) == "@0x01")
    }

    /// **Any non-empty brief can be expanded.** Seventy Chinese characters
    /// in a narrow window are more than two lines, and a length heuristic
    /// would make the tail unreachable.
    @Test func testEveryNonEmptyBriefCanBeExpanded() {
        #expect(!P.showsBriefToggle(""))
        #expect(P.showsBriefToggle("短简述"))
        #expect(P.showsBriefToggle("第一行\n第二行"))
        #expect(P.showsBriefToggle(String(repeating: "长", count: 70)))
    }

    // MARK: - The speaker's rule

    /// **A hairline goes where the speaker changes, and nowhere else**
    /// (task 2999 ①): "A, A, B" is no rule, no rule, rule.
    @Test func testAPlaceHoldsOnlyWhereTheSpeakerChanges() {
        let a = P.Speaker(author: "test-worker", role: "开发", channel: 2999, summary: false)
        let b = P.Speaker(author: "reviewer", role: "审核", channel: 2999, summary: false)
        #expect(P.speakerRules([a, a, b]) == [false, false, true])
        #expect(P.speakerRules([b, a, b]) == [false, true, true])
        #expect(P.speakerRules([a]) == [false])
        #expect(P.speakerRules([P.Speaker]()) == [Bool]())
    }

    /// The comparison is over all four facts: a new role or a new channel
    /// under one name is a change of subject, an empty role is no role, and
    /// a handover summary is not the person who spoke before it.
    @Test func testARoleOrChannelChangeIsASpeakerChange() {
        let plain = P.Speaker(author: "w", role: nil, channel: 0, summary: false)
        #expect(P.Speaker(author: "w", role: "", channel: 0, summary: false) == plain)
        #expect(plain.role == nil)
        #expect(P.needsSpeakerRule(
            previous: plain,
            current: .init(author: "w", role: "dev", channel: 0, summary: false)))
        #expect(P.needsSpeakerRule(
            previous: plain,
            current: .init(author: "w", role: nil, channel: 2999, summary: false)))
        #expect(P.needsSpeakerRule(
            previous: plain,
            current: .init(author: "", role: nil, channel: 0, summary: true)))
        // The first row has no rule above it: its day divider is the line.
        #expect(!P.needsSpeakerRule(previous: nil, current: plain))
    }

    @Test func testTheNameARowIsDrawnUnder() {
        #expect(P.authorText(author: "worker", fromSelf: false) == "worker")
        #expect(!P.authorText(author: "", fromSelf: true).isEmpty)
        #expect(P.authorText(author: "", fromSelf: false) == "")
    }

    /// **Nothing is put back under a hand that is on the list** (task 2999
    /// ③, kept as R1-2). A projection that ran during a wheel or a live
    /// scroll moved the viewport at the same time as the reader, and the list
    /// jumped at a point part-way up while the scroller still reached the
    /// top. **What is owed is not dropped either**: the projection stays in
    /// the state and is paid once the hand leaves.
    @Test func testAProjectionIsNotRunUnderAHandOnTheList() {
        #expect(C.mayProject(userScrolling: false, readerRecently: false))
        #expect(!C.mayProject(userScrolling: true, readerRecently: false))
        #expect(!C.mayProject(userScrolling: false, readerRecently: true))
        #expect(!C.mayProject(userScrolling: true, readerRecently: true))

        // A layout callback while a projection is owed leaves it owed.
        var state = C.State(
            place: .init(id: "c", offset: 3), pinned: false, owed: .wait("c"))
        let wrote = state.bounds(
            cause: .layout, y: 0, order: ["a", "b", "c"], frames: frames)
        #expect(!wrote)
        #expect(state.owed == .wait("c"))
    }

    // MARK: - The camera's primitives

    private var frames: [String: CGRect] {
        [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
            "c": CGRect(x: 0, y: 40, width: 100, height: 10),
        ]
    }

    /// A taller row above moves the frame; the projection is the row's new
    /// top plus the same offset **in points**.
    private var tallerFrames: [String: CGRect] {
        [
            "a": CGRect(x: 0, y: 0, width: 100, height: 30),
            "b": CGRect(x: 0, y: 40, width: 100, height: 10),
            "c": CGRect(x: 0, y: 60, width: 100, height: 10),
        ]
    }

    /// **The inverse is the last row whose top is at or above the line**
    /// (R2-3's rule, the same as Windows'). Inside a row, in the gap below
    /// it, and exactly on its top all name a row and keep the distance.
    @Test func testThePlaceIsTheLastRowWhoseTopIsAboveTheViewport() {
        #expect(C.place(order: ["a", "b", "c"], frames: frames, at: 25)
                == .init(id: "b", offset: 5))
        #expect(C.place(order: ["a", "b", "c"], frames: frames, at: 0)
                == .init(id: "a", offset: 0))
        // 15 sits in the 10pt gap between a (0..10) and b (20..30): the last
        // row whose top is above it is still a, offset 15.
        #expect(C.place(order: ["a", "b", "c"], frames: frames, at: 15)
                == .init(id: "a", offset: 15))
        // Above every measured row (the list's own 12pt top padding): the
        // first row with the distance kept **negative**, which projects back
        // to the same point (the Windows seat's rule).
        let padded: [String: CGRect] = [
            "a": CGRect(x: 0, y: 12, width: 100, height: 10),
        ]
        #expect(C.place(order: ["a"], frames: padded, at: 5)
                == .init(id: "a", offset: -7))
        #expect(C.y(of: .init(id: "a", offset: -7), frames: padded) == 5)
        // Nothing measured is the only "no basis" answer.
        #expect(C.place(order: ["a", "b", "c"], frames: [:], at: 5) == nil)
    }

    /// **`y → place → y` is lossless in all three positions** (R2-3), to
    /// within half a point: inside a row, in the gap below one, and exactly
    /// on a row's top.
    @Test func testThePlaceRoundTripsToTheSamePoint() {
        for y in [25.0, 15.0, 20.0, 43.0, 0.0] {
            guard let place = C.place(order: ["a", "b", "c"], frames: frames, at: y)
            else {
                Issue.record("no place for \(y)")
                continue
            }
            let back = C.y(of: place, frames: frames)
            #expect(back != nil)
            if let back { #expect(abs(back - y) <= 0.5) }
        }
        // ... the same round trip above the first measured row, where the
        // offset is negative (the top padding).
        let padded: [String: CGRect] = [
            "a": CGRect(x: 0, y: 12, width: 100, height: 10),
        ]
        guard let above = C.place(order: ["a"], frames: padded, at: 5) else {
            Issue.record("no place in the padding")
            return
        }
        #expect(above.offset < 0)
        let back = C.y(of: above, frames: padded)
        #expect(back != nil)
        if let back { #expect(abs(back - 5) <= 0.5) }
    }

    /// **R2-2: a programmatic scroll is converted to a place first**, so the
    /// projection that follows it lands on the same point instead of undoing
    /// it. This is the page/seek/clamp rule stated without a window.
    @Test func testAProgrammaticScrollProjectsBackToTheSamePoint() {
        let target = 45.0
        guard let place = C.place(order: ["a", "b", "c"], frames: frames, at: target)
        else {
            Issue.record("no place for \(target)")
            return
        }
        let back = C.y(of: place, frames: frames)
        #expect(back != nil)
        if let back { #expect(abs(back - target) <= 0.5) }
    }

    /// The place keeps its **points** when a row above is re-measured
    /// taller: the same words, not the same fraction of a new height (R1-9).
    @Test func testThePlaceKeepsItsPointsWhenTheRowIsRemeasured() {
        let place = C.Place(id: "b", offset: 5)
        #expect(C.y(of: place, frames: frames) == 25)
        #expect(C.y(of: place, frames: tallerFrames) == 45)
        #expect(C.y(of: .init(id: "gone", offset: 5), frames: frames) == nil)
    }

    @Test func testTheBottomIsWhereTheViewportEnds() {
        #expect(A.isAtBottom(offset: 200, viewport: 400, content: 600))
        #expect(A.isAtBottom(offset: 198, viewport: 400, content: 600))
        #expect(!A.isAtBottom(offset: 190, viewport: 400, content: 600))
        #expect(A.isAtBottom(offset: 0, viewport: 400, content: 100))
    }

    /// **The band is 8 pt**: half a text line, which is above the view's own
    /// measurement jitter (16–18 pt, so the jitter is *outside* it) and below
    /// one wheel notch (20–40 pt, so a deliberate scroll is outside it too).
    /// This pins the number itself -- the default, not a passed tolerance --
    /// because that is the one thing the run was changed for.
    @Test func testTheBottomBandIsEightPoints() {
        let atTheEdge = 600.0 - (192.0 + 400.0)   // 8 pt above the end
        let justOutside = 600.0 - (191.0 + 400.0) // 9 pt
        #expect(A.isAtBottom(offset: 192, viewport: 400, content: 600))
        #expect(!A.isAtBottom(offset: 191, viewport: 400, content: 600))
        #expect(atTheEdge == 8)
        #expect(justOutside == 9)
    }

    // MARK: - The camera's state machine (the old Keeper's tests)

    /// **Only a callback the reader caused writes the place** (old tests
    /// `testALayoutCallbackDoesNotOverwriteTheAnchor` and
    /// `testBothCallbackOrdersLeaveTheAnchorWhereItWas`, both branches kept).
    /// A layout callback -- with the old frames or the new -- leaves the
    /// camera alone; the correction is projected *from* it.
    @Test func testOnlyAUserCallbackWritesThePlace() {
        var state = C.State()
        let wrote = state.bounds(
            cause: .user, y: 25, order: ["a", "b", "c"], frames: frames)
        #expect(wrote)
        #expect(state.place == .init(id: "b", offset: 5))
        #expect(!state.pinned)

        // Both callback orders: bounds arriving with the old frames
        // (bounds-first), and the stash already refreshed (frames-first).
        for list in [frames, tallerFrames] {
            var kept = C.State(place: .init(id: "b", offset: 5), pinned: false)
            let layout = kept.bounds(
                cause: .layout, y: 55, order: ["a", "b", "c"], frames: list)
            #expect(!layout)
            #expect(kept.place == .init(id: "b", offset: 5))
            let projected = C.y(of: .init(id: "b", offset: 5), frames: tallerFrames)
            #expect(projected == 45)
            if let projected { #expect(abs(projected - 45) <= 0.5) }
        }
    }

    /// **The view's own scroll is not the reader** (old test
    /// `testAProgrammaticScrollDoesNotMoveTheAnchor`).
    @Test func testAProgrammaticScrollDoesNotWriteThePlace() {
        #expect(C.writesPlace(cause: .user))
        #expect(!C.writesPlace(cause: .layout))
        #expect(!C.writesPlace(cause: .programmatic))

        var state = C.State(place: .init(id: "b", offset: 5), pinned: false)
        let wrote = state.bounds(
            cause: .programmatic, y: 0, order: ["a", "b", "c"], frames: frames)
        #expect(!wrote)
        #expect(state.place == .init(id: "b", offset: 5))
    }

    /// A place kept across a showing projects from **fresh** frames (old test
    /// `testASeededPositionCanBeRestored`, first half).
    @Test func testATabReturnedPlaceProjectsFromFreshFrames() {
        let place = C.Place(id: "c", offset: 3)
        #expect(C.y(of: place, frames: frames) == 43)
        #expect(C.y(of: place, frames: tallerFrames) == 63)
    }

    /// ... and while its row is unmeasured it **asks for it by name** rather
    /// than scrolling to a guess (old test `testASeededPositionCanBeRestored`,
    /// second half; R1-3's two-stage jump).
    @Test func testAnUnmeasuredPlaceAsksForItsRow() {
        let unmeasured: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
        ]
        let state = C.State(place: .init(id: "c", offset: 3), pinned: false)
        let projection = C.projection(
            state: state, order: ["a", "b", "c"], frames: unmeasured,
            content: 100, viewport: 40, centre: 20)
        // **Waiting, not seeking** (MF1): this place is not a jump, so the
        // row will be measured by the layout that is about to run.
        #expect(projection == .wait("c"))
    }

    /// **A hand takes the place and voids what was owed** (old tests
    /// `testAUserScrollCancelsARestore` and `testTheReaderCancelsTheOwedPlace`,
    /// both owed states kept).
    @Test func testAUserScrollTakesThePlaceAndCancelsTheOwed() {
        for owed in [C.Projection.wait("c"), .fallback(.init(id: "b", offset: 5))] {
            var state = C.State(
                place: .init(id: "c", offset: 3), pinned: false, owed: owed)
            let wrote = state.bounds(
                cause: .user, y: 25, order: ["a", "b", "c"], frames: frames)
            #expect(wrote)
            #expect(state.owed == nil)
            #expect(state.place == .init(id: "b", offset: 5))
            #expect(!state.pinned)
        }
    }

    /// **A projection owed against a version of the frames may only be
    /// answered by a newer one** (old tests
    /// `testALayoutCallbackWithTheSameFramesKeepsTheOwedPlace` and
    /// `testARestoreIsOnlySpentOnceTheFramesMovedOn`, merged).
    @Test func testAOwedProjectionIsNotAnsweredByTheFramesItWasFrozenAgainst() {
        #expect(!C.mayAnswer(framesEpoch: 7, waitingSince: 7))
        #expect(!C.mayAnswer(framesEpoch: 6, waitingSince: 7))
        #expect(C.mayAnswer(framesEpoch: 8, waitingSince: 7))

        // And the same fact from the projection's side: the row the place
        // names is still unmeasured in the map it was frozen against, so the
        // projection asks for it rather than scrolling to the old frame.
        let state = C.State(place: .init(id: "c", offset: 3), pinned: false)
        let unmeasured: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
        ]
        #expect(C.projection(
            state: state, order: ["a", "b", "c"], frames: unmeasured,
            content: 100, viewport: 40, centre: 20
        ) == .wait("c"))
    }

    /// **A bottom owed before the reader moved is not performed** (old test
    /// `testAFollowIntentIsDroppedByAUserScroll`, and R1-7's transfer).
    @Test func testABottomOwedBeforeTheReaderMovedIsNotPerformed() {
        #expect(!C.pinned(after: .user, atBottom: false, was: true, hand: true))
        #expect(C.pinned(after: .user, atBottom: true, was: false, hand: true))
        // **A `.user` without a hand changes nothing.** `cause` falls back to
        // `.user` for a callback none of its tests explains, and a page's
        // first layout is exactly that -- the clip at `offset = 1` of
        // 22 277 pt before the bottom projection has run. Judging the pin
        // from it opened the page in the middle of the history.
        #expect(C.pinned(after: .user, atBottom: false, was: true, hand: false))
        #expect(!C.pinned(after: .user, atBottom: true, was: false, hand: false))
        // A layout or the view's own scroll changes nothing, even at the
        // bottom: only the reader pins or unpins.
        #expect(!C.pinned(after: .layout, atBottom: true, was: false, hand: true))
        #expect(C.pinned(after: .programmatic, atBottom: false, was: true, hand: true))

        // **The pair, in the view's order** (R1-7): `bounds` first (it
        // voids the owed bottom and unpins), then `pinned(after:)`. A reader
        // who lands on the bottom ends up pinned with nothing owed -- the
        // intermediate `false` must not survive, and must not eat `.pin`.
        var state = C.State(
            place: .init(id: "b", offset: 5), pinned: false, owed: .pin)
        state.bounds(cause: .user, y: 43, order: ["a", "b", "c"], frames: frames)
        state.pinned = C.pinned(after: .user, atBottom: true, was: state.pinned, hand: true)
        #expect(state.pinned)
        #expect(state.owed == nil)
        #expect(state.place == .init(id: "c", offset: 3))
    }

    /// **A page opens at the bottom and stays there** (2026-11-07: it opened
    /// at `offset = 1` of 22 277 pt, showed #809 instead of the newest
    /// message, and its very first action was to evict the newer side --
    /// which only a viewport that thinks it is *not* at the bottom does).
    @Test func testAPageOpensAtTheBottomAndStaysThere() {
        // The opening layout's callback is not the reader: pinned stays.
        #expect(C.pinned(after: .user, atBottom: false, was: true, hand: false))
        // **A pinned viewport's top is the document's end**, not the clip's
        // 1, and that is what the decision is taken from.
        let content = 22277.0
        let viewport = 968.0
        let top = W.viewportTop(pinned: true, content: content, viewport: viewport, offset: 1)
        #expect(top == content - viewport)
        let decision = W.decide(
            W.Reading(top: top, viewport: viewport, content: content,
                      loadedTop: 0, rowHeight: 92),
            aboveRows: 0, belowRows: 0,
            documentAbove: 197, documentBelow: 0,
            hasEarlier: true, hasNewer: false
        )
        // **The first action is never "the newer side is over retain"**: at
        // the bottom there is no newer side below the viewport at all.
        if case .releaseNewer = decision.evict {
            Issue.record("a page that opens at the bottom evicted the newer side")
        }
        #expect(decision.feed == .none)
    }

    /// **The document's height comes from the rows, not from the scroll
    /// view** (2026-11-07, the page that never reached the bottom): 192 rows
    /// were in the frames -- 21 504 pt of them -- while the scroll view still
    /// answered 24. A pinned projection that asked `pinIsAvailable` of the 24
    /// waited for a document it already had.
    @Test func testTheDocumentHeightComesFromTheRowsBeforeTheScrollView() {
        var order: [String] = []
        var frames: [String: CGRect] = [:]
        for i in 0..<192 {
            let id = "p:\(i)"
            order.append(id)
            frames[id] = CGRect(x: 0, y: CGFloat(i) * 112, width: 300, height: 112)
        }
        let content = W.documentHeight(order: order, frames: frames, live: 24)
        #expect(content == 192 * 112)
        // **A last row the lazy stack has not made**: the tallest measured
        // bottom is still the document's.
        var sparse = frames
        sparse.removeValue(forKey: order.last!)
        #expect(W.documentHeight(order: order, frames: sparse, live: 24) == 191 * 112)
        // Nothing measured at all: the scroll view's own word is all there is.
        #expect(W.documentHeight(order: order, frames: [:], live: 24) == 24)
        // **The decision that reads it**: pinned, the document is far taller
        // than the viewport, so the answer is a pin and its target is the
        // document's end -- not a wait.
        #expect(W.viewportTop(pinned: true, content: content, viewport: 968, offset: 0)
                == content - 968)
        #expect(C.projection(
            state: C.State(place: nil, pinned: true), order: order, frames: frames,
            content: content, viewport: 968, centre: 0
        ) == .pin)
    }

    /// **The fallback picks the nearest measured row** (old test
    /// `testTheRecoveryPicksTheNearestMeasuredRow`, unchanged assertions).
    @Test func testAFallbackPicksTheNearestMeasuredRow() {
        let list = frameMap([40, 40, 40])
        // Rows at 0..40, 50..90, 100..140; a viewport centred at 78 is
        // nearest r1 (mid 70), not r2 (mid 120).
        #expect(C.nearestMeasured(
            centre: 78, order: list.order, frames: list.frames) == "r1")
        #expect(C.nearestMeasured(
            centre: 0, order: list.order, frames: list.frames) == "r0")
        #expect(C.nearestMeasured(
            centre: 300, order: list.order, frames: list.frames) == "r2")
        #expect(C.nearestMeasured(
            centre: 300, order: list.order, frames: [:]) == nil)
        // **A measured row that is no longer in the window is not a
        // candidate**: it is what a trim leaves behind, and landing on it
        // would project into a place that no longer exists. `gone` is at
        // 53..93 (mid 73), *nearer* the centre than r1's 70, so an
        // unfiltered search would pick it.
        var stale = list.frames
        stale["gone"] = CGRect(x: 0, y: 53, width: 300, height: 40)
        #expect(C.nearestMeasured(
            centre: 78, order: list.order, frames: stale) == "r1")
        #expect(C.nearestMeasured(centre: 73, order: [], frames: stale) == nil)
    }

    /// **A place whose row is gone falls back instead of waiting** (new,
    /// R1-4). "I do not know yet" and "I know it is gone" are different
    /// answers, and only the second may move the camera.
    @Test func testAPlaceWhoseRowIsGoneFallsBackInsteadOfWaiting() {
        let state = C.State(place: .init(id: "gone", offset: 5), pinned: false)
        let projection = C.projection(
            state: state, order: ["a", "b", "c"], frames: frames,
            content: 100, viewport: 40, centre: 25)
        // **The nearest row, with the offset inside it kept** (M2): b spans
        // 20..30, and the top edge at 25 is 5 points into it. Scrolling to
        // b's top instead would jump half a viewport.
        #expect(projection == .fallback(.init(id: "b", offset: 5)))
        #expect(projection != .wait("gone"))

        // Nothing measured: no row to fall back to, still not `wait`.
        let empty = C.projection(
            state: state, order: ["a", "b", "c"], frames: [:],
            content: 0, viewport: 40, centre: 0)
        #expect(empty == .fallback(nil))
    }

    /// **A jump to a row the lazy stack has not made asks for it by name**
    /// (new, R1-3). **A row that is merely not measured waits** (MF1): only
    /// a jump's own row may make the view scroll before the frames arrive.
    @Test func testJumpToAnUnmeasuredRowAsksForItByName() {
        let state = C.State(place: .init(id: "x", offset: 0), pinned: false)
        let unmeasured: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
        ]
        // No jump named it: this is a row about to be measured, not a jump.
        #expect(C.projection(
            state: state, order: ["a", "x"], frames: unmeasured,
            content: 100, viewport: 40, centre: 5
        ) == .wait("x"))
        // The jump that named it is the one allowed to seek.
        #expect(C.projection(
            state: state, order: ["a", "x"], frames: unmeasured,
            content: 100, viewport: 40, centre: 5, pending: "x"
        ) == .scrollTo("x"))

        let measured: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "x": CGRect(x: 0, y: 20, width: 100, height: 10),
        ]
        #expect(C.projection(
            state: state, order: ["a", "x"], frames: measured,
            content: 100, viewport: 40, centre: 5
        ) == .scroll(20))
    }

    /// **A jump still on its way is not a lost place** (M1): the place names
    /// a row the map does not have yet, and that must wait, not fall back.
    @Test func testAJumpWhoseRowIsNotLoadedYetWaitsInsteadOfFallingBack() {
        let state = C.State(place: .init(id: "far", offset: 0), pinned: false)
        let projection = C.projection(
            state: state, order: ["a", "b", "c"], frames: frames,
            content: 100, viewport: 40, centre: 25, pending: "far")
        #expect(projection == .wait("far"))
        #expect(projection != .fallback(.init(id: "b", offset: 5)))
        // The same place with no jump in flight *is* gone.
        #expect(C.projection(
            state: state, order: ["a", "b", "c"], frames: frames,
            content: 100, viewport: 40, centre: 25
        ) == .fallback(.init(id: "b", offset: 5)))
    }

    /// **A pinned projection needs content taller than the viewport, and
    /// nothing else** (R1-6, revised by MF1). `scroll to max` works against
    /// the estimated document, so no row has to be measured.
    @Test func testAPinnedProjectionWaitsUntilThereIsABottom() {
        // **The first screen is pinned before anything else happens** (task
        // 3016 §4). This is the default the view's first render reads: there
        // is no landing action that could fail and be lost.
        #expect(C.State().pinned)
        #expect(!C.pinIsAvailable(content: 0, viewport: 600))
        #expect(!C.pinIsAvailable(content: 400, viewport: 600))
        #expect(C.pinIsAvailable(content: 800, viewport: 600))

        let state = C.State(place: nil, pinned: true)
        // An empty map has no row to name: `nil`, not the empty string.
        #expect(C.projection(
            state: state, order: [], frames: [:],
            content: 0, viewport: 600, centre: 0
        ) == .wait(nil))
        // **No camera and no place are the same "not yet"**.
        let unpinned = C.State(place: nil, pinned: false)
        #expect(C.projection(
            state: unpinned, order: [], frames: [:],
            content: 0, viewport: 600, centre: 0
        ) == .wait(nil))
        let frames: [String: CGRect] = ["a": CGRect(x: 0, y: 0, width: 100, height: 40)]
        // Content taller than the viewport pins even though the last row has
        // not been measured: that is what stops the first screen's seek.
        #expect(C.projection(
            state: state, order: ["a"], frames: frames,
            content: 800, viewport: 600, centre: 400
        ) == .pin)
    }

    /// **The capacity, in one place** (the 2026-11-07 capacity red): ten
    /// screens of margin, twelve of retention, twelve for the first screen,
    /// a 40-row request floor. Changing one without the others is what the
    /// red was; these are the numbers the person checks on the real machine.
    @Test func testTheWindowCapacityIsTheAgreedOne() {
        #expect(W.marginScreens == 10)
        #expect(W.retainScreens == 12)
        #expect(W.firstScreenScreens == 12)
        #expect(W.requestFloor == 40)
    }

    /// **A world where points and rows agree**: this many rows either side of
    /// the camera row, all one height, the viewport `top` points in. The rule
    /// turns points into rows with the document's own average, which in a
    /// world like this is exactly `height` -- so every expectation below is
    /// arithmetic the test can do, not a number copied out of the rule.
    ///
    /// `rowHeight` is what the view would publish as its median (the few rows
    /// it has laid out); passing one that disagrees with `height` is the real
    /// machine, and is how the ruler is tested.
    private func windowDecision(
        top: Double,
        height: Double = 20,
        viewport: Double = 800,
        rowsAbove: Int,
        rowsBelow: Int,
        aboveRows: Int = 0,
        belowRows: Int = 0,
        hasEarlier: Bool = true,
        hasNewer: Bool = false,
        rowHeight: Double? = nil
    ) -> W.Decision {
        let content = Double(rowsAbove + 1 + rowsBelow) * height
        let reading = W.Reading(
            top: top, viewport: viewport, content: content, loadedTop: 0,
            rowHeight: rowHeight ?? height
        )
        return W.decide(
            reading,
            aboveRows: aboveRows, belowRows: belowRows,
            documentAbove: rowsAbove, documentBelow: rowsBelow,
            hasEarlier: hasEarlier, hasNewer: hasNewer
        )
    }

    /// **The step is the drawn margin's shortfall** (the capacity model):
    /// the rows between the viewport and the document's edge are what the
    /// reader sees, and one step spends the apron to put them back at the
    /// margin -- the amount is what was consumed, not a fixed row count.
    @Test func testTheStepIsTheDrawnMarginsShortfall() {
        // At the margin: nothing to do.
        #expect(windowDecision(top: 8000, rowsAbove: 400, rowsBelow: 400).feed == .none)
        // 7900 pt missing in 16 pt rows is 494 rows; the apron has 100.
        #expect(windowDecision(
            top: 100, height: 16, rowsAbove: 40, rowsBelow: 40,
            aboveRows: 100, belowRows: 500, hasNewer: true
        ).feed == .intakeOlder(100))
        // **The same shortfall in taller rows is fewer rows, not less
        // height**: 7900 pt of 200 pt rows is 40 rows; the apron has 30.
        #expect(windowDecision(
            top: 100, height: 200, rowsAbove: 40, rowsBelow: 40, aboveRows: 30
        ).feed == .intakeOlder(30))
        // **No ceiling on the row count**: a ten-screen shortfall with the
        // apron to cover it goes in one rows change.
        #expect(windowDecision(
            top: 0, rowsAbove: 0, rowsBelow: 400, aboveRows: 200
        ).feed == .intakeOlder(200))
        // **The drawn margin is what is fed, not the loaded total**: 6000
        // drawn + a 300-row apron is over the margin, but the reader's own
        // margin is still two screens short and takes them from the apron.
        #expect(windowDecision(
            top: 6000, rowsAbove: 300, rowsBelow: 400, aboveRows: 300
        ).feed == .intakeOlder(100))
        // The apron bounds it: ten rows are all there is.
        #expect(windowDecision(
            top: 0, rowsAbove: 0, rowsBelow: 400, aboveRows: 10
        ).feed == .intakeOlder(10))
    }

    /// **Twelve screens is where eviction starts, and it goes all the way to
    /// retain in one rows change** (the capacity model's mirror).
    @Test func testTheWindowReleasesToRetainInOneStep() {
        // 18000 pt is 8400 over the twelve-screen retain: 420 rows, one step.
        #expect(windowDecision(
            top: 18000, rowsAbove: 900, rowsBelow: 600
        ).evict == .releaseOlder(420))
        // Inside the band (ten to twelve screens either side) nothing moves.
        let calm = windowDecision(top: 8000, rowsAbove: 200, rowsBelow: 240)
        #expect(calm.feed == .none)
        #expect(calm.evict == .none)
    }

    /// **The eviction is measured by the document's own rows, not by the few
    /// the list has laid out** (the 2026-11-07 real-machine red).
    ///
    /// The log that red came from: `rows=1 drawnBelow=20568` released as
    /// `moved=191 want=191`, and the next tick fed the same 191 back --
    /// every 5 ms. 191 rows of 108 pt is 20568 pt, so the release was
    /// arithmetic on a 46 pt ruler: the median of the one row the view had
    /// measured, standing in for 191 rows it had never laid out. Ten and a
    /// half screens is 84 rows of 108 pt, and the document's own average
    /// says so whatever the median says.
    @Test func testAReleaseIsMeasuredByTheDocumentsOwnRows() {
        let viewport = 968.0                       // the real pane's height
        let height = 108.0
        let rowsBelow = 191
        let rowsAbove = 11
        let drawnBelow = Double(rowsAbove + 1 + rowsBelow) * height
            - 300 - viewport                      // 20656 pt
        let margin = W.marginScreens * viewport    // 9680

        let decision = windowDecision(
            top: 300, height: height, viewport: viewport,
            rowsAbove: rowsAbove, rowsBelow: rowsBelow,
            rowHeight: 46                          // the median the view offers
        )
        guard case let .releaseNewer(n) = decision.evict else {
            Issue.record("expected a newer release, got \(decision.evict)")
            return
        }
        // **Not the whole document**: taking all 191 was the red.
        #expect(n < rowsBelow)
        // 10.5 screens over retain, in 108 pt rows.
        #expect(n == 84)
        // **The invariant**: a release leaves its side at least the margin.
        let left = drawnBelow - Double(n) * height
        #expect(left >= margin)
        // The next tick has nothing to take back: no release, no intake.
        // **The viewport top does not move when rows go from below it** --
        // the release took them off the document's end -- so the next
        // reading has the same top and a document `n` rows shorter.
        let next = windowDecision(
            top: 300, height: height, viewport: viewport,
            rowsAbove: rowsAbove, rowsBelow: rowsBelow - n, rowHeight: 46
        )
        #expect(next.evict == .none)
        #expect(next.feed == .none)
        // **The apron does not enter the eviction at all**: a 5000-row
        // buffer behind the drawn side leaves the answer unchanged.
        let buffered = windowDecision(
            top: 300, height: height, viewport: viewport,
            rowsAbove: rowsAbove, rowsBelow: rowsBelow,
            aboveRows: 5000, belowRows: 5000, rowHeight: 46
        )
        #expect(buffered.evict == decision.evict)
        // **And the intake is measured by the same ruler**: ten screens of
        // 108 pt rows is 89 rows, not the 209 a 46 pt median asks for.
        #expect(windowDecision(
            top: 300, height: height, viewport: viewport,
            rowsAbove: rowsAbove, rowsBelow: rowsBelow,
            aboveRows: 500, rowHeight: 46
        ).feed == .intakeOlder(87))
    }

    /// **What an insertion above the reader owes the viewport** (the
    /// 2026-11-07 red, the third one): 99 rows went in, the offset moved six
    /// points, and the page slid a hundred rows under the reader, tick after
    /// tick. The debt is the inserted rows' own height, taken from the
    /// document's ruler -- **never a projection to the camera's row**, which
    /// after an insertion is a dozen screens below the viewport and is never
    /// laid out, so its frame never comes and the projection waits for ever.
    @Test func testAnInsertionIsPaidByTheRowsItPutIn() {
        let height = 108.0
        let rows = 99
        let reader = 39.0
        let target = W.compensatedTop(offset: reader, rows: rows, rowHeight: height)
        // The viewport goes down by exactly what went in above it.
        #expect(target - reader == Double(rows) * height)
        // **The criterion**: one compensation moves the viewport by at
        // least four fifths of what went in above it.
        #expect(target - reader >= 0.8 * Double(rows) * height)
        // The same ruler the window's decisions use, so the debt and the
        // window cannot disagree about how tall a row is: the document
        // average, not the 46 pt median of the one row near the viewport.
        let ruler = W.averageRowHeight(
            .init(top: 300, viewport: 968, content: 203 * 108, loadedTop: 0,
                  rowHeight: 46),
            rows: 203
        )
        #expect(ruler == 108)
        #expect(W.compensatedTop(offset: reader, rows: rows, rowHeight: ruler) == target)
        // Nothing went in, nothing is owed.
        #expect(W.insertedPoints(rows: 0, rowHeight: 200) == 0)
    }

    /// **A debt is paid once, in two instalments at most** (the 2026-11-07
    /// red, the flash): the first is scrolled in the turn the rows change --
    /// before the frame that draws them -- and the second is the exact
    /// remainder when layout says what the rows really took. **Paying the
    /// amount twice is a jump of its own**, which is why the remainder is
    /// the amount minus what was already paid and not the amount.
    @Test func testADebtIsPaidOnceInTwoInstalments() {
        let amount = 77.0
        // Nothing paid yet: the whole amount.
        #expect(W.compensationRemainder(amount: amount, paid: 0) == amount)
        // The estimate paid at once and it was right: nothing left.
        #expect(W.compensationRemainder(amount: amount, paid: amount) == 0)
        // The estimate was 20 pt low: the remainder is the 20, not the 77.
        #expect(W.compensationRemainder(amount: amount, paid: 57) == 20)
        // ... and 20 pt high: the remainder is negative, so it scrolls back.
        #expect(W.compensationRemainder(amount: amount, paid: 97) == -20)
    }

    /// **The debt is paid with the document's growth, never with the batch
    /// estimate** (the 2026-11-07 red, the small jump): one 72 pt row went
    /// in where the document averaged 92, so an estimate-paid compensation
    /// over-scrolls by 20 pt -- and 20 pt is enough to put the viewport's top
    /// edge into the next row. Eighteen of those a second is "a small jump
    /// every so often".
    @Test func testTheCompensationIsTheDocumentsGrowthNotTheEstimate() {
        let grown = 72.0
        let estimate = W.insertedPoints(rows: 1, rowHeight: 92)
        #expect(estimate == 92)      // the two really do differ
        #expect(W.compensationAmount(grown: grown, estimate: estimate) == grown)
        // Before the layout has the rows there is no growth; nothing is paid
        // until the fallback's deadline, and the fallback is what it is.
        #expect(W.compensationAmount(grown: 0, estimate: estimate) == estimate)
    }

    /// **A compensated viewport is on the same row it was on**, and the
    /// amount is what decides it: 72 pt of growth keeps the top edge inside
    /// p:975, the 92 pt estimate puts it into p:976 -- the row the jump is
    /// measured in.
    @Test func testACompensatedViewportIsOnTheSameRow() {
        let order = ["p:974", "p:975", "p:976"]
        let frames: [String: CGRect] = [
            "p:974": CGRect(x: 0, y: 9534, width: 300, height: 72),
            "p:975": CGRect(x: 0, y: 9606, width: 300, height: 72),
            "p:976": CGRect(x: 0, y: 9678, width: 300, height: 72),
        ]
        let reader = 9670.0
        #expect(C.place(order: order, frames: frames, at: reader)?.id == "p:975")
        // One 72 pt row went in above every row in the document.
        let grown = 72.0
        let after = frames.mapValues { $0.offsetBy(dx: 0, dy: CGFloat(grown)) }
        let paid = reader + W.compensationAmount(
            grown: grown, estimate: W.insertedPoints(rows: 1, rowHeight: 92)
        )
        #expect(C.place(order: order, frames: after, at: paid)?.id == "p:975")
        // **The estimate would land one row on** -- 20 pt of over-scroll.
        let estimated = reader + W.insertedPoints(rows: 1, rowHeight: 92)
        #expect(C.place(order: order, frames: after, at: estimated)?.id == "p:976")
    }

    /// **A release may not take a side under the margin** (the 2026-11-06
    /// oscillation): landing under it is how one tick's release became the
    /// next tick's intake. And the dead band between the margin and twelve
    /// screens does nothing at all.
    @Test func testAReleaseNeverLandsUnderTheMargin() {
        let viewport = 800.0
        let height = 20.0
        let margin = W.marginScreens * viewport
        let retain = W.retainScreens * viewport
        // Every position inside the band is a no-op. The document is sized
        // so the other side sits at the margin too: otherwise a release on
        // the far side would be the one action, and this test would pass for
        // the wrong reason.
        for side in stride(from: margin, through: retain, by: 50) {
            let rows = Int(((side + viewport + margin) / height).rounded())
            let decision = windowDecision(
                top: side, rowsAbove: rows, rowsBelow: 0
            )
            #expect(decision.feed == .none)
            #expect(decision.evict == .none)
        }
        // Over the retain, a release stops at retain, and the decision taken
        // from that position is a no-op -- no oscillation possible.
        for over in stride(from: Int(retain) + 20,
                           through: Int(retain + 3 * viewport), by: 400) {
            let top = Double(over)
            let rows = over / Int(height)
            let decision = windowDecision(top: top, rowsAbove: rows, rowsBelow: 0)
            guard case let .releaseOlder(n) = decision.evict else {
                Issue.record("expected a release at \(over)")
                continue
            }
            let after = top - Double(n) * height
            #expect(after >= margin - 0.001)
            let next = windowDecision(
                top: after, rowsAbove: rows - n, rowsBelow: 0
            )
            // **A release is never followed by an intake on that side**;
            // a release on the other side (the fixture's newer margin grew
            // as the older side shrank) is fine.
            if case .intakeOlder = next.feed {
                Issue.record("a release at \(over) was followed by an intake at \(after)")
            }
        }

        // **A row taller than the dead band cannot be released at all**:
        // taking one out would put the side under the margin, and the next
        // tick would take it back in. No action is the right answer.
        #expect(windowDecision(
            top: retain + 1, height: 2000, rowsAbove: 4, rowsBelow: 0
        ).evict == .none)
        // **The mirror side, and it needs its own case**: below the viewport
        // the same 2000 pt row sits just over retain, and one of it would
        // take the newer side from 9601 to 7601 -- under the margin.
        let tallBelow = W.decide(
            W.Reading(top: 0, viewport: 800, content: 10401, loadedTop: 0,
                      rowHeight: 2080.2),
            aboveRows: 0, belowRows: 0,
            documentAbove: 0, documentBelow: 4,
            hasEarlier: false, hasNewer: false
        )
        #expect(tallBelow.evict == .none)
    }

    /// **One action per tick** (the 2026-11-06 oscillation): a document
    /// short on both sides -- and with both aprons holding rows -- yields
    /// exactly one move, not a feed and a release in the same breath.
    @Test func testTheWindowTakesOneActionAtATime() {
        let both = windowDecision(
            top: 100, rowsAbove: 5, rowsBelow: 5,
            aboveRows: 40, belowRows: 40, hasNewer: true
        )
        #expect(both.feed == .intakeOlder(40))
        #expect(!both.contradictory)
        // A tiny document whose older side is satisfied but whose newer side
        // is short takes the newer intake, still one action.
        let newerOnly = windowDecision(
            top: 8000, rowsAbove: 600, rowsBelow: 39,
            belowRows: 40, hasEarlier: false, hasNewer: true
        )
        #expect(newerOnly.feed == .intakeNewer(40))
        // Above short while below is over: still one action, and **the
        // release goes first** -- feeding first would starve it while the
        // reader scrolls continuously, and the document would grow at the
        // far end without bound.
        let mixed = windowDecision(
            top: 100, rowsAbove: 5, rowsBelow: 594, aboveRows: 40
        )
        #expect(mixed.evict == .releaseNewer(75))
    }

    /// **The request goes out at the first shortfall, and carries the
    /// shortfall with a floor** (the capacity model): not when the apron is
    /// empty, and not a fixed page.
    @Test func testTheRequestIsTheMissingBuffer() {
        // A shortfall of 14 rows in a group of 300 pt messages: one round
        // trip still asks for the floor.
        #expect(windowDecision(
            top: 3900, height: 300, rowsAbove: 13, rowsBelow: 13
        ).requestOlderRows == W.requestFloor)
        // A big shortfall asks for more than the floor.
        #expect(windowDecision(
            top: 0, rowsAbove: 0, rowsBelow: 40
        ).requestOlderRows == 200)
        // **Any shortfall asks** (2026-11-07): 6000 of 8000 pt is short, and
        // the refill does not wait for the half-way mark or the edge.
        #expect(windowDecision(
            top: 6000, rowsAbove: 300, rowsBelow: 300
        ).requestOlderRows == 100)
        // **The apron is part of the loaded side**: 100 drawn + 300 x 20 =
        // 6100, short of the margin, so it asks for the rest.
        #expect(windowDecision(
            top: 100, rowsAbove: 5, rowsBelow: 200, aboveRows: 300
        ).requestOlderRows == 95)
        // A full buffer asks for nothing...
        #expect(windowDecision(
            top: 100, rowsAbove: 5, rowsBelow: 200, aboveRows: 500
        ).requestOlderRows == 0)
        // ... and a core with nothing older is not asked at all.
        #expect(windowDecision(
            top: 100, rowsAbove: 5, rowsBelow: 200, hasEarlier: false
        ).requestOlderRows == 0)
    }

    /// **The first screen is twelve screens of the measured rows**, aligned
    /// with the ten-screen margin, and the conservative default before the
    /// pane has measured itself (review C, M5's unmeasured case).
    @Test func testTheFirstScreenIsTwelveScreens() {
        #expect(W.firstScreenRows(viewportRows: 16) == 192)
        #expect(W.firstScreenRows(viewportRows: 30) == 200)   // the core's cap
        #expect(W.firstScreenRows(viewportRows: 1) == 12)
        // The core's ceiling still holds.
        #expect(W.firstScreenRows(viewportRows: 100) == W.maxRequestRows)
    }

    /// **Criterion 1 and 3 together** (as amended by the 2026-11-07 red):
    /// fifty screens up, in wheel-sized callbacks, and **no single rows
    /// change takes in more than one screen**, the list never reaches the
    /// loaded edge, and the document does not grow with the scroll.
    ///
    /// The world is a fixture (rows with heights, an apron either side); the
    /// decisions are the production ones. Every callback scrolls 50 pt, so
    /// the reader is modelled the way a trackpad delivers them, not as one
    /// screen per event -- a screen is eighteen rows.
    @Test func testFiftyScreensUpTakesInAStepAtATime() {
        let viewport = 800.0
        let height = 44.0
        let rowsPerScreen = Int(viewport / height)          // 18
        let total = 2000
        let firstScreen = Int(
            W.firstScreenScreens * Double(rowsPerScreen)    // 108
        )
        var docStart = total - firstScreen
        var docEnd = total
        var aboveCount = 0
        var unloaded = docStart
        var belowCount = 0
        var top = Double(docEnd - docStart) * height - viewport
        var maxInsert = 0
        var topHits = 0
        var docCounts: [Int] = []

        for tick in 0..<Int(50 * viewport / 50) {           // 50 screens
            top = max(0, top - 50)
            if top <= 1, aboveCount + unloaded > 0 {
                topHits += 1
            }
            let decision = W.decide(
                .init(
                    top: top, viewport: viewport,
                    content: Double(docEnd - docStart) * height,
                    loadedTop: 0, rowHeight: height
                ),
                aboveRows: aboveCount, belowRows: belowCount,
                documentAbove: Int(top / height),
                documentBelow: max(0, docEnd - docStart - 1 - Int(top / height)),
                hasEarlier: aboveCount + unloaded > 0,
                hasNewer: false
            )
            // **The apron the decision saw**, before this tick's request
            // lands: the move is bounded by it, not by the refill.
            let apronAtDecision = aboveCount
            // The core answers within the same tick in this model.
            if decision.requestOlderRows > 0, unloaded > 0 {
                let land = min(decision.requestOlderRows, unloaded)
                unloaded -= land
                aboveCount += land
            }
            // **One feed and one eviction, exactly as the view applies
            // them.**
            switch decision.feed {
            case let .intakeOlder(n):
                let take = min(n, aboveCount)
                // **The move is the drawn shortfall, not a trickle** (the
                // 2026-11-07 `moved=1` red): at least 80% of what the
                // shortfall asks for (bounded by the apron).
                let shortfallRows = max(
                    0, Int(((W.marginScreens * viewport - top) / height).rounded(.up))
                )
                if Double(take) < 0.8 * Double(min(shortfallRows, apronAtDecision)) {
                    Issue.record(
                        "took \(take) of \(min(shortfallRows, apronAtDecision)) n=\(n) top=\(top) apron=\(apronAtDecision)"
                    )
                }
                if take > 0 {
                    maxInsert = max(maxInsert, take)
                    docStart -= take
                    aboveCount -= take
                    top += Double(take) * height           // the compensation
                }
            case let .intakeNewer(n):
                let take = min(n, belowCount)
                let belowNow = max(
                    0, Double(docEnd - docStart) * height - (top + viewport)
                )
                let shortfallRows = max(
                    0, Int(((W.marginScreens * viewport - belowNow) / height).rounded(.up))
                )
                #expect(Double(take) >= 0.8 * Double(min(shortfallRows, belowCount)),
                        "took \(take) of \(min(shortfallRows, belowCount))")
                if take > 0 {
                    docEnd += take
                    belowCount -= take
                }
            case .releaseOlder, .releaseNewer, .none:
                break
            }
            switch decision.evict {
            case let .releaseOlder(n):
                let take = min(n, docEnd - docStart - 1)
                if take > 0 {
                    docStart += take
                    aboveCount += take
                }
            case let .releaseNewer(n):
                let take = min(n, docEnd - docStart - 1)
                if take > 0 {
                    docEnd -= take
                    belowCount += take
                }
            case .intakeOlder, .intakeNewer, .none:
                break
            }
            docCounts.append(docEnd - docStart)
            if docCounts.count == 1 || (docCounts.max() ?? 0) == docEnd - docStart {
            }
        }

        // **No ceiling on the step** (the capacity model): it is the drawn
        // margin's shortfall, so it is bounded by what the reader spent
        // while the apron was empty, not by a row count. What must hold is
        // that the margin is restored and the edge is never reached.
        #expect(maxInsert > 0)                  // the fixture did exercise it
        #expect(topHits == 0)
        // Criterion 3: the document is a window, not a growing history --
        // five screens above, six below, and a little slack for the step.
        let bound = Int((W.marginScreens + W.retainScreens + 2) * Double(rowsPerScreen))
        if let mi = docCounts.firstIndex(of: docCounts.max() ?? 0) {
        }
        #expect((docCounts.max() ?? 0) <= bound,
                "max=\(docCounts.max() ?? 0) bound=\(bound) screens=\(rowsPerScreen)")
        #expect((docCounts.last ?? 0) <= bound)
    }

    /// **Criterion 4**: an insertion is compensated by the camera row's own
    /// y under the new frames (review C, M2) -- the projection target moves
    /// by exactly the inserted height, so the row stays on the same screen
    /// point.
    @Test func testAnInsertIsCompensatedByTheCameraRowsOwnY() {
        let place = C.Place(id: "m", offset: 7)
        let state = C.State(place: place, pinned: false)
        let before: [String: CGRect] = ["m": CGRect(x: 0, y: 100, width: 300, height: 40)]
        let after: [String: CGRect] = ["m": CGRect(x: 0, y: 320, width: 300, height: 40)]
        let oldY = C.projection(
            state: state, order: ["m"], frames: before,
            content: 500, viewport: 200, centre: 100
        )
        let newY = C.projection(
            state: state, order: ["m"], frames: after,
            content: 720, viewport: 200, centre: 320
        )
        #expect(oldY == .scroll(107))
        #expect(newY == .scroll(327))
        // The five rows inserted above are 220 pt: the compensation is that
        // distance and nothing else, so the row's screen y is unchanged.
        #expect(327 - 107 == 220)
    }

    /// **A width change does not project from the old frames** (new, R1-12):
    /// while the map is empty the projection waits; only frames newer than
    /// the wait may answer it.
    @Test func testAWidthChangeDoesNotProjectFromTheOldFrames() {
        let state = C.State(place: .init(id: "b", offset: 5), pinned: false)
        #expect(C.projection(
            state: state, order: ["a", "b", "c"], frames: frames,
            content: 100, viewport: 40, centre: 20
        ) == .scroll(25))
        // **Waiting, not seeking** (MF1): the row is on screen and about to
        // be measured; a seek would scroll to one place and then another.
        #expect(C.projection(
            state: state, order: ["a", "b", "c"], frames: [:],
            content: 100, viewport: 40, centre: 20
        ) == .wait("b"))
        #expect(!C.mayAnswer(framesEpoch: 9, waitingSince: 9))
        #expect(C.mayAnswer(framesEpoch: 10, waitingSince: 9))
    }

    /// **Two programmatic scrolls in one turn are both recognised** (MF2).
    /// The old single slot was cleared by the first callback whether it
    /// matched or not, so the second landed in the reader's branch and turned
    /// `pinned` off.
    @Test func testTwoProgrammaticScrollsInOneTurnAreBothRecognised() {
        var expectations: [C.ScrollExpectation] = [
            .init(y: 100, epoch: 3), .init(y: 200, epoch: 3),
        ]
        #expect(C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 100, epoch: 3,
            expectations: &expectations))
        #expect(C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 200, epoch: 3,
            expectations: &expectations))
        #expect(expectations.isEmpty)

        // **A callback that matches nothing is not the view's** -- and does
        // not spend the expectations that are still owed.
        var owed: [C.ScrollExpectation] = [.init(y: 400, epoch: 3)]
        #expect(!C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 250, epoch: 3,
            expectations: &owed))
        #expect(owed.count == 1)
        #expect(C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 400.4, epoch: 3,
            expectations: &owed))
        #expect(owed.isEmpty)
    }

    /// **The window's reading is the viewport's real top** (the 2026-11-06
    /// red): the clip origin, or the document's end while pinned -- **never
    /// the camera's projection**. Reading the projection back was the closed
    /// loop that walked a reader towards the oldest while they scrolled
    /// towards the newest.
    @Test func testTheWindowReadsTheActualOffsetNotTheCamera() {
        #expect(W.viewportTop(
            pinned: false, content: 5000, viewport: 800, offset: 1234) == 1234)
        // A camera sitting at 400 is not this number.
        #expect(W.viewportTop(
            pinned: false, content: 5000, viewport: 800, offset: 1234) != 400)
        // Pinned: the document's end, which is also where the offset has
        // to be.
        #expect(W.viewportTop(
            pinned: true, content: 5000, viewport: 800, offset: 999) == 4200)
    }

    /// **A reader's scroll is still the reader's after twenty
    /// compensations** (the 2026-11-06 red). Five rows a step raised the
    /// number of targets the view leaves behind; the epoch has to keep a
    /// stale one from being matched, and the reader's own wheel has to
    /// outrank even a fresh match.
    @Test func testAUserScrollAfterTwentyCompensationsIsStillTheReaders() {
        var expectations: [C.ScrollExpectation] = []
        var epoch: UInt64 = 1
        for step in 0..<20 {
            // The rows changed, the frames that answer them arrived, and
            // the compensation registered exactly one target.
            epoch &+= 1
            expectations = [.init(y: Double(step) * 100, epoch: epoch)]
            #expect(C.programmaticCallback(
                inScrollCall: false, seekInFlight: false,
                y: Double(step) * 100, epoch: epoch,
                expectations: &expectations))
            #expect(expectations.isEmpty)
            // The reader's own wheel, a map later.
            epoch &+= 1
            let matched = C.programmaticCallback(
                inScrollCall: false, seekInFlight: false, y: 777,
                epoch: epoch, expectations: &expectations)
            #expect(!matched)
            #expect(A.cause(
                contentChanged: false, framesChanged: false,
                phaseIsLayout: true, programmatic: matched,
                userScrolling: false, readerRecently: true) == .user)
        }

        // **A stale target the reader lands on is the reader's**, even when
        // the raw matcher thinks it is the view's: the wheel explains the
        // callback, and the camera is written.
        var stale: [C.ScrollExpectation] = [.init(y: 400, epoch: 3)]
        let matchedStale = C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 400, epoch: 3,
            expectations: &stale)
        #expect(matchedStale)
        #expect(A.cause(
            contentChanged: false, framesChanged: false,
            phaseIsLayout: false, programmatic: matchedStale,
            userScrolling: false, readerRecently: true) == .user)
    }

    /// **A target from an older map is not an answer** (review C, M3). With
    /// five rows going in every few screens, the place the last compensation
    /// left is exactly where the reader's next scroll arrives; matching it
    /// would read the reader as the view and swallow their movement.
    @Test func testATargetFromAnOlderMapIsNotMatched() {
        var expectations: [C.ScrollExpectation] = [.init(y: 400, epoch: 3)]
        // The frames have moved on: the old target means nothing.
        #expect(!C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 400, epoch: 4,
            expectations: &expectations))
        #expect(expectations.isEmpty)
    }

    /// **The lower edge asks for a newer page only on the reader's input**
    /// (M4): a pinned viewport's programmatic callback is always at distance
    /// zero, and asking there walked the whole remaining history.
    @Test func testANewerPageIsAskedForOnlyOnTheReadersInput() {
        #expect(C.newerIsDue(wants: true, fromInput: true))
        #expect(!C.newerIsDue(wants: true, fromInput: false))
        #expect(!C.newerIsDue(wants: false, fromInput: true))
        #expect(!C.newerIsDue(wants: false, fromInput: false))
    }

    /// **A settle means the locate is finished, not that the row is here**
    /// (M5): a target outside its own window must be recorded too, or every
    /// rows change asks for the same `around` again.
    @Test func testALocateIsSettledEvenWhenItsTargetIsNotInTheWindow() {
        #expect(C.locateSettled(targetInRows: true, hasContext: false, trouble: false))
        #expect(C.locateSettled(targetInRows: false, hasContext: true, trouble: false))
        #expect(C.locateSettled(targetInRows: false, hasContext: false, trouble: true))
        // Still on its way: no window and no word from the feed.
        #expect(!C.locateSettled(targetInRows: false, hasContext: false, trouble: false))
    }

    /// **A momentum event counts wherever the pointer is** (M6). A fling is
    /// window-wide; dropping it once the cursor left the list opened the
    /// projection gate while the list was still decelerating.
    @Test func testAMomentumWheelCountsOutsideTheListAndItsEndEndsTheHand() {
        #expect(ControlRoomChatScrollHandle.wheelCounts(
            momentum: true, pointerInside: false))
        #expect(ControlRoomChatScrollHandle.wheelCounts(
            momentum: false, pointerInside: true))
        #expect(!ControlRoomChatScrollHandle.wheelCounts(
            momentum: false, pointerInside: false))

        let handle = ControlRoomChatScrollHandle()
        #expect(handle.noteWheel(now: 10))
        #expect(handle.readerMovedRecently(now: 10.1))
        // The explicit end needs no window: the hand is off now.
        handle.endMomentum(now: 10.1)
        #expect(!handle.readerMovedRecently(now: 10.1))
    }

    // MARK: - The probe's attach

    @Test func testOnlyTheLatestMoveAttachesAndOnlyOnce() {
        var ledger = A.AttachLedger()
        let first = ledger.moved(inWindow: true)
        let second = ledger.moved(inWindow: true)
        #expect(!ledger.mayAttach(generation: first, inWindow: true, clip: "clip"))
        #expect(ledger.mayAttach(generation: second, inWindow: true, clip: "clip"))
        let adopted = ledger.attached("clip", generation: second)
        #expect(adopted)
        // Already listening to this clip: a second attach would be a second
        // observer.
        #expect(!ledger.mayAttach(generation: second, inWindow: true, clip: "clip"))

        ledger.detach()
        #expect(ledger.mayAttach(generation: second, inWindow: true, clip: "clip"))

        let leftWindow = ledger.moved(inWindow: false)
        #expect(!ledger.mayAttach(generation: leftWindow, inWindow: false, clip: "clip"))
    }

    /// **A measured Markdown row's bounds is layout, not the reader**, even
    /// when no rows or width changed and the frames preference has not
    /// arrived; a live-scroll event is what makes it the reader.
    @Test func testAMeasuredRowIsLayoutAndLiveScrollIsTheReader() {
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: false, userScrolling: false
        ) == .layout)
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: false, userScrolling: true
        ) == .user)
        #expect(A.cause(
            contentChanged: false, framesChanged: false,
            phaseIsLayout: false, programmatic: false, userScrolling: false
        ) == .user)
        // A layout transaction that is being waited on does **not** beat a
        // real live scroll: the person's drag takes over.
        #expect(A.cause(
            contentChanged: false, framesChanged: false,
            phaseIsLayout: true, programmatic: false, userScrolling: true
        ) == .user)
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: true, userScrolling: false
        ) == .programmatic)
    }

    /// **A wheel is the reader even when no live scroll started** (task 2999
    /// ③). A wheel's bounds arriving together with a lazily measured row's
    /// growth were classified layout, and the view put the list back at the
    /// bottom under the reader's hand: "it only scrolls down".
    @Test func testAWheelWinsOverALayoutInferenceWithoutALiveScroll() {
        // The regression itself: content grew in the same callback as the
        // wheel's own movement.
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: false,
            userScrolling: false, readerRecently: true
        ) == .user)
        // Frames too, and a layout transaction being waited on.
        #expect(A.cause(
            contentChanged: true, framesChanged: true,
            phaseIsLayout: true, programmatic: false,
            userScrolling: false, readerRecently: true
        ) == .user)
        // **A wheel outranks even one of our own target matches now** (the
        // 2026-11-06 red): a compensation landing under the reader's hand
        // re-reads the place the camera already names, so treating it as
        // theirs costs nothing -- while the old rule swallowed a reader's
        // scroll that happened to reach a target left behind, froze the
        // camera, and walked them to the oldest.
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: true,
            userScrolling: false, readerRecently: true
        ) == .user)
        // Without the reader's signal, a match is still ours.
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: true,
            userScrolling: false, readerRecently: false
        ) == .programmatic)
        // Without the signal the same facts are still layout -- the defect
        // this parameter exists for, held here so it cannot come back.
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: false,
            userScrolling: false, readerRecently: false
        ) == .layout)
    }

    /// The wheel signal itself: it is "recent" only inside its window, and a
    /// burst says `began` once -- the view voids what it owed on the first
    /// event, not on every one.
    @Test func testTheWheelSignalLastsOnlyItsWindow() {
        let handle = ControlRoomChatScrollHandle()
        #expect(!handle.readerMovedRecently(now: 10))
        #expect(handle.noteWheel(now: 10))
        #expect(handle.readerMovedRecently(now: 10.2))
        #expect(!handle.noteWheel(now: 10.2))
        #expect(!handle.readerMovedRecently(now: 11))
        #expect(handle.noteWheel(now: 11))
        handle.forgetWheel()
        #expect(!handle.readerMovedRecently(now: 11))
    }

    /// **The located mark waits until its row is measured and under the
    /// viewport** (task 2999 ④). The locate's own arrival is before the
    /// around window, so it is not the moment; neither is a row measured
    /// off screen.
    @Test func testTheMarkWaitsUntilTheLocatedRowIsOnScreen() {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 300, height: 40),
            "b": CGRect(x: 0, y: 40, width: 300, height: 40),
            "c": CGRect(x: 0, y: 80, width: 300, height: 40),
        ]
        // A viewport from 50 to 70 has only b (40..80) under it.
        #expect(A.locatedIsInView(located: "b", frames: frames, offset: 50, viewport: 20))
        #expect(!A.locatedIsInView(located: "a", frames: frames, offset: 50, viewport: 20))
        #expect(!A.locatedIsInView(located: "c", frames: frames, offset: 50, viewport: 20))
        // A row that starts exactly at the viewport's bottom edge is not on
        // screen, and one that has not been measured at all is not either.
        #expect(!A.locatedIsInView(located: "c", frames: frames, offset: 60, viewport: 20))
        #expect(A.locatedIsInView(located: "b", frames: frames, offset: 60, viewport: 20))
        #expect(!A.locatedIsInView(located: "z", frames: frames, offset: 50, viewport: 20))
        // No viewport has nothing on it.
        #expect(!A.locatedIsInView(located: "b", frames: frames, offset: 0, viewport: 0))
    }

    @Test func testTheRowListChangeTellsPrependFromAppend() {
        #expect(A.change(from: [], to: ["a"]) == .appended)
        #expect(A.change(from: ["b", "c"], to: ["a", "b", "c"]) == .prepended)
        #expect(A.change(from: ["a", "b"], to: ["a", "b", "c"]) == .appended)
        #expect(A.change(from: ["a", "b"], to: ["a", "b"]) == .none)
        // **A slide is still the same map** (review C, M4): the window
        // dropped its front and grew at the back, and the rows the reader is
        // among are untouched.
        #expect(A.change(from: ["a", "b", "c"], to: ["b", "c", "d"]) == .moved)
        #expect(A.change(from: ["a", "b", "c"], to: ["b", "c"]) == .moved)
        #expect(A.change(from: ["a", "b", "c"], to: ["a", "b"]) == .moved)
        // **A row that left the middle** is not a window move: the surviving
        // ids no longer form the run they bounded.
        #expect(A.change(from: ["a", "b", "c"], to: ["a", "c"]) == .replaced)
        // **Another map**: nothing contiguous survives.
        #expect(A.change(from: ["a", "b"], to: ["x", "y"]) == .replaced)
        #expect(A.change(from: ["a", "b", "c"], to: []) == .replaced)
    }

    /// **The end marks are in the plan, not in the feed's rows** (review C,
    /// M7): they are the conversation's real ends, they draw no control, and
    /// the list does not draw them twice.
    @Test func testTheEndsAreMarksInThePlan() {
        let order = ["p:1", "p:2"]
        #expect(P.listRows(order: order, trimmedBefore: nil, trimmedAfter: nil,
                           atStart: true, atEnd: false) == [
            .start, .message(id: "p:1"), .message(id: "p:2"),
        ])
        #expect(P.listRows(order: order, trimmedBefore: nil, trimmedAfter: nil,
                           atStart: false, atEnd: true) == [
            .message(id: "p:1"), .message(id: "p:2"), .end,
        ])
        // A real released run wins the top: the beginning is not both a
        // mark and a gap.
        #expect(P.listRows(order: order, trimmedBefore: "p:1", trimmedAfter: nil,
                           atStart: true, atEnd: false).first == .start)
        // No rows, no mark.
        #expect(P.listRows(order: [], trimmedBefore: nil, trimmedAfter: nil,
                           atStart: true, atEnd: true).isEmpty)
        #expect(P.ListRow.start.id != P.ListRow.end.id)
        #expect(P.ListRow.start.id != P.ListRow.message(id: "p:1").id)
    }

    /// **A fallback lands near where the camera was** (the 2026-11-07
    /// back-jump red): with only the early and late stretches measured, a
    /// drifted pixel centre must not pull the reader to the early rows --
    /// the camera's own index decides.
    @Test func testTheFallbackLandsNearTheCamerasPlace() {
        var order: [String] = []
        var frames: [String: CGRect] = [:]
        for i in 0..<500 {
            let id = "r\(i)"
            order.append(id)
            frames[id] = CGRect(x: 0, y: CGFloat(i) * 40, width: 300, height: 40)
        }
        let measured = frames.filter { i, _ in
            (0..<60).contains(Int(i.dropFirst())!) || (380..<421).contains(Int(i.dropFirst())!)
        }
        // The pixel centre is early (a stale offset); the camera was at 400.
        let place = C.fallbackPlace(centre: 500, order: order, frames: measured, near: 400)
        let index = place.flatMap { order.firstIndex(of: $0.id) } ?? -1
        #expect(index >= 380)
    }

    /// **Thirty screens of scrolling, and the row at the viewport's top only
    /// moves one way** (the 2026-11-07 back-jump red): down the index never
    /// decreases, up it never increases, and the end of the run is not back
    /// at the beginning. This is the inverse the camera is written from.
    @Test func testTheTopRowIsMonotonicOverThirtyScreens() {
        let height = 40.0
        let viewport = 800.0
        var order: [String] = []
        var frames: [String: CGRect] = [:]
        for i in 0..<500 {
            let id = "r\(i)"
            order.append(id)
            frames[id] = CGRect(x: 0, y: CGFloat(i) * height, width: 300, height: height)
        }
        let step = 25.0
        let steps = Int(30 * viewport / step)   // thirty screens in 25 pt steps

        var last = -1
        for i in 0..<steps {
            let y = Double(i) * step
            guard let place = C.place(order: order, frames: frames, at: y) else {
                Issue.record("no place at y=\(y)")
                return
            }
            let index = order.firstIndex(of: place.id)!
            #expect(index >= last, "a back-jump down: \(index) after \(last) at y=\(y)")
            last = index
        }
        // The run really travelled, and it is not back at the first rows.
        #expect(last > 400)

        var previous = order.count
        for i in stride(from: steps - 1, through: 0, by: -1) {
            let y = Double(i) * step
            guard let place = C.place(order: order, frames: frames, at: y) else {
                Issue.record("no place at y=\(y) going up")
                return
            }
            let index = order.firstIndex(of: place.id)!
            #expect(index <= previous, "a back-jump up: \(index) after \(previous) at y=\(y)")
            previous = index
        }
        #expect(previous < 100)
    }

    // MARK: - The index bar (task 3002)

    /// **The high-water mark belongs to the group, not to the map** (review
    /// M, Q3). `.replaced` is also how a locate -- or a drag to a place that
    /// was not loaded -- swaps the whole map inside one group; only a
    /// different group may start the depth again.
    @Test func testAReplacedMapKeepsTheReachedDepthOnlyInTheSameGroup() {
        #expect(I.keepsReached(mapGroup: "polter", newGroup: "polter"))
        #expect(!I.keepsReached(mapGroup: "polter", newGroup: "second-group"))
        #expect(!I.keepsReached(mapGroup: nil, newGroup: "polter"))
        #expect(!I.keepsReached(mapGroup: "polter", newGroup: nil))
    }

    /// `count` rows of the same height, with the list's 10pt gap between
    /// them, in the content coordinates the frames preference reports.
    private func frameMap(_ heights: [CGFloat]) -> (order: [String], frames: [String: CGRect]) {
        var order: [String] = []
        var frames: [String: CGRect] = [:]
        var y: CGFloat = 0
        for (index, height) in heights.enumerated() {
            let id = "r\(index)"
            order.append(id)
            frames[id] = CGRect(x: 0, y: y, width: 300, height: height)
            y += height + 10
        }
        return (order, frames)
    }

    /// **The thumb is the viewport's share of the loaded map**, and it is
    /// never shorter than a hand can grab.
    @Test func testTheThumbIsTheShareOfTheDocumentTheViewportCovers() {
        let all: CGFloat = 300
        #expect(I.thumbHeightPoints(totalPoints: 1_000, viewportPoints: 1_000, trackH: all) == all)
        #expect(I.thumbHeightPoints(totalPoints: 2_000, viewportPoints: 1_000, trackH: all) == 150)
        #expect(I.thumbHeightPoints(totalPoints: 10_000, viewportPoints: 1_000, trackH: all) == 36)
        // A night's document: the ratio would be under a point, the floor
        // holds, and the thumb is still no taller than its track.
        #expect(I.thumbHeightPoints(totalPoints: 500_000, viewportPoints: 1_000, trackH: all) == 36)
        // A track shorter than the floor is the limit, not the floor.
        #expect(I.thumbHeightPoints(totalPoints: 500_000, viewportPoints: 1_000, trackH: 30) == 30)
        #expect(I.thumbHeightPoints(totalPoints: 2_000, viewportPoints: 1_000, trackH: 20) == 20)
        #expect(I.thumbHeightPoints(totalPoints: 0, viewportPoints: 0, trackH: all) == all)
    }

    /// **The thumb reaches the end of its travel exactly at the bottom**:
    /// that is what makes the bar's end read as the newest message and not as
    /// "somewhere near it".
    @Test func testTheThumbReachesTheEndOnlyAtTheBottomInPointSpace() {
        // 500 points of document, a 10 point viewport: the deepest point
        // reached is the document's top, `depth == total`.
        let top = I.geometryPoints(
            totalPoints: 500, viewportPoints: 10, depthPoints: 500, trackH: 300)
        #expect(top.thumbY == 0)
        #expect(top.thumbH == 36)
        let bottom = I.geometryPoints(
            totalPoints: 500, viewportPoints: 10, depthPoints: 10, trackH: 300)
        let travel: CGFloat = 300 - 36
        #expect(bottom.thumbY == travel)
        let middle = I.geometryPoints(
            totalPoints: 500, viewportPoints: 10, depthPoints: 255, trackH: 300)
        #expect(middle.thumbY == travel / 2)
        // Past the end is still the end: an estimate that overshoots must not
        // draw the thumb outside the track.
        let past = I.geometryPoints(
            totalPoints: 500, viewportPoints: 10, depthPoints: -900, trackH: 300)
        #expect(past.thumbY == travel)
    }

    /// **A drag lands on a row of the loaded map**, from the first to the
    /// last, and never past either end.
    @Test func testADragLandsOnADepthAndNeverPastTheEnds() {
        // 101 points of document, a 1 point viewport: the travel spans
        // 1...101 in depth, and the ends are the two ends.
        let total = 101.0
        let viewport = 1.0
        #expect(I.seekDepth(fraction: 0, totalPoints: total, viewportPoints: viewport, step: 1) == total)
        #expect(I.seekDepth(fraction: 1, totalPoints: total, viewportPoints: viewport, step: 1) == viewport)
        #expect(I.seekDepth(fraction: 0.5, totalPoints: total, viewportPoints: viewport, step: 1) == 51)
        #expect(I.seekDepth(fraction: -1, totalPoints: total, viewportPoints: viewport, step: 1) == total)
        #expect(I.seekDepth(fraction: 2, totalPoints: total, viewportPoints: viewport, step: 1) == viewport)
        // One drawn cell is `step` points, so a drag lands on a cell edge.
        let snapped = I.seekDepth(
            fraction: 0.5, totalPoints: 100, viewportPoints: 1, step: 3)
        let expected = 51.0
        #expect(snapped == expected)
        #expect(I.seekDepth(fraction: 0, totalPoints: 0, viewportPoints: 0, step: 1) == 0)
    }

    /// **How many rows one drawn tick stands for**: one while they fit, more
    /// once they do not.
    @Test func testAStepIsHowManyPointsOneTickStandsFor() {
        // 300pt of track, one tick every 5pt: sixty fit.
        #expect(I.stepPoints(totalPoints: 60, trackH: 300) == 1)
        #expect(I.stepPoints(totalPoints: 61, trackH: 300) == 2)
        #expect(I.stepPoints(totalPoints: 120, trackH: 300) == 2)
        #expect(I.stepPoints(totalPoints: 601, trackH: 300) == 11)
        #expect(I.stepPoints(totalPoints: 0, trackH: 300) == 1)
        let fractions = I.tickFractionsPoints(totalPoints: 601, step: 11)
        #expect(fractions.count == 55)
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
    }

    /// A click on the bare track is a page; a click on the thumb is not.
    @Test func testAClickOnTheBareTrackIsAPage() {
        #expect(I.page(forY: 10, thumbY: 100, thumbH: 36) == -1)
        #expect(I.page(forY: 10, thumbY: 0, thumbH: 36) == 0)
        #expect(I.page(forY: 118, thumbY: 100, thumbH: 36) == 0)
        #expect(I.page(forY: 200, thumbY: 100, thumbH: 36) == 1)
    }

    /// **The camera's place is a continuous tick, not the index of a row**:
    /// half way into a row is half a tick. A scroll of one pixel must move
    /// the thumb by one pixel's worth, not by a whole row.
    @Test func testTheDepthIsPointsBelowTheDocumentsBottom() {
        // The document ends at 5_614; at the bottom the viewport's top is
        // one screen (968) below it, and at the oldest edge it is the whole
        // document below it.
        let bottom = I.topPoints(documentBottom: 5_614, offset: 5_614 - 968)
        let oldest = I.topPoints(documentBottom: 5_614, offset: 0)
        // Past the bottom is still the bottom, not a negative depth.
        let past = I.topPoints(documentBottom: 5_614, offset: 9_000)
        #expect(bottom == 968)
        #expect(oldest == 5_614)
        #expect(past == 0)
    }

    /// The viewport's coverage is counted over the frames it really overlaps,
    /// with a partly visible row counting by the part on screen.
    @Test func testTheViewportCoversOnlyWhatItSees() {
        let list = frameMap([40, 40, 40])
        let half = I.viewportTicks(
            order: list.order, frames: list.frames, offset: 60, viewport: 20)
        #expect(half == 0.5)
        let two = I.viewportTicks(
            order: list.order, frames: list.frames, offset: 0, viewport: 90)
        // r0 fully, r1 fully (50..90), and nothing of r2 (starts at 100).
        #expect(two == 2)
        #expect(I.viewportTicks(order: list.order, frames: list.frames, offset: 900, viewport: 20) == nil)
    }

    /// The bubble says when, and never invents a clock the row does not
    /// have. **A point is not a row** (design §23.3), so there is no `#n` any
    /// more -- the bar is in points and the caller hands in the nearest row's
    /// time.
    @Test func testTheBubbleNamesTheClockAndNothingElse() {
        #expect(I.bubbleText(time: "10:12:05") == "10:12:05")
        #expect(I.bubbleText(time: "") == "")
    }

    // The old spent-restore test and the old nearest-measured test moved to
    // the camera's state machine section above: `testAOwedProjectionIsNot
    // AnsweredByTheFramesItWasFrozenAgainst` and
    // `testAFallbackPicksTheNearestMeasuredRow`. Nothing here was dropped --
    // the assertion for each old one is still exactly once in the file.

    // MARK: - The bar in point space (design §23.3, step one)

    /// **The high-water mark only grows.** This is the user's whole rule:
    /// reaching 100 keeps 100, and coming back to the newest does not shrink
    /// it. It is a pure function so it can be read here instead of only
    /// living in a `@State`.
    @Test func testTheHighWaterOnlyGrows() {
        let first = 1_000.0
        let back = 40.0
        let deeper = 1_800.0
        var reached = I.reached(previous: 0, top: first)
        #expect(reached == first)
        reached = I.reached(previous: reached, top: back)
        #expect(reached == first)
        reached = I.reached(previous: reached, top: deeper)
        #expect(reached == deeper)
    }

    /// **The thumb sits at the ends it should**: the end of its travel at the
    /// newest edge, the start of it at the deepest point reached. `depth` is
    /// measured from the newest and the travel from the oldest, so this is
    /// where that inversion would show up if the conversion were wrong.
    @Test func testTheThumbSitsAtTheEndsItShouldInPointSpace() {
        let total = 5_614.0
        let viewport = 968.0
        let trackH: CGFloat = 300
        let newest = I.geometryPoints(
            totalPoints: total, viewportPoints: viewport,
            depthPoints: viewport, trackH: trackH)
        let deepest = I.geometryPoints(
            totalPoints: total, viewportPoints: viewport,
            depthPoints: total, trackH: trackH)
        let travel = trackH - newest.thumbH
        #expect(newest.thumbY == travel)
        #expect(deepest.thumbY == 0)
    }

    /// **A drag lands between the two ends it was given**, and the middle of
    /// the travel is the middle of the document.
    @Test func testASeekLandsBetweenTheEndsItWasGiven() {
        let total = 5_614.0
        let viewport = 968.0
        let newest = I.seekDepth(
            fraction: 1, totalPoints: total, viewportPoints: viewport, step: 1)
        let deepest = I.seekDepth(
            fraction: 0, totalPoints: total, viewportPoints: viewport, step: 1)
        let middle = I.seekDepth(
            fraction: 0.5, totalPoints: total, viewportPoints: viewport, step: 1)
        let expectedMiddle = (total + viewport) / 2
        #expect(newest == viewport)
        #expect(deepest == total)
        #expect(middle == expectedMiddle)
    }

    // MARK: - The landing screen's wait (review M, Q4)

    /// **A screen whose forms keep changing is never given up on**, however
    /// long it takes, and it ends with the one switch: `settled`.
    @Test func testAScreenThatKeepsChangingIsNeverGivenUpOn() {
        var wait = ControlRoomChatPlaceholderWait()
        #expect(wait.look(forms: ["a": "pending:queued"], settled: false, at: 0) == nil)
        // 900 ms of nothing would be a stall; the change at 0.9 restarts it.
        #expect(wait.look(forms: ["a": "pending:inFlight"], settled: false, at: 0.9) == nil)
        #expect(wait.look(forms: ["a": "pending:inFlight"], settled: false, at: 1.5) == nil)
        #expect(wait.look(forms: ["a": "markdown:cache"], settled: true, at: 1.6) == .settled)
    }

    /// **A screen that stops changing is given up on after `stall` -- once.**
    /// A row waiting on a budget or a window is exactly this: nothing this
    /// screen does will change its form, so waiting longer only means a grey
    /// screen with no content.
    @Test func testAScreenThatStopsChangingIsGivenUpOnOnce() {
        var wait = ControlRoomChatPlaceholderWait()
        #expect(wait.look(forms: ["a": "deferred:budget"], settled: false, at: 10) == nil)
        #expect(wait.look(forms: ["a": "deferred:budget"], settled: false, at: 10.9) == nil)
        #expect(wait.look(forms: ["a": "deferred:budget"], settled: false, at: 11) == .stalled)
        // The screen has switched: a row settling later changes nothing here.
        #expect(wait.look(forms: ["a": "markdown:cache"], settled: true, at: 30) == nil)
    }

    /// **Every row settled is the other end, and it is immediate.**
    @Test func testASettledScreenSwitchesAtOnce() {
        var wait = ControlRoomChatPlaceholderWait()
        #expect(wait.look(
            forms: ["a": "markdown:cache", "b": "plain:uncached"],
            settled: true,
            at: 0
        ) == .settled)
    }
}
