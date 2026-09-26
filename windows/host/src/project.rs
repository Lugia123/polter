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
    /// The pane's scrollback snapshot, as a name **relative to
    /// `scrollback_dir`** of this project's file: `<ASCII digits>.snap`, or
    /// empty for none. Never a path -- the directory is derived by whoever
    /// reads the file, from the file's own path, so the three
    /// implementations' disagreeing name sanitizers (issue #23) never meet
    /// here. See `dev-docs/project-scrollback.md` §4.5.
    pub scrollback: String,
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
    /// The next scrollback snapshot number this project will hand out
    /// (`next_scrollback` on the wire, shared with macOS). See `Allocator`.
    ///
    /// ⚠️ **Read and written back even by a build that does not use it.** A
    /// writer that dropped a counter it did not understand would reset it,
    /// the next save would hand out a number some closed pane still has a
    /// file under, and a new pane would open with that pane's history.
    pub next_scrollback: Option<u64>,
}

/// Matches `Project.zig`'s `ReadError`: never a half a tree.
#[derive(Clone, Debug, PartialEq)]
pub enum ReadError {
    /// No project by this name exists.
    NotFound,
    /// The file exists but is not a complete, well-formed project.
    Corrupt,
    /// The name has nothing left once sanitized (`sanitize_filename`), so no
    /// file can be named after it. Matches `Project.zig`'s `InvalidName`.
    InvalidName,
}

/// A project name that names no file: nothing is left once it is sanitized.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidName;

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

/// The path a **new** project with this name is written to, under `dir`
/// (`default_dir`'s return value).
///
/// ⚠️ **Not how an existing project is found.** A project's identity is the
/// file `list` found (`Entry::path`), as on macOS: the rule that names files
/// has changed once (#838) and a file named by an earlier rule must still
/// open. Recomputing a path from a name is right only for the file this
/// build is about to write.
pub fn path_for(dir: &Path, name: &str) -> Result<PathBuf, InvalidName> {
    Ok(dir.join(sanitize_filename(name)?))
}

/// Where the scrollback snapshots of the project saved at `project_file`
/// live: the file's path with its extension replaced by `.scrollback`
/// (`foo.json` -> `foo.scrollback`, and the extensionless `project` that an
/// empty name sanitizes to -> `project.scrollback`).
///
/// ⚠️ **Derived from the file, never from the project's name.** Sanitizing
/// the name a second time is what the first design did, and it assumed every
/// implementation sanitizes alike -- Zig cuts at 200 bytes, Swift at 200
/// Characters (issue #23), so a snapshot would be written into one directory
/// and looked for in another, with nothing reporting it.
pub fn scrollback_dir(project_file: &Path) -> PathBuf {
    project_file.with_extension("scrollback")
}

/// Whether `name` is a snapshot name this format writes: ASCII digits, then
/// `.snap`, and nothing else.
///
/// **Checked on read, because the core deletes what it cannot decode.** A
/// restored pane's snapshot is removed when it is missing, stale or corrupt,
/// so a project file is -- through this one field -- a list of files the core
/// may delete. `../../somewhere/else.snap` passes the core's own `.snap`
/// check; it does not pass this one, and no separator or drive can.
pub fn is_scrollback_name(name: &str) -> bool {
    match name.strip_suffix(".snap") {
        Some(digits) => !digits.is_empty() && digits.len() <= 20 && digits.bytes().all(|b| b.is_ascii_digit()),
        None => false,
    }
}

/// Every leaf of `node`, in the order `describe` and `layout::fresh` walk
/// (left before right) -- the order a save numbers snapshots in, so the
/// caller can pair each leaf with the surface it met at the same position.
pub fn leaves_mut(node: &mut SavedNode) -> Vec<&mut SavedLeaf> {
    let mut out = Vec::new();
    fn walk<'a>(n: &'a mut SavedNode, out: &mut Vec<&'a mut SavedLeaf>) {
        match n {
            SavedNode::Leaf(l) => out.push(l),
            SavedNode::Split { left, right, .. } => {
                walk(left, out);
                walk(right, out);
            }
        }
    }
    walk(node, &mut out);
    out
}

/// Remove the snapshots in `dir` that this save did not name.
///
/// **The filter is what this code makes, not a pattern it happens to
/// recognise**: only `is_scrollback_name` files are candidates, and of those
/// only the ones not in `keep`. Anything else in the directory -- including
/// whatever temporary name the core writes before its rename -- is left
/// alone. Returns how many were removed. A missing directory is zero.
///
/// ⚠️ Captures are asynchronous. A capture from an *earlier* save of this
/// project, still queued for a pane index this save no longer has, can land
/// after this has run and leave one orphan behind; the next save removes it.
pub fn prune_scrollback_dir(dir: &Path, keep: &[String]) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    let mut removed = 0;
    for e in entries.flatten() {
        let name = e.file_name();
        let Some(name) = name.to_str() else { continue };
        if is_scrollback_name(name) && !keep.iter().any(|k| k == name) && std::fs::remove_file(e.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

/// The number in a snapshot name: `7` for `7.snap`. `None` for anything
/// `is_scrollback_name` refuses.
pub fn scrollback_number(name: &str) -> Option<u64> {
    if !is_scrollback_name(name) {
        return None;
    }
    name.strip_suffix(".snap")?.parse().ok()
}

/// A pane's snapshot: which project's directory it is in, and its name there.
/// **Held by the pane, for the pane's life** (`tabs::Pane::scrollback`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Slot {
    /// `scrollback_dir` of the project file. The project's identity for this
    /// purpose: numbers are handed out per project, so a pane saved into two
    /// projects has a number in each.
    pub dir: PathBuf,
    pub name: String,
}

impl Slot {
    /// The slot a pane was restored from, given the absolute path it was
    /// created with (`scrollback_path`). `None` for anything that is not a
    /// snapshot name inside a directory.
    pub fn from_restore_path(path: &str) -> Option<Slot> {
        let p = Path::new(path);
        let name = p.file_name()?.to_str()?;
        if !is_scrollback_name(name) {
            return None;
        }
        Some(Slot { dir: p.parent()?.to_path_buf(), name: name.to_string() })
    }
}

/// Hands out snapshot names that belong to a **pane**, not to a position.
///
/// ⚠️ **Why not "leaf `n` gets `n.snap`"** -- which is what this file first
/// did. Save a project, swap two panes, save it again: each pane's scrollback
/// is written into the file the *other* pane's leaf points at, and on restore
/// each pane shows the other's history. Nothing reports it; it looks like
/// success. The same shape on macOS is `ProjectScrollback.Allocator`, and this
/// follows it: a number is given to a pane the first time it is saved into a
/// project and stays with it, and **no number is ever given out twice** -- a
/// new pane given a closed pane's number would restore the closed pane's
/// history.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Allocator {
    /// The next number to hand out. Written back to the file as
    /// `next_scrollback`.
    pub next: u64,
}

