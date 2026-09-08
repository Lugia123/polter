//! Four non-interactive signs over the terminal: the grid size while you
//! resize it, a badge when the surface is read-only, the URL under the
//! pointer, and where you are in the scrollback.
//!
//! **Why they share one file and one window class.** All four are the same
//! shape — a small always-on-top window that never takes focus, driven
//! entirely by something the host already knows. None has an input field, so
//! none touches `overlay.rs`'s focus contract. Splitting them would duplicate
//! the window, the font, and the paint path five ways (`keyseq.rs` is the
//! fifth).
//!
//! **Where each gets its truth:**
//!
//! - **Grid size** — the host's own. Columns and rows are the active surface's
//!   client rectangle divided by the cell size the core published through
//!   `cell_size`, read back with `ime_cell_size()`. Nothing is guessed and
//!   nothing is stored: if the numbers on screen are wrong, either the client
//!   rect or the cell size is wrong, and both are checkable.
//! - **Read-only** — the core's, through `GHOSTTY_ACTION_READONLY`. The host
//!   never decides this and never remembers it across a config reload; it
//!   paints the last thing the core said.
//! - **The hovered URL** — the core's, through `mouse_over_link`. The core
//!   sends the text when the pointer goes over a link and a zero length when
//!   it leaves; the host paints the last thing it was told and nothing else.
//!   **It does not detect links**, and must not start to: the core owns what
//!   counts as one, and a second opinion would differ on exactly the URLs
//!   that are hard.
//! - **The scrollbar** — the core's, through `scrollbar`, as three row counts:
//!   how many rows exist, which one is at the top, and how many are visible.
//!
//! ⚠️ **The scrollbar cannot be dragged, and that is a limit, not an
//! oversight.** A real one would have to turn a pixel back into a scrollback
//! row and ask the core to go there, and libghostty publishes no "scroll to
//! row" entry point on this platform — `ghostty_surface_mouse_scroll` moves by
//! a delta from wherever the view happens to be. So this is an indicator: it
//! says where you are, and the wheel is still how you move. It is drawn in a
//! window of its own **over** the pane rather than by giving the pane
//! `WS_VSCROLL`, because a surface window must be created at its final size
//! (`windows/AGENTS.md`) and a scroll bar would take pixels out of a client
//! area libghostty has already been told the size of.
//!
//! **Why the size sign hides on a timer rather than on `WM_EXITSIZEMOVE`.**
//! `WM_EXITSIZEMOVE` only arrives for a drag of the window frame. A resize
//! from `SetWindowPos` (the tab strip's layout, a maximise, the self-test)
//! never sends it, so a sign that waited for it would stay on screen forever
//! after a programmatic resize. **One timer covers every way a resize can
//! happen; the message covers one of them.**

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{hlogf, plogf};

const WM_HUD_SYNC: u32 = WM_APP + 7;
/// Timer id for "the resize is over".
const TIMER_SIZE_OFF: usize = 1;
/// How long the grid size stays after the last resize message.
const SIZE_LINGER_MS: u32 = 900;

const HEIGHT: i32 = 30;
const COL_BG: u32 = 0x00403f3d;
const COL_TEXT: u32 = 0x00ffffff;
const COL_RO_BG: u32 = 0x00306090; // BGR: amber, for the read-only badge
/// BGR: a deep red, for the secure-input badge. **Deliberately not
/// `COL_RO_BG`**: the two badges can be up at once on the same pane, and two
/// identically coloured rectangles a badge-height apart is how a person reads
/// one state and acts on the other.
const COL_SEC_BG: u32 = 0x00202090;
/// The link bar's background. Darker than the size sign so a URL sitting over
/// terminal text still reads as a separate thing.
const COL_LINK_BG: u32 = 0x00302f2d;
/// The scrollbar's track and thumb. The track is nearly the terminal's own
/// grey on purpose -- a bar you can see at rest is a bar in the way.
const COL_TRACK: u32 = 0x00303030;
const COL_THUMB: u32 = 0x00808080;
/// Width of the scrollbar, unscaled, and the shortest thumb worth drawing.
/// **A thumb below this is not a small thumb, it is an invisible one**, and a
/// scrollbar whose thumb vanishes in a large scrollback reads as "there is
/// nothing to scroll".
const SCROLL_W: i32 = 10;
const THUMB_MIN: i32 = 18;

static HWND_SIZE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_RO: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_SEC: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_LINK: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_SCROLL: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Which surfaces are read-only, by surface pointer.
///
/// **This was one process-wide `AtomicBool`, and that is the defect this list
/// exists to fix.** Read-only is a property of a *surface*: with a split, one
/// pane can be read-only while the other is not. A single bool made the two
/// panes share one answer, and the two visible consequences pointed in
/// opposite directions -- the right pane's menu ticked «Read-only» because
/// the *left* pane was, and toggling it printed `on` because the right pane's
/// own state, the one the core keeps, said otherwise. **A tick and a badge
/// drawn from a state that is not the one the core is toggling will disagree
/// with it eventually, and there is nothing in either of them that can say
/// so.**
///
/// A `Vec` rather than a map: a window has a handful of panes, and the whole
/// list is walked on every sync anyway to drop surfaces that no longer exist.
static READONLY: std::sync::Mutex<Vec<(usize, bool)>> = std::sync::Mutex::new(Vec::new());

/// Which surfaces the core says are at a password prompt.
///
/// **A separate table from `READONLY` rather than a second field on it.** The
/// two states are set by different actions, at different times, and a pane can
/// be either, both or neither; one table of `(surface, ro, secure)` would make
/// every write to one of them a read-modify-write of the other, which is how
/// the reading that arrives second silently loses the one that arrived first.
static SECURE: std::sync::Mutex<Vec<(usize, bool)>> = std::sync::Mutex::new(Vec::new());

