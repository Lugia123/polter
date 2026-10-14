//! Against the core's own fixture: the snapshot `ControlRoom.zig` builds and
//! a Zig test holds to the code. The same file the macOS side decodes.

use crate::act::{self, Act, Refusal, SeenMarker};
use crate::layout::{self, AskFit, ListLayout};

/// A fixed-pitch measurement: `n` characters to a line.
fn cells(n: usize) -> impl Fn(&str) -> usize {
    move |text: &str| text.chars().count().min(n)
}

#[test]
fn a_line_breaks_after_the_last_space_that_fits_and_inside_a_word_only_when_it_must() {
    let w = |text: &str, n: usize| layout::wrap(text, &cells(n));
    assert_eq!(w("npm run build", 40), ["npm run build"]);
    assert_eq!(w("npm run build", 9), ["npm run", "build"]);
    // The space the break falls on is dropped, not carried to the next line.
    assert_eq!(w("aaaa bbbb", 4), ["aaaa", "bbbb"]);
    assert_eq!(w("aaaa bbbb", 5), ["aaaa", "bbbb"]);
    // No space to break at: where the room ends.
    assert_eq!(w("node_modules/.vite/deps", 10), ["node_modul", "es/.vite/d", "eps"]);
    // A leading space is not a place to break (the line would be empty).
    assert_eq!(w(" abcdefgh", 4), [" abc", "defg", "h"]);
    // Nothing is one empty line, and nothing is lost or repeated.
    assert_eq!(w("", 10), [""]);
    for n in 1..30 {
        let text = "rm -rf dist/ .cache/ node_modules/.vite && npm ci && npm run build -- --mode production";
        let joined: String = w(text, n).concat();
        assert_eq!(joined.replace(' ', ""), text.replace(' ', ""), "at {n} to a line");
        assert!(w(text, n).iter().all(|l| l.chars().count() <= n), "at {n} to a line");
    }
    // A measurement that says nothing fits still ends.
    assert_eq!(layout::wrap("abc", &|_| 0), ["a", "b", "c"]);
    // Wide characters are the host's to measure; here each is one.
    assert_eq!(w("发票编号要按租户分开", 4), ["发票编号", "要按租户", "分开"]);
}

#[test]
fn what_does_not_fit_in_a_steps_lines_is_all_on_its_last_line_for_the_host_to_cut() {
    let b = |text: &str, lines: usize, n: usize| layout::block_lines(text, lines, &cells(n));
    // Fits: as wrapped.
    assert_eq!(b("npm run build", 3, 9), ["npm run", "build"]);
    // Does not: the lines before the last as wrapped, the rest whole on the
    // last -- cut there, never a line dropped from the middle.
    assert_eq!(b("aa bb cc dd ee", 2, 2), ["aa", "bb cc dd ee"]);
    assert_eq!(b("aa bb cc dd ee", 1, 2), ["aa bb cc dd ee"]);
    assert_eq!(b("aa bb cc dd ee", 0, 2), ["aa bb cc dd ee"]);
    assert_eq!(b("", 3, 9), [""]);
    // The number of lines a step needs is how many `wrap` makes of it, and
    // a step given that many loses nothing.
    let text = "rm -rf dist/ .cache/ node_modules/.vite && npm ci";
    let needed = layout::wrap(text, &cells(12)).len();
    assert_eq!(b(text, needed, 12), layout::wrap(text, &cells(12)));
}
use crate::list::{self, List};
use crate::look::{line, side, space, window_tab};
use crate::pulse::{self, Scope, TabStatus};
use crate::snapshot::{self, DecodeError, Form, Header, HeaderNumber, HeaderOf, Shown, WaiterIs};

/// The row of the fixture's one terminal that is in no group.
const LONE: &str = "terminal:0x00000000000000c1";

const FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../src/poltergeist/testdata/control_snapshot.json"
));

fn list() -> List {
    List::from_snapshot(&snapshot::decode(FIXTURE).expect("the fixture decodes"))
}

/// The list as it was before task 1485, with a row for the terminal in no
/// group: what such a row says is still held, though nothing draws one.
fn list_with_lone() -> List {
    List::from_snapshot_with(&snapshot::decode(FIXTURE).expect("the fixture decodes"), true)
}

/// The fixture with its two headings replaced by the ones given, or taken
/// out: what a core that writes none sends.
fn with_headers(waiting: Option<&str>, quiet: Option<&str>) -> String {
    let mut out = FIXTURE.to_string();
    for (key, new) in [("header_waiting", waiting), ("header_quiet", quiet)] {
        let from = out.find(&format!("  \"{key}\": {{")).expect("the fixture has the heading");
        let to = from + out[from..].find("},\n").expect("the heading ends") + 3;
        let put = new.map_or(String::new(), |h| format!("  \"{key}\": {h},\n"));
        out.replace_range(from..to, &put);
    }
    out
}

// -- reading it ---------------------------------------------------------------

#[test]
fn the_fixture_is_read_and_the_counts_are_the_ones_written_in_it() {
    let s = snapshot::decode(FIXTURE).unwrap();
    assert_eq!(s.rev, 1);
    assert_eq!(s.now_ms, 6_000_000);
    // Every row that waits and is drawn is one: five groups. The terminal
    // in no group that waits is listed and not counted (task 1485).
    assert_eq!(s.needs_me, 5);
    assert_eq!(s.ungrouped.iter().filter(|u| u.needs_me).count(), 1);
    assert_eq!(s.groups_needing_me, 5);
    assert_eq!(s.groups_other, 3);
    assert_eq!(s.groups.len(), 8);
    assert_eq!(s.pulses.len(), 5);
}

#[test]
fn nothing_in_the_snapshot_says_how_long() {
    // The minutes and the band of today's waiting were taken out (the
    // user's ruling, 2026-10-13: "no use at all"). A snapshot that carries
    // them again is one this crate was not told about.
    for gone in ["waited_min", "\"band\"", "total_min", "lanes", "spans"] {
        assert!(!FIXTURE.contains(gone), "the fixture says {gone} again");
    }
}

#[test]
fn a_part_is_marked_where_the_rest_would_be_and_never_shown_as_the_whole() {
    use crate::snapshot::{Cut, What};
    let what = |cut, lines: &[&str]| What { form: Form::Words, lines: lines.iter().map(|l| l.to_string()).collect(), cut };
    assert_eq!(list::drawn(&what(Cut::None, &["which branch?"])), ["which branch?"]);
    // The end of a turn: something came before it.
    assert_eq!(list::drawn(&what(Cut::Head, &["half first, or all at once?"])), ["… half first, or all at once?"]);
    // A summary that reached its limit: the mark goes after the last step.
    assert_eq!(list::drawn(&what(Cut::Tail, &["rm -rf dist/", "&& npm ci --pre"])), ["rm -rf dist/", "&& npm ci --pre …"]);
    assert!(list::drawn(&what(Cut::Tail, &[])).is_empty());

    // The core's word, copied; and whatever shows the row shows the mark.
    let l = list();
    let infra = l.row("infra").unwrap();
    assert_eq!(infra.what.cut, Cut::Head);
    assert_eq!(list::tooltip(infra).as_deref(), Some("… 要不要现在切流量？"));
    assert_eq!(l.row("web-app").unwrap().what.cut, Cut::None);

    // Left out, or a word this build does not know, is not "all of it".
    let gone = FIXTURE.replacen("\"cut\": \"none\"", "\"cat\": \"none\"", 1);
    assert_eq!(snapshot::decode(&gone), Err(DecodeError::Field("groups[0].what.cut".into())));
    let odd = FIXTURE.replacen("\"cut\": \"none\"", "\"cut\": \"middle\"", 1);
    assert_eq!(snapshot::decode(&odd), Err(DecodeError::UnknownValue("groups[0].what.cut=middle".into())));
}

#[test]
fn a_row_that_stops_while_the_person_is_on_it_is_seen_after_the_same_wait() {
    let l = list();
    let mut working = l.row("infra").unwrap().clone();
    working.unseen = false;
    let stopped = l.row("infra").unwrap().clone();
    assert!(stopped.unseen);

    let mut marker = SeenMarker::default();
    assert_eq!(marker.selection_changed(Some(&working)), None);
    assert_eq!(marker.list_changed(Some(&working)), None);
    // It finishes, the selection not having moved: one wait.
    let wait = marker.list_changed(Some(&stopped)).expect("a wait begins");
    assert_eq!(marker.due(&wait, true), Some(Act::Seen { group: "infra" }));
    assert_eq!(marker.due(&wait, false), None);
    // More lists before it is over do not begin it again, and do not
    // cancel it.
    assert_eq!(marker.list_changed(Some(&stopped)), None);
    assert_eq!(marker.due(&wait, true), Some(Act::Seen { group: "infra" }));
    // Seen, then stopped a second time: a second wait.
    assert_eq!(marker.list_changed(Some(&working)), None);
    assert!(marker.list_changed(Some(&stopped)).is_some());

    // The person moves on before the wait is over: nothing is sent.
    let wait = marker.selection_changed(Some(&working)).or(marker.list_changed(Some(&stopped))).unwrap();
    marker.selection_changed(l.row("notes"));
    assert_eq!(marker.due(&wait, true), None);
    // A list in which the selection is another row is a change of selection.
    assert!(marker.list_changed(Some(&stopped)).is_some());
    assert_eq!(marker.list_changed(None), None);
}

#[test]
fn who_waits_and_for_what_are_read_and_a_value_not_known_is_an_error() {
    let cut = FIXTURE.replacen("\"waiter\"", "\"waiting\"", 1);
    assert_eq!(snapshot::decode(&cut), Err(DecodeError::Field("groups[0].waiter".into())));
    let cut = FIXTURE.replacen("\"what\"", "\"wat\"", 1);
    assert_eq!(snapshot::decode(&cut), Err(DecodeError::Field("groups[0].what".into())));

    let odd = FIXTURE.replacen("\"is\": \"supervisor\"", "\"is\": \"owner\"", 1);
    assert_ne!(odd, FIXTURE);
    assert_eq!(snapshot::decode(&odd), Err(DecodeError::UnknownValue("groups[0].waiter.is=owner".into())));
    let odd = FIXTURE.replacen("\"form\": \"command\"", "\"form\": \"poem\"", 1);
    assert_ne!(odd, FIXTURE);
    assert_eq!(snapshot::decode(&odd), Err(DecodeError::UnknownValue("groups[0].what.form=poem".into())));
}

