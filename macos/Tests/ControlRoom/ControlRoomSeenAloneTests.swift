import Foundation
import Testing
@testable import Ghostty

/// "This row has been looked at", for a row that is about one terminal in
/// no group: said by the terminal, since there is no group to say it by.
struct ControlRoomSeenAloneTests {
    typealias Actions = ControlRoomActions
    typealias Row = ControlRoomList.Row

    private static let stray = "0x00000000000000c1"

    private static func rows() -> [Row] {
        let group = ControlRoomList.sample.rows[0]
        var alone = group
        alone.id = ControlRoomList.rowId(ofTerminal: stray)
        alone.unseen = true
        alone.alone = ControlRoomList.Alone(terminal: stray, title: "stray", pane: .plain)
        return [group, alone]
    }

    @Test func aGroupsRowIsSeenByItsNameAndALoneTerminalsByItsTerminal() {
        let rows = Self.rows()
        #expect(Actions.seen(rowId: rows[0].id, in: rows) == .seen(group: rows[0].id))
        #expect(Actions.seen(rowId: rows[1].id, in: rows) == .seenTerminal(Self.stray))
        // A row that is no longer listed has nothing to be said about it.
        #expect(Actions.seen(rowId: "gone", in: rows) == nil)
    }

    @Test func theRequestNamesTheTerminalAndNoGroup() throws {
        var captured = Data()
        try Actions { json in
            captured = json
            return nil
        }.perform(.seenTerminal(Self.stray))
        let json = try #require(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
        #expect(json["act"] as? String == "seen")
        #expect(json["terminal"] as? String == Self.stray)
        #expect(json["group"] == nil)
        #expect(json.count == 2)
    }

    @Test func lookingAtALoneTerminalsRowForAMomentMarksItLikeAnyOther() {
        // The same tracker, the same wait, the same check of being in
        // front: only what is sent at the end differs.
        var pending: [() -> Void] = []
        var sent: [Actions.Act] = []
        let rows = Self.rows()
        let tracker = ControlRoomSeenTracker(
            dwell: 1.5,
            later: { _, work in pending.append(work) },
            isInFront: { true },
            markSeen: { id in
                if let act = Actions.seen(rowId: id, in: rows) { sent.append(act) }
            })

        tracker.selectionChanged(to: rows[1])
        #expect(sent.isEmpty)
        // Kept alive across the wait: the deferred call holds it weakly.
        withExtendedLifetime(tracker) { pending.forEach { $0() } }
        #expect(sent == [.seenTerminal(Self.stray)])
    }

    @Test func theCoresFixtureHasALoneRowThatCarriesItsTerminal() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        let alone = try #require(list.rows.first { $0.alone != nil })
        let act = Actions.seen(rowId: alone.id, in: list.rows)
        #expect(act == .seenTerminal("0x00000000000000c1"))
    }
}
