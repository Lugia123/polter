//! How much of each account's allowance is used: the block at the bottom of
//! the group list (`dev-docs/poltergeist/control-room.md`, 3.6), read from
//! the core's snapshot and nothing more. `src/poltergeist/quota.zig` says
//! the shape.
//!
//! **Everything here was decided by the core**: which account is opened out
//! and which is a number in the one line, whether a number is old, whether
//! its window has come round again, whether a way out is named, how the
//! moment it comes back is said. There is no percentage in this file to
//! compare one with, on purpose.
//!
//! A word this does not know is an error, like every other word in the
//! snapshot. **Not drawn yet**: this crate reads the block and says how
//! high it is; the Windows host does not show it.

use crate::json::Value;
use crate::look;
use crate::snapshot::{self as snap, DecodeError};

type Res<T> = Result<T, DecodeError>;

macro_rules! words {
    ($(#[$doc:meta])* $name:ident { $($variant:ident => $word:literal),+ $(,)? }) => {
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum $name { $($variant),+ }

        impl $name {
            /// The core's spelling.
            pub fn name(self) -> &'static str {
                match self { $($name::$variant => $word),+ }
            }

            fn parse(s: String) -> Res<$name> {
                [$($name::$variant),+]
                    .into_iter()
                    .find(|v| v.name() == s)
                    .ok_or(DecodeError::UnknownValue(s))
            }
        }
    };
}

words!(
    /// Whose allowance.
    Family { Claude => "claude", Codex => "codex" }
);
words!(
    /// Which window of it.
    Span { FiveHour => "five_hour", SevenDay => "seven_day", Month => "month", Other => "other" }
);
words!(
    /// An account at the limit line, or with nothing left.
    Level { Near => "near", Out => "out" }
);
words!(
    /// How the moment an allowance comes back is said: so many from now,
    /// or the moment itself, with or without its day.
    WhenForm { Minutes => "minutes", Hours => "hours", Days => "days", Clock => "clock", Date => "date" }
);
words!(AgoUnit { Hours => "hours", Days => "days" });
words!(
    /// An account in the one line.
    State { Fresh => "fresh", Stale => "stale", Recovered => "recovered", Unreadable => "unreadable" }
);
words!(
    /// What the left of the one line says.
    Label { Used => "used", NoneYet => "none_yet" }
);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct When {
    pub form: WhenForm,
    pub n: u64,
}

/// How old a number is, once the core says it is old.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ago {
    pub unit: AgoUnit,
    pub n: u64,
}

/// One window of an account, for a tooltip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Window {
    pub span: Span,
    pub used: u64,
    /// False once its reset has passed.
    pub live: bool,
    pub resets_ms: u64,
}

/// An account opened out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    pub family: Family,
    pub level: Level,
    pub span: Span,
    pub used: u64,
    /// Wall clock.
    pub resets_ms: u64,
    pub when: When,
    pub stale: Option<Ago>,
    /// An account that has room, when the core names one.
    pub way_out: Option<Family>,
    pub at_ms: u64,
    pub windows: Vec<Window>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub family: Family,
    pub state: State,
    pub used: Option<u64>,
    pub span: Option<Span>,
    pub stale: Option<Ago>,
    pub at_ms: Option<u64>,
    pub windows: Vec<Window>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub label: Label,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Quota {
    pub alerts: Vec<Alert>,
    /// None when every account is opened out.
    pub line: Option<Line>,
}

fn ago(v: &Value, path: &str) -> Res<Option<Ago>> {
    let a = snap::field(v, path, "stale")?;
    if *a == Value::Null {
        return Ok(None);
    }
    let at = format!("{path}.stale");
    Ok(Some(Ago { unit: AgoUnit::parse(snap::text(a, &at, "unit")?)?, n: snap::int(a, &at, "n")? }))
}

fn windows(v: &Value, path: &str) -> Res<Vec<Window>> {
    let mut out = Vec::new();
    for (i, w) in snap::list(v, path, "windows")?.iter().enumerate() {
        let at = format!("{path}.windows[{i}]");
        out.push(Window {
            span: Span::parse(snap::text(w, &at, "span")?)?,
            used: snap::int(w, &at, "used")?,
            live: snap::boolean(w, &at, "live")?,
            resets_ms: snap::int(w, &at, "resets_ms")?,
        });
    }
    Ok(out)
}

/// The `quota` object of a snapshot.
pub fn decode(v: &Value, path: &str) -> Res<Quota> {
    let mut alerts = Vec::new();
    for (i, a) in snap::list(v, path, "alerts")?.iter().enumerate() {
        let at = format!("{path}.alerts[{i}]");
        let when = snap::field(a, &at, "when")?;
        let when_at = format!("{at}.when");
        alerts.push(Alert {
            family: Family::parse(snap::text(a, &at, "family")?)?,
            level: Level::parse(snap::text(a, &at, "level")?)?,
            span: Span::parse(snap::text(a, &at, "span")?)?,
            used: snap::int(a, &at, "used")?,
            resets_ms: snap::int(a, &at, "resets_ms")?,
            when: When {
                form: WhenForm::parse(snap::text(when, &when_at, "form")?)?,
                n: snap::int(when, &when_at, "n")?,
            },
            stale: ago(a, &at)?,
            way_out: snap::opt_text(a, &at, "way_out")?.map(Family::parse).transpose()?,
            at_ms: snap::int(a, &at, "at_ms")?,
            windows: windows(a, &at)?,
        });
    }

    let line = snap::field(v, path, "line")?;
    let line = if *line == Value::Null {
        None
    } else {
        let at = format!("{path}.line");
        let mut entries = Vec::new();
        for (i, e) in snap::list(line, &at, "entries")?.iter().enumerate() {
            let at = format!("{at}.entries[{i}]");
            entries.push(Entry {
                family: Family::parse(snap::text(e, &at, "family")?)?,
                state: State::parse(snap::text(e, &at, "state")?)?,
                used: snap::opt_int(e, &at, "used")?,
                span: snap::opt_text(e, &at, "span")?.map(Span::parse).transpose()?,
                stale: ago(e, &at)?,
                at_ms: snap::opt_int(e, &at, "at_ms")?,
                windows: windows(e, &at)?,
            });
        }
        Some(Line { label: Label::parse(snap::text(line, &at, "label")?)?, entries })
    };

    Ok(Quota { alerts, line })
}

