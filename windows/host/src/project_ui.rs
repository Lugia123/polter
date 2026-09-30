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
//! What lives here is everything about task 533 that *is* verifiable without
//! a screen: turning a live tab into a `Snapshot` (`write_tab`) and
//! turning a loaded `Snapshot` into the JSON the existing
//! `poltergeist_layout` pipeline already knows how to build a tab from
//! (`shape_for_snapshot`). A UI, whatever shape it ends up taking, calls
//! into these two and nothing else.

use windows::Win32::Foundation::HWND;

use crate::{plogf, wlogf};
use crate::project::{self, SavedLeaf, SavedNode, Snapshot};
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
/// `write_tab`'s doc comment for how those two "empty" cases are told
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
/// `write_tab` can make its capture calls after this lock is released;
/// the deadlock described above is what calling out from inside it has
/// already cost once.
fn snapshot_and_surfaces(frame: HWND, id: TabId, name: String, saved_at: i64) -> Option<(Snapshot, Vec<LeafPane>)> {
    let (root, surfaces) = tabs::with_windows(|ws| {
        let win = ws.iter().find(|w| w.frame == frame.0 as isize)?;
        let tab = win.tabs.iter().find(|t| t.id == id)?;
        let node = tab.tree.root()?;
        let meta: std::collections::HashMap<polter_split_tree::PaneId, (SavedLeaf, LeafPane)> = tab
            .panes
            .iter()
            .map(|p| {
                (
                    p.id,
                    (
                        SavedLeaf {
                            cwd: p.cwd.clone().unwrap_or_default(),
                            title: p.title.clone().unwrap_or_default(),
                            history: p.history.clone().unwrap_or_default(),
                            // Named by `write_tab`, from the pane's own
                            // slot (`capture_scrollback`); empty until then.
                            scrollback: String::new(),
                        },
                        LeafPane { pane: p.id, surface: p.surface, slot: p.scrollback.as_ref().map(|j| j.slot().clone()) },
                    ),
                )
            })
            .collect();
        let order = std::cell::RefCell::new(Vec::new());
        let root = project::describe(node, &|id| {
            let (leaf, pane) = meta.get(&id).cloned().unwrap_or_default();
            order.borrow_mut().push(pane);
            leaf
        });
        Some((root, order.into_inner()))
    })?;

    Some((Snapshot { name, saved_at, root: Some(root), next_scrollback: None }, surfaces))
}

/// The pane behind one leaf of a snapshot being saved.
#[derive(Clone, Debug, Default)]
struct LeafPane {
    pane: polter_split_tree::PaneId,
    surface: usize,
    slot: Option<project::Slot>,
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
fn capture_scrollback(
    frame: HWND,
    snapshot: &mut Snapshot,
    panes: &[LeafPane],
    snaps: &std::path::Path,
    alloc: &mut project::Allocator,
) {
    let Some(root) = snapshot.root.as_mut() else { return };
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
        let Some(abs) = snaps.join(&name).to_str().and_then(|s| std::ffi::CString::new(s).ok()) else {
            wlogf!(frame, "[project] capture {}: {:?} is not a UTF-8 path the core can take", name, snaps);
            continue;
        };
        // Written before the call: `capture_scrollback` queues onto the IO
        // thread's mailbox and waits for room when it is full, so this line
        // being the last one is what that wait would look like.
        wlogf!(frame, "[project] capture pane {} -> {} via ghostty_surface_capture_scrollback(0x{:x}) …", p.pane, name, p.surface);
        let ok = unsafe { (crate::api().surface_capture_scrollback)(p.surface as crate::ffi::Surface, abs.as_ptr()) };
        if !ok {
            wlogf!(frame, "[project] capture {}: the core refused it; the leaf keeps the name, its file is not written", name);
        }
    }
}

