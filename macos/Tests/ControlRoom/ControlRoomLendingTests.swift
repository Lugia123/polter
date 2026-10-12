import Foundation
import Testing
@testable import Ghostty

/// The supervisor's terminal goes into the control room and comes back out
/// (`ControlRoomLending`). Run against a world with no views in it: a set of
/// terminals that are in their own tabs, and what the control room holds.
struct ControlRoomLendingTests {
    typealias Lending = ControlRoomLending
    typealias Loan = ControlRoomLending.Loan

    /// Where every terminal is, moved only by doing what `Lending` says.
    private struct World {
        var lending = Lending()
        /// Terminals shown in their own tab (no placeholder there).
        var atHome: Set<String>
        /// What the control room holds, in the order it was put there. A
        /// list and not one slot, so that holding two is something this can
        /// see rather than something it cannot say.
        var inRoom: [String] = []
        /// Terminals whose tab is gone.
        var closed: Set<String> = []
        /// Who was handed the keyboard, in order.
        var focused: [String] = []
        /// Terminals that were put back into a tab that was no longer there.
        var returnedToNowhere: [String] = []

        init(_ terminals: String...) { atHome = Set(terminals) }

        @discardableResult
        mutating func send(_ event: Lending.Event) -> [Lending.Effect] {
            let effects = lending.handle(event)
            for effect in effects {
                switch effect {
                case let .borrow(loan):
                    atHome.remove(loan.terminal)
                    inRoom.append(loan.terminal)
                case let .giveBack(terminal, toHome, focus):
                    if let at = inRoom.firstIndex(of: terminal) { inRoom.remove(at: at) }
                    if toHome {
                        if closed.contains(terminal) { returnedToNowhere.append(terminal) } else { atHome.insert(terminal) }
                    }
                    if focus { focused.append(terminal) }
                }
            }
            return effects
        }

        /// Select `group`, whose supervisor is `supervisor`.
        mutating func select(_ group: String?, _ supervisor: String?) {
            let present = supervisor.map { !closed.contains($0) } ?? false
            send(.selected(group: group, supervisor: supervisor, present: present))
        }

        /// The tab `terminal` lives in is closed.
        mutating func close(_ terminal: String) {
            closed.insert(terminal)
            atHome.remove(terminal)
            send(.homeGone(terminal: terminal))
        }

        /// In how many places `terminal` is.
        func places(_ terminal: String) -> Int {
            inRoom.filter { $0 == terminal }.count + (atHome.contains(terminal) ? 1 : 0)
        }
    }

    // MARK: One place at a time

    @Test func selectingAGroupBringsItsSupervisorIn() {
        var world = World("a1", "a2")
        world.select("web-app", "a1")
        #expect(world.inRoom == ["a1"])
        #expect(world.atHome == ["a2"])
        #expect(world.lending.detail == .terminal(Loan(group: "web-app", terminal: "a1")))
        #expect(world.lending.loan == Loan(group: "web-app", terminal: "a1"))
    }