/// **The turn every test that writes `READONLY` waits for.**
///
/// Next to the thing it guards, not inside the test module that needs it:
/// **the boundary of "one at a time" follows the object.** `tabs`'
/// `test_arena` is the same rule over the state mutex, and
/// `crate::test_log` over the log destination.
///
/// # What it is for
///
/// Three tests here each `clear()` -> write -> assert -> `clear()` on this
/// one process-wide `Vec`, and there was no serialisation in this file at
/// all. Twenty-two parallel runs went red three times, and **all three tests
/// failed at one time or another**. The give-away is that one assertion
/// produced two opposite readings: `left: 2` when a neighbour's
/// `on_readonly_for` landed between this test's write and its assertion, and
/// `left: 0` when a neighbour's `clear()` did. **Not two defects -- two sides
/// of one.**
///
/// # What is deliberately *not* in the turn, and on what evidence
///
/// **Not `tabs::test_arena`.** These tests reach no function that takes
/// `STATE` -- measured, and it is what separated this from task 189 in the
/// first place. Putting them in that arena would be surplus serialisation,
/// **and surplus serialisation is green, so nobody would ever find out it
/// was unnecessary.**
///
/// **Not `RO_SHOWN_FOR`.** Neither `on_readonly_for` nor `is_readonly_for`
/// touches it; it lives only in the paint and sync paths, which no test here
/// enters.
///
/// **Not `ctxmenu::tests`, and this one needs its reason spelled out because
/// the fact alone is misleading.** A reachability scan says those tests do
/// reach `READONLY`: they call `tick_state`, and `tick_state` has an arm
/// `Tick::Readonly => is_readonly_for(..)`. The names are right and the call
/// is real. **The arm is never selected** -- every call there passes
/// `PgSupervisor`, `PgWatched` or `PgShielded`, and the one loop over ticks
/// lists those three literally.
///
/// > **Reachability stops at function granularity; the only path to this
/// > object is one `match` arm the caller never chooses.**
///
/// **So the reason it is out is conditional, not structural.** Add
/// `Tick::Readonly` to that loop and those tests join this race that day --
/// **and they will be green while they do it.** If that changes, they need
/// this turn.
#[cfg(test)]
mod readonly_arena {
    use std::cell::Cell;
    use std::sync::Mutex;

    static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

    thread_local! {
        /// Per-thread, for `tabs::test_arena`'s reason: "somebody holds it"
        /// answers `true` on an unwired tree whenever another thread happens
        /// to hold it.
        static HAS_THE_TURN: Cell<bool> = const { Cell::new(false) };
    }

    /// A turn. **Bind it** -- `let _turn = exclusive();`. Writing
    /// `let _ = exclusive();` drops it on the spot and the test then runs
    /// unprotected, which on its own looks like nothing at all; what makes
    /// that mutation visible is the flag below, cleared by this `Drop`, and
    /// the check in `tests::clear`.
    pub(super) struct Turn {
        _inner: std::sync::MutexGuard<'static, ()>,
    }

    impl Drop for Turn {
        fn drop(&mut self) {
            HAS_THE_TURN.with(|c| c.set(false));
        }
    }

    /// **Poison is recovered from, not propagated.** These tests assert on a
    /// lock they hold; one real failure would otherwise dress every test
    /// after it in a second one, each red on the lock instead of on its own
    /// subject.
    #[must_use]
    pub(super) fn exclusive() -> Turn {
        let inner = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
        HAS_THE_TURN.with(|c| c.set(true));
        Turn { _inner: inner }
    }

    pub(super) fn this_thread_has_the_turn() -> bool {
        HAS_THE_TURN.with(|c| c.get())
    }
}

/// The URL under the pointer, and which surface it is over.
///
/// **One entry, not a list per surface.** There is one pointer, so there is
/// one hovered link; the surface is stored with it so the bar can be placed
/// over the right pane and hidden when that pane's core says the pointer left.
static HOVER: std::sync::Mutex<Option<(usize, String)>> = std::sync::Mutex::new(None);

/// What each surface last said about its scrollback, as
/// `(surface, total, offset, len)` in rows.
///
/// **Per surface and keyed by the surface pointer**, for the reason written
/// on `READONLY`: with a split, each pane scrolls on its own, and one shared
/// answer would draw the focused pane's position over the other one.
static SCROLL: std::sync::Mutex<Vec<(usize, u64, u64, u64)>> = std::sync::Mutex::new(Vec::new());

/// The surface the badge is currently showing for, or 0.
static RO_SHOWN_FOR: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static SEC_SHOWN_FOR: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// The window a surface is in, as a handle a log line can be tagged with.
///
/// Null when no window owns it, which `hlogf!` reports as "not a terminal
/// window" rather than inventing one. **A surface pointer in the text is not
/// a substitute**: it names a terminal, and the question a reader of a
/// two-window log is asking is which *window* the line came from.
fn frame_hwnd_of(surface: usize) -> HWND {
    crate::tabs::frame_of_surface(surface as crate::ffi::Surface).unwrap_or_default()
}

struct State {
    font: HFONT,
    /// Last measured grid, painted by the size sign.
    cols: i32,
    rows: i32,
    size_visible: bool,
    /// The frame the size sign was last put over, so the line that hides it
    /// half a second later can name the same window the line that showed it
    /// did. Read from here rather than asked again: by then the focus may
    /// have moved, and `overlay_frame` would answer about the wrong window --
    /// and a wrong window is worse than none.
    size_frame: isize,
    ro_visible: bool,
    sec_visible: bool,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

// ------------------------------------------------------- from `action_cb`

/// Is **this** surface read-only?
///
/// The badge and every menu tick have to come from here, with the surface the
/// menu is about: the one the pointer opened it on, not the focused one. Two
/// copies of this state drift the first time the core toggles it from
/// somewhere else, and the symptom is a menu that lies about a mode the badge
/// is simultaneously reporting correctly.
pub fn is_readonly_for(surface: usize) -> bool {
    if surface == 0 {
        return false;
    }
    READONLY
        .lock()
        .map(|v| v.iter().any(|(s, on)| *s == surface && *on))
        .unwrap_or(false)
}

/// `GHOSTTY_ACTION_READONLY` for one surface. **Safe from any thread.**
pub fn on_readonly_for(surface: usize, on: bool) {
    if surface == 0 {
        // process-wide: the action named surface 0, so there is no terminal
        // and therefore no window this line could belong to
        plogf!("[hud] readonly {} for surface 0 -- ignored, that names no terminal", on);
        return;
    }
    if let Ok(mut v) = READONLY.lock() {
        match v.iter_mut().find(|(s, _)| *s == surface) {
            Some(e) => e.1 = on,
            None => v.push((surface, on)),
        }
    }
    // **The whole stack, not just this badge.** See `sync_corner`.
    sync_corner(surface);
}

/// A badge that shares the pane's top-left corner with another.
///
/// # The rule, and why it is written as a set rather than as an event
///
/// > **Badges over the pane's top-left corner stack downward in one fixed
/// > order, and each one's slot is its position among those *currently lit*,
/// > recomputed from the live state whenever any of them changes.**
///
/// What stood here before was the same idea expressed as an event: the
/// PASSWORD badge asked `is_readonly_for` **at the moment it turned on** and
/// offset itself if the answer was yes. That is right exactly when it was the
/// last of the two to change. Measured on the machine, the same two states in
/// the two possible orders:
///
///   * read-only first, then secure -> secure at `196,162`, stacked. Correct.
///   * secure first, then read-only -> **both at `196,126`**. The badge that
///     was already up was never told the world had changed under it, so two
///     badges drew on one point -- which is one badge as far as the person can
///     tell, and they act on whichever lost the z-order.
///
/// **Stated as a set, the order cannot matter**, because no part of the answer
/// remembers when anything happened. That is also what makes a third badge on
/// this corner one line here rather than a third order to get wrong.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Corner {
    ReadOnly,
    Secure,
}

