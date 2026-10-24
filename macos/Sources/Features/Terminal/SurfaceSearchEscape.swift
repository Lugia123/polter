import Foundation

/// Esc in a terminal's find bar (task 2146): the rule `SurfaceSearchOverlay`
/// follows, kept out of the view so that it can be tested without one -- the
/// way the other rules in this directory are.
///
/// # What changed, and why
///
/// The bar's text used to decide it. An empty box closed the bar; a box with a
/// needle in it only handed the keyboard back to the terminal
/// (`Ghostty.moveFocus(to: surfaceView)`) and left the bar and its matches up,
/// so it took a second Esc, pressed **in the terminal**, to be rid of it.
///
/// **Somebody pressing Esc to get rid of something does not know that, and
/// nothing on screen can tell them.** The rounds that walk the matches with F3
/// and Enter have a needle in the box every time, so on Windows this read as a
/// bar that would not close -- two rounds in a row reported Esc doing nothing
/// and the cross on the right as the only way out (#2146, round 8 b and c).
/// Both hosts end the search on the first press now, and the needle is not
/// read on either.
///
/// # The needle is still a parameter, and that is deliberate
///
/// It is the shape `#2146` has: the one thing that used to be read. It is not
/// read here any more, and taking it anyway is what makes "it no longer
/// depends on what was typed" a claim a test can hold -- `action(needle:)` is
/// asked about a box that has something in it, which is exactly the state the
/// two rounds were in, and it answers the same as an empty one. Delete the
/// parameter and that test becomes unable to say anything; put a branch on it
/// and the test goes red.
///
/// # The other host's rule has one more arm, and this one must not
///
/// Windows keeps a second arm (`polter_control_room::hud::find_escape`), for a
/// state it can really be in: its bar is a window of its own, over a text box
/// that outlives it, so "Esc reached the box with no bar up" happens there and
/// has an answer -- the keyboard goes back to the terminal.
///
/// **This overlay cannot be in that state.** It is built inside
/// `if let searchState = surfaceView.searchState`, so anything that can run an
/// exit command has a bar up by construction. An arm no key can reach would
/// read as a case that was considered and handled, and nobody could tell it
/// from one that was merely imagined.
enum SurfaceSearchEscape: CaseIterable {
    /// End the search, close the bar, and put the keyboard back on the
    /// surface: `SurfaceView.endSearch()` moves focus to the terminal, and the
    /// bar leaves with the `searchState` it was drawn from.
    case close

    /// **`needle` is the bar's text: taken, and not read.** See this file's
    /// header for why it is a parameter at all.
    static func action(needle: String) -> SurfaceSearchEscape {
        // No branch on `needle`, and one case to branch to. A second case is
        // an edit to the enum, which is the edit this rule is meant to make
        // loud.
        _ = needle
        return .close
    }
}
