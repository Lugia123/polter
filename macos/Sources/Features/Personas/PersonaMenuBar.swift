import AppKit

/// The `Role ▸` item in the menu bar's Agents menu.
///
/// **Why this exists at all.** The four per-terminal agent actions are in
/// three places -- the menu bar, the tab strip's right-click menu, and the
/// terminal's own. `Role` was in the two right-click menus and not in the
/// menu bar, which is the shape that hides best: the feature works, and a
/// person who learned that the menu bar is where per-terminal agent things
/// live looks there, finds nothing, and concludes it was never built.
/// `tools/the-role-submenu-is-wherever-the-agent-rows-are.py` is the floor
/// under that, so the next menu to grow the rows cannot forget this one.
///
/// **Why a delegate and not a one-time build.** The other two copies are
/// built at the moment of the right-click, against the terminal that was
/// clicked. The menu bar's copy has no such moment and no such terminal: it
/// is one item, reused for whichever terminal is focused when the menu is
/// pulled down, and the persona under it changes while it sits there. Built
/// once at launch it would be a mark that stops being true the first time the
/// user switches tabs -- and roles.md §5.3 is that an out-of-date mark and a
/// correct one look exactly alike.
///
/// **Delegate of the Agents menu, not of the submenu.** The parent item's
/// title is one of the two claims that are not allowed to be wrong ("Role:
/// 射手"), and it is drawn when the *Agents* menu opens, not when the
/// submenu does. Hanging this off the submenu would refresh the rows in time
/// and the title one open too late.
@MainActor
final class PersonaMenuBar: NSObject, NSMenuDelegate {
    /// The nib's item. Weak: the nib owns it, this only fills it in.
    private weak var item: NSMenuItem?

    /// `Launch with Role ▸`, put right under `Role ▸` by `attach`. Made in
    /// code rather than in the nib because it is rebuilt on every open
    /// anyway and has no title of its own to translate there.
    private var launchItem: NSMenuItem?

    /// Take over the item `MainMenu.xib` holds for the role submenu.
    func attach(to item: NSMenuItem) {
        self.item = item

        // The menu the item is *in*, i.e. Agents -- see the note above on
        // which menu's opening has to be the trigger.
        item.menu?.delegate = self

        if let menu = item.menu {
            let launch = RoleLaunchMenu.makeItem(target: nil)
            menu.insertItem(launch, at: menu.index(of: item) + 1)
            launchItem = launch
        }

        // Filled in once here as well, so the item is never a dead row: a
        // menu bar item with no submenu is greyed out, and greyed-out reads
        // as "not built" rather than "not opened yet".
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // This object is the delegate of exactly one menu, but saying so is
        // a claim about a wiring somewhere else; checking costs nothing.
        guard menu === item?.menu else { return }
        rebuild()
    }

    private func rebuild() {
        guard let item else { return }

        // One reading of "which terminal", used for both the state shown and
        // the target acted on. Two lookups would be two answers the moment
        // focus moved between them, and the menu would then be describing one
        // terminal while pointing at another.
        let surface = Self.focusedSurface

        let catalog = PersonaCatalog.shared
        catalog.reload()
        surface?.reloadPersonaFace()

        PersonaMenu.configure(
            item,
            state: surface?.poltergeistPersonaState ?? .none,
            shielded: surface?.poltergeistShielded ?? false,
            personas: catalog.personas,
            personasKnown: catalog.isKnown,
            target: surface)

        if let launchItem {
            RoleLaunchMenu.configure(launchItem, target: surface)
        }
    }

    /// The terminal the menu bar is about.
    ///
    /// `keyWindow` is the focused one; `mainWindow` is the fallback for the
    /// moments AppKit has no key window but the app is still frontmost. With
    /// neither, `nil` -- and a `nil` target is not a silent failure here: the
    /// submenu is built from `PersonaState.none`, which is the same "no
    /// persona, nobody connected" it would show for a terminal that has none.
    private static var focusedSurface: Ghostty.SurfaceView? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return (window?.windowController as? BaseTerminalController)?.focusedSurface
    }
}
