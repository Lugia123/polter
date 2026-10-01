//! The settings window: one window for roles, projects, plugins and general
//! settings, the same on both hosts. The specification is
//! `dev-docs/poltergeist/settings.md`, shared with the macOS side; section
//! numbers below are that file's. Phase 1 (§9) made the window, the routes,
//! the roles section and "open the config file" under General; phase 2 adds
//! the plugins, listed in the sidebar under their section with their status
//! dots, and their detail (`plugins_ui.rs`); phase 3 the projects section
//! (`projects_ui.rs`).
//!
//! **Every rule is decided in `polter-settings-shell`** -- which section a
//! route opens, when leaving asks, the opening size, whether a remembered
//! rectangle is still on a screen, where the sidebar rows are -- because
//! this crate's tests only run on Windows and that one's run anywhere. What
//! is here is Win32 asking those functions and doing what they say.
//!
//! # Why it belongs to no terminal window (§2.1)
//!
//! The role library used to be owned by the terminal window it was opened
//! over, and an owned window is destroyed with its owner: close that
//! terminal window and the library went with it while this side still held
//! its handle (`dev-docs/windows/status.md`, the role library's section,
//! item 7). This window is created **unowned, once, at startup**, and is
//! hidden rather than destroyed when it closes -- so there is no owner to
//! take it away, and the handle is good for the life of the process. The
//! terminal a route came from is remembered only as `origin`: where a Launch
//! opens its tab, and where the keyboard goes back to.
//!
//! ⚠️ **Nothing here dispatches a message while `ST` is borrowed**, the rule
//! `roles_ui.rs` states and `windows/tools/borrow-across-dispatch.py` holds.

use std::cell::RefCell;
use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::Mutex;

use polter_settings_shell::plugins::{self as plugin_rules, Hit};
use polter_settings_shell::{self as shell, grid, Place, Rect, Route, Section, Unsaved};
use windows::core::{w, BOOL, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWINDOWATTRIBUTE};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, GetDpiForWindow, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::theme;

/// A route asked for from somewhere that is not this window's procedure.
/// **`WM_APP + 18`**, free when written (`grep 'WM_APP +'`); posted to this
/// window only.
const WM_SETTINGS_OPEN: u32 = WM_APP + 18;

const ID_SEARCH: u16 = 10;
const EN_CHANGE: u32 = 0x0300;
const PROP_PREV: PCWSTR = w!("PolterSettingsWinPrevProc");

static WIN: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static SEARCH: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_BOLD: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
/// Set while this side moves the window to where it opens: the move can
/// cross onto a monitor with another DPI, and the rectangle Windows then
/// suggests is the old one rescaled -- a second scaling of a size that was
/// already computed at the new DPI.
static POSITIONING: AtomicBool = AtomicBool::new(false);
/// How far the sidebar's rows are scrolled, in pixels (task 990: with the
/// plugins listed, General went under the bottom band at the smallest
/// window). Kept in range by `plugin_rules::sidebar_max_scroll`.
static SIDE_SCROLL: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
/// The control that had the keyboard when the window was last deactivated,
/// given it back on the next activation (task 999: after switching away and
/// back, typing went into no field). What a dialog does for itself; a plain
/// window's `DefWindowProc` puts the focus on the window instead.
static LAST_FOCUS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Routes asked for from any thread, drained on the window's.
/// `(route, origin HWND as isize)`: a handle is not `Send`.
static PENDING: Mutex<Vec<(Route, isize)>> = Mutex::new(Vec::new());

struct State {
    /// The section on screen; `None` while hidden.
    section: Option<Section>,
    /// Where the window was when it last closed, for the no-argument route.
    last: Option<Place>,
    /// The window the current opening came from. See the header.
    origin: HWND,
    /// Who had the keyboard before the window was shown.
    prev_focus: HWND,
}

thread_local! {
    static ST: RefCell<State> = const {
        RefCell::new(State {
            section: None,
            last: None,
            origin: HWND(std::ptr::null_mut()),
            prev_focus: HWND(std::ptr::null_mut()),
        })
    };
}

fn win() -> HWND {
    HWND(WIN.load(Ordering::Acquire))
}

fn dpi_of(h: HWND) -> i32 {
    match unsafe { GetDpiForWindow(h) } {
        0 => 96,
        d => d as i32,
    }
}

fn to_rect(r: RECT) -> Rect {
    Rect::new(r.left, r.top, r.right, r.bottom)
}

fn from_rect(r: Rect) -> RECT {
    RECT { left: r.left, top: r.top, right: r.right, bottom: r.bottom }
}

/// The section's label, as the sidebar and the breadcrumb show it. The
/// msgids were agreed with the macOS side (settings.md §2.3).
fn label(s: Section) -> String {
    match s {
        Section::Roles => tr("Roles"),
        Section::Projects => tr("Projects"),
        Section::Plugins => tr("Plugins"),
        Section::General => tr("General"),
    }
}

// ============================================================ the routes

/// `openSettings(route)` (§3.1), from anywhere. **Safe from any thread**,
/// and it defers even on the window's own: the callers are menus and the
/// core's action callback, and this may ask a modal question, which is not
/// something to do inside either.
pub fn request(route: Route, origin: HWND) {
    let h = win();
    if h.0.is_null() {
        // process-wide: the settings window does not exist yet, so no window could be meant
        crate::plogf!("[settings] {route:?} was asked for before the window existed");
        return;
    }
    if let Ok(mut q) = PENDING.lock() {
        q.push((route, origin.0 as isize));
    }
    let _ = unsafe { PostMessageW(Some(h), WM_SETTINGS_OPEN, WPARAM(0), LPARAM(0)) };
}

/// Where the window is now, as a route would name it. The item is asked of
/// the section, so it is never a stale copy.
fn current_place() -> Option<Place> {
    let section = ST.with(|c| c.borrow().section)?;
    let item = match section {
        Section::Roles => crate::roles_ui::current().and_then(|(key, _)| key),
        Section::Plugins => crate::plugins_ui::current().map(|(key, _)| key),
        Section::Projects => crate::projects_ui::current(),
        Section::General => Some(crate::general_ui::current().key().to_string()),
    };
    Some(Place { section, item })
}

/// §2.4 for the roles section.
struct RolesSection;

impl Unsaved for RolesSection {
    fn is_dirty(&self) -> bool {
        crate::roles_ui::is_dirty()
    }
    fn save(&mut self) -> Result<(), String> {
        crate::roles_ui::save_now()
    }
    fn revert(&mut self) {
        crate::roles_ui::revert_now()
    }
}

