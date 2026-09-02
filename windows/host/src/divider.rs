//! The draggable boundaries between panes.
//!
//! **Why the dividers are windows rather than paint.** A divider needs three
//! things Win32 gives a window for free and gives a painted rectangle not at
//! all: a cursor that changes when the pointer is over it (`WM_SETCURSOR`),
//! a hit region the system tests before anyone writes an `if`, and mouse
//! capture during a drag. Painting them on the frame would mean re-deriving
//! all three from rectangles, in a file the tab strip already owns.
//!
//! **Why they overlap the panes instead of sitting in a gap.** The tree tiles
//! its bounds exactly -- `layout` leaves no gutter, and the area-conservation
//! test says so. Rather than teach the model about a presentation width, the
//! dividers are siblings drawn *over* the seam. A few pixels of each GL
//! surface end up underneath, which is what a divider looks like anyway.
//! **No pixel of this file enters the tree**, the same rule the strip follows.
//!
//! **Why the pointer is read with `GetCursorPos` and not from `lParam`.**
//! The packed halves of `lParam` are signed, and a drag that leaves the window
//! to the left produces a negative x that reads as ~65000 if it is taken as
//! unsigned -- a real bug the tab strip hit and fixed by remembering to cast.
//! `GetCursorPos` hands over a `POINT` of two `i32`s, so **the hazard is gone
//! by construction rather than by remembering**. It also gives screen
//! coordinates, which is what a capture-based drag wants: the pointer may be
//! well outside the divider by then.
//!
//! **Why the drag sends an absolute position, not a delta.** See
//! `Tree::resize_at`. Deltas drift when a message is coalesced and never
//! recover; a position re-measures every time.

use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, Ordering};

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
// `WM_MOUSELEAVE` lives in `Win32_UI_Controls`, not `WindowsAndMessaging`.
// Without this import Rust reads it as a *binding pattern* in the match below
// -- a catch-all name that swallows every message after it. The build stays
// green; the divider simply never paints and never responds. The compiler
// does say `unreachable pattern`, which is the only reason this was caught.
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    ReleaseCapture, SetCapture, TrackMouseEvent, TME_LEAVE, TRACKMOUSEEVENT,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_split_tree::{Axis, Branch};

use crate::{logf, plogf, wlogf};

/// Divider thickness in unscaled pixels. Wide enough to grab, narrow enough
/// not to eat a column of text.
const THICKNESS: i32 = 6;
const COL: u32 = 0x00141312;
const COL_HOT: u32 = 0x00605f5d;

/// One divider window and what it stands for.
struct Div {
    hwnd: HWND,
    path: Vec<Branch>,
    axis: Axis,
}

#[derive(Default)]
struct State {
    /// A pool: windows are reused across layouts and hidden when a layout
    /// needs fewer, because creating and destroying windows during a drag is
    /// how a divider disappears out from under the pointer.
    pool: Vec<Div>,
    /// Index into `pool` of the divider being dragged.
    dragging: Option<usize>,
    hot: Option<usize>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

static REGISTERED: AtomicBool = AtomicBool::new(false);

fn scaled_thickness(frame: HWND) -> i32 {
    let dpi = unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(frame) }.max(96) as i32;
    (THICKNESS * dpi / 96).max(3)
}

// ------------------------------------------------------------------ setup

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(div_proc),
            hInstance: hinst,
            // No class cursor: `WM_SETCURSOR` picks one per divider, because
            // a horizontal split wants the east-west arrow and a vertical one
            // wants north-south.
            hCursor: HCURSOR(std::ptr::null_mut()),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            lpszClassName: w!("PolterDivider"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            // process-wide: registering the divider window class, once per process
            plogf!("[div] RegisterClassExW failed");
            return;
        }
        REGISTERED.store(true, Ordering::Release);
        // process-wide: the divider class is registered; no window owns it
        plogf!("[div] ready");
    }
}

// ------------------------------------------------------------------- sync

