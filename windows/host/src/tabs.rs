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
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_split_tree::{Focus, NewSplit, PaneId, Placement, Rect as TreeRect, Side, Tree};

use crate::ffi::*;
use crate::{api, logf};

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
    CloseTab(i32),
    GotoTab(i32),
    /// What the core's `move_tab` action carries: a relative shift of the
    /// active tab. Kept faithful to the action rather than resolved at the
    /// call site, because the tab set can change between queueing and running.
    MoveTabBy(i64),
    ToggleFullscreen,
    ToggleMaximize,
    ResetWindowSize,
    SetTabTitle(String),
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

pub struct State {
    pub tabs: Vec<Tab>,
    pub active: usize,
    /// From the `size_limit` action: the smallest the core says a window may
    /// be. Reported to Windows through `WM_GETMINMAXINFO`.
    pub min_w: u32,
    pub min_h: u32,
    pub max_w: u32,
    pub max_h: u32,
    /// Saved frame state while fullscreen, so the toggle can undo itself.
    pub pre_fullscreen: Option<(WINDOWPLACEMENT, isize)>,
    pub ops: Vec<Op>,
    pub frame: isize,
    pub scale: f64,
    /// The size the very first surface asked for, for `reset_window_size`.
    pub initial: Option<(u32, u32)>,
    /// Handed out to panes **and tabs**, never reused. One counter for both,
    /// so an id means exactly one thing in this process. Starts at 1 so that
    /// 0 can mean "no pane" in the C userdata pointer.
    pub next_id: u64,
    /// Typed into the first shell as if the user had typed it (`--clock`).
    /// Owned here because the core reads the pointer during `surface_new`.
    pub initial_input: Option<std::ffi::CString>,
    /// Working directories reported for a surface that has no `Tab` yet.
    ///
    /// **This exists because of an ordering, not as a cache.** The core emits
    /// `pwd` from inside `ghostty_surface_new`, and that call happens before
    /// the `Tab` holding the pane is pushed. Without somewhere to put it the
    /// first `pwd` of every tab is dropped -- and the symptom would be that
    /// reopening a tab you never `cd`'d in lands in the wrong place.
    pub pending_cwd: Vec<(usize, String)>,
    /// **The directory actually handed to `sc.working_directory`** by the
    /// last `create_pane`, or `None` when none was.
    ///
    /// Written where the pointer is set, read by the restore log line. It
    /// exists because that line must report the value that was *used*, not
    /// the one the caller meant to use -- the same value right up until the
    /// moment worth catching, when the string could not be made into a
    /// `CString` and the shell quietly started somewhere else.
    pub last_pane_cwd: Option<String>,
}

impl State {
    const fn new() -> Self {
        State {
            tabs: Vec::new(),
            active: 0,
            min_w: 0,
            min_h: 0,
            max_w: 0,
            max_h: 0,
            pre_fullscreen: None,
            ops: Vec::new(),
            frame: 0,
            scale: 1.0,
            next_id: 1,
            initial: None,
            initial_input: None,
            pending_cwd: Vec::new(),
            last_pane_cwd: None,
        }
    }
}

static STATE: Mutex<State> = Mutex::new(State::new());

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
pub struct Guard {
    inner: std::sync::MutexGuard<'static, State>,
}

impl std::ops::Deref for Guard {
    type Target = State;
    fn deref(&self) -> &State {
        &self.inner
    }
}
impl std::ops::DerefMut for Guard {
    fn deref_mut(&mut self) -> &mut State {
        &mut self.inner
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        HOLDER.store(0, std::sync::atomic::Ordering::Release);
    }
}

/// `&'static Location` of whoever holds the lock, or 0.
static HOLDER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
/// How many times anyone has had to wait. Bounds the logging.
static CONTENDED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

