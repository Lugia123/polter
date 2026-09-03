//! The tab model, and the window-state actions that come with it.
//!
//! **Why child windows.** A libghostty surface is bound to one HWND for its
//! whole life (`ghostty_surface_config_s.platform.win32.hwnd`), and
//! `wgl.zig` takes a `CS_OWNDC` device context for that window and keeps it
//! for the life of the GL context. So a tab cannot be a repaint of one
//! window -- each tab needs its own HWND. The top-level window becomes a
//! frame that owns a tab strip; each tab is a `WS_CHILD` window that fills
//! the rest and owns exactly one surface.
//!
//! **Why every mutation runs on the main thread.** `action_cb` is called
//! from whichever thread the core is on. Creating and destroying windows off
//! the owning thread is undefined in Win32, so an action that changes the
//! tab set is queued and a message is posted; `wndproc` drains the queue.
//! Actions that only read, or that Windows already marshals (`SetWindowText`),
//! are done inline.
//!
//! **Why the child windows take keyboard focus.** Keys and the IME belong to
//! whichever surface they are typed into, and the only thing that knows which
//! surface that is, is the window they arrived at. So the active tab's child
//! window holds the focus and its window procedure owns `WM_KEY*`, `WM_CHAR`
//! and the TSF document; the frame forwards focus down rather than handling
//! any of it. Keeping the keyboard on the frame instead would have meant a
//! second piece of state saying which surface a key was meant for -- one that
//! can disagree with the focus Windows already tracks.

use std::ffi::c_void;
use std::sync::Mutex;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_split_tree::{Focus, NewSplit, PaneId, Placement, Rect as TreeRect, Side, Tree};

use crate::ffi::*;
use crate::{api, logf, plogf, wlogf};

/// Posted to the frame window when the action queue has something in it.
pub const WM_POLTER_OP: u32 = WM_APP + 1;

/// One leaf of a tab's split tree: a window, and the surface bound to it.
///
/// **A pane is a window because it has to be.** A libghostty surface is bound
/// to one HWND for its whole life, and `wgl.zig` keeps a `CS_OWNDC` device
/// context for that window -- so a split cannot be "one surface drawing two
/// regions". macOS can nest `NSView`s inside a single surface's view; Windows
/// cannot, and that is why the tree's leaves are HWNDs here.
pub struct Pane {
    /// Stable identity, and what the tree stores. **Never an index**: panes
    /// are reordered and removed, and an index would silently come to mean a
    /// different pane.
    pub id: PaneId,
    pub hwnd: isize,
    pub surface: usize,
}

/// A tab's identity. **Never an index, and never reused.**
///
/// A newtype rather than a bare `u64` because tab ids and pane ids come out
/// of the *same* counter: with two id spaces sharing one allocator, passing
/// one where the other belongs would not collide, it would just quietly find
/// nothing. This turns that into a compile error.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct TabId(pub u64);

/// One tab: a tree of panes, which of them has focus, and a label.
pub struct Tab {
    pub id: TabId,
    pub tree: Tree,
    pub panes: Vec<Pane>,
    pub focused: PaneId,
    pub title: String,
    /// The tab's colour: 0 for none, otherwise an index into the strip's
    /// palette. **Stored on the tab, not in a side table keyed by position**
    /// -- for the same reason the title is: a parallel array is how "the
    /// order is right but the colours are wrong" gets written.
    pub color: u8,
    /// What Poltergeist has made of this terminal, as the core last said.
    /// `ghostty_action_poltergeist_role_e`: 0 none, 1 supervisor, 2 watched.
    ///
    /// **Kept here rather than asked for on demand because there is nothing
    /// to ask.** The core announces a mark through `poltergeist_mark` and
    /// publishes no getter, so a menu item that wants to tick itself has to
    /// have been listening. Before this field the Windows host discarded the
    /// action entirely.
    pub role: u8,
    pub shielded: bool,
    /// The shell's working directory, as the core last reported it
    /// (`GHOSTTY_ACTION_PWD`). Kept so a reopened tab lands where the closed
    /// one was, which is the whole of what makes "reopen" different from
    /// "new tab".
    pub cwd: Option<String>,
    /// The name **the user gave this tab**, as opposed to the one the program
    /// inside it announced.
    ///
    /// **Two different facts that were one field, and that is the whole of the
    /// defect this exists to fix.** A reopened tab had its name restored and
    /// then lost it a moment later, because the freshly started `cmd` sends
    /// its own `OSC 0` and the host wrote it over the top -- leaving a log
    /// line claiming a title had been restored and a strip showing
    /// `C:\WINDOWS\system32\cmd.exe`. The log and the screen disagreed, and
    /// the log was the one that was wrong.
    ///
    /// macOS keeps the same split (`titleOverride` in
    /// `BaseTerminalController`) and is explicit about the precedence: "When
    /// set, this takes precedence over the computed title from the terminal."
    /// Only this field is worth remembering across a close; the program's own
    /// title belongs to the program that is gone.
    pub title_override: Option<String>,
}

impl Tab {
    fn pane(&self, id: PaneId) -> Option<&Pane> {
        self.panes.iter().find(|p| p.id == id)
    }
    fn focused_pane(&self) -> Option<&Pane> {
        self.pane(self.focused)
    }
}

pub enum Op {
    NewTab,
    /// A second top-level window, with a tab in it.
    ///
    /// **Queued for the same reason `NewTab` is**, and it is the stronger
    /// case of the two: this one makes a frame *and* a surface, and both
    /// have to happen on the thread that owns windows.
    NewWindow,
    CloseTab(i32),
    GotoTab(i32),
    /// What the core's `move_tab` action carries: a relative shift of the
    /// active tab. Kept faithful to the action rather than resolved at the
    /// call site, because the tab set can change between queueing and running.
    MoveTabBy(i64),
    ToggleFullscreen,
    ToggleMaximize,
    ResetWindowSize,
    /// A program announced its own title. **Carries the surface it came
    /// from**, because the tab it belongs to is not necessarily the tab in
    /// front: a build running in a background tab renames itself as it goes.
    ///
    /// A `usize` rather than a `Surface`, matching `Pane.surface`: this queue
    /// lives behind the `STATE` mutex, and a raw pointer in it would make the
    /// whole of `State` un-`Send`.
    SetTabTitle { surface: usize, title: String },
    CopyTitleToClipboard,
    PresentTerminal,
    /// `ghostty_action_split_direction_e`.
    NewSplit(i32),
    /// `ghostty_action_goto_split_e`.
    GotoSplit(i32),
    /// amount in pixels, `ghostty_action_resize_split_direction_e`.
    ResizeSplit(u16, i32),
    EqualizeSplits,
    ToggleSplitZoom,
    /// A surface asked to be closed: its pane goes, and the tab with it if it
    /// was the last one. Carries the pane id, which is the surface userdata.
    ClosePane(PaneId),
    /// The quick terminal, which is not a tab and not a pane -- but the queue
    /// is how anything reaches the thread that owns windows, so it comes
    /// through here too.
    ToggleQuickTerminal,
    /// A tab whose surface is not the default one: the chat terminal, today.
    /// Queued like every other window-making request, because `create_tab`
    /// must run on the thread that owns windows.
    NewTabWith(NewTab),
    /// Put a closed tab back: its shell starts in `cwd`, it gets its old name
    /// back, and it goes back to `index` rather than onto the end.
    ///
    /// **Queued rather than done at the menu**, because it makes a window,
    /// and `create_tab` must run on the thread that owns them.
    ReopenTab {
        cwd: String,
        title: String,
        index: usize,
    },
}

impl Op {
    /// A short, stable name for the log.
    ///
    /// **Spelled out rather than derived from `Debug`.** `Debug` on these
    /// variants prints their payloads -- a whole `NewTab` struct, a title, a
    /// directory -- and the queue's lines are read by eye in pairs (`queued`
    /// then `running`), so they have to be short enough to compare at a
    /// glance and stable enough that a payload change does not rewrite them.
    pub fn name(&self) -> &'static str {
        match self {
            Op::NewTab => "NewTab",
            Op::NewWindow => "NewWindow",
            Op::CloseTab(_) => "CloseTab",
            Op::GotoTab(_) => "GotoTab",
            Op::MoveTabBy(_) => "MoveTabBy",
            Op::ToggleFullscreen => "ToggleFullscreen",
            Op::ToggleMaximize => "ToggleMaximize",
            Op::ResetWindowSize => "ResetWindowSize",
            Op::SetTabTitle { .. } => "SetTabTitle",
            Op::CopyTitleToClipboard => "CopyTitleToClipboard",
            Op::PresentTerminal => "PresentTerminal",
            Op::NewSplit(_) => "NewSplit",
            Op::GotoSplit(_) => "GotoSplit",
            Op::ResizeSplit(..) => "ResizeSplit",
            Op::EqualizeSplits => "EqualizeSplits",
            Op::ToggleSplitZoom => "ToggleSplitZoom",
            Op::ClosePane(_) => "ClosePane",
            Op::ToggleQuickTerminal => "ToggleQuickTerminal",
            Op::NewTabWith(_) => "NewTabWith",
            Op::ReopenTab { .. } => "ReopenTab",
        }
    }
}

/// Everything that belongs to **one window**.
///
/// **Only three fields, and the shortness is the point.** A second window
/// does not get a copy of `State`: `next_id` hands out `TabId`s and `PaneId`s
/// that are unique *in this process*, and a per-window copy of it would give
/// two windows each a `Tab(1)`. That is not merely confusing --
/// `windows/tools/window-tagged-logs.py` excuses any log line that mentions a
/// `TabId` on the grounds that an id is already unambiguous, and duplicating
/// the counter takes that premise away **while the checker carries on
/// reporting green**. `initial_input` is the same shape: copied, every new
/// window would replay `--clock`'s text into its first shell.
///
/// So the split is by field, not by struct, and the fields that move are the
/// ones a window genuinely owns: which tabs are in it and which of them is in
/// front. The rest -- `scale`, `min_*`, `pre_fullscreen`, the op queue --
/// are still one copy between all windows, which is **wrong and known to be
/// wrong**; see `State`. Sorting those out is B1-a, and each has its own
/// answer rather than one blanket one.
pub struct WindowState {
    /// The frame's `HWND`. `isize` rather than `HWND` because `State` has to
    /// be `Send` and a raw pointer is not.
    pub frame: isize,
    pub tabs: Vec<Tab>,
    pub active: usize,
    /// The window's own queue of pending mutations.
    ///
    /// **One queue per window, rather than one queue with a target on each
    /// op.** Both designs answer "whose op is this"; they differ on the day
    /// the window goes away before its op runs, and that difference is the
    /// whole reason to choose deliberately rather than by convenience:
    ///
    ///  - **Per window (this one).** The queue is part of the window, so it
    ///    goes when the window goes. There is no moment at which a live op
    ///    holds a dead window's handle, so there is nothing to resolve, and
    ///    therefore nothing that can resolve *wrongly*.
    ///  - **One queue, targets on the ops.** The op outlives its window and
    ///    has to be refused at the front of the queue. That is a correct
    ///    design, but it has a failure mode this one cannot have: the refusal
    ///    is a check somebody has to write, and if it is missing or wrong the
    ///    fallback is "run it on the current window" -- a tab from the window
    ///    you just closed silently appearing in another one.
    ///
    /// The cost of this choice is that dropping a closed window's ops is
    /// **normal completion here, not a defect**, which is worth saying next to
    /// E4 ("closing a window must do none of the things quitting does"):
    /// discarding that window's queue is part of the window closing, not part
    /// of anything shutting down.
    pub ops: Vec<QueuedOp>,
    /// From the `size_limit` action: the smallest the core says this window
    /// may be. Reported to Windows through `WM_GETMINMAXINFO`.
    ///
    /// **Per window because the message is.** `WM_GETMINMAXINFO` arrives at a
    /// frame and is answered for that frame; with one copy between them, a
    /// limit computed for window 2's cell grid became the floor window 1
    /// could not be dragged below.
    pub min_w: u32,
    pub min_h: u32,
    pub max_w: u32,
    pub max_h: u32,
    /// Saved frame state while fullscreen, so the toggle can undo itself.
    ///
    /// **The clearest of the lot.** One copy, two windows: window 2 goes
    /// fullscreen and overwrites the placement window 1 was going to be
    /// restored to, and window 1 comes out of fullscreen the size and place
    /// of window 2.
    pub pre_fullscreen: Option<(WINDOWPLACEMENT, isize)>,
    /// This window's content scale, from the DPI of the display it is on.
    ///
    /// **Structurally per window; not claimed as verified.** Two monitors of
    /// different DPI is the case this matters for, and the machine these are
    /// tested on has one screen -- where both windows necessarily report the
    /// same number, so "print both and compare" is a criterion that cannot
    /// fail. What is checked is that the two are separately addressable and
    /// that `WM_DPICHANGED` writes only the window it arrived at.
    pub scale: f64,
    /// The size this window's first surface asked for, for
    /// `reset_window_size`.
    pub initial: Option<(u32, u32)>,
    /// **The directory actually handed to `sc.working_directory`** by the
    /// last `create_pane` in this window, or `None` when none was.
    ///
    /// Written where the pointer is set, read by the restore log line. It
    /// exists because that line must report the value that was *used*, not
    /// the one the caller meant to use -- the same value right up until the
    /// moment worth catching, when the string could not be made into a
    /// `CString` and the shell quietly started somewhere else.
    ///
    /// **Per window, though it is only ever read immediately after being
    /// written.** "Only ever" is a property of today's call order, not of the
    /// field; a reopen in window 2 that reported window 1's directory would
    /// be a line that is wrong about the one thing it exists to be right
    /// about.
    pub last_pane_cwd: Option<String>,
}

impl WindowState {
    /// **Every field of this struct, as one line.**
    ///
    /// This is the reading E3 and G5 are taken from: two windows are put into
    /// different states, one dump is taken, and the two lines are compared
    /// field by field. A field missing from this line is a field those
    /// criteria silently do not cover -- and the way that goes wrong is the
    /// worst available, because the comparison still passes.
    ///
    /// **The destructuring is exhaustive and has no `..`, and that is the
    /// mechanism.** Add a field to `WindowState` and this stops compiling
    /// until the field is named here. The alternative on offer was a test
    /// asserting the line mentions every field; a test has to be run, and
    /// this cannot be got past at all. If a new field genuinely does not
    /// belong in the line, binding it to `_name` is a decision somebody has
    /// written down, which is the point -- as opposed to an omission, which
    /// looks like nothing.
    ///
    /// **Every value is rendered, not summarised.** `ops` prints its depth
    /// rather than its contents because the contents are timestamps and would
    /// differ between two dumps of an idle window -- but the depth is the
    /// part a criterion can be written against.
    pub fn state_fields(&self) -> String {
        let WindowState {
            frame,
            tabs,
            active,
            ops,
            min_w,
            min_h,
            max_w,
            max_h,
            pre_fullscreen,
            scale,
            initial,
            last_pane_cwd,
        } = self;
        let listed: Vec<String> = tabs
            .iter()
            .map(|t| format!("{}:{}", t.id.0, t.title))
            .collect();
        let active_id = tabs.get(*active).map(|t| t.id.0).unwrap_or(0);
        format!(
            "frame=0x{:x} tabs=[{}] active={} n={} panes={} ops={} min={}x{} max={}x{} \
             prefullscreen={} scale={:.2} initial={} lastcwd={}",
            frame,
            listed.join(","),
            active_id,
            tabs.len(),
            tabs.get(*active).map(|t| t.panes.len()).unwrap_or(0),
            ops.len(),
            min_w,
            min_h,
            max_w,
            max_h,
            match pre_fullscreen {
                // The saved style, not just "yes": two windows can both be
                // fullscreen and be restoring to different things.
                Some((_, style)) => format!("style=0x{style:x}"),
                None => "none".to_string(),
            },
            scale,
            match initial {
                Some((w, h)) => format!("{w}x{h}"),
                None => "none".to_string(),
            },
            match last_pane_cwd {
                Some(c) => c.as_str(),
                None => "none",
            },
        )
    }
}

/// An op waiting to run, and the two facts the log needs about it.
pub struct QueuedOp {
    pub op: Op,
    /// When it was queued.
    ///
    /// **Read only by the `--ops-delay` test hook**, which is what makes that
    /// hook a stopwatch rather than a detour: the delay is a comparison
    /// against this stamp at the front of the queue, so a delayed op takes
    /// exactly the path an undelayed one takes, later. Nothing about *which*
    /// code runs depends on it.
    pub at: std::time::Instant,
    /// Which call site queued it, for the log line. A `&'static str` so it
    /// cannot be built out of runtime data and cannot allocate on a path that
    /// runs from the core's thread.
    pub from: &'static str,
}

