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
use windows::Win32::Foundation::{FILETIME, HINSTANCE, HWND, LPARAM, LRESULT, SYSTEMTIME, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, GetDC, GetTextMetricsW,
    IntersectClipRect, InvalidateRect, ReleaseDC, RestoreDC, SaveDC, ScreenToClient, SelectObject,
    SetBkColor, SetBkMode, SetTextColor, DT_CALCRECT, DT_LEFT, DT_NOPREFIX, DT_SINGLELINE,
    DT_WORDBREAK, HDC, HFONT, PAINTSTRUCT, TEXTMETRICW, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Time::{FileTimeToSystemTime, SystemTimeToTzSpecificLocalTime};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetCapture, GetFocus, ReleaseCapture, SetCapture, SetFocus, VK_END, VK_ESCAPE, VK_HOME,
    VK_LEFT, VK_NEXT, VK_PRIOR, VK_RIGHT,
};
use windows::Win32::UI::Shell::{DefSubclassProc, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_chat_markdown::cache::Key as MdKey;
use polter_chat_markdown::coordinator::{Completion, Owner};
use polter_chat_markdown::layout::{self as md_layout, Face, FontKind, Fonts, Inputs, Plan};
use polter_control_room::chat_meta::{self, Parts};
use polter_control_room::look;
use polter_settings_shell::plugins::PageState as settings_shell_page_state;
use polter_split_tree::Rect as TreeRect;

use crate::chat_feed::{self, Action, Envelope, Feed, Kind};
use crate::chat_read::{self, Transport, TransportError};
use crate::ffi::Surface;
use crate::preview_page;
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

#[derive(Debug, Clone, PartialEq, Eq)]
struct PreviewPending {
    anchor: String,
    location: Option<String>,
    reference: String,
}

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
    /// The brief is expanded; the member popover is open. Both are the
    /// person's view state, not the group's.
    brief_open: bool,
    members_open: bool,
    /// The view follows new messages while it is at the bottom. Scrolling
    /// up turns this off until the person returns to the latest end.
    follow: bool,
    /// What the last tick saw, so growth can be told from a repaint.
    rows_seen: usize,
    /// New rows arrived while reading history (distinct from the feed's
    /// separately held `new_messages`).
    new_rows: bool,
    /// A located message's whole row is briefly lit (search increment).
    highlight: Option<(String, std::time::Instant)>,
    /// **The selected hit's own ranges, in the message's raw bytes.** The
    /// core validated `snippet_start + ranges` inside `message.text`; the
    /// paint maps them to rendered runs/code/table text through the
    /// parser's proved spans. `None` means no text-range highlight.
    text_highlight: Option<(String, Vec<std::ops::Range<usize>>)>,
    /// The message viewport's height at the last paint, so the tick can
    /// keep a following view on the bottom without measuring again.
    view_h: i32,
    /// The right-hand search panel (closed | search). Preview is the other
    /// occupant of the same slot and arrives with the file-reference slice.
    side: SidebarMode,
    search_query: String,
    /// The query changed and the scan has not been asked for yet.
    search_due: Option<u64>,
    search_selected: Option<usize>,
    search_scroll: i32,
    /// The first visible result card when a release was asked for; the
    /// same anchor is put back at the top afterwards.
    search_anchor: Option<String>,
    /// The selected hit by identity, so a window slide cannot move the
    /// selection to another row.
    search_selected_anchor: Option<String>,
    /// The selected hit's message is not in the loaded window; the panel
    /// says so instead of jumping to a look-alike.
    search_missing: bool,
    /// The around target already applied to the view, so a ready page is
    /// not scrolled to on every tick.
    around_seen: Option<String>,
    /// The search box is a native `EDIT`, so selection, paste, IME and
    /// surrogate pairs are the platform's and not a key handler's.
    search_edit: isize,
    /// The EDIT's font, owned here so closing the panel releases it and a
    /// DPI move replaces it.
    search_font: isize,
    preview_token: Option<String>,
    /// The source this page asked for: exact anchor, its opaque hint and
    /// the reference text, all bound to the same request.
    preview_pending: Option<PreviewPending>,
    preview_label: Option<String>,
    preview_error: Option<String>,
    preview_back_search: bool,
    preview_loading: bool,
    /// The descriptor the core chose for the current token; kept for a
    /// resize/restore re-mount.
    preview_plugin: Option<serde_json::Value>,
    /// The rect the preview child was last mounted with.
    preview_rect: Option<(i32, i32, i32, i32)>,
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
/// The search box's control id, and the two messages its subclass posts so
/// Escape/Return reach the page's own state machine.
const SEARCH_EDIT_ID: usize = 0x5101;
const WM_SEARCH_CLOSE: u32 = WM_APP + 61;
const WM_SEARCH_NOW: u32 = WM_APP + 62;
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
    /// The search box's background brush, replaced (and the old one
    /// deleted) rather than leaked on every EN_CHANGE.
    static EDIT_BRUSH: Cell<isize> = const { Cell::new(0) };
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
            let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
            // The wheel belongs to whichever side the pointer is over:
            // the panel's results scroll without moving the conversation.
            let mut at = windows::Win32::Foundation::POINT {
                x: (lp.0 & 0xFFFF) as i16 as i32,
                y: ((lp.0 >> 16) & 0xFFFF) as i16 as i32,
            };
            let _ = unsafe { ScreenToClient(hwnd, &mut at) };
            let mut client = windows::Win32::Foundation::RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut client) };
            let opened = CHATS.with(|c| {
                c.try_borrow()
                    .ok()
                    .and_then(|c| {
                        c.iter()
                            .find(|x| x.hwnd == hwnd.0 as isize)
                            .map(|x| x.side != SidebarMode::Closed)
                    })
                    .unwrap_or(false)
            });
            let (_, side_w) = split(&client, &metrics, sidebar_of(opened));
            let side_left = panel_left(&client, side_w);
            if opened && side_w > 0 && at.x >= side_left {
                search_scroll_by(hwnd, -(delta / 120) * metrics.line * 3);
            } else {
                // Three lines a notch, as the control room's list scrolls.
                scroll_by(hwnd, (delta / 120) * metrics.line * 3);
            }
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            let x = (lp.0 & 0xFFFF) as i16 as i32;
            let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
            let consumed = chat_click(hwnd, x, y);
            if !consumed {
                // **The one line a click leaves when nothing took it**:
                // where it was, so a link that missed can be measured
                // against the page instead of guessed at.
                plogf!("[chat-native] click at ({}, {}) was not consumed", x, y);
                hscroll_press(hwnd, x, y);
                // **A click on the conversation is how the person says
                // "keys go here".** A click the header/panel/search box
                // consumed keeps its own focus -- taking it would pull the
                // caret out of the native search editor.
                take_keyboard(hwnd);
            }
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
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as usize;
            let note = ((wp.0 >> 16) & 0xFFFF) as u32;
            if id == SEARCH_EDIT_ID && note == 0x0300 {
                // EN_CHANGE. The box is the editor; the page reads its
                // text and invalidates the old answers at once.
                on_search_edit_changed(hwnd);
                return LRESULT(0);
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_CTLCOLOREDIT => {
            if lp.0 as isize == search_edit_hwnd(hwnd) {
                let theme = look::theme(unsafe {
                    crate::termcolor::chrome(GetAncestor(hwnd, GA_ROOT)).dark
                });
                let dc = HDC(wp.0 as *mut c_void);
                unsafe {
                    SetTextColor(dc, crate::control_room::rgb(theme.text));
                    SetBkColor(dc, crate::control_room::rgb(theme.surface_row));
                    let brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row));
                    EDIT_BRUSH.with(|b| {
                        let old = b.replace(brush.0 as isize);
                        if old != 0 {
                            let _ = DeleteObject(windows::Win32::Graphics::Gdi::HGDIOBJ(
                                old as *mut c_void,
                            ));
                        }
                    });
                    return LRESULT(EDIT_BRUSH.with(|b| b.get()) as isize);
                }
            }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
        WM_SEARCH_CLOSE => {
            close_search(hwnd);
            LRESULT(0)
        }
        WM_SEARCH_NOW => {
            CHATS.with(|c| {
                if let Ok(mut c) = c.try_borrow_mut() {
                    if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                        chat.search_due = Some(now_ms());
                    }
                }
            });
            LRESULT(0)
        }
        WM_KEYDOWN => {
            if search_key(hwnd, wp.0 as u16) {
                return LRESULT(0);
            }
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
        brief_open: false,
        members_open: false,
        follow: true,
        rows_seen: 0,
        new_rows: false,
        highlight: None,
        text_highlight: None,
        view_h: 0,
        side: SidebarMode::Closed,
        search_query: String::new(),
        search_due: None,
        search_selected: None,
        search_scroll: 0,
        search_anchor: None,
        search_selected_anchor: None,
        search_missing: false,
        around_seen: None,
        search_edit: 0,
        search_font: 0,
        preview_token: None,
        preview_pending: None,
        preview_label: None,
        preview_error: None,
        preview_back_search: false,
        preview_loading: false,
        preview_plugin: None,
        preview_rect: None,
    })
}

/// Put one away: its window destroyed, and nothing else in the process
/// touched.
fn close(mut chat: Chat, why: &str) {
    let hwnd = HWND(chat.hwnd as *mut c_void);
    // **The EDIT does not outlive its page**, and its HFONT is never the
    // control's to free: both go here before the parent window does.
    destroy_search_edit(&mut chat);
    // **A window that goes takes its reading with it**: the feed is
    // stopped before the window dies, and a known job is cancelled.
    let mut cancels: Vec<String> = Vec::new();
    let mut tickets: Vec<String> = Vec::new();
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
        // **Two jobs, two cancels**: the bootstrap's came back from
        // `stop`, and the auxiliary scan's is waiting in the cleanup
        // slots. No tick will drain them once this window is gone.
        while let Some(Action::Cancel { request }) = feed.pending_cleanup() {
            cancels.push(request);
        }
        if let Some(page) = feed.take_reference() {
            if let Some(token) = chat_read::ticket_of(&page) {
                tickets.push(token);
            }
        }
        // **No tick will drain these once this window is gone**, and `stop`
        // parks a stored ready answer here rather than dropping its ticket.
        tickets.extend(feed.take_orphan_references());
    }
    // process-wide: a chat belongs to the control room, of which the process has one
    plogf!("[chat-native] chat for {:?} closed: {}", chat.group, why);
    let _ = unsafe { KillTimer(Some(hwnd), CHAT_TIMER) };
    // **Children go before their parent window**, and a ticket nobody
    // adopted is closed here too.
    crate::preview_page::flush_deferred();
    crate::preview_page::close_all_for_parent(hwnd);
    for token in tickets {
        crate::preview_page::close_unowned(&token);
    }
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
    // Tickets a hidden page's feed handed back: the timer is about to stop,
    // so no tick can drain them after this borrow.
    let mut tickets: Vec<String> = Vec::new();
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
                            // The auxiliary scan's cancel too: this page is
                            // hidden and its timer is about to be killed.
                            while let Some(Action::Cancel { request }) = feed.pending_cleanup() {
                                cancels.push(request);
                            }
                            // `stop` parks a ready reference there; the
                            // hidden page has no next tick to drain it.
                            tickets.extend(feed.take_orphan_references());
                        }
                        crate::preview_page::hide_all_for_parent(HWND(x.hwnd as *mut c_void));
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
    // **The owner check is the ledger's**: a token another slot holds is
    // refused here, so a hidden page cannot close a visible preview.
    for token in tickets {
        crate::preview_page::close_unowned(&token);
    }
    // A close deferred by a busy ledger is retried once the borrows above
    // are gone.
    crate::preview_page::flush_deferred();
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

/// Milliseconds between 1601-01-01 and 1970-01-01, for the FILETIME epoch.
const EPOCH_AS_FILETIME_MS: i128 = 11_644_473_600_000;

/// An epoch millisecond as the person's own local calendar fields. DST is
/// the platform's answer; this host does no offset arithmetic.
fn local_parts(at_ms: i64) -> Option<Parts> {
    let ms = i128::from(at_ms) + EPOCH_AS_FILETIME_MS;
    let ticks = ms.checked_mul(10_000)?;
    if !(0..=i128::from(u64::MAX)).contains(&ticks) {
        return None;
    }
    let ticks = ticks as u64;
    let file = FILETIME {
        dwLowDateTime: ticks as u32,
        dwHighDateTime: (ticks >> 32) as u32,
    };
    let mut system = SYSTEMTIME::default();
    unsafe { FileTimeToSystemTime(&file, &mut system).ok()? };
    let mut local = SYSTEMTIME::default();
    unsafe { SystemTimeToTzSpecificLocalTime(None, &system, &mut local).ok()? };
    Some(Parts {
        year: i32::from(local.wYear),
        month: u32::from(local.wMonth),
        day: u32::from(local.wDay),
        hour: u32::from(local.wHour),
        minute: u32::from(local.wMinute),
        second: u32::from(local.wSecond),
    })
}

/// The wall clock in epoch milliseconds, for "today" only. **Never for a
/// deadline**: the monotonic clock in `now_ms` is the one scheduling uses.
fn wall_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn date_words(p: &Parts) -> String {
    let mut text = chat_meta::date_label(p);
    if local_parts(wall_ms())
        .map(|now| chat_meta::day_key(&now) == chat_meta::day_key(p))
        .unwrap_or(false)
    {
        text.push(' ');
        text.push_str(&crate::i18n::tr("Today"));
    }
    text
}

fn channel_words(channel: u64) -> String {
    match chat_meta::channel_of(channel) {
        chat_meta::Channel::Group => crate::i18n::tr("Group chat"),
        chat_meta::Channel::Task(n) => {
            format!("{} #{n}", crate::i18n::tr("Task"))
        }
    }
}

fn members_words(count: u32) -> String {
    if count == 1 {
        format!("1 {}", crate::i18n::tr("Member"))
    } else {
        format!("{count} {}", crate::i18n::tr("Members"))
    }
}

/// The search panel's width, in points, as the design gives it.
pub const SIDEBAR_PT: f64 = 330.0;

/// The one right-hand slot: closed or search today, preview later. **One
/// mode at a time**, never two panels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sidebar {
    Closed,
    Search,
}

/// What the one right-hand slot is **showing**. The search's query and
/// results live separately and survive a switch to preview.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SidebarMode {
    Closed,
    Search,
    Preview,
}

fn sidebar_of(open: bool) -> Sidebar {
    if open {
        Sidebar::Search
    } else {
        Sidebar::Closed
    }
}

/// Whether a chat this wide puts the side panel and the message column **side
/// by side**. Below it the panel **covers** the message column's right edge
/// instead of squeezing it: 330 points of panel beside a narrower column
/// leaves too little to read. The number is the product's own
/// `cell_min_width_side_by_side`, not the design's canvas width (the user's
/// ruling of 2026-11-05, task 2970).
fn side_by_side(metrics: &Metrics, total: i32) -> bool {
    (total as f64) >= look::preview::CELL_MIN_WIDTH_SIDE_BY_SIDE * metrics.scale
}

/// Where the side panel and the message pane divide, in pixels: the message
/// column's right edge, and the panel's width. **Side by side**, the column
/// stops where the panel's divider begins; **covered**, the column keeps the
/// whole client width and the panel is painted over its right edge.
fn split(
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
    side: Sidebar,
) -> (i32, i32) {
    let total = (client.right - client.left).max(1);
    let width = match side {
        Sidebar::Closed => 0,
        Sidebar::Search => ((SIDEBAR_PT * metrics.scale) as i32)
            .min(total / 2)
            .max(metrics.pad * 8),
    };
    if width == 0 {
        return (client.right, 0);
    }
    if !side_by_side(metrics, total) {
        return (client.right, width);
    }
    (client.right - width - divider_width(metrics), width)
}

/// The side panel's own left edge, in pixels. Side by side it is the divider's
/// right side; covered it is still the client's right edge minus its width.
fn panel_left(client: &windows::Win32::Foundation::RECT, side_w: i32) -> i32 {
    client.right - side_w
}

/// The divider between the message column and the panel, in pixels: one
/// device-independent line, rounded up. **One expression, one place** -- the
/// split and the paint both ask here.
fn divider_width(metrics: &Metrics) -> i32 {
    metrics.scale.round().max(1.0) as i32
}

