//! The control room's chat page as a **native read-only window** (task
//! 2802, W2b).
//!
//! This replaces the `polter +chat` terminal the page used to run: one
//! Win32 child window per control-room panel, never a Ghostty surface, and
//! never a second route back to the terminal. It speaks to the core only
//! through W1 (`chat_read`) and holds one group's rows through W2a
//! (`chat_feed`); that wiring and the rows are the next step of this
//! slice. What is here now is the window and the route: created, placed,
//! hidden, focused and destroyed where the old chat's were, with no shell,
//! no CLI and no surface.
//!
//! **One child per panel.** The chat page shows the group its page is on;
//! switching group hides the old window rather than ending anything, as
//! the terminal chat did. Past four kept, the one looked at longest ago is
//! destroyed.
//!
//! **The keyboard.** A native window takes the keyboard for its own
//! read-only scrolling and copying; it is never lent to a supervisor and
//! it is not a pane (`tabs::surface_of` answers null for it). Hidden with
//! the keyboard in it, it hands the keyboard back to the panel first, so
//! no key goes to something nobody can see.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::sync::atomic::{AtomicIsize, Ordering};

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, GetDC, GetTextMetricsW,
    IntersectClipRect, InvalidateRect, ReleaseDC, RestoreDC, SaveDC, SelectObject, SetBkMode,
    SetTextColor, DT_CALCRECT, DT_LEFT, DT_NOPREFIX, DT_SINGLELINE, DT_WORDBREAK, HDC, HFONT,
    PAINTSTRUCT, TEXTMETRICW, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetCapture, GetFocus, ReleaseCapture, SetCapture, SetFocus, VK_END, VK_HOME, VK_LEFT, VK_NEXT,
    VK_PRIOR, VK_RIGHT,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_chat_markdown::cache::Key as MdKey;
use polter_chat_markdown::coordinator::{Completion, Owner};
use polter_chat_markdown::layout::{self as md_layout, Face, FontKind, Fonts, Inputs, Plan};
use polter_control_room::look;
use polter_split_tree::Rect as TreeRect;

use crate::chat_feed::{self, Action, Envelope, Feed, Kind};
use crate::chat_read::{self, Transport, TransportError};
use crate::ffi::Surface;
use crate::{plogf, wlogf};
use polter_control_room::chat_rows::{
    self, FontKey, MeasureError, Measured, Metrics, RowIdentity, RowInput, Sight,
};

/// The most kept open at once.
pub const KEPT: usize = 4;

/// The class of the native chat child. **Not `PolterSurface`**: this window
/// has no surface behind it, and the shared window procedure must never be
/// asked to draw or type for it.
const CLASS: PCWSTR = w!("PolterChatNative");

struct Chat {
    group: String,
    hwnd: isize,
    /// Its size when it was last placed, in pixels.
    size: (i32, i32),
    /// When it was last in front: what decides which goes past `KEPT`.
    seen: std::time::Instant,
    shown: bool,
    /// The one read-only state machine for this group. Kept while the page
    /// is hidden (its rows stay), stopped so it asks nothing.
    feed: Option<Feed>,
    /// A cancel the feed handed back while a reply was being applied. Sent
    /// on the next tick, never recursively inside the reply.
    pending_cancel: Option<String>,
    /// The measured rows, kept across paints: a paint measures nothing
    /// unless the body, width or DPI changed.
    layout: chat_rows::Layout,
    /// Pixels scrolled down from the first row.
    scroll: i32,
    /// **This view's own identity**, not its HWND: a handle can be reused,
    /// and a late Markdown answer must not land in whatever holds it next.
    view: u64,
    /// Measured plans for the messages in sight, and the width/DPI/font
    /// they were measured for. **Bounded by what is on screen**: an entry
    /// whose message left, or whose document left the cache, is dropped
    /// and its `Arc` released.
    plans: Vec<ViewPlan>,
    plan_width: i32,
    plan_dpi: i32,
    plan_font: u64,
    /// The block whose horizontal view the keyboard owns, and the mouse
    /// drag. Both bind the **complete message/plan identity** and a block;
    /// never a screen position or a reused block number alone.
    hfocus: Option<chat_rows::DragTarget>,
    hdrag: chat_rows::DragState,
}

/// One measured message.
struct ViewPlan {
    /// The feed's stable row id. **Not the canonical anchor**: a live row
    /// keeps its `l:` id when history later names it by its `p:` anchor.
    row_id: String,
    group: String,
    generation: u64,
    /// The canonical anchor this plan's Markdown key used.
    anchor: String,
    version: u64,
    doc_ptr: usize,
    /// The width/DPI/font this plan was measured for. Paint compares them
    /// with its own current values, so a resize before the next tick
    /// cannot draw an old plan at a new size.
    width: i32,
    dpi: i32,
    font: u64,
    /// Held only while this message is in sight.
    doc: std::sync::Arc<polter_chat_markdown::Document>,
    plan: std::sync::Arc<Plan>,
    /// **Horizontal offsets by block index**, this message's tables and
    /// code blocks, independent of each other. Kept with the plan: a new
    /// document is a new plan, and a row that leaves sight drops both --
    /// the identity is the message, never a screen position.
    hscroll: Vec<(usize, i32)>,
}

impl ViewPlan {
    fn hoffset(&self, block: usize) -> i32 {
        self.hscroll
            .iter()
            .find(|(b, _)| *b == block)
            .map_or(0, |(_, o)| *o)
    }

    fn set_hoffset(&mut self, block: usize, offset: i32) {
        let Some(horiz) = self.plan.horizontal(block) else {
            return;
        };
        let offset = horiz.clamp(offset);
        if let Some(slot) = self.hscroll.iter_mut().find(|(b, _)| *b == block) {
            slot.1 = offset;
        } else {
            self.hscroll.push((block, offset));
        }
    }
}

static NEXT_VIEW: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// The child window's tick: one ordinary read at most, and only while the
/// page is active.
const CHAT_TIMER: usize = 1;
/// **One ordinary read per 200 ms at most** (contract §3). `chat_feed`'s own
/// cadence is 200 ms for a pending page and 2 s for live; the host looks no
/// more often than that, so two due clocks cannot be read on adjacent ticks.
const TICK_MS: u32 = 200;

thread_local! {
    static CHATS: RefCell<Vec<Chat>> = const { RefCell::new(Vec::new()) };
    /// A group whose window could not be made: not tried again until
    /// another is wanted, or every layout would try (`settled`).
    static FAILED: RefCell<Option<String>> = const { RefCell::new(None) };
    /// The keyboard was last in a chat: given back to the one in front when
    /// the control room is.
    static KEYBOARD: Cell<bool> = const { Cell::new(false) };
    /// The focus is being moved off a chat that is being hidden: that move
    /// is not the person leaving the chat.
    static HIDING: Cell<bool> = const { Cell::new(false) };
}

/// Registered once per process.
fn class() -> bool {
    static ONCE: std::sync::Once = std::sync::Once::new();
    static OK: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    ONCE.call_once(|| {
        let hinst: HINSTANCE = unsafe { GetModuleHandleW(None) }
            .map(Into::into)
            .unwrap_or_default();
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst,
            lpszClassName: CLASS,
            // The window paints itself: the rows are drawn by this module,
            // not by a background brush.
            ..Default::default()
        };
        OK.store(unsafe { RegisterClassExW(&wc) } != 0, Ordering::Release);
    });
    OK.load(Ordering::Acquire)
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_ERASEBKGND => LRESULT(1),
        WM_TIMER if wp.0 == CHAT_TIMER => {
            tick(hwnd);
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
            let line = Metrics::for_dpi(crate::dpi_for(hwnd) as i32).line;
            // Three lines a notch, as the control room's list scrolls. The
            // wheel is the page's vertical scroll only: a table's own
            // horizontal rail never takes it.
            scroll_by(hwnd, (delta / 120) * line * 3);
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            let x = (lp.0 & 0xFFFF) as i16 as i32;
            let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
            hscroll_press(hwnd, x, y);
            // **A click is how the person says "keys go here".** This is
            // the same entry a terminal pane's click uses; its CHATS borrow
            // has ended above, so the keyboard can move now.
            take_keyboard(hwnd);
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            let x = (lp.0 & 0xFFFF) as i16 as i32;
            if hscroll_drag(hwnd, x) {
                LRESULT(0)
            } else {
                unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
            }
        }
        WM_LBUTTONUP => {
            hscroll_end(hwnd);
            LRESULT(0)
        }
        WM_CAPTURECHANGED => {
            // The mouse was taken away mid-drag: forget only our own drag
            // and focus; the other window's capture is not ours to release.
            hscroll_capture_lost(hwnd);
            LRESULT(0)
        }
        WM_CANCELMODE => {
            hscroll_cancel(hwnd);
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let mut client = windows::Win32::Foundation::RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut client) };
            let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
            let page = (client.bottom - client.top - metrics.pad * 2).max(metrics.line);
            match wp.0 as u16 {
                key if key == VK_LEFT.0 => {
                    hscroll_key(hwnd, -metrics.line * 2);
                    LRESULT(0)
                }
                key if key == VK_RIGHT.0 => {
                    hscroll_key(hwnd, metrics.line * 2);
                    LRESULT(0)
                }
                key if key == VK_PRIOR.0 => {
                    scroll_by(hwnd, page);
                    LRESULT(0)
                }
                key if key == VK_NEXT.0 => {
                    scroll_by(hwnd, -page);
                    LRESULT(0)
                }
                key if key == VK_HOME.0 => {
                    scroll_to(hwnd, 0);
                    LRESULT(0)
                }
                key if key == VK_END.0 => {
                    scroll_to(hwnd, i32::MAX);
                    LRESULT(0)
                }
                _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
            }
        }
        WM_RBUTTONUP => {
            // **Copy the message's own words**, and nothing else: no
            // Ctrl+C passthrough, no terminal behind the page.
            let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
            if let Some(text) = row_at(hwnd, y) {
                let _ = crate::tabs::copy_to_clipboard(&text);
            }
            LRESULT(0)
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let dc = unsafe { BeginPaint(hwnd, &mut ps) };
            paint(hwnd, dc, &ps);
            let _ = unsafe { EndPaint(hwnd, &ps) };
            LRESULT(0)
        }
        WM_SETFOCUS => {
            if !HIDING.with(|h| h.get()) {
                KEYBOARD.with(|k| k.set(true));
            }
            LRESULT(0)
        }
        WM_KILLFOCUS => {
            KEYBOARD.with(|k| k.set(false));
            LRESULT(0)
        }
        // The read-only scrolling and copying of this window arrive with
        // the rows (W2b's next step); nothing here is a terminal.
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

