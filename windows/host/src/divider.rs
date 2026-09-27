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
/// How wide a divider can be **grabbed**: the width of its window. Unchanged
/// by #19, and it must stay that way -- see [`LINE`].
const THICKNESS: i32 = 6;
/// How wide a divider is **seen**: the line drawn in the middle of the window.
///
/// **Why two numbers (#19).** Both used to be `THICKNESS`: `WM_PAINT` filled
/// the whole window, so the line was six pixels wide where macOS draws one
/// (`splitterVisibleSize`), and people said it looked heavy. Making the window
/// thinner would have fixed the look and made the divider nearly impossible
/// to grab, because on Win32 the window *is* the hit area. So the window stays
/// `THICKNESS` wide and only the drawing changes: the middle `LINE` pixels get
/// the divider colour and the rest gets the terminal's background, so the
/// divider looks one pixel wide and still catches the pointer six pixels wide.
/// (macOS's hit area is 7: `visibleSize + invisibleSize`.)
///
/// The panes cannot draw that background themselves: they are
/// `WS_CLIPSIBLINGS`, so nothing under a divider window is ever theirs to
/// paint. Leaving those pixels unpainted would show whatever was there last.
///
/// **Where the illusion breaks**, knowingly: with a non-default
/// `unfocused-split-fill` the unfocused side's background is not `background`
/// (with the default, the dimming layer *is* `background`, so it matches); a
/// background that is not one flat colour is not matched; and the outer
/// pixels of the column right at the seam stay covered, as they were under
/// the old six-pixel bar.
const LINE: i32 = 1;
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
    /// Whether this drag has already said why it is going nowhere.
    ///
    /// **A drag is one line, not one line per `WM_MOUSEMOVE`.** The reasons
    /// `drag_to` gives up are all sticky -- a window that is gone stays gone
    /// for the rest of the drag -- so the first move to hit one says
    /// everything the whole drag would, and printing it per move would be
    /// thousands of lines a second. Cleared when a drag starts.
    ///
    /// ⚠️ **So this line proves a stuck drag happened, never how long it
    /// went on for.** Do not count these to measure anything.
    complained: bool,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

static REGISTERED: AtomicBool = AtomicBool::new(false);

fn scaled_thickness(frame: HWND) -> i32 {
    let dpi = unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(frame) }.max(96) as i32;
    (THICKNESS * dpi / 96).max(3)
}

/// `LINE` in device pixels at `dpi`: 1 at 100% and 150%, 2 at 200%. Never
/// wider than the window (`across`, its narrow side) it is drawn in.
fn line_px(dpi: i32, across: i32) -> i32 {
    (LINE * dpi.max(96) / 96).max(1).min(across.max(1))
}

/// The part of a divider window's client rect that is drawn as the line: the
/// middle `line_px` of its narrow side, whichever way the divider runs. The
/// rest of `rc` is the hit area painted as background (see `LINE`).
fn line_rect(rc: RECT, dpi: i32) -> RECT {
    let (w, h) = (rc.right - rc.left, rc.bottom - rc.top);
    if w <= h {
        let l = line_px(dpi, w);
        let x = rc.left + (w - l) / 2;
        RECT { left: x, top: rc.top, right: x + l, bottom: rc.bottom }
    } else {
        let l = line_px(dpi, h);
        let y = rc.top + (h - l) / 2;
        RECT { left: rc.left, top: y, right: rc.right, bottom: y + l }
    }
}

fn dpi_of(hwnd: HWND) -> i32 {
    unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(hwnd) }.max(96) as i32
}

