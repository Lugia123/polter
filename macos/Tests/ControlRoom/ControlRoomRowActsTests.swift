import Foundation
import Testing
@testable import Ghostty

/// Approve and refuse on a row of the list (`ControlRoomRowActs`), the keys
/// that press them (`ControlRoomRules.rowAct`), and that the tick and the
/// cross are the screenshot toolbar's (`ControlRoomActGlyph`).
struct ControlRoomRowActsTests {
    typealias Row = ControlRoomList.Row
    typealias Acts = ControlRoomRowActs

    private func row(_ id: String, approvable: Bool = true, target: ControlRoomList.Target? = .init(
        terminal: "0x00000000000000a1", sinceMs: 5_760_000, eventMs: 5_761_000)) -> Row {
        .init(id: id, shown: .needsYou, word: "等批准", detail: "Bash(rm -rf dist/)", detailIsCode: true,
              waitedMin: 4, others: 1, pulses: false, unseen: false, approvable: approvable, target: target)
    }

    private final class Clock {
        var pending: [(TimeInterval, () -> Void)] = []
        func later(_ after: TimeInterval, _ work: @escaping () -> Void) { pending.append((after, work)) }
        /// The oldest timer comes due.
        func passOne() {
            guard !pending.isEmpty else { return }
            pending.removeFirst().1()
        }
    }

    /// A stand-in for the core: keeps what it was sent, answers as told.
    private final class Core {
        var sent: [ControlRoomActions.Act] = []
        var refuseWith: String?
        func perform(_ act: ControlRoomActions.Act) throws {
            sent.append(act)
            if let refuseWith { throw ControlRoomActions.Refusal(name: refuseWith) }
        }
    }

    // MARK: Which rows, and what a press sends

    @Test func aPressSendsTheRowsOwnTerminalAndItsTwoMoments() throws {
        let core = Core()
        let acts = Acts(later: Clock().later, perform: core.perform)
        let waiting = row("web-app")
        acts.press(.approve, on: waiting)
        acts.press(.refuse, on: waiting)

        let target = try #require(waiting.target)
        #expect(core.sent == [.approve(target), .refuse(target)])

        // And the request the core reads carries both guards, as they came.
        let request = ControlRoomActions.request(for: core.sent[0])
        #expect(request["act"] as? String == "approve")
        #expect(request["terminal"] as? String == "0x00000000000000a1")
        #expect(request["since_ms"] as? UInt64 == 5_760_000)
        #expect(request["event_ms"] as? UInt64 == 5_761_000)
    }

    @Test func aRowTheCoreDoesNotCallApprovableSendsNothing() {
        let core = Core()
        let acts = Acts(later: Clock().later, perform: core.perform)
        // It looks exactly like one that is waiting for an approval: the
        // word, the glyph, the terminal. Only the core's word differs.
        acts.press(.approve, on: row("web-app", approvable: false))
        acts.press(.refuse, on: row("web-app", approvable: false))
        #expect(core.sent.isEmpty)
        #expect(Acts.act(.approve, on: row("web-app", approvable: false)) == nil)
    }

    @Test func aRowWithNoTerminalBehindItSendsNothing() {
        let core = Core()
        let acts = Acts(later: Clock().later, perform: core.perform)
        acts.press(.approve, on: row("web-app", target: nil))
        #expect(core.sent.isEmpty)
    }

    // MARK: A press is not a selection

    @Test func pressingAButtonDoesNotSelectTheRowOrCountAsLookingAtIt() {
        let json = """
        { "rev": 2, "now_ms": 1, "needs_me": 2, "groups_needing_me": 2, "groups_other": 0, "open_on": "billing",
          "groups": [
          { "name": "billing", "needs_me": true, "unseen": false, "approvable": false, "shown": "needs_you",
            "text": "等回答", "waited_min": 3, "reason": {"from": "none", "text": "", "missing": null},
            "more": 0, "same_as": null },
          { "name": "web-app", "needs_me": true, "unseen": false, "approvable": true, "shown": "needs_you",
            "text": "等批准", "waited_min": 4,
            "attention": {"terminal": "0x00000000000000a1", "since_ms": 10, "event_ms": 11},
            "reason": {"from": "hook_note", "text": "Bash(x)", "missing": null}, "more": 0, "same_as": null } ] }
        """
        let center = NotificationCenter()
        let feed = ControlRoomFeed(center: center) { buffer, capacity in
            let bytes = Array(json.utf8)
            if let buffer, bytes.count + 1 <= capacity {
                for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
                buffer[bytes.count] = 0
            }
            return bytes.count
        }
        let model = ControlRoomModel(feed: feed)
        // Opened on billing by itself; nobody has chosen anything.
        #expect(model.selection == "billing")
        #expect(!model.selectionIsThePersons)

        var pressed: [(Acts.Kind, String)] = []
        var chose = 0
        model.act = { kind, row in pressed.append((kind, row.id)) }
        model.onChoose = { chose += 1 }
        let waiting = model.list?.rows.first { $0.id == "web-app" }
        #expect(waiting?.approvable == true)
        if let waiting { model.press(.approve, on: waiting) }

        #expect(pressed.map(\.1) == ["web-app"])
        #expect(model.selection == "billing")
        #expect(!model.selectionIsThePersons)
        #expect(model.rowBeingLookedAt == nil)
        #expect(chose == 0)
    }

