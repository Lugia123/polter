import Foundation
import Testing
@testable import Ghostty

/// The settings table in the shape the core writes it now, read by the
/// type the settings window reads it with. Kept apart from
/// `ConfigFormRulesTests`, which needs the running app: this one needs
/// nothing, so it can be run wherever the sources can be compiled.
struct ConfigFormShapeTests {
    /// The table as the core has written it since the screenshot group was
    /// added: a section carries `shortcuts`, an item carries `aliases`,
    /// `on`, `off` and `choice_template`, a choice's name can be null, and
    /// there is a control (`directory`) older hosts never heard of. The
    /// first of these that this type could not read took the whole table
    /// with it, and every group of the settings window was empty.
    private static let withScreenshots = #"""
    {"main":"/c","backup":null,"errors":[],
     "sections":[{"group":"screenshot","keys":["screenshot-mouse-trigger","screenshot-directory","screenshot-agent-access"],
                  "shortcuts":[{"action":"screenshot","label":"Screenshot","summary":"Take one.","aliases":["capture"]}]}],
     "items":[
      {"key":"screenshot-mouse-trigger","group":"screenshot","label":"Mouse Trigger","summary":"S","control":"choice",
       "choices":["","cmd+shift","ctrl+shift"],"choice_labels":["Off",null,null],"choice_template":"%s + Double-Click",
       "on":null,"off":null,"aliases":["double-click"],"min":null,"max":null,"default":"cmd+shift","value":"cmd+shift",
       "doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"screenshot-directory","group":"screenshot","label":"Folder","summary":"S","control":"directory",
       "choices":null,"choice_labels":null,"choice_template":null,"on":null,"off":null,"aliases":[],
       "min":null,"max":null,"default":"","value":"","doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"screenshot-agent-access","group":"screenshot","label":"Agents","summary":"S","control":"toggle",
       "choices":null,"choice_labels":null,"choice_template":null,"on":"allow","off":"deny","aliases":[],
       "min":null,"max":null,"default":"allow","value":"allow","doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"clipboard-paste-image","group":"screenshot","label":"Paste Images as Files","summary":"S","control":"toggle",
       "choices":null,"choice_labels":null,"choice_template":null,"on":null,"off":null,"aliases":["paste","粘贴"],
       "min":null,"max":null,"default":"true","value":"false","doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"font-size","group":"font","label":"Font Size","summary":"In points.","control":"number",
       "choices":null,"choice_labels":null,"choice_template":null,"on":null,"off":null,"aliases":[],
       "min":1,"max":null,"default":"13","value":"13","doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"window-vsync","group":null,"label":null,"summary":null,"control":"hologram",
       "choices":null,"choice_labels":null,"choice_template":null,"on":null,"off":null,"aliases":[],
       "min":null,"max":null,"default":"true","value":"true","doc":"Sync.\n\nMore.","source":{"kind":"default","path":null,"line":null},"readonly":null},
      {"key":"future-key","group":"holodeck","label":"Future","summary":"S","control":"text",
       "choices":null,"choice_labels":null,"choice_template":null,"on":null,"off":null,"aliases":[],
       "min":null,"max":null,"default":"","value":"","doc":null,"source":{"kind":"default","path":null,"line":null},"readonly":null}
     ]}
    """#

    @Test func aChoiceTheTableDoesNotNameDoesNotTakeTheTableWithIt() throws {
        let form = try #require(ConfigForm.parse(Self.withScreenshots), "the whole table failed to decode")
        #expect(form.items.count == 7)
        let trigger = try #require(form.items.first { $0.key == "screenshot-mouse-trigger" })
        #expect(trigger.choiceLabels == ["Off", nil, nil])
        // Named: its name. Not named: the value, until the host spells it.
        #expect(ConfigFormRules.choiceTitle("", of: trigger, bundle: .main) == "Off")
        // Not named: spelled by the host, through the item's template.
        #expect(ConfigFormRules.choiceTitle("cmd+shift", of: trigger, bundle: .main) == "⇧⌘ + Double-Click")
        #expect(form.items.first { $0.key == "screenshot-directory" }?.control == .directory)
        #expect(form.items.first { $0.key == "screenshot-agent-access" }?.control == .toggle)
        // A control this build does not draw is shown read-only.
        #expect(form.items.first { $0.key == "window-vsync" }?.control == .readonly)
    }

    private var form: ConfigForm { ConfigForm.parse(Self.withScreenshots)! }
    private func item(_ key: String) -> ConfigForm.Item { form.items.first { $0.key == key }! }

    /// The app's Chinese table, read from the sources.
    private var zhHans: Bundle? {
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        let table = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/zh-Hans.lproj")
        return Bundle(path: table.path)
    }

    // MARK: The screenshot group (screenshot.md §12.1, §12.3)

    @Test func theScreenshotGroupIsListedBeforeKeyboardShortcuts() throws {
        let groups = GeneralGroup.allCases
        let screenshot = try #require(groups.firstIndex(of: .screenshot))
        #expect(groups.firstIndex(of: .keybinds) == screenshot + 1)
        #expect(GeneralGroup.screenshot.needsForm)
        #expect(ConfigFormRules.coreGroup(.screenshot) == "screenshot")
        #expect(ConfigFormRules.items(in: .screenshot, of: form).map(\.key)
            == ["screenshot-mouse-trigger", "screenshot-directory", "screenshot-agent-access"])
        #expect(GeneralRules.groupToSelect(item: "screenshot", fresh: false, current: .font) == .screenshot)
    }

    @Test func theNewFieldsAreRead() {
        let trigger = item("screenshot-mouse-trigger")
        #expect(trigger.choiceTemplate == "%s + Double-Click")
        #expect(trigger.aliases == ["double-click"])
        #expect(item("screenshot-agent-access").on == "allow")
        #expect(item("screenshot-agent-access").off == "deny")
        #expect(item("clipboard-paste-image").on == nil)
        #expect(form.sections.first?.shortcuts
            == [.init(action: "screenshot", label: "Screenshot", summary: "Take one.", aliases: ["capture"])])
        // A table from a core that has none of them still reads.
        let old = ConfigForm.parse(#"""
        {"main":"/c","backup":null,"errors":[],"sections":[{"group":"font","keys":["font-size"]}],
         "items":[{"key":"font-size","group":"font","control":"number","choices":null,"min":1,"max":null,
                   "default":"13","value":"13","doc":null,"source":{"kind":"default"},"readonly":null}]}
        """#)
        #expect(old?.sections.first?.shortcuts == [])
        #expect(old?.items.first?.aliases == [])
        #expect(old?.items.count == 1)
        #expect(old?.items.first?.on == nil)
    }

    @Test func aToggleWritesTheTablesOwnWords() {
        let access = item("screenshot-agent-access")
        #expect(ConfigFormRules.isOn(access))
        #expect(ConfigFormRules.toggleValue(true, of: access) == "allow")
        #expect(ConfigFormRules.toggleValue(false, of: access) == "deny", "the core refuses `false` for this key")
        var denied = access
        denied.value = "deny"
        #expect(!ConfigFormRules.isOn(denied))
        // One over a true/false key writes true and false, as before.
        let paste = item("clipboard-paste-image")
        #expect(!ConfigFormRules.isOn(paste))
        #expect(ConfigFormRules.toggleValue(true, of: paste) == "true")
        #expect(ConfigFormRules.toggleValue(false, of: paste) == "false")
        var pasting = paste
        pasting.value = "true"
        #expect(ConfigFormRules.isOn(pasting))
    }

    @Test func modifiersAreWrittenTheWayTheMacWritesThem() {
        #expect(ConfigFormRules.modifierSymbols("super+shift") == "⇧⌘")
        #expect(ConfigFormRules.modifierSymbols("shift+super") == "⇧⌘", "the order named in does not matter")
        #expect(ConfigFormRules.modifierSymbols("ctrl+shift") == "⌃⇧")
        #expect(ConfigFormRules.modifierSymbols("alt+shift") == "⌥⇧")
        #expect(ConfigFormRules.modifierSymbols("super+alt") == "⌥⌘")
        #expect(ConfigFormRules.modifierSymbols("ctrl+alt") == "⌃⌥")
        #expect(ConfigFormRules.modifierSymbols("super+ctrl") == "⌃⌘")
        #expect(ConfigFormRules.modifierSymbols("ctrl+alt+shift+super") == "⌃⌥⇧⌘")
        #expect(ConfigFormRules.modifierSymbols("cmd + Shift") == "⇧⌘")
        #expect(ConfigFormRules.modifierSymbols("control+option+command") == "⌃⌥⌘")
        #expect(ConfigFormRules.modifierSymbols("none") == nil)
        #expect(ConfigFormRules.modifierSymbols("") == nil)
        #expect(ConfigFormRules.modifierSymbols("super+hyper") == nil)
    }

    @Test func aChoiceWithNoNameIsSpelledThroughTheTemplate() throws {
        let trigger = item("screenshot-mouse-trigger")
        #expect(ConfigFormRules.choiceTitle("ctrl+shift", of: trigger, bundle: .main) == "⌃⇧ + Double-Click")
        let zh = try #require(zhHans)
        #expect(ConfigFormRules.choiceTitle("cmd+shift", of: trigger, bundle: zh) == "⇧⌘ + 双击")
        #expect(ConfigFormRules.choiceTitle("", of: trigger, bundle: zh) == "已关")
        // A value the template cannot spell is shown as it is written.
        #expect(ConfigFormRules.choiceTitle("sideways", of: trigger, bundle: .main) == "sideways")
        // Without a template a nameless value is itself.
        var plain = trigger
        plain.choiceTemplate = nil
        #expect(ConfigFormRules.choiceTitle("cmd+shift", of: plain, bundle: .main) == "cmd+shift")
    }

    @Test func aValueTheTableDoesNotOfferIsShownAsItselfAndNotAsTheFirstChoice() {
        var trigger = item("screenshot-mouse-trigger")
        #expect(ConfigFormRules.choices(of: trigger) == ["", "cmd+shift", "ctrl+shift"])
        trigger.value = "super+ctrl+shift"
        #expect(ConfigFormRules.choices(of: trigger) == ["", "cmd+shift", "ctrl+shift", "super+ctrl+shift"])
        #expect(ConfigFormRules.choiceTitle("super+ctrl+shift", of: trigger, bundle: .main) == "⌃⇧⌘ + Double-Click")
        #expect(ConfigFormRules.choices(of: item("font-size")) == ["13"])
    }

    @Test func aFolderTakesTheRowAndIsOneLineOfTextInAllOptions() {
        let folder = item("screenshot-directory")
        #expect(ConfigFormRules.control(for: folder, in: .screenshot) == .directory)
        #expect(ConfigFormRules.control(for: folder, in: .all) == .text)
        #expect(ConfigFormRules.fieldWidth(folder, control: .directory, in: .screenshot) == nil)
        #expect(ConfigFormRules.isWritable(folder))
    }

    @Test func aGroupsShortcutRowsFollowItsSettings() throws {
        #expect(ConfigFormRules.shortcuts(in: .screenshot, of: form).map(\.action) == ["screenshot"])
        #expect(ConfigFormRules.shortcuts(in: .font, of: form).isEmpty)
        #expect(ConfigFormRules.shortcuts(in: .keybinds, of: form).isEmpty)
        #expect(ConfigFormRules.bindingText(["⇧⌘0"], bundle: .main) == "⇧⌘0")
        #expect(ConfigFormRules.bindingText(["⇧⌘0", "F13"], bundle: .main) == "⇧⌘0   F13")
        #expect(ConfigFormRules.bindingText([], bundle: .main) == "Not set")
        #expect(ConfigFormRules.bindingText([], bundle: try #require(zhHans)) == "未设置")
    }

    // MARK: Search (screenshot.md §12.2)

    @Test func everyKeyAndEveryShortcutRowCanBeFound() {
        let entries = SettingsSearch.entries(of: form, bundle: .main)
        #expect(entries.map(\.target) == [
            .formItem(key: "screenshot-mouse-trigger", group: .screenshot),
            .formItem(key: "screenshot-directory", group: .screenshot),
            .formItem(key: "screenshot-agent-access", group: .screenshot),
            .formItem(key: "clipboard-paste-image", group: .screenshot),
            .formItem(key: "font-size", group: .font),
            // In no group: found in All Options. So is one in a group this
            // build has no page for.
            .formItem(key: "window-vsync", group: .all),
            .formItem(key: "future-key", group: .all),
            .shortcut(action: "screenshot", group: .screenshot),
        ])
        #expect(entries[safe: 0] == .init(
            target: .formItem(key: "screenshot-mouse-trigger", group: .screenshot),
            name: "Mouse Trigger", aliases: ["double-click"], key: "screenshot-mouse-trigger", summary: "S",
            choices: ["Off", "⇧⌘ + Double-Click", "⌃⇧ + Double-Click"]))
        // A key with no name of its own: found by its key and its help.
        #expect(entries[safe: 5]?.name == nil)
        #expect(entries[safe: 5]?.summary == "Sync.")
        #expect(entries[safe: 4]?.choices == [], "a number has no choices")
        #expect(entries[safe: 7] == .init(
            target: .shortcut(action: "screenshot", group: .screenshot),
            name: "Screenshot", aliases: ["capture"], key: "screenshot", summary: "Take one."))
    }

    @Test func aTranslatedNameIsAlsoFoundByItsEnglish() throws {
        let zh = try #require(zhHans)
        let entries = SettingsSearch.entries(of: form, bundle: zh)
        #expect(entries[safe: 0]?.name == "鼠标触发")
        #expect(entries[safe: 0]?.aliases == ["double-click", "Mouse Trigger"])
        #expect(entries[safe: 0]?.choices == ["已关", "⇧⌘ + 双击", "⌃⇧ + 双击"])
        #expect(entries[safe: 3]?.aliases == ["paste", "粘贴", "Paste Images as Files"])
        #expect(entries[safe: 7]?.name == "截图")
        #expect(entries[safe: 7]?.aliases == ["capture", "Screenshot"])
        // In English there is nothing to add.
        #expect(SettingsSearch.entries(of: form, bundle: .main)[safe: 3]?.aliases == ["paste", "粘贴"])
    }

    @Test func theEntriesGoToTheCoreInOrderWithEmptyFieldsLeftOut() throws {
        let entries: [SettingsSearch.Entry] = [
            .init(target: .role(key: "dev"), name: "Developer", key: "dev"),
            .init(target: .project(name: "site"), name: "site"),
            .init(target: .keybind(action: "new_tab"), name: "New Tab", aliases: [], key: "new_tab", summary: "⌘T"),
            .init(target: .plugin(key: "p"), name: "", key: "", summary: ""),
            .init(target: .formItem(key: "k", group: .all), name: "N", aliases: ["a", "b"], key: "k", summary: "S", choices: ["x"]),
        ]
        let root = try #require(try JSONSerialization.jsonObject(with: Data(SettingsSearch.json(entries).utf8)) as? [[String: Any]])
        #expect(root.count == 5)
        #expect(root[safe: 0] as NSDictionary? == ["name": "Developer", "key": "dev"] as NSDictionary)
        #expect(root[safe: 1] as NSDictionary? == ["name": "site"] as NSDictionary)
        #expect(root[safe: 2] as NSDictionary? == ["name": "New Tab", "key": "new_tab", "summary": "⌘T"] as NSDictionary)
        #expect(root[safe: 3]?.isEmpty == true, "still an entry: the indexes after it must not move")
        #expect(root[safe: 4] as NSDictionary?
            == ["name": "N", "aliases": ["a", "b"], "key": "k", "summary": "S", "choices": ["x"]] as NSDictionary)
        #expect(SettingsSearch.json([]) == "[]")
    }

    @Test func theCoresAnswerNamesEntriesAndOneThatNamesNoneIsDropped() {
        let answer = #"{"hits":[{"index":2,"rank":"name"},{"index":0,"rank":"alias"},{"index":9,"rank":"key"},{"index":-1,"rank":"key"},{"rank":"key"},{"index":1}]}"#
        #expect(SettingsSearch.hits(from: answer, count: 3) == [.init(index: 2, rank: "name"), .init(index: 0, rank: "alias")])
        #expect(SettingsSearch.hits(from: #"{"hits":[]}"#, count: 3) == [])
        #expect(SettingsSearch.hits(from: "{}", count: 3) == nil)
        #expect(SettingsSearch.hits(from: "nonsense", count: 3) == nil)
        let entries: [SettingsSearch.Entry] = [
            .init(target: .role(key: "a")), .init(target: .role(key: "b")), .init(target: .role(key: "c")),
        ]
        #expect(SettingsSearch.results(entries, hits: [.init(index: 2, rank: "name"), .init(index: 0, rank: "alias")]).map(\.target)
            == [.role(key: "c"), .role(key: "a")], "in the core's order, not the list's")
        #expect(SettingsSearch.results(entries, hits: [.init(index: 7, rank: "name")]).isEmpty)
    }

    @Test func spacesAloneAreNotASearch() {
        #expect(!SettingsSearch.isSearching(""))
        #expect(!SettingsSearch.isSearching("   "))
        #expect(!SettingsSearch.isSearching(" \n\t"))
        #expect(SettingsSearch.isSearching(" a "))
        #expect(SettingsSearch.isSearching("截图"))
    }

    @Test func aResultSaysWhereItLives() {
        #expect(SettingsSearch.crumb(section: "General", item: "Screenshot") == "General › Screenshot")
        #expect(SettingsSearch.crumb(section: "Roles", item: nil) == "Roles")
        #expect(SettingsSearch.crumb(section: "Roles", item: "") == "Roles")
    }
}

private extension Array {
    /// The element at `index`, or nil when there are not that many: a test
    /// that is wrong about how many there are should fail, not stop the run.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