impl Allocator {
    /// `stored` is the file's `next_scrollback`; `in_use` is every snapshot
    /// name the file refers to or the directory holds. Starts past all of
    /// them, so a file that lost its counter -- written before it existed,
    /// by hand, or by a writer that dropped it -- still cannot hand out a
    /// number that is taken.
    pub fn new<'a>(stored: Option<u64>, in_use: impl IntoIterator<Item = &'a str>) -> Allocator {
        let past = in_use.into_iter().filter_map(scrollback_number).map(|n| n + 1).max().unwrap_or(0);
        Allocator { next: stored.unwrap_or(0).max(past) }
    }

    /// The name for a pane in the project whose snapshots live in `dir`: the
    /// one it already has there, or a new one.
    pub fn name_for(&mut self, dir: &Path, current: Option<&Slot>) -> String {
        if let Some(slot) = current.filter(|s| s.dir == dir) {
            if let Some(n) = scrollback_number(&slot.name) {
                self.next = self.next.max(n + 1);
                return slot.name.clone();
            }
        }
        let name = format!("{}.snap", self.next);
        self.next += 1;
        name
    }
}

/// Every snapshot name a saved tree refers to.
pub fn scrollback_names(node: &SavedNode) -> Vec<String> {
    let mut out = Vec::new();
    fn walk(n: &SavedNode, out: &mut Vec<String>) {
        match n {
            SavedNode::Leaf(l) if !l.scrollback.is_empty() => out.push(l.scrollback.clone()),
            SavedNode::Leaf(_) => {}
            SavedNode::Split { left, right, .. } => {
                walk(left, out);
                walk(right, out);
            }
        }
    }
    walk(node, &mut out);
    out
}

const MAX_FILENAME_LEN: usize = 200;

/// The rule that names a new project file (#838). **One rule for all three
/// implementations**, pinned by `test/fixtures/project-filenames.tsv`, which
/// the tests below run row by row -- `src/Project.zig` and
/// `ProjectFilename.swift` run the same file.
///
/// Walk the name by Unicode scalar -- no normalisation, and **not** by
/// grapheme cluster: cluster boundaries depend on the Unicode version each
/// language's standard library ships, so a rule written in them could not be
/// identical in three languages. Replace every scalar at or below U+001F,
/// U+007F, and `/ \ : * ? " < > |` with `_`. Stop before the scalar that
/// would take the result past 200 UTF-8 bytes, so a multi-byte character is
/// never cut in half. Nothing left is `InvalidName`; otherwise append `.json`.
///
/// ⚠️ **What this replaced**, so it is not rebuilt: it walked `bytes()` and
/// pushed each byte `as char`, which turns every UTF-8 byte into its own
/// Latin-1 code point -- `写` came out as `å\u{86}\u{99}` -- so every
/// non-ASCII name got a different filename from the other two platforms,
/// and the 200 cap counted the mangled length. The round trip still passed,
/// because the writer and the reader mangled alike (#23).
pub fn sanitize_filename(name: &str) -> Result<String, InvalidName> {
    let mut buf = String::new();
    for c in name.chars() {
        let safe = match c {
            '\u{0}'..='\u{1f}' | '\u{7f}' | '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            other => other,
        };
        if buf.len() + safe.len_utf8() > MAX_FILENAME_LEN {
            break;
        }
        buf.push(safe);
    }
    if buf.is_empty() {
        return Err(InvalidName);
    }
    buf.push_str(".json");
    Ok(buf)
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
            if !leaf.scrollback.is_empty() {
                obj.insert("scrollback".to_string(), serde_json::Value::String(leaf.scrollback.clone()));
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
            // A name that is not one this format writes is dropped, not
            // refused: the pane still opens, just without its scrollback,
            // which is exactly what a missing snapshot gives. Refusing would
            // cost the whole project for one field. See `is_scrollback_name`
            // on why this is checked at all.
            scrollback: Some(opt_str(obj.get("scrollback"))).filter(|s| is_scrollback_name(s)).unwrap_or_default(),
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
    if let Some(n) = snapshot.next_scrollback {
        obj.insert("next_scrollback".to_string(), serde_json::json!(n));
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

    // Absent or not a whole number: `None`, and the allocator falls back on
    // the numbers actually in use (`Allocator::new`), which is what it would
    // do for a file written before the counter existed.
    let next_scrollback = obj.get("next_scrollback").and_then(|n| n.as_u64());

    Ok(Snapshot { name, saved_at, root, next_scrollback })
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
    let path = path_for(dir, &snapshot.name).map_err(|_| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "the project name is empty once sanitized")
    })?;
    std::fs::create_dir_all(dir)?;
    let tmp = path.with_extension("json.tmp");
    let body = serde_json::to_string(&snapshot_to_json(snapshot))
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    std::fs::write(&tmp, body.as_bytes())?;
    std::fs::rename(&tmp, &path)
}