/// The corner's occupants, **in stacking order**.
const CORNER_ORDER: [Corner; 2] = [Corner::ReadOnly, Corner::Secure];

fn corner_lit(surface: usize, which: Corner) -> bool {
    match which {
        Corner::ReadOnly => is_readonly_for(surface),
        Corner::Secure => is_secure_for(surface),
    }
}

/// Which row `which` occupies, counting only the badges that are lit.
///
/// Pure over the live state: same states, same answer, whatever happened
/// first.
pub fn corner_slot(surface: usize, which: Corner) -> i32 {
    CORNER_ORDER
        .iter()
        .take_while(|c| **c != which)
        .filter(|c| corner_lit(surface, **c))
        .count() as i32
}

/// Wake **every** badge over the corner, not just the one whose state moved.
///
/// The other half of the rule, and the half that was missing: a slot computed
/// from live state is still stale on screen if nobody asks the badge to
/// recompute it. `on_readonly_for` posted to `HWND_RO` and stopped, so the
/// PASSWORD badge -- already up, and now in the wrong row -- was never told.
fn sync_corner(surface: usize) {
    for slot in [&HWND_RO, &HWND_SEC] {
        let h = slot.load(Ordering::Acquire);
        if !h.is_null() {
            let _ =
                unsafe { PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(surface), LPARAM(0)) };
        }
    }
}

/// Is **this** surface at a password prompt?
///
/// Read by the badge and by `mouse.rs`, both with the surface they are about.
/// The same rule `is_readonly_for` states: two copies of this drift the first
/// time the core changes it from somewhere else, and the symptom is one
/// indicator reporting a mode the other is simultaneously denying.
pub fn is_secure_for(surface: usize) -> bool {
    if surface == 0 {
        return false;
    }
    SECURE
        .lock()
        .map(|v| v.iter().any(|(s, on)| *s == surface && *on))
        .unwrap_or(false)
}

/// `GHOSTTY_ACTION_SECURE_INPUT` for one surface. **Safe from any thread.**
///
/// Answers what the surface's state is *afterwards*, which is what `toggle`
/// needs and what the caller logs -- `cb_action` cannot work it out from the
/// mode alone.
///
/// # Why this arrives without anybody pressing anything
///
/// The core raises `secure_input` from `Surface.zig`'s `setPasswordInput`
/// whenever the terminal enters or leaves a password prompt, so this runs
/// during ordinary use and not only from the `toggle_secure_input` binding.
/// That is the whole reason this was worth building before the other actions
/// on the same list: an unanswered `secure_input` is not a menu row nobody
/// clicks, it is a thing that happens to everybody who types `sudo`.
///
/// # What this does **not** do, and it is the important half
///
/// macOS answers this action by calling `EnableSecureEventInput`, a system
/// API that stops *any* application reading keyboard events. **This host makes
/// no equivalent call**, so what is here is an indication and not a
/// protection: it tells the person the terminal believes they are typing a
/// password. It does not stop anything reading it.
///
/// The Windows API that comes closest is `SetWindowDisplayAffinity` with
/// `WDA_EXCLUDEFROMCAPTURE`, and it is deliberately not here -- it is task
/// 296, on its own, because it excludes the window from *all* screen capture
/// and this machine's supervision reads terminals by capturing the screen.
/// The core's own configuration documentation names the same shape as the
/// reason to have an off switch on macOS: `macos-auto-secure-input`'s comment
/// says a reason to disable it is that "it is interfering with legitimate
/// accessibility software ... since secure input prevents any application from
/// reading keyboard events". **Whether that description fits our own
/// supervisor is the question 296 exists to answer, and it is not one to
/// settle as a side effect of wiring an action.**
/// Is **any** surface in this window at a password prompt?
///
/// **The question `capture.rs` has to ask before it restores anything.**
/// Secure input is per surface and display affinity is per window, so with a
/// split the last one out is the one that may lift the protection -- and a
/// per-surface answer would lift it while another pane still needed it, with
/// nothing on screen to say so.
pub fn any_secure_in_frame(frame: HWND) -> bool {
    let Ok(v) = SECURE.lock() else { return false };
    v.iter().any(|(s, on)| {
        *on && crate::tabs::frame_of_surface(*s as crate::ffi::Surface) == Some(frame)
    })
}

pub fn on_secure_input(surface: usize, mode: i32) -> bool {
    if surface == 0 {
        // process-wide: the action named surface 0, so there is no terminal
        // and therefore no window this line could belong to
        plogf!("[hud] secure_input mode {} for surface 0 -- ignored, that names no terminal", mode);
        return false;
    }
    let on = match SECURE.lock() {
        Ok(mut v) => {
            let want = match mode {
                crate::ffi::SECURE_INPUT_ON => true,
                crate::ffi::SECURE_INPUT_OFF => false,
                crate::ffi::SECURE_INPUT_TOGGLE => !v
                    .iter()
                    .any(|(s, cur)| *s == surface && *cur),
                // **Not folded into `on`.** A mode this host does not know is
                // a core that has grown a fourth one, and guessing would set a
                // security-flavoured state from a value nobody read.
                other => {
                    // process-wide: a fact about what the core sent, not about
                    // any one window
                    plogf!("[hud] secure_input: unknown mode {}; state unchanged", other);
                    return false;
                }
            };
            match v.iter_mut().find(|(s, _)| *s == surface) {
                Some(e) => e.1 = want,
                None => v.push((surface, want)),
            }
            want
        }
        Err(_) => {
            // process-wide: one table, one mutex; a poisoned lock is a fact
            // about the process
            plogf!("[hud] secure_input: the table is poisoned; state unchanged");
            return false;
        }
    };
    // **The whole stack, not just this badge.** See `sync_corner`.
    sync_corner(surface);
    on
}

