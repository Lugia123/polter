import Foundation
import Testing
@testable import Ghostty

/// Esc in a terminal's find bar (task 2146), without a view.
struct SurfaceSearchEscapeTests {
    /// **The finding, as a test, asked with the state that produced it.**
    /// Round 8's bar stayed up on the first Esc because the needle was one of
    /// the inputs to the decision. Here the box has a needle -- the same state
    /// every one of those presses was in -- and the first press still ends it.
    @Test func theBarClosesOnTheFirstPressWithANeedleInIt() {
        #expect(SurfaceSearchEscape.action(needle: "r8find") == .close)
        #expect(SurfaceSearchEscape.action(needle: "") == .close)
    }

    /// **The floor, and it is the shape of the defect rather than one input.**
    /// Round 8's rule had two outcomes, and which one you got depended on what
    /// was typed. The rule has exactly one now, so putting the needle back into
    /// the decision is not a one-line edit that goes unnoticed: it needs a
    /// second case, and this fails the moment that case exists.
    @Test func endingTheSearchIsTheOnlyOutcomeOfEsc() {
        #expect(SurfaceSearchEscape.allCases == [.close])
    }
}