#[test]
fn a_glyph_this_build_does_not_know_is_an_error_and_not_a_blank() {
    let odd = FIXTURE.replacen("\"shown\": \"needs_you\"", "\"shown\": \"on_fire\"", 1);
    assert_ne!(odd, FIXTURE);
    assert_eq!(snapshot::decode(&odd), Err(DecodeError::UnknownShown("on_fire".into())));
}

#[test]
fn a_field_that_has_to_be_there_says_which_when_it_is_not() {
    let cut = FIXTURE.replacen("\"groups_needing_me\"", "\"groups_needing_you\"", 1);
    assert_eq!(snapshot::decode(&cut), Err(DecodeError::Field("snapshot.groups_needing_me".into())));

    let wrong = FIXTURE.replacen("\"more\": 1", "\"more\": \"one\"", 1);
    assert_ne!(wrong, FIXTURE);
    assert_eq!(snapshot::decode(&wrong), Err(DecodeError::Field("groups[0].more".into())));

    assert!(matches!(snapshot::decode("{"), Err(DecodeError::Json(_))));
}

// -- the rows -----------------------------------------------------------------

#[test]
fn the_rows_keep_the_snapshots_order_in_two_sections() {
    let l = list();
    let waiting: Vec<&str> = l.waiting.iter().map(|r| r.id.as_str()).collect();
    let quiet: Vec<&str> = l.quiet.iter().map(|r| r.id.as_str()).collect();
    // The groups in the core's order, and nothing else: the terminal that
    // is in no group has no row.
    assert_eq!(waiting, ["web-app", "web-app-docs", "mobile", "billing", "docs-site"]);
    assert_eq!(quiet, ["infra", "design-system", "notes"]);

    let shown: Vec<Shown> = l.rows().map(|r| r.shown).collect();
    assert_eq!(
        shown,
        [
            Shown::NeedsYou,
            Shown::NeedsYou,
            Shown::NeedsYou,
            Shown::NeedsYou,
            Shown::Trouble,
            Shown::DoneUnseen,
            Shown::Working,
            Shown::None
        ]
    );
    let words: Vec<&str> = l.rows().map(|r| r.word.as_str()).collect();
    assert_eq!(words, ["等批准", "等批准", "等批准", "等回答", "出错", "做完了，没看", "在干活", ""]);
}

