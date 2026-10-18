import Foundation

/// What the app and the core say to each other about projects, and what the
/// app does about what it is told. The contract is
/// `dev-docs/poltergeist/projects.md`; this is the app's half of it, with
/// no window and no terminal in it, so all of it can be run without the app
/// (`tools/mac-logic-tests`). The half that reads real tabs and acts on
/// real files is `ProjectLinker.swift`.
///
/// Two directions:
///
/// - **The app states** every project it knows, whole, every time
///   (`statement`), and asks before two things a person does: taking a page
///   out and renaming.
/// - **The core orders**: its snapshot carries a list of things it wants
///   done (`Told.orders`). They are a statement of what is not yet so, not
///   events: the same order is there in every snapshot until the app's next
///   statement shows it done.
enum ProjectLink {
    // MARK: What the app says

    /// One project as it is stated to the core. Every one of these is
    /// written every time: to the core a key left out is not "none", it is
    /// a sentence it refuses whole.
    struct Stated: Equatable {
        let name: String
        /// The group the file names; nil when it names none.
        let group: String?
        /// How many pages it has, open or not.
        let pages: Int
        /// When it is open: the terminals on each open page, in the pages'
        /// order. Nil when none of its pages is open.
        let open: [[String]]?
        /// When it is open: the terminal in the pane the file marks as the
        /// supervisor's. Nil when it is not open, marks none, or that pane
        /// is on a page that is not open.
        let supervisor: String?
        /// The terminals in panes the file marks as opened by the
        /// supervisor. Empty when there are none or the project is not
        /// open.
        let workers: [String]
    }