    @Test func selectingAnotherGroupPutsThePreviousTerminalBackFirst() {
        var world = World("a1", "a2")
        world.select("web-app", "a1")
        let effects = world.send(.selected(group: "billing", supervisor: "a2", present: true))

        // Back before the next one is taken, and without the keyboard: the
        // person is in the list.
        #expect(effects == [
            .giveBack(terminal: "a1", toHome: true, focus: false),
            .borrow(Loan(group: "billing", terminal: "a2")),
        ])
        #expect(world.atHome == ["a1"])
        #expect(world.inRoom == ["a2"])
    }

    @Test func aTerminalIsInExactlyOnePlaceWhateverHappens() {
        var world = World("a1", "a2", "a3")
        let steps: [(inout World) -> Void] = [
            { $0.select("web-app", "a1") },
            { $0.select("web-app-docs", "a1") },      // the same supervisor, another group
            { $0.select("billing", "a2") },
            { $0.send(.reclaimed(terminal: "a2")) },
            { $0.select("billing", "a2") },           // a snapshot arrives; still taken back
            { $0.send(.askedFor) },
            { $0.select("notes", nil) },              // a group with no supervisor
            { $0.select("docs-site", "a3") },
            { $0.select(nil, nil) },
            { $0.select("web-app", "a1") },
            { $0.select("web-app", "a1") },           // the same selection again
            { $0.send(.closing) },
        ]
        for (n, step) in steps.enumerated() {
            step(&world)
            for terminal in ["a1", "a2", "a3"] {
                let places = world.places(terminal)
                #expect(places == 1, "after step \(n), \(terminal) is in \(places) places")
            }
            #expect(world.inRoom.count <= 1, "after step \(n) the control room holds \(world.inRoom)")
            #expect(world.inRoom == (world.lending.loan.map { [$0.terminal] } ?? []), "after step \(n)")
        }
        #expect(world.inRoom.isEmpty)
        #expect(world.atHome == ["a1", "a2", "a3"])
    }

    @Test func oneSupervisorMindingTwoGroupsDoesNotMoveBetweenThem() {
        var world = World("a1")
        world.select("web-app", "a1")
        let effects = world.send(.selected(group: "web-app-docs", supervisor: "a1", present: true))
        #expect(effects == [])
        #expect(world.places("a1") == 1)
        #expect(world.lending.detail == .terminal(Loan(group: "web-app-docs", terminal: "a1")))
    }

    // MARK: Going back

    @Test func outOfSightNothingIsBorrowedAndWhatItSaysIsStillTrue() {
        var world = World("a1", "a2")
        world.select("web-app", "a1")
        #expect(world.inRoom == ["a1"])
        // Behind another tab: the terminal goes home, without the keyboard,
        // and the right side says where it is rather than "select a group".
        let effects = world.send(.outOfSight(group: "web-app", supervisor: "a1", present: true))
        #expect(effects == [.giveBack(terminal: "a1", toHome: true, focus: false)])
        #expect(world.inRoom.isEmpty)
        #expect(world.lending.detail == .takenBack(Loan(group: "web-app", terminal: "a1")))
        // Still out of sight, the selection or the snapshot changes: the
        // sentence follows, and nothing is borrowed.
        #expect(world.send(.outOfSight(group: "notes", supervisor: nil, present: false)) == [])
        #expect(world.lending.detail == .noSupervisor(group: "notes"))
        #expect(world.send(.outOfSight(group: "infra", supervisor: "a9", present: false)) == [])
        #expect(world.lending.detail == .supervisorGone(group: "infra"))
        #expect(world.send(.outOfSight(group: nil, supervisor: nil, present: false)) == [])
        #expect(world.lending.detail == .nothingSelected)
        #expect(world.inRoom.isEmpty)
        // Back in sight: it is borrowed again, not left "taken back" --
        // the person never took it back.
        _ = world.send(.outOfSight(group: "web-app", supervisor: "a1", present: true))
        world.select("web-app", "a1")
        #expect(world.inRoom == ["a1"])
        #expect(world.lending.detail == .terminal(Loan(group: "web-app", terminal: "a1")))
    }

    @Test func closingTheControlRoomPutsTheTerminalBack() {
        var world = World("a1")
        world.select("web-app", "a1")
        let effects = world.send(.closing)
        #expect(effects == [.giveBack(terminal: "a1", toHome: true, focus: false)])
        #expect(world.atHome == ["a1"])
        #expect(world.lending.loan == nil)
        // And closing again, or with nothing borrowed, does nothing.
        #expect(world.send(.closing) == [])
    }

    @Test func askingForItBackFromItsOwnTabReturnsItWithTheKeyboard() {
        var world = World("a1")
        world.select("web-app", "a1")
        let effects = world.send(.reclaimed(terminal: "a1"))
        #expect(effects == [.giveBack(terminal: "a1", toHome: true, focus: true)])
        #expect(world.focused == ["a1"])
        #expect(world.lending.detail == .takenBack(Loan(group: "web-app", terminal: "a1")))

        // The next snapshot must not take it away again.
        world.select("web-app", "a1")
        #expect(world.atHome == ["a1"])
        #expect(world.inRoom.isEmpty)

        // Asking for it here again does; so does coming back to the group
        // after selecting another.
        world.send(.askedFor)
        #expect(world.inRoom == ["a1"])
        world.send(.reclaimed(terminal: "a1"))
        world.select("billing", nil)
        world.select("web-app", "a1")
        #expect(world.inRoom == ["a1"])
    }

    @Test func aRequestForATerminalThatIsNotOnLoanDoesNothing() {
        var world = World("a1", "a2")
        world.select("web-app", "a1")
        #expect(world.send(.reclaimed(terminal: "a2")) == [])
        #expect(world.send(.askedFor) == [])
        #expect(world.inRoom == ["a1"])
    }

    // MARK: Its own tab closed under it

    @Test func aTerminalWhoseTabWasClosedIsLetGoOfAndNotPutBack() {
        var world = World("a1", "a2")
        world.select("web-app", "a1")
        world.close("a1")

        #expect(world.inRoom.isEmpty)
        #expect(world.returnedToNowhere.isEmpty)
        #expect(world.lending.loan == nil)
        #expect(world.lending.detail == .supervisorGone(group: "web-app"))

        // Nothing afterwards tries to return it either.
        world.select("billing", "a2")
        world.send(.closing)
        #expect(world.returnedToNowhere.isEmpty)
        #expect(world.places("a1") == 0)
        #expect(world.atHome == ["a2"])
    }

    @Test func aSupervisorTheSnapshotStillNamesButNoTabHoldsIsLetGoOf() {
        // The tab went and nobody said so; the next look at the selection
        // finds the terminal is not there.
        var world = World("a1")
        world.select("web-app", "a1")
        world.closed.insert("a1")
        let effects = world.send(.selected(group: "web-app", supervisor: "a1", present: false))
        #expect(effects == [.giveBack(terminal: "a1", toHome: false, focus: false)])
        #expect(world.returnedToNowhere.isEmpty)
        #expect(world.lending.detail == .supervisorGone(group: "web-app"))
    }

    @Test func aTabClosedWhileItsTerminalWasTakenBackLeavesNothingToAskFor() {
        var world = World("a1")
        world.select("web-app", "a1")
        world.send(.reclaimed(terminal: "a1"))
        world.close("a1")
        #expect(world.lending.detail == .supervisorGone(group: "web-app"))
        #expect(world.send(.askedFor) == [])
        #expect(world.inRoom.isEmpty)
    }

    // MARK: Nothing to show

    @Test func whatTheRightSideSaysWhenThereIsNoTerminalToShow() {
        var world = World("a1")
        #expect(world.lending.detail == .nothingSelected)

        world.select("notes", nil)
        #expect(world.lending.detail == .noSupervisor(group: "notes"))

        world.closed.insert("gone")
        world.select("infra", "gone")
        #expect(world.lending.detail == .supervisorGone(group: "infra"))
        #expect(world.inRoom.isEmpty)

        world.select(nil, nil)
        #expect(world.lending.detail == .nothingSelected)
    }

    // MARK: Who the supervisor is

    @Test func theSupervisorIsTheOneTheCoreNames() throws {
        let snapshot = try JSONDecoder().decode(ControlRoomSnapshot.self, from: ControlRoomListTests.fixture())
        #expect(snapshot.supervisor(of: "web-app") == "0x00000000000000a1")
        // One supervisor, two groups.
        #expect(snapshot.supervisor(of: "web-app-docs") == "0x00000000000000a1")
        #expect(snapshot.supervisor(of: "billing") == "0x00000000000000a2")
        #expect(snapshot.supervisor(of: "no-such-group") == nil)
    }
}
