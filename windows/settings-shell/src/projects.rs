//! The projects section (settings.md §6), with nothing drawn: the rules a
//! project's list, detail and operations follow, and the file operations
//! underneath them that do not need to know the project format.
//!
//! **Why here and not in `polter-host`.** The same reason as the rest of this
//! crate (see `lib.rs`): the host's tests only run on the Windows machine.
//! Renaming, copying, keeping one previous generation, putting a deleted
//! project back -- every one of those moves files a person cares about, and a
//! rule for moving files that can only be broken on the Mac with everything
//! green is the rule most worth testing where it is written. So the file
//! operations are here too, over `std::fs` alone, and the tests run them in a
//! temporary directory.
//!
//! What stays in the host is the format (`project.rs`, which mirrors
//! `Project.zig` and has a serde dependency) and Win32. The host turns a
//! saved tree into a [`Shape`], and a file it has read into an [`Existing`],
//! and asks the functions below.
//!
//! **The previous generation** (`<name>.json.prev`) follows
//! `macos/Sources/Features/Projects/ProjectAutosave.swift`
//! (`ProjectFileWriter`) rule for rule, so a project folder moved between the
//! two machines means the same thing on both: kept only when the *layout*
//! changed, a write that changes nothing but the time is not a write, and
//! restoring swaps -- so it is undone by restoring again.

use std::io;
use std::path::{Path, PathBuf};

use crate::grid::*;
use crate::{scale, Rect, SectionGrid};

// ================================================================== shapes

/// A saved tab's split tree with nothing in it but the shape: which way each
/// split goes, its ratio, and where the panes are. What the thumbnail draws
/// and what decides whether a save keeps the previous generation.
#[derive(Clone, Debug, PartialEq)]
pub enum Shape {
    Pane,
    /// `side_by_side` is the split-tree's `Horizontal` (a vertical divider,
    /// `first` on the left); otherwise `first` is on top.
    Split { side_by_side: bool, ratio: f64, first: Box<Shape>, second: Box<Shape> },
}

impl Shape {
    pub fn panes(&self) -> usize {
        match self {
            Shape::Pane => 1,
            Shape::Split { first, second, .. } => first.panes() + second.panes(),
        }
    }

    /// Whether two trees have the same *layout*: the same shape and the same
    /// split directions. **Not the ratios** -- a divider dragged a few pixels
    /// is not a change worth a generation (`ProjectNode.layout` on macOS).
    pub fn same_layout(&self, other: &Shape) -> bool {
        match (self, other) {
            (Shape::Pane, Shape::Pane) => true,
            (
                Shape::Split { side_by_side: a, first: af, second: asd, .. },
                Shape::Split { side_by_side: b, first: bf, second: bsd, .. },
            ) => a == b && af.same_layout(bf) && asd.same_layout(bsd),
            _ => false,
        }
    }
}

/// `same_layout` for trees that may be empty (a project with no root).
pub fn same_layout(a: Option<&Shape>, b: Option<&Shape>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => a.same_layout(b),
        _ => false,
    }
}

/// The thumbnail (§6.1): one rectangle per pane inside `r`, **in the order
/// the tree's leaves are walked** (first before second), with `gap` pixels
/// between the two halves of every split. A ratio outside 0..1 is held to it;
/// no pane is ever narrower or shorter than one pixel, so a deep tree in a
/// small box still shows every pane.
pub fn thumbnail(shape: &Shape, r: Rect, gap: i32) -> Vec<Rect> {
    let mut out = Vec::new();
    fn walk(s: &Shape, r: Rect, gap: i32, out: &mut Vec<Rect>) {
        match s {
            Shape::Pane => out.push(r),
            Shape::Split { side_by_side, ratio, first, second } => {
                let ratio = if ratio.is_finite() { ratio.clamp(0.0, 1.0) } else { 0.5 };
                let (a, b) = if *side_by_side {
                    let room = (r.width() - gap).max(2);
                    let w = ((room as f64 * ratio).round() as i32).clamp(1, room - 1);
                    (Rect::new(r.left, r.top, r.left + w, r.bottom), Rect::new(r.left + w + gap, r.top, r.right.max(r.left + w + gap + 1), r.bottom))
                } else {
                    let room = (r.height() - gap).max(2);
                    let h = ((room as f64 * ratio).round() as i32).clamp(1, room - 1);
                    (Rect::new(r.left, r.top, r.right, r.top + h), Rect::new(r.left, r.top + h + gap, r.right, r.bottom.max(r.top + h + gap + 1)))
                };
                walk(first, a, gap, out);
                walk(second, b, gap, out);
            }
        }
    }
    walk(shape, r, gap, &mut out);
    out
}

// ====================================================== one previous generation

/// What is at the path a save is about to write, as far as the rule needs:
/// nothing, something that does not read as a project, or a project compared
/// with the one being written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Existing {
    Nothing,
    /// There is a file and it is not a project this build can read. **Kept as
    /// the previous generation, never simply overwritten**: it is somebody's
    /// project in a form this cannot tell the layout of.
    Unreadable,
    Read {
        /// The layout differs (`Shape::same_layout`).
        layout_changed: bool,
        /// Everything but `saved_at` is the same: name, tree, counter.
        only_the_time_changed: bool,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WritePlan {
    /// Nothing but the time would change, so nothing is written -- every
    /// write changes `saved_at`, so every write would otherwise look like a
    /// change.
    Unchanged,
    /// Write it. `keep_previous`: first copy what is there to `.prev`.
    Write { keep_previous: bool },
}

/// `ProjectFileWriter.write`'s decision, the same on both hosts.
///
/// **Kept only on a layout change**, not on the changes that follow a person
/// around all day (a title, a directory, a divider): keeping on those would
/// replace the good layout with the bad one the next time a shell set its
/// title, which is the mistake `.prev` exists to undo.
pub fn plan_write(existing: Existing) -> WritePlan {
    match existing {
        Existing::Nothing => WritePlan::Write { keep_previous: false },
        Existing::Unreadable => WritePlan::Write { keep_previous: true },
        Existing::Read { only_the_time_changed: true, .. } => WritePlan::Unchanged,
        Existing::Read { layout_changed, .. } => WritePlan::Write { keep_previous: layout_changed },
    }
}

/// **Why a project file is being written**, because the three are not one
/// rule (§6.2, 39ae3f040). They were one boolean -- "decide about `.prev`" or
/// not -- and "Overwrite with Current Tab" went through the save's rule,
/// which keeps a generation only when the *layout* changed: one pane
/// overwritten by one pane lost the old directory and title, under a
/// confirmation that said it would be kept (found on the mac, #962 P9).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteKind {
    /// "Save as Project" -- and on macOS the autosave: `plan_write`, so the
    /// changes that follow a person around all day do not push the good
    /// layout out of `.prev`.
    Save,
    /// "Overwrite with Current Tab": the person replaced the project on
    /// purpose, was told the replaced version is kept, and it is -- **always**,
    /// whatever changed or did not.
    Overwrite,
    /// The same project under a new name (a rename, a copy): not a new
    /// version, so `.prev` is left as it is.
    Rename,
}

/// "Save as Project" under a name that already has a project **is an
/// overwrite** (§6.2, #969/#970): the person is asked first, and what it
/// replaces is kept as the previous version, exactly as "Overwrite with
/// Current Tab" keeps it. Under a new name it is a save. `target_exists` is
/// whether the file the name gives is there -- a file this build cannot read
/// included: it is somebody's project all the same.
pub fn save_as(target_exists: bool) -> WriteKind {
    if target_exists {
        WriteKind::Overwrite
    } else {
        WriteKind::Save
    }
}

/// The plan for writing a project of `kind` over `existing`.
pub fn plan_for(kind: WriteKind, existing: Existing) -> WritePlan {
    match (kind, existing) {
        (WriteKind::Save, e) => plan_write(e),
        (WriteKind::Overwrite, Existing::Nothing) => WritePlan::Write { keep_previous: false },
        (WriteKind::Overwrite, _) => WritePlan::Write { keep_previous: true },
        (WriteKind::Rename, _) => WritePlan::Write { keep_previous: false },
    }
}

/// `<name>.json.prev` beside `<name>.json`. Its extension is `prev`, so a
/// listing that takes only `.json` never lists it -- on macOS
/// (`ProjectFileWriter.previousURL`) and here.
pub fn prev_path(file: &Path) -> PathBuf {
    let mut s = file.as_os_str().to_os_string();
    s.push(".prev");
    PathBuf::from(s)
}

