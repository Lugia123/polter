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
//! a screen: turning a live tab into a `Snapshot` (`save_project`) and
//! turning a loaded `Snapshot` into the JSON the existing
//! `poltergeist_layout` pipeline already knows how to build a tab from
//! (`shape_for_snapshot`). A UI, whatever shape it ends up taking, calls
//! into these two and nothing else.

use windows::Win32::Foundation::HWND;

use crate::plogf;
use crate::project::{self, SavedLeaf, SavedNode, Snapshot};
use crate::tabs::{self, TabId};
use polter_split_tree::Node;

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
/// `save_project`'s doc comment for how those two "empty" cases are told
/// apart now (an apprt-side count, not just a hope that a log line was
/// read).
pub fn snapshot_for_tab(frame: HWND, id: TabId, name: String, saved_at: i64) -> Option<Snapshot> {
    let root = tabs::with_windows(|ws| {
        let win = ws.iter().find(|w| w.frame == frame.0 as isize)?;
        let tab = win.tabs.iter().find(|t| t.id == id)?;
        let node = tab.tree.root()?;
        Some(build_saved_node(node))
    })?;

    Some(Snapshot { name, saved_at, root: Some(root) })
}

fn build_saved_node(node: &Node) -> SavedNode {
    project::describe(node, &|id| SavedLeaf {
        cwd: tabs::cwd_of_pane(id).unwrap_or_default(),
        title: tabs::title_of_pane(id).unwrap_or_default(),
        history: tabs::history_of_pane(id).unwrap_or_default(),
    })
}

/// Number of leaves in a saved tree. Used by `save_project`'s log line and by
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
pub fn should_offer_save_as_project(tab_needs_confirmation: bool) -> bool {
    tab_needs_confirmation
}

/// Save the given tab as a named project. The caller (whichever UI ends up
/// asking for the name) is responsible for telling the person the result;
/// this only reports success/failure as a value.
///
/// **Logs once when some, but not all, panes have a history handle.** All
/// missing (capture is plainly off) or all present are both unremarkable; a
/// *mix* in one save is the shape worth a line, since it usually means
/// capture was toggled mid-session rather than a per-pane setting anyone
/// asked for.
pub fn save_project(dir: &std::path::Path, frame: HWND, id: TabId, name: String) -> Result<(), String> {
    let saved_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let Some(snapshot) = snapshot_for_tab(frame, id, name.clone(), saved_at) else {
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

    project::write(dir, &snapshot).map_err(|e| e.to_string())
}

/// Read the project that saving as `name` would overwrite, if any -- for a
/// UI to show "you are about to replace a N-pane project saved at T" before
/// it happens. `None` for a name that would be a fresh save (nothing to
/// confirm) as well as for a name whose existing file is corrupt (nothing
/// useful to show; the write will still replace it, same as `Project.zig`'s
/// `write` does unconditionally).
pub fn existing_project_for_overwrite_check(dir: &std::path::Path, name: &str) -> Option<Snapshot> {
    project::read(dir, name).ok()
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
pub fn shape_for_snapshot_seeded(snapshot: &Snapshot, seed_surface: usize) -> Option<serde_json::Value> {
    let root = snapshot.root.as_ref()?;
    Some(seed_leftmost(root, seed_surface))
}

fn seed_leftmost(node: &SavedNode, seed_surface: usize) -> serde_json::Value {
    match node {
        SavedNode::Leaf(_) => serde_json::json!({ "pane": format!("0x{seed_surface:x}") }),
        SavedNode::Split { axis, ratio, left, right } => serde_json::json!({
            "split": match axis { polter_split_tree::Axis::Horizontal => "h", polter_split_tree::Axis::Vertical => "v" },
            "ratio": ratio,
            "left": seed_leftmost(left, seed_surface),
            "right": project::to_layout_shape(right),
        }),
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
pub fn shape_for_snapshot(snapshot: &Snapshot) -> Option<serde_json::Value> {
    snapshot.root.as_ref().map(project::to_layout_shape)
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
        }
    }

    #[test]
    fn shape_for_snapshot_carries_cwd_through_the_existing_layout_shape() {
        let shape = shape_for_snapshot(&sample_snapshot()).unwrap();
        assert_eq!(shape["split"], "h");
        assert_eq!(shape["left"]["new"]["cwd"], "/a");
        assert_eq!(shape["right"]["new"]["cwd"], "/b");
    }

    #[test]
    fn shape_for_snapshot_of_an_empty_project_is_none() {
        let snapshot = Snapshot { name: "blank".to_string(), saved_at: 1, root: None };
        assert!(shape_for_snapshot(&snapshot).is_none());
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

        let saved = project::describe(&live, &|id| SavedLeaf {
            cwd: format!("/pane/{id}"),
            title: String::new(),
            history: String::new(),
        });

        let shape = project::to_layout_shape(&saved);

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
        let snapshot = Snapshot { name: "three panes three dirs".to_string(), saved_at: 42, root: Some(saved) };

        let dir = std::env::temp_dir().join(format!("polter-project-ui-rs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        project::write(&dir, &snapshot).expect("write should succeed");

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
    /// cannot, on this machine) prove the log line in `save_project` fires
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
        let shape = shape_for_snapshot_seeded(&sample_snapshot(), 0xABCD).unwrap();
        assert_eq!(shape["left"]["pane"], "0xabcd");
        // The other leaf is still freshly built, cwd intact.
        assert_eq!(shape["right"]["new"]["cwd"], "/b");
    }
}
