//! The macOS host's `ProjectPagesTests`, case for case: the same project,
//! the same tabs on screen, the same answers. Where a number differs it is
//! because a frame here is measured from the top left.

use std::collections::{BTreeMap, BTreeSet};

use polter_projectfile::{emit, parse_snapshot, Agent, Axis, Frame, Origin, SavedLeaf, SavedNode, Snapshot, Tab, Who, Window};

use crate::autosave::{Change, Debounce, QUIET};
use crate::pages::{keeping_what_the_file_knew, Known, Live, Pages, Screen};
use crate::placement::{self, Home, Place, Rect};

fn leaf_of(cwd: &str, scrollback: &str, agent: Agent) -> SavedNode {
    SavedNode::Leaf(SavedLeaf { cwd: cwd.into(), title: String::new(), history: String::new(), scrollback: scrollback.into(), by_supervisor: false, agent })
}

fn leaf(cwd: &str, scrollback: &str) -> SavedNode {
    leaf_of(cwd, scrollback, Agent::None)
}

fn tab(root: SavedNode) -> Tab {
    Tab { root }
}

fn frame(x: f64) -> Frame {
    Frame { origin: Origin::TopLeft, x, y: 0.0, width: 800.0, height: 600.0 }
}

fn frames(of: &[(isize, f64)]) -> BTreeMap<isize, Frame> {
    of.iter().map(|(token, x)| (*token, frame(*x))).collect()
}

fn split(left: SavedNode, right: SavedNode, axis: Axis) -> SavedNode {
    SavedNode::Split { axis, ratio: 0.5, left: Box::new(left), right: Box::new(right) }
}

/// Two windows: three pages (ids 0, 1, 2; the second in front), and one
/// page (id 3).
fn project() -> Pages {
    Pages::from_file(&Snapshot {
        name: "p".into(),
        saved_at: 1,
        group: Some("g".into()),
        windows: vec![
            Window { frame: Some(frame(10.0)), front: 1, tabs: vec![tab(leaf("/a", "0.snap")), tab(leaf("/b", "1.snap")), tab(leaf("/c", "2.snap"))] },
            Window { frame: Some(frame(20.0)), front: 0, tabs: vec![tab(leaf("/d", "3.snap"))] },
        ],
        next_scrollback: Some(4),
    })
}

/// The directories of each window's pages, in order: enough to say which
/// page is where.
fn cwds(pages: &Pages) -> Vec<Vec<String>> {
    pages
        .file_windows()
        .iter()
        .map(|w| {
            w.tabs
                .iter()
                .map(|t| match &t.root {
                    SavedNode::Leaf(l) => l.cwd.clone(),
                    SavedNode::Split { .. } => "split".to_string(),
                })
                .collect()
        })
        .collect()
}

fn says(windows: &[&[&str]]) -> Vec<Vec<String>> {
    windows.iter().map(|w| w.iter().map(|s| s.to_string()).collect()).collect()
}

fn live(id: usize, window: isize, index: usize, selected: bool, cwd: &str) -> Live {
    Live { id, window, index, selected, root: leaf(cwd, "") }
}

fn fronts(pages: &Pages) -> Vec<usize> {
    pages.file_windows().iter().map(|w| w.front).collect()
}

fn frames_of(pages: &Pages) -> Vec<Option<Frame>> {
    pages.file_windows().iter().map(|w| w.frame).collect()
}

// ---- reading

