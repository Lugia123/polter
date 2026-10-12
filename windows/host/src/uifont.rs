//! The one place a settings or project window gets a font from.
//!
//! **The rule (settings.md §2.3b): no text in those windows is smaller than
//! the system's menu font.** The size is asked of the system, per DPI, every
//! time fonts are made -- `lfMenuFont` of `NONCLIENTMETRICSW` -- and is
//! written down nowhere. A window names the size it was designed with, in
//! 96-DPI pixels, and gets that or the menu's, whichever is larger
//! (`polter_settings_shell::text_px`, which is where the arithmetic is
//! tested).
//!
//! **Why a floor and not a fixed number.** The menu font is 12 px at 96 DPI
//! on a machine nobody has changed, which is what the small fonts here were
//! already written as. But it follows Settings > Accessibility > Text size,
//! and a literal 12 does not: at 150% text the menu is 18 px and a caption
//! made with `-(12 * dpi / 96)` is still 12.
//!
//! `windows/tools/no-text-below-the-menu-font.py` holds the other half: no
//! other file among those windows may call `CreateFontW` or take a stock
//! font, so there is no second way to make one.

use windows::core::PCWSTR;
use windows::Win32::Graphics::Gdi::{
    CreateFontW, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DEFAULT_PITCH, FF_DONTCARE, HFONT, OUT_DEFAULT_PRECIS,
};
use windows::Win32::UI::HiDpi::SystemParametersInfoForDpi;
use windows::Win32::UI::WindowsAndMessaging::{NONCLIENTMETRICSW, SPI_GETNONCLIENTMETRICS};

use crate::plogf;

/// The menu font's character height at `dpi`, in pixels. **0 when the system
/// would not say**: a floor of 0 leaves every font at the size it was
/// designed with, which is what this code did before it asked, and the line
/// in the log is how that gets noticed.
pub fn menu_px(dpi: i32) -> i32 {
    let mut m = NONCLIENTMETRICSW { cbSize: std::mem::size_of::<NONCLIENTMETRICSW>() as u32, ..Default::default() };
    let asked = unsafe { SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS.0, m.cbSize, Some(&mut m as *mut _ as *mut _), 0, dpi.max(96) as u32) };
    match asked {
        // Negative is a character height, positive a cell height; either
        // way the magnitude is the size the menu is set in.
        Ok(()) => m.lfMenuFont.lfHeight.abs(),
        Err(e) => {
            // process-wide: the metrics belong to the session, not a window
            plogf!("[uifont] SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, dpi={dpi}) failed: {e:?}; fonts keep their designed sizes");
            0
        }
    }
}

/// A font `px` tall at 96 DPI, scaled to `dpi`, and never smaller than the
/// menu's.
pub fn make(dpi: i32, px: i32, weight: i32, face: PCWSTR) -> HFONT {
    let height = polter_settings_shell::text_px(px, dpi, menu_px(dpi));
    unsafe {
        CreateFontW(
            -height,
            0,
            0,
            0,
            weight,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            face,
        )
    }
}

/// The face the control room sets names, commands and paths in.
///
/// **Cascadia Mono where it is installed, Consolas where it is not.** The
/// design's sizes are for a face whose letters are six tenths of its size
/// wide (41 to a line of 322 at 13); Consolas is narrower and lower at the
/// same size -- 0.55 wide -- so a group's name set at 15 read as 13 and a
/// command at 13 as 11 beside the interface's face (task 1444). Cascadia
/// Mono is 0.586 wide and ships with Windows 11; Consolas is on every
/// Windows. Asked once.
pub fn mono_face() -> PCWSTR {
    use std::sync::OnceLock;
    use windows::core::w;
    use windows::Win32::Foundation::LPARAM;
    use windows::Win32::Graphics::Gdi::{EnumFontFamiliesExW, GetDC, ReleaseDC, LOGFONTW, TEXTMETRICW};
    static CASCADIA: OnceLock<bool> = OnceLock::new();
    unsafe extern "system" fn found(_: *const LOGFONTW, _: *const TEXTMETRICW, _: u32, seen: LPARAM) -> i32 {
        unsafe { *(seen.0 as *mut bool) = true };
        0
    }
    let has = *CASCADIA.get_or_init(|| {
        let mut seen = false;
        let mut want = LOGFONTW { lfCharSet: DEFAULT_CHARSET, ..Default::default() };
        for (to, from) in want.lfFaceName.iter_mut().zip("Cascadia Mono".encode_utf16()) {
            *to = from;
        }
        unsafe {
            let dc = GetDC(None);
            EnumFontFamiliesExW(dc, &want, Some(found), LPARAM(&mut seen as *mut bool as isize), 0);
            ReleaseDC(None, dc);
        }
        // process-wide: which faces are installed is the machine's
        plogf!("[uifont] the control room's fixed-width face: {}", if seen { "Cascadia Mono" } else { "Consolas (Cascadia Mono is not installed)" });
        seen
    });
    if has {
        w!("Cascadia Mono")
    } else {
        w!("Consolas")
    }
}
