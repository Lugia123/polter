//! The core's control-room snapshot, read and nothing more.
//!
//! `src/poltergeist/ControlRoom.zig` says the whole shape. This takes the
//! part a list of groups draws, and **does not take the part that would let
//! a host decide anything**: the core's `kind` is not a field here at all,
//! so nothing downstream can compare one. What a row draws is `shown`, what
//! it says is `text`, where it sits is its place in `groups`.
//!
//! A value this does not know is an error. A glyph that silently went
//! missing would look like a group with nothing to say.

use crate::json::{self, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shown {
    NeedsYou,
    Trouble,
    DoneUnseen,
    Working,
    None,
}

impl Shown {
    /// The core's spelling, both ways.
    pub fn name(self) -> &'static str {
        match self {
            Shown::NeedsYou => "needs_you",
            Shown::Trouble => "trouble",
            Shown::DoneUnseen => "done_unseen",
            Shown::Working => "working",
            Shown::None => "none",
        }
    }

    pub(crate) fn parse(s: &str) -> Option<Shown> {
        [Shown::NeedsYou, Shown::Trouble, Shown::DoneUnseen, Shown::Working, Shown::None]
            .into_iter()
            .find(|v| v.name() == s)
    }
}

/// Who is waiting, as the core says it. A host turns this into words and
/// never works it out from `steward` and `terminal`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaiterIs {
    /// Nobody is: the row is not about a terminal.
    None,
    /// The group's supervisor itself.
    Supervisor,
    /// One of the supervisor's workers; the person reaches it through the
    /// supervisor.
    WorkerViaSupervisor,
    /// A worker of a group that has no supervisor.
    Worker,
    /// A terminal that is in no group.
    Terminal,
}

impl WaiterIs {
    pub fn name(self) -> &'static str {
        match self {
            WaiterIs::None => "none",
            WaiterIs::Supervisor => "supervisor",
            WaiterIs::WorkerViaSupervisor => "worker_via_supervisor",
            WaiterIs::Worker => "worker",
            WaiterIs::Terminal => "terminal",
        }
    }

    pub(crate) fn parse(s: &str) -> Option<WaiterIs> {
        [WaiterIs::None, WaiterIs::Supervisor, WaiterIs::WorkerViaSupervisor, WaiterIs::Worker, WaiterIs::Terminal]
            .into_iter()
            .find(|v| v.name() == s)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Waiter {
    pub is: WaiterIs,
    /// What that terminal is called. Empty for the supervisor and for none.
    pub name: String,
}

/// What kind of thing is being waited on: how its lines are set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Form {
    /// Nothing to say.
    None,
    /// A shell command, one step to a line.
    Command,
    /// Something to be read letter by letter that is not a shell command.
    Code,
    /// A sentence.
    Words,
}

impl Form {
    pub fn name(self) -> &'static str {
        match self {
            Form::None => "none",
            Form::Command => "command",
            Form::Code => "code",
            Form::Words => "words",
        }
    }

    pub(crate) fn parse(s: &str) -> Option<Form> {
        [Form::None, Form::Command, Form::Code, Form::Words].into_iter().find(|v| v.name() == s)
    }
}

/// Whether `lines` is all of it. A host marks where the rest would be and
/// never shows a part as the whole.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cut {
    /// Everything that was said.
    None,
    /// The start of something longer, or it may be.
    Tail,
    /// The end of something longer.
    Head,
}

impl Cut {
    pub fn name(self) -> &'static str {
        match self {
            Cut::None => "none",
            Cut::Tail => "tail",
            Cut::Head => "head",
        }
    }

    pub(crate) fn parse(s: &str) -> Option<Cut> {
        [Cut::None, Cut::Tail, Cut::Head].into_iter().find(|v| v.name() == s)
    }
}

/// What is being waited on. `lines` is one step of a command each, or the
/// one sentence; `cut` is the core's word for whether that is all of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct What {
    pub form: Form,
    pub lines: Vec<String>,
    pub cut: Cut,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reason {
    pub from: String,
    pub text: String,
}

/// Where a group stands with a supervisor (`ControlRoom.zig`,
/// `SupervisorOut`). It only picks the sentence: whether one can be started
/// is `can_start`, the core's word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SupervisorState {
    Present,
    Absent,
    Starting,
    Failed,
}

