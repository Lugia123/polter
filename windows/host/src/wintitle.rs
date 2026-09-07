//! The window's caption: the program's title, and the override on top of it.
//!
//! **Why this is a file and not two lines in the `set_title` arm.** There are
//! two sources for one string and they arrive from different places at
//! different times. The shell announces its own title (`OSC 0/2`, reaching the
//! host as `set_title`) whenever it feels like it -- every prompt, in some
//! configurations. `set_window_title` is the person saying what this window is
//! called. Written straight to the caption in arrival order, the second one
//! survives until the next prompt and then vanishes, which reads as "the
//! rename did not work" and is unreportable afterwards because nothing wrote
//! anything down.
//!
//! `tabs.rs` already learned this and states the rule for the tab label:
//! `title_override` "takes precedence over the computed title from the
//! terminal". This is the same rule one level up, for the frame's caption, and
//! it is deliberately the same shape so a reader who knows one knows the
//! other.
//!
//! **Keyed by frame, and that is a fix as well as a feature.** The `set_title`
//! arm wrote through `HWND_G` -- the *first* window -- so with two windows open
//! a title announced in the second renamed the first. That could not be left
//! alone here: an override stored per window and applied to a global one would
//! have been a new way to write the wrong window's name, on top of the old one.
//!
//! **What is not here: the empty string as a title.** `set_window_title ""`
//! clears the override rather than setting an empty caption, which is what
//! `Binding.zig` says of it ("If the title is empty, the ... override is
//! cleared") and what GTK's `setWindowTitle` does (`null` for an empty value).
//! A window with no caption at all is not something the core offers a way back
//! from.

use std::sync::Mutex;

use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::SetWindowTextW;

use crate::wlogf;

/// One window's two titles.
struct Entry {
    frame: isize,
    /// The last thing the program inside announced. Kept even while an
    /// override is up, because clearing the override has to put *something*
    /// back and "whatever the shell last said" is the only honest answer.
    program: String,
    /// What the person called this window, if they did.
    over: Option<String>,
}

static TITLES: Mutex<Vec<Entry>> = Mutex::new(Vec::new());

/// The caption this window should be showing right now.
///
/// Returns `None` when neither source has said anything yet -- which is not
/// the same as the empty string, and the caller leaves the caption alone
/// rather than blanking it.
fn resolve(frame: isize) -> Option<String> {
    let g = TITLES.lock().ok()?;
    let e = g.iter().find(|e| e.frame == frame)?;
    match &e.over {
        Some(t) => Some(t.clone()),
        None if !e.program.is_empty() => Some(e.program.clone()),
        None => None,
    }
}

/// Put `text` on the frame's caption.
///
/// **Nothing is locked here.** `SetWindowTextW` sends `WM_SETTEXT`
/// synchronously, so the window procedure of `frame` runs on this thread
/// before it returns -- the rule `tabs.rs` states for its own lock, and the
/// reason every caller below resolves the string first and drops the guard.
fn paint(frame: HWND, text: &str) {
    let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    unsafe {
        let _ = SetWindowTextW(frame, PCWSTR(wide.as_ptr()));
    }
}

/// Record and apply. Split out because both entry points end the same way and
/// the ordering -- resolve, drop, paint -- is the part that must not drift.
fn store_then_paint(frame: HWND, edit: impl FnOnce(&mut Entry)) {
    let key = frame.0 as isize;
    {
        let Ok(mut g) = TITLES.lock() else { return };
        match g.iter_mut().find(|e| e.frame == key) {
            Some(e) => edit(e),
            None => {
                let mut e = Entry { frame: key, program: String::new(), over: None };
                edit(&mut e);
                g.push(e);
            }
        }
    }
    if let Some(t) = resolve(key) {
        paint(frame, &t);
    }
}

/// The program in this window announced its own title (`set_title`).
///
/// **Recorded even when an override is up.** Dropping it would make clearing
/// the override show whatever was there before the person renamed the window,
/// which is a title the shell has since moved on from.
pub fn set_program(frame: HWND, title: &str) {
    let t = title.to_string();
    store_then_paint(frame, |e| e.program = t);
}

/// The person named this window (`set_window_title`), or cleared the name.
///
/// Answers whether the caption now shows what was asked for, which is what
/// `cb_action` hands back to the core.
pub fn set_override(frame: HWND, title: &str) -> bool {
    let cleared = title.is_empty();
    let t = title.to_string();
    store_then_paint(frame, |e| e.over = if cleared { None } else { Some(t) });
    match resolve(frame.0 as isize) {
        Some(now) => {
            wlogf!(
                frame,
                "[title] window title override {} -> caption {:?}",
                if cleared { "cleared" } else { "set" },
                now
            );
            true
        }
        // Cleared with no program title behind it: there is nothing to put
        // back, so the caption keeps the words it had. Said out loud rather
        // than reported as a plain success, because "cleared" and "cleared and
        // you cannot see it" are different outcomes on screen.
        None => {
            wlogf!(
                frame,
                "[title] window title override cleared, but the program in this window has \
                 announced no title; the caption is unchanged"
            );
            true
        }
    }
}

/// This window is gone.
pub fn forget(frame: HWND) {
    let key = frame.0 as isize;
    if let Ok(mut g) = TITLES.lock() {
        g.retain(|e| e.frame != key);
    }
}

/// How many windows have a title recorded, and how many of those are
/// overridden. **For tests and for the log**: a leak here is invisible
/// otherwise, because a stale entry does nothing until a frame handle is
/// reused.
pub fn depth() -> (usize, usize) {
    TITLES
        .lock()
        .map(|g| (g.len(), g.iter().filter(|e| e.over.is_some()).count()))
        .unwrap_or((0, 0))
}
