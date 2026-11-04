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
    BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, InvalidateRect, SelectObject,
    SetBkMode, SetTextColor, DT_CALCRECT, DT_LEFT, DT_NOPREFIX, DT_SINGLELINE, DT_WORDBREAK, HDC,
    PAINTSTRUCT, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetFocus, SetFocus, VK_END, VK_HOME, VK_NEXT, VK_PRIOR,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_control_room::look;
use polter_split_tree::Rect as TreeRect;

use crate::chat_feed::{self, Action, Envelope, Feed, Kind};
use crate::chat_read::{self, Transport, TransportError};
use crate::ffi::Surface;
use crate::{plogf, wlogf};
use polter_control_room::chat_rows::{
    self, FontKey, MeasureError, Measured, Metrics, RowInput, Sight,
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
}

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
            // Three lines a notch, as the control room's list scrolls.
            scroll_by(hwnd, (delta / 120) * line * 3);
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let mut client = windows::Win32::Foundation::RECT::default();
            let _ = unsafe { GetClientRect(hwnd, &mut client) };
            let metrics = Metrics::for_dpi(crate::dpi_for(hwnd) as i32);
            let page = (client.bottom - client.top - metrics.pad * 2).max(metrics.line);
            match wp.0 as u16 {
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
    })
}

/// Put one away: its window destroyed, and nothing else in the process
/// touched.
fn close(mut chat: Chat, why: &str) {
    let hwnd = HWND(chat.hwnd as *mut c_void);
    // **A window that goes takes its reading with it**: the feed is
    // stopped before the window dies, and a known job is cancelled.
    let mut cancels: Vec<String> = Vec::new();
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
            feed,
            layout,
            scroll,
            ..
        } = chat;
        let Some(feed) = feed.as_ref() else {
            return;
        };

        let left = client.left + metrics.pad;
        let width = (client.right - client.left - metrics.pad * 2).max(1);
        let view_h = (client.bottom - client.top - metrics.pad * 2).max(1);

        // The rows as the layout wants them: the feed's own stable id and
        // content version, and the words as written.
        let inputs: Vec<RowInput<'_>> = feed
            .rows()
            .iter()
            .map(|row| {
                let author = if row.message.author.is_empty() {
                    row.message.from.as_str()
                } else {
                    row.message.author.as_str()
                };
                RowInput {
                    id: row.id.as_str(),
                    version: row.message.content_version,
                    author,
                    text: row.message.text.as_str(),
                }
            })
            .collect();

        // **An update keeps the reader where they were**: the row at the
        // top and its pixel offset are remembered before the body changes
        // and looked up again after, by id -- never by index.
        // The `PCWSTR` must outlive the slice borrowed from it: bind the
        // handle first (E0716 when the temporary was borrowed directly).
        let face_holder = crate::uifont::ui_face();
        let force = unsafe { face_holder.as_wide() };
        let key = FontKey {
            dpi: dpi as i32,
            // **The size the font was actually made at**, including the
            // system menu floor `uifont::make` applies.
            size_px: polter_settings_shell::text_px(
                look::font::BODY.round() as i32,
                dpi as i32,
                crate::uifont::menu_px(dpi as i32),
            ),
            weight: look::font::WEIGHT_BODY.round() as i32,
            face: String::from_utf16_lossy(force),
        };
        let anchor = layout.anchor(*scroll).map(|(id, off)| (id.to_owned(), off));
        let changed = layout.update_measured(&inputs, width, &metrics, &key, &mut |row, w| {
            measure_row(dc, row.author, row.text, w)
        });
        if changed {
            if let Some((id, off)) = anchor {
                if let Some(at) = layout.scroll_for(&id, off) {
                    *scroll = at;
                }
            }
        }
        *scroll = layout.clamp(*scroll, view_h);

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
                    draw_block(dc, &row.message.text, left, text_top, width, text_bottom);
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
