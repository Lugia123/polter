//! The plugin page, the config-error list, and the about box.
//!
//! **Three windows in one file because they are one shape**: a modeless popup
//! over the frame, a list on the left, detail on the right, and nothing that
//! the terminal underneath needs to know about. Splitting them would repeat
//! the class registration, the font and the paint path three more times --
//! `hud.rs` already makes that argument for its two.
//!
//! **What the host is allowed to decide here: nothing.**
//!
//! | thing on screen | where it comes from |
//! | --- | --- |
//! | the plugin list | `plugin.json` on disk, via `plugins::catalog` |
//! | which control a parameter gets | the manifest's schema, via `plugins::Control` |
//! | the config errors | `ghostty_config_diagnostics_count` / `_get_diagnostic` |
//! | version and build | `ghostty_info()` |
//!
//! **The one exception is spelled out where it happens**: a schema this build
//! cannot turn into a control falls back to a text box rather than being
//! hidden, because refusing to show a setting is how a plugin ends up
//! unconfigurable with no error anywhere.
//!
//! **Controls are real child windows**, not painted rectangles: `EDIT`,
//! `COMBOBOX` and a checkbox `BUTTON` bring their own caret, selection,
//! keyboard handling and -- the expensive one -- their own TSF document, so a
//! parameter value can be typed in Chinese without this file implementing an
//! `ITextStoreACP`. The focus contract that comes with borrowing them lives in
//! `overlay.rs`.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::plogf;
use crate::plugins::{self, Control, Plugin};

const WM_SETTINGS_TOGGLE: u32 = WM_APP + 8;
const WM_ERRORS_SHOW: u32 = WM_APP + 9;
/// Show the about box, asked for from somewhere that is not this window --
/// the main menu's «About Polter». Posted rather than called so the window
/// that owns the about box is the one that shows it.
const WM_ABOUT_SHOW: u32 = WM_APP + 10;

const W: i32 = 720;
const H: i32 = 460;
const LIST_W: i32 = 220;
const ROW_H: i32 = 30;
const PAD: i32 = 12;
const FIELD_H: i32 = 26;
/// The name line, above the summary. Fixed: it is one line by construction.
const NAME_H: i32 = 24;
/// How tall the summary and the subscription line are allowed to grow before
/// the text is cut instead.
///
/// **Growth is honest until it starts pushing the controls off the page.** A
/// plugin's self-description is written by its author and can be any length;
/// a page that grew to fit it would eventually put the Save button below the
/// bottom edge, where nothing says it is there. Past this, the text is
/// ellipsised -- a visible cut rather than an invisible one.
const HEAD_MAX_H: i32 = 150;

/// How tall the block above the first control is, **measured, not assumed**.
///
/// Returns the tops and heights the painter draws at and the y the controls
/// start at, so that the two functions cannot disagree: they were two copies
/// of one constant, and when the summary started being read (it had been an
/// empty string, because the reader looked for a field the manifests do not
/// have) that constant was 22px of room for text that wraps to three lines.
/// The result was the summary printed under the subscription line and the
/// checkbox, letters on top of letters.
///
/// **Measuring is what makes the length the author's business rather than
/// ours.** A bigger constant only moves the number at which it breaks.
fn head_layout(win: HWND, p: &Plugin) -> (RECT, RECT, i32) {
    let sc = dpi_scale(win);
    let s = |v: i32| v * sc / 96;
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let left = s(LIST_W + PAD * 2);
    let right = rc.right - s(PAD);

    let measure = |text: &str, top: i32| -> RECT {
        let mut r = RECT { left, top, right, bottom: top + s(HEAD_MAX_H) };
        if text.is_empty() {
            r.bottom = top;
            return r;
        }
        unsafe {
            let hdc = GetDC(Some(win));
            let font = font();
            let old = SelectObject(hdc, font.into());
            let mut wide: Vec<u16> = text.encode_utf16().collect();
            // `DT_CALCRECT` fills the rectangle instead of drawing; the width
            // is fixed and the height comes back.
            DrawTextW(hdc, &mut wide, &mut r, DT_LEFT | DT_WORDBREAK | DT_CALCRECT);
            SelectObject(hdc, old);
            ReleaseDC(Some(win), hdc);
        }
        r.right = right;
        r.bottom = r.bottom.min(top + s(HEAD_MAX_H));
        r
    };

    let summary = measure(&p.summary, s(PAD + NAME_H));
    let sub_top = if p.summary.is_empty() { summary.bottom } else { summary.bottom + s(6) };
    let subscription = measure(&subscription_line(&p.events), sub_top);
    (summary, subscription, subscription.bottom + s(10))
}

/// What this build can say about an event, one phrase each.
///
/// **Presentation and nothing else**, which is the whole difference from a
/// list that decides behaviour: an event missing from here costs a phrase,
/// not a plugin. The page shows the raw wire name for anything not in it, so
/// an event added after this build still leaves the subscription visible --
/// a plugin that says nothing about itself is the shape this replaced.
///
/// **English only, and that is a known gap, not an oversight.** This host has
/// no gettext; macOS runs these three through `String(localized:)`. A Chinese
/// reader therefore gets a translated summary from the plugin's own sidecar
/// and this line in English, which reads worse than all-English -- written
/// down in the report rather than left to be discovered.
const EVENT_PHRASES: &[(&str, &str)] = &[
    ("chat", "Keeps the conversations"),
    ("terminal.quiet", "Notifies you"),
    ("provision", "Sets your agent up to reach Polter"),
];

/// One line saying what a plugin is handed.
///
/// Phrases where this build has one, wire names where it has not, **both from
/// the same table** so "which events do we have a phrase for" is answered in
/// one place. Nothing at all is not an option: a plugin that subscribes to
/// nothing is not started, and saying so is more use than an empty list.
fn subscription_line(events: &[String]) -> String {
    if events.is_empty() {
        return "Subscribes to nothing, so Polter has nothing to hand it and will not start it."
            .to_string();
    }
    let mut said: Vec<String> = Vec::new();
    for (wire, phrase) in EVENT_PHRASES {
        if events.iter().any(|e| e == wire) {
            said.push((*phrase).to_string());
        }
    }
    for e in events {
        if !EVENT_PHRASES.iter().any(|(wire, _)| wire == e) {
            said.push(e.clone());
        }
    }
    format!("What it is handed: {}", said.join(", "))
}

// ------------------------------------------------------------------ colour
//
// **The palette is not here any more.** It was six literals in this file, and
// three other windows had their own copies of the same idea; the day one of
// them changed, the app was half one colour and half another. `theme.rs` is
// the single source now, and it is also what answers "is high contrast on",
// which every drawing path below has to ask before it paints a control
// itself.
//
// The names below are this page's vocabulary for that palette, not a second
// copy of it: each one is a call.

use crate::theme;

/// Control ids. `1..` are parameter fields, offset by their index.
const ID_ENABLED: usize = 1000;
const ID_SAVE: usize = 1001;
const ID_OPEN_CONFIG: usize = 1002;
const ID_ABOUT: usize = 1003;
const ID_PARAM_BASE: usize = 2000;

static HWND_SETTINGS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_ERRORS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_ABOUT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// The page's font.
///
/// **Out of `ST` on purpose, and this is the fix for a crash rather than a
/// tidy-up.** It is written once in `init` and read nine times, and three of
/// those reads are on the *drawing* path -- `draw_button`, the owner-drawn
/// combo item, the paint handlers. The drawing path is entered synchronously
/// from inside our own code: `SetWindowTextW` on a custom-drawn `BUTTON`
/// sends `WM_NOTIFY`/`NM_CUSTOMDRAW` to **this window's procedure** before it
/// returns. So a `borrow_mut` held across that call met a `borrow` in
/// `draw_button`, and the page aborted the instant it was opened with any
/// plugin installed.
///
/// Narrowing the borrow would have fixed that one call. Taking the value out
/// of the cell means **the drawing path cannot reach the mutable state at
/// all** -- there is no borrow to conflict with, so there is nothing to keep
/// right in a future edit. An `AtomicPtr` rather than a `Cell` for the same
/// reason the three window handles above are: a value read from a paint that
/// might one day arrive on another thread should not silently be a different
/// value there, and a null `HFONT` is *legal* (it means "the system font"),
/// so that mistake would not announce itself.
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

