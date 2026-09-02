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
use std::sync::atomic::{AtomicPtr, Ordering};

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::{logf, plogf};

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

/// Which surfaces are read-only, by surface pointer.
///
/// **This was one process-wide `AtomicBool`, and that is the defect this list
/// exists to fix.** Read-only is a property of a *surface*: with a split, one
/// pane can be read-only while the other is not. A single bool made the two
/// panes share one answer, and the two visible consequences pointed in
/// opposite directions -- the right pane's menu ticked «Read-only» because
/// the *left* pane was, and toggling it printed `on` because the right pane's
/// own state, the one the core keeps, said otherwise. **A tick and a badge
/// drawn from a state that is not the one the core is toggling will disagree
/// with it eventually, and there is nothing in either of them that can say
/// so.**
///
/// A `Vec` rather than a map: a window has a handful of panes, and the whole
/// list is walked on every sync anyway to drop surfaces that no longer exist.
static READONLY: std::sync::Mutex<Vec<(usize, bool)>> = std::sync::Mutex::new(Vec::new());

/// The surface the badge is currently showing for, or 0.
static RO_SHOWN_FOR: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

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

/// Is **this** surface read-only?
///
/// The badge and every menu tick have to come from here, with the surface the
/// menu is about: the one the pointer opened it on, not the focused one. Two
/// copies of this state drift the first time the core toggles it from
/// somewhere else, and the symptom is a menu that lies about a mode the badge
/// is simultaneously reporting correctly.
pub fn is_readonly_for(surface: usize) -> bool {
    if surface == 0 {
        return false;
    }
    READONLY
        .lock()
        .map(|v| v.iter().any(|(s, on)| *s == surface && *on))
        .unwrap_or(false)
}

/// `GHOSTTY_ACTION_READONLY` for one surface. **Safe from any thread.**
pub fn on_readonly_for(surface: usize, on: bool) {
    if surface == 0 {
        logf!("[hud] readonly {} for surface 0 -- ignored, that names no terminal", on);
        return;
    }
    if let Ok(mut v) = READONLY.lock() {
        match v.iter_mut().find(|(s, _)| *s == surface) {
            Some(e) => e.1 = on,
            None => v.push((surface, on)),
        }
    }
    let h = HWND_RO.load(Ordering::Acquire);
    if !h.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(surface), LPARAM(0)) };
    }
}

/// The pane window that hosts a surface, and its rectangle on screen.
///
/// **Read out of the tab model rather than kept here.** A second table of
/// which pane owns which surface is a second thing to keep in step with the
/// splits, and it would be wrong exactly while a split is being made.
fn pane_rect_for(surface: usize) -> Option<RECT> {
    let hwnd = {
        // Every window: the key is a surface, which is unique in the process,
        // so this is a search rather than a choice of window.
        crate::tabs::with_windows(|ws| {
            ws.iter()
                .flat_map(|w| w.tabs.iter())
                .flat_map(|t| t.panes.iter())
                .find(|p| p.surface == surface)
                .map(|p| HWND(p.hwnd as *mut c_void))
        })?
    };
    let mut r = RECT::default();
    if unsafe { GetWindowRect(hwnd, &mut r) }.is_err() {
        return None;
    }
    Some(r)
}

/// Drop surfaces that no longer exist, and say how many are read-only.
///
/// Called on every sync: a pane that closed while read-only would otherwise
/// leave its `true` behind, and surface pointers get reused.
fn prune_and_count() -> usize {
    let live: Vec<usize> = {
        // Every window: a surface that closed in window 2 has to leave this
        // list too, or its stale `read-only` sticks to a reused pointer.
        crate::tabs::with_windows(|ws| {
            ws.iter()
                .flat_map(|w| w.tabs.iter())
                .flat_map(|t| t.panes.iter())
                .map(|p| p.surface)
                .collect()
        })
    };
    let Ok(mut v) = READONLY.lock() else { return 0 };
    let before = v.len();
    v.retain(|(s, _)| live.contains(s));
    if v.len() != before {
        logf!("[hud] forgot {} closed surface(s) from the read-only list", before - v.len());
    }
    v.iter().filter(|(_, on)| *on).count()
}

/// The frame was resized. **Main thread only** -- it is called from the frame's
/// own window procedure.
pub fn on_frame_resized() {
    let h = HWND_SIZE.load(Ordering::Acquire);
    if !h.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
    }
    // **The badge has to move too, now that it sits over a pane.** While it
    // was pinned to the window's corner a resize left it roughly right; over a
    // pane, a resize moves the pane out from under it and the badge ends up
    // marking whatever is now beneath it. `WPARAM(0)` means "re-evaluate the
    // surface you are already showing".
    let ro = HWND_RO.load(Ordering::Acquire);
    if !ro.is_null() {
        let _ = unsafe { PostMessageW(Some(HWND(ro)), WM_HUD_SYNC, WPARAM(0), LPARAM(0)) };
    }
}

