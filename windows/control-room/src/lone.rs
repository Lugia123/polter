//! Terminals that are in no group and have a row of their own: the
//! snapshot's `ungrouped` (`control-room.md`, 4.6).
//!
//! A supervisor that has made no group yet, a worker somebody minds outside
//! any group, an agent nobody minds. Each is in `needs_me` -- the number on
//! the taskbar and the Dock -- and in neither count of groups, so a list
//! that draws only groups shows fewer rows than that number says are
//! waiting. Which terminals these are, and what each says, is the core's;
//! this reads it and decides nothing.
//!
//! **This is the reading.** What becomes of them is `list::List`: each is a
//! row after the groups' rows, in the section its own `needs_me` says, as
//! the macOS host has it (`ControlRoomList.init(snapshot:)`), and the panel
//! draws it like any other row. Before task 1471 the Windows panel did not:
//! an agent in no group could wait for an approval and the control room
//! showed nothing of it.

use crate::json::{self, Value};
use crate::snapshot::{boolean, field, fix_of, int, list, opt_int, opt_text, text, Cut, DecodeError, Fix, Form, Shown, Waiter, WaiterIs, What};

/// One terminal on its own: what a group's row says, about one terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lone {
    /// The terminal, as the core writes its id.
    pub id: String,
    pub title: String,
    pub needs_me: bool,
    pub unseen: bool,
    pub shown: Shown,
    /// The words beside the glyph: the core's English msgid as decoded,
    /// the person's language after [`crate::snapshot::Snapshot::translate_words`].
    pub text: String,
    pub waiter: Waiter,
    pub what: What,
    /// What an act on the row hands back, as on a group's row.
    pub terminal: Option<String>,
    pub since_ms: u64,
    pub event_ms: Option<u64>,
    /// The "Fix" button, as on a group's row.
    pub fix: Fix,
}

impl Lone {
    /// The row's identity in a list. A group's name is letters, digits and
    /// hyphens, so nothing with a colon in it is one -- and a group may be
    /// named exactly what a terminal's id looks like.
    pub fn row_id(&self) -> String {
        row_id(&self.id)
    }

    /// Which of the list's two sections it goes in: the same test a
    /// group's row is put by.
    pub fn section(&self) -> &'static str {
        if self.needs_me { "waiting" } else { "quiet" }
    }
}

pub fn row_id(terminal: &str) -> String {
    format!("terminal:{terminal}")
}

/// The terminal the right-hand side shows for the row `row`, when that row
/// is one of these: the terminal itself.
pub fn shown_for<'a>(rows: &'a [Lone], row: &str) -> Option<&'a str> {
    rows.iter().find(|one| one.row_id() == row).map(|one| one.id.as_str())
}

/// The snapshot's `ungrouped`, in the core's order.
pub fn decode(json_text: &str) -> Result<Vec<Lone>, DecodeError> {
    let v = json::parse(json_text).map_err(DecodeError::Json)?;
    let mut out = Vec::new();
    for (i, one) in list(&v, "snapshot", "ungrouped")?.iter().enumerate() {
        out.push(lone(one, &format!("ungrouped[{i}]"))?);
    }
    Ok(out)
}

pub(crate) fn lone(v: &Value, path: &str) -> Result<Lone, DecodeError> {
    let shown = text(v, path, "shown")?;
    let attention = field(v, path, "attention")?;
    let at = format!("{path}.attention");
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
    Ok(Lone {
        id: text(v, path, "id")?,
        title: text(v, path, "title")?,
        needs_me: boolean(v, path, "needs_me")?,
        unseen: boolean(v, path, "unseen")?,
        // A glyph this build does not know is an error, never a blank.
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
            say: crate::snapshot::say_of(what, &what_at)?,
        },
        terminal: opt_text(attention, &at, "terminal")?,
        since_ms: int(attention, &at, "since_ms")?,
        event_ms: opt_int(attention, &at, "event_ms")?,
        fix: fix_of(v, path)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Embedded at compile time, not read at run time: a test binary built
    /// on the Mac and run on the Windows machine has no source tree beside it.
    fn fixture() -> String {
        include_str!("../../../src/poltergeist/testdata/control_snapshot.json").to_string()
    }

    #[test]
    fn the_cores_fixture_has_one_terminal_waiting_in_no_group() {
        let rows = decode(&fixture()).unwrap();
        assert_eq!(rows.len(), 1);
        let one = &rows[0];
        assert_eq!((one.id.as_str(), one.title.as_str()), ("0x00000000000000c1", "zsh — ~/work"));
        assert!(one.needs_me && !one.unseen);
        assert_eq!(one.section(), "waiting");
        assert_eq!(one.shown, Shown::NeedsYou);
        assert_eq!(one.text, "Awaiting approval");
        assert_eq!(one.waiter.is, WaiterIs::Terminal);
        assert_eq!(one.what.lines, vec!["git push".to_string()]);
        assert_eq!((one.terminal.as_deref(), one.since_ms, one.event_ms), (Some("0x00000000000000c1"), 5_940_000, Some(5_940_000)));
    }

    #[test]
    fn its_rows_identity_is_not_a_name_a_group_could_have() {
        let rows = decode(&fixture()).unwrap();
        let id = rows[0].row_id();
        assert_eq!(id, "terminal:0x00000000000000c1");
        // What a group's name may hold (`Chat`): lowercase letters, digits,
        // hyphens.
        assert!(id.chars().any(|c| !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')));
        assert_eq!(shown_for(&rows, &id), Some("0x00000000000000c1"));
        // The bare id is not the row, and neither is a group's name.
        assert_eq!(shown_for(&rows, "0x00000000000000c1"), None);
        assert_eq!(shown_for(&rows, "web-app"), None);
    }

    #[test]
    fn one_that_needs_nothing_goes_with_the_quiet_rows() {
        let json = r#"{"ungrouped":[{"id":"0x2","title":"idle","attention":{"terminal":"0x2","since_ms":7,"event_ms":null},
            "needs_me":false,"unseen":true,"shown":"done_unseen","text":"做完了，没看","waiter":{"is":"none","name":""},
            "what":{"form":"none","lines":[],"cut":"none"}}]}"#;
        let rows = decode(json).unwrap();
        assert_eq!(rows[0].section(), "quiet");
        assert!(rows[0].unseen);
        assert_eq!((rows[0].terminal.as_deref(), rows[0].since_ms, rows[0].event_ms), (Some("0x2"), 7, None));
    }

    #[test]
    fn a_glyph_this_build_does_not_know_is_an_error_here_too() {
        let json = r#"{"ungrouped":[{"id":"0x1","title":"t","attention":{"terminal":null,"since_ms":0,"event_ms":null},
            "needs_me":true,"unseen":false,"shown":"sparkles","text":"","waiter":{"is":"terminal","name":""},
            "what":{"form":"none","lines":[],"cut":"none"}}]}"#;
        assert!(matches!(decode(json), Err(DecodeError::UnknownShown(s)) if s == "sparkles"));
        // And a snapshot that lists none at all is one that was cut down,
        // not one with nobody on their own.
        assert!(decode("{}").is_err());
        assert_eq!(decode(r#"{"ungrouped":[]}"#).unwrap(), vec![]);
    }
}
