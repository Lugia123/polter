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

use windows::Win32::Foundation::{COLORREF, HWND};
use windows::Win32::Graphics::Gdi::{
    CreateSolidBrush, DeleteObject, GetSysColor, SetBkColor, SetTextColor, COLOR_BTNFACE,
    COLOR_BTNSHADOW, COLOR_BTNTEXT, COLOR_GRAYTEXT, COLOR_HIGHLIGHT, COLOR_HIGHLIGHTTEXT,
    COLOR_WINDOW, COLOR_WINDOWTEXT, HBRUSH, HDC,
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

/// The ground a window paints behind everything else.
pub fn bg() -> u32 {
    if high_contrast() {
        sys(COLOR_BTNFACE)
    } else {
        0x0020_1f1d
    }
}

/// An inset area: a list column, a results pane.
pub fn panel() -> u32 {
    if high_contrast() {
        sys(COLOR_WINDOW)
    } else {
        0x0028_2725
    }
}

/// A box that floats over the terminal: the title box, and anything else that
/// has no border to separate it from what is behind it. **Lighter than `bg`
/// on purpose**: a floating box the same colour as a near-black terminal is a
/// box nobody can see the edge of.
pub fn float_bg() -> u32 {
    if high_contrast() {
        sys(COLOR_BTNFACE)
    } else {
        0x0040_3f3d
    }
}

/// A text field's interior, which is deeper than the ground so it reads as a
/// place to type rather than a patch of background.
pub fn field_bg() -> u32 {
    if high_contrast() {
        sys(COLOR_WINDOW)
    } else {
        0x0017_1615
    }
}

pub fn text() -> u32 {
    if high_contrast() {
        sys(COLOR_WINDOWTEXT)
    } else {
        0x00ff_ffff
    }
}

/// Secondary text: a help line, a summary, a row that is switched off.
pub fn dim() -> u32 {
    if high_contrast() {
        sys(COLOR_GRAYTEXT)
    } else {
        0x00a0_a0a0
    }
}

/// The selected row **and the text on it**, taken as a pair: a highlight with
/// unrelated text over it is unreadable exactly on the themes nobody tested.
pub fn sel() -> u32 {
    if high_contrast() {
        sys(COLOR_HIGHLIGHT)
    } else {
        0x0040_3f3d
    }
}

pub fn sel_text() -> u32 {
    if high_contrast() {
        sys(COLOR_HIGHLIGHTTEXT)
    } else {
        0x00ff_ffff
    }
}

/// A button at rest, and the three states it moves through.
pub fn btn_face() -> u32 {
    if high_contrast() {
        sys(COLOR_BTNFACE)
    } else {
        0x0032_3130
    }
}

pub fn btn_hot() -> u32 {
    if high_contrast() {
        sys(COLOR_BTNFACE)
    } else {
        0x0043_4241
    }
}

pub fn btn_down() -> u32 {
    if high_contrast() {
        sys(COLOR_BTNFACE)
    } else {
        0x0026_2524
    }
}

pub fn btn_text() -> u32 {
    if high_contrast() {
        sys(COLOR_BTNTEXT)
    } else {
        0x00ff_ffff
    }
}

/// The line around a control. Also the focus rectangle's colour, which is
/// brighter than the border on purpose: focus has to be findable by someone
/// who is tabbing, and a border-coloured focus ring is not.
pub fn border() -> u32 {
    if high_contrast() {
        sys(COLOR_BTNSHADOW)
    } else {
        0x0054_5352
    }
}

pub fn focus() -> u32 {
    if high_contrast() {
        sys(COLOR_WINDOWTEXT)
    } else {
        0x0090_8f8e
    }
}

/// **The one colour with no system source.** Nothing in the system palette
/// means "this is a complaint": window, button, text, grey text and highlight
/// are places, not meanings. Borrowing one would give the next reader a name
/// that lies. Under high contrast it gives way to plain window text, because
/// there a fixed red is the thing that stops being readable, and the sentence
/// itself still says what it is.
pub fn warn() -> u32 {
    if high_contrast() {
        sys(COLOR_WINDOWTEXT)
    } else {
        0x0040_40e0
    }
}

thread_local! {
    /// The brush handed back to `WM_CTLCOLOR*`, and the colour it was made for.
    ///
    /// **The system keeps this handle after the message returns**, so it cannot
    /// be a brush created and deleted inside the handler -- that is a use of a
    /// freed object, and it shows up as a control painted in whatever memory
    /// held next, not as a crash. One brush is kept and rebuilt only when the
    /// colour it stands for changes, which is what a theme switch does.
    static FIELD_BRUSH: RefCell<(u32, isize)> = const { RefCell::new((0xffff_ffff, 0)) };
}

/// Answer a `WM_CTLCOLOREDIT` / `WM_CTLCOLORSTATIC` / `WM_CTLCOLORLISTBOX`.
///
/// Returns the brush to hand back, or `None` under high contrast, where the
/// caller must let `DefWindowProc` answer and the system's own colours stand.
pub fn ctl_color(hdc: HDC) -> Option<HBRUSH> {
    if high_contrast() {
        return None;
    }
    let colour = field_bg();
    unsafe {
        SetTextColor(hdc, COLORREF(text()));
        SetBkColor(hdc, COLORREF(colour));
    }
    Some(FIELD_BRUSH.with(|c| {
        let mut cur = c.borrow_mut();
        if cur.0 != colour || cur.1 == 0 {
            if cur.1 != 0 {
                let _ = unsafe { DeleteObject(HBRUSH(cur.1 as *mut _).into()) };
            }
            let b = unsafe { CreateSolidBrush(COLORREF(colour)) };
            *cur = (colour, b.0 as isize);
        }
        HBRUSH(cur.1 as *mut _)
    }))
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