/// §2.4 for the plugins section: the plugin on screen.
struct PluginsSection;

impl Unsaved for PluginsSection {
    fn is_dirty(&self) -> bool {
        crate::plugins_ui::is_dirty()
    }
    fn save(&mut self) -> Result<(), String> {
        crate::plugins_ui::save_now()
    }
    fn revert(&mut self) {
        crate::plugins_ui::revert_now()
    }
}

/// Whether a section has something unsaved. The others show no Revert /
/// Save (§2.3) and never ask.
fn section_dirty(s: Section) -> bool {
    match s {
        Section::Roles => crate::roles_ui::is_dirty(),
        Section::Plugins => crate::plugins_ui::is_dirty(),
        Section::Projects | Section::General => false,
    }
}

/// Leave the section on screen, asking first when something is unsaved.
/// True when it may be left.
fn leave_current() -> bool {
    match ST.with(|c| c.borrow().section) {
        Some(Section::Roles) => shell::leave(&mut RolesSection, crate::roles_ui::ask_to_save),
        Some(Section::Plugins) => shell::leave(&mut PluginsSection, || crate::plugins_ui::ask_to_save(win())),
        _ => true,
    }
}

fn open(route: Route, origin: HWND) {
    let h = win();
    if h.0.is_null() {
        return;
    }
    let (last, prev_origin) = ST.with(|c| {
        let s = c.borrow();
        (s.last.clone(), s.origin)
    });
    let current = current_place();
    let target = shell::resolve(&route, current.as_ref().or(last.as_ref()));
    let visible = unsafe { IsWindowVisible(h) }.as_bool();
    let origin = if origin.0.is_null() { prev_origin } else { origin };
    ST.with(|c| c.borrow_mut().origin = origin);

    if visible {
        let iconic = unsafe { IsIconic(h) }.as_bool();
        if iconic {
            let _ = unsafe { ShowWindow(h, SW_RESTORE) };
        }
        let asked = unsafe { SetForegroundWindow(h) }.as_bool();
        let front = unsafe { GetForegroundWindow() } == h;
        // process-wide: the one settings window, not any terminal window's
        crate::plogf!(
            "[settings] raised (already open) for {}: iconic_before={} set_foreground={} foreground_now={}",
            route,
            iconic,
            asked,
            front
        );
        let dirty = current.as_ref().is_some_and(|c| section_dirty(c.section));
        if shell::must_ask(current.as_ref(), dirty, &target) && !leave_current() {
            // process-wide: as above
            crate::plogf!("[settings] stayed where it was: leaving {:?} was cancelled", current);
            return;
        }
        switch_to(target);
        return;
    }

    // ⚠️ **Read before the window is on screen**: showing it takes the
    // focus, and the same call made afterwards answers "this window". See
    // `roles_ui::handback_to`.
    let had = unsafe { GetFocus() };
    ST.with(|c| c.borrow_mut().prev_focus = had);
    // The plugins are listed in the sidebar whatever section opens.
    crate::plugins_ui::opened();
    crate::general_ui::opened();
    let (r, maximized, why) = opening_state(origin);
    // **One call that says both facts** -- the normal rectangle and whether
    // it is maximized over it (#896 D1). `SetWindowPos` on a window that was
    // hidden while maximized kept the maximized flag and put a normal-sized
    // rectangle under it; a placement replaces both.
    let (mon, work) = primary_monitor();
    let wp = WINDOWPLACEMENT {
        length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
        showCmd: if maximized { SW_SHOWMAXIMIZED.0 as u32 } else { SW_SHOWNORMAL.0 as u32 },
        rcNormalPosition: from_rect(shell::to_workspace(r, mon, work)),
        ..Default::default()
    };
    POSITIONING.store(true, Ordering::Release);
    let placed = unsafe { SetWindowPlacement(h, &wp) }.is_ok();
    unsafe {
        let _ = SetWindowPos(h, Some(HWND_TOP), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    }
    POSITIONING.store(false, Ordering::Release);
    // **Laid out now, not on the next `WM_SIZE`** (#896 E1): a placement that
    // leaves the size what it already was sends none, and the search field
    // stayed where it was created -- 0,0, 10×10 -- on the first opening at
    // 96 DPI, where the first-opening size is the creation size.
    relayout();
    let zoomed = unsafe { IsZoomed(h) }.as_bool();
    let _ = unsafe { SetForegroundWindow(h) };
    // process-wide: as above
    crate::plogf!(
        "[settings] shown for route {:?} at {},{} {}x{} maximized={} ({}) dpi={} placed={} zoomed_now={}",
        route.to_string(),
        r.left,
        r.top,
        r.width(),
        r.height(),
        maximized,
        why,
        dpi_of(h),
        placed,
        zoomed
    );
    switch_to(target);
    log_grid();
}

/// §2.3a's criterion, as far as this process can read it on the machine:
/// the rules' rows, the dividers' columns, and the two baselines -- the
/// search edit's from its own window rectangle read back from Windows plus
/// its font's ascent, the breadcrumb's from where it is drawn plus its
/// font's. The screenshot is still the judge; this is the same numbers
/// said by the program.
fn log_grid() {
    let h = win();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let dpi = dpi_of(h);
    let l = shell::layout(rc.right, rc.bottom, dpi);
    let edit = HWND(SEARCH.load(Ordering::Acquire));
    let mut er = RECT::default();
    let _ = unsafe { GetWindowRect(edit, &mut er) };
    let mut pts = [POINT { x: er.left, y: er.top }, POINT { x: er.right, y: er.bottom }];
    unsafe {
        let _ = MapWindowPoints(None, Some(h), &mut pts);
    }
    let (_, asc) = metrics(FONT.load(Ordering::Acquire));
    let (crumb_top, crumb_asc) = crumb_top(&l);
    // process-wide: the one settings window
    crate::plogf!(
        "[settings] grid at dpi={} client={}x{}: top rule row {} (x {}..{}), bottom rule row {} (x {}..{}), \
         sidebar divider col {} (rows {}..{}), search baseline row {} (edit rows {}..{}), breadcrumb baseline row {}",
        dpi,
        rc.right,
        rc.bottom,
        l.top_rule.top,
        l.top_rule.left,
        l.top_rule.right - 1,
        l.bottom_rule.top,
        l.bottom_rule.left,
        l.bottom_rule.right - 1,
        l.divider.left,
        l.divider.top,
        l.divider.bottom - 1,
        pts[0].y + asc,
        pts[0].y,
        pts[1].y - 1,
        crumb_top + crumb_asc
    );
    crate::roles_ui::log_grid();
    crate::projects_ui::log_grid();
}

/// A font's line height and ascent, in pixels.
fn metrics(font: *mut c_void) -> (i32, i32) {
    let h = win();
    let mut tm = TEXTMETRICW::default();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, HGDIOBJ(font));
        let _ = GetTextMetricsW(dc, &mut tm);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    (tm.tmHeight, tm.tmAscent)
}

