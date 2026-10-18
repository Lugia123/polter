//! A project file: what it says, and the bytes it is written as.
//!
//! **This mirrors `src/Project.zig`, byte for byte, and nothing else.** The
//! format, its versions, what a read puts right and the rules for a
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
pub const FORMAT_VERSION: i64 = 3;

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

/// The colour a person gave a pane (task 1699/1700). The ten of the
/// palette, in its order, under the names a file, a tool and a binding
/// action all write (`pane-color-interface.md` §1.1). **The colour set, not
/// the colour shown**: a supervisor's pane with none set shows purple, and
/// that is the host's to draw, not the file's to say.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaneColor {
    None,
    Blue,
    Purple,
    Pink,
    Red,
    Orange,
    Yellow,
    Green,
    Teal,
    Graphite,
}

impl PaneColor {
    /// In the palette's order: the core's `ghostty_poltergeist_pane_color_e`
    /// is the index.
    pub const ALL: [PaneColor; 10] = [
        PaneColor::None,
        PaneColor::Blue,
        PaneColor::Purple,
        PaneColor::Pink,
        PaneColor::Red,
        PaneColor::Orange,
        PaneColor::Yellow,
        PaneColor::Green,
        PaneColor::Teal,
        PaneColor::Graphite,
    ];

    pub fn name(self) -> &'static str {
        match self {
            PaneColor::None => "none",
            PaneColor::Blue => "blue",
            PaneColor::Purple => "purple",
            PaneColor::Pink => "pink",
            PaneColor::Red => "red",
            PaneColor::Orange => "orange",
            PaneColor::Yellow => "yellow",
            PaneColor::Green => "green",
            PaneColor::Teal => "teal",
            PaneColor::Graphite => "graphite",
        }
    }

    pub fn from_name(name: &str) -> Option<PaneColor> {
        PaneColor::ALL.into_iter().find(|c| c.name() == name)
    }

    /// The palette index; `ALL[c.index()] == c`.
    pub fn index(self) -> usize {
        PaneColor::ALL.iter().position(|c| *c == self).unwrap_or(0)
    }
}

/// Whether a supervisor may start a worker in a pane. **Not a `bool`**: the
/// host keeps "not told yet" apart from "told: allowed", and so does the
/// interface (`pane-color-interface.md` §1.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Workers {
    Allowed,
    Refused,
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
    /// What the pane showed: the program's title, or a name somebody chose
    /// for this pane (`title_chosen`).
    pub title: String,
    /// `title` is a name somebody chose for this pane rather than the last
    /// title the program in it reported (format 3, task 1722;
    /// `Project.zig`'s `Leaf.title_chosen`). Only a chosen name is put back
    /// when a project opens; a program's title is the program's to say
    /// again. Written only when true and `title` is not empty.
    pub title_chosen: bool,
    /// Opaque; see `Project.zig`'s `Leaf.history` doc comment. Never a path
    /// to open directly.
    pub history: String,
    /// The pane's scrollback snapshot, as a name relative to the project's
    /// snapshot directory: `<ASCII digits>.snap`, or empty for none. Never a
    /// path.
    pub scrollback: String,
    /// Whether the project's supervisor opened this pane. On the pane and
    /// not in `agent`: the agent leaves, the pane is nobody's, and it is
    /// still one the supervisor opened and may use again. `false` is also
    /// what a pane nothing recorded this for reads as (`Project.zig`'s
    /// `Leaf.by_supervisor` says why the two are not told apart).
    pub by_supervisor: bool,
    /// The four marks a person puts on a pane, new with format 3
    /// (`pane-color-interface.md` §7). Each is `None` when **the host could
    /// not tell yet** -- a pane just restored from this file, whose values
    /// the core has not taken back -- and a save fills that in from the file
    /// (`polter_projects::pages::keeping_what_the_file_knew`) rather than
    /// writing the default over what the file knew. What `parse_snapshot`
    /// hands back is never `None`; a `None` that reaches `emit` is written
    /// as the default, since the file has no way to say "not known".
    ///
    /// The project's supervisor's seat: the pane, not the agent in it, so
    /// it is still the seat after the agent has left. At most one pane of a
    /// project has it; `parse_snapshot` never hands back two.
    pub supervisor_seat: Option<bool>,
    pub color: Option<PaneColor>,
    pub workers: Option<Workers>,
    pub shielded: Option<bool>,
    pub agent: Agent,
}

