//! The one thing every overlay with a text box has to get right.
//!
//! **Why this file exists.** Three places have now independently arrived at
//! the same two-call contract: the command palette (`palette.rs`), the tab
//! rename box (`strip.rs`), and the search overlay (`search.rs`). When three
//! sites reach the same shape by themselves, the shape is real; and this one
//! is worth naming because **every way of getting it wrong is silent**.
//!
//! **What the contract is.** There is exactly one TSF document manager for
//! this thread, and `ime_init` associated it with the *terminal* windows. A
//! native `EDIT` control has a document of its own. So when an overlay takes
//! focus we must hand ours back, and when it closes we must let the surface
//! take its document again.
//!
//! **What is deliberately not here.** The window, the font, the painting —
//! the three call sites want genuinely different windows (a filter list, a
//! one-line rename field, a find bar with a counter), and forcing them
//! through one scaffold would cost more than it saves. **Only the part with
//! the silent failure is shared.**
//!
//! **The ordering is load-bearing, in both directions:**
//!
//!  - Opening: release the document **before** the edit control takes focus.
//!    Reverse it and TSF has already decided which document the next
//!    keystroke belongs to; the symptom is "the box cannot compose Chinese",
//!    with no error anywhere.
//!  - Closing: give focus back to the surface and **stop**. Its `WM_SETFOCUS`
//!    already calls `ime_set_window` + `ime_focus(true)`. Calling those here
//!    as well would be a second place that has to stay in agreement with the
//!    first, and the two would drift.

use windows::Win32::Foundation::HWND;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetFocus, SetFocus};

use crate::logf;

/// Hand the TSF document back and move focus into an overlay's edit control.
///
/// Returns the window that had focus, to be passed to [`focus_back`] when the
/// overlay closes. A null return is possible (nothing had focus) and is not an
/// error; [`focus_back`] ignores it.
pub fn focus_to_edit(edit: HWND, who: &str) -> HWND {
    let prev = unsafe { GetFocus() };

    // Before, not after. See this file's header.
    crate::ime_focus(false);

    if !edit.0.is_null() {
        let _ = unsafe { SetFocus(Some(edit)) };
    }
    logf!("[overlay] {} took focus, ime document released", who);
    prev
}

/// Give focus back to whatever had it, and let *that* window restore the IME.
pub fn focus_back(prev: HWND, who: &str) {
    if prev.0.is_null() {
        // Nothing to give it back to. Release the document rather than leave
        // it pointed at an overlay that is gone -- the terminal will take it
        // again on its next `WM_SETFOCUS`.
        crate::ime_focus(false);
        logf!("[overlay] {} closed with no previous focus", who);
        return;
    }
    let _ = unsafe { SetFocus(Some(prev)) };
    logf!("[overlay] {} closed, focus returned to the surface", who);
}