    /// A terminal's number as the core writes it: `0x` and sixteen hex
    /// digits (`ghostty_surface_poltergeist_id`).
    static func terminal(_ id: UInt64) -> String {
        let hex = String(id, radix: 16)
        return "0x" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// `{"act":"projects","list":[…]}`: everything, replacing whatever was
    /// said before. Written by hand, in one key order, so that what is sent
    /// is a string a test can hold against the core's reader.
    static func statement(_ list: [Stated]) -> Data {
        var out = "{\"act\":\"projects\",\"list\":["
        for (i, project) in list.enumerated() {
            if i > 0 { out += "," }
            out += "{\"name\":" + quoted(project.name)
            out += ",\"group\":" + (project.group.map(quoted) ?? "null")
            out += ",\"pages\":\(project.pages)"
            out += ",\"open\":"
            if let open = project.open {
                out += "[" + open.map { "[" + $0.map(quoted).joined(separator: ",") + "]" }.joined(separator: ",") + "]"
            } else {
                out += "null"
            }
            out += ",\"supervisor\":" + (project.supervisor.map(quoted) ?? "null")
            out += ",\"workers\":[" + project.workers.map(quoted).joined(separator: ",") + "]}"
        }
        out += "]}"
        return Data(out.utf8)
    }

    /// Why a project the core asked for was not opened.
    enum Failure: String, Equatable {
        case notFound = "not_found"
        case unreadable
    }

    static func failed(_ name: String, _ why: Failure) -> Data {
        Data(("{\"act\":\"project_failed\",\"name\":" + quoted(name) + ",\"why\":" + quoted(why.rawValue) + "}").utf8)
    }

    /// Asked **before** a page is taken out of its project; `terminal` is
    /// any terminal on that page.
    static func askRemove(terminal: String) -> Data {
        Data(("{\"act\":\"project_remove\",\"terminal\":" + quoted(terminal) + "}").utf8)
    }

    /// Asked **before** a project is renamed.
    static func askRename(from: String, to: String) -> Data {
        Data(("{\"act\":\"project_rename\",\"from\":" + quoted(from) + ",\"to\":" + quoted(to) + "}").utf8)
    }

    private static func quoted(_ text: String) -> String {
        var out = ""
        ProjectFileWriting.string(text, into: &out)
        return out
    }

    /// What an answer to `askRemove` means for the person's act.
    ///
    /// Only the refusal that is about the page stops it. The core saying it
    /// knows nothing of projects yet, or does not find the terminal on any
    /// page, is the core being behind the app -- not a reason the page
    /// cannot be taken out, and the next statement puts it right.
    static func mayRemove(refusal: String?) -> Bool {
        switch refusal {
        case nil, "ProjectsUnknown", "NotInAProject": return true
        default: return false
        }
    }

    /// Who renames the files after the core has allowed a rename.
    enum Renames: Equatable {
        /// The app, now: the project is no group's.
        case theApp
        /// The core's order will: the project is a group's, the group has
        /// taken the new name, and a `rename` order follows.
        case anOrder
    }

    static func renames(group: String?) -> Renames {
        group == nil ? .theApp : .anOrder
    }

    // MARK: What the core says

    struct Order: Equatable {
        enum Kind: String, Equatable, CaseIterable {
            case open
            case create
            case bind
            case setGroup = "set_group"
            case rename
            case addTab = "add_tab"
        }

        let kind: Kind
        let project: String
        let group: String?
        let to: String?
        let terminal: String?
    }

    /// What a group's row says of its project.
    struct GroupProject: Equatable {
        enum Start: String, Equatable {
            /// Starting the group opens its project.
            case project
            /// Starting it opens a tab in a directory, as before projects.
            case directory
        }

        let tie: String
        let name: String?
        /// Nil when the app has not stated its projects: **not known is not
        /// zero**.
        let pages: Int?
        /// Nil for the same reason: not known is not "closed".
        let open: Bool?
        let start: Start
        let why: String
        /// Whether the host should ask now whether to join the project in
        /// the way (`project-link-interface.md` §2). Always written by a
        /// core that knows it; false from one before it did.
        var ask = false
    }

    struct Told: Equatable {
        /// Whether the core has heard a statement at all.
        var known: Bool
        var orders: [Order]
        /// By group name.
        var groups: [String: GroupProject]
    }

    /// The project part of a snapshot. Nil when the snapshot is not one --
    /// and an order of a kind this build does not know is left out rather
    /// than taken for one it does.
    static func told(snapshot: Data) -> Told? {
        guard let top = (try? JSONSerialization.jsonObject(with: snapshot)) as? [String: Any] else { return nil }
        var told = Told(known: top["projects_known"] as? Bool ?? false, orders: [], groups: [:])
        for raw in top["project_orders"] as? [[String: Any]] ?? [] {
            guard let kind = (raw["order"] as? String).flatMap(Order.Kind.init(rawValue:)),
                  let project = raw["project"] as? String
            else { continue }
            told.orders.append(Order(
                kind: kind, project: project,
                group: raw["group"] as? String, to: raw["to"] as? String, terminal: raw["terminal"] as? String))
        }
        for row in top["groups"] as? [[String: Any]] ?? [] {
            guard let name = row["name"] as? String, let project = row["project"] as? [String: Any],
                  let start = (project["start"] as? String).flatMap(GroupProject.Start.init(rawValue:))
            else { continue }
            told.groups[name] = GroupProject(
                tie: project["tie"] as? String ?? "",
                name: project["name"] as? String,
                pages: project["pages"] as? Int,
                open: project["open"] as? Bool,
                start: start,
                why: project["why"] as? String ?? "",
                ask: project["ask"] as? Bool ?? false)
        }
        return told
    }

    // MARK: Who is in a pane

    /// What the core's snapshot says of one terminal (`terminals[].who`):
    /// who is working in it, and which terminal's agent opened it.
    struct Who: Equatable {
        enum Kind: Equatable {
            /// The core could not tell.
            case unknown
            /// Nobody: no agent, and the shell at its prompt.
            case none
            case agent
        }

        let kind: Kind
        /// For an agent, each as the core wrote it: empty is that part not
        /// known. Nil for the other two.
        let role: String?
        let cli: String?
        let session: String?
        /// The supervisor this one was opened for as a worker, in this run
        /// of the app (the snapshot's `who.worker_of`); nil when it was not,
        /// or it was opened before the app started. Not "who opened it": a
        /// supervisor's own split is opened by it and is not a worker's
        /// pane (#1498).
        let workerOf: String?
    }

    /// What a save writes of a pane, given what the core says of its
    /// terminal.
    ///
    /// - The core's three answers are the file's three, word for word. A
    ///   terminal the snapshot does not have is one nothing can be said of.
    /// - **Whether it is the supervisor is not said here**: that is the
    ///   project's own mark (`ProjectPages.makeSupervisor`), which a save
    ///   keeps (`ProjectNode.keepingWhatTheFileKnew`).
    /// - The pane is one the supervisor opened when it was opened as a
    ///   worker of the terminal in the project's supervisor pane now. With no
    ///   supervisor's terminal to compare with -- its page is closed, or
    ///   the project has none -- that cannot be told, which is not "no":
    ///   the file's mark stays.
    static func pane(_ who: Who?, supervisor: String?) -> (agent: ProjectAgent, bySupervisor: Bool) {
        guard let who else { return (.unknown, false) }
        let agent: ProjectAgent
        switch who.kind {
        case .unknown: agent = .unknown
        case .none: agent = .none
        case .agent:
            agent = .agent(role: who.role ?? "", cli: who.cli ?? "", session: who.session ?? "", supervisor: false)
        }
        return (agent, supervisor != nil && who.workerOf == supervisor)
    }

    /// What the core last said. Kept here, where the control room's views
    /// can read it without the half of the app that holds terminals; set by
    /// `ProjectLinker` at every snapshot.
    static var latest: Told?

    // MARK: What the app does about an order

    /// What the app has, as far as an order needs to know.
    struct Host: Equatable {
        /// Every project, as it was last stated.
        var projects: [Stated]
        /// The project each terminal's tab is a page of.
        var projectOfTab: [String: String]
        /// The terminals there are, in tabs of any project or none.
        var terminals: Set<String>

        func project(_ name: String) -> Stated? {
            projects.first { $0.name == name }
        }
    }

    enum Step: Equatable {
        case open(String)
        /// Say that it was not opened.
        case fail(String, Failure)
        /// Save the tab `terminal` is in as a new project, of `group`, with
        /// that pane its supervisor's.
        case create(name: String, group: String, terminal: String)
        /// Make a project that has no group the project of `group`, the
        /// pane of `terminal` its supervisor's -- and then give it the name
        /// `to`, when that is not its name.
        case bind(project: String, group: String, terminal: String, to: String?)
        case setGroup(project: String, group: String?)
        case rename(project: String, to: String)
        case addTab(project: String, terminal: String)
    }

    /// What to do about `order`, or nil when there is nothing to do: it is
    /// so already, or it cannot be done from here.
    ///
    /// **An order done twice must not do anything the second time.** The
    /// core repeats every order until the app's statement shows it done, so
    /// each is checked against what the app has before anything is
    /// touched.
    static func step(for order: Order, host: Host) -> Step? {
        switch order.kind {
        case .open:
            guard host.project(order.project) != nil else { return .fail(order.project, .notFound) }
            return .open(order.project)

        case .create:
            guard let group = order.group, let terminal = order.terminal else { return nil }
            // A project by that name is there: made already, or somebody
            // else's -- either way not one to make again or write over.
            guard host.project(order.project) == nil else { return nil }
            // Its tab has to be there, and a page of no project.
            guard host.terminals.contains(terminal), host.projectOfTab[terminal] == nil else { return nil }
            return .create(name: order.project, group: group, terminal: terminal)

        case .bind:
            guard let group = order.group, let terminal = order.terminal,
                  let project = host.project(order.project)
            else { return nil }
            // Only a project that is no group's: one that has a group is
            // that group's, whatever is asked.
            guard project.group == nil || project.group == group else { return nil }
            guard host.projectOfTab[terminal] == order.project else { return nil }
            let to = order.to.flatMap { $0 == order.project || host.project($0) != nil ? nil : $0 }
            if project.group == group, project.supervisor == terminal, to == nil { return nil }
            return .bind(project: order.project, group: group, terminal: terminal, to: to)

        case .setGroup:
            guard let project = host.project(order.project), project.group != order.group else { return nil }
            return .setGroup(project: order.project, group: order.group)

        case .rename:
            guard let to = order.to, to != order.project else { return nil }
            // Gone and the new name there: done. The new name taken while
            // the old is still there: not this app's to settle.
            guard host.project(order.project) != nil, host.project(to) == nil else { return nil }
            return .rename(project: order.project, to: to)

        case .addTab:
            guard let terminal = order.terminal, host.project(order.project) != nil else { return nil }
            guard host.terminals.contains(terminal), host.projectOfTab[terminal] == nil else { return nil }
            return .addTab(project: order.project, terminal: terminal)
        }
    }

    /// Which orders to act on now, given the ones acted on already.
    ///
    /// An order is acted on once for as long as it stays in the list.
    /// Checking each against what the app has stops the ones that are
    /// done; this stops the ones that cannot be -- an `open` whose project
    /// has no supervisor's pane stays in the list for as long as the core
    /// waits, and opening it again at every snapshot would pull its windows
    /// in front of the person some times a second. An order that goes away
    /// and comes back is a new one.
    static func fresh(_ orders: [Order], acted: [Order]) -> (toDo: [Order], acted: [Order]) {
        let still = acted.filter(orders.contains)
        let toDo = orders.filter { !still.contains($0) }
        return (toDo, still + toDo)
    }

    // MARK: The control room's start

    /// What the button that starts a group says: it opens the group's
    /// project when the core says starting does that, and starts a
    /// supervisor in a directory otherwise -- which is also what it says
    /// when the core has said nothing of a project.
    static func startTitle(_ project: GroupProject?) -> String {
        ProjectLinkRules.startTitle(opensProject: project?.start == .project)
    }

    /// The sentence under a group that has a project and no supervisor
    /// running: how many pages come back, and what happens to them. Nil
    /// when starting does not open a project. The count is left out when
    /// the core does not know it.
    static func startNote(_ project: GroupProject?) -> String? {
        guard let project else { return nil }
        return ProjectLinkRules.startNote(opensProject: project.start == .project, tie: project.tie, why: project.why, pages: project.pages)
    }
}
