import AppKit
import Foundation
import Testing
@testable import Ghostty

/// What the group row's menu does through the control room's model (task
/// 1660): which state each row is asked in, and what each item sends.
@MainActor
struct ControlRoomRowMenuModelTests {
    private final class Core {
        var json = ""
        let center = NotificationCenter()
        lazy var feed = ControlRoomFeed(center: center) { [unowned self] buffer, capacity in
            let bytes = Array(self.json.utf8)
            if let buffer, bytes.count + 1 <= capacity {
                for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
                buffer[bytes.count] = 0
            }
            return bytes.count
        }
        func say(_ json: String) {
            self.json = json
            center.post(name: ControlRoomFeed.changed, object: nil)
        }
    }

    /// A model on the core's fixture, with web-app pinned, muted until a
    /// time, bound to a project and carrying its counts; with every act it
    /// sends recorded, and nothing done outside it.
    private final class Rig {
        let core = Core()
        let model: ControlRoomModel
        var sent: [ControlRoomActions.Act] = []
        var refuse: [String: String] = [:]
        var answers: [Bool] = []
        var asked: [ControlRoomGroupAlerts.Question] = []
        var revealed: [URL] = []
        var copied: [String] = []
        var later: [(TimeInterval, () -> Void)] = []
        var told: [String] = []
        var tookOver: [(String, String)] = []

        init() throws {
            var snapshot = try #require(try JSONSerialization.jsonObject(with: ControlRoomListTests.fixture()) as? [String: Any])
            var groups = try #require(snapshot["groups"] as? [[String: Any]])
            let i = try #require(groups.firstIndex { $0["name"] as? String == "web-app" })
            groups[i].merge([
                "pinned": true, "muted": ["until_ms": 1_792_146_000_000],
                "delete_cost": ["members": 3, "open_tasks": 4], "record_dir": "/state/chat/web-app",
                "brief": "旧的说明",
            ]) { $1 }
            snapshot["groups"] = groups
            snapshot["archived"] = [["name": "old-app", "archived_ms": 1, "record_dir": "/state/chat/old-app",
                                     "delete_cost": ["members": 0, "open_tasks": 2]]]
            core.json = try #require(String(bytes: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8))
            model = ControlRoomModel(feed: core.feed)
            model.perform = { [unowned self] act in
                self.sent.append(act)
                if let name = self.refuse[Self.name(act)] { throw ControlRoomActions.Refusal(name: name) }
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            model.effects = .init(
                reveal: { [unowned self] in self.revealed.append($0) },
                copy: { [unowned self] in self.copied.append($0) },
                ask: { [unowned self] question, answer in
                    self.asked.append(question)
                    answer(self.answers.isEmpty ? false : self.answers.removeFirst())
                },
                now: { calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 14, minute: 40))! },
                calendar: calendar,
                after: { [unowned self] seconds, run in self.later.append((seconds, run)) },
                tell: { [unowned self] in self.told.append($0) },
                takeOver: { [unowned self] in self.tookOver.append(($0, $1)) })
        }

        static func name(_ act: ControlRoomActions.Act) -> String {
            ControlRoomActions.request(for: act)["act"] as? String ?? ""
        }

