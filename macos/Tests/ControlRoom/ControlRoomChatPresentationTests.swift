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
    /// gap is still real, so it is said at the top rather than dropped and
    /// the two messages are not drawn as neighbours.
    @Test func testAnUnplaceableGapIsStillSaid() {
        let rows = P.listRows(
            order: ["p:200", "p:201"],
            trimmedBefore: nil,
            trimmedAfter: "p:101"
        )
        #expect(rows.first == .gap(.before("p:200")))
        #expect(rows.contains(.message(id: "p:201")))
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
        #expect(!C.pinned(after: .user, atBottom: false, was: true))
        #expect(C.pinned(after: .user, atBottom: true, was: false))
        // A layout or the view's own scroll changes nothing, even at the
        // bottom: only the reader pins or unpins.
        #expect(!C.pinned(after: .layout, atBottom: true, was: false))
        #expect(C.pinned(after: .programmatic, atBottom: false, was: true))

        // **The pair, in the view's order** (R1-7): `bounds` first (it
        // voids the owed bottom and unpins), then `pinned(after:)`. A reader
        // who lands on the bottom ends up pinned with nothing owed -- the
        // intermediate `false` must not survive, and must not eat `.pin`.
        var state = C.State(
            place: .init(id: "b", offset: 5), pinned: false, owed: .pin)
        state.bounds(cause: .user, y: 43, order: ["a", "b", "c"], frames: frames)
        state.pinned = C.pinned(after: .user, atBottom: true, was: state.pinned)
        #expect(state.pinned)
        #expect(state.owed == nil)
        #expect(state.place == .init(id: "c", offset: 3))
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

    /// **The prefetch asks three viewports before the edge** (new, §5;
    /// replaced the `shouldLoadOlder` half of the old bottom test).
    @Test func testPrefetchAsksThreeViewportsBeforeTheEdge() {
        #expect(C.wantsOlder(top: 0, loadedTop: 0, viewport: 600))
        #expect(C.wantsOlder(top: 1800, loadedTop: 0, viewport: 600))
        #expect(!C.wantsOlder(top: 1800.5, loadedTop: 0, viewport: 600))
        // The floor's shape: a threshold of zero asks only at the edge.
        #expect(!C.wantsOlder(top: 1, loadedTop: 0, viewport: 600, screens: 0))
        #expect(C.wantsOlder(top: 0, loadedTop: 0, viewport: 600, screens: 0))

        #expect(C.wantsNewer(bottom: 4000, loadedBottom: 5000, viewport: 600))
        #expect(!C.wantsNewer(bottom: 3199, loadedBottom: 5000, viewport: 600))
        // No viewport measured: nothing is asked.
        #expect(!C.wantsOlder(top: 0, loadedTop: 0, viewport: 0))
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
        var expectations: [Double] = []
        expectations.append(100)
        expectations.append(200)
        #expect(C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 100,
            expectations: &expectations))
        #expect(C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 200,
            expectations: &expectations))
        #expect(expectations.isEmpty)

        // **A callback that matches nothing is not the view's** -- and does
        // not spend the expectations that are still owed.
        var owed: [Double] = [400]
        #expect(!C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 250,
            expectations: &owed))
        #expect(owed == [400])
        #expect(C.programmaticCallback(
            inScrollCall: false, seekInFlight: false, y: 400.4,
            expectations: &owed))
        #expect(owed.isEmpty)
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
        // Our own scroll stays ours, whatever the wheel is doing.
        #expect(A.cause(
            contentChanged: true, framesChanged: false,
            phaseIsLayout: false, programmatic: true,
            userScrolling: false, readerRecently: true
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
        // The window dropped its front while appending: neither end is the
        // same list, so this is not an append that may pull the reader down.
        #expect(A.change(from: ["a", "b", "c"], to: ["b", "c", "d"]) == .replaced)
    }

    // MARK: - The index bar (task 3002)

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
    @Test func testTheThumbIsTheShareOfTheMapTheViewportCovers() {
        let all: CGFloat = 300
        #expect(I.thumbHeight(totalTicks: 10, viewportTicks: 10, trackH: all) == all)
        #expect(I.thumbHeight(totalTicks: 20, viewportTicks: 10, trackH: all) == 150)
        #expect(I.thumbHeight(totalTicks: 100, viewportTicks: 10, trackH: all) == 36)
        // A night's messages: the ratio would be under a point, the floor
        // holds, and the thumb is still no taller than its track.
        #expect(I.thumbHeight(totalTicks: 5_000, viewportTicks: 10, trackH: all) == 36)
        // A track shorter than the floor is the limit, not the floor.
        #expect(I.thumbHeight(totalTicks: 5_000, viewportTicks: 10, trackH: 30) == 30)
        #expect(I.thumbHeight(totalTicks: 20, viewportTicks: 10, trackH: 20) == 20)
        #expect(I.thumbHeight(totalTicks: 0, viewportTicks: 0, trackH: all) == all)
    }

    /// **The thumb reaches the end of its travel exactly at the bottom**:
    /// that is what makes the bar's end read as the newest message and not as
    /// "somewhere near it".
    @Test func testTheThumbReachesTheEndOnlyAtTheBottom() {
        let top = I.geometry(totalTicks: 500, viewportTicks: 10, topTick: 0, trackH: 300)
        #expect(top.thumbY == 0)
        #expect(top.thumbH == 36)
        let bottom = I.geometry(
            totalTicks: 500, viewportTicks: 10, topTick: 490, trackH: 300)
        let travel: CGFloat = 300 - 36
        #expect(bottom.thumbY == travel)
        let middle = I.geometry(
            totalTicks: 500, viewportTicks: 10, topTick: 245, trackH: 300)
        #expect(middle.thumbY == travel / 2)
        // Past the end is still the end: an estimate that overshoots must not
        // draw the thumb outside the track.
        let past = I.geometry(totalTicks: 500, viewportTicks: 10, topTick: 900, trackH: 300)
        #expect(past.thumbY == travel)
    }

    /// **A drag lands on a row of the loaded map**, from the first to the
    /// last, and never past either end.
    @Test func testADragLandsOnARowAndNeverPastTheEnds() {
        #expect(I.seekIndex(fraction: 0, totalTicks: 101, step: 1) == 0)
        #expect(I.seekIndex(fraction: 1, totalTicks: 101, step: 1) == 100)
        #expect(I.seekIndex(fraction: 0.5, totalTicks: 101, step: 1) == 50)
        #expect(I.seekIndex(fraction: -1, totalTicks: 101, step: 1) == 0)
        #expect(I.seekIndex(fraction: 2, totalTicks: 101, step: 1) == 100)
        // One drawn cell is `step` rows, so a drag lands on a cell boundary:
        // 50 with steps of 3 goes to the nearest multiple, 51.
        #expect(I.seekIndex(fraction: 0.5, totalTicks: 100, step: 3) == 51)
        let last = I.seekIndex(fraction: 1, totalTicks: 100, step: 3)
        #expect(last == 99)
        #expect(I.seekIndex(fraction: 0, totalTicks: 0, step: 1) == 0)
    }

    /// **How many rows one drawn tick stands for**: one while they fit, more
    /// once they do not.
    @Test func testAStepIsHowManyRowsOneTickStandsFor() {
        // 300pt of track, one tick every 5pt: sixty fit.
        #expect(I.step(totalTicks: 60, trackH: 300) == 1)
        #expect(I.step(totalTicks: 61, trackH: 300) == 2)
        #expect(I.step(totalTicks: 120, trackH: 300) == 2)
        #expect(I.step(totalTicks: 601, trackH: 300) == 11)
        #expect(I.step(totalTicks: 0, trackH: 300) == 1)
        let fractions = I.tickFractions(totalTicks: 601, step: 11)
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
    @Test func testTheTopTickIsARowPlusHowFarIntoItTheReaderIs() {
        let list = frameMap([40, 40, 40])
        // Row r1 spans 50..90. Offset 60 is a quarter into it.
        let quarter = I.topTick(
            order: list.order, frames: list.frames, offset: 60, viewport: 20)
        #expect(quarter == 1.25)
        let atTop = I.topTick(
            order: list.order, frames: list.frames, offset: 0, viewport: 20)
        #expect(atTop == 0)
        // Nothing measured is "not known", not "at the top".
        #expect(I.topTick(order: ["x"], frames: [:], offset: 0, viewport: 20) == nil)
        #expect(I.topTick(order: list.order, frames: list.frames, offset: 0, viewport: 0) == nil)
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

    /// The bubble says which row and when, and never invents a clock the row
    /// does not have.
    @Test func testTheBubbleNamesTheRowAndItsClock() {
        #expect(I.bubbleText(index: 0, time: "10:12:05") == "#1  10:12:05")
        #expect(I.bubbleText(index: 99, time: "") == "#100")
    }

    // The old spent-restore test and the old nearest-measured test moved to
    // the camera's state machine section above: `testAOwedProjectionIsNot
    // AnsweredByTheFramesItWasFrozenAgainst` and
    // `testAFallbackPicksTheNearestMeasuredRow`. Nothing here was dropped --
    // the assertion for each old one is still exactly once in the file.
}