/// `mouse_over_link` for one surface. **Safe from any thread.**
///
/// `url` is `None` when the pointer has left the link -- the core sends a
/// zero length for that, and `ffi::Action::as_mouse_over_link` turns it into
/// `None` so the two spellings of "no link" cannot be handled differently
/// here by accident.
pub fn on_hover_link(surface: usize, url: Option<String>) -> bool {
    if surface == 0 {
        // process-wide: the action named surface 0, so there is no terminal
        // and therefore no window this line could belong to
        plogf!("[hud] mouse_over_link for surface 0 -- ignored, that names no terminal");
        return false;
    }
    match HOVER.lock() {
        Ok(mut h) => {
            *h = url.map(|u| (surface, u));
        }
        Err(_) => return false,
    }
    let w = HWND_LINK.load(Ordering::Acquire);
    if w.is_null() {
        return false;
    }
    unsafe { PostMessageW(Some(HWND(w)), WM_HUD_SYNC, WPARAM(surface), LPARAM(0)) }.is_ok()
}

/// `scrollbar` for one surface. **Safe from any thread.**
///
/// The three numbers are rows: how many the scrollback holds, which row is at
/// the top of the view, and how many rows the view shows.
pub fn on_scrollbar(surface: usize, total: u64, offset: u64, len: u64) -> bool {
    if surface == 0 {
        // process-wide: the action named surface 0, so there is no terminal
        // and therefore no window this line could belong to
        plogf!("[hud] scrollbar for surface 0 -- ignored, that names no terminal");
        return false;
    }
    match SCROLL.lock() {
        Ok(mut v) => match v.iter_mut().find(|(s, ..)| *s == surface) {
            Some(e) => *e = (surface, total, offset, len),
            None => v.push((surface, total, offset, len)),
        },
        Err(_) => return false,
    }
    let w = HWND_SCROLL.load(Ordering::Acquire);
    if w.is_null() {
        return false;
    }
    unsafe { PostMessageW(Some(HWND(w)), WM_HUD_SYNC, WPARAM(surface), LPARAM(0)) }.is_ok()
}

/// The pane window that hosts a surface, and its rectangle on screen.
///
/// **Read out of the tab model rather than kept here.** A second table of
/// which pane owns which surface is a second thing to keep in step with the
/// splits, and it would be wrong exactly while a split is being made.
fn pane_rect_for(surface: usize) -> Option<RECT> {
    let hwnd = {
        // Every window: the key is a surface, which is unique in the process,
        // so this is a search rather than a choice of window.
        crate::tabs::with_windows(|ws| {
            ws.iter()
                .flat_map(|w| w.tabs.iter())
                .flat_map(|t| t.panes.iter())
                .find(|p| p.surface == surface)
                .map(|p| HWND(p.hwnd as *mut c_void))
        })?
    };
    let mut r = RECT::default();
    if unsafe { GetWindowRect(hwnd, &mut r) }.is_err() {
        return None;
    }
    Some(r)
}

/// Drop surfaces that no longer exist, and say how many are read-only.
///
/// Called on every sync: a pane that closed while read-only would otherwise
/// leave its `true` behind, and surface pointers get reused.
fn prune_and_count() -> usize {
    let live: Vec<usize> = {
        // Every window: a surface that closed in window 2 has to leave this
        // list too, or its stale `read-only` sticks to a reused pointer.
        crate::tabs::with_windows(|ws| {
            ws.iter()
                .flat_map(|w| w.tabs.iter())
                .flat_map(|t| t.panes.iter())
                .map(|p| p.surface)
                .collect()
        })
    };
    let Ok(mut v) = READONLY.lock() else { return 0 };
    let before = v.len();
    v.retain(|(s, _)| live.contains(s));
    if v.len() != before {
        // process-wide: one read-only list for every window; this line is
        // about pruning the list, and the surfaces it drops came from windows
        // that no longer exist
        plogf!("[hud] forgot {} closed surface(s) from the read-only list", before - v.len());
    }
    v.iter().filter(|(_, on)| *on).count()
}

/// The frame was resized. **Main thread only** -- it is called from the frame's
/// own window procedure.
pub fn on_frame_resized() {
    let h = HWND_SIZE.load(Ordering::Acquire);
    if !h.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
    }
    // **The badge has to move too, now that it sits over a pane.** While it
    // was pinned to the window's corner a resize left it roughly right; over a
    // pane, a resize moves the pane out from under it and the badge ends up
    // marking whatever is now beneath it. `WPARAM(0)` means "re-evaluate the
    // surface you are already showing".
    let ro = HWND_RO.load(Ordering::Acquire);
    if !ro.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(ro)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
    }
    // **The same reason again, for the two signs that also sit over a pane.**
    // The link bar is pinned to a pane's bottom-left and the scrollbar to its
    // right edge; a resize moves the pane out from under both, and a sign left
    // where it was marks whatever is now beneath it. Both take `WPARAM(0)`,
    // which each of their syncs reads as "the surface you are already
    // showing".
    let link = HWND_LINK.load(Ordering::Acquire);
    if !link.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(link)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
    }
    let scroll = HWND_SCROLL.load(Ordering::Acquire);
    if !scroll.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(scroll)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
    }
}

/// Columns and rows of the active surface, or `None` if either input is not
/// available yet. **Returns `None` rather than a plausible-looking zero**: a
/// sign that says `0x0` looks like a measurement, and this one would be the
/// absence of one.
fn grid() -> Option<(i32, i32, i32, i32, i32, i32)> {
    // **The first window's active pane.** The HUD is one overlay for the
    // process and has no frame of its own to ask about; which window it
    // should be measuring is a question for whoever gives the HUD a window,
    // and it is left visibly unanswered rather than quietly answered.
    let hwnd = crate::tabs::active_hwnd(crate::tabs::overlay_frame());
    if hwnd.0.is_null() {
        return None;
    }
    let mut rc = RECT::default();
    if unsafe { GetClientRect(hwnd, &mut rc) }.is_err() {
        return None;
    }
    let (cw, ch) = crate::ime_cell_size();
    // `ime_cell_size` clamps to 1 to stay divisible; that is exactly the value
    // that means "the core has not sent cell_size yet".
    if cw <= 1 || ch <= 1 {
        return None;
    }
    let (w, h) = (rc.right - rc.left, rc.bottom - rc.top);
    if w <= 0 || h <= 0 {
        return None;
    }
    Some((w / cw, h / ch, w, h, cw, ch))
}

// ------------------------------------------------------------------ setup