/// Everything that is genuinely one thing for the whole process.
///
/// **The window list is deliberately not in here.** It lives in the private
/// `Registry` alongside this, so that `shared()` -- the accessor allowed to
/// take no argument -- has no path to a window at all. Leaving `windows` on
/// this struct would mean that accessor could still reach window 1, and
/// "quietly reaches the first window" is the exact defect this cell removes.
pub struct State {
    /// Handed out to panes **and tabs**, never reused. One counter for both,
    /// so an id means exactly one thing in this process. Starts at 1 so that
    /// 0 can mean "no pane" in the C userdata pointer.
    ///
    /// **Shared on purpose, and it is the one field that must not be split.**
    /// A per-window counter would give two windows each a `Tab(1)` -- and
    /// beyond the confusion, `windows/tools/window-tagged-logs.py` excuses any
    /// log line that mentions a `TabId` on the grounds that an id is already
    /// unambiguous. Splitting this takes that premise away **while the checker
    /// carries on reporting green**, which is the failure this project keeps
    /// meeting: the reading does not change and the conclusion is already
    /// wrong.
    pub next_id: u64,
    /// Typed into the first shell as if the user had typed it (`--clock`).
    /// Owned here because the core reads the pointer during `surface_new`.
    ///
    /// **Shared, and the consequence is written down rather than left to be
    /// discovered.** `create_pane` `take()`s it, so exactly one shell in the
    /// process ever receives it: the first tab of the first window. **A shell
    /// started in a second window does not replay `--clock`'s text.** Split
    /// per window it would be typed again into every new window's first
    /// shell, which is not what a diagnostic flag for one terminal means.
    pub initial_input: Option<std::ffi::CString>,
    /// Working directories reported for a surface that has no `Tab` yet.
    ///
    /// **This exists because of an ordering, not as a cache.** The core emits
    /// `pwd` from inside `ghostty_surface_new`, and that call happens before
    /// the `Tab` holding the pane is pushed. Without somewhere to put it the
    /// first `pwd` of every tab is dropped -- and the symptom would be that
    /// reopening a tab you never `cd`'d in lands in the wrong place.
    ///
    /// **Shared, because at the moment it is written there is no window to
    /// file it under.** It is keyed by surface -- unique in the process -- and
    /// the write happens inside `ghostty_surface_new`, before the `Tab` and
    /// therefore before anything connects that surface to a frame. A
    /// per-window copy would need the answer this exists precisely because
    /// nobody has yet.
    pub pending_cwd: Vec<(usize, String)>,
}

impl State {
    const fn new() -> Self {
        State {
            next_id: 1,
            initial_input: None,
            pending_cwd: Vec::new(),
        }
    }

}

/// The window list plus the process-wide fields, behind the one lock.
///
/// Private: nothing outside this file names it, and the three public ways in
/// (`win`, `shared`, `with_windows`) each expose one half or the other.
struct Registry {
    /// One entry per live window, in creation order -- the same order
    /// `winid::FRAMES` uses, so `windows[0]` is `w1`.
    ///
    /// **A `Vec` rather than a `HashMap`.** There are one or two of these,
    /// three if somebody is trying; a linear scan over that is not worth a
    /// hasher, and creation order is a property worth keeping rather than
    /// one to reconstruct.
    windows: Vec<WindowState>,
    shared: State,
}

impl Registry {
    const fn new() -> Self {
        Registry { windows: Vec::new(), shared: State::new() }
    }
}

static STATE: Mutex<Registry> = Mutex::new(Registry::new());

/// The one lock, with a tripwire that **names the holder**.
///
/// **The invariant this file lives by: never hold this across a Win32 call
/// that can dispatch a message.** `SetWindowPos`, `ShowWindow`, `SetFocus`,
/// `DestroyWindow` and friends call a window procedure *on this thread*
/// before they return, and every window procedure here needs the same lock.
/// A `std` mutex is not re-entrant, so doing it deadlocks the main thread --
/// silently, with a window that never responds and a log that simply stops.
/// Take a copy of what is needed, drop the guard, then call Windows.
///
/// **Three things went wrong with the first version of this tripwire, and all
/// three are fixed here:**
///
///  1. **It spun instead of waiting.** The fallback was written as a
///     recursive call, so a contended lock became an infinite retry at 100%
///     CPU. (That was not a design choice: a blanket regex meant to replace
///     the lock boilerplate at every call site also replaced the one inside
///     this function.)
///  2. **It logged on every turn of that spin** -- 100,000 identical lines
///     and 6.7 MB in two minutes. The difference between one line and a
///     hundred thousand is the difference between evidence and noise.
///  3. **Its text contradicted its behaviour**: it said "if the log stops
///     here it is re-entrant", while guaranteeing the log would never stop.
///
/// And it answered the wrong question. Knowing the lock is contended is
/// nearly useless; knowing **which line holds it** is the whole diagnosis.
/// `#[track_caller]` gets the waiter's location for free, and the guard
/// records the holder's, so a contended lock prints both.
struct Guard {
    inner: std::sync::MutexGuard<'static, Registry>,
}

impl std::ops::Deref for Guard {
    type Target = Registry;
    fn deref(&self) -> &Registry {
        &self.inner
    }
}
impl std::ops::DerefMut for Guard {
    fn deref_mut(&mut self) -> &mut Registry {
        &mut self.inner
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        HOLDER.store(0, std::sync::atomic::Ordering::Release);
    }
}

/// One window's state, with the lock held. Derefs to that window alone.
pub struct WinGuard {
    inner: Guard,
    at: usize,
}

impl std::ops::Deref for WinGuard {
    type Target = WindowState;
    fn deref(&self) -> &WindowState {
        &self.inner.windows[self.at]
    }
}
impl std::ops::DerefMut for WinGuard {
    fn deref_mut(&mut self) -> &mut WindowState {
        &mut self.inner.windows[self.at]
    }
}

/// The process-wide fields, with the lock held.
pub struct SharedGuard {
    inner: Guard,
}

impl std::ops::Deref for SharedGuard {
    type Target = State;
    fn deref(&self) -> &State {
        &self.inner.shared
    }
}
impl std::ops::DerefMut for SharedGuard {
    fn deref_mut(&mut self) -> &mut State {
        &mut self.inner.shared
    }
}

/// `&'static Location` of whoever holds the lock, or 0.
static HOLDER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
/// How many times anyone has had to wait. Bounds the logging.
static CONTENDED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

fn claim(
    inner: std::sync::MutexGuard<'static, Registry>,
    here: &'static std::panic::Location<'static>,
) -> Guard {
    HOLDER.store(
        here as *const _ as usize,
        std::sync::atomic::Ordering::Release,
    );
    Guard { inner }
}

