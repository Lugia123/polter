import AppKit
import GhosttyKit
import OSLog

/// The menu of a pane's title and of a stack's tab (task 1582).
///
/// **The tab's menu, for this pane.** A terminal that runs a program that
/// takes the mouse -- an agent CLI, an editor -- keeps its own right-click,
/// so nothing here takes the terminal's: the menu is on the title and the
/// tabs over it. Everything below the first section is the window tab's
/// menu, built by the same code (`TerminalWindow.polterAppendTabSections`);
/// the pane is given the keyboard first, so what is about one terminal is
/// about this one.
extension TerminalController {
    /// The menu for `view`'s title, or -- with `stack` -- for its tab in the
    /// strip of a stack, where "close others / to the right / to the left"
    /// are added for that stack's tabs.
    func polterPaneMenu(for view: Ghostty.SurfaceView, inStack stacked: Bool) -> NSMenu {
        // The pane is the one the menu is about: it takes the keyboard, and
        // nothing else changes. One stacked behind is brought to the front
        // first -- a terminal nobody can see does not take the keyboard.
        if surfaceTree.stack(of: view) != nil, !surfaceTree.isShown(view) {
            showStackMember(view)
        }
        focusedSurface = view
        Ghostty.moveFocus(to: view)

        let menu = NSMenu()
        menu.autoenablesItems = true

        menu.addItem(PolterMenuAction.item(
            String(localized: "Close Terminal", comment: "分屏标题和层叠标签左端的 x；层叠标签右键菜单：关闭这一个终端"),
            symbol: "xmark") { [weak self, weak view] in
                guard let self, let view else { return }
                self.performAction("close_surface", on: view)
            })

        if stacked, let stack = surfaceTree.stack(of: view),
           let index = stack.members.firstIndex(where: { $0 === view }) {
            let entries: [(PolterPaneTabRules.Closing, String, String)] = [
                (.others, String(localized: "Close Others", comment: "层叠标签右键菜单：关闭这一叠里的其他终端"), "xmark.square"),
                (.right, String(localized: "Close to the Right", comment: "层叠标签右键菜单：关闭这一叠里右侧的终端"), "arrow.right.to.line"),
                (.left, String(localized: "Close to the Left", comment: "层叠标签右键菜单：关闭这一叠里左侧的终端"), "arrow.left.to.line"),
            ]
            for (which, title, symbol) in entries {
                let members = PolterPaneTabRules.closing(which, at: index, count: stack.members.count)
                    .map { stack.members[$0] }
                // Greyed when there is nothing that way (`offers`).
                menu.addItem(PolterMenuAction.item(title, symbol: symbol, enabled: !members.isEmpty) { [weak self] in
                    self?.polterCloseStacked(members)
                })
            }
        }

        // This pane's terminal id, for pasting to an agent (task 1643).
        if let copy = TerminalIDMenu.item(for: view) {
            menu.addItem(.separator())
            menu.addItem(copy)
        }

        menu.addItem(.separator())

        // The window tab's own items, which the system puts on its menu.
        let tabItems: [(String, String, Selector)] = [
            (String(localized: "Close Tab", comment: "分屏标题右键菜单：关闭这一格所在的标签页"), "xmark", NSSelectorFromString("performClose:")),
            (String(localized: "Close Other Tabs", comment: "分屏标题右键菜单：关闭其他标签页"), "xmark", NSSelectorFromString("performCloseOtherTabs:")),
        ]
        for (title, symbol, action) in tabItems {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = window
            item.setImageIfDesired(systemSymbolName: symbol)
            menu.addItem(item)
        }
        menu.addItem(TerminalWindow.polterCloseTabsToTheRightItem(target: self))
        let move = NSMenuItem(
            title: String(localized: "Move Tab to New Window", comment: "分屏标题右键菜单：把这一格所在的标签页移到新窗口"),
            action: NSSelectorFromString("moveTabToNewWindow:"), keyEquivalent: "")
        move.target = window
        menu.addItem(move)

        // Without the tab's «Copy Terminal ID»: the row above is this pane's,
        // and the tab's would be a second one about the same thing.
        (window as? TerminalWindow)?.polterAppendTabSections(to: menu, target: self, copyIDs: false)
        return menu
    }
}

