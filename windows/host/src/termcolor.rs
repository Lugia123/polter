//! The colours the terminal reports, and the one place the window shows them.
//!
//! `color_change` is what the core sends when a program changes a terminal
//! colour programmatically -- OSC 10 (foreground), OSC 11 (background), OSC 12
//! (cursor), or any palette entry. A colour scheme switched by `vim`, a remote
//! host's prompt setting its own background over ssh, `printf '\e]11;#1e1e2e\a'`.
//!
//! # What the host does with it, and what it does not
//!
//! **Does:** remembers the colours per surface, and works out from the
//! background of the pane in front whether the whole window is light or dark
//! and what its strip is painted in ([`chrome`]) -- the macOS rule, where a
//! terminal window takes its terminal's background (task 1550). The border,
//! the caption, the strip, the control room and the frames round the panes
//! all ask it when they paint; a background change here only asks them to
//! paint again (`shell::recolor`).
//!
//! # High contrast wins here too
//!
//! When a high-contrast theme is on, the painters use system colours whatever
//! this says. A person who has asked the system for a specific set of colours
//! has not asked for whatever a program in a terminal decided to emit, and
//! `theme.rs` makes the same judgement for every other colour in this port.

use std::sync::Mutex;

use windows::Win32::Foundation::HWND;

use crate::ffi;
use crate::{plogf, wlogf};

/// What one surface has said about its colours.
///
/// Keyed by surface pointer, the same identity `hud.rs` uses for read-only.
/// **Never by index**: panes are added and removed, and an index quietly
/// starts naming a different one.
#[derive(Clone, Copy, Default)]
struct Colors {
    fg: Option<u32>,
    bg: Option<u32>,
    cursor: Option<u32>,
}

static COLORS: Mutex<Vec<(usize, Colors)>> = Mutex::new(Vec::new());

/// `(r, g, b)` to a `COLORREF`, which is `0x00BBGGRR` and not the other way
/// round. Getting this backwards is invisible in grey and obvious in orange.
fn colorref(r: u8, g: u8, b: u8) -> u32 {
    (b as u32) << 16 | (g as u32) << 8 | r as u32
}

/// Is this surface still in a window?
///
/// **The only way this file learns a pane has gone.** There is no teardown
/// hook here on purpose: adding one would put a second place in `tabs.rs`
/// that has to remember to call it, and the failure of a hook nobody calls is
/// a table that grows for the life of the process with nothing saying so.
fn still_alive(surface: usize) -> bool {
    crate::tabs::frame_of_surface(surface as crate::ffi::Surface).is_some()
}

fn record(surface: usize, kind: i32, value: u32) -> Colors {
    let mut guard = match COLORS.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    // Swept here rather than on a timer: the list is walked on every change
    // anyway, and a surface that has gone cannot send another colour.
    guard.retain(|(s, _)| *s == surface || still_alive(*s));
    let entry = match guard.iter_mut().find(|(s, _)| *s == surface) {
        Some((_, c)) => c,
        None => {
            guard.push((surface, Colors::default()));
            &mut guard.last_mut().unwrap().1
        }
    };
    match kind {
        ffi::COLOR_KIND_FOREGROUND => entry.fg = Some(value),
        ffi::COLOR_KIND_BACKGROUND => entry.bg = Some(value),
        ffi::COLOR_KIND_CURSOR => entry.cursor = Some(value),
        // A palette entry (kind >= 0). Remembered by nobody: the host draws
        // nothing from the palette, and storing 256 values that are never
        // read would be a table whose wrongness could not be noticed.
        _ => {}
    }
    *entry
}