/// The search panel's controls, fixed under the header line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SideGeom {
    left: i32,
    width: i32,
    input: (i32, i32, i32, i32),
    close: (i32, i32, i32, i32),
    results_top: i32,
    results_bottom: i32,
}

fn side_geom(
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
    left: i32,
    width: i32,
) -> SideGeom {
    let top = client.top + metrics.pad;
    let close_w = metrics.line + metrics.gap;
    let input_h = metrics.line + metrics.gap;
    let input = (
        left + metrics.pad,
        top,
        (width - metrics.pad * 2 - close_w).max(1),
        input_h,
    );
    let close = (left + width - metrics.pad - close_w, top, close_w, input_h);
    SideGeom {
        left,
        width,
        input,
        close,
        results_top: top + input_h + metrics.gap,
        results_bottom: client.bottom - metrics.pad,
    }
}

/// Where the fixed header's parts are, in the window's pixels. **The
/// header never scrolls**: the message viewport starts under `total`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct HeaderGeom {
    total: i32,
    title_y: i32,
    brief_y: i32,
    brief_h: i32,
    toggle_y: i32,
    toggle_h: i32,
    member: (i32, i32, i32, i32),
    /// The toolbar's search entry, left of the member chip.
    search: (i32, i32, i32, i32),
    toggle: (i32, i32, i32, i32),
    overflow: bool,
}

fn header_geom(
    dc: HDC,
    left: i32,
    top: i32,
    width: i32,
    metrics: &Metrics,
    meta: Option<&chat_read::Metadata>,
    expanded: bool,
) -> HeaderGeom {
    let brief = meta.map_or("", |m| m.brief.as_str());
    let full_h = if brief.is_empty() {
        0
    } else {
        unsafe { calc_height(dc, brief, width.max(1), DrawTextFlags::wrap()) }.max(0)
    };
    let lines = if metrics.line > 0 {
        (full_h + metrics.line - 1) / metrics.line
    } else {
        0
    };
    let (shown, overflow) = if expanded {
        (lines.min(12), lines > 12)
    } else {
        (lines.min(2), lines > 2)
    };
    let title_y = top;
    let title_h = metrics.line;
    let brief_y = title_y + title_h;
    let brief_h = shown * metrics.line;
    let toggle_shown = overflow || (expanded && lines > 2);
    let toggle_y = brief_y + brief_h;
    let toggle_h = if toggle_shown { metrics.line } else { 0 };
    let total = title_h + brief_h + toggle_h + metrics.gap;

    let body = crate::uifont::make(
        (metrics.scale * 96.0).round() as i32,
        look::font::BODY.round() as i32,
        look::font::WEIGHT_BODY.round() as i32,
        crate::uifont::ui_face(),
    );
    let member_text = meta.map_or(String::new(), |m| members_words(m.member_count));
    let member_w = if member_text.is_empty() {
        0
    } else {
        measure_in(dc, body, &member_text) + metrics.pad
    };
    let toggle_text = if expanded {
        crate::i18n::tr("Show less")
    } else {
        crate::i18n::tr("Show more")
    };
    let toggle_w = measure_in(dc, body, &toggle_text) + metrics.pad;
    let search_text = "\u{2315}";
    let search_w = measure_in(dc, body, search_text) + metrics.pad;
    unsafe {
        let _ = DeleteObject(body.into());
    }
    HeaderGeom {
        total,
        title_y,
        brief_y,
        brief_h,
        toggle_y,
        toggle_h,
        member: (
            left + width - member_w,
            title_y,
            member_w.min(width),
            title_h,
        ),
        search: (
            left + width - member_w - search_w.max(1),
            title_y,
            search_w.min(width).max(1),
            title_h,
        ),
        toggle: (
            left + width - toggle_w.max(1),
            toggle_y,
            toggle_w.min(width).max(1),
            toggle_h.max(1),
        ),
        overflow,
    }
}

/// The header: the group's name, its brief (two lines unless expanded) and
/// the member entry. **Fixed above the rows and never scrolled with them.**
fn paint_header(
    dc: HDC,
    left: i32,
    width: i32,
    top: i32,
    metrics: &Metrics,
    theme: &look::Theme,
    group: &str,
    meta: Option<&chat_read::Metadata>,
    expanded: bool,
    members_open: bool,
) -> HeaderGeom {
    let geom = header_geom(dc, left, top, width, metrics, meta, expanded);
    let title = format!("# {group}");
    let _ = draw_text(dc, &title, left, geom.title_y, width, theme.text);

    // The member entry is a chip, right-aligned in the title line.
    let body = unsafe {
        crate::uifont::make(
            (metrics.scale * 96.0).round() as i32,
            look::font::BODY.round() as i32,
            look::font::WEIGHT_BODY.round() as i32,
            crate::uifont::ui_face(),
        )
    };
    // The toolbar's search entry.
    let (sx, sy, sw, sh) = geom.search;
    unsafe {
        let brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row));
        let r = windows::Win32::Foundation::RECT {
            left: sx,
            top: sy,
            right: sx + sw,
            bottom: sy + sh,
        };
        let _ = FillRect(dc, &r, brush);
        let _ = DeleteObject(brush.into());
    }
    let _ = draw_text(
        dc,
        "\u{2315}",
        sx + metrics.pad / 2,
        sy,
        sw,
        theme.text_secondary,
    );
    let (mx, my, mw, mh) = geom.member;
    if let Some(meta) = meta {
        let member_text = members_words(meta.member_count);
        unsafe {
            let brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row));
            let r = windows::Win32::Foundation::RECT {
                left: mx,
                top: my,
                right: mx + mw,
                bottom: my + mh,
            };
            let _ = FillRect(dc, &r, brush);
            let _ = DeleteObject(brush.into());
            let old = SelectObject(dc, body.into());
            let mut wide: Vec<u16> = member_text.encode_utf16().collect();
            let mut r = windows::Win32::Foundation::RECT {
                left: mx + metrics.pad / 2,
                top: my,
                right: mx + mw,
                bottom: my + mh,
            };
            SetTextColor(dc, crate::control_room::rgb(theme.text_secondary));
            let _ =
                crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::single_line());
            SelectObject(dc, old);
        }
    }

    if let Some(meta) = meta {
        if !meta.brief.is_empty() {
            unsafe {
                let saved = SaveDC(dc);
                let r = windows::Win32::Foundation::RECT {
                    left,
                    top: geom.brief_y,
                    right: left + width,
                    bottom: geom.brief_y + geom.brief_h.max(1),
                };
                IntersectClipRect(dc, r.left, r.top, r.right, r.bottom);
                SetTextColor(dc, crate::control_room::rgb(theme.text_secondary));
                let mut wide: Vec<u16> = meta.brief.encode_utf16().collect();
                let mut r = r;
                let _ = crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::wrap());
                let _ = RestoreDC(dc, saved);
            }
        }
        if geom.overflow || (expanded && !meta.brief.is_empty()) {
            let word = if expanded {
                crate::i18n::tr("Show less")
            } else {
                crate::i18n::tr("Show more")
            };
            let _ = draw_text(
                dc,
                &word,
                geom.toggle.0 + metrics.pad / 2,
                geom.toggle_y,
                geom.toggle.2,
                theme.attention_text,
            );
        }
    }
    unsafe {
        let _ = DeleteObject(body.into());
        let brush = CreateSolidBrush(crate::control_room::rgb(theme.line_faint));
        let r = windows::Win32::Foundation::RECT {
            left,
            top: top + geom.total - metrics.gap / 2,
            right: left + width,
            bottom: top + geom.total - metrics.gap / 2 + 1,
        };
        let _ = FillRect(dc, &r, brush);
        let _ = DeleteObject(brush.into());
    }
    let _ = members_open;
    geom
}

/// The member popover: names and roles, under the member entry. **A view,
/// not an action**: no terminal is started, nobody is asked anything.
fn members_rect(
    left: i32,
    width: i32,
    top: i32,
    metrics: &Metrics,
    count: usize,
) -> (i32, i32, i32, i32) {
    let panel_w = width.min((metrics.pad * 24).max(220));
    let rows = count.min(200) as i32;
    let head = metrics.line + metrics.gap;
    let panel_h = (head + rows * metrics.line + metrics.gap).min(metrics.line * 20);
    (left + width - panel_w, top, panel_w, panel_h)
}

fn paint_members(
    dc: HDC,
    left: i32,
    width: i32,
    top: i32,
    metrics: &Metrics,
    theme: &look::Theme,
    meta: &chat_read::Metadata,
) -> (i32, i32, i32, i32) {
    let (x, y, panel_w, panel_h) = members_rect(left, width, top, metrics, meta.members.len());
    let head = metrics.line + metrics.gap;
    unsafe {
        let brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row));
        let r = windows::Win32::Foundation::RECT {
            left: x,
            top: y,
            right: x + panel_w,
            bottom: y + panel_h,
        };
        let _ = FillRect(dc, &r, brush);
        let _ = DeleteObject(brush.into());
        let edge = CreateSolidBrush(crate::control_room::rgb(theme.line));
        let border = windows::Win32::Foundation::RECT {
            left: x,
            top: y,
            right: x + panel_w,
            bottom: y + 1,
        };
        let _ = FillRect(dc, &border, edge);
        let _ = DeleteObject(edge.into());
    }
    let head_word = format!("{} ({})", crate::i18n::tr("Members"), meta.member_count);
    let _ = draw_text(
        dc,
        &head_word,
        x + metrics.pad / 2,
        y + metrics.gap / 2,
        panel_w - metrics.pad,
        theme.text,
    );
    let body = unsafe {
        crate::uifont::make(
            (metrics.scale * 96.0).round() as i32,
            look::font::BODY.round() as i32,
            look::font::WEIGHT_BODY.round() as i32,
            crate::uifont::ui_face(),
        )
    };
    unsafe {
        let old = SelectObject(dc, body.into());
        for (i, member) in meta.members.iter().take(200).enumerate() {
            let line = format!("{}  {}", member.title, member.role.as_deref().unwrap_or(""));
            let mut wide: Vec<u16> = line.encode_utf16().collect();
            let mut r = windows::Win32::Foundation::RECT {
                left: x + metrics.pad / 2,
                top: y + head + i as i32 * metrics.line,
                right: x + panel_w - metrics.pad / 2,
                bottom: y + head + (i as i32 + 1) * metrics.line,
            };
            SetTextColor(dc, crate::control_room::rgb(theme.text));
            let _ =
                crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::single_line());
        }
        SelectObject(dc, old);
        let _ = DeleteObject(body.into());
    }
    (x, y, panel_w, panel_h)
}

fn search_card_height(metrics: &Metrics) -> i32 {
    metrics.line * 3 + metrics.gap
}

/// One result card: author, role, time and channel on the first line, the
/// snippet under it with the core's UTF-8 ranges lit.
fn draw_hit(
    dc: HDC,
    hit: &chat_read::Hit,
    left: i32,
    top: i32,
    width: i32,
    metrics: &Metrics,
    theme: &look::Theme,
    selected: bool,
) {
    let height = search_card_height(metrics) - metrics.gap;
    unsafe {
        let brush = CreateSolidBrush(crate::control_room::rgb(if selected {
            theme.surface_row_selected
        } else {
            theme.surface_row
        }));
        let r = windows::Win32::Foundation::RECT {
            left,
            top,
            right: left + width,
            bottom: top + height,
        };
        let _ = FillRect(dc, &r, brush);
        let _ = DeleteObject(brush.into());
    }
    let message = &hit.message;
    let author = if message.author.is_empty() {
        message.from.as_str()
    } else {
        message.author.as_str()
    };
    let mut x = left + metrics.pad / 2;
    let meta_y = top + metrics.gap / 2;
    let _ = draw_text(dc, author, x, meta_y, width - metrics.pad, theme.text);
    let body = unsafe {
        crate::uifont::make(
            (metrics.scale * 96.0).round() as i32,
            look::font::BODY.round() as i32,
            look::font::WEIGHT_BODY.round() as i32,
            crate::uifont::ui_face(),
        )
    };
    x += measure_in(dc, body, author) + metrics.pad / 2;
    if let Some(role) = message.role.as_deref().filter(|r| !r.is_empty()) {
        draw_chip(
            dc,
            role,
            &mut x,
            meta_y,
            metrics.line,
            metrics,
            theme,
            theme.surface_row_selected,
            theme.text_secondary,
        );
    }
    // **Date and time both**, as the result card promised.
    if let Some(parts) = local_parts(message.at_ms) {
        let stamp = format!(
            "{} {}",
            chat_meta::date_label(&parts),
            chat_meta::time_label(&parts)
        );
        let tw = measure_in(dc, body, &stamp);
        let tx = (left + width - metrics.pad / 2 - tw).max(x);
        let _ = draw_text(dc, &stamp, tx, meta_y, tw.max(1), theme.text_tertiary);
    }
    // The snippet, piece by piece: the ranges are byte offsets into this
    // exact substring (validated by `chat_read`), so each piece is drawn
    // where it really is.
    let snippet = hit.snippet.replace(['\n', '\r'], " ");
    let snip_y = top + metrics.line + metrics.gap / 2;
    let snip_h = metrics.line * 2;
    unsafe {
        let saved = SaveDC(dc);
        IntersectClipRect(dc, left, snip_y, left + width, snip_y + snip_h);
        let mut at = 0usize;
        let mut sx = left + metrics.pad / 2;
        let text_w = (width - metrics.pad).max(1);
        let mut draw_segment = |segment: &str, lit: bool, sx: &mut i32| {
            if segment.is_empty() {
                return;
            }
            let w = measure_in(dc, body, segment);
            if lit {
                // The found word: the design's own ground and ink, from the
                // one look table both hosts share. **Translucent**, so it is
                // composited over the card rather than painted solid.
                let r = windows::Win32::Foundation::RECT {
                    left: *sx,
                    top: snip_y,
                    right: *sx + w,
                    bottom: snip_y + snip_h,
                };
                crate::control_room::fill_rgba(dc, &r, theme.search_hit);
            }
            let mut wide: Vec<u16> = segment.encode_utf16().collect();
            let mut r = windows::Win32::Foundation::RECT {
                left: *sx,
                top: snip_y,
                right: (*sx + w).min(left + text_w),
                bottom: snip_y + snip_h,
            };
            SetTextColor(
                dc,
                crate::control_room::rgb(if lit {
                    theme.search_hit_text
                } else {
                    theme.text
                }),
            );
            let _ =
                crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::single_line());
            *sx += w;
        };
        for range in &hit.ranges {
            let start = (range.start as usize).min(snippet.len());
            let end = (range.end as usize).min(snippet.len());
            if start < at || start > end {
                continue;
            }
            if !snippet.is_char_boundary(start) || !snippet.is_char_boundary(end) {
                continue;
            }
            draw_segment(&snippet[at..start], false, &mut sx);
            draw_segment(&snippet[start..end], true, &mut sx);
            at = end;
        }
        draw_segment(&snippet[at..], false, &mut sx);
        let _ = RestoreDC(dc, saved);
        let _ = DeleteObject(body.into());
    }
    let _ = x;
}

/// After a release, put the card the person was looking at back at the
/// top: identity, not the old pixel offset.
fn sync_search_anchor(hwnd: HWND) {
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return;
        };
        let Some(anchor) = chat.search_anchor.clone() else {
            return;
        };
        let Some(feed) = chat.feed.as_ref() else {
            return;
        };
        // **Wait for the page that caused the release**, not for the old
        // list that still happens to contain the anchor.
        if matches!(feed.search_state(), chat_feed::SearchState::Loading) {
            return;
        }
        let index = feed
            .search_results()
            .iter()
            .position(|hit| hit.message.anchor == anchor);
        let selected = chat.search_selected_anchor.as_ref().and_then(|wanted| {
            feed.search_results()
                .iter()
                .position(|hit| &hit.message.anchor == wanted)
        });
        drop(feed);
        chat.search_selected = selected;
        if selected.is_none() {
            chat.search_selected_anchor = None;
        }
        match index {
            Some(i) => {
                let card_h = search_card_height(&Metrics::for_dpi(crate::dpi_for(hwnd) as i32));
                chat.search_scroll = i as i32 * card_h.max(1);
                chat.search_anchor = None;
            }
            None => {
                // The card was released itself; the list starts at the
                // top and the banner explains why.
                chat.search_scroll = 0;
                chat.search_anchor = None;
            }
        }
    });
}

