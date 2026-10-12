//! The list of groups, as the panel draws it: a copy of the snapshot's rows
//! in two sections, and what each row says.
//!
//! **Nothing is worked out here.** The rows keep the snapshot's order, each
//! goes in the section its own `needs_me` says, and the two counts in the
//! headers are the snapshot's -- fields, not lengths. The macOS host's
//! `ControlRoomList.swift` is the same thing, and
//! `tools/control-room-hosts-agree.py` holds the two to one answer.

use crate::snapshot::{Cut, Form, Header, HeaderNumber, HeaderOf, Shown, Snapshot, SupervisorRole, SupervisorStart, Waiter, WaiterIs, What};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// The group's name, which is its identity.
    pub id: String,
    pub shown: Shown,
    /// The words beside the glyph: which one of the four it is.
    pub word: String,
    /// Who is waiting: the supervisor itself or which worker. The core's.
    pub waiter: Waiter,
    /// What it is waiting on, whole, already cut into the lines to set.
    pub what: What,
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
    /// Whether this group has a supervisor and what starting one would
    /// use, as the core says it.
    pub start: Option<SupervisorStart>,
    /// Set on a row that is a terminal on its own, in no group (the
    /// snapshot's `ungrouped`): which terminal, its title, and its frame.
    pub alone: Option<Alone>,
}

/// A terminal that is in no group and has a row of its own: a supervisor
/// that has made no group yet, a worker minded outside any group, an agent
/// nobody minds. The core lists them; which they are is not asked here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alone {
    pub terminal: String,
    pub title: String,
    /// Which frame its own pane wears, as the core says it for that
    /// terminal; plain when the core does not list it.
    pub pane: crate::snapshot::Pane,
}

