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

    fn parse(s: &str) -> Option<Shown> {
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

    fn parse(s: &str) -> Option<WaiterIs> {
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

    fn parse(s: &str) -> Option<Form> {
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

    fn parse(s: &str) -> Option<Cut> {
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub rev: u64,
    pub now_ms: u64,
    /// Terminals waiting, each once: the taskbar badge and notifications.
    pub needs_me: u64,
    /// Rows waiting: "N groups are waiting for you".
    pub groups_needing_me: u64,
    pub groups_other: u64,
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
    })
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

    Ok(Snapshot {
        rev: int(&v, root, "rev")?,
        now_ms: int(&v, root, "now_ms")?,
        needs_me: int(&v, root, "needs_me")?,
        groups_needing_me: int(&v, root, "groups_needing_me")?,
        groups_other: int(&v, root, "groups_other")?,
        open_on: opt_text(&v, root, "open_on")?,
        groups,
        tabs,
        pulses,
        quota: match v.get("quota") {
            None => None,
            Some(q) => Some(crate::quota::decode(q, "quota")?),
        },
    })
}