/// Whether `group`'s chat ended and has not been asked for again. A native
/// page has no program to end; a failure is a state on the rows, not this.
pub fn ended(_group: &str) -> bool {
    false
}

/// The person asked for `group`'s chat again.
pub fn reopen(group: &str) {
    // process-wide: the chat is the control room's, of which the process has one
    plogf!("[chat-native] chat for {:?} asked for again", group);
}

/// Whether `hwnd` is a chat's window.
pub fn owns(hwnd: HWND) -> bool {
    let key = hwnd.0 as isize;
    CHATS.with(|c| {
        c.try_borrow()
            .is_ok_and(|c| c.iter().any(|x| x.hwnd == key))
    })
}

/// A click on a chat: the keyboard goes into it.
pub fn take_keyboard(hwnd: HWND) {
    // process-wide: the chat is the control room's, of which the process has one
    plogf!(
        "[chat-native] click on chat window {:?}: the keyboard goes into it",
        hwnd.0
    );
    crate::with_host_shuffle(|| unsafe {
        let _ = SetFocus(Some(hwnd));
    });
}

/// A window of this thread took the keyboard from `from`.
pub fn focus_went_to(hwnd: HWND, from: HWND) {
    if HIDING.with(|h| h.get()) {
        return;
    }
    if owns(from) {
        KEYBOARD.with(|k| k.set(false));
    }
    if owns(hwnd) {
        KEYBOARD.with(|k| k.set(true));
    }
}

/// The group whose chat is in front now, when one is.
pub fn shown_group() -> Option<String> {
    CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| c.iter().find(|x| x.shown).map(|x| x.group.clone()))
    })
}

/// The chat in front, when the keyboard was last in it.
pub fn keyboard_hwnd() -> Option<isize> {
    if !KEYBOARD.with(|k| k.get()) {
        return None;
    }
    CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| c.iter().find(|x| x.shown).map(|x| x.hwnd))
    })
}

/// Whether what is in front is what `want` says: that chat, or none.
pub fn settled(want: &Option<String>) -> bool {
    if *want == shown_group() {
        return true;
    }
    match want {
        Some(g) => FAILED.with(|f| f.borrow().as_deref() == Some(g.as_str())),
        None => false,
    }
}

/// **No surface, ever.** The chat is not a terminal and has no terminal id;
/// a caller asking the shared lookup for one finds nothing.
pub fn surface_of(_hwnd: HWND) -> Surface {
    std::ptr::null_mut()
}

fn create(frame: HWND, group: &str, r: TreeRect) -> Option<Chat> {
    if !class() {
        wlogf!(frame, "[chat-native] its window class is not registered");
        return None;
    }
    let hinst = unsafe {
        windows::Win32::Foundation::HINSTANCE(
            GetWindowLongPtrW(frame, GWLP_HINSTANCE) as *mut c_void
        )
    };
    let (x, y, w, h) = (
        r.x as i32,
        r.y as i32,
        (r.w as i32).max(1),
        (r.h as i32).max(1),
    );
    let child = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            CLASS,
            w!(""),
            WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
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
        Ok(child) => child,
        Err(_) => {
            wlogf!(
                frame,
                "[chat-native] its window could not be made for {:?}",
                group
            );
            return None;
        }
    };
    wlogf!(
        frame,
        "[chat-native] chat for {:?}: native hwnd {:?}",
        group,
        child.0
    );
    Some(Chat {
        group: group.to_owned(),
        hwnd: child.0 as isize,
        size: (w, h),
        seen: std::time::Instant::now(),
        shown: false,
        feed: Some(Feed::new(next_request_id)),
        pending_cancel: None,
        layout: chat_rows::Layout::new(),
        scroll: 0,
        view: NEXT_VIEW.fetch_add(1, Ordering::Relaxed),
        plans: Vec::new(),
        plan_width: 0,
        plan_dpi: 0,
        plan_font: 0,
        hfocus: None,
        hdrag: chat_rows::DragState::default(),
    })
}

/// Put one away: its window destroyed, and nothing else in the process
/// touched.
fn close(mut chat: Chat, why: &str) {
    let hwnd = HWND(chat.hwnd as *mut c_void);
    // **A window that goes takes its reading with it**: the feed is
    // stopped before the window dies, and a known job is cancelled.
    let mut cancels: Vec<String> = Vec::new();
    let leave = chat.feed.as_ref().map(|feed| Owner {
        view: chat.view,
        epoch: feed.generation(),
    });
    if let Some(pending) = chat.pending_cancel.take() {
        cancels.push(pending);
    }
    if let Some(feed) = chat.feed.as_mut() {
        if let Some(Action::Cancel { request }) = feed.stop(now_ms()) {
            cancels.push(request);
        }
    }
    // process-wide: a chat belongs to the control room, of which the process has one
    plogf!("[chat-native] chat for {:?} closed: {}", chat.group, why);
    let _ = unsafe { KillTimer(Some(hwnd), CHAT_TIMER) };
    unsafe {
        crate::with_host_shuffle(|| {
            let _ = ShowWindow(hwnd, SW_HIDE);
        });
        let _ = DestroyWindow(hwnd);
    }
    for request in cancels {
        let _ = send_request(&request);
    }
    if let Some(owner) = leave {
        crate::markdown_service::leave(owner);
    }
}

