//! Where the keyboard goes when an overlay closes (#1012): the settings
//! window, the command palette, the search bar, the quick terminal, the
//! title box -- everything that goes through `overlay::focus_back`.
//!
//! **What went wrong.** Each overlay remembered the terminal that had the
//! keyboard *when it opened* and gave the keyboard back to it when it closed.
//! The settings window can stay open for minutes, and the person switches
//! tabs meanwhile. Measured on the Windows test machine: settings open → tab 2
//! opened in the main window → settings closed → the keyboard went to tab 1's
//! pane, which was **hidden** (`visible=False`); six keystrokes typed "into
//! the terminal" landed in a tab nobody could see.
//!
//! **The rule.** The keyboard goes to where typing goes **now**: the focused
//! pane of the active tab of the current terminal window. The one remembered
//! at opening is kept only when it is still exactly that kind of place -- its
//! tab is the active one, in the current window. Anything that is not a
//! terminal pane (another window's control, a dialog) is handed back as it
//! was: this rule is about panes going out of sight, and nothing else.
//!
//! Handles are integers here, so the rule runs on any machine.

/// What the overlay remembered, as the host finds it at closing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Prev {
    /// Nothing; or a window that no longer exists; or a terminal window
    /// itself rather than a pane in it.
    Nothing,
    /// Some window that is not a terminal pane, still there.
    Other(isize),
    /// A terminal pane.
    Pane {
        hwnd: isize,
        /// The terminal window it is in.
        frame: isize,
        /// Whether its tab is that window's active tab -- the one on screen.
        tab_active: bool,
    },
}

/// The current terminal window, and the pane typing goes to in it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Current {
    pub frame: isize,
    pub pane: Option<isize>,
}

/// Why the answer is what it is -- for the log line, which is what is read on
/// the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Why {
    /// The remembered pane is still on screen, in the current window.
    StillShowing,
    /// The remembered window is not a pane; handed back as it was.
    NotAPane,
    /// The current window's active pane, in place of the remembered one.
    CurrentPane,
    /// No current window; another visible window's active pane.
    AnyWindow,
    /// No terminal window at all: nobody gets the keyboard.
    Nowhere,
}

/// The keyboard's destination. `current` is the window `overlay_frame` names
/// (the one last active); `anywhere` is the active pane of some visible
/// terminal window, for when there is no current one or it has no pane.
pub fn handback(prev: Prev, current: Option<Current>, anywhere: Option<isize>) -> (Option<isize>, Why) {
    match prev {
        Prev::Other(h) => return (Some(h), Why::NotAPane),
        Prev::Pane { hwnd, frame, tab_active: true } if current.is_none_or(|c| c.frame == frame) => {
            return (Some(hwnd), Why::StillShowing);
        }
        _ => {}
    }
    if let Some(p) = current.and_then(|c| c.pane) {
        return (Some(p), Why::CurrentPane);
    }
    match anywhere {
        Some(p) => (Some(p), Why::AnyWindow),
        None => (None, Why::Nowhere),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const W1: isize = 0x100;
    const W2: isize = 0x200;
    const TAB1_PANE: isize = 0x11;
    const TAB2_PANE: isize = 0x12;

    /// The case measured on the machine: tab 2 was opened (and is active)
    /// while the settings window was up; tab 1's pane is hidden.
    #[test]
    fn a_tab_switched_to_meanwhile_gets_the_keyboard() {
        let prev = Prev::Pane { hwnd: TAB1_PANE, frame: W1, tab_active: false };
        let now = Some(Current { frame: W1, pane: Some(TAB2_PANE) });
        assert_eq!(handback(prev, now, Some(TAB2_PANE)), (Some(TAB2_PANE), Why::CurrentPane));
    }

    #[test]
    fn nothing_changed_meanwhile_and_the_same_pane_gets_it_back() {
        let prev = Prev::Pane { hwnd: TAB1_PANE, frame: W1, tab_active: true };
        let now = Some(Current { frame: W1, pane: Some(TAB1_PANE) });
        assert_eq!(handback(prev, now, None), (Some(TAB1_PANE), Why::StillShowing));
    }

    /// The remembered tab was closed: its pane window is gone, which the host
    /// reports as `Nothing`.
    #[test]
    fn the_remembered_tab_was_closed_meanwhile() {
        let now = Some(Current { frame: W1, pane: Some(TAB2_PANE) });
        assert_eq!(handback(Prev::Nothing, now, None), (Some(TAB2_PANE), Why::CurrentPane));
    }

    /// Its window was closed too: some other visible window's active pane;
    /// with no terminal window at all, nobody.
    #[test]
    fn every_window_it_knew_was_closed() {
        assert_eq!(handback(Prev::Nothing, None, Some(0x77)), (Some(0x77), Why::AnyWindow));
        assert_eq!(handback(Prev::Nothing, Some(Current { frame: W2, pane: None }), Some(0x77)), (Some(0x77), Why::AnyWindow));
        assert_eq!(handback(Prev::Nothing, None, None), (None, Why::Nowhere));
    }

    /// Still the active tab, but of a window the person has left for another:
    /// the window in use wins.
    #[test]
    fn a_pane_in_a_window_the_person_left_is_not_kept() {
        let prev = Prev::Pane { hwnd: TAB1_PANE, frame: W1, tab_active: true };
        let now = Some(Current { frame: W2, pane: Some(0x21) });
        assert_eq!(handback(prev, now, None), (Some(0x21), Why::CurrentPane));
        // With no current window known, an on-screen pane is kept.
        assert_eq!(handback(prev, None, Some(0x21)), (Some(TAB1_PANE), Why::StillShowing));
    }

    #[test]
    fn what_is_not_a_pane_is_handed_back_as_it_was() {
        let now = Some(Current { frame: W1, pane: Some(TAB2_PANE) });
        assert_eq!(handback(Prev::Other(0x999), now, None), (Some(0x999), Why::NotAPane));
    }
}
