import AppKit

/// Something a "Launch with Role" row can be pointed at: a terminal, whose
/// tab the new one opens beside.
@objc protocol RoleLaunchTarget {
    func launchWithRole(_ sender: NSMenuItem)
}

/// `Launch with Role ▸`: every role, and for a role set up for more than one
/// agent CLI, which one.
///
/// Built in one place for the three menus it appears in -- the tab's
/// right-click menu, the terminal's, and the Agents menu -- so that they
/// cannot come to offer different things.
///
/// **Separate from `Role ▸`**, which puts a role on a terminal that is
/// already running. That one changes what an agent already there can use;
/// this one starts a new agent. Folding both into one submenu would put two
/// rows called "Archer" next to each other that do entirely different
/// things.
@MainActor
enum RoleLaunchMenu {
    static let itemIdentifier = NSUserInterfaceItemIdentifier("polter.roleLaunch")

    static func makeItem(
        target: RoleLaunchTarget?,
        imagesDesired: Bool = NSMenuItem.menuItemImagesAreDesired
    ) -> NSMenuItem {
        let item = NSMenuItem()
        configure(item, target: target, imagesDesired: imagesDesired)
        return item
    }

    /// Fill `item` in from the library as it is now.
    static func configure(
        _ item: NSMenuItem,
        target: RoleLaunchTarget?,
        imagesDesired: Bool = NSMenuItem.menuItemImagesAreDesired
    ) {
        let library = RoleLibrary.shared
        library.reload()
        configure(
            item,
            catalog: library.catalog,
            clis: library.clis,
            target: target,
            imagesDesired: imagesDesired)
    }

    /// The same, from values, which is what the tests build it from.
    static func configure(
        _ item: NSMenuItem,
        catalog: RoleCatalog,
        clis: AgentCliSnapshot,
        target: RoleLaunchTarget?,
        imagesDesired: Bool = NSMenuItem.menuItemImagesAreDesired
    ) {
        item.title = String(localized: "Launch with Role", comment: "用角色启动：菜单项，开一个新标签页并用某个角色启动 agent CLI")
        item.identifier = itemIdentifier
        item.action = nil
        item.isEnabled = true
        item.setImage(systemSymbolName: "person.crop.rectangle.stack", desired: imagesDesired)
        item.submenu = makeSubmenu(catalog: catalog, clis: clis, target: target)
    }

    static func makeSubmenu(
        catalog: RoleCatalog,
        clis: AgentCliSnapshot,
        target: RoleLaunchTarget?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if target == nil {
            menu.addItem(disabledNote(String(localized: "Open a terminal window first", comment: "用角色启动：没有终端可以在旁边开新标签页")))
        }

        if !catalog.loaded {
            menu.addItem(disabledNote(String(localized: "Reading the role library…", comment: "角色库：还没读到角色文件")))
        } else if catalog.roles.isEmpty {
            menu.addItem(disabledNote(String(localized: "No roles yet", comment: "角色库：一个角色都没有")))
        }

        for role in catalog.roles {
            menu.addItem(row(for: role, clis: clis, target: target))
        }

        menu.addItem(.separator())
        let library = NSMenuItem(
            title: String(localized: "Role Library...", comment: "用角色启动：打开角色库窗口"),
            action: #selector(RoleLibraryOpener.showRoleLibrary(_:)),
            keyEquivalent: "")
        library.target = RoleLibraryOpener.shared
        library.isEnabled = true
        menu.addItem(library)

        return menu
    }

    private static func row(for role: Role, clis: AgentCliSnapshot, target: RoleLaunchTarget?) -> NSMenuItem {
        let item = NSMenuItem(title: role.name, action: nil, keyEquivalent: "")
        if !role.summary.isEmpty { item.toolTip = role.summary }

        switch role.clis.count {
        case 0:
            // Shown and not clickable, rather than hidden: a role that is
            // missing from this menu looks like a role that was never saved.
            item.title = String(format: String(localized: "%@ (no agent CLI chosen)", comment: "用角色启动：角色还没选 CLI，%@ 是角色名"), role.name)
            item.isEnabled = false

        case 1:
            item.action = #selector(RoleLaunchTarget.launchWithRole(_:))
            item.target = target
            item.representedObject = [role.key, role.clis[0].cli]
            item.isEnabled = target != nil

        default:
            item.isEnabled = true
            let sub = NSMenu()
            sub.autoenablesItems = false
            for choice in role.clis {
                let cliItem = NSMenuItem(
                    title: clis.label(for: choice.cli),
                    action: #selector(RoleLaunchTarget.launchWithRole(_:)),
                    keyEquivalent: "")
                cliItem.target = target
                cliItem.representedObject = [role.key, choice.cli]
                cliItem.isEnabled = target != nil
                sub.addItem(cliItem)
            }
            item.submenu = sub
        }
        return item
    }

    private static func disabledNote(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The role and CLI a launch row carries.
    static func launchPair(_ sender: NSMenuItem) -> (key: String, cli: String)? {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The role couldn't be launched", comment: "用角色启动：失败弹窗标题")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Opens the role library from a menu row. A target of its own because the
/// row is useful with no terminal at all -- that is when somebody sets up
/// their first role.
@MainActor
final class RoleLibraryOpener: NSObject {
    static let shared = RoleLibraryOpener()

    @objc func showRoleLibrary(_ sender: Any?) {
        RoleLibraryWindow.shared.present()
    }
}

extension Ghostty.SurfaceView: RoleLaunchTarget {
    @objc func launchWithRole(_ sender: NSMenuItem) {
        guard let pair = RoleLaunchMenu.launchPair(sender), let surface else { return }
        if let error = RoleLibrary.launch(from: surface, key: pair.key, cli: pair.cli) {
            RoleLaunchMenu.showError(error)
        }
    }
}

extension TerminalController: RoleLaunchTarget {
    @objc func launchWithRole(_ sender: NSMenuItem) {
        focusedSurface?.launchWithRole(sender)
    }
}
