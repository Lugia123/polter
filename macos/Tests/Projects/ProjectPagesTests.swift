import Testing
import Foundation
@testable import Ghostty

/// What a project is while the app has it in hand: which tab is which page,
/// and what a save makes of the tabs that are open and the pages that are
/// not (`ProjectPages`). No window and no terminal is needed for any of it.
@Suite
struct ProjectPagesTests {
    private typealias Live = ProjectPages.Live

    private func leaf(_ cwd: String, _ scrollback: String = "", _ agent: ProjectAgent = .none) -> ProjectNode {
        .leaf(cwd: cwd, title: "", history: "", scrollback: scrollback, bySupervisor: false, agent: agent)
    }

    private func frame(_ x: Double) -> ProjectFrame {
        ProjectFrame(origin: .bottomLeft, x: x, y: 0, width: 800, height: 600)
    }

    /// Two windows: three pages (ids 0, 1, 2; the second in front), and one
    /// page (id 3).
    private var project: ProjectPages {
        ProjectPages(file: ProjectFile(
            name: "p", savedAt: 1, group: "g",
            windows: [
                ProjectWindow(frame: frame(10), front: 1, tabs: [
                    ProjectTab(root: leaf("/a", "0.snap")),
                    ProjectTab(root: leaf("/b", "1.snap")),
                    ProjectTab(root: leaf("/c", "2.snap")),
                ]),
                ProjectWindow(frame: frame(20), front: 0, tabs: [ProjectTab(root: leaf("/d", "3.snap"))]),
            ],
            nextScrollback: 4))
    }

    /// The directories of each window's pages, in order: enough to say
    /// which page is where.
    private func cwds(_ pages: ProjectPages) -> [[String]] {
        pages.fileWindows.map { window in
            window.tabs.map { tab -> String in
                if case .leaf(let cwd, _, _, _, _, _) = tab.root { return cwd }
                return "split"
            }
        }
    }

    private func live(_ id: Int, window: Int, index: Int, selected: Bool = false, _ cwd: String) -> Live {
        Live(id: id, window: window, index: index, selected: selected, root: leaf(cwd))
    }

    // MARK: Reading

    @Test func theFilesPagesComeBackAsTheFilesPages() {
        let file = ProjectFile(
            name: "p", savedAt: 1, group: nil,
            windows: [
                ProjectWindow(frame: frame(10), front: 1, tabs: [ProjectTab(root: leaf("/a")), ProjectTab(root: leaf("/b"))]),
                ProjectWindow(frame: nil, front: 0, tabs: [ProjectTab(root: leaf("/c"))]),
            ],
            nextScrollback: nil)
        let pages = ProjectPages(file: file)
        #expect(pages.fileWindows == file.windows)
        #expect(pages.pageIDs == [0, 1, 2])
        // Nothing open and nothing changed: a save leaves it as it is.
        #expect(pages.updated(live: [], frames: [:], keepingFront: false) == pages)
    }

    // MARK: A save

    /// **A page that is not open stays in the project**, with what it was
    /// last saved as, in its place.
    @Test func aPageThatIsNotOpenStaysWhereItWas() {
        // Only the first and the third page of the first window are open.
        let now = project.updated(
            live: [live(0, window: 7, index: 0, "/a2"), live(2, window: 7, index: 1, selected: true, "/c2")],
            frames: [7: frame(99)], keepingFront: false)
        #expect(cwds(now) == [["/a2", "/b", "/c2"], ["/d"]])
        // The window that is on screen has the frame it has now; the one
        // that is not keeps the frame it had.
        #expect(now.fileWindows.map(\.frame) == [frame(99), frame(20)])
        // The tab showing is in front.
        #expect(now.fileWindows[0].front == 2)
        #expect(now.fileWindows[1].front == 0)
    }

