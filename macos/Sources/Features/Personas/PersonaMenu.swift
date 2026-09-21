import AppKit

/// What a context menu's owner has to be able to do for the `Role` submenu
/// to act on the right terminal.
///
/// Two menus carry this submenu -- the tab strip's (`TerminalWindow`, acting
/// on the tab that was right-clicked, which is not necessarily the focused
/// one) and the terminal's own (`SurfaceView`, acting on itself). The items
/// are identical; only who they point at differs. So the building happens
/// here once and the two targets conform, rather than the same menu being
/// written out twice and drifting.
@MainActor
@objc protocol PersonaMenuTarget: AnyObject {
    /// `sender.representedObject` is the persona key as a `String`, or `nil`
    /// for "No Role". One selector serves every persona because the item
    /// carries the key.
    func setPoltergeistPersona(_ sender: NSMenuItem)

    func showPoltergeistPersonaEditor(_ sender: NSMenuItem)
}

@MainActor
enum PersonaMenu {
    static let itemIdentifier = NSUserInterfaceItemIdentifier("com.lugia.polter.personaSubmenu")

    /// The `Role ▸` item, ready to be added to a context menu.
    ///
    /// - Parameters:
    ///   - state: this terminal's persona, as the core reports it.
    ///   - shielded: the user has put this terminal out of reach. Nothing
    ///     may re-equip it, a supervisor included (roles.md §7.2).
    ///   - personas: the user-defined closed set, as the core reported it.
    ///   - personasKnown: whether anything has reported that set *at all*.
    ///     `false` and an empty `personas` are different facts and get
    ///     different sentences.
    ///   - target: who the items act on.
    ///   - imagesDesired: whether this system puts icons on menu items.
    ///     Defaults to what the running system says, which is what every
    ///     caller in the app uses; it is a parameter at all because the
    ///     other answer is unreachable on a macOS 26 machine and is the
    ///     answer every older one gets. See
    ///     `NSMenuItem.menuItemImagesAreDesired`.
    ///
    /// Takes its inputs rather than reaching for `PersonaCatalog.shared`, so
    /// that the whole menu is a function of its arguments and can be built
    /// -- and checked -- without an app, a window, or a screen.
    static func makeItem(
        state: PersonaState,
        shielded: Bool = false,
        personas: [Persona],
        personasKnown: Bool,
        target: PersonaMenuTarget?,
        imagesDesired: Bool = NSMenuItem.menuItemImagesAreDesired
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        configure(
            item,
            state: state,
            shielded: shielded,
            personas: personas,
            personasKnown: personasKnown,
            target: target,
            imagesDesired: imagesDesired)
        return item
    }

    /// The same item, onto one that already exists.
    ///
    /// The menu bar's copy comes out of `MainMenu.xib` and cannot be replaced
    /// wholesale, only filled in -- and it has to be re-filled every time the
    /// menu opens, because the terminal it is about changes underneath it.
    /// So the building is expressed as "make this item be the role item", and
    /// `makeItem` is that applied to a fresh one. A third menu was the moment
    /// to find out whether one builder really served them all; it does, and
    /// this is the whole of the difference.
    ///
    /// The title is set here rather than by the caller: it is one of the two
    /// claims that are not allowed to be wrong (see `title(state:personas:)`),
    /// and a caller free to set it is a caller free to get it wrong.
    static func configure(
        _ item: NSMenuItem,
        state: PersonaState,
        shielded: Bool = false,
        personas: [Persona],
        personasKnown: Bool,
        target: PersonaMenuTarget?,
        imagesDesired: Bool = NSMenuItem.menuItemImagesAreDesired
    ) {
        item.title = title(state: state, personas: personas)
        item.identifier = itemIdentifier
        item.setImage(systemSymbolName: PersonaSymbol.parent.rawValue, desired: imagesDesired)
        item.submenu = makeSubmenu(
            state: state,
            shielded: shielded,
            personas: personas,
            personasKnown: personasKnown,
            target: target,
            imagesDesired: imagesDesired)
    }

    /// "Role" on its own, or "Role: 射手" / "Role: 射手（已改）" once one is
    /// set **and something is actually wearing it**.
    ///
    /// ⚠️ The `agentPresent` half is not decoration. roles.md §5.3: a
    /// persona is the user's intent for a terminal, not a measurement of
    /// what is running in it, so the moment nobody is connected the mark
    /// starts lying -- "and an out-of-date mark and a correct one look
    /// exactly alike". The submenu still ticks the stored persona, because
    /// the terminal still *has* it; what stops is the parent item claiming
    /// the terminal *is* it.
    /// **0.7's roles feature is not finished** (roles.md is still marked
    /// draft), so every entry point the user can reach it from says so --
    /// task 666. `(beta)` is its own translatable text rather than a literal
    /// appended after the fact: it sits inside the localized string itself,
    /// the same way `%@` does, so a translator controls its wording and
    /// placement exactly as they would any other word in the sentence.
    private static func title(state: PersonaState, personas: [Persona]) -> String {
        guard state.agentPresent, let name = state.displayName(in: personas) else {
            return String(localized: "Role (beta)", comment: "标签页右键菜单：角色子菜单，功能还没做完，标 beta")
        }
        return String(
            format: String(localized: "Role (beta): %@",
                           comment: "标签页右键菜单：角色子菜单，已经设了角色，功能还没做完，标 beta"),
            name)
    }

