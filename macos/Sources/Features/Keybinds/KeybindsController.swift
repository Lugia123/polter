import Cocoa
import SwiftUI
import GhosttyKit

/// The window behind "Keyboard Shortcuts…".
///
/// **Built in code rather than from a nib.** `AboutController` needs one
/// because it has a custom title bar; this is a list in a plain window, and a
/// nib for it would be a second place to keep the size and the title.
class KeybindsController: NSWindowController {
    static let shared = KeybindsController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Keyboard Shortcuts"
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: this window is made in code")
    }

    /// Show the window, **reading the listing afresh each time**.
    ///
    /// The configuration can be reloaded while this window is closed, and a
    /// list kept from last time would be quietly stale -- wrong for exactly
    /// the person who just changed a binding and came to check.
    func show(config: ghostty_config_t?) {
        let rows = KeybindsModel.rows(config: config)
        window?.contentView = NSHostingView(rootView: KeybindsView(rows: rows))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
