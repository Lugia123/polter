import AppKit
import SwiftUI

/// Presents `ProjectPickerView` as a standalone window.
///
/// A standalone window rather than a sheet: "Load Project" is meaningful
/// even when no terminal window is focused (or none exists), and a sheet
/// needs a parent window to attach to. "Save as Project"
/// (`presentSaveAs`) happens to always have one (there's a tab being
/// saved), but using the same presentation for both keeps them from
/// drifting.
@MainActor
final class ProjectPicker: NSObject {
    private var window: NSWindow?

    /// Show the picker in `mode`. Replaces whatever this instance is
    /// currently showing, if anything.
    ///
    /// - Parameters:
    ///   - onLoad: Called with the picked entry. The picker closes itself
    ///     afterward.
    ///   - onCancel: Called when the picker is dismissed without loading
    ///     (Cancel, or the window's close button).
    func present(
        mode: ProjectPickerMode,
        store: ProjectStore = .shared,
        onLoad: @escaping (ProjectStore.Entry) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        close()

        let view = ProjectPickerView(
            mode: mode,
            store: store,
            onLoad: { [weak self] entry in
                onLoad(entry)
                self?.close()
            },
            onCancel: { [weak self] in
                onCancel()
                self?.close()
            })

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = mode.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        // Sized before it is centered: see `ProjectPickerView.size`.
        window.setContentSize(ProjectPickerView.size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show "Save as Project" for `tabs`, the tabs of the window it was
    /// asked in. `onSave` is called with the name and the ids of the tabs
    /// to save; the sheet closes itself afterward.
    func presentSaveAs(
        tabs: [ProjectPageRules.Tab],
        store: ProjectStore = .shared,
        onSave: @escaping (String, [Int]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        close()

        let view = ProjectSaveAsView(
            tabs: tabs,
            store: store,
            onSave: { [weak self] name, ids in
                onSave(name, ids)
                self?.close()
            },
            onCancel: { [weak self] in
                onCancel()
                self?.close()
            })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Save as Project", comment: "项目选择界面标题：另存为项目")
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        window.setContentSize(ProjectSaveAsView.size(rows: tabs.count))
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
