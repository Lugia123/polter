import Foundation

/// The mac host's half of a group's tie to a project that is not shared
/// with Windows (task 1713, `project-link-interface.md` §3): the words, when
/// the "join and link?" question may be put, what the line saying a project
/// was made for a group says, and what undoing it does. Which menu items
/// there are, what a row's right end says and how long the line stays are
/// `ProjectLinkRules`, which both hosts hold; this is only the mac's.
///
/// **Nothing here touches a file, a tab or the core.** It decides; what
/// carries a decision out is `ProjectLinkDesk` (in the app), so all of this
/// runs under `tools/mac-logic-tests`.
enum ProjectLinkPlan {
    // MARK: What a project is, as far as these words need

    /// One saved project, as the host lists it.
    struct Project: Equatable {
        var name: String
        /// The group its file names; nil for none.
        var group: String?
        var savedAt: Date
        var pages: Int
        /// Whether it was saved in a format older than this build's.
        var olderFormat = false
    }

    // MARK: The line saying a project was made for a group (v2 A1)

    /// How the group came to have its project, as the host saw it happen.
    enum Origin: Equatable {
        /// The core's `create`: the steward's tab saved as a new project.
        case created(project: String)
        /// The core's `bind`: the project the steward's tab was a page of,
        /// renamed from `from` to `project` (the same when not renamed).
        case bound(project: String, from: String)
        /// "Join and link": the steward's tab added to `project`.
        case joined(project: String)
        /// "Replace": `project` became the steward's tab, the old kept as
        /// the previous version.
        case replaced(project: String)

        var project: String {
            switch self {
            case .created(let p), .joined(let p), .replaced(let p): return p
            case .bound(let p, _): return p
            }
        }
    }

    /// What the line says. `short`: the copy in the supervisor's own pane,
    /// which may be narrow.
    static func hintText(_ origin: Origin, short: Bool) -> String {
        switch origin {
        case .created(let p):
            return short
                ? String(localized: "Saved as the project \"\(p)\", this group's.", comment: "项目提示条（窄格短句）：自动把总管的标签页存成了项目，参数是项目名")
                : String(localized: "The supervisor's tab was saved as the project \"\(p)\", as this group's project.", comment: "项目提示条：核心让宿主新建了项目，参数是项目名")
        case .bound(let p, let from) where from != p:
            return short
                ? String(localized: "Renamed to \"\(p)\", this group's.", comment: "项目提示条（窄格短句）：把总管所在的项目改名并归这个群，参数是新名字")
                : String(localized: "The supervisor's tab was in the project \"\(from)\", which was renamed \"\(p)\", as this group's project.", comment: "项目提示条：核心让宿主改名并关联，参数依次是原名、新名")
        case .bound(let p, _):
            return short
                ? String(localized: "\"\(p)\" is this group's project now.", comment: "项目提示条（窄格短句）：总管所在的项目归了这个群，没改名，参数是项目名")
                : String(localized: "The project \"\(p)\" the supervisor's tab is in is this group's project now.", comment: "项目提示条：总管所在的项目归了这个群，没改名，参数是项目名")
        case .joined(let p):
            return String(localized: "Joined the project \"\(p)\", this group's.", comment: "项目提示条：用户选了「加入并关联」之后，参数是项目名")
        case .replaced(let p):
            return short
                ? String(localized: "Replaced the project \"\(p)\", this group's.", comment: "项目提示条（窄格短句）：用户选了「替换」之后，参数是项目名")
                : String(localized: "The project \"\(p)\" was replaced with the supervisor's tab, as this group's project. The old one is kept as the previous version.", comment: "项目提示条：用户选了「替换」之后，参数是项目名")
        }
    }

