//! The tab strip: what it looks like, and what a mouse does to it.
//!
//! This replaces the 43 lines of `FillRect` that stood in for a strip while
//! the port was proving it could draw a terminal at all. The brief is "close
//! to the macOS level of finish", which here means: a tab can be dragged to
//! reorder, closed from its own button, renamed in place, and none of it
//! flickers.
//!
//! **Three rules this file keeps, each of which is a bug it is avoiding:**
//!
//!  1. **No second list of tabs.** Everything drawn comes from a snapshot
//!     taken from the model in that same paint (`tabs::strip_snapshot`). A
//!     cached `Vec<TabLabel>` is how "the order is right but the contents are
//!     wrong" gets written, and this is the file most likely to write it.
//!  2. **Identity, never index.** Every mouse interaction resolves to a
//!     `TabId` immediately. A drag spans dozens of frames and any of them can
//!     reorder; an index stops naming the same tab the moment one moves.
//!  3. **Draw into a memory DC.** A drag repaints on every mouse move, and
//!     painting straight into the window DC flickers -- which is exactly the
//!     kind of thing "finish" means.

use std::cell::RefCell;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetActiveWindow, ReleaseCapture, SetCapture, SetFocus, TrackMouseEvent, TME_LEAVE,
    TRACKMOUSEEVENT, VK_ESCAPE, VK_RETURN,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::logf;
use crate::tabs::{self, TabId};

/// Height of the strip in unscaled pixels.
pub const STRIP_H: i32 = 30;

/// Widest a tab gets when there is room, and the narrowest it is squeezed to
/// before the overflow policy has to do something else.
const TAB_MAX_W: i32 = 220;
const TAB_MIN_W: i32 = 60;
/// How far the pointer travels before a press becomes a drag rather than a
/// click. Without it, a click with a shaky hand reorders tabs.
const DRAG_SLOP: i32 = 4;

pub fn strip_h(scale: f64) -> i32 {
    ((STRIP_H as f64) * scale).round() as i32
}

/// One tab's geometry: the whole tab, and its close button.
pub struct Slot {
    pub id: TabId,
    pub rect: RECT,
    pub close: RECT,
}

/// Room the overflow button takes when there is one.
const OVERFLOW_W: i32 = 22;

/// How the tabs are sized, and whether the strip overflows.
///
/// **This function is the overflow policy** (decided: compress, then scroll,
/// with a `»` menu for the rest). Tabs shrink evenly down to `TAB_MIN_W`;
/// past that the strip scrolls and the button appears. Everything below
/// consumes rectangles and does not know how they were chosen, so a different
/// policy is a change here and nowhere else.
///
/// Returns `(tab width, overflowing)`.
pub fn layout(strip_w: i32, scale: f64, n: usize) -> (i32, bool) {
    let min_w = (TAB_MIN_W as f64 * scale) as i32;
    let max_w = (TAB_MAX_W as f64 * scale) as i32;
    if n == 0 {
        return (min_w, false);
    }
    let n = n as i32;
    // Does it fit at the narrowest we are willing to draw?
    if n * min_w > strip_w {
        return (min_w, true);
    }
    ((strip_w / n).clamp(min_w, max_w), false)
}

/// The whole strip's content width, and how far it can be scrolled.
fn extent(strip_w: i32, tw: i32, n: usize, overflowing: bool) -> (i32, i32) {
    let content = tw * n as i32;
    let visible = if overflowing {
        strip_w - (OVERFLOW_W as f64 * tabs::scale_of()) as i32
    } else {
        strip_w
    };
    (content, (content - visible).max(0))
}

/// The `»` button's rectangle, when the strip overflows.
fn overflow_rect(strip_w: i32, scale: f64, sh: i32) -> RECT {
    let w = (OVERFLOW_W as f64 * scale) as i32;
    RECT { left: strip_w - w, top: 0, right: strip_w, bottom: sh }
}

/// Is this point one of the strip's own controls?
///
/// Asked by `WM_NCHITTEST`: a point on a tab has to answer `HTCLIENT` so the
/// strip's mouse handling runs, and everything else in the strip answers
/// `HTCAPTION` so the window can be dragged by it. Getting it backwards makes
/// tabs look broken rather than making the window look wrong.
pub fn is_interactive(frame: HWND, x: i32, y: i32) -> bool {
    let (slots, overflow) = slots(frame);
    hit(&slots, overflow, x, y) != Hit::None
}

