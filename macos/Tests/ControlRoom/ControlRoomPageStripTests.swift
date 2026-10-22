import Foundation
import Testing
@testable import Ghostty

/// The same expectations as the Windows host's `rightpage` tests: the two
/// hosts' page strips are held to one set of numbers.
struct PageStripTests {
    typealias L = ControlRoomPageStripLayout
    let wants: [CGFloat] = [L.nominalWant("总管", marked: true), L.nominalWant("群聊", marked: false),
                            L.nominalWant("任务", marked: false), L.nominalWant("性能", marked: true)]

    @Test func testFourTabsInOrderFromTheInsetEachAsWideAsItWants() {
        let s = L(width: 900, wants: wants, current: .supervisor)
        #expect(s.tabs.map(\.page) == ControlRoomPage.allCases)
        #expect(s.tabs.map(\.width) == [78, 56, 56, 78])
        #expect(same(s.tabs[0].x, 4 + 20))
        for (a, b) in zip(s.tabs, s.tabs.dropFirst()) { #expect(a.x + a.width == b.x) }
        #expect(s.tabs.allSatisfy { $0.y == 4 && $0.height == 28 && !$0.squeezed })
        let last = s.tabs[3]
        #expect(s.status.x == last.x + last.width + 8)
        #expect(same(s.status.x + s.status.width, 900 - 4 - 12))
    }

    @Test func testSeparatorsOnlyBetweenTwoTabsNeitherInFront() {
        let s = L(width: 900, wants: wants, current: .tasks)
        #expect(s.tabs.map(\.separatorBefore) == [false, true, false, false])
        #expect(s.tabs.filter(\.current).map(\.page) == [.tasks])
    }

    @Test func testAPressOnATabIsItsPageAndBetweenOrBelowThemIsNone() {
        let s = L(width: 900, wants: wants, current: .supervisor)
        for t in s.tabs {
            #expect(s.page(at: CGPoint(x: t.x + 1, y: t.y + 1)) == t.page)
            #expect(s.page(at: CGPoint(x: t.x + t.width - 0.5, y: t.y + t.height - 0.5)) == t.page)
        }
        #expect(s.page(at: CGPoint(x: s.tabs[0].x - 1, y: 10)) == nil)
        #expect(s.page(at: CGPoint(x: s.tabs[0].x + 1, y: 2)) == nil)
        #expect(s.page(at: CGPoint(x: s.tabs[0].x + 1, y: 33)) == nil)
    }

    @Test func testTooNarrowTheOthersGiveWayAndTheOneInFrontDoesNot() {
        let width = 2 * 4 + 20 + 12 + wants[3] + 3 * 50
        let s = L(width: width, wants: wants, current: .performance)
        #expect(s.tabs[3].width == wants[3])
        #expect(!(s.tabs[3].squeezed))
        #expect(s.tabs[..<3].allSatisfy { $0.squeezed && $0.width >= L.least })
        let tight = L(width: 2 * 4 + 20 + 12 + 3 * L.least + 30, wants: wants, current: .performance)
        #expect(tight.tabs[..<3].allSatisfy { $0.width == L.least })
        #expect(same(tight.tabs[3].width, 30))
        #expect(same(tight.status.width, 0))
    }

    @Test func testTheStripIsTheBarSoTheTerminalDoesNotMove() {
        #expect(ControlRoomLook.StackTab.stripHeight == ControlRoomLook.Pane.barHeight)
    }

    @Test func testEveryLevelIsReadAnUnknownOneIsNotAndOnlyPastOkHasInk() throws {
        struct Box: Decodable { var l: ControlRoomResourceLevel }
        for l in ControlRoomResourceLevel.allCases {
            let b = try JSONDecoder().decode(Box.self, from: Data("{\"l\":\"\(l.rawValue)\"}".utf8))
            #expect(b.l == l)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Box.self, from: Data("{\"l\":\"warn9\"}".utf8)) }
        let t = ControlRoomLook.theme(dark: true)
        #expect(ControlRoomResourceLevel.none.ink(t) == nil)
        #expect(ControlRoomResourceLevel.ok.ink(t) == nil)
        #expect(ControlRoomResourceLevel.warn3.ink(t)?.base == t.levelWarn3)
        #expect(ControlRoomResourceLevel.withheld.ink(t)?.text == t.levelWithheldText)
        #expect(ControlRoomResourceLevel.killed.ink(t)?.edge == t.levelKilledEdge)
    }
}

/// Both sides one type, so that a literal takes the other side's -- what
/// XCTAssertEqual's one generic parameter did.
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