fn holder_str() -> String {
    let p = HOLDER.load(std::sync::atomic::Ordering::Acquire);
    if p == 0 {
        return "nobody (released between the failed try and this read)".to_string();
    }
    // Safe: only ever a `&'static Location` stored by `claim`.
    let loc = unsafe { &*(p as *const std::panic::Location<'static>) };
    format!("{}:{}", loc.file(), loc.line())
}

/// The lock itself. **Private, and that is the whole of G1.**
///
/// Every way in now says which window it means, or says out loud that it
/// means none of them:
///
///  - `window(frame)` -- one window's state. Most callers.
///  - `shared()` -- the three process-wide fields, and nothing else. It
///    cannot reach a window, so it cannot accidentally reach window 1.
///  - `with_windows` / `with_windows_mut` -- a scan across every window, for
///    lookups whose key (`HWND`, `Surface`, `PaneId`) is unique in the
///    process. Those are answering "where is this?", not choosing a window.
///
/// **There is deliberately no accessor that hands out "the state".** That
/// function existed, was called seventy-three times, and every one of those
/// calls was a place that had not been asked which window it meant -- while
/// reading exactly like a call that had.
#[track_caller]
fn reg() -> Guard {
    let here = std::panic::Location::caller();
    match STATE.try_lock() {
        Ok(g) => return claim(g, here),
        Err(std::sync::TryLockError::Poisoned(p)) => return claim(p.into_inner(), here),
        Err(std::sync::TryLockError::WouldBlock) => {}
    }

    // Contended. Say it once, with both ends of the story.
    let n = CONTENDED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
    if n == 1 || n % 10_000 == 0 {
        logf!(
            "[state] contended #{}: waiter {}:{}, holder {}",
            n,
            here.file(),
            here.line(),
            holder_str()
        );
    }

    // Wait, but not forever. A lock this file holds is never held for long,
    // so five seconds means it is never coming back -- and **a process that
    // dies saying who held the lock is worth more than one that spins**.
    //
    // The wait is timed and reported on the way out because the two illnesses
    // that produce a contended lock look identical in a log that only says
    // "contended". **One call stuck forever and ten thousand calls each
    // waiting a moment are different bugs, and the earlier version of this
    // line described only the first one** -- it read "if the log stops here it
    // is re-entrant", and then a real build printed it 24 MB of times without
    // ever stopping. Saying how long each one actually waited turns that
    // distinction into a reading instead of an inference from silence.
    let began = std::time::Instant::now();
    let deadline = began + std::time::Duration::from_secs(5);
    loop {
        let got = match STATE.try_lock() {
            Ok(g) => Some(claim(g, here)),
            Err(std::sync::TryLockError::Poisoned(p)) => Some(claim(p.into_inner(), here)),
            Err(std::sync::TryLockError::WouldBlock) => None,
        };
        if let Some(g) = got {
            let waited = began.elapsed();
            if n == 1 || n % 10_000 == 0 {
                logf!(
                    "[state] contended #{} resolved after {:.1}ms (churn, not a deadlock)",
                    n,
                    waited.as_secs_f64() * 1000.0
                );
            }
            return g;
        }
        if std::time::Instant::now() >= deadline {
            let msg = format!(
                "[state] DEADLOCK: {}:{} waited 5s; holder is {}",
                here.file(),
                here.line(),
                holder_str()
            );
            logf!("{}", msg);
            panic!("{}", msg);
        }
        std::thread::yield_now();
    }
}

/// One window's state, or `None` if there is no such window.
///
/// **`Option`, not a fallback.** A frame this does not know is a bug at the
/// caller -- a stale handle, or a pane's `HWND` where a frame's was meant --
/// and answering it with the first window's state would make that bug produce
/// a plausible screen and a plausible log.
#[track_caller]
pub fn window(frame: HWND) -> Option<WinGuard> {
    let key = frame.0 as isize;
    let g = reg();
    let at = g.windows.iter().position(|w| w.frame == key)?;
    Some(WinGuard { inner: g, at })
}

/// The process-wide fields: the id counter, the initial input, the pending
/// working directories. **It cannot reach a window from here**, which is the
/// point -- these three are shared because they are genuinely one thing, and
/// a caller reaching for them should not find a window in the same hand.
#[track_caller]
// window-free: the three process-wide fields, and it can reach no window at all
pub fn shared() -> SharedGuard {
    SharedGuard { inner: reg() }
}

/// Look across every window, for a key that is unique in the whole process.
///
/// **Not a way to get at "the windows"**: it is how `surface_of`,
/// `frame_of_pane` and their neighbours answer "which window is this thing
/// in?", which is a search, not a choice. The closure form keeps the borrow
/// from escaping across a Win32 call, the same reason `strip::with_ui` has it.
#[track_caller]
// window-free: a scan over every window, for a key that is unique in the process
pub fn with_windows<R>(f: impl FnOnce(&[WindowState]) -> R) -> R {
    let g = reg();
    f(&g.windows)
}

#[track_caller]
// window-free: a scan over every window, for a key that is unique in the process
pub fn with_windows_mut<R>(f: impl FnOnce(&mut Vec<WindowState>) -> R) -> R {
    let mut g = reg();
    f(&mut g.windows)
}

/// Queue an op and wake the main thread. Safe from any thread.
/// How long a queued op waits before it is allowed to run, in milliseconds.
///
/// **A stopwatch, not a detour.** Zero unless `--ops-delay=N` was given, and
/// the only thing a non-zero value changes is the comparison in `run_ops`
/// that decides whether the op at the front is due yet. It does not change
/// which queue an op goes into, when it is enqueued, which code drains it, or
/// which arm runs it -- the op takes exactly the path it always takes, later.
///
/// **The variant of this hook that would be worth refusing** is one that
/// delays *enqueueing*. That reads the same at the call site and is the same
/// one-line change, and it destroys the two criteria the hook exists to make
/// possible: with nothing on the queue during the delay, "move the focus
/// between queueing and running" is measuring a window of time in which
/// nothing has been queued. Every experiment would pass, and pass vacuously.
/// So the delay is applied at the front of `run_ops` and nowhere else, and
/// `post_op` is written to be read alongside this paragraph.
static OPS_DELAY_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn ops_delay_ms() -> u64 {
    OPS_DELAY_MS.load(std::sync::atomic::Ordering::Relaxed)
}

/// Turn the hook on. **Called once, from argument parsing, and silent at
/// zero**: a test hook that announces itself when it is off teaches people to
/// ignore the line, and a test hook that is on by default is not a test hook.
pub fn set_ops_delay(ms: u64) {
    OPS_DELAY_MS.store(ms, std::sync::atomic::Ordering::Relaxed);
    if ms > 0 {
        // process-wide: one hook for the process, set before any window has
        // queued anything
        crate::plogf!("[ops] delay={}ms (test hook)", ms);
    }
}

/// Queue a mutation **against a named window**, and wake that window.
///
/// **The target is a parameter and cannot be defaulted, and that is the whole
/// of C4.** This used to take only the op: it pushed onto one process-wide
/// queue and woke `frame_hwnd()`, so every action queued anywhere ran on the
/// first window. Nothing about the call sites said which window they meant,
/// because there was nothing to say. Making the window an argument means the
/// compiler asks all twenty of them, and a twenty-first cannot be added
/// without answering.
///
/// **A frame this does not know is refused, not redirected.** Falling back to
/// the first window is the one behaviour that must not exist here: it turns
/// "this op has no window" into "this op runs on somebody else's window",
/// which is invisible in every reading except the screen.
pub fn post_op(frame: HWND, op: Op, from: &'static str) {
    let name = op.name();
    let queued = {
        match window(frame) {
            Some(mut w) => {
                w.ops.push(QueuedOp { op, at: std::time::Instant::now(), from });
                Some(w.ops.len())
            }
            None => None,
        }
    };
    let Some(depth) = queued else {
        // process-wide: the op names no window this host is tracking, which is
        // the fact being reported; there is no window to attribute it to
        crate::plogf!(
            "[ops] {} from {} names no live window ({:?}); not queued",
            name,
            from,
            frame.0
        );
        return;
    };
    // **The target is in the line, and so is where it came from.** Which
    // window an op ran on can be read from its effect, but "it happened to
    // land on the focused window" and "it was addressed to that window" leave
    // the same effect behind -- so the address is recorded when it is chosen,
    // not inferred afterwards from where it arrived.
    wlogf!(frame, "[ops] queued {} for {} (from {}); {} in this window's queue",
        name, crate::winid::tag(frame), from, depth);
    unsafe {
        let _ = PostMessageW(Some(frame), WM_POLTER_OP, WPARAM(0), LPARAM(0));
    }
}

/// Start tracking a window. Called by `create_frame`, once per frame.
///
/// **Explicit, and for the same reason `winid::created` is explicit.** A
/// registry that grows a window the first time somebody asks about one cannot
/// tell "a window exists" from "somebody asked about a handle", and both of
/// the questions this file has to answer -- how many windows, and whose tabs
/// -- turn on that difference.
/// **Called only by `winid::created`, which registers the other half.**
///
/// A window is recorded in two registries and they must be written as one
/// act: a frame that is in `tabs` and not in `winid` (or the reverse) is a
/// state every reader can observe and none of them expects, and the gap
/// between two statements is where somebody later adds a third.
/// `winid::created` is that one act; see its documentation for what the gap
/// used to cost and why nothing goes red when it comes back.
///
/// `pub(crate)` is as narrow as Rust goes here -- it stops other crates, not
/// other modules -- so "only `winid::created` calls this" is a sentence and
/// not a rule the compiler keeps. It is written down because an unwritten
/// convention and an unnoticed second caller look the same from here.
pub(crate) fn add_window(frame: HWND) {
    let key = frame.0 as isize;
    let n = with_windows_mut(|ws| {
        if ws.iter().any(|w| w.frame == key) {
            return None;
        }
        ws.push(WindowState {
            frame: key,
            tabs: Vec::new(),
            active: 0,
            ops: Vec::new(),
            min_w: 0,
            min_h: 0,
            max_w: 0,
            max_h: 0,
            pre_fullscreen: None,
            // Replaced by the real DPI in `create_frame`, which measures the
            // window it has just made. 1.0 is what a window's scale is before
            // anybody has asked, not a guess at what it will turn out to be.
            scale: 1.0,
            initial: None,
            last_pane_cwd: None,
        });
        Some(ws.len())
    });
    // **Logged outside the closure**, because `wlogf!` takes the same lock:
    // `winid::tag` reads the frame registry and this file's rule is that no
    // guard is held across a call that can take one.
    match n {
        Some(n) => wlogf!(frame, "[win] state registered; {} window(s) tracked", n),
        // Not silently ignored: a second registration means two things think
        // they created this window, and the count is what the shutdown rule
        // reads.
        None => wlogf!(frame, "[win] add_window: already registered"),
    }
}

/// Stop tracking a window, once Windows has destroyed it.
///
/// **Idempotent, like `winid::destroyed` and for the same reason**: more than
/// one route can reach it, and the second one must not be able to change an
/// answer the first one already gave correctly.
pub fn remove_window(frame: HWND) {
    let key = frame.0 as isize;
    let (dropped, pending, after) = with_windows_mut(|ws| {
        let before = ws.len();
        // **What was still queued for it, counted before it goes.** Dropping
        // a closed window's ops is this design's normal completion rather
        // than a fault (see `WindowState::ops`), and normal or not it is work
        // the user asked for that will not happen -- so it is said out loud
        // with a number, not left as the absence of a line.
        let pending: Vec<&'static str> = ws
            .iter()
            .find(|w| w.frame == key)
            .map(|w| w.ops.iter().map(|q| q.op.name()).collect())
            .unwrap_or_default();
        ws.retain(|w| w.frame != key);
        (before != ws.len(), pending, ws.len())
    });
    if !dropped {
        return;
    }
    forget_activated(frame);
    if !pending.is_empty() {
        wlogf!(
            frame,
            "[ops] dropped {} queued op(s) with {}: {}",
            pending.len(),
            crate::winid::tag(frame),
            pending.join(", ")
        );
    }
    wlogf!(frame, "[win] state dropped; {} window(s) tracked", after);
}

/// The frame that was activated most recently. 0 when none has been.
///
/// **This is what the fifteen panel call sites were waiting for.** They spent
/// one cell calling `frame_hwnd()` -- the first window -- each with its own
/// inline comment about it. Concentrating that into one named function was
/// the whole value of the previous cell: the fix is a function body, and not
/// one of the fifteen changes.
///
/// **There is no longer a `frame_hwnd` beside this.** There was, returning the
/// first window, and the two were kept apart on the argument that some callers
/// genuinely mean the first one. After the conversion none did: all fifteen
/// wanted the window in front. A second function that returns the same value
/// and has no callers is not a distinction, it is a place for the next person
/// to land by accident.
///
/// **Ours, recorded in `WM_ACTIVATE`, and that is a choice among three.**
/// Win32 offers at least three answers to "which window is the user on", and
/// the two obvious ones are wrong here for the same reason -- they are right
/// about the *window* and wrong about the *terminal window*:
///
///  - **`GetForegroundWindow()`** is whatever is in front on the whole
///    desktop, which is frequently not ours at all. Alt-tab to a browser and
///    it answers with the browser; a panel that centred itself on that would
///    be centred on another program's rectangle, and `own_and_place` would
///    set `GWLP_HWNDPARENT` to a window in another process.
///  - **`GetFocus()`** is this thread's focused *control*, so inside our own
///    process it answers with whatever has the caret -- a pane's child window,
///    the settings page's edit box, the command palette's input. **And that is
///    exactly the moment this function is asked**: the settings page calls it
///    while showing itself, so `GetFocus` would hand the page back its own
///    handle and it would become its own owner.
///
/// Only a record we keep ourselves answers the question actually being asked,
/// which is "which of *our terminal windows* was the person last looking at".
/// It survives a panel taking the focus for free -- panels are not frames, so
/// they never enter this record. The frame class `PolterHost` is used by
/// `create_frame` and by nothing else, so the `WM_ACTIVATE` that writes this
/// can only ever be a frame's.
static ACTIVE_FRAME: std::sync::atomic::AtomicIsize = std::sync::atomic::AtomicIsize::new(0);

/// A frame has been activated. Called from its `WM_ACTIVATE`.
pub fn note_activated(frame: HWND) {
    let key = frame.0 as isize;
    if ACTIVE_FRAME.swap(key, std::sync::atomic::Ordering::Release) != key {
        wlogf!(frame, "[win] activated; panels now open over this window");
    }
}

/// Forget a frame that is going away.
///
/// **Not strictly required, because `overlay_frame` validates.** Kept because
/// leaving a dead handle in a variable named "the active frame" makes the next
/// reader's job harder than it needs to be, and because a stale record that is
/// only ever corrected on the way out is a fact with two states of truth.
fn forget_activated(frame: HWND) {
    let key = frame.0 as isize;
    let _ = ACTIVE_FRAME.compare_exchange(
        key,
        0,
        std::sync::atomic::Ordering::AcqRel,
        std::sync::atomic::Ordering::Relaxed,
    );
}

// window-free: it answers "which window is the person on", which is a property
// of the process rather than an argument any caller could supply
/// The window a **floating panel** should attach itself to: the terminal
/// window the person was last on.
///
/// **Validated against the live registry on every call, and that is the whole
/// of the degenerate path.** The recorded handle can name a window that has
/// since been destroyed -- close the focused window and a panel can be asked
/// for before any other frame reports activation -- and **handing a destroyed
/// `HWND` back would be worse than handing back nothing**. Nothing is
/// checkable: every caller already tests `is_null`. A dead handle is not: it
/// passes that test, and then `GetWindowRect` fails and is ignored, or
/// `SetWindowLongPtrW(GWLP_HWNDPARENT)` succeeds against a handle Windows has
/// recycled for somebody else's window.
///
/// So the order is: the recorded frame **if it is still one of ours**, else
/// any live window, else null.
///
/// **The middle step is deliberate rather than tidy.** Falling straight to
/// null when the record is stale would leave a panel ownerless for the moment
/// between one window closing and the next being activated -- which is a real
/// moment, because closing a window is exactly when something else gets shown.
/// A live window is a worse answer than the right window and a much better one
/// than no window.
pub fn overlay_frame() -> HWND {
    let want = ACTIVE_FRAME.load(std::sync::atomic::Ordering::Acquire);
    let picked = with_windows(|ws| {
        let live: Vec<isize> = ws.iter().map(|w| w.frame).collect();
        pick_overlay(want, &live)
    });
    HWND(picked as *mut c_void)
}

/// The whole of the choice `overlay_frame` makes, as arithmetic.
///
/// **Split out so it can be run on the machine the port is written on.**
/// Everything around it is Win32 and only executes on the target, and the part
/// worth testing is not the Win32 -- it is the degenerate path: what happens
/// when the remembered window has been destroyed, and when there is no window
/// at all. Those are the two cases nobody produces by accident while clicking
/// around, and they are the two where a wrong answer is a recycled `HWND`
/// rather than a visible mistake.
///
/// `0` means "no window", which is what `HWND(null)` is on the other side.
fn pick_overlay(want: isize, live: &[isize]) -> isize {
    // The remembered one, but **only if it is still one of ours**. This is the
    // line that stops a destroyed handle being handed out.
    if want != 0 && live.contains(&want) {
        return want;
    }
    // Any live window beats no window: closing a window is exactly when
    // something else gets shown, and the moment between that close and the
    // next activation is real.
    live.first().copied().unwrap_or(0)
}

#[cfg(test)]
mod overlay_tests {
    use super::pick_overlay;

    #[test]
    fn the_remembered_window_wins_while_it_is_alive() {
        assert_eq!(pick_overlay(20, &[10, 20, 30]), 20);
    }

    /// **The case this function exists for.** The remembered window has been
    /// destroyed; handing its handle back would pass every `is_null` check the
    /// callers make and then fail inside Windows, or land on whatever window
    /// has been given that handle since.
    #[test]
    fn a_destroyed_window_is_never_handed_out() {
        assert_eq!(pick_overlay(20, &[10, 30]), 10);
    }

    #[test]
    fn nothing_remembered_yet_falls_back_to_a_live_window() {
        assert_eq!(pick_overlay(0, &[10, 30]), 10);
    }

    /// No windows at all: `0`, which becomes a null `HWND`. **Null is a
    /// checkable answer and every caller checks it**; a stale handle is not.
    #[test]
    fn no_windows_is_no_window() {
        assert_eq!(pick_overlay(0, &[]), 0);
        assert_eq!(pick_overlay(20, &[]), 0);
    }
}

use crate::strip::strip_h;

/// **This window's** content scale, for turning unscaled sizes into pixels.
///
/// **The window is a parameter now, and that is G7's structural half.** There
/// was one `scale` for the process, so every caller got the DPI of whichever
/// window was measured last. On one screen that is always the right number,
/// which is exactly why it survived: the defect needs two displays of
/// different DPI to show, and the machine this is tested on has one. What can
/// be checked without a second monitor is that the two are separately
/// addressable and that `WM_DPICHANGED` writes only the window it arrived at
/// -- **not** "print both and compare", which on one screen cannot fail.
///
/// 1.0 for a window this does not know: a scale of 1 draws something the
/// right shape at the wrong size, where 0 would divide by zero and a panic
/// would take the process down over a repaint.
pub fn scale_of(frame: HWND) -> f64 {
    window(frame).map(|w| w.scale).unwrap_or(1.0)
}

/// Put the active tab's child window over the client area below the strip,
/// and hide every other one.
/// The area a tab's panes live in: the client area minus the strip.
pub fn content_bounds(frame: HWND, sh: i32) -> Option<TreeRect> {
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return None;
        }
    }
    let w = rc.right - rc.left;
    let h = (rc.bottom - rc.top - sh).max(0);

    // **A layout with no height is not a layout.**
    //
    // The frame was once observed reporting a 160x30 client area for about
    // seven seconds, and every pane created during it was dutifully placed at
    // `160x0` -- `SetWindowPos` reported success each time, because moving a
    // window to zero height is a legal thing to ask for. The panes were
    // invisible and the strip showed three tabs out of seventeen.
    //
    // Refusing here keeps the last good geometry instead of replacing it with
    // a meaningless one, and **says so**: the window rect and the window's
    // state go in the line, because "the client area is wrong" and "our
    // arithmetic is wrong" are two different bugs and this is the input that
    // separates them.
    if h == 0 || w <= 0 {
        let mut wr = RECT::default();
        unsafe {
            let _ = GetWindowRect(frame, &mut wr);
            // **The HWND is in the line too.** Two hypotheses survive for a
            // 160-pixel client area, and they are told apart by identity, not
            // by geometry: either the frame really is that small, or this was
            // handed a window that is not the frame. Printing both the handle
            // we measured and the one the model calls the frame answers that
            // without another round trip.
            //
            // The frame comes from an atomic, not from the lock: this runs
            // inside `layout`'s critical section.
            let expect = crate::frame_hwnd_cached();
            wlogf!(frame, 
                "[layout] refusing: hwnd={:?} (frame={:?}, same={}) client {}x{} (strip {}), \
                 window {}x{} at {},{} zoomed={} iconic={}",
                frame.0,
                expect.0,
                frame.0 == expect.0,
                w,
                rc.bottom - rc.top,
                sh,
                wr.right - wr.left,
                wr.bottom - wr.top,
                wr.left,
                wr.top,
                IsZoomed(frame).as_bool(),
                IsIconic(frame).as_bool()
            );
        }
        return None;
    }

    Some(TreeRect::new(0.0, sh as f64, w as f64, h as f64))
}

/// Place every pane of the active tab where the tree says, and hide the rest.
///
/// **The tree does the geometry, this does the windows.** `Tree::layout` is a
/// pure function over rectangles -- it is what the 42 tests in
/// `windows/split-tree` cover, on whatever machine the port is written on --
/// and nothing below the call knows what a split is. Keeping Win32 out of the
/// algorithm is the whole reason it is a separate crate.
///
/// **The strip's pixels never enter the tree.** It is handed a content rect;
/// `STRIP_H` is added and subtracted here. When the strip becomes a drawn,
/// draggable thing, none of the tree code changes.
pub fn layout(frame: HWND) {
    // Pure work under the lock, Windows calls after it: `SetWindowPos` sends
    // WM_SIZE back into this thread, which takes the same lock.
    #[allow(clippy::type_complexity)]
    let (place, hide, orphans): (
        Vec<(PaneId, HWND, TreeRect)>,
        Vec<(PaneId, HWND)>,
        Vec<PaneId>,
    ) = {
        let mut orphans: Vec<PaneId> = Vec::new();
        let Some(win) = window(frame) else {
            return;
        };
        let sh = strip_h(win.scale);
        let Some(bounds) = content_bounds(frame, sh) else {
            return;
        };
        let mut place = Vec::new();
        let mut hide = Vec::new();
        // **This window's tabs, not every tab in the process.** While there
        // was one window the two were the same list, and iterating all of
        // them was correct by accident. With two, the accident becomes a
        // window-move call on the *other* window's panes -- laying window 1's
        // terminal out inside window 2's client rectangle.
        //
        // (The move call is deliberately not named here. This block is inside
        // the state guard, and `borrow-across-dispatch.py` matches the
        // names of dispatching calls against the guard's whole scope as raw
        // text -- so writing one in a comment reports a deadlock that is not
        // there. Worth knowing before wording the next comment in a critical
        // section.)
        for (i, tab) in win.tabs.iter().enumerate() {
            if i != win.active {
                hide.extend(tab.panes.iter().map(|p| (p.id, HWND(p.hwnd as *mut c_void))));
                continue;
            }
            let laid = tab.tree.layout(bounds);
            for p in tab.panes.iter() {
                let hw = HWND(p.hwnd as *mut c_void);
                match laid.iter().find(|(id, _)| *id == p.id) {
                    Some((_, Placement::Visible(r))) => place.push((p.id, hw, *r)),
                    Some((_, Placement::Hidden)) => hide.push((p.id, hw)),

                    // **Absent is not the same as hidden**, and the previous
                    // version could not tell them apart: it read every miss as
                    // "a zoom is covering this" and hid it. A pane the tree
                    // does not know about is not covered, it is a disagreement
                    // between `panes` and `tree` -- and `close_pane` removes
                    // from both together, so reaching here means they drifted.
                    //
                    // Hidden anyway, so a stale window does not sit on screen,
                    // but never silently: the old behaviour made this
                    // indistinguishable from normal zoom.
                    //
                    // **Destruction deliberately does not happen here.**
                    // `close_pane` owns it, this loop runs under `STATE`, and
                    // `ghostty_surface_free` is precisely the call that must
                    // not be made from inside a layout pass.
                    None => {
                        orphans.push(p.id);
                        hide.push((p.id, hw));
                    }
                }
            }
        }
        (place, hide, orphans)
    };

    for id in orphans {
        logf!(
            "[layout] BUG pane {} is in tabs.panes but not in the tree; hidden, not destroyed",
            id
        );
    }

    // **Every window call here is logged with its pane and its result.**
    // The previous version logged only that a `WM_SIZE` had happened, with no
    // pane in the line -- and when two panes disagreed about their size, that
    // log could not say which one had been moved and which had been skipped.
    // A layout is a decision per pane; the log is now one line per decision.
    let n = LAYOUTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
    let verbose = n <= 40;
    unsafe {
        // Hide before showing, so a zoom toggle does not flash both.
        //
        // # Hiding a *visible* pane ends any composition it is carrying
        //
        // TSF ends the composition synchronously inside `ShowWindow`, and the
        // handler in `tsf.rs` would then commit the half-typed text into the
        // terminal -- so pressing a keybinding while composing opened the tab
        // **and** typed the syllable. `with_host_shuffle` marks this window so
        // that ending is discarded instead.
        //
        // **The trigger is hiding, not opening a tab.** Two earlier attempts
        // guarded the focus change further down this function, and both missed
        // it: the composition was already over 38ms before that ran. Anything
        // that rearranges panes reaches this loop -- splitting, zooming,
        // closing a tab -- so guarding the loop covers them all, while
        // guarding the caller covers one.
        //
        // # What is actually known, and what was believed for one afternoon
        //
        // The log line below carries `ShowWindow`'s return value, which is
        // exactly "was it visible", and one real run put the two cases side by
        // side inside a single layout pass:
        //
        // ```text
        // [layout #6] pane 1 -> hide (was visible: false)
        // [ime] OnEndComposition commit="ni"
        // [layout #6] pane 3 -> hide (was visible: true)
        // ```
        //
        // That reads as "hiding a *visible* pane is what ends it", and it was
        // written down here as exactly that. **It is not true.** Splitting a
        // pane mid-composition ends the composition too, and in that run
        // **both** hidden panes reported `was visible: false`.
        //
        // So the honest statement is narrower than the one that fits:
        //
        //   * the composition ends somewhere inside this loop -- measured, in
        //     two different runs;
        //   * *which* `ShowWindow` does it, and on what condition, **is not
        //     known**. Visibility was the first hypothesis and it is refuted.
        //
        // **This guard therefore works by covering the whole loop, not by
        // knowing the trigger.** That is a real difference and it has a
        // consequence for whoever edits this function: the floor that proves
        // the guard is not simply always-on (`H5`: type a word normally and
        // watch it commit) **belongs to this code, not to the guard**. Move a
        // `ShowWindow` out of this loop, or add a path around it, and that
        // floor has to be run again -- the guard cannot tell you it stopped
        // covering something.
        //
        // The open question is recorded in `docs/windows/status.md`; it is a
        // debt, not a blocker, because the wide guard is safe.
        crate::with_host_shuffle(|| {
            for (id, hw) in hide {
                let ok = ShowWindow(hw, SW_HIDE).as_bool();
                if verbose {
                    logf!("[layout #{}] pane {} -> hide (was visible: {})", n, id, ok);
                }
            }
        });
        for (id, hw, r) in place {
            let res = SetWindowPos(
                hw,
                None,
                r.x as i32,
                r.y as i32,
                (r.w as i32).max(1),
                (r.h as i32).max(1),
                SWP_NOZORDER | SWP_SHOWWINDOW,
            );
            if verbose {
                logf!(
                    "[layout #{}] pane {} -> {}x{}+{}+{} ({})",
                    n,
                    id,
                    r.w as i32,
                    r.h as i32,
                    r.x as i32,
                    r.y as i32,
                    if res.is_ok() { "ok" } else { "SetWindowPos FAILED" }
                );
            }
        }
        let _ = InvalidateRect(Some(frame), None, false);
    }

    // **The dividers follow the panes, from here and nowhere else.**
    //
    // This was originally hooked to the frame's `WM_SIZE`, which is one of
    // ten call sites of this function -- and not one of the ones that matter:
    // splitting, closing and zooming all change the layout without changing
    // the frame's size, so a split produced panes with no divider between
    // them. Putting it at the end of the one function every layout change
    // goes through is the structure; hooking each caller was a rule, and nine
    // callers did not know about it.
    //
    // Safe here specifically because the `STATE` guard above has already been
    // dropped: `sync` takes that lock itself.
    crate::divider::sync(frame);
}

