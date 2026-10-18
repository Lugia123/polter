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

use polter_settings_shell::general::{self as rules, Commit, Control, FormRead, Group, Item, Kind, ReadOnlyNote, Source};
use polter_settings_shell::inline::{self, Run};
use polter_settings_shell::search as find;
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
/// Log Management's "Show in Explorer": the state directory (`logs_ui`).
const ID_REVEAL_LOGS: u16 = 104;
const ID_ROW_BASE: u16 = 2000;
/// The second box of a theme row (the dark half) is its row's id plus this;
/// so is a folder row's "Choose…", and its "Show in Explorer" is the id
/// plus twice this (`part_of_id`).
const ID_DARK_OFFSET: u16 = 1000;
const ID_RESTORE: usize = 1;
const EN_KILLFOCUS: u32 = 0x0200;
const PROP_PREV: PCWSTR = w!("PolterGeneralPrevProc");

/// One row of a drop-down, in DIP -- what `roles_ui::common` answers
/// `WM_MEASUREITEM` with.
const CHOICE_ROW_H: i32 = 20;
const CHOICE_LIST_ROWS: i32 = 30;
/// How many lines of a key's documentation go under its control, and of
/// its name in the label column: the macOS form's (`ConfigFormView`,
/// task 1550).
const DOC_LINES: i32 = 3;
const LABEL_LINES: i32 = 2;

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
    /// The file this process reads and the one the form would write, when
    /// the core writes nothing for it (#1743): every key row is then
    /// read-only and the banner over the rows names the two.
    read_only: Option<(String, String)>,
    errors: Vec<String>,
    sections: rules::Sections,
    items: Vec<Item>,
}

struct Row {
    /// Index into `Form::items`.
    item: usize,
    control: Control,
    hwnd: HWND,
    /// The dark half of a theme row; a folder row's "Choose…".
    hwnd2: HWND,
    /// A folder row's "Show in Explorer".
    hwnd3: HWND,
    /// The group whose rules draw the row: the one on screen, or in a
    /// search the one the row lives in.
    home: Group,
    /// In a search: the line above the row that says where it lives, and
    /// where a click on it goes (screenshot.md §12.2).
    crumb: Option<(String, shell::Place)>,
    /// A search result that is no row of the form -- a role, a project, a
    /// plugin, an action: the row is this, and `item` names nothing.
    synth: Option<Item>,
    /// What the core said when it refused the last write (§7.3: under the
    /// control, in red, the value back to the effective one).
    error: Option<String>,
    /// A number with a narrow range, drawn as a trackbar with its value
    /// beside it (`rules::slider_for`).
    slider: bool,
    /// "More…" has been clicked: Ghostty's own text is shown in full under
    /// the line, and the link reads "Less" (#977, as on the mac).
    expanded: bool,
}

/// Something the search can find that is not this section's: a role, a
/// project, a plugin or one of a plugin's own settings. `settings_win`
/// collects them; where a click goes is theirs to say.
#[derive(Clone)]
pub struct External {
    pub entry: find::Entry,
    pub crumb: String,
    pub place: shell::Place,
}

/// One result, in the order the core ranked it.
#[derive(Clone)]
struct Hit {
    /// Index into `Form::items` for a row of the form.
    item: Option<usize>,
    home: Group,
    synth: Option<Item>,
    crumb: String,
    place: shell::Place,
}

/// The search box has something in it: the form shows results and the
/// group list stands aside.
struct Search {
    query: String,
    externals: Vec<External>,
    hits: Vec<Hit>,
}

#[derive(Clone, Copy)]
struct Fixed {
    filter: HWND,
    open_config: HWND,
    reload: HWND,
    edit_keybinds: HWND,
    reveal_logs: HWND,
    /// About's three values, as read-only boxes with no frame: words to
    /// look at, and **to select and copy**, as the macOS ones are (task
    /// 1550) -- a version is the thing a bug report needs pasted.
    about: [HWND; 3],
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
    search: Option<Search>,
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
            search: None,
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

pub(crate) fn font() -> HFONT {
    HFONT(FONT.load(Ordering::Acquire))
}

pub(crate) fn bold() -> HFONT {
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
pub(crate) fn ask_json(mut call: impl FnMut(*mut u8, usize) -> usize) -> Option<String> {
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
    // The core always sends the Chinese for a key's first help paragraph
    // (`doc_zh`, task 1751) and has no language of its own to choose by; the
    // interface language is the host's to ask.
    let chinese = crate::plugins::interface_languages().first().is_some_and(|l| l.starts_with("zh"));
    parse_form(&text, shortcut_text, chinese).ok_or_else(|| "the core's answer would not parse".to_string())
}

/// The keys bound to `action` now, written as the menus write them, or
/// "Not set" (screenshot.md §12.3).
fn shortcut_text(action: &str) -> String {
    crate::keys::shortcut_for(action).unwrap_or_else(|| tr("Not set"))
}

/// The item row `r` draws. Total: a row whose item the table no longer has
/// draws as an empty read-only row until the rows are made again, rather
/// than shifting every row after it onto another row's rectangle.
fn item_of(form: Option<&Form>, r: &Row) -> Item {
    r.synth.clone().or_else(|| form.and_then(|f| f.items.get(r.item).cloned())).unwrap_or_else(|| jump_item("", None))
}

/// A result that is no form row, as a row: its name where a label goes and
/// its sentence where a value would be.
fn jump_item(name: &str, summary: Option<&str>) -> Item {
    Item {
        kind: Kind::Jump,
        key: String::new(),
        group: None,
        control: Control::ReadOnly,
        choices: Vec::new(),
        choice_labels: Vec::new(),
        choice_template: None,
        on: None,
        off: None,
        aliases: Vec::new(),
        min: None,
        max: None,
        default: String::new(),
        value: String::new(),
        doc: None,
        doc_zh: None,
        doc_full_zh: None,
        label: Some(name.to_string()),
        summary: summary.map(str::to_string),
        source: Source::Default,
        readonly: None,
    }
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

/// `writeJson`'s document (`src/config/form.zig`). `binding` says what is
/// bound to an action now, as the row shows it.
fn parse_form(text: &str, binding: impl Fn(&str) -> String, chinese: bool) -> Option<Form> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let strs = |x: Option<&serde_json::Value>| -> Vec<String> {
        x.and_then(|a| a.as_array()).map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect()).unwrap_or_default()
    };
    // `null` where the table leaves a value's name to `choice_template`.
    let names = |x: Option<&serde_json::Value>| -> Vec<Option<String>> {
        x.and_then(|a| a.as_array()).map(|a| a.iter().map(|s| s.as_str().map(str::to_string)).collect()).unwrap_or_default()
    };
    let mut sections: rules::Sections = v
        .get("sections")?
        .as_array()?
        .iter()
        .filter_map(|s| Some((s.get("group")?.as_str()?.to_string(), strs(s.get("keys")))))
        .collect();
    let mut items: Vec<Item> = v
        .get("items")?
        .as_array()?
        .iter()
        .filter_map(|it| {
            let st = |k: &str| it.get(k).and_then(|x| x.as_str()).map(str::to_string);
            Some(Item {
                kind: Kind::Key,
                key: st("key")?,
                group: st("group"),
                control: Control::parse(&st("control").unwrap_or_default()),
                choices: strs(it.get("choices")),
                choice_labels: names(it.get("choice_labels")),
                choice_template: st("choice_template"),
                on: st("on"),
                off: st("off"),
                aliases: strs(it.get("aliases")),
                min: it.get("min").and_then(|x| x.as_f64()),
                max: it.get("max").and_then(|x| x.as_f64()),
                default: st("default").unwrap_or_default(),
                value: st("value").unwrap_or_default(),
                doc: st("doc"),
                doc_zh: if chinese { st("doc_zh") } else { None },
                doc_full_zh: if chinese { st("doc_full_zh") } else { None },
                label: st("label"),
                summary: st("summary"),
                source: it.get("source").map(source_of).unwrap_or(Source::Default),
                readonly: st("readonly"),
            })
        })
        .collect();
    // A section's `shortcuts` (screenshot.md §12.3): each is a read-only
    // row after the section's keys, showing what is bound to its action
    // now. The binding is asked of the core here, on every read -- a reload
    // ends in a read, so the row never shows a key that is no longer bound.
    for sec in v.get("sections").and_then(|s| s.as_array()).into_iter().flatten() {
        let Some(group) = sec.get("group").and_then(|g| g.as_str()) else { continue };
        for sc in sec.get("shortcuts").and_then(|a| a.as_array()).into_iter().flatten() {
            let st = |k: &str| sc.get(k).and_then(|x| x.as_str()).map(str::to_string);
            let Some(action) = st("action") else { continue };
            let bound = binding(&action);
            items.push(Item {
                kind: Kind::Shortcut,
                key: action.clone(),
                group: Some(group.to_string()),
                control: Control::ReadOnly,
                choices: Vec::new(),
                choice_labels: Vec::new(),
                choice_template: None,
                on: None,
                off: None,
                aliases: strs(sc.get("aliases")),
                min: None,
                max: None,
                default: bound.clone(),
                value: bound,
                doc: None,
                doc_zh: None,
                doc_full_zh: None,
                label: st("label"),
                summary: st("summary"),
                source: Source::Default,
                readonly: None,
            });
            if let Some((_, keys)) = sections.iter_mut().find(|(g, _)| g == group) {
                keys.push(action);
            }
        }
    }
    let main = v.get("main").and_then(|m| m.as_str()).unwrap_or("").to_string();
    let read_only = rules::read_only_files(v.get("writable").and_then(|w| w.as_bool()), v.get("reads").and_then(|r| r.as_str()), &main);
    if read_only.is_some() {
        rules::hold_every_key(&mut items);
    }
    Some(Form {
        main,
        read_only,
        backup: v.get("backup").and_then(|b| b.as_str()).map(str::to_string),
        errors: strs(v.get("errors")),
        sections,
        items,
    })
}

/// What a write came back with (`setJson`).
pub(crate) struct SetResult {
    pub(crate) ok: bool,
    pub(crate) code: String,
    pub(crate) message: Option<String>,
    /// The file the core wrote, when it says (`form.zig`'s `"wrote"`).
    pub(crate) wrote: Option<String>,
}

impl SetResult {
    /// The status line after a write that took: which file it went to, as
    /// the macOS form says it (task 1550). Nothing when the core named no
    /// file, as there.
    pub(crate) fn saved_line(&self) -> Option<String> {
        self.wrote.as_deref().map(|p| tr("Saved to {}.").replacen("{}", p, 1))
    }
}

/// `ghostty_app_config_set`: `None` restores the default. The write happens
/// once per call, so a result that did not fit is read back with
/// `_set_result`, never by calling again.
///
/// **A write that took is followed by the host's reload, here and nowhere
/// else** (task 1541). The core only writes the file -- "Reloading is the
/// host's" (`ghostty_app_config_set`) -- and each caller used to ask for the
/// reload itself. Log Management's fields did not, so a retention setting
/// changed there reached the file and not the sweep until something else
/// reloaded. With the request inside the one write path no caller can leave
/// it out.
///
/// ⚠️ **Not `GHOSTTY_ACTION_CONFIG_CHANGE` instead.** That arrives from
/// inside `ghostty_app_update_config`, before `reload::perform` has swapped
/// the host's handle, so `read_log_limits` there would read the config being
/// replaced: it would look fixed and keep the old limits. The hard reload
/// reads them after the swap (`reload.rs`).
pub(crate) fn set(key: &str, value: Option<&str>) -> SetResult {
    set_with(key, value, write_through_core, || {
        let _ = crate::reload::request(false, std::ptr::null_mut());
    })
}

/// [`set`] with its two effects handed in, so the rule between them -- a
/// reload after a write that took, and only then -- can be tested without a
/// core. `write` answers the core's JSON, or why there is none.
fn set_with(
    key: &str,
    value: Option<&str>,
    write: impl FnOnce(&str, Option<&str>) -> Result<String, &'static str>,
    reload: impl FnOnce(),
) -> SetResult {
    let failed = |m: &str| SetResult { ok: false, code: "failed".into(), message: Some(m.into()), wrote: None };
    let text = match write(key, value) {
        Ok(t) => t,
        Err(m) => return failed(m),
    };
    let v: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return failed("the core's answer would not parse"),
    };
    // process-wide: the one config file, written from the one settings window
    crate::plogf!("[general-ui] set {} = {:?} -> {}", key, value, text);
    let r = SetResult {
        ok: v.get("ok").and_then(|b| b.as_bool()).unwrap_or(false),
        code: v.get("code").and_then(|c| c.as_str()).unwrap_or("").to_string(),
        message: v.get("message").and_then(|m| m.as_str()).map(str::to_string),
        wrote: v.get("wrote").and_then(|m| m.as_str()).map(str::to_string),
    };
    if r.ok {
        reload();
    }
    r
}