/// The terminal's `background`, read when it is painted so a reloaded config
/// is followed. `None` when it cannot be read; the caller then paints the
/// whole window the divider colour, which is the old look, not a hole.
fn terminal_background() -> Option<COLORREF> {
    let cfg = crate::config_handle();
    if cfg.is_null() {
        return None;
    }
    let mut c = crate::ffi::ConfigColor::default();
    let key = "background";
    let ok = unsafe {
        (crate::api().config_get)(cfg, &mut c as *mut _ as *mut std::ffi::c_void, key.as_ptr(), key.len())
    };
    ok.then(|| COLORREF(c.r as u32 | (c.g as u32) << 8 | (c.b as u32) << 16))
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
        // **The scale is read before the guard is taken**, not out of it:
        // `scale_of` locks, and taking the lock while already holding it is
        // the five-second hang this file's header is about.
        let sh = crate::strip::strip_h(tabs::scale_of(frame));
        let Some(bounds) = tabs::content_bounds(frame, sh) else {
            return;
        };
        let Some(win) = tabs::window(frame) else {
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
        // The two widths #19 is about, read back from the windows rather than
        // restated from the constants: how wide the first divider can be
        // grabbed (its window) and how wide it is drawn.
        let widths = st.pool.first().filter(|_| !wanted.is_empty()).map(|d| {
            let mut wr = RECT::default();
            let _ = unsafe { GetWindowRect(d.hwnd, &mut wr) };
            let hit = match d.axis {
                Axis::Horizontal => wr.right - wr.left,
                Axis::Vertical => wr.bottom - wr.top,
            };
            (hit, line_px(dpi_of(d.hwnd), hit))
        });
        match widths {
            Some((hit, line)) => wlogf!(frame,
                "[div] sync: {} dividers for {} panes, zoomed={}, hit={}px line={}px",
                wanted.len(),
                panes,
                zoomed,
                hit,
                line
            ),
            None => wlogf!(frame,
                "[div] sync: {} dividers for {} panes, zoomed={}",
                wanted.len(),
                panes,
                zoomed
            ),
        }
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

/// Put the divider being dragged where the pointer is.
///
/// **Every way out of here that is not a resize is announced**, at most once
/// per drag (see `State::complained`). The `Err` arm below already said why
/// in its own words -- "a divider that silently stops responding is
/// indistinguishable from a frozen app" -- and every early exit above it had
/// exactly the same consequence without the same treatment.
fn drag_to(frame: HWND, idx: usize) {
    // One place, so a new exit cannot forget the gate.
    let say = |what: &str| {
        let first = STATE.with(|c| {
            let mut st = c.borrow_mut();
            let first = !st.complained;
            st.complained = true;
            first
        });
        // absence: depends -- one line per drag, not one per pointer
        // message, so a drag that goes nowhere for the same reason a hundred
        // times says so once. Within one drag, therefore, a second silent
        // exit leaves no trace at all: the count of these lines is a count of
        // drags, never of refusals.
        if first {
            wlogf!(frame, "[div] drag {} is going nowhere: {}", idx, what);
        }
    };

    let Some(p) = pointer_in_frame(frame) else {
        say("the pointer is not in this frame");
        return;
    };

    let (path, axis) = STATE.with(|c| {
        let st = c.borrow();
        st.pool
            .get(idx)
            .map(|d| (d.path.clone(), d.axis))
            .unwrap_or((Vec::new(), Axis::Horizontal))
    });
    if path.is_empty() && idx > 0 {
        say("this divider has no path in the tree");
        return;
    }

    let position = match axis {
        Axis::Horizontal => p.x as f64,
        Axis::Vertical => p.y as f64,
    };

    // Compute the new tree under the lock, drop it, then lay out. `layout`
    // calls `SetWindowPos`, which re-enters this thread.
    let changed = {
        // Same rule as `sync`: `scale_of` takes the lock, so it runs before
        // the guard below rather than inside it.
        let sh = crate::strip::strip_h(tabs::scale_of(frame));
        let Some(bounds) = tabs::content_bounds(frame, sh) else {
            // `content_bounds` writes its own line about the geometry; this
            // one says which action that geometry killed.
            say("that window has no content area");
            return;
        };
        let Some(mut win) = tabs::window(frame) else {
            say("that window is gone");
            return;
        };
        let active = win.active;
        let Some(tab) = win.tabs.get_mut(active) else {
            say("that window has no active tab");
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
                    STATE.with(|c| {
                        let mut st = c.borrow_mut();
                        st.dragging = Some(i);
                        // A new drag gets a new voice; see `complained`.
                        st.complained = false;
                    });
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
                    let line_col = COLORREF(if hot { COL_HOT } else { COL });

                    // See `LINE`: the whole window is the hit area, only the
                    // middle of it is the line.
                    let line_rc = match terminal_background() {
                        Some(bg) => {
                            let back = CreateSolidBrush(bg);
                            FillRect(hdc, &rc, back);
                            let _ = DeleteObject(back.into());
                            line_rect(rc, dpi_of(hwnd))
                        }
                        None => rc,
                    };
                    let brush = CreateSolidBrush(line_col);
                    FillRect(hdc, &line_rc, brush);
                    let _ = DeleteObject(brush.into());
                    let _ = EndPaint(hwnd, &ps);
                }
                LRESULT(0)
            }

            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(l: i32, t: i32, rr: i32, b: i32) -> RECT {
        RECT { left: l, top: t, right: rr, bottom: b }
    }

    #[test]
    fn a_six_pixel_divider_is_drawn_one_pixel_wide_in_its_middle() {
        // A left|right split at 100%: window 6 wide, line 1 wide, centred.
        let line = line_rect(r(0, 0, 6, 400), 96);
        assert_eq!((line.left, line.right), (2, 3));
        assert_eq!((line.top, line.bottom), (0, 400));
    }

    #[test]
    fn the_line_follows_the_divider_when_it_runs_across() {
        // A top/bottom split: the narrow side is the height.
        let line = line_rect(r(0, 0, 400, 6), 96);
        assert_eq!((line.top, line.bottom), (2, 3));
        assert_eq!((line.left, line.right), (0, 400));
    }

    #[test]
    fn the_line_scales_with_dpi_but_stays_thin() {
        // 150%: window 9 (THICKNESS * 144 / 96), line still 1.
        let at150 = line_rect(r(0, 0, 9, 100), 144);
        assert_eq!(at150.right - at150.left, 1);
        // 200%: window 12, line 2.
        let at200 = line_rect(r(0, 0, 12, 100), 192);
        assert_eq!(at200.right - at200.left, 2);
        assert_eq!(at200.left, 5);
    }

    #[test]
    fn the_hit_area_is_not_what_gets_narrower() {
        // The fix must thin what is drawn and nothing else: the window the
        // line sits in is still THICKNESS wide at 100%.
        assert_eq!(THICKNESS * 96 / 96, 6);
        let rc = r(0, 0, THICKNESS, 300);
        let line = line_rect(rc, 96);
        assert!(line.right - line.left < rc.right - rc.left);
    }
}
