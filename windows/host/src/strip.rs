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

use crate::{logf, wlogf};
use crate::menu::{draw_menu_button, show_root_menu};
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

/// The `≡` button's width at this scale, which is also **the tabs' left
/// inset**.
///
/// **One line, forwarding to `menu.rs`, on purpose.** `s4.md` §3.1 pins the
/// button to the strip's left end (the right end belongs to the caption
/// buttons, and a button that moves with the tab count is one you have to
/// find again every time), which makes its width and the tabs' inset the same
/// fact. Computing `46 * scale` here as well would be that fact stored twice:
/// the two would agree at every scale until one of them changed its rounding,
/// and the symptom would be tabs starting one pixel off with nothing to
/// report it.
pub fn menu_w(scale: f64) -> i32 {
    crate::menu::button_w(scale)
}

pub fn strip_h(scale: f64) -> i32 {
    ((STRIP_H as f64) * scale).round() as i32
}

/// One tab's geometry: the whole tab, and its close button.
pub struct Slot {
    pub id: TabId,
    pub rect: RECT,
    pub close: RECT,
}

/// The close cross's side, in pixels.
fn close_side_px(scale: f64) -> i32 {
    (14.0 * scale) as i32
}

/// Does a tab this wide have room for its close cross?
///
/// **Split out of `slots` so it can be tested**, because the answer being
/// "always yes" is a property of two constants that live far apart
/// (`TAB_MIN_W` here, the factor below) and nothing connected them.
fn tab_shows_close(tw: i32, scale: f64) -> bool {
    tw > close_side_px(scale) * 4
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
/// `inset` is what the tabs do not get: the main-menu button's width. **A
/// parameter rather than a call to `menu_w` from inside here**, so the
/// arithmetic stays a pure function of its inputs and a strip with no button
/// is still expressible -- which is what makes the inset testable at all.
///
/// Returns `(tab width, overflowing)`.
pub fn layout(strip_w: i32, scale: f64, n: usize, inset: i32) -> (i32, bool) {
    let min_w = (TAB_MIN_W as f64 * scale) as i32;
    let max_w = (TAB_MAX_W as f64 * scale) as i32;
    if n == 0 {
        return (min_w, false);
    }
    let avail = (strip_w - inset).max(1);
    let n = n as i32;
    // Does it fit at the narrowest we are willing to draw?
    if n * min_w > avail {
        return (min_w, true);
    }
    ((avail / n).clamp(min_w, max_w), false)
}

/// Where tab `i` starts, in strip coordinates.
///
/// **Split out so the inset can be pinned by a test.** The number this
/// returns for `i == 0` is the whole of §3.1's "the first slot moves right by
/// the button's width", and inlined in `slots` it was reachable only through
/// an `HWND`.
fn tab_x(inset: i32, i: usize, tw: i32, scroll: i32) -> i32 {
    inset + i as i32 * tw - scroll
}

/// The whole strip's content width, and how far it can be scrolled.
fn extent(strip_w: i32, tw: i32, n: usize, overflowing: bool, inset: i32) -> (i32, i32) {
    let content = tw * n as i32;
    // The button's width is gone from the visible span too, not just from the
    // tabs' start: leaving it in here scrolls the strip 46px past its end,
    // and the symptom is a last tab that cannot be reached.
    let visible = if overflowing {
        strip_w - inset - (OVERFLOW_W as f64 * tabs::scale_of()) as i32
    } else {
        strip_w - inset
    };
    (content, (content - visible).max(0))
}

/// The `≡` button's rectangle: the strip's left end, always, whatever the
/// tabs are doing.
fn menu_rect(scale: f64, sh: i32) -> RECT {
    RECT { left: 0, top: 0, right: menu_w(scale), bottom: sh }
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
    let g = slots(frame);
    // The menu button is in here through `hit`, which is what makes those
    // 46px answer `HTCLIENT`. Left out, the button would still be drawn and
    // still be dead: pressing it would drag the window, and the defect would
    // look like a menu that does not open rather than like a hit test.
    hit(&g, x, y) != Hit::None
}

/// The tabs' geometry, and the overflow button's if there is one.
///
/// The scroll offset is clamped here rather than where it is changed: the
/// number of tabs can change without the pointer touching anything, and a
/// stale offset would leave the strip scrolled past its own end.
/// Where the `+` goes: straight after the last tab, the way every browser
/// puts it, and pinned to the right end when the tabs no longer fit.
///
/// **Pinned rather than dropped.** A `+` that disappears once there are
/// enough tabs teaches the user it was never there; one that stays put is
/// still where they last saw it.
fn new_rect(strip_w: i32, scale: f64, sh: i32, after_tabs: i32, overflowing: bool, inset: i32) -> RECT {
    let w = (OVERFLOW_W as f64 * scale) as i32;
    let right_limit = if overflowing { strip_w - w } else { strip_w };
    // Floored at the inset, not at 0: with no tabs at all the `+` would
    // otherwise sit underneath the menu button, and whichever the hit test
    // named first would win a click aimed at the other.
    let left = after_tabs.min(right_limit - w).max(inset);
    RECT { left, top: 0, right: left + w, bottom: sh }
}

/// Everything on the strip that a pointer can be over.
///
/// A struct rather than a tuple that grew a fourth member: every caller here
/// passes the whole thing on to `hit`, and a four-tuple of rectangles is four
/// chances to swap two of them silently.
struct Geometry {
    slots: Vec<Slot>,
    overflow: Option<RECT>,
    new: RECT,
    menu: RECT,
}

fn slots(frame: HWND) -> Geometry {
    let (tabs_now, _) = tabs::strip_snapshot();
    let scale = tabs::scale_of();
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return Geometry {
                slots: Vec::new(),
                overflow: None,
                new: RECT::default(),
                menu: RECT::default(),
            };
        }
    }
    let sh = strip_h(scale);
    // The caption buttons live at the right end of the strip now that the
    // strip *is* the caption. Their width comes out of the space the tabs
    // get; **this is the only thing about the shell the strip knows.** The
    // drag-position arithmetic below is untouched by it.
    let strip_w = (rc.right - rc.left - crate::shell::reserved_right()).max(1);
    let n = tabs_now.len();
    let inset = menu_w(scale);
    let (tw, overflowing) = layout(strip_w, scale, n, inset);
    let (_, max_scroll) = extent(strip_w, tw, n, overflowing, inset);

    let scroll = with_ui(|u| {
        u.scroll = u.scroll.clamp(0, max_scroll);
        u.scroll
    });

    let close_side = close_side_px(scale);
    let slots = tabs_now
        .into_iter()
        .enumerate()
        .map(|(i, (id, _))| {
            let x = tab_x(inset, i, tw, scroll);
            let rect = RECT { left: x, top: 0, right: x + tw - 1, bottom: sh };
            // The close button only earns its space once the tab is wide
            // enough that it does not swallow the label.
            let close = if tab_shows_close(tw, scale) {
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
    let after_tabs = tab_x(inset, n, tw, scroll);
    Geometry {
        slots,
        overflow: overflowing.then(|| overflow_rect(strip_w, scale, sh)),
        new: new_rect(strip_w, scale, sh, after_tabs, overflowing, inset),
        menu: menu_rect(scale, sh),
    }
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
    /// The `+`. **Added 2026-09-02**: the strip had no target for "make
    /// another one of these", so the only way to open a tab was a keyboard
    /// shortcut nobody is told about. `docs/windows/discoverability.md` §3.1
    /// quotes this enum as the evidence that D1 could not pass; that quote
    /// needs updating now that this variant exists.
    New,
    /// The `≡` at the left end. **Added 2026-09-02** for `s4.md` §3.1, the
    /// same way `New` was added: appended, never inserted. `Hit` is compared
    /// for equality all over this file (hover, drag, the close-on-release
    /// check), and reordering the variants would change what those
    /// comparisons mean without changing a line of the code that makes them.
    Menu,
}

fn hit(g: &Geometry, x: i32, y: i32) -> Hit {
    // First, and it costs nothing: the menu button is pinned to the left end
    // and the tabs are inset past it, so today nothing can overlap it. It is
    // tested first anyway, so that if a future edit narrows the inset the
    // answer stays "the control that is drawn on top" -- which is the rule
    // `New` and `Overflow` below already follow.
    if contains(&g.menu, x, y) {
        return Hit::Menu;
    }
    let (slots, overflow, new) = (&g.slots, g.overflow, g.new);
    // The button sits on top of whatever the strip scrolled under it.
    if let Some(r) = overflow {
        if contains(&r, x, y) {
            return Hit::Overflow;
        }
    }
    // Before the tabs: when the strip is full the `+` is pinned over the end
    // of the last tab, and the thing on top is the thing that was clicked.
    if contains(&new, x, y) {
        return Hit::New;
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
    let g = slots(frame);
    match hit(&g, x, y) {
        // The root menu is not this file's to build. All the strip owns is
        // "the pointer is on the button", and the button's rectangle to hang
        // the menu off.
        Hit::Menu => {
            show_root_menu(frame, g.menu);
            return;
        }
        // Straight to the core's own action, the same one the keyboard bind
        // reaches. The strip does not know how to make a tab and should not
        // learn.
        Hit::New => {
            let ok = crate::binding("new_tab");
            wlogf!(frame, "[strip] click -> new_tab, binding_action = {}", ok);
        }
        Hit::Overflow => {
            show_overflow_menu(frame, g.overflow.unwrap_or_default());
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
    let g = slots(frame);

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

    let h = hit(&g, x, y);
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
        let tw = g.slots.first().map(|s| s.rect.right - s.rect.left + 1).unwrap_or(1);
        let scroll = with_ui(|u| u.scroll);
        // The inset comes back out of the pointer position along with the
        // scroll, for the same reason: both shift where tab 0 starts, and a
        // drag that forgets either lands one slot off at every position.
        let inset = menu_w(tabs::scale_of());
        let want = ((x + scroll - inset).max(0) / tw.max(1))
            .clamp(0, g.slots.len().saturating_sub(1) as i32) as usize;
        let at = g.slots.iter().position(|s| s.id == id);
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
    wlogf!(frame, "[strip] wheel {} -> scroll {}", by, with_ui(|u| u.scroll));
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
    let g = slots(frame);
    if g.overflow.is_none() {
        return;
    }
    let Some(slot) = g.slots.iter().find(|s| s.id == id) else {
        return;
    };
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return;
        }
    }
    let right_edge = rc.right - (OVERFLOW_W as f64 * tabs::scale_of()) as i32;
    let inset = menu_w(tabs::scale_of());
    with_ui(|u| {
        if slot.rect.left < inset {
            u.scroll += slot.rect.left - inset;
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
    let g = slots(frame);
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
        if hit(&g, x, y) == Hit::Close(id) {
            logf!("[strip] close {:?}", id);
            crate::winid::close_requested(frame, crate::winid::CloseVia::StripCross);
            tabs::close_tab(frame, id);
            return;
        }
    }
    repaint(frame);
}

pub fn on_double_click(frame: HWND, x: i32, y: i32) {
    let g = slots(frame);
    if let Hit::Tab(id) = hit(&g, x, y) {
        if let Some(slot) = g.slots.iter().find(|s| s.id == id) {
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
        wlogf!(frame, "[strip] rename: CreateWindowExW(EDIT) failed");
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
    let g = slots(frame);
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(frame, &mut rc);
    }
    let listed: Vec<String> = tabs_now
        .iter()
        .map(|(id, t)| format!("{}:{}", id.0, t))
        .collect();
    let onscreen = g
        .slots
        .iter()
        .filter(|s| s.rect.right > 0 && s.rect.left < rc.right)
        .count();
    let active_id = tabs_now.get(active).map(|(id, _)| id.0).unwrap_or(0);
    let scale = tabs::scale_of();
    let (tw, _) = layout(
        (rc.right - crate::shell::reserved_right()).max(1),
        scale,
        tabs_now.len(),
        menu_w(scale),
    );
    // `inset=` and `tab0=` are printed because §3.1's whole claim is about
    // where the first tab starts, and a line that prints only the tab width
    // cannot say whether the inset was applied, skipped, or applied twice.
    format!(
        "tabs=[{}] active={} n={} client={}x{} inset={} tab0={} tw={} scroll={} overflow={} onscreen={} paints={}",
        listed.join(","),
        active_id,
        tabs_now.len(),
        rc.right - rc.left,
        rc.bottom - rc.top,
        menu_w(scale),
        g.slots.first().map(|s| s.rect.left).unwrap_or(-1),
        tw,
        with_ui(|u| u.scroll),
        g.overflow.is_some(),
        onscreen,
        PAINTS.load(std::sync::atomic::Ordering::Relaxed)
    )
}

pub fn log_state(frame: HWND, tag: &str) {
    wlogf!(frame, "[strip] {} | {}", tag, state_line(frame));
}

/// Draw the strip. Called from the frame's `WM_PAINT`.
pub fn paint(frame: HWND) {
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(frame, &mut ps) };
    if hdc.is_invalid() {
        // EndPaint even so: without it the update region stays invalid and
        // Windows asks again, forever.
        let _ = unsafe { EndPaint(frame, &ps) };
        wlogf!(frame, "[strip] BeginPaint failed; nothing drawn");
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
        let colours = tabs::tab_colors();
        let Geometry { slots, overflow, new, menu } = slots(frame);
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

            // The tab's colour, if it has one: a bar along the top edge.
            // **Looked up by id**, not by the loop counter -- the colours
            // come from a second snapshot and the two lists are only in the
            // same order until they are not.
            let colour = colours
                .iter()
                .find(|(cid, _)| *cid == slot.id)
                .map(|(_, c)| *c)
                .unwrap_or(0) as usize;
            if colour > 0 && colour < TAB_COLORS.len() {
                let bar = RECT {
                    left: slot.rect.left,
                    top: slot.rect.top,
                    right: slot.rect.right,
                    bottom: slot.rect.top + (3.0 * scale).max(2.0) as i32,
                };
                fill(mem, &bar, TAB_COLORS[colour].1);
            }

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

        // The `≡`. Drawn before the tabs would be wrong -- nothing can reach
        // under it -- and drawn here, after them, it is also drawn over the
        // strip's own background rather than over a tab, which is what the
        // hit test says is true.
        draw_menu_button(mem, menu, scale, hover == Hit::Menu);

        // The `+`, drawn before the overflow button so that when both are
        // pinned to the right the overflow one wins the pixels -- the same
        // order the hit test uses, so what is clicked is what is seen.
        {
            // Same two colours the overflow button uses, so the two controls
            // at the right end read as one row rather than two decorations.
            let lit = hover == Hit::New;
            fill(mem, &new, if lit { 0x00403f3d } else { 0x00201f1d });
            SetTextColor(mem, COLORREF(if lit { 0x00ffffff } else { 0x00a0a0a0 }));
            let mut plus: Vec<u16> = "+".encode_utf16().collect();
            let mut r2 = new;
            DrawTextW(mem, &mut plus, &mut r2, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
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


// -------------------------------------------------------------------- menus
//
// Three menus hang off this file. Only one of them is built here.
//
//  * The **root** menu (the `≡` at the left end) belongs to `menu.rs`; the
//    strip owns the button's rectangle and its hit test, and hands both to
//    `menu.rs` to draw and to open.
//  * The **tab** menu and the **blank-strip** menu are built here, because
//    both are answers to "which tab is under the pointer", and that question
//    has exactly one implementation in this process (`hit`).

// The button's rectangle, its hit test and its paint are the strip's; what
// it draws and what it opens are `menu.rs`'s. The two call sites are
// `on_button_down` (`Hit::Menu`) and `paint`.

// ------------------------------------------------------- the tab right-click

/// Which tab a right-click landed on, and how many there are.
///
/// **This is the value that must survive to the far end.** `s4.md` §3.3 ends
/// on it: a menu opened on tab 3 that acts on the focused tab looks entirely
/// correct -- the menu appears where you clicked, the item you picked does
/// what it says -- and closes the wrong terminal. So the identity is resolved
/// once, here, and everything downstream takes a `TabId`; nothing downstream
/// is allowed to ask what the active tab is.
pub struct MenuTarget {
    pub index: usize,
    pub id: TabId,
    pub n: usize,
}

pub fn tab_menu_target(frame: HWND, x: i32, y: i32) -> Option<MenuTarget> {
    let g = slots(frame);
    let id = match hit(&g, x, y) {
        // The close cross counts as its tab: a right-click is not a click,
        // and landing two pixels inside the cross should not mean "no tab".
        Hit::Tab(id) | Hit::Close(id) => id,
        _ => return None,
    };
    let index = g.slots.iter().position(|s| s.id == id)?;
    Some(MenuTarget { index, id, n: g.slots.len() })
}

/// The tab colours, `0` being none. Nine plus none, which is what
/// `TerminalTabColor.swift` has; `s4.md` §3.3 says eight and is out by one.
/// The values are macOS's own system colours, as `COLORREF` (`0x00BBGGRR`).
const TAB_COLORS: &[(&str, u32)] = &[
    ("无颜色", 0x00000000),
    ("蓝", 0x00FF840A),
    ("紫", 0x00F25ABF),
    ("粉", 0x005F37FF),
    ("红", 0x003A45FF),
    ("橙", 0x000A9FFF),
    ("黄", 0x000AD6FF),
    ("绿", 0x0058D130),
    ("青", 0x00E2E663),
    ("石墨", 0x00938E8E),
];

/// One row of the tab menu, ported item for item from
/// `TerminalWindow.swift:717` (`configureTabContextMenuIfNeeded` and the two
/// sections it appends). **That code is this repository's own, not something
/// AppKit supplies**, so there is nothing here that a platform gives away.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum TabCmd {
    Close,
    CloseOthers,
    CloseRight,
    MoveToNewWindow,
    Rename,
    Supervisor,
    Watch,
    Shield,
}

impl TabCmd {
    fn label(self) -> &'static str {
        match self {
            TabCmd::Close => "关闭标签",
            TabCmd::CloseOthers => "关闭其他标签",
            TabCmd::CloseRight => "关闭右侧的标签",
            TabCmd::MoveToNewWindow => "移到新窗口",
            TabCmd::Rename => "重命名标签…",
            TabCmd::Supervisor => "设为总管",
            TabCmd::Watch => "监督此终端",
            TabCmd::Shield => "禁止 agent 进入",
        }
    }

    /// What the log line names. For the three agent rows this **is** a core
    /// binding name, checked against `src/input/Binding.zig`'s `Action`
    /// union; for the rest it names the host operation that ran, because
    /// there is no core action that means "close every tab but this named
    /// one" -- see `close_other_tabs`.
    fn action(self) -> &'static str {
        match self {
            TabCmd::Close => "close_tab:this",
            TabCmd::CloseOthers => "close_tab:other",
            TabCmd::CloseRight => "close_tab:right",
            TabCmd::MoveToNewWindow => "move_tab_to_new_window",
            TabCmd::Rename => "rename_tab",
            TabCmd::Supervisor => "poltergeist_supervisor",
            TabCmd::Watch => "poltergeist_toggle_watch",
            TabCmd::Shield => "poltergeist_toggle_shielded",
        }
    }

    /// Ticked when the terminal already is what the row offers to make it.
    /// The comment macOS wrote for this is worth keeping: a row that has been
    /// used has to look different from one that has not, or the only way to
    /// find out whether the last click landed is to click it again.
    ///
    /// **Three different state bits, read three times.** Sharing one getter
    /// between them is the most natural way to write this and would tick all
    /// three together.
    fn checked(self, role: u8, shielded: bool) -> bool {
        match self {
            TabCmd::Supervisor => role == 1,
            TabCmd::Watch => role == 2,
            TabCmd::Shield => shielded,
            _ => false,
        }
    }

    /// Rows the host cannot do yet. **Greyed, never hidden** (`s4.md` §3.4.3):
    /// a row that is missing and a row that never existed look the same.
    ///
    /// `move_tab_to_new_window` is a real core action and a real gap *here*:
    /// the Windows host has one frame, and `ACTION_MOVE_TAB_TO_NEW_WINDOW`
    /// (tag 69) is not dispatched. It is a piece of S4 nobody has written,
    /// not something the core lacks.
    fn enabled(self) -> bool {
        !matches!(self, TabCmd::MoveToNewWindow)
    }
}

/// Top level of the tab menu, in order. `None` is a separator.
const TAB_MENU: &[Option<TabCmd>] = &[
    Some(TabCmd::Close),
    Some(TabCmd::CloseOthers),
    Some(TabCmd::CloseRight),
    Some(TabCmd::MoveToNewWindow),
    None,
    Some(TabCmd::Rename),
    // The colour submenu is inserted here, between the two separators.
    None,
    Some(TabCmd::Supervisor),
    Some(TabCmd::Watch),
    Some(TabCmd::Shield),
];

/// Command ids. Well clear of anything Windows sends, and clear of
/// `ctxmenu.rs`'s `0x4000` block so a stray id cannot be read by both.
const TAB_ID_BASE: usize = 0x5000;
const TAB_COLOR_BASE: usize = 0x5100;
const STRIP_ID_BASE: usize = 0x5200;

/// A tab's 1-based position **right now**, or `?` if it has gone.
fn ordinal(id: TabId) -> String {
    match tabs::index_of(id) {
        Some((i, _)) => (i + 1).to_string(),
        None => "?".to_string(),
    }
}

/// The tab right-click menu, on the tab that was right-clicked.
fn show_tab_menu(frame: HWND, target: MenuTarget, x: i32, y: i32) {
    let (role, shielded) = tabs::tab_mark(target.id);
    let colour = tabs::tab_color(target.id);

    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else {
            wlogf!(frame, "[tabmenu] CreatePopupMenu failed");
            return;
        };
        let Ok(colours) = CreatePopupMenu() else {
            let _ = DestroyMenu(menu);
            wlogf!(frame, "[tabmenu] CreatePopupMenu (colours) failed");
            return;
        };
        for (i, (name, _)) in TAB_COLORS.iter().enumerate() {
            let mut wide: Vec<u16> = name.encode_utf16().collect();
            wide.push(0);
            let flags = if i as u8 == colour {
                MF_STRING | MF_CHECKED
            } else {
                MF_STRING
            };
            let _ = AppendMenuW(colours, flags, TAB_COLOR_BASE + i, PCWSTR(wide.as_ptr()));
        }

        let mut items = 0usize;
        for (i, row) in TAB_MENU.iter().enumerate() {
            let Some(cmd) = row else {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
                // The colour submenu goes after the second separator, which
                // is where macOS puts it (right below "Rename Tab...").
                if i == 6 {
                    let mut wide: Vec<u16> = "标签颜色".encode_utf16().collect();
                    wide.push(0);
                    let _ = AppendMenuW(
                        menu,
                        MF_POPUP,
                        menu_handle_as_id(colours),
                        PCWSTR(wide.as_ptr()),
                    );
                    items += 1;
                }
                continue;
            };
            let mut flags = MF_STRING;
            if cmd.checked(role, shielded) {
                flags |= MF_CHECKED;
            }
            if !cmd.enabled() {
                flags |= MF_GRAYED;
            }
            let mut wide: Vec<u16> = cmd.label().encode_utf16().collect();
            wide.push(0);
            let _ = AppendMenuW(menu, flags, TAB_ID_BASE + i, PCWSTR(wide.as_ptr()));
            items += 1;
        }

        // Printed **before** `TrackPopupMenu`, which runs a nested message
        // loop and does not come back until the menu is dismissed. `items`
        // counts selectable rows, separators excluded.
        wlogf!(frame, 
            "[tabmenu] shown for tab {} of {} at {},{} items={}",
            target.index + 1,
            target.n,
            x,
            y,
            items
        );
        // **The ticks, in words.** The unit test on `TabCmd::checked` proves
        // that pure function is right; it cannot say that `role` and
        // `shielded` came from the tab that was right-clicked, nor that the
        // flags reached `AppendMenuW`. Nothing else can either: the only
        // other reading is a photograph of a menu, taken while
        // `TrackPopupMenu` is running a nested modal loop -- and the capture
        // on this link has already reported a scale it did not have.
        wlogf!(frame, 
            "[tabmenu] tab {} ticks: supervisor={} watch={} shield={} colour={}",
            target.index + 1,
            role == 1,
            role == 2,
            shielded,
            colour
        );

        let mut pt = POINT { x, y };
        let _ = ClientToScreen(frame, &mut pt);
        let cmd = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_TOPALIGN,
            pt.x,
            pt.y,
            None,
            frame,
            None,
        );
        let _ = DestroyMenu(menu);
        cmd.0 as usize
    };

    if chosen == 0 {
        wlogf!(frame, "[tabmenu] dismissed without a choice");
        return;
    }
    if (TAB_COLOR_BASE..TAB_COLOR_BASE + TAB_COLORS.len()).contains(&chosen) {
        let c = chosen - TAB_COLOR_BASE;
        run_tab_colour(frame, target.id, c as u8);
        return;
    }
    // Subtracted only after the range is known: an id below the base would
    // wrap, and a wrapped index is a lookup that fails for the wrong reason.
    let row = chosen
        .checked_sub(TAB_ID_BASE)
        .and_then(|i| TAB_MENU.get(i))
        .copied()
        .flatten();
    let Some(cmd) = row else {
        logf!("[tabmenu] returned an id outside the table: {}", chosen);
        return;
    };
    run_tab_command(frame, target.id, cmd);
}

/// `AppendMenuW`'s `uIDNewItem` is the submenu handle for an `MF_POPUP` row.
fn menu_handle_as_id(m: HMENU) -> usize {
    m.0 as usize
}

fn run_tab_colour(frame: HWND, id: TabId, c: u8) {
    let ok = tabs::set_tab_color(frame, id, c);
    logf!(
        "[tabmenu] pick {:?} tab {} -> tab_color:{} ok={}",
        TAB_COLORS[c as usize].0,
        ordinal(id),
        c,
        ok as u8
    );
}

/// Do the thing, on the tab that was right-clicked.
///
/// **`ordinal(id)` is re-read here, at the point the work happens, and it is
/// in every log line this function prints.** It is not the number
/// `show_tab_menu` printed and it is not passed in: an implementation that
/// carries the index correctly as far as the menu and then falls back to "the
/// current tab" to do the work passes every check that reads only the
/// `shown` line. This is the one place that can tell them apart.
fn run_tab_command(frame: HWND, id: TabId, cmd: TabCmd) {
    let at = ordinal(id);
    // Taken before anything closes, purely so the `remaining` line below can
    // *name* the survivors. The survivors themselves are re-enumerated after
    // the fact; this is the naming, not the arithmetic.
    let before: Vec<TabId> = tabs::strip_snapshot().0.into_iter().map(|(i, _)| i).collect();

    let ok = match cmd {
        TabCmd::Close => {
            // **Recorded where the request is made, not where it ends.** This
            // and the close cross below both call `close_tab`, so the ending
            // cannot say which one a person used -- and they are two different
            // gestures that a fix might cover only one of.
            crate::winid::close_requested(frame, crate::winid::CloseVia::Menu);
            tabs::close_tab(frame, id);
            report_remaining(frame, &before, &format!("closed tab {}", at));
            true
        }
        TabCmd::CloseOthers => {
            tabs::close_other_tabs(frame, id);
            report_remaining(frame, &before, &format!("closed other than tab {}", at));
            true
        }
        TabCmd::CloseRight => {
            tabs::close_tabs_right_of(frame, id);
            report_remaining(frame, &before, &format!("closed right of tab {}", at));
            true
        }
        // Greyed, so this is unreachable from the menu. Kept as a real arm
        // rather than `unreachable!()`: the row becoming live is a one-line
        // change in `enabled`, and a panic is a poor way to find that out.
        TabCmd::MoveToNewWindow => false,
        TabCmd::Rename => {
            let g = slots(frame);
            match g.slots.iter().find(|s| s.id == id) {
                Some(slot) => {
                    // The editor opens on the tab that was right-clicked --
                    // the same trap as the actions, with its own exit.
                    begin_rename(frame, id, slot.rect);
                    true
                }
                None => false,
            }
        }
        TabCmd::Supervisor | TabCmd::Watch | TabCmd::Shield => {
            // Straight at that tab's surface. `crate::binding` would send it
            // to whichever surface has focus.
            tabs::binding_on_tab(id, cmd.action())
        }
    };

    wlogf!(frame, 
        "[tabmenu] pick {:?} tab {} -> {} ok={}",
        cmd.label(),
        at,
        cmd.action(),
        ok as u8
    );
}

/// `[tabmenu] closed tab 3, remaining 1,2,4,5`.
///
/// **The survivors are enumerated from the model after the close**, and only
/// then labelled with the positions they held before it. Subtracting one
/// entry from the pre-close list would produce the same line while proving
/// nothing except that the arithmetic in this function is consistent with
/// itself -- and the tabs are indistinguishable on screen, so a screenshot
/// cannot supply what this line does not.
fn report_remaining(frame: HWND, before: &[TabId], what: &str) {
    let (after, _) = tabs::strip_snapshot();
    let names: Vec<String> = after
        .iter()
        .map(|(id, _)| match before.iter().position(|b| b == id) {
            Some(i) => (i + 1).to_string(),
            None => "?".to_string(),
        })
        .collect();
    wlogf!(frame, "[tabmenu] {}, remaining {}", what, names.join(","));
}

// ------------------------------------------------- the blank-strip right-click

/// The three rows for the empty part of the strip (`s4.md` §3.3).
/// The blank-strip rows. The third field is whether the row does something
/// the core knows about; `reopen_closed_tab` is the host's own, so it is
/// dispatched here rather than handed to `binding`.
const STRIP_MENU: &[(&str, &str, bool)] = &[
    ("新建标签", "new_tab", true),
    // **The host's, not the core's.** There is no `reopen_closed_tab` in
    // `Binding.zig`; macOS's row calls `reopenClosedTab:`, an application
    // selector backed by `ClosedTabs.swift`. The equivalent stack lives in
    // `reopen.rs`, so the action string here names the host and is never
    // handed to `binding_action`, which would silently return false.
    ("重开关闭的标签", "host:reopen_closed_tab", false),
    ("命令面板", "toggle_command_palette", true),
];

fn show_strip_menu(frame: HWND, x: i32, y: i32) {
    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else {
            wlogf!(frame, "[stripmenu] CreatePopupMenu failed");
            return;
        };
        // Greyed only when there is genuinely nothing to reopen -- not
        // because the feature is missing. A row that is grey for one reason
        // today and another reason tomorrow has to say which, and the log
        // line below is where it says it.
        let can_reopen = crate::reopen::can_reopen();
        for (i, (label, action, _)) in STRIP_MENU.iter().enumerate() {
            let mut wide: Vec<u16> = label.encode_utf16().collect();
            wide.push(0);
            let live = *action != "host:reopen_closed_tab" || can_reopen;
            let flags = if live { MF_STRING } else { MF_STRING | MF_GRAYED };
            let _ = AppendMenuW(menu, flags, STRIP_ID_BASE + i, PCWSTR(wide.as_ptr()));
        }
        wlogf!(frame, 
            "[stripmenu] shown at {},{} items={}",
            x,
            y,
            STRIP_MENU.len()
        );
        let mut pt = POINT { x, y };
        let _ = ClientToScreen(frame, &mut pt);
        let cmd = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_TOPALIGN,
            pt.x,
            pt.y,
            None,
            frame,
            None,
        );
        let _ = DestroyMenu(menu);
        cmd.0 as usize
    };
    if chosen == 0 {
        wlogf!(frame, "[stripmenu] dismissed without a choice");
        return;
    }
    let Some((label, action, _)) =
        chosen.checked_sub(STRIP_ID_BASE).and_then(|i| STRIP_MENU.get(i))
    else {
        logf!("[stripmenu] returned an id outside the table: {}", chosen);
        return;
    };
    // Host rows never reach `binding_action`: an action name the core does
    // not have returns false and does nothing, which is the failure mode this
    // whole evening has been about.
    let ok = if let Some(host) = action.strip_prefix("host:") {
        run_strip_host_action(frame, host)
    } else {
        crate::binding(action)
    };
    wlogf!(frame, "[stripmenu] pick {:?} -> {} ok={}", label, action, ok as u8);
}

/// The blank-strip rows the core knows nothing about.
fn run_strip_host_action(frame: HWND, name: &str) -> bool {
    match name {
        // **The whole of it is one call.** The stack, the bound, the refusal
        // to remember a tab with no directory, and the log lines around all
        // three belong to `reopen.rs`; this row's only job is to press the
        // button. Reading the stack here as well is how the greying and the
        // action come to disagree.
        "reopen_closed_tab" => crate::reopen::reopen_last(),
        other => {
            wlogf!(frame, "[stripmenu] no host handler for {:?}", other);
            false
        }
    }
}

/// A right button released over the strip's **client** part: the tabs, their
/// close crosses, the `+`, the chevron, the `≡`.
pub fn on_right_click(frame: HWND, x: i32, y: i32) {
    if let Some(target) = tab_menu_target(frame, x, y) {
        show_tab_menu(frame, target, x, y);
        return;
    }
    let g = slots(frame);
    if hit(&g, x, y) == Hit::Menu {
        // The `≡` answers to the left button. A right-click on it opening the
        // strip's own menu would put two different menus on one control.
        //
        // **Logged even though nothing happens.** Silence here reads exactly
        // the same as "the right-click never reached the strip at all", and
        // those are a design decision and a routing bug respectively.
        wlogf!(frame, "[strip] right-click on the menu button at {},{}: ignored by design", x, y);
        return;
    }
    show_strip_menu(frame, x, y);
}

/// A right button released over the strip's **caption** part -- the empty
/// space, which answers `HTCAPTION` so the window can be dragged by it and
/// therefore never sees a client mouse message.
///
/// Returns whether it was ours; `false` leaves Windows to show the window's
/// system menu, which is still the right answer everywhere else in the
/// caption.
pub fn on_nc_right_click(frame: HWND, screen_x: i32, screen_y: i32) -> bool {
    let mut pt = POINT { x: screen_x, y: screen_y };
    unsafe {
        let _ = ScreenToClient(frame, &mut pt);
    }
    let sh = strip_h(tabs::scale_of());
    if pt.y < 0 || pt.y >= sh || pt.x < 0 {
        return false;
    }
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return false;
        }
    }
    // The minimise/maximise/close buttons keep their own behaviour.
    if pt.x >= rc.right - crate::shell::reserved_right() {
        return false;
    }
    on_right_click(frame, pt.x, pt.y);
    true
}

