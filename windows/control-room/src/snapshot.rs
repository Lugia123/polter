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
    pub waited_min: Option<u64>,
    pub reason: Reason,
    pub more: u64,
    pub same_as: Option<String>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub from_ms: u64,
    pub to_ms: u64,
    pub ongoing: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lane {
    pub name: String,
    pub spans: Vec<Span>,
}

/// "Kept you waiting today". Wall clock throughout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Band {
    pub start_ms: u64,
    pub start_label: String,
    pub now_ms: u64,
    pub total_min: u64,
    pub lanes: Vec<Lane>,
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
    /// Already in the order to draw them.
    pub groups: Vec<Group>,
    /// Every window tab the core has placed, each with its glyph.
    pub tabs: Vec<Tab>,
    pub pulses: Vec<Pulse>,
    pub band: Band,
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
}

type Res<T> = Result<T, DecodeError>;

fn field<'a>(v: &'a Value, path: &str, key: &str) -> Res<&'a Value> {
    v.get(key).ok_or_else(|| DecodeError::Field(format!("{path}.{key}")))
}

fn int(v: &Value, path: &str, key: &str) -> Res<u64> {
    match field(v, path, key)? {
        Value::Int(n) => Ok(*n),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

fn opt_int(v: &Value, path: &str, key: &str) -> Res<Option<u64>> {
    match field(v, path, key)? {
        Value::Null => Ok(None),
        Value::Int(n) => Ok(Some(*n)),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

fn boolean(v: &Value, path: &str, key: &str) -> Res<bool> {
    match field(v, path, key)? {
        Value::Bool(b) => Ok(*b),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

fn text(v: &Value, path: &str, key: &str) -> Res<String> {
    match field(v, path, key)? {
        Value::Str(s) => Ok(s.clone()),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

fn opt_text(v: &Value, path: &str, key: &str) -> Res<Option<String>> {
    match field(v, path, key)? {
        Value::Null => Ok(None),
        Value::Str(s) => Ok(Some(s.clone())),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

fn list<'a>(v: &'a Value, path: &str, key: &str) -> Res<&'a [Value]> {
    match field(v, path, key)? {
        Value::Arr(items) => Ok(items),
        _ => Err(DecodeError::Field(format!("{path}.{key}"))),
    }
}

fn group(v: &Value, path: &str) -> Res<Group> {
    let shown = text(v, path, "shown")?;
    let reason = field(v, path, "reason")?;
    let attention = field(v, path, "attention")?;
    let at = format!("{path}.attention");
    Ok(Group {
        name: text(v, path, "name")?,
        needs_me: boolean(v, path, "needs_me")?,
        unseen: boolean(v, path, "unseen")?,
        shown: Shown::parse(&shown).ok_or(DecodeError::UnknownShown(shown))?,
        text: text(v, path, "text")?,
        waited_min: opt_int(v, path, "waited_min")?,
        reason: Reason {
            from: text(reason, &format!("{path}.reason"), "from")?,
            text: text(reason, &format!("{path}.reason"), "text")?,
        },
        more: int(v, path, "more")?,
        same_as: opt_text(v, path, "same_as")?,
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

    let b = field(&v, root, "band")?;
    let mut lanes = Vec::new();
    for (i, l) in list(b, "band", "lanes")?.iter().enumerate() {
        let path = format!("band.lanes[{i}]");
        let mut spans = Vec::new();
        for (j, s) in list(l, &path, "spans")?.iter().enumerate() {
            let sp = format!("{path}.spans[{j}]");
            spans.push(Span {
                from_ms: int(s, &sp, "from_ms")?,
                to_ms: int(s, &sp, "to_ms")?,
                ongoing: boolean(s, &sp, "ongoing")?,
            });
        }
        lanes.push(Lane { name: text(l, &path, "name")?, spans });
    }

    Ok(Snapshot {
        rev: int(&v, root, "rev")?,
        now_ms: int(&v, root, "now_ms")?,
        needs_me: int(&v, root, "needs_me")?,
        groups_needing_me: int(&v, root, "groups_needing_me")?,
        groups_other: int(&v, root, "groups_other")?,
        groups,
        tabs,
        pulses,
        band: Band {
            start_ms: int(b, "band", "start_ms")?,
            start_label: text(b, "band", "start_label")?,
            now_ms: int(b, "band", "now_ms")?,
            total_min: int(b, "band", "total_min")?,
            lanes,
        },
    })
}
