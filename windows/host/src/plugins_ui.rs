//! The settings window's Plugins section (settings.md §5): the plugins in
//! the sidebar with their status dots, and one plugin's detail -- its title
//! block, the switch, the Settings form and its own Page, Test, the log, and
//! the banner that says a saved change waits for a restart.
//!
//! This replaces the plugin page that was a popup of its own in
//! `settings_ui.rs` (§9 phase 2). The form is that page's form, moved: the
//! control a parameter gets still comes from its schema (`plugins::Control`),
//! and a schema this build cannot turn into a control still falls back to a
//! text box rather than hiding the setting.
//!
//! **What is decided here: nothing that can be decided without a window.**
//! The dot, what is missing, where every block goes, the form's rows and
//! what the page may load are `polter_settings_shell::plugins`, tested off
//! Windows. What the core knows -- whether a copy is running, the test's
//! report, saving -- comes from the core (`plugins::runtimes`, `test`,
//! `configure`), the same functions MCP's `plugin_list`, `plugin_test` and
//! `plugin_configure` run.
//!
//! ⚠️ **Nothing here dispatches a message while `ST` is borrowed**, the rule
//! `roles_ui.rs` states and `windows/tools/borrow-across-dispatch.py` holds:
//! every control handle is copied out of the cell before it is sent
//! anything.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

use polter_settings_shell::plugins::{self as rules, Dot, Tab};
use polter_settings_shell::{self as shell, grid, Rect};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::{n_, tr};
use crate::plugins::{self, Control, Plugin};
use crate::theme;

const ID_SWITCH: u16 = 100;
const ID_TEST: u16 = 101;
const ID_REVERT: u16 = 102;
const ID_SAVE: u16 = 103;
const ID_SHOW_LOG: u16 = 104;
const ID_SHOW_FOLDER: u16 = 105;
const ID_LOG: u16 = 106;
const ID_PARAM_BASE: u16 = 2000;

/// The running states are asked for again this often while the settings
/// window is open, so a dot does not stay green after its plugin fell over.
const TIMER_RUNTIMES: usize = 1;
const RUNTIMES_EVERY_MS: u32 = 5000;

/// One row of a drop-down, in DIP -- the row height `roles_ui::common`
/// answers `WM_MEASUREITEM` with.
const CHOICE_ROW_H: i32 = 20;
/// How many rows a drop-down is created tall. See the note this carried in
/// `settings_ui.rs`: themed comctl32 ignores it and caps at 30 rows by
/// itself; this keeps the unthemed path the same.
const CHOICE_LIST_ROWS: i32 = 30;
/// How tall the summary may grow before it is cut with an ellipsis: an
/// author's sentence is any length, and a title block that grew to fit it
/// would push the form off the window (the old page's `HEAD_MAX_H`).
const SUMMARY_MAX_LINES: i32 = 3;

static SECTION: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
/// The form's own window: the parameter controls are its children, so the
/// form scrolls as one thing inside the body.
static FORM: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_BOLD: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_MONO: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

struct Field {
    /// Parameter name, as the manifest and the settings file spell it.
    name: String,
    hwnd: HWND,
    control: Control,
}

/// The controls made once, with the section: they do not change with the
/// selection.
#[derive(Clone, Copy)]
struct Fixed {
    switch: HWND,
    test: HWND,
    revert: HWND,
    save: HWND,
    show_log: HWND,
    show_folder: HWND,
    log: HWND,
}

struct State {
    plugins: Vec<Plugin>,
    /// `None`: the core was not asked or could not answer (`rules::Facts`).
    runtimes: Option<BTreeMap<String, rules::Runtime>>,
    selected: Option<usize>,
    filter: String,
    tab: Tab,
    fields: Vec<Field>,
    /// What the controls said right after they were made: dirty is "not
    /// this any more".
    baseline: (bool, Vec<(String, String)>),
    scroll: i32,
    form_h: i32,
    status: String,
    status_warn: bool,
    /// The last test's whole report, shown above the log lines.
    tested: Option<String>,
    log: Result<Vec<String>, String>,
    fixed: Option<Fixed>,
}

thread_local! {
    static ST: RefCell<State> = const {
        RefCell::new(State {
            plugins: Vec::new(),
            runtimes: None,
            selected: None,
            filter: String::new(),
            tab: Tab::Settings,
            fields: Vec::new(),
            baseline: (false, Vec::new()),
            scroll: 0,
            form_h: 0,
            status: String::new(),
            status_warn: false,
            tested: None,
            log: Ok(Vec::new()),
            fixed: None,
        })
    };
}

fn section() -> HWND {
    HWND(SECTION.load(Ordering::Acquire))
}

