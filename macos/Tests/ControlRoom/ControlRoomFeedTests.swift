import AppKit
import Combine
import Foundation
import Testing
@testable import Ghostty

/// A stand-in for `ghostty_app_control_snapshot`: writes when it fits, one
/// NUL after, and always returns the real length. `reads` counts how many
/// times the snapshot was asked for (each read is a length call and then a
/// bytes call).
private final class FakeCore {
    var json = ""
    var calls: [Int] = []
    var reads: Int { calls.filter { $0 == 0 }.count }

    func fetch(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
        calls.append(capacity)
        let bytes = Array(json.utf8)
        if let buffer, bytes.count + 1 <= capacity {
            for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
            buffer[bytes.count] = 0
        }
        return bytes.count
    }
}

private func snapshot(more: Int = 11, groups: String = "billing") -> String {
    """
    { "rev": 2, "now_ms": 1, "needs_me": 1, "groups_needing_me": 1, "groups_other": 0, "groups": [
      { "name": "\(groups)", "needs_me": true, "unseen": false, "shown": "needs_you", "text": "等回答",
        "waiter": {"is": "supervisor", "name": ""},
        "reason": {"from": "hook_detail", "text": "「发票编号要按租户分开吗？」", "missing": null},
        "what": {"cut": "none", "form": "words", "lines": ["「发票编号要按租户分开吗？」"]},
        "more": \(more), "same_as": null } ] }
    """
}

/// The one snapshot everybody draws from: fetched when the core says so,
/// once, however many are listening.
struct ControlRoomFeedTests {
    @Test func theCoresBytesComeBackWholeIncludingWhatIsNotAscii() {
        let core = FakeCore()
        core.json = snapshot()
        let data = ControlRoomFeed.read(core.fetch)
        #expect(data == Data(core.json.utf8))
        // Asked for the length, then for the bytes with room for the NUL.
        #expect(core.calls == [0, core.json.utf8.count + 1])
    }

    @Test func zeroBytesFromTheCoreIsNoSnapshotAndNotAnEmptyOne() {
        let core = FakeCore()
        let data = ControlRoomFeed.read(core.fetch)
        #expect(data == nil)
        let feed = ControlRoomFeed(center: NotificationCenter(), fetch: core.fetch)
        #expect(feed.latest == nil)
        let model = ControlRoomModel(feed: feed, selection: "billing")
        #expect(model.list == nil)
        // The selection kept from last time waits for a list to check it against.
        #expect(model.selection == "billing")
    }

    @Test func aSnapshotThisBuildCannotReadChangesNothing() {
        let center = NotificationCenter()
        let core = FakeCore()
        core.json = snapshot()
        let feed = ControlRoomFeed(center: center, fetch: core.fetch)
        let model = ControlRoomModel(feed: feed)
        #expect(model.list?.waiting.first?.others == 11)

        core.json = #"{"rev": 3, "groups": "not a list"}"#
        center.post(name: ControlRoomFeed.changed, object: nil)
        #expect(model.list?.waiting.first?.others == 11)
        core.json = ""
        center.post(name: ControlRoomFeed.changed, object: nil)
        #expect(model.list?.waiting.first?.others == 11)
    }

    @Test func itFetchesOnTheNoticeAndOnlyThen() {
        let center = NotificationCenter()
        let core = FakeCore()
        core.json = snapshot()
        let feed = ControlRoomFeed(center: center, fetch: core.fetch)
        let model = ControlRoomModel(feed: feed)
        #expect(core.reads == 1)
        #expect(model.list?.waiting.first?.others == 11)

        // The core's bytes change and nobody says so: nothing is fetched.
        core.json = snapshot(more: 12)
        #expect(core.reads == 1)
        #expect(model.list?.waiting.first?.others == 11)

        center.post(name: ControlRoomFeed.changed, object: nil)
        #expect(core.reads == 2)
        #expect(model.list?.waiting.first?.others == 12)

        // Another notification altogether is not a notice.
        center.post(name: Notification.Name("something-else"), object: nil)
        #expect(core.reads == 2)
    }

