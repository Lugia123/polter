import Foundation

/// How the text on a tab is put together out of the several things that
/// have something to say about a terminal.
///
/// **This exists as a pure function because of a bug it is meant to make
/// impossible.** Poltergeist's mark used to be spliced into the tab title
/// override and sent down as a title, which meant the mark and the title
/// the program set through OSC 0/2 lived in one field with two writers:
/// rename the terminal and the mark was gone. The fix is that each thing
/// keeps its own per-surface field and they are composed here, at the
/// moment the title is rendered -- so a rename recomposes instead of
/// overwriting. Keeping the composition out of the controller keeps it
/// testable without an app.
enum TerminalTitle {
    /// Compose what a tab shows.
    ///
    /// - Parameters:
    ///   - title: what the terminal calls itself, or the user's override.
    ///   - bell: whether to show the bell prefix. The caller has already
    ///     applied the config that decides whether the bell shows in the
    ///     title at all.
    ///     when there is nothing to say. It ends in its own space.
    ///
    /// The Poltergeist mark is deliberately absent: it has a slot of its
    /// own on the tab (`NSWindowTab.accessoryView`) because sharing this
    /// string with the program in the terminal meant it was erased on
    /// every rename and doubled whenever a composed title came back
    /// through. The bell stays -- it is a passing event about this title,
    /// not a standing fact about the terminal.
    static func compose(
        title: String,
        bell: Bool
    ) -> String {
        var result = title
        if bell {
            result = "🔔 \(result)"
        }
        return result
    }
}
