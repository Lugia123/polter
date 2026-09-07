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
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::WindowsAndMessaging::{
    CallWindowProcW, GetAncestor, GetClassNameW, GetForegroundWindow, GetParent,
    GetWindowLongPtrW, GetWindowThreadProcessId, SendMessageW, SetForegroundWindow,
    SetWindowLongPtrW, GA_ROOT, GWLP_USERDATA, GWLP_WNDPROC, WM_KEYDOWN,
};

use crate::hlogf;

/// Which window an overlay belongs to, for its log lines.
///
/// **`tabs::overlay_frame`, not the control's own ancestry.** An overlay is a
/// popup, so `GA_ROOT` from its edit control is the popup itself and answers
/// nothing; `GA_ROOTOWNER` would answer for the ones that were given an owner
/// and silently answer "no window" for the ones that were not. `overlay_frame`
/// is the project's single answer to this question -- the same one that
/// decides where the overlay is *placed* -- so if it is ever wrong, it is
/// wrong in one place for everybody rather than in a second way here.
fn frame() -> windows::Win32::Foundation::HWND {
    crate::tabs::overlay_frame()
}

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
    hlogf!(frame(), "[overlay] {} took focus, ime document released", who);
    prev
}

/// Give focus back to whatever had it, and let *that* window restore the IME.
pub fn focus_back(prev: HWND, who: &str) {
    if prev.0.is_null() {
        // Nothing to give it back to. Release the document rather than leave
        // it pointed at an overlay that is gone -- the terminal will take it
        // again on its next `WM_SETFOCUS`.
        crate::ime_focus(false);
        hlogf!(frame(), "[overlay] {} closed with no previous focus", who);
        return;
    }
    let _ = unsafe { SetFocus(Some(prev)) };
    hlogf!(frame(), "[overlay] {} closed, focus returned to the surface", who);
}

/// Give the **foreground** back when an overlay hides itself.
///
/// # Focus and foreground are two different things, and only one was being set
///
/// [`focus_back`] calls `SetFocus`, which moves the focus **within the calling
/// thread**. It does not move the foreground window, and nothing in this host
/// was moving that. So an overlay could hide itself and stay foreground, which
/// is what the command palette did after running a command:
///
///     GetForegroundWindow() = 0x50022A
///     GetClassNameW         = PolterCommandPalette
///     IsWindowVisible       = False
///     GetWindowRect         = 440,150..1000,500
///
/// on-screen and normally sized, so not drawn away or collapsed -- hidden, and
/// still holding the keyboard. **From the chair there is nothing to see**: no
/// window appeared, nothing closed, and every key from then on goes into
/// something invisible. That is the whole reason this is worth a shared
/// function rather than a line in one file.
///
/// # What this does not claim
///
/// These overlays are `WS_POPUP` created with `hWndParent = None`, so they
/// have no owner for Windows to hand activation to. That is the likely reason
/// nothing happened by itself -- **and it stays an explanation, not a
/// finding**, because it cannot be measured anywhere but on the machine. The
/// remedy does not rest on it: hand the foreground back, then *read it back*,
/// and the log says what actually happened either way.
///
/// # The guard asks about the process; the first version asked about this window
///
/// The courtesy is right: if the person has already clicked another
/// application, taking the foreground back would be this host yanking the
/// keyboard out of somebody else's window. **The first version implemented
/// that courtesy as `if fg != me { return }`, and that is the wrong
/// question.** At the instant an overlay hides, which of *this process's*
/// windows holds the foreground is exactly what is in flux. On the machine
/// the read came back as the frame, so the branch concluded "not mine, leave
/// it", returned, and the log showed one line -- `left alone` -- which reads
/// entirely normal. Three seconds later the foreground was the hidden overlay
/// and every keystroke was going into it.
///
/// So the question is asked about the **process**: is anything of ours in
/// front. That answer does not change while Windows is moving activation
/// between two of our own windows, and it keeps the courtesy exactly. A null
/// foreground is handed back to rather than left alone -- nobody holding it
/// is not somebody else holding it.
///
/// # The other mechanism, and why it is not in this change
///
/// These popups have no owner (`hWndParent = None`), and an owned popup is
/// one Windows hands activation back for by itself -- which is why
/// `settings_ui.rs` never had this. Setting an owner would be a second,
/// independent fix. **It is deliberately not done in the same step**: neither
/// can be tested anywhere but on the machine, and two untestable changes at
/// once means a run that still fails cannot say which half was wrong. If the
/// read-back below still comes out wrong, the owner is the next lever.
///
/// # And back to the window `prev` lives in, not to "window 1"
///
///  * **back to the window `prev` lives in**, not to "window 1". The window
///    that had the keyboard before the overlay took it is the one that should
///    have it after -- and `5351b0147` had just finished removing exactly that
///    "always window 1" answer from these same overlays. `GA_ROOT` because
///    `prev` is a surface *child*, and the foreground window is a top-level
///    one.
pub fn foreground_back(me: HWND, prev: HWND, who: &str) {
    unsafe {
        let fg = GetForegroundWindow();
        let mut pid = 0u32;
        if !fg.0.is_null() {
            let _ = GetWindowThreadProcessId(fg, Some(&mut pid));
        }
        if !fg.0.is_null() && pid != GetCurrentProcessId() {
            // **This line has to carry its own evidence.** `left alone` is the
            // sentence the broken version printed too, and there it meant "I
            // asked too early", not "somebody else has it". The two are
            // indistinguishable in a log unless the line says *whose* window
            // it is -- so the pid and the class go in it, and a reader can
            // decide rather than believe. Anything that prints `left alone`
            // without them is the old shape wearing the new words.
            let mut cls = [0u16; 64];
            let n = GetClassNameW(fg, &mut cls) as usize;
            hlogf!(
                frame(),
                "[overlay] {} hid; the foreground {:?} is pid {} class {:?}, another process -- left alone",
                who,
                fg,
                pid,
                String::from_utf16_lossy(&cls[..n])
            );
            return;
        }
        // **Which of ours it was, recorded.** `another of ours` is what came
        // back on the machine at the moment the old guard turned round and
        // left, and without this line in the log there is nothing to tell that
        // state from `this overlay` -- which is the whole of why the first fix
        // looked correct.
        let was = if fg.0.is_null() {
            "nothing"
        } else if fg == me {
            "this overlay"
        } else {
            "another of ours"
        };
        if prev.0.is_null() {
            // Nothing to hand it to. Said rather than passed over: this is the
            // state in which the keyboard is about to go nowhere, and it is
            // the one reading that distinguishes it from a working close.
            hlogf!(
                frame(),
                "[overlay] {} hid (foreground was {}) and there is no previous focus; NOTHING WAS HANDED BACK",
                who, was
            );
            return;
        }
        let want = GetAncestor(prev, GA_ROOT);
        let ok = SetForegroundWindow(want).as_bool();
        // **The read-back is the point.** `SetForegroundWindow` can be refused
        // and says so only in its return value, and the return value is a
        // claim about the request rather than about the state. This line is
        // what makes "the keyboard came back" a reading instead of an
        // assumption -- and it is what somebody on the machine greps for.
        let now = GetForegroundWindow();
        let verdict = if now == want {
            "the window that had it"
        } else if now == me {
            "STILL THE HIDDEN OVERLAY"
        } else {
            "somewhere else"
        };
        hlogf!(
            frame(),
            "[overlay] {} hid (foreground was {}); handed back to {:?} ok={} -- GetForegroundWindow now {:?}: {}",
            who, was, want, ok as u8, now, verdict
        );
    }
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
