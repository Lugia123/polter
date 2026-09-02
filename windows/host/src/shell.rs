//! The window shell: the frame, the caption, and the buttons in it.
//!
//! **What this replaces.** The frame used to be a plain `WS_OVERLAPPEDWINDOW`
//! with the system caption on top and the tab strip below it -- two bars, one
//! of them ours. The brief is the macOS level of finish, and on macOS the tabs
//! *are* the titlebar. So the system caption goes away and the strip takes its
//! place, which on Win32 means owning the non-client area.
//!
//! ## Why a custom frame rather than just colouring the system one
//!
//! `DWMWA_CAPTION_COLOR` can tint the system caption, and that alone would be
//! perhaps thirty lines. But it leaves the caption *there* -- a separate bar
//! above the tabs. **Tinting and "tabs in the titlebar" are alternatives, not
//! steps**, and the second is what was asked for. So: `WM_NCCALCSIZE` removes
//! the caption, `WM_NCHITTEST` puts back the parts of it that have to keep
//! working (resize edges, drag-to-move, the snap layouts flyout), and the
//! buttons are drawn by us.
//!
//! The DWM attributes are still set, because with a custom frame they govern
//! the one part still drawn by the system: the thin border. That is also the
//! whole of the Windows 10 story -- see `Version` below.
//!
//! ## What this deliberately does not do
//!
//! macOS spends around a thousand lines here, much of it keeping two eras of
//! titlebar tabs (Ventura and Tahoe) working at once. That complexity is not
//! inherited: there is one window here, and it is the one we draw.

use windows::core::{s, BOOL};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DwmExtendFrameIntoClientArea, DwmSetWindowAttribute, DWMWINDOWATTRIBUTE,
};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};
use windows::Win32::UI::Controls::MARGINS;
use windows::Win32::UI::HiDpi::GetSystemMetricsForDpi;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::logf;
use crate::tabs;

// --------------------------------------------------------------- palette

/// The caption's own colours. Deliberately the same greys the strip already
/// uses: the caption is not a separate surface any more, it is the strip.
const CAPTION_BG: u32 = 0x00201f1d;
const BTN_HOVER: u32 = 0x00403f3d;
const BTN_CLOSE_HOVER: u32 = 0x002d2dc4; // BGR: a red that reads as "close"
const GLYPH: u32 = 0x00d0d0d0;
const GLYPH_DIM: u32 = 0x00808080;

/// Width of one caption button, unscaled. Windows uses 46x32 for its own;
/// matching it is what makes the corner feel native rather than approximate.
const BTN_W: i32 = 46;

// --------------------------------------------------------------- version

/// The real build number.
///
/// **`GetVersionEx` lies** -- since Windows 8.1 it reports 6.2 unless the
/// binary carries a compatibility manifest, and this one does not. `RtlGetVersion`
/// is the documented way to get the truth, and it is what every browser does.
/// Getting this wrong means asking Windows 10 for an attribute that only
/// exists on 11, which fails quietly and leaves the border the wrong colour.
fn build_number() -> u32 {
    #[repr(C)]
    struct OsVersionInfoW {
        dw_os_version_info_size: u32,
        dw_major_version: u32,
        dw_minor_version: u32,
        dw_build_number: u32,
        dw_platform_id: u32,
        sz_csd_version: [u16; 128],
    }
    unsafe {
        let ntdll = match GetModuleHandleA(s!("ntdll.dll")) {
            Ok(h) => h,
            Err(_) => return 0,
        };
        let Some(p) = GetProcAddress(ntdll, s!("RtlGetVersion")) else {
            return 0;
        };
        let f: extern "system" fn(*mut OsVersionInfoW) -> i32 = std::mem::transmute(p);
        let mut vi: OsVersionInfoW = std::mem::zeroed();
        vi.dw_os_version_info_size = std::mem::size_of::<OsVersionInfoW>() as u32;
        if f(&mut vi) != 0 {
            return 0;
        }
        vi.dw_build_number
    }
}

/// Windows 11 is 10.0.22000 and up. Below that, three DWM attributes this
/// file would like do not exist.
fn is_win11() -> bool {
    build_number() >= 22000
}

// ------------------------------------------------------------ attributes

const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
const DWMWA_BORDER_COLOR: u32 = 34;
const DWMWA_CAPTION_COLOR: u32 = 35;

