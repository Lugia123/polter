//! Which tabs a "close tabs" gesture takes, and whether the person has to be
//! asked first -- decided **before** anything closes, in one place, for every
//! mode.
//!
//! **Why this exists (issue #24).** `ctrl+shift+w` closed a whole tab, every
//! process in it included, without a single question, while closing one idle
//! pane asked. The core's `close_tab` promises a confirmation "depending on
//! `confirm-close-surface`" and exports the answer
//! (`ghostty_surface_needs_confirm_quit`); the host resolved it and asked it on
//! the strip's cross -- and the keyboard path went straight into the op queue,
//! where a modal box must never be raised (`tabs.rs`, the note above `ask`).
//! An op that reached the queue had never been decided. The strip menu's
//! "Close Other Tabs" and "Close Tabs to the Right" had the same gap.
//!
//! ⚠️ **Three modes, and two of them close many tabs at once.** A fix that
//! only covers `this` covers a third of the gesture. `Scope` is the whole list
//! and every caller goes through `decide`.
//!
//! **No Win32 here, on purpose.** The rule is tested where it is written; the
//! host crate's own tests only run on a Windows machine.

/// What a close gesture takes, relative to one tab (the *anchor*): the core's
/// `ghostty_action_close_tab_mode_e` for the keyboard, the right-clicked tab
/// for the strip menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// The anchor itself.
    This,
    /// Every tab but the anchor.
    Others,
    /// Every tab after the anchor.
    Right,
}

/// The indices a close in `scope` removes from a strip of `n` tabs, anchored
/// at `anchor`, **highest first** -- so removing them one by one never shifts
/// an index that is still to come. Empty when `anchor` is out of range.
pub fn victims(scope: Scope, anchor: usize, n: usize) -> Vec<usize> {
    if anchor >= n {
        return Vec::new();
    }
    match scope {
        Scope::This => vec![anchor],
        Scope::Others => (0..n).rev().filter(|i| *i != anchor).collect(),
        Scope::Right => (anchor + 1..n).rev().collect(),
    }
}

/// The tabs an agent's `poltergeist_close` takes (#989), by the core's
/// `ghostty_action_poltergeist_close_scope_e`: 0 the anchor's tab, 1 every
/// other tab, 2 the tabs to its right, 3 the whole window. Anything else is
/// the anchor's tab, the conservative reading `tabs.rs` already gives it.
pub fn tool_victims(scope: i32, anchor: usize, n: usize) -> Vec<usize> {
    match scope {
        1 => victims(Scope::Others, anchor, n),
        2 => victims(Scope::Right, anchor, n),
        3 if anchor < n => (0..n).rev().collect(),
        _ => victims(Scope::This, anchor, n),
    }
}

/// Whether an agent's close is **refused** (#989): it would need the user's
/// consent (`confirm`, the core's answer for the named terminal) and one of
/// the tabs it takes has something running. **Never asked**: the box this
/// used to be is on the user's screen for a close an agent wanted, and the
/// user said it must not appear. Nothing busy among the victims closes
/// whatever `confirm` says -- there is nothing to lose.
pub fn tool_close_refused(confirm: bool, victims: &[usize], busy: &[bool]) -> bool {
    confirm && victims.iter().any(|i| busy.get(*i).copied().unwrap_or(false))
}

