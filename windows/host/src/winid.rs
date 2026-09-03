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

/// The live frames, each with **the number it was given when it was created**.
///
/// A `Mutex` rather than a thread-local: `cb_action` arrives on whichever
/// thread the core is on, and a log line from there must get the same name for
/// a window as the one the message loop uses.
///
/// **The number used to be the position in this list, and that was wrong in a
/// way the log could not show.** `Vec::retain` closes the gap it makes, so
/// closing the first of two windows renumbered the survivor from `w2` to
/// `w1` -- and a real log has been read where `w1` names one handle while it
/// is created and a different handle when it is destroyed. Every line is
/// individually correct and the sequence is unreadable.
///
/// It is not only a reading problem. `uia.rs` publishes this number twice:
/// as the window's `AutomationId` (the string an automation client uses to
/// *find* an element) and inside every `RuntimeId` (what a client caches to
/// recognise an element it has already seen). A number that changes because
/// **some other window closed** makes a stable-looking identity quietly start
/// meaning something else.
static FRAMES: Mutex<Vec<(isize, u32)>> = Mutex::new(Vec::new());

/// The next number to hand out. **Monotonic, and never reused.**
///
/// Starts at 1 so `w0` stays available as "no window", which is what [`of`]
/// returns for a handle it does not know.
static NEXT_ID: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);

