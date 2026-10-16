import Foundation
import Testing
@testable import Ghostty

/// What a group's row carries for its menu (task 1660), as read from the
/// snapshot fields task 1659 adds (`issue-fix/1659-interface.md`).
struct ControlRoomGroupFactsTests {
    /// The core's fixture, with the new fields put on two of its groups
    /// and two archived groups at the top.
    private func list(_ edit: (inout [String: Any]) throws -> Void) throws -> ControlRoomList {
        var snapshot = try #require(try JSONSerialization.jsonObject(with: ControlRoomListTests.fixture()) as? [String: Any])
        try edit(&snapshot)
        return try ControlRoomList.decode(snapshot: JSONSerialization.data(withJSONObject: snapshot))
    }

    private func setGroup(_ name: String, in snapshot: inout [String: Any], _ fields: [String: Any]) throws {
        var groups = try #require(snapshot["groups"] as? [[String: Any]])
        let i = try #require(groups.firstIndex { $0["name"] as? String == name })
        groups[i].merge(fields) { $1 }
        snapshot["groups"] = groups
    }

    @Test func theNewFieldsReachTheRow() throws {
        let l = try list { s in
            try setGroup("web-app", in: &s, [
                "pinned": true,
                "muted": ["until_ms": 1_792_166_400_000],
                "delete_cost": ["members": 3, "open_tasks": 4],
                "record_dir": "/state/chat/web-app",
                "brief": "这个群负责网页端",
                "project": ["tie": "bound", "name": "web-app", "pages": 2, "open": true, "start": "project", "why": "none"],
            ])
            try setGroup("notes", in: &s, ["muted": ["until_ms": NSNull()]])
        }
        let web = try #require(l.rows.first { $0.id == "web-app" }?.facts)
        #expect(web.pinned)
        #expect(web.muted)
        #expect(web.mutedUntilMs == 1_792_166_400_000)
        #expect(web.deleteCost == .init(members: 3, open_tasks: 4))
        #expect(web.recordDir == "/state/chat/web-app")
        #expect(web.brief == "这个群负责网页端")
        #expect(web.project == "web-app")
        #expect(web.steward == "0x00000000000000a1")
        // Muted for good: muted, with no time.
        let notes = try #require(l.rows.first { $0.id == "notes" }?.facts)
        #expect(notes.muted)
        #expect(notes.mutedUntilMs == nil)
    }

    /// A snapshot from before the fields -- the core's fixture with them
    /// taken off -- is nothing pinned or muted and no counts. A group has a
    /// project only where its tie is `bound`: in the fixture, infra.
    @Test func aSnapshotWithoutThemIsNothingPinnedOrMuted() throws {
        let l = try list { s in
            var groups = try #require(s["groups"] as? [[String: Any]])
            for i in groups.indices {
                for field in ["pinned", "muted", "delete_cost", "record_dir"] { groups[i].removeValue(forKey: field) }
            }
            s["groups"] = groups
            s.removeValue(forKey: "archived")
        }
        for row in l.rows {
            let facts = try #require(row.facts, "\(row.id) has no facts")
            #expect(!facts.pinned)
            #expect(!facts.muted)
            #expect(facts.deleteCost == nil)
            #expect(facts.recordDir == nil)
            #expect(facts.project == (row.id == "infra" ? "infra" : nil), "\(row.id)")
        }
        #expect(l.archived.isEmpty)
    }

    /// The fields as the core writes them (its fixture, task 1659).
    @Test func theCoresFixtureCarriesTheFields() throws {
        let l = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        let design = try #require(l.rows.first { $0.id == "design-system" }?.facts)
        #expect(design.deleteCost == .init(members: 2, open_tasks: 1))
        #expect(design.recordDir == "/state/chat/design-system")
        #expect(!design.pinned)
        #expect(!design.muted)
        #expect(l.rows.allSatisfy { $0.facts?.recordDir != nil })
        #expect(l.archived.isEmpty)
    }

