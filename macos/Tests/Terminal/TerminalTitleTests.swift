import Testing
@testable import Ghostty

/// The bug these are here for: Poltergeist's mark used to be spliced into
/// the tab title and sent as a title override, so the mark and the title
/// the program sets through OSC 0/2 shared one field. Whoever wrote last
/// won, and renaming the terminal erased the mark. The mark has its own
/// per-surface field now and is composed here at render time, so a rename
/// recomposes instead of overwriting.
@Suite
struct TerminalTitleTests {
    /// The shield in front of the on-duty disc, as the core composes it.
    static let mark = "\u{1F512}\u{0020}\u{25CF}\u{0020}"

    @Test func composesTheMarkInFrontOfTheTitle() {
        #expect(TerminalTitle.compose(
            title: "zsh",
            bell: false,
            poltergeistMark: Self.mark) == "\u{1F512} \u{25CF} zsh")
    }

    /// The whole point. Every one of these is the program renaming itself.
    @Test(arguments: ["new name", "claude", "vim README.md", ""])
    func markSurvivesARename(_ renamed: String) {
        let shown = TerminalTitle.compose(
            title: renamed,
            bell: false,
            poltergeistMark: Self.mark)
        #expect(shown.hasPrefix(Self.mark))
        #expect(shown.hasSuffix(renamed))
    }

    /// Control: the assertion above is not true of every string. Without a
    /// mark the title is passed through untouched.
    @Test func noMarkLeavesTheTitleAlone() {
        let shown = TerminalTitle.compose(
            title: "new name",
            bell: false,
            poltergeistMark: "")
        #expect(shown == "new name")
        #expect(!shown.hasPrefix(Self.mark))
    }

    /// The mark leads: it is a fact about the whole terminal. The bell is a
    /// passing event, so it sits closer to the title it happened in.
    @Test func markLeadsAndTheBellSitsNextToTheTitle() {
        #expect(TerminalTitle.compose(
            title: "zsh",
            bell: true,
            poltergeistMark: Self.mark) == "\u{1F512} \u{25CF} \u{1F514} zsh")
    }

    /// The bell on its own behaves exactly as it did before the mark
    /// existed, which is what makes this change safe to drop in.
    @Test func bellAloneIsUnchanged() {
        #expect(TerminalTitle.compose(
            title: "zsh",
            bell: true,
            poltergeistMark: "") == "\u{1F514} zsh")
    }
}
