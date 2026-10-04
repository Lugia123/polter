//! The projects section of the settings window (`dev-docs/poltergeist/
//! settings.md` §6): every saved project on the left, the one selected on the
//! right, and what can be done to it -- open, rename, copy, overwrite with the
//! current tab, delete (with Undo), go back to the previous version, show it
//! in Explorer.
//!
//! **Every rule is `polter_settings_shell::projects`'s**: where each thing
//! goes, which names clash, what a copy is called, how long Undo lasts, which
//! version is which, what moving a project on disk takes with it. That crate's
//! tests run on the Mac; this one's only on the Windows machine. What is here
//! is Win32 asking those functions and doing what they say, and `project.rs`
//! reading and writing the format.
//!
//! **A project here is a tab**, as it is everywhere on both hosts: "Overwrite"
//! takes the current tab of the terminal window the settings window was opened
//! from (the group's ruling on §6.2), and "+" saves that tab as a new project
//! through the same box the menu row opens.
//!
//! **Windows has no autosave and no binding of a tab to a project**, so the
//! detail says "not bound" and a rename has no binding to carry along
//! (§6.1/§6.2, as ruled for this host).
//!
//! ⚠️ **Nothing here dispatches a message while `ST` is borrowed**
//! (`windows/tools/borrow-across-dispatch.py`): every block that borrows
//! computes and returns, and the Win32 calls come after.

use std::cell::RefCell;
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicPtr, Ordering};

use polter_settings_shell::projects::{self as pj, NameVerdict, Named, SaveAsStep, Stash, Undo};
use polter_settings_shell::{grid, scale, section_grid, Rect as SRect};
use windows::core::{s, w, BOOL, HRESULT, PCWSTR};
use windows::Win32::Foundation::{GetLastError, COLORREF, ERROR_CLASS_ALREADY_EXISTS, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW};
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::project::{self, Snapshot};
use crate::theme;

const ID_NEW: u16 = 200;
const ID_DUP: u16 = 201;
const ID_DEL: u16 = 202;
const ID_RENAME: u16 = 211;
const ID_RESTORE0: u16 = 220;
const ID_UNDO: u16 = 230;
const ID_REVEAL: u16 = 240;
const ID_OVERWRITE: u16 = 241;
const ID_OPEN: u16 = 242;

const PROP_PREV: PCWSTR = w!("PolterProjectsPrevProc");

static MAIN: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_BOLD: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_SMALL: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// The controls, made once with the window.
#[derive(Clone, Copy, Default)]
struct Controls {
    list_buttons: [HWND; 3],
    rename: HWND,
    restore: [HWND; 2],
    undo: HWND,
    actions: [HWND; 3],
}

/// One saved project, as the list shows it.
#[derive(Clone, Debug)]
struct Item {
    name: String,
    saved_at: i64,
    panes: usize,
    /// **The project's identity**, the file the listing found it in
    /// (`project::Entry::path`), never a path recomputed from its name.
    path: PathBuf,
}

/// The selected project, read whole.
#[derive(Clone, Debug)]
struct Detail {
    snap: Snapshot,
    prev: Option<Snapshot>,
    bytes: u64,
}

struct State {
    dir: Option<PathBuf>,
    items: Vec<Item>,
    selected: Option<PathBuf>,
    /// The one selected when the window last closed (§3.1: an empty route
    /// opens "the last one selected, else the first").
    remembered: Option<PathBuf>,
    filter: String,
    list_top: usize,
    detail: Option<Detail>,
    undo: Undo<Stash>,
    /// What the last operation said, in the band; `true` for a failure.
    status: Option<(String, bool)>,
    /// The window the settings window was opened from. See the header.
    origin: HWND,
    /// Whether the leftovers of an earlier process's Undo have been purged.
    purged: bool,
}

impl State {
    /// The directory the banner's Undo would move back from.
    fn undo_held(&self) -> Option<PathBuf> {
        self.undo.peek().map(|s| s.held.clone())
    }
}

thread_local! {
    static ST: RefCell<State> = RefCell::new(State {
        dir: None,
        items: Vec::new(),
        selected: None,
        remembered: None,
        filter: String::new(),
        list_top: 0,
        detail: None,
        undo: Undo::default(),
        status: None,
        origin: HWND(std::ptr::null_mut()),
        purged: false,
    });
    static CTL: std::cell::Cell<Option<Controls>> = const { std::cell::Cell::new(None) };
}

fn main_hwnd() -> HWND {
    HWND(MAIN.load(Ordering::Acquire))
}

fn dpi_of(h: HWND) -> i32 {
    unsafe { GetDpiForWindow(h) }.max(96) as i32
}

fn ctl() -> Option<Controls> {
    CTL.with(|c| c.get())
}

fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
    ST.with(|c| f(&mut c.borrow_mut()))
}

fn rect(r: SRect) -> RECT {
    RECT { left: r.left, top: r.top, right: r.right, bottom: r.bottom }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

// ============================================================== the listing

/// Read the projects again, keeping the selection when it still exists.
fn reload() {
    let dir = project::resolve_state_dir().map(|s| project::default_dir(&s));
    let mut items = Vec::new();
    if let Some(d) = &dir {
        let listing = project::list(d);
        for (path, why) in &listing.skipped {
            // process-wide: the settings window's project list, one per process
            crate::plogf!("[projects-ui] list left out {:?}: {}", path, why);
        }
        for e in listing.entries {
            let panes = project::read_file(&e.path)
                .ok()
                .and_then(|s| s.root.as_ref().map(crate::project_ui::leaf_count))
                .unwrap_or(0);
            items.push(Item { name: e.name, saved_at: e.saved_at, panes, path: e.path });
        }
    }
    // Newest first, as the load list and macOS order them.
    items.sort_by(|a, b| b.saved_at.cmp(&a.saved_at).then_with(|| a.name.cmp(&b.name)));
    let first_time = with(|s| {
        s.dir = dir.clone();
        s.items = items;
        if s.selected.as_ref().is_some_and(|p| !s.items.iter().any(|i| &i.path == p)) {
            s.selected = None;
        }
        !std::mem::replace(&mut s.purged, true)
    });
    if first_time {
        sweep_leftovers();
    }
    load_detail();
}

/// Send whatever waits in `.deleted` to the Recycle Bin, but the one the
/// banner still holds (`pj::leftovers`): a process that ended with the banner
/// up left it there. **Called at startup** (`settings_win::init`) and the
/// first time the list is read.
pub fn sweep_leftovers() {
    let Some(dir) = project::resolve_state_dir().map(|s| project::default_dir(&s)) else { return };
    let held = with(|s| s.undo_held());
    let found = pj::leftovers(&pj::trash_dir(&dir), held.as_deref());
    for p in &found {
        let ok = recycle(p);
        // process-wide: the projects directory is one per process
        crate::plogf!("[projects-ui] left over from an earlier delete: {:?} -> Recycle Bin ok={ok}", p);
    }
}

/// Send a stashed project's directory to the Recycle Bin (§6.2): undoable
/// from there by the person, silently, with no question -- the question was
/// asked when it was deleted. `true` when it is gone from where it was.
///
/// ⚠️ **Not `remove_dir_all` when this fails**: a project that cannot be
/// recycled stays in `.deleted` and is tried again at the next start, rather
/// than deleted past the Recycle Bin.
fn recycle(dir: &Path) -> bool {
    use std::os::windows::ffi::OsStrExt;
    use windows::Win32::UI::Shell::{SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW};
    // A list of paths, each ended by a nul and the whole by another.
    let from: Vec<u16> = dir.as_os_str().encode_wide().chain([0, 0]).collect();
    let mut op = SHFILEOPSTRUCTW {
        wFunc: FO_DELETE,
        pFrom: PCWSTR(from.as_ptr()),
        fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI).0 as u16,
        ..Default::default()
    };
    let r = unsafe { SHFileOperationW(&mut op) };
    let ok = r == 0 && !op.fAnyOperationsAborted.as_bool() && !dir.exists();
    if !ok {
        // process-wide: as above
        crate::plogf!("[projects-ui] SHFileOperationW({:?}) = {r:#x}, aborted={}; left in .deleted", dir, op.fAnyOperationsAborted.as_bool());
    }
    ok
}