/// Where a project file's scrollback snapshots are: the file's path with its
/// extension replaced by `.scrollback`. **The one statement of this rule on
/// Windows** -- `project::scrollback_dir` asks this.
pub fn scrollback_dir(file: &Path) -> PathBuf {
    file.with_extension("scrollback")
}

/// Everything that belongs to a project besides its file, and goes wherever
/// the file goes: the previous generation and the snapshot directory. Either
/// may be absent.
pub fn sidecars(file: &Path) -> [PathBuf; 2] {
    [prev_path(file), scrollback_dir(file)]
}

/// A name in `dir` for a temporary file that nothing lists: it starts with a
/// dot and ends in `.tmp`, and carries the process and a counter so two
/// writers never share one.
fn temporary_beside(file: &Path) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let n = N.fetch_add(1, Ordering::Relaxed);
    let base = file.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    file.with_file_name(format!(".{base}.{}.{n}.tmp", std::process::id()))
}

/// Write `body` to `file` as `plan` says, keeping the previous generation
/// when it says so. Written to a temporary file beside it and renamed over
/// it, so a half-written file is never what is there.
///
/// The previous generation is taken **by copy**, not by rename: the file
/// stays where it is until the new one replaces it, so a failure in between
/// leaves the project as it was.
pub fn write_keeping_previous(file: &Path, body: &[u8], plan: WritePlan) -> io::Result<()> {
    let keep = match plan {
        WritePlan::Unchanged => return Ok(()),
        WritePlan::Write { keep_previous } => keep_previous,
    };
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if keep && file.exists() {
        let tmp = temporary_beside(file);
        let copied = std::fs::copy(file, &tmp).and_then(|_| std::fs::rename(&tmp, prev_path(file)));
        if let Err(e) = copied {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
    }
    let tmp = temporary_beside(file);
    let written = std::fs::write(&tmp, body).and_then(|_| std::fs::rename(&tmp, file));
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

/// Put the previous generation back, keeping the current one as the new
/// previous -- so this is undone by doing it again
/// (`ProjectFileWriter.restorePrevious`). `NotFound` when there is none.
///
/// Snapshots are not versioned (`dev-docs/project-scrollback.md` 3.5.6, and
/// the same on macOS): a pane that exists only in the previous generation
/// opens without its history.
pub fn restore_previous(file: &Path) -> io::Result<()> {
    let prev = prev_path(file);
    if !prev.exists() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "there is no previous version"));
    }
    if !file.exists() {
        return std::fs::rename(&prev, file);
    }
    let held = temporary_beside(file);
    std::fs::rename(file, &held)?;
    if let Err(e) = std::fs::rename(&prev, file) {
        // Put the current one back where it was: a restore that failed must
        // not leave the project without its file.
        let _ = std::fs::rename(&held, file);
        return Err(e);
    }
    std::fs::rename(&held, &prev)
}

// ========================================================= moving whole projects

/// Whether two paths are one file: the same path, or -- on a file system
/// that ignores case, as Windows' does -- the same file under two spellings.
/// A path that does not exist is only the same as itself.
fn same_file(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y || x.to_string_lossy().to_lowercase() == y.to_string_lossy().to_lowercase(),
        _ => false,
    }
}

/// Move a project -- its file and every sidecar there is -- to `to`.
/// **Refused with `AlreadyExists` when `to` is another project's file**:
/// renaming onto a project would silently delete it. A change of case only
/// (`demo` -> `Demo`) is the same file and goes ahead.
///
/// The file moves first; a sidecar that fails to follow is reported, and
/// the file is put back so the project is never split across two names.
pub fn move_project(from: &Path, to: &Path) -> io::Result<()> {
    if to.exists() && !same_file(from, to) {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists, "a project already has that file"));
    }
    for (a, b) in sidecars(from).iter().zip(sidecars(to).iter()) {
        if b.exists() && !same_file(a, b) {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, format!("{} is in the way", b.display())));
        }
    }
    std::fs::rename(from, to)?;
    let mut moved: Vec<(PathBuf, PathBuf)> = Vec::new();
    for (a, b) in sidecars(from).into_iter().zip(sidecars(to)) {
        if !a.exists() {
            continue;
        }
        if let Err(e) = std::fs::rename(&a, &b) {
            for (x, y) in moved.into_iter().rev() {
                let _ = std::fs::rename(&y, &x);
            }
            let _ = std::fs::rename(to, from);
            return Err(e);
        }
        moved.push((a, b));
    }
    Ok(())
}

/// Copy a project's file to `to`, with its snapshots -- so the copy opens
/// with the same scrollback -- and **without** its previous generation: a
/// copy starts its own history. Refused with `AlreadyExists` like
/// `move_project`. The copy's file is written last, so a copy that failed
/// halfway lists as nothing.
pub fn copy_project(from: &Path, to: &Path) -> io::Result<()> {
    if to.exists() {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists, "a project already has that file"));
    }
    let (src, dst) = (scrollback_dir(from), scrollback_dir(to));
    if src.is_dir() {
        if dst.exists() {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, format!("{} is in the way", dst.display())));
        }
        std::fs::create_dir_all(&dst)?;
        for e in std::fs::read_dir(&src)?.flatten() {
            if e.path().is_file() {
                std::fs::copy(e.path(), dst.join(e.file_name()))?;
            }
        }
    }
    let tmp = temporary_beside(to);
    let r = std::fs::copy(from, &tmp).and_then(|_| std::fs::rename(&tmp, to));
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r.map(|_| ())
}

// ============================================================ delete and undo

/// **Delete ends in the Recycle Bin** (§6.2, as macOS sends it to the Trash),
/// but not at once. First the project -- its file and its sidecars -- is
/// moved into a directory of its own under the projects directory's
/// `.deleted`, `<name>-<time>`: a rename on one volume, so it is atomic, the
/// listing loses it at once, and Undo is a rename back. **When the banner
/// goes** (the window closes, or the next delete) that directory is sent to
/// the Recycle Bin; the host does the sending (`SHFileOperationW`), and
/// whatever a process left in `.deleted` when it ended is sent at the next
/// start (`leftovers`).
///
/// Why not straight to the Recycle Bin: getting an item back out of it has
/// no call, only its undocumented records to read, and reading the wrong one
/// would put back something else.
///
/// Where a deleted project waits for Undo.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stash {
    /// The project's file, where it was.
    pub file: PathBuf,
    /// The directory holding it now.
    pub held: PathBuf,
}

/// The directory deleted projects wait in, under the projects directory.
/// It starts with a dot and is a directory, so a listing that takes only
/// `.json` files never sees it.
pub fn trash_dir(projects_dir: &Path) -> PathBuf {
    projects_dir.join(".deleted")
}

/// The directory a project deleted at `now` (seconds) waits in:
/// `<file stem>-<now>`, then `-2`, `-3`… after it while `taken` says the
/// name is in use -- two deletes of one name in one second are two
/// directories.
pub fn stash_name(file: &Path, now: i64, taken: impl Fn(&str) -> bool) -> String {
    let stem = file.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let first = format!("{stem}-{now}");
    if !taken(&first) {
        return first;
    }
    (2u32..).map(|n| format!("{first}-{n}")).find(|c| !taken(c)).expect("an unbounded range has a free name")
}

/// Move a project out of the listing, for Undo. The sidecars go with it.
pub fn stash(file: &Path, trash: &Path, now: i64) -> io::Result<Stash> {
    let name = file.file_name().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?;
    std::fs::create_dir_all(trash)?;
    let held = trash.join(stash_name(file, now, |n| trash.join(n).exists()));
    std::fs::create_dir(&held)?;
    let target = held.join(name);
    if let Err(e) = move_project(file, &target) {
        let _ = std::fs::remove_dir(&held);
        return Err(e);
    }
    Ok(Stash { file: file.to_path_buf(), held })
}

/// Put a stashed project back where it was. **Refused with `AlreadyExists`
/// when something has been saved there since** -- Undo must not overwrite
/// the newer project.
pub fn unstash(s: &Stash) -> io::Result<()> {
    let name = s.file.file_name().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?;
    move_project(&s.held.join(name), &s.file)?;
    let _ = std::fs::remove_dir(&s.held);
    Ok(())
}

/// What in `trash` is to be sent to the Recycle Bin: every directory there
/// **but the one the banner still holds** (`held`) -- a process that ended
/// with the banner up, a crash, a power cut, left the rest, and the banner
/// that could undo them went with it. Files there are not a stash this makes
/// and are left alone.
pub fn leftovers(trash: &Path, held: Option<&Path>) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(trash) else { return Vec::new() };
    let mut v: Vec<PathBuf> =
        entries.flatten().map(|e| e.path()).filter(|p| p.is_dir() && Some(p.as_path()) != held).collect();
    v.sort();
    v
}

