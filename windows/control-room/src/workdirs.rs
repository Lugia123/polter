//! The working-directories page's data and rules (task 3148, `#2140` W2;
//! the macOS host's `ControlRoomWorkdirs.swift`).
//!
//! What arrives here is two answers, and nothing else:
//!
//! * the **page** -- `{"page":"workdirs","group":…}`, the group's working
//!   directories (`files/Workdirs.zig`), read by [`read`];
//! * one **level** of a directory -- `files_list(token, rel)`, answered from
//!   `files/Listing.zig`, read by [`read_listing`].
//!
//! A ticket is what a level is asked with (`files/Tickets.zig`), and this
//! file builds the three requests as text -- the same text the socket would
//! carry -- so that what the host sends is a value with a test rather than a
//! string built at the call site: [`request`], [`listing_request`],
//! [`open_request`].
//!
//! # What this file decides, and what it must not
//!
//! **It is a host file, so it draws and does not decide.** Which rows a
//! directory holds, their order, and what is left out of it are the core's
//! (`Listing.zig`: directories first, then by name, with `Watch`'s excluded
//! directories already gone). Nothing here sorts, filters or counts rows,
//! and `tools/control-room-hosts-do-not-decide.py` reads this file for
//! exactly that. The two fields it refuses for a second reason are `kind`
//! and `tree_name`: a host has nothing to do with a kind but compare it,
//! and the macOS host decodes neither (`ControlRoomWorkdirs.swift`'s `Dir`).
//!
//! What *is* worked out here is the tree: which roots are open, which
//! directories under them are open, which rows that makes visible, and the
//! paths those rows stand for. Those are decisions about the person's
//! screen, not about what the core says, and the macOS host has them here
//! too (`Tree`, `Levels`, `nodes(under:in:)`).
//!
//! # Two answers and a refusal
//!
//! **A refusal is not a parse failure.** The page door answers
//! `{"error":"NoSuchGroup"}` and the files door answers
//! `{"refused":"access","reason":"outside","why":…}` -- both are
//! well-formed JSON documents in which the core said no, and folding either
//! into [`Failure::NotJson`] would throw away the one word a person needs.
//! That is [`Failure`]'s three cases, the same three the macOS host has.

use crate::json::{self, Value};
use crate::reader::{at, Reader};

/// The page's key in a request and in its answer.
pub const PAGE: &str = "workdirs";

/// The scope a root's tree is listed with. **`workdir`, and wider than a
/// preview's `file` on purpose**: a tree shows what is *under* a directory,
/// so a ticket that reached only its own anchor could list one level and
/// nothing below it (`Tickets.list`). One ticket per root is minted and
/// kept; the file opened in the workbench gets a ticket of its own, on
/// itself, with [`FILE_SCOPE`].
pub const ROOT_SCOPE: &str = "workdir";

/// The scope a previewed file's ticket is made with: the file itself.
pub const FILE_SCOPE: &str = "file";

/// One working directory, as the page says it. **A subset**: `kind`,
/// `tree_name`, `who`, `also_in` and `editing` are sent and none of them is
/// read here -- the first two for the reason in the file's header, the
/// last three because the workbench does not draw them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dir {
    /// 16 hex digits of a hash of `path`. **This is what `files_open` wants
    /// as `workdir_id`** (`Workdirs.writeJson`), so a ticket is asked for
    /// by this and never by a path.
    pub id: String,
    /// Real: every link followed.
    pub path: String,
    /// `path` with the home directory written `~`. The row's name.
    pub short: String,
    /// False for a row the page lists but nothing may be read from (`/`,
    /// the home directory, above it); the reason is in `why`.
    pub readable: bool,
    /// The core's own reason, when `readable` is false.
    pub why: Option<String>,
}

/// The whole page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub group: String,
    /// In the core's order (`Workdirs` puts the supervisor's first and the
    /// person's own last). Never sorted here.
    pub dirs: Vec<Dir>,
    /// Fields a [`Dir`] needed and the answer did not have. Not drawn; the
    /// host writes them down (`reader`).
    pub missing: Vec<String>,
}

/// One thing in a directory: a name and whether it opens.
///
/// **`is_dir` and not a `kind`.** The core sends `is_dir` and says why in
/// `Listing.writeJson`: it is the one thing the row is asked and it cannot
/// be compared with anything.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The name only. The directory it is in is the one the level was asked
    /// about, so a row carries no path of its own.
    pub name: String,
    /// A directory, or a link that leads to one.
    pub is_dir: bool,
}

/// One level of a directory, as the core answers it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Level {
    pub entries: Vec<Entry>,
    /// How many were past the core's own limit and are not here
    /// (`Listing.max_entries`); 0 when the whole level came.
    pub more: u64,
    /// Fields the level needed and did not have, as [`Answer::missing`].
    pub missing: Vec<String>,
}

