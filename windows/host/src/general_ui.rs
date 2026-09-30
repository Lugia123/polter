//! The settings window's General section (settings.md §7): a list of groups
//! and, beside it, the group -- a form that writes the config file for the
//! first six, the keyboard shortcuts, the advanced page (open and reload the
//! config file, its errors, the backup) and About.
//!
//! **The form is the core's.** Which keys a group has, what control each
//! gets, what a value may be and where a write lands are all
//! `src/config/form.zig`, reached through `ghostty_app_config_form` /
//! `_set` / `_set_result`; the host draws the table and asks. The small
//! decisions a row makes before it asks -- whether it can be written, when
//! it writes, whether it shows the dot -- are
//! `polter_settings_shell::general`, tested off Windows.
//!
//! **This takes in the three popups `settings_ui.rs` had**: the keyboard
//! shortcuts page (with its UI Automation provider, which now reads the
//! rows from here), the configuration errors box and the about box. The
//! menu rows that opened them route here instead (§3.2).
//!
//! **Writes are immediate** (§7.3): a switch or a choice when it changes, a
//! text box on Return or when it loses focus. So this section is never
//! "unsaved" in §2.4's sense and never asks.
//!
//! ⚠️ **Nothing here dispatches a message while `ST` is borrowed**
//! (`windows/tools/borrow-across-dispatch.py`).

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicI32, AtomicPtr, AtomicUsize, Ordering};

use polter_settings_shell::general::{self as rules, Commit, Control, Group, Item, ReadOnlyNote, Source};
use polter_settings_shell::{self as shell, grid, Rect};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::theme;

const ID_FILTER: u16 = 100;
const ID_OPEN_CONFIG: u16 = 101;
const ID_RELOAD: u16 = 102;
const ID_EDIT_KEYBINDS: u16 = 103;
const ID_ROW_BASE: u16 = 2000;
/// The second box of a theme row (the dark half) is its row's id plus this.
const ID_DARK_OFFSET: u16 = 1000;
const ID_RESTORE: usize = 1;
const EN_KILLFOCUS: u32 = 0x0200;
const PROP_PREV: PCWSTR = w!("PolterGeneralPrevProc");

/// One row of a drop-down, in DIP -- what `roles_ui::common` answers
/// `WM_MEASUREITEM` with.
const CHOICE_ROW_H: i32 = 20;
const CHOICE_LIST_ROWS: i32 = 30;
/// How many lines of a key's documentation go under its control.
const DOC_LINES: i32 = 2;

static SECTION: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FORM: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static KB: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_BOLD: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_MONO: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// The core's table, as `ghostty_app_config_form` answered it.
#[derive(Clone, Default)]
struct Form {
    main: String,
    backup: Option<String>,
    errors: Vec<String>,
    sections: rules::Sections,
    items: Vec<Item>,
}

struct Row {
    /// Index into `Form::items`.
    item: usize,
    control: Control,
    hwnd: HWND,
    /// The dark half of a theme row.
    hwnd2: HWND,
    /// What the core said when it refused the last write (§7.3: under the
    /// control, in red, the value back to the effective one).
    error: Option<String>,
    /// A number with a narrow range, drawn as a trackbar with its value
    /// beside it (`rules::slider_for`).
    slider: bool,
}

#[derive(Clone, Copy)]
struct Fixed {
    filter: HWND,
    open_config: HWND,
    reload: HWND,
    edit_keybinds: HWND,
}

struct State {
    group: Group,
    form: Option<Form>,
    /// Why the table could not be read, said instead of an empty form.
    form_error: Option<String>,
    query: String,
    rows: Vec<Row>,
    scroll: i32,
    status: String,
    status_warn: bool,
    keybinds: Vec<crate::keybinds::Row>,
    fixed: Option<Fixed>,
    /// Set while the form's controls are being filled from the table, so
    /// the notifications that filling raises are not taken for edits.
    filling: bool,
}

thread_local! {
    static ST: RefCell<State> = const {
        RefCell::new(State {
            group: Group::Appearance,
            form: None,
            form_error: None,
            query: String::new(),
            rows: Vec::new(),
            scroll: 0,
            status: String::new(),
            status_warn: false,
            keybinds: Vec::new(),
            fixed: None,
            filling: false,
        })
    };
}

fn section() -> HWND {
    HWND(SECTION.load(Ordering::Acquire))
}

fn form_hwnd() -> HWND {
    HWND(FORM.load(Ordering::Acquire))
}

fn kb_hwnd() -> HWND {
    HWND(KB.load(Ordering::Acquire))
}

fn dpi_of(h: HWND) -> i32 {
    match unsafe { GetDpiForWindow(h) } {
        0 => 96,
        d => d as i32,
    }
}

fn hinst() -> HINSTANCE {
    unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }.map(Into::into).unwrap_or_default()
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn to_rect(r: Rect) -> RECT {
    RECT { left: r.left, top: r.top, right: r.right, bottom: r.bottom }
}

fn font() -> HFONT {
    HFONT(FONT.load(Ordering::Acquire))
}

fn bold() -> HFONT {
    HFONT(FONT_BOLD.load(Ordering::Acquire))
}

fn mono() -> HFONT {
    HFONT(FONT_MONO.load(Ordering::Acquire))
}

pub fn label(g: Group) -> String {
    tr(g.msgid())
}

/// The group on screen, for the route and the breadcrumb.
pub fn current() -> Group {
    ST.with(|c| c.borrow().group)
}

// ================================================================ the core

/// Ask the core by the persona buffer rule.
fn ask_json(mut call: impl FnMut(*mut u8, usize) -> usize) -> Option<String> {
    let need = call(std::ptr::null_mut(), 0);
    if need == 0 {
        return None;
    }
    let mut buf = vec![0u8; need + 1];
    if call(buf.as_mut_ptr(), buf.len()) != need {
        return None;
    }
    String::from_utf8(buf[..need].to_vec()).ok()
}

fn read_form() -> Result<Form, String> {
    let api = crate::api_opt().ok_or("NoApp")?;
    let app = crate::app_opt();
    if app.is_null() {
        return Err("NoApp".into());
    }
    let text = ask_json(|b, c| unsafe { (api.app_config_form)(app, b, c) }).ok_or("the core gave no answer")?;
    parse_form(&text).ok_or_else(|| "the core's answer would not parse".to_string())
}

fn source_of(v: &serde_json::Value) -> Source {
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
    let n = |k: &str| v.get(k).and_then(|x| x.as_u64()).unwrap_or(0) as u32;
    match v.get("kind").and_then(|k| k.as_str()) {
        Some("main") => Source::Main { path: s("path"), line: n("line") },
        Some("file") => Source::File { path: s("path"), line: n("line") },
        Some("cli") => Source::Cli { arg: n("arg") },
        _ => Source::Default,
    }
}

/// `writeJson`'s document (`src/config/form.zig`).
fn parse_form(text: &str) -> Option<Form> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let strs = |x: Option<&serde_json::Value>| -> Vec<String> {
        x.and_then(|a| a.as_array()).map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect()).unwrap_or_default()
    };
    let sections = v
        .get("sections")?
        .as_array()?
        .iter()
        .filter_map(|s| Some((s.get("group")?.as_str()?.to_string(), strs(s.get("keys")))))
        .collect();
    let items = v
        .get("items")?
        .as_array()?
        .iter()
        .filter_map(|it| {
            let st = |k: &str| it.get(k).and_then(|x| x.as_str()).map(str::to_string);
            Some(Item {
                key: st("key")?,
                group: st("group"),
                control: Control::parse(&st("control").unwrap_or_default()),
                choices: strs(it.get("choices")),
                min: it.get("min").and_then(|x| x.as_f64()),
                max: it.get("max").and_then(|x| x.as_f64()),
                default: st("default").unwrap_or_default(),
                value: st("value").unwrap_or_default(),
                doc: st("doc"),
                source: it.get("source").map(source_of).unwrap_or(Source::Default),
                readonly: st("readonly"),
            })
        })
        .collect();
    Some(Form {
        main: v.get("main").and_then(|m| m.as_str()).unwrap_or("").to_string(),
        backup: v.get("backup").and_then(|b| b.as_str()).map(str::to_string),
        errors: strs(v.get("errors")),
        sections,
        items,
    })
}