fn set_attr<T>(hwnd: HWND, attr: u32, value: &T) -> bool {
    unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWINDOWATTRIBUTE(attr as i32),
            value as *const T as *const _,
            std::mem::size_of::<T>() as u32,
        )
        .is_ok()
    }
}

/// Dress the frame. Called once, after the window exists and before it is
/// shown.
///
/// **The Windows 10 fallback is the absence of the last two calls, not a
/// different code path.** With a custom frame the caption is ours to draw on
/// either version; what Windows 11 adds is control over the one-pixel border
/// DWM still draws around us. On 10 those two attributes return an error, we
/// log it once, and the window is correct apart from a border in the system
/// accent colour. Writing a second rendering path to chase that pixel would
/// cost more than the pixel is worth.
pub fn init_frame(hwnd: HWND) {
    let build = build_number();
    let dark = BOOL(1);
    let ok_dark = set_attr(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark);

    let (ok_caption, ok_border) = if is_win11() {
        (
            set_attr(hwnd, DWMWA_CAPTION_COLOR, &COLORREF(CAPTION_BG)),
            set_attr(hwnd, DWMWA_BORDER_COLOR, &COLORREF(CAPTION_BG)),
        )
    } else {
        (false, false)
    };

    // One pixel of frame extended into the client area. Without this DWM
    // stops drawing the drop shadow and the window looks flat and detached;
    // with the full frame extended, the top border reappears over our tabs.
    let m = MARGINS {
        cxLeftWidth: 0,
        cxRightWidth: 0,
        cyTopHeight: 1,
        cyBottomHeight: 0,
    };
    let ok_extend = unsafe { DwmExtendFrameIntoClientArea(hwnd, &m).is_ok() };

    unsafe {
        // Tell Windows the frame changed, so it asks us to recalculate it.
        let _ = SetWindowPos(
            hwnd,
            None,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED,
        );
    }

    logf!(
        "[shell] build={} win11={} dark={} caption={} border={} extend={}",
        build,
        is_win11(),
        ok_dark,
        ok_caption,
        ok_border,
        ok_extend
    );
}

// ------------------------------------------------------------ non-client

/// How much the frame overhangs the screen when maximised.
///
/// A maximised window's rect is deliberately larger than the monitor by the
/// resize border on every side; the system caption normally hides that. With
/// a custom frame it does not, so the top of our strip would be cut off and
/// the caption buttons would sit past the right edge. This is the amount to
/// pull the client area back in by.
fn maximized_overhang(hwnd: HWND) -> i32 {
    unsafe {
        let dpi = crate::dpi_for(hwnd);
        let frame = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi);
        let padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
        frame + padding
    }
}

fn is_maximized(hwnd: HWND) -> bool {
    unsafe { IsZoomed(hwnd).as_bool() }
}

/// `WM_NCCALCSIZE`: the caption is gone, the resize borders stay.
///
/// Returning a client rect equal to the window rect removes every non-client
/// element -- caption, borders, the lot. The borders are then put back by
/// `hit_test` reporting `HTTOP` and friends near the edges, which is what
/// makes the window resizable without a visible frame. The top is left flush
/// so the tabs reach the very top of the window, the way they do on macOS.
pub fn nc_calc_size(hwnd: HWND, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
    if wp.0 == 0 {
        return None;
    }
    let params = lp.0 as *mut NCCALCSIZE_PARAMS;
    if params.is_null() {
        return None;
    }
    unsafe {
        let rc = &mut (*params).rgrc[0];
        if is_maximized(hwnd) {
            let inset = maximized_overhang(hwnd);
            rc.left += inset;
            rc.top += inset;
            rc.right -= inset;
            rc.bottom -= inset;
        }
        // Not maximised: the rect is left exactly as it came in, so the
        // client area *is* the window rect -- no caption, no visible border.
        // The resize edges come back through `hit_test`, which reports
        // HTLEFT/HTTOP/... for client pixels near the edges.
    }
    Some(LRESULT(0))
}