fn write_through_core(key: &str, value: Option<&str>) -> Result<String, &'static str> {
    let Some(api) = crate::api_opt() else { return Err("NoApp") };
    let app = crate::app_opt();
    if app.is_null() {
        return Err("NoApp");
    }
    let (vp, vl) = value.map(|v| (v.as_ptr(), v.len())).unwrap_or((std::ptr::null(), 0));
    let mut buf = vec![0u8; 4096];
    let need = unsafe { (api.app_config_set)(app, key.as_ptr(), key.len(), vp, vl, buf.as_mut_ptr(), buf.len()) };
    if need < buf.len() {
        Ok(String::from_utf8_lossy(&buf[..need]).into_owned())
    } else {
        ask_json(|b, c| unsafe { (api.app_config_set_result)(app, b, c) }).ok_or("the core's answer could not be read")
    }
}

// ============================================================ the window

fn make_fonts(dpi: i32) {
    for (slot, f) in [
        (&FONT, crate::uifont::ui(dpi, polter_settings_shell::type_size::BODY, FW_NORMAL.0 as i32)),
        (&FONT_BOLD, crate::uifont::ui(dpi, polter_settings_shell::type_size::HEADING, FW_SEMIBOLD.0 as i32)),
        (&FONT_MONO, crate::uifont::mono(dpi)),
    ] {
        let old = slot.swap(f.0, Ordering::AcqRel);
        if !old.is_null() {
            let _ = unsafe { DeleteObject(HGDIOBJ(old)) };
        }
    }
}

pub(crate) fn set_font(h: HWND, f: HFONT) {
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
        let value = || {
            let h = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("EDIT"),
                PCWSTR::null(),
                WS_CHILD | WINDOW_STYLE((ES_READONLY | ES_AUTOHSCROLL) as u32),
                0,
                0,
                10,
                10,
                Some(sec),
                None,
                Some(hinst()),
                None,
            )
            .unwrap_or_default();
            crate::settings_win::subclass_child(h);
            h
        };
        let fixed = Fixed {
            filter,
            open_config: button(ID_OPEN_CONFIG),
            reload: button(ID_RELOAD),
            edit_keybinds: button(ID_EDIT_KEYBINDS),
            reveal_logs: button(ID_REVEAL_LOGS),
            about: [value(), value(), value()],
        };
        crate::logs_ui::create(sec);
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
        (f.reveal_logs, tr("Show in Explorer")),
    ] {
        set_font(h, font());
        set_text(h, &t);
    }
    set_font(f.filter, font());
    for h in f.about {
        set_font(h, mono());
    }
    // The placeholder, from the system: this box is not the search field
    // `settings_win.rs` paints its own placeholder into.
    let cue = wide(&tr("Filter by setting name"));
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
        refresh_values(FormRead::Reread);
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
            refresh_values(FormRead::Reread);
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
/// The value the config file holds for `key` now, as the core's table says
/// it; `None` before the table is read. Log Management's fields read theirs
/// here (`logs_ui`).
pub(crate) fn form_value(key: &str) -> Option<String> {
    ST.with(|c| c.borrow().form.as_ref()?.items.iter().find(|i| i.key == key).map(|i| i.value.clone()))
}