impl SupervisorState {
    pub fn name(self) -> &'static str {
        match self {
            SupervisorState::Present => "present",
            SupervisorState::Absent => "absent",
            SupervisorState::Starting => "starting",
            SupervisorState::Failed => "failed",
        }
    }

    fn parse(s: &str) -> Option<SupervisorState> {
        [SupervisorState::Present, SupervisorState::Absent, SupervisorState::Starting, SupervisorState::Failed]
            .into_iter()
            .find(|v| v.name() == s)
    }
}

/// Why the last try made no supervisor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartFailure {
    None,
    TerminalNeverOpened,
    AgentNeverConnected,
    TerminalClosed,
    /// `+launch` said so itself, at once: the CLI's program is not there
    /// to run.
    CliNotFound,
    /// `+launch` said so itself: something else stopped it before the CLI
    /// ran.
    CliDidNotStart,
}

impl StartFailure {
    pub fn name(self) -> &'static str {
        match self {
            StartFailure::None => "none",
            StartFailure::TerminalNeverOpened => "terminal_never_opened",
            StartFailure::AgentNeverConnected => "agent_never_connected",
            StartFailure::TerminalClosed => "terminal_closed",
            StartFailure::CliNotFound => "cli_not_found",
            StartFailure::CliDidNotStart => "cli_did_not_start",
        }
    }

    /// Every reason the core gives. A word that is none of these is an
    /// error, like a glyph this build does not know.
    pub const ALL: [StartFailure; 6] = [
        StartFailure::None,
        StartFailure::TerminalNeverOpened,
        StartFailure::AgentNeverConnected,
        StartFailure::TerminalClosed,
        StartFailure::CliNotFound,
        StartFailure::CliDidNotStart,
    ];

    fn parse(s: &str) -> Option<StartFailure> {
        Self::ALL.into_iter().find(|v| v.name() == s)
    }
}

/// Why a start does not go on with the last supervisor's session, or
/// `None` when it does (`ControlRoom.zig`, `ResumeOut.Why`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResumeWhy {
    None,
    NoRecord,
    NoSession,
    LastTryFailed,
    CliDiffers,
    ClisUnread,
    CliCannotResume,
    SessionInUse,
}

impl ResumeWhy {
    pub fn name(self) -> &'static str {
        match self {
            ResumeWhy::None => "none",
            ResumeWhy::NoRecord => "no_record",
            ResumeWhy::NoSession => "no_session",
            ResumeWhy::LastTryFailed => "last_try_failed",
            ResumeWhy::CliDiffers => "cli_differs",
            ResumeWhy::ClisUnread => "clis_unread",
            ResumeWhy::CliCannotResume => "cli_cannot_resume",
            ResumeWhy::SessionInUse => "session_in_use",
        }
    }

    /// Every reason the core gives. A word that is none of these is an
    /// error, like a glyph this build does not know.
    pub const ALL: [ResumeWhy; 8] = [
        ResumeWhy::None,
        ResumeWhy::NoRecord,
        ResumeWhy::NoSession,
        ResumeWhy::LastTryFailed,
        ResumeWhy::CliDiffers,
        ResumeWhy::ClisUnread,
        ResumeWhy::CliCannotResume,
        ResumeWhy::SessionInUse,
    ];

    fn parse(s: &str) -> Option<ResumeWhy> {
        Self::ALL.into_iter().find(|v| v.name() == s)
    }
}

/// What the core says of the supervisor a group last had, and whether a
/// start goes on with its session (`ControlRoom.zig`, `SupervisorOut`'s
/// `cli`, `last` and `resume`). What the right side makes of it is
/// `scene::last_supervisor_said`, `scene::resume_note` and `scene::build_start`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupervisorLast {
    /// The CLI the default role is started in.
    pub cli: Option<String>,
    /// The role and the CLI the last supervisor was, and when it was last
    /// heard from (the real clock). Each `None` when nobody wrote it down.
    pub role: Option<String>,
    pub last_cli: Option<String>,
    pub heard_ms: Option<u64>,
    /// Whether a start goes on with its session. A host offers that on
    /// this and on nothing else, and says `why` when it is no.
    pub can_resume: bool,
    pub why: ResumeWhy,
    /// The directory the core names for the start (`cwd`) is where that
    /// supervisor last worked (`cwd_from: last_supervisor`), and not
    /// somewhere worked out another way.
    pub cwd_is_last: bool,
    /// What the two CLIs are called to a person, as the core says
    /// (`cli_label`): the one a start uses, and the one the last supervisor
    /// was. `None` when the core has no name for it, and then the key is
    /// what is written.
    pub cli_label: Option<String>,
    pub last_cli_label: Option<String>,
}

