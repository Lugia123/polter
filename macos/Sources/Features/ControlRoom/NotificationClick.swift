import Foundation

/// Where a click on one of Polter's system notifications goes (task 1538).
///
/// **Anything that belongs to a group goes to the control room**, opened if
/// it is not, with that group selected -- its supervisor is then the right
/// column. That is the control room's own call (`ControlRoomAlert`), and a
/// notification a terminal raised itself -- a program's OSC 9, a finished
/// command, a supervisor's `notify_user` -- when the core said, as it was
/// raised, that the terminal is in a group (`ghostty_app_notification_group`).
/// Only a terminal in no group is gone to directly: its tab, its pane.
///
/// No AppKit and no GhosttyKit, so the decision can be checked on its own.
enum NotificationClick: Equatable {
    case controlRoom(group: String)
    case terminal(UUID)
    case nothing

    /// The key in a terminal's own notification that names the group the
    /// core put it in. Not `ControlRoomAlert.groupKey`: that one also says
    /// "show it whatever the person is looking at", and a terminal's own
    /// notification keeps its own rule for that.
    static let routeGroupKey = "polterRouteGroup"

    /// What a terminal's notification carries: the terminal, whether it
    /// needs the terminal out of focus to be shown, and its group if any.
    static func userInfo(surface: UUID, requireFocus: Bool, group: String?) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "surface": surface.uuidString,
            "requireFocus": requireFocus,
        ]
        if let group, !group.isEmpty { info[routeGroupKey] = group }
        return info
    }

    static func of(_ userInfo: [AnyHashable: Any]) -> NotificationClick {
        if let group = userInfo[ControlRoomAlert.groupKey] as? String { return .controlRoom(group: group) }
        if let group = userInfo[routeGroupKey] as? String, !group.isEmpty { return .controlRoom(group: group) }
        if let s = userInfo["surface"] as? String, let uuid = UUID(uuidString: s) { return .terminal(uuid) }
        return .nothing
    }
}
