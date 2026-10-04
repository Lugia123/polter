//! The project picker: the window "Save as Project…" and "Load Project…"
//! open, and what picking in it does.
//!
//! **One window for both, as on macOS** (`ProjectPicker.swift`,
//! `ProjectPickerView.swift`): a title bar that says which it is, a field on
//! top, every saved project under it, Cancel at the bottom, in the middle of
//! the screen. Saving, the field is the new project's name with Save beside
//! it, and picking a row overwrites that project after asking. Loading, the
//! field searches the list, and picking a row opens it. "Save as a Project
//! Before Closing?" opens the same window to save.
//!
//! **Why this is no longer a popup menu and a one-line box.** Loading used to
//! be a `TrackPopupMenu` at the pointer and saving a borderless name box
//! (`prompt.rs`). A menu cannot be searched, has no title, and opens wherever
//! the pointer was; the box showed none of the projects a name could land
//! on. Same entry points as macOS, and neither looked like it.
//!
//! **Where things go and what a key does is `polter_settings_shell::picker`**,
//! whose tests run on the Mac. What is here is Win32 asking it.
//!
//! **Opened from the message loop, not from inside the menu call**, for the
//! reason `language::request_picker` gives: `--polter-host-menu-selftest`
//! performs every row through the same call a click makes.
//!
//! ⚠️ **Nothing here dispatches a message while `MODEL` is borrowed**
//! (`windows/tools/borrow-across-dispatch.py`): the window handles live in
//! `HANDLES`, a `Cell`, so a borrow hands out no window to call anything on.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::atomic::{AtomicPtr, Ordering};

use polter_settings_shell::picker::{self, Mode};
use polter_settings_shell::projects as pj;
use polter_settings_shell::Rect as SRect;
use windows::core::{w, BOOL, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HANDLE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWINDOWATTRIBUTE};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Controls::{
    SetWindowTheme, CDDS_PREPAINT, CDIS_DISABLED, CDIS_FOCUS, CDIS_HOT, CDIS_SELECTED, CDRF_SKIPDEFAULT, DRAWITEMSTRUCT, NMCUSTOMDRAW,
    NM_CUSTOMDRAW, ODS_SELECTED,
};
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForWindow};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetFocus, GetKeyState, SetFocus, VK_DOWN, VK_ESCAPE, VK_RETURN, VK_SHIFT, VK_TAB, VK_UP,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::{n_, tr};
use crate::tabs::TabId;
use crate::{project, theme, wlogf};

static PENDING_FRAME: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

const ID_FIELD: usize = 100;
const ID_SAVE: usize = 101;
const ID_CANCEL: usize = 102;
const ID_LIST: usize = 103;

/// Posted by the list and the field to the picker: the row at `WPARAM` (its
/// place in the list as shown) was picked. **Posted, not sent**, so the list
/// has finished with the click by the time the window it is in goes away.
const WM_PICK: u32 = WM_APP + 31;
/// Posted the same way: Escape.
const WM_DISMISS: u32 = WM_APP + 32;

const PROP_PREV: PCWSTR = w!("PolterProjectPickerPrevProc");
const STYLE: WINDOW_STYLE = WINDOW_STYLE(WS_POPUP.0 | WS_CAPTION.0 | WS_SYSMENU.0 | WS_CLIPCHILDREN.0);
const EX_STYLE: WINDOW_EX_STYLE = WS_EX_DLGMODALFRAME;

/// What the window is for.
#[derive(Clone, Copy, Debug)]
enum Purpose {
    Load,
    /// Save `tab`. `close_after` is the "Save as a Project Before Closing?"
    /// case (settings.md §6.3): the tab -- or, with `true`, its window --
    /// closes once the save has worked, and only then.
    Save { tab: TabId, close_after: Option<bool> },
}

impl Purpose {
    fn mode(self) -> Mode {
        match self {
            Purpose::Load => Mode::Load,
            Purpose::Save { .. } => Mode::SaveAs,
        }
    }

    /// **No ellipsis**: macOS spells the *menu row* `Save as Project...`;
    /// this is the window that row opens.
    fn title(self) -> &'static str {
        match self {
            Purpose::Load => n_("Load Project"),
            Purpose::Save { .. } => n_("Save as Project"),
        }
    }
}

/// One saved project, as a row shows it.
#[derive(Clone, Debug)]
struct Item {
    name: String,
    saved_at: i64,
    panes: usize,
    /// **The project's identity** for opening it (`project::Entry::path`).
    path: PathBuf,
}

/// The windows and what was made for them. `Copy`, and outside `MODEL`: see
/// the header.
#[derive(Clone, Copy)]
struct Handles {
    hwnd: HWND,
    field: HWND,
    list: HWND,
    save: HWND,
    frame: HWND,
    /// Who had the keyboard when the window opened.
    prev: HWND,
    font: HFONT,
    font_small: HFONT,
    list_brush: HBRUSH,
    purpose: Purpose,
}

struct Model {
    items: Vec<Item>,
    /// Indices into `items`, as the list shows them now.
    shown: Vec<usize>,
    /// "Saves this tab: N pane(s)", when saving.
    caption: Option<String>,
}