/// The `color_change` action.
///
/// Returns `true` when the colour was recorded -- which is the whole of what
/// this host claims to do with it. **Not conditional on the border being
/// repainted**: the border is one window's decoration and the record is the
/// action, and returning `false` because a decoration did not change would
/// tell the core the colour never arrived.
pub fn on_color_change(
    frame: Option<HWND>,
    surface: Option<crate::ffi::Surface>,
    kind: i32,
    r: u8,
    g: u8,
    b: u8,
) -> bool {
    let Some(surface) = surface else {
        // process-wide: a colour belongs to a surface and this action named
        // none, so there is nothing to record it against
        plogf!("[color] color_change kind={kind} names no surface; dropped");
        return false;
    };
    let value = colorref(r, g, b);
    record(surface as usize, kind, value);

    let Some(f) = frame else {
        // process-wide: the surface is not in any window this host knows, so
        // there is no border to paint
        plogf!("[color] color_change kind={kind} #{r:02x}{g:02x}{b:02x} recorded, no window");
        return true;
    };

    if kind != ffi::COLOR_KIND_BACKGROUND {
        wlogf!(f, "[color] kind={kind} #{r:02x}{g:02x}{b:02x} recorded");
        return true;
    }

    // Only the surface a person is looking at gets to colour the window. With
    // a split, the other pane's background is equally real and equally not
    // what the frame is around.
    if crate::tabs::active_surface(f) != surface {
        wlogf!(f, "[color] background #{r:02x}{g:02x}{b:02x} recorded for an inactive pane");
        return true;
    }

    // The whole chrome follows the terminal's background now (task 1550):
    // the border, the caption, the strip, the control room and the frames
    // round the panes, light or dark by the macOS rule.
    let c = chrome(f);
    crate::shell::recolor(f);
    wlogf!(f, "[color] background #{r:02x}{g:02x}{b:02x}; the window is {}", if c.dark { "dark" } else { "light" });
    true
}

/// The background the window's chrome is worked out from: what the pane in
/// front last said with OSC 11, or the configured `background`. `None` when
/// neither can be read, which `Chrome::of` takes as dark.
///
/// **A pane that set its background and then reset it (OSC 111) is still
/// read as the colour it set**: the core sends the reset as no colour, and
/// this table has never heard of one. Recorded as a limit.
pub fn ground(frame: HWND) -> Option<u32> {
    let s = crate::tabs::active_surface(frame) as usize;
    let said = (s != 0)
        .then(|| {
            let guard = match COLORS.lock() {
                Ok(g) => g,
                Err(p) => p.into_inner(),
            };
            guard.iter().find(|(k, _)| *k == s).and_then(|(_, c)| c.bg)
        })
        .flatten();
    said.or_else(|| crate::divider::terminal_background().map(|c| c.0))
}

/// Light or dark for `frame`, and its strip's ground, by the macOS rule
/// (`polter_control_room::chrome`).
pub fn chrome(frame: HWND) -> polter_control_room::chrome::Chrome {
    polter_control_room::chrome::Chrome::of(ground(frame).map(polter_control_room::chrome::from_bgr))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **`COLORREF` is BGR.** The one assertion here is the byte order,
    /// because it is the mistake that looks right in every grey and wrong in
    /// every colour -- and the terminal colours this action carries are the
    /// ones somebody chose on purpose.
    #[test]
    fn a_colorref_is_bgr_and_not_rgb() {
        // Pure red must land in the low byte.
        assert_eq!(colorref(0xFF, 0x00, 0x00), 0x0000_00FF);
        // Pure blue in the high one.
        assert_eq!(colorref(0x00, 0x00, 0xFF), 0x00FF_0000);
        assert_eq!(colorref(0x1E, 0x1E, 0x2E), 0x002E_1E1E);
    }

    /// A palette entry (`kind >= 0`) is not stored. **The assertion is that
    /// nothing is remembered**, because the alternative that looks identical
    /// from the outside -- 256 entries kept and never read -- is a table
    /// whose being wrong could never be noticed.
    #[test]
    fn a_palette_entry_changes_nothing_that_is_kept() {
        let s = 0xBEEF_usize;
        let before = record(s, ffi::COLOR_KIND_BACKGROUND, 0x112233);
        let after = record(s, 7, 0x445566);
        assert_eq!(before.bg, after.bg);
        assert_eq!(after.fg, None);
        assert_eq!(after.cursor, None);
    }
}
