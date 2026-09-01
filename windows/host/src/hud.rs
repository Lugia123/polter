//! Two non-interactive signs over the terminal: the grid size while you resize
//! it, and a badge when the surface is read-only.
//!
//! **Why they share one file and one window class.** Both are the same shape —
//! a small always-on-top label that never takes focus, driven entirely by
//! something the host already knows. Neither has an input field, so neither
//! touches `overlay.rs`'s focus contract. Splitting them would duplicate the
//! window, the font, and the paint path three ways (`keyseq.rs` is the third).
//!
//! **Where each gets its truth:**
//!
//! - **Grid size** — the host's own. Columns and rows are the active surface's
//!   client rectangle divided by the cell size the core published through
//!   `cell_size`, read back with `ime_cell_size()`. Nothing is guessed and
//!   nothing is stored: if the numbers on screen are wrong, either the client
//!   rect or the cell size is wrong, and both are checkable.
//! - **Read-only** — the core's, through `GHOSTTY_ACTION_READONLY`. The host
//!   never decides this and never remembers it across a config reload; it
//!   paints the last thing the core said.
//!
//! **Why the size sign hides on a timer rather than on `WM_EXITSIZEMOVE`.**
//! `WM_EXITSIZEMOVE` only arrives for a drag of the window frame. A resize
//! from `SetWindowPos` (the tab strip's layout, a maximise, the self-test)
//! never sends it, so a sign that waited for it would stay on screen forever
//! after a programmatic resize. **One timer covers every way a resize can
//! happen; the message covers one of them.**

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::logf;

const WM_HUD_SYNC: u32 = WM_APP + 7;
/// Timer id for "the resize is over".
const TIMER_SIZE_OFF: usize = 1;
/// How long the grid size stays after the last resize message.
const SIZE_LINGER_MS: u32 = 900;

const HEIGHT: i32 = 30;
const COL_BG: u32 = 0x00403f3d;
const COL_TEXT: u32 = 0x00ffffff;
const COL_RO_BG: u32 = 0x00306090; // BGR: amber, for the read-only badge

static HWND_SIZE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_RO: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
/// Written from `action_cb` on whichever thread the core is on. A single bool
/// needs no inbox and no lock.
static READONLY: AtomicBool = AtomicBool::new(false);

struct State {
    font: HFONT,
    /// Last measured grid, painted by the size sign.
    cols: i32,
    rows: i32,
    size_visible: bool,
    ro_visible: bool,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

// ------------------------------------------------------- from `action_cb`

/// `GHOSTTY_ACTION_READONLY`. **Safe from any thread.**
pub fn on_readonly(on: bool) {
    READONLY.store(on, Ordering::Release);
    let h = HWND_RO.load(Ordering::Acquire);
    if !h.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
    }
}

/// The frame was resized. **Main thread only** -- it is called from the frame's
/// own window procedure.
pub fn on_frame_resized() {
    let h = HWND_SIZE.load(Ordering::Acquire);
    if h.is_null() {
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
}

/// Columns and rows of the active surface, or `None` if either input is not
/// available yet. **Returns `None` rather than a plausible-looking zero**: a
/// sign that says `0x0` looks like a measurement, and this one would be the
/// absence of one.
fn grid() -> Option<(i32, i32, i32, i32, i32, i32)> {
    let hwnd = crate::tabs::active_hwnd();
    if hwnd.0.is_null() {
        return None;
    }
    let mut rc = RECT::default();
    if unsafe { GetClientRect(hwnd, &mut rc) }.is_err() {
        return None;
    }
    let (cw, ch) = crate::ime_cell_size();
    // `ime_cell_size` clamps to 1 to stay divisible; that is exactly the value
    // that means "the core has not sent cell_size yet".
    if cw <= 1 || ch <= 1 {
        return None;
    }
    let (w, h) = (rc.right - rc.left, rc.bottom - rc.top);
    if w <= 0 || h <= 0 {
        return None;
    }
    Some((w / cw, h / ch, w, h, cw, ch))
}

// ------------------------------------------------------------------ setup

fn make_window(hinst: windows::Win32::Foundation::HINSTANCE, class: windows::core::PCWSTR) -> HWND {
    unsafe {
        match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            class,
            w!("Polter"),
            WS_POPUP,
            0,
            0,
            160,
            HEIGHT,
            None,
            None,
            Some(hinst),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                logf!("[hud] CreateWindowExW failed: {e:?}");
                HWND(std::ptr::null_mut())
            }
        }
    }
}

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        for (proc_fn, class) in [
            (size_proc as WndprocFn, w!("PolterHudSize")),
            (ro_proc as WndprocFn, w!("PolterHudReadonly")),
        ] {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                style: CS_DROPSHADOW,
                lpfnWndProc: Some(proc_fn),
                hInstance: hinst,
                hbrBackground: HBRUSH(std::ptr::null_mut()),
                lpszClassName: class,
                ..Default::default()
            };
            if RegisterClassExW(&wc) == 0 {
                logf!("[hud] RegisterClassExW failed");
                return;
            }
        }

        let hsize = make_window(hinst, w!("PolterHudSize"));
        let hro = make_window(hinst, w!("PolterHudReadonly"));
        if hsize.0.is_null() || hro.0.is_null() {
            return;
        }

        let dpi = GetDpiForWindow(hsize).max(96) as i32;
        let font = CreateFontW(
            -(14 * dpi / 96),
            0,
            0,
            0,
            FW_SEMIBOLD.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            w!("Segoe UI"),
        );
        STATE.with(|c| {
            *c.borrow_mut() = Some(State {
                font,
                cols: 0,
                rows: 0,
                size_visible: false,
                ro_visible: false,
            });
        });
        HWND_SIZE.store(hsize.0, Ordering::Release);
        HWND_RO.store(hro.0, Ordering::Release);
        logf!("[hud] ready");
    }
}