fn form_hwnd() -> HWND {
    HWND(FORM.load(Ordering::Acquire))
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

// ============================================================ the facts

/// Everything the dot of `p` is decided from.
fn facts(p: &Plugin, runtimes: &Option<BTreeMap<String, rules::Runtime>>) -> rules::Facts {
    let values: Vec<(String, String)> = p.values.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    let runtime = runtimes.as_ref().map(|m| m.get(&p.key).cloned().unwrap_or_default());
    rules::Facts {
        enabled: p.enabled,
        missing: rules::missing_required(&params_of(p), &values).len(),
        restart_pending: rules::restart_pending(
            plugins::running_with(&p.key).as_ref(),
            &plugins::settings_of(p),
            runtime.as_ref().map(|r| r.running),
        ),
        runtime,
    }
}

fn params_of(p: &Plugin) -> Vec<(String, String, bool)> {
    p.params.iter().map(|x| (x.name.clone(), x.title.clone(), x.required)).collect()
}

/// A row of the sidebar's plugin list: the index into the catalog, the name,
/// the dot, whether it is the one on screen.
pub struct SidebarRow {
    pub index: usize,
    pub name: String,
    pub dot: Dot,
    pub selected: bool,
}

/// The plugins the sidebar lists (§2.3), narrowed by the search box.
pub fn sidebar_rows() -> Vec<SidebarRow> {
    ST.with(|c| {
        let s = c.borrow();
        s.plugins
            .iter()
            .enumerate()
            .filter(|(_, p)| shell::matches(&s.filter, &p.name))
            .map(|(i, p)| SidebarRow {
                index: i,
                name: p.name.clone(),
                dot: rules::dot(&facts(p, &s.runtimes)),
                selected: s.selected == Some(i),
            })
            .collect()
    })
}

/// The dot's word, translated.
pub fn dot_word(d: Dot) -> String {
    tr(d.msgid())
}

/// A plugin as the search lists it (screenshot.md §12.3): itself, and each
/// of its own settings as `(key, title, help)`.
pub struct SearchRow {
    pub key: String,
    pub name: String,
    pub summary: String,
    pub params: Vec<(String, String, String)>,
}

pub fn search_rows() -> Vec<SearchRow> {
    ST.with(|c| {
        c.borrow()
            .plugins
            .iter()
            .map(|p| SearchRow {
                key: p.key.clone(),
                name: p.name.clone(),
                summary: p.summary.clone(),
                params: p.params.iter().map(|q| (q.name.clone(), q.title.clone(), q.help.clone())).collect(),
            })
            .collect()
    })
}

/// The plugin on screen: its key and its name.
pub fn current() -> Option<(String, String)> {
    ST.with(|c| {
        let s = c.borrow();
        s.selected.and_then(|i| s.plugins.get(i)).map(|p| (p.key.clone(), p.name.clone()))
    })
}

/// The key of the plugin at a catalog index.
pub fn key_at(index: usize) -> Option<String> {
    ST.with(|c| c.borrow().plugins.get(index).map(|p| p.key.clone()))
}

/// The plugin on screen is one the search hid (§2.3a).
pub fn selection_hidden() -> bool {
    ST.with(|c| {
        let s = c.borrow();
        let visible = s.plugins.iter().filter(|p| shell::matches(&s.filter, &p.name)).count();
        let sel = s.selected.and_then(|i| s.plugins.get(i)).map(|p| shell::matches(&s.filter, &p.name));
        shell::filtered(&s.filter, visible, sel).selection_hidden
    })
}

/// Read the catalog and the running states again. The settings window asks
/// on opening and on activation; a selection is kept by key, so a plugin
/// installed meanwhile does not move the one on screen.
pub fn refresh_catalog() {
    let cat = plugins::catalog();
    let runtimes = plugins::runtimes();
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        let key = s.selected.and_then(|i| s.plugins.get(i)).map(|p| p.key.clone());
        s.plugins = cat;
        s.runtimes = runtimes;
        s.selected = key.and_then(|k| s.plugins.iter().position(|p| p.key == k));
    });
}

fn refresh_runtimes() {
    let runtimes = plugins::runtimes();
    set_runtimes(runtimes);
    // A plugin that turned red grows the title block by the core's note;
    // the switch, the tabs and the form are child windows and do not move
    // with a repaint (task 1003: the note was drawn under the switch).
    if head_moved() {
        relayout();
    }
}

fn set_runtimes(r: Option<BTreeMap<String, rules::Runtime>>) {
    ST.with(|c| c.borrow_mut().runtimes = r);
}

/// The title block's height the children were last placed for.
static LAID_HEAD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// Whether the title block is not the height the children were placed
/// for -- the core's note came or went, the summary changed.
fn head_moved() -> bool {
    let win = section();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return false;
    }
    let (_, d, _) = laid();
    d.head.height() != LAID_HEAD.load(Ordering::Acquire)
}

/// The settings window opened: keep the dots current while it is.
pub fn opened() {
    refresh_catalog();
    let h = section();
    if !h.0.is_null() {
        unsafe {
            SetTimer(Some(h), TIMER_RUNTIMES, RUNTIMES_EVERY_MS, None);
        }
    }
}

/// Where the keyboard goes when the page it was in is hidden (task 1005:
/// after `close()` it was left on this section's own window, where no key
/// does anything): the first parameter field, else the switch, else
/// nowhere -- the caller then gives it to the settings window.
pub fn focus_after_page() -> bool {
    let target = first_focusable();
    match target {
        Some(h) => {
            let _ = unsafe { SetFocus(Some(h)) };
            true
        }
        None => false,
    }
}

fn first_focusable() -> Option<HWND> {
    let (fields, switch) = ST.with(|c| {
        let s = c.borrow();
        (s.fields.iter().map(|f| f.hwnd).collect::<Vec<_>>(), s.fixed.map(|f| f.switch))
    });
    fields
        .into_iter()
        .chain(switch)
        .find(|h| !h.0.is_null() && unsafe { IsWindowVisible(*h) }.as_bool() && unsafe { IsWindowEnabled(*h) }.as_bool())
}

pub fn closed() {
    let h = section();
    if !h.0.is_null() {
        unsafe {
            let _ = KillTimer(Some(h), TIMER_RUNTIMES);
        }
    }
    crate::plugin_page::hide();
}

// ============================================================ the window