    @Test func oneFetchServesEveryListenerHoweverMany() {
        // The control room and nine terminal windows' tabs: ten listeners.
        let center = NotificationCenter()
        let core = FakeCore()
        core.json = snapshot()
        let feed = ControlRoomFeed(center: center, fetch: core.fetch)
        var heard = [Int](repeating: 0, count: 10)
        let tokens = (0..<10).map { n in feed.listen { _ in heard[n] += 1 } }
        // Arriving is not a reason to fetch: each was handed what was there.
        #expect(core.reads == 1)
        #expect(heard == [Int](repeating: 1, count: 10))

        for _ in 0..<3 { center.post(name: ControlRoomFeed.changed, object: nil) }
        #expect(core.reads == 4)
        #expect(heard == [Int](repeating: 4, count: 10))
        #expect(tokens.count == 10)
    }

    @Test func aListenerThatLetGoIsNotToldAgain() {
        let center = NotificationCenter()
        let core = FakeCore()
        core.json = snapshot()
        let feed = ControlRoomFeed(center: center, fetch: core.fetch)
        var heard = 0
        var token: AnyCancellable? = feed.listen { _ in heard += 1 }
        #expect(heard == 1)
        token = nil
        center.post(name: ControlRoomFeed.changed, object: nil)
        #expect(heard == 1)
        #expect(token == nil)
    }

    @Test @MainActor func nothingFetchesWhileNothingIsSaid() {
        // Half a second with the run loop turning, which is what a timer
        // needs in order to fire. (Sleeping instead proves nothing: with no
        // run loop running, a timer would never fire either.)
        let core = FakeCore()
        core.json = snapshot()
        let feed = ControlRoomFeed(center: NotificationCenter(), fetch: core.fetch)
        let model = ControlRoomModel(feed: feed)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        #expect(core.reads == 1)
        #expect(model.list != nil)
    }

    @Test func aSelectedGroupThatIsNoLongerListedIsDeselected() {
        let center = NotificationCenter()
        let core = FakeCore()
        core.json = snapshot()
        let feed = ControlRoomFeed(center: center, fetch: core.fetch)
        let model = ControlRoomModel(feed: feed, selection: "billing")
        #expect(model.selection == "billing")
        core.json = snapshot(groups: "infra")
        center.post(name: ControlRoomFeed.changed, object: nil)
        #expect(model.selection == nil)
    }
}

/// Which glyph a window tab carries and which one breathes.
struct ControlRoomTabStatusTests {
    typealias Pulse = ControlRoomSnapshot.Pulse
    let window = "0x0000000000000010"

    private func fixture() throws -> ControlRoomSnapshot {
        try JSONDecoder().decode(ControlRoomSnapshot.self, from: ControlRoomListTests.fixture())
    }

    @Test func aTabCarriesTheGlyphTheCoreGivesIt() throws {
        let snap = try fixture()
        let waiting = ControlRoomPulse.status(ofTab: "0x0000000000000021", inWindow: window, showing: nil, in: snap)
        #expect(waiting.shown == .needsYou)
        let trouble = ControlRoomPulse.status(ofTab: "0x0000000000000023", inWindow: window, showing: nil, in: snap)
        #expect(trouble.shown == .trouble)
        let unseen = ControlRoomPulse.status(ofTab: "0x0000000000000024", inWindow: window, showing: nil, in: snap)
        #expect(unseen.shown == .doneUnseen)
        let quiet = ControlRoomPulse.status(ofTab: "0x0000000000000025", inWindow: window, showing: nil, in: snap)
        #expect(quiet == .none)
    }

