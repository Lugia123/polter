import AppKit

/// The two questions the group row's menu asks before it acts (task 1660,
/// design v21 `06`), built apart from asking them so a test can look at
/// their buttons. The icon is the app's own (`NSApp.applicationIconImage`,
/// which is `Polter.icon`): the design drew another one, which the user
/// turned down (2026-10-16).
///
/// - Archive can be undone: "Archive" is at the right and takes Return,
///   "Cancel" is at its left and takes Escape.
/// - Delete cannot: "Cancel" is at the right and takes Return and Escape,
///   as "Clear…" in log management has it (`LogManagementAlert`); "Delete
///   Group" is at its left, marked destructive. Its icon is the app's with
///   the system's caution sign at its corner, as the design has it. The
///   system's own `.critical` draws the two the other way round -- a large
///   sign with the app's icon small at its corner -- which poltertest
///   showed (task 1660).
///
/// NSAlert puts the first button it is given at the right, and binds
/// Escape by itself only to a button titled "Cancel" in English; so each
/// question says which button acts and which Escape presses (`Question`).
enum ControlRoomGroupAlerts {
    static var cancel: String {
        String(localized: "Cancel", comment: "总控台：归档、删除群确认框的取消按钮")
    }

    /// A question, which of its buttons acts, and which Escape presses.
    struct Question {
        let alert: NSAlert
        let act: Int
        let cancel: Int

        /// Whether the button that acts was the one chosen, for a modal
        /// response.
        func acted(_ response: NSApplication.ModalResponse) -> Bool {
            response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue == act
        }

        /// Ask it as a sheet on `window`, Escape pressing `cancel`, and
        /// hand `answer` whether it was answered by the button that acts.
        ///
        /// **A sheet, never `runModal`** (task 1660; #1635b found it): a
        /// modal alert closing changes the control room window's
        /// occlusion, and the lending takes that as the supervisor's
        /// terminal going out of sight and gives it back to its own tab.
        /// With no window to hang it on, nothing is asked and the answer is
        /// no.
        func ask(on window: NSWindow?, _ answer: @escaping (Bool) -> Void) {
            guard let window else { return answer(false) }
            let alert = self.alert
            let cancel = self.cancel
            var monitor: Any?
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === alert.window,
                      LogManagementAlert.isEscape(keyCode: event.keyCode, flags: event.modifierFlags) else { return event }
                alert.buttons[cancel].performClick(nil)
                return nil
            }
            alert.beginSheetModal(for: window) { response in
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                answer(acted(response))
            }
        }
    }

    /// A sentence with nothing to choose, as a sheet on `window`.
    static func tell(_ text: String, on window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.beginSheetModal(for: window)
    }

    static func archive(name: String, supervisorRunning: Bool) -> Question {
        let q = ControlRoomGroupWords.archiveQuestion(name: name, supervisorRunning: supervisorRunning)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = q.title
        alert.informativeText = q.body
        let go = alert.addButton(withTitle: String(localized: "Archive", comment: "总控台：归档确认框的归档按钮"))
        go.keyEquivalent = "\r"
        let no = alert.addButton(withTitle: cancel)
        no.keyEquivalent = ""
        return Question(alert: alert, act: 0, cancel: 1)
    }

    static func delete(name: String, project: String?, still: ControlRoomGroupWords.Still) -> Question {
        let q = ControlRoomGroupWords.deleteQuestion(name: name, project: project, still: still)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = cautionIcon()
        alert.messageText = q.title
        alert.informativeText = [q.body, q.aside].compactMap { $0 }.joined(separator: "\n\n")
        // First is at the right: Cancel, which takes Return.
        let no = alert.addButton(withTitle: cancel)
        no.keyEquivalent = "\r"
        let go = alert.addButton(withTitle: String(localized: "Delete Group", comment: "总控台：删除群确认框的删除按钮"))
        go.hasDestructiveAction = true
        go.keyEquivalent = ""
        if let warning = q.warning {
            // As wide as the alert's own text, which is there once it is
            // laid out.
            alert.layout()
            alert.accessoryView = warningView(warning, width: bodyWidth(alert))
        }
        return Question(alert: alert, act: 1, cancel: 0)
    }

    /// The app's icon with the system's caution sign over its lower right
    /// corner, the sign half the icon's side.
    static func cautionIcon() -> NSImage {
        let app = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        let side: CGFloat = 64
        let sign = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.black, .systemYellow]))
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            app.draw(in: rect)
            if let sign {
                let s = side / 2
                sign.draw(in: NSRect(x: rect.maxX - s, y: rect.minY, width: s, height: s))
            }
            return true
        }
    }

    /// How wide the alert sets its informative text.
    static func bodyWidth(_ alert: NSAlert) -> CGFloat {
        func fields(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) }
        }
        let body = alert.window.contentView.map(fields)?.first { $0.stringValue == alert.informativeText }
        return body?.frame.width ?? alert.window.frame.width
    }

    /// What is still in the group, in the system's red with its caution
    /// glyph, above the buttons.
    static func warningView(_ text: String, width: CGFloat) -> NSView {
        let glyph = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                               accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .systemRed
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .systemRed
        // The system's size, which is the menu's: nothing smaller.
        label.font = SafeFace(size: NSFont.systemFontSize).font
        let gap = CGFloat(ControlRoomLook.Side.quietItemGap)
        label.preferredMaxLayoutWidth = max(0, width - glyph.intrinsicContentSize.width - gap)
        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = gap
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(text)
        row.frame.size = row.fittingSize
        return row
    }
}