fn make_font(dpi: i32, px: i32, weight: i32, face: PCWSTR) -> HFONT {
    crate::uifont::make(dpi, px, weight, face)
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

fn font() -> HFONT {
    HFONT(FONT.load(Ordering::Acquire))
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

/// Make the section's windows, once, inside the settings window.
fn create(host: HWND) -> bool {
    unsafe {
        for (class, proc_fn) in [
            (w!("PolterPluginsSection"), section_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT),
            (w!("PolterPluginsForm"), form_proc),
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
            // Zero also when the class is already there; the window below
            // is what says whether this worked.
            let _ = RegisterClassExW(&wc);
        }
        let Ok(sec) = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterPluginsSection"),
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
            // process-wide: the settings window's one plugins section
            crate::plogf!("[plugins-ui] could not make the section window");
            return false;
        };
        SECTION.store(sec.0, Ordering::Release);
        // **The dots' refresh starts with the section** (task 1005): it was
        // started only by `opened`, and only if this window already existed
        // then -- open the settings window on Roles, click into Plugins, and
        // no plugin's dot changed for the rest of that opening. `closed`
        // stops it; the next `opened` starts it again.
        SetTimer(Some(sec), TIMER_RUNTIMES, RUNTIMES_EVERY_MS, None);
        make_fonts(dpi_of(sec));
        let form = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterPluginsForm"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_VSCROLL | WS_TABSTOP,
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
        FORM.store(form.0, Ordering::Release);

        let button = |id: u16, style: u32| {
            let h = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("BUTTON"),
                PCWSTR::null(),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(style),
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
        let fixed = Fixed {
            switch: button(ID_SWITCH, BS_AUTOCHECKBOX as u32),
            test: button(ID_TEST, BS_PUSHBUTTON as u32),
            revert: button(ID_REVERT, BS_PUSHBUTTON as u32),
            save: button(ID_SAVE, BS_PUSHBUTTON as u32),
            show_log: button(ID_SHOW_LOG, BS_PUSHBUTTON as u32),
            show_folder: button(ID_SHOW_FOLDER, BS_PUSHBUTTON as u32),
            log: CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("EDIT"),
                PCWSTR::null(),
                WS_CHILD
                    | WS_VISIBLE
                    | WS_VSCROLL
                    | WS_TABSTOP
                    | WINDOW_STYLE((ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL) as u32),
                0,
                0,
                10,
                10,
                Some(sec),
                Some(HMENU(ID_LOG as usize as *mut c_void)),
                Some(hinst()),
                None,
            )
            .unwrap_or_default(),
        };
        crate::settings_win::subclass_child(fixed.log);
        ST.with(|c| c.borrow_mut().fixed = Some(fixed));
        label_fixed(fixed);
        // process-wide: the settings window's one plugins section
        crate::plogf!("[plugins-ui] section made");
        true
    }
}

fn label_fixed(f: Fixed) {
    let font = font();
    for (h, label) in [
        (f.switch, tr("Enabled")),
        (f.test, tr("Test")),
        (f.revert, tr("Revert")),
        (f.save, tr("Save")),
        (f.show_log, tr("Show Log")),
        (f.show_folder, tr("Show Plugin Folder")),
    ] {
        set_font(h, font);
        set_text(h, &label);
    }
    set_font(f.log, HFONT(FONT_MONO.load(Ordering::Acquire)));
}

fn fixed() -> Option<Fixed> {
    ST.with(|c| c.borrow().fixed)
}

/// Show the section in `rect` of the settings window, at `item` (a plugin
/// key) or else the one selected before, or else the first (§3.1).
pub fn show(host: HWND, rect: RECT, item: Option<&str>) {
    if section().0.is_null() && !create(host) {
        return;
    }
    let win = section();
    let (named, unknown) = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        let named = item.and_then(|k| s.plugins.iter().position(|p| p.key == k));
        let unknown = item.is_some() && named.is_none();
        s.selected = named.or(s.selected.filter(|&i| i < s.plugins.len())).or((!s.plugins.is_empty()).then_some(0));
        (named, unknown)
    });
    unsafe {
        let _ = SetWindowPos(
            win,
            None,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
    }
    rebuild();
    // process-wide: the settings window's one plugins section
    crate::plogf!("[plugins-ui] shown: named={:?} unknown_key={}", named, unknown);
}

pub fn hide() {
    let win = section();
    if win.0.is_null() {
        return;
    }
    crate::plugin_page::hide();
    // hides without handing the foreground back: a child window, which
    // cannot be the foreground; the settings window does the handback
    let _ = unsafe { ShowWindow(win, SW_HIDE) };
}

pub fn move_to(rect: RECT) {
    let win = section();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return;
    }
    unsafe {
        let _ = SetWindowPos(
            win,
            None,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOZORDER | SWP_NOACTIVATE,
        );
    }
}

pub fn dpi_changed() {
    let win = section();
    if win.0.is_null() {
        return;
    }
    make_fonts(dpi_of(win));
    if let Some(f) = fixed() {
        label_fixed(f);
    }
    rebuild();
}

/// A theme change: whether the combo boxes draw themselves is a style fixed
/// at creation, so the form is made again (the note `settings_ui.rs` had).
pub fn theme_changed() {
    if !section().0.is_null() && unsafe { IsWindowVisible(section()) }.as_bool() {
        rebuild();
    }
}

// ============================================================== layout

/// The section's grid and the detail's blocks, for the window as it is now.
fn laid() -> (shell::SectionGrid, rules::Detail, i32) {
    let win = section();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let dpi = dpi_of(win);
    let g = shell::section_grid(rc.right, rc.bottom, dpi, false);
    let p = ST.with(|c| {
        let s = c.borrow();
        s.selected.and_then(|i| s.plugins.get(i)).cloned().map(|p| (p.clone(), rules::dot(&facts(&p, &s.runtimes))))
    });
    let (banner, head_h) = match &p {
        Some((p, d)) => (*d == Dot::Changed, head(p, *d, g.editor.width() - 2 * shell::scale(grid::PAD, dpi)).height),
        None => (false, 0),
    };
    let (line_h, _) = metrics(HFONT(FONT_MONO.load(Ordering::Acquire)));
    let d = rules::detail(g.editor, dpi, rules::DetailInput { banner, head_h, log_line_h: line_h });
    (g, d, dpi)
}

fn metrics(font: HFONT) -> (i32, i32) {
    let h = section();
    let mut tm = TEXTMETRICW::default();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, font.into());
        let _ = GetTextMetricsW(dc, &mut tm);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    (tm.tmHeight, tm.tmAscent)
}

/// How tall `text` is wrapped to `width` in `font`, capped at `max_lines`
/// lines (0: no cap).
fn measure(text: &str, width: i32, font: HFONT, max_lines: i32) -> i32 {
    if text.is_empty() {
        return 0;
    }
    let h = section();
    let mut r = RECT { left: 0, top: 0, right: width.max(1), bottom: 0 };
    let mut w: Vec<u16> = text.encode_utf16().collect();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, font.into());
        DrawTextW(dc, &mut w, &mut r, DT_LEFT | DT_WORDBREAK | DT_CALCRECT | DT_NOPREFIX);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    let line = metrics(font).0;
    if max_lines > 0 {
        r.bottom.min(line * max_lines)
    } else {
        r.bottom
    }
}

/// The title block's lines (§5.2 item 1), each with its height and how it
/// is drawn.
struct Head {
    lines: Vec<(String, HFONT, u32, i32)>,
    height: i32,
}

