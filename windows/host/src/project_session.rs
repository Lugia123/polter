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
//! # The core
//!
//! The core is told what projects there are and which are open
//! (`state`), and what it asks back is done (`told`, `obey`):
//! `dev-docs/poltergeist/projects.md` 3, 4 and 8. What is said and what an
//! order still asks are `polter_projects::stated` and `::orders`.
//!
//! # Not done in this file yet
//!
//!  * **A restart forgets which tabs were pages.** This host does not bring
//!    its tabs back after a restart, so there is no tab to match to a page
//!    (`Pages::page_sharing` is there for the day it does). The project is
//!    opened again from its file.
//!
//! # Who is in a pane
//!
//! A save reads the snapshot's `terminals[].who` for each pane: who is in it
//! (`agent`, task 1800 -- the supervisor's pane keeps its mark,
//! `pages::agent_kept`), and whether the supervisor opened it as a worker
//! (`by_supervisor`, task 1799), which is what the core is then told as
//! `workers`.

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
use polter_projects::orders::{self, Have, Order, Step, Told};
use polter_projects::page_rules::{self, SaveOver};
use polter_projects::pages::{self, Live, PageId, Pages, Screen};
use polter_projects::placement::{self, Place, Rect};
use polter_projects::stated::{self, FailedWhy, Stated};

use crate::project::{self, PaneColor, WriteKind};
use crate::tabs::{self, TabId};
use crate::{plogf, wlogf};

/// One project that has a tab open.
struct Open {
    /// The file it is: its identity, as everywhere else in this host.
    file: PathBuf,
    name: String,
    /// The group the file says it is the project of. Carried from read to
    /// write; changed only when the core asks (`set_group`).
    group: Option<String>,
    /// The project's colour (task 1796), carried from read to write like
    /// the group; changed only by the person (settings) or, when it has
    /// none, given one (`project_color::give`).
    color: PaneColor,
    next_scrollback: Option<u64>,
    pages: Pages,
    /// Which tab is which page. A tab is in here from the moment it is
    /// opened or saved as a page until it closes.
    tabs: Vec<(TabId, PageId)>,
    /// The terminals in each open page's panes, in the order of the page's
    /// leaves, as the last save found them: what the core is told.
    terminals: Vec<(PageId, Vec<String>)>,
    debounce: Debounce,
}

/// What a save found on screen, besides the screen itself.
struct Found {
    /// Tabs that are no longer anywhere.
    gone: Vec<TabId>,
    terminals: Vec<(PageId, Vec<String>)>,
}

thread_local! {
    static OPEN: RefCell<Vec<Open>> = const { RefCell::new(Vec::new()) };
    /// The thread timer the next write is waiting on; 0 for none.
    static TIMER: Cell<usize> = const { Cell::new(0) };
    /// The statement the core last took; none until it has taken one.
    static STATED: RefCell<Option<String>> = const { RefCell::new(None) };
    /// The project files the last statement said could not be read (task
    /// 1807), for the control room's banner.
    static UNREADABLE: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    /// The orders of the last snapshot that are still to be looked at, and
    /// the timer that will look at them.
    static ORDERS: RefCell<Vec<Order>> = const { RefCell::new(Vec::new()) };
    static ORDERS_TIMER: Cell<usize> = const { Cell::new(0) };
    /// The projects directory as last looked at, and the repeating timer
    /// that looks (task 1830): a file fixed, broken or moved away by hand
    /// is noticed within `WATCH_MS`, where nothing else would say so.
    static DIRECTORY: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
    static WATCH_TIMER: Cell<usize> = const { Cell::new(0) };
    /// Orders that were acted on and are still being asked: each is acted
    /// on once for as long as the core goes on asking it.
    static TRIED: RefCell<Vec<Order>> = const { RefCell::new(Vec::new()) };
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
    // A pane more or fewer is something the core is told.
    state();
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
///
/// `supervisor` is the terminal in the project's supervisor pane as the
/// core was last told (`Stated::supervisor`): each pane whose terminal the
/// core says was opened as its worker is marked so (`pages::mark_workers`,
/// task 1799). `None` marks nothing and the file's marks stand.
fn screen_of(
    bound: &[(TabId, PageId)],
    snaps: &Path,
    alloc: &mut project::Allocator,
    capture: bool,
    keeping_front: bool,
    supervisor: Option<&str>,
    group: Option<&str>,
) -> (Screen, Found) {
    // Who the group's supervisor is now, as the core says (task 1831).
    let steward = group.and_then(|g| {
        crate::control_room_source::with(|d| match d {
            crate::control_room_source::Data::Ready(r) => r.list.row(g).and_then(|row| row.steward.clone()),
            _ => None,
        })
    });
    let mut live = Vec::new();
    let mut frames = BTreeMap::new();
    let mut gone = Vec::new();
    let mut terminals = Vec::new();
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
        let behind: Vec<Option<String>> = panes.iter().map(crate::project_ui::LeafPane::terminal).collect();
        pages::fill_agents(&mut root, &behind, &agent_of);
        pages::mark_workers(&mut root, &behind, supervisor, &worker_of);
        pages::mark_seats(&mut root, &behind, group, steward.as_deref());
        terminals.push((*page, behind.into_iter().flatten().collect()));
        let token = frame.0 as isize;
        // The tab's chosen name, whoever chose it; none is "none said",
        // which keeps the file's (`Live::title`). Never the program's title.
        let title = tabs::chosen_name_of_tab(*tab);
        live.push(Live { id: *page, window: token, index, selected, root, title });
        if let std::collections::btree_map::Entry::Vacant(slot) = frames.entry(token) {
            if let Some(f) = frame_of(frame) {
                slot.insert(f);
            }
        }
    }
    (Screen { live, frames, keeping_front }, Found { gone, terminals })
}

/// What the core's last snapshot says of who is in `terminal` (`who`);
/// none when it does not list it, says nothing of it, or has not been read.
fn who_of<R>(terminal: &str, f: impl FnOnce(&polter_control_room::snapshot::Who) -> R) -> Option<R> {
    crate::control_room_source::with(|data| match data {
        crate::control_room_source::Data::Ready(r) => r.snapshot.terminals.iter().find(|t| t.id == terminal).and_then(|t| t.who.as_ref()).map(f),
        _ => None,
    })
}