    @Test func aTabTheSnapshotDoesNotListAndNoSnapshotAtAllCarryNothing() throws {
        let snap = try fixture()
        let unlisted = ControlRoomPulse.status(ofTab: "0x00000000000000ff", inWindow: window, showing: nil, in: snap)
        #expect(unlisted == .none)
        let nothing = ControlRoomPulse.status(ofTab: "0x0000000000000021", inWindow: window, showing: nil, in: nil)
        #expect(nothing == .none)
    }

    @Test func theTabThatBreathesIsTheFirstInTheListNotInTheTabInFront() throws {
        // The core's list starts: tab …22 (billing), then tab …21 (web-app).
        let snap = try fixture()
        func breathes(_ tab: String, showing: String?) -> Bool {
            ControlRoomPulse.status(ofTab: tab, inWindow: window, showing: showing, in: snap).pulses
        }
        // A third tab in front: the longest-waiting one breathes, and only it.
        let far = "0x0000000000000025"
        #expect(breathes("0x0000000000000022", showing: far))
        #expect(!breathes("0x0000000000000021", showing: far))
        // The longest-waiting one is in front: it is being looked at, so the
        // next one breathes instead.
        let front = "0x0000000000000022"
        #expect(!breathes("0x0000000000000022", showing: front))
        #expect(breathes("0x0000000000000021", showing: front))
    }

    @Test func aWaitingTerminalInAnotherWindowDoesNotBreatheHere() {
        let pulses = [
            Pulse(terminal: "0xa", window: "0xw2", tab: "0xt9", group: nil),
            Pulse(terminal: "0xb", window: "0xw1", tab: "0xt1", group: nil),
        ]
        let here = ControlRoomPulse.first(of: pulses, inWindow: "0xw1", notIn: "0xt5")
        #expect(here?.tab == "0xt1")
        let there = ControlRoomPulse.first(of: pulses, inWindow: "0xw2", notIn: "0xt5")
        #expect(there?.tab == "0xt9")
        let nowhere = ControlRoomPulse.first(of: pulses, inWindow: "0xw3", notIn: nil)
        #expect(nowhere == nil)
    }

    @Test func idsAreSpelledTheWayTheCoreSpellsThem() {
        #expect(ControlRoomPulse.id(0x10) == "0x0000000000000010")
        #expect(ControlRoomPulse.id(0) == "0x0000000000000000")
        #expect(ControlRoomPulse.id(UInt64.max) == "0xffffffffffffffff")
    }

    // MARK: What a window tab's accessory shows

    @Test func aWindowTabDrawsTheThreeThatWantALookAndNotWorking() {
        #expect(TabAccessory.drawsOnWindowTab(.needsYou))
        #expect(TabAccessory.drawsOnWindowTab(.trouble))
        #expect(TabAccessory.drawsOnWindowTab(.doneUnseen))
        #expect(!TabAccessory.drawsOnWindowTab(.none))
        // The look table's switch, which is off (and marked tentative there).
        #expect(ControlRoomLook.WindowTab.workingGlyphShown == false)
        #expect(!TabAccessory.drawsOnWindowTab(.working))
    }

    @Test func theStatusIsLastAndTheMarkAndTheShortcutHintStayBesideIt() {
        let visible = TabAccessory.visibleItems(.init(poltergeistMark: "⚑ ", status: .needsYou))
        #expect(visible == [.colorIndicator, .poltergeistMark, .keyEquivalent, .status])
        let working = TabAccessory.visibleItems(.init(status: .working))
        #expect(working == [.colorIndicator, .keyEquivalent])
        let plain = TabAccessory.visibleItems(.init())
        #expect(plain == [.colorIndicator, .keyEquivalent])
    }
}

/// Looking at a row for a moment marks its group seen.
struct ControlRoomSeenTests {
    /// Holds what was deferred, so the test decides when the moment passes.
    private final class Clock {
        var pending: [(TimeInterval, () -> Void)] = []
        func later(_ after: TimeInterval, _ work: @escaping () -> Void) { pending.append((after, work)) }
        func pass() {
            let due = pending
            pending = []
            due.forEach { $0.1() }
        }
    }

