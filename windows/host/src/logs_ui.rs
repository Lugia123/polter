//! Settings › General › Log Management (task 1511): how much each kind of
//! record takes, how long it is kept -- the two retention settings edited in
//! its row -- and "Clear…". Drawn as `log-management-windows-v1` drew it,
//! and as the macOS page (`LogManagement.swift`) is.
//!
//! **The figures and the clearing are the core's** (`ghostty_app_storage_
//! usage`, `ghostty_app_storage_clear`; `src/poltergeist/Storage.zig`); the
//! settings are written through the same call as every other General row
//! (`general_ui::set`). Where each part of a row goes, what a field writes
//! and what a confirmation says are `polter_settings_shell::logs`, tested on
//! the Mac. What is left here is the window.
//!
//! ⚠️ **Nothing here dispatches a message while `ST` is borrowed**
//! (`windows/tools/borrow-across-dispatch.py`): read what is needed, let go,
//! then call.

use std::cell::RefCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

use polter_settings_shell::grid;
use polter_settings_shell::logs::{self as rules, Kind};
use polter_settings_shell::{self as shell, n_, Rect};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::general_ui::{bold, draw_text, fill, font, metrics};
use crate::i18n::tr;
use crate::theme;

const ID_OK: u16 = 3000;
const ID_ROW_BASE: u16 = 3100;
/// A row's three controls: `base + 4 * row + part`.
const PART_DAYS: u16 = 0;
const PART_MB: u16 = 1;
const PART_BUTTON: u16 = 2;
const EN_KILLFOCUS: u32 = 0x0200;
const PROP_PREV: PCWSTR = w!("PolterLogsPrevProc");
/// Read the figures again, posted rather than done: see `reload_later`.
const WM_RELOAD_LATER: u32 = WM_APP + 0x51;
/// While the page is shown it reads the figures again this often: what
/// it shows changes behind it -- the control room's "OK", files written
/// while it is open (the tenth run, D4).
const REFRESH_TIMER: usize = 0x1511;
const REFRESH_MS: u32 = 10_000;

static PAGE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// The page's figures, as the core gave them.
#[derive(Clone, Default)]
struct Usage {
    state_dir: String,
    total_bytes: u64,
    waiting_bytes: Option<u64>,
    /// Kept going round first, then kept for good: the page's order.
    kinds: Vec<Kind>,
}

struct RowCtl {
    days: HWND,
    mb: HWND,
    button: HWND,
}

#[derive(Default)]
struct State {
    usage: Option<Usage>,
    unavailable: bool,
    rows: Vec<RowCtl>,
    ok: HWND,
    scroll: i32,
    filling: bool,
}

thread_local! {
    static ST: RefCell<State> = RefCell::new(State::default());
}

fn page() -> HWND {
    HWND(PAGE.load(Ordering::Acquire))
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn dpi_of(h: HWND) -> i32 {
    let d = unsafe { windows::Win32::UI::HiDpi::GetDpiForWindow(h) } as i32;
    if d > 0 { d } else { 96 }
}

/// Make the page, a child of the General section. Hidden until `place`.
pub fn create(section: HWND) {
    if !page().0.is_null() {
        return;
    }
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(page_proc),
            hInstance: windows::Win32::System::LibraryLoader::GetModuleHandleW(None).unwrap_or_default().into(),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            lpszClassName: w!("PolterGeneralLogs"),
            ..Default::default()
        };
        let _ = RegisterClassExW(&wc);
        let h = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterGeneralLogs"),
            PCWSTR::null(),
            WS_CHILD | WS_CLIPCHILDREN | WS_VSCROLL,
            0,
            0,
            10,
            10,
            Some(section),
            None,
            None,
            None,
        )
        .unwrap_or_default();
        PAGE.store(h.0, Ordering::Release);
    }
}

/// Put the page in `rect` and show it, or hide it. Showing reads the
/// figures again: the page is the place a person looks to see them now.
pub fn place(rect: Rect, show: bool) {
    let h = page();
    if h.0.is_null() {
        return;
    }
    let was = unsafe { IsWindowVisible(h) }.as_bool();
    unsafe {
        let _ = SetWindowPos(
            h,
            None,
            rect.left,
            rect.top,
            rect.width(),
            rect.height(),
            SWP_NOZORDER | SWP_NOACTIVATE | if show { SWP_SHOWWINDOW } else { SWP_HIDEWINDOW },
        );
    }
    if show && !was {
        reload();
        unsafe { SetTimer(Some(h), REFRESH_TIMER, REFRESH_MS, None) };
    } else if show {
        layout();
    } else if was {
        let _ = unsafe { KillTimer(Some(h), REFRESH_TIMER) };
    }
}

