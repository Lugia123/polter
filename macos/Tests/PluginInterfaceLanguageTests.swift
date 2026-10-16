import Foundation
import Testing
@testable import Ghostty

/// #1663: a plugin's page is in the app's language, not the system's list.
/// With English first and Chinese second the app is English, and a plugin
/// carrying only `zh-Hans.json` used to show its Chinese anyway, because it
/// went on down the list until it found a file. Temporary directories only.
struct PluginInterfaceLanguageTests {
    private func pluginDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("polter-interface-language-\(UUID().uuidString)")
        let i18n = directory.appendingPathComponent("i18n")
        try FileManager.default.createDirectory(at: i18n, withIntermediateDirectories: true)
        try Data("""
        {"key": "demo", "name": "Demo", "description": "English."}
        """.utf8).write(to: directory.appendingPathComponent("plugin.json"))
        try Data("""
        {"name": "演示", "description": "中文。"}
        """.utf8).write(to: i18n.appendingPathComponent("zh-Hans.json"))
        return directory
    }

    @Test func anEnglishAppShowsTheManifestEvenWithChineseSecond() throws {
        let directory = try pluginDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // What `Bundle.main.preferredLocalizations` gives an English app on
        // a machine whose list is English, then Chinese.
        let languages = PluginLocale.interfaceLanguages(from: ["en", "zh-Hans"], development: "en")
        let plugin = PluginCatalog.read(directory: directory, preferring: languages)
        #expect(plugin?.summary == "English.")
    }

    @Test func aChineseAppShowsTheSidecar() throws {
        let directory = try pluginDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let languages = PluginLocale.interfaceLanguages(from: ["zh-Hans", "en"], development: "en")
        let plugin = PluginCatalog.read(directory: directory, preferring: languages)
        #expect(plugin?.summary == "中文。")
    }

    @Test func baseIsTheDevelopmentLanguage() {
        #expect(PluginLocale.interfaceLanguages(from: ["Base", "zh-Hans"], development: "en") == ["en"])
        #expect(PluginLocale.interfaceLanguages(from: [], development: "en") == [])
    }
}