    @Test func aClosedPageFollowsThePageItFollowedAndIsFirstWhenItFollowedNone() {
        // The first page is closed, the other two have swapped places.
        let swapped = project.updated(
            live: [live(2, window: 7, index: 0, "/c"), live(1, window: 7, index: 1, "/b")], frames: [:], keepingFront: false)
        #expect(cwds(swapped) == [["/a", "/c", "/b"], ["/d"]])
        // The middle page is closed: it stays after the first, wherever
        // the first has gone.
        let moved = project.updated(
            live: [live(2, window: 7, index: 0, "/c"), live(0, window: 7, index: 1, "/a")], frames: [:], keepingFront: false)
        #expect(cwds(moved) == [["/c", "/a", "/b"], ["/d"]])
    }

    /// The order of the pages is the order of the tabs, whatever tabs of
    /// other things stand between them.
    @Test func openPagesAreInTheOrderOfTheTabs() {
        let now = project.updated(
            live: [
                live(0, window: 7, index: 9, "/a"), live(1, window: 7, index: 2, "/b"), live(2, window: 7, index: 5, "/c"),
                live(3, window: 8, index: 0, "/d"),
            ],
            frames: [:], keepingFront: false)
        #expect(cwds(now) == [["/b", "/c", "/a"], ["/d"]])
    }

    /// The page in front is the tab showing when that is one of the
    /// project's; when the tab showing is something else, it is the page
    /// that was in front.
    @Test func thePageInFrontIsTheTabShowingOrStaysWhatItWas() {
        let all = [live(0, window: 7, index: 0, "/a"), live(1, window: 7, index: 1, "/b"), live(2, window: 7, index: 2, "/c")]
        #expect(project.updated(live: all, frames: [:], keepingFront: false).fileWindows[0].front == 1)
        let third = [all[0], all[1], live(2, window: 7, index: 2, selected: true, "/c")]
        #expect(project.updated(live: third, frames: [:], keepingFront: false).fileWindows[0].front == 2)
        // The page that was in front was dragged away: the first is.
        let dragged = [all[0], live(1, window: 9, index: 0, "/b"), all[2]]
        let now = project.updated(live: dragged, frames: [:], keepingFront: false)
        #expect(cwds(now) == [["/a", "/c"], ["/d"], ["/b"]])
        #expect(now.fileWindows[0].front == 0)
    }

    /// **A window closing does not make its last tab the page in front.**
    /// Its tabs close one after another, and the system shows each of the
    /// ones left in turn; each closing tab's save keeps what was in front.
    @Test func aClosingTabsSaveKeepsThePageThatWasInFront() {
        // The page in front (id 1) has closed already; the system now shows
        // the third, which is closing next.
        let left = [live(0, window: 7, index: 0, "/a"), live(2, window: 7, index: 1, selected: true, "/c")]
        let closing = project.updated(live: left, frames: [:], keepingFront: true)
        #expect(cwds(closing) == [["/a", "/b", "/c"], ["/d"]])
        #expect(closing.fileWindows[0].front == 1)
        // The same tabs in a save that is nobody closing: the tab showing
        // is the page in front.
        #expect(project.updated(live: left, frames: [:], keepingFront: false).fileWindows[0].front == 2)
    }

    /// A tab dragged to another window is a page of that window; dragged
    /// out on its own, it is a window more.
    @Test func aPageDraggedToAnotherWindowIsInThatWindow() {
        let intoTheOther = project.updated(
            live: [
                live(0, window: 7, index: 0, "/a"), live(1, window: 7, index: 1, "/b"),
                live(3, window: 8, index: 0, "/d"), live(2, window: 8, index: 1, "/c"),
            ],
            frames: [7: frame(1), 8: frame(2)], keepingFront: false)
        #expect(cwds(intoTheOther) == [["/a", "/b"], ["/d", "/c"]])
        #expect(intoTheOther.fileWindows.map(\.frame) == [frame(1), frame(2)])

        let onItsOwn = project.updated(
            live: [
                live(0, window: 7, index: 0, "/a"), live(1, window: 7, index: 1, "/b"),
                live(2, window: 9, index: 0, "/c"), live(3, window: 8, index: 0, "/d"),
            ],
            frames: [7: frame(1), 8: frame(2), 9: frame(3)], keepingFront: false)
        #expect(cwds(onItsOwn) == [["/a", "/b"], ["/d"], ["/c"]])
        #expect(onItsOwn.fileWindows.map(\.frame) == [frame(1), frame(2), frame(3)])
    }