thread_local! {
    static HANDLES: Cell<Option<Handles>> = const { Cell::new(None) };
    static MODEL: RefCell<Option<Model>> = const { RefCell::new(None) };
    /// A pick is being acted on: the overwrite question runs a message loop
    /// of its own, and a second pick arriving in it would ask twice.
    static ACTING: Cell<bool> = const { Cell::new(false) };
}

fn handles() -> Option<Handles> {
    HANDLES.with(|h| h.get())
}



fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn rect(r: SRect) -> RECT {
    RECT { left: r.left, top: r.top, right: r.right, bottom: r.bottom }
}

// ================================================================= opening

/// Open the window to load a project into `frame`. **Returns at once**; the
/// window opens from the thread's own message loop. See the module comment.
pub fn request_load(frame: HWND) -> bool {
    PENDING_FRAME.store(frame.0, Ordering::Release);
    let id = unsafe { SetTimer(None, 0, 0, Some(load_timer)) };
    // not-gated: the condition is the event -- the timer was refused, and
    // without this line a click that opened nothing would leave no trace.
    if id == 0 {
        wlogf!(frame, "[project] SetTimer failed; the project list was not opened");
        return false;
    }
    true
}

unsafe extern "system" fn load_timer(_: HWND, _: u32, id: usize, _: u32) {
    let _ = unsafe { KillTimer(None, id) };
    let frame = HWND(PENDING_FRAME.swap(std::ptr::null_mut(), Ordering::AcqRel));
    if frame.0.is_null() {
        return;
    }
    open(frame, frame, Purpose::Load);
}

/// Open the window to save tab `tab` of `frame` as a project. **Main thread
/// only** -- it makes windows.
pub fn open_save(frame: HWND, tab: TabId) {
    open(frame, frame, Purpose::Save { tab, close_after: None });
}

/// The same, asked for from another window -- the settings window's "+".
/// **The window belongs to `owner`, the one the person is looking at**: owned
/// by the terminal window instead, one click on the settings window put it
/// behind that window with nothing to say it was still there. What is saved
/// is still `frame`'s tab.
pub fn open_save_over(owner: HWND, frame: HWND, tab: TabId) {
    open(owner, frame, Purpose::Save { tab, close_after: None });
}

/// The same, from "Save as a Project Before Closing?" (settings.md §6.3):
/// the tab -- or, with `whole_window`, its window -- closes once the save has
/// worked, and only then (`ProjectSaveBeforeClose.saveThenClose`).
pub fn open_save_then_close(frame: HWND, tab: TabId, whole_window: bool) {
    open(frame, frame, Purpose::Save { tab, close_after: Some(whole_window) });
}

/// The saved projects, newest first, as `ProjectStore.list` orders them on
/// macOS and the settings window does here.
fn read_items(frame: HWND) -> Vec<Item> {
    let Some(dir) = project::resolve_state_dir().map(|s| project::default_dir(&s)) else {
        wlogf!(frame, "[project] no state directory (neither XDG_STATE_HOME nor LOCALAPPDATA); nothing to list");
        return Vec::new();
    };
    let listing = project::list(&dir);
    // **Every project left out is named.** `list` skips what it cannot read
    // -- on purpose, and the same on every platform -- so the one thing this
    // window owes the person is that a missing row has a line to find.
    for (path, why) in &listing.skipped {
        wlogf!(frame, "[project] list left out {:?}: {}", path, why);
    }
    let mut items: Vec<Item> = listing
        .entries
        .into_iter()
        .map(|e| {
            let panes = project::read_file(&e.path)
                .ok()
                .and_then(|s| s.root.as_ref().map(crate::project_ui::leaf_count))
                .unwrap_or(0);
            Item { name: e.name, saved_at: e.saved_at, panes, path: e.path }
        })
        .collect();
    items.sort_by(|a, b| b.saved_at.cmp(&a.saved_at).then_with(|| a.name.cmp(&b.name)));
    wlogf!(frame, "[project] picker list: {} project(s), {} left out, in {:?}", items.len(), listing.skipped.len(), dir);
    items
}

/// How many panes the tab being saved has, for the line under the name.
fn panes_of(frame: HWND, tab: TabId) -> Option<usize> {
    let index = crate::tabs::strip_snapshot(frame).0.iter().position(|(t, _)| *t == tab)?;
    crate::tabs::tab_pane_count(frame, index).filter(|(t, _)| *t == tab).map(|(_, n)| n)
}

