//! The macOS host's `ProjectPagesTests`, case for case: the same project,
//! the same tabs on screen, the same answers. Where a number differs it is
//! because a frame here is measured from the top left.

use std::collections::{BTreeMap, BTreeSet};

use polter_projectfile::{emit, parse_snapshot, Agent, Axis, Frame, Origin, PaneColor, SavedLeaf, SavedNode, Snapshot, Tab, Who, Window, Workers};

use crate::autosave::{Change, Debounce, QUIET};
use crate::pages::{keeping_what_the_file_knew, Known, Live, Pages, Screen};
use crate::placement::{self, Home, Place, Rect};

fn leaf_of(cwd: &str, scrollback: &str, agent: Agent) -> SavedNode {
    SavedNode::Leaf(SavedLeaf { scrollback: scrollback.into(), ..SavedLeaf::plain(cwd, agent) })
}

/// What the file says of a pane with no mark on it.
fn unmarked() -> Known {
    Known { cwd: String::new(), agent: Agent::None, supervisor_seat: false, color: PaneColor::None, workers: Workers::Allowed, shielded: false }
}

/// A pane with these marks, `None` being "the host could not tell yet".
fn marked(cwd: &str, scrollback: &str, seat: Option<bool>, color: Option<PaneColor>, workers: Option<Workers>, shielded: Option<bool>) -> SavedNode {
    SavedNode::Leaf(SavedLeaf { scrollback: scrollback.into(), supervisor_seat: seat, color, workers, shielded, ..SavedLeaf::plain(cwd, Agent::None) })
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
                    SavedNode::Stack { .. } => "stack".to_string(),
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
            ("0.snap".to_string(), Known { cwd: "/a".into(), agent: worker(), ..unmarked() }),
            ("1.snap".to_string(), Known { cwd: "/b".into(), agent: Agent::None, ..unmarked() }),
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

// ---- what the host tells the core

use crate::orders::{self, Have, Kind, Order, Start, Step};
use crate::stated::{self, FailedWhy, Refusal, Stated};

fn chief() -> Agent {
    Agent::Agent(Who { role: "polter-supervisor".into(), cli: "claude-code".into(), session: "s".into(), supervisor: true })
}

fn terms(of: &[&str]) -> Vec<String> {
    of.iter().map(|t| t.to_string()).collect()
}

/// One window, two pages: the first is the supervisor beside a worker, the
/// second one pane.
fn tied() -> Pages {
    Pages::from_file(&Snapshot {
        name: "web-app".into(),
        saved_at: 1,
        group: Some("web-app".into()),
        windows: vec![Window {
            frame: None,
            front: 0,
            tabs: vec![tab(split(leaf_of("/a", "0.snap", chief()), leaf_of("/b", "1.snap", worker()), Axis::Horizontal)), tab(leaf("/c", "2.snap"))],
        }],
        next_scrollback: Some(3),
    })
}

/// The statement is these bytes: the contract's own example, key for key.
#[test]
fn the_statement_says_every_key_of_every_project() {
    let list = [
        Stated {
            name: "web-app".into(),
            group: Some("web-app".into()),
            pages: 3,
            open: Some(vec![terms(&["0xa1", "0xb1"]), terms(&["0xb2"])]),
            supervisor: Some("0xa1".into()),
            workers: terms(&["0xb1", "0xb2"]),
        },
        Stated { name: "notes".into(), group: None, pages: 1, open: None, supervisor: None, workers: Vec::new() },
    ];
    assert_eq!(
        stated::statement(&list),
        concat!(
            r#"{"act":"projects","list":["#,
            r#"{"name":"web-app","group":"web-app","pages":3,"open":[["0xa1","0xb1"],["0xb2"]],"supervisor":"0xa1","workers":["0xb1","0xb2"]},"#,
            r#"{"name":"notes","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}"#,
            r#"]}"#
        )
    );
    assert_eq!(stated::refusal(&list), None);
    // No project at all is still a statement: "there are none" is not
    // "nothing was said".
    assert_eq!(stated::statement(&[]), r#"{"act":"projects","list":[]}"#);
    // A name is written as JSON writes it.
    let odd = [Stated { name: "a\"b\\c".into(), group: None, pages: 0, open: None, supervisor: None, workers: Vec::new() }];
    assert_eq!(stated::statement(&odd), r#"{"act":"projects","list":[{"name":"a\"b\\c","group":null,"pages":0,"open":null,"supervisor":null,"workers":[]}]}"#);
}

#[test]
fn a_project_that_is_not_open_says_what_its_file_says() {
    let file = Snapshot { name: "notes".into(), saved_at: 1, group: Some("g".into()), windows: tied().file_windows(), next_scrollback: None };
    assert_eq!(Stated::of_closed(&file), Stated { name: "notes".into(), group: Some("g".into()), pages: 2, open: None, supervisor: None, workers: Vec::new() });
}

/// The supervisor's terminal is the one in the pane the file marks, found
/// by where that pane stands among its page's panes.
#[test]
fn an_open_project_says_its_pages_terminals_and_where_its_supervisor_is() {
    let pages = tied();
    // Said in the order the tabs happen to be held in, which is not the
    // project's.
    let said = Stated::of_open("web-app", Some("web-app".into()), &pages, &[(1, terms(&["0xc"])), (0, terms(&["0xa", "0xb"]))]);
    assert_eq!(
        said,
        Stated { name: "web-app".into(), group: Some("web-app".into()), pages: 2, open: Some(vec![terms(&["0xa", "0xb"]), terms(&["0xc"])]), supervisor: Some("0xa".into()), workers: Vec::new() }
    );
    assert_eq!(stated::refusal(&[said]), None);

    // Only the second page open: the supervisor's pane is not on screen.
    let said = Stated::of_open("web-app", None, &pages, &[(1, terms(&["0xc"]))]);
    assert_eq!(said.open, Some(vec![terms(&["0xc"])]));
    assert_eq!(said.supervisor, None);
    assert_eq!(said.pages, 2);

    // No page open is not "open with nothing".
    let said = Stated::of_open("web-app", None, &pages, &[]);
    assert_eq!(said.open, None);

    // An agent in a pane is not the supervisor for being an agent: with
    // the worker's pane first, it is still the marked pane that is named.
    let turned = Pages::from_file(&one_tab(split(leaf_of("/b", "1.snap", worker()), leaf_of("/a", "0.snap", chief()), Axis::Horizontal), 2));
    assert_eq!(Stated::of_open("p", None, &turned, &[(0, terms(&["0xw", "0xs"]))]).supervisor, Some("0xs".into()));
    // And a project nobody is marked in names nobody.
    let unmarked = Pages::from_file(&one_tab(leaf_of("/b", "1.snap", worker()), 2));
    assert_eq!(Stated::of_open("p", None, &unmarked, &[(0, terms(&["0xw"]))]).supervisor, None);
}

/// A page split since it was written has three terminals and two leaves:
/// counting along it would name the wrong pane, so nobody is named.
#[test]
fn a_page_that_changed_since_it_was_written_names_no_supervisor() {
    let said = Stated::of_open("web-app", None, &tied(), &[(0, terms(&["0xnew", "0xa", "0xb"]))]);
    assert_eq!(said.open, Some(vec![terms(&["0xnew", "0xa", "0xb"])]));
    assert_eq!(said.supervisor, None);
}

#[test]
fn what_the_core_would_refuse_is_found_before_it_is_said() {
    let p = |name: &str, open: Option<Vec<Vec<String>>>, supervisor: Option<&str>, workers: &[&str]| Stated {
        name: name.into(),
        group: None,
        pages: 1,
        open,
        supervisor: supervisor.map(str::to_string),
        workers: terms(workers),
    };
    let on = |t: &[&str]| Some(vec![terms(t)]);
    assert_eq!(stated::refusal(&[p("a", None, None, &[]), p("a", None, None, &[])]), Some(Refusal::SameName("a".into())));
    assert_eq!(
        stated::refusal(&[p("a", on(&["0x1"]), None, &[]), p("b", on(&["0x2", "0x1"]), None, &[])]),
        Some(Refusal::OnTwoProjects("0x1".into(), "a".into(), "b".into()))
    );
    assert_eq!(stated::refusal(&[p("a", on(&["0x1"]), Some("0x9"), &[])]), Some(Refusal::SupervisorOffPage("a".into())));
    assert_eq!(stated::refusal(&[p("a", None, Some("0x1"), &[])]), Some(Refusal::SupervisorOffPage("a".into())));
    assert_eq!(stated::refusal(&[p("a", on(&["0x1"]), Some("0x1"), &["0x7"])]), Some(Refusal::WorkerOffPage("a".into(), "0x7".into())));
    assert_eq!(stated::refusal(&[p("a", None, None, &["0x7"])]), Some(Refusal::WorkerOffPage("a".into(), "0x7".into())));
    assert_eq!(stated::refusal(&[p("a", Some(Vec::new()), None, &[])]), Some(Refusal::OpenWithNothing("a".into())));
    // And what it takes.
    assert_eq!(stated::refusal(&[p("a", on(&["0x1", "0x2"]), Some("0x1"), &["0x2"]), p("b", on(&["0x3"]), None, &[])]), None);
}

#[test]
fn the_three_other_things_a_host_says() {
    assert_eq!(stated::failed("web-app", FailedWhy::NotFound), r#"{"act":"project_failed","name":"web-app","why":"not_found"}"#);
    assert_eq!(stated::failed("web-app", FailedWhy::Unreadable), r#"{"act":"project_failed","name":"web-app","why":"unreadable"}"#);
    assert_eq!(stated::remove_question("0xb2"), r#"{"act":"project_remove","terminal":"0xb2"}"#);
    assert_eq!(stated::rename_question("web-app", "storefront"), r#"{"act":"project_rename","from":"web-app","to":"storefront"}"#);
}

// ---- what the core asks of the host

const SNAPSHOT: &str = r#"{
  "rev": 7,
  "projects_known": true,
  "project_orders": [
    {"order":"open",     "project":"web-app","group":"web-app","to":null,"terminal":null},
    {"order":"create",   "project":"nightly","group":"nightly","to":null,"terminal":"0xa1"},
    {"order":"bind",     "project":"scratch","group":"old","to":"old","terminal":"0xa1"},
    {"order":"set_group","project":"copy","group":null,"to":null,"terminal":null},
    {"order":"rename",   "project":"web-app","group":null,"to":"storefront","terminal":null},
    {"order":"add_tab",  "project":"web-app","group":null,"to":null,"terminal":"0xb9"}
  ],
  "groups": [
    {"name":"web-app","project":{"tie":"bound","name":"web-app","pages":3,"open":false,"start":"project","why":"none"}},
    {"name":"old","project":{"tie":"undecided","name":null,"pages":null,"open":null,"start":"directory","why":"projects_unknown"}},
    {"name":"before-ties"}
  ]
}"#;

fn order(kind: Kind, project: &str, group: Option<&str>, to: Option<&str>, terminal: Option<&str>) -> Order {
    Order { kind, project: project.into(), group: group.map(str::to_string), to: to.map(str::to_string), terminal: terminal.map(str::to_string) }
}

#[test]
fn the_snapshots_orders_and_each_groups_project_are_read() {
    let told = orders::decode(SNAPSHOT).unwrap();
    assert!(told.known);
    assert_eq!(
        told.orders,
        [
            order(Kind::Open, "web-app", Some("web-app"), None, None),
            order(Kind::Create, "nightly", Some("nightly"), None, Some("0xa1")),
            order(Kind::Bind, "scratch", Some("old"), Some("old"), Some("0xa1")),
            order(Kind::SetGroup, "copy", None, None, None),
            order(Kind::Rename, "web-app", None, Some("storefront"), None),
            order(Kind::AddTab, "web-app", None, None, Some("0xb9")),
        ]
    );
    let web = &told.groups["web-app"];
    assert_eq!((web.name.as_deref(), web.pages, web.open, web.start, web.why.as_str()), (Some("web-app"), Some(3), Some(false), Start::Project, "none"));
    // Not known is not zero and not closed.
    let old = &told.groups["old"];
    assert_eq!((old.name.as_deref(), old.pages, old.open, old.start, old.why.as_str()), (None, None, None, Start::Directory, "projects_unknown"));
    assert!(!told.groups.contains_key("before-ties"));
}

#[test]
fn a_snapshot_from_before_projects_says_the_host_has_said_nothing() {
    let told = orders::decode(r#"{"rev":1,"groups":[{"name":"g"}]}"#).unwrap();
    assert_eq!(told, orders::Told::default());
    assert!(!told.known);
}

/// An order this build does not know is not skipped: the core would wait on
/// a host that never does it and never says why.
#[test]
fn what_cannot_be_read_is_an_error_not_a_guess() {
    // Asked as "what was the error", so that reading it by mistake fails
    // the comparison below instead of stopping the test on an unwrap.
    let bad = |text: &str| orders::decode(text).err().unwrap_or_default();
    assert!(bad(r#"{"project_orders":[{"order":"paint","project":"p","group":null,"to":null,"terminal":null}]}"#).contains("paint"));
    assert!(bad(r#"{"project_orders":[{"order":"open","project":"p","group":null,"to":null}]}"#).contains("terminal is missing"));
    assert!(bad(r#"{"projects_known":"yes"}"#).contains("projects_known"));
    assert!(bad(r#"{"groups":[{"name":"g","project":{"tie":"bound","name":"p","pages":1,"open":true,"start":"later","why":"none"}}]}"#).contains("later"));
    assert!(bad(r#"{"groups":[{"name":"g","project":{"tie":"bound","name":"p","open":true,"start":"project","why":"none"}}]}"#).contains("pages is missing"));
}

fn have(name: &str, group: Option<&str>, terminals: &[&str]) -> Have {
    Have { name: name.into(), group: group.map(str::to_string), terminals: terms(terminals), open: !terminals.is_empty() }
}

fn any_terminal(_: &str) -> bool {
    true
}

#[test]
fn an_order_to_open_opens_what_is_closed_and_says_what_is_missing() {
    let o = order(Kind::Open, "web-app", Some("web-app"), None, None);
    assert_eq!(orders::step(&o, &[have("web-app", Some("web-app"), &[])], &any_terminal), Step::Open { project: "web-app".into() });
    // Seen again after it was done: nothing more.
    assert_eq!(orders::step(&o, &[have("web-app", Some("web-app"), &["0x1"])], &any_terminal), Step::Nothing("it is open"));
    assert_eq!(orders::step(&o, &[have("other", None, &[])], &any_terminal), Step::Missing { project: "web-app".into() });
}

#[test]
fn an_order_to_create_makes_a_project_of_the_supervisors_tab_once() {
    let o = order(Kind::Create, "nightly", Some("nightly"), None, Some("0xa1"));
    assert_eq!(orders::step(&o, &[], &any_terminal), Step::Create { name: "nightly".into(), group: Some("nightly".into()), terminal: "0xa1".into() });
    assert_eq!(orders::step(&o, &[have("nightly", Some("nightly"), &["0xa1"])], &any_terminal), Step::Nothing("a project of that name exists"));
    assert_eq!(orders::step(&o, &[have("other", None, &["0xa1"])], &any_terminal), Step::Nothing("its tab is already a page of a project"));
    assert_eq!(orders::step(&o, &[], &|_| false), Step::Nothing("that terminal is not open here"));
    assert_eq!(orders::step(&order(Kind::Create, "nightly", None, None, None), &[], &any_terminal), Step::Nothing("no terminal was named"));
}

#[test]
fn an_order_to_bind_gives_a_project_its_group_and_its_name() {
    let o = order(Kind::Bind, "scratch", Some("old"), Some("old"), Some("0xa1"));
    assert_eq!(
        orders::step(&o, &[have("scratch", None, &["0xa1"])], &any_terminal),
        Step::Bind { project: "scratch".into(), group: "old".into(), terminal: Some("0xa1".into()), to: Some("old".into()) }
    );
    // Called that already: bound, not renamed.
    let same = order(Kind::Bind, "old", Some("old"), Some("old"), Some("0xa1"));
    assert_eq!(orders::step(&same, &[have("old", None, &["0xa1"])], &any_terminal), Step::Bind { project: "old".into(), group: "old".into(), terminal: Some("0xa1".into()), to: None });
    assert_eq!(orders::step(&o, &[have("scratch", Some("old"), &["0xa1"])], &any_terminal), Step::Nothing("its file names that group already"));
    assert_eq!(orders::step(&o, &[have("scratch", None, &[]), have("old", None, &[])], &any_terminal), Step::Nothing("the name it would take is another project's"));
    assert_eq!(orders::step(&o, &[], &any_terminal), Step::Nothing("no such project"));
}

#[test]
fn an_order_to_set_the_group_writes_it_once() {
    let clear = order(Kind::SetGroup, "copy", None, None, None);
    assert_eq!(orders::step(&clear, &[have("copy", Some("web-app"), &[])], &any_terminal), Step::SetGroup { project: "copy".into(), group: None });
    assert_eq!(orders::step(&clear, &[have("copy", None, &[])], &any_terminal), Step::Nothing("its file says that already"));
    let set = order(Kind::SetGroup, "copy", Some("g"), None, None);
    assert_eq!(orders::step(&set, &[have("copy", None, &[])], &any_terminal), Step::SetGroup { project: "copy".into(), group: Some("g".into()) });
    assert_eq!(orders::step(&set, &[], &any_terminal), Step::Nothing("no such project"));
}

#[test]
fn an_order_to_rename_moves_the_file_once_and_never_onto_another() {
    let o = order(Kind::Rename, "web-app", None, Some("storefront"), None);
    assert_eq!(orders::step(&o, &[have("web-app", Some("storefront"), &[])], &any_terminal), Step::Rename { from: "web-app".into(), to: "storefront".into() });
    // Done: the old name is gone.
    assert_eq!(orders::step(&o, &[have("storefront", Some("storefront"), &[])], &any_terminal), Step::Nothing("no such project"));
    assert_eq!(orders::step(&o, &[have("web-app", None, &[]), have("storefront", None, &[])], &any_terminal), Step::Nothing("that name is another project's"));
    assert_eq!(orders::step(&order(Kind::Rename, "web-app", None, Some("web-app"), None), &[have("web-app", None, &[])], &any_terminal), Step::Nothing("it is called that already"));
}

#[test]
fn an_order_to_add_a_tab_adds_it_once() {
    let o = order(Kind::AddTab, "web-app", None, None, Some("0xb9"));
    assert_eq!(orders::step(&o, &[have("web-app", None, &["0xa1"])], &any_terminal), Step::AddTab { project: "web-app".into(), terminal: "0xb9".into() });
    assert_eq!(orders::step(&o, &[have("web-app", None, &["0xa1", "0xb9"])], &any_terminal), Step::Nothing("its tab is already a page of a project"));
    assert_eq!(orders::step(&o, &[have("web-app", None, &[]), have("notes", None, &["0xb9"])], &any_terminal), Step::Nothing("its tab is already a page of a project"));
    assert_eq!(orders::step(&o, &[have("web-app", None, &["0xa1"])], &|_| false), Step::Nothing("that terminal is not open here"));
    assert_eq!(orders::step(&o, &[], &any_terminal), Step::Nothing("no such project"));
}

/// Marking a pane the supervisor's unmarks the one that was, and a save
/// that cannot tell who is in a pane keeps the mark.
#[test]
fn one_pane_of_a_project_is_its_supervisors() {
    let supervisors = |pages: &Pages| -> Vec<String> {
        pages
            .file_windows()
            .iter()
            .flat_map(|w| w.tabs.iter())
            .flat_map(|t| polter_projectfile::leaves(&t.root))
            .filter(|l| matches!(&l.agent, Agent::Agent(who) if who.supervisor))
            .map(|l| l.scrollback.clone())
            .collect()
    };
    let mut pages = tied();
    assert_eq!(supervisors(&pages), ["0.snap"]);
    // A pane nobody was written down for: it is an agent's now, of whom
    // nothing else is known. The one that was is still who it was.
    assert!(pages.mark_supervisor("2.snap"));
    assert_eq!(supervisors(&pages), ["2.snap"]);
    let was = pages.known();
    assert_eq!(was["0.snap"].agent, Agent::Agent(Who { role: "polter-supervisor".into(), cli: "claude-code".into(), session: "s".into(), supervisor: false }));
    assert_eq!(was["2.snap"].agent, Agent::Agent(Who { role: String::new(), cli: String::new(), session: String::new(), supervisor: true }));
    // A worker's pane keeps who the worker is.
    assert!(pages.mark_supervisor("1.snap"));
    assert_eq!(pages.known()["1.snap"].agent, Agent::Agent(Who { role: "polter-dev".into(), cli: "codex".into(), session: "s".into(), supervisor: true }));
    assert_eq!(supervisors(&pages), ["1.snap"]);
    // No such pane: nothing changes, and the one marked stays marked.
    assert!(!pages.mark_supervisor("9.snap"));
    assert!(!pages.mark_supervisor(""));
    assert_eq!(supervisors(&pages), ["1.snap"]);

    // A pane that has no name yet is not "the pane called nothing": asked
    // for that, nothing is marked -- and the one that was stays.
    let mut unnamed = Pages::from_file(&one_tab(split(leaf_of("/a", "", worker()), leaf_of("/b", "1.snap", chief()), Axis::Horizontal), 2));
    assert!(!unnamed.mark_supervisor(""));
    assert_eq!(supervisors(&unnamed), ["1.snap"]);

    // The next save sees the tab and cannot say who is in its panes.
    let unknown = split(leaf_of("/a", "0.snap", Agent::Unknown), leaf_of("/b", "1.snap", Agent::Unknown), Axis::Horizontal);
    let screen = Screen { live: vec![Live { id: 0, window: 1, index: 0, selected: true, root: unknown }], frames: BTreeMap::new(), keeping_front: false };
    let (after, _) = pages.saving("web-app", 2, None, Some(3), &screen);
    assert_eq!(supervisors(&after), ["1.snap"]);
}

// ---- the interface's rules about pages (ProjectPageRulesTests, case for case)

use crate::page_rules::{self as rules, CloseChoice, CloseScope, CloseStep, Item, Note, Row, SaveOver};

fn three_tabs() -> Vec<rules::Tab> {
    vec![
        rules::Tab { id: 1, title: "polter".into(), panes: 2, project: None, is_current: false },
        rules::Tab { id: 2, title: "web-app".into(), panes: 3, project: None, is_current: true },
        rules::Tab { id: 3, title: "argus-site".into(), panes: 1, project: Some("argus".into()), is_current: false },
    ]
}

fn set(of: &[u64]) -> BTreeSet<u64> {
    of.iter().copied().collect()
}

#[test]
fn save_as_lists_every_tab_and_only_the_current_one_is_checked() {
    let tabs = three_tabs();
    assert_eq!(
        rules::save_as_rows(&tabs),
        [
            Row { id: 1, title: "polter".into(), note: Note::Panes(2), can_check: true },
            Row { id: 2, title: "web-app".into(), note: Note::ThisPage, can_check: true },
            Row { id: 3, title: "argus-site".into(), note: Note::InProject("argus".into()), can_check: false },
        ]
    );
    assert_eq!(rules::initially_checked(&tabs), set(&[2]));
    assert_eq!(rules::note_words(&Note::Panes(2)).filled("{} pane(s)"), "2 pane(s)");
    assert_eq!(rules::note_words(&Note::InProject("argus".into())).filled("已在项目 {} 里"), "已在项目 argus 里");
}

#[test]
fn a_current_tab_that_is_already_a_page_is_not_offered() {
    let own = [
        rules::Tab { id: 1, title: "a".into(), panes: 1, project: None, is_current: false },
        rules::Tab { id: 2, title: "b".into(), panes: 1, project: Some("p".into()), is_current: true },
    ];
    assert_eq!(rules::initially_checked(&own), set(&[]));
    assert_eq!(rules::save_as_rows(&own)[1], Row { id: 2, title: "b".into(), note: Note::InProject("p".into()), can_check: false });
}

#[test]
fn saving_needs_a_name_and_a_tab_that_can_be_taken() {
    let rows = rules::save_as_rows(&three_tabs());
    assert!(rules::can_save("new", &set(&[2]), &rows));
    assert!(!rules::can_save("   ", &set(&[2]), &rows));
    assert!(!rules::can_save("new", &set(&[]), &rows));
    // A check on a row that cannot be checked is not a way round the rule.
    assert!(!rules::can_save("new", &set(&[3]), &rows));
    assert_eq!(rules::tabs_to_save(&set(&[3, 2, 1]), &rows), [1, 2]);
}

#[test]
fn the_menu_says_which_project_and_offers_what_fits() {
    assert_eq!(rules::menu_header(Some("polter")).filled("This page is in the project \"{}\""), "This page is in the project \"polter\"");
    assert_ne!(rules::menu_header(None), rules::menu_header(Some("polter")));
    assert_eq!(rules::take_out_title(Some("polter")).args, ["polter"]);
    assert_ne!(rules::take_out_title(None).msgid, rules::take_out_title(Some("polter")).msgid);

    let in_one: Vec<Item> = Item::ALL.into_iter().filter(|i| rules::offered(*i, Some("polter"))).collect();
    assert_eq!(in_one, [Item::SaveAs, Item::Open, Item::Manage, Item::Rename, Item::TakeOut, Item::CloseProject]);
    let in_none: Vec<Item> = Item::ALL.into_iter().filter(|i| rules::offered(*i, None)).collect();
    assert_eq!(in_none, [Item::SaveAs, Item::Open, Item::Manage, Item::AddTo]);
}

#[test]
fn closing_a_page_asks_only_where_the_answer_could_be_wanted() {
    let step = |project: Option<&str>, others: usize, scope: CloseScope, choice: CloseChoice| rules::close_step(project, others, scope, choice);
    let stays = CloseStep::Close { taking_out: false };
    assert_eq!(step(Some("p"), 2, CloseScope::Tab, CloseChoice::Ask), CloseStep::Ask);
    assert_eq!(step(None, 2, CloseScope::Tab, CloseChoice::Ask), stays);
    // The project's last open page: that is the project being closed.
    assert_eq!(step(Some("p"), 0, CloseScope::Tab, CloseChoice::Ask), stays);
    for scope in CloseScope::ALL.into_iter().filter(|s| *s != CloseScope::Tab) {
        for choice in CloseChoice::ALL {
            assert_eq!(step(Some("p"), 2, scope, choice), stays, "{scope:?} {choice:?}");
        }
    }
    assert_eq!(step(Some("p"), 2, CloseScope::Tab, CloseChoice::Keep), stays);
    assert_eq!(step(Some("p"), 2, CloseScope::Tab, CloseChoice::TakeOut), CloseStep::Close { taking_out: true });
    // A standing "take it out" takes nothing out of no project, and does
    // not thin a project that is being closed.
    assert_eq!(step(None, 2, CloseScope::Tab, CloseChoice::TakeOut), stays);
    assert_eq!(step(Some("p"), 0, CloseScope::Tab, CloseChoice::TakeOut), stays);
}

#[test]
fn the_answer_is_remembered_only_when_asked_to() {
    assert_eq!(rules::choice_after(true, false, CloseChoice::Ask), CloseChoice::Ask);
    assert_eq!(rules::choice_after(true, true, CloseChoice::Ask), CloseChoice::TakeOut);
    assert_eq!(rules::choice_after(false, true, CloseChoice::Ask), CloseChoice::Keep);
    for choice in CloseChoice::ALL {
        assert_eq!(CloseChoice::from_stored(choice.stored()), choice);
    }
    // The macOS host's own words for them, so a setting means the same.
    assert_eq!(CloseChoice::ALL.map(CloseChoice::stored), ["ask", "keep", "takeOut"]);
    assert_eq!(CloseChoice::from_stored(""), CloseChoice::Ask);
    assert_eq!(CloseChoice::from_stored("later"), CloseChoice::Ask);
    let said: BTreeSet<&str> = CloseChoice::ALL.into_iter().map(CloseChoice::msgid).collect();
    assert_eq!(said.len(), 3);
}

#[test]
fn a_project_is_counted_whole() {
    assert_eq!(rules::size(3, 4).filled("{} 页 · {} 格"), "3 页 · 4 格");
}

/// Saving over a name: the three refusals of the macOS host's
/// `ProjectSession.save`, and the two things it does otherwise.
#[test]
fn saving_over_a_project_never_writes_under_tabs_that_would_write_back() {
    let free = |t: u64| (t, None);
    let of = |t: u64, p: &str| (t, Some(p.to_string()));
    // Not open: it becomes these tabs.
    assert_eq!(rules::save_over("p", &[], &[free(1), free(2)]), SaveOver::Replace);
    // A chosen tab is another project's page.
    assert_eq!(rules::save_over("p", &[], &[free(1), of(2, "q")]), SaveOver::PageOfAnother { tab: 2, project: "q".into() });
    // Open in exactly these tabs: saved again by hand.
    assert_eq!(rules::save_over("p", &[1, 2], &[of(2, "p"), of(1, "p")]), SaveOver::Again);
    // Open in a tab that was not chosen: that tab would write itself back.
    assert_eq!(rules::save_over("p", &[1, 2], &[of(1, "p")]), SaveOver::OpenElsewhere);
    // Open, and a tab that is not its page was chosen too.
    assert_eq!(rules::save_over("p", &[1], &[of(1, "p"), free(3)]), SaveOver::OpenElsewhere);
    assert_eq!(rules::save_over("p", &[1], &[free(3)]), SaveOver::OpenElsewhere);
}

#[test]
fn the_start_button_says_how_many_pages_come_back_when_that_is_known() {
    assert_eq!(rules::start_in_project_words(Some(3)).args, ["3"]);
    assert!(rules::start_in_project_words(Some(3)).msgid.starts_with("All {} page(s)"));
    // Not known is not "0 pages".
    assert!(rules::start_in_project_words(None).args.is_empty());
    assert!(rules::start_in_project_words(None).msgid.starts_with("Every page"));
}

/// **What this crate writes is what the core reads**: the lines of this
/// file are fed to the core by its own test (`ControlAct.zig`, "the core
/// takes what the Windows host writes"), and are these bytes here.
#[test]
fn what_is_said_is_the_bytes_the_core_is_tested_on() {
    let file = include_str!("../../../src/poltergeist/testdata/host_project_acts.jsonl");
    let lines: Vec<&str> = file.lines().collect();
    let id = |n: u64| format!("0x{n:016x}");
    let list = [
        Stated {
            name: "web-app".into(),
            group: Some("web-app".into()),
            pages: 3,
            open: Some(vec![vec![id(0xa1), id(0xb1)], vec![id(0xb2)]]),
            supervisor: Some(id(0xa1)),
            workers: vec![id(0xb1), id(0xb2)],
        },
        Stated { name: "notes".into(), group: None, pages: 1, open: None, supervisor: None, workers: Vec::new() },
    ];
    assert_eq!(stated::refusal(&list), None);
    assert_eq!(
        lines,
        [
            stated::statement(&list),
            stated::statement(&[]),
            stated::failed("web-app", FailedWhy::NotFound),
            stated::failed("web-app", FailedWhy::Unreadable),
            stated::remove_question(&id(0xb2)),
            stated::rename_question("notes", "scratch"),
        ]
    );
}

/// **The first save after a project opens does not take its marks off it**
/// (task 1700; `pane-color-interface.md` §7.2). The panes are open, the core
/// has not taken their colours, shields and refusals back yet, and the host
/// says it cannot tell -- so what is written is what the file had.
#[test]
fn a_save_before_the_marks_are_taken_back_writes_what_the_file_had() {
    let file = one_tab(
        split(
            marked("/a", "0.snap", Some(true), Some(PaneColor::Orange), Some(Workers::Allowed), Some(false)),
            marked("/b", "1.snap", Some(false), Some(PaneColor::Teal), Some(Workers::Refused), Some(true)),
            Axis::Horizontal,
        ),
        2,
    );
    let pages = Pages::from_file(&file);
    let not_yet = split(marked("/a", "0.snap", None, None, None, None), marked("/b", "1.snap", None, None, None, None), Axis::Horizontal);
    let screen = Screen { live: vec![Live { id: 0, window: 1, index: 0, selected: true, root: not_yet }], frames: BTreeMap::new(), keeping_front: false };
    let (_, written) = pages.saving("p", 2, None, Some(2), &screen);
    assert_eq!(written.windows[0].tabs[0].root, file.windows[0].tabs[0].root);
    // And it is the bytes: the file says the marks it said.
    let bytes = emit(&written).unwrap();
    for want in [r#""supervisor_seat":true,"color":"orange""#, r#""color":"teal","workers":"refused","shielded":true"#] {
        assert!(bytes.contains(want), "{want} not in {bytes}");
    }

    // Told, what it was told is what is written -- the defaults included.
    let told = split(
        marked("/a", "0.snap", None, Some(PaneColor::None), Some(Workers::Allowed), Some(false)),
        marked("/b", "1.snap", None, Some(PaneColor::Pink), Some(Workers::Allowed), Some(false)),
        Axis::Horizontal,
    );
    let screen = Screen { live: vec![Live { id: 0, window: 1, index: 0, selected: true, root: told }], frames: BTreeMap::new(), keeping_front: false };
    let (_, written) = pages.saving("p", 3, None, Some(2), &screen);
    let got: Vec<(Option<PaneColor>, Option<Workers>, Option<bool>)> =
        polter_projectfile::leaves(&written.windows[0].tabs[0].root).iter().map(|l| (l.color, l.workers, l.shielded)).collect();
    assert_eq!(got, vec![(Some(PaneColor::None), Some(Workers::Allowed), Some(false)), (Some(PaneColor::Pink), Some(Workers::Allowed), Some(false))]);
}

/// The seat stays where the file had it while no supervisor is on screen,
/// and moves -- leaving no second seat behind -- when one is.
#[test]
fn the_seat_moves_to_where_the_supervisor_is_and_stays_put_while_there_is_none() {
    let file = one_tab(split(marked("/a", "0.snap", Some(true), Some(PaneColor::None), None, None), leaf("/b", "1.snap"), Axis::Horizontal), 2);
    let pages = Pages::from_file(&file);
    let seats = |root: SavedNode| -> Vec<Option<bool>> {
        let screen = Screen { live: vec![Live { id: 0, window: 1, index: 0, selected: true, root }], frames: BTreeMap::new(), keeping_front: false };
        let (_, written) = pages.saving("p", 2, None, Some(2), &screen);
        polter_projectfile::leaves(&written.windows[0].tabs[0].root).iter().map(|l| l.supervisor_seat).collect()
    };
    let nobody = |cwd: &str, snap: &str| marked(cwd, snap, None, Some(PaneColor::None), Some(Workers::Allowed), Some(false));
    let here = |cwd: &str, snap: &str| marked(cwd, snap, Some(true), Some(PaneColor::None), Some(Workers::Allowed), Some(false));
    assert_eq!(seats(split(nobody("/a", "0.snap"), nobody("/b", "1.snap"), Axis::Horizontal)), vec![Some(true), Some(false)], "no supervisor: the file's seat");
    assert_eq!(seats(split(nobody("/a", "0.snap"), here("/b", "1.snap"), Axis::Horizontal)), vec![Some(false), Some(true)], "it moved");
    assert_eq!(seats(split(here("/a", "0.snap"), nobody("/b", "1.snap"), Axis::Horizontal)), vec![Some(true), Some(false)], "where it was");
}