fn reload_form() {
    let form = read_form();
    let keybinds = crate::keybinds::listed();
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

pub(crate) fn metrics(f: HFONT) -> i32 {
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

/// A row's label as lines when it is a setting's key (`wrap_key_label`);
/// None for a name, which `DrawText` wraps at its spaces.
fn key_label_lines(title: &str, width: i32) -> Option<Vec<String>> {
    // Never an empty string to `DrawTextW` (`text_width`).
    if title.is_empty() {
        return None;
    }
    rules::wrap_key_label(title, |t| text_width(t, font()) <= width, LABEL_LINES as usize)
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
        Group::Logs => vec![(ID_REVEAL_LOGS, tr("Show in Explorer"))],
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
/// Whether a row ends in a "More…" / "Less" line: only a plain row -- no
/// refusal, nothing read-only to explain -- whose Ghostty text says more
/// than the line does.
fn has_link(it: &Item, error: Option<&str>) -> bool {
    // A shortcut row's line is the way to the page that lists it (§12.1).
    it.kind == Kind::Shortcut || (error.is_none() && rules::readonly_note(it).is_none() && rules::has_more(it))
}

fn link_text(it: &Item, expanded: bool) -> String {
    if it.kind == Kind::Shortcut {
        return tr(Group::Keybinds.msgid());
    }
    if expanded { tr("Less") } else { tr("More…") }
}

fn row_note(it: &Item, error: Option<&str>, expanded: bool) -> (String, bool) {
    if expanded && has_link(it, error) {
        return (rules::expanded_help(it, tr), false);
    }
    row_note_closed(it, error)
}

/// A row's help line as runs, the way the macOS form writes it (task 1604):
/// the key in the fixed-width face, then its sentence, then "More…" after
/// the sentence; and whether it is a complaint, drawn in the warning colour.
fn help_runs(it: &Item, error: Option<&str>, expanded: bool) -> (Vec<(Run, String)>, bool) {
    let (note, red) = row_note(it, error, expanded);
    let mut runs = if !red && !expanded && it.kind == Kind::Key && it.label.is_some() && rules::readonly_note(it).is_none() {
        // `rules::row_help`'s two halves, kept apart so each has its face.
        let mut r = vec![(Run::Key, it.key.clone())];
        if let Some(summary) = &it.summary {
            r.push((Run::Text, tr(summary)));
        }
        r
    } else {
        vec![(Run::Text, note)]
    };
    if has_link(it, error) {
        runs.push((Run::Link, link_text(it, expanded)));
    }
    (runs, red)
}

/// [`help_runs`] flowed into `width`: one device context for every word.
fn help_flow(runs: &[(Run, String)], width: i32, expanded: bool) -> inline::Flow {
    let h = section();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, font().into());
        let measure = |run: Run, text: &str| -> i32 {
            let f = if run == Run::Key { mono() } else { font() };
            SelectObject(dc, f.into());
            let mut r = RECT::default();
            let mut w: Vec<u16> = text.encode_utf16().collect();
            DrawTextW(dc, &mut w, &mut r, DT_SINGLELINE | DT_CALCRECT | DT_NOPREFIX);
            r.right
        };
        // The space "key  sentence" had between its halves.
        let gap = measure(Run::Text, "  ");
        let f = inline::flow(runs, width, gap, &measure, if expanded { 0 } else { DOC_LINES as usize });
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
        f
    }
}

fn row_note_closed(it: &Item, error: Option<&str>) -> (String, bool) {
    if let Some(e) = error {
        return (e.to_string(), true);
    }
    // Its sentence is drawn where a control would be (`paint_form`).
    if it.kind == Kind::Jump {
        return (String::new(), false);
    }
    match rules::readonly_note(it) {
        Some(ReadOnlyNote::SetBy { path, line }) => {
            (tr("Set in {}, line {}.").replacen("{}", &path, 1).replacen("{}", &line.to_string(), 1), false)
        }
        Some(ReadOnlyNote::CommandLine) => (tr("Set on the command line; a change here would not take effect."), false),
        Some(ReadOnlyNote::InTheFile) => (tr("Edited in the config file, not here."), false),
        None => (rules::row_help(it, tr), false),
    }
}

/// The form's rows, laid out in the form window's width.
/// The rows, and the form's whole height, in `width` -- the form window's
/// client width, which does not change with the form's length: its scroll
/// bar is always there (`SIF_DISABLENOSCROLL`, task 990), so the width the
/// controls are laid out in is the width they are painted in.
fn form_rows(width: i32, dpi: i32) -> (Vec<polter_settings_shell::plugins::FormRow>, i32) {
    let (rows, _, total) = form_layout(width, dpi);
    (rows, total)
}

/// `form_rows`, and in a search each row's breadcrumb line above it.
fn form_layout(width: i32, dpi: i32) -> (Vec<polter_settings_shell::plugins::FormRow>, Vec<Rect>, i32) {
    let (texts, crumbed): (Vec<(String, Vec<(Run, String)>, bool)>, bool) = ST.with(|c| {
        let s = c.borrow();
        let texts = s
            .rows
            .iter()
            .map(|r| {
                let it = item_of(s.form.as_ref(), r);
                let (runs, _) = help_runs(&it, r.error.as_deref(), r.expanded);
                (rules::row_title(&it, tr), runs, r.expanded)
            })
            .collect::<Vec<_>>();
        (texts, s.search.is_some())
    });
    let control_w = width - shell::scale(grid::LABEL_W + grid::LABEL_GAP, dpi);
    // The label column less the room the "differs from default" dot takes.
    let label_w = shell::scale(grid::LABEL_W, dpi) - shell::scale(8, dpi);
    let rows: Vec<(i32, i32)> = texts
        .into_iter()
        .map(|(title, runs, expanded)| {
            // Opened, the whole of Ghostty's text. The link follows the
            // sentence on its last line, or takes a line when it does not
            // fit (task 1604). A name too long for the label column wraps
            // (task 990) rather than being cut.
            let help = help_flow(&runs, control_w, expanded).lines as i32 * metrics(font());
            let label = match key_label_lines(&title, label_w) {
                Some(lines) => lines.len() as i32 * metrics(font()),
                None => measure(&title, label_w, font(), LABEL_LINES),
            };
            (label, help)
        })
        .collect();
    let (rows, total) = polter_settings_shell::plugins::form_spaced(width, dpi, &rows, polter_settings_shell::plugins::GENERAL_ROW_GAP);
    if !crumbed {
        return (rows, Vec::new(), total);
    }
    find::with_crumbs(&rows, total, metrics(font()), shell::scale(grid::BUTTON_GAP, dpi))
}

// ================================================================== the form

/// What a click in the form did, if anything: in a search, a breadcrumb
/// line or a result that is no form row goes where it lives; a shortcut
/// row's line goes to Keyboard Shortcuts; a "More…" / "Less" line opens or
/// closes Ghostty's text under it, and the form is laid out again.
fn click_at(win: HWND, x: i32, y: i32) -> bool {
    let (_, dpi) = laid();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let (rows, crumbs, _) = form_layout(rc.right, dpi);
    let line = metrics(font());
    enum Did {
        Go(shell::Place),
        Toggle(usize),
    }
    let did = ST.with(|c| {
        let s = c.borrow();
        let y = y + s.scroll;
        for (i, row) in s.rows.iter().enumerate() {
            let Some(r) = rows.get(i) else { break };
            let it = item_of(s.form.as_ref(), row);
            if let (Some(cr), Some((_, place))) = (crumbs.get(i), &row.crumb) {
                let bottom = r.help.map(|h| h.bottom).unwrap_or(r.control.bottom).max(r.label.bottom);
                let on_crumb = x >= cr.left && x < cr.right && y >= cr.top && y < cr.bottom;
                let on_row = y >= r.label.top && y < bottom;
                if on_crumb || (it.kind == Kind::Jump && on_row) {
                    return Some(Did::Go(place.clone()));
                }
            }
            let Some(hr) = r.help else { continue };
            if !has_link(&it, row.error.as_deref()) {
                continue;
            }
            // Where the link was drawn: after the sentence (task 1604).
            let (runs, _) = help_runs(&it, row.error.as_deref(), row.expanded);
            let Some((at, lx, lw)) = help_flow(&runs, hr.right - hr.left, row.expanded).link() else { continue };
            let top = hr.top + at as i32 * line;
            let left = hr.left + lx;
            if x >= left && x < left + lw && y >= top && y < top + line {
                return Some(if it.kind == Kind::Shortcut {
                    Did::Go(shell::Place { section: shell::Section::General, item: Some(Group::Keybinds.key().to_string()) })
                } else {
                    Did::Toggle(i)
                });
            }
        }
        None
    });
    match did {
        None => false,
        Some(Did::Go(place)) => {
            go(place);
            true
        }
        Some(Did::Toggle(i)) => {
            ST.with(|c| {
                let row = &mut c.borrow_mut().rows[i];
                row.expanded = !row.expanded;
            });
            layout_form(dpi);
            let _ = unsafe { InvalidateRect(Some(win), None, true) };
            true
        }
    }
}

/// Go to where something lives: out of a search through the settings
/// window, which owns the box; otherwise to a group of this section.
fn go(place: shell::Place) {
    // process-wide: the settings window's one General section
    crate::plogf!("[general-ui] go to {}/{:?} (searching: {})", place.section.key(), place.item, is_searching());
    if is_searching() {
        crate::settings_win::leave_search_to(place);
    } else if let Some(g) = place.item.as_deref().and_then(Group::from_key).filter(|_| place.section == shell::Section::General) {
        select(g);
    }
}

pub fn is_searching() -> bool {
    ST.with(|c| c.borrow().search.is_some())
}

/// The search box holds `query` (screenshot.md §12.2): the form shows what
/// it finds, across the whole window, and the group list stands aside.
/// `None` is the box cleared: the section is as it was.
pub fn set_search(search: Option<(String, Vec<External>)>) {
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.search = search.map(|(query, externals)| Search { query, externals, hits: Vec::new() });
        s.status.clear();
        s.status_warn = false;
    });
    if section().0.is_null() {
        return;
    }
    research();
    rebuild();
}