/// Why an answer could not be read -- **or that the core said no.**
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// Not JSON, or not the document this takes.
    NotJson,
    /// The page door said no, in its one shape: `{"error": …}`. The word is
    /// the core's (`NoSuchGroup` is the one a host most often sees).
    Refused(String),
    /// The files door said no, in that door's shape:
    /// `{"refused":"access","reason":"outside","why":…}`. **Not the case
    /// above**: one name is not a code, a reason and a sentence.
    RefusedFile { code: String, reason: Option<String>, why: Option<String> },
    /// The answer is this door's but not the page/level this build knows.
    Unknown(String),
    /// **The request never reached the core, or it did not answer** -- the
    /// core not running, the door missing from this build. The host's own
    /// sentence, kept here so that a directory whose level could not be
    /// asked for is stored like any other refusal (and is not asked for
    /// again on every redraw).
    Unavailable(String),
}

impl Failure {
    /// The sentence a person reads, as the core wrote it where it wrote one.
    /// None for [`Failure::NotJson`] and [`Failure::Unknown`], which have no
    /// core word to give: the host says its own sentence for those.
    pub fn why(&self) -> Option<&str> {
        match self {
            Failure::NotJson | Failure::Unknown(_) => None,
            Failure::Refused(word) => Some(word),
            Failure::RefusedFile { why, .. } => why.as_deref(),
            Failure::Unavailable(said) => Some(said),
        }
    }
}

// ------------------------------------------------------------------ requests

