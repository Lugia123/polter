import Testing
import Foundation
@testable import Ghostty

/// A pane dragged over a tab strip (task 1557). The same cases are in
/// `windows/split-tree/src/drag.rs`, named alike.
struct TabStripDropTests {
    private typealias Drop = TabStripDrop

    /// Three tabs 100 wide with a gap of 4: 0-100, 104-204, 208-308.
    private let tabs = [
        Drop.Tab(minX: 0, maxX: 100),
        Drop.Tab(minX: 104, maxX: 204),
        Drop.Tab(minX: 208, maxX: 308),
    ]

    private func at(_ x: Double, selected: Int? = 0, alone: Bool = false) -> Drop.Target {
        Drop.target(x: x, tabs: tabs, selected: selected, alone: alone)
    }

    // MARK: - The quarters

    @Test func theLeftQuarterOfATabIsTheGapBeforeIt() {
        #expect(at(105) == .insert(1))
        #expect(at(128.9) == .insert(1))
    }

    @Test func theRightQuarterOfATabIsTheGapAfterIt() {
        #expect(at(179.1) == .insert(2))
        #expect(at(204) == .insert(2))
    }

    @Test func theQuarterLinesBelongToTheMiddle() {
        #expect(at(129) == .bringForward(1))
        #expect(at(179) == .bringForward(1))
    }

    @Test func theGapBetweenTwoTabsIsThatGap() {
        #expect(at(102) == .insert(1))
        #expect(at(206) == .insert(2))
    }

    // MARK: - The ends

    @Test func pastTheLastTabIsAfterIt() {
        #expect(at(309) == .insert(3))
        #expect(at(2000) == .insert(3))
    }

    @Test func beforeTheFirstTabIsBeforeIt() {
        #expect(at(-5) == .insert(0))
        #expect(at(10) == .insert(0))
    }

    @Test func anEmptyStripMeansNothing() {
        #expect(Drop.target(x: 10, tabs: [], selected: nil, alone: false) == .none)
    }

    // MARK: - The tab in front, and a pane that is a tab already

    @Test func theMiddleOfTheTabInFrontIsNothing() {
        #expect(at(50, selected: 0) == .none)
        #expect(at(50, selected: 1) == .bringForward(0))
    }

    @Test func aPaneAloneInItsTabIsOfferedNoGapOnItsOwnStrip() {
        #expect(at(10, alone: true) == .none)
        #expect(at(102, alone: true) == .none)
        #expect(at(2000, alone: true) == .none)
    }

    @Test func aPaneAloneInItsTabCanStillBringAnotherTabForward() {
        #expect(at(150, selected: 0, alone: true) == .bringForward(1))
    }

    // MARK: - The mark

    @Test func theMarkSitsInTheGapOrOnTheOuterEdge() {
        #expect(Drop.markX(index: 0, tabs: tabs) == 0)
        #expect(Drop.markX(index: 1, tabs: tabs) == 102)
        #expect(Drop.markX(index: 3, tabs: tabs) == 308)
        #expect(Drop.markX(index: 4, tabs: tabs) == nil)
    }

    // MARK: - The dwell

    @Test func theDwellIsEightTenthsOfASecond() {
        #expect(Drop.dwell == 0.8)
    }

    @Test func aTabComesForwardOnceAfterTheWholeDwell() {
        var d = Drop.Dwell<Int>()
        #expect(d.at(7, now: 0) == nil)
        #expect(d.progress(now: 0.4) == 0.5)
        #expect(d.at(7, now: 0.79) == nil)
        #expect(d.at(7, now: 0.81) == 7)
        #expect(d.at(7, now: 2) == nil)
        #expect(d.progress(now: 2) == nil)
    }

    @Test func movingOffAndBackStartsAgain() {
        var d = Drop.Dwell<Int>()
        _ = d.at(7, now: 0)
        _ = d.at(nil, now: 0.5)
        #expect(d.progress(now: 0.5) == nil)
        _ = d.at(7, now: 1)
        #expect(d.at(7, now: 1.75) == nil)
        #expect(d.at(7, now: 1.85) == 7)
    }

    @Test func anotherTabStartsItsOwnDwell() {
        var d = Drop.Dwell<Int>()
        _ = d.at(7, now: 0)
        #expect(d.at(8, now: 0.7) == nil)
        #expect(d.at(8, now: 1.0) == nil)
        #expect(d.at(8, now: 1.6) == 8)
    }
}
