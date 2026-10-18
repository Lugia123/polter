import Foundation

// The Plugins section's rules, with no AppKit and no core in them: which
// dot a plugin gets, what it is missing, which plugin a route selects, and
// what a log's last lines are (settings.md §5). The Windows host keeps the
// same table of cases in `polter-settings-shell`.

/// What the core says about one plugin: the part of `plugin_list` the
/// status dot reads. The same document an agent is handed, so the window
/// and an agent cannot be told two stories (§5.1).
struct PluginCoreStatus: Equatable {
    var key: String
    var enabled: Bool
    /// `starting`, `feeding`, `backing_off`, `dormant`, `stopped`; empty
    /// when no copy is running (the core leaves the field out then).
    var state: String = ""
    var failures: Int = 0
    /// The running copy was started with other settings than are saved now
    /// (`report.restartPending` in the core, #1697). The core leaves it out
    /// when no copy runs.
    var restartPending: Bool = false
    /// Why nothing is happening, when nothing is. Empty when it is fine.
    /// English and addressed to an agent: it is `plugin_list`'s own note.
    var note: String = ""
    /// The same reason for a person (`report.NoteSay`, #1644): a template to
    /// say in their language and the arguments to fill it with. Only the
    /// settings window's document carries it; an agent's never does.
    var noteSay: NoteSay?

    struct NoteSay: Equatable {
        var template: String
        var args: [String]
    }

    var running: Bool { !state.isEmpty }

    /// Whether the plugin waits for a restart -- the settings window's ↻ and
    /// its banner: the core says a copy is running on settings other than
    /// the ones saved now.
    ///
    /// **The core's answer and nothing else** (#1697). This used to be a
    /// snapshot this app took at launch, updated only by its own saves, so
    /// a change an agent made through `plugin_configure` under a running
    /// copy never showed ↻ here -- and the Windows host, which kept the same
    /// kind of snapshot, showed ↻ for a plugin the core had already started
    /// with what was saved. With no answer from the core (no status at
    /// all), nothing is claimed.
    var waitsForRestart: Bool { running && restartPending }

    /// What the window shows for `note`: the core's reason said in the
    /// person's language when it sent one to say, else the note as it came.
    func shownNote(in bundle: Bundle = .main) -> String {
        guard let say = noteSay else { return note }
        return ControlRoomList.fill(
            bundle.localizedString(forKey: say.template, value: say.template, table: nil), say.args)
    }

    /// `plugin_list`'s document, by plugin key. Nil when it is not one --
    /// not JSON, or `ok` is not true -- which is "the core did not say",
    /// not "there are no plugins".
    static func parse(_ json: String) -> [String: PluginCoreStatus]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let plugins = root["plugins"] as? [[String: Any]]
        else { return nil }

        var out: [String: PluginCoreStatus] = [:]
        for plugin in plugins {
            guard let key = plugin["key"] as? String else { continue }
            var say: NoteSay?
            if let raw = plugin["note_say"] as? [String: Any], let template = raw["template"] as? String {
                say = NoteSay(template: template, args: (raw["args"] as? [Any] ?? []).compactMap { $0 as? String })
            }
            out[key] = PluginCoreStatus(
                key: key,
                enabled: plugin["enabled"] as? Bool ?? false,
                state: plugin["state"] as? String ?? "",
                failures: plugin["failures"] as? Int ?? 0,
                restartPending: plugin["restart_pending"] as? Bool ?? false,
                note: plugin["note"] as? String ?? "",
                noteSay: say)
        }
        return out
    }
}

/// The dot beside a plugin in the sidebar (settings.md §5.1).
enum PluginDot: Equatable, CaseIterable {
    /// Saved while its resident copy was running, and different from what
    /// this launch read: the running copy still has the old settings.
    case restartPending
    case off
    case missingConfig
    case failing
    case on

    var symbol: String {
        switch self {
        case .restartPending: "↻"
        case .off: "○"
        case .missingConfig: "◐"
        case .failing: "▲"
        case .on: "●"
        }
    }

