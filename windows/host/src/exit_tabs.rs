//! The tab count on the exit line (task 3242).
//!
//! **The line used to count a window that was already gone.**
//! `[main] exiting: … N tabs were open` took `tabs::count(hwnd)` after the
//! message loop, and every route out destroys the frame that ends the process
//! before the loop ends -- on the window-X route its tabs are even closed
//! before that -- so `N` was 0 on every run. A reading that is always the same
//! number is not a reading.
//!
//! **The count is taken where the window still has its tabs**, by the two
//! steps that take a window away: `tabs::close_all_tabs_of`, before it empties
//! the tab model (the one route that empties it before the frame goes), and
//! `winid::close_window_now`, before it destroys the frame (every route that
//! destroys the frame with its tabs still in the model). The exit line reads
//! the record afterwards. Those call sites are wired in the files that own
//! the windows; what lives here is the record and its policy.
//!
//! **Why this is its own file.** `polter-host` only builds for a Windows
//! target, so a test inside `main.rs` runs nowhere on the machine the port is
//! written on (`dev-docs/windows/development.md` §4.0). What can be wrong
//! quietly is which moment's number survives, so that rule is kept apart
//! where a test runs against these same bytes.

use std::sync::atomic::{AtomicUsize, Ordering};

/// How many tabs the window that ended the process had at the last moment
/// they were still in the tab model.
///
/// Its own type rather than a bare static so the tests can hold one of their
/// own: the process-wide record is [`AT_EXIT`], and two tests sharing it would
/// read each other's writes.
pub(crate) struct TabsAtExit(AtomicUsize);

impl TabsAtExit {
    pub(crate) const fn new() -> Self {
        Self(AtomicUsize::new(0))
    }

    /// The window that is going away had this many tabs a moment ago.
    ///
    /// **Replaces whatever was recorded before**, because the line is about
    /// the window that went last: a window closed while others stay is not
    /// the one the process leaves with. A window that goes with no tabs left
    /// -- the person closed its last tab -- records 0, and the count goes
    /// back to 0 rather than keeping an earlier window's number.
    pub(crate) fn remember(&self, tabs: usize) {
        self.0.store(tabs, Ordering::Relaxed);
    }

    /// The count for the exit line. 0 before any window is recorded, which
    /// is also the number the old line printed always.
    pub(crate) fn count(&self) -> usize {
        self.0.load(Ordering::Relaxed)
    }
}

/// The one record the exit line reads.
pub(crate) static AT_EXIT: TabsAtExit = TabsAtExit::new();

#[cfg(test)]
mod tests {
    use super::*;

    /// Before a window goes there is no count to print. Keeping the default
    /// at 0 makes that absence read as "0 tabs", which is a fact, rather than
    /// as a leftover from somewhere else.
    #[test]
    fn nothing_recorded_is_zero() {
        assert_eq!(TabsAtExit::new().count(), 0);
    }

    /// The count is the window's own: three tabs open in the window that
    /// went are three -- not the zero left in the tab model after it was
    /// emptied (task 3242).
    #[test]
    fn the_window_that_went_is_the_one_counted() {
        let at_exit = TabsAtExit::new();
        at_exit.remember(3);
        assert_eq!(at_exit.count(), 3);
    }

    /// Two windows can go in one process (B1-e). The line is about the last
    /// one, so its count replaces the earlier window's.
    #[test]
    fn the_window_that_went_last_wins() {
        let at_exit = TabsAtExit::new();
        at_exit.remember(5);
        at_exit.remember(2);
        assert_eq!(at_exit.count(), 2);
    }

    /// **A count can go down to zero, and must.** Closing the last tab takes
    /// the window with it: that window had no tabs left when it went, so the
    /// line says 0 -- not the five an earlier window had. A record that kept
    /// the largest number would pass the test above and fail this one.
    #[test]
    fn a_window_with_no_tabs_left_replaces_an_earlier_count() {
        let at_exit = TabsAtExit::new();
        at_exit.remember(5);
        at_exit.remember(0);
        assert_eq!(at_exit.count(), 0);
    }
}
