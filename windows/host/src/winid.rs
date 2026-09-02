//! Which window a log line is about, and how many there are.
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

/// A window has been created. **Called at creation, not at first sighting.**
///
/// `of` assigns a name lazily, which is enough for a log line but not for
/// counting: a window that has not logged yet does not exist as far as a lazy
/// registry is concerned, and "how many windows are there" is exactly the
/// question the shutdown rule turns on.
pub fn created(frame: HWND) -> u32 {
    let id = of(frame);
    crate::logf!("[win] w{} created; {} window(s)", id, count());
    id
}

/// A window has gone. Returns how many are left.
///
/// **The count is on the same line as the destruction, and so is the
/// consequence.** "w2 destroyed" and "0 windows left" and "therefore the
/// process is quitting" are three facts a reader would otherwise have to
/// assemble from three lines written at three moments -- and the assembling
/// is where the wrong conclusion gets drawn, because the interesting case is
/// precisely the one where the third does not follow from the second.
pub fn destroyed(frame: HWND) -> usize {
    let key = frame.0 as isize;
    // **Idempotent, and that is not tidiness.** One path records the window as
    // gone and then quits; another lets Windows destroy it and records it in
    // `WM_DESTROY`. If both ever run for one window, a naive second call would
    // find the frame missing, `of` would treat it as a window never seen
    // before, and the log would grow a `w2` that never existed. A phantom
    // window in the one log line the shutdown rule is read from is worse than
    // no line at all.
    let known = FRAMES
        .lock()
        .map(|f| f.iter().any(|k| *k == key))
        .unwrap_or(false);
    if !known {
        return count();
    }
    let id = of(frame);
    if let Ok(mut frames) = FRAMES.lock() {
        frames.retain(|f| *f != key);
    }
    let left = count();
    crate::logf!(
        "[win] w{} destroyed; {} window(s) left{}",
        id,
        left,
        if left == 0 { " -> quitting" } else { "" }
    );
    left
}

/// Every window, in the order they were created.
///
/// Handed out so a caller can print one line per window **at one instant**.
/// Reading two windows' state lines out of a log where each was printed when
/// it happened to change is comparing two different moments of the world, and
/// a diff of those says nothing about whether the two windows are independent.
pub fn all() -> Vec<HWND> {
    FRAMES
        .lock()
        .map(|f| f.iter().map(|k| HWND(*k as *mut std::ffi::c_void)).collect())
        .unwrap_or_default()
}

/// How many windows exist right now.
pub fn count() -> usize {
    FRAMES.lock().map(|f| f.len()).unwrap_or(0)
}

/// Where a request to close something came from.
///
/// **Four routes, one destination.** Closing the last tab from the menu, from
/// the strip's cross, from the window's own X (or Alt+F4), and from the core's
/// `close_window` all end at the same `DestroyWindow`, so a log that records
/// only the ending cannot say which of the four a person used -- and an
/// implementation that fixes three of them looks complete until somebody uses
/// the fourth, which is the one they use most. The window's own X is that
/// fourth one.
#[derive(Clone, Copy, Debug)]
pub enum CloseVia {
    Menu,
    StripCross,
    WindowXOrAltF4,
    CoreCloseWindow,
}

/// This window is finished: record it, and quit if it was the last one.
///
/// **One function, because there are four ways in and one thing to say.**
/// Three of the four routes called `PostQuitMessage` directly and never
/// destroyed anything, so `WM_DESTROY` -- and with it the only record that a
/// window had gone -- ran on exactly one of them. The asymmetry did not make
/// any criterion fail; it made "how many windows are left" unanswerable on
/// three routes out of four, and an unanswerable reading is the kind nobody
/// re-runs.
///
/// **The quit is behind `left == 0`, and this is the only place that decides
/// it.** Every route now reaches here the same way -- through
/// `close_window_now` and Windows' own `WM_DESTROY` -- so "this window is
/// gone" and "therefore the process is finished" are asked once, of a count
/// that four routes agree on.
///
/// **Called from `WM_DESTROY` and nowhere else.** That is not style: the
/// count has to be taken *after* the window is really gone, and `WM_DESTROY`
/// is the one moment where that is true no matter which route asked. A route
/// that recorded the window on the way in would take the count while the
/// window it is about is still on screen -- and on the interesting path, the
/// one where the process does not quit, that off-by-one is the difference
/// between quitting and not.
pub fn window_finished(frame: HWND) {
    let left = destroyed(frame);
    if left == 0 {
        unsafe { windows::Win32::UI::WindowsAndMessaging::PostQuitMessage(0) };
    } else {
        crate::wlogf!(frame, "[win] {} window(s) remain; the process stays", left);
    }
}

/// This window is to go: destroy it, and let `WM_DESTROY` do the recording.
///
/// **`DestroyWindow` is the whole of this function, and it is the whole of
/// what E6 turns on.** The three routes that close a window by closing its
/// last tab used to call `window_finished` directly: they recorded that the
/// window was finished and then never destroyed anything. With one window
/// that was invisible, because `PostQuitMessage` followed immediately and the
/// process took the window down with it. With two, the same code leaves an
/// empty frame sitting on screen with no tabs and no way to close it -- **and
/// every reading E1 asks for is satisfied while it does**: `w2 destroyed`,
/// `1 window left`, no `[main] exiting`, the pid unchanged. The log is green
/// and there is a window on the screen that should not be there.
///
/// So the destruction is real, and the record is made by the message Windows
/// sends back. Four routes in, one `DestroyWindow`, one `WM_DESTROY`, one
/// place that decides to quit.
///
/// **Not merged into `window_finished`.** They answer different questions and
/// run at different moments: this one runs while the window is still there
/// and asks Windows to take it away; that one runs after it is gone and asks
/// whether anything is left. Collapsing them would put the count back before
/// the destruction, which is the bug this pair exists to keep apart.
pub fn close_window_now(frame: HWND) {
    crate::wlogf!(frame, "[win] closing -> DestroyWindow");
    unsafe {
        // The result is logged rather than dropped: a `DestroyWindow` that
        // fails leaves the window on screen, which is exactly the E6 symptom,
        // and it would otherwise be a silent failure with a healthy-looking
        // log above it.
        if let Err(e) = windows::Win32::UI::WindowsAndMessaging::DestroyWindow(frame) {
            crate::wlogf!(frame, "[win] DestroyWindow FAILED: {e:?}; the window is still up");
        }
    }
}

pub fn close_requested(frame: HWND, via: CloseVia) {
    let what = match via {
        CloseVia::Menu => "menu",
        CloseVia::StripCross => "strip-x",
        CloseVia::WindowXOrAltF4 => "alt-f4",
        CloseVia::CoreCloseWindow => "core close_window",
    };
    crate::wlogf!(frame, "[win] close requested via {}", what);
}

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
