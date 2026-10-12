//! Which "waiting for you" glyph breathes, and what a window tab carries.
//!
//! One per window: the longest-waiting, unless it is in the tab the window
//! is already showing. **The order is the core's** -- `pulses` in the
//! snapshot is every waiting terminal, longest first -- and all this does
//! is walk it asking two things that are equalities: is this the tab I am
//! showing, and is this my window. Nothing here compares a time.

use crate::look::window_tab;
use crate::snapshot::{Pulse, Shown, Snapshot};

/// Where a glyph is drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// In a tab bar or on a pane: only terminals of this window are there
    /// to breathe.
    Window,
    /// In the list of groups, which shows every group whatever window its
    /// terminals are in.
    List,
}

/// The one entry that breathes in `window`, which is showing `showing_tab`;
/// none when nothing should.
pub fn pulsing<'a>(
    pulses: &'a [Pulse],
    window: Option<&str>,
    showing_tab: Option<&str>,
    scope: Scope,
) -> Option<&'a Pulse> {
    pulses.iter().find(|p| {
        let here = p.window.as_deref() == window;
        if scope == Scope::Window && !here {
            return false;
        }
        // The one being looked at does not need to call for attention.
        !(here && showing_tab.is_some() && p.tab.as_deref() == showing_tab)
    })
}

/// The row of the list that breathes, by its group's name.
pub fn pulsing_row<'a>(pulses: &'a [Pulse], window: Option<&str>, showing_tab: Option<&str>) -> Option<&'a str> {
    pulsing(pulses, window, showing_tab, Scope::List)?.group.as_deref()
}

/// What one window tab carries: the glyph the core gives that tab, and
/// whether it is the one that breathes among its window's tabs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TabStatus {
    pub shown: Shown,
    pub pulses: bool,
}

impl TabStatus {
    pub const NONE: TabStatus = TabStatus { shown: Shown::None, pulses: false };
}

/// The status of `tab`, which is in `window`, whose tab in front is
/// `showing_tab` -- all three as the core spells them. A tab the snapshot
/// does not list (the control room's own, or a terminal the core has not
/// placed yet) carries nothing, and so does every tab before the first
/// snapshot.
pub fn tab_status(snapshot: Option<&Snapshot>, tab: &str, window: &str, showing_tab: Option<&str>) -> TabStatus {
    let Some(snapshot) = snapshot else {
        return TabStatus::NONE;
    };
    let Some(entry) = snapshot.tabs.iter().find(|t| t.tab == tab) else {
        return TabStatus::NONE;
    };
    let breathing = pulsing(&snapshot.pulses, Some(window), showing_tab, Scope::Window);
    TabStatus { shown: entry.shown, pulses: breathing.is_some_and(|p| p.tab.as_deref() == Some(tab)) }
}

/// Whether a status is drawn on a window tab at all.
///
/// Working is not, so that every glyph in a row of tabs is one worth a
/// look -- unless the look table's switch says otherwise (it is marked
/// tentative there). The core already leaves working out of what it gives a
/// tab; this is the same rule on the side that draws, so that a snapshot
/// from a core that did not would still be drawn the way the table says.
pub fn draws_on_window_tab(shown: Shown) -> bool {
    match shown {
        Shown::NeedsYou | Shown::Trouble | Shown::DoneUnseen => true,
        Shown::Working => window_tab::WORKING_GLYPH_SHOWN,
        Shown::None => false,
    }
}
