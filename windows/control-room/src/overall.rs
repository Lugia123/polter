//! The `overall` page's group block, read (task 3167; the mac host's
//! `ControlRoomOverall.Group`).
//!
//! **One page, one group.** The performance page asks the core
//! `{"page":"overall","group":…}` -- the same page the overall view reads --
//! and the core sends back only the group it was asked about, so the block
//! this file takes is `groups[0]`. The strip under the history grid draws
//! four parts of that group's memory and a card for its own part.
//!
//! **Everything here is the core's.** The four widths, whether the group's
//! own part is rising, how many tasks it has, how big its record is and
//! which process its chat is all arrive as fields. The host adds nothing
//! up and weighs no slope (`tools/control-room-hosts-do-not-decide.py`):
//! the bar's total is [`Parts::sum_mib`], the four parts' sum, and never
//! `total_mib` beside it (the mac host's rule: pieces that do not add up to
//! their own total are then not something a bar can be drawn from), and
//! "rising" is [`Growth::rising`] as the core wrote it.
//!
//! **Null is a state, not a zero.** `chat_pid` is null when the group has no
//! embedded chat, and `growth.since` is null when it is not rising; both are
//! read as `None` and the card says the sentence that goes with it.

use crate::json::{self, Value};
use crate::reader::{at, join, Reader};
use crate::snapshot::DecodeError;

type Res<T> = Result<T, DecodeError>;

/// The four parts of a group's own cost, in the order the bar draws them
/// and the legend names them (`OverallPage.zig`'s `Parts`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Parts {
    pub supervisor_mib: u64,
    pub workers_mib: u64,
    pub yours_mib: u64,
    pub own_mib: u64,
}

impl Parts {
    /// The four, in the order they are drawn.
    pub fn in_order(&self) -> [u64; 4] {
        [self.supervisor_mib, self.workers_mib, self.yours_mib, self.own_mib]
    }

    /// **The bar's total is the pieces' own sum**, not the `total_mib`
    /// beside them: both are the core's, made in one walk, and a bar whose
    /// pieces over- or under-fill it is then not a shape that can be drawn.
    /// The mac host's `Parts.sumMib` for the same reason.
    pub fn sum_mib(&self) -> u64 {
        self.in_order().iter().sum()
    }
}

/// How a row's memory is moving, as the core weighed it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Growth {
    /// **The core's verdict**: the card is drawn in the warning ink when
    /// this is true, and nothing here weighs a slope.
    pub rising: bool,
    /// MiB an hour, as the core worked it out; negative is possible and
    /// written with a minus by [`rate`], not decided here.
    pub slope_mib_per_h: i64,
    /// When it began rising, on the reader's own clock; null when it is
    /// not rising.
    pub since: Option<String>,
}

/// What the group holds that is not one of its terminals: its embedded
/// chat and the two numbers no process table has.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Own {
    /// The row behind the chat, so a press can point at a process; none
    /// when the group has no chat running.
    pub chat_pid: Option<u64>,
    pub chat_mib: u64,
    pub growth: Growth,
    pub tasks: u64,
    pub tasks_open: u64,
    pub record_bytes: u64,
}

/// One group's own cost, as `OverallPage.zig`'s `Group` writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub group: String,
    /// The core's own total, **not drawn**: the bar's widths come from
    /// [`Parts::sum_mib`] (`Group.total_mib`'s comment in the core says the
    /// four parts sum to it).
    pub total_mib: u64,
    pub parts: Parts,
    pub own: Own,
}

