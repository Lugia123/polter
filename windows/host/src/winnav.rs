//! Three actions about the set of windows rather than about one of them:
//! `close_all_windows`, `goto_window` and `toggle_visibility`.
//!
//! **They live together because they share the one hard question**: what *is*
//! the list of windows, and in what order? Both used to be unanswerable here
//! -- there was one frame -- and both become wrong in the same way if the list
//! is taken from Windows' Z-order, which changes every time the user clicks.
//! `winid::all()` hands back creation order, which is stable, and stability is
//! the property `goto_window` needs: "next" has to mean the same window twice
//! running or it is not navigation, it is a shuffle.
//!
//! **The macOS implementation was read and deliberately not copied.**
//! `Ghostty.App.swift`'s `gotoWindow` filters `NSApplication.shared.windows`
//! for visible, non-miniaturised windows and treats a native tab group as one
//! entry. None of those three ideas ports: this host has no native tab groups
//! (its tabs are its own strip), and skipping minimised windows would make
//! `goto_window` unable to reach one -- on macOS a miniaturised window is in
//! the Dock and reachable there, on Windows the taskbar button is the same
//! affordance but `goto_window` is often the *only* keyboard route back. So a
//! minimised window is a destination here and gets restored on arrival.

use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, IsIconic, IsWindow, IsWindowVisible, SetForegroundWindow, ShowWindow,
    SW_HIDE, SW_RESTORE, SW_SHOWNA,
};

use crate::{plogf, tabs, winid, wlogf};

/// `ghostty_action_goto_window_e`, whose members are `previous, next` in that
/// order (`src/apprt/action.zig`'s `GotoWindow`).
pub const GOTO_PREVIOUS: i32 = 0;
pub const GOTO_NEXT: i32 = 1;

/// Close every terminal window.
///
/// **The same terminus as `close_window`**, per window: `close_requested` for
/// the record and `close_window_now` to actually destroy it. Going any other
/// way would be a fifth close route, and the four that exist were only made to
/// agree recently -- `winid::window_finished` says what that cost.
///
/// **The list is taken once, before anything is destroyed.** `winid::all()`
/// reads a lock that `WM_DESTROY` writes; iterating it lazily while closing
/// would be walking a list that the walk itself is changing.
///
/// Answers how many were closed rather than a bare `true`, because "there were
/// none" is a real outcome and the core is told `false` for it: an action that
/// closed nothing was not performed.
pub fn close_all() -> bool {
    let frames = winid::all();
    if frames.is_empty() {
        // process-wide: the count of windows is a fact about the process, and
        // the point of the line is that there is no window to attribute it to
        plogf!("[win] close_all_windows: no windows are open; nothing to close");
        return false;
    }
    // process-wide: this line is about the whole set, before any one window is
    // singled out; the per-window lines follow from `close_requested`
    plogf!("[win] close_all_windows: {} window(s) to close", frames.len());
    for f in &frames {
        winid::close_requested(*f, winid::CloseVia::CoreCloseWindow);
        winid::close_window_now(*f);
    }
    true
}

/// The windows this host hid, and which of them had the keyboard.
///
/// **Recorded rather than recomputed**, and macOS is why: its
/// `toggleVisibility` keeps a `hiddenState` for exactly this and its comment
/// says what it buys -- *"we don't use NSApp.unhide because that will unhide
/// ALL hidden windows. We want to only bring forward the ones that we hid."*
/// The same rule here: a window the person had already minimised, or one made
/// while everything was away, is not ours to show.
static HIDDEN: std::sync::Mutex<Option<Hidden>> = std::sync::Mutex::new(None);

struct Hidden {
    /// `HWND` as `isize`, because a raw pointer is not `Send` and this sits
    /// behind a mutex. Every one is re-checked with `IsWindow` before it is
    /// touched again -- a window can be destroyed while the set is away.
    frames: Vec<isize>,
    /// The window that had the foreground when they went away, so the toggle
    /// back does not have to guess. Zero when the foreground was not ours.
    was_foreground: isize,
}

