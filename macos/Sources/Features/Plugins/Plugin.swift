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
    ///
    /// This and everything else a person reads here may have come from a
    /// per-locale sidecar beside the manifest rather than from the manifest
    /// itself; see `PluginLocale`. The tool surface does not do this, on
    /// purpose -- an agent reads the manifest verbatim on every machine.
    let name: String

    /// What the plugin is for, in a sentence, as its manifest puts it.
    /// Empty when the manifest says nothing.
    let summary: String

    /// Where the plugin itself lives.
    let directory: URL

    /// What it needs configured, straight out of its `plugin.json`.
    let parameters: [Parameter]

    /// Which events this plugin subscribes to, as `wants.events` spells
    /// them, kept verbatim and **never used to decide whether the plugin
    /// exists**.
    ///
    /// This was an `enum Kind` with a case per kind, and a manifest naming
    /// one this build had not heard of was dropped. That is a hand-written
    /// mirror of a list living on the core side, and it went stale twice:
    /// the first time `chat-archive` shipped inside the bundle and never
    /// appeared, the second time -- with the note about the first sitting
    /// right beside it -- `claude-code` did, while running. A third case
    /// would not have stopped a fourth, so there is no case list here at
    /// all.
    ///
    /// **A list, not a word.** The kind it replaced could only ever be one
    /// thing; a plugin may subscribe to several. So the question this
    /// answers is "is `terminal.quiet` among them", never "which one is
    /// it" -- and a build asking the second question would be wrong about
    /// every plugin that wants two.
    ///
    /// Empty when the manifest declares none, which is what the core reads
    /// as "hand it nothing" and therefore does not start. Shown all the
    /// same: it is installed, and hiding what is installed was the bug.
    let events: [String]

    /// Whether the plugin ships a settings page of its own (`ui/index.html`).
    ///
    /// Checked at display time rather than read into a stored field: a page
    /// added beside an installed plugin should show up the next time the
    /// window opens, the same as an edited manifest does.
    var pageURL: URL? {
        let url = directory
            .appendingPathComponent("ui", isDirectory: true)
            .appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var id: String { key }

    /// The events this build has something to say about, in the order they
    /// are said.
    ///
    /// **The one list.** `roles` and `unrecognisedEvents` are both derived
    /// from it, so "which events do we have a phrase for" is answered in a
    /// single place -- a second copy of this, kept by hand somewhere else,
    /// is precisely the failure that took out the kind list twice.
    private static let phrased = ["chat", "terminal.quiet", "provision"]

    /// What this plugin is for, one phrase per event it subscribes to.
    ///
    /// The table below is presentation and nothing else, which is the whole
    /// difference from the enum it replaced: an event missing from it costs
    /// a phrase, not a plugin. It is allowed to go stale, and the settings
    /// window shows `unrecognisedEvents` beside this so that a phrase this
    /// build cannot supply still leaves the subscription visible.
    ///
    /// In `phrased` order rather than the manifest's, so two plugins wanting
    /// the same pair read the same way round.
    var roles: [String] {
        Plugin.phrased.filter(events.contains).compactMap(Plugin.phrase(for:))
    }

    /// The events this build has no phrase for, in the order the manifest
    /// wrote them. Shown as-is rather than dropped.
    var unrecognisedEvents: [String] {
        events.filter { !Plugin.phrased.contains($0) }
    }

    private static func phrase(for event: String) -> String? {
        switch event {
        case "chat": return String(
            localized: "Keeps the conversations",
            comment: "插件列表：订阅 chat 的插件")
        case "terminal.quiet": return String(
            localized: "Notifies you",
            comment: "插件列表：订阅 terminal.quiet 的插件")
        case "provision": return String(
            localized: "Sets your agent up to reach Polter",
            comment: "插件列表：订阅 provision 的插件")
        default: return nil
        }
    }

    /// The phrases as one line beside the name, or nothing when this build
    /// has none for anything this plugin wants.
    var subtitle: String? {
        let roles = self.roles
        return roles.isEmpty ? nil : roles.joined(separator: " · ")
    }

    /// One configurable value, described by the plugin's own JSON Schema.
    struct Parameter: Identifiable {
        let name: String
        let title: String
        let help: String
        let required: Bool

        /// The manifest said `"secret": true` about this one. The core reads
        /// the same field and treats it as the only thing that decides it;
        /// `looksSecret` below is the guess that runs when nobody declared
        /// anything.
        let declaredSecret: Bool

        /// What the value is allowed to be, and therefore what to put on
        /// screen for it.
        let control: Control

        /// The schema's `default`, as a string, or `nil` when it names none.
        /// Shown as the starting point for a value nobody has set; it is not
        /// written to the file until the user saves.
        let defaultValue: String?

        init(
            name: String,
            title: String,
            help: String,
            required: Bool,
            declaredSecret: Bool = false,
            control: Control = .text,
            defaultValue: String? = nil
        ) {
            self.name = name
            self.title = title
            self.help = help
            self.required = required
            self.declaredSecret = declaredSecret
            self.control = control
            self.defaultValue = defaultValue
        }

        var id: String { name }

        /// How a value is asked for.
        ///
        /// Everything used to be `.text`, including the parameters whose
        /// schema said `enum`. A field that accepts three words rendered as
        /// a box you can type anything into, and what you typed was saved:
        /// the declaration was written down and then not read. These are the
        /// two shapes a schema can state without ambiguity, so these are the
        /// two that are read.
        enum Control: Equatable {
            /// Free text, and what anything unrecognised falls back to. A
            /// schema this build cannot make a control out of must still
            /// leave the value editable -- refusing to show it would hide a
            /// setting the plugin needs.
            case text

            /// A closed set from the schema's `enum`.
            case choice([Choice])

            /// `"type": "boolean"`. Stored as the text `true` or `false`,
            /// because a plugin's settings file is a flat map of strings on
            /// both sides of the wire.
            case flag
        }

        /// One allowed value. The label is the value: a JSON Schema `enum`
        /// carries no titles, and inventing prettier ones here would mean
        /// the screen and the file disagreeing about what was chosen.
        struct Choice: Identifiable, Equatable {
            let value: String
            var id: String { value }
        }

        /// Whether this is the kind of value that should not be typed in
        /// plainly.
        ///
        /// A guess, and deliberately a broad one: it only decides whether the
        /// field warns about storing a secret in a file, and being told that
        /// about a URL costs nothing next to a signing key sitting in
        /// plaintext because nothing said anything. A manifest that declares
        /// `"secret"` outright is believed without the guessing.
        var looksSecret: Bool {
            if declaredSecret { return true }

            // A closed set cannot be holding a credential -- the core says
            // the same thing about the same field, and it is why a chosen
            // value may be shown back to an agent.
            if case .choice = control { return false }
            if case .flag = control { return false }

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

    /// `$XDG_STATE_HOME/polter/plugins`, where each plugin's log file is.
    ///
    /// **Config and state, under the same last name, deliberately.** What
    /// the user wrote about a plugin is configuration and lives beside
    /// `userDirectory`; what Polter observed happening to it is state and
    /// lives here. That is the XDG split said out loud, and it is why the
    /// two are not merged and why neither got a third word invented for it.
    /// The core builds the same path in `PluginLog.dirIn`; this is a second
    /// reader of it, the same way `userDirectory` is.
    ///
    /// Not created here. The core makes it when it starts a plugin, and a
    /// menu that made it would produce an empty directory on a machine
    /// where no plugin has ever run -- which reads as "the logs are gone"
    /// rather than as "nothing has run".
    static var logDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"],
           !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = home
                .appendingPathComponent(".local")
                .appendingPathComponent("state")
        }

        return base
            .appendingPathComponent("polter")
            .appendingPathComponent("plugins")
    }

    /// One plugin's log file, if it has been written to yet.
    ///
    /// Nil when nothing has been written, so a menu can say "there is
    /// nothing to open" rather than opening a Finder window onto a file
    /// that is not there.
    static func logURL(for key: String) -> URL? {
        guard let dir = logDirectory else { return nil }
        let url = dir.appendingPathComponent("\(key).log")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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

                // A leading underscore means "not a plugin": it is how the
                // shipped SDK (`plugins/_sdk`) rides along in the same
                // directory without being one. The same rule as the host's,
                // said here because this is a second reader of the same
                // directory and a rule only one of them keeps is not a rule.
                // Cheaper than reading the manifest to find out, and it
                // holds for a directory that has no manifest at all.
                guard !entry.lastPathComponent.hasPrefix("_") else { continue }

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

        // Nothing here looks at what the plugin is before deciding to show
        // it. This used to skip a manifest whose `kind` this build had not
        // heard of, on the reasoning that configuring it would do nothing --
        // what it actually did was hide plugins that were installed and
        // running, twice, because the list of kinds lived on the core side
        // and this was a copy of it. A plugin that is installed is shown.
        // See `Plugin.events`.
        //
        // The strings only, and the order they were written in. An entry
        // that is not text is passed over rather than voiding the rest: the
        // core reads the same field the same way, and a declaration that
        // can be read in part still says what its author meant.
        let wants = root["wants"] as? [String: Any]
        let events = ((wants?["events"] as? [Any]) ?? []).compactMap { $0 as? String }

        // The person's language, if the plugin ships it. Read here rather
        // than at display time so that everything below sees one answer.
        let text = PluginText.load(
            from: directory,
            preferring: Locale.preferredLanguages)

        return Plugin(
            key: key,
            name: text.name ?? (root["name"] as? String) ?? key,
            summary: text.summary ?? (root["description"] as? String) ?? "",
            directory: directory,
            parameters: parameters(
                from: root["params"] as? [String: Any],
                translated: text),
            events: events)
    }

    private static func parameters(
        from schema: [String: Any]?,
        translated text: PluginText = .none
    ) -> [Plugin.Parameter] {
        guard let schema,
              let properties = schema["properties"] as? [String: Any]
        else { return [] }

        let required = Set((schema["required"] as? [String]) ?? [])

        // Sorted by name: JSON objects have no order, and a form whose fields
        // move between openings is worse than one in an arbitrary but fixed
        // order.
        return properties.keys.sorted().compactMap { name in
            guard let spec = properties[name] as? [String: Any] else { return nil }
            let field = text.fields[name]
            let control = control(from: spec)
            return Plugin.Parameter(
                name: name,
                title: field?.title ?? (spec["title"] as? String) ?? name,
                help: field?.help ?? (spec["description"] as? String) ?? "",
                required: required.contains(name),
                declaredSecret: (spec["secret"] as? Bool) ?? false,
                control: control,
                defaultValue: defaultValue(from: spec, control: control))
        }
    }

    /// Which control one property's schema asks for.
    ///
    /// `enum` wins over `type`, because a schema saying both means the type
    /// is describing what the members of the closed set are -- the set is
    /// still the narrower statement, and the narrower statement is the one
    /// to honour.
    private static func control(
        from spec: [String: Any]
    ) -> Plugin.Parameter.Control {
        if let raw = spec["enum"] as? [Any] {
            // Only the strings, and only when there is at least one. The
            // core reads the same field the same way -- a value is text on
            // the wire either way -- and an `enum` of numbers would produce
            // a menu whose entries could not be saved. Falling back to text
            // there matches what the core does with an empty choice list:
            // anything is allowed, because nothing readable was declared.
            let choices = raw.compactMap { $0 as? String }
                .map(Plugin.Parameter.Choice.init(value:))
            if !choices.isEmpty { return .choice(choices) }
        }

        if (spec["type"] as? String) == "boolean" { return .flag }
        return .text
    }

    /// The schema's `default`, rendered the way the settings file spells it.
    private static func defaultValue(
        from spec: [String: Any],
        control: Plugin.Parameter.Control
    ) -> String? {
        guard let raw = spec["default"] else { return nil }
        if let text = raw as? String { return text }

        // A boolean default is written `true`, not `"true"`, by anyone who
        // knows JSON Schema -- so it has to be read as one and spelled back
        // out as the text the file holds.
        if control == .flag, let flag = raw as? Bool { return flag ? "true" : "false" }
        return nil
    }
}