fn font() -> HFONT {
    HFONT(FONT.load(Ordering::Acquire))
}

struct Field {
    /// Parameter name, as the manifest and the settings file spell it.
    name: String,
    hwnd: HWND,
    control: Control,
}

#[derive(Default)]
struct State {
    plugins: Vec<Plugin>,
    selected: usize,
    visible: bool,
    prev_focus: HWND,
    /// One child window per parameter of the selected plugin, rebuilt on
    /// every selection change. Rebuilt rather than reused because the control
    /// *type* changes between plugins, and a `COMBOBOX` cannot become an
    /// `EDIT`.
    fields: Vec<Field>,
    enabled_box: HWND,
    save_btn: HWND,
    /// Set when a required parameter is empty at save time.
    complaint: String,
    errors: Vec<String>,
    /// Created once and kept: unlike the parameter controls these do not
    /// change with the selection, and destroying them on every selection
    /// change is how a button stops responding halfway through a session.
    open_cfg_btn: HWND,
    about_btn: HWND,
}

thread_local! {
    static ST: RefCell<State> = RefCell::new(State::default());
}

fn hwnd() -> HWND {
    HWND(HWND_SETTINGS.load(Ordering::Acquire))
}

fn dpi_scale(h: HWND) -> i32 {
    unsafe { GetDpiForWindow(h) }.max(96) as i32
}

// ------------------------------------------------------------------ setup

pub fn init(hinst: windows::Win32::Foundation::HINSTANCE) {
    unsafe {
        for (proc_fn, class) in [
            (
                settings_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT,
                w!("PolterSettings"),
            ),
            (errors_proc, w!("PolterConfigErrors")),
            (about_proc, w!("PolterAbout")),
        ] {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                style: CS_DROPSHADOW,
                lpfnWndProc: Some(proc_fn),
                hInstance: hinst,
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hbrBackground: HBRUSH(std::ptr::null_mut()),
                lpszClassName: class,
                ..Default::default()
            };
            if RegisterClassExW(&wc) == 0 {
                // process-wide: registering the window class, once per process
                plogf!("[set] RegisterClassExW failed");
                return;
            }
        }

        // **No `WS_EX_TOPMOST`.** These three windows had it, which is not
        // "above Polter" -- it is above *everything*, including other programs
        // and the system's own surfaces. A person switched to Notepad and this
        // page was still in front of it. What was wanted all along is an
        // **owned** window: always above the terminal it belongs to,
        // minimising and restoring with it, and behind whatever the person
        // switches to. The owner is set at show time; see `own_and_place`.
        let make = |class: PCWSTR, w: i32, h: i32| {
            CreateWindowExW(
                WS_EX_TOOLWINDOW,
                class,
                w!("Polter"),
                WS_POPUP | WS_CLIPCHILDREN,
                0,
                0,
                w,
                h,
                None,
                None,
                Some(hinst),
                None,
            )
        };

        let hs = match make(w!("PolterSettings"), W, H) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the settings window, one per process by the
                // S4-B ruling.
                //
                // **The rest of this line used to read "and no window owns
                // it", and that was a conclusion drawn from the wrong
                // premise.** One page for the process is a fact about how many
                // there are; which terminal window it belongs to is a
                // different question, and the answer is not "none" -- it is
                // "the one it was opened from". Read as a design note, it kept
                // an ownerless, always-on-top window in front of other
                // people's programs.
                plogf!("[set] CreateWindowExW failed: {e:?}");
                return;
            }
        };
        let he = match make(w!("PolterConfigErrors"), 560, 320) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the errors window: one per process
                plogf!("[set] errors CreateWindowExW failed: {e:?}");
                return;
            }
        };

        let sc = dpi_scale(hs);
        let font = CreateFontW(
            -(14 * sc / 96),
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
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

        FONT.store(font.0, Ordering::Release);
        let ha = match make(w!("PolterAbout"), 420, 220) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the about window: one per process
                plogf!("[set] about CreateWindowExW failed: {e:?}");
                return;
            }
        };
        HWND_SETTINGS.store(hs.0, Ordering::Release);
        HWND_ERRORS.store(he.0, Ordering::Release);
        HWND_ABOUT.store(ha.0, Ordering::Release);
        // process-wide: the three windows are up; no terminal window is involved
        plogf!("[set] ready");
    }
}

/// Open or close the plugin page. **Safe from any thread.**
pub fn request_toggle() {
    let h = HWND_SETTINGS.load(Ordering::Acquire);
    if h.is_null() {
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_SETTINGS_TOGGLE, WPARAM(0), LPARAM(0)) };
}

/// Show the about box. **Safe from any thread.**
///
/// **Here rather than a second dialog in `menu.rs`.** A host with two about
/// boxes has two version strings to keep in step, and they disagree exactly
/// when it matters -- in a bug report. Same reason `about_lines` asks the core
/// instead of composing the version itself.
pub fn request_about() {
    let h = HWND_ABOUT.load(Ordering::Acquire);
    if h.is_null() {
        // process-wide: the about window does not exist yet, so no window could be meant
        plogf!("[set] about was asked for before its window existed");
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_ABOUT_SHOW, WPARAM(0), LPARAM(0)) };
}

/// Show the config errors, if the core reported any. **Safe from any thread.**
pub fn request_errors() {
    let h = HWND_ERRORS.load(Ordering::Acquire);
    if h.is_null() {
        return;
    }
    let _ = unsafe { PostMessageW(Some(HWND(h)), WM_ERRORS_SHOW, WPARAM(0), LPARAM(0)) };
}

// ------------------------------------------------------------- parameters

fn set_text(h: HWND, s: &str) {
    let wide: Vec<u16> = s.encode_utf16().chain(Some(0)).collect();
    let _ = unsafe { SetWindowTextW(h, PCWSTR(wide.as_ptr())) };
}

fn get_text(h: HWND) -> String {
    let mut buf = [0u16; 1024];
    let n = unsafe { GetWindowTextW(h, &mut buf) } as usize;
    String::from_utf16_lossy(&buf[..n])
}

// ------------------------------------------------------- drawing controls
//
// **Why the buttons are custom drawn and the fields are not.** A themed
// `EDIT`, `STATIC` or list box asks its parent what colours to use, through
// `WM_CTLCOLOR*`, and honours the answer -- so those need no drawing code at
// all, only an answer. A themed `BUTTON` asks nobody: it is painted by the
// visual style, and the only ways in are to owner-draw it or to answer its
// custom-draw notification. Custom draw is the one that keeps the control's
// own behaviour -- a check box stays an auto check box, `BM_GETCHECK` still
// answers, and the hot state arrives as a flag rather than as mouse tracking
// this file would have to write.
//
// Every path here begins by asking `theme::custom_drawing()`. Under high
// contrast none of them run and the system paints its own controls.