    var title: String {
        switch self {
        case .restartPending: String(localized: "Restart to apply", comment: "设置窗口：插件状态，改了设置、要重启 Polter 才生效")
        case .off: String(localized: "Off", comment: "设置窗口：插件状态，已关")
        case .missingConfig: String(localized: "Needs settings", comment: "设置窗口：插件状态，必填项没填齐")
        case .failing: String(localized: "Error", comment: "设置窗口：插件状态，出错")
        case .on: String(localized: "On", comment: "设置窗口：插件状态，已开")
        }
    }
}

/// How a plugin's resident copy stands after a save: the core's
/// `report.Started`, by the name `ghostty_app_plugin_configure` writes.
enum PluginStarted: String {
    case subscribesToNothing = "subscribes_to_nothing"
    case alreadyRunning = "already_running"
    case startedNow = "started_now"
    case notStarted = "not_started"
}

/// One declared parameter, as much of it as "is it filled in" needs.
struct PluginRequirement: Equatable {
    var name: String
    var title: String
    var required: Bool
    /// A switch: off is an answer, so it is never missing.
    var isFlag: Bool
    var defaultValue: String?
}

extension SettingsRules {
    /// Which dot a plugin gets. The first that holds, in this order
    /// (settings.md §5.1): restart pending, off, missing settings, failing,
    /// on. Off comes before failing because the core's `note` is never
    /// empty for a plugin that is off -- it says it is off -- and a plugin
    /// just switched on and not yet running has a note too; neither is an
    /// error. With no answer from the core (`status` nil) an enabled,
    /// complete plugin is on, which is what the table's "on" says.
    static func pluginDot(
        restartPending: Bool,
        enabled: Bool,
        missing: [String],
        status: PluginCoreStatus?
    ) -> PluginDot {
        if restartPending { return .restartPending }
        if !enabled { return .off }
        if !missing.isEmpty { return .missingConfig }
        if let status {
            if status.running && status.failures > 0 { return .failing }
            if !status.note.isEmpty { return .failing }
        }
        return .on
    }

    /// The titles of the required parameters that have nothing in them, in
    /// declaration order. A value counts when it is non-blank, or when it
    /// is unset and the schema gives a default; a switch is never missing.
    static func pluginMissing(_ requirements: [PluginRequirement], params: [String: String]) -> [String] {
        requirements.compactMap { r in
            guard r.required, !r.isFlag else { return nil }
            let value = params[r.name] ?? r.defaultValue ?? ""
            return value.trimmingCharacters(in: .whitespaces).isEmpty ? r.title : nil
        }
    }

    /// Which plugin a route to the Plugins section selects (§3.1): the one
    /// it names, else -- in a newly opened window, or when what is shown is
    /// gone -- the first; an open window otherwise keeps what it shows.
    static func pluginToSelect(item: String?, current: String?, fresh: Bool, keys: [String]) -> String? {
        if let item, keys.contains(item) { return item }
        if !fresh, let current, keys.contains(current) { return current }
        return keys.first
    }

    /// The last `count` lines of a log, oldest first. Any line break --
    /// `\n`, `\r\n`, `\r` -- ends a line; a break at the very end does not
    /// start another.
    static func logTail(_ text: String, count: Int = 20) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(max(count, 0)))
    }

    /// Where a search goes (§2.3): it stays in the current section while
    /// that has a match, and otherwise goes to the first section, in
    /// sidebar order, that has one. Nil -- go nowhere -- for an empty
    /// search or one nothing matches.
    static func sectionForSearch(
        _ query: String,
        current: SettingsSection,
        hasMatch: (SettingsSection) -> Bool
    ) -> SettingsSection? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if hasMatch(current) { return current }
        return SettingsSection.allCases.first(where: hasMatch)
    }
}

extension SettingsRoute {
    static func plugins(_ key: String? = nil) -> Self { .init(section: .plugins, item: key) }
}