/// The tabs' geometry, and the overflow button's if there is one.
///
/// The scroll offset is clamped here rather than where it is changed: the
/// number of tabs can change without the pointer touching anything, and a
/// stale offset would leave the strip scrolled past its own end.
fn slots(frame: HWND) -> (Vec<Slot>, Option<RECT>) {
    let (tabs_now, _) = tabs::strip_snapshot();
    let scale = tabs::scale_of();
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return (Vec::new(), None);
        }
    }
    let sh = strip_h(scale);
    // The caption buttons live at the right end of the strip now that the
    // strip *is* the caption. Their width comes out of the space the tabs
    // get; **this is the only thing about the shell the strip knows.** The
    // drag-position arithmetic below is untouched by it.
    let strip_w = (rc.right - rc.left - crate::shell::reserved_right()).max(1);
    let n = tabs_now.len();
    let (tw, overflowing) = layout(strip_w, scale, n);
    let (_, max_scroll) = extent(strip_w, tw, n, overflowing);

    let scroll = with_ui(|u| {
        u.scroll = u.scroll.clamp(0, max_scroll);
        u.scroll
    });

    let close_side = (14.0 * scale) as i32;
    let slots = tabs_now
        .into_iter()
        .enumerate()
        .map(|(i, (id, _))| {
            let x = i as i32 * tw - scroll;
            let rect = RECT { left: x, top: 0, right: x + tw - 1, bottom: sh };
            // The close button only earns its space once the tab is wide
            // enough that it does not swallow the label.
            let close = if tw > close_side * 4 {
                RECT {
                    left: rect.right - close_side - (6.0 * scale) as i32,
                    top: (sh - close_side) / 2,
                    right: rect.right - (6.0 * scale) as i32,
                    bottom: (sh + close_side) / 2,
                }
            } else {
                RECT::default()
            };
            Slot { id, rect, close }
        })
        .collect();
    (
        slots,
        overflowing.then(|| overflow_rect(strip_w, scale, sh)),
    )
}

fn contains(r: &RECT, x: i32, y: i32) -> bool {
    x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

/// What is under the pointer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Hit {
    None,
    Tab(TabId),
    Close(TabId),
    Overflow,
}

fn hit(slots: &[Slot], overflow: Option<RECT>, x: i32, y: i32) -> Hit {
    // The button sits on top of whatever the strip scrolled under it.
    if let Some(r) = overflow {
        if contains(&r, x, y) {
            return Hit::Overflow;
        }
    }
    for s in slots.iter() {
        if contains(&s.close, x, y) {
            return Hit::Close(s.id);
        }
        if contains(&s.rect, x, y) {
            return Hit::Tab(s.id);
        }
    }
    Hit::None
}

// ------------------------------------------------------------------ state

/// The pointer's business with the strip. **Never holds an index**: the tab
/// being dragged is named, because the list reorders underneath the drag.
enum Drag {
    Idle,
    /// A button is down on a tab but the pointer has not moved far enough for
    /// this to be a drag rather than a click.
    Pressed { id: TabId, x: i32 },
    /// The pointer's position is not kept here: it arrives with every
    /// `WM_MOUSEMOVE`, and a stored copy could only ever be staler.
    Dragging { id: TabId },
}

struct Interaction {
    drag: Drag,
    hover: Hit,
    /// How far the strip is scrolled, in pixels. Only ever non-zero while
    /// the tabs do not fit.
    scroll: i32,
    /// The in-place rename editor, when one is open, and what it is renaming.
    editing: Option<(isize, TabId)>,
}

thread_local! {
    /// **Not a mutex, and that is the point.**
    ///
    /// Everything that touches this arrives in a window procedure, and window
    /// procedures for these windows run on one thread. A second `Mutex`
    /// alongside `tabs::STATE` bought nothing and cost two things: it created
    /// a lock-ordering question between two locks that no code documented an
    /// order for, and, being a blocking lock, re-entering it would have hung
    /// the thread **in silence** -- the failure mode this file is supposed to
    /// be helping to avoid.
    ///
    /// A `RefCell` on the owning thread cannot be entered twice without
    /// saying so: it panics, with a stack, at the line that did it.
    static UI: RefCell<Interaction> = RefCell::new(Interaction {
        drag: Drag::Idle,
        hover: Hit::None,
        scroll: 0,
        editing: None,
    });
}

