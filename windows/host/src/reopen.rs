//! The tabs you closed, so the last one can come back.
//!
//! **Why this file exists and `undo` does not do it.** The core publishes an
//! `undo` action, the menu named it, and it returned false every time:
//! `GHOSTTY_ACTION_UNDO` (tag 55) is handed to the host, and `cb_action` in
//! `main.rs` ends in `_ => false`. There is nothing to fix in the core. The
//! stack of what was closed is the host's to keep, the way macOS keeps it in
//! `ClosedTabs.swift`.
//!
//! **What is kept, and the one that decides whether this feature should
//! exist at all: the directory.** A tab that reopens somewhere else is worse
//! than no reopen at all -- it looks like it worked, and the person notices
//! two commands later, in the wrong tree. So a tab whose directory is not
//! known is **not remembered**, loudly. There is no fallback to the home
//! directory: "reopened in the wrong place" is exactly what a fallback looks
//! like from the outside.
//!
//! **Bounded, at twenty.** This is the undo stack for closing things, not a
//! history -- `ClosedTabs.swift`'s own words, and the same number, because two
//! platforms with different limits is one more difference to explain than the
//! difference is worth. The depth is in every log line so the bound is
//! visible rather than a constant somebody has to go and read.
//!
//! **Not done, and it is missing rather than unnecessary:** macOS also primes
//! this stack from the previous session (`session.json`), so ⌘⇧T walks back
//! past a restart. This host writes no session file, so tonight the stack
//! covers this run only. That is a piece of S4 that is not built, not a
//! decision that it should not be.

use std::sync::{Mutex, OnceLock};

use crate::logf;

/// One tab worth reopening.
pub struct Entry {
    pub title: String,
    /// Where its shell was standing. **Never empty**: an entry without one is
    /// refused by `remember` rather than stored and papered over later.
    pub cwd: String,
    /// Where it was in the strip when it was closed. Restored, not appended:
    /// a tab that comes back at the far end has moved, and the person who
    /// pressed undo did not ask for it to move.
    pub index: usize,
}

/// The bound. See the module docs: undo stack, not history.
const LIMIT: usize = 20;

static STACK: Mutex<Vec<Entry>> = Mutex::new(Vec::new());

/// What actually builds the tab again. Installed by `tabs.rs`, which owns tab
/// creation; **this file never creates anything**, so there is no second path
/// into tab creation to keep in step with the first.
///
/// Returns whether the tab was created.
static OPENER: OnceLock<fn(&Entry) -> bool> = OnceLock::new();

/// Install the thing that makes a tab from an entry.
pub fn set_opener(f: fn(&Entry) -> bool) {
    let _ = OPENER.set(f);
}

fn depth() -> usize {
    STACK.lock().map(|s| s.len()).unwrap_or(0)
}

/// Is there anything to reopen? **The menu row's greyed state reads this**,
/// which makes it the first row in the menu whose greying tracks something
/// real rather than a piece of work nobody has started.
pub fn can_reopen() -> bool {
    depth() > 0
}

/// Remember a tab that is being closed.
///
/// Called from `destroy_tab_at` while the tab is still whole -- after the
/// panes are freed there is nothing left to ask.
pub fn remember(index: usize, title: &str, cwd: &str) {
    if cwd.is_empty() {
        // **Said out loud rather than skipped.** "The stack is empty" and
        // "this tab had no directory to remember" produce the same greyed
        // menu item, and only this line tells them apart.
        logf!(
            "[reopen] not remembering tab {} {:?}: no cwd known (nothing has told this host \
             where that shell was; GHOSTTY_ACTION_PWD)",
            index,
            title
        );
        return;
    }
    let Ok(mut stack) = STACK.lock() else {
        logf!("[reopen] the stack is poisoned; tab {index} {title:?} was not remembered");
        return;
    };
    stack.push(Entry {
        title: title.to_string(),
        cwd: cwd.to_string(),
        index,
    });
    if stack.len() > LIMIT {
        let dropped = stack.remove(0);
        // Dropping the oldest is the bound working, but a silent drop and a
        // lost entry look the same from the far side.
        logf!("[reopen] dropped oldest {:?} to stay at {}", dropped.title, LIMIT);
    }
    logf!(
        "[reopen] remembered tab {} {:?} cwd={:?}; stack {}/{}",
        index,
        title,
        cwd,
        stack.len(),
        LIMIT
    );
}

