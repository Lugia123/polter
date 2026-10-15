//! The signs drawn over a terminal by the host (`windows/host/src/hud.rs`):
//! the decisions about them that need no window.

/// Which terminal the one scrollbar should be drawn for once the panes have
/// moved -- another tab came to the front, or back.
///
/// - `shown_for`: the terminal it was last placed for, if any.
/// - `reported`: every terminal that has reported its scrollback, **oldest
///   report first**, each with whether its pane is on screen now and whether
///   it has anything to scroll.
///
/// The one it was placed for stays while its pane is on screen. Otherwise it
/// is the most recent report from a pane on screen with something to scroll.
///
/// **Why the history and not only `shown_for`** (#1579 V3). Leaving a tab
/// with Ctrl+Shift+T makes a new terminal, and its first report -- nothing to
/// scroll -- took the bar over and forgot the old one; coming back, there was
/// nothing left to say which terminal it had been for, and the core sends
/// the numbers again only when they change.
pub fn scrollbar_for(shown_for: Option<usize>, reported: &[(usize, bool, bool)]) -> Option<usize> {
    if let Some(s) = shown_for {
        if reported.iter().any(|(r, showing, _)| *r == s && *showing) {
            return Some(s);
        }
    }
    reported.iter().rev().find(|(_, showing, scrolls)| *showing && *scrolls).map(|(s, ..)| *s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coming_back_from_a_new_tab_finds_the_bar_again() {
        // Tab 1's terminal 10 had a scrollbar; Ctrl+Shift+T made terminal 20,
        // whose report (nothing to scroll) cleared `shown_for`.
        let back = [(10, true, true), (20, false, false)];
        assert_eq!(scrollbar_for(None, &back), Some(10));
        // While the new tab is in front, nothing of tab 1 is on screen.
        let away = [(10, false, true), (20, true, false)];
        assert_eq!(scrollbar_for(None, &away), None);
    }

    #[test]
    fn the_one_it_is_for_stays_while_it_is_on_screen() {
        let r = [(10, true, true), (30, true, true)];
        assert_eq!(scrollbar_for(Some(10), &r), Some(10));
        // Its pane went behind: the latest on screen with something to scroll.
        let r = [(30, true, true), (10, false, true), (40, true, false)];
        assert_eq!(scrollbar_for(Some(10), &r), Some(30));
    }
}