/// Whether a directory entry of the projects directory is a project to list:
/// a file named `*.json`. **Not `.deleted`** (a directory), not a `.prev`,
/// not a snapshot directory, not a temporary file (`.tmp`). A leading dot
/// alone does not hide one: a project named `.x` is the file `.x.json`, and
/// macOS lists it.
pub fn listable(name: &str, is_file: bool) -> bool {
    is_file && Path::new(name).extension().is_some_and(|e| e == "json")
}

/// The "Deleted <name>  [Undo]" banner (§6.2): up **until the window closes
/// or the next delete**. Generic over what is held, so the lifecycle is
/// tested without files.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Undo<T> {
    held: Option<(String, T)>,
}

impl<T> Default for Undo<T> {
    fn default() -> Self {
        Undo { held: None }
    }
}

impl<T> Undo<T> {
    /// A project was deleted. Returns the one this replaces, **for the caller
    /// to send to the Recycle Bin** -- the next delete is where the last
    /// one's Undo ends.
    pub fn deleted(&mut self, name: String, held: T) -> Option<T> {
        self.held.replace((name, held)).map(|(_, t)| t)
    }

    /// What is held, while there is something to undo.
    pub fn peek(&self) -> Option<&T> {
        self.held.as_ref().map(|(_, t)| t)
    }

    /// The banner's text argument: the name, while there is something to undo.
    pub fn banner(&self) -> Option<&str> {
        self.held.as_ref().map(|(n, _)| n.as_str())
    }

    /// Undo was pressed: what to put back. The banner goes.
    pub fn undo(&mut self) -> Option<(String, T)> {
        self.held.take()
    }

    /// The window closed: what to send to the Recycle Bin. The banner goes.
    pub fn closed(&mut self) -> Option<T> {
        self.held.take().map(|(_, t)| t)
    }
}

// ================================================================ names

/// What a typed project name comes to (§6.2) -- **the macOS side's
/// `ProjectsRules.NameVerdict`, case for case**, so the two hosts agree on
/// which names clash. Asked by all three places a name is typed on Windows:
/// Save as Project, Rename…, and the name a copy is given (#983).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NameVerdict {
    /// Go ahead, under this name: the one typed, **with its surrounding
    /// white space taken off**.
    Ok(String),
    /// The same name the project already has: nothing to do.
    Unchanged,
    /// Nothing left once trimmed, or once made a file name.
    Empty,
    /// Another project has this name, or a name saved under the same file --
    /// named, so the refusal (or Save As's overwrite question) can say which.
    Taken(String),
}

/// One project as a name is checked against it: its name and its file's
/// name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Named {
    pub name: String,
    pub file: String,
}

/// `ProjectsRules.renameVerdict` / `ProjectStore.nameVerdict`: whether
/// `proposed` may be the name of `current` (`None` for a new project, as Save
/// As has). `rule_file` is the file name the naming rule gives a name
/// (`None` when nothing is left of it); it is asked of the **trimmed** name.
///
/// The rule, as on macOS: trim; empty is `Empty`; the project's own name is
/// `Unchanged`; then a clash with any *other* project -- the same name
/// exactly, **or** the same file ignoring case (Windows' and macOS' disks
/// both do not tell `Demo.json` from `demo.json`). A change of case to the
/// project's own name is its own file, so it is a rename.
pub fn name_verdict(
    current: Option<&Named>,
    proposed: &str,
    rule_file: impl Fn(&str) -> Option<String>,
    all: &[Named],
) -> NameVerdict {
    let name = proposed.trim();
    let Some(file) = rule_file(name).filter(|_| !name.is_empty()) else {
        return NameVerdict::Empty;
    };
    if current.is_some_and(|c| c.name == name) {
        return NameVerdict::Unchanged;
    }
    let own = current.map(|c| c.file.to_lowercase());
    let clash = all
        .iter()
        .filter(|o| Some(o.file.to_lowercase()) != own)
        .find(|o| o.name == name || o.file.to_lowercase() == file.to_lowercase());
    match clash {
        Some(o) => NameVerdict::Taken(o.name.clone()),
        None => NameVerdict::Ok(name.to_string()),
    }
}

/// What Save as Project does with a typed name (#980 on macOS,
/// `ProjectsRules.saveAsStep`): a free name is saved; a taken one is asked
/// about -- the same overwrite question as picking that project -- and then
/// saved **under the existing project's name**; nothing typed does nothing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SaveAsStep {
    Save(String),
    ConfirmOverwrite(String),
    Nothing,
}

pub fn save_as_step(v: NameVerdict) -> SaveAsStep {
    match v {
        NameVerdict::Ok(n) => SaveAsStep::Save(n),
        NameVerdict::Taken(existing) => SaveAsStep::ConfirmOverwrite(existing),
        NameVerdict::Empty | NameVerdict::Unchanged => SaveAsStep::Nothing,
    }
}

/// The copy's name (§6.2: "默认名「<原名> 副本」"): `sentence` with the
/// original put in for `{}`, then with ` 2`, ` 3`… after it until `taken`
/// says no. `taken` is asked about names; the caller answers for files too.
pub fn copy_name(original: &str, sentence: &str, taken: impl Fn(&str) -> bool) -> String {
    let first = sentence.replacen("{}", original.trim(), 1);
    if !taken(&first) {
        return first;
    }
    (2u32..).map(|n| format!("{first} {n}")).find(|c| !taken(c)).expect("an unbounded range has a free name")
}

// ============================================================== the detail

/// One version in the history (§6.2), as a row shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Version {
    pub saved_at: i64,
    pub panes: usize,
    /// The one that is the project now; the other is the previous
    /// generation, the only one that can be restored.
    pub current: bool,
}

/// The versions, **newest first** (§6.2: "按时间"), the current one first
/// when two were saved in the same second. At most two: the storage keeps one
/// previous generation. After a restore the previous one can be the newer.
pub fn versions(current: Option<(i64, usize)>, previous: Option<(i64, usize)>) -> Vec<Version> {
    let mut v: Vec<Version> = current
        .map(|(t, p)| Version { saved_at: t, panes: p, current: true })
        .into_iter()
        .chain(previous.map(|(t, p)| Version { saved_at: t, panes: p, current: false }))
        .collect();
    v.sort_by(|a, b| b.saved_at.cmp(&a.saved_at).then(b.current.cmp(&a.current)));
    v
}

/// The last part of a directory, as a pane in the thumbnail is labelled:
/// `C:\work\repo` -> `repo`, `/home/a/` -> `a`, `C:\` -> `C:`, `/` -> `/`.
/// Both separators, whichever machine saved it.
pub fn last_segment(cwd: &str) -> &str {
    let t = cwd.trim_end_matches(['/', '\\']);
    if t.is_empty() {
        return if cwd.is_empty() { "" } else { &cwd[..1] };
    }
    match t.rfind(['/', '\\']) {
        Some(i) => &t[i + 1..],
        None => t,
    }
}

/// The directories a project's panes are in, each once, in the order the
/// panes are walked; panes with none are skipped.
pub fn distinct_dirs<'a>(cwds: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for c in cwds {
        if !c.is_empty() && !out.iter().any(|o| o == c) {
            out.push(c.to_string());
        }
    }
    out
}

/// A pane's label in the thumbnail: the directory's last part, then its
/// title when it has one that says something else. **The project file keeps
/// no role**, on either host (`Project.zig`'s `Leaf`), so the title stands
/// where §6.1 asks for the role.
pub fn pane_label(cwd: &str, title: &str) -> String {
    let seg = last_segment(cwd);
    let title = title.trim();
    match (seg.is_empty(), title.is_empty() || title == seg) {
        (true, true) => String::new(),
        (true, false) => title.to_string(),
        (false, true) => seg.to_string(),
        (false, false) => format!("{seg} \u{b7} {title}"),
    }
}

/// How much a project's snapshots take on disk, in bytes: the files directly
/// in its snapshot directory (it has no subdirectories). Nothing there is 0.
pub fn scrollback_bytes(file: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(scrollback_dir(file)) else { return 0 };
    entries.flatten().filter_map(|e| e.metadata().ok()).filter(|m| m.is_file()).map(|m| m.len()).sum()
}