/// Read the selected project whole, for the right-hand side.
fn load_detail() {
    let sel = with(|s| s.selected.clone());
    let detail = sel.and_then(|path| {
        let snap = project::read_file(&path).ok()?;
        let prev = project::read_file(&pj::prev_path(&path)).ok();
        let bytes = pj::scrollback_bytes(&path);
        Some(Detail { snap, prev, bytes })
    });
    with(|s| s.detail = detail);
}

/// The items the search leaves, with their index in `items`.
fn shown(s: &State) -> Vec<usize> {
    (0..s.items.len()).filter(|&i| polter_settings_shell::matches(&s.filter, &s.items[i].name)).collect()
}

fn selected_item(s: &State) -> Option<Item> {
    let p = s.selected.as_ref()?;
    s.items.iter().find(|i| &i.path == p).cloned()
}

/// Select `path`, or nothing.
fn select(path: Option<PathBuf>) {
    with(|s| {
        s.selected = path;
        s.status = None;
    });
    load_detail();
    keep_selection_visible();
    refresh();
    crate::settings_win::crumb_changed();
}

// ============================================ what the settings window asks

/// Show the section in `rect` of `host`. `item` is the route's project name
/// (§3.1): that project; else the last one selected; else -- Windows binds
/// no tab to a project -- the first.
pub fn show(host: HWND, r: RECT, origin: HWND, item: Option<&str>) {
    if !main_hwnd().0.is_null() && !unsafe { IsWindow(Some(main_hwnd())) }.as_bool() {
        MAIN.store(std::ptr::null_mut(), Ordering::Release);
        CTL.with(|c| c.set(None));
    }
    if main_hwnd().0.is_null() && !create(host) {
        return;
    }
    with(|s| s.origin = origin);
    reload();
    let pick = with(|s| {
        let by_name = item.and_then(|n| {
            s.items
                .iter()
                .find(|i| i.name == n)
                .or_else(|| s.items.iter().find(|i| i.name.to_lowercase() == n.to_lowercase()))
                .map(|i| i.path.clone())
        });
        let unknown = item.is_some() && by_name.is_none();
        let kept = s.selected.clone().or_else(|| s.remembered.clone()).filter(|p| s.items.iter().any(|i| &i.path == p));
        (by_name.or(kept).or_else(|| s.items.first().map(|i| i.path.clone())), unknown)
    });
    let win = main_hwnd();
    unsafe {
        let _ = SetWindowPos(win, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
    select(pick.0);
    let n = with(|s| s.items.len());
    // process-wide: the projects section of the one settings window
    crate::plogf!("[projects-ui] shown: {} project(s), item={:?} unknown={}", n, item, pick.1);
}

pub fn hide() {
    let win = main_hwnd();
    if !win.0.is_null() {
        // hides without handing the foreground back: a child window, which
        // cannot be the foreground; the settings window does the handback
        let _ = unsafe { ShowWindow(win, SW_HIDE) };
    }
}

/// The settings window closed: Undo ends here (§6.2), and the selection is
/// remembered for the next opening.
pub fn closed() {
    let stash = with(|s| {
        s.remembered = s.selected.clone().or(s.remembered.take());
        s.status = None;
        s.undo.closed()
    });
    if let Some(st) = stash {
        let ok = recycle(&st.held);
        // process-wide: as above
        crate::plogf!("[projects-ui] window closed: {:?} -> Recycle Bin ok={ok}", st.file);
    }
}

pub fn move_to(r: RECT) {
    let win = main_hwnd();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return;
    }
    unsafe {
        let _ = SetWindowPos(win, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
    }
    refresh();
}

/// The settings window became active: a project may have been saved from a
/// terminal meanwhile ("+" opens the box there), so the list is read again.
pub fn activated() {
    let win = main_hwnd();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return;
    }
    reload();
    refresh();
}

pub fn dpi_changed() {
    let win = main_hwnd();
    if win.0.is_null() {
        return;
    }
    make_fonts(dpi_of(win));
    crate::roles_ui::ensure_fonts(dpi_of(win));
    refresh();
}

/// The selected project's name, for the breadcrumb and the route.
pub fn current() -> Option<String> {
    let win = main_hwnd();
    if win.0.is_null() {
        return None;
    }
    with(|s| selected_item(s).map(|i| i.name))
}

/// Every project's name, for the sidebar's search (§2.3).
pub fn names() -> Vec<String> {
    if main_hwnd().0.is_null() {
        let dir = project::resolve_state_dir().map(|s| project::default_dir(&s));
        return dir.map(|d| project::list(&d).entries.into_iter().map(|e| e.name).collect()).unwrap_or_default();
    }
    with(|s| s.items.iter().map(|i| i.name.clone()).collect())
}

pub fn set_filter(q: &str) {
    with(|s| {
        s.filter = q.to_string();
        s.list_top = 0;
    });
    if !main_hwnd().0.is_null() {
        refresh();
    }
}

fn filter_state() -> polter_settings_shell::Filtered {
    with(|s| {
        let v = shown(s);
        let sel = s.selected.as_ref().map(|p| v.iter().any(|&i| &s.items[i].path == p));
        polter_settings_shell::filtered(&s.filter, v.len(), sel)
    })
}

/// §2.3a: the selected project is one the search hid.
pub fn selection_hidden() -> bool {
    filter_state().selection_hidden
}

/// §2.3a's readings for this section, as the roles section logs its own.
pub fn log_grid() {
    let win = main_hwnd();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return;
    }
    let (g, a, ll, e, _) = geometry();
    // process-wide: as above
    crate::plogf!(
        "[projects-ui] grid: list divider col {} (rows {}..{}), bottom rule row {}, + at x {}, row text x {}, \
         actions {}..{} / {}..{} / {}..{} on rows {}..{}, editor margin x {}, control column x {}",
        g.list_divider.map_or(-1, |d| d.left),
        g.list_divider.map_or(-1, |d| d.top),
        g.list_divider.map_or(-1, |d| d.bottom - 1),
        g.bottom_rule.top,
        g.list_buttons.map_or(-1, |b| b[0].left),
        ll.text_left,
        a[0].left,
        a[0].right - 1,
        a[1].left,
        a[1].right - 1,
        a[2].left,
        a[2].right - 1,
        a[0].top,
        a[0].bottom - 1,
        e.margin,
        e.control_left
    );
}

