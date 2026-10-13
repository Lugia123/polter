//! The projects that are open: which tab is which page of which project,
//! saving one as it changes, and opening one whole (task 1496; v20 rules
//! 1, 3, 4 and 5).
//!
//! **This file gathers and carries out. It decides nothing.** Which page a
//! tab is after it was dragged, where a page that is not open stays, which
//! is in front, what a save may not overwrite, where a window opens and how
//! soon a change is written are `polter-projects` -- the macOS host's
//! `ProjectPages.swift`, case for case -- where each has a test that runs
//! off Windows. This host cannot be run where it is written, so anything
//! below that could be wrong without looking wrong belongs there instead.
//!
//! **A page that is not open stays in the project.** Closing a tab is not
//! taking it out: its page keeps the layout it was last saved with and
//! comes back when the project is opened again.
//!
//! **Main thread only.** Every entry is reached from a window procedure, an
//! op, or a thread timer, so the state is a `thread_local` and there is no
//! lock. What there is instead is a `RefCell`, and the rule that goes with
//! it: **nothing is called out to while it is borrowed.** Asking the tab
//! model for a tree, creating a tab, or writing a file can each come back
//! here (`note` is called from the tab model's own paths), so every
//! function copies out what it needs, lets go, does the work, and puts the
//! result back.
//!
//! # Not done in this file yet
//!
//!  * **The core is told nothing.** No `projects` statement is sent and no
//!    `project_orders` is read (`dev-docs/poltergeist/projects.md`, 8): that
//!    is the second half of this task.
//!  * **Nothing asks before a page is closed, and no page can be taken out
//!    of a project from the screen.** Also the second half.
//!  * **A restart forgets which tabs were pages.** This host does not bring
//!    its tabs back after a restart, so there is no tab to match to a page
//!    (`Pages::page_sharing` is there for the day it does). The project is
//!    opened again from its file.
//!  * **Who is in a pane is not recorded**: every pane is saved `Unknown`,
//!    which keeps whatever the file already said of it.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use windows::Win32::Foundation::{HWND, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO};
use windows::Win32::UI::WindowsAndMessaging::{
    GetWindowPlacement, GetWindowRect, IsIconic, IsZoomed, KillTimer, SetForegroundWindow, SetTimer, SetWindowPos, SWP_NOACTIVATE,
    SWP_NOZORDER, WINDOWPLACEMENT,
};

use polter_projects::autosave::{Change, Debounce};
use polter_projects::pages::{Live, PageId, Pages, Screen};
use polter_projects::placement::{self, Place, Rect};

use crate::project::{self, WriteKind};
use crate::tabs::{self, TabId};
use crate::{plogf, wlogf};

/// One project that has a tab open.
struct Open {
    /// The file it is: its identity, as everywhere else in this host.
    file: PathBuf,
    name: String,
    /// The group the file says it is the project of. Carried from read to
    /// write untouched; nothing here changes it.
    group: Option<String>,
    next_scrollback: Option<u64>,
    pages: Pages,
    /// Which tab is which page. A tab is in here from the moment it is
    /// opened or saved as a page until it closes.
    tabs: Vec<(TabId, PageId)>,
    debounce: Debounce,
}

thread_local! {
    static OPEN: RefCell<Vec<Open>> = const { RefCell::new(Vec::new()) };
    /// The thread timer the next write is waiting on; 0 for none.
    static TIMER: Cell<usize> = const { Cell::new(0) };
}

/// Seconds on a clock that only goes forward.
fn now() -> f64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64()
}

fn wall_secs() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

// ------------------------------------------------------------------ asking

/// The name of the project `tab` is a page of, when it is one.
pub fn project_of_tab(tab: TabId) -> Option<String> {
    OPEN.with(|o| o.try_borrow().ok()?.iter().find(|p| p.tabs.iter().any(|(t, _)| *t == tab)).map(|p| p.name.clone()))
}

/// Whether the project in `file` has a tab open, and so is saved as it
/// changes.
pub fn is_open(file: &Path) -> bool {
    OPEN.with(|o| o.try_borrow().is_ok_and(|o| o.iter().any(|p| p.file == file)))
}