/// Read the project this build would write under `name` -- the file a save
/// is about to replace. To open a project a person picked, use `read_file`
/// with the path `list` found (see `path_for`).
pub fn read(dir: &Path, name: &str) -> Result<Snapshot, ReadError> {
    read_file(&path_for(dir, name).map_err(|_| ReadError::InvalidName)?)
}

/// Read the project stored in `path`.
pub fn read_file(path: &Path) -> Result<Snapshot, ReadError> {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(ReadError::NotFound),
        Err(_) => return Err(ReadError::Corrupt),
    };
    parse_snapshot(&bytes)
}

/// Delete a saved project. `NotFound` if there was no such project -- matches
/// `Project.zig::delete`.
///
/// **Takes the project's snapshot directory with it** (`scrollback_dir`): its
/// snapshots mean nothing without the file that numbers them. That removal is
/// best-effort and after the file, so a failure there leaves orphans rather
/// than a project with its scrollback gone.
pub fn delete(dir: &Path, name: &str) -> Result<(), ReadError> {
    let path = path_for(dir, name).map_err(|_| ReadError::InvalidName)?;
    match std::fs::remove_file(&path) {
        Ok(()) => {
            let _ = std::fs::remove_dir_all(scrollback_dir(&path));
            Ok(())
        }
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
    /// The file this entry was read from. **This is the project's identity**
    /// for opening it -- see `path_for` on why a path is not recomputed from
    /// `name`.
    pub path: PathBuf,
}

/// List saved projects. Best-effort, matching `Project.zig::list`: an entry
/// this build cannot make sense of is skipped rather than failing the whole
/// listing, and a missing directory is an empty list, not an error.
///
/// **Skipping is unchanged; hiding it is not.** A project that fails to read
/// is still left out -- the same in all three implementations, and changing
/// it here alone would make them disagree about which projects exist -- but
/// every one left out is named in `Listing::skipped` with the reason, so the
/// caller can say so. A list that is quietly one short is how a project
/// "disappears" with nothing anywhere to search for.
pub fn list(dir: &Path) -> Listing {
    let mut out = Listing::default();
    let Ok(read_dir) = std::fs::read_dir(dir) else {
        return out;
    };
    for dirent in read_dir.flatten() {
        let path = dirent.path();
        if !path.is_file() {
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                out.skipped.push((path, format!("unreadable: {e}")));
                continue;
            }
        };
        match parse_snapshot(&bytes) {
            Ok(snapshot) => out.entries.push(Entry { name: snapshot.name, saved_at: snapshot.saved_at, path }),
            Err(e) => out.skipped.push((path, format!("{e:?}"))),
        }
    }
    out
}

/// What `list` found: the projects, and the `.json` files it left out.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Listing {
    pub entries: Vec<Entry>,
    /// Each file that looked like a project and could not be read as one,
    /// with why. Files that are not `.json` are not projects and are not here.
    pub skipped: Vec<(PathBuf, String)>,
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
/// this function only answers "what shape, with what cwd, what history
/// handle and what scrollback snapshot".
///
/// `snaps` is `scrollback_dir` of the file this snapshot was read from; a
/// leaf's relative `scrollback` name becomes an absolute path under it
/// (`scrollback_path`), which is what `ghostty_surface_config_s` takes.
///
/// Note the axis strings here are `"h"`/`"v"`, `layout.rs`'s convention --
/// **not** `direction_str`'s `"horizontal"`/`"vertical"` above. Two
/// different wire formats; see that function's doc comment.
pub fn to_layout_shape(node: &SavedNode, snaps: &Path) -> serde_json::Value {
    match node {
        SavedNode::Leaf(leaf) => {
            let scrollback = scrollback_path(snaps, leaf);
            if leaf.cwd.is_empty() && leaf.history.is_empty() && scrollback.is_none() {
                serde_json::json!({ "new": null })
            } else {
                let mut new_obj = serde_json::Map::new();
                if !leaf.cwd.is_empty() {
                    new_obj.insert("cwd".to_string(), serde_json::Value::String(leaf.cwd.clone()));
                }
                if !leaf.history.is_empty() {
                    new_obj.insert("history".to_string(), serde_json::Value::String(leaf.history.clone()));
                }
                if let Some(p) = scrollback {
                    new_obj.insert("scrollback".to_string(), serde_json::Value::String(p));
                }
                serde_json::json!({ "new": new_obj })
            }
        }
        SavedNode::Split { axis, ratio, left, right } => serde_json::json!({
            "split": match axis { Axis::Horizontal => "h", Axis::Vertical => "v" },
            "ratio": ratio,
            "left": to_layout_shape(left, snaps),
            "right": to_layout_shape(right, snaps),
        }),
    }
}

