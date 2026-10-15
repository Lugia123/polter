use super::*;

fn leaf(cwd: &str) -> SavedNode {
    SavedNode::Leaf(SavedLeaf::plain(cwd, Agent::None))
}

fn one_tab(name: &str, root: SavedNode) -> Snapshot {
    Snapshot {
        name: name.to_string(),
        saved_at: 1,
        group: None,
        windows: vec![Window { frame: None, front: 0, tabs: vec![Tab { root }] }],
        next_scrollback: None,
    }
}

// ---------------------------------------------------------------------------
// The shared files
// ---------------------------------------------------------------------------

/// `test/project-format/`, from this file's own place in the tree.
fn shared_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/project-format")
}

/// **The files `src/Project.zig` makes, read here and written back.**
///
/// `index.txt` says what each is: `same` (read and written, it is the same
/// bytes), `from` (`<stem>.in.json` read and written is the bytes of
/// `<stem>.json`), `refused` (`<stem>.in.json` is from a later format and
/// must not be read), `stacked` (`<stem>.json` is format 3, which a build
/// with stacks reads and writes back the same, and this one refuses as too
/// new). Nothing in this crate makes any of them, so a writer
/// here that drops a field, orders two keys the other way or prints a number
/// its own way is a red line that shows both byte strings -- not a file that
/// went out and came back the same.
///
/// A round trip alone would not say that: this build reading and writing its
/// own mistake back is green.
#[test]
fn every_shared_file_is_read_and_written_back_as_the_same_bytes() {
    let dir = shared_dir();
    let index = std::fs::read_to_string(dir.join("index.txt")).expect("test/project-format/index.txt");
    let read = |name: String| std::fs::read(dir.join(&name)).unwrap_or_else(|e| panic!("{name}: {e}"));

    let (mut rows, mut named) = (0, 0);
    for line in index.lines().filter(|l| !l.is_empty()) {
        let (kind, stem) = line.split_once('\t').unwrap_or_else(|| panic!("index.txt: {line:?} is not `kind<TAB>stem`"));
        rows += 1;
        match kind {
            "same" => {
                named += 1;
                let want = read(format!("{stem}.json"));
                let got = emit(&parse_snapshot(&want).unwrap_or_else(|e| panic!("{stem}.json: {e:?}"))).unwrap();
                assert_eq!(got, String::from_utf8(want).unwrap(), "{stem}.json did not come back as it went in");
            }
            "from" => {
                named += 2;
                let want = read(format!("{stem}.json"));
                let input = read(format!("{stem}.in.json"));
                let got = emit(&parse_snapshot(&input).unwrap_or_else(|e| panic!("{stem}.in.json: {e:?}"))).unwrap();
                assert_eq!(got, String::from_utf8(want.clone()).unwrap(), "{stem}.in.json was not written as {stem}.json");
                // What it was written as reads, and stays as it is.
                let again = emit(&parse_snapshot(&want).unwrap_or_else(|e| panic!("{stem}.json: {e:?}"))).unwrap();
                assert_eq!(again, String::from_utf8(want).unwrap(), "{stem}.json did not come back as it went in");
            }
            // A pane holding a stack: format 3, which this build does not
            // read yet (`FORMAT_VERSION`), and refuses whole -- the Windows
            // host has no stacks to put the terminals behind into, and
            // reading only the one each pane shows would lose the rest and
            // save that over the file.
            "stacked" => {
                named += 1;
                let input = read(format!("{stem}.json"));
                assert!(
                    matches!(parse_snapshot(&input), Err(ReadError::TooNew { found: 3 })),
                    "{stem}.json must be refused as too new (format 3), and read as {:?}",
                    parse_snapshot(&input)
                );
            }
            "refused" => {
                named += 1;
                let input = read(format!("{stem}.in.json"));
                assert!(
                    matches!(parse_snapshot(&input), Err(ReadError::TooNew { .. })),
                    "{stem}.in.json must be refused as too new, and read as {:?}",
                    parse_snapshot(&input)
                );
            }
            other => panic!("index.txt: unknown kind {other:?}"),
        }
    }

    // A reader that found nothing passed every row it found.
    assert!(rows >= 9, "index.txt has {rows} rows; there were 9 when this was written");
    // And no file here that the index does not name.
    let on_disk = std::fs::read_dir(&dir).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".json")).count();
    assert_eq!(on_disk, named, "test/project-format has a .json file index.txt does not name, or names one that is not there");
}

