//! Orchestration between the live tab model (`tabs.rs`) and the saved-project
//! format (`project.rs`). **Deliberately no UI in this file.**
//!
//! `prompt.rs` (a native text-input popup) and `palette.rs` (a native
//! filtered list) are the closest existing things to "ask for a project
//! name" and "pick a saved project" respectively, but both are tightly
//! coupled to dispatching a core keybind action on accept, both carry the
//! densest history of TSF-focus and IME-handoff bugs in this codebase, and
//! neither can be visually verified from the machine this file is being
//! written on. Extending either one blind, with no way to see whether a box
//! actually opens in the right place or steals focus correctly, is exactly
//! the kind of change this codebase's own `AGENTS.md`/task history warns
//! about -- so the three UI entry points (Save as Project / Load Project /
//! Manage Projects) and the close-flow integration are tracked separately,
//! for a session with real-machine access.
//!
//! **Since task 1496 a project is every tab it holds, in every window.**
//! What is here is one tab's worth of each direction -- a live tab into a
//! saved tree (`tab_tree`, `name_leaves`), a saved tree into a new tab
//! (`open_page_in_new_tab`) -- and saving chosen tabs as a project
//! (`save_tabs_as`). Which open tab is which page, saving as things change
//! and opening a whole project are `project_session.rs`; the rules they
//! follow are `polter-projects`.
//!
//! What lives here is everything about task 533 that *is* verifiable without
//! a screen: turning a live tab into a saved tree (`tab_tree`,
//! `name_leaves`) and turning a saved page into the JSON the existing
//! `poltergeist_layout` pipeline already knows how to build a tab from
//! (`shape_for_page`).

use windows::Win32::Foundation::HWND;

use crate::wlogf;
use crate::project::{self, Agent, SavedLeaf, SavedNode};
use crate::tabs::{self, TabId};

/// Build a `Snapshot` from a live tab. `None` if the tab (or its window) is
/// gone by the time this runs -- callers are expected to be reacting to a
/// user gesture on a specific tab, so this should be rare, not a state to
/// design a retry around.
///
/// **`history` on a leaf can legitimately still be empty** -- history
/// capture is off by default (`Config.ShellIntegrationFeatures`), so a pane
/// that never had it on never got a `history_filename` action at all. That
/// is a real, silent, *correct* empty string, same as `Project.zig`'s own
/// `Leaf.history` default -- unlike the gap this function used to have
/// before `ACTION_HISTORY_FILENAME` was wired (`tabs::history_of_pane`),
/// where the field was empty for a reason nobody could ask about. See
/// `name_leaves`'s doc comment for how those two "empty" cases are told
/// apart now (an apprt-side count, not just a hope that a log line was
/// read).
///
/// **Reads every pane's metadata out of the same borrow that finds the
/// tree, and does not call `tabs::cwd_of_pane`/`title_of_pane`/
/// `history_of_pane`.** Those three each take `tabs::with_windows`'s lock
/// themselves; calling any of them from inside the closure below -- which
/// already holds that lock to find `tab` in the first place -- is the same
/// non-reentrant-mutex-taken-twice shape `tabs.rs` has warned about at
/// several of its own call sites (see `create_tab_with`'s comment on
/// `take_id`/`take_pending_cwd`). A real run of this exact bug produced
/// a `[state] DEADLOCK` line: the `with_windows` call in `tabs.rs`'s
/// `cwd_of_pane` waited 5s, and the holder was the `with_windows` call at
/// the top of this function -- caught by the host's own watchdog rather
/// than hanging silently, but a bug regardless. Building `meta` from
/// `tab.panes` directly, while still inside the one borrow, is the fix.
///
/// **Also returns the pane behind every leaf** (`LeafPane`), in the order
/// `project::leaves_mut` walks them -- collected in the same borrow, by the
/// same `describe` walk, so position `n` in the list is leaf `n` of the tree
/// and no second walk has to agree with the first. A leaf whose pane was not
/// found gets a default `LeafPane` (surface `0`), and its metadata is the
/// default too.
///
/// **Nothing is asked of the core in here.** The surfaces come out so that
/// `name_leaves` can make its capture calls after this lock is released;
/// the deadlock described above is what calling out from inside it has
/// already cost once.
pub(crate) fn tab_tree(frame: HWND, id: TabId) -> Option<(SavedNode, Vec<LeafPane>)> {
    tabs::with_windows(|ws| {
        let win = ws.iter().find(|w| w.frame == frame.0 as isize)?;
        let tab = win.tabs.iter().find(|t| t.id == id)?;
        // A project is a terminal tab's split tree. The control room has
        // none, and saving it is not offered; asked anyway, there is
        // nothing to save.
        let tree = &tab.terminal()?.tree;
        let meta: std::collections::HashMap<polter_split_tree::PaneId, (SavedLeaf, LeafPane)> = tab
            .panes()
            .iter()
            .map(|p| {
                (
                    p.id,
                    (
                        SavedLeaf {
                            cwd: p.cwd.clone().unwrap_or_default(),
                            // What the pane showed: the program's title,
                            // written as that and never put back (issue #9).
                            title: p.title.clone().unwrap_or_default(),
                            // **Always false here.** This host has no name
                            // per pane: an explicit `set_surface_title`
                            // pins the pane's whole *tab*
                            // (`tabs::Op::SetTabTitle`, `NamedBy::Tool`),
                            // so a chosen name is the tab's and is written
                            // as the tab's (`project_session::screen_of`).
                            // A pane title macOS chose comes back on this
                            // host as its tab's name when it is the only one
                            // in the tab (`polter_projects::pages::
                            // restored_name`); the next save here writes it
                            // there, not on the pane.
                            title_chosen: false,
                            history: p.history.clone().unwrap_or_default(),
                            // Named by `name_leaves`, from the pane's own
                            // slot; empty until then.
                            scrollback: String::new(),
                            by_supervisor: false,
                            // The seat where this pane's own mark says the
                            // supervisor is, and "cannot tell" elsewhere:
                            // the file's seat stands until a supervisor is
                            // somewhere (`polter_projects::pages`'s
                            // `one_seat`, `pane-color-interface.md` §7.1).
                            supervisor_seat: p.marks.supervisor.then_some(true),
                            // `None` while the pane waits for its hand-back:
                            // the save keeps the file's word (task 1700).
                            color: p.marks.color,
                            workers: p.marks.workers,
                            shielded: p.shielded,
                            // **Not known, which is not "nobody"**, until
                            // the core is asked: that is done after this
                            // lock is let go (`project_session::screen_of`,
                            // task 1800). A pane it cannot say stays this,
                            // and the file's word is kept.
                            agent: Agent::Unknown,
                        },
                        LeafPane { pane: p.id, surface: p.surface, slot: p.scrollback.as_ref().map(|j| j.slot().clone()) },
                    ),
                )
            })
            .collect();
        let order = std::cell::RefCell::new(Vec::new());
        let root = project::describe(tree, &|id| {
            let (leaf, pane) =
                meta.get(&id).cloned().unwrap_or_else(|| (SavedLeaf::plain("", Agent::Unknown), LeafPane::default()));
            order.borrow_mut().push(pane);
            leaf
        })?;
        Some((root, order.into_inner()))
    })
}