// ----------------------------------------------------------------- changes

/// Something changed that an open project may record: every one that has a
/// tab open is to be written, `change` saying how soon
/// (`autosave::Change::no_later_than`).
///
/// **Called from wherever the change is made, and it is cheap to call too
/// often**: a write that would change nothing but the time is not made
/// (`project::write_file`). Which project the change was in is not asked --
/// a tab can be dragged between windows, and "every open project" is the
/// answer that cannot miss one.
///
/// With the state in use (a save or an open is under way, and it is what
/// caused this) nothing is noted: that work ends by writing or by noting a
/// change itself.
pub fn note(change: Change) {
    let noted = OPEN.with(|o| {
        let Ok(mut open) = o.try_borrow_mut() else { return false };
        let at = now();
        for p in open.iter_mut().filter(|p| !p.tabs.is_empty()) {
            p.debounce.poke(change, at);
        }
        !open.is_empty()
    });
    if noted {
        arm_timer();
    }
}

/// Set the thread timer for the earliest write that is due; none when
/// nothing is pending.
fn arm_timer() {
    let due = OPEN.with(|o| o.try_borrow().ok().and_then(|o| o.iter().filter_map(|p| p.debounce.due_at()).fold(None, |a: Option<f64>, d| Some(a.map_or(d, |a| a.min(d))))));
    let old = TIMER.with(|t| t.replace(0));
    if old != 0 {
        let _ = unsafe { KillTimer(None, old) };
    }
    let Some(due) = due else { return };
    let ms = ((due - now()).max(0.0) * 1000.0).ceil() as u32;
    let id = unsafe { SetTimer(None, 0, ms.max(10), Some(timer)) };
    // not-gated: the condition is the event -- the timer was refused, and
    // without this line a project that stopped being saved leaves no trace.
    if id == 0 {
        // process-wide: one thread timer serves every open project
        plogf!("[project] SetTimer failed; open projects are not saved until the next change");
        return;
    }
    TIMER.with(|t| t.set(id));
}

unsafe extern "system" fn timer(_: HWND, _: u32, id: usize, _: u32) {
    let _ = unsafe { KillTimer(None, id) };
    TIMER.with(|t| {
        if t.get() == id {
            t.set(0);
        }
    });
    let at = now();
    let due: Vec<PathBuf> = OPEN.with(|o| match o.try_borrow_mut() {
        Ok(mut open) => open.iter_mut().filter_map(|p| p.debounce.take_if_due(at).then(|| p.file.clone())).collect(),
        Err(_) => Vec::new(),
    });
    for file in due {
        if let Err(e) = save(&file, false, false) {
            // Logged, not shown: this runs by itself a second after any
            // change, and a box per title change is worse than the failure.
            // The next change tries again.
            // process-wide: a project is tabs of any number of windows
            plogf!("[project] autosave of {:?} failed: {}", file, e);
        }
    }
    arm_timer();
}

// ------------------------------------------------------------------ saving

