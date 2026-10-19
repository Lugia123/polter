//! The one place the host hands text to `USER32` or `GDI` to be drawn or
//! measured (tasks 1871, 1872).
//!
//! **Words that are not there are not handed over.** Every one of these
//! calls takes a counted slice, and an empty `Vec<u16>` is a count of 0 and a
//! pointer to nothing (`0x2`, the dangling pointer of an empty buffer of
//! `u16`). `USER32` on Windows 11 build 26200 reads through it: an access
//! violation inside `USER32.dll` in the middle of `WM_PAINT`, with nothing in
//! the log after the line that opened the window. It has killed the host
//! three times, each from a different window: the screenshot overlay (task
//! 1199), the control room's panel (task 1439), and Manage Projects (task
//! 1871, `USER32+0x24702` reading `0x2`, three dumps out of three) -- each
//! time from a string that was empty on purpose.
//!
//! So each function here has the signature of the call it stands for, and
//! asks `draws` first. A caller changes the name it calls and nothing else.
//! What an empty string gets back is what drawing nothing would have given:
//! nothing drawn, and -- measured -- no width and no height, so a caller that
//! lays out by the answer does not take the box it started with for the
//! text's size.
//!
//! `windows/tools/control-room-hands-user32-no-empty-text.py` holds the whole
//! of `windows/host/src` to it: these calls appear here, in these functions,
//! after the question, and nowhere else.

use windows::core::{BOOL, PCWSTR};
use windows::Win32::Foundation::{RECT, SIZE};
use windows::Win32::Graphics::Gdi::{
    DrawTextW, GetTextExtentExPointW, GetTextExtentPoint32W, TextOutW, DRAW_TEXT_FORMAT, DT_CALCRECT, HDC,
};

/// Whether `text` is anything to hand to the system.
pub fn draws(text: &[u16]) -> bool {
    !text.is_empty()
}

/// `DrawTextW`. With `DT_CALCRECT`, an empty `text` leaves `r` as wide and
/// as tall as nothing: its right edge on its left, its bottom on its top.
pub unsafe fn draw_text_w(hdc: HDC, text: &mut [u16], r: *mut RECT, how: DRAW_TEXT_FORMAT) -> i32 {
    if !draws(text) {
        if how.0 & DT_CALCRECT.0 != 0 && !r.is_null() {
            unsafe {
                (*r).right = (*r).left;
                (*r).bottom = (*r).top;
            }
        }
        return 0;
    }
    unsafe { DrawTextW(hdc, text, r, how) }
}

/// `TextOutW`. Nothing to write is written, and that succeeded.
pub unsafe fn text_out_w(hdc: HDC, x: i32, y: i32, text: &[u16]) -> BOOL {
    if !draws(text) {
        return BOOL(1);
    }
    unsafe { TextOutW(hdc, x, y, text) }
}

/// `GetTextExtentPoint32W`. Nothing is no size.
pub unsafe fn get_text_extent_point32_w(hdc: HDC, text: &[u16], size: *mut SIZE) -> BOOL {
    if !draws(text) {
        if !size.is_null() {
            unsafe { *size = SIZE::default() };
        }
        return BOOL(1);
    }
    unsafe { GetTextExtentPoint32W(hdc, text, size) }
}

/// `GetTextExtentExPointW`, given the slice rather than a pointer and a
/// count. Nothing fits no characters and is no size.
pub unsafe fn get_text_extent_ex_point_w(
    hdc: HDC,
    text: &[u16],
    max_extent: i32,
    fit: Option<*mut i32>,
    dx: Option<*mut i32>,
    size: *mut SIZE,
) -> BOOL {
    if !draws(text) {
        if let Some(fit) = fit.filter(|p| !p.is_null()) {
            unsafe { *fit = 0 };
        }
        if !size.is_null() {
            unsafe { *size = SIZE::default() };
        }
        return BOOL(1);
    }
    unsafe { GetTextExtentExPointW(hdc, PCWSTR(text.as_ptr()), text.len() as i32, max_extent, fit, dx, size) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_1872_nothing_is_not_handed_over() {
        assert!(!draws(&[]));
        assert!(draws(&[u16::from(b'a')]));
    }

    #[test]
    fn task_1872_measuring_nothing_is_no_size() {
        let mut r = RECT { left: 10, top: 20, right: 300, bottom: 400 };
        let drawn = unsafe { draw_text_w(HDC::default(), &mut [], &mut r, DT_CALCRECT) };
        assert_eq!(drawn, 0);
        assert_eq!((r.right, r.bottom), (10, 20), "a measure of nothing kept the box it was given");

        // Drawn, not measured: the box is the caller's and is left alone.
        let mut kept = RECT { left: 10, top: 20, right: 300, bottom: 400 };
        let _ = unsafe { draw_text_w(HDC::default(), &mut [], &mut kept, DRAW_TEXT_FORMAT(0)) };
        assert_eq!((kept.right, kept.bottom), (300, 400));

        let mut size = SIZE { cx: 7, cy: 9 };
        assert!(unsafe { get_text_extent_point32_w(HDC::default(), &[], &mut size) }.as_bool());
        assert_eq!((size.cx, size.cy), (0, 0));

        let mut fit = 5;
        let mut size = SIZE { cx: 7, cy: 9 };
        assert!(unsafe { get_text_extent_ex_point_w(HDC::default(), &[], 100, Some(&mut fit), None, &mut size) }.as_bool());
        assert_eq!(fit, 0);
        assert_eq!((size.cx, size.cy), (0, 0));

        assert!(unsafe { text_out_w(HDC::default(), 0, 0, &[]) }.as_bool());
    }
}
