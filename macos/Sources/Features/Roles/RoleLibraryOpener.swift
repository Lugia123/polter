import AppKit
import GhosttyKit

/// Opens the role library from a menu row. A target of its own because the
/// row is useful with no terminal at all -- that is when somebody sets up
/// their first role -- and on a shielded one, since the library is about
/// every role and not about that terminal.
///
/// The library is the Roles section of the settings window. The row carries
/// the role of the terminal it was opened from, if any, and the window
/// selects that role (settings.md §3.2).
@MainActor
final class RoleLibraryOpener: NSObject {
    static let shared = RoleLibraryOpener()

    @objc func showRoleLibrary(_ sender: Any?) {
        let route = (sender as? NSMenuItem)?.representedObject as? SettingsRoute
        openSettings(route ?? .roles())
    }

    /// The terminal a launch from the library opens its tab beside: the one
    /// in front, as for any new tab.
    static var launchSurface: ghostty_surface_t? {
        TerminalController.preferredParent?.focusedSurface?.surface
    }

    static func launch(role: Role, cli: String) {
        guard let surface = launchSurface else { return }
        if let error = RoleLibrary.launch(from: surface, key: role.key, cli: cli) {
            showLaunchError(error)
        }
    }

    static func showLaunchError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The role couldn't be launched", comment: "用角色启动：失败弹窗标题")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