/// Ask the core which entries the query finds. **The list of entries and
/// the list of what each one is are built together, in one loop**, so an
/// index in the answer cannot name a different thing here.
fn research() {
    let Some((query, externals)) = ST.with(|c| c.borrow().search.as_ref().map(|s| (s.query.clone(), s.externals.clone()))) else { return };
    let (form, keybinds) = ST.with(|c| {
        let s = c.borrow();
        (s.form.clone(), s.keybinds.clone())
    });
    let general = crate::settings_win::section_label(shell::Section::General);
    let here = |g: Group| (shell::breadcrumb(&general, Some(&label(g))), shell::Place { section: shell::Section::General, item: Some(g.key().to_string()) });
    let mut entries: Vec<find::Entry> = Vec::new();
    let mut what: Vec<Hit> = Vec::new();
    if let Some(f) = &form {
        for (i, g, e) in find::form_entries(&f.items, &f.sections, tr) {
            let (crumb, place) = here(g);
            entries.push(e);
            what.push(Hit { item: Some(i), home: g, synth: None, crumb, place });
        }
    }
    for x in externals {
        let synth = jump_item(&x.entry.name, x.entry.summary.as_deref());
        entries.push(x.entry);
        what.push(Hit { item: None, home: Group::All, synth: Some(synth), crumb: x.crumb, place: x.place });
    }
    // The Keyboard Shortcuts page's actions: the name it shows, the action,
    // and the keys it has now (§12.3's last row).
    for r in &keybinds {
        let name = r.title.clone().unwrap_or_else(|| r.action.to_string());
        let keys = crate::keybinds::keys_label(r);
        let (crumb, place) = here(Group::Keybinds);
        let synth = jump_item(&name, Some(&keys));
        entries.push(find::Entry { name, key: Some(r.action.to_string()), summary: Some(keys), ..Default::default() });
        what.push(Hit { item: None, home: Group::All, synth: Some(synth), crumb, place });
    }
    let doc = find::json(&entries);
    let answer = match (crate::api_opt(), crate::app_opt()) {
        (Some(api), app) if !app.is_null() => {
            ask_json(|b, c| unsafe { (api.app_config_form_search)(app, doc.as_ptr(), doc.len(), query.as_ptr(), query.len(), b, c) })
        }
        _ => None,
    };
    let indices: Option<Vec<usize>> = answer.as_deref().and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok()).and_then(|v| {
        Some(v.get("hits")?.as_array()?.iter().filter_map(|h| h.get("index").and_then(|i| i.as_u64()).map(|i| i as usize)).collect())
    });
    let hits: Vec<Hit> = find::valid_hits(indices.as_deref().unwrap_or(&[]), what.len()).into_iter().map(|i| what[i].clone()).collect();
    // process-wide: the settings window's one General section
    crate::plogf!(
        "[general-ui] search {:?}: {} entries handed to the core -> {}",
        query,
        entries.len(),
        match &indices {
            Some(_) => format!("{} hit(s)", hits.len()),
            None => "NO ANSWER (the core gave none, or one that would not parse); shown as no results".to_string(),
        }
    );
    ST.with(|c| {
        if let Some(s) = c.borrow_mut().search.as_mut() {
            s.hits = hits;
        }
    });
}

/// Make the controls for the group on screen and put everything in place.
fn rebuild() {
    let doomed: Vec<HWND> = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.scroll = 0;
        s.rows.drain(..).flat_map(|r| [r.hwnd, r.hwnd2, r.hwnd3]).filter(|h| !h.0.is_null()).collect()
    });
    for h in doomed {
        let _ = unsafe { DestroyWindow(h) };
    }
    // What the form shows: a search's results, else the group's keys.
    let wanted: Vec<(usize, Group, Item, Option<(String, shell::Place)>, bool)> = ST.with(|c| {
        let s = c.borrow();
        match (&s.search, &s.form) {
            (Some(search), form) => search
                .hits
                .iter()
                .filter_map(|h| {
                    let it = h.synth.clone().or_else(|| form.as_ref()?.items.get(h.item?).cloned())?;
                    Some((h.item.unwrap_or(usize::MAX), h.home, it, Some((h.crumb.clone(), h.place.clone())), h.synth.is_some()))
                })
                .collect(),
            (None, Some(form)) if s.group.is_form() => {
                rules::items_in(s.group, &form.items, &form.sections, &s.query).into_iter().map(|i| (i, s.group, form.items[i].clone(), None, false)).collect()
            }
            _ => Vec::new(),
        }
    });
    let none = HWND(std::ptr::null_mut());
    let mut made = Vec::new();
    for (i, home, it, crumb, synth) in wanted {
        let control = rules::control_for(&it, home);
        let id = ID_ROW_BASE + made.len() as u16;
        let slider = rules::slider_for(&it, home);
        let (hwnd, hwnd2, hwnd3) = if slider { (make_slider(id), none, none) } else { make_row(control, &it, id) };
        made.push(Row { item: i, control, hwnd, hwnd2, hwnd3, home, crumb, synth: synth.then_some(it), error: None, slider, expanded: false });
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

fn make_row(control: Control, it: &Item, id: u16) -> (HWND, HWND, HWND) {
    let border = if theme::custom_drawing() { WINDOW_STYLE(0) } else { WS_BORDER };
    let edit = WINDOW_STYLE(ES_AUTOHSCROLL as u32) | border;
    let none = HWND(std::ptr::null_mut());
    match control {
        Control::Toggle => (make_control(w!("BUTTON"), WINDOW_STYLE(BS_AUTOCHECKBOX as u32), id), none, none),
        Control::Choice => {
            let od = if theme::custom_drawing() { CBS_OWNERDRAWFIXED } else { 0 };
            // Its rows are put in by `fill_one`, with the value: the list
            // can gain a row when the file says something it does not list.
            (make_control(w!("COMBOBOX"), WINDOW_STYLE((CBS_DROPDOWNLIST | CBS_HASSTRINGS | od) as u32) | WS_VSCROLL, id), none, none)
        }
        Control::Theme => (make_control(w!("EDIT"), edit, id), make_control(w!("EDIT"), edit, id + ID_DARK_OFFSET), none),
        Control::Directory => (
            make_control(w!("EDIT"), edit, id),
            make_button(id + ID_DARK_OFFSET, &tr("Choose…")),
            make_button(id + 2 * ID_DARK_OFFSET, &tr("Show in Explorer")),
        ),
        // A result that goes somewhere has nothing to hold: its sentence is
        // drawn where a control would be.
        Control::ReadOnly if it.kind == Kind::Jump => (none, none, none),
        Control::ReadOnly => (make_control(w!("EDIT"), edit | WINDOW_STYLE(ES_READONLY as u32), id), none, none),
        _ => (make_control(w!("EDIT"), edit, id), none, none),
    }
}

/// A push button in the form. **Not `make_control`**: that one's subclass
/// takes Return for "write this row", and on a button Return is a click.
fn make_button(id: u16, text: &str) -> HWND {
    let h = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(BS_PUSHBUTTON as u32),
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
        set_text(h, text);
        crate::settings_win::subclass_child(h);
    }
    h
}

/// How wide a button is for its label: the text and the grid's padding,
/// as the bottom band's buttons are.
fn button_width(text: &str, dpi: i32) -> i32 {
    text_width(text, font()) + 2 * shell::scale(grid::PAD, dpi)
}

