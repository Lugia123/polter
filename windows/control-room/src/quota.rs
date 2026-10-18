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
//! snapshot. What the block says is here (`alert_title`, `when_text`,
//! `entry_number`, ...), in the macOS host's words
//! (`ControlRoomQuota.swift`); where it is drawn is `scene::build_quota`
//! (task 1755). The macOS host's hover text has no counterpart: this host's
//! control room has no tooltips.

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

// --- what it says (task 1755) -----------------------------------------------
//
// The macOS host's sentences, word for word, with `{}` where its `%@` goes:
// a host passes each through its translation and `list::fill`s it.

pub mod msg {
    use crate::n_;

    pub const FIVE_HOUR: &str = n_("5-hour");
    pub const SEVEN_DAY: &str = n_("7-day");
    pub const MONTH: &str = n_("30-day");
    pub const HOURS_AGO: &str = n_("{} h ago");
    pub const DAYS_AGO: &str = n_("{} d ago");
    pub const USED_LABEL: &str = n_("Allowance used");
    pub const NONE_YET_LABEL: &str = n_("Allowance");
    pub const NONE_YET: &str = n_("No numbers yet");
    pub const RESET: &str = n_("reset");
    pub const UNREADABLE: &str = n_("unreadable");
    /// A number that is old, and how old.
    pub const STALE_NUMBER: &str = n_("{}, {}");
    /// Who, which window, how much.
    pub const NEAR_SPAN: &str = n_("{} {} {} used");
    pub const NEAR: &str = n_("{} {} used");
    pub const OUT_SPAN: &str = n_("{} {} allowance used up");
    pub const OUT: &str = n_("{} allowance used up");
    pub const BACK_IN_MINUTES: &str = n_("back in {} min");
    pub const BACK_IN_HOURS: &str = n_("back in {} h");
    pub const BACK_IN_DAYS: &str = n_("back in {} d");
    pub const BACK_AT: &str = n_("back at {}");
    pub const WAY_OUT: &str = n_("{} has room.");
    /// A moment with its day: the month, the day of the month, the time of
    /// day -- what the macOS host's `MMMdHHmm` gives in English ("Nov 17
    /// at 12:00", measured by `tools/control-room-hosts-agree.py`).
    pub const MOMENT_WITH_DAY: &str = n_("{} {} at {}");
    pub const MONTHS: [&str; 12] = [
        n_("Jan"),
        n_("Feb"),
        n_("Mar"),
        n_("Apr"),
        n_("May"),
        n_("Jun"),
        n_("Jul"),
        n_("Aug"),
        n_("Sep"),
        n_("Oct"),
        n_("Nov"),
        n_("Dec"),
    ];
}

type Tr<'a> = &'a dyn Fn(&str) -> String;

fn fill_all(template: &str, args: &[&str]) -> String {
    args.iter().fold(template.to_string(), |said, arg| crate::list::fill(&said, arg))
}

/// The products' own names, the same in every language.
pub fn name(family: Family) -> &'static str {
    match family {
        Family::Claude => "Claude",
        Family::Codex => "Codex",
    }
}

/// Which window, as the person calls it; none for one with no name.
pub fn span_text(span: Span, tr: Tr) -> Option<String> {
    match span {
        Span::FiveHour => Some(tr(msg::FIVE_HOUR)),
        Span::SevenDay => Some(tr(msg::SEVEN_DAY)),
        Span::Month => Some(tr(msg::MONTH)),
        Span::Other => None,
    }
}

pub fn ago_text(ago: Ago, tr: Tr) -> String {
    let template = match ago.unit {
        AgoUnit::Hours => msg::HOURS_AGO,
        AgoUnit::Days => msg::DAYS_AGO,
    };
    crate::list::fill(&tr(template), &ago.n.to_string())
}

/// The left of the one line.
pub fn label_text(label: Label, tr: Tr) -> String {
    tr(match label {
        Label::Used => msg::USED_LABEL,
        Label::NoneYet => msg::NONE_YET_LABEL,
    })
}

/// What an account says after its name in the one line.
pub fn entry_value(entry: &Entry, tr: Tr) -> String {
    match entry.state {
        State::Fresh | State::Stale => entry.used.map(|u| format!("{u}%")).unwrap_or_default(),
        State::Recovered => tr(msg::RESET),
        State::Unreadable => tr(msg::UNREADABLE),
    }
}