    /// What the line says once it was undone.
    static func undoneText(_ origin: Origin) -> String {
        let back = String(localized: "To change it back, use the group's Project menu.", comment: "项目提示条：撤销之后那句的后半，告诉用户在群右键「项目」里改回")
        let what: String
        switch origin {
        case .created(let p):
            what = String(localized: "Undone: the project \"\(p)\" was moved to the Trash, and this group uses no project.", comment: "项目提示条：撤销了自动新建，参数是项目名")
        case .bound(let p, let from) where from != p:
            what = String(localized: "Undone: the project is called \"\(from)\" again, and this group uses no project.", comment: "项目提示条：撤销了改名并关联，参数是原名")
        case .bound:
            what = String(localized: "Undone: this group uses no project.", comment: "项目提示条：撤销了关联（没改过名）")
        case .joined(let p):
            what = String(localized: "Undone: this page was taken out of the project \"\(p)\", and this group uses no project.", comment: "项目提示条：撤销了加入，参数是项目名")
        case .replaced(let p):
            what = String(localized: "Undone: the project \"\(p)\" is back to its previous version, and this group uses no project.", comment: "项目提示条：撤销了替换，参数是项目名")
        }
        return what + " " + back
    }

    /// What undoing it was stopped by, said in its place.
    static func undoFailedText(_ why: String) -> String {
        String(localized: "Not all of it was undone: \(why)", comment: "项目提示条：撤销没做完，参数是原因")
    }

    /// One thing undoing does, in order.
    enum UndoStep: Equatable {
        /// `project_decline`: first, or the next offer makes it again.
        case decline(group: String)
        /// The tab stops being a page of the project, the file left as it
        /// is: what has to happen before the file can be moved or restored.
        case letGo(project: String)
        case trash(project: String)
        case clearGroup(project: String)
        case rename(project: String, to: String)
        case restorePrevious(project: String)
    }

    /// What undoing `origin` for `group` does (§3.2). Never touches a
    /// running terminal: the tab and its supervisor stay where they are.
    static func undo(_ origin: Origin, group: String) -> [UndoStep] {
        var steps: [UndoStep] = [.decline(group: group)]
        switch origin {
        case .created(let p):
            steps += [.letGo(project: p), .trash(project: p)]
        case .bound(let p, let from):
            steps.append(.clearGroup(project: p))
            if from != p { steps.append(.rename(project: p, to: from)) }
        case .joined(let p):
            // The file as it was before the join, byte for byte: the join's
            // own write kept it as the previous version, and taking the page
            // out instead would write again and rotate it away -- the way
            // back for an old file nothing else has a copy of (brief 9; the
            // supervisor's ruling on the first poltertest run, task 1713).
            steps += [.letGo(project: p), .restorePrevious(project: p)]
        case .replaced(let p):
            steps += [.letGo(project: p), .restorePrevious(project: p)]
        }
        return steps
    }

    /// Whether a new line replaces the one standing for the group. The
    /// core's `bind` that follows a join or a replace is the same event the
    /// person already has a line for -- and an undo for, which undoes more
    /// than the bind's would.
    static func replaces(_ new: Origin, standing: Origin?) -> Bool {
        guard let standing else { return true }
        switch (standing, new) {
        case (.joined(let a), .bound(let b, _)), (.replaced(let a), .bound(let b, _)):
            return a != b
        default:
            return true
        }
    }

    // MARK: When to ask "join and link?" (v2 B)

    /// What is in front of the person.
    enum Front: Equatable {
        case controlRoom
        /// The tab the group's supervisor is in.
        case stewardTab
        case other
    }

    /// The groups asked about in this run, until what the core says of them
    /// changes: one question per moment the core asks, however many times
    /// the window comes back to the front.
    struct Asked: Equatable {
        private(set) var groups: Set<String> = []

        /// The core's `ask` for every group, as the snapshot has it. A group
        /// it no longer asks about may be asked about again when it does.
        mutating func heard(_ asks: [String: Bool]) {
            groups = groups.filter { asks[$0] == true }
        }

        mutating func asked(_ group: String) { groups.insert(group) }

        func has(_ group: String) -> Bool { groups.contains(group) }
    }

