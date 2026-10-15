import Foundation
import Testing
@testable import Ghostty

/// Where a click on a notification goes (task 1538): to the control room
/// whenever there is a group, to the terminal only when there is none.
struct NotificationClickTests {
    private let surface = UUID()

    @Test func theControlRoomsOwnCallGoesToItsGroup() {
        #expect(NotificationClick.of([ControlRoomAlert.groupKey: "api"]) == .controlRoom(group: "api"))
    }

    @Test func aTerminalInAGroupGoesToTheControlRoomNotToTheTerminal() {
        let info = NotificationClick.userInfo(surface: surface, requireFocus: true, group: "api")
        #expect(NotificationClick.of(info) == .controlRoom(group: "api"))
        // Still the terminal's: it is cleared from there, and whether it is
        // shown follows the terminal's focus, not the control room's rule.
        #expect(info["surface"] as? String == surface.uuidString)
        #expect(info[ControlRoomAlert.groupKey] == nil)
    }

    @Test func aTerminalInNoGroupGoesToItsTabAndPane() {
        let none = NotificationClick.userInfo(surface: surface, requireFocus: false, group: nil)
        #expect(NotificationClick.of(none) == .terminal(surface))
        // The core's "no group" is zero bytes; an empty name is no group too.
        let empty = NotificationClick.userInfo(surface: surface, requireFocus: false, group: "")
        #expect(NotificationClick.of(empty) == .terminal(surface))
        #expect(NotificationClick.of([NotificationClick.routeGroupKey: "", "surface": surface.uuidString]) == .terminal(surface))
    }

    @Test func aNotificationNamingNothingGoesNowhere() {
        #expect(NotificationClick.of([:]) == .nothing)
        #expect(NotificationClick.of(["surface": "not a uuid"]) == .nothing)
    }
}
