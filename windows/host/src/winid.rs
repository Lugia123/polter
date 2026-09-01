//! Which window a log line is about.
//!
//! **Written before multi-window, and that is the point.** Today there is one
//! frame, so every line in the host is unambiguous by default and the tag is
//! always `w1`. The moment a second frame exists, 53 lines that describe
//! per-window state -- `[strip] click -> activate`, `[session] saved geometry`,
//! `[tabmenu] shown for tab 3 of 5` -- stop having an answer to "which
//! window?", and **they do not turn red when that happens, they turn
//! unreadable.** A criterion that fails gets looked at; a criterion that can
//! no longer be judged gets believed.
//!
//! So the tag goes in first, while it can be verified against a tree where
//! the right answer is known.
//!
//! **The number is correlatable from outside**, which a bare counter would not
//! be: the first time a frame is seen it prints the pairing, so a reader with
//! only the log can tie `w2` to a window handle, and a reader with a debugger
//! or a window enumerator can tie that handle to something on screen.
//!
//! ```text
//! [01:02:03.004] [win] w1 = frame 0x000000000012ab34
//! [01:02:03.055] w1 [strip] click -> activate Tab(3)
//! ```
//!
//! **Not everything gets a tag, and the ones that do not are listed rather
//! than left to chance** -- see `UNTAGGED` in the test below. A line logged
//! from the core's callback thread does not always know which window it
//! concerns, and inventing one there would be worse than leaving it off: a
//! wrong window is a wrong answer, an absent one is a visible gap.

use std::sync::Mutex;

use windows::Win32::Foundation::HWND;

/// Frames in the order they were first seen. The index plus one is the tag.
///
/// A `Mutex` rather than a thread-local: `cb_action` arrives on whichever
/// thread the core is on, and a log line from there must get the same name for
/// a window as the one the message loop uses.
static FRAMES: Mutex<Vec<isize>> = Mutex::new(Vec::new());

/// The tag for a frame, assigning one if this is the first sighting.
pub fn of(frame: HWND) -> u32 {
    let key = frame.0 as isize;
    let mut frames = match FRAMES.lock() {
        Ok(f) => f,
        // A poisoned lock must not take the log down with it: `0` reads as
        // "no window", which is true and visibly not a window number.
        Err(_) => return 0,
    };
    if let Some(i) = frames.iter().position(|f| *f == key) {
        return i as u32 + 1;
    }
    frames.push(key);
    let id = frames.len() as u32;
    drop(frames);
    // The pairing, printed once. This is the line that makes the tag mean
    // something to somebody who was not here when it was assigned.
    crate::logf!("[win] w{} = frame {:?}", id, frame.0);
    id
}

/// `w1`, for embedding in a line.
pub fn tag(frame: HWND) -> String {
    format!("w{}", of(frame))
}

/// `logf!` for a line that is about one window.
///
/// The frame comes first because it is not optional: a caller that does not
/// know which window it is talking about should use `logf!` and appear in the
/// untagged list, not pass something plausible.
/// **`format_args!` on the caller's literal, not `concat!` into a new one.**
/// The first version built the format string with `concat!("{} ", $fmt)`, and
/// that quietly forbids the thing half this codebase writes:
///
/// ```ignore
/// wlogf!(frame, "[menu] root shown at {screen_x},{screen_y}");
/// ```
///
/// Rust captures `screen_x` from the surrounding scope only when the format
/// string is a literal **in the source**; a string produced by `concat!` is
/// not, and the call fails with `there is no argument named screen_x`. It is a
/// compile error rather than a silent one, but it is an error at *somebody
/// else's* call site, for a reason that is inside this macro -- so it would
/// have been read as "the tag cannot be used here" rather than "this macro is
/// too narrow". Keeping the caller's literal inside `format_args!` leaves the
/// capture working.
/// `logf!` for a line that is **not** about any one window.
///
/// **It expands to exactly what `logf!` does.** There is no runtime
/// difference and the output is byte-for-byte the same, because changing the
/// text would break every `grep` anyone has written against these lines. Its
/// whole value is at the source level: it is a declaration, made where the
/// line is written, that this fact belongs to the process rather than to a
/// window -- and `windows/tools/window-tagged-logs.py` requires the reason to
/// be written on the line above:
///
/// ```ignore
/// // process-wide: the static menu table, built once at startup
/// plogf!("[menu] built {} groups, {} items", groups, items);
/// ```
///
/// **Why this rather than a table of tags in the checker.** That is what it
/// was, and the table was a second place where a fact lived: `[menu]` is 4
/// lines about a window and 18 about a table, so no answer for the tag as a
/// whole was true. The declaration belongs to the line, where the person
/// writing it knows which of the two they are writing.
#[macro_export]
macro_rules! plogf {
    ($($a:tt)*) => { $crate::log_line(&format!($($a)*)) };
}

#[macro_export]
macro_rules! wlogf {
    ($frame:expr, $($a:tt)*) => {{
        let __w = $crate::winid::tag($frame);
        $crate::log_line(&format!("{} {}", __w, format_args!($($a)*)));
    }};
}