/// `owner` is the window this one stays in front of and opens on the
/// monitor of; `frame` is the terminal window it loads into or saves from.
fn open(owner: HWND, frame: HWND, purpose: Purpose) {
    // One picker: a second request replaces the first, as `present` does on
    // macOS.
    dismiss();

    if frame.0.is_null() {
        // process-wide: there is no window to name -- that is what this line
        // reports. Naming one here would have to invent it.
        crate::plogf!("[project] no frame window; {} window not shown", purpose.title());
        return;
    }
    let items = read_items(frame);
    let caption = match purpose {
        Purpose::Load => None,
        Purpose::Save { tab, .. } => Some(match panes_of(frame, tab) {
            Some(n) => tr("Saves this tab: {} pane(s)").replacen("{}", &n.to_string(), 1),
            None => String::new(),
        }),
    };

    let owner = if owner.0.is_null() { frame } else { owner };
    let dpi = (unsafe { GetDpiForWindow(owner) } as i32).max(96);
    let (cw, ch) = (pj_scale(picker::WIDTH, dpi), pj_scale(picker::HEIGHT, dpi));
    let mut outer = RECT { left: 0, top: 0, right: cw, bottom: ch };
    let _ = unsafe { AdjustWindowRectExForDpi(&mut outer, STYLE, false, EX_STYLE, dpi as u32) };
    let (ow, oh) = (outer.right - outer.left, outer.bottom - outer.top);
    // The middle of the monitor its owner is on.
    let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    let work = if unsafe { GetMonitorInfoW(MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST), &mut mi) }.as_bool() {
        SRect::new(mi.rcWork.left, mi.rcWork.top, mi.rcWork.right, mi.rcWork.bottom)
    } else {
        let mut fr = RECT::default();
        let _ = unsafe { GetWindowRect(owner, &mut fr) };
        SRect::new(fr.left, fr.top, fr.right, fr.bottom)
    };
    let (x, y) = picker::centred(work, ow, oh);
    let l = picker::layout(purpose.mode(), cw, ch, dpi);

    unsafe {
        register_class();
        // Who has the keyboard now, read before the window can take it.
        let prev = GetFocus();
        let title = wide(&tr(purpose.title()));
        let hwnd = CreateWindowExW(EX_STYLE, w!("PolterProjectPicker"), PCWSTR(title.as_ptr()), STYLE, x, y, ow, oh, Some(owner), None, None, None);
        let Ok(hwnd) = hwnd else {
            wlogf!(frame, "[project] CreateWindowExW failed; {} window not shown", purpose.title());
            return;
        };
        if theme::custom_drawing() {
            // The dark title bar, as `shell.rs` asks for the frame's.
            let on: BOOL = true.into();
            let _ = DwmSetWindowAttribute(hwnd, DWMWINDOWATTRIBUTE(20), &on as *const BOOL as *const c_void, std::mem::size_of::<BOOL>() as u32);
        }

        let child = |class: PCWSTR, text: &str, style: u32, r: SRect, id: usize| -> HWND {
            let t = wide(text);
            CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                class,
                PCWSTR(t.as_ptr()),
                WS_CHILD | WS_VISIBLE | WINDOW_STYLE(style),
                r.left,
                r.top,
                r.width(),
                r.height(),
                Some(hwnd),
                Some(HMENU(id as *mut c_void)),
                None,
                None,
            )
            .unwrap_or_default()
        };
        // **No `WS_BORDER` while this window draws itself**, for the reason
        // `prompt.rs` gives: the themed border takes no colour from
        // `WM_CTLCOLOR*`. The field's own darker ground marks it out.
        // Drawing itself, the window paints the field's frame at `l.field`
        // and the `EDIT` is the line of text inside it.
        let (border, field_at) = if theme::custom_drawing() { (0, picker::field_text(l.field, dpi)) } else { (WS_BORDER.0, l.field) };
        let field = child(w!("EDIT"), "", ES_AUTOHSCROLL as u32 | WS_TABSTOP.0 | border, field_at, ID_FIELD);
        let save = match l.save {
            Some(r) => child(w!("BUTTON"), &tr("Save"), BS_DEFPUSHBUTTON as u32 | WS_TABSTOP.0 | WS_DISABLED.0, r, ID_SAVE),
            None => HWND::default(),
        };
        // `LBS_HASSTRINGS` with owner drawing: each row's string is the
        // project's name, which is what a UI Automation client reads.
        // **Made before Cancel**: Tab goes through the controls in the order
        // they were made, and the list is above Cancel on screen.
        let list_style = (LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT) as u32 | WS_VSCROLL.0 | WS_TABSTOP.0;
        let list = child(w!("LISTBOX"), "", list_style, l.list, ID_LIST);
        if theme::custom_drawing() && !list.0.is_null() {
            // The list's scrollbar in the dark theme, as the role library's
            // lists have it; without this it is the system's light one.
            let _ = SetWindowTheme(list, w!("DarkMode_Explorer"), PCWSTR::null());
        }
        let cancel = child(w!("BUTTON"), &tr("Cancel"), BS_PUSHBUTTON as u32 | WS_TABSTOP.0, l.cancel, ID_CANCEL);
        if field.0.is_null() || list.0.is_null() || cancel.0.is_null() {
            let _ = DestroyWindow(hwnd);
            wlogf!(frame, "[project] a control could not be made; {} window not shown", purpose.title());
            return;
        }

        let font = crate::projects_ui::make_font(dpi, 14, FW_NORMAL.0 as i32);
        let font_small = crate::projects_ui::make_font(dpi, 12, FW_NORMAL.0 as i32);
        for h in [field, save, cancel, list] {
            if !h.0.is_null() {
                SendMessageW(h, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
            }
        }
        SendMessageW(list, LB_SETITEMHEIGHT, Some(WPARAM(0)), Some(LPARAM(l.row_h as isize)));
        for h in [field, list, save, cancel] {
            if !h.0.is_null() {
                subclass(h);
            }
        }

        let shown: Vec<usize> = (0..items.len()).collect();
        MODEL.with(|c| *c.borrow_mut() = Some(Model { items, shown, caption }));
        HANDLES.with(|c| {
            c.set(Some(Handles {
                hwnd,
                field,
                list,
                save,
                frame,
                prev,
                font,
                font_small,
                list_brush: CreateSolidBrush(COLORREF(theme::panel())),
                purpose,
            }))
        });
        fill_list();

        let _ = ShowWindow(hwnd, SW_SHOW);
        // The shared contract, not a private copy of it: the terminal's TSF
        // document must be released *before* the field takes focus, or the
        // field cannot compose Chinese and nothing anywhere says why.
        crate::overlay::focus_to_edit(field, "project picker");

        // One self-contained line: "it opened" is compatible with a window
        // that is off-screen or not visible, and each of those looks like a
        // pass. The rectangle is where it really landed.
        let mut got = RECT::default();
        let _ = GetWindowRect(hwnd, &mut got);
        wlogf!(
            frame,
            "[project] {} window shown at {},{} {}x{} visible={} rows={} work={},{} {}x{} dpi={}",
            purpose.title(),
            got.left,
            got.top,
            got.right - got.left,
            got.bottom - got.top,
            IsWindowVisible(hwnd).as_bool() as u8,
            row_count(),
            work.left,
            work.top,
            work.width(),
            work.height(),
            dpi
        );
    }
}

