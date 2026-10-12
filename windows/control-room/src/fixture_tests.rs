//! Against the core's own fixture: the snapshot `ControlRoom.zig` builds and
//! a Zig test holds to the code. The same file the macOS side decodes.

use crate::act::{self, Act, Refusal, SeenMarker};
use crate::layout::{self, ListLayout};
use crate::list::{self, List};
use crate::look::{line, side, space, window_tab};
use crate::pulse::{self, Scope, TabStatus};
use crate::snapshot::{self, DecodeError, Form, Shown, WaiterIs};

const FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../src/poltergeist/testdata/control_snapshot.json"
));

fn list() -> List {
    List::from_snapshot(&snapshot::decode(FIXTURE).expect("the fixture decodes"))
}

// -- reading it ---------------------------------------------------------------

#[test]
fn the_fixture_is_read_and_the_counts_are_the_ones_written_in_it() {
    let s = snapshot::decode(FIXTURE).unwrap();
    assert_eq!(s.rev, 1);
    assert_eq!(s.now_ms, 6_000_000);
    assert_eq!(s.needs_me, 5);
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
    let odd = FIXTURE
        .replacen("\"groups_needing_me\": 5", "\"groups_needing_me\": 9", 1)
        .replacen("\"groups_other\": 3", "\"groups_other\": 0", 1);
    let l = List::from_snapshot(&snapshot::decode(&odd).unwrap());
    assert_eq!(l.waiting_count, 9);
    assert_eq!(l.quiet_count, 0);
    assert_eq!(l.waiting.len(), 5);
    assert_eq!(l.quiet.len(), 3);
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
    assert_eq!(list::move_selection(&l, Some("docs-site"), 1), Some("infra"));
    assert_eq!(list::move_selection(&l, Some("infra"), -1), Some("docs-site"));
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
    // Five waiting rows, each a row and a gap below the header.
    let first = lay.chip(Some("web-app")).unwrap();
    assert_eq!(first.y, pad + side::HEADER_HEIGHT);
    assert_eq!(first.h, side::ROW_HEIGHT);
    let fourth = lay.chip(Some("docs-site")).unwrap();
    assert_eq!(fourth.y, first.y + 4.0 * (side::ROW_HEIGHT + side::ROW_GAP));

    let below = fourth.y + side::ROW_HEIGHT + side::ROW_GAP + side::SEPARATOR_SPACE_ABOVE;
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
    assert_eq!(dwell.group, "infra");
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
    assert_eq!(layout::chip_between(from, to, 0.0), from);
    let rest = layout::chip_between(from, to, 5.0);
    assert!((rest.y - to.y).abs() < 0.01 && (rest.h - to.h).abs() < 0.01, "{rest:?}");
    // On the way it passes the far row a little: that is the overshoot.
    let furthest = (0..200).map(|n| layout::chip_between(from, to, n as f64 * 0.005).y).fold(f64::MIN, f64::max);
    assert!(furthest > to.y, "{furthest} never passes {}", to.y);
    assert!(!layout::chip_settled(0.0));
    assert!(!layout::chip_settled(crate::look::selection::SPRING_PERIOD));
    assert!(layout::chip_settled(2.0 * crate::look::selection::SPRING_PERIOD));
    // Settled means it is where it is going, to within a hundredth of the way.
    let settled = layout::chip_between(from, to, 2.0 * crate::look::selection::SPRING_PERIOD);
    assert!((settled.y - to.y).abs() <= 0.01 * (to.y - from.y).abs(), "{settled:?}");
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
