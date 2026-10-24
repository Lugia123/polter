import Foundation
import Testing
@testable import Ghostty

/// What the title bar of a supervisor's frame says
/// (`ControlRoomList.SupervisorTitle`), and the Dock icon's badge
/// (`ControlRoomRules.dockBadge`).
struct ControlRoomSupervisorTitleTests {
    typealias Group = ControlRoomSnapshot.Group
    typealias Title = ControlRoomList.SupervisorTitle

    private func snapshot() throws -> ControlRoomSnapshot {
        try JSONDecoder().decode(ControlRoomSnapshot.self, from: ControlRoomListTests.fixture())
    }

    private func group(_ name: String) throws -> Group {
        try #require(try snapshot().groups.first { $0.name == name })
    }

    // MARK: The title

    @Test func whenTheRowIsAboutTheSupervisorTheTitleSaysWhatTheRowSays() throws {
        // web-app's supervisor is itself waiting for an approval.
        let web = try group("web-app")
        #expect(web.attention?.terminal == web.steward)
        let title = try #require(ControlRoomList.supervisorTitle(of: web))
        let member = try #require(web.members?.first { $0.id == web.steward })
        #expect(title == Title(name: member.title, shown: web.shown, word: web.text))
        #expect(title.shown == .needsYou)
    }

    @Test func whenTheRowIsAboutAWorkerTheTitleIsTheSupervisorsOwn() throws {
        // mobile: a worker waits for an approval and the supervisor itself
        // has nothing to say. The row says "waiting for approval"; the
        // title of the supervisor's frame does not, because the supervisor
        // is not the one waiting.
        let mobile = try group("mobile")
        #expect(mobile.waiter.is == .workerViaSupervisor)
        #expect(mobile.shown == .needsYou)
        let member = try #require(mobile.members?.first { $0.id == mobile.steward })
        #expect(member.shown == .none)
        let title = try #require(ControlRoomList.supervisorTitle(of: mobile))
        #expect(title == Title(name: member.title, shown: .none, word: ""))
    }

