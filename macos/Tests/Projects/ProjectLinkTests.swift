import Testing
import Foundation
@testable import Ghostty

/// What the app and the core say to each other about projects
/// (`ProjectLink`; the contract is `dev-docs/poltergeist/projects.md`).
@Suite
struct ProjectLinkTests {
    private typealias Link = ProjectLink

    /// `src/poltergeist/testdata`, from this file's own place in the tree.
    private static var testdata: URL {
        URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent() // Projects
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // the repository
            .appendingPathComponent("src/poltergeist/testdata")
    }

    private let webApp = Link.Stated(
        name: "web-app", group: "web-app", pages: 3,
        open: [[Link.terminal(0xa1), Link.terminal(0xb1)], [Link.terminal(0xb2)]],
        supervisor: Link.terminal(0xa1), workers: [Link.terminal(0xb1)])
    private let notes = Link.Stated(name: "notes \"2\" 写", group: nil, pages: 1, open: nil, supervisor: nil, workers: [])

    // MARK: What the app says

    /// **The bytes the app sends are the bytes the core's own reader is
    /// tested against.** `host_project_acts.txt` is read by the core's test
    /// (`src/poltergeist/HostProjectActs.zig`) with the parser the core
    /// runs; here each line has to be what this build writes. A request
    /// this build got wrong in a way the core still accepted would be green
    /// there and red here.
    @Test func everyRequestIsWrittenAsTheCoreIsTestedToReadIt() throws {
        let text = try String(contentsOf: Self.testdata.appendingPathComponent("host_project_acts.txt"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        let written = [
            Link.statement([webApp, notes]),
            Link.statement([]),
            Link.failed("web-app", .notFound),
            Link.failed("web-app", .unreadable),
            Link.askRemove(terminal: Link.terminal(0xb2)),
            Link.askRename(from: "web-app", to: "storefront"),
        ].map { String(bytes: $0, encoding: .utf8) ?? "" }
        #expect(lines.count == written.count)
        for (line, mine) in zip(lines, written) {
            #expect(mine == line)
        }
    }

    @Test func aTerminalIsWrittenAsTheCoreWritesIt() {
        #expect(Link.terminal(0xa1) == "0x00000000000000a1")
        #expect(Link.terminal(0) == "0x0000000000000000")
        #expect(Link.terminal(.max) == "0xffffffffffffffff")
    }

    /// Every key, every time: a project that is closed says so with `null`
    /// and an empty list, not by leaving keys out -- to the core a key left
    /// out is a sentence refused whole.
    @Test func aClosedProjectStillSaysEveryKey() throws {
        let said = try #require(JSONSerialization.jsonObject(with: Link.statement([notes])) as? [String: Any])
        let project = try #require((said["list"] as? [[String: Any]])?.first)
        #expect(Set(project.keys) == ["name", "group", "pages", "open", "supervisor", "workers"])
        #expect(project["group"] is NSNull)
        #expect(project["open"] is NSNull)
        #expect(project["supervisor"] is NSNull)
        #expect((project["workers"] as? [String]) == [])
    }

    // MARK: Asking first

    @Test func onlyARefusalAboutThePageStopsItBeingTakenOut() {
        #expect(Link.mayRemove(refusal: nil))
        // The core being behind the app is not a reason.
        #expect(Link.mayRemove(refusal: "ProjectsUnknown"))
        #expect(Link.mayRemove(refusal: "NotInAProject"))
        // The supervisor's page -- and anything this build has no name for.
        #expect(!Link.mayRemove(refusal: "SupervisorPage"))
        #expect(!Link.mayRemove(refusal: "SomethingNew"))
    }

    /// A project that is a group's is renamed by the order that follows the
    /// group's own rename; the app renaming it as well would do it twice.
    @Test func aGroupsProjectIsRenamedByTheOrder() {
        #expect(Link.renames(group: nil) == .theApp)
        #expect(Link.renames(group: "web-app") == .anOrder)
    }

    // MARK: What the core says

    /// The core's own sample of a snapshot: no statement heard yet, so
    /// nothing is known -- which is not "no pages" and not "closed".
    @Test func theCoresSnapshotIsReadAndNotKnownStaysNotKnown() throws {
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("control_snapshot.json"))
        let told = try #require(Link.told(snapshot: data))
        #expect(told.known == false)
        #expect(told.orders.isEmpty)
        #expect(!told.groups.isEmpty)
        let undecided = try #require(told.groups.values.first { $0.why == "projects_unknown" })
        #expect(undecided.pages == nil)
        #expect(undecided.open == nil)
        #expect(undecided.start == .directory)
        // And the sample has a group whose start opens a project.
        #expect(told.groups.values.contains { $0.start == .project })
    }

    /// Orders as the core writes them (the two lines are the core's own,
    /// from its test of the writer in `ControlRoom.zig`).
    @Test func ordersAreReadAndAKindThisBuildDoesNotKnowIsLeftOut() throws {
        let json = #"""
        {"projects_known":true,"groups":[
          {"name":"tied","project":{"tie":"bound","name":"tied","pages":3,"open":false,"start":"project","why":"none"}}],
         "project_orders":[
          {"order":"open","project":"tied","group":"tied","to":null,"terminal":null},
          {"order":"create","project":"old","group":"old","to":null,"terminal":"0x00000000000000a1"},
          {"order":"paint_it_blue","project":"tied","group":null,"to":null,"terminal":null},
          {"order":"rename","project":"web-app","group":null,"to":"storefront","terminal":null}]}
        """#
        let told = try #require(Link.told(snapshot: Data(json.utf8)))
        #expect(told.known)
        #expect(told.orders == [
            Link.Order(kind: .open, project: "tied", group: "tied", to: nil, terminal: nil),
            Link.Order(kind: .create, project: "old", group: "old", to: nil, terminal: "0x00000000000000a1"),
            Link.Order(kind: .rename, project: "web-app", group: nil, to: "storefront", terminal: nil),
        ])
        #expect(told.groups["tied"] == Link.GroupProject(tie: "bound", name: "tied", pages: 3, open: false, start: .project, why: "none"))
        #expect(Link.told(snapshot: Data("not a snapshot".utf8)) == nil)
    }

    // MARK: What the app does about an order

    private var host: Link.Host {
        Link.Host(
            projects: [webApp, notes],
            projectOfTab: [Link.terminal(0xa1): "web-app", Link.terminal(0xb1): "web-app", Link.terminal(0xb2): "web-app"],
            terminals: [Link.terminal(0xa1), Link.terminal(0xb1), Link.terminal(0xb2), Link.terminal(0xc1)])
    }

    private func order(_ kind: Link.Order.Kind, _ project: String, group: String? = nil, to: String? = nil, terminal: UInt64? = nil) -> Link.Order {
        Link.Order(kind: kind, project: project, group: group, to: to, terminal: terminal.map(Link.terminal))
    }

    @Test func anOrderToOpenOpensOrSaysWhyNot() {
        #expect(Link.step(for: order(.open, "web-app"), host: host) == .open("web-app"))
        #expect(Link.step(for: order(.open, "gone"), host: host) == .fail("gone", .notFound))
    }

    /// **Done twice, an order does nothing the second time**: each is held
    /// against what the app has before anything is touched.
    @Test func anOrderThatIsAlreadySoIsNothingToDo() {
        // create: the tab is free and the name is too.
        #expect(Link.step(for: order(.create, "nightly", group: "nightly", terminal: 0xc1), host: host)
            == .create(name: "nightly", group: "nightly", terminal: Link.terminal(0xc1)))
        // ...the name is a project already; the tab is a page already; the
        // terminal is gone.
        #expect(Link.step(for: order(.create, "notes \"2\" 写", group: "g", terminal: 0xc1), host: host) == nil)
        #expect(Link.step(for: order(.create, "nightly", group: "nightly", terminal: 0xb2), host: host) == nil)
        #expect(Link.step(for: order(.create, "nightly", group: "nightly", terminal: 0xdd), host: host) == nil)

        // set_group: only when the file says something else.
        #expect(Link.step(for: order(.setGroup, "web-app", group: "web-app"), host: host) == nil)
        #expect(Link.step(for: order(.setGroup, "web-app", group: nil), host: host) == .setGroup(project: "web-app", group: nil))
        #expect(Link.step(for: order(.setGroup, "notes \"2\" 写", group: "g"), host: host) == .setGroup(project: "notes \"2\" 写", group: "g"))
        #expect(Link.step(for: order(.setGroup, "gone", group: "g"), host: host) == nil)

        // rename: once; not when it is done, and not onto a name in use.
        #expect(Link.step(for: order(.rename, "web-app", to: "storefront"), host: host) == .rename(project: "web-app", to: "storefront"))
        #expect(Link.step(for: order(.rename, "gone", to: "web-app"), host: host) == nil)
        #expect(Link.step(for: order(.rename, "web-app", to: "notes \"2\" 写"), host: host) == nil)
        #expect(Link.step(for: order(.rename, "web-app", to: "web-app"), host: host) == nil)

        // add_tab: a tab of no project, into a project that is there.
        #expect(Link.step(for: order(.addTab, "web-app", terminal: 0xc1), host: host) == .addTab(project: "web-app", terminal: Link.terminal(0xc1)))
        #expect(Link.step(for: order(.addTab, "web-app", terminal: 0xb2), host: host) == nil)
        #expect(Link.step(for: order(.addTab, "gone", terminal: 0xc1), host: host) == nil)
    }

    @Test func bindingTakesAProjectOfNoGroupAndIsDoneOnce() {
        var with = host
        with.projects = [
            Link.Stated(name: "scratch", group: nil, pages: 1, open: [[Link.terminal(0xa1)]], supervisor: nil, workers: []),
            webApp,
        ]
        with.projectOfTab = [Link.terminal(0xa1): "scratch"]
        let bind = order(.bind, "scratch", group: "old", to: "old", terminal: 0xa1)
        #expect(Link.step(for: bind, host: with) == .bind(project: "scratch", group: "old", terminal: Link.terminal(0xa1), to: "old"))
        // The name it would take is another project's: bound, not renamed.
        #expect(Link.step(for: order(.bind, "scratch", group: "old", to: "web-app", terminal: 0xa1), host: with)
            == .bind(project: "scratch", group: "old", terminal: Link.terminal(0xa1), to: nil))
        // The terminal's tab is not a page of that project.
        #expect(Link.step(for: order(.bind, "scratch", group: "old", to: "old", terminal: 0xc1), host: with) == nil)
        // A project that is another group's is that group's.
        #expect(Link.step(for: order(.bind, "web-app", group: "old", to: "old", terminal: 0xa1), host: host) == nil)

        // Done: the file names the group, the pane is the supervisor's and
        // the name is the one asked for.
        var done = with
        done.projects[0] = Link.Stated(name: "old", group: "old", pages: 1, open: [[Link.terminal(0xa1)]], supervisor: Link.terminal(0xa1), workers: [])
        done.projectOfTab = [Link.terminal(0xa1): "old"]
        #expect(Link.step(for: order(.bind, "old", group: "old", to: "old", terminal: 0xa1), host: done) == nil)
    }

    /// An order is acted on once for as long as it stays in the list: an
    /// `open` the core goes on asking for does not pull the project's
    /// windows in front of the person at every snapshot.
    @Test func anOrderThatStaysInTheListIsActedOnOnce() {
        let open = order(.open, "web-app")
        let add = order(.addTab, "web-app", terminal: 0xc1)
        var (toDo, acted) = Link.fresh([open], acted: [])
        #expect(toDo == [open])
        (toDo, acted) = Link.fresh([open, add], acted: acted)
        #expect(toDo == [add])
        (toDo, acted) = Link.fresh([open, add], acted: acted)
        #expect(toDo.isEmpty)
        // It went away, and came back: a new one.
        (toDo, acted) = Link.fresh([add], acted: acted)
        #expect(toDo.isEmpty && acted == [add])
        (toDo, acted) = Link.fresh([open, add], acted: acted)
        #expect(toDo == [open])
    }

    // MARK: The supervisor's pane

    /// The seat is where the supervisor's agent is, as in every file a
    /// build before format 3 wrote and every one `makeSupervisor` leaves.
    private func leaf(_ cwd: String, _ scrollback: String, _ agent: ProjectAgent, bySupervisor: Bool = false) -> ProjectNode {
        .leaf(cwd: cwd, title: "", titleChosen: false, history: "", scrollback: scrollback, bySupervisor: bySupervisor, supervisorSeat: agent.isSupervisor, color: .none, workersRefused: false, shielded: false, agent: agent)
    }

    /// **One pane is the supervisor's, and marking another unmarks the
    /// first** -- two would read back as none.
    @Test func markingAPaneTheSupervisorsUnmarksEveryOther() throws {
        let old = ProjectAgent.agent(role: "polter-supervisor", cli: "claude-code", session: "s", supervisor: true)
        var pages = ProjectPages(file: ProjectFile(
            name: "p", savedAt: 1, group: "g",
            windows: [ProjectWindow(frame: nil, front: 0, tabs: [
                ProjectTab(root: .split(direction: .horizontal, ratio: 0.5, left: leaf("/a", "0.snap", old), right: leaf("/b", "1.snap", .none, bySupervisor: true)), title: ""),
                ProjectTab(root: leaf("/c", "2.snap", .unknown), title: ""),
            ])],
            nextScrollback: 3))
        #expect(pages.supervisorPane == "0.snap")
        #expect(pages.workerPanes == ["1.snap"])

        pages.makeSupervisor(pane: "2.snap")
        #expect(pages.supervisorPane == "2.snap")
        let file = ProjectFile(name: "p", savedAt: 1, group: "g", windows: pages.fileWindows, nextScrollback: 3)
        // Exactly one, so it reads back as it is written.
        #expect(try ProjectFile.decode(from: file.encoded()) == file)
        #expect(file.tabs.reduce(0) { $0 + $1.supervisorCount } == 1)
        // The pane that was it is still the agent it was, and the worker's
        // pane is still one the supervisor opened.
        #expect(file.tabs[0] == .split(
            direction: .horizontal, ratio: 0.5,
            left: leaf("/a", "0.snap", .agent(role: "polter-supervisor", cli: "claude-code", session: "s", supervisor: false)),
            right: leaf("/b", "1.snap", .none, bySupervisor: true)))

        // A pane with no name cannot be it, and asking changes nothing.
        let was = pages
        pages.makeSupervisor(pane: "")
        #expect(pages == was)
    }

    /// The supervisor's pane, a worker's pane and what a save cannot tell
    /// are found among a stack's members exactly as among panes side by
    /// side -- in front or behind.
    @Test func whatIsKeptAndMarkedIsFoundAmongAStacksMembers() {
        let was = ProjectAgent.agent(role: "polter-supervisor", cli: "claude-code", session: "s-1", supervisor: true)
        let file = ProjectFile.oneTab(
            name: "p", savedAt: 1,
            root: .stack(shown: 1, members: [leaf("/a", "0.snap", was), leaf("/b", "1.snap", .none, bySupervisor: true)]),
            nextScrollback: 2)
        var pages = ProjectPages(file: file)
        #expect(pages.supervisorPane == "0.snap")
        #expect(pages.workerPanes == ["1.snap"])

        // A save that can tell nothing about either member -- and has the
        // other one in front now -- keeps what the file said of each.
        let captured = ProjectNode.stack(shown: 0, members: [leaf("", "0.snap", .unknown), leaf("/b2", "1.snap", .unknown)])
        #expect(captured.keepingWhatTheFileKnew(pages.known) == .stack(shown: 0, members: [
            leaf("/a", "0.snap", was), leaf("/b2", "1.snap", .none, bySupervisor: true),
        ]))

        // Marking the member behind as the supervisor's unmarks the other.
        pages.makeSupervisor(pane: "1.snap")
        #expect(pages.supervisorPane == "1.snap")
        #expect(pages.fileWindows[0].tabs[0].root.supervisorCount == 1)
    }

    // MARK: Who is in a pane

    private func who(_ kind: Link.Who.Kind, role: String? = nil, cli: String? = nil, session: String? = nil, workerOf: UInt64? = nil) -> Link.Who {
        Link.Who(kind: kind, role: role, cli: cli, session: session, workerOf: workerOf.map(Link.terminal))
    }

    /// The core's three answers are the file's three; a terminal the
    /// snapshot does not have is one nothing can be said of.
    @Test func whatTheCoreSaysOfATerminalIsWhatIsWrittenOfItsPane() {
        let supervisor = Link.terminal(0xa1)
        #expect(Link.pane(nil, supervisor: supervisor).agent == .unknown)
        #expect(Link.pane(who(.unknown), supervisor: supervisor).agent == .unknown)
        #expect(Link.pane(who(.none), supervisor: supervisor).agent == ProjectAgent.none)
        #expect(Link.pane(who(.agent, role: "polter-dev", cli: "codex", session: "s"), supervisor: supervisor).agent
            == .agent(role: "polter-dev", cli: "codex", session: "s", supervisor: false))
        // A part the core does not know is an empty one, as it wrote it.
        #expect(Link.pane(who(.agent, role: "", cli: "claude-code", session: ""), supervisor: nil).agent
            == .agent(role: "", cli: "claude-code", session: "", supervisor: false))
    }

    /// A pane is one the supervisor opened when it was opened as a worker
    /// of the terminal in the project's supervisor pane -- and with no such
    /// terminal to compare with, that is not said. A pane the supervisor
    /// split off for itself is not one: the core says no `worker_of` for it
    /// (#1498), and that is the `who(.none)` line below.
    @Test func aPaneIsTheSupervisorsToUseWhenTheSupervisorsTerminalOpenedIt() {
        let supervisor = Link.terminal(0xa1)
        #expect(Link.pane(who(.agent, role: "polter-dev", cli: "codex", session: "", workerOf: 0xa1), supervisor: supervisor).bySupervisor)
        // The agent has left; the pane is still one the supervisor opened.
        #expect(Link.pane(who(.none, workerOf: 0xa1), supervisor: supervisor).bySupervisor)
        // Opened by somebody else's agent, by a person, or not in the snapshot.
        #expect(!Link.pane(who(.none, workerOf: 0xc9), supervisor: supervisor).bySupervisor)
        #expect(!Link.pane(who(.none), supervisor: supervisor).bySupervisor)
        #expect(!Link.pane(nil, supervisor: supervisor).bySupervisor)
        // The supervisor's page is closed: nothing to compare with -- and a
        // pane nobody opened does not match "no supervisor".
        #expect(!Link.pane(who(.none, workerOf: 0xa1), supervisor: nil).bySupervisor)
        #expect(!Link.pane(who(.none), supervisor: nil).bySupervisor)
    }

    /// **The supervisor's pane stays the supervisor's, whoever is found in
    /// it** -- most of all when nobody is: it is where the group's
    /// supervisor is started again, with the session it had.
    @Test func theSupervisorsPaneKeepsItsMarkAndItsLastSession() {
        let was = ProjectAgent.agent(role: "polter-supervisor", cli: "claude-code", session: "s-1", supervisor: true)
        let known = ProjectPages(file: .oneTab(name: "p", savedAt: 1, root: leaf("/w", "0.snap", was), nextScrollback: 1)).known
        func saved(_ now: ProjectAgent) -> ProjectNode { leaf("/w", "0.snap", now).keepingWhatTheFileKnew(known) }

        // Its agent has left, or nothing can tell: the pane as it was.
        #expect(saved(.none) == leaf("/w", "0.snap", was))
        #expect(saved(.unknown) == leaf("/w", "0.snap", was))
        // An agent is in it: what the core knows of it, the mark kept, and
        // what the core does not know yet kept as the file had it.
        #expect(saved(.agent(role: "polter-supervisor", cli: "claude-code", session: "s-2", supervisor: false))
            == leaf("/w", "0.snap", .agent(role: "polter-supervisor", cli: "claude-code", session: "s-2", supervisor: true)))
        #expect(saved(.agent(role: "", cli: "codex", session: "", supervisor: false))
            == leaf("/w", "0.snap", .agent(role: "polter-supervisor", cli: "codex", session: "s-1", supervisor: true)))

        // Any other pane: an answer is what is written, nobody included,
        // and an agent's unknown parts are not filled from whoever was
        // there before.
        let worker = ProjectAgent.agent(role: "polter-dev", cli: "codex", session: "w", supervisor: false)
        let other = ProjectPages(file: .oneTab(name: "p", savedAt: 1, root: leaf("/w", "0.snap", worker), nextScrollback: 1)).known
        #expect(leaf("/w", "0.snap", .none).keepingWhatTheFileKnew(other) == leaf("/w", "0.snap", .none))
        #expect(leaf("/w", "0.snap", .unknown).keepingWhatTheFileKnew(other) == leaf("/w", "0.snap", worker))
        let next = ProjectAgent.agent(role: "", cli: "claude-code", session: "", supervisor: false)
        #expect(leaf("/w", "0.snap", next).keepingWhatTheFileKnew(other) == leaf("/w", "0.snap", next))
        // And a save cannot make a pane the supervisor's: only the mark can.
        let claims = ProjectAgent.agent(role: "x", cli: "y", session: "z", supervisor: true)
        #expect(Link.pane(who(.agent, role: "x", cli: "y", session: "z"), supervisor: nil).agent != claims)
    }

    // MARK: The control room's start

    @Test func theStartButtonSaysOpenWhenStartingOpensAProject() {
        let bound = Link.GroupProject(tie: "bound", name: "web-app", pages: 3, open: false, start: .project, why: "none")
        let old = Link.GroupProject(tie: "undecided", name: nil, pages: nil, open: nil, start: .directory, why: "projects_unknown")
        #expect(Link.startTitle(bound) != Link.startTitle(old))
        #expect(Link.startTitle(nil) == Link.startTitle(old))
        #expect(Link.startNote(bound)?.contains("3") == true)
        #expect(Link.startNote(old) == nil)
        // No project yet, and one will be made: said, with how to undo it
        // (task 1713). Not when the group said it wants none.
        let none = Link.GroupProject(tie: "undecided", name: nil, pages: nil, open: nil, start: .directory, why: "not_taken_up")
        #expect(Link.startNote(none) != nil)
        let declined = Link.GroupProject(tie: "declined", name: nil, pages: nil, open: nil, start: .directory, why: "declined")
        #expect(Link.startNote(declined) == nil)
        #expect(Link.startNote(nil) == nil)
        // Not known is not zero: the sentence leaves the count out.
        let unknown = Link.GroupProject(tie: "bound", name: "web-app", pages: nil, open: nil, start: .project, why: "none")
        let said = try? #require(Link.startNote(unknown))
        #expect(said != nil && said?.contains("0") == false)
    }
}