/// Put a divider window on every boundary of the active tab's tree.
///
/// Called after anything that changes the layout. **Never call this while
/// holding `tabs::STATE`**: it creates and moves windows, and `SetWindowPos`
/// sends `WM_SIZE` back into this thread, which takes that lock again. That
/// is the re-entrant deadlock the tab layout already paid for once.
pub fn sync(frame: HWND) {
    if !REGISTERED.load(Ordering::Acquire) || frame.0.is_null() {
        return;
    }

    // Pure read under the lock; every window call happens after it is dropped.
    let (wanted, panes, zoomed): (Vec<(Vec<Branch>, Axis, RECT)>, usize, bool) = {
        let st = tabs::state();
        let sh = crate::strip::strip_h(st.scale);
        let Some(bounds) = tabs::content_bounds(frame, sh) else {
            return;
        };
        let Some(win) = st.win(frame) else {
            return;
        };
        let Some(tab) = win.tabs.get(win.active) else {
            return;
        };
        // Recorded so the log can carry the whole claim: for a tree of P
        // panes with nothing zoomed, there are exactly P-1 boundaries. Two
        // numbers on one line is a check anyone can do; "N dividers" alone
        // needs a second source to mean anything.
        let panes = tab.tree.panes().len();
        let zoomed = tab.tree.zoomed().is_some();
        let t = scaled_thickness(frame) as f64;
        let rects = tab.tree
            .dividers(bounds, t)
            .into_iter()
            .map(|d| {
                (
                    d.path,
                    d.axis,
                    RECT {
                        left: d.rect.x as i32,
                        top: d.rect.y as i32,
                        right: (d.rect.x + d.rect.w) as i32,
                        bottom: (d.rect.y + d.rect.h) as i32,
                    },
                )
            })
            .collect();
        (rects, panes, zoomed)
    };

    let hinst = unsafe {
        windows::Win32::System::LibraryLoader::GetModuleHandleW(None)
            .map(Into::into)
            .unwrap_or_default()
    };

    STATE.with(|c| {
        let mut st = c.borrow_mut();

        // Grow the pool to fit.
        while st.pool.len() < wanted.len() {
            let hwnd = unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    w!("PolterDivider"),
                    None,
                    WS_CHILD | WS_CLIPSIBLINGS,
                    0,
                    0,
                    0,
                    0,
                    Some(frame),
                    None,
                    Some(hinst),
                    None,
                )
            };
            match hwnd {
                Ok(h) => st.pool.push(Div {
                    hwnd: h,
                    path: Vec::new(),
                    axis: Axis::Horizontal,
                }),
                Err(e) => {
                    wlogf!(frame, "[div] CreateWindowExW failed: {e:?}");
                    return;
                }
            }
        }

        for (i, (path, axis, rc)) in wanted.iter().enumerate() {
            let d = &mut st.pool[i];
            d.path = path.clone();
            d.axis = *axis;
            unsafe {
                // `HWND_TOP` so a divider sits over the panes it straddles.
                let _ = SetWindowPos(
                    d.hwnd,
                    Some(HWND_TOP),
                    rc.left,
                    rc.top,
                    rc.right - rc.left,
                    rc.bottom - rc.top,
                    SWP_SHOWWINDOW | SWP_NOACTIVATE,
                );
            }
        }
        // Hide the leftovers rather than destroy them.
        for d in st.pool.iter().skip(wanted.len()) {
            unsafe {
                let _ = ShowWindow(d.hwnd, SW_HIDE);
            }
        }
        wlogf!(frame, 
            "[div] sync: {} dividers for {} panes, zoomed={}",
            wanted.len(),
            panes,
            zoomed
        );
    });
}

use crate::tabs;

// ------------------------------------------------------------------- drag

/// The pointer in frame client coordinates -- the same space `content_bounds`
/// and therefore `dividers()` use.
fn pointer_in_frame(frame: HWND) -> Option<POINT> {
    let mut p = POINT::default();
    unsafe {
        if GetCursorPos(&mut p).is_err() {
            return None;
        }
        if ScreenToClient(frame, &mut p).as_bool() {
            Some(p)
        } else {
            None
        }
    }
}

