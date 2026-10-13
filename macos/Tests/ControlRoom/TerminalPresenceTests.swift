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
}
