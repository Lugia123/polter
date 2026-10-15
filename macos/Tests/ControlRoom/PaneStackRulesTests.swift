import Foundation
import Testing
@testable import Ghostty

/// What a pane that holds a stack draws, out of the tree's stack and the
/// core's snapshot (`PaneStackRules`).
struct PaneStackRulesTests {
    typealias Rules = PaneStackRules
    typealias Member = PaneStackRules.Member

    /// The core's own fixture: seven supervisors, three workers and two
    /// terminals nobody minds.
    private func snapshot() throws -> ControlRoomSnapshot {
        try JSONDecoder().decode(ControlRoomSnapshot.self, from: ControlRoomListTests.fixture())
    }

    private let supervisor = "0x00000000000000a1"
    private let worker = "0x00000000000000b1"
    private let waitingShell = "0x00000000000000c1"
    private let shell = "0x00000000000000c2"

    // MARK: The members

    @Test func everyMemberIsNamedAndDressedByTheCoresWordsForThatTerminal() throws {
        let s = try snapshot()
        let stack = Rules.stack(
            members: [
                Member(terminal: worker, ownName: "its own view's"),
                Member(terminal: supervisor, ownName: ""),
                Member(terminal: shell, ownName: "zsh, said the view"),
            ],
            shown: 1, terminals: s.terminals, pulses: [])
        #expect(stack.members.map(\.wears) == [.worker, .supervisor, .plain])
        // The core's titles, not the views'.
        #expect(stack.members.map(\.name) == ["web-app worker", "web-app", "zsh"])
        #expect(stack.members.map(\.shown) == [.needsYou, .needsYou, .none])
        #expect(stack.current == 1)
        #expect(stack.plainStyle == Rules.Choices.plainStyle)
    }

    @Test func aTerminalTheCoreDoesNotListIsAnOrdinaryOneUnderItsViewsName() throws {
        let s = try snapshot()
        let stack = Rules.stack(
            members: [Member(terminal: nil, ownName: "just opened"), Member(terminal: "0x00000000000000ee", ownName: "unlisted")],
            shown: 0, terminals: s.terminals, pulses: [])
        #expect(stack.members.map(\.name) == ["just opened", "unlisted"])
        #expect(stack.members.map(\.wears) == [.plain, .plain])
        #expect(stack.members.map(\.shown) == [.none, .none])
        // And with no snapshot at all, the same.
        let blind = Rules.stack(members: [Member(terminal: worker, ownName: "w")], shown: 0, terminals: nil, pulses: [])
        #expect(blind.members.map(\.name) == ["w"])
    }

    @Test func aShownIndexThatIsNotOneOfTheMembersIsTheFirst() {
        let stack = Rules.stack(
            members: [Member(terminal: nil, ownName: "a"), Member(terminal: nil, ownName: "b")],
            shown: 7, terminals: nil, pulses: [])
        #expect(stack.current == 0)
    }

    // MARK: Who is waiting behind

    @Test func whoIsMostPressingIsTheCoresOrderKeptToThisStack() throws {
        let members = [
            Member(terminal: shell, ownName: ""),
            Member(terminal: worker, ownName: ""),
            Member(terminal: supervisor, ownName: ""),
        ]
        // The core says: the supervisor first, then somebody not in this
        // stack, then the worker. The shell is not waiting.
        let stack = Rules.stack(
            members: members, shown: 0, terminals: try snapshot().terminals,
            pulses: [supervisor, "0x00000000000000a7", worker])
        #expect(stack.urgent == [2, 1])
        // The other way round is the other way round: nothing here ranks.
        let other = Rules.stack(members: members, shown: 0, terminals: try snapshot().terminals, pulses: [worker, supervisor])
        #expect(other.urgent == [1, 2])
        // Nobody waiting: nobody.
        #expect(Rules.stack(members: members, shown: 0, terminals: nil, pulses: []).urgent.isEmpty)
    }

    // MARK: The frame round it

    @Test func theFrameIsTheOneOfTheMemberInFront() throws {
        let s = try snapshot()
        let members = [Member(terminal: worker, ownName: ""), Member(terminal: supervisor, ownName: ""), Member(terminal: shell, ownName: "")]
        #expect(Rules.Choices.frameFollowsShown)
        #expect(Rules.wears(Rules.stack(members: members, shown: 0, terminals: s.terminals, pulses: [])) == .worker)
        #expect(Rules.wears(Rules.stack(members: members, shown: 1, terminals: s.terminals, pulses: [])) == .supervisor)
        #expect(Rules.wears(Rules.stack(members: members, shown: 2, terminals: s.terminals, pulses: [])) == .plain)
    }

    @Test func anOrdinaryTerminalThatWouldWearNothingStillGetsATitleForItsStrip() throws {
        let s = try snapshot()
        let stack = Rules.stack(
            members: [Member(terminal: shell, ownName: ""), Member(terminal: nil, ownName: "new")],
            shown: 0, terminals: s.terminals, pulses: [])
        // Alone in its tab an ordinary terminal wears nothing...
        let alone = PaneFrame.Place(enabled: true, quickTerminal: false, alone: true)
        #expect(PaneFrame.drawn(terminal: shell, ownName: "", at: alone, in: s.terminals) == nil)
        // ...and holding a stack it wears the plain frame, named for the
        // member in front, with nothing to say.
        #expect(Rules.wears(stack) == .plain)
        let title = Rules.title(stack, framed: nil)
        #expect(title.name == "zsh")
        #expect(title.shown == .none)
        #expect(title.word.isEmpty)
        // A frame it would have worn anyway keeps its own title.
        let own = PaneFrame.Title(name: "kept", shown: .held, word: "held")
        #expect(Rules.title(stack, framed: own) == own)
    }

    // MARK: Along the tabs

    @Test func aStepAlongTheTabsGoesRoundTheEnds() {
        #expect(Rules.neighbour(of: 0, count: 3, by: 1) == 1)
        #expect(Rules.neighbour(of: 2, count: 3, by: 1) == 0)
        #expect(Rules.neighbour(of: 0, count: 3, by: -1) == 2)
        #expect(Rules.neighbour(of: 1, count: 2, by: -1) == 0)
        // Nowhere to go: one terminal, or an index that is not one.
        #expect(Rules.neighbour(of: 0, count: 1, by: 1) == nil)
        #expect(Rules.neighbour(of: 3, count: 3, by: 1) == nil)
        #expect(Rules.neighbour(of: 1, count: 3, by: 3) == nil)
    }

    // MARK: What is on offer

    @Test func aVerbIsOfferedOnlyWhereItHasSomethingToDo() {
        // A new terminal in this pane: anywhere but the quick terminal.
        #expect(Rules.offers(.new, stacked: false, panes: 1, quick: false))
        // Along the tabs and out of the stack: only in a stack.
        for verb in [Rules.Verb.next, .previous, .out] {
            #expect(!Rules.offers(verb, stacked: false, panes: 3, quick: false))
            #expect(Rules.offers(verb, stacked: true, panes: 1, quick: false))
        }
        // Onto a neighbour: only where there is one.
        for verb in [Rules.Verb.ontoNext, .ontoPrevious] {
            #expect(!Rules.offers(verb, stacked: true, panes: 1, quick: false))
            #expect(Rules.offers(verb, stacked: false, panes: 2, quick: false))
        }
        // The quick terminal holds no stacks.
        for verb in Rules.Verb.allCases {
            #expect(!Rules.offers(verb, stacked: true, panes: 3, quick: true))
        }
        #expect(Rules.Verb.allCases.map(\.rawValue) == ["new", "next", "previous", "out", "onto_next", "onto_previous"])
    }
}