/// The pane behind one leaf of a tree being saved.
#[derive(Clone, Debug, Default)]
pub(crate) struct LeafPane {
    pane: polter_split_tree::PaneId,
    surface: usize,
    slot: Option<project::Slot>,
}

impl LeafPane {
    /// The terminal in this pane, as the core names it; none for a pane
    /// that has no surface yet.
    pub(crate) fn terminal(&self) -> Option<String> {
        if self.surface == 0 {
            return None;
        }
        let id = unsafe { (crate::api().surface_poltergeist_id)(self.surface as crate::ffi::Surface) };
        Some(polter_control_room::rules::key(id))
    }
}

/// Name every leaf's snapshot **by its pane**, ask the core to write each one,
/// and give each pane its slot to keep. See `project::Allocator` for why the
/// name belongs to the pane and never to the leaf's position.
///
/// **A leaf is named even when the capture is refused**, as macOS does: the
/// name is the pane's for life, and a name whose file never lands reads back
/// as "no scrollback" -- the core opens an empty terminal -- which is today's
/// behaviour anyway.
///
/// **Not waited for.** `true` from the core means the request reached the
/// pane's IO thread, not that the file exists; the JSON names the file it
/// *will* be (`dev-docs/project-scrollback.md` §3.2). The core also finishes
/// queued captures before `ghostty_surface_free` returns, so closing right
/// after saving does not lose them.
///
/// `capture` is whether the core is asked to write each pane's whole
/// scrollback now. A save somebody asked for does; one made as things
/// change does not -- it is up to the configured limit per pane and such a
/// save follows every divider that is dragged -- and relies on the journal
/// this starts for any pane that has none yet.
pub(crate) fn name_leaves(
    frame: HWND,
    root: &mut SavedNode,
    panes: &[LeafPane],
    snaps: &std::path::Path,
    alloc: &mut project::Allocator,
    capture: bool,
) {
    let leaves = project::leaves_mut(root);
    if leaves.len() != panes.len() {
        // Cannot happen while both come from one `describe` walk; if it
        // does, pairing them by position could give one pane another's
        // snapshot, so nothing is named at all.
        wlogf!(frame, "[project] capture skipped: {} leaves but {} panes", leaves.len(), panes.len());
        return;
    }
    if let Err(e) = std::fs::create_dir_all(snaps) {
        wlogf!(frame, "[project] capture skipped: cannot create {:?}: {}", snaps, e);
        return;
    }
    for (leaf, p) in leaves.into_iter().zip(panes) {
        if p.surface == 0 {
            continue;
        }
        let name = alloc.name_for(snaps, p.slot.as_ref());
        leaf.scrollback = name.clone();
        // Journaled from here on, so what the pane prints after this save
        // is on disk too -- and asked before the capture below, which then
        // rewrites the journal in place rather than a file beside it.
        // Outside the window lock: `journal::start` calls into the core.
        let journaled = crate::journal::start(p.pane, p.surface, project::Slot { dir: snaps.to_path_buf(), name: name.clone() });
        tabs::set_scrollback_slot(frame, p.pane, journaled);
        if !capture {
            continue;
        }
        let Some(abs) = snaps.join(&name).to_str().and_then(|s| std::ffi::CString::new(s).ok()) else {
            wlogf!(frame, "[project] capture {}: {:?} is not a UTF-8 path the core can take", name, snaps);
            continue;
        };
        // Written before the call: the capture queues onto the IO
        // thread's mailbox and waits for room when it is full, so this line
        // being the last one is what that wait would look like.
        wlogf!(frame, "[project] capture pane {} -> {} via ghostty_surface_capture_scrollback(0x{:x}) …", p.pane, name, p.surface);
        let ok = unsafe { (crate::api().surface_capture_scrollback)(p.surface as crate::ffi::Surface, abs.as_ptr()) };
        if !ok {
            wlogf!(frame, "[project] capture {}: the core refused it; the leaf keeps the name, its file is not written", name);
        }
    }
}

