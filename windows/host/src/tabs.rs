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
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_split_tree::{Focus, NewSplit, PaneId, Rect as TreeRect, Side, Tree};

use crate::ffi::*;
use crate::{api, logf};

/// Height of the tab strip in unscaled pixels. Scaled by DPI at layout time.
pub const STRIP_H: i32 = 30;

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

/// One tab: a tree of panes, which of them has focus, and a label.
pub struct Tab {
    pub tree: Tree,
    pub panes: Vec<Pane>,
    pub focused: PaneId,
    pub title: String,
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
    MoveTab(i64),
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
    /// Handed out to panes, never reused. Starts at 1 so that 0 can mean
    /// "no pane" in the C userdata pointer.
    pub next_pane: PaneId,
    /// Typed into the first shell as if the user had typed it (`--clock`).
    /// Owned here because the core reads the pointer during `surface_new`.
    pub initial_input: Option<std::ffi::CString>,
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
            next_pane: 1,
            initial: None,
            initial_input: None,
        }
    }
}

static STATE: Mutex<State> = Mutex::new(State::new());

/// The one lock, with a tripwire.
///
/// **The invariant this file lives by: never hold this across a Win32 call
/// that can dispatch a message.** `SetWindowPos`, `ShowWindow`, `SetFocus`,
/// `DestroyWindow` and friends call a window procedure *on this thread*
/// before they return, and every window procedure here needs the same lock.
/// A `std` mutex is not re-entrant, so doing it deadlocks the main thread --
/// silently. That is what it looks like from outside: a window that never
/// paints and never responds, a process that is alive, and a log that simply
/// stops mid-function. Take a copy of what is needed, drop the guard, then
/// call Windows.
///
/// `try_lock` first so that if it ever happens again the log says so instead
/// of going quiet. Contention with the core's thread (which calls `action_cb`
/// and takes this lock briefly) is normal and momentary; a line here followed
/// by nothing at all is the re-entrant case.
pub fn state() -> std::sync::MutexGuard<'static, State> {
    match STATE.try_lock() {
        Ok(g) => return g,
        Err(std::sync::TryLockError::Poisoned(p)) => return p.into_inner(),
        Err(std::sync::TryLockError::WouldBlock) => {
            logf!("[state] lock contended; if the log stops here it is re-entrant, not slow");
        }
    }
    state()
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

fn strip_h(scale: f64) -> i32 {
    ((STRIP_H as f64) * scale).round() as i32
}

/// Put the active tab's child window over the client area below the strip,
/// and hide every other one.
/// The area a tab's panes live in: the client area minus the strip.
fn content_bounds(frame: HWND, sh: i32) -> Option<TreeRect> {
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return None;
        }
    }
    let w = (rc.right - rc.left) as f64;
    let h = ((rc.bottom - rc.top - sh).max(0)) as f64;
    Some(TreeRect::new(0.0, sh as f64, w, h))
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
    let (place, hide): (Vec<(HWND, TreeRect)>, Vec<HWND>) = {
        let st = state();
        let sh = strip_h(st.scale);
        let Some(bounds) = content_bounds(frame, sh) else {
            return;
        };
        let mut place = Vec::new();
        let mut hide = Vec::new();
        for (i, tab) in st.tabs.iter().enumerate() {
            if i != st.active {
                hide.extend(tab.panes.iter().map(|p| HWND(p.hwnd as *mut c_void)));
                continue;
            }
            let laid = tab.tree.layout(bounds);
            for p in tab.panes.iter() {
                let hw = HWND(p.hwnd as *mut c_void);
                // A pane absent from the layout is one a zoom is covering.
                match laid.iter().find(|(id, _)| *id == p.id) {
                    Some((_, r)) => place.push((hw, *r)),
                    None => hide.push(hw),
                }
            }
        }
        (place, hide)
    };

    unsafe {
        // Hide before showing, so a zoom toggle does not flash both.
        for hw in hide {
            let _ = ShowWindow(hw, SW_HIDE);
        }
        for (hw, r) in place {
            let _ = SetWindowPos(
                hw,
                None,
                r.x as i32,
                r.y as i32,
                (r.w as i32).max(1),
                (r.h as i32).max(1),
                SWP_NOZORDER | SWP_SHOWWINDOW,
            );
        }
        let _ = InvalidateRect(Some(frame), None, false);
    }
}

