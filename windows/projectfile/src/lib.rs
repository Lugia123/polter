//! A project file: what it says, and the bytes it is written as.
//!
//! **This mirrors `src/Project.zig`, byte for byte, and nothing else.** The
//! format, its two versions, what a read puts right and the rules for a
//! string and a number are written down once, in that file's module comment;
//! read it before changing anything here. The third implementation is
//! `macos/Sources/Features/Projects/ProjectDocument.swift`.
//!
//! What holds the three together is `test/project-format/`: the files there
//! are made by `src/Project.zig`'s tests from values spelled out in them,
//! and this crate's test reads every one and has to write the same bytes
//! back. Nothing here makes those files.
//!
//! Only the shape and the bytes are here. Where a project is kept, which
//! file a name gives, `.prev` and the snapshot directory are the host's
//! (`windows/host/src/project.rs`, `polter-settings-shell`).

pub use polter_split_tree::Axis;

/// The format this build writes, and the latest it reads.
pub const FORMAT_VERSION: i64 = 2;

/// Who was working in a pane when the project was saved.
///
/// **Nobody and not known are two answers, and neither is a default** -- this
/// type has no `Default` on purpose. A pane a person ran a shell in is
/// `None`; a pane out of a format 1 file, or one whose host could not tell,
/// is `Unknown`.
#[derive(Clone, Debug, PartialEq)]
pub enum Agent {
    /// Nothing recorded who, if anybody, was here.
    Unknown,
    /// Nobody: a pane with no agent in it.
    None,
    Agent(Who),
}

/// The agent in a pane. `role`, `cli` and `session` are the words a group's
/// own file keeps for its last supervisor under the same names
/// (`LastSupervisor` in `src/poltergeist/Chat.zig`): each is empty when the
/// agent had none or nobody could tell which.
#[derive(Clone, Debug, PartialEq)]
pub struct Who {
    pub role: String,
    pub cli: String,
    pub session: String,
    /// Whether it is the supervisor of the project's group. At most one pane
    /// of a project is; `parse_snapshot` never hands back two.
    pub supervisor: bool,
}

/// A pane: one leaf of the *saved* tree. Not a `split_tree::Leaf` -- there is
/// no such type; `split_tree::Node::Leaf` holds a bare `PaneId`, and a
/// `PaneId` from a previous run means nothing. So a saved leaf holds what a
/// `PaneId` would have pointed the host at, not the id itself.
///
/// **No `Default`.** A leaf built with `..Default::default()` compiles when a
/// field is added and says nothing about it; `SavedLeaf::plain` is the one
/// short way to build one, and it takes who is in the pane.
#[derive(Clone, Debug, PartialEq)]
pub struct SavedLeaf {
    pub cwd: String,
    pub title: String,
    /// Opaque; see `Project.zig`'s `Leaf.history` doc comment. Never a path
    /// to open directly.
    pub history: String,
    /// The pane's scrollback snapshot, as a name relative to the project's
    /// snapshot directory: `<ASCII digits>.snap`, or empty for none. Never a
    /// path.
    pub scrollback: String,
    pub agent: Agent,
}

impl SavedLeaf {
    /// A pane in `cwd` with no title, history or snapshot, and `agent` in it.
    pub fn plain(cwd: &str, agent: Agent) -> SavedLeaf {
        SavedLeaf { cwd: cwd.to_string(), title: String::new(), history: String::new(), scrollback: String::new(), agent }
    }
}

/// One node of the saved tree: a pane, or a division of two more nodes.
#[derive(Clone, Debug, PartialEq)]
pub enum SavedNode {
    Leaf(SavedLeaf),
    Split { axis: Axis, ratio: f64, left: Box<SavedNode>, right: Box<SavedNode> },
}

/// One tab: a tree of panes.
#[derive(Clone, Debug, PartialEq)]
pub struct Tab {
    pub root: SavedNode,
}

/// Which corner of the screen a `Frame` is measured from: Win32 measures
/// down from the top left, AppKit up from the bottom left, and the same four
/// numbers are two different places.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    TopLeft,
    BottomLeft,
}

