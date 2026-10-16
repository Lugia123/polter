import Foundation
import Testing
@testable import Ghostty

/// #1636: on a Chinese machine the Claude Code plugin's page showed `yes`,
/// `no`, `user` and `local` -- the values of its `enum`s, which a sidecar
/// had no way to name. These are the sidecar's `choices`, read from a
/// temporary directory only: nothing here touches a real config directory.
struct PluginChoiceLabelTests {
    private func pluginDirectory(sidecar: String?) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("polter-choice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        {"key": "demo", "name": "Demo", "description": "English.",
         "params": {"type": "object", "properties": {
           "skills": {"type": "string", "title": "Install skills as well",
                      "enum": ["yes", "no"], "default": "yes"}}}}
        """.utf8).write(to: directory.appendingPathComponent("plugin.json"))
        if let sidecar {
            let i18n = directory.appendingPathComponent("i18n")
            try FileManager.default.createDirectory(at: i18n, withIntermediateDirectories: true)
            try Data(sidecar.utf8).write(to: i18n.appendingPathComponent("zh-Hans.json"))
        }
        return directory
    }

    private func choices(_ plugin: Plugin?) -> [Plugin.Parameter.Choice] {
        guard case .choice(let choices) = plugin?.parameters.first?.control else { return [] }
        return choices
    }

    @Test func aSidecarNamesTheValuesAndTheValuesStay() throws {
        let directory = try pluginDirectory(sidecar: """
        {"params": {"skills": {"title": "顺便装上 skill", "choices": {"yes": "装", "no": "不装"}}}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = PluginCatalog.read(directory: directory, preferring: ["zh_CN.UTF-8"])
        #expect(plugin?.parameters.first?.title == "顺便装上 skill")
        #expect(choices(plugin).map(\.value) == ["yes", "no"])
        #expect(choices(plugin).map(\.label) == ["装", "不装"])
    }

    @Test func anEnglishReaderSeesTheValues() throws {
        let directory = try pluginDirectory(sidecar: """
        {"params": {"skills": {"choices": {"yes": "装", "no": "不装"}}}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = PluginCatalog.read(directory: directory, preferring: ["en-US"])
        #expect(choices(plugin).map(\.label) == ["yes", "no"])
    }

    /// A value the sidecar does not name is shown as itself, and a name for
    /// a value the schema does not have adds nothing.
    @Test func whatTheSidecarLeavesOutIsTheValue() throws {
        let directory = try pluginDirectory(sidecar: """
        {"params": {"skills": {"choices": {"yes": "装", "maybe": "也许"}}}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = PluginCatalog.read(directory: directory, preferring: ["zh-Hans"])
        #expect(choices(plugin).map(\.value) == ["yes", "no"])
        #expect(choices(plugin).map(\.label) == ["装", "no"])
    }

    @Test func noSidecarIsEnglish() throws {
        let directory = try pluginDirectory(sidecar: nil)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = PluginCatalog.read(directory: directory, preferring: ["zh-Hans"])
        #expect(plugin?.parameters.first?.title == "Install skills as well")
        #expect(choices(plugin).map(\.label) == ["yes", "no"])
    }
}
