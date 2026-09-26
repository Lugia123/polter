import AppKit

/// The decisions behind "Save as a Project Before Closing?", kept apart
/// from the alert and the controller so they can be checked without a
/// window. The alert itself is `presentSaveAsProjectBeforeClosing` in
/// `TerminalController+Projects.swift`.
///
/// Both rules here exist because the prompt's whole reason to exist is not
/// losing what is running in the tab, and each was once a way to lose it:
/// any answer but "Save" used to close the tab (and the alert offered no
/// way out, so there was no answer that meant "don't"), and a save that
/// failed used to close it anyway.
enum ProjectSaveBeforeClose {
    enum Choice: Equatable {
        case save
        case closeWithoutSaving
        case keepOpen
    }

    /// The alert's buttons, in the order they are added -- the order is
    /// what `NSAlert` reports back, so this is the one place it's written,
    /// and `makeAlert` adds them from it.
    static let buttonOrder: [Choice] = [.save, .closeWithoutSaving, .keepOpen]

    /// The alert, not yet shown. `title` is a seam for tests: the Esc
    /// binding only matters under a title that isn't the English "Cancel",
    /// and a test running in English can't see that any other way.
    ///
    /// Each `String(localized:)` below stays on one line -- the
    /// Chinese-strings checker only sees it when the literal starts on the
    /// same line as the call.
    static func makeAlert(title: (Choice) -> String = title(for:)) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save as a Project Before Closing?", comment: "关闭终端前的存项目提醒标题")
        alert.informativeText = String(localized: "The terminal still has a running process. Closing it without saving as a project will kill it.", comment: "关闭终端前的存项目提醒正文")
        alert.alertStyle = .warning
        for choice in buttonOrder {
            let button = alert.addButton(withTitle: title(choice))
            // The way out this alert used to lack. Esc is bound explicitly:
            // NSAlert only binds it on its own to a button titled "Cancel"
            // in English, which a localized title isn't.
            if choice == .keepOpen { button.keyEquivalent = "\u{1b}" }
        }
        return alert
    }

    private static func title(for choice: Choice) -> String {
        switch choice {
        case .save: return String(localized: "Save as Project...", comment: "关闭终端前的存项目提醒：存成项目按钮")
        case .closeWithoutSaving: return String(localized: "Close Without Saving", comment: "关闭终端前的存项目提醒：直接关闭按钮")
        case .keepOpen: return String(localized: "Cancel", comment: "关闭终端前的存项目提醒：取消按钮")
        }
    }

    /// What a response from the alert means.
    ///
    /// Only the one button that says "close without saving" closes. Every
    /// other response -- Cancel, Esc, and anything AppKit might report that
    /// isn't a button (the sheet ended because its window went away) --
    /// keeps the tab open: closing kills processes, so it has to be asked
    /// for, never defaulted into.
    static func choice(for response: NSApplication.ModalResponse) -> Choice {
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = response.rawValue - first
        guard buttonOrder.indices.contains(index) else { return .keepOpen }
        return buttonOrder[index]
    }

    /// Save, and close only if the save worked. A failed save is reported
    /// and the tab stays open -- the person pressed "Save" so as not to
    /// lose what's in it.
    static func saveThenClose(
        save: () throws -> Void,
        reportFailure: (Error) -> Void,
        close: () -> Void
    ) {
        do {
            try save()
        } catch {
            reportFailure(error)
            return
        }
        close()
    }
}
