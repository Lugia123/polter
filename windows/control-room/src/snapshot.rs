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

/// The "Fix" button on a card that reads "Failed" (task 1560,
/// `ControlFix.zig`): not there, there, or pressed and greyed until the card
/// changes. Which is the core's to say; a host draws it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fix {
    None,
    Offered,
    Sent,
}

impl Fix {
    pub const ALL: [Fix; 3] = [Fix::None, Fix::Offered, Fix::Sent];

    pub fn name(self) -> &'static str {
        match self {
            Fix::None => "none",
            Fix::Offered => "offered",
            Fix::Sent => "sent",
        }
    }

    pub(crate) fn parse(s: &str) -> Option<Fix> {
        Fix::ALL.into_iter().find(|v| v.name() == s)
    }
}

/// A row's `fix`: none where a core from before task 1560 wrote none, and
/// a word this build does not know is an error, never a missing button.
pub(crate) fn fix_of(v: &Value, path: &str) -> Res<Fix> {
    if v.get("fix").is_none() {
        return Ok(Fix::None);
    }
    let word = text(v, path, "fix")?;
    Fix::parse(&word).ok_or(DecodeError::UnknownValue(format!("{path}.fix={word}")))
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
    /// Set when `lines` is one of the core's own sentences (task 1525):
    /// `lines` then holds it in English, and
    /// [`Snapshot::translate_words`] puts it in the person's language.
    pub say: Option<Say>,
}

/// One of the core's own sentences ("Screen still for {1} min"): the
/// English msgid with `{1}`, `{2}` where `args` go (`ControlRoom.Say`).
/// The arguments are as they go in -- minutes in decimal, an agent's own
/// words -- and none is translated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Say {
    pub key: String,
    pub template: String,
    pub args: Vec<String>,
}

/// `template` with `{1}`..`{9}` replaced by `args`; a placeholder with no
/// argument is left as written. The same few lines as the core's
/// `Say.fill` and the mac app's, so a translation that puts the arguments
/// the other way round, or drops one, is drawn and does not fail.
pub fn fill(template: &str, args: &[String]) -> String {
    let b = template.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    let mut start = 0;
    while i < b.len() {
        if b[i] == b'{' && i + 2 < b.len() && b[i + 2] == b'}' && (b'1'..=b'9').contains(&b[i + 1]) {
            let n = (b[i + 1] - b'1') as usize;
            if let Some(arg) = args.get(n) {
                out.push_str(&template[start..i]);
                out.push_str(arg);
                i += 3;
                start = i;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&template[start..]);
    out
}

/// `what.say`: absent in a snapshot from before the core said it, null
/// when the line is not the core's own.
pub(crate) fn say_of(what: &Value, what_at: &str) -> Res<Option<Say>> {
    say_named(what, what_at, "say")
}

/// A `Say` under `name` in `obj`: absent or null is none.
pub(crate) fn say_named(obj: &Value, obj_at: &str, name: &str) -> Res<Option<Say>> {
    let Some(v) = obj.get(name) else { return Ok(None) };
    if matches!(v, Value::Null) {
        return Ok(None);
    }
    let at = format!("{obj_at}.{name}");
    let mut args = Vec::new();
    for (i, a) in list(v, &at, "args")?.iter().enumerate() {
        match a {
            Value::Str(s) => args.push(s.clone()),
            _ => return Err(DecodeError::Field(format!("{at}.args[{i}]"))),
        }
    }
    Ok(Some(Say { key: text(v, &at, "key")?, template: text(v, &at, "template")?, args }))
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
    /// `can_resume` and `why` for each CLI a role here can be started in
    /// (#1677); `can_resume` and `why` above are the one for `cli`. Empty
    /// in a snapshot from before the core said.
    pub by_cli: Vec<CliResume>,
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
    /// The terminal one is being started in (`"0x…"`), while starting or
    /// after it failed.
    pub terminal: Option<String>,
    /// Starting, and the CLI in its tab is waiting for the person to answer
    /// a question there -- Antigravity's folder trust box (task 1746).
    /// Polter never answers it: the right side says so and offers to go to
    /// that tab. False from a core before it said.
    pub asking: bool,
    /// The role it is started in unless the person picks another.
    pub role: Option<String>,
    /// Where it is started unless the person picks elsewhere.
    pub cwd: String,
    /// The last supervisor and whether its session is gone on with.
    /// `None` for a snapshot from before the core said it.
    pub last: Option<SupervisorLast>,
    /// Whether the supervisor there was started by hand (task 1635).
    /// `None` for a snapshot from before the core said it.
    pub hookless: Option<Hookless>,
}

/// A supervisor somebody started by typing its command: no hooks, so none
/// of its state reaches Polter (`ControlRoom.zig`, `HooklessOut`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hookless {
    /// none | asking | known | unknown, as the core wrote it.
    pub state: String,
    pub cli_label: Option<String>,
    pub session: bool,
    /// What the supervisor frame's title says of it; `None` for `none`.
    pub note: Option<Say>,
    /// "Let the control room take over?" (task 1635); `None` from a core
    /// before it said.
    pub take_over: Option<TakeOver>,
}

/// What the supervisor's frame offers about taking it over
/// (`ControlRoom.TakeOverOut`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TakeOver {
    /// none | offer | running | failed, as the core wrote it.
    pub state: String,
    /// The question asked before anything is done.
    pub confirm: Option<Say>,
    /// What is happening, or why the last try stopped.
    pub status: Option<Say>,
}