    /// Whether the question for `group` may be put now: the core asks
    /// (`project.ask`), the person is there -- the app active, the window
    /// key, and in front of it the control room or the supervisor's own
    /// tab -- and it has not been put since the core started asking.
    /// Selecting the row is not a reason: nothing here reads the selection.
    static func mayAsk(ask: Bool, group: String, presence: Presence, asked: Asked) -> Bool {
        ask && presence.appActive && presence.windowKey && presence.front != .other
            && !presence.sheetShowing && !asked.has(group)
    }

    /// Whether the person is there, as the window in front says.
    struct Presence: Equatable {
        var appActive: Bool
        var windowKey: Bool
        var front: Front
        /// Something is already asked on that window.
        var sheetShowing: Bool
    }

    // MARK: The row's words (§3.4)

    /// The short word at the right end of a group's row for
    /// `ProjectLinkRules.Note.attention`.
    static func rowWord(_ key: String) -> String {
        switch key {
        case "name_taken": return String(localized: "Same-name project", comment: "总控台群行右端：有同名项目挡着，要用户回答")
        case "several": return String(localized: "Two projects", comment: "总控台群行右端：两个项目都说是这个群的")
        case "unreadable": return String(localized: "Project file unreadable", comment: "总控台群行右端：群的项目文件读不出（绑定先留着）")
        default: return String(localized: "Project not made", comment: "总控台群行右端：项目没建成")
        }
    }

    /// The whole sentence for a reason, where there is room for one: the
    /// row's tooltip, the menu's first line, the banner.
    static func whySentence(_ why: String, group: String, blocker: Project?) -> String? {
        switch why {
        case "project_name_taken":
            let name = blocker?.name ?? group
            if let other = blocker?.group, other != group {
                return String(localized: "There is already a project \"\(name)\", and it is the group \"\(other)\"'s.", comment: "项目：同名项目属于别的群，参数依次是项目名、那个群")
            }
            return String(localized: "There is already a project \"\(name)\", in no group.", comment: "项目：群右键「项目」第一行，已有同名项目，参数是项目名")
        case "several_projects":
            return String(localized: "Two projects both say they are this group's.", comment: "项目：两个项目都写着这个群")
        case "project_has_group":
            return String(localized: "The supervisor's tab is in a project that is another group's.", comment: "项目：总管的标签页属于另一个群的项目")
        case "supervisor_has_project":
            return String(localized: "This supervisor is already the supervisor of another group, which has a project. A supervisor looks after one project.", comment: "项目：这个总管已经是另一个有项目的群的总管")
        case "supervisor_of_several":
            return String(localized: "This supervisor looks after several groups with no project, so which this page is for is not known.", comment: "项目：这个总管同时管着几个没项目的群")
        case "other_supervisor":
            return String(localized: "There is more than one supervisor in the group.", comment: "项目：群里不止一个总管")
        case "projects_unknown":
            return String(localized: "Which projects there are is not known yet.", comment: "项目：宿主还没报过项目，菜单里不可点的一行")
        case "project_unreadable":
            return String(localized: "A project file could not be read.", comment: "项目：群的项目文件读不出，绑定先留着（悬停说明）")
        default:
            return nil
        }
    }

    // MARK: The "Project ›" menu's words