#[test]
fn the_files_pages_come_back_as_the_files_pages() {
    let file = Snapshot {
        name: "p".into(),
        saved_at: 1,
        group: None,
        windows: vec![
            Window { frame: Some(frame(10.0)), front: 1, tabs: vec![tab(leaf("/a", "")), tab(leaf("/b", ""))] },
            Window { frame: None, front: 0, tabs: vec![tab(leaf("/c", ""))] },
        ],
        next_scrollback: None,
    };
    let pages = Pages::from_file(&file);
    assert_eq!(pages.file_windows(), file.windows);
    assert_eq!(pages.page_ids(), [0, 1, 2]);
    // Nothing open and nothing changed: a save leaves it as it is.
    assert_eq!(pages.updated(&[], &BTreeMap::new(), false), pages);
    // A front that names no tab is the first, and a window with no tab is
    // no window.
    let odd = Pages::from_file(&Snapshot {
        windows: vec![Window { frame: None, front: 7, tabs: vec![tab(leaf("/a", ""))] }, Window { frame: None, front: 0, tabs: vec![] }],
        ..file
    });
    assert_eq!(odd.file_windows(), vec![Window { frame: None, front: 0, tabs: vec![tab(leaf("/a", ""))] }]);
}

// ---- a save

/// **A page that is not open stays in the project**, with what it was last
/// saved as, in its place.
#[test]
fn a_page_that_is_not_open_stays_where_it_was() {
    // Only the first and the third page of the first window are open.
    let now = project().updated(&[live(0, 7, 0, false, "/a2"), live(2, 7, 1, true, "/c2")], &frames(&[(7, 99.0)]), false);
    assert_eq!(cwds(&now), says(&[&["/a2", "/b", "/c2"], &["/d"]]));
    // The window that is on screen has the frame it has now; the one that
    // is not keeps the frame it had.
    assert_eq!(frames_of(&now), [Some(frame(99.0)), Some(frame(20.0))]);
    // The tab showing is in front.
    assert_eq!(fronts(&now), [2, 0]);
}

#[test]
fn a_closed_page_follows_the_page_it_followed_and_is_first_when_it_followed_none() {
    // The first page is closed, the other two have swapped places.
    let swapped = project().updated(&[live(2, 7, 0, false, "/c"), live(1, 7, 1, false, "/b")], &BTreeMap::new(), false);
    assert_eq!(cwds(&swapped), says(&[&["/a", "/c", "/b"], &["/d"]]));
    // The middle page is closed: it stays after the first, wherever the
    // first has gone.
    let moved = project().updated(&[live(2, 7, 0, false, "/c"), live(0, 7, 1, false, "/a")], &BTreeMap::new(), false);
    assert_eq!(cwds(&moved), says(&[&["/c", "/a", "/b"], &["/d"]]));
}

/// The order of the pages is the order of the tabs, whatever tabs of other
/// things stand between them.
#[test]
fn open_pages_are_in_the_order_of_the_tabs() {
    let now = project().updated(
        &[live(0, 7, 9, false, "/a"), live(1, 7, 2, false, "/b"), live(2, 7, 5, false, "/c"), live(3, 8, 0, false, "/d")],
        &BTreeMap::new(),
        false,
    );
    assert_eq!(cwds(&now), says(&[&["/b", "/c", "/a"], &["/d"]]));
}

/// The page in front is the tab showing when that is one of the project's;
/// when the tab showing is something else, it is the page that was in front.
#[test]
fn the_page_in_front_is_the_tab_showing_or_stays_what_it_was() {
    let all = [live(0, 7, 0, false, "/a"), live(1, 7, 1, false, "/b"), live(2, 7, 2, false, "/c")];
    assert_eq!(fronts(&project().updated(&all, &BTreeMap::new(), false))[0], 1);
    let third = [all[0].clone(), all[1].clone(), live(2, 7, 2, true, "/c")];
    assert_eq!(fronts(&project().updated(&third, &BTreeMap::new(), false))[0], 2);
    // The page that was in front was dragged away: the first is.
    let dragged = [all[0].clone(), live(1, 9, 0, false, "/b"), all[2].clone()];
    let now = project().updated(&dragged, &BTreeMap::new(), false);
    assert_eq!(cwds(&now), says(&[&["/a", "/c"], &["/d"], &["/b"]]));
    assert_eq!(fronts(&now)[0], 0);
}