/// Number of leaves in a saved tree. Used by `write_tab`'s log line and by
/// the "you are about to overwrite N-pane project saved at T" confirmation a
/// UI shows before replacing an existing name -- **on the *existing on-disk*
/// project being overwritten**, read fresh with `project::read`, never on the
/// live tab that is about to replace it; those are two different pane counts
/// and confirming with the wrong one tells the person the wrong thing about
/// what they are about to lose.
pub fn leaf_count(node: &SavedNode) -> usize {
    match node {
        SavedNode::Leaf(_) => 1,
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

/// "Overwrite with Current Tab" (settings.md §6.2): a save, except that
/// **what it replaces is always kept as the previous version**, as the
/// confirmation promised -- the save's rule keeps it only on a layout change,
/// and one pane over one pane then lost it (39ae3f040).
pub fn overwrite_project(dir: &std::path::Path, frame: HWND, id: TabId, name: String) -> Result<(), String> {
    write_tab(dir, frame, id, name, project::WriteKind::Overwrite)
}

/// A tab saved as a project of `kind` -- `Save` or `Overwrite`, as
/// `polter_settings_shell::projects::save_as` decided for "Save as Project".
pub fn write_tab_as(dir: &std::path::Path, frame: HWND, id: TabId, name: String, kind: project::WriteKind) -> Result<(), String> {
    write_tab(dir, frame, id, name, kind)
}

/// Save the given tab as a named project. The caller (whichever UI asked
/// for the name) is responsible for telling the person the result; this
/// only reports success/failure as a value.
///
/// **Logs once when some, but not all, panes have a history handle.** All
/// missing (capture is plainly off) or all present are both unremarkable; a
/// *mix* in one save is the shape worth a line, since it usually means
/// capture was toggled mid-session rather than a per-pane setting anyone
/// asked for.
fn write_tab(dir: &std::path::Path, frame: HWND, id: TabId, name: String, kind: project::WriteKind) -> Result<(), String> {
    let saved_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let Some((mut snapshot, surfaces)) = snapshot_and_surfaces(frame, id, name.clone(), saved_at) else {
        return Err("that tab no longer exists".to_string());
    };

    if let Some(root) = &snapshot.root {
        let missing = missing_history_count(root);
        let total = leaf_count(root);
        if missing > 0 && missing < total {
            // process-wide: about the save format, not attributable to one window
            plogf!(
                "[project] saved {:?}: {} of {} pane(s) have no history handle \
                 (the rest do) -- capture may have been toggled mid-session",
                name,
                missing,
                total
            );
        }
    }

    // Derived from the file this save writes, not from `name` again: see
    // `project::scrollback_dir`.
    let file = project::path_for(dir, &snapshot.name)
        .map_err(|_| format!("{:?} has nothing left once sanitized, so no file can be named after it", snapshot.name))?;
    let snaps = project::scrollback_dir(&file);
    // **What this project has already handed out**: the counter in the file
    // being replaced, and every snapshot name that file or the directory
    // still holds. A counter that went missing cannot make a number be used
    // twice, because what is on disk is counted too.
    let existing = project::read(dir, &snapshot.name).ok();
    let mut in_use: Vec<String> =
        existing.as_ref().and_then(|e| e.root.as_ref()).map(project::scrollback_names).unwrap_or_default();
    if let Ok(entries) = std::fs::read_dir(&snaps) {
        in_use.extend(entries.flatten().filter_map(|e| e.file_name().to_str().map(str::to_string)));
    }
    let mut alloc = project::Allocator::new(existing.and_then(|e| e.next_scrollback), in_use.iter().map(String::as_str));
    capture_scrollback(frame, &mut snapshot, &surfaces, &snaps, &mut alloc);
    snapshot.next_scrollback = Some(alloc.next);
    let named = snapshot.root.as_ref().map(project::scrollback_names).unwrap_or_default();
    project::write(dir, &snapshot, kind).map_err(|e| e.to_string())?;
    // After the write, so a failed write leaves the previous save's
    // snapshots where its file still points. Kept: exactly what the tree
    // now names.
    let pruned = project::prune_scrollback_dir(&snaps, &named);
    wlogf!(
        frame,
        "[project] saved {:?}: {} of {} pane(s) named a snapshot, next_scrollback={}, {} stale snapshot(s) removed",
        name,
        named.len(),
        surfaces.len(),
        alloc.next,
        pruned
    );
    Ok(())
}

/// Build the shape for a *new* tab from a loaded project, reusing the tab's
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
pub fn shape_for_snapshot_seeded(
    snapshot: &Snapshot,
    seed_surface: usize,
    snaps: &std::path::Path,
) -> Option<serde_json::Value> {
    let root = snapshot.root.as_ref()?;
    Some(seed_leftmost(root, seed_surface, snaps))
}

fn seed_leftmost(node: &SavedNode, seed_surface: usize, snaps: &std::path::Path) -> serde_json::Value {
    match node {
        SavedNode::Leaf(_) => serde_json::json!({ "pane": format!("0x{seed_surface:x}") }),
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
/// `load_project_into_new_tab`'s doc comment on why this half of the fix
/// belongs at creation time, not in `Shape`.
fn leftmost_leaf(node: &SavedNode) -> &SavedLeaf {
    match node {
        SavedNode::Leaf(leaf) => leaf,
        SavedNode::Split { left, .. } => leftmost_leaf(left),
    }
}

/// Turn a loaded snapshot into the JSON `layout::parse` already understands.
/// `None` for a project with no layout (`Snapshot::root` is `None`) -- there
/// is nothing to build, which is a valid saved state (see `Project.zig`'s
/// doc comment on `Snapshot::root`), not an error.
///
/// **Does not apply anything.** Building windows has to happen on the thread
/// that owns them (see `layout.rs`'s module doc comment on the same point),
/// so this makes no assumption about which thread called it -- the caller
/// still queues `tabs::Op::ApplyLayout` with the shape this returns, the same
/// path `poltergeist_layout` uses.
pub fn shape_for_snapshot(snapshot: &Snapshot, snaps: &std::path::Path) -> Option<serde_json::Value> {
    snapshot.root.as_ref().map(|r| project::to_layout_shape(r, snaps))
}

/// Load a saved project into a brand-new tab in `frame`. This is the
/// end-to-end "does the existing `poltergeist_layout` pipeline actually
/// build the tree, with the right cwd and `history_restore` on the fresh
/// panes" path -- called from a fresh top-level context (a keybind's
/// dispatch, same as `layout::perform` is normally reached from
/// `cb_action`), **never from inside `tabs::run_ops`**: `post_op` +
/// `drain_for_layout` below queue and then synchronously wait for a *second*
/// op, and doing that from inside the op loop that would have to run it is
/// the same non-reentrant shape `snapshot_and_surfaces`'s deadlock was, one level
/// up (queueing into your own queue and then blocking for it to drain, while
/// the thread that drains it is this one and it is not draining because it
/// is here instead).
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
/// reads the same leaf `shape_for_snapshot_seeded` will later address as
/// `{"pane": "0x..."}`, and its `cwd`/`history` seed the tab's creation via
/// `NewTab` -- the same fields `Op::ApplyLayout`'s own fresh leaves already
/// use. The seed pane is still plugged into the shape by identity afterward
/// (unchanged: geometry has to come from the layout step regardless of how
/// the pane started), but by the time that happens it is no longer blank.
/// **What this does not fix**: a *saved project's* seed leaf's `history` is
/// still capped by whatever `history_filename` core minted for it -- if that
/// pane's own shell never turned history capture on, there is nothing here
/// to restore, same as any other leaf, and that is not this function's gap.
pub fn load_project_into_new_tab(
    frame: HWND,
    app: crate::ffi::App,
    hinst: windows::Win32::Foundation::HINSTANCE,
    file: &std::path::Path,
) -> Result<(), String> {
    // **The file the listing found**, not a path recomputed from the name:
    // see `project::path_for`. (This used to take a name and call `path_for`
    // right below a comment saying it did not.)
    let snapshot = project::read_file(file).map_err(|e| format!("{e:?}"))?;
    let snaps = project::scrollback_dir(file);

    // The seed pane is created here rather than by the layout step, so its
    // scrollback has to be given here too -- the same reason as `cwd` and
    // `history` (task 547): `scrollback_restore` is read once, at
    // `surface_new`, and a pane the layout step plugs in by identity has
    // long since passed it.
    let seed = snapshot.root.as_ref().map(leftmost_leaf);
    let seed_spec = tabs::NewTab {
        cwd: seed.filter(|l| !l.cwd.is_empty()).map(|l| l.cwd.clone()),
        history: seed.filter(|l| !l.history.is_empty()).map(|l| l.history.clone()),
        scrollback: seed.and_then(|l| project::scrollback_path(&snaps, l)),
        ..Default::default()
    };
    if !tabs::create_tab_with(frame, app, hinst, seed_spec) {
        return Err("could not create a new tab".to_string());
    }

    let seed_surface = tabs::active_surface(frame);
    if seed_surface.is_null() {
        return Err("the new tab has no active surface".to_string());
    }

    let Some(shape_json) = shape_for_snapshot_seeded(&snapshot, seed_surface as usize, &snaps) else {
        // An empty project: the fresh blank tab this function already made
        // is the whole of what there was to build.
        return Ok(());
    };
    let shape = crate::layout::parse_project(&shape_json)?;
    let at = tabs::pane_id_of_surface(seed_surface);

    let outcome: crate::layout::Outcome = std::sync::Arc::new(std::sync::Mutex::new(None));
    tabs::post_op(frame, tabs::Op::ApplyLayout(shape, at, outcome.clone()), "load_project_into_new_tab");
    tabs::drain_for_layout(frame);

    match outcome.lock().ok().and_then(|mut o| o.take()) {
        Some(Ok(_)) => Ok(()),
        Some(Err(e)) => Err(e),
        None => Err("the layout was queued and did not run; the window may have closed".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::SavedLeaf;

    fn sample_snapshot() -> Snapshot {
        Snapshot {
            name: "demo".to_string(),
            saved_at: 1,
            root: Some(SavedNode::Split {
                axis: polter_split_tree::Axis::Horizontal,
                ratio: 0.5,
                left: Box::new(SavedNode::Leaf(SavedLeaf { cwd: "/a".to_string(), ..Default::default() })),
                right: Box::new(SavedNode::Leaf(SavedLeaf { cwd: "/b".to_string(), ..Default::default() })),
            }),
            next_scrollback: None,
        }
    }

    #[test]
    fn shape_for_snapshot_carries_cwd_through_the_existing_layout_shape() {
        let shape = shape_for_snapshot(&sample_snapshot(), std::path::Path::new("/p/x.scrollback")).unwrap();
        assert_eq!(shape["split"], "h");
        assert_eq!(shape["left"]["new"]["cwd"], "/a");
        assert_eq!(shape["right"]["new"]["cwd"], "/b");
    }

    #[test]
    fn shape_for_snapshot_of_an_empty_project_is_none() {
        let snapshot = Snapshot { name: "blank".to_string(), saved_at: 1, root: None, next_scrollback: None };
        assert!(shape_for_snapshot(&snapshot, std::path::Path::new("/p/x.scrollback")).is_none());
    }

    #[test]
    fn leaf_count_counts_every_leaf_not_every_node() {
        let root = sample_snapshot().root.unwrap();
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

        let saved = project::describe(&live, &|id| SavedLeaf { cwd: format!("/pane/{id}"), ..Default::default() });

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

        let saved = project::describe(&live, &|id| SavedLeaf { cwd: cwd_of(id).to_string(), ..Default::default() });
        let snapshot = Snapshot { name: "three panes three dirs".to_string(), saved_at: 42, root: Some(saved), next_scrollback: None };

        let dir = std::env::temp_dir().join(format!("polter-project-ui-rs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        project::write(&dir, &snapshot, project::WriteKind::Save).expect("write should succeed");

        let back = project::read(&dir, "three panes three dirs").expect("read should succeed");
        let root = back.root.expect("root should round-trip");
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
    /// cannot, on this machine) prove the log line in `write_tab` fires
    /// -- it proves the *fact the log line reports* is independently
    /// computable from the saved data, so code (not just a person reading a
    /// scrolled-off log) can act on it later.
    #[test]
    fn missing_history_is_a_discoverable_fact_not_a_silent_null() {
        let root = sample_snapshot().root.unwrap();
        // Neither leaf in `sample_snapshot` was given a history handle.
        assert_eq!(missing_history_count(&root), 2);
        assert_eq!(leaf_count(&root), 2);

        // Once a leaf does carry one, it stops counting as missing.
        let with_history = SavedNode::Split {
            axis: polter_split_tree::Axis::Horizontal,
            ratio: 0.5,
            left: Box::new(SavedNode::Leaf(SavedLeaf { history: "abc123.history".to_string(), ..Default::default() })),
            right: Box::new(SavedNode::Leaf(SavedLeaf::default())),
        };
        assert_eq!(missing_history_count(&with_history), 1);
    }

    #[test]
    fn save_before_closing_is_offered_exactly_when_confirmation_would_fire() {
        assert!(should_offer_save_as_project(true));
        assert!(!should_offer_save_as_project(false));
    }

    #[test]
    fn shape_for_snapshot_seeded_reuses_the_seed_pane_as_the_leftmost_leaf() {
        let shape = shape_for_snapshot_seeded(&sample_snapshot(), 0xABCD, std::path::Path::new("/p/x.scrollback")).unwrap();
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
        let root = sample_snapshot().root.unwrap();
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
                left: Box::new(SavedNode::Leaf(SavedLeaf { cwd: "/deep".to_string(), ..Default::default() })),
                right: Box::new(SavedNode::Leaf(SavedLeaf::default())),
            }),
            right: Box::new(SavedNode::Leaf(SavedLeaf::default())),
        };
        assert_eq!(leftmost_leaf(&nested).cwd, "/deep");
    }
}
