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
            menu.addItem(logsItem())
            return
        }

        for plugin in plugins {
            let settings = PluginSettings.load(for: plugin)

            // What it is for, beside its name, when this build has a phrase
            // for what it subscribes to: the shipped plugins' names do not
            // say which is which, and they stay running once on. A plugin
            // subscribing to something this build has no phrase for is
            // listed under its name alone -- it is still installed and still
            // configurable, and hiding it was the bug this replaced. The
            // settings window shows the raw subscription either way.
            let title = plugin.subtitle.map { "\(plugin.name) — \($0)" }
                ?? plugin.name
            let item = NSMenuItem(
                title: title,
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
        menu.addItem(logsItem())
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

        // This plugin's own file, which holds both what it printed and what
        // Polter did to it. One item per plugin because that is the shape of
        // the question -- "what happened to this one" -- and the answer is
        // one file rather than a directory to hunt through.
        let showLog = NSMenuItem(
            title: String(localized: "Show Log", comment: "插件菜单：打开这个插件的日志"),
            action: #selector(revealLog(_:)),
            keyEquivalent: "")
        showLog.target = self
        showLog.representedObject = plugin.key

        // Disabled rather than hidden when there is nothing yet: an item
        // that comes and goes teaches nobody where the logs are, and "this
        // plugin has not written anything" is itself worth reading off a
        // menu.
        if PluginCatalog.logURL(for: plugin.key) == nil {
            showLog.isEnabled = false
            showLog.title = String(
                localized: "Show Log (nothing written yet)",
                comment: "插件菜单：这个插件还没有日志")
        }
        menu.addItem(showLog)

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

    /// The directory every plugin's log is in.
    ///
    /// Beside "Open Plugins Folder" and not instead of it: one of them holds
    /// what the user wrote, the other what Polter observed, and somebody
    /// looking for either is helped by seeing both named.
    private func logsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(
                localized: "Open Plugin Logs",
                comment: "插件菜单：打开插件日志目录"),
            action: #selector(revealLogs(_:)),
            keyEquivalent: "")
        item.target = self

        if let dir = PluginCatalog.logDirectory,
           !FileManager.default.fileExists(atPath: dir.path) {
            item.isEnabled = false
            item.title = String(
                localized: "Open Plugin Logs (nothing written yet)",
                comment: "插件菜单：还没有任何插件日志")
        }
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
        guard let key = sender.representedObject as? String,
              let plugin = PluginCatalog.installed().first(where: { $0.key == key })
        else { return }

        // Started from what is in effect, not from the user's file alone:
        // switching off a plugin that a release ships switched on has to
        // write "off", and reading only the user's file would see "never
        // configured" and toggle it to on.
        var settings = PluginSettings.load(for: plugin)
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

    @objc private func revealLogs(_ sender: Any?) {
        guard let dir = PluginCatalog.logDirectory,
              FileManager.default.fileExists(atPath: dir.path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Reveal one plugin's log rather than open it.
    ///
    /// Selecting it in the Finder instead of handing it to whatever claims
    /// `.log`: the file is a plugin's own output, which may be anything at
    /// all, and choosing what opens it is the user's to make once rather
    /// than ours to make for them every time.
    @objc private func revealLog(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let url = PluginCatalog.logURL(for: key)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