/// Where the search edit goes inside its frame: its text starts at the
/// sidebar's text edge (`Layout::sidebar_text_left`, where the row labels
/// start too) and it ends `PAD_SIDEBAR` inside the frame's right edge;
/// exactly one line of its font tall, centred on the frame. **Its text starts at its top** (a single-line edit has no
/// vertical centring of its own), which is what lets the breadcrumb be put
/// on the same baseline by arithmetic rather than by eye.
fn search_edit_rect(l: &shell::Layout, dpi: i32) -> Rect {
    let frame = l.search;
    let (line, _) = metrics(FONT.load(Ordering::Acquire));
    let line = line.min(frame.height() - 2).max(1);
    let top = frame.top + (frame.height() - line) / 2;
    Rect::new(l.sidebar_text_left, top, frame.right - shell::scale(grid::PAD_SIDEBAR, dpi), top + line)
}

/// The breadcrumb's top, chosen so its baseline is the search edit's
/// (§2.3a ③), and the breadcrumb font's ascent.
fn crumb_top(l: &shell::Layout) -> (i32, i32) {
    let dpi = dpi_of(win());
    let e = search_edit_rect(l, dpi);
    let (_, asc) = metrics(FONT.load(Ordering::Acquire));
    let (_, bold_asc) = metrics(FONT_BOLD.load(Ordering::Acquire));
    (e.top + asc - bold_asc, bold_asc)
}

/// Show `target`'s section and hide the others. Leaving was agreed to.
fn switch_to(target: Place) {
    let h = win();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let l = shell::layout(rc.right, rc.bottom, dpi_of(h));
    let origin = ST.with(|c| c.borrow().origin);
    for s in Section::ALL {
        if s != target.section {
            hide_section(s);
        }
    }
    ST.with(|c| c.borrow_mut().section = Some(target.section));
    match target.section {
        Section::Roles => crate::roles_ui::show(h, from_rect(l.content), origin, target.item.as_deref()),
        Section::Plugins => crate::plugins_ui::show(h, from_rect(l.content), target.item.as_deref()),
        Section::Projects => crate::projects_ui::show(h, from_rect(l.content), origin, target.item.as_deref()),
        Section::General => crate::general_ui::show(h, from_rect(l.content), target.item.as_deref()),
    }
    reveal_selection();
    let _ = unsafe { InvalidateRect(Some(h), None, false) };
    // process-wide: as above
    crate::plogf!("[settings] section {} item={:?}", target.section.key(), target.item);
}

fn hide_section(s: Section) {
    match s {
        Section::Roles => crate::roles_ui::hide(),
        Section::Plugins => crate::plugins_ui::hide(),
        Section::Projects => crate::projects_ui::hide(),
        Section::General => crate::general_ui::hide(),
    }
}

/// The role on screen changed (selected, renamed, saved): the breadcrumb
/// names it, so it is redrawn.
pub fn crumb_changed() {
    let h = win();
    if h.0.is_null() {
        return;
    }
    let _ = unsafe { InvalidateRect(Some(h), None, false) };
}

/// Close: ask about anything unsaved, remember where it was, hide, and give
/// the keyboard back.
fn close() {
    if !leave_current() {
        return;
    }
    let h = win();
    save_state();
    let last = current_place();
    LAST_FOCUS.store(std::ptr::null_mut(), Ordering::Release);
    crate::roles_ui::hide();
    crate::roles_ui::forget_draft();
    crate::plugins_ui::hide();
    crate::plugins_ui::closed();
    crate::projects_ui::hide();
    // Undo for a deleted project ends with the window (§6.2).
    crate::projects_ui::closed();
    let (prev, origin) = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.last = last.clone();
        s.section = None;
        let p = s.prev_focus;
        s.prev_focus = HWND(std::ptr::null_mut());
        (p, s.origin)
    });
    unsafe {
        let _ = ShowWindow(h, SW_HIDE);
    }
    // Focus and the foreground are two different pieces of state and both
    // are handed back (`overlay.rs` has the story). Not to this window, and
    // never to nothing: `roles_ui::handback_to`.
    let frame = crate::winid::frame_of_window(origin).unwrap_or_else(crate::tabs::overlay_frame);
    let target = HWND(crate::roles_ui::handback_to(prev.0 as isize, usable_handback(prev), frame.0 as isize) as *mut c_void);
    crate::overlay::foreground_back(h, target, "settings");
    crate::overlay::focus_back(target, "settings");
    // process-wide: as above
    crate::plogf!("[settings] hidden; last={:?}", last);
    // It may have been the last window (#896 D3).
    crate::winid::settings_closed();
}

/// **Ctrl+W wherever the keyboard is in this window** (task 1005): asked by
/// the message loop before a key is dispatched. A key aimed at this window
/// or any control in it that is one of the window's own
/// (`shell::window_key`) is answered here and not dispatched -- a check box,
/// a button or a section's window used to receive Ctrl+W and do nothing
/// with it. True when the key was taken.
pub fn pre_translate(msg: &MSG) -> bool {
    if msg.message != WM_KEYDOWN {
        return false;
    }
    let h = win();
    if h.0.is_null() || !(msg.hwnd == h || unsafe { IsChild(h, msg.hwnd) }.as_bool()) {
        return false;
    }
    let vk = (msg.wParam.0 & 0xFFFF) as u32;
    match shell::window_key(vk, held(VK_CONTROL), held(VK_SHIFT), held(VK_MENU)) {
        Some(shell::WindowKey::Close) => {
            // process-wide: the one settings window
            crate::plogf!("[settings] Ctrl+W (keyboard on {:?}): closing", msg.hwnd);
            let _ = unsafe { PostMessageW(Some(h), WM_CLOSE, WPARAM(0), LPARAM(0)) };
            true
        }
        None => false,
    }
}

