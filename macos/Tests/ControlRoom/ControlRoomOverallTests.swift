import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// The left panel's bottom line (task 2149, handoff §6, the first of slice
/// 2's three blocks): that the core's answer is read, that the words are the
/// host's while the two verdicts are the core's, and where the row's parts
/// stand.
///
/// **What these are not.** Nothing here decides whether the swap is rising,
/// whether the disk is under its line, or how much of the history to draw:
/// those arrive as `swap_growth.rising`, `disk_low` and the points
/// themselves, and the core's own tests have them. The tests below are that
/// this side has no opinion on them -- one of them is exactly that a field
/// nothing draws is not read.
struct ControlRoomOverallTests {
    typealias U = ControlRoomOverall
    typealias Look = ControlRoomLook

    /// An answer of the shape `OverallPage.render` makes, with the design's
    /// own numbers (`02-overall-leak`, the user's machine): 22.4 GB of
    /// Polter, 18.6 GB of swap, 9.1 GB of disk left.
    ///
    /// `edit` replaces one `"key":value` of the `machine` block; `"null"` is
    /// how a number the machine would not give arrives. The two blocks are
    /// written whole, so that a caller can take one entry out by name.
    static func fixture(edit: [String: String] = [:]) -> Data {
        var machine: [String: String] = [
            "swap_used_mib": "19046",
            "swap_total_mib": "24576",
            "disk_free_mib": "9320",
            "disk_low": "true",
            "disk_low_line_mib": "15360",
            "swap_growth": "{\"rising\":true,\"slope_mib_per_h\":1331,\"rose_mib\":20070,\"since_s\":57600,\"since\":null}",
            "swap_hour": "[[1700000000,1024],[1700000060,2048],[1700000120,4096]]",
        ]
        machine.merge(edit) { _, new in new }
        let polter = "{\"cpu_cores\":\"2.6\",\"total_mib\":22938}"
        let written = machine.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return Data("{\"at\":\"2026-10-25T16:10:00+08:00\",\"machine\":{\(written)},\"polter\":\(polter)}".utf8)
    }

    /// The core's own refusal, which is never an empty page.
    static func refused(_ why: String) -> Data { Data("{\"error\":\"\(why)\"}".utf8) }

    // MARK: From the core

    @Test func theAnswersNumbersAreReadWhole() throws {
        let a = try U.decode(Self.fixture())
        #expect(same(a.totalMib, 22938))
        #expect(a.cpuCores == "2.6")
        #expect(a.machine.swapUsedMib == 19046)
        #expect(a.machine.swapTotalMib == 24576)
        #expect(a.machine.diskFreeMib == 9320)
        #expect(a.machine.swapRising)
        #expect(a.machine.diskLow)
        #expect(a.machine.swapHour.map(\.0) == [1700000000, 1700000060, 1700000120])
        #expect(a.machine.swapHour.map(\.1) == [1024, 2048, 4096])
    }

    /// A refusal is the core's own words, and never an empty page: the row
    /// says nothing rather than drawing a machine that costs nothing.
    @Test func aRefusalIsNotAnEmptyAnswer() throws {
        let refused = try #require(throws: U.DecodeError.self) { try U.decode(Self.refused("NoSuchGroup")) }
        #expect(refused == .refused("NoSuchGroup"))
    }

    @Test func somethingThatIsNotAnAnswerIsNotOne() throws {
        #expect(throws: U.DecodeError.self) { try U.decode(Data("not json".utf8)) }
        #expect(throws: U.DecodeError.self) { try U.decode(Data("{\"machine\":{}}".utf8)) }
    }

    /// **A machine that was not read costs what it is drawn as, and not the
    /// row.** The size and the name are still there; the second line is
    /// empty, and there is nothing for the ink to colour.
    @Test func aMachineThatWasNotReadCostsOnlyItsOwnNumbers() throws {
        let a = try U.decode(Data("{\"polter\":{\"cpu_cores\":\"2.6\",\"total_mib\":22938}}".utf8))
        #expect(a.totalMib == 22938)
        #expect(a.machine.swapUsedMib == nil)
        #expect(a.machine.diskFreeMib == nil)
        #expect(a.machine.swapHour.isEmpty)
        // Not rising and not low, because nothing said so -- and the two
        // flags are what the ink follows, not the missing numbers.
        #expect(!a.machine.swapRising)
        #expect(!a.machine.diskLow)
        let e = U.entry(a)
        #expect(e.size == "22.4 GB")
        #expect(e.machine.isEmpty)
        #expect(!e.saysDisk)
        #expect(!e.rising)
    }

    /// **The step between the points is not read.** The core's
    /// `hour_step_s` belongs to `polter.series`, the layer chart; this row
    /// draws the last 24 hours on the points' own axis. A field read and
    /// never drawn is a field that is wrong quietly, so it is not read --
    /// and an answer without it is a whole answer.
    @Test func theStepBetweenThePointsIsNotRead() throws {
        let a = try U.decode(Self.fixture())
        #expect(a.machine.swapHour.count == 3)
        // `hour_step_s` where the core puts it, in `polter.series`: an
        // answer carrying it is read to the same row as one without it.
        let withStep = Data("""
            {"machine":{"swap_hour":[[1700000000,1024],[1700000060,2048],[1700000120,4096]]},
             "polter":{"cpu_cores":"2.6","total_mib":22938,
                       "series":{"hour_step_s":300,"week_step_s":1800,"hour":[],"week":[]}}}
            """.utf8)
        let b = try U.decode(withStep)
        // A tuple array is not `Equatable`; the two columns are.
        #expect(b.machine.swapHour.map(\.0) == a.machine.swapHour.map(\.0))
        #expect(b.machine.swapHour.map(\.1) == a.machine.swapHour.map(\.1))
    }

    /// A number the machine would not give arrives as null, and is nil
    /// rather than zero: a swap of 0 MiB and a swap nobody could read are
    /// not the same thing.
    @Test func aNumberThatWasNotGivenIsNilAndNotZero() throws {
        let a = try U.decode(Self.fixture(edit: ["swap_used_mib": "null", "disk_free_mib": "null"]))
        #expect(a.machine.swapUsedMib == nil)
        #expect(a.machine.diskFreeMib == nil)
    }

    // MARK: The row's words

    @Test func theRowSaysTheSizeAndTheMachinesTwoNumbers() throws {
        let e = U.entry(try U.decode(Self.fixture()))
        #expect(e.app == "Polter")
        #expect(e.size == "22.4 GB")
        #expect(e.rising)
        #expect(e.diskLow)
        #expect(e.saysDisk)
        // The core's sentence in the person's language. Not asserted word
        // for word -- that is the strings table's
        // (`the-mac-strings-still-have-a-chinese-half`).
        #expect(e.machine.contains("18.6 GB"))
        #expect(e.machine.contains("9.1 GB"))
    }

    /// The disk part is in the line exactly when there is a disk number, so
    /// that the words and the ink cannot disagree.
    @Test func theDiskIsInTheLineOnlyWhenItWasRead() throws {
        let e = U.entry(try U.decode(Self.fixture(edit: ["disk_free_mib": "null"])))
        #expect(!e.saysDisk)
        #expect(!e.machine.contains("9.1 GB"))
        #expect(e.machine.contains("18.6 GB"))
        // Still low: that is the core's flag about the disk, not about
        // whether this row could read the number.
        #expect(e.diskLow)

        let s = U.entry(try U.decode(Self.fixture(edit: ["swap_used_mib": "null"])))
        #expect(s.saysDisk)
        #expect(s.machine.contains("9.1 GB"))
        #expect(!s.machine.contains("18.6 GB"))
    }