/// The supervisor `terminal` was opened for as a worker (`who.worker_of`).
fn worker_of(terminal: &str) -> Option<String> {
    who_of(terminal, |w| w.worker_of.clone()).flatten()
}

/// Who is in `terminal`, as a save writes it (task 1800): not known when
/// the snapshot cannot say.
fn agent_of(terminal: &str) -> polter_projectfile::Agent {
    who_of(terminal, |w| pages::agent_said(w.is.name(), w.role.as_deref(), w.cli.as_deref(), w.session.as_deref()))
        .unwrap_or(polter_projectfile::Agent::Unknown)
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
    let Some((name, group, color, next, pages, bound, supervisor)) = OPEN.with(|o| {
        let open = o.try_borrow().ok()?;
        let p = open.iter().find(|p| p.file == file)?;
        // Who the supervisor is, as the core was last told: what macOS
        // compares a pane's worker with as well (`ProjectSession`).
        let supervisor = Stated::of_open(&p.name, p.group.clone(), &p.pages, &on_screen(p)).supervisor;
        Some((p.name.clone(), p.group.clone(), p.color, p.next_scrollback, p.pages.clone(), p.tabs.clone(), supervisor))
    }) else {
        return Ok(());
    };

    let snaps = project::scrollback_dir(file);
    let in_use = names_in_use(&pages, &snaps);
    let mut alloc = project::Allocator::new(next, in_use.iter().map(String::as_str));
    let (screen, found) = screen_of(&bound, &snaps, &mut alloc, capture, keeping_front, supervisor.as_deref(), group.as_deref());
    let (after, snapshot) = pages.saving(&name, wall_secs(), group, color, Some(alloc.next), &screen);

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
                p.tabs.retain(|(t, _)| !found.gone.contains(t));
                p.terminals = found.terminals;
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
/// A tab that a move left with no pane has been taken away (task 1549).
/// **Not `tab_closing`**: what was in it is open somewhere else, so it is not
/// written one last time with nothing in it -- it simply stops being one of
/// its project's open pages.
pub fn tab_left(tab: TabId) {
    let known = OPEN.with(|o| o.try_borrow().ok().is_some_and(|o| o.iter().any(|p| p.tabs.iter().any(|(t, _)| *t == tab))));
    if !known {
        return;
    }
    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            for p in open.iter_mut() {
                p.tabs.retain(|(t, _)| *t != tab);
            }
            open.retain(|p| !p.tabs.is_empty());
        }
    });
    state();
    arm_timer();
}

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
    state();
    arm_timer();
}

/// The tabs in `chosen` saved as the project in `file`, called `name`: the
/// project becomes those tabs. Whatever pages it had are replaced (the
/// replaced version is kept as the previous one when `kind` says so), and
/// its group, if it had one, stays its group.
///
/// What it may not do is `page_rules::save_over`, the macOS host's rule:
/// refused while the project is open in other tabs -- they would write
/// themselves straight back over this -- and refused for a tab that is a
/// page of another project.
pub fn save_as(file: &Path, chosen: &[(HWND, TabId)], name: String, kind: WriteKind) -> Result<(), String> {
    save_as_for(file, chosen, name, kind, None)
}

