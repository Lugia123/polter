import AppKit

/// What a menu's owner has to be able to do for the direct-mentions switch
/// to act on the right terminal.
@MainActor
@objc protocol MentionMenuTarget: AnyObject {
    func togglePoltergeistDirectMentions(_ sender: NSMenuItem)
}

/// The **Let Workers Name Each Other Directly** switch, in one place.
///
/// **Why a builder and not a fourth copy of a row.** The per-terminal agent
/// rows live in three menus -- the menu bar's Agents menu, the tab strip's
/// right-click menu, and the terminal's own -- and the first three of them
/// are written out three times. That is how `Role` came to be in two of the
/// three and missing from the menu bar for a release (task 582): nothing
/// was comparing them. This one is built once and called three times, so
/// the three cannot drift, and
/// `tools/the-role-submenu-is-wherever-the-agent-rows-are.py` can check the
/// call rather than the contents.
///
/// **What the switch is.** `dev-docs/poltergeist/mentions.md` §5: a worker
/// naming another worker is rewritten into a mention of that worker's
/// supervisor by default, because workers cannot reach each other and a
/// direct mention would be a way around that. §6 makes the rewrite
/// switchable -- **per supervisor, off by default** -- because both modes
/// are meant to be run for a while and compared, so neither is an escape
/// hatch bolted onto the other.
@MainActor
enum MentionMenu {
    static let itemIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.poltergeistDirectMentions")

    /// The item, ready to be added to a context menu.
    ///
    /// - Parameters:
    ///   - isSupervisor: whether this terminal is a supervisor. The switch
    ///     belongs to one (§6), so on any other terminal there is nothing
    ///     for it to be about.
    ///   - allowed: whether that supervisor currently lets its workers name
    ///     each other directly.
    ///   - target: who the item acts on.
    ///
    /// Takes its inputs rather than reaching for shared state, for
    /// `PersonaMenu`'s reason: a menu that is a function of its arguments
    /// can be built -- and checked -- without an app, a window or a screen.
    static func makeItem(
        isSupervisor: Bool,
        allowed: Bool,
        target: MentionMenuTarget?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        configure(item, isSupervisor: isSupervisor, allowed: allowed, target: target)
        return item
    }

    /// The same item, onto one that already exists.
    ///
    /// The menu bar's copy comes out of `MainMenu.xib` and can only be
    /// filled in, not replaced -- and it has to be re-filled every time the
    /// menu opens, because the terminal it is about changes underneath it.
    static func configure(
        _ item: NSMenuItem,
        isSupervisor: Bool,
        allowed: Bool,
        target: MentionMenuTarget?
    ) {
        item.title = String(
            localized: "Let Workers Name Each Other Directly",
            comment: "agent 菜单：允许 worker 之间直接点名，不改写给主管；作用域是这个主管")
        item.identifier = itemIdentifier
        item.action = #selector(MentionMenuTarget.togglePoltergeistDirectMentions(_:))
        item.target = target
        item.setImageIfDesired(systemSymbolName: "at")

        // Ticked when it is on, like the four rows beside it: an item that
        // has been used has to read differently from one that has not, or
        // the only way to learn whether the last click landed is to click
        // it again.
        item.state = allowed ? .on : .off

        // **Hidden rather than greyed, and that is a decision.** The other
        // agent rows are about *this* terminal and apply to every terminal,
        // so greying one says something useful. This switch is a property of
        // a supervisor; on a worker it is not disabled, it is not about
        // anything. A greyed row here would send somebody looking for the
        // reason it is greyed, and the reason would be "you are looking at
        // the wrong terminal".
        item.isHidden = !isSupervisor
        item.isEnabled = isSupervisor
    }
}