/// What a write came back with (`setJson`).
struct SetResult {
    ok: bool,
    code: String,
    message: Option<String>,
}

/// `ghostty_app_config_set`: `None` restores the default. The write happens
/// once per call, so a result that did not fit is read back with
/// `_set_result`, never by calling again.
fn set(key: &str, value: Option<&str>) -> SetResult {
    let failed = |m: &str| SetResult { ok: false, code: "failed".into(), message: Some(m.into()) };
    let Some(api) = crate::api_opt() else { return failed("NoApp") };
    let app = crate::app_opt();
    if app.is_null() {
        return failed("NoApp");
    }
    let (vp, vl) = value.map(|v| (v.as_ptr(), v.len())).unwrap_or((std::ptr::null(), 0));
    let mut buf = vec![0u8; 4096];
    let need = unsafe { (api.app_config_set)(app, key.as_ptr(), key.len(), vp, vl, buf.as_mut_ptr(), buf.len()) };
    let text = if need < buf.len() {
        String::from_utf8_lossy(&buf[..need]).into_owned()
    } else {
        match ask_json(|b, c| unsafe { (api.app_config_set_result)(app, b, c) }) {
            Some(t) => t,
            None => return failed("the core's answer could not be read"),
        }
    };
    let v: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return failed("the core's answer would not parse"),
    };
    // process-wide: the one config file, written from the one settings window
    crate::plogf!("[general-ui] set {} = {:?} -> {}", key, value, text);
    SetResult {
        ok: v.get("ok").and_then(|b| b.as_bool()).unwrap_or(false),
        code: v.get("code").and_then(|c| c.as_str()).unwrap_or("").to_string(),
        message: v.get("message").and_then(|m| m.as_str()).map(str::to_string),
    }
}

// ============================================================ the window

fn make_font(dpi: i32, px: i32, weight: i32, face: PCWSTR) -> HFONT {
    unsafe {
        CreateFontW(
            -(px * dpi / 96),
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

fn make_fonts(dpi: i32) {
    for (slot, f) in [
        (&FONT, make_font(dpi, 14, FW_NORMAL.0 as i32, w!("Segoe UI"))),
        (&FONT_BOLD, make_font(dpi, 15, FW_SEMIBOLD.0 as i32, w!("Segoe UI"))),
        (&FONT_MONO, make_font(dpi, 12, FW_NORMAL.0 as i32, w!("Consolas"))),
    ] {
        let old = slot.swap(f.0, Ordering::AcqRel);
        if !old.is_null() {
            let _ = unsafe { DeleteObject(HGDIOBJ(old)) };
        }
    }
}

fn set_font(h: HWND, f: HFONT) {
    unsafe {
        SendMessageW(h, WM_SETFONT, Some(WPARAM(f.0 as usize)), Some(LPARAM(1)));
    }
}

fn set_text(h: HWND, s: &str) {
    let w = wide(s);
    let _ = unsafe { SetWindowTextW(h, PCWSTR(w.as_ptr())) };
}

fn get_text(h: HWND) -> String {
    let n = unsafe { GetWindowTextLengthW(h) }.max(0) as usize;
    let mut buf = vec![0u16; n + 1];
    let got = unsafe { GetWindowTextW(h, &mut buf) }.max(0) as usize;
    String::from_utf16_lossy(&buf[..got])
}

fn create(host: HWND) -> bool {
    unsafe {
        // The trackbar is comctl32's, not user32's: its class exists once
        // this has been asked for.
        let icc = INITCOMMONCONTROLSEX { dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32, dwICC: ICC_BAR_CLASSES };
        let _ = InitCommonControlsEx(&icc);
        for (class, proc_fn) in [
            (w!("PolterGeneralSection"), section_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT),
            (w!("PolterGeneralForm"), form_proc),
            (w!("PolterGeneralKeybinds"), kb_proc),
        ] {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(proc_fn),
                hInstance: hinst(),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hbrBackground: HBRUSH(std::ptr::null_mut()),
                lpszClassName: class,
                ..Default::default()
            };
            let _ = RegisterClassExW(&wc);
        }
        let Ok(sec) = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterGeneralSection"),
            PCWSTR::null(),
            WS_CHILD | WS_CLIPCHILDREN,
            0,
            0,
            10,
            10,
            Some(host),
            None,
            Some(hinst()),
            None,
        ) else {
            // process-wide: the settings window's one General section
            crate::plogf!("[general-ui] could not make the section window");
            return false;
        };
        SECTION.store(sec.0, Ordering::Release);
        make_fonts(dpi_of(sec));
        let child = |class: PCWSTR, style: WINDOW_STYLE| {
            CreateWindowExW(WINDOW_EX_STYLE::default(), class, PCWSTR::null(), WS_CHILD | style, 0, 0, 10, 10, Some(sec), None, Some(hinst()), None)
                .unwrap_or_default()
        };
        FORM.store(child(w!("PolterGeneralForm"), WS_CLIPCHILDREN | WS_VSCROLL).0, Ordering::Release);
        KB.store(child(w!("PolterGeneralKeybinds"), WS_TABSTOP).0, Ordering::Release);
        let button = |id: u16| {
            let h = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("BUTTON"),
                PCWSTR::null(),
                WS_CHILD | WS_TABSTOP | WINDOW_STYLE(BS_PUSHBUTTON as u32),
                0,
                0,
                10,
                10,
                Some(sec),
                Some(HMENU(id as usize as *mut c_void)),
                Some(hinst()),
                None,
            )
            .unwrap_or_default();
            crate::settings_win::subclass_child(h);
            h
        };
        let filter = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_TABSTOP | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            0,
            0,
            10,
            10,
            Some(sec),
            Some(HMENU(ID_FILTER as usize as *mut c_void)),
            Some(hinst()),
            None,
        )
        .unwrap_or_default();
        crate::settings_win::subclass_child(filter);
        let fixed = Fixed { filter, open_config: button(ID_OPEN_CONFIG), reload: button(ID_RELOAD), edit_keybinds: button(ID_EDIT_KEYBINDS) };
        set_fixed(fixed);
        label_fixed(fixed);
        // process-wide: the settings window's one General section
        crate::plogf!("[general-ui] section made");
        true
    }
}

fn label_fixed(f: Fixed) {
    for (h, t) in [
        (f.open_config, tr("Open config file…")),
        (f.reload, tr("Reload Configuration")),
        (f.edit_keybinds, tr("Edit in Config File…")),
    ] {
        set_font(h, font());
        set_text(h, &t);
    }
    set_font(f.filter, font());
    // The placeholder, from the system: this box is not the search field
    // `settings_win.rs` paints its own placeholder into.
    let cue = wide(&tr("Filter by key"));
    unsafe {
        SendMessageW(f.filter, EM_SETCUEBANNER, Some(WPARAM(1)), Some(LPARAM(cue.as_ptr() as isize)));
    }
}

/// Setters of their own, so the borrow ends before the caller dispatches
/// anything (`borrow-across-dispatch.py`).
fn set_fixed(f: Fixed) {
    ST.with(|c| c.borrow_mut().fixed = Some(f));
}

fn set_rows(rows: Vec<Row>) {
    ST.with(|c| c.borrow_mut().rows = rows);
}

fn set_scroll(to: i32) {
    ST.with(|c| c.borrow_mut().scroll = to);
}

fn set_query(q: String) {
    ST.with(|c| c.borrow_mut().query = q);
}

fn fixed() -> Option<Fixed> {
    ST.with(|c| c.borrow().fixed)
}

/// Set when the settings window opens, and spent by the next `show`: a
/// window just opened starts at the first group, one already open stays.
static FRESH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

/// The settings window was opened (not raised).
pub fn opened() {
    FRESH.store(true, Ordering::Release);
}