/// After `tabs::layout` has placed the panes of `frame`: the chat of the
/// group whose chat page is in front goes at `at`, and every other chat is
/// hidden. `at` is none when the control room is not in front, or not in
/// this frame.
pub fn place(frame: HWND, at: Option<TreeRect>) {
    if let Some(panel) = crate::control_room::panel_hwnd() {
        PANEL.store(panel.0 as isize, Ordering::Release);
    }
    // **In sight means in sight**: the room's page, its tab and every
    // ancestor window shown, the frame not minimised (`IsWindowVisible`
    // stays true for an iconic window), and a rectangle that can hold
    // rows. Anything else is treated exactly like "not in front": the
    // chat is hidden and, once the feed is wired, stopped.
    let page = crate::control_room::chat_group();
    let at = at.filter(|r| {
        chat_rows::in_sight(&Sight {
            room_tab: true,
            chat_page: page.is_some(),
            ancestors_visible: ancestors_visible(frame),
            iconic: unsafe { IsIconic(frame).as_bool() },
            rect_w: r.w,
            rect_h: r.h,
        })
    });
    let wanted = at
        .and(page)
        .filter(|_| crate::control_room::frame_of_panel() == Some(frame));
    // Made outside the borrow: creating a window sends messages.
    if let (Some(group), Some(r)) = (wanted.as_ref(), at) {
        let has = CHATS.with(|c| c.borrow().iter().any(|x| &x.group == group));
        let failed = FAILED.with(|f| f.borrow().as_deref() == Some(group.as_str()));
        if !has && !failed {
            match create(frame, group, r) {
                Some(chat) => CHATS.with(|c| c.borrow_mut().push(chat)),
                None => FAILED.with(|f| *f.borrow_mut() = Some(group.clone())),
            }
        }
    }
    if wanted.is_none() || FAILED.with(|f| f.borrow().as_ref() != wanted.as_ref()) {
        FAILED.with(|f| *f.borrow_mut() = None);
    }

    let mut show: Vec<(isize, TreeRect, bool)> = Vec::new();
    let mut hide: Vec<isize> = Vec::new();
    let mut gone: Vec<Chat> = Vec::new();
    let mut cancels: Vec<String> = Vec::new();
    let mut leaves: Vec<Owner> = Vec::new();
    let mut release_input: Vec<isize> = Vec::new();
    let mut repaint: Vec<isize> = Vec::new();
    let now = now_ms();
    CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let seen = std::time::Instant::now();
        for x in c.iter_mut() {
            match (wanted.as_ref(), at) {
                (Some(g), Some(r)) if *g == x.group => {
                    let size = ((r.w as i32).max(1), (r.h as i32).max(1));
                    let resized = size != x.size;
                    x.size = size;
                    x.seen = seen;
                    let entering = !x.shown;
                    x.shown = true;
                    show.push((x.hwnd, r, resized));
                    // **Entering the page starts the one feed**; a repeat
                    // sync is a no-op inside `start`.
                    if entering {
                        if let Some(feed) = x.feed.as_mut() {
                            if let Some(id) = next_request_id() {
                                feed.start(&x.group, id, now);
                            }
                        }
                        let _ = unsafe {
                            SetTimer(Some(HWND(x.hwnd as *mut c_void)), CHAT_TIMER, TICK_MS, None)
                        };
                    }
                }
                _ => {
                    if x.shown {
                        // **Leaving it (another group, another page, the
                        // room hidden or minimised) stops the reads**, and
                        // a known job is cancelled once. A cancel the feed
                        // already owed is drained here too: after the timer
                        // is killed no tick will come for it.
                        if let Some(feed) = x.feed.as_ref() {
                            leaves.push(Owner {
                                view: x.view,
                                epoch: feed.generation(),
                            });
                        }
                        // **A page nobody sees keeps no plans or document
                        // Arcs**; showing it again publishes fresh ones.
                        x.plans.clear();
                        // A drag or focus bound to one of those plans is
                        // cancelled; both requested effects come back and
                        // are executed after the borrow.
                        let action = chat_rows::cancel_input(&mut x.hdrag, &mut x.hfocus);
                        if action.release_own_capture {
                            release_input.push(x.hwnd);
                        }
                        if action.invalidate {
                            repaint.push(x.hwnd);
                        }
                        if let Some(pending) = x.pending_cancel.take() {
                            cancels.push(pending);
                        }
                        if let Some(feed) = x.feed.as_mut() {
                            if let Some(Action::Cancel { request }) = feed.stop(now) {
                                cancels.push(request);
                            }
                        }
                        let _ = unsafe { KillTimer(Some(HWND(x.hwnd as *mut c_void)), CHAT_TIMER) };
                        hide.push(x.hwnd);
                    }
                    x.shown = false;
                }
            }
        }
        while c.len() > KEPT {
            let Some(oldest) = c
                .iter()
                .enumerate()
                .filter(|(_, x)| !x.shown)
                .min_by_key(|(_, x)| x.seen)
                .map(|(i, _)| i)
            else {
                break;
            };
            gone.push(c.remove(oldest));
        }
    });

    // Cancels taken under the borrow are sent after it: one ABI call at a
    // time, never inside the state machine's own bookkeeping.
    for request in cancels {
        let _ = send_request(&request);
    }
    // And the Markdown demand of a page nobody can see any more is
    // withdrawn outside the borrow.
    for owner in leaves {
        crate::markdown_service::leave(owner);
    }
    for hwnd in release_input {
        release_own_capture(HWND(hwnd as *mut c_void));
    }
    for hwnd in repaint {
        let _ = unsafe { InvalidateRect(Some(HWND(hwnd as *mut c_void)), None, false) };
    }

    // A hidden chat with the keyboard in it gives it to the panel first.
    let focused = unsafe { GetFocus() }.0 as isize;
    if hide.iter().any(|h| *h == focused) {
        if let Some(panel) = crate::control_room::panel_hwnd() {
            HIDING.with(|h| h.set(true));
            unsafe {
                let _ = SetFocus(Some(panel));
            }
            HIDING.with(|h| h.set(false));
            wlogf!(
                frame,
                "[chat-native] the keyboard was in a chat being hidden; given to the panel"
            );
        }
    }
    unsafe {
        crate::with_host_shuffle(|| {
            for hwnd in &hide {
                let _ = ShowWindow(HWND(*hwnd as *mut c_void), SW_HIDE);
            }
        });
        for (hwnd, r, _resized) in show {
            let hw = HWND(hwnd as *mut c_void);
            if GetParent(hw).ok() != Some(frame) {
                let _ = SetParent(hw, Some(frame));
                wlogf!(frame, "[chat-native] chat moved into this window");
            }
            let (w, h) = ((r.w as i32).max(1), (r.h as i32).max(1));
            let res = SetWindowPos(
                hw,
                Some(HWND_TOP),
                r.x as i32,
                r.y as i32,
                w,
                h,
                SWP_SHOWWINDOW | SWP_NOACTIVATE,
            );
            wlogf!(
                frame,
                "[chat-native] chat -> {}x{}+{}+{} ({})",
                w,
                h,
                r.x as i32,
                r.y as i32,
                if res.is_ok() {
                    "ok"
                } else {
                    "SetWindowPos FAILED"
                }
            );
        }
    }
    if let Some(chat) = keyboard_hwnd() {
        let panel = crate::control_room::panel_hwnd();
        let focused = unsafe { GetFocus() };
        if panel.is_some() && panel == Some(focused) {
            let hw = HWND(chat as *mut c_void);
            crate::with_host_shuffle(|| unsafe {
                let _ = SetFocus(Some(hw));
            });
            wlogf!(
                frame,
                "[chat-native] the keyboard was in this chat when it was hidden; given back to it"
            );
        }
    }
    for chat in gone {
        close(chat, "more than four kept; looked at longest ago");
    }
}

/// Whether `frame` and every window above it is shown. Minimised is its own
/// fact (`Sight::iconic`): `IsWindowVisible` stays true for an iconic frame.
fn ancestors_visible(frame: HWND) -> bool {
    if !unsafe { IsWindowVisible(frame) }.as_bool() {
        return false;
    }
    let mut at = frame;
    while let Ok(parent) = unsafe { GetParent(at) } {
        if parent.0.is_null() {
            break;
        }
        if !unsafe { IsWindowVisible(parent) }.as_bool() {
            return false;
        }
        at = parent;
    }
    true
}

/// The groups whose chats are kept: one whose group `alive` no longer
/// knows is closed.
pub fn prune(alive: impl Fn(&str) -> bool) {
    let gone: Vec<Chat> = CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let (keep, gone): (Vec<Chat>, Vec<Chat>) = c.drain(..).partition(|x| alive(&x.group));
        *c = keep;
        gone
    });
    for chat in gone {
        close(chat, "its group is gone");
    }
}

/// Every chat, when the control room's panel goes.
pub fn close_all() {
    let all: Vec<Chat> = CHATS.with(|c| c.borrow_mut().drain(..).collect());
    for chat in all {
        close(chat, "the control room closed");
    }
}

/// The panel whose chats these are, for the keyboard give-back. Kept here
/// as the old module kept it: process-wide, and only ever set by `place`.
static PANEL: AtomicIsize = AtomicIsize::new(0);

/// Draw the page from the feed's own rows. **Nothing here reads the core
/// or measures text that has not changed**: the layout keeps each row's
/// height until its version, the width or the DPI moves, and the paint
/// offers only the rows in sight plus one either side.
fn paint(hwnd: HWND, dc: HDC, ps: &PAINTSTRUCT) {
    let _ = ps;
    let dark = unsafe { crate::termcolor::chrome(GetAncestor(hwnd, GA_ROOT)).dark };
    let theme = look::theme(dark);
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    unsafe {
        let brush = CreateSolidBrush(crate::control_room::rgb(theme.terminal_background));
        FillRect(dc, &client, brush);
        let _ = DeleteObject(brush.into());
    }

    let dpi = crate::dpi_for(hwnd);
    let metrics = Metrics::for_dpi(dpi as i32);
    let font = crate::uifont::make(
        dpi as i32,
        look::font::BODY.round() as i32,
        look::font::WEIGHT_BODY.round() as i32,
        crate::uifont::ui_face(),
    );
    let old = unsafe { SelectObject(dc, font.into()) };
    unsafe {
        SetBkMode(dc, TRANSPARENT);
    }

    let key = hwnd.0 as isize;
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return;
        };
        let Chat {
            group,
            feed,
            layout,
            scroll,
            plans,
            ..
        } = chat;
        let Some(feed) = feed.as_ref() else {
            return;
        };

        let left = client.left + metrics.pad;
        let width = (client.right - client.left - metrics.pad * 2).max(1);
        let view_h = (client.bottom - client.top - metrics.pad * 2).max(1);

        let mut top = client.top + metrics.pad;
        // **Loading is not empty, and a raw code is not product copy.** The
        // feed's state picks the sentence; the code stays in the log.
        let note = if let Some(code) = feed.trouble() {
            Some(crate::i18n::tr(chat_rows::trouble_word(code)))
        } else if feed.rows().is_empty() {
            let load = match feed.load() {
                chat_feed::Load::Loading => chat_rows::Load::Loading,
                chat_feed::Load::Empty => chat_rows::Load::Empty,
                chat_feed::Load::Ready => chat_rows::Load::Ready,
            };
            chat_rows::load_word(load).map(crate::i18n::tr)
        } else {
            None
        };
        if let Some(note) = note {
            top = draw_text(dc, &note, left, top, width, theme.text_secondary);
        }

        // The rows themselves, drawn from the cached heights.
        let range = layout.visible(*scroll, view_h - (top - (client.top + metrics.pad)).max(0));
        for i in range {
            let Some(row) = feed.rows().get(i) else {
                continue;
            };
            let measured = &layout.rows()[i];
            let y = top + measured.top - *scroll;
            if y + measured.height <= client.top || y >= client.bottom {
                continue;
            }
            let author = if row.message.author.is_empty() {
                row.message.from.as_str()
            } else {
                row.message.author.as_str()
            };
            draw_author(
                dc,
                author,
                left,
                y,
                width,
                measured.author_height,
                theme.text_secondary,
            );
            let text_top = y + measured.author_height;
            // **The measured block is the block**: no clamp to the model's
            // pitch, and the only edge that cuts it is the window itself.
            let text_bottom = text_top.saturating_add(measured.text_height);
            if text_bottom > client.top {
                unsafe {
                    SetTextColor(dc, crate::control_room::rgb(theme.text));
                }
                if measured.failed {
                    draw_author(
                        dc,
                        &crate::i18n::tr(chat_rows::msg::MEASURE_FAILED),
                        left,
                        text_top,
                        width,
                        metrics.line,
                        theme.text_secondary,
                    );
                } else {
                    // **Paint consumes a plan the tick measured** (B2):
                    // never lays text out here. Anything without one --
                    // pending, fallback, evicted -- keeps the verified
                    // original-text path.
                    // **Only a plan matching the published height is
                    // drawn**: a stale or raw row shows its original text
                    // inside the published rectangle, clipped to the row
                    // and the window.
                    let row_bottom = text_bottom.min(client.bottom).max(text_top);
                    // **The plan's own metadata must be current**: a
                    // resize or DPI move before the next tick leaves the
                    // old plan in the list, and it must not be drawn at
                    // the new size. Look up by the feed's stable row id,
                    // then let the published identity decide.
                    let font_id = plan_font_id(dpi as i32);
                    let found = plans.iter().find(|p| {
                        p.row_id == row.id
                            && p.anchor == row.message.anchor
                            && p.version == row.message.content_version
                            && p.group == *group
                            && p.generation == feed.generation()
                            && p.width == width
                            && p.dpi == dpi as i32
                            && p.font == font_id
                    });
                    let current = found.map(|entry| chat_rows::Identity {
                        group: group.clone(),
                        generation: feed.generation(),
                        anchor: row.message.anchor.clone(),
                        version: row.message.content_version,
                        doc: entry.doc_ptr,
                        width,
                        dpi: dpi as i32,
                        font: font_id,
                    });
                    match found {
                        Some(entry) if current.is_some_and(|c| measured.draws(&c)) => draw_plan(
                            dc,
                            &entry.doc,
                            &entry.plan,
                            &entry.hscroll,
                            dpi as i32,
                            text_top,
                            left,
                            client.right,
                            width,
                            row_bottom,
                            *theme,
                        ),
                        _ => {
                            draw_block(dc, &row.message.text, left, text_top, width, row_bottom)
                        }
                    }
                }
            }
        }
    });

    unsafe {
        SelectObject(dc, old);
        let _ = DeleteObject(font.into());
    }
}