    @Test func aSupervisorStartedByHandIsSaidToBeAndNoOtherIs() throws {
        // Task 1635: docs-site's supervisor was started by hand and its
        // adapter knows it; design-system's no adapter recognised.
        #expect(try ControlRoomList.supervisorTitle(of: group("docs-site"))?.note == "Started by hand: no status")
        #expect(try ControlRoomList.supervisorTitle(of: group("design-system"))?.note == "Unknown CLI: no status")
        for g in try snapshot().groups where g.name != "docs-site" && g.name != "design-system" {
            #expect(ControlRoomList.supervisorTitle(of: g)?.note == nil, "\(g.name)")
        }
        // And the frame's title carries it.
        let title = try #require(ControlRoomList.supervisorTitle(of: group("docs-site")))
        #expect(PaneFrame.Title(title).note == "Started by hand: no status")
        // docs-site's is offered for taking over, with the core's question
        // filled in; design-system's (no adapter knows it) is not.
        let take = try #require(title.takeOver)
        #expect(take.offered)
        #expect(take.confirm == "This ends the Claude Code running in this terminal and starts it again through Polter, "
            + "with its status hooks, going on with session 0b1d1c35 (last written 3 min ago).")
        #expect(take.status == nil)
        #expect(PaneFrame.Title(title).takeOver == take)
        #expect(try ControlRoomList.supervisorTitle(of: group("design-system"))?.takeOver == nil)
        #expect(ControlRoomActions.request(for: .takeOver(group: "docs-site")) as? [String: String]
            == ["act": "take_over", "group": "docs-site"])
    }

    @Test func theNameIsTheSupervisorsOwnTitleNotAnotherMembers() throws {
        var web = try group("web-app")
        let steward = try #require(web.steward)
        // The supervisor is not the first member listed.
        web.members = web.members.map { Array($0.reversed()) }
        #expect(web.members?.first?.id != steward)
        let title = try #require(ControlRoomList.supervisorTitle(of: web))
        let member = try #require(web.members?.first { $0.id == steward })
        #expect(title.name == member.title)
    }

    @Test func aGroupTheCoreNamesNoSupervisorForHasNoTitle() throws {
        var web = try group("web-app")
        web.steward = nil
        #expect(ControlRoomList.supervisorTitle(of: web) == nil)
        // Named, and not among the members the snapshot lists.
        var odd = try group("web-app")
        odd.steward = "0x00000000000000ff"
        #expect(ControlRoomList.supervisorTitle(of: odd) == nil)
    }

    @Test func everyRowOfTheFixtureCarriesItsSupervisorsTitle() throws {
        let snapshot = try snapshot()
        let list = ControlRoomList(snapshot: snapshot)
        for group in snapshot.groups {
            let row = try #require(list.rows.first { $0.id == group.name })
            #expect(row.supervisor == ControlRoomList.supervisorTitle(of: group))
            #expect((row.supervisor != nil) == (group.steward != nil))
            // And none of them went through an Agent CLI of the person's own
            #expect(row.supervisor?.model == nil, "\(group.name)")
        }
    }

    // MARK: An Agent CLI of the person's own (task 2156)

    /// The snapshot with the group's steward started through the Agent CLI
    /// `key`, called `name`.
    private func through(_ key: String, name: String?, group named: String) throws -> ControlRoomSnapshot {
        var snapshot = try snapshot()
        let steward = try #require(snapshot.groups.first { $0.name == named }?.steward)
        snapshot.terminals = snapshot.terminals?.map { t in
            guard t.id == steward else { return t }
            var t = t
            t.who?.launcher = key
            t.who?.launcher_name = name
            return t
        }
        return snapshot
    }

    /// The control room's own frame says "custom model" where the CLI's name
    /// would be, for a supervisor started through one of the person's own.
    @Test func aSupervisorStartedThroughAnAgentCliOfThePersonsOwnSaysCustomModel() throws {
        let list = ControlRoomList(snapshot: try through("claude-deepseek-flash", name: "Claude · DeepSeek flash", group: "web-app"))
        let row = try #require(list.rows.first { $0.id == "web-app" })
        #expect(row.supervisor?.model == "Claude · DeepSeek flash custom model")
        // Its key when the core said no name.
        let keyed = ControlRoomList(snapshot: try through("minimax", name: nil, group: "web-app"))
        #expect(keyed.rows.first { $0.id == "web-app" }?.supervisor?.model == "minimax custom model")
        // A supervisor its own plugin started says nothing there.
        let plain = ControlRoomList(snapshot: try snapshot())
        #expect(plain.rows.first { $0.id == "web-app" }?.supervisor?.model == nil)
        // And another group's frame is not the one that went through it.
        #expect(list.rows.first { $0.id == "mobile" }?.supervisor?.model == nil)
    }

    // MARK: The Dock badge

    @Test func theBadgeIsTheCoresNumberAsItCame() {
        #expect(ControlRoomRules.dockBadge(needsMe: 3, bells: nil) == "3")
        // Not capped, not added to anything.
        #expect(ControlRoomRules.dockBadge(needsMe: 120, bells: "2") == "120")
        #expect(ControlRoomRules.dockBadge(needsMe: 1, bells: "99+") == "1")
    }

    @Test func nobodyWaitingIsNoBadgeOfItsOwn() {
        #expect(ControlRoomRules.dockBadge(needsMe: 0, bells: nil) == nil)
        #expect(ControlRoomRules.dockBadge(needsMe: nil, bells: nil) == nil)
        // What was there before stays: windows that rang their bell.
        #expect(ControlRoomRules.dockBadge(needsMe: 0, bells: "2") == "2")
        #expect(ControlRoomRules.dockBadge(needsMe: nil, bells: "2") == "2")
    }

    @Test func theNumberIsReadFromTheSnapshotsNeedsMe() throws {
        let snapshot = try snapshot()
        // Every row that waits and is drawn is one: the five groups the
        // list's header counts. The terminal that waits in no group has no
        // row and is not in the number (task 1485). The Dock's number is
        // the core's, and the host adds nothing up to get it.
        #expect(snapshot.groups_needing_me == 5)
        #expect(snapshot.needs_me == 5)
        #expect(snapshot.groups.count == 8)
        #expect(ControlRoomRules.dockBadge(needsMe: snapshot.needs_me, bells: nil) == "5")
    }
}
