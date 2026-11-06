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
    /// ③). A restore that ran during a wheel or a live scroll moved the
    /// viewport at the same time as the reader, and the list jumped at a
    /// point part-way up while the scroller still reached the top.
    @Test func testARestoreIsNotRunUnderAHandOnTheList() {
        #expect(A.mayRestore(userScrolling: false, readerRecently: false))
        #expect(!A.mayRestore(userScrolling: true, readerRecently: false))
        #expect(!A.mayRestore(userScrolling: false, readerRecently: true))
        #expect(!A.mayRestore(userScrolling: true, readerRecently: true))
    }

    // MARK: - The reader's anchor

    private var frames: [String: CGRect] {
        [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
            "c": CGRect(x: 0, y: 40, width: 100, height: 10),
        ]
    }

    @Test func testTheAnchorIsTheFirstRowUnderTheViewportTop() {
        #expect(A.anchor(order: ["a", "b", "c"], frames: frames, at: 25)
                == .init(id: "b", offset: 5))
        #expect(A.anchor(order: ["a", "b", "c"], frames: frames, at: 0)
                == .init(id: "a", offset: 0))
        #expect(A.anchor(order: ["a", "b", "c"], frames: frames, at: 100) == nil)
    }

    /// A height change above the anchor moves its frame; the offset that puts
    /// the viewport back is the row's new top plus the same offset into it.
    @Test func testTheAnchorOffsetSurvivesANewRowHeight() {
        let anchor = A.Anchor(id: "b", offset: 5)
        #expect(A.offset(of: anchor, frames: frames) == 25)
        let taller: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 30),
            "b": CGRect(x: 0, y: 40, width: 100, height: 10),
            "c": CGRect(x: 0, y: 60, width: 100, height: 10),
        ]
        #expect(A.offset(of: anchor, frames: taller) == 45)
        #expect(A.offset(of: .init(id: "gone", offset: 5), frames: frames) == nil)
    }

    @Test func testOnlyTheBottomFollowsNewMessages() {
        #expect(A.isAtBottom(offset: 200, viewport: 400, content: 600))
        #expect(A.isAtBottom(offset: 198, viewport: 400, content: 600))
        #expect(!A.isAtBottom(offset: 190, viewport: 400, content: 600))
        #expect(A.isAtBottom(offset: 0, viewport: 400, content: 100))
        #expect(A.shouldLoadOlder(offset: 0))
        #expect(A.shouldLoadOlder(offset: 24))
        #expect(!A.shouldLoadOlder(offset: 25))
    }

    // MARK: - Freezing the reader's place

    /// A layout callback with new frames must not move the anchor; the
    /// frozen position is restored from the new frames instead.
    @Test func testALayoutCallbackDoesNotOverwriteTheAnchor() {
        var keeper = A.Keeper()
        let order = ["a", "b", "c"]
        let moved = keeper.bounds(
            y: 25, order: order, frames: frames,
            user: true
        )
        #expect(moved)
        #expect(keeper.anchor == .init(id: "b", offset: 5))

        keeper.layoutWillChange()
        #expect(keeper.restoring)
        // The callback that arrives with the new frames and the old offset.
        let layoutBounds = keeper.bounds(
            y: 55, order: order, frames: frames,
            user: false
        )
        #expect(!layoutBounds)
        #expect(keeper.anchor == .init(id: "b", offset: 5))

        let taller: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 30),
            "b": CGRect(x: 0, y: 40, width: 100, height: 10),
            "c": CGRect(x: 0, y: 60, width: 100, height: 10),
        ]
        #expect(keeper.restoreTarget(frames: taller) == 45)
        keeper.restored()
        #expect(!keeper.restoring)
    }

    /// The two orders a scroll view reports a layout change in -- bounds
    /// first, frames first -- both leave the frozen anchor alone.
    @Test func testBothCallbackOrdersLeaveTheAnchorWhereItWas() {
        for framesFirst in [true, false] {
            var keeper = A.Keeper()
            let start = keeper.bounds(
                y: 25, order: ["a", "b", "c"], frames: frames,
                user: true
            )
            #expect(start)
            keeper.layoutWillChange()
            if framesFirst {
                let layout = keeper.bounds(
                    y: 55, order: ["a", "b", "c"], frames: frames,
                    user: false
                )
                #expect(!layout)
            } else {
                let programmatic = keeper.bounds(
                    y: 55, order: ["a", "b", "c"], frames: frames,
                    user: false
                )
                #expect(!programmatic)
            }
            #expect(keeper.anchor == .init(id: "b", offset: 5))
            #expect(keeper.restoring)
        }
    }

    /// A programmatic scroll's bounds callback is not the reader moving.
    @Test func testAProgrammaticScrollDoesNotMoveTheAnchor() {
        var keeper = A.Keeper()
        _ = keeper.bounds(
            y: 25, order: ["a", "b", "c"], frames: frames,
            user: true
        )
        let anchor = keeper.anchor
        let programmatic = keeper.bounds(
            y: 0, order: ["a", "b", "c"], frames: frames,
            user: false
        )
        #expect(!programmatic)
        #expect(keeper.anchor == anchor)
    }

    /// Seeding a kept position and restoring it to a different frame is the
    /// tab-return path.
    @Test func testASeededPositionCanBeRestored() {
        var keeper = A.Keeper()
        keeper.seed(.init(id: "c", offset: 3))
        keeper.layoutWillChange()
        #expect(keeper.restoreTarget(frames: frames) == 43)
    }

    /// A reader grabbing the list during a restore takes over: the restore
    /// is over and the anchor becomes theirs.
    @Test func testAUserScrollCancelsARestore() {
        var keeper = A.Keeper()
        _ = keeper.bounds(
            y: 25, order: ["a", "b", "c"], frames: frames,
            user: true
        )
        keeper.layoutWillChange()
        #expect(keeper.restoring)

        let user = keeper.bounds(
            y: 45, order: ["a", "b", "c"], frames: frames,
            user: true
        )
        #expect(user)
        #expect(!keeper.restoring)
        #expect(keeper.anchor == .init(id: "c", offset: 5))
    }

    /// **A layout callback while a place is owed must not drop it** (task
    /// 2999 ④/③). During a window replacement a bounds callback with
    /// unchanged frames is ordinary; while the keeper inferred "the reader"
    /// from that, it cleared the frozen place -- and the viewport stayed at
    /// the top of the new window instead of the row a locate was going to.
    @Test func testALayoutCallbackWithTheSameFramesKeepsTheOwedPlace() {
        var keeper = A.Keeper()
        keeper.seed(.init(id: "c", offset: 3))
        keeper.layoutWillChange()
        #expect(keeper.restoring)

        // The new window's height moved; its frames preference has not
        // arrived yet. This is layout and must change nothing.
        let layout = keeper.bounds(
            y: 0, order: ["a", "b", "c"], frames: frames, user: false)
        #expect(!layout)
        #expect(keeper.restoring)
        #expect(keeper.anchor == .init(id: "c", offset: 3))

        // The frames arrive: the owed place is still the target row.
        let taller: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 30),
            "b": CGRect(x: 0, y: 40, width: 100, height: 10),
            "c": CGRect(x: 0, y: 60, width: 100, height: 10),
        ]
        #expect(keeper.restoreTarget(frames: taller) == 63)
        keeper.restored()
        #expect(!keeper.restoring)
    }

    /// **And the reader still wins**: a wheel or a drag before the place is
    /// put back cancels it, and the viewport stays where they left it.
    @Test func testTheReaderCancelsTheOwedPlace() {
        var keeper = A.Keeper()
        keeper.seed(.init(id: "c", offset: 3))
        keeper.layoutWillChange()
        #expect(keeper.restoring)

        let user = keeper.bounds(
            y: 25, order: ["a", "b", "c"], frames: frames, user: true)
        #expect(user)
        #expect(!keeper.restoring)
        #expect(keeper.restoreTarget(frames: frames) == nil)
        #expect(keeper.anchor == .init(id: "b", offset: 5))
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

    /// A remembered bottom is only owed while the reader has not moved.
    @Test func testAFollowIntentIsDroppedByAUserScroll() {
        #expect(A.mayFollow(intentEpoch: 3, currentUserEpoch: 3))
        #expect(!A.mayFollow(intentEpoch: 3, currentUserEpoch: 4))
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

    // MARK: - The blank list and the spent restore (task 3002 review)

    /// **A restore is not spent on the map it was frozen against.** A
    /// replaced window's frames preference arrives after the freeze; until
    /// the epoch moves, "it is already there" means nothing.
    @Test func testARestoreIsOnlySpentOnceTheFramesMovedOn() {
        #expect(!A.restoreWasAnswered(framesEpoch: 7, frozenAt: 7))
        #expect(!A.restoreWasAnswered(framesEpoch: 6, frozenAt: 7))
        #expect(A.restoreWasAnswered(framesEpoch: 8, frozenAt: 7))
    }

    /// The blank list's second answer is the nearest **measured** row, so the
    /// viewport lands where rows exist -- not at the bottom, which would
    /// throw the reader's place away.
    @Test func testTheRecoveryPicksTheNearestMeasuredRow() {
        let list = frameMap([40, 40, 40])
        // Rows at 0..40, 50..90, 100..140; a viewport centred at 78 is
        // nearest r1 (mid 70), not r2 (mid 120).
        #expect(A.nearestMeasured(centre: 78, frames: list.frames) == "r1")
        #expect(A.nearestMeasured(centre: 0, frames: list.frames) == "r0")
        #expect(A.nearestMeasured(centre: 300, frames: list.frames) == "r2")
        #expect(A.nearestMeasured(centre: 300, frames: [:]) == nil)
    }
}