/// Measure one row with the font already selected in `dc` and **the same
/// flags its draw will use**: `single_line()|DT_CALCRECT` for the author,
/// `wrap()|DT_CALCRECT` for the body at the same pixel width. An empty body
/// is one line of that font, taken from a one-line sample; a measurement
/// that comes back non-positive is an explicit failure, never a silent
/// zero height.
fn measure_row(dc: HDC, author: &str, text: &str, width: i32) -> Result<Measured, MeasureError> {
    let author_height =
        unsafe { calc_height(dc, author, width.max(1), DrawTextFlags::single_line()) };
    let sample;
    let body = if text.is_empty() {
        sample = "Mg";
        sample
    } else {
        text
    };
    let text_height = unsafe { calc_height(dc, body, width.max(1), DrawTextFlags::wrap()) };
    if author_height <= 0 || text_height <= 0 {
        return Err(MeasureError);
    }
    Ok(Measured {
        author_height,
        text_height,
    })
}

/// DrawText with `DT_CALCRECT` and the caller's flags -- the one measurement
/// path, sharing the flags helper the draws use.
unsafe fn calc_height(
    dc: HDC,
    text: &str,
    width: i32,
    how: windows::Win32::Graphics::Gdi::DRAW_TEXT_FORMAT,
) -> i32 {
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = windows::Win32::Foundation::RECT {
        left: 0,
        top: 0,
        right: width.max(1),
        bottom: 0,
    };
    unsafe { crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, how | DT_CALCRECT) }
}

/// The author line at the height the measurement gave it: **drawn, never
/// measured again**.
fn draw_author(
    dc: HDC,
    text: &str,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    colour: look::Rgba,
) {
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = windows::Win32::Foundation::RECT {
        left,
        top,
        right: left + width,
        bottom: top + height.max(0),
    };
    unsafe {
        SetTextColor(dc, crate::control_room::rgb(colour));
        crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::single_line());
    }
}

/// The faces a message plan draws with, made from the page's own fonts.
struct PlanFonts {
    body: windows::Win32::Graphics::Gdi::HFONT,
    strong: windows::Win32::Graphics::Gdi::HFONT,
    emphasis: windows::Win32::Graphics::Gdi::HFONT,
    code: windows::Win32::Graphics::Gdi::HFONT,
    fonts: Fonts,
}

fn face_of(dc: HDC, font: windows::Win32::Graphics::Gdi::HFONT) -> Face {
    unsafe {
        let old = SelectObject(dc, font.into());
        let mut tm = windows::Win32::Graphics::Gdi::TEXTMETRICW::default();
        let _ = windows::Win32::Graphics::Gdi::GetTextMetricsW(dc, &mut tm);
        SelectObject(dc, old);
        Face {
            ascent: tm.tmAscent as i32,
            descent: tm.tmDescent as i32,
        }
    }
}

fn plan_fonts(dc: HDC, dpi: i32) -> PlanFonts {
    let make = |weight: f64, mono: bool, italic: bool| {
        let face = if mono {
            crate::uifont::mono_face()
        } else {
            crate::uifont::ui_face()
        };
        let px = look::font::BODY.round() as i32;
        if italic {
            crate::uifont::make_italic(dpi, px, weight as i32, face)
        } else {
            crate::uifont::make(dpi, px, weight as i32, face)
        }
    };
    let body = make(look::font::WEIGHT_BODY, false, false);
    let strong = make(look::font::WEIGHT_STRONG, false, false);
    let emphasis = make(look::font::WEIGHT_BODY, false, true);
    let code = make(look::font::WEIGHT_BODY, true, false);
    let fonts = Fonts {
        body: face_of(dc, body),
        strong: face_of(dc, strong),
        emphasis: face_of(dc, emphasis),
        code: face_of(dc, code),
    };
    PlanFonts {
        body,
        strong,
        emphasis,
        code,
        fonts,
    }
}

fn plan_font(fonts: &PlanFonts, kind: FontKind) -> windows::Win32::Graphics::Gdi::HFONT {
    match kind {
        FontKind::Body => fonts.body,
        FontKind::Strong => fonts.strong,
        FontKind::Emphasis => fonts.emphasis,
        FontKind::Code => fonts.code,
    }
}

fn measure_in(dc: HDC, font: windows::Win32::Graphics::Gdi::HFONT, text: &str) -> i32 {
    unsafe {
        let old = SelectObject(dc, font.into());
        let wide: Vec<u16> = text.encode_utf16().collect();
        let mut size = windows::Win32::Foundation::SIZE::default();
        let _ = crate::gdi_text::get_text_extent_point32_w(dc, &wide, &mut size);
        SelectObject(dc, old);
        size.cx
    }
}