/// Create one pane: a child window at the rectangle the tree gave it, plus
/// the surface bound to that window.
///
/// **The window is created at its final size and shown before
/// `ghostty_surface_new`.** That is not tidiness: the renderer sizes itself
/// from `GetClientRect` of this HWND inside `surface_new`, and a surface built
/// on a placeholder-sized window renders black with no error anywhere. See
/// docs/windows/development.md section 5.2, item 4.
#[allow(clippy::too_many_arguments)]
fn create_pane(
    frame: HWND,
    app: App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    id: PaneId,
    r: TreeRect,
    spec: NewTab,
) -> Option<Pane> {
    let scale = scale_of(frame);
    let (x, y) = (r.x as i32, r.y as i32);
    let (w, h) = ((r.w as i32).max(1), (r.h as i32).max(1));

    let child = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterSurface"),
            PCWSTR::null(),
            WS_CHILD | WS_CLIPSIBLINGS | WS_VISIBLE,
            x,
            y,
            w,
            h,
            Some(frame),
            None,
            Some(hinst),
            None,
        )
    };
    let child = match child {
        Ok(c) => c,
        Err(e) => {
            logf!("[pane] CreateWindowExW failed: {:?}", e);
            return None;
        }
    };
    logf!("[pane] {} hwnd = {:?} at {}x{}+{}+{}", id, child.0, w, h, x, y);

    let mut sc: SurfaceConfig = unsafe { (api().surface_config_new)() };
    sc.platform_tag = PLATFORM_WIN32;
    sc.platform_hwnd = child.0 as *mut c_void;
    sc.scale_factor = scale;
    // The surface carries its own pane id: `close_surface_cb` is handed this
    // back and nothing else, so without it a shell exiting in one pane could
    // only be answered by guessing which pane it was.
    sc.userdata = id as *mut c_void;

    // Taken, not borrowed: only the first pane gets it, and the CString has
    // to outlive `surface_new`, which is what this binding is for.
    let initial_input = shared().initial_input.take();
    if let Some(cmd) = &initial_input {
        sc.initial_input = cmd.as_ptr();
    }
    // Same lifetime rule as `initial_input`: the core reads the pointer
    // during `surface_new`, so the CString has to outlive that call.
    let cwd_c = match spec.cwd {
        None => None,
        Some(c) => match std::ffi::CString::new(c.clone()) {
            Ok(c) => Some(c),
            Err(_) => {
                // An interior NUL. Said out loud, because the alternative is a
                // shell that starts somewhere else for a reason nothing records.
                logf!("[pane] {} cwd {:?} has an interior NUL; using the default directory", id, c);
                None
            }
        },
    };
    // **Written where the pointer is set.** This is what the restore line
    // reports, so that line cannot say `cwd=X` while the surface got nothing.
    if let Some(mut w) = window(frame) {
        w.last_pane_cwd = cwd_c.as_ref().map(|c| c.to_string_lossy().to_string());
    }
    if let Some(c) = &cwd_c {
        sc.working_directory = c.as_ptr();
        logf!("[pane] {} starting in {:?}", id, c);
    }
    // **Same lifetime rule as `working_directory` and `initial_input`**: the
    // core reads the pointer during `surface_new`, so the `CString` has to
    // outlive that call. Declared here, not inside the `if`, for exactly that.
    let command_c = match &spec.command {
        None => None,
        Some(c) => match std::ffi::CString::new(c.clone()) {
            Ok(c) => Some(c),
            Err(_) => {
                // Refused rather than dropped: a chat surface that silently
                // starts a plain shell looks like a chat window that does not
                // answer, and nothing would say which of the two it was.
                logf!("[pane] {} command {:?} has an interior NUL; not starting it", id, c);
                return None;
            }
        },
    };
    if let Some(c) = &command_c {
        sc.command = c.as_ptr();
    }
    // A bool, so no lifetime question -- but it is the whole of what makes
    // this surface a chat surface, so it is logged with the command.
    sc.poltergeist_chat = spec.chat;
    if spec.chat || command_c.is_some() {
        logf!(
            "[pane] {} command={:?} poltergeist_chat={}",
            id,
            spec.command.as_deref().unwrap_or(""),
            spec.chat
        );
    }

    let s = unsafe { (api().surface_new)(app, &sc) };
    if s.is_null() {
        logf!("[pane] ghostty_surface_new returned null -- destroying the window");
        unsafe {
            let _ = DestroyWindow(child);
        }
        return None;
    }
    // **The other half of the pair `[mouse] divisor=` is compared against.**
    // These two numbers come from the same expression at two different
    // moments; if they ever differ, the round trip through the core does not
    // cancel and a pointer lands somewhere a person did not point.
    logf!("[pane] {} content_scale={} (told to the core at creation)", id, scale);
    unsafe {
        (api().surface_set_content_scale)(s, scale, scale);
        (api().surface_set_size)(s, w as u32, h as u32);
        (api().surface_set_focus)(s, true);
    }
    // A window TSF has never seen has no document until it is told, and the
    // failure is silent: the IME looks switched on and nothing composes.
    crate::ime_attach(child);
    // Dropped files land on a pane, so the drop target is registered per
    // pane, the same as the IME document above. `quick.rs` does this for its
    // own surface already; the tabs' panes were the ones nobody had wired.
    crate::dnd::attach(child);
    logf!("[pane] {} surface = {:?}", id, s);

    Some(Pane {
        id,
        hwnd: child.0 as isize,
        surface: s as usize,
    })
}

/// The next identity. Shared by panes and tabs; see `TabId`.
fn take_id() -> u64 {
    let mut st = shared();
    let id = st.next_id;
    st.next_id += 1;
    id
}

/// Create one tab: a tree with a single pane in it.
///
/// Returns false and logs if either half fails. The caller keeps running --
/// a tab that could not be made is not a reason to lose the ones that exist.
pub fn create_tab(frame: HWND, app: App, hinst: windows::Win32::Foundation::HINSTANCE) -> bool {
    create_tab_in(frame, app, hinst, None)
}

/// What a new tab's surface should be, beyond the defaults.
///
/// **A value rather than three more parameters.** `cwd` and `command` are both
/// `Option<String>` and would sit next to each other in the argument list,
/// where swapping them compiles and produces a shell started in a directory
/// named `polter +chat`. Named fields cannot be swapped silently, and the
/// callers that want none of it say `NewTab::default()`.
#[derive(Clone, Default, Debug)]
pub struct NewTab {
    /// Where the shell starts. Only a reopened tab passes one.
    pub cwd: Option<String>,
    /// What to run instead of the configured shell. `polter +chat` for the
    /// chat surface; nothing else uses it yet.
    pub command: Option<String>,
    /// **What makes a chat surface different from any other terminal**: it
    /// tells the core that requests from this surface speak for the person at
    /// the keyboard (`embedded.zig:684`). Set where we know why the surface is
    /// being opened, and nowhere else -- the same rule `Ghostty.App.swift`'s
    /// `openChat` states.
    pub chat: bool,
}

/// A new tab whose shell starts in `cwd`. `create_tab` is this with `None`.
pub fn create_tab_in(
    frame: HWND,
    app: App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    cwd: Option<String>,
) -> bool {
    create_tab_with(frame, app, hinst, NewTab { cwd, ..Default::default() })
}

pub fn create_tab_with(
    frame: HWND,
    app: App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    spec: NewTab,
) -> bool {
    let sh = strip_h(scale_of(frame));
    let Some(bounds) = content_bounds(frame, sh) else {
        wlogf!(frame, "[tab] no client area yet; not creating a tab");
        return false;
    };
    // **Both identities are taken before the guard is.** `take_id` locks, so
    // calling it inside the block below re-enters a non-re-entrant mutex --
    // and it is easy to miss there because it is not a statement, it is one
    // field's initialiser inside a struct literal. That is exactly what
    // deadlocked the host on startup: a lock taken *inside a value being
    // constructed* while the guard for that value's destination was held.
    let id = take_id();
    let tab_id = TabId(take_id());
    let Some(pane) = create_pane(frame, app, hinst, id, bounds, spec) else {
        return false;
    };
    // **Read before the tab exists, because the core reports it before the
    // tab exists.** `pwd` can arrive during `surface_new`, which runs inside
    // `create_pane` above -- at which point there is no `Tab` to write it to.
    let pane_surface = pane.surface;
    // **Taken before the guard, and the comment eight lines up says why.**
    // `take_pending_cwd` locks. Written as a field initialiser inside the
    // struct literal below -- which is where it was, and which deadlocked the
    // host on startup with no window ever appearing -- it is evaluated *after*
    // that literal's destination has already taken the same non-re-entrant
    // lock. The shape is invisible at the call site: it reads as fetching a
    // value, not as acquiring anything.
    //
    // This is the same paragraph that was already written above for `take_id`,
    // about the same struct literal. Rewriting it rather than pointing at it,
    // because the first copy did not stop the second instance.
    let pending_cwd = take_pending_cwd(pane_surface);
    {
        // **The tab goes into the window it was asked for.** Nothing else
        // here changed when windows became plural; this line is the whole of
        // where a new tab decides which strip it appears on.
        let Some(mut win) = window(frame) else {
            wlogf!(frame, "[tab] created a pane for a window that is not tracked; dropping it");
            return false;
        };
        win.tabs.push(Tab {
            id: tab_id,
            tree: Tree::with_pane(id),
            panes: vec![pane],
            focused: id,
            title: "shell".to_string(),
            color: 0,
            role: 0,
            shielded: false,
            cwd: pending_cwd,
            title_override: None,
        });
        win.active = win.tabs.len() - 1;
    }
    layout(frame);
    focus_active(frame);
    wlogf!(frame, "[tab] created; count now {}", count(frame));
    // **After the guard above is gone, and that is load-bearing.** Raising a
    // UIA event can call straight back into `uia.rs`, which takes this
    // module's lock -- and taking it twice on one thread hangs rather than
    // panics. See the rule at the head of `uia.rs`'s events section;
    // `borrow-across-dispatch.py` enforces it.
    crate::uia::tabs_changed(frame);
    true
}

/// Split the focused pane of the active tab.
///
/// The new tree is computed **before** the window exists, because that is
/// what says how big the new pane is -- and a pane has to be created at its
/// final size (see `create_pane`).
fn split_focused(
    frame: HWND,
    app: App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    dir: NewSplit,
) {
    let (bounds, focused, tree) = {
        let Some(win) = window(frame) else {
            return;
        };
        let sh = strip_h(win.scale);
        let Some(bounds) = content_bounds(frame, sh) else {
            return;
        };
        let Some(tab) = win.tabs.get(win.active) else {
            return;
        };
        (bounds, tab.focused, tab.tree.clone())
    };

    let id = take_id();
    let new_tree = match tree.insert(id, focused, dir) {
        Ok(t) => t,
        Err(e) => {
            wlogf!(frame, "[split] insert failed: {:?}", e);
            return;
        }
    };
    // Only `Visible` is acceptable for a pane being created: a brand new pane
    // that the tree reports as `Hidden` would be a tree bug, and building a
    // window for it would hide that bug behind an invisible window.
    let Some((_, Placement::Visible(r))) =
        new_tree.layout(bounds).into_iter().find(|(p, _)| *p == id)
    else {
        wlogf!(frame, "[split] the new pane is not in the layout; refusing to create it");
        return;
    };

    let Some(pane) = create_pane(frame, app, hinst, id, r, NewTab::default()) else {
        return;
    };
    {
        if let Some(mut win) = window(frame) {
            let a = win.active;
            if let Some(tab) = win.tabs.get_mut(a) {
                tab.tree = new_tree;
                tab.panes.push(pane);
                tab.focused = id;
            }
        }
    }
    layout(frame);
    focus_active(frame);
    logf!("[split] {:?} -> pane {}; {} panes in this tab", dir, id, pane_count(frame));
}

/// Close one pane. The tab goes with it when it was the last one.
fn close_pane(frame: HWND, id: PaneId) {
    let (hwnd, surface, tab_empty, tab_idx) = {
        let Some(mut win) = window(frame) else {
            return;
        };
        let Some((idx, _)) = win
            .tabs
            .iter()
            .enumerate()
            .find(|(_, t)| t.pane(id).is_some())
        else {
            return;
        };
        let tab = &mut win.tabs[idx];
        let Some(pos) = tab.panes.iter().position(|p| p.id == id) else {
            return;
        };
        let pane = tab.panes.remove(pos);
        tab.tree = tab.tree.remove(id);
        if tab.focused == id {
            // Focus whatever leaf the tree still has; tree order is as good a
            // choice as any and is at least deterministic.
            tab.focused = tab.tree.panes().first().copied().unwrap_or(0);
        }
        let empty = tab.panes.is_empty();
        (pane.hwnd, pane.surface, empty, idx)
    };

    free_pane(id, hwnd, surface);
    logf!("[pane] {} closed", id);

    if tab_empty {
        destroy_tab_at(frame, tab_idx);
        if count(frame) == 0 {
            wlogf!(frame, "[tab] last tab closed");
            // Through the one point, so every route leaves the same record the
            // window's own X does -- and it **destroys** the window, which the
            // direct `window_finished` call that used to be here never did: it
            // recorded the window as finished and left it on the screen. See
            // `winid::close_window_now`.
            crate::winid::close_window_now(frame);
            return;
        }
        set_active(frame, active_index(frame));
        return;
    }
    layout(frame);
    focus_active(frame);
}