/// **A window closing does not make its last tab the page in front.** Its
/// tabs close one after another, and the host shows each of the ones left
/// in turn; each closing tab's save keeps what was in front.
#[test]
fn a_closing_tabs_save_keeps_the_page_that_was_in_front() {
    // The page in front (id 1) has closed already; the host now shows the
    // third, which is closing next.
    let left = [live(0, 7, 0, false, "/a"), live(2, 7, 1, true, "/c")];
    let closing = project().updated(&left, &BTreeMap::new(), true);
    assert_eq!(cwds(&closing), says(&[&["/a", "/b", "/c"], &["/d"]]));
    assert_eq!(fronts(&closing)[0], 1);
    // The same tabs in a save that is nobody closing: the tab showing is
    // the page in front.
    assert_eq!(fronts(&project().updated(&left, &BTreeMap::new(), false))[0], 2);
}

/// A tab dragged to another window is a page of that window; dragged out on
/// its own, it is a window more.
#[test]
fn a_page_dragged_to_another_window_is_in_that_window() {
    let into_the_other = project().updated(
        &[live(0, 7, 0, false, "/a"), live(1, 7, 1, false, "/b"), live(3, 8, 0, false, "/d"), live(2, 8, 1, false, "/c")],
        &frames(&[(7, 1.0), (8, 2.0)]),
        false,
    );
    assert_eq!(cwds(&into_the_other), says(&[&["/a", "/b"], &["/d", "/c"]]));
    assert_eq!(frames_of(&into_the_other), [Some(frame(1.0)), Some(frame(2.0))]);

    let on_its_own = project().updated(
        &[live(0, 7, 0, false, "/a"), live(1, 7, 1, false, "/b"), live(2, 9, 0, false, "/c"), live(3, 8, 0, false, "/d")],
        &frames(&[(7, 1.0), (8, 2.0), (9, 3.0)]),
        false,
    );
    assert_eq!(cwds(&on_its_own), says(&[&["/a", "/b"], &["/d"], &["/c"]]));
    assert_eq!(frames_of(&on_its_own), [Some(frame(1.0)), Some(frame(2.0)), Some(frame(3.0))]);
}

/// Two windows of the project put together into one on screen are one
/// window of the file.
#[test]
fn two_windows_made_one_are_one() {
    let merged = project().updated(
        &[live(0, 7, 0, false, "/a"), live(1, 7, 1, false, "/b"), live(2, 7, 2, false, "/c"), live(3, 7, 3, false, "/d")],
        &frames(&[(7, 1.0)]),
        false,
    );
    assert_eq!(cwds(&merged), says(&[&["/a", "/b", "/c", "/d"]]));
}

/// A window of the file goes on as the window on screen most of its open
/// pages are in, not as the one its first page went to.
#[test]
fn a_window_goes_on_as_the_window_most_of_its_pages_are_in() {
    // The first page was dragged out; the other two stayed.
    let now = project().updated(
        &[live(0, 9, 0, false, "/a"), live(1, 7, 0, false, "/b"), live(2, 7, 1, false, "/c"), live(3, 8, 0, false, "/d")],
        &frames(&[(7, 1.0), (8, 2.0), (9, 3.0)]),
        false,
    );
    assert_eq!(cwds(&now), says(&[&["/b", "/c"], &["/d"], &["/a"]]));
    assert_eq!(frames_of(&now), [Some(frame(1.0)), Some(frame(2.0)), Some(frame(3.0))]);
}

/// The windows keep their order, whichever is in front on screen.
#[test]
fn the_order_of_the_windows_does_not_follow_the_screen() {
    let all = [live(3, 1, 0, true, "/d"), live(0, 2, 0, false, "/a"), live(1, 2, 1, false, "/b"), live(2, 2, 2, false, "/c")];
    assert_eq!(cwds(&project().updated(&all, &BTreeMap::new(), false)), says(&[&["/a", "/b", "/c"], &["/d"]]));
}

