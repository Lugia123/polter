import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// Where the tabs of a stack's strip are (`PaneStackStripLayout`): the rule
/// in the order it gives way, on numbers small enough to add up by hand.
///
/// With the table as it is: the first tab starts 20 in, the plus is 28,
/// 12 is kept at the right end, a status takes its width and 8 before it,
/// `more` is 60, and a tab is not cut below 104.
struct PaneStackStripTests {
    typealias Layout = PaneStackStripLayout
    typealias Look = ControlRoomLook

    private func xs(_ l: Layout) -> [CGFloat] { l.tabs.map(\.x) }
    private func widths(_ l: Layout) -> [CGFloat] { l.tabs.map(\.width) }
    private func members(_ l: Layout) -> [Int] { l.tabs.map(\.member) }

    @Test func theNumbersTheseTestsAddUpWith() {
        #expect(Look.StackTab.inset == 20)
        #expect(Look.StackTab.addButton == 28)
        #expect(Look.StackTab.trailing == 12)
        #expect(Look.StackTab.statusGap == 8)
        #expect(Look.StackTab.moreButton == 60)
        #expect(Look.StackTab.minWidth == 104)
    }

    // MARK: 1. Everything fits

    @Test func tabsThatFitAreAsWideAsTheyWantOneAfterAnotherFromTheInset() {
        let l = Layout(wants: [100, 60, 60], current: 1, width: 400, status: 50)
        #expect(xs(l) == [20, 120, 180])
        #expect(widths(l) == [100, 60, 60])
        #expect(l.tabs.map(\.current) == [false, true, false])
        #expect(l.tabs.allSatisfy { !$0.squeezed })
        #expect(l.hidden.isEmpty)
        #expect(l.moreX == nil)
        // The plus straight after the last tab; the status against the
        // right end, 12 in.
        #expect(l.addX == 240)
        #expect(l.status == 338...388)
    }

    @Test func aHairlineStandsOnlyBetweenTwoTabsNeitherOfWhichIsInFront() {
        let first = Layout(wants: [60, 60, 60, 60], current: 0, width: 600, status: 0)
        #expect(first.tabs.map(\.separatorBefore) == [false, false, true, true])
        let middle = Layout(wants: [60, 60, 60, 60], current: 2, width: 600, status: 0)
        #expect(middle.tabs.map(\.separatorBefore) == [false, true, false, false])
        let last = Layout(wants: [60, 60, 60, 60], current: 3, width: 600, status: 0)
        #expect(last.tabs.map(\.separatorBefore) == [false, true, true, false])
    }

    @Test func theFirstTabLeavesRoomForItsFootBesideTheContentsCorner() {
        // 20 = the content's corner 8 + a straight 4 + the arc 8: the foot
        // of the first tab ends where the corner has finished turning.
        let l = Layout(wants: [60], current: 0, width: 300, status: 0)
        let foot = l.tabs[0].x - CGFloat(Look.StackTab.reverseArcRadius)
        #expect(foot == 12)
        #expect(foot >= CGFloat(Look.Radius.supervisorInner))
        // And at the other end the plus and the trailing space keep the
        // last tab's body further than that from the right edge.
        let end = l.tabs[0].x + l.tabs[0].width
        #expect(300 - end >= CGFloat(Look.StackTab.inset))
    }

    @Test func withNothingToSayThereIsNoStatus() {
        let l = Layout(wants: [60, 60], current: 0, width: 400, status: 0)
        #expect(l.status == nil)
    }

    // MARK: 2. The widest give way first

    @Test func whenTheyDoNotFitTheWidestAreCutToOneWidthAndTheShortLeftWhole() {
        // 400 for the tabs; they want 520. The two long ones come down to
        // 140 each and the two short ones are untouched.
        let l = Layout(wants: [200, 60, 200, 60], current: 1, width: 460, status: 0)
        #expect(widths(l) == [140, 60, 140, 60])
        #expect(l.tabs.map(\.squeezed) == [true, false, true, false])
        #expect(l.hidden.isEmpty)
        let afterTabs: CGFloat = 420
        #expect(l.addX == afterTabs)
    }