fn head(p: &Plugin, dot: Dot, width: i32) -> Head {
    let bold = HFONT(FONT_BOLD.load(Ordering::Acquire));
    let f = font();
    let mut lines: Vec<(String, HFONT, u32, i32)> = Vec::new();
    lines.push((p.name.clone(), bold, theme::text(), metrics(bold).0));
    let meta: Vec<&str> = [p.version.as_str(), p.author.as_str()].into_iter().filter(|s| !s.is_empty()).collect();
    if !meta.is_empty() {
        lines.push((meta.join(" \u{b7} "), f, theme::dim(), metrics(f).0));
    }
    if !p.summary.is_empty() {
        lines.push((p.summary.clone(), f, theme::dim(), measure(&p.summary, width, f, SUMMARY_MAX_LINES)));
    }
    let sub = subscription_line(&p.events);
    lines.push((sub.clone(), f, theme::dim(), measure(&sub, width, f, 2)));
    // What the core says about it, when the dot is red; and when the core
    // said nothing at all, that it did not -- ● then means "nobody said
    // otherwise", and the page should not pass that off as "running fine".
    let (runtimes_known, note) = ST.with(|c| {
        let s = c.borrow();
        (s.runtimes.is_some(), s.runtimes.as_ref().and_then(|m| m.get(&p.key)).map(|r| r.note.clone()).unwrap_or_default())
    });
    if dot == Dot::Error && !note.trim().is_empty() {
        lines.push((note.clone(), f, theme::warn(), measure(&note, width, f, 3)));
    } else if !runtimes_known && p.enabled {
        let t = tr("Polter's core did not say whether this plugin is running.");
        lines.push((t.clone(), f, theme::dim(), measure(&t, width, f, 2)));
    }
    let gap = shell::scale(grid::BUTTON_GAP, dpi_of(section()));
    let height = lines.iter().map(|l| l.3).sum::<i32>() + gap * (lines.len() as i32 - 1).max(0);
    Head { lines, height }
}

// ================================================================ the form

/// Destroy the parameter controls and make the selected plugin's, then put
/// everything where the layout says.
fn rebuild() {
    let form = form_hwnd();
    // **Handles out first, destroyed with the cell released**: destroying a
    // visible child repaints its parent, and the parent's paint reads `ST`
    // (the crash note `settings_ui.rs` carried).
    let doomed: Vec<HWND> = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.scroll = 0;
        s.fields.drain(..).map(|f| f.hwnd).collect()
    });
    for h in doomed {
        let _ = unsafe { DestroyWindow(h) };
    }
    let plugin = ST.with(|c| {
        let s = c.borrow();
        s.selected.and_then(|i| s.plugins.get(i)).cloned()
    });
    let font = font();
    let mut made: Vec<Field> = Vec::new();
    if let Some(p) = &plugin {
        for (i, param) in p.params.iter().enumerate() {
            let id = ID_PARAM_BASE + i as u16;
            let cur = p.values.get(&param.name).cloned();
            let (class, style) = match &param.control {
                Control::Flag => (w!("BUTTON"), WINDOW_STYLE(BS_AUTOCHECKBOX as u32)),
                Control::Choice(_) => {
                    // Owner drawn only when this window draws its own
                    // controls: under high contrast the system draws it.
                    let od = if theme::custom_drawing() { CBS_OWNERDRAWFIXED } else { 0 };
                    (w!("COMBOBOX"), WINDOW_STYLE((CBS_DROPDOWNLIST | CBS_HASSTRINGS | od) as u32 | WS_VSCROLL.0))
                }
                Control::Text => {
                    // The theme's light border is dropped when the frame is
                    // drawn here, in the shared border colour.
                    let border = if theme::custom_drawing() { WINDOW_STYLE(0) } else { WS_BORDER };
                    let pw = if param.secret { ES_PASSWORD } else { 0 };
                    (w!("EDIT"), WINDOW_STYLE((ES_AUTOHSCROLL | pw) as u32) | border)
                }
            };
            let Ok(h) = (unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    class,
                    PCWSTR::null(),
                    WS_CHILD | WS_VISIBLE | WS_TABSTOP | style,
                    0,
                    0,
                    10,
                    10,
                    Some(form),
                    Some(HMENU(id as usize as *mut c_void)),
                    Some(hinst()),
                    None,
                )
            }) else {
                continue;
            };
            crate::settings_win::subclass_child(h);
            set_font(h, font);
            match &param.control {
                Control::Flag => {
                    let on = cur.as_deref().unwrap_or(param.default.as_deref().unwrap_or("false")) == "true";
                    unsafe {
                        SendMessageW(h, BM_SETCHECK, Some(WPARAM(on as usize)), Some(LPARAM(0)));
                    }
                }
                Control::Choice(options) => {
                    for o in options {
                        let w = wide(o);
                        unsafe {
                            SendMessageW(h, CB_ADDSTRING, Some(WPARAM(0)), Some(LPARAM(w.as_ptr() as isize)));
                        }
                    }
                    let want = cur.clone().or_else(|| param.default.clone());
                    let idx = want.and_then(|v| options.iter().position(|o| *o == v)).unwrap_or(0);
                    unsafe {
                        SendMessageW(h, CB_SETCURSEL, Some(WPARAM(idx)), Some(LPARAM(0)));
                    }
                }
                Control::Text => {
                    // The stored value, or the schema's default as a
                    // starting point.
                    if let Some(v) = cur.as_ref().or(param.default.as_ref()) {
                        set_text(h, v);
                    }
                }
            }
            made.push(Field { name: param.name.clone(), hwnd: h, control: param.control.clone() });
        }
    }
    let enabled = plugin.as_ref().is_some_and(|p| p.enabled);
    if let Some(f) = fixed() {
        unsafe {
            SendMessageW(f.switch, BM_SETCHECK, Some(WPARAM(enabled as usize)), Some(LPARAM(0)));
        }
    }
    let values = read_fields(&made);
    let key = plugin.as_ref().map(|p| p.key.clone());
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.fields = made;
        s.baseline = (enabled, values);
        s.status.clear();
        s.tested = None;
        if !s.plugins.get(s.selected.unwrap_or(usize::MAX)).is_some_and(|p| crate::plugins::page_of(p).is_some()) {
            s.tab = Tab::Settings;
        }
    });
    reload_log(key.as_deref());
    relayout();
    changed();
}

/// Every field's value as it would be saved: a flag as `true` / `false`,
/// a choice as its text, a text box as typed.
fn read_fields(fields: &[Field]) -> Vec<(String, String)> {
    fields
        .iter()
        .map(|f| {
            let v = match f.control {
                Control::Flag => {
                    let on = unsafe { SendMessageW(f.hwnd, BM_GETCHECK, None, None).0 == 1 };
                    (if on { "true" } else { "false" }).to_string()
                }
                _ => get_text(f.hwnd),
            };
            (f.name.clone(), v)
        })
        .collect()
}

/// The draft: the switch and every field, read off the controls.
fn draft() -> (bool, Vec<(String, String)>) {
    let (switch, handles): (HWND, Vec<(String, HWND, Control)>) = ST.with(|c| {
        let s = c.borrow();
        (
            s.fixed.map(|f| f.switch).unwrap_or_default(),
            s.fields.iter().map(|f| (f.name.clone(), f.hwnd, f.control.clone())).collect(),
        )
    });
    let on = !switch.0.is_null() && unsafe { SendMessageW(switch, BM_GETCHECK, None, None).0 == 1 };
    let fields: Vec<Field> = handles.into_iter().map(|(name, hwnd, control)| Field { name, hwnd, control }).collect();
    (on, read_fields(&fields))
}

