import Foundation
import Testing
@testable import Ghostty

/// The rules for a terminal's title on macOS (task 1735), without a view.
struct SurfaceTitleStateTests {
    /// The box sends the core the same binding an agent does, with the text
    /// as typed -- colons and all, which the core's parser keeps.
    @Test func theBoxSendsSetSurfaceTitle() {
        #expect(SurfaceTitleState.renameBinding("build: A=1") == "set_surface_title:build: A=1")
        #expect(SurfaceTitleState.renameBinding("") == "set_surface_title:")
    }

    /// Named, the program's next title does not replace it; cleared, the
    /// title is the program's again -- what it said last, not before.
    @Test func aChosenNameHoldsUntilItIsCleared() {
        var s = SurfaceTitleState(title: "~/work", fromTerminal: nil)
        s.chosen("builder")
        #expect(s.title == "builder")
        #expect(s.pinned)

        s.reported("vim notes.md")
        #expect(s.title == "builder")

        s.chosen("")
        #expect(s.title == "vim notes.md")
        #expect(!s.pinned)

        s.reported("~/elsewhere")
        #expect(s.title == "~/elsewhere")
    }

    /// Renamed twice: clearing still returns to the program's title, not to
    /// the first name.
    @Test func aSecondNameDoesNotBecomeTheProgramsTitle() {
        var s = SurfaceTitleState(title: "zsh", fromTerminal: nil)
        s.chosen("first")
        s.chosen("second")
        #expect(s.title == "second")
        s.chosen("")
        #expect(s.title == "zsh")
    }

    /// Clearing a name nobody chose changes nothing. (It used to put up a
    /// placeholder until the program spoke again.)
    @Test func clearingWithNothingChosenKeepsTheTitle() {
        var s = SurfaceTitleState(title: "~/work", fromTerminal: nil)
        s.chosen("")
        #expect(s == SurfaceTitleState(title: "~/work", fromTerminal: nil))
    }
}