/// `reload`, once the message being handled has returned. **What asks for
/// a reload is a control's own notification** -- a field's EN_KILLFOCUS or
/// Return, a button's BN_CLICKED -- and `reload` destroys every row's
/// controls, that one with them, while it is still inside its own message.
fn reload_later() {
    let h = page();
    if !h.0.is_null() {
        let _ = unsafe { PostMessageW(Some(h), WM_RELOAD_LATER, WPARAM(0), LPARAM(0)) };
    }
}

/// Read the figures from the core and make the rows' controls again.
pub fn reload() {
    let h = page();
    if h.0.is_null() {
        return;
    }
    let usage = read_usage();
    let doomed: Vec<HWND> = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.unavailable = usage.is_none();
        s.usage = usage.clone();
        let mut out: Vec<HWND> = s.rows.drain(..).flat_map(|r| [r.days, r.mb, r.button]).collect();
        out.push(std::mem::replace(&mut s.ok, HWND(std::ptr::null_mut())));
        out.into_iter().filter(|h| !h.0.is_null()).collect()
    });
    for d in doomed {
        let _ = unsafe { DestroyWindow(d) };
    }
    let Some(usage) = usage else {
        layout();
        return;
    };
    let mut rows = Vec::new();
    for (i, k) in usage.kinds.iter().enumerate() {
        let base = ID_ROW_BASE + 4 * i as u16;
        let edit = |id: u16, key: &Option<String>| if key.is_some() { make_field(id) } else { HWND(std::ptr::null_mut()) };
        let days = edit(base + PART_DAYS, &k.days_key);
        let mb = edit(base + PART_MB, &k.mb_key);
        let label = if k.action == "compact" { tr("Compact…") } else { tr("Clear…") };
        let button = make_button(base + PART_BUTTON, &label);
        rows.push(RowCtl { days, mb, button });
    }
    let ok = if usage.waiting_bytes.is_some() { make_button(ID_OK, &tr("OK")) } else { HWND(std::ptr::null_mut()) };
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.rows = rows;
        s.ok = ok;
        s.filling = true;
    });
    fill_fields(&usage);
    ST.with(|c| c.borrow_mut().filling = false);
    layout();
}

/// The figures again, from behind the page's back. Where only the figures
/// moved, only they are redrawn: rebuilding the rows would take a field
/// out from under someone typing in it. Where the rows themselves changed
/// -- the notice went, a kind came or went -- the page is made again, but
/// not while one of its fields has the focus; the next tick tries again.
fn refresh() {
    let h = page();
    if h.0.is_null() {
        return;
    }
    let fresh = read_usage();
    let same = ST.with(|c| match (&c.borrow().usage, &fresh) {
        (Some(a), Some(b)) => rules::same_rows(&a.kinds, a.waiting_bytes, &b.kinds, b.waiting_bytes),
        (None, None) => true,
        _ => false,
    });
    if same {
        ST.with(|c| c.borrow_mut().usage = fresh);
        let _ = unsafe { InvalidateRect(Some(h), None, false) };
        return;
    }
    let focus = unsafe { GetFocus() };
    let typing = !focus.0.is_null() && unsafe { IsChild(h, focus) }.as_bool();
    if !typing {
        reload();
    }
}

fn read_usage() -> Option<Usage> {
    let api = crate::api_opt()?;
    let app = crate::app_opt();
    if app.is_null() {
        return None;
    }
    let text = crate::general_ui::ask_json(|b, c| unsafe { (api.app_storage_usage)(app, b, c) })?;
    parse_usage(&text)
}

