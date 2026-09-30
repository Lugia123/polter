import AppKit
import GhosttyKit
import OSLog

/// The core's side of plugins, for the settings window and the menu: the
/// same `plugin_list`, `plugin_test` and `plugin_configure` an agent calls,
/// through `ghostty_app_plugin_*` (settings.md §5). Saving goes through the
/// core's writer, never a file written here, so the window, the menu, a
/// plugin's own page and an agent all write a plugin's settings one way.
@MainActor
enum PluginCore {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "plugins")

    private static var app: ghostty_app_t? {
        (NSApp.delegate as? AppDelegate)?.ghostty.app
    }

    /// What the core says about every plugin, by key. Nil when it could not
    /// be asked or did not answer -- "unknown", not "none".
    static func statuses() -> [String: PluginCoreStatus]? {
        guard let app,
              let json = PersonaCatalog.readJSON({ ghostty_app_plugin_list(app, $0, $1) })
        else { return nil }
        return PluginCoreStatus.parse(json)
    }

    enum Failure: Error, Equatable {
        /// The core refused, with the error's name (`TooSoon`,
        /// `NoSuchPlugin`, `UnknownParameter`, `BadSettings`, ...).
        case refused(String)
        /// There is no core to ask.
        case noCore

        /// For the person, in their language where the name is one we know.
        var message: String {
            switch self {
            case .noCore:
                return String(localized: "Polter's core is not running.", comment: "设置窗口：插件，核心不在")
            case .refused("TooSoon"):
                return String(localized: "A plugin was tested less than a minute ago. Try again in a minute.", comment: "设置窗口：插件测试，一分钟内只能测一次")
            case .refused("NoSuchPlugin"):
                return String(localized: "This plugin is no longer installed.", comment: "设置窗口：插件已不在")
            case .refused("UnknownParameter"):
                return String(localized: "A setting is not one this plugin declares.", comment: "设置窗口：插件，写了 manifest 没声明的参数")
            case .refused(let name):
                return String(format: String(localized: "The core refused: %@", comment: "设置窗口：插件，核心拒绝，%@ 是错误名"), name)
            }
        }
    }

    /// Test one plugin: `plugin_test`, sharing its one-a-minute budget.
    /// Called once -- a notification plugin really sends.
    static func test(_ key: String) -> Result<String, Failure> {
        guard let app else { return .failure(.noCore) }
        var out = [CChar](repeating: 0, count: 4096)
        let ok = key.withCString { k in
            out.withUnsafeMutableBufferPointer { b in
                ghostty_app_plugin_test(app, k, UInt(strlen(k)), b.baseAddress, UInt(b.count))
            }
        }
        let text = String(cString: out)
        logger.info("plugin test \(key, privacy: .public) ok=\(ok) said=\(text, privacy: .public)")
        return ok ? .success(text) : .failure(.refused(text))
    }

    /// Save one plugin's settings through the core's writer, as the person.
    /// `enabled` nil keeps what is there; a parameter left out is kept, and
    /// an empty value unsets one. Records a save made while the resident
    /// copy was running, for the restart dot and banner.
    @discardableResult
    static func configure(_ key: String, enabled: Bool?, params: [String: String]) -> Result<PluginStarted, Failure> {
        guard let app else { return .failure(.noCore) }
        var body: [String: Any] = ["params": params]
        if let enabled { body["enabled"] = enabled }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return .failure(.refused("BadSettings"))
        }

        var out = [CChar](repeating: 0, count: 256)
        let ok = key.withCString { k in
            data.withUnsafeBytes { json in
                out.withUnsafeMutableBufferPointer { b in
                    ghostty_app_plugin_configure(
                        app, k, UInt(strlen(k)),
                        json.bindMemory(to: CChar.self).baseAddress, UInt(json.count),
                        b.baseAddress, UInt(b.count))
                }
            }
        }
        let said = String(cString: out)
        logger.info("plugin configure \(key, privacy: .public) ok=\(ok) said=\(said, privacy: .public)")
        guard ok else { return .failure(.refused(said)) }

        // A name this build has not heard of is still a save that worked;
        // it is only the restart dot that cannot be told anything.
        let started = PluginStarted(rawValue: said) ?? .notStarted
        if started == .alreadyRunning { PluginLaunch.shared.savedWhileRunning.insert(key) }
        return .success(started)
    }
}

/// What this launch read about each plugin, and which were saved while
/// their resident copy was running. The core keeps neither: a resident copy
/// reads its settings when it starts, so "what is running" is "what was
/// there then" (settings.md §5.1, ↻).
@MainActor
final class PluginLaunch {
    static let shared = PluginLaunch()

    private(set) var atLaunch: [String: PluginSettings] = [:]
    var savedWhileRunning: Set<String> = []

    /// Once, as the app finishes launching.
    func snapshot() {
        var out: [String: PluginSettings] = [:]
        for plugin in PluginCatalog.installed() {
            out[plugin.key] = PluginSettings.load(for: plugin)
        }
        atLaunch = out
    }

    func restartPending(_ plugin: Plugin, now: PluginSettings) -> Bool {
        SettingsRules.pluginRestartPending(
            savedWhileRunning: savedWhileRunning.contains(plugin.key),
            atLaunch: atLaunch[plugin.key],
            now: now)
    }
}