// ================================================================ geometry

fn geometry() -> (polter_settings_shell::SectionGrid, [SRect; 3], pj::ListLayout, pj::EditorLayout, i32) {
    let win = main_hwnd();
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let dpi = dpi_of(win);
    let g = section_grid(rc.right, rc.bottom, dpi, true);
    let a = pj::actions(&g, rc.right, dpi);
    let banner = with(|s| s.undo.banner().is_some());
    let ll = pj::list_layout(g.list.unwrap_or_default(), dpi, banner);
    let e = pj::editor_layout(g.editor, dpi);
    (g, a, ll, e, dpi)
}

fn keep_selection_visible() {
    if main_hwnd().0.is_null() {
        return;
    }
    let (g, _, ll, _, _) = geometry();
    let fit = pj::rows_fitting(&ll, g.list.map_or(0, |l| l.bottom));
    with(|s| {
        let v = shown(s);
        if let Some(i) = s.selected.as_ref().and_then(|p| v.iter().position(|&k| &s.items[k].path == p)) {
            s.list_top = polter_settings_shell::keep_visible(s.list_top, i, fit);
        }
        s.list_top = s.list_top.min(v.len().saturating_sub(1));
    });
}

// ============================================================ the controls

fn place(h: HWND, r: SRect, show: bool, enabled: bool) {
    if h.0.is_null() {
        return;
    }
    // Off the keyboard before it is hidden or greyed (task 1010).
    if !show {
        crate::settings_win::keep_keyboard_off(h);
    }
    unsafe {
        let _ = SetWindowPos(
            h,
            None,
            r.left,
            r.top,
            r.width(),
            r.height(),
            SWP_NOZORDER | SWP_NOACTIVATE | if show { SWP_SHOWWINDOW } else { SWP_HIDEWINDOW },
        );
    }
    crate::settings_win::enable(h, enabled);
}

/// Which way the tab "Overwrite" and "+" would take goes: the terminal
/// window the settings window was opened from, else whichever is in front;
/// `None` with no terminal window at all.
fn terminal_frame() -> Option<HWND> {
    let origin = with(|s| s.origin);
    let f = crate::winid::frame_of_window(origin).unwrap_or_else(crate::tabs::overlay_frame);
    (!f.0.is_null()).then_some(f)
}

/// The tab in front of that window: its identity and the name it shows.
fn current_tab() -> Option<(HWND, crate::tabs::TabId, String)> {
    let frame = terminal_frame()?;
    let (tabs, active) = crate::tabs::strip_snapshot(frame);
    tabs.get(active).map(|(id, title)| (frame, *id, title.clone()))
}

/// Move every control where the grid says, shown and enabled as the state
/// says, and repaint.
fn refresh() {
    let win = main_hwnd();
    let Some(c) = ctl() else { return };
    if win.0.is_null() {
        return;
    }
    let (g, a, ll, e, _) = geometry();
    let (has_sel, versions, banner) = with(|s| {
        let v = s
            .detail
            .as_ref()
            .map(|d| {
                pj::versions(
                    Some((d.snap.saved_at, d.snap.root.as_ref().map(crate::project_ui::leaf_count).unwrap_or(0))),
                    d.prev.as_ref().map(|p| (p.saved_at, p.root.as_ref().map(crate::project_ui::leaf_count).unwrap_or(0))),
                )
            })
            .unwrap_or_default();
        (s.detail.is_some(), v, s.undo.banner().is_some())
    });
    let tab = current_tab().is_some();
    if let Some(b) = g.list_buttons {
        place(c.list_buttons[0], b[0], true, tab);
        place(c.list_buttons[1], b[1], true, has_sel);
        place(c.list_buttons[2], b[2], true, has_sel);
    }
    place(c.undo, ll.undo.unwrap_or_default(), banner, banner);
    place(c.rename, e.rename, has_sel, has_sel);
    for i in 0..2 {
        let restorable = versions.get(i).is_some_and(|v| !v.current);
        place(c.restore[i], e.restore[i], has_sel && restorable, restorable);
    }
    place(c.actions[0], a[0], true, has_sel);
    place(c.actions[1], a[1], true, has_sel && tab);
    place(c.actions[2], a[2], true, has_sel);
    let _ = unsafe { InvalidateRect(Some(win), None, false) };
}

// ================================================================ asking

/// `TaskDialogIndirect`, looked up rather than imported, for the reason
/// `roles_ui::task_dialog_indirect` gives: a static import of a comctl32 v6
/// entry point stops the program starting where v6 is not selected.
type TaskDialogIndirectFn = unsafe extern "system" fn(*const TASKDIALOGCONFIG, *mut i32, *mut i32, *mut BOOL) -> HRESULT;

fn task_dialog_indirect() -> Option<TaskDialogIndirectFn> {
    unsafe {
        let m = LoadLibraryW(w!("comctl32.dll")).ok()?;
        let p = GetProcAddress(m, s!("TaskDialogIndirect"))?;
        Some(std::mem::transmute::<unsafe extern "system" fn() -> isize, TaskDialogIndirectFn>(p))
    }
}

/// Ask a question whose answers are `buttons` (named, as the macOS alerts
/// name theirs), **the last of them the one that does nothing**. Returns the
/// index pressed, `None` when the dialog could not be shown or went away.
/// Owned by `owner`; the keyboard goes back to whoever had it (#896 W35).
pub(crate) fn ask(owner: HWND, tag: &str, main: &str, body: &str, buttons: &[String]) -> Option<usize> {
    let before = unsafe { GetFocus() };
    let (m, b, title) = (wide(main), wide(body), wide(&tr("Polter")));
    let labels: Vec<Vec<u16>> = buttons.iter().map(|l| wide(l)).collect();
    crate::plogf!("{tag} asking: {main}");
    let mut pressed = None;
    let mut shown = false;
    if let Some(tdi) = task_dialog_indirect() {
        let specs: Vec<TASKDIALOG_BUTTON> = labels
            .iter()
            .enumerate()
            .map(|(i, l)| TASKDIALOG_BUTTON { nButtonID: 100 + i as i32, pszButtonText: PCWSTR(l.as_ptr()) })
            .collect();
        let cfg = TASKDIALOGCONFIG {
            cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
            hwndParent: owner,
            dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW,
            pszWindowTitle: PCWSTR(title.as_ptr()),
            pszMainInstruction: PCWSTR(m.as_ptr()),
            pszContent: PCWSTR(b.as_ptr()),
            cButtons: specs.len() as u32,
            pButtons: specs.as_ptr(),
            nDefaultButton: 100,
            ..Default::default()
        };
        let mut id = 0i32;
        let hr = unsafe { tdi(&cfg, &mut id, std::ptr::null_mut(), std::ptr::null_mut()) };
        if hr.is_ok() {
            shown = true;
            // Escape and the title bar's cross answer IDCANCEL: the last
            // button, the one that does nothing.
            pressed = if id == IDCANCEL.0 { Some(buttons.len() - 1) } else { usize::try_from(id - 100).ok() };
        } else {
            crate::plogf!("{tag} TaskDialogIndirect failed ({hr:?}); asking with a message box");
        }
    }
    if !shown {
        // Two answers at most in a message box: the first, or nothing.
        let text = wide(&format!("{main}\n\n{body}"));
        let r = unsafe { MessageBoxW(Some(owner), PCWSTR(text.as_ptr()), PCWSTR(title.as_ptr()), MB_OKCANCEL | MB_ICONWARNING) };
        pressed = Some(if r == IDOK { 0 } else { buttons.len() - 1 });
    }
    crate::plogf!("{tag} answered {:?}", pressed.and_then(|i| buttons.get(i)));
    let usable = !before.0.is_null() && unsafe { IsWindow(Some(before)) }.as_bool();
    let to = HWND(polter_settings_shell::focus_after_question(before.0 as isize, usable, owner.0 as isize) as *mut c_void);
    if !to.0.is_null() {
        let _ = unsafe { SetFocus(Some(to)) };
    }
    pressed
}

