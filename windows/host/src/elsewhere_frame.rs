//! The frosted frame under "it is in its own tab" (task 1758): the last
//! picture a supervisor's terminal showed in the control room, taken as it
//! leaves, kept small and blurred, and drawn under the right-hand side's
//! words with the veil and the shade over it -- macOS's
//! `ControlRoomElsewhere`, whose arithmetic is
//! `polter_control_room::elsewhere` and is shared, tests and all.
//!
//! **One frame is kept**, the last one taken, with the terminal it is of:
//! the side only ever shows the one terminal it is about, and another
//! terminal's frame is never drawn for it (`elsewhere::frame_for`).
//!
//! **Taken off the screen**, `BitBlt` from the screen's DC with
//! `CAPTUREBLT`, the way every capture in this host is (`shot.rs`): the
//! terminal draws with OpenGL, and its own window DC does not hold what is
//! on the screen. Taken at the moment it is given back, while it is still
//! where the control room showed it. A window kept out of captures
//! (`windows-secure-input-exclude-from-capture`) comes back black, which is
//! a dark frame and nothing worse.

use std::cell::RefCell;

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::GetWindowRect;

use polter_control_room::elsewhere;
use polter_control_room::lend::Detail;
use polter_control_room::look::Rgba;

struct Frozen {
    terminal: String,
    w: usize,
    h: usize,
    /// BGRA, top down, already blurred.
    px: Vec<u8>,
}

thread_local! {
    static FROZEN: RefCell<Option<Frozen>> = const { RefCell::new(None) };
}

/// Take the frame `pane` (the terminal `terminal`'s window) shows now, keep
/// it small, blur it, and keep it as the one frame. Says in the log what
/// it took, or why nothing.
pub fn capture(frame: HWND, pane: HWND, terminal: &str) {
    let mut r = RECT::default();
    if unsafe { GetWindowRect(pane, &mut r) }.is_err() {
        crate::wlogf!(frame, "[control-room] frosted frame of {terminal}: no window rect; none kept");
        return;
    }
    let (sw, sh) = (r.right - r.left, r.bottom - r.top);
    let Some((kw, kh)) = elsewhere::kept_size(sw as f64, sh as f64) else {
        crate::wlogf!(frame, "[control-room] frosted frame of {terminal}: {sw}x{sh} has no size; none kept");
        return;
    };
    let (kw, kh) = (kw as i32, kh as i32);
    let Some(mut px) = (unsafe { grab(r, kw, kh) }) else {
        crate::wlogf!(frame, "[control-room] frosted frame of {terminal}: the screen could not be read; none kept");
        return;
    };
    elsewhere::blur(&mut px, kw as usize, kh as usize, polter_control_room::look::elsewhere::BLUR);
    FROZEN.with(|f| *f.borrow_mut() = Some(Frozen { terminal: terminal.to_string(), w: kw as usize, h: kh as usize, px }));
    crate::wlogf!(frame, "[control-room] frosted frame of {terminal}: {sw}x{sh} kept as {kw}x{kh}");
}

/// The screen under `r`, scaled to `w` x `h`, as BGRA top down.
unsafe fn grab(r: RECT, w: i32, h: i32) -> Option<Vec<u8>> {
    unsafe {
        let screen = GetDC(None);
        if screen.is_invalid() {
            return None;
        }
        let mem = CreateCompatibleDC(Some(screen));
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let out = match CreateDIBSection(Some(mem), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(b) if !bits.is_null() => {
                let old = SelectObject(mem, b.into());
                // Averaged down rather than sampled: the picture is only ever
                // shown blurred, and a sampled one shimmers into the blur.
                SetStretchBltMode(mem, HALFTONE);
                let ok = StretchBlt(mem, 0, 0, w, h, Some(screen), r.left, r.top, r.right - r.left, r.bottom - r.top, SRCCOPY | CAPTUREBLT).as_bool();
                let _ = GdiFlush();
                let px = ok.then(|| std::slice::from_raw_parts(bits as *const u8, (w * h * 4) as usize).to_vec());
                SelectObject(mem, old);
                let _ = DeleteObject(b.into());
                px
            }
            Ok(b) => {
                let _ = DeleteObject(b.into());
                None
            }
            Err(_) => None,
        };
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        out
    }
}

