import Foundation
import SwiftUI
import Testing

@testable import Ghostty

/// The display mapping from the core's raw UTF-8 ranges to the drawn text.
struct ControlRoomChatDisplayHighlightTests {
    typealias H = ControlRoomChatDisplayHighlight

    private func message(_ text: String, anchor: String = "p:1") -> ControlRoomChatData.Message {
        ControlRoomChatData.Message(
            seq: 0, logSeq: 1, from: "0x1", fromSelf: false, author: "w",
            atMs: 1, summary: false, channel: 0, text: text,
            anchor: anchor, liveAnchor: nil, contentVersion: 0,
            location: nil, mentions: nil, role: nil
        )
    }

    private func hit(_ text: String, start: UInt32, _ ranges: [(UInt32, UInt32)])
        -> ControlRoomChatSearch.Hit
    {
        ControlRoomChatSearch.Hit(
            message: message(text), snippet: "", snippetStart: start,
            ranges: ranges.map { ControlRoomChatSearch.HitRange(start: $0.0, end: $0.1) }
        )
    }

    @Test func testTheMatchedTextIsFoundInTheRenderedBlocksInOrder() {
        let text = "a批量b"
        let plan = H.plan(message: message(text),
                          hit: hit(text, start: 1, [(0, 6)]))
        #expect(plan?.needles.map(\.text) == ["批量"])
        let ranges = H.matches(in: [["a批量b"]], plan: plan!)
        #expect(ranges.count == 1)
        #expect(String("a批量b"[ranges[0].range]) == "批量")
    }

    @Test func testEscapesAreDecodedForComparisonOnly() {
        let text = "docs/a\\(b\\).md"
        let plan = H.plan(message: message(text),
                          hit: hit(text, start: 0, [(0, UInt32(text.utf8.count))]))
        #expect(plan?.needles.map(\.text) == ["docs/a(b).md"])
    }

    /// The core named both matches, so both are drawn -- the second one is
    /// the second occurrence, not the first one twice.
    @Test func testTheSameWordTwiceIsConsumedInTheCoreOrder() {
        let text = "x y x"
        let plan = H.plan(message: message(text),
                          hit: hit(text, start: 0, [(0, 1), (4, 5)]))
        #expect(plan?.needles == [.init(text: "x", rank: 0), .init(text: "x", rank: 1)])
        let matches = H.matches(in: [["x y x"]], plan: plan!)
        #expect(matches.count == 2)
        let text0 = "x y x"
        #expect(matches.map { text0.distance(from: text0.startIndex, to: $0.range.lowerBound) } == [0, 4])
    }

    /// **The position, not the document's first occurrence**: a hit whose
    /// snippet starts after an earlier spelling of the same word points at
    /// the later one.
    @Test func testTheCoreOffsetChoosesTheOccurrenceNotTheFirstOne() {
        let text = "批量 done 批量"
        // The second "批量" starts at UTF-8 byte 13 (3 + 5 + 5).
        let second = UInt32("批量 done ".utf8.count)
        let plan = H.plan(message: message(text),
                          hit: hit(text, start: second, [(0, 6)]))
        #expect(plan?.needles == [.init(text: "批量", rank: 1)])
        let matches = H.matches(in: [["批量 done 批量"]], plan: plan!)
        #expect(matches.count == 1)
        let rendered = "批量 done 批量"
        #expect(rendered.distance(from: rendered.startIndex, to: matches[0].range.lowerBound) == 8)
    }

    /// A needle the rendered text cannot reach is dropped, not moved.
    @Test func testAnUnreachableRankIsNotMovedToANearerWord() {
        let plan = H.Plan(needles: [.init(text: "x", rank: 3)])
        #expect(H.matches(in: [["x y x"]], plan: plan).isEmpty)
    }

    @Test func testAHitForAnotherMessageIsNotPlanned() {
        let plan = H.plan(message: message("abc", anchor: "p:1"),
                          hit: ControlRoomChatSearch.Hit(
                            message: message("abc", anchor: "p:2"), snippet: "", snippetStart: 0,
                            ranges: [.init(start: 0, end: 1)]))
        #expect(plan == nil)
    }

    /// A byte offset inside a character is refused: the plan is nil rather
    /// than a highlight cutting a Chinese character in half.
    @Test func testAnOffsetInsideACharacterIsNotPlanned() {
        let text = "批量"
        let plan = H.plan(message: message(text),
                          hit: hit(text, start: 1, [(0, 2)]))
        #expect(plan == nil)
    }

    /// **A mark SwiftUI will actually draw carries a ground *and* a
    /// different foreground.** `Text` draws nothing for a run whose only
    /// attribute is `AttributedString.backgroundColor`: on the real app one
    /// message and one needle gave 0 yellow pixels with the background
    /// alone, 784 with `.red` beside it, and 0 again with `.primary` -- the
    /// body's own colour (task 2994). The mark therefore pairs the design's
    /// `search_hit` ground with its `search_hit_text` word. What is proved
    /// here is the string the view hands `Text`; the pixels are only provable
    /// on screen.
    @Test func testAMarkedRunCarriesTheGroundAndADifferentForeground() {
        let text = AttributedString("a批量b")
        let plain = "a批量b"
        let match = ControlRoomChatDisplayHighlight.Match(
            block: 0, text: 0, range: plain.range(of: "批量")!)
        let out = ControlRoomChatMarkdownView.marked(
            text, block: 0, text: 0, marks: [match], ink: .yellow, hitText: .red)

        var runs = 0
        for run in out.runs where String(out[run.range].characters) == "批量" {
            runs += 1
            #expect(run.backgroundColor != nil)
            #expect(run.foregroundColor != nil)
            #expect(run.backgroundColor != run.foregroundColor)
        }
        #expect(runs == 1)
    }

    /// The table's cells are one text each, so a match in the second cell is
    /// reported against that cell and not the row's first.
    @Test func testATableCellIsItsOwnText() {
        let plan = H.Plan(needles: [.init(text: "hit", rank: 0)])
        let matches = H.matches(in: [["a", "b"], ["c", "hit"]], plan: plan)
        #expect(matches.count == 1)
        #expect(matches[0].block == 1)
        #expect(matches[0].text == 1)
    }
}
