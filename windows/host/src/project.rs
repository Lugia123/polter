//! A user's "save this tab as a project": the whole split tree of one tab,
//! each pane's directory and title, and which command-history handle
//! belongs to which pane.
//!
//! **This mirrors `src/Project.zig`, byte-for-byte on the wire, and nothing
//! else.** The file format, the field names, the strict-read rules and the
//! `sanitizeFilename` behaviour below are copied from there because two
//! independent JSON writers is how a project saved on one platform silently
//! fails to load on the other -- see `windows_host_settings.json` in
//! `src/poltergeist/testdata/` for a case this codebase already paid for
//! once. Read `Project.zig`'s doc comment before changing either side.
//!
//! **Why this is not in `polter-split-tree`.** That crate's whole reason to
//! exist is that it knows nothing beyond the shape: no Win32, no libghostty,
//! no serde (see its `Cargo.toml`). `cwd`, `title` and `history` are facts
//! the *host* holds about a surface -- `split_tree::PaneId` is deliberately
//! just an opaque number, per its own doc comment -- so a leaf with those
//! fields cannot be a `split_tree::Node` without dragging host knowledge (and
//! a `serde` dependency) into the one crate that is tested by not having any.
//! This module owns a second, plain-data tree shape instead
//! (`SavedNode`/`SavedLeaf`) that exists only on the way to and from disk.
//! Building an actual tab uses the *existing* `layout::Shape` pipeline
//! (`to_layout_shape` below), not a new one.
//!
//! **`state_dir` is a parameter to `default_dir`, not a decision made
//! there** -- mirroring `Project.zig::defaultDir`, which does the same.
//! What that parameter actually *is* on Windows is settled, though (2026-09-10,
//! decided by the core owner): the same `xdg.state(subdir="polter")` root
//! `App.zig` already resolves for `poltergeist`'s chat/task logs, with
//! `projects` a *sibling* of whatever poltergeist keeps there -- not nested
//! under it. "A project is a terminal feature and should work with
//! poltergeist absent" is the reasoning; see `resolve_state_dir` below for
//! the Windows-side equivalent of that resolution. Note this is **the same
//! root** `plugins::user_dir()` and `session.rs` use (`%LOCALAPPDATA%\polter`,
//! or `session.rs`'s comment calls it), but a different *env-var category* --
//! those two read `XDG_CONFIG_HOME`, projects reads `XDG_STATE_HOME` -- so on
//! a system where a user has actually set both variables to different paths,
//! the two would diverge even though they look like the same folder today.

use std::path::{Path, PathBuf};

use polter_split_tree::{Axis, Node, PaneId};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A pane: one leaf of the *saved* tree. Not a `split_tree::Leaf` -- there is
/// no such type; `split_tree::Node::Leaf` holds a bare `PaneId`, and a
/// `PaneId` from a previous run means nothing (the host hands out fresh ones
/// every launch, see `split_tree`'s own doc comment on `PaneId`). So a saved
/// leaf holds what a `PaneId` would have pointed the host at, not the id
/// itself.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SavedLeaf {
    pub cwd: String,
    pub title: String,
    /// Opaque; see `Project.zig`'s `Leaf.history` doc comment. Never a path
    /// to open directly -- bash/zsh keys give a filename under
    /// `CommandHistory.defaultDir`, fish gives a `fish_history` session name.
    pub history: String,
}

/// One node of the saved tree: a pane, or a division of two more nodes.
#[derive(Clone, Debug, PartialEq)]
pub enum SavedNode {
    Leaf(SavedLeaf),
    Split { axis: Axis, ratio: f64, left: Box<SavedNode>, right: Box<SavedNode> },
}

/// The whole saved tab, matching `Project.zig`'s `Snapshot`.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub name: String,
    pub saved_at: i64,
    pub root: Option<SavedNode>,
}