/// Whether `f` is a live, visible, enabled control inside this window --
/// somewhere the keyboard can be given back to.
fn focus_is_ours(f: HWND) -> bool {
    let h = win();
    !f.0.is_null()
        && f != h
        && unsafe { IsWindow(Some(f)) }.as_bool()
        && unsafe { IsWindowVisible(f) }.as_bool()
        && unsafe { IsWindowEnabled(f) }.as_bool()
        && unsafe { IsChild(h, f) }.as_bool()
}

/// Whether a remembered focus is still somewhere to hand the keyboard: a
/// window that exists and is not in this one.
fn usable_handback(prev: HWND) -> bool {
    if prev.0.is_null() || !unsafe { IsWindow(Some(prev)) }.as_bool() {
        return false;
    }
    (unsafe { GetAncestor(prev, GA_ROOT) }) != win()
}

// ============================================================== geometry

/// `%LOCALAPPDATA%\polter\settings-window-rect`, beside the role library's
/// `role-library-instructions-height` (§2.2). The whole rectangle in
/// physical pixels, not only a height.
fn rect_path() -> Option<PathBuf> {
    Some(crate::plugins::user_dir()?.parent()?.join("settings-window-rect"))
}

fn load_saved() -> Option<shell::Saved> {
    shell::parse_saved(&std::fs::read_to_string(rect_path()?).ok()?)
}

/// Whether the settings window is open -- the one fact the process's "is
/// that the last window?" needs from here (#896 D3).
pub fn is_open() -> bool {
    let h = win();
    !h.0.is_null() && unsafe { IsWindowVisible(h) }.as_bool()
}

/// The primary monitor's rectangle and work area, which is what workspace
/// coordinates are relative to.
fn primary_monitor() -> (Rect, Rect) {
    let mon = unsafe { MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY) };
    let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    if unsafe { GetMonitorInfoW(mon, &mut mi) }.as_bool() {
        (to_rect(mi.rcMonitor), to_rect(mi.rcWork))
    } else {
        (Rect::default(), Rect::default())
    }
}

/// Remember the window (§2.2, #896 D1): its **normal** rectangle, from the
/// placement -- which Windows keeps while the window is maximized or
/// minimised -- and whether it is maximized. Minimised counts as whatever it
/// will be restored to.
fn save_state() {
    let h = win();
    let mut wp = WINDOWPLACEMENT { length: std::mem::size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
    if unsafe { GetWindowPlacement(h, &mut wp) }.is_err() {
        return;
    }
    let maximized = if unsafe { IsIconic(h) }.as_bool() {
        wp.flags.0 & WPF_RESTORETOMAXIMIZED.0 != 0
    } else {
        unsafe { IsZoomed(h) }.as_bool()
    };
    let (mon, work) = primary_monitor();
    // Remembered inside the work area it is on, so a rectangle that ran
    // past the edge is not written down as the one to come back to.
    let normal = shell::from_workspace(to_rect(wp.rcNormalPosition), mon, work);
    let saved = shell::Saved { rect: shell::clamp_onto_screen(normal, &work_areas()), maximized };
    let Some(path) = rect_path() else {
        // process-wide: the one settings window
        crate::plogf!("[settings] no LOCALAPPDATA; the window's rectangle is not remembered");
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Temporary file and rename, like `roles_ui::save_height`: a
    // half-written file reads back as no memory, which is the first-opening
    // rule.
    let tmp = path.with_extension("tmp");
    let ok = std::fs::write(&tmp, shell::format_saved(saved)).is_ok() && std::fs::rename(&tmp, &path).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        // process-wide: as above
        crate::plogf!("[settings] could not write {}", path.display());
    }
}

/// Every monitor's work area.
fn work_areas() -> Vec<Rect> {
    unsafe extern "system" fn each(mon: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        unsafe {
            let out = &mut *(data.0 as *mut Vec<Rect>);
            let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            if GetMonitorInfoW(mon, &mut mi).as_bool() {
                out.push(to_rect(mi.rcWork));
            }
        }
        BOOL(1)
    }
    let mut out: Vec<Rect> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut out as *mut Vec<Rect> as isize));
    }
    out
}

fn monitor_work_and_dpi(mon: HMONITOR) -> (Rect, i32) {
    let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    let work = if unsafe { GetMonitorInfoW(mon, &mut mi) }.as_bool() {
        to_rect(mi.rcWork)
    } else {
        Rect::new(0, 0, 1280, 720)
    };
    let (mut x, mut y) = (96u32, 96u32);
    let dpi = if unsafe { GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &mut x, &mut y) }.is_ok() { x as i32 } else { 96 };
    (work, dpi)
}

/// Where the window opens (§2.2), and which rule said so, for the log.
///
/// The first-opening rule is applied on the monitor of the terminal the
/// route came from, at that monitor's DPI. A remembered rectangle is grown
/// to the minimum at the DPI of the monitor it is on.
fn opening_state(origin: HWND) -> (Rect, bool, &'static str) {
    let works = work_areas();
    let saved_state = load_saved();
    let saved = saved_state.map(|s| s.rect);
    let near = if origin.0.is_null() { unsafe { GetForegroundWindow() } } else { origin };
    let (work, dpi) = monitor_work_and_dpi(unsafe { MonitorFromWindow(near, MONITOR_DEFAULTTOPRIMARY) });
    let dpi_there = match saved {
        Some(r) if shell::on_some_screen(r, &works) => {
            monitor_work_and_dpi(unsafe { MonitorFromRect(&from_rect(r), MONITOR_DEFAULTTONEAREST) }).1
        }
        _ => dpi,
    };
    let (r, maximized) = shell::opening(saved_state, &works, work, dpi_there);
    let why = match saved {
        None => "first opening",
        Some(s) if !shell::on_some_screen(s, &works) => "remembered rect is off every screen; first-opening rule",
        Some(_) => "remembered",
    };
    (r, maximized, why)
}

// ================================================================ window

fn make_font(dpi: i32, px: i32, weight: i32) -> HFONT {
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
            w!("Segoe UI"),
        )
    }
}

