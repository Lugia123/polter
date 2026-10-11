import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// The group list's arithmetic: what a row says, where things are, where the
/// selection goes, how the chip gets there.
///
/// **What these are not.** Nothing here asks which rows there should be or
/// what order they are in. That is the core's, and a test of it here would
/// be the host deciding it a second time.
struct ControlRoomListTests {
    typealias Look = ControlRoomLook
    let list = ControlRoomList.sample

    // MARK: What a row says

    @Test func othersAreSaidOnlyWhenThereAreSome() {
        // The words are the translation table's; what is this code's is
        // whether anything is said, and that the number said is the one given.
        #expect(ControlRoomList.othersText(0) == nil)
        let one = ControlRoomList.othersText(1) ?? ""
        #expect(one.contains("1"))
        let three = ControlRoomList.othersText(3) ?? ""
        #expect(three.contains("3") && !three.contains("1"))
    }

    @Test func theTooltipIsTheWholeDetailAndThereIsNoneForNoDetail() {
        let cut = ControlRoomList.tooltip(for: list.waiting[0])
        #expect(cut == "rm -rf dist/ && npm run build")
        let quiet = ControlRoomList.tooltip(for: list.quiet[0])
        #expect(quiet == nil)
    }

    @Test func theCountsShownAreTheOnesHandedIn() {
        // Not `waiting.count`: a list handed 7 says 7 whatever it holds.
        var odd = list
        odd.waitingCount = 7
        odd.quietCount = 0
        #expect(odd.waiting.count == 3)
        #expect(odd.waitingCount == 7)
        #expect(odd.quietCount == 0)
    }

    // MARK: From the core's snapshot

    /// The core's shape, cut down to two groups that wait and one that does
    /// not. Field for field what `ControlRoom.zig` writes, including ones
    /// this side does not read.
    private let snapshot = Data("""
    { "rev": 9, "now_ms": 6000000, "needs_me": 2, "groups_needing_me": 5, "groups_other": 8,
      "groups": [
        { "name": "web-app", "brief": "", "steward": "0x00000000000000a1",
          "needs_me": true, "unseen": false, "shown": "needs_you", "word": "needs_approval", "text": "等批准",
          "waited_min": 4, "reason": {"from": "hook_note", "text": "Bash(rm -rf dist/)", "missing": null},
          "more": 1, "same_as": null, "members": [] },
        { "name": "infra", "needs_me": false, "unseen": true, "shown": "done_unseen", "word": "done_unseen",
          "text": "做完了，没看", "waited_min": null,
          "reason": {"from": "last_turn", "text": "", "missing": "no_turn_kept"}, "more": 0, "same_as": null },
        { "name": "web-app-docs", "needs_me": true, "unseen": false, "shown": "trouble", "word": "failed",
          "text": "出错", "waited_min": 4, "reason": {"from": "hook_detail", "text": "限流", "missing": null},
          "more": 0, "same_as": "web-app" }
      ], "ungrouped": [], "terminals": [], "tabs": [] }
    """.utf8)

    @Test func aRowIsACopyOfWhatTheSnapshotSays() throws {
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let row = made.waiting[0]
        #expect(row.id == "web-app")
        #expect(row.shown == .needsYou)
        #expect(row.word == "等批准")
        #expect(row.detail == "Bash(rm -rf dist/)")
        #expect(row.detailIsCode == true)
        #expect(row.waitedMin == 4)
        #expect(row.others == 1)
        #expect(made.nowMs == 6_000_000)
    }

    @Test func theCountsAreTheSnapshotsAndNotTheNumberOfRows() throws {
        // The snapshot says 5 and 8 while holding 2 and 1: the list says 5 and 8.
        let made = try ControlRoomList.decode(snapshot: snapshot)
        #expect(made.waiting.count == 2)
        #expect(made.quiet.count == 1)
        #expect(made.waitingCount == 5)
        #expect(made.quietCount == 8)
    }

    @Test func eachRowGoesWhereItsOwnFlagSaysAndKeepsTheSnapshotsOrder() throws {
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let waiting = made.waiting.map(\.id)
        #expect(waiting == ["web-app", "web-app-docs"])
        let quiet = made.quiet.map(\.id)
        #expect(quiet == ["infra"])
        #expect(made.quiet[0].waitedMin == nil)
        #expect(made.quiet[0].detail == "")
    }

    @Test func aGroupUnderTheSameSupervisorPointsAtTheRowThatHasTheReason() throws {
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let row = made.waiting[1]
        // It names the other row and does not repeat the reason ("限流").
        #expect(row.detail.contains("web-app"))
        #expect(!row.detail.contains("限流"))
        #expect(row.detailIsCode == false)
    }