/// Matches `Project.zig`'s `ReadError`: never a half a tree.
#[derive(Clone, Debug, PartialEq)]
pub enum ReadError {
    /// No project by this name exists.
    NotFound,
    /// The file exists but is not a complete, well-formed project.
    Corrupt,
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// Where projects live under Ghostty's state directory. Caller-supplied, like
/// `Project.zig`'s `defaultDir` -- see the module doc comment on why this file
/// does not resolve `state_dir` itself.
pub fn default_dir(state_dir: &Path) -> PathBuf {
    state_dir.join("projects")
}

/// The Windows-side equivalent of `xdg.state(subdir="polter")`: `%LOCALAPPDATA%`
/// (or `XDG_STATE_HOME` if a user has actually set it) joined with `polter`.
/// The result feeds `default_dir` to get to `…\polter\projects`.
///
/// Mirrors `plugins::user_dir`'s exact shape (env-var priority, `filter` on
/// non-empty, `None` rather than a deeper home-directory fallback if neither
/// is set) rather than `xdg.zig::dir`'s full fallback chain -- that is the
/// convention this host already uses for its own config directory, and there
/// is no report of `LOCALAPPDATA` actually being unset on a real machine to
/// justify the extra fallback `xdg.zig` has for POSIX. If that turns out to
/// matter in practice, this and `plugins::user_dir` should grow the same
/// fallback together, not this one alone.
pub fn resolve_state_dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .or_else(|| std::env::var_os("LOCALAPPDATA").filter(|v| !v.is_empty()))?;
    Some(PathBuf::from(base).join("polter"))
}

/// The path a project with this name is stored at, under `dir`
/// (`default_dir`'s return value).
pub fn path_for(dir: &Path, name: &str) -> PathBuf {
    dir.join(sanitize_filename(name))
}

const MAX_FILENAME_LEN: usize = 200;

/// Mirrors `Project.zig`'s `sanitizeFilename` exactly, including the
/// asymmetry it has: path separators, NUL and other control bytes become
/// `_`, the result is capped at 200 bytes, and -- **this is the one thing
/// worth pausing on** -- a name that sanitizes to nothing at all comes back
/// as literally `project`, with **no** `.json` suffix, because the length
/// check in `Project.zig` happens before the suffix is appended. Every
/// non-empty name gets the suffix; only the empty one does not. That reads
/// like an oversight, but agreement is the whole point of this file, so it
/// is copied rather than "fixed" here -- flag it to whoever owns
/// `Project.zig` if it should change, don't let the two sides drift apart
/// silently instead.
pub fn sanitize_filename(name: &str) -> String {
    let mut buf = String::new();
    for b in name.bytes() {
        if buf.len() >= MAX_FILENAME_LEN {
            break;
        }
        let safe = match b {
            0x00..=0x1f | 0x7f | b'/' | b'\\' => b'_',
            other => other,
        };
        buf.push(safe as char);
    }

    if buf.is_empty() {
        return "project".to_string();
    }

    buf.push_str(".json");
    buf
}

// ---------------------------------------------------------------------------
// Wire format: SavedNode <-> JSON (matches Project.zig's writeJson/parseNode)
// ---------------------------------------------------------------------------

/// `Axis` as `Project.zig`'s `Direction` spells it: full words, not
/// `layout.rs`'s `"h"`/`"v"`. **Do not reuse `layout::describe`'s mapping
/// here** -- they are two different wire formats for two different features
/// (the `poltergeist_layout` tool vs. this file), and the whole reason this
/// comment exists is that conflating them is the trap the axis doc comment
/// warns about, one level up: `Horizontal` is side-by-side (a vertical
/// divider) either way, but the *strings* are not interchangeable.
fn direction_str(axis: Axis) -> &'static str {
    match axis {
        Axis::Horizontal => "horizontal",
        Axis::Vertical => "vertical",
    }
}

fn direction_from_str(s: &str) -> Option<Axis> {
    match s {
        "horizontal" => Some(Axis::Horizontal),
        "vertical" => Some(Axis::Vertical),
        _ => None,
    }
}