/// Columns and rows of the active surface, or `None` if either input is not
/// available yet. **Returns `None` rather than a plausible-looking zero**: a
/// sign that says `0x0` looks like a measurement, and this one would be the
/// absence of one.
fn grid() -> Option<(i32, i32, i32, i32, i32, i32)> {
    // **The first window's active pane.** The HUD is one overlay for the
    // process and has no frame of its own to ask about; which window it
    // should be measuring is a question for whoever gives the HUD a window,
    // and it is left visibly unanswered rather than quietly answered.
    let hwnd = crate::tabs::active_hwnd(crate::tabs::overlay_frame());
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
                // process-wide: creating one of the two badge windows; there is one pair per process
                plogf!("[hud] CreateWindowExW failed: {e:?}");
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
                // process-wide: registering the badge window class, once per process
                plogf!("[hud] RegisterClassExW failed");
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
        // process-wide: the badge windows exist; neither belongs to a terminal window yet
        plogf!("[hud] ready");
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
        let frame = crate::tabs::overlay_frame();
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
                let n_readonly = prune_and_count();
                // Which surface this sync is about: the one that just changed,
                // or -- for a sync with no surface, such as a resize -- the one
                // the badge is already showing for.
                let surface = if wp.0 != 0 {
                    wp.0
                } else {
                    RO_SHOWN_FOR.load(Ordering::Acquire)
                };
                let on = is_readonly_for(surface);
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
                    RO_SHOWN_FOR.store(0, Ordering::Release);
                    logf!("[hud] readonly off for surface {:#x}", surface);
                    // One badge, and more than one pane can be read-only. Say
                    // so rather than leaving a read-only pane unmarked and
                    // unexplained.
                    if n_readonly > 0 {
                        logf!(
                            "[hud] {} other surface(s) still read-only and unbadged (one badge,                              many panes)",
                            n_readonly
                        );
                    }
                    return LRESULT(0);
                }
                // **Over the pane that owns the surface, not the window's
                // corner.** The old placement was `frame.left + 16, frame.top
                // + 56`, which is the left pane's corner whenever there is a
                // split -- so a read-only right pane put its badge on a pane
                // that was not read-only, and nothing about the badge said
                // which pane it meant.
                let Some(fr) = pane_rect_for(surface) else {
                    logf!(
                        "[hud] readonly on for surface {:#x}, but no pane owns it; badge hidden                          rather than drawn somewhere arbitrary",
                        surface
                    );
                    let _ = ShowWindow(hwnd, SW_HIDE);
                    RO_SHOWN_FOR.store(0, Ordering::Release);
                    return LRESULT(0);
                };
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let sc = |v: i32| v * dpi / 96;
                let (w, h) = (sc(110), sc(HEIGHT));
                // Top-left of that pane, inset. The search bar (top-right) and
                // the key indicator (bottom-right) still do not use it.
                let x = fr.left + sc(16);
                let y = fr.top + sc(16);
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
                RO_SHOWN_FOR.store(surface, Ordering::Release);
                logf!(
                    "[hud] readonly on for surface {:#x}; badge at {},{} over pane {},{}..{},{}",
                    surface,
                    x,
                    y,
                    fr.left,
                    fr.top,
                    fr.right,
                    fr.bottom
                );
                if n_readonly > 1 {
                    logf!(
                        "[hud] {} surfaces are read-only; the badge shows {:#x} (one badge, many                          panes)",
                        n_readonly,
                        surface
                    );
                }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn clear() {
        if let Ok(mut v) = READONLY.lock() {
            v.clear();
        }
    }

    /// **The regression this file was rewritten for.** Read-only used to be
    /// one process-wide bool, so a second surface answered the first one's
    /// state: with a split, the right pane's menu ticked «Read-only» because
    /// the left pane was. Asking about a surface nobody has said anything
    /// about must be `false`, not "whatever the last surface said".
    #[test]
    fn one_surface_going_readonly_does_not_answer_for_another() {
        clear();
        on_readonly_for(0x1111, true);
        assert!(is_readonly_for(0x1111));
        assert!(!is_readonly_for(0x2222), "a different surface must answer for itself");
        clear();
    }

    /// Toggling back off is per surface too -- and the entry is updated, not
    /// appended, or the list would answer with whichever copy came first.
    #[test]
    fn a_surface_can_be_toggled_back_and_keeps_one_entry() {
        clear();
        on_readonly_for(0x3333, true);
        on_readonly_for(0x3333, false);
        assert!(!is_readonly_for(0x3333));
        assert_eq!(READONLY.lock().unwrap().len(), 1, "one entry per surface");
        clear();
    }

    /// A null surface names no terminal. Storing it would give every "no
    /// surface" caller a shared answer, which is the original bug in miniature.
    #[test]
    fn surface_zero_is_never_readonly_and_is_never_stored() {
        clear();
        on_readonly_for(0, true);
        assert!(!is_readonly_for(0));
        assert!(READONLY.lock().unwrap().is_empty());
        clear();
    }
}