/// Show the section in `rect`, at the group `item` names (§3.1 as the
/// macOS side reads it: `general/<group>`), else the first on a fresh
/// opening, else where it was.
pub fn show(host: HWND, rect: RECT, item: Option<&str>) {
    if section().0.is_null() && !create(host) {
        return;
    }
    let fresh = FRESH.swap(false, Ordering::AcqRel);
    let group = rules::group_to_select(item, fresh, current());
    ST.with(|c| c.borrow_mut().group = group);
    unsafe {
        let _ = SetWindowPos(
            section(),
            None,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
    }
    reload_form();
    // process-wide: the settings window's one General section
    crate::plogf!("[general-ui] shown at {} (asked {:?})", group.key(), item);
}

pub fn hide() {
    let h = section();
    if !h.0.is_null() {
        kb_publish(false);
        let _ = unsafe { ShowWindow(h, SW_HIDE) };
    }
}

pub fn move_to(rect: RECT) {
    let h = section();
    if h.0.is_null() || !unsafe { IsWindowVisible(h) }.as_bool() {
        return;
    }
    unsafe {
        let _ = SetWindowPos(h, None, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

pub fn dpi_changed() {
    let h = section();
    if h.0.is_null() {
        return;
    }
    make_fonts(dpi_of(h));
    if let Some(f) = fixed() {
        label_fixed(f);
    }
    rebuild();
}

pub fn theme_changed() {
    if is_showing() {
        rebuild();
    }
}

fn is_showing() -> bool {
    let h = section();
    !h.0.is_null() && unsafe { IsWindowVisible(h) }.as_bool()
}

/// The settings window became active: the file may have been changed
/// behind the form's back (§7.3).
pub fn activated() {
    if is_showing() {
        refresh_values();
    }
}

/// The configuration was reloaded, or its errors changed. **With the window
/// closed and errors to show, the window opens at Advanced** -- that is what
/// the errors box used to do by itself; with it open, the page follows.
pub fn config_changed() {
    let errors = read_diagnostics();
    // process-wide: diagnostics about the config this process loaded
    crate::plogf!("[general-ui] config diagnostics: {}", errors.len());
    if crate::settings_win::is_open() {
        if is_showing() {
            // In place: a write from this form ends in a reload, and making
            // the rows again would take the keyboard out of the next field.
            refresh_values();
        }
        return;
    }
    if !errors.is_empty() {
        crate::settings_win::request(
            shell::Route::to(shell::Section::General, Some(Group::Advanced.key())),
            HWND(std::ptr::null_mut()),
        );
    }
}

/// Ask the core what is wrong with the config it is holding.
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
        let s = unsafe { std::ffi::CStr::from_ptr(d.message) }.to_string_lossy().into_owned();
        if !s.is_empty() {
            out.push(s);
        }
    }
    out
}

/// Read the table (and the shortcuts) afresh and redraw everything.
fn reload_form() {
    let form = read_form();
    let keybinds = crate::keybinds::rows();
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        match form {
            Ok(f) => {
                s.form = Some(f);
                s.form_error = None;
            }
            Err(e) => {
                s.form = None;
                s.form_error = Some(e);
            }
        }
        s.keybinds = keybinds;
    });
    rebuild();
}

/// Go to a group from the list.
fn select(g: Group) {
    if current() == g {
        return;
    }
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.group = g;
        s.status.clear();
    });
    rebuild();
    crate::settings_win::crumb_changed();
}

// ================================================================== layout

/// The section's grid (with its list column) and the editor's parts.
fn laid() -> (shell::SectionGrid, i32) {
    let h = section();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let dpi = dpi_of(h);
    (shell::section_grid(rc.right, rc.bottom, dpi, true), dpi)
}

fn metrics(f: HFONT) -> i32 {
    let h = section();
    let mut tm = TEXTMETRICW::default();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, f.into());
        let _ = GetTextMetricsW(dc, &mut tm);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    tm.tmHeight
}

fn measure(text: &str, width: i32, f: HFONT, max_lines: i32) -> i32 {
    if text.is_empty() {
        return 0;
    }
    let h = section();
    let mut r = RECT { left: 0, top: 0, right: width.max(1), bottom: 0 };
    let mut w: Vec<u16> = text.encode_utf16().collect();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, f.into());
        DrawTextW(dc, &mut w, &mut r, DT_LEFT | DT_WORDBREAK | DT_CALCRECT | DT_NOPREFIX);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    if max_lines > 0 {
        r.bottom.min(metrics(f) * max_lines)
    } else {
        r.bottom
    }
}

fn text_width(text: &str, f: HFONT) -> i32 {
    let h = section();
    let mut r = RECT::default();
    let mut w: Vec<u16> = text.encode_utf16().collect();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, f.into());
        DrawTextW(dc, &mut w, &mut r, DT_SINGLELINE | DT_CALCRECT | DT_NOPREFIX);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    r.right
}

/// The bottom band's buttons for `group`, right-aligned from the band's
/// right margin, each as wide as its label plus the grid's padding.
fn band_buttons(g: &shell::SectionGrid, dpi: i32, group: Group) -> Vec<(u16, Rect)> {
    let s = |v| shell::scale(v, dpi);
    let ids: Vec<(u16, String)> = match group {
        Group::Keybinds => vec![(ID_EDIT_KEYBINDS, tr("Edit in Config File…"))],
        Group::Advanced => vec![(ID_OPEN_CONFIG, tr("Open config file…")), (ID_RELOAD, tr("Reload Configuration"))],
        Group::About => Vec::new(),
        _ => vec![(ID_OPEN_CONFIG, tr("Open config file…"))],
    };
    let top = g.actions[2].top;
    let mut right = g.actions[2].right;
    let mut out = Vec::new();
    for (id, label) in ids.iter().rev() {
        let w = (text_width(label, font()) + 2 * s(grid::PAD)).max(s(grid::ACTION_W[1]));
        out.push((*id, Rect::new(right - w, top, right, top + s(grid::CONTROL_H))));
        right -= w + s(grid::BUTTONS_GAP);
    }
    out
}

/// What goes under a row's control: the core's refusal (red), why it cannot
/// be written, or the first lines of its documentation.
fn row_note(it: &Item, error: Option<&str>) -> (String, bool) {
    if let Some(e) = error {
        return (e.to_string(), true);
    }
    match rules::readonly_note(it) {
        Some(ReadOnlyNote::SetBy { path, line }) => {
            (tr("Set by {}:{}. Edit it there.").replacen("{}", &path, 1).replacen("{}", &line.to_string(), 1), false)
        }
        Some(ReadOnlyNote::CommandLine) => (tr("Set on the command line, which has the last word."), false),
        Some(ReadOnlyNote::InTheFile) => (tr("Edit this one in the config file."), false),
        None => (it.doc.as_deref().map(rules::doc_summary).unwrap_or_default(), false),
    }
}

/// The form's rows, laid out in the form window's width.
fn form_rows(width: i32, dpi: i32) -> Vec<polter_settings_shell::plugins::FormRow> {
    let helps: Vec<i32> = ST.with(|c| {
        let s = c.borrow();
        let Some(form) = &s.form else { return Vec::new() };
        s.rows
            .iter()
            .map(|r| {
                let (note, _) = row_note(&form.items[r.item], r.error.as_deref());
                (r.item, note)
            })
            .collect::<Vec<_>>()
    })
    .into_iter()
    .map(|(_, note)| {
        let control_w = width - shell::scale(grid::LABEL_W + grid::LABEL_GAP, dpi);
        measure(&note, control_w, font(), DOC_LINES)
    })
    .collect();
    polter_settings_shell::plugins::form(width, dpi, &helps).0
}

// ================================================================== the form

/// Make the controls for the group on screen and put everything in place.
fn rebuild() {
    let doomed: Vec<HWND> = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.scroll = 0;
        s.rows.drain(..).flat_map(|r| [r.hwnd, r.hwnd2]).filter(|h| !h.0.is_null()).collect()
    });
    for h in doomed {
        let _ = unsafe { DestroyWindow(h) };
    }
    let (group, form, query) = ST.with(|c| {
        let s = c.borrow();
        (s.group, s.form.clone(), s.query.clone())
    });
    let mut made = Vec::new();
    if let (true, Some(form)) = (group.is_form(), &form) {
        for i in rules::items_in(group, &form.items, &form.sections, &query) {
            let it = &form.items[i];
            let control = rules::control_for(it, group);
            let id = ID_ROW_BASE + made.len() as u16;
            let slider = rules::slider_for(it, group);
            let (hwnd, hwnd2) = if slider { (make_slider(id), HWND(std::ptr::null_mut())) } else { make_row(control, it, id) };
            made.push(Row { item: i, control, hwnd, hwnd2, error: None, slider });
        }
    }
    set_rows(made);
    fill_rows();
    relayout();
}