// --------------------------------------------------------------- striptest

/// The centre of a tab, and of its close button, in client coordinates.
fn centre_of(frame: HWND, index: usize) -> Option<(i32, i32, i32, i32)> {
    let g = slots(frame);
    let s = g.slots.get(index)?;
    Some((
        (s.rect.left + s.rect.right) / 2,
        (s.rect.top + s.rect.bottom) / 2,
        (s.close.left + s.close.right) / 2,
        (s.close.top + s.close.bottom) / 2,
    ))
}

/// A point on tab `index` that a pointer could actually land on, or why
/// there is not one.
///
/// **Written after the centre-of-the-tab version reported a defect that was
/// not one and passed three tabs it had not tested.** On the real machine,
/// with 17 tabs in an 877px strip:
///
///  * tab 14's centre (855) is underneath the `»` chevron, which `hit` tests
///    before the tabs on purpose -- so the probe called a correct hit test
///    broken, and
///  * tabs 15, 16 and 17 have centres at 915, 975 and 1035, all **past the
///    right edge of the strip**, where no click can ever be delivered.
///    `hit` has no bounds check (it does not need one: Windows never sends a
///    click from outside the window), so `contains` matched and the probe
///    said `ok` three times without testing anything.
///
/// The second is the worse half. A probe that reports a false alarm gets
/// looked at; one that reports `ok` for what it never exercised is how
/// `0 mismatches` comes to mean nothing.
///
/// The point is chosen from **rectangles only** -- the strip's width and the
/// three controls drawn over the tabs -- and never from `hit`'s answer.
/// Asking `hit` where the tab is and then asking `hit` whether that is the
/// tab would agree with any ordering mistake `hit` makes, and the ordering is
/// the whole of what this is testing.
fn reachable_point(frame: HWND, index: usize) -> Result<(i32, i32), String> {
    let g = slots(frame);
    let Some(s) = g.slots.get(index) else {
        return Err("no such slot".to_string());
    };
    let mut rc = RECT::default();
    unsafe {
        if GetClientRect(frame, &mut rc).is_err() {
            return Err("no client rect".to_string());
        }
    }
    let strip_w = (rc.right - rc.left - crate::shell::reserved_right()).max(1);
    let y = (s.rect.top + s.rect.bottom) / 2;
    let covers: Vec<(i32, i32)> = [Some(g.new), g.overflow]
        .into_iter()
        .flatten()
        .map(|r| (r.left, r.right))
        .collect();
    match reachable_span(
        (s.rect.left, s.rect.right),
        g.menu.right,
        strip_w,
        &covers,
    ) {
        Some((a, b)) => Ok(((a + b) / 2, y)),
        None if s.rect.left >= strip_w || s.rect.right <= g.menu.right => Err(format!(
            "scrolled outside the strip (rect {}..{}, strip {}..{})",
            s.rect.left, s.rect.right, g.menu.right, strip_w
        )),
        None => Err(format!(
            "entirely underneath the strip's own controls (rect {}..{}, covers {:?})",
            s.rect.left, s.rect.right, covers
        )),
    }
}