fn owner() -> HWND {
    unsafe { GetAncestor(main_hwnd(), GA_ROOT) }
}

/// "Save as a Project Before Closing?" (settings.md §6.3), over the terminal
/// window whose tab is closing -- the words and the buttons macOS has
/// (`ProjectSaveBeforeClose.swift`). What the answer means is
/// `polter_settings_shell::projects::close_choice`: only the button that
/// says so closes.
pub(crate) fn ask_save_before_close(frame: HWND) -> pj::CloseChoice {
    let labels: Vec<String> = pj::CLOSE_BUTTONS
        .iter()
        .map(|c| match c {
            pj::CloseChoice::Save => tr("Save as Project…"),
            pj::CloseChoice::CloseWithoutSaving => tr("Close Without Saving"),
            pj::CloseChoice::KeepOpen => tr("Cancel"),
        })
        .collect();
    let pressed = ask(
        frame,
        "[close]",
        &tr("Save as a Project Before Closing?"),
        &tr("The terminal still has a running process. Closing it without saving as a project will kill it."),
        &labels,
    );
    pj::close_choice(pressed)
}

/// "Save as Project" onto a name that already has a project (§6.2, #970):
/// the same question macOS asks (`ProjectPickerView`, "Overwrite Project?"),
/// with the same promise -- the replaced version is kept, and it is
/// (`WriteKind::Overwrite`). `existing` is the project there, `None` when its
/// file does not read. True to overwrite.
pub(crate) fn confirm_save_as_overwrite(owner: HWND, name: &str, existing: Option<&Snapshot>) -> bool {
    let (panes, saved) = match existing {
        Some(s) => (s.root.as_ref().map(crate::project_ui::leaf_count).unwrap_or(0).to_string(), pj::format_time(s.saved_at, local_offset())),
        None => ("?".to_string(), "?".to_string()),
    };
    let body = tr("\"{}\" already has {} pane(s), saved {}. The replaced version is kept as the previous version.")
        .replacen("{}", name, 1)
        .replacen("{}", &panes, 1)
        .replacen("{}", &saved, 1);
    ask(owner, "[prompt]", &tr("Overwrite Project?"), &body, &[tr("Overwrite"), tr("Cancel")]) == Some(0)
}

/// "Do it / Cancel", true for the first.
fn confirm(main: &str, body: &str, verb: &str) -> bool {
    ask(owner(), "[projects-ui]", main, body, &[verb.to_string(), tr("Cancel")]) == Some(0)
}

fn say(text: String, failed: bool) {
    // process-wide: as above
    crate::plogf!("[projects-ui] {} {}", if failed { "failed:" } else { "said:" }, text);
    with(|s| s.status = Some((text, failed)));
    let win = main_hwnd();
    if !win.0.is_null() {
        let _ = unsafe { InvalidateRect(Some(win), None, false) };
    }
}

// ============================================================ doing things

fn dir_and_selected() -> Option<(PathBuf, Item)> {
    with(|s| Some((s.dir.clone()?, selected_item(s)?)))
}

fn open_selected() {
    let Some((_, item)) = dir_and_selected() else { return };
    let Some(frame) = terminal_frame() else {
        say(tr("There is no terminal window to open the project in."), true);
        return;
    };
    let hinst = unsafe { GetModuleHandleW(None) }.map(Into::into).unwrap_or_default();
    // process-wide: as above
    crate::plogf!("[projects-ui] open {:?} from {:?} -> load_project_into_new_tab", item.name, item.path);
    match crate::project_ui::load_project_into_new_tab(frame, crate::app_handle(), hinst, &item.path) {
        Ok(()) => {
            say(tr("Opened “{}”.").replacen("{}", &item.name, 1), false);
            let _ = unsafe { SetForegroundWindow(frame) };
        }
        Err(e) => say(format!("{} {e}", tr("The project could not be opened.")), true),
    }
}

/// Rename… (§6.2, as the macOS side has it): a box asking for the name,
/// modal over the settings window; `rename_to` does the rest.
fn rename_selected() {
    let Some((_, item)) = dir_and_selected() else { return };
    crate::prompt::prompt_rename_project(owner(), item.path.clone(), &item.name);
}

/// The Rename Project box was answered with `wanted` for the project in
/// `file`: rename it, or say why not in the status line.
pub fn rename_to(file: &Path, wanted: &str) {
    let Some(dir) = with(|s| s.dir.clone()) else { return };
    let Some(item) = with(|s| s.items.iter().find(|i| i.path == file).cloned()) else {
        say(tr("The project could not be renamed."), true);
        return;
    };
    let all: Vec<Named> = named_projects(&dir).into_iter().map(|(n, _)| n).collect();
    let this = Named { name: item.name.clone(), file: file_name(&item.path) };
    match pj::name_verdict(Some(&this), wanted, rule_file, &all) {
        NameVerdict::Unchanged => {}
        NameVerdict::Empty => say(tr("A project needs a name."), true),
        NameVerdict::Taken(other) => {
            say(tr("There is already a project called “{}”.").replacen("{}", &other, 1), true)
        }
        NameVerdict::Ok(new) => {
            let to = dir.join(rule_file(&new).unwrap_or_default());
            let r = pj::move_project(&item.path, &to).map_err(|e| e.to_string()).and_then(|_| project::set_name(&to, &new));
            match r {
                Ok(()) => {
                    // process-wide: the projects section of the one settings window
                    crate::plogf!("[projects-ui] renamed {:?} -> {:?} ({:?})", item.name, new, to);
                    reload();
                    select(Some(to));
                    say(tr("Renamed to “{}”.").replacen("{}", &new, 1), false);
                }
                Err(e) => {
                    reload();
                    say(format!("{} {e}", tr("The project could not be renamed.")), true);
                }
            }
        }
    }
    crate::settings_win::crumb_changed();
}