/// Draw the kept frame into `place` (device pixels) under what `detail`
/// says, if the frame is of the terminal it says that about: scaled to
/// cover the place and cut at its edges, then the terminal's `ground` laid
/// over it -- the veil everywhere, more behind the words, whose box is
/// `words` (centre x, centre y, width, height, in device pixels). Clipped
/// to `clip` (the side's own rounded frame). False when nothing was drawn,
/// and the place is the flat ground it always was.
pub unsafe fn paint(dc: HDC, place: RECT, clip: HRGN, detail: &Detail, ground: Rgba, words: (f64, f64, f64, f64)) -> bool {
    FROZEN.with(|f| {
        let f = f.borrow();
        let Some(frozen) = elsewhere::frame_for(detail, f.as_ref().map(|z| (z.terminal.as_str(), z))) else { return false };
        let (pw, ph) = (place.right - place.left, place.bottom - place.top);
        if pw <= 0 || ph <= 0 {
            return false;
        }
        unsafe {
            let saved = SaveDC(dc);
            if !clip.is_invalid() {
                SelectClipRgn(dc, Some(clip));
            }
            // The frame, covering the place: scaled by the larger of the two
            // ratios and centred, so what is cut is cut evenly.
            let s = (pw as f64 / frozen.w as f64).max(ph as f64 / frozen.h as f64);
            let (dw, dh) = ((frozen.w as f64 * s).round() as i32, (frozen.h as f64 * s).round() as i32);
            let (dx, dy) = (place.left + (pw - dw) / 2, place.top + (ph - dh) / 2);
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: frozen.w as i32,
                    biHeight: -(frozen.h as i32),
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            SetStretchBltMode(dc, HALFTONE);
            StretchDIBits(dc, dx, dy, dw, dh, 0, 0, frozen.w as i32, frozen.h as i32, Some(frozen.px.as_ptr() as *const _), &info, DIB_RGB_COLORS, SRCCOPY);
            veil(dc, place, ground, words);
            let _ = RestoreDC(dc, saved);
        }
        true
    })
}

/// The ground over the frame, pixel by pixel: `elsewhere::ground_at`.
unsafe fn veil(dc: HDC, place: RECT, ground: Rgba, words: (f64, f64, f64, f64)) {
    let (w, h) = (place.right - place.left, place.bottom - place.top);
    let (cx, cy, ww, wh) = words;
    let size = (w as f64, h as f64);
    let ellipse = elsewhere::shade_size((ww, wh), size);
    let middle = elsewhere::shade_at_middle((ww, wh), size);
    unsafe {
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let Ok(bmp) = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0) else { return };
        if bits.is_null() {
            let _ = DeleteObject(bmp.into());
            return;
        }
        let o = std::slice::from_raw_parts_mut(bits as *mut u32, (w * h) as usize);
        let (ox, oy) = (cx - place.left as f64, cy - place.top as f64);
        for y in 0..h {
            for x in 0..w {
                let a = elsewhere::ground_at(x as f64 + 0.5 - ox, y as f64 + 0.5 - oy, ellipse, middle);
                // Premultiplied, as `AlphaBlend` wants it.
                let ch = |c: u8| (c as f64 * a).round() as u32;
                o[(y * w + x) as usize] = (((a * 255.0).round() as u32) << 24) | (ch(ground.r) << 16) | (ch(ground.g) << 8) | ch(ground.b);
            }
        }
        let mem = CreateCompatibleDC(Some(dc));
        let old = SelectObject(mem, bmp.into());
        let how = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
        let _ = AlphaBlend(dc, place.left, place.top, w, h, mem, 0, 0, w, h, how);
        SelectObject(mem, old);
        let _ = DeleteDC(mem);
        let _ = DeleteObject(bmp.into());
    }
}
