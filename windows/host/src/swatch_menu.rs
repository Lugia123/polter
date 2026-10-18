//! The colours in a pane's menu: two rows of five dots, laid flat in the
//! menu and picked with one click (task 1700; the user, 2026-10-18: not a
//! submenu, because it is something done often).
//!
//! **A Win32 menu item is one command**, so each row is one owner-drawn
//! item and which of its dots was meant is worked out here, from where the
//! row is and where the pointer was (`polter_control_room::swatch`, which
//! has the arithmetic and its tests). The menu's own loop is watched with a
//! `WH_MSGFILTER` hook for as long as the menu is up: a move over a row
//! lights the dot under the pointer, a click records which dot, and
//! ←/→ move the lit dot along the row the keyboard is on -- Enter then
//! picks it, as the menu returns the row.
//!
//! **Not readable by a screen reader** (owner-drawn items carry no text):
//! said in the task's delivery as a debt, not hidden.
//!
//! One menu at a time on one thread, which is what `TrackPopupMenu` is; the
//! state is thread-local and lives from `begin` to `end`.

use std::cell::RefCell;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, MEASUREITEMSTRUCT, ODT_MENU};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{VK_LEFT, VK_RIGHT};
use windows::Win32::UI::WindowsAndMessaging::*;

use polter_control_room::layout::Rect;
use polter_control_room::look::{self, Rgba};
use polter_control_room::pane_color::Color;
use polter_control_room::swatch::{self, Key, PER_ROW};

/// The two rows' command ids. Clear of every range in `strip.rs` and
/// `ctxmenu.rs` (those asserts are there).
pub const ROW_BASE: usize = 0x5100;
pub const ROWS: usize = 2;

struct Session {
    /// The colour set on the pane the menu is about: ringed.
    current: Option<Color>,
    dark: bool,
    scale: f64,
    /// Each row's rectangle on the screen, as it was last drawn; empty
    /// until it has been.
    rows: [RECT; ROWS],
    /// Where the dots start in a row, from its left edge.
    inset: i32,
    /// The row the menu has selected, if it is one of ours.
    on: Option<usize>,
    /// The lit dot of that row.
    hot: usize,
    /// The dot a click landed on: what the menu's answer means.
    picked: Option<usize>,
    hook: HHOOK,
}

thread_local! {
    static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
}

/// The palette index, 0 none, of row `row`'s dot `at`.
fn color_at(row: usize, at: usize) -> Option<Color> {
    Color::from_c(swatch::index(row, at))
}

/// Add the «Color» heading and the two rows to `menu`, for a pane whose
/// colour is `current`. Call `begin` before `TrackPopupMenu` and `end`
/// after it.
pub fn append(menu: HMENU, heading: &str) -> usize {
    unsafe {
        let mut wide: Vec<u16> = heading.encode_utf16().collect();
        wide.push(0);
        let _ = AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, PCWSTR(wide.as_ptr()));
        for row in 0..ROWS {
            let _ = AppendMenuW(menu, MF_OWNERDRAW, ROW_BASE + row, PCWSTR(row as *const u16));
        }
    }
    ROWS
}

/// Start watching the menu that is about to be shown.
pub fn begin(current: Option<Color>, dark: bool, scale: f64) {
    let hook = unsafe { SetWindowsHookExW(WH_MSGFILTER, Some(filter), None, GetCurrentThreadId()) }.unwrap_or_default();
    if hook.is_invalid() {
        // process-wide: the hook is this thread's, and without it the dots
        // still draw and a click still picks a row -- only which dot is lost.
        crate::plogf!("[swatch] SetWindowsHookExW(WH_MSGFILTER) failed; a click on a colour row picks nothing");
    }
    let inset = unsafe { GetSystemMetrics(SM_CXMENUCHECK) } + (8.0 * scale).round() as i32;
    let hot = current.map_or(0, |c| c.to_c() % PER_ROW);
    SESSION.with(|s| {
        *s.borrow_mut() = Some(Session { current, dark, scale, rows: [RECT::default(); ROWS], inset, on: None, hot, picked: None, hook });
    });
}