/// `save_as`, and `group` -- when given -- is what the file names as its
/// group instead of what it named before (an order to create a project).
fn save_as_for(file: &Path, chosen: &[(HWND, TabId)], name: String, kind: WriteKind, group: Option<Option<String>>) -> Result<(), String> {
    let its_tabs: Vec<u64> = OPEN.with(|o| {
        o.try_borrow().ok().and_then(|o| o.iter().find(|p| p.file == file).map(|p| p.tabs.iter().map(|(t, _)| t.0).collect())).unwrap_or_default()
    });
    let asked: Vec<(u64, Option<String>)> = chosen.iter().map(|(_, tab)| (tab.0, project_of_tab(*tab))).collect();
    match page_rules::save_over(&name, &its_tabs, &asked) {
        SaveOver::Replace => {}
        SaveOver::Again => {
            // Its own project, saved again by hand: with the whole
            // scrollback, as a save somebody asked for is.
            save(file, false, true)?;
            state();
            return Ok(());
        }
        SaveOver::OpenElsewhere => {
            let w = page_rules::open_elsewhere_words(&name);
            return Err(w.filled(&crate::i18n::tr(w.msgid)));
        }
        SaveOver::PageOfAnother { tab, project } => {
            let w = page_rules::page_of_another_words(&tabs::title_of_tab(TabId(tab)), &project);
            return Err(w.filled(&crate::i18n::tr(w.msgid)));
        }
    }

    // What the name already holds: its group stays, and its numbers are not
    // handed out again.
    let existing = project::read_file(file).ok();
    let group = group.unwrap_or_else(|| existing.as_ref().and_then(|e| e.group.clone()));
    // What the name already holds keeps its colour; a new project is
    // given the one least in use (task 1796).
    let color = match existing.as_ref().map(|e| e.color) {
        Some(c) if c != PaneColor::None => c,
        _ => given_color(file),
    };
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
    // A new project, or one saved over: no supervisor of it to compare
    // with yet, so no pane is marked as its worker here. The next save
    // after its supervisor's pane is marked does that.
    let (screen, found) = screen_of(&bound, &snaps, &mut alloc, true, false, None, group.as_deref());
    if screen.live.is_empty() {
        return Err("that tab no longer exists".to_string());
    }
    let (after, snapshot) = pages.saving(&name, wall_secs(), group.clone(), color, Some(alloc.next), &screen);
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

    bound.retain(|(t, _)| !found.gone.contains(t));
    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            open.retain(|p| p.file != file);
            open.push(Open {
                file: file.to_path_buf(),
                name,
                group,
                color,
                next_scrollback: Some(alloc.next),
                pages: after,
                tabs: bound,
                terminals: found.terminals,
                debounce: Debounce::new(),
            });
        }
    });
    state();
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
/// `behind`: the pages that go among `frame`'s tabs are added behind the
/// tab in front there, and nothing is brought in front -- a project the
/// core ordered while the person is on the control room
/// (`rules::ordered_project_tab`). A window made for the project shows its
/// own page, as it would.
///
/// Never called from inside `tabs::run_ops` (`open_page_in_new_tab`).
pub fn open(frame: HWND, app: crate::ffi::App, hinst: windows::Win32::Foundation::HINSTANCE, file: &Path, named: bool, behind: bool) -> Result<(), String> {
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
                    // Behind: shown without being activated (task 1823).
                    let made = if behind { crate::create_frame_secondary_behind(hinst) } else { crate::create_frame_secondary(hinst) };
                    let Some(made) = made else {
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

        // Behind the tab in front of a window that was there already; a
        // window made for the project has no tab of the person's to keep.
        // Behind: the pages take the keyboard from nobody, a window of
        // their own included, which still shows them (task 1835).
        let opening = polter_control_room::rules::project_page_opening(behind, ours);
        let tucked = opening.tab_behind;
        let mut front = None;
        let was_open: Vec<TabId> = bound.iter().map(|(t, _)| *t).collect();
        let mut opened_here: Vec<TabId> = Vec::new();
        for page in missing {
            match crate::project_ui::open_page_in_new_tab(target, app, hinst, &page.tab.root, &snaps, tucked, !opening.takes_keyboard) {
                Ok(tab) => {
                    // The name somebody gave it, back as one (task 1722):
                    // pinned, so the shell's first title does not replace
                    // it -- the same as reopening a closed tab. **Before
                    // the tab is a page** (`bound`, and `OPEN` after the
                    // loop), so no save sees it unnamed; one that did would
                    // keep the file's name anyway (`Live::title`). A
                    // program's title is not put back: it is the program's
                    // to say again, and pinned it would outrank it.
                    if let Some(name) = polter_projects::pages::restored_name(&page.tab) {
                        tabs::rename_tab(target, tab, name.clone(), tabs::NamedBy::Restored);
                        wlogf!(target, "[project] page {} of {:?} is named {:?} again", page.id, snapshot.name, name);
                    }
                    bound.push((tab, page.id));
                    opened_here.push(tab);
                    opened += 1;
                    first.get_or_insert((target, tab));
                    if page.id == window.front {
                        front = Some(tab);
                    }
                }
                Err(e) => errors.push(e),
            }
        }
        // Its pages together (task 1796): the ones just opened go after
        // the last of its pages open in this window already. None of those
        // moves, so a page the person dragged away stays where they put it.
        let order: Vec<TabId> = tabs::strip_snapshot(target).0.into_iter().map(|(t, _)| t).collect();
        if let Some(at) = page_rules::gathered(&order, &was_open, &opened_here) {
            for (k, tab) in opened_here.iter().enumerate() {
                tabs::move_tab_keeping_front(target, *tab, at + k);
            }
            wlogf!(target, "[project] {} page(s) of {:?} just opened go beside the ones open, at {at}", opened_here.len(), snapshot.name);
        }
        // The page that was in front is the one showing.
        if let Some(tab) = front.filter(|_| !tucked) {
            if opening.takes_keyboard {
                tabs::activate_tab(target, tab);
            } else {
                tabs::activate_tab_quietly(target, tab);
            }
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
    // Not gone to when it opened behind: the person stays where they are.
    if let Some((window, tab)) = go.filter(|_| !behind) {
        if opened == 0 {
            tabs::activate_tab(window, tab);
        }
        let _ = unsafe { SetForegroundWindow(window) };
    }
    wlogf!(
        frame,
        "[project] opened {:?}: {} page(s) opened now, {} open in all, of {}{}{}",
        snapshot.name,
        opened,
        bound.len(),
        pages.page_ids().len(),
        if was_open { " (it was open already)" } else { "" },
        if behind { ", behind the tab in front" } else { "" }
    );

    let color = color_of(file, &snapshot);
    OPEN.with(|o| {
        if let Ok(mut open) = o.try_borrow_mut() {
            match open.iter_mut().find(|p| p.file == file) {
                Some(p) => p.tabs = bound,
                None => open.push(Open {
                    file: file.to_path_buf(),
                    name: snapshot.name.clone(),
                    group: snapshot.group.clone(),
                    color,
                    next_scrollback: snapshot.next_scrollback,
                    pages,
                    tabs: bound,
                    terminals: Vec::new(),
                    debounce: Debounce::new(),
                }),
            }
        }
    });
    // Written now rather than when things are still: the core is waiting
    // to hear which terminal is in the supervisor's pane, and a save is
    // what finds that out. No whole-scrollback capture -- nothing has run.
    if opened > 0 {
        if let Err(e) = save(file, false, false) {
            wlogf!(frame, "[project] the save after opening {:?} failed: {}", snapshot.name, e);
        }
    }
    state();
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
    state();
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
    state();
    arm_timer();
}

// ------------------------------------------------------- pages in and out

/// The file of the open project `tab` is a page of.
fn file_of_tab(tab: TabId) -> Option<PathBuf> {
    OPEN.with(|o| o.try_borrow().ok()?.iter().find(|p| p.tabs.iter().any(|(t, _)| *t == tab)).map(|p| p.file.clone()))
}

/// How many pages of `tab`'s project are open besides it: what closing it
/// asks about (`page_rules::close_step`).
pub fn other_pages_open(tab: TabId) -> usize {
    OPEN.with(|o| {
        o.try_borrow()
            .ok()
            .and_then(|o| o.iter().find(|p| p.tabs.iter().any(|(t, _)| *t == tab)).map(|p| p.tabs.len().saturating_sub(1)))
            .unwrap_or(0)
    })
}

/// `tab` becomes one more page of the project in `file`, where its tab is.
/// The project's other pages are not opened by this.
pub fn add_tab(file: &Path, tab: TabId) -> Result<(), String> {
    if let Some(other) = project_of_tab(tab) {
        let w = page_rules::page_of_another_words(&tabs::title_of_tab(tab), &other);
        return Err(w.filled(&crate::i18n::tr(w.msgid)));
    }
    let snapshot = project::read_file(file).map_err(|e| e.to_string())?;
    let color = color_of(file, &snapshot);
    OPEN.with(|o| {
        let Ok(mut open) = o.try_borrow_mut() else { return };
        if !open.iter().any(|p| p.file == file) {
            open.push(Open {
                file: file.to_path_buf(),
                name: snapshot.name.clone(),
                group: snapshot.group.clone(),
                color,
                next_scrollback: snapshot.next_scrollback,
                pages: Pages::from_file(&snapshot),
                tabs: Vec::new(),
                terminals: Vec::new(),
                debounce: Debounce::new(),
            });
        }
        if let Some(p) = open.iter_mut().find(|p| p.file == file) {
            let page = p.pages.new_page_id();
            p.tabs.push((tab, page));
        }
    });
    // With its whole scrollback: this is a save somebody asked for.
    let saved = save(file, false, true);
    state();
    saved
}

/// `tab` stops being a page of its project, and its page is gone from the
/// file; the tab stays open. **Whether it may is asked first, of the core**
/// (`ask_before_taking_out`): this only does it.
pub fn take_out(tab: TabId) -> Result<(), String> {
    let Some(file) = file_of_tab(tab) else { return Ok(()) };
    // The project as it stands, so that what is written is everything but
    // this page -- not everything but this page as of some seconds ago.
    save(&file, false, false)?;
    let left = OPEN.with(|o| {
        let mut open = o.try_borrow_mut().ok()?;
        let p = open.iter_mut().find(|p| p.file == file)?;
        let (_, page) = *p.tabs.iter().find(|(t, _)| *t == tab)?;
        p.pages.remove(page);
        p.tabs.retain(|(t, _)| *t != tab);
        p.terminals.retain(|(id, _)| *id != page);
        let snapshot = project::Snapshot {
            name: p.name.clone(),
            saved_at: wall_secs(),
            group: p.group.clone(),
            color: p.color,
            windows: p.pages.file_windows(),
            next_scrollback: p.next_scrollback,
        };
        let keep = p.pages.scrollback_names();
        let none_open = p.tabs.is_empty();
        if none_open {
            open.retain(|p| p.file != file);
        }
        Some((snapshot, keep, none_open))
    });
    let Some((snapshot, keep, none_open)) = left else { return Ok(()) };
    let written = project::write_file(&file, &snapshot, WriteKind::Save).map_err(|e| e.to_string());
    if written.is_ok() {
        let pruned = project::prune_scrollback_dir(&project::scrollback_dir(&file), &keep);
        // process-wide: a project is tabs of any number of windows
        plogf!(
            "[project] a page was taken out of {:?}: {} page(s) left, {} snapshot(s) removed{}",
            snapshot.name,
            snapshot.tabs().count(),
            pruned,
            if none_open { "; none of it is open now" } else { "" }
        );
    }
    state();
    arm_timer();
    written
}

/// Ask the core whether `tab`'s page may be taken out of its project
/// (`project_remove`, contract 3). `Err` is the sentence to show: the
/// group's supervisor is on the page, or the core's own word for anything
/// else it refuses with.
pub fn ask_before_taking_out(tab: TabId) -> Result<(), String> {
    let Some(file) = file_of_tab(tab) else { return Ok(()) };
    // Any terminal on the page names the page. Asked of the screen, not of
    // what the last save found: the page may have been split since.
    let terminal = tabs::locate_tab(tab)
        .and_then(|(frame, _, _)| crate::project_ui::tab_tree(frame, tab))
        .and_then(|(_, panes)| panes.iter().find_map(crate::project_ui::LeafPane::terminal));
    let Some(terminal) = terminal else { return Ok(()) };
    match crate::control_room_source::act(&stated::remove_question(&terminal)) {
        Ok(()) => Ok(()),
        Err(why) => {
            // process-wide: a project is tabs of any number of windows
            plogf!("[project] taking a page out of {:?} was refused by the core: {}", file, why);
            Err(match why.as_str() {
                "SupervisorPage" => crate::i18n::tr(page_rules::SUPERVISOR_PAGE),
                // A core that has not heard of projects refuses nothing a
                // person asks of their own files.
                "NoApp" | "ProjectsUnknown" | "NoSuchTerminal" => return Ok(()),
                other => other.to_string(),
            })
        }
    }
}

/// Every open tab of the project in `file`, with its window: what "Close
/// Project" closes.
pub fn tabs_of(file: &Path) -> Vec<(HWND, TabId)> {
    let bound: Vec<TabId> =
        OPEN.with(|o| o.try_borrow().ok().and_then(|o| o.iter().find(|p| p.file == file).map(|p| p.tabs.iter().map(|(t, _)| *t).collect())).unwrap_or_default());
    bound.into_iter().filter_map(|t| tabs::locate_tab(t).map(|(f, _, _)| (f, t))).collect()
}

/// The colour of the open project `tab` is a page of, which its project
/// mark is drawn in (task 1796); `None` for a tab of no project. A project
/// is given one when it opens (`color_of`), so `Some(PaneColor::None)` is a
/// file that could not be written and a colour not yet given.
pub fn project_color_of_tab(tab: TabId) -> Option<PaneColor> {
    OPEN.with(|o| o.try_borrow().ok()?.iter().find(|p| p.tabs.iter().any(|(t, _)| *t == tab)).map(|p| p.color))
}

/// The file of the open project `tab` is a page of, and its name.
pub fn project_file_of_tab(tab: TabId) -> Option<(PathBuf, String)> {
    OPEN.with(|o| o.try_borrow().ok()?.iter().find(|p| p.tabs.iter().any(|(t, _)| *t == tab)).map(|p| (p.file.clone(), p.name.clone())))
}

// ------------------------------------------------------- telling the core

/// The colour of the project in `file`: the one it has, or -- it has none
/// -- the one it is given, written into the file there and then (task
/// 1796), so the next host to read it, the mac's included, draws the same
/// colour rather than giving one of its own. Written as a rename is: the
/// same project, not a new version, so `.prev` is left alone. A write that
/// fails is logged and the colour is still used; the next save writes it.
fn color_of(file: &Path, snapshot: &project::Snapshot) -> PaneColor {
    if snapshot.color != PaneColor::None {
        return snapshot.color;
    }
    let color = given_color(file);
    let given = project::Snapshot { color, ..snapshot.clone() };
    match project::write_file(file, &given, WriteKind::Rename) {
        Ok(()) => plogf!("[project] {:?} had no colour and was given {}", snapshot.name, color.name()),
        Err(e) => plogf!("[project] {:?} was given {} but it was not written: {e}", snapshot.name, color.name()),
    }
    color
}

/// The colour a project in `file` is given: the one the other projects
/// beside it use least (`polter_projects::tone::pick`). A file that does
/// not read counts for nothing; it has no colour anybody sees.
fn given_color(file: &Path) -> PaneColor {
    let used: Vec<PaneColor> = file
        .parent()
        .map(|dir| project::list(dir).entries)
        .unwrap_or_default()
        .iter()
        .filter(|e| e.path != file)
        .filter_map(|e| project::read_file(&e.path).ok())
        .map(|s| s.color)
        .collect();
    polter_projects::tone::pick(&used)
}

fn projects_dir() -> Option<PathBuf> {
    project::resolve_state_dir().map(|s| project::default_dir(&s))
}

/// The terminals of each page of `p` that has a tab open, as the last save
/// found them.
fn on_screen(p: &Open) -> Vec<(PageId, Vec<String>)> {
    p.terminals.iter().filter(|(page, _)| p.tabs.iter().any(|(_, id)| id == page)).cloned().collect()
}

/// Every project there is, each as it would be said: an open one from what
/// is open, the rest from their files.
fn everything() -> Vec<(PathBuf, Stated)> {
    everything_and_unreadable().0
}

/// `everything`, and the project files that are there and did not read
/// (task 1807): what `project::list` skipped, and a listed one whose file
/// no longer reads. **Not known is not gone**: they are said to the core,
/// which keeps a group's project while one is there rather than untie it.
fn everything_and_unreadable() -> (Vec<(PathBuf, Stated)>, Vec<String>) {
    let Some(dir) = projects_dir() else { return (Vec::new(), Vec::new()) };
    let listing = project::list(&dir);
    let mut unread: Vec<PathBuf> = listing.skipped.iter().map(|(p, _)| p.clone()).collect();
    let all = listing
        .entries
        .into_iter()
        .filter_map(|e| {
            let showing = OPEN.with(|o| {
                let o = o.try_borrow().ok()?;
                let p = o.iter().find(|p| p.file == e.path)?;
                Some(Stated::of_open(&p.name, p.group.clone(), &p.pages, &on_screen(p)))
            });
            match showing {
                Some(said) => Some((e.path, said)),
                None => match project::read_file(&e.path) {
                    Ok(file) => Some((e.path, Stated::of_closed(&file))),
                    // Gone between the listing and here is gone.
                    Err(project::ReadError::NotFound) => None,
                    Err(_) => {
                        unread.push(e.path);
                        None
                    }
                },
            }
        })
        .collect();
    (all, stated::unreadable(unread.iter().map(PathBuf::as_path)))
}

/// The project files the core was last told could not be read (task 1807).
pub fn unreadable() -> Vec<String> {
    UNREADABLE.with(|u| u.try_borrow().map(|u| u.clone()).unwrap_or_default())
}

// ------------------------------------------- a group's project (task 1714)

/// "Save the Supervisor's Tab as Project “X”" (`project_link_ui`): `chosen`
/// saved as a new project named `group` that names `group` as its group,
/// with `supervisor`'s pane marked the supervisor's -- what the core's
/// `create` does, asked by the person. The file written.
pub fn save_for_group(chosen: &[(HWND, TabId)], group: &str, supervisor: &str) -> Result<PathBuf, String> {
    let dir = projects_dir().ok_or("there is no projects directory")?;
    let file = dir.join(project::sanitize_filename(group).map_err(|_| format!("{group:?} names no file"))?);
    save_as_for(&file, chosen, group.to_string(), WriteKind::Save, Some(Some(group.to_string())))?;
    mark_supervisor(&file, supervisor)?;
    state();
    Ok(file)
}

/// The project in `file` names `group`, and `supervisor`'s pane in it is
/// marked the supervisor's when there is one (task 1714: "As the project of
/// group “X”" ticked in "Save as Project").
pub fn adopt(file: &Path, group: &str, supervisor: Option<&str>) -> Result<(), String> {
    set_group(file, Some(group.to_string()))?;
    if let Some(s) = supervisor {
        mark_supervisor(file, s)?;
    }
    state();
    Ok(())
}

/// "Join and Link": `tab` -- the supervisor's -- becomes a page of the
/// project in `file`, its pane marked the supervisor's. The pages already
/// there stay. **Written in the current format, and what was there kept as
/// the previous version**: a page added is a change of layout, which is
/// what `plan_write` keeps one for (brief 5). The core binds it on its next
/// look.
pub fn join(file: &Path, tab: TabId, supervisor: &str) -> Result<(), String> {
    add_tab(file, tab)?;
    mark_supervisor(file, supervisor)?;
    state();
    Ok(())
}

/// "Replace…", asked twice: the project in `file` is `chosen` now, under
/// `name`, what it was kept as the previous version (`Overwrite` keeps it
/// always), `supervisor`'s pane marked the supervisor's.
pub fn replace(file: &Path, chosen: &[(HWND, TabId)], name: &str, supervisor: &str) -> Result<(), String> {
    save_as(file, chosen, name.to_string(), WriteKind::Overwrite)?;
    mark_supervisor(file, supervisor)?;
    state();
    Ok(())
}

/// The project in `file` is called `to`, as the person said (renaming one
/// out of a group's way): the core is asked first, as for any rename.
pub fn rename_project(file: &Path, to: &str) -> Result<(), String> {
    let from = project::read_file(file).map_err(|e| e.to_string())?.name;
    match ask_before_renaming(&from, to, None) {
        Ok(true) => rename_to(file, to)?,
        Ok(false) => {}
        Err(why) => return Err(why),
    }
    state();
    Ok(())
}

/// Undoing the core's `bind`: the project in `file` names no group, and is
/// called `to` again -- the name it had.
pub fn unbind(file: &Path, to: &str) -> Result<(), String> {
    set_group(file, None)?;
    let name = project::read_file(file).map_err(|e| e.to_string())?.name;
    if name != to {
        rename_to(file, to)?;
    }
    state();
    Ok(())
}

/// Undoing a project made for a group, first step after "no project": its
/// open tabs stop being its pages and **nothing is written** -- a save now
/// would put the tabs over the file that is about to be moved or put back.
/// The tabs stay open.
pub fn let_go(file: &Path) -> Result<(), String> {
    forget(file);
    state();
    Ok(())
}

/// Undoing "Join and Link" or "Replace…": the project in `file` is what it
/// was before, byte for byte -- the previous version the join's or the
/// replace's own write kept. Its tabs were let go first (`let_go`).
pub fn restore_previous(file: &Path) -> Result<(), String> {
    polter_settings_shell::projects::restore_previous(file).map_err(|e| e.to_string())?;
    state();
    Ok(())
}

/// One project as the group's "Project ›" menu, the banner and the
/// confirmation need it (task 1714): what the core does not say -- whose it
/// is, how many pages, when it was saved -- read from the same list the core
/// is told.
#[derive(Clone, Debug, PartialEq)]
pub struct Known {
    pub name: String,
    pub group: Option<String>,
    pub pages: usize,
    pub saved_at: i64,
    pub path: PathBuf,
}

/// Every project there is, in the order `project::list` found them.
pub fn known() -> Vec<Known> {
    let Some(dir) = projects_dir() else { return Vec::new() };
    let saved: Vec<(PathBuf, i64)> = project::list(&dir).entries.into_iter().map(|e| (e.path, e.saved_at)).collect();
    everything()
        .into_iter()
        .map(|(path, said)| Known {
            saved_at: saved.iter().find(|(p, _)| *p == path).map_or(0, |(_, t)| *t),
            name: said.name,
            group: said.group,
            pages: said.pages,
            path,
        })
        .collect()
}

/// Tell the core what projects there are and which are open: all of it,
/// every time (contract 3). Said again only when it would say something
/// else, so it is called wherever anything about a project may have changed
/// and costs a directory listing when nothing did.
///
/// A statement the core would refuse is not sent (`stated::refusal`): the
/// one it has goes on standing, and the log says which project and why.
pub fn state() {
    watch_the_directory();
    let (all, unreadable) = everything_and_unreadable();
    let list: Vec<Stated> = all.into_iter().map(|(_, said)| said).collect();
    if let Some(why) = stated::refusal(&list) {
        // process-wide: a project is tabs of any number of windows
        plogf!("[project] NOT stated: the core would refuse it: {:?}", why);
        return;
    }
    let text = stated::statement(&list, &unreadable);
    if STATED.with(|s| s.try_borrow().is_ok_and(|s| s.as_deref() == Some(text.as_str()))) {
        return;
    }
    match crate::control_room_source::act(&text) {
        Ok(()) => {
            // process-wide: a project is tabs of any number of windows
            plogf!(
                "[project] stated {} project(s), {} open, {} with a supervisor's terminal",
                list.len(),
                list.iter().filter(|p| p.open.is_some()).count(),
                list.iter().filter(|p| p.supervisor.is_some()).count()
            );
            if !unreadable.is_empty() {
                // process-wide: a project is tabs of any number of windows
                plogf!("[project] said {} project file(s) do not read: {}", unreadable.len(), unreadable.join(", "));
            }
            UNREADABLE.with(|u| {
                if let Ok(mut u) = u.try_borrow_mut() {
                    *u = unreadable;
                }
            });
            STATED.with(|s| {
                if let Ok(mut s) = s.try_borrow_mut() {
                    *s = Some(text);
                }
            });
        }
        // process-wide: a project is tabs of any number of windows
        Err(why) => plogf!("[project] the statement was not taken: {}", why),
    }
}

/// A snapshot arrived, and this is what it says about projects. The first
/// one is when the core is first told anything; every one's orders are
/// looked at, a moment later and off this call's stack -- doing one opens
/// windows and tabs, and the snapshot's reader is not the place for that.
pub fn told(told: &Told) {
    if STATED.with(|s| s.try_borrow().is_ok_and(|s| s.is_none())) {
        state();
    }
    // An order the core has stopped asking can be acted on afresh if it
    // ever asks again.
    TRIED.with(|t| {
        if let Ok(mut t) = t.try_borrow_mut() {
            t.retain(|o| told.orders.contains(o));
        }
    });
    let fresh: Vec<Order> = TRIED.with(|t| t.try_borrow().map(|t| told.orders.iter().filter(|o| !t.contains(o)).cloned().collect()).unwrap_or_default());
    let any = !fresh.is_empty();
    ORDERS.with(|o| {
        if let Ok(mut o) = o.try_borrow_mut() {
            *o = fresh;
        }
    });
    if any && ORDERS_TIMER.with(Cell::get) == 0 {
        let id = unsafe { SetTimer(None, 0, 10, Some(orders_timer)) };
        ORDERS_TIMER.with(|t| t.set(id));
    }
}

/// How often the projects directory is looked at (task 1830).
const WATCH_MS: u32 = 2_000;

/// The directory as `stated::directory_fingerprint` sees it: a listing and
/// a stat per file, nothing decoded.
fn directory_now() -> Vec<String> {
    let Some(dir) = projects_dir() else { return Vec::new() };
    let Ok(read) = std::fs::read_dir(&dir) else { return Vec::new() };
    let files: Vec<(String, u64, u64)> = read
        .filter_map(Result::ok)
        .filter_map(|e| {
            let meta = e.metadata().ok()?;
            let ms = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_millis() as u64;
            Some((e.file_name().to_string_lossy().into_owned(), meta.len(), ms))
        })
        .collect();
    polter_projects::stated::directory_fingerprint(&files)
}

/// Start looking at the projects directory, once: the first statement is
/// when there is a core to tell.
fn watch_the_directory() {
    if WATCH_TIMER.with(Cell::get) != 0 {
        return;
    }
    DIRECTORY.with(|d| {
        if let Ok(mut d) = d.try_borrow_mut() {
            *d = Some(directory_now());
        }
    });
    let id = unsafe { SetTimer(None, 0, WATCH_MS, Some(directory_timer)) };
    // not-gated: the condition is the event -- without the timer a file
    // fixed by hand is noticed only at the next change of ours.
    if id == 0 {
        // process-wide: one projects directory for the process
        plogf!("[project] SetTimer failed; a project file changed by hand is noticed at the next change only");
        return;
    }
    WATCH_TIMER.with(|t| t.set(id));
}

unsafe extern "system" fn directory_timer(_: HWND, _: u32, _: usize, _: u32) {
    let now = directory_now();
    let changed = DIRECTORY.with(|d| match d.try_borrow_mut() {
        Ok(mut d) if d.as_ref() != Some(&now) => {
            *d = Some(now);
            true
        }
        _ => false,
    });
    if changed {
        // process-wide: one projects directory for the process
        plogf!("[project] the projects directory changed; stating the projects again");
        state();
    }
}

unsafe extern "system" fn orders_timer(_: HWND, _: u32, id: usize, _: u32) {
    let _ = unsafe { KillTimer(None, id) };
    ORDERS_TIMER.with(|t| t.set(0));
    obey();
}

/// A terminal window to open things in: the one in front if it is one of
/// ours, else any.
fn some_frame() -> Option<HWND> {
    let all = crate::winid::all();
    let front = unsafe { windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow() };
    all.iter().copied().find(|f| *f == front).or_else(|| all.first().copied())
}

fn hinst() -> windows::Win32::Foundation::HINSTANCE {
    unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }.map(Into::into).unwrap_or_default()
}

/// Do what the core asked, each order once for as long as it is asked
/// (contract 4). What an order still asks, given how things stand, is
/// `orders::step`; this carries the answer out and says so in the log.
fn obey() {
    let pending: Vec<Order> = ORDERS.with(|o| o.try_borrow_mut().map(|mut o| std::mem::take(&mut *o)).unwrap_or_default());
    for order in pending {
        // Looked up afresh for each: the one before may have made, moved
        // or opened a project.
        let all = everything();
        let have: Vec<Have> = all
            .iter()
            .map(|(_, p)| Have {
                name: p.name.clone(),
                group: p.group.clone(),
                terminals: p.open.iter().flatten().flatten().cloned().collect(),
                open: p.open.is_some(),
                supervisor: p.supervisor.clone(),
            })
            .collect();
        let file_of = |name: &str| all.iter().find(|(_, p)| p.name == name).map(|(f, _)| f.clone());
        let step = orders::step(&order, &have, &|t| tabs::tab_of_terminal(t).is_some());
        let done: Result<(), String> = match &step {
            Step::Nothing(why) => {
                // process-wide: a project is tabs of any number of windows
                plogf!("[project] order {:?} for {:?}: nothing to do ({})", order.kind, order.project, why);
                continue;
            }
            Step::Missing { project } => crate::control_room_source::act(&stated::failed(project, FailedWhy::NotFound)),
            Step::Open { project } => match (file_of(project), some_frame()) {
                (Some(file), frame) => {
                    // The first window of it goes among the tabs of the
                    // window the person is in, whatever frame it recorded:
                    // they asked for it from there. **With the control
                    // room in front, into its window and behind it**
                    // (`rules::ordered_project_tab`): this is a supervisor's
                    // start, the application's own tab (#1703).
                    use polter_control_room::rules::{ordered_project_tab, NewTab as To};
                    let facts = tabs::new_tab_facts();
                    let (frame, behind) = match (ordered_project_tab(facts.control_room.is_some(), facts.tabs_beside, facts.any_terminal_window), facts.control_room) {
                        (To::Behind(_), Some(room)) => (room, true),
                        // The core's order, with the control room not in
                        // front: the window in front, still behind (task 1823).
                        (To::Behind(_), None) => (frame.unwrap_or_default(), true),
                        _ => (frame.unwrap_or_default(), false),
                    };
                    let opened = open(frame, crate::app_handle(), hinst(), &file, true, behind);
                    if opened.is_err() && project::read_file(&file).is_err() {
                        let _ = crate::control_room_source::act(&stated::failed(project, FailedWhy::Unreadable));
                    }
                    opened
                }
                (None, _) => Err("its file was not found".to_string()),
            },
            Step::Create { name, group, terminal } => match (projects_dir(), tabs::tab_of_terminal(terminal)) {
                (Some(dir), Some((frame, tab))) => project::sanitize_filename(name)
                    .map_err(|_| format!("{name:?} names no file"))
                    .and_then(|file| {
                        let file = dir.join(file);
                        save_as_for(&file, &[(frame, tab)], name.clone(), WriteKind::Save, Some(group.clone()))?;
                        mark_supervisor(&file, terminal)
                    }),
                _ => Err("no projects directory, or the terminal is gone".to_string()),
            },
            Step::Bind { project, group, terminal, to } => match file_of(project) {
                Some(file) => set_group(&file, Some(group.clone()))
                    .and_then(|()| match terminal {
                        Some(t) => mark_supervisor(&file, t),
                        None => Ok(()),
                    })
                    .and_then(|()| match to {
                        Some(to) => rename_to(&file, to),
                        None => Ok(()),
                    }),
                None => Err("its file was not found".to_string()),
            },
            Step::SetGroup { project, group } => match file_of(project) {
                Some(file) => set_group(&file, group.clone()),
                None => Err("its file was not found".to_string()),
            },
            Step::Rename { from, to } => match file_of(from) {
                Some(file) => rename_to(&file, to),
                None => Err("its file was not found".to_string()),
            },
            Step::AddTab { project, terminal } => match (file_of(project), tabs::tab_of_terminal(terminal)) {
                (Some(file), Some((_, tab))) => add_tab(&file, tab),
                _ => Err("its file was not found, or the terminal is gone".to_string()),
            },
            // Task 1794: the supervisor's pane follows the group's supervisor.
            Step::Seat { project, terminal, join_tab } => match (file_of(project), tabs::tab_of_terminal(terminal)) {
                (Some(file), Some((_, tab))) => (if *join_tab { add_tab(&file, tab) } else { Ok(()) })
                    .and_then(|()| mark_supervisor(&file, terminal)),
                _ => Err("its file was not found, or the terminal is gone".to_string()),
            },
        };
        // process-wide: a project is tabs of any number of windows
        plogf!("[project] order {:?} for {:?} -> {:?}: {}", order.kind, order.project, step, done.as_ref().map_or_else(|e| format!("FAILED: {e}"), |()| "done".to_string()));
        // A project made for a group by the core's own doing is said, with
        // an Undo (task 1714, `project-link-interface.md` §3.2).
        if done.is_ok() {
            if let Some((group, made)) = made_by(&step, projects_dir().as_deref()) {
                crate::project_link_ui::made_for(&group, made);
            }
        }
        TRIED.with(|t| {
            if let Ok(mut t) = t.try_borrow_mut() {
                t.push(order);
            }
        });
    }
    state();
}

/// What a `create` or a `bind` that was done made, for the line that says
/// so: the group, and what undoing it needs. None for any other order.
fn made_by(step: &Step, dir: Option<&Path>) -> Option<(String, polter_control_room::project_words::Made)> {
    use polter_control_room::project_words::Made;
    let path = |name: &str| dir.and_then(|d| project::sanitize_filename(name).ok().map(|f| d.join(f).to_string_lossy().into_owned()));
    match step {
        Step::Create { name, group: Some(group), .. } => Some((group.clone(), Made::Created { name: name.clone(), path: path(name)? })),
        Step::Bind { project, group, to, .. } => {
            let now = to.clone().unwrap_or_else(|| project.clone());
            Some((group.clone(), Made::Renamed { from: project.clone(), path: path(&now)?, to: now }))
        }
        _ => None,
    }
}

/// The file's group becomes `group` (none: it names none). An open project
/// is written as it stands with the new group; a closed one has only that
/// changed in its file.
fn set_group(file: &Path, group: Option<String>) -> Result<(), String> {
    let is_open = OPEN.with(|o| {
        let Ok(mut open) = o.try_borrow_mut() else { return false };
        match open.iter_mut().find(|p| p.file == file) {
            Some(p) => {
                p.group = group.clone();
                true
            }
            None => false,
        }
    });
    if is_open {
        return save(file, false, false);
    }
    let mut snapshot = project::read_file(file).map_err(|e| e.to_string())?;
    snapshot.group = group;
    project::write_file(file, &snapshot, WriteKind::Save).map_err(|e| e.to_string())
}

/// The project in `file` is `color` from now on (task 1796, the settings
/// window's colour line). An open project is written as it stands with the
/// new colour, and the strips its tabs are on are drawn again; a closed one
/// has only that changed in its file. Written as a rename is: the same
/// project, not a new version.
pub fn set_color(file: &Path, color: PaneColor) -> Result<(), String> {
    let tabs: Option<Vec<TabId>> = OPEN.with(|o| {
        let mut open = o.try_borrow_mut().ok()?;
        let p = open.iter_mut().find(|p| p.file == file)?;
        p.color = color;
        Some(p.tabs.iter().map(|(t, _)| *t).collect())
    });
    let Some(tabs) = tabs else {
        let snapshot = project::read_file(file).map_err(|e| e.to_string())?;
        return project::write_file(file, &project::Snapshot { color, ..snapshot }, WriteKind::Rename).map_err(|e| e.to_string());
    };
    for frame in tabs.into_iter().filter_map(|t| tabs::locate_tab(t).map(|(f, _, _)| f)) {
        unsafe {
            let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(frame), None, false);
        }
    }
    save(file, false, false)
}