    private static func makeSubmenu(
        state: PersonaState,
        shielded: Bool,
        personas: [Persona],
        personasKnown: Bool,
        target: PersonaMenuTarget?,
        imagesDesired: Bool
    ) -> NSMenu {
        let menu = NSMenu()

        // Nothing to act on, so nothing may look actionable.
        //
        // **This is the one thing a menu must never do**, and it is the
        // shape this very submenu was caught in: every row enabled, a click
        // delivered, and nothing happening. `autoenablesItems = false` (see
        // the note at the end of this function) is what makes it possible --
        // it stops AppKit re-enabling the rows above, and it also stops
        // AppKit disabling a row whose target cannot answer. So the second
        // half has to be done here.
        //
        // Reachable by a person, not only by a driver: the menu bar's copy
        // is built against `NSApp.keyWindow ?? .mainWindow`, and with every
        // window closed there is no terminal to be about. Finding "some"
        // surface instead would be worse than a grey row -- it would act on
        // a terminal the user is not looking at.
        let actionable = target != nil
        if !actionable {
            menu.addItem(disabledNote(
                String(localized: "There is no terminal here to change",
                       comment: "角色菜单：没有终端可作用（例如一个窗口都没开时的菜单栏），所以下面几行是死的"),
                symbol: .noTerminal, imagesDesired: imagesDesired))
            menu.addItem(.separator())
        }

        // A shielded terminal refuses every re-equip, a supervisor included.
        // Greying the rows without saying why is just a broken menu, so the
        // reason goes above them.
        if shielded {
            menu.addItem(disabledNote(
                String(localized: "Agents are kept out of this terminal, so its role cannot be changed",
                       comment: "角色菜单：护盾的终端拒绝一切换装，对总管也一样；用词跟「不让 agent 碰此终端」对齐，好让用户认出是自己勾的那一项"),
                symbol: .shield, imagesDesired: imagesDesired))
            menu.addItem(.separator())
        }

        // The "when" goes above the choices, because it changes what picking
        // one of them means. roles.md §6: a cold host must never be able to
        // look like it already changed, and a note under a list the user has
        // already clicked in is a note read too late.
        if let note = state.hostClass.pendingRestartNote {
            menu.addItem(disabledNote(note, symbol: .pendingRestart, imagesDesired: imagesDesired))
            menu.addItem(.separator())
        }

        // roles.md §5.3: the persona is the user's intent for this terminal,
        // not a measurement of what is in it. With nobody connected it is
        // still set -- what has to stop is the claim that the terminal *is*
        // that persona.
        if state.key != nil && !state.agentPresent {
            menu.addItem(disabledNote(
                String(localized: "No agent is connected here, so nothing is wearing this yet",
                       comment: "角色菜单：这个终端里没有 agent 连着 Polter，角色存着但没兑现"),
                symbol: .noAgent, imagesDesired: imagesDesired))
            menu.addItem(.separator())
        }

        if !personasKnown {
            // Not "none are defined". Asked-and-there-are-none sends the
            // user to write `personas.json`; never-asked does not, and the
            // two are one sentence apart.
            menu.addItem(disabledNote(
                String(localized: "Nothing has reported which roles exist yet",
                       comment: "角色菜单：角色清单还没接上来源，不是「一个都没定义」"),
                symbol: .rolesUnknown, imagesDesired: imagesDesired))
        } else if personas.isEmpty {
            menu.addItem(disabledNote(
                String(localized: "No roles are defined",
                       comment: "角色菜单：用户还没定义任何角色"),
                symbol: .noRoles, imagesDesired: imagesDesired))
        } else {
            for persona in personas {
                let isCurrent = persona.key == state.key
                let entry = NSMenuItem(
                    title: isCurrent
                        ? (state.displayName(in: personas) ?? persona.name)
                        : persona.name,
                    action: #selector(PersonaMenuTarget.setPoltergeistPersona(_:)),
                    keyEquivalent: "")
                entry.target = target
                entry.representedObject = persona.key
                entry.state = isCurrent ? .on : .off
                entry.isEnabled = !shielded && actionable
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())

        // Getting back out. A terminal starts with no persona, so without
        // this the first pick would be one-way.
        let clear = NSMenuItem(
            title: String(localized: "No Role", comment: "角色菜单：清掉这个终端的角色"),
            action: #selector(PersonaMenuTarget.setPoltergeistPersona(_:)),
            keyEquivalent: "")
        clear.target = target
        clear.representedObject = nil
        clear.state = state.key == nil ? .on : .off
        clear.isEnabled = !shielded && actionable
        menu.addItem(clear)

        menu.addItem(.separator())

        // Not disabled when shielded: the editor's third pane is the
        // read-only inventory, and being able to look at a shielded
        // terminal was never the thing the shield forbids.
        let editor = NSMenuItem(
            title: String(localized: "Role Editor (beta)...", comment: "角色菜单：打开角色编辑器，功能还没做完，标 beta"),
            action: #selector(PersonaMenuTarget.showPoltergeistPersonaEditor(_:)),
            keyEquivalent: "")
        editor.target = target
        // The shield leaves this one alive on purpose -- looking at a
        // shielded terminal was never what it forbids. Having nothing to
        // look at is a different fact, and it does disable it.
        editor.isEnabled = actionable
        editor.setImage(systemSymbolName: PersonaSymbol.editor.rawValue, desired: imagesDesired)
        menu.addItem(editor)

        // A submenu built here is fully decided here, so AppKit is told not
        // to ask the target to validate it. Without this the disabled notes
        // and the shielded rows get re-enabled by the default validation,
        // which answers "yes" for anything whose target responds to the
        // selector -- and `isEnabled` set by hand is what that overrides.
        menu.autoenablesItems = false

        return menu
    }

    /// A line that is there to be read, not clicked.
    ///
    /// `action` stays `nil` so a stray click on it does nothing at all
    /// rather than nothing visible.
    private static func disabledNote(
        _ text: String,
        symbol: PersonaSymbol,
        imagesDesired: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.setImage(systemSymbolName: symbol.rawValue, desired: imagesDesired)
        return item
    }
}