/// The rules for a string and a number, said here as well as in the shared
/// files so that a failure names the rule.
#[test]
fn a_string_and_a_number_are_written_one_way() {
    let mut s = String::new();
    string(&mut s, "a/b \"q\" \\ \t\n\u{1}\u{1f}\u{7f} 写 🧪 \u{2028}");
    assert_eq!(s, "\"a/b \\\"q\\\" \\\\ \\u0009\\u000a\\u0001\\u001f\u{7f} 写 🧪 \u{2028}\"");

    for (value, want) in [
        (0.62, "0.62"),
        (1.0, "1"),
        (0.0, "0"),
        (0.1 + 0.2, "0.30000000000000004"),
        (1e-7, "0.0000001"),
        (1e21, "1000000000000000000000"),
        (-1920.0, "-1920"),
        (123456789.125, "123456789.125"),
    ] {
        let mut s = String::new();
        number(&mut s, value).unwrap();
        assert_eq!(s, want);
    }
    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(number(&mut String::new(), bad), Err(NotFinite));
        let root = SavedNode::Split { axis: Axis::Horizontal, ratio: bad, left: Box::new(leaf("/a")), right: Box::new(leaf("/b")) };
        assert_eq!(emit(&one_tab("n", root)), Err(NotFinite));
    }
}

// ---------------------------------------------------------------------------
// The two formats
// ---------------------------------------------------------------------------

#[test]
fn a_format_1_file_reads_as_one_window_with_one_tab_and_nobody_knows_who_was_in_its_panes() {
    let bytes = br#"{"name":"old","saved_at":7,"next_scrollback":2,"group":"not a format 1 key",
        "root":{"kind":"leaf","cwd":"/a","scrollback":"1.snap","agent":{"kind":"agent","supervisor":true}}}"#;
    let snap = parse_snapshot(bytes).unwrap();
    assert_eq!(
        snap,
        Snapshot {
            name: "old".to_string(),
            saved_at: 7,
            group: None,
            windows: vec![Window {
                frame: None,
                front: 0,
                tabs: vec![Tab {
                    root: SavedNode::Leaf(SavedLeaf {
                        cwd: "/a".to_string(),
                        title: String::new(),
                        history: String::new(),
                        scrollback: "1.snap".to_string(),
                        // Not `None`, and not the agent the stray key describes.
                        agent: Agent::Unknown,
                    })
                }],
            }],
            next_scrollback: Some(2),
        }
    );
    assert_eq!(format_of(bytes), Ok(1));

    // No `root` is a project with nothing in it, not a corrupt one.
    let blank = parse_snapshot(br#"{"name":"blank","saved_at":1}"#).unwrap();
    assert!(blank.windows.is_empty());
    assert!(blank.tabs().next().is_none());
}

