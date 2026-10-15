//! Light or dark for a terminal window's own chrome -- the tab strip, the
//! caption buttons, the window's border, and what is drawn inside the window
//! on the terminal's behalf (the control room, the pane frames, the boxes
//! that float over a terminal) -- and the strip's ground.
//!
//! **The macOS rule, as it is written there**: the window takes the
//! terminal's background colour, and is light when that colour's luminance
//! `0.299 r + 0.587 g + 0.114 b` is above one half
//! (`TransparentTitlebarTerminalWindow.swift` `syncAppearance`,
//! `OSColor+Extension.swift` `isLightColor`). The system's own light or dark
//! setting does not enter into it; that is for the settings and project
//! windows, which have no terminal in them (`theme.rs` in the host).
//!
//! **A background nobody could read is dark** ([`Chrome::of`] with `None`).
//! That is what this window was before it followed anything, so a host that
//! cannot say what its terminal is painted gets the old look rather than a
//! light strip over what is almost certainly a dark terminal.

use crate::look::{theme, Rgba, Theme};
use crate::scene::over;
use crate::tabstrip;

/// The ground the strip was painted in when it followed nothing, and what it
/// is still painted in when the terminal's background cannot be read.
pub const DARK_GROUND: Rgba = Rgba { r: 0x1d, g: 0x1f, b: 0x20, a: 1.0 };

/// Is a colour light, by the macOS rule? The comparison is strict: exactly
/// one half is dark, as it is there.
pub fn is_light(c: Rgba) -> bool {
    let l = (0.299 * c.r as f64 + 0.587 * c.g as f64 + 0.114 * c.b as f64) / 255.0;
    l > 0.5
}

/// One window's chrome, worked out from its terminal's background.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Chrome {
    pub dark: bool,
    /// The strip's ground: the terminal's background, or [`DARK_GROUND`].
    pub ground: Rgba,
}

/// The few colours on the strip that are not the control room's look: the
/// caption buttons' glyphs and the `+` and `»` buttons. In the dark they are
/// the values this strip has always had; in the light, the light table's
/// text colours and the tab strip's own hover.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Buttons {
    pub glyph: Rgba,
    /// The caption glyph of a window that is not the active one.
    pub glyph_dim: Rgba,
    /// A button's ground under the pointer, and while its menu is open.
    pub hover: Rgba,
    /// The `≡` button's ground under the pointer with its menu closed: a
    /// step short of `hover`.
    pub hover_soft: Rgba,
    /// `+` and `»`, and a tab's close cross, at rest and under the pointer.
    pub text: Rgba,
    pub text_hot: Rgba,
}

const fn rgb(r: u8, g: u8, b: u8) -> Rgba {
    Rgba { r, g, b, a: 1.0 }
}

impl Chrome {
    /// `ground` is the terminal's background as the host knows it, or
    /// `None` when it does not -- which is dark.
    pub fn of(ground: Option<Rgba>) -> Chrome {
        match ground {
            Some(g) => Chrome { dark: !is_light(g), ground: Rgba { a: 1.0, ..g } },
            None => Chrome { dark: true, ground: DARK_GROUND },
        }
    }

    /// The control room's table for this window: its tab strip, its panel
    /// and its pane frames all draw from it.
    pub fn theme(&self) -> &'static Theme {
        theme(self.dark)
    }

    pub fn buttons(&self) -> Buttons {
        if self.dark {
            Buttons {
                glyph: rgb(0xd0, 0xd0, 0xd0),
                glyph_dim: rgb(0x80, 0x80, 0x80),
                hover: rgb(0x3d, 0x3f, 0x40),
                hover_soft: rgb(0x2d, 0x2f, 0x30),
                text: rgb(0xa0, 0xa0, 0xa0),
                text_hot: rgb(0xff, 0xff, 0xff),
            }
        } else {
            let t = self.theme();
            Buttons {
                glyph: rgb(0x40, 0x40, 0x40),
                glyph_dim: rgb(0x8a, 0x8a, 0x8a),
                hover: tabstrip::hover_color(self.ground, t),
                hover_soft: over(self.ground, rgb(0, 0, 0), 0.04),
                text: t.text_secondary,
                text_hot: t.text,
            }
        }
    }
}