/// The widest run of a tab that is on the strip and not covered by anything
/// drawn over it. **Pure, so the machine's own numbers can be pinned in a
/// test** -- which is the only way the probe's two failure modes get a floor,
/// because the probe itself needs a window.
fn reachable_span(
    tab: (i32, i32),
    inset: i32,
    strip_w: i32,
    covers: &[(i32, i32)],
) -> Option<(i32, i32)> {
    let mut spans = vec![(tab.0.max(inset), tab.1.min(strip_w))];
    for &(cl, cr) in covers {
        let mut next = Vec::new();
        for (a, b) in spans {
            if cl > a {
                next.push((a, b.min(cl)));
            }
            if cr < b {
                next.push((a.max(cr), b));
            }
        }
        spans = next;
    }
    spans
        .into_iter()
        .filter(|(a, b)| b > a)
        .max_by_key(|(a, b)| b - a)
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
        wlogf!(frame, "[strip] synth_click: no slot {}", index);
        return;
    };
    let (x, y) = if on_close { (cx, cy) } else { (tx, ty) };
    wlogf!(frame, "[strip] synth click at ({},{}) on slot {}", x, y, index);
    on_button_down(frame, x, y);
    on_button_up(frame, x, y);
}

/// Drag a tab from one slot to another, through the state machine.
fn synth_drag(frame: HWND, from: usize, to: usize) {
    let (Some((x0, y0, _, _)), Some((x1, _, _, _))) =
        (centre_of(frame, from), centre_of(frame, to))
    else {
        wlogf!(frame, "[strip] synth_drag: missing slots");
        return;
    };
    wlogf!(frame, "[strip] synth drag {} -> {} (x {} -> {})", from, to, x0, x1);
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
        // **The left inset**, checked rather than eyeballed. §3.1 says the
        // first slot starts after the button; `state_line` now prints both
        // `inset=` and `tab0=` so the two can be compared without an image.
        27 => {
            let scale = tabs::scale_of();
            let want = menu_w(scale);
            let got = centre_of(frame, 0)
                .and_then(|_| {
                    let g = slots(frame);
                    g.slots.first().map(|s| s.rect.left)
                })
                .unwrap_or(-1);
            wlogf!(frame, 
                "[strip] inset check: menu_w({}) = {}, first tab left = {} -- {}",
                scale,
                want,
                got,
                if got == want { "ok" } else { "MISMATCH" }
            );
            true
        }
        // **The trap, driven end to end without a mouse.** For every tab in
        // turn: take the coordinates of that tab from the strip's own
        // geometry, put them through the same hit test a right-click uses,
        // and print what came back next to what was asked for.
        //
        // `--striptest`'s whole reason applies here twice over: aiming a real
        // right-click at tab 3 of 18 by hand is exactly the operation that
        // has already produced one false defect on this port.
        28 => {
            let n = tabs::count();
            let (mut ok, mut bad, mut untested) = (0, 0, 0);
            let scroll_was = with_ui(|u| u.scroll);
            for i in 0..n {
                // A tab scrolled out of the strip is not a defect -- it is a
                // tab you would scroll to before right-clicking it. So the
                // probe scrolls to it, exactly as a person would, and only
                // then gives up. Without this, a third of the tabs in an
                // overflowing strip go untested every run.
                let mut how = "";
                let mut at = reachable_point(frame, i);
                if at.is_err() {
                    if let Some((id, _)) = tabs::strip_snapshot().0.get(i).cloned() {
                        scroll_into_view(frame, id);
                        how = " (after scrolling it into view)";
                        at = reachable_point(frame, i);
                    }
                }
                let (x, y) = match at {
                    Ok(p) => p,
                    Err(why) => {
                        untested += 1;
                        // **Not counted as a pass.** This tab was not tested.
                        wlogf!(frame, "[strip] rmb-probe tab {} of {}: UNTESTED -- {}", i + 1, n, why);
                        continue;
                    }
                };
                match tab_menu_target(frame, x, y) {
                    Some(t) if t.index == i => {
                        ok += 1;
                        wlogf!(frame, 
                            "[strip] rmb-probe at ({},{}) -> tab {} of {} (want {}) ok{}",
                            x, y, t.index + 1, t.n, i + 1, how
                        );
                    }
                    Some(t) => {
                        bad += 1;
                        wlogf!(frame, 
                            "[strip] rmb-probe at ({},{}) -> tab {} of {} (want {}) MISMATCH{}",
                            x, y, t.index + 1, t.n, i + 1, how
                        );
                    }
                    None => {
                        bad += 1;
                        wlogf!(frame, 
                            "[strip] rmb-probe at ({},{}) -> no tab (want {}) MISMATCH{}",
                            x, y, i + 1, how
                        );
                    }
                }
            }
            with_ui(|u| u.scroll = scroll_was);
            // **All three counts on one line.** `0 mismatches` alone cannot
            // say whether seventeen tabs passed or four passed and thirteen
            // were never reached, and those are very different readings.
            wlogf!(frame, 
                "[strip] rmb-probe done: {} tabs, {} ok, {} mismatches, {} untested",
                n, ok, bad, untested
            );
            true
        }
        // A point inside the button must **not** resolve to a tab, and a
        // point one pixel past it must. Without this pair, step 28 passes on
        // an implementation that has no inset at all.
        29 => {
            let scale = tabs::scale_of();
            let w = menu_w(scale);
            let y = strip_h(scale) / 2;
            let on_button = tab_menu_target(frame, w / 2, y).is_some();
            let past_button = tab_menu_target(frame, w, y).map(|t| t.index);
            wlogf!(frame, 
                "[strip] inset probe: x={} -> tab? {} (want false); x={} -> tab {:?} (want Some(0)) -- {}",
                w / 2,
                on_button,
                w,
                past_button,
                if !on_button && past_button == Some(0) { "ok" } else { "MISMATCH" }
            );
            true
        }
        // **The two closing directions, driven without a mouse.**
        //
        // Steps 28 and 29 prove the *resolution* is right (right-clicking the
        // Nth tab yields the Nth tab). They cannot prove the *action* is:
        // an implementation that carries the index correctly as far as the
        // menu and then falls back to "the current tab" to do the work passes
        // both. These two steps drive `run_tab_command` on a named tab, which
        // is the same function the menu calls, and print what survived.
        //
        // Two opposite directions on purpose. "Close to the right of tab 3"
        // and "close everything but tab 3" leave different sets, and an
        // implementation that has degenerated to the focused tab cannot get
        // both right -- one direction alone can pass by luck.
        //
        // **What this still does not cover**, and needs a real right-click:
        // that Windows delivers WM_RBUTTONUP / WM_NCRBUTTONUP here, that
        // `TrackPopupMenu` puts a menu on screen, and that the MF_CHECKED
        // flags reached it. The `[tabmenu] ... ticks:` line is the reading
        // for that last one.
        30 => {
            let t = tabs_now();
            if let Some((id, _)) = t.get(2).cloned() {
                // Focus is deliberately left wherever the previous steps put
                // it: if it happened to be this tab, the check would pass on
                // an implementation that ignores `id` entirely.
                wlogf!(frame, "[strip] focus is on tab {} of {}", tabs::active_index() + 1, t.len());
                log_state(frame, "before close-right-of tab 3");
                run_tab_command(frame, id, TabCmd::CloseRight);
            }
            true
        }
        31 => {
            let t = tabs_now();
            if let Some((id, _)) = t.get(1).cloned() {
                wlogf!(frame, "[strip] focus is on tab {} of {}", tabs::active_index() + 1, t.len());
                log_state(frame, "before close-others-than tab 2");
                run_tab_command(frame, id, TabCmd::CloseOthers);
            }
            true
        }
        _ => {
            log_state(frame, "striptest done");
            false
        }
    }
}