/// Where a window is, as a project records it: where it would be if it were
/// neither minimised nor maximised, because that is the place a person gave
/// it. None when Windows does not say.
fn frame_of(hwnd: HWND) -> Option<project::Frame> {
    let mut r = RECT::default();
    unsafe {
        if IsIconic(hwnd).as_bool() || IsZoomed(hwnd).as_bool() {
            let mut wp = WINDOWPLACEMENT { length: std::mem::size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
            GetWindowPlacement(hwnd, &mut wp).ok()?;
            r = wp.rcNormalPosition;
        } else {
            GetWindowRect(hwnd, &mut r).ok()?;
        }
    }
    Some(placement::stored(Rect { x: r.left as f64, y: r.top as f64, width: (r.right - r.left) as f64, height: (r.bottom - r.top) as f64 }))
}

/// What a save finds on screen for the tabs in `bound`: each one's tree
/// with every pane named, where it stands, and its window's frame. Tabs
/// that are no longer anywhere come back in the second list.
///
/// `capture` is `project_ui::name_leaves`'s.
fn screen_of(bound: &[(TabId, PageId)], snaps: &Path, alloc: &mut project::Allocator, capture: bool, keeping_front: bool) -> (Screen, Vec<TabId>) {
    let mut live = Vec::new();
    let mut frames = BTreeMap::new();
    let mut gone = Vec::new();
    for (tab, page) in bound {
        let Some((frame, index, selected)) = tabs::locate_tab(*tab) else {
            gone.push(*tab);
            continue;
        };
        let Some((mut root, panes)) = crate::project_ui::tab_tree(frame, *tab) else {
            gone.push(*tab);
            continue;
        };
        crate::project_ui::name_leaves(frame, &mut root, &panes, snaps, alloc, capture);
        let token = frame.0 as isize;
        live.push(Live { id: *page, window: token, index, selected, root });
        if let std::collections::btree_map::Entry::Vacant(slot) = frames.entry(token) {
            if let Some(f) = frame_of(frame) {
                slot.insert(f);
            }
        }
    }
    (Screen { live, frames, keeping_front }, gone)
}

/// Every snapshot name `pages` refers to or the directory holds: what an
/// allocator must start past.
fn names_in_use(pages: &Pages, snaps: &Path) -> Vec<String> {
    let mut in_use = pages.scrollback_names();
    if let Ok(entries) = std::fs::read_dir(snaps) {
        in_use.extend(entries.flatten().filter_map(|e| e.file_name().to_str().map(str::to_string)));
    }
    in_use
}

/// Write the open project in `file` as it stands: every open tab as it is
/// now and where it is now, every page that is not open as it was
/// (`Pages::saving`). Nothing when it is not open.
///
/// `keeping_front` is for the save a closing tab makes (`Pages::updated`).
fn save(file: &Path, keeping_front: bool, capture: bool) -> Result<(), String> {
    let Some((name, group, next, pages, bound)) = OPEN.with(|o| {
        let open = o.try_borrow().ok()?;
        let p = open.iter().find(|p| p.file == file)?;
        Some((p.name.clone(), p.group.clone(), p.next_scrollback, p.pages.clone(), p.tabs.clone()))
    }) else {
        return Ok(());
    };

    let snaps = project::scrollback_dir(file);
    let in_use = names_in_use(&pages, &snaps);
    let mut alloc = project::Allocator::new(next, in_use.iter().map(String::as_str));
    let (screen, gone) = screen_of(&bound, &snaps, &mut alloc, capture, keeping_front);
    let (after, snapshot) = pages.saving(&name, wall_secs(), group, Some(alloc.next), &screen);

    project::write_file(file, &snapshot, WriteKind::Save).map_err(|e| e.to_string())?;
    // After the write, so a failed write leaves the previous save's
    // snapshots where its file still points. Kept: what every page names,
    // open or not.
    let pruned = project::prune_scrollback_dir(&snaps, &after.scrollback_names());
    // process-wide: a project is tabs of any number of windows
    plogf!(
        "[project] saved {:?}: {} of {} page(s) open, {} window(s), next_scrollback={}, {} stale snapshot(s) removed, {}{}",
        name,
        screen.live.len(),
        after.page_ids().len(),
        after.windows().len(),
        alloc.next,
        pruned,
        history_note(&snapshot),
        if keeping_front { " (a tab closing)" } else { "" }
    );

    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            if let Some(p) = open.iter_mut().find(|p| p.file == file) {
                p.pages = after;
                p.next_scrollback = Some(alloc.next);
                p.tabs.retain(|(t, _)| !gone.contains(t));
            }
            // A project none of whose tabs is left -- its window went
            // without its tabs being closed one by one -- is not open.
            open.retain(|p| !p.tabs.is_empty());
        }
    });
    Ok(())
}

/// How many of the panes just written have no command history to come back
/// with, said in the save's own log line: an empty history that nobody can
/// ask about reads the same as a pane that never ran a command.
fn history_note(snapshot: &project::Snapshot) -> String {
    let (missing, total) = snapshot.tabs().fold((0, 0), |(m, t), root| {
        (m + crate::project_ui::missing_history_count(root), t + crate::project_ui::leaf_count(root))
    });
    format!("{missing} of {total} pane(s) without history")
}