#[test]
fn the_counts_shown_are_the_ones_handed_in() {
    // A snapshot that says 9 and 0 is drawn as 9 and 0, whatever it holds.
    let odd = with_headers(Some(r#"{"count":9,"of":"groups","number":"other"}"#), Some(r#"{"count":0,"of":"groups","number":"none"}"#));
    let l = List::from_snapshot(&snapshot::decode(&odd).unwrap());
    assert_eq!(l.waiting_count, 9);
    assert_eq!(l.quiet_count, 0);
    assert_eq!(l.waiting.len(), 5);
    assert_eq!(l.quiet.len(), 3);
    // From a core that writes no headings the two are the groups' counts.
    let old = with_headers(None, None)
        .replacen("\"groups_needing_me\": 5", "\"groups_needing_me\": 9", 1)
        .replacen("\"groups_other\": 3", "\"groups_other\": 0", 1);
    let l = List::from_snapshot(&snapshot::decode(&old).unwrap());
    assert_eq!((l.waiting_count, l.quiet_count), (9, 0));
}

#[test]
fn what_a_row_says() {
    let l = list();
    // A command is its steps, one to a line, each whole and the joiner at
    // the head of the step it brings in.
    let web = l.row("web-app").unwrap();
    assert_eq!(web.what.form, Form::Command);
    assert_eq!(
        web.what.lines,
        ["rm -rf dist/ .cache/ node_modules/.vite", "&& npm ci", "&& npm run build -- --mode production"]
    );
    assert!(list::is_code(&web.what));
    assert_eq!(web.waiter.is, WaiterIs::Supervisor);
    assert_eq!(list::waiter(&web.waiter), Some((list::msg::SUPERVISOR, String::new())));
    assert_eq!(list::others(web.others), Some((list::msg::OTHERS, "1".to_string())));
    assert_eq!(
        list::tooltip(web).as_deref(),
        Some("rm -rf dist/ .cache/ node_modules/.vite\n&& npm ci\n&& npm run build -- --mode production")
    );

    // One supervisor, two groups: each row says the whole of it.
    let docs = l.row("web-app-docs").unwrap();
    assert_eq!(docs.what, web.what);
    assert_eq!(list::others(docs.others), None);

    // A worker waits; the person reaches it through the supervisor.
    let mobile = l.row("mobile").unwrap();
    assert_eq!(mobile.waiter.is, WaiterIs::WorkerViaSupervisor);
    let (template, who) = list::waiter(&mobile.waiter).unwrap();
    assert_eq!(list::fill(template, &who), "ios-build, via the supervisor");
    assert_eq!(mobile.what.lines, ["git push --force-with-lease origin release/2.4"]);

    // A question is words: the core says so, nothing here guesses it from
    // where the words came from.
    let billing = l.row("billing").unwrap();
    assert_eq!(billing.what.form, Form::Words);
    assert!(!list::is_code(&billing.what));
    assert_eq!(billing.what.lines.len(), 1);
    assert!(!list::is_code(&l.row("docs-site").unwrap().what));

    // A group that needs nothing: what it is doing, when the core knows.
    let design = l.row("design-system").unwrap();
    assert_eq!(design.what.lines, ["改按钮的三种尺寸"]);
    let notes = l.row("notes").unwrap();
    assert_eq!(notes.what.form, Form::None);
    assert_eq!(list::tooltip(notes), None);
    assert_eq!(list::waiter(&notes.waiter), None);
}

#[test]
fn the_selection_walks_the_rows_and_stops_at_the_ends() {
    let l = list();
    assert_eq!(list::move_selection(&l, None, 1), Some("web-app"));
    assert_eq!(list::move_selection(&l, None, -1), Some("notes"));
    // From the last waiting group to the first quiet one and back: the
    // terminal in no group is not a row, so the keys do not stop on it.
    assert_eq!(list::move_selection(&l, Some("docs-site"), 1), Some("infra"));
    assert_eq!(list::move_selection(&l, Some("infra"), -1), Some("docs-site"));
    assert_eq!(list::move_selection(&l, Some(LONE), 1), Some("web-app"));
    assert_eq!(list::move_selection(&l, Some("notes"), 1), Some("notes"));
    assert_eq!(list::move_selection(&l, Some("web-app"), -3), Some("web-app"));
    // A selection that is no longer listed starts over.
    assert_eq!(list::move_selection(&l, Some("gone"), 1), Some("web-app"));

    assert_eq!(list::restored_selection(&l, Some("billing")), Some("billing"));
    assert_eq!(list::restored_selection(&l, Some("gone")), None);
    assert_eq!(list::restored_selection(&l, None), None);

    // Opening with nothing selected starts on the core's group, which is
    // not the person's choice; a selection that stands is left alone; and
    // later, nothing is selected for them.
    let s = snapshot::decode(FIXTURE).unwrap();
    assert_eq!(s.open_on.as_deref(), Some("web-app"));
    assert_eq!(list::opening_selection(None, true, s.open_on.as_deref()), (Some("web-app"), false));
    assert_eq!(list::opening_selection(Some("billing"), true, s.open_on.as_deref()), (Some("billing"), true));
    assert_eq!(list::opening_selection(None, false, s.open_on.as_deref()), (None, true));
    assert_eq!(list::opening_selection(None, true, None), (None, true));
}

// -- where things are ---------------------------------------------------------

#[test]
fn the_panel_is_laid_out_from_the_look_and_nothing_else() {
    let l = list();
    let lay = ListLayout::new(&l, 800.0);
    let pad = space::SIDE_PANEL_PADDING;
    let inner = side::WIDTH - 2.0 * pad;

    assert_eq!(lay.header, layout::Rect { x: pad, y: pad, w: inner, h: side::HEADER_HEIGHT });
    // Five waiting rows below the header, each as high as what it waits on
    // and a gap apart: 40 for the first line and the padding, 20 a line.
    let high = |id: &str| lay.chip(Some(id)).unwrap().h;
    let first = lay.chip(Some("web-app")).unwrap();
    assert_eq!(first.y, pad + side::HEADER_HEIGHT);
    // Three steps, and a line for "1 more".
    assert_eq!(high("web-app"), 120.0);
    assert_eq!(high("web-app-docs"), 100.0);
    // One step, too long for one line.
    assert_eq!(high("mobile"), 80.0);
    assert_eq!(high("billing"), 80.0);
    assert_eq!(high("docs-site"), 60.0);
    let fourth = lay.chip(Some("docs-site")).unwrap();
    assert_eq!(fourth.y, first.y + 120.0 + 100.0 + 80.0 + 80.0 + 4.0 * side::ROW_GAP);
    assert_eq!(lay.fit("web-app"), Some(&AskFit { lines: vec![1, 1, 1], hidden: 0 }));
    assert_eq!(lay.fit("mobile"), Some(&AskFit { lines: vec![2], hidden: 0 }));
    assert_eq!(lay.fit("infra"), None);
    assert_eq!(layout::ask_width(), 322.0);

    // The terminal in no group has no row: the line follows the last group.
    assert_eq!(lay.chip(Some(LONE)), None);
    assert_eq!(lay.fit(LONE), None);
    let below = fourth.y + 60.0 + side::ROW_GAP + side::SEPARATOR_SPACE_ABOVE;
    assert_eq!(lay.separator.y, below);
    assert_eq!(lay.separator.h, line::HAIRLINE);
    assert_eq!(lay.quiet_header.y, below + line::HAIRLINE + side::SEPARATOR_SPACE_BELOW);

    let infra = lay.chip(Some("infra")).unwrap();
    assert_eq!(infra.y, lay.quiet_header.y + side::HEADER_HEIGHT);
    assert_eq!(infra.h, side::QUIET_ROW_HEIGHT);
    assert_eq!(lay.chip(Some("notes")).unwrap().y, infra.y + 2.0 * side::QUIET_ROW_HEIGHT);
    assert_eq!(lay.chip(Some("gone")), None);
    assert_eq!(lay.chip(None), None);
}

#[test]
fn when_the_core_says_nobody_waits_the_groups_follow_the_one_header() {
    // The core's count, whatever rows there are: 0 means no line and no
    // second header, and the rows that follow start where they would be.
    let none = with_headers(Some(r#"{"count":0,"of":"groups","number":"none"}"#), Some(r#"{"count":9,"of":"rows","number":"other"}"#));
    let l = List::from_snapshot(&snapshot::decode(&none).unwrap());
    let lay = ListLayout::new(&l, 800.0);
    assert_eq!(lay.quiet_header.h, 0.0);
    assert_eq!(lay.separator.h, 0.0);
    let after = lay.chip(Some("docs-site")).unwrap();
    assert_eq!(lay.chip(Some("infra")).unwrap().y, after.y + after.h + side::ROW_GAP);
    let with = ListLayout::new(&list(), 800.0);
    assert_eq!(with.quiet_header.h, side::HEADER_HEIGHT);
}

#[test]
fn a_row_is_as_high_as_the_host_measured_it_to_be() {
    // A host with a font says every step wants four lines: a sentence gets
    // the three there are, a command of three steps one line each.
    let l = list();
    let lay = ListLayout::measured(&l, 800.0, &|_, _| 4);
    assert_eq!(lay.fit("billing"), Some(&AskFit { lines: vec![3], hidden: 0 }));
    assert_eq!(lay.chip(Some("billing")).unwrap().h, 100.0);
    assert_eq!(lay.fit("web-app-docs"), Some(&AskFit { lines: vec![1, 1, 1], hidden: 0 }));
    // Told which face it is set in.
    let asked = std::cell::RefCell::new(Vec::new());
    ListLayout::measured(&l, 800.0, &|text, code| {
        asked.borrow_mut().push((text.to_string(), code));
        1
    });
    let asked = asked.into_inner();
    assert!(asked.contains(&("&& npm ci".to_string(), true)));
    assert!(asked.iter().any(|(text, code)| text.starts_with("发票") && !code));
}

#[test]
fn what_is_cut_is_the_end_of_a_line_and_never_a_step() {
    let max_lines = side::ASK_MAX_LINES as usize;
    let max_steps = side::ASK_MAX_STEPS as usize;
    assert_eq!((max_lines, max_steps), (3, 6));

    assert_eq!(AskFit::fit(&[]), AskFit::default());
    // A sentence: as many lines as it wants, up to the ceiling.
    assert_eq!(AskFit::fit(&[1]).lines, [1]);
    assert_eq!(AskFit::fit(&[2]).lines, [2]);
    assert_eq!(AskFit::fit(&[9]).lines, [3]);
    // Each step a line first; what is left to the earliest that needs it.
    assert_eq!(AskFit::fit(&[3, 1]).lines, [2, 1]);
    assert_eq!(AskFit::fit(&[1, 3]).lines, [1, 2]);
    assert_eq!(AskFit::fit(&[2, 2]).lines, [2, 1]);
    assert_eq!(AskFit::fit(&[9, 9, 9]).lines, [1, 1, 1]);

    // **Every step has a line, however long each is and however many there
    // are, until the second ceiling; past it the ones not shown are counted.**
    for steps in 1..=20 {
        for want in [1, 2, 9] {
            let fit = AskFit::fit(&vec![want; steps]);
            assert!(fit.lines.iter().all(|n| *n >= 1), "{steps} steps wanting {want}: {fit:?}");
            assert_eq!(fit.lines.len() + fit.hidden, steps, "{steps} steps wanting {want}: a step is neither shown nor counted");
            if steps <= max_steps {
                assert_eq!(fit.hidden, 0, "{steps} steps: {fit:?}");
            } else {
                assert_eq!(fit.drawn(), max_steps, "{steps} steps: {fit:?}");
            }
            if steps <= max_lines {
                assert!(fit.drawn() <= max_lines, "{steps} steps wanting {want}: {fit:?}");
            }
        }
    }
    // More steps than lines: the row grows by a line a step.
    assert_eq!(AskFit::fit(&[2, 1, 1, 1]), AskFit { lines: vec![1, 1, 1, 1], hidden: 0 });
    assert_eq!(layout::row_height(&AskFit::fit(&[1, 1, 1, 1]), 0), 120.0);
    assert_eq!(AskFit::fit(&[1; 7]), AskFit { lines: vec![1; 5], hidden: 2 });

    assert_eq!(layout::nominal_lines(""), 1);
    assert_eq!(layout::nominal_lines(&"x".repeat(41)), 1);
    assert_eq!(layout::nominal_lines(&"x".repeat(42)), 2);
    // A wide character is two cells.
    assert_eq!(layout::nominal_lines(&"票".repeat(20)), 1);
    assert_eq!(layout::nominal_lines(&"票".repeat(21)), 2);
}

#[test]
fn the_chip_overshoots_a_little_and_settles() {
    use layout::spring;
    assert_eq!(spring::progress(0.0), 0.0);
    assert!((spring::progress(5.0) - 1.0).abs() < 1e-6);
    let peak = (1..2000).map(|i| spring::progress(i as f64 / 1000.0)).fold(0.0_f64, f64::max);
    let over = spring::overshoot(crate::look::selection::SPRING_DAMPING);
    assert!((peak - 1.0 - over).abs() < 1e-3, "peak {peak}, overshoot {over}");
    assert!(over > 0.02 && over < 0.06);
    // Critically damped never passes 1.
    assert_eq!(spring::overshoot(1.0), 0.0);
    assert!((1..2000).all(|i| spring::progress_with(i as f64 / 1000.0, 0.36, 1.0) <= 1.0));
}

// -- which glyph breathes ---------------------------------------------------

#[test]
fn one_waiting_glyph_breathes_and_not_the_one_being_looked_at() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let window = Some("0x0000000000000010");
    let tab = |n: u8| format!("0x00000000000000{n:02x}");

    // Looking at some other tab: the longest-waiting, which is billing's.
    let other = tab(0x26);
    assert_eq!(pulse::pulsing_row(&s.pulses, window, Some(&other)), Some("billing"));
    let first = pulse::pulsing(&s.pulses, window, Some(&other), Scope::Window).unwrap();
    assert_eq!(first.terminal, "0x00000000000000a2");

    // Looking at billing's own tab: the next one instead.
    let billing = tab(0x22);
    assert_eq!(pulse::pulsing_row(&s.pulses, window, Some(&billing)), Some("web-app-docs"));

    // In a tab bar only this window's terminals are there to breathe.
    let elsewhere = Some("0x0000000000000099");
    assert_eq!(pulse::pulsing(&s.pulses, elsewhere, None, Scope::Window), None);
    // The list shows every group, wherever its terminals are.
    assert_eq!(pulse::pulsing_row(&s.pulses, elsewhere, None), Some("billing"));

    // Nothing waiting, nothing breathes.
    assert_eq!(pulse::pulsing(&[], window, None, Scope::List), None);
}

#[test]
fn exactly_one_row_breathes_whatever_tab_is_showing() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = list();
    let window = Some("0x0000000000000010");
    for showing in [None, Some("0x0000000000000021"), Some("0x0000000000000022"), Some("0x0000000000000027")] {
        let row = pulse::pulsing_row(&s.pulses, window, showing);
        let breathing = l.rows().filter(|r| Some(r.id.as_str()) == row).map(|r| r.id.as_str()).collect::<Vec<_>>();
        assert!(breathing.len() <= 1, "{breathing:?} with {showing:?} showing");
    }
}

// -- what a window tab carries --------------------------------------------------

#[test]
fn a_tab_carries_the_glyph_the_core_gave_it_and_one_of_them_breathes() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let window = "0x0000000000000010";
    let tab = |n: u8| format!("0x00000000000000{n:02x}");
    let status = |t: u8, showing: Option<u8>| {
        pulse::tab_status(Some(&s), &tab(t), window, showing.map(tab).as_deref())
    };

    assert_eq!(s.tabs.len(), 8);
    // Looking at a tab nothing waits in: billing's breathes, the others do not.
    assert_eq!(status(0x22, Some(0x26)), TabStatus { shown: Shown::NeedsYou, pulses: true });
    assert_eq!(status(0x21, Some(0x26)), TabStatus { shown: Shown::NeedsYou, pulses: false });
    assert_eq!(status(0x23, Some(0x26)), TabStatus { shown: Shown::Trouble, pulses: false });
    assert_eq!(status(0x24, Some(0x26)), TabStatus { shown: Shown::DoneUnseen, pulses: false });
    assert_eq!(status(0x25, Some(0x26)), TabStatus { shown: Shown::None, pulses: false });

    // Looking at billing's own tab: it keeps its glyph and the next one breathes.
    assert_eq!(status(0x22, Some(0x22)), TabStatus { shown: Shown::NeedsYou, pulses: false });
    assert_eq!(status(0x21, Some(0x22)), TabStatus { shown: Shown::NeedsYou, pulses: true });

    // In another window nothing of this one breathes, but the glyph is the tab's.
    let elsewhere = pulse::tab_status(Some(&s), &tab(0x22), "0x0000000000000099", None);
    assert_eq!(elsewhere, TabStatus { shown: Shown::NeedsYou, pulses: false });

    // A tab the core does not list, and any tab before the first snapshot.
    assert_eq!(status(0x7f, None), TabStatus::NONE);
    assert_eq!(pulse::tab_status(None, &tab(0x22), window, None), TabStatus::NONE);
}

#[test]
fn a_tabs_glyph_this_build_does_not_know_is_an_error_too() {
    let at = FIXTURE.find("\"tabs\"").expect("the fixture has tabs");
    let odd = format!("{}{}", &FIXTURE[..at], FIXTURE[at..].replacen("\"shown\": \"trouble\"", "\"shown\": \"on_fire\"", 1));
    assert_ne!(odd, FIXTURE);
    assert_eq!(snapshot::decode(&odd), Err(DecodeError::UnknownShown("on_fire".into())));

    let cut = FIXTURE.replacen("\"unseen\"", "\"unsee\"", 1);
    assert_eq!(snapshot::decode(&cut), Err(DecodeError::Field("groups[0].unseen".into())));
    let cut = FIXTURE.replacen("\"tabs\"", "\"tab_list\"", 1);
    assert_eq!(snapshot::decode(&cut), Err(DecodeError::Field("snapshot.tabs".into())));
}

#[test]
fn working_is_drawn_on_a_window_tab_only_if_the_look_says_so() {
    assert!(pulse::draws_on_window_tab(Shown::NeedsYou));
    assert!(pulse::draws_on_window_tab(Shown::Trouble));
    assert!(pulse::draws_on_window_tab(Shown::DoneUnseen));
    assert!(!pulse::draws_on_window_tab(Shown::None));
    assert_eq!(pulse::draws_on_window_tab(Shown::Working), window_tab::WORKING_GLYPH_SHOWN);
}

// -- done, and nobody has looked ------------------------------------------------

#[test]
fn unseen_is_the_cores_word_for_each_row() {
    let l = list();
    let unseen: Vec<&str> = l.rows().filter(|r| r.unseen).map(|r| r.id.as_str()).collect();
    assert_eq!(unseen, ["infra"]);
}

#[test]
fn looking_at_an_unseen_row_long_enough_marks_it_seen() {
    let l = list();
    let infra = l.row("infra").unwrap();
    let billing = l.row("billing").unwrap();
    let mut marker = SeenMarker::default();

    // A row somebody has looked at already starts no wait.
    assert_eq!(marker.selection_changed(Some(billing)), None);
    assert_eq!(marker.selection_changed(None), None);

    // An unseen one does, and when the wait is over it is the seen act.
    let dwell = marker.selection_changed(Some(infra)).expect("infra is unseen");
    assert_eq!(dwell.row, "infra");
    assert_eq!(marker.due(&dwell, true), Some(Act::Seen { group: "infra" }));
    // Not while the control room is behind something else.
    assert_eq!(marker.due(&dwell, false), None);

    // Arrowing past it: the wait that was started is no longer about anything.
    marker.selection_changed(Some(billing));
    assert_eq!(marker.due(&dwell, true), None);
    // Coming back starts a new one; the old one stays dead.
    let again = marker.selection_changed(Some(infra)).unwrap();
    assert_eq!(marker.due(&dwell, true), None);
    assert_eq!(marker.due(&again, true), Some(Act::Seen { group: "infra" }));
}

// -- what the person does -----------------------------------------------------

#[test]
fn an_act_is_the_request_the_core_reads() {
    let l = list();
    let docs = l.row("web-app-docs").unwrap();
    assert_eq!(
        act::encode(&Act::Approve { row: docs }).unwrap(),
        r#"{"act":"approve","terminal":"0x00000000000000a1","since_ms":5760000,"event_ms":5760000}"#
    );
    assert_eq!(
        act::encode(&Act::Refuse { row: docs }).unwrap(),
        r#"{"act":"refuse","terminal":"0x00000000000000a1","since_ms":5760000,"event_ms":5760000}"#
    );
    let billing = l.row("billing").unwrap();
    assert_eq!(
        act::encode(&Act::Reply { row: billing, text: "第二种 \"B\"\n" }).unwrap(),
        "{\"act\":\"reply\",\"terminal\":\"0x00000000000000a2\",\"since_ms\":5340000,\"text\":\"第二种 \\\"B\\\"\\n\"}"
    );
    assert_eq!(act::encode(&Act::Seen { group: "infra" }).unwrap(), r#"{"act":"seen","group":"infra"}"#);
    assert_eq!(act::encode(&Act::Snooze { group: "infra" }).unwrap(), r#"{"act":"snooze","group":"infra"}"#);
    assert_eq!(
        act::encode(&Act::SnoozeUntil { group: "infra", until_ms: 1_700_009_000_000 }).unwrap(),
        r#"{"act":"snooze","group":"infra","until_ms":1700009000000}"#
    );
    assert_eq!(act::encode(&Act::Unsnooze { group: "infra" }).unwrap(), r#"{"act":"unsnooze","group":"infra"}"#);

    // Every one of them is JSON, and says what it was built from.
    for row in l.rows() {
        for request in [act::encode(&Act::Approve { row }), act::encode(&Act::Reply { row, text: "x" })].into_iter().flatten() {
            let v = crate::json::parse(&request).unwrap();
            assert_eq!(v.get("terminal"), row.terminal.clone().map(crate::json::Value::Str).as_ref());
        }
    }
}

#[test]
fn a_row_with_nothing_to_aim_at_has_no_request() {
    let mut row = list().row("billing").unwrap().clone();
    row.event_ms = None;
    assert_eq!(act::encode(&Act::Approve { row: &row }), None);
    row.terminal = None;
    assert_eq!(act::encode(&Act::Reply { row: &row, text: "x" }), None);
    assert_eq!(act::encode(&Act::Refuse { row: &row }), None);
}

#[test]
fn every_refusal_the_core_names_has_something_to_say() {
    // The names in `src/poltergeist/ControlAct.zig`'s table, and the
    // terminal's own.
    let names = [
        "BadRequest",
        "NoSuchGroup",
        "SnoozeInThePast",
        "UnknownTerminal",
        "PromptGone",
        "NothingToReplyTo",
        "Stale",
        "EmptyText",
        "UserPresent",
        "DraftInLine",
        "ChildExited",
        "KeyFailed",
    ];
    let mut said = std::collections::BTreeSet::new();
    for name in names {
        let r = Refusal::parse(name);
        assert_ne!(r, Refusal::Other, "{name} is not known here");
        assert!(!r.message().is_empty());
        assert!(!r.message().contains("{}"));
        said.insert(r.message());
    }
    // Each its own sentence: two refusals that read the same send the
    // person to the same wrong place.
    assert_eq!(said.len(), names.len());

    // A name from a later core is shown, not swallowed.
    let other = Refusal::parse("SomethingNew");
    assert_eq!(other, Refusal::Other);
    assert_eq!(list::fill(other.message(), "SomethingNew"), "It was not done (SomethingNew).");

    assert!(Refusal::PromptGone.means_look_again());
    assert!(!Refusal::DraftInLine.means_look_again());
    assert!(Refusal::DraftInLine.offers_the_terminal());
    assert!(!Refusal::PromptGone.offers_the_terminal());
}

// -- the tab's content area, the chip's slide, the clock ------------------------

#[test]
fn the_two_sides_fill_the_tab_with_the_tables_margins() {
    let room = layout::Room::new(1000.0, 700.0);
    let edge = space::WINDOW_EDGE;
    assert_eq!(room.panel, layout::Rect { x: edge, y: edge, w: side::WIDTH, h: 700.0 - 2.0 * edge });
    // The gap between the two frames, and the same margin on the far side.
    assert_eq!(room.right.x, edge + side::WIDTH + space::BETWEEN_FRAMES);
    assert_eq!(room.right.x + room.right.w, 1000.0 - edge);
    assert_eq!((room.right.y, room.right.h), (room.panel.y, room.panel.h));
    // A window too narrow for a right side has none, not a negative one.
    assert_eq!(layout::Room::new(200.0, 10.0).right.w, 0.0);
    assert_eq!(layout::Room::new(200.0, 10.0).panel.h, 0.0);
}

#[test]
fn a_point_is_in_the_row_drawn_there_and_in_none_between_rows() {
    let l = list();
    let at = ListLayout::new(&l, 900.0);
    for (name, r) in &at.rows {
        assert_eq!(at.row_at(r.x + 1.0, r.y + 1.0), Some(name.as_str()));
        assert_eq!(at.row_at(r.x + r.w - 1.0, r.y + r.h - 1.0), Some(name.as_str()));
    }
    // The header, the gap under the first waiting row, and outside the panel.
    assert_eq!(at.row_at(at.header.x + 1.0, at.header.y + 1.0), None);
    let first = at.rows[0].1;
    assert_eq!(at.row_at(first.x + 1.0, first.y + first.h + side::ROW_GAP / 2.0), None);
    assert_eq!(at.row_at(-1.0, first.y + 1.0), None);
}

#[test]
fn the_chip_leaves_one_row_and_comes_to_rest_on_the_other() {
    let l = list();
    let at = ListLayout::new(&l, 900.0);
    let (from, to) = (at.rows[0].1, at.rows[2].1);
    let run = crate::slide::Run { from, to, lift_scale: crate::look::selection::LIFT_SCALE_ROW };
    assert_eq!(run.frame(0.0).chip, from);
    // On the way its middle passes the far row's a little: that is the
    // overshoot.
    let middle = |r: layout::Rect| r.y + r.h / 2.0;
    let furthest = (0..200).map(|n| middle(run.frame(n as f64 * 0.005).chip)).fold(f64::MIN, f64::max);
    assert!(furthest > middle(to), "{furthest} never passes {}", middle(to));
    assert!(!run.frame(0.0).last);
    assert!(!run.frame(crate::slide::lands_at()).last);
    // Over means it is on the row itself, not near it.
    let rest = run.frame(crate::slide::duration());
    assert!(rest.last);
    assert_eq!(rest.chip, to);
}

#[test]
fn a_breathing_glyph_goes_down_to_the_tables_least_and_back_once_a_period() {
    use crate::look::status;
    let period = status::WAITING_PULSE_PERIOD;
    assert_eq!(pulse::opacity(0.0), 1.0);
    assert!((pulse::opacity(period / 2.0) - status::WAITING_PULSE_MIN_OPACITY).abs() < 1e-9);
    assert!((pulse::opacity(period) - 1.0).abs() < 1e-9);
    assert!((pulse::opacity(period * 7.25) - pulse::opacity(period * 0.25)).abs() < 1e-9);
    for n in 0..100 {
        let o = pulse::opacity(n as f64 * 0.031);
        assert!((status::WAITING_PULSE_MIN_OPACITY - 1e-9..=1.0 + 1e-9).contains(&o), "{o}");
    }
}

#[test]
fn the_spinner_steps_through_every_line_once_a_turn() {
    use crate::look::status;
    let steps = status::WORKING_SPIN_STEPS as usize;
    let per = status::WORKING_SPIN_PERIOD / status::WORKING_SPIN_STEPS;
    for n in 0..steps {
        assert_eq!(pulse::spin_step((n as f64 + 0.5) * per), n);
    }
    assert_eq!(pulse::spin_step(status::WORKING_SPIN_PERIOD + per * 0.5), 0);
}

#[test]
fn a_rows_supervisor_is_the_one_the_core_named() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = List::from_snapshot(&s);
    assert!(s.groups.iter().any(|g| g.steward.is_some()));
    for g in &s.groups {
        assert_eq!(l.row(&g.name).unwrap().steward, g.steward);
    }
    // A group with none says so with null, and a snapshot without the field
    // at all is not read as "none".
    let without = FIXTURE.replacen("\"steward\": \"0x00000000000000a1\",", "", 1);
    assert_ne!(without, FIXTURE);
    assert!(matches!(snapshot::decode(&without), Err(DecodeError::Field(f)) if f.ends_with(".steward")));
}

// -- the selection's life -----------------------------------------------------------

#[test]
fn a_control_room_that_opens_with_nothing_selected_starts_on_the_cores_group_and_that_is_not_a_look() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = List::from_snapshot(&s);
    let mut sel = list::Selection::opened(None);
    assert_eq!(sel.current(), None);
    sel.snapshot(&l, s.open_on.as_deref());
    assert_eq!(sel.current(), Some("web-app"));
    assert!(!sel.is_a_look());
    // The person selecting that same row makes it one.
    sel.choose(Some("web-app".into()));
    assert!(sel.is_a_look());
}

#[test]
fn only_the_first_snapshot_after_opening_selects_for_the_person() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = List::from_snapshot(&s);
    let mut sel = list::Selection::opened(None);
    sel.snapshot(&l, None);
    assert_eq!(sel.current(), None);
    // A later snapshot that does name a group is too late.
    sel.snapshot(&l, s.open_on.as_deref());
    assert_eq!(sel.current(), None);
    // And clearing the selection later does not bring the core's back.
    let mut sel = list::Selection::opened(None);
    sel.snapshot(&l, s.open_on.as_deref());
    sel.choose(None);
    sel.snapshot(&l, s.open_on.as_deref());
    assert_eq!(sel.current(), None);
}

#[test]
fn what_was_selected_before_stands_and_is_still_the_persons() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = List::from_snapshot(&s);
    let mut sel = list::Selection::opened(Some("billing".into()));
    assert!(sel.is_a_look());
    sel.snapshot(&l, s.open_on.as_deref());
    assert_eq!(sel.current(), Some("billing"));
    assert!(sel.is_a_look());
    sel.snapshot(&l, s.open_on.as_deref());
    assert_eq!(sel.current(), Some("billing"));
}

