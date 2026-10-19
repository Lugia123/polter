import Foundation
import Testing
@testable import Ghostty

/// The one rule for a terminal that is in its tab's tree and not in front
/// of the person there (control-room.md, 12.6.2). Not wired in yet.
struct TerminalPresenceTests {
    typealias Presence = TerminalPresence

    @Test func theThreeRowsOfTheTable() {
        // Shown and not lent: as it always has.
        #expect(Presence.ownTabReports(shown: true, lent: false) == .asShown)
        // Behind, not lent: says it is neither visible nor focused.
        #expect(Presence.ownTabReports(shown: false, lent: false) == .hidden)
        // Lent: the control room reports, whether it was in front or behind.
        #expect(Presence.ownTabReports(shown: true, lent: true) == .nothing)
        #expect(Presence.ownTabReports(shown: false, lent: true) == .nothing)
    }

    @Test func thePlaceholderIsDrawnOnlyWhereTheTerminalWouldHaveBeen() {
        #expect(Presence.drawsLentPlaceholder(shown: true, lent: true))
        // Borrowed from behind: its pane is showing something else already.
        #expect(!Presence.drawsLentPlaceholder(shown: false, lent: true))
        #expect(!Presence.drawsLentPlaceholder(shown: true, lent: false))
        #expect(!Presence.drawsLentPlaceholder(shown: false, lent: false))
    }

    @Test func focusFollowsTheTerminalThatComesForward() {
        // The one going behind had the keyboard: the one coming forward has it.
        #expect(Presence.focus("b", afterShowing: "d", inPlaceOf: "b") == "d")
        // Somebody else had it, or nobody: unchanged.
        #expect(Presence.focus("a", afterShowing: "d", inPlaceOf: "b") == "a")
        #expect(Presence.focus(String?.none, afterShowing: "d", inPlaceOf: "b") == nil)
    }

    @Test func aWorkerStackedByTheCoreTakesTheKeyboardFromNobody() {
        // Task 1797: the supervisor ("s") or the person somewhere else has
        // the keyboard, and a worker is stacked onto worker "w": it stays.
        #expect(Presence.focus("s", afterStacking: "n", onto: "w", byPerson: false) == "s")
        #expect(Presence.focus(String?.none, afterStacking: "n", onto: "w", byPerson: false) == nil)
        // The one going behind had it: the new one in the same pane.
        #expect(Presence.focus("w", afterStacking: "n", onto: "w", byPerson: false) == "n")
        // The person's own "new" takes it there, as it always has.
        #expect(Presence.focus("s", afterStacking: "n", onto: "w", byPerson: true) == "n")
    }
}