    private func row(_ id: String, unseen: Bool = true) -> ControlRoomList.Row {
        .init(id: id, shown: .doneUnseen, word: "", waiter: .none, what: .none,
              others: 0, pulses: false, unseen: unseen)
    }

    @Test func aRowLookedAtForTheDwellIsMarkedSeenOnce() {
        let clock = Clock()
        var seen: [String] = []
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { true }, markSeen: { seen.append($0) })
        tracker.selectionChanged(to: row("infra"))
        // Nothing until the moment has passed.
        #expect(seen.isEmpty)
        #expect(clock.pending.map(\.0) == [1.5])
        clock.pass()
        #expect(seen == ["infra"])
        clock.pass()
        #expect(seen == ["infra"])
    }

    @Test func aRowThatStopsWhileThePersonIsOnItIsSeenAfterTheSameWait() {
        let clock = Clock()
        var seen: [String] = []
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { true }, markSeen: { seen.append($0) })
        // Selected while it is still working: nothing to wait for.
        tracker.selectionChanged(to: row("billing", unseen: false))
        #expect(clock.pending.isEmpty)
        tracker.listChanged(to: row("billing", unseen: false))
        #expect(clock.pending.isEmpty)
        // It finishes, the selection not having moved.
        tracker.listChanged(to: row("billing"))
        #expect(seen.isEmpty)
        #expect(clock.pending.map(\.0) == [1.5])
        // More lists arrive before the moment has passed: it is not begun again.
        tracker.listChanged(to: row("billing"))
        tracker.listChanged(to: row("billing"))
        #expect(clock.pending.map(\.0) == [1.5])
        clock.pass()
        #expect(seen == ["billing"])
        // Seen, then it stops a second time: a second moment.
        tracker.listChanged(to: row("billing", unseen: false))
        tracker.listChanged(to: row("billing"))
        clock.pass()
        #expect(seen == ["billing", "billing"])
    }

    @Test func aRowThatStopsBehindSomethingElseOrAfterThePersonMovedOnIsNotSeen() {
        let clock = Clock()
        var seen: [String] = []
        var inFront = false
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { inFront }, markSeen: { seen.append($0) })
        tracker.selectionChanged(to: row("billing", unseen: false))
        // It stops while the control room is not in front.
        tracker.listChanged(to: row("billing"))
        clock.pass()
        #expect(seen.isEmpty)

        // In front now; it stops, and the person moves to another row
        // before the moment has passed.
        inFront = true
        tracker.selectionChanged(to: row("infra", unseen: false))
        tracker.listChanged(to: row("infra"))
        tracker.selectionChanged(to: row("notes", unseen: false))
        clock.pass()
        #expect(seen.isEmpty)

        // A row the person did not select is handed in as none, whatever
        // it does: nothing is waited for.
        tracker.selectionChanged(to: nil)
        tracker.listChanged(to: nil)
        #expect(clock.pending.isEmpty)
        // A list in which the selection is another row is a change of
        // selection, with its own moment.
        tracker.listChanged(to: row("web-app"))
        clock.pass()
        #expect(seen == ["web-app"])
    }

    @Test func whileTheControlRoomIsNotInFrontNothingIsMarked() {
        let clock = Clock()
        var seen: [String] = []
        var inFront = false
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { inFront }, markSeen: { seen.append($0) })
        tracker.selectionChanged(to: row("infra"))
        clock.pass()
        #expect(seen.isEmpty)

        // Coming to the front starts the moment again; it is not owed from before.
        inFront = true
        tracker.selectionChanged(to: row("infra"))
        #expect(seen.isEmpty)
        clock.pass()
        #expect(seen == ["infra"])
    }

    @Test func arrowingPastARowDoesNotMarkIt() {
        let clock = Clock()
        var seen: [String] = []
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { true }, markSeen: { seen.append($0) })
        tracker.selectionChanged(to: row("infra"))
        tracker.selectionChanged(to: row("notes"))
        clock.pass()
        #expect(seen == ["notes"])
    }

    @Test func leavingAndComingBackToARowStartsItsMomentAgain() {
        let clock = Clock()
        var seen: [String] = []
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { true }, markSeen: { seen.append($0) })
        tracker.selectionChanged(to: row("infra"))
        tracker.selectionChanged(to: nil)
        tracker.selectionChanged(to: row("infra"))
        // Two deferred calls are waiting; only the one made for the
        // selection that still stands may speak.
        #expect(clock.pending.count == 2)
        clock.pass()
        #expect(seen == ["infra"])
    }

    @Test func aRowTheCoreDoesNotCallUnseenIsNotReported() {
        let clock = Clock()
        var seen: [String] = []
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5, later: clock.later, isInFront: { true }, markSeen: { seen.append($0) })
        tracker.selectionChanged(to: row("web-app", unseen: false))
        #expect(clock.pending.isEmpty)
        clock.pass()
        #expect(seen.isEmpty)
    }

    @Test func theDwellIsTheLookTables() {
        let clock = Clock()
        let tracker = ControlRoomSeenTracker(later: clock.later, isInFront: { true }, markSeen: { _ in })
        tracker.selectionChanged(to: row("infra"))
        #expect(clock.pending.map(\.0) == [ControlRoomLook.Selection.seenAfter])
    }
}