/// The page's request for `group` (`ControlRoomWorkdirs.request`).
pub fn request(group: &str) -> String {
    format!(r#"{{"page":"workdirs","group":{}}}"#, json::quote(group))
}

/// `files_list` for the directory the ticket `token` was made for, or for
/// the directory `rel` names under it. **Empty `rel` is the ticket's own
/// path** -- one level of the directory the ticket is on.
pub fn listing_request(token: &str, rel: &str) -> String {
    format!(
        r#"{{"method":"files_list","params":{{"token":{},"rel":{}}}}}"#,
        json::quote(token),
        json::quote(rel)
    )
}

/// `files_open` for `path` in the workdir `workdir_id`, as one ticket
/// covering `scope` (`file` or `workdir`).
pub fn open_request(workdir_id: &str, path: &str, scope: &str) -> String {
    format!(
        r#"{{"method":"files_open","params":{{"workdir_id":{},"path":{},"scope":{}}}}}"#,
        json::quote(workdir_id),
        json::quote(path),
        json::quote(scope)
    )
}

// ------------------------------------------------------------------ reading

/// The page, or what could not be read of it.
pub fn read(text: &str) -> Result<Answer, Failure> {
    let v = json::parse(text).map_err(|_| Failure::NotJson)?;
    // **First, and before the shape**: the page door's `{"error": …}` is
    // well-formed and is the core saying no (the macOS host's `read(_:)`).
    if let Some(Value::Str(word)) = v.get("error") {
        return Err(Failure::Refused(word.clone()));
    }
    read_value(&v)
}

pub fn read_value(v: &Value) -> Result<Answer, Failure> {
    match v.get("page") {
        Some(Value::Str(p)) if p == PAGE => {}
        _ => return Err(Failure::Unknown("not a workdirs page".into())),
    }
    let group = match v.get("group") {
        Some(Value::Str(g)) => g.clone(),
        _ => return Err(Failure::Unknown("a workdirs page with no group".into())),
    };
    let mut r = Reader::default();
    let dirs = r
        .list(v, "", "dirs")
        .iter()
        .enumerate()
        .filter_map(|(i, d)| dir(&mut r, d, &at("dirs", i)))
        .collect();
    Ok(Answer { group, dirs, missing: r.missing })
}

/// One directory, or none when what it is opened by is missing: a row with
/// no `id` cannot be minted a ticket for and one with no `path` cannot be
/// listed, and either absence is already in `Reader::missing`.
fn dir(r: &mut Reader, v: &Value, path: &str) -> Option<Dir> {
    let id = r.text(v, path, "id");
    let real = r.text(v, path, "path");
    let short = r.text(v, path, "short");
    if id.is_empty() || real.is_empty() {
        return None;
    }
    Some(Dir {
        id,
        path: real,
        short,
        readable: r.boolean(v, path, "readable").unwrap_or(false),
        why: r.nullable_text(v, path, "why"),
    })
}

/// One level, or the core's refusal -- **three outcomes, not two** (the
/// macOS host's `readListing`).
pub fn read_listing(text: &str) -> Result<Level, Failure> {
    let v = json::parse(text).map_err(|_| Failure::NotJson)?;
    if let Some(Value::Str(word)) = v.get("error") {
        return Err(Failure::Refused(word.clone()));
    }
    if let Some(Value::Str(code)) = v.get("refused") {
        let reason = match v.get("reason") {
            Some(Value::Str(s)) => Some(s.clone()),
            _ => None,
        };
        let why = match v.get("why") {
            Some(Value::Str(s)) => Some(s.clone()),
            _ => None,
        };
        return Err(Failure::RefusedFile { code: code.clone(), reason, why });
    }
    // Neither an answer nor a refusal: the shape is not this door's.
    if v.get("entries").is_none() {
        return Err(Failure::Unknown("a listing with no entries".into()));
    }
    let mut r = Reader::default();
    let entries = r
        .list(&v, "", "entries")
        .iter()
        .enumerate()
        .filter_map(|(i, e)| {
            let p = at("entries", i);
            let name = r.text(e, &p, "name");
            if name.is_empty() {
                return None;
            }
            Some(Entry { name, is_dir: r.boolean(e, &p, "is_dir").unwrap_or(false) })
        })
        .collect();
    Ok(Level { entries, more: r.int(&v, "", "more").unwrap_or(0), missing: r.missing })
}

// --------------------------------------------------------------------- paths

/// The separator `dir` ends with (or holds), as the names under it are
/// joined on. **The root's own**, never a constant: a Windows working
/// directory arrives `C:\work`, and a path built with `/` would be a second
/// spelling of the directory the core listed.
pub fn separator_of(dir: &str) -> char {
    match dir.rfind(['/', '\\']) {
        Some(i) => dir.as_bytes()[i] as char,
        None => '/',
    }
}

/// `dir` and the core's `name`, joined on `dir`'s own separator. A trailing
/// separator on `dir` is not doubled.
pub fn join_path(dir: &str, name: &str) -> String {
    let sep = separator_of(dir);
    let mut out = String::with_capacity(dir.len() + 1 + name.len());
    out.push_str(dir.trim_end_matches(['/', '\\']));
    out.push(sep);
    out.push_str(name);
    out
}

/// Where `name` is under `rel`: `rel` itself when it is empty.
///
/// ⚠️ **`/` and not the separator the root uses.** `files_list`'s `rel` is
/// joined by the core onto the ticket's anchor (`Tickets.list`), and the
/// macOS host sends it the same way; a name with a separator in it is not a
/// name the core could have sent (`Listing` reads one directory), so this
/// is the one place a `/` is written and it is a key, not a path the host
/// looks anything up by.
pub fn child_rel(rel: &str, name: &str) -> String {
    if rel.is_empty() {
        name.to_string()
    } else {
        format!("{rel}/{name}")
    }
}

/// The pieces of `path`, split on either separator, empty pieces dropped.
fn parts(path: &str) -> impl Iterator<Item = &str> {
    path.split(['/', '\\']).filter(|p| !p.is_empty())
}

/// Whether `outer` is `inner`'s directory or one of its parents, **by whole
/// pieces and never by substring**: `/a/bc` does not contain `/a/b`.
pub fn contains(outer: &str, inner: &str) -> bool {
    let mut o = parts(outer);
    let mut i = parts(inner);
    loop {
        match o.next() {
            None => return true,
            Some(want) => match i.next() {
                // A drive letter or a root is one piece on Windows; the
                // case of one is the filesystem's, which the core already
                // resolved the path with (`Workdirs` realpaths), so the
                // pieces are compared as written.
                Some(have) if have == want => {}
                _ => return false,
            },
        }
    }
}

/// The directory a file at `path` is opened from: **the longest readable
/// row that contains it**, or none.
///
/// Longest and not first: a worktree standing inside the person's own
/// directory is two rows, and a file in the worktree belongs to the nearer
/// one. A row that may not be read is passed over -- the core refuses a
/// ticket for one (`too_wide`), and a caller that asked anyway would be
/// asking for a refusal it could have predicted.
pub fn dir_holding<'a>(answer: &'a Answer, path: &str) -> Option<&'a Dir> {
    let mut best: Option<&Dir> = None;
    for d in &answer.dirs {
        if !d.readable || !contains(&d.path, path) {
            continue;
        }
        let longer = match best {
            None => true,
            Some(b) => parts(&d.path).count() > parts(&b.path).count(),
        };
        if longer {
            best = Some(d);
        }
    }
    best
}

// ---------------------------------------------------------------------- tree

/// Which roots the person has shut, and the row the workbench is showing.
///
/// **Shut, not open.** A set of open ids cannot tell "nobody has touched
/// this root" from "somebody opened it", and a root the page has never seen
/// would draw shut -- the right picture for the wrong reason. Absence from
/// this set means **no decision**, and a root nobody has decided about is
/// drawn open, which is what the design's first picture shows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Tree {
    shut: Vec<String>,
    /// The row the workbench is showing: a root's id or a node's path.
    /// **One at a time**, in one slot, so there is no second thing to
    /// clear.
    selected: Option<String>,
}

impl Tree {
    pub fn is_open(&self, id: &str) -> bool {
        !self.shut.iter().any(|s| s == id)
    }