/// Close every tab in a window, on the way to closing the window itself.
///
/// **Nothing did this before, and with one window nothing needed to.** The
/// window's X went straight to `DefWindowProc`, Windows destroyed the frame
/// and its children, and the process exited a moment later -- so the surfaces
/// were never freed and it never showed. Close the second of two windows and
/// the same code leaks a surface per tab: `ghostty_surface_free` is what
/// joins the core's io and renderer threads and tears the ConPTY down, and
/// the shells in that window would carry on running with no window attached.
///
/// **Back to front**, so each removal is from the end and no index shifts
/// under the loop.
pub fn close_all_tabs_of(frame: HWND) {
    let n = count(frame);
    if n == 0 {
        return;
    }
    wlogf!(frame, "[tab] closing {} tab(s) with the window", n);
    for i in (0..n).rev() {
        destroy_tab_at(frame, i);
    }
}

/// What the strip needs to draw itself: identity and label, in order, plus
/// which one is active.
///
/// **A snapshot, taken per paint, never cached.** The moment the strip keeps
/// its own `Vec` of labels there are two orderings that can disagree, and the
/// symptom is tabs whose order is right and whose contents are not.
///
/// **Takes the window it is drawing.** The strip paints from a frame's
/// `WM_PAINT`, so it always knew which window it was; it just had nowhere to
/// say so, and the one tab list answered every frame. Two windows sharing one
/// snapshot is E3's failure exactly: an action in window 2 changes what
/// window 1 draws.
pub fn strip_snapshot(frame: HWND) -> (Vec<(TabId, String)>, usize) {
    match window(frame) {
        Some(w) => (
            w.tabs.iter().map(|t| (t.id, t.title.clone())).collect(),
            w.active,
        ),
        None => (Vec::new(), 0),
    }
}

/// Make a tab active by identity.
pub fn activate_tab(frame: HWND, id: TabId) {
    let idx = {
        window(frame).and_then(|w| w.tabs.iter().position(|t| t.id == id))
    };
    if let Some(idx) = idx {
        set_active(frame, idx);
    }
}

/// Close a tab by identity, with every pane in it.
pub fn close_tab(frame: HWND, id: TabId) {
    let idx = {
        window(frame).and_then(|w| w.tabs.iter().position(|t| t.id == id))
    };
    let Some(idx) = idx else { return };
    destroy_tab_at(frame, idx);
    if count(frame) == 0 {
        wlogf!(frame, "[tab] last tab closed");
        // Through the one point, so every route leaves the same record the
        // window's own X does -- and it **destroys** the window, which the
        // direct `window_finished` call that used to be here never did: it
        // recorded the window as finished and left it on the screen. See
        // `winid::close_window_now`.
        crate::winid::close_window_now(frame);
        return;
    }
    set_active(frame, active_index(frame));
}

/// Where a tab sits right now, and how many there are.
///
/// **Resolved at the moment it is asked, never cached.** Everything that
/// prints "tab 3 of 5" goes through here, including the line printed at the
/// point an action actually runs -- that line is the only external evidence
/// that the identity travelled the whole way instead of degenerating into
/// "the current one" somewhere in the middle.
pub fn index_of(frame: HWND, id: TabId) -> Option<(usize, usize)> {
    let win = window(frame)?;
    let n = win.tabs.len();
    win.tabs.iter().position(|t| t.id == id).map(|i| (i, n))
}

/// The surface of the focused pane of **a named tab** -- not the active one.
///
/// `active_surface` is the right answer for "where typing goes" and the wrong
/// answer for everything a context menu does, because the tab that was
/// right-clicked is usually not the tab that has focus.
pub fn surface_of_tab(frame: HWND, id: TabId) -> Surface {
    let found = window(frame).and_then(|w| {
        w.tabs
            .iter()
            .find(|t| t.id == id)
            .and_then(|t| t.focused_pane())
            .map(|p| p.surface)
    });
    match found {
        Some(surface) => surface as Surface,
        None => std::ptr::null_mut(),
    }
}

/// One tab, as the UIA provider needs to see it: identity first, then the
/// things that are only true right now.
///
/// **Every field is owned, and the lock is not held when this is returned.**
/// That is the point of the type rather than a convenience: `uia.rs` must
/// call into libghostty to read the screen, and libghostty takes the core's
/// renderer lock -- so the registry lock has to be gone by then. See the lock
/// rule at the top of `uia.rs`.
pub struct TabInfo {
    pub id: TabId,
    pub title: String,
    /// The tab's focused pane. **Carried so the provider can name a pane by
    /// identity** rather than holding a `Surface` pointer across calls: a
    /// pane can be closed between one UIA call and the next, and a stale
    /// `Surface` is the one mistake here that is not recoverable.
    pub pane: PaneId,
    /// That pane's window. **Carried in the same snapshot as the id, not
    /// looked up afterwards**: two lookups a moment apart can straddle a
    /// pane being closed, and the pair would then describe two different
    /// panes while looking like one.
    pub pane_hwnd: isize,
}

/// Every tab of one window, and which of them is active.
///
/// The twin of `strip_snapshot`, which the strip uses to paint. Kept
/// separate rather than widened because the strip's version is called on
/// every `WM_PAINT` and has no business growing a field for a caller that
/// runs when a screen reader asks.
pub fn tab_infos(frame: HWND) -> (Vec<TabInfo>, usize) {
    match window(frame) {
        Some(w) => (
            w.tabs
                .iter()
                .map(|t| TabInfo {
                    id: t.id,
                    // The name the user gave wins over the one the program
                    // announced -- the same precedence the strip paints with.
                    title: t.title_override.clone().unwrap_or_else(|| t.title.clone()),
                    pane: t.focused,
                    pane_hwnd: t
                        .panes
                        .iter()
                        .find(|p| p.id == t.focused)
                        .map(|p| p.hwnd)
                        .unwrap_or(0),
                })
                .collect(),
            w.active,
        ),
        None => (Vec::new(), 0),
    }
}

/// Resolve a `(frame, tab, pane)` triple to a live surface, or null.
///
/// **All three have to still agree**, which is what makes this different
/// from `surface_of_pane`: a pane id is unique in the process, so looking it
/// up alone would happily answer for a pane that has since been moved into
/// another window -- and the UIA provider would then read window 2's
/// terminal while claiming to be window 1's. Checking the whole triple is
/// how "this element is gone" stays distinguishable from "this element now
/// means something else".
///
/// A null return is the provider's cue to answer `UIA_E_ELEMENTNOTAVAILABLE`.
/// **Not an empty string**: a terminal that has been closed and a terminal
/// showing nothing are different facts, and a screen reader that is told the
/// second one will sit reading a blank document that no longer exists.
pub fn surface_of_tab_pane(frame: HWND, tab: TabId, pane: PaneId) -> Surface {
    let found = window(frame).and_then(|w| {
        w.tabs
            .iter()
            .find(|t| t.id == tab)
            .and_then(|t| t.panes.iter().find(|p| p.id == pane))
            .map(|p| p.surface)
    });
    match found {
        Some(surface) => surface as Surface,
        None => std::ptr::null_mut(),
    }
}

/// Send a core binding action to a **named tab's** surface.
///
/// The twin of `crate::binding`, which sends to whichever surface has focus.
/// A menu that was opened on tab 3 and dispatches through `crate::binding`
/// acts on tab 1, silently, and looks entirely correct while doing it.
pub fn binding_on_tab(frame: HWND, id: TabId, name: &str) -> bool {
    let s = surface_of_tab(frame, id);
    if s.is_null() {
        return false;
    }
    unsafe { (api().surface_binding_action)(s, name.as_ptr(), name.len()) }
}

/// Close every tab except one, **named by identity**.
///
/// **Not `Op::CloseTab(CLOSE_TAB_OTHER)`.** That branch is the core's action
/// and resolves against `active_index()`, which is exactly right for the
/// keyboard binding and exactly wrong for a menu opened on a tab that does
/// not have focus. The two are different operations that happen to share a
/// name, so they are different functions.
pub fn close_other_tabs(frame: HWND, id: TabId) {
    let victims: Vec<usize> = {
        let Some(win) = window(frame) else { return };
        let keep = win.tabs.iter().position(|t| t.id == id);
        match keep {
            None => return,
            Some(keep) => (0..win.tabs.len()).rev().filter(|i| *i != keep).collect(),
        }
    };
    for i in victims {
        destroy_tab_at(frame, i);
    }
    set_active(frame, 0);
    logf!("[tab] closed all but {:?}; count now {}", id, count(frame));
}

/// Close every tab to the right of one, **named by identity**. Same reason.
pub fn close_tabs_right_of(frame: HWND, id: TabId) {
    let victims: Vec<usize> = {
        let Some(win) = window(frame) else { return };
        match win.tabs.iter().position(|t| t.id == id) {
            None => return,
            Some(at) => (at + 1..win.tabs.len()).rev().collect(),
        }
    };
    let n = victims.len();
    for i in victims {
        destroy_tab_at(frame, i);
    }
    set_active(frame, active_index(frame).min(count(frame).saturating_sub(1)));
    logf!("[tab] closed {} tabs right of {:?}; count now {}", n, id, count(frame));
}

/// Record the working directory the core reported for a surface.
///
/// **Keyed on the surface the action was targeted at, never on the active
/// tab.** A background tab's shell changes directory as freely as the focused
/// one; writing every `pwd` onto whichever tab is in front would quietly give
/// tab A's directory to tab B, and the only place it would ever show is a
/// reopened tab landing somewhere the user never was.
// window-free: keyed by surface, which is unique in the process
pub fn set_cwd_for_surface(surface: Surface, cwd: String) -> bool {
    let key = surface as usize;
    // **Every window, because a surface names itself.** The lookup key is
    // globally unique, so searching all windows is not a widening of scope --
    // it is the same question asked where the answer can now be.
    let landed = with_windows_mut(|ws| {
        for win in ws.iter_mut() {
            for tab in win.tabs.iter_mut() {
                if tab.panes.iter().any(|p| p.surface == key) {
                    tab.cwd = Some(cwd.clone());
                    return true;
                }
            }
        }
        false
    });
    if landed {
        return true;
    }
    // No tab yet: it is still being built. Held until `create_tab` collects it.
    let mut st = shared();
    st.pending_cwd.retain(|(s, _)| *s != key);
    st.pending_cwd.push((key, cwd));
    false
}

/// Take whatever `pwd` arrived for a surface before its tab existed.
fn take_pending_cwd(surface: usize) -> Option<String> {
    let mut st = shared();
    let at = st.pending_cwd.iter().position(|(s, _)| *s == surface)?;
    Some(st.pending_cwd.remove(at).1)
}

/// Teach `reopen.rs` how to build a tab. Called once, at startup.
///
/// **The stack is `reopen.rs`'s and tab creation is this file's**, and this
/// is the one line where they meet. The first version of this kept a second
/// stack here -- the same fact stored twice, and the two already disagreed
/// about the bound (20 there, 10 here) before either had run once.
pub fn install_reopen_opener() {
    crate::reopen::set_opener(|frame, e| {
        post_op(
            frame,
            Op::ReopenTab {
                cwd: e.cwd.clone(),
                title: e.chosen_title.clone(),
                index: e.index,
            },
            "reopen stack",
        );
        true
    });
}

/// Every tab's colour, by identity, in one lock.
///
/// **By identity, not a `Vec<u8>` in strip order.** A vector indexed by
/// position is the parallel array this file's rule 1 exists to forbid, and
/// the bug it writes -- colours right, order wrong -- is invisible until two
/// tabs happen to be different colours.
pub fn tab_colors(frame: HWND) -> Vec<(TabId, u8)> {
    match window(frame) {
        Some(w) => w.tabs.iter().map(|t| (t.id, t.color)).collect(),
        None => Vec::new(),
    }
}

/// A tab's colour, and how to set it. 0 is "none".
pub fn tab_color(frame: HWND, id: TabId) -> u8 {
    window(frame)
        .and_then(|w| w.tabs.iter().find(|t| t.id == id).map(|t| t.color))
        .unwrap_or(0)
}

pub fn set_tab_color(frame: HWND, id: TabId, color: u8) -> bool {
    let found = match window(frame) {
        Some(mut w) => match w.tabs.iter_mut().find(|t| t.id == id) {
            Some(tab) => {
                tab.color = color;
                true
            }
            None => false,
        },
        None => false,
    };
    if found {
        unsafe {
            let _ = InvalidateRect(Some(frame), None, false);
        }
    }
    found
}

/// What Poltergeist has made of a tab: `(role, shielded)`.
pub fn tab_mark(frame: HWND, id: TabId) -> (u8, bool) {
    window(frame)
        .and_then(|w| w.tabs.iter().find(|t| t.id == id).map(|t| (t.role, t.shielded)))
        .unwrap_or((0, false))
}

/// What Poltergeist has made of the terminal in a **particular surface**.
///
/// Exported so that nothing else has to keep its own copy of this. The mark
/// arrives once, as an action, and every consumer that cached it separately
/// would be a second place for it to be right -- which is the shape that has
/// gone wrong four times tonight (the menu's target, the close batch, the
/// mark's landing tab, and the button width), each time by two stores of one
/// fact drifting apart with nothing to report it.
// window-free: keyed by surface, which is unique in the process
pub fn mark_for_surface(surface: Surface) -> Option<(u8, bool)> {
    let key = surface as usize;
    // Every window: a surface is unique in the process, so the window it is
    // in is an answer rather than a parameter.
    with_windows(|ws| {
        ws.iter()
            .flat_map(|w| w.tabs.iter())
            .find(|t| t.panes.iter().any(|p| p.surface == key))
            .map(|t| (t.role, t.shielded))
    })
}

/// Record a `poltergeist_mark` against **the surface it was sent for**.
///
/// **The surface, not the active tab.** `set_tab_title` and its neighbours
/// queue an `Op` that lands on whichever tab is active when the queue runs,
/// which is right for a title the focused shell just set and wrong here: a
/// mark can be made on a tab that is not in front (from this very menu, or
/// from a supervisor elsewhere), and applying it to the active tab would put
/// the tick on the wrong row while looking completely normal.
// window-free: keyed by surface, which is unique in the process
pub fn set_mark_for_surface(surface: Surface, role: u8, shielded: bool) -> bool {
    let key = surface as usize;
    with_windows_mut(|ws| {
        for win in ws.iter_mut() {
            for tab in win.tabs.iter_mut() {
                if tab.panes.iter().any(|p| p.surface == key) {
                    tab.role = role;
                    tab.shielded = shielded;
                    return true;
                }
            }
        }
        false
    })
}

/// Rename a tab **because the user said so** -- the in-place editor, the tab
/// menu's rename, or a restored name.
///
/// **This outranks the program's own title from here on.** The comment that
/// used to sit here said the opposite ("the shell can still overwrite it,
/// which is the same rule macOS follows"), and that sentence was wrong about
/// macOS: `BaseTerminalController` says of `titleOverride`, "When set, this
/// takes precedence over the computed title from the terminal." The host was
/// built to a mis-stated rule, which is why a renamed tab lost its name at the
/// next `cd`.
pub fn rename_tab(frame: HWND, id: TabId, title: String) {
    // **Whether the rename actually landed**, taken inside the block and read
    // outside it. Announcing a name that was never stored -- because the tab
    // had gone -- would tell a client to re-read a property that has not
    // changed, which is a smaller lie than the alternative but still a lie.
    let renamed = {
        if let Some(mut w) = window(frame) {
            match w.tabs.iter_mut().find(|t| t.id == id) {
                Some(tab) => {
                    tab.title = title.clone();
                    tab.title_override = Some(title.clone());
                    true
                }
                None => false,
            }
        } else {
            false
        }
    };
    unsafe {
        let _ = InvalidateRect(Some(frame), None, false);
    }
    // Outside the block, same rule as the other four.
    if renamed {
        crate::uia::tab_renamed(frame, id, &title);
    }
}

