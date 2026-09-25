import AppKit

extension NSAlert {
    static func reviewWindowsAlert(
        messageText: String,
        informativeText: String = String(localized: "If you don't review your windows, any running processes will be terminated", comment: "应用级提醒框／Dock 菜单"),
        terminateNowButtonTitle: String = String(localized: "Terminate Processes", comment: "应用级提醒框／Dock 菜单")
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "Review Windows...", comment: "应用级提醒框／Dock 菜单"))
        alert.addButton(withTitle: terminateNowButtonTitle)
        alert.addButton(withTitle: String(localized: "Cancel", comment: "应用级提醒框／Dock 菜单"))
        alert.alertStyle = .warning

        return alert
    }
}