/// A window has been created: **both registries learn about it here, and
/// there is nowhere to stand between them.**
///
/// A frame is recorded in two places -- `FRAMES` for its identity and number,
/// `tabs::Registry` for its state -- and they are rightly separate things
/// (see `per-window.md` §3). But two registrations written as two statements
/// leave a moment when one has happened and the other has not, and that
/// moment is a place code can be added later.
///
/// **The moment was real and it was wide.** Until `57c7384a9` the two calls
/// sat on either side of `ShowWindow`, which dispatches messages
/// synchronously -- so window procedures genuinely ran while `tabs` knew
/// about the frame and `winid` did not. Moving them adjacent narrowed it to
/// "between two statements with no message pump", which has no observer.
/// **That is a fact about today's code, not about the code**: one call that
/// pumps messages, added between them by somebody who has not read this,
/// puts it back -- and nothing goes red when they do. `wlogf!` would print a
/// perfectly good window number (`FRAMES` already says yes), and
/// `window-tagged-logs.py` counts `hlogf!` as classified wherever it sits.
///
/// So the two are one act with one name. **The order inside is load-bearing**
/// and is the only reason this is a function rather than a comment:
/// `tabs::add_window` logs through `wlogf!`, which asks this module for a
/// number, so the number has to exist before it runs.
///
/// The remaining seam is that `tabs::add_window` is still reachable on its
/// own from anywhere in the crate. Rust has no narrower word than
/// `pub(crate)` for "only this function may call you", so that half is a
/// sentence on `add_window` rather than a rule the compiler keeps -- said
/// here so the gap is known rather than assumed shut.
pub fn created(frame: HWND) -> u32 {
    let id = assign(frame);
    // **Second, not first.** See above: `add_window` logs with `wlogf!`.
    crate::tabs::add_window(frame);
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
        .map(|f| f.iter().any(|(k, _)| *k == key))
        .unwrap_or(false);
    if !known {
        return count();
    }
    // **Read before the removal, and that ordering is now load-bearing.**
    // `of` no longer mints, so after the `retain` below this frame has no
    // number at all and this line would say `w0`.
    let id = of(frame);
    if let Ok(mut frames) = FRAMES.lock() {
        // **The number does not come back.** `retain` still closes the gap in
        // this list -- it is a list of live windows and nothing more -- but
        // the id travels with the entry rather than with the position, so
        // removing one does not rename any other.
        frames.retain(|(k, _)| *k != key);
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

/// The whole of what [`empty_agrees`] objects to, as a function of two
/// numbers.
///
/// **Separated so it can be pinned.** The one way this invariant goes wrong
/// without anybody noticing is by quietly widening from "they disagree about
/// *empty*" to "they are not equal" -- a one-character edit, and the result
/// fires on the two legitimate disagreements every window has. The tests
/// below hold both halves: that `0` vs `n` is caught, and that `n` vs `m` is
/// **not**.
fn disagrees_about_empty(mine: usize, theirs: usize) -> bool {
    (mine == 0) != (theirs == 0)
}

/// **Do the two registries agree that there are no windows left?**
///
/// Called at the end of `WM_DESTROY`, once both have been updated.
///
/// **It asserts zero and nothing else, and that restraint is the whole
/// design.** `winid::FRAMES` and `tabs::Registry` are legitimately two
/// different things -- one holds identity, one holds state -- and they are
/// *supposed* to disagree for a moment twice in every window's life: between
/// `created` and `tabs::add_window` on the way in, and between
/// `window_finished` and `tabs::remove_window` on the way out. An invariant
/// that demanded the two counts be equal at all times would fire on the
/// normal path, and **an invariant that cries wolf is switched off, which
/// leaves less behind than never having written it.**
///
/// Zero is different. Zero is the value the shutdown rule turns on, it is
/// checked at the one moment both registries have finished with this window,
/// and there is no legitimate way for one of them to be empty while the other
/// is not.
///
/// **This exists because the disagreement was already in the log and nobody
/// read it as one.** On the run that would not exit, these two lines were
/// printed one after the other:
///
/// ```text
/// w2 [win] 1 window(s) remain; the process stays
/// w2 [win] state dropped; 0 window(s) tracked
/// ```
///
/// One and zero, adjacent, and the contradiction *was* the answer -- but
/// nothing anywhere said those two numbers had to agree, so a reader takes
/// agreement as corroboration and disagreement as noise. **Two numbers
/// printed side by side are not a cross-check until something says they must
/// match.** This is that something.
pub fn empty_agrees(frame: HWND) {
    let mine = count();
    let theirs = crate::tabs::with_windows(|ws| ws.len());
    if !disagrees_about_empty(mine, theirs) {
        return;
    }
    // process-wide: how many windows the process has left is not a fact about
    // any one window, and by this point the window this ran for is gone
    crate::plogf!(
        "[win] REGISTRIES DISAGREE: winid has {} window(s), tabs has {} -- \
         one of them is empty and the other is not, just after frame {:?} \
         was destroyed. The quit decision reads the first of those two.",
        mine,
        theirs,
        frame.0
    );
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
        .map(|f| f.iter().map(|(k, _)| HWND(*k as *mut std::ffi::c_void)).collect())
        .unwrap_or_default()
}

/// How many windows exist right now.
///
/// **Private, and that is the point of it being private.** This number is
/// read by exactly one rule -- "the last window closed, so quit" -- and until
/// now it was `pub` with no caller outside this file. "Only one reader" was
/// therefore a fact about today rather than about the code, and a fact about
/// today stops being true without anything saying so.
///
/// A caller elsewhere that wants to know whether any windows are left is
/// asking the question [`empty_agrees`] answers, and should ask it there --
/// where the two registries that could disagree about it are both consulted.
fn count() -> usize {
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
/// **The number used to be the index plus one, and numbers were therefore
/// reused.** That is worth keeping on the page, because it is what made the
/// defect above hard to see from the log: the re-registered handle came back
/// as `w2` on a run that really did have a `w2`, so "every `wN` has a
/// `created` line" was true while the process refused to exit. The reading
/// that held then, and still holds, is the handle -- the pairing line for one
/// `frame 0x...` appearing twice.
///
/// The number comes from `NEXT_ID` now and is never handed out twice, so the
/// number is a usable identity as well. **That did not make the handle
/// reading redundant**: the handle is what proves a *registration* happened
/// twice, which is the fault, while a repeated number would now prove only
/// that this counter is broken.
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
    if let Some((_, id)) = frames.iter().find(|(k, _)| *k == key) {
        return *id;
    }
    // **Taken from a counter, not from the length.** A length-derived number
    // is a position, and positions move when something ahead of them is
    // removed; this one belongs to the window for as long as the process
    // lives, and is not handed out again after it goes.
    let id = NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    frames.push((key, id));
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
    match frames.iter().find(|(k, _)| *k == key) {
        Some((_, id)) => *id,
        None => 0,
    }
}

/// `w1`, for embedding in a line.
/// The terminal window a handle belongs to, when it belongs to one.
///
/// **This asks a different registry from [`of`], and the difference is the
/// whole reason it exists.** `of` answers from `FRAMES` -- identity -- and it
/// answers about the handle it is given, whatever that handle is. A pane is
/// not a frame, so `of` would say `0` for it and the line would be tagged
/// `w?`: not wrong, but not an answer either. This walks the handle to its
/// root and checks that root against the *state* registry, so the caller gets
/// "the window this thing lives in" rather than "this thing".
///
/// (It used to close a sharper trap. `of` minted a number for any handle it
/// was handed, so a pane reaching it invented a window that does not exist --
/// and that entry never left `FRAMES`, whose size decides when the process
/// quits. `of` only looks now; `57c7384a9`.)
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
    ///
    /// `pub(super)` under the alias `reset` as well, because
    /// `numbering_tests` needs the same guard: two test modules writing one
    /// static without sharing the lock is the flake that would be blamed on
    /// the code under test.
    pub(super) fn reset() -> std::sync::MutexGuard<'static, ()> {
        empty()
    }

    fn empty() -> std::sync::MutexGuard<'static, ()> {
        let g = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
        if let Ok(mut f) = FRAMES.lock() {
            f.clear();
        }
        // **The counter goes back too.** It is process-wide and monotonic, so
        // without this the second test to run would start at whatever the
        // first left behind, and every assertion about a specific number
        // would depend on the order the harness happened to pick.
        NEXT_ID.store(1, std::sync::atomic::Ordering::Relaxed);
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

    /// **`N = 2`, and the reason has outlived the aliasing it was written
    /// for.**
    ///
    /// It was written when the id was the index plus one: a handle put back
    /// after a removal took a number that already belonged to somebody, and a
    /// run that only ever closed one window could land on an arrangement
    /// where the stale entry happened to be the one being removed anyway.
    /// Numbers do not alias any more -- but the *positions* in `FRAMES` still
    /// shift on every removal, and this is the test that walks more than one
    /// of them.
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

#[cfg(test)]
mod invariant_tests {
    use super::disagrees_about_empty as d;

    /// The case it exists for: one registry empty, the other not. This is
    /// what the log showed on the run that would not exit -- `1` next to
    /// `0`, adjacent lines, and nothing saying they had to agree.
    #[test]
    fn one_empty_and_one_not_is_a_disagreement() {
        assert!(d(1, 0));
        assert!(d(0, 1));
        assert!(d(0, 3));
        assert!(d(7, 0));
    }

    /// **The half that keeps it quiet, and the half that would be lost by a
    /// one-character edit.**
    ///
    /// `(mine == 0) != (theirs == 0)` becoming `mine != theirs` looks like a
    /// simplification and is not: every window legitimately spends two short
    /// moments counted by one registry and not the other -- between `created`
    /// and `tabs::add_window`, and between `window_finished` and
    /// `tabs::remove_window`. An invariant that fired there would be switched
    /// off, and a switched-off invariant leaves less behind than one never
    /// written.
    #[test]
    fn unequal_but_both_present_is_not_a_disagreement() {
        assert!(!d(1, 2), "the create-side gap must not fire this");
        assert!(!d(2, 1), "the destroy-side gap must not fire this");
        assert!(!d(3, 9));
    }

    /// Agreement, both directions. The zero case is the one the shutdown rule
    /// reads; the non-zero case is every other moment.
    #[test]
    fn agreement_is_silent() {
        assert!(!d(0, 0));
        assert!(!d(4, 4));
    }
}

#[cfg(test)]
mod numbering_tests {
    use super::*;

    fn guard() -> std::sync::MutexGuard<'static, ()> {
        super::registry_tests::reset()
    }

    fn h(n: isize) -> HWND {
        HWND(n as *mut std::ffi::c_void)
    }

    /// **The defect, exactly as the log showed it.**
    ///
    /// Two windows are created; the first is closed. The survivor's number
    /// must not change -- it used to, because the number was the position in
    /// `FRAMES` and `retain` closes the gap. A real log has `w1 = frame
    /// 0x1a009c` and `w2 = frame 0x2f07a0` at creation, and then `0x2f07a0`
    /// being destroyed **as `w1`**: one name, two windows, in one file.
    #[test]
    fn closing_a_window_does_not_renumber_the_others() {
        let _g = guard();
        let (a, b) = (h(0x1a009c), h(0x2f07a0));
        assert_eq!(assign(a), 1);
        assert_eq!(assign(b), 2);
        destroyed(a);
        assert_eq!(of(b), 2, "the survivor keeps the number it was created with");
        assert_eq!(tag(b), "w2");
    }

    /// A number is never handed out twice, **even after the window that had
    /// it is gone**.
    ///
    /// This is the half that a "numbers are unique right now" check would
    /// miss: with position-derived ids, the id of a closed window is free
    /// again the moment the next one opens, and the log then has two
    /// unrelated windows answering to one name at different times.
    #[test]
    fn a_number_is_never_reused() {
        let _g = guard();
        let first = assign(h(0x100));
        destroyed(h(0x100));
        let second = assign(h(0x200));
        assert_ne!(first, second, "a retired number must not come back");
        // And again, so a single spare is not mistaken for a rule.
        destroyed(h(0x200));
        let third = assign(h(0x300));
        assert_ne!(second, third);
        assert_ne!(first, third);
    }

    /// **The floor for the two tests above.** If `assign` stopped handing out
    /// numbers at all -- returning `0` for everything -- `a_number_is_never_reused`
    /// would fail, but `closing_a_window_does_not_renumber_the_others` would
    /// pass while saying nothing. Numbers have to be real and to start at 1.
    #[test]
    fn numbers_start_at_one_and_increase() {
        let _g = guard();
        assert_eq!(assign(h(0xa)), 1);
        assert_eq!(assign(h(0xb)), 2);
        assert_eq!(assign(h(0xc)), 3);
        // Asking again is not a new number.
        assert_eq!(assign(h(0xa)), 1);
    }

    /// Removing from the middle is the arrangement where a position-derived
    /// id renames the most windows at once.
    #[test]
    fn removing_from_the_middle_renames_nobody() {
        let _g = guard();
        let ws = [h(0x11), h(0x22), h(0x33), h(0x44)];
        for w in ws {
            assign(w);
        }
        destroyed(ws[1]);
        assert_eq!(of(ws[0]), 1);
        assert_eq!(of(ws[2]), 3, "third window keeps w3, not w2");
        assert_eq!(of(ws[3]), 4);
        assert_eq!(count(), 3, "the count still follows the live windows");
    }
}