fn pj_scale(v: i32, dpi: i32) -> i32 {
    polter_settings_shell::scale(v, dpi)
}

fn row_count() -> usize {
    MODEL.with(|c| c.borrow().as_ref().map_or(0, |m| m.shown.len()))
}

/// The rows the search leaves, put into the list. With none, the list is
/// hidden and the window says why in its place.
fn fill_list() {
    let Some(h) = handles() else { return };
    let needle = match h.purpose {
        Purpose::Load => field_text(h.field),
        // The name field names a new project; it is not a search.
        Purpose::Save { .. } => String::new(),
    };
    let names: Vec<String> = MODEL.with(|c| {
        let mut b = c.borrow_mut();
        let Some(m) = b.as_mut() else { return Vec::new() };
        m.shown = (0..m.items.len()).filter(|&i| polter_settings_shell::matches(&needle, &m.items[i].name)).collect();
        m.shown.iter().map(|&i| m.items[i].name.clone()).collect()
    });
    unsafe {
        SendMessageW(h.list, WM_SETREDRAW, Some(WPARAM(0)), Some(LPARAM(0)));
        SendMessageW(h.list, LB_RESETCONTENT, Some(WPARAM(0)), Some(LPARAM(0)));
        for n in &names {
            let t = wide(n);
            SendMessageW(h.list, LB_ADDSTRING, Some(WPARAM(0)), Some(LPARAM(t.as_ptr() as isize)));
        }
        SendMessageW(h.list, WM_SETREDRAW, Some(WPARAM(1)), Some(LPARAM(0)));
        // hides without handing the foreground back: what is hidden here is the list, a child window, which is never the foreground window.
        // The picker itself is destroyed, not hidden, has the terminal
        // window as its owner, and `dismiss` hands the foreground back.
        let _ = ShowWindow(h.list, if names.is_empty() { SW_HIDE } else { SW_SHOWNA });
        let _ = InvalidateRect(Some(h.hwnd), None, true);
    }
    wlogf!(h.frame, "[project] picker filter {:?} -> {} row(s)", needle, names.len());
}

fn field_text(field: HWND) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(field, &mut buf) };
    String::from_utf16_lossy(&buf[..n as usize])
}

// ================================================================= closing

/// Take the window down without doing anything, if it is up. Returns what
/// it was.
fn dismiss() -> Option<Handles> {
    let h = HANDLES.with(|c| c.take())?;
    MODEL.with(|c| *c.borrow_mut() = None);
    unsafe {
        let _ = DestroyWindow(h.hwnd);
        for o in [HGDIOBJ(h.font.0), HGDIOBJ(h.font_small.0), HGDIOBJ(h.list_brush.0)] {
            let _ = DeleteObject(o);
        }
    }
    // **Foreground first, then focus**, as `palette::hide` has it: they are
    // different pieces of Windows state.
    crate::overlay::foreground_back(h.hwnd, h.prev, "project picker");
    crate::overlay::focus_back(h.hwnd, h.prev, "project picker");
    Some(h)
}

/// Cancel, Escape, or the title bar's cross.
fn cancel() {
    let Some(h) = dismiss() else { return };
    match h.purpose {
        // A close that waited on this window now does not happen, and this
        // line is the only trace.
        Purpose::Save { close_after: Some(_), .. } => {
            wlogf!(h.frame, "[project] {} cancelled; the tab stays open", h.purpose.title())
        }
        _ => wlogf!(h.frame, "[project] {} cancelled", h.purpose.title()),
    }
}

// ================================================================== acting

