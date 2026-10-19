import AppKit
import GhosttyKit
import OSLog

/// A project that is open: the tabs that are its pages, and the one writer
/// of its file for as long as any of them is there.
///
/// A project used to be one tab, and that tab wrote the file. Now it is
/// several pages in one window or more, some of them open as tabs and some
/// not, and a save has to write all of them -- the open ones as they are,
/// the others as they were. So the writer is this, not a tab: every tab of
/// the project holds it (`TerminalController.projectSession`), it holds
/// them weakly, and it goes away with the last of them.
///
/// What the pages are and what a save makes of them is `ProjectPages`,
/// which needs no window and is tested without the app. This file is the
/// part that touches real tabs and real windows, and it decides nothing
/// that file does not.
///
/// It is what `ProjectStore.bindings` holds for the project, so "is this
/// project open, and in what" has one answer.
@MainActor
final class ProjectSession: ProjectBindingHolder, ProjectMoveFollower {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "projects")

    private struct Member {
        weak var controller: TerminalController?
        let page: Int
    }

    private(set) var name: String
    private let store: ProjectStore
    private var pages: ProjectPages
    /// The group the project is the project of. Read from the file and
    /// written back; changed only by `setGroup`, which the core's orders
    /// call.
    private(set) var group: String?
    /// The project's colour (task 1796). Read from the file -- given one
    /// when it has none (`ProjectStore.givingColor`) -- and written back;
    /// changed only by `setColor`, which the settings window calls.
    private(set) var color: PaneColor
    private var members: [Member] = []
    /// How many `open`s have put tabs up and not yet finished placing
    /// their windows. While any has not, a save takes no frame and no
    /// front from the screen (`ProjectPages.taken`).
    private var opening = 0

    /// How long after its tabs are up a project is still "being opened".
    /// Shorter than the second a save waits after a change, so the first
    /// save after an open is already one that may look at the screen.
    private static let settling: TimeInterval = 0.5
    private lazy var autosave = ProjectAutosaveDebouncer(scheduler: MainQueueScheduler()) { [weak self] in
        self?.autosaveNow()
    }

    private init(name: String, store: ProjectStore, pages: ProjectPages, group: String?, color: PaneColor) {
        self.name = name
        self.store = store
        self.pages = pages
        self.group = group
        self.color = color
    }

    // MARK: Finding and making one

    /// The session the project `name` is open in, if it is open.
    static func open(for name: String, in store: ProjectStore) -> ProjectSession? {
        store.bindings.owner(of: store.bindingKey(name: name)) as? ProjectSession
    }

    /// The session of `entry`'s project: the one it is open in, or a new
    /// one read from its file with none of its pages open yet.
    static func session(for entry: ProjectStore.Entry, in store: ProjectStore) throws -> ProjectSession {
        if let session = open(for: entry.name, in: store) { return session }
        let file = store.givingColor(try store.read(entry), of: entry)
        let session = ProjectSession(
            name: entry.name, store: store, pages: ProjectPages(file: file), group: file.group, color: file.color)
        try session.claim()
        return session
    }

    private func claim() throws {
        if case .heldBy = store.bindings.claim(store.bindingKey(name: name), for: self) {
            throw ProjectStore.StoreError.boundElsewhere(name: name, holder: store.holderTitle(name: name) ?? "")
        }
    }

    private func releaseIfNobodyIsLeft() {
        guard liveMembers.isEmpty else { return }
        autosave.cancel()
        store.bindings.release(store.bindingKey(name: name), for: self)
    }

    // MARK: Its tabs

    private var liveMembers: [(controller: TerminalController, page: Int)] {
        members.compactMap { member in member.controller.map { ($0, member.page) } }
    }

    private func controller(of page: Int) -> TerminalController? {
        liveMembers.first { $0.page == page }?.controller
    }

    /// Never empty: a tab just opened has no window title until its shell
    /// sets one (see `ProjectsRules.holderLabel`, #965).
    var projectBindingTitle: String {
        liveMembers.first?.controller.projectTabTitle ?? ""
    }

    /// Make `controller` a page of this project: the page `page` when it is
    /// one the project already has, a new one otherwise. From now on its
    /// layout, directories and titles are written as they change.
    private func attach(_ controller: TerminalController, page: Int?, caller: String = #function) {
        let id = page ?? pages.newPageID()
        ProjectTrace.membership("attached", controller, project: name, page: id, caller: caller)
        members.removeAll { $0.controller == nil }
        members.append(Member(controller: controller, page: id))
        controller.projectSession = self
        controller.boundProject = name
        controller.boundProjectColor = color
        controller.startProjectAutosave()
        // What carries the tab's place in the project across a restart --
        // see `TerminalRestorableState.InternalState.boundProject`.
        controller.invalidateRestorableState()
        ProjectStore.postBindingDidChange(name)
    }

    /// `controller` stops being a tab of this project.
    ///
    /// With `removing` false the page stays: the tab is closing, and the
    /// project keeps the page as it is now -- with a full capture of its
    /// scrollback, asked for while its panes are still alive -- to open
    /// again. With `removing` true the page is taken out of the project,
    /// and the tab, if it lives on, is a tab of no project.
    ///
    /// `saving` false writes nothing at all: for undoing a join whose save
    /// failed, which must leave the file as it was.
    func detach(_ controller: TerminalController, removing: Bool, saving: Bool = true, caller: String = #function) {
        guard let at = members.firstIndex(where: { $0.controller === controller }) else { return }
        ProjectTrace.membership(
            removing ? "taken out" : "detached", controller, project: name, page: members[at].page, caller: caller)
        if !removing && saving {
            save(capturing: [controller], closing: true, keeping: .onLayoutChange, what: "final save")
        }
        let page = members.remove(at: at).page
        controller.stopProjectAutosave()
        controller.stopScrollbackJournals()
        controller.projectSession = nil
        controller.boundProject = nil
        controller.boundProjectColor = .none
        controller.invalidateRestorableState()
        if removing {
            pages.remove(page)
            // Written now, with or without a tab left: the page is gone
            // from the file, and its snapshots with it.
            if saving {
                save(capturing: [], keeping: .onLayoutChange, what: "save after taking a page out")
            }
        }
        releaseIfNobodyIsLeft()
        ProjectStore.postBindingDidChange(name)
    }

    // MARK: Saving

    /// Something about the project changed: write it soon
    /// (`ProjectAutosaveChange` says how soon at the latest).
    func poke(_ change: ProjectAutosaveChange) {
        autosave.poke(change)
    }

    private func autosaveNow() {
        // No full capture: that is up to the configured limit per pane and
        // this runs a second after any title change. Scrollback is kept by
        // each pane's journal, which a save also starts for a pane that has
        // none yet (`ProjectStore.save`).
        save(capturing: [], keeping: .onLayoutChange, what: "autosave")
    }

    /// The application is quitting: write the project as it is now. Always
    /// written, pending or not: a file that would not change is not touched
    /// (`ProjectFileWriter.plan`). No full scrollback capture, which is
    /// asked of the core and lands later than a quit waits for; each pane's
    /// journal has its scrollback.
    func saveBeforeQuit() {
        autosave.cancel()
        save(capturing: [], keeping: .onLayoutChange, what: "save at quit")
    }

    /// Logged, not alerted, when it fails: most saves run on their own a
    /// second after a change, and an alert per title change is worse than
    /// the failure. The next change tries again.
    private func save(
        capturing: [TerminalController], closing: Bool = false, keeping: ProjectFileWriter.Keeping, what: String
    ) {
        do {
            try write(capturing: capturing, closing: closing, keeping: keeping)
        } catch {
            Self.logger.warning("\(what, privacy: .public) of project '\(self.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Who is in each pane, as the core's latest snapshot says
    /// (`terminals[].who`), and whether the project's supervisor opened it
    /// (`ProjectLink.pane` has the rule). Read once for a whole save.
    private func whoIsInPane() -> (Ghostty.SurfaceView) -> (agent: ProjectAgent, bySupervisor: Bool, seat: Bool) {
        guard let ghostty = liveMembers.first?.controller.ghostty else {
            return { view in (.unknown, false, ProjectLink.seat(supervisor: view.poltergeistRole == .supervisor, terminal: nil, group: self.group, steward: nil)) }
        }
        let latest = ControlRoomFeed.shared(ghostty).latest
        var said: [String: ProjectLink.Who] = [:]
        for terminal in latest?.terminals ?? [] {
            guard let who = terminal.who else { continue }
            let kind: ProjectLink.Who.Kind
            switch who.is {
            case .unknown: kind = .unknown
            case .none: kind = .none
            case .agent: kind = .agent
            }
            said[terminal.id] = ProjectLink.Who(
                kind: kind, role: who.role, cli: who.cli, session: who.session, workerOf: who.worker_of)
        }
        let supervisor = stated?.supervisor
        // Who the group's supervisor is now, as the core says (task 1831).
        let group = self.group
        let steward = group.flatMap { g in latest?.groups.first { $0.name == g }?.steward }
        return { view in
            let terminal = ControlRoomLender.terminal(of: view)
            let pane = ProjectLink.pane(terminal.flatMap { said[$0] }, supervisor: supervisor)
            let seat = ProjectLink.seat(
                supervisor: view.poltergeistRole == .supervisor, terminal: terminal, group: group, steward: steward)
            return (pane.agent, pane.bySupervisor, seat)
        }
    }

    /// `closing` is the save a tab makes as it closes: which page is in
    /// front is not asked of the tabs (`ProjectPages.updated`).
    private func write(capturing: [TerminalController], closing: Bool = false, keeping: ProjectFileWriter.Keeping) throws {
        var frames: [Int: ProjectFrame] = [:]
        let open: [ProjectStore.OpenPage] = liveMembers.compactMap { member in
            guard let window = member.controller.window else { return nil }
            let capturing = capturing.contains { $0 === member.controller }
            // A tab that is closing is not asked where it is: the system
            // has already taken it out of its window, and what it would
            // answer is a window of its own (`ProjectPages.Live.window`).
            if closing && capturing {
                return ProjectStore.OpenPage(
                    id: member.page, tree: member.controller.surfaceTree,
                    window: nil, index: 0, selected: false, capturingScrollback: true,
                    title: member.controller.titleOverride ?? "")
            }
            let tabs = window.tabGroup
            let token = tabs.map { ObjectIdentifier($0).hashValue } ?? ObjectIdentifier(window).hashValue
            // Where the window is, is where the tab that is showing is:
            // the tabs of a window are windows themselves, and one that is
            // not showing can be anywhere it was last put. A window that
            // fills the screen has the screen's frame, which is not where
            // it goes back to: what the file had stays.
            let onScreen = tabs?.selectedWindow ?? window
            if !onScreen.styleMask.contains(.fullScreen) {
                frames[token] = ProjectPlacement.stored(onScreen.frame)
            }
            return ProjectStore.OpenPage(
                id: member.page,
                tree: member.controller.surfaceTree,
                window: token,
                index: tabs?.windows.firstIndex(of: window) ?? 0,
                selected: tabs?.selectedWindow.map { $0 === window } ?? true,
                capturingScrollback: capturing,
                // The name somebody gave the tab, and nothing else: the
                // window's title is the program's (task 1722).
                title: member.controller.titleOverride ?? "")
        }
        let taken = ProjectPages.taken(frames: frames, closing: closing, opening: opening > 0)
        pages = try store.save(
            name: name, group: group, color: color, pages: pages,
            tabs: .init(open: open, frames: taken.frames, keepingFront: taken.keepingFront),
            who: whoIsInPane(), keeping: keeping).pages
        // Also when nothing was written: what changed may be only a
        // window's title, which is what the settings window calls the
        // project's tab by.
        ProjectStore.postBindingDidChange(name)
    }

    // MARK: The group's side

    /// The project is `group`'s from now on (nil: no group's), and the file
    /// says so.
    func setGroup(_ group: String?) {
        guard self.group != group else { return }
        self.group = group
        save(capturing: [], keeping: .onLayoutChange, what: "save of the group")
    }

    /// The project is `color` from now on, and the file says so.
    func setColor(_ color: PaneColor) {
        guard self.color != color, ProjectTone.order.contains(color) else { return }
        self.color = color
        for member in liveMembers {
            member.controller.boundProjectColor = color
        }
        save(capturing: [], keeping: .onLayoutChange, what: "save of the colour")
    }

    /// The pane `view` is the supervisor's, and no other pane of the
    /// project is (`ProjectPages.makeSupervisor`).
    func makeSupervisor(_ view: Ghostty.SurfaceView, caller: String = #function) {
        ProjectTrace.seated(view, project: name, caller: caller)
        // A pane is found by its snapshot name, which a save gives it.
        if view.projectSnapshot == nil {
            save(capturing: [], keeping: .onLayoutChange, what: "save before marking the supervisor")
        }
        let key = store.bindingKey(name: name)
        guard let snapshot = view.projectSnapshot, snapshot.project == key else { return }
        guard pages.supervisorPane != snapshot.filename else { return }
        pages.makeSupervisor(pane: snapshot.filename)
        save(capturing: [], keeping: .onLayoutChange, what: "save of the supervisor's pane")
    }

    /// What the core is told of this project while it is open: the
    /// terminals on each open page in the pages' order, the terminal in the
    /// supervisor's pane, and those in panes the supervisor opened. Nil
    /// when no page is open.
    ///
    /// The panes the supervisor opened are the ones the file marks: after a
    /// restart the core has forgotten who opened what, and this is how it
    /// is told again (`dev-docs/poltergeist/projects.md`, section 9).
    var stated: (open: [[String]], supervisor: String?, workers: [String])? {
        let order = pages.pageIDs
        let live = liveMembers.sorted {
            (order.firstIndex(of: $0.page) ?? .max) < (order.firstIndex(of: $1.page) ?? .max)
        }
        guard !live.isEmpty else { return nil }
        let key = store.bindingKey(name: name)
        func terminals(named names: [String]) -> [String] {
            live.flatMap { member in
                member.controller.surfaceTree.compactMap { view -> String? in
                    guard let snapshot = view.projectSnapshot, snapshot.project == key,
                          names.contains(snapshot.filename)
                    else { return nil }
                    return ControlRoomLender.terminal(of: view)
                }
            }
        }
        return (
            live.map { $0.controller.surfaceTree.compactMap(ControlRoomLender.terminal(of:)) },
            pages.supervisorPane.flatMap { terminals(named: [$0]).first },
            terminals(named: pages.workerPanes))
    }

    // MARK: Tabs saved as a project

    /// The project `name` becomes the tabs `controllers`, in the order
    /// their tabs stand: whatever pages it had are replaced, and its group,
    /// if it had one, stays its group. Throws rather than reporting, so a
    /// caller that has something riding on the save -- closing the tab, the
    /// settings window's "Overwrite with Current Tab" -- can tell whether
    /// it worked, and a save that fails leaves every tab as it was.
    ///
    /// Refused while the project is open in other tabs: its pages there
    /// would be written straight back over this. Refused for a tab that is
    /// a page of another project: a tab is a page of at most one.
    static func save(
        _ controllers: [TerminalController],
        as name: String,
        keeping: ProjectFileWriter.Keeping,
        in store: ProjectStore
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session = open(for: trimmed, in: store) {
            guard session.liveMembers.allSatisfy({ member in controllers.contains { $0 === member.controller } }),
                  controllers.allSatisfy({ $0.projectSession === session })
            else {
                throw ProjectStore.StoreError.boundElsewhere(name: trimmed, holder: session.projectBindingTitle)
            }
            // Its own project, saved again by hand.
            try session.write(capturing: controllers, keeping: keeping)
            return
        }
        if store.bindings.owner(of: store.bindingKey(name: trimmed)) != nil {
            throw ProjectStore.StoreError.boundElsewhere(name: trimmed, holder: store.holderTitle(name: trimmed) ?? "")
        }
        if let taken = controllers.first(where: { $0.projectSession != nil }) {
            throw ProjectStore.StoreError.pageOfAnother(tab: taken.projectTabTitle, name: taken.boundProject ?? "")
        }

        let session = ProjectSession(
            name: trimmed, store: store, pages: ProjectPages(), group: store.group(name: trimmed),
            color: store.color(name: trimmed))
        try session.claim()
        for controller in controllers {
            session.attach(controller, page: nil)
        }
        do {
            try session.write(capturing: controllers, keeping: keeping)
        } catch {
            for controller in controllers {
                session.detach(controller, removing: true, saving: false)
            }
            throw error
        }
    }

    /// `controller` becomes one more page of `entry`'s project, where its
    /// tab is. The project's other pages are not opened by this.
    static func add(_ controller: TerminalController, to entry: ProjectStore.Entry, in store: ProjectStore) throws {
        if let name = controller.boundProject, controller.projectSession != nil {
            throw ProjectStore.StoreError.pageOfAnother(tab: controller.projectTabTitle, name: name)
        }
        let session = try session(for: entry, in: store)
        session.attach(controller, page: nil)
        do {
            try session.write(capturing: [controller], keeping: .onLayoutChange)
        } catch {
            session.detach(controller, removing: true, saving: false)
            throw error
        }
    }

    /// How many of the project's pages are open besides `controller`.
    func otherPagesOpen(than controller: TerminalController) -> Int {
        liveMembers.filter { $0.controller !== controller }.count
    }

    /// Whether any pane of any open page has something running that a
    /// person would want asking about before it is closed.
    var needsConfirmToClose: Bool {
        liveMembers.contains { member in member.controller.surfaceTree.contains { $0.needsConfirmQuit } }
    }

    /// "Close Project": every open page closes, and every one stays a page
    /// -- the project is put away, not taken apart.
    func closeAllPages() {
        for member in liveMembers {
            member.controller.closeTabImmediately(registerRedo: false)
        }
    }

    // MARK: Opening

    /// Open every page of the project that is not open, and bring the
    /// project in front.
    ///
    /// - A window of the project none of whose pages is open goes where
    ///   `ProjectPlacement.place` says: a window of its own at the frame the
    ///   file recorded, or -- with no frame recorded -- tabs of `current`,
    ///   the terminal window the person is in. Its pages are in order, the
    ///   one that was in front showing.
    /// - A window some of whose pages are open gets the others back as tabs
    ///   beside them, each after the page it follows.
    /// - `home`, when there is one, is where the first window's pages go as
    ///   tabs whatever its frame: the control room's rule for where a tab
    ///   it opens goes (`ControlRoomRules.newTab`). `inFront` false then
    ///   leaves them behind the tab that is showing.
    /// - Nothing is refused for being open already: with every page open
    ///   this only brings the project in front.
    func open(_ ghostty: Ghostty.App, into home: NSWindow?, beside current: NSWindow?, inFront: Bool) throws {
        guard let app = ghostty.app else { return }
        guard let entry = store.entry(name: name) else { throw ProjectStore.StoreError.notFound }
        let screens = NSScreen.screens.map(\.visibleFrame)

        // Until the windows stand where the file says, nothing a save
        // takes from the screen is the project's (`ProjectPages.taken`).
        opening += 1
        var placements: [() -> Void] = []

        var toShow: NSWindow?
        for (number, window) in pages.windows.enumerated() {
            let wasOpen = window.pages.contains { controller(of: $0.id) != nil }
            // The tab a page not yet open goes after...
            var previous: NSWindow?
            // ...or, with no page before it open, the tab it goes before.
            let firstOpen = window.pages.lazy.compactMap { self.controller(of: $0.id)?.window }.first
            let place = ProjectPlacement.place(
                window.frame, isFirstWindow: number == 0, homeIsNamed: home != nil,
                hasCurrentWindow: current != nil, screens: screens)
            let behind = !wasOpen && place == .tabs(in: .named) && !inFront
            // What the page's panes will be laid out in, for the one case
            // that is known before they exist: a window of its own at the
            // frame the file recorded, holding this page alone (a second
            // tab would bring a tab bar). Anywhere else nil, and the panes
            // start at the core's placeholder (#47).
            let toOpen = window.pages.filter { controller(of: $0.id) == nil }.count
            var area: ProjectPageArea?
            if case .ownWindow(let frame?) = place, firstOpen == nil, toOpen == 1 {
                area = ProjectPageAreas.ownWindow(frame, ghostty: ghostty)
                Self.logger.info("project '\(self.name, privacy: .public)' window \(number): panes sized for \(area.map { "\(Int($0.size.width))x\(Int($0.size.height))@\($0.scale)" } ?? "nothing", privacy: .public) in a \(Int(frame.width))x\(Int(frame.height)) frame")
            }

            for page in window.pages {
                if let existing = controller(of: page.id) {
                    previous = existing.window
                    continue
                }
                let tree = store.materialize(page.tab, of: entry, app: app, area: area)
                let controller = TerminalController(ghostty, withSurfaceTree: tree)
                // The tab's chosen name, set on the tab itself rather than
                // sent as `set_tab_title`: the core keeps no record of a
                // tab's name (that action only forwards to the host, which
                // finds the tab by the terminal's window -- and these
                // terminals have none yet), so this is the same field the
                // action would have reached (task 1722).
                if let name = page.tab.titleOverride { controller.titleOverride = name }
                guard let tab = controller.window else { continue }
                if let previous {
                    previous.addTabbedWindowSafely(tab, ordered: .above)
                } else if let firstOpen {
                    firstOpen.addTabbedWindowSafely(tab, ordered: .below)
                } else {
                    switch place {
                    case .ownWindow(let frame):
                        controller.presentAsProjectWindow(placed: frame != nil)
                    case .tabs(let which):
                        // `place` only names a window that is there.
                        guard let host = which == .named ? home : current else {
                            controller.presentAsProjectWindow(placed: false)
                            break
                        }
                        if host.isMiniaturized { host.deminiaturize(nil) }
                        // Tabs join by identifier, and a host that is not a
                        // terminal's window -- the control room alone in
                        // its own -- does not have the terminals'.
                        if !(host.windowController is TerminalController) {
                            host.tabbingIdentifier = tab.tabbingIdentifier
                        }
                        (host.tabGroup?.windows.last ?? host).addTabbedWindowSafely(tab, ordered: .above)
                    }
                }
                previous = tab
                attach(controller, page: page.id)
            }

            // Which tab shows: the page that was in front, in a window this
            // just made or filled. In a window of the project the person
            // already has open, the tab they are looking at stays.
            let front = controller(of: window.front)?.window
            if !wasOpen, !behind, let front {
                front.tabGroup?.selectedWindow = front
            }
            // Not brought in front when asked for behind, open already or
            // not: the core repeats an open order for a project that is
            // (#1703), and that brought it over the control room.
            if number == 0, !behind, inFront || !wasOpen {
                toShow = front ?? firstOpen
            }

            // **The window's place, now that its tabs stand and the one in
            // front is chosen** -- and on every tab of it, the one showing
            // first: each tab is a window of its own, and the one on screen
            // is the one whose frame the person sees. Only for a window
            // this just made; one that was already open is where the
            // person has it.
            if !wasOpen, case .ownWindow(let frame?) = place, let shown = front ?? previous {
                let place = { [weak shown] in
                    guard let shown else { return }
                    let showing = shown.tabGroup?.selectedWindow ?? shown
                    guard !showing.styleMask.contains(.fullScreen) else { return }
                    showing.setFrame(frame, display: true)
                    for tab in shown.tabGroup?.windows ?? [] where tab !== showing {
                        tab.setFrame(frame, display: false)
                    }
                }
                place()
                placements.append(place)
            }
        }

        // Again after this turn of the run loop, when everything each new
        // window put off until it was first shown has run; and once more a
        // little later, for whatever the system does to a window it has
        // just put up. Only after that last time is a save let take frames
        // again: until then the screen is not known to be the project's,
        // and a save that waits loses nothing -- one that does not wrote
        // a new window's place over the person's (`ProjectPages.taken`).
        // The write poked for at the end is the first that may take them,
        // and what it finds is what the file said.
        DispatchQueue.main.async {
            for place in placements { place() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settling) { [weak self] in
            for place in placements { place() }
            guard let self else { return }
            self.opening -= 1
            self.poke(.windowFrame)
        }

        if let toShow {
            let showing = toShow.tabGroup?.selectedWindow ?? toShow
            showing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        for member in liveMembers {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak controller = member.controller] in
                controller?.relabelTabs()
            }
        }
    }

    // MARK: Across a restart

    /// A tab that came back from a restart saying it was in the project
    /// `name` takes its page back -- **if the file has a page for it**
    /// (`ProjectPages.page(sharing:excluding:)` has the rule and why). When
    /// it has none, or the project is gone, the tab is a tab of no project;
    /// a restart is no time for an alert, so that is logged.
    static func restore(_ controller: TerminalController, to name: String, in store: ProjectStore) {
        guard let entry = store.entry(name: name) else {
            logger.warning("a restored tab says it was in project '\(name, privacy: .public)', which is gone; it is in no project")
            return
        }
        do {
            let session = try session(for: entry, in: store)
            let key = store.bindingKey(name: entry.name)
            let names = controller.surfaceTree.compactMap { view -> String? in
                guard let snapshot = view.projectSnapshot, snapshot.project == key else { return nil }
                return snapshot.filename
            }
            let taken = Set(session.liveMembers.map(\.page))
            guard let page = session.pages.page(sharing: names, excluding: taken) else {
                logger.warning("a restored tab says it was in project '\(name, privacy: .public)', whose file has no page for it; it is in no project")
                session.releaseIfNobodyIsLeft()
                return
            }
            session.attach(controller, page: page)
            // The core starts a terminal that came back from a restart with
            // no colour, no shield and workers allowed; the file has what
            // the user set (task 1699).
            let known = session.pages.known
            for view in controller.surfaceTree {
                guard let snapshot = view.projectSnapshot, snapshot.project == key,
                      let was = known[snapshot.filename] else { continue }
                view.handBackProjectMarks(was.marks)
            }
            // The same for a name somebody chose (task 1722): window
            // restoration put it back on screen, pinned, but the core
            // started the terminal with no title of its own -- and its
            // record is what `terminal_list` and the chat read. The tab's
            // own name came back with window restoration
            // (`TerminalRestorableState.titleOverride`), which the core
            // keeps no record of.
            for view in controller.surfaceTree {
                let file = view.projectSnapshot.flatMap { snapshot in
                    snapshot.project == key ? known[snapshot.filename]?.title : nil
                }
                if let chosen = ProjectPaneTitle.afterRestart(host: view.projectTitleLive, file: file) {
                    view.handBackProjectTitle(chosen)
                }
            }
        } catch {
            logger.warning("a restored tab was not put back in project '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Renamed from the settings window

    func projectWillMove() {
        // A pending autosave lands where the project is now, before it moves.
        autosave.flush()
        for member in liveMembers {
            member.controller.stopScrollbackJournals()
        }
    }

    /// Its tabs stay its tabs, under the new name, and their panes go on
    /// journaling into the moved snapshot directory under the same
    /// snapshot names.
    func projectDidMove(to name: String, oldKey: String, key: String, scrollback: URL) {
        self.name = name
        for member in liveMembers {
            member.controller.boundProject = name
            for view in member.controller.surfaceTree {
                guard let snapshot = view.projectSnapshot, snapshot.project == oldKey else { continue }
                view.journalScrollback(.init(project: key, filename: snapshot.filename), in: scrollback)
            }
            member.controller.invalidateRestorableState()
        }
    }
}