/// Where a window was and how big, **as its host had it and nothing more**.
/// The screen it was on may be gone when the project is opened again;
/// bringing the window back onto one that is there belongs to whoever opens
/// it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub origin: Origin,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// One window: its tabs in the order they stood, and which was in front.
#[derive(Clone, Debug, PartialEq)]
pub struct Window {
    /// `None` when nothing recorded it -- every window out of a format 1
    /// file.
    pub frame: Option<Frame>,
    /// The index, in `tabs`, of the tab that was showing.
    pub front: usize,
    /// Never empty in anything `parse_snapshot` returns.
    pub tabs: Vec<Tab>,
}

/// The whole saved project, matching `Project.zig`'s `Snapshot`.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub name: String,
    pub saved_at: i64,
    /// The group this project is the project of. A project has at most one.
    pub group: Option<String>,
    /// The windows, the first being the one in front. Empty for a project
    /// with nothing in it.
    pub windows: Vec<Window>,
    /// The next scrollback snapshot number this project will hand out. **One
    /// counter for the whole project**, whatever window or tab a pane is in:
    /// every snapshot of a project is in one directory.
    ///
    /// ⚠️ **Read and written back even by a build that does not use it.** A
    /// writer that dropped a counter it did not understand would reset it,
    /// the next save would hand out a number some closed pane still has a
    /// file under, and a new pane would open with that pane's history.
    pub next_scrollback: Option<u64>,
}

impl Snapshot {
    /// The tree of the tab in front in the first window -- the window in
    /// front -- or `None` for a project with nothing in it. What a picture
    /// of the project that has room for one tab shows.
    pub fn front_tab(&self) -> Option<&SavedNode> {
        let first = self.windows.first()?;
        first.tabs.get(first.front).or(first.tabs.first()).map(|t| &t.root)
    }

    /// Every tab's tree: windows in order, and each window's tabs in order.
    pub fn tabs(&self) -> impl Iterator<Item = &SavedNode> {
        self.windows.iter().flat_map(|w| w.tabs.iter().map(|t| &t.root))
    }

    /// Every snapshot name the project refers to, in any window or tab --
    /// what a save must count as taken and must not prune.
    pub fn scrollback_names(&self) -> Vec<String> {
        self.tabs().flat_map(|root| leaves(root).into_iter().filter(|l| !l.scrollback.is_empty()).map(|l| l.scrollback.clone())).collect()
    }

    /// How many panes the project has, in every window and tab.
    pub fn pane_count(&self) -> usize {
        self.tabs().map(|root| leaves(root).len()).sum()
    }
}

/// Every leaf, left before right.
pub fn leaves(node: &SavedNode) -> Vec<&SavedLeaf> {
    let mut out = Vec::new();
    fn walk<'a>(n: &'a SavedNode, out: &mut Vec<&'a SavedLeaf>) {
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

/// Every leaf of `node`, in the same order, to change.
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

/// Whether `name` is a snapshot name this format writes: 1 to 20 ASCII
/// digits, then `.snap`, and nothing else.
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

/// Matches `Project.zig`'s `ReadError`: never a half a tree.
#[derive(Clone, Debug, PartialEq)]
pub enum ReadError {
    /// No project by this name exists.
    NotFound,
    /// The file exists but is not a complete, well-formed project.
    Corrupt,
    /// The file says it is of format `found`, later than `FORMAT_VERSION`: a
    /// newer build wrote it. **Not `Corrupt`, and never read as format 1**
    /// -- the file is whole, and what this build would make of it is a
    /// project with panes missing that the next save would put on disk.
    TooNew { found: i64 },
    /// The name has nothing left once sanitized, so no file can be named
    /// after it. Matches `Project.zig`'s `InvalidName`.
    InvalidName,
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReadError::NotFound => write!(f, "there is no such project"),
            ReadError::Corrupt => write!(f, "the project file is damaged or incomplete"),
            ReadError::TooNew { found } => write!(
                f,
                "the project file is format {found}, and this build reads up to format {FORMAT_VERSION}: a later version of Polter wrote it"
            ),
            ReadError::InvalidName => write!(f, "the project name names no file"),
        }
    }
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// A ratio or a frame holds a value that is not a finite number, which the
/// file has no way to say.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NotFinite;

