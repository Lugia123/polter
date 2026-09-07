//! `poltergeist_close`: an agent asking, through the tool surface, for a tab
//! or a window to go -- and being told the truth about what happened.
//!
//! **What was here before: nothing.** `cb_action` had no arm for
//! `GHOSTTY_ACTION_POLTERGEIST_CLOSE`, so it fell through to `_ => false` and
//! the agent's tool answered `unsupported`. That was at least honest, and it
//! is the only thing in this file that was not a hazard.
//!
//! # The out parameter is the whole job
//!
//! `ghostty_action_poltergeist_close_s` carries `result`, which the core
//! initialises to `UNSUPPORTED` and reads back the instant this callback
//! returns; `PoltergeistClose.Result.toolAnswer` turns it into what the agent
//! is told. The header spells out why zero is `UNSUPPORTED`: so that an apprt
//! which quietly does nothing, **or which does the work and writes nothing**,
//! is reported as having done nothing.
//!
//! So the failure to be afraid of is not the missing arm. It is the arm that
//! closes the tab and forgets to write: the terminal goes, the agent is told
//! its request was ignored, and everything on screen looks correct. That is
//! why every path out of [`perform`] writes the cell, including the refusals.
//!
//! # `closed`, when nothing has closed yet
//!
//! The close is queued: `cb_action` arrives on whichever thread the core is
//! on, and destroying a tab is the business of the thread that owns windows.
//! By the time the core reads the cell, the tab is still there.
//!
//! `closed` is nonetheless the honest answer, and the enum says so in words
//! -- *"it is closed, or on its way to closed with nothing left to ask"*.
//! What makes it true here is the second half: **this host never asks.**
//! `cb_close_surface` ignores the `confirm` flag it is handed and there is no
//! confirmation dialog anywhere in it, so there is no state in which a queued
//! close is waiting on a person. `AWAITING_CONFIRMATION` is therefore a value
//! this file can never write, and that is a fact about the host rather than
//! an omission -- if a close prompt is ever added, this is the file that has
//! to grow the third answer with it.

use crate::ffi;
use crate::{plogf, wlogf};

/// Perform the action and write its result. The return value is what
/// `cb_action` answers the core: whether the host **handled** the action, not
/// whether anything closed -- the cell says that.
pub fn perform(action: &ffi::Action, target: Option<ffi::Surface>) -> bool {
    let (scope, confirm, result) = action.as_poltergeist_close();

    // **A null out pointer is not something to work around.** The core always
    // provides one; a null here means the payload was read wrong, and doing
    // the close anyway would destroy somebody's terminal on the strength of a
    // struct we have just discovered we cannot parse.
    if result.is_null() {
        // process-wide: the payload is unreadable, so there is no window this
        // could be attributed to
        plogf!("[polterclose] the action carries no result pointer; refused");
        return false;
    }

    // Written first and overwritten on success, so that every early return
    // below leaves the honest answer rather than needing to remember to.
    let mut answer = ffi::POLTERGEIST_CLOSE_RESULT_UNSUPPORTED;

    let handled = match target.and_then(crate::tabs::tab_of_surface) {
        Some((frame, tab)) => {
            crate::tabs::post_op(
                frame,
                crate::tabs::Op::PoltergeistClose { tab, scope },
                "poltergeist_close action",
            );
            answer = ffi::POLTERGEIST_CLOSE_RESULT_CLOSED;
            wlogf!(
                frame,
                "[polterclose] scope={} confirm={} tab={:?} -> queued, answering closed",
                scope, confirm as u8, tab
            );
            true
        }
        None => {
            // Either the action named no surface (an app target: the union
            // holds no surface, see `ffi.rs`) or it named one that is not in
            // a tab -- the quick terminal. Neither has a tab to close, and
            // `unsupported` is exactly what the enum keeps for "this apprt
            // does not do this", which is not a failure of the request.
            // process-wide: no tab was found, so there is no window to name
            plogf!(
                "[polterclose] scope={} confirm={} names no tab (surface={:?}); answering unsupported",
                scope, confirm as u8, target
            );
            false
        }
    };

    unsafe { result.write(answer) };
    handled
}