fn file_name(p: &Path) -> String {
    p.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
}

/// The file name the naming rule gives a name, for `pj::name_verdict`.
fn rule_file(name: &str) -> Option<String> {
    project::sanitize_filename(name).ok()
}

/// Every listed project as a typed name is checked against it (#983), with
/// the file it was found in. Read from disk, not from the section's list:
/// Save as Project asks this with the settings window closed.
fn named_projects(dir: &Path) -> Vec<(Named, PathBuf)> {
    project::list(dir)
        .entries
        .into_iter()
        .map(|e| (Named { name: e.name.clone(), file: file_name(&e.path) }, e.path))
        .collect()
}

/// What Save as Project does with `typed` (#983, the mac's `saveAsStep`):
/// the name to save under and how, or `None` for nothing -- nothing typed,
/// or an overwrite the person declined. A name another project has (the same
/// name, or its file whatever the case) asks the overwrite question and saves
/// **under that project's name**; a project in a file an older naming rule
/// gave it is moved to the rule's file first, so the save replaces it rather
/// than writing a second one beside it.
pub(crate) fn save_as_plan(owner: HWND, dir: &Path, typed: &str) -> Option<(String, pj::WriteKind)> {
    let listed = named_projects(dir);
    let all: Vec<Named> = listed.iter().map(|(n, _)| n.clone()).collect();
    match pj::save_as_step(pj::name_verdict(None, typed, rule_file, &all)) {
        SaveAsStep::Nothing => None,
        SaveAsStep::Save(name) => {
            // A file under the rule's name that did not list (it does not
            // read) is still somebody's project: asked about, and kept.
            let there = project::path_for(dir, &name).is_ok_and(|p| p.exists());
            if there && !confirm_save_as_overwrite(owner, &name, None) {
                return None;
            }
            Some((name, pj::save_as(there)))
        }
        SaveAsStep::ConfirmOverwrite(existing) => {
            let path = listed.iter().find(|(n, _)| n.name == existing).map(|(_, p)| p.clone())?;
            let snap = project::read_file(&path).ok();
            if !confirm_save_as_overwrite(owner, &existing, snap.as_ref()) {
                return None;
            }
            if let Ok(rule) = project::path_for(dir, &existing) {
                if rule != path && pj::move_project(&path, &rule).is_err() {
                    return None;
                }
            }
            Some((existing, pj::WriteKind::Overwrite))
        }
    }
}

fn duplicate_selected() {
    let Some((dir, item)) = dir_and_selected() else { return };
    // The same rule a typed name is held to (#983), and a file already on
    // disk under the name -- listed or not -- is taken too.
    let all: Vec<Named> = named_projects(&dir).into_iter().map(|(n, _)| n).collect();
    let taken = |n: &str| {
        !matches!(pj::name_verdict(None, n, rule_file, &all), NameVerdict::Ok(_))
            || rule_file(n).map_or(true, |f| dir.join(f).exists())
    };
    let new = pj::copy_name(&item.name, &tr("{} copy"), taken);
    let Ok(file) = project::sanitize_filename(&new) else { return };
    let to = dir.join(file);
    let r = pj::copy_project(&item.path, &to).map_err(|e| e.to_string()).and_then(|_| project::set_name(&to, &new));
    match r {
        Ok(()) => {
            // process-wide: as above
            crate::plogf!("[projects-ui] copied {:?} -> {:?}", item.name, new);
            reload();
            select(Some(to));
            say(tr("Copied as “{}”.").replacen("{}", &new, 1), false);
        }
        Err(e) => say(format!("{} {e}", tr("The project could not be copied.")), true),
    }
}

fn delete_selected() {
    let Some((dir, item)) = dir_and_selected() else { return };
    if !confirm(
        &tr("Delete “{}”?").replacen("{}", &item.name, 1),
        &tr("You can undo this until the settings window closes."),
        &tr("Delete"),
    ) {
        return;
    }
    // The row below takes its place, else the one above.
    let next = with(|s| {
        let v = shown(s);
        let at = v.iter().position(|&i| s.items[i].path == item.path)?;
        v.get(at + 1).or_else(|| at.checked_sub(1).and_then(|p| v.get(p))).map(|&i| s.items[i].path.clone())
    });
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
    match pj::stash(&item.path, &pj::trash_dir(&dir), now) {
        Ok(st) => {
            let old = with(|s| s.undo.deleted(item.name.clone(), st));
            if let Some(o) = old {
                // The next delete is where the last one's Undo ends (§6.2).
                let ok = recycle(&o.held);
                // process-wide: as above
                crate::plogf!("[projects-ui] the delete before: {:?} -> Recycle Bin ok={ok}", o.file);
            }
            // process-wide: as above
            crate::plogf!("[projects-ui] deleted {:?} (undo held)", item.name);
            reload();
            select(next);
        }
        Err(e) => say(format!("{} {e}", tr("The project could not be deleted.")), true),
    }
}

fn undo_delete() {
    let Some((name, st)) = with(|s| s.undo.undo()) else { return };
    match pj::unstash(&st) {
        Ok(()) => {
            // process-wide: as above
            crate::plogf!("[projects-ui] undid the delete of {:?}", name);
            reload();
            select(Some(st.file.clone()));
            say(tr("“{}” is back.").replacen("{}", &name, 1), false);
        }
        Err(e) => {
            // Refused (something was saved there since): the stash stays
            // for the banner, which comes back.
            with(|s| {
                s.undo.deleted(name, st);
            });
            reload();
            say(format!("{} {e}", tr("The project could not be put back.")), true);
        }
    }
}

fn restore_previous() {
    let Some((_, item)) = dir_and_selected() else { return };
    if !confirm(
        &tr("Restore the previous version of “{}”?").replacen("{}", &item.name, 1),
        &tr("The current version becomes the previous one, so you can switch back."),
        &tr("Restore"),
    ) {
        return;
    }
    match pj::restore_previous(&item.path) {
        Ok(()) => {
            // process-wide: as above
            crate::plogf!("[projects-ui] restored the previous version of {:?}", item.name);
            reload();
            select(Some(item.path.clone()));
            say(tr("Restored the previous version."), false);
        }
        Err(e) => say(format!("{} {e}", tr("The previous version could not be restored.")), true),
    }
}