    /// A plain click on a root: it opens if it was shut, and shuts if it was
    /// open. The other roots are left alone.
    pub fn toggle(&mut self, id: &str) {
        match self.shut.iter().position(|s| s == id) {
            Some(i) => {
                self.shut.remove(i);
            }
            None => self.shut.push(id.to_string()),
        }
    }

    /// ⌥-click: this root opens and every other one shuts. On a root that is
    /// already the only one open nothing changes.
    pub fn solo(&mut self, id: &str, ids: &[String]) {
        self.shut = ids.iter().filter(|x| x.as_str() != id).cloned().collect();
    }

    /// 「全部收起」: every root shuts.
    pub fn collapse_all(&mut self, ids: &[String]) {
        self.shut = ids.to_vec();
    }

    pub fn is_selected(&self, key: &str) -> bool {
        self.selected.as_deref() == Some(key)
    }

    pub fn selected(&self) -> Option<&str> {
        self.selected.as_deref()
    }

    /// The row was clicked: it is the selected one and the one before it is
    /// not (one slot). `None` is a selection moved off every row.
    pub fn select(&mut self, key: Option<&str>) {
        self.selected = key.map(str::to_string);
    }

    /// Roots that have gone stop being remembered, so a directory that
    /// comes back comes back **open** rather than wearing a decision made
    /// about a directory the group had before (`Workdirs.compute` is worked
    /// out afresh on every ask).
    pub fn keep(&mut self, ids: &[String]) {
        self.shut.retain(|s| ids.iter().any(|id| id == s));
    }
}

/// Every level this page has read, which directories are open under the
/// roots, and the ticket each root is listed with.
///
/// **A level is asked for once and kept.** The page redraws on every notice
/// from the core, and a `files_list` per redraw would be a directory read
/// per redraw, on the app thread. Nothing here expires on a clock: what
/// changes on disk is said by asking again, which is a person's act.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Levels {
    /// By real path. A directory's rows are only drawn when it is open and
    /// has been read (the tree is lazy: 文件树按目录懒加载).
    levels: Vec<(String, Level)>,
    /// A directory that could not be read: **kept beside the level, not
    /// stored as an empty one** -- "it is empty" and "it could not be read"
    /// are two states the page draws differently.
    failures: Vec<(String, Failure)>,
    /// The directories under the roots somebody has opened.
    open: Vec<String>,
    /// The ticket each root's tree is listed with, by workdir id. One per
    /// root and minted once: a fresh ticket per directory would spend the
    /// core's ledger on directories the person has already looked at.
    tickets: Vec<(String, String)>,
}

impl Levels {
    pub fn level(&self, path: &str) -> Option<&Level> {
        self.levels.iter().find(|(p, _)| p == path).map(|(_, l)| l)
    }

    pub fn failure(&self, path: &str) -> Option<&Failure> {
        self.failures.iter().find(|(p, _)| p == path).map(|(_, f)| f)
    }

    /// Whether this directory has ever been asked for. **Different from
    /// "its level is empty"**, which is an answer: a directory nobody has
    /// asked about must ask, and one that came back empty must not ask
    /// again on every redraw.
    pub fn has_asked(&self, path: &str) -> bool {
        self.level(path).is_some() || self.failure(path).is_some()
    }

    pub fn keep(&mut self, path: &str, level: Level) {
        self.failures.retain(|(p, _)| p != path);
        match self.levels.iter_mut().find(|(p, _)| p == path) {
            Some(slot) => slot.1 = level,
            None => self.levels.push((path.to_string(), level)),
        }
    }

    pub fn keep_failure(&mut self, path: &str, failure: Failure) {
        self.levels.retain(|(p, _)| p != path);
        match self.failures.iter_mut().find(|(p, _)| p == path) {
            Some(slot) => slot.1 = failure,
            None => self.failures.push((path.to_string(), failure)),
        }
    }

    /// Everything that was read is gone -- the group changed. The opened
    /// directories go too, and **the tickets with them**: a ticket is minted
    /// for one workdir of one group, so one kept across a change of group is
    /// a token this page would go on listing with against a directory that
    /// group may not have.
    pub fn forget(&mut self) {
        self.levels.clear();
        self.failures.clear();
        self.open.clear();
        self.tickets.clear();
    }

    /// Every level and refusal goes; the open set and the tickets stay.
    /// What a person's press on 刷新 means: what changes on disk is what a
    /// directory *holds*, and the directories that are open are the same
    /// ones they were.
    pub fn refresh(&mut self) {
        self.levels.clear();
        self.failures.clear();
    }

    pub fn ticket(&self, workdir_id: &str) -> Option<&str> {
        self.tickets.iter().find(|(id, _)| id == workdir_id).map(|(_, t)| t.as_str())
    }