/// A size for a person: `0 B`, `512 B`, `1.5 KB`, `12 MB`, `3.2 GB` --
/// powers of 1024, one decimal below ten.
pub fn format_bytes(n: u64) -> String {
    const UNITS: [&str; 4] = ["KB", "MB", "GB", "TB"];
    if n < 1024 {
        return format!("{n} B");
    }
    let mut v = n as f64 / 1024.0;
    let mut u = 0;
    while v >= 1024.0 && u + 1 < UNITS.len() {
        v /= 1024.0;
        u += 1;
    }
    if v < 10.0 {
        format!("{:.1} {}", v, UNITS[u])
    } else {
        format!("{:.0} {}", v, UNITS[u])
    }
}

/// A saved time as `YYYY-MM-DD HH:MM`, `offset` seconds east of UTC (the
/// host passes the machine's). The civil-from-days conversion is Howard
/// Hinnant's, proleptic Gregorian.
pub fn format_time(unix: i64, offset: i64) -> String {
    let t = unix + offset;
    let days = t.div_euclid(86_400);
    let secs = t.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{:04}-{:02}-{:02} {:02}:{:02}", y, m, d, secs / 3600, secs % 3600 / 60)
}

/// Seconds east of UTC, from the same moment read both ways (`GetLocalTime`
/// and `GetSystemTime` on Windows): `(year, month, day, hour, minute)` each.
/// Rounded to the minute, so the second or two between the two reads is lost.
pub fn offset_seconds(local: (i64, i64, i64, i64, i64), utc: (i64, i64, i64, i64, i64)) -> i64 {
    let at = |(y, m, d, h, mi): (i64, i64, i64, i64, i64)| days_from_civil(y, m, d) * 1440 + h * 60 + mi;
    (at(local) - at(utc)) * 60
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Hinnant).
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

// ========================================================= closing a busy tab

/// §6.3 and `ProjectSaveBeforeClose.swift`: closing something busy offers
/// "Save as a Project Before Closing?" **only when it is one tab** -- a tab
/// on its own, or a window holding just the one. A window of several tabs
/// keeps the plain warning: several trees are not one project.
pub fn offers_save_before_close(tabs_closing: usize, busy: bool) -> bool {
    busy && tabs_closing == 1
}

/// The three answers to that question, in the order the buttons are shown.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseChoice {
    /// Ask for a name; close only once the save has worked.
    Save,
    CloseWithoutSaving,
    KeepOpen,
}

pub const CLOSE_BUTTONS: [CloseChoice; 3] = [CloseChoice::Save, CloseChoice::CloseWithoutSaving, CloseChoice::KeepOpen];

/// What a pressed button means, by its place in `CLOSE_BUTTONS`. **Anything
/// else keeps the tab open** -- a dialog closed some other way, a failure:
/// closing kills processes, so it has to be asked for, never defaulted into.
pub fn close_choice(pressed: Option<usize>) -> CloseChoice {
    pressed.and_then(|i| CLOSE_BUTTONS.get(i).copied()).unwrap_or(CloseChoice::KeepOpen)
}

// ================================================================== layout

/// Launch/Revert/Save's places are the roles section's; this section has no
/// unsaved state (§2.3: no Revert / Save) and its own three actions, wider
/// because their words are: **Show in Explorer, Overwrite with Current Tab,
/// Open**, right-aligned in the same band, on the same row.
pub const ACTION_W: [i32; 3] = [160, 176, 96];

/// A project's row in the list: its name, and under it when it was saved and
/// how big it is.
pub const ROW_H: i32 = 44;
/// The "Deleted <name>  [Undo]" banner at the top of the list.
pub const BANNER_H: i32 = 44;
/// The Undo button in it.
pub const UNDO_W: i32 = 72;
/// The thumbnail's height: whatever the editor has left over the lines
/// below it, **no less than `THUMB_MIN`** (at the minimum window that is
/// what it gets) and no more than `THUMB_MAX`. And the gap between two panes
/// in it.
pub const THUMB_MIN: i32 = 96;
pub const THUMB_MAX: i32 = 240;
pub const THUMB_GAP: i32 = 4;
/// One line of the detail, and one row of the version history (a button
/// tall, for Restore).
pub const LINE_H: i32 = 20;
/// Rename… and Restore.
pub const BUTTON_W: i32 = 96;
/// How many detail lines there are: last saved, size, directories, roles,
/// scrollback, autosave.
pub const DETAIL_LINES: usize = 6;

/// This section's own constants, for the test that holds them to multiples
/// of four with the grid's.
pub const ALL: [i32; 11] =
    [ACTION_W[0], ACTION_W[1], ACTION_W[2], ROW_H, BANNER_H, UNDO_W, THUMB_MIN, THUMB_MAX, THUMB_GAP, LINE_H, BUTTON_W];

/// Show in Explorer, Overwrite, Open: right-aligned in the band, `PAD` from
/// the right, on the row the band's buttons are on.
pub fn actions(g: &SectionGrid, w: i32, dpi: i32) -> [Rect; 3] {
    let s = |v| scale(v, dpi);
    let (top, bottom) = (g.actions[2].top, g.actions[2].bottom);
    let open = Rect::new(w - s(PAD) - s(ACTION_W[2]), top, w - s(PAD), bottom);
    let over = Rect::new(open.left - s(BUTTONS_GAP) - s(ACTION_W[1]), top, open.left - s(BUTTONS_GAP), bottom);
    let show = Rect::new(over.left - s(BUTTONS_GAP) - s(ACTION_W[0]), top, over.left - s(BUTTONS_GAP), bottom);
    [show, over, open]
}

/// The band's status text between the list's buttons and the actions.
pub fn status(g: &SectionGrid, actions: &[Rect; 3], dpi: i32) -> Rect {
    let left = g.status.left;
    Rect::new(left, g.status.top, (actions[0].left - scale(PAD, dpi)).max(left), g.status.bottom)
}

/// The list column's inside.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListLayout {
    /// The banner, when a delete can be undone; the rows start under it.
    pub banner: Option<Rect>,
    pub undo: Option<Rect>,
    /// Row `i` is `rows_top + i * ROW_H`.
    pub rows_top: i32,
    pub row_h: i32,
    /// Where row text starts: the list's content edge (§2.3a).
    pub text_left: i32,
}

pub fn list_layout(list: Rect, dpi: i32, banner: bool) -> ListLayout {
    let s = |v| scale(v, dpi);
    let (banner, undo) = if banner {
        let b = Rect::new(list.left, list.top, list.right, list.top + s(BANNER_H));
        let top = b.top + (b.height() - s(CONTROL_H)) / 2;
        let u = Rect::new(b.right - s(PAD) - s(UNDO_W), top, b.right - s(PAD), top + s(CONTROL_H));
        (Some(b), Some(u))
    } else {
        (None, None)
    };
    let rows_top = banner.map_or(list.top, |b| b.bottom);
    ListLayout { banner, undo, rows_top, row_h: s(ROW_H), text_left: list.left + s(PAD) }
}

/// Which row a click at `y` is on, of `count` rows.
pub fn row_at(l: &ListLayout, top: usize, count: usize, y: i32, bottom: i32) -> Option<usize> {
    if y < l.rows_top || y >= bottom || l.row_h <= 0 {
        return None;
    }
    let i = top + ((y - l.rows_top) / l.row_h) as usize;
    (i < count).then_some(i)
}

/// How many whole rows fit between `rows_top` and `bottom`.
pub fn rows_fitting(l: &ListLayout, bottom: i32) -> usize {
    if l.row_h <= 0 {
        return 0;
    }
    ((bottom - l.rows_top).max(0) / l.row_h) as usize
}

/// Everything in the editor column, in the section's coordinates. **Two left
/// edges only** (§2.3a): the editor's margin, where headings and the
/// thumbnail start, and the control column, where every value and field
/// starts; labels are right-aligned in the label column before it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorLayout {
    /// The project's name, as a heading, from the margin to just before
    /// Rename… -- the macOS detail's first row. Renaming is a dialog
    /// (`Rename…`), not a field here, so nothing on this page is ever typed
    /// and left unapplied.
    pub title: Rect,
    /// Rename…, at the editor's right margin.
    pub rename: Rect,
    pub thumb: Rect,
    /// One per detail line: the label, right-aligned, and the value.
    pub labels: [Rect; DETAIL_LINES],
    pub values: [Rect; DETAIL_LINES],
    pub history_heading: Rect,
    /// Two rows, newest first; the Restore button sits on whichever row is
    /// the previous generation.
    pub history: [Rect; 2],
    pub restore: [Rect; 2],
    /// The editor's margin and its control column, the two left edges.
    pub margin: i32,
    pub control_left: i32,
}