/// Do something with the interaction state.
///
/// Kept as a closure rather than handing out a borrow: a returned borrow can
/// be held across a Win32 call by accident, and that is precisely the shape
/// that has cost this port two days.
fn with_ui<R>(f: impl FnOnce(&mut Interaction) -> R) -> R {
    UI.with(|c| f(&mut c.borrow_mut()))
}

fn repaint(frame: HWND) {
    unsafe {
        let _ = InvalidateRect(Some(frame), None, false);
    }
}

// ------------------------------------------------------------------- mouse

pub fn on_button_down(frame: HWND, x: i32, y: i32) {
    let (slots, overflow) = slots(frame);
    match hit(&slots, overflow, x, y) {
        Hit::Overflow => {
            show_overflow_menu(frame, overflow.unwrap_or_default());
            return;
        }
        Hit::Close(id) => {
            // Act on release, the way every other close button does: pressing
            // and sliding off has to be a way out.
            with_ui(|u| u.drag = Drag::Pressed { id, x });
        }
        Hit::Tab(id) => {
            logf!("[strip] click -> activate {:?}", id);
            tabs::activate_tab(frame, id);
            with_ui(|u| u.drag = Drag::Pressed { id, x });
            unsafe {
                SetCapture(frame);
            }
        }
        Hit::None => {}
    }
    repaint(frame);
}

pub fn on_mouse_move(frame: HWND, x: i32, y: i32) {
    let (slots, overflow) = slots(frame);

    // Ask to be told when the pointer leaves, so hover can be cleared. Without
    // this the last hovered tab stays lit after the pointer is gone.
    let mut tme = TRACKMOUSEEVENT {
        cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
        dwFlags: TME_LEAVE,
        hwndTrack: frame,
        dwHoverTime: 0,
    };
    unsafe {
        let _ = TrackMouseEvent(&mut tme);
    }

    let h = hit(&slots, overflow, x, y);
    let (started, dragging_id) = with_ui(|u| {
        if u.hover != h {
            u.hover = h;
        }
        match u.drag {
            Drag::Pressed { id, x: x0 } if (x - x0).abs() >= DRAG_SLOP => {
                u.drag = Drag::Dragging { id };
                (true, Some(id))
            }
            Drag::Dragging { id } => (false, Some(id)),
            _ => (false, None),
        }
    });
    if started {
        log_state(frame, &format!("drag start {:?}", dragging_id));
    }

    if let Some(id) = dragging_id {
        // Where the pointer is now, in tab positions. Resolved against the
        // *current* order every time, so a reorder mid-drag stays consistent.
        // Positions are measured in the strip's own coordinates, so the
        // scroll offset has to come back out of the pointer position -- a
        // dragged tab in a scrolled strip otherwise lands one screenful off.
        let tw = slots.first().map(|s| s.rect.right - s.rect.left + 1).unwrap_or(1);
        let scroll = with_ui(|u| u.scroll);
        let want = ((x + scroll) / tw.max(1)).clamp(0, slots.len().saturating_sub(1) as i32) as usize;
        let at = slots.iter().position(|s| s.id == id);
        if at != Some(want) {
            tabs::move_tab_to(frame, id, want);
        }
    }
    repaint(frame);
}

/// Wheel over the strip scrolls it, when there is anything to scroll.
pub fn on_wheel(frame: HWND, delta: i16) {
    // One notch moves about a tab and a half: enough to feel responsive,
    // little enough to stop where you meant to.
    let step = (TAB_MIN_W as f64 * tabs::scale_of() * 1.5) as i32;
    let by = -(delta as i32) / 120 * step;
    if by == 0 {
        return;
    }
    with_ui(|u| u.scroll += by);
    logf!("[strip] wheel {} -> scroll {}", by, with_ui(|u| u.scroll));
    // The clamp lives in `slots`, which is about to run: it is the only place
    // that knows the current content width.
    repaint(frame);
}

