import AppKit

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

        (window as? TerminalWindow)?.polterAppendTabSections(to: menu, target: self)
        return menu
    }
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
