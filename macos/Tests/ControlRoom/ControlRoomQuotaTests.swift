import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// The allowance block: that it is a copy of what the core says, what its
/// words are made of, and where its parts are.
///
/// **What these are not.** Nothing here asks at what percentage an account
/// is opened out, when a number counts as old, or which account is a way
/// out. Those are the core's (`src/poltergeist/quota.zig` has the tests),
/// and two of the tests below are that this side has no opinion on them.
struct ControlRoomQuotaTests {
    typealias Look = ControlRoomLook
    typealias Quota = ControlRoomQuota
    typealias Sample = ControlRoomQuota.Sample

    let utc = TimeZone(identifier: "UTC") ?? .current
    let plain = Locale(identifier: "en_GB")

    // MARK: From the core's snapshot

    @Test func theCoresFixtureIsOneAccountOpenedOutAndOneInTheLine() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        let quota = try #require(list.quota)
        #expect(quota.alerts.count == 1)
        let alert = try #require(quota.alerts.first)
        #expect(alert.family == .claude)
        #expect(alert.level == .near)
        #expect(alert.span == .fiveHour)
        #expect(alert.used == 92)
        #expect(alert.when == Quota.When(form: .minutes, n: 40))
        #expect(alert.way_out == nil)
        #expect(alert.windows.count == 2)

