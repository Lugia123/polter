import Testing
@testable import Ghostty

/// What the launch does about the control room
/// (`ControlRoomRules.atLaunch`, task 1581). The same rows as the Windows
/// host's `what_the_launch_does_about_the_control_room`.
struct ControlRoomAtLaunchTests {
    struct Row: Sendable, CustomStringConvertible {
        let enabled: Bool
        let restored: Int
        let room: Bool
        let initial: Bool
        let want: ControlRoomRules.AtLaunch

        var description: String { "enabled=\(enabled) restored=\(restored) room=\(room) initial=\(initial)" }
    }

    @Test(arguments: [
        Row(enabled: true, restored: 0, room: false, initial: true, want: .ownWindow),
        Row(enabled: true, restored: 2, room: false, initial: true, want: .firstTabBehind),
        Row(enabled: true, restored: 2, room: true, initial: true, want: .nothing),
        Row(enabled: true, restored: 0, room: true, initial: true, want: .nothing),
        Row(enabled: false, restored: 0, room: false, initial: true, want: .nothing),
        Row(enabled: false, restored: 2, room: false, initial: true, want: .nothing),
        Row(enabled: true, restored: 0, room: false, initial: false, want: .nothing),
        Row(enabled: true, restored: 1, room: false, initial: false, want: .firstTabBehind),
    ])
    func theLaunchTable(_ row: Row) {
        #expect(ControlRoomRules.atLaunch(
            enabled: row.enabled, restoredTerminals: row.restored,
            roomRestored: row.room, initialWindow: row.initial) == row.want)
    }
}