/// The requests the control room makes of the core, and what a refusal says.
struct ControlRoomActionsTests {
    typealias Actions = ControlRoomActions
    private let target = ControlRoomList.Target(terminal: "0x00000000000000a1", sinceMs: 5_760_000, eventMs: 5_990_000)

    private func sent(_ act: Actions.Act, answer: String? = nil) throws -> (json: [String: Any], thrown: Actions.Refusal?) {
        var captured = Data()
        let actions = Actions { json in
            captured = json
            return answer
        }
        var thrown: Actions.Refusal?
        do { try actions.perform(act) } catch let refusal as Actions.Refusal { thrown = refusal }
        let object = try JSONSerialization.jsonObject(with: captured) as? [String: Any]
        return (object ?? [:], thrown)
    }

    @Test func seenAndSnoozeNameTheGroup() throws {
        let seen = try sent(.seen(group: "infra")).json
        #expect(seen["act"] as? String == "seen")
        #expect(seen["group"] as? String == "infra")
        #expect(seen.count == 2)

        let snooze = try sent(.snooze(group: "infra")).json
        #expect(snooze["act"] as? String == "snooze")
        #expect(snooze["until_ms"] == nil)
        let until = try sent(.snooze(group: "infra", untilMs: 1_700_000_000_000)).json
        #expect(until["until_ms"] as? UInt64 == 1_700_000_000_000)
        let back = try sent(.unsnooze(group: "infra")).json
        #expect(back["act"] as? String == "unsnooze")
    }

    @Test func approveAndRefuseHandBackBothMomentsExactlyAsTheyCame() throws {
        for (act, word) in [(Actions.Act.approve(target), "approve"), (.refuse(target), "refuse")] {
            let json = try sent(act).json
            #expect(json["act"] as? String == word)
            #expect(json["terminal"] as? String == "0x00000000000000a1")
            #expect(json["since_ms"] as? UInt64 == 5_760_000)
            #expect(json["event_ms"] as? UInt64 == 5_990_000)
        }
    }

    @Test func aReplyCarriesItsTextAndTheStateItAnswers() throws {
        let json = try sent(.reply(target, text: "按租户分开")).json
        #expect(json["act"] as? String == "reply")
        #expect(json["text"] as? String == "按租户分开")
        #expect(json["since_ms"] as? UInt64 == 5_760_000)
        #expect(json["event_ms"] == nil)
    }