#[test]
fn a_new_page_is_a_page_of_the_window_its_tab_is_in() {
    let mut pages = project();
    let id = pages.new_page_id();
    assert_eq!(id, 4);
    let now = pages.updated(&[live(1, 7, 0, false, "/b"), live(id, 7, 1, false, "/new")], &BTreeMap::new(), false);
    // The page that is not open keeps its place after the one it followed;
    // the new tab is where its tab is, after that.
    assert_eq!(cwds(&now), says(&[&["/a", "/b", "/c", "/new"], &["/d"]]));
    // And an id is not given twice -- by the project as it was, or as the
    // save left it.
    assert_eq!(pages.new_page_id(), 5);
    let mut after = now;
    assert_eq!(after.new_page_id(), 5);
}

// ---- taking a page out

#[test]
fn taking_a_page_out_leaves_the_rest() {
    let mut pages = project();
    pages.remove(1);
    assert_eq!(cwds(&pages), says(&[&["/a", "/c"], &["/d"]]));
    // It was the page in front: the first that is left is. Asked of the
    // page's id as well as of its place in the file -- a front left naming
    // the page that went writes the same file, and then nothing is brought
    // to the front when the project is opened.
    assert_eq!(fronts(&pages)[0], 0);
    assert_eq!(pages.windows()[0].front, pages.windows()[0].pages[0].id);
    assert_eq!(pages.scrollback_names(), ["0.snap", "2.snap", "3.snap"]);
    // A window's only page takes the window with it.
    pages.remove(3);
    assert_eq!(cwds(&pages), says(&[&["/a", "/c"]]));
}

// ---- across a restart

/// A tab that comes back finds its page by what its panes are called, not
/// by where it stood.
#[test]
fn a_restored_tab_finds_its_page_by_its_panes_snapshot_names() {
    let pages = project();
    let none = BTreeSet::new();
    assert_eq!(pages.page_sharing(&["2.snap"], &none), Some(2));
    // One pane is enough: the other was split off since the last save.
    assert_eq!(pages.page_sharing(&["", "3.snap"], &none), Some(3));
    // **The file decides.** A tab none of whose panes the file has is in no
    // project, whatever it says -- and so is a tab with no name to go by.
    assert_eq!(pages.page_sharing(&["9.snap"], &none), None);
    assert_eq!(pages.page_sharing(&[], &none), None);
    assert_eq!(pages.page_sharing(&[""], &none), None);
    // A page is one tab's: a second that claims it does not get it.
    assert_eq!(pages.page_sharing(&["2.snap"], &BTreeSet::from([2])), None);
}

// ---- what a save cannot tell

fn worker() -> Agent {
    Agent::Agent(Who { role: "polter-dev".into(), cli: "codex".into(), session: "s".into(), supervisor: false })
}

fn one_tab(root: SavedNode, next: u64) -> Snapshot {
    Snapshot { name: "p".into(), saved_at: 1, group: None, windows: vec![Window { frame: None, front: 0, tabs: vec![tab(root)] }], next_scrollback: Some(next) }
}

/// **Not known does not overwrite what the file knew**; an answer does.
#[test]
fn a_pane_nobody_can_tell_about_keeps_what_the_file_said_of_it() {
    let pages = Pages::from_file(&one_tab(split(leaf_of("/a", "0.snap", worker()), leaf_of("/b", "1.snap", Agent::None), Axis::Horizontal), 2));
    let known = pages.known();
    assert_eq!(
        known,
        BTreeMap::from([
            ("0.snap".to_string(), Known { cwd: "/a".into(), agent: worker() }),
            ("1.snap".to_string(), Known { cwd: "/b".into(), agent: Agent::None }),
        ])
    );

    // The save cannot tell about either pane.
    let asked = split(leaf_of("/a", "0.snap", Agent::Unknown), leaf_of("/b", "1.snap", Agent::Unknown), Axis::Horizontal);
    assert_eq!(
        keeping_what_the_file_knew(&asked, &known),
        split(leaf_of("/a", "0.snap", worker()), leaf_of("/b", "1.snap", Agent::None), Axis::Horizontal)
    );

    // It can: what it says is what is written, even "nobody" over an agent.
    assert_eq!(keeping_what_the_file_knew(&leaf_of("/a", "0.snap", Agent::None), &known), leaf_of("/a", "0.snap", Agent::None));
    // A pane the file never had, and one with no name to match by, stay not
    // known.
    assert_eq!(keeping_what_the_file_knew(&leaf_of("/c", "7.snap", Agent::Unknown), &known), leaf_of("/c", "7.snap", Agent::Unknown));
    assert_eq!(keeping_what_the_file_knew(&leaf_of("/c", "", Agent::Unknown), &known), leaf_of("/c", "", Agent::Unknown));
}

