import AppKit
import SwiftUI

/// Presents `ProjectPickerView` as a standalone window.
///
/// A standalone window rather than a sheet: "Load Project" and "Manage
/// Projects" are meaningful even when no terminal window is focused (or
/// none exists), and a sheet needs a parent window to attach to. "Save as
/// Project" happens to always have one (there's a tab being saved), but
/// using the same presentation for all three keeps them from drifting.
@MainActor
final class ProjectPicker: NSObject {
    private var window: NSWindow?

    /// Show the picker in `mode`. Replaces whatever this instance is
    /// currently showing, if anything.
    ///
    /// - Parameters:
    ///   - onSave: Called with the name to save under -- a brand new one,
    ///     or an existing entry's, which overwrites it (see
    ///     `ProjectStore.Entry`). Only reachable in `.saveAs` mode. The
    ///     picker closes itself afterward.
    ///   - onLoad: Called with the picked entry. Only reachable in `.load`
    ///     mode. The picker closes itself afterward.
    ///   - onCancel: Called when the picker is dismissed without saving or
    ///     loading (Cancel, or the window's close button).
    func present(
        mode: ProjectPickerMode,
        store: ProjectStore = .shared,
        onSave: @escaping (String) -> Void = { _ in },
        onLoad: @escaping (ProjectStore.Entry) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        close()

        let view = ProjectPickerView(
            mode: mode,
            store: store,
            onSave: { [weak self] name in
                onSave(name)
                self?.close()
            },
            onLoad: { [weak self] entry in
                onLoad(entry)
                self?.close()
            },
            onDelete: { entry in
                try? store.delete(name: entry.name)
            },
            onCancel: { [weak self] in
                onCancel()
                self?.close()
            })

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.close()
    }
}

extension ProjectPicker: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Closed via the titlebar button rather than Cancel: same effect,
        // just make sure we don't hold a stale reference.
        window = nil
    }
}