/// How high the block is and where its parts start, top to bottom, in the
/// block's own points. Sizes are `look::quota`'s; this is only the adding
/// up, the same as the macOS host's `ControlRoomQuotaLayout`.
#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    /// One opened-out account each: where it starts, how high it is, and
    /// whether the way out is written under its bar.
    pub parts: Vec<(f64, f64, bool)>,
    /// Where the one line starts; none when there is no line.
    pub line_y: Option<f64>,
    pub height: f64,
}

pub fn part_height(note: bool) -> f64 {
    use look::quota as q;
    let mut h = q::ALERT_PADDING_TOP + q::ALERT_TITLE_HEIGHT + q::BAR_SPACE_ABOVE + q::BAR_HEIGHT + q::BAR_SPACE_BELOW;
    if note {
        h += q::NOTE_LINE_HEIGHT + q::NOTE_PADDING_BOTTOM;
    }
    h + q::ALERT_PADDING_BOTTOM
}

pub fn layout(quota: &Quota) -> Layout {
    let mut y = look::line::HAIRLINE + look::quota::SEPARATOR_SPACE_BELOW;
    let mut parts = Vec::new();
    for alert in &quota.alerts {
        // The core says whether there is a way out; none is looked for.
        let note = alert.way_out.is_some();
        let h = part_height(note);
        parts.push((y, h, note));
        y += h;
    }
    let line_y = quota.line.as_ref().map(|_| {
        let at = y;
        y += look::quota::LINE_HEIGHT;
        at
    });
    Layout { parts, line_y, height: y + look::quota::PADDING_BOTTOM }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json;

    const FIXTURE: &str = include_str!("../../../src/poltergeist/testdata/control_snapshot.json");

    fn fixture() -> Quota {
        crate::snapshot::decode(FIXTURE).expect("the fixture reads").quota.expect("and has a quota")
    }

    #[test]
    fn the_cores_fixture_is_one_account_opened_out_and_one_in_the_line() {
        let q = fixture();
        assert_eq!(q.alerts.len(), 1);
        let a = &q.alerts[0];
        assert_eq!((a.family, a.level, a.span, a.used), (Family::Claude, Level::Near, Span::FiveHour, 92));
        assert_eq!(a.when, When { form: WhenForm::Minutes, n: 40 });
        assert_eq!(a.way_out, None);
        assert_eq!(a.windows.len(), 2);
        let line = q.line.expect("a line");
        assert_eq!(line.label, Label::Used);
        assert_eq!(line.entries.len(), 1);
        assert_eq!((line.entries[0].family, line.entries[0].state, line.entries[0].used), (Family::Codex, State::Fresh, Some(20)));
    }

    #[test]
    fn a_word_this_build_does_not_know_is_not_read() {
        for (known, odd) in [
            ("\"level\": \"near\"", "\"level\": \"nearly\""),
            ("\"form\": \"minutes\"", "\"form\": \"fortnights\""),
            ("\"state\": \"fresh\"", "\"state\": \"minty\""),
            ("\"label\": \"used\"", "\"label\": \"spent\""),
            ("\"family\": \"codex\"", "\"family\": \"abacus\""),
        ] {
            let cut = FIXTURE.replace(known, odd);
            assert_ne!(cut, FIXTURE, "the fixture no longer has {known}");
            assert!(matches!(crate::snapshot::decode(&cut), Err(DecodeError::UnknownValue(_))), "{odd} was read");
        }
    }

    #[test]
    fn a_snapshot_with_no_allowance_in_it_has_none_and_still_reads() {
        let cut = FIXTURE.replace("\"quota\": {", "\"not_quota\": {");
        assert_ne!(cut, FIXTURE);
        assert_eq!(crate::snapshot::decode(&cut).expect("still a snapshot").quota, None);
    }

    #[test]
    fn the_block_is_as_high_as_the_design_drew_it() {
        // One account close and one line: 88.5.
        assert_eq!(layout(&fixture()).height, 88.5);

        let read = |text: &str| decode(&json::parse(text).expect("json"), "quota").expect("a quota");
        let none = read(r#"{"alerts":[],"line":{"label":"none_yet","entries":[]}}"#);
        assert_eq!(layout(&none).height, 38.5);

        let mut out = fixture();
        out.alerts[0].level = Level::Out;
        out.alerts[0].way_out = Some(Family::Codex);
        assert_eq!(layout(&out).height, 112.5);
        // Used up, and no way out named: nothing is written under the bar,
        // whatever the line beside it holds.
        out.alerts[0].way_out = None;
        assert_eq!(layout(&out).height, 88.5);

        out.line = None;
        let l = layout(&out);
        assert_eq!((l.line_y, l.height), (None, 60.5));
    }
}