/// A pane's own things go with the pane, by its name, whichever page it is
/// on now.
#[test]
fn what_the_file_knew_of_a_pane_is_found_wherever_the_pane_is() {
    // In the file the worker's pane is on the second page.
    let file = Snapshot {
        name: "p".into(),
        saved_at: 1,
        group: None,
        windows: vec![Window { frame: None, front: 0, tabs: vec![tab(leaf_of("/a", "0.snap", Agent::None)), tab(leaf_of("/b", "1.snap", worker()))] }],
        next_scrollback: Some(2),
    };
    let known = Pages::from_file(&file).known();
    assert_eq!(keeping_what_the_file_knew(&leaf_of("/b", "1.snap", Agent::Unknown), &known), leaf_of("/b", "1.snap", worker()));
}

/// **A project just opened does not lose its directories.** A pane has none
/// to report until its shell says one; the save that follows opening by a
/// second or two finds every pane with none.
#[test]
fn a_pane_that_cannot_say_where_it_is_yet_keeps_the_directory_it_was_opened_in() {
    let known = Pages::from_file(&one_tab(leaf_of("/work/repo", "0.snap", Agent::None), 1)).known();
    assert_eq!(keeping_what_the_file_knew(&leaf_of("", "0.snap", Agent::None), &known), leaf_of("/work/repo", "0.snap", Agent::None));
    // Once it has said one, that is the one.
    assert_eq!(keeping_what_the_file_knew(&leaf_of("/elsewhere", "0.snap", Agent::None), &known), leaf_of("/elsewhere", "0.snap", Agent::None));
}

/// A whole save, as the host makes one: two tabs open of three pages, one
/// of them just opened and able to say nothing of itself.
#[test]
fn a_save_writes_the_open_tabs_as_they_are_and_the_rest_as_they_were() {
    let file = Snapshot {
        name: "p".into(),
        saved_at: 1,
        group: Some("g".into()),
        windows: vec![
            Window { frame: Some(frame(10.0)), front: 0, tabs: vec![tab(leaf_of("/a", "0.snap", worker())), tab(leaf_of("/b", "1.snap", Agent::None))] },
            Window { frame: Some(frame(20.0)), front: 0, tabs: vec![tab(leaf_of("/d", "3.snap", worker()))] },
        ],
        next_scrollback: Some(4),
    };
    let pages = Pages::from_file(&file);
    let screen = Screen {
        live: vec![
            // Just opened: no directory yet, and nobody can say who.
            Live { id: 0, window: 7, index: 0, selected: false, root: leaf_of("", "0.snap", Agent::Unknown) },
            // A split made since, in the second page.
            Live {
                id: 1,
                window: 7,
                index: 1,
                selected: true,
                root: split(leaf_of("/b2", "1.snap", Agent::Unknown), leaf_of("/new", "4.snap", Agent::Unknown), Axis::Vertical),
            },
        ],
        frames: frames(&[(7, 77.0)]),
        keeping_front: false,
    };
    let (after, written) = pages.saving("p", 9, Some("g".into()), Some(5), &screen);

    assert_eq!(
        written,
        Snapshot {
            name: "p".into(),
            saved_at: 9,
            group: Some("g".into()),
            windows: vec![
                Window {
                    frame: Some(frame(77.0)),
                    front: 1,
                    tabs: vec![
                        tab(leaf_of("/a", "0.snap", worker())),
                        tab(split(leaf_of("/b2", "1.snap", Agent::None), leaf_of("/new", "4.snap", Agent::Unknown), Axis::Vertical)),
                    ],
                },
                // Not open: exactly as it was.
                Window { frame: Some(frame(20.0)), front: 0, tabs: vec![tab(leaf_of("/d", "3.snap", worker()))] },
            ],
            next_scrollback: Some(5),
        }
    );
    assert_eq!(after.file_windows(), written.windows);
    // What is written is a file all three implementations read back.
    assert_eq!(parse_snapshot(emit(&written).unwrap().as_bytes()).unwrap(), written);
    // And the next save starts from it: nothing changed, nothing to do.
    let (again, _) = after.saving("p", 10, Some("g".into()), Some(5), &Screen::default());
    assert_eq!(again, after);
}

