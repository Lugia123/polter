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
use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, GA_ROOT};

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
    let id = assign(frame);
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
    // **Read before the removal, and that ordering is now load-bearing.**
    // `of` no longer mints, so after the `retain` below this frame has no
    // number at all and this line would say `w0`.
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

/// Take a number for a window. **The only place a frame enters `FRAMES`.**
///
/// **Split out of `of`, and the split is the whole of this fix.** `of` used
/// to do both jobs: it named a frame, and if it had not seen the handle
/// before it minted a number and kept it. That is fine for the one caller
/// that means "this window now exists" and wrong for the twenty that mean
/// "which window is this line about" -- because `count()` is read by exactly
/// one rule, "the last window closed, so quit", and a naming call is not
/// supposed to be able to change it.
///
/// It did change it, on the path where it mattered most. `window_finished`
/// takes the count *after* the frame is gone, then logs the answer with
/// `wlogf!` -- and `wlogf!` names the frame it was handed, which was the one
/// just removed. So the count that decided not to quit was followed
/// immediately by that same handle being put back under a fresh number. With
/// one window nothing showed: `PostQuitMessage` had already gone out before
/// the log line ran. With two, the first window's handle was re-registered
/// when it closed, and the second close counted it and stopped at one.
/// Windows all gone, process still running, and every line in the log
/// individually correct.
///
/// **The number is the index plus one, and numbers are therefore reused.**
/// That is worth stating because it is what made the defect hard to see from
/// the log: the re-registered handle came back as `w2` on a run that really
/// did have a `w2`, so "every `wN` has a `created` line" was true while the
/// process refused to exit. The reading that does hold is the handle -- the
/// pairing line for one `frame 0x...` appearing twice.
fn assign(frame: HWND) -> u32 {
    let key = frame.0 as isize;
    // **A null handle is not a window, and must not become one.** A caller
    // that resolved a frame and got nothing would otherwise mint
    // `w4 = frame 0x0`, and that entry never leaves `FRAMES`: `count` reports
    // it forever, and `count` is what "the last window closed, so quit" is
    // read from.
    if key == 0 {
        return 0;
    }
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
    //
    // **Once per registration, not once per window.** If this line ever
    // appears twice for one `frame 0x...`, a handle was registered, removed
    // and registered again -- which is the defect above, and this is the
    // reading that shows it.
    crate::logf!("[win] w{} = frame {:?}", id, frame.0);
    id
}

/// The number of a window that is registered right now, or `0`.
///
/// **This only looks.** An unknown handle gets `0`, which reads as "no
/// window" and is visibly not a window number -- the same answer a null
/// handle and a poisoned lock get, for the same reason. See [`assign`] for
/// what used to happen instead and what it cost.
///
/// `0` has three causes and they are all "this is not one of the terminal
/// windows *now*": never registered (a pane, the quick terminal), already
/// removed (any line logged after `destroyed`), or a handle that is not a
/// window at all. A caller that needs to tell them apart is asking a question
/// this function does not answer; [`frame_of_window`] is the one that checks
/// against the window registry.
pub fn of(frame: HWND) -> u32 {
    let key = frame.0 as isize;
    if key == 0 {
        return 0;
    }
    let Ok(frames) = FRAMES.lock() else {
        return 0;
    };
    match frames.iter().position(|f| *f == key) {
        Some(i) => i as u32 + 1,
        None => 0,
    }
}

/// `w1`, for embedding in a line.
/// The terminal window a handle belongs to, when it belongs to one.
///
/// **`of` will name any handle it is given**, and that is the trap this
/// closes. Hand it a pane and it mints a number for a window that does not
/// exist; the log then has a `w4` nobody can find, which reads exactly like a
/// real one. So a handle is walked to its root and the root is *checked
/// against the registry* rather than assumed to be in it.
///
/// **`None` is a real answer, not a failure**, and it has two causes the port
/// actually has:
///
///  - the quick terminal is one window for the whole process and is
///    deliberately not a registered frame, and `dnd::attach` runs for its
///    surface as well as for panes;
///  - a pane torn down after its window left the registry has no window left
///    to name.
///
/// Both are "this line is not about one of the terminal windows", which is
/// what the caller wants to say, and neither is "some window, unknown".
pub fn frame_of_window(hwnd: HWND) -> Option<HWND> {
    if hwnd.0.is_null() {
        return None;
    }
    let root = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let key = root.0 as isize;
    crate::tabs::with_windows(|ws| ws.iter().any(|w| w.frame == key)).then_some(root)
}

