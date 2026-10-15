import Testing
import Foundation
@testable import Ghostty

/// Covers `PolterArrangePlan` (task 1571): which named terminals leave a
/// tab, and the refusals that stop a layout before anything moves. Moving
/// the views themselves needs live windows and is checked on the test
/// machine; see the task's checklist.
@Suite
struct PolterArrangePlanTests {
    final class View {}

    // Kept alive: an identifier of an object that is gone can be reused by
    // the next one, and then the two homes would be one.
    private let tabA = NSObject(), tabB = NSObject()
    private var homeA: ObjectIdentifier { ObjectIdentifier(tabA) }
    private var homeB: ObjectIdentifier { ObjectIdentifier(tabB) }

    private func handle(_ v: View) -> String { "v" }

    @Test func aTerminalFromAnotherTabIsMovedAndOneFromHereIsNot() throws {
        let here = View(), there = View()
        let everywhere: [UInt: PolterArrangePlan.Placed<View>] = [
            1: .init(view: here, home: homeA, lent: false),
            2: .init(view: there, home: homeB, lent: false),
        ]
        let plan = try PolterArrangePlan.decide(
            named: [1, 2], everywhere: everywhere,
            destination: (homeA, [here]), handleOf: handle).get()
        #expect(plan.leaving.count == 1)
        #expect(plan.leaving[homeB]?.count == 1)
        #expect(plan.leaving[homeB]?.first === there)
        #expect(plan.byHandle[1] === here)
    }

    @Test func intoANewTabEveryNamedTerminalLeavesItsTab() throws {
        let a = View(), b = View()
        let plan = try PolterArrangePlan.decide(
            named: [1, 2],
            everywhere: [1: .init(view: a, home: homeA, lent: false), 2: .init(view: b, home: homeA, lent: false)],
            destination: nil, handleOf: handle).get()
        #expect(plan.leaving[homeA]?.count == 2)
    }

    @Test func aLentTerminalRefusesTheWholeLayoutWithItsOwnCode() {
        let a = View(), b = View()
        let result = PolterArrangePlan.decide(
            named: [1, 2],
            everywhere: [1: .init(view: a, home: homeA, lent: false), 2: .init(view: b, home: homeB, lent: true)],
            destination: (homeA, [a]), handleOf: handle)
        guard case .failure(let refusal) = result else {
            Issue.record("a lent terminal was let through")
            return
        }
        #expect(refusal.code == "Lent")
        #expect(refusal.wire.contains("\"code\":\"Lent\""))
    }

    @Test func aPaneOfTheDestinationLeftOutIsRefused() {
        let a = View(), b = View(), c = View()
        let result = PolterArrangePlan.decide(
            named: [3],
            everywhere: [3: .init(view: c, home: homeB, lent: false)],
            destination: (homeA, [a, b]), handleOf: handle)
        guard case .failure(let refusal) = result else {
            Issue.record("a layout that drops a pane was let through")
            return
        }
        #expect(refusal.code == "Refused")
        #expect(refusal.wire.contains("leaves out"))
    }

    @Test func anUnknownOrRepeatedTerminalIsRefused() {
        let a = View()
        let everywhere: [UInt: PolterArrangePlan.Placed<View>] = [1: .init(view: a, home: homeA, lent: false)]
        if case .success = PolterArrangePlan.decide(named: [9], everywhere: everywhere, destination: nil, handleOf: handle) {
            Issue.record("an unknown terminal was let through")
        }
        switch PolterArrangePlan.decide(named: [1, 1], everywhere: everywhere, destination: nil, handleOf: { _ in "0x1" }) {
        case .success: Issue.record("a terminal named twice was let through")
        // Task 1578: the refusal names the terminal, as "leaves out" does.
        case .failure(let refusal): #expect(refusal.message.contains("names terminal 0x1 twice"))
        }
    }

    @Test func theEnvelopeSaysWhereTheShapeGoes() throws {
        func into(_ json: String) throws -> PolterArrangePlan.Into {
            try PolterArrangePlan.envelope(JSONSerialization.jsonObject(with: Data(json.utf8))).into
        }
        #expect(try into(#"{"layout":{"pane":"0x1"}}"#) == .here)
        #expect(try into(#"{"layout":{"pane":"0x1"},"into":{"new_window":true}}"#) == .newWindow)
        #expect(try into(#"{"layout":{"pane":"0x1"},"into":{"new_tab_beside":"0x2a"}}"#) == .newTabBeside(0x2a))
        #expect(throws: PoltergeistLayoutError.self) { try into(#"{"layout":{"pane":"0x1"},"into":{"new_tab":"0x2a"}}"#) }
        #expect(throws: PoltergeistLayoutError.self) { try into(#"{"pane":"0x1"}"#) }
    }

    @Test func aTabSlotIsTheTabItGoesBeforeOrTheEnd() {
        #expect(PolterArrangePlan.tabSlot(index: 0, othersCount: 3) == 0)
        #expect(PolterArrangePlan.tabSlot(index: 2, othersCount: 3) == 2)
        #expect(PolterArrangePlan.tabSlot(index: 3, othersCount: 3) == nil)
        #expect(PolterArrangePlan.tabSlot(index: 99, othersCount: 3) == nil)
    }
}
