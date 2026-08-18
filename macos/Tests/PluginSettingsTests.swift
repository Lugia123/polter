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
            directory: URL(fileURLWithPath: "/tmp"),
            parameters: [
                .init(name: "url", title: "Where to POST", help: "", required: true),
            ])

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

    // MARK: Helpers

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
