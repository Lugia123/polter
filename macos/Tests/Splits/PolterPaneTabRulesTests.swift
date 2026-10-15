import CoreGraphics
import Testing
@testable import Ghostty

/// The rules of a pane's title and a stack's tabs (task 1582).
struct PolterPaneTabRulesTests {
    private typealias Rules = PolterPaneTabRules

    @Test func aCloseButtonShowsUnderThePointerAndOnTheOneInFront() {
        #expect(Rules.closeShows(hovering: true, current: false))
        #expect(Rules.closeShows(hovering: false, current: true))
        #expect(!Rules.closeShows(hovering: false, current: false))
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