/// The `»` menu: every tab, by name, in order.
///
/// A real popup menu rather than a drawn list. **Keyboard navigation, the
/// input method, and high-contrast themes come with it** -- all things a
/// hand-drawn list would have to reimplement, and, being on nobody's
/// acceptance list, would not.
fn show_overflow_menu(frame: HWND, button: RECT) {
    let (tabs_now, active) = tabs::strip_snapshot();
    if tabs_now.is_empty() {
        return;
    }

    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        for (i, (_, title)) in tabs_now.iter().enumerate() {
            let label = format!("{}: {}", i + 1, title);
            let mut wide: Vec<u16> = label.encode_utf16().collect();
            wide.push(0);
            let flags = if i == active {
                MF_STRING | MF_CHECKED
            } else {
                MF_STRING
            };
            let _ = AppendMenuW(menu, flags, i + 1, PCWSTR(wide.as_ptr()));
        }
        let mut pt = POINT { x: button.left, y: button.bottom };
        let _ = ClientToScreen(frame, &mut pt);
        // TPM_RETURNCMD hands the choice back here instead of posting
        // WM_COMMAND, which keeps the whole interaction in one function.
        // Note this runs a nested message loop: `app_tick` pauses while the
        // menu is open, the same as during a window move.
        let cmd = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN,
            pt.x,
            pt.y,
            None,
            frame,
            None,
        );
        let _ = DestroyMenu(menu);
        cmd.0
    };

    if chosen <= 0 {
        return;
    }
    let Some((id, _)) = tabs_now.get((chosen - 1) as usize) else {
        return;
    };
    tabs::activate_tab(frame, *id);
    scroll_into_view(frame, *id);
    repaint(frame);
}

/// Put a tab on screen after it was chosen from the menu -- otherwise
/// activating a tab that is scrolled out of sight looks like nothing happened.
fn scroll_into_view(frame: HWND, id: TabId) {
    let (slots, overflow) = slots(frame);
    if overflow.is_none() {
        return;
    }
    let Some(slot) = slots.iter().find(|s| s.id == id) else {
        return;
    };
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return;
        }
    }
    let right_edge = rc.right - (OVERFLOW_W as f64 * tabs::scale_of()) as i32;
    with_ui(|u| {
        if slot.rect.left < 0 {
            u.scroll += slot.rect.left;
        } else if slot.rect.right > right_edge {
            u.scroll += slot.rect.right - right_edge;
        }
    });
}

pub fn on_mouse_leave(frame: HWND) {
    with_ui(|u| u.hover = Hit::None);
    repaint(frame);
}

pub fn on_button_up(frame: HWND, x: i32, y: i32) {
    let (slots, overflow) = slots(frame);
    let was = with_ui(|u| std::mem::replace(&mut u.drag, Drag::Idle));
    unsafe {
        let _ = ReleaseCapture();
    }
    if matches!(was, Drag::Dragging { .. }) {
        log_state(frame, "drag end");
    }
    if let Drag::Pressed { id, .. } = was {
        // A press that never became a drag: if it started and ended on the
        // same close button, that is a click on it.
        if hit(&slots, overflow, x, y) == Hit::Close(id) {
            logf!("[strip] close {:?}", id);
            tabs::close_tab(frame, id);
            return;
        }
    }
    repaint(frame);
}

pub fn on_double_click(frame: HWND, x: i32, y: i32) {
    let (slots, overflow) = slots(frame);
    if let Hit::Tab(id) = hit(&slots, overflow, x, y) {
        if let Some(slot) = slots.iter().find(|s| s.id == id) {
            begin_rename(frame, id, slot.rect);
        }
    }
}

// ------------------------------------------------------------------ rename