impl SavedLeaf {
    /// A pane in `cwd` with no title, history or snapshot, not one the
    /// supervisor opened, nobody's seat and no mark on it, and `agent` in
    /// it.
    pub fn plain(cwd: &str, agent: Agent) -> SavedLeaf {
        SavedLeaf {
            cwd: cwd.to_string(),
            title: String::new(),
            title_chosen: false,
            history: String::new(),
            scrollback: String::new(),
            by_supervisor: false,
            supervisor_seat: Some(false),
            color: Some(PaneColor::None),
            workers: Some(Workers::Allowed),
            shielded: Some(false),
            agent,
        }
    }
}

/// One node of the saved tree: a pane, or a division of two more nodes.
#[derive(Clone, Debug, PartialEq)]
pub enum SavedNode {
    Leaf(SavedLeaf),
    /// Several terminals in one pane: one showing, the others behind it.
    /// It takes the place of a pane, so its members are panes -- never a
    /// split, never another stack -- and there are at least two: **one
    /// terminal in a pane is a `Leaf`**. `shown` is the index, in
    /// `members`, of the one in front; the order is the order of its tabs.
    /// See `Project.zig`'s `Stack`.
    Stack { shown: usize, members: Vec<SavedLeaf> },
    Split { axis: Axis, ratio: f64, left: Box<SavedNode>, right: Box<SavedNode> },
}

/// One tab: a tree of panes, and the name somebody gave it.
#[derive(Clone, Debug, PartialEq)]
pub struct Tab {
    pub root: SavedNode,
    /// The name somebody gave the tab -- renamed by hand, or `set_tab_title`
    /// -- or `None` for none (format 3, task 1722; `Project.zig`'s
    /// `Tab.title`). Never `Some("")` in anything `parse_snapshot` returns,
    /// and `Some("")` is written as none. **Not a title a program
    /// reported**: that is the program's to say again, and a pane's
    /// `title` already records it.
    pub title: Option<String>,
}

impl Tab {
    /// A tab nobody named.
    pub fn unnamed(root: SavedNode) -> Tab {
        Tab { root, title: None }
    }
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
    /// The windows, in an order that stays the same from one save to the
    /// next -- not the order they are stacked in on screen. Empty for a project
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

/// Every leaf, left before right; a stack's members in their order.
pub fn leaves(node: &SavedNode) -> Vec<&SavedLeaf> {
    let mut out = Vec::new();
    fn walk<'a>(n: &'a SavedNode, out: &mut Vec<&'a SavedLeaf>) {
        match n {
            SavedNode::Leaf(l) => out.push(l),
            SavedNode::Stack { members, .. } => out.extend(members.iter()),
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
            SavedNode::Stack { members, .. } => out.extend(members.iter_mut()),
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

/// Why a project could not be written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EmitError {
    /// A ratio or a frame holds a value that is not a finite number, which
    /// the file has no way to say.
    NotFinite,
    /// A stack with fewer than two members, or whose `shown` is none of
    /// them. Refused rather than written as something else: one member is
    /// a `Leaf`, and it is whoever built the tree that knows which.
    BadStack,
}

impl std::fmt::Display for EmitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EmitError::NotFinite => write!(f, "a split's ratio or a window's frame is not a finite number"),
            EmitError::BadStack => write!(f, "a stack has fewer than two members, or shows one it does not have"),
        }
    }
}

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

