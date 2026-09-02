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

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetFocus, SetFocus, VK_ESCAPE};
use windows::Win32::UI::WindowsAndMessaging::{
    CallWindowProcW, GetParent, GetWindowLongPtrW, SendMessageW, SetWindowLongPtrW,
    GWLP_USERDATA, GWLP_WNDPROC, WM_KEYDOWN,
};

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

// --------------------------------------------------- letting Escape through
//
// **A native control eats Escape and tells nobody.** An `EDIT`, a `COMBOBOX`
// and a `BUTTON` all take the key and hand it to `DefWindowProcW`, which does
// nothing with it; Win32 does not bubble keys to the parent. So a page whose
// only way out is `Escape`, handled in the *page's* window procedure, closes
// only while nothing inside it has focus -- and the settings page puts focus
// into its first control the moment it opens. There was no way out.
//
// **Why this is here and not a third copy of the subclass in `strip.rs` and
// `prompt.rs`.** Those two subclass an edit to make a *one-field dialog*:
// Return means accept, Escape means cancel, losing focus decides which. That
// is a contract about editing one value, and it belongs to those boxes. What
// a page needs is narrower and different: **do not swallow the key that
// closes me**. Folding the three together would push dialog semantics onto a
// page that has a Save button, so what is shared here is only the part that
// is the same -- and the part whose absence is silent.

/// Let `control`'s parent see **the keys that close the page it is on**.
///
/// Two of them, because a page needs a way out that works wherever focus is:
///
///  * `Escape`.
///  * `Ctrl+Shift+,` -- **the chord that opened the page**. It is a host
///    accelerator in `keys.rs`, and that path runs only for a *surface*
///    window, so once focus is inside the page the key never reaches the code
///    that would toggle it. The page handles it itself; this makes sure a
///    control does not eat it first.
///
/// **The second key was the half that was missed.** The first version of this
/// forwarded only `Escape`, the page grew a branch for the chord, and the
/// commit message said the page could now be closed from anywhere -- while
/// the chord was still being swallowed by whichever control had focus, which
/// is the condition that was broken to begin with. A fix for one of two ways
/// out reads exactly like a fix for both.
///
/// A `COMBOBOX` with its list dropped keeps `Escape`: closing the list is what
/// it means there, and it is what every other Windows program does. The second
/// press then reaches the parent, because the list is no longer down.
///
/// **The chord half has not been verified on a machine, and cannot be with
/// the input tooling in use.** The injector cannot produce a comma:
/// `key(",")` fails outright and `key("ctrl+shift+,")` reports success while
/// sending nothing -- shown by a positive control, where the same chord aimed
/// at a focused terminal did not open the page it opens. So the earlier
/// reading of "the chord does nothing" was measuring the tool, not this code.
/// **What is written here is what the code does when read; nothing has
/// watched it happen.** Verifying it needs another input channel -- a real
/// keyboard, or an injector that can send `VK_OEM_COMMA` with two modifiers.
pub fn forward_escape_to_parent(control: HWND) {
    if control.0.is_null() {
        return;
    }
    unsafe {
        let prev = SetWindowLongPtrW(control, GWLP_WNDPROC, escape_proc as *const () as isize);
        SetWindowLongPtrW(control, GWLP_USERDATA, prev);
    }
}

/// `CB_GETDROPPEDSTATE`. Spelled numerically because the constant lives
/// behind a Controls feature this crate does not otherwise need.
const CB_GETDROPPEDSTATE: u32 = 0x0157;

fn held(vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY) -> bool {
    (unsafe { windows::Win32::UI::Input::KeyboardAndMouse::GetKeyState(vk.0 as i32) } as u16
        & 0x8000)
        != 0
}

unsafe extern "system" fn escape_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    use windows::Win32::UI::Input::KeyboardAndMouse::{VK_CONTROL, VK_OEM_COMMA, VK_SHIFT};
    unsafe {
        let prev = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if msg == WM_KEYDOWN {
            let key = wp.0 as u16;
            let is_escape = key == VK_ESCAPE.0
                && SendMessageW(hwnd, CB_GETDROPPEDSTATE, None, None).0 == 0;
            let is_chord = key == VK_OEM_COMMA.0 && held(VK_CONTROL) && held(VK_SHIFT);
            if is_escape || is_chord {
                if let Ok(parent) = GetParent(hwnd) {
                    SendMessageW(parent, WM_KEYDOWN, Some(wp), Some(lp));
                    return LRESULT(0);
                }
            }
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT =
            std::mem::transmute(prev);
        CallWindowProcW(Some(f), hwnd, msg, wp, lp)
    }
}
