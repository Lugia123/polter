import AppKit
import SwiftUI
import OSLog

/// The Plugins submenu, rebuilt each time it opens.
///
/// Rebuilt rather than kept in step: plugins are directories somebody can add
/// or edit outside the app, and a menu that only refreshed when we thought to
/// refresh it would quietly show a plugin that is no longer there.
@MainActor
final class PluginMenu: NSObject, NSMenuDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "plugins")

    private var windows: [String: NSWindow] = [:]

    /// Attach to the menu item that should hold the list.
    func attach(to item: NSMenuItem) {
        let menu = NSMenu(title: item.title)
        menu.delegate = self
        item.submenu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let plugins = PluginCatalog.installed()
        guard !plugins.isEmpty else {
            let empty = NSMenuItem(
                title: String(
                    localized: "No plugins installed",
                    comment: "插件菜单：一个插件都没有"),
                action: nil,
                keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(.separator())
            menu.addItem(revealItem())
            return
        }

        for plugin in plugins {
            let settings = PluginSettings.load(key: plugin.key)

            // What it is for, beside its name. Two kinds are installed by
            // default and their names do not say which is which -- and one
            // of them, once on, is a process that stays running.
            let item = NSMenuItem(
                title: "\(plugin.name) — \(plugin.kind.summary)",
                action: nil,
                keyEquivalent: "")

            // The tick is on the plugin itself rather than on a line inside
            // it: whether it is doing anything is the thing you want to see
            // without opening anything.
            item.state = settings.enabled ? .on : .off
            item.submenu = submenu(for: plugin, settings: settings)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(revealItem())
    }

    private func submenu(for plugin: Plugin, settings: PluginSettings) -> NSMenu {
        let menu = NSMenu(title: plugin.name)

        let configure = NSMenuItem(
            title: String(localized: "Settings…", comment: "插件菜单：打开设置"),
            action: #selector(openSettings(_:)),
            keyEquivalent: "")
        configure.target = self
        configure.representedObject = plugin.key
        menu.addItem(configure)

        let toggle = NSMenuItem(
            title: settings.enabled
                ? String(localized: "Switch Off", comment: "插件菜单：停用")
                : String(localized: "Switch On", comment: "插件菜单：启用"),
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = plugin.key

        // Switching on a plugin that has nothing filled in would look like it
        // worked and then send nothing, so that path goes through the form.
        if !settings.enabled && !settings.isComplete(for: plugin) {
            toggle.isEnabled = false
            toggle.title = String(
                localized: "Switch On (needs settings first)",
                comment: "插件菜单：还没配置完")
        }
        menu.addItem(toggle)

        return menu
    }

    private func revealItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(
                localized: "Open Plugins Folder",
                comment: "插件菜单：打开插件目录"),
            action: #selector(revealFolder(_:)),
            keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let plugin = PluginCatalog.installed().first(where: { $0.key == key })
        else { return }

        // One window per plugin, reused: opening the menu twice should not
        // leave two windows disagreeing about the same file.
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PluginSettingsView(plugin: plugin) { [weak self] in
            self?.windows[key]?.close()
            self?.windows.removeValue(forKey: key)
        }

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = plugin.name
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        windows[key] = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }

        var settings = PluginSettings.load(key: key)
        settings.enabled.toggle()
        do {
            try settings.save(key: key)
        } catch {
            PluginMenu.logger.warning("could not switch \(key): \(error)")
            return
        }

        // The core reads these files when it starts. Saying so is better than
        // leaving somebody to wonder why the next notification went nowhere.
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Restart Polter to apply",
            comment: "插件启停后需重启")
        alert.informativeText = String(
            localized: "Plugins are loaded when Polter starts.",
            comment: "插件启停后需重启的说明")
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func revealFolder(_ sender: Any?) {
        guard let dir = PluginCatalog.userDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