#[cfg(test)]
mod invariant_floor {
    //! **Does `empty_agrees` actually say anything?**
    //!
    //! `invariant_tests` pins the predicate: `0` against `n` is a
    //! disagreement, `n` against `m` is not. That is the half that can be
    //! reasoned about. It does not answer the question this module exists
    //! for, which is whether the check, wired up to the two real registries
    //! and given a real disagreement, **produces a line**.
    //!
    //! That question has to be asked, because the answer "no" is invisible.
    //! An invariant that never fires and an invariant that cannot fire look
    //! identical from every direction except this one -- and the cost of the
    //! difference is that the next time the registries drift apart, nothing
    //! says so and the reading is "the invariant is there, so it must be
    //! fine". A panic hook nobody had heard speak cost exactly that today.
    //!
    //! **So this makes the registries genuinely disagree** -- one is written
    //! and the other is not -- and then reads the log file back off disk.
    //! Not a switch that makes the line print: that would prove the line can
    //! be printed, which nobody doubted. **The point is to prove the check
    //! can see.**
    //!
    //! What it still does not cover, said out loud: the call site. That
    //! `WM_DESTROY` reaches `empty_agrees` at the one moment both registries
    //! are finished with a window is a claim about `main.rs`, and only a real
    //! machine can answer it.

