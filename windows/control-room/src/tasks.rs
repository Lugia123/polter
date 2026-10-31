//! The task page's data: the core's answer to a `tasks` request (task
//! 2015, `polter-artifacts/2015/API.md` §2.2), read.
//!
//! **Every word is the core's**, written in the person's language; the
//! order of the tasks is the core's too. What is read here is drawn as it
//! is. A glyph or a kind of line this build does not know is an error.

use crate::json::{self, Value};
use crate::n_;
use crate::reader::{at, join, Reader};
use crate::snapshot::DecodeError;

type Res<T> = Result<T, DecodeError>;

/// A task's state as a picture (v9 `main-tasks`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Glyph {
    Queued,
    Working,
    Blocked,
    Done,
    Closed,
    Cancelled,
}

impl Glyph {
    pub fn parse(s: &str) -> Option<Glyph> {
        Some(match s {
            "queued" => Glyph::Queued,
            "working" => Glyph::Working,
            "blocked" => Glyph::Blocked,
            "done" => Glyph::Done,
            "closed" => Glyph::Closed,
            "cancelled" => Glyph::Cancelled,
            _ => return None,
        })
    }
}

/// The heading over the columns, in their order.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Head {
    pub id: String,
    pub state: String,
    pub title: String,
    pub owner: String,
    pub idle: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LogLine {
    /// `at` and `who` are null on a line that has none -- the one that says
    /// what came before was merged has no who (API.md §2.0): not drawn.
    Event { at: Option<String>, who: Option<String>, text: String, last: bool },
    /// "隔了 18 分钟": more than ten minutes between two events.
    Gap { text: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Said {
    pub at: String,
    pub who: String,
    pub text: String,
}

/// One place in a task's squad. **`slot` is the whole of its state** --
/// `filled`, `empty` (nobody has taken it) or `vacated` (its terminal has
/// gone) -- and the word drawn is this host's (`slot_word`). There is no
/// status from the core: it holds no per-seat progress, and a sentence
/// invented there would be one language inside a page both hosts translate.
#[derive(Debug, Clone, PartialEq)]
pub struct SquadSeat {
    pub alias: String,
    pub role: String,
    pub lead: bool,
    pub slot: String,
    pub terminal: String,
    pub cli: String,
}

impl SquadSeat {
    /// What the seat's chip says, or `None` for a slot this build does not
    /// know -- drawn with no word rather than a guessed one.
    pub fn slot_word(&self) -> Option<&'static str> {
        match self.slot.as_str() {
            "filled" => Some(n_("Seated")),
            "empty" => Some(n_("Not seated yet")),
            "vacated" => Some(n_("Seat left")),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SquadDetail {
    pub name: String,
    pub seats: Vec<SquadSeat>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorktreeDetail {
    pub branch: String,
    /// The ledger's path; empty for a tree that is only planned.
    pub path: String,
    /// `made` or `planned`, a token: the word is this host's.
    pub state: String,
}

impl WorktreeDetail {
    pub fn state_word(&self) -> Option<&'static str> {
        match self.state.as_str() {
            "made" => Some(n_("Ready")),
            "planned" => Some(n_("Planned, not made yet")),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TokenSlice {
    pub alias: String,
    pub role: String,
    pub tokens: String,
    pub pct: u8,
    pub color: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TokensDetail {
    pub total: String,
    pub breakdown: Vec<TokenSlice>,
}

/// What the open task shows under its line.
#[derive(Debug, Clone, PartialEq)]
pub struct Detail {
    pub body_title: String,
    pub body: String,
    pub log_title: String,
    pub log: Vec<LogLine>,
    pub said_title: String,
    pub said: Vec<Said>,
    pub squad: Option<SquadDetail>,
    pub worktree: Option<WorktreeDetail>,
    pub tokens: Option<TokensDetail>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Task {
    pub id: u64,
    /// None when the core named none, or one this build does not know: no
    /// symbol is drawn.
    pub glyph: Option<Glyph>,
    pub state: String,
    pub title: String,
    pub owner: String,
    pub idle: String,
    /// The title cut where the filter found it (#2083): `(words, hit)`, the
    /// hits drawn bold on a ground of their own. None with no filter: the
    /// title is drawn as it is. **Cut by the core**, which alone knows how
    /// the filter matches; the page only draws the pieces.
    pub title_parts: Option<Vec<(String, bool)>>,
    /// Its line in bold: the open one.
    pub emph: bool,
    pub detail: Option<Detail>,
    /// The tree's branch (`wt/group/task`), drawn as the tag after the
    /// title; `None` for a task with no tree.
    pub worktree: Option<String>,
}

/// A key and what it does.
pub type Hint = (String, String);

/// The filter box (#2083): what it says while empty, what is typed, how
/// many it found ("4 / 9 条", none while empty) and the key that clears it.
#[derive(Debug, Clone, PartialEq)]
pub struct Filter {
    pub prompt: String,
    pub text: String,
    pub count: Option<String>,
    pub clear: Hint,
}

/// What the page says when no open task matches (#2083).
#[derive(Debug, Clone, PartialEq)]
pub struct NoMatch {
    pub title: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Tasks {
    pub group: String,
    pub goal: String,
    /// The goal as the person wrote it, a line each -- trimmed, the empty
    /// ones gone (`TaskPage.goalLines`, #2060). What the page draws, each
    /// line wrapped on its own (`tasks_scene::goal_rows`); `goal` is the
    /// same words run together.
    pub goal_lines: Vec<String>,
    pub head: Head,
    pub open: Vec<Task>,
    /// The closed tasks' line, and the key at its right (#2083: "已隐藏 8
    /// 条已关闭或已取消的任务" · c "或点这一行显示"). None when there is no
    /// such line: none closed, or none the filter found.
    pub closed_title: Option<String>,
    pub closed_key: Option<Hint>,
    pub closed_count: u64,
    /// Empty unless asked for with `closed: true`.
    pub closed: Vec<Task>,
    /// `(key, what it does)`, in order.
    pub hints: Vec<Hint>,
    /// The key kept at the strip's right end (#2083, plan A): whether the
    /// closed ones are shown, and how to change it. None when none is
    /// closed.
    pub hint_closed: Option<Hint>,
    /// None without a filter box.
    pub filter: Option<Filter>,
    /// None unless filtering found no open task.
    pub no_match: Option<NoMatch>,
    /// What the answer should have said and did not, by path; none of it is
    /// drawn (`reader`). The host writes it down.
    pub missing: Vec<String>,
}

impl Tasks {
    /// Every task in the order drawn: the open ones, then the closed ones
    /// when they are shown. What the arrow keys go through.
    pub fn in_order(&self) -> impl Iterator<Item = &Task> {
        self.open.iter().chain(self.closed.iter())
    }
}

/// The request for `group`'s page: `open_task` is the one whose detail is
/// wanted, `closed` whether the closed ones are listed, `filter` what is
/// typed in the filter box -- "" while it is open and empty, none with no
/// box (API.md §2.2; #2083: **the core filters**, asked at every change).
/// `selected` is the one the arrow keys are on: what Enter's hint speaks of,
/// "fold" for the open one and "open" for another.
pub fn request(group: &str, open_task: Option<u64>, closed: bool, filter: Option<&str>, selected: Option<u64>) -> String {
    let open = open_task.map_or(String::new(), |n| format!(r#","open_task":{n}"#)) + &selected.map_or(String::new(), |n| format!(r#","selected":{n}"#));
    let typed = filter.map_or(String::new(), |f| format!(r#","filter":{}"#, json::quote(f)));
    format!(r#"{{"page":"tasks","group":{}{},"closed":{}{}}}"#, json::quote(group), open, closed, typed)
}

fn hint(r: &mut Reader, v: &Value, path: &str) -> Hint {
    (r.text(v, path, "key"), r.text(v, path, "text"))
}

fn said(r: &mut Reader, v: &Value, path: &str) -> Said {
    Said { at: r.text(v, path, "at"), who: r.text(v, path, "who"), text: r.text(v, path, "text") }
}

fn detail(r: &mut Reader, v: &Value, path: &str) -> Detail {
    let lp = join(path, "log");
    let log = r.list(v, path, "log").iter().enumerate().filter_map(|(i, l)| {
        let p = at(&lp, i);
        match l.get("entry") {
            Some(Value::Str(e)) if e == "event" => Some(LogLine::Event {
                at: r.nullable_text(l, &p, "at"),
                who: r.nullable_text(l, &p, "who"),
                text: r.text(l, &p, "text"),
                last: r.boolean(l, &p, "last").unwrap_or(false),
            }),
            Some(Value::Str(e)) if e == "gap" => {
                // The core writes every key on every line (API.md §2.0): a
                // gap's `at` and `who` null, its `last` false. Read, so
                // that one gone is said, and not drawn.
                let _ = (r.nullable_text(l, &p, "at"), r.nullable_text(l, &p, "who"), r.boolean(l, &p, "last"));
                Some(LogLine::Gap { text: r.text(l, &p, "text") })
            }
            // A kind of line this build does not know: that line is left out.
            _ => {
                r.miss(join(&p, "entry"));
                None
            }
        }
    }).collect();
    let sp = join(path, "said");
    let said = r.list(v, path, "said").iter().enumerate().map(|(i, x)| said(r, x, &at(&sp, i))).collect();

    let squad = match v.get("squad") {
        Some(sq @ Value::Obj(_)) => {
            let sp_path = join(path, "squad");
            let name = r.text(sq, &sp_path, "name");
            let seats_path = join(&sp_path, "seats");
            let seats = r.list(sq, &sp_path, "seats").iter().enumerate().map(|(i, s)| {
                let p = at(&seats_path, i);
                SquadSeat {
                    alias: r.text(s, &p, "alias"),
                    role: r.text(s, &p, "role"),
                    lead: r.boolean(s, &p, "lead").unwrap_or(false),
                    slot: r.text(s, &p, "slot"),
                    terminal: r.text(s, &p, "terminal"),
                    cli: r.text(s, &p, "cli"),
                }
            }).collect();
            Some(SquadDetail { name, seats })
        }
        _ => None,
    };

    let worktree = match v.get("worktree") {
        Some(wt @ Value::Obj(_)) => {
            let wp = join(path, "worktree");
            Some(WorktreeDetail {
                branch: r.text(wt, &wp, "branch"),
                path: r.text(wt, &wp, "path"),
                state: r.text(wt, &wp, "state"),
            })
        }
        _ => None,
    };

    let tokens = match v.get("tokens") {
        Some(tk @ Value::Obj(_)) => {
            let tp = join(path, "tokens");
            let total = r.text(tk, &tp, "total");
            let bp = join(&tp, "breakdown");
            let breakdown = r.list(tk, &tp, "breakdown").iter().enumerate().map(|(i, b)| {
                let p = at(&bp, i);
                TokenSlice {
                    alias: r.text(b, &p, "alias"),
                    role: r.text(b, &p, "role"),
                    tokens: r.text(b, &p, "tokens"),
                    pct: r.int(b, &p, "pct").map(|n| n as u8).unwrap_or(0),
                    color: r.text(b, &p, "color"),
                }
            }).collect();
            Some(TokensDetail { total, breakdown })
        }
        _ => None,
    };

    Detail {
        body_title: r.text(v, path, "body_title"),
        body: r.text(v, path, "body"),
        log_title: r.text(v, path, "log_title"),
        log,
        said_title: r.text(v, path, "said_title"),
        said,
        squad,
        worktree,
        tokens,
    }
}

/// One task, or none without its `id`: what the arrow keys and the open
/// detail are kept by -- not made up.
fn task(r: &mut Reader, v: &Value, path: &str) -> Option<Task> {
    let id = r.int(v, path, "id")?;
    let glyph = match v.get("glyph") {
        Some(Value::Str(g)) => Glyph::parse(g),
        _ => None,
    };
    if glyph.is_none() {
        r.miss(join(path, "glyph"));
    }
    // Null with no filter; a list of pieces with one. A piece that is not
    // one is left out and said, and the rest still drawn.
    let pp = join(path, "title_parts");
    let title_parts = match v.get("title_parts") {
        Some(Value::Null) => None,
        Some(Value::Arr(items)) => Some(items.iter().enumerate().filter_map(|(i, x)| {
            let p = at(&pp, i);
            let text = r.text(x, &p, "text");
            r.boolean(x, &p, "hit").map(|hit| (text, hit))
        }).collect()),
        _ => {
            r.miss(pp);
            None
        }
    };
    let worktree = match v.get("worktree") {
        Some(Value::Str(s)) => Some(s.clone()),
        _ => None,
    };
    Some(Task {
        id,
        glyph,
        state: r.text(v, path, "state"),
        title: r.text(v, path, "title"),
        title_parts,
        owner: r.text(v, path, "owner"),
        idle: r.text(v, path, "idle"),
        emph: r.boolean(v, path, "emph").unwrap_or(false),
        detail: r.nullable_obj(v, path, "detail").map(|d| detail(r, d, &join(path, "detail"))),
        worktree,
    })
}

/// The answer, read field by field (`reader`): only JSON that does not
/// parse, `{"error": …}` -- the error's name, never an empty page -- and an
/// answer that does not say whose group it is fail; everything else missing
/// is left out of what is drawn and named in `missing`.
pub fn decode(json_text: &str) -> Res<Tasks> {
    decode_value(&json::parse(json_text).map_err(DecodeError::Json)?)
}

pub fn decode_value(v: &Value) -> Res<Tasks> {
    if let Some(Value::Str(e)) = v.get("error") {
        return Err(DecodeError::UnknownValue(format!("error={e}")));
    }
    let Some(Value::Str(group)) = v.get("group") else {
        return Err(DecodeError::Field("group".into()));
    };
    let mut r = Reader::default();
    let head = match r.obj(v, "", "head") {
        Some(h) => Head {
            id: r.text(h, "head", "id"),
            state: r.text(h, "head", "state"),
            title: r.text(h, "head", "title"),
            owner: r.text(h, "head", "owner"),
            idle: r.text(h, "head", "idle"),
        },
        None => Head::default(),
    };
    let mut tasks = |key: &str| -> Vec<Task> { r.list(v, "", key).iter().enumerate().filter_map(|(i, t)| task(&mut r, t, &at(key, i))).collect() };
    let (open, closed) = (tasks("open"), tasks("closed"));
    let hints = r.list(v, "", "hints").iter().enumerate().map(|(i, h)| hint(&mut r, h, &at("hints", i))).collect();
    let closed_key = r.nullable_obj(v, "", "closed_key").map(|h| hint(&mut r, h, "closed_key"));
    let hint_closed = r.nullable_obj(v, "", "hint_closed").map(|h| hint(&mut r, h, "hint_closed"));
    let filter = r.nullable_obj(v, "", "filter").map(|f| Filter {
        prompt: r.text(f, "filter", "prompt"),
        text: r.text(f, "filter", "text"),
        count: r.nullable_text(f, "filter", "count"),
        clear: r.obj(f, "filter", "clear").map(|c| hint(&mut r, c, "filter.clear")).unwrap_or_default(),
    });
    let no_match = r.nullable_obj(v, "", "no_match").map(|m| NoMatch { title: r.text(m, "no_match", "title"), detail: r.text(m, "no_match", "detail") });
    Ok(Tasks {
        group: group.clone(),
        goal: r.text(v, "", "goal"),
        goal_lines: r.list(v, "", "goal_lines").iter().enumerate().filter_map(|(i, l)| match l {
            Value::Str(s) => Some(s.clone()),
            _ => {
                r.miss(at("goal_lines", i));
                None
            }
        }).collect(),
        head,
        open,
        closed_title: r.nullable_text(v, "", "closed_title"),
        closed_key,
        closed_count: r.int(v, "", "closed_count").unwrap_or(0),
        closed,
        hints,
        hint_closed,
        filter,
        no_match,
        missing: r.missing,
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) const OPEN: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/tasks-open.json"));
    pub(crate) const CLOSED: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/tasks-closed.json"));
    pub(crate) const NULLS: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/tasks-nulls.json"));
    pub(crate) const FILTER: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/tasks-filter.json"));
    pub(crate) const NOMATCH: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/tasks-nomatch.json"));
    /// The core's own answers (#2083, 0x1c0de's `polter-artifacts/2083/examples`,
    /// made by TaskPage.zig on fbec483e3 + core-task-page-words.patch).
    pub(crate) const CORE: [&str; 4] = [
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/core-tasks-filtered.json")),
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/core-tasks-no_match.json")),
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/core-tasks-expanded.json")),
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/core-tasks-closed_shown.json")),
    ];

    /// The keys the host does not read, and why.
    const UNREAD: [(&str, &str); 2] = [
        ("later", "a key put in the nulls fixture for no build to know (`make-nulls-fixtures.py`)"),
        ("page", "the request's own word, which the answer repeats"),
    ];

    /// Every key of every fixture taken away, and put to a kind it is not
    /// (group seq 309): the answer still reads -- but for `group` -- names
    /// the key in `missing` or is one the host does not read, and the page
    /// lays out and builds.
    #[test]
    fn every_key_missing_or_wrong_costs_only_its_item_and_is_said() {
        use crate::reader::{edited, get_path, paths};
        let unread = |p: &str| p.split('.').any(|part| UNREAD.iter().any(|(k, _)| part.split('[').next() == Some(*k)));
        let measure = |s: &str, _: &crate::scene::Style| s.chars().count() as f64 * 7.0;
        let (mut checked, mut unsaid) = (0, Vec::<String>::new());
        for fixture in [OPEN, CLOSED, NULLS, FILTER, NOMATCH].into_iter().chain(CORE) {
            let v = json::parse(fixture).unwrap();
            // Whole, nothing is missing: what is said below is the edit's.
            assert_eq!(decode_value(&v).unwrap().missing, Vec::<String>::new());
            let mut all = Vec::new();
            paths(&v, "", &mut all);
            for path in &all {
                for with in [None, Some(Value::Bool(true)), Some(Value::Obj(vec![("x".into(), Value::Bool(true))]))] {
                    let got = decode_value(&edited(&v, path, with.clone()));
                    if path == "group" {
                        assert!(got.is_err());
                        continue;
                    }
                    let t = got.unwrap_or_else(|e| panic!("{path} ({with:?}): {e:?}"));
                    let said = t.missing.iter().any(|m| {
                        path == m || path.starts_with(&format!("{m}.")) || path.starts_with(&format!("{m}[")) || m.starts_with(&format!("{path}.")) || m.starts_with(&format!("{path}["))
                    });
                    let same_kind = matches!((&with, get_path(&v, path)), (Some(Value::Bool(_)), Some(Value::Bool(_))) | (Some(Value::Obj(_)), Some(Value::Obj(_))));
                    if !(said || unread(path) || same_kind) {
                        let key: String = path.split('.').map(|part| part.split('[').next().unwrap_or(part)).collect::<Vec<_>>().join(".");
                        let what = format!("{key} ({})", match &with { None => "taken away", Some(Value::Bool(_)) => "a yes/no", _ => "an object" });
                        if !unsaid.contains(&what) {
                            unsaid.push(what);
                        }
                    }
                    let at = crate::tasks_scene::layout(&t, 600.0, 700.0, 0.0, &crate::look::DARK, 1.0, &measure);
                    let _ = crate::tasks_scene::build(&t, &at, &crate::look::DARK, 1.0, None, true, None, &measure);
                    checked += 1;
                }
            }
        }
        assert!(unsaid.is_empty(), "nothing said for:\n{}", unsaid.join("\n"));
        assert!(checked > 300, "{checked}");
    }

    /// The log's `at` and `who` null (API.md §2.0: the merged line has no
    /// who), and keys this build does not know: still the page.
    #[test]
    fn a_log_line_without_its_time_or_who_and_unknown_keys_are_still_the_page() {
        let t = decode(NULLS).unwrap();
        let d = t.open.iter().find_map(|x| x.detail.as_ref()).expect("the open one's detail");
        let events: Vec<_> = d.log.iter().filter_map(|l| match l {
            LogLine::Event { at, who, .. } => Some((at.clone(), who.clone())),
            LogLine::Gap { .. } => None,
        }).collect();
        assert!(!events.is_empty() && events.iter().all(|e| *e == (None, None)));
        assert_eq!(t.open.len(), decode(OPEN).unwrap().open.len());
    }

    #[test]
    fn the_fake_answers_are_read_whole() {
        let t = decode(OPEN).unwrap();
        assert_eq!(t.open.len(), 6);
        assert!(t.closed.is_empty());
        assert_eq!(t.closed_count, 8);
        let open: Vec<&Task> = t.open.iter().filter(|x| x.detail.is_some()).collect();
        assert_eq!(open.len(), 1);
        let d = open[0].detail.as_ref().unwrap();
        assert!(open[0].emph);
        assert_eq!(d.log.iter().filter(|l| matches!(l, LogLine::Gap { .. })).count(), 2);
        assert!(matches!(d.log.last(), Some(LogLine::Event { last: true, .. })));
        assert_eq!(d.said.len(), 4);
        // c is no longer among them: it is at the strip's right (#2083).
        assert_eq!(t.hints.len(), 3);
        let c = decode(CLOSED).unwrap();
        assert_eq!(c.closed.len(), 8);
        assert!(c.closed.iter().all(|x| x.glyph == Some(Glyph::Closed) && !x.emph));
        assert_eq!(c.in_order().count(), 14);
    }

    /// A glyph or a kind of line this build does not know: that symbol, or
    /// that line, is left out and said -- no longer the page (group seq 309).
    #[test]
    fn a_glyph_or_a_line_this_build_does_not_know_costs_only_its_item() {
        let g = decode(&OPEN.replacen("\"glyph\": \"working\"", "\"glyph\": \"sleeping\"", 1)).unwrap();
        assert_eq!(g.open.iter().filter(|t| t.glyph.is_none()).count(), 1);
        assert!(g.missing.iter().any(|m| m.ends_with(".glyph")), "{:?}", g.missing);
        let e = decode(&OPEN.replacen("\"entry\": \"gap\"", "\"entry\": \"pause\"", 1)).unwrap();
        assert!(e.missing.iter().any(|m| m.ends_with(".entry")), "{:?}", e.missing);
        assert_eq!(decode(r#"{"error":"NoSuchTask"}"#), Err(DecodeError::UnknownValue("error=NoSuchTask".into())));
    }

    #[test]
    fn the_request_says_the_open_task_only_when_there_is_one() {
        assert_eq!(request("g", Some(215), false, None, Some(218)), r#"{"page":"tasks","group":"g","open_task":215,"selected":218,"closed":false}"#);
        assert_eq!(request("web-app", Some(215), false, None, None), r#"{"page":"tasks","group":"web-app","open_task":215,"closed":false}"#);
        assert_eq!(request("a\"b", None, true, None, None), r#"{"page":"tasks","group":"a\"b","closed":true}"#);
        // #2083: the filter box's words, "" while it is empty.
        assert_eq!(request("g", None, false, Some(""), None), r#"{"page":"tasks","group":"g","closed":false,"filter":""}"#);
        assert_eq!(request("g", None, false, Some("批\"量"), None), r#"{"page":"tasks","group":"g","closed":false,"filter":"批\"量"}"#);
    }

    /// #2083: the closed tasks' line and its key, the strip's right-hand
    /// key -- the core's words, read as they are.
    #[test]
    fn the_closed_line_and_its_keys_are_the_cores() {
        let t = decode(OPEN).unwrap();
        assert_eq!(t.closed_title.as_deref(), Some("已隐藏 8 条已关闭或已取消的任务"));
        assert_eq!(t.closed_key, Some(("c".into(), "或点这一行显示".into())));
        assert_eq!(t.hint_closed, Some(("c".into(), "显示已关闭的 8 条".into())));
        assert!(t.filter.is_none() && t.no_match.is_none());
        assert!(t.open.iter().all(|x| x.title_parts.is_none()));
        let c = decode(CLOSED).unwrap();
        assert_eq!(c.closed_title.as_deref(), Some("已关闭或已取消的 8 条"));
        assert_eq!(c.hint_closed.map(|h| h.1).as_deref(), Some("隐藏已关闭的"));
        // None closed: no line, and nothing said of it at the right.
        let n = decode(NULLS).unwrap();
        assert!(n.closed_title.is_none() && n.closed_key.is_none() && n.hint_closed.is_none());
    }

    /// #2083: the core's own answers read whole: nothing missing, and the
    /// shape the fake ones have.
    #[test]
    fn the_cores_own_answers_are_read_whole() {
        let [filtered, no_match, expanded, closed_shown] = CORE.map(|c| decode(c).unwrap());
        for t in [&filtered, &no_match, &expanded, &closed_shown] {
            assert!(t.missing.is_empty(), "{:?}", t.missing);
            assert_eq!(t.hints.len(), 3);
        }
        let parts = filtered.open[0].title_parts.as_ref().unwrap();
        assert_eq!(parts.iter().map(|p| p.0.as_str()).collect::<String>(), filtered.open[0].title);
        assert!(parts.iter().any(|p| p.1));
        assert!(filtered.filter.is_some() && no_match.no_match.is_some() && no_match.open.is_empty());
        assert!(expanded.open.iter().any(|x| x.detail.is_some()) && expanded.filter.is_none());
        assert!(!closed_shown.closed.is_empty() && closed_shown.closed_key.is_some());
    }

    /// #2083: **the core filters** and cuts each title where it found the
    /// words; the page draws the pieces and says what the core says.
    #[test]
    fn a_filtered_answer_is_read_piece_by_piece() {
        let t = decode(FILTER).unwrap();
        let f = t.filter.as_ref().unwrap();
        assert_eq!((f.prompt.as_str(), f.text.as_str(), f.count.as_deref()), ("按标题筛选", "批量", Some("2 / 6 条")));
        assert_eq!(f.clear, ("Esc".into(), "清空".into()));
        assert_eq!(t.open.iter().map(|x| x.id).collect::<Vec<_>>(), [216, 218]);
        for task in &t.open {
            let parts = task.title_parts.as_ref().unwrap();
            assert_eq!(parts.iter().map(|p| p.0.as_str()).collect::<String>(), task.title);
            assert_eq!(parts.iter().filter(|p| p.1).map(|p| p.0.as_str()).collect::<Vec<_>>(), ["批量"]);
        }
        assert!(t.closed_title.is_none());
        assert!(t.missing.is_empty(), "{:?}", t.missing);
        let m = decode(NOMATCH).unwrap();
        assert!(m.open.is_empty());
        assert_eq!(m.no_match, Some(NoMatch { title: "没有标题里含「弹窗」的任务".into(), detail: "已关闭的也找过了。按 Esc 清空筛选。".into() }));
        assert!(m.missing.is_empty());
    }

    #[test]
    fn test_squad_and_worktree_task_decoding() {
        let json = r##"{
            "group": "polter",
            "goal": "重构任务面板",
            "goal_lines": ["重构任务面板"],
            "head": {"id": "号", "state": "状态", "title": "标题", "owner": "负责人", "idle": "多久没动"},
            "open": [
                {
                    "id": 2614,
                    "glyph": "working",
                    "state": "进行中",
                    "title": "任务面板升级",
                    "owner": "Polter核心开发小队",
                    "idle": "刚刚",
                    "emph": true,
                    "title_parts": null,
                    "worktree": "wt/polter/2614",
                    "detail": {
                        "body_title": "任务目标",
                        "body": "落地 v3 设计",
                        "log_title": "执行经过",
                        "log": [],
                        "said_title": "小队群聊提及",
                        "said": [],
                        "squad": {
                            "name": "Polter核心开发小队",
                            "seats": [
                                {
                                    "alias": "审核",
                                    "role": "reviewer",
                                    "lead": true,
                                    "slot": "filled",
                                    "terminal": "0x361a",
                                    "cli": "Claude · DS Flash"
                                },
                                {
                                    "alias": "开发",
                                    "role": "dev",
                                    "lead": false,
                                    "slot": "empty",
                                    "terminal": "—",
                                    "cli": ""
                                },
                                {
                                    "alias": "测试",
                                    "role": "tester",
                                    "lead": false,
                                    "slot": "vacated",
                                    "terminal": "—",
                                    "cli": ""
                                }
                            ]
                        },
                        "worktree": {
                            "branch": "wt/polter/2614",
                            "path": "/src/proj-wt/polter/wt-2614",
                            "state": "made"
                        },
                        "tokens": {
                            "total": "110.6k",
                            "breakdown": [
                                {
                                    "alias": "审核",
                                    "role": "reviewer",
                                    "tokens": "38.5k",
                                    "pct": 35,
                                    "color": "#3B82F6"
                                }
                            ]
                        }
                    }
                }
            ],
            "closed_count": 0,
            "closed": [],
            "closed_title": null,
            "closed_key": null,
            "hint_closed": null,
            "filter": null,
            "no_match": null,
            "hints": []
        }"##;

        let res = decode(json).expect("should decode squad task");
        assert!(res.missing.is_empty(), "missing: {:?}", res.missing);
        assert_eq!(res.open.len(), 1);
        let t = &res.open[0];
        assert_eq!(t.owner, "Polter核心开发小队");
        assert_eq!(t.worktree.as_deref(), Some("wt/polter/2614"));

        let d = t.detail.as_ref().expect("detail should exist");
        let squad = d.squad.as_ref().expect("squad should exist");
        assert_eq!(squad.name, "Polter核心开发小队");
        assert_eq!(squad.seats.len(), 3);
        assert!(squad.seats[0].lead);
        assert_eq!(squad.seats[0].alias, "审核");
        // **Three slots, three words** (`slot_word`): a page told the same
        // word for all three would say a seat is being worked when nobody
        // has taken it.
        assert_eq!(squad.seats.iter().map(|s| s.slot_word()).collect::<Vec<_>>(), [Some("Seated"), Some("Not seated yet"), Some("Seat left")]);
        assert_eq!(SquadSeat { slot: "squatted".into(), ..squad.seats[0].clone() }.slot_word(), None);

        let wt = d.worktree.as_ref().expect("worktree should exist");
        assert_eq!(wt.branch, "wt/polter/2614");
        assert_eq!(wt.path, "/src/proj-wt/polter/wt-2614");
        assert_eq!(wt.state_word(), Some("Ready"));
        assert_eq!(WorktreeDetail { state: "vanished".into(), ..wt.clone() }.state_word(), None);

        let tok = d.tokens.as_ref().expect("tokens should exist");
        assert_eq!(tok.total, "110.6k");
        assert_eq!(tok.breakdown.len(), 1);
    }
}