#[cfg(test)]
mod menu_inset_tests {
    use super::*;

    /// A strip's geometry without a window, built from the same pure pieces
    /// `slots` uses. Only what the hit test reads is filled in.
    fn geometry(strip_w: i32, scale: f64, n: usize, scroll: i32) -> Geometry {
        let inset = menu_w(scale);
        let sh = strip_h(scale);
        let (tw, _) = layout(strip_w, scale, n, inset);
        let slots = (0..n)
            .map(|i| {
                let x = tab_x(inset, i, tw, scroll);
                Slot {
                    id: TabId(100 + i as u64),
                    rect: RECT { left: x, top: 0, right: x + tw - 1, bottom: sh },
                    close: RECT::default(),
                }
            })
            .collect();
        Geometry {
            slots,
            overflow: None,
            // Parked off the right-hand end so it cannot take a hit meant
            // for a tab; where it really goes is `new_rect`'s business.
            new: RECT { left: strip_w + 1000, top: 0, right: strip_w + 1022, bottom: sh },
            menu: menu_rect(scale, sh),
        }
    }

    /// **The number `s4.md` §3.1 specifies, at the scales Windows reports.**
    ///
    /// Written out rather than computed, because a test that recomputes
    /// `46.0 * scale` the same way the code does agrees with any mistake the
    /// code makes -- including the one this is really guarding: the day
    /// someone "tidies" the button to 44 or 48 to make an icon fit, and the
    /// only visible consequence is that the strip no longer matches the
    /// design it was measured against.
    #[test]
    fn the_button_is_46_logical_pixels_at_every_scale() {
        assert_eq!(menu_w(1.0), 46);
        assert_eq!(menu_w(1.25), 58); // 57.5, rounded
        assert_eq!(menu_w(1.5), 69);
        assert_eq!(menu_w(2.0), 92);
        assert_eq!(menu_w(3.0), 138);
    }