/// Draw the tab strip. Deliberately plain: this is the smallest thing that
/// makes "the action did something" visible in a screenshot. A real strip
/// (drag to reorder, close buttons, overflow) is its own piece of work --
/// on Windows there is no native tabbed-window control to inherit from, so
/// whatever ships here has to be drawn by hand either way.
pub fn paint_strip(frame: HWND) {
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(frame, &mut ps) };
    if hdc.is_invalid() {
        return;
    }
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(frame, &mut rc) };

    let st = state();
    let sh = strip_h(st.scale);
    let strip = RECT { left: 0, top: 0, right: rc.right, bottom: sh };

    unsafe {
        let bg = CreateSolidBrush(COLORREF(0x00201f1d));
        FillRect(hdc, &strip, bg);
        let _ = DeleteObject(bg.into());

        let n = st.tabs.len().max(1) as i32;
        let tw = (rc.right / n).min(220).max(60);
        SetBkMode(hdc, TRANSPARENT);
        for (i, t) in st.tabs.iter().enumerate() {
            let x = i as i32 * tw;
            let cell = RECT { left: x, top: 0, right: x + tw - 1, bottom: sh };
            let active = i == st.active;
            let brush = CreateSolidBrush(if active {
                COLORREF(0x00403f3d)
            } else {
                COLORREF(0x00282725)
            });
            FillRect(hdc, &cell, brush);
            let _ = DeleteObject(brush.into());
            SetTextColor(hdc, if active { COLORREF(0x00ffffff) } else { COLORREF(0x00a0a0a0) });
            let label = format!(" {}: {}", i + 1, t.title);
            let mut wide: Vec<u16> = label.encode_utf16().collect();
            let mut tr = RECT { left: x + 4, top: 4, right: x + tw - 6, bottom: sh };
            DrawTextW(
                hdc,
                &mut wide,
                &mut tr,
                DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS,
            );
        }
    }
    drop(st);
    let _ = unsafe { EndPaint(frame, &ps) };
}

/// Create one pane: a child window at the rectangle the tree gave it, plus
/// the surface bound to that window.
///
/// **The window is created at its final size and shown before
/// `ghostty_surface_new`.** That is not tidiness: the renderer sizes itself
/// from `GetClientRect` of this HWND inside `surface_new`, and a surface built
/// on a placeholder-sized window renders black with no error anywhere. See
/// docs/windows/development.md section 5.2, item 4.
fn create_pane(
    frame: HWND,
    app: App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    id: PaneId,
    r: TreeRect,
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
    logf!("[pane] {} surface = {:?}", id, s);

    Some(Pane {
        id,
        hwnd: child.0 as isize,
        surface: s as usize,
    })
}

fn take_pane_id() -> PaneId {
    let mut st = state();
    let id = st.next_pane;
    st.next_pane += 1;
    id
}