/// Number of leaves in a saved tree. Used by the save's log line and by
/// the "you are about to overwrite N-pane project saved at T" confirmation a
/// UI shows before replacing an existing name -- **on the *existing on-disk*
/// project being overwritten**, read fresh with `project::read`, never on the
/// live tab that is about to replace it; those are two different pane counts
/// and confirming with the wrong one tells the person the wrong thing about
/// what they are about to lose.
pub fn leaf_count(node: &SavedNode) -> usize {
    match node {
        SavedNode::Leaf(_) => 1,
        // Every terminal of a stack is one the person has.
        SavedNode::Stack { members, .. } => members.len(),
        SavedNode::Split { left, right, .. } => leaf_count(left) + leaf_count(right),
    }
}

/// How many leaves have no history handle. **A legitimate, expected number
/// for most saves** now that `ACTION_HISTORY_FILENAME` is wired
/// (`tabs::history_of_pane`): history capture is off by default
/// (`Config.ShellIntegrationFeatures`), so a pane that never turned it on
/// never gets a handle, and that is not a defect in this file or in core.
/// Kept as an independently-checkable fact (not just a log line) for the
/// same reason it was written the first time, before the channel existed:
/// a discoverable count survives longer than a person happening to be
/// watching the log at the moment a save happens.
pub fn missing_history_count(node: &SavedNode) -> usize {
    match node {
        SavedNode::Leaf(leaf) => {
            if leaf.history.is_empty() {
                1
            } else {
                0
            }
        }
        SavedNode::Stack { members, .. } => members.iter().filter(|m| m.history.is_empty()).count(),
        SavedNode::Split { left, right, .. } => missing_history_count(left) + missing_history_count(right),
    }
}

/// **The one place "does closing this tab offer to save as a project"
/// gets decided.** Today that is exactly "would the plain kill-warning have
/// fired" (`tabs::dialogs_for`'s condition) -- the person has not confirmed
/// "always offer, even for an idle tab" yet (see the windows-port
/// discussion). If that changes, this is the only line that needs to.
///
/// Asked by `tabs::close_tab_asking` and `close_all_tabs_of_asking` (a window
/// of one tab) since settings.md §6.3; the rule itself is
/// `polter_settings_shell::projects::offers_save_before_close`, whose tests
/// run off Windows.
pub fn should_offer_save_as_project(tab_needs_confirmation: bool) -> bool {
    polter_settings_shell::projects::offers_save_before_close(1, tab_needs_confirmation)
}

/// Save the given tabs as the project `name`: **the project is those tabs
/// and nothing else**, each a page, in the order given and in the windows
/// they are in now (v20, rule 6). A project that already has that name is
/// replaced by them -- what it held is kept as the previous version when
/// `kind` says so, which for a name that is taken it always does
/// (`projects_ui::save_as_plan`) -- except its group, which stays: the
/// group's own file says which project is its, and a project that dropped
/// the word would be unbound behind the group's back.
///
/// The tabs are then pages of that project for as long as they are open
/// (`project_session`), and it is saved as they change.
///
/// The caller (whichever UI asked for the name) is responsible for telling
/// the person the result; this only reports success/failure as a value.
pub fn save_tabs_as(dir: &std::path::Path, tabs_to_save: &[(HWND, TabId)], name: String, kind: project::WriteKind) -> Result<(), String> {
    let file = project::path_for(dir, &name)
        .map_err(|_| format!("{name:?} has nothing left once sanitized, so no file can be named after it"))?;
    crate::project_session::save_as(&file, tabs_to_save, name, kind)
}

/// One tab saved as a project: what "Save as Project" does until its window
/// lists the tabs to tick, and what "Overwrite with Current Tab" is.
pub fn write_tab_as(dir: &std::path::Path, frame: HWND, id: TabId, name: String, kind: project::WriteKind) -> Result<(), String> {
    save_tabs_as(dir, &[(frame, id)], name, kind)
}

/// "Overwrite with Current Tab" (settings.md §6.2): a save, except that
/// **what it replaces is always kept as the previous version**, as the
/// confirmation promised -- the save's rule keeps it only on a layout change,
/// and one pane over one pane then lost it (39ae3f040).
pub fn overwrite_project(dir: &std::path::Path, frame: HWND, id: TabId, name: String) -> Result<(), String> {
    write_tab_as(dir, frame, id, name, project::WriteKind::Overwrite)
}

// ---------------------------------------------------------------------
// What a person does to a page from a menu
// ---------------------------------------------------------------------

/// The things the `Project` menu and a tab's own menu do to a page that
/// take a moment or a question (`page_rules::Item` has the rest).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageAct {
    AddTo,
    TakeOut,
    Rename,
    CloseProject,
}

impl PageAct {
    fn item(self) -> polter_projects::page_rules::Item {
        use polter_projects::page_rules::Item;
        match self {
            PageAct::AddTo => Item::AddTo,
            PageAct::TakeOut => Item::TakeOut,
            PageAct::Rename => Item::Rename,
            PageAct::CloseProject => Item::CloseProject,
        }
    }
}

/// Whether `act` can be chosen for tab `id` (`page_rules::offered`): the
/// three that act on a project need the tab to be a page of one, and
/// "Add to Project" needs it to be a page of none.
pub fn page_act_offered(act: PageAct, id: Option<TabId>) -> bool {
    let Some(id) = id else { return false };
    polter_projects::page_rules::offered(act.item(), crate::project_session::project_of_tab(id).as_deref())
}