/// Stop watching; what the menu's answer `chosen` meant: `Some(colour)`
/// (`None` inside it is "no colour") when it was one of the rows and a dot
/// was meant, `None` when it was not about a colour or no dot was.
pub fn end(chosen: usize) -> Option<Option<Color>> {
    let s = SESSION.with(|s| s.borrow_mut().take())?;
    if !s.hook.is_invalid() {
        let _ = unsafe { UnhookWindowsHookEx(s.hook) };
    }
    let row = chosen.checked_sub(ROW_BASE).filter(|r| *r < ROWS)?;
    // A click says which dot; a key says the lit one.
    let at = s.picked.or((s.on == Some(row)).then_some(s.hot))?;
    Some(color_at(row, at))
}

/// The owner window's `WM_MEASUREITEM`, `WM_DRAWITEM` and `WM_MENUSELECT`
/// while a menu with the rows is up; `None` for anything that is not ours.
pub fn on_owner_message(msg: u32, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
    SESSION.with(|cell| {
        let mut b = cell.borrow_mut();
        let s = b.as_mut()?;
        match msg {
            WM_MEASUREITEM => {
                let m = unsafe { &mut *(lp.0 as *mut MEASUREITEMSTRUCT) };
                let row = (m.itemID as usize).checked_sub(ROW_BASE).filter(|r| m.CtlType == ODT_MENU && *r < ROWS)?;
                let _ = row;
                m.itemWidth = (s.inset as f64 + swatch::row_width(s.scale) + (12.0 * s.scale).round()) as u32;
                m.itemHeight = swatch::item_height(s.scale) as u32;
                Some(LRESULT(1))
            }
            WM_DRAWITEM => {
                let d = unsafe { &*(lp.0 as *const DRAWITEMSTRUCT) };
                let row = (d.itemID as usize).checked_sub(ROW_BASE).filter(|r| d.CtlType == ODT_MENU && *r < ROWS)?;
                // Where the row is on the screen, for the hook: the menu's
                // window is the DC's.
                let mut screen = d.rcItem;
                unsafe {
                    let w = WindowFromDC(d.hDC);
                    let mut pts = [POINT { x: screen.left, y: screen.top }, POINT { x: screen.right, y: screen.bottom }];
                    MapWindowPoints(Some(w), None, &mut pts);
                    screen = RECT { left: pts[0].x, top: pts[0].y, right: pts[1].x, bottom: pts[1].y };
                }
                s.rows[row] = screen;
                draw_row(d, row, s);
                Some(LRESULT(1))
            }
            WM_MENUSELECT => {
                // Which item the menu has selected: ours, or not.
                let id = (wp.0 & 0xffff) as usize;
                s.on = id.checked_sub(ROW_BASE).filter(|r| *r < ROWS);
                None
            }
            _ => None,
        }
    })
}

fn colorref(c: Rgba) -> windows::Win32::Foundation::COLORREF {
    windows::Win32::Foundation::COLORREF((c.r as u32) | ((c.g as u32) << 8) | ((c.b as u32) << 16))
}