    @Test func doneSaysNothingAndARefusalIsThrownByName() throws {
        let done = try sent(.approve(target), answer: nil).thrown
        #expect(done == nil)
        let gone = try sent(.approve(target), answer: "PromptGone").thrown
        #expect(gone?.name == "PromptGone")
        // Refused with no name written is still a refusal.
        let blank = try sent(.approve(target), answer: "").thrown
        #expect(blank != nil)
    }

    @Test func everyRefusalTheCoreListsHasItsOwnSentence() {
        let names = ["PromptGone", "NothingToReplyTo", "Stale", "EmptyText", "UserPresent", "DraftInLine",
                     "ChildExited", "KeyFailed", "UnknownTerminal", "NoSuchGroup", "SnoozeInThePast"]
        let messages = names.map { Actions.Refusal(name: $0).message }
        // Each has a sentence of its own, and none is the catch-all (which
        // would have its name in it).
        #expect(Set(messages).count == names.count)
        for (name, message) in zip(names, messages) {
            #expect(!message.isEmpty)
            #expect(!message.contains(name))
        }
    }

    @Test func aRefusalThisBuildHasNoSentenceForStillNamesItself() {
        let message = Actions.Refusal(name: "SomethingNew").message
        #expect(message.contains("SomethingNew"))
    }
}

/// Making a group and starting a supervisor from the control room: what is
/// asked of the core, what a refusal says, and what the core's answer
/// about a group's supervisor becomes.
struct ControlRoomStartTests {
    typealias Actions = ControlRoomActions

    private func sent(_ act: Actions.Act) throws -> [String: Any] {
        var captured = Data()
        try Actions { json in
            captured = json
            return nil
        }.perform(act)
        return try #require(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
    }

    @Test func aNewGroupIsAskedForByTheNameAsTyped() throws {
        let json = try sent(.newGroup(name: " web-app "))
        #expect(json["act"] as? String == "new_group")
        // Trimming and checking are the core's.
        #expect(json["name"] as? String == " web-app ")
        #expect(json.count == 2)
    }

    @Test func startingASupervisorSendsOnlyWhatThePersonPicked() throws {
        let plain = try sent(.startSupervisor(group: "nightly"))
        #expect(plain["act"] as? String == "start_supervisor")
        #expect(plain["group"] as? String == "nightly")
        // Neither picked: the core uses what its snapshot named.
        #expect(plain.count == 2)

        let picked = try sent(.startSupervisor(group: "nightly", role: "night-lead", cwd: "/work/repo"))
        #expect(picked["role"] as? String == "night-lead")
        #expect(picked["cwd"] as? String == "/work/repo")
    }

    @Test func everyRefusalOfTheTwoHasASentenceThatIsNotTheCatchAll() {
        let names = ["BadName", "GroupExists", "TooManyGroups", "HasSupervisor", "AlreadyStarting",
                     "NoSupervisorRole", "NoSuchPersona", "NotASupervisorRole", "NoCli",
                     "NoSuchDirectory", "OpenFailed", "NoExecutable"]
        let messages = names.map { Actions.Refusal(name: $0).message }
        #expect(Set(messages).count == names.count)
        for (name, message) in zip(names, messages) {
            #expect(!message.isEmpty)
            #expect(!message.contains(name))
        }
        // The three ways a directory is not one say the same thing.
        let absolute = Actions.Refusal(name: "NotAbsolute").message
        #expect(absolute == Actions.Refusal(name: "NoSuchDirectory").message)
        #expect(absolute == Actions.Refusal(name: "NotADirectory").message)
    }

