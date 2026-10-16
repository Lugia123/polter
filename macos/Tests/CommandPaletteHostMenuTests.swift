import AppKit
import Testing
@testable import Ghostty

/// #50: the menu bar's own commands -- "Load Project…" first among them --
/// were not in the command palette, because the palette listed only what the
/// core publishes. `HostMenuCommands` reads them from the menu.
@MainActor
struct CommandPaletteHostMenuTests {
    /// Receives the test menu's own actions, so an item is "this app's".
    final class Target: NSObject {
        var loaded = 0
        @objc func loadProject(_ sender: Any?) { loaded += 1 }
        @objc func saveAsProject(_ sender: Any?) {}
        @objc func newTab(_ sender: Any?) {}
    }

    private func item(_ title: String, _ action: Selector, _ target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    /// A menu bar shaped like the app's: a Project menu, a File menu whose
    /// "New Tab" the core drives, and a Window menu with AppKit's own items.
    private func menuBar(_ target: Target) -> (NSMenu, core: NSMenuItem, services: NSMenu) {
        let bar = NSMenu(title: "Main")
        bar.autoenablesItems = false

        let project = NSMenu(title: "Project")
        project.autoenablesItems = false
        project.addItem(item("Save as Project…", #selector(Target.saveAsProject(_:)), target))
        project.addItem(item("Load Project…", #selector(Target.loadProject(_:)), target))
        project.addItem(.separator())
        let greyed = item("Rename Project…", #selector(Target.saveAsProject(_:)), target)
        greyed.isEnabled = false
        project.addItem(greyed)
        let hidden = item("Hidden", #selector(Target.saveAsProject(_:)), target)
        hidden.isHidden = true
        project.addItem(hidden)

        let file = NSMenu(title: "File")
        file.autoenablesItems = false
        let newTab = item("New Tab", #selector(Target.newTab(_:)), target)
        file.addItem(newTab)

        let window = NSMenu(title: "Window")
        window.autoenablesItems = false
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), nil))
        window.addItem(item("Hide", #selector(NSApplication.hide(_:)), nil))
        window.addItem(item("Some Window", #selector(NSWindow.makeKeyAndOrderFront(_:)), nil))

        let services = NSMenu(title: "Services")
        services.autoenablesItems = false
        services.addItem(item("A Service", #selector(Target.saveAsProject(_:)), target))

        for (title, sub) in [("Project", project), ("File", file), ("Window", window), ("Services", services)] {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            bar.addItem(holder)
        }
        return (bar, newTab, services)
    }

    @Test func theProjectMenuIsOffered() {
        let target = Target()
        let (bar, core, services) = menuBar(target)
        let entries = HostMenuCommands.entries(
            in: bar,
            core: [ObjectIdentifier(core)],
            skipping: [ObjectIdentifier(services)]
        )
        #expect(entries.map(\.item.title) == ["Save as Project…", "Load Project…"])
        #expect(entries.map(\.path) == [["Project"], ["Project"]])
    }

    @Test func whatTheCoreDrivesIsNotOfferedTwice() {
        let target = Target()
        let (bar, core, _) = menuBar(target)
        let without = HostMenuCommands.entries(in: bar, core: [ObjectIdentifier(core)]).map(\.item.title)
        let with = HostMenuCommands.entries(in: bar, core: []).map(\.item.title)
        #expect(!without.contains("New Tab"))
        #expect(with.contains("New Tab"))
    }

    @Test func appKitsOwnItemsAreNotOffered() {
        #expect(HostMenuCommands.isAppKits(#selector(NSApplication.hide(_:))))
        #expect(HostMenuCommands.isAppKits(#selector(NSWindow.performMiniaturize(_:))))
        #expect(HostMenuCommands.isAppKits(#selector(NSWindow.makeKeyAndOrderFront(_:))))
        #expect(!HostMenuCommands.isAppKits(#selector(Target.loadProject(_:))))
    }

    @Test func anEnglishQueryFindsATranslatedItem() {
        #expect(HostMenuCommands.alias(for: #selector(Target.loadProject(_:))) == "load project")
        let load = CommandOption(title: "加载项目…", aliases: [HostMenuCommands.alias(for: #selector(Target.loadProject(_:)))]) {}
        let save = CommandOption(title: "存为项目…", aliases: [HostMenuCommands.alias(for: #selector(Target.saveAsProject(_:)))]) {}
        #expect([load, save].filteredAndSorted(query: "load project") == [load])
        #expect([load, save].filteredAndSorted(query: "加载项目") == [load])
    }

    /// Running an offered item is running the menu item: its target gets
    /// the action, once.
    @Test func runningAnEntryRunsTheMenuItem() {
        _ = NSApplication.shared
        let target = Target()
        let (bar, core, _) = menuBar(target)
        let load = HostMenuCommands.entries(in: bar, core: [ObjectIdentifier(core)])
            .first { $0.item.title == "Load Project…" }
        #expect(load != nil)
        if let load { #expect(HostMenuCommands.perform(load.item)) }
        #expect(target.loaded == 1)
    }
}