/// **Plan and draw one message from its parsed document.** The rectangles
/// here are the ones the plan produced; the host does no second wrap. Styles
/// choose the face; a wide table or long code line is clipped for now --
/// its own horizontal view arrives with the rest of B2.
fn draw_plan(
    dc: HDC,
    doc: &polter_chat_markdown::Document,
    plan: &Plan,
    hscroll: &[(usize, i32)],
    dpi: i32,
    top: i32,
    left: i32,
    right: i32,
    width: i32,
    bottom: i32,
    theme: look::Theme,
) {
    let fonts = plan_fonts(dc, dpi);
    let handle_h = md_layout::handle_height(dpi as f64 / 96.0);
    unsafe {
        let saved = SaveDC(dc);
        let clip_bottom = bottom.min(top.saturating_add(plan.height.max(1))).max(top);
        IntersectClipRect(dc, left, top, right, clip_bottom);
        for (block_index, block) in plan.blocks.iter().enumerate() {
            let block_top = top.saturating_add(block.rect.y);
            let horiz = plan.horizontal(block_index);
            let off = hscroll
                .iter()
                .find(|(b, _)| *b == block_index)
                .map_or(0, |(_, o)| *o);
            let draw_left = left.saturating_sub(off);
            let block_saved = SaveDC(dc);
            if horiz.is_some() {
                // **Only this block moves horizontally**, and only inside
                // its own rectangle: the page's vertical clip stays.
                let block_bottom = block_top
                    .saturating_add(block.rect.h)
                    .min(clip_bottom)
                    .max(block_top);
                IntersectClipRect(dc, left, block_top, left + width.max(1), block_bottom);
            }
            match &block.kind {
                md_layout::BlockKind::Rule => {
                    let brush = CreateSolidBrush(crate::control_room::rgb(theme.text_secondary));
                    let r = windows::Win32::Foundation::RECT {
                        left,
                        top: block_top,
                        right: left + width,
                        bottom: block_top + 1,
                    };
                    FillRect(dc, &r, brush);
                    let _ = DeleteObject(brush.into());
                }
                md_layout::BlockKind::Table => {
                    // **By the source block index, never by the compact
                    // `tables` position**: those differ whenever a table
                    // is not the first block.
                    let Some(table) = plan.table_at(block_index) else {
                        let _ = RestoreDC(dc, block_saved);
                        continue;
                    };
                    let Some(polter_chat_markdown::Block::Table(src)) = doc.blocks.get(table.block)
                    else {
                        let _ = RestoreDC(dc, block_saved);
                        continue;
                    };
                    let head_brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row));
                    for cell in &table.header {
                        let r = windows::Win32::Foundation::RECT {
                            left: draw_left + cell.rect.x,
                            top: top + cell.rect.y,
                            right: draw_left + cell.rect.x + cell.rect.w.max(1),
                            bottom: top + cell.rect.y + cell.rect.h.max(1),
                        };
                        let _ = FillRect(dc, &r, head_brush);
                    }
                    let _ = DeleteObject(head_brush.into());
                    for (c, cell) in table.header.iter().enumerate() {
                        let runs = src.header.get(c).map_or(&[][..], |r| r.as_slice());
                        for line in &cell.lines {
                            for piece in &line.pieces {
                                draw_piece(
                                    dc,
                                    &fonts,
                                    piece,
                                    runs,
                                    table_top(&table.block, top),
                                    draw_left,
                                    theme,
                                );
                            }
                        }
                    }
                    for (ri, row) in table.rows.iter().enumerate() {
                        for (c, cell) in row.iter().enumerate() {
                            let runs = src
                                .rows
                                .get(ri)
                                .and_then(|r| r.get(c))
                                .map_or(&[][..], |r| r.as_slice());
                            for line in &cell.lines {
                                for piece in &line.pieces {
                                    draw_piece(
                                        dc,
                                        &fonts,
                                        piece,
                                        runs,
                                        table_top(&table.block, top),
                                        draw_left,
                                        theme,
                                    );
                                }
                            }
                        }
                    }
                }
                _ => {
                    if let Some((text, rect)) = &block.prefix {
                        let mut wide: Vec<u16> = text.encode_utf16().collect();
                        let mut r = windows::Win32::Foundation::RECT {
                            left: left + rect.x,
                            top: top + rect.y,
                            right: left + rect.x + rect.w.max(1),
                            bottom: top + rect.y + rect.h,
                        };
                        SetTextColor(dc, crate::control_room::rgb(theme.text_secondary));
                        SelectObject(dc, fonts.body.into());
                        let _ = crate::gdi_text::draw_text_w(
                            dc,
                            &mut wide,
                            &mut r,
                            DrawTextFlags::single_line(),
                        );
                    }
                    let runs = match doc.blocks.get(block_index) {
                        Some(polter_chat_markdown::Block::Paragraph(r))
                        | Some(polter_chat_markdown::Block::Heading { runs: r, .. })
                        | Some(polter_chat_markdown::Block::Quote { runs: r, .. }) => r.as_slice(),
                        Some(polter_chat_markdown::Block::ListItem(i)) => i.runs.as_slice(),
                        Some(polter_chat_markdown::Block::Code { text, .. }) => {
                            // A code plan's line is the whole line; its
                            // piece range indexes the block's text.
                            let _ = text;
                            &[][..]
                        }
                        _ => &[][..],
                    };
                    let code_text = match doc.blocks.get(block_index) {
                        Some(polter_chat_markdown::Block::Code { text, .. }) => Some(text.as_str()),
                        _ => None,
                    };
                    if code_text.is_some() {
                        let brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row));
                        let r = windows::Win32::Foundation::RECT {
                            left,
                            top: top + block.rect.y,
                            right: left + width.max(1),
                            bottom: top + block.rect.y + block.rect.h.max(1),
                        };
                        let _ = FillRect(dc, &r, brush);
                        let _ = DeleteObject(brush.into());
                    }
                    for line in &block.lines {
                        for piece in &line.pieces {
                            if let Some(code) = code_text {
                                let slice = code.get(piece.text.clone()).unwrap_or("");
                                draw_text_slice(
                                    dc,
                                    &fonts,
                                    piece,
                                    slice,
                                    top,
                                    draw_left,
                                    theme,
                                );
                            } else {
                                draw_piece(dc, &fonts, piece, runs, block_top, draw_left, theme);
                            }
                        }
                    }
                }
            }
            // **Each scrollable block owns a visible rail and thumb**, at
            // the same rectangles the mouse drags.
            if let Some(horiz) = horiz {
                let rect = md_layout::Rect {
                    x: 0,
                    y: block.rect.y,
                    w: width.max(1),
                    h: block.rect.h,
                };
                let (track, thumb) = horiz.thumb(rect, handle_h, off);
                let rail_brush =
                    CreateSolidBrush(crate::control_room::rgb(theme.text_tertiary));
                let rail = windows::Win32::Foundation::RECT {
                    left: left + track.x,
                    top: top + track.y,
                    right: left + track.x + track.w,
                    bottom: top + track.y + track.h,
                };
                let _ = FillRect(dc, &rail, rail_brush);
                let _ = DeleteObject(rail_brush.into());
                let thumb_brush =
                    CreateSolidBrush(crate::control_room::rgb(theme.text_secondary));
                let bar = windows::Win32::Foundation::RECT {
                    left: left + thumb.x,
                    top: top + thumb.y,
                    right: left + thumb.x + thumb.w,
                    bottom: top + thumb.y + thumb.h,
                };
                let _ = FillRect(dc, &bar, thumb_brush);
                let _ = DeleteObject(thumb_brush.into());
            }
            let _ = RestoreDC(dc, block_saved);
        }
        let _ = RestoreDC(dc, saved);
    }
    unsafe {
        for font in [fonts.body, fonts.strong, fonts.emphasis, fonts.code] {
            let _ = DeleteObject(font.into());
        }
    }
}

fn draw_piece(
    dc: HDC,
    fonts: &PlanFonts,
    piece: &md_layout::Piece,
    runs: &[polter_chat_markdown::Run],
    base_top: i32,
    left: i32,
    theme: look::Theme,
) {
    let Some(run) = runs.get(piece.run) else {
        return;
    };
    let slice = run.text.get(piece.text.clone()).unwrap_or("");
    draw_text_slice(dc, fonts, piece, slice, base_top, left, theme);
}

fn draw_text_slice(
    dc: HDC,
    fonts: &PlanFonts,
    piece: &md_layout::Piece,
    text: &str,
    base_top: i32,
    left: i32,
    theme: look::Theme,
) {
    if text.is_empty() {
        return;
    }
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = windows::Win32::Foundation::RECT {
        left: left + piece.rect.x,
        top: base_top + piece.rect.y,
        right: left + piece.rect.x + piece.rect.w.max(1) + 2,
        bottom: base_top + piece.rect.y + piece.rect.h.max(1),
    };
    unsafe {
        let old_font = SelectObject(dc, plan_font(fonts, piece.kind).into());
        SetTextColor(dc, crate::control_room::rgb(theme.text));
        let _ = crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::single_line());
        SelectObject(dc, old_font);
    }
}

fn table_top(_block: &usize, top: i32) -> i32 {
    top
}

/// One single-line string at `y`; its own height is the answer.
fn draw_text(dc: HDC, text: &str, left: i32, y: i32, width: i32, colour: look::Rgba) -> i32 {
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = windows::Win32::Foundation::RECT {
        left,
        top: y,
        right: left + width,
        bottom: y,
    };
    unsafe {
        SetTextColor(dc, crate::control_room::rgb(colour));
        let height = crate::gdi_text::draw_text_w(
            dc,
            &mut wide,
            &mut r,
            DrawTextFlags::single_line() | DT_CALCRECT,
        );
        if height > 0 {
            let mut wide: Vec<u16> = text.encode_utf16().collect();
            let mut draw = windows::Win32::Foundation::RECT {
                left,
                top: y,
                right: left + width,
                bottom: y + height,
            };
            crate::gdi_text::draw_text_w(dc, &mut wide, &mut draw, DrawTextFlags::single_line());
        }
        y + height.max(0)
    }
}

/// A message's original text, wrapped by the same width the layout
/// measured; no ellipsis, no Markdown interpretation.
fn draw_block(dc: HDC, text: &str, left: i32, top: i32, width: i32, bottom: i32) {
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = windows::Win32::Foundation::RECT {
        left,
        top,
        right: left + width,
        bottom,
    };
    unsafe {
        crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::wrap());
    }
}

/// The two format sets this module uses, in one place.
struct DrawTextFlags;
impl DrawTextFlags {
    fn single_line() -> windows::Win32::Graphics::Gdi::DRAW_TEXT_FORMAT {
        DT_LEFT | DT_SINGLELINE | DT_NOPREFIX
    }
    fn wrap() -> windows::Win32::Graphics::Gdi::DRAW_TEXT_FORMAT {
        DT_LEFT | DT_WORDBREAK | DT_NOPREFIX
    }
}

/// What the mouse found under it: the **complete message/plan identity**
/// plus the block, and where the plan's rects are on screen.
struct HSpot {
    target: chat_rows::DragTarget,
    left: i32,
    width: i32,
    /// The message's plan origin on screen.
    plan_top: i32,
    /// The block's plan-local top and height.
    block_rect_y: i32,
    block_h: i32,
    horiz: md_layout::Horiz,
    offset: i32,
    /// The point is on the fixed rail (viewport rect), not the content.
    on_bar: bool,
}

/// The horizontal spot at one point. **Rails are hit first, in viewport
/// coordinates and without any content offset**; only content goes through
/// `Plan::hit_scrolled`.
fn hspot_at(hwnd: HWND, x: i32, y: i32) -> Option<HSpot> {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let dpi = crate::dpi_for(hwnd) as i32;
    let metrics = Metrics::for_dpi(dpi);
    let width = (client.right - client.left - metrics.pad * 2).max(1);
    let view_h = (client.bottom - client.top - metrics.pad * 2).max(1);
    let font_id = plan_font_id(dpi);
    let handle_h = md_layout::handle_height(dpi as f64 / 96.0);
    let left = client.left + metrics.pad;
    CHATS.with(|c| {
        let Ok(c) = c.try_borrow() else {
            return None;
        };
        let chat = c.iter().find(|x| x.hwnd == key)?;
        if !chat.shown {
            return None;
        }
        let feed = chat.feed.as_ref()?;
        let group = chat.group.as_str();
        let generation = feed.generation();
        for i in chat.layout.visible(chat.scroll, view_h) {
            let Some(row) = feed.rows().get(i) else {
                continue;
            };
            let Some(measured) = chat.layout.rows().get(i) else {
                continue;
            };
            let text_top =
                client.top + metrics.pad + measured.top - chat.scroll + measured.author_height;
            let plan_y = y - text_top;
            if plan_y < 0 {
                continue;
            }
            let Some(entry) = chat.plans.iter().find(|p| {
                p.row_id == row.id
                    && p.version == row.message.content_version
                    && p.group == group
                    && p.generation == generation
                    && p.width == width
                    && p.dpi == dpi
                    && p.font == font_id
            }) else {
                continue;
            };
            if plan_y >= entry.plan.height {
                continue;
            }
            let target = |block: usize| chat_rows::DragTarget {
                row_id: row.id.clone(),
                version: row.message.content_version,
                doc: entry.doc_ptr,
                width,
                dpi,
                font: font_id,
                block,
            };
            let (block, horiz, on_bar) =
                if let Some(bar) = entry
                    .plan
                    .bar_at(x - left, plan_y, |b| entry.hoffset(b), handle_h)
                {
                    (bar.block, bar.horiz, true)
                } else {
                    let hit = entry
                        .plan
                        .hit_scrolled(x - left, plan_y, |b| entry.hoffset(b));
                    let block = match hit {
                        Some(md_layout::Hit::Cell { table, .. }) => {
                            let Some(table) = entry.plan.tables.get(table) else {
                                continue;
                            };
                            table.block
                        }
                        Some(md_layout::Hit::Block(block)) => block,
                        None => continue,
                    };
                    let Some(horiz) = entry.plan.horizontal(block) else {
                        continue;
                    };
                    (block, horiz, false)
                };
            let Some(block_plan) = entry.plan.blocks.get(block) else {
                continue;
            };
            return Some(HSpot {
                target: target(block),
                left,
                width,
                plan_top: text_top,
                block_rect_y: block_plan.rect.y,
                block_h: block_plan.rect.h,
                horiz,
                offset: entry.hoffset(block),
                on_bar,
            });
        }
        None
    })
}