        func row(_ id: String) throws -> ControlRoomList.Row {
            try #require(model.list?.rows.first { $0.id == id })
        }
    }

    // MARK: Which state

    @Test func eachRowIsAskedInTheStateTheSnapshotSays() throws {
        let rig = try Rig()
        let web = rig.model.menuState(try rig.row("web-app"))
        #expect(web == .init(archived: false, supervisor: .hooked, resumable: false, pinned: true, muted: true))
        // The same row with no supervisor the core names a title for.
        var none = try rig.row("notes")
        none.supervisor = nil
        #expect(rig.model.menuState(none).supervisor == .none)
    }

    @Test func theMenuHasTheRulesItemsWithTheirTimes() throws {
        let rig = try Rig()
        let menu = rig.model.menu(for: try rig.row("web-app"))
        let keys = menu.items.compactMap { $0.representedObject as? String }
        #expect(keys.contains("unpin"))
        #expect(keys.contains("unmute"))
        #expect(!keys.contains("mute"))
        // Muted until 18:20 the same day (1_792_146_000_000 ms, Shanghai).
        if #available(macOS 14.0, *) {
            let unmute = menu.items.first { $0.representedObject as? String == "unmute" }
            #expect(unmute?.badge?.stringValue?.contains("18:20") == true)
        }
    }

    // MARK: Taking over (#1635)

    /// docs-site's supervisor was started by hand and the core offers to
    /// take it over (its fixture): the menu has the item, and choosing it
    /// asks the core's own question about that group.
    @Test func aSupervisorStartedByHandCanBeTakenOverFromTheMenu() throws {
        let rig = try Rig()
        let docs = try rig.row("docs-site")
        #expect(rig.model.menuState(docs).supervisor == .hookless)
        let keys = rig.model.menu(for: docs).items.compactMap { $0.representedObject as? String }
        #expect(keys.prefix(2) == ["jump_to_supervisor", "take_over"])
        rig.model.choose("take_over", on: docs)
        let question = try #require(docs.supervisor?.takeOver?.confirm)
        #expect(rig.tookOver.map(\.0) == ["docs-site"])
        #expect(rig.tookOver.map(\.1) == [question])
        #expect(rig.sent.isEmpty, "the question comes first; the act is the take-over's")
    }

    /// A hooked supervisor is jumped to and nothing more.
    @Test func aHookedSupervisorOffersNoTakeOver() throws {
        let rig = try Rig()
        let web = try rig.row("web-app")
        #expect(rig.model.menuState(web).supervisor == .hooked)
        let keys = rig.model.menu(for: web).items.compactMap { $0.representedObject as? String }
        #expect(!keys.contains("take_over"))
        rig.model.choose("take_over", on: web)
        #expect(rig.tookOver.isEmpty)
    }

    // MARK: What each sends

    @Test func pinMuteAndUnmuteSendTheirActs() throws {
        let rig = try Rig()
        let web = try rig.row("web-app")
        rig.model.choose("unpin", on: web)
        rig.model.choose("mute_hour", on: web)
        rig.model.choose("mute_tomorrow", on: web)
        rig.model.choose("mute_forever", on: web)
        rig.model.choose("unmute", on: web)
        // Now is 14:40 on 2026-10-16 in Shanghai: 1_792_132_800_000.
        let hour: UInt64 = 1_792_136_400_000
        let tomorrow: UInt64 = 1_792_198_800_000
        #expect(rig.sent == [
            .unpin(group: "web-app"),
            .mute(group: "web-app", untilMs: hour),
            .mute(group: "web-app", untilMs: tomorrow),
            .mute(group: "web-app", untilMs: nil),
            .unmute(group: "web-app"),
        ])
    }

    @Test func revealAndCopyGoOutsideAndSendNothing() throws {
        let rig = try Rig()
        let web = try rig.row("web-app")
        rig.model.choose("reveal", on: web)
        rig.model.choose("copy_supervisor_id", on: web)
        #expect(rig.revealed == [URL(fileURLWithPath: "/state/chat/web-app", isDirectory: true)])
        #expect(rig.copied == ["0x00000000000000a1"])
        #expect(rig.sent.isEmpty)
    }

    @Test func askingSaysAskedAndFoldsAwayAfterTheTablesSeconds() throws {
        let rig = try Rig()
        rig.model.choose("close_idle_workers", on: try rig.row("web-app"))
        #expect(rig.sent == [.askSupervisor(group: "web-app", ask: .closeIdleWorkers)])
        #expect(rig.model.rowLines["web-app"]?.delivered == true)
        #expect(rig.later.map(\.0) == [ControlRoomLook.GroupNote.feedbackSeconds])
        rig.later[0].1()
        #expect(rig.model.rowLines["web-app"] == nil)
    }

    @Test func aSentenceThatDidNotGoInStaysAndSaysWhy() throws {
        let rig = try Rig()
        rig.refuse["ask_supervisor"] = "DraftInLine"
        rig.model.choose("report_progress", on: try rig.row("web-app"))
        let line = try #require(rig.model.rowLines["web-app"])
        #expect(!line.delivered)
        #expect(line.text == ControlRoomGroupWords.notDelivered(ControlRoomGroupWords.askReason("DraftInLine")))
        #expect(rig.later.isEmpty)
    }

    /// Task 1671 (the test machine, #1666): a retry that went in left the
    /// line saying "will try again". The core's next words on the ask --
    /// the fixture's web-app is being tried again as message 41 -- are
    /// followed: the line learns its message, then that it went in.
    @Test func aRetryThatWentInSaysAskedAndFoldsAway() throws {
        let rig = try Rig()
        rig.refuse["ask_supervisor"] = "DraftInLine"
        rig.model.choose("report_progress", on: try rig.row("web-app"))
        let waiting = try #require(rig.model.rowLines["web-app"])
        #expect(waiting.retry == .init(ask: .reportProgress, on: nil))

        try say(rig, ask: ["seq": 41, "state": "retrying", "code": "DraftInLine"])
        #expect(rig.model.rowLines["web-app"]?.retry?.on == 41)
        #expect(rig.model.rowLines["web-app"]?.text == waiting.text)
        #expect(rig.later.isEmpty)

        try say(rig, ask: ["seq": 41, "state": "delivered", "code": NSNull()])
        let line = try #require(rig.model.rowLines["web-app"])
        #expect(line.delivered)
        #expect(line.text == ControlRoomGroupWords.asked(.reportProgress))
        #expect(rig.later.map(\.0) == [ControlRoomLook.GroupNote.feedbackSeconds])
    }

    /// One given up on says why, and no longer that it will try again; the
    /// ask before this one is never taken for it.
    @Test func aRetryGivenUpOnSaysWhyAndOnlyThisAsksEndCounts() throws {
        let rig = try Rig()
        rig.refuse["ask_supervisor"] = "UserPresent"
        rig.model.choose("report_progress", on: try rig.row("web-app"))
        try say(rig, ask: ["seq": 41, "state": "retrying", "code": "UserPresent"])
        try say(rig, ask: ["seq": 40, "state": "delivered", "code": NSNull()])
        #expect(rig.model.rowLines["web-app"]?.delivered == false)

        try say(rig, ask: ["seq": 41, "state": "gave_up", "code": "UserPresent"])
        let line = try #require(rig.model.rowLines["web-app"])
        #expect(!line.delivered)
        #expect(line.retry == nil)
        #expect(line.text == ControlRoomGroupWords.notDelivered(ControlRoomGroupWords.askReason("UserPresent", willTryAgain: false)))
        #expect(!line.text.contains(ControlRoomGroupWords.askReason("UserPresent")))
    }

    /// The rig's snapshot again, with web-app's last ask as given.
    private func say(_ rig: Rig, ask: [String: Any]) throws {
        var snapshot = try #require(try JSONSerialization.jsonObject(with: Data(rig.core.json.utf8)) as? [String: Any])
        var groups = try #require(snapshot["groups"] as? [[String: Any]])
        let i = try #require(groups.firstIndex { $0["name"] as? String == "web-app" })
        groups[i]["ask"] = ask
        snapshot["groups"] = groups
        rig.core.say(try #require(String(bytes: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)))
    }

    /// An old line folding away does not take a newer one with it.
    @Test func foldingAnOldLineLeavesTheNewOne() throws {
        let rig = try Rig()
        let web = try rig.row("web-app")
        rig.model.choose("report_progress", on: web)
        rig.model.choose("close_idle_workers", on: web)
        rig.later[0].1()
        #expect(rig.model.rowLines["web-app"]?.text == ControlRoomGroupWords.asked(.closeIdleWorkers))
    }

    // MARK: Renaming

    @Test func renamingRefusesAnEmptyNameBeforeReturnAndTheCoresOnReturn() throws {
        let rig = try Rig()
        rig.model.choose("rename", on: try rig.row("web-app"))
        #expect(rig.model.renaming == .init(row: "web-app", draft: "web-app", refusal: nil))
        rig.model.renameTyped("  ")
        #expect(rig.model.renaming?.refusal == ControlRoomGroupWords.emptyName)
        rig.model.submitRename()
        #expect(rig.sent.isEmpty, "Return does nothing while the name is refused")
        rig.refuse["rename_group"] = "GroupExists"
        rig.model.renameTyped("mobile")
        rig.model.submitRename()
        #expect(rig.sent == [.renameGroup(from: "web-app", to: "mobile")])
        #expect(rig.model.renaming?.refusal == ControlRoomActions.Refusal(name: "GroupExists").message)
    }

    @Test func theSameNameEndsItWithNothingSentAndANewOneIsSelectedAfter() throws {
        let rig = try Rig()
        rig.model.choose("web-app")
        rig.model.choose("rename", on: try rig.row("web-app"))
        rig.model.submitRename()
        #expect(rig.sent.isEmpty)
        #expect(rig.model.renaming == nil)
        rig.model.choose("rename", on: try rig.row("web-app"))
        rig.model.renameTyped("web")
        rig.model.submitRename()
        #expect(rig.sent == [.renameGroup(from: "web-app", to: "web")])
        #expect(rig.model.renaming == nil)
        #expect(rig.model.madeGroup == "web")
    }

    // MARK: The note

    @Test func theNoteOpensOnTheGroupsBriefAndSavesWhatWasTyped() throws {
        let rig = try Rig()
        rig.model.choose("edit_note", on: try rig.row("web-app"))
        #expect(rig.model.noteEditing == .init(group: "web-app", saved: "旧的说明", draft: "旧的说明", refusal: nil))
        rig.model.noteEditing?.draft = "新的说明"
        rig.model.saveNote()
        #expect(rig.sent == [.setBrief(group: "web-app", brief: "新的说明")])
        #expect(rig.model.noteEditing == nil)
    }

    @Test func aRefusedSaveKeepsThePanelAndSaysWhy() throws {
        let rig = try Rig()
        rig.refuse["set_brief"] = "NoSuchGroup"
        rig.model.choose("edit_note", on: try rig.row("web-app"))
        rig.model.noteEditing?.draft = "x"
        rig.model.saveNote()
        #expect(rig.model.noteEditing?.draft == "x")
        #expect(rig.model.noteEditing?.refusal == ControlRoomActions.Refusal(name: "NoSuchGroup").message)
    }

    // MARK: Archiving and deleting

    @Test func archivingAsksAndOnlyThenSends() throws {
        let rig = try Rig()
        let web = try rig.row("web-app")
        rig.answers = [false]
        rig.model.choose("archive", on: web)
        #expect(rig.sent.isEmpty)
        rig.answers = [true]
        rig.model.choose("archive", on: web)
        #expect(rig.sent == [.archive(group: "web-app")])
        // The supervisor is running: the question says its terminals stay.
        #expect(rig.asked.last?.alert.informativeText.contains("still running") == true)
    }

    @Test func deletingSendsTheCountsTheQuestionShowed() throws {
        let rig = try Rig()
        rig.answers = [true]
        rig.model.choose("delete", on: try rig.row("web-app"))
        #expect(rig.sent == [.deleteGroup(group: "web-app", members: 3, openTasks: 4)])
        // Three members, the supervisor one of them: two workers.
        #expect((rig.asked.last?.alert.accessoryView?.accessibilityLabel() ?? "").contains("the supervisor and 2 workers"))
    }

    /// The counts changed meanwhile: nothing was deleted, and the question
    /// is asked again -- once.
    @Test func aStaleDeleteIsAskedAgainOnce() throws {
        let rig = try Rig()
        rig.refuse["delete_group"] = "Stale"
        rig.answers = [true, true]
        rig.model.choose("delete", on: try rig.row("web-app"))
        #expect(rig.asked.count == 2)
        #expect(rig.sent.count == 2)
        #expect(rig.model.rowLines["web-app"]?.delivered == false)
    }

    /// Off the list, records left on disk: said in a box of its own, since
    /// the row it would stand under is gone.
    @Test func aDeleteThatLeftRecordsIsToldNotPutUnderARow() throws {
        let rig = try Rig()
        rig.refuse["delete_group"] = "DeleteFailed"
        rig.answers = [true]
        rig.model.choose("delete", on: try rig.row("web-app"))
        #expect(rig.told == [ControlRoomActions.Refusal(name: "DeleteFailed").message])
        #expect(rig.model.rowLines["web-app"] == nil)
        #expect(rig.asked.count == 1)
    }

    @Test func anArchivedGroupsMenuRevealsUnarchivesAndDeletes() throws {
        let rig = try Rig()
        let old = try #require(rig.model.list?.archived.first)
        let keys = rig.model.menu(forArchived: old).items.compactMap { $0.representedObject as? String }
        #expect(keys == ["reveal", "unarchive", "delete"])
        rig.model.chooseArchived("unarchive", old)
        rig.answers = [true]
        rig.model.chooseArchived("delete", old)
        #expect(rig.sent == [.unarchive(group: "old-app"), .deleteGroup(group: "old-app", members: 0, openTasks: 2)])
    }
}