/// The six states a button can be in, drawn from the flags custom draw hands
/// over. **All six, because the ones that are missed are the ones nobody
/// walks through**: a button that is right at rest and light when hot is a
/// defect a person meets by moving the mouse and no screenshot records.
unsafe fn draw_button(cd: &NMCUSTOMDRAW) {
    unsafe {
        let h = cd.hdr.hwndFrom;
        let hdc = cd.hdc;
        let st8 = cd.uItemState;
        let has = |f: NMCUSTOMDRAW_DRAW_STATE_FLAGS| st8.contains(f);
        let (hot, down, disabled, focus, default) = (
            has(CDIS_HOT),
            has(CDIS_SELECTED),
            has(CDIS_DISABLED),
            has(CDIS_FOCUS),
            has(CDIS_DEFAULT),
        );
        let style = GetWindowLongPtrW(h, GWL_STYLE) as u32;
        let kind = (style & BS_TYPEMASK as u32) as i32;
        let is_check = kind == BS_AUTOCHECKBOX || kind == BS_CHECKBOX;

        let mut rc = cd.rc;
        let font = font();
        let old_font = SelectObject(hdc, font.into());
        SetBkMode(hdc, TRANSPARENT);

        let mut text = [0u16; 256];
        let n = GetWindowTextW(h, &mut text) as usize;
        let label = String::from_utf16_lossy(&text[..n]);
        let fg = if disabled { theme::dim() } else { theme::btn_text() };

        if is_check {
            // A check box sits on the page, so its ground is the page's.
            let b = CreateSolidBrush(COLORREF(theme::bg()));
            FillRect(hdc, &rc, b);
            let _ = DeleteObject(b.into());

            let side = (rc.bottom - rc.top).min(16).max(12);
            let top = rc.top + ((rc.bottom - rc.top) - side) / 2;
            let box_r = RECT {
                left: rc.left,
                top,
                right: rc.left + side,
                bottom: top + side,
            };
            let fill = CreateSolidBrush(COLORREF(if hot {
                theme::btn_hot()
            } else {
                theme::field_bg()
            }));
            FillRect(hdc, &box_r, fill);
            let _ = DeleteObject(fill.into());
            frame(hdc, &box_r, if focus { theme::focus() } else { theme::border() });

            let checked = SendMessageW(h, BM_GETCHECK, Some(WPARAM(0)), Some(LPARAM(0))).0 == 1;
            if checked {
                // The tick, as two strokes. A glyph from a font would be a
                // second thing to keep in step with the box's size.
                let pen = CreatePen(PS_SOLID, 2, COLORREF(fg));
                let old = SelectObject(hdc, pen.into());
                let (l, t, r2, b2) = (box_r.left, box_r.top, box_r.right, box_r.bottom);
                let mut pt = POINT::default();
                let _ = MoveToEx(hdc, l + side / 5, t + side / 2, Some(&mut pt));
                let _ = LineTo(hdc, l + side * 2 / 5, b2 - side / 4);
                let _ = LineTo(hdc, r2 - side / 5, t + side / 4);
                SelectObject(hdc, old);
                let _ = DeleteObject(pen.into());
            }

            let mut tr = RECT {
                left: box_r.right + 8,
                top: rc.top,
                right: rc.right,
                bottom: rc.bottom,
            };
            SetTextColor(hdc, COLORREF(fg));
            let wide: Vec<u16> = label.encode_utf16().collect();
            DrawTextW(
                hdc,
                &mut wide.clone(),
                &mut tr,
                DT_LEFT | DT_SINGLELINE | DT_VCENTER,
            );
            SelectObject(hdc, old_font);
            return;
        }

        // A push button: face, border, label, and a focus ring that is a
        // different colour from the border rather than a second border.
        let face = if disabled {
            theme::btn_face()
        } else if down {
            theme::btn_down()
        } else if hot {
            theme::btn_hot()
        } else {
            theme::btn_face()
        };
        let b = CreateSolidBrush(COLORREF(face));
        FillRect(hdc, &rc, b);
        let _ = DeleteObject(b.into());
        frame(
            hdc,
            &rc,
            if default && !disabled {
                theme::focus()
            } else {
                theme::border()
            },
        );
        if focus && !disabled {
            let inner = RECT {
                left: rc.left + 3,
                top: rc.top + 3,
                right: rc.right - 3,
                bottom: rc.bottom - 3,
            };
            frame(hdc, &inner, theme::focus());
        }
        if down {
            // Pressed moves the label a pixel, the way every native button
            // does; without it a click on a button that is already dark
            // gives no feedback at all.
            rc.top += 1;
            rc.left += 1;
        }
        SetTextColor(hdc, COLORREF(fg));
        let wide: Vec<u16> = label.encode_utf16().collect();
        DrawTextW(
            hdc,
            &mut wide.clone(),
            &mut rc,
            DT_CENTER | DT_SINGLELINE | DT_VCENTER,
        );
        SelectObject(hdc, old_font);
    }
}

