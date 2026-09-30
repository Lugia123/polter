import Foundation

/// What the user has said about one plugin: whether it is on, and its values.
///
/// The same file the core reads (`Plugin.Settings` in
/// `src/poltergeist/Plugin.zig`). Only read here: every write goes through
/// the core's writer (`PluginCore.configure`, settings.md §5.1).
struct PluginSettings: Equatable {
    var enabled: Bool = false
    var params: [String: String] = [:]

    /// Read two places, nearest first: the user's file, and failing that the
    /// `settings.json` the plugin's own directory may carry.
    ///
    /// The same two-step the core does (`Plugin.Settings.readFirst`), and it
    /// has to be the same or the menu would show a plugin as off while the
    /// core is running it. **The file that exists wins whole, including when
    /// it says off**: merging the two cannot tell "switched off" from "never
    /// configured" -- both are `enabled == false` -- so it would switch a
    /// plugin back on for somebody who had deliberately switched it off. A
    /// user's file that will not parse wins too, in the same direction, for
    /// the same reason.
    ///
    /// Nothing ever writes the shipped copy: the core writes the user's file only.
    static func load(for plugin: Plugin) -> PluginSettings {
        if let url = PluginCatalog.settingsURL(for: plugin.key),
           let settings = read(url) {
            return settings
        }
        let shipped = plugin.directory.appendingPathComponent("settings.json")
        return read(shipped) ?? PluginSettings()
    }

    /// One file, or `nil` when there was no file to read at all. A file that
    /// is there but will not parse is a `PluginSettings`, not a `nil`: it
    /// reads as "not configured", and it stops the search.
    private static func read(_ url: URL) -> PluginSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return PluginSettings() }

        // The older shape was the parameters alone, with whether the plugin
        // was on kept in the main config. Such a file was only ever written
        // to make a plugin work, so it reads as enabled -- matching the core,
        // which has the same rule for the same reason.
        let modern = root["params"] != nil || root["enabled"] != nil
        if !modern {
            return PluginSettings(enabled: true, params: strings(root))
        }

        return PluginSettings(
            enabled: (root["enabled"] as? Bool) ?? false,
            params: strings(root["params"] as? [String: Any] ?? [:]))
    }

    /// Whether every required parameter has something in it.
    ///
    /// Only emptiness is checked. Whether a value is a *correct* webhook URL
    /// or a resolvable `cmd:` reference is not knowable without running it,
    /// and guessing would mean refusing to save something that works.
    func isComplete(for plugin: Plugin) -> Bool {
        missing(for: plugin).isEmpty
    }

    /// The titles of the required parameters with nothing in them -- what
    /// the settings window names beside a switch it will not turn on
    /// (settings.md §5.2). One rule, `SettingsRules.pluginMissing`: a
    /// switch that is off is an answer, and an unset value with a schema
    /// default counts as set.
    func missing(for plugin: Plugin) -> [String] {
        SettingsRules.pluginMissing(plugin.requirements, params: params)
    }

    private static func strings(_ raw: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in raw {
            guard let string = value as? String else { continue }
            out[name] = string
        }
        return out
    }
}