/// The bytes of `snapshot` as a format 3 file -- `emit` in `Project.zig`,
/// which says why this is written out by hand and not handed to a JSON
/// library.
pub fn emit(snapshot: &Snapshot) -> Result<String, EmitError> {
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
            if let Some(title) = tab.title.as_deref() {
                field(&mut out, "title", title);
            }
            out.push('}');
        }
        out.push_str("]}");
    }
    out.push_str("]}");
    Ok(out)
}

fn node(out: &mut String, n: &SavedNode) -> Result<(), EmitError> {
    match n {
        SavedNode::Leaf(leaf) => leaf_out(out, leaf),
        SavedNode::Stack { shown, members } => {
            if members.len() < 2 || *shown >= members.len() {
                return Err(EmitError::BadStack);
            }
            out.push_str(&format!("{{\"kind\":\"stack\",\"shown\":{shown},\"members\":["));
            for (i, member) in members.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                leaf_out(out, member);
            }
            out.push_str("]}");
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

fn leaf_out(out: &mut String, leaf: &SavedLeaf) {
    out.push_str("{\"kind\":\"leaf\"");
    field(out, "cwd", &leaf.cwd);
    field(out, "title", &leaf.title);
    // A chosen name with no name is not a thing (`Project.zig`): an empty
    // name is the person giving the program its title back.
    if leaf.title_chosen && !leaf.title.is_empty() {
        out.push_str(",\"title_chosen\":true");
    }
    field(out, "history", &leaf.history);
    field(out, "scrollback", &leaf.scrollback);
    if leaf.by_supervisor {
        out.push_str(",\"by_supervisor\":true");
    }
    // Each only when it is not the default, in this order (`Project.zig`).
    if leaf.supervisor_seat == Some(true) {
        out.push_str(",\"supervisor_seat\":true");
    }
    if let Some(c) = leaf.color.filter(|c| *c != PaneColor::None) {
        field(out, "color", c.name());
    }
    if leaf.workers == Some(Workers::Refused) {
        out.push_str(",\"workers\":\"refused\"");
    }
    if leaf.shielded == Some(true) {
        out.push_str(",\"shielded\":true");
    }
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
fn number(out: &mut String, value: f64) -> Result<(), EmitError> {
    if !value.is_finite() {
        return Err(EmitError::NotFinite);
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
    seats: usize,
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
            Some(r) => vec![Window { frame: None, front: 0, tabs: vec![Tab::unnamed(json_to_node(r, format, &mut fixups)?)] }],
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
    // Two seats are none, as two supervisors are: which of them is the
    // project's is not something a read can decide.
    if fixups.seats > 1 {
        for window in &mut windows {
            for tab in &mut window.tabs {
                for leaf in leaves_mut(&mut tab.root) {
                    leaf.supervisor_seat = Some(false);
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
            let tab = tab.as_object().ok_or(ReadError::Corrupt)?;
            let root = tab.get("root").ok_or(ReadError::Corrupt)?;
            let root = json_to_node(root, format, fixups)?;
            // New with format 3: absent is none; an empty name is never
            // written, so one read is a damaged file, as is a name that is
            // not text. Before format 3 the key meant nothing.
            let title = match tab.get("title") {
                _ if format < 3 => None,
                None => None,
                Some(serde_json::Value::String(t)) if !t.is_empty() => Some(t.clone()),
                Some(_) => return Err(ReadError::Corrupt),
            };
            tabs.push(Tab { root, title });
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
        "leaf" => Ok(SavedNode::Leaf(json_to_leaf(obj, format, fixups)?)),
        // Format 1 has no such node. And nothing about a stack is put right
        // (`Project.zig`'s module comment says why): fewer than two members,
        // a member that is not a pane, or a `shown` that is none of them is
        // a damaged file.
        "stack" if format != 1 => {
            let items = obj.get("members").and_then(|m| m.as_array()).ok_or(ReadError::Corrupt)?;
            if items.len() < 2 {
                return Err(ReadError::Corrupt);
            }
            let mut members = Vec::with_capacity(items.len());
            for item in items {
                let member = item.as_object().ok_or(ReadError::Corrupt)?;
                if member.get("kind").and_then(|k| k.as_str()) != Some("leaf") {
                    return Err(ReadError::Corrupt);
                }
                members.push(json_to_leaf(member, format, fixups)?);
            }
            let shown = obj.get("shown").filter(|n| n.is_u64()).and_then(|n| n.as_u64()).ok_or(ReadError::Corrupt)? as usize;
            if shown >= members.len() {
                return Err(ReadError::Corrupt);
            }
            Ok(SavedNode::Stack { shown, members })
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

/// One pane, out of an object already known to be of kind `leaf`.
fn json_to_leaf(obj: &Object, format: i64, fixups: &mut Fixups) -> Result<SavedLeaf, ReadError> {
    // A name that is not one this format writes is dropped, not refused:
    // the pane still opens, just without its scrollback, which is exactly
    // what a missing snapshot gives. Refusing would cost the whole project
    // for one field. A name an earlier pane already has is dropped for the
    // same reason.
    let scrollback = Some(opt_str(obj.get("scrollback")))
        .filter(|s| is_scrollback_name(s))
        .filter(|s| fixups.scrollback.insert(s.clone()))
        .unwrap_or_default();
    // A format 1 file never said, whatever keys it has.
    let agent = if format == 1 { Agent::Unknown } else { json_to_agent(obj.get("agent").ok_or(ReadError::Corrupt)?)? };
    if matches!(&agent, Agent::Agent(who) if who.supervisor) {
        fixups.supervisors += 1;
    }
    // New with format 2 and strict as the agent is: absent is false,
    // anything but a boolean is a damaged file.
    let by_supervisor = match obj.get("by_supervisor") {
        _ if format == 1 => false,
        None => false,
        Some(serde_json::Value::Bool(b)) => *b,
        Some(_) => return Err(ReadError::Corrupt),
    };
    // New with format 3, and stricter still: each is written only when it
    // is not the default, so the one value a file may hold is that value.
    // Anything else is a damaged file, never quietly the default. Before
    // format 3 the keys meant nothing and are not read; the seat was the
    // agent's being the supervisor.
    let title = opt_str(obj.get("title"));
    let (title_chosen, supervisor_seat, color, workers, shielded) = if format < 3 {
        (false, matches!(&agent, Agent::Agent(who) if who.supervisor), PaneColor::None, Workers::Allowed, false)
    } else {
        let only_true = |key: &str| match obj.get(key) {
            None => Ok(false),
            Some(serde_json::Value::Bool(true)) => Ok(true),
            Some(_) => Err(ReadError::Corrupt),
        };
        let color = match obj.get("color") {
            None => PaneColor::None,
            Some(serde_json::Value::String(s)) => PaneColor::from_name(s).ok_or(ReadError::Corrupt)?,
            Some(_) => return Err(ReadError::Corrupt),
        };
        let workers = match obj.get("workers") {
            None => Workers::Allowed,
            Some(serde_json::Value::String(s)) if s == "refused" => Workers::Refused,
            Some(_) => return Err(ReadError::Corrupt),
        };
        // Chosen, and nothing chosen: written by no build.
        let title_chosen = only_true("title_chosen")?;
        if title_chosen && title.is_empty() {
            return Err(ReadError::Corrupt);
        }
        (title_chosen, only_true("supervisor_seat")?, color, workers, only_true("shielded")?)
    };
    if supervisor_seat {
        fixups.seats += 1;
    }
    Ok(SavedLeaf {
        cwd: opt_str(obj.get("cwd")),
        title,
        title_chosen,
        history: opt_str(obj.get("history")),
        scrollback,
        by_supervisor,
        supervisor_seat: Some(supervisor_seat),
        color: Some(color),
        workers: Some(workers),
        shielded: Some(shielded),
        agent,
    })
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
        // A stack is one pane to the layout: which terminals are in it,
        // and which is in front, changes as often as a title does.
        SavedNode::Leaf(_) | SavedNode::Stack { .. } => Shape::Pane,
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