/// What the core says about a group's supervisor and what starting one
/// would use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupervisorStart {
    pub state: SupervisorState,
    /// Whether the button is offered. A host shows it on this and works
    /// nothing out from `state`.
    pub can_start: bool,
    pub failed: StartFailure,
    /// The role it is started in unless the person picks another.
    pub role: Option<String>,
    /// Where it is started unless the person picks elsewhere.
    pub cwd: String,
    /// The last supervisor and whether its session is gone on with.
    /// `None` for a snapshot from before the core said it.
    pub last: Option<SupervisorLast>,
}

/// A role a supervisor can be started in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupervisorRole {
    pub key: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub name: String,
    pub needs_me: bool,
    /// The core says nobody has looked at this since it stopped.
    pub unseen: bool,
    pub shown: Shown,
    /// The words beside the glyph, already in the person's language.
    pub text: String,
    pub waiter: Waiter,
    pub reason: Reason,
    pub what: What,
    pub more: u64,
    pub same_as: Option<String>,
    /// The terminal that is this group's supervisor, none when it has none.
    /// The core's choice; a host finds that terminal by equality and never
    /// picks one out of the members itself.
    pub steward: Option<String>,
    /// The terminal the row is about and the two moments it was drawn
    /// from: what an act on this row hands back (`act`). Opaque; a host
    /// only ever tests them for equality or sends them home.
    pub terminal: Option<String>,
    pub since_ms: u64,
    pub event_ms: Option<u64>,
    /// None in a snapshot from before the core said it; then nothing is
    /// offered.
    pub supervisor: Option<SupervisorStart>,
}

/// Which of the three frames a terminal's pane wears in its own tab, as the
/// core spells them (`pane::drawn` says whether one is drawn at all).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pane {
    /// A border all round, its top edge thickened into the title bar.
    Supervisor,
    /// A line all round and a band for the title.
    Worker,
    /// No line and no band: the title on the terminal's own ground.
    Plain,
}

impl Pane {
    pub const ALL: [Pane; 3] = [Pane::Supervisor, Pane::Worker, Pane::Plain];

    pub fn name(self) -> &'static str {
        match self {
            Pane::Supervisor => "supervisor",
            Pane::Worker => "worker",
            Pane::Plain => "plain",
        }
    }

    fn parse(s: &str) -> Option<Pane> {
        Pane::ALL.into_iter().find(|v| v.name() == s)
    }
}

/// The glyph at the right end of a pane's title: the five a row draws, and
/// `Held`, which only a title does (`ControlRoom.zig`, `Bar`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BarShown {
    NeedsYou,
    Trouble,
    DoneUnseen,
    Working,
    None,
    /// The person is holding the terminal, and nobody is waiting on it.
    Held,
}

impl BarShown {
    pub const ALL: [BarShown; 6] =
        [BarShown::NeedsYou, BarShown::Trouble, BarShown::DoneUnseen, BarShown::Working, BarShown::None, BarShown::Held];

    pub fn name(self) -> &'static str {
        match self {
            BarShown::Held => "held",
            BarShown::NeedsYou => Shown::NeedsYou.name(),
            BarShown::Trouble => Shown::Trouble.name(),
            BarShown::DoneUnseen => Shown::DoneUnseen.name(),
            BarShown::Working => Shown::Working.name(),
            BarShown::None => Shown::None.name(),
        }
    }

    fn parse(s: &str) -> Option<BarShown> {
        BarShown::ALL.into_iter().find(|v| v.name() == s)
    }

    /// The same glyph, for a status that is not a pane's.
    pub fn of(status: Shown) -> BarShown {
        match status {
            Shown::NeedsYou => BarShown::NeedsYou,
            Shown::Trouble => BarShown::Trouble,
            Shown::DoneUnseen => BarShown::DoneUnseen,
            Shown::Working => BarShown::Working,
            Shown::None => BarShown::None,
        }
    }

    /// The status glyph this is; none for `Held`, which is not one of them.
    pub fn status(self) -> Option<Shown> {
        match self {
            BarShown::NeedsYou => Some(Shown::NeedsYou),
            BarShown::Trouble => Some(Shown::Trouble),
            BarShown::DoneUnseen => Some(Shown::DoneUnseen),
            BarShown::Working => Some(Shown::Working),
            BarShown::None => Some(Shown::None),
            BarShown::Held => None,
        }
    }
}

