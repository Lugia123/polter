//! Which "waiting for you" glyph breathes.
//!
//! One per window: the longest-waiting, unless it is in the tab the window
//! is already showing. **The order is the core's** -- `pulses` in the
//! snapshot is every waiting terminal, longest first -- and all this does
//! is walk it asking two things that are equalities: is this the tab I am
//! showing, and is this my window. Nothing here compares a time.

use crate::snapshot::Pulse;

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