fn make_control(class: PCWSTR, style: WINDOW_STYLE, id: u16) -> HWND {
    let h = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class,
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | style,
            0,
            0,
            10,
            10,
            Some(form_hwnd()),
            Some(HMENU(id as usize as *mut c_void)),
            Some(hinst()),
            None,
        )
    }
    .unwrap_or_default();
    if !h.0.is_null() {
        set_font(h, font());
        subclass_field(h);
    }
    h
}

/// A trackbar of `SLIDER_STEPS` steps; the range it stands for is the
/// item's own, converted in `rules::slider_pos` / `slider_value`. No tick
/// marks: the value is written beside it.
fn make_slider(id: u16) -> HWND {
    let h = make_control(w!("msctls_trackbar32"), WINDOW_STYLE((TBS_HORZ | TBS_NOTICKS) as u32), id);
    if !h.0.is_null() {
        unsafe {
            SendMessageW(h, TBM_SETRANGEMIN, Some(WPARAM(0)), Some(LPARAM(0)));
            SendMessageW(h, TBM_SETRANGEMAX, Some(WPARAM(1)), Some(LPARAM(rules::SLIDER_STEPS as isize)));
            SendMessageW(h, TBM_SETLINESIZE, Some(WPARAM(0)), Some(LPARAM(1)));
            SendMessageW(h, TBM_SETPAGESIZE, Some(WPARAM(0)), Some(LPARAM(10)));
        }
    }
    h
}

/// `TBM_GETPOS`, which is `WM_USER` itself and has no constant in the
/// `windows` crate (its neighbours `TBM_SETPOS` = 1029 and
/// `TBM_SETRANGEMIN` = 1031 do).
const TBM_GETPOS: u32 = WM_USER;

/// Where a trackbar is now, as the value it stands for, written the way
/// the file writes it.
fn slider_now(h: HWND, it: &Item) -> String {
    let pos = unsafe { SendMessageW(h, TBM_GETPOS, None, None).0 } as i32;
    rules::slider_text(rules::slider_value(pos, it.min.unwrap_or(0.0), it.max.unwrap_or(1.0)))
}

fn make_row(control: Control, it: &Item, id: u16) -> (HWND, HWND) {
    let border = if theme::custom_drawing() { WINDOW_STYLE(0) } else { WS_BORDER };
    let edit = WINDOW_STYLE(ES_AUTOHSCROLL as u32) | border;
    let none = HWND(std::ptr::null_mut());
    match control {
        Control::Toggle => (make_control(w!("BUTTON"), WINDOW_STYLE(BS_AUTOCHECKBOX as u32), id), none),
        Control::Choice => {
            let od = if theme::custom_drawing() { CBS_OWNERDRAWFIXED } else { 0 };
            let h = make_control(w!("COMBOBOX"), WINDOW_STYLE((CBS_DROPDOWNLIST | CBS_HASSTRINGS | od) as u32) | WS_VSCROLL, id);
            for o in &it.choices {
                let w = wide(o);
                unsafe {
                    SendMessageW(h, CB_ADDSTRING, Some(WPARAM(0)), Some(LPARAM(w.as_ptr() as isize)));
                }
            }
            (h, none)
        }
        Control::Theme => (make_control(w!("EDIT"), edit, id), make_control(w!("EDIT"), edit, id + ID_DARK_OFFSET)),
        Control::ReadOnly => (make_control(w!("EDIT"), edit | WINDOW_STYLE(ES_READONLY as u32), id), none),
        _ => (make_control(w!("EDIT"), edit, id), none),
    }
}

/// Put every row's effective value into its control.
fn fill_rows() {
    let rows: Vec<(HWND, HWND, Control, Item, bool)> = ST.with(|c| {
        let s = c.borrow();
        let Some(form) = &s.form else { return Vec::new() };
        s.rows.iter().map(|r| (r.hwnd, r.hwnd2, r.control, form.items[r.item].clone(), r.slider)).collect()
    });
    ST.with(|c| c.borrow_mut().filling = true);
    for (h, h2, control, it, slider) in rows {
        if slider {
            let pos = rules::slider_pos(&it.value, it.min.unwrap_or(0.0), it.max.unwrap_or(1.0));
            unsafe {
                SendMessageW(h, TBM_SETPOS, Some(WPARAM(1)), Some(LPARAM(pos as isize)));
            }
            continue;
        }
        fill_one(h, h2, control, &it);
    }
    ST.with(|c| c.borrow_mut().filling = false);
}

fn fill_one(h: HWND, h2: HWND, control: Control, it: &Item) {
    match control {
        Control::Toggle => unsafe {
            SendMessageW(h, BM_SETCHECK, Some(WPARAM(rules::is_on(it) as usize)), Some(LPARAM(0)));
        },
        Control::Choice => {
            let idx = it.choices.iter().position(|c| *c == it.value).map(|i| i as isize).unwrap_or(-1);
            unsafe {
                SendMessageW(h, CB_SETCURSEL, Some(WPARAM(idx as usize)), Some(LPARAM(0)));
            }
        }
        Control::Theme => {
            let (l, d) = rules::theme_pair(&it.value);
            set_text(h, &l);
            set_text(h2, &d);
            for (hh, cue) in [(h, tr("Light")), (h2, tr("Dark"))] {
                let w = wide(&cue);
                unsafe {
                    SendMessageW(hh, EM_SETCUEBANNER, Some(WPARAM(1)), Some(LPARAM(w.as_ptr() as isize)));
                }
            }
        }
        // A repeatable key's lines are joined with `\n`; one line of box
        // shows them side by side.
        _ => set_text(h, &it.value.replace('\n', "  ·  ")),
    }
}

/// Where every child goes.
fn relayout() {
    let sec = section();
    if sec.0.is_null() {
        return;
    }
    let (g, dpi) = laid();
    let group = current();
    let place = |h: HWND, r: Rect, show: bool| unsafe {
        let _ = SetWindowPos(
            h,
            None,
            r.left,
            r.top,
            r.width(),
            r.height(),
            SWP_NOZORDER | SWP_NOACTIVATE | if show { SWP_SHOWWINDOW } else { SWP_HIDEWINDOW },
        );
    };
    let (filter, body) = rules::form_area(g.editor, dpi, group == Group::All);
    if let Some(f) = fixed() {
        let buttons = band_buttons(&g, dpi, group);
        for (id, h) in [(ID_OPEN_CONFIG, f.open_config), (ID_RELOAD, f.reload), (ID_EDIT_KEYBINDS, f.edit_keybinds)] {
            match buttons.iter().find(|(i, _)| *i == id) {
                Some((_, r)) => place(h, *r, true),
                None => place(h, Rect::new(0, 0, 1, 1), false),
            }
        }
        place(f.filter, filter.unwrap_or(Rect::new(0, 0, 1, 1)), filter.is_some());
    }
    place(form_hwnd(), body, group.is_form());
    place(kb_hwnd(), body, group == Group::Keybinds);
    kb_publish(group == Group::Keybinds);
    if group.is_form() {
        layout_form(dpi);
    }
    let _ = unsafe { InvalidateRect(Some(sec), None, false) };
}

fn layout_form(dpi: i32) {
    let form = form_hwnd();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(form, &mut rc) };
    let rows = form_rows(rc.right, dpi);
    let total = rows.last().map(|r| r.help.map(|h| h.bottom).unwrap_or(r.control.bottom)).unwrap_or(0) + shell::scale(grid::ROW_GAP, dpi);
    let view = rc.bottom;
    let (ctls, scroll) = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.scroll = s.scroll.clamp(0, (total - view).max(0));
        (s.rows.iter().map(|r| (r.hwnd, r.hwnd2, r.control, r.slider)).collect::<Vec<_>>(), s.scroll)
    });
    let gap = shell::scale(grid::BUTTONS_GAP, dpi);
    for ((h, h2, control, slider), r) in ctls.iter().zip(rows.iter()) {
        let c = r.control;
        let extra = if *control == Control::Choice { shell::scale(CHOICE_LIST_ROWS * CHOICE_ROW_H, dpi) } else { 0 };
        let flags = SWP_NOZORDER | SWP_NOACTIVATE;
        unsafe {
            if *slider {
                let (sl, _) = rules::slider_parts(c, dpi);
                let _ = SetWindowPos(*h, None, sl.left, sl.top - scroll, sl.width(), sl.height(), flags);
            } else if *control == Control::Theme {
                let half = (c.width() - gap) / 2;
                let _ = SetWindowPos(*h, None, c.left, c.top - scroll, half, c.height(), flags);
                let _ = SetWindowPos(*h2, None, c.left + half + gap, c.top - scroll, c.width() - half - gap, c.height(), flags);
            } else {
                let _ = SetWindowPos(*h, None, c.left, c.top - scroll, c.width(), c.height() + extra, flags);
            }
        }
    }
    let si = SCROLLINFO {
        cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
        fMask: SIF_RANGE | SIF_PAGE | SIF_POS,
        nMin: 0,
        nMax: (total - 1).max(0),
        nPage: view.max(0) as u32,
        nPos: scroll,
        nTrackPos: 0,
    };
    unsafe {
        SetScrollInfo(form, SB_VERT, &si, true);
        let _ = InvalidateRect(Some(form), None, true);
    }
}

