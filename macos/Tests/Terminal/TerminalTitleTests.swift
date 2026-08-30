import Testing
@testable import Ghostty

/// The title composition, which no longer has anything to do with the
/// Poltergeist mark.
///
/// **The mark used to be composed in here and is not any more.** It lived
/// in the title string, which the program running in the terminal also
/// writes: a shell retitling on `cd` erased it, and a title that had
/// already been composed once could come back through and be composed
/// again, which is where the doubled glyphs came from. Two owners for one
/// value is not a race to be tightened -- it is a place the mark could not
/// live. It has a slot of its own now, `NSWindowTab.accessoryView`, and
/// these tests exist partly to fail if it is ever moved back.
struct TerminalTitleTests {
    @Test func titleIsUnchangedWithoutABell() {
        #expect(TerminalTitle.compose(title: "zsh", bell: false) == "zsh")
    }

    @Test func bellSitsNextToTheTitleItHappenedIn() {
        #expect(TerminalTitle.compose(title: "zsh", bell: true) == "🔔 zsh")
    }

    @Test func renamingIsCarriedThroughUntouched() {
        // The case that broke before: the program renames itself and the
        // composed title is exactly the new name. Nothing of Poltergeist's
        // is in here to be erased.
        #expect(TerminalTitle.compose(title: "vim README.md", bell: false) == "vim README.md")
        #expect(TerminalTitle.compose(title: "", bell: false) == "")
    }

    @Test func composingTwiceIsNotComposingTwice() {
        // Idempotent for the no-bell case, which is what a title that has
        // been through the pipe once and comes back again looks like.
        let once = TerminalTitle.compose(title: "claude", bell: false)
        #expect(TerminalTitle.compose(title: once, bell: false) == once)
    }
}