    /// Remember the ticket a root's tree is listed with. **The first one
    /// wins**: a second token for a root already held would be a second
    /// ticket for one tree.
    pub fn keep_ticket(&mut self, workdir_id: &str, token: &str) {
        if self.ticket(workdir_id).is_none() {
            self.tickets.push((workdir_id.to_string(), token.to_string()));
        }
    }

    pub fn is_open(&self, path: &str) -> bool {
        self.open.iter().any(|p| p == path)
    }

    pub fn toggle(&mut self, path: &str) {
        match self.open.iter().position(|p| p == path) {
            Some(i) => {
                self.open.remove(i);
            }
            None => self.open.push(path.to_string()),
        }
    }

    /// The directories that are open, as paths. **In no particular order**:
    /// nothing is drawn in this order and each ask is independent; a sort
    /// here would be a sort in a host file, which the gate refuses by name.
    pub fn open_directories(&self) -> &[String] {
        &self.open
    }
}

/// One row of the file tree under a root.
///
/// `path` is the real path -- the root's own path with the names the core
/// sent joined on -- and `rel` is where that is under the root, which is
/// what `files_list` takes. **Both are built from the core's names and from
/// nothing else**: a path the host made up would name a directory the core
/// never listed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    pub name: String,
    pub path: String,
    pub rel: String,
    pub is_dir: bool,
    /// 1 for a row directly under the root, 2 under that, and so on.
    pub depth: usize,
}

/// The rows under one root, **in the core's order and with no sort**.
///
/// A directory's own rows are drawn only when it is open and has been read.
/// Nothing is filtered, reordered or counted: the core sends the level
/// directories-first and by name, with the build output already gone.
pub fn nodes(under: &Dir, levels: &Levels) -> Vec<Node> {
    let mut out = Vec::new();
    walk(&root_node(under), levels, &mut out);
    out
}

fn root_node(root: &Dir) -> Node {
    Node { name: root.short.clone(), path: root.path.clone(), rel: String::new(), is_dir: true, depth: 0 }
}

fn walk(node: &Node, levels: &Levels, out: &mut Vec<Node>) {
    let Some(level) = levels.level(&node.path) else { return };
    for entry in &level.entries {
        let child = Node {
            name: entry.name.clone(),
            path: join_path(&node.path, &entry.name),
            rel: child_rel(&node.rel, &entry.name),
            is_dir: entry.is_dir,
            depth: node.depth + 1,
        };
        // The directory's own row first, then what is under it -- the
        // macOS host's `nodes(under:in:)`, and the order the level came in
        // is kept: this is a walk, not a sort.
        let deeper = child.is_dir && levels.is_open(&child.path);
        let recurse = child.clone();
        out.push(child);
        if deeper {
            walk(&recurse, levels, out);
        }
    }
}

/// The page's state for one group: what the core said, and what the person
/// has done with it.
///
/// **The answer and the person's decisions are two fields**, so that an
/// answer arriving again (the group's terminals moved) cannot reset a tree
/// the person opened. A change of group is [`Page::for_group`]'s.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Page {
    pub group: String,
    /// None until the core has answered for this group.
    pub answer: Option<Answer>,
    pub tree: Tree,
    pub levels: Levels,
}

impl Page {
    pub fn new(group: &str) -> Page {
        Page { group: group.to_string(), answer: None, tree: Tree::default(), levels: Levels::default() }
    }

    /// This page for `group`, or a fresh one when it is another group's:
    /// **everything read and everything decided goes**, because a root id,
    /// a path and a ticket are all facts about one group.
    pub fn for_group(&mut self, group: &str) -> bool {
        if self.group == group {
            return false;
        }
        *self = Page::new(group);
        true
    }

    /// A fresh answer for this group, with the person's tree kept. Roots
    /// that have gone are forgotten (`Tree::keep`), and so are the tickets
    /// of roots the group no longer has.
    pub fn set_answer(&mut self, answer: Answer) {
        let ids: Vec<String> = answer.dirs.iter().map(|d| d.id.clone()).collect();
        self.tree.keep(&ids);
        self.levels.tickets.retain(|(id, _)| ids.iter().any(|x| x == id));
        self.answer = Some(answer);
    }

    pub fn dirs(&self) -> &[Dir] {
        match &self.answer {
            Some(a) => &a.dirs,
            None => &[],
        }
    }

    pub fn dir(&self, id: &str) -> Option<&Dir> {
        self.dirs().iter().find(|d| d.id == id)
    }

    /// The rows under one root, or none when the root is shut.
    pub fn rows(&self, root: &Dir) -> Vec<Node> {
        if !self.tree.is_open(&root.id) {
            return Vec::new();
        }
        nodes(root, &self.levels)
    }

