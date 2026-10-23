//! The performance page's data: the core's answer to a `resources` request
//! (task 2015, `polter-artifacts/2015/API.md` §2.1), read, and the curves
//! kept between answers.
//!
//! **Every word on the page arrives written** (API.md §0): what is read here
//! is drawn as it is, and the numbers that come with it are only for the
//! arc, the curve and the grid. A tone this build does not know is an error,
//! not a quiet "nothing", as a glyph is in the snapshot.

use crate::json::{self, Value};
use crate::level::Level;
use crate::look::perf_page as p;
use crate::reader::{at, join, Reader};
use crate::snapshot::DecodeError;

type Res<T> = Result<T, DecodeError>;

/// Which history the grid shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Span {
    #[default]
    Day,
    Week,
}

impl Span {
    pub fn parse(s: &str) -> Option<Span> {
        match s {
            "day" => Some(Span::Day),
            "week" => Some(Span::Week),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Span::Day => "day",
            Span::Week => "week",
        }
    }
}

/// Words in a tone: `{"tone": …, "text": …}`, the tone none where the core
/// gives none.
#[derive(Debug, Clone, PartialEq)]
pub struct Toned {
    pub tone: Option<Level>,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Machine {
    /// "整机", before the reading; none when the core says none.
    pub label: Option<String>,
    /// None when the core could not read it (API.md §2.0): not drawn.
    pub mem: Option<String>,
    pub mem_of: Option<String>,
    /// None when the core has none to say -- the Windows core reads no swap
    /// (group seq 274) -- the key left out or null: that part is not drawn,
    /// and the rest of the page is (group seq 276: a missing field one part
    /// needs never empties the page).
    pub swap: Option<String>,
    /// None when it could not be read: that part is not drawn at all.
    pub pressure: Option<String>,
    pub panes: String,
    pub day: String,
    pub pressure_tone: Option<Level>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GridPane {
    pub id: String,
    pub name: String,
    pub cells: Vec<Level>,
    /// The cells that say something when the pointer is on them.
    pub hover: Vec<(usize, Vec<Toned>)>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Grid {
    pub span: Span,
    pub title: String,
    pub subtitle: String,
    /// The two buttons at the top right, in order; empty from a core that
    /// writes none, and then none are drawn.
    pub spans: Vec<(Span, String)>,
    pub legend: Vec<(Level, String)>,
    pub cells: usize,
    pub axis: Vec<(usize, String)>,
    /// One a terminal: its line of cells (API.md calls them `panes`: they
    /// are terminals, not the control room's rows).
    pub panes: Vec<GridPane>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Dial {
    /// How far the arc is filled: 0 and up; past 1 is drawn as 1.
    pub fraction: f64,
    /// The warnings' places on the arc, 0..1, first warning first.
    pub ticks: Vec<f64>,
    pub big: String,
    pub unit: String,
    pub cap: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Card {
    pub id: String,
    pub name: String,
    pub role: Option<String>,
    pub badge: Option<Toned>,
    pub tone: Level,
    /// None when the core did not say how full it is: no dial is drawn.
    pub dial: Option<Dial>,
    /// The usage line: the reading and what follows it.
    /// None before the pane's first reading (API.md §2.0): not drawn.
    pub r1: Option<(String, String)>,
    pub r2: Option<Toned>,
    pub r3: Option<Toned>,
    pub foot: (String, String),
    /// The kill line in bytes, drawn across the curve; none when unset.
    pub line_at: Option<u64>,
    /// `[ms, bytes]`: all of them when the answer is `full`, the new ones
    /// otherwise (`Curves`).
    pub points: Vec<(u64, u64)>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Resources {
    pub group: String,
    /// The next request's `since`.
    pub seq: u64,
    pub full: bool,
    pub period_ms: u64,
    pub now_ms: u64,
    pub machine: Machine,
    pub now_line: String,
    pub now_note: String,
    pub grid: Grid,
    pub cards: Vec<Card>,
    /// What the answer should have said and did not -- or said as something
    /// else -- by path; none of it is drawn (`reader`). The host writes it
    /// down.
    pub missing: Vec<String>,
}

/// The request for `group`'s page: `since` is the last answer's `seq`, 0
/// the first time (API.md §2.1).
pub fn request(group: &str, span: Span, since: u64) -> String {
    format!(r#"{{"page":"resources","group":{},"span":"{}","since":{}}}"#, json::quote(group), span.name(), since)
}

fn toned(r: &mut Reader, v: &Value, path: &str) -> Toned {
    Toned { tone: r.nullable_level(v, path, "tone"), text: r.text(v, path, "text") }
}

/// A `Toned` that may be null (§2.0).
fn nullable_toned(r: &mut Reader, v: &Value, path: &str, key: &str) -> Option<Toned> {
    r.nullable_obj(v, path, key).map(|t| toned(r, t, &join(path, key)))
}

/// One card, or none when it has no `id` -- what its curve is kept under;
/// a card is not drawn under an id made up for it.
fn card(r: &mut Reader, v: &Value, path: &str) -> Option<Card> {
    let id = r.text(v, path, "id");
    if id.is_empty() {
        return None;
    }
    let dial = r.obj(v, path, "dial").and_then(|d| {
        let dp = join(path, "dial");
        // No fill, no dial: an empty arc would be read as a reading of 0.
        let fraction = r.number(d, &dp, "fraction")?;
        let tp = join(&dp, "ticks");
        let ticks = r.list(d, &dp, "ticks").iter().enumerate().filter_map(|(i, t)| match t {
            Value::Int(n) => Some(*n as f64),
            Value::Float(f) => Some(*f),
            _ => {
                r.miss(at(&tp, i));
                None
            }
        }).collect();
        Some(Dial { fraction, ticks, big: r.text(d, &dp, "big"), unit: r.text(d, &dp, "unit"), cap: r.text(d, &dp, "cap") })
    });
    let lp = join(path, "lines");
    let (r1, r2, r3) = match r.obj(v, path, "lines") {
        Some(lines) => {
            let r1 = r.nullable_obj(lines, &lp, "r1").map(|u| {
                let up = join(&lp, "r1");
                (r.text(u, &up, "value"), r.text(u, &up, "rest"))
            });
            (r1, nullable_toned(r, lines, &lp, "r2"), nullable_toned(r, lines, &lp, "r3"))
        }
        None => (None, None, None),
    };
    let fp = join(path, "foot");
    let foot = match r.obj(v, path, "foot") {
        Some(f) => (r.text(f, &fp, "left"), r.text(f, &fp, "right")),
        None => (String::new(), String::new()),
    };
    let pp = join(path, "points");
    let points = r.list(v, path, "points").iter().enumerate().filter_map(|(i, p)| match p {
        Value::Arr(a) if a.len() == 2 => match (&a[0], &a[1]) {
            (Value::Int(t), Value::Int(b)) => Some((*t, *b)),
            _ => {
                r.miss(at(&pp, i));
                None
            }
        },
        _ => {
            r.miss(at(&pp, i));
            None
        }
    }).collect();
    Some(Card {
        name: r.text(v, path, "name"),
        role: r.nullable_text(v, path, "role"),
        badge: nullable_toned(r, v, path, "badge"),
        tone: r.level(v, path, "tone").unwrap_or(Level::None),
        dial,
        r1,
        r2,
        r3,
        foot,
        line_at: r.nullable_int(v, path, "line_at"),
        points,
        id,
    })
}

/// The grid. Without its span or its count of cells it has no rows, no
/// axis and no legend -- nothing can be placed -- and its title is still
/// said.
fn grid(r: &mut Reader, v: &Value, path: &str) -> Grid {
    let span = match v.get("span") {
        Some(Value::Str(s)) => Span::parse(s),
        _ => None,
    };
    if span.is_none() {
        r.miss(join(path, "span"));
    }
    let cells = r.int(v, path, "cells").map(|n| n as usize);
    let title = r.text(v, path, "title");
    let subtitle = r.text(v, path, "subtitle");
    // No buttons from a core that writes none -- and, every key being there
    // (§2.0), said.
    let mut spans = Vec::new();
    {
        let sp = join(path, "spans");
        for (i, e) in r.list(v, path, "spans").iter().enumerate() {
            let ep = at(&sp, i);
            let s = match e.get("span") {
                Some(Value::Str(s)) => Span::parse(s),
                _ => None,
            };
            let t = r.text(e, &ep, "text");
            match s {
                Some(s) => spans.push((s, t)),
                None => r.miss(join(&ep, "span")),
            }
        }
    }
    let (Some(span), Some(cells)) = (span, cells) else {
        return Grid { span: Span::Day, title, subtitle, spans, legend: Vec::new(), cells: 0, axis: Vec::new(), panes: Vec::new() };
    };
    let lp = join(path, "legend");
    let legend = r.list(v, path, "legend").iter().enumerate().filter_map(|(i, e)| {
        let ep = at(&lp, i);
        let level = r.level(e, &ep, "tone")?;
        Some((level, r.text(e, &ep, "text")))
    }).collect();
    let ap = join(path, "axis");
    let axis = r.list(v, path, "axis").iter().enumerate().filter_map(|(i, a)| {
        let ep = at(&ap, i);
        let cell = r.int(a, &ep, "cell")? as usize;
        Some((cell, r.text(a, &ep, "text")))
    }).collect();
    let pp = join(path, "panes");
    let panes = r.list(v, path, "panes").iter().enumerate().filter_map(|(i, row)| {
        let p = at(&pp, i);
        let cp = join(&p, "cells");
        // A cell this build cannot read is drawn as having no level.
        let row_cells: Vec<Level> = r.list(row, &p, "cells").iter().enumerate().map(|(k, c)| match c {
            Value::Str(s) => Level::parse(s).unwrap_or_else(|| {
                r.miss(at(&cp, k));
                Level::None
            }),
            _ => {
                r.miss(at(&cp, k));
                Level::None
            }
        }).collect();
        // Exactly as many as the grid has (API.md §2.1): a row that is not
        // would be drawn against the wrong times -- that row is left out.
        if row_cells.len() != cells {
            if row.get("cells").is_some() {
                r.miss(cp);
            }
            return None;
        }
        let hp = join(&p, "hover");
        let hover = r.list(row, &p, "hover").iter().enumerate().filter_map(|(k, h)| {
            let ep = at(&hp, k);
            let cell = r.int(h, &ep, "cell")? as usize;
            let linp = join(&ep, "lines");
            let lines = r.list(h, &ep, "lines").iter().enumerate().map(|(j, l)| toned(r, l, &at(&linp, j))).collect();
            Some((cell, lines))
        }).collect();
        Some(GridPane { id: r.text(row, &p, "id"), name: r.text(row, &p, "name"), cells: row_cells, hover })
    }).collect();
    Grid { span, title, subtitle, spans, legend, cells, axis, panes }
}

/// The answer, read field by field (`Reader`): only JSON that does not
/// parse, `{"error": …}` -- the error's name in `DecodeError::UnknownValue`,
/// never an empty page -- and an answer that does not say whose group it is
/// fail; everything else missing is left out of what is drawn and named in
/// `missing`.
pub fn decode(json_text: &str) -> Res<Resources> {
    decode_value(&json::parse(json_text).map_err(DecodeError::Json)?)
}

pub fn decode_value(v: &Value) -> Res<Resources> {
    if let Some(Value::Str(e)) = v.get("error") {
        return Err(DecodeError::UnknownValue(format!("error={e}")));
    }
    let Some(Value::Str(group)) = v.get("group") else {
        return Err(DecodeError::Field("group".into()));
    };
    let mut r = Reader::default();
    let machine = match r.obj(v, "", "machine") {
        Some(m) => {
            let text = r.obj(m, "machine", "text");
            let tp = "machine.text";
            let mut t = |key: &str| text.and_then(|mt| r.nullable_text(mt, tp, key));
            let (label, mem, mem_of, swap, pressure) = (t("label"), t("mem"), t("mem_of"), t("swap"), t("pressure"));
            let (panes, day) = match text {
                Some(mt) => (r.text(mt, tp, "panes"), r.text(mt, tp, "day")),
                None => (String::new(), String::new()),
            };
            Machine { label, mem, mem_of, swap, pressure, panes, day, pressure_tone: r.nullable_level(m, "machine", "pressure_tone") }
        }
        None => Machine { label: None, mem: None, mem_of: None, swap: None, pressure: None, panes: String::new(), day: String::new(), pressure_tone: None },
    };
    let grid = match r.obj(v, "", "grid") {
        Some(g) => grid(&mut r, g, "grid"),
        None => Grid { span: Span::Day, title: String::new(), subtitle: String::new(), spans: Vec::new(), legend: Vec::new(), cells: 0, axis: Vec::new(), panes: Vec::new() },
    };
    let cards = r.list(v, "", "cards").iter().enumerate().filter_map(|(i, c)| card(&mut r, c, &at("cards", i))).collect();
    Ok(Resources {
        group: group.clone(),
        seq: r.int(v, "", "seq").unwrap_or(p::MISSING_SEQ as u64),
        full: r.boolean(v, "", "full").unwrap_or(false),
        period_ms: r.int(v, "", "period_ms").unwrap_or(p::MISSING_PERIOD_MS as u64),
        now_ms: r.int(v, "", "now_ms").unwrap_or(0),
        machine,
        now_line: r.text(v, "", "now_line"),
        now_note: r.text(v, "", "now_note"),
        grid,
        cards,
        missing: r.missing,
    })
}

/// The most points a card keeps: five minutes at one every two seconds
/// (DESIGN-v2 §1, API.md §2.1).
pub const KEPT_POINTS: usize = 150;

/// Each card's curve, kept between answers: a `full` answer replaces them
/// all, a later one adds its points to the end, and a card no longer in the
/// answer is forgotten. The oldest go first past `KEPT_POINTS`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Curves {
    by_id: Vec<(String, Vec<(u64, u64)>)>,
    /// The `since` of the next request.
    pub since: u64,
}

impl Curves {
    pub fn take(&mut self, r: &Resources) {
        let mut next = Vec::with_capacity(r.cards.len());
        for c in &r.cards {
            let mut pts = if r.full { Vec::new() } else { self.points(&c.id).to_vec() };
            pts.extend_from_slice(&c.points);
            if pts.len() > KEPT_POINTS {
                pts.drain(..pts.len() - KEPT_POINTS);
            }
            next.push((c.id.clone(), pts));
        }
        self.by_id = next;
        self.since = r.seq;
    }

    pub fn points(&self, id: &str) -> &[(u64, u64)] {
        self.by_id.iter().find(|(i, _)| i == id).map_or(&[], |(_, p)| p.as_slice())
    }

    /// Back to nothing: another group, or another span.
    pub fn clear(&mut self) {
        *self = Curves::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const DAY: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/resources-day.json"));
    const WEEK: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/resources-week.json"));
    pub(crate) const NULLS: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/resources-nulls.json"));

    /// The keys the host does not read at all, and why: taking one away
    /// changes nothing, so nothing is said of it.
    const UNREAD: [(&str, &str); 6] = [
        ("start_ms", "when the grid's first cell begins: the axis's words are the core's, so the host places nothing by time"),
        ("cell_ms", "how long a cell is: likewise"),
        ("raw", "the readings as numbers; the core writes every word the host draws (API.md §2.1)"),
        ("r4", "says only that the fourth line is the curve, which is drawn from `points`"),
        ("later", "a key put in the nulls fixture for no build to know (`make-nulls-fixtures.py`)"),
        ("page", "the request's own word, which the answer repeats"),
    ];

    /// **Every key of every fixture, taken away, and then put to a kind it
    /// is not** (group seq 309): each answer still reads -- but for `group`,
    /// without which it is nobody's page -- and names the key in `missing`,
    /// or the key is one the host does not read (`UNREAD`). The page is then
    /// laid out and built, which must not fail either.
    #[test]
    fn every_key_missing_or_wrong_costs_only_its_item_and_is_said() {
        use crate::reader::{edited, paths};
        let unread = |p: &str| p.split('.').any(|part| UNREAD.iter().any(|(k, _)| part.split('[').next() == Some(*k)));
        let mut checked = 0;
        let mut unsaid: Vec<String> = Vec::new();
        for fixture in [DAY, WEEK, NULLS] {
            let v = crate::json::parse(fixture).unwrap();
            // Whole, nothing is missing: what is said below is the edit's.
            assert_eq!(decode_value(&v).unwrap().missing, Vec::<String>::new());
            let mut all = Vec::new();
            paths(&v, "", &mut all);
            for path in &all {
                // Taken away; a yes/no, wrong for all but the yes/nos; an
                // object, wrong for all but the objects.
                for with in [None, Some(Value::Bool(true)), Some(Value::Obj(vec![("x".into(), Value::Bool(true))]))] {
                    let e = edited(&v, path, with.clone());
                    let got = decode_value(&e);
                    if path == "group" {
                        assert!(got.is_err(), "{path}");
                        continue;
                    }
                    let r = got.unwrap_or_else(|err| panic!("{path} ({with:?}): {err:?}"));
                    // The key itself, or what holds it (the key is under
                    // a path named).
                    let said = r.missing.iter().any(|m| {
                        path == m
                            || path.starts_with(&format!("{m}."))
                            || path.starts_with(&format!("{m}["))
                            || m.starts_with(&format!("{path}."))
                            || m.starts_with(&format!("{path}["))
                    });
                    // A yes/no put where a yes/no was is no change.
                    let same_kind = matches!((&with, crate::reader::get_path(&v, path)), (Some(Value::Bool(_)), Some(Value::Bool(_))) | (Some(Value::Obj(_)), Some(Value::Obj(_))));
                    if !(said || unread(path) || same_kind) {
                        // Indices stripped: one line a key, not one an element.
                        let key: String = path.split('.').map(|part| part.split('[').next().unwrap_or(part)).collect::<Vec<_>>().join(".");
                        let what = format!("{key} ({})", match &with { None => "taken away", Some(Value::Bool(_)) => "a yes/no", _ => "an object" });
                        if !unsaid.contains(&what) {
                            unsaid.push(what);
                        }
                    }
                    let at = crate::perf_scene::layout(&r, 600.0, 0.0, &crate::look::DARK, &|s: &str, _: &crate::scene::Style| s.chars().count() as f64 * 7.0);
                    let _ = crate::perf_scene::build(&r, &Curves::default(), &at, &crate::look::DARK, 1.0, None, &|s: &str, _: &crate::scene::Style| s.chars().count() as f64 * 7.0);
                    checked += 1;
                }
            }
        }
        assert!(unsaid.is_empty(), "nothing said for:\n{}", unsaid.join("\n"));
        assert!(checked > 1000, "{checked}");
    }

    #[test]
    fn the_fake_answers_are_read_whole() {
        let r = decode(DAY).unwrap();
        assert_eq!(r.cards.len(), 8);
        assert_eq!(r.grid.span, Span::Day);
        assert_eq!((r.grid.cells, r.grid.panes.len()), (48, 8));
        assert!(r.grid.panes.iter().all(|pane| pane.cells.len() == 48));
        assert_eq!(r.machine.label.as_deref(), Some("整机"));
        assert_eq!(r.grid.spans.iter().map(|s| s.0).collect::<Vec<_>>(), vec![Span::Day, Span::Week]);
        let ocr = r.cards.iter().find(|c| c.name == "ocr-mask").unwrap();
        assert_eq!(ocr.tone, Level::Killed);
        assert_eq!(ocr.badge.as_ref().unwrap().tone, Some(Level::Killed));
        assert!(ocr.dial.as_ref().unwrap().fraction > 1.0);
        assert_eq!(ocr.points.len(), 150);
        let me = r.cards.iter().find(|c| c.role.as_deref() == Some("你的终端")).unwrap();
        assert_eq!((me.line_at, me.dial.as_ref().unwrap().ticks.len()), (None, 0));
        assert_eq!(r.grid.panes.iter().map(|pane| pane.hover.len()).sum::<usize>(), 1);
        let w = decode(WEEK).unwrap();
        assert_eq!((w.grid.span, w.grid.cells), (Span::Week, 42));
    }

    /// A value this build does not know costs what it is drawn as, and is
    /// said -- no longer the page (group seq 309).
    #[test]
    fn a_tone_or_span_this_build_does_not_know_costs_only_its_item() {
        let legend = decode(&DAY.replacen("\"tone\": \"warn2\"", "\"tone\": \"warn9\"", 1)).unwrap();
        assert!(legend.missing.iter().any(|m| m.starts_with("grid.legend[")), "{:?}", legend.missing);
        assert_eq!(legend.grid.legend.len(), decode(DAY).unwrap().grid.legend.len() - 1);
        let span = decode(&DAY.replacen("\"span\": \"day\"", "\"span\": \"month\"", 1)).unwrap();
        assert!(span.missing.contains(&"grid.span".to_string()));
        assert!(span.grid.panes.is_empty() && span.grid.axis.is_empty(), "no grid without its span");
        assert!(!span.cards.is_empty(), "and the rest is drawn");
        // In a pane's cells, not the legend's tones, which come first --
        // and not `machine.text.panes`, which comes before both: the array.
        let rows = DAY.find("\"panes\": [").unwrap();
        let in_rows = |from: &str, to: &str| format!("{}{}", &DAY[..rows], DAY[rows..].replacen(from, to, 1));
        let gone = decode(&in_rows("\"none\",", "\"gone\",")).unwrap();
        assert!(gone.missing.iter().any(|m| m.starts_with("grid.panes[0].cells[")), "{:?}", gone.missing);
        // A row with a cell too few is not drawn against the wrong times:
        // that row alone is left out.
        let short = decode(&in_rows("\"none\",", "")).unwrap();
        assert_eq!(short.grid.panes.len(), decode(DAY).unwrap().grid.panes.len() - 1);
        assert!(short.missing.contains(&"grid.panes[0].cells".to_string()));
        assert!(decode(&in_rows("\"none\",", "\"ok\",")).unwrap().missing.is_empty(), "the edit itself is what is said, not the splice");
        // The core's refusal is a refusal, not an empty page; and an answer
        // that does not say whose it is cannot be drawn for anybody.
        assert_eq!(decode(r#"{"error":"NoSuchGroup"}"#), Err(DecodeError::UnknownValue("error=NoSuchGroup".into())));
        assert!(decode(&DAY.replacen("\"group\":", "\"gruop\":", 1)).is_err());
    }

    /// Every field API.md §2.0's table lets be null, null at once -- and a
    /// key this build does not know on the answer, the machine and each
    /// card (`testdata/resources-nulls.json`, made by
    /// `polter-artifacts/2039/tools/make-nulls-fixtures.py`). 0x4881's
    /// fourth round (group seq 274) was the page empty over the swap alone.
    #[test]
    fn every_field_the_api_lets_be_null_is_read_as_none_and_unknown_keys_are_ignored() {
        let r = decode(NULLS).unwrap();
        let m = &r.machine;
        assert_eq!((&m.mem, &m.mem_of, &m.swap, &m.pressure, &m.pressure_tone), (&None, &None, &None, &None, &None));
        assert!(!r.cards.is_empty());
        for c in &r.cards {
            assert_eq!((&c.role, &c.badge, &c.r1, &c.r2, &c.r3, &c.line_at), (&None, &None, &None, &None, &None, &None), "{}", c.id);
        }
        let tones: Vec<_> = r.grid.panes.iter().flat_map(|p| p.hover.iter().flat_map(|(_, l)| l.iter().map(|t| t.tone))).collect();
        assert!(!tones.is_empty() && tones.iter().all(|t| t.is_none()));
        // The rest is all there.
        assert_eq!(r.grid.cells, 48);
        assert_eq!(m.panes, decode(DAY).unwrap().machine.panes);
        // A key left out -- the core's mistake (§2.0) -- costs only its item.
        let line = "\"swap\": \"交换 1.2 GB\",";
        assert!(DAY.contains(line), "the fixture's swap is where this test looks");
        assert_eq!(decode(&DAY.replacen(line, "", 1)).unwrap().machine.swap, None);
        assert_eq!(decode(DAY).unwrap().machine.swap.as_deref(), Some("交换 1.2 GB"));
    }

    #[test]
    fn no_spans_and_no_label_from_a_core_that_writes_none_draws_none() {
        let v = DAY.replacen("\"label\": \"整机\",", "", 1);
        let start = v.find("\"spans\"").unwrap();
        let end = start + v[start..].find("],").unwrap() + 2;
        let v = format!("{}{}", &v[..start], &v[end..]);
        let r = decode(&v).unwrap();
        assert_eq!(r.machine.label, None);
        assert!(r.grid.spans.is_empty());
    }

    #[test]
    fn the_request_names_the_group_quoted_the_span_and_since() {
        assert_eq!(request("web\"app", Span::Week, 12), r#"{"page":"resources","group":"web\"app","span":"week","since":12}"#);
    }

    #[test]
    fn curves_are_replaced_by_a_full_answer_added_to_by_the_next_and_cut_at_150() {
        let mut r = decode(DAY).unwrap();
        let mut c = Curves::default();
        c.take(&r);
        let id = r.cards[0].id.clone();
        assert_eq!(c.points(&id).len(), 150);
        assert_eq!(c.since, r.seq);
        let last = *c.points(&id).last().unwrap();
        // Two new points: the oldest two go.
        r.full = false;
        r.seq += 1;
        for card in &mut r.cards {
            card.points = vec![(last.0 + 2000, 1), (last.0 + 4000, 2)];
        }
        let first_before = c.points(&id)[2];
        c.take(&r);
        assert_eq!(c.points(&id).len(), 150);
        assert_eq!(c.points(&id)[0], first_before);
        assert_eq!(*c.points(&id).last().unwrap(), (last.0 + 4000, 2));
        // A card no longer there is forgotten; a full answer starts again.
        r.cards.truncate(1);
        r.full = true;
        c.take(&r);
        assert_eq!(c.points(&id).len(), 2);
        assert!(c.points(&decode(DAY).unwrap().cards[1].id).is_empty());
    }
}