/// `Axis` as `Project.zig`'s `Direction` spells it: full words, not
/// `layout.rs`'s `"h"`/`"v"`. Two wire formats for two features; the strings
/// are not interchangeable.
pub fn direction_str(axis: Axis) -> &'static str {
    match axis {
        Axis::Horizontal => "horizontal",
        Axis::Vertical => "vertical",
    }
}

pub fn direction_from_str(s: &str) -> Option<Axis> {
    match s {
        "horizontal" => Some(Axis::Horizontal),
        "vertical" => Some(Axis::Vertical),
        _ => None,
    }
}

/// The bytes of `snapshot` as a format 2 file -- `emit` in `Project.zig`,
/// which says why this is written out by hand and not handed to a JSON
/// library.
pub fn emit(snapshot: &Snapshot) -> Result<String, NotFinite> {
    let mut out = String::new();
    out.push_str(&format!("{{\"format\":{FORMAT_VERSION},\"name\":"));
    string(&mut out, &snapshot.name);
    out.push_str(&format!(",\"saved_at\":{}", snapshot.saved_at));
    out.push_str(",\"root\":{\"kind\":\"moved-to-windows\"}");
    if let Some(group) = snapshot.group.as_deref().filter(|g| !g.is_empty()) {
        out.push_str(",\"group\":");
        string(&mut out, group);
    }
    if let Some(n) = snapshot.next_scrollback {
        out.push_str(&format!(",\"next_scrollback\":{n}"));
    }
    out.push_str(",\"windows\":[");
    for (i, window) in snapshot.windows.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('{');
        if let Some(frame) = &window.frame {
            out.push_str("\"frame\":{\"origin\":\"");
            out.push_str(match frame.origin {
                Origin::TopLeft => "top_left",
                Origin::BottomLeft => "bottom_left",
            });
            out.push_str("\",\"x\":");
            number(&mut out, frame.x)?;
            out.push_str(",\"y\":");
            number(&mut out, frame.y)?;
            out.push_str(",\"width\":");
            number(&mut out, frame.width)?;
            out.push_str(",\"height\":");
            number(&mut out, frame.height)?;
            out.push_str("},");
        }
        out.push_str(&format!("\"front\":{},\"tabs\":[", window.front));
        for (j, tab) in window.tabs.iter().enumerate() {
            if j > 0 {
                out.push(',');
            }
            out.push_str("{\"root\":");
            node(&mut out, &tab.root)?;
            out.push('}');
        }
        out.push_str("]}");
    }
    out.push_str("]}");
    Ok(out)
}

fn node(out: &mut String, n: &SavedNode) -> Result<(), NotFinite> {
    match n {
        SavedNode::Leaf(leaf) => {
            out.push_str("{\"kind\":\"leaf\"");
            field(out, "cwd", &leaf.cwd);
            field(out, "title", &leaf.title);
            field(out, "history", &leaf.history);
            field(out, "scrollback", &leaf.scrollback);
            out.push_str(",\"agent\":{\"kind\":\"");
            match &leaf.agent {
                Agent::Unknown => out.push_str("unknown\""),
                Agent::None => out.push_str("none\""),
                Agent::Agent(who) => {
                    out.push_str("agent\"");
                    field(out, "role", &who.role);
                    field(out, "cli", &who.cli);
                    field(out, "session", &who.session);
                    out.push_str(if who.supervisor { ",\"supervisor\":true" } else { ",\"supervisor\":false" });
                }
            }
            out.push_str("}}");
        }
        SavedNode::Split { axis, ratio, left, right } => {
            out.push_str("{\"kind\":\"split\",\"direction\":\"");
            out.push_str(direction_str(*axis));
            out.push_str("\",\"ratio\":");
            number(out, *ratio)?;
            out.push_str(",\"left\":");
            node(out, left)?;
            out.push_str(",\"right\":");
            node(out, right)?;
            out.push('}');
        }
    }
    Ok(())
}