    /// The title of one of `ProjectLinkRules.menu`'s items. `project` is
    /// the bound project's name, or the one in the way.
    static func menuTitle(_ item: ProjectLinkRules.Item, group: String, project: String?) -> String {
        let p = project ?? group
        switch item {
        case .openProject: return String(localized: "Open Project \"\(p)\"", comment: "群右键「项目」：打开这个群的项目，参数是项目名")
        case .showInSettings: return String(localized: "Show in Project Settings", comment: "群右键「项目」：在设置的项目页里看这个项目")
        case .unlinkProject: return String(localized: "No Longer This Group's Project…", comment: "群右键「项目」：不再作为这个群的项目（会确认）")
        case .saveSupervisorTab: return String(localized: "Save the Supervisor's Tab as Project \"\(group)\"", comment: "群右键「项目」：把总管的标签页存成和群同名的项目，参数是群名")
        case .linkExisting: return String(localized: "Use an Existing Project", comment: "群右键「项目」：改用已有的项目（子菜单）")
        case .declineProject: return String(localized: "This Group Uses No Project", comment: "群右键「项目」：这个群不用项目")
        case .undeclineProject: return String(localized: "Use a Project for This Group", comment: "群右键「项目」：选过不用项目之后，改回用项目")
        case .joinExisting: return String(localized: "Join and Link", comment: "群右键「项目」/确认框：把总管的标签页加入同名项目并关联")
        case .replaceExisting: return String(localized: "Replace \"\(p)\"…", comment: "群右键「项目」：用总管的标签页替换同名项目（会确认），参数是项目名")
        case .openBlocker: return String(localized: "Open \"\(p)\"", comment: "群右键「项目」：打开挡路的同名项目，参数是项目名")
        case .header(let why): return whySentence(why, group: group, blocker: nil) ?? why
        }
    }

    /// One project in "Use an Existing Project ›": whose it is, and
    /// whether it can be chosen -- one that is another group's cannot.
    struct LinkChoice: Equatable {
        var name: String
        var owner: String
        var enabled: Bool
    }

    static func linkChoices(_ projects: [Project], for group: String) -> [LinkChoice] {
        projects.map { p in
            let owner: String
            if let g = p.group {
                owner = g == group
                    ? String(localized: "This group", comment: "群右键「改用已有的项目」：这个项目已经写着这个群")
                    : String(localized: "Group \(g)", comment: "群右键「改用已有的项目」：这个项目属于别的群，参数是群名")
            } else {
                owner = String(localized: "No group", comment: "群右键「改用已有的项目」：这个项目不属于任何群")
            }
            return LinkChoice(name: p.name, owner: owner, enabled: p.group == nil || p.group == group)
        }
    }

    /// The projects that say they are `group`'s: what `several_projects`
    /// offers to choose between.
    static func candidates(_ projects: [Project], for group: String) -> [Project] {
        projects.filter { $0.group == group }
    }

    /// The name a project in the way is renamed to before another takes
    /// the group's name: "X (old)", and a number after it when that is
    /// taken too.
    static func asideName(_ name: String, taken: (String) -> Bool) -> String {
        let first = String(localized: "\(name) (old)", comment: "项目：关联时给挡路的同名项目改的名字，参数是原名")
        guard taken(first) else { return first }
        var n = 2
        while taken("\(first) \(n)") { n += 1 }
        return "\(first) \(n)"
    }

    /// "Rename X to X (old) and link?"
    static func asideQuestion(_ name: String, to aside: String) -> String {
        String(localized: "Rename \"\(name)\" to \"\(aside)\" and then link?", comment: "项目：关联时撞名，问要不要先把挡路的项目改名，参数依次是原名、新名")
    }

    // MARK: The banner and the question (v1 01c/01d, v2 B1, D)