/// The three caption buttons, right to left: close, maximise, minimise.
///
/// Returned in window-client coordinates, which is the same space the strip
/// works in, so the strip can simply avoid this range.
pub fn buttons(hwnd: HWND) -> [RECT; 3] {
    let scale = tabs::scale_of(hwnd);
    let w = (BTN_W as f64 * scale) as i32;
    let h = crate::strip::strip_h(scale);
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    let right = rc.right;
    [
        RECT { left: right - w, top: 0, right, bottom: h },          // close
        RECT { left: right - 2 * w, top: 0, right: right - w, bottom: h }, // max
        RECT { left: right - 3 * w, top: 0, right: right - 2 * w, bottom: h }, // min
    ]
}

/// How much of the strip's width the buttons take. The strip subtracts this
/// rather than being told where to stop, so there is one owner of the number.
pub fn reserved_right(frame: HWND) -> i32 {
    (BTN_W as f64 * tabs::scale_of(frame) * 3.0) as i32
}

/// `WM_NCHITTEST`: hand back the parts of the caption that must keep working.
///
/// Four kinds of answer, and each one is a behaviour that silently disappears
/// if it is missing:
///
///  - `HTTOP`/`HTLEFT`/... near the edges: **resizing**. With the caption
///    gone the system no longer supplies these.
///  - `HTMAXBUTTON` over the maximise button: **the snap layouts flyout**.
///    Windows 11 shows it on hover, and only for a window that says the
///    pointer is over its maximise button. Nothing else triggers it.
///  - `HTCAPTION` over empty strip: **dragging the window, double-click to
///    maximise, and the system menu on right-click** -- all of it, free.
///  - `HTCLIENT` over a tab: so the strip's own mouse handling runs. Get this
///    wrong and tabs become undraggable in a way that looks like the drag
///    code is broken.
pub fn hit_test(hwnd: HWND, screen_x: i32, screen_y: i32) -> LRESULT {
    let mut pt = POINT { x: screen_x, y: screen_y };
    unsafe {
        let _ = ScreenToClient(hwnd, &mut pt);
    }
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    let scale = tabs::scale_of(hwnd);
    let border = (6.0 * scale) as i32;
    let sh = crate::strip::strip_h(scale);

    // Edges first: a resize border on top of the caption still resizes.
    if !is_maximized(hwnd) {
        let left = pt.x < border;
        let right = pt.x >= rc.right - border;
        let top = pt.y < border;
        let bottom = pt.y >= rc.bottom - border;
        let code = match (top, bottom, left, right) {
            (true, _, true, _) => Some(HTTOPLEFT),
            (true, _, _, true) => Some(HTTOPRIGHT),
            (_, true, true, _) => Some(HTBOTTOMLEFT),
            (_, true, _, true) => Some(HTBOTTOMRIGHT),
            (true, ..) => Some(HTTOP),
            (_, true, ..) => Some(HTBOTTOM),
            (_, _, true, _) => Some(HTLEFT),
            (_, _, _, true) => Some(HTRIGHT),
            _ => None,
        };
        if let Some(c) = code {
            return LRESULT(c as isize);
        }
    }

    if pt.y >= sh {
        return LRESULT(HTCLIENT as isize);
    }

    // The buttons. HTMAXBUTTON is the one with a side effect: it is what
    // makes the Windows 11 snap layouts flyout appear.
    let b = buttons(hwnd);
    let inside = |r: &RECT| pt.x >= r.left && pt.x < r.right && pt.y >= r.top && pt.y < r.bottom;
    if inside(&b[0]) {
        return LRESULT(HTCLOSE as isize);
    }
    if inside(&b[1]) {
        return LRESULT(HTMAXBUTTON as isize);
    }
    if inside(&b[2]) {
        return LRESULT(HTMINBUTTON as isize);
    }

    // A tab, its close button, or the overflow chevron: the strip's business.
    if crate::strip::is_interactive(hwnd, pt.x, pt.y) {
        return LRESULT(HTCLIENT as isize);
    }

    LRESULT(HTCAPTION as isize)
}

/// Which caption button the pointer is over, if any, for the hover state.
/// Kept here rather than in the strip because the strip does not own these.
static HOVER: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// `WM_NCMOUSEMOVE` / `WM_NCMOUSELEAVE`: light the button under the pointer.
///
/// The pointer is in the non-client area here, so the strip never sees these
/// moves; without this the buttons would be the one part of the window with
/// no hover feedback, which reads as "not a real button".
pub fn nc_hover(hwnd: HWND, hit: isize) {
    let idx = match hit as u32 {
        HTCLOSE => 0,
        HTMAXBUTTON => 1,
        HTMINBUTTON => 2,
        _ => -1i32 as u32,
    } as i32;
    if HOVER.swap(idx, std::sync::atomic::Ordering::Relaxed) != idx {
        unsafe {
            let _ = InvalidateRect(Some(hwnd), None, false);
        }
    }
}

