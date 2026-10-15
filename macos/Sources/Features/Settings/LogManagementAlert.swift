import AppKit

/// The question "Clear…" asks (task 1511), built apart from asking it so a
/// test can look at its buttons.
enum LogManagementAlert {
    /// Return answers Cancel, not the button that deletes: clearing cannot
    /// be undone, and a Return pressed out of habit should cost nothing.
    /// The same as Windows' TaskDialog, whose default is Cancel too.
    ///
    /// The deleting button stays first, so `.alertFirstButtonReturn` is
    /// still "go"; it is only its Return that is taken off it. One button
    /// has one key equivalent and Cancel's is Return -- the one a person
    /// presses without reading -- so Esc is answered by `run` instead
    /// (task 1551). NSAlert would bind it by itself only to a button titled
    /// "Cancel" in English; 取消 gets nothing.
    static func make(_ c: LogManagementRules.Confirmation, cancel: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = c.title
        alert.informativeText = c.lines.joined(separator: "\n\n")
        let go = alert.addButton(withTitle: c.button)
        go.hasDestructiveAction = true
        go.keyEquivalent = ""
        let no = alert.addButton(withTitle: cancel)
        no.keyEquivalent = "\r"
        return alert
    }

    /// Whether a key going down is the Esc this alert answers with Cancel:
    /// Esc alone, as every other dialog takes it.
    static func isEscape(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && flags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    /// `runModal`, with Esc pressing Cancel while the alert is up.
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window,
                  isEscape(keyCode: event.keyCode, flags: event.modifierFlags) else { return event }
            alert.buttons[1].performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }
}