/// Put every row's effective value into its control.
fn fill_rows() {
    let rows: Vec<(HWND, HWND, Control, Item, bool)> = ST.with(|c| {
        let s = c.borrow();
        s.rows.iter().map(|r| (r.hwnd, r.hwnd2, r.control, item_of(s.form.as_ref(), r), r.slider)).collect()
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
            // Names, not values (#977); the index is the value's, so what
            // is written is still the value (`edited_value`). Put in again
            // on every fill: a value the table does not list is a row of
            // its own (screenshot.md §12.3), and it comes and goes with
            // what the file says.
            let idx = rules::choice_index(it).map(|i| i as isize).unwrap_or(-1);
            unsafe {
                SendMessageW(h, CB_RESETCONTENT, Some(WPARAM(0)), Some(LPARAM(0)));
                for o in &rules::choice_titles(it, tr) {
                    let w = wide(o);
                    SendMessageW(h, CB_ADDSTRING, Some(WPARAM(0)), Some(LPARAM(w.as_ptr() as isize)));
                }
                SendMessageW(h, CB_SETCURSEL, Some(WPARAM(idx as usize)), Some(LPARAM(0)));
            }
        }
        // Nothing to fill: there is no control.
        Control::ReadOnly if it.kind == Kind::Jump => {}
        Control::Directory => set_text(h, &it.value),
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
    let searching = is_searching();
    let (filter, _, body) = form_area(&g, dpi, group, searching);
    if let Some(f) = fixed() {
        // A search is across every group: the band is the form's own.
        let buttons = band_buttons(&g, dpi, if searching { Group::All } else { group });
        for (id, h) in [(ID_OPEN_CONFIG, f.open_config), (ID_RELOAD, f.reload), (ID_EDIT_KEYBINDS, f.edit_keybinds), (ID_REVEAL_LOGS, f.reveal_logs)] {
            match buttons.iter().find(|(i, _)| *i == id) {
                Some((_, r)) => place(h, *r, true),
                None => place(h, Rect::new(0, 0, 1, 1), false),
            }
        }
        place(f.filter, filter.unwrap_or(Rect::new(0, 0, 1, 1)), filter.is_some());
    }
    place(form_hwnd(), body, group.is_form() || searching);
    place(kb_hwnd(), body, group == Group::Keybinds && !searching);
    if let Some(f) = fixed() {
        let about = group == Group::About && !searching;
        let at = about_layout(&about_area(&g, dpi), dpi);
        for (i, (h, (_, v))) in f.about.iter().zip(about_values()).enumerate() {
            let r = at.rows[i].1;
            if about {
                // Cut with the mark when the box is too narrow, and the
                // whole value under the pointer (#1552).
                let margins = unsafe { SendMessageW(*h, EM_GETMARGINS, None, None) }.0 as u32;
                let room = (r.right - r.left) - (margins & 0xFFFF) as i32 - (margins >> 16) as i32;
                // Never an empty string to `DrawTextW` (`text_width`).
                let shown = rules::elide_end(&v, |t| t.is_empty() || text_width(t, mono()) <= room);
                set_text(*h, &shown);
                about_tip(*h, (shown != v).then_some(v.as_str()));
            }
            place(*h, Rect::new(r.left, r.top, r.right, r.bottom), about);
        }
    }
    // Log Management is its own page over the whole editor: its notice
    // runs edge to edge, and it keeps its own margins (`logs_ui`).
    crate::logs_ui::place(g.editor, group == Group::Logs && !searching);
    kb_publish(group == Group::Keybinds && !searching);
    if group.is_form() || searching {
        layout_form(dpi);
    }
    let _ = unsafe { InvalidateRect(Some(sec), None, false) };
}

fn layout_form(dpi: i32) {
    let form = form_hwnd();
    // The bar first, so the client width the rows are laid out in is the
    // one they will be painted in (task 990).
    unsafe {
        let si = SCROLLINFO { cbSize: std::mem::size_of::<SCROLLINFO>() as u32, fMask: SIF_DISABLENOSCROLL, ..Default::default() };
        SetScrollInfo(form, SB_VERT, &si, false);
        let _ = ShowScrollBar(form, SB_VERT, true);
    }
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(form, &mut rc) };
    let (rows, total) = form_rows(rc.right, dpi);
    let view = rc.bottom;
    let (ctls, scroll) = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.scroll = s.scroll.clamp(0, (total - view).max(0));
        (s.rows.iter().map(|r| (r.hwnd, r.hwnd2, r.hwnd3, r.control, r.slider, r.home)).collect::<Vec<_>>(), s.scroll)
    });
    let gap = shell::scale(grid::BUTTONS_GAP, dpi);
    let (choose_w, reveal_w) = (button_width(&tr("Choose…"), dpi), button_width(&tr("Show in Explorer"), dpi));
    for ((h, h2, h3, control, slider, home), r) in ctls.iter().zip(rows.iter()) {
        if h.0.is_null() {
            continue;
        }
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
            } else if *control == Control::Directory {
                let (e, ch, rv) = rules::directory_parts(c, dpi, choose_w, reveal_w);
                for (w, r) in [(*h, e), (*h2, ch), (*h3, rv)] {
                    let _ = SetWindowPos(w, None, r.left, r.top - scroll, r.width(), r.height(), flags);
                }
            } else {
                // A number or a short value is as wide as what goes in it
                // and starts on the control column (#977, same widths as
                // the mac); the rest take the row.
                let w = rules::field_width(*control, *home).map(|v| shell::scale(v, dpi).min(c.width())).unwrap_or(c.width());
                let _ = SetWindowPos(*h, None, c.left, c.top - scroll, w, c.height() + extra, flags);
                if *control == Control::Choice {
                    crate::roles_ui::fit_combo(*h, c.height());
                }
            }
        }
    }
    let si = SCROLLINFO {
        cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
        fMask: SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL,
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
    part_of_id(id).map(|(i, _)| i)
}

/// The row a control's id belongs to, and which of the row's controls it
/// is: 0 the first, 1 the second (a theme's dark half, a folder's
/// "Choose…"), 2 the third (a folder's "Show in Explorer").
fn part_of_id(id: u16) -> Option<(usize, u16)> {
    let n = ST.with(|c| c.borrow().rows.len()) as u16;
    let off = id.checked_sub(ID_ROW_BASE)?;
    let (part, i) = (off / ID_DARK_OFFSET, off % ID_DARK_OFFSET);
    (part <= 2 && i < n).then_some((i as usize, part))
}

/// One of a folder row's two buttons was pressed.
fn directory_button(index: usize, part: u16) {
    let Some((edit, it)) = ST.with(|c| {
        let s = c.borrow();
        let r = s.rows.get(index)?;
        (r.control == Control::Directory).then(|| (r.hwnd, item_of(s.form.as_ref(), r)))
    }) else {
        return;
    };
    let typed = get_text(edit).trim().to_string();
    let root = unsafe { GetAncestor(form_hwnd(), GA_ROOT) };
    if part == 1 {
        // "Choose…": the system's folder picker, opened at what the box
        // says. Picking writes at once, as leaving the box would.
        let picked = pick_folder(root, &typed);
        // not-gated: the branch is which of the row's two buttons was pressed, and the other one logs its own line below
        // process-wide: the settings window's one General section
        crate::plogf!("[general-ui] choose folder for {} (from {:?}) -> {:?}", it.key, typed, picked);
        if let Some(path) = picked {
            set_text(edit, &path);
            changed(index, Commit::OnEnterOrBlur);
        }
        return;
    }
    // "Show in Explorer": the folder in effect -- what the box says, else
    // the one screenshots go to now -- made first if it is not there yet,
    // because a folder nothing has been saved into is still the answer to
    // "where will they go".
    let dir = if typed.is_empty() { crate::shots::dir() } else { Some(std::path::PathBuf::from(&typed)) };
    let Some(dir) = dir else {
        say_status(tr("The screenshot folder could not be worked out."), true);
        return;
    };
    let made = std::fs::create_dir_all(&dir);
    let started = made.is_ok() && crate::shellopen::detached(Some(root), "[general-ui] show folder", dir.to_string_lossy().into_owned());
    // process-wide: the settings window's one General section
    crate::plogf!("[general-ui] show folder {:?}: exists_or_made={:?} handed_to_shell={}", dir, made.as_ref().map(|_| true).map_err(|e| e.to_string()), started);
    if !started {
        say_status(tr("Explorer could not be started."), true);
    }
}

pub(crate) fn say_status(text: String, warn: bool) {
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.status = text;
        s.status_warn = warn;
    });
    let _ = unsafe { InvalidateRect(Some(section()), None, false) };
}

/// The system's folder picker, opened at `start` when that is a folder.
/// `None` when it was cancelled or could not be shown.
pub(crate) fn pick_folder(owner: HWND, start: &str) -> Option<String> {
    use windows::Win32::System::Com::{CoCreateInstance, CoTaskMemFree, CLSCTX_INPROC_SERVER};
    use windows::Win32::UI::Shell::{FileOpenDialog, IFileOpenDialog, IShellItem, SHCreateItemFromParsingName, FOS_FORCEFILESYSTEM, FOS_PICKFOLDERS, SIGDN_FILESYSPATH};
    unsafe {
        let dlg: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER).ok()?;
        let opts = dlg.GetOptions().ok()?;
        dlg.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM).ok()?;
        if !start.is_empty() {
            let w = wide(start);
            if let Ok(item) = SHCreateItemFromParsingName::<_, _, IShellItem>(PCWSTR(w.as_ptr()), None) {
                let _ = dlg.SetFolder(&item);
            }
        }
        // Modal: it runs its own message loop until a folder is picked or
        // the dialog is dismissed. Nothing of `ST` is borrowed here.
        dlg.Show(Some(owner)).ok()?;
        let item = dlg.GetResult().ok()?;
        let p = item.GetDisplayName(SIGDN_FILESYSPATH).ok()?;
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as *const c_void));
        s
    }
}

