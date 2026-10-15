import Testing
@testable import Ghostty

/// A window tab dragged onto a pane (#1558): when the window is hidden,
/// and when it is taken apart. The tree it makes is `SplitStackTests`'.
struct TabIntoPaneTests {
    @Test func aTabWithATerminalInTheControlRoomIsRefused() {
        #expect(TabIntoPane.refusal(tabHasLentTerminal: true) == .lentToControlRoom)
        #expect(TabIntoPane.refusal(tabHasLentTerminal: false) == nil)
    }

    @Test func theWindowIsHeldOnlyOverAPaneThatWillTakeIt() {
        #expect(TabIntoPane.holdsWindow(overPane: true, refusal: nil))
        // Refused: let go, it is torn off as it always was, and seen.
        #expect(!TabIntoPane.holdsWindow(overPane: true, refusal: .lentToControlRoom))
        #expect(!TabIntoPane.holdsWindow(overPane: false, refusal: nil))
    }

    @Test func theDropWaitsForAppKitToTearTheTabOff() {
        // Taken apart before the tear-off, AppKit's picture of the tab
        // stays on the screen: so not torn off yet is "wait".
        #expect(TabIntoPane.afterRelease(goingIntoPane: true, tornOff: false, ticksSinceRelease: 0) == .wait)
        #expect(TabIntoPane.afterRelease(
            goingIntoPane: true, tornOff: false, ticksSinceRelease: TabIntoPane.tearOffTicks - 1) == .wait)
        #expect(TabIntoPane.afterRelease(goingIntoPane: true, tornOff: true, ticksSinceRelease: 0) == .drop)
        #expect(TabIntoPane.afterRelease(goingIntoPane: true, tornOff: true, ticksSinceRelease: 7) == .drop)
    }

    @Test func aTabNeverTornOffOrNotOverAPaneIsLetGo() {
        // Let go on a tab bar: AppKit moves it and never tears it off.
        #expect(TabIntoPane.afterRelease(
            goingIntoPane: true, tornOff: false, ticksSinceRelease: TabIntoPane.tearOffTicks) == .letGo)
        #expect(TabIntoPane.afterRelease(goingIntoPane: false, tornOff: true, ticksSinceRelease: 0) == .letGo)
        #expect(TabIntoPane.afterRelease(goingIntoPane: false, tornOff: false, ticksSinceRelease: 0) == .letGo)
    }
}
