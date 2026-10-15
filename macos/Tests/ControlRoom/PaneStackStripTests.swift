import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// Where the tabs of a stack's strip are (`PaneStackStripLayout`): the rule
/// in the order it gives way, on numbers small enough to add up by hand.
///
/// With the table as it is: the first tab starts 20 in, the plus is 28,
/// 12 is kept at the right end, a status takes its width and 8 before it,
/// and a tab is not cut below 104. Past that the tabs scroll (task 1582).
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
        #expect(Look.StackTab.closeButton == 16)
        #expect(Look.StackTab.closeGap == 4)
        #expect(Look.StackTab.minWidth == 104)
    }

    // MARK: 1. Everything fits

    @Test func tabsThatFitAreAsWideAsTheyWantOneAfterAnotherFromTheInset() {
        let l = Layout(wants: [100, 60, 60], current: 1, width: 400, status: 50)
        #expect(xs(l) == [20, 120, 180])
        #expect(widths(l) == [100, 60, 60])
        #expect(l.tabs.map(\.current) == [false, true, false])
        #expect(l.tabs.allSatisfy { !$0.squeezed })
        #expect(!l.scrolls)
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
        #expect(!l.scrolls)
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
        #expect(!fits.scrolls)
        let over = Layout(wants: [200, 72, 200, 200], current: 1, width: 443, status: 0)
        #expect(over.scrolls)
    }

    @Test func theLeastWidthCanBeTheOtherCandidate() {
        // The same four at 68: they still fit where at 104 they did not.
        let narrow = Layout(wants: [200, 72, 200, 200], current: 1, width: 336, status: 0, minWidth: 68)
        #expect(widths(narrow) == [68, 72, 68, 68])
        let table = Layout(wants: [200, 72, 200, 200], current: 1, width: 336, status: 0)
        #expect(table.scrolls)
    }

    // MARK: 3. The rest scroll (task 1582)

    @Test func whatThereIsNoRoomForScrollsAndEveryTabIsStillThere() {
        // Eight tabs of 150, the seventh in front, 400 wide: 340 for the
        // tabs. Every one is laid out -- none behind a menu -- the one in
        // front whole and the rest at 104, and the room is a window.
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 6, width: 400, status: 0)
        #expect(members(l) == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(widths(l) == [104, 104, 104, 104, 104, 104, 150, 104])
        #expect(l.viewport == 340)
        #expect(l.content == 878)
        #expect(l.scrolls)
        // The plus stands after the window, not after the tabs.
        #expect(l.addX == 360)
    }

    @Test func theTabInFrontIsScrolledIntoViewByTheLeastMove() {
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 6, width: 400, status: 0)
        // Tab 6 runs from 624 to 774 of the row; the window is 340 wide.
        // Its end comes to 16 (the fade) inside the window's right edge.
        #expect(l.revealing(6, from: 0) == 450)
        // Already in view, clear of both fades: no move.
        #expect(l.revealing(6, from: 500) == 500)
        // To its left: its start comes to 16 inside the window's left edge.
        #expect(l.revealing(1, from: 500) == 88)
        // Never past either end.
        #expect(l.revealing(7, from: 0) == 538)
        #expect(l.revealing(0, from: 900) == 0)
        // A strip that does not scroll does not move.
        let roomy = Layout(wants: [100, 60, 60], current: 1, width: 400, status: 0)
        #expect(roomy.revealing(2, from: 0) == 0)
    }

    @Test func aWaitingTerminalOffAnEdgeIsCarriedByThatEdgeInTheCoresOrder() {
        // Scrolled to 434: tabs 0-4 are off the left, 7 off the right.
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 6, width: 400, status: 0)
        let a = l.beyond(urgent: [6, 4, 0, 7], offset: 434)
        #expect(a.left == 4)
        #expect(a.right == 7)
        // The order is the core's and is not second-guessed: 0 before 4.
        #expect(l.beyond(urgent: [0, 4], offset: 434).left == 0)
        // Not scrolled: nothing off the left.
        let b = l.beyond(urgent: [1, 5, 3], offset: 0)
        #expect(b.left == nil)
        #expect(b.right == 5)
        #expect(l.beyond(urgent: [], offset: 434).left == nil)
    }

    // MARK: 4. The status gives way, then the tab itself

    @Test func theStatusGivesWayBeforeTheTabInFront() {
        // With the status there would be 72 for a tab that wants 120.
        let l = Layout(wants: [120, 150], current: 0, width: 200, status: 60)
        #expect(l.status == nil)
        // Without it there is 140: the one in front whole, the other at
        // its least, and they scroll.
        #expect(widths(l) == [120, 104])
        #expect(l.viewport == 140)
        #expect(l.scrolls)
    }

    @Test func aTabInFrontTooWideEvenAloneIsCutToTheRoom() {
        let l = Layout(wants: [300], current: 0, width: 100, status: 40)
        #expect(l.status == nil)
        #expect(widths(l) == [40])
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
        // 8 a cell, a wide character two; 12 each side; 8 and 14 for a
        // glyph; 4 and 16 for the close button every tab keeps a place for.
        #expect(Layout.nominalWidth(name: "api", glyph: false) == 68)
        #expect(Layout.nominalWidth(name: "api", glyph: true) == 90)
        #expect(Layout.nominalWidth(name: "任务", glyph: false) == 76)
        #expect(Layout.nominalWidth(name: "", glyph: false) == 44)
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

    // MARK: The glyph at the right end

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
