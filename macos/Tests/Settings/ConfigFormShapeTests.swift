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

    /// The words a test expects, in one of the app's languages, and the
    /// table they are looked up in.
    ///
    /// **A test names its table; none of them reads `Bundle.main`.** In the
    /// app, on a machine set to Chinese, `Bundle.main` answers in Chinese,
    /// and six tests here that expected English from it were red there and
    /// green wherever the sources are compiled on their own -- where
    /// `Bundle.main` has no table at all and every msgid comes back as
    /// itself. Each of those now runs once for each language, against that
    /// language's own table, so that what the machine is set to cannot
    /// decide the result.
    struct Tongue: CustomTestStringConvertible, Sendable {
        var table: String
        var off: String
        var doubleClick: String
        var notSet: String
        var mouseTrigger: String
        var screenshot: String
        var pasteImages: String
        /// Whether a name is its own msgid, so that there is no English to
        /// add beside it.
        var isEnglish: Bool

        var testDescription: String { table }

        static let english = Tongue(
            table: "Base", off: "Off", doubleClick: "Double-Click", notSet: "Not set",
            mouseTrigger: "Mouse Trigger", screenshot: "Screenshot", pasteImages: "Paste Images as Files",
            isEnglish: true)
        static let chinese = Tongue(
            table: "zh-Hans", off: "已关", doubleClick: "双击", notSet: "未设置",
            mouseTrigger: "鼠标触发", screenshot: "截图", pasteImages: "粘贴图片时存成文件并粘贴路径",
            isEnglish: false)
        static let all = [english, chinese]

        /// The table: the app's own copy when the tests run inside it,
        /// else the one in the sources this file was compiled from.
        var bundle: Bundle? {
            if let inApp = Bundle.main.path(forResource: table, ofType: "lproj") { return Bundle(path: inApp) }
            let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            let lproj = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/App/\(table).lproj")
            return FileManager.default.fileExists(atPath: lproj.appendingPathComponent("Localizable.strings").path)
                ? Bundle(path: lproj.path) : nil
        }
    }

    @Test(arguments: Tongue.all)
    func aChoiceTheTableDoesNotNameDoesNotTakeTheTableWithIt(_ tongue: Tongue) throws {
        let words = try #require(tongue.bundle, "no \(tongue.table) table")
        let form = try #require(ConfigForm.parse(Self.withScreenshots), "the whole table failed to decode")
        #expect(form.items.count == 7)
        let trigger = try #require(form.items.first { $0.key == "screenshot-mouse-trigger" })
        #expect(trigger.choiceLabels == ["Off", nil, nil])
        // Named: its name. Not named: the value, until the host spells it.
        #expect(ConfigFormRules.choiceTitle("", of: trigger, bundle: words) == tongue.off)
        // Not named: spelled by the host, through the item's template.
        #expect(ConfigFormRules.choiceTitle("cmd+shift", of: trigger, bundle: words) == "⇧⌘ + \(tongue.doubleClick)")
        #expect(form.items.first { $0.key == "screenshot-directory" }?.control == .directory)
        #expect(form.items.first { $0.key == "screenshot-agent-access" }?.control == .toggle)
        // A control this build does not draw is shown read-only.
        #expect(form.items.first { $0.key == "window-vsync" }?.control == .readonly)
    }

    private var form: ConfigForm { ConfigForm.parse(Self.withScreenshots)! }
    private func item(_ key: String) -> ConfigForm.Item { form.items.first { $0.key == key }! }


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

    @Test(arguments: Tongue.all)
    func aChoiceWithNoNameIsSpelledThroughTheTemplate(_ tongue: Tongue) throws {
        let words = try #require(tongue.bundle, "no \(tongue.table) table")
        let trigger = item("screenshot-mouse-trigger")
        #expect(ConfigFormRules.choiceTitle("ctrl+shift", of: trigger, bundle: words) == "⌃⇧ + \(tongue.doubleClick)")
        #expect(ConfigFormRules.choiceTitle("cmd+shift", of: trigger, bundle: words) == "⇧⌘ + \(tongue.doubleClick)")
        #expect(ConfigFormRules.choiceTitle("", of: trigger, bundle: words) == tongue.off)
        // A value the template cannot spell is shown as it is written.
        #expect(ConfigFormRules.choiceTitle("sideways", of: trigger, bundle: words) == "sideways")
        // Without a template a nameless value is itself.
        var plain = trigger
        plain.choiceTemplate = nil
        #expect(ConfigFormRules.choiceTitle("cmd+shift", of: plain, bundle: words) == "cmd+shift")
    }

    @Test(arguments: Tongue.all)
    func aValueTheTableDoesNotOfferIsShownAsItselfAndNotAsTheFirstChoice(_ tongue: Tongue) throws {
        let words = try #require(tongue.bundle, "no \(tongue.table) table")
        var trigger = item("screenshot-mouse-trigger")
        #expect(ConfigFormRules.choices(of: trigger) == ["", "cmd+shift", "ctrl+shift"])
        trigger.value = "super+ctrl+shift"
        #expect(ConfigFormRules.choices(of: trigger) == ["", "cmd+shift", "ctrl+shift", "super+ctrl+shift"])
        #expect(ConfigFormRules.choiceTitle("super+ctrl+shift", of: trigger, bundle: words)
            == "⌃⇧⌘ + \(tongue.doubleClick)")
        #expect(ConfigFormRules.choices(of: item("font-size")) == ["13"])
    }

    @Test func aFolderTakesTheRowAndIsOneLineOfTextInAllOptions() {
        let folder = item("screenshot-directory")
        #expect(ConfigFormRules.control(for: folder, in: .screenshot) == .directory)
        #expect(ConfigFormRules.control(for: folder, in: .all) == .text)
        #expect(ConfigFormRules.fieldWidth(folder, control: .directory, in: .screenshot) == nil)
        #expect(ConfigFormRules.isWritable(folder))
    }

    @Test(arguments: Tongue.all)
    func aGroupsShortcutRowsFollowItsSettings(_ tongue: Tongue) throws {
        let words = try #require(tongue.bundle, "no \(tongue.table) table")
        #expect(ConfigFormRules.shortcuts(in: .screenshot, of: form).map(\.action) == ["screenshot"])
        #expect(ConfigFormRules.shortcuts(in: .font, of: form).isEmpty)
        #expect(ConfigFormRules.shortcuts(in: .keybinds, of: form).isEmpty)
        #expect(ConfigFormRules.bindingText(["⇧⌘0"], bundle: words) == "⇧⌘0")
        #expect(ConfigFormRules.bindingText(["⇧⌘0", "F13"], bundle: words) == "⇧⌘0   F13")
        #expect(ConfigFormRules.bindingText([], bundle: words) == tongue.notSet)
    }

    // MARK: Search (screenshot.md §12.2)

    @Test(arguments: Tongue.all)
    func everyKeyAndEveryShortcutRowCanBeFound(_ tongue: Tongue) throws {
        let words = try #require(tongue.bundle, "no \(tongue.table) table")
        let entries = SettingsSearch.entries(of: form, bundle: words)
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
            name: tongue.mouseTrigger,
            aliases: tongue.isEnglish ? ["double-click"] : ["double-click", "Mouse Trigger"],
            key: "screenshot-mouse-trigger", summary: "S",
            choices: [tongue.off, "⇧⌘ + \(tongue.doubleClick)", "⌃⇧ + \(tongue.doubleClick)"]))
        // A key with no name of its own: found by its key and its help.
        #expect(entries[safe: 5]?.name == nil)
        #expect(entries[safe: 5]?.summary == "Sync.")
        #expect(entries[safe: 4]?.choices == [], "a number has no choices")
        #expect(entries[safe: 7] == .init(
            target: .shortcut(action: "screenshot", group: .screenshot),
            name: tongue.screenshot, aliases: tongue.isEnglish ? ["capture"] : ["capture", "Screenshot"],
            key: "screenshot", summary: "Take one."))
    }

    @Test(arguments: Tongue.all)
    func aTranslatedNameIsAlsoFoundByItsEnglish(_ tongue: Tongue) throws {
        let words = try #require(tongue.bundle, "no \(tongue.table) table")
        let entries = SettingsSearch.entries(of: form, bundle: words)
        #expect(entries[safe: 0]?.name == tongue.mouseTrigger)
        #expect(entries[safe: 3]?.name == tongue.pasteImages)
        #expect(entries[safe: 7]?.name == tongue.screenshot)
        if tongue.isEnglish {
            // The name is the English: there is nothing to add beside it.
            #expect(entries[safe: 0]?.aliases == ["double-click"])
            #expect(entries[safe: 3]?.aliases == ["paste", "粘贴"])
            #expect(entries[safe: 7]?.aliases == ["capture"])
        } else {
            #expect(entries[safe: 0]?.aliases == ["double-click", "Mouse Trigger"])
            #expect(entries[safe: 3]?.aliases == ["paste", "粘贴", "Paste Images as Files"])
            #expect(entries[safe: 7]?.aliases == ["capture", "Screenshot"])
        }
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
