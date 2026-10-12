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
        }
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
        // Every row that waits is one: the five groups the list's header
        // counts, and one terminal that is in no group. The Dock's number
        // is the core's, and the host adds nothing up to get it.
        #expect(snapshot.groups_needing_me == 5)
        #expect(snapshot.needs_me == 6)
        #expect(snapshot.groups.count == 8)
        #expect(ControlRoomRules.dockBadge(needsMe: snapshot.needs_me, bells: nil) == "6")
    }
}