/// The program inside a tab announced its own title (`OSC 0` / `OSC 2`).
///
/// **Ignored while the user has given the tab a name of their own.** Every
/// `cd` in a shell sends one of these, so without the guard a name the user
/// typed survives until their next command.
/// What happened to a title a program announced.
///
/// **Both outcomes carry the window as well as the index**, because a title
/// arrives named by its surface and a surface can be in any window. The
/// caller draining the queue knows which window *it* is; it does not know
/// which window the title landed in, and a line that assumed they were the
/// same would report window 2's rename as window 1's -- exactly the class of
/// unreadable-but-green line the tag exists to prevent.
pub enum ShellTitle {
    /// `(frame, index in that window, how many tabs that window has)`
    Applied(isize, usize, usize),
    /// The user named this tab; the program does not get to rename it.
    Overridden(isize, usize, usize),
    /// No tab owns that surface. **Distinct from the other two on purpose**:
    /// "the title went to the wrong tab" and "the title went nowhere" are
    /// different failures and used to produce the same silence.
    NoSuchSurface,
}

// window-free: keyed by surface; it reports which window it landed in
fn set_shell_title(surface: usize, title: String) -> ShellTitle {
    // Which window, then which tab in it. Searched rather than assumed: the
    // surface is the only thing the action carried.
    with_windows_mut(|ws| {
        let found = ws.iter().enumerate().find_map(|(wi, w)| {
            w.tabs
                .iter()
                .position(|t| t.panes.iter().any(|p| p.surface == surface))
                .map(|ti| (wi, ti))
        });
        let Some((wi, idx)) = found else {
            return ShellTitle::NoSuchSurface;
        };
        let win = &mut ws[wi];
        let (owner, n) = (win.frame, win.tabs.len());
        let tab = &mut win.tabs[idx];
        if tab.title_override.is_some() {
            return ShellTitle::Overridden(owner, idx, n);
        }
        tab.title = title;
        ShellTitle::Applied(owner, idx, n)
    })
}


/// Move one tab to a position, **by identity**.
///
/// This is the primitive; the core's relative `move_tab` action resolves into
/// it. Dragging a tab will call it directly -- a drag is a state machine that
/// spans dozens of frames (`WM_LBUTTONDOWN` -> many `WM_MOUSEMOVE` ->
/// `WM_LBUTTONUP`) and any frame in between can reorder, so the thing being
/// dragged needs a name that an intervening reorder cannot invalidate. It
/// needs no queued `Op`: mouse messages already arrive on the thread that
/// owns the windows.
///
/// **The whole `Tab` moves**, and a `Tab` owns its tree, its panes and its
/// title -- there is no second array keyed by position for them to fall out
/// of step with. That is what makes "the order is right but the contents are
/// wrong" not expressible here: it is a bug of parallel arrays, and there are
/// none. The acceptance check for it (three tabs, move the first to third,
/// the contents follow) therefore tests the model, not this function.
pub fn move_tab_to(frame: HWND, id: TabId, to: usize) {
    let moved = {
        let Some(mut win) = window(frame) else { return };
        let Some(from) = win.tabs.iter().position(|t| t.id == id) else {
            logf!("[tab] move: {:?} no longer exists", id);
            return;
        };
        let n = win.tabs.len();
        if n < 2 {
            return;
        }
        let to = to.min(n - 1);
        if to == from {
            return;
        }
        let tab = win.tabs.remove(from);
        win.tabs.insert(to, tab);
        // Follow the tab that moved, not the position it left.
        win.active = to;
        (from, to)
    };
    layout(frame);
    logf!("[tab] moved {:?} from {} to {}", id, moved.0, moved.1);
    // A reorder **is** a structure change: the children come back in a
    // different order, and a client holding the old order is holding a wrong
    // one. Outside the block above, for the reason written there.
    crate::uia::tabs_changed(frame);
}

/// Panes in the active tab.
pub fn pane_count(frame: HWND) -> usize {
    window(frame)
        .and_then(|w| w.tabs.get(w.active).map(|t| t.panes.len()))
        .unwrap_or(0)
}

/// Give the keyboard, and with it the IME, to the active tab.
///
/// Three things have to agree about which surface is being typed into: Win32
/// focus, the core's own focus flag, and the window TSF measures the caret
/// against. They are set together here so they cannot drift apart.
pub fn focus_active(frame: HWND) {
    let child = {
        let found = window(frame)
            .and_then(|w| w.tabs.get(w.active).and_then(|t| t.focused_pane()).map(|p| p.hwnd));
        match found {
            Some(hwnd) => HWND(hwnd as *mut c_void),
            None => return,
        }
    };
    // **Wrapped, because this focus move can end somebody's composition --
    // but a real machine says it is not the only thing that does, and not the
    // first.**
    //
    // `SetFocus` re-enters TSF, which ends any composition in flight and calls
    // back into `tsf.rs` with the half-typed text still in the buffer; without
    // the guard that text is committed to the terminal.
    //
    // **That was written as the explanation of the whole symptom, and the
    // timestamps refuted it**: pressing a keybinding mid-composition still
    // typed the syllable, and the composition had ended 38ms *before* this
    // function ran -- 5ms before the tab it opens even existed. So something
    // earlier, on the interception path itself, ends it first. `main.rs`'s
    // `trace_intercept` is there to say which step, and until that reading
    // exists this guard is known to be **insufficient, not wrong**: it still
    // covers a real focus change, it just is not where the reported symptom
    // comes from.
    crate::with_host_shuffle(|| {
        crate::ime_set_window(child);
        unsafe {
            let _ = SetFocus(Some(child));
        }
    });
    let s = active_surface(frame);
    if !s.is_null() {
        unsafe { (api().surface_set_focus)(s, true) };
    }
}

pub fn set_initial_input(cmd: &str) {
    shared().initial_input = std::ffi::CString::new(cmd).ok();
}

/// The window of the active tab, or a null HWND when there is none.
pub fn active_hwnd(frame: HWND) -> HWND {
    let found = window(frame)
        .and_then(|w| w.tabs.get(w.active).and_then(|t| t.focused_pane()).map(|p| p.hwnd));
    match found {
        Some(hwnd) => HWND(hwnd as *mut c_void),
        None => HWND(std::ptr::null_mut()),
    }
}

/// How many tabs are in **one window**.
pub fn count(frame: HWND) -> usize {
    window(frame).map(|w| w.tabs.len()).unwrap_or(0)
}

/// The surface of the focused pane of the active tab -- "where typing goes".
pub fn active_surface(frame: HWND) -> Surface {
    let found = window(frame)
        .and_then(|w| w.tabs.get(w.active).and_then(|t| t.focused_pane()).map(|p| p.surface));
    match found {
        Some(surface) => surface as Surface,
        None => std::ptr::null_mut(),
    }
}

/// Which window a pane is in.
///
/// **The key `close_surface` has.** That callback is handed a pane id and no
/// `Target` at all, so it is the one queueing site that cannot go through
/// `origin_window`. A pane id comes out of the one process-wide counter, so
/// it names exactly one pane wherever that pane is.
// window-free: keyed by pane id, which is unique in the process -- this is the
// function that turns such a key *into* a window
pub fn frame_of_pane(pane: PaneId) -> Option<HWND> {
    with_windows(|ws| {
        ws.iter()
            .find(|w| w.tabs.iter().any(|t| t.panes.iter().any(|p| p.id == pane)))
            .map(|w| HWND(w.frame as *mut c_void))
    })
}

/// Which window a surface is in.
///
/// **This is what an action's target can be turned into**, and it is the
/// answer `close_window` needed and did not have: the core says *which
/// surface* an action was sent for, and the window that owns it is a lookup,
/// not a guess. The alternative on offer was `frame_hwnd()` -- the first
/// window -- which is right exactly once and silently wrong for every window
/// opened after it. Every queued op now reaches its window through here.
// window-free: keyed by surface -- this is the function that turns such a key
// *into* a window
pub fn frame_of_surface(surface: Surface) -> Option<HWND> {
    let key = surface as usize;
    with_windows(|ws| {
        ws.iter()
            .find(|w| {
                w.tabs
                    .iter()
                    .any(|t| t.panes.iter().any(|p| p.surface == key))
            })
            .map(|w| HWND(w.frame as *mut c_void))
    })
}

/// The surface bound to a particular pane window, for that window's wndproc.
pub fn surface_of(hwnd: HWND) -> Surface {
    let key = hwnd.0 as isize;
    // Every window: an HWND is unique in the process, so this is a lookup,
    // not a scope decision.
    let found = with_windows(|ws| {
        ws.iter()
            .flat_map(|w| w.tabs.iter())
            .flat_map(|t| t.panes.iter())
            .find(|p| p.hwnd == key)
            .map(|p| p.surface)
    });
    if let Some(surface) = found {
        return surface as Surface;
    }
    // The quick terminal's surface lives in its own module but uses this same
    // window class and window procedure, so the lookup falls through to it.
    crate::quick::surface_of(hwnd)
}

/// The pane that owns a window, so a click can move focus to it: which frame
/// it is in, which tab of that frame, and the pane's identity.
///
/// **The frame is returned rather than taken.** A click arrives at a pane's
/// own window procedure, which knows the pane and not the frame -- and asking
/// the caller to supply a frame would mean asking it to guess, which is how a
/// click in window 2 comes to activate a tab in window 1.
///
/// # It answers `None` for an ordinary pane, at a moment you will meet
///
/// A pane enters the model when `create_tab_with` pushes the finished `Tab`
/// -- **after** `create_pane` has returned. Windows sends `WM_SIZE`, and the
/// drop target is attached, *during* `CreateWindowExW` inside `create_pane`.
/// So at those moments this function answers `None` for a pane that is
/// perfectly normal and about to be perfectly registered.
///
/// That makes it the wrong thing to base a decision on there, and the failure
/// is the quiet kind: the `None` branch is usually worded as "this pane is in
/// no window", which is a true-sounding sentence that runs **every time**. Two
/// call sites have already been written that way and corrected -- `dnd::attach`
/// and the surface window's `WM_SIZE` line.
///
/// **Use `winid::frame_of_window` when the question is only "which frame".**
/// It walks to the root window and checks *that* against the registry, and a
/// frame is registered before it is ever shown -- so it is right from the
/// first message a pane receives. Reach for `pane_of` when you genuinely need
/// the tab index or the `PaneId`, and then treat `None` as "not yet", not as
/// "not ours".
pub fn pane_of(hwnd: HWND) -> Option<(HWND, usize, PaneId)> {
    let key = hwnd.0 as isize;
    with_windows(|ws| {
        for win in ws.iter() {
            for (i, tab) in win.tabs.iter().enumerate() {
                for p in tab.panes.iter() {
                    if p.hwnd == key {
                        return Some((HWND(win.frame as *mut c_void), i, p.id));
                    }
                }
            }
        }
        None
    })
}

/// Focus follows the click: the pane clicked becomes the focused one, and its
/// tab the active one.
/// **The frame comes from the pane, not from the caller.** The parameter that
/// used to be here was the caller's idea of which window the click was in,
/// and every caller got it from the same single global -- so a click on
/// window 2's pane moved window 1's active tab.
pub fn focus_pane_at(hwnd: HWND) {
    let Some((frame, tab_idx, id)) = pane_of(hwnd) else {
        return;
    };
    let changed = {
        let Some(mut win) = window(frame) else { return };
        let was = (win.active, win.tabs.get(win.active).map(|t| t.focused));
        win.active = tab_idx;
        if let Some(tab) = win.tabs.get_mut(tab_idx) {
            tab.focused = id;
        }
        was != (tab_idx, Some(id))
    };
    if changed {
        layout(frame);
    }
    focus_active(frame);
}

fn set_active(frame: HWND, idx: usize) {
    {
        let Some(mut win) = window(frame) else { return };
        if win.tabs.is_empty() {
            return;
        }
        win.active = idx.min(win.tabs.len() - 1);
    }
    layout(frame);
    focus_active(frame);
    wlogf!(frame, "[tab] active -> {} of {}", active_index(frame) + 1, count(frame));
    // **A property change, not a structure change**: switching tabs does not
    // alter the shape of the tree, only which element has focus. The identity
    // is read back here rather than carried down from the block above, so the
    // announcement is about the tab that ended up active -- `idx` was clamped.
    let now = {
        let (tabs_now, active) = tab_infos(frame);
        tabs_now.get(active).map(|t| (t.id, t.pane))
    };
    if let Some((id, pane)) = now {
        crate::uia::active_tab_changed(frame, id, pane);
    }
}

pub fn active_index(frame: HWND) -> usize {
    window(frame).map(|w| w.active).unwrap_or(0)
}

/// Destroy a whole tab: every pane's surface and window.
/// Free a surface and destroy its window, **saying how long each half took**.
///
/// Closing a tab hung the main thread for minutes with no lock contention and
/// no deadlock panic -- so it was not waiting on `STATE`, it was inside a call
/// that does not touch it. There are exactly two candidates here and they
/// belong to different owners: `ghostty_surface_free` joins the core's io and
/// renderer threads and tears down the ConPTY, while `DestroyWindow` is ours.
/// **A log line on each side of both names which one, and a duration says
/// whether it was slow or stopped.**
fn free_pane(id: PaneId, hwnd: isize, surface: usize) {
    // **Before `DestroyWindow`, not after.** `RevokeDragDrop` reaches OLE,
    // which is holding a reference to the drop target, which is holding this
    // HWND. Destroy the window first and OLE is left clutching a dead handle
    // -- and nothing says so at the time.
    crate::dnd::detach(HWND(hwnd as *mut c_void));
    let t0 = std::time::Instant::now();
    logf!("[close] pane {} -> ghostty_surface_free …", id);
    unsafe {
        (api().surface_free)(surface as Surface);
    }
    let t1 = std::time::Instant::now();
    logf!("[close] pane {} surface_free done in {} ms", id, (t1 - t0).as_millis());

    logf!("[close] pane {} -> DestroyWindow …", id);
    unsafe {
        let _ = DestroyWindow(HWND(hwnd as *mut c_void));
    }
    logf!(
        "[close] pane {} DestroyWindow done in {} ms",
        id,
        t1.elapsed().as_millis()
    );
}

fn destroy_tab_at(frame: HWND, idx: usize) {
    // Both come out of the one critical section: the panes to free, and what
    // `reopen.rs` should be told once the guard is gone.
    let (doomed, remembered): (Vec<(PaneId, isize, usize)>, Option<(TabId, String, String)>) = {
        let Some(mut win) = window(frame) else {
            return;
        };
        if idx >= win.tabs.len() {
            return;
        }
        let tab = win.tabs.remove(idx);
        // Taken while the tab is still whole; handed to `reopen.rs` below,
        // **after this guard is dropped** -- `remember` takes its own lock and
        // logs, and this file's rule is that `STATE` is held across neither.
        // **The user's name, not the program's.** A reopened tab gets a fresh
        // shell, and that shell announces its own title within a moment of
        // starting -- so restoring the program's old title produces a name
        // that is visibly wrong for one frame and then gone. Only a name the
        // person chose is theirs to get back.
        let remembered = Some((
            tab.id,
            tab.title_override.clone().unwrap_or_default(),
            tab.cwd.clone().unwrap_or_default(),
        ));
        if win.active >= win.tabs.len() && !win.tabs.is_empty() {
            win.active = win.tabs.len() - 1;
        }
        (
            tab.panes.iter().map(|p| (p.id, p.hwnd, p.surface)).collect(),
            remembered,
        )
    };
    if let Some((id, title, cwd)) = remembered {
        // `remember` refuses an empty cwd, loudly: a tab that reopens in the
        // wrong directory is worse than one that does not reopen at all.
        crate::reopen::remember(frame, Some(id), idx, &title, &cwd);
    }
    logf!("[close] tab index {} -> {} pane(s)", idx, doomed.len());
    for (id, hwnd, surface) in doomed {
        free_pane(id, hwnd, surface);
    }
    logf!("[close] tab index {} panes gone; laying out", idx);
    layout(frame);
    wlogf!(frame, "[tab] closed index {}; count now {}", idx, count(frame));
    // Same rule as the creation side: the critical section ended far above.
    crate::uia::tabs_changed(frame);
}

/// `CF_UNICODETEXT`. Spelled numerically because the constant lives behind a
/// feature this crate does not otherwise need.
const CF_UNICODETEXT: u32 = 13;