/// A one pixel rectangle, in a colour, without disturbing the fill.
unsafe fn frame(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        let _ = FrameRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

/// One combo box item: the closed control's own line, and each row of the
/// drop-down list.
///
/// **What this does not reach**, written here because it is the one thing in
/// the port that cannot be made dark: the combo's frame and its drop-down
/// arrow in the closed state, and the drop-down list's border and scroll bar
/// when it is open, are drawn by the visual style. `WM_CTLCOLORLISTBOX`
/// covers the list's background, and this covers every row; the frame around
/// them does not belong to either.
unsafe fn draw_combo_item(dis: &DRAWITEMSTRUCT) {
    unsafe {
        if dis.itemID == u32::MAX {
            let b = CreateSolidBrush(COLORREF(theme::field_bg()));
            FillRect(dis.hDC, &dis.rcItem, b);
            let _ = DeleteObject(b.into());
            return;
        }
        let selected = dis.itemState.0 & ODS_SELECTED.0 != 0;
        let in_edit = dis.itemState.0 & ODS_COMBOBOXEDIT.0 != 0;
        let bg = if selected && !in_edit {
            theme::sel()
        } else {
            theme::field_bg()
        };
        let fg = if selected && !in_edit {
            theme::sel_text()
        } else {
            theme::text()
        };
        let b = CreateSolidBrush(COLORREF(bg));
        FillRect(dis.hDC, &dis.rcItem, b);
        let _ = DeleteObject(b.into());

        let mut buf = [0u16; 256];
        let n = SendMessageW(
            dis.hwndItem,
            CB_GETLBTEXT,
            Some(WPARAM(dis.itemID as usize)),
            Some(LPARAM(buf.as_mut_ptr() as isize)),
        )
        .0;
        if n <= 0 {
            return;
        }
        let font = font();
        let old = SelectObject(dis.hDC, font.into());
        SetBkMode(dis.hDC, TRANSPARENT);
        SetTextColor(dis.hDC, COLORREF(fg));
        let mut r = RECT {
            left: dis.rcItem.left + 4,
            ..dis.rcItem
        };
        let mut wide = buf[..n as usize].to_vec();
        DrawTextW(dis.hDC, &mut wide, &mut r, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        // **Focus has to be findable.** With owner drawing the system stops
        // drawing the combo's focus rectangle and expects this to, and a
        // control that looks identical focused and not is unusable by anyone
        // working from the keyboard.
        if in_edit && dis.itemState.0 & ODS_FOCUS.0 != 0 {
            frame(dis.hDC, &dis.rcItem, theme::focus());
        }
        SelectObject(dis.hDC, old);
    }
}

/// Destroy the current parameter controls and build the selected plugin's.
fn rebuild_fields(win: HWND, hinst: windows::Win32::Foundation::HINSTANCE) {
    let sc = dpi_scale(win);
    let s = |v: i32| v * sc / 96;

    let plugin = ST.with(|c| {
        let st = c.borrow();
        st.plugins.get(st.selected).cloned()
    });
    // Read once, from outside the cell. It used to come out of `ST` in the
    // same borrow as the plugin; it no longer lives there at all.
    let font = font();

    // **Take the handles out, then destroy them with the cell released.**
    //
    // `DestroyWindow` on a visible child makes the parent repaint what the
    // child was covering, and this parent's repaint reads `ST`. Destroying
    // inside the `borrow_mut` was the same shape as the crash below it, one
    // call earlier -- it survived only because the uncovered area happened
    // not to contain a custom-drawn control. That is a property of the
    // layout, not of the code, and it is not one anybody would think to
    // preserve.
    let doomed: Vec<HWND> = ST.with(|c| {
        let mut st = c.borrow_mut();
        let mut v: Vec<HWND> = st.fields.drain(..).map(|f| f.hwnd).collect();
        if !st.enabled_box.0.is_null() {
            v.push(st.enabled_box);
            st.enabled_box = HWND(std::ptr::null_mut());
        }
        if !st.save_btn.0.is_null() {
            v.push(st.save_btn);
            st.save_btn = HWND(std::ptr::null_mut());
        }
        st.complaint.clear();
        v
    });
    for h in doomed {
        unsafe {
            let _ = DestroyWindow(h);
        }
    }

    let Some(p) = plugin else { return };
    let x = s(LIST_W + PAD * 2);
    // The same measurement the painter makes, from the same function: the two
    // used to share a constant, and a constant is what stopped fitting the
    // moment the summary had any text in it.
    let mut y = head_layout(win, &p).2;
    let field_w = s(W - LIST_W - PAD * 4);

    // **Every control this page makes goes through here**, which is why the
    // Escape forwarding is installed here rather than at each call site: a
    // control added later gets it without anybody remembering to.
    let mk = |class: PCWSTR, style: WINDOW_STYLE, yy: i32, hh: i32, id: usize| unsafe {
        let made = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class,
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | style,
            x,
            yy,
            field_w,
            hh,
            Some(win),
            Some(HMENU(id as *mut c_void)),
            Some(hinst),
            None,
        );
        if let Ok(h) = made {
            crate::overlay::forward_escape_to_parent(h);
        }
        made
    };

    // The on/off switch, first, because it is the thing most visits are for.
    let enabled = mk(
        w!("BUTTON"),
        WINDOW_STYLE(BS_AUTOCHECKBOX as u32),
        y,
        s(22),
        ID_ENABLED,
    );
    y += s(32);

    let mut fields = Vec::new();
    for (i, param) in p.params.iter().enumerate() {
        y += s(18); // room for the label the paint draws above the control
        let id = ID_PARAM_BASE + i;
        let cur = p.values.get(&param.name).cloned();

        let h = match &param.control {
            Control::Flag => {
                let h = mk(
                    w!("BUTTON"),
                    WINDOW_STYLE(BS_AUTOCHECKBOX as u32),
                    y,
                    s(22),
                    id,
                );
                if let Ok(h) = h {
                    let on = cur.as_deref().unwrap_or(param.default.as_deref().unwrap_or("false"))
                        == "true";
                    unsafe {
                        SendMessageW(
                            h,
                            BM_SETCHECK,
                            Some(WPARAM(if on { 1 } else { 0 })),
                            Some(LPARAM(0)),
                        );
                    }
                }
                y += s(28);
                h
            }
            Control::Choice(options) => {
                // **`CBS_HASSTRINGS` stays.** Owner drawing here is about
                // paint only: the control keeps the strings, so `CB_GETLBTEXT`
                // and the save path go on reading it the same way. The style
                // is chosen each time the page is built rather than once,
                // because turning high contrast on has to be able to give the
                // system its drawing back -- which is why a theme change
                // rebuilds these controls instead of only repainting them.
                let owner_draw = if theme::custom_drawing() {
                    CBS_OWNERDRAWFIXED
                } else {
                    0
                };
                let h = mk(
                    w!("COMBOBOX"),
                    WINDOW_STYLE((CBS_DROPDOWNLIST | CBS_HASSTRINGS | owner_draw) as u32),
                    y,
                    s(200),
                    id,
                );
                if let Ok(h) = h {
                    for o in options {
                        let wide: Vec<u16> = o.encode_utf16().chain(Some(0)).collect();
                        unsafe {
                            SendMessageW(
                                h,
                                CB_ADDSTRING,
                                Some(WPARAM(0)),
                                Some(LPARAM(wide.as_ptr() as isize)),
                            );
                        }
                    }
                    // **Ask for a list height, out loud.**
                    //
                    // Without this the drop-down is capped at 30 rows -- the
                    // documented default for `CB_SETMINVISIBLE` -- and on the
                    // test machine a 40-option list showed exactly 30 with
                    // **no scroll bar**: `LB_SETTOPINDEX(10)` moved it and
                    // `End` reached item 39, so the list scrolls and the
                    // keyboard arrives; what is missing is the handle, and a
                    // person using the mouse cannot reach item 31.
                    //
                    // **Two things were ruled out before this line was
                    // written, and neither cost a reading of its own:**
                    //
                    //  - *Owner drawing*, by running the same list under high
                    //    contrast, where `custom_drawing()` is false and this
                    //    style bit is not set. No scroll bar there either.
                    //  - *The creation height above*, by putting two existing
                    //    measurements side by side: the list came out 602px
                    //    with our 20px rows and 572px with the system's 19px
                    //    rows -- **thirty rows both times**. A pixel cap
                    //    cannot produce the same row count at two different
                    //    row heights, so the cap is on rows and the height
                    //    passed to `CreateWindowExW` is not participating.
                    //
                    // What is left is not "the control is simply like this":
                    // the documentation says a list with more items than the
                    // minimum grows a scroll bar, so that answer would be a
                    // claim about Windows that Microsoft's own documentation
                    // denies. **The remaining hypothesis is that the sizing
                    // path only runs completely when an application asks**,
                    // and we never have. This line asks.
                    //
                    // 12 rather than a smaller number because the point is a
                    // usable list, not a minimal one; `CB_SETMINVISIBLE` is a
                    // *minimum*, so a three-option plugin still shows three
                    // rows and is unaffected.
                    unsafe {
                        SendMessageW(h, CB_SETMINVISIBLE, Some(WPARAM(12)), Some(LPARAM(0)));
                    }
                    let want = cur.clone().or_else(|| param.default.clone());
                    let idx = want
                        .and_then(|v| options.iter().position(|o| *o == v))
                        .unwrap_or(0);
                    unsafe {
                        SendMessageW(h, CB_SETCURSEL, Some(WPARAM(idx)), Some(LPARAM(0)));
                    }
                }
                y += s(FIELD_H + 6);
                h
            }
            Control::Text => {
                // `ES_PASSWORD` only when the manifest declared it. Guessing
                // would either mask something that is not a secret or, worse,
                // fail to mask one that is.
                // **`WS_BORDER` is dropped when this page does its own
                // drawing.** With visual styles on, that border is painted by
                // the theme in the system's light grey -- a one pixel line
                // around every field that no `WM_CTLCOLOR*` answer can reach,
                // because it is not part of the control's client area. The
                // page draws the frame instead, in the shared border colour.
                // Under high contrast the style comes back and the system
                // draws its own, which is the point.
                let border = if theme::custom_drawing() {
                    WINDOW_STYLE(0)
                } else {
                    WS_BORDER
                };
                let style = if param.secret {
                    WINDOW_STYLE((ES_AUTOHSCROLL | ES_PASSWORD) as u32) | border
                } else {
                    WINDOW_STYLE(ES_AUTOHSCROLL as u32) | border
                };
                let h = mk(w!("EDIT"), style, y, s(FIELD_H), id);
                if let Ok(h) = h {
                    // The stored value, or the schema's default as a starting
                    // point. **The default is shown, not saved** -- writing it
                    // on sight would turn a default into a decision the user
                    // never made.
                    if let Some(v) = cur.as_ref().or(param.default.as_ref()) {
                        set_text(h, v);
                    }
                }
                y += s(FIELD_H + 6);
                h
            }
        };

        if let Ok(h) = h {
            unsafe {
                SendMessageW(h, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
            }
            fields.push(Field {
                name: param.name.clone(),
                hwnd: h,
                control: param.control.clone(),
            });
        }
    }

    let save = mk(
        w!("BUTTON"),
        WINDOW_STYLE(BS_PUSHBUTTON as u32),
        s(H - PAD - 34),
        s(28),
        ID_SAVE,
    );

    // **The crash was here, and the shape is the one to remember.**
    //
    // This block used to hold `borrow_mut` while calling `set_text`.
    // `SetWindowTextW` on a `BUTTON` this page custom-draws does not return
    // before the button has been repainted, and the repaint arrives as
    // `WM_NOTIFY`/`NM_CUSTOMDRAW` **at this window's own procedure**, which
    // reaches `draw_button`, which borrowed `ST`. `panic = abort`, so the
    // whole process went -- every time the page was opened with at least one
    // plugin present. With none, `rebuild_fields` returns above and no button
    // is ever made, which is why an empty plugin directory looked fine.
    //
    // **The messages go first, with nothing borrowed; the cell is taken only
    // to record the handles.** Nothing between the two touches `ST`, so there
    // is no window in which a dispatch can find a borrow held.
    if let Ok(e) = enabled {
        unsafe {
            SendMessageW(e, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
            SendMessageW(
                e,
                BM_SETCHECK,
                Some(WPARAM(if p.enabled { 1 } else { 0 })),
                Some(LPARAM(0)),
            );
        }
        set_text(e, "Enabled");
    }
    if let Ok(b) = save {
        unsafe {
            SendMessageW(b, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
        }
        set_text(b, "Save");
    }

    ST.with(|c| {
        let mut st = c.borrow_mut();
        if let Ok(e) = enabled {
            st.enabled_box = e;
        }
        if let Ok(b) = save {
            st.save_btn = b;
        }
        st.fields = fields;
    });

    let _ = unsafe { InvalidateRect(Some(win), None, true) };
}

/// The two buttons that do not belong to any one plugin: they are about the
/// configuration and about the build, and both outlive the selection.
fn ensure_buttons(win: HWND, hinst: windows::Win32::Foundation::HINSTANCE) {
    let sc = dpi_scale(win);
    let s = |v: i32| v * sc / 96;
    let font = font();
    let have = ST.with(|c| !c.borrow().open_cfg_btn.0.is_null());
    if have {
        return;
    }

    let mk = |label: &str, y: i32, id: usize| unsafe {
        let h = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WINDOW_STYLE(BS_PUSHBUTTON as u32),
            s(PAD),
            y,
            s(LIST_W - PAD * 2),
            s(26),
            Some(win),
            Some(HMENU(id as *mut c_void)),
            Some(hinst),
            None,
        );
        if let Ok(h) = h {
            SendMessageW(h, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
            set_text(h, label);
            crate::overlay::forward_escape_to_parent(h);
            return h;
        }
        HWND(std::ptr::null_mut())
    };

    let cfg = mk("Open config file…", s(H - PAD - 68), ID_OPEN_CONFIG);
    let about = mk("About Polter", s(H - PAD - 34), ID_ABOUT);
    ST.with(|c| {
        let mut st = c.borrow_mut();
        st.open_cfg_btn = cfg;
        st.about_btn = about;
    });
}

/// Version, commit and build mode -- **all three straight out of the core**.
///
/// The host composing its own version string would be a second one to keep in
/// step with the first, and the two would disagree exactly when it mattered:
/// in a bug report.
fn about_lines() -> Vec<String> {
    let api = crate::api();
    let info = unsafe { (api.info)() };
    let version = if info.version.is_null() || info.version_len == 0 {
        "unknown".to_string()
    } else {
        let bytes =
            unsafe { std::slice::from_raw_parts(info.version as *const u8, info.version_len) };
        String::from_utf8_lossy(bytes).into_owned()
    };
    let mode = match info.build_mode {
        0 => "Debug",
        1 => "ReleaseSafe",
        2 => "ReleaseFast",
        3 => "ReleaseSmall",
        other => return vec![format!("Polter {version}"), format!("build mode {other} (unknown)")],
    };
    // **The same string the `[build]` log line carries**, from the same
    // function -- not a second hash computed here. A bug report that quotes
    // the about box and a log that quotes the build line have to be talking
    // about the same binary, and the only way to be sure of that is for one
    // of them not to exist twice.
    let build = std::env::current_exe()
        .map(|p| crate::binary_identity(&p))
        .unwrap_or_else(|_| "build identity unavailable".to_string());
    // **The host's own commit, next to the core's.**
    //
    // The two halves of this program can be built from different trees, and
    // when they are, the symptom is that a feature behaves as though nobody
    // ever wrote it -- the core declines an action it does not know, and a
    // declined action is indistinguishable from an absent one. The log says
    // so at startup (`log_pairing`), but **a log is read afterwards by
    // somebody investigating, and this box is read during, by somebody who is
    // confused right now**. That is the moment the two lines need to be
    // side by side.
    //
    // It is deliberately the raw stamp rather than a verdict: the verdict
    // needs both halves parsed and belongs where it can say what to do about
    // it. Here it is enough that the two strings are visible together, so a
    // person can see they differ without knowing anything about how either
    // was produced.
    let host = match crate::HOST_COMMIT {
        "" => "host build: commit unknown (not built from a git checkout)".to_string(),
        c => format!(
            "host build: {c}{}",
            if crate::HOST_DIRTY == "1" { " (uncommitted changes)" } else { "" }
        ),
    };
    vec![
        "Polter".to_string(),
        format!("libghostty {version}"),
        host,
        format!("{mode} build"),
        build,
        String::new(),
        "MIT licensed. A fork of Ghostty.".to_string(),
    ]
}

fn show_about() {
    let h = HWND(HWND_ABOUT.load(Ordering::Acquire));
    if h.0.is_null() {
        return;
    }
    unsafe {
        let frame = crate::tabs::overlay_frame();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let sc = dpi_scale(h);
        let (w, hh) = (420 * sc / 96, 220 * sc / 96);
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + ((fr.bottom - fr.top) - hh) / 2;
        own_and_place(h, x, y, w, hh);
        let _ = InvalidateRect(Some(h), None, true);
    }
    // process-wide: the about window is one per process
    plogf!("[set] about shown");
}

unsafe extern "system" fn about_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_ABOUT_SHOW => {
                show_about();
                LRESULT(0)
            }
            WM_KEYDOWN if VIRTUAL_KEY(wp.0 as u16) == VK_ESCAPE => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            // **A theme change is a repaint, because the colours are the
            // system's now.** Without this the page keeps the old ones until
            // something else invalidates it -- and "it did not follow the
            // theme" is exactly what a second, private copy of the colours
            // would look like, which would make the two indistinguishable
            // from outside.
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                theme::repaint_all(win);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(win, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let sc = dpi_scale(win);
                    let s = |v: i32| v * sc / 96;
                    let b = CreateSolidBrush(COLORREF(theme::panel()));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                    SetBkMode(hdc, TRANSPARENT);
                    ST.with(|_c| {
                        // The borrow that used to be here read one field, `font`, and
                        // that field is no longer in the cell: this paint touches no
                        // shared state at all.
                        let old = SelectObject(hdc, font().into());
                        let mut y = s(PAD * 2);
                        for (i, line) in about_lines().iter().enumerate() {
                            let mut r = RECT {
                                left: s(PAD * 2),
                                top: y,
                                right: rc.right - s(PAD),
                                bottom: y + s(24),
                            };
                            draw_text(
                                hdc,
                                line,
                                &mut r,
                                DT_LEFT | DT_SINGLELINE,
                                if i == 0 { theme::text() } else { theme::dim() },
                            );
                            y += s(24);
                        }
                        let mut fr = RECT {
                            left: s(PAD * 2),
                            top: rc.bottom - s(30),
                            right: rc.right - s(PAD),
                            bottom: rc.bottom,
                        };
                        draw_text(
                            hdc,
                            "Esc or click to dismiss",
                            &mut fr,
                            DT_LEFT | DT_SINGLELINE,
                            theme::dim(),
                        );
                        SelectObject(hdc, old);
                    });
                    let _ = EndPaint(win, &ps);
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

/// Collect the controls and write the file.
fn save_selected() {
    // **The handles come out first; every message is sent with the cell
    // released.** `BM_GETCHECK` and `WM_GETTEXT` do not repaint today, so
    // this one was not the crash -- but it was covered by the same
    // hand-written exemption that was wrong about the one that was, and
    // "safe for a reason nobody rechecks" is the state this whole class of
    // bug lives in. Taking the borrow out means the question stops being
    // asked.
    let (key, enabled_box, wanted, required) = ST.with(|c| {
        let st = c.borrow();
        let Some(p) = st.plugins.get(st.selected) else {
            return (String::new(), HWND(std::ptr::null_mut()), Vec::new(), Vec::new());
        };
        (
            p.key.clone(),
            st.enabled_box,
            st.fields
                .iter()
                .map(|f| (f.name.clone(), f.hwnd, f.control.clone()))
                .collect::<Vec<_>>(),
            p.params
                .iter()
                .filter(|pa| pa.required)
                .map(|pa| (pa.name.clone(), pa.title.clone()))
                .collect::<Vec<_>>(),
        )
    });

    let (enabled, values, missing) = {
        let enabled = unsafe { SendMessageW(enabled_box, BM_GETCHECK, None, None).0 == 1 };
        let mut values: BTreeMap<String, String> = BTreeMap::new();
        for (name, h, control) in &wanted {
            let v = match control {
                Control::Flag => {
                    let on = unsafe { SendMessageW(*h, BM_GETCHECK, None, None).0 == 1 };
                    // Stored as the text `true`/`false`: `Plugin.Param.value`
                    // is a string on both sides of the wire.
                    (if on { "true" } else { "false" }).to_string()
                }
                _ => get_text(*h),
            };
            if !v.is_empty() {
                values.insert(name.clone(), v);
            }
        }
        // Required parameters that are still empty. Reported rather than
        // refused: the user may be halfway through, and a page that will not
        // save is worse than one that says what is missing.
        let missing: Vec<String> = required
            .iter()
            .filter(|(name, _)| !values.contains_key(name))
            .map(|(_, title)| title.clone())
            .collect();
        (enabled, values, missing)
    };

    if key.is_empty() {
        return;
    }
    let ok = plugins::save(&key, enabled, &values);

    ST.with(|c| {
        let mut st = c.borrow_mut();
        st.complaint = if !ok {
            "Could not write the settings file. See the log.".into()
        } else if !missing.is_empty() {
            format!("Saved. Still empty and required: {}", missing.join(", "))
        } else {
            "Saved.".into()
        };
        let sel = st.selected;
        if let Some(p) = st.plugins.get_mut(sel) {
            p.enabled = enabled;
            p.values = values;
        }
    });
    let _ = unsafe { InvalidateRect(Some(hwnd()), None, true) };
}

// ------------------------------------------------------------ show / hide

fn show(win: HWND, hinst: windows::Win32::Foundation::HINSTANCE) {
    let cat = plugins::catalog();
    ST.with(|c| {
        let mut st = c.borrow_mut();
        st.plugins = cat;
        st.selected = 0;
        st.visible = true;
    });

    unsafe {
        let frame = crate::tabs::overlay_frame();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let sc = dpi_scale(win);
        let (w, h) = (W * sc / 96, H * sc / 96);
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
        own_and_place(win, x, y, w, h);
    }

    ensure_buttons(win, hinst);
    rebuild_fields(win, hinst);

    // The page owns real edit controls, so the terminal's TSF document has to
    // go back before any of them takes focus. Same contract as the palette.
    let first = ST.with(|c| {
        let st = c.borrow();
        st.fields.first().map(|f| f.hwnd).or(Some(st.enabled_box))
    });
    if let Some(f) = first.filter(|h| !h.0.is_null()) {
        let prev = crate::overlay::focus_to_edit(f, "settings");
        ST.with(|c| c.borrow_mut().prev_focus = prev);
    }
    // process-wide: the settings window is one per process; it is not shown *for* a window
    plogf!("[set] shown");
}

/// Give `win` an owner, put it over that owner, and show it.
///
/// **Owned, not topmost.** An owned window is always above its owner, hides
/// when the owner is minimised and comes back with it, and never covers
/// another program. That is the behaviour these three windows were reaching
/// for with `WS_EX_TOPMOST`, which buys the first half by taking the whole
/// screen hostage.
///
/// **The owner is set here rather than at creation**, and that is not
/// bookkeeping: these windows are made once, at startup, and there is going
/// to be more than one terminal window. Which window this page belongs to is
/// a fact about *this* opening -- the one whose keystroke asked for it -- so
/// it is answered every time it opens. `GWLP_HWNDPARENT` on an already-made
/// window is how Win32 spells "re-own".
///
/// **`overlay_frame()` is the answer, and it is a named gap rather than a
/// value.** This page belongs to the window the person is looking at; this
/// host cannot yet say which one that is, so `overlay_frame` answers with the
/// first window and says so in one place, for all fifteen callers that want
/// it. B1-f replaces its body, and this call needs no edit when it does.
///
/// This line was written as `frame_hwnd()` so that the ownership fix could
/// land without waiting for the split, on the understanding that whichever
/// batch landed second would change the one word. The split landed second.
fn own_and_place(win: HWND, x: i32, y: i32, w: i32, h: i32) {
    let owner = crate::tabs::overlay_frame();
    unsafe {
        if !owner.0.is_null() {
            SetWindowLongPtrW(win, GWLP_HWNDPARENT, owner.0 as isize);
        }
        // `HWND_TOP`, not `HWND_TOPMOST`: at the front of its own owner's
        // stack. The z-order this window needs is the one being owned gives it.
        let _ = SetWindowPos(win, Some(HWND_TOP), x, y, w, h, SWP_SHOWWINDOW);
    }
}

fn hide(win: HWND) {
    let prev = ST.with(|c| {
        let mut st = c.borrow_mut();
        st.visible = false;
        st.prev_focus
    });
    unsafe {
        let _ = ShowWindow(win, SW_HIDE);
    }
    crate::overlay::focus_back(prev, "settings");
}

// ------------------------------------------------------------ window proc

unsafe extern "system" fn settings_proc(
    win: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
) -> LRESULT {
    unsafe {
        let hinst = windows::Win32::System::LibraryLoader::GetModuleHandleW(None)
            .map(Into::into)
            .unwrap_or_default();
        match msg {
            WM_SETTINGS_TOGGLE => {
                let vis = ST.with(|c| c.borrow().visible);
                if vis {
                    hide(win);
                } else {
                    show(win, hinst);
                }
                LRESULT(0)
            }

            // The controls that ask their parent what colours to use: an
            // `EDIT`, a `STATIC`, and the combo's drop-down list. Answering is
            // the whole of making them dark -- and under high contrast
            // `ctl_color` answers `None`, the message falls through, and the
            // system's own colours stand.
            WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC | WM_CTLCOLORLISTBOX | WM_CTLCOLORBTN => {
                match theme::ctl_color(HDC(wp.0 as *mut c_void)) {
                    Some(b) => LRESULT(b.0 as isize),
                    None => DefWindowProcW(win, msg, wp, lp),
                }
            }

            // A button's paint, arriving as a notification rather than as a
            // message to the button.
            WM_NOTIFY => {
                let nm = &*(lp.0 as *const NMHDR);
                if nm.code == NM_CUSTOMDRAW && theme::custom_drawing() {
                    let cd = &*(lp.0 as *const NMCUSTOMDRAW);
                    if cd.dwDrawStage == CDDS_PREPAINT {
                        draw_button(cd);
                        return LRESULT(CDRF_SKIPDEFAULT as isize);
                    }
                }
                DefWindowProcW(win, msg, wp, lp)
            }

            WM_DRAWITEM => {
                let dis = &*(lp.0 as *const DRAWITEMSTRUCT);
                if dis.CtlType == ODT_COMBOBOX && theme::custom_drawing() {
                    draw_combo_item(dis);
                    return LRESULT(1);
                }
                DefWindowProcW(win, msg, wp, lp)
            }

            // An owner-drawn combo box has no idea how tall a row is until it
            // is told. Left out, the rows come out the default height and the
            // text is clipped -- which reads as a font problem and is not one.
            WM_MEASUREITEM => {
                let mis = &mut *(lp.0 as *mut MEASUREITEMSTRUCT);
                if mis.CtlType == ODT_COMBOBOX {
                    mis.itemHeight = (dpi_scale(win) * 20 / 96) as u32;
                    return LRESULT(1);
                }
                DefWindowProcW(win, msg, wp, lp)
            }

            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as usize;
                if id == ID_SAVE {
                    save_selected();
                } else if id == ID_OPEN_CONFIG {
                    // The core owns *where* the config is: this asks it, and
                    // the resulting action comes back to `cb_action` under
                    // `ffi::ACTION_OPEN_CONFIG`, which calls
                    // `ghostty_config_open_path` and hands the result to
                    // `ShellExecuteW`. One path, and the host never computes a
                    // config path of its own.
                    //
                    // The symbol names are here on purpose: an earlier version
                    // of this comment claimed the host "already handles" the
                    // action without naming it, and that claim was false and
                    // uncheckable at the same time. See development.md §6.
                    let ok = crate::binding("open_config");
                    // process-wide: opening the config file: one config, one process
                    plogf!("[set] open_config -> binding_action = {}", ok);
                } else if id == ID_ABOUT {
                    show_about();
                }
                LRESULT(0)
            }

            WM_LBUTTONDOWN => {
                let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
                let x = (lp.0 & 0xFFFF) as i16 as i32;
                let sc = dpi_scale(win);
                if x < LIST_W * sc / 96 {
                    let row = (y - PAD * sc / 96) / (ROW_H * sc / 96);
                    let hit = ST.with(|c| {
                        let mut st = c.borrow_mut();
                        let i = row.max(0) as usize;
                        if i < st.plugins.len() && i != st.selected {
                            st.selected = i;
                            true
                        } else {
                            false
                        }
                    });
                    if hit {
                        rebuild_fields(win, hinst);
                    }
                }
                LRESULT(0)
            }

            // **The chord that opens this page has to close it from inside
            // it, too.** `Ctrl+Shift+,` is a host accelerator in `keys.rs`,
            // and that path runs only for a *surface* window -- so once focus
            // is in this page, the key never reaches the code that would
            // toggle it. Handled here as well, so the way in is also a way
            // out no matter where focus is.
            WM_KEYDOWN
                if wp.0 as u16 == VK_OEM_COMMA.0
                    && (GetKeyState(VK_CONTROL.0 as i32) as u16 & 0x8000) != 0
                    && (GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0 =>
            {
                hide(win);
                LRESULT(0)
            }

            WM_KEYDOWN if VIRTUAL_KEY(wp.0 as u16) == VK_ESCAPE => {
                hide(win);
                LRESULT(0)
            }

            // **A theme change is a repaint, because the colours are the
            // system's now.** Without this the page keeps the old ones until
            // something else invalidates it -- and "it did not follow the
            // theme" is exactly what a second, private copy of the colours
            // would look like, which would make the two indistinguishable
            // from outside.
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                // **Rebuilt, not just repainted.** Whether these controls are
                // drawn by this file or by the system is decided by a window
                // style, and a style is fixed when the control is created. A
                // page that only repainted would keep its owner-drawn combo
                // boxes after a person switched high contrast on, which is the
                // one case where our drawing has to stop.
                rebuild_fields(win, hinst);
                theme::repaint_all(win);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint_settings(win);
                LRESULT(0)
            }
            WM_DESTROY => {
                // **No `ST` here any more.** The font left the cell, and a
                // borrow taken for nothing is still a borrow that a dispatch
                // can arrive during.
                let f = font();
                if !f.0.is_null() {
                    let _ = DeleteObject(f.into());
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

fn draw_text(hdc: HDC, s: &str, r: &mut RECT, flags: DRAW_TEXT_FORMAT, colour: u32) {
    unsafe {
        SetTextColor(hdc, COLORREF(colour));
        let mut wide: Vec<u16> = s.encode_utf16().collect();
        if wide.is_empty() {
            return;
        }
        DrawTextW(hdc, &mut wide, r, flags);
    }
}

fn paint_settings(win: HWND) {
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(win, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(win, &mut rc);
        let sc = dpi_scale(win);
        let s = |v: i32| v * sc / 96;

        let bg = CreateSolidBrush(COLORREF(theme::bg()));
        FillRect(hdc, &rc, bg);
        let _ = DeleteObject(bg.into());
        let panel = RECT {
            left: 0,
            top: 0,
            right: s(LIST_W),
            bottom: rc.bottom,
        };
        let pb = CreateSolidBrush(COLORREF(theme::panel()));
        FillRect(hdc, &panel, pb);
        let _ = DeleteObject(pb.into());
        SetBkMode(hdc, TRANSPARENT);

        ST.with(|c| {
            let st = c.borrow();
            let old = SelectObject(hdc, font().into());

            if st.plugins.is_empty() {
                let mut r = RECT {
                    left: s(PAD),
                    top: s(PAD),
                    right: s(LIST_W - PAD),
                    bottom: rc.bottom,
                };
                // **Two different sentences, because they are two different
                // problems.** "The directory is missing" is a broken install;
                // "the directory is there and empty" is a build that shipped
                // nothing. A single "no plugins found" covered both, and the
                // one time it mattered it sent the reader looking in the
                // wrong place -- the directory was fine, this host was
                // reading a different one.
                let msg = match crate::plugins::shipped() {
                    crate::plugins::Shipped::Found(d) => format!(
                        "no plugins found\n\nThe bundled plugin directory exists and holds \
                         none this host can read:\n{}",
                        d.display()
                    ),
                    crate::plugins::Shipped::Missing(d) => format!(
                        "the bundled plugin directory is missing\n\n{}\n\nThis build's \
                         resources are not installed next to it.",
                        d.display()
                    ),
                    crate::plugins::Shipped::NoResourcesDir => {
                        "the bundled plugin directory could not be located\n\n\
                         POLTER_RESOURCES_DIR is not set, so plugins, skills, themes and \
                         shell integration are all unavailable."
                            .to_string()
                    }
                };
                draw_text(hdc, &msg, &mut r, DT_LEFT | DT_WORDBREAK, theme::dim());
            }

            for (i, p) in st.plugins.iter().enumerate() {
                let y = s(PAD) + i as i32 * s(ROW_H);
                let row = RECT {
                    left: 0,
                    top: y,
                    right: s(LIST_W),
                    bottom: y + s(ROW_H),
                };
                if i == st.selected {
                    let b = CreateSolidBrush(COLORREF(theme::sel()));
                    FillRect(hdc, &row, b);
                    let _ = DeleteObject(b.into());
                }
                let mut r = RECT {
                    left: s(PAD),
                    top: y + s(6),
                    right: s(LIST_W - PAD),
                    bottom: y + s(ROW_H),
                };
                let label = if p.enabled {
                    format!("● {}", p.name)
                } else {
                    format!("○ {}", p.name)
                };
                draw_text(
                    hdc,
                    &label,
                    &mut r,
                    DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS,
                    // **The selected row's text comes from the highlight
                    // pair, not from the enabled/disabled pair.** Whether the
                    // plugin is on is already in the glyph; readable text on
                    // the highlight is not something a second colour can be
                    // asked to guess.
                    if i == st.selected {
                        theme::sel_text()
                    } else if p.enabled {
                        theme::text()
                    } else {
                        theme::dim()
                    },
                );
            }

            if let Some(p) = st.plugins.get(st.selected) {
                let x = s(LIST_W + PAD * 2);
                let right = rc.right - s(PAD);
                let mut r = RECT {
                    left: x,
                    top: s(PAD),
                    right,
                    bottom: s(PAD + 24),
                };
                draw_text(hdc, &p.name, &mut r, DT_LEFT | DT_SINGLELINE, theme::text());
                // **Measured once, by the same function the control layout
                // uses.** The summary is the plugin author's sentence and
                // wraps to as many lines as it wraps to.
                let (mut r2, mut r3, controls_top) = head_layout(win, p);
                draw_text(
                    hdc,
                    &p.summary,
                    &mut r2,
                    DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS,
                    theme::dim(),
                );

                // What it subscribes to, from its own `wants.events`.
                draw_text(
                    hdc,
                    &subscription_line(&p.events),
                    &mut r3,
                    DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS,
                    theme::dim(),
                );

                // Labels above each control, in the same order the controls
                // were created.
                let mut y = controls_top + s(32);
                for param in &p.params {
                    let mut lr = RECT {
                        left: x,
                        top: y,
                        right,
                        bottom: y + s(18),
                    };
                    let label = if param.required {
                        format!("{} *", param.title)
                    } else {
                        param.title.clone()
                    };
                    // The manifest's own sentence about the parameter, in the
                    // label when there is one. It is the only place a person
                    // finds out what the value is supposed to be.
                    let label = if param.help.is_empty() {
                        label
                    } else {
                        format!("{label}  —  {}", param.help)
                    };
                    draw_text(hdc, &label, &mut lr, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS, theme::dim());
                    y += s(18);
                    y += match param.control {
                        Control::Flag => s(28),
                        Control::Choice(_) => s(FIELD_H + 6),
                        Control::Text => s(FIELD_H + 6),
                    };
                }

                // The frame around every text field, drawn from the control's
                // own rectangle rather than from a second copy of the layout
                // arithmetic. A combo box is skipped: its frame is the theme's
                // and is the one part of this page that stays light.
                if theme::custom_drawing() {
                    for f in st.fields.iter() {
                        if matches!(f.control, Control::Text) {
                            let mut wr = RECT::default();
                            if GetWindowRect(f.hwnd, &mut wr).is_ok() {
                                let mut pts = [
                                    POINT { x: wr.left, y: wr.top },
                                    POINT { x: wr.right, y: wr.bottom },
                                ];
                                let _ = MapWindowPoints(Some(HWND::default()), Some(win), &mut pts);
                                let r = RECT {
                                    left: pts[0].x - 1,
                                    top: pts[0].y - 1,
                                    right: pts[1].x + 1,
                                    bottom: pts[1].y + 1,
                                };
                                frame(hdc, &r, theme::border());
                            }
                        }
                    }
                }

                if !st.complaint.is_empty() {
                    let mut cr = RECT {
                        left: x,
                        top: rc.bottom - s(PAD + 60),
                        right,
                        bottom: rc.bottom - s(PAD + 36),
                    };
                    draw_text(hdc, &st.complaint, &mut cr, DT_LEFT | DT_WORDBREAK, theme::warn());
                }
            }

            SelectObject(hdc, old);
        });

        let _ = EndPaint(win, &ps);
    }
}

// --------------------------------------------------------- config errors

/// Ask the core what is wrong with the config. Empty means nothing is.
fn read_diagnostics() -> Vec<String> {
    let cfg = crate::config_handle();
    if cfg.is_null() {
        return Vec::new();
    }
    let api = crate::api();
    let n = unsafe { (api.config_diagnostics_count)(cfg) };
    let mut out = Vec::new();
    for i in 0..n {
        let d = unsafe { (api.config_get_diagnostic)(cfg, i) };
        if d.message.is_null() {
            continue;
        }
        let s = unsafe { std::ffi::CStr::from_ptr(d.message) }
            .to_string_lossy()
            .into_owned();
        if !s.is_empty() {
            out.push(s);
        }
    }
    out
}

unsafe extern "system" fn errors_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_ERRORS_SHOW => {
                let errors = read_diagnostics();
                // process-wide: diagnostics about the config this process loaded
                plogf!("[set] config diagnostics: {}", errors.len());
                if errors.is_empty() {
                    let _ = ShowWindow(win, SW_HIDE);
                    return LRESULT(0);
                }
                ST.with(|c| c.borrow_mut().errors = errors);
                let frame = crate::tabs::overlay_frame();
                let mut fr = RECT::default();
                if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
                    return LRESULT(0);
                }
                let sc = dpi_scale(win);
                let (w, h) = (560 * sc / 96, 320 * sc / 96);
                let x = fr.left + ((fr.right - fr.left) - w) / 2;
                let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
                own_and_place(win, x, y, w, h);
                let _ = InvalidateRect(Some(win), None, true);
                LRESULT(0)
            }
            WM_KEYDOWN if VIRTUAL_KEY(wp.0 as u16) == VK_ESCAPE => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let _ = ShowWindow(win, SW_HIDE);
                LRESULT(0)
            }
            // **A theme change is a repaint, because the colours are the
            // system's now.** Without this the page keeps the old ones until
            // something else invalidates it -- and "it did not follow the
            // theme" is exactly what a second, private copy of the colours
            // would look like, which would make the two indistinguishable
            // from outside.
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                theme::repaint_all(win);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(win, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let sc = dpi_scale(win);
                    let s = |v: i32| v * sc / 96;
                    let b = CreateSolidBrush(COLORREF(theme::panel()));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                    SetBkMode(hdc, TRANSPARENT);
                    ST.with(|c| {
                        let st = c.borrow();
                        let old = SelectObject(hdc, font().into());
                        let mut r = RECT {
                            left: s(PAD),
                            top: s(PAD),
                            right: rc.right - s(PAD),
                            bottom: s(PAD + 24),
                        };
                        draw_text(
                            hdc,
                            "Configuration errors",
                            &mut r,
                            DT_LEFT | DT_SINGLELINE,
                            theme::warn(),
                        );
                        let mut y = s(PAD + 30);
                        for e in &st.errors {
                            let mut er = RECT {
                                left: s(PAD),
                                top: y,
                                right: rc.right - s(PAD),
                                bottom: y + s(40),
                            };
                            draw_text(hdc, e, &mut er, DT_LEFT | DT_WORDBREAK, theme::text());
                            y += s(42);
                        }
                        let mut fr = RECT {
                            left: s(PAD),
                            top: rc.bottom - s(28),
                            right: rc.right - s(PAD),
                            bottom: rc.bottom,
                        };
                        draw_text(
                            hdc,
                            "Esc or click to dismiss",
                            &mut fr,
                            DT_LEFT | DT_SINGLELINE,
                            theme::dim(),
                        );
                        SelectObject(hdc, old);
                    });
                    let _ = EndPaint(win, &ps);
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

#[cfg(test)]
mod subscription_tests {
    use super::subscription_line;

    /// A phrase where this build has one.
    #[test]
    fn a_known_event_is_said_in_words() {
        assert_eq!(subscription_line(&["chat".to_string()]), "What it is handed: Keeps the conversations");
    }

    /// **And the raw wire name where it has not.** This is the whole reason
    /// the table is allowed to go stale: an event added after this build must
    /// still leave the subscription visible, or the plugin becomes a thing
    /// that says nothing about itself.
    #[test]
    fn an_unknown_event_is_said_by_its_wire_name() {
        let line = subscription_line(&["chat".to_string(), "terminal.smells".to_string()]);
        assert!(line.contains("Keeps the conversations"), "{line}");
        assert!(line.contains("terminal.smells"), "{line}");
    }

    /// Subscribing to nothing is not an empty list.
    #[test]
    fn nothing_subscribed_says_so() {
        let line = subscription_line(&[]);
        assert!(line.contains("will not start it"), "{line}");
    }
}