// ---- where a window opens

const SCREEN: Rect = Rect { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 };
const SECOND: Rect = Rect { x: 1440.0, y: 0.0, width: 1920.0, height: 1080.0 };

fn stored(x: f64, y: f64, w: f64, h: f64) -> Option<Frame> {
    Some(Frame { origin: Origin::TopLeft, x, y, width: w, height: h })
}

fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect {
    Rect { x, y, width: w, height: h }
}

#[test]
fn a_frame_on_a_screen_that_is_there_is_left_alone() {
    assert_eq!(placement::frame(stored(100.0, 50.0, 800.0, 600.0), &[SCREEN]), Some(rect(100.0, 50.0, 800.0, 600.0)));
    assert_eq!(placement::frame(stored(1500.0, 40.0, 1800.0, 1000.0), &[SCREEN, SECOND]), Some(rect(1500.0, 40.0, 1800.0, 1000.0)));
    // Asked with no screen to go by: as it was.
    assert_eq!(placement::frame(stored(1500.0, 40.0, 800.0, 600.0), &[]), Some(rect(1500.0, 40.0, 800.0, 600.0)));
}

/// The second screen is gone: the window comes back onto the one that is
/// left, whole, and no bigger than it.
#[test]
fn a_frame_off_every_screen_is_brought_back_onto_one() {
    // Was on the second screen, which is not there now.
    assert_eq!(placement::frame(stored(1500.0, 40.0, 800.0, 600.0), &[SCREEN]), Some(rect(640.0, 40.0, 800.0, 600.0)));
    // Bigger than the screen that is left.
    assert_eq!(placement::frame(stored(1500.0, 40.0, 1800.0, 1000.0), &[SCREEN]), Some(SCREEN));
    // Hanging off the left and the top.
    assert_eq!(placement::frame(stored(-300.0, -200.0, 800.0, 600.0), &[SCREEN]), Some(rect(0.0, 0.0, 800.0, 600.0)));
    // Across two screens: onto the one that holds more of it.
    assert_eq!(placement::frame(stored(1300.0, 100.0, 800.0, 600.0), &[SCREEN, SECOND]), Some(rect(1440.0, 100.0, 800.0, 600.0)));
    assert_eq!(placement::frame(stored(900.0, 100.0, 800.0, 600.0), &[SCREEN, SECOND]), Some(rect(640.0, 100.0, 800.0, 600.0)));
}

#[test]
fn a_frame_that_is_not_a_place_here_is_no_frame() {
    // Nothing recorded: every window of a format 1 file.
    assert_eq!(placement::frame(None, &[SCREEN]), None);
    // Measured from the other corner, on macOS.
    assert_eq!(placement::frame(Some(Frame { origin: Origin::BottomLeft, x: 100.0, y: 50.0, width: 800.0, height: 600.0 }), &[SCREEN]), None);
    // Not a rectangle, and not a number.
    assert_eq!(placement::frame(stored(100.0, 50.0, 0.0, 600.0), &[SCREEN]), None);
    assert_eq!(placement::frame(stored(100.0, 50.0, 800.0, -1.0), &[SCREEN]), None);
    assert_eq!(placement::frame(stored(f64::NAN, 50.0, 800.0, 600.0), &[SCREEN]), None);
    assert_eq!(placement::frame(stored(100.0, 50.0, f64::NAN, 600.0), &[SCREEN]), None);
}

