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
    ///
    /// Takes its inputs rather than reaching for `PersonaCatalog.shared`, so
    /// that the whole menu is a function of its arguments and can be built
    /// -- and checked -- without an app, a window, or a screen.
    static func makeItem(
        state: PersonaState,
        shielded: Bool = false,
        personas: [Persona],
        personasKnown: Bool,
        target: PersonaMenuTarget?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title(state: state, personas: personas),
                              action: nil,
                              keyEquivalent: "")
        item.identifier = itemIdentifier
        item.setImageIfDesired(systemSymbolName: "person.crop.square.filled.and.at.rectangle")
        item.submenu = makeSubmenu(
            state: state,
            shielded: shielded,
            personas: personas,
            personasKnown: personasKnown,
            target: target)
        return item
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
    private static func title(state: PersonaState, personas: [Persona]) -> String {
        guard state.agentPresent, let name = state.displayName(in: personas) else {
            return String(localized: "Role", comment: "标签页右键菜单：角色子菜单")
        }
        return String(
            format: String(localized: "Role: %@",
                           comment: "标签页右键菜单：角色子菜单，已经设了角色"),
            name)
    }

    private static func makeSubmenu(
        state: PersonaState,
        shielded: Bool,
        personas: [Persona],
        personasKnown: Bool,
        target: PersonaMenuTarget?
    ) -> NSMenu {
        let menu = NSMenu()

        // A shielded terminal refuses every re-equip, a supervisor included.
        // Greying the rows without saying why is just a broken menu, so the
        // reason goes above them.
        if shielded {
            menu.addItem(disabledNote(
                String(localized: "This terminal is shielded, so nothing may change what it hands out",
                       comment: "角色菜单：护盾的终端拒绝一切换装，对总管也一样"),
                symbol: "lock"))
            menu.addItem(.separator())
        }

        // The "when" goes above the choices, because it changes what picking
        // one of them means. roles.md §6: a cold host must never be able to
        // look like it already changed, and a note under a list the user has
        // already clicked in is a note read too late.
        if let note = state.hostClass.pendingRestartNote {
            menu.addItem(disabledNote(note, symbol: "clock.arrow.circlepath"))
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
                symbol: "person.slash"))
            menu.addItem(.separator())
        }

        if !personasKnown {
            // Not "none are defined". Asked-and-there-are-none sends the
            // user to write `personas.json`; never-asked does not, and the
            // two are one sentence apart.
            menu.addItem(disabledNote(
                String(localized: "Nothing has reported which roles exist yet",
                       comment: "角色菜单：角色清单还没接上来源，不是「一个都没定义」"),
                symbol: "ellipsis"))
        } else if personas.isEmpty {
            menu.addItem(disabledNote(
                String(localized: "No roles are defined",
                       comment: "角色菜单：用户还没定义任何角色"),
                symbol: "tray"))
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
                entry.isEnabled = !shielded
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
        clear.isEnabled = !shielded
        menu.addItem(clear)

        menu.addItem(.separator())

        // Not disabled when shielded: the editor's third pane is the
        // read-only inventory, and being able to look at a shielded
        // terminal was never the thing the shield forbids.
        let editor = NSMenuItem(
            title: String(localized: "Role Editor...", comment: "角色菜单：打开角色编辑器"),
            action: #selector(PersonaMenuTarget.showPoltergeistPersonaEditor(_:)),
            keyEquivalent: "")
        editor.target = target
        editor.setImageIfDesired(systemSymbolName: "slider.horizontal.3")
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
    private static func disabledNote(_ text: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.setImageIfDesired(systemSymbolName: symbol)
        return item
    }
}