    @Test func theTabInFrontIsNotCut() {
        // 440 for the tabs with a long one in front: it keeps its 200, the
        // short ones their 60, and the other long one what is left.
        let l = Layout(wants: [200, 60, 200, 60], current: 0, width: 500, status: 0)
        #expect(widths(l) == [200, 60, 120, 60])
        #expect(l.tabs.map(\.squeezed) == [false, false, true, false])
    }

    @Test func cuttingStopsAtTheLeastWidth() {
        // 384 for the tabs: 104 + 104 + 104 + the 72 in front. One less
        // and they no longer all fit.
        let fits = Layout(wants: [200, 72, 200, 200], current: 1, width: 444, status: 0)
        #expect(widths(fits) == [104, 72, 104, 104])
        #expect(fits.hidden.isEmpty)
        let over = Layout(wants: [200, 72, 200, 200], current: 1, width: 443, status: 0)
        #expect(!over.hidden.isEmpty)
    }

    @Test func theLeastWidthCanBeTheOtherCandidate() {
        // The same four at 68: they still fit where at 104 they did not.
        let narrow = Layout(wants: [200, 72, 200, 200], current: 1, width: 336, status: 0, minWidth: 68)
        #expect(widths(narrow) == [68, 72, 68, 68])
        let table = Layout(wants: [200, 72, 200, 200], current: 1, width: 336, status: 0)
        #expect(!table.hidden.isEmpty)
    }

    // MARK: 3. The rest go behind `more`

    @Test func whatThereIsNoRoomForGoesBehindMoreAndTheOneInFrontNeverDoes() {
        // Eight tabs of 150, the seventh in front, 400 wide: 340 for the
        // tabs, 280 once `more` has its 60. The one in front takes its
        // 150; one more at 104 makes 254, and another would not fit.
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 6, width: 400, status: 0)
        #expect(members(l) == [0, 6])
        // It was counted at 104 to see whether it fits, and is given the
        // 130 there turned out to be.
        #expect(widths(l) == [130, 150])
        #expect(xs(l) == [20, 150])
        #expect(l.hidden == [1, 2, 3, 4, 5, 7])
        #expect(l.moreX == 300)
        #expect(l.addX == 360)
        #expect(l.tabs.last?.current == true)