/// Row `row` of the list as shown was picked: open it, or -- saving -- save
/// onto it, which asks first.
fn pick(row: usize) {
    let Some(h) = handles() else { return };
    let item = MODEL.with(|c| {
        let b = c.borrow();
        let m = b.as_ref()?;
        m.items.get(*m.shown.get(row)?).cloned()
    });
    let Some(item) = item else {
        // The row came from a click made before the list last changed.
        wlogf!(h.frame, "[project] picker row {row}: no such row now; nothing done");
        return;
    };
    match h.purpose {
        Purpose::Load => load(item),
        Purpose::Save { tab, close_after } => save(h, tab, close_after, &item.name),
    }
}

/// Return in the field, or Save.
fn accept() {
    let Some(h) = handles() else { return };
    match h.purpose {
        Purpose::Load => {
            let selected = usize::try_from(unsafe { SendMessageW(h.list, LB_GETCURSEL, Some(WPARAM(0)), Some(LPARAM(0))) }.0).ok();
            if let Some(row) = picker::enter_target(row_count(), selected) {
                pick(row);
            }
        }
        Purpose::Save { tab, close_after } => {
            let text = field_text(h.field);
            if text.trim().is_empty() {
                // Saving under a name nobody chose is a different request
                // from the one the row makes.
                wlogf!(h.frame, "[project] {} accepted with an empty name; nothing sent", h.purpose.title());
                return;
            }
            save(h, tab, close_after, &text);
        }
    }
}

fn load(item: Item) {
    let Some(h) = dismiss() else { return };
    let frame = h.frame;
    wlogf!(frame, "[project] load {:?} (saved_at={}) -> load_project_into_new_tab …", item.name, item.saved_at);
    let hinst = unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }.map(Into::into).unwrap_or_default();
    match crate::project_ui::load_project_into_new_tab(frame, crate::app_handle(), hinst, &item.path) {
        Ok(()) => wlogf!(frame, "[project] loaded {:?}", item.name),
        Err(e) => {
            // **Said on screen as well as in the log.** The row was picked;
            // a failure that only a log records is, to the person, a click
            // that did nothing.
            wlogf!(frame, "[project] load {:?} failed: {}", item.name, e);
            tell(frame, n_("Load Project"), &format!("{}\n\n{}", tr(n_("The project could not be opened.")), e), MB_ICONINFORMATION);
        }
    }
}

/// Save `tab` under `typed` -- a new name, or a project's, which overwrites
/// it after asking (`projects_ui::save_as_plan`, the mac's `saveAsStep`).
/// **The window stays while the question is up and when it is declined**, as
/// the macOS picker does: nothing was written, and the name is still there
/// to change.
fn save(h: Handles, tab: TabId, close_after: Option<bool>, typed: &str) {
    let frame = h.frame;
    let Some(dir) = project::resolve_state_dir().map(|s| project::default_dir(&s)) else {
        dismiss();
        wlogf!(frame, "[project] save as project {:?} failed: no state directory (neither XDG_STATE_HOME nor LOCALAPPDATA)", typed);
        return;
    };
    // A taken name -- the same name, or the same file whatever the case,
    // after trimming (#983, the mac's nameVerdict) -- is an overwrite: asked
    // first, over this window, and what it replaces is kept (§6.2, #970).
    let Some((name, kind)) = crate::projects_ui::save_as_plan(h.hwnd, &dir, typed) else {
        // not-gated: the condition is the event -- nothing was written, and
        // this line is the only trace.
        wlogf!(frame, "[project] save as project {:?}: declined or empty; nothing written", typed);
        // The question gave the keyboard back to whatever had it, which a
        // click on a row made the list.
        if still_up(h) {
            let _ = unsafe { SetFocus(Some(h.field)) };
        }
        return;
    };
    // The question ran a message loop: the window can have gone meanwhile
    // (its terminal window closed, or the picker was opened again), and then
    // so has the request.
    if !still_up(h) || dismiss().is_none() {
        wlogf!(frame, "[project] save as project {:?}: the window went away while asking; nothing written", typed);
        return;
    }
    let saved = crate::project_ui::write_tab_as(&dir, frame, tab, name, kind);
    match (&saved, close_after) {
        (Ok(()), None) => wlogf!(frame, "[project] saved as project {:?}", typed),
        (Ok(()), Some(whole_window)) => {
            wlogf!(frame, "[project] saved as project {:?}; closing the {}", typed, if whole_window { "window" } else { "tab" });
            if whole_window {
                crate::tabs::close_all_tabs_of(frame);
            } else {
                crate::tabs::close_tab(frame, tab);
            }
        }
        (Err(e), None) => wlogf!(frame, "[project] save as project {:?} failed: {}", typed, e),
        (Err(e), Some(_)) => {
            // **Said on screen, and the tab stays**: the person chose Save so
            // as not to lose what is running in it.
            wlogf!(frame, "[project] save as project {:?} failed: {}; the tab stays open", typed, e);
            tell(frame, n_("Save as Project"), &format!("{}\n\n{}", tr("The project could not be saved."), e), MB_ICONWARNING);
        }
    }
}

/// Whether the window `h` describes is still the one that is up.
fn still_up(h: Handles) -> bool {
    handles().is_some_and(|now| now.hwnd == h.hwnd)
}