/// Put text on the Windows clipboard.
///
/// **Returns why, not just whether.** The defect this was pulled out of was
/// precisely a clipboard write that reported success and did nothing, so
/// "tried" and "succeeded" have to be two different readings, and a failure
/// that cannot say which of four calls failed is barely better than a `false`.
pub fn copy_to_clipboard(text: &str) -> Result<(), &'static str> {
    use windows::Win32::System::DataExchange::*;
    use windows::Win32::System::Memory::*;
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    wide.push(0);
    let bytes = wide.len() * 2;
    unsafe {
        // The clipboard is a machine-wide resource and another process can be
        // holding it. This is the failure a user actually hits, and it is
        // transient, so it has to be distinguishable from the rest.
        if OpenClipboard(None).is_err() {
            return Err("OpenClipboard denied (another process holds it)");
        }
        let _ = EmptyClipboard();
        let h = match GlobalAlloc(GMEM_MOVEABLE, bytes) {
            Ok(h) => h,
            Err(_) => {
                let _ = CloseClipboard();
                return Err("GlobalAlloc failed");
            }
        };
        let p = GlobalLock(h);
        if p.is_null() {
            // **`GlobalFree` before returning.** Ownership of `h` passes to
            // the clipboard only when `SetClipboardData` succeeds; on every
            // path before that it is still ours, and the previous version
            // dropped it -- leaking one block per failed copy.
            let _ = windows::Win32::Foundation::GlobalFree(Some(h));
            let _ = CloseClipboard();
            return Err("GlobalLock failed");
        }
        std::ptr::copy_nonoverlapping(wide.as_ptr(), p as *mut u16, wide.len());
        let _ = GlobalUnlock(h);
        let ok = SetClipboardData(CF_UNICODETEXT, Some(windows::Win32::Foundation::HANDLE(h.0)))
            .is_ok();
        if !ok {
            // Same rule: it did not take ownership, so it is still ours.
            let _ = windows::Win32::Foundation::GlobalFree(Some(h));
        }
        let _ = CloseClipboard();
        if ok {
            Ok(())
        } else {
            Err("SetClipboardData failed")
        }
    }
}

/// Read text off the Windows clipboard.
///
/// `CF_UNICODETEXT` only: Windows synthesises it from `CF_TEXT` for us, so
/// asking for the one format covers both without a conversion of our own.
pub fn read_clipboard_text() -> Result<String, &'static str> {
    use windows::Win32::System::DataExchange::*;
    use windows::Win32::System::Memory::*;
    unsafe {
        if !IsClipboardFormatAvailable(CF_UNICODETEXT).is_ok() {
            // Not an error worth alarming about -- an image on the clipboard
            // reaches here -- but it is a different outcome from a failure to
            // open, and the log has to say which.
            return Err("clipboard has no CF_UNICODETEXT");
        }
        if OpenClipboard(None).is_err() {
            return Err("OpenClipboard denied (another process holds it)");
        }
        let h = match GetClipboardData(CF_UNICODETEXT) {
            Ok(h) => h,
            Err(_) => {
                let _ = CloseClipboard();
                return Err("GetClipboardData failed");
            }
        };
        let hg = windows::Win32::Foundation::HGLOBAL(h.0);
        let p = GlobalLock(hg) as *const u16;
        if p.is_null() {
            let _ = CloseClipboard();
            return Err("GlobalLock failed");
        }
        // **The handle belongs to the clipboard, not to us**: it is locked and
        // unlocked, never freed, and it must not be read after CloseClipboard.
        let mut n = 0usize;
        while *p.add(n) != 0 {
            n += 1;
        }
        let text = String::from_utf16_lossy(std::slice::from_raw_parts(p, n));
        let _ = GlobalUnlock(hg);
        let _ = CloseClipboard();
        Ok(text)
    }
}

/// The surface belonging to a pane id.
///
/// **Both clipboard callbacks are handed a pane id**, because `embedded.zig`
/// passes the *surface's* userdata (`self.userdata`), not the runtime's --
/// which is null. So a paste can be completed against the surface that asked
/// for it, and neither callback has to fall back to "whichever surface has
/// focus". That fallback would be wrong in exactly the way tonight's other
/// three defects were wrong, and here it costs nothing to avoid.
// window-free: keyed by pane id, which is unique in the process
pub fn surface_of_pane(pane: u64) -> Surface {
    // Every window: a `PaneId` comes out of one process-wide counter, so it
    // names exactly one pane wherever that pane is.
    with_windows(|ws| {
        ws.iter()
            .flat_map(|w| w.tabs.iter())
            .flat_map(|t| t.panes.iter())
            .find(|p| p.id == pane)
            .map(|p| p.surface as Surface)
            .unwrap_or(std::ptr::null_mut())
    })
}