/// A role a supervisor can be started in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupervisorRole {
    pub key: String,
    pub name: String,
    /// The agent CLIs it can be started in here: only those whose plugin
    /// is on, in the role's own order (#1677). Empty for a role none of
    /// whose CLIs is on, and in a snapshot from before the core said.
    pub clis: Vec<RoleCli>,
    /// The CLIs the role is set up for that cannot be started here, and
    /// why (`held_back`, #1677). Empty in a snapshot from before the core
    /// said.
    pub held_back: Vec<HeldBack>,
}

/// Why a CLI a role is set up for is not one it can be started in here.
/// **Two of these are not one**: a plugin that is off is the person's to
/// turn on; one that cannot run here is not fixed by that.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeldWhy {
    /// Its plugin is installed and switched off.
    PluginOff,
    /// Its plugin is on, and its adapter cannot run on this machine.
    CannotRun,
    /// No plugin manages it.
    NoPlugin,
    /// Its plugin is on, its adapter runs, and its adapter says the CLI's
    /// program is not on this machine (task 1744).
    NotInstalled,
}

impl HeldWhy {
    pub const ALL: [HeldWhy; 4] = [HeldWhy::PluginOff, HeldWhy::CannotRun, HeldWhy::NoPlugin, HeldWhy::NotInstalled];

    pub fn name(self) -> &'static str {
        match self {
            HeldWhy::PluginOff => "plugin_off",
            HeldWhy::CannotRun => "cannot_run",
            HeldWhy::NoPlugin => "no_plugin",
            HeldWhy::NotInstalled => "not_installed",
        }
    }

    fn parse(s: &str) -> Option<HeldWhy> {
        Self::ALL.into_iter().find(|v| v.name() == s)
    }
}

/// A CLI a role is set up for and cannot be started in here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldBack {
    pub key: String,
    pub label: Option<String>,
    pub why: HeldWhy,
}

/// One agent CLI a role can be started in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoleCli {
    pub key: String,
    /// What it is called to a person; `None` when the core has no name,
    /// and then the key is what is written (`scene::cli_name`).
    pub label: Option<String>,
}

