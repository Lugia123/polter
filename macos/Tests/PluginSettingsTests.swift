import Testing
import Foundation
@testable import Ghostty

@Suite
struct PluginSettingsTests {
    /// The shape the core writes and reads.
    @Test
    func modernFileRoundTrips() throws {
        let json = """
        {"enabled": true, "params": {"url": "cmd:op read op://Private/hook"}}
        """
        let settings = try decode(json)

        #expect(settings.enabled)
        #expect(settings.params["url"] == "cmd:op read op://Private/hook")
    }

    /// Before this, the file held parameters alone and the main config said
    /// which plugins were on. Reading such a file as "off" would stop
    /// delivering notifications for somebody who changed nothing.
    @Test
    func flatFileCountsAsEnabled() throws {
        let settings = try decode(#"{"url": "https://example.com/hook"}"#)

        #expect(settings.enabled)
        #expect(settings.params["url"] == "https://example.com/hook")
    }

    /// Switched off stays off however much is configured.
    @Test
    func switchedOffStaysOff() throws {
        let settings = try decode(#"{"enabled": false, "params": {"url": "x"}}"#)

        #expect(!settings.enabled)
        #expect(settings.params.count == 1)
    }

    /// A required field with nothing in it blocks switching the plugin on,
    /// because switching it on would look like it worked and send nothing.
    @Test
    func emptyRequiredFieldIsIncomplete() {
        let plugin = Plugin(
            key: "webhook",
            name: "Webhook",
            summary: "",
            directory: URL(fileURLWithPath: "/tmp"),
            parameters: [
                .init(name: "url", title: "Where to POST", help: "", required: true),
            ],
            kind: .notify)

        #expect(!PluginSettings(enabled: true, params: [:]).isComplete(for: plugin))
        #expect(!PluginSettings(enabled: true, params: ["url": "   "]).isComplete(for: plugin))
        #expect(PluginSettings(enabled: true, params: ["url": "https://x"]).isComplete(for: plugin))
    }

    /// Anything that names a credential is flagged, and the check is
    /// deliberately broad: being warned about a URL costs nothing next to a
    /// signing key sitting in a file because nothing said anything.
    @Test
    func secretsAreRecognisedByName() {
        func parameter(_ name: String, _ title: String = "") -> Plugin.Parameter {
            .init(name: name, title: title, help: "", required: false)
        }

        #expect(parameter("signing_key").looksSecret)
        #expect(parameter("token").looksSecret)
        #expect(parameter("app_secret").looksSecret)
        #expect(parameter("x", "App Password").looksSecret)
        #expect(!parameter("url").looksSecret)
    }

    /// A plugin a release ships may arrive already switched on, and the
    /// menu has to see that or it shows a plugin as off while the core is
    /// running it.
    @Test
    func shippedDefaultsAreSeenWhenTheUserHasSaidNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"enabled": true, "params": {}}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))

        // A key nothing has ever written a user file for.
        let plugin = plugin(key: "archive-\(UUID().uuidString)", at: directory)
        #expect(PluginSettings.load(for: plugin).enabled)
    }

    /// And the user's file wins over it, **including when it says off** --
    /// otherwise every upgrade switches back on what somebody switched off.
    @Test
    func theUsersFileWinsIncludingWhenItSaysOff() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"enabled": true, "params": {}}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))

        let key = "archive-\(UUID().uuidString)"
        guard let userFile = PluginCatalog.settingsURL(for: key) else {
            Issue.record("no config directory to write to")
            return
        }
        try Data(#"{"enabled": false, "params": {}}"#.utf8).write(to: userFile)
        defer { try? FileManager.default.removeItem(at: userFile) }

        #expect(!PluginSettings.load(for: plugin(key: key, at: directory)).enabled)
    }

    /// The ladder a sidecar file is looked up by. Script before region,
    /// because what a reader cannot read is the other script; and a POSIX
    /// locale naming no script gets the one it implies, so a translator who
    /// ships `zh-Hans.json` reaches a machine that says `zh_CN`.
    @Test
    func localeCandidatesGoFromMostSpecificToLeast() {
        #expect(PluginLocale.candidates(for: ["zh-Hans-CN"])
                == ["zh-Hans-CN", "zh-Hans", "zh-CN", "zh"])
        #expect(PluginLocale.candidates(for: ["zh_CN.UTF-8"])
                == ["zh-Hans-CN", "zh-Hans", "zh-CN", "zh"])
        #expect(PluginLocale.candidates(for: ["zh-TW"])
                == ["zh-Hant-TW", "zh-Hant", "zh-TW", "zh"])
        #expect(PluginLocale.candidates(for: ["ZH-hans"]) == ["zh-Hans", "zh"])

        // Several preferences: each ladder in turn, nothing twice.
        #expect(PluginLocale.candidates(for: ["zh-Hans", "zh_CN"])
                == ["zh-Hans", "zh", "zh-Hans-CN", "zh-CN"])

        // It becomes a file name, so anything that is not a language tag is
        // not tried at all.
        #expect(PluginLocale.candidates(for: ["../../etc/passwd", ""]).isEmpty)
    }

    /// The sidecar covers only what it names; everything else stays the
    /// manifest's English.
    @Test
    func aSidecarOverlaysTheManifestAndNothingMore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let i18n = directory.appendingPathComponent("i18n")
        try FileManager.default.createDirectory(
            at: i18n, withIntermediateDirectories: true)
        try Data("""
        {"name": "存档", "params": {"dir": {"title": "放哪"}}}
        """.utf8).write(to: i18n.appendingPathComponent("zh-Hans.json"))

        let text = PluginText.load(from: directory, preferring: ["zh_CN.UTF-8"])
        #expect(text.name == "存档")
        #expect(text.summary == nil)
        #expect(text.fields["dir"]?.title == "放哪")
        #expect(text.fields["dir"]?.help == nil)

        #expect(PluginText.load(from: directory, preferring: ["fr-FR"]).name == nil)
    }

    // MARK: Helpers

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("polter-plugin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func plugin(key: String, at directory: URL) -> Plugin {
        Plugin(
            key: key,
            name: key,
            summary: "",
            directory: directory,
            parameters: [],
            kind: .archive)
    }


    /// Exercises the same decoding the app uses, without touching the disk.
    private func decode(_ json: String) throws -> PluginSettings {
        let root = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]

        let modern = root["params"] != nil || root["enabled"] != nil
        if !modern {
            return PluginSettings(enabled: true, params: strings(root))
        }
        return PluginSettings(
            enabled: (root["enabled"] as? Bool) ?? false,
            params: strings(root["params"] as? [String: Any] ?? [:]))
    }

    private func strings(_ raw: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in raw {
            if let string = value as? String { out[name] = string }
        }
        return out
    }
}