fn parse_usage(text: &str) -> Option<Usage> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let str_of = |o: &serde_json::Value, k: &str| o.get(k).and_then(|x| x.as_str()).map(str::to_string);
    let mut kinds: Vec<Kind> = v
        .get("kinds")?
        .as_array()?
        .iter()
        .filter_map(|o| {
            Some(Kind {
                key: str_of(o, "key")?,
                kept: str_of(o, "kept")?,
                bytes: o.get("bytes")?.as_u64()?,
                files: o.get("files")?.as_u64()?,
                days_key: str_of(o, "days_key"),
                mb_key: str_of(o, "mb_key"),
                fixed_days: o.get("fixed_days").and_then(|x| x.as_u64()),
                action: str_of(o, "action")?,
            })
        })
        .collect();
    // The core lists them in its order; the page shows the ones that go
    // round first. A stable sort keeps the core's order within each.
    kinds.sort_by_key(|k| !k.goes_round());
    Some(Usage {
        state_dir: str_of(&v, "state_dir")?,
        total_bytes: v.get("total_bytes")?.as_u64()?,
        waiting_bytes: v.get("waiting_bytes").and_then(|x| x.as_u64()),
        kinds,
    })
}

fn make_field(id: u16) -> HWND {
    let h = unsafe {
        CreateWindowExW(
            WS_EX_CLIENTEDGE,
            w!("EDIT"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE((ES_RIGHT | ES_AUTOHSCROLL) as u32),
            0,
            0,
            10,
            10,
            Some(page()),
            Some(HMENU(id as usize as *mut c_void)),
            None,
            None,
        )
    }
    .unwrap_or_default();
    if !h.0.is_null() {
        crate::general_ui::set_font(h, font());
        unsafe {
            let prev = SetWindowLongPtrW(h, GWLP_WNDPROC, field_proc as *const () as isize);
            let _ = SetPropW(h, PROP_PREV, Some(windows::Win32::Foundation::HANDLE(prev as *mut c_void)));
        }
    }
    h
}

fn make_button(id: u16, label: &str) -> HWND {
    let text = wide(label);
    let h = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            PCWSTR(text.as_ptr()),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(BS_PUSHBUTTON as u32),
            0,
            0,
            10,
            10,
            Some(page()),
            Some(HMENU(id as usize as *mut c_void)),
            None,
            None,
        )
    }
    .unwrap_or_default();
    if !h.0.is_null() {
        crate::general_ui::set_font(h, font());
        crate::settings_win::subclass_child(h);
    }
    h
}

/// Put each field's value in, as the config file holds it now.
fn fill_fields(usage: &Usage) {
    let no_limit = tr("No limit");
    let fields: Vec<(HWND, String)> = ST.with(|c| {
        let s = c.borrow();
        let mut out = Vec::new();
        for (r, k) in s.rows.iter().zip(usage.kinds.iter()) {
            for (h, key) in [(r.days, &k.days_key), (r.mb, &k.mb_key)] {
                if let (false, Some(key)) = (h.0.is_null(), key) {
                    out.push((h, key.clone()));
                }
            }
        }
        out
    });
    for (h, key) in fields {
        let value = crate::general_ui::form_value(&key).unwrap_or_default();
        let text = wide(&rules::field_text(&value, &no_limit));
        let _ = unsafe { SetWindowTextW(h, PCWSTR(text.as_ptr())) };
    }
}

// ================================================================== layout

/// How tall the notice is: its bold line and the sentence under it,
/// wrapped to the width it has.
fn notice_height(width: i32, dpi: i32) -> i32 {
    let s = |v| shell::scale(v, dpi);
    let text_w = width - 2 * s(grid::PAD) - s(24) - s(grid::ACTION_W[2]);
    let detail = tr(NOTICE_DETAIL);
    measure(&detail, text_w.max(1)) + metrics(bold()) + s(4) + 2 * (s(grid::ROW_GAP) + s(4))
}

fn measure(text: &str, width: i32) -> i32 {
    let mut w: Vec<u16> = text.encode_utf16().collect();
    if w.is_empty() {
        return 0;
    }
    let h = page();
    let mut r = RECT { left: 0, top: 0, right: width, bottom: 0 };
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, font().into());
        DrawTextW(dc, &mut w, &mut r, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    r.bottom
}

struct Laid {
    notice: Option<Rect>,
    page: rules::PageLayout,
    /// Where the page's own layout starts, under the notice.
    offset: i32,
}

