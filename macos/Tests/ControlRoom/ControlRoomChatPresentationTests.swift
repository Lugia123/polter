import CoreGraphics
import Foundation
import Testing

@testable import Ghostty

/// The message list's own rules: where a released run is drawn, what a row
/// says about time and metadata, and how the page's id list changed between
/// two updates. **The anchor/camera/window half is gone** with the native
/// list (design v3 §七); the page owns scrolling now.
///
/// **The list inputs are real**: whole id arrays and the feed's two gap
/// markers, not one field at a time. A plan that draws p:101 next to p:152 is
/// the defect this suite exists to catch.
struct ControlRoomChatPresentationTests {
    typealias P = ControlRoomChatPresentation

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

    /// **Which of the five things happened to the page's id list.** The
    /// bridge's own classifier (design v3 §五): `page.append` per row for
    /// the end, one `page.prepend` for the front, and `page.reset` for
    /// anything else. It was the native list's anchor classifier when that
    /// list needed the same answer; the anchor is gone and this one reader
    /// is left (`ControlRoomChatTranscriptDiff`).
    @Test func testTheRowListChangeTellsPrependFromAppend() {
        typealias Change = ControlRoomChatTranscriptDiff.Change
        #expect(ControlRoomChatTranscriptDiff.change(from: [], to: ["a"]) == .appended)
        #expect(ControlRoomChatTranscriptDiff.change(from: ["b", "c"], to: ["a", "b", "c"]) == .prepended)
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b"], to: ["a", "b", "c"]) == .appended)
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b"], to: ["a", "b"]) == .none)
        // **A slide is still the same map**: the window dropped its front
        // and grew at the back, and the rows the reader is among are
        // untouched -- so the page is not told everything again.
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b", "c"], to: ["b", "c", "d"]) == .moved)
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b", "c"], to: ["b", "c"]) == .moved)
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b", "c"], to: ["a", "b"]) == .moved)
        // **A row that left the middle** is not a window move: the surviving
        // ids no longer form the run they bounded.
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b", "c"], to: ["a", "c"]) == .replaced)
        // **Another map**: nothing contiguous survives.
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b"], to: ["x", "y"]) == .replaced)
        #expect(ControlRoomChatTranscriptDiff.change(from: ["a", "b", "c"], to: []) == .replaced)
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
    }}