/// What row `index`'s control says now, as the value to write.
fn edited_value(index: usize) -> Option<(Item, Control, String)> {
    let (h, h2, control, it, slider) = ST.with(|c| {
        let s = c.borrow();
        let r = s.rows.get(index)?;
        Some((r.hwnd, r.hwnd2, r.control, item_of(s.form.as_ref(), r), r.slider))
    })?;
    if slider {
        let v = slider_now(h, &it);
        return Some((it, control, v));
    }
    let v = match control {
        // The table's own two values where it names them: `allow` / `deny`
        // for one switch, and `true` there is refused (screenshot.md §12.3).
        Control::Toggle => rules::toggle_value(&it, unsafe { SendMessageW(h, BM_GETCHECK, None, None).0 == 1 }),
        // The selected row's value: the list shows names (#977), and a name
        // written into the config file would be an invalid value.
        Control::Choice => rules::choice_value(&it, unsafe { SendMessageW(h, CB_GETCURSEL, None, None).0 })?,
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
            s.status = r.saved_line().unwrap_or_default();
            s.status_warn = false;
        });
        // Rule 7: reloading is the host's, through its usual path; `set`
        // asked for it. The reload ends in `config_changed`, which reads the
        // table again.
        refresh_values(FormRead::AfterOwnWrite);
    } else {
        let why = match r.code.as_str() {
            "invalid_value" => r.message.unwrap_or_else(|| tr("Not a valid value for this setting.")),
            "read_only" => tr("This setting is set somewhere the form does not write."),
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
        // The control goes back to the effective value (§7.3); this write's
        // refusal stays under it.
        refresh_values(FormRead::AfterOwnWrite);
    }
}

/// Read the table again and put the values into the controls in place,
/// keeping the keyboard where it is. The rows are made again only when the
/// group now lists other keys. A read that is not the form's own, right
/// after a write, clears the refusals shown under the controls and the red
/// status that said the same (#986).
/// Read the core's table again after a write made elsewhere (Log
/// Management's fields, `logs_ui`).
pub(crate) fn refresh_form_values() {
    refresh_values(FormRead::AfterOwnWrite);
}