thread_local! {
    static ASKED: std::cell::RefCell<Vec<(isize, TabId, PageAct)>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Do `act` to tab `id` of `frame`. **Returns at once**: each of these
/// opens a window or asks a question, which runs a message loop, and a menu
/// row is also performed by the menu's self-test -- so it is done from the
/// thread's own loop, a moment later (`project_picker::request_load` has
/// the same reason).
pub fn request_page_act(frame: HWND, id: TabId, act: PageAct) -> bool {
    use windows::Win32::UI::WindowsAndMessaging::SetTimer;
    ASKED.with(|a| a.borrow_mut().push((frame.0 as isize, id, act)));
    let timer = unsafe { SetTimer(None, 0, 0, Some(page_act_timer)) };
    // not-gated: the condition is the event -- the timer was refused, and
    // without this line a click that did nothing would leave no trace.
    if timer == 0 {
        ASKED.with(|a| a.borrow_mut().clear());
        wlogf!(frame, "[project] SetTimer failed; {:?} for tab {:?} was not done", act, id);
        return false;
    }
    true
}

unsafe extern "system" fn page_act_timer(_: HWND, _: u32, id: usize, _: u32) {
    let _ = unsafe { windows::Win32::UI::WindowsAndMessaging::KillTimer(None, id) };
    let asked = ASKED.with(|a| std::mem::take(&mut *a.borrow_mut()));
    for (frame, tab, act) in asked {
        page_act(HWND(frame as *mut core::ffi::c_void), tab, act);
    }
}

fn tell(frame: HWND, text: &str) {
    use windows::core::PCWSTR;
    use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONINFORMATION, MB_OK};
    let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() };
    let (title, body) = (wide(&crate::i18n::tr("Polter")), wide(text));
    unsafe {
        MessageBoxW(Some(frame), PCWSTR(body.as_ptr()), PCWSTR(title.as_ptr()), MB_OK | MB_ICONINFORMATION);
    }
}

fn page_act(frame: HWND, id: TabId, act: PageAct) {
    use crate::i18n::tr;
    use polter_projects::page_rules as rules;
    // Asked again now: the menu was drawn a moment ago.
    if !page_act_offered(act, Some(id)) {
        wlogf!(frame, "[project] {:?} for tab {:?}: not offered any more; nothing done", act, id);
        return;
    }
    match act {
        PageAct::AddTo => crate::project_picker::open_add_to(frame, id),
        PageAct::TakeOut => {
            let done = crate::project_session::ask_before_taking_out(id).and_then(|()| crate::project_session::take_out(id));
            wlogf!(frame, "[project] take tab {:?} out of its project -> {:?}", id, done);
            if let Err(why) = done {
                tell(frame, &why);
            }
        }
        // Renaming is the settings window's: it has the box, the rule about
        // names that are taken, and the question to the core.
        PageAct::Rename => {
            let name = crate::project_session::project_of_tab(id);
            crate::settings_win::request(
                polter_settings_shell::Route::to(polter_settings_shell::Section::Projects, name.as_deref()),
                frame,
            );
        }
        PageAct::CloseProject => {
            let Some((file, name)) = crate::project_session::project_file_of_tab(id) else { return };
            let its = crate::project_session::tabs_of(&file);
            // One question for all of it, and only when something would be
            // killed: closing a project is putting it away, and every page
            // stays its page.
            if crate::tabs::any_busy(&its) {
                let pressed = crate::projects_ui::ask(
                    frame,
                    "[project]",
                    &tr("Close Project?"),
                    &tr("A terminal of this project still has a running process. If you close the project the process will be killed."),
                    &[tr(rules::CLOSE_PROJECT), tr("Cancel")],
                );
                if pressed != Some(0) {
                    wlogf!(frame, "[project] close project {:?}: kept", name);
                    return;
                }
            }
            wlogf!(frame, "[project] close project {:?}: closing {} tab(s)", name, its.len());
            for (window, tab) in its {
                crate::tabs::close_tab(window, tab);
            }
        }
    }
}

/// Tab `id` of `frame` is about to be closed by itself, by a person. `true`
/// means close it; `false` that they thought better of it.
///
/// When it is a page of a project that has other pages open, they are asked
/// whether it is to be taken out of the project as well
/// (`page_rules::close_step`); nothing else asks. **There is no "don't ask
/// again" here yet**: this host has nowhere to change that answer back, and
/// a question that can be silenced for good and never restored is worse
/// than one that is asked.
pub fn closing_a_page(frame: HWND, id: TabId) -> bool {
    use crate::i18n::tr;
    use polter_projects::page_rules::{self as rules, CloseChoice, CloseScope, CloseStep};
    let project = crate::project_session::project_of_tab(id);
    let others = crate::project_session::other_pages_open(id);
    match rules::close_step(project.as_deref(), others, CloseScope::Tab, CloseChoice::Ask) {
        CloseStep::Close { taking_out: false } => true,
        CloseStep::Close { taking_out: true } => taking_out_then(frame, id),
        CloseStep::Ask => {
            let project = project.unwrap_or_default();
            let (title, body) = (rules::close_question_title(&crate::tabs::title_of_tab(id)), rules::close_question_body(&project));
            let pressed = crate::projects_ui::ask(
                frame,
                "[close]",
                &title.filled(&tr(title.msgid)),
                &body.filled(&tr(body.msgid)),
                &[tr("Close"), tr(rules::ALSO_TAKE_OUT), tr("Cancel")],
            );
            match pressed {
                Some(0) => true,
                Some(1) => taking_out_then(frame, id),
                _ => false,
            }
        }
    }
}

