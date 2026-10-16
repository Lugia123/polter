import AppKit

/// The menu bar's own commands, for the command palette (#50).
///
/// **The palette used to list only the core's commands** -- its rows came from
/// `command-palette-entry`, and a row the app implements itself ("Load
/// Project…", "Keyboard Shortcuts…") is one the core has never heard of. So
/// those could be reached from the menu bar and from nowhere you could type
/// into. These are read **from the menu bar itself** each time the palette
/// asks, rather than written out again here: a second list is a second thing
/// to keep in step, and the day it fell behind, a new menu item would be
/// missing from the palette with nothing going red. Windows does the same
/// from its own menu table (`windows/host/src/menu.rs`, `host_commands`).
///
/// What is left out, and why:
///  * an item the core's binding table already drives (`core`): the palette
///    has that command already, under the core's title;
///  * an item whose action AppKit implements (Hide, Minimize, the window
///    list, Services): those are the system's, not this app's;
///  * separators, submenus (their items are walked instead), hidden items,
///    and an item the menu would grey right now -- a search result you
///    cannot act on is worse than one that is not offered.
enum HostMenuCommands {
    struct Entry {
        let item: NSMenuItem
        /// The menus above the item, outermost first: "Project", or
        /// "Window", "Stack".
        let path: [String]
    }

    /// The items of `menu` and its submenus that the palette should offer.
    /// `core` holds the items the core's binding table drives; `skipping`
    /// holds menus not to walk at all (Services).
    @MainActor
    static func entries(
        in menu: NSMenu,
        core: Set<ObjectIdentifier>,
        skipping: Set<ObjectIdentifier> = [],
        path: [String] = []
    ) -> [Entry] {
        guard !skipping.contains(ObjectIdentifier(menu)) else { return [] }
        // Enablement is only as fresh as the last validation; a menu that
        // has not been opened since the page in front changed would answer
        // for the old page.
        menu.update()
        var out: [Entry] = []
        for item in menu.items {
            if item.isSeparatorItem || item.isHidden { continue }
            if let sub = item.submenu {
                out += entries(in: sub, core: core, skipping: skipping, path: path + [item.title])
                continue
            }
            guard let action = item.action, item.isEnabled, !item.title.isEmpty else { continue }
            if core.contains(ObjectIdentifier(item)) { continue }
            if isAppKits(action) { continue }
            out.append(Entry(item: item, path: path))
        }
        return out
    }

    /// Whether AppKit itself implements `action` -- `hide:`, `performZoom:`,
    /// `makeKeyAndOrderFront:` (the window list), `terminate:`. Asked of the
    /// base classes, so an action this app adds to a subclass is not one.
    static func isAppKits(_ action: Selector) -> Bool {
        NSApplication.instancesRespond(to: action)
            || NSWindow.instancesRespond(to: action)
            || NSTextView.instancesRespond(to: action)
    }

    /// The action as words to search by: `loadProject:` is "load project".
    /// **The title is translated and the selector never is**, so this is what
    /// lets an English query find the item in a Chinese interface -- the same
    /// rule `CommandOption.actionAlias` applies to the core's actions.
    static func alias(for action: Selector) -> String {
        var words = ""
        for ch in NSStringFromSelector(action) where ch != ":" {
            if ch.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(contentsOf: ch.lowercased())
        }
        return words
    }

    /// Run the item **the way a click on it runs**: through its menu, so the
    /// responder chain, validation and anything the menu does around a pick
    /// are the same. False when the item is no longer in a menu or the menu
    /// would grey it now.
    @MainActor
    @discardableResult
    static func perform(_ item: NSMenuItem) -> Bool {
        guard let menu = item.menu else { return false }
        menu.update()
        let index = menu.index(of: item)
        guard index >= 0, item.isEnabled else { return false }
        menu.performActionForItem(at: index)
        return true
    }
}
