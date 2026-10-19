//! What the core asks of the host about projects, and what the host makes
//! of it (`dev-docs/poltergeist/projects.md` §4).
//!
//! **An order is a statement of what should be so, not an event.** The core
//! works the list out again from scratch every time, so one stays until the
//! host's next statement shows it done -- and the host sees every one of
//! them once a snapshot until then. `step` is therefore asked of the same
//! order many times, and answers "nothing" once things already stand the
//! way it wants.

use std::collections::BTreeMap;

use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Open,
    Create,
    Bind,
    SetGroup,
    Rename,
    AddTab,
    /// Make the tab `terminal` is in a page of the project if it is not
    /// one, and mark its pane the supervisor's (task 1794).
    Seat,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Order {
    pub kind: Kind,
    pub project: String,
    pub group: Option<String>,
    pub to: Option<String>,
    pub terminal: Option<String>,
}

/// What starting a group's supervisor does, which is what the button says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Start {
    /// Its project opens, every page of it, and the supervisor is started
    /// in its own pane.
    Project,
    /// One tab opens in a directory.
    Directory,
}

/// A group's project, as the core has it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GroupProject {
    /// The project's name; none unless the group is tied to one.
    pub name: Option<String>,
    /// How many pages it has. **None is "not known", not zero.**
    pub pages: Option<u64>,
    /// Whether it is open; none likewise.
    pub open: Option<bool>,
    pub start: Start,
    /// The core's one word for why things stand as they do.
    pub why: String,
}

/// The part of a snapshot that is about projects.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Told {
    /// Whether the core has a statement from the host at all.
    pub known: bool,
    pub orders: Vec<Order>,
    /// By group name. A group the snapshot says nothing about a project
    /// for is not in here.
    pub groups: BTreeMap<String, GroupProject>,
}

fn text(v: &Value, key: &str, at: &str) -> Result<String, String> {
    v.get(key).and_then(Value::as_str).map(str::to_string).ok_or_else(|| format!("{at}.{key} is not a string"))
}

/// A key that must be there and is a string or null.
fn maybe_text(v: &Value, key: &str, at: &str) -> Result<Option<String>, String> {
    match v.get(key) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(format!("{at}.{key} is neither a string nor null")),
        None => Err(format!("{at}.{key} is missing")),
    }
}

/// Read it out of a snapshot. **Strict where it reads**: an order this
/// build does not know is an error, not something skipped -- skipping it
/// would leave the core waiting on a host that never says why. A snapshot
/// from before any of this (no `projects_known`) is "the host has said
/// nothing", which is what it was.
pub fn decode(snapshot: &str) -> Result<Told, String> {
    let root: Value = serde_json::from_str(snapshot).map_err(|e| e.to_string())?;
    let known = match root.get("projects_known") {
        None => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err("projects_known is not a boolean".to_string()),
    };
    let mut orders = Vec::new();
    match root.get("project_orders") {
        None => {}
        Some(Value::Array(list)) => {
            for (i, o) in list.iter().enumerate() {
                let at = format!("project_orders[{i}]");
                let kind = match text(o, "order", &at)?.as_str() {
                    "open" => Kind::Open,
                    "create" => Kind::Create,
                    "bind" => Kind::Bind,
                    "set_group" => Kind::SetGroup,
                    "rename" => Kind::Rename,
                    "add_tab" => Kind::AddTab,
                    "seat" => Kind::Seat,
                    other => return Err(format!("{at}.order is {other:?}, which this build does not know")),
                };
                orders.push(Order {
                    kind,
                    project: text(o, "project", &at)?,
                    group: maybe_text(o, "group", &at)?,
                    to: maybe_text(o, "to", &at)?,
                    terminal: maybe_text(o, "terminal", &at)?,
                });
            }
        }
        Some(_) => return Err("project_orders is not a list".to_string()),
    }
    let mut groups = BTreeMap::new();
    if let Some(Value::Array(list)) = root.get("groups") {
        for (i, g) in list.iter().enumerate() {
            let Some(p) = g.get("project") else { continue };
            let at = format!("groups[{i}].project");
            let name = text(g, "name", &format!("groups[{i}]"))?;
            let start = match text(p, "start", &at)?.as_str() {
                "project" => Start::Project,
                "directory" => Start::Directory,
                other => return Err(format!("{at}.start is {other:?}, which this build does not know")),
            };
            let pages = match p.get("pages") {
                Some(Value::Null) => None,
                Some(n) => Some(n.as_u64().ok_or_else(|| format!("{at}.pages is not a count"))?),
                None => return Err(format!("{at}.pages is missing")),
            };
            let open = match p.get("open") {
                Some(Value::Null) => None,
                Some(Value::Bool(b)) => Some(*b),
                _ => return Err(format!("{at}.open is neither a boolean nor null")),
            };
            groups.insert(name, GroupProject { name: maybe_text(p, "name", &at)?, pages, open, start, why: text(p, "why", &at)? });
        }
    }
    Ok(Told { known, orders, groups })
}