/// Every open project, written now: before the application goes, and before
/// a window is asked to close. Nothing pending is left to a timer that will
/// not fire.
///
/// No whole-scrollback capture: each pane's journal has its scrollback, and
/// a tab that then closes makes its own save with one (`tab_closing`).
pub fn save_all() {
    let files: Vec<PathBuf> = OPEN.with(|o| match o.try_borrow_mut() {
        Ok(mut open) => open
            .iter_mut()
            .filter(|p| !p.tabs.is_empty())
            .map(|p| {
                p.debounce.cancel();
                p.file.clone()
            })
            .collect(),
        Err(_) => Vec::new(),
    });
    for file in files {
        if let Err(e) = save(&file, false, false) {
            // process-wide: a project is tabs of any number of windows
            plogf!("[project] save of {:?} before closing failed: {}", file, e);
        }
    }
    arm_timer();
}

/// `tab` of `frame` is about to be destroyed. If it is a page of a project,
/// the project is written with the tab still in it -- its last layout, and
/// the one time besides a save somebody asked for that its panes' whole
/// scrollback is captured -- and then the tab stops being a page that is
/// open. **Its page stays in the project.**
///
/// Called while the tab and its panes are all still there.
pub fn tab_closing(frame: HWND, tab: TabId) {
    let Some(file) = OPEN.with(|o| o.try_borrow().ok()?.iter().find(|p| p.tabs.iter().any(|(t, _)| *t == tab)).map(|p| p.file.clone())) else {
        return;
    };
    if let Err(e) = save(&file, true, true) {
        wlogf!(frame, "[project] last save of {:?} for a closing tab failed: {}", file, e);
    }
    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            if let Some(p) = open.iter_mut().find(|p| p.file == file) {
                p.tabs.retain(|(t, _)| *t != tab);
            }
            // With no tab open there is nothing left to save as it changes.
            open.retain(|p| !p.tabs.is_empty());
        }
    });
    arm_timer();
}

/// The tabs in `chosen` saved as the project in `file`, called `name`: the
/// project is those tabs and nothing else (`project_ui::save_tabs_as`).
///
/// A tab that is already a page of *another* project is refused -- a tab is
/// a page of one project (v20, rule 6). One that is a page of *this* project
/// is simply part of what is saved.
pub fn save_as(file: &Path, chosen: &[(HWND, TabId)], name: String, kind: WriteKind) -> Result<(), String> {
    for (_, tab) in chosen {
        let elsewhere = OPEN.with(|o| o.try_borrow().ok()?.iter().find(|p| p.file != file && p.tabs.iter().any(|(t, _)| t == tab)).map(|p| p.name.clone()));
        if let Some(other) = elsewhere {
            return Err(format!("that tab is already a page of the project {other:?}"));
        }
    }

    // What the name already holds: its group stays, and its numbers are not
    // handed out again.
    let existing = project::read_file(file).ok();
    let group = existing.as_ref().and_then(|e| e.group.clone());
    let snaps = project::scrollback_dir(file);
    let mut in_use: Vec<String> = existing.as_ref().map(project::Snapshot::scrollback_names).unwrap_or_default();
    in_use.extend(names_in_use(&Pages::new(), &snaps));
    let mut alloc = project::Allocator::new(existing.as_ref().and_then(|e| e.next_scrollback), in_use.iter().map(String::as_str));

    let mut pages = Pages::new();
    let mut bound: Vec<(TabId, PageId)> = Vec::new();
    for (_, tab) in chosen {
        if !bound.iter().any(|(t, _)| t == tab) {
            bound.push((*tab, pages.new_page_id()));
        }
    }
    let (screen, gone) = screen_of(&bound, &snaps, &mut alloc, true, false);
    if screen.live.is_empty() {
        return Err("that tab no longer exists".to_string());
    }
    let (after, snapshot) = pages.saving(&name, wall_secs(), group.clone(), Some(alloc.next), &screen);
    project::write_file(file, &snapshot, kind).map_err(|e| e.to_string())?;
    let pruned = project::prune_scrollback_dir(&snaps, &after.scrollback_names());
    // process-wide: a project is tabs of any number of windows
    plogf!(
        "[project] saved as {:?}: {} page(s) in {} window(s), next_scrollback={}, {} stale snapshot(s) removed, {}",
        name,
        after.page_ids().len(),
        after.windows().len(),
        alloc.next,
        pruned,
        history_note(&snapshot)
    );

    bound.retain(|(t, _)| !gone.contains(t));
    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            // Whatever was open under this file is replaced by this.
            open.retain(|p| p.file != file);
            open.push(Open { file: file.to_path_buf(), name, group, next_scrollback: Some(alloc.next), pages: after, tabs: bound, debounce: Debounce::new() });
        }
    });
    Ok(())
}