fn node_to_json(node: &SavedNode) -> serde_json::Value {
    match node {
        SavedNode::Leaf(leaf) => {
            let mut obj = serde_json::Map::new();
            obj.insert("kind".to_string(), serde_json::Value::String("leaf".to_string()));
            // Omitted-when-empty, matching Project.zig's writeNode -- an
            // absent field and an empty string read back the same way
            // (`optionalStr(...) orelse ""`), so this is cosmetic, but
            // matching it keeps a saved file the same shape on either
            // platform for anyone diffing one by hand.
            if !leaf.cwd.is_empty() {
                obj.insert("cwd".to_string(), serde_json::Value::String(leaf.cwd.clone()));
            }
            if !leaf.title.is_empty() {
                obj.insert("title".to_string(), serde_json::Value::String(leaf.title.clone()));
            }
            if !leaf.history.is_empty() {
                obj.insert("history".to_string(), serde_json::Value::String(leaf.history.clone()));
            }
            serde_json::Value::Object(obj)
        }
        SavedNode::Split { axis, ratio, left, right } => serde_json::json!({
            "kind": "split",
            "direction": direction_str(*axis),
            "ratio": ratio,
            "left": node_to_json(left),
            "right": node_to_json(right),
        }),
    }
}

fn json_to_node(v: &serde_json::Value) -> Result<SavedNode, ReadError> {
    let obj = v.as_object().ok_or(ReadError::Corrupt)?;
    let kind = obj.get("kind").and_then(|k| k.as_str()).ok_or(ReadError::Corrupt)?;

    match kind {
        "leaf" => Ok(SavedNode::Leaf(SavedLeaf {
            cwd: opt_str(obj.get("cwd")),
            title: opt_str(obj.get("title")),
            history: opt_str(obj.get("history")),
        })),
        "split" => {
            let direction = obj
                .get("direction")
                .and_then(|d| d.as_str())
                .and_then(direction_from_str)
                .ok_or(ReadError::Corrupt)?;
            let ratio = obj.get("ratio").and_then(|r| r.as_f64()).ok_or(ReadError::Corrupt)?;
            // Both children required -- a split with only `left` is exactly
            // the half-a-tree `Project.zig`'s reader refuses to hand back,
            // so this does too, rather than producing a lopsided node.
            let left = json_to_node(obj.get("left").ok_or(ReadError::Corrupt)?)?;
            let right = json_to_node(obj.get("right").ok_or(ReadError::Corrupt)?)?;
            Ok(SavedNode::Split { axis: direction, ratio, left: Box::new(left), right: Box::new(right) })
        }
        _ => Err(ReadError::Corrupt),
    }
}

fn opt_str(v: Option<&serde_json::Value>) -> String {
    match v {
        Some(serde_json::Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

/// Matches `Project.zig`'s `writeJson`.
pub fn snapshot_to_json(snapshot: &Snapshot) -> serde_json::Value {
    let mut obj = serde_json::Map::new();
    obj.insert("name".to_string(), serde_json::Value::String(snapshot.name.clone()));
    obj.insert("saved_at".to_string(), serde_json::json!(snapshot.saved_at));
    if let Some(root) = &snapshot.root {
        obj.insert("root".to_string(), node_to_json(root));
    }
    serde_json::Value::Object(obj)
}

/// Matches `Project.zig`'s `parse`. Never returns half a `Snapshot`: any
/// structural problem is `Corrupt`, the same promise `Project.zig` makes.
pub fn parse_snapshot(bytes: &[u8]) -> Result<Snapshot, ReadError> {
    let parsed: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| ReadError::Corrupt)?;
    let obj = parsed.as_object().ok_or(ReadError::Corrupt)?;

    let name = obj.get("name").and_then(|n| n.as_str()).ok_or(ReadError::Corrupt)?.to_string();
    let saved_at = obj.get("saved_at").and_then(|s| s.as_i64()).ok_or(ReadError::Corrupt)?;
    let root = match obj.get("root") {
        Some(r) => Some(json_to_node(r)?),
        None => None,
    };

    Ok(Snapshot { name, saved_at, root })
}

// ---------------------------------------------------------------------------
// Disk I/O
// ---------------------------------------------------------------------------

/// Write the snapshot, replacing whatever project of this name was there.
/// Written to a temp file in `dir` first, then renamed over the target --
/// `std::fs::rename` on Windows replaces an existing destination file, so
/// this is the same atomic-replace shape `session.rs` already uses for its
/// own state file, and the same reason `Project.zig::write` gives: a
/// half-written file is exactly the "half a tree" this format promises never
/// to hand back.
pub fn write(dir: &Path, snapshot: &Snapshot) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let path = path_for(dir, &snapshot.name);
    let tmp = path.with_extension("json.tmp");
    let body = serde_json::to_string(&snapshot_to_json(snapshot))
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    std::fs::write(&tmp, body.as_bytes())?;
    std::fs::rename(&tmp, &path)
}

/// Read a project by name.
pub fn read(dir: &Path, name: &str) -> Result<Snapshot, ReadError> {
    let path = path_for(dir, name);
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(ReadError::NotFound),
        Err(_) => return Err(ReadError::Corrupt),
    };
    parse_snapshot(&bytes)
}