/// The absolute path of `leaf`'s snapshot under `snaps`, as UTF-8 (what the
/// C API takes), or `None` when it has none -- or when its name is not one
/// this format writes, which `json_to_node` already drops but a `SavedLeaf`
/// built some other way might still carry. A path that is not valid Unicode
/// cannot be handed over as UTF-8 and is `None` too: the pane opens without
/// scrollback rather than with a path the core would misread.
pub fn scrollback_path(snaps: &Path, leaf: &SavedLeaf) -> Option<String> {
    if !is_scrollback_name(&leaf.scrollback) {
        return None;
    }
    snaps.join(&leaf.scrollback).to_str().map(str::to_string)
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
        scrollback: "1.snap".to_string(),
    });
    let left_leaf = SavedNode::Leaf(SavedLeaf::default());
    let root = SavedNode::Split {
        axis: Axis::Vertical,
        ratio: 0.4,
        left: Box::new(left_leaf),
        right: Box::new(right_leaf),
    };
    let snapshot = Snapshot { name: "fixture project".to_string(), saved_at: 1_757_000_000, root: Some(root), next_scrollback: None };

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

    /// **The shared table, every row** (#838). The rule is a function, and
    /// a function cannot be pinned by a sample file of fields: it is pinned
    /// by input -> expected pairs that all three implementations run.
    ///
    /// ⚠️ **The row count is asserted against the table's own `# rows:`**:
    /// a reader that parsed nothing would otherwise pass every row it saw.
    /// `draft` rows are run and counted but not compared -- see the table's
    /// header for why they are still undecided.
    #[test]
    fn the_shared_filename_table_holds_for_this_implementation() {
        const TABLE: &str = include_str!("../../../test/fixtures/project-filenames.tsv");
        fn unhex(s: &str) -> Vec<u8> {
            (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex")).collect()
        }
        let mut declared = None;
        let (mut rows, mut asserted, mut drafts) = (0, 0, 0);
        let mut wrong = Vec::new();
        for (n, line) in TABLE.lines().enumerate() {
            let line = line.trim_end_matches('\r');
            if let Some(v) = line.strip_prefix("# rows:") {
                declared = Some(v.trim().parse::<usize>().expect("# rows: is a number"));
                continue;
            }
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            assert_eq!(f.len(), 4, "line {}: {} fields", n + 1, f.len());
            rows += 1;
            let input = String::from_utf8(unhex(f[0])).expect("input is UTF-8");
            let got = match sanitize_filename(&input) {
                Ok(name) => name,
                Err(InvalidName) => "ERR:InvalidName".to_string(),
            };
            let want = if f[1] == "ERR:InvalidName" {
                f[1].to_string()
            } else {
                String::from_utf8(unhex(f[1])).expect("expected is UTF-8")
            };
            match f[2] {
                "ok" => {
                    asserted += 1;
                    if got != want {
                        wrong.push(format!("line {} ({}): got {:?}, want {:?}", n + 1, f[3], got, want));
                    }
                }
                "draft" => drafts += 1,
                other => panic!("line {}: unknown status {other:?}", n + 1),
            }
        }
        assert_eq!(Some(rows), declared, "ran {rows} rows, the table declares {declared:?}");
        assert!(asserted > 0, "no row was compared");
        assert!(wrong.is_empty(), "{} of {} rows disagree ({} draft rows not compared):\n{}", wrong.len(), asserted, drafts, wrong.join("\n"));
    }

    /// **The NTFS characters, asserted here because the table only counts
    /// them.** Their two rows are `draft` in the shared table, so no
    /// implementation is held to them yet -- and this is the one platform
    /// where they bite: `a:b.json` is accepted by `CreateFileW` and becomes
    /// an extensionless `a` with the data in an alternate stream, silently.
    /// Same inputs and expectations as those two rows.
    #[test]
    fn ntfs_reserved_characters_are_replaced_on_this_platform_at_least() {
        assert_eq!(sanitize_filename("a:b"), Ok("a_b.json".to_string()));
        assert_eq!(sanitize_filename("*?\"<>|"), Ok("______.json".to_string()));
    }

    /// **A project whose file path is past MAX_PATH still saves, lists, opens
    /// and deletes** (issue #29) -- the whole of what this file does to disk.
    ///
    /// ⚠️ **Nothing here adds `\\?\`, and that is not an omission.** Rust's
    /// `std::fs` does it: every path it hands to Windows goes through
    /// `sys::path::windows::maybe_verbatim`, which prefixes anything of 248
    /// UTF-16 units or more (read in the 1.95.0 source; `File::open`,
    /// `create_dir`, `read_dir` call it, `rename`/`remove_file`/`remove_dir_all`
    /// reach it through `with_native_path`). This test is what says so on the
    /// machine, rather than a reading of somebody else's source.
    ///
    /// ⭐ **The positive control comes first and can fail the test.** The same
    /// path is opened with raw `CreateFileW` and no prefix, which must be
    /// refused. If it is not -- long paths are enabled on this machine
    /// (`LongPathsEnabled`) -- then nothing below would have been tested, and
    /// the test says so and fails instead of passing on a machine that cannot
    /// show the problem.
    #[cfg(windows)]
    #[test]
    fn a_project_past_max_path_saves_lists_opens_and_deletes() {
        use std::os::windows::ffi::OsStrExt as _;
        use windows::core::PCWSTR;
        use windows::Win32::Storage::FileSystem::{
            CreateFileW, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, FILE_GENERIC_WRITE, FILE_SHARE_READ,
        };

        let root = std::env::temp_dir().join(format!("polter-project-rs-longpath-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let mut dir = root.clone();
        while dir.as_os_str().encode_wide().count() < 230 {
            dir = dir.join("d".repeat(24));
        }
        let name = "n".repeat(40);
        let file = path_for(&dir, &name).unwrap();
        let units = file.as_os_str().encode_wide().count();
        assert!(units > 260, "the constructed path is only {units} UTF-16 units");
        std::fs::create_dir_all(&dir).expect("create the deep directory");

        // Positive control: the same file, raw, without `\\?\`.
        let mut wide: Vec<u16> = file.as_os_str().encode_wide().collect();
        wide.push(0);
        let raw = unsafe {
            CreateFileW(
                PCWSTR::from_raw(wide.as_ptr()),
                FILE_GENERIC_WRITE.0,
                FILE_SHARE_READ,
                None,
                CREATE_NEW,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
        };
        if let Ok(h) = raw {
            let _ = unsafe { windows::Win32::Foundation::CloseHandle(h) };
            let _ = std::fs::remove_dir_all(&root);
            panic!(
                "positive control did not fail: a raw CreateFileW of a {units}-unit path succeeded, so \
                 long paths are enabled on this machine and this test cannot show the MAX_PATH case"
            );
        }

        let snap = Snapshot {
            name: name.clone(),
            saved_at: 5,
            root: Some(SavedNode::Leaf(SavedLeaf { cwd: "C:\\w".to_string(), scrollback: "0.snap".to_string(), ..Default::default() })),
            next_scrollback: Some(1),
        };
        write(&dir, &snap).expect("write past MAX_PATH");
        assert!(file.exists(), "{file:?} was not written");
        assert_eq!(read_file(&file), Ok(snap.clone()));
        let listing = list(&dir);
        assert_eq!(listing.skipped, Vec::new());
        assert_eq!(listing.entries.len(), 1);
        assert_eq!(listing.entries[0].path, file);

        // The snapshot directory beside it, and pruning inside it.
        let snaps = scrollback_dir(&file);
        std::fs::create_dir_all(&snaps).expect("create the snapshot directory past MAX_PATH");
        std::fs::write(snaps.join("0.snap"), b"x").unwrap();
        std::fs::write(snaps.join("7.snap"), b"x").unwrap();
        assert_eq!(prune_scrollback_dir(&snaps, &["0.snap".to_string()]), 1);

        delete(&dir, &name).expect("delete past MAX_PATH");
        assert!(!file.exists());
        assert!(!snaps.exists(), "{snaps:?} outlived its project");

        let _ = std::fs::remove_dir_all(&root);
    }

    /// The case the table's second column cannot express on its own: a name
    /// with nothing left is refused, never written as a bare `project`.
    #[test]
    fn a_name_with_nothing_left_cannot_be_saved() {
        assert_eq!(sanitize_filename(""), Err(InvalidName));
        let dir = std::env::temp_dir().join(format!("polter-project-rs-empty-{}", std::process::id()));
        let snap = Snapshot { name: String::new(), saved_at: 1, root: None, next_scrollback: None };
        assert!(write(&dir, &snap).is_err());
        assert!(!dir.join("project").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Opened by the file the listing found**, not by recomputing a path
    /// from the name: a project written under an earlier naming rule (say
    /// the old byte-wise one, which mangled `写`) still opens.
    #[test]
    fn a_project_opens_from_the_file_list_found_even_if_its_name_now_maps_elsewhere() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-legacy-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let snap = Snapshot { name: "写".to_string(), saved_at: 7, root: None, next_scrollback: None };
        // The old rule's filename for "写": each UTF-8 byte as its own char.
        let legacy = dir.join("\u{e5}\u{86}\u{99}.json");
        std::fs::write(&legacy, serde_json::to_vec(&snapshot_to_json(&snap)).unwrap()).unwrap();

        let listing = list(&dir);
        assert_eq!(listing.entries.len(), 1);
        assert_eq!(listing.entries[0].path, legacy);
        assert_eq!(read_file(&listing.entries[0].path), Ok(snap));
        assert_eq!(read(&dir, "写"), Err(ReadError::NotFound), "the name alone no longer finds it");

        let _ = std::fs::remove_dir_all(&dir);
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
            scrollback: "0.snap".to_string(),
        });
        let right = SavedNode::Leaf(SavedLeaf { cwd: "/work/repo/tests".to_string(), ..Default::default() });
        SavedNode::Split { axis: Axis::Horizontal, ratio: 0.62, left: Box::new(left), right: Box::new(right) }
    }

    #[test]
    fn what_is_written_comes_back_exactly() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let snapshot = Snapshot { name: "写 retry 装饰器".to_string(), saved_at: 1_757_000_000, root: Some(sample_tree()), next_scrollback: None };
        write(&dir, &snapshot).expect("write should succeed");

        let back = read(&dir, "写 retry 装饰器").expect("read should succeed");
        assert_eq!(back, snapshot);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_project_with_no_layout_round_trips_as_an_empty_root() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-blank-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        write(&dir, &Snapshot { name: "blank".to_string(), saved_at: 1, root: None, next_scrollback: None }).unwrap();
        let back = read(&dir, "blank").unwrap();
        assert!(back.root.is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn delete_removes_a_project_and_reading_it_after_is_not_found() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-delete-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        write(&dir, &Snapshot { name: "gone soon".to_string(), saved_at: 5, root: None, next_scrollback: None }).unwrap();
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

        write(&dir, &Snapshot { name: "alpha".to_string(), saved_at: 10, root: None, next_scrollback: None }).unwrap();
        write(&dir, &Snapshot { name: "beta".to_string(), saved_at: 20, root: None, next_scrollback: None }).unwrap();
        std::fs::write(dir.join("garbage.json"), b"{not json").unwrap();

        let listing = list(&dir);
        let entries = listing.entries;
        // Left out, as before -- and now said so, by name.
        assert_eq!(listing.skipped.len(), 1, "{:?}", listing.skipped);
        assert_eq!(listing.skipped[0].0, dir.join("garbage.json"));
        assert_eq!(entries.len(), 2);
        assert!(entries.contains(&Entry { name: "alpha".to_string(), saved_at: 10, path: dir.join("alpha.json") }));
        assert!(entries.contains(&Entry { name: "beta".to_string(), saved_at: 20, path: dir.join("beta.json") }));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn listing_a_directory_that_does_not_exist_yet_is_empty_not_an_error() {
        let dir = std::env::temp_dir().join("polter-project-rs-list-does-not-exist-4a1f");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(list(&dir), Listing::default());
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
            next_scrollback: None,
        }))
        .unwrap();
        let half = &full[..full.len() / 2];
        assert_eq!(parse_snapshot(half), Err(ReadError::Corrupt));
    }

    /// **The floor under every field this format grows.** A file written by a
    /// newer build -- one that knows a field this one does not, such as the
    /// scrollback snapshot a pane may carry -- must still open here, with
    /// every field this build does know read correctly. `json_to_node` and
    /// `parse_snapshot` look fields up by name and ignore the rest, so today
    /// this holds; this test is what keeps a stricter reader from breaking
    /// every project saved by the next version.
    #[test]
    fn a_file_with_fields_this_build_does_not_know_still_reads() {
        let bytes = br#"{"name":"from the future","saved_at":9,"format":2,
            "root":{"kind":"split","direction":"vertical","ratio":0.25,"weight":3,
              "left":{"kind":"leaf","cwd":"/a","title":"t","history":"h.history",
                      "scrollback":"0.snap","colour":{"r":1}},
              "right":{"kind":"leaf","unheard_of":[1,2,3]}}}"#;
        let want = Snapshot {
            name: "from the future".to_string(),
            saved_at: 9,
            root: Some(SavedNode::Split {
                axis: Axis::Vertical,
                ratio: 0.25,
                left: Box::new(SavedNode::Leaf(SavedLeaf {
                    cwd: "/a".to_string(),
                    title: "t".to_string(),
                    history: "h.history".to_string(),
                    scrollback: "0.snap".to_string(),
                })),
                right: Box::new(SavedNode::Leaf(SavedLeaf::default())),
            }),
            next_scrollback: None,
        };
        assert_eq!(parse_snapshot(bytes), Ok(want));
    }

    /// **Every field of a leaf and of the snapshot reaches the file**, and
    /// the list of fields checked here is the struct's own, not one kept by
    /// hand beside it.
    ///
    /// ⚠️ The destructuring patterns below have no `..` on purpose. Adding a
    /// field to `SavedLeaf` or `Snapshot` -- as `scrollback` was -- is a
    /// compile error here until that field is
    /// given its JSON key in `expect`. A writer that forgets the new field is
    /// then a red assertion that names the key, instead of a project that
    /// silently loses it on the next save. (This file is one of three
    /// implementations of the format -- `src/Project.zig`, this one, and the
    /// mac one -- and this test only speaks for this one.)
    #[test]
    fn every_field_is_written() {
        let leaf = SavedLeaf {
            cwd: "C:\\work".to_string(),
            title: "a title".to_string(),
            history: "a1b2.history".to_string(),
            scrollback: "7.snap".to_string(),
        };
        let SavedLeaf { cwd, title, history, scrollback } = &leaf;
        let expect: [(&str, &str); 4] =
            [("cwd", cwd), ("title", title), ("history", history), ("scrollback", scrollback)];

        let snapshot = Snapshot {
            name: "all fields".to_string(),
            saved_at: 42,
            root: Some(SavedNode::Leaf(leaf.clone())),
            next_scrollback: Some(8),
        };
        let Snapshot { name, saved_at, root: _, next_scrollback } = &snapshot;
        let json = snapshot_to_json(&snapshot);
        assert_eq!(json.get("next_scrollback").and_then(|v| v.as_u64()), *next_scrollback, "`next_scrollback` was not written");

        assert_eq!(json.get("name").and_then(|v| v.as_str()), Some(name.as_str()), "`name` was not written");
        assert_eq!(json.get("saved_at").and_then(|v| v.as_i64()), Some(*saved_at), "`saved_at` was not written");
        let node = json.get("root").and_then(|v| v.as_object()).expect("`root` was not written");
        assert_eq!(node.get("kind").and_then(|v| v.as_str()), Some("leaf"));
        for (key, value) in expect {
            assert_eq!(node.get(key).and_then(|v| v.as_str()), Some(value), "leaf field `{key}` was not written");
        }
        // `kind` plus one key per field: nothing written that the reader
        // does not know about.
        assert_eq!(node.len(), expect.len() + 1, "leaf has keys this test does not name: {node:?}");
    }

    #[test]
    fn a_scrollback_name_is_only_what_a_save_writes() {
        for ok in ["0.snap", "12.snap", "00000000000000000001.snap"] {
            assert!(is_scrollback_name(ok), "{ok:?} should be accepted");
        }
        for bad in [
            "",
            ".snap",
            "a.snap",
            "-1.snap",
            "0.SNAP",
            "0.snap.tmp",
            "0",
            "../0.snap",
            "0/1.snap",
            "..\\0.snap",
            "C:\\x\\0.snap",
            "１.snap", // full-width digit: not ASCII
            "000000000000000000001.snap", // 21 digits
        ] {
            assert!(!is_scrollback_name(bad), "{bad:?} should be refused");
        }
    }

    /// The case `is_scrollback_name` exists for: a project file is, through
    /// this field, a list of files the core may delete. A name reaching
    /// outside the snapshot directory is dropped and the rest of the pane
    /// still loads.
    #[test]
    fn a_scrollback_name_that_reaches_outside_is_dropped_and_the_pane_still_loads() {
        let bytes = br#"{"name":"p","saved_at":1,
            "root":{"kind":"leaf","cwd":"/a","scrollback":"..\\..\\Users\\x\\keep.snap"}}"#;
        let snap = parse_snapshot(bytes).expect("one bad field must not cost the project");
        assert_eq!(snap.root, Some(SavedNode::Leaf(SavedLeaf { cwd: "/a".to_string(), ..Default::default() })));
    }

    #[test]
    fn the_snapshot_directory_is_the_project_file_with_its_extension_replaced() {
        // From a file path, not a name: which file a name maps to is
        // `path_for`'s business (and differs between the implementations,
        // issue #23), and this function must not have an opinion on it.
        let dir = Path::new("/state/projects");
        assert_eq!(scrollback_dir(&dir.join("写 retry.json")), dir.join("写 retry.scrollback"));
        assert_eq!(scrollback_dir(&dir.join("v1.2.json")), dir.join("v1.2.scrollback"));
    }

    #[test]
    fn pruning_removes_only_the_snapshots_this_save_did_not_name() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-prune-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for f in ["0.snap", "1.snap", "2.snap", "1.snap.tmp", "notes.txt"] {
            std::fs::write(dir.join(f), b"x").unwrap();
        }

        let removed = prune_scrollback_dir(&dir, &["0.snap".to_string(), "2.snap".to_string()]);

        let mut left: Vec<String> =
            std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        left.sort();
        assert_eq!(removed, 1);
        assert_eq!(left, ["0.snap", "1.snap.tmp", "2.snap", "notes.txt"]);
        assert_eq!(prune_scrollback_dir(&dir.join("absent"), &[]), 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn deleting_a_project_takes_its_snapshot_directory_with_it() {
        let dir = std::env::temp_dir().join(format!("polter-project-rs-delete-snaps-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        write(&dir, &Snapshot { name: "with snaps".to_string(), saved_at: 1, root: None, next_scrollback: None }).unwrap();
        let snaps = scrollback_dir(&path_for(&dir, "with snaps").unwrap());
        std::fs::create_dir_all(&snaps).unwrap();
        std::fs::write(snaps.join("0.snap"), b"x").unwrap();

        delete(&dir, "with snaps").unwrap();
        assert!(!snaps.exists(), "{snaps:?} outlived its project");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The floor this allocator exists for**: two panes saved, swapped,
    /// saved again. Each must keep the number it was given, so each leaf
    /// points at the file its own pane writes -- whatever position it is in.
    /// Numbering by position passes every single-pane and every unchanged-
    /// layout test, and fails this one.
    #[test]
    fn a_pane_keeps_its_snapshot_when_the_layout_changes() {
        let dir = Path::new("/p/x.scrollback");
        // Pane A and pane B, by identity; each holds its slot.
        let mut slot_a: Option<Slot> = None;
        let mut slot_b: Option<Slot> = None;

        // First save: A left of B.
        let mut alloc = Allocator::new(None, []);
        let a1 = alloc.name_for(dir, slot_a.as_ref());
        slot_a = Some(Slot { dir: dir.to_path_buf(), name: a1.clone() });
        let b1 = alloc.name_for(dir, slot_b.as_ref());
        slot_b = Some(Slot { dir: dir.to_path_buf(), name: b1.clone() });
        assert_ne!(a1, b1);
        let stored = alloc.next;

        // Second save of the same project, B now left of A.
        let mut alloc = Allocator::new(Some(stored), [a1.as_str(), b1.as_str()]);
        let leaf0 = alloc.name_for(dir, slot_b.as_ref()); // B, now first
        let leaf1 = alloc.name_for(dir, slot_a.as_ref()); // A, now second
        assert_eq!(leaf0, b1, "B's history must stay in B's file after the swap");
        assert_eq!(leaf1, a1, "A's history must stay in A's file after the swap");
    }

    #[test]
    fn a_closed_panes_number_is_never_given_to_a_new_pane() {
        let dir = Path::new("/p/x.scrollback");
        // Saved with two panes (0 and 1); pane 1 then closed and its file
        // pruned. The counter says 2, and a new pane must get 2, not 1.
        let mut alloc = Allocator::new(Some(2), ["0.snap"]);
        let kept = Slot { dir: dir.to_path_buf(), name: "0.snap".to_string() };
        assert_eq!(alloc.name_for(dir, Some(&kept)), "0.snap");
        assert_eq!(alloc.name_for(dir, None), "2.snap");
    }

    #[test]
    fn a_file_that_lost_its_counter_starts_past_every_number_in_use() {
        let mut alloc = Allocator::new(None, ["4.snap", "junk", "1.snap", "../9.snap"]);
        assert_eq!(alloc.name_for(Path::new("/p/x.scrollback"), None), "5.snap");
        // A stored counter behind what is on disk loses to what is on disk.
        let mut alloc = Allocator::new(Some(2), ["6.snap"]);
        assert_eq!(alloc.name_for(Path::new("/p/x.scrollback"), None), "7.snap");
    }

    #[test]
    fn a_slot_from_another_project_is_not_reused_here() {
        let here = Path::new("/p/this.scrollback");
        let other = Slot { dir: PathBuf::from("/p/other.scrollback"), name: "0.snap".to_string() };
        let mut alloc = Allocator::new(Some(3), []);
        assert_eq!(alloc.name_for(here, Some(&other)), "3.snap");
    }

    #[test]
    fn a_restore_path_gives_back_the_panes_slot() {
        let p = Path::new("/p/x.scrollback").join("4.snap");
        assert_eq!(
            Slot::from_restore_path(p.to_str().unwrap()),
            Some(Slot { dir: PathBuf::from("/p/x.scrollback"), name: "4.snap".to_string() })
        );
        assert_eq!(Slot::from_restore_path("/p/x.scrollback/notes.txt"), None);
    }

    /// **Read and written back unchanged**, which is a different promise from
    /// "an unknown field does not make the read fail": that one keeps the
    /// project opening, this one keeps the counter from being reset by a
    /// round trip through this build.
    #[test]
    fn next_scrollback_survives_a_read_and_a_write() {
        let bytes = br#"{"name":"p","saved_at":1,"next_scrollback":12,"root":{"kind":"leaf","scrollback":"11.snap"}}"#;
        let snap = parse_snapshot(bytes).unwrap();
        assert_eq!(snap.next_scrollback, Some(12));
        let again = snapshot_to_json(&snap);
        assert_eq!(again.get("next_scrollback").and_then(|v| v.as_u64()), Some(12));
        assert_eq!(parse_snapshot(&serde_json::to_vec(&again).unwrap()).unwrap(), snap);
    }

    #[test]
    fn to_layout_shape_turns_a_scrollback_name_into_a_path_under_the_snapshot_directory() {
        let snaps = Path::new("/p/x.scrollback");
        let shape = to_layout_shape(&sample_tree(), snaps);
        assert_eq!(shape["left"]["new"]["scrollback"], snaps.join("0.snap").to_str().unwrap());
        assert!(shape["right"]["new"].get("scrollback").is_none());
    }

    /// The keys found on each kind of object in a project file, `kind`
    /// itself left out -- it is the discriminator, not a field.
    fn key_sets(file: &serde_json::Value) -> [(&'static str, std::collections::BTreeSet<String>); 3] {
        fn walk(node: &serde_json::Value, leaf: &mut std::collections::BTreeSet<String>, split: &mut std::collections::BTreeSet<String>) {
            let obj = node.as_object().expect("a node is an object");
            let into = match obj.get("kind").and_then(|k| k.as_str()) {
                Some("leaf") => &mut *leaf,
                Some("split") => &mut *split,
                other => panic!("unknown node kind {other:?}"),
            };
            into.extend(obj.keys().filter(|k| *k != "kind").cloned());
            if obj.get("kind").and_then(|k| k.as_str()) == Some("split") {
                walk(&obj["left"], leaf, split);
                walk(&obj["right"], leaf, split);
            }
        }
        let top = file.as_object().expect("a project file is an object");
        let (mut leaf, mut split) = (Default::default(), Default::default());
        if let Some(root) = top.get("root") {
            walk(root, &mut leaf, &mut split);
        }
        [("snapshot", top.keys().cloned().collect()), ("leaf", leaf), ("split", split)]
    }

    /// **The same file `src/Project.zig` and the mac tests check against.**
    /// `test/project-format/all_fields.json` is one project with every field
    /// of the format filled in; this checks that every key in it survives this
    /// implementation's read-then-write, and that this implementation writes
    /// no key it lacks. `every_field_is_written` above keeps this file's
    /// writer honest about its own struct; this is what keeps it honest about
    /// the other two implementations, which nothing here compiles.
    ///
    /// Adding a field to the format: add it to the sample first, and this
    /// test (and theirs) name what has not caught up.
    #[test]
    fn the_shared_sample_survives_this_build_and_this_build_writes_nothing_it_lacks() {
        const SAMPLE: &str = include_str!("../../../test/project-format/all_fields.json");
        let sample: serde_json::Value = serde_json::from_str(SAMPLE).expect("the shared sample is JSON");
        let written = snapshot_to_json(&parse_snapshot(SAMPLE.as_bytes()).expect("the shared sample must read"));

        // What this build writes when every field it has is filled in. No
        // `..` in the literals: a field added to either struct is a compile
        // error here until it is given a (non-empty) value.
        let own = snapshot_to_json(&Snapshot {
            name: "n".to_string(),
            saved_at: 1,
            root: Some(SavedNode::Split {
                axis: Axis::Horizontal,
                ratio: 0.5,
                left: Box::new(SavedNode::Leaf(SavedLeaf {
                    cwd: "c".to_string(),
                    title: "t".to_string(),
                    history: "h".to_string(),
                    scrollback: "5.snap".to_string(),
                })),
                right: Box::new(SavedNode::Leaf(SavedLeaf::default())),
            }),
            next_scrollback: Some(9),
        });

        let mut problems = Vec::new();
        for (((what, want), (_, got)), (_, mine)) in key_sets(&sample).into_iter().zip(key_sets(&written)).zip(key_sets(&own)) {
            for k in want.difference(&got) {
                problems.push(format!(
                    "windows/host/src/project.rs loses {what}.{k}: it is in test/project-format/all_fields.json \
                     but does not come back out of parse_snapshot + snapshot_to_json -- carry it in \
                     SavedLeaf/Snapshot, json_to_node/parse_snapshot and node_to_json/snapshot_to_json"
                ));
            }
            for k in got.union(&mine).filter(|k| !want.contains(*k)) {
                problems.push(format!(
                    "windows/host/src/project.rs writes {what}.{k}, which test/project-format/all_fields.json \
                     does not have -- add it there, then to src/Project.zig and \
                     macos/Sources/Features/Projects/ProjectDocument.swift, whose tests read the same file"
                ));
            }
        }
        assert!(problems.is_empty(), "\n{}", problems.join("\n"));

        // Same keys is not same values: a writer that swapped `cwd` and
        // `title` passes everything above.
        assert_eq!(written, sample, "the shared sample did not come back as it went in");
    }

    #[test]
    fn to_layout_shape_carries_cwd_and_shape_but_not_title_or_history() {
        let shape = to_layout_shape(&sample_tree(), Path::new("/p/x.scrollback"));
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

        let saved = describe(&live, &|id: PaneId| SavedLeaf { cwd: format!("/pane/{id}"), ..Default::default() });

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
