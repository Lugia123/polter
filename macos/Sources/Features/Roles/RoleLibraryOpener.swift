import AppKit

/// Opens the role library from a menu row. A target of its own because the
/// row is useful with no terminal at all -- that is when somebody sets up
/// their first role -- and on a shielded one, since the library is about
/// every role and not about that terminal.
@MainActor
final class RoleLibraryOpener: NSObject {
    static let shared = RoleLibraryOpener()

    @objc func showRoleLibrary(_ sender: Any?) {
        RoleLibraryWindow.shared.present()
    }

    static func showLaunchError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The role couldn't be launched", comment: "用角色启动：失败弹窗标题")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