fn refresh_values(read: FormRead) {
    if read == FormRead::Reread {
        ST.with(|c| {
            let s = &mut *c.borrow_mut();
            for row in s.rows.iter_mut() {
                row.error = rules::error_after(read, row.error.take());
            }
            if s.status_warn {
                s.status.clear();
                s.status_warn = false;
            }
        });
    }
    let keybinds = crate::keybinds::listed();
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
        if s.search.is_some() {
            // A result names its item by index: the rows stand while the
            // table lists the same keys in the same places.
            return s.form.as_ref().is_some_and(|old| old.items.iter().map(|i| &i.key).eq(form.items.iter().map(|i| &i.key)));
        }
        let keys = rules::items_in(s.group, &form.items, &form.sections, &s.query);
        s.rows.iter().map(|r| r.item).eq(keys.into_iter())
    });
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.form = Some(form);
        s.form_error = None;
    });
    if !same {
        research();
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
        Some(item_of(s.form.as_ref(), r))
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
    let (rows, _) = form_rows(rc.right, dpi_of(form));
    let scroll = ST.with(|c| c.borrow().scroll);
    rows.iter().position(|r| {
        let bottom = r.help.map(|h| h.bottom).unwrap_or(r.control.bottom).max(r.label.bottom);
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
            WM_KEYDOWN if crate::settings_win::is_close_key(wp.0 as u16) => {
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

pub(crate) fn fill(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

pub(crate) fn draw_text(hdc: HDC, s: &str, r: &RECT, f: HFONT, colour: u32, flags: DRAW_TEXT_FORMAT) {
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

/// The banner a form the core will not write for shows over its rows, in
/// the person's language (#1743; the macOS page's sentence).
fn banner_text() -> Option<String> {
    let (reads, writes) = ST.with(|c| c.borrow().form.as_ref().and_then(|f| f.read_only.clone()))?;
    // TRANSLATORS: Settings > General, over the rows when this Polter was
    // started on a config file of its own. The first {} is that file, the
    // second the one the form would otherwise write.
    Some(tr("This Polter reads {}, but the form would write {}. The settings are shown read-only.").replacen("{}", &reads, 1).replacen("{}", &writes, 1))
}

/// Where the filter, the banner and the rows go, on a form page.
fn form_area(g: &shell::SectionGrid, dpi: i32, group: Group, searching: bool) -> (Option<Rect>, Option<(Rect, String)>, Rect) {
    let with_filter = group == Group::All && !searching;
    let (_, plain) = rules::form_area(g.editor, dpi, with_filter);
    let text = if group.is_form() || searching { banner_text() } else { None };
    let h = text.as_ref().map(|t| measure(t, plain.width(), font(), 0));
    let (filter, banner, body) = rules::form_area_with_banner(g.editor, dpi, with_filter, h);
    (filter, banner.zip(text), body)
}

fn paint(win: HWND) {
    let (g, dpi) = laid();
    let s = |v: i32| shell::scale(v, dpi);
    let (searching, group, status, warn, form_error, errors, backup, main) = ST.with(|c| {
        let st = c.borrow();
        (
            st.search.is_some(),
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
            // In a search the list takes no part (screenshot.md §12.2):
            // dimmed, nothing selected, and `section_proc` ignores it.
            let on = *gr == group && !searching;
            if on {
                theme::fill_round(hdc, &r, polter_settings_shell::scale(polter_settings_shell::grid::SECTION_ROW_RADIUS, dpi), theme::sel());
            }
            let t = RECT { left: list.left + g.text_left, ..r };
            let colour = if searching { theme::dim() } else if on { theme::sel_text() } else { theme::text() };
            draw_text(hdc, &label(*gr), &t, font(), colour, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
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
    if let (_, Some((r, t)), _) = form_area(&g, dpi, group, searching) {
        draw_text(hdc, &t, &to_rect(r), font(), theme::warn(), DT_WORDBREAK);
    }
    match group {
        _ if group.is_form() || searching => {
            if let Some(e) = form_error {
                draw_text(hdc, &tr("The settings could not be read: {}").replace("{}", &e), &area, font(), theme::warn(), DT_WORDBREAK);
            }
        }
        Group::Advanced => paint_advanced(hdc, &area, dpi, errors.unwrap_or_else(read_diagnostics), main, backup),
        Group::About => paint_about(hdc, &about_area(&g, dpi), dpi),
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

/// Where About is drawn: the editor less the grid's padding.
fn about_area(g: &shell::SectionGrid, dpi: i32) -> RECT {
    let pad = shell::scale(grid::PAD, dpi);
    let ed = g.editor;
    RECT { left: ed.left + pad, top: ed.top + pad, right: ed.right - pad, bottom: ed.bottom - pad }
}

/// The three links under About's values, as the macOS page's buttons:
/// what each says and where it goes (`polter_links.rs`, the macOS
/// `PolterLinks.swift`'s addresses).
const ABOUT_LINKS: [(&str, &str); 3] = [
    ("Docs", crate::polter_links::DOCS),
    ("GitHub", crate::polter_links::GITHUB),
    ("Ghostty", crate::polter_links::UPSTREAM),
];

/// About's parts, in the macOS page's order (`GeneralAbout`, task 1550):
/// the 64-point icon with the name and the line under it beside it, the
/// three values, the links, and the licence line. **One place for the
/// painter, the boxes and the click**, so the three cannot disagree.
struct AboutLayout {
    icon: RECT,
    title: RECT,
    tag: RECT,
    /// Each value's label and its box.
    rows: [(RECT, RECT); 3],
    links: [RECT; 3],
    licence: RECT,
}

fn about_layout(area: &RECT, dpi: i32) -> AboutLayout {
    let s = |v: i32| shell::scale(v, dpi);
    let icon = RECT { left: area.left, top: area.top, right: area.left + s(64), bottom: area.top + s(64) };
    let text_left = icon.right + s(grid::PAD);
    let title_h = metrics(title_font(dpi));
    let tag_h = measure(&tr("A terminal that minds the agents running in it. \nBuilt on Ghostty."), (area.right - text_left).max(1), font(), 0);
    let block = title_h + s(4) + tag_h;
    let top = icon.top + ((icon.bottom - icon.top) - block).max(0) / 2;
    let title = RECT { left: text_left, top, right: area.right, bottom: top + title_h };
    let tag = RECT { left: text_left, top: title.bottom + s(4), right: area.right, bottom: title.bottom + s(4) + tag_h };
    let mut y = icon.bottom.max(tag.bottom) + s(grid::GROUP_GAP);
    let line = metrics(font()).max(s(grid::CONTROL_H));
    let label_right = area.left + s(grid::LABEL_W);
    let control_left = label_right + s(grid::LABEL_GAP);
    let rows = [0, 1, 2].map(|_| {
        let l = RECT { left: area.left, top: y, right: label_right, bottom: y + line };
        // The box is the mono line's own height, in the middle of the row,
        // so its words sit where painted words would.
        let mh = metrics(mono());
        let v = RECT { left: control_left, top: y + (line - mh) / 2, right: area.right, bottom: y + (line - mh) / 2 + mh };
        y += line + s(grid::ROW_GAP);
        (l, v)
    });
    y += s(grid::GROUP_GAP) - s(grid::ROW_GAP);
    let mut x = area.left;
    let links = ABOUT_LINKS.map(|(word, _)| {
        let w = text_width(&tr(word), font());
        let r = RECT { left: x, top: y, right: x + w, bottom: y + line };
        x = r.right + s(grid::GROUP_GAP);
        r
    });
    y += line + s(grid::GROUP_GAP);
    let licence = RECT { left: area.left, top: y, right: area.right, bottom: y + line };
    AboutLayout { icon, title, tag, rows, links, licence }
}

/// About's name, at the macOS `.title2` semibold.
fn title_font(dpi: i32) -> HFONT {
    thread_local! {
        static F: std::cell::Cell<(i32, isize)> = const { std::cell::Cell::new((0, 0)) };
    }
    F.with(|c| {
        let (at, h) = c.get();
        if at == dpi && h != 0 {
            return HFONT(h as *mut c_void);
        }
        if h != 0 {
            let _ = unsafe { DeleteObject(HGDIOBJ(h as *mut c_void)) };
        }
        let f = crate::uifont::ui(dpi, polter_settings_shell::type_size::TITLE, FW_SEMIBOLD.0 as i32);
        c.set((dpi, f.0 as isize));
        f
    })
}

/// About (§7.1): version, build and commit -- all three from the core and
/// this binary, not composed here (the reason `settings_ui.rs`'s about box
/// gave: two version strings disagree exactly in a bug report). The values
/// themselves are the boxes `relayout` puts over their places.
fn paint_about(hdc: HDC, area: &RECT, dpi: i32) {
    let at = about_layout(area, dpi);
    let icon = crate::app_icon_at(at.icon.right - at.icon.left);
    if !icon.is_invalid() {
        let _ = unsafe { DrawIconEx(hdc, at.icon.left, at.icon.top, icon, at.icon.right - at.icon.left, at.icon.bottom - at.icon.top, 0, None, DI_NORMAL) };
    }
    draw_text(hdc, "Polter", &at.title, title_font(dpi), theme::text(), DT_SINGLELINE);
    draw_text(hdc, &tr("A terminal that minds the agents running in it. \nBuilt on Ghostty."), &at.tag, font(), theme::dim(), DT_WORDBREAK);
    for ((l, _), (label, _)) in at.rows.iter().zip(about_values()) {
        let name = match label {
            rules::AboutLabel::Version => tr("Version"),
            rules::AboutLabel::Build => tr("Build"),
            rules::AboutLabel::Commit => tr("Commit"),
        };
        draw_text(hdc, &name, l, font(), theme::dim(), DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
    }
    for (r, (word, _)) in at.links.iter().zip(ABOUT_LINKS) {
        draw_text(hdc, &tr(word), r, font(), theme::link(), DT_SINGLELINE | DT_VCENTER);
    }
    draw_text(hdc, &tr("MIT licensed. A fork of Ghostty."), &at.licence, font(), theme::dim(), DT_SINGLELINE);
}

/// A click on one of About's links opens it.
fn about_click(x: i32, y: i32) -> bool {
    let (g, dpi) = laid();
    let at = about_layout(&about_area(&g, dpi), dpi);
    let Some((_, (_, url))) = at.links.iter().zip(ABOUT_LINKS).find(|(r, _)| x >= r.left && x < r.right && y >= r.top && y < r.bottom) else {
        return false;
    };
    crate::shellopen::detached(None, "about", url.to_string())
}

/// The tooltip that shows an About value whole when its box shows it cut.
fn about_tip(value: HWND, whole: Option<&str>) {
    thread_local! {
        static TIP: std::cell::Cell<isize> = const { std::cell::Cell::new(0) };
    }
    let parent = unsafe { GetParent(value) }.unwrap_or_default();
    let mut tip = HWND(TIP.with(|t| t.get()) as *mut c_void);
    if tip.0.is_null() || !unsafe { IsWindow(Some(tip)) }.as_bool() {
        if whole.is_none() {
            return;
        }
        tip = unsafe {
            CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE, TOOLTIPS_CLASSW, PCWSTR::null(), WS_POPUP | WINDOW_STYLE(TTS_ALWAYSTIP | TTS_NOPREFIX), 0, 0, 0, 0, Some(parent), None, Some(hinst()), None)
        }
        .unwrap_or_default();
        if tip.0.is_null() {
            return;
        }
        TIP.with(|t| t.set(tip.0 as isize));
    }
    let mut text = whole.map(wide).unwrap_or_else(|| vec![0]);
    let mut ti = TTTOOLINFOW {
        cbSize: std::mem::size_of::<TTTOOLINFOW>() as u32,
        uFlags: TTF_IDISHWND | TTF_SUBCLASS,
        hwnd: parent,
        uId: value.0 as usize,
        lpszText: windows::core::PWSTR(text.as_mut_ptr()),
        ..Default::default()
    };
    // Lines, not one line: wrapped at `tip_max_width` of the work area of
    // the screen the value is on, so the whole value stays on it (#1579 V9).
    let work_w = unsafe {
        let mon = MonitorFromWindow(value, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if GetMonitorInfoW(mon, &mut mi).as_bool() { mi.rcWork.right - mi.rcWork.left } else { 1024 }
    };
    let scale = unsafe { GetDpiForWindow(value) }.max(96) as f64 / 96.0;
    unsafe {
        SendMessageW(tip, TTM_SETMAXTIPWIDTH, None, Some(LPARAM(rules::tip_max_width(work_w, scale) as isize)));
        // Taken away and put back, so the text is the one just worked out.
        SendMessageW(tip, TTM_DELTOOLW, None, Some(LPARAM(&mut ti as *mut _ as isize)));
        if whole.is_some() {
            SendMessageW(tip, TTM_ADDTOOLW, None, Some(LPARAM(&mut ti as *mut _ as isize)));
        }
    }
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
    let (rows, crumbs, _) = form_layout(rc.right, dpi);
    let (scroll, searching, items) = ST.with(|c| {
        let s = c.borrow();
        let items: Vec<(Item, Control, Option<String>, HWND, HWND, bool, bool, Option<String>)> = s
            .rows
            .iter()
            .map(|r| (item_of(s.form.as_ref(), r), r.control, r.error.clone(), r.hwnd, r.hwnd2, r.slider, r.expanded, r.crumb.as_ref().map(|(t, _)| t.clone())))
            .collect();
        (s.scroll, s.search.is_some(), items)
    });
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(win, &mut ps) };
    fill(hdc, &rc, theme::bg());
    // A search that finds nothing says so (screenshot.md §12.2): not an
    // empty page, which reads as a window that failed to draw.
    // In the middle of the page, as the macOS one (task 1550).
    if searching && items.is_empty() {
        let text = tr(find::NO_RESULTS);
        let h = measure(&text, rc.right - rc.left, font(), 0);
        let top = rc.top + ((rc.bottom - rc.top) - h).max(0) / 2;
        let line = RECT { top, bottom: top + h, ..rc };
        draw_text(hdc, &text, &line, font(), theme::dim(), DT_CENTER | DT_WORDBREAK);
    }
    let dot = shell::scale(8, dpi);
    for (i, (r, (it, control, error, h, h2, slider, expanded, crumb))) in rows.iter().zip(items.iter()).enumerate() {
        // Where the result lives, above it; a click goes there (`click_at`).
        if let (Some(text), Some(cr)) = (crumb, crumbs.get(i)) {
            let cr = RECT { left: cr.left + dot, top: cr.top - scroll, right: cr.right, bottom: cr.bottom - scroll };
            draw_text(hdc, text, &cr, font(), theme::link(), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        }
        // A result that is no form row: its sentence where a control would be.
        if it.kind == Kind::Jump {
            let vr = RECT { left: r.control.left, top: r.control.top - scroll, right: r.control.right, bottom: r.control.bottom - scroll };
            draw_text(hdc, &rules::row_help(it, tr), &vr, font(), theme::dim(), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        }
        if *slider {
            // The value beside the slider, read off the trackbar itself so
            // it follows a drag before anything is written.
            let (_, tx) = rules::slider_parts(r.control, dpi);
            let tr_ = RECT { left: tx.left, top: tx.top - scroll, right: tx.right, bottom: tx.bottom - scroll };
            draw_text(hdc, &slider_now(*h, it), &tr_, font(), theme::dim(), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        }
        let lr = RECT { left: r.label.left + dot, top: r.label.top - scroll, right: r.label.right, bottom: r.label.bottom - scroll };
        // Wrapped in the label column (task 990), right-aligned; one line
        // sits on the control's middle as before.
        let title = rules::row_title(it, tr);
        let control_h = shell::scale(grid::CONTROL_H, dpi);
        let key_lines = key_label_lines(&title, lr.right - lr.left);
        let one_line = match &key_lines {
            Some(lines) => lines.len() == 1,
            None => measure(&title, lr.right - lr.left, font(), 0) <= metrics(font()),
        };
        let lr = if one_line { RECT { bottom: lr.top + control_h, ..lr } } else { lr };
        match key_lines {
            // A key broken after its hyphens, a line at a time and each
            // right-aligned, as the macOS label wraps (#1750).
            Some(lines) if !one_line => {
                let line = metrics(font());
                for (k, l) in lines.iter().enumerate() {
                    let at = RECT { top: lr.top + k as i32 * line, bottom: lr.top + (k as i32 + 1) * line, ..lr };
                    draw_text(hdc, l, &at, font(), theme::text(), DT_RIGHT | DT_SINGLELINE);
                }
            }
            _ => {
                let flags = if one_line { DT_RIGHT | DT_SINGLELINE | DT_VCENTER } else { DT_RIGHT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL };
                draw_text(hdc, &title, &lr, font(), theme::text(), flags);
            }
        }
        if rules::differs_from_default(it) {
            let d = RECT { left: r.label.left, top: lr.top, right: r.label.left + dot, bottom: lr.top + control_h };
            draw_text(hdc, "\u{2022}", &d, font(), theme::focus(), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        }
        if let Some(hr) = r.help {
            let (runs, red) = help_runs(it, error.as_deref(), *expanded);
            let flow = help_flow(&runs, hr.right - hr.left, *expanded);
            let line = metrics(font());
            for p in &flow.pieces {
                let top = hr.top - scroll + p.line as i32 * line;
                let pr = RECT { left: hr.left + p.x, top, right: hr.left + p.x + p.w + 1, bottom: top + line };
                let (f, colour) = match p.run {
                    Run::Key => (mono(), theme::dim()),
                    Run::Text => (font(), if red { theme::warn() } else { theme::dim() }),
                    Run::Link => (font(), theme::link()),
                };
                draw_text(hdc, &p.text, &pr, f, colour, DT_LEFT | DT_SINGLELINE | DT_BOTTOM | DT_NOPREFIX);
            }
        }
        if theme::custom_drawing() && !*slider && !matches!(control, Control::Toggle | Control::Choice) {
            // A folder row's second control is a button, which frames itself.
            let boxes = if *control == Control::Directory { [*h, HWND(std::ptr::null_mut())] } else { [*h, *h2] };
            for c in boxes {
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
        tr("{} actions. Some have no shortcut yet.").replace("{}", &rows.len().to_string())
    };
    draw_text(hdc, &legend, &RECT { left: 0, top: 0, right: rc.right, bottom: s(rules::KB_HEADER) - s(grid::BUTTON_GAP) }, font(), theme::dim(), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    if top != usize::MAX {
        let (name_w, keys_w, gap) = (s(rules::KB_NAME_W), s(rules::KB_KEYS_W), s(rules::KB_GAP));
        for i in top..(top + fit).min(rows.len()) {
            let Some(r) = kb_row_rect(i) else { continue };
            let row = &rows[i];
            let line = s(rules::KB_LINE_H);
            // The name, and under it the action's tag in the fixed-width
            // face: what a config file is written in. An action with no
            // name of its own is its tag, once (task 1550, the macOS page).
            let named = row.name != row.action;
            let nr = RECT { left: 0, top: r.top, right: name_w, bottom: r.top + line };
            draw_text(hdc, &row.name, &nr, if named { font() } else { mono() }, theme::text(), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            if named {
                let tr_ = RECT { left: 0, top: nr.bottom, right: name_w, bottom: nr.bottom + line };
                draw_text(hdc, &row.action, &tr_, mono(), theme::dim(), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            }
            // Two lines, as the name and its tag have, each in its own line
            // box like theirs: the second key of `copy_to_clipboard` used to
            // be cut at one ("Copy  Ctrl+Inser…"). The lines are made by
            // `pack_keys`, whole keys only, and each is drawn on its own --
            // left to `DT_WORDBREAK`, a line started with the gap's spaces
            // and a stray third one appeared (#1750).
            let colour = if unbound.get(i).copied().unwrap_or(false) { theme::dim() } else { theme::text() };
            let lines = rules::pack_keys(&row.keys, |t| text_width(t, mono()) <= keys_w, 2);
            for (k, l) in lines.iter().enumerate() {
                let top = r.top + k as i32 * line;
                let kr = RECT { left: name_w + gap, top, right: name_w + gap + keys_w, bottom: top + line };
                draw_text(hdc, l, &kr, mono(), colour, DT_SINGLELINE | DT_VCENTER);
            }
            if !row.note.is_empty() {
                let colour = if hidden.get(i).copied().unwrap_or(false) { theme::warn() } else { theme::dim() };
                let note = tr(&row.note);
                // The note wraps in the room it has, as the macOS one does,
                // rather than being cut at one line.
                let nr = if below {
                    RECT { left: name_w + gap, top: r.top + 2 * line, right: rc.right, bottom: r.bottom }
                } else {
                    RECT { left: name_w + gap + keys_w + gap, top: r.top, right: rc.right, bottom: r.bottom }
                };
                draw_text(hdc, &note, &nr, font(), colour, DT_WORDBREAK | DT_END_ELLIPSIS);
            }
        }
    }
    let _ = unsafe { EndPaint(win, &ps) };
}

// ======================================================= window procedures

unsafe extern "system" fn section_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        // About's values are words on the page, not fields: the page's
        // ground behind them, not a box's.
        if msg == WM_CTLCOLORSTATIC && fixed().is_some_and(|f| f.about.contains(&HWND(lp.0 as *mut c_void))) {
            if let Some(b) = theme::on_ground(HDC(wp.0 as *mut c_void)) {
                return LRESULT(b.0 as isize);
            }
        }
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
                    ID_REVEAL_LOGS => crate::logs_ui::reveal(),
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
                if current() == Group::About && !is_searching() && about_click(x, y) {
                    return LRESULT(0);
                }
                let (g, dpi) = laid();
                if let Some(list) = g.list.filter(|_| !is_searching()) {
                    if let Some(gr) = rules::group_at(list, dpi, x, y) {
                        let _ = SetFocus(Some(win));
                        select(gr);
                    }
                }
                LRESULT(0)
            }
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if (vk == VK_UP || vk == VK_DOWN) && !is_searching() {
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
            WM_LBUTTONDOWN => {
                let x = (lp.0 & 0xFFFF) as i16 as i32;
                let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
                if click_at(win, x, y) {
                    return LRESULT(0);
                }
                DefWindowProcW(win, msg, wp, lp)
            }
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
                if let Some((i, part)) = part_of_id(id) {
                    // A folder row's buttons (BN_CLICKED is 0); a theme
                    // row's second control is a box and takes the arms below.
                    let folder = part > 0 && ST.with(|c| c.borrow().rows.get(i).map(|r| r.control)) == Some(Control::Directory);
                    if folder {
                        if code == 0 {
                            directory_button(i, part);
                        }
                        return LRESULT(0);
                    }
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

#[cfg(test)]
mod tests {
    use super::set_with;
    use std::cell::Cell;

    /// Task 1541: Log Management's fields wrote the file and nothing reloaded
    /// it, so the sweep kept its old limits. The reload is now the write
    /// path's own: after a write the core took, exactly once; after one it
    /// refused, or that never reached it, not at all.
    #[test]
    fn a_write_that_took_is_followed_by_one_reload_and_a_refused_one_by_none() {
        let reloads = Cell::new(0);
        let r = set_with("poltergeist-log-keep-days", Some("1"), |_, _| Ok(r#"{"ok":true}"#.into()), || reloads.set(reloads.get() + 1));
        assert!(r.ok);
        assert_eq!(reloads.get(), 1, "a write that took must be followed by the host's reload");

        reloads.set(0);
        let r = set_with("poltergeist-log-keep-days", Some("x"), |_, _| Ok(r#"{"ok":false,"code":"invalid_value"}"#.into()), || reloads.set(reloads.get() + 1));
        assert!(!r.ok);
        assert_eq!(r.code, "invalid_value");
        assert_eq!(reloads.get(), 0, "a refused write changed nothing to reload");

        let r = set_with("poltergeist-log-keep-days", Some("1"), |_, _| Err("NoApp"), || reloads.set(reloads.get() + 1));
        assert!(!r.ok);
        assert_eq!(reloads.get(), 0, "a write that never reached the core changed nothing either");
    }
}