    use super::*;

    fn h(n: isize) -> HWND {
        HWND(n as *mut std::ffi::c_void)
    }

    /// A clean pair of registries, and the guard that keeps them clean.
    ///
    /// **Two turns, because two process-wide things are being written**:
    /// `tabs::test_arena` for `STATE`, and `registry_tests`' lock for
    /// `FRAMES`. Its siblings `registry_tests` and `numbering_tests` need
    /// only the second -- **measured, not assumed**: their `count` and
    /// `destroyed` are `winid`'s own and never reach `tabs`. Giving them the
    /// arena as well would be surplus, and **surplus serialisation is green,
    /// so nobody would ever find out it was unnecessary.**
    ///
    /// **`registry_tests::reset` only clears `winid`.** These tests write
    /// `tabs` as well, and they clean up after themselves -- but a test that
    /// fails part-way does not reach its cleanup, and the residue would make
    /// the *next* test fail for a reason that has nothing to do with what it
    /// is checking. **A harness-caused failure attributed to the code under
    /// test costs somebody an afternoon changing something that was not
    /// broken**, so the clearing happens on the way in as well as on the way
    /// out.
    fn clean(handles: &[HWND]) -> Turn {
        // **The arena first, always.** It is the outer, process-wide turn;
        // `reset()` takes `winid`'s own registry lock inside it. Taking them
        // the other way round in some future test would be a cycle, and the
        // rule is written in `tabs::test_arena` as well as here because the
        // only thing keeping it true today is that this is the one place
        // both are taken.
        let arena = crate::tabs::test_arena::exclusive();
        let winid = super::registry_tests::reset();
        // Reaches `STATE`, so it has to be inside the arena turn.
        for h in handles {
            crate::tabs::remove_window(*h);
        }
        Turn { _winid: winid, _arena: arena }
    }