/// `,"key":"value"`, or nothing when the value is empty.
fn field(out: &mut String, key: &str, value: &str) {
    if value.is_empty() {
        return;
    }
    out.push_str(",\"");
    out.push_str(key);
    out.push_str("\":");
    string(out, value);
}

fn string(out: &mut String, value: &str) {
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{0}'..='\u{1f}' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// The shortest decimal that reads back as `value`, in full: `Display` for
/// an `f64` is that, never with an exponent and with no point on a whole
/// value.
fn number(out: &mut String, value: f64) -> Result<(), NotFinite> {
    if !value.is_finite() {
        return Err(NotFinite);
    }
    out.push_str(&format!("{value}"));
    Ok(())
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// What a read keeps track of across the whole file, to put right the two
/// things `Project.zig`'s module comment says a read puts right.
#[derive(Default)]
struct Fixups {
    scrollback: std::collections::HashSet<String>,
    supervisors: usize,
}

type Object = serde_json::Map<String, serde_json::Value>;

/// The format `bytes` says it is: 1 for a file with no `format` key. For a
/// caller that has to know a file is of an older format before writing over
/// it; `parse_snapshot` reads either and does not say which it read.
pub fn format_of(bytes: &[u8]) -> Result<i64, ReadError> {
    let parsed: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| ReadError::Corrupt)?;
    format_in(parsed.as_object().ok_or(ReadError::Corrupt)?)
}

fn format_in(obj: &Object) -> Result<i64, ReadError> {
    match obj.get("format") {
        None => Ok(1),
        Some(v) => match v.as_i64() {
            Some(n) if n < 1 => Err(ReadError::Corrupt),
            Some(n) if n > FORMAT_VERSION => Err(ReadError::TooNew { found: n }),
            Some(n) => Ok(n),
            None => Err(ReadError::Corrupt),
        },
    }
}

/// Matches `Project.zig`'s `parse`. Never returns half a `Snapshot`: any
/// structural problem is `Corrupt`, the same promise `Project.zig` makes.
pub fn parse_snapshot(bytes: &[u8]) -> Result<Snapshot, ReadError> {
    let parsed: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| ReadError::Corrupt)?;
    let obj = parsed.as_object().ok_or(ReadError::Corrupt)?;

    // The format first, before anything is made of the rest.
    let format = format_in(obj)?;

    let name = obj.get("name").and_then(|n| n.as_str()).ok_or(ReadError::Corrupt)?.to_string();
    let saved_at = obj.get("saved_at").and_then(|s| s.as_i64()).ok_or(ReadError::Corrupt)?;

    // Absent or not a whole number: `None`, and the allocator falls back on
    // the numbers actually in use, which is what it would do for a file
    // written before the counter existed.
    let next_scrollback = obj.get("next_scrollback").and_then(|n| n.as_u64());

    let mut fixups = Fixups::default();

    let mut windows = if format == 1 {
        // One tab is one window with that tab in it; no `root` is a project
        // with nothing in it.
        match obj.get("root") {
            Some(r) => vec![Window { frame: None, front: 0, tabs: vec![Tab { root: json_to_node(r, format, &mut fixups)? }] }],
            None => Vec::new(),
        }
    } else {
        json_to_windows(obj.get("windows").ok_or(ReadError::Corrupt)?, format, &mut fixups)?
    };

    let group = if format == 1 {
        None
    } else {
        match obj.get("group") {
            None => None,
            Some(serde_json::Value::String(s)) => Some(s.clone()).filter(|s| !s.is_empty()),
            Some(_) => return Err(ReadError::Corrupt),
        }
    };

    if fixups.supervisors > 1 {
        for window in &mut windows {
            for tab in &mut window.tabs {
                for leaf in leaves_mut(&mut tab.root) {
                    if let Agent::Agent(who) = &mut leaf.agent {
                        who.supervisor = false;
                    }
                }
            }
        }
    }

    Ok(Snapshot { name, saved_at, group, windows, next_scrollback })
}