        // `more` has to have its own 60: at 434 wide a second tab beside
        // the one in front would fit in the 374 there is without it, and
        // does not in the 314 there is with it.
        let tight = Layout(wants: Array(repeating: 150, count: 8), current: 6, width: 434, status: 0)
        #expect(members(tight) == [0, 6])
        // With 164 left beside the one in front, the other is whole.
        #expect(widths(tight) == [150, 150])
    }

    @Test func theTabsKeepTheStacksOrder() {
        // In front is the second: it stays second, not last.
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 1, width: 520, status: 0)
        #expect(members(l) == [0, 1, 2])
        // 400 beside `more`: the one in front whole, 125 each for the two.
        #expect(widths(l) == [125, 150, 125])
        #expect(l.tabs.map(\.current) == [false, true, false])
        #expect(l.hidden == [3, 4, 5, 6, 7])
    }

    // MARK: What `more` carries

    @Test func moreCarriesTheFirstOfTheCoresOrderThatIsBehindIt() {
        // Behind `more`: 1, 2, 3, 4, 5 and 7.
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 6, width: 400, status: 0)
        // The core says 6 is the most pressing, then 4, then 0, then 2.
        // 6 is on the strip; 4 is the first of them that is not.
        #expect(l.behindMore(urgent: [6, 4, 0, 2]) == 4)
        // The order is the core's and is not second-guessed: 2 before 4.
        #expect(l.behindMore(urgent: [0, 2, 4]) == 2)
        // Everything pressing is on the strip already, or nothing is.
        #expect(l.behindMore(urgent: [6, 0]) == nil)
        #expect(l.behindMore(urgent: []) == nil)
    }

    @Test func withNothingBehindMoreItCarriesNothing() {
        let l = Layout(wants: [100, 60, 60], current: 1, width: 400, status: 0)
        #expect(l.hidden.isEmpty)
        #expect(l.behindMore(urgent: [0, 1, 2]) == nil)
    }

    // MARK: 4. The status gives way, then the tab itself

    @Test func theStatusGivesWayBeforeTheTabInFront() {
        // With the status there would be 72 for a tab that wants 120.
        let l = Layout(wants: [120, 150], current: 0, width: 200, status: 60)
        #expect(l.status == nil)
        // Without it there is 140, 80 beside `more`: the one in front
        // alone, cut to that, and the other behind `more`.
        #expect(members(l) == [0])
        #expect(widths(l) == [80])
        #expect(l.hidden == [1])
        #expect(l.tabs[0].squeezed)
    }

    @Test func aStatusThatFitsBesideTheTabInFrontStays() {
        let l = Layout(wants: [120, 80], current: 0, width: 330, status: 60)
        #expect(l.status == 258...318)
        // 202 for the tabs: both, whole.
        #expect(widths(l) == [120, 80])
    }

    // MARK: Odd input

    @Test func aCurrentThatIsNotOneOfThemIsTheFirst() {
        let l = Layout(wants: [60, 60], current: 7, width: 400, status: 0)
        #expect(l.tabs.map(\.current) == [true, false])
        let stack = PaneStack(members: [
            .init(name: "a", shown: .none, wears: .worker), .init(name: "b", shown: .none, wears: .supervisor),
        ], current: 7)
        #expect(stack.showing?.name == "a")
    }

    @Test func noTabsIsOnlyThePlus() {
        let l = Layout(wants: [], current: 0, width: 400, status: 0)
        #expect(l.tabs.isEmpty)
        #expect(l.addX == 20)
    }

    // MARK: With no font

    @Test func aTabsNominalWidthIsItsCellsItsPaddingsAndItsGlyph() {
        // 8 a cell, a wide character two; 12 each side; 8 and 14 for a glyph.
        #expect(Layout.nominalWidth(name: "api", glyph: false) == 48)
        #expect(Layout.nominalWidth(name: "api", glyph: true) == 70)
        #expect(Layout.nominalWidth(name: "任务", glyph: false) == 56)
        #expect(Layout.nominalWidth(name: "", glyph: false) == 24)
    }

    // MARK: The frame is the showing member's

    @Test func theFrameRoundAStackIsWhicheverMemberIsInFront() {
        var stack = PaneStack(members: [
            .init(name: "web-app", shown: .needsYou, wears: .supervisor),
            .init(name: "api", shown: .working, wears: .worker),
            .init(name: "zsh", shown: .none, wears: .plain),
        ], current: 0)
        #expect(stack.showing?.wears == .supervisor)
        stack.current = 1
        #expect(stack.showing?.wears == .worker)
        stack.current = 2
        #expect(stack.showing?.wears == .plain)
    }

    // MARK: What `more` says, and the glyph at the right end

    @Test func moreSaysHowManyTabsAreBehindIt() {
        #expect(Layout.moreLabel(hidden: 1) == "…1")
        #expect(Layout.moreLabel(hidden: 12) == "…12")
        #expect(Layout.moreLabel(hidden: 99) == "…99")
        // Past what the button has room for, said as that.
        #expect(Layout.moreLabel(hidden: 100) == "…99+")
        #expect(Layout.moreLabel(hidden: 0) == "…0")
    }

    @Test func aHeldTerminalDrawsTheHeldMarkAndEveryStatusDrawsItsOwnGlyph() {
        typealias Bar = ControlRoomSnapshot.Terminal.Bar.Shown
        // Held is not one of the status glyphs: it is the one case that
        // is drawn as something else.
        #expect(PaneStackStatusGlyph(Bar.held) == .held)
        #expect(PaneStackStatusGlyph(Bar.needsYou) == .status(.needsYou))
        #expect(PaneStackStatusGlyph(Bar.trouble) == .status(.trouble))
        #expect(PaneStackStatusGlyph(Bar.doneUnseen) == .status(.doneUnseen))
        #expect(PaneStackStatusGlyph(Bar.working) == .status(.working))
        #expect(PaneStackStatusGlyph(Bar.none) == .status(ControlRoomList.Shown.none))
        // Every case the core can send is one of the two.
        for shown in Bar.allCases {
            #expect(PaneStackStatusGlyph(shown) == (shown == .held ? .held : .status(shown.status!)))
        }
    }
}