/// A project as the host has it, for deciding what an order still asks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Have {
    pub name: String,
    pub group: Option<String>,
    /// Every terminal on a page of it that is open; empty when none is.
    pub terminals: Vec<String>,
    pub open: bool,
    /// The terminal in the pane its file marks as the supervisor's, when
    /// it is open and marks one.
    pub supervisor: Option<String>,
}

/// What the host does about an order now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    /// Things already stand that way, or it cannot be done from here; the
    /// word is for the log.
    Nothing(&'static str),
    /// Open the project, then state.
    Open { project: String },
    /// Tell the core the project it asked to open is not there.
    Missing { project: String },
    /// A new project called `name`, of one page: the tab `terminal` is in.
    /// Its file names `group` and marks `terminal`'s pane the supervisor's.
    Create { name: String, group: Option<String>, terminal: String },
    /// The project `project` is the group's now: its file names `group`,
    /// `terminal`'s pane is the supervisor's, and it is renamed to `to`
    /// when that is another name.
    Bind { project: String, group: String, terminal: Option<String>, to: Option<String> },
    /// The file's group becomes this (none: it names none).
    SetGroup { project: String, group: Option<String> },
    Rename { from: String, to: String },
    /// The tab `terminal` is in becomes a page of `project`.
    AddTab { project: String, terminal: String },
    /// The tab `terminal` is in becomes a page of `project` when it is a
    /// page of none (`join_tab`), and its pane is marked the supervisor's.
    Seat { project: String, terminal: String, join_tab: bool },
}

/// What `order` still asks, given the projects the host has (`have`) and
/// whether a terminal is one it has open at all (`live`).
pub fn step(order: &Order, have: &[Have], live: &dyn Fn(&str) -> bool) -> Step {
    let project = have.iter().find(|p| p.name == order.project);
    let page_of = |terminal: &str| have.iter().find(|p| p.terminals.iter().any(|t| t == terminal));
    match order.kind {
        Kind::Open => match project {
            None => Step::Missing { project: order.project.clone() },
            Some(p) if p.open => Step::Nothing("it is open"),
            Some(_) => Step::Open { project: order.project.clone() },
        },
        Kind::Create => {
            let Some(terminal) = &order.terminal else { return Step::Nothing("no terminal was named") };
            if project.is_some() {
                return Step::Nothing("a project of that name exists");
            }
            if !live(terminal) {
                return Step::Nothing("that terminal is not open here");
            }
            if page_of(terminal).is_some() {
                return Step::Nothing("its tab is already a page of a project");
            }
            Step::Create { name: order.project.clone(), group: order.group.clone(), terminal: terminal.clone() }
        }
        Kind::Bind => {
            let Some(p) = project else { return Step::Nothing("no such project") };
            let Some(group) = &order.group else { return Step::Nothing("no group was named") };
            if p.group.as_ref() == Some(group) {
                return Step::Nothing("its file names that group already");
            }
            let to = order.to.clone().filter(|to| *to != p.name);
            if to.as_ref().is_some_and(|to| have.iter().any(|other| other.name == *to)) {
                return Step::Nothing("the name it would take is another project's");
            }
            Step::Bind { project: p.name.clone(), group: group.clone(), terminal: order.terminal.clone(), to }
        }
        Kind::SetGroup => match project {
            None => Step::Nothing("no such project"),
            Some(p) if p.group == order.group => Step::Nothing("its file says that already"),
            Some(p) => Step::SetGroup { project: p.name.clone(), group: order.group.clone() },
        },
        Kind::Rename => {
            let Some(to) = &order.to else { return Step::Nothing("no name was given") };
            if project.is_none() {
                return Step::Nothing("no such project");
            }
            if *to == order.project {
                return Step::Nothing("it is called that already");
            }
            if have.iter().any(|other| other.name == *to) {
                return Step::Nothing("that name is another project's");
            }
            Step::Rename { from: order.project.clone(), to: to.clone() }
        }
        Kind::AddTab => {
            let Some(terminal) = &order.terminal else { return Step::Nothing("no terminal was named") };
            if project.is_none() {
                return Step::Nothing("no such project");
            }
            if !live(terminal) {
                return Step::Nothing("that terminal is not open here");
            }
            if page_of(terminal).is_some() {
                return Step::Nothing("its tab is already a page of a project");
            }
            Step::AddTab { project: order.project.clone(), terminal: terminal.clone() }
        }
        Kind::Seat => {
            let Some(terminal) = &order.terminal else { return Step::Nothing("no terminal was named") };
            let Some(p) = project else { return Step::Nothing("no such project") };
            if !live(terminal) {
                return Step::Nothing("that terminal is not open here");
            }
            let join_tab = match page_of(terminal) {
                None => true,
                Some(q) if q.name == p.name => false,
                Some(_) => return Step::Nothing("its tab is another project's page"),
            };
            if !join_tab && p.supervisor.as_deref() == Some(terminal.as_str()) {
                return Step::Nothing("its pane is the marked one already");
            }
            Step::Seat { project: p.name.clone(), terminal: terminal.clone(), join_tab }
        }
    }
}