#[test]
fn a_selection_whose_group_went_away_is_dropped_and_what_replaces_it_is_not_a_look() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = List::from_snapshot(&s);
    // Kept from last time, gone since: the opening snapshot takes the core's.
    let mut sel = list::Selection::opened(Some("gone-overnight".into()));
    sel.snapshot(&l, s.open_on.as_deref());
    assert_eq!(sel.current(), Some("web-app"));
    assert!(!sel.is_a_look());
    // Selected by the person, then the group goes while it is open: nothing.
    let mut sel = list::Selection::opened(None);
    sel.snapshot(&l, None);
    sel.choose(Some("billing".into()));
    let mut fewer = l.clone();
    fewer.waiting.retain(|r| r.id != "billing");
    fewer.quiet.retain(|r| r.id != "billing");
    sel.snapshot(&fewer, s.open_on.as_deref());
    assert_eq!(sel.current(), None);
    assert!(!sel.is_a_look());
}

#[test]
fn a_group_the_core_names_but_does_not_list_is_not_selected() {
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = List::from_snapshot(&s);
    let mut sel = list::Selection::opened(None);
    sel.snapshot(&l, Some("not-in-the-list"));
    assert_eq!(sel.current(), None);
    assert!(!sel.is_a_look());
}

// ---- a new group, and a supervisor for a group that has none (task 1453)