    @Test func aSizeIsGBAboveOneAndWholeMBBelow() {
        #expect(U.size(1023) == "1023 MB")
        #expect(U.size(1024) == "1.0 GB")
        #expect(U.size(22938) == "22.4 GB")
        #expect(U.size(19046) == "18.6 GB")
        #expect(U.size(9320) == "9.1 GB")
        #expect(U.size(0) == "0 MB")
    }

    // MARK: Where the parts go

    /// The row is exactly as wide as the list's own rows and starts at the
    /// same left edge. `handoff §6` asks for that alignment as a reading.
    @Test func theRowStandsWhereTheRowsAboveItDo() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        let layout = ControlRoomListLayout(list: list, height: 900, overallLineHeight: ControlRoomOverall.EntryLayout.height + CGFloat(Look.OverallEntry.marginBottom))
        #expect(layout.overallEntry.minX == CGFloat(Look.Space.sidePanelPadding))
        #expect(layout.overallEntry.width == CGFloat(Look.Side.width) - 2 * CGFloat(Look.Space.sidePanelPadding))
        let rows = list.rows.filter { layout.rows[$0.id] != nil }
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(layout.rows[row.id]?.minX == layout.overallEntry.minX)
            #expect(layout.rows[row.id]?.width == layout.overallEntry.width)
        }
    }

    /// **The panel that has no such line moves nothing**: the rows run down
    /// to the allowance block as they did, which is what the Windows host
    /// draws today and what `control-room-hosts-agree` holds the two to.
    @Test func withoutTheLineTheRowsRunToTheAllowanceBlockAsBefore() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        let off = ControlRoomListLayout(list: list, height: 900)
        let on = ControlRoomListLayout(list: list, height: 900, overallLineHeight: ControlRoomOverall.EntryLayout.height + CGFloat(Look.OverallEntry.marginBottom))
        #expect(off.overallEntry.height == 0)
        #expect(on.overallEntry.height == ControlRoomOverall.EntryLayout.height
            + CGFloat(Look.OverallEntry.marginBottom))
        // The rows themselves are laid out identically; only what is below
        // them moved.
        #expect(off.rows.mapValues(\.minY) == on.rows.mapValues(\.minY))
        #expect(off.quota == on.quota)
        // And the viewport loses exactly the line's height.
        #expect(off.viewport.height - on.viewport.height == on.overallEntry.height)
    }

    /// The chip is the width the layout left, and its own two lines and the
    /// curve are inside it: the curve at the right, wholly inside, the words
    /// never under it.
    @Test func theCurveIsTheRightmostThingAndTheWordsStopShortOfIt() {
        let width = CGFloat(Look.Side.width) - 2 * CGFloat(Look.Space.sidePanelPadding)
        let at = U.entryLayout(width: width)
        let e = Look.OverallEntry.self
        #expect(at.chip.width == width)
        #expect(at.chip.minX == 0)
        #expect(at.curve.maxX == width - CGFloat(e.paddingRight))
        #expect(at.curve.width == CGFloat(e.curveWidth))
        #expect(at.curve.height == CGFloat(e.curveHeight))
        #expect(at.curve.minY >= at.chip.minY)
        #expect(at.curve.maxY <= at.chip.maxY)
        // The first line starts where the chip's own padding puts it, and
        // both lines stop `gap` short of the curve.
        #expect(at.line1.minX == CGFloat(e.paddingX))
        #expect(at.line2.minX == at.line1.minX)
        #expect(at.line1.maxX == at.curve.minX - CGFloat(e.gap))
        #expect(at.line2.maxX == at.line1.maxX)
        // One above the other, both inside the chip.
        #expect(at.line2.minY == at.line1.maxY + CGFloat(e.lineGap))
        #expect(at.line1.minY >= at.chip.minY)
        #expect(at.line2.maxY <= at.chip.maxY)
        // And the rail against the chip's left edge, inset above and below.
        #expect(at.rail.minX == at.chip.minX + CGFloat(e.railLeft))
        #expect(at.rail.minY == at.chip.minY + CGFloat(e.railInset))
        #expect(at.rail.height == at.chip.height - 2 * CGFloat(e.railInset))
    }

    /// A narrow panel is not a negative width: the words get what is left
    /// and nothing goes outside the chip.
    @Test func aNarrowPanelLeavesTheCurveToTheRightAndTheWordsWhatIsLeft() {
        let at = U.entryLayout(width: 120)
        #expect(at.chip.width == 120)
        #expect(at.line1.width >= 0)
        #expect(at.line1.maxX <= at.curve.minX)
        #expect(at.curve.maxX <= at.chip.maxX)
    }

    /// **No text smaller than the system's menu face** (the user's rule,
    /// 2026-10-18): every size this row is set in is `Look.Font.min` or
    /// above, and the two lines are the design's line-height.
    @Test func nothingHereIsSmallerThanTheMenuFace() {
        #expect(Look.Font.body >= Look.Font.min)
        #expect(Look.OverallEntry.lineHeight >= Look.Font.min)
        #expect(U.EntryLayout.height == CGFloat(Look.OverallEntry.height))
    }

    // MARK: The little curve

    @Test func theCurveIsThePointsItWasGivenAndNothingWithoutTwo() {
        let rect = CGRect(x: 0, y: 0, width: 56, height: 20)
        let three = U.Machine(swapUsedMib: nil, swapTotalMib: nil, diskFreeMib: nil,
                              swapRising: false, swapSlopeMibPerHour: 0, diskLow: false,
                              swapHour: [(1_700_000_000, 1024), (1_700_000_600, 2048), (1_700_001_200, 4096)], diskHour: [])
        let drawn = U.curve(three, nowS: 0, rect: rect)
        #expect(drawn.line.count == 3)
        #expect(drawn.killY == nil)
        // Inside the box, edges included: a point *on* the right edge is on
        // it, and `CGRect.contains` says no to that one.
        #expect(drawn.line.allSatisfy { $0.x >= rect.minX && $0.x <= rect.maxX })
        #expect(drawn.line.allSatisfy { $0.y >= rect.minY && $0.y <= rect.maxY })
        // Rising values are higher up the box: the y axis is the other way.
        #expect(drawn.line[0].y > drawn.line[1].y)
        #expect(drawn.line[1].y > drawn.line[2].y)

        let one = U.Machine(swapUsedMib: nil, swapTotalMib: nil, diskFreeMib: nil,
                            swapRising: false, swapSlopeMibPerHour: 0, diskLow: false, swapHour: [(1_700_000_000, 1024)], diskHour: [])
        #expect(U.curve(one, nowS: 0, rect: rect).line.isEmpty)
        let none = U.Machine(swapUsedMib: nil, swapTotalMib: nil, diskFreeMib: nil,
                             swapRising: false, swapSlopeMibPerHour: 0, diskLow: false, swapHour: [], diskHour: [])
        #expect(U.curve(none, nowS: 0, rect: rect).line.isEmpty)
    }

    /// The span is the last 24 hours before the newest point: two points a
    /// day apart are the left and right edges of the box, and a third one
    /// older than that is not drawn at all (`ControlRoomResources.curve`).
    @Test func theCurveIsTheLastTwentyFourHoursOfThePoints() {
        let rect = CGRect(x: 0, y: 0, width: 56, height: 20)
        let hour: UInt64 = 3_600
        let t: UInt64 = 1_700_000_000
        let two = U.Machine(swapUsedMib: nil, swapTotalMib: nil, diskFreeMib: nil,
                            swapRising: false, swapSlopeMibPerHour: 0, diskLow: false, swapHour: [(t, 100), (t + 24 * hour, 200)], diskHour: [])
        let drawn = U.curve(two, nowS: 0, rect: rect)
        #expect(drawn.line.count == 2)
        #expect(drawn.line.first?.x == rect.minX)
        #expect(drawn.line.last?.x == rect.maxX)

        let three = U.Machine(swapUsedMib: nil, swapTotalMib: nil, diskFreeMib: nil,
                              swapRising: false, swapSlopeMibPerHour: 0, diskLow: false,
                              swapHour: [(t - hour, 50), (t, 100), (t + 24 * hour, 200)], diskHour: [])
        #expect(U.curve(three, nowS: 0, rect: rect).line.count == 2)
    }

    /// **The right-hand edge is the core's `now_s`** (task 2149, slice 2, the
    /// reviewer's suggestion): the row's little curve and the overall view's
    /// chart and two curves then end at one clock, instead of each ending at
    /// its own newest point and the three being up to a sampling interval
    /// apart. Zero -- an answer with no `series` -- falls back to the newest
    /// point, which is the same curve read without it.
    @Test func theLittleCurveEndsWhereTheCoresOwnClockSays() {
        let rect = CGRect(x: 0, y: 0, width: 56, height: 20)
        let hour: UInt64 = 3_600
        let t: UInt64 = 1_700_000_000
        // A point an hour old, and the core's clock an hour past it: with
        // `now_s` the point stands three quarters of a day from the right
        // edge, and without it, it is the right edge itself.
        let m = U.Machine(swapUsedMib: nil, swapTotalMib: nil, diskFreeMib: nil,
                          swapRising: false, swapSlopeMibPerHour: 0, diskLow: false,
                          swapHour: [(t - hour, 100), (t, 200)], diskHour: [])
        let byCore = U.curve(m, nowS: t + hour, rect: rect)
        #expect(byCore.line.count == 2)
        #expect(byCore.line.last!.x < rect.maxX)
        expectClose(byCore.line.last!.x - rect.minX, 23.0 / 24.0 * rect.width)
        let byPoint = U.curve(m, nowS: 0, rect: rect)
        #expect(byPoint.line.last!.x == rect.maxX)
        // Both drew the same two points: only the edge they are read against
        // moved.
        #expect(byCore.line.map(\.y) == byPoint.line.map(\.y))
    }

    // MARK: The group page's strip (handoff §6, the second of slice 2's
    // three blocks)

    /// The answer the group page's strip draws, of the shape `groupsOf`
    /// makes: the design's own numbers (`01-group-perf`, the normal state),
    /// a supervisor's tree of 1.1 GB, its workers' 29.0 GB, the person's own
    /// 0.4 GB and the group's embedded chat of 0.3 GB -- and the four add up
    /// to the `total_mib` beside them, as the core's one walk makes them.
    static func groupFixture(rising: Bool = false, tasks: Int = 128, open: Int = 23,
                             recordBytes: Int = 4_404_019) -> String {
        let growth = rising
            ? "{\"rising\":true,\"slope_mib_per_h\":1331,\"rose_mib\":20070,\"since_s\":57600,\"since\":\"2026-10-25T16:10:00+08:00\"}"
            : "{\"rising\":false,\"slope_mib_per_h\":4,\"rose_mib\":9,\"since_s\":null,\"since\":null}"
        return """
            {"group":"web-app","total_mib":31500,
             "parts":{"supervisor_mib":1126,"workers_mib":29700,"yours_mib":410,"own_mib":264},
             "own":{"chat_pid":1904,"chat_mib":264,"growth":\(growth),
                    "tasks":\(tasks),"tasks_open":\(open),"record_bytes":\(recordBytes)}}
            """
    }

    /// The whole answer: the two numbers the row above the strip draws, and
    /// one group.
    static func answer(withGroup group: String) -> Data {
        Data("{\"at\":\"2026-10-25T16:10:00+08:00\",\"groups\":[\(group)],\"machine\":{},\"polter\":{\"cpu_cores\":\"2.6\",\"total_mib\":22938}}".utf8)
    }

    /// The core's fields are read whole, and the four parts are the four the
    /// bar and the legend are drawn from -- not one number the host splits.
    @Test func theGroupsOwnFactsAreReadWhole() throws {
        let a = try U.decode(Self.answer(withGroup: Self.groupFixture()))
        #expect(a.groups.count == 1)
        let g = try #require(a.groups.first)
        #expect(g.group == "web-app")
        #expect(same(g.totalMib, 31500))
        #expect(same(g.parts.supervisorMib, 1126))
        #expect(same(g.parts.workersMib, 29700))
        #expect(same(g.parts.yoursMib, 410))
        #expect(same(g.parts.ownMib, 264))
        #expect(same(g.parts.sumMib, 31500))
        #expect(g.own.chatPid == 1904)
        #expect(same(g.own.chatMib, 264))
        #expect(!g.own.rising)
        #expect(g.own.slopeMibPerHour == 4)
        #expect(g.own.since == nil)
        #expect(same(g.own.tasks, 128))
        #expect(same(g.own.tasksOpen, 23))
        #expect(same(g.own.recordBytes, 4_404_019))
    }

    /// An answer with no `groups` at all is an answer with none in it: the
    /// strip is simply not drawn, which is what the group page draws for a
    /// group nobody has. **Not a row of zeroes**, which would be a group
    /// that costs nothing.
    @Test func anAnswerWithNoGroupsHasNoneInIt() throws {
        let a = try U.decode(Self.fixture())
        #expect(a.groups.isEmpty)
    }

    /// **The four widths are the four parts' shares of the sum**, to within
    /// a point, and the four fill the bar exactly (`handoff §6`: that is one
    /// of the two things to measure).
    @Test func theFourWidthsAreTheirPartsSharesOfTheBar() throws {
        let g = try #require(try U.decode(Self.answer(withGroup: Self.groupFixture())).groups.first)
        let width: CGFloat = 700
        let bar = U.groupBar(g.parts, width: width)
        #expect(bar.count == 4)
        // Left to right, in the order the legend names them, abutting.
        #expect(bar[0].minX == 0)
        for i in 1..<4 { #expect(bar[i].minX == bar[i - 1].maxX) }
        #expect(bar[3].maxX == width)
        let total = Double(g.parts.sumMib)
        let want = [1126.0, 29700.0, 410.0, 264.0].map { Double(width) * $0 / total }
        for (r, w) in zip(bar, want) {
            #expect(abs(Double(r.width) - w) < 1, "\(r.width) against \(w)")
        }
        // And the shares are the same numbers without a width.
        #expect(same(U.groupBarShares(g.parts).map { ($0 * 10000).rounded() },
                    [357, 9429, 130, 84]))
    }

    /// **A group that costs nothing is four empty rectangles**, not a full
    /// bar: with no sum to divide, every share is zero, and the two are
    /// otherwise the same arithmetic.
    @Test func aGroupThatCostsNothingIsFourEmptyRectangles() throws {
        let bar = U.groupBar(.none, width: 700)
        #expect(bar.count == 4)
        #expect(bar.allSatisfy { $0.width == 0 && $0.height == 0 })
        #expect(U.groupBarShares(.none) == [0, 0, 0, 0])
        // A bar with no width likewise, and not a negative one.
        let zero = U.groupBar(try #require(try U.decode(Self.answer(withGroup: Self.groupFixture())).groups.first).parts,
                             width: 0)
        #expect(zero.allSatisfy { $0.width == 0 })
    }

    /// **The card is in the warning ink while the core says the group's own
    /// part is rising, and not otherwise** (`01-group-perf` against
    /// `01b-group-chat-growing`). The verdict is `growth.rising`, read as
    /// `own.rising`; nothing here weighs a slope.
    @Test func theCardTurnsWarnOnlyWhileTheCoreSaysItIsRising() throws {
        let still = try #require(try U.decode(Self.answer(withGroup: Self.groupFixture())).groups.first)
        #expect(U.ownCardTone(still.own) == U.Tone.normal)
        let growing = try #require(try U.decode(Self.answer(withGroup: Self.groupFixture(rising: true))).groups.first)
        #expect(growing.own.rising)
        #expect(U.ownCardTone(growing.own) == U.Tone.warn)
        #expect(growing.own.since == "2026-10-25T16:10:00+08:00")
        // The bar's own fourth share is the same reading, not a second one:
        // the segment that is orange is `own_mib`'s, and it is the same
        // `rising`.
        #expect(growing.parts.ownMib == still.parts.ownMib)
    }

    /// A group's own block that was not read costs its own numbers and not
    /// the strip: the sum of what there is is what the bar is drawn to.
    @Test func aGroupsOwnBlockThatWasNotReadLeavesTheBarWhole() throws {
        let bare = """
            {"group":"web-app","total_mib":1126,
             "parts":{"supervisor_mib":1126,"workers_mib":0,"yours_mib":0,"own_mib":0}}
            """
        let g = try #require(try U.decode(Self.answer(withGroup: bare)).groups.first)
        #expect(same(g.own.tasks, 0))
        #expect(!g.own.rising)
        let bar = U.groupBar(g.parts, width: 200)
        #expect(bar[0].width == 200)
        #expect(bar[1].width == 0)
        #expect(bar[3].maxX == 200)
    }

    /// **No text smaller than the system's menu face**, the strip included:
    /// its legends are the body size, which is `Look.Font.min`.
    @Test func nothingOnTheStripIsSmallerThanTheMenuFace() {
        #expect(Look.Font.body >= Look.Font.min)
        #expect(Look.Font.min >= 13)
    }

    /// The performance page's own fake answer (`windows/control-room/testdata`,
    /// the same file `ControlRoomPerfTests` reads), for the two tests about
    /// where the strip stands. Read whole: those tests are about the page's
    /// layout and not about any number in it.
    static func performanceDay() throws -> ControlRoomResources.Answer {
        let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("windows/control-room/testdata")
        return try ControlRoomResources.decode(Data(contentsOf: dir.appendingPathComponent("resources-day.json")))
    }

    /// **Without a strip the performance page is exactly what it was**: no
    /// rect, and every card where it stood. That is what the Windows host
    /// draws today, and `ControlRoomPerfTests`' own numbers are written
    /// against it.
    @Test func withoutTheStripThePageIsWhatItWas() throws {
        let a = try Self.performanceDay()
        let off = ControlRoomPerfLayout(a, width: 1040)
        #expect(off.strip == nil)
        // The line over the cards is where it always was, and so are they.
        #expect(off.cardsHead.minY == off.summary.maxY + 12)
        #expect(off.contentHeight == off.cards[7].maxY + 12)
    }

    /// **With the strip the cards move down by the strip and its own two
    /// gaps**, and the strip stands between the box above and the line over
    /// the cards -- over nothing.
    @Test func theStripStandsBetweenTheBoxAndTheLineOverTheCards() throws {
        let a = try Self.performanceDay()
        let h = U.groupStripHeight
        #expect(h > 0)
        let on = ControlRoomPerfLayout(a, width: 1040, stripHeight: h)
        let off = ControlRoomPerfLayout(a, width: 1040)
        let strip = try #require(on.strip)
        #expect(strip.minX == off.summary.minX)
        #expect(strip.width == off.summary.width)
        #expect(strip.height == h)
        #expect(strip.minY == off.summary.maxY + CGFloat(Look.GroupStrip.top))
        #expect(on.cardsHead.minY == strip.maxY + CGFloat(Look.GroupStrip.bottom))
        let moved = CGFloat(Look.GroupStrip.top) + h + CGFloat(Look.GroupStrip.bottom)
            - CGFloat(Look.PerfPage.cardsTitleTop)
        #expect(on.cards[0].minY - off.cards[0].minY == moved)
        #expect(on.contentHeight == off.contentHeight + moved)
        // The box above and the grid inside it do not move: only what is
        // under the grid does.
        #expect(on.summary == off.summary)
        #expect(on.cardsHead.width == off.cardsHead.width)
    }

    /// The height is the look's own numbers and **nothing measured**: the
    /// taller of the bar's box and the card, each built up from its parts.
    /// A word getting longer must not move the cards under the row.
    @Test func theStripIsAsTallAsTheLookSaysAndNotAsWhatItMeasures() {
        let g = Look.GroupStrip.self
        let left = CGFloat(g.padY + g.headHeight + g.barTop + g.barHeight + g.legendTop)
            + U.groupStripLegendHeight + CGFloat(g.padY)
        let card = CGFloat(g.padY) + max(CGFloat(g.headHeight), CGFloat(g.tagHeight))
            + CGFloat(g.cardLineGap + g.cardValueHeight + g.cardFootGap + g.legendRow + g.cardFootGap + g.legendRow)
            + CGFloat(g.padY)
        #expect(U.groupStripHeight == max(left, card))
        #expect(U.groupStripLegendHeight
            == 2 * CGFloat(g.legendRow) + CGFloat(g.legendGapY))
        #expect(U.groupStripHeight >= 60)
    }

    /// The three numbers the card writes: a size from the one place that
    /// writes one, a record's own size, and a rate with the core's sign.
    @Test func theCardsNumbersAreWrittenTheOneWay() {
        #expect(U.size(31500) == "30.8 GB")
        #expect(U.record(4_404_019) == "4.2 MB")
        #expect(U.record(1_073_741_824) == "1.0 GB")
        #expect(U.record(40_960) == "40.0 KB")
        #expect(U.rate(1331) == "+1.3 GB")
        #expect(U.rate(4) == "+4 MB")
        #expect(U.rate(-9) == "\u{2212}9 MB")
    }

    /// The request names the group, quoted as every other page's does: a
    /// group whose name has a quote in it is not a broken request.
    @Test func theStripAsksForTheGroupItIsShowing() {
        #expect(U.groupRequest(group: "web-app") == "{\"page\":\"overall\",\"group\":\"web-app\"}")
        #expect(U.groupRequest(group: "web\"app") == "{\"page\":\"overall\",\"group\":\"web\\\"app\"}")
    }

    /// The strip draws the group it was asked about and no other: an answer
    /// about a group nobody asked for (a selection that moved between
    /// asking and now) leaves the page with no strip.
    @Test func theStripIsAboutTheGroupThePageIsShowing() throws {
        let a = try U.decode(Self.answer(withGroup: Self.groupFixture()))
        #expect(U.group(a, named: "web-app") != nil)
        #expect(U.group(a, named: "billing") == nil)
    }

    // MARK: The overall view's chart (handoff §6, the third of slice 2's
    // three blocks)

    /// An answer carrying the three stacked layers, in the core's own order
    /// (`main`, `chats`, `sidecars`), and the moment the chart's right edge
    /// is. **The numbers are small on purpose**: the sums the tests assert
    /// below are read by eye against the layer beside them.
    static func seriesFixture(nowS: Int = 7200) -> Data {
        Data("""
            {"at":"2026-10-25T16:10:00+08:00",
             "polter":{"cpu_cores":"2.6","total_mib":22938,
                       "run_started":"2026-10-25T14:10:00+08:00",
                       "series":{
                         "hour":[{"category":"main","cells":[10,20,30]},
                                 {"category":"chats","cells":[1,2,3]},
                                 {"category":"sidecars","cells":[100,200,300]}],
                         "week":[{"category":"main","cells":[7,8]},
                                 {"category":"chats","cells":[9,10]},
                                 {"category":"sidecars","cells":[11,12]}],
                         "hour_step_s":300,"week_step_s":1800,"now_s":\(nowS)}}}
            """.utf8)
    }

    /// One layer, for the arithmetic: what `stack` is handed, with no JSON
    /// and no decoding in the way.
    static func layer(_ name: String, _ cells: [UInt64]) -> U.Layer {
        U.Layer(name: name, cells: cells)
    }

    /// **The three layers added up, cell by cell, in the core's order**: the
    /// second layer's top edge is the first's plus its own, the third's is
    /// both. The order out is the order in -- nothing here sorts the layers
    /// or works out which is which.
    @Test func theThreeLayersAreAddedUpCellByCell() throws {
        let a = try U.decode(Self.seriesFixture())
        #expect(a.polter.series.hour.count == 3)
        let s = U.stack(a.polter.series.hour)
        #expect(s.cells == 3)
        #expect(s.tops.count == 3)
        // The first layer is itself, cell for cell.
        #expect(s.top(0) == [10, 20, 30])
        // The second is the first plus its own.
        #expect(s.top(1) == [11, 22, 33])
        // The third is both, and its last cell is the highest anywhere.
        #expect(s.top(2) == [111, 222, 333])
        #expect(same(s.maxMib, 333))
        // Each layer's base is the one below it, and the bottom's is
        // nothing: they are stacked and not laid side by side.
        #expect(same(s.base(0, 0), 0))
        #expect(same(s.base(1, 2), 30))
        #expect(same(s.base(2, 2), 33))
    }

    /// **A layer that came short is zero where it has nothing**, not a
    /// narrower chart: the box is the longest layer's width, and the two
    /// would otherwise be different windows.
    @Test func aLayerThatCameShortIsZeroWhereItHasNothing() {
        let s = U.stack([Self.layer("main", [5, 5]),
                         Self.layer("chats", [1, 2, 3, 4]),
                         Self.layer("sidecars", [9])])
        #expect(s.cells == 4)
        #expect(s.top(0) == [5, 5, 0, 0])
        #expect(s.top(1) == [6, 7, 3, 4])
        #expect(s.top(2) == [15, 7, 3, 4])
        #expect(same(s.maxMib, 15))
    }

    /// **Nothing to draw is a flat chart on its floor**, not a division by
    /// nothing: no layers at all, or a layer with no cells.
    @Test func nothingToDrawIsFlatOnTheFloor() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        #expect(U.stack([]) == U.Stack.none)
        #expect(U.stack([Self.layer("main", [])]) == U.Stack.none)
        #expect(U.Stack.none.top(0) == [])
        #expect(U.Stack.none.base(1, 0) == 0)
        // A value with no scale is on the floor, and so is zero.
        #expect(U.stackY(0, of: 0, in: rect) == rect.maxY)
        #expect(U.stackY(100, of: 0, in: rect) == rect.maxY)
        #expect(U.stackY(0, of: 100, in: rect) == rect.maxY)
        // The tallest is on the top edge, and half the scale is halfway.
        #expect(U.stackY(100, of: 100, in: rect) == rect.minY)
        #expect(U.stackY(50, of: 100, in: rect) == rect.midY)
        // A reading above the scale is not drawn outside the box.
        #expect(U.stackY(200, of: 100, in: rect) == rect.minY)
    }

    /// One cell's band: the cells divide the width evenly, the first at the
    /// left edge and the last ending at the right one, so the chart has no
    /// gap at either end. **The cells are the core's**: this only places
    /// them.
    @Test func theCellsDivideTheWidthEvenly() {
        let rect = CGRect(x: 10, y: 0, width: 300, height: 100)
        let bands = (0..<3).map { U.cellBand($0, of: 3, in: rect) }
        #expect(bands[0].minX == rect.minX)
        expectClose(bands[0].width, 100)
        for i in 1..<3 { expectClose(bands[i].minX, bands[i - 1].maxX) }
        expectClose(bands[2].maxX, rect.maxX)
        for b in bands {
            #expect(b.minY == rect.minY)
            #expect(b.height == rect.height)
        }
        // No cells, or a cell that is not there: an empty band at the left
        // edge, and never a negative width.
        #expect(U.cellBand(0, of: 0, in: rect).width == 0)
        #expect(U.cellBand(5, of: 3, in: rect).width == 0)
        #expect(U.cellBand(-1, of: 3, in: rect).width == 0)
    }

    /// **Where the rise mark stands** (handoff §6's vertical dashed line):
    /// the chart's right edge is the core's `now_s` and the mark is
    /// `since_s`, on that same clock -- so the mark stands `now - since`
    /// seconds back from the right edge whatever the answer's own `at` says.
    @Test func theRiseMarkStandsWhereTheCoreSays() throws {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        let now: UInt64 = 100_000
        // 288 cells of five minutes is the 24-hour span; a rise that began
        // six hours ago stands three quarters of the way across.
        let six = UInt64(6 * 3600)
        let f = try #require(U.riseMarkFraction(sinceS: now - six, nowS: now, stepS: 300, cells: 288))
        expectClose(f, 0.75)
        let x = try #require(U.riseMarkX(sinceS: now - six, nowS: now, stepS: 300, cells: 288, in: rect))
        expectClose(x, rect.minX + 0.75 * rect.width)
        // A rise that began just now is at the right edge, and one as old as
        // the whole window is at the left edge.
        #expect(U.riseMarkFraction(sinceS: now, nowS: now, stepS: 300, cells: 288) == 1)
        #expect(U.riseMarkFraction(sinceS: now - 288 * 300, nowS: now, stepS: 300, cells: 288) == 0)
        // The box is the span's own: the same rise over the week's 336 half
        // hours is a different place, and neither is the host's to work out.
        let weekF = try #require(U.riseMarkFraction(sinceS: now - six, nowS: now, stepS: 1800, cells: 336))
        expectClose(weekF, 1 - 6.0 * 3600 / (336 * 1800))
    }

    /// **A mark that cannot be placed is not drawn**, and every one of these
    /// is a real case rather than a zero: nothing rising (a null `since_s`,
    /// which arrives as no mark at all), a rise older than the box (the
    /// 7-day view of one that began an hour ago), an answer with no cells or
    /// no step, a clock that disagrees with itself.
    @Test func aRiseOlderThanTheBoxIsNotDrawn() {
        let day = UInt64(288 * 300)
        #expect(U.riseMarkFraction(sinceS: 0, nowS: day + 1, stepS: 300, cells: 288) == nil)
        #expect(U.riseMarkFraction(sinceS: 500, nowS: 400, stepS: 300, cells: 288) == nil)
        #expect(U.riseMarkFraction(sinceS: 0, nowS: 100, stepS: 300, cells: 0) == nil)
        #expect(U.riseMarkFraction(sinceS: 0, nowS: 100, stepS: 0, cells: 288) == nil)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        #expect(U.riseMarkX(sinceS: 0, nowS: day + 1, stepS: 300, cells: 288, in: rect) == nil)
    }

    /// **The core's `now_s` is what the mark is placed from, and the
    /// answer's own `at` is not read for it.** An answer without `now_s`
    /// reads as none, and then no mark is placed: the moment is never
    /// guessed from the answer's clock.
    @Test func theRiseMarkIsPlacedFromTheCoresOwnClock() throws {
        let a = try U.decode(Self.seriesFixture(nowS: 7200))
        #expect(same(a.polter.series.nowS, 7200))
        // Three cells of five minutes, a rise that began one cell ago:
        // two thirds of the way across.
        let f = try #require(U.riseMarkFraction(sinceS: a.polter.series.nowS - 300,
                                               nowS: a.polter.series.nowS,
                                               stepS: a.polter.series.hourStepS,
                                               cells: 3))
        expectClose(f, 2.0 / 3.0)
        let bare = try U.decode(Data("""
            {"polter":{"cpu_cores":"2.6","total_mib":1,
                       "series":{"hour":[],"week":[],"hour_step_s":300,"week_step_s":1800}}}
            """.utf8))
        #expect(bare.polter.series.nowS == 0)
    }

    /// The chart's three layers are read as the core sent them, name and
    /// all, for both spans: **the host draws the core's order and does not
    /// sort it**.
    @Test func theChartsLayersTakeTheCoresOrderAndNames() throws {
        let a = try U.decode(Self.seriesFixture())
        let hour = a.polter.series.layers(.day)
        #expect(hour.map(\.name) == ["main", "chats", "sidecars"])
        #expect(hour[1].cells == [1, 2, 3])
        #expect(same(a.polter.series.stepS(.day), 300))
        #expect(same(a.polter.series.stepS(.week), 1800))
        // The week's own three, and the same names in the same order.
        let week = a.polter.series.layers(.week)
        #expect(week.map(\.name) == ["main", "chats", "sidecars"])
        #expect(week[2].cells == [11, 12])
        // The switch's two spans, in the order it draws them.
        #expect(U.Span.allCases == [.day, .week])
    }

    // MARK: The process table (handoff §6, the third of slice 2's three
    // blocks)

    /// One row of the table, of the shape `rowsOf` writes: the core's own
    /// `category` (never its `kind`), the two verdicts, and the three facts
    /// the row is named from.
    static func process(_ category: String, pid: UInt64 = 1, group: String? = nil,
                        memMib: UInt64 = 100, insideMain: Bool = false,
                        terminal: String? = nil, rising: Bool = false) -> U.Process {
        U.Process(category: category, pid: pid, group: group, count: 1, memMib: memMib,
                  cpuDecimals: 4, rising: rising, slopeMibPerHour: rising ? 1331 : 0,
                  insideMain: insideMain, alive: true, diedAt: nil, started: nil,
                  terminal: terminal)
    }

    /// A `polter` block with just the two lists the table is drawn from, for
    /// the tests that ask about the table and not about a reading.
    static func whole(sections: [U.Section], processes: [U.Process]) -> U.Whole {
        U.Whole(cpuDecimals: 0, monitorBytes: 0, untracked: 0, runStarted: "",
                series: .none, processes: processes, sections: sections, rise: nil)
    }

    /// **The table is grouped by the two things the core sent**: a heading
    /// per group (`Sections`, with the count and the total it worked out),
    /// and under it the rows carrying that group's name. Nothing here adds
    /// a row up or counts them (task 2149, slice 2, review r2 ①).
    @Test func theTableIsGroupedByTheCoresOwnTwoLists() {
        let w = Self.whole(sections: [
            U.Section(category: "main", count: 1, totalMib: 512),
            U.Section(category: "chats", count: 2, totalMib: 21_074),
            U.Section(category: "sidecars", count: 1, totalMib: 92),
        ], processes: [
            Self.process("main", pid: 812, memMib: 512),
            Self.process("main", pid: 812, memMib: 1, insideMain: true),
            Self.process("chats", pid: 1904, group: "web-app", memMib: 20_787),
            Self.process("chats", pid: 1911, group: "billing", memMib: 287),
            Self.process("sidecars", pid: 2210, memMib: 92),
        ])
        let lines = U.tableLines(w)
        // The order out is the core's: a heading, then the rows it named, in
        // the order the core's own list has them.
        #expect(lines.map(\.sectionOrNil?.category) == ["main", nil, nil, "chats", nil, nil, "sidecars", nil])
        #expect(lines.map(\.pidOrNil) == [nil, 812, 812, nil, 1904, 1911, nil, 2210])
        // The numbers on the headings are the core's, drawn as they came:
        // the main process's is one process and 512 MiB even though two rows
        // are drawn under it, because the monitor's row is inside it and the
        // core left it out.
        #expect(same(lines[0].sectionOrNil?.count, 1))
        #expect(same(lines[0].sectionOrNil?.totalMib, 512))
        #expect(same(lines[3].sectionOrNil?.count, 2))
        #expect(same(lines[3].sectionOrNil?.totalMib, 21_074))
        // And it is what the table's own height is worked out from.
        #expect(U.tableHeight(rows: lines.count + 1) > U.tableHeight(rows: 1))
    }

    /// **A row the core gave no heading for is not drawn**, rather than put
    /// in a group of the host's own invention: naming a group the core did
    /// not name is the host deciding.
    @Test func aRowWithNoHeadingIsNotDrawn() {
        let w = Self.whole(sections: [U.Section(category: "main", count: 1, totalMib: 5)],
                           processes: [Self.process("main", pid: 1), Self.process("chats", pid: 2)])
        #expect(U.tableLines(w).count == 2)
        // No headings at all is no lines at all, and not one line per row
        // without a group over them.
        #expect(U.tableLines(Self.whole(sections: [], processes: [Self.process("main")])).isEmpty)
    }

    /// **The monitor's row says it is inside the main process's**, which is
    /// what the core's `inside_main` is for: a reader who adds the rows up
    /// must not count it twice. It is named from that flag and not from the
    /// category or a pid.
    @Test func theMonitorsRowSaysItIsAlreadyCounted() throws {
        let monitor = Self.process("main", pid: 812, memMib: 1, insideMain: true)
        let main = Self.process("main", pid: 812, memMib: 512)
        let table = [main, monitor, Self.process("chats", pid: 1904, group: "web-app")]
        let last = try #require(U.theMonitorRow(table))
        #expect(last.pid == 812)
        #expect(last.insideMain)
        #expect(U.rowName(last) == "of which: performance monitoring")
        // The main process's own row is not it, though it is in the same
        // group and has the same pid: the flag is what says so.
        #expect(U.rowName(main) == "Polter")
        // An answer with no such row draws no such line rather than an
        // empty one.
        #expect(U.theMonitorRow([main, Self.process("chats", group: "x")]) == nil)
        #expect(U.theMonitorRow([]) == nil)
    }

    /// The other rows are named from what the core sent beside them: the
    /// group a chat is, the terminal a sidecar serves. **The names are the
    /// host's** (`rowName`); the facts in them are the core's, and a fact
    /// that did not arrive leaves the application's own name rather than a
    /// half sentence.
    @Test func theRowsAreNamedFromWhatTheCoreSentBesideThem() {
        let chat = Self.process("chats", group: "web-app")
        #expect(U.rowName(chat).contains("web-app"))
        #expect(chat.group == "web-app")
        // A sidecar is named by the terminal it serves.
        let sidecar = Self.process("sidecars", group: "web-app", terminal: "0xab")
        #expect(U.rowName(sidecar).contains("0xab"))
        #expect(sidecar.terminal == "0xab")
        // Neither a group nor a terminal: the application's own name, which
        // is what the main process's row is.
        #expect(U.rowName(Self.process("sidecars")) == "Polter")
        // An empty string is a fact that did not arrive, not a name.
        #expect(U.rowName(Self.process("chats", group: "")) == "Polter")
    }

    /// The rows of the process table are read whole, in order, with the
    /// core's own category on each: **the host is handed the grouping and
    /// never reads the core's `kind`**, which is the field it must not
    /// (`tools/control-room-hosts-do-not-decide.py`, rule 1).
    @Test func theProcessTableIsReadInTheCoresOrder() throws {
        let a = try U.decode(Data("""
            {"polter":{"cpu_cores":"2.6","total_mib":22938,
              "sections":[{"category":"main","count":1,"total_mib":512},
                          {"category":"chats","count":1,"total_mib":20787},
                          {"category":"sidecars","count":2,"total_mib":92}],
              "processes":[
                {"kind":"main","category":"main","pid":812,"group":null,"count":1,
                 "mem_mib":512,"cpu_ds":4,"inside_main":false,"alive":true},
                {"kind":"monitor","category":"main","pid":812,"group":null,"count":1,
                 "mem_mib":1,"cpu_ds":0,"inside_main":true,"alive":true},
                {"kind":"chat","category":"chats","pid":1904,"group":"web-app","count":1,
                 "mem_mib":20787,"cpu_ds":9,"inside_main":false,"alive":true},
                {"kind":"sidecar","category":"sidecars","pid":2210,"group":"web-app","count":2,
                 "mem_mib":92,"cpu_ds":0,"inside_main":false,"alive":false,
                 "died_at":"2026-10-25T16:10:02+08:00"}]}}
            """.utf8))
        let rows = a.polter.processes
        #expect(rows.map(\.category) == ["main", "main", "chats", "sidecars"])
        #expect(rows.map(\.pid) == [812, 812, 1904, 2210])
        #expect(rows[2].group == "web-app")
        #expect(rows[2].memMib == 20_787)
        #expect(rows[3].count == 2)
        #expect(!rows[3].alive)
        #expect(rows[3].diedAt == "2026-10-25T16:10:02+08:00")
        // And the headings, read as the core sent them: **the main process's
        // count is 1 although two rows are drawn under it**, because the
        // monitor's row is inside it and the core left it out. The host is
        // handed both numbers and adds nothing up (review r2 ①).
        let s = a.polter.sections
        #expect(s.map(\.category) == ["main", "chats", "sidecars"])
        #expect(s.map(\.count) == [1, 1, 2])
        #expect(s.map(\.totalMib) == [512, 20_787, 92])
        // Which is the same as the JSON above, drawn line by line.
        #expect(U.tableLines(a.polter).map(\.pidOrNil) == [nil, 812, 812, nil, 1904, nil, 2210])
    }

    // MARK: Opening the overall view (handoff §6's entry, and the
    // supervisor's ruling of 2026-10-25)

    /// A model with a core that answers, selected on `billing`, and with a
    /// group's own page still where the group left it.
    ///
    /// The snapshot arrives at `init` (the feed reads once as it is made and
    /// hands what it has to the listener), so the model is a whole control
    /// room and not one waiting for a core.
    static func openModel() -> ControlRoomModel {
        let core = FakeOverallCore()
        let model = ControlRoomModel(feed: ControlRoomFeed(center: NotificationCenter(), fetch: core.fetch),
                                     selection: "billing")
        model.overallAsk = { _ in .notReady }
        model.detail = .noSupervisor(group: "billing")
        model.pages["billing"] = .performance
        return model
    }

    /// **The overall view stands beside "a group is selected"**, not inside
    /// it: it belongs to no group. With no core there is no such view, and
    /// then it cannot be opened -- which is the same rule the left panel's
    /// bottom line follows.
    @Test func theOverallViewOpensOnlyWhereThereIsACore() {
        let model = ControlRoomModel(feed: ControlRoomFeed(center: NotificationCenter(), fetch: { _, _ in 0 }),
                                     selection: "billing")
        model.showOverall()
        #expect(!model.showingOverall)
        #expect(!model.overallInFront)
        model.overallAsk = { _ in .notReady }
        model.showOverall()
        #expect(model.showingOverall)
        #expect(model.overallInFront)
    }

    /// **Coming back to a group puts it on the page it was left on, and the
    /// overall view does not touch a group's page at all**: selecting a
    /// group after the whole of Polter was in front leaves `pages` exactly
    /// as it was, so a group that was on "Performance" is still there.
    @Test func comingBackToAGroupFindsThePageItWasLeftOn() {
        let model = Self.openModel()
        #expect(model.selection == "billing")
        model.showOverall()
        #expect(model.overallInFront)
        // Nothing about the group's own page moved while the overall view
        // was in front.
        #expect(model.pages["billing"] == .performance)
        #expect(model.selection == "billing")
        model.leaveOverall()
        #expect(!model.overallInFront)
        // And the group is back on the page it was on.
        #expect(model.pages["billing"] == .performance)
        #expect(model.pageInFront == .performance)
    }

    /// A press on the row opens the overall view; a second one comes back,
    /// which is what the row's `onPress` is wired to.
    @Test func aPressOnTheRowOpensAndASecondOneComesBack() {
        let model = Self.openModel()
        func press() { model.overallInFront ? model.leaveOverall() : model.showOverall() }
        press()
        #expect(model.overallInFront)
        press()
        #expect(!model.overallInFront)
    }

    /// **The person selecting a group takes the overall view out of front**:
    /// a press on a row in the list is asking for that group, and leaving
    /// the whole of Polter up over it would ignore the press.
    @Test func selectingAGroupTakesTheOverallViewOutOfFront() {
        let core = FakeOverallCore()
        let model = ControlRoomModel(feed: ControlRoomFeed(center: NotificationCenter(), fetch: core.fetch),
                                     selection: "billing")
        model.overallAsk = { _ in .notReady }
        model.showOverall()
        #expect(model.overallInFront)
        // The press itself, and not a snapshot afterwards: a snapshot the
        // list causes by itself must not undo it (the test below is that
        // half), so the two are the two sides of one rule.
        model.choose("billing")
        #expect(!model.overallInFront)
    }

    /// **Every door onto a group closes the overall view, and they close it
    /// in one place** (task 2149, slice 2; the supervisor's ruling of
    /// 2026-10-25). Four doors lead to a group: a press on a row and the two
    /// things that arrive as one -- the notification jump and a group just
    /// made, both of which come through `choose` -- and Return on the list,
    /// which goes into the group's own terminal through `goToSupervisor`.
    /// This is the second of the two, and the one that used to leave the
    /// whole of Polter up over the terminal it had just handed the keyboard
    /// to.
    @Test func goingToAGroupsSupervisorTakesTheOverallViewOutOfFront() {
        let model = Self.openModel()
        var went = 0
        model.onGoToSupervisor = { went += 1 }
        model.showOverall()
        #expect(model.overallInFront)
        model.goToSupervisor()
        #expect(!model.overallInFront)
        // And the doing still happened: closing the view is not a way of
        // swallowing the key.
        #expect(went == 1)
        // Once is once: with no overall view in front there is nothing to
        // close, and nothing else happens either way.
        model.goToSupervisor()
        #expect(went == 2)
        #expect(!model.overallInFront)
    }

    /// **A group's own pieces are drawn only while the group's side is the
    /// one in front** (task 2149, slice 2, the reviewer's second must-fix):
    /// the project link strip over the terminal and the "start a supervisor"
    /// sentence with no terminal are both drawn by this one question, so
    /// neither can be left over the whole of Polter by a later edit that
    /// forgets one of them.
    @Test func theGroupsOwnPiecesAreDrawnOnlyWhileTheGroupIs() {
        let model = Self.openModel()
        #expect(model.groupSideDrawn(true))
        // Another page of the group -- performance, tasks, chat -- and the
        // supervisor's own pieces are not drawn either.
        #expect(!model.groupSideDrawn(false))
        model.showOverall()
        #expect(model.overallInFront)
        #expect(!model.groupSideDrawn(true))
        #expect(!model.groupSideDrawn(false))
        model.leaveOverall()
        #expect(model.groupSideDrawn(true))
    }

    /// **A snapshot the list caused by itself does not undo the press**: the
    /// same group still selected, chosen by nobody, leaves the overall view
    /// in front -- the list's own bookkeeping is not a person asking for a
    /// group.
    @Test func aSnapshotWithTheSameSelectionLeavesTheOverallViewInFront() {
        let core = FakeOverallCore()
        let center = NotificationCenter()
        // **Kept**: the model does not hold the feed, and a feed that goes
        // away stops listening -- the post below would reach nobody and this
        // test would pass for the wrong reason.
        let feed = ControlRoomFeed(center: center, fetch: core.fetch)
        let model = ControlRoomModel(feed: feed, selection: "billing")
        model.overallAsk = { _ in .notReady }
        model.showOverall()
        #expect(model.overallInFront)
        core.more = 12
        center.post(name: ControlRoomFeed.changed, object: nil)
        #expect(model.overallInFront)
    }

    /// Every word the page says is in both string tables, and no size on it
    /// is below the menu face -- the two floors the whole control room is
    /// held to. Measured off the look's own numbers rather than off a
    /// drawing.
    @Test func nothingOnTheOverallViewIsSmallerThanTheMenuFace() {
        #expect(Look.Font.kpiValue >= Look.Font.min)
        #expect(Look.Font.min >= 13)
        #expect(Look.OverallPage.kpiLine >= 13)
        #expect(Look.OverallPage.tableRowHeight >= 13)
        #expect(Look.OverallPage.plotLabelHeight >= 13)
        #expect(Look.OverallPage.miniHeadHeight >= 13)
        #expect(Look.OverallPage.chartHeadHeight >= 13)
    }

    /// **The page's own layout**: the four figures fill the width evenly,
    /// the chart and the table stand at the page's own padding, and the
    /// machine's two curves are side by side under it. Every one of these is
    /// a reading off `layout`, so the view cannot place a part from a second
    /// reading of the same page.
    @Test func theOverallViewLaysItselfOutByTheLook() {
        let w: CGFloat = 1040
        let at = U.layout(width: w, rising: false)
        let o = Look.OverallPage.self
        #expect(at.kpis.count == U.Layout.kpiCount)
        // Four equal columns, the page's own padding at both ends, `kpiGap`
        // between two, and no gap before the first.
        #expect(at.kpis[0].minX == CGFloat(o.padX))
        #expect(at.kpis[0].width == at.kpis[3].width)
        for i in 1..<at.kpis.count {
            #expect(at.kpis[i].minX == at.kpis[i - 1].maxX + CGFloat(o.kpiGap))
        }
        #expect(at.kpis[3].maxX == w - CGFloat(o.padX))
        // The chart is the page's width, under the figures, and the table is
        // under the curves.
        #expect(at.chart.minX == at.kpis[0].minX)
        #expect(at.chart.width == at.kpis[3].maxX - at.kpis[0].minX)
        #expect(at.chart.minY == at.kpis[0].maxY + CGFloat(o.gap))
        #expect(at.minis[0].minY == at.chart.maxY + CGFloat(o.gap))
        #expect(at.minis[1].minY == at.minis[0].minY)
        #expect(at.minis[0].width == at.minis[1].width)
        #expect(at.minis[1].minX == at.minis[0].maxX + CGFloat(o.miniGap))
        #expect(at.table.minY == at.minis[1].maxY + CGFloat(o.gap))
        #expect(at.table.minX == at.chart.minX)
        // The plot is inside the chart, right of its own gutter, and the
        // labels of the two axes are outside it.
        #expect(at.plot.minX == at.chartHead.minX + CGFloat(o.plotGutter))
        #expect(at.plot.maxX <= at.chart.maxX)
        #expect(at.plotGutter.maxX == at.plot.minX)
        #expect(at.plotXLabels.minY == at.plot.maxY + CGFloat(o.plotAxisGap))
        #expect(at.contentHeight == at.table.minY)
    }

    /// **The sentence takes its room off the chart and nothing else moves**:
    /// with something rising there is one more line under the title, the
    /// plot is shorter by the design's own two numbers, and the two curves
    /// under it simply move down. A page whose parts were placed from two
    /// readings of the same height would have had the curves stand still and
    /// the chart grow over them.
    @Test func theRiseSentenceTakesItsRoomOffTheChart() {
        let w: CGFloat = 1040
        let still = U.layout(width: w, rising: false)
        let rising = U.layout(width: w, rising: true)
        let o = Look.OverallPage.self
        #expect(still.riseNote == .zero)
        #expect(rising.riseNote.height == CGFloat(o.riseNoteHeight))
        #expect(rising.riseNote.minY == rising.chartHead.maxY + CGFloat(o.riseNoteTop))
        // The plot is shorter by the difference of the design's two heights,
        // and starts below the sentence.
        #expect(rising.plot.height == CGFloat(o.plotHeightRising))
        #expect(still.plot.height == CGFloat(o.plotHeight))
        #expect(still.chart.height - rising.chart.height
            == CGFloat(o.plotHeight) - CGFloat(o.plotHeightRising) - CGFloat(o.riseNoteHeight) - CGFloat(o.riseNoteTop))
        // Everything under the chart moved down by the same amount, and the
        // figures above it did not move at all.
        #expect(rising.kpis.map(\.minY) == still.kpis.map(\.minY))
        #expect(rising.minis[0].minY - still.minis[0].minY == rising.chart.maxY - still.chart.maxY)
        #expect(rising.table.minY - still.table.minY == rising.minis[0].minY - still.minis[0].minY)
    }

    /// The table's height is its head, one line per group and per row, and
    /// the room the bottom fades over: a table nobody can see the end of is
    /// the design's `fade`.
    @Test func theTablesHeightIsItsOwnLines() {
        let o = Look.OverallPage.self
        let four = U.tableHeight(rows: 4)
        #expect(four == CGFloat(o.tableTop + o.tableHeadHeight) + 4 * CGFloat(o.tableRowHeight) + CGFloat(o.tableFade))
        #expect(U.tableHeight(rows: 0) == CGFloat(o.tableTop + o.tableHeadHeight + o.tableFade))
        #expect(U.tableHeight(rows: 10) > U.tableHeight(rows: 3))
    }
}

/// A core that answers, for the two tests about a snapshot arriving while
/// the overall view is in front. The same shape `ControlRoomFeedTests` uses.
private final class FakeOverallCore {
    var groups = "billing"
    var more = 11

    func fetch(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
        let json = """
            { "rev": 2, "now_ms": 1, "needs_me": 1, "groups_needing_me": 1, "groups_other": 0, "groups": [
              { "name": "\(groups)", "needs_me": true, "unseen": false, "shown": "needs_you", "text": "等回答",
                "waiter": {"is": "supervisor", "name": ""},
                "reason": {"from": "hook_detail", "text": "x", "missing": null},
                "what": {"cut": "none", "form": "words", "lines": ["x"]},
                "more": \(more), "same_as": null } ] }
            """
        let bytes = Array(json.utf8)
        if let buffer, bytes.count + 1 <= capacity {
            for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
            buffer[bytes.count] = 0
        }
        return bytes.count
    }
}

/// Two points apart is the same place: a rectangle's edges are worked out in
/// points and compared to a fraction.
private func expectClose(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) {
    #expect(abs(a - b) <= tolerance, "\(a) against \(b)")
}

private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
