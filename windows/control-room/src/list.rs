//! The list of groups, as the panel draws it: a copy of the snapshot's rows
//! in two sections, and what each row says.
//!
//! **Nothing is worked out here.** The rows keep the snapshot's order, each
//! goes in the section its own `needs_me` says, and the two counts in the
//! headers are the snapshot's -- fields, not lengths. The macOS host's
//! `ControlRoomList.swift` is the same thing, and
//! `tools/control-room-hosts-agree.py` holds the two to one answer.

use crate::snapshot::{Band, Shown, Snapshot};

/// What a row's second line says after the status word.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Detail {
    /// What it is waiting on, in the agent's or the core's words. May be
    /// empty.
    Reason(String),
    /// One supervisor minds several groups and waits once: this row points
    /// at the one that carries the reason.
    SameAs(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// The group's name, which is its identity.
    pub id: String,
    pub shown: Shown,
    /// The words beside the glyph: which one of the four it is.
    pub word: String,
    pub detail: Detail,
    /// The detail is a command or a path, set in the terminal's face.
    pub detail_is_code: bool,
    /// Whole minutes it has waited, as the core counted them.
    pub waited_min: Option<u64>,
    /// How many other terminals of this group are also waiting.
    pub others: u64,
    /// The core says nobody has looked at this since it stopped.
    pub unseen: bool,
    /// The group's supervisor, as the core names that terminal.
    pub steward: Option<String>,
    /// What an act on this row sends home (`act`).
    pub terminal: Option<String>,
    pub since_ms: u64,
    pub event_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct List {
    pub now_ms: u64,
    /// "N groups are waiting for you". The core's number.
    pub waiting_count: u64,
    pub waiting: Vec<Row>,
    /// "N groups need nothing from you". Also the core's.
    pub quiet_count: u64,
    pub quiet: Vec<Row>,
    pub band: Band,
}

/// The English of what this crate says; a host passes each through its
/// translation and then `fill`s it. `{}` is where the one argument goes.
pub mod msg {
    pub const OTHERS: &str = "{} more";
    pub const SAME_SUPERVISOR: &str = "Same supervisor: see {}";
}

/// Put the argument where the translated sentence wants it.
pub fn fill(template: &str, arg: &str) -> String {
    template.replacen("{}", arg, 1)
}

impl List {
    pub fn from_snapshot(s: &Snapshot) -> List {
        let mut waiting = Vec::new();
        let mut quiet = Vec::new();
        for g in &s.groups {
            let row = Row {
                id: g.name.clone(),
                shown: g.shown,
                word: g.text.clone(),
                detail: match &g.same_as {
                    Some(other) => Detail::SameAs(other.clone()),
                    None => Detail::Reason(g.reason.text.clone()),
                },
                // A hook's note is a tool and what it was given.
                detail_is_code: g.same_as.is_none() && g.reason.from == "hook_note",
                waited_min: g.waited_min,
                others: g.more,
                unseen: g.unseen,
                steward: g.steward.clone(),
                terminal: g.terminal.clone(),
                since_ms: g.since_ms,
                event_ms: g.event_ms,
            };
            if g.needs_me {
                waiting.push(row);
            } else {
                quiet.push(row);
            }
        }
        List {
            now_ms: s.now_ms,
            waiting_count: s.groups_needing_me,
            waiting,
            quiet_count: s.groups_other,
            quiet,
            band: s.band.clone(),
        }
    }

    /// Every row in the order it is listed, which is the order the up and
    /// down keys walk.
    pub fn rows(&self) -> impl Iterator<Item = &Row> {
        self.waiting.iter().chain(self.quiet.iter())
    }

    pub fn row(&self, id: &str) -> Option<&Row> {
        self.rows().find(|r| r.id == id)
    }
}

/// The "N more" at the end of a waiting row, untranslated; none when there
/// are none.
pub fn others(n: u64) -> Option<(&'static str, String)> {
    (n > 0).then(|| (msg::OTHERS, n.to_string()))
}

/// What the pointer shows for a row whose detail may be cut short: the
/// whole of it. None when there is nothing that could have been cut.
pub fn tooltip(row: &Row) -> Option<&str> {
    match &row.detail {
        Detail::Reason(text) if !text.is_empty() => Some(text),
        _ => None,
    }
}

/// The row the selection lands on after an arrow key. It stops at the ends,
/// and with nothing selected a step lands on the first row going down and
/// the last going up.
pub fn move_selection<'a>(list: &'a List, selection: Option<&str>, step: i64) -> Option<&'a str> {
    let ids: Vec<&str> = list.rows().map(|r| r.id.as_str()).collect();
    let last = ids.last().copied()?;
    let at = selection.and_then(|s| ids.iter().position(|id| *id == s));
    let Some(at) = at else {
        return Some(if step >= 0 { ids[0] } else { last });
    };
    let to = (at as i64 + step).clamp(0, ids.len() as i64 - 1) as usize;
    Some(ids[to])
}

/// The selection to start with after a restart: the one that was kept, if
/// that group is still listed. A group that went away overnight must not
/// leave a selection pointing at nothing.
pub fn restored_selection<'a>(list: &List, kept: Option<&'a str>) -> Option<&'a str> {
    kept.filter(|k| list.row(k).is_some())
}