// ----------------------------------------------------------------- opening

/// The part of every screen a window may use.
fn work_areas() -> Vec<Rect> {
    unsafe extern "system" fn each(monitor: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> windows::core::BOOL {
        let out = data.0 as *mut Vec<Rect>;
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !out.is_null() && unsafe { GetMonitorInfoW(monitor, &mut mi) }.as_bool() {
            let w = mi.rcWork;
            unsafe { (*out).push(Rect { x: w.left as f64, y: w.top as f64, width: (w.right - w.left) as f64, height: (w.bottom - w.top) as f64 }) };
        }
        windows::core::BOOL(1)
    }
    let mut out: Vec<Rect> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut out as *mut Vec<Rect> as isize));
    }
    out
}

/// Open the project in `file`, whole (v20, rule 3): every page of it that
/// is not open already. A project that is open is gone to, and the pages of
/// it that were closed come back.
///
/// Where each window of it goes is `placement::place`: one that recorded
/// its frame opens as a window of its own, there; one that did not opens as
/// tabs of `frame`. `named` is for a project opened from the control room,
/// whose first window goes among `frame`'s tabs whatever it recorded. A
/// window some of whose pages are open already takes the rest where those
/// are.
///
/// Never called from inside `tabs::run_ops` (`open_page_in_new_tab`).
pub fn open(frame: HWND, app: crate::ffi::App, hinst: windows::Win32::Foundation::HINSTANCE, file: &Path, named: bool) -> Result<(), String> {
    // In words: a project from a later format is refused, and "TooNew" on
    // its own does not tell a person that updating is what opens it.
    let snapshot = project::read_file(file).map_err(|e| e.to_string())?;
    let snaps = project::scrollback_dir(file);

    // What is open of it already, if anything. The pages are the session's,
    // not the file's: a page added since the last write is one of them.
    let (pages, mut bound, was_open) = OPEN
        .with(|o| {
            let open = o.try_borrow().ok()?;
            let p = open.iter().find(|p| p.file == file)?;
            Some((p.pages.clone(), p.tabs.clone(), true))
        })
        .unwrap_or_else(|| (Pages::from_file(&snapshot), Vec::new(), false));

    let screens = work_areas();
    let mut errors: Vec<String> = Vec::new();
    let mut opened = 0usize;
    let mut first: Option<(HWND, TabId)> = None;
    for (at, window) in pages.windows().iter().enumerate() {
        let missing: Vec<_> = window.pages.iter().filter(|p| !bound.iter().any(|(_, id)| *id == p.id)).collect();
        if missing.is_empty() {
            continue;
        }
        let beside = window.pages.iter().find_map(|p| bound.iter().find(|(_, id)| *id == p.id)).and_then(|(tab, _)| tabs::locate_tab(*tab)).map(|(f, _, _)| f);
        let (target, ours) = match beside {
            Some(f) => (f, false),
            None => match placement::place(window.frame, at == 0, named, !frame.0.is_null(), &screens) {
                Place::Tabs(_) => (frame, false),
                Place::OwnWindow(rect) => {
                    let Some(made) = crate::create_frame_secondary(hinst) else {
                        errors.push("a window could not be created".to_string());
                        continue;
                    };
                    if let Some(r) = rect {
                        let _ = unsafe { SetWindowPos(made, None, r.x as i32, r.y as i32, r.width as i32, r.height as i32, SWP_NOZORDER | SWP_NOACTIVATE) };
                    }
                    wlogf!(made, "[project] a window of {:?} opens at {:?}", snapshot.name, rect);
                    (made, true)
                }
            },
        };
        if target.0.is_null() {
            errors.push("there is no terminal window to open the pages in".to_string());
            continue;
        }

        let mut front = None;
        for page in missing {
            match crate::project_ui::open_page_in_new_tab(target, app, hinst, &page.tab.root, &snaps) {
                Ok(tab) => {
                    bound.push((tab, page.id));
                    opened += 1;
                    first.get_or_insert((target, tab));
                    if page.id == window.front {
                        front = Some(tab);
                    }
                }
                Err(e) => errors.push(e),
            }
        }
        // The page that was in front is the one showing.
        if let Some(tab) = front {
            tabs::activate_tab(target, tab);
        }
        // A window made for pages none of which opened is not left empty.
        if ours && tabs::count(target) == 0 {
            crate::winid::close_window_now(target);
        }
    }

    for e in &errors {
        wlogf!(frame, "[project] opening {:?}: {}", snapshot.name, e);
    }
    if bound.is_empty() {
        return Err(if errors.is_empty() { "the project has no page to open".to_string() } else { errors.join("; ") });
    }

    // Gone to: the first page just opened, or -- all of it was open already
    // -- the first page that is.
    let go = first.or_else(|| bound.first().and_then(|(tab, _)| tabs::locate_tab(*tab).map(|(f, _, _)| (f, *tab))));
    if let Some((window, tab)) = go {
        if opened == 0 {
            tabs::activate_tab(window, tab);
        }
        let _ = unsafe { SetForegroundWindow(window) };
    }
    wlogf!(
        frame,
        "[project] opened {:?}: {} page(s) opened now, {} open in all, of {}{}",
        snapshot.name,
        opened,
        bound.len(),
        pages.page_ids().len(),
        if was_open { " (it was open already)" } else { "" }
    );

    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            match open.iter_mut().find(|p| p.file == file) {
                Some(p) => p.tabs = bound,
                None => open.push(Open {
                    file: file.to_path_buf(),
                    name: snapshot.name.clone(),
                    group: snapshot.group.clone(),
                    next_scrollback: snapshot.next_scrollback,
                    pages,
                    tabs: bound,
                    debounce: Debounce::new(),
                }),
            }
        }
    });
    // Where its windows stand now is worth writing once things are still.
    if opened > 0 {
        note(Change::Pages);
    }
    Ok(())
}