/// The rename editor is a real `EDIT` control.
///
/// **Deliberately native.** A hand-rolled text field would need its own
/// caret, selection, clipboard and -- the expensive one -- its own IME
/// handling, and Chinese input into a tab name is not an edge case for this
/// fork. The cost is the TSF handover below.
fn begin_rename(frame: HWND, id: TabId, rect: RECT) {
    end_rename(frame, false);

    let (tabs_now, _) = tabs::strip_snapshot();
    let title = tabs_now
        .iter()
        .find(|(t, _)| *t == id)
        .map(|(_, s)| s.clone())
        .unwrap_or_default();
    let mut wide: Vec<u16> = title.encode_utf16().collect();
    wide.push(0);

    let edit = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            PCWSTR(wide.as_ptr()),
            WS_CHILD | WS_VISIBLE | WS_BORDER | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            rect.left + 2,
            rect.top + 2,
            (rect.right - rect.left - 4).max(20),
            (rect.bottom - rect.top - 4).max(16),
            Some(frame),
            None,
            None,
            None,
        )
    };
    let Ok(edit) = edit else {
        logf!("[strip] rename: CreateWindowExW(EDIT) failed");
        return;
    };

    unsafe {
        // Subclass it, so Enter commits and Escape cancels. An EDIT swallows
        // both by default and tells nobody.
        let prev = SetWindowLongPtrW(edit, GWLP_WNDPROC, edit_proc as *const () as isize);
        SetWindowLongPtrW(edit, GWLP_USERDATA, prev);
        // EM_SETSEL: select everything, so typing replaces the old name.
        // Spelled numerically because the constant lives behind a Controls
        // feature this crate does not otherwise need.
        const EM_SETSEL: u32 = 0x00B1;
        SendMessageW(edit, EM_SETSEL, Some(WPARAM(0)), Some(LPARAM(-1)));
        let _ = SetFocus(Some(edit));
    }

    // Hand the input method over. The terminal's document must stop being the
    // focused one or the IME keeps composing into the surface behind the box.
    crate::ime_focus(false);

    with_ui(|u| u.editing = Some((edit.0 as isize, id)));
    logf!("[strip] rename {:?} started", id);
}

/// Close the editor, keeping what was typed if `commit`.
pub fn end_rename(frame: HWND, commit: bool) {
    let Some((hwnd, id)) = with_ui(|u| u.editing.take()) else {
        return;
    };
    let edit = HWND(hwnd as *mut std::ffi::c_void);

    if commit {
        let mut buf = [0u16; 256];
        let n = unsafe { GetWindowTextW(edit, &mut buf) };
        if n > 0 {
            let title = String::from_utf16_lossy(&buf[..n as usize]);
            tabs::rename_tab(frame, id, title.clone());
            logf!("[strip] rename {:?} -> {:?}", id, title);
        }
    }
    unsafe {
        let _ = DestroyWindow(edit);
    }
    // Take the input method back, and put the keyboard where it was.
    crate::ime_focus(true);
    tabs::focus_active();
    repaint(frame);
}

extern "system" fn edit_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if msg == WM_KEYDOWN {
            let vk = wp.0 as u16;
            if vk == VK_RETURN.0 || vk == VK_ESCAPE.0 {
                let frame = GetParent(hwnd).unwrap_or_default();
                end_rename(frame, vk == VK_RETURN.0);
                return LRESULT(0);
            }
        }
        if msg == WM_KILLFOCUS {
            let frame = GetParent(hwnd).unwrap_or_default();
            // Clicking away keeps the edit, which is what a rename box that
            // was typed into should do.
            end_rename(frame, true);
            return LRESULT(0);
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT =
            std::mem::transmute(prev);
        f(hwnd, msg, wp, lp)
    }
}

// ------------------------------------------------------------------- paint

fn fill(hdc: HDC, r: &RECT, color: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(color));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

/// How many times the strip has actually painted. **"The strip was asked to
/// repaint" and "the strip painted" are different claims**, and a strip that
/// vanishes could be either; only a counter tells them apart.
static PAINTS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// One line that says everything the strip believes.
///
/// **Machine-readable on purpose.** Every strip defect so far was diagnosed
/// from a screenshot, and screenshots on this link have already produced one
/// false defect (a tab measured at 45px that was really 76px, because the
/// image was scaled 0.6). Order, titles,活动标签, scroll and overflow are
/// facts the host knows; printing them removes the eye from the loop.
///
/// The tab order and the titles are printed **together**, because the defect
/// worth catching here is precisely the one where they disagree.
///
/// `client=` is here because `onscreen=` is a *derived* number: it depends on
/// the client width, and a line that prints the conclusion without the input
/// cannot say whether the window changed or the arithmetic did. That question
/// came up the first time these two lines were compared across runs.
pub fn state_line(frame: HWND) -> String {
    let (tabs_now, active) = tabs::strip_snapshot();
    let (slots, overflow) = slots(frame);
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(frame, &mut rc);
    }
    let listed: Vec<String> = tabs_now
        .iter()
        .map(|(id, t)| format!("{}:{}", id.0, t))
        .collect();
    let onscreen = slots
        .iter()
        .filter(|s| s.rect.right > 0 && s.rect.left < rc.right)
        .count();
    let active_id = tabs_now.get(active).map(|(id, _)| id.0).unwrap_or(0);
    let (tw, _) = layout(
        (rc.right - crate::shell::reserved_right()).max(1),
        tabs::scale_of(),
        tabs_now.len(),
    );
    format!(
        "tabs=[{}] active={} n={} client={}x{} tw={} scroll={} overflow={} onscreen={} paints={}",
        listed.join(","),
        active_id,
        tabs_now.len(),
        rc.right - rc.left,
        rc.bottom - rc.top,
        tw,
        with_ui(|u| u.scroll),
        overflow.is_some(),
        onscreen,
        PAINTS.load(std::sync::atomic::Ordering::Relaxed)
    )
}