    /// Both turns, released in the order they were taken.
    ///
    /// Struct fields drop in declaration order, so `_winid` goes first and
    /// the arena last -- the mirror of `clean`'s acquisition. Writing them
    /// the other way round would release the outer turn while still holding
    /// the inner one, which is the shape a lock-order bug is usually found in.
    struct Turn {
        _winid: std::sync::MutexGuard<'static, ()>,
        _arena: crate::tabs::test_arena::Turn,
    }

    /// **The floor for the wiring itself, and it is deterministic.**
    ///
    /// These tests reach `STATE` -- `add_window`, `remove_window`,
    /// `with_windows`, and `empty_agrees` behind them -- while
    /// `tabs::deadlock_detector_tests`' D2 holds it for 5.8 seconds. Before
    /// task 189 the two modules took turns in two different arenas, so they
    /// could run at once, and this module's tests panicked with a `DEADLOCK`
    /// naming D2's holding thread. **That failure was intermittent and it
    /// arrived wearing this module's name**, which is the expensive part: the
    /// evidence points at the subject rather than at the instrument.
    ///
    /// This asserts the wiring instead of waiting for the collision, so it is
    /// red on an unwired tree on every run rather than on some of them.
    ///
    /// ⚠️ **`this_thread_has_the_turn`, not "somebody holds the arena".** The
    /// obvious spelling -- `try_lock().is_err()` -- **passes on an unwired
    /// tree** whenever D2 is holding the arena on another thread at that
    /// moment, which is precisely when this module is in danger. A floor that
    /// can pass without its subject being wired up is not a floor.
    #[test]
    fn these_tests_wait_for_the_same_turn_as_the_state_lock_tests() {
        let _turn = clean(&[]);
        assert!(
            crate::tabs::test_arena::this_thread_has_the_turn(),
            "`clean` did not take `tabs::test_arena`'s turn. These tests reach \
             `STATE`, so without it they can run while D2 holds the lock for \
             5.8 seconds, wait out the five-second deadline, and panic with a \
             `DEADLOCK` that names D2's thread and this module's test."
        );
    }

    /// Run `body` with the log redirected, and hand back what was written.
    ///
    /// **`crate::test_log`'s redirect, not a copy of it.** This module and
    /// `tabs::deadlock_detector_tests` each had one, and both set the same
    /// process-wide `POLTER_HOST_LOG`; in parallel they overwrote each
    /// other, and a test here once failed on a line it had never written.
    /// Task 187.
    fn logged(body: impl FnOnce()) -> String {
        crate::test_log::logged("invariant-floor", body)
    }

    const MARKER: &str = "REGISTRIES DISAGREE";

