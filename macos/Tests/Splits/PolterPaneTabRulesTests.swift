import CoreGraphics
import Testing
@testable import Ghostty

/// The rules of a pane's title and a stack's tabs (task 1582).
struct PolterPaneTabRulesTests {
    private typealias Rules = PolterPaneTabRules

    /// Under the pointer only: the one in front no longer keeps its button
    /// showing (task 1642), which is why there is no `current` to pass.
    @Test func aCloseButtonShowsUnderThePointerOnly() {
        #expect(Rules.closeShows(hovering: true))
        #expect(!Rules.closeShows(hovering: false))
    }

    @Test func closingOthersRightAndLeftTakeWhatTheySay() {
        // Five tabs, the menu opened on the middle one.
        #expect(Rules.closing(.others, at: 2, count: 5) == [0, 1, 3, 4])
        #expect(Rules.closing(.right, at: 2, count: 5) == [3, 4])
        #expect(Rules.closing(.left, at: 2, count: 5) == [0, 1])
    }

    @Test func atTheEndsAndAloneThereIsNothingToCloseAndTheItemIsGreyed() {
        #expect(!Rules.offers(.right, at: 4, count: 5))
        #expect(Rules.offers(.left, at: 4, count: 5))
        #expect(!Rules.offers(.left, at: 0, count: 5))
        #expect(Rules.offers(.right, at: 0, count: 5))
        for which in Rules.Closing.allCases {
            #expect(!Rules.offers(which, at: 0, count: 1))
            #expect(Rules.closing(which, at: 7, count: 3).isEmpty)
        }
    }

    @Test func closingEveryMemberTakesThePaneAndLeavingOneDoesNot() {
        #expect(Rules.closesPane([0, 1, 2], count: 3))
        #expect(Rules.closesPane([2, 0, 1, 1], count: 3))
        #expect(!Rules.closesPane(Rules.closing(.others, at: 1, count: 3), count: 3))
        #expect(!Rules.closesPane([], count: 3))
        #expect(!Rules.closesPane([0, 1, 9], count: 3))
    }

    /// A pane's title carries every one of the window tab's rows (task
    /// 2163): a plain pane is where those rows ever were.
    @Test func aPanesTitleCarriesEveryWindowRow() {
        #expect(Rules.windowRows(stacked: false) == Rules.WindowRow.allCases)
        #expect(Rules.windowRows(stacked: false).count == 4)
    }

    /// A stack's tab leaves out the two that close *other* window tabs
    /// (task 2163). **This is the whole fix**: they were on that menu beside
    /// `Close Others` and `Close to the Right`, which mean this stack's
    /// terminals, and the report was somebody choosing the wrong one of the
    /// pair and losing the tab strip.
    @Test func aStacksTabLeavesOutTheTwoThatCloseOtherWindowTabs() {
        #expect(Rules.windowRows(stacked: true) == [.close, .moveToNewWindow])
        for row in Rules.WindowRow.allCases {
            #expect(Rules.windowRowOffered(row, stacked: true) == !row.closesOtherTabs)
            #expect(Rules.windowRowOffered(row, stacked: false))
        }
        // The narrow two on that menu are the stack's own, and they are not
        // these: nothing named `closing` is a window row.
        #expect(Rules.Closing.allCases.count == 3)
        #expect(Rules.windowRows(stacked: true).contains(.closeOthers) == false)
        #expect(Rules.windowRows(stacked: true).contains(.closeRight) == false)
        // Closing this tab and moving it out stay: both are about this tab,
        // not about other tabs.
        #expect(Rules.windowRows(stacked: true).contains(.close))
        #expect(Rules.windowRows(stacked: true).contains(.moveToNewWindow))
    }

    /// The names the dump goes by are the Windows host's, so the two hosts
    /// can be held to each other row by row (`control-room-hosts-agree`).
    @Test func everyWindowRowHasTheNameTheOtherHostKnowsItBy() {
        #expect(Rules.WindowRow.allCases.map(\.name)
            == ["close", "close-others", "close-right", "move-to-new-window"])
    }

    @Test func aWheelThatOnlyTurnsUpAndDownScrollsTheTabsSideways() {
        // A mouse wheel: a line down moves the tabs on by a line's points.
        #expect(Rules.scroll(deltaX: 0, deltaY: -1, precise: false) == 16)
        #expect(Rules.scroll(deltaX: 0, deltaY: 2, precise: false) == -32)
        // A trackpad swiping sideways is taken as it is, in points.
        #expect(Rules.scroll(deltaX: -7, deltaY: 1, precise: true) == 7)
        // A trackpad moving mostly up and down still moves the tabs.
        #expect(Rules.scroll(deltaX: 1, deltaY: -5, precise: true) == 5)
    }
}
