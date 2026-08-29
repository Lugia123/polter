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
            events: ["terminal.quiet"])

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

    /// A plugin subscribing to an event this build has never heard of is
    /// still shown.
    ///
    /// This was an enum with a case per `kind`, and a manifest naming
    /// anything else was dropped on the floor. That is a hand-written copy
    /// of a list that lives on the core side, and it went stale twice --
    /// the second time with the note about the first sitting beside it,
    /// which is how `claude-code` came to be installed, running, and absent
    /// from this list. A third case would not have stopped a fourth.
    @Test
    func aPluginWantingAnUnknownEventIsStillListed() throws {
        let key = "future-\(UUID().uuidString)"
        let directory = try installedPlugin(key: key, manifest: """
        {"key": "\(key)", "name": "From The Future",
         "wants": {"events": ["telepathy"]}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = try #require(
            PluginCatalog.installed().first { $0.key == key })
        #expect(plugin.name == "From The Future")
        #expect(plugin.events == ["telepathy"])

        // No phrase for it, and that is the entire cost of not knowing it --
        // the raw name is still there to be shown.
        #expect(plugin.roles.isEmpty)
        #expect(plugin.subtitle == nil)
        #expect(plugin.unrecognisedEvents == ["telepathy"])
    }

    /// And so is one whose manifest declares no events at all. The core
    /// hands such a plugin nothing and will not start it; that is a thing
    /// to say on screen, not a reason to hide it.
    @Test
    func aPluginWantingNothingIsStillListed() throws {
        let key = "silent-\(UUID().uuidString)"
        let directory = try installedPlugin(key: key, manifest: """
        {"key": "\(key)", "name": "Silent"}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = try #require(
            PluginCatalog.installed().first { $0.key == key })
        #expect(plugin.events.isEmpty)
        #expect(plugin.subtitle == nil)
    }

    /// `events` is a list, so the question is always membership. A plugin
    /// wanting two is one plugin with two phrases -- asking "which one is
    /// it" would be wrong about every plugin that wants a second.
    @Test
    func severalSubscriptionsGiveSeveralPhrases() throws {
        let key = "both-\(UUID().uuidString)"
        let directory = try installedPlugin(key: key, manifest: """
        {"key": "\(key)", "name": "Both",
         "wants": {"events": ["provision", "chat", "telepathy"]}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = try #require(
            PluginCatalog.installed().first { $0.key == key })

        // Said in a fixed order, not the manifest's, so two plugins wanting
        // the same pair read the same way round.
        #expect(plugin.roles == ["Keeps the conversations",
                                 "Sets your agent up to reach Polter"])
        #expect(plugin.subtitle
                == "Keeps the conversations · Sets your agent up to reach Polter")

        // And the one it has no phrase for survives beside them.
        #expect(plugin.unrecognisedEvents == ["telepathy"])
    }

    /// A directory whose name starts with an underscore is not a plugin.
    /// That is how the shipped SDK rides along in the same directory, and
    /// the host keeps the same rule -- a rule only one of two readers keeps
    /// is not a rule.
    @Test
    func underscoredDirectoriesAreNotPlugins() throws {
        let key = "_sdk-\(UUID().uuidString)"
        let directory = try installedPlugin(key: key, manifest: """
        {"key": "\(key)", "name": "Not A Plugin",
         "wants": {"events": ["chat"]}}
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Passed over even though it holds a manifest that would otherwise
        // read perfectly well.
        #expect(!PluginCatalog.installed().contains { $0.key == key })
    }

    /// A schema's `enum` becomes a closed set and its `boolean` a switch.
    /// Both used to be rendered as a text box, so a field that took three
    /// words accepted anything typed into it -- the declaration was written
    /// down and then not read.
    @Test
    func schemaTypesBecomeControls() throws {
        let key = "shapes-\(UUID().uuidString)"
        let directory = try installedPlugin(key: key, manifest: """
        {
          "key": "\(key)", "name": "Shapes",
          "params": {
            "type": "object",
            "required": ["scope"],
            "properties": {
              "scope": {"type": "string", "enum": ["user", "local"], "default": "user"},
              "loud": {"type": "boolean", "default": true},
              "url": {"type": "string"},
              "count": {"type": "integer", "enum": [1, 2]},
              "signing_key": {"type": "string", "secret": true}
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = try #require(
            PluginCatalog.installed().first { $0.key == key })
        func parameter(_ name: String) throws -> Plugin.Parameter {
            try #require(plugin.parameters.first { $0.name == name })
        }

        let scope = try parameter("scope")
        #expect(scope.control == .choice([.init(value: "user"), .init(value: "local")]))
        #expect(scope.defaultValue == "user")

        let loud = try parameter("loud")
        #expect(loud.control == .flag)

        // Spelled the way the settings file spells it, not the way JSON does.
        #expect(loud.defaultValue == "true")

        // Nothing said about it, so it stays a box you can type into. A
        // schema this side cannot make a control out of must leave the value
        // editable rather than hide a setting the plugin needs.
        #expect(try parameter("url").control == .text)

        // An `enum` of numbers is not a menu that could be saved: a value is
        // text on the wire, and the core reads the same field the same way.
        #expect(try parameter("count").control == .text)

        // Declared, rather than guessed at from the name.
        #expect(try parameter("signing_key").declaredSecret)
    }

    /// A closed set cannot be holding a credential, so it is not warned
    /// about however its name reads -- the core says the same about the same
    /// field, and it is why a chosen value may be shown back to an agent.
    @Test
    func aClosedSetIsNeverTreatedAsASecret() {
        let choice = Plugin.Parameter(
            name: "key_scope", title: "Key scope", help: "", required: false,
            control: .choice([.init(value: "user")]))
        #expect(!choice.looksSecret)

        let flag = Plugin.Parameter(
            name: "sign_it", title: "", help: "", required: false, control: .flag)
        #expect(!flag.looksSecret)

        // And a manifest that says so outright is believed without guessing.
        let declared = Plugin.Parameter(
            name: "dir", title: "Where", help: "", required: false,
            declaredSecret: true)
        #expect(declared.looksSecret)
    }

    /// A required switch that is off is answered, not unanswered. Emptiness
    /// cannot mean "not yet said" for a boolean, so requiring it to be
    /// non-empty would mean the only way to satisfy it was to turn it on.
    @Test
    func aRequiredSwitchIsCompleteWhetherOnOrOff() {
        let plugin = Plugin(
            key: "shapes",
            name: "Shapes",
            summary: "",
            directory: URL(fileURLWithPath: "/tmp"),
            parameters: [
                .init(name: "loud", title: "Loud", help: "", required: true,
                      control: .flag),
                .init(name: "scope", title: "Scope", help: "", required: true,
                      control: .choice([.init(value: "user")]),
                      defaultValue: "user"),
            ],
            events: ["terminal.quiet"])

        #expect(PluginSettings(enabled: true, params: [:]).isComplete(for: plugin))
        #expect(PluginSettings(enabled: true, params: ["loud": "false"])
            .isComplete(for: plugin))
    }

    /// A required text field with nothing in it and no default still blocks,
    /// which is the half of the rule the switches above must not have
    /// loosened.
    @Test
    func aRequiredTextFieldStillBlocks() {
        let plugin = Plugin(
            key: "webhook", name: "Webhook", summary: "",
            directory: URL(fileURLWithPath: "/tmp"),
            parameters: [
                .init(name: "url", title: "Where to POST", help: "", required: true),
            ],
            events: [])

        #expect(!PluginSettings(enabled: true, params: [:]).isComplete(for: plugin))
    }

    /// The page is what decides which screen a plugin gets, and it is a file
    /// on disk rather than anything declared, so adding one to an installed
    /// plugin is enough.
    @Test
    func aPageIsFoundWhenTheDirectoryHasOne() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plugin = plugin(key: "paged", at: directory)
        #expect(plugin.pageURL == nil)

        let ui = directory.appendingPathComponent("ui")
        try FileManager.default.createDirectory(
            at: ui, withIntermediateDirectories: true)

        // A directory named `ui` alone is not a page.
        #expect(plugin.pageURL == nil)

        try Data("<!doctype html>".utf8)
            .write(to: ui.appendingPathComponent("index.html"))
        #expect(plugin.pageURL?.lastPathComponent == "index.html")
    }

    // MARK: Helpers

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("polter-plugin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A plugin directory in the place `installed()` looks, holding just the
    /// manifest given. Returned so the caller can take it away again.
    private func installedPlugin(key: String, manifest: String) throws -> URL {
        guard let base = PluginCatalog.userDirectory else {
            struct NoConfigDirectory: Error {}
            throw NoConfigDirectory()
        }
        let directory = base.appendingPathComponent(key)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(manifest.utf8)
            .write(to: directory.appendingPathComponent("plugin.json"))
        return directory
    }

    private func plugin(key: String, at directory: URL) -> Plugin {
        Plugin(
            key: key,
            name: key,
            summary: "",
            directory: directory,
            parameters: [],
            events: ["chat"])
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