fn make_window(hinst: windows::Win32::Foundation::HINSTANCE, class: windows::core::PCWSTR) -> HWND {
    unsafe {
        match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            class,
            w!("Polter"),
            WS_POPUP,
            0,
            0,
            160,
            HEIGHT,
            None,
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: creating one of the two badge windows; there is one pair per process
                plogf!("[hud] CreateWindowExW failed: {e:?}");
                HWND(std::ptr::null_mut())
            }
        }
    }
}

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        for (proc_fn, class) in [
            (size_proc as WndprocFn, w!("PolterHudSize")),
            (ro_proc as WndprocFn, w!("PolterHudReadonly")),
            (sec_proc as WndprocFn, w!("PolterHudSecure")),
            (link_proc as WndprocFn, w!("PolterHudLink")),
            (scroll_proc as WndprocFn, w!("PolterHudScroll")),
        ] {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                style: CS_DROPSHADOW,
                lpfnWndProc: Some(proc_fn),
                hInstance: hinst,
                hbrBackground: HBRUSH(std::ptr::null_mut()),
                lpszClassName: class,
                ..Default::default()
            };
            if RegisterClassExW(&wc) == 0 {
                // process-wide: registering the badge window class, once per process
                plogf!("[hud] RegisterClassExW failed");
                return;
            }
        }

        let hsize = make_window(hinst, w!("PolterHudSize"));
        let hro = make_window(hinst, w!("PolterHudReadonly"));
        let hsec = make_window(hinst, w!("PolterHudSecure"));
        let hlink = make_window(hinst, w!("PolterHudLink"));
        let hscroll = make_window(hinst, w!("PolterHudScroll"));
        if hsize.0.is_null()
            || hro.0.is_null()
            || hsec.0.is_null()
            || hlink.0.is_null()
            || hscroll.0.is_null()
        {
            return;
        }

        let dpi = GetDpiForWindow(hsize).max(96) as i32;
        let font = CreateFontW(
            -(14 * dpi / 96),
            0,
            0,
            0,
            FW_SEMIBOLD.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            w!("Segoe UI"),
        );
        STATE.with(|c| {
            *c.borrow_mut() = Some(State {
                font,
                cols: 0,
                rows: 0,
                size_visible: false,
                size_frame: 0,
                ro_visible: false,
                sec_visible: false,
            });
        });
        HWND_SIZE.store(hsize.0, Ordering::Release);
        HWND_RO.store(hro.0, Ordering::Release);
        HWND_SEC.store(hsec.0, Ordering::Release);
        HWND_LINK.store(hlink.0, Ordering::Release);
        HWND_SCROLL.store(hscroll.0, Ordering::Release);
        // process-wide: the badge windows exist; neither belongs to a terminal window yet
        plogf!("[hud] ready");
    }
}

type WndprocFn = unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT;

// ------------------------------------------------------------- size sign

fn show_size(me: HWND) {
    let Some((cols, rows, px_w, px_h, cell_w, cell_h)) = grid() else {
        // No measurement, no sign. Logged because "the size overlay never
        // appeared" and "the core never sent cell_size" look identical on
        // screen and are different bugs.
        hlogf!(
            crate::tabs::overlay_frame(),
            "[hud] size: no measurement (cell_size or client rect missing)"
        );
        return;
    };

    // **Hoisted out of the placement block below.** The window the sign is
    // put over is the window its log lines are about, and the "hidden" line
    // that follows a second later has no other way to know which one it was.
    let frame = crate::tabs::overlay_frame();

    let changed = STATE.with(|c| {
        c.borrow_mut()
            .as_mut()
            .map(|st| {
                let ch = st.cols != cols || st.rows != rows || !st.size_visible;
                st.cols = cols;
                st.rows = rows;
                st.size_visible = true;
                st.size_frame = frame.0 as isize;
                ch
            })
            .unwrap_or(false)
    });

    unsafe {
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let dpi = GetDpiForWindow(me).max(96) as i32;
        let sc = |v: i32| v * dpi / 96;
        let (w, h) = (sc(120), sc(HEIGHT));
        // Centred on the frame, the way every terminal shows this.
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
        let _ = SetWindowPos(
            me,
            Some(HWND_TOPMOST),
            x,
            y,
            w,
            h,
            SWP_SHOWWINDOW | SWP_NOACTIVATE,
        );
        let _ = InvalidateRect(Some(me), None, true);
        // Restart the linger every time, so a continuous drag keeps it up.
        let _ = SetTimer(Some(me), TIMER_SIZE_OFF, SIZE_LINGER_MS, None);
    }
    if changed {
        // **Every number this claim depends on is on the same line.**
        // The obvious form was `[hud] size CxR` plus a comparison against
        // `tabs.rs`'s `[win] surface ... WM_SIZE` line -- but that one stops
        // after ten messages (`if n <= 10`), and a resize five seconds into a
        // run arrives long after the startup layouts have used the quota up.
        // A criterion whose evidence is rate-limited elsewhere is a criterion
        // that quietly stops being checkable, so the arithmetic is closed here
        // instead: client pixels, cell size, and the quotient, in one line
        // nobody else can throttle.
        hlogf!(
            frame,
            "[hud] size {}x{} from client {}x{} cell {}x{}",
            cols, rows, px_w, px_h, cell_w, cell_h
        );
    }
}