type WndprocFn = unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT;

// ------------------------------------------------------------- size sign

fn show_size(me: HWND) {
    let Some((cols, rows, px_w, px_h, cell_w, cell_h)) = grid() else {
        // No measurement, no sign. Logged because "the size overlay never
        // appeared" and "the core never sent cell_size" look identical on
        // screen and are different bugs.
        logf!("[hud] size: no measurement (cell_size or client rect missing)");
        return;
    };

    let changed = STATE.with(|c| {
        c.borrow_mut()
            .as_mut()
            .map(|st| {
                let ch = st.cols != cols || st.rows != rows || !st.size_visible;
                st.cols = cols;
                st.rows = rows;
                st.size_visible = true;
                ch
            })
            .unwrap_or(false)
    });

    unsafe {
        let frame = crate::tabs::frame_hwnd();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let dpi = GetDpiForWindow(me).max(96) as i32;
        let sc = |v: i32| v * dpi / 96;
        let (w, h) = (sc(120), sc(HEIGHT));
        // Centred on the frame, the way every terminal shows this.
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
        let _ = SetWindowPos(
            me,
            Some(HWND_TOPMOST),
            x,
            y,
            w,
            h,
            SWP_SHOWWINDOW | SWP_NOACTIVATE,
        );
        let _ = InvalidateRect(Some(me), None, true);
        // Restart the linger every time, so a continuous drag keeps it up.
        let _ = SetTimer(Some(me), TIMER_SIZE_OFF, SIZE_LINGER_MS, None);
    }
    if changed {
        // **Every number this claim depends on is on the same line.**
        // The obvious form was `[hud] size CxR` plus a comparison against
        // `tabs.rs`'s `[win] surface ... WM_SIZE` line -- but that one stops
        // after ten messages (`if n <= 10`), and a resize five seconds into a
        // run arrives long after the startup layouts have used the quota up.
        // A criterion whose evidence is rate-limited elsewhere is a criterion
        // that quietly stops being checkable, so the arithmetic is closed here
        // instead: client pixels, cell size, and the quotient, in one line
        // nobody else can throttle.
        logf!(
            "[hud] size {}x{} from client {}x{} cell {}x{}",
            cols, rows, px_w, px_h, cell_w, cell_h
        );
    }
}

unsafe extern "system" fn size_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HUD_SYNC => {
                show_size(hwnd);
                LRESULT(0)
            }
            WM_TIMER if wp.0 == TIMER_SIZE_OFF => {
                let _ = KillTimer(Some(hwnd), TIMER_SIZE_OFF);
                let was = STATE.with(|c| {
                    c.borrow_mut()
                        .as_mut()
                        .map(|st| std::mem::replace(&mut st.size_visible, false))
                        .unwrap_or(false)
                });
                if was {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    logf!("[hud] size hidden");
                }
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let label = STATE.with(|c| {
                    c.borrow()
                        .as_ref()
                        .map(|st| format!("{} × {}", st.cols, st.rows))
                        .unwrap_or_default()
                });
                paint(hwnd, &label, COL_BG, COL_TEXT);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// --------------------------------------------------------- readonly badge

unsafe extern "system" fn ro_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_HUD_SYNC => {
                let on = READONLY.load(Ordering::Acquire);
                let was = STATE.with(|c| {
                    c.borrow_mut()
                        .as_mut()
                        .map(|st| std::mem::replace(&mut st.ro_visible, on))
                        .unwrap_or(false)
                });
                if !on {
                    if was {
                        let _ = ShowWindow(hwnd, SW_HIDE);
                    }
                    logf!("[hud] readonly off");
                    return LRESULT(0);
                }
                let frame = crate::tabs::frame_hwnd();
                let mut fr = RECT::default();
                if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
                    return LRESULT(0);
                }
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                let (w, h) = (sc(110), sc(HEIGHT));
                // Top-left of the content area: the one corner the search bar
                // (top-right) and the key indicator (bottom-right) do not use.
                let x = fr.left + sc(16);
                let y = fr.top + sc(56);
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOPMOST),
                    x,
                    y,
                    w,
                    h,
                    SWP_SHOWWINDOW | SWP_NOACTIVATE,
                );
                let _ = InvalidateRect(Some(hwnd), None, true);
                logf!("[hud] readonly on");
                LRESULT(0)
            }
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(hwnd, "READ ONLY", COL_RO_BG, COL_TEXT);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

// ------------------------------------------------------------------- paint

fn paint(hwnd: HWND, label: &str, bg: u32, fg: u32) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        let brush = CreateSolidBrush(COLORREF(bg));
        FillRect(hdc, &rc, brush);
        let _ = DeleteObject(brush.into());
        SetBkMode(hdc, TRANSPARENT);
        STATE.with(|c| {
            let b = c.borrow();
            let Some(st) = b.as_ref() else { return };
            let old = SelectObject(hdc, st.font.into());
            SetTextColor(hdc, COLORREF(fg));
            let mut wide: Vec<u16> = label.encode_utf16().collect();
            DrawTextW(
                hdc,
                &mut wide,
                &mut rc,
                DT_CENTER | DT_SINGLELINE | DT_VCENTER,
            );
            SelectObject(hdc, old);
        });
        let _ = EndPaint(hwnd, &ps);
    }
}
