//! What the person does in the control room, as the request the core takes
//! (`src/poltergeist/ControlAct.zig`), and what a refusal says.
//!
//! The requests carry what the row was drawn from and nothing about who is
//! asking: calling `ghostty_app_control_act` is being the person.

use crate::json::quote;
use crate::n_;
use crate::list::Row;
use crate::snapshot::Fix;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Act<'a> {
    Seen { group: &'a str },
    /// The same for a terminal that is in no group: it has no group to
    /// name, so it is named itself.
    SeenTerminal { terminal: &'a str },
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
    /// directory is the one the core's snapshot names. No session is the
    /// core's own choice (`session_sent`). No CLI is the one the core's
    /// snapshot names (`supervisor.cli`, #1677).
    StartSupervisor { group: &'a str, role: Option<&'a str>, cwd: Option<&'a str>, cli: Option<&'a str>, session: Option<Session> },
    /// The person said OK to the first sweep of old records (task 1511).
    RetentionAgree,
    /// "Fix" on a card that reads "Failed" (task 1560): the core tells the
    /// card's supervisor. Which card, as last drawn, is the core's to look
    /// up; the row's name is all it is told.
    Fix { group: &'a str },
    /// The same, on the row of a terminal that is in no group.
    FixTerminal { terminal: &'a str },
    // The menu on a group's row (task 1659's acts; the hosts' part is
    // tasks 1660 and 1661).
    Pin { group: &'a str },
    Unpin { group: &'a str },
    /// Notifications off until a moment on the wall clock; none: until
    /// they are turned on. "An hour" and "until tomorrow 9:00, local time"
    /// are the host's to work out (`mute_until`).
    Mute { group: &'a str, until_ms: Option<u64> },
    Unmute { group: &'a str },
    Archive { group: &'a str },
    Unarchive { group: &'a str },
    RenameGroup { from: &'a str, to: &'a str },
    // The person's word on a group's project (task 1714,
    // `project-link-interface.md` §1): the same as the supervisor's
    // `group_project`, said by the person, so no standing is asked.
    /// "This group has no project": its tie becomes `declined`.
    ProjectDecline { group: &'a str },
    /// "This group uses a project" again: `declined` becomes `undecided`.
    ProjectUndecline { group: &'a str },
    /// Use the project already there by that name.
    ProjectLink { group: &'a str, project: &'a str },
    /// "Not now" in the confirmation: not asked again this run.
    ProjectNotNow { group: &'a str },
    SetBrief { group: &'a str, brief: &'a str },
    /// The two numbers the dialog showed: the core does nothing if they
    /// are not what it would delete now (`Stale`).
    DeleteGroup { group: &'a str, members: u64, open_tasks: u64 },
    /// Type the core's fixed sentence into the group's supervisor.
    AskSupervisor { group: &'a str, ask: Ask },
    /// "Let the control room take over?" on a group's supervisor, once the
    /// person said yes to the core's question (task 1635): from the frame's
    /// title and from the row's menu alike.
    TakeOver { group: &'a str },
}

/// What the supervisor is asked from the row's menu.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ask {
    /// To say how the work is going.
    Report,
    /// To close the workers that have nothing to do.
    CloseIdle,
}

impl Ask {
    /// The core's word.
    pub fn name(self) -> &'static str {
        match self {
            Ask::Report => "report",
            Ask::CloseIdle => "close_idle",
        }
    }
}

/// What "Fix" on `row` is sent as; none when the row offers no button to
/// press -- none, or one already pressed. A lone terminal's row is fixed by
/// its terminal, as it is seen. The macOS host's `ControlRoomActions.fix`.
pub fn fix_act(row: &Row) -> Option<Act<'_>> {
    if row.fix != Fix::Offered {
        return None;
    }
    Some(match &row.alone {
        Some(alone) => Act::FixTerminal { terminal: &alone.terminal },
        None => Act::Fix { group: &row.id },
    })
}

/// Whether the reason the last "Fix" on `refused` was refused is still
/// said, now that the list is `rows`: only while that row still offers the
/// button, to be pressed again. The macOS host's `ControlRoomModel` does
/// the same when a list arrives.
pub fn fix_refusal_stands<'r>(refused: &str, mut rows: impl Iterator<Item = &'r Row>) -> bool {
    rows.any(|r| r.id == refused && r.fix == Fix::Offered)
}

/// Which session a start is asked for: the core's two words
/// (`ControlAct.zig`, `Session`). The macOS host's
/// `ControlRoomStartChoice.Session`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Session {
    /// Go on with the session the group's last supervisor was in.
    Last,
    New,
}

impl Session {
    pub const ALL: [Session; 2] = [Session::Last, Session::New];

    pub fn name(self) -> &'static str {
        match self {
            Session::Last => "last",
            Session::New => "new",
        }
    }
}

/// What the start sends for `session`; none to leave it out. With the
/// choice on screen (`offered`) it is what is selected there -- the last
/// session until the person picks the other. With no choice on screen
/// nothing is said: the core starts a new session where the last cannot be
/// gone on with, and a host that said "new" there would be deciding it a
/// second time.
pub fn session_sent(offered: bool, picked: Option<Session>) -> Option<Session> {
    if offered {
        Some(picked.unwrap_or(Session::Last))
    } else {
        None
    }
}

/// The request for an act, or none when the row has nothing to send it
/// with -- no terminal behind it, or no moment to say which prompt was
/// seen. A button for that act should not be there to press.
pub fn encode(act: &Act) -> Option<String> {
    Some(match act {
        Act::Seen { group } => format!("{{\"act\":\"seen\",\"group\":{}}}", quote(group)),
        Act::SeenTerminal { terminal } => format!("{{\"act\":\"seen\",\"terminal\":{}}}", quote(terminal)),
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
        Act::RetentionAgree => "{\"act\":\"retention_agree\"}".to_string(),
        Act::Fix { group } => format!("{{\"act\":\"fix\",\"group\":{}}}", quote(group)),
        Act::FixTerminal { terminal } => format!("{{\"act\":\"fix\",\"terminal\":{}}}", quote(terminal)),
        Act::TakeOver { group } => format!("{{\"act\":\"take_over\",\"group\":{}}}", quote(group)),
        Act::Pin { group } => format!("{{\"act\":\"pin\",\"group\":{}}}", quote(group)),
        Act::Unpin { group } => format!("{{\"act\":\"unpin\",\"group\":{}}}", quote(group)),
        Act::Mute { group, until_ms: Some(until) } => format!("{{\"act\":\"mute\",\"group\":{},\"until_ms\":{until}}}", quote(group)),
        Act::Mute { group, until_ms: None } => format!("{{\"act\":\"mute\",\"group\":{}}}", quote(group)),
        Act::Unmute { group } => format!("{{\"act\":\"unmute\",\"group\":{}}}", quote(group)),
        Act::Archive { group } => format!("{{\"act\":\"archive\",\"group\":{}}}", quote(group)),
        Act::Unarchive { group } => format!("{{\"act\":\"unarchive\",\"group\":{}}}", quote(group)),
        Act::RenameGroup { from, to } => format!("{{\"act\":\"rename_group\",\"from\":{},\"to\":{}}}", quote(from), quote(to)),
        Act::ProjectDecline { group } => format!("{{\"act\":\"project_decline\",\"group\":{}}}", quote(group)),
        Act::ProjectUndecline { group } => format!("{{\"act\":\"project_undecline\",\"group\":{}}}", quote(group)),
        Act::ProjectLink { group, project } => {
            format!("{{\"act\":\"project_link\",\"group\":{},\"project\":{}}}", quote(group), quote(project))
        }
        Act::ProjectNotNow { group } => format!("{{\"act\":\"project_not_now\",\"group\":{}}}", quote(group)),
        Act::SetBrief { group, brief } => format!("{{\"act\":\"set_brief\",\"group\":{},\"brief\":{}}}", quote(group), quote(brief)),
        Act::DeleteGroup { group, members, open_tasks } => {
            format!("{{\"act\":\"delete_group\",\"group\":{},\"members\":{members},\"open_tasks\":{open_tasks}}}", quote(group))
        }
        Act::AskSupervisor { group, ask } => {
            format!("{{\"act\":\"ask_supervisor\",\"group\":{},\"ask\":{}}}", quote(group), quote(ask.name()))
        }
        Act::StartSupervisor { group, role, cwd, cli, session } => {
            // Left out when the person picked neither: the core then uses
            // the ones its snapshot named.
            let mut out = format!("{{\"act\":\"start_supervisor\",\"group\":{}", quote(group));
            if let Some(role) = role {
                out.push_str(&format!(",\"role\":{}", quote(role)));
            }
            if let Some(cwd) = cwd {
                out.push_str(&format!(",\"cwd\":{}", quote(cwd)));
            }
            if let Some(cli) = cli.filter(|c| !c.is_empty()) {
                out.push_str(&format!(",\"cli\":{}", quote(cli)));
            }
            if let Some(session) = session {
                out.push_str(&format!(",\"session\":{}", quote(session.name())));
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
    /// A start named a CLI the role is not set up for (#1677, D).
    NotSetUpForCli,
    /// A start named a CLI whose plugin is off (#1677, D): turning it on
    /// is the way through.
    CliOff,
    /// A start named a CLI whose plugin is on but whose adapter cannot run
    /// on this machine: turning the plugin on would not help.
    CliUnavailable,
    /// Its adapter says the CLI's program is not on this machine (task 1744).
    CliNotInstalled,
    /// The directory to start in is not there, or is not one.
    NoSuchDirectory,
    /// No tab could be opened for it.
    OpenFailed,
    NoExecutable,
    /// "Fix" on a card that is not failing any more.
    NothingToFix,
    /// "Fix" on a card that was fixed and has not changed since.
    AlreadyNotified,
    /// Nobody connected in the terminal "Fix" would type into; the
    /// paragraph is kept in the group.
    NoAgent,
    /// A group's new name is empty (task 1659's rename).
    EmptyName,
    /// The group has no supervisor to ask.
    NoSupervisor,
    /// The rename could not be written; nothing was changed.
    RenameFailed,
    /// A record by the new name is still on disk (a group of that name was
    /// deleted from the list and its history kept).
    RenameBlocked,
    /// Another Polter is renaming a group this very moment.
    RenameBusy,
    /// An earlier rename was left half done by a Polter that stopped.
    RenameUnfinished,
    /// Begun and neither finished nor undone; it is finished at the next
    /// start, and the group keeps its old name until then.
    RenameDeferred,
    /// The group is off the list, but some of its records could not be
    /// deleted and are still on disk.
    DeleteFailed,
    /// "Let the control room take over?" on a supervisor that is not one
    /// an adapter recognised as started by hand (task 1635).
    NotStartedByHand,
    /// A take-over is under way.
    AlreadyTakingOver,
    // `project_link` (task 1714, `project-link-interface.md` §1).
    /// The host has not said what projects there are yet.
    ProjectsUnknown,
    NoSuchProject,
    /// The project says it is another group's.
    ProjectHasGroup,
    /// Another project already has the group's name.
    ProjectNameTaken,
    /// The group's supervisor already has a project through another group:
    /// one supervisor, one project.
    SupervisorHasProject,
    /// A name this build does not know. Shown as it came, never dropped.
    Other,
}

impl Refusal {
    pub fn parse(name: &str) -> Refusal {
        match name {
            "BadRequest" => Refusal::BadRequest,
            "NoSuchGroup" => Refusal::NoSuchGroup,
            // A mute's moment is a snooze's in all but name.
            "SnoozeInThePast" | "MuteInThePast" => Refusal::SnoozeInThePast,
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
            "NotSetUpForCli" => Refusal::NotSetUpForCli,
            "CliOff" => Refusal::CliOff,
            "CliUnavailable" => Refusal::CliUnavailable,
            "CliNotInstalled" => Refusal::CliNotInstalled,
            "NotAbsolute" | "NoSuchDirectory" | "NotADirectory" => Refusal::NoSuchDirectory,
            "OpenFailed" | "NoRuntime" => Refusal::OpenFailed,
            "NoExecutable" => Refusal::NoExecutable,
            "NothingToFix" => Refusal::NothingToFix,
            "AlreadyNotified" => Refusal::AlreadyNotified,
            "NoAgent" => Refusal::NoAgent,
            "EmptyName" => Refusal::EmptyName,
            "NoSupervisor" => Refusal::NoSupervisor,
            "RenameFailed" => Refusal::RenameFailed,
            "RenameBlocked" => Refusal::RenameBlocked,
            "RenameBusy" => Refusal::RenameBusy,
            "RenameUnfinished" => Refusal::RenameUnfinished,
            "RenameDeferred" => Refusal::RenameDeferred,
            "DeleteFailed" => Refusal::DeleteFailed,
            "NotStartedByHand" => Refusal::NotStartedByHand,
            "AlreadyTakingOver" => Refusal::AlreadyTakingOver,
            "ProjectsUnknown" => Refusal::ProjectsUnknown,
            "NoSuchProject" => Refusal::NoSuchProject,
            "ProjectHasGroup" => Refusal::ProjectHasGroup,
            "ProjectNameTaken" => Refusal::ProjectNameTaken,
            "SupervisorHasProject" => Refusal::SupervisorHasProject,
            _ => Refusal::Other,
        }
    }

    /// The English of what to tell the person; a host translates it. For
    /// `Other` it has a `{}` for the name the core gave.
    pub fn message(self) -> &'static str {
        match self {
            Refusal::BadRequest => n_("That could not be sent. This is a fault in Polter, not something you did."),
            Refusal::NoSuchGroup => n_("That group is no longer there."),
            Refusal::SnoozeInThePast => n_("That time has already passed."),
            Refusal::UnknownTerminal => n_("That terminal is no longer there."),
            Refusal::PromptGone => n_("The prompt has changed since this was drawn. Nothing was sent; look again."),
            Refusal::NothingToReplyTo => n_("It is not waiting to be told anything right now."),
            Refusal::Stale => n_("It has moved on since this was drawn. Nothing was sent; look again."),
            Refusal::EmptyText => n_("There is nothing to send."),
            Refusal::UserPresent => n_("Somebody typed in that terminal a moment ago. Nothing was sent; try again shortly."),
            Refusal::DraftInLine => n_("That terminal has unsent text in its input line. Nothing was sent; go to the terminal."),
            Refusal::ChildExited => n_("The program in that terminal has ended."),
            Refusal::KeyFailed => n_("The key did not reach the program. Go to the terminal."),
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
            Refusal::NotSetUpForCli => n_("That role isn't set up for that agent CLI."),
            Refusal::CliOff => n_("That agent CLI's plugin is off. Turn it on in Plugins."),
            Refusal::CliUnavailable => n_("That agent CLI can't be started on this machine."),
            Refusal::CliNotInstalled => n_("That agent CLI isn't installed on this machine."),
            Refusal::NoSuchDirectory => n_("That directory is not there."),
            Refusal::OpenFailed => n_("No tab could be opened for it."),
            Refusal::NoExecutable => n_("Polter could not find its own program to start the role with."),
            Refusal::NothingToFix => n_("It is no longer failing. Nothing was sent."),
            Refusal::AlreadyNotified => n_("The supervisor has already been told."),
            Refusal::NoAgent => n_("No agent is connected in that terminal, so nothing was typed. It is kept in the group."),
            Refusal::EmptyName => n_("A group's name cannot be empty."),
            Refusal::NoSupervisor => n_("This group has no supervisor."),
            Refusal::RenameFailed => n_("The group could not be renamed. Nothing was changed."),
            Refusal::RenameBlocked => n_("Records of a group by that name are still on disk. Pick another name."),
            Refusal::RenameBusy => n_("Another Polter is renaming a group right now. Try again in a few seconds."),
            Refusal::RenameUnfinished => n_("An earlier rename was left unfinished. Restart Polter, then try again."),
            Refusal::RenameDeferred => n_("The rename could not be finished now; it will be finished the next time Polter starts."),
            Refusal::DeleteFailed => n_("Deleted from the list, but some of its records could not be deleted."),
            Refusal::NotStartedByHand => n_("There is nothing here the control room can take over."),
            Refusal::AlreadyTakingOver => n_("The control room is already taking over a supervisor."),
            Refusal::ProjectsUnknown => n_("The projects on this computer have not been read yet. Try again in a moment."),
            Refusal::NoSuchProject => n_("That project is not there any more."),
            Refusal::ProjectHasGroup => n_("That project is another group's."),
            Refusal::ProjectNameTaken => n_("Another project already has this group's name."),
            Refusal::SupervisorHasProject => n_("This group's supervisor already has a project through another group: one supervisor, one project."),
            Refusal::Other => n_("It was not done ({})."),
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

/// Looking at a row marks it seen: a row the core says nobody has looked
/// at, left selected with the control room in front for
/// `look::selection::SEEN_AFTER` seconds.
///
/// The rule is one for every row. A group's row is seen by the group's
/// name; a terminal that is in no group has no group to name and is seen
/// by its own (`Act::SeenTerminal`). For as long as only the first was
/// sent, what such a terminal finished stayed "not looked at". Which a row
/// is the list already says (`alone`); nothing is worked out from its id.
/// The macOS host's `ControlRoomActions.seen(rowId:in:)`.
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

/// One wait, for one selection of one row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dwell {
    generation: u64,
    /// The row waited on, by its id.
    pub row: String,
    /// The terminal to name when the row is a terminal in no group.
    alone: Option<String>,
}

impl Dwell {
    fn on(generation: u64, row: &Row) -> Dwell {
        Dwell { generation, row: row.id.clone(), alone: row.alone.as_ref().map(|a| a.terminal.clone()) }
    }
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
        Some(Dwell::on(self.generation, row))
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
        Some(Dwell::on(self.generation, row))
    }

    /// The wait is over: the act to send, or none when the selection moved
    /// or the control room is not what the person is looking at.
    pub fn due<'a>(&self, dwell: &'a Dwell, in_front: bool) -> Option<Act<'a>> {
        let still = self.generation == dwell.generation && self.selected.as_deref() == Some(dwell.row.as_str());
        (still && in_front).then(|| match &dwell.alone {
            Some(terminal) => Act::SeenTerminal { terminal },
            None => Act::Seen { group: &dwell.row },
        })
    }
}

/// When "mute" from the row's menu ends, in wall-clock milliseconds: an
/// hour from `now_ms`; tomorrow at 9:00 in the person's own time, as the
/// menu says it (the brief: "到明天 9:00") -- tomorrow's even just after
/// midnight; or never (task 1659: the host works these out, the core is
/// told the moment). `offset_ms` is how far local time is ahead of UTC at
/// `now_ms`. None for an id that is not one of the three.
pub fn mute_until(id: &str, now_ms: u64, offset_ms: i64) -> Option<Option<u64>> {
    const HOUR: u64 = 3_600_000;
    const DAY: i64 = 86_400_000;
    match id {
        "mute_hour" => Some(Some(now_ms + HOUR)),
        "mute_forever" => Some(None),
        "mute_tomorrow" => {
            let local = now_ms as i64 + offset_ms;
            let midnight = local.div_euclid(DAY) * DAY;
            let at = midnight + DAY + 9 * HOUR as i64;
            Some(Some((at - offset_ms).max(0) as u64))
        }
        _ => None,
    }
}

/// Why asking the supervisor (`Act::AskSupervisor`) typed nothing, in a
/// few words for the line under the row, untranslated; and whether the core
/// will try again by itself (task 1659: it does for these two, three times
/// some seconds apart, and the host does not send it again).
pub fn not_delivered(refusal: &str) -> (&'static str, bool) {
    match Refusal::parse(refusal) {
        Refusal::DraftInLine => (n_("the supervisor's input line has text in it"), true),
        Refusal::UserPresent => (n_("somebody just typed in the supervisor's terminal"), true),
        Refusal::NoAgent => (n_("no agent is connected in the supervisor's terminal"), false),
        other => (other.message(), false),
    }
}

/// What a "not delivered, will try again" line under a row becomes, now
/// that a snapshot says how the row's last ask went (task 1671). The macOS
/// host's `ControlRoomRowMenu.followAsk`; `hosts-agree` compares the two.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AskNow {
    /// Nothing to change.
    Keep,
    /// The ask the line is about is this message: wait for its end.
    Wait(u64),
    /// It went in: the line says it was asked, and folds away.
    Delivered,
    /// It was given up on, for this reason (the core's code).
    GaveUp(String),
}

/// `waiting_on` is the message the line already knows it is about; none
/// until a snapshot has said. The line was put there by the ask's own
/// reply, so the first ask the core says is being tried again is that one
/// -- and a later message than the one waited on is a later ask by the
/// person, which is the line's now. **An earlier one never is**: a snapshot
/// from before the reply can still be on its way, saying how the ask
/// before went.
pub fn follow_ask(waiting_on: Option<u64>, ask: Option<&crate::snapshot::AskState>) -> AskNow {
    use crate::snapshot::AskStage;
    let Some(ask) = ask else { return AskNow::Keep };
    let ours = match waiting_on {
        None => ask.stage == AskStage::Retrying,
        Some(seq) => ask.seq >= seq,
    };
    if !ours {
        return AskNow::Keep;
    }
    match ask.stage {
        AskStage::Retrying if waiting_on == Some(ask.seq) => AskNow::Keep,
        AskStage::Retrying => AskNow::Wait(ask.seq),
        AskStage::Delivered => AskNow::Delivered,
        AskStage::GaveUp => AskNow::GaveUp(ask.code.clone().unwrap_or_default()),
    }
}

/// The cases `hosts-agree` runs both hosts' `follow_ask` over: what the
/// line waits on, and what the snapshot says.
pub fn follow_ask_cases() -> Vec<(Option<u64>, Option<crate::snapshot::AskState>)> {
    use crate::snapshot::{AskStage::*, AskState};
    let s = |seq, stage, code: Option<&str>| Some(AskState { seq, stage, code: code.map(str::to_string) });
    vec![
        (None, None),
        (None, s(7, Retrying, Some("DraftInLine"))),
        (None, s(7, Delivered, None)),
        (None, s(7, GaveUp, Some("UserPresent"))),
        (Some(7), None),
        (Some(7), s(7, Retrying, Some("DraftInLine"))),
        (Some(7), s(7, Delivered, None)),
        (Some(7), s(7, GaveUp, Some("UserPresent"))),
        (Some(7), s(6, Delivered, None)),
        (Some(7), s(6, Retrying, Some("DraftInLine"))),
        (Some(7), s(9, Retrying, Some("UserPresent"))),
        (Some(7), s(9, Delivered, None)),
    ]
}

/// One line of `hosts-agree` for a case of `follow_ask`.
pub fn follow_ask_line(waiting_on: Option<u64>, ask: Option<&crate::snapshot::AskState>) -> String {
    use crate::snapshot::AskStage;
    let on = waiting_on.map_or("none".to_string(), |s| s.to_string());
    let said = match ask {
        None => "none".to_string(),
        Some(a) => format!(
            "{}:{}:{}",
            a.seq,
            match a.stage {
                AskStage::Retrying => "retrying",
                AskStage::Delivered => "delivered",
                AskStage::GaveUp => "gave_up",
            },
            a.code.as_deref().unwrap_or("-")
        ),
    };
    let now = match follow_ask(waiting_on, ask) {
        AskNow::Keep => "keep".to_string(),
        AskNow::Wait(s) => format!("wait {s}"),
        AskNow::Delivered => "delivered".to_string(),
        AskNow::GaveUp(c) => format!("gave_up {c}"),
    };
    format!("follow_ask on={on} said={said} -> {now}")
}

#[cfg(test)]
mod follow_ask_tests {
    use super::*;
    use crate::snapshot::{AskStage, AskState};

    fn said(seq: u64, stage: AskStage) -> AskState {
        AskState { seq, stage, code: (stage != AskStage::Delivered).then(|| "DraftInLine".to_string()) }
    }

    /// Task 1671 (the test machine, #1666): the retry went in and the line
    /// said "will try again" forty seconds later. The line learns which ask
    /// it is about, then that it went in -- or why it was given up on.
    #[test]
    fn a_line_waiting_on_a_retry_hears_how_it_ended() {
        assert_eq!(follow_ask(None, Some(&said(7, AskStage::Retrying))), AskNow::Wait(7));
        assert_eq!(follow_ask(Some(7), Some(&said(7, AskStage::Retrying))), AskNow::Keep);
        assert_eq!(follow_ask(Some(7), Some(&said(7, AskStage::Delivered))), AskNow::Delivered);
        assert_eq!(follow_ask(Some(7), Some(&said(7, AskStage::GaveUp))), AskNow::GaveUp("DraftInLine".into()));
        // A core that does not say keeps the line as it was.
        assert_eq!(follow_ask(Some(7), None), AskNow::Keep);
    }

    /// The ask before this one is never taken for it, whatever it says;
    /// a later one -- the person asked again -- is.
    #[test]
    fn only_this_ask_or_a_later_one_moves_the_line() {
        assert_eq!(follow_ask(None, Some(&said(6, AskStage::Delivered))), AskNow::Keep);
        assert_eq!(follow_ask(Some(7), Some(&said(6, AskStage::Delivered))), AskNow::Keep);
        assert_eq!(follow_ask(Some(7), Some(&said(6, AskStage::Retrying))), AskNow::Keep);
        assert_eq!(follow_ask(Some(7), Some(&said(9, AskStage::Retrying))), AskNow::Wait(9));
        assert_eq!(follow_ask(Some(7), Some(&said(9, AskStage::Delivered))), AskNow::Delivered);
    }
}

#[cfg(test)]
mod menu_tests {
    use super::*;

    #[test]
    fn the_project_links_refusals_are_named_and_not_taken_for_another() {
        // Task 1714: `project_link`'s four, by the names `ControlAct.zig`
        // gives them.
        for (name, r) in [
            ("ProjectsUnknown", Refusal::ProjectsUnknown),
            ("NoSuchProject", Refusal::NoSuchProject),
            ("ProjectHasGroup", Refusal::ProjectHasGroup),
            ("ProjectNameTaken", Refusal::ProjectNameTaken),
            ("SupervisorHasProject", Refusal::SupervisorHasProject),
        ] {
            assert_eq!(Refusal::parse(name), r, "{name}");
            let own = r.message() != Refusal::Other.message();
            assert!(own, "{name}");
        }
    }

    #[test]
    fn the_menu_acts_are_the_cores_words() {
        assert_eq!(encode(&Act::Pin { group: "g" }).unwrap(), r#"{"act":"pin","group":"g"}"#);
        assert_eq!(encode(&Act::Unpin { group: "g" }).unwrap(), r#"{"act":"unpin","group":"g"}"#);
        assert_eq!(encode(&Act::Mute { group: "g", until_ms: Some(5) }).unwrap(), r#"{"act":"mute","group":"g","until_ms":5}"#);
        assert_eq!(encode(&Act::Mute { group: "g", until_ms: None }).unwrap(), r#"{"act":"mute","group":"g"}"#);
        assert_eq!(encode(&Act::Unmute { group: "g" }).unwrap(), r#"{"act":"unmute","group":"g"}"#);
        assert_eq!(encode(&Act::Archive { group: "g" }).unwrap(), r#"{"act":"archive","group":"g"}"#);
        assert_eq!(encode(&Act::Unarchive { group: "g" }).unwrap(), r#"{"act":"unarchive","group":"g"}"#);
        assert_eq!(encode(&Act::RenameGroup { from: "a", to: "b\"" }).unwrap(), r#"{"act":"rename_group","from":"a","to":"b\""}"#);
        // The person's word on a group's project (task 1714): the core's
        // `ControlAct` names, field for field.
        assert_eq!(encode(&Act::ProjectDecline { group: "g" }).unwrap(), r#"{"act":"project_decline","group":"g"}"#);
        assert_eq!(encode(&Act::ProjectUndecline { group: "g" }).unwrap(), r#"{"act":"project_undecline","group":"g"}"#);
        assert_eq!(
            encode(&Act::ProjectLink { group: "g", project: "p\"" }).unwrap(),
            r#"{"act":"project_link","group":"g","project":"p\""}"#
        );
        assert_eq!(encode(&Act::ProjectNotNow { group: "g" }).unwrap(), r#"{"act":"project_not_now","group":"g"}"#);
        assert_eq!(encode(&Act::SetBrief { group: "g", brief: "x\ny" }).unwrap(), r#"{"act":"set_brief","group":"g","brief":"x\ny"}"#);
        assert_eq!(
            encode(&Act::DeleteGroup { group: "g", members: 2, open_tasks: 3 }).unwrap(),
            r#"{"act":"delete_group","group":"g","members":2,"open_tasks":3}"#
        );
        assert_eq!(encode(&Act::AskSupervisor { group: "g", ask: Ask::Report }).unwrap(), r#"{"act":"ask_supervisor","group":"g","ask":"report"}"#);
        assert_eq!(encode(&Act::AskSupervisor { group: "g", ask: Ask::CloseIdle }).unwrap(), r#"{"act":"ask_supervisor","group":"g","ask":"close_idle"}"#);
        assert_eq!(Refusal::parse("MuteInThePast"), Refusal::SnoozeInThePast);
        assert_eq!(Refusal::parse("EmptyName"), Refusal::EmptyName);
        assert_eq!(not_delivered("DraftInLine"), ("the supervisor's input line has text in it", true));
        assert_eq!(not_delivered("UserPresent").1, true);
        assert_eq!(not_delivered("NoAgent").1, false);
        assert_eq!(not_delivered("NoSupervisor"), (Refusal::NoSupervisor.message(), false));
    }

    /// 2026-10-16 15:40 in Shanghai (UTC+8) is 07:40 UTC.
    #[test]
    fn muting_ends_in_an_hour_tomorrow_at_nine_or_never() {
        const HOUR: u64 = 3_600_000;
        let offset = 8 * HOUR as i64;
        // 2026-10-16T07:40:00Z
        let now = 1_792_136_400_000;
        assert_eq!(mute_until("mute_hour", now, offset), Some(Some(now + HOUR)));
        assert_eq!(mute_until("mute_forever", now, offset), Some(None));
        // 2026-10-17 09:00 in Shanghai is 2026-10-17T01:00:00Z.
        assert_eq!(mute_until("mute_tomorrow", now, offset), Some(Some(1_792_198_800_000)));
        // Just after midnight it is still tomorrow's 9:00, not today's.
        let early = 1_792_198_800_000 - 8 * HOUR - 30 * 60_000; // 00:30 local on the 17th
        assert_eq!(mute_until("mute_tomorrow", early, offset), Some(Some(1_792_198_800_000 + 24 * HOUR)));
        assert_eq!(mute_until("pin", now, offset), None);
    }
}