    private static func supervised(groups: [(name: String, supervisor: String)], roles: String, choose: Bool) -> String {
        let rows = groups.map { group in
            """
            { "name": "\(group.name)", "needs_me": false, "unseen": false, "shown": "none", "text": "",
              "supervisor": \(group.supervisor),
              "waiter": {"is": "none", "name": ""},
              "reason": {"from": "none", "text": "", "missing": null},
              "what": {"cut": "none", "form": "none", "lines": []},
              "more": 0, "same_as": null }
            """
        }.joined(separator: ",")
        return """
        { "rev": 2, "now_ms": 1, "needs_me": 0, "groups_needing_me": 0, "groups_other": \(groups.count),
          "groups": [\(rows)], "supervisor_roles": \(roles), "choose_supervisor_role": \(choose) }
        """
    }

    private static let absent = """
    {"state":"absent","can_start":true,"terminal":null,"failed":"none",
     "role":"polter-supervisor","cwd":"/work/repo","cwd_from":"last_supervisor"}
    """

    @Test func whatTheCoreSaysAboutAGroupsSupervisorIsCopiedAndNothingIsWorkedOut() throws {
        let failed = """
        {"state":"failed","can_start":true,"terminal":"0x00000000000000a9","failed":"agent_never_connected",
         "role":"polter-supervisor","cwd":"","cwd_from":"none"}
        """
        // "Starting" with the button still offered is not a state the core
        // writes; it is here to show the button follows `can_start` alone.
        let odd = """
        {"state":"starting","can_start":true,"terminal":null,"failed":"none","role":null,"cwd":"","cwd_from":"none"}
        """
        let json = Self.supervised(
            groups: [("nightly", Self.absent), ("billing", failed), ("odd", odd)],
            roles: #"[{"key":"polter-supervisor","name":"Polter Supervisor"},{"key":"night-lead","name":"Night Lead"}]"#,
            choose: true)
        let list = try ControlRoomList.decode(snapshot: Data(json.utf8))

        let nightly = try #require(list.rows.first { $0.id == "nightly" }?.start)
        #expect(nightly.state == .absent)
        #expect(nightly.canStart)
        #expect(nightly.role == "polter-supervisor")
        #expect(nightly.cwd == "/work/repo")

        let billing = try #require(list.rows.first { $0.id == "billing" }?.start)
        #expect(billing.state == .failed)
        #expect(billing.failed == .agentNeverConnected)
        #expect(billing.canStart)

        let strange = try #require(list.rows.first { $0.id == "odd" }?.start)
        #expect(strange.state == .starting)
        #expect(strange.canStart)
        #expect(strange.role == nil)

        #expect(list.supervisorRoles.map(\.key) == ["polter-supervisor", "night-lead"])
        #expect(list.chooseSupervisorRole)
        // A role the person made is shown by the name they gave it.
        #expect(list.supervisorRoles[1].displayName == "Night Lead")
    }

    @Test func aSnapshotFromBeforeASupervisorCouldBeStartedOffersNothing() throws {
        let list = try ControlRoomList.decode(snapshot: Data(snapshot().utf8))
        #expect(list.rows.first?.start == nil)
        #expect(list.supervisorRoles.isEmpty)
        #expect(!list.chooseSupervisorRole)
    }

