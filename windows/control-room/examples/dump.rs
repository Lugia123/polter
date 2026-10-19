//! Print what this crate makes of a snapshot, in the form
//! `tools/control-room-hosts-agree.py` compares with the macOS host's.
//!
//!     cargo run -q -p polter-control-room --example dump -- <snapshot.json> <height>
//!
//! One fact a line. The macOS side prints the same lines from
//! `ControlRoomList.swift`; any line that differs is the two hosts
//! disagreeing about what one snapshot looks like.

use polter_control_room::json::quote;
use polter_control_room::act::{self, Act, Refusal, SeenMarker};
use polter_control_room::rules;
use polter_control_room::layout::{self, ListLayout, Rect};
use polter_control_room::list::{self, List, Row};
use polter_control_room::json::Value;
use polter_control_room::pane;
use polter_control_room::pane_color::Color as PaneColor;
use polter_control_room::project_link::{self, HintClock};
use polter_control_room::{panestack, tabmarks};
use polter_control_room::pulse::{self, Scope};
use polter_control_room::quota;
use polter_control_room::rowmenu;
use polter_control_room::look::selection;
use polter_control_room::slide;
use polter_control_room::snapshot::{self, Shown};
use polter_control_room::stackstrip;

/// What steps want, for the fitting rule: one sentence short and long, a
/// command at, under and over each of the two ceilings.
const FITS: &[&[usize]] = &[
    &[],
    &[1],
    &[2],
    &[5],
    &[1, 1],
    &[3, 1],
    &[1, 3],
    &[2, 2],
    &[1, 1, 1],
    &[4, 4, 4],
    &[2, 1, 1, 1],
    &[1, 1, 1, 1, 1, 1],
    &[1, 1, 1, 1, 1, 1, 1],
    &[9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9],
];

const NOMINAL: &[&str] = &[
    "",
    "git push",
    "rm -rf dist/ .cache/ node_modules/.vite && x",
    "01234567890123456789012345678901234567890",
    "012345678901234567890123456789012345678901",
    "发票编号要按租户分开，还是全局连续？分开的话，旧发票要不要一起改编号？",
];

fn rect(name: &str, r: Rect) {
    println!("rect {name} x={:.3} y={:.3} w={:.3} h={:.3}", r.x, r.y, r.w, r.h);
}

fn row(section: &str, r: &Row) {
    // The two moments go with the terminal: with no terminal behind the
    // row there is nothing an act would hand back.
    let since = r.terminal.as_ref().map_or("-".to_string(), |_| r.since_ms.to_string());
    let event = r.terminal.as_ref().and(r.event_ms).map_or("-".to_string(), |m| m.to_string());
    println!(
        "row section={section} id={} shown={} word={} who={} name={} form={} code={} lines={} others={} \
         unseen={} terminal={} since={since} event={event}",
        r.id,
        r.shown.name(),
        quote(&r.word),
        r.waiter.is.name(),
        quote(&r.waiter.name),
        r.what.form.name(),
        list::is_code(&r.what),
        r.what.lines.len(),
        r.others,
        r.unseen,
        r.terminal.as_deref().unwrap_or("-")
    );
    // What it waits on, every line of it and whole.
    println!("cut id={} cut={}", r.id, r.what.cut.name());
    for (n, line) in list::drawn(&r.what).iter().enumerate() {
        println!("what id={} n={n} line={}", r.id, quote(line));
    }
}

/// `#RRGGBB` in capitals, no alpha, or `-`.
fn hex(c: Option<polter_control_room::look::Rgba>) -> String {
    c.map_or("-".to_string(), |c| format!("#{:02X}{:02X}{:02X}", c.r, c.g, c.b))
}

/// `pane_colors.json`, beside the snapshot (`pane-color-interface.md` §11):
/// the colour set on each terminal, and the window-tab cases.
struct PaneColours {
    colors: Vec<(String, PaneColor)>,
    cases: Vec<(String, Vec<tabmarks::Seen>)>,
}

impl PaneColours {
    fn read(snapshot: &str) -> PaneColours {
        let path = std::path::Path::new(snapshot).with_file_name("pane_colors.json");
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let v = polter_control_room::json::parse(&text).expect("pane_colors.json is JSON");
        let colour = |name: &str| -> Option<PaneColor> {
            if name == "none" {
                return None;
            }
            Some(PaneColor::from_name(name).unwrap_or_else(|| panic!("pane_colors.json: {name:?} is no colour")))
        };
        let colors = match v.get("colors") {
            Some(Value::Obj(fields)) => fields
                .iter()
                .filter_map(|(id, c)| match c {
                    Value::Str(c) => colour(c).map(|c| (id.clone(), c)),
                    _ => panic!("pane_colors.json: colors.{id} is not a word"),
                })
                .collect(),
            _ => panic!("pane_colors.json: no colors"),
        };
        let word = |v: &Value, key: &str| match v.get(key) {
            Some(Value::Str(s)) => s.clone(),
            _ => panic!("pane_colors.json: a {key} is missing"),
        };
        let cases = match v.get("tab_dots") {
            Some(Value::Arr(items)) => items
                .iter()
                .map(|case| {
                    let panes = match case.get("panes") {
                        Some(Value::Arr(ps)) => ps
                            .iter()
                            .map(|p| tabmarks::Seen {
                                name: word(p, "name"),
                                color: colour(&word(p, "color")),
                                flag: match word(p, "flag").as_str() {
                                    "none" => None,
                                    "raised" => Some(tabmarks::Flag::Raised),
                                    "lowered" => Some(tabmarks::Flag::Lowered),
                                    other => panic!("pane_colors.json: flag {other:?}"),
                                },
                            })
                            .collect(),
                        _ => panic!("pane_colors.json: a case has no panes"),
                    };
                    (word(case, "case"), panes)
                })
                .collect(),
            _ => panic!("pane_colors.json: no tab_dots"),
        };
        PaneColours { colors, cases }
    }

    fn of(&self, id: Option<&str>) -> Option<PaneColor> {
        let id = id?;
        self.colors.iter().find(|(t, _)| t == id).map(|(_, c)| *c)
    }
}

/// `project_link_cases.json`, beside the snapshot (`project-link-interface.md`
/// §5): the group states the "Project ›" menu and the row's words are
/// printed for, and the hint's clock cases.
struct ProjectLinkCases {
    menu: Vec<LinkCase>,
    hint: Vec<HintCase>,
}

struct LinkCase {
    tie: String,
    why: String,
    steward: bool,
    name: Option<String>,
}

struct HintCase {
    case: String,
    steps: Vec<(f64, bool)>,
    close_at: Option<f64>,
}

/// A number as the macOS dump writes a `Double`: whole ones without a point.
fn seconds(v: f64) -> String {
    if v == v.round() {
        format!("{}", v as i64)
    } else {
        format!("{v}")
    }
}

impl ProjectLinkCases {
    fn read(snapshot: &str) -> ProjectLinkCases {
        let path = std::path::Path::new(snapshot).with_file_name("project_link_cases.json");
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let v = polter_control_room::json::parse(&text).expect("project_link_cases.json is JSON");
        let word = |v: &Value, key: &str| match v.get(key) {
            Some(Value::Str(s)) => s.clone(),
            _ => panic!("project_link_cases.json: a {key} is missing"),
        };
        let number = |v: &Value| match v {
            Value::Int(n) => *n as f64,
            Value::Float(f) => *f,
            other => panic!("project_link_cases.json: {other:?} is no number"),
        };
        let menu = match v.get("menu") {
            Some(Value::Arr(items)) => items
                .iter()
                .map(|c| LinkCase {
                    tie: word(c, "tie"),
                    why: word(c, "why"),
                    steward: match c.get("steward") {
                        Some(Value::Bool(b)) => *b,
                        _ => panic!("project_link_cases.json: a steward is missing"),
                    },
                    name: match c.get("name") {
                        Some(Value::Str(s)) => Some(s.clone()),
                        Some(Value::Null) => None,
                        _ => panic!("project_link_cases.json: a name is missing"),
                    },
                })
                .collect(),
            _ => panic!("project_link_cases.json: no menu"),
        };
        let hint = match v.get("hint") {
            Some(Value::Arr(items)) => items
                .iter()
                .map(|h| HintCase {
                    case: word(h, "case"),
                    steps: match h.get("steps") {
                        Some(Value::Arr(steps)) => steps
                            .iter()
                            .map(|s| match s {
                                Value::Arr(pair) if pair.len() == 2 => match &pair[1] {
                                    Value::Bool(b) => (number(&pair[0]), *b),
                                    _ => panic!("project_link_cases.json: a step's second is not a flag"),
                                },
                                _ => panic!("project_link_cases.json: a step is not a pair"),
                            })
                            .collect(),
                        _ => panic!("project_link_cases.json: a case has no steps"),
                    },
                    close_at: match h.get("close_at") {
                        Some(Value::Null) => None,
                        Some(n) => Some(number(n)),
                        None => panic!("project_link_cases.json: a close_at is missing"),
                    },
                })
                .collect(),
            _ => panic!("project_link_cases.json: no hint"),
        };
        ProjectLinkCases { menu, hint }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: dump <snapshot.json> <height>");
        std::process::exit(2);
    }
    let text = std::fs::read_to_string(&args[1]).expect("the snapshot can be read");
    let height: f64 = args[2].parse().expect("the height is a number");

