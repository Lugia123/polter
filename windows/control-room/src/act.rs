//! What the person does in the control room, as the request the core takes
//! (`src/poltergeist/ControlAct.zig`), and what a refusal says.
//!
//! The requests carry what the row was drawn from and nothing about who is
//! asking: calling `ghostty_app_control_act` is being the person.

use crate::json::quote;
use crate::n_;
use crate::list::Row;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Act<'a> {
    Seen { group: &'a str },
    /// Until its state next changes.
    Snooze { group: &'a str },
    /// Until a moment on the wall clock.
    SnoozeUntil { group: &'a str, until_ms: u64 },
    Unsnooze { group: &'a str },
    Approve { row: &'a Row },
    Refuse { row: &'a Row },
    Reply { row: &'a Row, text: &'a str },
    /// Make a group by the name that was typed.
    NewGroup { name: &'a str },
    /// Start a supervisor for a group that has none. No role or no
    /// directory is the one the core's snapshot names.
    StartSupervisor { group: &'a str, role: Option<&'a str>, cwd: Option<&'a str> },
}

/// The request for an act, or none when the row has nothing to send it
/// with -- no terminal behind it, or no moment to say which prompt was
/// seen. A button for that act should not be there to press.
pub fn encode(act: &Act) -> Option<String> {
    Some(match act {
        Act::Seen { group } => format!("{{\"act\":\"seen\",\"group\":{}}}", quote(group)),
        Act::Snooze { group } => format!("{{\"act\":\"snooze\",\"group\":{}}}", quote(group)),
        Act::SnoozeUntil { group, until_ms } => {
            format!("{{\"act\":\"snooze\",\"group\":{},\"until_ms\":{until_ms}}}", quote(group))
        }
        Act::Unsnooze { group } => format!("{{\"act\":\"unsnooze\",\"group\":{}}}", quote(group)),
        Act::Approve { row } => prompt("approve", row)?,
        Act::Refuse { row } => prompt("refuse", row)?,
        Act::Reply { row, text } => format!(
            "{{\"act\":\"reply\",\"terminal\":{},\"since_ms\":{},\"text\":{}}}",
            quote(row.terminal.as_deref()?),
            row.since_ms,
            quote(text)
        ),
        Act::NewGroup { name } => format!("{{\"act\":\"new_group\",\"name\":{}}}", quote(name)),
        Act::StartSupervisor { group, role, cwd } => {
            // Left out when the person picked neither: the core then uses
            // the ones its snapshot named.
            let mut out = format!("{{\"act\":\"start_supervisor\",\"group\":{}", quote(group));
            if let Some(role) = role {
                out.push_str(&format!(",\"role\":{}", quote(role)));
            }
            if let Some(cwd) = cwd {
                out.push_str(&format!(",\"cwd\":{}", quote(cwd)));
            }
            out.push('}');
            out
        }
    })
}

fn prompt(name: &str, row: &Row) -> Option<String> {
    Some(format!(
        "{{\"act\":\"{name}\",\"terminal\":{},\"since_ms\":{},\"event_ms\":{}}}",
        quote(row.terminal.as_deref()?),
        row.since_ms,
        row.event_ms?
    ))
}

/// Why the core did not do it, by the name it gives.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    BadRequest,
    NoSuchGroup,
    SnoozeInThePast,
    UnknownTerminal,
    PromptGone,
    NothingToReplyTo,
    Stale,
    EmptyText,
    UserPresent,
    DraftInLine,
    ChildExited,
    KeyFailed,
    /// A new group's name is not one a group can have (an empty one too).
    BadName,
    GroupExists,
    TooManyGroups,
    HasSupervisor,
    AlreadyStarting,
    NoSupervisorRole,
    NoSuchPersona,
    NotASupervisorRole,
    NoCli,
    /// The directory to start in is not there, or is not one.
    NoSuchDirectory,
    /// No tab could be opened for it.
    OpenFailed,
    NoExecutable,
    /// A name this build does not know. Shown as it came, never dropped.
    Other,
}

impl Refusal {
    pub fn parse(name: &str) -> Refusal {
        match name {
            "BadRequest" => Refusal::BadRequest,
            "NoSuchGroup" => Refusal::NoSuchGroup,
            "SnoozeInThePast" => Refusal::SnoozeInThePast,
            "UnknownTerminal" | "NoSuchTerminal" => Refusal::UnknownTerminal,
            "PromptGone" => Refusal::PromptGone,
            "NothingToReplyTo" => Refusal::NothingToReplyTo,
            "Stale" => Refusal::Stale,
            "EmptyText" => Refusal::EmptyText,
            "UserPresent" => Refusal::UserPresent,
            "DraftInLine" => Refusal::DraftInLine,
            "ChildExited" => Refusal::ChildExited,
            "KeyFailed" => Refusal::KeyFailed,
            "BadName" => Refusal::BadName,
            "GroupExists" => Refusal::GroupExists,
            "TooManyGroups" => Refusal::TooManyGroups,
            "HasSupervisor" => Refusal::HasSupervisor,
            "AlreadyStarting" => Refusal::AlreadyStarting,
            "NoSupervisorRole" => Refusal::NoSupervisorRole,
            "NoSuchPersona" => Refusal::NoSuchPersona,
            "NotASupervisorRole" => Refusal::NotASupervisorRole,
            "NoCli" => Refusal::NoCli,
            "NotAbsolute" | "NoSuchDirectory" | "NotADirectory" => Refusal::NoSuchDirectory,
            "OpenFailed" | "NoRuntime" => Refusal::OpenFailed,
            "NoExecutable" => Refusal::NoExecutable,
            _ => Refusal::Other,
        }
    }

    /// The English of what to tell the person; a host translates it. For
    /// `Other` it has a `{}` for the name the core gave.
    pub fn message(self) -> &'static str {
        match self {
            Refusal::BadRequest => "That could not be sent. This is a fault in Polter, not something you did.",
            Refusal::NoSuchGroup => "That group is no longer there.",
            Refusal::SnoozeInThePast => "That time has already passed.",
            Refusal::UnknownTerminal => "That terminal is no longer there.",
            Refusal::PromptGone => "The prompt has changed since this was drawn. Nothing was sent; look again.",
            Refusal::NothingToReplyTo => "It is not waiting to be told anything right now.",
            Refusal::Stale => "It has moved on since this was drawn. Nothing was sent; look again.",
            Refusal::EmptyText => "There is nothing to send.",
            Refusal::UserPresent => "Somebody typed in that terminal a moment ago. Nothing was sent; try again shortly.",
            Refusal::DraftInLine => "That terminal has unsent text in its input line. Nothing was sent; go to the terminal.",
            Refusal::ChildExited => "The program in that terminal has ended.",
            Refusal::KeyFailed => "The key did not reach the program. Go to the terminal.",
            // The sentences below are the macOS host's, word for word
            // (`ControlRoomActions.Refusal.message`).
            Refusal::BadName => n_("A group's name is lowercase letters, digits and dashes, 48 at most."),
            Refusal::GroupExists => n_("There is already a group by that name."),
            Refusal::TooManyGroups => n_("There is no room for another group."),
            Refusal::HasSupervisor => n_("This group already has a supervisor."),
            Refusal::AlreadyStarting => n_("A supervisor is already being started for this group."),
            Refusal::NoSupervisorRole => n_("There is no role that makes a supervisor. Add one in the role library."),
            Refusal::NoSuchPersona => n_("That role no longer exists."),
            Refusal::NotASupervisorRole => n_("That role does not make a supervisor."),
            Refusal::NoCli => n_("This role isn't set up for any agent CLI yet. Pick one in the role library."),
            Refusal::NoSuchDirectory => n_("That directory is not there."),
            Refusal::OpenFailed => n_("No tab could be opened for it."),
            Refusal::NoExecutable => n_("Polter could not find its own program to start the role with."),
            Refusal::Other => "It was not done ({}).",
        }
    }

    /// The row is out of date and a fresh snapshot will say what is there:
    /// worth redrawing at once rather than waiting to be told.
    pub fn means_look_again(self) -> bool {
        matches!(
            self,
            Refusal::PromptGone | Refusal::Stale | Refusal::NoSuchGroup | Refusal::UnknownTerminal | Refusal::NothingToReplyTo
        )
    }

    /// Going to the terminal itself is the way through.
    pub fn offers_the_terminal(self) -> bool {
        matches!(self, Refusal::DraftInLine | Refusal::UserPresent | Refusal::KeyFailed)
    }
}

/// Looking at a group marks it seen: a row the core says nobody has looked
/// at, left selected with the control room in front for
/// `look::selection::SEEN_AFTER` seconds.
///
/// This holds no clock. `selection_changed` hands back a `Dwell` when there
/// is something to wait for; the host waits and then asks `due`, which says
/// no if the selection has moved on meanwhile.
#[derive(Debug, Default)]
pub struct SeenMarker {
    /// Counts selections, so that a wait can tell whether it is still about
    /// the current one.
    generation: u64,
    selected: Option<String>,
    /// Whether the selected row was unseen the last time it was heard of.
    selected_unseen: bool,
}

/// One wait, for one selection of one group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dwell {
    generation: u64,
    pub group: String,
}

impl SeenMarker {
    /// The selection is now `row` (none for none). Call it on every change,
    /// and again when the control room comes to the front with a row
    /// already selected.
    pub fn selection_changed(&mut self, row: Option<&Row>) -> Option<Dwell> {
        self.generation += 1;
        self.selected = row.map(|r| r.id.clone());
        self.selected_unseen = row.is_some_and(|r| r.unseen);
        // Only a row the core says has not been looked at is worth saying
        // anything about.
        let row = row.filter(|r| r.unseen)?;
        Some(Dwell { generation: self.generation, group: row.id.clone() })
    }

    /// A new list has arrived; `row` is the selected row as it is now (none
    /// for none, and for a row the person did not select themselves).
    ///
    /// **A row that stops while the person is on it is seen like any
    /// other**: they selected it, the control room is in front, its
    /// supervisor's terminal is beside the list. The wait starts when the
    /// core first says "not looked at". A row that was already unseen is
    /// left alone, or every list would start the wait over and it would
    /// never end. The macOS host's `ControlRoomSeenTracker.listChanged`.
    pub fn list_changed(&mut self, row: Option<&Row>) -> Option<Dwell> {
        if row.map(|r| r.id.as_str()) != self.selected.as_deref() {
            return self.selection_changed(row);
        }
        let was = self.selected_unseen;
        self.selected_unseen = row.is_some_and(|r| r.unseen);
        let row = row.filter(|r| r.unseen && !was)?;
        self.generation += 1;
        Some(Dwell { generation: self.generation, group: row.id.clone() })
    }

    /// The wait is over: the act to send, or none when the selection moved
    /// or the control room is not what the person is looking at.
    pub fn due<'a>(&self, dwell: &'a Dwell, in_front: bool) -> Option<Act<'a>> {
        let still = self.generation == dwell.generation && self.selected.as_deref() == Some(dwell.group.as_str());
        (still && in_front).then_some(Act::Seen { group: &dwell.group })
    }
}