fn scroll_form(to: i32) {
    set_scroll(to);
    layout_form(dpi_of(form_hwnd()));
}

// ================================================================= writing

/// The row whose control has id `id`, and whether it is a theme row's dark
/// half.
fn row_of_id(id: u16) -> Option<usize> {
    let n = ST.with(|c| c.borrow().rows.len()) as u16;
    let base = if id >= ID_ROW_BASE + ID_DARK_OFFSET { id - ID_DARK_OFFSET } else { id };
    let i = base.checked_sub(ID_ROW_BASE)?;
    (i < n).then_some(i as usize)
}

/// What row `index`'s control says now, as the value to write.
fn edited_value(index: usize) -> Option<(Item, Control, String)> {
    let (h, h2, control, it, slider) = ST.with(|c| {
        let s = c.borrow();
        let r = s.rows.get(index)?;
        Some((r.hwnd, r.hwnd2, r.control, s.form.as_ref()?.items.get(r.item)?.clone(), r.slider))
    })?;
    if slider {
        let v = slider_now(h, &it);
        return Some((it, control, v));
    }
    let v = match control {
        Control::Toggle => rules::toggle_value(unsafe { SendMessageW(h, BM_GETCHECK, None, None).0 == 1 }).to_string(),
        Control::Choice => get_text(h),
        Control::Theme => rules::theme_value(&get_text(h), &get_text(h2)),
        Control::ReadOnly => return None,
        _ => get_text(h),
    };
    Some((it, control, v))
}

/// Row `index` changed. Writes when its control's rule says this is the
/// moment (`commit`), and only when the value is not what the file says.
fn changed(index: usize, commit: Commit) {
    if ST.with(|c| c.borrow().filling) {
        return;
    }
    let Some((it, control, v)) = edited_value(index) else { return };
    if rules::commit_for(control) != commit || !rules::should_write(&v, &it) {
        return;
    }
    write(index, &it.key, Some(&v));
}

/// A slider was let go (`TB_ENDTRACK`, after a drag or a key): it writes
/// then, as the macOS slider does when editing ends, and only a value that
/// is not what the file says.
fn slider_released(index: usize) {
    if ST.with(|c| c.borrow().filling) {
        return;
    }
    let Some((it, _, v)) = edited_value(index) else { return };
    if rules::should_write(&v, &it) {
        write(index, &it.key, Some(&v));
    }
}

fn write(index: usize, key: &str, value: Option<&str>) {
    let r = set(key, value);
    if r.ok {
        ST.with(|c| {
            let s = &mut *c.borrow_mut();
            if let Some(row) = s.rows.get_mut(index) {
                row.error = None;
            }
            s.status = tr("Saved to the config file.");
            s.status_warn = false;
        });
        // Rule 7: reloading is the host's, through its usual path. The
        // reload ends in `config_changed`, which reads the table again.
        let _ = crate::reload::request(false, std::ptr::null_mut());
        refresh_values();
    } else {
        let why = match r.code.as_str() {
            "invalid_value" => r.message.unwrap_or_else(|| tr("That value is not valid for this key.")),
            "read_only" => tr("This key is set somewhere the form does not write."),
            "busy" => tr("The config file kept changing while it was being written. Try again."),
            other => tr("Could not write the config file: {}").replace("{}", r.message.as_deref().unwrap_or(other)),
        };
        ST.with(|c| {
            let s = &mut *c.borrow_mut();
            if let Some(row) = s.rows.get_mut(index) {
                row.error = Some(why.clone());
            }
            s.status = why;
            s.status_warn = true;
        });
        // The control goes back to the effective value (§7.3).
        refresh_values();
    }
}

/// Read the table again and put the values into the controls in place,
/// keeping the keyboard where it is. The rows are made again only when the
/// group now lists other keys.
fn refresh_values() {
    let keybinds = crate::keybinds::rows();
    ST.with(|c| c.borrow_mut().keybinds = keybinds);
    kb_publish(current() == Group::Keybinds);
    let _ = unsafe { InvalidateRect(Some(kb_hwnd()), None, false) };
    let form = match read_form() {
        Ok(f) => f,
        Err(e) => {
            ST.with(|c| {
                let s = &mut *c.borrow_mut();
                s.form = None;
                s.form_error = Some(e);
            });
            rebuild();
            return;
        }
    };
    let same = ST.with(|c| {
        let s = c.borrow();
        let keys = rules::items_in(s.group, &form.items, &form.sections, &s.query);
        s.rows.iter().map(|r| r.item).eq(keys.into_iter())
    });
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.form = Some(form);
        s.form_error = None;
    });
    if !same {
        rebuild();
        return;
    }
    fill_rows();
    layout_form(dpi_of(form_hwnd()));
    let _ = unsafe { InvalidateRect(Some(section()), None, false) };
}

/// Right-click on a row's label: "Restore Default" where there is a main
/// file line to delete (§7.3).
fn context_menu(index: usize, at: POINT) {
    let it = ST.with(|c| {
        let s = c.borrow();
        let r = s.rows.get(index)?;
        s.form.as_ref()?.items.get(r.item).cloned()
    });
    let Some(it) = it else { return };
    if !rules::can_restore_default(&it) {
        return;
    }
    let Ok(menu) = (unsafe { CreatePopupMenu() }) else { return };
    let label = wide(&tr("Restore Default"));
    let chosen = unsafe {
        let _ = AppendMenuW(menu, MF_STRING, ID_RESTORE, PCWSTR(label.as_ptr()));
        let r = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, at.x, at.y, None, form_hwnd(), None);
        let _ = DestroyMenu(menu);
        r.0 as usize
    };
    if chosen == ID_RESTORE {
        write(index, &it.key, None);
    }
}

/// The row whose label is under `y` in the form window.
fn row_at(y: i32) -> Option<usize> {
    let form = form_hwnd();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(form, &mut rc) };
    let rows = form_rows(rc.right, dpi_of(form));
    let scroll = ST.with(|c| c.borrow().scroll);
    rows.iter().position(|r| {
        let bottom = r.help.map(|h| h.bottom).unwrap_or(r.control.bottom);
        y + scroll >= r.label.top && y + scroll < bottom
    })
}

/// Return in a text box writes it; Ctrl+W and Escape behave as everywhere
/// in this window (`settings_win::subclass_child` keeps its previous
/// procedure in another property, so the two never collide).
fn is_trackbar(h: HWND) -> bool {
    let mut buf = [0u16; 32];
    let n = unsafe { GetClassNameW(h, &mut buf) }.max(0) as usize;
    String::from_utf16_lossy(&buf[..n]).eq_ignore_ascii_case("msctls_trackbar32")
}

fn subclass_field(h: HWND) {
    unsafe {
        let prev = SetWindowLongPtrW(h, GWLP_WNDPROC, field_proc as *const () as isize);
        let _ = SetPropW(h, PROP_PREV, Some(windows::Win32::Foundation::HANDLE(prev as *mut c_void)));
    }
}