    @Test func aGlyphTheHostDoesNotKnowIsAnErrorNotABlank() {
        let odd = Data((String(bytes: snapshot, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\"done_unseen\", \"word\"", with: "\"sparkles\", \"word\"").utf8)
        #expect(throws: DecodingError.self) {
            try ControlRoomList.decode(snapshot: odd)
        }
    }

    @Test func aSnapshotCarriesNoTimeBandYetSoTheListHasNone() throws {
        let made = try ControlRoomList.decode(snapshot: snapshot)
        #expect(made.timeBand == nil)
        let layout = ControlRoomListLayout(list: made, height: 600)
        #expect(layout.lanes.isEmpty)
    }

    // MARK: Where the selection goes

    @Test func arrowKeysWalkTheListedOrderAcrossBothSections() {
        let rows = list.rows
        let order = rows.map(\.id)
        #expect(order == ["web-app", "billing", "docs-site", "infra", "design-system"])
        let down = ControlRoomList.move("docs-site", by: 1, in: rows)
        #expect(down == "infra")
        let up = ControlRoomList.move("infra", by: -1, in: rows)
        #expect(up == "docs-site")
    }

    @Test func theSelectionStopsAtTheEnds() {
        let rows = list.rows
        let top = ControlRoomList.move("web-app", by: -1, in: rows)
        #expect(top == "web-app")
        let bottom = ControlRoomList.move("design-system", by: 1, in: rows)
        #expect(bottom == "design-system")
    }

    @Test func withNothingSelectedAStepLandsOnTheNearEnd() {
        let rows = list.rows
        let down = ControlRoomList.move(nil, by: 1, in: rows)
        #expect(down == "web-app")
        let up = ControlRoomList.move(nil, by: -1, in: rows)
        #expect(up == "design-system")
        let gone = ControlRoomList.move("no-such-group", by: 1, in: rows)
        #expect(gone == "web-app")
        let empty = ControlRoomList.move("web-app", by: 1, in: [])
        #expect(empty == nil)
    }

    // MARK: Where things are