fn tell(frame: HWND, title: &str, text: &str, icon: MESSAGEBOX_STYLE) {
    let (title, body) = (wide(&tr(title)), wide(text));
    unsafe {
        MessageBoxW(Some(frame), PCWSTR(body.as_ptr()), PCWSTR(title.as_ptr()), MB_OK | icon);
    }
}

// ================================================================== window

fn register_class() {
    use std::sync::OnceLock;
    static DONE: OnceLock<()> = OnceLock::new();
    if DONE.set(()).is_err() {
        return;
    }
    unsafe {
        let wc = WNDCLASSW {
            lpfnWndProc: Some(picker_proc),
            lpszClassName: w!("PolterProjectPicker"),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            ..Default::default()
        };
        RegisterClassW(&wc);
    }
}

fn subclass(h: HWND) {
    unsafe {
        let prev = SetWindowLongPtrW(h, GWLP_WNDPROC, child_proc as *const () as isize);
        let _ = SetPropW(h, PROP_PREV, Some(HANDLE(prev as *mut c_void)));
    }
}

unsafe extern "system" fn picker_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_PICK => {
                if !ACTING.replace(true) {
                    pick(wp.0);
                    ACTING.set(false);
                }
                LRESULT(0)
            }
            WM_DISMISS | WM_CLOSE => {
                cancel();
                LRESULT(0)
            }
            // Gone without `dismiss` -- the terminal window that owns it was
            // destroyed. `dismiss` takes `HANDLES` before it destroys, so
            // finding this window still there is how the two are told apart.
            WM_NCDESTROY => {
                // not-gated: the condition is the event -- the window went
                // without being dismissed, and this line is the only trace.
                if let Some(h) = handles().filter(|h| h.hwnd == hwnd) {
                    HANDLES.with(|c| c.set(None));
                    MODEL.with(|c| *c.borrow_mut() = None);
                    for o in [HGDIOBJ(h.font.0), HGDIOBJ(h.font_small.0), HGDIOBJ(h.list_brush.0)] {
                        let _ = DeleteObject(o);
                    }
                    wlogf!(h.frame, "[project] {} window destroyed with its owner", h.purpose.title());
                }
                DefWindowProcW(hwnd, msg, wp, lp)
            }
            WM_NOTIFY => {
                let cd = &*(lp.0 as *const NMCUSTOMDRAW);
                if cd.hdr.code == NM_CUSTOMDRAW && theme::custom_drawing() && cd.dwDrawStage == CDDS_PREPAINT {
                    if let Some(h) = handles() {
                        draw_button(cd, h.font);
                        return LRESULT(CDRF_SKIPDEFAULT as isize);
                    }
                }
                DefWindowProcW(hwnd, msg, wp, lp)
            }
            WM_COMMAND => {
                let (id, code) = (wp.0 & 0xFFFF, ((wp.0 >> 16) & 0xFFFF) as u32);
                match (id, code) {
                    (ID_CANCEL, BN_CLICKED) => cancel(),
                    (ID_SAVE, BN_CLICKED) => {
                        if !ACTING.replace(true) {
                            accept();
                            ACTING.set(false);
                        }
                    }
                    (ID_FIELD, EN_CHANGE) => field_changed(),
                    _ => return DefWindowProcW(hwnd, msg, wp, lp),
                }
                LRESULT(0)
            }
            // Back from another window: the keyboard goes to the field, and
            // the terminal's TSF document is released again on the way.
            WM_ACTIVATE if (wp.0 & 0xFFFF) as u32 != WA_INACTIVE => {
                if let Some(h) = handles().filter(|h| h.hwnd == hwnd) {
                    crate::overlay::focus_to_edit(h.field, "project picker");
                }
                LRESULT(0)
            }
            // The field and the list are native controls: they ask what
            // colours to use and honour the answer. Under high contrast
            // these fall through and the system's colours stand.
            WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC => match theme::ctl_color(HDC(wp.0 as *mut c_void)) {
                Some(b) => LRESULT(b.0 as isize),
                None => DefWindowProcW(hwnd, msg, wp, lp),
            },
            WM_CTLCOLORLISTBOX => match handles().filter(|_| theme::custom_drawing()) {
                Some(h) => LRESULT(h.list_brush.0 as isize),
                None => DefWindowProcW(hwnd, msg, wp, lp),
            },
            WM_DRAWITEM if wp.0 == ID_LIST => {
                draw_row(&*(lp.0 as *const DRAWITEMSTRUCT));
                LRESULT(1)
            }
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                theme::repaint_all(hwnd);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint(hwnd);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// The field changed: the search narrows the list; the name decides whether
/// there is anything to save.
fn field_changed() {
    let Some(h) = handles() else { return };
    match h.purpose {
        Purpose::Load => fill_list(),
        Purpose::Save { .. } => {
            let named = !field_text(h.field).trim().is_empty();
            let _ = unsafe { EnableWindow(h.save, named) };
        }
    }
}