/// Take the page out of its project before its tab closes. Refused -- the
/// group's supervisor is on it -- is said, and the tab stays.
fn taking_out_then(frame: HWND, id: TabId) -> bool {
    match crate::project_session::ask_before_taking_out(id).and_then(|()| crate::project_session::take_out(id)) {
        Ok(()) => true,
        Err(why) => {
            wlogf!(frame, "[close] tab {:?} was not taken out of its project: {}", id, why);
            tell(frame, &why);
            false
        }
    }
}

/// Build the shape for a *new* tab from a saved page, reusing the tab's
/// already-existing seed pane (every `tabs::Op::NewTab` starts with one)
/// rather than creating a redundant extra pane and discarding it.
///
/// **The seed becomes the leftmost leaf, deterministically.** A `SavedNode`
/// tree has no "first" pane the way a list would; "leftmost, always taking
/// `left`" is the same order `layout.rs`'s own `existing`/`fresh` walk uses,
/// so a saved four-pane grid restores with the seed pane where a person
/// re-reading `layout.rs` would expect the first `Shape::New` to have gone.
/// Every other leaf is `Shape::New{cwd}`, restored fresh -- this is the
/// "existing terminal_layout path" task 533 was scoped to reuse, not a
/// second way to build a tab.
///
/// `snaps` is the project file's `project::scrollback_dir`, which turns each
/// leaf's relative snapshot name into the absolute path a pane is created
/// with (see `project::to_layout_shape`).
pub fn shape_for_page_seeded(root: &SavedNode, seed_surface: usize, snaps: &std::path::Path) -> serde_json::Value {
    seed_leftmost(root, seed_surface, snaps)
}

fn seed_leftmost(node: &SavedNode, seed_surface: usize, snaps: &std::path::Path) -> serde_json::Value {
    match node {
        SavedNode::Leaf(_) => serde_json::json!({ "pane": format!("0x{seed_surface:x}") }),
        // The tab was made with the member in front (`leftmost_leaf`): it
        // stands at its own place among the tabs, and the others are made
        // (task 1583).
        SavedNode::Stack { shown, members } => {
            let at = (*shown).min(members.len().saturating_sub(1));
            serde_json::json!({
                "stack": members.iter().enumerate().map(|(i, m)| if i == at {
                    serde_json::json!({ "pane": format!("0x{seed_surface:x}") })
                } else {
                    project::to_layout_shape(&SavedNode::Leaf(m.clone()), snaps)
                }).collect::<Vec<_>>(),
                "shown": at,
            })
        }
        SavedNode::Split { axis, ratio, left, right } => serde_json::json!({
            "split": match axis { polter_split_tree::Axis::Horizontal => "h", polter_split_tree::Axis::Vertical => "v" },
            "ratio": ratio,
            "left": seed_leftmost(left, seed_surface, snaps),
            "right": project::to_layout_shape(right, snaps),
        }),
    }
}

/// The same leaf `seed_leftmost` will address as `{"pane": "0x..."}` --
/// walked once, before the seed pane exists, so its `cwd`/`history` can be
/// given to the tab's *creation* instead of left for the layout step, which
/// has no way to carry either onto a pane it did not create. See task 547 and
/// `open_page_in_new_tab`'s doc comment on why this half of the fix
/// belongs at creation time, not in `Shape`.
fn leftmost_leaf(node: &SavedNode) -> &SavedLeaf {
    match node {
        SavedNode::Leaf(leaf) => leaf,
        // The member in front, which is the one `to_layout_shape` opens. A
        // stack that was read has at least two members and shows one of
        // them (`polter_projectfile`).
        SavedNode::Stack { shown, members } => &members[(*shown).min(members.len().saturating_sub(1))],
        SavedNode::Split { left, .. } => leftmost_leaf(left),
    }
}

/// Turn a saved page into the JSON `layout::parse` already understands.
///
/// **Does not apply anything.** Building windows has to happen on the thread
/// that owns them (see `layout.rs`'s module doc comment on the same point),
/// so this makes no assumption about which thread called it -- the caller
/// still queues `tabs::Op::ApplyLayout` with the shape this returns, the same
/// path `poltergeist_layout` uses.
///
/// Opening a page goes through `shape_for_page_seeded`; this is the same
/// shape without a seed, which is what the tests of it read.
#[cfg(test)]
pub fn shape_for_page(root: &SavedNode, snaps: &std::path::Path) -> serde_json::Value {
    project::to_layout_shape(root, snaps)
}

