//! Against the core's own fixture: the snapshot `ControlRoom.zig` builds and
//! a Zig test holds to the code. The same file the macOS side decodes.

use crate::act::{self, Act, Refusal, SeenMarker};
use crate::layout::{self, ListLayout};
use crate::list::{self, Detail, List};
use crate::look::{line, side, space, window_tab};
use crate::pulse::{self, Scope, TabStatus};
use crate::snapshot::{self, DecodeError, Shown};

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
    assert_eq!(s.needs_me, 4);
    assert_eq!(s.groups_needing_me, 4);
    assert_eq!(s.groups_other, 3);
    assert_eq!(s.groups.len(), 7);
    assert_eq!(s.pulses.len(), 4);
    assert_eq!(s.band.start_label, "06:00");
    assert_eq!(s.band.total_min, 19);
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
    assert_eq!(waiting, ["web-app", "web-app-docs", "billing", "docs-site"]);
    assert_eq!(quiet, ["infra", "design-system", "notes"]);

    let shown: Vec<Shown> = l.rows().map(|r| r.shown).collect();
    assert_eq!(
        shown,
        [
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
    assert_eq!(words, ["等批准", "等批准", "等回答", "出错", "做完了，没看", "在干活", ""]);
}

#[test]
fn the_counts_shown_are_the_ones_handed_in() {
    // A snapshot that says 9 and 0 is drawn as 9 and 0, whatever it holds.
    let odd = FIXTURE
        .replacen("\"groups_needing_me\": 4", "\"groups_needing_me\": 9", 1)
        .replacen("\"groups_other\": 3", "\"groups_other\": 0", 1);
    let l = List::from_snapshot(&snapshot::decode(&odd).unwrap());
    assert_eq!(l.waiting_count, 9);
    assert_eq!(l.quiet_count, 0);
    assert_eq!(l.waiting.len(), 4);
    assert_eq!(l.quiet.len(), 3);
}

#[test]
fn what_a_row_says() {
    let l = list();
    // One supervisor, two groups: the reason is on one row, the other points at it.
    let web = l.row("web-app").unwrap();
    assert_eq!(web.detail, Detail::SameAs("web-app-docs".into()));
    assert!(!web.detail_is_code);
    assert_eq!(list::tooltip(web), None);
    assert_eq!(web.waited_min, Some(4));
    assert_eq!(list::others(web.others), Some((list::msg::OTHERS, "1".to_string())));

    let docs = l.row("web-app-docs").unwrap();
    assert_eq!(docs.detail, Detail::Reason("Bash(rm -rf dist/ && npm run build)".into()));
    assert!(docs.detail_is_code);
    assert_eq!(list::tooltip(docs), Some("Bash(rm -rf dist/ && npm run build)"));
    assert_eq!(list::others(docs.others), None);

    // ⚠️ A question an agent asked comes from a hook's note as well, so by
    // this rule it is set as code too. That is the macOS host's rule, kept
    // the same here so the two draw one thing; telling a command from a
    // question is the core's to say, and it does not say it yet.
    assert!(l.row("billing").unwrap().detail_is_code);
    assert!(!l.row("docs-site").unwrap().detail_is_code);
    assert_eq!(l.row("infra").unwrap().waited_min, None);
    assert_eq!(list::fill(list::msg::SAME_SUPERVISOR, "web-app-docs"), "Same supervisor: see web-app-docs");
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
}

// -- where things are ---------------------------------------------------------

#[test]
fn the_panel_is_laid_out_from_the_look_and_nothing_else() {
    let l = list();
    let lay = ListLayout::new(&l, 800.0);
    let pad = space::SIDE_PANEL_PADDING;
    let inner = side::WIDTH - 2.0 * pad;

    assert_eq!(lay.header, layout::Rect { x: pad, y: pad, w: inner, h: side::HEADER_HEIGHT });
    // Four waiting rows, each a row and a gap below the header.
    let first = lay.chip(Some("web-app")).unwrap();
    assert_eq!(first.y, pad + side::HEADER_HEIGHT);
    assert_eq!(first.h, side::ROW_HEIGHT);
    let fourth = lay.chip(Some("docs-site")).unwrap();
    assert_eq!(fourth.y, first.y + 3.0 * (side::ROW_HEIGHT + side::ROW_GAP));

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

    // The band hangs from the bottom, one lane per group in it.
    assert_eq!(lay.lanes.len(), 4);
    assert_eq!(lay.axis.y, 800.0 - pad - side::TIME_BAND_PADDING_BOTTOM - side::TIME_AXIS_HEIGHT);
    assert_eq!(lay.lanes[3].y + side::TIME_LANE_LABELLED_HEIGHT, lay.axis.y);
    assert_eq!(lay.band_header.y + side::HEADER_HEIGHT, lay.lanes[0].y);
}

#[test]
fn a_lanes_pieces_are_cut_to_the_band_and_run_to_now() {
    let l = list();
    let band = &l.band;
    let total = (band.now_ms - band.start_ms) as f64;
    let width = layout::track_width(260.0);
    assert_eq!(width, 260.0 - side::TIME_LANE_LABEL_WIDTH - side::ROW_ITEM_GAP);
    assert_eq!(layout::track_width(10.0), 0.0);

    // docs-site: once this morning, over; and again, still going.
    let docs = band.lanes.iter().find(|lane| lane.name == "docs-site").unwrap();
    let pieces = layout::segments(docs, band, width);
    assert_eq!(pieces.len(), 2);
    assert!(!pieces[0].ongoing);
    assert!(pieces[1].ongoing);
    let eight_minutes = 8.0 * 60_000.0 / total * width;
    assert!((pieces[0].w - eight_minutes).abs() < 1e-9);
    // The one still going ends at the right edge, which is now.
    assert!((pieces[1].x + pieces[1].w - width).abs() < 1e-9);

    // A span that claims to end after now, or before the band, is cut or dropped.
    let mut odd = docs.clone();
    odd.spans[0].from_ms = 0;
    odd.spans[0].to_ms = band.start_ms - 1;
    odd.spans[1].ongoing = false;
    odd.spans[1].to_ms = band.now_ms + 999_999;
    let cut = layout::segments(&odd, band, width);
    assert_eq!(cut.len(), 1);
    assert!((cut[0].x + cut[0].w - width).abs() < 1e-9);
    assert!(layout::segments(docs, band, 0.0).is_empty());
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

    assert_eq!(s.tabs.len(), 7);
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