    @Test func aGroupTiedNoOtherWayThanBoundHasNoProject() throws {
        let l = try list { s in
            try setGroup("web-app", in: &s, ["project": ["tie": "declined", "name": NSNull(), "start": "directory", "why": "declined"]])
        }
        #expect(l.rows.first { $0.id == "web-app" }?.facts?.project == nil)
    }

    @Test func archivedGroupsAreListedAsTheCoreOrdersThem() throws {
        let l = try list { s in
            s["archived"] = [
                ["name": "old-app", "brief": "旧的", "archived_ms": 2_000, "record_dir": "/state/chat/old-app",
                 "delete_cost": ["members": 0, "open_tasks": 2]],
                ["name": "spike-pdf", "archived_ms": 1_000],
            ]
        }
        #expect(l.archived.map(\.name) == ["old-app", "spike-pdf"])
        #expect(l.archived[0].deleteCost == .init(members: 0, open_tasks: 2))
        #expect(l.archived[1].brief == "")
        #expect(l.archived[1].recordDir == nil)
        // An archived group is not a row.
        #expect(!l.rows.contains { $0.id == "old-app" })
    }

    // MARK: What the menu sends

    private func json(_ act: ControlRoomActions.Act) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ControlRoomActions.request(for: act), options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    /// Each as `issue-fix/1659-interface.md` writes it.
    @Test func eachActIsTheRequestTheCoreTakes() throws {
        #expect(try json(.pin(group: "g")) == #"{"act":"pin","group":"g"}"#)
        #expect(try json(.unpin(group: "g")) == #"{"act":"unpin","group":"g"}"#)
        #expect(try json(.mute(group: "g", untilMs: 5)) == #"{"act":"mute","group":"g","until_ms":5}"#)
        // Muted for good: no time at all, not a null one.
        #expect(try json(.mute(group: "g", untilMs: nil)) == #"{"act":"mute","group":"g"}"#)
        #expect(try json(.unmute(group: "g")) == #"{"act":"unmute","group":"g"}"#)
        #expect(try json(.archive(group: "g")) == #"{"act":"archive","group":"g"}"#)
        #expect(try json(.unarchive(group: "g")) == #"{"act":"unarchive","group":"g"}"#)
        #expect(try json(.renameGroup(from: "a", to: "b")) == #"{"act":"rename_group","from":"a","to":"b"}"#)
        #expect(try json(.setBrief(group: "g", brief: "x")) == #"{"act":"set_brief","brief":"x","group":"g"}"#)
        #expect(try json(.deleteGroup(group: "g", members: 3, openTasks: 4))
            == #"{"act":"delete_group","group":"g","members":3,"open_tasks":4}"#)
        #expect(try json(.askSupervisor(group: "g", ask: .reportProgress)) == #"{"act":"ask_supervisor","ask":"report","group":"g"}"#)
        #expect(try json(.askSupervisor(group: "g", ask: .closeIdleWorkers)) == #"{"act":"ask_supervisor","ask":"close_idle","group":"g"}"#)
    }

    /// Every refusal the new acts can give has a sentence of its own, not
    /// the one that only names it.
    @Test func eachNewRefusalHasASentence() {
        let fallback = ControlRoomActions.Refusal(name: "NoSuchThingEver").message
        for name in ["NoSuchGroup", "EmptyName", "BadName", "GroupExists", "RenameFailed", "MuteInThePast",
                     "Stale", "NoSupervisor", "NoAgent", "UserPresent", "DraftInLine", "ChildExited",
                     "RenameBlocked", "RenameBusy", "RenameUnfinished", "RenameDeferred", "DeleteFailed"] {
            let message = ControlRoomActions.Refusal(name: name).message
            #expect(!message.contains(name), "\(name) has no sentence")
            #expect(message != fallback)
        }
        // The rename's three are the mockup's three.
        #expect(ControlRoomActions.Refusal(name: "EmptyName").message == ControlRoomGroupWords.emptyName)
    }
}