    /// Two windows of the project put together into one on screen are one
    /// window of the file -- unless the second still has a page that is not
    /// open, which stays in a window of its own.
    @Test func twoWindowsMadeOneAreOne() {
        let merged = project.updated(
            live: [
                live(0, window: 7, index: 0, "/a"), live(1, window: 7, index: 1, "/b"),
                live(2, window: 7, index: 2, "/c"), live(3, window: 7, index: 3, "/d"),
            ],
            frames: [7: frame(1)], keepingFront: false)
        #expect(cwds(merged) == [["/a", "/b", "/c", "/d"]])
    }

    /// A window of the file goes on as the window on screen most of its
    /// open pages are in, not as the one its first page went to.
    @Test func aWindowGoesOnAsTheWindowMostOfItsPagesAreIn() {
        // The first page was dragged out; the other two stayed.
        let now = project.updated(
            live: [
                live(0, window: 9, index: 0, "/a"), live(1, window: 7, index: 0, "/b"),
                live(2, window: 7, index: 1, "/c"), live(3, window: 8, index: 0, "/d"),
            ],
            frames: [7: frame(1), 8: frame(2), 9: frame(3)], keepingFront: false)
        #expect(cwds(now) == [["/b", "/c"], ["/d"], ["/a"]])
        #expect(now.fileWindows.map(\.frame) == [frame(1), frame(2), frame(3)])
    }

    /// The windows keep their order, whichever is in front on screen.
    @Test func theOrderOfTheWindowsDoesNotFollowTheScreen() {
        let all = [
            live(3, window: 1, index: 0, selected: true, "/d"),
            live(0, window: 2, index: 0, "/a"), live(1, window: 2, index: 1, "/b"), live(2, window: 2, index: 2, "/c"),
        ]
        #expect(cwds(project.updated(live: all, frames: [:], keepingFront: false)) == [["/a", "/b", "/c"], ["/d"]])
    }

    @Test func aNewPageIsAPageOfTheWindowItsTabIsIn() {
        var pages = project
        let id = pages.newPageID()
        #expect(id == 4)
        let now = pages.updated(
            live: [live(1, window: 7, index: 0, "/b"), live(id, window: 7, index: 1, "/new")], frames: [:], keepingFront: false)
        // The page that is not open keeps its place after the one it
        // followed; the new tab is where its tab is, after that.
        #expect(cwds(now) == [["/a", "/b", "/c", "/new"], ["/d"]])
        // And an id is not given twice.
        #expect(pages.newPageID() == 5)
    }

    // MARK: Taking a page out

    @Test func takingAPageOutLeavesTheRest() {
        var pages = project
        pages.remove(1)
        #expect(cwds(pages) == [["/a", "/c"], ["/d"]])
        // It was the page in front: the first that is left is.
        #expect(pages.fileWindows[0].front == 0)
        #expect(pages.scrollbackFilenames == ["0.snap", "2.snap", "3.snap"])
        // A window's only page takes the window with it.
        pages.remove(3)
        #expect(cwds(pages) == [["/a", "/c"]])
    }

    // MARK: Across a restart

    /// A tab that comes back finds its page by what its panes are called,
    /// not by where it stood.
    @Test func aRestoredTabFindsItsPageByItsPanesSnapshotNames() {
        let pages = project
        #expect(pages.page(sharing: ["2.snap"], excluding: []) == 2)
        // One pane is enough: the other was split off since the last save.
        #expect(pages.page(sharing: ["", "3.snap"], excluding: []) == 3)
        // **The file decides.** A tab none of whose panes the file has is
        // in no project, whatever it says -- and so is a tab with no name
        // to go by.
        #expect(pages.page(sharing: ["9.snap"], excluding: []) == nil)
        #expect(pages.page(sharing: [], excluding: []) == nil)
        #expect(pages.page(sharing: [""], excluding: []) == nil)
        // A page is one tab's: a second that claims it does not get it.
        #expect(pages.page(sharing: ["2.snap"], excluding: [2]) == nil)
    }

    // MARK: What a save cannot tell

    private let worker = ProjectAgent.agent(role: "polter-dev", cli: "codex", session: "s", supervisor: false)