    @Test func theCoresFixtureSaysEveryGroupHasASupervisorAndNamesOneRole() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        // The rows that are groups. A terminal on its own has a row too
        // since those were listed, and no supervisor to start: it is one,
        // or it has none to be given here.
        let groups = list.rows.filter { $0.alone == nil }
        #expect(groups.count == 8)
        for row in groups {
            let start = try #require(row.start, "\(row.id)")
            #expect(start.state == .present)
            #expect(!start.canStart)
        }
        let alone = list.rows.filter { $0.alone != nil }
        #expect(!alone.isEmpty)
        #expect(alone.allSatisfy { $0.start == nil })
        #expect(list.supervisorRoles.map(\.key) == ["polter-supervisor"])
        #expect(!list.chooseSupervisorRole)
    }

    @Test func theSentenceOnTheRightSaysWhichWaitFailed() {
        typealias Start = ControlRoomList.SupervisorStart
        let detail = ControlRoomLending.Detail.noSupervisor(group: "nightly")
        func words(_ state: Start.State, _ failed: Start.Failure) -> String {
            ControlRoomDetailMessage.words(
                for: detail, start: Start(state: state, canStart: false, failed: failed, role: nil, cwd: ""))
        }
        let all = [
            ControlRoomDetailMessage.words(for: detail),
            words(.absent, .none), words(.starting, .none), words(.failed, .none),
            words(.failed, .terminalNeverOpened), words(.failed, .agentNeverConnected), words(.failed, .terminalClosed),
        ]
        // With nothing said and with "absent" it is the same sentence; the
        // other five are each their own, and none is blank.
        #expect(all[0] == all[1])
        #expect(Set(all).count == 6)
        #expect(all.allSatisfy { !$0.isEmpty })
    }

    @Test func aGroupThePersonMakesIsSelectedWhenTheCoreListsItAndARefusalIsHandedBack() {
        let center = NotificationCenter()
        let core = FakeCore()
        core.json = snapshot()
        // Kept: the model does not hold the feed.
        let feed = ControlRoomFeed(center: center, fetch: core.fetch)
        let model = ControlRoomModel(feed: feed)
        #expect(model.selection == nil)

        // Without the core handed in, nothing is done and that is said.
        #expect(model.newGroup(named: "nightly") != nil)

        var asked: [ControlRoomActions.Act] = []
        var answer: String?
        model.perform = { act in
            asked.append(act)
            if let answer { throw ControlRoomActions.Refusal(name: answer) }
        }

        answer = "GroupExists"
        let refused = model.newGroup(named: "billing")
        #expect(refused == ControlRoomActions.Refusal(name: "GroupExists").message)
        #expect(model.selection == nil)

        answer = nil
        let made = model.newGroup(named: " nightly ")
        #expect(made == nil)
        #expect(asked.last == .newGroup(name: " nightly "))
        // The list on screen is from before it existed: nothing is selected yet.
        #expect(model.selection == nil)

        core.json = snapshot(groups: "nightly")
        center.post(name: ControlRoomFeed.changed, object: nil)
        #expect(model.selection == "nightly")
        #expect(model.selectionIsThePersons)
    }

    @Test func aRefusedStartIsKeptToBeShownAndClearedByOneThatIsTaken() {
        let core = FakeCore()
        core.json = snapshot()
        let model = ControlRoomModel(feed: ControlRoomFeed(center: NotificationCenter(), fetch: core.fetch))
        var answer: String? = "NoSuchDirectory"
        var asked: [ControlRoomActions.Act] = []
        model.perform = { act in
            asked.append(act)
            if let answer { throw ControlRoomActions.Refusal(name: answer) }
        }

        model.startSupervisor(for: "billing", role: nil, cwd: "/gone")
        #expect(model.startRefusal?.group == "billing")
        #expect(model.startRefusal?.message == ControlRoomActions.Refusal(name: "NoSuchDirectory").message)
        #expect(asked.last == .startSupervisor(group: "billing", role: nil, cwd: "/gone"))

        answer = nil
        model.startSupervisor(for: "billing", role: nil, cwd: nil)
        #expect(model.startRefusal == nil)
    }

    @Test func theDirectoryIsShownWithHomeAsATilde() {
        typealias View = ControlRoomStartSupervisor
        #expect(View.shown("/Users/me", home: "/Users/me") == "~")
        #expect(View.shown("/Users/me/work/repo", home: "/Users/me") == "~/work/repo")
        // A sibling whose name only starts the same is not under home.
        #expect(View.shown("/Users/meadow", home: "/Users/me") == "/Users/meadow")
        #expect(View.shown("/srv/app", home: "/Users/me") == "/srv/app")
        #expect(!View.shown("", home: "/Users/me").isEmpty)
    }
}