    let snap = match snapshot::decode(&text) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("the snapshot does not decode: {e:?}");
            std::process::exit(1);
        }
    };
    let l = List::from_snapshot(&snap);
    // The colour each terminal was given, from beside the snapshot: the
    // core's snapshot does not carry it (`pane-color-interface.md` §11).
    let colours = PaneColours::read(&args[1]);

    println!("count waiting={} quiet={}", l.waiting_count, l.quiet_count);
    // The two headings: what the core wrote, and the sentence made of it.
    for (name, h, (words, n)) in [("waiting", l.waiting_header, l.waiting_heading()), ("quiet", l.quiet_header, l.quiet_heading())] {
        let core = h.map_or("-".to_string(), |h| format!("{} of={} number={}", h.count, h.of.name(), h.number.name()));
        println!("heading {name} core={core} says={}", quote(&polter_control_room::list::fill(words, &n)));
    }

    // Where a control room opens, and whose choice the selection then is.
    let open_on = snap.open_on.as_deref();
    println!("open_on {}", open_on.unwrap_or("-"));
    let first = l.waiting.first().or(l.quiet.first()).map(|r| r.id.as_str());
    for (current, opening) in [(None, true), (None, false), (first, true), (first, false)] {
        let (id, persons) = list::opening_selection(current, opening, open_on);
        println!(
            "opening current={} opening={} selects={} persons={}",
            current.unwrap_or("-"),
            opening,
            id.unwrap_or("-"),
            persons
        );
    }
    for r in &l.waiting {
        row("waiting", r);
    }
    for r in &l.quiet {
        row("quiet", r);
    }
    // What each row is called, and for a terminal in no group which
    // terminal it is and which frame its own pane wears.
    for r in l.rows() {
        println!(
            "rowname id={} name={} alone={} pane={}",
            r.id,
            quote(r.name()),
            r.alone.as_ref().map_or("-", |a| a.terminal.as_str()),
            r.alone.as_ref().map_or("-", |a| a.pane.name())
        );
    }
    // Which rows' lines are the core's own sentence, and what goes in it
    // (task 1525): as decoded, before either side says it.
    let say = |s: &Option<snapshot::Say>| match s {
        None => "none".to_string(),
        Some(s) => format!("key={} template={} args={}", s.key, quote(&s.template), s.args.iter().map(|a| quote(a)).collect::<Vec<_>>().join(",")),
    };
    for g in &snap.groups {
        println!("say group={} {}", quote(&g.name), say(&g.what.say));
    }
    for one in &snap.ungrouped {
        println!("say lone={} {}", one.id, say(&one.what.say));
    }

    // The terminals in no group, each with a row of its own.
    let alone = match polter_control_room::lone::decode(&text) {
        Ok(rows) => rows,
        Err(e) => {
            eprintln!("the snapshot's ungrouped does not decode: {e:?}");
            std::process::exit(1);
        }
    };
    println!("lone {}", alone.len());
    for one in &alone {
        let since = one.terminal.as_ref().map_or("-".to_string(), |_| one.since_ms.to_string());
        let event = one.terminal.as_ref().and(one.event_ms).map_or("-".to_string(), |m| m.to_string());
        println!(
            "lone row={} section={} title={} shown={} word={} who={} name={} form={} code={} lines={} unseen={} \
             terminal={} since={since} event={event} shows={}",
            one.row_id(),
            one.section(),
            quote(&one.title),
            one.shown.name(),
            quote(&one.text),
            one.waiter.is.name(),
            quote(&one.waiter.name),
            one.what.form.name(),
            list::is_code(&one.what),
            one.what.lines.len(),
            one.unseen,
            one.terminal.as_deref().unwrap_or("-"),
            polter_control_room::lone::shown_for(&alone, &one.row_id()).unwrap_or("-")
        );
        println!("lone cut row={} cut={}", one.row_id(), one.what.cut.name());
        for (n, line) in list::drawn(&one.what).iter().enumerate() {
            println!("lone what row={} n={n} line={}", one.row_id(), quote(line));
        }
    }
    // The first line of a waiting row, when it is too narrow for the name,
    // who is waiting and the status word: the same cases on both sides, in
    // the same units, laid out the way `scene` lays that line out -- the
    // name leading, who is waiting squeezed, the status word trailing.
    const LINE1: [(i32, i32, Option<i32>, i32); 16] = [
        (80, 0, Some(100), 40), (80, 0, Some(400), 40), (500, 0, Some(90), 40), (274, 0, Some(90), 40),
        (266, 0, Some(90), 40), (265, 0, Some(90), 40), (250, 0, Some(90), 40), (300, 0, None, 40),
        (400, 0, None, 40), (66, 0, Some(67), 40), (187, 0, Some(510), 40), (465, 0, Some(149), 40),
        (80, 292, Some(50), 40), (10, 262, Some(50), 40), (80, 0, Some(400), 0), (400, 0, None, 0),
    ];
    for (name, narrower, who, word) in LINE1 {
        use polter_control_room::scene::{place_line, Side};
        let width = 322 - narrower;
        let mut parts = vec![(Side::Lead, 0, name)];
        if let Some(w) = who {
            parts.push((Side::Squeezed, 8, w));
        }
        parts.push((Side::Trail, 8, word));
        let placed = place_line(0, width, &parts);
        let got_name = placed[0].map_or((0, name > 0), |p| (p.right - p.left, p.cut));
        let who_says = match who.and_then(|_| placed[1]) {
            Some(p) => format!("{} cut={}", p.right - p.left, p.cut),
            None => "-".to_string(),
        };
        println!(
            "line1 width={width} name={name} who={} word={word} -> name={} cut={} who={who_says}",
            who.map_or("-".to_string(), |w| w.to_string()),
            got_name.0,
            got_name.1
        );
    }
    println!("lone shows bare-id={} group={}", polter_control_room::lone::shown_for(&alone, "0x00000000000000c1").unwrap_or("-"), polter_control_room::lone::shown_for(&alone, "web-app").unwrap_or("-"));

    // Which glyph breathes: with nothing in front, and with each tab that
    // holds a waiting terminal in front -- asked, as a host asks, with the
    // window that tab is in.
    let mut fronts: Vec<Option<(&str, Option<&str>)>> = vec![None];
    let mut windows: Vec<&str> = Vec::new();
    for p in &snap.pulses {
        if let Some(tab) = p.tab.as_deref() {
            if !fronts.iter().flatten().any(|(t, _)| *t == tab) {
                fronts.push(Some((tab, p.window.as_deref())));
            }
        }
        if let Some(window) = p.window.as_deref() {
            if !windows.contains(&window) {
                windows.push(window);
            }
        }
    }
    // And a window none of them is in.
    windows.push("0x00000000000000ff");
    println!("pulses {}", snap.pulses.len());
    for front in &fronts {
        let tab = front.map(|(t, _)| t);
        let window = front.and_then(|(_, w)| w);
        let breathing = pulse::pulsing_row_id(&snap.pulses, window, tab);
        let row = breathing.as_deref().and_then(|id| l.row(id));
        println!("pulse list showing={} rows={}", tab.unwrap_or("-"), row.map_or("-", |r| r.id.as_str()));
    }
    for window in &windows {
        for front in &fronts {
            let tab = front.map(|(t, _)| t);
            let p = pulse::pulsing(&snap.pulses, Some(window), tab, Scope::Window);
            println!(
                "pulse window={window} showing={} terminal={} tab={}",
                tab.unwrap_or("-"),
                p.map_or("-", |p| p.terminal.as_str()),
                p.and_then(|p| p.tab.as_deref()).unwrap_or("-")
            );
        }
    }

    // What each window tab carries, for the same fronts; then a tab the
    // core does not list, and every glyph there is.
    println!("tabs {}", snap.tabs.len());
    for t in &snap.tabs {
        println!(
            "tab {} window={} shown={} draws={}",
            t.tab,
            t.window.as_deref().unwrap_or("-"),
            t.shown.name(),
            pulse::draws_on_window_tab(t.shown)
        );
        let Some(window) = t.window.as_deref() else { continue };
        for front in &fronts {
            let tab = front.map(|(f, _)| f);
            let st = pulse::tab_status(Some(&snap), &t.tab, window, tab);
            println!(
                "tab_status tab={} showing={} shown={} pulses={}",
                t.tab,
                tab.unwrap_or("-"),
                st.shown.name(),
                st.pulses
            );
        }
    }
    let unlisted = pulse::tab_status(Some(&snap), "0x00000000000000fe", windows[0], None);
    println!("tab_status tab=unlisted showing=- shown={} pulses={}", unlisted.shown.name(), unlisted.pulses);
    for s in [Shown::NeedsYou, Shown::Trouble, Shown::DoneUnseen, Shown::Working, Shown::None] {
        println!("tab_draws shown={} draws={}", s.name(), pulse::draws_on_window_tab(s));
    }

    // A group's supervisor: where each group stands and what starting one
    // would use, the roles, and whether there is a choice of them.
    for r in l.rows() {
        match &r.start {
            Some(s) => println!(
                "start id={} state={} can={} failed={} role={} cwd={}",
                r.id,
                s.state.name(),
                s.can_start,
                s.failed.name(),
                s.role.as_deref().unwrap_or("-"),
                quote(&s.cwd)
            ),
            None => println!("start id={} -", r.id),
        }
        // What the core says of the last supervisor, and whether a start
        // goes on with its session.
        match r.start.as_ref().and_then(|s| s.last.as_ref()) {
            Some(l) => println!(
                "start_last id={} cli={} last_role={} last_cli={} heard_ms={} resume={} why={} dir_is_last={} cli_label={} last_cli_label={}",
                r.id,
                l.cli.as_deref().unwrap_or("-"),
                l.role.as_deref().unwrap_or("-"),
                l.last_cli.as_deref().unwrap_or("-"),
                l.heard_ms.map(|n| n.to_string()).unwrap_or_else(|| "-".into()),
                l.can_resume,
                l.why.name(),
                l.cwd_is_last,
                l.cli_label.as_deref().map_or("-".to_string(), quote),
                l.last_cli_label.as_deref().map_or("-".to_string(), quote)
            ),
            None => println!("start_last id={} -", r.id),
        }
        // What the start button says (task 1756).
        println!("start_title id={} says={}", r.id, quote(polter_control_room::scene::start_title(r.project.as_ref())));
        // Whether it asks where to start, and the sentence under the button.
        println!("start_dir id={} asks={}", r.id, polter_control_room::scene::asks_directory(r.project.as_ref()));
        println!("start_note id={} says={}", r.id, start_note_said(r.project.as_ref()));
    }
    // The same over every mix the rule tells apart (the fixture has two).
    for (opens, tie, why, pages) in [
        (true, "bound", "none", None),
        (true, "bound", "none", Some(3)),
        (true, "bound", "none", Some(1)),
        (false, "undecided", "not_taken_up", None),
        (false, "undecided", "none", None),
        (false, "undecided", "pending", None),
        (false, "undecided", "projects_unknown", None),
        (false, "declined", "none", None),
        (false, "bound", "none", None),
    ] {
        let p = polter_control_room::snapshot::ProjectTie { tie: tie.into(), why: why.into(), ask: false, opens_project: opens, pages };
        println!(
            "start_note_case opens={opens} tie={tie} why={why} pages={} asks_dir={} says={}",
            pages.map_or("-".to_string(), |n: u64| n.to_string()),
            polter_control_room::scene::asks_directory(Some(&p)),
            start_note_said(Some(&p))
        );
    }
    for why in polter_control_room::snapshot::ResumeWhy::ALL {
        println!("resume_why {}", why.name());
    }
    // Who the core says is working in every terminal: which of its three
    // answers, the three words a project's pane keeps, and who opened it.
    for t in &snap.terminals {
        match &t.who {
            Some(w) => println!(
                "who id={} is={} role={} cli={} session={} worker_of={}",
                t.id,
                w.is.name(),
                w.role.as_deref().map(quote).unwrap_or_else(|| "-".into()),
                w.cli.as_deref().map(quote).unwrap_or_else(|| "-".into()),
                w.session.as_deref().map(quote).unwrap_or_else(|| "-".into()),
                w.worker_of.as_deref().unwrap_or("-")
            ),
            None => println!("who id={} -", t.id),
        }
    }
    for is in polter_control_room::snapshot::WhoIs::ALL {
        println!("who_is {}", is.name());
    }
    // What the right-hand side makes of that: the sentence for each reason
    // a start will not go on with the last session (none for the two that
    // need none), what the two sessions are called, what a start sends for
    // every state of the choice, and the sentence about the last supervisor
    // for each mix of what is known of it.
    {
        use polter_control_room::act::{session_sent, Session};
        use polter_control_room::scene;
        use polter_control_room::snapshot::{ResumeWhy, StartFailure, SupervisorLast, SupervisorStart, SupervisorState};
        let same = |s: &str| s.to_string();
        let or_dash = |s: Option<String>| s.map_or("-".to_string(), |s| quote(&s));
        // Whether a split asked of a terminal is made: of one the control
        // room is showing, for an agent (asked through the core) and not
        // for a key.
        for lent in [false, true] {
            for core in [false, true] {
                println!("new_split lent={lent} asked_by_core={core} made={}", polter_control_room::lend::may_split(lent, core));
            }
        }
        for why in ResumeWhy::ALL {
            println!("resume_note {} says={}", why.name(), or_dash(scene::resume_note(why).map(str::to_string)));
        }
        for session in Session::ALL {
            println!("session_option {} says={}", session.name(), quote(scene::session_words(session)));
        }
        for offered in [true, false] {
            for picked in [None, Some(Session::Last), Some(Session::New)] {
                println!(
                    "session_sent offered={offered} picked={} sends={}",
                    picked.map_or("-", Session::name),
                    session_sent(offered, picked).map_or("-", Session::name)
                );
            }
        }
        // (name, heard, the directory, it is the last supervisor's, its CLI, the core's name for it,
        //  the directory the person picked, can go on)
        #[allow(clippy::type_complexity)]
        let cases: [(&str, Option<u64>, &str, bool, Option<&str>, Option<&str>, Option<&str>, bool); 12] = [
            ("unpicked", Some(1), "/Users/me/work", true, Some("claude-code"), Some("Claude Code"), None, true),
            ("picked-the-same", Some(1), "/Users/me/work", true, Some("claude-code"), Some("Claude Code"), Some("/Users/me/work"), true),
            ("picked-elsewhere", Some(1), "/Users/me/work", true, Some("claude-code"), Some("Claude Code"), Some("/srv/other"), true),
            ("home-itself", Some(1), "/Users/me", true, Some("claude-code"), Some("Claude Code"), Some("/srv/other"), true),
            ("no-name-for-the-cli", Some(1), "/Users/me/work", true, Some("claude-code"), None, Some("/srv/other"), false),
            ("an-empty-name", Some(1), "/Users/me/work", true, Some("claude-code"), Some(""), None, false),
            ("directory-is-a-guess", Some(1), "/Users/me/work", false, Some("claude-code"), Some("Claude Code"), Some("/srv/other"), true),
            ("no-directory", Some(1), "", true, Some("codex"), None, Some("/srv/other"), false),
            ("cli-not-written", Some(1), "/Users/me/work", true, None, None, Some("/srv/other"), false),
            ("cli-not-written-unpicked", Some(1), "/Users/me/work", true, None, None, None, false),
            ("cli-empty", Some(1), "/Users/me/work", true, Some(""), Some("Claude Code"), Some("/srv/other"), false),
            ("never-recorded", None, "/Users/me/work", true, Some("claude-code"), Some("Claude Code"), Some("/srv/other"), false),
        ];
        let start = |cwd: &str, last| SupervisorStart { state: SupervisorState::Absent, can_start: true, failed: StartFailure::None, terminal: None, asking: false, clis_read: true, role: None, cwd: cwd.to_string(), last, hookless: None };
        for (name, heard, cwd, is_last, cli, label, picked, can) in cases {
            let s = start(
                cwd,
                Some(SupervisorLast {
                    cli: Some("claude-code".into()),
                    role: None,
                    last_cli: cli.map(str::to_string),
                    heard_ms: heard,
                    can_resume: can,
                    why: if can { ResumeWhy::None } else { ResumeWhy::NoSession },
                    cwd_is_last: is_last,
                    cli_label: Some("Claude Code".into()),
                    last_cli_label: label.map(str::to_string),
                    by_cli: Vec::new(),
                }),
            );
            println!(
                "last_said {name} offers={} says={}",
                scene::offers_session(Some(&s)),
                or_dash(scene::last_supervisor_words(Some(&s), picked, "/Users/me", &same))
            );
        }
        let old = start("/Users/me/work", None);
        println!(
            "last_said core-says-nothing offers={} says={}",
            scene::offers_session(Some(&old)),
            or_dash(scene::last_supervisor_words(Some(&old), None, "/Users/me", &same))
        );
    }
    // What the right-hand side says of a group with no supervisor, for
    // every reason the core gives for the last try having made none -- the
    // two a launcher reports itself among them -- and while one is on its
    // way.
    {
        use polter_control_room::scene::no_supervisor_words;
        use polter_control_room::snapshot::{StartFailure, SupervisorStart, SupervisorState};
        let start = |state, failed, can_start| SupervisorStart { state, can_start, failed, terminal: None, asking: false, clis_read: true, role: None, cwd: String::new(), last: None, hookless: None };
        for failed in StartFailure::ALL {
            println!(
                "start_says state=failed failed={} says={}",
                failed.name(),
                quote(no_supervisor_words(Some(&start(SupervisorState::Failed, failed, true))))
            );
        }
        for state in [SupervisorState::Starting, SupervisorState::Absent] {
            println!(
                "start_says state={} failed=none says={}",
                state.name(),
                quote(no_supervisor_words(Some(&start(state, StartFailure::None, false))))
            );
        }
        // Its CLI asking the person a question in its tab (task 1746).
        let asking = SupervisorStart { asking: true, terminal: Some("0x00000000000000a9".into()), ..start(SupervisorState::Starting, StartFailure::None, false) };
        println!("start_says state=starting failed=none asking=true says={}", quote(no_supervisor_words(Some(&asking))));
    }
    println!("start_roles choose={}", l.choose_supervisor_role);
    for role in &l.supervisor_roles {
        println!("start_role key={} name={}", role.key, quote(&role.name));
        for c in &role.clis {
            println!("start_role_cli role={} key={} label={}", role.key, c.key, c.label.as_deref().map_or("-".to_string(), quote));
        }
        for h in &role.held_back {
            println!("start_role_held role={} key={} label={} why={}", role.key, h.key, h.label.as_deref().map_or("-".to_string(), quote), h.why.name());
        }
    }
    // Which agent CLI a start uses and what becomes of "Go on with the last
    // session" (#1678): every group a supervisor can be started for, in
    // every role, with nothing picked and with each of the role's CLIs.
    {
        use polter_control_room::scene;
        let same = |s: &str| s.to_string();
        // And each the same while the adapters are not read yet (task
        // 1741): the last session looked for, the CLIs' names not known.
        let unread = |s: &polter_control_room::snapshot::SupervisorStart| {
            use polter_control_room::snapshot::ResumeWhy;
            let mut u = s.clone();
            u.clis_read = false;
            if let Some(l) = u.last.as_mut() {
                l.can_resume = false;
                l.why = ResumeWhy::ClisUnread;
                for b in l.by_cli.iter_mut() {
                    b.can = false;
                    b.why = ResumeWhy::ClisUnread;
                }
            }
            u
        };
        let fill = |said: Option<(&str, Vec<String>)>| said.map(|(t, args)| args.iter().fold(same(t), |said, a| list::fill(&said, a)));
        for r in l.rows() {
            let Some(read) = r.start.as_ref().filter(|_| r.alone.is_none()) else { continue };
            for (tag, start) in [("start_cli", read.clone()), ("start_cli_unread", unread(read))] {
                if tag == "start_cli_unread" {
                    let parts = scene::last_supervisor_parts(&start, None, "", &same);
                    println!("start_parts group={} parts={}", r.id, parts.map_or("-".to_string(), |(b, a)| format!("{}|{}", quote(&b), quote(&a))));
                }
                for role in &l.supervisor_roles {
                    let picks: Vec<Option<&str>> = std::iter::once(None).chain(role.clis.iter().map(|c| Some(c.key.as_str()))).collect();
                    for picked in picks {
                        let c = scene::cli_choice(&start, &l.supervisor_roles, Some(&role.key), picked);
                        let says = fill(scene::resume_said(&c, start.last.as_ref()));
                        let tip = fill(scene::resume_tooltip(&c, start.last.as_ref()));
                        println!(
                            "{} group={} role={} picked={} shown={} room={} on={} resume={} why={} gone={} says={} tip={} sends_cli={} sends_session={} sends_new={} enabled={} enabled_new={}",
                            tag,
                            r.id,
                            role.key,
                            picked.unwrap_or("-"),
                            u8::from(c.shown),
                            c.room,
                            c.picked.as_deref().unwrap_or("-"),
                            c.resume.name(),
                            c.why.name(),
                            c.last_gone.as_deref().map_or("-".to_string(), quote),
                            says.map_or("-".to_string(), |s| quote(&s)),
                            tip.map_or("-".to_string(), |s| quote(&s)),
                            c.picked.as_deref().unwrap_or("-"),
                            scene::session_for(&c, None).map_or("-", |s| s.name()),
                            scene::session_for(&c, Some(polter_control_room::act::Session::New)).map_or("-", |s| s.name()),
                            u8::from(scene::start_enabled(&c, None)),
                            u8::from(scene::start_enabled(&c, Some(polter_control_room::act::Session::New)))
                        );
                    }
                }
            }
        }
        // A CLI the read of the adapters finds not installed (task 1741):
        // each role's last CLI held back for it. The "Agent CLI" line
        // keeps its room.
        let gone: Vec<_> = l
            .supervisor_roles
            .iter()
            .map(|role| {
                let mut g = role.clone();
                if let Some(last) = g.clis.pop() {
                    g.held_back.push(polter_control_room::snapshot::HeldBack { key: last.key, label: last.label, why: polter_control_room::snapshot::HeldWhy::NotInstalled });
                }
                g
            })
            .collect();
        for r in l.rows() {
            let Some(start) = r.start.as_ref().filter(|_| r.alone.is_none()) else { continue };
            for role in &gone {
                let c = scene::cli_choice(start, &gone, Some(&role.key), None);
                println!("start_room group={} role={} shown={} room={} on={} resume={}", r.id, role.key, u8::from(c.shown), c.room, c.picked.as_deref().unwrap_or("-"), c.resume.name());
            }
        }
    }
    // A group just made: selected when it is listed, not before.
    for awaited in [Some("billing"), Some("not-yet"), None] {
        println!("made awaited={} select={}", awaited.unwrap_or("-"), rules::made_group_to_select(awaited, &l).unwrap_or("-"));
    }
    // Where a tab the core asked for goes, for every asker and every place
    // the control room can be.
    let askers = [None, Some((false, false)), Some((false, true)), Some((true, false)), Some((true, true))];
    for asker in askers {
        for bits in 0..16u8 {
            let (person, front, beside, any) = (bits & 8 != 0, bits & 4 != 0, bits & 2 != 0, bits & 1 != 0);
            let home = |h: rules::Home| match h {
                rules::Home::Askers => "askers",
                rules::Home::ControlRooms => "control_rooms",
                rules::Home::Frontmost => "frontmost",
            };
            let to = match rules::new_tab(asker, person, front, beside, any) {
                rules::NewTab::InFront(h) => format!("in_front({})", home(h)),
                rules::NewTab::Behind(h) => format!("behind({})", home(h)),
                rules::NewTab::OwnWindow => "own_window".to_string(),
                rules::NewTab::Refused => "refused".to_string(),
            };
            let who = asker.map_or("app".to_string(), |(lent, has_home)| format!("lent={lent},home={has_home}"));
            println!("new_tab asker={who} person={person} front={front} beside={beside} any={any} -> {to}");
        }
    }
    // Where a project the core ordered opened goes (#1703).
    for bits in 0..8u8 {
        let (front, beside, any) = (bits & 4 != 0, bits & 2 != 0, bits & 1 != 0);
        let home = |h: rules::Home| match h {
            rules::Home::Askers => "askers",
            rules::Home::ControlRooms => "control_rooms",
            rules::Home::Frontmost => "frontmost",
        };
        let to = match rules::ordered_project_tab(front, beside, any) {
            rules::NewTab::InFront(h) => format!("in_front({})", home(h)),
            rules::NewTab::Behind(h) => format!("behind({})", home(h)),
            rules::NewTab::OwnWindow => "own_window".to_string(),
            rules::NewTab::Refused => "refused".to_string(),
        };
        println!("ordered_project_tab front={front} beside={beside} any={any} -> {to}");
    }
    // What the person is told when a group was not made or a supervisor
    // not started, by the core's name for why.
    for name in [
        "BadName", "GroupExists", "TooManyGroups", "HasSupervisor", "AlreadyStarting", "NoSupervisorRole", "NoSuchPersona",
        "NotASupervisorRole", "NoCli", "NotAbsolute", "NoSuchDirectory", "NotADirectory", "OpenFailed", "NoRuntime", "NoExecutable",
        "NotStartedByHand", "AlreadyTakingOver", "NotSetUpForCli", "CliOff", "CliUnavailable", "CliNotInstalled",
    ] {
        println!("refusal {name} says={}", quote(Refusal::parse(name).message()));
    }

    // The frame each pane of a split terminal tab wears: every terminal the
    // core lists, one it does not and none at all, in each place a pane can
    // be; then the word for what each frame is.
    let mut ids: Vec<Option<String>> = snap.terminals.iter().map(|t| Some(t.id.clone())).collect();
    ids.push(Some("0x00000000000000fe".to_string()));
    ids.push(None);
    println!("panes {}", snap.terminals.len());
    let places = [
        ("split", pane::Place { enabled: true, quick_terminal: false, alone: false }),
        ("alone", pane::Place { enabled: true, quick_terminal: false, alone: true }),
        ("off", pane::Place { enabled: false, quick_terminal: false, alone: false }),
        ("quick", pane::Place { enabled: true, quick_terminal: true, alone: false }),
    ];
    for (place_name, place) in places {
        let mut all = Vec::new();
        for id in &ids {
            let set = colours.of(id.as_deref());
            let d = pane::drawn(id.as_deref(), "own", place, Some(&snap.terminals), set);
            match &d {
                Some(d) => println!(
                    "pane place={place_name} terminal={} wears={} name={} shown={} word={}",
                    id.as_deref().unwrap_or("-"),
                    d.wears.name(),
                    quote(&d.title.name),
                    d.title.shown.name(),
                    quote(&d.title.word)
                ),
                None => println!("pane place={place_name} terminal={} wears=-", id.as_deref().unwrap_or("-")),
            }
            // Tasks 1692 and 1700: the badge at the left of the bar, the edge
            // with no frames, and the mark on a stack's tab, in both themes.
            for (theme_name, dark) in [("light", false), ("dark", true)] {
                let theme = polter_control_room::look::theme(dark);
                let (kind, c) = pane::badge(d.as_ref());
                let badged = c.filter(|_| kind != pane::BadgeKind::None);
                let edge = pane::edged(id.as_deref(), place, Some(&snap.terminals), set);
                // The stack's tab: what `panestack::stack` makes of the member.
                let member = panestack::stack(&[(id.as_deref(), "own")], 0, Some(&snap.terminals), &[], &[set]);
                let stack = member.members[0].mark().map(|(_, c)| c.ink(theme));
                println!(
                    "pane_mark theme={theme_name} place={place_name} terminal={} badge={} ground={} text={} edge={} stack={}",
                    id.as_deref().unwrap_or("-"),
                    kind.name(),
                    hex(badged.map(|c| c.badge(theme))),
                    hex(badged.map(|c| c.badge_text(theme))),
                    hex(edge.map(|c| c.ink(theme))),
                    hex(stack),
                );
            }
            all.push(d);
        }
        println!("pane_ground place={place_name} shows={}", pane::ground_shows(&all));
    }
    let nothing = pane::drawn(Some("0x00000000000000a1"), "own", places[0].1, None, None);
    println!("pane no-snapshot wears={} name={}", nothing.as_ref().map_or("-", |d| d.wears.name()), quote(nothing.as_ref().map_or("", |d| &d.title.name)));
    for w in snapshot::Pane::ALL {
        println!("pane_role wears={} word={}", w.name(), pane::role_word(w).map_or("-".to_string(), quote));
    }

    // A window tab's flag and dots (task 1700), for each case beside the
    // snapshot, in both themes: what is drawn, how wide up to its last
    // column of dots (the count's words are measured by each host, so not
    // here), and the tooltip in English.
    for (case, panes) in &colours.cases {
        for (theme_name, dark) in [("light", false), ("dark", true)] {
            let theme = polter_control_room::look::theme(dark);
            let (flag, dots) = tabmarks::of_panes(panes);
            let c = tabmarks::cluster(flag.map(|(_, c)| c), &dots, 1.0, |_| 0.0);
            let (shown, plus) = tabmarks::shown(dots.len());
            let width = if plus > 0 { c.w - polter_control_room::look::tab_dots::PLUS_GAP } else { c.w };
            let drawn: Vec<String> = dots.iter().take(shown).map(|d| hex(Some(d.ink(theme)))).collect();
            println!(
                "tab_dots theme={theme_name} case={case} flag={}:{} dots={} plus={plus} width={} tip={}",
                flag.map_or("none", |(f, _)| f.name()),
                hex(flag.map(|(_, c)| c.ink(theme))),
                if drawn.is_empty() { "-".to_string() } else { drawn.join(",") },
                width,
                quote(&tabmarks::tip(panes, &|m| m.to_string()).unwrap_or_default()),
            );
        }
    }

    // Task 1714: the group's "Project ›" menu, the words at the right end of
    // its row, and how long the line saying a project was made stays --
    // over the cases beside the snapshot (project_link_cases.json).
    let links = ProjectLinkCases::read(&args[1]);
    for c in &links.menu {
        let items: Vec<String> = project_link::menu(&c.tie, &c.why, c.steward).iter().map(project_link::Item::id).collect();
        println!(
            "project_menu tie={} why={} steward={} -> {}",
            c.tie,
            c.why,
            if c.steward { "yes" } else { "no" },
            items.join(",")
        );
        println!(
            "project_note tie={} why={} name={} -> {}",
            c.tie,
            c.why,
            c.name.as_deref().unwrap_or("-"),
            project_link::note(&c.tie, &c.why, c.name.as_deref()).said()
        );
    }
    for h in &links.hint {
        let mut clock = HintClock::default();
        for &(at, visible) in &h.steps {
            clock.look(at, visible);
            if h.close_at == Some(at) {
                clock.close();
            }
        }
        let said = if clock.gone() { "gone".to_string() } else { format!("remaining={}", seconds(clock.remaining())) };
        println!("hint_clock case={} -> {said}", h.case);
    }

    // Looking at a row: which are marked seen, and after how long. The
    // wait is over at once and the control room is in front.
    for r in l.rows() {
        let mut marker = SeenMarker::default();
        let said = match marker.selection_changed(Some(r)) {
            None => "-".to_string(),
            Some(dwell) => match marker.due(&dwell, true) {
                Some(Act::Seen { group }) => format!("after={:.3} marks={group}", selection::SEEN_AFTER),
                Some(Act::SeenTerminal { terminal }) => format!("after={:.3} marks_terminal={terminal}", selection::SEEN_AFTER),
                _ => format!("after={:.3}", selection::SEEN_AFTER),
            },
        };
        println!("seen row={} {said}", r.id);
    }
    // What the title of the frame on the right says while it holds each
    // row's terminal: that terminal's own name, glyph and word.
    for r in l.rows() {
        match &r.title {
            Some(t) => {
                let said = |s: Option<&polter_control_room::snapshot::Say>| s.map_or(String::new(), |n| polter_control_room::snapshot::fill(&n.template, &n.args));
                println!(
                    "frame_title row={} name={} shown={} word={} note={} take_over={} confirm={} status={}",
                    r.id,
                    quote(&t.name),
                    t.shown.name(),
                    quote(&t.word),
                    quote(&said(t.note.as_ref())),
                    t.take_over.as_ref().map_or("-", |o| if o.offered { "offered" } else { "not_offered" }),
                    quote(&said(t.take_over.as_ref().and_then(|o| o.confirm.as_ref()))),
                    quote(&said(t.take_over.as_ref().and_then(|o| o.status.as_ref()))),
                )
            }
            None => println!("frame_title row={} -", r.id),
        }
    }
    // What marking a row seen sends, for every row as if nobody had looked
    // at it: a group's by the group's name, a lone terminal's by the
    // terminal.
    for r in l.rows() {
        let mut unseen = r.clone();
        unseen.unseen = true;
        let mut marker = SeenMarker::default();
        let sends = marker
            .selection_changed(Some(&unseen))
            .and_then(|dwell| marker.due(&dwell, true).and_then(|a| act::encode(&a)))
            .unwrap_or("-".to_string());
        println!("seen_sends row={} {sends}", r.id);
    }

    // Which terminal is shown on the right, through one script of events:
    // what each asks to be done, in order, and what the right side shows
    // after it. (`Place::Elsewhere` is this host's own and is not in the
    // script; the crate's tests hold it.)
    {
        use polter_control_room::lend::{Detail as Shows, Effect, Event, Lending, Place};
        let sel = |g: Option<&str>, s: Option<&str>, here: bool| Event::Selected {
            group: g.map(str::to_string),
            supervisor: s.map(str::to_string),
            place: if here { Place::Here } else { Place::Gone },
        };
        let t = |s: &str| s.to_string();
        let script: Vec<(&str, Event)> = vec![
            ("select a/t1", sel(Some("a"), Some("t1"), true)),
            ("select b/t2", sel(Some("b"), Some("t2"), true)),
            ("select b/t2 again", sel(Some("b"), Some("t2"), true)),
            ("select c/t2", sel(Some("c"), Some("t2"), true)),
            ("select d/none", sel(Some("d"), None, false)),
            ("select a/t1", sel(Some("a"), Some("t1"), true)),
            ("reclaim t1", Event::Reclaimed { terminal: t("t1") }),
            ("select a/t1", sel(Some("a"), Some("t1"), true)),
            ("ask", Event::AskedFor),
            ("ask again", Event::AskedFor),
            ("home gone t9", Event::HomeGone { terminal: t("t9") }),
            ("home gone t1", Event::HomeGone { terminal: t("t1") }),
            ("select a/t1 gone", sel(Some("a"), Some("t1"), false)),
            ("select a/t1", sel(Some("a"), Some("t1"), true)),
            ("select a/t1 gone", sel(Some("a"), Some("t1"), false)),
            ("select a/t1", sel(Some("a"), Some("t1"), true)),
            ("close", Event::Closing),
            ("close again", Event::Closing),
            ("select nothing", sel(None, None, false)),
        ];
        let mut lending = Lending::default();
        for (n, (name, event)) in script.into_iter().enumerate() {
            let effects: Vec<String> = lending
                .handle(event)
                .into_iter()
                .map(|e| match e {
                    Effect::GiveBack { terminal, to_home, focus } => format!("back({terminal},home={to_home},focus={focus})"),
                    Effect::Borrow(loan) => format!("borrow({},{})", loan.group, loan.terminal),
                })
                .collect();
            let shows = match lending.detail() {
                Shows::NothingSelected => "nothing".to_string(),
                Shows::NoSupervisor { group } => format!("no-supervisor({group})"),
                Shows::SupervisorGone { group } => format!("gone({group})"),
                Shows::Elsewhere(loan) => format!("elsewhere({},{})", loan.group, loan.terminal),
                Shows::TakenBack(loan) => format!("taken-back({},{})", loan.group, loan.terminal),
                Shows::Terminal(loan) => format!("terminal({},{})", loan.group, loan.terminal),
            };
            let loan = lending.loan().map_or("-".to_string(), |l| format!("{},{}", l.group, l.terminal));
            println!("lend {n} {} does=[{}] shows={shows} loan={loan}", quote(name), effects.join(" "));
        }
    }

    match &snap.quota {
        Some(q) => {
            let windows = |ws: &[quota::Window]| {
                ws.iter()
                    .map(|w| format!("{}:{}:{}:{}", w.span.name(), w.used, w.live, w.resets_ms))
                    .collect::<Vec<_>>()
                    .join(",")
            };
            let ago = |a: &Option<quota::Ago>| a.map_or("-".to_string(), |a| format!("{}:{}", a.unit.name(), a.n));
            for a in &q.alerts {
                println!(
                    "quota alert family={} level={} span={} used={} resets={} when={}:{} stale={} way_out={} at={} windows={}",
                    a.family.name(),
                    a.level.name(),
                    a.span.name(),
                    a.used,
                    a.resets_ms,
                    a.when.form.name(),
                    a.when.n,
                    ago(&a.stale),
                    a.way_out.map_or("-", |f| f.name()),
                    a.at_ms,
                    windows(&a.windows),
                );
            }
            match &q.line {
                Some(line) => {
                    println!("quota line label={} entries={}", line.label.name(), line.entries.len());
                    for e in &line.entries {
                        println!(
                            "quota entry family={} state={} used={} span={} stale={} at={} windows={}",
                            e.family.name(),
                            e.state.name(),
                            e.used.map_or("-".to_string(), |n| n.to_string()),
                            e.span.map_or("-", |s| s.name()),
                            ago(&e.stale),
                            e.at_ms.map_or("-".to_string(), |n| n.to_string()),
                            windows(&e.windows),
                        );
                    }
                }
                None => println!("quota line none"),
            }
            let ql = quota::layout(q);
            for (y, h, note) in &ql.parts {
                println!("quota part y={y:.3} h={h:.3} note={note}");
            }
            println!("quota height={:.3} line_y={}", ql.height, ql.line_y.map_or("-".to_string(), |y| format!("{y:.3}")));
            quota_words("fixture", q);
        }
        None => println!("quota none"),
    }
    // What the block says (task 1755), for the macOS host's eight made-up
    // states (`ControlRoomQuota.Sample`), on UTC and in English.
    for (name, q) in quota_samples() {
        quota_words(name, &q);
    }

    for (n, (wants, current, width, status)) in stackstrip::CASES.iter().enumerate() {
        let sl = stackstrip::layout(wants, *current, *width, *status);
        let tabs: Vec<String> = sl
            .tabs
            .iter()
            .map(|t| format!("{}@{:.3}+{:.3}{}{}{}", t.member, t.x, t.width, if t.current { "*" } else { "" }, if t.separator_before { "|" } else { "" }, if t.squeezed { "~" } else { "" }))
            .collect();
        println!(
            "strip {n} tabs=[{}] viewport={:.3} content={:.3} add={:.3} status={}",
            tabs.join(" "),
            sl.viewport,
            sl.content,
            sl.add_x,
            sl.status.map_or("-".to_string(), |(a, b)| format!("{a:.3}..{b:.3}")),
        );
    }
    // The other candidate for the least width, and where the tab in front
    // is scrolled to from three offsets (task 1582).
    for (n, (wants, current, width, status)) in stackstrip::CASES.iter().enumerate() {
        let sl = stackstrip::layout_with(wants, *current, *width, *status, 68.0);
        let widths: Vec<String> = sl.tabs.iter().map(|t| format!("{}:{:.3}", t.member, t.width)).collect();
        let table = stackstrip::layout(wants, *current, *width, *status);
        let revealed: Vec<String> = [0.0, 250.0, 10000.0]
            .iter()
            .map(|o| format!("{:.3}", stackstrip::revealing(&table, *current, *o)))
            .collect();
        let carried: Vec<String> = [&[6usize, 4, 0, 2][..], &[0, 2, 4, 9, 11], &[]]
            .iter()
            .map(|urgent| {
                let (l, r) = stackstrip::beyond(&table, urgent, stackstrip::revealing(&table, *current, 0.0));
                format!("{}|{}", l.map_or("-".to_string(), |i| i.to_string()), r.map_or("-".to_string(), |i| i.to_string()))
            })
            .collect();
        let closes: Vec<String> = [0.0f64, 250.0, 10000.0]
            .iter()
            .map(|&o| {
                let o = o.min(table.max_offset());
                table.tabs.iter().filter(|t| stackstrip::close_seen(&table, t.member, o)).map(|t| t.member.to_string()).collect::<Vec<_>>().join(",")
            })
            .collect();
        println!(
            "strip {n} at68=[{}] scrolls68={} reveals={} carries={} closes={}",
            widths.join(" "),
            sl.scrolls(),
            revealed.join("/"),
            carried.join("/"),
            closes.join("/")
        );
    }
    for name in ["", "api", "frontend", "任务", "billing-worker"] {
        println!("strip nominal {} plain={:.3} glyph={:.3}", quote(name), stackstrip::nominal_width(name, false), stackstrip::nominal_width(name, true));
    }

    let lay = ListLayout::new(&l, height);
    println!("size w={:.3} h={:.3}", lay.width, lay.height);
    rect("header", lay.header);
    for (id, r) in &lay.rows {
        rect(&format!("row:{id}"), *r);
    }
    // How what each waiting row waits on is fitted, by the nominal count.
    for (id, fit) in &lay.fits {
        let lines: Vec<String> = fit.lines.iter().map(|n| n.to_string()).collect();
        println!("fit id={id} lines={} hidden={} drawn={}", lines.join("+"), fit.hidden, fit.drawn());
    }
    println!("ask w={:.3}", layout::ask_width());
    // The rule itself, away from the fixture: what each step wants, in.
    for wanted in FITS {
        let fit = layout::AskFit::fit(wanted);
        let w: Vec<String> = wanted.iter().map(|n| n.to_string()).collect();
        let l: Vec<String> = fit.lines.iter().map(|n| n.to_string()).collect();
        println!("fit-of {} lines={} hidden={} drawn={}", w.join("+"), l.join("+"), fit.hidden, fit.drawn());
    }
    for text in NOMINAL {
        println!("nominal {} lines={}", quote(text), layout::nominal_lines(text));
    }
    rect("separator", lay.separator);
    rect("quiet_header", lay.quiet_header);

    let ids: Vec<Option<String>> =
        std::iter::once(None).chain(l.rows().map(|r| Some(r.id.clone()))).collect();
    for from in &ids {
        for step in [-1i64, 1] {
            let to = list::move_selection(&l, from.as_deref(), step).unwrap_or("-");
            println!("move from={} step={step} to={to}", from.as_deref().unwrap_or("-"));
        }
    }

    // Scrolling the rows (tasks 1654 and 1657): the room they are seen in
    // with the allowance block at the bottom -- which this host does not
    // draw yet, and gives the height it will have -- how tall what scrolls
    // is, which rows are wholly seen and how far the selection scrolls
    // them, at the top, part way and at the end; then the rule itself on
    // made-up rows.
    // In a panel as tall as asked, and in one too short for the rows, so
    // that they do scroll.
    for tall in [height, 300.0] {
        let room = ListLayout::new(&l, tall).with_quota(snap.quota.as_ref().map_or(0.0, |q| quota::layout(q).height));
        rect(&format!("viewport h={tall:.3}"), room.viewport);
        let max = layout::scroll::max(room.content_height, room.viewport);
        println!("content h={:.3} max={:.3}", room.content_height, max);
        for scrolled in [0.0, max.min(100.0), max] {
            let at = room.clone().scrolled_to(scrolled);
            println!("in_sight scrolled={:.3} rows={}", at.scrolled, polter_control_room::alert::in_sight(&at).join(","));
            for r in l.rows() {
                let to = at.reveal(Some(&r.id)).map_or("-".to_string(), |v| format!("{v:.3}"));
                println!("reveal scrolled={:.3} id={} to={to}", at.scrolled, r.id);
            }
        }
    }
    for (vy, vh) in [(40.0, 200.0), (0.0, 50.0), (10.0, 0.0)] {
        let view = Rect { x: 0.0, y: vy, w: 300.0, h: vh };
        for (ry, rh) in [(40.0, 28.0), (20.0, 28.0), (230.0, 28.0), (226.0, 28.0), (100.0, 300.0), (50.0, 0.0), (240.0, 10.0)] {
            for scrolled in [0.0, 30.0, 200.0] {
                let row = Rect { x: 0.0, y: ry, w: 300.0, h: rh };
                let to = layout::scroll::reveal(row, view, scrolled).map_or("-".to_string(), |v| format!("{v:.3}"));
                println!(
                    "reveal-of view={vy:.3}+{vh:.3} row={ry:.3}+{rh:.3} scrolled={scrolled:.3} to={to} in_view={}",
                    layout::scroll::in_view(row, view, scrolled)
                );
            }
        }
    }

    // The chip's slide: whether it moves, when it starts down, when it is
    // still, and where it is at the same moments on both sides.
    let plan_name = |p: slide::Plan| match p {
        slide::Plan::Jump => "jump".to_string(),
        slide::Plan::Slide { dx, dy } => format!("slide dx={dx:.6} dy={dy:.6}"),
    };
    let tab_was = Rect { x: 0.0, y: 0.0, w: 293.0, h: 24.0 };
    let tab_now = Rect { x: 588.0, y: 0.0, w: 292.0, h: 24.0 };
    let row_was = Rect { x: 6.0, y: 38.0, w: 368.0, h: 100.0 };
    let row_now = Rect { x: 6.0, y: 146.0, w: 368.0, h: 80.0 };
    // "still" is the person asking for no motion: Reduce Motion there, the
    // system's animations off here.
    println!("slide plan tab still=false {}", plan_name(slide::plan(Some(tab_was), tab_now, true)));
    println!("slide plan tab still=true {}", plan_name(slide::plan(Some(tab_was), tab_now, false)));
    println!("slide plan row still=false {}", plan_name(slide::plan(Some(row_was), row_now, true)));
    println!("slide plan nowhere still=false {}", plan_name(slide::plan(None, tab_now, true)));
    println!("slide plan same still=false {}", plan_name(slide::plan(Some(tab_now), tab_now, true)));
    println!("slide lands_at={:.6} duration={:.6}", slide::lands_at(), slide::duration());
    const MOMENTS: [f64; 16] = [0.0, 0.01, 0.035, 0.07, 0.1, 0.11, 0.15, 0.2, 0.26, 0.3, 0.36, 0.4, 0.405, 0.41, 0.5, 1.0];
    for (name, dx, dy, scale) in [("tab", -587.5, 0.0, selection::LIFT_SCALE_WINDOW_TAB), ("row", 0.0, -98.0, selection::LIFT_SCALE_ROW)] {
        for t in MOMENTS {
            let s = slide::sample(t, dx, dy, scale);
            println!(
                "slide {name} t={t:.6} dx={:.6} dy={:.6} along={:.6} across={:.6} lift={:.6} over={}",
                s.dx,
                s.dy,
                s.along,
                s.across,
                slide::lift(t),
                slide::over(t)
            );
        }
    }

    // The list's layout with what it depends on besides the list (task
    // 1661): a line under the first waiting row and the first quiet one,
    // and two groups put away, their section closed and open.
    let under_ids: Vec<String> = [l.waiting.first(), l.quiet.first()].into_iter().flatten().map(|r| r.id.clone()).collect();
    for open in [false, true] {
        let extras = layout::Extras { lines_under: under_ids.clone(), archived: vec!["old-app".into(), "spike-pdf".into()], archived_open: open };
        let room = ListLayout::measured_with(&l, height, &|text, _| layout::nominal_lines(text), &extras);
        println!("extras open={open} content h={:.3}", room.content_height);
        for r in l.rows() {
            if let Some(frame) = room.chip(Some(&r.id)) {
                rect(&format!("extras row:{}", r.id), frame);
            }
            if let Some((_, line)) = room.line_rects.iter().find(|(id, _)| *id == r.id) {
                rect(&format!("extras under:{}", r.id), *line);
            }
        }
        rect("extras archived_separator", room.archived_separator);
        rect("extras archived_header", room.archived_header);
        for (name, frame) in &room.archived_rows {
            rect(&format!("extras archived:{name}"), *frame);
        }
    }

    // The menu on a group's row (tasks 1660 and 1661): what it holds in
    // every state, and what each of its two submenus holds.
    for state in rowmenu::every_state() {
        println!("{}", rowmenu::line(state));
    }
    for id in ["mute", "project"] {
        println!("group_submenu {id} items={}", rowmenu::submenu(id).join(" "));
    }
    // What "with a new session ›" opens for each group (#1678): the CLIs of
    // the role the core would start, and the one the last supervisor used.
    for r in l.rows() {
        let Some(start) = r.start.as_ref().filter(|_| r.alone.is_none()) else { continue };
        let clis: Vec<String> = start
            .role
            .as_deref()
            .and_then(|k| l.supervisor_roles.iter().find(|x| x.key == k))
            .map(|x| x.clis.iter().map(|c| c.key.clone()).collect())
            .unwrap_or_default();
        let last = start.last.as_ref().and_then(|x| x.last_cli.as_deref());
        println!("{} row={}", rowmenu::cli_submenu_line(&clis, last), r.id);
    }
    // Which supervisor each row's menu is made for (task 1635).
    for r in l.rows() {
        if r.alone.is_none() {
            println!("group_menu_sup row={} sup={}", r.id, rowmenu::sup_of(r).name());
        }
    }
    // How the last ask of each group's supervisor went, and what a line
    // waiting on a retry makes of it (task 1671).
    for r in l.rows() {
        if r.alone.is_none() {
            println!("group_ask row={} {}", r.id, polter_control_room::act::follow_ask_line(None, r.ask.as_ref()));
        }
    }
    for (on, said) in polter_control_room::act::follow_ask_cases() {
        println!("{}", polter_control_room::act::follow_ask_line(on, said.as_ref()));
    }
    // The mark itself: its pages, its strength in each state, and its glow
    // at the scales a screen has.
    use polter_control_room::glyph::Outline;
    use polter_control_room::project_mark::{self, State};
    for s in project_mark::shapes() {
        let Outline::RoundRect(x, y, w, h, r) = s.outline else { panic!("a page is a rounded rectangle") };
        println!("project_mark shape x={x:.3} y={y:.3} w={w:.3} h={h:.3} r={r:.3} level={:.3}", s.level);
    }
    for dark in [false, true] {
        for st in State::ALL {
            println!("project_mark strength dark={dark} state={} {:.3}", st.name(), project_mark::strength(st, dark));
        }
    }
    for scale in [1.0, 1.25, 1.5, 2.0] {
        for strength in [project_mark::strength(State::Rest, true), 1.0] {
            let g = project_mark::glow(scale, strength);
            let mid = g.side / 2;
            println!(
                "project_mark glow scale={scale:.2} strength={strength:.3} reach={:.3} side={} total={:.6} middle={:.6} top_middle={:.6}",
                g.reach,
                g.side,
                g.total(),
                g.at(mid, mid),
                g.at(mid, (g.reach * scale) as usize)
            );
        }
    }
}


