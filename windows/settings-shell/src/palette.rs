//! The colours of the windows that have no terminal in them -- settings,
//! projects -- in the system's light and in its dark (task 1550).
//!
//! **These follow the system, not a terminal.** The macOS settings window is
//! drawn in system colours, so it is light when the Mac is; the Windows host
//! asks `AppsUseLightTheme` and takes a table from here. A terminal window
//! follows its terminal's background instead (`polter_control_room::chrome`).
//!
//! The dark table is the one `theme.rs` has always had, unchanged. The light
//! one was read off the macOS window itself
//! (`verify-cr-09/1504-8-light.png`): white ground and list, #DCDCDC behind
//! the selected row, #747474 for secondary text.
//!
//! All values are `COLORREF`s, `0x00BBGGRR`.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Palette {
    pub bg: u32,
    pub panel: u32,
    pub float_bg: u32,
    pub field_bg: u32,
    pub text: u32,
    pub dim: u32,
    pub sel: u32,
    pub sel_text: u32,
    pub btn_face: u32,
    pub btn_hot: u32,
    pub btn_down: u32,
    pub btn_text: u32,
    pub border: u32,
    pub focus: u32,
    /// The link colour when the system's accent cannot be read: the macOS
    /// link colour for this appearance.
    pub link: u32,
    pub warn: u32,
}

const fn rgb(c: u32) -> u32 {
    // Written as #RRGGBB below, so a reader can compare them with a picture.
    (c & 0xff) << 16 | (c & 0xff00) | (c >> 16 & 0xff)
}

pub const DARK: Palette = Palette {
    bg: 0x0020_1f1d,
    panel: 0x0028_2725,
    float_bg: 0x0040_3f3d,
    field_bg: 0x0017_1615,
    text: 0x00ff_ffff,
    dim: 0x00a0_a0a0,
    sel: 0x0040_3f3d,
    sel_text: 0x00ff_ffff,
    btn_face: 0x0032_3130,
    btn_hot: 0x0043_4241,
    btn_down: 0x0026_2524,
    btn_text: 0x00ff_ffff,
    border: 0x0054_5352,
    focus: 0x0090_8f8e,
    link: 0x00ff_9c41,
    warn: 0x0040_40e0,
};

pub const LIGHT: Palette = Palette {
    bg: rgb(0xFFFFFF),
    panel: rgb(0xFFFFFF),
    float_bg: rgb(0xFFFFFF),
    field_bg: rgb(0xFFFFFF),
    text: rgb(0x262626),
    dim: rgb(0x747474),
    sel: rgb(0xDCDCDC),
    sel_text: rgb(0x262626),
    btn_face: rgb(0xE5E5E5),
    btn_hot: rgb(0xDADADA),
    btn_down: rgb(0xCDCDCD),
    btn_text: rgb(0x262626),
    border: rgb(0xD4D4D4),
    focus: rgb(0x8A8A8A),
    link: rgb(0x0068DA),
    warn: rgb(0xC42B1C),
};

pub const fn of(light: bool) -> &'static Palette {
    if light {
        &LIGHT
    } else {
        &DARK
    }
}

/// Is the system light, from `AppsUseLightTheme`? A value that could not be
/// read is light, which is what Windows itself does with a missing key.
pub fn system_light(apps_use_light: Option<u32>) -> bool {
    apps_use_light != Some(0)
}

/// The link colour from the system's accent: the `AccentPalette` value,
/// eight RGBA entries from the lightest shade to the darkest. **On a dark
/// ground the second-lightest, on a light one the first darker shade** --
/// the base accent itself (#0078D4 by default) is too dark to read as text
/// on the dark ground and the lightest shades vanish on white. `None` when
/// the value is not 32 bytes; the caller then uses [`Palette::link`].
pub fn accent_link(accent_palette: &[u8], light: bool) -> Option<u32> {
    if accent_palette.len() != 32 {
        return None;
    }
    let i = if light { ACCENT_DARK1 } else { ACCENT_LIGHT2 };
    let e = &accent_palette[i * 4..i * 4 + 3];
    Some((e[2] as u32) << 16 | (e[1] as u32) << 8 | e[0] as u32)
}