    /// **The acceptance number: the first tab starts at `46 * scale`.**
    ///
    /// This is the whole of the layout half of the block. Before it, `layout`
    /// started tabs at 0 and the button would have been drawn on top of tab
    /// one -- which does not look like a layout bug, it looks like a menu
    /// button that sometimes switches tabs.
    #[test]
    fn the_first_tab_starts_after_the_menu_button() {
        for &scale in &[1.0f64, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0] {
            for &n in &[1usize, 2, 7, 18, 200] {
                let g = geometry(1600, scale, n, 0);
                assert_eq!(
                    g.slots[0].rect.left,
                    menu_w(scale),
                    "scale {scale}, {n} tabs: first tab must start at 46*scale",
                );
                assert_eq!(g.menu.right, menu_w(scale));
            }
        }
    }

    /// The inset comes out of the tabs' share, not out of nowhere: with a
    /// button, the same strip and the same tab count give narrower tabs.
    #[test]
    fn the_inset_is_taken_from_the_tabs_not_added_to_the_strip() {
        let (with_button, _) = layout(1000, 1.0, 5, menu_w(1.0));
        let (without, _) = layout(1000, 1.0, 5, 0);
        assert!(
            with_button < without,
            "5 tabs in 1000px must be narrower once 46px is spent: {with_button} vs {without}",
        );
        assert_eq!(with_button, (1000 - 46) / 5);
    }