/// The field, the list and the buttons. **An `EDIT` eats Return and Escape
/// and tells nobody**, which is why this subclass exists; the list is here
/// so a click counts when the button comes up, once, rather than at every
/// row the pointer crosses on the way; and all of them are here for Tab,
/// which nothing moves in a window that is not a dialog.
unsafe extern "system" fn child_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetPropW(hwnd, PROP_PREV).0 as isize;
        let call_prev = || {
            let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = std::mem::transmute(prev);
            f(hwnd, msg, wp, lp)
        };
        let Some(h) = handles() else { return call_prev() };
        let (is_field, is_list) = (hwnd == h.field, hwnd == h.list);
        match msg {
            WM_KEYDOWN => {
                let vk = wp.0 as u16;
                if vk == VK_ESCAPE.0 {
                    let _ = PostMessageW(Some(h.hwnd), WM_DISMISS, WPARAM(0), LPARAM(0));
                    return LRESULT(0);
                }
                if vk == VK_TAB.0 {
                    let back = (GetKeyState(VK_SHIFT.0 as i32) as u16 & 0x8000) != 0;
                    if let Ok(next) = GetNextDlgTabItem(h.hwnd, Some(hwnd), back) {
                        let _ = SetFocus(Some(next));
                    }
                    return LRESULT(0);
                }
                if vk == VK_RETURN.0 {
                    if is_list {
                        post_selected(h);
                    } else if is_field {
                        if !ACTING.replace(true) {
                            accept();
                            ACTING.set(false);
                        }
                    } else {
                        // A button: Return presses it, as Space does.
                        let _ = PostMessageW(Some(hwnd), BM_CLICK, WPARAM(0), LPARAM(0));
                    }
                    return LRESULT(0);
                }
                // ↑ and ↓ in the search move the highlight in the list, so
                // a project can be found and opened without the mouse.
                if is_field && matches!(h.purpose, Purpose::Load) && (vk == VK_UP.0 || vk == VK_DOWN.0) {
                    let selected = usize::try_from(SendMessageW(h.list, LB_GETCURSEL, Some(WPARAM(0)), Some(LPARAM(0))).0).ok();
                    if let Some(to) = picker::step(selected, row_count(), vk == VK_DOWN.0) {
                        SendMessageW(h.list, LB_SETCURSEL, Some(WPARAM(to)), Some(LPARAM(0)));
                    }
                    return LRESULT(0);
                }
                call_prev()
            }
            // The characters Return, Escape and Tab leave behind: an `EDIT`
            // that is given them beeps.
            WM_CHAR if is_field && (wp.0 == 0x0d || wp.0 == 0x1b || wp.0 == 0x09) => LRESULT(0),
            WM_LBUTTONUP if is_list => {
                let r = call_prev();
                // Only a release over the highlighted row: one that ends
                // under the last row, or outside the list after a drag,
                // picks nothing.
                let (x, y) = ((lp.0 & 0xFFFF) as i16 as i32, ((lp.0 >> 16) & 0xFFFF) as i16 as i32);
                let row = SendMessageW(hwnd, LB_GETCURSEL, Some(WPARAM(0)), Some(LPARAM(0))).0;
                let mut rc = RECT::default();
                if row >= 0 {
                    SendMessageW(hwnd, LB_GETITEMRECT, Some(WPARAM(row as usize)), Some(LPARAM(&mut rc as *mut RECT as isize)));
                }
                if row >= 0 && x >= rc.left && x < rc.right && y >= rc.top && y < rc.bottom {
                    post_selected(h);
                }
                r
            }
            // The empty field says what it is for. Painted here rather than
            // set with `EM_SETCUEBANNER`, for the reason `settings_win.rs`
            // gives: on the test machine's English session the cue did not
            // show (#896).
            WM_PAINT if is_field => {
                let r = call_prev();
                if GetWindowTextLengthW(hwnd) == 0 {
                    paint_placeholder(h);
                }
                r
            }
            WM_NCDESTROY => {
                let r = call_prev();
                let _ = RemovePropW(hwnd, PROP_PREV);
                r
            }
            _ => call_prev(),
        }
    }
}

/// Post the list's highlighted row as picked, when it has one.
fn post_selected(h: Handles) {
    let row = unsafe { SendMessageW(h.list, LB_GETCURSEL, Some(WPARAM(0)), Some(LPARAM(0))) }.0;
    if let Ok(row) = usize::try_from(row) {
        let _ = unsafe { PostMessageW(Some(h.hwnd), WM_PICK, WPARAM(row), LPARAM(0)) };
    }
}

// ================================================================= drawing