/// Reopen the most recently closed tab. Returns whether anything happened,
/// which is what the menu's `ok=` reports.
pub fn reopen_last() -> bool {
    let entry = match STACK.lock() {
        Ok(mut stack) => stack.pop(),
        Err(_) => {
            logf!("[reopen] the stack is poisoned; nothing reopened");
            return false;
        }
    };
    let Some(entry) = entry else {
        // Reachable only if the row was not greyed when it should have been,
        // so this line is also the greying's own alarm.
        logf!("[reopen] nothing to reopen; stack 0/{}", LIMIT);
        return false;
    };
    let Some(open) = OPENER.get() else {
        logf!(
            "[reopen] no opener installed: {:?} cwd={:?} stays on the stack, because a tab \
             opened without its directory is the failure this feature exists to avoid",
            entry.title,
            entry.cwd
        );
        // Put it back: a dropped entry would make the next press reopen the
        // wrong tab, and the person would never learn why.
        if let Ok(mut stack) = STACK.lock() {
            stack.push(entry);
        }
        return false;
    };
    // **The log line for the restore is `tabs.rs`'s, not this one's.** It has
    // to print the index the tab actually landed at and the directory that was
    // actually handed to the surface -- printing them from here would report
    // this function's intent, which is the copy that is right even when the
    // used value is wrong.
    let title = entry.title.clone();
    let ok = open(&entry);
    if !ok {
        logf!("[reopen] the opener refused {:?}; putting it back on the stack", title);
        if let Ok(mut stack) = STACK.lock() {
            stack.push(entry);
        }
    }
    ok
}

/// For the log line at startup and for tests: how deep, and how deep it may get.
pub fn stack_depth() -> (usize, usize) {
    (depth(), LIMIT)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tests share one global stack, so they run one after another rather
    /// than pretending to be independent.
    fn reset() {
        if let Ok(mut s) = STACK.lock() {
            s.clear();
        }
        // The opener is a `OnceLock` on purpose (installed once, at startup);
        // tests here never install one, which is why `reopen_last` is only
        // exercised for its refusal paths.
    }

    #[test]
    fn a_tab_with_no_cwd_is_not_remembered() {
        reset();
        remember(0, "no cwd", "");
        assert_eq!(stack_depth().0, 0);
        assert!(!can_reopen());
    }

    /// **The floor for the test above.** If `remember` stored everything, the
    /// test above would still pass on an implementation that stores an empty
    /// directory and lets the tab reopen somewhere else.
    #[test]
    fn a_tab_with_a_cwd_is_remembered() {
        reset();
        remember(3, "build", "C:\\work\\alpha");
        assert_eq!(stack_depth().0, 1);
        assert!(can_reopen());
        reset();
    }

    #[test]
    fn the_stack_is_last_in_first_out() {
        reset();
        remember(0, "x", "C:\\x");
        remember(1, "y", "C:\\y");
        remember(2, "z", "C:\\z");
        let mut order = Vec::new();
        while let Ok(mut s) = STACK.lock() {
            match s.pop() {
                Some(e) => order.push(e.title),
                None => break,
            }
        }
        assert_eq!(order, vec!["z", "y", "x"]);
        reset();
    }

    /// The bound holds, and it drops the *oldest*. Dropping the newest would
    /// also keep the length at twenty and would break undo instead.
    #[test]
    fn the_stack_is_bounded_and_drops_the_oldest() {
        reset();
        for i in 0..(LIMIT + 5) {
            remember(i, &format!("tab{i}"), "C:\\somewhere");
        }
        assert_eq!(stack_depth().0, LIMIT);
        let s = STACK.lock().unwrap();
        assert_eq!(s.first().unwrap().title, "tab5", "the oldest five should be gone");
        assert_eq!(s.last().unwrap().title, format!("tab{}", LIMIT + 4));
    }

    /// With no opener installed the entry stays put. **The failure this
    /// prevents is silent**: popped, then not opened, and the next press
    /// reopens the tab before it.
    #[test]
    fn a_refused_reopen_keeps_the_entry() {
        reset();
        remember(1, "keeps", "C:\\work\\alpha");
        assert!(!reopen_last(), "no opener is installed in tests");
        assert_eq!(stack_depth().0, 1, "the entry must still be there");
        reset();
    }

    /// An empty stack answers no, and does not panic doing it.
    #[test]
    fn an_empty_stack_reopens_nothing() {
        reset();
        assert!(!reopen_last());
        assert_eq!(stack_depth().0, 0);
    }
}