/// **A window that recorded where it was opens there, as a window; one that
/// did not opens as tabs of the window the person is in** -- which is every
/// project from before frames were recorded, and how those always opened.
#[test]
fn a_window_with_a_frame_is_its_own_window_and_one_without_is_tabs_of_the_current_window() {
    let place = |frame: Option<Frame>, first: bool, named: bool, current: bool| placement::place(frame, first, named, current, &[SCREEN]);
    let recorded = stored(100.0, 50.0, 800.0, 600.0);
    let there = Place::OwnWindow(Some(rect(100.0, 50.0, 800.0, 600.0)));

    assert_eq!(place(recorded, true, false, true), there);
    // Off the screen: still its own window, brought back onto it.
    assert_eq!(place(stored(1500.0, 40.0, 800.0, 600.0), true, false, true), Place::OwnWindow(Some(rect(640.0, 40.0, 800.0, 600.0))));
    // No frame: tabs where the person is -- and with no terminal window to
    // go into, a window wherever a new one goes.
    assert_eq!(place(None, true, false, true), Place::Tabs(Home::Current));
    assert_eq!(place(None, true, false, false), Place::OwnWindow(None));
    // A frame from the other corner is no frame here.
    let mac = Some(Frame { origin: Origin::BottomLeft, x: 100.0, y: 50.0, width: 800.0, height: 600.0 });
    assert_eq!(place(mac, true, false, true), Place::Tabs(Home::Current));
    // Each window by its own frame, first or not.
    assert_eq!(place(recorded, false, false, true), there);
    assert_eq!(place(None, false, false, true), Place::Tabs(Home::Current));

    // From the control room: the first window goes where it says, frame or
    // none; the others by the rules above.
    assert_eq!(place(recorded, true, true, true), Place::Tabs(Home::Named));
    assert_eq!(place(None, true, true, false), Place::Tabs(Home::Named));
    assert_eq!(place(recorded, false, true, true), there);
    assert_eq!(place(None, false, true, true), Place::Tabs(Home::Current));
    assert_eq!(place(None, false, true, false), Place::OwnWindow(None));
}

#[test]
fn a_windows_frame_is_recorded_from_the_top_left() {
    assert_eq!(placement::stored(rect(12.0, 34.0, 560.0, 780.0)), stored(12.0, 34.0, 560.0, 780.0).unwrap());
    // And what is recorded is a place here again.
    assert_eq!(placement::frame(Some(placement::stored(rect(12.0, 34.0, 560.0, 780.0))), &[SCREEN]), Some(rect(12.0, 34.0, 560.0, 780.0)));
}

// ---- how soon

/// Each kind of change has a latest moment, and the ones a person makes
/// with their own hands the soonest. The numbers are the macOS host's.
#[test]
fn every_kind_of_change_has_a_latest_moment() {
    assert_eq!(QUIET, 1.0);
    assert_eq!(Change::Layout.no_later_than(), 3.0);
    assert_eq!(Change::Pages.no_later_than(), Change::Layout.no_later_than());
    assert_eq!(Change::Front.no_later_than(), Change::Layout.no_later_than());
    assert_eq!(Change::WindowFrame.no_later_than(), 10.0);
    assert_eq!(Change::PaneDetail.no_later_than(), 30.0);
    for change in Change::ALL {
        assert!(change.no_later_than() >= QUIET);
        assert!(change.no_later_than() <= 30.0);
    }
}

/// Changes `every` seconds apart for `seconds`, starting at `from`; the
/// times a write happened.
fn churn(debounce: &mut Debounce, change: Change, from: f64, seconds: f64, every: f64) -> Vec<f64> {
    let mut writes = Vec::new();
    let mut now = from;
    while now < from + seconds {
        if debounce.take_if_due(now) {
            writes.push(now);
        }
        debounce.poke(change, now);
        now += every;
    }
    if debounce.take_if_due(now) {
        writes.push(now);
    }
    writes
}