/// The panel's footer: locating status, a load-more entry, or a retry.
fn search_footer(feed: &Feed) -> Option<String> {
    if feed.aux_busy() {
        Some(crate::i18n::tr("Locating…"))
    } else if feed.aux_error().is_some() {
        Some(crate::i18n::tr("Could not locate that message."))
    } else if feed.search_full() {
        Some(crate::i18n::tr("Load older results"))
    } else if feed.search_can_more() {
        Some(crate::i18n::tr("Load more results"))
    } else if matches!(
        feed.search_state(),
        chat_feed::SearchState::Failed(_) | chat_feed::SearchState::Cancelled
    ) && feed.search_query().is_some()
    {
        Some(crate::i18n::tr("Retry search"))
    } else {
        None
    }
}

/// The right-hand search panel. **It never replaces the conversation**:
/// the left side keeps its rows and its scroll anchor.
#[allow(clippy::too_many_arguments)]
fn paint_search(
    dc: HDC,
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
    theme: &look::Theme,
    g: SideGeom,
    feed: &Feed,
    query: &str,
    selected: Option<usize>,
    scroll: i32,
    missing: bool,
) {
    // The input.
    unsafe {
        let brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row));
        let r = windows::Win32::Foundation::RECT {
            left: g.input.0,
            top: g.input.1,
            right: g.input.0 + g.input.2,
            bottom: g.input.1 + g.input.3,
        };
        let _ = FillRect(dc, &r, brush);
        let _ = DeleteObject(brush.into());
    }
    let shown = if query.is_empty() {
        crate::i18n::tr("Search messages…")
    } else {
        format!("{query}|")
    };
    let _ = draw_text(
        dc,
        &shown,
        g.input.0 + metrics.pad / 2,
        g.input.1,
        g.input.2 - metrics.pad,
        if query.is_empty() {
            theme.text_tertiary
        } else {
            theme.text
        },
    );
    let _ = draw_text(
        dc,
        "\u{00d7}",
        g.close.0,
        g.close.1,
        g.close.2,
        theme.text_secondary,
    );
    let heading = if feed.search_released() {
        crate::i18n::tr("Newer results were released. Search again for the newest.")
    } else {
        crate::i18n::tr("Search this group")
    };
    let heading_colour = if feed.search_released() {
        theme.attention_text
    } else {
        theme.text_secondary
    };
    let _ = draw_text(
        dc,
        &heading,
        g.left + metrics.pad,
        g.results_top,
        g.width - metrics.pad * 2,
        heading_colour,
    );
    let list_top = g.results_top + metrics.line + metrics.gap;

    let results = feed.search_results();
    let note = if missing {
        Some(crate::i18n::tr("That message is not loaded here."))
    } else {
        match feed.search_state() {
            chat_feed::SearchState::Idle => None,
            chat_feed::SearchState::Loading if results.is_empty() => {
                Some(crate::i18n::tr("Searching…"))
            }
            chat_feed::SearchState::Failed(code) => {
                Some(crate::i18n::tr(chat_rows::trouble_word(code)))
            }
            chat_feed::SearchState::Gap => Some(crate::i18n::tr("Some records could not be read.")),
            chat_feed::SearchState::Cancelled => Some(crate::i18n::tr("Loading was cancelled.")),
            chat_feed::SearchState::End if results.is_empty() => {
                Some(crate::i18n::tr("No results."))
            }
            _ => None,
        }
    };
    if let Some(note) = note {
        let _ = draw_text(
            dc,
            &note,
            g.left + metrics.pad,
            list_top,
            g.width - metrics.pad * 2,
            theme.text_secondary,
        );
    }

    let footer = search_footer(feed);
    let footer_h = if footer.is_some() {
        metrics.line + metrics.gap
    } else {
        0
    };
    let cards_bottom = g.results_bottom - footer_h;
    if let Some(word) = &footer {
        let _ = draw_text(
            dc,
            word,
            g.left + metrics.pad,
            cards_bottom,
            g.width - metrics.pad * 2,
            theme.attention_text,
        );
    }
    // The cards, newest first, scrolled inside the panel.
    let card_h = search_card_height(metrics);
    let visible = ((cards_bottom - list_top) / card_h.max(1)).max(0) as usize;
    let first = (scroll.max(0) as usize / card_h.max(1) as usize).min(results.len());
    let last = (first + visible + 2).min(results.len());
    unsafe {
        let saved = SaveDC(dc);
        IntersectClipRect(dc, g.left, list_top, g.left + g.width, cards_bottom);
        for (i, hit) in results.iter().enumerate().take(last).skip(first) {
            let y = list_top + i as i32 * card_h - scroll;
            if y + card_h <= list_top || y >= cards_bottom {
                continue;
            }
            draw_hit(
                dc,
                hit,
                g.left + metrics.pad / 2,
                y,
                g.width - metrics.pad,
                metrics,
                theme,
                selected == Some(i),
            );
        }
        let _ = RestoreDC(dc, saved);
    }
}

fn preview_parts(
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
    left: i32,
    width: i32,
) -> (
    (i32, i32, i32, i32),
    (i32, i32, i32, i32),
    (i32, i32, i32, i32),
) {
    let top = client.top + metrics.pad;
    let close_w = metrics.line + metrics.gap;
    let header = (
        left + metrics.pad,
        top,
        (width - metrics.pad * 2 - close_w).max(1),
        metrics.line,
    );
    let close = (
        left + width - metrics.pad - close_w,
        top,
        close_w,
        metrics.line,
    );
    let body = (
        left + metrics.pad,
        top + metrics.line + metrics.gap,
        (width - metrics.pad * 2).max(1),
        (client.bottom - metrics.pad - (top + metrics.line + metrics.gap)).max(1),
    );
    (header, close, body)
}

