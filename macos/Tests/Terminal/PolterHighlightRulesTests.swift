import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// `terminal_highlight`'s rules on macOS (task 1689) that need no window.
struct PolterHighlightRulesTests {
    typealias Rules = PolterHighlightRules
    typealias Look = ControlRoomLook.Highlight

    @Test func theNumbersTheseTestsUse() {
        #expect(Look.breathPeriod == 1.2)
        #expect(Look.breathLow == 0.35)
        #expect(Look.breathHigh == 1.0)
        #expect(Look.cardMinPaneWidth == 280)
        #expect(Look.cardMinPaneHeight == 160)
    }

    /// The curve the edge, the card's ring and the tab share: faintest at
    /// the start, strongest half a breath in, back again after one -- and
    /// it really moves.
    @Test func itBreathesOncePerPeriod() {
        let p = Look.breathPeriod
        #expect(abs(Rules.breath(at: 0, reduceMotion: false) - Look.breathLow) < 1e-9)
        #expect(abs(Rules.breath(at: p / 2, reduceMotion: false) - Look.breathHigh) < 1e-9)
        #expect(abs(Rules.breath(at: p, reduceMotion: false) - Look.breathLow) < 1e-9)
        #expect(abs(Rules.breath(at: 7 * p + p / 2, reduceMotion: false) - Look.breathHigh) < 1e-9)
        let quarter = Rules.breath(at: p / 4, reduceMotion: false)
        #expect(abs(quarter - (Look.breathLow + Look.breathHigh) / 2) < 1e-9)
        for i in 0...100 {
            let a = Rules.breath(at: Double(i) * 0.037, reduceMotion: false)
            #expect(a >= Look.breathLow - 1e-9 && a <= Look.breathHigh + 1e-9)
        }
    }

    @Test func withReduceMotionItRestsAtTheTop() {
        for t in [0.0, 0.3, 0.6, 5.0] {
            #expect(Rules.breath(at: t, reduceMotion: true) == Look.breathHigh)
        }
    }

    /// The tab's layer repeats one breath: no seam where it starts again.
    @Test func theKeyframesAreOneBreathWithNoSeam() {
        let k = Rules.breathKeyframes(count: 25)
        #expect(k.count == 25)
        #expect(abs(k.first! - k.last!) < 1e-9)
        #expect(abs(k[12] - Look.breathHigh) < 1e-9)
        #expect(Set(k.map { ($0 * 1000).rounded() }).count > 5)
    }

    @Test func aPaneTooSmallForTheCardGetsTheRing() {
        #expect(Rules.style(paneSize: CGSize(width: 280, height: 160)) == .card)
        #expect(Rules.style(paneSize: CGSize(width: 279, height: 600)) == .ring)
        #expect(Rules.style(paneSize: CGSize(width: 900, height: 159)) == .ring)
    }

    @Test func theCardIsNeverWiderThanItsShareOfThePane() {
        #expect(Rules.cardWidth(paneWidth: 1000, wanted: 100) == 360)
        #expect(Rules.cardWidth(paneWidth: 1000, wanted: 500) == 500)
        #expect(Rules.cardWidth(paneWidth: 300, wanted: 500) == 264)
    }

    @Test func theCountdownRoundsUpAndTheBarRunsDown() {
        #expect(Rules.secondsLeft(total: 30, elapsed: 0) == 30)
        #expect(Rules.secondsLeft(total: 30, elapsed: 5.9) == 25)
        #expect(Rules.secondsLeft(total: 30, elapsed: 29.99) == 1)
        #expect(Rules.secondsLeft(total: 30, elapsed: 31) == 0)
        #expect(Rules.barFraction(total: 30, elapsed: 15) == 0.5)
        #expect(Rules.barFraction(total: 30, elapsed: 40) == 0)
    }

    /// The first key is swallowed so it does not reach the worker; ⌘ and ⌃
    /// combinations still go to the system and the menus, and end nothing.
    @Test func theFirstKeyIsSwallowedUnlessItIsACommand() {
        #expect(Rules.key(command: false, control: false) == .swallow)
        #expect(Rules.key(command: true, control: false) == .pass)
        #expect(Rules.key(command: false, control: true) == .pass)
    }

    /// Choosing another tab on the bar leaves the lit one breathing; a click
    /// on the panes ends it.
    @Test func onlyAClickOnThePanesEndsIt() {
        let panes = CGRect(x: 0, y: 0, width: 800, height: 560)
        #expect(Rules.clickEnds(at: CGPoint(x: 400, y: 300), paneArea: panes))
        #expect(!Rules.clickEnds(at: CGPoint(x: 400, y: 580), paneArea: panes))
    }

    /// `pending` and `refused` are different answers, and so are
    /// `other_space` and `refused`.
    @Test func frontSaysWhatWasReadBack() {
        func f(_ active: Bool, _ key: Bool, _ space: Bool, _ mini: Bool, _ wait: Bool) -> Rules.Front {
            Rules.front(appActive: active, windowIsKey: key, onActiveSpace: space, wasMinimized: mini, waitingForWindow: wait)
        }
        #expect(f(true, true, true, false, false) == .yes)
        #expect(f(true, true, true, true, false) == .minimizedRestored)
        #expect(f(false, false, true, false, false) == .refused)
        #expect(f(true, false, false, false, false) == .otherSpace)
        #expect(f(true, false, true, true, true) == .pending)
        #expect(f(false, false, true, true, true) == .pending)
    }

    @Test func theAnswerIsWhatTheInterfaceSays() throws {
        let text = Rules.shownJSON(
            switched: .init(window: false, tab: true, stack: true),
            front: .otherSpace, timerRunning: false, replaced: 4096)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let switched = try #require(object["switched"] as? [String: Bool])
        #expect(switched == ["window": false, "tab": true, "stack": true])
        #expect(object["front"] as? String == "other_space")
        #expect(object["timer"] as? String == "waiting")
        #expect(object["replaced"] as? Int == 4096)
        #expect(Rules.endedJSON(true) == "{\"ended\":true}")
        let refused = try #require(try JSONSerialization.jsonObject(
            with: Data(Rules.refusalJSON(code: "NotShown", message: "a \"quoted\" word").utf8)) as? [String: String])
        #expect(refused == ["code": "NotShown", "message": "a \"quoted\" word"])
    }

    /// Since task 1699 the lit tab's mark is a ring round the tab's dots,
    /// in the same slot: nearest the title, and taking room while lit even
    /// when the tab has no dots.
    @Test func theLitTabsRingIsNearestTheTitleAndOnlyWhileLit() {
        #expect(TabAccessory.Item.allCases.first == .paneDots)
        #expect(!TabAccessory.visibleItems(.init()).contains(.paneDots))
        let lit = TabAccessory.visibleItems(.init(highlighted: true))
        #expect(lit == [.paneDots, .keyEquivalent])
        let dots = TabAccessory.visibleItems(.init(hasDots: true))
        #expect(dots == [.paneDots, .keyEquivalent])
    }
}
