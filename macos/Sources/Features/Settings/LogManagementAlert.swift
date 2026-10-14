import AppKit

/// The question "Clear…" asks (task 1511), built apart from asking it so a
/// test can look at its buttons.
enum LogManagementAlert {
    /// Return answers Cancel, not the button that deletes: clearing cannot
    /// be undone, and a Return pressed out of habit should cost nothing.
    /// The same as Windows' TaskDialog, whose default is Cancel too.
    ///
    /// The deleting button stays first, so `.alertFirstButtonReturn` is
    /// still "go"; it is only its Return that is taken off it. Esc is not
    /// bound to Cancel here: one button has one key, and Return is the one
    /// a person presses without reading.
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
}