pub fn log_state(frame: HWND, tag: &str) {
    logf!("[strip] {} | {}", tag, state_line(frame));
}

/// Draw the strip. Called from the frame's `WM_PAINT`.
pub fn paint(frame: HWND) {
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(frame, &mut ps) };
    if hdc.is_invalid() {
        // EndPaint even so: without it the update region stays invalid and
        // Windows asks again, forever.
        let _ = unsafe { EndPaint(frame, &ps) };
        logf!("[strip] BeginPaint failed; nothing drawn");
        return;
    }
    PAINTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(frame, &mut rc) };
    let scale = tabs::scale_of();
    let sh = strip_h(scale);
    let strip = RECT { left: 0, top: 0, right: rc.right, bottom: sh };

    // Rule 3: everything is drawn once, into memory, and blitted. A drag
    // repaints on every mouse move; painting straight into the window DC
    // would flicker the whole strip on each one.
    unsafe {
        let mem = CreateCompatibleDC(Some(hdc));
        let bmp = CreateCompatibleBitmap(hdc, rc.right.max(1), sh.max(1));
        let old = SelectObject(mem, bmp.into());

        fill(mem, &strip, 0x00201f1d);

        let (tabs_now, active) = tabs::strip_snapshot();
        let (slots, overflow) = slots(frame);
        let (hover, dragging) = with_ui(|u| {
            (
                u.hover,
                match u.drag {
                    Drag::Dragging { id } => Some(id),
                    _ => None,
                },
            )
        });

        SetBkMode(mem, TRANSPARENT);
        let font = GetStockObject(DEFAULT_GUI_FONT);
        let old_font = SelectObject(mem, font);

        for (i, slot) in slots.iter().enumerate() {
            // Scrolled off either end: nothing to draw.
            if slot.rect.right < 0 || slot.rect.left > rc.right {
                continue;
            }
            let is_active = i == active;
            let is_hover = matches!(hover, Hit::Tab(h) | Hit::Close(h) if h == slot.id);
            let is_dragged = dragging == Some(slot.id);

            let bg = if is_dragged {
                0x00504f4d
            } else if is_active {
                0x00403f3d
            } else if is_hover {
                0x00302f2d
            } else {
                0x00282725
            };
            fill(mem, &slot.rect, bg);

            // The active tab gets a lit edge along the bottom -- the cheapest
            // mark that reads as "this one" even at a glance.
            if is_active {
                let underline = RECT {
                    left: slot.rect.left,
                    top: slot.rect.bottom - (2.0 * scale) as i32,
                    right: slot.rect.right,
                    bottom: slot.rect.bottom,
                };
                fill(mem, &underline, 0x00c8a35a);
            }

            SetTextColor(
                mem,
                COLORREF(if is_active { 0x00ffffff } else { 0x00a0a0a0 }),
            );
            let label = tabs_now
                .get(i)
                .map(|(_, t)| format!(" {}: {}", i + 1, t))
                .unwrap_or_default();
            let mut wide: Vec<u16> = label.encode_utf16().collect();
            let right_edge = if slot.close.right > slot.close.left {
                slot.close.left - 2
            } else {
                slot.rect.right - (6.0 * scale) as i32
            };
            let mut tr = RECT {
                left: slot.rect.left + (4.0 * scale) as i32,
                top: 0,
                right: right_edge,
                bottom: sh,
            };
            DrawTextW(
                mem,
                &mut wide,
                &mut tr,
                DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS,
            );

            // The close glyph: two strokes, drawn rather than a font
            // character, so it lines up at any DPI.
            if slot.close.right > slot.close.left {
                let lit = matches!(hover, Hit::Close(h) if h == slot.id);
                let pen = CreatePen(
                    PS_SOLID,
                    (1.0 * scale).max(1.0) as i32,
                    COLORREF(if lit { 0x00ffffff } else { 0x00808080 }),
                );
                let old_pen = SelectObject(mem, pen.into());
                let pad = (4.0 * scale) as i32;
                let c = slot.close;
                let _ = MoveToEx(mem, c.left + pad, c.top + pad, None);
                let _ = LineTo(mem, c.right - pad, c.bottom - pad);
                let _ = MoveToEx(mem, c.right - pad, c.top + pad, None);
                let _ = LineTo(mem, c.left + pad, c.bottom - pad);
                SelectObject(mem, old_pen);
                let _ = DeleteObject(pen.into());
            }
        }

        // The overflow button, drawn last so the scrolled tabs pass under it.
        if let Some(r) = overflow {
            let lit = hover == Hit::Overflow;
            fill(mem, &r, if lit { 0x00403f3d } else { 0x00201f1d });
            SetTextColor(mem, COLORREF(if lit { 0x00ffffff } else { 0x00a0a0a0 }));
            let mut chevron: Vec<u16> = "\u{00bb}".encode_utf16().collect();
            let mut tr = r;
            DrawTextW(
                mem,
                &mut chevron,
                &mut tr,
                DT_CENTER | DT_SINGLELINE | DT_VCENTER,
            );
        }

        // The caption buttons go into the same memory DC, so the whole bar
        // is still one blit: they are part of the strip now, not a second
        // surface painted over it.
        let active = GetActiveWindow() == frame;
        crate::shell::paint_buttons(mem, frame, active);

        SelectObject(mem, old_font);
        let _ = BitBlt(hdc, 0, 0, rc.right, sh, Some(mem), 0, 0, SRCCOPY);
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
    }

    // **Clear whatever the panes do not cover.**
    //
    // Nothing else paints the frame's content area: the class has no
    // background brush and `WM_ERASEBKGND` is swallowed, both on purpose so
    // the GL panes never flicker. The consequence is that a pane which is
    // hidden -- by a zoom, or by switching tabs -- **leaves its last pixels
    // on the screen forever**, and the symptom is a `ShowWindow(SW_HIDE)`
    // that looks like it did nothing. `WS_CLIPCHILDREN` on the frame keeps
    // this fill off the visible panes.
    let mut below = rc;
    below.top = sh;
    if below.bottom > below.top {
        fill(hdc, &below, 0x00201f1d);
    }

    let _ = unsafe { EndPaint(frame, &ps) };
}

