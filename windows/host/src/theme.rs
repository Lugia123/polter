//! One place the port's colours come from.
//!
//! **Four windows used to keep four private copies of this palette** -- the
//! settings page (with the error and about boxes), the command palette, the
//! search bar and the title box -- and the day one of them changed was the day
//! the app was half one colour and half another. That is not a hypothetical
//! shape here: it is exactly how this started, with a dark page drawn by us
//! around light controls drawn by the system.
//!
//! So the palette lives here and the four ask for it. A colour is a function,
//! never a `static`: it is read at the moment it is painted, because a value
//! captured at startup is a copy again, and its symptom -- "it does not follow
//! a theme change" -- is indistinguishable from having no shared source at
//! all.
//!
//! # High contrast wins, always
//!
//! Every function below returns a **system** colour when a high-contrast theme
//! is on, and the drawing code asks [`custom_drawing`] before it paints a
//! control itself. A person who has turned on high contrast has told the
//! system what they need to be able to read; an app that paints its own dark
//! buttons over that has taken it away, silently, from the people least able
//! to work around it. That is why the fallback is not a preference here but
//! the first thing every one of these functions does.

use std::cell::RefCell;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM};
use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_BINARY, RRF_RT_REG_DWORD};
use windows::Win32::Graphics::Gdi::{
    CreateSolidBrush, GetSysColor, SetBkColor, SetTextColor, COLOR_BTNFACE,
    COLOR_BTNSHADOW, COLOR_BTNTEXT, COLOR_GRAYTEXT, COLOR_HIGHLIGHT, COLOR_HIGHLIGHTTEXT,
    COLOR_HOTLIGHT, COLOR_WINDOW, COLOR_WINDOWTEXT, HBRUSH, HDC,
};
use windows::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
use windows::Win32::UI::WindowsAndMessaging::{
    SystemParametersInfoW, SPI_GETHIGHCONTRAST, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
};

/// Is a high-contrast theme on?
///
/// **Asked every time rather than cached**, for the same reason the colours
/// are: it can be switched on while the program is running, by a keyboard
/// shortcut that exists precisely so it can be reached in a hurry.
pub fn high_contrast() -> bool {
    let mut hc = HIGHCONTRASTW {
        cbSize: std::mem::size_of::<HIGHCONTRASTW>() as u32,
        ..Default::default()
    };
    let ok = unsafe {
        SystemParametersInfoW(
            SPI_GETHIGHCONTRAST,
            hc.cbSize,
            Some(&mut hc as *mut _ as *mut _),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    ok.is_ok() && hc.dwFlags.contains(HCF_HIGHCONTRASTON)
}

/// May this port draw a control itself?
///
/// `false` under high contrast, and every drawing path is written to ask
/// before it paints. **A custom-drawn control in high contrast is the defect**,
/// not a cosmetic difference: the system colours are the accessibility
/// contract, and painting over them is opting a person out of it without
/// telling them.
pub fn custom_drawing() -> bool {
    !high_contrast()
}

fn sys(i: windows::Win32::Graphics::Gdi::SYS_COLOR_INDEX) -> u32 {
    unsafe { GetSysColor(i) }
}

// ------------------------------------------------------------ which table
//
// **Two kinds of window, two rules** (task 1550, the macOS rules):
//
// * the settings and project windows have no terminal in them and follow
//   **the system's** light or dark, as the macOS settings window does with
//   its system colours -- [`system`], and every bare function below;
// * what is drawn over or around a terminal -- the command palette, the
//   search bar, the title box -- follows **that terminal's background**, as
//   everything in a macOS terminal window does -- [`for_frame`].
//
// Both are asked at the moment of painting, like everything else here.

/// Is the system's app mode light (`AppsUseLightTheme`)? **Read every time**:
/// switching it sends `WM_SETTINGCHANGE` with `ImmersiveColorSet`, and a value
/// kept from before that message is the stale half of a half-switched window.
pub fn system_light() -> bool {
    polter_settings_shell::palette::system_light(read_dword(
        w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        w!("AppsUseLightTheme"),
    ))
}

fn read_dword(key: PCWSTR, name: PCWSTR) -> Option<u32> {
    let mut value = 0u32;
    let mut len = std::mem::size_of::<u32>() as u32;
    let read = unsafe {
        RegGetValueW(HKEY_CURRENT_USER, key, name, RRF_RT_REG_DWORD, None, Some(&mut value as *mut u32 as *mut _), Some(&mut len))
    };
    read.is_ok().then_some(value)
}

/// The system accent's eight shades (`AccentPalette`), or nothing when the
/// system does not have them -- Windows before 10 1809, or a policy that
/// removed the key -- in which case the links take the macOS link colour.
fn accent_palette() -> Vec<u8> {
    let mut buf = [0u8; 32];
    let mut len = buf.len() as u32;
    let read = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent"),
            w!("AccentPalette"),
            RRF_RT_REG_BINARY,
            None,
            Some(buf.as_mut_ptr() as *mut _),
            Some(&mut len),
        )
    };
    if read.is_ok() {
        buf[..(len as usize).min(32)].to_vec()
    } else {
        Vec::new()
    }
}