/// The held-plan view of one chat, projected for the pure liveness check.
/// **Only independent fields are borrowed** (`plans`, `hdrag`, `hfocus`),
/// so a surviving `feed`/row reference elsewhere is never invalidated. The
/// block lists live in `owned`.
fn drop_dead_for(
    plans: &[ViewPlan],
    drag: &mut chat_rows::DragState,
    focus: &mut Option<chat_rows::DragTarget>,
) -> chat_rows::InputAction {
    let owned: Vec<Vec<usize>> = plans
        .iter()
        .map(|p| {
            p.plan
                .blocks
                .iter()
                .enumerate()
                .filter(|(b, _)| p.plan.horizontal(*b).is_some())
                .map(|(b, _)| b)
                .collect()
        })
        .collect();
    let held: Vec<chat_rows::HeldPlan<'_>> = plans
        .iter()
        .zip(&owned)
        .map(|(p, blocks)| chat_rows::HeldPlan {
            row_id: &p.row_id,
            version: p.version,
            doc: p.doc_ptr,
            width: p.width,
            dpi: p.dpi,
            font: p.font,
            blocks,
        })
        .collect();
    chat_rows::drop_dead_input(drag, focus, &held)
}

/// Set one exact plan's block offset; the plan clamps it.
fn set_hoffset(hwnd: HWND, target: &chat_rows::DragTarget, offset: i32) -> bool {
    let key = hwnd.0 as isize;
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return false;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return false;
        };
        let Some(entry) = chat.plans.iter_mut().find(|p| {
            p.row_id == target.row_id
                && p.version == target.version
                && p.doc_ptr == target.doc
                && p.width == target.width
                && p.dpi == target.dpi
                && p.font == target.font
        }) else {
            return false;
        };
        let before = entry.hoffset(target.block);
        entry.set_hoffset(target.block, offset);
        entry.hoffset(target.block) != before
    })
}

/// **Only this window's own capture** is released, and only after the
/// CHATS borrow has ended.
fn release_own_capture(hwnd: HWND) {
    unsafe {
        if GetCapture() == hwnd {
            let _ = ReleaseCapture();
        }
    }
}

/// A press: the rail starts a drag (after a valid target exists) and jumps
/// the thumb under the pointer; content only gives the keyboard a target.
fn hscroll_press(hwnd: HWND, x: i32, y: i32) -> bool {
    let Some(spot) = hspot_at(hwnd, x, y) else {
        return false;
    };
    let target = spot.target.clone();
    CHATS.with(|c| {
        if let Ok(mut c) = c.try_borrow_mut() {
            if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                chat.hfocus = Some(target.clone());
                if spot.on_bar {
                    chat.hdrag.start(target.clone());
                }
            }
        }
    });
    if !spot.on_bar {
        return false;
    }
    // The target is set: the drag may own the mouse now.
    unsafe {
        SetCapture(hwnd);
    }
    let offset = spot.horiz.offset_at(spot.width, x - spot.left);
    let changed = set_hoffset(hwnd, &target, offset);
    if changed {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
    true
}

/// A drag: the thumb follows the pointer while the complete target still
/// exists. A target that left sight, was rebuilt or lost its document is
/// dropped here; **the returned action is applied after the borrow**.
fn hscroll_drag(hwnd: HWND, x: i32) -> bool {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let width = (client.right - client.left - metrics.pad * 2).max(1);
    let left = client.left + metrics.pad;

    enum Step {
        None,
        Moved(chat_rows::DragTarget, i32),
        Dead(chat_rows::InputAction),
    }
    let step = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return Step::None;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return Step::None;
        };
        let mut action =
            drop_dead_for(&chat.plans, &mut chat.hdrag, &mut chat.hfocus);
        let Some(target) = chat.hdrag.target().cloned() else {
            return if action == chat_rows::InputAction::NONE {
                Step::None
            } else {
                Step::Dead(action)
            };
        };
        let Some(entry) = chat.plans.iter().find(|p| {
            p.row_id == target.row_id
                && p.version == target.version
                && p.doc_ptr == target.doc
                && p.width == target.width
                && p.dpi == target.dpi
                && p.font == target.font
        }) else {
            action = action.merge(chat_rows::cancel_input(&mut chat.hdrag, &mut chat.hfocus));
            return Step::Dead(action);
        };
        let Some(horiz) = entry.plan.horizontal(target.block) else {
            action = action.merge(chat_rows::cancel_input(&mut chat.hdrag, &mut chat.hfocus));
            return Step::Dead(action);
        };
        let offset = horiz.offset_at(width, x - left);
        Step::Moved(target, offset)
    });
    match step {
        Step::None => false,
        Step::Dead(action) => {
            // Every requested effect, even when the drag was already clear.
            if action.release_own_capture {
                release_own_capture(hwnd);
            }
            if action.invalidate {
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            }
            true
        }
        Step::Moved(target, offset) => {
            let changed = set_hoffset(hwnd, &target, offset);
            if changed {
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            }
            true
        }
    }
}

/// Hide/leave/close/`WM_CANCELMODE`: cancel the drag and focus, then run
/// the action after the borrow. **The capture release is asked for even
/// when the drag was already cleared.**
fn hscroll_cancel(hwnd: HWND) {
    let action = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return chat_rows::InputAction::NONE;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return chat_rows::InputAction::NONE;
        };
        chat_rows::cancel_input(&mut chat.hdrag, &mut chat.hfocus)
    });
    if action.release_own_capture {
        release_own_capture(hwnd);
    }
    if action.invalidate {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
}

/// The button came up: end the drag; a still-valid focus is kept, and the
/// tick's liveness check drops it later if its plan is gone.
fn hscroll_end(hwnd: HWND) {
    let action = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return chat_rows::InputAction::NONE;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return chat_rows::InputAction::NONE;
        };
        chat.hdrag.end()
    });
    if action.release_own_capture {
        release_own_capture(hwnd);
    }
    if action.invalidate {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
}

/// `WM_CAPTURECHANGED`: another window took the capture. Forget only our
/// drag/focus; never release that other window's capture.
fn hscroll_capture_lost(hwnd: HWND) {
    let action = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return chat_rows::InputAction::NONE;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return chat_rows::InputAction::NONE;
        };
        // Capture and keyboard focus are separate: ending the drag here
        // must not drop the block the person selected with the click.
        chat_rows::capture_lost_input(&mut chat.hdrag)
    });
    if action.invalidate {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
}

/// Arrow keys move the focused block's own horizontal view. Without a
/// click, the first scrollable block in sight takes the focus. **Every
/// early return carries the action** the liveness check produced.
fn hscroll_key(hwnd: HWND, step: i32) -> bool {
    let key = hwnd.0 as isize;
    let (action, changed) = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return (chat_rows::InputAction::NONE, false);
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return (chat_rows::InputAction::NONE, false);
        };
        let mut action =
            drop_dead_for(&chat.plans, &mut chat.hdrag, &mut chat.hfocus);
        if action.invalidate || action.release_own_capture {
            // The dead target already produced its action; return it
            // before touching any plan.
            return (action, false);
        }
        if chat.hfocus.is_none() {
            let first = chat.plans.iter().find_map(|p| {
                p.plan
                    .blocks
                    .iter()
                    .enumerate()
                    .find(|(b, _)| p.plan.horizontal(*b).is_some())
                    .map(|(b, _)| chat_rows::DragTarget {
                        row_id: p.row_id.clone(),
                        version: p.version,
                        doc: p.doc_ptr,
                        width: p.width,
                        dpi: p.dpi,
                        font: p.font,
                        block: b,
                    })
            });
            chat.hfocus = first;
        }
        let Some(target) = chat.hfocus.clone() else {
            return (action, false);
        };
        let Some(entry) = chat.plans.iter_mut().find(|p| {
            p.row_id == target.row_id
                && p.version == target.version
                && p.doc_ptr == target.doc
                && p.width == target.width
                && p.dpi == target.dpi
                && p.font == target.font
        }) else {
            chat.hfocus = None;
            action = action.merge(chat_rows::InputAction::invalidate());
            return (action, false);
        };
        let before = entry.hoffset(target.block);
        entry.set_hoffset(target.block, before.saturating_add(step));
        (action, entry.hoffset(target.block) != before)
    });
    if action.release_own_capture {
        release_own_capture(hwnd);
    }
    if action.invalidate || changed {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
    changed
}

/// Wheel and keys move the view; both are bounded by the content, and both
/// keep the row at the top (by id and offset) as the anchor.
fn scroll_by(hwnd: HWND, by: i32) {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let view_h = (client.bottom - client.top - metrics.pad * 2).max(1);
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return;
        };
        chat.scroll = chat.layout.clamp(chat.scroll - by, view_h);
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

