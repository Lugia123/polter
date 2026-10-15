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

/// What the host does when the right button comes up over a terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RightUp {
    /// The terminal the release is told to: always the one that saw the
    /// press, whichever terminal the pointer came up over. `None` when no
    /// terminal saw a press, and then nothing is sent.
    pub release_to: Option<usize>,
    /// Whether the terminal's menu opens, on the terminal the button came up
    /// over.
    pub menu: bool,
}

/// The right button, as macOS has it (`SurfaceView_AppKit.swift`,
/// `rightMouseDown`): **the core is asked first**, and the menu is what
/// happens only when the core says it did not take the click.
///
/// - `press`: the terminal the press went to, and whether the core took it
///   (`ghostty_surface_mouse_button` returned true). The core takes it when a
///   program is reporting the mouse (vim, tmux), and when
///   `right-click-action` is `copy`, `paste`, `copy-or-paste` or `ignore`;
///   with `context-menu` it selects the word under the pointer and declines,
///   so the host shows the menu.
/// - `up_on`: the terminal the button came up over.
///
/// **The menu opens only over the terminal that was pressed.** macOS opens it
/// on the press itself, so a press and a release on two different terminals
/// cannot happen there. Here the menu is the release's (`WM_CONTEXTMENU`
/// comes from the release), and a press on one pane carried to another is
/// not a request for either pane's menu.
pub fn right_up(press: Option<(usize, bool)>, up_on: usize) -> RightUp {
    match press {
        None => RightUp { release_to: None, menu: false },
        Some((pressed, taken)) => RightUp { release_to: Some(pressed), menu: !taken && pressed == up_on },
    }
}

/// How far the find bar sits in from its terminal's top and right edges, in
/// the design's points: macOS pads the bar by 8 inside the terminal
/// (`SurfaceSearchOverlay.padding`).
pub const FIND_INSET: i32 = 8;

/// Where the find bar goes: **the top-right corner of the terminal whose
/// search it is**, inset by `inset` -- not of the window (#1596 D-4). `pane`
/// is that terminal's rectangle as `(left, top, right, bottom)` and `size`
/// the bar's, all in the same units; the answer is the bar's top-left.
///
/// A terminal narrower than the bar keeps the bar's left edge on its own
/// left edge, so the needle box -- the bar's first part -- stays over the
/// terminal it searches and only the buttons run past.
pub fn find_bar_at(pane: (i32, i32, i32, i32), size: (i32, i32), inset: i32) -> (i32, i32) {
    let (left, top, right, _) = pane;
    ((right - size.0 - inset).max(left), top + inset)
}

/// What Esc in the find bar's box does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FindEscape {
    /// End the search and close the bar.
    Close,
    /// Give the keyboard back to the terminal and leave the bar open with its
    /// needle and matches; Esc in the terminal then ends the search (the
    /// core's own `escape` → `end_search` binding).
    BackToTerminal,
}

/// macOS (`SurfaceSearchOverlay`, `onExitCommand`): an empty box closes the
/// bar; a box with something in it hands the keyboard back first, so a
/// search is not thrown away by the key people press to get back to typing.
pub fn find_escape(needle_empty: bool) -> FindEscape {
    if needle_empty {
        FindEscape::Close
    } else {
        FindEscape::BackToTerminal
    }
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

    #[test]
    fn a_right_click_the_core_took_opens_no_menu() {
        // vim with the mouse on, or right-click-action = paste: the core took
        // the press, so the release goes to it and nothing else happens.
        assert_eq!(right_up(Some((7, true)), 7), RightUp { release_to: Some(7), menu: false });
        // right-click-action = context-menu: the core selected the word and
        // declined, so the menu opens.
        assert_eq!(right_up(Some((7, false)), 7), RightUp { release_to: Some(7), menu: true });
    }

    #[test]
    fn a_release_over_another_terminal_goes_to_the_pressed_one_and_opens_nothing() {
        assert_eq!(right_up(Some((7, false)), 8), RightUp { release_to: Some(7), menu: false });
        assert_eq!(right_up(Some((7, true)), 8), RightUp { release_to: Some(7), menu: false });
        // A release whose press no terminal saw.
        assert_eq!(right_up(None, 8), RightUp { release_to: None, menu: false });
    }

    #[test]
    fn the_find_bar_sits_in_the_top_right_of_its_own_terminal() {
        // #1596 D-4: a window split left and right, each half 640 wide. The
        // bar belongs in whichever half the search is for, not in the
        // window's corner -- which is the right half's corner either way.
        let left = (0, 40, 640, 760);
        let right = (644, 40, 1284, 760);
        assert_eq!(find_bar_at(left, (340, 38), 8), (292, 48));
        assert_eq!(find_bar_at(right, (340, 38), 8), (936, 48));
        // Its right edge is `inset` inside the terminal's.
        let (x, _) = find_bar_at(left, (340, 38), 8);
        assert_eq!(x + 340, 640 - 8);
    }

    #[test]
    fn a_terminal_narrower_than_the_bar_keeps_the_box_over_it() {
        assert_eq!(find_bar_at((100, 0, 300, 400), (340, 38), 8), (100, 8));
    }

    #[test]
    fn esc_closes_an_empty_bar_and_otherwise_goes_back_to_the_terminal() {
        assert_eq!(find_escape(true), FindEscape::Close);
        assert_eq!(find_escape(false), FindEscape::BackToTerminal);
    }
}