/// What the right end of a pane's title draws, as the core worked it out.
/// **A host draws this pair and makes none of its own** out of the status
/// and whether the terminal is held: which of them wins is the core's rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bar {
    pub shown: BarShown,
    pub text: String,
}

/// One open terminal, as much of it as its pane's frame shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Terminal {
    pub id: String,
    pub title: String,
    pub shown: Shown,
    /// The words beside the glyph, already in the person's language.
    pub text: String,
    /// None in a snapshot from before the core said it; such a terminal is
    /// drawn as an ordinary one.
    pub pane: Option<Pane>,
    /// None in a snapshot from before the core said it; the title then
    /// says the terminal's status, as it did before.
    pub bar: Option<Bar>,
    /// Who is working in it. None in a snapshot from before the core said
    /// it. Read and carried; nothing here draws it.
    pub who: Option<Who>,
}

/// Which of the core's three answers to "who is in this terminal"
/// (`ControlRoom.zig`, `WhoOut`). `Unknown` is not `None`: the core could
/// not tell, which is not nobody.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WhoIs {
    Unknown,
    None,
    Agent,
}

impl WhoIs {
    pub fn name(self) -> &'static str {
        match self {
            WhoIs::Unknown => "unknown",
            WhoIs::None => "none",
            WhoIs::Agent => "agent",
        }
    }

    /// Every answer the core gives. A word that is none of these is an
    /// error, like a glyph this build does not know.
    pub const ALL: [WhoIs; 3] = [WhoIs::Unknown, WhoIs::None, WhoIs::Agent];

    fn parse(s: &str) -> Option<WhoIs> {
        Self::ALL.into_iter().find(|v| v.name() == s)
    }
}

/// Who is working in a terminal: what a host writes into a project's pane.
/// `role`, `cli` and `session` are the core's words, kept as it wrote them
/// -- for an agent an empty string is that part not known, and for the
/// other two all three are `None`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Who {
    /// Which of the three: the snapshot's `who.is`.
    pub is: WhoIs,
    pub role: Option<String>,
    pub cli: Option<String>,
    pub session: Option<String>,
    /// The terminal whose agent opened this one, in this run.
    pub opened_by: Option<String>,
}

/// One window tab and the one glyph it carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tab {
    pub window: Option<String>,
    pub tab: String,
    pub shown: Shown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pulse {
    pub terminal: String,
    pub window: Option<String>,
    pub tab: Option<String>,
    pub group: Option<String>,
}

/// One of the list's two headings, as the core writes it: how many rows
/// are under it, whether every one of them is a group, and which form of
/// the number the sentence takes. Nothing here is worked out from `count`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub count: u64,
    pub of: HeaderOf,
    pub number: HeaderNumber,
}

/// What the rows under a heading are called.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeaderOf {
    /// Every one is a group.
    Groups,
    /// Some are terminals in no group: the heading does not say "group".
    Rows,
}

impl HeaderOf {
    pub fn parse(s: &str) -> Option<HeaderOf> {
        Some(match s {
            "groups" => HeaderOf::Groups,
            "rows" => HeaderOf::Rows,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            HeaderOf::Groups => "groups",
            HeaderOf::Rows => "rows",
        }
    }
}

/// Which form of the number a heading's sentence takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeaderNumber {
    None,
    One,
    Other,
}