    // MARK: A refusal is said on the row, and goes away

    @Test func aRefusalIsSaidOnThatRowInTheCoresSentenceAndThenGoes() {
        let core = Core()
        let clock = Clock()
        var told: [[String: String]] = []
        let acts = Acts(linger: 4, later: clock.later, perform: core.perform)
        acts.onChange = { told.append($0) }

        core.refuseWith = "PromptGone"
        acts.press(.approve, on: row("web-app"))
        #expect(acts.notices == ["web-app": ControlRoomActions.Refusal(name: "PromptGone").message])
        #expect(clock.pending.map(\.0) == [4])
        #expect(told.count == 1)

        clock.passOne()
        #expect(acts.notices.isEmpty)
        #expect(told.last == [:])
    }

    @Test func anEarlierSentencesTimerDoesNotTakeAwayALaterOne() {
        let core = Core()
        let clock = Clock()
        let acts = Acts(linger: 4, later: clock.later, perform: core.perform)

        core.refuseWith = "PromptGone"
        acts.press(.approve, on: row("web-app"))
        core.refuseWith = "UserPresent"
        acts.press(.refuse, on: row("web-app"))
        let second = ControlRoomActions.Refusal(name: "UserPresent").message
        #expect(acts.notices == ["web-app": second])

        // The first sentence's time is up: the second one stays.
        clock.passOne()
        #expect(acts.notices == ["web-app": second])
        clock.passOne()
        #expect(acts.notices.isEmpty)
    }

    @Test func aPressThatIsDoneSaysNothingAndClearsWhatWasSaid() {
        let core = Core()
        let clock = Clock()
        let acts = Acts(linger: 4, later: clock.later, perform: core.perform)

        core.refuseWith = "DraftInLine"
        acts.press(.approve, on: row("web-app"))
        #expect(acts.notices.count == 1)

        core.refuseWith = nil
        acts.press(.approve, on: row("web-app"))
        #expect(acts.notices.isEmpty)
        // One row's sentence is its own.
        core.refuseWith = "PromptGone"
        acts.press(.refuse, on: row("billing"))
        #expect(Array(acts.notices.keys) == ["billing"])
    }

    // MARK: The keys

    @Test func yApprovesAndNRefusesWithNoModifier() {
        #expect(ControlRoomRules.rowAct(key: "y", modifiers: 0) == .approve)
        #expect(ControlRoomRules.rowAct(key: "Y", modifiers: 0) == .approve)
        #expect(ControlRoomRules.rowAct(key: "n", modifiers: 0) == .refuse)
        // Return is kept for going into the terminal.
        #expect(ControlRoomRules.rowAct(key: "\r", modifiers: 0) == nil)
        #expect(ControlRoomRules.rowAct(key: "a", modifiers: 0) == nil)
        // With command, control or option down it is somebody else's key.
        #expect(ControlRoomRules.rowAct(key: "y", modifiers: 1 << 20) == nil)
        #expect(ControlRoomRules.rowAct(key: "n", modifiers: 1 << 18) == nil)
    }

    // MARK: The tick and the cross are the screenshot toolbar's

    @Test func theTwoIconsAreTheToolbarsOwnData() throws {
        let done = try #require(ShotLook.icon("done"))
        let cancel = try #require(ShotLook.icon("cancel"))
        #expect(ControlRoomActGlyph.icon(.approve) == done)
        #expect(ControlRoomActGlyph.icon(.refuse) == cancel)
        // And they are in the toolbar: this is not a spare drawing.
        #expect(ShotLook.toolbarIcons.contains("done"))
        #expect(ShotLook.toolbarIcons.contains("cancel"))
    }

    @Test func theyAreDrawnByTheToolbarsRuleAtTheToolbarsSize() throws {
        // The generator recorded where each icon's ink falls in a toolbar
        // button at each scale; what a row draws is that, pixel for pixel.
        for kind in [Acts.Kind.approve, .refuse] {
            let icon = try #require(ControlRoomActGlyph.icon(kind))
            for want in icon.ink {
                let mask = try #require(ControlRoomActGlyph.mask(kind, scale: want.scale))
                #expect(mask.cell == want.cell)
                #expect(mask.ink == .init(x: want.x, y: want.y, w: want.w, h: want.h, count: want.count))
                #expect(mask == ShotIconRaster.mask(icon, cell: want.cell, scale: want.scale))
            }
        }
        // The pressed square is the toolbar's button.
        #expect(ControlRoomLook.Side.actButton == ShotLook.Size.button)
        #expect(ControlRoomLook.Side.actButtonGap == ShotLook.Size.gap)
    }
}