fn fill(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

fn frame_rect(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        FrameRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

/// Save and Cancel, from their custom-draw notification: the plain button
/// `roles_ui::draw_button` draws, in the same states.
fn draw_button(cd: &NMCUSTOMDRAW, font: HFONT) {
    let has = |f| cd.uItemState.contains(f);
    let (hot, down, disabled, focus) = (has(CDIS_HOT), has(CDIS_SELECTED), has(CDIS_DISABLED), has(CDIS_FOCUS));
    let label = field_text(cd.hdr.hwndFrom);
    let mut rc = cd.rc;
    let face = if disabled {
        theme::btn_face()
    } else if down {
        theme::btn_down()
    } else if hot {
        theme::btn_hot()
    } else {
        theme::btn_face()
    };
    fill(cd.hdc, &rc, face);
    frame_rect(cd.hdc, &rc, theme::border());
    if focus && !disabled {
        frame_rect(cd.hdc, &RECT { left: rc.left + 3, top: rc.top + 3, right: rc.right - 3, bottom: rc.bottom - 3 }, theme::focus());
    }
    if down {
        rc.top += 1;
        rc.left += 1;
    }
    let fg = if disabled { theme::dim() } else { theme::btn_text() };
    draw_text(cd.hdc, &label, &rc, font, fg, DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
}

fn draw_text(hdc: HDC, s: &str, r: &RECT, font: HFONT, colour: u32, flags: DRAW_TEXT_FORMAT) {
    let mut t: Vec<u16> = s.encode_utf16().collect();
    let mut r = *r;
    unsafe {
        let old = SelectObject(hdc, HGDIOBJ(font.0));
        SetTextColor(hdc, COLORREF(colour));
        SetBkMode(hdc, TRANSPARENT);
        DrawTextW(hdc, &mut t, &mut r, flags | DT_NOPREFIX);
        SelectObject(hdc, old);
    }
}

fn paint_placeholder(h: Handles) {
    let text = match h.purpose {
        Purpose::Load => tr("Search"),
        Purpose::Save { .. } => tr("New Project Name"),
    };
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(h.field, &mut rc);
        let dc = GetDC(Some(h.field));
        draw_text(dc, &text, &rc, h.font, theme::dim(), DT_LEFT | DT_SINGLELINE | DT_TOP);
        ReleaseDC(Some(h.field), dc);
    }
}

/// One row: the project's name over when it was saved and how big it is --
/// the line the settings window's list shows for it.
fn draw_row(d: &DRAWITEMSTRUCT) {
    let Some(h) = handles() else { return };
    let item = MODEL.with(|c| {
        let b = c.borrow();
        let m = b.as_ref()?;
        m.items.get(*m.shown.get(d.itemID as usize)?).cloned()
    });
    let Some(item) = item else { return };
    let dpi = (unsafe { GetDpiForWindow(h.hwnd) } as i32).max(96);
    let s = |v: i32| pj_scale(v, dpi);
    let r = d.rcItem;
    let on = (d.itemState.0 & ODS_SELECTED.0) != 0;
    // The list's ground is the panel colour, as the settings window's lists
    // are: `theme::sel()` is the same value as `theme::float_bg()`, so a
    // highlighted row on that ground could not be told from the others.
    fill(d.hDC, &r, theme::panel());
    let (fg, dim) = if on {
        fill(d.hDC, &RECT { left: r.left + s(6), right: r.right - s(6), ..r }, theme::sel());
        (theme::sel_text(), theme::sel_text())
    } else {
        (theme::text(), theme::dim())
    };
    let (left, right) = (r.left + s(polter_settings_shell::grid::PAD), r.right - s(polter_settings_shell::grid::PAD));
    let name = RECT { left, top: r.top + s(4), right, bottom: r.top + s(24) };
    draw_text(d.hDC, &item.name, &name, h.font, fg, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    let sub = RECT { left, top: r.top + s(23), right, bottom: r.bottom - s(3) };
    let line = format!(
        "{} \u{b7} {}",
        pj::format_time(item.saved_at, crate::projects_ui::local_offset()),
        crate::projects_ui::size_text(item.panes)
    );
    draw_text(d.hDC, &line, &sub, h.font_small, dim, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
}

fn paint(hwnd: HWND) {
    // Everything is read out first; nothing below borrows.
    let h = handles().filter(|h| h.hwnd == hwnd);
    let (caption, empty, none_shown) = MODEL.with(|c| {
        let b = c.borrow();
        b.as_ref().map_or((None, true, true), |m| (m.caption.clone(), m.items.is_empty(), m.shown.is_empty()))
    });
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(hwnd, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        fill(hdc, &rc, theme::bg());
        if let Some(h) = h {
            let dpi = (GetDpiForWindow(hwnd) as i32).max(96);
            let l = picker::layout(h.purpose.mode(), rc.right, rc.bottom, dpi);
            // The field's frame, from the rectangle the `EDIT` was placed
            // inside. Only when this window draws: under high contrast the
            // field has `WS_BORDER` and draws its own.
            if theme::custom_drawing() {
                fill(hdc, &rect(l.field), theme::field_bg());
                frame_rect(hdc, &rect(l.field), theme::border());
            }
            if let (Some(r), Some(text)) = (l.caption, caption.as_ref()) {
                draw_text(hdc, text, &rect(r), h.font_small, theme::dim(), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            }
            // Never a blank list: it says whether there are no projects or
            // none the search leaves.
            fill(hdc, &rect(l.list), theme::panel());
            if none_shown {
                let text = if empty { tr("No Saved Projects") } else { tr("No matching projects") };
                draw_text(hdc, &text, &rect(l.list), h.font, theme::dim(), DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            }
            fill(hdc, &rect(l.rule_top), theme::border());
            fill(hdc, &rect(l.rule_bottom), theme::border());
        }
        let _ = EndPaint(hwnd, &ps);
    }
}