unsafe extern "system" fn size_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HUD_SYNC => {
                show_size(hwnd);
                LRESULT(0)
            }
            WM_TIMER if wp.0 == TIMER_SIZE_OFF => {
                let _ = KillTimer(Some(hwnd), TIMER_SIZE_OFF);
                let was = STATE.with(|c| {
                    c.borrow_mut()
                        .as_mut()
                        .map(|st| std::mem::replace(&mut st.size_visible, false))
                        .unwrap_or(false)
                });
                if was {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    let over = STATE
                        .with(|c| c.borrow().as_ref().map(|st| st.size_frame).unwrap_or(0));
                    hlogf!(HWND(over as *mut c_void), "[hud] size hidden");
                }
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let label = STATE.with(|c| {
                    c.borrow()
                        .as_ref()
                        .map(|st| format!("{} × {}", st.cols, st.rows))
                        .unwrap_or_default()
                });
                paint(hwnd, &label, COL_BG, COL_TEXT);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// --------------------------------------------------------- readonly badge

unsafe extern "system" fn ro_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HUD_SYNC => {
                let n_readonly = prune_and_count();
                // Which surface this sync is about: the one that just changed,
                // or -- for a sync with no surface, such as a resize -- the one
                // the badge is already showing for.
                let surface = if wp.0 != 0 {
                    wp.0
                } else {
                    RO_SHOWN_FOR.load(Ordering::Acquire)
                };
                let on = is_readonly_for(surface);
                let was = STATE.with(|c| {
                    c.borrow_mut()
                        .as_mut()
                        .map(|st| std::mem::replace(&mut st.ro_visible, on))
                        .unwrap_or(false)
                });
                if !on {
                    if was {
                        let _ = ShowWindow(hwnd, SW_HIDE);
                    }
                    RO_SHOWN_FOR.store(0, Ordering::Release);
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] readonly off for surface {:#x}",
                        surface
                    );
                    // One badge, and more than one pane can be read-only. Say
                    // so rather than leaving a read-only pane unmarked and
                    // unexplained.
                    if n_readonly > 0 {
                        // process-wide: the count is over every window's panes,
                        // which is the whole point of saying it
                        plogf!(
                            "[hud] {} other surface(s) still read-only and unbadged \
                             (one badge, many panes)",
                            n_readonly
                        );
                    }
                    return LRESULT(0);
                }
                // **Over the pane that owns the surface, not the window's
                // corner.** The old placement was `frame.left + 16, frame.top
                // + 56`, which is the left pane's corner whenever there is a
                // split -- so a read-only right pane put its badge on a pane
                // that was not read-only, and nothing about the badge said
                // which pane it meant.
                let Some(fr) = pane_rect_for(surface) else {
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] readonly on for surface {:#x}, but no pane owns it; \
                         badge hidden rather than drawn somewhere arbitrary",
                        surface
                    );
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    RO_SHOWN_FOR.store(0, Ordering::Release);
                    return LRESULT(0);
                };
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                let (w, h) = (sc(110), sc(HEIGHT));
                // Top-left of that pane, inset. The search bar (top-right) and
                // the key indicator (bottom-right) still do not use it.
                let x = fr.left + sc(16);
                let y = fr.top + sc(16)
                    + sc(corner_slot(surface, Corner::ReadOnly) * (HEIGHT + 6));
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOPMOST),
                    x,
                    y,
                    w,
                    h,
                    SWP_SHOWWINDOW | SWP_NOACTIVATE,
                );
                let _ = InvalidateRect(Some(hwnd), None, true);
                RO_SHOWN_FOR.store(surface, Ordering::Release);
                hlogf!(
                    frame_hwnd_of(surface),
                    "[hud] readonly on for surface {:#x}; badge at {},{} over pane {},{}..{},{}",
                    surface,
                    x,
                    y,
                    fr.left,
                    fr.top,
                    fr.right,
                    fr.bottom
                );
                if n_readonly > 1 {
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] {} surfaces are read-only; the badge shows {:#x} \
                         (one badge, many panes)",
                        n_readonly,
                        surface
                    );
                }
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(hwnd, "READ ONLY", COL_RO_BG, COL_TEXT);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// ---------------------------------------------------- secure-input badge

unsafe extern "system" fn sec_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HUD_SYNC => {
                let surface = if wp.0 != 0 {
                    wp.0
                } else {
                    SEC_SHOWN_FOR.load(Ordering::Acquire)
                };
                let on = is_secure_for(surface);
                let was = STATE.with(|c| {
                    c.borrow_mut()
                        .as_mut()
                        .map(|st| std::mem::replace(&mut st.sec_visible, on))
                        .unwrap_or(false)
                });
                if !on {
                    if was {
                        let _ = ShowWindow(hwnd, SW_HIDE);
                    }
                    SEC_SHOWN_FOR.store(0, Ordering::Release);
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] secure input off for surface {:#x}",
                        surface
                    );
                    return LRESULT(0);
                }
                let Some(fr) = pane_rect_for(surface) else {
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] secure input on for surface {:#x}, but no pane owns it; \
                         badge hidden rather than drawn somewhere arbitrary",
                        surface
                    );
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    SEC_SHOWN_FOR.store(0, Ordering::Release);
                    return LRESULT(0);
                };
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                let (w, h) = (sc(150), sc(HEIGHT));
                // **Under the read-only badge when both are up.** They share
                // the pane's top-left corner, and two badges drawn at the same
                // point is one badge as far as the person can tell -- they
                // would read whichever won the z-order and act on the other.
                // The offset is conditional rather than permanent so that the
                // common case, secure input alone, still lands where every
                // other badge in this file lands.
                let slot = corner_slot(surface, Corner::Secure);
                let x = fr.left + sc(16);
                let y = fr.top + sc(16) + sc(slot * (HEIGHT + 6));
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOPMOST),
                    x,
                    y,
                    w,
                    h,
                    SWP_SHOWWINDOW | SWP_NOACTIVATE,
                );
                let _ = InvalidateRect(Some(hwnd), None, true);
                SEC_SHOWN_FOR.store(surface, Ordering::Release);
                hlogf!(
                    frame_hwnd_of(surface),
                    "[hud] secure input on for surface {:#x}; badge at {},{} over pane \
                     {},{}..{},{} (corner slot {})",
                    surface,
                    x,
                    y,
                    fr.left,
                    fr.top,
                    fr.right,
                    fr.bottom,
                    slot
                );
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                // **"PASSWORD", not "SECURE INPUT".** The badge has to answer
                // the question a person actually has when it appears, which is
                // "why has this shown up", and the honest answer here is that
                // the terminal thinks they are typing a password -- not that
                // some system-level protection was engaged, because none was.
                // See `on_secure_input` for what this host does and does not
                // do.
                paint(hwnd, "PASSWORD", COL_SEC_BG, COL_TEXT);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// ---------------------------------------------------------------- link bar

/// Where the thumb goes, given the three row counts and the height available,
/// as `(top, height)` in pixels. `None` means there is nothing to scroll and
/// the bar should not be drawn at all.
///
/// **Split out of the window procedure so it can be asserted.** Every input
/// is a number and every output is a number; the version of this that lived
/// inline could only be checked by looking at a screen, and its two failures
/// -- a thumb that vanishes in a long scrollback, and one that stops short of
/// the bottom -- both read as "the scrollbar is a bit off" rather than as a
/// wrong answer.
fn thumb(total: u64, offset: u64, len: u64, height: i32, min: i32) -> Option<(i32, i32)> {
    if height <= 0 || len == 0 || total <= len {
        return None;
    }
    // How much of the buffer is on screen, as a fraction of the track.
    let h = ((len as f64 / total as f64) * height as f64).round() as i32;
    // **Clamped by the track as well as by the floor.** A two-pixel pane must
    // get a two-pixel thumb, not an eighteen-pixel one hanging off the end.
    let h = h.clamp(min.min(height), height);
    // **`total - len`, not `total`.** The last row the view can *start* at is
    // one screenful above the end; dividing by `total` leaves the thumb short
    // of the bottom by exactly that, which reads as "there is more below" when
    // you are already at the end of the scrollback.
    let span = total - len;
    let pos = (offset.min(span) as f64 / span as f64) * (height - h) as f64;
    Some((pos.round() as i32, h))
}