    /// **The trap, as a unit test.** Right-clicking the Nth tab must resolve
    /// to the Nth tab, for every N -- and it has to fail if the answer is
    /// "whichever one is current", so nothing here consults an active index.
    #[test]
    fn a_hit_on_the_nth_tab_resolves_to_the_nth_tab() {
        for &scale in &[1.0f64, 1.5, 2.0] {
            for &n in &[1usize, 3, 5, 18] {
                let g = geometry(1600, scale, n, 0);
                for i in 0..n {
                    let s = &g.slots[i];
                    let x = (s.rect.left + s.rect.right) / 2;
                    let y = (s.rect.top + s.rect.bottom) / 2;
                    let h = hit(&g, x, y);
                    assert_eq!(h, Hit::Tab(TabId(100 + i as u64)), "scale {scale}, {n} tabs, i {i}");
                    let index = g.slots.iter().position(|q| q.id == TabId(100 + i as u64));
                    assert_eq!(index, Some(i));
                }
            }
        }
    }

    /// The other half of that: the button's own pixels are not any tab's.
    ///
    /// Without this, the test above passes on a strip with no inset at all --
    /// tab 3 is still tab 3, it is just also underneath the button.
    #[test]
    fn the_button_is_not_a_tab() {
        for &scale in &[1.0f64, 1.5, 2.0] {
            let g = geometry(1600, scale, 5, 0);
            let y = strip_h(scale) / 2;
            for x in [0, 1, menu_w(scale) / 2, menu_w(scale) - 1] {
                assert_eq!(hit(&g, x, y), Hit::Menu, "x={x} at scale {scale}");
            }
            assert_eq!(
                hit(&g, menu_w(scale), y),
                Hit::Tab(TabId(100)),
                "the pixel after the button is the first tab",
            );
        }
    }