    /// What a day is said as: "Oct 13" / "10月13日".
    static func day(_ date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    /// "saved Oct 13, 1 page(s)".
    static func facts(_ p: Project, locale: Locale = .current) -> String {
        String(localized: "saved \(day(p.savedAt, locale: locale)), \(String(p.pages)) page(s)", comment: "项目：存的日期和页数，参数依次是日期、页数")
    }

    /// The banner over the supervisor's terminal for a group whose project
    /// was not made (§3.4); nil when there is none to show.
    enum Banner: Equatable {
        /// `project_name_taken`: the question, with the four buttons.
        case nameTaken(text: String, blocker: String)
        /// `several_projects`: each candidate with "Use It".
        case several(text: String, candidates: [Project])
        /// The rest: the sentence, and what can be done in one press.
        case notMade(text: String, saveTab: Bool)
        /// A project kept while a file does not read (task 1807): which
        /// files, so the person knows what to mend. Nothing to press.
        case unreadable(text: String)
    }

    /// `unreadable`: the project files that do not read (task 1807).
    static func banner(why: String, tie: String, group: String, projects: [Project], unreadable: [String],
                       locale: Locale = .current) -> Banner? {
        if tie == "bound", why == "project_unreadable" {
            if unreadable.isEmpty {
                return .unreadable(text: whySentence(why, group: group, blocker: nil) ?? why)
            }
            let files = unreadable.joined(separator: ", ")
            return .unreadable(text: String(localized: "The project file \(files) could not be read, so this group keeps its project as it is. Once the file reads again, the project is used again by itself.", comment: "总控台右栏横幅：群的项目文件读不出，绑定先留着；参数是读不出的文件名"))
        }
        guard tie == "undecided" else { return nil }
        switch why {
        case "project_name_taken":
            let blocker = projects.first { $0.name == group }
            let text: String
            if let blocker, blocker.group == nil {
                text = String(localized: "There is already a project \"\(blocker.name)\" (\(facts(blocker, locale: locale))), in no group. A group's project has the group's name: add the supervisor's tab to it, as this group's project?", comment: "总控台右栏横幅：同名项目挡着，参数依次是项目名、存的日期和页数")
            } else {
                text = whySentence(why, group: group, blocker: blocker) ?? why
            }
            return .nameTaken(text: text, blocker: blocker?.name ?? group)
        case "several_projects":
            return .several(text: whySentence(why, group: group, blocker: nil) ?? why,
                            candidates: candidates(projects, for: group))
        default:
            guard ProjectLinkRules.notMade.contains(why), let text = whySentence(why, group: group, blocker: nil) else { return nil }
            // Saving the tab is a way out only where the tab is in no
            // project: the supervisor's group is not known, or there is
            // more than one supervisor.
            return .notMade(text: text, saveTab: why == "supervisor_of_several" || why == "other_supervisor")
        }
    }

    /// The question's words (v2 B1), for the project in the way.
    struct Question: Equatable {
        var title: String
        var body: String
        var after: String
    }

    static func joinQuestion(_ blocker: Project, group: String, locale: Locale = .current) -> Question {
        Question(
            title: String(localized: "There is already a project \"\(blocker.name)\". Add the supervisor's tab to it?", comment: "撞名确认框标题，参数是项目名"),
            body: String(localized: "A group's project has the group's name. \"\(blocker.name)\" was saved \(day(blocker.savedAt, locale: locale)), has \(String(blocker.pages)) page(s), and is no group's yet.", comment: "撞名确认框正文，参数依次是项目名、日期、页数"),
            after: String(localized: "Once added it is the group \(group)'s project: the supervisor's tab becomes its page \(String(blocker.pages + 1)), and the pages it has stay as they are.", comment: "撞名确认框第二句，参数依次是群名、第几页"))
    }

    /// The second question before "Replace".
    static func replaceQuestion(_ blocker: Project, tab: String, panes: Int) -> Question {
        Question(
            title: String(localized: "Replace \"\(blocker.name)\"?", comment: "替换同名项目的二次确认标题，参数是项目名"),
            body: String(localized: "\"\(blocker.name)\" will be replaced with the tab \"\(tab)\" (\(String(panes)) pane(s)), and the tab is saved to it automatically from then on. The layout replaced is kept as the previous version.", comment: "替换同名项目的二次确认正文，参数依次是项目名、标签页标题、面板数"),
            after: String(localized: "To get the old one back: Settings › Projects, choose \"\(blocker.name)\", Restore Previous Version.", comment: "替换同名项目的二次确认：怎么找回原来的，参数是项目名"))
    }

    // MARK: The tab's menu (§3.5)

    /// The group whose supervisor is in a tab with these terminals; nil
    /// when none is. `stewards`: each group's supervisor's terminal.
    static func supervisorGroup(terminals: [String], stewards: [(group: String, steward: String?)]) -> String? {
        stewards.first { g in g.steward.map(terminals.contains) ?? false }?.group
    }

    /// "Save as Group "X"'s Project…", the tab menu's first item.
    static func saveForGroupTitle(_ group: String) -> String {
        String(localized: "Save as Group \"\(group)\"'s Project…", comment: "标签页右键第一项：这页里有群的总管时，存为这个群的项目，参数是群名")
    }

    /// The save dialog's checkbox.
    static func asGroupsProjectTitle(_ group: String) -> String {
        String(localized: "As group \"\(group)\"'s project", comment: "另存为项目对话框的勾选框：作为这个群的项目，参数是群名")
    }

    /// What saving with the box ticked comes to: the name is the group's,
    /// the file names the group, and the core is told to link the two --
    /// which turns a group that said "no project" back too.
    struct GroupSave: Equatable {
        var name: String
        var group: String?
        var link: Bool
    }

    static func groupSave(typed: String, group: String?, ticked: Bool) -> GroupSave {
        guard let group, ticked else { return GroupSave(name: typed, group: nil, link: false) }
        return GroupSave(name: group, group: group, link: true)
    }
}

/// What the control room's group menu, banner and question ask the app to
/// do about projects. The app's is `ProjectLinkDesk`; a test hands in its
/// own. Every method says nothing back but a refusal's sentence, nil when
/// it was done: what became of it arrives in the next snapshot. Called on
/// the main thread only.
protocol ControlRoomProjectHands: AnyObject {
    /// Every project there is, as the host lists them.
    func projects() -> [ProjectLinkPlan.Project]
    /// The project files that do not read, by name (task 1807).
    func unreadableProjectFiles() -> [String]
    func open(project: String)
    func showInSettings(project: String?)
    /// Asks first, with "also move the project file to the Trash".
    func unlink(group: String, project: String)
    func saveSupervisorTab(group: String) -> String?
    func link(group: String, project: String) -> String?
    func join(group: String, project: String) -> String?
    /// Asks the second question first.
    func replace(group: String, project: String)
    func decline(group: String) -> String?
    func undecline(group: String) -> String?
}

/// The group's "Project ›" submenu, as lines (§3.3): the rule's items in
/// its order, worded, with the lists only the host has -- every project
/// under "Use an Existing Project", the candidates under "two projects".
/// Keys are the rule's ids, with `link:<name>` and `use_this:<name>` for a
/// project picked.
enum ProjectLinkMenu {
    enum Line: Equatable {
        /// A line that says why and does nothing.
        case header(String)
        case item(key: String, title: String, enabled: Bool)
        case submenu(key: String, title: String, [Line])
    }

    static func lines(group: String, tie: String, why: String, project: String?, steward: Bool,
                      projects: [ProjectLinkPlan.Project]) -> [Line] {
        ProjectLinkRules.menu(tie: tie, why: why, steward: steward).flatMap { item -> [Line] in
            let title = ProjectLinkPlan.menuTitle(item, group: group, project: project)
            switch item {
            case .header(let why):
                let blocker = projects.first { $0.name == group }
                var out: [Line] = [.header(ProjectLinkPlan.whySentence(why, group: group, blocker: blocker) ?? title)]
                if why == "several_projects" {
                    out += ProjectLinkPlan.candidates(projects, for: group).map {
                        .item(key: "use_this:" + $0.name, title: $0.name, enabled: true)
                    }
                }
                return out
            case .linkExisting:
                let choices = ProjectLinkPlan.linkChoices(projects, for: group)
                return [.submenu(key: item.id, title: title, choices.map {
                    .item(key: "link:" + $0.name, title: $0.name + "  —  " + $0.owner, enabled: $0.enabled)
                })]
            default:
                return [.item(key: item.id, title: title, enabled: true)]
            }
        }
    }
}