const ACCENT_LIGHT2: usize = 1;
const ACCENT_DARK1: usize = 4;

/// What a default button is filled with, and its text: the accent, as on
/// both systems. Under the dark table the text is black, as Windows 11 sets
/// its own accent buttons there; under the light one, white.
pub fn accent_button(accent: u32, light: bool) -> (u32, u32) {
    (accent, if light { 0x00ff_ffff } else { 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The dark table is the one the host had before there was a light
    /// one: a change here is a change to every dark window, made by
    /// accident.
    #[test]
    fn the_dark_table_is_the_one_there_was() {
        assert_eq!(DARK.bg, 0x0020_1f1d);
        assert_eq!(DARK.text, 0x00ff_ffff);
        assert_eq!(DARK.link, 0x00ff_9c41);
        assert_eq!(DARK.warn, 0x0040_40e0);
    }

    /// The light table is the macOS window's, read off its picture.
    #[test]
    fn the_light_table_is_the_macos_windows() {
        assert_eq!(LIGHT.bg, 0x00ff_ffff);
        assert_eq!(LIGHT.sel, 0x00dc_dcdc);
        assert_eq!(LIGHT.dim, 0x0074_7474);
        // #0068DA, written BGR.
        assert_eq!(LIGHT.link, 0x00da_6800);
    }

    /// Text has to be readable on every ground it is drawn on, in both
    /// tables: dark on light and light on dark, by a clear margin.
    #[test]
    fn text_contrasts_with_its_grounds() {
        fn luma(c: u32) -> f64 {
            let (r, g, b) = ((c & 0xff) as f64, (c >> 8 & 0xff) as f64, (c >> 16 & 0xff) as f64);
            (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        for p in [&DARK, &LIGHT] {
            for (fg, bgs) in [
                (p.text, vec![p.bg, p.panel, p.field_bg, p.float_bg]),
                (p.sel_text, vec![p.sel]),
                (p.btn_text, vec![p.btn_face, p.btn_hot, p.btn_down]),
            ] {
                for bg in bgs {
                    assert!((luma(fg) - luma(bg)).abs() > 0.5, "{fg:06x} on {bg:06x}");
                }
            }
            assert!((luma(p.dim) - luma(p.bg)).abs() > 0.25, "secondary text on the ground");
        }
    }

    #[test]
    fn a_missing_setting_is_light_and_zero_is_dark() {
        assert!(system_light(None));
        assert!(system_light(Some(1)));
        assert!(!system_light(Some(0)));
    }

    /// The default blue's `AccentPalette`, as Windows 11 writes it.
    const DEFAULT_BLUE: [u8; 32] = [
        0x99, 0xeb, 0xff, 0x00, 0x4c, 0xc2, 0xff, 0x00, 0x00, 0x91, 0xf8, 0x00, 0x00, 0x78, 0xd4, 0x00, 0x00, 0x67,
        0xc0, 0x00, 0x00, 0x3e, 0x92, 0x00, 0x00, 0x1a, 0x68, 0x00, 0xf7, 0x63, 0x0c, 0x00,
    ];

    #[test]
    fn the_accent_link_is_a_lighter_shade_on_dark_and_a_darker_one_on_light() {
        // #4CC2FF and #0067C0, as COLORREFs.
        assert_eq!(accent_link(&DEFAULT_BLUE, false), Some(0x00ff_c24c));
        assert_eq!(accent_link(&DEFAULT_BLUE, true), Some(0x00c0_6700));
        assert_eq!(accent_link(&DEFAULT_BLUE[..31], true), None);
        assert_eq!(accent_link(&[], false), None);
    }
}