    /// A scrolled strip still starts its content after the button: the scroll
    /// offset moves the tabs, it does not move where they are allowed to
    /// begin. Tab 0 slides left under nothing, and the first *visible* tab
    /// must still not be reachable at x < inset.
    #[test]
    fn scrolling_never_puts_a_tab_under_the_button() {
        let scale = 1.0;
        let g = geometry(400, scale, 18, 137);
        let y = strip_h(scale) / 2;
        for x in 0..menu_w(scale) {
            assert_eq!(hit(&g, x, y), Hit::Menu, "x={x} while scrolled");
        }
    }

    /// Every row of the tab menu says what it does, and the three agent rows
    /// read three different state bits. **Copying one getter to all three is
    /// the natural way to write `checked`** and would tick them together.
    #[test]
    fn the_three_agent_rows_do_not_share_a_state_bit() {
        // role 1 = supervisor, 2 = watched; shielded is its own flag.
        assert!(TabCmd::Supervisor.checked(1, false));
        assert!(!TabCmd::Watch.checked(1, false));
        assert!(!TabCmd::Shield.checked(1, false));

        assert!(!TabCmd::Supervisor.checked(2, false));
        assert!(TabCmd::Watch.checked(2, false));
        assert!(!TabCmd::Shield.checked(2, false));

        assert!(!TabCmd::Supervisor.checked(0, true));
        assert!(!TabCmd::Watch.checked(0, true));
        assert!(TabCmd::Shield.checked(0, true));

        // And nothing is ticked when the terminal is nothing in particular.
        for cmd in [TabCmd::Supervisor, TabCmd::Watch, TabCmd::Shield, TabCmd::Close] {
            assert!(!cmd.checked(0, false), "{cmd:?} ticked on a plain terminal");
        }
    }

