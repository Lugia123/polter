import Cocoa
import SwiftUI
import GhosttyKit

/// The window showing what the terminals have said to each other.
///
/// Built in code rather than from a nib because it holds one hosting view
/// and nothing else; a nib would be a file to keep in step for no gain.
class PoltergeistChatController: NSWindowController, NSWindowDelegate {
    static let shared = PoltergeistChatController()

    private var ghostty: ghostty_app_t?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminal Conversations"
        window.center()
        window.setFrameAutosaveName("PoltergeistChat")

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Show the window, or hide it if it is already in front.
    ///
    /// Toggling rather than always showing, because this is bound to a key
    /// and a key that only ever opens something is a key you cannot undo.
    func toggle(_ app: ghostty_app_t) {
        guard let window else { return }

        if window.isVisible && window.isKeyWindow {
            window.close()
            return
        }

        if ghostty != app {
            ghostty = app
            window.contentView = NSHostingView(
                rootView: PoltergeistChatView(ghostty: app)
            )
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func close(_ sender: Any) {
        window?.performClose(sender)
    }
}