/// The preview panel's own chrome: the file's name, close, and a way back to
/// the search that opened it. The page itself is the shared WebView2 child.
#[allow(clippy::too_many_arguments)]
fn paint_preview(
    dc: HDC,
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
    theme: &look::Theme,
    left: i32,
    width: i32,
    label: Option<&str>,
    error: Option<&str>,
    back_to_search: bool,
) -> (i32, i32, i32, i32) {
    let (header, close, body) = preview_parts(client, metrics, left, width);
    let title = match label {
        Some(label) => label.to_owned(),
        None => crate::i18n::tr("Preview"),
    };
    let back_w = if back_to_search { metrics.line * 5 } else { 0 };
    if back_to_search {
        let _ = draw_text(
            dc,
            "\u{2190}",
            header.0,
            header.1,
            metrics.line,
            theme.attention_text,
        );
        let _ = draw_text(
            dc,
            &crate::i18n::tr("Search"),
            header.0 + metrics.line,
            header.1,
            back_w,
            theme.attention_text,
        );
    }
    let _ = draw_text(
        dc,
        &title,
        header.0 + back_w + metrics.gap,
        header.1,
        header.2.saturating_sub(back_w + metrics.gap),
        theme.text,
    );
    let _ = draw_text(
        dc,
        "\u{00d7}",
        close.0,
        close.1,
        close.2,
        theme.text_secondary,
    );
    if let Some(error) = error {
        let _ = draw_text(dc, error, body.0, body.1, body.2, theme.text_secondary);
    }
    body
}

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
            brief_open,
            members_open,
            new_rows,
            highlight,
            text_highlight,
            view_h: view_height,
            side: side_mode,
            search_query,
            search_selected,
            search_scroll,
            search_missing,
            search_edit,
            preview_token,
            preview_pending,
            preview_label,
            preview_error,
            preview_back_search,
            preview_loading,
            ..
        } = chat;
        let Some(feed) = feed.as_ref() else {
            return;
        };

        let left = client.left + metrics.pad;
        let side = sidebar_of(*side_mode != SidebarMode::Closed);
        let (messages_right, side_w) = split(&client, &metrics, side);
        let msg = message_rect(
            dc,
            &client,
            &metrics,
            feed,
            *side_mode != SidebarMode::Closed,
            *brief_open,
        );
        let width = msg.width;
        let meta = feed.metadata();
        let header = paint_header(
            dc,
            left,
            width,
            client.top + metrics.pad,
            &metrics,
            &theme,
            group.as_str(),
            meta,
            *brief_open,
            *members_open,
        );
        // The older-history strip stays at the top of the message pane,
        // below the fixed header. It is the state, not a floating note.
        let msg_top = msg.strip_top;
        let later = later_words(feed);
        let later_h = if later.is_some() {
            metrics.line + metrics.gap
        } else {
            0
        };
        let view_h = msg.height;
        *view_height = view_h;
        if let Some((word, _)) = &later {
            let _ = draw_text(
                dc,
                word,
                left + metrics.pad / 2,
                client.bottom - metrics.pad - later_h,
                width - metrics.pad,
                theme.text_tertiary,
            );
        }
        let (boundary, _retry) = boundary_words(feed);
        let _ = draw_text(
            dc,
            &boundary,
            left + metrics.pad / 2,
            msg_top,
            width - metrics.pad,
            theme.text_tertiary,
        );

        let mut top = msg.top;
        // **Loading is not empty, and a raw code is not product copy.** The
        // feed's state picks the sentence; the code stays in the log.
        let note = if feed.rows().is_empty() {
            if let Some(code) = feed.trouble() {
                Some(crate::i18n::tr(chat_rows::trouble_word(code)))
            } else {
                let load = match feed.load() {
                    chat_feed::Load::Loading => chat_rows::Load::Loading,
                    chat_feed::Load::Empty => chat_rows::Load::Empty,
                    chat_feed::Load::Cancelled => chat_rows::Load::Cancelled,
                    chat_feed::Load::Gap => chat_rows::Load::Gap,
                    chat_feed::Load::Ready => chat_rows::Load::Ready,
                };
                chat_rows::load_word(load).map(crate::i18n::tr)
            }
        } else {
            None
        };
        if let Some(note) = note {
            top = draw_text(dc, &note, left, top, width, theme.text_secondary);
        }

        // The rows themselves, drawn from the cached heights.
        // The viewport is already the message pane; only a placeholder
        // note above the rows takes more of it.
        let rows_view = (view_h - (top - msg.top).max(0)).max(metrics.line);
        let range = layout.visible(*scroll, rows_view);
        for i in range {
            let Some(row) = feed.rows().get(i) else {
                continue;
            };
            let measured = &layout.rows()[i];
            let y = top + measured.top - *scroll;
            if y + measured.height <= client.top || y >= client.bottom {
                continue;
            }
            // A handoff summary is a card of its own, and a located message
            // is lit whole for a moment (search increment).
            let lit = highlight.as_ref().is_some_and(|(id, at)| {
                id == &row.id && at.elapsed() < std::time::Duration::from_millis(2500)
            });
            // The rendered text ranges belong to the same located moment as
            // the whole-row light; the anchor may be a live alias while the
            // row has been promoted to its persisted identity.
            let text_hits = if lit {
                text_highlight.as_ref().and_then(|(anchor, ranges)| {
                    (row.message.anchor == *anchor
                        || row.message.live_anchor.as_deref() == Some(anchor.as_str()))
                    .then_some(ranges.as_slice())
                })
            } else {
                None
            };
            if row.message.summary || lit {
                // A located message wears the design's target ground and its
                // 3px left edge; a handoff summary keeps the plain row ground.
                let fill = if lit {
                    theme.search_target
                } else {
                    theme.surface_row
                };
                let bottom = y + (measured.height - metrics.gap).max(1);
                unsafe {
                    let r = windows::Win32::Foundation::RECT {
                        left,
                        top: y,
                        right: left + width,
                        bottom,
                    };
                    // `search_target` carries alpha: composited, never solid.
                    crate::control_room::fill_rgba(dc, &r, fill);
                    if lit {
                        let edge = (3.0 * metrics.scale).round().max(1.0) as i32;
                        let r = windows::Win32::Foundation::RECT {
                            left,
                            top: y,
                            right: left + edge,
                            bottom,
                        };
                        crate::control_room::fill_rgba(dc, &r, theme.search_target_edge);
                    }
                }
            }
            if measured.date {
                draw_date_divider(
                    dc,
                    row.message.at_ms,
                    left,
                    y,
                    width,
                    measured.date_height,
                    &metrics,
                    &theme,
                );
            }
            draw_meta_line(
                dc,
                row,
                left,
                y + measured.date_height,
                width,
                measured.author_height,
                &metrics,
                &theme,
            );
            let text_top = y + measured.date_height + measured.author_height;
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
                            messages_right,
                            width,
                            row_bottom,
                            text_hits,
                            *theme,
                        ),
                        _ => draw_block(dc, &row.message.text, left, text_top, width, row_bottom),
                    }
                }
            }
        }

        // The one right-hand slot. A divider belongs to the split, not
        // to either side; **covered**, the panel brings its own ground and
        // edge, because the message column runs on underneath it.
        if side_w > 0 {
            let divider = divider_width(&metrics);
            let side_left = panel_left(&client, side_w);
            unsafe {
                if side_by_side(&metrics, client.right - client.left) {
                    let brush = CreateSolidBrush(crate::control_room::rgb(theme.line));
                    let r = windows::Win32::Foundation::RECT {
                        left: messages_right,
                        top: client.top,
                        right: messages_right + divider,
                        bottom: client.bottom,
                    };
                    let _ = FillRect(dc, &r, brush);
                    let _ = DeleteObject(brush.into());
                } else {
                    let ground =
                        CreateSolidBrush(crate::control_room::rgb(theme.terminal_background));
                    let r = windows::Win32::Foundation::RECT {
                        left: side_left,
                        top: client.top,
                        right: client.right,
                        bottom: client.bottom,
                    };
                    let _ = FillRect(dc, &r, ground);
                    let _ = DeleteObject(ground.into());
                    let edge = CreateSolidBrush(crate::control_room::rgb(theme.line));
                    let r = windows::Win32::Foundation::RECT {
                        left: side_left,
                        top: client.top,
                        right: side_left + 1,
                        bottom: client.bottom,
                    };
                    let _ = FillRect(dc, &r, edge);
                    let _ = DeleteObject(edge.into());
                }
            }
            let sg = side_geom(&client, &metrics, side_left, side_w);
            if *side_mode != SidebarMode::Preview && *search_edit != 0 {
                unsafe {
                    let _ = MoveWindow(
                        HWND(*search_edit as *mut c_void),
                        sg.input.0,
                        sg.input.1,
                        sg.input.2,
                        sg.input.3,
                        true,
                    );
                }
            }
            if *side_mode == SidebarMode::Preview {
                let status = if let Some(error) = preview_error.as_deref() {
                    Some(error.to_owned())
                } else if *preview_loading {
                    Some(crate::i18n::tr("Loading…"))
                } else {
                    let slot = preview_page::SlotKey::chat(group.as_str(), hwnd);
                    match preview_page::state(&slot) {
                        Some(settings_shell_page_state::RuntimeMissing) => {
                            Some(crate::i18n::tr("WebView2 Runtime is not installed."))
                        }
                        Some(settings_shell_page_state::LoaderMissing) => {
                            Some(crate::i18n::tr("The WebView2 loader is missing."))
                        }
                        Some(settings_shell_page_state::Failed(_)) => {
                            Some(crate::i18n::tr("Could not show this file."))
                        }
                        _ => None,
                    }
                };
                let _ = paint_preview(
                    dc,
                    &client,
                    &metrics,
                    &theme,
                    side_left,
                    side_w,
                    preview_label.as_deref(),
                    status.as_deref(),
                    *preview_back_search,
                );
            } else {
                paint_search(
                    dc,
                    &client,
                    &metrics,
                    &theme,
                    sg,
                    feed,
                    search_query,
                    *search_selected,
                    *search_scroll,
                    *search_missing,
                );
            }
        }

        // The member popover is drawn over the rows and above the header's
        // message area; it is a view, not a second page.
        if *members_open {
            if let Some(meta) = meta {
                let _ = paint_members(dc, left, width, msg_top, &metrics, &theme, meta);
            }
        }

        // "New messages" / "Back to latest": shown only when there is
        // somewhere to return to, or something waiting there.
        if let Some(word) = latest_words(feed, *new_rows) {
            let body = unsafe {
                crate::uifont::make(
                    (metrics.scale * 96.0).round() as i32,
                    look::font::BODY.round() as i32,
                    look::font::WEIGHT_BODY.round() as i32,
                    crate::uifont::ui_face(),
                )
            };
            let tw = measure_in(dc, body, &word);
            let h = metrics.line + metrics.gap;
            let w = tw + metrics.pad * 2;
            // **Covered, the panel is on top**: the pill keeps to the part of
            // the message column still visible, instead of landing under the
            // panel and being painted over.
            let visible_right = if side_w > 0 && !side_by_side(&metrics, client.right - client.left)
            {
                panel_left(&client, side_w)
            } else {
                left + width
            };
            let x = (visible_right - w).max(left);
            let y = client.bottom - metrics.pad - h;
            unsafe {
                let brush = CreateSolidBrush(crate::control_room::rgb(theme.surface_row_selected));
                let r = windows::Win32::Foundation::RECT {
                    left: x,
                    top: y,
                    right: x + w,
                    bottom: y + h,
                };
                let _ = FillRect(dc, &r, brush);
                let _ = DeleteObject(brush.into());
                let _ = DeleteObject(body.into());
            }
            let _ = draw_text(
                dc,
                &word,
                x + metrics.pad,
                y + metrics.gap / 2,
                tw.max(1),
                theme.attention_text,
            );
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
    // The selected hit's raw ranges, when this row is the located one.
    text_hits: Option<&[std::ops::Range<usize>]>,
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
                                let base = table_top(&table.block, top);
                                paint_piece_hits(dc, &fonts, piece, runs, text_hits, base, draw_left, theme);
                                draw_piece(dc, &fonts, piece, runs, base, draw_left, theme);
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
                                    let base = table_top(&table.block, top);
                                    paint_piece_hits(dc, &fonts, piece, runs, text_hits, base, draw_left, theme);
                                    draw_piece(dc, &fonts, piece, runs, base, draw_left, theme);
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
                    let code_block = match doc.blocks.get(block_index) {
                        Some(polter_chat_markdown::Block::Code { text, spans, .. }) => {
                            Some((text.as_str(), spans.as_slice()))
                        }
                        _ => None,
                    };
                    let code_text = code_block.map(|(text, _)| text);
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
                            if let Some((code, spans)) = code_block {
                                // **A code block's pieces index its own
                                // text**, so the hit maps through the
                                // block's spans before the line clip.
                                if let Some(hits) = text_hits {
                                    for hit in hits {
                                        for range in
                                            polter_chat_markdown::display_ranges(spans, hit.clone())
                                        {
                                            let start = range.start.max(piece.text.start);
                                            let end = range.end.min(piece.text.end);
                                            if start >= end {
                                                continue;
                                            }
                                            let rel = start - piece.text.start
                                                ..end - piece.text.start;
                                            let (Some(prefix), Some(mid)) = (
                                                code.get(piece.text.start..piece.text.start + rel.start),
                                                code.get(piece.text.start + rel.start
                                                    ..piece.text.start + rel.end),
                                            ) else {
                                                continue;
                                            };
                                            let font = plan_font(&fonts, piece.kind);
                                            let x = piece.rect.x + measure_in(dc, font, prefix);
                                            let w = measure_in(dc, font, mid).max(1);
                                            unsafe {
                                                // Fenced code is message text
                                                // too: the same composited
                                                // hit ground as a paragraph
                                                // or a table cell.
                                                let r = windows::Win32::Foundation::RECT {
                                                    left: draw_left + x,
                                                    top: top + piece.rect.y,
                                                    right: draw_left + x + w,
                                                    bottom: top + piece.rect.y + piece.rect.h.max(1),
                                                };
                                                crate::control_room::fill_rgba(
                                                    dc,
                                                    &r,
                                                    theme.search_hit,
                                                );
                                            }
                                        }
                                    }
                                }
                                let slice = code.get(piece.text.clone()).unwrap_or("");
                                draw_text_slice(dc, &fonts, piece, slice, top, draw_left, theme);
                            } else {
                                paint_piece_hits(dc, &fonts, piece, runs, text_hits, block_top, draw_left, theme);
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
                let rail_brush = CreateSolidBrush(crate::control_room::rgb(theme.text_tertiary));
                let rail = windows::Win32::Foundation::RECT {
                    left: left + track.x,
                    top: top + track.y,
                    right: left + track.x + track.w,
                    bottom: top + track.y + track.h,
                };
                let _ = FillRect(dc, &rail, rail_brush);
                let _ = DeleteObject(rail_brush.into());
                let thumb_brush = CreateSolidBrush(crate::control_room::rgb(theme.text_secondary));
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

/// **The selected hit's rendered text, painted behind the glyphs.** The
/// ranges come from the core's validated raw hit, mapped through this
/// run's proved source spans; the rects come from measuring the same
/// piece text the layout measured. A run with no proven span is left
/// alone rather than guessed at.
fn paint_piece_hits(
    dc: HDC,
    fonts: &PlanFonts,
    piece: &md_layout::Piece,
    runs: &[polter_chat_markdown::Run],
    hits: Option<&[std::ops::Range<usize>]>,
    base_top: i32,
    left: i32,
    theme: look::Theme,
) {
    let Some(hits) = hits.filter(|h| !h.is_empty()) else {
        return;
    };
    let Some(run) = runs.get(piece.run) else {
        return;
    };
    if run.spans.is_empty() {
        return;
    }
    let Some(shown) = run.text.get(piece.text.clone()) else {
        return;
    };
    let font = plan_font(fonts, piece.kind);
    for hit in hits {
        for range in polter_chat_markdown::display_ranges(&run.spans, hit.clone()) {
            let start = range.start.max(piece.text.start);
            let end = range.end.min(piece.text.end);
            if start >= end {
                continue;
            }
            let a = start - piece.text.start;
            let b = end - piece.text.start;
            let (Some(prefix), Some(mid)) = (shown.get(..a), shown.get(a..b)) else {
                continue;
            };
            let x = piece.rect.x + measure_in(dc, font, prefix);
            let w = measure_in(dc, font, mid).max(1);
            unsafe {
                // The same ground as the snippet's found word, so a hit
                // reads as one thing whether it is in the card or in the
                // message's own text. It carries alpha, so it is composited
                // over the row (or table cell, or code ground) beneath.
                let r = windows::Win32::Foundation::RECT {
                    left: left + x,
                    top: base_top + piece.rect.y,
                    right: left + x + w,
                    bottom: base_top + piece.rect.y + piece.rect.h.max(1),
                };
                crate::control_room::fill_rgba(dc, &r, theme.search_hit);
            }
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

/// One chip: a filled rectangle and its single line of words.
fn draw_chip(
    dc: HDC,
    text: &str,
    left: &mut i32,
    y: i32,
    height: i32,
    metrics: &Metrics,
    theme: &look::Theme,
    fill: look::Rgba,
    colour: look::Rgba,
) {
    if text.is_empty() {
        return;
    }
    let body = unsafe {
        crate::uifont::make(
            (metrics.scale * 96.0).round() as i32,
            look::font::BODY.round() as i32,
            look::font::WEIGHT_BODY.round() as i32,
            crate::uifont::ui_face(),
        )
    };
    let text_w = measure_in(dc, body, text);
    let pad = metrics.pad / 2;
    let w = (text_w + pad * 2).max(1);
    unsafe {
        let brush = CreateSolidBrush(crate::control_room::rgb(fill));
        let r = windows::Win32::Foundation::RECT {
            left: *left,
            top: y,
            right: *left + w,
            bottom: y + height,
        };
        let _ = FillRect(dc, &r, brush);
        let _ = DeleteObject(brush.into());
        let old = SelectObject(dc, body.into());
        let mut wide: Vec<u16> = text.encode_utf16().collect();
        let mut r = windows::Win32::Foundation::RECT {
            left: *left + pad,
            top: y,
            right: *left + w,
            bottom: y + height,
        };
        SetTextColor(dc, crate::control_room::rgb(colour));
        let _ = crate::gdi_text::draw_text_w(dc, &mut wide, &mut r, DrawTextFlags::single_line());
        SelectObject(dc, old);
        let _ = DeleteObject(body.into());
    }
    *left += w + pad;
}

/// One message's header line: author or the handoff tag, role, mentions,
/// channel and local time. **Every piece is optional and missing pieces
/// are absent, not empty words.**
fn draw_meta_line(
    dc: HDC,
    row: &crate::chat_feed::Row,
    left: i32,
    y: i32,
    width: i32,
    height: i32,
    metrics: &Metrics,
    theme: &look::Theme,
) {
    let message = &row.message;
    let body = unsafe {
        crate::uifont::make(
            (metrics.scale * 96.0).round() as i32,
            look::font::BODY.round() as i32,
            look::font::WEIGHT_BODY.round() as i32,
            crate::uifont::ui_face(),
        )
    };
    let mut x = left;
    unsafe {
        let saved = SaveDC(dc);
        IntersectClipRect(dc, left, y, left + width, y + height);
        if message.summary {
            draw_chip(
                dc,
                &crate::i18n::tr("Handoff summary"),
                &mut x,
                y,
                height,
                metrics,
                theme,
                theme.surface_row_selected,
                theme.text,
            );
        } else {
            let author = if message.author.is_empty() {
                message.from.as_str()
            } else {
                message.author.as_str()
            };
            let words = if message.from_self {
                format!("{} · {}", author, crate::i18n::tr("you"))
            } else {
                author.to_owned()
            };
            let _ = draw_text(dc, &words, x, y, width, theme.text);
            x += measure_in(dc, body, &words) + metrics.pad;
        }
        if let Some(role) = message.role.as_deref() {
            if !role.is_empty() {
                draw_chip(
                    dc,
                    role,
                    &mut x,
                    y,
                    height,
                    metrics,
                    theme,
                    theme.surface_row,
                    theme.text_secondary,
                );
            }
        }
        if let Some(mentions) = &message.mentions {
            for mention in mentions.iter().take(3) {
                let title = mention
                    .title
                    .as_deref()
                    .filter(|t| !t.is_empty())
                    .unwrap_or(mention.id.as_str());
                let words = format!("@{title}");
                let _ = draw_text(dc, &words, x, y, width, theme.attention_text);
                x += measure_in(dc, body, &words) + metrics.pad;
            }
        }
        draw_chip(
            dc,
            &channel_words(message.channel),
            &mut x,
            y,
            height,
            metrics,
            theme,
            theme.surface_row,
            theme.text_secondary,
        );
        if let Some(parts) = local_parts(message.at_ms) {
            let time = chat_meta::time_label(&parts);
            let tw = measure_in(dc, body, &time);
            let time_x = (left + width - tw).max(x);
            let _ = draw_text(dc, &time, time_x, y, tw.max(1), theme.text_tertiary);
        }
        let _ = RestoreDC(dc, saved);
        let _ = DeleteObject(body.into());
    }
}

/// The date divider: one line, centred between two faint rules.
fn draw_date_divider(
    dc: HDC,
    at_ms: i64,
    left: i32,
    y: i32,
    width: i32,
    height: i32,
    metrics: &Metrics,
    theme: &look::Theme,
) {
    let Some(parts) = local_parts(at_ms) else {
        return;
    };
    let word = date_words(&parts);
    let body = unsafe {
        crate::uifont::make(
            (metrics.scale * 96.0).round() as i32,
            look::font::BODY.round() as i32,
            look::font::WEIGHT_BODY.round() as i32,
            crate::uifont::ui_face(),
        )
    };
    let text_w = measure_in(dc, body, &word);
    unsafe {
        let _ = DeleteObject(body.into());
    }
    let text_x = left + (width - text_w) / 2;
    let mid = y + height / 2;
    unsafe {
        let brush = CreateSolidBrush(crate::control_room::rgb(theme.line_faint));
        for (a, b) in [
            (left, text_x - metrics.pad),
            (text_x + text_w + metrics.pad, left + width),
        ] {
            if b > a {
                let r = windows::Win32::Foundation::RECT {
                    left: a,
                    top: mid,
                    right: b,
                    bottom: mid + 1,
                };
                let _ = FillRect(dc, &r, brush);
            }
        }
        let _ = DeleteObject(brush.into());
    }
    let _ = draw_text(dc, &word, text_x, y, text_w.max(1), theme.text_tertiary);
}

/// The strip above the rows: what the older direction is doing. The bool
/// says the strip may be clicked to ask again.
fn boundary_words(feed: &Feed) -> (String, bool) {
    use chat_feed::OlderState;
    // **A context window is not the history chain**: its own two cursors
    // say whether there is more in each direction.
    if feed.context_window() {
        return if feed.aux_busy() {
            (crate::i18n::tr("Loading earlier messages…"), false)
        } else if feed.aux_error().is_some() {
            (
                crate::i18n::tr("Earlier messages could not be read. Click to retry."),
                true,
            )
        } else if feed.context_dirty(true) {
            (
                crate::i18n::tr("Some earlier records could not be read."),
                false,
            )
        } else if feed.context_can(true) {
            (crate::i18n::tr("Scroll up for earlier messages."), true)
        } else {
            (crate::i18n::tr("Beginning of the group"), false)
        };
    }
    match feed.older() {
        OlderState::Loading => (crate::i18n::tr("Loading earlier messages…"), false),
        OlderState::End => (crate::i18n::tr("Beginning of the group"), false),
        OlderState::Gap => (
            crate::i18n::tr("Some earlier records could not be read."),
            false,
        ),
        OlderState::Cancelled => (
            crate::i18n::tr("Loading earlier messages was cancelled. Click to retry."),
            true,
        ),
        OlderState::Failed(_) => (
            crate::i18n::tr("Earlier messages could not be read. Click to retry."),
            true,
        ),
        OlderState::Incomplete => (crate::i18n::tr("Scroll up for earlier messages."), true),
        OlderState::Idle => {
            if feed.tail().is_some_and(|t| t.gap) {
                (
                    crate::i18n::tr("Some earlier records could not be read."),
                    false,
                )
            } else if feed.can_load_older() {
                (crate::i18n::tr("Scroll up for earlier messages."), true)
            } else if feed.tail().is_some() {
                (crate::i18n::tr("Beginning of the group"), false)
            } else {
                (crate::i18n::tr("Loading"), false)
            }
        }
    }
}

/// The context window's lower edge: more later neighbours, if the core
/// gave a cursor for them.
fn later_words(feed: &Feed) -> Option<(String, bool)> {
    if feed.context_window() && feed.context_dirty(false) {
        Some((
            crate::i18n::tr("Some later records could not be read."),
            false,
        ))
    } else if feed.context_window() && feed.context_can(false) {
        Some((crate::i18n::tr("Scroll down for later messages."), true))
    } else {
        None
    }
}

/// The "new messages / back to latest" words, and whether there is
/// anything to return from.
fn latest_words(feed: &Feed, new_rows: bool) -> Option<String> {
    let unseen = feed.new_messages() > 0 || new_rows;
    if unseen {
        Some(crate::i18n::tr("New messages"))
    } else if feed.reading_history() || feed.can_load_older() {
        Some(crate::i18n::tr("Back to latest"))
    } else {
        None
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

/// Where the message content starts inside the window: under the fixed
/// header and the older-history strip. **One answer for paint, the row
/// hit test and the horizontal hit test**, so they cannot disagree.
fn page_content_top(
    dc: HDC,
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
    chat: &Chat,
) -> i32 {
    let left = client.left + metrics.pad;
    let (messages_right, _) = split(
        client,
        metrics,
        sidebar_of(chat.side != SidebarMode::Closed),
    );
    let width = (messages_right - left - metrics.pad).max(1);
    let top = client.top + metrics.pad;
    let meta = chat.feed.as_ref().and_then(|feed| feed.metadata());
    let geom = header_geom(dc, left, top, width, metrics, meta, chat.brief_open);
    top + geom.total + metrics.line + metrics.gap
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
    let opened = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| x.side != SidebarMode::Closed)
            })
            .unwrap_or(false)
    });
    let (messages_right, _) = split(&client, &metrics, sidebar_of(opened));
    let width = (messages_right - client.left - metrics.pad * 2).max(1);
    let font_id = plan_font_id(dpi);
    let handle_h = md_layout::handle_height(dpi as f64 / 96.0);
    let left = client.left + metrics.pad;
    let dc = unsafe { GetDC(Some(hwnd)) };
    let out = CHATS.with(|c| {
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
        let msg = message_rect(
            dc,
            &client,
            &metrics,
            feed,
            chat.side != SidebarMode::Closed,
            chat.brief_open,
        );
        let view_h = msg.height;
        for i in chat.layout.visible(chat.scroll, view_h) {
            let Some(row) = feed.rows().get(i) else {
                continue;
            };
            let Some(measured) = chat.layout.rows().get(i) else {
                continue;
            };
            let text_top = msg.top + measured.top - chat.scroll
                + measured.date_height
                + measured.author_height;
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
            let (block, horiz, on_bar) = if let Some(bar) =
                entry
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
    });
    unsafe {
        ReleaseDC(Some(hwnd), dc);
    }
    out
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
    let opened = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| x.side != SidebarMode::Closed)
            })
            .unwrap_or(false)
    });
    let (messages_right, _) = split(&client, &metrics, sidebar_of(opened));
    let width = (messages_right - client.left - metrics.pad * 2).max(1);
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
        let mut action = drop_dead_for(&chat.plans, &mut chat.hdrag, &mut chat.hfocus);
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
        let mut action = drop_dead_for(&chat.plans, &mut chat.hdrag, &mut chat.hfocus);
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

