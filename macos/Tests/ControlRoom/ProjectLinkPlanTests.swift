import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The mac's half of a group's tie to a project (task 1713): the four acts
/// as the core reads them, `ask` read from a snapshot, when the question may
/// be put, which line says what for which origin, what undoing does, the
/// "Project ›" submenu and where its items go.
///
/// **What these are not.** That the desk saves, trashes or renames a real
/// file, that a sheet appears on a window, that the line is drawn over a
/// pane -- those are in the app (`ProjectLinkDesk`, `PaneFrameSplit`) and
/// nothing here starts it.
@MainActor
struct ProjectLinkPlanTests {
    typealias Plan = ProjectLinkPlan

    // MARK: The four acts

    private func bytes(_ act: ControlRoomActions.Act) throws -> String {
        var sent: Data?
        try ControlRoomActions { sent = $0; return nil }.perform(act)
        let data = try #require(sent)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func theFourActsAreWrittenAsTheCoreReadsThem() throws {
        // `ControlAct.zig`'s own examples, byte for byte.
        let decline = try bytes(.projectDecline(group: "notes"))
        #expect(decline == #"{"act":"project_decline","group":"notes"}"#)
        let undecline = try bytes(.projectUndecline(group: "notes"))
        #expect(undecline == #"{"act":"project_undecline","group":"notes"}"#)
        let link = try bytes(.projectLink(group: "notes", project: "scratch"))
        #expect(link == #"{"act":"project_link","group":"notes","project":"scratch"}"#)
        let notNow = try bytes(.projectNotNow(group: "notes"))
        #expect(notNow == #"{"act":"project_not_now","group":"notes"}"#)
    }

