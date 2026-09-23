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

    /// The nib's direct-mentions item (`MentionMenu`), when there is one.
    ///
    /// Here rather than in a delegate of its own because it sits in the same
    /// Agents menu, and a menu has exactly one delegate: a second object
    /// claiming it would silently unhook `Role`. Filled in by the same
    /// `rebuild`, from the same one reading of "which terminal".
    private weak var mentionsItem: NSMenuItem?

    /// Take over the item `MainMenu.xib` holds for the direct-mentions switch.
    ///
    /// Call after `attach(to:)`: it is that call that makes this object the
    /// Agents menu's delegate, and so what re-fills the item on every open.
    func attachMentions(to item: NSMenuItem) {
        mentionsItem = item
        rebuild()
    }

    /// Take over the item `MainMenu.xib` holds for the role submenu.
    func attach(to item: NSMenuItem) {
        self.item = item

        // The menu the item is *in*, i.e. Agents -- see the note above on
        // which menu's opening has to be the trigger.
        item.menu?.delegate = self

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
        // One reading of "which terminal", used for both the state shown and
        // the target acted on. Two lookups would be two answers the moment
        // focus moved between them, and the menu would then be describing one
        // terminal while pointing at another.
        let surface = Self.focusedSurface

        if let mentionsItem {
            MentionMenu.configure(
                mentionsItem,
                isSupervisor: surface?.poltergeistRole == .supervisor,
                allowed: surface?.poltergeistWorkerMentions ?? false,
                target: surface)
        }

        guard let item else { return }

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
    }

    /// The terminal the menu bar is about.
    ///
    /// Chosen by `terminalWindow(ordered:key:main:isTerminal:isShowing:)`;
    /// this only feeds it the app's real windows. With no terminal to be
    /// about the answer is `nil`, and a `nil` target is not a silent failure:
    /// `PersonaMenu` greys every row and says there is no terminal here
    /// (task 588), and `MentionMenu` hides its switch.
    private static var focusedSurface: Ghostty.SurfaceView? {
        let window = terminalWindow(
            ordered: NSApp.orderedWindows,
            key: NSApp.keyWindow,
            main: NSApp.mainWindow,
            isTerminal: { $0.windowController is BaseTerminalController },
            isShowing: { $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace })
        return (window?.windowController as? BaseTerminalController)?.focusedSurface
    }

    /// Which window the menu bar's per-terminal rows should be about.
    ///
    /// **Why not `keyWindow ?? mainWindow`** (task 589). That only falls back
    /// when there is no key window at all. With the role library -- or any
    /// other window of this app that is not a terminal -- in front, the key
    /// window exists and is not a terminal; and being an ordinary titled
    /// window it is the main window too, so the fallback falls back to the
    /// same thing. The rows then pointed at nobody while a terminal sat in
    /// plain view right behind it.
    ///
    /// So the question asked is "is it a terminal", not "is it key":
    ///
    ///   1. the key window, if it is a terminal -- the ordinary case, and
    ///      unchanged;
    ///   2. else the main window, if it is a terminal (a panel can be key
    ///      without being main, leaving the terminal behind it main);
    ///   3. else the frontmost terminal that is actually on screen here --
    ///      the one behind whatever is in front. Only a showing one: a
    ///      minimised terminal, or one on another Space, is not one the user
    ///      is looking at, and acting on it would be worse than a grey row;
    ///   4. else none.
    ///
    /// Generic over the window type, and every question about a window is
    /// passed in, so it can be decided -- and checked -- without an app or a
    /// window server.
    static func terminalWindow<W: AnyObject>(
        ordered: [W],
        key: W?,
        main: W?,
        isTerminal: (W) -> Bool,
        isShowing: (W) -> Bool
    ) -> W? {
        if let key, isTerminal(key) { return key }
        if let main, isTerminal(main) { return main }
        return ordered.first { isTerminal($0) && isShowing($0) }
    }
}
