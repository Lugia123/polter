import Foundation

/// The rules for what the person sees of a group's project and can do about
/// it (task 1713, `project-link-interface.md` §3): the group's "Project ›"
/// menu, the words at the right end of its row, and how long the line
/// saying a project was made for it stays.
///
/// **No AppKit, and the Windows host has the same three** (`project_link.rs`
/// in `polter-control-room`): `tools/control-room-hosts-agree.py` prints
/// both over `src/poltergeist/testdata/project_link_cases.json` and
/// compares them line by line. The core's words for the tie and the reason
/// (`ControlRoom.ProjectOut.tie`, `.why`) are taken as written.
enum ProjectLinkRules {
    /// One item of the group's "Project ›" menu. The host words and wires
    /// each by its id; a header is a line that says why and does nothing.
    enum Item: Equatable {
        case openProject
        case showInSettings
        case unlinkProject
        case saveSupervisorTab
        case linkExisting
        case declineProject
        case undeclineProject
        case joinExisting
        case replaceExisting
        case openBlocker
        case header(String)

        /// The id the hosts agree on.
        var id: String {
            switch self {
            case .openProject: return "open_project"
            case .showInSettings: return "show_in_settings"
            case .unlinkProject: return "unlink_project"
            case .saveSupervisorTab: return "save_supervisor_tab"
            case .linkExisting: return "link_existing"
            case .declineProject: return "decline_project"
            case .undeclineProject: return "undecline_project"
            case .joinExisting: return "join_existing"
            case .replaceExisting: return "replace_existing"
            case .openBlocker: return "open_blocker"
            case .header(let why): return "header:\(why)"
            }
        }
    }

    /// The reasons a tie was not made that the person can do something
    /// about by linking another project (`Projects.Why`).
    static let notMade: Set<String> = ["project_has_group", "supervisor_has_project", "supervisor_of_several", "other_supervisor"]

    /// What the group's "Project ›" menu offers, in order (§3.3). Only what
    /// can be done is listed; a group whose projects are not known yet has
    /// only the line saying so. `steward`: the group has a supervisor on
    /// screen, whose tab could be saved.
    static func menu(tie: String, why: String, steward: Bool) -> [Item] {
        if tie == "bound" { return [.openProject, .showInSettings, .unlinkProject] }
        if tie == "declined" { return [.undeclineProject] }
        switch why {
        case "projects_unknown":
            return [.header(why)]
        case "project_name_taken":
            return [.header(why), .joinExisting, .replaceExisting, .openBlocker, .declineProject]
        case "several_projects":
            // The candidates are the host's to list, under the header.
            return [.header(why), .declineProject]
        default:
            if notMade.contains(why) { return [.header(why), .linkExisting, .declineProject] }
            return steward ? [.saveSupervisorTab, .linkExisting, .declineProject] : [.linkExisting, .declineProject]
        }
    }

    /// What the right end of a group's row says of its project (§3.4).
    enum Note: Equatable {
        case none
        /// The project's name, in the second ink.
        case name(String)
        /// The attention glyph and a short word: there is something to
        /// answer. The word's key: `name_taken`, `several`, `not_made`,
        /// `unreadable`.
        case attention(String)

        var said: String {
            switch self {
            case .none: return "none"
            case .name(let n): return "name:\(n)"
            case .attention(let w): return "attention:\(w)"
            }
        }
    }

    /// What the button that starts a group says: "Open" when the core says
    /// starting opens the group's project, "Start Supervisor" otherwise --
    /// which is also what it says when the core has said nothing of a
    /// project. Here rather than in `ProjectLink` so that the Windows host's
    /// `scene::start_title` is compared with it (task 1756).
    static func startTitle(opensProject: Bool) -> String {
        if opensProject {
            return String(localized: "Open", comment: "总控台：有项目的群，右栏上打开它的项目的主按钮")
        }
        return String(localized: "Start Supervisor", comment: "总控台：没有总管的群，右栏上启动一个总管的主按钮")
    }

    /// Whether the start asks where the supervisor starts: not when it
    /// opens the group's project, whose supervisor's pane has its own
    /// directory (task 1756, so that the Windows host's `scene::asks_directory`
    /// is compared with it).
    static func asksDirectory(opensProject: Bool) -> Bool {
        !opensProject
    }

    /// The sentence under a group's start button: how many pages come back
    /// when it opens the group's project, and what happens to them -- the
    /// count left out when the core does not know it; or, for a group with
    /// no project yet whose supervisor will be offered one when it takes the
    /// group up (`Projects.offer`), that its tab will be saved as one and
    /// that this can be undone (project-link-v2 D, 01 b; task 1713). Nil
    /// otherwise. Here rather than in `ProjectLink` for the same reason as
    /// `startTitle` (task 1756).
    static func startNote(opensProject: Bool, tie: String, why: String, pages: Int?) -> String? {
        if !opensProject, tie == "undecided", ["not_taken_up", "none", "pending"].contains(why) {
            return String(localized: "This group has no project yet, so only the supervisor starts. Once it takes up the group, its tab is saved as a project of the group's name; you are told when it is, and it can be undone.", comment: "总控台：没有项目的群右栏底下那句（总管上岗后会自动存成项目，可撤销）")
        }
        guard opensProject else { return nil }
        guard let pages else {
            return String(localized: "Every page of its project comes back and the supervisor starts in its own pane. The workers' panes come back as terminals only; who is called back is the supervisor's to decide.", comment: "总控台：有项目的群右栏底下那句，不知道页数时")
        }
        return String(localized: "All \(String(pages)) page(s) of its project come back and the supervisor starts in its own pane. The workers' panes come back as terminals only; who is called back is the supervisor's to decide.", comment: "总控台：有项目的群右栏底下那句，参数是项目的页数")
    }

    static func note(tie: String, why: String, name: String?) -> Note {
        // Kept, and its file does not read (task 1807): that, before its name.
        if tie == "bound", why == "project_unreadable" { return .attention("unreadable") }
        if tie == "bound", let name { return .name(name) }
        if tie != "undecided" { return .none }
        switch why {
        case "project_name_taken": return .attention("name_taken")
        case "several_projects": return .attention("several")
        default: return notMade.contains(why) ? .attention("not_made") : .none
        }
    }

    /// How long the line saying a project was made for a group stays
    /// (§3.2): `GroupNote.feedbackSeconds` of being seen -- the window in
    /// front and the line on screen -- added up; time not seen does not
    /// count, and ✕ takes it away at once.
    struct HintClock: Equatable {
        /// Seconds seen so far.
        var seen: Double = 0
        /// When it was last looked at, and whether it was seen then.
        var last: (at: Double, visible: Bool)?
        var closed = false

        static func == (a: HintClock, b: HintClock) -> Bool {
            a.seen == b.seen && a.closed == b.closed && a.last?.at == b.last?.at && a.last?.visible == b.last?.visible
        }

        static var lasts: Double { ControlRoomLook.GroupNote.feedbackSeconds }

        /// Look at it at `at`: the time since the last look counts when it
        /// was seen then.
        mutating func look(at: Double, visible: Bool) {
            if let last, last.visible { seen += max(0, at - last.at) }
            last = (at, visible)
        }

        mutating func close() { closed = true }

        var gone: Bool { closed || seen >= Self.lasts }
        var remaining: Double { gone ? 0 : Self.lasts - seen }
    }
}