/// `WM_NCLBUTTONDOWN` on one of our buttons. Returns true if handled.
///
/// Acting on the down rather than the up is what the system caption does for
/// these three, so it is what feels right; the alternative would be to track
/// press-and-release ourselves for no visible gain.
pub fn nc_click(hwnd: HWND, hit: isize) -> bool {
    let cmd = match hit as u32 {
        HTCLOSE => SC_CLOSE,
        HTMAXBUTTON => {
            if is_maximized(hwnd) {
                SC_RESTORE
            } else {
                SC_MAXIMIZE
            }
        }
        HTMINBUTTON => SC_MINIMIZE,
        _ => return false,
    };
    unsafe {
        let _ = PostMessageW(Some(hwnd), WM_SYSCOMMAND, WPARAM(cmd as usize), LPARAM(0));
    }
    true
}

// ---------------------------------------------------------------- paint

fn line(hdc: HDC, x1: i32, y1: i32, x2: i32, y2: i32, color: u32, width: i32) {
    unsafe {
        let pen = CreatePen(PS_SOLID, width.max(1), COLORREF(color));
        let old = SelectObject(hdc, pen.into());
        let _ = MoveToEx(hdc, x1, y1, None);
        let _ = LineTo(hdc, x2, y2);
        SelectObject(hdc, old);
        let _ = DeleteObject(pen.into());
    }
}

fn fill(hdc: HDC, r: &RECT, color: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(color));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

/// Draw the three buttons into the strip's memory DC.
///
/// **Drawn, not written.** A font glyph for the maximise box lands on a
/// different pixel at every DPI and every font substitution; three strokes do
/// not. This is the same reason the tab close button is drawn.
pub fn paint_buttons(hdc: HDC, hwnd: HWND, active: bool) {
    let scale = tabs::scale_of(hwnd);
    let b = buttons(hwnd);
    let hover = HOVER.load(std::sync::atomic::Ordering::Relaxed);
    let glyph = if active { GLYPH } else { GLYPH_DIM };
    let stroke = (1.0 * scale).max(1.0) as i32;
    let maximized = is_maximized(hwnd);

    for (i, r) in b.iter().enumerate() {
        if hover == i as i32 {
            fill(hdc, r, if i == 0 { BTN_CLOSE_HOVER } else { BTN_HOVER });
        }
        let cx = (r.left + r.right) / 2;
        let cy = (r.top + r.bottom) / 2;
        let s = (5.0 * scale) as i32;
        let color = if hover == i as i32 && i == 0 { 0x00ffffff } else { glyph };
        match i {
            // Close: two strokes.
            0 => {
                line(hdc, cx - s, cy - s, cx + s, cy + s, color, stroke);
                line(hdc, cx + s, cy - s, cx - s, cy + s, color, stroke);
            }
            // Maximise: a box, or two offset boxes when already maximised --
            // the same shape the system uses for restore.
            1 => {
                let d = (2.0 * scale) as i32;
                if maximized {
                    rect_outline(hdc, cx - s, cy - s + d, cx + s - d, cy + s, color, stroke);
                    line(hdc, cx - s + d, cy - s + d, cx - s + d, cy - s, color, stroke);
                    line(hdc, cx - s + d, cy - s, cx + s, cy - s, color, stroke);
                    line(hdc, cx + s, cy - s, cx + s, cy + s - d, color, stroke);
                } else {
                    rect_outline(hdc, cx - s, cy - s, cx + s, cy + s, color, stroke);
                }
            }
            // Minimise: one stroke.
            _ => line(hdc, cx - s, cy, cx + s, cy, color, stroke),
        }
    }
}

fn rect_outline(hdc: HDC, l: i32, t: i32, r: i32, b: i32, color: u32, w: i32) {
    line(hdc, l, t, r, t, color, w);
    line(hdc, r, t, r, b, color, w);
    line(hdc, r, b, l, b, color, w);
    line(hdc, l, b, l, t, color, w);
}