    /// `winid` has a window, `tabs` does not. **This is the direction the
    /// real defect had**: the count that decides whether to quit said one
    /// while the other registry had already reached zero.
    #[test]
    fn it_speaks_when_winid_has_one_and_tabs_has_none() {
        let w = h(0x5001);
        let _g = clean(&[w]);
        let out = logged(|| {
            // The disagreement is made by writing one registry and not the
            // other -- not by handing the check two numbers.
            assign(w);
            assert_eq!(count(), 1);
            assert_eq!(crate::tabs::with_windows(|ws| ws.len()), 0);
            empty_agrees(w);
        });
        let _ = destroyed(w);
        assert!(
            out.contains(MARKER),
            "the invariant said nothing about 1 vs 0. Log was:\n{out}"
        );
        assert!(out.contains("winid has 1"), "the line must carry both numbers:\n{out}");
        assert!(out.contains("tabs has 0"), "the line must carry both numbers:\n{out}");
    }

    /// The other direction, because a check that only looks one way is half a
    /// check and the halves fail separately.
    #[test]
    fn it_speaks_when_tabs_has_one_and_winid_has_none() {
        let w = h(0x5002);
        let _g = clean(&[w]);
        let out = logged(|| {
            crate::tabs::add_window(w);
            assert_eq!(count(), 0);
            assert_eq!(crate::tabs::with_windows(|ws| ws.len()), 1);
            empty_agrees(w);
        });
        crate::tabs::remove_window(w);
        assert!(
            out.contains(MARKER),
            "the invariant said nothing about 0 vs 1. Log was:\n{out}"
        );
    }

    /// **The half that keeps it switched on.**
    ///
    /// An invariant that fires on the normal path gets removed, and the
    /// person who removes it does not put anything back. Both registries
    /// holding the same window, and both holding nothing, are the normal
    /// path -- and so is one holding two while the other holds one, which is
    /// what every window's creation and destruction passes through.
    #[test]
    fn it_stays_quiet_when_there_is_nothing_to_say() {
        let (a, b) = (h(0x5003), h(0x5004));
        let _g = clean(&[a, b]);

        // Both empty.
        let out = logged(|| empty_agrees(a));
        assert!(!out.contains(MARKER), "0 vs 0 is agreement:\n{out}");

        // Both holding the same one.
        let out = logged(|| {
            assign(a);
            crate::tabs::add_window(a);
            empty_agrees(a);
        });
        assert!(!out.contains(MARKER), "1 vs 1 is agreement:\n{out}");

        // Two against one: the transient every window passes through.
        let out = logged(|| {
            assign(b);
            empty_agrees(b);
        });
        assert!(
            !out.contains(MARKER),
            "2 vs 1 is a legitimate transient and must not fire:\n{out}"
        );

        let _ = destroyed(a);
        let _ = destroyed(b);
        crate::tabs::remove_window(a);
    }

    /// **The floor for this module's own instrument.**
    ///
    /// Every assertion above is of the form "the log did (not) contain a
    /// string". If `logged` returned an empty string always -- a wrong path,
    /// a redirect that did not take, a file that could not be read -- the
    /// three "stays quiet" assertions would pass while proving nothing, and
    /// the two "speaks" ones would fail in a way that reads like a broken
    /// invariant rather than a broken harness.
    #[test]
    fn the_harness_captures_a_line_it_is_given() {
        let _g = clean(&[]);
        // process-wide: this is a probe for the redirect itself, not a report
        // about a window -- it is written before any window exists and its
        // whole content is "the log path took".
        //
        // **`plogf!` rather than an untagged `logf!`, and the difference is
        // not cosmetic.** An untagged line passes `window-tagged-logs.py` by
        // being invisible to it; this one passes by answering its question.
        // That checker's rule is that every line is about a window until
        // somebody writes down why it is not, **at the line** -- and a probe
        // that dodges the rule instead of answering it stops passing the day
        // the checker starts examining untagged lines, for a reason nobody
        // will connect to this test.
        let out = logged(|| crate::plogf!("[floor] the redirect works"));
        assert!(
            out.contains("[floor] the redirect works"),
            "POLTER_HOST_LOG redirect did not take; every other test in this \
             module is unreadable until it does. Log was:\n{out}"
        );
    }
}