/// Whether a start in one CLI goes on with the last session
/// (`supervisor.resume_by_cli`, #1677): the core's `resumeOf` for that CLI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliResume {
    pub cli: String,
    pub can: bool,
    pub why: ResumeWhy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub name: String,
    pub needs_me: bool,
    /// The core says nobody has looked at this since it stopped.
    pub unseen: bool,
    pub shown: Shown,
    /// The words beside the glyph: the core's English msgid as decoded,
    /// the person's language after [`Snapshot::translate_words`].
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
    /// The "Fix" button (`Fix`).
    pub fix: Fix,
    /// What the group is for, in the person's words (its "brief"); empty
    /// when it has none.
    pub brief: String,
    /// Kept at the front of its section (task 1659). The core has already
    /// put it there; a host draws the groups in the order given.
    pub pinned: bool,
    /// Its notifications are off, and until when (task 1659).
    pub muted: Option<Muted>,
    /// What deleting it takes with it, for the dialog that asks first.
    pub delete_cost: Option<DeleteCost>,
    /// The directory its record is in: what "Show in Explorer" opens.
    pub record_dir: Option<String>,
    /// The project it is tied to, by name; none when it has none.
    pub project_name: Option<String>,
    /// Its tie to a project and why one was not made (task 1714,
    /// `project-link-interface.md` §2); none from a core before it said.
    pub project: Option<ProjectTie>,
    /// What became of the control room's last ask of its supervisor (task
    /// 1671); none when none was made since the core started, or from a
    /// core before it said.
    pub ask: Option<AskState>,
}

/// A group's tie to a project as the core says it (`ControlRoom.ProjectOut`):
/// the core's own words for the tie and the reason, taken as written by
/// [`crate::project_link`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectTie {
    /// `undecided`, `bound` or `declined`.
    pub tie: String,
    /// Why a tie was not made (`Projects.Why`), `none` when nothing stands
    /// in the way.
    pub why: String,
    /// Whether the host should ask the person now whether to join the
    /// project with the group's name (§2). False from a core before it said.
    pub ask: bool,
}

/// How the control room's last ask of a group's supervisor went (task
/// 1671, `ControlAsk.zig`): the ask's own reply was the first try's, and a
/// retry's end is only ever said here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskState {
    /// The group message the ask was kept as.
    pub seq: u64,
    pub stage: AskStage,
    /// The last refusal's code, as the core names it; none once delivered.
    pub code: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AskStage {
    /// It will be typed again.
    Retrying,
    /// It is in the supervisor's terminal.
    Delivered,
    /// It was not typed, and will not be.
    GaveUp,
}

/// A group whose notifications are off (task 1659).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Muted {
    /// Wall-clock milliseconds when they come back on; none: not until
    /// the person turns them on.
    pub until_ms: Option<u64>,
}

/// What deleting a group takes with it, as the dialog says it and as the
/// delete hands back (`act::Act::DeleteGroup`): the terminals in it, the
/// supervisor counted and the person not, and its tasks not done.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeleteCost {
    pub members: u64,
    pub open_tasks: u64,
}

/// A group put away (task 1659): not in `groups`, nothing waits on it, and
/// it is shown only in the list's last section, newest first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Archived {
    pub name: String,
    pub brief: String,
    /// Wall-clock milliseconds when it was put away.
    pub archived_ms: u64,
    pub record_dir: Option<String>,
    pub delete_cost: Option<DeleteCost>,
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
    /// The words beside the glyph: the core's English msgid as decoded,
    /// the person's language after [`Snapshot::translate_words`].
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
    /// The supervisor this one was opened for as a worker, in this run
    /// (#1498: not who opened it -- a supervisor's own split is not one).
    pub worker_of: Option<String>,
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
    /// The first sweep of old records is waiting for the person, and would
    /// delete this much (task 1511). None when nothing waits, or from a
    /// core that does not say.
    pub retention_waiting_bytes: Option<u64>,
    /// The groups put away (task 1659), newest first.
    pub archived: Vec<Archived>,
}