unsafe extern "system" fn link_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HUD_SYNC => {
                let shown = HOVER.lock().ok().and_then(|h| h.clone());
                let Some((surface, url)) = shown else {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    hlogf!(frame_hwnd_of(wp.0), "[hud] link bar hidden");
                    return LRESULT(0);
                };
                let Some(fr) = pane_rect_for(surface) else {
                    // The pane went away between the core sending this and us
                    // reading it. Hidden rather than left over whatever is
                    // under it now.
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] link bar: no pane owns surface {:#x}; hidden",
                        surface
                    );
                    return LRESULT(0);
                };
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                // Bottom-left of the pane, where every browser and every other
                // terminal puts this. **Width is capped at the pane**, so a
                // long URL is elided rather than drawn off the side of the
                // window.
                let want = sc(16) + sc(7) * url.chars().count() as i32;
                let w = want.min(fr.right - fr.left - sc(16)).max(sc(60));
                let h = sc(HEIGHT);
                let x = fr.left + sc(8);
                let y = fr.bottom - h - sc(8);
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOPMOST),
                    x,
                    y,
                    w,
                    h,
                    SWP_SHOWWINDOW | SWP_NOACTIVATE,
                );
                let _ = InvalidateRect(Some(hwnd), None, true);
                hlogf!(
                    frame_hwnd_of(surface),
                    "[hud] link bar over surface {:#x}: {:?}",
                    surface,
                    url
                );
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let url = HOVER
                    .lock()
                    .ok()
                    .and_then(|h| h.as_ref().map(|(_, u)| u.clone()))
                    .unwrap_or_default();
                // **`DT_PATH_ELLIPSIS`, not `DT_END_ELLIPSIS`.** What a person
                // needs from a long URL is the host and the end of the path;
                // cutting the tail off leaves the half that is identical for
                // every link on the page.
                paint_with(
                    hwnd,
                    &url,
                    COL_LINK_BG,
                    COL_TEXT,
                    DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_PATH_ELLIPSIS,
                );
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// --------------------------------------------------------------- scrollbar

/// Which surface the scrollbar is currently drawn for.
///
/// **`WM_PAINT` arrives with no arguments**, so without this it would have to
/// guess which surface's numbers to draw -- and the guess that suggests itself
/// (the focused pane) is wrong exactly when there is a split, which is the
/// only time it matters.
static SCROLL_SHOWN_FOR: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn scroll_counts(surface: usize) -> Option<(u64, u64, u64)> {
    SCROLL
        .lock()
        .ok()
        .and_then(|v| v.iter().find(|(s, ..)| *s == surface).map(|(_, t, o, l)| (*t, *o, *l)))
}

unsafe extern "system" fn scroll_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HUD_SYNC => {
                // `WPARAM(0)` means "re-evaluate the surface you are already
                // showing" -- that is what a frame resize sends.
                let surface = if wp.0 != 0 { wp.0 } else { SCROLL_SHOWN_FOR.load(Ordering::Acquire) };
                let Some((total, offset, len)) = scroll_counts(surface) else {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    SCROLL_SHOWN_FOR.store(0, Ordering::Release);
                    return LRESULT(0);
                };
                let Some(fr) = pane_rect_for(surface) else {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    SCROLL_SHOWN_FOR.store(0, Ordering::Release);
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] scrollbar: no pane owns surface {:#x}; hidden",
                        surface
                    );
                    return LRESULT(0);
                };
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                let h = fr.bottom - fr.top;
                if thumb(total, offset, len, h, sc(THUMB_MIN)).is_none() {
                    // Nothing to scroll. **Hidden rather than drawn
                    // full-height**: a full-height thumb and a scrollbar that
                    // has stopped being updated look exactly the same.
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    SCROLL_SHOWN_FOR.store(0, Ordering::Release);
                    hlogf!(
                        frame_hwnd_of(surface),
                        "[hud] scrollbar hidden for surface {:#x} ({} rows, {} visible)",
                        surface,
                        total,
                        len
                    );
                    return LRESULT(0);
                }
                let w = sc(SCROLL_W);
                // **Stored before the placement, not after.** `SetWindowPos`
                // with `SWP_SHOWWINDOW` can deliver `WM_PAINT` before it
                // returns, and a paint that ran while this still named the
                // previous surface would draw the other pane's position.
                SCROLL_SHOWN_FOR.store(surface, Ordering::Release);
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOPMOST),
                    fr.right - w,
                    fr.top,
                    w,
                    h,
                    SWP_SHOWWINDOW | SWP_NOACTIVATE,
                );
                let _ = InvalidateRect(Some(hwnd), None, true);
                hlogf!(
                    frame_hwnd_of(surface),
                    "[hud] scrollbar surface {:#x}: row {} of {}, {} visible",
                    surface,
                    offset,
                    total,
                    len
                );
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let counts = scroll_counts(SCROLL_SHOWN_FOR.load(Ordering::Acquire));
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(hwnd, &mut rc);
                    let track = CreateSolidBrush(COLORREF(COL_TRACK));
                    FillRect(hdc, &rc, track);
                    let _ = DeleteObject(track.into());
                    if let Some((total, offset, len)) = counts {
                        let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                        if let Some((y, th)) =
                            thumb(total, offset, len, rc.bottom, THUMB_MIN * dpi / 96)
                        {
                            let tr = RECT {
                                left: rc.left,
                                top: y,
                                right: rc.right,
                                bottom: y + th,
                            };
                            let brush = CreateSolidBrush(COLORREF(COL_THUMB));
                            FillRect(hdc, &tr, brush);
                            let _ = DeleteObject(brush.into());
                        }
                    }
                    let _ = EndPaint(hwnd, &ps);
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// ------------------------------------------------------------------- paint

fn paint(hwnd: HWND, label: &str, bg: u32, fg: u32) {
    paint_with(hwnd, label, bg, fg, DT_CENTER | DT_SINGLELINE | DT_VCENTER)
}