    /// The design's panel is 824 high; these are its GRID readings, moved
    /// from window coordinates (the panel is at 8, 68) to the panel's own.
    @Test func theWaitingRowsAreWhereTheDesignPutThem() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.size == CGSize(width: 308, height: 824))
        #expect(layout.header == CGRect(x: 6, y: 6, width: 296, height: 32))
        #expect(layout.rows["web-app"] == CGRect(x: 6, y: 38, width: 296, height: 60))
        #expect(layout.rows["billing"] == CGRect(x: 6, y: 106, width: 296, height: 60))
        #expect(layout.rows["docs-site"] == CGRect(x: 6, y: 174, width: 296, height: 60))
    }

    @Test func theQuietSectionFollowsTheSeparator() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.separator == CGRect(x: 18, y: 250, width: 272, height: 0.5))
        #expect(layout.quietHeader == CGRect(x: 6, y: 254.5, width: 296, height: 32))
        #expect(layout.rows["infra"] == CGRect(x: 6, y: 286.5, width: 296, height: 28))
        #expect(layout.rows["design-system"] == CGRect(x: 6, y: 314.5, width: 296, height: 28))
    }

    @Test func theChipRestsExactlyOnItsRowAndNowhereForARowNotListed() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.chip(for: "billing") == layout.rows["billing"])
        #expect(layout.chip(for: "infra") == layout.rows["infra"])
        #expect(layout.chip(for: nil) == nil)
        #expect(layout.chip(for: "no-such-group") == nil)
    }

    @Test func theTimeBandHangsFromTheBottomWhateverTheHeight() {
        let heights: [CGFloat] = [824, 600]
        for height in heights {
            let layout = ControlRoomListLayout(list: list, height: height)
            let laneH = CGFloat(Look.Side.timeLaneLabelledHeight)
            let floor = height - 12
            #expect(layout.axis.maxY == floor)
            #expect(layout.axis.height == 24)
            #expect(layout.lanes.count == 3)
            #expect(layout.lanes[2].maxY == layout.axis.minY)
            #expect(layout.lanes[0].minY == layout.axis.minY - 3 * laneH)
            #expect(layout.bandHeader.maxY == layout.lanes[0].minY)
            #expect(layout.bandHeader.height == 32)
        }
    }

    // MARK: Today's waiting

    private let band = ControlRoomList.TimeBand(startMs: 1_000, startLabel: "09:00", totalMinutes: 0, lanes: [])

    @Test func aSpanIsDrawnInProportionToTheDaySoFar() {
        let lane = ControlRoomList.Lane(name: "a", spans: [.init(fromMs: 1_250, toMs: 1_500, ongoing: false)])
        let pieces = ControlRoomListLayout.segments(lane, band: band, now: 2_000, width: 200)
        #expect(pieces.count == 1)
        #expect(pieces[0].x == 50)
        #expect(pieces[0].width == 50)
        #expect(pieces[0].ongoing == false)
    }

    @Test func aSpanStillGoingRunsToNow() {
        let lane = ControlRoomList.Lane(name: "a", spans: [.init(fromMs: 1_800, toMs: 1_800, ongoing: true)])
        let pieces = ControlRoomListLayout.segments(lane, band: band, now: 2_000, width: 200)
        #expect(pieces.count == 1)
        #expect(pieces[0].x == 160)
        #expect(pieces[0].width == 40)
        #expect(pieces[0].ongoing == true)
    }

    @Test func spansAreClippedToTheBandAndEmptyOnesDropped() {
        let lane = ControlRoomList.Lane(name: "a", spans: [
            .init(fromMs: 500, toMs: 1_100, ongoing: false),     // starts before the band
            .init(fromMs: 1_900, toMs: 2_600, ongoing: false),   // ends after now
            .init(fromMs: 1_400, toMs: 1_400, ongoing: false),   // no length
            .init(fromMs: 100, toMs: 900, ongoing: false),       // wholly before
        ])
        let pieces = ControlRoomListLayout.segments(lane, band: band, now: 2_000, width: 100)
        #expect(pieces.count == 2)
        #expect(pieces[0].x == 0)
        #expect(pieces[0].width == 10)
        #expect(pieces[1].x == 90)
        #expect(pieces[1].width == 10)
        let noDay = ControlRoomListLayout.segments(lane, band: band, now: 1_000, width: 100)
        #expect(noDay.isEmpty)
    }

    @Test func theNameAtALanesLeftEndComesOffItsTrack() {
        let track = ControlRoomListLayout.trackWidth(lane: 272)
        #expect(track == 272 - CGFloat(Look.Side.timeLaneLabelWidth) - CGFloat(Look.Side.rowItemGap))
        let tiny = ControlRoomListLayout.trackWidth(lane: 10)
        #expect(tiny == 0)
    }

    // MARK: How the chip moves

    @Test func theChipStartsAtRestAndSettlesOnItsRow() {
        let start = ControlRoomChipSpring.progress(at: 0)
        #expect(start == 0)
        let settled = ControlRoomChipSpring.progress(at: 1.5)
        #expect(abs(settled - 1) < 0.001)
    }

    @Test func theChipOvershootsByAboutFourPercentAndComesBack() {
        // The design: "about 0.26 s to its furthest, about 4% past".
        let peak = stride(from: 0.0, through: 1.0, by: 0.001)
            .map { ($0, ControlRoomChipSpring.progress(at: $0)) }
            .max { $0.1 < $1.1 }!
        #expect(peak.1 > 1.03 && peak.1 < 1.05)
        #expect(peak.0 > 0.24 && peak.0 < 0.28)
        let said = ControlRoomChipSpring.overshoot()
        #expect(abs((peak.1 - 1) - said) < 0.001)
    }

    @Test func aCriticallyDampedChipNeverPassesItsRow() {
        // The other candidate for the tentative `spring_damping`.
        let highest = stride(from: 0.0, through: 2.0, by: 0.001)
            .map { ControlRoomChipSpring.progress(at: $0, damping: 1) }
            .max()!
        #expect(highest <= 1)
        // A fifth of a second in it is most of the way and is a number: the
        // under-damped formula divides by zero here.
        let partway = ControlRoomChipSpring.progress(at: 0.2, damping: 1)
        #expect(abs(partway - 0.863) < 0.001)
        let said = ControlRoomChipSpring.overshoot(damping: 1)
        #expect(said == 0)
    }

    // MARK: The glyphs' motion

    @Test func thePulseGoesFromFullToTheTablesMinimumAndBack() {
        let period = Look.Status.waitingPulsePeriod
        let full = ControlRoomGlyph.pulse(at: 0)
        #expect(full == 1)
        let low = ControlRoomGlyph.pulse(at: period / 2)
        #expect(abs(low - Look.Status.waitingPulseMinOpacity) < 1e-9)
        let again = ControlRoomGlyph.pulse(at: period)
        #expect(abs(again - 1) < 1e-9)
    }

    @Test func theSpinnerStepsThroughEveryLineOncePerTurn() {
        let period = Look.Status.workingSpinPeriod
        let steps = Int(Look.Status.workingSpinSteps)
        let seen = (0..<steps).map { ControlRoomGlyph.spinStep(at: (Double($0) + 0.5) * period / Double(steps)) }
        #expect(seen == Array(0..<steps))
        let held = ControlRoomGlyph.spinStep(at: 0.01)
        #expect(held == 0)
    }
}