/// Hide every terminal window, or bring back the ones we hid.
///
/// # Which way it goes is read, not remembered
///
/// macOS decides this with `NSApp.isActive`: if the app has focus, hide;
/// otherwise activate and restore. The equivalent reading here is whether the
/// foreground window is one of ours, and it is a better question than a
/// stored flag for the reason every stored flag in this port has eventually
/// been wrong: the world can change underneath it. Somebody who hides the
/// windows, then closes the last of them from the taskbar, leaves a flag
/// saying "hidden" and nothing to show.
///
/// # The macOS fullscreen note is deliberately not ported
///
/// `Binding.zig` says *"When the focused surface is fullscreen, this method
/// does nothing"*, and `AppDelegate.swift` implements it with an explicit
/// guard on `keyWindow.styleMask.contains(.fullScreen)`. **That guard is
/// about macOS native fullscreen**, which puts the window in a Space of its
/// own; hiding an app out from under its own Space is what misbehaves.
///
/// This host has no Spaces. `tabs::go_fullscreen` is a `GWL_STYLE` change and
/// a `SetWindowPlacement` -- a borderless maximised ordinary window, which
/// hides and shows like any other. Copying the guard would import a
/// restriction whose reason does not exist here, and it would do it silently:
/// the person would press the key in fullscreen and nothing would happen,
/// with no line to say why.
///
/// # Yielding the foreground, and the one way this can go badly
///
/// When hiding, macOS "yields to the next application as determined by the
/// OS", and this does the same by **not choosing**: hiding the foreground
/// window is what makes Windows pick the next one, and picking somebody
/// else's window on their behalf is not this host's business.
///
/// **The read-back afterwards is not decoration.** If the foreground is still
/// one of our now-hidden windows, this has just built the defect task 300 was
/// about, at whole-application scale: every key goes into something invisible
/// and there is nothing on screen to say so. That state cannot be produced or
/// ruled out from the machine this is written on, so it is not claimed either
/// way -- it is *read*, on every run, and the line says which it was.
pub fn toggle_visibility() -> bool {
    let frames = winid::all();
    if frames.is_empty() {
        // process-wide: about the window set, not about any one window
        plogf!("[win] toggle_visibility: no windows are open; nothing to hide or show");
        return false;
    }

    let fg = unsafe { GetForegroundWindow() };
    let ours = winid::frame_of_window(fg).is_some();

    if ours {
        hide_all(&frames, fg)
    } else {
        show_again(fg)
    }
}

fn hide_all(frames: &[HWND], fg: HWND) -> bool {
    // **Only the ones that are actually up.** A window the person minimised
    // is already out of the way and is not ours to remember; restoring it
    // later would be this host undoing something they did.
    let mut hidden: Vec<isize> = Vec::new();
    for f in frames {
        if !unsafe { IsWindowVisible(*f) }.as_bool() {
            continue;
        }
        unsafe {
            let _ = ShowWindow(*f, SW_HIDE);
        }
        hidden.push(f.0 as isize);
        wlogf!(*f, "[win] toggle_visibility: hidden");
    }

    let n = hidden.len();
    if let Ok(mut slot) = HIDDEN.lock() {
        *slot = Some(Hidden { frames: hidden, was_foreground: fg.0 as isize });
    }

    // **Read back, do not assume.** See the note on `toggle_visibility`: if
    // this says one of ours, the keyboard is going into a window nobody can
    // see, and this line is the only thing that would ever say so.
    let now = unsafe { GetForegroundWindow() };
    let still_ours = winid::frame_of_window(now).is_some();
    // process-wide: about the window set as a whole
    plogf!(
        "[win] toggle_visibility: hid {} window(s); GetForegroundWindow now {:?} -- {}",
        n,
        now,
        if still_ours {
            "STILL ONE OF OURS, and every one of ours is hidden: the keyboard has nowhere visible to go"
        } else {
            "another application has it, which is what yielding means"
        }
    );
    n > 0
}