fn overwrite_selected() {
    let Some((dir, item)) = dir_and_selected() else { return };
    let Some((frame, tab, title)) = current_tab() else {
        say(tr("There is no terminal window to open the project in."), true);
        return;
    };
    if !confirm(
        &tr("Overwrite “{}” with the current tab?").replacen("{}", &item.name, 1),
        &tr("“{}” replaces what the project holds. The version it replaces is kept and can be restored.")
            .replacen("{}", &title, 1),
        &tr("Overwrite"),
    ) {
        return;
    }
    // A project still in a file an older naming rule gave it is moved to the
    // rule's file first, so the save carries on from it instead of writing a
    // second project beside it (`ProjectStore.adoptLegacyFile` on macOS).
    if let Ok(rule) = project::path_for(&dir, &item.name) {
        if rule != item.path {
            if let Err(e) = pj::move_project(&item.path, &rule) {
                say(format!("{} {e}", tr("The project could not be saved.")), true);
                return;
            }
        }
    }
    // **Overwrite, not save**: what it replaces is kept, always (§6.2).
    match crate::project_ui::overwrite_project(&dir, frame, tab, item.name.clone()) {
        Ok(()) => {
            reload();
            let to = project::path_for(&dir, &item.name).ok();
            select(to);
            say(tr("Saved the current tab as “{}”.").replacen("{}", &item.name, 1), false);
        }
        Err(e) => say(format!("{} {e}", tr("The project could not be saved.")), true),
    }
}

/// "+": the current tab as a new project, through the window the menu row
/// opens, in front of this one; the list reads the new project when this
/// window is active again (`activated`).
fn save_new() {
    let Some((frame, tab, _)) = current_tab() else {
        say(tr("There is no terminal window to open the project in."), true);
        return;
    };
    crate::project_picker::open_save_over(owner(), frame, tab);
}

/// Show in Explorer (§6.2): the project's folder, **with its file selected**.
///
/// ⚠️ `explorer.exe /select,"<path>"` alone was what this did, and on the test
/// machine it opened the projects folder with nothing selected (#1000, the
/// log said `spawned=true`). Starting a process says nothing about what
/// Explorer then does with its argument. So the shell's own call is asked
/// first -- `SHOpenFolderAndSelectItems` on the file's ID list, which opens
/// the folder and selects the file, or says it could not -- and the command
/// line is only the fallback.
///
/// On a thread of its own, with its own COM apartment: the call talks to
/// Explorer and can wait on it, and the settings window must not wait with
/// it -- `shellopen::detached` keeps `ShellExecuteW` off the window thread
/// for the same reason.
fn reveal_selected() {
    let Some((_, item)) = dir_and_selected() else { return };
    let path = pj::reveal_path(&item.path.to_string_lossy());
    let spawned = std::thread::Builder::new().name("polter-reveal".into()).spawn(move || {
        crate::name_this_thread("polter-reveal");
        let how = match reveal_with_shell(&path) {
            Ok(()) => "SHOpenFolderAndSelectItems".to_string(),
            Err(e) => {
                use std::os::windows::process::CommandExt;
                let r = std::process::Command::new("explorer.exe").raw_arg(pj::explorer_select_arg(&path)).spawn();
                format!("SHOpenFolderAndSelectItems failed ({e}); explorer /select spawned={}", r.is_ok())
            }
        };
        // process-wide: the projects section of the one settings window
        crate::plogf!("[projects-ui] show in Explorer {:?}: {how}", path);
    });
    if spawned.is_err() {
        say(tr("Explorer could not be started."), true);
    }
}

/// The shell's call, on the calling thread (which it initialises for COM).
fn reveal_with_shell(path: &str) -> Result<(), String> {
    use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED};
    use windows::Win32::UI::Shell::{ILCreateFromPathW, ILFree, SHOpenFolderAndSelectItems};
    let w = wide(path);
    unsafe {
        let com = CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_ok();
        let pidl = ILCreateFromPathW(PCWSTR(w.as_ptr()));
        let r = if pidl.is_null() {
            Err("no ID list for that path".to_string())
        } else {
            // A full ID list for the file and no children: the shell opens its
            // folder and selects it.
            let r = SHOpenFolderAndSelectItems(pidl, None, 0).map_err(|e| format!("{e:?}"));
            ILFree(Some(pidl));
            r
        };
        if com {
            CoUninitialize();
        }
        r
    }
}

fn step(down: bool) {
    let target = with(|s| {
        let v = shown(s);
        let cur = s.selected.as_ref().and_then(|p| v.iter().position(|&i| &s.items[i].path == p));
        polter_settings_shell::step(cur, v.len(), down).map(|i| s.items[v[i]].path.clone())
    });
    if target.is_some() {
        select(target);
    }
}

fn on_command(id: u16, code: u32) {
    match id {
        ID_NEW => save_new(),
        ID_DUP => duplicate_selected(),
        ID_DEL => delete_selected(),
        ID_RENAME => rename_selected(),
        ID_UNDO => undo_delete(),
        ID_OPEN => open_selected(),
        ID_OVERWRITE => overwrite_selected(),
        ID_REVEAL => reveal_selected(),
        i if i == ID_RESTORE0 || i == ID_RESTORE0 + 1 => restore_previous(),
        _ => {
            let _ = code;
        }
    }
}

fn on_click(x: i32, y: i32) {
    let (g, _, ll, _, _) = geometry();
    let Some(list) = g.list else { return };
    if !list.contains(x, y) {
        return;
    }
    let win = main_hwnd();
    // The keyboard comes to the list, so ↑ / ↓ go on from here.
    let _ = unsafe { SetFocus(Some(win)) };
    let target = with(|s| {
        let v = shown(s);
        pj::row_at(&ll, s.list_top, v.len(), y, list.bottom).map(|i| s.items[v[i]].path.clone())
    });
    if target.is_some() {
        select(target);
    }
}

// ================================================================ drawing

pub(crate) fn make_font(dpi: i32, px: i32, weight: i32) -> HFONT {
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
    for (slot, f) in [
        (&FONT, make_font(dpi, 14, FW_NORMAL.0 as i32)),
        (&FONT_BOLD, make_font(dpi, 14, FW_SEMIBOLD.0 as i32)),
        (&FONT_SMALL, make_font(dpi, 12, FW_NORMAL.0 as i32)),
    ] {
        let old = slot.swap(f.0, Ordering::AcqRel);
        if !old.is_null() {
            let _ = unsafe { DeleteObject(HGDIOBJ(old)) };
        }
    }
    if let Some(c) = ctl() {
        let f = FONT.load(Ordering::Acquire);
        let all = c.list_buttons.iter().chain(&c.restore).chain(&c.actions).chain([&c.rename, &c.undo]);
        for h in all {
            unsafe {
                SendMessageW(*h, WM_SETFONT, Some(WPARAM(f as usize)), Some(LPARAM(1)));
            }
        }
    }
}

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

fn draw_text(hdc: HDC, s: &str, r: &RECT, font: &AtomicPtr<c_void>, colour: u32, flags: DRAW_TEXT_FORMAT) {
    let mut w: Vec<u16> = s.encode_utf16().collect();
    let mut r = *r;
    unsafe {
        let old = SelectObject(hdc, HGDIOBJ(font.load(Ordering::Acquire)));
        SetTextColor(hdc, COLORREF(colour));
        SetBkMode(hdc, TRANSPARENT);
        DrawTextW(hdc, &mut w, &mut r, flags | DT_NOPREFIX);
        SelectObject(hdc, old);
    }
}