unsafe extern "system" fn search_edit_proc(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    if msg == WM_KEYDOWN {
        if wp.0 as u16 == VK_ESCAPE.0 {
            if let Ok(parent) = unsafe { GetParent(hwnd) } {
                let _ =
                    unsafe { PostMessageW(Some(parent), WM_SEARCH_CLOSE, WPARAM(0), LPARAM(0)) };
            }
            return LRESULT(0);
        }
        if wp.0 as u16 == 0x0D {
            if let Ok(parent) = unsafe { GetParent(hwnd) } {
                let _ = unsafe { PostMessageW(Some(parent), WM_SEARCH_NOW, WPARAM(0), LPARAM(0)) };
            }
            return LRESULT(0);
        }
    }
    unsafe { DefSubclassProc(hwnd, msg, wp, lp) }
}

fn search_edit_hwnd(hwnd: HWND) -> isize {
    CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| x.search_edit)
            })
            .unwrap_or(0)
    })
}

fn edit_text(edit: isize) -> String {
    if edit == 0 {
        return String::new();
    }
    let edit = HWND(edit as *mut c_void);
    let len = unsafe { GetWindowTextLengthW(edit) }.max(0) as usize;
    let mut buf = vec![0u16; len + 1];
    let n = unsafe { GetWindowTextW(edit, &mut buf) }.max(0) as usize;
    String::from_utf16_lossy(&buf[..n.min(buf.len())])
}

/// Make the real search box: a native `EDIT` in the panel's input rect.
fn ensure_search_edit(hwnd: HWND) {
    let existing = search_edit_hwnd(hwnd);
    if existing != 0 {
        // **Entering search always focuses the box**, however it was
        // entered (the toolbar's button, or the panel already being open
        // while a click moved the keyboard away).
        unsafe {
            let _ = SetFocus(Some(HWND(existing as *mut c_void)));
        }
        return;
    }
    let hinst: HINSTANCE =
        unsafe { HINSTANCE(GetWindowLongPtrW(hwnd, GWLP_HINSTANCE) as *mut c_void) };
    let made = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            0,
            0,
            1,
            1,
            Some(hwnd),
            Some(HMENU(SEARCH_EDIT_ID as usize as *mut c_void)),
            Some(hinst),
            None,
        )
    };
    let Ok(edit) = made else {
        wlogf!(hwnd, "[chat-native] the search box could not be made");
        return;
    };
    let dpi = crate::dpi_for(hwnd) as i32;
    let font = crate::uifont::make(
        dpi,
        look::font::BODY.round() as i32,
        look::font::WEIGHT_BODY.round() as i32,
        crate::uifont::ui_face(),
    );
    unsafe {
        SendMessageW(
            edit,
            WM_SETFONT,
            Some(WPARAM(font.0 as usize)),
            Some(LPARAM(1)),
        );
        let _ = SetWindowSubclass(edit, Some(search_edit_proc), 1, 0);
    }
    let query = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| x.search_query.clone())
            })
            .unwrap_or_default()
    });
    // **Terminated**: `SetWindowTextW` reads a C string, and an empty
    // query must still be one NUL rather than an empty buffer.
    let text: Vec<u16> = query.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        SetWindowTextW(edit, PCWSTR(text.as_ptr()));
        let _ = SetFocus(Some(edit));
    }
    CHATS.with(|c| {
        if let Ok(mut c) = c.try_borrow_mut() {
            if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                chat.search_edit = edit.0 as isize;
                chat.search_font = font.0 as isize;
            }
        }
    });
}

/// The panel is on another monitor or DPI now: replace the EDIT's font and
/// release the old one.
fn update_search_font(hwnd: HWND) {
    let (edit, old_font) = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| (x.search_edit, x.search_font))
            })
            .unwrap_or((0, 0))
    });
    if edit == 0 {
        return;
    }
    let dpi = crate::dpi_for(hwnd) as i32;
    let font = crate::uifont::make(
        dpi,
        look::font::BODY.round() as i32,
        look::font::WEIGHT_BODY.round() as i32,
        crate::uifont::ui_face(),
    );
    unsafe {
        SendMessageW(
            HWND(edit as *mut c_void),
            WM_SETFONT,
            Some(WPARAM(font.0 as usize)),
            Some(LPARAM(1)),
        );
        if old_font != 0 {
            let _ = DeleteObject(windows::Win32::Graphics::Gdi::HGDIOBJ(
                old_font as *mut c_void,
            ));
        }
    }
    CHATS.with(|c| {
        if let Ok(mut c) = c.try_borrow_mut() {
            if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                chat.search_font = font.0 as isize;
            }
        }
    });
}

fn destroy_search_edit(chat: &mut Chat) {
    if chat.search_edit != 0 {
        unsafe {
            let _ = DestroyWindow(HWND(chat.search_edit as *mut c_void));
        }
        chat.search_edit = 0;
    }
    if chat.search_font != 0 {
        unsafe {
            let _ = DeleteObject(windows::Win32::Graphics::Gdi::HGDIOBJ(
                chat.search_font as *mut c_void,
            ));
        }
        chat.search_font = 0;
    }
}

fn on_search_edit_changed(hwnd: HWND) {
    let edit = search_edit_hwnd(hwnd);
    if edit == 0 {
        return;
    }
    let text = edit_text(edit);
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return;
        };
        if (chat.side == SidebarMode::Search) && text != chat.search_query {
            chat.search_query = text;
            invalidate_search(chat);
            chat.search_due = Some(now_ms() + 250);
        }
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// Whether the focused window is a text field (`EDIT` or a rich edit). A
/// page-wide key handler asks this before taking a key: **the field the
/// person is typing in keeps its letters** (task 2981).
fn focus_is_text_field() -> bool {
    let focus = unsafe { GetFocus() };
    if focus.0.is_null() {
        return false;
    }
    let mut name = [0u16; 32];
    let n = unsafe { GetClassNameW(focus, &mut name) };
    if n <= 0 {
        return false;
    }
    let class = String::from_utf16_lossy(&name[..n as usize]).to_ascii_lowercase();
    class == "edit" || class.starts_with("richedit")
}

/// Escape closes the open panel. **The search panel is opened by its own
/// button, never by a shortcut**: this page's key handler used to take
/// `Ctrl+F` before anything else, and inside a text box that is how a person
/// loses the letters they are typing (task 2981; the task panel's own filter
/// box was the report). **Only this window's own keys**: the handler is on
/// this page's wndproc, so the key never reaches a tab that is not in front.
fn search_key(hwnd: HWND, vk: u16) -> bool {
    // **A key pressed while a text field has focus belongs to that field.**
    // Nothing here may swallow a character the person is typing. The test
    // is the focused window's class, not "is it the search box": the bug
    // (task 2981) was the task panel's own search box losing f/c, and any
    // EDIT this page grows later must be covered the same way.
    if focus_is_text_field() {
        return false;
    }
    if vk == VK_ESCAPE.0 {
        let open = CHATS.with(|c| {
            c.try_borrow()
                .ok()
                .and_then(|c| {
                    c.iter()
                        .find(|x| x.hwnd == hwnd.0 as isize)
                        .map(|x| x.side != SidebarMode::Closed)
                })
                .unwrap_or(false)
        });
        if open {
            let preview = CHATS.with(|c| {
                c.try_borrow()
                    .ok()
                    .and_then(|c| {
                        c.iter()
                            .find(|x| x.hwnd == hwnd.0 as isize)
                            .map(|x| x.side == SidebarMode::Preview)
                    })
                    .unwrap_or(false)
            });
            if preview {
                close_preview(hwnd);
            } else {
                close_search(hwnd);
            }
            return true;
        }
    }
    false
}

fn close_search(hwnd: HWND) {
    let owed = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return None;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return None;
        };
        chat.side = SidebarMode::Closed;
        chat.search_due = None;
        let had_focus = unsafe { GetFocus() }.0 as isize == chat.search_edit;
        destroy_search_edit(chat);
        if had_focus {
            unsafe {
                let _ = SetFocus(Some(hwnd));
            }
        }
        let cancel = chat.feed.as_mut().and_then(|f| f.cancel_search());
        if let Some(Action::Cancel { request }) = cancel {
            if chat.shown {
                chat.pending_cancel = Some(request);
            }
        }
        Some(())
    });
    let _ = owed;
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// A query edit invalidates the old answers **now**, not when the debounce
/// fires: the results and any scan behind them are for the old words. The
/// cancel goes through a cleanup slot like every other one.
fn invalidate_search(chat: &mut Chat) {
    let cancel = chat.feed.as_mut().and_then(|feed| feed.clear_search());
    if let Some(Action::Cancel { request }) = cancel {
        if chat.shown {
            chat.pending_cancel = Some(request);
        }
    }
    chat.search_selected = None;
    chat.search_selected_anchor = None;
    chat.search_missing = false;
    chat.around_seen = None;
    // A new query starts at the top of its own result list.
    chat.search_scroll = 0;
    chat.search_anchor = None;
}

/// Ask for the query once its debounce is up, or clear it when empty.
fn search_tick(hwnd: HWND, now: u64) {
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return;
        };
        if !(chat.side == SidebarMode::Search) {
            return;
        }
        let Some(due) = chat.search_due else {
            return;
        };
        if now < due {
            return;
        }
        chat.search_due = None;
        let query = chat_read::trim_query(&chat.search_query).to_owned();
        let Some(feed) = chat.feed.as_mut() else {
            return;
        };
        if query.is_empty() {
            let _ = feed.clear_search();
            return;
        }
        let same = feed.search_query() == Some(query.as_str());
        let idle = matches!(feed.search_state(), chat_feed::SearchState::Idle);
        let failed = matches!(feed.search_state(), chat_feed::SearchState::Failed(_));
        let cancelled = matches!(feed.search_state(), chat_feed::SearchState::Cancelled);
        if let Some(id) = next_request_id() {
            if same && (failed || cancelled) {
                // **Enter after a stop resumes the interrupted page**,
                // keeping the hits already shown.
                let _ = feed.retry_search(id, now);
                return;
            }
            if same && !idle {
                return;
            }
            let _ = feed.start_search(&query, id, now);
        }
    });
}

/// The hit at `index` and the row it names. **A target that is not in the
/// loaded window is said out loud**, never replaced by a look-alike.
fn locate_hit(chat: &mut Chat, index: usize) {
    let Some(hit) = chat
        .feed
        .as_ref()
        .and_then(|feed| feed.search_results().get(index).cloned())
    else {
        return;
    };
    chat.search_selected = Some(index);
    chat.search_selected_anchor = chat
        .feed
        .as_ref()
        .and_then(|feed| feed.search_results().get(index))
        .map(|hit| hit.message.anchor.clone());
    // **Absolute raw ranges, from the core's own snippet window**: the
    // search decoder proved the snippet is `message.text[snippet_start..]`
    // and that each range is char-aligned inside it. No matching is redone
    // here; this only shifts validated offsets.
    let text_hits: Vec<std::ops::Range<usize>> = hit
        .ranges
        .iter()
        .map(|r| {
            let start = hit.snippet_start as usize + r.start as usize;
            start..start + r.end.saturating_sub(r.start) as usize
        })
        .collect();
    chat.text_highlight = Some((hit.message.anchor.clone(), text_hits));
    let row_id = chat.feed.as_ref().and_then(|feed| {
        feed.rows()
            .iter()
            .find(|row| {
                row.message.anchor == hit.message.anchor
                    || row.id == hit.message.anchor
                    || hit.message.live_anchor.as_deref() == Some(row.message.anchor.as_str())
            })
            .map(|row| row.id.clone())
    });
    match row_id {
        Some(id) => {
            chat.search_missing = false;
            chat.highlight = Some((id.clone(), std::time::Instant::now()));
            chat.follow = false;
            chat.new_rows = false;
            // **A loaded target is still a navigation**: the old unloaded
            // request must not replace the window later, and the feed
            // treats what is on screen as a reading window.
            if let Some(feed) = chat.feed.as_mut() {
                feed.cancel_navigation();
                feed.enter_reading();
            }
            if let Some(y) = chat.layout.scroll_for(&id, 0) {
                chat.scroll = chat.layout.clamp(y, chat.view_h.max(1));
            }
        }
        None => {
            // **Direct around, not a walk through history pages.** The
            // target is asked for by its own anchor; the row waits until
            // the core answers with the explicit context view.
            let now = now_ms();
            let mut asked = false;
            if let Some(feed) = chat.feed.as_mut() {
                if let Some(id) = next_request_id() {
                    // The hint goes back exactly as the core gave it; a
                    // record that carried none is not guessed at.
                    asked = feed.load_around(
                        &hit.message.anchor,
                        hit.message.location.as_deref(),
                        10,
                        10,
                        id,
                        now,
                    );
                }
            }
            chat.search_missing = !asked;
            chat.around_seen = None;
        }
    }
}

/// The around page arrived: put its target in sight once, with the same
/// whole-row highlight a hit that was already loaded gets.
fn apply_around(hwnd: HWND) {
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return;
        };
        let Some(page) = chat.feed.as_ref().and_then(|feed| feed.around()) else {
            return;
        };
        let Some(target) = page.messages.get(page.target_index) else {
            return;
        };
        if chat.around_seen.as_deref() == Some(target.anchor.as_str()) {
            return;
        }
        chat.around_seen = Some(target.anchor.clone());
        let row_id = chat.feed.as_ref().and_then(|feed| {
            feed.rows()
                .iter()
                .find(|row| {
                    row.message.anchor == target.anchor
                        || target.live_anchor.as_deref() == Some(row.message.anchor.as_str())
                })
                .map(|row| row.id.clone())
        });
        if let Some(id) = row_id {
            chat.search_missing = false;
            chat.highlight = Some((id.clone(), std::time::Instant::now()));
            chat.follow = false;
            chat.new_rows = false;
            if let Some(y) = chat.layout.scroll_for(&id, 0) {
                chat.scroll = chat.layout.clamp(y, chat.view_h.max(1));
            }
        } else {
            chat.search_missing = true;
        }
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// A click inside the right-hand panel. **The panel takes every click in
/// its own rectangle**, so the conversation under it never moves.
fn search_click(hwnd: HWND, x: i32, y: i32) -> bool {
    let open = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| x.side == SidebarMode::Search)
            })
            .unwrap_or(false)
    });
    if !open {
        return false;
    }
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let (_, side_w) = split(&client, &metrics, Sidebar::Search);
    let side_left = panel_left(&client, side_w);
    if side_w <= 0 || x < side_left {
        return false;
    }
    let g = side_geom(&client, &metrics, side_left, side_w);
    let inside = |r: (i32, i32, i32, i32)| x >= r.0 && x < r.0 + r.2 && y >= r.1 && y < r.1 + r.3;
    if inside(g.close) {
        close_search(hwnd);
        return true;
    }
    if inside(g.input) {
        return true;
    }
    if y >= g.results_top && y < g.results_top + metrics.line {
        let released = CHATS.with(|c| {
            c.try_borrow()
                .ok()
                .and_then(|c| {
                    c.iter()
                        .find(|x| x.hwnd == hwnd.0 as isize)
                        .and_then(|x| x.feed.as_ref().map(|f| f.search_released()))
                })
                .unwrap_or(false)
        });
        if released {
            CHATS.with(|c| {
                let Ok(mut c) = c.try_borrow_mut() else {
                    return;
                };
                let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
                    return;
                };
                let Some(feed) = chat.feed.as_mut() else {
                    return;
                };
                let Some(query) = feed.search_query().map(str::to_owned) else {
                    return;
                };
                if let Some(id) = next_request_id() {
                    let _ = feed.start_search(&query, id, now_ms());
                }
                chat.search_scroll = 0;
                chat.search_anchor = None;
            });
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            return true;
        }
    }
    let list_top = g.results_top + metrics.line + metrics.gap;
    let footer_h = {
        let busy = CHATS.with(|c| {
            c.try_borrow()
                .ok()
                .and_then(|c| {
                    c.iter()
                        .find(|x| x.hwnd == hwnd.0 as isize)
                        .and_then(|x| x.feed.as_ref().and_then(|f| search_footer(f)))
                })
                .is_some()
        });
        if busy {
            metrics.line + metrics.gap
        } else {
            0
        }
    };
    let footer_y = g.results_bottom - footer_h;
    if footer_h > 0 && y >= footer_y && y < g.results_bottom {
        let now = now_ms();
        CHATS.with(|c| {
            let Ok(mut c) = c.try_borrow_mut() else {
                return;
            };
            let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
                return;
            };
            let Some(feed) = chat.feed.as_mut() else {
                return;
            };
            if feed.aux_busy() {
                return;
            }
            let Some(id) = next_request_id() else {
                return;
            };
            if feed.search_can_more() || feed.search_full() {
                // Keep the top card's identity while the window moves.
                let card_h = search_card_height(&metrics).max(1) as usize;
                let first = (chat.search_scroll.max(0) as usize) / card_h;
                chat.search_anchor = feed
                    .search_results()
                    .get(first)
                    .map(|hit| hit.message.anchor.clone());
                let mut done = feed.search_load_older(id, now);
                if !done {
                    if let Some(id) = next_request_id() {
                        done = feed.search_more(id, now);
                    }
                }
                let _ = done;
            } else if feed.retry_search(id, now) {
                // Retry continues the interrupted page, keeping results.
            }
        });
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
        return true;
    }
    if y >= list_top {
        let mut clicked = None;
        CHATS.with(|c| {
            let Ok(mut c) = c.try_borrow_mut() else {
                return;
            };
            let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
                return;
            };
            if !(chat.side == SidebarMode::Search) {
                return;
            }
            let card_h = search_card_height(&metrics).max(1);
            let index = ((y - list_top + chat.search_scroll).max(0) / card_h) as usize;
            let count = chat
                .feed
                .as_ref()
                .map_or(0, |feed| feed.search_results().len());
            if index < count {
                locate_hit(chat, index);
                clicked = Some(());
            }
        });
        if clicked.is_some() {
            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
        }
        return true;
    }
    true
}