/// One table: light or dark, with high contrast still deciding first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Set {
    pub light: bool,
}

/// The settings and project windows' table: the system's.
pub fn system() -> Set {
    Set { light: system_light() }
}

/// The table for what is drawn over the terminal in `frame`: its
/// background's (`polter_control_room::chrome`).
pub fn for_frame(frame: HWND) -> Set {
    Set { light: !crate::termcolor::chrome(frame).dark }
}

/// The table for a box over a terminal -- the command palette, the search
/// bar, the title box -- found from the box itself: its owner, or the window
/// it is a child of, is the terminal window it floats over.
pub fn for_window(hwnd: HWND) -> Set {
    use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, GA_ROOTOWNER};
    for_frame(unsafe { GetAncestor(hwnd, GA_ROOTOWNER) })
}

macro_rules! colours {
    ($($(#[$doc:meta])* $name:ident: $sys:ident;)*) => {
        impl Set {
            $(
                $(#[$doc])*
                pub fn $name(&self) -> u32 {
                    if high_contrast() {
                        sys($sys)
                    } else {
                        polter_settings_shell::palette::of(self.light).$name
                    }
                }
            )*
        }
        $(
            $(#[$doc])*
            #[allow(dead_code)]
            pub fn $name() -> u32 {
                system().$name()
            }
        )*
    };
}

colours! {
    /// The ground a window paints behind everything else.
    bg: COLOR_BTNFACE;
    /// An inset area: a list column, a results pane.
    panel: COLOR_WINDOW;
    /// A box that floats over the terminal: the title box, and anything else
    /// that has no border to separate it from what is behind it. **Lighter
    /// than `bg` in the dark on purpose**: a floating box the same colour as
    /// a near-black terminal is a box nobody can see the edge of.
    float_bg: COLOR_BTNFACE;
    /// A text field's interior.
    field_bg: COLOR_WINDOW;
    text: COLOR_WINDOWTEXT;
    /// Secondary text: a help line, a summary, a row that is switched off.
    dim: COLOR_GRAYTEXT;
    /// The selected row **and the text on it**, taken as a pair: a highlight
    /// with unrelated text over it is unreadable exactly on the themes nobody
    /// tested.
    sel: COLOR_HIGHLIGHT;
    sel_text: COLOR_HIGHLIGHTTEXT;
    /// A button at rest, and the three states it moves through.
    btn_face: COLOR_BTNFACE;
    btn_hot: COLOR_BTNFACE;
    btn_down: COLOR_BTNFACE;
    btn_text: COLOR_BTNTEXT;
    /// The line around a control.
    border: COLOR_BTNSHADOW;
    /// The focus rectangle's colour, which is further from the ground than
    /// the border on purpose: focus has to be findable by someone who is
    /// tabbing, and a border-coloured focus ring is not.
    focus: COLOR_WINDOWTEXT;
    /// **The one colour with no system source.** Nothing in the system
    /// palette means "this is a complaint"; under high contrast it gives way
    /// to plain window text, and the sentence itself still says what it is.
    warn: COLOR_WINDOWTEXT;
}

impl Set {
    /// Text that goes somewhere when clicked: a link under a row, a search
    /// result's breadcrumb, a link-styled button. **The system's accent**,
    /// in the shade that reads on this table's ground; the macOS link colour
    /// when the accent cannot be read.
    pub fn link(&self) -> u32 {
        if high_contrast() {
            return sys(COLOR_HOTLIGHT);
        }
        polter_settings_shell::palette::accent_link(&accent_palette(), self.light)
            .unwrap_or(polter_settings_shell::palette::of(self.light).link)
    }

    /// A default button: the accent behind, and the text that reads on it.
    /// `None` under high contrast, where a default button is the system's.
    pub fn default_button(&self) -> Option<(u32, u32)> {
        (!high_contrast()).then(|| polter_settings_shell::palette::accent_button(self.link(), self.light))
    }

    /// Answer a `WM_CTLCOLOR*` from this table. See [`ctl_color`].
    pub fn ctl_color(&self, hdc: HDC) -> Option<HBRUSH> {
        if high_contrast() {
            return None;
        }
        field_brush(hdc, self.text(), self.field_bg())
    }

    /// The scroll bars of a list or a multi-line box, in this table's light
    /// or dark (`DarkMode_Explorer` or `Explorer`, the only two the system
    /// has). Nothing under high contrast, where they are the system's.
    pub fn dress_scrollbars(&self, h: HWND) {
        use windows::Win32::UI::Controls::SetWindowTheme;
        if high_contrast() || h.0.is_null() {
            return;
        }
        let name = if self.light { w!("Explorer") } else { w!("DarkMode_Explorer") };
        let _ = unsafe { SetWindowTheme(h, name, PCWSTR::null()) };
    }

    /// Tell the window manager whether to draw this window's caption dark.
    /// The settings and project windows have the system's caption, and a
    /// light page under a dark caption is the half-and-half this module is
    /// against.
    pub fn dress_caption(&self, win: HWND) {
        use windows::core::BOOL;
        use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWINDOWATTRIBUTE};
        let dark: BOOL = (!self.light && !high_contrast()).into();
        // DWMWA_USE_IMMERSIVE_DARK_MODE, as `shell.rs` names it.
        let _ = unsafe { DwmSetWindowAttribute(win, DWMWINDOWATTRIBUTE(20), &dark as *const BOOL as *const _, std::mem::size_of::<BOOL>() as u32) };
    }
}

/// See [`Set::link`].
pub fn link() -> u32 {
    system().link()
}

/// Is this `WM_SETTINGCHANGE` the system switching light and dark (or its
/// accent)? Those arrive with the string `ImmersiveColorSet`, and **they are
/// the only notice there is**: no `WM_THEMECHANGED` is sent for them.
pub fn is_colour_change(lparam: LPARAM) -> bool {
    if lparam.0 == 0 {
        return false;
    }
    let s = unsafe { PCWSTR(lparam.0 as *const u16).to_string() };
    s.map(|s| s == "ImmersiveColorSet").unwrap_or(false)
}

thread_local! {
    /// The brushes handed back to `WM_CTLCOLOR*`, one per colour.
    ///
    /// **The system keeps this handle after the message returns**, so it cannot
    /// be a brush created and deleted inside the handler -- that is a use of a
    /// freed object, and it shows up as a control painted in whatever memory
    /// held next, not as a crash. **And none is ever deleted**: with a light
    /// settings window and a dark command palette open together, one brush
    /// rebuilt per colour change would be deleted under whichever window
    /// asked first. There are only as many as there are field colours in the
    /// two tables and the high-contrast one, so the list stays a handful.
    static FIELD_BRUSHES: RefCell<Vec<(u32, isize)>> = const { RefCell::new(Vec::new()) };
}

/// Answer a `WM_CTLCOLOREDIT` / `WM_CTLCOLORSTATIC` / `WM_CTLCOLORLISTBOX`.
///
/// Returns the brush to hand back, or `None` under high contrast, where the
/// caller must let `DefWindowProc` answer and the system's own colours stand.
pub fn ctl_color(hdc: HDC) -> Option<HBRUSH> {
    system().ctl_color(hdc)
}

/// Answer a `WM_CTLCOLORSTATIC` for a read-only box that is words on the
/// page rather than a field -- About's values: text on the window's ground.
pub fn on_ground(hdc: HDC) -> Option<HBRUSH> {
    if high_contrast() {
        return None;
    }
    field_brush(hdc, text(), bg())
}

fn field_brush(hdc: HDC, text: u32, colour: u32) -> Option<HBRUSH> {
    unsafe {
        SetTextColor(hdc, COLORREF(text));
        SetBkColor(hdc, COLORREF(colour));
    }
    Some(FIELD_BRUSHES.with(|c| {
        let mut all = c.borrow_mut();
        if let Some((_, b)) = all.iter().find(|(c, _)| *c == colour) {
            return HBRUSH(*b as *mut _);
        }
        let b = unsafe { CreateSolidBrush(COLORREF(colour)) };
        all.push((colour, b.0 as isize));
        b
    }))
}

/// A selected row's highlight: `r` filled with round corners, `radius`
/// pixels -- the macOS `SettingsRow`'s 6, scaled (task 1550).
pub fn fill_round(hdc: HDC, r: &windows::Win32::Foundation::RECT, radius: i32, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        let old_brush = windows::Win32::Graphics::Gdi::SelectObject(hdc, b.into());
        let old_pen = windows::Win32::Graphics::Gdi::SelectObject(hdc, windows::Win32::Graphics::Gdi::GetStockObject(windows::Win32::Graphics::Gdi::NULL_PEN));
        // One past the right and bottom, as GDI's rectangles stop short.
        let _ = windows::Win32::Graphics::Gdi::RoundRect(hdc, r.left, r.top, r.right + 1, r.bottom + 1, radius * 2, radius * 2);
        windows::Win32::Graphics::Gdi::SelectObject(hdc, old_pen);
        windows::Win32::Graphics::Gdi::SelectObject(hdc, old_brush);
        let _ = windows::Win32::Graphics::Gdi::DeleteObject(b.into());
    }
}

/// Repaint a window and its controls after the theme changed.
pub fn repaint_all(win: HWND) {
    unsafe {
        use windows::Win32::Graphics::Gdi::{
            RedrawWindow, RDW_ALLCHILDREN, RDW_ERASE, RDW_INVALIDATE,
        };
        // **Children too, which is the whole reason this is not
        // `InvalidateRect`.** An `EDIT` keeps its old background until it is
        // asked again, so a page that repainted only itself would come back
        // half in the new colours and half in the old -- the exact look this
        // module exists to prevent, arrived at by fixing it.
        let _ = RedrawWindow(
            Some(win),
            None,
            None,
            RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
        );
    }
}