#[test]
fn the_fixture_says_where_every_group_stands_with_a_supervisor_and_which_roles_start_one() {
    use crate::snapshot::{StartFailure, SupervisorState};
    let s = snapshot::decode(FIXTURE).unwrap();
    assert_eq!(s.groups.len(), 8);
    for g in &s.groups {
        let start = g.supervisor.as_ref().unwrap_or_else(|| panic!("{} says nothing of its supervisor", g.name));
        // Every group of the fixture has one, so none can be started.
        assert_eq!((start.state, start.can_start, start.failed), (SupervisorState::Present, false, StartFailure::None), "{}", g.name);
        assert_eq!(start.role.as_deref(), Some("polter-supervisor"));
        assert_eq!(start.cwd, "/Users/me");
    }
    let roles: Vec<(&str, &str)> = s.supervisor_roles.iter().map(|r| (r.key.as_str(), r.name.as_str())).collect();
    assert_eq!(roles, [("polter-supervisor", "Polter Supervisor")]);
    assert!(!s.choose_supervisor_role);
    // And the list carries all three to whoever draws.
    let l = List::from_snapshot(&s);
    assert!(l.rows().filter(|r| r.alone.is_none()).all(|r| r.start.is_some()));
    // A terminal on its own has no supervisor to start: it is one, or has
    // none to be given here.
    assert_eq!(l.rows().filter(|r| r.alone.is_some()).count(), 0);
    let l = List::from_snapshot_with(&s, true);
    assert!(l.rows().filter(|r| r.alone.is_some()).all(|r| r.start.is_none()));
    assert_eq!(l.rows().filter(|r| r.alone.is_some()).count(), 1);
    assert_eq!(l.supervisor_roles, s.supervisor_roles);
    assert_eq!(l.choose_supervisor_role, s.choose_supervisor_role);
}

#[test]
fn what_the_core_says_of_a_supervisor_is_read_as_said_and_an_unknown_word_is_an_error() {
    use crate::snapshot::{StartFailure, SupervisorState};
    let first = |from: &str, to: &str| FIXTURE.replacen(from, to, 1);
    let read = |json: String| snapshot::decode(&json).unwrap().groups[0].supervisor.clone().unwrap();
    let absent = read(first("\"state\": \"present\",\n        \"can_start\": false", "\"state\": \"absent\",\n        \"can_start\": true"));
    assert_eq!((absent.state, absent.can_start), (SupervisorState::Absent, true));
    // `can_start` is read, not worked out from the state: a group with no
    // supervisor that the core says none can be started for, and one whose
    // last try failed that it says can be tried again.
    let odd = read(first("\"state\": \"present\"", "\"state\": \"starting\""));
    assert_eq!((odd.state, odd.can_start), (SupervisorState::Starting, false));
    let held = read(first("\"state\": \"present\"", "\"state\": \"absent\""));
    assert_eq!((held.state, held.can_start), (SupervisorState::Absent, false));
    let again = read(first("\"state\": \"present\",\n        \"can_start\": false", "\"state\": \"failed\",\n        \"can_start\": true"));
    assert_eq!((again.state, again.can_start), (SupervisorState::Failed, true));
    let failed = read(first("\"state\": \"present\"", "\"state\": \"failed\"").replacen("\"failed\": \"none\"", "\"failed\": \"agent_never_connected\"", 1));
    assert_eq!((failed.state, failed.failed), (SupervisorState::Failed, StartFailure::AgentNeverConnected));
    // The two a launcher reports itself are read like the rest: every word
    // the core writes, and what each is read back as.
    for reason in StartFailure::ALL {
        let with = read(first("\"state\": \"present\"", "\"state\": \"failed\"").replacen("\"failed\": \"none\"", &format!("\"failed\": \"{}\"", reason.name()), 1));
        assert_eq!(with.failed, reason, "{}", reason.name());
    }
    let named: Vec<&str> = StartFailure::ALL.iter().map(|r| r.name()).collect();
    assert_eq!(named, ["none", "terminal_never_opened", "agent_never_connected", "terminal_closed", "cli_not_found", "cli_did_not_start"]);
    let no_role = read(first("\"role\": \"polter-supervisor\"", "\"role\": null"));
    assert_eq!(no_role.role, None);
    assert!(matches!(snapshot::decode(&first("\"state\": \"present\"", "\"state\": \"maybe\"")), Err(DecodeError::UnknownValue(_))));
    assert!(matches!(snapshot::decode(&first("\"failed\": \"none\"", "\"failed\": \"gave_up\"")), Err(DecodeError::UnknownValue(_))));
    assert!(snapshot::decode(&first("\"choose_supervisor_role\": false", "\"choose_supervisor_role\": true")).unwrap().choose_supervisor_role);
}

#[test]
fn a_snapshot_from_before_a_supervisor_could_be_started_offers_nothing() {
    // Older cores wrote neither the group's `supervisor` nor the roles.
    let mut old = String::new();
    let mut rest = FIXTURE;
    while let Some(at) = rest.find("      \"supervisor\": {") {
        old.push_str(&rest[..at]);
        // Its own closing brace, at its own depth: it has objects in it.
        let close = "\n      },\n";
        let end = rest[at..].find(close).unwrap() + at + close.len();
        rest = &rest[end..];
    }
    old.push_str(rest);
    let at = old.find("  \"supervisor_roles\"").unwrap();
    let end = old[at..].find("\"choose_supervisor_role\": false,\n").unwrap() + at + "\"choose_supervisor_role\": false,\n".len();
    let old = format!("{}{}", &old[..at], &old[end..]);
    let s = snapshot::decode(&old).unwrap();
    assert_eq!(s.groups.len(), 8);
    assert!(s.groups.iter().all(|g| g.supervisor.is_none()));
    assert!(s.supervisor_roles.is_empty() && !s.choose_supervisor_role);
}

#[test]
fn the_directory_is_the_last_supervisors_only_when_the_core_says_how_it_was_arrived_at() {
    // Every group in the fixture has a directory arrived at another way.
    let s = snapshot::decode(FIXTURE).unwrap();
    assert!(s.groups.iter().all(|g| !g.supervisor.as_ref().unwrap().last.as_ref().unwrap().cwd_is_last));
    // The first one, said to be where its supervisor last worked.
    let said = FIXTURE.replacen("\"cwd_from\": \"home\"", "\"cwd_from\": \"last_supervisor\"", 1);
    assert_ne!(said, FIXTURE);
    let s = snapshot::decode(&said).unwrap();
    let is_last: Vec<bool> = s.groups.iter().map(|g| g.supervisor.as_ref().unwrap().last.as_ref().unwrap().cwd_is_last).collect();
    assert_eq!(is_last.iter().filter(|b| **b).count(), 1);
    assert!(is_last[0]);
    // Any other way of arriving at it is not that.
    for other in ["session_snapshot", "members", "none"] {
        let s = snapshot::decode(&FIXTURE.replacen("\"cwd_from\": \"home\"", &format!("\"cwd_from\": \"{other}\""), 1)).unwrap();
        assert!(s.groups.iter().all(|g| !g.supervisor.as_ref().unwrap().last.as_ref().unwrap().cwd_is_last), "{other}");
    }
}

