import Foundation
import Testing
@testable import Ghostty

/// "Fix" on a card that reads "Failed" (task 1560): the core says which
/// cards have it, the host sends one request and shows a refusal beside the
/// button until the card stops offering it.
struct ControlRoomFixTests {
    typealias Actions = ControlRoomActions
    typealias Row = ControlRoomList.Row

    private static func group(_ name: String, fix: String?) -> String {
        let said = fix.map { ", \"fix\": \"\($0)\"" } ?? ""
        return """
        { "name": "\(name)", "needs_me": true, "unseen": false, "shown": "trouble", "text": "Failed",
          "waiter": {"is": "supervisor", "name": ""}, "what": {"cut": "none", "form": "none", "lines": []},
          "reason": {"from": "none", "text": "", "missing": null},
          "more": 0, "same_as": null\(said) }
        """
    }

    private static func snapshot(_ groups: [String]) -> String {
        """
        { "rev": 2, "now_ms": 1, "needs_me": \(groups.count), "groups_needing_me": \(groups.count), "groups_other": 0,
          "open_on": null, "groups": [ \(groups.joined(separator: ",")) ] }
        """
    }

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

    @Test func theButtonIsWhatTheCoreSaysAndNothingWhenItSaysNothing() throws {
        let list = try ControlRoomList.decode(snapshot: Data(Self.snapshot([
            Self.group("a", fix: "offered"), Self.group("b", fix: "sent"),
            Self.group("c", fix: "none"), Self.group("d", fix: nil),
        ]).utf8))
        #expect(list.rows.map(\.fix) == [.offered, .sent, .none, .none])
    }

    @Test func onlyAnOfferedButtonIsPressedAndALoneTerminalIsNamedByItself() {
        var row = ControlRoomList.sample.rows[0]
        row.fix = .offered
        #expect(Actions.fix(row) == .fix(group: row.id))
        row.fix = .sent
        #expect(Actions.fix(row) == nil)
        row.fix = .none
        #expect(Actions.fix(row) == nil)

        var alone = row
        alone.fix = .offered
        alone.alone = ControlRoomList.Alone(terminal: "0x00000000000000c1", title: "stray", pane: .plain)
        #expect(Actions.fix(alone) == .fixTerminal("0x00000000000000c1"))
    }

    @Test func theRequestIsTheCoresSpelling() throws {
        var captured: [[String: Any]] = []
        let actions = Actions { json in
            if let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] { captured.append(o) }
            return nil
        }
        try actions.perform(.fix(group: "build"))
        try actions.perform(.fixTerminal("0x00000000000000c1"))
        #expect(captured.count == 2)
        #expect(captured[0]["act"] as? String == "fix")
        #expect(captured[0]["group"] as? String == "build")
        #expect(captured[0].count == 2)
        #expect(captured[1]["act"] as? String == "fix")
        #expect(captured[1]["terminal"] as? String == "0x00000000000000c1")
        #expect(captured[1].count == 2)
    }

    @Test func aCardWithTheButtonHasItsLineAndNoOtherCardDoes() {
        let fit = ControlRoomAskFit.fit(needed: [1])
        let plain = ControlRoomListLayout.rowHeight(fit: fit, others: 0)
        #expect(ControlRoomListLayout.rowHeight(fit: fit, others: 0, fix: .none) == plain)
        #expect(ControlRoomListLayout.rowHeight(fit: fit, others: 0, fix: .offered)
                == plain + CGFloat(ControlRoomLook.Side.fixLineHeight))
        #expect(ControlRoomListLayout.rowHeight(fit: fit, others: 0, fix: .sent)
                == plain + CGFloat(ControlRoomLook.Side.fixLineHeight))
    }

    @Test func eachRefusalTheButtonCanMeetHasASentenceOfItsOwn() {
        let fallback = Actions.Refusal(name: "SomethingNew").message
        for name in ["NothingToFix", "AlreadyNotified", "NoAgent", "UserPresent", "DraftInLine", "NoSuchTerminal"] {
            #expect(Actions.Refusal(name: name).message != fallback, "no sentence for \(name)")
        }
    }

    @Test func aRefusalStandsBesideTheButtonUntilTheCardStopsOfferingIt() {
        let core = Core()
        core.json = Self.snapshot([Self.group("build", fix: "offered")])
        let model = ControlRoomModel(feed: core.feed)
        var refuse: String? = "DraftInLine"
        var sent: [Actions.Act] = []
        model.perform = { act in
            sent.append(act)
            if let refuse { throw Actions.Refusal(name: refuse) }
        }
        let row = model.list!.rows[0]

        model.fix(row)
        #expect(sent == [.fix(group: "build")])
        #expect(model.fixRefusal?.row == "build")
        #expect(model.fixRefusal?.message == Actions.Refusal(name: "DraftInLine").message)

        // Redrawn and still offered: still said.
        core.say(Self.snapshot([Self.group("build", fix: "offered")]))
        #expect(model.fixRefusal?.row == "build")

        // Pressed again, and done: nothing to say.
        refuse = nil
        model.fix(row)
        #expect(model.fixRefusal == nil)

        // Refused again, then the card is greyed: the refusal goes with it.
        refuse = "NoAgent"
        model.fix(row)
        #expect(model.fixRefusal != nil)
        core.say(Self.snapshot([Self.group("build", fix: "sent")]))
        #expect(model.fixRefusal == nil)
    }

    @Test func aButtonAlreadyPressedSendsNothing() {
        let core = Core()
        core.json = Self.snapshot([Self.group("build", fix: "sent")])
        let model = ControlRoomModel(feed: core.feed)
        var sent = 0
        model.perform = { _ in sent += 1 }
        model.fix(model.list!.rows[0])
        #expect(sent == 0)
    }
}