impl HeaderNumber {
    pub fn parse(s: &str) -> Option<HeaderNumber> {
        Some(match s {
            "none" => HeaderNumber::None,
            "one" => HeaderNumber::One,
            "other" => HeaderNumber::Other,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            HeaderNumber::None => "none",
            HeaderNumber::One => "one",
            HeaderNumber::Other => "other",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub rev: u64,
    pub now_ms: u64,
    /// Terminals waiting, each once: the taskbar badge and notifications.
    pub needs_me: u64,
    /// Rows waiting: "N groups are waiting for you".
    pub groups_needing_me: u64,
    pub groups_other: u64,
    /// The first heading, as the core writes it: the rows waiting, the
    /// terminals in no group among them. None in a snapshot from a core
    /// that does not say; the heading is then the groups' count.
    pub header_waiting: Option<Header>,
    /// The second heading, by the same rule.
    pub header_quiet: Option<Header>,
    /// The group to start on when the control room opens with nothing
    /// selected: the core's choice of first and of which have an agent.
    pub open_on: Option<String>,
    /// Already in the order to draw them.
    pub groups: Vec<Group>,
    /// Every window tab the core has placed, each with its glyph.
    pub tabs: Vec<Tab>,
    pub pulses: Vec<Pulse>,
    /// How much of each account's allowance is used (`quota`). None in a
    /// snapshot from a core that does not say; one that says it in a word
    /// this build does not know is not read at all.
    pub quota: Option<crate::quota::Quota>,
    /// Every open terminal, for the frame its pane wears. Empty in a
    /// snapshot that lists none.
    pub terminals: Vec<Terminal>,
    /// The terminals that are in no group and have a row of their own, in
    /// the core's order (`lone`). Empty in a snapshot that lists none.
    pub ungrouped: Vec<crate::lone::Lone>,
    /// The roles a supervisor can be started in, in the core's order.
    /// Empty in a snapshot from before one could be started here.
    pub supervisor_roles: Vec<SupervisorRole>,
    /// Whether there is a choice of role to offer: the core's word, not
    /// the length of the list.
    pub choose_supervisor_role: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// Not JSON at all.
    Json(json::Error),
    /// A field that has to be there is not, or is not what it has to be.
    /// The path says which.
    Field(String),
    /// A `shown` this build has no glyph for.
    UnknownShown(String),
    /// A `waiter.is` or a `what.form` this build has no words or face for.
    UnknownValue(String),
}

type Res<T> = Result<T, DecodeError>;

pub(crate) fn field<'a>(v: &'a Value, path: &str, key: &str) -> Res<&'a Value> {
    v.get(key).ok_or_else(|| DecodeError::Field(format!("{path}.{key}")))
}

pub(crate) fn int(v: &Value, path: &str, key: &str) -> Res<u64> {
    match field(v, path, key)? {
        Value::Int(n) => Ok(*n),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

pub(crate) fn opt_int(v: &Value, path: &str, key: &str) -> Res<Option<u64>> {
    match field(v, path, key)? {
        Value::Null => Ok(None),
        Value::Int(n) => Ok(Some(*n)),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

pub(crate) fn boolean(v: &Value, path: &str, key: &str) -> Res<bool> {
    match field(v, path, key)? {
        Value::Bool(b) => Ok(*b),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

pub(crate) fn text(v: &Value, path: &str, key: &str) -> Res<String> {
    match field(v, path, key)? {
        Value::Str(s) => Ok(s.clone()),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

pub(crate) fn opt_text(v: &Value, path: &str, key: &str) -> Res<Option<String>> {
    match field(v, path, key)? {
        Value::Null => Ok(None),
        Value::Str(s) => Ok(Some(s.clone())),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

pub(crate) fn list<'a>(v: &'a Value, path: &str, key: &str) -> Res<&'a [Value]> {
    match field(v, path, key)? {
        Value::Arr(items) => Ok(items),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

fn group(v: &Value, path: &str) -> Res<Group> {
    let shown = text(v, path, "shown")?;
    let reason = field(v, path, "reason")?;
    let attention = field(v, path, "attention")?;
    let waiter = field(v, path, "waiter")?;
    let waiter_at = format!("{path}.waiter");
    let is = text(waiter, &waiter_at, "is")?;
    let what = field(v, path, "what")?;
    let what_at = format!("{path}.what");
    let form = text(what, &what_at, "form")?;
    let cut = text(what, &what_at, "cut")?;
    let mut lines = Vec::new();
    for (i, l) in list(what, &what_at, "lines")?.iter().enumerate() {
        match l {
            Value::Str(s) => lines.push(s.clone()),
            _ => return Err(DecodeError::Field(format!("{what_at}.lines[{i}]"))),
        }
    }
    let at = format!("{path}.attention");
    let supervisor = match v.get("supervisor") {
        None => None,
        Some(s) => {
            let sp = format!("{path}.supervisor");
            let state = text(s, &sp, "state")?;
            let failed = text(s, &sp, "failed")?;
            Some(SupervisorStart {
                state: SupervisorState::parse(&state).ok_or(DecodeError::UnknownValue(format!("{sp}.state={state}")))?,
                can_start: boolean(s, &sp, "can_start")?,
                failed: StartFailure::parse(&failed).ok_or(DecodeError::UnknownValue(format!("{sp}.failed={failed}")))?,
                role: opt_text(s, &sp, "role")?,
                cwd: text(s, &sp, "cwd")?,
                // All of it or none: a core that says `resume` says the
                // other two with it.
                last: match (s.get("last"), s.get("resume")) {
                    (Some(last), Some(resume)) => {
                        let lp = format!("{sp}.last");
                        let rp = format!("{sp}.resume");
                        let why = text(resume, &rp, "why")?;
                        Some(SupervisorLast {
                            cli: opt_text(s, &sp, "cli")?,
                            role: opt_text(last, &lp, "role")?,
                            last_cli: opt_text(last, &lp, "cli")?,
                            heard_ms: opt_int(last, &lp, "heard_ms")?,
                            can_resume: boolean(resume, &rp, "can")?,
                            why: ResumeWhy::parse(&why).ok_or(DecodeError::UnknownValue(format!("{rp}.why={why}")))?,
                            cwd_is_last: opt_text(s, &sp, "cwd_from")?.as_deref() == Some("last_supervisor"),
                            // Newer than the rest: a core from before it
                            // gave names says none, and that is no name.
                            cli_label: if s.get("cli_label").is_some() { opt_text(s, &sp, "cli_label")? } else { None },
                            last_cli_label: if last.get("cli_label").is_some() { opt_text(last, &lp, "cli_label")? } else { None },
                        })
                    }
                    (None, None) => None,
                    _ => return Err(DecodeError::Field(format!("{sp}.resume"))),
                },
            })
        }
    };
    Ok(Group {
        name: text(v, path, "name")?,
        needs_me: boolean(v, path, "needs_me")?,
        unseen: boolean(v, path, "unseen")?,
        shown: Shown::parse(&shown).ok_or(DecodeError::UnknownShown(shown))?,
        text: text(v, path, "text")?,
        waiter: Waiter {
            is: WaiterIs::parse(&is).ok_or(DecodeError::UnknownValue(format!("{waiter_at}.is={is}")))?,
            name: text(waiter, &waiter_at, "name")?,
        },
        what: What {
            form: Form::parse(&form).ok_or(DecodeError::UnknownValue(format!("{what_at}.form={form}")))?,
            lines,
            cut: Cut::parse(&cut).ok_or(DecodeError::UnknownValue(format!("{what_at}.cut={cut}")))?,
        },
        reason: Reason {
            from: text(reason, &format!("{path}.reason"), "from")?,
            text: text(reason, &format!("{path}.reason"), "text")?,
        },
        more: int(v, path, "more")?,
        same_as: opt_text(v, path, "same_as")?,
        steward: opt_text(v, path, "steward")?,
        terminal: opt_text(attention, &at, "terminal")?,
        since_ms: int(attention, &at, "since_ms")?,
        event_ms: opt_int(attention, &at, "event_ms")?,
        supervisor,
    })
}

/// A heading the core wrote, or none where the snapshot has none. One that
/// is there and says a word this build does not know is not read at all:
/// a heading written from a guess would be a wrong number said plainly.
fn header(v: &Value, key: &str) -> Res<Option<Header>> {
    let Some(h) = v.get(key) else { return Ok(None) };
    let of = text(h, key, "of")?;
    let number = text(h, key, "number")?;
    Ok(Some(Header {
        count: int(h, key, "count")?,
        of: HeaderOf::parse(&of).ok_or(DecodeError::UnknownValue(format!("{key}.of={of}")))?,
        number: HeaderNumber::parse(&number).ok_or(DecodeError::UnknownValue(format!("{key}.number={number}")))?,
    }))
}

pub fn decode(json_text: &str) -> Res<Snapshot> {
    let v = json::parse(json_text).map_err(DecodeError::Json)?;
    let root = "snapshot";

    let mut groups = Vec::new();
    for (i, g) in list(&v, root, "groups")?.iter().enumerate() {
        groups.push(group(g, &format!("groups[{i}]"))?);
    }

    let mut tabs = Vec::new();
    for (i, t) in list(&v, root, "tabs")?.iter().enumerate() {
        let path = format!("tabs[{i}]");
        let shown = text(t, &path, "shown")?;
        tabs.push(Tab {
            window: opt_text(t, &path, "window")?,
            tab: text(t, &path, "tab")?,
            shown: Shown::parse(&shown).ok_or(DecodeError::UnknownShown(shown))?,
        });
    }

    let mut pulses = Vec::new();
    for (i, p) in list(&v, root, "pulses")?.iter().enumerate() {
        let path = format!("pulses[{i}]");
        pulses.push(Pulse {
            terminal: text(p, &path, "terminal")?,
            window: opt_text(p, &path, "window")?,
            tab: opt_text(p, &path, "tab")?,
            group: opt_text(p, &path, "group")?,
        });
    }

    // The one list a snapshot may be without: it is newer than the rest, and
    // a pane whose terminal is not listed is drawn as an ordinary one.
    let mut terminals = Vec::new();
    if v.get("terminals").is_some() {
        for (i, t) in list(&v, root, "terminals")?.iter().enumerate() {
            let path = format!("terminals[{i}]");
            let shown = text(t, &path, "shown")?;
            let pane = match t.get("pane") {
                None => None,
                Some(_) => {
                    let name = text(t, &path, "pane")?;
                    Some(Pane::parse(&name).ok_or(DecodeError::UnknownValue(format!("{path}.pane={name}")))?)
                }
            };
            let bar = match t.get("bar") {
                None => None,
                Some(b) => {
                    let at = format!("{path}.bar");
                    let name = text(b, &at, "shown")?;
                    Some(Bar {
                        shown: BarShown::parse(&name).ok_or(DecodeError::UnknownValue(format!("{at}.shown={name}")))?,
                        text: text(b, &at, "text")?,
                    })
                }
            };
            terminals.push(Terminal {
                id: text(t, &path, "id")?,
                title: text(t, &path, "title")?,
                shown: Shown::parse(&shown).ok_or(DecodeError::UnknownShown(shown))?,
                text: text(t, &path, "text")?,
                pane,
                bar,
                who: match t.get("who") {
                    None => None,
                    Some(w) => {
                        let at = format!("{path}.who");
                        let is = text(w, &at, "is")?;
                        Some(Who {
                            is: WhoIs::parse(&is).ok_or(DecodeError::UnknownValue(format!("{at}.is={is}")))?,
                            role: opt_text(w, &at, "role")?,
                            cli: opt_text(w, &at, "cli")?,
                            session: opt_text(w, &at, "session")?,
                            opened_by: opt_text(w, &at, "opened_by")?,
                        })
                    }
                },
            });
        }
    }

    let mut ungrouped = Vec::new();
    if v.get("ungrouped").is_some() {
        for (i, one) in list(&v, root, "ungrouped")?.iter().enumerate() {
            ungrouped.push(crate::lone::lone(one, &format!("ungrouped[{i}]"))?);
        }
    }

    let mut supervisor_roles = Vec::new();
    if v.get("supervisor_roles").is_some() {
        for (i, r) in list(&v, root, "supervisor_roles")?.iter().enumerate() {
            let path = format!("supervisor_roles[{i}]");
            supervisor_roles.push(SupervisorRole { key: text(r, &path, "key")?, name: text(r, &path, "name")? });
        }
    }
    let choose_supervisor_role = match v.get("choose_supervisor_role") {
        None => false,
        Some(_) => boolean(&v, root, "choose_supervisor_role")?,
    };

    Ok(Snapshot {
        rev: int(&v, root, "rev")?,
        now_ms: int(&v, root, "now_ms")?,
        needs_me: int(&v, root, "needs_me")?,
        groups_needing_me: int(&v, root, "groups_needing_me")?,
        groups_other: int(&v, root, "groups_other")?,
        header_waiting: header(&v, "header_waiting")?,
        header_quiet: header(&v, "header_quiet")?,
        open_on: opt_text(&v, root, "open_on")?,
        groups,
        tabs,
        pulses,
        quota: match v.get("quota") {
            None => None,
            Some(q) => Some(crate::quota::decode(q, "quota")?),
        },
        terminals,
        ungrouped,
        supervisor_roles,
        choose_supervisor_role,
    })
}