    /// The root and node rows this page would draw, as `(key, depth, is_dir)`
    /// -- **the order the page draws them**, a root's own tree under it.
    /// Used by the scene and by the tests; no sort and no filter.
    pub fn visible(&self) -> Vec<Visible> {
        let mut out = Vec::new();
        for d in self.dirs() {
            out.push(Visible { key: d.id.clone(), depth: 0, is_dir: true, open: self.tree.is_open(&d.id) });
            if !self.tree.is_open(&d.id) {
                continue;
            }
            for n in nodes(d, &self.levels) {
                out.push(Visible { key: n.path.clone(), depth: n.depth, is_dir: n.is_dir, open: n.is_dir && self.levels.is_open(&n.path) });
            }
        }
        out
    }
}

/// One row as the page draws it, worked out from the answer and the tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Visible {
    /// A root's id or a node's real path. **The one key every press and the
    /// selection use**, so two spellings of one directory cannot both be
    /// selected.
    pub key: String,
    /// 0 for a root; 1 and deeper under it.
    pub depth: usize,
    pub is_dir: bool,
    /// Whether a directory's own rows follow it.
    pub open: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listing(entries: &[(&str, bool)], more: u64) -> String {
        let mut out = String::from("{\"entries\":[");
        for (i, (name, is_dir)) in entries.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!("{{\"name\":{},\"is_dir\":{}}}", json::quote(name), is_dir));
        }
        out.push_str(&format!("],\"more\":{more}}}"));
        out
    }

    fn page(dirs: &[&str]) -> String {
        let mut out = String::from("{\"page\":\"workdirs\",\"group\":\"g\",\"dirs\":[");
        for (i, path) in dirs.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            // **The id is a hash of the path** (`Workdirs.writeJson`): two
            // roots never share one, and a root that goes and comes back
            // wears the same id it had.
            let id = format!("id{}", path.len());
            out.push_str(&format!(
                "{{\"id\":{},\"path\":{},\"short\":{},\"kind\":\"terminal\",\"tree_name\":null,\"who\":[],\"also_in\":[],\"readable\":true,\"why\":null,\"editing\":0}}",
                json::quote(&id),
                json::quote(path),
                json::quote(path)
            ));
        }
        out.push_str("]}");
        out
    }

    /// The page, read, with a level kept at `path`.
    fn with_level(dir_path: &str, path: &str, text: &str) -> (Page, Dir) {
        let mut p = Page::new("g");
        p.set_answer(read(&page(&[dir_path])).unwrap());
        let d = p.dirs()[0].clone();
        p.levels.keep(path, read_listing(text).unwrap());
        (p, d)
    }

    #[test]
    fn the_page_is_read_with_the_fields_the_row_needs() {
        let a = read(&page(&["/w"])).unwrap();
        assert_eq!(a.group, "g");
        assert_eq!(a.dirs.len(), 1);
        // The id is the fixture's stand-in for the core's hash of the path.
        assert_eq!(a.dirs[0].id, "id2");
        assert_eq!(a.dirs[0].path, "/w");
        assert_eq!(a.dirs[0].short, "/w");
        assert!(a.dirs[0].readable);
        assert_eq!(a.dirs[0].why, None);
        assert!(a.missing.is_empty());
    }

    #[test]
    fn a_page_that_says_no_is_the_cores_word_and_not_a_parse_failure() {
        assert_eq!(
            read(r#"{"error":"NoSuchGroup"}"#),
            Err(Failure::Refused("NoSuchGroup".into()))
        );
        assert_eq!(read("not json"), Err(Failure::NotJson));
        assert_eq!(read(r#"{"page":"tasks"} "#), Err(Failure::Unknown("not a workdirs page".into())));
    }

    #[test]
    fn a_listing_is_names_and_whether_they_open() {
        let l = read_listing(&listing(&[("a", false), ("b", true)], 3)).unwrap();
        assert_eq!(l.entries, vec![
            Entry { name: "a".into(), is_dir: false },
            Entry { name: "b".into(), is_dir: true },
        ]);
        assert_eq!(l.more, 3);
        assert!(l.missing.is_empty());
    }

    /// **The third branch**: a refusal is not "nothing here".
    #[test]
    fn a_listing_that_was_refused_says_which_refusal_it_was() {
        let text = r#"{"refused":"access","reason":"outside","why":"it is not in this working directory, or there is nothing at that path"}"#;
        assert_eq!(
            read_listing(text),
            Err(Failure::RefusedFile {
                code: "access".into(),
                reason: Some("outside".into()),
                why: Some("it is not in this working directory, or there is nothing at that path".into()),
            })
        );
        assert_eq!(
            read_listing(r#"{"refused":"no_ticket","why":"there is no such ticket"}"#),
            Err(Failure::RefusedFile { code: "no_ticket".into(), reason: None, why: Some("there is no such ticket".into()) })
        );
        assert_eq!(
            read_listing(r#"{"refused":"bad_request","why":"it is not one of the files requests"}"#),
            Err(Failure::RefusedFile { code: "bad_request".into(), reason: None, why: Some("it is not one of the files requests".into()) })
        );
        // A request that never reached the core is its own case, and says so.
        let u = Failure::Unavailable("the core is not running".into());
        assert_eq!(u.why(), Some("the core is not running"));
        // The page door's own refusal on this door, too.
        assert_eq!(read_listing(r#"{"error":"NoSuchGroup"}"#), Err(Failure::Refused("NoSuchGroup".into())));
        assert_eq!(read_listing(r#"{"more":0}"#), Err(Failure::Unknown("a listing with no entries".into())));
    }

    #[test]
    fn the_three_requests_are_the_text_the_socket_carries() {
        assert_eq!(request("g"), r#"{"page":"workdirs","group":"g"}"#);
        assert_eq!(
            listing_request("0a1b", "sub/dir"),
            r#"{"method":"files_list","params":{"token":"0a1b","rel":"sub/dir"}}"#
        );
        assert_eq!(
            open_request("id0", "/w/a.txt", FILE_SCOPE),
            r#"{"method":"files_open","params":{"workdir_id":"id0","path":"/w/a.txt","scope":"file"}}"#
        );
        // A name with a quote or a backslash is a request that is still JSON.
        assert_eq!(
            listing_request("t", "a\"b\\c"),
            r#"{"method":"files_list","params":{"token":"t","rel":"a\"b\\c"}}"#
        );
    }

    /// The root's own separator, not a constant: a Windows directory is one
    /// spelling and a path built with `/` would be another.
    #[test]
    fn a_path_is_joined_on_its_roots_own_separator() {
        assert_eq!(join_path("/w", "a"), "/w/a");
        assert_eq!(join_path("/w/", "a"), "/w/a");
        assert_eq!(join_path("C:\\work", "a"), "C:\\work\\a");
        assert_eq!(join_path("C:\\work\\", "a"), "C:\\work\\a");
        assert_eq!(child_rel("", "a"), "a");
        assert_eq!(child_rel("sub", "a"), "sub/a");
    }

    #[test]
    fn contains_is_by_whole_pieces_and_never_by_substring() {
        assert!(contains("/a/b", "/a/b"));
        assert!(contains("/a/b", "/a/b/c/d"));
        assert!(!contains("/a/b", "/a/bc"));
        assert!(!contains("/a/b", "/a"));
        assert!(contains("C:\\w", "C:\\w\\a\\b"));
        assert!(!contains("C:\\w", "C:\\wx\\a"));
    }

    #[test]
    fn a_file_belongs_to_the_nearest_readable_row_that_holds_it() {
        let text = r#"{"page":"workdirs","group":"g","dirs":[
            {"id":"wide","path":"/","short":"/","kind":"terminal","tree_name":null,"who":[],"also_in":[],"readable":false,"why":"too_wide","editing":0},
            {"id":"own","path":"/home/me","short":"~","kind":"terminal","tree_name":null,"who":[],"also_in":[],"readable":true,"why":null,"editing":0},
            {"id":"tree","path":"/home/me/wt","short":"~/wt","kind":"tree","tree_name":"wt","who":[],"also_in":[],"readable":true,"why":null,"editing":0}]}"#;
        let a = read(text).unwrap();
        assert_eq!(dir_holding(&a, "/home/me/wt/a.txt").unwrap().id, "tree");
        assert_eq!(dir_holding(&a, "/home/me/b.txt").unwrap().id, "own");
        // The unreadable row holds everything and is passed over.
        assert_eq!(dir_holding(&a, "/etc/x").map(|d| d.id.clone()), None);
    }

    /// **The rows are the core's order, lazily**: a directory's own rows
    /// only once it is open and read, and neither the order nor the set is
    /// worked out again here.
    #[test]
    fn the_tree_is_the_cores_order_one_open_directory_at_a_time() {
        let (mut p, d) = with_level("/w", "/w", &listing(&[("sub", true), ("z.txt", false)], 0));
        // **A root nobody has shut is open** (`Tree` keeps the shut ones),
        // and its level has been read: its rows are drawn in the core's
        // order.
        let rows = p.rows(&d);
        assert_eq!(rows.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), vec!["sub", "z.txt"]);
        assert_eq!(rows[0].path, "/w/sub");
        assert_eq!(rows[0].rel, "sub");
        assert_eq!(rows[1].depth, 1);

        // Shut: the root row stays and nothing is under it.
        p.tree.toggle(&d.id);
        assert!(p.rows(&d).is_empty());
        assert_eq!(p.visible().len(), 1);
        p.tree.toggle(&d.id);

        // `sub` is open but never read: it draws, and nothing is under it.
        p.levels.toggle("/w/sub");
        assert_eq!(p.rows(&d).len(), 2);

        p.levels.keep("/w/sub", read_listing(&listing(&[("inner", false)], 0)).unwrap());
        let rows = p.rows(&d);
        assert_eq!(rows.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), vec!["sub", "inner", "z.txt"]);
        assert_eq!(rows[1].path, "/w/sub/inner");
        assert_eq!(rows[1].rel, "sub/inner");
        assert_eq!(rows[1].depth, 2);
    }

    #[test]
    fn a_deeper_level_is_joined_onto_the_path_its_parent_was_read_at() {
        let mut p = Page::new("g");
        p.set_answer(read(&page(&["C:\\w"])).unwrap());
        let d = p.dirs()[0].clone();
        p.levels.keep("C:\\w", read_listing(&listing(&[("a", true)], 0)).unwrap());
        p.levels.toggle("C:\\w\\a");
        p.levels.keep("C:\\w\\a", read_listing(&listing(&[("b", false)], 0)).unwrap());
        let rows = p.rows(&d);
        assert_eq!(rows[1].name, "b");
        assert_eq!(rows[1].path, "C:\\w\\a\\b");
        assert_eq!(rows[1].rel, "a/b");
    }

    #[test]
    fn opening_and_shutting_a_root_is_one_slot_and_a_plain_click() {
        let mut t = Tree::default();
        assert!(t.is_open("r"));
        t.toggle("r");
        assert!(!t.is_open("r"));
        t.toggle("r");
        assert!(t.is_open("r"));
        // ⌥-click: only this one.
        t.solo("r", &["r".into(), "s".into()]);
        assert!(t.is_open("r") && !t.is_open("s"));
        // A root that goes is forgotten, so one that comes back comes back
        // open.
        t.keep(&["r".into()]);
        assert!(t.is_open("s"));
    }

    #[test]
    fn a_refusal_is_kept_beside_the_level_and_not_as_an_empty_one() {
        let mut l = Levels::default();
        l.keep("/w/a", read_listing(&listing(&[], 0)).unwrap());
        assert!(l.has_asked("/w/a"));
        assert!(l.level("/w/a").unwrap().entries.is_empty());
        assert!(l.failure("/w/a").is_none());

        let f = read_listing(r#"{"refused":"access","reason":"unreadable","why":"it could not be looked at"}"#).unwrap_err();
        l.keep_failure("/w/b", f.clone());
        assert!(l.has_asked("/w/b"));
        assert!(l.level("/w/b").is_none());
        assert_eq!(l.failure("/w/b"), Some(&f));
        // Asking again and getting it clears the refusal, and the other way
        // round.
        l.keep("/w/b", read_listing(&listing(&[("x", false)], 0)).unwrap());
        assert!(l.failure("/w/b").is_none());
        assert_eq!(l.level("/w/b").unwrap().entries.len(), 1);
        l.keep_failure("/w/a", f);
        assert!(l.level("/w/a").is_none());
    }

    #[test]
    fn a_change_of_group_forgets_the_tickets_and_the_open_directories() {
        let mut p = Page::new("g1");
        p.set_answer(read(&page(&["/w"])).unwrap());
        p.levels.keep_ticket("id0", "tok");
        p.levels.keep("/w", read_listing(&listing(&[("a", true)], 0)).unwrap());
        p.levels.toggle("/w/a");
        p.tree.select(Some("/w/a"));

        assert!(!p.for_group("g1"));
        assert!(p.for_group("g2"));
        assert!(p.dirs().is_empty());
        assert!(p.levels.ticket("id0").is_none());
        assert!(!p.levels.is_open("/w/a"));
        assert_eq!(p.tree.selected(), None);
    }

    #[test]
    fn an_answer_again_keeps_the_tree_the_person_opened() {
        let mut p = Page::new("g");
        p.set_answer(read(&page(&["/w"])).unwrap());
        let id = p.dirs()[0].id.clone();
        p.tree.toggle(&id);
        p.levels.keep_ticket(&id, "tok");
        // The same group, with the same root: the person's decision and the
        // ticket stay.
        p.set_answer(read(&page(&["/w"])).unwrap());
        assert!(!p.tree.is_open(&id));
        assert_eq!(p.levels.ticket(&id), Some("tok"));
        // The root is gone: the decision about it goes, and so does its
        // ticket. If it ever comes back it comes back open.
        p.set_answer(read(&page(&["/other"])).unwrap());
        assert!(p.tree.is_open(&id));
        assert_eq!(p.levels.ticket(&id), None);
    }

    #[test]
    fn the_visible_rows_carry_the_key_every_press_uses() {
        let (p, _d) = with_level("/w", "/w", &listing(&[("a.txt", false)], 0));
        let v = p.visible();
        assert_eq!(v[0].key, p.dirs()[0].id);
        assert_eq!(v[0].depth, 0);
        assert!(v[0].open);
        assert_eq!(v[1].key, "/w/a.txt");
        assert_eq!(v[1].depth, 1);
        assert!(!v[1].open);
    }
}