/// Open one saved page as a brand-new tab in `frame`, and say which tab it
/// is. This is the end-to-end "does the existing `poltergeist_layout`
/// pipeline actually build the tree, with the right cwd and
/// `history_restore` on the fresh panes" path -- called from a fresh
/// top-level context (a keybind's dispatch, same as `layout::perform` is
/// normally reached from `cb_action`), **never from inside
/// `tabs::run_ops`**: `post_op` + `drain_for_layout` below queue and then
/// synchronously wait for a *second* op, and doing that from inside the op
/// loop that would have to run it is the same non-reentrant shape
/// `tab_tree`'s deadlock was, one level up (queueing into your own queue and
/// then blocking for it to drain, while the thread that drains it is this
/// one and it is not draining because it is here instead).
///
/// **Task 547, fixed here rather than worked around.** The earlier version
/// of this function created its seed pane with `create_tab_in(frame, app,
/// hinst, None)` -- a blank pane, then plugged in by identity as
/// `Shape::Existing`. Confirmed on a real run: `Shape::Existing` has no
/// `cwd` field (only `Shape::New` does) and cannot carry one, so the seed
/// pane came back at the fresh tab's own default directory, unrelated to
/// what was saved, while every other leaf landed exactly on its saved `cwd`.
/// `history_restore` has the same shape of gap for the sharper reason that
/// it can only be set once, at `surface_new`, which a blank seed pane has
/// already passed before this function ever sees it.
///
/// **The fix is to stop creating the seed pane blank.** `leftmost_leaf`
/// reads the same leaf `shape_for_page_seeded` will later address as
/// `{"pane": "0x..."}`, and its `cwd`/`history` seed the tab's creation via
/// `NewTab` -- the same fields `Op::ApplyLayout`'s own fresh leaves already
/// use. The seed pane is still plugged into the shape by identity afterward
/// (unchanged: geometry has to come from the layout step regardless of how
/// the pane started), but by the time that happens it is no longer blank.
/// **What this does not fix**: a *saved project's* seed leaf's `history` is
/// still capped by whatever `history_filename` core minted for it -- if that
/// pane's own shell never turned history capture on, there is nothing here
/// to restore, same as any other leaf, and that is not this function's gap.
///
/// **Every pane is a shell and nothing more**, the one a supervisor was in
/// included: who was in a pane is written in the file and is not started
/// from here (`dev-docs/poltergeist/projects.md`, 8.5).
pub fn open_page_in_new_tab(
    frame: HWND,
    app: crate::ffi::App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    root: &SavedNode,
    snaps: &std::path::Path,
    behind: bool,
    quiet: bool,
) -> Result<TabId, String> {
    // The seed pane is created here rather than by the layout step, so its
    // scrollback has to be given here too -- the same reason as `cwd` and
    // `history` (task 547): `scrollback_restore` is read once, at
    // `surface_new`, and a pane the layout step plugs in by identity has
    // long since passed it.
    let seed = leftmost_leaf(root);
    let seed_spec = tabs::NewTab {
        cwd: Some(seed.cwd.clone()).filter(|c| !c.is_empty()),
        history: Some(seed.history.clone()).filter(|h| !h.is_empty()),
        scrollback: project::scrollback_path(snaps, seed),
        behind,
        quiet,
        ..Default::default()
    };
    if !tabs::create_tab_with(frame, app, hinst, seed_spec) {
        return Err("could not create a new tab".to_string());
    }
    // `create_tab_with` appends (and activates unless `behind`), so the tab
    // just made is the last one -- picked up by identity here, before
    // anything can reorder.
    let Some(id) = tabs::last_tab_id(frame) else {
        return Err("the new tab is not in its window".to_string());
    };

    // **All of the page, or none of it** (task 1597): from here on the tab
    // exists, and a page that cannot be built whole takes it back -- a
    // refused layout used to leave its first pane standing alone in a tab
    // nobody asked for, and a window made for the project with it.
    let built = (|| -> Result<(), String> {
        // The new tab's, by identity: behind, the active one is another.
        let seed_surface = tabs::surface_of_tab(frame, id);
        if seed_surface.is_null() {
            return Err("the new tab has no active surface".to_string());
        }
        let shape_json = shape_for_page_seeded(root, seed_surface as usize, snaps);
        let shape = crate::layout::parse_project(&shape_json)?;
        let at = tabs::pane_id_of_surface(seed_surface);

        let outcome: crate::layout::Outcome = std::sync::Arc::new(std::sync::Mutex::new(None));
        tabs::post_op(frame, tabs::Op::ApplyLayout(shape, at, outcome.clone()), "open_page_in_new_tab");
        tabs::drain_for_layout(frame);

        match outcome.lock().ok().and_then(|mut o| o.take()) {
            Some(Ok(_)) => Ok(()),
            Some(Err(e)) => Err(e),
            None => Err("the layout was queued and did not run; the window may have closed".to_string()),
        }
    })();
    match built {
        // Built whole: only now are its terminals' snapshots written to.
        Ok(()) => {
            let n = tabs::begin_journals(frame, id);
            wlogf!(frame, "[project] page built: {} terminal(s) journaled to their snapshots from now on", n);
            Ok(id)
        }
        Err(e) => {
            tabs::retract_tab(frame, id);
            Err(e)
        }
    }
}