fn scroll_to(hwnd: HWND, at: i32) {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let view_h = (client.bottom - client.top - metrics.pad * 2).max(1);
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return;
        };
        chat.scroll = chat.layout.clamp(at, view_h);
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// The message whose row is at `y` pixels from the top of the page.
fn row_at(hwnd: HWND, y: i32) -> Option<String> {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let mut out = None;
    CHATS.with(|c| {
        let Ok(c) = c.try_borrow() else {
            return;
        };
        let Some(chat) = c.iter().find(|x| x.hwnd == key) else {
            return;
        };
        let Some(feed) = chat.feed.as_ref() else {
            return;
        };
        let page_y = y - client.top - metrics.pad + chat.scroll;
        for (i, row) in chat.layout.rows().iter().enumerate() {
            if page_y < row.top || page_y >= row.top + row.height {
                continue;
            }
            if let Some(text) = feed.rows().get(i).map(|r| r.message.text.clone()) {
                out = Some(text);
            }
            break;
        }
    });
    out
}

/// **The real plan builder**: the selected fonts, their real metrics, the
/// page's pixel width and one measuring callback. The `HFONT`s are released
/// before it returns; the plan keeps no font resource.
fn build_plan(dc: HDC, doc: &polter_chat_markdown::Document, width: i32, dpi: i32) -> Plan {
    let fonts = plan_fonts(dc, dpi);
    let measure = |kind: FontKind, text: &str| measure_in(dc, plan_font(&fonts, kind), text);
    let input = Inputs {
        width,
        scale: dpi as f64 / 96.0,
        fonts: fonts.fonts,
        measure: &measure,
    };
    let plan = md_layout::layout(doc, &input);
    unsafe {
        for font in [fonts.body, fonts.strong, fonts.emphasis, fonts.code] {
            let _ = DeleteObject(font.into());
        }
    }
    plan
}

/// The raw path's heights with the same body face: one author line and the
/// wrapped body, measured by DrawText with the flags it is drawn with.
fn measure_raw(dc: HDC, author: &str, text: &str, width: i32, dpi: i32) -> (i32, i32) {
    let fonts = plan_fonts(dc, dpi);
    let measure_body = |text: &str| unsafe {
        let old = SelectObject(dc, fonts.body.into());
        let height = calc_height(dc, text, width.max(1), DrawTextFlags::wrap());
        SelectObject(dc, old);
        height
    };
    let author_height = unsafe {
        let old = SelectObject(dc, fonts.body.into());
        let h = calc_height(dc, author, width.max(1), DrawTextFlags::single_line());
        SelectObject(dc, old);
        h
    };
    let text_height = if text.is_empty() {
        measure_body("Mg")
    } else {
        measure_body(text)
    };
    unsafe {
        for font in [fonts.body, fonts.strong, fonts.emphasis, fonts.code] {
            let _ = DeleteObject(font.into());
        }
    }
    (author_height.max(1), text_height.max(1))
}

/// The semantic identity of the faces a plan is measured with: the DPI,
/// the body size and weight, and the interface face's name. Never an
/// `HFONT` handle, which is new every time one is made.
fn plan_font_id(dpi: i32) -> u64 {
    use std::hash::{Hash, Hasher};
    let face_holder = unsafe { crate::uifont::ui_face() };
    let face = unsafe { face_holder.as_wide() };
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    dpi.hash(&mut hasher);
    face.hash(&mut hasher);
    look::font::BODY.to_bits().hash(&mut hasher);
    look::font::WEIGHT_BODY.to_bits().hash(&mut hasher);
    look::font::WEIGHT_STRONG.to_bits().hash(&mut hasher);
    hasher.finish()
}

/// **Measure at most four messages a tick**, for the rows in sight and one
/// either side, and keep only those plans. A message whose document has
/// left the cache, or whose width/DPI/font changed, is measured again; a
/// plan for a row no longer in sight is dropped together with its document
/// `Arc`, so this cache never keeps an old document alive outside the
/// host's 200-entry parse cache.
fn publish_heights(hwnd: HWND) {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let dpi = crate::dpi_for(hwnd) as i32;
    let metrics = Metrics::for_dpi(dpi);
    let width = (client.right - client.left - metrics.pad * 2).max(1);
    let view_h = (client.bottom - client.top - metrics.pad * 2).max(1);
    let font_id = plan_font_id(dpi);
    let dc = unsafe { GetDC(Some(hwnd)) };
    if dc.0.is_null() {
        return;
    }
    let mut invalidate = false;
    let mut release_input = false;
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return;
        };
        if !chat.shown {
            return;
        }
        let Some(feed) = chat.feed.as_ref() else {
            return;
        };
        let group = chat.group.clone();
        let generation = feed.generation();
        if chat.plan_width != width || chat.plan_dpi != dpi || chat.plan_font != font_id {
            chat.plans.clear();
            // A drag or focus on the old plans is dead: clear the state
            // here and **accumulate** both requested effects, never
            // overwrite them.
            let action = chat_rows::cancel_input(&mut chat.hdrag, &mut chat.hfocus);
            release_input = release_input || action.release_own_capture;
            invalidate = invalidate || action.invalidate;
            chat.plan_width = width;
            chat.plan_dpi = dpi;
            chat.plan_font = font_id;
        }
        let identities: Vec<RowIdentity<'_>> = feed
            .rows()
            .iter()
            .map(|r| RowIdentity {
                id: r.id.as_str(),
                version: r.message.content_version,
            })
            .collect();
        let range = chat.layout.visible(chat.scroll, view_h);

        struct Candidate {
            index: usize,
            /// The feed's stable row id, **never** the canonical anchor.
            id: String,
            version: u64,
            /// The complete semantic this row's current content, document,
            /// size and font imply.
            identity: chat_rows::Identity,
            doc: Option<std::sync::Arc<polter_chat_markdown::Document>>,
        }
        let mut candidates: Vec<Candidate> = Vec::new();
        for i in range {
            let Some(row) = feed.rows().get(i) else {
                continue;
            };
            let anchor = row.message.anchor.clone();
            let version = row.message.content_version;
            let md_key = MdKey {
                group: group.clone(),
                generation,
                anchor: anchor.clone(),
                content_version: version,
            };
            let doc = crate::markdown_service::document(&md_key);
            let doc_ptr = doc
                .as_ref()
                .map(|d| std::sync::Arc::as_ptr(d) as usize)
                .unwrap_or(0);
            candidates.push(Candidate {
                index: i,
                id: row.id.clone(),
                version,
                identity: chat_rows::Identity {
                    group: group.clone(),
                    generation,
                    anchor,
                    version,
                    doc: doc_ptr,
                    width,
                    dpi,
                    font: font_id,
                },
                doc,
            });
        }
        chat.plans.retain(|p| {
            candidates
                .iter()
                .any(|c| c.id == p.row_id && c.version == p.version && c.identity.doc == p.doc_ptr)
        });
        // Eviction, a rebuilt plan, a new document or a vanished block
        // kills the drag/focus here, in the same pure criterion the tests
        // use -- borrowing only the independent fields, so the feed/row
        // references used above stay valid.
        let action = drop_dead_for(&chat.plans, &mut chat.hdrag, &mut chat.hfocus);
        release_input = release_input || action.release_own_capture;
        invalidate = invalidate || action.invalidate;

        // **Explicit projection** from the host's bookkeeping (index, doc
        // `Arc`, plan lookup) into the pure candidate type. `draw_ready`
        // is true for a raw row (its text is in the feed) and for a
        // Markdown row only when this view still holds a plan measured for
        // exactly this identity -- a cached document alone is not enough.
        let pure: Vec<chat_rows::Candidate> = candidates
            .iter()
            .map(|c| {
                let plan_present = c.doc.as_ref().is_some_and(|doc| {
                    let ptr = std::sync::Arc::as_ptr(doc) as usize;
                    chat.plans.iter().any(|p| {
                        p.row_id == c.id
                            && p.group == group
                            && p.generation == generation
                            && p.anchor == c.identity.anchor
                            && p.version == c.version
                            && p.doc_ptr == ptr
                            && p.width == width
                            && p.dpi == dpi
                            && p.font == font_id
                    })
                });
                chat_rows::view_candidate(
                    &c.id,
                    c.version,
                    c.identity.clone(),
                    c.doc.is_some(),
                    plan_present,
                )
            })
            .collect();

        // **The host's actual decision path is this pure function**: a
        // fresh row costs no budget, only a genuinely invalid one is
        // measured, four at most, in page order.
        let plan = chat_rows::schedule(chat.layout.rows(), &pure, 4);
        let mut decisions: Vec<chat_rows::Decision<'_>> = Vec::with_capacity(plan.len());
        for entry in &plan {
            match entry.action {
                chat_rows::Action::Fresh => decisions.push(chat_rows::Decision::KeepFresh {
                    id: entry.id,
                    version: entry.version,
                }),
                chat_rows::Action::Stale => decisions.push(chat_rows::Decision::KeepStale {
                    id: entry.id,
                    version: entry.version,
                }),
                chat_rows::Action::Measure => {
                    let Some(candidate) = candidates
                        .iter()
                        .find(|c| c.id == entry.id && c.version == entry.version)
                    else {
                        continue;
                    };
                    let Some(row) = feed.rows().get(candidate.index) else {
                        continue;
                    };
                    let author = if row.message.author.is_empty() {
                        row.message.from.as_str()
                    } else {
                        row.message.author.as_str()
                    };
                    let (source, author_height, text_height) = match &candidate.doc {
                        Some(doc) => {
                            let ptr = std::sync::Arc::as_ptr(doc) as usize;
                            let known = chat
                                .plans
                                .iter()
                                .find(|p| {
                                    p.row_id == candidate.id
                                        && p.group == group
                                        && p.generation == generation
                                        && p.anchor == candidate.identity.anchor
                                        && p.version == candidate.version
                                        && p.doc_ptr == ptr
                                        && p.width == width
                                        && p.dpi == dpi
                                        && p.font == font_id
                                })
                                .map(|p| p.plan.clone());
                            let plan = match known {
                                Some(plan) => plan,
                                None => {
                                    let plan = std::sync::Arc::new(build_plan(dc, doc, width, dpi));
                                    chat.plans.push(ViewPlan {
                                        row_id: candidate.id.clone(),
                                        group: group.clone(),
                                        generation,
                                        anchor: candidate.identity.anchor.clone(),
                                        version: candidate.version,
                                        doc_ptr: ptr,
                                        width,
                                        dpi,
                                        font: font_id,
                                        doc: doc.clone(),
                                        plan: plan.clone(),
                                        hscroll: Vec::new(),
                                    });
                                    plan
                                }
                            };
                            let (author_height, _) = measure_raw(dc, author, "", width, dpi);
                            (chat_rows::Source::Markdown, author_height, plan.height.max(1))
                        }
                        None => {
                            let (author_height, text_height) =
                                measure_raw(dc, author, &row.message.text, width, dpi);
                            (chat_rows::Source::Raw, author_height, text_height)
                        }
                    };
                    decisions.push(chat_rows::Decision::Replace(
                        chat_rows::PublishedHeight {
                            id: candidate.id.as_str(),
                            version: candidate.version,
                            source,
                            identity: &candidate.identity,
                            author_height,
                            text_height,
                        },
                    ));
                }
            }
        }

        let anchor = chat
            .layout
            .anchor(chat.scroll)
            .map(|(id, offset)| (id.to_owned(), offset));
        let changed = chat
            .layout
            .publish(&identities, &decisions, &metrics, width);
        if let Some((id, offset)) = anchor {
            if let Some(at) = chat.layout.scroll_for(&id, offset) {
                chat.scroll = at;
            }
        }
        chat.scroll = chat.layout.clamp(chat.scroll, view_h);
        invalidate = invalidate || changed;
    });
    unsafe {
        ReleaseDC(Some(hwnd), dc);
    }
    if release_input {
        release_own_capture(hwnd);
    }
    if invalidate {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
}

