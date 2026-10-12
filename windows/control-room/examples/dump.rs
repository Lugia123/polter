//! Print what this crate makes of a snapshot, in the form
//! `tools/control-room-hosts-agree.py` compares with the macOS host's.
//!
//!     cargo run -q -p polter-control-room --example dump -- <snapshot.json> <height>
//!
//! One fact a line. The macOS side prints the same lines from
//! `ControlRoomList.swift`; any line that differs is the two hosts
//! disagreeing about what one snapshot looks like.

use polter_control_room::json::quote;
use polter_control_room::act::{Act, SeenMarker};
use polter_control_room::layout::{self, ListLayout, Rect};
use polter_control_room::list::{self, List, Row};
use polter_control_room::pulse::{self, Scope};
use polter_control_room::quota;
use polter_control_room::look::selection;
use polter_control_room::slide;
use polter_control_room::snapshot::{self, Shown};

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

    println!("count waiting={} quiet={}", l.waiting_count, l.quiet_count);

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
        let row = pulse::pulsing_row(&snap.pulses, window, tab).and_then(|name| l.row(name));
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

    // Looking at a row: which are marked seen, and after how long. The
    // wait is over at once and the control room is in front.
    for r in l.rows() {
        let mut marker = SeenMarker::default();
        let said = match marker.selection_changed(Some(r)) {
            None => "-".to_string(),
            Some(dwell) => match marker.due(&dwell, true) {
                Some(Act::Seen { group }) => format!("after={:.3} marks={group}", selection::SEEN_AFTER),
                _ => format!("after={:.3}", selection::SEEN_AFTER),
            },
        };
        println!("seen row={} {said}", r.id);
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
        }
        None => println!("quota none"),
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
}