/// The one rectangle the rows live in: message pane (side slot taken out),
/// below the fixed header and top strip, above the bottom strip. **Every
/// measurement, paint, hit test and scroll uses this.**
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct MessageRect {
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    /// The top strip's own top (the header ends there).
    strip_top: i32,
}

fn message_rect(
    dc: HDC,
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
    feed: &Feed,
    open: bool,
    brief_open: bool,
) -> MessageRect {
    let left = client.left + metrics.pad;
    let (messages_right, _) = split(client, metrics, sidebar_of(open));
    let width = (messages_right - left - metrics.pad).max(1);
    let top = client.top + metrics.pad;
    let header = header_geom(dc, left, top, width, metrics, feed.metadata(), brief_open);
    let strip_top = top + header.total;
    let strip_h = metrics.line + metrics.gap;
    let later_h = if later_words(feed).is_some() {
        metrics.line + metrics.gap
    } else {
        0
    };
    MessageRect {
        left,
        top: strip_top + strip_h,
        width,
        height: (client.bottom - (strip_top + strip_h) - later_h - metrics.pad).max(metrics.line),
        strip_top,
    }
}

/// The Markdown link under the pointer, with the message identity and its
/// `location` hint. **Only a run the parser marked as a link**; a path-like
/// string that was not a link is not an entry.
fn message_link_at(
    hwnd: HWND,
    dc: HDC,
    x: i32,
    y: i32,
    client: &windows::Win32::Foundation::RECT,
    metrics: &Metrics,
) -> Option<(String, Option<String>, String)> {
    let dpi = crate::dpi_for(hwnd) as i32;
    let font_id = plan_font_id(dpi);
    CHATS.with(|c| {
        let c = c.try_borrow().ok()?;
        let chat = c.iter().find(|x| x.hwnd == hwnd.0 as isize)?;
        if !chat.shown {
            return None;
        }
        let feed = chat.feed.as_ref()?;
        let msg = message_rect(
            dc,
            client,
            metrics,
            feed,
            chat.side != SidebarMode::Closed,
            chat.brief_open,
        );
        let left = msg.left;
        let width = msg.width;
        let view_h = msg.height;
        let group = chat.group.clone();
        let generation = feed.generation();
        // **One line, when the click found nothing and the reason is not
        // "there is no link here"**: a row under the pointer with no plan
        // is a host state, not a person's mistake, and on a live machine
        // the log is the only witness (task 2983).
        let mut miss_why: Option<String> = None;
        for i in chat.layout.visible(chat.scroll, view_h) {
            let Some(row) = feed.rows().get(i) else {
                continue;
            };
            // **Whether a link resolves is the core's answer, not this
            // row's `location`.** `location` is the core's opaque log
            // position hint, not a cwd: live messages carry `null` and the
            // core still resolves them (task 2978 M3). The host offers the
            // entry and, when the core cannot find the file, says so in the
            // panel.
            let Some(measured) = chat.layout.rows().get(i) else {
                continue;
            };
            let row_top = msg.top + measured.top - chat.scroll;
            let text_top = row_top + measured.date_height + measured.author_height;
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
                // The click is in this row's own rectangle and the row has
                // no usable plan: say whether there is no plan at all or
                // one whose key differs, and which key -- the next run then
                // names the cause instead of repeating the symptom.
                if y >= row_top && y < row_top + measured.height {
                    let held = chat.plans.iter().find(|p| p.row_id == row.id);
                    miss_why = Some(match held {
                        Some(p) => format!(
                            "row {:?} v{}: held plan differs (plan: gen {}, width {}, dpi {}, font {}, v{}; asked: gen {}, width {}, dpi {}, font {}, v{})",
                            row.id,
                            row.message.content_version,
                            p.generation,
                            p.width,
                            p.dpi,
                            p.font,
                            p.version,
                            generation,
                            width,
                            dpi,
                            font_id,
                            row.message.content_version
                        ),
                        None => format!(
                            "row {:?} v{}: no plan for it at all (gen {}, width {}, dpi {}, font {}, {} plans held)",
                            row.id,
                            row.message.content_version,
                            generation,
                            width,
                            dpi,
                            font_id,
                            chat.plans.len()
                        ),
                    });
                }
                continue;
            };
            if plan_y >= entry.plan.height {
                continue;
            }
            let hit = entry
                .plan
                .hit_scrolled(x - left, plan_y, |b| entry.hoffset(b));
            let link = match hit {
                Some(md_layout::Hit::Block(block)) => {
                    let Some(plan_block) = entry.plan.blocks.get(block) else {
                        continue;
                    };
                    // **The plan's own document**, not a second lookup in
                    // the parse cache: the plan was built from this `Arc`,
                    // so the runs and the rectangles are the same parse by
                    // construction (a cache miss must not kill a link).
                    let doc = &entry.doc;
                    let runs: &[polter_chat_markdown::Run] = match doc.blocks.get(block) {
                        Some(polter_chat_markdown::Block::Paragraph(runs))
                        | Some(polter_chat_markdown::Block::Heading { runs, .. })
                        | Some(polter_chat_markdown::Block::Quote { runs, .. }) => runs.as_slice(),
                        Some(polter_chat_markdown::Block::ListItem(item)) => item.runs.as_slice(),
                        _ => continue,
                    };
                    let off = entry.hoffset(block);
                    // **Pieces are laid out in the block's own space**: a
                    // paragraph's first line starts at y 0, not at the
                    // block's plan offset. `hit_scrolled` found the block
                    // in plan coordinates; the piece test needs the same
                    // point in the block's coordinates.
                    let piece_y = plan_y.saturating_sub(plan_block.rect.y);
                    let mut found = None;
                    for line in &plan_block.lines {
                        for piece in &line.pieces {
                            if !piece.rect.contains(x - left + off, piece_y) {
                                continue;
                            }
                            let Some(run) = runs.get(piece.run) else {
                                continue;
                            };
                            if let Some(link) = &run.style.link_raw {
                                found = Some(link.to_string());
                            }
                        }
                    }
                    // The click is on the line that carries a link but on
                    // none of its pieces: the one shape a plan lookup
                    // cannot explain, and the one worth a line.
                    if found.is_none() && runs.iter().any(|r| r.style.link_raw.is_some()) {
                        if let Some(line) = plan_block
                            .lines
                            .iter()
                            .find(|l| piece_y >= l.rect.y && piece_y < l.rect.y + l.rect.h)
                        {
                            miss_why = Some(format!(
                                "block {} has a link run but no piece contains x {} (block y {}, piece_y {}, line {:?})",
                                block,
                                x - left + off,
                                plan_block.rect.y,
                                piece_y,
                                line.rect
                            ));
                        }
                    }
                    found
                }
                Some(md_layout::Hit::Cell {
                    table,
                    head,
                    row: cell_row,
                    column,
                }) => {
                    let Some(table_plan) = entry.plan.tables.get(table) else {
                        continue;
                    };
                    let doc = &entry.doc;
                    let Some(polter_chat_markdown::Block::Table(src)) =
                        doc.blocks.get(table_plan.block)
                    else {
                        continue;
                    };
                    let (cell, runs) = if head {
                        (
                            table_plan.header.get(column),
                            src.header.get(column).map(|r| r.as_slice()),
                        )
                    } else {
                        (
                            table_plan.rows.get(cell_row).and_then(|r| r.get(column)),
                            src.rows
                                .get(cell_row)
                                .and_then(|r| r.get(column))
                                .map(|r| r.as_slice()),
                        )
                    };
                    let (Some(cell), Some(runs)) = (cell, runs) else {
                        continue;
                    };
                    // The table cells are laid out at their own offsets;
                    // use the same scrolled x as the content.
                    let off = entry.hoffset(table_plan.block);
                    let mut found = None;
                    for line in &cell.lines {
                        for piece in &line.pieces {
                            if !piece.rect.contains(x - left + off, plan_y) {
                                continue;
                            }
                            let Some(run) = runs.get(piece.run) else {
                                continue;
                            };
                            if let Some(link) = &run.style.link_raw {
                                found = Some(link.to_string());
                            }
                        }
                    }
                    found
                }
                _ => continue,
            };
            if let Some(link) = link {
                return Some((
                    row.message.anchor.clone(),
                    row.message.location.clone(),
                    link,
                ));
            }
        }
        if let Some(why) = miss_why {
            plogf!(
                "[chat-native] link click at ({}, {}) found nothing: {}",
                x,
                y,
                why
            );
        }
        None
    })
}

/// The sentence a failed reference job shows. §6 names the two cases where
/// the core cannot tell which file was meant -- a relative path with no
/// recorded source, and more than one root that fits -- and both are said
/// plainly instead of being folded into the general refusal. **The host does
/// not decide this itself**: the core's own code is the only input.
fn reference_error(code: Option<&str>) -> String {
    match code {
        // The core's only "cannot tell which file" code; `AmbiguousSource`
        // is in the contract but the core never emits it (review 2978), so
        // it is not mapped to a sentence that could never appear.
        Some("SourceUnavailable") => {
            crate::i18n::tr("The location of this file cannot be determined.")
        }
        _ => crate::i18n::tr("This file cannot be previewed."),
    }
}

/// The sentence a refused `file_open` shows. **Never the core's code or its
/// English**: the panel speaks the person's language, and a bare `access` is
/// not a sentence (task 2978). The core's refusal is
/// `{"refused":"access","reason":…,"why":…}` (`files/Tickets.zig`); the
/// `why` string is deliberately not displayed.
fn reference_refusal(refused: &str, reason: &str) -> String {
    match (refused, reason) {
        ("access", "outside") => {
            crate::i18n::tr("The file is not in the group's working directory, or it is gone.")
        }
        ("access", "unreadable") => crate::i18n::tr("This file cannot be read."),
        ("access", "not_a_file") => crate::i18n::tr("That link is not a file."),
        ("no_workdir", _) => {
            crate::i18n::tr("This group has no working directory to find the file in.")
        }
        ("HostRefused", _) => crate::i18n::tr("Polter could not prepare the preview."),
        _ => crate::i18n::tr("This file cannot be previewed."),
    }
}

/// Whether a link is a web address rather than a file reference. **http and
/// https only**, ASCII case ignored; everything else is the core's to answer
/// as a file reference or to refuse (task 2978).
fn is_external_link(reference: &str) -> bool {
    let value = reference.trim_start();
    // Long enough for either scheme; a short string is taken whole, and a
    // cut in the middle of a character falls back to the whole string too.
    let head = value.get(..8).unwrap_or(value);
    let head = head.to_ascii_lowercase();
    head.starts_with("http://") || head.starts_with("https://")
}

/// Start a preview from a clicked link. The panel switches to preview; the
/// search (query and hits) is kept for the way back.
fn start_preview(chat: &mut Chat, anchor: String, location: Option<String>, reference: String) {
    // The other half of the link-hit witness: a click that did find a link
    // says so, with the reference it sent the core.
    plogf!(
        "[chat-native] link: preview {:?} for anchor {:?} (location {:?})",
        reference,
        anchor,
        location
    );
    // **The old body goes at once**, so a slow or failed new source never
    // leaves A under B's title.
    let slot = preview_page::SlotKey::chat(&chat.group, HWND(chat.hwnd as *mut c_void));
    preview_page::hide(&slot);
    let now = now_ms();
    let mut asked = false;
    if let Some(feed) = chat.feed.as_mut() {
        if let Some(id) = next_request_id() {
            asked = feed.load_reference(&anchor, location.as_deref(), &reference, id, now);
        }
        chat.preview_back_search = feed.search_query().is_some();
    }
    destroy_search_edit(chat);
    chat.side = SidebarMode::Preview;
    chat.preview_token = None;
    chat.preview_plugin = None;
    chat.preview_loading = asked;
    chat.preview_error = if asked {
        None
    } else {
        Some(crate::i18n::tr("This file cannot be previewed."))
    };
    chat.preview_label = Some(reference.clone());
    chat.preview_pending = Some(PreviewPending {
        anchor,
        location,
        reference,
    });
}