        let line = try #require(quota.line)
        #expect(line.label == .used)
        let entries = line.entries.map(\.family)
        #expect(entries == [.codex])
        #expect(line.entries.first?.used == 20)
        #expect(line.entries.first?.state == .fresh)
    }

    @Test func aWordThisBuildDoesNotKnowIsNotRead() throws {
        // Not read as the nearest thing it does know: an account silently
        // drawn as an ordinary one would be the block failing at its job.
        let text = String(bytes: try ControlRoomListTests.fixture(), encoding: .utf8) ?? ""
        for (known, odd) in [("\"level\": \"near\"", "\"level\": \"nearly\""),
                             ("\"form\": \"minutes\"", "\"form\": \"fortnights\""),
                             ("\"state\": \"fresh\"", "\"state\": \"minty\""),
                             ("\"label\": \"used\"", "\"label\": \"spent\""),
                             ("\"family\": \"codex\"", "\"family\": \"abacus\"")] {
            let cut = text.replacingOccurrences(of: known, with: odd)
            #expect(cut != text, "the fixture no longer has \(known)")
            #expect(throws: DecodingError.self) {
                try ControlRoomList.decode(snapshot: Data(cut.utf8))
            }
        }
    }

    @Test func aSnapshotWithNoAllowanceInItDrawsNoBlock() throws {
        let text = String(bytes: try ControlRoomListTests.fixture(), encoding: .utf8) ?? ""
        let cut = text.replacingOccurrences(of: "\"quota\": {", with: "\"not_quota\": {")
        #expect(cut != text)
        let list = try ControlRoomList.decode(snapshot: Data(cut.utf8))
        #expect(list.quota == nil)
        let layout = ControlRoomListLayout(list: list, height: 824)
        let blockHeight = layout.quota.height
        #expect(blockHeight == 0)
    }

    // MARK: The host has no opinion

    @Test func whatIsOpenedOutIsWhatTheCoreListedWhateverTheNumbers() {
        // Ninety-five in the line stays in the line, and ten opened out is
        // opened out: the limit line is not a number this side has.
        var odd = Sample.near
        odd.alerts[0].used = 10
        odd.line?.entries[0].used = 95
        let layout = ControlRoomQuotaLayout(quota: odd)
        let parts = layout.parts.count
        #expect(parts == 1)
        #expect(layout.lineY != nil)
        #expect(Quota.entryNumber(odd.line?.entries[0] ?? Sample.entry(.codex, 0)) == "95%")
    }

    @Test func theWayOutIsWrittenOnlyWhenTheCoreNamesOne() {
        // Used up, and an account with room in the line beside it: still
        // nothing, because the core did not say so.
        var unnamed = Sample.outWithRoom
        unnamed.alerts[0].way_out = nil
        #expect(Quota.wayOutText(unnamed.alerts[0]) == nil)
        let noNote = ControlRoomQuotaLayout(quota: unnamed).parts[0].note
        #expect(!noNote)

        let named = Quota.wayOutText(Sample.outWithRoom.alerts[0]) ?? ""
        #expect(named.contains("Codex"))
        let note = ControlRoomQuotaLayout(quota: Sample.outWithRoom).parts[0].note
        #expect(note)
    }

    // MARK: What it says

    @Test func whenItComesBackIsSaidInTheFormTheCoreChose() {
        var alert = Sample.near.alerts[0]
        let minutes = Quota.whenText(alert, timeZone: utc, locale: plain)
        #expect(minutes.contains("40"))

        alert.when = Quota.When(form: .hours, n: 3)
        let hours = Quota.whenText(alert, timeZone: utc, locale: plain)
        #expect(hours.contains("3") && hours != minutes.replacingOccurrences(of: "40", with: "3"))

        // The moment itself: 13:40 on the clock it is asked to be read on.
        let clock = Quota.whenText(Sample.outWithRoom.alerts[0], timeZone: utc, locale: plain)
        #expect(clock.contains("13:40"))
        let tokyo = Quota.whenText(Sample.outWithRoom.alerts[0],
                                   timeZone: TimeZone(identifier: "Asia/Tokyo") ?? utc, locale: plain)
        #expect(tokyo.contains("22:40"))

        // With the day when the core asks for the day.
        alert.when = Quota.When(form: .date, n: 0)
        alert.resets_ms = Sample.now + 3 * Sample.day
        let date = Quota.whenText(alert, timeZone: utc, locale: plain)
        #expect(date.contains("17") && date.contains("12:00"))
    }

    @Test func anOldNumberSaysHowOldAndAWindowThatCameRoundSaysNoNumber() throws {
        let old = try #require(Sample.stale.line?.entries.last)
        let said = Quota.entryNumber(old)
        #expect(said.contains("20%") && said.contains("3"))

        let fresh = try #require(Sample.stale.line?.entries.first)
        #expect(Quota.entryNumber(fresh) == "61%")

        // Ninety-seven of a window that is over is not written anywhere on
        // the line.
        let back = try #require(Sample.recovered.line?.entries.last)
        let recovered = Quota.entryNumber(back)
        #expect(!recovered.contains("97") && !recovered.isEmpty)
        let help = Quota.help(for: back, timeZone: utc, locale: plain)
        #expect(!help.contains("97"))

        let unreadable = try #require(Sample.unreadable.line?.entries.last)
        let none = Quota.entryNumber(unreadable)
        #expect(!none.isEmpty && !none.contains("0"))
    }

    @Test func theTooltipHasEveryWindowAndWhenTheNumbersWereTaken() throws {
        let entry = try #require(Sample.ordinary.line?.entries.first)
        let help = Quota.help(for: entry, timeZone: utc, locale: plain)
        // Both windows, and 11:58, two minutes before the sample's noon.
        #expect(help.contains("61%") && help.contains("12%"))
        #expect(help.contains("11:58"))
        #expect(help.hasPrefix("Claude"))
    }

    @Test func theTitleNamesTheAccountTheWindowAndTheNumber() {
        let near = Quota.alertTitle(Sample.near.alerts[0])
        #expect(near.contains("Claude") && near.contains("92%"))
        let out = Quota.alertTitle(Sample.outWithRoom.alerts[0])
        #expect(out.contains("Claude") && !out.contains("100"))
        #expect(out != near)
    }

    // MARK: Where things are

    @Test func theBlockIsAsHighAsTheDesignDrewIt() {
        // v19, way three: 38.5 on an ordinary day, 88.5 with one account
        // close, 112.5 with one used up and a way out under it.
        let ordinary = ControlRoomQuotaLayout(quota: Sample.ordinary).height
        #expect(ordinary == 38.5)
        let near = ControlRoomQuotaLayout(quota: Sample.near).height
        #expect(near == 88.5)
        let out = ControlRoomQuotaLayout(quota: Sample.outWithRoom).height
        #expect(out == 112.5)
        let none = ControlRoomQuotaLayout(quota: Sample.noneYet).height
        #expect(none == 38.5)

        // Two opened out and no line: the hairline, two parts, the foot.
        let both = ControlRoomQuotaLayout(quota: Sample.outBothHigh)
        #expect(both.lineY == nil)
        let twoParts: CGFloat = 110.5
        #expect(both.height == twoParts)
        let tops: [CGFloat] = [4.5, 54.5]
        #expect(both.parts.map(\.y) == tops)
    }

    @Test func theBlockStandsOnTheBottomOfThePanelWhateverTheListHolds() {
        var list = ControlRoomList.sample
        list.quota = Sample.near
        let pad = CGFloat(Look.Space.sidePanelPadding)
        for height in [824.0, 600.0] {
            let layout = ControlRoomListLayout(list: list, height: CGFloat(height))
            #expect(layout.quota.maxY == CGFloat(height) - pad)
            #expect(layout.quota.height == 88.5)
            #expect(layout.quota.minX == pad)
            #expect(layout.quota.width == CGFloat(Look.Side.width) - 2 * pad)
        }
        // And the rows above are where they were without it.
        let without = ControlRoomListLayout(list: ControlRoomList.sample, height: 824)
        let with = ControlRoomListLayout(list: list, height: 824)
        #expect(with.rows == without.rows)
    }

    @Test func nothingIsSetSmallerThanTheSmallestSize() {
        #expect(Look.Font.body >= Look.Font.min)
        #expect(Look.Font.min >= 13)
    }
}