/// §2.4: the plugin on screen has changes not saved.
pub fn is_dirty() -> bool {
    if section().0.is_null() || current().is_none() {
        return false;
    }
    let base = baseline();
    draft() != base
}

/// What the controls said right after they were made. A function of its
/// own so the borrow ends before the caller reads the controls.
fn baseline() -> (bool, Vec<(String, String)>) {
    ST.with(|c| c.borrow().baseline.clone())
}

/// A field or the switch changed: Save and Revert, the switch's own
/// availability, and the note beside it follow.
fn changed() {
    let Some(f) = fixed() else { return };
    let has = current().is_some();
    let dirty = is_dirty();
    let (on, values) = draft();
    let params = ST.with(|c| {
        let s = c.borrow();
        s.selected.and_then(|i| s.plugins.get(i)).map(params_of).unwrap_or_default()
    });
    let missing = rules::missing_required(&params, &values);
    // Through `settings_win::enable`: Save goes grey the moment it is
    // clicked, with the keyboard on it (task 1010). The switch first, so it
    // is already what it will be when the keyboard looks for somewhere to go.
    let sw = crate::settings_win::enable;
    sw(f.switch, has && rules::switch_enabled(on, missing.len()));
    sw(f.test, has);
    sw(f.show_log, has);
    sw(f.show_folder, has);
    sw(f.save, dirty);
    sw(f.revert, dirty);
    let _ = unsafe { InvalidateRect(Some(section()), None, false) };
}

/// Where every child goes, from the layout.
fn relayout() {
    let win = section();
    if win.0.is_null() {
        return;
    }
    let (g, d, dpi) = laid();
    LAID_HEAD.store(d.head.height(), Ordering::Release);
    let s = |v: i32| shell::scale(v, dpi);
    let has = current().is_some();
    let tab = ST.with(|c| c.borrow().tab);
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
    if let Some(f) = fixed() {
        place(f.switch, d.switch, has);
        place(f.test, g.actions[0], true);
        place(f.revert, g.actions[1], true);
        place(f.save, g.actions[2], true);
        place(f.show_log, d.log_buttons[0], has);
        place(f.show_folder, d.log_buttons[1], has);
        place(f.log, d.log, has);
    }
    let form = form_hwnd();
    place(form, d.body, has && tab == Tab::Settings);
    layout_form(dpi);
    // The page, over the same body, when its tab is on.
    let page = ST.with(|c| {
        let st = c.borrow();
        st.selected.and_then(|i| st.plugins.get(i)).cloned()
    });
    match page {
        Some(p) if tab == Tab::Page && plugins::page_of(&p).is_some() => crate::plugin_page::show(win, to_rect(d.body), &p),
        _ => crate::plugin_page::hide(),
    }
    let _ = s;
    let _ = unsafe { InvalidateRect(Some(win), None, false) };
}

/// The form's rows, in the form window's coordinates, before scrolling,
/// and the helps' heights they were laid out with.
/// A parameter's label as the label column shows it.
fn label_text(title: &str, required: bool) -> String {
    if required {
        format!("{title} *")
    } else {
        title.to_string()
    }
}

/// The form's rows in the form window's **client** width. Measured from
/// the window itself, once, for both the controls and the paint: they used
/// to be laid out at one width and framed at another, and with no scroll
/// bar showing the frame ran a scroll bar's width past the box (task 990:
/// 546..1723 against 547..1697 at 144 DPI). The bar is now always there
/// (`SIF_DISABLENOSCROLL`), so the client width does not change with the
/// length of the form.
fn form_rows(dpi: i32) -> (Vec<rules::FormRow>, i32, Vec<(String, String, bool)>) {
    let p = ST.with(|c| {
        let s = c.borrow();
        s.selected.and_then(|i| s.plugins.get(i)).cloned()
    });
    let Some(p) = p else { return (Vec::new(), 0, Vec::new()) };
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(form_hwnd(), &mut rc) };
    let width = rc.right;
    let control_w = width - shell::scale(grid::LABEL_W + grid::LABEL_GAP, dpi);
    let label_w = shell::scale(grid::LABEL_W, dpi);
    let f = font();
    // A label too long for the column wraps (up to three lines) rather
    // than being cut.
    let rows: Vec<(i32, i32)> = p
        .params
        .iter()
        .map(|x| (measure(&label_text(&x.title, x.required), label_w, f, 3), measure(&x.help, control_w, f, 3)))
        .collect();
    let texts = p.params.iter().map(|x| (x.title.clone(), x.help.clone(), x.required)).collect();
    let (rows, h) = rules::form_labeled(width, dpi, &rows);
    (rows, h, texts)
}