#[test]
fn a_burst_of_changes_is_one_write() {
    let mut d = Debounce::new();
    // A two-second divider drag at 60 events a second.
    let mut now = 0.0;
    for _ in 0..120 {
        assert!(!d.take_if_due(now));
        d.poke(Change::Layout, now);
        now += 1.0 / 60.0;
    }
    assert!(d.is_pending());
    // Not before its second of quiet is over.
    assert!(!d.take_if_due(now + 0.9));
    assert!(d.take_if_due(now + 1.0));
    // And then nothing is pending: one write.
    assert!(!d.is_pending());
    assert!(!d.take_if_due(now + 60.0));
}

/// What the user reported on macOS: a split made while agents were working
/// was not in the project. Every title change restarted the wait.
#[test]
fn a_layout_change_is_written_while_titles_keep_changing() {
    let mut d = Debounce::new();
    d.poke(Change::Layout, 0.0);
    let writes = churn(&mut d, Change::PaneDetail, 0.25, 10.0, 0.25);
    let first = writes.first().copied().unwrap_or(f64::INFINITY);
    assert!(first <= Change::Layout.no_later_than() + 0.25, "{writes:?}");
    assert!(first > QUIET);
}

#[test]
fn titles_that_never_stop_are_written_now_and_then_and_not_each_time() {
    let mut d = Debounce::new();
    // Ninety seconds, 360 changes: not none, and not 360.
    let writes = churn(&mut d, Change::PaneDetail, 0.0, 90.0, 0.25);
    assert_eq!(writes.len(), 3, "{writes:?}");
}

#[test]
fn a_window_being_dragged_is_written_within_its_ten_seconds() {
    let mut d = Debounce::new();
    let writes = churn(&mut d, Change::WindowFrame, 0.0, 25.0, 0.1);
    assert_eq!(writes.len(), 2, "{writes:?}");
    assert!(writes[0] <= 10.0 + 0.1 && writes[0] > 9.0, "{writes:?}");
}

#[test]
fn a_layout_change_brings_forward_a_write_that_was_waiting_on_titles() {
    let mut d = Debounce::new();
    assert!(churn(&mut d, Change::PaneDetail, 0.0, 10.0, 0.25).is_empty());
    d.poke(Change::Layout, 10.0);
    let writes = churn(&mut d, Change::PaneDetail, 10.25, 5.0, 0.25);
    let first = writes.first().copied().unwrap_or(f64::INFINITY);
    assert!(first <= 10.0 + Change::Layout.no_later_than() + 0.25, "{writes:?}");
    // And a title after a layout change does not push it back out.
    assert!(first > 10.0);
}

#[test]
fn one_change_alone_waits_out_its_second_and_says_when() {
    let mut d = Debounce::new();
    assert_eq!(d.due_at(), None);
    assert_eq!(d.poke(Change::Layout, 5.0), 6.0);
    assert_eq!(d.due_at(), Some(6.0));
    assert!(!d.take_if_due(5.9));
    assert!(d.take_if_due(6.0));
    assert_eq!(d.due_at(), None);
}

#[test]
fn a_write_that_was_dropped_or_done_leaves_no_latest_moment_behind() {
    let mut d = Debounce::new();
    // A layout change, dropped (the tab left the project). Titles after it
    // are a new burst with their own, longer, latest moment.
    d.poke(Change::Layout, 0.0);
    d.cancel();
    assert!(!d.is_pending());
    assert!(churn(&mut d, Change::PaneDetail, 0.5, 10.0, 0.25).is_empty());
    // The same after a flush, which says whether there was one to make.
    assert!(d.flush());
    assert!(!d.flush());
    assert!(churn(&mut d, Change::PaneDetail, 20.0, 10.0, 0.25).is_empty());
}