fn make_fonts(dpi: i32) {
    for (slot, f) in [(&FONT, make_font(dpi, 14, FW_NORMAL.0 as i32)), (&FONT_BOLD, make_font(dpi, 15, FW_SEMIBOLD.0 as i32))] {
        let old = slot.swap(f.0, Ordering::AcqRel);
        if !old.is_null() {
            let _ = unsafe { DeleteObject(HGDIOBJ(old)) };
        }
    }
    let f = FONT.load(Ordering::Acquire);
    for c in [&SEARCH] {
        let h = HWND(c.load(Ordering::Acquire));
        if !h.0.is_null() {
            unsafe {
                SendMessageW(h, WM_SETFONT, Some(WPARAM(f as usize)), Some(LPARAM(1)));
            }
        }
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Make the window, hidden, once, at startup. See the header for why it is
/// made here rather than at the first opening.
pub fn init(hi: HINSTANCE) {
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            // Repaint the whole client area on a resize, for the reason
            // `roles_ui::create` gives.
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(proc_),
            hInstance: hi,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            // Not `PolterSettings`: that class is `settings_ui.rs`'s plugin
            // page, which phase 2 folds in here.
            lpszClassName: w!("PolterSettingsWindow"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            // process-wide: registering the window class, once per process
            // absence: means it was not reached -- the failure arm of a call
            // made once at startup; a log with neither this line nor
            // `[settings] ready` means `init` was never called
            crate::plogf!("[settings] RegisterClassExW failed");
            return;
        }
        let title = wide(&tr("Polter Settings"));
        // A real top-level window with a title bar and a close button
        // (§2.1), **with no owner** -- see the header.
        let h = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterSettingsWindow"),
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            shell::FIRST_W,
            shell::FIRST_H,
            None,
            None,
            Some(hi),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the one settings window
                crate::plogf!("[settings] CreateWindowExW failed: {e:?}");
                return;
            }
        };
        WIN.store(h.0, Ordering::Release);
        if theme::custom_drawing() {
            // The dark title bar, as `shell.rs` asks for the frame's.
            let on: BOOL = true.into();
            let _ = DwmSetWindowAttribute(
                h,
                DWMWINDOWATTRIBUTE(20),
                &on as *const BOOL as *const c_void,
                std::mem::size_of::<BOOL>() as u32,
            );
        }
        let search = CreateWindowExW(
            // No border of its own: the frame around it is painted with the
            // breadcrumb bar's, from the same rectangle (§2.3).
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(ES_AUTOHSCROLL as u32),
            0,
            0,
            10,
            10,
            Some(h),
            Some(HMENU(ID_SEARCH as usize as *mut c_void)),
            Some(hi),
            None,
        )
        .unwrap_or_default();
        if !search.0.is_null() {
            SEARCH.store(search.0, Ordering::Release);
            // The placeholder is painted by `child_proc`, not set with
            // `EM_SETCUEBANNER`: on the test machine's English session the
            // cue did not show (#896), and a word this window draws itself
            // is one it can see and put in the theme's dim colour.
            subclass(search);
        }
        make_fonts(dpi_of(h));
        // The `WM_SIZE` from creation arrived before these controls existed.
        relayout();
        // Projects an earlier process deleted and could no longer undo go
        // on to the Recycle Bin (settings.md §6.2).
        crate::projects_ui::sweep_leftovers();
        // process-wide: as above
        crate::plogf!("[settings] ready (hidden until a route opens it)");
    }
}

/// Ctrl+W has to close the window wherever the keyboard is, and a control
/// swallows keys its parent never sees. **Escape closes nothing** (§2.3):
/// long text and an input method both use it.
pub fn subclass_child(h: HWND) {
    subclass(h);
}

fn subclass(h: HWND) {
    unsafe {
        let prev = SetWindowLongPtrW(h, GWLP_WNDPROC, child_proc as *const () as isize);
        let _ = SetPropW(h, PROP_PREV, Some(HANDLE(prev as *mut c_void)));
    }
}

fn held(vk: VIRTUAL_KEY) -> bool {
    (unsafe { GetKeyState(vk.0 as i32) } as u16 & 0x8000) != 0
}

unsafe extern "system" fn child_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetPropW(h, PROP_PREV).0 as isize;
        match msg {
            WM_KEYDOWN if wp.0 as u16 == u16::from(b'W') && held(VK_CONTROL) => {
                let _ = PostMessageW(Some(win()), WM_CLOSE, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            // The characters Ctrl+W and Escape also produce, which an `EDIT`
            // would answer with a beep.
            WM_CHAR if wp.0 == 0x17 || wp.0 == 0x1B => return LRESULT(0),
            WM_NCDESTROY => {
                let _ = RemovePropW(h, PROP_PREV);
            }
            _ => {}
        }
        if prev == 0 {
            return DefWindowProcW(h, msg, wp, lp);
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = std::mem::transmute(prev);
        let r = CallWindowProcW(Some(f), h, msg, wp, lp);
        // The search field's placeholder, over the empty edit once it has
        // painted itself.
        if msg == WM_PAINT && h.0 == SEARCH.load(Ordering::Acquire) && GetWindowTextLengthW(h) == 0 {
            paint_placeholder(h);
        }
        r
    }
}

/// "Search" in the empty search field, where its text would start, in the
/// theme's dim colour and the field's font.
fn paint_placeholder(edit: HWND) {
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(edit, &mut rc);
        let dc = GetDC(Some(edit));
        draw_text(dc, &tr("Search"), &rc, FONT.load(Ordering::Acquire), theme::dim(), DT_LEFT | DT_SINGLELINE | DT_TOP);
        ReleaseDC(Some(edit), dc);
    }
}