impl Row {
    /// What the row is called: the group's name, or the terminal's title.
    pub fn name(&self) -> &str {
        match &self.alone {
            Some(alone) => &alone.title,
            None => &self.id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct List {
    pub now_ms: u64,
    /// How many are waiting, by the core's count: the first heading's
    /// when the core wrote one, otherwise the groups'.
    pub waiting_count: u64,
    pub waiting: Vec<Row>,
    /// How many need nothing. Also the core's.
    pub quiet_count: u64,
    pub quiet: Vec<Row>,
    /// The two headings as the core writes them; none from a core that
    /// does not, and the headings are then the groups' counts.
    pub waiting_header: Option<Header>,
    pub quiet_header: Option<Header>,
    /// The roles a supervisor can be started in, in the core's order.
    pub supervisor_roles: Vec<SupervisorRole>,
    /// Whether there is a choice of role to offer. The core's word.
    pub choose_supervisor_role: bool,
}

/// The English of what this crate says; a host passes each through its
/// translation and then `fill`s it. `{}` is where the one argument goes.
pub mod msg {
    use crate::n_;

    // The list's two headings. The sentences are the macOS host's, word
    // for word (`ControlRoomList.headerText`, `quietHeaderText`).
    pub const NONE_WAITING_HEADER: &str = n_("No group is waiting for you");
    pub const ONE_GROUP_WAITING_HEADER: &str = n_("{} group waiting for you");
    pub const WAITING_HEADER: &str = n_("{} groups waiting for you");
    /// Some of those waiting are terminals in no group, so it does not say
    /// "group".
    pub const ROWS_WAITING_HEADER: &str = n_("{} waiting for you");
    pub const ONE_GROUP_QUIET_HEADER: &str = n_("{} group needs nothing from you");
    pub const QUIET_HEADER: &str = n_("{} groups need nothing from you");
    pub const ONE_ROW_QUIET_HEADER: &str = n_("{} needs nothing from you");
    pub const ROWS_QUIET_HEADER: &str = n_("{} need nothing from you");

    pub const OTHERS: &str = n_("{} more");
    /// Who is waiting, when it is the group's supervisor itself.
    pub const SUPERVISOR: &str = n_("Supervisor");
    /// Who is waiting, when it is a worker reached through the supervisor.
    /// `{}` is the worker.
    pub const VIA_SUPERVISOR: &str = n_("{}, via the supervisor");
}

/// Put the argument where the translated sentence wants it.
pub fn fill(template: &str, arg: &str) -> String {
    template.replacen("{}", arg, 1)
}

/// The first heading as the core says it, untranslated, with the argument
/// `fill` puts in: so many waiting, called groups only when every one of
/// them is a group, and "1 group" where the core says the number is one.
/// The number handed in is the number written; the form is `number`'s.
pub fn waiting_heading(h: &Header) -> (&'static str, String) {
    let template = match (h.number, h.of) {
        (HeaderNumber::None, _) => msg::NONE_WAITING_HEADER,
        (HeaderNumber::One, HeaderOf::Groups) => msg::ONE_GROUP_WAITING_HEADER,
        (HeaderNumber::Other, HeaderOf::Groups) => msg::WAITING_HEADER,
        (HeaderNumber::One | HeaderNumber::Other, HeaderOf::Rows) => msg::ROWS_WAITING_HEADER,
    };
    (template, h.count.to_string())
}

/// The second heading, by the same rule.
pub fn quiet_heading(h: &Header) -> (&'static str, String) {
    let template = match (h.number, h.of) {
        (HeaderNumber::One, HeaderOf::Groups) => msg::ONE_GROUP_QUIET_HEADER,
        (HeaderNumber::None | HeaderNumber::Other, HeaderOf::Groups) => msg::QUIET_HEADER,
        (HeaderNumber::One, HeaderOf::Rows) => msg::ONE_ROW_QUIET_HEADER,
        (HeaderNumber::None | HeaderNumber::Other, HeaderOf::Rows) => msg::ROWS_QUIET_HEADER,
    };
    (template, h.count.to_string())
}

impl List {
    /// The first heading of this list: the core's when it gave one,
    /// otherwise the count of groups, written as it always was.
    pub fn waiting_heading(&self) -> (&'static str, String) {
        match &self.waiting_header {
            Some(h) => waiting_heading(h),
            None if self.waiting_count == 0 => (msg::NONE_WAITING_HEADER, String::new()),
            None => (msg::WAITING_HEADER, self.waiting_count.to_string()),
        }
    }

    pub fn quiet_heading(&self) -> (&'static str, String) {
        match &self.quiet_header {
            Some(h) => quiet_heading(h),
            None => (msg::QUIET_HEADER, self.quiet_count.to_string()),
        }
    }

    pub fn from_snapshot(s: &Snapshot) -> List {
        let mut waiting = Vec::new();
        let mut quiet = Vec::new();
        for g in &s.groups {
            let row = Row {
                id: g.name.clone(),
                shown: g.shown,
                word: g.text.clone(),
                waiter: g.waiter.clone(),
                what: g.what.clone(),
                others: g.more,
                unseen: g.unseen,
                steward: g.steward.clone(),
                terminal: g.terminal.clone(),
                since_ms: g.since_ms,
                event_ms: g.event_ms,
                start: g.supervisor.clone(),
                alone: None,
            };
            if g.needs_me {
                waiting.push(row);
            } else {
                quiet.push(row);
            }
        }
        // A terminal on its own, after the groups, in the section its own
        // `needs_me` says -- the same test a group's row is put by.
        for one in &s.ungrouped {
            let pane = s.terminals.iter().find(|t| t.id == one.id).and_then(|t| t.pane).unwrap_or(crate::snapshot::Pane::Plain);
            let row = Row {
                id: one.row_id(),
                shown: one.shown,
                word: one.text.clone(),
                waiter: one.waiter.clone(),
                what: one.what.clone(),
                others: 0,
                unseen: one.unseen,
                // What the right-hand side shows for this row is the
                // terminal itself: it is its own "supervisor" there.
                steward: Some(one.id.clone()),
                terminal: one.terminal.clone(),
                since_ms: one.since_ms,
                event_ms: one.event_ms,
                start: None,
                alone: Some(Alone { terminal: one.id.clone(), title: one.title.clone(), pane }),
            };
            if one.needs_me {
                waiting.push(row);
            } else {
                quiet.push(row);
            }
        }
        List {
            now_ms: s.now_ms,
            waiting_count: s.header_waiting.map_or(s.groups_needing_me, |h| h.count),
            waiting,
            quiet_count: s.header_quiet.map_or(s.groups_other, |h| h.count),
            quiet,
            waiting_header: s.header_waiting,
            quiet_header: s.header_quiet,
            supervisor_roles: s.supervisor_roles.clone(),
            choose_supervisor_role: s.choose_supervisor_role,
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

/// Whether what is waited on is set in the terminal's face. The core's
/// `form` says; nothing is guessed from where the words came from.
pub fn is_code(what: &What) -> bool {
    matches!(what.form, Form::Command | Form::Code)
}

/// Who is waiting, as the words a row shows at its right: untranslated, with
/// the argument `fill` puts in. None when there is nothing to say -- a row
/// that is about no terminal, or a terminal in no group, which is its own
/// name already.
pub fn waiter(w: &Waiter) -> Option<(&'static str, String)> {
    match w.is {
        WaiterIs::Supervisor => Some((msg::SUPERVISOR, String::new())),
        WaiterIs::WorkerViaSupervisor => Some((msg::VIA_SUPERVISOR, w.name.clone())),
        WaiterIs::Worker => Some(("{}", w.name.clone())),
        WaiterIs::None | WaiterIs::Terminal => None,
    }
}

/// The mark that stands where the rest would be.
pub const ELLIPSIS: &str = "…";

/// The lines as a row sets them: the core's, with the mark before the first
/// when what came before is missing and after the last when what came after
/// is. Everything that draws, measures or reads out a row uses these, so a
/// part is marked wherever it appears. The macOS host's `What.drawn`.
pub fn drawn(what: &What) -> Vec<String> {
    let mut out = what.lines.clone();
    match what.cut {
        Cut::None => {}
        Cut::Head => {
            if let Some(first) = out.first_mut() {
                *first = format!("{ELLIPSIS} {first}");
            }
        }
        Cut::Tail => {
            if let Some(last) = out.last_mut() {
                last.push(' ');
                last.push_str(ELLIPSIS);
            }
        }
    }
    out
}

/// What the pointer shows for a row whose lines may be cut short: all the
/// row was given, a step to a line. None when there is nothing to show.
pub fn tooltip(row: &Row) -> Option<String> {
    (!row.what.lines.is_empty()).then(|| drawn(&row.what).join("\n"))
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

/// What is selected once a snapshot has arrived, and whether it is the
/// person's own choice. `current` is what is selected already (after
/// `restored_selection`), `opening` is true for the first snapshot a control
/// room sees since it was opened, `open_on` is the group the core says to
/// start on.
///
/// A selection that stands is never replaced. With none, a control room
/// that has just opened starts on the core's group, and that is nobody's
/// choice: it does not count towards "seen" until the person selects the
/// row themselves. Later, with nothing selected, nothing is selected for
/// them. The macOS host's `ControlRoomRules.selection` is the same rule.
pub fn opening_selection<'a>(
    current: Option<&'a str>,
    opening: bool,
    open_on: Option<&'a str>,
) -> (Option<&'a str>, bool) {
    if current.is_some() {
        return (current, true);
    }
    match (opening, open_on) {
        (true, Some(group)) => (Some(group), false),
        _ => (None, true),
    }
}

/// Which group is selected, and whether the person chose it: the whole life
/// of a control room's selection, so that a host holds one of these and
/// decides nothing.
///
/// It is made when the control room opens, told about every snapshot, and
/// told when the person selects a row. A selection the core made for them
/// (`open_on`) is drawn like any other and is **not a look**: it does not
/// start the wait that marks a group seen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    current: Option<String>,
    persons: bool,
    /// No snapshot has been seen since this was opened.
    opening: bool,
}

impl Selection {
    /// A control room that has just opened. `kept` is what was selected the
    /// last time one was open, if anything: that was the person's choice
    /// and still is.
    pub fn opened(kept: Option<String>) -> Selection {
        Selection { persons: kept.is_some(), current: kept, opening: true }
    }

    /// A snapshot has arrived. A selection whose group is no longer listed
    /// is dropped; then, for the first snapshot since opening and only with
    /// nothing selected, the core's `open_on` is taken.
    pub fn snapshot(&mut self, list: &List, open_on: Option<&str>) {
        let kept = restored_selection(list, self.current.as_deref()).map(str::to_string);
        if kept.is_none() {
            // Whatever is selected next, the person has not chosen it yet.
            self.persons = false;
        }
        let (now, persons) = opening_selection(kept.as_deref(), self.opening, open_on);
        // The core names a group it lists; one it does not list is not
        // selected, rather than left pointing at nothing.
        let now = restored_selection(list, now).map(str::to_string);
        self.persons = now.is_some() && persons && (kept.is_none() || self.persons);
        self.current = now;
        self.opening = false;
    }

    /// The person selected a row (a click, an arrow key), or cleared it.
    pub fn choose(&mut self, id: Option<String>) {
        self.persons = id.is_some();
        self.current = id;
    }

    pub fn current(&self) -> Option<&str> {
        self.current.as_deref()
    }

    /// Whether having this selected is the person looking at it.
    pub fn is_a_look(&self) -> bool {
        self.current.is_some() && self.persons
    }
}

/// The selection to start with after a restart: the one that was kept, if
/// that group is still listed. A group that went away overnight must not
/// leave a selection pointing at nothing.
pub fn restored_selection<'a>(list: &List, kept: Option<&'a str>) -> Option<&'a str> {
    kept.filter(|k| list.row(k).is_some())
}