    /// The colour submenu is inserted at a hard-coded position in the loop
    /// that builds the menu. **That index and the table have to agree**, and
    /// nothing else would notice if they stopped: the submenu would simply
    /// appear in the wrong section, which looks like a design choice.
    #[test]
    fn the_colour_submenu_goes_after_the_second_separator() {
        assert!(TAB_MENU[6].is_none(), "index 6 must be the separator before the agent rows");
        assert_eq!(TAB_MENU[5], Some(TabCmd::Rename), "the colours follow 重命名标签…");
        assert_eq!(TAB_MENU[7], Some(TabCmd::Supervisor));
        assert_eq!(TAB_MENU.iter().filter(|r| r.is_none()).count(), 2);
    }

    /// **The reading that came off the real machine, pinned.**
    ///
    /// 17 tabs, 60px wide, 46px inset, an 877px strip, with the `+` at
    /// 833..855 and the `»` at 855..877. The first probe took each tab's
    /// geometric centre and got two things wrong at once, and this test is
    /// both of them.
    #[test]
    fn the_probe_point_is_on_the_strip_and_out_from_under_the_controls() {
        let (inset, tw, strip_w) = (46, 60, 877);
        let covers = [(833, 855), (855, 877)];
        let rect = |i: i32| (inset + i * tw, inset + i * tw + tw - 1);

        // Tab 14 (index 13): its centre is 855, which is the chevron. The
        // hit test is right to answer `Overflow` there -- the chevron is
        // drawn on top -- so the probe must aim somewhere else on the tab
        // rather than call a correct hit test broken.
        let (a, b) = reachable_span(rect(13), inset, strip_w, &covers)
            .expect("tab 14 has 826..833 showing and must be reachable");
        let x = (a + b) / 2;
        assert!(rect(13).0 <= x && x < rect(13).1, "the point must be on tab 14");
        for (cl, cr) in covers {
            assert!(!(cl..cr).contains(&x), "the point must not be under {cl}..{cr}");
        }
        assert!(x < strip_w, "and it must be somewhere a click can land");

        // Tabs 15, 16 and 17 are entirely past the strip's right edge. The
        // first probe called all three `ok`: `hit` has no bounds check, so
        // `contains` matched coordinates no click can ever carry. They have
        // to come back as "no point", which the caller reports as UNTESTED.
        for i in 14..17 {
            assert_eq!(
                reachable_span(rect(i), inset, strip_w, &covers),
                None,
                "tab {} starts at {} which is past the strip's {strip_w}",
                i + 1,
                rect(i).0,
            );
        }

        // And the ordinary case is unaffected: tab 13 is clear of everything.
        assert!(reachable_span(rect(12), inset, strip_w, &covers).is_some());
    }

    /// A tab hidden behind the button is not reachable either, and must not
    /// be silently counted as a pass.
    #[test]
    fn a_tab_scrolled_under_the_menu_button_has_no_probe_point() {
        assert_eq!(reachable_span((-60, -1), 46, 877, &[]), None);
        // Half under it: the visible half is the answer, not the whole tab.
        let (a, b) = reachable_span((20, 80), 46, 877, &[]).unwrap();
        assert_eq!((a, b), (46, 80));
    }

    /// The three id blocks cannot overlap each other, `ctxmenu.rs`'s block,
    /// or anything Windows sends. An overlap is a menu row that runs a
    /// different row's action -- and it compiles.
    #[test]
    fn the_id_blocks_do_not_overlap() {
        assert!(TAB_ID_BASE > 0x4000 + 64, "must clear ctxmenu.rs's block");
        assert!(TAB_ID_BASE + TAB_MENU.len() < TAB_COLOR_BASE);
        assert!(TAB_COLOR_BASE + TAB_COLORS.len() < STRIP_ID_BASE);
        assert!(STRIP_ID_BASE + STRIP_MENU.len() < 0xF000);
    }

    /// Nine colours plus none, matching `TerminalTabColor.swift`. `s4.md`
    /// §3.3 says eight; the source is the source.
    #[test]
    fn the_palette_matches_the_macos_one() {
        assert_eq!(TAB_COLORS.len(), 10);
        assert_eq!(TAB_COLORS[0].1, 0, "index 0 is 'no colour' and draws nothing");
        for (name, c) in &TAB_COLORS[1..] {
            assert_ne!(*c, 0, "{name} would draw as no colour at all");
        }
    }

    /// Every action string this file hands to the core has a binding's shape.
    /// A typo returns `false` from `binding_action` and does nothing else,
    /// so the cheap check is worth having next to the real one.
    #[test]
    fn the_core_bound_rows_have_binding_shaped_names() {
        for cmd in [TabCmd::Supervisor, TabCmd::Watch, TabCmd::Shield] {
            let a = cmd.action();
            assert!(!a.contains(' '), "binding names have no spaces: {a}");
            assert!(a.chars().all(|c| c.is_ascii_lowercase() || c == '_' || c == ':'));
        }
        for (label, action, _) in STRIP_MENU {
            assert!(!action.is_empty(), "{label} has no action");
            assert!(!action.contains(' '), "action names have no spaces: {action}");
            // A host row must be marked as one. An unmarked name goes to
            // `binding_action`, which does not have it, and returns false
            // without saying why -- the exact silence this table avoids.
            if action.starts_with("host:") {
                continue;
            }
            assert!(
                action.chars().all(|c| c.is_ascii_lowercase() || c == '_' || c == ':'),
                "unexpected characters in the core action {action}",
            );
        }
    }
}

#[cfg(test)]
mod close_affordance_tests {
    use super::{layout, tab_shows_close, TAB_MIN_W};

    /// **The close cross must never disappear, at any width the layout can
    /// produce, at any DPI.**
    ///
    /// This is the one control on the strip whose absence loses data: someone
    /// who cannot find how to close a tab reaches for the window's ×, and that
    /// takes every other tab with it.
    ///
    /// It holds today only because `TAB_MIN_W` (60) is larger than the four
    /// close-widths the cross needs (56) -- **a seven percent margin between
    /// two constants that no code connects.** Narrowing `TAB_MIN_W` as part of
    /// some future overflow change would remove the cross silently, and the
    /// symptom would be a person closing the wrong thing. This test is the
    /// connection.
    #[test]
    fn the_close_cross_survives_the_narrowest_tab_at_every_scale() {
        // 1.0 is the floor Windows reports; the rest are the usual ladder,
        // plus a deliberately absurd one.
        for &scale in &[1.0f64, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0] {
            // The narrowest tab the layout will ever hand out: far too many
            // tabs for the strip.
            // No inset here on purpose: this test is about the close
            // cross against `TAB_MIN_W`, and the menu button is a separate
            // claim with its own tests below.
            let (tw, overflowing) = layout(400, scale, 200, 0);
            assert!(overflowing, "200 tabs in 400px must overflow (scale {scale})");
            assert!(
                tab_shows_close(tw, scale),
                "at scale {scale} the narrowest tab is {tw}px and loses its close cross",
            );
        }
    }

    /// The margin itself, stated once so a future edit sees the number it is
    /// spending.
    #[test]
    fn the_margin_between_the_two_constants_is_named() {
        assert!(
            TAB_MIN_W > 56,
            "TAB_MIN_W must stay above four close-widths (56) or the cross vanishes"
        );
    }
}