/// A colour as a `COLORREF`, which is `0x00BBGGRR`.
pub fn bgr(c: Rgba) -> u32 {
    (c.b as u32) << 16 | (c.g as u32) << 8 | c.r as u32
}

/// A `COLORREF` back to a colour.
pub fn from_bgr(c: u32) -> Rgba {
    rgb((c & 0xff) as u8, (c >> 8 & 0xff) as u8, (c >> 16 & 0xff) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one rule the person asked to have a test: **a background that
    /// cannot be read is dark**, and the strip keeps the colour it had.
    #[test]
    fn an_unreadable_background_is_dark() {
        let c = Chrome::of(None);
        assert!(c.dark, "no background must mean dark");
        assert_eq!(c.ground, DARK_GROUND);
        assert!(c.theme().dark);
    }

    #[test]
    fn the_terminals_background_decides_and_is_the_ground() {
        let white = rgb(0xff, 0xff, 0xff);
        let w = Chrome::of(Some(white));
        assert!(!w.dark, "a white terminal is a light window");
        assert_eq!(w.ground, white);
        assert!(!w.theme().dark);

        let solarized_light = rgb(0xfd, 0xf6, 0xe3);
        assert!(!Chrome::of(Some(solarized_light)).dark);

        let ghostty = rgb(0x28, 0x2c, 0x34);
        let g = Chrome::of(Some(ghostty));
        assert!(g.dark);
        assert_eq!(g.ground, ghostty);
    }

    /// The macOS weights and its strict comparison: pure green is light,
    /// pure red and pure blue are not, and a grey of exactly one half is
    /// dark.
    #[test]
    fn light_is_the_macos_luminance_above_one_half() {
        assert!(is_light(rgb(0, 255, 0)));
        assert!(!is_light(rgb(255, 0, 0)));
        assert!(!is_light(rgb(0, 0, 255)));
        // 127.5 is not a byte; 128 is just over, 127 just under.
        assert!(is_light(rgb(128, 128, 128)));
        assert!(!is_light(rgb(127, 127, 127)));
    }

    /// A translucent background is still a colour to decide by; the strip
    /// is painted opaque.
    #[test]
    fn the_ground_is_opaque() {
        let c = Chrome::of(Some(Rgba { r: 0xff, g: 0xff, b: 0xff, a: 0.4 }));
        assert_eq!(c.ground.a, 1.0);
    }

    /// In the dark the strip's buttons keep the values they always had.
    #[test]
    fn the_dark_buttons_are_the_old_ones() {
        let b = Chrome::of(None).buttons();
        assert_eq!(bgr(b.glyph), 0x00d0d0d0);
        assert_eq!(bgr(b.hover), 0x00403f3d);
        assert_eq!(bgr(b.hover_soft), 0x00302f2d);
        assert_eq!(bgr(b.text), 0x00a0a0a0);
        assert_eq!(bgr(b.text_hot), 0x00ffffff);
    }

    #[test]
    fn the_light_buttons_are_readable_on_the_ground() {
        let c = Chrome::of(Some(rgb(0xff, 0xff, 0xff)));
        let b = c.buttons();
        assert!(!is_light(b.glyph) && !is_light(b.text_hot), "light chrome needs dark glyphs");
        assert!(is_light(b.hover), "and a light hover");
    }

    #[test]
    fn bgr_round_trips() {
        let c = rgb(0x12, 0x34, 0x56);
        assert_eq!(bgr(c), 0x00563412);
        assert_eq!(from_bgr(bgr(c)), c);
    }
}