    /// **Not known does not overwrite what the file knew**; an answer does.
    @Test func aPaneNobodyCanTellAboutKeepsWhatTheFileSaidOfIt() {
        let pages = ProjectPages(file: .oneTab(
            name: "p", savedAt: 1,
            root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a", "0.snap", worker), right: leaf("/b", "1.snap", .none)),
            nextScrollback: 2))
        let known = pages.known
        #expect(known == [
            "0.snap": ProjectPages.Known(cwd: "/a", agent: worker, bySupervisor: false),
            "1.snap": ProjectPages.Known(cwd: "/b", agent: .none, bySupervisor: false),
        ])

        // The save cannot tell about either pane.
        let asked = ProjectNode.split(
            direction: .horizontal, ratio: 0.5,
            left: leaf("/a", "0.snap", .unknown), right: leaf("/b", "1.snap", .unknown))
        #expect(asked.keepingWhatTheFileKnew(known) == .split(
            direction: .horizontal, ratio: 0.5,
            left: leaf("/a", "0.snap", worker), right: leaf("/b", "1.snap", .none)))

        // It can: what it says is what is written, even "nobody" over an
        // agent.
        #expect(leaf("/a", "0.snap", .none).keepingWhatTheFileKnew(known) == leaf("/a", "0.snap", .none))
        // A pane the file never had, and one with no name to match by, stay
        // not known.
        #expect(leaf("/c", "7.snap", .unknown).keepingWhatTheFileKnew(known) == leaf("/c", "7.snap", .unknown))
        #expect(leaf("/c", "", .unknown).keepingWhatTheFileKnew(known) == leaf("/c", "", .unknown))
    }

    /// A pane's own things go with the pane, by its name, whichever page
    /// it is on now.
    @Test func whatTheFileKnewOfAPaneIsFoundWhereverThePaneIs() {
        // In the file the worker's pane is on the second page.
        let file = ProjectFile(
            name: "p", savedAt: 1, group: nil,
            windows: [ProjectWindow(frame: nil, front: 0, tabs: [
                ProjectTab(root: leaf("/a", "0.snap", .none)), ProjectTab(root: leaf("/b", "1.snap", worker)),
            ])],
            nextScrollback: 2)
        let known = ProjectPages(file: file).known
        #expect(leaf("/b", "1.snap", .unknown).keepingWhatTheFileKnew(known) == leaf("/b", "1.snap", worker))
    }

    /// A pane the supervisor opened stays one: a save that cannot tell --
    /// every save after a restart -- does not make it a pane the supervisor
    /// did not open. And a save that can tell says so.
    @Test func aPaneTheSupervisorOpenedStaysOne() {
        let opened = ProjectNode.leaf(cwd: "/w", title: "", history: "", scrollback: "0.snap", bySupervisor: true, agent: .none)
        let known = ProjectPages(file: .oneTab(name: "p", savedAt: 1, root: opened, nextScrollback: 1)).known
        #expect(known["0.snap"]?.bySupervisor == true)
        #expect(leaf("/w", "0.snap", .none).keepingWhatTheFileKnew(known) == opened)
        // A pane the file did not mark, which the save says the supervisor
        // opened: it is marked.
        let plain = ProjectPages(file: .oneTab(name: "p", savedAt: 1, root: leaf("/w", "0.snap", .none), nextScrollback: 1)).known
        #expect(opened.keepingWhatTheFileKnew(plain) == opened)
        #expect(leaf("/w", "0.snap", .none).keepingWhatTheFileKnew(plain) == leaf("/w", "0.snap", .none))
    }

    /// **A project just opened does not lose its directories.** A pane has
    /// none to report until its shell says one; the save that follows
    /// opening by a second or two finds every pane with none.
    @Test func aPaneThatCannotSayWhereItIsYetKeepsTheDirectoryItWasOpenedIn() {
        let known = ProjectPages(file: .oneTab(
            name: "p", savedAt: 1, root: leaf("/work/repo", "0.snap", .none), nextScrollback: 1)).known
        #expect(leaf("", "0.snap", .none).keepingWhatTheFileKnew(known) == leaf("/work/repo", "0.snap", .none))
        // Once it has said one, that is the one.
        #expect(leaf("/elsewhere", "0.snap", .none).keepingWhatTheFileKnew(known) == leaf("/elsewhere", "0.snap", .none))
    }

    /// A whole save, as the store makes one: two tabs open of four pages,
    /// one of them just opened and able to say nothing of itself.
    @Test func aSaveWritesTheOpenTabsAsTheyAreAndTheRestAsTheyWere() throws {
        let file = ProjectFile(
            name: "p", savedAt: 1, group: "g",
            windows: [
                ProjectWindow(frame: frame(10), front: 0, tabs: [
                    ProjectTab(root: leaf("/a", "0.snap", worker)),
                    ProjectTab(root: leaf("/b", "1.snap", .none)),
                ]),
                ProjectWindow(frame: frame(20), front: 0, tabs: [ProjectTab(root: leaf("/d", "3.snap", worker))]),
            ],
            nextScrollback: 4)
        let pages = ProjectPages(file: file)
        let (after, written) = pages.saving(
            name: "p", savedAt: 9, group: "g", nextScrollback: 5,
            screen: .init(live: [
                // Just opened: no directory yet, and nobody can say who.
                Live(id: 0, window: 7, index: 0, selected: false, root: leaf("", "0.snap", .unknown)),
                // A split made since, in the second page.
                Live(id: 1, window: 7, index: 1, selected: true, root: .split(
                    direction: .vertical, ratio: 0.5, left: leaf("/b2", "1.snap", .unknown), right: leaf("/new", "4.snap", .unknown))),
            ], frames: [7: frame(77)], keepingFront: false))

        #expect(written == ProjectFile(
            name: "p", savedAt: 9, group: "g",
            windows: [
                ProjectWindow(frame: frame(77), front: 1, tabs: [
                    ProjectTab(root: leaf("/a", "0.snap", worker)),
                    ProjectTab(root: .split(
                        direction: .vertical, ratio: 0.5, left: leaf("/b2", "1.snap", .none), right: leaf("/new", "4.snap", .unknown))),
                ]),
                // Not open: exactly as it was.
                ProjectWindow(frame: frame(20), front: 0, tabs: [ProjectTab(root: leaf("/d", "3.snap", worker))]),
            ],
            nextScrollback: 5))
        #expect(after.fileWindows == written.windows)
        // What is written is a file all three implementations read back.
        #expect(try ProjectFile.decode(from: written.encoded()) == written)
        // And the next save starts from it: nothing changed, nothing to do.
        let (again, _) = after.saving(
            name: "p", savedAt: 10, group: "g", nextScrollback: 5,
            screen: .init(live: [], frames: [:], keepingFront: false))
        #expect(again == after)
    }

    // MARK: Where a window opens

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    private func stored(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ProjectFrame {
        ProjectFrame(origin: .bottomLeft, x: x, y: y, width: w, height: h)
    }

    @Test func aFrameOnAScreenThatIsThereIsLeftAlone() {
        #expect(ProjectPlacement.frame(stored(100, 50, 800, 600), screens: [screen]) == CGRect(x: 100, y: 50, width: 800, height: 600))
        #expect(ProjectPlacement.frame(stored(1500, 40, 1800, 1000), screens: [screen, second]) == CGRect(x: 1500, y: 40, width: 1800, height: 1000))
    }

    /// The second screen is gone: the window comes back onto the one that
    /// is left, whole, and no bigger than it.
    @Test func aFrameOffEveryScreenIsBroughtBackOntoOne() {
        // Was on the second screen, which is not there now.
        #expect(ProjectPlacement.frame(stored(1500, 40, 800, 600), screens: [screen]) == CGRect(x: 640, y: 40, width: 800, height: 600))
        // Bigger than the screen that is left.
        #expect(ProjectPlacement.frame(stored(1500, 40, 1800, 1000), screens: [screen]) == screen)
        // Hanging off the left and the bottom.
        #expect(ProjectPlacement.frame(stored(-300, -200, 800, 600), screens: [screen]) == CGRect(x: 0, y: 0, width: 800, height: 600))
        // Across two screens: onto the one that holds more of it.
        #expect(ProjectPlacement.frame(stored(1300, 100, 800, 600), screens: [screen, second]) == CGRect(x: 1440, y: 100, width: 800, height: 600))
        #expect(ProjectPlacement.frame(stored(900, 100, 800, 600), screens: [screen, second]) == CGRect(x: 640, y: 100, width: 800, height: 600))
    }

    @Test func aFrameThatIsNotAPlaceHereIsNoFrame() {
        // Nothing recorded: every window of a format 1 file.
        #expect(ProjectPlacement.frame(nil, screens: [screen]) == nil)
        // Measured from the other corner, on Windows.
        #expect(ProjectPlacement.frame(ProjectFrame(origin: .topLeft, x: 100, y: 50, width: 800, height: 600), screens: [screen]) == nil)
        // Not a rectangle.
        #expect(ProjectPlacement.frame(stored(100, 50, 0, 600), screens: [screen]) == nil)
        #expect(ProjectPlacement.frame(stored(100, 50, 800, -1), screens: [screen]) == nil)
    }

    /// **A window that recorded where it was opens there, as a window; one
    /// that did not opens as tabs of the window the person is in** -- which
    /// is every project from before frames were recorded, and how those
    /// always opened.
    @Test func aWindowWithAFrameIsItsOwnWindowAndOneWithoutIsTabsOfTheCurrentWindow() {
        typealias Place = ProjectPlacement.Place
        func place(_ frame: ProjectFrame?, first: Bool = true, named: Bool = false, current: Bool = true) -> Place {
            ProjectPlacement.place(frame, isFirstWindow: first, homeIsNamed: named, hasCurrentWindow: current, screens: [screen])
        }
        let recorded = stored(100, 50, 800, 600)

        #expect(place(recorded) == .ownWindow(CGRect(x: 100, y: 50, width: 800, height: 600)))
        // Off the screen: still its own window, brought back onto it.
        #expect(place(stored(1500, 40, 800, 600)) == .ownWindow(CGRect(x: 640, y: 40, width: 800, height: 600)))
        // No frame: tabs where the person is -- and with no terminal
        // window to go into, a window wherever a new one goes.
        #expect(place(nil) == .tabs(in: .current))
        #expect(place(nil, current: false) == .ownWindow(nil))
        // A frame from the other corner is no frame here.
        #expect(place(ProjectFrame(origin: .topLeft, x: 100, y: 50, width: 800, height: 600)) == .tabs(in: .current))
        // Each window by its own frame, first or not.
        #expect(place(recorded, first: false) == .ownWindow(CGRect(x: 100, y: 50, width: 800, height: 600)))
        #expect(place(nil, first: false) == .tabs(in: .current))

        // From the control room: the first window goes where it says,
        // frame or none; the others by the rules above.
        #expect(place(recorded, named: true) == .tabs(in: .named))
        #expect(place(nil, named: true, current: false) == .tabs(in: .named))
        #expect(place(recorded, first: false, named: true) == .ownWindow(CGRect(x: 100, y: 50, width: 800, height: 600)))
        #expect(place(nil, first: false, named: true) == .tabs(in: .current))
        #expect(place(nil, first: false, named: true, current: false) == .ownWindow(nil))
    }

    @Test func aWindowsFrameIsRecordedFromTheBottomLeft() {
        #expect(ProjectPlacement.stored(CGRect(x: 12, y: 34, width: 560, height: 780)) == stored(12, 34, 560, 780))
    }

    // MARK: How soon

    /// Each kind of change has a latest moment, and the ones a person makes
    /// with their own hands the soonest.
    @Test func everyKindOfChangeHasALatestMoment() {
        #expect(ProjectAutosaveChange.pages.noLaterThan == ProjectAutosaveChange.layout.noLaterThan)
        #expect(ProjectAutosaveChange.windowFrame.noLaterThan == 10)
        #expect(ProjectAutosaveChange.front.noLaterThan == ProjectAutosaveChange.layout.noLaterThan)
        for change in ProjectAutosaveChange.allCases {
            #expect(change.noLaterThan >= ProjectAutosaveChange.quiet)
            #expect(change.noLaterThan <= 30)
        }
    }
}
