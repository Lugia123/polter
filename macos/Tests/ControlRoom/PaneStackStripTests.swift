import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

/// Where the tabs of a stack's strip are (`PaneStackStripLayout`): the rule
/// in the order it gives way, on numbers small enough to add up by hand.
///
/// With the table as it is: the first tab starts 20 in, the plus is 28,
/// 12 is kept at the right end, a status takes its width and 8 before it,
/// and a tab is never narrower than 104 -- neither cut below it nor left
/// below it by a short name (task 1675). Past that the tabs scroll (task
/// 1582).
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
        let l = Layout(wants: [130, 110, 110], current: 1, width: 500, status: 50)
        #expect(xs(l) == [20, 150, 260])
        #expect(widths(l) == [130, 110, 110])
        #expect(l.tabs.map(\.current) == [false, true, false])
        #expect(l.tabs.allSatisfy { !$0.squeezed })
        #expect(!l.scrolls)
        // The plus straight after the last tab; the status against the
        // right end, 12 in.
        #expect(l.addX == 370)
        #expect(l.status == 438...488)
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
        // 500 for the tabs; they want 720. The two long ones come down to
        // 140 each and the two short ones are untouched.
        let l = Layout(wants: [250, 110, 250, 110], current: 1, width: 560, status: 0)
        #expect(widths(l) == [140, 110, 140, 110])
        #expect(l.tabs.map(\.squeezed) == [true, false, true, false])
        #expect(!l.scrolls)
        let afterTabs: CGFloat = 520
        #expect(l.addX == afterTabs)
    }

    @Test func theTabInFrontIsNotCut() {
        // 610 for the tabs with a long one in front: it keeps its 250, the
        // short ones their 110, and the other long one what is left.
        let l = Layout(wants: [250, 110, 250, 110], current: 0, width: 670, status: 0)
        #expect(widths(l) == [250, 110, 140, 110])
        #expect(l.tabs.map(\.squeezed) == [false, false, true, false])
    }

    @Test func cuttingStopsAtTheLeastWidth() {
        // 432 for the tabs: 104 + 104 + 104 + the 120 in front. One less
        // and they no longer all fit.
        let fits = Layout(wants: [200, 120, 200, 200], current: 1, width: 492, status: 0)
        #expect(widths(fits) == [104, 120, 104, 104])
        #expect(!fits.scrolls)
        let over = Layout(wants: [200, 120, 200, 200], current: 1, width: 491, status: 0)
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

    /// Task 1599, the same two steps as `stackstrip.rs`'s
    /// `a_new_tab_whose_name_comes_later_is_still_brought_into_view`: a new
    /// terminal's name comes after it is made, its tab widens, and nothing
    /// the strip is keyed on changed. Until the person scrolls, the tab in
    /// front is still brought into view.
    @Test func aNewTabWhoseNameComesLaterIsStillBroughtIntoView() {
        var wants: [CGFloat] = Array(repeating: 150, count: 11) + [60]
        let before = Layout(wants: wants, current: 11, width: 400, status: 0)
        let first = before.settle(11, from: 0, changed: true, wheeled: false)
        #expect(first == before.maxOffset)
        wants[11] = 200
        let after = Layout(wants: wants, current: 11, width: 400, status: 0)
        let then = after.settle(11, from: first, changed: false, wheeled: false)
        let tab = after.tabs.first { $0.member == 11 }!
        let start = tab.x - CGFloat(ControlRoomLook.StackTab.inset) - then
        #expect(start >= 0 && start + tab.width <= after.viewport)
        // Scrolled by the person: left where they put it until one of the
        // three changes.
        #expect(after.settle(11, from: 100, changed: false, wheeled: true) == 100)
        #expect(after.settle(11, from: 100, changed: true, wheeled: true) == after.revealing(11, from: 100))
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
        let l = Layout(wants: [120, 110], current: 0, width: 360, status: 60)
        #expect(l.status == 288...348)
        // 232 for the tabs: both, whole.
        #expect(widths(l) == [120, 110])
    }

    // MARK: Never narrower than the least (task 1675)

    /// A terminal in its home directory is called `~`, and its tab was as
    /// wide as that wants: barely wider than the close button that comes
    /// over the name's start, so a drag meant to move the tab closed it
    /// (the person's screenshot, #1675). Every tab is at least `min_width`,
    /// the one in front too, and being widened is not being squeezed.
    @Test func aTabNamedTildeIsNeverNarrowerThanTheLeast() {
        let tilde = Layout.nominalWidth(name: "~", glyph: true)
        let least = CGFloat(Look.StackTab.minWidth)
        #expect(tilde < least)
        for current in 0..<2 {
            let l = Layout(wants: [tilde, tilde], current: current, width: 600, status: 0)
            #expect(widths(l) == [least, least])
            #expect(xs(l) == [20, 20 + least])
            #expect(l.tabs.allSatisfy { !$0.squeezed })
        }
        // Five in a narrow pane: none is cut below the least to fit; they
        // scroll.
        let five = Layout(wants: Array(repeating: tilde, count: 5), current: 2, width: 300, status: 0)
        #expect(widths(five) == Array(repeating: least, count: 5))
        #expect(five.scrolls)
        // What is left of a tab past its close button, to pick it up by:
        // the button's square is all a click closes.
        let close = PolterCloseCircle.frame(textLeading: CGFloat(Look.StackTab.paddingX),
                                            height: CGFloat(Look.StackTab.height))
        #expect(least - close.maxX >= 3 * close.width)
        // The other candidate holds the same way.
        let narrow = Layout(wants: [50, 50], current: 0, width: 600, status: 0, minWidth: 68)
        #expect(widths(narrow) == [68, 68])
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
        // glyph. No place for the close button (task 1642): on macOS it
        // comes over the name's start, so these are Windows' less 4 + 16.
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

    // MARK: The close button

    /// Task 1600 (#1601 W3): scrolled so that a tab stood under the plus,
    /// its close button was drawn there. It is seen only whole inside the
    /// window the tabs are seen through -- at the tab's left end on macOS
    /// (task 1642), its right end on Windows.
    @Test func aCloseButtonScrolledOutOfTheWindowIsNotSeen() {
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 7, width: 400, status: 0)
        let pad = CGFloat(Look.StackTab.paddingX)
        let inset = CGFloat(Look.StackTab.inset)
        for offset in [CGFloat(0), 100, 300, 400, l.maxOffset] {
            for tab in l.tabs {
                // macOS: the 18pt square, 11 in (the disc's edge on the name's).
                let x = tab.x - inset - offset + pad - 1
                #expect(l.closeSeen(tab.member, offset: offset, at: .leading) == (x >= 0 && x + 18 <= l.viewport),
                        "leading: offset \(offset), tab \(tab.member) at \(x)")
                // Windows: 16pt, inside the right padding.
                let y = tab.x - inset - offset + tab.width - pad - 16
                #expect(l.closeSeen(tab.member, offset: offset, at: .trailing) == (y >= 0 && y + 16 <= l.viewport),
                        "trailing: offset \(offset), tab \(tab.member) at \(y)")
            }
        }
        // At the start the first tab's is seen, the last tab's is not.
        #expect(l.closeSeen(0, offset: 0, at: .leading))
        #expect(!l.closeSeen(7, offset: 0, at: .leading))
        #expect(!l.closeSeen(99, offset: 0, at: .leading))
    }

    /// The two ends part where a tab is half out of the window: its left
    /// end in sight and its right end not, or the other way (task 1642).
    /// Scrolled through, eight tabs in a window of 400 show both.
    @Test func aTabHalfInSightShowsTheButtonAtTheEndThatIsIn() {
        let l = Layout(wants: Array(repeating: 150, count: 8), current: 7, width: 400, status: 0)
        var leftOnly = 0, rightOnly = 0
        for offset in stride(from: CGFloat(0), through: l.maxOffset, by: 10) {
            for tab in l.tabs {
                let leading = l.closeSeen(tab.member, offset: offset, at: .leading)
                let trailing = l.closeSeen(tab.member, offset: offset, at: .trailing)
                if leading && !trailing { leftOnly += 1 }
                if trailing && !leading { rightOnly += 1 }
            }
        }
        #expect(leftOnly > 0)
        #expect(rightOnly > 0)
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

    // MARK: The supervisor's mark (task 1692)

    @Test func aSupervisorsTabWantsRoomForItsMarkBeforeTheName() {
        let worker = PaneStack.Member(name: "web-app", shown: .working, wears: .worker)
        let supervisor = PaneStack.Member(name: "web-app", shown: .working, wears: .supervisor)
        #expect(!worker.marked && supervisor.marked)
        #expect(PaneStackStripView.wanted(supervisor) - PaneStackStripView.wanted(worker)
            == CGFloat(Look.Side.glyph) + CGFloat(Look.StackTab.gap))
    }

    /// The mark is drawn on the supervisor's tab, in front and behind, and
    /// on no other tab: a stack of two workers draws none of its colour.
    @MainActor @Test func theStripDrawsTheMarkOnTheSupervisorsTabOnly() throws {
        func markPixels(_ members: [PaneStack.Member], current: Int, scheme: ColorScheme) throws -> Int {
            let stack = PaneStack(members: members, current: current)
            let wears = stack.showing?.wears ?? .plain
            let view = PaneStackStripView(stack: stack, wears: wears, title: nil, well: .white, still: true)
                .frame(width: 600, height: CGFloat(Look.StackTab.stripHeight))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            let want = Look.theme(dark: scheme == .dark).panePurple
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9 else { continue }
                    let d = abs(c.redComponent * 255 - Double(want.r)) + abs(c.greenComponent * 255 - Double(want.g))
                        + abs(c.blueComponent * 255 - Double(want.b))
                    if d < 24 { count += 1 }
                }
            }
            return count
        }
        let sv = PaneStack.Member(name: "web-app", shown: .working, wears: .supervisor)
        let a = PaneStack.Member(name: "frontend", shown: .working, wears: .worker)
        let b = PaneStack.Member(name: "e2e", shown: .none, wears: .worker)
        for scheme in [ColorScheme.light, .dark] {
            let behind = try markPixels([a, sv, b], current: 0, scheme: scheme)
            let front = try markPixels([a, sv, b], current: 1, scheme: scheme)
            let none = try markPixels([a, b], current: 0, scheme: scheme)
            #expect(behind > 40, "\(scheme): behind, \(behind)")
            #expect(front > 40, "\(scheme): in front, \(front)")
            #expect(none == 0, "\(scheme): no supervisor, \(none)")
        }
    }
}
