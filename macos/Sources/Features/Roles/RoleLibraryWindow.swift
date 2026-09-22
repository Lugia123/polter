import AppKit
import GhosttyKit
import SwiftUI

/// The role library window. One for the whole app: the library is one file,
/// and two windows editing it would be two drafts racing each other to save.
@MainActor
final class RoleLibraryWindow: NSObject, NSWindowDelegate {
    static let shared = RoleLibraryWindow()

    private var window: NSWindow?
    private var editor: RoleLibraryEditor?

    /// Show the window, optionally with one role selected.
    func present(selecting key: String? = nil) {
        let library = RoleLibrary.shared
        library.reload()

        if let window, let editor {
            if let key { editor.select(key) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let editor = RoleLibraryEditor(library: library)
        editor.select(key ?? library.catalog.roles.first?.key)
        self.editor = editor

        let view = RoleLibraryView(
            library: library,
            editor: editor,
            canLaunch: { Self.launchSurface != nil },
            onLaunch: { role, cli in Self.launch(role: role, cli: cli) })

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "Role Library", comment: "角色库：窗口标题")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 720))
        window.setFrameAutosaveName("PolterRoleLibrary")
        window.delegate = self
        self.window = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        editor?.confirmClose() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        editor = nil
    }

    /// The terminal a launch from the window opens its tab beside: the one
    /// in front, as for any new tab.
    static var launchSurface: ghostty_surface_t? {
        TerminalController.preferredParent?.focusedSurface?.surface
    }

    static func launch(role: Role, cli: String) {
        guard let surface = launchSurface else { return }
        if let error = RoleLibrary.launch(from: surface, key: role.key, cli: cli) {
            RoleLibraryOpener.showLaunchError(error)
        }
    }
}