fn layout_form(dpi: i32) {
    let form = form_hwnd();
    if form.0.is_null() {
        return;
    }
    // The bar first, so the client width the rows are laid out in is the
    // one they will be painted in.
    unsafe {
        let si = SCROLLINFO { cbSize: std::mem::size_of::<SCROLLINFO>() as u32, fMask: SIF_DISABLENOSCROLL, ..Default::default() };
        SetScrollInfo(form, SB_VERT, &si, false);
        let _ = ShowScrollBar(form, SB_VERT, true);
    }
    let (rows, total, _) = form_rows(dpi);
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(form, &mut rc) };
    let view = rc.bottom;
    let (fields, scroll) = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.form_h = total;
        s.scroll = s.scroll.clamp(0, (total - view).max(0));
        (s.fields.iter().map(|f| (f.hwnd, f.control.clone())).collect::<Vec<_>>(), s.scroll)
    });
    for ((h, control), r) in fields.iter().zip(rows.iter()) {
        let extra = if matches!(control, Control::Choice(_)) { shell::scale(CHOICE_LIST_ROWS * CHOICE_ROW_H, dpi) } else { 0 };
        unsafe {
            let _ = SetWindowPos(
                *h,
                None,
                r.control.left,
                r.control.top - scroll,
                r.control.width(),
                r.control.height() + extra,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
        if matches!(control, Control::Choice(_)) {
            crate::roles_ui::fit_combo(*h, r.control.height());
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

/// A setter of its own, so the borrow ends before the caller lays anything
/// out (`borrow-across-dispatch.py`).
fn set_scroll(to: i32) {
    ST.with(|c| c.borrow_mut().scroll = to);
}

// ================================================================ actions

fn reload_log(key: Option<&str>) {
    let log = match key {
        Some(k) => plugins::log_tail(k, rules::LOG_LINES),
        None => Ok(Vec::new()),
    };
    set_log(log);
    write_log();
}

fn set_log(log: Result<Vec<String>, String>) {
    ST.with(|c| c.borrow_mut().log = log);
}

/// The log box: the last test's report, then the log's last lines -- or why
/// there is no log to show.
fn write_log() {
    let (h, text) = ST.with(|c| {
        let s = c.borrow();
        let mut t = String::new();
        if let Some(r) = &s.tested {
            t.push_str(&tr("Test: {}").replace("{}", r));
            t.push_str("\r\n\r\n");
        }
        match &s.log {
            Ok(lines) if lines.is_empty() => t.push_str(&tr("The log is empty.")),
            Ok(lines) => t.push_str(&lines.join("\r\n")),
            Err(why) => t.push_str(&tr("No log yet: {}").replace("{}", why)),
        }
        (s.fixed.map(|f| f.log).unwrap_or_default(), t)
    });
    if !h.0.is_null() {
        set_text(h, &text);
        // The newest line is the one worth seeing.
        unsafe {
            SendMessageW(h, WM_VSCROLL, Some(WPARAM(SB_BOTTOM.0 as usize)), Some(LPARAM(0)));
        }
    }
}

fn set_status(text: String, warn: bool) {
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.status = text;
        s.status_warn = warn;
    });
    let _ = unsafe { InvalidateRect(Some(section()), None, false) };
}

/// §2.4's save for this section. `Err` is said in the band and keeps the
/// window where it is.
pub fn save_now() -> Result<(), String> {
    let Some((key, _)) = current() else { return Ok(()) };
    let (enabled, values) = draft();
    let all: BTreeMap<String, String> = values.iter().cloned().collect();
    match plugins::configure(&key, enabled, &all) {
        Ok(saved) => {
            let kept: BTreeMap<String, String> = all.iter().filter(|(_, v)| !v.is_empty()).map(|(k, v)| (k.clone(), v.clone())).collect();
            let settings = (enabled, kept.iter().map(|(k, v)| (k.clone(), v.clone())).collect());
            // The core started a copy with these, or none runs: either way
            // nothing waits. Only `already_running` leaves ↻ (§5.2 item 6).
            if saved == plugins::Saved::Applied {
                plugins::started_with(&key, settings);
            }
            ST.with(|c| {
                let s = &mut *c.borrow_mut();
                if let Some(p) = s.selected.and_then(|i| s.plugins.get_mut(i)) {
                    p.enabled = enabled;
                    p.values = kept;
                }
                s.baseline = (enabled, values);
            });
            refresh_runtimes();
            set_status(tr("Saved."), false);
            relayout();
            changed();
            crate::settings_win::crumb_changed();
            Ok(())
        }
        Err(name) => {
            let why = tr("Could not save: {}").replace("{}", &name);
            set_status(why.clone(), true);
            Err(why)
        }
    }
}

pub fn revert_now() {
    rebuild();
}

/// The question §2.4 asks before leaving a plugin with changes.
pub fn ask_to_save(owner: HWND) -> shell::Answer {
    crate::roles_ui::ask_to_save_this(owner, &tr("Save changes to this plugin?"))
}

fn run_test() {
    let Some((key, _)) = current() else { return };
    let (line, full, warn) = match plugins::test(&key) {
        Ok(report) => (report.lines().next().unwrap_or("").to_string(), report, false),
        Err(name) => {
            let why = match name.as_str() {
                "TooSoon" => tr("Tested less than a minute ago. Try again in a minute."),
                "NoSuchPlugin" => tr("Polter's core does not know this plugin."),
                plugins::NO_APP => tr("Polter is not ready yet."),
                other => tr("Test failed: {}").replace("{}", other),
            };
            (why.clone(), why, true)
        }
    };
    // process-wide: a plugin test, asked for from the one settings window
    crate::plogf!("[plugins-ui] test {} -> {}", key, line);
    ST.with(|c| c.borrow_mut().tested = Some(full));
    set_status(line, warn);
    refresh_runtimes();
    reload_log(Some(&key));
}

fn show_log() {
    let Some((key, _)) = current() else { return };
    let Some(path) = plugins::log_path(&key) else { return };
    // The file when there is one, the folder it would be in when not.
    let target = if path.is_file() { path } else { path.parent().map(|p| p.to_path_buf()).unwrap_or(path) };
    let _ = crate::shellopen::detached(None, "[plugins-ui] show log", target.display().to_string());
}

fn show_folder() {
    let dir = ST.with(|c| {
        let s = c.borrow();
        s.selected.and_then(|i| s.plugins.get(i)).map(|p| p.dir.clone())
    });
    if let Some(d) = dir {
        let _ = crate::shellopen::detached(None, "[plugins-ui] show folder", d.display().to_string());
    }
}

/// The tab on screen, and setting it: functions of their own so the borrow
/// ends before the caller lays anything out (`borrow-across-dispatch.py`).
fn tab_now() -> Tab {
    ST.with(|c| c.borrow().tab)
}

fn set_tab(t: Tab) {
    ST.with(|c| c.borrow_mut().tab = t);
}

/// The page asked to be closed: the Settings tab comes back.
pub fn page_closed() {
    set_tab(Tab::Settings);
    relayout();
}

/// The page saved: the form, the dot and the baseline follow what it wrote.
pub fn page_saved() {
    let key = current().map(|(k, _)| k);
    refresh_catalog();
    let tab = tab_now();
    rebuild();
    set_tab(tab);
    relayout();
    crate::settings_win::crumb_changed();
    // process-wide: the one settings window
    crate::plogf!("[plugins-ui] page saved {:?}", key);
}

fn tab_at(x: i32, y: i32) -> Option<Tab> {
    let (_, d, dpi) = laid();
    let has_page = ST.with(|c| {
        let s = c.borrow();
        s.selected.and_then(|i| s.plugins.get(i)).is_some_and(|p| plugins::page_of(p).is_some())
    });
    rules::tabs(has_page).into_iter().enumerate().find_map(|(i, t)| rules::tab_rect(&d, dpi, i).contains(x, y).then_some(t))
}

// ================================================================ painting

fn fill(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

fn draw_text(hdc: HDC, s: &str, r: &RECT, font: HFONT, colour: u32, flags: DRAW_TEXT_FORMAT) {
    let mut w: Vec<u16> = s.encode_utf16().collect();
    if w.is_empty() {
        return;
    }
    let mut r = *r;
    unsafe {
        let old = SelectObject(hdc, font.into());
        SetTextColor(hdc, COLORREF(colour));
        SetBkMode(hdc, TRANSPARENT);
        DrawTextW(hdc, &mut w, &mut r, flags | DT_NOPREFIX);
        SelectObject(hdc, old);
    }
}

fn paint(win: HWND) {
    let (g, d, dpi) = laid();
    let s = |v: i32| shell::scale(v, dpi);
    let (p, dot, missing, status, warn, tab) = ST.with(|c| {
        let st = c.borrow();
        let p = st.selected.and_then(|i| st.plugins.get(i)).cloned();
        let dot = p.as_ref().map(|p| rules::dot(&facts(p, &st.runtimes)));
        (p, dot, (), st.status.clone(), st.status_warn, st.tab)
    });
    let _ = missing;
    let (on, values) = draft();
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(win, &mut ps) };
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    fill(hdc, &rc, theme::bg());
    let f = font();
    let bold = HFONT(FONT_BOLD.load(Ordering::Acquire));

    // The bottom band and the rule over it: this section owns the content
    // column, so it draws its own part of both (§2.3a).
    fill(hdc, &to_rect(g.bottom_rule), theme::border());
    let status_rect = to_rect(g.status);
    draw_text(
        hdc,
        &status,
        &status_rect,
        f,
        if warn { theme::warn() } else { theme::dim() },
        DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS,
    );

    let Some(p) = p else {
        // No plugin to show: why there are none, in the two-problem wording
        // the old page had (a missing directory is not an empty one).
        let why = match plugins::shipped() {
            plugins::Shipped::Found(dir) => tr("No plugins found. The bundled plugin directory exists and holds none this build can read:\n{}")
                .replace("{}", &dir.display().to_string()),
            plugins::Shipped::Missing(dir) => tr("The bundled plugin directory is missing:\n{}\nThis build's resources are not installed next to it.")
                .replace("{}", &dir.display().to_string()),
            plugins::Shipped::NoResourcesDir => tr("The bundled plugin directory could not be located: POLTER_RESOURCES_DIR is not set."),
        };
        let r = RECT { left: d.left, top: g.editor.top + s(grid::PAD), right: g.editor.right - s(grid::PAD), bottom: g.editor.bottom };
        draw_text(hdc, &why, &r, f, theme::dim(), DT_LEFT | DT_WORDBREAK);
        let _ = unsafe { EndPaint(win, &ps) };
        return;
    };
    let dot = dot.unwrap_or(Dot::On);

    if let Some(b) = d.banner {
        let r = to_rect(b);
        fill(hdc, &r, theme::panel());
        unsafe {
            let br = CreateSolidBrush(COLORREF(theme::warn()));
            FrameRect(hdc, &r, br);
            let _ = DeleteObject(br.into());
        }
        let t = RECT { left: r.left + s(grid::PAD), ..r };
        draw_text(hdc, &tr("Restart Polter to apply"), &t, f, theme::warn(), DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    }

    let h = head(&p, dot, d.head.width());
    let mut y = d.head.top;
    // The block gets what `rules::detail` left it -- less than it asked for
    // when the window is short (task 990) -- so a line that would run past
    // its bottom is cut there, with an ellipsis, and nothing after it is
    // drawn over the switch.
    for (i, (text, font, colour, height)) in h.lines.iter().enumerate() {
        if y >= d.head.bottom {
            break;
        }
        let r = RECT { left: d.head.left, top: y, right: d.head.right, bottom: (y + height).min(d.head.bottom) };
        let flags = if i == 0 { DT_SINGLELINE | DT_END_ELLIPSIS } else { DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL };
        draw_text(hdc, text, &r, *font, *colour, flags);
        y += height + s(grid::BUTTON_GAP);
    }

    // The switch's label column, and what is missing beside it.
    let label = RECT { left: d.left, top: d.switch.top, right: d.control_left - s(grid::LABEL_GAP), bottom: d.switch.bottom };
    draw_text(hdc, &tr("Status"), &label, f, theme::dim(), DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
    let missing = rules::missing_required(&params_of(&p), &values);
    let note = if !missing.is_empty() {
        tr("Still empty and required: {}").replace("{}", &missing.join(", "))
    } else {
        format!("{} {}", dot.glyph(), dot_word(dot))
    };
    let _ = on;
    draw_text(
        hdc,
        &note,
        &to_rect(d.switch_note),
        f,
        if missing.is_empty() { theme::dim() } else { theme::warn() },
        DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS,
    );

    // The tabs: the selected one bold, with a line under it.
    let has_page = plugins::page_of(&p).is_some();
    for (i, t) in rules::tabs(has_page).into_iter().enumerate() {
        let r = to_rect(rules::tab_rect(&d, dpi, i));
        let on = t == tab;
        let word = match t {
            Tab::Settings => tr("Settings"),
            Tab::Page => tr("Page"),
        };
        draw_text(hdc, &word, &r, if on { bold } else { f }, if on { theme::text() } else { theme::dim() }, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
        if on {
            fill(hdc, &RECT { left: r.left, top: r.bottom - s(2), right: r.right, bottom: r.bottom }, theme::focus());
        }
    }
    fill(hdc, &RECT { left: d.tabs.left, top: d.tabs.bottom, right: d.tabs.right, bottom: d.tabs.bottom + 1 }, theme::border());

    if tab == Tab::Settings && p.params.is_empty() {
        draw_text(hdc, &tr("This plugin has no settings."), &to_rect(d.body), f, theme::dim(), DT_LEFT | DT_WORDBREAK);
    }
    if tab == Tab::Page {
        // What the page tab says when the page itself cannot be shown
        // (§5.3): the tab stays, and names what is missing.
        let why = match crate::plugin_page::state() {
            rules::PageState::Ready | rules::PageState::Loading => None,
            rules::PageState::LoaderMissing => Some(tr(
                "This plugin brings its own page, and it cannot be shown: WebView2Loader.dll is not next to polter-host.exe, so this installation is incomplete.",
            )),
            rules::PageState::RuntimeMissing => Some(
                tr("This plugin brings its own page, and it cannot be shown: the Microsoft Edge WebView2 Runtime is not installed on this computer. Get it from {} and reopen this window.")
                    .replace("{}", rules::RUNTIME_URL),
            ),
            rules::PageState::Failed(hr) => Some(
                tr("This plugin brings its own page, and it could not be opened (error 0x{}).").replace("{}", &format!("{:08X}", hr as u32)),
            ),
        };
        if let Some(why) = why {
            draw_text(hdc, &why, &to_rect(d.body), f, theme::dim(), DT_LEFT | DT_WORDBREAK);
        }
    }

    // The log's heading.
    draw_text(hdc, &tr("Log"), &to_rect(d.log_head), bold, theme::text(), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
    // The frame around the log box, from its own rectangle.
    if theme::custom_drawing() {
        let r = to_rect(d.log);
        unsafe {
            let br = CreateSolidBrush(COLORREF(theme::border()));
            FrameRect(hdc, &RECT { left: r.left - 1, top: r.top - 1, right: r.right + 1, bottom: r.bottom + 1 }, br);
            let _ = DeleteObject(br.into());
        }
    }
    let _ = unsafe { EndPaint(win, &ps) };
}

/// The form: each label in the label column, right-aligned; each help under
/// its control; a frame around each text field.
fn paint_form(win: HWND) {
    let dpi = dpi_of(win);
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let (rows, _, texts) = form_rows(dpi);
    let (scroll, fields) = ST.with(|c| {
        let s = c.borrow();
        (s.scroll, s.fields.iter().map(|f| (f.hwnd, f.control.clone())).collect::<Vec<_>>())
    });
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(win, &mut ps) };
    fill(hdc, &rc, theme::bg());
    let f = font();
    for (r, (title, help, required)) in rows.iter().zip(texts.iter()) {
        let label = label_text(title, *required);
        let lr = RECT { left: r.label.left, top: r.label.top - scroll, right: r.label.right, bottom: r.label.bottom - scroll };
        // Wrapped in the label column (task 990), right-aligned. A one-line
        // label sits on the control's middle, as before; a longer one starts
        // at the control's top.
        let one_line = measure(&label, r.label.width(), f, 0) <= metrics(f).0;
        let flags = if one_line { DT_RIGHT | DT_SINGLELINE | DT_VCENTER } else { DT_RIGHT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL };
        let lr = if one_line { RECT { bottom: lr.top + shell::scale(grid::CONTROL_H, dpi), ..lr } } else { lr };
        draw_text(hdc, &label, &lr, f, theme::text(), flags);
        if let Some(hr) = r.help {
            let hr = RECT { left: hr.left, top: hr.top - scroll, right: hr.right, bottom: hr.bottom - scroll };
            draw_text(hdc, help, &hr, f, theme::dim(), DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_EDITCONTROL);
        }
    }
    if theme::custom_drawing() {
        for ((_, control), r) in fields.iter().zip(rows.iter()) {
            if matches!(control, Control::Text) {
                let fr = RECT { left: r.control.left - 1, top: r.control.top - scroll - 1, right: r.control.right + 1, bottom: r.control.bottom - scroll + 1 };
                unsafe {
                    let br = CreateSolidBrush(COLORREF(theme::border()));
                    FrameRect(hdc, &fr, br);
                    let _ = DeleteObject(br.into());
                }
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
                match id {
                    ID_SAVE => {
                        let _ = save_now();
                    }
                    ID_REVERT => revert_now(),
                    ID_TEST => run_test(),
                    ID_SHOW_LOG => show_log(),
                    ID_SHOW_FOLDER => show_folder(),
                    ID_SWITCH => changed(),
                    _ => {}
                }
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let x = (lp.0 & 0xFFFF) as i16 as i32;
                let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
                if let Some(t) = tab_at(x, y) {
                    set_tab(t);
                    relayout();
                }
                LRESULT(0)
            }
            crate::plugin_page::WM_PAGE_EVENT => {
                match wp.0 {
                    1 => page_saved(),
                    2 => page_closed(),
                    _ => {}
                }
                LRESULT(0)
            }
            WM_TIMER if wp.0 == TIMER_RUNTIMES => {
                refresh_runtimes();
                crate::settings_win::crumb_changed();
                let _ = InvalidateRect(Some(win), None, false);
                LRESULT(0)
            }
            WM_SIZE => {
                relayout();
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(win);
                // Whatever made the title block taller or shorter since the
                // children were placed -- a refresh of the catalog, a test --
                // they follow it now rather than staying under it.
                if head_moved() {
                    relayout();
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

unsafe extern "system" fn form_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if let Some(r) = crate::roles_ui::common(win, msg, wp, lp) {
            return r;
        }
        match msg {
            // Every field's change is a change of the draft.
            WM_COMMAND => {
                changed();
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

// ======================================================= the subscription

/// What this build can say about an event, one phrase each. Presentation
/// only: an event missing here shows its wire name, so a plugin that
/// subscribes to something newer still says so. Moved with the page from
/// `settings_ui.rs`.
const EVENT_PHRASES: &[(&str, &str)] = &[
    ("chat", n_("Keeps the conversations")),
    ("terminal.quiet", n_("Notifies you")),
    ("provision", n_("Sets your agent up to reach Polter")),
];

/// One line saying what a plugin is handed: phrases where this build has
/// one, wire names where it has not.
fn subscription_line(events: &[String]) -> String {
    if events.is_empty() {
        return tr("Subscribes to nothing, so Polter has nothing to hand it and will not start it.");
    }
    let mut said: Vec<String> = Vec::new();
    for (wire, phrase) in EVENT_PHRASES {
        if events.iter().any(|e| e == wire) {
            said.push(tr(phrase));
        }
    }
    for e in events {
        if !EVENT_PHRASES.iter().any(|(wire, _)| wire == e) {
            // The wire name is not translated: it is the plugin's word.
            said.push(e.clone());
        }
    }
    // One msgid with a placeholder, so a translator has the whole clause.
    tr("What it is handed: {}").replace("{}", &said.join(", "))
}

#[cfg(test)]
mod subscription_tests {
    use super::*;

    #[test]
    fn nothing_is_said_as_nothing() {
        assert!(subscription_line(&[]).contains("nothing"));
    }

    #[test]
    fn known_events_are_phrased_and_unknown_ones_named() {
        let line = subscription_line(&["chat".into(), "future.event".into()]);
        assert!(line.contains("Keeps the conversations"), "{line}");
        assert!(line.contains("future.event"), "{line}");
    }
}