unsafe extern "system" fn field_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetPropW(h, PROP_PREV).0 as isize;
        match msg {
            WM_KEYDOWN if wp.0 as u16 == VK_RETURN.0 => {
                let id = GetDlgCtrlID(h) as u16;
                if let Some(i) = row_of_id(id) {
                    changed(i, Commit::OnEnterOrBlur);
                }
                return LRESULT(0);
            }
            WM_KEYDOWN if wp.0 as u16 == u16::from(b'W') && (GetKeyState(VK_CONTROL.0 as i32) as u16 & 0x8000) != 0 => {
                let _ = PostMessageW(Some(GetAncestor(h, GA_ROOT)), WM_CLOSE, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            // The characters Return, Ctrl+W and Escape produce, which an
            // `EDIT` would answer with a beep.
            WM_CHAR if wp.0 == 0x0D || wp.0 == 0x17 || wp.0 == 0x1B => return LRESULT(0),
            WM_NCDESTROY => {
                let _ = RemovePropW(h, PROP_PREV);
            }
            _ => {}
        }
        if prev == 0 {
            return DefWindowProcW(h, msg, wp, lp);
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = std::mem::transmute(prev);
        CallWindowProcW(Some(f), h, msg, wp, lp)
    }
}

// ================================================================ painting

fn fill(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

fn draw_text(hdc: HDC, s: &str, r: &RECT, f: HFONT, colour: u32, flags: DRAW_TEXT_FORMAT) {
    let mut w: Vec<u16> = s.encode_utf16().collect();
    if w.is_empty() {
        return;
    }
    let mut r = *r;
    unsafe {
        let old = SelectObject(hdc, f.into());
        SetTextColor(hdc, COLORREF(colour));
        SetBkMode(hdc, TRANSPARENT);
        DrawTextW(hdc, &mut w, &mut r, flags | DT_NOPREFIX);
        SelectObject(hdc, old);
    }
}

fn paint(win: HWND) {
    let (g, dpi) = laid();
    let s = |v: i32| shell::scale(v, dpi);
    let (group, status, warn, form_error, errors, backup, main) = ST.with(|c| {
        let st = c.borrow();
        (
            st.group,
            st.status.clone(),
            st.status_warn,
            st.form_error.clone(),
            st.form.as_ref().map(|f| f.errors.clone()),
            st.form.as_ref().and_then(|f| f.backup.clone()),
            st.form.as_ref().map(|f| f.main.clone()),
        )
    });
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(win, &mut ps) };
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    fill(hdc, &rc, theme::bg());

    // The group list, with the list's text edge and the sidebar's highlight.
    if let Some(list) = g.list {
        for (i, gr) in Group::ALL.iter().enumerate() {
            let r = to_rect(rules::group_row(list, dpi, i));
            let on = *gr == group;
            if on {
                fill(hdc, &r, theme::sel());
            }
            let t = RECT { left: list.left + g.text_left, ..r };
            draw_text(hdc, &label(*gr), &t, if on { bold() } else { font() }, if on { theme::sel_text() } else { theme::text() }, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        }
    }
    if let Some(d) = g.list_divider {
        fill(hdc, &to_rect(d), theme::border());
    }
    fill(hdc, &to_rect(g.bottom_rule), theme::border());
    let status_r = RECT { left: g.text_left, ..to_rect(g.status) };
    draw_text(hdc, &status, &status_r, font(), if warn { theme::warn() } else { theme::dim() }, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);

    let pad = s(grid::PAD);
    let ed = g.editor;
    let area = RECT { left: ed.left + pad, top: ed.top + pad, right: ed.right - pad, bottom: ed.bottom - pad };
    match group {
        _ if group.is_form() => {
            if let Some(e) = form_error {
                draw_text(hdc, &tr("The settings could not be read: {}").replace("{}", &e), &area, font(), theme::warn(), DT_WORDBREAK);
            }
        }
        Group::Advanced => paint_advanced(hdc, &area, dpi, errors.unwrap_or_else(read_diagnostics), main, backup),
        Group::About => paint_about(hdc, &area, dpi),
        _ => {}
    }
    let _ = unsafe { EndPaint(win, &ps) };
}

/// Advanced (§7.1): the configuration's errors, and where the copy taken
/// before this run's first write is. Opening and reloading are in the band.
fn paint_advanced(hdc: HDC, area: &RECT, dpi: i32, errors: Vec<String>, main: Option<String>, backup: Option<String>) {
    let s = |v: i32| shell::scale(v, dpi);
    let mut y = area.top;
    // Which file the form writes: the one "Open config file…" opens.
    if let Some(m) = main.filter(|m| !m.is_empty()) {
        let t = tr("The form writes to:\n{}").replace("{}", &m);
        let h = measure(&t, area.right - area.left, font(), 0);
        draw_text(hdc, &t, &RECT { top: y, bottom: y + h, ..*area }, font(), theme::dim(), DT_WORDBREAK);
        y += h + s(grid::GROUP_GAP);
    }
    let line = metrics(bold());
    draw_text(hdc, &tr("Configuration Errors"), &RECT { top: y, bottom: y + line, ..*area }, bold(), theme::text(), DT_SINGLELINE);
    y += line + s(grid::ROW_GAP);
    let summary = if errors.is_empty() {
        tr("The configuration loaded without errors.")
    } else {
        tr("{} error(s). The lines they name were ignored; fix them and reload.").replace("{}", &errors.len().to_string())
    };
    let h = measure(&summary, area.right - area.left, font(), 0);
    draw_text(hdc, &summary, &RECT { top: y, bottom: y + h, ..*area }, font(), theme::dim(), DT_WORDBREAK);
    y += h + s(grid::ROW_GAP);
    let bottom_reserve = if backup.is_some() { metrics(font()) * 2 + s(grid::GROUP_GAP) } else { 0 };
    for e in &errors {
        let h = measure(e, area.right - area.left, mono(), 3);
        if y + h > area.bottom - bottom_reserve {
            break;
        }
        draw_text(hdc, e, &RECT { top: y, bottom: y + h, ..*area }, mono(), theme::text(), DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL);
        y += h + s(grid::BUTTON_GAP);
    }
    if let Some(b) = backup {
        let t = tr("Before this run's first write the config file was copied to:\n{}").replace("{}", &b);
        let h = measure(&t, area.right - area.left, font(), 0);
        let top = (area.bottom - h).max(y + s(grid::GROUP_GAP));
        draw_text(hdc, &t, &RECT { top, bottom: top + h, ..*area }, font(), theme::dim(), DT_WORDBREAK);
    }
}

/// About (§7.1): version, build and commit -- all three from the core and
/// this binary, not composed here (the reason `settings_ui.rs`'s about box
/// gave: two version strings disagree exactly in a bug report).
fn paint_about(hdc: HDC, area: &RECT, dpi: i32) {
    let s = |v: i32| shell::scale(v, dpi);
    let mut y = area.top;
    let big = metrics(bold());
    draw_text(hdc, "Polter", &RECT { top: y, bottom: y + big, ..*area }, bold(), theme::text(), DT_SINGLELINE);
    y += big + s(grid::BUTTON_GAP);
    let tag = tr("A terminal that minds the agents running in it. \nBuilt on Ghostty.");
    let h = measure(&tag, area.right - area.left, font(), 0);
    draw_text(hdc, &tag, &RECT { top: y, bottom: y + h, ..*area }, font(), theme::dim(), DT_WORDBREAK);
    y += h + s(grid::GROUP_GAP);
    let line = metrics(font()).max(s(grid::CONTROL_H));
    let label_right = area.left + s(grid::LABEL_W);
    let control_left = label_right + s(grid::LABEL_GAP);
    for (l, v) in about_values() {
        let name = match l {
            rules::AboutLabel::Version => tr("Version"),
            rules::AboutLabel::Build => tr("Build"),
            rules::AboutLabel::Commit => tr("Commit"),
        };
        draw_text(hdc, &name, &RECT { left: area.left, top: y, right: label_right, bottom: y + line }, font(), theme::dim(), DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
        draw_text(hdc, &v, &RECT { left: control_left, top: y, right: area.right, bottom: y + line }, mono(), theme::text(), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        y += line + s(grid::ROW_GAP);
    }
    y += s(grid::GROUP_GAP);
    draw_text(hdc, &tr("MIT licensed. A fork of Ghostty."), &RECT { top: y, bottom: y + line, ..*area }, font(), theme::dim(), DT_SINGLELINE);
}

/// Version from the core (`ghostty_info`), build as the build mode and this
/// binary's identity -- the string the `[build]` log line carries -- and the
/// host's own commit.
fn about_values() -> Vec<(rules::AboutLabel, String)> {
    let info = unsafe { (crate::api().info)() };
    let version = (!info.version.is_null() && info.version_len > 0)
        .then(|| String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(info.version as *const u8, info.version_len) }).into_owned());
    let mode = match info.build_mode {
        0 => "Debug",
        1 => "ReleaseSafe",
        2 => "ReleaseFast",
        3 => "ReleaseSmall",
        _ => "unknown mode",
    };
    let identity = std::env::current_exe().map(|p| crate::binary_identity(&p)).unwrap_or_default();
    let build = format!("{mode} \u{b7} {identity}");
    let commit = match crate::HOST_COMMIT {
        "" => String::new(),
        c => format!("{c}{}", if crate::HOST_DIRTY == "1" { " (uncommitted changes)" } else { "" }),
    };
    rules::about_rows(version.as_deref(), Some(&build), Some(&commit))
}

/// The form: each key in the label column, right-aligned, with the dot when
/// it differs from its default; the note under each control; a frame around
/// each text box.
fn paint_form(win: HWND) {
    let dpi = dpi_of(win);
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let rows = form_rows(rc.right, dpi);
    let (scroll, items) = ST.with(|c| {
        let s = c.borrow();
        let items: Vec<(Item, Control, Option<String>, HWND, HWND, bool)> = match &s.form {
            Some(f) => s.rows.iter().map(|r| (f.items[r.item].clone(), r.control, r.error.clone(), r.hwnd, r.hwnd2, r.slider)).collect(),
            None => Vec::new(),
        };
        (s.scroll, items)
    });
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(win, &mut ps) };
    fill(hdc, &rc, theme::bg());
    let dot = shell::scale(8, dpi);
    for (r, (it, control, error, h, h2, slider)) in rows.iter().zip(items.iter()) {
        if *slider {
            // The value beside the slider, read off the trackbar itself so
            // it follows a drag before anything is written.
            let (_, tx) = rules::slider_parts(r.control, dpi);
            let tr_ = RECT { left: tx.left, top: tx.top - scroll, right: tx.right, bottom: tx.bottom - scroll };
            draw_text(hdc, &slider_now(*h, it), &tr_, font(), theme::dim(), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        }
        let lr = RECT { left: r.label.left + dot, top: r.label.top - scroll, right: r.label.right, bottom: r.label.bottom - scroll };
        draw_text(hdc, &it.key, &lr, font(), theme::text(), DT_RIGHT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        if rules::differs_from_default(it) {
            let d = RECT { left: r.label.left, top: lr.top, right: r.label.left + dot, bottom: lr.bottom };
            draw_text(hdc, "\u{2022}", &d, font(), theme::focus(), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        }
        if let Some(hr) = r.help {
            let (note, red) = row_note(it, error.as_deref());
            let hr = RECT { left: hr.left, top: hr.top - scroll, right: hr.right, bottom: hr.bottom - scroll };
            draw_text(hdc, &note, &hr, font(), if red { theme::warn() } else { theme::dim() }, DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL);
        }
        if theme::custom_drawing() && !*slider && !matches!(control, Control::Toggle | Control::Choice) {
            for c in [*h, *h2] {
                if c.0.is_null() {
                    continue;
                }
                let mut wr = RECT::default();
                if unsafe { GetWindowRect(c, &mut wr) }.is_ok() {
                    let mut pts = [POINT { x: wr.left, y: wr.top }, POINT { x: wr.right, y: wr.bottom }];
                    unsafe {
                        let _ = MapWindowPoints(None, Some(win), &mut pts);
                        let br = CreateSolidBrush(COLORREF(if error.is_some() { theme::warn() } else { theme::border() }));
                        FrameRect(hdc, &RECT { left: pts[0].x - 1, top: pts[0].y - 1, right: pts[1].x + 1, bottom: pts[1].y + 1 }, br);
                        let _ = DeleteObject(br.into());
                    }
                }
            }
        }
    }
    let _ = unsafe { EndPaint(win, &ps) };
}

// ====================================================== keyboard shortcuts

/// What a UI Automation client is shown for one row -- the struct the
/// provider in `uia.rs` reads, moved here with the page.
#[derive(Clone, Default)]
pub struct KbSnapshotRow {
    pub action: String,
    pub name: String,
    pub keys: String,
    pub note: String,
}

/// The page as another thread may read it: the provider does not run on
/// the window's thread, and `ST` is thread-local (the reason the old page
/// published a snapshot too).
static KB_SNAPSHOT: std::sync::Mutex<Vec<KbSnapshotRow>> = std::sync::Mutex::new(Vec::new());
/// First visible row; `usize::MAX` when the page is not showing -- a
/// different fact from "showing, at the top".
static KB_TOP: AtomicUsize = AtomicUsize::new(usize::MAX);
static KB_FIT: AtomicUsize = AtomicUsize::new(1);
static KB_DPI: AtomicI32 = AtomicI32::new(96);
static KB_WIDTH: AtomicI32 = AtomicI32::new(0);
static KB_BELOW: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Row `index`'s rectangle in the page's own client area, as it is now.
pub fn kb_row_rect(index: usize) -> Option<RECT> {
    rules::kb_row_rect_at(
        KB_TOP.load(Ordering::Acquire),
        KB_FIT.load(Ordering::Acquire),
        KB_DPI.load(Ordering::Acquire),
        KB_WIDTH.load(Ordering::Acquire),
        KB_BELOW.load(Ordering::Acquire),
        index,
    )
    .map(to_rect)
}

pub fn kb_row_count() -> usize {
    KB_SNAPSHOT.lock().map(|r| r.len()).unwrap_or(0)
}

pub fn kb_row(index: usize) -> Option<KbSnapshotRow> {
    KB_SNAPSHOT.lock().ok()?.get(index).cloned()
}

/// Publish what a client may read, and the geometry the rows are drawn at.
fn kb_publish(showing: bool) {
    let h = kb_hwnd();
    let mut rc = RECT::default();
    if !h.0.is_null() {
        let _ = unsafe { GetClientRect(h, &mut rc) };
    }
    let dpi = if h.0.is_null() { 96 } else { dpi_of(h) };
    let below = rules::keybind_note_below(rc.right, dpi);
    let fit = rules::kb_fit(rc.bottom, dpi, below);
    let top = ST.with(|c| {
        let s = c.borrow();
        if let Ok(mut rows) = KB_SNAPSHOT.lock() {
            rows.clear();
            for r in &s.keybinds {
                rows.push(KbSnapshotRow {
                    action: r.action.to_string(),
                    name: r.title.clone().unwrap_or_else(|| r.action.to_string()),
                    keys: crate::keybinds::keys_label(r),
                    note: crate::keybinds::note(r).to_string(),
                });
            }
        }
        KB_TOP.load(Ordering::Acquire)
    });
    KB_FIT.store(fit, Ordering::Release);
    KB_DPI.store(dpi, Ordering::Release);
    KB_WIDTH.store(rc.right, Ordering::Release);
    KB_BELOW.store(below, Ordering::Release);
    let n = kb_row_count();
    let top = if showing { if top == usize::MAX { 0 } else { rules::kb_scroll(top, 0, n, fit) } } else { usize::MAX };
    KB_TOP.store(top, Ordering::Release);
}

fn kb_scroll(by: i32) {
    let top = KB_TOP.load(Ordering::Acquire);
    if top == usize::MAX {
        return;
    }
    let next = rules::kb_scroll(top, by, kb_row_count(), KB_FIT.load(Ordering::Acquire));
    if next != top {
        KB_TOP.store(next, Ordering::Release);
        let _ = unsafe { InvalidateRect(Some(kb_hwnd()), None, true) };
    }
}

fn kb_paint(win: HWND) {
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(win, &mut ps) };
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    fill(hdc, &rc, theme::bg());
    let dpi = dpi_of(win);
    let s = |v: i32| shell::scale(v, dpi);
    let rows = KB_SNAPSHOT.lock().map(|r| r.clone()).unwrap_or_default();
    let hidden: Vec<bool> = ST.with(|c| c.borrow().keybinds.iter().map(|r| r.hidden_from_menu).collect());
    let unbound: Vec<bool> = ST.with(|c| c.borrow().keybinds.iter().map(|r| r.triggers.is_empty()).collect());
    let top = KB_TOP.load(Ordering::Acquire);
    let fit = KB_FIT.load(Ordering::Acquire);
    let below = KB_BELOW.load(Ordering::Acquire);
    // The legend: the list is actions, not bindings or commands -- three
    // different counts live near each other (the old page's note).
    let legend = if rows.is_empty() {
        tr("The shortcuts could not be read from the configuration.")
    } else {
        tr("This page lists actions; {} in all. Some actions have no shortcut assigned.").replace("{}", &rows.len().to_string())
    };
    draw_text(hdc, &legend, &RECT { left: 0, top: 0, right: rc.right, bottom: s(rules::KB_HEADER) - s(grid::BUTTON_GAP) }, font(), theme::dim(), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    if top != usize::MAX {
        let (name_w, keys_w, gap) = (s(rules::KB_NAME_W), s(rules::KB_KEYS_W), s(rules::KB_GAP));
        for i in top..(top + fit).min(rows.len()) {
            let Some(r) = kb_row_rect(i) else { continue };
            let row = &rows[i];
            let line = s(rules::KB_ROW_H);
            let nr = RECT { left: 0, top: r.top, right: name_w, bottom: r.top + line };
            draw_text(hdc, &row.name, &nr, font(), theme::text(), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            let kr = RECT { left: name_w + gap, top: r.top, right: name_w + gap + keys_w, bottom: r.top + line };
            draw_text(hdc, &row.keys, &kr, font(), if unbound.get(i).copied().unwrap_or(false) { theme::dim() } else { theme::text() }, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            if !row.note.is_empty() {
                let colour = if hidden.get(i).copied().unwrap_or(false) { theme::warn() } else { theme::dim() };
                let note = tr(&row.note);
                let nr = if below {
                    RECT { left: name_w + gap, top: r.top + line, right: rc.right, bottom: r.bottom }
                } else {
                    RECT { left: name_w + gap + keys_w + gap, top: r.top, right: rc.right, bottom: r.bottom }
                };
                draw_text(hdc, &note, &nr, font(), colour, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            }
        }
    }
    let _ = unsafe { EndPaint(win, &ps) };
}

// ======================================================= window procedures

unsafe extern "system" fn section_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if let Some(r) = crate::roles_ui::common(win, msg, wp, lp) {
            return r;
        }
        match msg {
            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as u16;
                let code = ((wp.0 >> 16) & 0xFFFF) as u32;
                match id {
                    ID_OPEN_CONFIG | ID_EDIT_KEYBINDS => {
                        // The host's own opening, not `open_config`, which
                        // opens this window (§3.2).
                        let ok = crate::open_config_file(None);
                        // process-wide: opening the config file: one config, one process
                        crate::plogf!("[general-ui] open config file -> handed off: {}", ok);
                    }
                    ID_RELOAD => {
                        let _ = crate::reload::request(false, std::ptr::null_mut());
                    }
                    ID_FILTER if code == 0x0300 => {
                        let q = fixed().map(|f| get_text(f.filter)).unwrap_or_default();
                        set_query(q);
                        rebuild();
                    }
                    _ => {}
                }
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let x = (lp.0 & 0xFFFF) as i16 as i32;
                let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
                let (g, dpi) = laid();
                if let Some(list) = g.list {
                    if let Some(gr) = rules::group_at(list, dpi, x, y) {
                        let _ = SetFocus(Some(win));
                        select(gr);
                    }
                }
                LRESULT(0)
            }
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if vk == VK_UP || vk == VK_DOWN {
                    let i = Group::ALL.iter().position(|g| *g == current());
                    if let Some(n) = shell::step(i, Group::ALL.len(), vk == VK_DOWN) {
                        select(Group::ALL[n]);
                    }
                    return LRESULT(0);
                }
                DefWindowProcW(win, msg, wp, lp)
            }
            WM_SIZE => {
                relayout();
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(win);
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

unsafe extern "system" fn form_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        // A trackbar's paint arrives as the same custom-draw notification a
        // button's does, and `common` would draw it as a push button. The
        // system draws the trackbar; its ground comes from
        // `WM_CTLCOLORSTATIC`, which `common` does answer.
        if msg == WM_NOTIFY {
            let nm = &*(lp.0 as *const NMHDR);
            if nm.code == NM_CUSTOMDRAW && is_trackbar(nm.hwndFrom) {
                return LRESULT(CDRF_DODEFAULT as isize);
            }
        }
        if let Some(r) = crate::roles_ui::common(win, msg, wp, lp) {
            return r;
        }
        match msg {
            WM_HSCROLL if lp.0 != 0 => {
                let bar = HWND(lp.0 as *mut c_void);
                if let Some(i) = row_of_id(GetDlgCtrlID(bar) as u16) {
                    if (wp.0 & 0xFFFF) as u32 == TB_ENDTRACK {
                        slider_released(i);
                    } else {
                        // Moving: the value beside it follows.
                        let _ = InvalidateRect(Some(win), None, false);
                    }
                }
                LRESULT(0)
            }
            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as u16;
                let code = ((wp.0 >> 16) & 0xFFFF) as u32;
                if let Some(i) = row_of_id(id) {
                    match code {
                        // BN_CLICKED / CBN_SELCHANGE (both 0 and 1 carry
                        // the change for these two controls).
                        0 | 1 => changed(i, Commit::Immediately),
                        EN_KILLFOCUS => changed(i, Commit::OnEnterOrBlur),
                        _ => {}
                    }
                }
                LRESULT(0)
            }
            WM_CONTEXTMENU => {
                let mut pt = POINT { x: (lp.0 & 0xFFFF) as i16 as i32, y: ((lp.0 >> 16) & 0xFFFF) as i16 as i32 };
                let screen = pt;
                let _ = ScreenToClient(win, &mut pt);
                if let Some(i) = row_at(pt.y) {
                    context_menu(i, screen);
                }
                LRESULT(0)
            }
            WM_VSCROLL => {
                let mut si = SCROLLINFO { cbSize: std::mem::size_of::<SCROLLINFO>() as u32, fMask: SIF_ALL, ..Default::default() };
                let _ = GetScrollInfo(win, SB_VERT, &mut si);
                let line = shell::scale(grid::CONTROL_H, dpi_of(win));
                let to = match SCROLLBAR_COMMAND((wp.0 & 0xFFFF) as i32) {
                    SB_LINEUP => si.nPos - line,
                    SB_LINEDOWN => si.nPos + line,
                    SB_PAGEUP => si.nPos - si.nPage as i32,
                    SB_PAGEDOWN => si.nPos + si.nPage as i32,
                    SB_THUMBTRACK | SB_THUMBPOSITION => si.nTrackPos,
                    SB_TOP => 0,
                    SB_BOTTOM => si.nMax,
                    _ => si.nPos,
                };
                scroll_form(to);
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
                let now = ST.with(|c| c.borrow().scroll);
                let step = shell::scale(grid::CONTROL_H + grid::ROW_GAP, dpi_of(win)) * 3;
                scroll_form(now - delta * step / 120);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint_form(win);
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

unsafe extern "system" fn kb_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_LBUTTONDOWN => {
                let _ = SetFocus(Some(win));
                LRESULT(0)
            }
            WM_KEYDOWN => {
                let fit = KB_FIT.load(Ordering::Acquire) as i32;
                let by = match VIRTUAL_KEY(wp.0 as u16) {
                    VK_DOWN => 1,
                    VK_UP => -1,
                    VK_NEXT => fit,
                    VK_PRIOR => -fit,
                    _ => return DefWindowProcW(win, msg, wp, lp),
                };
                kb_scroll(by);
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xffff) as i16;
                kb_scroll(if delta > 0 { -3 } else { 3 });
                LRESULT(0)
            }
            // The page draws its rows itself; without a provider a client
            // asking for the tree gets the window and nothing in it.
            WM_GETOBJECT => match crate::uia::on_get_object_keybinds(win, wp, lp) {
                Some(r) => r,
                None => DefWindowProcW(win, msg, wp, lp),
            },
            WM_SIZE => {
                kb_publish(IsWindowVisible(win).as_bool());
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                kb_paint(win);
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}
