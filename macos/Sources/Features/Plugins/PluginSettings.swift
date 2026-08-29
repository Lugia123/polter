import Foundation
import OSLog

/// What the user has said about one plugin: whether it is on, and its values.
///
/// The same file the core reads (`Plugin.Settings` in
/// `src/poltergeist/Plugin.zig`). Written whole -- it is small, and this is
/// the only thing that writes it.
struct PluginSettings: Equatable {
    var enabled: Bool = false
    var params: [String: String] = [:]

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "plugins")

    /// Read what the user has said. Missing or unreadable is "not
    /// configured", which is the same as off: a plugin nobody has set up
    /// should not be sending anything.
    ///
    /// This one looks only at the user's file. Anything showing a plugin's
    /// state wants `load(for:)`, which also sees the defaults a release
    /// ships with.
    static func load(key: String) -> PluginSettings {
        guard let url = PluginCatalog.settingsURL(for: key) else {
            return PluginSettings()
        }
        return read(url) ?? PluginSettings()
    }

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
    /// Nothing ever writes the shipped copy; `save` knows one path.
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

    /// Write it back, owner-only.
    ///
    /// The file may hold a reference to a secret, and on some setups the
    /// secret itself -- so it is created 0600 rather than left to the
    /// umask, the same as everything else Polter writes about your work.
    func save(key: String) throws {
        guard let url = PluginCatalog.settingsURL(for: key) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let root: [String: Any] = ["enabled": enabled, "params": params]
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])

        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Whether every required parameter has something in it.
    ///
    /// Only emptiness is checked. Whether a value is a *correct* webhook URL
    /// or a resolvable `cmd:` reference is not knowable without running it,
    /// and guessing would mean refusing to save something that works.
    func isComplete(for plugin: Plugin) -> Bool {
        for parameter in plugin.parameters where parameter.required {
            // A switch that is off is an answer. Emptiness cannot mean
            // "unanswered" for a boolean, so requiring one to be non-empty
            // would mean a required flag could only be satisfied by turning
            // it on -- which is not what `required` says.
            if parameter.control == .flag { continue }

            let value = params[parameter.name] ?? parameter.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
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
