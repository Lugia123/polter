//! What the host tells the core about projects: one statement, all of it,
//! every time (`dev-docs/poltergeist/projects.md` §3).
//!
//! The core takes a statement whole or not at all -- half of one would make
//! the projects in the other half look deleted, and their groups would be
//! untied. So what it refuses is checked here first (`refusal`): a host that
//! is about to say something the core will not take finds out from its own
//! log, with the reason, instead of from a group that was never tied.

use std::collections::BTreeMap;

use polter_projectfile::{leaves, Agent, Snapshot};

use crate::pages::{PageId, Pages};

/// One project, as it is said. **Every field is said every time**: none has
/// a default, here or on the wire.
#[derive(Clone, Debug, PartialEq)]
pub struct Stated {
    pub name: String,
    /// The group its file names; none when it names none.
    pub group: Option<String>,
    /// How many pages it has, open or not.
    pub pages: usize,
    /// The terminals on each page that is open, a list a page; `None` when
    /// no page of it is open. Never `Some` of nothing.
    pub open: Option<Vec<Vec<String>>>,
    /// The terminal now in the pane its file marks as the supervisor's.
    pub supervisor: Option<String>,
    /// The terminals now in the panes its file marks as opened by its
    /// supervisor.
    pub workers: Vec<String>,
}

impl Stated {
    /// A project none of whose pages is open: what its file says.
    pub fn of_closed(file: &Snapshot) -> Stated {
        Stated { name: file.name.clone(), group: file.group.clone(), pages: file.tabs().count(), open: None, supervisor: None, workers: Vec::new() }
    }

    /// A project with pages open. `open` is each open page and the
    /// terminals in its panes, **in the order of the page's leaves** -- which
    /// is what a save has just written, so the pane the file marks is found
    /// by counting.
    ///
    /// A page whose terminals are not as many as its leaves has changed
    /// since it was written: its terminals are still said (they are on the
    /// page), and no supervisor is read off it -- the count would point at
    /// the wrong pane.
    pub fn of_open(name: &str, group: Option<String>, pages: &Pages, open: &[(PageId, Vec<String>)]) -> Stated {
        let mut on_pages: Vec<Vec<String>> = Vec::new();
        let mut supervisor = None;
        // In the project's order, not the order the tabs were opened in.
        for id in pages.page_ids() {
            let Some((_, terminals)) = open.iter().find(|(page, _)| *page == id) else { continue };
            let Some(page) = pages.page(id) else { continue };
            on_pages.push(terminals.clone());
            let panes = leaves(&page.tab.root);
            if panes.len() != terminals.len() {
                continue;
            }
            for (leaf, terminal) in panes.iter().zip(terminals) {
                if matches!(&leaf.agent, Agent::Agent(who) if who.supervisor) && supervisor.is_none() {
                    supervisor = Some(terminal.clone());
                }
            }
        }
        Stated {
            name: name.to_string(),
            group,
            pages: pages.page_ids().len(),
            open: if on_pages.is_empty() { None } else { Some(on_pages) },
            supervisor,
            // The file has no mark for these yet (`by_supervisor`, #1491):
            // until it does, none is what the contract says to send.
            workers: Vec::new(),
        }
    }
}

/// Why the core would refuse a statement. Its own words for the same four
/// things are one `BadRequest`; these say which.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Two projects are called this.
    SameName(String),
    /// This terminal is on a page of both of these projects.
    OnTwoProjects(String, String, String),
    /// This project's supervisor is on none of its pages.
    SupervisorOffPage(String),
    /// This worker of this project is on none of its pages.
    WorkerOffPage(String, String),
    /// This project is open with no page.
    OpenWithNothing(String),
}

/// The first thing in `list` the core would refuse, if anything.
pub fn refusal(list: &[Stated]) -> Option<Refusal> {
    let mut names: Vec<&str> = Vec::new();
    let mut owner: BTreeMap<&str, &str> = BTreeMap::new();
    for p in list {
        if names.contains(&p.name.as_str()) {
            return Some(Refusal::SameName(p.name.clone()));
        }
        names.push(&p.name);
        let Some(open) = &p.open else {
            if p.supervisor.is_some() {
                return Some(Refusal::SupervisorOffPage(p.name.clone()));
            }
            if let Some(w) = p.workers.first() {
                return Some(Refusal::WorkerOffPage(p.name.clone(), w.clone()));
            }
            continue;
        };
        if open.is_empty() {
            return Some(Refusal::OpenWithNothing(p.name.clone()));
        }
        for terminal in open.iter().flatten() {
            if let Some(other) = owner.insert(terminal, &p.name) {
                if other != p.name {
                    return Some(Refusal::OnTwoProjects(terminal.clone(), other.to_string(), p.name.clone()));
                }
            }
        }
        let here = |t: &String| open.iter().flatten().any(|o| o == t);
        if p.supervisor.as_ref().is_some_and(|s| !here(s)) {
            return Some(Refusal::SupervisorOffPage(p.name.clone()));
        }
        if let Some(w) = p.workers.iter().find(|w| !here(w)) {
            return Some(Refusal::WorkerOffPage(p.name.clone(), w.clone()));
        }
    }
    None
}

fn quoted(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

fn list_of(items: &[String]) -> String {
    format!("[{}]", items.iter().map(|t| quoted(t)).collect::<Vec<_>>().join(","))
}

/// The statement, as the bytes handed to `ghostty_app_control_act`. Six keys
/// a project, each written whether or not it has anything to say.
pub fn statement(list: &[Stated]) -> String {
    let each: Vec<String> = list
        .iter()
        .map(|p| {
            format!(
                "{{\"name\":{},\"group\":{},\"pages\":{},\"open\":{},\"supervisor\":{},\"workers\":{}}}",
                quoted(&p.name),
                p.group.as_deref().map_or("null".to_string(), quoted),
                p.pages,
                p.open.as_ref().map_or("null".to_string(), |pages| format!("[{}]", pages.iter().map(|t| list_of(t)).collect::<Vec<_>>().join(","))),
                p.supervisor.as_deref().map_or("null".to_string(), quoted),
                list_of(&p.workers),
            )
        })
        .collect();
    format!("{{\"act\":\"projects\",\"list\":[{}]}}", each.join(","))
}

/// The three other things a host says (§3). Each is asked or told on its
/// own, and the core's answer to the two questions is a refusal by name.
pub fn failed(name: &str, why: FailedWhy) -> String {
    let why = match why {
        FailedWhy::NotFound => "not_found",
        FailedWhy::Unreadable => "unreadable",
    };
    format!("{{\"act\":\"project_failed\",\"name\":{},\"why\":\"{why}\"}}", quoted(name))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailedWhy {
    NotFound,
    Unreadable,
}

/// Asked before a page is taken out of its project; `terminal` is any
/// terminal on the page.
pub fn remove_question(terminal: &str) -> String {
    format!("{{\"act\":\"project_remove\",\"terminal\":{}}}", quoted(terminal))
}

/// Asked before a project is renamed.
pub fn rename_question(from: &str, to: &str) -> String {
    format!("{{\"act\":\"project_rename\",\"from\":{},\"to\":{}}}", quoted(from), quoted(to))
}