fn json_to_windows(v: &serde_json::Value, format: i64, fixups: &mut Fixups) -> Result<Vec<Window>, ReadError> {
    let items = v.as_array().ok_or(ReadError::Corrupt)?;
    let mut windows = Vec::with_capacity(items.len());
    for item in items {
        let obj = item.as_object().ok_or(ReadError::Corrupt)?;

        let frame = match obj.get("frame") {
            None => None,
            Some(f) => {
                let f = f.as_object().ok_or(ReadError::Corrupt)?;
                let origin = match f.get("origin").and_then(|o| o.as_str()) {
                    Some("top_left") => Origin::TopLeft,
                    Some("bottom_left") => Origin::BottomLeft,
                    _ => return Err(ReadError::Corrupt),
                };
                let side = |key: &str| f.get(key).and_then(|n| n.as_f64()).ok_or(ReadError::Corrupt);
                Some(Frame { origin, x: side("x")?, y: side("y")?, width: side("width")?, height: side("height")? })
            }
        };

        let tab_items = obj.get("tabs").and_then(|t| t.as_array()).ok_or(ReadError::Corrupt)?;
        if tab_items.is_empty() {
            return Err(ReadError::Corrupt);
        }
        let mut tabs = Vec::with_capacity(tab_items.len());
        for tab in tab_items {
            let root = tab.as_object().and_then(|t| t.get("root")).ok_or(ReadError::Corrupt)?;
            tabs.push(Tab { root: json_to_node(root, format, fixups)? });
        }

        let front = obj.get("front").filter(|n| n.is_u64()).and_then(|n| n.as_u64()).ok_or(ReadError::Corrupt)? as usize;
        if front >= tabs.len() {
            return Err(ReadError::Corrupt);
        }

        windows.push(Window { frame, front, tabs });
    }
    Ok(windows)
}

fn json_to_node(v: &serde_json::Value, format: i64, fixups: &mut Fixups) -> Result<SavedNode, ReadError> {
    let obj = v.as_object().ok_or(ReadError::Corrupt)?;
    let kind = obj.get("kind").and_then(|k| k.as_str()).ok_or(ReadError::Corrupt)?;

    match kind {
        "leaf" => {
            // A name that is not one this format writes is dropped, not
            // refused: the pane still opens, just without its scrollback,
            // which is exactly what a missing snapshot gives. Refusing would
            // cost the whole project for one field. A name an earlier pane
            // already has is dropped for the same reason.
            let scrollback = Some(opt_str(obj.get("scrollback")))
                .filter(|s| is_scrollback_name(s))
                .filter(|s| fixups.scrollback.insert(s.clone()))
                .unwrap_or_default();
            // A format 1 file never said, whatever keys it has.
            let agent = if format == 1 { Agent::Unknown } else { json_to_agent(obj.get("agent").ok_or(ReadError::Corrupt)?)? };
            if matches!(&agent, Agent::Agent(who) if who.supervisor) {
                fixups.supervisors += 1;
            }
            Ok(SavedNode::Leaf(SavedLeaf {
                cwd: opt_str(obj.get("cwd")),
                title: opt_str(obj.get("title")),
                history: opt_str(obj.get("history")),
                scrollback,
                agent,
            }))
        }
        "split" => {
            let direction = obj
                .get("direction")
                .and_then(|d| d.as_str())
                .and_then(direction_from_str)
                .ok_or(ReadError::Corrupt)?;
            let ratio = obj.get("ratio").and_then(|r| r.as_f64()).ok_or(ReadError::Corrupt)?;
            // Both children required -- a split with only `left` is exactly
            // the half-a-tree `Project.zig`'s reader refuses to hand back.
            let left = json_to_node(obj.get("left").ok_or(ReadError::Corrupt)?, format, fixups)?;
            let right = json_to_node(obj.get("right").ok_or(ReadError::Corrupt)?, format, fixups)?;
            Ok(SavedNode::Split { axis: direction, ratio, left: Box::new(left), right: Box::new(right) })
        }
        _ => Err(ReadError::Corrupt),
    }
}