/// Open the project in `file`, whole: every window and every page of it
/// that is not open already, each window where the file says it was or
/// among the tabs of `frame` (`project_session::open`). A project that is
/// open already is gone to.
pub fn open_project(
    frame: HWND,
    app: crate::ffi::App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    file: &std::path::Path,
) -> Result<(), String> {
    crate::project_session::open(frame, app, hinst, file, false, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Task 1583: a page whose first place holds a stack opens with the tab's
    /// first terminal -- the member that was in front -- at its own place
    /// among the stack's tabs, and the others made.
    #[test]
    fn a_page_that_starts_with_a_stack_is_seeded_with_the_member_in_front() {
        let stack = SavedNode::Stack {
            shown: 1,
            members: vec![SavedLeaf::plain("/a", Agent::Unknown), SavedLeaf::plain("/b", Agent::Unknown), SavedLeaf::plain("/c", Agent::Unknown)],
        };
        assert_eq!(leftmost_leaf(&stack).cwd, "/b");
        let shape = shape_for_page_seeded(&stack, 0x77, std::path::Path::new("/p/x.scrollback"));
        assert_eq!(shape["shown"], 1);
        assert_eq!(shape["stack"][0]["new"]["cwd"], "/a");
        assert_eq!(shape["stack"][1]["pane"], "0x77");
        assert_eq!(shape["stack"][2]["new"]["cwd"], "/c");
        let parsed = crate::layout::parse_project(&shape).expect("the layout reads it");
        let mut named = Vec::new();
        crate::layout::existing(&parsed, &mut named);
        assert_eq!(named, [0x77]);
    }
    use crate::project::{Snapshot, Tab, Window};

    fn sample_snapshot() -> Snapshot {
        Snapshot {
            name: "demo".to_string(),
            saved_at: 1,
            group: None,
            color: crate::project::PaneColor::None,
            windows: vec![Window {
                frame: None,
                front: 0,
                tabs: vec![Tab {
                    root: SavedNode::Split {
                        axis: polter_split_tree::Axis::Horizontal,
                        ratio: 0.5,
                        left: Box::new(SavedNode::Leaf(SavedLeaf::plain("/a", Agent::Unknown))),
                        right: Box::new(SavedNode::Leaf(SavedLeaf::plain("/b", Agent::Unknown))),
                    },
                    title: None,
                }],
            }],
            next_scrollback: None,
        }
    }

    /// The one tab of `sample_snapshot`.
    fn sample_root() -> SavedNode {
        sample_snapshot().windows[0].tabs[0].root.clone()
    }

    #[test]
    fn shape_for_page_carries_cwd_through_the_existing_layout_shape() {
        let shape = shape_for_page(&sample_root(), std::path::Path::new("/p/x.scrollback"));
        assert_eq!(shape["split"], "h");
        assert_eq!(shape["left"]["new"]["cwd"], "/a");
        assert_eq!(shape["right"]["new"]["cwd"], "/b");
    }

    #[test]
    fn leaf_count_counts_every_leaf_not_every_node() {
        let root = sample_root();
        assert_eq!(leaf_count(&root), 2);
    }

    /// **Judgment ① from the windows-port discussion.** A live tree, walked
    /// through `describe()` into a `SavedNode` and then through
    /// `to_layout_shape` into the *other* wire format, must come out
    /// isomorphic to the original: same axis at each level, same ratio, same
    /// left/right order. This is exactly where `direction_str`'s
    /// `"horizontal"/"vertical"` could get silently swapped for
    /// `to_layout_shape`'s `"h"/"v"`, or a left/right pair could get flipped
    /// in one of the two walks -- either mistake produces a tree that is
    /// still valid JSON and still parses, so nothing but comparing shapes
    /// catches it.
    ///
    /// Both axes appear, at different levels, on purpose: a bug that only
    /// mishandles one of `Horizontal`/`Vertical` would pass a test that only
    /// exercised the other.
    #[test]
    fn describe_then_shape_round_trip_is_isomorphic_including_axis_mapping() {
        use polter_split_tree::{Axis, Node, PaneId, Split};

        const TOP_LEFT: PaneId = 1;
        const BOTTOM_LEFT: PaneId = 2;
        const BOTTOM_RIGHT: PaneId = 3;

        // root: Horizontal(top_left | Vertical(bottom_left / bottom_right))
        let live = Node::Split(Box::new(Split {
            axis: Axis::Horizontal,
            ratio: 0.3,
            left: Node::Leaf(TOP_LEFT),
            right: Node::Split(Box::new(Split {
                axis: Axis::Vertical,
                ratio: 0.7,
                left: Node::Leaf(BOTTOM_LEFT),
                right: Node::Leaf(BOTTOM_RIGHT),
            })),
        }));

        let saved = project::describe(&polter_split_tree::Tree::with_root(live), &|id| SavedLeaf::plain(&format!("/pane/{id}"), Agent::Unknown)).unwrap();

        let shape = project::to_layout_shape(&saved, std::path::Path::new("/p/x.scrollback"));

        // Root axis: Horizontal -> "h", not "v".
        assert_eq!(shape["split"], "h");
        assert_eq!(shape["ratio"], 0.3);
        // Left of root is the single leaf, unswapped.
        assert_eq!(shape["left"]["new"]["cwd"], "/pane/1");
        // Right of root is the nested Vertical split, not the leaf.
        assert_eq!(shape["right"]["split"], "v");
        assert_eq!(shape["right"]["ratio"], 0.7);
        assert_eq!(shape["right"]["left"]["new"]["cwd"], "/pane/2");
        assert_eq!(shape["right"]["right"]["new"]["cwd"], "/pane/3");
    }

    /// **Judgment ② from the windows-port discussion.** The same
    /// `apply_pane_cwd`-shaped data (three distinct directories, already
    /// proven in `tabs.rs`'s `pane_metadata_tests` to reach the live
    /// `Pane`) has to survive all the way into the *file on disk*, not just
    /// an in-memory `serde_json::Value`. This chains `describe()` (already
    /// covered above) through the real `project::write`/`project::read`
    /// round trip, reading the bytes back off disk the same way a restart
    /// would.
    #[test]
    fn pane_cwd_reaches_the_written_file() {
        use polter_split_tree::{Axis, Node, PaneId, Split};

        const A: PaneId = 10;
        const B: PaneId = 20;
        const C: PaneId = 30;
        let cwd_of = |id: PaneId| match id {
            A => "/repo/a",
            B => "/repo/b",
            C => "/repo/c",
            _ => unreachable!(),
        };

        let live = Node::Split(Box::new(Split {
            axis: Axis::Vertical,
            ratio: 0.5,
            left: Node::Leaf(A),
            right: Node::Split(Box::new(Split {
                axis: Axis::Horizontal,
                ratio: 0.5,
                left: Node::Leaf(B),
                right: Node::Leaf(C),
            })),
        }));

        let saved = project::describe(&polter_split_tree::Tree::with_root(live), &|id| SavedLeaf::plain(cwd_of(id), Agent::Unknown)).unwrap();
        let snapshot = Snapshot {
            name: "three panes three dirs".to_string(),
            saved_at: 42,
            group: None,
            color: crate::project::PaneColor::None,
            windows: vec![Window { frame: None, front: 0, tabs: vec![Tab::unnamed(saved)] }],
            next_scrollback: None,
        };

        let dir = std::env::temp_dir().join(format!("polter-project-ui-rs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        project::write(&dir, &snapshot, project::WriteKind::Save).expect("write should succeed");

        let back = project::read(&dir, "three panes three dirs").expect("read should succeed");
        let root = back.tabs().next().cloned().expect("root should round-trip");
        let SavedNode::Split { left, right, .. } = &root else { panic!("expected a split") };
        let SavedNode::Leaf(a) = left.as_ref() else { panic!("expected a leaf") };
        let SavedNode::Split { left: b, right: c, .. } = right.as_ref() else { panic!("expected a split") };
        let SavedNode::Leaf(b) = b.as_ref() else { panic!("expected a leaf") };
        let SavedNode::Leaf(c) = c.as_ref() else { panic!("expected a leaf") };

        assert_eq!(a.cwd, "/repo/a");
        assert_eq!(b.cwd, "/repo/b");
        assert_eq!(c.cwd, "/repo/c");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Judgment ③ from the windows-port discussion: the missing-history
    /// gap must be discoverable, not a silent empty string that reads the
    /// same as "this pane never ran a command".** This does not (and
    /// cannot, on this machine) prove the log line in `name_leaves` fires
    /// -- it proves the *fact the log line reports* is independently
    /// computable from the saved data, so code (not just a person reading a
    /// scrolled-off log) can act on it later.
    #[test]
    fn missing_history_is_a_discoverable_fact_not_a_silent_null() {
        let root = sample_root();
        // Neither leaf in `sample_snapshot` was given a history handle.
        assert_eq!(missing_history_count(&root), 2);
        assert_eq!(leaf_count(&root), 2);

        // Once a leaf does carry one, it stops counting as missing.
        let with_history = SavedNode::Split {
            axis: polter_split_tree::Axis::Horizontal,
            ratio: 0.5,
            left: Box::new(SavedNode::Leaf(SavedLeaf { history: "abc123.history".to_string(), ..SavedLeaf::plain("", Agent::Unknown) })),
            right: Box::new(SavedNode::Leaf(SavedLeaf::plain("", Agent::Unknown))),
        };
        assert_eq!(missing_history_count(&with_history), 1);
    }

    #[test]
    fn save_before_closing_is_offered_exactly_when_confirmation_would_fire() {
        assert!(should_offer_save_as_project(true));
        assert!(!should_offer_save_as_project(false));
    }

    #[test]
    fn shape_for_page_seeded_reuses_the_seed_pane_as_the_leftmost_leaf() {
        let shape = shape_for_page_seeded(&sample_root(), 0xABCD, std::path::Path::new("/p/x.scrollback"));
        assert_eq!(shape["left"]["pane"], "0xabcd");
        // The other leaf is still freshly built, cwd intact.
        assert_eq!(shape["right"]["new"]["cwd"], "/b");
    }

    /// **Task 547's judgment.** `leftmost_leaf` has to find the exact same
    /// leaf `seed_leftmost` addresses as `{"pane": "0x..."}` -- if the two
    /// ever disagreed, the seed pane would be created with one leaf's
    /// cwd/history and then plugged into the shape at a *different* leaf's
    /// position, which is a worse bug than the one 547 opened with (a wrong
    /// but at-least-consistent seed, versus a seed whose creation-time
    /// metadata belongs to a different pane entirely).
    #[test]
    fn leftmost_leaf_finds_the_same_leaf_seed_leftmost_addresses() {
        let root = sample_root();
        let leaf = leftmost_leaf(&root);
        assert_eq!(leaf.cwd, "/a");

        // Same tree, walked the other way: the shape's "left" cell should be
        // the seed placeholder, and its sibling should be the *other* leaf's
        // cwd ("/b"), never "/a" showing up on the wrong side.
        let shape = seed_leftmost(&root, 0x1234, std::path::Path::new("/p/x.scrollback"));
        assert_eq!(shape["left"]["pane"], "0x1234");
        assert_eq!(shape["right"]["new"]["cwd"], "/b");
    }

    #[test]
    fn leftmost_leaf_descends_through_nested_splits() {
        let nested = SavedNode::Split {
            axis: polter_split_tree::Axis::Vertical,
            ratio: 0.4,
            left: Box::new(SavedNode::Split {
                axis: polter_split_tree::Axis::Horizontal,
                ratio: 0.6,
                left: Box::new(SavedNode::Leaf(SavedLeaf::plain("/deep", Agent::Unknown))),
                right: Box::new(SavedNode::Leaf(SavedLeaf::plain("", Agent::Unknown))),
            }),
            right: Box::new(SavedNode::Leaf(SavedLeaf::plain("", Agent::Unknown))),
        };
        assert_eq!(leftmost_leaf(&nested).cwd, "/deep");
    }
}
