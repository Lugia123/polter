import AppKit
import GhosttyKit
import OSLog

/// The app's side of what it and the core say to each other about projects
/// (`dev-docs/poltergeist/projects.md`): it states every project whenever
/// one changes, does what the core's snapshot orders, and asks the core
/// before a page is taken out or a project renamed.
///
/// **Everything decided is decided in `ProjectLink`**, which has no window
/// in it and is tested without the app: what a statement says, which orders
/// are acted on and what each comes to. This file reads the real tabs,
/// sends, and carries a step out on real files -- and none of that has been
/// run against a core, which is said where this is handed over.
@MainActor
final class ProjectLinker {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "projects")

    /// The one there is, once the app has started.
    private(set) static var shared: ProjectLinker?

    static func start(_ ghostty: Ghostty.App) {
        guard shared == nil else { return }
        shared = ProjectLinker(ghostty)
        ProjectLinkDesk.start(ghostty)
    }

    private let ghostty: Ghostty.App
    private let store = ProjectStore.shared
    private var observers: [NSObjectProtocol] = []
    /// What was last sent, so that the same statement is not sent twice:
    /// the core answers a statement with a snapshot, and a statement per
    /// snapshot would never stop.
    private var lastStated: Data?
    private var restatePending = false
    private var acted: [ProjectLink.Order] = []

    private init(_ ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let center = NotificationCenter.default
        for name in [ProjectStore.didWrite, ProjectStore.bindingDidChange, ProjectStore.listDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.restateSoon() }
            })
        }
        observers.append(center.addObserver(forName: ControlRoomFeed.changed, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshotArrived() }
        })
        // What is on disk when the app starts.
        restateSoon()
    }

    private func send(_ request: Data) -> String? {
        ControlRoomActions.core(ghostty).send(request)
    }

    // MARK: Stating

    /// State the projects on the next turn of the run loop: a save posts
    /// more than one notice, and they are one change.
    func restateSoon() {
        guard !restatePending else { return }
        restatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.restatePending = false
            self?.restate()
        }
    }

    /// State the projects now. For a request about a project the host has
    /// only just written -- a link right after a save (task 1713): sent
    /// before the restatement, it is refused for a project the core has
    /// not heard of yet.
    func restateNow() {
        restate()
    }

    private func stated() -> [ProjectLink.Stated] {
        store.list().map { entry in
            let open = ProjectSession.open(for: entry.name, in: store)?.stated
            return ProjectLink.Stated(
                name: entry.name,
                group: entry.group,
                pages: entry.pageCount,
                open: open?.open,
                supervisor: open?.supervisor,
                workers: open?.workers ?? [])
        }
    }

    private func restate() {
        let request = ProjectLink.statement(stated())
        guard request != lastStated else { return }
        if let refusal = send(request) {
            // Refused whole, and what was said before still stands. Not
            // remembered as said, so the next change says it again.
            Self.logger.warning("the core refused the statement of projects: \(refusal, privacy: .public)")
            return
        }
        lastStated = request
    }

    // MARK: Orders

    private func host() -> ProjectLink.Host {
        var projectOfTab: [String: String] = [:]
        var terminals: Set<String> = []
        for controller in TerminalController.all {
            for view in controller.surfaceTree {
                guard let terminal = ControlRoomLender.terminal(of: view) else { continue }
                terminals.insert(terminal)
                if let project = controller.boundProject { projectOfTab[terminal] = project }
            }
        }
        return ProjectLink.Host(projects: stated(), projectOfTab: projectOfTab, terminals: terminals)
    }

    private func snapshotArrived() {
        let fetch: ControlRoomFeed.Fetch = { [weak ghostty] buffer, capacity in
            guard let app = ghostty?.app else { return 0 }
            return Int(ghostty_app_control_snapshot(app, buffer, UInt(capacity)))
        }
        guard let json = ControlRoomFeed.read(fetch), let told = ProjectLink.told(snapshot: json) else { return }
        ProjectLink.latest = told

        let (toDo, acted) = ProjectLink.fresh(told.orders, acted: self.acted)
        self.acted = acted
        guard !toDo.isEmpty else { return }
        for order in toDo {
            // Read again for each: the one before may have changed it.
            guard let step = ProjectLink.step(for: order, host: host()) else { continue }
            perform(step)
        }
        restateSoon()
    }

    private func controller(holding terminal: String) -> (TerminalController, Ghostty.SurfaceView)? {
        for controller in TerminalController.all {
            for view in controller.surfaceTree where ControlRoomLender.terminal(of: view) == terminal {
                return (controller, view)
            }
        }
        return nil
    }

    private func perform(_ step: ProjectLink.Step) {
        do {
            switch step {
            case .open(let name):
                guard let entry = store.entry(name: name) else {
                    _ = send(ProjectLink.failed(name, .notFound))
                    return
                }
                do {
                    try open(entry)
                } catch ProjectStore.StoreError.notFound {
                    _ = send(ProjectLink.failed(name, .notFound))
                } catch {
                    Self.logger.warning("project '\(name, privacy: .public)' was not opened for the core: \(error.localizedDescription, privacy: .public)")
                    _ = send(ProjectLink.failed(name, .unreadable))
                }

            case .fail(let name, let why):
                _ = send(ProjectLink.failed(name, why))

            case .create(let name, let group, let terminal):
                guard let (controller, view) = controller(holding: terminal) else { return }
                try ProjectSession.save([controller], as: name, keeping: .always, in: store)
                guard let session = controller.projectSession else { return }
                session.setGroup(group)
                session.makeSupervisor(view)
                // Made without the person asking: say so, with an undo
                // (task 1713, v2 A1).
                ProjectLinkDesk.shared?.made(.created(project: name), for: group)

            case .bind(let project, let group, let terminal, let to):
                guard let (controller, view) = controller(holding: terminal),
                      let session = controller.projectSession, session.name == project
                else { return }
                session.setGroup(group)
                session.makeSupervisor(view)
                if let to, let entry = store.entry(name: project) {
                    try store.rename(entry, to: to)
                }
                // The name it had is what undoing gives back.
                ProjectLinkDesk.shared?.made(.bound(project: to ?? project, from: project), for: group)

            case .setGroup(let project, let group):
                if let session = ProjectSession.open(for: project, in: store) {
                    session.setGroup(group)
                } else if let entry = store.entry(name: project) {
                    try store.setGroup(entry, to: group)
                }

            case .rename(let project, let to):
                guard let entry = store.entry(name: project) else { return }
                try store.rename(entry, to: to)

            case .addTab(let project, let terminal):
                guard let (controller, _) = controller(holding: terminal), let entry = store.entry(name: project) else { return }
                try ProjectSession.add(controller, to: entry, in: store)

            case .seat(let project, let terminal):
                guard let (controller, view) = controller(holding: terminal), let entry = store.entry(name: project) else { return }
                if controller.projectSession == nil {
                    try ProjectSession.add(controller, to: entry, in: store)
                }
                guard let session = controller.projectSession, session.name == project else { return }
                session.makeSupervisor(view)
            }
        } catch {
            Self.logger.warning("an order from the core was not carried out: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open a project the core asked for where the control room puts a tab
    /// the application asked for (`ControlRoomRules.orderedProjectTab`):
    /// beside it and behind it while it is in front; with no control room
    /// on screen, by the frames in its file and beside the terminal in
    /// front.
    private func open(_ entry: ProjectStore.Entry) throws {
        let room = NSApp.windows.compactMap { $0.windowController as? ControlRoomController }.first
        if let room {
            try room.loadProjectWhereTabsGo(entry, orderedByCore: true)
        } else {
            try TerminalController.load(
                entry, ghostty: ghostty, into: nil, beside: TerminalController.preferredParent?.window)
        }
    }

    // MARK: Asking first

    /// A refusal as a person reads it.
    struct Refused: LocalizedError {
        let name: String
        var errorDescription: String? { ControlRoomActions.Refusal(name: name).message }
    }

    /// Ask the core whether `controller`'s page may be taken out of its
    /// project. Throws what it says when it may not; with no core to ask,
    /// or a core that knows nothing of the page, it may.
    func askToRemove(_ controller: TerminalController) throws {
        guard let terminal = controller.surfaceTree.lazy.compactMap(ControlRoomLender.terminal(of:)).first else { return }
        let refusal = send(ProjectLink.askRemove(terminal: terminal))
        if !ProjectLink.mayRemove(refusal: refusal), let refusal { throw Refused(name: refusal) }
    }

    /// Rename `entry` to `name`, asking the core first. A project that is a
    /// group's is renamed by the order that follows the group's own rename
    /// (`ProjectLink.renames`); any other is renamed here and now.
    @discardableResult
    func rename(_ entry: ProjectStore.Entry, to name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != entry.name else { return entry.name }
        if let refusal = send(ProjectLink.askRename(from: entry.name, to: trimmed)) {
            // Nothing stated yet is the core being behind, not a refusal.
            if refusal != "ProjectsUnknown" && refusal != "NoSuchProject" { throw Refused(name: refusal) }
        }
        switch ProjectLink.renames(group: entry.group) {
        case .theApp: return try store.rename(entry, to: trimmed).name
        case .anOrder: return trimmed
        }
    }
}
