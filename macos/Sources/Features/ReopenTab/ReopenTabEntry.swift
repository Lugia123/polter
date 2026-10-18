import AppKit

/// Whether File › "Reopen Closed Tab" is shown, and hiding it when it is not.
///
/// **Hidden, not removed** (task 1708): with projects the item has stopped
/// earning its place, so the entry point is switched off and `ClosedTabs`,
/// `reopenClosedTab(_:)` and the nib item are all kept. Turning it back on is
/// `offered = true` here, together with the core's
/// `reopen_closed_tab_offered` in `Config.zig`, which owns the default
/// `⇧⌘T` binding, and `reopen::OFFERED` on Windows.
///
/// The command palette needs nothing of its own: `HostMenuCommands` skips a
/// hidden menu item.
enum ReopenTabEntry {
    static let offered = false

    /// Hide every item in `menu` that runs `action`, take its key equivalent
    /// away, and hide a separator the hiding left doubled. Does nothing when
    /// `offered`, so the nib's own item, title and key come back untouched.
    ///
    /// **The key equivalent goes as well as the item.** AppKit does not match
    /// a hidden item's key by default, but that is a property
    /// (`allowsKeyEquivalentWhenHidden`) rather than a promise, and a key that
    /// still works with nothing on screen to say so is exactly what hiding
    /// must not leave behind.
    static func apply(to menu: NSMenu, action: Selector, offered: Bool = offered) {
        guard !offered else { return }
        for item in menu.items where item.action == action {
            item.isHidden = true
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
        hideDoubledSeparators(in: menu)
    }

    /// A separator straight after another visible separator, or at either
    /// end of what is visible, separates nothing.
    private static func hideDoubledSeparators(in menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem && previousWasSeparator {
                item.isHidden = true
                continue
            }
            previousWasSeparator = item.isSeparatorItem
        }
        if let last = menu.items.last(where: { !$0.isHidden }), last.isSeparatorItem {
            last.isHidden = true
        }
    }
}
