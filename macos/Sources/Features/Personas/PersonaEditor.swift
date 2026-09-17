import AppKit
import SwiftUI

/// Presents `PersonaEditorView` as a standalone window, one per terminal.
///
/// Standalone rather than a sheet, for `ProjectPicker`'s reason and one
/// more: the editor is about *a* terminal, not the frontmost one, and a
/// sheet bolted to the key window would put one terminal's settings on top
/// of a different terminal.
///
/// Keyed by the terminal it was opened for, so a second "Role Editor..."
/// from the same tab raises the window that is already up instead of
/// stacking a copy that will then disagree with it.
@MainActor
final class PersonaEditor: NSObject {
    static let shared = PersonaEditor()

    private struct Open {
        let window: NSWindow
        let state: PersonaEditorState
    }

    private var open: [ObjectIdentifier: Open] = [:]

    /// Show (or raise) the editor for `terminal`.
    ///
    /// - Parameter terminal: identity only -- what the window is keyed by.
    ///   Nothing is read back out of it here; `model` is what gets drawn,
    ///   and `update(for:model:)` is how it stays current.
    func present(
        for terminal: AnyObject,
        model: PersonaEditorModel,
        onSelectPersona: @escaping (String?) -> Void,
        onToggleSkill: @escaping (PersonaFace.Entry, Bool) -> Void = { _, _ in },
        onToggleMCP: @escaping (PersonaFace.Entry, Bool) -> Void = { _, _ in },
        onResetToPersona: @escaping () -> Void = {}
    ) {
        let key = ObjectIdentifier(terminal)

        if let existing = open[key] {
            existing.state.model = model
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let state = PersonaEditorState(model)
        let view = PersonaEditorView(
            state: state,
            onSelectPersona: onSelectPersona,
            onToggleSkill: onToggleSkill,
            onToggleMCP: onToggleMCP,
            onResetToPersona: onResetToPersona,
            onClose: { [weak self, weak terminal] in
                guard let terminal else { return }
                self?.close(for: terminal)
            })

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "Role Editor", comment: "角色编辑器：窗口标题")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        open[key] = Open(window: window, state: state)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Redraw an open editor from fresh state.
    ///
    /// Called whenever the core reports this terminal's persona changed --
    /// including when the change came from a click in this very window.
    /// Without it the editor shows the state as it was when it opened, and
    /// a user who picks a role watches nothing happen.
    ///
    /// A no-op when no editor is open for `terminal`, so callers do not have
    /// to track whether one is.
    func update(for terminal: AnyObject, model: PersonaEditorModel) {
        open[ObjectIdentifier(terminal)]?.state.model = model
    }

    func isOpen(for terminal: AnyObject) -> Bool {
        open[ObjectIdentifier(terminal)] != nil
    }

    func close(for terminal: AnyObject) {
        guard let entry = open.removeValue(forKey: ObjectIdentifier(terminal)) else { return }
        entry.window.delegate = nil
        entry.window.close()
    }
}

extension PersonaEditor: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Closed from the titlebar rather than the Done button. Drop the
        // reference so the next open builds a fresh window instead of
        // raising a closed one.
        guard let window = notification.object as? NSWindow else { return }
        open = open.filter { $0.value.window !== window }
    }
}