/// Consume the reference answer once: mount its ticket in the slot, or say
/// why it cannot be shown. Never reads a path here.
fn apply_reference(hwnd: HWND) {
    let plan = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return None;
        };
        let chat = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize)?;
        if !(chat.side == SidebarMode::Preview) {
            return None;
        }
        let pending = chat.preview_pending.clone()?;
        let page = chat.feed.as_mut()?.take_reference()?;
        // The source may have been promoted from its live alias to its
        // persisted anchor; both name the same row.
        let same_row = page.source_anchor == pending.anchor
            || page.source_live_anchor.as_deref() == Some(pending.anchor.as_str())
            || chat.feed.as_ref().is_some_and(|feed| {
                feed.rows().iter().any(|row| {
                    (row.message.anchor == pending.anchor
                        || row.id == pending.anchor
                        || row.message.live_anchor.as_deref() == Some(pending.anchor.as_str()))
                        && (row.message.anchor == page.source_anchor
                            || row.message.live_anchor.as_deref()
                                == Some(page.source_anchor.as_str()))
                })
            });
        if !same_row || page.original_reference != pending.reference {
            if let Some(token) = chat_read::ticket_of(&page) {
                preview_page::close_unowned(&token);
            }
            chat.preview_loading = false;
            return None;
        }
        // **The same ticket-shape rule everywhere**: a decoded page is not
        // a licence to adopt any string out of `file_open`.
        let token = chat_read::ticket_of(&page);
        let plugin = page.file_open.get("plugin");
        if token.is_none() {
            let refused = page
                .file_open
                .get("refused")
                .and_then(|w| w.as_str())
                .unwrap_or("");
            let reason = page
                .file_open
                .get("reason")
                .and_then(|w| w.as_str())
                .unwrap_or("");
            chat.preview_error = Some(reference_refusal(refused, reason));
            chat.preview_loading = false;
            return None;
        }
        let Some(plugin) = plugin.filter(|p| !p.is_null()) else {
            chat.preview_error = Some(crate::i18n::tr("No plugin can show this file."));
            chat.preview_loading = false;
            if let Some(token) = token.as_deref() {
                preview_page::close_unowned(token);
            }
            return None;
        };
        let status = plugin.get("status").and_then(|s| s.as_str());
        let render = plugin.get("render").and_then(|r| r.as_str());
        if status != Some("matched") {
            let why = match status {
                Some("disabled") => crate::i18n::tr("The plugin for this file is switched off."),
                Some("unsupported") => crate::i18n::tr("No plugin claims this kind of file."),
                _ => crate::i18n::tr("No plugin can show this file."),
            };
            chat.preview_error = Some(why);
            chat.preview_loading = false;
            if let Some(token) = token.as_deref() {
                preview_page::close_unowned(token);
            }
            return None;
        }
        if !matches!(render, Some("browser") | Some("page")) {
            chat.preview_error = Some(crate::i18n::tr("No plugin can show this file."));
            chat.preview_loading = false;
            if let Some(token) = token.as_deref() {
                preview_page::close_unowned(token);
            }
            return None;
        }
        let token = token?;
        let mut client = windows::Win32::Foundation::RECT::default();
        let _ = unsafe { GetClientRect(hwnd, &mut client) };
        let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
        let (_, side_w) = split(&client, &metrics, sidebar_of(true));
        let side_left = panel_left(&client, side_w);
        let (_, _, body) = preview_parts(&client, &metrics, side_left, side_w);
        Some((
            preview_page::SlotKey::chat(&chat.group, hwnd),
            windows::Win32::Foundation::RECT {
                left: body.0,
                top: body.1,
                right: body.0 + body.2,
                bottom: body.1 + body.3,
            },
            token,
            (*plugin).clone(),
            page.source_anchor.clone(),
            page.source_location.clone(),
        ))
    });
    if let Some((slot, rect, token, plugin, source_anchor, source_location)) = plan {
        match preview_page::show(slot, rect, &token, Some(&plugin)) {
            Ok(()) => {
                // **Only an adopted ticket becomes the slot's current
                // source.** A refused one is never kept for a later show.
                CHATS.with(|c| {
                    if let Ok(mut c) = c.try_borrow_mut() {
                        if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                            chat.preview_token = Some(token.clone());
                            chat.preview_plugin = Some(plugin.clone());
                            chat.preview_loading = false;
                            chat.preview_error = None;
                            chat.preview_rect = Some((
                                rect.left,
                                rect.top,
                                rect.right - rect.left,
                                rect.bottom - rect.top,
                            ));
                            // **Save what the core resolved, not the hint
                            // that asked for it**: a live row may now be its
                            // persisted anchor with a location. A later
                            // reopen (evicted slot, hidden page, another core
                            // session) must ask with this pair; the raw
                            // reference stays the same.
                            if let Some(pending) = chat.preview_pending.as_mut() {
                                pending.anchor = source_anchor;
                                pending.location = source_location;
                            }
                        }
                    }
                });
            }
            Err(preview_page::ShowError::Budget) => {
                // The ticket was not adopted; it is still ours to close.
                preview_page::close_unowned(&token);
                CHATS.with(|c| {
                    if let Ok(mut c) = c.try_borrow_mut() {
                        if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                            chat.preview_error =
                                Some(crate::i18n::tr("No room for another preview."));
                            chat.preview_token = None;
                            chat.preview_plugin = None;
                            chat.preview_rect = None;
                            chat.preview_loading = false;
                        }
                    }
                });
            }
            Err(preview_page::ShowError::Unsupported) => {
                preview_page::close_unowned(&token);
                CHATS.with(|c| {
                    if let Ok(mut c) = c.try_borrow_mut() {
                        if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                            chat.preview_error =
                                Some(crate::i18n::tr("No plugin can show this file."));
                            chat.preview_token = None;
                            chat.preview_plugin = None;
                            chat.preview_rect = None;
                            chat.preview_loading = false;
                        }
                    }
                });
            }
            Err(preview_page::ShowError::AlreadyOwned) => {
                // The token belongs to another slot; closing it here would
                // break that visible page.
                CHATS.with(|c| {
                    if let Ok(mut c) = c.try_borrow_mut() {
                        if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                            chat.preview_error =
                                Some(crate::i18n::tr("That preview is open in another slot."));
                            chat.preview_token = None;
                            chat.preview_plugin = None;
                            chat.preview_rect = None;
                            chat.preview_loading = false;
                        }
                    }
                });
            }
        }
    }
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// Close any ticket a refused reference answer carried.
fn drain_orphan_reference(hwnd: HWND) {
    let mut tokens = Vec::new();
    CHATS.with(|c| {
        if let Ok(mut c) = c.try_borrow_mut() {
            if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                if let Some(feed) = chat.feed.as_mut() {
                    tokens.extend(feed.take_orphan_references());
                }
            }
        }
    });
    for token in tokens {
        preview_page::close_unowned(&token);
    }
}

/// Drop a reference answer nobody is waiting for, and project a failed
/// reference job into this panel.
fn discard_unwanted_reference(hwnd: HWND) {
    let (open, ticket) = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return (false, None);
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return (false, None);
        };
        let open = chat.side == SidebarMode::Preview;
        let mut ticket = None;
        if let Some(feed) = chat.feed.as_mut() {
            if open && chat.preview_loading && chat.preview_pending.is_some() {
                if let Some(code) = feed.aux_error().map(str::to_owned) {
                    // The core's own word for why the reference failed.
                    plogf!("[chat-native] link: reference failed, core said {:?}", code);
                    chat.preview_loading = false;
                    chat.preview_pending = None;
                    chat.preview_error = Some(reference_error(Some(&code)));
                }
            }
            if !open {
                if let Some(page) = feed.take_reference() {
                    ticket = chat_read::ticket_of(&page);
                }
            }
        }
        (open, ticket)
    });
    let _ = open;
    if let Some(ticket) = ticket {
        preview_page::close_unowned(&ticket);
    }
}

/// Ask again for the source the panel still names. **The pending source is
/// what the core confirmed** on the last successful adopt (canonical anchor
/// and location), so this never walks back to a stale hint or re-adopts a
/// dead ticket. Returns whether a request was actually started.
fn reopen_preview(chat: &mut Chat, now: u64) -> bool {
    let Some(pending) = chat.preview_pending.clone() else {
        return false;
    };
    let Some(feed) = chat.feed.as_mut() else {
        return false;
    };
    let Some(id) = next_request_id() else {
        return false;
    };
    let asked = feed.load_reference(
        &pending.anchor,
        pending.location.as_deref(),
        &pending.reference,
        id,
        now,
    );
    if asked {
        chat.preview_loading = true;
    }
    asked
}

/// Put the current preview back on screen after a resize, a re-show, or a
/// return from search. Same token reuses the slot; a changed rect is
/// applied without recreating the page.
fn sync_preview(hwnd: HWND) {
    let plan = CHATS.with(
        |c| -> Option<(
            preview_page::SlotKey,
            windows::Win32::Foundation::RECT,
            String,
            serde_json::Value,
        )> {
            let Ok(mut c) = c.try_borrow_mut() else {
                return None;
            };
            let chat = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize)?;
            if !chat.shown || !(chat.side == SidebarMode::Preview) {
                return None;
            }
            if chat.preview_loading && chat.preview_token.is_none() {
                // **A cancel took the answer away**: the page was hidden,
                // its feed stopped, and the no-longer-wanted ticket was
                // handed back. While the question is still out, wait; when
                // nothing is in flight, ask again from the confirmed source.
                let waiting = chat
                    .feed
                    .as_ref()
                    .is_some_and(|feed| feed.aux_busy() || feed.reference().is_some());
                if waiting {
                    return None;
                }
                chat.preview_loading = false;
                if !reopen_preview(chat, now_ms()) {
                    chat.preview_error =
                        Some(crate::i18n::tr("This file cannot be previewed."));
                    return None;
                }
            }
            if chat.preview_loading {
                return None;
            }
            let token = chat.preview_token.clone()?;
            let plugin = chat.preview_plugin.clone()?;
            let slot = preview_page::SlotKey::chat(&chat.group, hwnd);
            match preview_page::showing(&slot) {
                Some(shown) if shown == token => {}
                Some(_) => {
                    chat.preview_token = None;
                    chat.preview_plugin = None;
                    chat.preview_rect = None;
                    chat.preview_error =
                        Some(crate::i18n::tr("That preview is open in another slot."));
                    return None;
                }
                None => {
                    // **A slot that no longer owns this ticket has already
                    // closed it** (LRU evict or close). Ask for a fresh
                    // reference from the same pending source; never re-adopt
                    // a dead ticket.
                    chat.preview_token = None;
                    chat.preview_plugin = None;
                    chat.preview_rect = None;
                    chat.preview_error = None;
                    if !reopen_preview(chat, now_ms()) {
                        chat.preview_error =
                            Some(crate::i18n::tr("This file cannot be previewed."));
                    }
                    return None;
                }
            }
            let mut client = windows::Win32::Foundation::RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut client) };
            let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
            let (_, side_w) = split(&client, &metrics, sidebar_of(true));
            let side_left = panel_left(&client, side_w);
            let (_, _, body) = preview_parts(&client, &metrics, side_left, side_w);
            let rect = (body.0, body.1, body.2, body.3);
            let slot = preview_page::SlotKey::chat(&chat.group, hwnd);
            match preview_page::state(&slot) {
                Some(settings_shell_page_state::Failed(_))
                | Some(settings_shell_page_state::LoaderMissing)
                | Some(settings_shell_page_state::RuntimeMissing) => return None,
                _ => {}
            }
            chat.preview_rect = Some(rect);
            Some((
                slot,
                windows::Win32::Foundation::RECT {
                    left: body.0,
                    top: body.1,
                    right: body.0 + body.2,
                    bottom: body.1 + body.3,
                },
                token,
                plugin,
            ))
        },
    );
    let Some((slot, rect, token, plugin)) = plan else {
        return;
    };
    if let Err(why) = preview_page::show(slot, rect, &token, Some(&plugin)) {
        CHATS.with(|c| {
            if let Ok(mut c) = c.try_borrow_mut() {
                if let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) {
                    chat.preview_error = Some(match why {
                        preview_page::ShowError::Budget => {
                            crate::i18n::tr("No room for another preview.")
                        }
                        preview_page::ShowError::AlreadyOwned => {
                            crate::i18n::tr("That preview is open in another slot.")
                        }
                        preview_page::ShowError::Unsupported => {
                            crate::i18n::tr("No plugin can show this file.")
                        }
                    });
                }
            }
        });
    }
}
/// Leave preview for good: the slot and its ticket are closed.
fn close_preview(hwnd: HWND) {
    let (slot, back, ticket) = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return (None, false, None);
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return (None, false, None);
        };
        let back = chat.preview_back_search;
        chat.side = if back {
            SidebarMode::Search
        } else {
            SidebarMode::Closed
        };
        chat.preview_token = None;
        chat.preview_plugin = None;
        chat.preview_pending = None;
        chat.preview_error = None;
        chat.preview_loading = false;
        chat.preview_rect = None;
        let mut ticket = None;
        if let Some(feed) = chat.feed.as_mut() {
            feed.cancel_navigation();
            if let Some(page) = feed.take_reference() {
                ticket = chat_read::ticket_of(&page);
            }
        }
        (
            Some(preview_page::SlotKey::chat(&chat.group, hwnd)),
            back,
            ticket,
        )
    });
    if let Some(slot) = slot {
        preview_page::close(&slot);
    }
    if let Some(ticket) = ticket {
        preview_page::close_unowned(&ticket);
    }
    if back {
        ensure_search_edit(hwnd);
    }
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}
/// Switch from preview back to the search that opened it, **hiding** this
/// slot (its ticket stays).
fn preview_to_search(hwnd: HWND) {
    let (slot, ticket) = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return (None, None);
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return (None, None);
        };
        chat.preview_loading = false;
        chat.preview_rect = None;
        chat.side = SidebarMode::Search;
        let mut ticket = None;
        if let Some(feed) = chat.feed.as_mut() {
            feed.cancel_navigation();
            if let Some(page) = feed.take_reference() {
                ticket = chat_read::ticket_of(&page);
            }
        }
        (Some(preview_page::SlotKey::chat(&chat.group, hwnd)), ticket)
    });
    if let Some(slot) = slot {
        preview_page::hide(&slot);
    }
    if let Some(ticket) = ticket {
        preview_page::close_unowned(&ticket);
    }
    ensure_search_edit(hwnd);
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// Clicks in the preview panel's chrome. The page body itself is a child
/// window and receives its own clicks.
fn preview_click(hwnd: HWND, x: i32, y: i32) -> bool {
    let open = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| (x.side == SidebarMode::Preview))
            })
            .unwrap_or(false)
    });
    if !open {
        return false;
    }
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let (_, side_w) = split(&client, &metrics, Sidebar::Search);
    let side_left = panel_left(&client, side_w);
    if x < side_left {
        return false;
    }
    let (header, close, body) = preview_parts(&client, &metrics, side_left, side_w);
    let inside = |r: (i32, i32, i32, i32)| x >= r.0 && x < r.0 + r.2 && y >= r.1 && y < r.1 + r.3;
    if inside(close) {
        close_preview(hwnd);
        return true;
    }
    let back = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| x.preview_back_search)
            })
            .unwrap_or(false)
    });
    if back {
        let back_rect = (header.0, header.1, metrics.line * 5, header.3);
        if inside(back_rect) {
            preview_to_search(hwnd);
            return true;
        }
    }
    let _ = body;
    true
}