/// The pane `terminal` is in becomes the supervisor's pane of the open
/// project in `file`, and no other pane of it is.
fn mark_supervisor(file: &Path, terminal: &str) -> Result<(), String> {
    // A save first: it is what names the pane and finds its terminal.
    save(file, false, false)?;
    let marked = OPEN.with(|o| {
        let mut open = o.try_borrow_mut().ok()?;
        let p = open.iter_mut().find(|p| p.file == file)?;
        let (page, at) = p.terminals.iter().find_map(|(page, on)| on.iter().position(|t| t == terminal).map(|at| (*page, at)))?;
        let name = project::leaves(&p.pages.page(page)?.tab.root).get(at)?.scrollback.clone();
        Some(p.pages.mark_supervisor(&name))
    });
    match marked {
        Some(true) => save(file, false, false),
        _ => Err(format!("the terminal {terminal} is in no pane of it that has a name")),
    }
}

/// The project in `file` is called `to` from now on: its file, its
/// snapshots and its previous version move, and its open tabs follow.
fn rename_to(file: &Path, to: &str) -> Result<(), String> {
    let dir = file.parent().ok_or("the project file has no directory")?;
    let target = dir.join(project::sanitize_filename(to).map_err(|_| format!("{to:?} names no file"))?);
    polter_settings_shell::projects::move_project(file, &target).map_err(|e| e.to_string())?;
    project::set_name(&target, to)?;
    moved(file, &target, to);
    Ok(())
}

/// Ask the core before the project called `from` is renamed `to`
/// (`project_rename`, contract 3). `Ok(true)`: go on and rename it.
/// `Ok(false)`: the core has taken it from here -- the project is a group's,
/// the group is being renamed, and the rename comes back as an order.
/// `Err` is the core's word for why not.
pub fn ask_before_renaming(from: &str, to: &str, group: Option<&str>) -> Result<bool, String> {
    match crate::control_room_source::act(&stated::rename_question(from, to)) {
        Ok(()) => Ok(group.is_none()),
        // A core that has not heard of projects has no group to rename.
        Err(why) if why == "NoApp" || why == "ProjectsUnknown" => Ok(true),
        Err(why) => Err(why),
    }
}