/// What the visible page asks to have parsed: the rows in sight and one
/// either side, and nothing else -- never the whole 500-row window. The
/// keys are the feed's own identities; the source is shared.
fn demand_in_sight(hwnd: HWND) {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let view_h = (client.bottom - client.top - metrics.pad * 2).max(1);
    let demand = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return None;
        };
        let chat = c.iter_mut().find(|x| x.hwnd == key)?;
        if !chat.shown {
            return None;
        }
        let feed = chat.feed.as_ref()?;
        let owner = Owner {
            view: chat.view,
            epoch: feed.generation(),
        };
        let group = chat.group.clone();
        let generation = feed.generation();
        let range = chat.layout.visible(chat.scroll, view_h);
        let mut items = Vec::new();
        for i in range {
            let Some(row) = feed.rows().get(i) else {
                continue;
            };
            items.push((
                MdKey {
                    group: group.clone(),
                    generation,
                    anchor: row.message.anchor.clone(),
                    content_version: row.message.content_version,
                },
                std::sync::Arc::<str>::from(row.message.text.as_str()),
            ));
        }
        Some((owner, items))
    });
    if let Some((owner, items)) = demand {
        if !items.is_empty() {
            crate::markdown_service::demand(owner, items);
        } else {
            // Nothing in sight is still a demand of nothing: the owner's
            // old set goes with it.
            crate::markdown_service::demand(owner, Vec::new());
        }
    }
}

/// Whether an owner is still the view and epoch it asked as. **The UI's
/// answer**, not the service's: it keeps no window handles.
fn owner_live(owner: Owner) -> bool {
    CHATS.with(|c| {
        c.try_borrow().ok().is_some_and(|c| {
            c.iter().any(|x| {
                x.view == owner.view
                    && x.shown
                    && x.feed
                        .as_ref()
                        .is_some_and(|f| f.generation() == owner.epoch)
            })
        })
    })
}

/// A document arrived for an owner that still asks: ask that view to draw.
/// B1 draws the original text, so this is only a repaint; the parsed
/// document itself lives in the one shared cache.
fn repaint_completions(completion: &Completion) {
    for owner in &completion.owners {
        let hwnd = CHATS.with(|c| {
            c.try_borrow().ok().and_then(|c| {
                c.iter()
                    .find(|x| x.view == owner.view)
                    .map(|x| HWND(x.hwnd as *mut c_void))
            })
        });
        if let Some(hwnd) = hwnd {
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
        }
    }
}

/// A fresh request id: process-unique nonce plus a monotonic counter,/// A fresh request id: process-unique nonce plus a monotonic counter,
/// rendered as the 32 lowercase hex characters W1 accepts. No new crate.
fn next_request_id() -> Option<String> {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id() as u64;
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_nanos() as u64;
    Some(format!("{:016x}{:016x}", t ^ (pid << 32) ^ n, n))
}

/// The host's monotonic clock, in milliseconds. Never the wall clock: a
/// clock that can go backwards stalls every deadline it feeds.
fn now_ms() -> u64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START
        .get_or_init(std::time::Instant::now)
        .elapsed()
        .as_millis() as u64
}

/// One W1 call, on this thread, with the core's App. A core that is not
/// there yet is `NotReady`, never a made-up empty reply.
fn send_request(request: &str) -> Result<Transport, TransportError> {
    let Some(api) = crate::api_opt() else {
        return Ok(Transport::NotReady);
    };
    let app = crate::app_opt();
    if app.is_null() {
        return Ok(Transport::NotReady);
    }
    chat_read::ask(api, app, request)
}

/// The child window's one tick: a cancel it owes, or at most one ordinary
/// read. Everything that touches the state machine happens under a borrow
/// that is released before the ABI call.
fn tick(hwnd: HWND) {
    let key = hwnd.0 as isize;
    let now = now_ms();

    // **Answers first**: keep the one cache, and repaint only owners that
    // are still alive under the epoch they asked with. Nothing is drawn or
    // parsed here.
    let completions = crate::markdown_service::poll(&owner_live);
    for completion in completions {
        repaint_completions(&completion);
    }
    // **Every tick, whatever the core is doing**: what is in sight is what
    // wants parsing. An idle core (no action ready) must not stop it.
    demand_in_sight(hwnd);
    // And the tick -- not the paint -- publishes the heights it consumes.
    publish_heights(hwnd);

    let owed = CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let chat = c.iter_mut().find(|x| x.hwnd == key)?;
        chat.pending_cancel.take()
    });
    if let Some(request) = owed {
        let _ = send_request(&request);
        return;
    }

    let ready = CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let chat = c.iter_mut().find(|x| x.hwnd == key)?;
        if !chat.shown {
            return None;
        }
        let feed = chat.feed.as_mut()?;
        let action = feed.next_action(now)?;
        let group = feed.group()?.to_owned();
        let generation = feed.generation();
        Some((action, group, generation))
    });
    let Some((action, group, generation)) = ready else {
        return;
    };
    let (kind, request) = match action {
        Action::Begin { request } => (Kind::Begin, request),
        Action::Live { request } => (Kind::Live, request),
        Action::Poll { request } => (Kind::Poll, request),
        Action::Cancel { request } => {
            // A cleanup cancel is fire and forget; there is no reply to
            // apply and nothing to retry.
            let _ = send_request(&request);
            return;
        }
    };

    let transport = send_request(&request);

    // **After the call the world may have moved**: the window may be gone,
    // another group selected, the page hidden, or the feed restarted.
    // Handing the reply to the feed is what checks that -- its `accept_*`
    // compares generation, group and the job -- and a Begin that is no
    // longer current still has its job cancelled, which is the one thing a
    // hidden window must not leave scanning. When there is no window left
    // to hand it to, that cancel is made here.
    let mut late: Option<String> = None;
    CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            late = late_begin_cancel(kind, &group, &transport);
            return;
        };
        let Some(feed) = chat.feed.as_mut() else {
            late = late_begin_cancel(kind, &group, &transport);
            return;
        };
        let envelope = Envelope {
            kind,
            generation,
            group,
        };
        let owed = match kind {
            Kind::Begin => feed.accept_begin(&envelope, transport, now),
            Kind::Live => feed.accept_live(&envelope, transport, now),
            Kind::Poll => feed.accept_poll(&envelope, transport, now),
            Kind::Cancel => None,
        };
        if let Some(Action::Cancel { request }) = owed {
            // **A hidden page has no tick to owe it to.** The timer was
            // killed when it left, so a cancel the stale reply produced is
            // sent now (cleanup only), not parked for a tick that will
            // never come.
            if chat.shown {
                chat.pending_cancel = Some(request);
            } else {
                late = Some(request);
            }
        }
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    });
    if let Some(request) = late {
        let _ = send_request(&request);
    }
}

/// The job a late begin started, for a window that is no longer there to
/// hand it to a feed. **Only the reply to a Begin, and only while it is the
/// group that Begin was made for**: a reply that wandered in from another
/// group is dropped rather than used to cancel somebody else's job.
fn late_begin_cancel(
    kind: Kind,
    expected_group: &str,
    transport: &Result<Transport, TransportError>,
) -> Option<String> {
    if kind != Kind::Begin {
        return None;
    }
    let Ok(Transport::Body(text)) = transport else {
        return None;
    };
    match chat_read::decode_begin(text) {
        Ok(chat_read::BeginOutcome::Started(page)) if page.group == expected_group => {
            chat_read::Request::Cancel {
                job_id: page.job_id,
            }
            .encode()
            .ok()
        }
        _ => None,
    }
}

/// The frame's DPI changed: the native window has no surface to resize, and
/// the rows' own layout takes the scale with the next placement.
pub fn rescale(hwnd: HWND, _scale: f64) {
    wlogf!(
        hwnd,
        "[chat-native] dpi change: the rows take it at their next placement"
    );
}