fn show_again(fg: HWND) -> bool {
    let Some(state) = HIDDEN.lock().ok().and_then(|mut s| s.take()) else {
        // Nothing of ours is in front and we hid nothing, so this is the
        // second half of a toggle whose first half never happened -- somebody
        // pressed it while another application was in front. Said out loud:
        // "nothing happened" and "nothing was there to happen to" are the
        // same silence otherwise.
        // process-wide: about the window set, not about any one window
        plogf!(
            "[win] toggle_visibility: the foreground is not ours and this host hid nothing;              nothing to bring back"
        );
        return false;
    };

    let mut shown = 0usize;
    let mut gone = 0usize;
    for raw in &state.frames {
        let f = HWND(*raw as *mut std::ffi::c_void);
        // **A window can be destroyed while the set is away.** Showing a dead
        // handle is not an error Windows reports in any way a reader would
        // see, so the two outcomes are counted apart.
        if !unsafe { IsWindow(Some(f)) }.as_bool() {
            gone += 1;
            continue;
        }
        unsafe {
            // `SW_SHOWNA` rather than `SW_SHOW`: showing them one at a time
            // with activation would leave whichever happened to be last in
            // front, which is not the window the person was using. The one
            // that was in front is chosen deliberately, below.
            let _ = ShowWindow(f, SW_SHOWNA);
        }
        shown += 1;
        wlogf!(f, "[win] toggle_visibility: shown again");
    }

    // The window that had the keyboard gets it back. Falling back to the
    // first one we showed rather than to "window 1", which is the answer
    // `5351b0147` spent a commit removing from the overlays.
    let want = HWND(state.was_foreground as *mut std::ffi::c_void);
    let target = if state.was_foreground != 0 && unsafe { IsWindow(Some(want)) }.as_bool() {
        Some(want)
    } else {
        state
            .frames
            .iter()
            .map(|r| HWND(*r as *mut std::ffi::c_void))
            .find(|f| unsafe { IsWindow(Some(*f)) }.as_bool())
    };

    let (asked, now) = match target {
        Some(t) => {
            let ok = unsafe { SetForegroundWindow(t) }.as_bool();
            (ok, unsafe { GetForegroundWindow() })
        }
        None => (false, fg),
    };
    // process-wide: about the window set as a whole
    plogf!(
        "[win] toggle_visibility: brought back {} window(s) ({} had been destroyed);          asked for {:?} ok={} -- GetForegroundWindow now {:?}: {}",
        shown,
        gone,
        target,
        asked as u8,
        now,
        match target {
            Some(t) if now == t => "the window that had it",
            _ if winid::frame_of_window(now).is_some() => "one of ours, but not that one",
            _ => "NOT ONE OF OURS -- they are visible and something else has the keyboard",
        }
    );
    shown > 0
}

/// Move focus to the next or previous window, wrapping.
///
/// `from` is the window the action named, when it named one. When it did not,
/// the foreground window stands in -- and if *that* is not one of ours the
/// walk starts at the first window, which is stated here rather than left to
/// be inferred from an `unwrap_or(0)`.
pub fn goto(from: Option<HWND>, dir: i32) -> bool {
    let frames = winid::all();
    if frames.len() < 2 {
        // process-wide: about the window set, not about any one window
        plogf!(
            "[win] goto_window: {} window(s) open; there is nowhere to go",
            frames.len()
        );
        return false;
    }

    let step: isize = match dir {
        GOTO_NEXT => 1,
        GOTO_PREVIOUS => -1,
        // Not guessed. A direction this host does not know is a core that has
        // grown a third one, and picking `next` for it would be a wrong answer
        // that looks like a working feature.
        other => {
            // process-wide: the action carried no window, only a direction
            plogf!("[win] goto_window: unknown direction {}; nothing moved", other);
            return false;
        }
    };

    let here = from
        .filter(|f| frames.contains(f))
        .or_else(|| winid::frame_of_window(unsafe { GetForegroundWindow() }));
    let start = match here.and_then(|h| frames.iter().position(|f| *f == h)) {
        Some(i) => i,
        None => {
            // process-wide: no window was identified, which is the fact
            plogf!(
                "[win] goto_window: neither the action nor the foreground names one of our \
                 windows; starting from the first"
            );
            0
        }
    };

    let n = frames.len() as isize;
    let to = (((start as isize + step) % n) + n) % n;
    let target = frames[to as usize];

    // Restore first: `SetForegroundWindow` on a minimised window brings it to
    // the front still minimised, which looks from the outside exactly like the
    // action doing nothing.
    let was_min = unsafe { IsIconic(target) }.as_bool();
    if was_min {
        unsafe {
            let _ = ShowWindow(target, SW_RESTORE);
        }
    }
    // **The result is kept, not dropped.** Windows refuses this call for a
    // process that does not hold the foreground privilege, and it refuses it
    // *silently* -- the window flashes in the taskbar instead. Reporting the
    // refusal as a performed action is the exact shape `action-arms-act.py`
    // exists to catch, one level down.
    let ok = unsafe { SetForegroundWindow(target) }.as_bool();
    if ok {
        tabs::focus_active(target);
    }
    wlogf!(
        target,
        "[win] goto_window {} from {} of {}: restored={} foreground={}",
        if step > 0 { "next" } else { "previous" },
        start + 1,
        frames.len(),
        was_min as u8,
        ok as u8
    );
    ok
}