fn draw_row(d: &DRAWITEMSTRUCT, row: usize, s: &Session) {
    let theme = look::theme(s.dark);
    let item = Rect {
        x: d.rcItem.left as f64,
        y: d.rcItem.top as f64,
        w: (d.rcItem.right - d.rcItem.left) as f64,
        h: (d.rcItem.bottom - d.rcItem.top) as f64,
    };
    unsafe {
        // The menu's own ground: an owner-drawn item paints all of itself.
        let ground = GetSysColorBrush(COLOR_MENU);
        FillRect(d.hDC, &d.rcItem, ground);
        let menu_bg = GetSysColor(COLOR_MENU);
        let bg = Rgba { r: (menu_bg & 0xff) as u8, g: ((menu_bg >> 8) & 0xff) as u8, b: ((menu_bg >> 16) & 0xff) as u8, a: 1.0 };
        let text = GetSysColor(COLOR_MENUTEXT);
        let ink = Rgba { r: (text & 0xff) as u8, g: ((text >> 8) & 0xff) as u8, b: ((text >> 16) & 0xff) as u8, a: 1.0 };
        let left = item.x + s.inset as f64;
        let lit = (s.on == Some(row)).then_some(s.hot);
        for (at, r) in swatch::dots(item, left, s.scale).iter().enumerate() {
            let rc = RECT { left: r.x as i32, top: r.y as i32, right: (r.x + r.w) as i32, bottom: (r.y + r.h) as i32 };
            let radius = (r.w / 2.0) as i32;
            let c = color_at(row, at);
            // The dot the pane has, or the one the keyboard or the pointer
            // is on, wears a ring a step outside it.
            let ringed = c == s.current || lit == Some(at);
            if ringed {
                let grow = (2.0 * s.scale).round() as i32;
                let ring = RECT { left: rc.left - grow, top: rc.top - grow, right: rc.right + grow, bottom: rc.bottom + grow };
                crate::control_room::round(d.hDC, ring, radius + grow, bg, Some(ink));
            }
            match c {
                Some(c) => crate::control_room::round(d.hDC, rc, radius, c.ink(theme), None),
                None => {
                    // No colour: a hollow circle with a stroke through it.
                    crate::control_room::round(d.hDC, rc, radius, bg, Some(ink));
                    let pen = CreatePen(PS_SOLID, (1.0 * s.scale).max(1.0) as i32, colorref(ink));
                    let old = SelectObject(d.hDC, pen.into());
                    let _ = MoveToEx(d.hDC, rc.right - 2, rc.top + 2, None);
                    let _ = LineTo(d.hDC, rc.left + 2, rc.bottom - 2);
                    SelectObject(d.hDC, old);
                    let _ = DeleteObject(pen.into());
                }
            }
        }
    }
}

/// The menu's own loop, seen before it acts.
unsafe extern "system" fn filter(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code == MSGF_MENU as i32 {
        let m = unsafe { &*(lp.0 as *const MSG) };
        if let Some(eat) = SESSION.with(|cell| cell.borrow_mut().as_mut().and_then(|s| on_menu_message(s, m))) {
            if eat {
                return LRESULT(1);
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wp, lp) }
}

/// What the hook does with one message of the menu's loop: `Some(true)` to
/// swallow it.
fn on_menu_message(s: &mut Session, m: &MSG) -> Option<bool> {
    let row_under = |pt: POINT| s.rows.iter().position(|r| r.right > r.left && pt.x >= r.left && pt.x < r.right && pt.y >= r.top && pt.y < r.bottom);
    match m.message {
        WM_MOUSEMOVE | WM_LBUTTONDOWN | WM_LBUTTONUP => {
            let pt = m.pt;
            let row = row_under(pt)?;
            let r = s.rows[row];
            let item = Rect { x: r.left as f64, y: r.top as f64, w: (r.right - r.left) as f64, h: (r.bottom - r.top) as f64 };
            let at = swatch::hit(item, item.x + s.inset as f64, s.scale, pt.x as f64);
            if m.message == WM_MOUSEMOVE {
                if let Some(at) = at {
                    if s.hot != at || s.on != Some(row) {
                        s.hot = at;
                        unsafe {
                            let _ = InvalidateRect(Some(m.hwnd), None, false);
                        }
                    }
                }
                return Some(false);
            }
            match at {
                Some(at) => {
                    s.picked = Some(at);
                    Some(false)
                }
                // Beside the dots: not a pick, and the menu stays up.
                None => Some(true),
            }
        }
        WM_KEYDOWN if s.on.is_some() => {
            let key = match m.wParam.0 as u16 {
                k if k == VK_LEFT.0 => Key::Left,
                k if k == VK_RIGHT.0 => Key::Right,
                _ => return None,
            };
            s.hot = swatch::step(s.hot, key);
            s.picked = None;
            unsafe {
                let _ = InvalidateRect(Some(m.hwnd), None, false);
            }
            Some(true)
        }
        _ => None,
    }
}

/// The binding action that sets colour `c` (none clears it) on a terminal.
pub fn action(c: Option<Color>) -> String {
    format!("poltergeist_set_pane_color:{}", c.map_or("none", Color::name))
}
