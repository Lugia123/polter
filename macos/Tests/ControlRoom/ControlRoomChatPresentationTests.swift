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
            framesChanged: false, programmatic: false
        )
        #expect(moved)
        #expect(keeper.anchor == .init(id: "b", offset: 5))

        keeper.layoutWillChange()
        #expect(keeper.restoring)
        // The callback that arrives with the new frames and the old offset.
        let layoutBounds = keeper.bounds(
            y: 55, order: order, frames: frames,
            framesChanged: true, programmatic: false
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
                framesChanged: false, programmatic: false
            )
            #expect(start)
            keeper.layoutWillChange()
            if framesFirst {
                let layout = keeper.bounds(
                    y: 55, order: ["a", "b", "c"], frames: frames,
                    framesChanged: true, programmatic: false
                )
                #expect(!layout)
            } else {
                let programmatic = keeper.bounds(
                    y: 55, order: ["a", "b", "c"], frames: frames,
                    framesChanged: false, programmatic: true
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
            framesChanged: false, programmatic: false
        )
        let anchor = keeper.anchor
        let programmatic = keeper.bounds(
            y: 0, order: ["a", "b", "c"], frames: frames,
            framesChanged: false, programmatic: true
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
            framesChanged: false, programmatic: false
        )
        keeper.layoutWillChange()
        #expect(keeper.restoring)

        let user = keeper.bounds(
            y: 45, order: ["a", "b", "c"], frames: frames,
            framesChanged: false, programmatic: false
        )
        #expect(user)
        #expect(!keeper.restoring)
        #expect(keeper.anchor == .init(id: "c", offset: 5))
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
}