/// Create one tab: a tree with a single pane in it.
///
/// Returns false and logs if either half fails. The caller keeps running --
/// a tab that could not be made is not a reason to lose the ones that exist.
pub fn create_tab(frame: HWND, app: App, hinst: windows::Win32::Foundation::HINSTANCE) -> bool {
    let sh = strip_h(state().scale);
    let Some(bounds) = content_bounds(frame, sh) else {
        logf!("[tab] no client area yet; not creating a tab");
        return false;
    };
    let id = take_pane_id();
    let Some(pane) = create_pane(frame, app, hinst, id, bounds) else {
        return false;
    };
    {
        let mut st = state();
        st.tabs.push(Tab {
            tree: Tree::with_pane(id),
            panes: vec![pane],
            focused: id,
            title: "shell".to_string(),
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

    let id = take_pane_id();
    let new_tree = match tree.insert(id, focused, dir) {
        Ok(t) => t,
        Err(e) => {
            logf!("[split] insert failed: {:?}", e);
            return;
        }
    };
    let Some((_, r)) = new_tree.layout(bounds).into_iter().find(|(p, _)| *p == id) else {
        logf!("[split] the new pane is not in the layout; refusing to create it");
        return;
    };

    let Some(pane) = create_pane(frame, app, hinst, id, r) else {
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

    unsafe {
        (api().surface_free)(surface as Surface);
        let _ = DestroyWindow(HWND(hwnd as *mut c_void));
    }
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
    std::ptr::null_mut()
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
fn destroy_tab_at(frame: HWND, idx: usize) {
    let doomed: Vec<(isize, usize)> = {
        let mut st = state();
        if idx >= st.tabs.len() {
            return;
        }
        let tab = st.tabs.remove(idx);
        if st.active >= st.tabs.len() && !st.tabs.is_empty() {
            st.active = st.tabs.len() - 1;
        }
        tab.panes.iter().map(|p| (p.hwnd, p.surface)).collect()
    };
    for (hwnd, surface) in doomed {
        unsafe {
            (api().surface_free)(surface as Surface);
            let _ = DestroyWindow(HWND(hwnd as *mut c_void));
        }
    }
    layout(frame);
    logf!("[tab] closed index {}; count now {}", idx, count());
}

fn copy_to_clipboard(text: &str) -> bool {
    use windows::Win32::System::DataExchange::*;
    use windows::Win32::System::Memory::*;
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    wide.push(0);
    let bytes = wide.len() * 2;
    unsafe {
        if OpenClipboard(None).is_err() {
            return false;
        }
        let _ = EmptyClipboard();
        let h = match GlobalAlloc(GMEM_MOVEABLE, bytes) {
            Ok(h) => h,
            Err(_) => {
                let _ = CloseClipboard();
                return false;
            }
        };
        let p = GlobalLock(h);
        if p.is_null() {
            let _ = CloseClipboard();
            return false;
        }
        std::ptr::copy_nonoverlapping(wide.as_ptr(), p as *mut u16, wide.len());
        let _ = GlobalUnlock(h);
        // CF_UNICODETEXT. Ownership of `h` passes to the clipboard on success.
        let ok = SetClipboardData(13u32, Some(windows::Win32::Foundation::HANDLE(h.0))).is_ok();
        let _ = CloseClipboard();
        ok
    }
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
            Op::MoveTab(delta) => {
                let n = count();
                if n < 2 {
                    continue;
                }
                let cur = active_index() as i64;
                // Wrap, the way macOS does, so move_tab:1 on the last tab
                // brings it to the front rather than doing nothing.
                let mut to = (cur + delta) % (n as i64);
                if to < 0 {
                    to += n as i64;
                }
                let to = to as usize;
                {
                    let mut st = state();
                    let t = st.tabs.remove(cur as usize);
                    st.tabs.insert(to, t);
                    st.active = to;
                }
                layout(frame);
                logf!("[tab] moved {} -> {}", cur + 1, to + 1);
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
                let ok = copy_to_clipboard(&title);
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
pub fn apply_min_max(frame: HWND, mmi: *mut MINMAXINFO) {
    let (min_w, min_h, max_w, max_h, scale) = {
        let st = state();
        (st.min_w, st.min_h, st.max_w, st.max_h, st.scale)
    };
    if min_w == 0 && min_h == 0 && max_w == 0 && max_h == 0 {
        return;
    }
    unsafe {
        let style = GetWindowLongPtrW(frame, GWL_STYLE) as u32;
        let exstyle = GetWindowLongPtrW(frame, GWL_EXSTYLE) as u32;
        let mut rc = RECT {
            left: 0,
            top: 0,
            right: min_w as i32,
            bottom: min_h as i32 + strip_h(scale),
        };
        let _ = AdjustWindowRectEx(
            &mut rc,
            WINDOW_STYLE(style),
            false,
            WINDOW_EX_STYLE(exstyle),
        );
        if min_w > 0 || min_h > 0 {
            (*mmi).ptMinTrackSize.x = rc.right - rc.left;
            (*mmi).ptMinTrackSize.y = rc.bottom - rc.top;
        }
        // A zero maximum means "no maximum" -- that is what the core sends
        // today, and clamping to zero would make the window unresizable.
        if max_w > 0 && max_h > 0 {
            (*mmi).ptMaxTrackSize.x = max_w as i32;
            (*mmi).ptMaxTrackSize.y = max_h as i32 + strip_h(scale);
        }
    }
}

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
                        logf!("[win] surface WM_SIZE {}x{} -> set_size (#{})", w, h, n);
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