fn go_fullscreen(frame: HWND) {
    // Same rule as `layout`: every call below re-enters this thread's window
    // procedures, which take the lock. The saved placement is taken out and
    // put back in short critical sections around them, never held across one.
    let saved = { window(frame).and_then(|mut w| w.pre_fullscreen.take()) };
    unsafe {
        if let Some((wp, style)) = saved {
            SetWindowLongPtrW(frame, GWL_STYLE, style);
            let _ = SetWindowPlacement(frame, &wp);
            let _ = SetWindowPos(
                frame,
                None,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED,
            );
            wlogf!(frame, "[win] fullscreen OFF");
            return;
        }

        let mut wp = WINDOWPLACEMENT {
            length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
            ..Default::default()
        };
        let _ = GetWindowPlacement(frame, &mut wp);
        let style = GetWindowLongPtrW(frame, GWL_STYLE);

        let mon = MonitorFromWindow(frame, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if !GetMonitorInfoW(mon, &mut mi).as_bool() {
            wlogf!(frame, "[win] fullscreen: GetMonitorInfoW failed, staying windowed");
            return;
        }

        // Recorded before the window changes, so a re-entrant layout during
        // SetWindowPos sees the state that matches the window it is laying out.
        if let Some(mut w) = window(frame) {
            w.pre_fullscreen = Some((wp, style));
        }

        let r = mi.rcMonitor;
        SetWindowLongPtrW(
            frame,
            GWL_STYLE,
            (style & !(WS_OVERLAPPEDWINDOW.0 as isize)) | (WS_POPUP.0 as isize),
        );
        let _ = SetWindowPos(
            frame,
            Some(HWND_TOP),
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
        );
        wlogf!(
            frame,
            "[win] fullscreen ON  monitor {}x{}",
            r.right - r.left,
            r.bottom - r.top
        );
    }
}

/// Drain the queue. Called on the main thread only.
pub fn run_ops(frame: HWND, app: App, hinst: windows::Win32::Foundation::HINSTANCE) {
    let delay = ops_delay_ms();
    loop {
        let (op, from, behind) = {
            let Some(mut w) = window(frame) else {
                // The window went while its own pump was draining. Nothing
                // left to run for it, and its queue went with it.
                return;
            };
            let Some(head) = w.ops.first() else {
                return;
            };
            // **Not yet due: stop, do not skip.** Skipping to the next op
            // that *is* due would reorder the queue, which is exactly what
            // C6 forbids -- and it would do it only while the hook is on, so
            // the reordering would be invisible in every ordinary run.
            if delay > 0 && (head.at.elapsed().as_millis() as u64) < delay {
                return;
            }
            let q = w.ops.remove(0);
            (q.op, q.from, w.ops.len())
        };

        // **The target is on this line too, and it is the target rather than
        // "the window we are running on".** They are the same window here by
        // construction -- that is what the queue being the window's own
        // means -- and printing it anyway is what makes the pair of lines
        // comparable: a reader matches `queued X for w2` against `running X
        // for w2` without having to know which pump produced the second.
        // The provenance is repeated from the `queued` line so the two can be
        // paired by eye when several ops are in flight -- three `NewTab`s for
        // one window are otherwise three identical lines.
        wlogf!(frame, "[ops] running {} for {}; {} queued behind it (queued from {})",
            op.name(), crate::winid::tag(frame), behind, from);

        match op {
            Op::NewTab => {
                create_tab(frame, app, hinst);
            }
            Op::NewWindow => {
                // **A window and then a tab in it, and the log says which of
                // the two failed.** An empty frame on screen and no frame at
                // all are different outcomes with different causes, and a
                // single "new_window failed" could not tell them apart.
                match crate::create_frame_secondary(hinst) {
                    None => wlogf!(frame, "[win] new_window: no frame created"),
                    Some(w2) => {
                        let ok = create_tab(w2, app, hinst);
                        wlogf!(w2, "[win] new_window: frame up, first tab created={}", ok as u8);
                        if !ok {
                            // Nothing to show and nothing to close it with:
                            // an empty frame is the E6 symptom whatever made
                            // it, so it goes the same way a closed one does.
                            wlogf!(w2, "[win] new_window: no tab, so no window");
                            crate::winid::close_window_now(w2);
                        }
                    }
                }
            }
            Op::NewTabWith(spec) => {
                let chat = spec.chat;
                let ok = create_tab_with(frame, app, hinst, spec);
                wlogf!(frame, "[tab] new tab (chat={}) created={}", chat, ok as u8);
            }
            Op::ReopenTab { cwd, title, index } => {
                if !create_tab_in(frame, app, hinst, Some(cwd.clone())) {
                    // Back on the stack: `reopen_last` already popped it, and
                    // an entry dropped here would make the next undo reopen
                    // the wrong tab with nothing to say why.
                    wlogf!(frame, "[reopen] could not create the tab; putting {:?} back", title);
                    // **`None`: there is no tab.** The one this entry names
                    // was destroyed when it was closed, and the replacement
                    // was just refused -- so nothing here has an identity to
                    // give, and saying so is the honest half of the line.
                    crate::reopen::remember(frame, None, index, &title, &cwd);
                    continue;
                }
                // `create_tab_in` appends and activates, so the tab just made
                // is the last one -- and it is picked up **by identity here**,
                // before anything else can reorder, so the rename and the move
                // below cannot land on a different tab.
                let Some(id) = window(frame).and_then(|w| w.tabs.last().map(|t| t.id)) else {
                    continue;
                };
                // **Only if there is one to restore**, and the log below says
                // which happened. Renaming to the empty string would put a
                // blank tab on the strip; renaming to the old shell title
                // would be overwritten by the new shell a moment later, and
                // the line claiming it had been restored would be describing
                // something nobody could see.
                if !title.is_empty() {
                    rename_tab(frame, id, title.clone());
                }
                // Back where it was. Clamped by `move_tab_to` itself: the tab
                // list is shorter now than when it was closed, and index 7 of
                // a 3-tab strip has to mean "the end", not "nowhere".
                move_tab_to(frame, id, index);
                // **Both halves are read back, not intended.** The index is
                // where the tab actually is after the move, and the directory
                // is the one `create_pane` actually handed to the surface --
                // W3's K1 floor compares this line against the `cd` output on
                // screen, and a line printed from the copy on the stack would
                // agree with itself while the shell stood somewhere else.
                let used = window(frame)
                    .and_then(|w| w.last_pane_cwd.clone())
                    .unwrap_or_default();
                let at = index_of(frame, id).map(|(i, _)| i).unwrap_or(0);
                // **The log claims only what is on the strip.** These two
                // lines are different claims, and the reason they are two is
                // that a single line saying `restored "tab-alpha"` was true of
                // the host's intent and false of the screen a moment later.
                if title.is_empty() {
                    wlogf!(
                        frame,
                        "[reopen] restored cwd={:?} at index {} of {}; no user title to restore, \
                         the shell names it",
                        used,
                        at,
                        count(frame)
                    );
                } else {
                    wlogf!(
                        frame,
                        "[reopen] restored {:?} cwd={:?} at index {} of {}",
                        title,
                        used,
                        at,
                        count(frame)
                    );
                }
            }
            Op::CloseTab(mode) => {
                let (active, n) = (active_index(frame), count(frame));
                match mode {
                    CLOSE_TAB_OTHER => {
                        for i in (0..n).rev() {
                            if i != active {
                                destroy_tab_at(frame, i);
                            }
                        }
                        set_active(frame, 0);
                    }
                    CLOSE_TAB_RIGHT => {
                        for i in (active + 1..n).rev() {
                            destroy_tab_at(frame, i);
                        }
                    }
                    _ => {
                        destroy_tab_at(frame, active);
                        if count(frame) == 0 {
                            wlogf!(frame, "[tab] last tab closed");
                            // Through the one point, so every route leaves the same record the
                            // window's own X does -- and it **destroys** the window, which the
                            // direct `window_finished` call that used to be here never did: it
                            // recorded the window as finished and left it on the screen. See
                            // `winid::close_window_now`.
                            crate::winid::close_window_now(frame);
                        } else {
                            set_active(frame, active_index(frame));
                        }
                    }
                }
            }
            Op::GotoTab(v) => {
                let n = count(frame);
                if n == 0 {
                    continue;
                }
                let cur = active_index(frame);
                let idx = match v {
                    GOTO_TAB_PREVIOUS => (cur + n - 1) % n,
                    GOTO_TAB_NEXT => (cur + 1) % n,
                    GOTO_TAB_LAST => n - 1,
                    // The C enum is 1-based for explicit indices.
                    x if x >= 1 => ((x as usize) - 1).min(n - 1),
                    _ => cur,
                };
                set_active(frame, idx);
            }
            Op::MoveTabBy(delta) => {
                // Resolve to an identity here, on the main thread, and hand
                // the rest to the primitive.
                let target = {
                    let Some(win) = window(frame) else { continue };
                    let n = win.tabs.len() as i64;
                    if n < 2 {
                        None
                    } else {
                        let cur = win.active as i64;
                        // Wrap, the way macOS does, so move_tab:1 on the last
                        // tab brings it to the front rather than doing nothing.
                        let mut to = (cur + delta) % n;
                        if to < 0 {
                            to += n;
                        }
                        win.tabs.get(win.active).map(|t| (t.id, to as usize))
                    }
                };
                if let Some((id, to)) = target {
                    move_tab_to(frame, id, to);
                }
            }
            Op::ToggleFullscreen => go_fullscreen(frame),
            Op::ToggleMaximize => unsafe {
                let zoomed = IsZoomed(frame).as_bool();
                let _ = ShowWindow(frame, if zoomed { SW_RESTORE } else { SW_MAXIMIZE });
                wlogf!(frame, "[win] maximize {} -> {}", zoomed, !zoomed);
            },
            Op::ResetWindowSize => {
                // **This window's own first size.** One copy for the
                // process meant `reset_window_size` in window 2 restored the
                // size window 1's first surface had asked for.
                let init = window(frame).and_then(|w| w.initial);
                if let Some((w, h)) = init {
                    unsafe {
                        let _ = ShowWindow(frame, SW_RESTORE);
                        let _ = SetWindowPos(
                            frame,
                            None,
                            0,
                            0,
                            w as i32,
                            h as i32,
                            SWP_NOMOVE | SWP_NOZORDER,
                        );
                    }
                    wlogf!(frame, "[win] reset_window_size -> {}x{}", w, h);
                }
            }
            Op::SetTabTitle { surface, title } => {
                let outcome = set_shell_title(surface, title.clone());
                unsafe {
                    let _ = InvalidateRect(Some(frame), None, false);
                }
                // **One line, and it says which of the three happened, and to
                // which tab.** The line that used to be here read
                // `set_tab_title "..."` whatever the outcome and never named a
                // tab -- so a title landing on the wrong one looked exactly
                // like a title landing on the right one.
                // **The window in the tag is the one the title landed in**,
                // which is not necessarily the one draining the queue: a
                // background shell in window 2 renames itself while window 1
                // is the one being pumped.
                match outcome {
                    ShellTitle::Applied(owner, i, n) => {
                        let owner = HWND(owner as *mut c_void);
                        wlogf!(owner, "[tab] set_tab_title {:?} on tab {} of {}", title, i + 1, n)
                    }
                    ShellTitle::Overridden(owner, i, n) => {
                        let owner = HWND(owner as *mut c_void);
                        wlogf!(owner,
                            "[tab] set_tab_title {:?} ignored on tab {} of {}; the user named it",
                            title,
                            i + 1,
                            n
                        )
                    }
                    // process-wide: no tab in any window owns this surface,
                    // so there is no window this line belongs to. **`frame` is
                    // in scope and is the wrong answer**: it is the window
                    // draining the queue, and the two arms above deliberately
                    // tag with the window the title *landed* in for exactly
                    // that reason. Naming the pump here would read like a
                    // window that dropped a title, which no window did.
                    ShellTitle::NoSuchSurface => plogf!(
                        "[tab] set_tab_title {:?} dropped: no tab owns surface {:?}",
                        title,
                        surface as *const std::ffi::c_void
                    ),
                }
            }
            Op::CopyTitleToClipboard => {
                let title = {
                    window(frame)
                        .and_then(|w| w.tabs.get(w.active).map(|t| t.title.clone()))
                        .unwrap_or_default()
                };
                let ok = copy_to_clipboard(&title).is_ok();
                wlogf!(frame, "[win] copy_title_to_clipboard {:?} -> {}", title, ok);
            }
            Op::NewSplit(dir) => {
                // `ghostty_action_split_direction_e`
                let d = match dir {
                    1 => NewSplit::Down,
                    2 => NewSplit::Left,
                    3 => NewSplit::Up,
                    _ => NewSplit::Right,
                };
                split_focused(frame, app, hinst, d);
            }
            Op::GotoSplit(v) => {
                // `ghostty_action_goto_split_e`
                let f = match v {
                    0 => Focus::Previous,
                    1 => Focus::Next,
                    2 => Focus::Spatial(Side::Up),
                    3 => Focus::Spatial(Side::Left),
                    4 => Focus::Spatial(Side::Down),
                    _ => Focus::Spatial(Side::Right),
                };
                let target = {
                    window(frame).and_then(|w| {
                        w.tabs
                            .get(w.active)
                            .and_then(|t| t.tree.focus_target(f, t.focused))
                    })
                };
                match target {
                    Some(id) => {
                        {
                            if let Some(mut win) = window(frame) {
                                let a = win.active;
                                if let Some(tab) = win.tabs.get_mut(a) {
                                    tab.focused = id;
                                }
                            }
                        }
                        focus_active(frame);
                        logf!("[split] focus -> pane {}", id);
                    }
                    // No pane that way. Doing nothing is the honest answer;
                    // wrapping would put focus somewhere the user did not aim.
                    None => wlogf!(frame, "[split] no pane {:?} of the focused one", f),
                }
            }
            Op::ResizeSplit(amount, dir) => {
                // `ghostty_action_resize_split_direction_e`
                let side = match dir {
                    0 => Side::Up,
                    1 => Side::Down,
                    2 => Side::Left,
                    _ => Side::Right,
                };
                let out = {
                    let Some(win) = window(frame) else { continue };
                    let sh = strip_h(win.scale);
                    let cur = win.tabs.get(win.active);
                    match (content_bounds(frame, sh), cur) {
                        (Some(b), Some(tab)) => {
                            Some((tab.tree.resize(tab.focused, amount, side, b), tab.focused))
                        }
                        _ => None,
                    }
                };
                if let Some((res, focused)) = out {
                    match res {
                        Ok(t) => {
                            {
                                if let Some(mut win) = window(frame) {
                                    let a = win.active;
                                    if let Some(tab) = win.tabs.get_mut(a) {
                                        tab.tree = t;
                                    }
                                }
                            }
                            layout(frame);
                            wlogf!(frame, "[split] resize pane {} by {} {:?}", focused, amount, side);
                        }
                        Err(e) => wlogf!(frame, "[split] resize refused: {:?}", e),
                    }
                }
            }
            Op::EqualizeSplits => {
                {
                    if let Some(mut win) = window(frame) {
                        let a = win.active;
                        if let Some(tab) = win.tabs.get_mut(a) {
                            tab.tree = tab.tree.equalize();
                        }
                    }
                }
                layout(frame);
                wlogf!(frame, "[split] equalized");
            }
            Op::ToggleSplitZoom => {
                let zoomed = {
                    // **The toggle happens inside the closure**, because the
                    // guard owns the lock and a `&mut Tab` cannot leave it.
                    window(frame)
                        .and_then(|mut w| {
                            let a = w.active;
                            w.tabs.get_mut(a).map(|tab| {
                                tab.tree = tab.tree.toggle_zoom(tab.focused);
                                tab.tree.zoomed()
                            })
                        })
                        .flatten()
                };
                layout(frame);
                wlogf!(frame, "[split] zoom -> {:?}", zoomed);
            }
            Op::ClosePane(id) => close_pane(frame, id),
            Op::ToggleQuickTerminal => crate::quick::toggle(app, hinst),
            Op::PresentTerminal => unsafe {
                let _ = ShowWindow(frame, SW_RESTORE);
                let _ = SetForegroundWindow(frame);
                wlogf!(frame, "[win] present_terminal");
            },
        }
    }
}

/// `WM_GETMINMAXINFO`: turn the core's cell-derived limit into a frame size.
///
/// The core reports a *client* minimum (cells x cell size); Windows asks
/// about the whole window, so the non-client area and the tab strip have to
/// be added back or the terminal ends up one row short of what the core
/// asked for.
/// **Answered for the frame the message arrived at.** `WM_GETMINMAXINFO` is
/// per window, and the limits used to be one set for the process -- so a
/// floor computed from window 2's cell grid became the size window 1 could
/// not be dragged below.
pub fn apply_min_max(frame: HWND, mmi: *mut MINMAXINFO) {
    let Some((min_w, min_h, max_w, max_h, scale)) = window(frame)
        .map(|w| (w.min_w, w.min_h, w.max_w, w.max_h, w.scale))
    else {
        return;
    };
    if min_w == 0 && min_h == 0 && max_w == 0 && max_h == 0 {
        return;
    }
    // **No `AdjustWindowRectEx` any more.** With the custom frame the client
    // area *is* the window rect (see shell.rs), so there is no caption or
    // border to add back. Asking Windows for the non-client size of a
    // `WS_OVERLAPPEDWINDOW` would add a caption that is not there and make
    // the minimum a titlebar too tall -- a wrong number that nothing would
    // ever report.
    let sh = strip_h(scale);
    unsafe {
        if min_w > 0 || min_h > 0 {
            (*mmi).ptMinTrackSize.x = min_w as i32;
            (*mmi).ptMinTrackSize.y = min_h as i32 + sh;
        }
        // A zero maximum means "no maximum" -- that is what the core sends
        // today, and clamping to zero would make the window unresizable.
        if max_w > 0 && max_h > 0 {
            (*mmi).ptMaxTrackSize.x = max_w as i32;
            (*mmi).ptMaxTrackSize.y = max_h as i32 + sh;
        }
    }
}

/// How many layouts have run, so the per-pane lines can be bounded.
static LAYOUTS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// How many times the surface was resized and told the core.
static SIZES: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// How many WM_PAINT the surface window has been sent.
static PAINT_MSGS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// The window that owns one surface: a child of the frame, or -- under
/// `--toplevel` -- a top-level window of its own.
/// Tell the core where the pointer is.
///
/// # The one conversion that is wrong invisibly
///
/// `LPARAM` carries client coordinates, and in a per-monitor-aware process
/// those are **physical pixels**. The core wants **unscaled** ones: its
/// `cursorPosCallback` multiplies by the content scale itself
/// (`embedded.zig`'s `cursorPosToPixels`), using the very scale this host
/// passed to `ghostty_surface_set_content_scale`.
///
/// So the two have to be divided back out here. **At 100% the bug is
/// invisible** -- scale is 1 and the wrong version is the right version --
/// and it only appears on a display where somebody would report it as "the
/// selection is offset", which points at the selection code rather than at
/// this line.
///
/// The scale is taken from the window rather than measured from anything
/// drawn: a screenshot's reported scale on the test machine is not the real
/// one, and geometry read back from an image would inherit that.
fn mouse_pos(pane: HWND, lp: LPARAM) {
    let s = surface_of(pane);
    if s.is_null() {
        return;
    }
    let Some(frame) = crate::winid::frame_of_window(pane) else {
        return;
    };
    let scale = scale_of(frame).max(0.01);
    let x = (lp.0 & 0xFFFF) as i16 as f64;
    let y = ((lp.0 >> 16) & 0xFFFF) as i16 as f64;
    unsafe { (api().surface_mouse_pos)(s, x / scale, y / scale, crate::keys::mods()) };

    // **The divisor, said out loud, because two different faults produce the
    // same screen and only this number tells them apart.**
    //
    // A selection landing at exactly 1.5x the pointer on a 150% display has
    // two possible causes, and their fixes are opposite:
    //
    //   * the conversion is inverted -- it should multiply;
    //   * **the conversion is right and this divisor is 1.0**, so dividing
    //     did nothing while the core went on multiplying by its own 1.5.
    //
    // Flipping the arithmetic would make the second case *look* fixed on a
    // 150% display and be wrong again at any other -- at 125% by 1.56, at
    // 175% by 3.06 -- so the number has to be read before anything is
    // changed. Compare it with the `content_scale=` on the `[pane]` line:
    // equal means the conversion is at fault, different means this value's
    // source is.
    //
    // **Once per drag, not once per move.** A line per `WM_MOUSEMOVE` is
    // thousands of lines a second and would push the interesting ones out of
    // reach; the divisor cannot change within one drag, so the first sample
    // after each press says everything a whole drag would.
    if MOUSE_SAMPLE.swap(false, std::sync::atomic::Ordering::Relaxed) {
        wlogf!(
            frame,
            "[mouse] pos client=({},{}) divisor={} -> sent=({:.2},{:.2})",
            x, y, scale, x / scale, y / scale
        );
    }
}

/// Set on each button press so the next motion reports its arithmetic once.
///
/// **An instrument, and it changes only what is visible**: nothing reads it
/// to decide where a message goes, and clearing it cannot alter a coordinate.
static MOUSE_SAMPLE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(true);

/// Tell the core a button went down or came up.
///
/// **Position first, always.** The core resolves a click against wherever it
/// last believes the pointer is, so a button reported before the position it
/// happened at selects from the previous point. Every caller here sends
/// `mouse_pos` immediately before -- except the capture-lost arm, which has
/// no position to report and must not invent one.
fn mouse_button(pane: HWND, state: i32, button: i32) {
    let s = surface_of(pane);
    if s.is_null() {
        return;
    }
    unsafe { (api().surface_mouse_button)(s, state, button, crate::keys::mods()) };
}

pub extern "system" fn surface_wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            // Same contract as the frame had in M1: we own every pixel.
            WM_ERASEBKGND => LRESULT(1),

            WM_PAINT => {
                // Logged whether or not we draw: "the surface window is being
                // asked to paint" and "the main thread drew" are two different
                // claims, and only the second one has a counter today.
                let m = PAINT_MSGS.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                if m <= 5 {
                    logf!("[paint] surface window got WM_PAINT #{}", m);
                }
                let s = surface_of(hwnd);
                if !s.is_null() && crate::draw_on_paint() {
                    let n = crate::paint_tick();
                    // Log generously but bounded: during a resize these land
                    // inside the window where the main loop is blocked, which
                    // is exactly the evidence we are after.
                    if n <= 400 {
                        logf!("[paint] #{} main-thread surface_draw", n);
                    }
                    (api().surface_draw)(s);
                }
                let _ = ValidateRect(Some(hwnd), None);
                LRESULT(0)
            }

            WM_SIZE => {
                let w = (lp.0 & 0xFFFF) as u32;
                let h = ((lp.0 >> 16) & 0xFFFF) as u32;
                let s = surface_of(hwnd);
                if !s.is_null() && w > 0 && h > 0 {
                    (api().surface_set_size)(s, w, h);
                    let n = SIZES.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                    if n <= 10 {
                        // **The frame is looked up, not assumed from `hwnd`.**
                        // `hwnd` here is a *pane's* window; `wlogf!(hwnd, ..)`
                        // compiles, and then `winid` issues it a window number
                        // of its own -- a window that appears in the log and
                        // has never existed.
                        //
                        // **`winid::frame_of_window`, not `pane_of`.** The
                        // obvious version of this asks the tab model which
                        // pane owns the handle -- and a pane is only in that
                        // model *after* `create_pane` returns, while `WM_SIZE`
                        // arrives during `CreateWindowExW` inside it. So
                        // `pane_of` answers `None` for a perfectly ordinary
                        // pane at exactly the moment this line is written.
                        // Walking to the root window and checking *that*
                        // against the registry works from the frame's
                        // creation, because the frame is registered before it
                        // is shown.
                        match crate::winid::frame_of_window(hwnd) {
                            Some(frame) => wlogf!(
                                frame,
                                "[win] surface {:?} WM_SIZE {}x{} -> set_size (#{})",
                                hwnd.0, w, h, n
                            ),
                            // process-wide: the handle belongs to no
                            // registered frame -- the quick terminal's surface,
                            // or a pane whose window has already gone
                            None => plogf!(
                                "[win] surface {:?} WM_SIZE {}x{} -> set_size (#{}); \
                                 in no tracked window",
                                hwnd.0, w, h, n
                            ),
                        }
                    }
                }
                // The composition is somewhere else on screen now even though
                // its text did not change. TSF does not come back to ask.
                crate::ime_layout_changed();
                LRESULT(0)
            }

            // Keys, and the IME, belong to the surface they were typed into.
            WM_KEYDOWN | WM_SYSKEYDOWN | WM_KEYUP | WM_SYSKEYUP => {
                let s = surface_of(hwnd);
                if s.is_null() {
                    return DefWindowProcW(hwnd, msg, wp, lp);
                }
                crate::keys::handle_key_message(hwnd, msg, wp, lp, s)
            }

            // Fallback for anything the core did not consume as a key.
            // The right button. **The host handled no right-button message at
            // all before this**; a person who selected text and reached for it
            // got nothing back, which is the whole of what
            // `discoverability.md` D2 asks about.
            //
            // `WM_CONTEXTMENU` rather than `WM_RBUTTONUP`: it is the message
            // Windows sends for *every* way of asking for a context menu,
            // including the keyboard's menu key, and handling the mouse one
            // alone would leave that path silent.
            WM_CONTEXTMENU => {
                crate::ctxmenu::on_context_menu(hwnd, lp.0);
                LRESULT(0)
            }

            WM_CHAR => {
                let s = surface_of(hwnd);
                let c = wp.0 as u16;
                if !s.is_null() && (c >= 0x20 || c == 0x08 || c == 0x0D || c == 0x09) {
                    let mut buf = [0u8; 8];
                    let txt: &str = char::from_u32(c as u32)
                        .map(|ch| &*ch.encode_utf8(&mut buf))
                        .unwrap_or("");
                    if !txt.is_empty() {
                        (api().surface_text)(s, txt.as_ptr() as *const _, txt.len());
                    }
                }
                LRESULT(0)
            }

            // Clicking a pane is how a user says "type here". With splits
            // that is also how focus moves between them, so it goes through
            // the model rather than straight to SetFocus.
            WM_LBUTTONDOWN => {
                // **No frame argument any more, and that is the fix.** This
                // passed `frame_hwnd()` -- the first window -- for a click
                // that arrived at a pane which may belong to any window.
                // `focus_pane_at` now works the frame out from the pane.
                focus_pane_at(hwnd);

                // **Capture, so a drag that leaves the window keeps arriving.**
                // Without it the pointer crossing into the next pane stops
                // sending us `WM_MOUSEMOVE` and the selection freezes where it
                // was, which reads as "selection stops halfway".
                let _ = SetCapture(hwnd);
                MOUSE_SAMPLE.store(true, std::sync::atomic::Ordering::Relaxed);
                mouse_pos(hwnd, lp);
                mouse_button(hwnd, crate::ffi::MOUSE_PRESS, crate::ffi::MOUSE_LEFT);
                LRESULT(0)
            }

            WM_MOUSEMOVE => {
                mouse_pos(hwnd, lp);
                LRESULT(0)
            }

            WM_LBUTTONUP => {
                mouse_pos(hwnd, lp);
                mouse_button(hwnd, crate::ffi::MOUSE_RELEASE, crate::ffi::MOUSE_LEFT);
                let _ = ReleaseCapture();
                LRESULT(0)
            }

            // **Capture taken away from us, rather than given back.**
            //
            // Windows sends this when something else claims the mouse, when
            // the window is destroyed under a held button, and when an
            // Alt+Tab or a modal steals it. **The button is never released as
            // far as the core is concerned**, so without this arm a drag
            // interrupted that way leaves the core believing the button is
            // still down: every later pointer movement goes on extending a
            // selection nobody is dragging.
            //
            // `ReleaseCapture` is deliberately **not** called here -- capture
            // is already gone, and asking for it back is how the pair stops
            // meaning anything.
            WM_CAPTURECHANGED => {
                mouse_button(hwnd, crate::ffi::MOUSE_RELEASE, crate::ffi::MOUSE_LEFT);
                LRESULT(0)
            }

            WM_SETFOCUS => {
                crate::ime_set_window(hwnd);
                crate::ime_focus(true);
                let s = surface_of(hwnd);
                if !s.is_null() {
                    (api().surface_set_focus)(s, true);
                }
                LRESULT(0)
            }
            WM_KILLFOCUS => {
                let s = surface_of(hwnd);
                if !s.is_null() {
                    (api().surface_set_focus)(s, false);
                }
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}