/// A click on the page's own furniture -- the header, its member popover,
/// the older-history strip, the "back to latest" pill. **Consumed before
/// the row hit test**, so a chip never becomes a table drag.
fn chat_click(hwnd: HWND, x: i32, y: i32) -> bool {
    if search_click(hwnd, x, y) {
        return true;
    }
    if preview_click(hwnd, x, y) {
        return true;
    }
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let left = client.left + metrics.pad;
    let opened = CHATS.with(|c| {
        c.try_borrow()
            .ok()
            .and_then(|c| {
                c.iter()
                    .find(|x| x.hwnd == hwnd.0 as isize)
                    .map(|x| x.side != SidebarMode::Closed)
            })
            .unwrap_or(false)
    });
    let (messages_right, _) = split(&client, &metrics, sidebar_of(opened));
    let width = (messages_right - left - metrics.pad).max(1);
    let top = client.top + metrics.pad;
    let dc = unsafe { GetDC(Some(hwnd)) };
    if dc.0.is_null() {
        return false;
    }
    let link = message_link_at(hwnd, dc, x, y, &client, &metrics);

    enum Hit {
        No,
        Yes { repaint: bool },
    }
    let hit = CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return Hit::No;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return Hit::No;
        };
        if !chat.shown {
            return Hit::No;
        }
        let meta = chat.feed.as_ref().and_then(|f| f.metadata()).cloned();
        let header = header_geom(
            dc,
            left,
            top,
            width,
            &metrics,
            meta.as_ref(),
            chat.brief_open,
        );
        let msg_top = top + header.total;

        // An open popover takes the click first: outside closes it.
        if chat.members_open {
            if let Some(m) = &meta {
                let (mx, my, mw, mh) =
                    members_rect(left, width, msg_top, &metrics, m.members.len());
                if x >= mx && x < mx + mw && y >= my && y < my + mh {
                    return Hit::Yes { repaint: false };
                }
            }
            chat.members_open = false;
            return Hit::Yes { repaint: true };
        }
        let inside =
            |r: (i32, i32, i32, i32)| x >= r.0 && x < r.0 + r.2 && y >= r.1 && y < r.1 + r.3;
        if inside(header.search) {
            // One slot: entering search leaves preview (its controller is
            // hidden, its ticket kept).
            if (chat.side == SidebarMode::Preview) {
                let slot = preview_page::SlotKey::chat(&chat.group, hwnd);
                preview_page::hide(&slot);
            }
            chat.preview_loading = false;
            chat.side = SidebarMode::Search;
            chat.search_due = Some(now_ms());
            return Hit::Yes { repaint: true };
        }
        if inside(header.member) {
            chat.members_open = true;
            return Hit::Yes { repaint: true };
        }
        if (header.overflow || chat.brief_open) && inside(header.toggle) {
            chat.brief_open = !chat.brief_open;
            return Hit::Yes { repaint: true };
        }
        if let Some((anchor, location, reference)) = link.clone() {
            // **A web address is not a file**: hand it to the shell and keep
            // the panel as it was. The reference job would only refuse it
            // (task 2978).
            if is_external_link(&reference) {
                plogf!(
                    "[chat-native] link: external {:?} handed to the system browser",
                    reference
                );
                let _ = crate::links::on_open_url(
                    None,
                    crate::ffi::OPEN_URL_KIND_TEXT,
                    Some(reference),
                );
                return Hit::Yes { repaint: false };
            }
            start_preview(chat, anchor, location, reference);
            return Hit::Yes { repaint: true };
        }
        // The older-history strip, always the first line of the message
        // pane; clicking it retries or asks for the next older page.
        if y >= msg_top && y < msg_top + metrics.line + metrics.gap {
            let now = now_ms();
            if let Some(feed) = chat.feed.as_mut() {
                if feed.context_window() && feed.context_can(true) {
                    if let Some(id) = next_request_id() {
                        let _ = feed.load_context(true, id, now);
                    }
                } else if feed.can_load_older() {
                    if let Some(id) = next_request_id() {
                        let _ = feed.load_older(id, now);
                    }
                }
            }
            return Hit::Yes { repaint: true };
        }
        // The context window's lower edge.
        let has_later = chat
            .feed
            .as_ref()
            .is_some_and(|feed| later_words(feed).is_some());
        if has_later {
            let later_h = metrics.line + metrics.gap;
            let y0 = client.bottom - metrics.pad - later_h;
            if y >= y0 && y < y0 + later_h {
                let now = now_ms();
                if let Some(feed) = chat.feed.as_mut() {
                    if let Some(id) = next_request_id() {
                        let _ = feed.load_context(false, id, now);
                    }
                }
                return Hit::Yes { repaint: true };
            }
        }
        // The "new messages / back to latest" pill.
        let Some(feed) = chat.feed.as_ref() else {
            return Hit::Yes { repaint: false };
        };
        if let Some(word) = latest_words(feed, chat.new_rows) {
            let body = unsafe {
                crate::uifont::make(
                    (metrics.scale * 96.0).round() as i32,
                    look::font::BODY.round() as i32,
                    look::font::WEIGHT_BODY.round() as i32,
                    crate::uifont::ui_face(),
                )
            };
            let tw = measure_in(dc, body, &word);
            let h = metrics.line + metrics.gap;
            let w = tw + metrics.pad * 2;
            let x0 = left + width - w;
            let y0 = client.bottom - metrics.pad - h;
            unsafe {
                let _ = DeleteObject(body.into());
            }
            if x >= x0 && x < x0 + w && y >= y0 && y < y0 + h {
                if let Some(feed) = chat.feed.as_mut() {
                    feed.return_to_latest(now_ms());
                }
                chat.follow = true;
                chat.new_rows = false;
                chat.around_seen = None;
                chat.scroll = chat.layout.clamp(i32::MAX, chat.view_h.max(1));
                return Hit::Yes { repaint: true };
            }
        }
        Hit::No
    });
    unsafe {
        ReleaseDC(Some(hwnd), dc);
    }
    match hit {
        Hit::No => false,
        Hit::Yes { repaint } => {
            let open = CHATS.with(|c| {
                c.try_borrow()
                    .ok()
                    .and_then(|c| {
                        c.iter()
                            .find(|x| x.hwnd == hwnd.0 as isize)
                            .map(|x| x.side != SidebarMode::Closed)
                    })
                    .unwrap_or(false)
            });
            if open {
                ensure_search_edit(hwnd);
            }
            if repaint {
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            }
            true
        }
    }
}

/// Keep a following view on the bottom; a view reading history never
/// follows, and says so through the pill.
fn sync_follow(hwnd: HWND) {
    let mut invalidate = false;
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return;
        };
        if !chat.shown {
            return;
        }
        let Some(feed) = chat.feed.as_ref() else {
            return;
        };
        let len = feed.rows().len();
        if len != chat.rows_seen {
            if chat.follow {
                chat.scroll = chat.layout.clamp(i32::MAX, chat.view_h.max(1));
                chat.new_rows = false;
            } else {
                chat.new_rows = true;
            }
            chat.rows_seen = len;
            invalidate = true;
        }
        if chat
            .highlight
            .as_ref()
            .is_some_and(|(_, at)| at.elapsed() >= std::time::Duration::from_millis(2500))
        {
            chat.highlight = None;
            chat.text_highlight = None;
            invalidate = true;
        }
    });
    if invalidate {
        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
    }
}

/// Wheel and keys move the view; both are bounded by the content, and both
/// keep the row at the top (by id and offset) as the anchor.
fn search_scroll_by(hwnd: HWND, by: i32) {
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == hwnd.0 as isize) else {
            return;
        };
        let count = chat
            .feed
            .as_ref()
            .map_or(0, |feed| feed.search_results().len());
        let footer = chat
            .feed
            .as_ref()
            .is_some_and(|feed| search_footer(feed).is_some());
        // **The same rectangle paint scrolls in**: the side's list starts
        // under the header and ends above the footer.
        let (_, side_w) = split(&client, &metrics, Sidebar::Search);
        let side_left = panel_left(&client, side_w);
        let g = side_geom(&client, &metrics, side_left, side_w);
        let list_top = g.results_top + metrics.line + metrics.gap;
        let footer_h = if footer {
            metrics.line + metrics.gap
        } else {
            0
        };
        let cards_bottom = g.results_bottom - footer_h;
        let list_h = (cards_bottom - list_top).max(1);
        let max = (count as i32 * search_card_height(&metrics) - list_h).max(0);
        let _ = side_w;
        chat.search_scroll = (chat.search_scroll + by).clamp(0, max);
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

fn scroll_by(hwnd: HWND, by: i32) {
    let key = hwnd.0 as isize;
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return;
        };
        let view_h = chat.view_h.max(1);
        chat.scroll = chat.layout.clamp(chat.scroll - by, view_h);
        let max = chat.layout.clamp(i32::MAX, view_h);
        chat.follow = chat.scroll >= max;
        if chat.follow {
            chat.new_rows = false;
        }
        // **Leaving the bottom is a reading state, and coming back is a
        // return to the latest** -- not just a paint flag. A context
        // window uses its own directions and never becomes "latest".
        if let Some(feed) = chat.feed.as_mut() {
            if chat.follow {
                if !feed.context_window() && feed.reading_history() {
                    feed.return_to_latest(now_ms());
                }
            } else if !feed.context_window() {
                feed.enter_reading();
            }
        }
        // **Scrolling at an edge asks for the next page**: the context
        // window uses its own two directions; the history chain its token.
        let now = now_ms();
        if by > 0 && chat.scroll == 0 {
            if let Some(feed) = chat.feed.as_mut() {
                if let Some(id) = next_request_id() {
                    if feed.context_window() {
                        let _ = feed.load_context(true, id, now);
                    } else if feed.can_load_older() {
                        let _ = feed.load_older(id, now);
                    }
                }
            }
        } else if by < 0 && chat.scroll >= max {
            if let Some(feed) = chat.feed.as_mut() {
                if feed.context_window() {
                    if let Some(id) = next_request_id() {
                        let _ = feed.load_context(false, id, now);
                    }
                }
            }
        }
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

fn scroll_to(hwnd: HWND, at: i32) {
    let key = hwnd.0 as isize;
    CHATS.with(|c| {
        let Ok(mut c) = c.try_borrow_mut() else {
            return;
        };
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            return;
        };
        let view_h = chat.view_h.max(1);
        chat.scroll = chat.layout.clamp(at, view_h);
        let max = chat.layout.clamp(i32::MAX, view_h);
        chat.follow = chat.scroll >= max;
        if chat.follow {
            chat.new_rows = false;
        }
        if let Some(feed) = chat.feed.as_mut() {
            if chat.follow {
                if !feed.context_window() && feed.reading_history() {
                    feed.return_to_latest(now_ms());
                }
            } else if !feed.context_window() {
                feed.enter_reading();
            }
        }
    });
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

/// The message whose row is at `y` pixels from the top of the page.
fn row_at(hwnd: HWND, y: i32) -> Option<String> {
    let key = hwnd.0 as isize;
    let mut client = windows::Win32::Foundation::RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
    let dc = unsafe { GetDC(Some(hwnd)) };
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
        let content_top = page_content_top(dc, &client, &metrics, chat);
        let page_y = y - content_top + chat.scroll;
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
    unsafe {
        ReleaseDC(Some(hwnd), dc);
    }
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
        // **The plan is measured for the same rectangle paint draws and
        // the hit test uses**: the message pane, below the fixed header
        // and between the two boundary strips, with the side panel's
        // width already taken out.
        let msg = message_rect(
            dc,
            &client,
            &metrics,
            feed,
            chat.side != SidebarMode::Closed,
            chat.brief_open,
        );
        let width = msg.width;
        let view_h = msg.height;
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
        let mut prev_day: Option<i64> = None;
        let identities: Vec<RowIdentity<'_>> = feed
            .rows()
            .iter()
            .map(|r| {
                let day = local_parts(r.message.at_ms).map(|p| chat_meta::day_key(&p));
                let date = day
                    .map(|d| chat_meta::starts_day(prev_day, d))
                    .unwrap_or(false);
                if let Some(d) = day {
                    prev_day = Some(d);
                }
                RowIdentity {
                    id: r.id.as_str(),
                    version: r.message.content_version,
                    date,
                }
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
                            (
                                chat_rows::Source::Markdown,
                                author_height,
                                plan.height.max(1),
                            )
                        }
                        None => {
                            let (author_height, text_height) =
                                measure_raw(dc, author, &row.message.text, width, dpi);
                            (chat_rows::Source::Raw, author_height, text_height)
                        }
                    };
                    decisions.push(chat_rows::Decision::Replace(chat_rows::PublishedHeight {
                        id: candidate.id.as_str(),
                        version: candidate.version,
                        source,
                        identity: &candidate.identity,
                        author_height,
                        text_height,
                    }));
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
        let view_h = chat.view_h.max(1);
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
    // A close that found the ticket ledger borrowed gets its retry here.
    crate::preview_page::flush_deferred();

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
    // A following view stays on the bottom; a reading view keeps its place.
    sync_follow(hwnd);
    search_tick(hwnd, now);
    apply_around(hwnd);
    apply_reference(hwnd);
    drain_orphan_reference(hwnd);
    discard_unwanted_reference(hwnd);
    sync_preview(hwnd);
    sync_search_anchor(hwnd);

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
        let nav = feed.nav_epoch();
        Some((action, group, generation, nav))
    });
    let Some((action, group, generation, nav)) = ready else {
        return;
    };
    let (kind, request) = match action {
        Action::Begin { request } => (Kind::Begin, request),
        Action::Live { request } => (Kind::Live, request),
        Action::Poll { request } => (Kind::Poll, request),
        Action::Metadata { request } => (Kind::Metadata, request),
        Action::SearchBegin { request } => (Kind::SearchBegin, request),
        Action::SearchPoll { request } => (Kind::SearchPoll, request),
        Action::AuxBegin { request } => (Kind::AuxBegin, request),
        Action::AuxPoll { request } => (Kind::AuxPoll, request),
        Action::Cancel { request } => {
            // A cleanup cancel is fire and forget; there is no reply to
            // apply and nothing to retry.
            let _ = send_request(&request);
            return;
        }
    };

    let request_id = if matches!(kind, Kind::Begin | Kind::AuxBegin | Kind::SearchBegin) {
        request_id_of(&request)
    } else {
        None
    };
    let job_id = if matches!(kind, Kind::Poll | Kind::AuxPoll | Kind::SearchPoll) {
        request_param(&request, "job_id")
    } else {
        None
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
    // **A window that is gone has no tick**: the ticket a late reference
    // answer minted is closed here, through the owner-checked ledger.
    let mut late_ticket: Option<String> = None;
    CHATS.with(|c| {
        let mut c = c.borrow_mut();
        let Some(chat) = c.iter_mut().find(|x| x.hwnd == key) else {
            late = late_begin_cancel(kind, &group, &transport);
            late_ticket = late_reference_ticket(kind, &transport);
            return;
        };
        let Some(feed) = chat.feed.as_mut() else {
            late = late_begin_cancel(kind, &group, &transport);
            late_ticket = late_reference_ticket(kind, &transport);
            return;
        };
        let envelope = Envelope {
            kind,
            generation,
            group,
            request_id: request_id.clone(),
            job_id: job_id.clone(),
            nav,
        };
        let owed = match kind {
            Kind::Begin => feed.accept_begin(&envelope, transport, now),
            Kind::Live => feed.accept_live(&envelope, transport, now),
            Kind::Poll => feed.accept_poll(&envelope, transport, now),
            Kind::Metadata => feed.accept_metadata(&envelope, transport, now),
            Kind::SearchBegin => feed.accept_search_begin(&envelope, transport, now),
            Kind::SearchPoll => feed.accept_search_poll(&envelope, transport, now),
            Kind::AuxBegin => feed.accept_aux_begin(&envelope, transport, now),
            Kind::AuxPoll => feed.accept_aux_poll(&envelope, transport, now),
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
    if let Some(token) = late_ticket {
        preview_page::close_unowned(&token);
    }
    // **A hidden page has no next tick.** `accept_*` may have parked a
    // ticket in this very dispatch (the `!active` guard after `place`
    // stopped the feed); drain it now, while the borrow is released.
    drain_orphan_reference(hwnd);
    sync_follow(hwnd);
}

/// The request id the host itself put in a begin, so a reply can be held
/// to the begin that is still current. **Only the feed's own encoded
/// request**; nothing here builds or checks a token.
fn request_id_of(request: &str) -> Option<String> {
    request_param(request, "request_id")
}

fn request_param(request: &str, key: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(request).ok()?;
    value["params"][key].as_str().map(str::to_owned)
}

/// The ticket a late reference poll minted for a window (or a feed) that is
/// no longer there to consume it. **Both poll doors carry one**: an AuxPoll
/// is where a reference normally answers, and a Poll that answers with a
/// reference page is a wrong-mode answer the same cleanup owns. A page the
/// strict decoder refuses is still read conservatively for a
/// ticket-shaped token (`chat_read::reference_ticket`). The close goes
/// through `close_unowned`, which refuses a token a visible slot owns.
fn late_reference_ticket(kind: Kind, transport: &Result<Transport, TransportError>) -> Option<String> {
    if !matches!(kind, Kind::AuxPoll | Kind::Poll) {
        return None;
    }
    let Ok(Transport::Body(text)) = transport else {
        return None;
    };
    match chat_read::decode_poll(text) {
        Ok(chat_read::PollOutcome::ReadyReference(page)) => chat_read::ticket_of(&page),
        _ => chat_read::reference_ticket(text),
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
    let Ok(Transport::Body(text)) = transport else {
        return None;
    };
    // **The kind says which door answered**, so the cancel is the same
    // door's: a search job is never closed with the history cancel.
    match kind {
        Kind::Begin => match chat_read::decode_begin(text) {
            Ok(chat_read::BeginOutcome::Started(page)) if page.group == expected_group => {
                chat_read::Request::Cancel {
                    job_id: page.job_id,
                }
                .encode()
                .ok()
            }
            _ => None,
        },
        Kind::AuxBegin => match chat_read::decode_aux_begin(text) {
            Ok(chat_read::AuxBeginOutcome::Started(start)) if start.group == expected_group => {
                chat_read::Request::Cancel {
                    job_id: start.job_id,
                }
                .encode()
                .ok()
            }
            _ => None,
        },
        Kind::SearchBegin => match chat_read::decode_search_begin(text) {
            Ok(chat_read::SearchBeginOutcome::Started(start)) if start.group == expected_group => {
                chat_read::Request::SearchCancel {
                    job_id: start.job_id,
                }
                .encode()
                .ok()
            }
            _ => None,
        },
        _ => None,
    }
}

/// The frame's DPI changed: the native window has no surface to resize, and
/// the rows' own layout takes the scale with the next placement.
pub fn rescale(hwnd: HWND, _scale: f64) {
    update_search_font(hwnd);
    wlogf!(
        hwnd,
        "[chat-native] dpi change: the rows take it at their next placement"
    );
}