impl Snapshot {
    /// Put every word beside a glyph into the person's language: a group's,
    /// a terminal's, its pane title's and a lone terminal's (task 1522);
    /// and a row's line, where it is one of the core's own sentences (task
    /// 1525).
    /// The core writes them as English msgids ("Awaiting approval",
    /// "Held"), because it does not know the person's language; this is
    /// where the host says them in it -- once, as the snapshot arrives, so
    /// that what a row measures and what it draws are the same words.
    pub fn translate_words(&mut self, tr: &dyn Fn(&str) -> String) {
        let say = |t: &mut String| {
            if !t.is_empty() {
                *t = tr(t);
            }
        };
        // A line that is one of the core's own sentences, said the same way.
        let sentence = |w: &mut What| {
            if let Some(s) = &w.say {
                w.lines = vec![fill(&tr(&s.template), &s.args)];
            }
        };
        for g in &mut self.groups {
            say(&mut g.text);
            sentence(&mut g.what);
        }
        for t in &mut self.terminals {
            say(&mut t.text);
            if let Some(b) = &mut t.bar {
                say(&mut b.text);
            }
        }
        for l in &mut self.ungrouped {
            say(&mut l.text);
            sentence(&mut l.what);
        }
    }
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
                terminal: opt_text(s, &sp, "terminal")?,
                asking: if s.get("asking").is_some() { boolean(s, &sp, "asking")? } else { false },
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
                            by_cli: match s.get("resume_by_cli") {
                                None => Vec::new(),
                                Some(_) => list(s, &sp, "resume_by_cli")?
                                    .iter()
                                    .enumerate()
                                    .map(|(i, r)| {
                                        let p = format!("{sp}.resume_by_cli[{i}]");
                                        let why = text(r, &p, "why")?;
                                        Ok(CliResume {
                                            cli: text(r, &p, "cli")?,
                                            can: boolean(r, &p, "can")?,
                                            why: ResumeWhy::parse(&why).ok_or(DecodeError::UnknownValue(format!("{p}.why={why}")))?,
                                        })
                                    })
                                    .collect::<Res<Vec<_>>>()?,
                            },
                        })
                    }
                    (None, None) => None,
                    _ => return Err(DecodeError::Field(format!("{sp}.resume"))),
                },
                hookless: match s.get("hookless") {
                    None => None,
                    Some(h) => {
                        let hp = format!("{sp}.hookless");
                        Some(Hookless {
                            state: text(h, &hp, "state")?,
                            cli_label: if h.get("cli_label").is_some() { opt_text(h, &hp, "cli_label")? } else { None },
                            session: boolean(h, &hp, "session")?,
                            note: say_named(h, &hp, "note")?,
                            take_over: match h.get("take_over") {
                                None => None,
                                Some(t) => {
                                    let tp = format!("{hp}.take_over");
                                    Some(TakeOver {
                                        state: text(t, &tp, "state")?,
                                        confirm: say_named(t, &tp, "confirm")?,
                                        status: say_named(t, &tp, "status")?,
                                    })
                                }
                            },
                        })
                    }
                },
            })
        }
    };
    Ok(Group {
        brief: if v.get("brief").is_some() { text(v, path, "brief")? } else { String::new() },
        pinned: if v.get("pinned").is_some() { boolean(v, path, "pinned")? } else { false },
        muted: muted_of(v, path)?,
        delete_cost: delete_cost_of(v, path)?,
        ask: ask_of(v, path)?,
        record_dir: if v.get("record_dir").is_some() { opt_text(v, path, "record_dir")? } else { None },
        project_name: match v.get("project") {
            Some(p) if p.get("name").is_some() => opt_text(p, &format!("{path}.project"), "name")?,
            _ => None,
        },
        project: match v.get("project") {
            Some(p) if p.get("tie").is_some() => {
                let at = format!("{path}.project");
                Some(ProjectTie {
                    tie: text(p, &at, "tie")?,
                    why: if p.get("why").is_some() { text(p, &at, "why")? } else { "none".into() },
                    ask: if p.get("ask").is_some() { boolean(p, &at, "ask")? } else { false },
                })
            }
            _ => None,
        },
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
            say: say_of(what, &what_at)?,
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
        fix: fix_of(v, path)?,
    })
}