/// Everything moves with the size: the search box, the section's content.
fn relayout() {
    let h = win();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let l = shell::layout(rc.right, rc.bottom, dpi_of(h));
    let search = HWND(SEARCH.load(Ordering::Acquire));
    if !search.0.is_null() {
        let e = search_edit_rect(&l, dpi_of(h));
        unsafe {
            let _ = SetWindowPos(search, None, e.left, e.top, e.width(), e.height(), SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }
    match ST.with(|c| c.borrow().section) {
        Some(Section::Roles) => crate::roles_ui::move_to(from_rect(l.content)),
        Some(Section::Plugins) => crate::plugins_ui::move_to(from_rect(l.content)),
        Some(Section::Projects) => crate::projects_ui::move_to(from_rect(l.content)),
        Some(Section::General) => crate::general_ui::move_to(from_rect(l.content)),
        _ => {}
    }
    let _ = unsafe { InvalidateRect(Some(h), None, false) };
}

fn search_text() -> String {
    let h = HWND(SEARCH.load(Ordering::Acquire));
    let n = unsafe { GetWindowTextLengthW(h) }.max(0) as usize;
    let mut buf = vec![0u16; n + 1];
    let got = unsafe { GetWindowTextW(h, &mut buf) }.max(0) as usize;
    String::from_utf16_lossy(&buf[..got])
}

/// The search box changed (§2.3): narrow the lists and jump to the first
/// section with a match: the roles and the projects (plugins join in phase 2).
fn on_search() {
    // The whole field repaints, so no piece of the placeholder is left
    // beside the first letter typed.
    let edit = HWND(SEARCH.load(Ordering::Acquire));
    let _ = unsafe { InvalidateRect(Some(edit), None, true) };
    let q = search_text();
    crate::roles_ui::set_filter(&q);
    crate::plugins_ui::set_filter(&q);
    crate::projects_ui::set_filter(&q);
    // The sidebar's plugin rows are narrowed too, so it repaints.
    let _ = unsafe { InvalidateRect(Some(win()), None, false) };
    let items = vec![
        (Section::Roles, crate::roles_ui::names()),
        (Section::Projects, crate::projects_ui::names()),
        (Section::Plugins, crate::plugins_ui::names()),
    ];
    // §2.3 (narrowed 2026-10-01): the section on screen keeps a search it
    // can answer.
    let here = section_now().unwrap_or(Section::ALL[0]);
    let Some(target) = shell::search_section(here, &q, &items) else { return };
    if ST.with(|c| c.borrow().section) == Some(target) {
        return;
    }
    let place = Place { section: target, item: None };
    let current = current_place();
    let dirty = current.as_ref().is_some_and(|c| section_dirty(c.section));
    if shell::must_ask(current.as_ref(), dirty, &place) && !leave_current() {
        return;
    }
    switch_to(place);
    // The jump must not take the keyboard out of the box being typed in.
    let s = HWND(SEARCH.load(Ordering::Acquire));
    let _ = unsafe { SetFocus(Some(s)) };
}

fn on_click(x: i32, y: i32) {
    let h = win();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let dpi = dpi_of(h);
    let l = shell::layout(rc.right, rc.bottom, dpi);
    let rows = crate::plugins_ui::sidebar_rows();
    let sb = plugin_rules::sidebar_at(&l, dpi, rows.len(), side_scroll(&l, dpi, rows.len()));
    let Some(hit) = plugin_rules::hit(&l, &sb, x, y) else { return };
    // **The keyboard comes to the sidebar before anything is asked** (#896
    // W35): the question gives it back to whoever had it when it opened, and
    // on a click that must be the sidebar that was clicked, not the field the
    // keyboard was in before.
    let _ = unsafe { SetFocus(Some(h)) };
    go_hit(hit, &rows);
}

/// The sidebar's scroll, held inside what the rows can scroll now -- the
/// number of plugin rows changes with the search box.
fn side_scroll(l: &shell::Layout, dpi: i32, plugins: usize) -> i32 {
    let max = plugin_rules::sidebar_max_scroll(l, dpi, plugins);
    SIDE_SCROLL.load(Ordering::Acquire).clamp(0, max)
}

/// Scroll the sidebar by `by` pixels (the wheel over it).
fn scroll_sidebar(by: i32) {
    let h = win();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let dpi = dpi_of(h);
    let l = shell::layout(rc.right, rc.bottom, dpi);
    let n = crate::plugins_ui::sidebar_rows().len();
    let max = plugin_rules::sidebar_max_scroll(&l, dpi, n);
    let next = (side_scroll(&l, dpi, n) + by).clamp(0, max);
    SIDE_SCROLL.store(next, Ordering::Release);
    let _ = unsafe { InvalidateRect(Some(h), Some(&from_rect(l.sidebar)), false) };
}

/// Bring the selected row -- a section, or the plugin on screen -- into the
/// sidebar's window, moving it as little as possible.
fn reveal_selection() {
    let h = win();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let dpi = dpi_of(h);
    let l = shell::layout(rc.right, rc.bottom, dpi);
    let rows = crate::plugins_ui::sidebar_rows();
    let sb = plugin_rules::sidebar(&l, dpi, rows.len());
    let row = match current_hit(&rows) {
        Some(Hit::Plugin(i)) => sb.plugins.get(i).copied(),
        Some(Hit::Section(sec)) => Section::ALL.iter().position(|x| *x == sec).map(|i| sb.sections[i]),
        None => None,
    };
    let Some(row) = row else { return };
    let max = plugin_rules::sidebar_max_scroll(&l, dpi, rows.len());
    let next = plugin_rules::sidebar_scroll_to(&l, row, side_scroll(&l, dpi, rows.len()), max);
    SIDE_SCROLL.store(next, Ordering::Release);
}

/// Where the sidebar's selection is, as a row of it.
fn current_hit(rows: &[crate::plugins_ui::SidebarRow]) -> Option<Hit> {
    let section = section_now()?;
    if section == Section::Plugins {
        if let Some(i) = rows.iter().position(|r| r.selected) {
            return Some(Hit::Plugin(i));
        }
    }
    Some(Hit::Section(section))
}

/// Go to a sidebar row: a section, or one plugin under Plugins.
fn go_hit(hit: Hit, rows: &[crate::plugins_ui::SidebarRow]) {
    match hit {
        Hit::Section(s) => go_section(s),
        Hit::Plugin(i) => {
            let key = rows.get(i).and_then(|r| crate::plugins_ui::key_at(r.index));
            go_place(Place { section: Section::Plugins, item: key });
        }
    }
}

/// The section on screen. A function of its own so the borrow ends before
/// its caller dispatches anything.
fn section_now() -> Option<Section> {
    ST.with(|c| c.borrow().section)
}

/// Go to a section from the sidebar -- a click or ↑ / ↓ -- asking first
/// about anything unsaved. **The keyboard stays on the sidebar**, so the
/// next ↓ goes on down it: showing the roles section would otherwise put
/// it in the role's name field.
fn go_section(section: Section) {
    if section_now() != Some(section) {
        go_place(Place { section, item: None });
    } else {
        let _ = unsafe { SetFocus(Some(win())) };
    }
}

/// Go to a place from the sidebar, asking first about anything unsaved --
/// a plugin with changes asks before another plugin is shown (§2.4).
fn go_place(place: Place) {
    let h = win();
    let current = current_place();
    if current.as_ref() != Some(&place) {
        let dirty = current.as_ref().is_some_and(|c| section_dirty(c.section));
        if shell::must_ask(current.as_ref(), dirty, &place) && !leave_current() {
            return;
        }
        switch_to(place);
    }
    let _ = unsafe { SetFocus(Some(h)) };
}

fn fill(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

/// The search field's frame: filled, with a one-pixel border in the
/// theme's border colour.
fn bar_frame(hdc: HDC, r: &RECT, inside: u32) {
    fill(hdc, r, inside);
    unsafe {
        let b = CreateSolidBrush(COLORREF(theme::border()));
        FrameRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

/// How wide `s` is in `font`, in pixels.
fn text_width(hdc: HDC, s: &str, font: *mut c_void) -> i32 {
    let mut w: Vec<u16> = s.encode_utf16().collect();
    let mut r = RECT::default();
    unsafe {
        let old = SelectObject(hdc, HGDIOBJ(font));
        DrawTextW(hdc, &mut w, &mut r, DT_SINGLELINE | DT_CALCRECT | DT_NOPREFIX);
        SelectObject(hdc, old);
    }
    r.right - r.left
}

fn draw_text(hdc: HDC, s: &str, r: &RECT, font: *mut c_void, colour: u32, flags: DRAW_TEXT_FORMAT) {
    let mut w: Vec<u16> = s.encode_utf16().collect();
    let mut r = *r;
    unsafe {
        let old = SelectObject(hdc, HGDIOBJ(font));
        SetTextColor(hdc, COLORREF(colour));
        SetBkMode(hdc, TRANSPARENT);
        DrawTextW(hdc, &mut w, &mut r, flags | DT_NOPREFIX);
        SelectObject(hdc, old);
    }
}


fn paint(h: HWND) {
    let section = ST.with(|c| c.borrow().section);
    let crumb_item = match section {
        Some(Section::Roles) => crate::roles_ui::current().map(|(_, name)| name),
        Some(Section::Plugins) => crate::plugins_ui::current().map(|(_, name)| name),
        Some(Section::Projects) => crate::projects_ui::current(),
        Some(Section::General) => Some(crate::general_ui::label(crate::general_ui::current())),
        None => None,
    };
    let plugin_rows = crate::plugins_ui::sidebar_rows();
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(h, &mut ps) };
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let dpi = dpi_of(h);
    let l = shell::layout(rc.right, rc.bottom, dpi);
    let font = FONT.load(Ordering::Acquire);
    let bold = FONT_BOLD.load(Ordering::Acquire);

    fill(hdc, &from_rect(l.sidebar), theme::panel());
    let right = RECT { left: l.content.left, top: 0, right: rc.right, bottom: rc.bottom };
    fill(hdc, &right, theme::bg());
    let sb = plugin_rules::sidebar_at(&l, dpi, plugin_rows.len(), side_scroll(&l, dpi, plugin_rows.len()));
    // The words' column is as wide as the widest of the five words in this
    // font, so none of them is cut ("改了未重启" was, at 144 DPI); the name
    // gives way instead (task 990).
    let word_w = plugin_rules::Dot::ALL
        .iter()
        .map(|d| text_width(hdc, &crate::plugins_ui::dot_word(*d), font))
        .max()
        .unwrap_or(0);
    // The plugins, under their section (§2.3): dot, name, and the dot's word
    // on the right. Only rows above the bottom rule are drawn; a list that
    // runs past it is cut there rather than into the band.
    let clip = unsafe { SaveDC(hdc) };
    unsafe {
        let _ = IntersectClipRect(hdc, 0, l.top_rule.bottom, l.sidebar.right, l.bottom_rule.top);
    }
    for (row, r) in plugin_rows.iter().zip(sb.plugins.iter()) {
        let r = from_rect(*r);
        let on = section == Some(Section::Plugins) && row.selected;
        if on {
            fill(hdc, &r, theme::sel());
        }
        let colour = if on { theme::sel_text() } else { theme::text() };
        let dim = if on { theme::sel_text() } else { theme::dim() };
        let word = crate::plugins_ui::dot_word(row.dot);
        let (name_r, word_r) = plugin_rules::plugin_columns(to_rect(r), sb.plugin_text_left, word_w, dpi);
        draw_text(hdc, &format!("{} {}", row.dot.glyph(), row.name), &from_rect(name_r), font, colour, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        draw_text(hdc, &word, &from_rect(word_r), font, dim, DT_SINGLELINE | DT_VCENTER | DT_RIGHT);
    }
    for (i, sec) in Section::ALL.iter().enumerate() {
        let r = from_rect(sb.sections[i]);
        // A section's row is highlighted when it is the place -- Plugins
        // only while no plugin under it is.
        let on = section == Some(*sec) && !(*sec == Section::Plugins && plugin_rows.iter().any(|p| p.selected));
        if on {
            // The highlight is the row's box: the search field's left and
            // right edges (§2.3a, `PAD_SIDEBAR`).
            fill(hdc, &r, theme::sel());
        }
        // The labels start where the search field's text does.
        let t = RECT { left: l.sidebar_text_left, ..r };
        draw_text(
            hdc,
            &label(*sec),
            &t,
            if on || section == Some(*sec) { bold } else { font },
            if on { theme::sel_text() } else { theme::text() },
            DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS,
        );
    }
    unsafe {
        let _ = RestoreDC(hdc, clip);
    }

    // §2.3a. The search field's frame; the breadcrumb on the search text's
    // baseline; one rule under the top band and one over the bottom band,
    // each the whole width; the sidebar divider through both bands. The
    // lines go last so nothing paints over a crossing. A section that owns
    // the content column (the roles) draws its own part of the bottom band
    // and rule, from the same grid.
    bar_frame(hdc, &from_rect(l.search), theme::field_bg());
    fill(hdc, &from_rect(l.top_rule), theme::border());
    fill(hdc, &from_rect(l.bottom_rule), theme::border());
    fill(hdc, &from_rect(l.divider), theme::border());

    if let Some(sec) = section {
        // §2.3a: an item the search has hidden from its list says so here.
        let item = match crumb_item {
            Some(name)
                if (sec == Section::Roles && crate::roles_ui::selection_hidden())
                    || (sec == Section::Plugins && crate::plugins_ui::selection_hidden()) =>
            {
                Some(shell::hidden_item(&tr("{} (not in the search results)"), &name))
            }
            Some(name) if sec == Section::Projects && crate::projects_ui::selection_hidden() => {
                Some(shell::hidden_item(&tr("{} (not in the search results)"), &name))
            }
            other => other,
        };
        let crumb = shell::breadcrumb(&label(sec), item.as_deref());
        let (top, _) = crumb_top(&l);
        let t = RECT { left: l.breadcrumb.left, top, right: l.breadcrumb.right, bottom: l.top_rule.top };
        draw_text(hdc, &crumb, &t, bold, theme::text(), DT_SINGLELINE | DT_TOP | DT_END_ELLIPSIS);
    }
    let _ = unsafe { EndPaint(h, &ps) };
}

fn drain_pending() {
    let q = PENDING.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default();
    for (route, origin) in q {
        open(route, HWND(origin as *mut c_void));
    }
}

unsafe extern "system" fn proc_(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        // The button's custom drawing and the edit's colours, as the role
        // library's own controls get them.
        if let Some(r) = crate::roles_ui::common(h, msg, wp, lp) {
            return r;
        }
        match msg {
            WM_SETTINGS_OPEN => {
                drain_pending();
                LRESULT(0)
            }
            WM_CLOSE => {
                close();
                LRESULT(0)
            }
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if vk.0 == u16::from(b'W') && held(VK_CONTROL) {
                    close();
                } else if vk == VK_UP || vk == VK_DOWN {
                    // The window itself has the keyboard only after a click
                    // on the sidebar (`go_section`), so these are the
                    // sidebar's (§2.3a: the arrow keys are not lost).
                    let rows = crate::plugins_ui::sidebar_rows();
                    go_hit(plugin_rules::step_sidebar(current_hit(&rows), rows.len(), vk == VK_DOWN), &rows);
                }
                LRESULT(0)
            }
            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as u16;
                let code = ((wp.0 >> 16) & 0xFFFF) as u32;
                if id == ID_SEARCH && code == EN_CHANGE {
                    on_search();
                }
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let x = (lp.0 & 0xFFFF) as i16 as i32;
                let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
                on_click(x, y);
                LRESULT(0)
            }
            // The wheel over the sidebar scrolls its rows (task 990). Over a
            // section the section's own window had it first.
            WM_MOUSEWHEEL => {
                let mut pt = POINT { x: (lp.0 & 0xFFFF) as i16 as i32, y: ((lp.0 >> 16) & 0xFFFF) as i16 as i32 };
                let _ = ScreenToClient(h, &mut pt);
                let dpi = dpi_of(h);
                if pt.x < shell::scale(grid::SIDEBAR, dpi) {
                    let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
                    scroll_sidebar(-delta * shell::scale(grid::SECTION_ROW_H, dpi) * 3 / 120);
                }
                LRESULT(0)
            }
            WM_ACTIVATE => {
                if (wp.0 & 0xFFFF) as u32 == WA_INACTIVE {
                    // Remember who had the keyboard, if it was one of ours.
                    let f = GetFocus();
                    let ours = focus_is_ours(f);
                    LAST_FOCUS.store(if ours { f.0 } else { std::ptr::null_mut() }, Ordering::Release);
                    return DefWindowProcW(h, msg, wp, lp);
                }
                crate::roles_ui::activated();
                crate::projects_ui::activated();
                crate::general_ui::activated();
                // A plugin installed or configured meanwhile -- by an
                // agent's `plugin_configure`, or by hand.
                if is_open() {
                    crate::plugins_ui::refresh_catalog();
                    let _ = InvalidateRect(Some(h), None, false);
                }
                // **Back to the control that had it**, after the sections
                // refreshed (a refresh may have made it again, and then it is
                // gone and the window takes the keyboard, as before). Not
                // `DefWindowProc`, which would put it on the window.
                let saved = HWND(LAST_FOCUS.swap(std::ptr::null_mut(), Ordering::AcqRel));
                let to = HWND(shell::focus_after_question(saved.0 as isize, focus_is_ours(saved), h.0 as isize) as *mut c_void);
                let _ = SetFocus(Some(to));
                // process-wide: the one settings window
                crate::plogf!("[settings] activated; keyboard back to {:?} (saved {:?})", to, saved);
                LRESULT(0)
            }
            WM_GETMINMAXINFO => {
                let mmi = &mut *(lp.0 as *mut MINMAXINFO);
                let (w, hh) = shell::min_size(dpi_of(h));
                mmi.ptMinTrackSize = POINT { x: w, y: hh };
                LRESULT(0)
            }
            WM_SIZE => {
                relayout();
                let _ = RedrawWindow(
                    Some(h),
                    None,
                    None,
                    RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN | RDW_UPDATENOW,
                );
                LRESULT(0)
            }
            WM_EXITSIZEMOVE => {
                save_state();
                LRESULT(0)
            }
            WM_DPICHANGED => {
                make_fonts(dpi_of(h));
                // Our own move already computed the size at the new DPI; see
                // `POSITIONING`.
                if !POSITIONING.load(Ordering::Acquire) {
                    // Windows' suggestion, **inside the work area**: after
                    // 96 → 250 dpi it ran 7 pixels past the corner, and was
                    // then remembered so (#896).
                    let suggested = to_rect(*(lp.0 as *const RECT));
                    let r = shell::clamp_onto_screen(suggested, &work_areas());
                    let _ = SetWindowPos(h, None, r.left, r.top, r.width(), r.height(), SWP_NOZORDER | SWP_NOACTIVATE);
                    // process-wide: the one settings window
                    // absence: depends -- no line for a DPI change this
                    // window made itself while opening (`POSITIONING`)
                    crate::plogf!(
                        "[settings] dpi changed: suggested {},{} {}x{} -> placed {},{} {}x{}",
                        suggested.left,
                        suggested.top,
                        suggested.width(),
                        suggested.height(),
                        r.left,
                        r.top,
                        r.width(),
                        r.height()
                    );
                }
                crate::roles_ui::dpi_changed();
                crate::plugins_ui::dpi_changed();
                crate::projects_ui::dpi_changed();
                crate::general_ui::dpi_changed();
                relayout();
                log_grid();
                LRESULT(0)
            }
            // Sent to top-level windows only, so the role library -- a child
            // now -- hears it from here.
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                crate::roles_ui::theme_changed();
                crate::plugins_ui::theme_changed();
                crate::general_ui::theme_changed();
                theme::repaint_all(h);
                DefWindowProcW(h, msg, wp, lp)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(h);
                LRESULT(0)
            }
            _ => DefWindowProcW(h, msg, wp, lp),
        }
    }
}