/// «Copy Terminal ID» on the three menus (task 1643): the terminal's own,
/// a pane's title and a stack's tab, and the window tab's. What they copy
/// and say is `TerminalIDCopy`; this is the part that needs AppKit.
enum TerminalIDMenu {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", category: "terminal-id")

    /// The id of `view`'s terminal; 0 when it has no surface.
    static func id(of view: Ghostty.SurfaceView) -> UInt64 {
        guard let surface = view.surface else { return 0 }
        return ghostty_surface_poltergeist_id(surface)
    }

    static func entry(_ view: Ghostty.SurfaceView) -> TerminalIDCopy.Entry {
        .init(id: id(of: view), title: view.title)
    }

    /// Put `text` on the clipboard. Nothing is shown: the person pastes it.
    static func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(text, forType: .string)
        logger.info("copied \(what, privacy: .public): \(text, privacy: .public) ok=\(ok)")
    }

    /// «Copy Terminal ID» for one terminal; nil when it has no id.
    static func item(for view: Ghostty.SurfaceView) -> NSMenuItem? {
        let entry = entry(view)
        guard TerminalIDCopy.known(entry.id) else { return nil }
        return PolterMenuAction.item(title, symbol: symbol) {
            copy(TerminalIDCopy.text(entry.id), what: "terminal id")
        }
    }

    /// The tab's: one terminal is copied straight; several get a submenu of
    /// one row each and «Copy All». Nil when no terminal has an id.
    static func tabItem(for views: [Ghostty.SurfaceView]) -> NSMenuItem? {
        switch TerminalIDCopy.offer(views.map(entry)) {
        case nil:
            return nil
        case .single(let entry):
            return PolterMenuAction.item(title, symbol: symbol) {
                copy(TerminalIDCopy.text(entry.id), what: "terminal id")
            }
        case .each(let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: symbol)
            let submenu = NSMenu()
            submenu.autoenablesItems = true
            for entry in entries {
                submenu.addItem(PolterMenuAction.item(TerminalIDCopy.rowLabel(entry), symbol: "") {
                    copy(TerminalIDCopy.text(entry.id), what: "terminal id")
                })
            }
            submenu.addItem(.separator())
            submenu.addItem(PolterMenuAction.item(
                String(localized: "Copy All", comment: "标签页右键菜单·复制终端 ID 子菜单最下面：把这个标签页里每个终端的标题和 ID 按行复制"),
                symbol: "doc.on.doc") {
                    copy(TerminalIDCopy.allText(entries), what: "\(entries.count) terminal ids")
                })
            item.submenu = submenu
            return item
        }
    }

    private static var title: String {
        String(localized: "Copy Terminal ID", comment: "右键菜单（终端、分屏标题、层叠标签、标签页）：复制 MCP 工具认的终端 ID（0x…），用来告诉 AI 操作哪个终端")
    }

    private static let symbol = "number"
}

/// A menu item that runs a closure. The item keeps the action alive, and
/// says itself whether it is enabled, so the menu can validate the rest.
final class PolterMenuAction: NSObject, NSMenuItemValidation {
    private let run: () -> Void
    private let enabled: Bool

    private init(_ run: @escaping () -> Void, enabled: Bool) {
        self.run = run
        self.enabled = enabled
    }

    // ⚠️ Not `perform(_:)`: inside an `NSObject` that name is also
    // `perform(_ aSelector:)`, `#selector` took that one, and every item
    // threw "unrecognized selector" from the menu (measured, task 1582).
    @objc private func polterRun(_ sender: Any?) {
        run()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        enabled
    }

    static func item(_ title: String, symbol: String, enabled: Bool = true, run: @escaping () -> Void) -> NSMenuItem {
        let action = PolterMenuAction(run, enabled: enabled)
        let item = NSMenuItem(title: title, action: #selector(polterRun(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.setImageIfDesired(systemSymbolName: symbol)
        return item
    }
}