#[test]
fn who_the_core_says_is_in_a_terminal_is_read_as_one_of_three_and_never_guessed() {
    use crate::snapshot::{Who, WhoIs};
    let s = snapshot::decode(FIXTURE).unwrap();
    let who = |id: &str| s.terminals.iter().find(|t| t.id == id).unwrap().who.clone().unwrap();

    // An agent, with what is known of it; a part not known is an empty
    // string, which is not a part that was not said.
    assert_eq!(
        who("0x00000000000000b1"),
        Who {
            is: WhoIs::Agent,
            role: Some("dev-worker".into()),
            cli: Some("claude-code".into()),
            session: Some("s".into()),
            worker_of: Some("0x00000000000000a1".into()),
        }
    );
    assert_eq!(who("0x00000000000000a2").role.as_deref(), Some(""));
    // Nobody, and not known: two answers, and neither has the three words.
    let nobody = who("0x00000000000000c2");
    assert_eq!((nobody.is, nobody.role, nobody.cli, nobody.session), (WhoIs::None, None, None, None));
    assert_eq!(who("0x00000000000000b5").is, WhoIs::Unknown);

    let named: Vec<&str> = WhoIs::ALL.iter().map(|k| k.name()).collect();
    assert_eq!(named, ["unknown", "none", "agent"]);
    // A word the core does not write is an error, not "unknown".
    let odd = FIXTURE.replacen("\"is\": \"none\",\n        \"role\": null", "\"is\": \"nobody\",\n        \"role\": null", 1);
    assert_ne!(odd, FIXTURE, "the fixture no longer has a terminal with nobody in it");
    assert!(snapshot::decode(&odd).is_err());

    // A core from before it said this: nothing, not a made-up "unknown".
    let block = "      \"who\": {\n        \"is\": \"none\",\n        \"role\": null,\n        \"cli\": null,\n        \"session\": null,\n        \"worker_of\": null\n      },\n";
    assert!(FIXTURE.contains(block), "the fixture no longer writes the block this test cuts");
    let before = snapshot::decode(&FIXTURE.replacen(block, "", 1)).unwrap();
    assert_eq!(before.terminals.iter().find(|t| t.id == "0x00000000000000c2").unwrap().who, None);
}

#[test]
fn what_the_core_says_of_a_groups_last_supervisor_is_read_and_not_worked_out() {
    use crate::snapshot::{ResumeWhy, SupervisorLast};
    let s = snapshot::decode(FIXTURE).unwrap();
    let last = |name: &str| s.groups.iter().find(|g| g.name == name).unwrap().supervisor.clone().unwrap().last.unwrap();

    // Nothing written down: every part is none, and the reason is that.
    assert_eq!(
        last("web-app"),
        SupervisorLast {
            cli: Some("claude-code".into()),
            role: None,
            last_cli: None,
            heard_ms: None,
            can_resume: false,
            why: ResumeWhy::NoRecord,
            cwd_is_last: false,
            // The CLI a start uses has a name; the last supervisor's was
            // never written down, so there is none to name.
            cli_label: Some("Claude Code".into()),
            last_cli_label: None,
        }
    );
    // One whose session a terminal is in now, and one that can be gone on with.
    let billing = last("billing");
    assert_eq!((billing.role.as_deref(), billing.last_cli.as_deref(), billing.heard_ms), (Some("polter-supervisor"), Some("claude-code"), Some(1_699_999_340_000)));
    assert_eq!((billing.can_resume, billing.why), (false, ResumeWhy::SessionInUse));
    let notes = last("notes");
    assert_eq!((notes.can_resume, notes.why), (true, ResumeWhy::None));
    assert_eq!((billing.cli_label.as_deref(), billing.last_cli_label.as_deref()), (Some("Claude Code"), Some("Claude Code")));
    // A core that gives no name -- null, or from before it said -- is read
    // as no name, not as the key.
    let unnamed = snapshot::decode(&FIXTURE.replace("\"cli_label\": \"Claude Code\"", "\"cli_label\": null")).unwrap();
    let b = unnamed.groups.iter().find(|g| g.name == "billing").unwrap().supervisor.clone().unwrap().last.unwrap();
    assert_eq!((b.cli.as_deref(), b.cli_label, b.last_cli.as_deref(), b.last_cli_label), (Some("claude-code"), None, Some("claude-code"), None));
    let before = snapshot::decode(&FIXTURE.replace("        \"cli_label\": \"Claude Code\",\n", "").replace("          \"cli_label\": \"Claude Code\",\n", "").replace("          \"cli_label\": null,\n", "")).unwrap();
    let b = before.groups.iter().find(|g| g.name == "billing").unwrap().supervisor.clone().unwrap().last.unwrap();
    assert_eq!((b.cli_label, b.last_cli_label), (None, None));

    // `can` is read, not made out of `why`: a core that says it cannot for
    // no reason it names is believed.
    let first = |from: &str, to: &str| FIXTURE.replacen(from, to, 1);
    let read = |json: String| snapshot::decode(&json).map(|s| s.groups[0].supervisor.clone().unwrap().last);
    let odd = read(first("\"why\": \"no_record\"", "\"why\": \"none\"")).unwrap().unwrap();
    assert_eq!((odd.can_resume, odd.why), (false, ResumeWhy::None));

    // Every word the core writes, and a word it does not is an error
    // rather than a guess.
    for why in ResumeWhy::ALL {
        let with = read(first("\"why\": \"no_record\"", &format!("\"why\": \"{}\"", why.name()))).unwrap().unwrap();
        assert_eq!(with.why, why, "{}", why.name());
    }
    let named: Vec<&str> = ResumeWhy::ALL.iter().map(|w| w.name()).collect();
    assert_eq!(named, ["none", "no_record", "no_session", "last_try_failed", "cli_differs", "clis_unread", "cli_cannot_resume", "session_in_use"]);
    assert!(read(first("\"why\": \"no_record\"", "\"why\": \"because\"")).is_err());

    // A core from before it said any of this: nothing, not a made-up "no".
    // And half of it is not a snapshot.
    let block = "        \"last\": {\n          \"role\": null,\n          \"cli\": null,\n          \"cli_label\": null,\n          \"heard_ms\": null\n        },\n        \"resume\": {\n          \"can\": false,\n          \"why\": \"no_record\"\n        }\n";
    assert!(FIXTURE.contains(block), "the fixture no longer writes the block this test cuts");
    let before = first(&format!("\"cwd_from\": \"home\",\n{block}"), "\"cwd_from\": \"home\"\n");
    assert_eq!(read(before).unwrap(), None);
    let half = first("        \"resume\": {\n          \"can\": false,\n          \"why\": \"no_record\"\n        }\n", "        \"x\": 1\n");
    assert!(read(half).is_err());
}

