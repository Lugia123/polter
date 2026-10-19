import Testing
@testable import Ghostty

/// The Dock's badge is set only when it changes (task 1873).
///
/// Each answer is taken into a constant before it is expected: `#expect`
/// cannot call a mutating member, and the constant names the step.
@Suite
struct DockBadgeTests {
    /// Snapshot after snapshot with the same count: set once.
    @Test func theSameLabelAgainIsNotSetAgain() {
        var badge = ControlRoomRules.DockBadge()
        let first = badge.needsSetting("3")
        #expect(first)
        let again = badge.needsSetting("3")
        #expect(!again)
        let thirdTime = badge.needsSetting("3")
        #expect(!thirdTime)
        #expect(badge.shown == "3")
    }

    /// A change is set, and so is taking it away; and no badge at the
    /// start is set once too, so a badge left from before is cleared.
    @Test func aChangeIsSetEachTime() {
        var badge = ControlRoomRules.DockBadge()
        let none = badge.needsSetting(nil)
        #expect(none)
        let noneAgain = badge.needsSetting(nil)
        #expect(!noneAgain)
        let one = badge.needsSetting("1")
        #expect(one)
        let two = badge.needsSetting("2")
        #expect(two)
        let cleared = badge.needsSetting(nil)
        #expect(cleared)
        #expect(badge.shown == nil)
    }
}
