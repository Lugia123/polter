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
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::WindowsAndMessaging::{
    GetAncestor, GetClassNameW, GetForegroundWindow, GetWindowThreadProcessId, SetForegroundWindow, GA_ROOT,
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

/// Where the keyboard goes back to, decided **at closing** (#1012).
///
/// `prev` is what the overlay remembered when it opened. The settings window
/// stays up for minutes; if the person switched tabs meanwhile, `prev` is a
/// pane in a tab that is no longer on screen, and handing it the keyboard is
/// how six keystrokes landed in a hidden terminal on the test machine. So
/// `prev` is kept only while its tab is still the active one of the current
/// window; otherwise the keyboard goes to where typing goes now. The rule is
/// `polter_settings_shell::handback`, tested there; this only reads the
/// windows it needs.
///
/// `me` is the overlay that is closing. A remembered window inside it, or
/// one that is hidden or disabled, cannot take the keyboard and is not kept
/// (#1016: the find bar handed it to its own hidden window).
pub fn handback_target(me: HWND, prev: HWND, who: &str) -> HWND {
    use polter_settings_shell::handback::{handback, Current, Prev};
    let alive = !prev.0.is_null() && unsafe { windows::Win32::UI::WindowsAndMessaging::IsWindow(Some(prev)) }.as_bool();
    let p = if !alive || crate::tabs::is_frame(prev) {
        Prev::Nothing
    } else {
        match crate::tabs::pane_place(prev) {
            Some((f, active)) => Prev::Pane { hwnd: prev.0 as isize, frame: f.0 as isize, tab_active: active },
            None => Prev::Other {
                hwnd: prev.0 as isize,
                usable: unsafe {
                    use windows::Win32::UI::Input::KeyboardAndMouse::IsWindowEnabled;
                    use windows::Win32::UI::WindowsAndMessaging::IsWindowVisible;
                    IsWindowVisible(prev).as_bool() && IsWindowEnabled(prev).as_bool() && !belongs_to(prev, me)
                },
            },
        }
    };
    let cur = frame();
    let current = (!cur.0.is_null()).then(|| Current {
        frame: cur.0 as isize,
        pane: crate::tabs::active_pane_hwnd(cur).map(|h| h.0 as isize),
    });
    let anywhere = crate::tabs::any_visible_active_pane().map(|h| h.0 as isize);
    let (to, why) = handback(p, current, anywhere);
    let target = HWND(to.unwrap_or(0) as *mut core::ffi::c_void);
    if target != prev {
        hlogf!(frame(), "[overlay] {} closing: remembered {:?} -> keyboard to {:?} ({:?})", who, prev, target, why);
    }
    target
}

/// Whether `h` is `overlay` or inside it. A focus remembered at opening that
/// is the overlay's own -- `show` run again while it was already up -- is no
/// previous focus (#1016).
pub fn belongs_to(h: HWND, overlay: HWND) -> bool {
    if h.0.is_null() || overlay.0.is_null() {
        return false;
    }
    h == overlay || unsafe { GetAncestor(h, GA_ROOT) } == unsafe { GetAncestor(overlay, GA_ROOT) }
}

/// Give focus back to whatever had it, and let *that* window restore the IME.
///
/// "Whatever had it" is checked first (`handback_target`, #1012): a pane
/// that has gone out of sight meanwhile does not get it, and neither does
/// anything of the closing overlay `me` itself (#1016).
pub fn focus_back(me: HWND, prev: HWND, who: &str) {
    let prev = handback_target(me, prev, who);
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
    // The same destination `focus_back` will give the keyboard to (#1012).
    let prev = handback_target(me, prev, who);
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
