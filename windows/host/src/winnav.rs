//! Two actions about the set of windows rather than about one of them:
//! `close_all_windows` and `goto_window`.
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
    GetForegroundWindow, IsIconic, SetForegroundWindow, ShowWindow, SW_RESTORE,
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