/// "3 panes". A project is one tab on both hosts, so the tab count is
/// always 1 and is not shown (§6.1).
pub(crate) fn size_text(panes: usize) -> String {
    if panes == 1 {
        tr("1 pane")
    } else {
        tr("{} panes").replacen("{}", &panes.to_string(), 1)
    }
}

/// Seconds east of UTC on this machine now.
pub(crate) fn local_offset() -> i64 {
    use windows::Win32::System::SystemInformation::{GetLocalTime, GetSystemTime};
    let (l, u) = unsafe { (GetLocalTime(), GetSystemTime()) };
    let t = |s: windows::Win32::Foundation::SYSTEMTIME| {
        (s.wYear as i64, s.wMonth as i64, s.wDay as i64, s.wHour as i64, s.wMinute as i64)
    };
    pj::offset_seconds(t(l), t(u))
}

fn paint(win: HWND) {
    // Everything is read out first; nothing below borrows.
    let fs = filter_state();
    let (items, list_top, detail, banner, status) = with(|s| {
        let v: Vec<(Item, bool)> = shown(s)
            .into_iter()
            .map(|i| {
                let it = s.items[i].clone();
                let on = s.selected.as_ref() == Some(&it.path);
                (it, on)
            })
            .collect();
        (v, s.list_top, s.detail.clone(), s.undo.banner().map(str::to_string), s.status.clone())
    });
    let empty = with(|s| s.items.is_empty());
    let (g, a, ll, e, dpi) = geometry();
    let sc = |v: i32| scale(v, dpi);
    let offset = local_offset();
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(win, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(win, &mut rc);
        fill(hdc, &rc, theme::bg());
        let list = g.list.unwrap_or_default();
        fill(hdc, &rect(list), theme::panel());

        // The banner (§6.2): "Deleted <name>" and Undo, until the window
        // closes or the next delete.
        if let (Some(b), Some(u), Some(name)) = (ll.banner, ll.undo, banner.as_ref()) {
            fill(hdc, &rect(b), theme::field_bg());
            let t = RECT { left: ll.text_left, top: b.top, right: u.left - sc(grid::ROW_GAP), bottom: b.bottom };
            draw_text(hdc, &tr("Deleted “{}”").replacen("{}", name, 1), &t, &FONT, theme::text(), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            fill(hdc, &RECT { left: b.left, top: b.bottom - 1, right: b.right, bottom: b.bottom }, theme::border());
        }

        // The rows.
        for (k, (it, on)) in items.iter().enumerate().skip(list_top) {
            let top = ll.rows_top + (k - list_top) as i32 * ll.row_h;
            if top + ll.row_h > list.bottom {
                break;
            }
            let r = RECT { left: list.left, top, right: list.right, bottom: top + ll.row_h };
            let (fg, dim) = if *on {
                fill(hdc, &RECT { left: r.left + sc(6), right: r.right - sc(6), ..r }, theme::sel());
                (theme::sel_text(), theme::sel_text())
            } else {
                (theme::text(), theme::dim())
            };
            let right = r.right - sc(grid::PAD);
            let t = RECT { left: ll.text_left, top: r.top + sc(4), right, bottom: r.top + sc(24) };
            draw_text(hdc, &it.name, &t, &FONT, fg, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            let sub = RECT { left: ll.text_left, top: r.top + sc(23), right, bottom: r.bottom - sc(3) };
            let line = format!("{} \u{b7} {}", pj::format_time(it.saved_at, offset), size_text(it.panes));
            draw_text(hdc, &line, &sub, &FONT_SMALL, dim, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
        // §2.3a: never a blank list beside a filled editor.
        let first = RECT { left: ll.text_left, top: ll.rows_top, right: list.right - sc(grid::PAD), bottom: ll.rows_top + ll.row_h };
        if empty {
            draw_text(hdc, &tr("No Saved Projects"), &first, &FONT, theme::dim(), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        } else if fs.no_match_row {
            draw_text(hdc, &tr("No matching projects"), &first, &FONT, theme::dim(), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        }

        // The editor.
        match &detail {
            None => {
                let t = RECT { left: e.margin, top: g.editor.top + sc(grid::PAD), right: g.editor.right - sc(grid::PAD), bottom: g.bottom_rule.top };
                draw_text(hdc, &tr("Select a project, or save the current tab as one with +."), &t, &FONT, theme::dim(), DT_LEFT | DT_WORDBREAK);
            }
            Some(d) => paint_detail(hdc, d, &e, dpi, offset),
        }

        // The band's status text, between + ⧉ − and the actions.
        if let Some((t, failed)) = status {
            let r = rect(pj::status(&g, &a, dpi));
            draw_text(hdc, &t, &r, &FONT, if failed { theme::warn() } else { theme::dim() }, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        }
        // The lines last, so nothing paints over a crossing.
        if let Some(d) = g.list_divider {
            fill(hdc, &rect(d), theme::border());
        }
        fill(hdc, &rect(g.bottom_rule), theme::border());
        let _ = EndPaint(win, &ps);
    }
}

fn paint_detail(hdc: HDC, d: &Detail, e: &pj::EditorLayout, dpi: i32, offset: i64) {
    let right_label = DT_RIGHT | DT_SINGLELINE | DT_VCENTER;
    let value = DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS;
    // The project's name as the page's heading, as on macOS.
    draw_text(hdc, &d.snap.name, &rect(e.title), &FONT_BOLD, theme::text(), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);

    // The thumbnail (§6.1): the tab's split tree, each pane named by its
    // directory's last part and its title.
    let leaves = d.snap.root.as_ref().map(project::leaves).unwrap_or_default();
    fill(hdc, &rect(e.thumb), theme::panel());
    frame_rect(hdc, &rect(e.thumb), theme::border());
    if let Some(root) = &d.snap.root {
        let inner = SRect::new(e.thumb.left + 1, e.thumb.top + 1, e.thumb.right - 1, e.thumb.bottom - 1);
        let boxes = pj::thumbnail(&project::to_shape(root), inner, scale(pj::THUMB_GAP, dpi));
        for (b, leaf) in boxes.iter().zip(&leaves) {
            fill(hdc, &rect(*b), theme::field_bg());
            frame_rect(hdc, &rect(*b), theme::border());
            let pad = scale(4, dpi);
            let t = RECT { left: b.left + pad, top: b.top + pad, right: b.right - pad, bottom: b.bottom - pad };
            draw_text(hdc, &pj::pane_label(&leaf.cwd, &leaf.title), &t, &FONT_SMALL, theme::text(), DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
    }

    let dirs = pj::distinct_dirs(leaves.iter().map(|l| l.cwd.as_str()));
    let panes = leaves.len();
    let lines: [(String, String, bool); pj::DETAIL_LINES] = [
        (tr("Last saved"), pj::format_time(d.snap.saved_at, offset), false),
        (tr("Panes"), size_text(panes), false),
        (tr("Directories"), if dirs.is_empty() { tr("None recorded") } else { dirs.join("; ") }, dirs.is_empty()),
        // The project file keeps no role, on either host.
        (tr("Roles"), tr("Not recorded in project files"), true),
        (tr("Scrollback"), pj::format_bytes(d.bytes), false),
        // Windows binds no tab to a project and saves none automatically.
        (tr("Autosave"), tr("Not bound to an open window"), true),
    ];
    for (i, (label, v, quiet)) in lines.iter().enumerate() {
        draw_text(hdc, label, &rect(e.labels[i]), &FONT, theme::dim(), right_label);
        draw_text(hdc, v, &rect(e.values[i]), &FONT, if *quiet { theme::dim() } else { theme::text() }, value);
    }

    draw_text(hdc, &tr("Version History"), &rect(e.history_heading), &FONT_BOLD, theme::text(), DT_LEFT | DT_SINGLELINE | DT_VCENTER);
    let count = |s: &Snapshot| s.root.as_ref().map(crate::project_ui::leaf_count).unwrap_or(0);
    let versions = pj::versions(Some((d.snap.saved_at, count(&d.snap))), d.prev.as_ref().map(|p| (p.saved_at, count(p))));
    for (i, v) in versions.iter().enumerate().take(2) {
        let who = if v.current { tr("Current version") } else { tr("Previous version") };
        let t = format!("{who} \u{b7} {} \u{b7} {}", pj::format_time(v.saved_at, offset), size_text(v.panes));
        let mut r = rect(e.history[i]);
        if !v.current {
            r.right = e.restore[i].left - scale(grid::BUTTONS_GAP, dpi);
        }
        draw_text(hdc, &t, &r, &FONT, theme::text(), value);
    }
    if versions.len() < 2 {
        let r = rect(e.history[versions.len().min(1)]);
        draw_text(hdc, &tr("No earlier version is kept yet."), &r, &FONT, theme::dim(), value);
    }
}

// ================================================================ window

fn create(host: HWND) -> bool {
    let hi: HINSTANCE = unsafe { GetModuleHandleW(None) }.map(Into::into).unwrap_or_default();
    unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            // Repaint the whole client area on a resize, for the reason
            // `roles_ui::create` gives.
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(main_proc),
            hInstance: hi,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(std::ptr::null_mut()),
            lpszClassName: w!("PolterProjects"),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS {
            // process-wide: registering the window class, once per process
            // absence: means it was not reached -- the failure arm of a call
            // made the first time the section is shown
            crate::plogf!("[projects-ui] RegisterClassExW failed");
            return false;
        }
        // A child of the settings window, as the roles section is.
        let win = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterProjects"),
            PCWSTR::null(),
            WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_TABSTOP,
            0,
            0,
            10,
            10,
            Some(host),
            None,
            Some(hi),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the projects section, one per process
                crate::plogf!("[projects-ui] CreateWindowExW failed: {e:?}");
                return false;
            }
        };
        MAIN.store(win.0, Ordering::Release);
        let dpi = dpi_of(win);
        // The buttons are drawn by `roles_ui::common`, in its fonts, which
        // exist only once the roles section has been shown.
        crate::roles_ui::ensure_fonts(dpi);
        let mk = |id: u16, class: PCWSTR, label: &str, style: WINDOW_STYLE| -> HWND {
            let text = wide(label);
            let h = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                class,
                PCWSTR(text.as_ptr()),
                WS_CHILD | WS_TABSTOP | style,
                0,
                0,
                10,
                10,
                Some(win),
                Some(HMENU(id as usize as *mut c_void)),
                Some(hi),
                None,
            )
            .unwrap_or_default();
            if !h.0.is_null() {
                subclass(h);
            }
            h
        };
        let button = WINDOW_STYLE(BS_PUSHBUTTON as u32);
        let c = Controls {
            // + ⧉ −, as the roles list has them (settings.md §2.3a).
            list_buttons: [mk(ID_NEW, w!("BUTTON"), "+", button), mk(ID_DUP, w!("BUTTON"), "\u{29c9}", button), mk(ID_DEL, w!("BUTTON"), "\u{2212}", button)],
            rename: mk(ID_RENAME, w!("BUTTON"), &tr("Rename…"), button),
            restore: [mk(ID_RESTORE0, w!("BUTTON"), &tr("Restore"), button), mk(ID_RESTORE0 + 1, w!("BUTTON"), &tr("Restore"), button)],
            undo: mk(ID_UNDO, w!("BUTTON"), &tr("Undo"), button),
            actions: [
                mk(ID_REVEAL, w!("BUTTON"), &tr("Show in Explorer"), button),
                mk(ID_OVERWRITE, w!("BUTTON"), &tr("Overwrite with Current Tab"), button),
                mk(ID_OPEN, w!("BUTTON"), &tr("Open"), button),
            ],
        };
        CTL.with(|x| x.set(Some(c)));
        make_fonts(dpi);
        // process-wide: as above
        crate::plogf!("[projects-ui] ready");
    }
    true
}

fn subclass(h: HWND) {
    unsafe {
        let prev = SetWindowLongPtrW(h, GWLP_WNDPROC, child_proc as *const () as isize);
        let _ = SetPropW(h, PROP_PREV, Some(HANDLE(prev as *mut c_void)));
    }
}

/// Ctrl+W closes the settings window wherever the keyboard is; **Escape
/// closes nothing** (§2.3).
unsafe extern "system" fn child_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetPropW(h, PROP_PREV).0 as isize;
        match msg {
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if vk == VK_ESCAPE {
                    return LRESULT(0);
                }
                if crate::settings_win::is_close_key(vk.0) {
                    let _ = PostMessageW(Some(owner()), WM_CLOSE, WPARAM(0), LPARAM(0));
                    return LRESULT(0);
                }
            }
            // The characters those keys also produce, which an `EDIT` would
            // answer with a beep.
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
        CallWindowProcW(Some(f), h, msg, wp, lp)
    }
}

unsafe extern "system" fn main_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if let Some(r) = crate::roles_ui::common(win, msg, wp, lp) {
            return r;
        }
        match msg {
            WM_COMMAND => {
                on_command((wp.0 & 0xFFFF) as u16, ((wp.0 >> 16) & 0xFFFF) as u32);
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let x = (lp.0 & 0xFFFF) as i16 as i32;
                let y = ((lp.0 >> 16) & 0xFFFF) as i16 as i32;
                on_click(x, y);
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
                with(|s| {
                    let n = shown(s).len();
                    s.list_top = if delta > 0 { s.list_top.saturating_sub(1) } else { (s.list_top + 1).min(n.saturating_sub(1)) };
                });
                let _ = InvalidateRect(Some(win), None, false);
                LRESULT(0)
            }
            WM_GETDLGCODE => LRESULT(DLGC_WANTARROWS as isize),
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if crate::settings_win::is_close_key(vk.0) {
                    let _ = PostMessageW(Some(owner()), WM_CLOSE, WPARAM(0), LPARAM(0));
                } else if vk == VK_UP || vk == VK_DOWN {
                    step(vk == VK_DOWN);
                } else if vk == VK_RETURN {
                    open_selected();
                } else if vk == VK_DELETE {
                    delete_selected();
                } else if vk == VK_F2 {
                    rename_selected();
                }
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