fn laid(width: i32, dpi: i32, usage: &Usage) -> Laid {
    let notice_h = usage.waiting_bytes.map(|_| notice_height(width, dpi));
    let control_h = shell::scale(grid::CONTROL_H - 4, dpi);
    let line = metrics(font());
    // Each row as tall as its description wrapped to the width it has
    // (the kinds come with the ones that go round first, as the rows do).
    let s = |v| shell::scale(v, dpi);
    let text_w = rules::row_parts(s(grid::PAD), width - s(grid::PAD), 0, 0, dpi, control_h).text.width().max(1);
    let height = |k: &rules::Kind| {
        let lines = (measure(&tr(rules::detail_msgid(&k.key)), text_w) + line - 1) / line.max(1);
        rules::row_height(dpi, line, lines)
    };
    let cycle: Vec<i32> = usage.kinds.iter().filter(|k| k.goes_round()).map(height).collect();
    let forever: Vec<i32> = usage.kinds.iter().filter(|k| !k.goes_round()).map(height).collect();
    let page = rules::page_layout(width, dpi, line, control_h, &cycle, &forever);
    let offset = notice_h.unwrap_or(0);
    Laid { notice: notice_h.map(|h| Rect::new(0, 0, width, h)), page, offset }
}

fn layout() {
    let h = page();
    if h.0.is_null() {
        return;
    }
    let dpi = dpi_of(h);
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(h, &mut rc) };
    let (usage, ctls, ok, scroll) = ST.with(|c| {
        let s = c.borrow();
        (s.usage.clone(), s.rows.iter().map(|r| (r.days, r.mb, r.button)).collect::<Vec<_>>(), s.ok, s.scroll)
    });
    let Some(usage) = usage else {
        let _ = unsafe { InvalidateRect(Some(h), None, true) };
        return;
    };
    let at = laid(rc.right, dpi, &usage);
    let total = at.offset + at.page.height;
    let scroll = scroll.clamp(0, (total - rc.bottom).max(0));
    ST.with(|c| c.borrow_mut().scroll = scroll);
    unsafe {
        let si = SCROLLINFO {
            cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
            fMask: SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL,
            nMin: 0,
            nMax: total.max(0),
            nPage: rc.bottom.max(0) as u32,
            nPos: scroll,
            nTrackPos: 0,
        };
        SetScrollInfo(h, SB_VERT, &si, true);
    }
    let put = |c: HWND, r: Rect| unsafe {
        if !c.0.is_null() {
            let _ = SetWindowPos(c, None, r.left, r.top + at.offset - scroll, r.width(), r.height(), SWP_NOZORDER | SWP_NOACTIVATE);
        }
    };
    for ((days, mb, button), parts) in ctls.iter().zip(at.page.rows.iter()) {
        put(*days, parts.days);
        put(*mb, parts.mb);
        put(*button, parts.button);
    }
    if let (false, Some(n)) = (ok.0.is_null(), at.notice) {
        let s = |v| shell::scale(v, dpi);
        let w = s(grid::ACTION_W[2]);
        let bh = shell::scale(grid::CONTROL_H - 4, dpi);
        let r = Rect::new(n.right - s(grid::PAD) - w, n.top + (n.height() - bh) / 2, n.right - s(grid::PAD), n.top + (n.height() - bh) / 2 + bh);
        unsafe {
            let _ = SetWindowPos(ok, None, r.left, r.top - scroll, r.width(), r.height(), SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }
    let _ = unsafe { InvalidateRect(Some(h), None, true) };
}

const NOTICE_DETAIL: &str = n_("This is the first clearing since the upgrade, and nothing is deleted until you choose OK. You can change the settings below first; a change counts as agreeing.");

fn paint(win: HWND) {
    let dpi = dpi_of(win);
    let s = |v| shell::scale(v, dpi);
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let (usage, unavailable, scroll) = ST.with(|c| {
        let st = c.borrow();
        (st.usage.clone(), st.unavailable, st.scroll)
    });
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(win, &mut ps) };
    fill(hdc, &rc, theme::bg());
    let to = |r: Rect, dy: i32| RECT { left: r.left, top: r.top + dy, right: r.right, bottom: r.bottom + dy };
    let one = DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS;
    match usage {
        None => {
            let line = RECT { left: s(grid::PAD), top: s(grid::PAD), right: rc.right - s(grid::PAD), bottom: s(grid::PAD) + metrics(font()) };
            let said = if unavailable { tr("Polter has no records to show yet.") } else { String::new() };
            draw_text(hdc, &said, &line, font(), theme::dim(), one);
        }
        Some(u) => {
            let at = laid(rc.right, dpi, &u);
            let dy = at.offset - scroll;
            if let (Some(n), Some(bytes)) = (at.notice, u.waiting_bytes) {
                let band = to(n, -scroll);
                fill(hdc, &band, theme::panel());
                let x = s(grid::PAD) + s(24);
                let right = band.right - s(grid::PAD) - s(grid::ACTION_W[2]) - s(rules::COL_GAP);
                let title = rules::fill(&tr("The new retention settings will clear %@ of old records"), &rules::size_text(bytes), 0);
                let t = RECT { left: x, top: band.top + s(grid::ROW_GAP) + s(4), right, bottom: band.top + s(grid::ROW_GAP) + s(4) + metrics(bold()) };
                draw_text(hdc, "⚠", &RECT { left: s(grid::PAD), right: x, ..t }, bold(), theme::warn(), one);
                draw_text(hdc, &title, &t, bold(), theme::text(), one);
                let d = RECT { left: x, top: t.bottom + s(4), right, bottom: band.bottom };
                draw_text(hdc, &tr(NOTICE_DETAIL), &d, font(), theme::dim(), DT_LEFT | DT_WORDBREAK);
            }
            let intro = rules::fill(&tr("%1$@ in all, in %2$@. Past the limits, cleared when Polter starts and every hour after."), &rules::size_text(u.total_bytes), 0);
            let intro = intro.replace("%2$@", &u.state_dir);
            draw_text(hdc, &intro, &to(at.page.intro, dy), font(), theme::dim(), one);
            heading(hdc, &to(at.page.cycle_heading, dy), &tr("Kept Going Round"), &tr("Past the days or the total, the oldest go first"), dpi);
            heading(hdc, &to(at.page.forever_heading, dy), &tr("Kept for Good"), &tr("Deleted only when you choose Clear"), dpi);
            for (k, p) in u.kinds.iter().zip(at.page.rows.iter()) {
                let line = metrics(font());
                let text = to(p.text, dy);
                // The description wraps, to at most `DETAIL_LINES`; its row
                // was made tall enough for what it takes (`laid`).
                let detail = tr(rules::detail_msgid(&k.key));
                let lines = ((measure(&detail, (text.right - text.left).max(1)) + line - 1) / line.max(1)).clamp(1, rules::DETAIL_LINES);
                let top = text.top + (text.bottom - text.top - (1 + lines) * line - s(rules::LINE_GAP)) / 2;
                draw_text(hdc, &tr(rules::title_msgid(&k.key)), &RECT { top, bottom: top + line, ..text }, bold(), theme::text(), one);
                let d = RECT { top: top + line + s(rules::LINE_GAP), bottom: top + (1 + lines) * line + s(rules::LINE_GAP), ..text };
                draw_text(hdc, &detail, &d, font(), theme::dim(), DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS);
                // The rule, where there are no fields to say it.
                let rule = match k.kept.as_str() {
                    "fixed" => Some(rules::fill(&tr("Fixed at %lld days"), "", k.fixed_days.unwrap_or(0))),
                    "forever" => Some(tr("Kept for good")),
                    _ => None,
                };
                if let Some(r) = rule {
                    draw_text(hdc, &r, &to(p.rule, dy), font(), theme::dim(), one);
                } else {
                    if k.days_key.is_none() {
                        let dr = to(Rect::new(p.rule.left, p.row.top, p.days_unit.right, p.row.bottom), dy);
                        draw_text(hdc, &tr("Not by days"), &dr, font(), theme::dim(), DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
                    } else {
                        draw_text(hdc, &tr("days"), &to(p.days_unit, dy), font(), theme::dim(), one);
                    }
                    draw_text(hdc, "MB", &to(p.mb_unit, dy), font(), theme::dim(), one);
                }
                draw_text(hdc, &rules::size_text(k.bytes), &to(p.size, dy), font(), theme::text(), DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
            }
        }
    }
    let _ = unsafe { EndPaint(win, &ps) };
}

fn heading(hdc: HDC, r: &RECT, title: &str, note: &str, dpi: i32) {
    let one = DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS;
    draw_text(hdc, title, r, bold(), theme::text(), one);
    let w = text_width(title, bold()) + shell::scale(grid::ROW_GAP, dpi);
    draw_text(hdc, note, &RECT { left: r.left + w, ..*r }, font(), theme::dim(), one);
}

fn text_width(text: &str, f: HFONT) -> i32 {
    let mut r = RECT::default();
    let mut w: Vec<u16> = text.encode_utf16().collect();
    if w.is_empty() {
        return 0;
    }
    let h = page();
    unsafe {
        let dc = GetDC(Some(h));
        let old = SelectObject(dc, f.into());
        DrawTextW(dc, &mut w, &mut r, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(dc, old);
        ReleaseDC(Some(h), dc);
    }
    r.right - r.left
}

// ================================================================ acting

/// Which row and part a control id is.
fn part_of(id: u16) -> Option<(usize, u16)> {
    let off = id.checked_sub(ID_ROW_BASE)?;
    let n = ST.with(|c| c.borrow().rows.len());
    let (row, part) = ((off / 4) as usize, off % 4);
    (row < n && part <= PART_BUTTON).then_some((row, part))
}

fn kind_at(row: usize) -> Option<Kind> {
    ST.with(|c| c.borrow().usage.as_ref()?.kinds.get(row).cloned())
}

/// A field lost the keyboard, or took Return: write what it says.
fn commit(row: usize, part: u16) {
    let Some(k) = kind_at(row) else { return };
    let key = if part == PART_DAYS { k.days_key } else { k.mb_key };
    let Some(key) = key else { return };
    let h = ST.with(|c| c.borrow().rows.get(row).map(|r| if part == PART_DAYS { r.days } else { r.mb }));
    let Some(h) = h else { return };
    let mut buf = [0u16; 64];
    let n = unsafe { GetWindowTextW(h, &mut buf) } as usize;
    let typed = String::from_utf16_lossy(&buf[..n]);
    let now = crate::general_ui::form_value(&key).unwrap_or_default();
    let no_limit = tr("No limit");
    let Some(value) = rules::value_to_write(&typed, &no_limit) else {
        let back = wide(&rules::field_text(&now, &no_limit));
        let _ = unsafe { SetWindowTextW(h, PCWSTR(back.as_ptr())) };
        crate::general_ui::say_status(tr("Write a whole number, or leave it empty for no limit."), true);
        return;
    };
    if value == now {
        return;
    }
    let r = crate::general_ui::set(&key, Some(&value));
    if r.ok {
        crate::general_ui::say_status(tr("Saved to the config file."), false);
    } else {
        crate::general_ui::say_status(r.message.unwrap_or(r.code), true);
    }
    // The write reloads the config; the sweep runs with the new limits on
    // its own thread, and what it left is read when the page is shown next.
    crate::general_ui::refresh_form_values();
    reload_later();
}

/// "Clear…" on a row: ask, then have the core clear it once.
fn clear(row: usize) {
    let Some(shown) = kind_at(row) else { return };
    // Measured now, as the question is asked: the figure on the row may be
    // minutes old, and the confirmation is what the person agrees to.
    let Some(k) = read_usage().and_then(|u| u.kinds.into_iter().find(|f| f.key == shown.key)) else { return };
    let c = rules::confirmation(&k.key);
    let size = rules::size_text(k.bytes);
    let title = rules::fill(&tr(c.title), &tr(rules::title_msgid(&k.key)), 0);
    let body: Vec<String> = c.lines.iter().map(|l| rules::fill(&tr(l), &size, k.files)).collect();
    let owner = unsafe { GetAncestor(page(), GA_ROOT) };
    let buttons = [tr(c.button), tr("Cancel")];
    let pressed = crate::projects_ui::ask_with_default(owner, "[logs-ui]", &title, &body.join("\n\n"), &buttons, 1);
    if pressed != Some(0) {
        return;
    }
    let Some(api) = crate::api_opt() else { return };
    let app = crate::app_opt();
    if app.is_null() {
        return;
    }
    // Once, into a buffer that is big enough: never called for its size.
    let mut buf = vec![0u8; 512];
    let n = unsafe { (api.app_storage_clear)(app, k.key.as_ptr(), k.key.len(), buf.as_mut_ptr(), buf.len()) };
    let text = String::from_utf8_lossy(&buf[..n.min(buf.len())]).into_owned();
    // process-wide: one state directory, cleared from the one settings window
    crate::plogf!("[logs-ui] clear {} -> {}", k.key, text);
    let v: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    if v.get("ok").and_then(|b| b.as_bool()) == Some(true) {
        let bytes = v.get("bytes").and_then(|b| b.as_u64()).unwrap_or(0);
        crate::general_ui::say_status(rules::fill(&tr("Cleared %@."), &rules::size_text(bytes), 0), false);
    } else if text.contains("ProjectUnreadable") {
        crate::general_ui::say_status(tr("A project file could not be read, so no shell history was cleared: it might have named some of it."), true);
    } else {
        crate::general_ui::say_status(tr("Nothing was cleared: Polter's core refused."), true);
    }
    reload_later();
}

/// The person said OK to the first sweep.
fn agree() {
    let Some(api) = crate::api_opt() else { return };
    let app = crate::app_opt();
    if app.is_null() {
        return;
    }
    let req = br#"{"act":"retention_agree"}"#;
    let mut err = [0u8; 64];
    let ok = unsafe { (api.app_control_act)(app, req.as_ptr(), req.len(), err.as_mut_ptr(), err.len()) };
    // process-wide: as above
    crate::plogf!("[logs-ui] retention_agree -> {ok}");
    reload_later();
}

/// The bottom band's "Show in Explorer": the state directory.
pub fn reveal() {
    let dir = ST.with(|c| c.borrow().usage.as_ref().map(|u| u.state_dir.clone()));
    if let Some(dir) = dir {
        let root = unsafe { GetAncestor(page(), GA_ROOT) };
        if !crate::shellopen::detached(Some(root), "[logs-ui] show folder", dir) {
            crate::general_ui::say_status(tr("Explorer could not be started."), true);
        }
    }
}

fn scroll_to(to: i32) {
    ST.with(|c| c.borrow_mut().scroll = to.max(0));
    layout();
}

unsafe extern "system" fn field_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetPropW(h, PROP_PREV).0 as isize;
        match msg {
            WM_KEYDOWN if wp.0 as u16 == VK_RETURN.0 => {
                if let Some((row, part)) = part_of(GetDlgCtrlID(h) as u16) {
                    commit(row, part);
                }
                return LRESULT(0);
            }
            WM_KEYDOWN if crate::settings_win::is_close_key(wp.0 as u16) => {
                let _ = PostMessageW(Some(GetAncestor(h, GA_ROOT)), WM_CLOSE, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            WM_CHAR if wp.0 == 0x0D || wp.0 == 0x17 || wp.0 == 0x1B => return LRESULT(0),
            WM_NCDESTROY => {
                let _ = RemovePropW(h, PROP_PREV);
            }
            _ => {}
        }
        CallWindowProcW(std::mem::transmute::<isize, WNDPROC>(prev), h, msg, wp, lp)
    }
}

unsafe extern "system" fn page_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if let Some(r) = crate::roles_ui::common(win, msg, wp, lp) {
            return r;
        }
        match msg {
            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as u16;
                let code = ((wp.0 >> 16) & 0xFFFF) as u32;
                if id == ID_OK {
                    agree();
                } else if let Some((row, part)) = part_of(id) {
                    let filling = ST.with(|c| c.borrow().filling);
                    match part {
                        PART_BUTTON if code == BN_CLICKED => clear(row),
                        PART_DAYS | PART_MB if code == EN_KILLFOCUS && !filling => commit(row, part),
                        _ => {}
                    }
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
                scroll_to(to);
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
                let now = ST.with(|c| c.borrow().scroll);
                let step = shell::scale(rules::ROW_H + grid::ROW_GAP, dpi_of(win)) * 3;
                scroll_to(now - delta * step / 120);
                LRESULT(0)
            }
            WM_RELOAD_LATER => {
                reload();
                LRESULT(0)
            }
            WM_TIMER if wp.0 == REFRESH_TIMER => {
                refresh();
                LRESULT(0)
            }
            WM_SIZE => {
                layout();
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