/// `muted`: none when it is absent (a core from before task 1659) or null.
fn muted_of(v: &Value, path: &str) -> Res<Option<Muted>> {
    match v.get("muted") {
        None | Some(Value::Null) => Ok(None),
        Some(m) => Ok(Some(Muted { until_ms: opt_int(m, &format!("{path}.muted"), "until_ms")? })),
    }
}

/// `ask`: none when it is absent, null, or in a stage this build does not
/// know -- then the line under the row stays as the ask's reply left it.
fn ask_of(v: &Value, path: &str) -> Res<Option<AskState>> {
    match v.get("ask") {
        None | Some(Value::Null) => Ok(None),
        Some(a) => {
            let at = format!("{path}.ask");
            let stage = match text(a, &at, "state")?.as_str() {
                "retrying" => AskStage::Retrying,
                "delivered" => AskStage::Delivered,
                "gave_up" => AskStage::GaveUp,
                _ => return Ok(None),
            };
            Ok(Some(AskState { seq: int(a, &at, "seq")?, stage, code: opt_text(a, &at, "code")? }))
        }
    }
}

/// `delete_cost`, when the core writes one.
fn delete_cost_of(v: &Value, path: &str) -> Res<Option<DeleteCost>> {
    match v.get("delete_cost") {
        None | Some(Value::Null) => Ok(None),
        Some(c) => {
            let at = format!("{path}.delete_cost");
            Ok(Some(DeleteCost { members: int(c, &at, "members")?, open_tasks: int(c, &at, "open_tasks")? }))
        }
    }
}

/// The groups put away, newest first; none from a core before task 1659.
fn archived_of(v: &Value) -> Res<Vec<Archived>> {
    if v.get("archived").is_none() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for (i, a) in list(v, "snapshot", "archived")?.iter().enumerate() {
        let path = format!("archived[{i}]");
        out.push(Archived {
            name: text(a, &path, "name")?,
            brief: if a.get("brief").is_some() { text(a, &path, "brief")? } else { String::new() },
            archived_ms: int(a, &path, "archived_ms")?,
            record_dir: if a.get("record_dir").is_some() { opt_text(a, &path, "record_dir")? } else { None },
            delete_cost: delete_cost_of(a, &path)?,
        });
    }
    Ok(out)
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
                            worker_of: opt_text(w, &at, "worker_of")?,
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
            let mut clis = Vec::new();
            if r.get("clis").is_some() {
                for (j, c) in list(r, &path, "clis")?.iter().enumerate() {
                    let cp = format!("{path}.clis[{j}]");
                    clis.push(RoleCli { key: text(c, &cp, "key")?, label: opt_text(c, &cp, "label")? });
                }
            }
            let mut held_back = Vec::new();
            if r.get("held_back").is_some() {
                for (j, c) in list(r, &path, "held_back")?.iter().enumerate() {
                    let cp = format!("{path}.held_back[{j}]");
                    let why = text(c, &cp, "why")?;
                    held_back.push(HeldBack {
                        key: text(c, &cp, "key")?,
                        label: opt_text(c, &cp, "label")?,
                        why: HeldWhy::parse(&why).ok_or(DecodeError::UnknownValue(format!("{cp}.why={why}")))?,
                    });
                }
            }
            supervisor_roles.push(SupervisorRole { key: text(r, &path, "key")?, name: text(r, &path, "name")?, clis, held_back });
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
        // Absent from a core older than task 1511: nothing waits.
        retention_waiting_bytes: match v.get("retention_waiting_bytes") {
            None => None,
            Some(_) => opt_int(&v, root, "retention_waiting_bytes")?,
        },
        archived: archived_of(&v)?,
    })
}
