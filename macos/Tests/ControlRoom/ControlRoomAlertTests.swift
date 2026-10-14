import Foundation
import Testing
@testable import Ghostty

/// The control room calling the person (task 1505): the words of the
/// notification, what the control room tells the core about where the
/// person is, and which cards count as in sight.
struct ControlRoomAlertTests {
    @Test func theTitleSaysWhichGroupAndWhatItWaitsFor() {
        let approval = ControlRoomAlert.title(kind: .needsApproval, group: "web-app")
        let answer = ControlRoomAlert.title(kind: .needsAnswer, group: "web-app")
        let failed = ControlRoomAlert.title(kind: .failed, group: "web-app")
        for t in [approval, answer, failed] { #expect(t.contains("web-app")) }
        #expect(Set([approval, answer, failed]).count == 3)
    }

    @Test func theBodyNamesTheWorkerAndSaysHowManyMoreGroupsWait() {
        #expect(ControlRoomAlert.body(who: "worker-core", text: "may I push?", more: 0) == "worker-core: may I push?")
        // The supervisor itself has no name to give.
        #expect(ControlRoomAlert.body(who: "", text: " may I push? \n", more: 0) == "may I push?")
        #expect(ControlRoomAlert.body(who: "worker-core", text: "", more: 0) == "worker-core")
        #expect(ControlRoomAlert.body(who: "", text: "", more: 0).isEmpty)
        let one = ControlRoomAlert.body(who: "", text: "x", more: 1).split(separator: "\n")
        #expect(one.count == 2)
        #expect(one[1].contains("1"))
        let three = ControlRoomAlert.body(who: "", text: "x", more: 3).split(separator: "\n")
        #expect(three.count == 2)
        #expect(three[1].contains("3"))
        #expect(one[1] != three[1])
    }

    @Test func presenceIsSaidOnceForEachChangeAndAsTheCoreReadsIt() throws {
        var reporter = ControlRoomAlert.PresenceReporter()
        let said = reporter.report(.init(inFront: true, cards: ["web", "api \"x\""]))
        let first = try #require(said)
        let parsed = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        #expect(parsed?["in_front"] as? Bool == true)
        #expect(parsed?["cards"] as? [String] == ["web", "api \"x\""])
        // The same sight in another order is not news.
        #expect(reporter.report(.init(inFront: true, cards: ["api \"x\"", "web"])) == nil)
        let saidBehind = reporter.report(.init(inFront: false, cards: []))
        let behind = try #require(saidBehind)
        #expect(behind == #"{"in_front":false,"cards":[]}"#)
        #expect(reporter.report(.init(inFront: false, cards: [])) == nil)
        // Byte for byte what the Windows host sends for the same sight
        // (`alert::tests` in windows/control-room).
        #expect(ControlRoomAlert.Presence(inFront: true, cards: ["web", "a \"q\""]).json
                == #"{"in_front":true,"cards":["web","a \"q\""]}"#)
    }

    @Test func inFrontIsTheKeyWindowOfTheActiveApplicationAndNothingMore() {
        #expect(ControlRoomAlert.inFront(appActive: true, windowIsKey: true, closing: false))
        #expect(!ControlRoomAlert.inFront(appActive: false, windowIsKey: true, closing: false))
        #expect(!ControlRoomAlert.inFront(appActive: true, windowIsKey: false, closing: false))
        #expect(!ControlRoomAlert.inFront(appActive: true, windowIsKey: true, closing: true))
    }

    @Test func outOfFrontNoCardIsInSightWhateverTheListHolds() {
        #expect(ControlRoomAlert.Presence.of(inFront: true, cards: ["web"]).cards == ["web"])
        #expect(ControlRoomAlert.Presence.of(inFront: false, cards: ["web"]).cards.isEmpty)
        #expect(ControlRoomAlert.Presence.of(inFront: true, cards: ["web"]).json == #"{"in_front":true,"cards":["web"]}"#)
    }

    @Test func aCardIsInSightWhenItIsWhollyAboveTheBottom() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        let ordered = list.rows.map(\.id)
        let tall = ControlRoomListLayout(list: list, height: 4000)
        // All of them, in the list's order.
        #expect(tall.inSight(order: ordered) == ordered)
        // So short that only the header fits: nothing is in sight.
        let short = ControlRoomListLayout(list: list, height: 10)
        #expect(short.inSight(order: ordered).isEmpty)
        // Cut through the second row: the first is in sight, the second is
        // not -- a card half off the bottom is not one the person can read.
        try #require(ordered.count >= 2)
        let second = try #require(tall.rows[ordered[1]])
        // What the allowance block takes off the bottom does not depend on
        // the height, so the bottom of the cards' room lands mid-row here.
        let taken = tall.size.height - (tall.quota.height > 0 ? tall.quota.minY : tall.size.height)
        let cut = ControlRoomListLayout(list: list, height: second.midY + taken)
        #expect(cut.inSight(order: ordered).contains(ordered[0]))
        #expect(!cut.inSight(order: ordered).contains(ordered[1]))
    }
}

import AppKit
import SwiftUI

/// The list view as the app hosts it, off screen: what it tells the
/// controller about the cards in sight (task 1531).
@MainActor
struct ControlRoomListInSightHostingTests {
    @Test func theHostedListReportsItsCardsInSight() async throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        var reported: [[String]] = []
        let view = ControlRoomListView(list: list, selection: .constant(nil), onInSight: { reported.append($0) })
        let host = NSHostingView(rootView: view.frame(height: 800))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<50 where reported.last?.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
        let ids = list.rows.map(\.id)
        let expected = ControlRoomListLayout(list: list, height: 800).inSight(order: ids)
        #expect(!expected.isEmpty)
        #expect(reported.last == expected, "reports: \(reported)")
    }
}
