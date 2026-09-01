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
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
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

const COL_BG: u32 = 0x00201f1d;
const COL_PANEL: u32 = 0x00282725;
const COL_SEL: u32 = 0x00403f3d;
const COL_TEXT: u32 = 0x00ffffff;
const COL_DIM: u32 = 0x00a0a0a0;
const COL_WARN: u32 = 0x004040e0;

/// Control ids. `1..` are parameter fields, offset by their index.
const ID_ENABLED: usize = 1000;
const ID_SAVE: usize = 1001;
const ID_OPEN_CONFIG: usize = 1002;
const ID_ABOUT: usize = 1003;
const ID_PARAM_BASE: usize = 2000;

static HWND_SETTINGS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_ERRORS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HWND_ABOUT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

struct Field {
    /// Parameter name, as the manifest and the settings file spell it.
    name: String,
    hwnd: HWND,
    control: Control,
}

#[derive(Default)]
struct State {
    font: HFONT,
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

        let make = |class: PCWSTR, w: i32, h: i32| {
            CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
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
                // process-wide: the settings window: there is one, by the S4-B ruling, and no window owns it
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

        ST.with(|c| {
            let mut st = c.borrow_mut();
            st.font = font;
        });
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

/// Destroy the current parameter controls and build the selected plugin's.
fn rebuild_fields(win: HWND, hinst: windows::Win32::Foundation::HINSTANCE) {
    let sc = dpi_scale(win);
    let s = |v: i32| v * sc / 96;

    let (plugin, font) = ST.with(|c| {
        let st = c.borrow();
        (st.plugins.get(st.selected).cloned(), st.font)
    });

    ST.with(|c| {
        let mut st = c.borrow_mut();
        for f in st.fields.drain(..) {
            unsafe {
                let _ = DestroyWindow(f.hwnd);
            }
        }
        if !st.enabled_box.0.is_null() {
            unsafe {
                let _ = DestroyWindow(st.enabled_box);
            }
            st.enabled_box = HWND(std::ptr::null_mut());
        }
        if !st.save_btn.0.is_null() {
            unsafe {
                let _ = DestroyWindow(st.save_btn);
            }
            st.save_btn = HWND(std::ptr::null_mut());
        }
        st.complaint.clear();
    });

    let Some(p) = plugin else { return };
    let x = s(LIST_W + PAD * 2);
    let mut y = s(PAD + 52);
    let field_w = s(W - LIST_W - PAD * 4);

    let mk = |class: PCWSTR, style: WINDOW_STYLE, yy: i32, hh: i32, id: usize| unsafe {
        CreateWindowExW(
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
        )
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
                let h = mk(
                    w!("COMBOBOX"),
                    WINDOW_STYLE((CBS_DROPDOWNLIST | CBS_HASSTRINGS) as u32),
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
                let style = if param.secret {
                    WINDOW_STYLE((ES_AUTOHSCROLL | ES_PASSWORD) as u32) | WS_BORDER
                } else {
                    WINDOW_STYLE(ES_AUTOHSCROLL as u32) | WS_BORDER
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

    ST.with(|c| {
        let mut st = c.borrow_mut();
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
            st.enabled_box = e;
        }
        if let Ok(b) = save {
            unsafe {
                SendMessageW(b, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
            }
            set_text(b, "Save");
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
    let font = ST.with(|c| c.borrow().font);
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
    vec![
        "Polter".to_string(),
        format!("libghostty {version}"),
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
        let frame = crate::tabs::frame_hwnd();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let sc = dpi_scale(h);
        let (w, hh) = (420 * sc / 96, 220 * sc / 96);
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + ((fr.bottom - fr.top) - hh) / 2;
        let _ = SetWindowPos(h, Some(HWND_TOPMOST), x, y, w, hh, SWP_SHOWWINDOW);
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
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(win, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let sc = dpi_scale(win);
                    let s = |v: i32| v * sc / 96;
                    let b = CreateSolidBrush(COLORREF(COL_BG));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                    SetBkMode(hdc, TRANSPARENT);
                    ST.with(|c| {
                        let st = c.borrow();
                        let old = SelectObject(hdc, st.font.into());
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
                                if i == 0 { COL_TEXT } else { COL_DIM },
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
                            COL_DIM,
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
    let (key, enabled, values, missing) = ST.with(|c| {
        let st = c.borrow();
        let Some(p) = st.plugins.get(st.selected) else {
            return (String::new(), false, BTreeMap::new(), Vec::new());
        };
        let enabled = unsafe {
            SendMessageW(st.enabled_box, BM_GETCHECK, None, None).0 == 1
        };
        let mut values: BTreeMap<String, String> = BTreeMap::new();
        for f in &st.fields {
            let v = match &f.control {
                Control::Flag => {
                    let on = unsafe { SendMessageW(f.hwnd, BM_GETCHECK, None, None).0 == 1 };
                    // Stored as the text `true`/`false`: `Plugin.Param.value`
                    // is a string on both sides of the wire.
                    (if on { "true" } else { "false" }).to_string()
                }
                _ => get_text(f.hwnd),
            };
            if !v.is_empty() {
                values.insert(f.name.clone(), v);
            }
        }
        // Required parameters that are still empty. Reported rather than
        // refused: the user may be halfway through, and a page that will not
        // save is worse than one that says what is missing.
        let missing: Vec<String> = p
            .params
            .iter()
            .filter(|pa| pa.required && !values.contains_key(&pa.name))
            .map(|pa| pa.title.clone())
            .collect();
        (p.key.clone(), enabled, values, missing)
    });

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
        let frame = crate::tabs::frame_hwnd();
        let mut fr = RECT::default();
        if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
            return;
        }
        let sc = dpi_scale(win);
        let (w, h) = (W * sc / 96, H * sc / 96);
        let x = fr.left + ((fr.right - fr.left) - w) / 2;
        let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
        let _ = SetWindowPos(win, Some(HWND_TOPMOST), x, y, w, h, SWP_SHOWWINDOW);
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

            WM_KEYDOWN if VIRTUAL_KEY(wp.0 as u16) == VK_ESCAPE => {
                hide(win);
                LRESULT(0)
            }

            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint_settings(win);
                LRESULT(0)
            }
            WM_DESTROY => {
                ST.with(|c| {
                    let f = c.borrow().font;
                    if !f.0.is_null() {
                        let _ = DeleteObject(f.into());
                    }
                });
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

        let bg = CreateSolidBrush(COLORREF(COL_BG));
        FillRect(hdc, &rc, bg);
        let _ = DeleteObject(bg.into());
        let panel = RECT {
            left: 0,
            top: 0,
            right: s(LIST_W),
            bottom: rc.bottom,
        };
        let pb = CreateSolidBrush(COLORREF(COL_PANEL));
        FillRect(hdc, &panel, pb);
        let _ = DeleteObject(pb.into());
        SetBkMode(hdc, TRANSPARENT);

        ST.with(|c| {
            let st = c.borrow();
            let old = SelectObject(hdc, st.font.into());

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
                draw_text(hdc, &msg, &mut r, DT_LEFT | DT_WORDBREAK, COL_DIM);
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
                    let b = CreateSolidBrush(COLORREF(COL_SEL));
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
                    if p.enabled { COL_TEXT } else { COL_DIM },
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
                draw_text(hdc, &p.name, &mut r, DT_LEFT | DT_SINGLELINE, COL_TEXT);
                let mut r2 = RECT {
                    left: x,
                    top: s(PAD + 24),
                    right,
                    bottom: s(PAD + 50),
                };
                draw_text(hdc, &p.summary, &mut r2, DT_LEFT | DT_WORDBREAK, COL_DIM);

                // Labels above each control, in the same order the controls
                // were created.
                let mut y = s(PAD + 52) + s(32);
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
                    draw_text(hdc, &label, &mut lr, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS, COL_DIM);
                    y += s(18);
                    y += match param.control {
                        Control::Flag => s(28),
                        Control::Choice(_) => s(FIELD_H + 6),
                        Control::Text => s(FIELD_H + 6),
                    };
                }

                if !st.complaint.is_empty() {
                    let mut cr = RECT {
                        left: x,
                        top: rc.bottom - s(PAD + 60),
                        right,
                        bottom: rc.bottom - s(PAD + 36),
                    };
                    draw_text(hdc, &st.complaint, &mut cr, DT_LEFT | DT_WORDBREAK, COL_WARN);
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
                let frame = crate::tabs::frame_hwnd();
                let mut fr = RECT::default();
                if frame.0.is_null() || GetWindowRect(frame, &mut fr).is_err() {
                    return LRESULT(0);
                }
                let sc = dpi_scale(win);
                let (w, h) = (560 * sc / 96, 320 * sc / 96);
                let x = fr.left + ((fr.right - fr.left) - w) / 2;
                let y = fr.top + ((fr.bottom - fr.top) - h) / 2;
                let _ = SetWindowPos(win, Some(HWND_TOPMOST), x, y, w, h, SWP_SHOWWINDOW);
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
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(win, &mut ps);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let sc = dpi_scale(win);
                    let s = |v: i32| v * sc / 96;
                    let b = CreateSolidBrush(COLORREF(COL_BG));
                    FillRect(hdc, &rc, b);
                    let _ = DeleteObject(b.into());
                    SetBkMode(hdc, TRANSPARENT);
                    ST.with(|c| {
                        let st = c.borrow();
                        let old = SelectObject(hdc, st.font.into());
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
                            COL_WARN,
                        );
                        let mut y = s(PAD + 30);
                        for e in &st.errors {
                            let mut er = RECT {
                                left: s(PAD),
                                top: y,
                                right: rc.right - s(PAD),
                                bottom: y + s(40),
                            };
                            draw_text(hdc, e, &mut er, DT_LEFT | DT_WORDBREAK, COL_TEXT);
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
                            COL_DIM,
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
