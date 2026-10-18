import AppKit
import Testing
@testable import Ghostty

/// File › "Reopen Closed Tab" is hidden with its key (task 1708).
@MainActor
struct ReopenTabEntryTests {
    final class Target: NSObject {
        @objc func newTab(_ sender: Any?) {}
        @objc func reopenClosedTab(_ sender: Any?) {}
        @objc func splitRight(_ sender: Any?) {}
    }

    private let reopen = #selector(Target.reopenClosedTab(_:))

    /// The nib's File menu around the item: New Tab, a separator, the item
    /// with `⇧⌘T`, a separator, Split Right.
    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(NSMenuItem(title: "New Tab", action: #selector(Target.newTab(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reopen Closed Tab", action: reopen, keyEquivalent: "T"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Split Right", action: #selector(Target.splitRight(_:)), keyEquivalent: ""))
        return menu
    }

    private func visible(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    @Test func theEntryIsSwitchedOff() {
        #expect(ReopenTabEntry.offered == false)
    }

    @Test func hiddenWithItsKeyAndOneSeparatorLeft() {
        let menu = fileMenu()
        ReopenTabEntry.apply(to: menu, action: reopen)

        #expect(visible(menu) == ["New Tab", "-", "Split Right"])
        // Still in the menu, so turning it back on is a constant, not a nib edit.
        let item = menu.items.first { $0.action == reopen }
        #expect(item?.isHidden == true)
        #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test func offeredLeavesTheNibAlone() {
        let menu = fileMenu()
        ReopenTabEntry.apply(to: menu, action: reopen, offered: true)

        #expect(visible(menu) == ["New Tab", "-", "Reopen Closed Tab", "-", "Split Right"])
        #expect(menu.items.first { $0.action == reopen }?.keyEquivalent == "T")
    }
}
