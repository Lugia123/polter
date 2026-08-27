import Foundation
import OSLog

/// One plugin as it appears to the settings UI.
///
/// The core reads these same files for itself (`src/poltergeist/Plugin.zig`);
/// this is a second reader, not a second source of truth. Nothing here is
/// cached beyond the moment it is shown, so a file edited by hand and a file
/// edited in the UI cannot drift apart.
struct Plugin: Identifiable {
    /// Directory name, and the name every file and message uses.
    let key: String

    /// For a person reading a list of them.
    let name: String

    /// Where the plugin itself lives.
    let directory: URL

    /// What it needs configured, straight out of its `plugin.json`.
    let parameters: [Parameter]

    /// What the plugin is for. The two differ in how they run, and the
    /// difference is worth showing: a notification plugin is started for one
    /// message and is gone, an archive plugin is started once and stays.
    let kind: Kind

    var id: String { key }

    enum Kind: String {
        case notify
        case archive

        /// Said in the list, because "switched on" means something different
        /// for each: a notification channel that has never been used looks
        /// exactly like one that is broken, while an archive that is on is a
        /// process that is running right now.
        var summary: String {
            switch self {
            case .notify: return "Notifies you"
            case .archive: return "Keeps the conversations"
            }
        }
    }

    /// One configurable value, described by the plugin's own JSON Schema.
    struct Parameter: Identifiable {
        let name: String
        let title: String
        let help: String
        let required: Bool

        var id: String { name }

        /// Whether this is the kind of value that should not be typed in
        /// plainly.
        ///
        /// A guess, and deliberately a broad one: it only decides whether the
        /// field warns about storing a secret in a file, and being told that
        /// about a URL costs nothing next to a signing key sitting in
        /// plaintext because nothing said anything.
        var looksSecret: Bool {
            let haystack = (name + " " + title).lowercased()
            for needle in ["secret", "token", "key", "password", "signature", "sign"] {
                if haystack.contains(needle) { return true }
            }
            return false
        }
    }
}

/// Everything installed, and what the user has said about each.
///
/// Read fresh on every use. There are a handful of small files and this
/// happens when a menu opens.
struct PluginCatalog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "plugins")

    /// Where a plugin's own settings live: one file per plugin.
    static func settingsURL(for key: String) -> URL? {
        guard let base = userDirectory else { return nil }
        return base.appendingPathComponent("\(key).json")
    }

    /// `$XDG_CONFIG_HOME/polter/plugins`, created if it is not there.
    ///
    /// Also where a user drops a plugin of their own, which is why the
    /// directory is made even when nothing has been configured yet: an empty
    /// directory is a place to put something, and a missing one is a
    /// question about where.
    static var userDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
           !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = home.appendingPathComponent(".config")
        }

        let dir = base
            .appendingPathComponent("polter")
            .appendingPathComponent("plugins")

        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where the plugins that ship with Polter live.
    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty")
            .appendingPathComponent("polter")
            .appendingPathComponent("plugins")
    }

    /// Every plugin that is installed, the user's copies winning on name.
    static func installed() -> [Plugin] {
        var byKey: [String: Plugin] = [:]

        // Bundled first so a user's copy of the same name overwrites it.
        for directory in [bundledDirectory, userDirectory].compactMap({ $0 }) {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []

            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true else { continue }
                guard let plugin = read(directory: entry) else { continue }
                byKey[plugin.key] = plugin
            }
        }

        return byKey.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static func read(directory: URL) -> Plugin? {
        let manifestURL = directory.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["key"] as? String
        else { return nil }

        // A manifest declaring a kind this build does not know is skipped
        // rather than shown as something the user could configure and then
        // find does nothing. This said `== "notify"` until `archive` existed
        // on the core side, which is why `chat-archive` shipped inside the
        // bundle and never appeared in the list.
        guard let kind = (root["kind"] as? String).flatMap(Plugin.Kind.init(rawValue:))
        else { return nil }

        return Plugin(
            key: key,
            name: (root["name"] as? String) ?? key,
            directory: directory,
            parameters: parameters(from: root["params"] as? [String: Any]),
            kind: kind)
    }

    private static func parameters(from schema: [String: Any]?) -> [Plugin.Parameter] {
        guard let schema,
              let properties = schema["properties"] as? [String: Any]
        else { return [] }

        let required = Set((schema["required"] as? [String]) ?? [])

        // Sorted by name: JSON objects have no order, and a form whose fields
        // move between openings is worse than one in an arbitrary but fixed
        // order.
        return properties.keys.sorted().compactMap { name in
            guard let spec = properties[name] as? [String: Any] else { return nil }
            return Plugin.Parameter(
                name: name,
                title: (spec["title"] as? String) ?? name,
                help: (spec["description"] as? String) ?? "",
                required: required.contains(name))
        }
    }
}