/// The request the strip's numbers come from: the same `overall` page the
/// overall view asks, about one group (the mac host's
/// `ControlRoomOverall.groupRequest`).
pub fn request(group: &str) -> String {
    format!(r#"{{"page":"overall","group":{}}}"#, json::quote(group))
}

/// The group the answer is about: the core sends only the group asked for,
/// so this is `groups[0]`. `Ok(None)` for an answer with no group in it --
/// a page whose core has nothing yet draws no strip, which is not an error.
pub fn decode(text: &str) -> Res<Option<Group>> {
    let v = json::parse(text).map_err(DecodeError::Json)?;
    decode_value(&v)
}

pub fn decode_value(v: &Value) -> Res<Option<Group>> {
    if let Some(Value::Str(e)) = v.get("error") {
        return Err(DecodeError::UnknownValue(format!("error={e}")));
    }
    let mut r = Reader::default();
    let groups = r.list(v, "", "groups");
    let Some(g) = groups.first() else { return Ok(None) };
    let gp = at("groups", 0);
    let group = r.text(g, &gp, "group");
    let total_mib = r.int(g, &gp, "total_mib").unwrap_or(0);
    let parts = match r.obj(g, &gp, "parts") {
        Some(p) => {
            let pp = join(&gp, "parts");
            Parts {
                supervisor_mib: r.int(p, &pp, "supervisor_mib").unwrap_or(0),
                workers_mib: r.int(p, &pp, "workers_mib").unwrap_or(0),
                yours_mib: r.int(p, &pp, "yours_mib").unwrap_or(0),
                own_mib: r.int(p, &pp, "own_mib").unwrap_or(0),
            }
        }
        None => Parts::default(),
    };
    let own = match r.obj(g, &gp, "own") {
        Some(o) => {
            let op = join(&gp, "own");
            let growth = match r.obj(o, &op, "growth") {
                Some(gr) => {
                    let grp = join(&op, "growth");
                    // **`slope_mib_per_h` can be negative**, and this crate's
                    // JSON reads a negative number as a float: the sign is
                    // the core's and is kept here, not clamped.
                    Growth {
                        rising: r.boolean(gr, &grp, "rising").unwrap_or(false),
                        slope_mib_per_h: r.number(gr, &grp, "slope_mib_per_h").unwrap_or(0.0) as i64,
                        since: r.nullable_text(gr, &grp, "since"),
                    }
                }
                None => Growth::default(),
            };
            Own {
                chat_pid: r.nullable_int(o, &op, "chat_pid"),
                chat_mib: r.int(o, &op, "chat_mib").unwrap_or(0),
                growth,
                tasks: r.int(o, &op, "tasks").unwrap_or(0),
                tasks_open: r.int(o, &op, "tasks_open").unwrap_or(0),
                record_bytes: r.int(o, &op, "record_bytes").unwrap_or(0),
            }
        }
        None => Own::default(),
    };
    Ok(Some(Group { group, total_mib, parts, own }))
}

// ------------------------------------------------------------------ numbers

/// MiB as the cards write a size: one decimal of a GB, or whole MB under
/// one (the mac host's `size`). The unit is not a word either host
/// translates.
pub fn size(mib: u64) -> String {
    if mib < 1024 {
        return format!("{mib} MB");
    }
    let tenths = (mib * 10 + 512) / 1024;
    format!("{}.{} GB", tenths / 10, tenths % 10)
}

/// A group's record, which the core counts in bytes: a tenth of a MB,
/// because that is the size these come in.
pub fn record(bytes: u64) -> String {
    let mib = bytes as f64 / 1_048_576.0;
    if mib >= 1024.0 {
        format!("{:.1} GB", mib / 1024.0)
    } else if mib >= 1.0 {
        format!("{:.1} MB", mib)
    } else {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    }
}

/// What an hour gained, with its sign: the core's own `slope_mib_per_h`, so
/// that "↗ +1.3 GB an hour" and "→ +4 MB an hour" are one template and the
/// host writes no minus of its own (the mac host's `rate`).
pub fn rate(slope_mib_per_h: i64) -> String {
    let sign = if slope_mib_per_h < 0 { "\u{2212}" } else { "+" };
    format!("{sign}{}", size(slope_mib_per_h.unsigned_abs()))
}

/// The direction mark while a row is rising (the design's `.pself .up`): **a
/// mark and not a word**, so there is nothing here for a translator.
pub const RISING_MARK: &str = "↗";

/// **One sentence with its arguments, in the catalogue's order.** The
/// templates are the mac host's msgids (`%@` for words, `%d` for numbers),
/// and a translation may reorder them by numbering them (`%1$d`, `%2$@`);
/// a translator who reorders the arguments of "Tasks %d (%d open)" would
/// otherwise get them swapped. `%%` is a literal percent.
pub fn sentence(template: &str, args: &[String]) -> String {
    let b = template.as_bytes();
    let mut out = String::with_capacity(template.len());
    let mut next = 0usize;
    let mut i = 0usize;
    while i < b.len() {
        if b[i] != b'%' {
            let ch = template[i..].chars().next().unwrap_or('\u{fffd}');
            out.push(ch);
            i += ch.len_utf8();
            continue;
        }
        if b.get(i + 1) == Some(&b'%') {
            out.push('%');
            i += 2;
            continue;
        }
        let mut j = i + 1;
        let mut digits = String::new();
        while b.get(j).is_some_and(|c| c.is_ascii_digit()) {
            digits.push(b[j] as char);
            j += 1;
        }
        let numbered = !digits.is_empty() && b.get(j) == Some(&b'$');
        if numbered {
            j += 1;
        }
        match b.get(j) {
            Some(b'@') | Some(b'd') => {
                let index = if numbered {
                    digits.parse::<usize>().ok().and_then(|n| n.checked_sub(1))
                } else {
                    let n = next;
                    next += 1;
                    Some(n)
                };
                if let Some(a) = index.and_then(|n| args.get(n)) {
                    out.push_str(a);
                }
                i = j + 1;
            }
            // A `%` that is not a placeholder: it is text.
            _ => {
                out.push('%');
                i += 1;
            }
        }
    }
    out
}

impl Group {
    /// **The bar's widths for this group**, from the four parts' sum and
    /// never from `total_mib` (the mac host's rule): see [`bar_widths`].
    pub fn bar_widths(&self, width: f64) -> [f64; 4] {
        bar_widths(&self.parts, self.parts.sum_mib(), width)
    }
}

/// The four segments of the bar in a bar `width` points wide, left to
/// right, each its part's share of `total`; **the four fill the
/// bar exactly**, the last ending at its right edge so four roundings
/// cannot leave a hairline of nothing. Four zero widths when there is
/// nothing to divide -- a group that costs nothing is not a group that
/// costs everything (the mac host's `groupBar`).
pub fn bar_widths(p: &Parts, total: u64, width: f64) -> [f64; 4] {
    let parts = p.in_order();
    if total == 0 || width <= 0.0 {
        return [0.0; 4];
    }
    let mut out = [0.0; 4];
    let mut x = 0.0;
    for (i, mib) in parts.iter().enumerate() {
        let w = if i + 1 == parts.len() {
            (width - x).max(0.0)
        } else {
            width * (*mib as f64) / (total as f64)
        };
        out[i] = w;
        x += w;
    }
    out
}

/// What the strip says. **The mac host's words, word for word**, so one
/// catalogue entry serves both hosts (`po/zh_CN.po` carries all of them).
pub mod msg {
    use crate::n_;
    pub const TITLE: &str = n_("This group's cost");
    pub const SUBTITLE: &str = n_("GB, one segment each, width by memory");
    pub const SUPERVISOR: &str = n_("Supervisor");
    pub const WORKERS: &str = n_("Workers");
    pub const YOURS: &str = n_("Your terminals");
    pub const GROUP_ITSELF: &str = n_("The group itself");
    pub const RISING: &str = n_("Rising");
    /// The card's rate line: the mark first, then this template.
    pub const AN_HOUR: &str = n_("%@ an hour");
    pub const CHAT_RISING: &str = n_("Embedded chat %@ · rising since %@");
    pub const CHAT_PID: &str = n_("Embedded chat %@ · process %d");
    pub const NO_CHAT: &str = n_("No embedded chat is running");
    pub const TASKS: &str = n_("Tasks %d (%d open) · Group record %@");
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/core-overall-group.json"));

    #[test]
    fn the_group_is_read_with_the_fields_the_strip_draws() {
        let g = decode(FIXTURE).unwrap().expect("one group");
        assert_eq!(g.group, "web-app");
        assert_eq!(g.total_mib, 512);
        assert_eq!(g.parts, Parts { supervisor_mib: 120, workers_mib: 200, yours_mib: 100, own_mib: 80 });
        assert_eq!(g.own.chat_pid, Some(4242));
        assert_eq!(g.own.chat_mib, 80);
        assert!(g.own.growth.rising);
        assert_eq!(g.own.growth.slope_mib_per_h, 64);
        assert_eq!(g.own.growth.since.as_deref(), Some("2026-11-11T09:00:00+08:00"));
        assert_eq!((g.own.tasks, g.own.tasks_open, g.own.record_bytes), (7, 3, 4_718_592));
    }

    /// **Null is a state** (task 3167): no chat running and not rising are
    /// both `None`, and neither is read as a zero that draws a process or a
    /// start time.
    #[test]
    fn a_null_chat_and_a_null_since_are_read_as_nothing() {
        let text = r#"{"groups":[{"group":"g","total_mib":0,"parts":{"supervisor_mib":0,"workers_mib":0,"yours_mib":0,"own_mib":0},"own":{"chat_pid":null,"chat_mib":0,"growth":{"rising":false,"slope_mib_per_h":0,"rose_mib":0,"since_s":null,"since":null},"tasks":0,"tasks_open":0,"record_bytes":0}}]}"#;
        let g = decode(text).unwrap().expect("one group");
        assert_eq!(g.own.chat_pid, None);
        assert_eq!(g.own.growth.since, None);
        assert!(!g.own.growth.rising);
    }

    #[test]
    fn an_answer_with_no_group_is_no_strip_and_not_an_error() {
        assert_eq!(decode(r#"{"groups":[]}"#).unwrap(), None);
        assert_eq!(decode(r#"{"at":"x"}"#).unwrap(), None);
    }

    /// **The bar's total is the four parts' sum**, not `total_mib`: a core
    /// that sent a total the pieces do not add up to still draws a bar of
    /// its pieces (the mac host's rule), so the widths are those shares.
    #[test]
    fn the_bars_widths_are_the_partsshares_and_nothing_else() {
        let p = Parts { supervisor_mib: 1, workers_mib: 1, yours_mib: 1, own_mib: 1 };
        assert_eq!(bar_widths(&p, p.sum_mib(), 400.0), [100.0, 100.0, 100.0, 100.0]);
        let p = Parts { supervisor_mib: 1, workers_mib: 2, yours_mib: 3, own_mib: 4 };
        assert_eq!(bar_widths(&p, p.sum_mib(), 100.0), [10.0, 20.0, 30.0, 40.0]);
        // The four fill the bar exactly, whatever the rounding.
        let p = Parts { supervisor_mib: 1, workers_mib: 1, yours_mib: 1, own_mib: 0 };
        let w = bar_widths(&p, p.sum_mib(), 10.0);
        assert!((w.iter().sum::<f64>() - 10.0).abs() < 1e-9);
        // Nothing to divide: four zeroes, not one full bar.
        assert_eq!(bar_widths(&Parts::default(), 0, 100.0), [0.0; 4]);
        assert_eq!(bar_widths(&Parts { supervisor_mib: 5, ..Parts::default() }, 5, 0.0), [0.0; 4]);
        // Monotone in the parts: a bigger part is a wider segment.
        let p = Parts { supervisor_mib: 1, workers_mib: 2, yours_mib: 3, own_mib: 4 };
        let w = bar_widths(&p, p.sum_mib(), 1000.0);
        assert!(w.windows(2).all(|x| x[0] < x[1]), "{w:?}");
    }

    /// **The bar is drawn from the four parts' own sum, never from
    /// `total_mib`** (task 3167; the mac host's rule). The fixture's total
    /// is deliberately **not** the parts' sum, so the two readings draw
    /// different bars and the assertion can tell them apart: 500 MiB of
    /// parts in a 500-point bar is the four sizes themselves, while 512
    /// would shrink every segment by 500/512.
    #[test]
    fn the_bar_is_the_parts_own_sum_and_not_the_total_beside_it() {
        let g = decode(FIXTURE).unwrap().expect("one group");
        assert_eq!(g.parts.sum_mib(), 500);
        assert_eq!(g.total_mib, 512);
        let w = g.bar_widths(500.0);
        assert_eq!(w, [120.0, 200.0, 100.0, 80.0]);
        // And the sum of the drawn widths is the bar, exactly.
        assert!((w.iter().sum::<f64>() - 500.0).abs() < 1e-9);
    }

    #[test]
    fn sizes_rates_and_records_are_written_as_the_cards_write_them() {
        assert_eq!(size(999), "999 MB");
        assert_eq!(size(1024), "1.0 GB");
        assert_eq!(size(12_700), "12.4 GB");
        assert_eq!(rate(64), "+64 MB");
        assert_eq!(rate(-1536), "\u{2212}1.5 GB");
        assert_eq!(record(4_718_592), "4.5 MB");
        assert_eq!(record(2_048), "2.0 KB");
    }

    /// **A translation may reorder the arguments** (`%1$d`), and this is
    /// the one place that is understood: the Chinese `Tasks …` sentence
    /// numbers them, the English does not.
    #[test]
    fn a_sentence_takes_its_arguments_in_the_catalogues_order() {
        let a = ["512 MB".to_string()];
        assert_eq!(sentence("%@ an hour", &a), "512 MB an hour");
        let a = ["1.0 GB".to_string(), "09:00".to_string()];
        assert_eq!(sentence("Embedded chat %@ · rising since %@", &a), "Embedded chat 1.0 GB · rising since 09:00");
        let a = ["7".to_string(), "3".to_string(), "4.5 MB".to_string()];
        assert_eq!(sentence("任务 %1$d 张（开着 %2$d）· 群记录 %3$@", &a), "任务 7 张（开着 3）· 群记录 4.5 MB");
        assert_eq!(sentence("100%% sure", &[]), "100% sure");
        // A `%` that is not a placeholder and has no argument is text.
        assert_eq!(sentence("50% off", &[]), "50% off");
    }

    #[test]
    fn the_request_is_the_one_page_the_overall_view_asks() {
        assert_eq!(request("web-app"), r#"{"page":"overall","group":"web-app"}"#);
    }
}