#[test]
fn making_a_group_and_starting_a_supervisor_are_requests_the_core_reads() {
    assert_eq!(act::encode(&Act::NewGroup { name: " web app\"x " }).unwrap(), r#"{"act":"new_group","name":" web app\"x "}"#);
    // What the person did not pick is left out, for the core to fill in.
    let start = |role, cwd| act::encode(&Act::StartSupervisor { group: "web-app", role, cwd, session: None }).unwrap();
    assert_eq!(start(None, None), r#"{"act":"start_supervisor","group":"web-app"}"#);
    assert_eq!(start(Some("reviewer"), None), r#"{"act":"start_supervisor","group":"web-app","role":"reviewer"}"#);
    assert_eq!(start(None, Some(r"C:\src")), r#"{"act":"start_supervisor","group":"web-app","cwd":"C:\\src"}"#);
    assert_eq!(start(Some("r"), Some("/x")), r#"{"act":"start_supervisor","group":"web-app","role":"r","cwd":"/x"}"#);
    for request in [start(Some("r"), Some("/x")), act::encode(&Act::NewGroup { name: "a" }).unwrap()] {
        assert!(crate::json::parse(&request).is_ok(), "{request}");
    }
    // Which session is the core's two words, and is left out when there is
    // none to say (`act::session_sent`).
    let with = |session| act::encode(&Act::StartSupervisor { group: "web-app", role: None, cwd: None, session }).unwrap();
    assert_eq!(with(Some(act::Session::Last)), r#"{"act":"start_supervisor","group":"web-app","session":"last"}"#);
    assert_eq!(with(Some(act::Session::New)), r#"{"act":"start_supervisor","group":"web-app","session":"new"}"#);
    assert_eq!(with(None), r#"{"act":"start_supervisor","group":"web-app"}"#);
    // On screen: the last session until the person picks the other. Not on
    // screen: nothing is said, whatever was picked while it was.
    assert_eq!(act::session_sent(true, None), Some(act::Session::Last));
    assert_eq!(act::session_sent(true, Some(act::Session::New)), Some(act::Session::New));
    assert_eq!(act::session_sent(true, Some(act::Session::Last)), Some(act::Session::Last));
    for picked in [None, Some(act::Session::Last), Some(act::Session::New)] {
        assert_eq!(act::session_sent(false, picked), None);
    }
}

#[test]
fn each_way_of_not_making_a_group_or_not_starting_a_supervisor_has_its_own_sentence() {
    let names = [
        "BadName", "GroupExists", "TooManyGroups", "HasSupervisor", "AlreadyStarting", "NoSupervisorRole", "NoSuchPersona",
        "NotASupervisorRole", "NoCli", "NoSuchDirectory", "OpenFailed", "NoExecutable",
    ];
    let mut said: Vec<&str> = names.iter().map(|n| Refusal::parse(n).message()).collect();
    assert!(names.iter().all(|n| Refusal::parse(n) != Refusal::Other), "{names:?}");
    assert!(said.iter().all(|m| !m.contains("{}") && m.ends_with('.')));
    said.sort_unstable();
    said.dedup();
    assert_eq!(said.len(), names.len(), "two of them say the same thing");
    // The three ways a directory is not there are one sentence; so are the two ways no tab opens.
    assert_eq!(Refusal::parse("NotAbsolute"), Refusal::NoSuchDirectory);
    assert_eq!(Refusal::parse("NotADirectory"), Refusal::NoSuchDirectory);
    assert_eq!(Refusal::parse("NoRuntime"), Refusal::OpenFailed);
    assert_eq!(Refusal::parse("BadName").message(), "A group's name is lowercase letters, digits and dashes, 48 at most.");
    // None of them is put right by looking again or by going to a terminal.
    assert!(names.iter().all(|n| !Refusal::parse(n).means_look_again() && !Refusal::parse(n).offers_the_terminal()));
}

#[test]
fn a_group_just_made_is_selected_when_the_core_lists_it_and_not_before() {
    use crate::rules::{made_group_name, made_group_to_select};
    let l = list();
    assert_eq!(made_group_to_select(Some("billing"), &l), Some("billing"));
    assert_eq!(made_group_to_select(Some("not-yet"), &l), None);
    assert_eq!(made_group_to_select(None, &l), None);
    // The core trims what was typed and makes nothing else of it.
    assert_eq!(made_group_name("  billing \n"), "billing");
    assert_eq!(made_group_name("Bill ing"), "Bill ing");
    assert_eq!(made_group_to_select(Some(made_group_name(" billing ")), &l), Some("billing"));
}

#[test]
fn where_a_tab_the_core_asked_for_goes() {
    use crate::rules::{new_tab, Home, NewTab};
    // (lent, has a home)
    assert_eq!(new_tab(Some((true, true)), false, true, true, true), NewTab::Behind(Home::Askers));
    assert_eq!(new_tab(Some((false, true)), false, true, true, true), NewTab::InFront(Home::Askers));
    // Nothing holds it: not opened, whatever else is so.
    for lent in [false, true] {
        for facts in [(false, false, false), (true, true, true)] {
            assert_eq!(new_tab(Some((lent, false)), false, facts.0, facts.1, facts.2), NewTab::Refused);
        }
    }
    // The application itself -- the control room starting a supervisor.
    assert_eq!(new_tab(None, false, true, true, true), NewTab::Behind(Home::ControlRooms));
    assert_eq!(new_tab(None, false, true, true, false), NewTab::Behind(Home::ControlRooms));
    // Alone in its window with a terminal window elsewhere: still its own.
    assert_eq!(new_tab(None, false, true, false, true), NewTab::Behind(Home::ControlRooms));
    assert_eq!(new_tab(None, false, false, true, true), NewTab::InFront(Home::Frontmost));
    assert_eq!(new_tab(None, false, false, false, false), NewTab::OwnWindow);
    // The control room alone on screen: its own window takes the tab.
    assert_eq!(new_tab(None, false, true, false, false), NewTab::Behind(Home::ControlRooms));
    // The person's own -- a key, a menu item -- comes in front there.
    assert_eq!(new_tab(None, true, true, true, true), NewTab::InFront(Home::ControlRooms));
    assert_eq!(new_tab(None, true, true, false, false), NewTab::InFront(Home::ControlRooms));
    assert_eq!(new_tab(None, true, true, false, true), NewTab::InFront(Home::Frontmost));
    assert_eq!(new_tab(None, true, false, false, false), NewTab::OwnWindow);
    // An asker's own answer does not depend on where the control room is.
    for a in [false, true] {
        for b in [false, true] {
            for c in [false, true] {
                assert_eq!(new_tab(Some((true, true)), false, a, b, c), NewTab::Behind(Home::Askers));
                assert_eq!(new_tab(Some((false, true)), false, a, b, c), NewTab::InFront(Home::Askers));
            }
        }
    }
}

#[test]
fn a_title_that_is_the_path_of_the_program_started_is_shown_as_its_name() {
    use crate::rules::shown_title;
    assert_eq!(shown_title(r"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"), "powershell");
    assert_eq!(shown_title(r"C:\Program Files\PowerShell\7\pwsh.EXE"), "pwsh");
    assert_eq!(shown_title(r"D:\tools\cmd.exe"), "cmd");
    // Anything a shell or a program set is kept as it came.
    for kept in ["powershell.exe", "zsh — ~/work", r"C:\Users\me\src", r"vim C:\x\notes.exe.txt", "", "claude", r"\\server\share\x.exe", "git commit -m x.exe"] {
        assert_eq!(shown_title(kept), kept);
    }
}

// ---- a terminal in no group has no row, and is in no count (task 1485)

#[test]
fn a_terminal_in_no_group_has_no_row_and_is_in_no_number_the_person_is_shown() {
    // The user, 2026-10-13: the rows of these terminals read as groups
    // nobody had made. They are listed by the core and drawn by no host.
    let s = snapshot::decode(FIXTURE).unwrap();
    assert_eq!(s.ungrouped.len(), 1);
    let l = List::from_snapshot(&s);
    assert!(l.rows().all(|r| r.alone.is_none()));
    assert_eq!(l.row(LONE), None);
    // The heading, the rows under it and the badge: one number.
    assert_eq!(l.waiting.len() as u64, l.waiting_count);
    assert_eq!(l.waiting_count, s.needs_me);
    assert_eq!(l.quiet.len() as u64, l.quiet_count);
    assert_eq!(s.header_waiting.map(|h| h.of), Some(HeaderOf::Groups));
    // And nothing of it is drawn.
    let lay = ListLayout::new(&l, 900.0);
    assert_eq!(lay.chip(Some(LONE)), None);
    assert_eq!(lay.rows.len() as u64, s.needs_me + l.quiet_count);
}

// ---- what a row of such a terminal says, were one drawn (task 1471; the same
// cases as the macOS host's ControlRoomListTests)

fn snapshot_with(change: impl FnOnce(&mut snapshot::Snapshot)) -> List {
    let mut s = snapshot::decode(FIXTURE).unwrap();
    change(&mut s);
    List::from_snapshot_with(&s, true)
}

#[test]
fn a_terminal_waiting_in_no_group_has_a_row_so_the_list_shows_what_the_badge_counts() {
    // The badge's number is `needs_me`: every terminal waiting, each once.
    // The groups' rows carry all of them but the ones in no group, and
    // those were not drawn: the badge said 6 over five rows.
    let s = snapshot::decode(FIXTURE).unwrap();
    let l = List::from_snapshot_with(&s, true);
    let alone: Vec<&list::Row> = l.waiting.iter().filter(|r| r.alone.is_some()).collect();
    assert_eq!(alone.len(), s.ungrouped.iter().filter(|u| u.needs_me).count());
    assert_eq!(alone.len(), 1);
    // Drawn, it would be one row more than the number says: the core
    // counts only what the hosts draw, and they do not draw this.
    let waiting_rows = l.waiting.len() as u64;
    assert_eq!(waiting_rows, s.needs_me + 1);

    let row = alone[0];
    assert_eq!(
        row.alone,
        Some(list::Alone { terminal: "0x00000000000000c1".to_string(), title: "zsh — ~/work".to_string(), pane: snapshot::Pane::Plain })
    );
    // It is called by its title, and is a copy of what the core says.
    assert_eq!(row.name(), "zsh — ~/work");
    assert_eq!(row.id, LONE);
    assert_eq!((row.shown, row.word.as_str()), (Shown::NeedsYou, "等批准"));
    assert_eq!(row.waiter.is, WaiterIs::Terminal);
    assert_eq!((row.what.form, row.what.lines.clone()), (Form::Command, vec!["git push".to_string()]));
    assert_eq!(row.others, 0);
    assert_eq!((row.terminal.as_deref(), row.since_ms, row.event_ms), (Some("0x00000000000000c1"), 5_940_000, Some(5_940_000)));
    // Nothing to start: it is not a group without a supervisor.
    assert_eq!(row.start, None);
    // Nobody is named beside it: the row is the terminal.
    assert_eq!(list::waiter(&row.waiter), None);
    // A group's row is called by the group's name, as it always was.
    assert_eq!(l.row("web-app").unwrap().name(), "web-app");
    assert_eq!(l.row("web-app").unwrap().alone, None);
}

#[test]
fn a_lone_terminals_row_cannot_be_mistaken_for_a_groups_and_shows_the_terminal_itself() {
    let l = list_with_lone();
    // The right-hand side shows that terminal itself; a group's row still
    // shows its supervisor; the bare id is no row at all.
    assert_eq!(l.row(LONE).and_then(|r| r.steward.as_deref()), Some("0x00000000000000c1"));
    assert_eq!(l.row("web-app").and_then(|r| r.steward.as_deref()), Some("0x00000000000000a1"));
    assert!(l.row("0x00000000000000c1").is_none());
    // And with none listed there are none, not an error -- whether the
    // list is empty or the snapshot is from before there was one.
    let none = snapshot_with(|s| s.ungrouped.clear());
    assert!(none.rows().all(|r| r.alone.is_none()));
    assert!(none.row(LONE).is_none());
    assert_eq!(none.waiting.len(), 5);
    let at = FIXTURE.find("  \"ungrouped\": [").unwrap();
    let end = FIXTURE[at..].find("\n  ],\n").unwrap() + at + "\n  ],\n".len();
    let old = format!("{}{}", &FIXTURE[..at], &FIXTURE[end..]);
    let read = snapshot::decode(&old).unwrap();
    assert!(read.ungrouped.is_empty());
    assert_eq!(List::from_snapshot(&read).waiting.len(), 5);
}

#[test]
fn a_lone_terminal_goes_in_the_section_its_own_word_says_and_breathes_when_it_is_first() {
    // Needing nothing, it is with the quiet rows, after the groups.
    let quiet = snapshot_with(|s| s.ungrouped[0].needs_me = false);
    assert_eq!(quiet.quiet.last().map(|r| r.id.as_str()), Some(LONE));
    assert!(quiet.waiting.iter().all(|r| r.alone.is_none()));

    // The one glyph that breathes is the first the core lists. When that is
    // this terminal, in no group, it is this row and no group's.
    let pulse = |terminal: &str| snapshot::Pulse { terminal: terminal.to_string(), window: None, tab: None, group: None };
    assert_eq!(pulse::pulsing_row_id(&[pulse("0x00000000000000c1")], None, None).as_deref(), Some(LONE));
    assert_eq!(pulse::pulsing_row(&[pulse("0x00000000000000c1")], None, None), None);
    // Another terminal in no group breathing is not this row.
    let other = pulse::pulsing_row_id(&[pulse("0x00000000000000ff")], None, None);
    assert!(list().row(other.as_deref().unwrap()).is_none());
    // A group's is still the group, by its name.
    let s = snapshot::decode(FIXTURE).unwrap();
    assert_eq!(pulse::pulsing_row_id(&s.pulses, None, None).as_deref(), pulse::pulsing_row(&s.pulses, None, None));
    assert!(pulse::pulsing_row_id(&s.pulses, None, None).is_some());
    assert_eq!(pulse::pulsing_row_id(&[], None, None), None);
}

#[test]
fn a_lone_terminals_row_says_which_frame_its_own_pane_wears() {
    assert_eq!(list_with_lone().row(LONE).unwrap().alone.as_ref().unwrap().pane, snapshot::Pane::Plain);
    // The core lists a terminal in no group as a worker somebody minds, or
    // as a supervisor that has made no group: the row follows.
    for kind in [snapshot::Pane::Worker, snapshot::Pane::Supervisor] {
        let l = snapshot_with(|s| s.terminals.iter_mut().find(|t| t.id == "0x00000000000000c1").unwrap().pane = Some(kind));
        assert_eq!(l.row(LONE).unwrap().alone.as_ref().unwrap().pane, kind);
    }
    // One the core does not list among its terminals is an ordinary one.
    let unlisted = snapshot_with(|s| s.terminals.clear());
    assert_eq!(unlisted.row(LONE).unwrap().alone.as_ref().unwrap().pane, snapshot::Pane::Plain);
}

#[test]
fn looking_at_a_lone_terminals_row_for_a_moment_marks_it_like_any_other() {
    // The same marker, the same wait, the same check of being in front:
    // only what is sent names the terminal, since there is no group to.
    let l = list_with_lone();
    let mut row = l.row(LONE).unwrap().clone();
    row.unseen = true;
    let mut marker = SeenMarker::default();
    let dwell = marker.selection_changed(Some(&row)).expect("a lone terminal's unseen row is waited for");
    assert_eq!(dwell.row, LONE);
    assert_eq!(marker.due(&dwell, false), None);
    assert_eq!(marker.due(&dwell, true), Some(Act::SeenTerminal { terminal: "0x00000000000000c1" }));
    // The request names the terminal and no group.
    assert_eq!(act::encode(&marker.due(&dwell, true).unwrap()).unwrap(), r#"{"act":"seen","terminal":"0x00000000000000c1"}"#);
    // It stops while the person is on it: seen, then not, begins a wait.
    let mut seen = row.clone();
    seen.unseen = false;
    assert_eq!(marker.list_changed(Some(&seen)), None);
    let again = marker.list_changed(Some(&row)).expect("it stopped while selected");
    assert_eq!(marker.due(&again, true), Some(Act::SeenTerminal { terminal: "0x00000000000000c1" }));
    // Already unseen, another list starts nothing over.
    assert_eq!(marker.list_changed(Some(&row)), None);
    // The selection moves on: the wait is no longer about anything.
    marker.selection_changed(l.row("notes"));
    assert_eq!(marker.due(&again, true), None);
    // A group's row is still seen by the group's name.
    row.alone = None;
    row.id = "web-app".to_string();
    let dwell = marker.selection_changed(Some(&row)).expect("a group's unseen row is waited for");
    assert_eq!(act::encode(&marker.due(&dwell, true).unwrap()).unwrap(), r#"{"act":"seen","group":"web-app"}"#);
}

#[test]
fn a_row_seen_is_what_the_list_says_it_is_and_not_what_its_id_looks_like() {
    // A group may not be named "terminal:…", but nothing here leans on
    // that: a row with no `alone` is a group's whatever it is called.
    let l = list();
    let mut row = l.row("infra").unwrap().clone();
    row.unseen = true;
    row.id = "terminal:0x1".to_string();
    let mut marker = SeenMarker::default();
    let dwell = marker.selection_changed(Some(&row)).unwrap();
    assert_eq!(marker.due(&dwell, true), Some(Act::Seen { group: "terminal:0x1" }));
}

// -- the two headings (the macOS host's `ControlRoomHeaderTests`) -------------

fn header(count: u64, of: HeaderOf, number: HeaderNumber) -> Header {
    Header { count, of, number }
}

fn said((words, n): (&'static str, String)) -> String {
    list::fill(words, &n)
}

#[test]
fn the_heading_is_the_cores_count_and_not_the_groups_when_lone_terminals_are_listed() {
    // One group waits and two terminals on their own do: the heading says
    // three, as the taskbar does, and does not call them groups.
    let json = with_headers(Some(r#"{"count":3,"of":"rows","number":"other"}"#), Some(r#"{"count":1,"of":"rows","number":"one"}"#));
    let l = List::from_snapshot(&snapshot::decode(&json).unwrap());
    assert_eq!(l.waiting_count, 3);
    assert_eq!(l.quiet_count, 1);
    assert_eq!(l.waiting_header, Some(header(3, HeaderOf::Rows, HeaderNumber::Other)));
    let first = said(l.waiting_heading());
    assert_eq!(first, said(list::waiting_heading(&header(3, HeaderOf::Rows, HeaderNumber::Other))));
    assert_eq!(first, "3 waiting for you");
    assert!(!first.to_lowercase().contains("group"));
    assert_eq!(said(l.quiet_heading()), "1 needs nothing from you");
}

#[test]
fn every_form_of_the_first_heading_is_its_own_sentence() {
    let none = said(list::waiting_heading(&header(0, HeaderOf::Groups, HeaderNumber::None)));
    let one_group = said(list::waiting_heading(&header(1, HeaderOf::Groups, HeaderNumber::One)));
    let groups = said(list::waiting_heading(&header(4, HeaderOf::Groups, HeaderNumber::Other)));
    let rows = said(list::waiting_heading(&header(4, HeaderOf::Rows, HeaderNumber::Other)));
    let all = [&none, &one_group, &groups, &rows];
    for (i, a) in all.iter().enumerate() {
        for b in &all[i + 1..] {
            assert_ne!(a, b);
        }
    }
    // One group is "group", several are "groups": the core said which, and
    // it is not worked out from the count here.
    assert_eq!(one_group, "1 group waiting for you");
    assert_eq!(groups, "4 groups waiting for you");
    assert_eq!(rows, "4 waiting for you");
    assert_eq!(none, "No group is waiting for you");
    assert!(!none.contains('0'));
    // Nobody waiting is said the same way whatever the rows would be called.
    assert_eq!(said(list::waiting_heading(&header(0, HeaderOf::Rows, HeaderNumber::None))), none);
    // One row that is not a group is still not called one.
    assert_eq!(said(list::waiting_heading(&header(1, HeaderOf::Rows, HeaderNumber::One))), "1 waiting for you");
    // The number handed in is the number written, whatever it is: the form
    // is `number`'s to say.
    let odd = said(list::waiting_heading(&header(7, HeaderOf::Groups, HeaderNumber::One)));
    assert_eq!(odd, "7 group waiting for you");
}

#[test]
fn the_second_heading_follows_the_same_rule() {
    let one_group = said(list::quiet_heading(&header(1, HeaderOf::Groups, HeaderNumber::One)));
    let groups = said(list::quiet_heading(&header(3, HeaderOf::Groups, HeaderNumber::Other)));
    let one_row = said(list::quiet_heading(&header(1, HeaderOf::Rows, HeaderNumber::One)));
    let rows = said(list::quiet_heading(&header(3, HeaderOf::Rows, HeaderNumber::Other)));
    assert_eq!(one_group, "1 group needs nothing from you");
    assert_eq!(groups, "3 groups need nothing from you");
    assert_eq!(one_row, "1 needs nothing from you");
    assert_eq!(rows, "3 need nothing from you");
    // None is written with its number, as several are.
    assert_eq!(said(list::quiet_heading(&header(0, HeaderOf::Groups, HeaderNumber::None))), "0 groups need nothing from you");
    assert_eq!(said(list::quiet_heading(&header(0, HeaderOf::Rows, HeaderNumber::None))), "0 need nothing from you");
}

#[test]
fn a_snapshot_without_the_headings_is_written_from_the_groups_as_it_always_was() {
    let old = with_headers(None, None)
        .replacen("\"groups_needing_me\": 5", "\"groups_needing_me\": 5", 1)
        .replacen("\"groups_other\": 3", "\"groups_other\": 8", 1);
    let s = snapshot::decode(&old).unwrap();
    assert_eq!((s.header_waiting, s.header_quiet), (None, None));
    let l = List::from_snapshot(&s);
    assert_eq!(l.waiting_header, None);
    assert_eq!((l.waiting_count, l.quiet_count), (5, 8));
    assert_eq!(said(l.waiting_heading()), "5 groups waiting for you");
    assert_eq!(said(l.quiet_heading()), "8 groups need nothing from you");
    // And none waiting, from such a core, is the sentence with no number.
    let none = with_headers(None, None).replacen("\"groups_needing_me\": 5", "\"groups_needing_me\": 0", 1);
    let l = List::from_snapshot(&snapshot::decode(&none).unwrap());
    assert_eq!(said(l.waiting_heading()), "No group is waiting for you");
}

#[test]
fn the_cores_fixture_says_five_groups_waiting_and_three_that_need_nothing() {
    let l = list();
    assert_eq!(l.waiting_header, Some(header(5, HeaderOf::Groups, HeaderNumber::Other)));
    assert_eq!(l.quiet_header, Some(header(3, HeaderOf::Groups, HeaderNumber::Other)));
    // The heading and the rows under it are the same number.
    assert_eq!(l.waiting.len(), 5);
    assert_eq!(l.quiet.len(), 3);
    assert_eq!(said(l.waiting_heading()), "5 groups waiting for you");
    assert_eq!(said(l.quiet_heading()), "3 groups need nothing from you");
}

#[test]
fn a_heading_in_a_word_this_build_does_not_know_is_not_read() {
    let odd = with_headers(Some(r#"{"count":2,"of":"tabs","number":"other"}"#), None);
    assert_eq!(snapshot::decode(&odd), Err(DecodeError::UnknownValue("header_waiting.of=tabs".into())));
    let odd = with_headers(None, Some(r#"{"count":2,"of":"rows","number":"two"}"#));
    assert_eq!(snapshot::decode(&odd), Err(DecodeError::UnknownValue("header_quiet.number=two".into())));
    let cut = with_headers(Some(r#"{"of":"rows","number":"other"}"#), None);
    assert_eq!(snapshot::decode(&cut), Err(DecodeError::Field("header_waiting.count".into())));
}

// -- the title over the terminal on the right ---------------------------------

#[test]
fn the_title_of_a_groups_frame_is_its_supervisors_own_terminal() {
    use crate::list::SupervisorTitle;
    let l = list();
    // The supervisor's own glyph and word, whoever the row is about.
    assert_eq!(
        l.row("mobile").unwrap().title,
        Some(SupervisorTitle { name: "mobile".into(), shown: Shown::None, word: String::new() })
    );
    assert_eq!(l.row("mobile").unwrap().shown, Shown::NeedsYou);
    assert_eq!(
        l.row("billing").unwrap().title,
        Some(SupervisorTitle { name: "billing".into(), shown: Shown::NeedsYou, word: "等回答".into() })
    );
    // Two groups under one supervisor both name that terminal.
    assert_eq!(l.row("web-app-docs").unwrap().title.as_ref().unwrap().name, "web-app");
    // A terminal on its own is its own title.
    let with_lone = list_with_lone();
    let lone = with_lone.row(LONE).unwrap();
    assert_eq!(lone.title.as_ref().unwrap().name, lone.alone.as_ref().unwrap().title);
    assert_eq!(lone.title.as_ref().unwrap().shown, lone.shown);
    // A core that lists no terminals gives a group's frame no title.
    let none = List::from_snapshot_with(
        &{
            let mut s = snapshot::decode(FIXTURE).unwrap();
            s.terminals.clear();
            s
        },
        true,
    );
    assert_eq!(none.row("billing").unwrap().title, None);
    assert!(none.row(LONE).unwrap().title.is_some());
}