/// **`w?` when the handle is not a registered window**, which is a real
/// answer and not a failure.
///
/// The lines this happens on are the ones logged *after* a window is gone --
/// `window_finished`'s own "the process stays", `tabs::remove_window`,
/// `strip::forget`. They lose the window's number, and that is a loss worth
/// naming: it is information the previous version appeared to keep.
///
/// **It only appeared to.** What it printed there was a *fresh* number for a
/// handle that already had one -- `w2` for what the reader had been calling
/// `w1` for the whole run. A wrong number is read as a right one; `w?` is
/// read as what it is. And the cost of appearing to keep it was `count()`
/// never reaching zero.
pub fn tag(frame: HWND) -> String {
    match of(frame) {
        0 => "w?".to_string(),
        id => format!("w{}", id),
    }
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
/// `logf!` for a line whose subject is a **handle**, which may or may not be
/// one of the terminal windows.
///
/// It is `wlogf!` when the handle resolves to a registered frame and `plogf!`
/// when it does not -- see [`frame_of_window`] for the two ways that happens.
/// The reason a `plogf!` normally has to carry at its call site is written
/// here instead, once, because it is the same reason at every one of them:
/// the alternative was the same sentence copied to a dozen sites, which is a
/// dozen places for one fact to be right.
///
/// **A macro the checker has not been taught is a site it cannot see**, and
/// an invisible site reads exactly like a classified one -- so
/// `windows/tools/window-tagged-logs.py` knows this name and has a canary for
/// it.
#[macro_export]
macro_rules! hlogf {
    ($hwnd:expr, $($a:tt)*) => {{
        match $crate::winid::frame_of_window($hwnd) {
            Some(__f) => $crate::wlogf!(__f, $($a)*),
            None => $crate::plogf!($($a)*),
        }
    }};
}

#[cfg(test)]
mod registry_tests {
    use super::*;

    /// `FRAMES` is one static and the tests below all write it, so they take
    /// turns. **Not `#[serial]`**: this crate has no such dependency, and a
    /// lock held for the body of each test is the same guarantee.
    static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

    /// A fresh registry, and the guard that keeps it fresh for one test.
    fn empty() -> std::sync::MutexGuard<'static, ()> {
        let g = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
        if let Ok(mut f) = FRAMES.lock() {
            f.clear();
        }
        g
    }

    fn h(n: isize) -> HWND {
        HWND(n as *mut std::ffi::c_void)
    }

    /// **The floor for everything below.** If `assign` stopped registering,
    /// every "the count did not move" assertion would pass while saying
    /// nothing, because the count would never move for anybody.
    #[test]
    fn assign_registers_and_numbers_from_one() {
        let _g = empty();
        assert_eq!(assign(h(0x1000)), 1);
        assert_eq!(count(), 1);
        assert_eq!(assign(h(0x2000)), 2);
        assert_eq!(count(), 2);
        // Asking again is not a second registration.
        assert_eq!(assign(h(0x1000)), 1);
        assert_eq!(count(), 2);
    }

    /// **The defect, in the order it happened.**
    ///
    /// `window_finished` takes the count after the frame is gone and then
    /// logs the answer with `wlogf!`, which names the frame it was handed --
    /// the one just removed. While `of` minted, that naming call put the
    /// handle back, and the *next* window's close counted it and stopped at
    /// one. Windows all gone, process still running.
    ///
    /// With one window it was invisible: `PostQuitMessage` went out before
    /// the log line ran. So the test needs two.
    #[test]
    fn naming_a_destroyed_window_does_not_put_it_back() {
        let _g = empty();
        let (w1, w2) = (h(0xa0930), h(0x1107b2));
        assign(w1);
        assign(w2);

        assert_eq!(destroyed(w1), 1, "one window left after the first closes");
        // This is `window_finished`'s own log line, and `tabs::remove_window`
        // and `strip::forget` after it: three calls that name a handle which
        // is no longer registered.
        let _ = tag(w1);
        let _ = tag(w1);
        let _ = tag(w1);
        assert_eq!(count(), 1, "naming a gone window must not register it");

        // The reading the shutdown rule turns on.
        assert_eq!(destroyed(w2), 0, "the last window leaves none behind");
    }

    /// **`N = 2`, because the numbers are reused.**
    ///
    /// The id is the index plus one, so a handle put back after a removal
    /// takes a number that already belonged to somebody. That aliasing is
    /// what made the log look clean, and it is why closing one window before
    /// the last is not a sufficient test: a run that only ever closes one
    /// could land on an arrangement where the stale entry is the one being
    /// removed anyway.
    #[test]
    fn the_count_reaches_zero_after_two_windows_have_been_closed() {
        let _g = empty();
        let ws = [h(0x11), h(0x22), h(0x33)];
        for w in ws {
            assign(w);
        }
        assert_eq!(destroyed(ws[0]), 2);
        let _ = tag(ws[0]);
        assert_eq!(destroyed(ws[1]), 1);
        let _ = tag(ws[1]);
        assert_eq!(destroyed(ws[2]), 0, "no window may be left over");
        assert_eq!(count(), 0);
    }

    /// An unknown handle has no number, and `tag` says so rather than
    /// inventing one. **`w?` is the visible half of the fix**: the previous
    /// version printed a fresh `wN` here, which reads exactly like a real
    /// window number and was one.
    #[test]
    fn an_unknown_handle_is_not_a_window() {
        let _g = empty();
        assign(h(0x1000));
        assert_eq!(of(h(0xdead)), 0);
        assert_eq!(tag(h(0xdead)), "w?");
        assert_eq!(count(), 1, "asking about a stranger must not admit it");
        // A registered one still names itself.
        assert_eq!(tag(h(0x1000)), "w1");
    }

    /// A null handle is not a window. It was minted as one once, and the
    /// entry never left `FRAMES`.
    #[test]
    fn a_null_handle_is_never_registered() {
        let _g = empty();
        assert_eq!(assign(h(0)), 0);
        assert_eq!(of(h(0)), 0);
        assert_eq!(tag(h(0)), "w?");
        assert_eq!(count(), 0);
    }

    /// `destroyed` is idempotent, and the second call must not re-admit the
    /// frame either -- it reads the count and leaves.
    #[test]
    fn destroying_twice_does_not_resurrect() {
        let _g = empty();
        let w = h(0x77);
        assign(w);
        assert_eq!(destroyed(w), 0);
        assert_eq!(destroyed(w), 0);
        assert_eq!(count(), 0);
    }
}