/// What follows an account's name in the one line: its number, and how
/// old the number is when the core says it is old.
pub fn entry_number(entry: &Entry, tr: Tr) -> String {
    let value = entry_value(entry, tr);
    match entry.stale {
        None => value,
        Some(stale) => fill_all(&tr(msg::STALE_NUMBER), &[&value, &ago_text(stale, tr)]),
    }
}

/// The first line of an opened-out account.
pub fn alert_title(alert: &Alert, tr: Tr) -> String {
    let who = name(alert.family);
    // The sign goes in with the number, as on the macOS host.
    let percent = format!("{}%", alert.used);
    match (alert.level, span_text(alert.span, tr)) {
        (Level::Near, Some(span)) => fill_all(&tr(msg::NEAR_SPAN), &[who, &span, &percent]),
        (Level::Near, None) => fill_all(&tr(msg::NEAR), &[who, &percent]),
        (Level::Out, Some(span)) => fill_all(&tr(msg::OUT_SPAN), &[who, &span]),
        (Level::Out, None) => fill_all(&tr(msg::OUT), &[who]),
    }
}

/// When an opened-out account comes back, in the form the core chose.
/// `offset_ms` is the person's clock against UTC.
pub fn when_text(alert: &Alert, offset_ms: i64, tr: Tr) -> String {
    let n = alert.when.n.to_string();
    match alert.when.form {
        WhenForm::Minutes => crate::list::fill(&tr(msg::BACK_IN_MINUTES), &n),
        WhenForm::Hours => crate::list::fill(&tr(msg::BACK_IN_HOURS), &n),
        WhenForm::Days => crate::list::fill(&tr(msg::BACK_IN_DAYS), &n),
        WhenForm::Clock | WhenForm::Date => {
            let moment = moment_text(alert.resets_ms, alert.when.form == WhenForm::Date, offset_ms, tr);
            crate::list::fill(&tr(msg::BACK_AT), &moment)
        }
    }
}

/// The way out, when the core names one.
pub fn way_out_text(alert: &Alert, tr: Tr) -> Option<String> {
    alert.way_out.map(|f| crate::list::fill(&tr(msg::WAY_OUT), name(f)))
}

/// A moment on the person's clock: the time of day, 24-hour, and the day
/// before it when the core asks for the day.
pub fn moment_text(ms: u64, with_day: bool, offset_ms: i64, tr: Tr) -> String {
    let local = ms as i64 + offset_ms;
    let days = local.div_euclid(86_400_000);
    let of_day = local.rem_euclid(86_400_000) / 60_000;
    let time = format!("{:02}:{:02}", of_day / 60, of_day % 60);
    if !with_day {
        return time;
    }
    let (_, month, day) = civil(days);
    fill_all(&tr(msg::MOMENT_WITH_DAY), &[&tr(msg::MONTHS[month as usize - 1]), &day.to_string(), &time])
}

/// The year, month (1-12) and day of `days` since 1970-01-01.
fn civil(days: i64) -> (i64, u32, u32) {
    // Howard Hinnant's days-to-civil.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(month <= 2), month, day)
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
    fn a_moment_is_said_on_the_persons_clock_with_its_day_when_asked() {
        // Task 1755. 2023-11-14 12:00 UTC.
        let same = |t: &str| t.to_string();
        let noon: u64 = 1_699_963_200_000;
        assert_eq!(moment_text(noon, false, 0, &same), "12:00");
        assert_eq!(moment_text(noon, true, 0, &same), "Nov 14 at 12:00");
        // Eight hours east is the evening of the same day; a minute before
        // midnight UTC, five hours east, is the next day.
        assert_eq!(moment_text(noon, true, 8 * 3_600_000, &same), "Nov 14 at 20:00");
        assert_eq!(moment_text(1_700_006_340_000, true, 5 * 3_600_000, &same), "Nov 15 at 04:59");
        // A leap day, and a moment west of UTC that falls on the day before.
        assert_eq!(moment_text(1_709_164_800_000, true, 0, &same), "Feb 29 at 00:00");
        assert_eq!(moment_text(1_709_164_800_000, true, -3_600_000, &same), "Feb 28 at 23:00");
        // The month's name goes through the translation.
        let zh = |t: &str| if t == "Nov" { "11月".to_string() } else { t.to_string() };
        assert_eq!(moment_text(noon, true, 0, &zh), "11月 14 at 12:00");
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
