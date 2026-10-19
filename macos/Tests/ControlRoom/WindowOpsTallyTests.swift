import Testing
@testable import Ghostty

/// The minute's line of window operations (task 1873).
@Suite
struct WindowOpsTallyTests {
    /// A quiet minute says nothing: no line, and the clock stops.
    @Test func nothingCountedIsNoLine() {
        #expect(WindowOpsTally.line([:]) == nil)
        #expect(WindowOpsTally.line([.borrow: 0, .glyphTicks: 0]) == nil)
    }

    /// Every kind is in the line, in one order, a zero said as a zero:
    /// the lines of two minutes are read side by side.
    @Test func everyKindIsSaidAndInOneOrder() {
        let line = WindowOpsTally.line([.glyphTicks: 400, .borrow: 1, .titleSets: 37])
        #expect(line == "window ops/min: borrow=1 giveBack=0 occlusionFlips=0 becomeKey=0 fixTabBar=0 markRedraw=0 titleSets=37 glyphTicks=400 setIcon=0 badgeSets=0")
    }
}