// --------------------------------------------------------------- striptest

/// The centre of a tab, and of its close button, in client coordinates.
fn centre_of(frame: HWND, index: usize) -> Option<(i32, i32, i32, i32)> {
    let (slots, _) = slots(frame);
    let s = slots.get(index)?;
    Some((
        (s.rect.left + s.rect.right) / 2,
        (s.rect.top + s.rect.bottom) / 2,
        (s.close.left + s.close.right) / 2,
        (s.close.top + s.close.bottom) / 2,
    ))
}

/// Click a tab **through the hit test**, without a mouse.
///
/// `--striptest`'s other steps call the model directly, and that is why they
/// did not reproduce the strip vanishing on click: the model path works. The
/// difference between the two paths *is* the defect, so this drives the same
/// entry point a real click does -- `on_button_down` / `on_button_up` with
/// coordinates taken from the strip's own geometry.
///
/// **What this still does not cover**: that Windows delivers the click to
/// this window with these coordinates. Everything after that point is here.
fn synth_click(frame: HWND, index: usize, on_close: bool) {
    let Some((tx, ty, cx, cy)) = centre_of(frame, index) else {
        logf!("[strip] synth_click: no slot {}", index);
        return;
    };
    let (x, y) = if on_close { (cx, cy) } else { (tx, ty) };
    logf!("[strip] synth click at ({},{}) on slot {}", x, y, index);
    on_button_down(frame, x, y);
    on_button_up(frame, x, y);
}