/// Strict where the rest of a leaf is not: these keys are new with format 2,
/// so nothing older wrote them any other way.
fn json_to_agent(v: &serde_json::Value) -> Result<Agent, ReadError> {
    let obj = v.as_object().ok_or(ReadError::Corrupt)?;
    match obj.get("kind").and_then(|k| k.as_str()) {
        Some("unknown") => Ok(Agent::Unknown),
        Some("none") => Ok(Agent::None),
        Some("agent") => Ok(Agent::Agent(Who {
            role: strict_str(obj.get("role"))?,
            cli: strict_str(obj.get("cli"))?,
            session: strict_str(obj.get("session"))?,
            supervisor: obj.get("supervisor").and_then(|b| b.as_bool()).ok_or(ReadError::Corrupt)?,
        })),
        _ => Err(ReadError::Corrupt),
    }
}

/// Absent is empty; anything but a string is `Corrupt`.
fn strict_str(v: Option<&serde_json::Value>) -> Result<String, ReadError> {
    match v {
        None => Ok(String::new()),
        Some(serde_json::Value::String(s)) => Ok(s.clone()),
        Some(_) => Err(ReadError::Corrupt),
    }
}

fn opt_str(v: Option<&serde_json::Value>) -> String {
    match v {
        Some(serde_json::Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

// ---------------------------------------------------------------------------
// Writing over what is there
// ---------------------------------------------------------------------------

/// The saved tree's shape, for the rules that need nothing else: the
/// thumbnail and whether a save changes the layout.
pub fn to_shape(node: &SavedNode) -> polter_settings_shell::projects::Shape {
    use polter_settings_shell::projects::Shape;
    match node {
        SavedNode::Leaf(_) => Shape::Pane,
        SavedNode::Split { axis, ratio, left, right } => Shape::Split {
            side_by_side: *axis == Axis::Horizontal,
            ratio: *ratio,
            first: Box::new(to_shape(left)),
            second: Box::new(to_shape(right)),
        },
    }
}

/// What a save of `new` finds in `on_disk`, the bytes of the file it is
/// about to replace, as `polter_settings_shell::projects::plan_write` asks.
///
/// **A file of an older format is kept, whatever is being written over it**
/// -- even when nothing but the time would change, which otherwise writes
/// nothing. This write turns the file into the current format, which the
/// build that wrote it cannot read; the copy in `.prev` is that build's way
/// back. It is said to the rule as a layout change, the case it keeps for.
///
/// A file this build cannot read -- one from a later format included -- is
/// `Unreadable`, which the rule keeps as well: it is somebody's project.
pub fn found_on_disk(on_disk: &[u8], new: &Snapshot) -> polter_settings_shell::projects::Existing {
    use polter_settings_shell::projects::{same_layout, Existing};
    if format_of(on_disk).is_ok_and(|f| f < FORMAT_VERSION) && parse_snapshot(on_disk).is_ok() {
        return Existing::Read { layout_changed: true, only_the_time_changed: false };
    }
    match parse_snapshot(on_disk) {
        Ok(old) => {
            // The layout is every tab's, in every window: a tab or a window
            // more or fewer is a change of layout too.
            let same = old.windows.len() == new.windows.len()
                && old.windows.iter().zip(&new.windows).all(|(a, b)| {
                    a.tabs.len() == b.tabs.len()
                        && a.tabs.iter().zip(&b.tabs).all(|(x, y)| same_layout(Some(&to_shape(&x.root)), Some(&to_shape(&y.root))))
                });
            Existing::Read {
                layout_changed: !same,
                only_the_time_changed: old.name == new.name
                    && old.group == new.group
                    && old.windows == new.windows
                    && old.next_scrollback == new.next_scrollback,
            }
        }
        Err(_) => Existing::Unreadable,
    }
}

#[cfg(test)]
mod tests;