/// Decide a close before it happens. `busy[i]` is whether tab `i` holds any
/// surface the core wants confirmed (`needsConfirmQuit`, which is where
/// `confirm-close-surface` is read). `ask` puts the question to the person and
/// returns `true` for go ahead.
///
/// Returns the tabs to close, highest index first, or `None` if the person
/// said no. **`ask` is called at most once**, however many tabs or panes are
/// going -- and **only about the tabs that are going**: a busy tab that this
/// gesture leaves alone is not a reason to interrupt anybody.
pub fn decide(scope: Scope, anchor: usize, busy: &[bool], ask: impl FnOnce() -> bool) -> Option<Vec<usize>> {
    let going = victims(scope, anchor, busy.len());
    if going.iter().any(|i| busy[*i]) && !ask() {
        return None;
    }
    Some(going)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #989: the user's busy tab is refused, an agent's (or marked) one
    /// closes, and nothing busy closes either way.
    #[test]
    fn an_agents_close_is_refused_only_over_something_busy() {
        let busy = [false, true, false, false];
        // The busy tab is among the victims.
        assert!(tool_close_refused(true, &tool_victims(0, 1, 4), &busy));
        assert!(tool_close_refused(true, &tool_victims(3, 0, 4), &busy), "the whole window");
        // Consent not needed (marked, or the agent's own): it closes.
        assert!(!tool_close_refused(false, &tool_victims(0, 1, 4), &busy));
        // The busy tab is not among the victims: nothing to lose.
        assert!(!tool_close_refused(true, &tool_victims(2, 1, 4), &busy), "right of the busy one");
        assert!(!tool_close_refused(true, &tool_victims(0, 2, 4), &busy));
        assert_eq!(tool_victims(1, 1, 4), vec![3, 2, 0]);
        assert_eq!(tool_victims(9, 1, 4), vec![1], "unknown is the anchor's tab");
    }

    /// A strip of four tabs, anchor at 1, where each case marks which are busy.
    const N: usize = 4;
    const ANCHOR: usize = 1;

    fn busy(which: &[usize]) -> Vec<bool> {
        (0..N).map(|i| which.contains(&i)).collect()
    }

    /// Runs `decide` and reports how many times it asked alongside what it
    /// returned. The count is the point: "did it ask" and "did it ask about
    /// the right tabs" are different questions.
    fn run(scope: Scope, which_busy: &[usize], answer: bool) -> (Option<Vec<usize>>, u32) {
        let mut asked = 0;
        let got = decide(scope, ANCHOR, &busy(which_busy), || {
            asked += 1;
            answer
        });
        (got, asked)
    }

    #[test]
    fn each_scope_takes_the_tabs_it_names_highest_first() {
        assert_eq!(victims(Scope::This, ANCHOR, N), [1]);
        assert_eq!(victims(Scope::Others, ANCHOR, N), [3, 2, 0]);
        assert_eq!(victims(Scope::Right, ANCHOR, N), [3, 2]);
        assert_eq!(victims(Scope::Right, N - 1, N), Vec::<usize>::new());
        assert_eq!(victims(Scope::This, N, N), Vec::<usize>::new());
    }

    // -- (a): a busy tab in the gesture's reach asks first, and "no" keeps
    //    every tab. One per scope, because two of the three close many tabs.

    #[test]
    fn this_asks_before_closing_a_busy_tab_and_no_keeps_it() {
        assert_eq!(run(Scope::This, &[1], false), (None, 1));
        assert_eq!(run(Scope::This, &[1], true), (Some(vec![1]), 1));
    }

    #[test]
    fn others_asks_once_for_several_busy_tabs_and_no_keeps_them_all() {
        assert_eq!(run(Scope::Others, &[0, 2, 3], false), (None, 1));
        assert_eq!(run(Scope::Others, &[0, 2, 3], true), (Some(vec![3, 2, 0]), 1));
    }

    #[test]
    fn right_asks_before_closing_a_busy_tab_to_the_right_and_no_keeps_it() {
        assert_eq!(run(Scope::Right, &[3], false), (None, 1));
        assert_eq!(run(Scope::Right, &[3], true), (Some(vec![3, 2]), 1));
    }

    // -- only the tabs that are going count.

    #[test]
    fn a_busy_tab_the_gesture_leaves_alone_does_not_ask() {
        // The anchor is busy but `others` and `right` keep it.
        assert_eq!(run(Scope::Others, &[1], false), (Some(vec![3, 2, 0]), 0));
        assert_eq!(run(Scope::Right, &[1], false), (Some(vec![3, 2]), 0));
        // A busy tab to the left is not "to the right".
        assert_eq!(run(Scope::Right, &[0], false), (Some(vec![3, 2]), 0));
    }

    // -- (c): nothing busy -- which is what every surface answers when
    //    `confirm-close-surface = false` -- closes without a question.

    #[test]
    fn nothing_busy_closes_without_asking_in_every_scope() {
        for scope in [Scope::This, Scope::Others, Scope::Right] {
            let (got, asked) = run(scope, &[], false);
            assert_eq!(asked, 0, "{scope:?} asked with nothing busy");
            assert_eq!(got, Some(victims(scope, ANCHOR, N)), "{scope:?}");
        }
    }
}