/// The words of one allowance block, in English, on UTC.
fn quota_words(name: &str, q: &quota::Quota) {
    let same = |t: &str| t.to_string();
    for a in &q.alerts {
        println!(
            "quota_says {name} alert title={} when={} way_out={}",
            quote(&quota::alert_title(a, &same)),
            quote(&quota::when_text(a, 0, &same)),
            quota::way_out_text(a, &same).map_or("-".to_string(), |w| quote(&w))
        );
    }
    match &q.line {
        Some(line) => {
            println!("quota_says {name} label={}", quote(&quota::label_text(line.label, &same)));
            if line.entries.is_empty() {
                println!("quota_says {name} none_yet={}", quote(quota::msg::NONE_YET));
            }
            for e in &line.entries {
                println!("quota_says {name} entry {} {}", quota::name(e.family), quote(&quota::entry_number(e, &same)));
            }
        }
        None => println!("quota_says {name} no line"),
    }
}

/// `ControlRoomQuota.Sample.all`, as far as what is said goes: the same
/// accounts, numbers and moments.
fn quota_samples() -> Vec<(&'static str, quota::Quota)> {
    use quota::*;
    let now: u64 = 1_699_963_200_000;
    let minute: u64 = 60_000;
    let day: u64 = 24 * 60 * minute;
    let alert = |family, level, span, used, resets_ms, when: When, way_out| Alert {
        family,
        level,
        span,
        used,
        resets_ms,
        when,
        stale: None,
        way_out,
        at_ms: now - minute,
        windows: Vec::new(),
    };
    let entry = |family, state, used, stale| Entry { family, state, used, span: None, stale, at_ms: None, windows: Vec::new() };
    let fresh = |family, used| entry(family, State::Fresh, Some(used), None);
    let used = |entries| Some(Line { label: Label::Used, entries });
    vec![
        ("1-ordinary", Quota { alerts: vec![], line: used(vec![fresh(Family::Claude, 61), fresh(Family::Codex, 20)]) }),
        (
            "2-near",
            Quota {
                alerts: vec![alert(Family::Claude, Level::Near, Span::FiveHour, 92, now + 40 * minute, When { form: WhenForm::Minutes, n: 40 }, None)],
                line: used(vec![fresh(Family::Codex, 20)]),
            },
        ),
        (
            "3-out-with-room",
            Quota {
                alerts: vec![alert(Family::Claude, Level::Out, Span::FiveHour, 100, now + 100 * minute, When { form: WhenForm::Clock, n: 0 }, Some(Family::Codex))],
                line: used(vec![fresh(Family::Codex, 20)]),
            },
        ),
        (
            "4-out-both-high",
            Quota {
                alerts: vec![
                    alert(Family::Claude, Level::Out, Span::FiveHour, 100, now + 100 * minute, When { form: WhenForm::Clock, n: 0 }, None),
                    alert(Family::Codex, Level::Near, Span::SevenDay, 85, now + 3 * day, When { form: WhenForm::Days, n: 3 }, None),
                ],
                line: None,
            },
        ),
        (
            "5-stale",
            Quota {
                alerts: vec![],
                line: used(vec![fresh(Family::Claude, 61), entry(Family::Codex, State::Stale, Some(20), Some(Ago { unit: AgoUnit::Hours, n: 3 }))]),
            },
        ),
        ("6-recovered", Quota { alerts: vec![], line: used(vec![fresh(Family::Claude, 61), entry(Family::Codex, State::Recovered, None, None)]) }),
        ("7-unreadable", Quota { alerts: vec![], line: used(vec![fresh(Family::Claude, 61), entry(Family::Codex, State::Unreadable, None, None)]) }),
        ("8-none-yet", Quota { alerts: vec![], line: Some(Line { label: Label::NoneYet, entries: vec![] }) }),
        (
            "9-date",
            Quota {
                alerts: vec![alert(Family::Codex, Level::Out, Span::Other, 100, now + 3 * day, When { form: WhenForm::Date, n: 0 }, None)],
                line: None,
            },
        ),
    ]
}

/// The sentence under a group's start button in English, filled, as the
/// macOS dump prints it; "-" for none.
fn start_note_said(project: Option<&polter_control_room::snapshot::ProjectTie>) -> String {
    match polter_control_room::scene::start_note(project) {
        Some((template, args)) => quote(&args.iter().fold(template.to_string(), |said, arg| polter_control_room::list::fill(&said, arg))),
        None => "-".to_string(),
    }
}