/// Delete a saved project. `NotFound` if there was no such project -- matches
/// `Project.zig::delete`.
pub fn delete(dir: &Path, name: &str) -> Result<(), ReadError> {
    let path = path_for(dir, name);
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(ReadError::NotFound),
        Err(_) => Err(ReadError::Corrupt),
    }
}

/// One entry from `list`: enough for a picker without reading every file
/// whole. Matches `Project.zig::Entry`.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub name: String,
    pub saved_at: i64,
}

/// List saved projects. Best-effort, matching `Project.zig::list`: an entry
/// this build cannot make sense of is skipped rather than failing the whole
/// listing, and a missing directory is an empty list, not an error.
///
/// **Inherits `Project.zig`'s `sanitizeFilename` gap on purpose (task 544 is
/// where that gets fixed, on the Zig side).** A project whose name sanitizes
/// to empty is saved as `project` with no `.json` suffix, and the `.json`
/// filter below -- copied from `Project.zig:442` -- will never surface it.
/// Fixing the filter here without the write side changing too would make
/// this list *disagree* with macOS's about which projects exist, which is
/// worse than both platforms sharing the same bug until 544 lands.
pub fn list(dir: &Path) -> Vec<Entry> {
    let mut entries = Vec::new();
    let Ok(read_dir) = std::fs::read_dir(dir) else {
        return entries;
    };
    for dirent in read_dir.flatten() {
        let path = dirent.path();
        if !path.is_file() {
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else { continue };
        if let Ok(snapshot) = parse_snapshot(&bytes) {
            entries.push(Entry { name: snapshot.name, saved_at: snapshot.saved_at });
        }
    }
    entries
}

// ---------------------------------------------------------------------------
// Rebuild: SavedNode -> the existing layout::Shape wire format
// ---------------------------------------------------------------------------

/// Turn a saved tree into the JSON `layout::parse` already understands, so
/// restoring a project reuses `poltergeist_layout`'s own pipeline
/// (`layout::perform` / `tabs::Op::ApplyLayout`) rather than a second way to
/// build a tab. **Still lossy for `title`**: `layout::Shape::New` carries
/// `cwd` and (since task 533's history wiring) `history`, but not title --
/// the caller applies that per pane *after* the shape comes back and hands
/// over which surface is which leaf (`layout::describe`'s output), via the
/// existing `set_tab_title` path. That follow-up step is not wired yet;
/// this function only answers "what shape, with what cwd and what history
/// handle".
///
/// Note the axis strings here are `"h"`/`"v"`, `layout.rs`'s convention --
/// **not** `direction_str`'s `"horizontal"`/`"vertical"` above. Two
/// different wire formats; see that function's doc comment.
pub fn to_layout_shape(node: &SavedNode) -> serde_json::Value {
    match node {
        SavedNode::Leaf(leaf) => {
            if leaf.cwd.is_empty() && leaf.history.is_empty() {
                serde_json::json!({ "new": null })
            } else {
                let mut new_obj = serde_json::Map::new();
                if !leaf.cwd.is_empty() {
                    new_obj.insert("cwd".to_string(), serde_json::Value::String(leaf.cwd.clone()));
                }
                if !leaf.history.is_empty() {
                    new_obj.insert("history".to_string(), serde_json::Value::String(leaf.history.clone()));
                }
                serde_json::json!({ "new": new_obj })
            }
        }
        SavedNode::Split { axis, ratio, left, right } => serde_json::json!({
            "split": match axis { Axis::Horizontal => "h", Axis::Vertical => "v" },
            "ratio": ratio,
            "left": to_layout_shape(left),
            "right": to_layout_shape(right),
        }),
    }
}

/// The other direction: a live tree plus a way to look up each pane's saved
/// metadata, turned into the tree this module saves. Mirrors `layout.rs`'s
/// `describe`, which does the same walk to turn a live tree into
/// `poltergeist_layout`'s reply JSON.
pub fn describe(node: &Node, meta_of: &dyn Fn(PaneId) -> SavedLeaf) -> SavedNode {
    match node {
        Node::Leaf(id) => SavedNode::Leaf(meta_of(*id)),
        Node::Split(s) => SavedNode::Split {
            axis: s.axis,
            ratio: s.ratio,
            left: Box::new(describe(&s.left, meta_of)),
            right: Box::new(describe(&s.right, meta_of)),
        },
    }
}

// ---------------------------------------------------------------------------
// `--write-project-fixture <path>`: the cross-implementation check
// ---------------------------------------------------------------------------

/// Writes the file `Project.zig`'s test suite is meant to read, from this
/// host's own writer -- the same shape as `plugins::write_fixture` /
/// `windows_host_settings.json`, and for the same reason stated there: a
/// unit test on either side alone proves only that an implementation agrees
/// with itself. Carries a quote, a backslash and non-ASCII on purpose, plus
/// a nested split and an empty-metadata leaf, since those are where two JSON
/// writers, and two readers' "field is optional" handling, actually diverge.
///
/// **Not yet wired to a Zig test.** Regenerating this from a real build and
/// checking a fixture into `src/poltergeist/testdata/` is real-machine work
/// (this crate does not run on the platform this comment is being written
/// on) -- tracked to happen in the same session as the other Windows-only
/// verification, not invented by hand here. A hand-typed "fixture" would
/// defeat the one property that makes this check worth having: it has to
/// come out of the shipped binary.
pub fn write_fixture(path: &str) -> bool {
    let right_leaf = SavedNode::Leaf(SavedLeaf {
        cwd: "C:\\work\\repo".to_string(),
        title: "a \"quoted\" title, a backslash \\, and 中文".to_string(),
        history: "a1b2c3.history".to_string(),
    });
    let left_leaf = SavedNode::Leaf(SavedLeaf::default());
    let root = SavedNode::Split {
        axis: Axis::Vertical,
        ratio: 0.4,
        left: Box::new(left_leaf),
        right: Box::new(right_leaf),
    };
    let snapshot = Snapshot { name: "fixture project".to_string(), saved_at: 1_757_000_000, root: Some(root) };

    let body = match serde_json::to_string_pretty(&snapshot_to_json(&snapshot)) {
        Ok(b) => b,
        Err(_) => return false,
    };
    std::fs::write(path, body.as_bytes()).is_ok()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Env-var-mutating tests must not run beside each other or anything else
    // that touches XDG_STATE_HOME/LOCALAPPDATA -- same reasoning as
    // `plugins::shipped_tests`'s `ENV_LOCK`.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn resolve_state_dir_prefers_xdg_state_home_over_localappdata() {
        let _guard = ENV_LOCK.lock().unwrap();
        let prev_xdg = std::env::var_os("XDG_STATE_HOME");
        let prev_local = std::env::var_os("LOCALAPPDATA");

        std::env::set_var("XDG_STATE_HOME", "C:\\xdg-state");
        std::env::set_var("LOCALAPPDATA", "C:\\local-appdata");
        assert_eq!(resolve_state_dir(), Some(PathBuf::from("C:\\xdg-state\\polter")));

        std::env::remove_var("XDG_STATE_HOME");
        assert_eq!(resolve_state_dir(), Some(PathBuf::from("C:\\local-appdata\\polter")));

        std::env::remove_var("LOCALAPPDATA");
        assert_eq!(resolve_state_dir(), None);

        match prev_xdg {
            Some(v) => std::env::set_var("XDG_STATE_HOME", v),
            None => std::env::remove_var("XDG_STATE_HOME"),
        }
        match prev_local {
            Some(v) => std::env::set_var("LOCALAPPDATA", v),
            None => std::env::remove_var("LOCALAPPDATA"),
        }
    }

    #[test]
    fn sanitize_filename_passes_a_plain_name_through() {
        assert_eq!(sanitize_filename("write retry decorator"), "write retry decorator.json");
    }

    #[test]
    fn sanitize_filename_replaces_separators_and_control_bytes() {
        assert_eq!(sanitize_filename("a/b\\c"), "a_b_c.json");
        assert_eq!(sanitize_filename("tab\ttab"), "tab_tab.json");
        assert_eq!(sanitize_filename("del\x7fdel"), "del_del.json");
    }

    #[test]
    fn sanitize_filename_caps_length() {
        let long = "x".repeat(500);
        let out = sanitize_filename(&long);
        // 200 x's, then ".json" -- the cap applies before the suffix, same
        // as Project.zig's loop-then-append order.
        assert_eq!(out.len(), MAX_FILENAME_LEN + ".json".len());
        assert!(out.starts_with(&"x".repeat(MAX_FILENAME_LEN)));
    }

    #[test]
    fn sanitize_filename_of_empty_name_has_no_json_suffix() {
        // See the doc comment on sanitize_filename: this is copied
        // deliberately, not fixed here. Only the truly-empty name skips the
        // suffix -- a name that sanitizes down to non-empty control bytes
        // still gets ".json", which is why the second assertion here is not
        // redundant with the first.
        assert_eq!(sanitize_filename(""), "project");
        assert_eq!(sanitize_filename("\x00\x00"), "__.json");
    }

    #[test]
    fn direction_strings_match_project_zig_not_layout_rs() {
        assert_eq!(direction_str(Axis::Horizontal), "horizontal");
        assert_eq!(direction_str(Axis::Vertical), "vertical");
        assert_eq!(direction_from_str("horizontal"), Some(Axis::Horizontal));
        assert_eq!(direction_from_str("vertical"), Some(Axis::Vertical));
        assert_eq!(direction_from_str("h"), None);
        assert_eq!(direction_from_str("v"), None);
    }

    fn sample_tree() -> SavedNode {
        let left = SavedNode::Leaf(SavedLeaf {
            cwd: "/work/repo".to_string(),
            title: "retry.py".to_string(),
            history: "a1b2c3.history".to_string(),
        });
        let right = SavedNode::Leaf(SavedLeaf { cwd: "/work/repo/tests".to_string(), ..Default::default() });
        SavedNode::Split { axis: Axis::Horizontal, ratio: 0.62, left: Box::new(left), right: Box::new(right) }
    }

    #[test]
    fn what_is_written_comes_back_exactly() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let snapshot = Snapshot { name: "写 retry 装饰器".to_string(), saved_at: 1_757_000_000, root: Some(sample_tree()) };
        write(&dir, &snapshot).expect("write should succeed");

        let back = read(&dir, "写 retry 装饰器").expect("read should succeed");
        assert_eq!(back, snapshot);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_project_with_no_layout_round_trips_as_an_empty_root() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-blank-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        write(&dir, &Snapshot { name: "blank".to_string(), saved_at: 1, root: None }).unwrap();
        let back = read(&dir, "blank").unwrap();
        assert!(back.root.is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn delete_removes_a_project_and_reading_it_after_is_not_found() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-delete-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        write(&dir, &Snapshot { name: "gone soon".to_string(), saved_at: 5, root: None }).unwrap();
        delete(&dir, "gone soon").unwrap();
        assert_eq!(read(&dir, "gone soon"), Err(ReadError::NotFound));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn deleting_a_project_that_does_not_exist_is_not_found() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-delete-missing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        assert_eq!(delete(&dir, "never existed"), Err(ReadError::NotFound));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn list_finds_every_saved_project_and_skips_a_corrupt_one() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-list-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        write(&dir, &Snapshot { name: "alpha".to_string(), saved_at: 10, root: None }).unwrap();
        write(&dir, &Snapshot { name: "beta".to_string(), saved_at: 20, root: None }).unwrap();
        std::fs::write(dir.join("garbage.json"), b"{not json").unwrap();

        let entries = list(&dir);
        assert_eq!(entries.len(), 2);
        assert!(entries.contains(&Entry { name: "alpha".to_string(), saved_at: 10 }));
        assert!(entries.contains(&Entry { name: "beta".to_string(), saved_at: 20 }));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn listing_a_directory_that_does_not_exist_yet_is_empty_not_an_error() {
        let dir = std::env::temp_dir().join("polter-project-rs-list-does-not-exist-4a1f");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(list(&dir), Vec::new());
    }

    #[test]
    fn reading_a_project_that_was_never_saved_is_not_found() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-missing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        assert_eq!(read(&dir, "no such project"), Err(ReadError::NotFound));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reading_from_a_directory_that_does_not_exist_yet_is_not_found_too() {
        let dir = std::env::temp_dir().join("polter-project-rs-does-not-exist-9c1f");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(read(&dir, "whatever"), Err(ReadError::NotFound));
    }

    #[test]
    fn a_split_missing_its_right_child_is_corrupt_not_a_lopsided_tree() {
        let bytes = br#"{"name":"lopsided","saved_at":4,"root":{"kind":"split",
            "direction":"horizontal","ratio":0.5,
            "left":{"kind":"leaf","cwd":"/a"}}}"#;
        assert_eq!(parse_snapshot(bytes), Err(ReadError::Corrupt));
    }

    #[test]
    fn truncated_json_is_corrupt() {
        let full = serde_json::to_vec(&snapshot_to_json(&Snapshot {
            name: "cutoff".to_string(),
            saved_at: 3,
            root: Some(sample_tree()),
        }))
        .unwrap();
        let half = &full[..full.len() / 2];
        assert_eq!(parse_snapshot(half), Err(ReadError::Corrupt));
    }

    #[test]
    fn to_layout_shape_carries_cwd_and_shape_but_not_title_or_history() {
        let shape = to_layout_shape(&sample_tree());
        assert_eq!(shape["split"], "h");
        assert_eq!(shape["left"]["new"]["cwd"], "/work/repo");
        // title/history are not part of layout::Shape at all -- this is the
        // lossy direction the doc comment on to_layout_shape describes.
        assert!(shape["left"]["new"].get("title").is_none());
        assert_eq!(shape["right"]["new"]["cwd"], "/work/repo/tests");
    }

    #[test]
    fn describe_walks_a_live_tree_into_a_saved_one() {
        use polter_split_tree::Split;

        let live = Node::Split(Box::new(Split {
            axis: Axis::Vertical,
            ratio: 0.5,
            left: Node::Leaf(1),
            right: Node::Leaf(2),
        }));

        let saved = describe(&live, &|id: PaneId| SavedLeaf {
            cwd: format!("/pane/{id}"),
            title: String::new(),
            history: String::new(),
        });

        match saved {
            SavedNode::Split { axis, left, right, .. } => {
                assert_eq!(axis, Axis::Vertical);
                assert_eq!(*left, SavedNode::Leaf(SavedLeaf { cwd: "/pane/1".to_string(), ..Default::default() }));
                assert_eq!(*right, SavedNode::Leaf(SavedLeaf { cwd: "/pane/2".to_string(), ..Default::default() }));
            }
            _ => panic!("expected a split"),
        }
    }
}