#[test]
fn a_file_from_a_later_format_is_refused_as_too_new_and_is_never_read_as_format_1() {
    // It has everything a format 1 file has. Read as one, it is a project of
    // one pane, and the next save writes that over whatever it was.
    let later = br#"{"format":3,"name":"later","saved_at":1,"root":{"kind":"leaf","cwd":"/a"}}"#;
    assert_eq!(parse_snapshot(later), Err(ReadError::TooNew { found: 3 }));
    assert_eq!(format_of(later), Err(ReadError::TooNew { found: 3 }));
    assert!(ReadError::TooNew { found: 3 }.to_string().contains("format 3"));

    // A `format` that is not a version at all is a damaged file.
    for bad in ["0", "-1", "\"2\"", "2.0", "null", "true", "[2]", "18446744073709551615"] {
        let bytes = format!(r#"{{"format":{bad},"name":"n","saved_at":1,"windows":[]}}"#);
        assert_eq!(parse_snapshot(bytes.as_bytes()), Err(ReadError::Corrupt), "format {bad}");
    }

    // And `format: 1` said out loud is format 1.
    let one = parse_snapshot(br#"{"format":1,"name":"n","saved_at":1,"root":{"kind":"leaf"}}"#).unwrap();
    assert_eq!(one.windows.len(), 1);
}

#[test]
fn a_format_2_file_that_lacks_what_format_2_always_writes_is_corrupt() {
    let leaf = r#"{"kind":"leaf","agent":{"kind":"none"}}"#;
    let cases = [
        ("no tabs key", r#"[{"front":0}]"#.to_string()),
        ("a window with no tab", r#"[{"front":0,"tabs":[]}]"#.to_string()),
        ("no front", format!(r#"[{{"tabs":[{{"root":{leaf}}}]}}]"#)),
        ("front past the last tab", format!(r#"[{{"front":1,"tabs":[{{"root":{leaf}}}]}}]"#)),
        ("front below zero", format!(r#"[{{"front":-1,"tabs":[{{"root":{leaf}}}]}}]"#)),
        ("a tab with no root", r#"[{"front":0,"tabs":[{}]}]"#.to_string()),
        ("a leaf that does not say who", r#"[{"front":0,"tabs":[{"root":{"kind":"leaf"}}]}]"#.to_string()),
        ("an agent of no kind this build names", r#"[{"front":0,"tabs":[{"root":{"kind":"leaf","agent":{"kind":"robot"}}}]}]"#.to_string()),
        ("an agent that does not say whether it supervises", r#"[{"front":0,"tabs":[{"root":{"kind":"leaf","agent":{"kind":"agent"}}}]}]"#.to_string()),
        ("an agent whose role is not text", r#"[{"front":0,"tabs":[{"root":{"kind":"leaf","agent":{"kind":"agent","role":1,"supervisor":false}}}]}]"#.to_string()),
        ("a frame from no corner", format!(r#"[{{"frame":{{"x":0,"y":0,"width":1,"height":1}},"front":0,"tabs":[{{"root":{leaf}}}]}}]"#)),
        ("a frame missing a side", format!(r#"[{{"frame":{{"origin":"top_left","x":0,"y":0,"width":1}},"front":0,"tabs":[{{"root":{leaf}}}]}}]"#)),
        ("windows that are not a list", "{}".to_string()),
    ];
    for (what, windows) in cases {
        let bytes = format!(r#"{{"format":2,"name":"n","saved_at":1,"windows":{windows}}}"#);
        assert_eq!(parse_snapshot(bytes.as_bytes()), Err(ReadError::Corrupt), "{what}: read without complaint");
    }
    // No `windows` at all -- what a format 1 file looks like to a reader that
    // only checked the number.
    let bytes = format!(r#"{{"format":2,"name":"n","saved_at":1,"root":{leaf}}}"#);
    assert_eq!(parse_snapshot(bytes.as_bytes()), Err(ReadError::Corrupt));
    // The control: the same shape, whole, reads.
    let bytes = format!(r#"{{"format":2,"name":"n","saved_at":1,"windows":[{{"front":0,"tabs":[{{"root":{leaf}}}]}}]}}"#);
    assert_eq!(parse_snapshot(bytes.as_bytes()), Ok(one_tab("n", SavedNode::Leaf(SavedLeaf::plain("", Agent::None)))));
}

/// What `emit` puts under `root` is a node no build from before windows
/// reads: those builds answer an unknown kind with "corrupt", which is the
/// point -- see `Project.zig`'s module comment.
#[test]
fn what_is_under_root_is_not_a_node_an_older_build_reads() {
    let text = emit(&one_tab("n", leaf("/a"))).unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    let kind = v["root"]["kind"].as_str().unwrap();
    assert!(kind != "leaf" && kind != "split", "{kind}");
}

// ---------------------------------------------------------------------------
// What a read puts right
// ---------------------------------------------------------------------------

#[test]
fn a_split_missing_its_right_child_is_corrupt_not_a_lopsided_tree() {
    let bytes = br#"{"name":"lopsided","saved_at":4,"root":{"kind":"split",
        "direction":"horizontal","ratio":0.5,
        "left":{"kind":"leaf","cwd":"/a"}}}"#;
    assert_eq!(parse_snapshot(bytes), Err(ReadError::Corrupt));
}

#[test]
fn truncated_json_is_corrupt() {
    let root = SavedNode::Split { axis: Axis::Horizontal, ratio: 0.62, left: Box::new(leaf("/a")), right: Box::new(leaf("/b")) };
    let full = emit(&one_tab("cutoff", root)).unwrap();
    assert_eq!(parse_snapshot(&full.as_bytes()[..full.len() / 2]), Err(ReadError::Corrupt));
}

/// **The floor under every key a format grows without a new number.** A file
/// with keys this build does not know must still open, with everything it
/// does know read correctly. The readers look keys up by name and ignore the
/// rest; this test is what keeps a stricter reader from breaking that.
#[test]
fn a_file_with_fields_this_build_does_not_know_still_reads() {
    let bytes = br#"{"name":"with more","saved_at":9,"flavour":2,
        "root":{"kind":"split","direction":"vertical","ratio":0.25,"weight":3,
          "left":{"kind":"leaf","cwd":"/a","title":"t","history":"h.history",
                  "scrollback":"0.snap","colour":{"r":1}},
          "right":{"kind":"leaf","unheard_of":[1,2,3]}}}"#;
    let snap = parse_snapshot(bytes).unwrap();
    assert_eq!(
        snap.tabs().next(),
        Some(&SavedNode::Split {
            axis: Axis::Vertical,
            ratio: 0.25,
            left: Box::new(SavedNode::Leaf(SavedLeaf {
                cwd: "/a".to_string(),
                title: "t".to_string(),
                history: "h.history".to_string(),
                scrollback: "0.snap".to_string(),
                agent: Agent::Unknown,
            })),
            right: Box::new(SavedNode::Leaf(SavedLeaf::plain("", Agent::Unknown))),
        })
    );
}

#[test]
fn a_scrollback_name_is_only_what_a_save_writes() {
    for ok in ["0.snap", "12.snap", "00000000000000000001.snap"] {
        assert!(is_scrollback_name(ok), "{ok:?} should be accepted");
    }
    for bad in [
        "",
        ".snap",
        "a.snap",
        "-1.snap",
        "0.SNAP",
        "0.snap.tmp",
        "0",
        "../0.snap",
        "0/1.snap",
        "..\\0.snap",
        "C:\\x\\0.snap",
        "１.snap", // full-width digit: not ASCII
        "000000000000000000001.snap", // 21 digits
    ] {
        assert!(!is_scrollback_name(bad), "{bad:?} should be refused");
    }
}

/// The case `is_scrollback_name` exists for: a project file is, through this
/// field, a list of files the core may delete. A name reaching outside the
/// snapshot directory is dropped and the rest of the pane still loads.
#[test]
fn a_scrollback_name_that_reaches_outside_is_dropped_and_the_pane_still_loads() {
    let bytes = br#"{"name":"p","saved_at":1,
        "root":{"kind":"leaf","cwd":"/a","scrollback":"..\\..\\Users\\x\\keep.snap"}}"#;
    let snap = parse_snapshot(bytes).expect("one bad field must not cost the project");
    assert_eq!(snap.tabs().next(), Some(&SavedNode::Leaf(SavedLeaf::plain("/a", Agent::Unknown))));
}

/// **Read and written back unchanged**, which is a different promise from "an
/// unknown field does not make the read fail": that one keeps the project
/// opening, this one keeps the counter from being reset by a round trip
/// through this build.
#[test]
fn next_scrollback_survives_a_read_and_a_write() {
    let bytes = br#"{"name":"p","saved_at":1,"next_scrollback":12,"root":{"kind":"leaf","scrollback":"11.snap"}}"#;
    let snap = parse_snapshot(bytes).unwrap();
    assert_eq!(snap.next_scrollback, Some(12));
    let again = emit(&snap).unwrap();
    assert!(again.contains(",\"next_scrollback\":12,"), "{again}");
    assert_eq!(parse_snapshot(again.as_bytes()).unwrap(), snap);
}

#[test]
fn direction_strings_match_project_zig_not_layout_rs() {
    assert_eq!(direction_str(Axis::Horizontal), "horizontal");
    assert_eq!(direction_str(Axis::Vertical), "vertical");
    assert_eq!(direction_from_str("horizontal"), Some(Axis::Horizontal));
    assert_eq!(direction_from_str("vertical"), Some(Axis::Vertical));
    assert_eq!(direction_from_str("h"), None);
    assert_eq!(direction_from_str("v"), None);
}

// ---------------------------------------------------------------------------
// A caller that saves one tab
// ---------------------------------------------------------------------------

fn three_tabs() -> Snapshot {
    Snapshot {
        name: "p".to_string(),
        saved_at: 1,
        group: Some("g".to_string()),
        windows: vec![
            Window {
                frame: Some(Frame { origin: Origin::TopLeft, x: 1.0, y: 2.0, width: 3.0, height: 4.0 }),
                front: 1,
                tabs: vec![Tab { root: leaf("/first") }, Tab { root: leaf("/second") }],
            },
            Window { frame: None, front: 0, tabs: vec![Tab { root: leaf("/other window") }] },
        ],
        next_scrollback: Some(5),
    }
}

/// The one tab a picture of the project shows is the one in front in the
/// window in front, not whichever happens to be written first.
#[test]
fn the_tab_in_front_is_the_first_windows_front_tab() {
    let was = three_tabs();
    assert_eq!(was.windows[0].front, 1);
    assert_eq!(was.front_tab(), Some(&was.windows[0].tabs[1].root));
    // A front that names no tab falls back to the first, and a project with
    // nothing in it has none.
    let mut odd = was.clone();
    odd.windows[0].front = 9;
    assert_eq!(odd.front_tab(), Some(&was.windows[0].tabs[0].root));
    let blank = Snapshot { name: "p".to_string(), saved_at: 1, group: None, windows: Vec::new(), next_scrollback: None };
    assert_eq!(blank.front_tab(), None);
}

/// Every snapshot of a project is in one directory, so what a save counts as
/// taken -- and must not prune -- is every name in every tab, not the names
/// of the tab being saved.
#[test]
fn the_snapshot_names_of_a_project_are_those_of_every_tab_and_window() {
    let named = |cwd: &str, snap: &str| {
        SavedNode::Leaf(SavedLeaf { scrollback: snap.to_string(), ..SavedLeaf::plain(cwd, Agent::None) })
    };
    let mut p = three_tabs();
    p.windows[0].tabs[0].root =
        SavedNode::Split { axis: Axis::Horizontal, ratio: 0.5, left: Box::new(named("/a", "0.snap")), right: Box::new(leaf("/b")) };
    p.windows[0].tabs[1].root = named("/c", "4.snap");
    p.windows[1].tabs[0].root = named("/d", "2.snap");
    assert_eq!(p.scrollback_names(), ["0.snap", "4.snap", "2.snap"]);
    assert_eq!(p.pane_count(), 4);
}

// ---------------------------------------------------------------------------
// Writing over what is there
// ---------------------------------------------------------------------------

/// **The first write over a format 1 file keeps it as `.prev`**, even when
/// the project has not changed at all -- the case that otherwise writes
/// nothing, and would leave the file in the old format for good.
#[test]
fn a_format_1_file_is_kept_when_it_is_first_written_over() {
    use polter_settings_shell::projects::{plan_for, Existing, WriteKind, WritePlan};

    let old = br#"{"name":"p","saved_at":1,"root":{"kind":"leaf","cwd":"/a"}}"#;
    // What a host that cannot tell who is in a pane saves for the same tab.
    let same = Snapshot { saved_at: 9, ..one_tab("p", SavedNode::Leaf(SavedLeaf::plain("/a", Agent::Unknown))) };
    assert_eq!(parse_snapshot(old).unwrap().windows, same.windows, "the control: nothing but the time differs");

    let found = found_on_disk(old, &same);
    assert_eq!(found, Existing::Read { layout_changed: true, only_the_time_changed: false });
    assert_eq!(plan_for(WriteKind::Save, found), WritePlan::Write { keep_previous: true });

    // The same project already in this format: nothing but the time, so
    // nothing is written -- as before.
    let current = emit(&Snapshot { saved_at: 1, ..same.clone() }).unwrap();
    let found = found_on_disk(current.as_bytes(), &same);
    assert_eq!(found, Existing::Read { layout_changed: false, only_the_time_changed: true });
    assert_eq!(plan_for(WriteKind::Save, found), WritePlan::Unchanged);
}

#[test]
fn what_a_save_finds_is_compared_over_every_tab_and_window() {
    use polter_settings_shell::projects::Existing;

    let was = three_tabs();
    let disk = emit(&was).unwrap();
    let found = |new: &Snapshot| found_on_disk(disk.as_bytes(), new);

    assert_eq!(found(&Snapshot { saved_at: 2, ..was.clone() }), Existing::Read { layout_changed: false, only_the_time_changed: true });

    // A directory in the second window: a change, not of layout.
    let mut moved = was.clone();
    moved.windows[1].tabs[0].root = leaf("/elsewhere");
    assert_eq!(found(&moved), Existing::Read { layout_changed: false, only_the_time_changed: false });

    // A split in the second tab, a tab fewer, a window fewer: layout.
    let mut split = was.clone();
    split.windows[0].tabs[1].root =
        SavedNode::Split { axis: Axis::Vertical, ratio: 0.5, left: Box::new(leaf("/second")), right: Box::new(leaf("/x")) };
    let mut fewer_tabs = was.clone();
    fewer_tabs.windows[0].tabs.pop();
    fewer_tabs.windows[0].front = 0;
    let mut fewer_windows = was.clone();
    fewer_windows.windows.pop();
    for new in [&split, &fewer_tabs, &fewer_windows] {
        assert_eq!(found(new), Existing::Read { layout_changed: true, only_the_time_changed: false });
    }

    // The group alone: a change.
    assert_eq!(found(&Snapshot { group: None, ..was.clone() }), Existing::Read { layout_changed: false, only_the_time_changed: false });

    // Not a project, and a project from a later format: kept, never read.
    assert_eq!(found_on_disk(b"{not json", &was), Existing::Unreadable);
    assert_eq!(found_on_disk(br#"{"format":3,"name":"p","saved_at":1,"windows":[]}"#, &was), Existing::Unreadable);
}