pub fn editor_layout(editor: Rect, dpi: i32) -> EditorLayout {
    let s = |v| scale(v, dpi);
    let margin = editor.left + s(PAD);
    let right = (editor.right - s(PAD)).max(margin + 1);
    let label_right = margin + s(LABEL_W);
    let control_left = label_right + s(LABEL_GAP);
    let mut y = editor.top + s(PAD);
    let rename = Rect::new((right - s(BUTTON_W)).max(margin), y, right, y + s(CONTROL_H));
    let title = Rect::new(margin, y, (rename.left - s(BUTTONS_GAP)).max(margin), y + s(CONTROL_H));
    y = title.bottom + s(GROUP_GAP);
    // Everything under the thumbnail, measured first so the thumbnail can
    // have what is left: the gap, the detail lines, the history.
    let below = s(GROUP_GAP)
        + DETAIL_LINES as i32 * (s(LINE_H) + s(ROW_GAP) / 2)
        + (s(GROUP_GAP) - s(ROW_GAP) / 2)
        + s(LINE_H)
        + s(ROW_GAP)
        + 2 * (s(CONTROL_H) + s(ROW_GAP));
    let room = editor.bottom - s(PAD) - y - below;
    let thumb = Rect::new(margin, y, right, y + room.clamp(s(THUMB_MIN), s(THUMB_MAX)));
    y = thumb.bottom + s(GROUP_GAP);
    let mut labels = [Rect::default(); DETAIL_LINES];
    let mut values = [Rect::default(); DETAIL_LINES];
    for i in 0..DETAIL_LINES {
        labels[i] = Rect::new(margin, y, label_right, y + s(LINE_H));
        values[i] = Rect::new(control_left, y, right.max(control_left), y + s(LINE_H));
        y += s(LINE_H) + s(ROW_GAP) / 2;
    }
    y += s(GROUP_GAP) - s(ROW_GAP) / 2;
    let history_heading = Rect::new(margin, y, right, y + s(LINE_H));
    y = history_heading.bottom + s(ROW_GAP);
    let mut history = [Rect::default(); 2];
    let mut restore = [Rect::default(); 2];
    for i in 0..2 {
        history[i] = Rect::new(control_left, y, right.max(control_left), y + s(CONTROL_H));
        restore[i] = Rect::new((right - s(BUTTON_W)).max(control_left), y, right.max(control_left), y + s(CONTROL_H));
        y += s(CONTROL_H) + s(ROW_GAP);
    }
    EditorLayout { title, rename, thumb, labels, values, history_heading, history, restore, margin, control_left }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{content_size, layout, section_grid, MIN_H, MIN_W};

    fn split(side_by_side: bool, ratio: f64, a: Shape, b: Shape) -> Shape {
        Shape::Split { side_by_side, ratio, first: Box::new(a), second: Box::new(b) }
    }

    /// A scratch directory of the test's own, removed at the end.
    struct Scratch(PathBuf);
    impl Scratch {
        fn new(tag: &str) -> Scratch {
            use std::sync::atomic::{AtomicU64, Ordering};
            static N: AtomicU64 = AtomicU64::new(0);
            let p = std::env::temp_dir().join(format!(
                "polter-projects-test-{}-{}-{}",
                tag,
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&p);
            std::fs::create_dir_all(&p).unwrap();
            Scratch(p)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn read(p: &Path) -> String {
        std::fs::read_to_string(p).unwrap()
    }
    /// The directory's entries, sorted, for comparing what is left behind.
    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> =
            std::fs::read_dir(dir).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        v.sort();
        v
    }

    // ------------------------------------------------------------ shapes

    #[test]
    fn the_layout_is_the_shape_and_the_directions_not_the_ratios() {
        let a = split(true, 0.5, Shape::Pane, split(false, 0.3, Shape::Pane, Shape::Pane));
        let dragged = split(true, 0.7, Shape::Pane, split(false, 0.6, Shape::Pane, Shape::Pane));
        assert!(a.same_layout(&dragged), "a divider dragged is not a layout change");
        let turned = split(true, 0.5, Shape::Pane, split(true, 0.3, Shape::Pane, Shape::Pane));
        assert!(!a.same_layout(&turned), "a split's direction is");
        let fewer = split(true, 0.5, Shape::Pane, Shape::Pane);
        assert!(!a.same_layout(&fewer), "a pane closed is");
        let swapped = split(true, 0.5, split(false, 0.3, Shape::Pane, Shape::Pane), Shape::Pane);
        assert!(!a.same_layout(&swapped), "which side holds the split is");
        assert!(same_layout(None, None));
        assert!(!same_layout(Some(&Shape::Pane), None));
        assert_eq!(a.panes(), 3);
    }

    #[test]
    fn the_thumbnail_has_one_box_per_pane_in_tree_order() {
        let s = split(true, 0.25, Shape::Pane, split(false, 0.5, Shape::Pane, Shape::Pane));
        let r = thumbnail(&s, Rect::new(0, 0, 404, 204), 4);
        assert_eq!(r.len(), 3);
        assert_eq!(r[0], Rect::new(0, 0, 100, 204), "a quarter of what is left after the gap");
        assert_eq!(r[1], Rect::new(104, 0, 404, 100));
        assert_eq!(r[2], Rect::new(104, 104, 404, 204));
        // Nothing overlaps, everything is inside.
        for (i, a) in r.iter().enumerate() {
            assert!(a.left >= 0 && a.top >= 0 && a.right <= 404 && a.bottom <= 204, "{a:?}");
            for b in &r[i + 1..] {
                assert!(a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top, "{a:?} {b:?}");
            }
        }
    }

    #[test]
    fn a_deep_tree_in_a_small_box_still_shows_every_pane() {
        let mut s = Shape::Pane;
        for i in 0..12 {
            s = split(i % 2 == 0, 0.9, s, Shape::Pane);
        }
        let r = thumbnail(&s, Rect::new(0, 0, 40, 30), 2);
        assert_eq!(r.len(), 13);
        assert!(r.iter().all(|x| x.width() >= 1 && x.height() >= 1), "{r:?}");
        // A ratio out of range is held to it rather than drawn outside.
        let odd = split(true, 7.0, Shape::Pane, Shape::Pane);
        let r = thumbnail(&odd, Rect::new(0, 0, 100, 10), 4);
        assert!(r[1].left <= 100 && r[1].width() >= 1, "{r:?}");
        let nan = split(false, f64::NAN, Shape::Pane, Shape::Pane);
        assert_eq!(thumbnail(&nan, Rect::new(0, 0, 10, 104), 4)[0].bottom, 50);
    }

    // ------------------------------------------------ one previous generation

    #[test]
    fn the_previous_generation_is_kept_only_on_a_layout_change() {
        assert_eq!(plan_write(Existing::Nothing), WritePlan::Write { keep_previous: false });
        assert_eq!(plan_write(Existing::Unreadable), WritePlan::Write { keep_previous: true }, "somebody's project");
        let same = Existing::Read { layout_changed: false, only_the_time_changed: true };
        assert_eq!(plan_write(same), WritePlan::Unchanged, "only the time: not written at all");
        let title = Existing::Read { layout_changed: false, only_the_time_changed: false };
        assert_eq!(plan_write(title), WritePlan::Write { keep_previous: false }, "a title is not worth a generation");
        let panes = Existing::Read { layout_changed: true, only_the_time_changed: false };
        assert_eq!(plan_write(panes), WritePlan::Write { keep_previous: true });
    }

    /// §6.2 (39ae3f040): an overwrite always keeps what it replaced -- the
    /// case the mac lost, one pane over one pane with only the directory and
    /// title changed, first.
    #[test]
    fn an_overwrite_always_keeps_what_it_replaces() {
        let one_pane_over_one_pane = Existing::Read { layout_changed: false, only_the_time_changed: false };
        assert_eq!(plan_for(WriteKind::Overwrite, one_pane_over_one_pane), WritePlan::Write { keep_previous: true });
        assert_eq!(
            plan_for(WriteKind::Save, one_pane_over_one_pane),
            WritePlan::Write { keep_previous: false },
            "a save of the same does not: that is the rule that must stay"
        );
        let identical = Existing::Read { layout_changed: false, only_the_time_changed: true };
        assert_eq!(plan_for(WriteKind::Overwrite, identical), WritePlan::Write { keep_previous: true }, "asked for, so done");
        assert_eq!(plan_for(WriteKind::Save, identical), WritePlan::Unchanged);
        let reshaped = Existing::Read { layout_changed: true, only_the_time_changed: false };
        assert_eq!(plan_for(WriteKind::Overwrite, reshaped), WritePlan::Write { keep_previous: true });
        assert_eq!(plan_for(WriteKind::Overwrite, Existing::Unreadable), WritePlan::Write { keep_previous: true });
        assert_eq!(plan_for(WriteKind::Overwrite, Existing::Nothing), WritePlan::Write { keep_previous: false }, "nothing to keep");
    }

    /// #970: "Save as Project" onto a taken name is an overwrite, and so
    /// keeps what it replaced -- one pane over one pane included.
    #[test]
    fn save_as_onto_a_taken_name_is_an_overwrite() {
        assert_eq!(save_as(true), WriteKind::Overwrite);
        assert_eq!(save_as(false), WriteKind::Save);
        let one_pane_over_one_pane = Existing::Read { layout_changed: false, only_the_time_changed: false };
        assert_eq!(plan_for(save_as(true), one_pane_over_one_pane), WritePlan::Write { keep_previous: true });
    }

    #[test]
    fn a_rename_is_not_a_new_version() {
        for e in [
            Existing::Nothing,
            Existing::Unreadable,
            Existing::Read { layout_changed: true, only_the_time_changed: false },
            Existing::Read { layout_changed: false, only_the_time_changed: true },
        ] {
            assert_eq!(plan_for(WriteKind::Rename, e), WritePlan::Write { keep_previous: false }, "{e:?}");
        }
    }

    /// On disk: one pane overwritten by one pane, the old file is the `.prev`.
    #[test]
    fn an_overwrite_on_disk_leaves_the_old_file_as_prev() {
        let d = Scratch::new("overwrite");
        let f = d.0.join("a.json");
        let same_shape = Existing::Read { layout_changed: false, only_the_time_changed: false };
        write_keeping_previous(&f, b"cwd=/old", plan_for(WriteKind::Save, Existing::Nothing)).unwrap();
        write_keeping_previous(&f, b"cwd=/new", plan_for(WriteKind::Overwrite, same_shape)).unwrap();
        assert_eq!((read(&f), read(&prev_path(&f))), ("cwd=/new".into(), "cwd=/old".into()));
    }

    #[test]
    fn the_sidecars_are_named_as_on_macos() {
        let f = Path::new("/p/demo.json");
        assert_eq!(prev_path(f), Path::new("/p/demo.json.prev"));
        assert_eq!(scrollback_dir(f), Path::new("/p/demo.scrollback"));
        assert_eq!(scrollback_dir(Path::new("/p/project")), Path::new("/p/project.scrollback"));
    }

    #[test]
    fn a_write_keeps_what_was_there_as_prev_and_leaves_nothing_else() {
        let d = Scratch::new("write");
        let f = d.0.join("a.json");
        write_keeping_previous(&f, b"one", WritePlan::Write { keep_previous: false }).unwrap();
        assert_eq!(names(&d.0), ["a.json"]);
        write_keeping_previous(&f, b"two", WritePlan::Write { keep_previous: true }).unwrap();
        assert_eq!((read(&f), read(&prev_path(&f))), ("two".into(), "one".into()));
        write_keeping_previous(&f, b"three", WritePlan::Write { keep_previous: false }).unwrap();
        assert_eq!((read(&f), read(&prev_path(&f))), ("three".into(), "one".into()), "a title change keeps the old prev");
        write_keeping_previous(&f, b"ignored", WritePlan::Unchanged).unwrap();
        assert_eq!(read(&f), "three");
        assert_eq!(names(&d.0), ["a.json", "a.json.prev"], "no temporary file is left behind");
    }

    #[test]
    fn restoring_swaps_so_it_is_undone_by_restoring_again() {
        let d = Scratch::new("restore");
        let f = d.0.join("a.json");
        assert_eq!(restore_previous(&f).unwrap_err().kind(), io::ErrorKind::NotFound);
        std::fs::write(&f, "new").unwrap();
        assert_eq!(restore_previous(&f).unwrap_err().kind(), io::ErrorKind::NotFound, "no prev");
        std::fs::write(prev_path(&f), "old").unwrap();
        restore_previous(&f).unwrap();
        assert_eq!((read(&f), read(&prev_path(&f))), ("old".into(), "new".into()));
        restore_previous(&f).unwrap();
        assert_eq!((read(&f), read(&prev_path(&f))), ("new".into(), "old".into()));
        assert_eq!(names(&d.0), ["a.json", "a.json.prev"]);
        // Only a prev: it becomes the project.
        std::fs::remove_file(&f).unwrap();
        restore_previous(&f).unwrap();
        assert_eq!(names(&d.0), ["a.json"]);
        assert_eq!(read(&f), "old");
    }

    // ------------------------------------------------ moving whole projects

    fn project(dir: &Path, stem: &str, body: &str, prev: bool, snaps: bool) -> PathBuf {
        let f = dir.join(format!("{stem}.json"));
        std::fs::write(&f, body).unwrap();
        if prev {
            std::fs::write(prev_path(&f), format!("{body}-prev")).unwrap();
        }
        if snaps {
            std::fs::create_dir_all(scrollback_dir(&f)).unwrap();
            std::fs::write(scrollback_dir(&f).join("0.snap"), "S").unwrap();
        }
        f
    }

    #[test]
    fn a_move_takes_every_sidecar_with_it() {
        let d = Scratch::new("move");
        let a = project(&d.0, "a", "A", true, true);
        let b = d.0.join("b.json");
        move_project(&a, &b).unwrap();
        assert_eq!(names(&d.0), ["b.json", "b.json.prev", "b.scrollback"]);
        assert_eq!(read(&scrollback_dir(&b).join("0.snap")), "S");
        // Without sidecars, only the file.
        let c = project(&d.0, "c", "C", false, false);
        move_project(&c, &d.0.join("e.json")).unwrap();
        assert_eq!(names(&d.0), ["b.json", "b.json.prev", "b.scrollback", "e.json"]);
    }

    #[test]
    fn a_move_onto_another_project_is_refused_and_touches_nothing() {
        let d = Scratch::new("clash");
        let a = project(&d.0, "a", "A", true, true);
        let b = project(&d.0, "b", "B", false, false);
        assert_eq!(move_project(&a, &b).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        assert_eq!((read(&a), read(&b)), ("A".into(), "B".into()));
        // A stray sidecar in the way is refused too, before anything moves.
        std::fs::create_dir_all(d.0.join("x.scrollback")).unwrap();
        assert_eq!(move_project(&a, &d.0.join("x.json")).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        assert!(a.exists() && prev_path(&a).exists() && scrollback_dir(&a).exists());
    }

    #[test]
    fn a_copy_has_the_snapshots_and_no_history() {
        let d = Scratch::new("copy");
        let a = project(&d.0, "a", "A", true, true);
        let b = d.0.join("b.json");
        copy_project(&a, &b).unwrap();
        assert_eq!(names(&d.0), ["a.json", "a.json.prev", "a.scrollback", "b.json", "b.scrollback"]);
        assert_eq!(read(&b), "A");
        assert_eq!(read(&scrollback_dir(&b).join("0.snap")), "S");
        assert_eq!(copy_project(&a, &b).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
    }

    // ------------------------------------------------------ delete and undo

    #[test]
    fn a_stashed_project_leaves_the_listing_and_comes_back_whole() {
        let d = Scratch::new("stash");
        let a = project(&d.0, "a", "A", true, true);
        let t = trash_dir(&d.0);
        let s = stash(&a, &t, 1_700_000_000).unwrap();
        assert_eq!(s.held, t.join("a-1700000000"));
        assert_eq!(names(&d.0), [".deleted"], "nothing of it is left where a listing looks");
        assert_eq!(names(&s.held), ["a.json", "a.json.prev", "a.scrollback"], "all three went");
        unstash(&s).unwrap();
        assert_eq!(names(&d.0), [".deleted", "a.json", "a.json.prev", "a.scrollback"]);
        assert_eq!(read(&prev_path(&a)), "A-prev");
        assert!(names(&t).is_empty(), "the stash's own directory went with it");
    }

    #[test]
    fn two_deletes_of_one_name_in_one_second_are_two_stashes() {
        assert_eq!(stash_name(Path::new("/p/a.json"), 5, |_| false), "a-5");
        assert_eq!(stash_name(Path::new("/p/a.json"), 5, |n| n == "a-5" || n == "a-5-2"), "a-5-3");
        let d = Scratch::new("stash-twice");
        let t = trash_dir(&d.0);
        let one = stash(&project(&d.0, "a", "1", false, false), &t, 9).unwrap();
        let two = stash(&project(&d.0, "a", "2", false, false), &t, 9).unwrap();
        assert_ne!(one.held, two.held);
        assert_eq!(read(&two.held.join("a.json")), "2");
    }

    #[test]
    fn undo_does_not_overwrite_a_project_saved_since() {
        let d = Scratch::new("undo-clash");
        let a = project(&d.0, "a", "old", false, false);
        let s = stash(&a, &trash_dir(&d.0), 1).unwrap();
        std::fs::write(&a, "newer").unwrap();
        assert_eq!(unstash(&s).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(read(&a), "newer");
        assert_eq!(read(&s.held.join("a.json")), "old", "the stash is still there to send on");
    }

    /// What is left in `.deleted` goes to the Recycle Bin -- except the one
    /// the banner still holds.
    #[test]
    fn leftovers_are_everything_but_what_the_banner_holds() {
        let d = Scratch::new("leftovers");
        let t = trash_dir(&d.0);
        assert!(leftovers(&t, None).is_empty(), "no .deleted at all");
        let a = stash(&project(&d.0, "a", "A", true, true), &t, 1).unwrap();
        let b = stash(&project(&d.0, "b", "B", false, false), &t, 2).unwrap();
        std::fs::write(t.join("stray.txt"), "x").unwrap();
        assert_eq!(leftovers(&t, None), [a.held.clone(), b.held.clone()]);
        assert_eq!(leftovers(&t, Some(&b.held)), [a.held.clone()]);
    }

    #[test]
    fn the_list_skips_everything_that_is_not_a_project_file() {
        assert!(listable("a.json", true));
        assert!(listable("项目.json", true));
        assert!(!listable(".deleted", false));
        assert!(!listable(".deleted", true));
        assert!(!listable("a.json.prev", true));
        assert!(!listable("a.scrollback", false));
        assert!(!listable(".a.json.12.0.tmp", true));
        assert!(!listable("x.json", false), "a directory named like one");
        assert!(listable(".x.json", true), "a project named .x");
    }

    /// §6.2: the banner is up until the window closes or the next delete,
    /// and the next delete is where the last one's Undo ends.
    #[test]
    fn the_undo_banner_lasts_until_the_next_delete_or_the_close() {
        let mut u: Undo<u32> = Undo::default();
        assert_eq!(u.banner(), None);
        assert_eq!(u.deleted("a".into(), 1), None);
        assert_eq!(u.banner(), Some("a"));
        assert_eq!(u.deleted("b".into(), 2), Some(1), "a's stash is handed back to be sent on");
        assert_eq!(u.banner(), Some("b"));
        assert_eq!(u.peek(), Some(&2));
        assert_eq!(u.undo(), Some(("b".into(), 2)));
        assert_eq!(u.peek(), None);
        assert_eq!(u.banner(), None);
        assert_eq!(u.undo(), None, "undone once");
        assert_eq!(u.closed(), None);
        u.deleted("c".into(), 3);
        assert_eq!(u.closed(), Some(3));
        assert_eq!(u.banner(), None, "the close takes the banner");
    }

    // ---------------------------------------------------------------- names

    fn named(n: &str, f: &str) -> Named {
        Named { name: n.into(), file: f.into() }
    }

    /// The naming rule, as far as these tests need it: `<name>.json`,
    /// nothing for nothing.
    fn rule(n: &str) -> Option<String> {
        (!n.is_empty()).then(|| format!("{n}.json"))
    }

    /// #983: the macOS side's five cells (`ProjectStoreSettingsTests.
    /// aTypedNameThatIsAlreadyAProjectIsAnOverwrite`), for Save As: gamma,
    /// "  gamma ", Gamma, delta, blank.
    #[test]
    fn a_typed_name_is_trimmed_and_checked_as_on_macos() {
        let all = [named("gamma", "gamma.json"), named("beta", "beta.json")];
        let v = |t: &str| name_verdict(None, t, rule, &all);
        assert_eq!(v("gamma"), NameVerdict::Taken("gamma".into()));
        assert_eq!(v("  gamma "), NameVerdict::Taken("gamma".into()), "trimmed first");
        assert_eq!(v("Gamma"), NameVerdict::Taken("gamma".into()), "the same file, whatever the case");
        assert_eq!(v("delta"), NameVerdict::Ok("delta".into()));
        assert_eq!(v("   "), NameVerdict::Empty);
        assert_eq!(save_as_step(v("  gamma ")), SaveAsStep::ConfirmOverwrite("gamma".into()));
        assert_eq!(save_as_step(v(" delta ")), SaveAsStep::Save("delta".into()), "saved under the trimmed name");
        assert_eq!(save_as_step(v(" ")), SaveAsStep::Nothing);
    }

    #[test]
    fn a_rename_onto_a_name_that_is_taken_is_refused_and_names_it() {
        let all = [named("Demo", "Demo.json"), named("Other", "Other.json")];
        let me = Some(&all[0]);
        assert_eq!(name_verdict(me, "Other", rule, &all), NameVerdict::Taken("Other".into()));
        assert_eq!(name_verdict(me, " OTHER ", rule, &all), NameVerdict::Taken("Other".into()), "its file, whatever the case");
        // The same name clashes even when the files differ -- a file an older
        // naming rule gave one of them.
        let legacy = [named("Demo", "Demo.json"), named("Other", "legacy-other.json")];
        assert_eq!(name_verdict(Some(&legacy[0]), "Other", rule, &legacy), NameVerdict::Taken("Other".into()));
        // Names are compared exactly, as on macOS: another case of a name
        // saved under another file is a different name.
        assert_eq!(name_verdict(Some(&legacy[0]), "other", rule, &legacy), NameVerdict::Ok("other".into()));
        // Two names that sanitize to one file are the same file.
        let odd = [named("Demo", "Demo.json"), named("a:b", "a_b.json")];
        assert_eq!(name_verdict(Some(&odd[0]), "a_b", rule, &odd), NameVerdict::Taken("a:b".into()));
    }

    #[test]
    fn a_rename_to_itself_is_unchanged_and_a_change_of_case_is_a_rename() {
        let all = [named("Demo", "Demo.json"), named("Other", "Other.json")];
        let me = Some(&all[0]);
        assert_eq!(name_verdict(me, " Demo ", rule, &all), NameVerdict::Unchanged);
        assert_eq!(name_verdict(me, "demo", rule, &all), NameVerdict::Ok("demo".into()));
        assert_eq!(name_verdict(me, "  New  ", rule, &all), NameVerdict::Ok("New".into()));
    }

    #[test]
    fn a_rename_to_nothing_is_refused() {
        let all = [named("Demo", "Demo.json")];
        assert_eq!(name_verdict(Some(&all[0]), "  ", rule, &all), NameVerdict::Empty);
        assert_eq!(name_verdict(Some(&all[0]), "///", |_| None, &all), NameVerdict::Empty);
    }

    /// A copy's name is checked with the same rule: a name whose file some
    /// other project already has is skipped.
    #[test]
    fn a_copy_is_named_past_what_the_name_rule_calls_taken() {
        let all = [named("Demo", "Demo.json"), named("demo copy", "demo copy.json")];
        let taken = |n: &str| !matches!(name_verdict(None, n, rule, &all), NameVerdict::Ok(_));
        assert_eq!(copy_name("Demo", "{} copy", taken), "Demo copy 2", "Demo copy is demo copy.json");
    }

    #[test]
    fn a_copy_is_named_after_its_original_and_numbered_past_what_is_taken() {
        let taken = ["Demo copy", "Demo copy 2"];
        assert_eq!(copy_name("Demo", "{} copy", |_| false), "Demo copy");
        assert_eq!(copy_name("Demo", "{} copy", |n| taken.contains(&n)), "Demo copy 3");
        assert_eq!(copy_name(" 项目 ", "{} 副本", |_| false), "项目 副本");
    }

    // --------------------------------------------------------------- detail

    #[test]
    fn versions_are_newest_first_and_say_which_is_current() {
        let v = versions(Some((200, 3)), Some((100, 2)));
        assert_eq!(v, [Version { saved_at: 200, panes: 3, current: true }, Version { saved_at: 100, panes: 2, current: false }]);
        // After a restore the previous one is the newer.
        let v = versions(Some((100, 2)), Some((200, 3)));
        assert_eq!((v[0].current, v[1].current), (false, true));
        // Same second: the current one first.
        let v = versions(Some((100, 2)), Some((100, 3)));
        assert!(v[0].current);
        assert_eq!(versions(Some((1, 1)), None).len(), 1);
        assert!(versions(None, None).is_empty());
    }

    #[test]
    fn a_pane_is_labelled_by_its_directory_and_its_title() {
        assert_eq!(last_segment("C:\\work\\repo"), "repo");
        assert_eq!(last_segment("/home/a/"), "a");
        assert_eq!(last_segment("C:\\"), "C:");
        assert_eq!(last_segment("/"), "/");
        assert_eq!(last_segment(""), "");
        assert_eq!(pane_label("C:\\work\\repo", "vim"), "repo · vim");
        assert_eq!(pane_label("C:\\work\\repo", "repo"), "repo");
        assert_eq!(pane_label("", "vim"), "vim");
        assert_eq!(pane_label("", " "), "");
        assert_eq!(distinct_dirs(["/a", "", "/b", "/a"]), ["/a", "/b"]);
    }

    #[test]
    fn sizes_and_times_read_as_a_person_would_write_them() {
        assert_eq!(format_bytes(0), "0 B");
        assert_eq!(format_bytes(1023), "1023 B");
        assert_eq!(format_bytes(1536), "1.5 KB");
        assert_eq!(format_bytes(12 * 1024 * 1024), "12 MB");
        assert_eq!(format_time(0, 0), "1970-01-01 00:00");
        assert_eq!(format_time(1_757_000_000, 0), "2025-09-04 15:33");
        assert_eq!(format_time(1_757_000_000, 8 * 3600), "2025-09-04 23:33");
        assert_eq!(format_time(951_782_400, 0), "2000-02-29 00:00", "a leap day");
        assert_eq!(format_time(-1, 0), "1969-12-31 23:59");
    }

    #[test]
    fn scrollback_is_counted_from_the_projects_own_directory() {
        let d = Scratch::new("size");
        let a = project(&d.0, "a", "A", false, true);
        std::fs::write(scrollback_dir(&a).join("1.snap"), vec![0u8; 1000]).unwrap();
        assert_eq!(scrollback_bytes(&a), 1001);
        assert_eq!(scrollback_bytes(&d.0.join("none.json")), 0);
    }

    #[test]
    fn the_offset_is_local_minus_utc_across_a_day_boundary() {
        assert_eq!(offset_seconds((2026, 10, 1, 8, 30), (2026, 10, 1, 0, 30)), 8 * 3600);
        assert_eq!(offset_seconds((2026, 10, 1, 2, 0), (2026, 9, 30, 18, 0)), 8 * 3600, "past midnight");
        assert_eq!(offset_seconds((2026, 12, 31, 19, 0), (2027, 1, 1, 0, 0)), -5 * 3600, "past new year, westward");
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2000, 3, 1), 11_017);
        assert_eq!(format_time(days_from_civil(2024, 2, 29) * 86_400, 0), "2024-02-29 00:00");
    }

    /// §6.3: one busy tab is offered a save; several tabs, or nothing
    /// busy, keep what they had.
    #[test]
    fn only_one_busy_tab_is_offered_a_save_before_it_closes() {
        assert!(offers_save_before_close(1, true));
        assert!(!offers_save_before_close(1, false), "nothing running: no question at all");
        assert!(!offers_save_before_close(3, true), "a window of three tabs keeps the plain warning");
        assert!(!offers_save_before_close(0, true));
    }

    #[test]
    fn only_the_close_button_closes() {
        assert_eq!(close_choice(Some(0)), CloseChoice::Save);
        assert_eq!(close_choice(Some(1)), CloseChoice::CloseWithoutSaving);
        assert_eq!(close_choice(Some(2)), CloseChoice::KeepOpen);
        assert_eq!(close_choice(Some(9)), CloseChoice::KeepOpen, "not a button");
        assert_eq!(close_choice(None), CloseChoice::KeepOpen, "the dialog failed or went away");
    }

    // --------------------------------------------------------------- layout

    #[test]
    fn this_sections_values_are_multiples_of_four() {
        for v in ALL {
            assert_eq!(v % 4, 0, "{v}");
        }
    }

    fn cases() -> Vec<(i32, i32, i32)> {
        let mut out = Vec::new();
        for dpi in [96, 120, 144, 168, 192, 240] {
            for (w, h) in [(MIN_W, MIN_H), (1180, 800), (1920, 1040)] {
                let (cw, ch) = content_size(w, h);
                out.push((cw * dpi / 96, ch * dpi / 96, dpi));
            }
        }
        out
    }

    /// §2.3a in this section: its band's buttons on the band's row, nothing
    /// overlapping, Open ending `PAD` from the right, the status text between
    /// the list's buttons and the actions; at the minimum window too.
    #[test]
    fn the_actions_sit_in_the_band_on_its_row() {
        for (w, h, dpi) in cases() {
            let g = section_grid(w, h, dpi, true);
            let a = actions(&g, w, dpi);
            let st = status(&g, &a, dpi);
            let at = format!("{w}x{h} at {dpi}");
            let b = g.list_buttons.unwrap();
            for r in &a {
                assert_eq!((r.top, r.bottom), (b[0].top, b[0].bottom), "{at}");
            }
            assert_eq!(a[2].right, w - scale(PAD, dpi), "{at}");
            assert!(a[0].right < a[1].left && a[1].right < a[2].left, "{at}");
            assert!(b[2].right < st.left && st.right <= a[0].left && st.width() > 0, "{at}");
        }
    }

    #[test]
    fn the_banner_pushes_the_rows_down_and_the_text_keeps_its_edge() {
        let g = section_grid(700, 500, 96, true);
        let list = g.list.unwrap();
        let plain = list_layout(list, 96, false);
        let with = list_layout(list, 96, true);
        assert_eq!(plain.rows_top, list.top);
        assert_eq!(with.rows_top, list.top + BANNER_H);
        assert_eq!(plain.text_left, g.text_left, "the list's text starts where the + button does");
        let u = with.undo.unwrap();
        assert_eq!(u.right, list.right - PAD);
        assert_eq!(u.top - with.banner.unwrap().top, with.banner.unwrap().bottom - u.bottom, "centred");
        assert_eq!(row_at(&with, 0, 3, with.rows_top + ROW_H + 1, list.bottom), Some(1));
        assert_eq!(row_at(&with, 0, 3, with.rows_top - 1, list.bottom), None, "the banner is not a row");
        assert_eq!(row_at(&with, 0, 1, with.rows_top + ROW_H + 1, list.bottom), None, "past the last row");
        assert_eq!(row_at(&with, 2, 5, with.rows_top + 1, list.bottom), Some(2), "scrolled");
        assert_eq!(rows_fitting(&plain, list.bottom), (list.height() / ROW_H) as usize);
    }

    /// §2.3a: two left edges in the editor, and everything inside it and
    /// above the bottom rule -- at the minimum window, at every DPI.
    #[test]
    fn the_editor_has_two_left_edges_and_fits_at_the_minimum() {
        for (w, h, dpi) in cases() {
            let g = section_grid(w, h, dpi, true);
            let e = editor_layout(g.editor, dpi);
            let at = format!("{w}x{h} at {dpi}");
            assert_eq!(e.margin, g.editor.left + scale(PAD, dpi), "{at}");
            assert_eq!(e.control_left, e.margin + scale(LABEL_W + LABEL_GAP, dpi), "{at}");
            let mut starts = vec![e.title.left, e.thumb.left, e.history_heading.left];
            starts.extend(e.labels.iter().map(|r| r.left));
            assert!(starts.iter().all(|&x| x == e.margin), "{at} {starts:?}");
            let mut ctl = vec![];
            ctl.extend(e.values.iter().map(|r| r.left));
            ctl.extend(e.history.iter().map(|r| r.left));
            assert!(ctl.iter().all(|&x| x == e.control_left), "{at} {ctl:?}");
            assert!(e.labels.iter().all(|r| r.right == e.control_left - scale(LABEL_GAP, dpi)), "{at}");
            // Inside the editor and above the bottom rule.
            let all = [e.title, e.rename, e.thumb, e.history_heading, e.history[1], e.restore[1]];
            for r in all {
                assert!(r.left >= g.editor.left && r.right <= g.editor.right, "{at} {r:?}");
                assert!(r.bottom <= g.bottom_rule.top, "{at} {r:?} under the rule at {}", g.bottom_rule.top);
            }
            assert!(e.title.right < e.rename.left && e.title.width() > 0, "{at}");
            assert_eq!(e.rename.right, g.editor.right - scale(PAD, dpi), "{at} Rename… at the right margin");
            let th = e.thumb.height();
            assert!(th >= scale(THUMB_MIN, dpi) && th <= scale(THUMB_MAX, dpi), "{at} thumb {th}");
            assert!(e.history[0].bottom < e.history[1].top, "{at}");
            // The window's and the section's rules are still one line.
            let l = layout(w + scale(SIDEBAR, dpi) + 1, h + scale(TOP, dpi) + 1, dpi);
            assert_eq!(l.content.top + g.bottom_rule.top, l.bottom_rule.top, "{at}");
        }
    }
}