fn claim(
    inner: std::sync::MutexGuard<'static, State>,
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

#[track_caller]
pub fn state() -> Guard {
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

/// Queue an op and wake the main thread. Safe from any thread.
pub fn post_op(op: Op) {
    {
        let mut st = state();
        st.ops.push(op);
    }
    let frame = frame_hwnd();
    if frame.0 as isize != 0 {
        unsafe {
            let _ = PostMessageW(Some(frame), WM_POLTER_OP, WPARAM(0), LPARAM(0));
        }
    }
}

pub fn frame_hwnd() -> HWND {
    let st = state();
    HWND(st.frame as *mut c_void)
}

use crate::strip::strip_h;

/// The content scale, for whoever needs to turn unscaled sizes into pixels.
pub fn scale_of() -> f64 {
    state().scale
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
            // The frame comes from an atomic, not from `state()`: this runs
            // inside `layout`'s critical section.
            let expect = crate::frame_hwnd_cached();
            logf!(
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
    // WM_SIZE back into this thread, which takes the same lock. See `state()`.
    #[allow(clippy::type_complexity)]
    let (place, hide, orphans): (
        Vec<(PaneId, HWND, TreeRect)>,
        Vec<(PaneId, HWND)>,
        Vec<PaneId>,
    ) = {
        let st = state();
        let mut orphans: Vec<PaneId> = Vec::new();
        let sh = strip_h(st.scale);
        let Some(bounds) = content_bounds(frame, sh) else {
            return;
        };
        let mut place = Vec::new();
        let mut hide = Vec::new();
        for (i, tab) in st.tabs.iter().enumerate() {
            if i != st.active {
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
        for (id, hw) in hide {
            let ok = ShowWindow(hw, SW_HIDE).as_bool();
            if verbose {
                logf!("[layout #{}] pane {} -> hide (was visible: {})", n, id, ok);
            }
        }
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
    // Where the shell should start. `None` means "wherever the core would
    // have put it"; only a reopened tab passes anything.
    cwd: Option<String>,
) -> Option<Pane> {
    let scale = state().scale;
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
    let initial_input = state().initial_input.take();
    if let Some(cmd) = &initial_input {
        sc.initial_input = cmd.as_ptr();
    }
    // Same lifetime rule as `initial_input`: the core reads the pointer
    // during `surface_new`, so the CString has to outlive that call.
    let cwd_c = match cwd {
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
    state().last_pane_cwd = cwd_c.as_ref().map(|c| c.to_string_lossy().to_string());
    if let Some(c) = &cwd_c {
        sc.working_directory = c.as_ptr();
        logf!("[pane] {} starting in {:?}", id, c);
    }

    let s = unsafe { (api().surface_new)(app, &sc) };
    if s.is_null() {
        logf!("[pane] ghostty_surface_new returned null -- destroying the window");
        unsafe {
            let _ = DestroyWindow(child);
        }
        return None;
    }
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
    let mut st = state();
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

/// A new tab whose shell starts in `cwd`. `create_tab` is this with `None`.
pub fn create_tab_in(
    frame: HWND,
    app: App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    cwd: Option<String>,
) -> bool {
    let sh = strip_h(state().scale);
    let Some(bounds) = content_bounds(frame, sh) else {
        logf!("[tab] no client area yet; not creating a tab");
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
    let Some(pane) = create_pane(frame, app, hinst, id, bounds, cwd) else {
        return false;
    };
    // **Read before the tab exists, because the core reports it before the
    // tab exists.** `pwd` can arrive during `surface_new`, which runs inside
    // `create_pane` above -- at which point there is no `Tab` to write it to.
    let pane_surface = pane.surface;
    {
        let mut st = state();
        st.tabs.push(Tab {
            id: tab_id,
            tree: Tree::with_pane(id),
            panes: vec![pane],
            focused: id,
            title: "shell".to_string(),
            color: 0,
            role: 0,
            shielded: false,
            cwd: take_pending_cwd(pane_surface),
        });
        st.active = st.tabs.len() - 1;
    }
    layout(frame);
    focus_active();
    logf!("[tab] created; count now {}", count());
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
        let st = state();
        let sh = strip_h(st.scale);
        let Some(bounds) = content_bounds(frame, sh) else {
            return;
        };
        let Some(tab) = st.tabs.get(st.active) else {
            return;
        };
        (bounds, tab.focused, tab.tree.clone())
    };

    let id = take_id();
    let new_tree = match tree.insert(id, focused, dir) {
        Ok(t) => t,
        Err(e) => {
            logf!("[split] insert failed: {:?}", e);
            return;
        }
    };
    // Only `Visible` is acceptable for a pane being created: a brand new pane
    // that the tree reports as `Hidden` would be a tree bug, and building a
    // window for it would hide that bug behind an invisible window.
    let Some((_, Placement::Visible(r))) =
        new_tree.layout(bounds).into_iter().find(|(p, _)| *p == id)
    else {
        logf!("[split] the new pane is not in the layout; refusing to create it");
        return;
    };

    let Some(pane) = create_pane(frame, app, hinst, id, r, None) else {
        return;
    };
    {
        let mut st = state();
        let a = st.active;
        if let Some(tab) = st.tabs.get_mut(a) {
            tab.tree = new_tree;
            tab.panes.push(pane);
            tab.focused = id;
        }
    }
    layout(frame);
    focus_active();
    logf!("[split] {:?} -> pane {}; {} panes in this tab", dir, id, pane_count());
}

/// Close one pane. The tab goes with it when it was the last one.
fn close_pane(frame: HWND, id: PaneId) {
    let (hwnd, surface, tab_empty, tab_idx) = {
        let mut st = state();
        let Some((idx, _)) = st
            .tabs
            .iter()
            .enumerate()
            .find(|(_, t)| t.pane(id).is_some())
        else {
            return;
        };
        let tab = &mut st.tabs[idx];
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
        if count() == 0 {
            logf!("[tab] last tab closed -> quitting");
            unsafe { PostQuitMessage(0) };
            return;
        }
        set_active(frame, active_index());
        return;
    }
    layout(frame);
    focus_active();
}

/// What the strip needs to draw itself: identity and label, in order, plus
/// which one is active.
///
/// **A snapshot, taken per paint, never cached.** The moment the strip keeps
/// its own `Vec` of labels there are two orderings that can disagree, and the
/// symptom is tabs whose order is right and whose contents are not.
pub fn strip_snapshot() -> (Vec<(TabId, String)>, usize) {
    let st = state();
    (
        st.tabs.iter().map(|t| (t.id, t.title.clone())).collect(),
        st.active,
    )
}

/// Make a tab active by identity.
pub fn activate_tab(frame: HWND, id: TabId) {
    let idx = {
        let st = state();
        st.tabs.iter().position(|t| t.id == id)
    };
    if let Some(idx) = idx {
        set_active(frame, idx);
    }
}

/// Close a tab by identity, with every pane in it.
pub fn close_tab(frame: HWND, id: TabId) {
    let idx = {
        let st = state();
        st.tabs.iter().position(|t| t.id == id)
    };
    let Some(idx) = idx else { return };
    destroy_tab_at(frame, idx);
    if count() == 0 {
        logf!("[tab] last tab closed -> quitting");
        unsafe { PostQuitMessage(0) };
        return;
    }
    set_active(frame, active_index());
}

/// Where a tab sits right now, and how many there are.
///
/// **Resolved at the moment it is asked, never cached.** Everything that
/// prints "tab 3 of 5" goes through here, including the line printed at the
/// point an action actually runs -- that line is the only external evidence
/// that the identity travelled the whole way instead of degenerating into
/// "the current one" somewhere in the middle.
pub fn index_of(id: TabId) -> Option<(usize, usize)> {
    let st = state();
    let n = st.tabs.len();
    st.tabs.iter().position(|t| t.id == id).map(|i| (i, n))
}

/// The surface of the focused pane of **a named tab** -- not the active one.
///
/// `active_surface` is the right answer for "where typing goes" and the wrong
/// answer for everything a context menu does, because the tab that was
/// right-clicked is usually not the tab that has focus.
pub fn surface_of_tab(id: TabId) -> Surface {
    let st = state();
    match st.tabs.iter().find(|t| t.id == id).and_then(|t| t.focused_pane()) {
        Some(p) => p.surface as Surface,
        None => std::ptr::null_mut(),
    }
}

/// Send a core binding action to a **named tab's** surface.
///
/// The twin of `crate::binding`, which sends to whichever surface has focus.
/// A menu that was opened on tab 3 and dispatches through `crate::binding`
/// acts on tab 1, silently, and looks entirely correct while doing it.
pub fn binding_on_tab(id: TabId, name: &str) -> bool {
    let s = surface_of_tab(id);
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
        let st = state();
        let keep = st.tabs.iter().position(|t| t.id == id);
        match keep {
            None => return,
            Some(keep) => (0..st.tabs.len()).rev().filter(|i| *i != keep).collect(),
        }
    };
    for i in victims {
        destroy_tab_at(frame, i);
    }
    set_active(frame, 0);
    logf!("[tab] closed all but {:?}; count now {}", id, count());
}

/// Close every tab to the right of one, **named by identity**. Same reason.
pub fn close_tabs_right_of(frame: HWND, id: TabId) {
    let victims: Vec<usize> = {
        let st = state();
        match st.tabs.iter().position(|t| t.id == id) {
            None => return,
            Some(at) => (at + 1..st.tabs.len()).rev().collect(),
        }
    };
    let n = victims.len();
    for i in victims {
        destroy_tab_at(frame, i);
    }
    set_active(frame, active_index().min(count().saturating_sub(1)));
    logf!("[tab] closed {} tabs right of {:?}; count now {}", n, id, count());
}

/// Record the working directory the core reported for a surface.
///
/// **Keyed on the surface the action was targeted at, never on the active
/// tab.** A background tab's shell changes directory as freely as the focused
/// one; writing every `pwd` onto whichever tab is in front would quietly give
/// tab A's directory to tab B, and the only place it would ever show is a
/// reopened tab landing somewhere the user never was.
pub fn set_cwd_for_surface(surface: Surface, cwd: String) -> bool {
    let key = surface as usize;
    let mut st = state();
    for tab in st.tabs.iter_mut() {
        if tab.panes.iter().any(|p| p.surface == key) {
            tab.cwd = Some(cwd);
            return true;
        }
    }
    // No tab yet: it is still being built. Held until `create_tab` collects it.
    st.pending_cwd.retain(|(s, _)| *s != key);
    st.pending_cwd.push((key, cwd));
    false
}

/// Take whatever `pwd` arrived for a surface before its tab existed.
fn take_pending_cwd(surface: usize) -> Option<String> {
    let mut st = state();
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
    crate::reopen::set_opener(|e| {
        post_op(Op::ReopenTab {
            cwd: e.cwd.clone(),
            title: e.title.clone(),
            index: e.index,
        });
        true
    });
}

/// Every tab's colour, by identity, in one lock.
///
/// **By identity, not a `Vec<u8>` in strip order.** A vector indexed by
/// position is the parallel array this file's rule 1 exists to forbid, and
/// the bug it writes -- colours right, order wrong -- is invisible until two
/// tabs happen to be different colours.
pub fn tab_colors() -> Vec<(TabId, u8)> {
    let st = state();
    st.tabs.iter().map(|t| (t.id, t.color)).collect()
}

/// A tab's colour, and how to set it. 0 is "none".
pub fn tab_color(id: TabId) -> u8 {
    let st = state();
    st.tabs.iter().find(|t| t.id == id).map(|t| t.color).unwrap_or(0)
}

pub fn set_tab_color(frame: HWND, id: TabId, color: u8) -> bool {
    let found = {
        let mut st = state();
        match st.tabs.iter_mut().find(|t| t.id == id) {
            Some(tab) => {
                tab.color = color;
                true
            }
            None => false,
        }
    };
    if found {
        unsafe {
            let _ = InvalidateRect(Some(frame), None, false);
        }
    }
    found
}

/// What Poltergeist has made of a tab: `(role, shielded)`.
pub fn tab_mark(id: TabId) -> (u8, bool) {
    let st = state();
    st.tabs
        .iter()
        .find(|t| t.id == id)
        .map(|t| (t.role, t.shielded))
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
pub fn mark_for_surface(surface: Surface) -> Option<(u8, bool)> {
    let key = surface as usize;
    let st = state();
    st.tabs
        .iter()
        .find(|t| t.panes.iter().any(|p| p.surface == key))
        .map(|t| (t.role, t.shielded))
}

/// Record a `poltergeist_mark` against **the surface it was sent for**.
///
/// **The surface, not the active tab.** `set_tab_title` and its neighbours
/// queue an `Op` that lands on whichever tab is active when the queue runs,
/// which is right for a title the focused shell just set and wrong here: a
/// mark can be made on a tab that is not in front (from this very menu, or
/// from a supervisor elsewhere), and applying it to the active tab would put
/// the tick on the wrong row while looking completely normal.
pub fn set_mark_for_surface(surface: Surface, role: u8, shielded: bool) -> bool {
    let key = surface as usize;
    let mut st = state();
    for tab in st.tabs.iter_mut() {
        if tab.panes.iter().any(|p| p.surface == key) {
            tab.role = role;
            tab.shielded = shielded;
            return true;
        }
    }
    false
}

/// Rename a tab. The label is the host's; the shell can still overwrite it
/// with its own title, which is the same rule macOS follows.
pub fn rename_tab(frame: HWND, id: TabId, title: String) {
    {
        let mut st = state();
        if let Some(tab) = st.tabs.iter_mut().find(|t| t.id == id) {
            tab.title = title;
        }
    }
    unsafe {
        let _ = InvalidateRect(Some(frame), None, false);
    }
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
        let mut st = state();
        let Some(from) = st.tabs.iter().position(|t| t.id == id) else {
            logf!("[tab] move: {:?} no longer exists", id);
            return;
        };
        let n = st.tabs.len();
        if n < 2 {
            return;
        }
        let to = to.min(n - 1);
        if to == from {
            return;
        }
        let tab = st.tabs.remove(from);
        st.tabs.insert(to, tab);
        // Follow the tab that moved, not the position it left.
        st.active = to;
        (from, to)
    };
    layout(frame);
    logf!("[tab] moved {:?} from {} to {}", id, moved.0, moved.1);
}

/// Panes in the active tab.
pub fn pane_count() -> usize {
    let st = state();
    st.tabs.get(st.active).map(|t| t.panes.len()).unwrap_or(0)
}

/// Give the keyboard, and with it the IME, to the active tab.
///
/// Three things have to agree about which surface is being typed into: Win32
/// focus, the core's own focus flag, and the window TSF measures the caret
/// against. They are set together here so they cannot drift apart.
pub fn focus_active() {
    let child = {
        let st = state();
        match st.tabs.get(st.active).and_then(|t| t.focused_pane()) {
            Some(p) => HWND(p.hwnd as *mut c_void),
            None => return,
        }
    };
    crate::ime_set_window(child);
    unsafe {
        let _ = SetFocus(Some(child));
    }
    let s = active_surface();
    if !s.is_null() {
        unsafe { (api().surface_set_focus)(s, true) };
    }
}

pub fn set_initial_input(cmd: &str) {
    let mut st = state();
    st.initial_input = std::ffi::CString::new(cmd).ok();
}

/// The window of the active tab, or a null HWND when there is none.
pub fn active_hwnd() -> HWND {
    let st = state();
    match st.tabs.get(st.active).and_then(|t| t.focused_pane()) {
        Some(p) => HWND(p.hwnd as *mut c_void),
        None => HWND(std::ptr::null_mut()),
    }
}

pub fn count() -> usize {
    state().tabs.len()
}

/// The surface of the focused pane of the active tab -- "where typing goes".
pub fn active_surface() -> Surface {
    let st = state();
    match st.tabs.get(st.active).and_then(|t| t.focused_pane()) {
        Some(p) => p.surface as Surface,
        None => std::ptr::null_mut(),
    }
}

/// The surface bound to a particular pane window, for that window's wndproc.
pub fn surface_of(hwnd: HWND) -> Surface {
    let key = hwnd.0 as isize;
    let st = state();
    for tab in st.tabs.iter() {
        for p in tab.panes.iter() {
            if p.hwnd == key {
                return p.surface as Surface;
            }
        }
    }
    drop(st);
    // The quick terminal's surface lives in its own module but uses this same
    // window class and window procedure, so the lookup falls through to it.
    crate::quick::surface_of(hwnd)
}

/// The pane that owns a window, so a click can move focus to it.
pub fn pane_of(hwnd: HWND) -> Option<(usize, PaneId)> {
    let key = hwnd.0 as isize;
    let st = state();
    for (i, tab) in st.tabs.iter().enumerate() {
        for p in tab.panes.iter() {
            if p.hwnd == key {
                return Some((i, p.id));
            }
        }
    }
    None
}

/// Focus follows the click: the pane clicked becomes the focused one, and its
/// tab the active one.
pub fn focus_pane_at(frame: HWND, hwnd: HWND) {
    let Some((tab_idx, id)) = pane_of(hwnd) else {
        return;
    };
    let changed = {
        let mut st = state();
        let was = (st.active, st.tabs.get(st.active).map(|t| t.focused));
        st.active = tab_idx;
        if let Some(tab) = st.tabs.get_mut(tab_idx) {
            tab.focused = id;
        }
        was != (tab_idx, Some(id))
    };
    if changed {
        layout(frame);
    }
    focus_active();
}

fn set_active(frame: HWND, idx: usize) {
    {
        let mut st = state();
        if st.tabs.is_empty() {
            return;
        }
        st.active = idx.min(st.tabs.len() - 1);
    }
    layout(frame);
    focus_active();
    logf!("[tab] active -> {} of {}", active_index() + 1, count());
}

pub fn active_index() -> usize {
    let st = state();
    st.active
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
    let (doomed, remembered): (Vec<(PaneId, isize, usize)>, Option<(String, String)>) = {
        let mut st = state();
        if idx >= st.tabs.len() {
            return;
        }
        let tab = st.tabs.remove(idx);
        // Taken while the tab is still whole; handed to `reopen.rs` below,
        // **after this guard is dropped** -- `remember` takes its own lock and
        // logs, and this file's rule is that `STATE` is held across neither.
        let remembered = Some((tab.title.clone(), tab.cwd.clone().unwrap_or_default()));
        if st.active >= st.tabs.len() && !st.tabs.is_empty() {
            st.active = st.tabs.len() - 1;
        }
        (
            tab.panes.iter().map(|p| (p.id, p.hwnd, p.surface)).collect(),
            remembered,
        )
    };
    if let Some((title, cwd)) = remembered {
        // `remember` refuses an empty cwd, loudly: a tab that reopens in the
        // wrong directory is worse than one that does not reopen at all.
        crate::reopen::remember(idx, &title, &cwd);
    }
    logf!("[close] tab index {} -> {} pane(s)", idx, doomed.len());
    for (id, hwnd, surface) in doomed {
        free_pane(id, hwnd, surface);
    }
    logf!("[close] tab index {} panes gone; laying out", idx);
    layout(frame);
    logf!("[tab] closed index {}; count now {}", idx, count());
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
pub fn surface_of_pane(pane: u64) -> Surface {
    let st = state();
    for tab in st.tabs.iter() {
        for p in tab.panes.iter() {
            if p.id == pane {
                return p.surface as Surface;
            }
        }
    }
    std::ptr::null_mut()
}

fn go_fullscreen(frame: HWND) {
    // Same rule as `layout`: every call below re-enters this thread's window
    // procedures, which take the lock. The saved placement is taken out and
    // put back in short critical sections around them, never held across one.
    let saved = { state().pre_fullscreen.take() };
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
            logf!("[win] fullscreen OFF");
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
            logf!("[win] fullscreen: GetMonitorInfoW failed, staying windowed");
            return;
        }

        // Recorded before the window changes, so a re-entrant layout during
        // SetWindowPos sees the state that matches the window it is laying out.
        state().pre_fullscreen = Some((wp, style));

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
        logf!(
            "[win] fullscreen ON  monitor {}x{}",
            r.right - r.left,
            r.bottom - r.top
        );
    }
}

/// Drain the queue. Called on the main thread only.
pub fn run_ops(frame: HWND, app: App, hinst: windows::Win32::Foundation::HINSTANCE) {
    loop {
        let op = {
            let mut st = state();
            if st.ops.is_empty() {
                return;
            }
            st.ops.remove(0)
        };

        match op {
            Op::NewTab => {
                create_tab(frame, app, hinst);
            }
            Op::ReopenTab { cwd, title, index } => {
                if !create_tab_in(frame, app, hinst, Some(cwd.clone())) {
                    // Back on the stack: `reopen_last` already popped it, and
                    // an entry dropped here would make the next undo reopen
                    // the wrong tab with nothing to say why.
                    logf!("[reopen] could not create the tab; putting {:?} back", title);
                    crate::reopen::remember(index, &title, &cwd);
                    continue;
                }
                // `create_tab_in` appends and activates, so the tab just made
                // is the last one -- and it is picked up **by identity here**,
                // before anything else can reorder, so the rename and the move
                // below cannot land on a different tab.
                let Some(id) = state().tabs.last().map(|t| t.id) else {
                    continue;
                };
                rename_tab(frame, id, title.clone());
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
                let used = state().last_pane_cwd.clone().unwrap_or_default();
                let at = index_of(id).map(|(i, _)| i).unwrap_or(0);
                logf!(
                    "[reopen] restored {:?} cwd={:?} at index {} of {}",
                    title,
                    used,
                    at,
                    count()
                );
            }
            Op::CloseTab(mode) => {
                let (active, n) = (active_index(), count());
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
                        if count() == 0 {
                            logf!("[tab] last tab closed -> quitting");
                            unsafe { PostQuitMessage(0) };
                        } else {
                            set_active(frame, active_index());
                        }
                    }
                }
            }
            Op::GotoTab(v) => {
                let n = count();
                if n == 0 {
                    continue;
                }
                let cur = active_index();
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
                    let st = state();
                    let n = st.tabs.len() as i64;
                    if n < 2 {
                        None
                    } else {
                        let cur = st.active as i64;
                        // Wrap, the way macOS does, so move_tab:1 on the last
                        // tab brings it to the front rather than doing nothing.
                        let mut to = (cur + delta) % n;
                        if to < 0 {
                            to += n;
                        }
                        st.tabs.get(st.active).map(|t| (t.id, to as usize))
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
                logf!("[win] maximize {} -> {}", zoomed, !zoomed);
            },
            Op::ResetWindowSize => {
                let init = {
                    let st = state();
                    st.initial
                };
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
                    logf!("[win] reset_window_size -> {}x{}", w, h);
                }
            }
            Op::SetTabTitle(t) => {
                {
                    let mut st = state();
                    let a = st.active;
                    if let Some(tab) = st.tabs.get_mut(a) {
                        tab.title = t.clone();
                    }
                }
                unsafe {
                    let _ = InvalidateRect(Some(frame), None, false);
                }
                logf!("[tab] set_tab_title {:?}", t);
            }
            Op::CopyTitleToClipboard => {
                let title = {
                    let st = state();
                    st.tabs
                        .get(st.active)
                        .map(|t| t.title.clone())
                        .unwrap_or_default()
                };
                let ok = copy_to_clipboard(&title).is_ok();
                logf!("[win] copy_title_to_clipboard {:?} -> {}", title, ok);
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
                    let st = state();
                    st.tabs
                        .get(st.active)
                        .and_then(|t| t.tree.focus_target(f, t.focused))
                };
                match target {
                    Some(id) => {
                        {
                            let mut st = state();
                            let a = st.active;
                            if let Some(tab) = st.tabs.get_mut(a) {
                                tab.focused = id;
                            }
                        }
                        focus_active();
                        logf!("[split] focus -> pane {}", id);
                    }
                    // No pane that way. Doing nothing is the honest answer;
                    // wrapping would put focus somewhere the user did not aim.
                    None => logf!("[split] no pane {:?} of the focused one", f),
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
                    let st = state();
                    let sh = strip_h(st.scale);
                    match (content_bounds(frame, sh), st.tabs.get(st.active)) {
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
                                let mut st = state();
                                let a = st.active;
                                if let Some(tab) = st.tabs.get_mut(a) {
                                    tab.tree = t;
                                }
                            }
                            layout(frame);
                            logf!("[split] resize pane {} by {} {:?}", focused, amount, side);
                        }
                        Err(e) => logf!("[split] resize refused: {:?}", e),
                    }
                }
            }
            Op::EqualizeSplits => {
                {
                    let mut st = state();
                    let a = st.active;
                    if let Some(tab) = st.tabs.get_mut(a) {
                        tab.tree = tab.tree.equalize();
                    }
                }
                layout(frame);
                logf!("[split] equalized");
            }
            Op::ToggleSplitZoom => {
                let zoomed = {
                    let mut st = state();
                    let a = st.active;
                    match st.tabs.get_mut(a) {
                        Some(tab) => {
                            tab.tree = tab.tree.toggle_zoom(tab.focused);
                            tab.tree.zoomed()
                        }
                        None => None,
                    }
                };
                layout(frame);
                logf!("[split] zoom -> {:?}", zoomed);
            }
            Op::ClosePane(id) => close_pane(frame, id),
            Op::ToggleQuickTerminal => crate::quick::toggle(app, hinst),
            Op::PresentTerminal => unsafe {
                let _ = ShowWindow(frame, SW_RESTORE);
                let _ = SetForegroundWindow(frame);
                logf!("[win] present_terminal");
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
pub fn apply_min_max(mmi: *mut MINMAXINFO) {
    let (min_w, min_h, max_w, max_h, scale) = {
        let st = state();
        (st.min_w, st.min_h, st.max_w, st.max_h, st.scale)
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
                        logf!(
                            "[win] surface {:?} WM_SIZE {}x{} -> set_size (#{})",
                            hwnd.0, w, h, n
                        );
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
                focus_pane_at(frame_hwnd(), hwnd);
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