/// Drag a tab from one slot to another, through the state machine.
fn synth_drag(frame: HWND, from: usize, to: usize) {
    let (Some((x0, y0, _, _)), Some((x1, _, _, _))) =
        (centre_of(frame, from), centre_of(frame, to))
    else {
        logf!("[strip] synth_drag: missing slots");
        return;
    };
    logf!("[strip] synth drag {} -> {} (x {} -> {})", from, to, x0, x1);
    on_button_down(frame, x0, y0);
    // Several moves, because the drag only starts after DRAG_SLOP and the
    // reorder is recomputed on every move -- one jump would test neither.
    let steps = 6;
    for i in 1..=steps {
        let x = x0 + (x1 - x0) * i / steps;
        on_mouse_move(frame, x, y0);
    }
    on_button_up(frame, x1, y0);
}

/// The strip's acceptance run, driven by the host itself.
///
/// **Why this exists.** Every step below can be done with a mouse, and doing
/// it that way cost a day: three misplaced clicks (one of them minimised the
/// window, one landed in somebody else's session) and one defect reported
/// from a screenshot that turned out to be the screenshot's scaling. The
/// same lesson as `--selfresize`: **when the host can do the thing itself and
/// print the result as a number, no one has to aim.**
///
/// Each step prints the strip's whole state before and after, so the check is
/// a diff of two lines rather than a judgement about an image. What it cannot
/// cover is left to a human on purpose: typing Chinese into the rename box
/// needs a real IME, and whether the result *looks* right is not a fact the
/// host can print.
///
/// Returns false when the script is done.
pub fn script_step(frame: HWND, step: usize) -> bool {
    let tabs_now = || tabs::strip_snapshot().0;
    match step {
        // **Seventeen more tabs, not five.** Seven tabs at 123px wide never
        // overflow, so the first run exercised neither the scroll nor the
        // chevron -- `scroll` stayed 0 because the clamp was right, which
        // reads as a pass and tests nothing. Eighteen is where 60px minimum
        // times the count passes the strip width on this machine.
        0..=16 => {
            crate::binding("new_tab");
            if step == 16 {
                log_state(frame, "after 18 tabs; expect overflow=true, onscreen<n");
            }
            true
        }
        // Scroll: one notch right, then back. Now that it overflows, `scroll`
        // has somewhere to go and `onscreen` should change with it.
        17 => {
            on_wheel(frame, -120);
            log_state(frame, "after wheel right");
            true
        }
        18 => {
            on_wheel(frame, 120);
            log_state(frame, "after wheel left (expect scroll back to 0)");
            true
        }
        // **The reorder check.** The first tab goes to position 3. Renaming
        // it first is what makes the check real: with every title identical,
        // a parallel-array bug looks exactly like a correct move.
        19 => {
            let t = tabs_now();
            if let Some((id, _)) = t.first().cloned() {
                tabs::rename_tab(frame, id, "MOVED-ME".to_string());
                log_state(frame, "before move (the tab to watch is MOVED-ME)");
                tabs::move_tab_to(frame, id, 2);
                log_state(frame, "after move -- MOVED-ME must be at index 2");
            }
            true
        }
        // Activation through the model. `paints` is the reading: see whether
        // a repaint follows, and on which tick.
        20 => {
            let t = tabs_now();
            if let Some((id, _)) = t.get(5).cloned() {
                log_state(frame, "before activate(model)");
                tabs::activate_tab(frame, id);
                log_state(frame, "after activate(model)");
            }
            true
        }
        21 => {
            log_state(frame, "one tick later (model path)");
            true
        }
        // **Activation through the hit test** -- the path that lost the strip
        // on the real machine. Same reading, different entry point; if the
        // two disagree, the difference is the defect.
        22 => {
            log_state(frame, "before activate(click)");
            synth_click(frame, 3, false);
            log_state(frame, "after activate(click)");
            true
        }
        23 => {
            log_state(frame, "one tick later (click path)");
            true
        }
        // Drag through the state machine, with the scroll offset in play.
        24 => {
            log_state(frame, "before drag 0 -> 4");
            synth_drag(frame, 0, 4);
            log_state(frame, "after drag -- MOVED-ME's neighbours must be intact");
            true
        }
        // The close button, again through the hit test.
        25 => {
            log_state(frame, "before close-button click on slot 1");
            synth_click(frame, 1, true);
            log_state(frame, "after close-button click");
            true
        }
        26 => {
            log_state(frame, "one tick after close");
            true
        }
        _ => {
            log_state(frame, "striptest done");
            false
        }
    }
}
