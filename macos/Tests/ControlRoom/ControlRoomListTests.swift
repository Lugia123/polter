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

    @Test func theTooltipIsEveryStepWholeAndThereIsNoneForNothing() {
        let command = ControlRoomList.tooltip(for: list.waiting[1])
        #expect(command == "rm -rf dist/ .cache/ node_modules/.vite\n&& npm ci\n&& npm run build -- --mode production")
        let nothing = ControlRoomList.tooltip(for: list.quiet[3])
        #expect(nothing == nil)
    }

    @Test func theCountsShownAreTheOnesHandedIn() {
        // Not `waiting.count`: a list handed 7 says 7 whatever it holds.
        var odd = list
        odd.waitingCount = 7
        odd.quietCount = 0
        #expect(odd.waiting.count == 4)
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
          "waiter": {"is": "worker_via_supervisor", "name": "ios-build"},
          "reason": {"from": "hook_note", "text": "Bash(rm -rf dist/ && npm ci)", "missing": null},
          "what": {"form": "command", "lines": ["rm -rf dist/", "&& npm ci"]},
          "more": 1, "same_as": null, "members": [] },
        { "name": "infra", "needs_me": false, "unseen": true, "shown": "done_unseen", "word": "done_unseen",
          "text": "做完了，没看", "waiter": {"is": "none", "name": ""},
          "reason": {"from": "last_turn", "text": "", "missing": "no_turn_kept"},
          "what": {"form": "none", "lines": []}, "more": 0, "same_as": null },
        { "name": "web-app-docs", "needs_me": true, "unseen": false, "shown": "trouble", "word": "failed",
          "text": "出错", "waiter": {"is": "supervisor", "name": ""},
          "reason": {"from": "hook_detail", "text": "限流", "missing": null},
          "what": {"form": "words", "lines": ["限流"]}, "more": 0, "same_as": "web-app" }
      ], "ungrouped": [], "terminals": [], "tabs": [] }
    """.utf8)

    @Test func aRowIsACopyOfWhatTheSnapshotSays() throws {
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let row = made.waiting[0]
        #expect(row.id == "web-app")
        #expect(row.shown == .needsYou)
        #expect(row.word == "等批准")
        // Who is waiting and for what are the core's, copied: the steps as
        // it cut them, none joined and none dropped.
        #expect(row.waiter == ControlRoomList.Waiter(is: .workerViaSupervisor, name: "ios-build"))
        #expect(row.what.form == .command)
        #expect(row.what.lines == ["rm -rf dist/", "&& npm ci"])
        #expect(row.what.isCode == true)
        #expect(row.others == 1)
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
        #expect(made.quiet[0].waiter == .none)
        #expect(made.quiet[0].what == .none)
    }

    @Test func whetherItIsSetAsCodeIsTheCoresFormAndNotWhereTheWordsCameFrom() throws {
        // The second waiting row's words came from a hook too, and are a
        // sentence: the core says `words`.
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let row = made.waiting[1]
        #expect(row.what.form == .words)
        #expect(row.what.isCode == false)
        #expect(row.waiter.is == .supervisor)
    }

    @Test func aSnapshotThatDoesNotSayWhoWaitsOrForWhatIsNotRead() {
        // Not read as "nobody" and "nothing": a row that silently lost what
        // it waits on would look like a group with nothing to say.
        let text = String(bytes: snapshot, encoding: .utf8) ?? ""
        for field in ["\"waiter\"", "\"what\""] {
            let cut = text.replacingOccurrences(of: field, with: "\"gone\"")
            #expect(cut != text)
            #expect(throws: DecodingError.self) {
                try ControlRoomList.decode(snapshot: Data(cut.utf8))
            }
        }
        let odd = text.replacingOccurrences(of: "\"form\": \"command\"", with: "\"form\": \"poem\"")
        #expect(odd != text)
        #expect(throws: DecodingError.self) {
            try ControlRoomList.decode(snapshot: Data(odd.utf8))
        }
    }

    @Test func aGlyphTheHostDoesNotKnowIsAnErrorNotABlank() {
        let odd = Data((String(bytes: snapshot, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\"done_unseen\", \"word\"", with: "\"sparkles\", \"word\"").utf8)
        #expect(throws: DecodingError.self) {
            try ControlRoomList.decode(snapshot: odd)
        }
    }

    // MARK: The core's own fixture

    /// The snapshot the core's tests build and check against the code that
    /// writes it. Read from the tree, so a change of shape there is seen here.
    static func fixture() throws -> Data {
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("src/poltergeist/testdata/control_snapshot.json"))
    }

    @Test func theCoresFixtureDecodesIntoItsEightGroups() throws {
        let made = try ControlRoomList.decode(snapshot: Self.fixture())
        let waiting = made.waiting.map(\.id)
        #expect(waiting == ["web-app", "web-app-docs", "mobile", "billing", "docs-site"])
        let quiet = made.quiet.map(\.id)
        #expect(quiet == ["infra", "design-system", "notes"])
        #expect(made.waitingCount == 5)
        #expect(made.quietCount == 3)
    }

    @Test func theCoresFixtureSaysWhoWaitsAndForWhat() throws {
        let made = try ControlRoomList.decode(snapshot: Self.fixture())
        let web = try #require(made.rows.first { $0.id == "web-app" })
        #expect(web.waiter.is == .supervisor)
        #expect(web.what.form == .command)
        #expect(web.what.lines == [
            "rm -rf dist/ .cache/ node_modules/.vite", "&& npm ci", "&& npm run build -- --mode production",
        ])
        let mobile = try #require(made.rows.first { $0.id == "mobile" })
        #expect(mobile.waiter == ControlRoomList.Waiter(is: .workerViaSupervisor, name: "ios-build"))
        let billing = try #require(made.rows.first { $0.id == "billing" })
        #expect(billing.what.form == .words)
        #expect(billing.what.isCode == false)
        // Nobody waits on a row that needs nothing; it may still say what
        // the group is doing.
        let design = try #require(made.rows.first { $0.id == "design-system" })
        #expect(design.waiter == .none)
        #expect(design.what.lines == ["改按钮的三种尺寸"])
        let notes = try #require(made.rows.first { $0.id == "notes" })
        #expect(notes.what == .none)
    }

    @Test func nothingInTheCoresFixtureSaysHowLong() throws {
        // The minutes and the band of today's waiting were taken out (the
        // user's ruling, 2026-10-13).
        let text = String(bytes: try Self.fixture(), encoding: .utf8) ?? ""
        #expect(!text.isEmpty)
        for gone in ["waited_min", "\"band\"", "total_min", "\"lanes\"", "\"spans\""] {
            #expect(!text.contains(gone), "the fixture says \(gone) again")
        }
    }

    @Test func theRowThatBreathesIsTheFirstInTheCoresListNotAlreadyInFront() throws {
        // The fixture's list: billing's terminal (tab …22), then web-app's
        // (tab …21, row web-app-docs), then two with no row.
        let nothingInFront = try ControlRoomList.decode(snapshot: Self.fixture())
        let breathing = nothingInFront.rows.filter(\.pulses).map(\.id)
        #expect(breathing == ["billing"])

        // With billing's own tab in front it is not billing: the person is
        // already looking at that one. The next in the list is.
        let billingInFront = try ControlRoomList.decode(
            snapshot: Self.fixture(), showing: "0x0000000000000022")
        let next = billingInFront.rows.filter(\.pulses).map(\.id)
        #expect(next == ["web-app-docs"])
    }

    @Test func aRowCarriesBackTheMomentsItWasDrawnFrom() throws {
        let made = try ControlRoomList.decode(snapshot: Self.fixture())
        let target = made.waiting[0].target
        #expect(target?.terminal == "0x00000000000000a1")
        #expect(target?.sinceMs == 5_760_000)
        #expect(target?.eventMs != nil)
    }

    // MARK: Where the selection goes

    @Test func arrowKeysWalkTheListedOrderAcrossBothSections() {
        let rows = list.rows
        let order = rows.map(\.id)
        #expect(order == ["billing", "web-app", "mobile", "docs-site", "infra", "design-system", "search", "notes"])
        let down = ControlRoomList.move("docs-site", by: 1, in: rows)
        #expect(down == "infra")
        let up = ControlRoomList.move("infra", by: -1, in: rows)
        #expect(up == "docs-site")
    }

    @Test func theSelectionStopsAtTheEnds() {
        let rows = list.rows
        let top = ControlRoomList.move("billing", by: -1, in: rows)
        #expect(top == "billing")
        let bottom = ControlRoomList.move("notes", by: 1, in: rows)
        #expect(bottom == "notes")
    }

    @Test func withNothingSelectedAStepLandsOnTheNearEnd() {
        let rows = list.rows
        let down = ControlRoomList.move(nil, by: 1, in: rows)
        #expect(down == "billing")
        let up = ControlRoomList.move(nil, by: -1, in: rows)
        #expect(up == "notes")
        let gone = ControlRoomList.move("no-such-group", by: 1, in: rows)
        #expect(gone == "billing")
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
        #expect(layout.rows["billing"] == CGRect(x: 6, y: 38, width: 296, height: 60))
        #expect(layout.rows["web-app"] == CGRect(x: 6, y: 106, width: 296, height: 60))
        #expect(layout.rows["mobile"] == CGRect(x: 6, y: 174, width: 296, height: 60))
        #expect(layout.rows["docs-site"] == CGRect(x: 6, y: 242, width: 296, height: 60))
    }

    @Test func theQuietSectionFollowsTheSeparator() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.separator == CGRect(x: 18, y: 318, width: 272, height: 0.5))
        #expect(layout.quietHeader == CGRect(x: 6, y: 322.5, width: 296, height: 32))
        #expect(layout.rows["infra"] == CGRect(x: 6, y: 354.5, width: 296, height: 28))
        #expect(layout.rows["design-system"] == CGRect(x: 6, y: 382.5, width: 296, height: 28))
    }

    @Test func theChipRestsExactlyOnItsRowAndNowhereForARowNotListed() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.chip(for: "billing") == layout.rows["billing"])
        #expect(layout.chip(for: "infra") == layout.rows["infra"])
        #expect(layout.chip(for: nil) == nil)
        #expect(layout.chip(for: "no-such-group") == nil)
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
