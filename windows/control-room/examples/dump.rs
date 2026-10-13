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
use polter_control_room::pane;
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
    }
    for why in polter_control_room::snapshot::ResumeWhy::ALL {
        println!("resume_why {}", why.name());
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
        let start = |cwd: &str, last| SupervisorStart { state: SupervisorState::Absent, can_start: true, failed: StartFailure::None, role: None, cwd: cwd.to_string(), last };
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
        let start = |state, failed, can_start| SupervisorStart { state, can_start, failed, role: None, cwd: String::new(), last: None };
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
    }
    println!("start_roles choose={}", l.choose_supervisor_role);
    for role in &l.supervisor_roles {
        println!("start_role key={} name={}", role.key, quote(&role.name));
    }
    // A group just made: selected when it is listed, not before.
    for awaited in [Some("billing"), Some("not-yet"), None] {
        println!("made awaited={} select={}", awaited.unwrap_or("-"), rules::made_group_to_select(awaited, &l).unwrap_or("-"));
    }
    // Where a tab the core asked for goes, for every asker and every place
    // the control room can be.
    let askers = [None, Some((false, false)), Some((false, true)), Some((true, false)), Some((true, true))];
    for asker in askers {
        for bits in 0..8u8 {
            let (front, beside, any) = (bits & 4 != 0, bits & 2 != 0, bits & 1 != 0);
            let home = |h: rules::Home| match h {
                rules::Home::Askers => "askers",
                rules::Home::ControlRooms => "control_rooms",
                rules::Home::Frontmost => "frontmost",
            };
            let to = match rules::new_tab(asker, front, beside, any) {
                rules::NewTab::InFront(h) => format!("in_front({})", home(h)),
                rules::NewTab::Behind(h) => format!("behind({})", home(h)),
                rules::NewTab::OwnWindow => "own_window".to_string(),
                rules::NewTab::Refused => "refused".to_string(),
            };
            let who = asker.map_or("app".to_string(), |(lent, has_home)| format!("lent={lent},home={has_home}"));
            println!("new_tab asker={who} front={front} beside={beside} any={any} -> {to}");
        }
    }
    // What the person is told when a group was not made or a supervisor
    // not started, by the core's name for why.
    for name in [
        "BadName", "GroupExists", "TooManyGroups", "HasSupervisor", "AlreadyStarting", "NoSupervisorRole", "NoSuchPersona",
        "NotASupervisorRole", "NoCli", "NotAbsolute", "NoSuchDirectory", "NotADirectory", "OpenFailed", "NoRuntime", "NoExecutable",
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
            let d = pane::drawn(id.as_deref(), "own", place, Some(&snap.terminals));
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
            all.push(d);
        }
        println!("pane_ground place={place_name} shows={}", pane::ground_shows(&all));
    }
    let nothing = pane::drawn(Some("0x00000000000000a1"), "own", places[0].1, None);
    println!("pane no-snapshot wears={} name={}", nothing.as_ref().map_or("-", |d| d.wears.name()), quote(nothing.as_ref().map_or("", |d| &d.title.name)));
    for w in snapshot::Pane::ALL {
        println!("pane_role wears={} word={}", w.name(), pane::role_word(w).map_or("-".to_string(), quote));
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
            Some(t) => println!("frame_title row={} name={} shown={} word={}", r.id, quote(&t.name), t.shown.name(), quote(&t.word)),
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
