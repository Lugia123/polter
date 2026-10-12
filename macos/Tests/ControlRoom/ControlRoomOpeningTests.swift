import Combine
import Foundation
import Testing
@testable import Ghostty

/// Where the control room opens (`ControlRoomRules.selection`), that a row
/// it opened on by itself is not one the person has looked at, and that a
/// terminal it has borrowed is not split (`ControlRoomRules.newSplit`).
struct ControlRoomOpeningTests {
    /// A snapshot with an empty group listed first, a group with an agent
    /// second -- which the core says to open on -- and both unseen.
    private static func snapshot(openOn: String? = "web-app", groups: [String] = ["attic", "web-app"]) -> String {
        let rows = groups.map {
            """
            { "name": "\($0)", "needs_me": false, "unseen": true, "shown": "done_unseen", "text": "做完了，没看",
              "waiter": {"is": "none", "name": ""}, "what": {"form": "none", "lines": []},
              "reason": {"from": "none", "text": "", "missing": null},
              "more": 0, "same_as": null }
            """
        }.joined(separator: ",")
        let open = openOn.map { "\"\($0)\"" } ?? "null"
        return """
        { "rev": 2, "now_ms": 1, "needs_me": 0, "groups_needing_me": 0, "groups_other": \(groups.count),
          "open_on": \(open), "groups": [ \(rows) ] }
        """
    }

    private final class Core {
        var json = ""
        let center = NotificationCenter()
        lazy var feed = ControlRoomFeed(center: center) { [unowned self] buffer, capacity in
            let bytes = Array(self.json.utf8)
            if let buffer, bytes.count + 1 <= capacity {
                for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
                buffer[bytes.count] = 0
            }
            return bytes.count
        }
        func say(_ json: String) {
            self.json = json
            center.post(name: ControlRoomFeed.changed, object: nil)
        }
    }

    private final class Clock {
        var pending: [() -> Void] = []
        func later(_ after: TimeInterval, _ work: @escaping () -> Void) { pending.append(work) }
        func pass() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    // MARK: Where it opens

    @Test func openingWithNothingSelectedStartsOnTheGroupTheCoreNames() {
        let core = Core()
        core.json = Self.snapshot()
        let model = ControlRoomModel(feed: core.feed)
        // Not the first row, which is an empty group: the core's choice.
        #expect(model.list?.rows.first?.id == "attic")
        #expect(model.selection == "web-app")
        #expect(!model.selectionIsThePersons)
    }

    @Test func itStartsThereEvenWhenTheFirstSnapshotComesLater() {
        let core = Core()
        let model = ControlRoomModel(feed: core.feed)
        #expect(model.selection == nil)
        core.say(Self.snapshot())
        #expect(model.selection == "web-app")
    }

    @Test func aSelectionThatStandsIsNotReplaced() {
        let core = Core()
        core.json = Self.snapshot()
        // Kept from before a restart.
        let model = ControlRoomModel(feed: core.feed, selection: "attic")
        #expect(model.selection == "attic")
        #expect(model.selectionIsThePersons)

        // And one the person makes is not replaced by a later snapshot.
        let fresh = ControlRoomModel(feed: core.feed)
        fresh.choose("attic")
        core.say(Self.snapshot(openOn: "web-app"))
        #expect(fresh.selection == "attic")
        #expect(fresh.selectionIsThePersons)
    }

    @Test func aKeptSelectionWhoseGroupIsGoneGivesWayToTheCoresGroup() {
        let core = Core()
        core.json = Self.snapshot()
        let model = ControlRoomModel(feed: core.feed, selection: "long-gone")
        #expect(model.selection == "web-app")
        #expect(!model.selectionIsThePersons)
    }

    @Test func afterOpeningNothingIsSelectedForThePerson() {
        let core = Core()
        core.json = Self.snapshot()
        let model = ControlRoomModel(feed: core.feed)
        model.choose("attic")
        // Their group goes away; the core still names one to open on.
        core.say(Self.snapshot(openOn: "web-app", groups: ["web-app"]))
        #expect(model.selection == nil)

        // And clearing the selection themselves does not bring one back.
        let other = ControlRoomModel(feed: core.feed)
        other.choose(nil)
        core.say(Self.snapshot(openOn: "web-app", groups: ["web-app", "attic"]))
        #expect(other.selection == nil)
    }

    @Test func withNoGroupsNothingIsSelected() {
        let core = Core()
        core.json = Self.snapshot(openOn: nil, groups: [])
        let model = ControlRoomModel(feed: core.feed)
        #expect(model.selection == nil)
        #expect(model.rowBeingLookedAt == nil)
    }

    @Test func theRuleOnItsOwn() {
        let opened = ControlRoomRules.selection(current: nil, opening: true, openOn: "web-app")
        #expect(opened.id == "web-app")
        #expect(!opened.isThePersons)

        let standing = ControlRoomRules.selection(current: "billing", opening: true, openOn: "web-app")
        #expect(standing.id == "billing")
        #expect(standing.isThePersons)

        let later = ControlRoomRules.selection(current: nil, opening: false, openOn: "web-app")
        #expect(later.id == nil)

        let nothing = ControlRoomRules.selection(current: nil, opening: true, openOn: nil)
        #expect(nothing.id == nil)
    }

    // MARK: A row it opened on is not one the person has looked at

    @Test func theRowItOpenedOnIsNotMarkedSeenUntilThePersonSelectsIt() {
        let core = Core()
        core.json = Self.snapshot()
        let model = ControlRoomModel(feed: core.feed)
        let clock = Clock()
        var seen: [String] = []
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { true }, markSeen: { seen.append($0) })

        // What the controller does on every selection change and every
        // time the control room comes to the front.
        tracker.selectionChanged(to: model.rowBeingLookedAt)
        clock.pass()
        tracker.selectionChanged(to: model.rowBeingLookedAt)
        clock.pass()
        #expect(model.selection == "web-app")
        #expect(seen.isEmpty)

        // The person presses the row that is already selected.
        var told = 0
        model.onChoose = { told += 1 }
        model.choose("web-app")
        #expect(told == 1)
        tracker.selectionChanged(to: model.rowBeingLookedAt)
        clock.pass()
        #expect(seen == ["web-app"])
    }

    @Test func movingToAnotherRowWithTheKeyboardIsThePersonsToo() {
        let core = Core()
        core.json = Self.snapshot()
        let model = ControlRoomModel(feed: core.feed)
        model.choose("attic")
        #expect(model.selectionIsThePersons)
        #expect(model.rowBeingLookedAt?.id == "attic")
    }

    // MARK: A borrowed terminal is not split

    @Test func aTerminalTheControlRoomHasIsNotSplit() {
        // From a key: refused, and the person hears it.
        #expect(ControlRoomRules.newSplit(lent: true, answerWanted: false) == .refuseAloud)
        // Asked through the core: refused, and the core answers whoever asked.
        #expect(ControlRoomRules.newSplit(lent: true, answerWanted: true) == .refuseToTheCore)
        // In its own tab it splits as it always did.
        #expect(ControlRoomRules.newSplit(lent: false, answerWanted: false) == .split)
        #expect(ControlRoomRules.newSplit(lent: false, answerWanted: true) == .split)
    }
}