/// The project in `file` was moved to `to` and is now called `name` (a
/// rename from the settings window): it is the same project, open under its
/// new file.
pub fn moved(file: &Path, to: &Path, name: &str) {
    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            if let Some(p) = open.iter_mut().find(|p| p.file == file) {
                p.file = to.to_path_buf();
                p.name = name.to_string();
            }
        }
    });
}

/// The project in `file` is gone (deleted from the settings window, or its
/// previous version was put back over it): its tabs stay open and are no
/// longer pages of anything, so nothing writes the file again behind the
/// person's back.
pub fn forget(file: &Path) {
    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            open.retain(|p| p.file != file);
        }
    });
    arm_timer();
}

/// Every open project's name and how many of its tabs are open: for a line
/// in the log, and for a test of this file on a real machine.
pub fn summary() -> Vec<(String, usize)> {
    OPEN.with(|o| o.try_borrow().map(|o| o.iter().map(|p| (p.name.clone(), p.tabs.len())).collect()).unwrap_or_default())
}

/// The tabs that are pages of any open project.
pub fn bound_tabs() -> Vec<TabId> {
    OPEN.with(|o| o.try_borrow().map(|o| o.iter().flat_map(|p| p.tabs.iter().map(|(t, _)| *t)).collect()).unwrap_or_default())
}