    @Test func aLinkRefusedForTheNameIsThrownByThatName() {
        let actions = ControlRoomActions { _ in "ProjectNameTaken" }
        #expect(throws: ControlRoomActions.Refusal(name: "ProjectNameTaken")) {
            try actions.perform(.projectLink(group: "notes", project: "scratch"))
        }
    }

    // MARK: `ask`

    @Test func askIsReadFromTheGroupsProject() throws {
        let json = #"""
        {"groups":[
          {"name":"a","project":{"tie":"undecided","start":"directory","why":"project_name_taken","ask":true}},
          {"name":"b","project":{"tie":"undecided","start":"directory","why":"project_name_taken","ask":false}},
          {"name":"c","project":{"tie":"undecided","start":"directory","why":"none"}}]}
        """#
        let told = try #require(ProjectLink.told(snapshot: Data(json.utf8)))
        let a = told.groups["a"]?.ask
        #expect(a == true)
        let b = told.groups["b"]?.ask
        #expect(b == false)
        // A core from before it said: not asked.
        let c = told.groups["c"]?.ask
        #expect(c == false)
    }

    // MARK: When to ask

    @Test func theQuestionWaitsForThePersonAndIsPutOnce() {
        var asked = Plan.Asked()
        func may(_ ask: Bool = true, active: Bool = true, key: Bool = true, front: Plan.Front = .controlRoom,
                 sheet: Bool = false) -> Bool {
            Plan.mayAsk(ask: ask, group: "polter",
                        presence: .init(appActive: active, windowKey: key, front: front, sheetShowing: sheet),
                        asked: asked)
        }
        #expect(may())
        #expect(may(front: .stewardTab))
        // The core does not ask; or the person is not there.
        #expect(!may(false))
        #expect(!may(active: false))
        #expect(!may(key: false))
        #expect(!may(front: .other))
        #expect(!may(sheet: true))
        // Put once: not again while the core keeps asking.
        asked.asked("polter")
        #expect(!may())
        asked.heard(["polter": true])
        #expect(!may())
        // The core stopped asking, then asked again: a new moment.
        asked.heard(["polter": false])
        #expect(may())
    }

    // MARK: The line

    @Test func eachOriginHasItsOwnLine() {
        let created = Plan.hintText(.created(project: "notes"), short: false)
        #expect(created.contains("saved as the project \"notes\""))
        let createdShort = Plan.hintText(.created(project: "notes"), short: true)
        #expect(createdShort != created)
        let renamed = Plan.hintText(.bound(project: "notes", from: "scratch"), short: false)
        #expect(renamed.contains("\"scratch\"") && renamed.contains("\"notes\""))
        let kept = Plan.hintText(.bound(project: "notes", from: "notes"), short: false)
        #expect(!kept.contains("renamed"))
        let joined = Plan.hintText(.joined(project: "polter"), short: false)
        #expect(joined.hasPrefix("Joined the project \"polter\""))
        let replaced = Plan.hintText(.replaced(project: "polter"), short: false)
        #expect(replaced.contains("previous version"))
        let undone = Plan.undoneText(.created(project: "notes"))
        #expect(undone.contains("Trash") && undone.contains("Project menu"))
    }

    @Test func undoingDeclinesFirstAndThenReversesWhatWasDone() {
        let created = Plan.undo(.created(project: "n"), group: "g")
        #expect(created == [.decline(group: "g"), .letGo(project: "n"), .trash(project: "n")])
        let bound = Plan.undo(.bound(project: "n", from: "s"), group: "g")
        #expect(bound == [.decline(group: "g"), .clearGroup(project: "n"), .rename(project: "n", to: "s")])
        let boundNoRename = Plan.undo(.bound(project: "n", from: "n"), group: "g")
        #expect(boundNoRename == [.decline(group: "g"), .clearGroup(project: "n")])
        let joined = Plan.undo(.joined(project: "p"), group: "g")
        // Restored, not taken out: taking the page out writes again, and the
        // file from before the join is rotated out of `.prev` for good.
        #expect(joined == [.decline(group: "g"), .letGo(project: "p"), .restorePrevious(project: "p")])
        let replaced = Plan.undo(.replaced(project: "p"), group: "g")
        #expect(replaced == [.decline(group: "g"), .letGo(project: "p"), .restorePrevious(project: "p")])
    }

    @Test func theBindAfterAJoinKeepsTheJoinsLine() {
        let afterJoin = Plan.replaces(.bound(project: "p", from: "p"), standing: .joined(project: "p"))
        #expect(!afterJoin)
        let afterReplace = Plan.replaces(.bound(project: "p", from: "p"), standing: .replaced(project: "p"))
        #expect(!afterReplace)
        let another = Plan.replaces(.bound(project: "q", from: "q"), standing: .joined(project: "p"))
        #expect(another)
        let none = Plan.replaces(.created(project: "p"), standing: nil)
        #expect(none)
    }

    @Test func theLineGoesAfterEightSecondsSeenAndUndoSaysWhatItDid() {
        let hints = ProjectHints()
        var said: [String] = []
        var undone: [(String, Plan.Origin)] = []
        var clock = 0.0
        hints.announce = { said.append($0) }
        hints.now = { clock }
        hints.undoer = { undone.append(($0, $1)); return nil }

        hints.show(.joined(project: "polter"), for: "polter")
        #expect(said.count == 1)
        // The core's bind for the same join brings no second line.
        hints.show(.bound(project: "polter", from: "polter"), for: "polter")
        #expect(said.count == 1)
        #expect(hints.hint(for: "polter")?.origin == .joined(project: "polter"))

        // Away for a minute: no time counted.
        clock = 60
        hints.tick(at: clock, visible: { _ in false })
        #expect(hints.hint(for: "polter") != nil)
        hints.tick(at: 67, visible: { _ in true })
        hints.tick(at: 67.5, visible: { _ in true })
        #expect(hints.hint(for: "polter") != nil)

        hints.undo("polter")
        #expect(undone.map(\.0) == ["polter"])
        let state = hints.hint(for: "polter")?.state
        #expect(state == .undone(Plan.undoneText(.joined(project: "polter"))))
        #expect(said.count == 2)
        // The undone line has a clock of its own.
        hints.tick(at: 68, visible: { _ in true })
        hints.tick(at: 75, visible: { _ in true })
        #expect(hints.hint(for: "polter") != nil)
        hints.tick(at: 76, visible: { _ in true })
        #expect(hints.hint(for: "polter") == nil)
    }

    @Test func closingTakesItAwayAtOnceFromBothCopies() {
        let hints = ProjectHints()
        hints.announce = { _ in }
        hints.show(.created(project: "n"), for: "g")
        hints.stewards = ["g": "0x1"]
        #expect(hints.hint(inPaneOf: "0x1") === hints.hint(for: "g"))
        #expect(hints.hint(inPaneOf: "0x2") == nil)
        hints.close("g")
        #expect(hints.hint(for: "g") == nil)
        #expect(hints.hint(inPaneOf: "0x1") == nil)
    }

    // MARK: The banner

    private let day = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func theBannerIsForWhatWasNotMade() {
        let projects = [Plan.Project(name: "polter", group: nil, savedAt: day, pages: 1)]
        let taken = Plan.banner(why: "project_name_taken", tie: "undecided", group: "polter", projects: projects, unreadable: [])
        guard case .nameTaken(let text, let blocker) = taken else { Issue.record("no banner"); return }
        #expect(blocker == "polter")
        #expect(text.contains("1 page(s)"))
        let two = [Plan.Project(name: "a", group: "g", savedAt: day, pages: 1),
                   Plan.Project(name: "b", group: "g", savedAt: day, pages: 2),
                   Plan.Project(name: "c", group: nil, savedAt: day, pages: 1)]
        let several = Plan.banner(why: "several_projects", tie: "undecided", group: "g", projects: two, unreadable: [])
        guard case .several(_, let candidates) = several else { Issue.record("no banner"); return }
        #expect(candidates.map(\.name) == ["a", "b"])
        let many = Plan.banner(why: "supervisor_of_several", tie: "undecided", group: "g", projects: [], unreadable: [])
        #expect(many.map { if case .notMade(_, let save) = $0 { return save } else { return false } } == true)
        let other = Plan.banner(why: "project_has_group", tie: "undecided", group: "g", projects: [], unreadable: [])
        #expect(other.map { if case .notMade(_, let save) = $0 { return save } else { return true } } == false)
        #expect(Plan.banner(why: "none", tie: "bound", group: "g", projects: [], unreadable: []) == nil)
        #expect(Plan.banner(why: "not_taken_up", tie: "undecided", group: "g", projects: [], unreadable: []) == nil)
        #expect(Plan.banner(why: "declined", tie: "declined", group: "g", projects: [], unreadable: []) == nil)
        // Task 1807: a project kept while a file does not read names the
        // files, and is not a "not made".
        let kept = Plan.banner(why: "project_unreadable", tie: "bound", group: "g", projects: [],
                               unreadable: ["g.json", "notes.json"])
        if case .unreadable(let text) = kept {
            #expect(text.contains("g.json, notes.json"))
        } else {
            Issue.record("expected the unreadable banner, got \(String(describing: kept))")
        }
        #expect(ProjectLinkRules.note(tie: "bound", why: "project_unreadable", name: "g") == .attention("unreadable"))
        #expect(ProjectLinkRules.note(tie: "bound", why: "none", name: "g") == .name("g"))
    }

    /// Task 1830: on a row whose words fill the line, "Project file
    /// unreadable" is what stays and the words give way; the project's name
    /// is what goes -- the Windows host's `Side::Trail` and `Side::Squeezed`.
    /// The row's words are at the default priority, 0.
    @Test func somethingToAnswerKeepsItsRoomAndANameGivesWay() {
        let words = 0.0
        let unreadable = ProjectLinkRules.note(tie: "bound", why: "project_unreadable", name: "g")
        #expect(ProjectLinkRules.notePriority(unreadable) > words)
        for why in ["project_name_taken", "several_projects", "project_has_group"] {
            let ask = ProjectLinkRules.note(tie: "undecided", why: why, name: nil)
            #expect(ProjectLinkRules.notePriority(ask) > words, "\(why)")
        }
        #expect(ProjectLinkRules.notePriority(.name("web")) < words)
        #expect(ProjectLinkRules.notePriority(.none) == words)
    }

    // MARK: The submenu

    @Test func useAnExistingProjectSaysWhoseEachIsAndGreysAnotherGroups() {
        let projects = [Plan.Project(name: "web", group: "web", savedAt: day, pages: 1),
                        Plan.Project(name: "scratch", group: nil, savedAt: day, pages: 1)]
        let lines = ProjectLinkMenu.lines(group: "notes", tie: "undecided", why: "not_taken_up", project: nil,
                                          steward: true, projects: projects)
        guard lines.count == 3, case .submenu(let key, _, let inner) = lines[1] else {
            Issue.record("\(lines)")
            return
        }
        #expect(key == "link_existing")
        let enabled = inner.map { if case .item(_, _, let on) = $0 { return on } else { return false } }
        #expect(enabled == [false, true])
        let keys = inner.map { if case .item(let k, _, _) = $0 { return k } else { return "" } }
        #expect(keys == ["link:web", "link:scratch"])
        if case .item(let first, _, _) = lines[0] { #expect(first == "save_supervisor_tab") }
    }

    @Test func twoProjectsListsTheCandidatesUnderTheHeader() {
        let projects = [Plan.Project(name: "a", group: "g", savedAt: day, pages: 1),
                        Plan.Project(name: "b", group: "g", savedAt: day, pages: 1)]
        let lines = ProjectLinkMenu.lines(group: "g", tie: "undecided", why: "several_projects", project: nil,
                                          steward: true, projects: projects)
        let keys = lines.map { line -> String in
            switch line {
            case .header: return "header"
            case .item(let k, _, _): return k
            case .submenu(let k, _, _): return k
            }
        }
        #expect(keys == ["header", "use_this:a", "use_this:b", "decline_project"])
    }

    /// Where each item goes, through the model, to the app's hands.
    private final class Hands: ControlRoomProjectHands {
        var did: [String] = []
        var refuse: String?
        func projects() -> [ProjectLinkPlan.Project] { [] }
        func unreadableProjectFiles() -> [String] { [] }
        func open(project: String) { did.append("open \(project)") }
        func showInSettings(project: String?) { did.append("settings \(project ?? "-")") }
        func unlink(group: String, project: String) { did.append("unlink \(group) \(project)") }
        func saveSupervisorTab(group: String) -> String? { did.append("save \(group)"); return refuse }
        func link(group: String, project: String) -> String? { did.append("link \(group) \(project)"); return refuse }
        func join(group: String, project: String) -> String? { did.append("join \(group) \(project)"); return refuse }
        func replace(group: String, project: String) { did.append("replace \(group) \(project)") }
        func decline(group: String) -> String? { did.append("decline \(group)"); return refuse }
        func undecline(group: String) -> String? { did.append("undecline \(group)"); return refuse }
    }

    @Test func eachItemGoesToItsHand() throws {
        let center = NotificationCenter()
        let json = Array(try ControlRoomListTests.fixture())
        let feed = ControlRoomFeed(center: center) { buffer, capacity in
            if let buffer, json.count + 1 <= capacity {
                for (i, byte) in json.enumerated() { buffer[i] = CChar(bitPattern: byte) }
                buffer[json.count] = 0
            }
            return json.count
        }
        let model = ControlRoomModel(feed: feed)
        center.post(name: ControlRoomFeed.changed, object: nil)
        let hands = Hands()
        model.projectHands = hands
        var row = try #require(model.list?.rows.first { $0.alone == nil })
        row.facts?.project = "web"
        let g = row.id
        for key in ["open_project", "show_in_settings", "unlink_project", "save_supervisor_tab", "link:scratch",
                    "use_this:b", "join_existing", "replace_existing", "open_blocker", "decline_project",
                    "undecline_project"] {
            model.chooseProject(key, on: row)
        }
        #expect(hands.did == [
            "open web", "settings web", "unlink \(g) web", "save \(g)", "link \(g) scratch", "link \(g) b",
            // The project in the way has the group's name.
            "join \(g) \(g)", "replace \(g) \(g)", "open \(g)", "decline \(g)", "undecline \(g)",
        ])
        // A refusal is said under the row, as the menu's others are.
        hands.refuse = "no"
        model.chooseProject("decline_project", on: row)
        #expect(model.rowLines[g]?.text == "no")
    }

    // MARK: The tab's menu and the save dialog

    @Test func theTabWithAGroupsSupervisorIsThatGroups() {
        let stewards: [(group: String, steward: String?)] = [("a", "0x1"), ("b", nil), ("c", "0x3")]
        #expect(Plan.supervisorGroup(terminals: ["0x9", "0x3"], stewards: stewards) == "c")
        #expect(Plan.supervisorGroup(terminals: ["0x9"], stewards: stewards) == nil)
    }

    @Test func savingWithTheBoxTickedTakesTheGroupsName() {
        #expect(Plan.groupSave(typed: "mine", group: "notes", ticked: true) == .init(name: "notes", group: "notes", link: true))
        #expect(Plan.groupSave(typed: "mine", group: "notes", ticked: false) == .init(name: "mine", group: nil, link: false))
        #expect(Plan.groupSave(typed: "mine", group: nil, ticked: true) == .init(name: "mine", group: nil, link: false))
    }

    @Test func theProjectInTheWayIsPutAsideUnderAFreeName() {
        let first = Plan.asideName("polter") { _ in false }
        #expect(first == "polter (old)")
        let taken: Set = ["polter (old)", "polter (old) 2"]
        let third = Plan.asideName("polter") { taken.contains($0) }
        #expect(third == "polter (old) 3")
    }
}