fn drag_to(frame: HWND, idx: usize) {
    let Some(p) = pointer_in_frame(frame) else { return };

    let (path, axis) = STATE.with(|c| {
        let st = c.borrow();
        st.pool
            .get(idx)
            .map(|d| (d.path.clone(), d.axis))
            .unwrap_or((Vec::new(), Axis::Horizontal))
    });
    if path.is_empty() && idx > 0 {
        return;
    }

    let position = match axis {
        Axis::Horizontal => p.x as f64,
        Axis::Vertical => p.y as f64,
    };

    // Compute the new tree under the lock, drop it, then lay out. `layout`
    // calls `SetWindowPos`, which re-enters this thread.
    let changed = {
        let mut st = tabs::state();
        let sh = crate::strip::strip_h(st.scale);
        let Some(bounds) = tabs::content_bounds(frame, sh) else {
            return;
        };
        let Some(win) = st.win_mut(frame) else {
            return;
        };
        let active = win.active;
        let Some(tab) = win.tabs.get_mut(active) else {
            return;
        };
        match tab.tree.resize_at(&path, position, bounds) {
            Ok(next) => {
                let same = next == tab.tree;
                tab.tree = next;
                !same
            }
            Err(e) => {
                // Not fatal: the divider may belong to a tree that changed
                // under the drag. Logged because a divider that silently
                // stops responding is indistinguishable from a frozen app.
                wlogf!(frame, "[div] resize_at({:?}) failed: {:?}", path, e);
                false
            }
        }
    };

    if changed {
        // `layout` syncs the dividers itself; calling it here as well would be
        // a second place that has to stay in agreement with the first.
        tabs::layout(frame);
    }
}

// ------------------------------------------------------------- window proc

fn index_of(hwnd: HWND) -> Option<usize> {
    STATE.with(|c| c.borrow().pool.iter().position(|d| d.hwnd == hwnd))
}

extern "system" fn div_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let frame = GetParent(hwnd).unwrap_or_default();
        match msg {
            WM_SETCURSOR => {
                let axis = index_of(hwnd)
                    .and_then(|i| STATE.with(|c| c.borrow().pool.get(i).map(|d| d.axis)));
                let id = match axis {
                    Some(Axis::Vertical) => IDC_SIZENS,
                    _ => IDC_SIZEWE,
                };
                if let Ok(cur) = LoadCursorW(None, id) {
                    SetCursor(Some(cur));
                }
                LRESULT(1)
            }

            WM_LBUTTONDOWN => {
                if let Some(i) = index_of(hwnd) {
                    STATE.with(|c| c.borrow_mut().dragging = Some(i));
                    SetCapture(hwnd);
                    logf!("[div] drag start {}", i);
                }
                LRESULT(0)
            }

            WM_MOUSEMOVE => {
                let dragging = STATE.with(|c| c.borrow().dragging);
                match dragging {
                    Some(i) => drag_to(frame, i),
                    None => {
                        // Hover feedback. Tracked so the divider un-highlights
                        // when the pointer leaves; without this it stays lit
                        // for the rest of the session.
                        let i = index_of(hwnd);
                        let was = STATE.with(|c| {
                            let mut st = c.borrow_mut();
                            std::mem::replace(&mut st.hot, i)
                        });
                        if was != i {
                            let _ = InvalidateRect(Some(hwnd), None, true);
                        }
                        let mut tme = TRACKMOUSEEVENT {
                            cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                            dwFlags: TME_LEAVE,
                            hwndTrack: hwnd,
                            dwHoverTime: 0,
                        };
                        let _ = TrackMouseEvent(&mut tme);
                    }
                }
                LRESULT(0)
            }

            WM_MOUSELEAVE => {
                STATE.with(|c| c.borrow_mut().hot = None);
                let _ = InvalidateRect(Some(hwnd), None, true);
                LRESULT(0)
            }

            WM_LBUTTONUP => {
                let was = STATE.with(|c| c.borrow_mut().dragging.take());
                if was.is_some() {
                    let _ = ReleaseCapture();
                    logf!("[div] drag end");
                }
                LRESULT(0)
            }

            // A drag that is cancelled (Alt+Tab, a modal dialog) must not
            // leave `dragging` set: the next stray mouse move would then move
            // a divider nobody is holding.
            WM_CAPTURECHANGED => {
                STATE.with(|c| c.borrow_mut().dragging = None);
                LRESULT(0)
            }

            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(hwnd, &mut rc);
                    let hot = index_of(hwnd) == STATE.with(|c| c.borrow().hot);
                    let brush = CreateSolidBrush(COLORREF(if hot { COL_HOT } else { COL }));
                    FillRect(hdc, &rc, brush);
                    let _ = DeleteObject(brush.into());
                    let _ = EndPaint(hwnd, &ps);
                }
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}