/// The same, with the caller saying how the text is laid out. The two signs
/// that are labels centre theirs; the link bar left-aligns and elides.
fn paint_with(hwnd: HWND, label: &str, bg: u32, fg: u32, flags: DRAW_TEXT_FORMAT) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        let brush = CreateSolidBrush(COLORREF(bg));
        FillRect(hdc, &rc, brush);
        let _ = DeleteObject(brush.into());
        SetBkMode(hdc, TRANSPARENT);
        STATE.with(|c| {
            let b = c.borrow();
            let Some(st) = b.as_ref() else { return };
            let old = SelectObject(hdc, st.font.into());
            SetTextColor(hdc, COLORREF(fg));
            let mut wide: Vec<u16> = label.encode_utf16().collect();
            // A little breathing room at both ends for the left-aligned
            // case. The centred signs are unaffected: the inset is symmetric.
            rc.left += 8;
            rc.right -= 8;
            DrawTextW(hdc, &mut wide, &mut rc, flags);
            SelectObject(hdc, old);
        });
        let _ = EndPaint(hwnd, &ps);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **These run on Windows and nowhere else.** `polter-host` does not build
    /// for the machine this port is written on, so unlike the rules in
    /// `polter-split-tree`, `polter-droppath`, `polter-cliargs` and
    /// `polter-urlpolicy`, nothing here is checked by `cargo test` while it is
    /// being written. Said out loud because **a `#[test]` that never runs looks
    /// exactly like one that passes.**
    ///
    /// What is pinned is the two failures that read as "the scrollbar is a bit
    /// off" rather than as a wrong answer:
    ///
    ///  * a thumb that goes to zero pixels in a long scrollback, which reads
    ///    as "there is nothing to scroll";
    ///  * a thumb that stops short of the bottom, which reads as "there is
    ///    more below" when you are already at the end.
    #[test]
    fn the_thumb_reaches_the_bottom_and_never_disappears() {
        // Nothing to scroll: no bar at all, rather than a full-height thumb.
        assert_eq!(thumb(24, 0, 24, 480, 18), None);
        assert_eq!(thumb(10, 0, 24, 480, 18), None);
        // No pane to draw in.
        assert_eq!(thumb(1000, 0, 24, 0, 18), None);

        // At the top.
        let (y, _) = thumb(1000, 0, 100, 500, 18).unwrap();
        assert_eq!(y, 0);

        // At the very bottom. The last row the view can start at is
        // `total - len`, and the thumb has to sit flush against the end there.
        let (y, h) = thumb(1000, 900, 100, 500, 18).unwrap();
        assert_eq!(y + h, 500, "the thumb stops short of the bottom of the track");

        // A stale offset past the end is clamped, not overrun.
        let (y, h) = thumb(1000, 5000, 100, 500, 18).unwrap();
        assert_eq!(y + h, 500);

        // A million rows with a 24-row view: the honest height is a fraction
        // of a pixel, and the floor is the whole of what keeps it visible.
        let (_, h) = thumb(1_000_000, 500_000, 24, 500, 18).unwrap();
        assert_eq!(h, 18);

        // The floor never exceeds the track.
        let (y, h) = thumb(1000, 900, 100, 2, 18).unwrap();
        assert!(h <= 2 && y + h <= 2, "thumb {y}+{h} does not fit in a 2px track");
    }

    /// Empty the table -- **and refuse to do it without the turn.**
    ///
    /// Every test below starts `let _turn = readonly_arena::exclusive();` and
    /// then calls this, so this is where a missing or dropped turn is caught.
    /// It is what makes the `let _ = exclusive();` mutation visible: that
    /// spelling drops the guard on the spot, `Drop` clears the flag, and the
    /// next line fails **in the mutated test and nowhere else**, on every run
    /// rather than on the unlucky ones.
    fn clear() {
        assert!(
            readonly_arena::this_thread_has_the_turn(),
            "this test is about to write the process-wide READONLY table \
             without holding `readonly_arena`'s turn. Start it with \
             `let _turn = readonly_arena::exclusive();` -- and bind it: \
             `let _ = exclusive();` drops the turn on the spot."
        );
        if let Ok(mut v) = READONLY.lock() {
            v.clear();
        }
    }

    /// **The floor for the line above: it has to be shown to fire.**
    ///
    /// A guard nobody has watched refuse is indistinguishable from one that
    /// cannot. This calls `clear` with no turn held and requires the panic,
    /// so the enforcement point is exercised on every run instead of only on
    /// the day somebody mutates a test.
    ///
    /// ⚠️ **It prints a panic backtrace, and no hook is installed to silence
    /// it.** `std::panic::set_hook` is process-wide, and `tabs`' D2 panics a
    /// thread on purpose -- muting this would mute somebody else's evidence.
    /// Noise is the cheaper of the two.
    ///
    /// It takes no turn and touches nothing: `clear` panics before it reaches
    /// the table, so this is safe to run beside the three tests below.
    #[test]
    fn clear_refuses_to_run_without_the_turn() {
        assert!(!readonly_arena::this_thread_has_the_turn());
        let refused = std::panic::catch_unwind(clear).is_err();
        assert!(
            refused,
            "`clear` wrote the table with no turn held. The check that makes \
             a dropped turn visible is not doing anything, so the three tests \
             below could lose their serialisation silently."
        );
    }

    /// **The regression this file was rewritten for.** Read-only used to be
    /// one process-wide bool, so a second surface answered the first one's
    /// state: with a split, the right pane's menu ticked «Read-only» because
    /// the left pane was. Asking about a surface nobody has said anything
    /// about must be `false`, not "whatever the last surface said".
    #[test]
    fn one_surface_going_readonly_does_not_answer_for_another() {
        let _turn = readonly_arena::exclusive();
        clear();
        on_readonly_for(0x1111, true);
        assert!(is_readonly_for(0x1111));
        assert!(!is_readonly_for(0x2222), "a different surface must answer for itself");
        clear();
    }

    /// Toggling back off is per surface too -- and the entry is updated, not
    /// appended, or the list would answer with whichever copy came first.
    #[test]
    fn a_surface_can_be_toggled_back_and_keeps_one_entry() {
        let _turn = readonly_arena::exclusive();
        clear();
        on_readonly_for(0x3333, true);
        on_readonly_for(0x3333, false);
        assert!(!is_readonly_for(0x3333));
        // **Read out, then assert.** `READONLY.lock().unwrap().len()` inside
        // the assertion holds the guard until the end of the statement, so a
        // failing assertion panics with the lock still held and poisons it --
        // and the next test's `unwrap()` then fails on the poison rather than
        // on its own subject. One real failure wearing three.
        let entries = READONLY.lock().map(|v| v.len()).unwrap_or_default();
        assert_eq!(entries, 1, "one entry per surface");
        clear();
    }

    /// A null surface names no terminal. Storing it would give every "no
    /// surface" caller a shared answer, which is the original bug in miniature.
    #[test]
    fn surface_zero_is_never_readonly_and_is_never_stored() {
        let _turn = readonly_arena::exclusive();
        clear();
        on_readonly_for(0, true);
        assert!(!is_readonly_for(0));
        // Read out before asserting, for the reason above.
        let empty = READONLY.lock().map(|v| v.is_empty()).unwrap_or_default();
        assert!(empty);
        clear();
    }
}
