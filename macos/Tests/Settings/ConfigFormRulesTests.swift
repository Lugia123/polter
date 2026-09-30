import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

/// Covers the General section's form on the host side (settings.md §7):
/// reading the core's table, which items a group shows, and the decisions a
/// control makes before it writes. What is valid and where it is written is
/// the core's, and is tested in `src/config/form.zig`.
struct ConfigFormRulesTests {
    /// The shape `writeJson` documents, with one of each kind of row.
    private static let sample = #"""
    {"main":"/home/me/.config/polter/config.polter","backup":null,"errors":["x: bad"],
     "sections":[{"group":"appearance","keys":["background-opacity","theme"]},
                 {"group":"font","keys":["font-size"]},{"group":"terminal","keys":[]},
                 {"group":"window","keys":["window-save-state"]},{"group":"polter","keys":[]}],
     "items":[
      {"key":"theme","group":"appearance","control":"theme","choices":null,"min":null,"max":null,
       "default":"","value":"light:A,dark:B","doc":"The theme.\n\nMore.","source":{"kind":"main","path":"/home/me/.config/polter/config.polter","line":3},"readonly":null},
      {"key":"background-opacity","group":"appearance","control":"number","choices":null,"min":0,"max":1,
       "default":"1","value":"0.9","doc":null,"source":{"kind":"file","path":"/home/me/extra","line":7},"readonly":"file"},
      {"key":"font-size","group":"font","control":"number","choices":null,"min":1,"max":null,
       "default":"13","value":"13","doc":"Font size in points.\n\nMore about it.","label":"Font Size","summary":"In points; may be fractional.","source":{"kind":"default"},"readonly":null},
      {"key":"window-save-state","group":"window","control":"choice","choices":["default","never","always"],"choice_labels":["System Default","Never","Always"],"min":null,"max":null,
       "default":"default","value":"never","doc":null,"source":{"kind":"cli","arg":2},"readonly":"cli"},
      {"key":"keybind","group":null,"control":"readonly","choices":null,"min":null,"max":null,
       "default":"a\nb","value":"a\nb","doc":null,"source":{"kind":"default"},"readonly":"repeatable"},
      {"key":"future-key","group":null,"control":"hologram","choices":null,"min":null,"max":null,
       "default":"","value":"","doc":null,"source":{"kind":"default"},"readonly":null}
     ]}
    """#

    private var form: ConfigForm { ConfigForm.parse(Self.sample)! }
    private func item(_ key: String) -> ConfigForm.Item { form.items.first { $0.key == key }! }

    // MARK: Reading

    @Test func theDocumentedShapeDecodes() throws {
        let form = try #require(ConfigForm.parse(Self.sample))
        #expect(form.items.count == 6)
        #expect(form.backup == nil)
        #expect(form.errors == ["x: bad"])
        #expect(item("theme").source == .init(kind: .main, path: "/home/me/.config/polter/config.polter", line: 3))
        #expect(item("window-save-state").choices == ["default", "never", "always"])
    }

    /// A control this build does not know is shown read-only rather than
    /// losing the whole table.
    @Test func anUnknownControlIsReadOnlyNotAFailure() {
        #expect(item("future-key").control == .readonly)
        #expect(!ConfigFormRules.isWritable(item("future-key")))
    }

    /// The real core's answer, read the way the window reads it: the Swift
    /// types and `writeJson` have to agree, and a hand-written sample
    /// cannot show that.
    @MainActor
    @Test func theCoresOwnTableDecodes() throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        let json = try #require(PersonaCatalog.readJSON({ ghostty_app_config_form(app, $0, $1) }))
        let form = try #require(ConfigForm.parse(json))
        #expect(form.items.count > 100)
        #expect(form.sections.map(\.group) == ["appearance", "font", "terminal", "window", "polter"])
        for section in form.sections {
            for key in section.keys {
                let found = form.items.first { $0.key == key }
                #expect(found?.group == section.group, "\(key) in \(section.group)")
            }
        }
        // Every group the host asks for is one the core answers.
        for group in GeneralGroup.allCases {
            if let name = ConfigFormRules.coreGroup(group) {
                #expect(form.sections.contains { $0.group == name }, "\(name)")
            }
        }
        let fontSize = form.items.first { $0.key == "font-size" }
        #expect(fontSize?.control == .number)
    }

    @Test func aSetResultDecodesEitherWay() throws {
        let ok = try #require(ConfigSetResult.parse(#"{"ok":true,"key":"font-size","wrote":"/c","errors":[]}"#))
        #expect(ok.ok && ok.wrote == "/c")
        let no = try #require(ConfigSetResult.parse(#"{"ok":false,"key":"font-size","code":"invalid_value","message":"not a number","source":null}"#))
        #expect(!no.ok && no.code == "invalid_value" && no.message == "not a number")
    }

    @MainActor
    @Test func aRefusalSaysWhatTheCoreSaid() {
        let invalid = ConfigSetResult(ok: false, key: "k", code: "invalid_value", message: "not a number")
        #expect(GeneralModel.message(for: invalid) == "not a number")
        let busy = ConfigSetResult(ok: false, key: "k", code: "busy")
        #expect(GeneralModel.message(for: busy) != GeneralModel.message(for: invalid))
        #expect(!GeneralModel.message(for: nil).isEmpty)
    }

    // MARK: Which items

    @Test func aGroupShowsItsKeysInTheTablesOrder() {
        #expect(ConfigFormRules.items(in: .appearance, of: form).map(\.key) == ["background-opacity", "theme"])
        #expect(ConfigFormRules.items(in: .windows, of: form).map(\.key) == ["window-save-state"])
        #expect(ConfigFormRules.items(in: .terminal, of: form).isEmpty)
    }

    @Test func allOptionsIsEveryKeyFilteredByName() {
        #expect(ConfigFormRules.items(in: .all, of: form).count == 6)
        #expect(ConfigFormRules.items(in: .all, of: form, query: " FONT ").map(\.key) == ["font-size"])
    }

    /// In All Options every writable key is one line of text; what cannot
    /// be written stays read-only there too.
    @Test func allOptionsDrawsTextAndKeepsReadOnly() {
        #expect(ConfigFormRules.control(for: item("theme"), in: .all) == .text)
        #expect(ConfigFormRules.control(for: item("theme"), in: .appearance) == .theme)
        #expect(ConfigFormRules.control(for: item("keybind"), in: .all) == .readonly)
        #expect(ConfigFormRules.control(for: item("background-opacity"), in: .appearance) == .readonly)
    }

    // MARK: Before a write

    @Test func theDotAndRestoreDefault() {
        #expect(ConfigFormRules.differsFromDefault(item("theme")))
        #expect(!ConfigFormRules.differsFromDefault(item("font-size")))
        // Only a line in the main file can be deleted to restore it.
        #expect(ConfigFormRules.canRestoreDefault(item("theme")))
        #expect(!ConfigFormRules.canRestoreDefault(item("font-size")))
        #expect(!ConfigFormRules.canRestoreDefault(item("background-opacity")))
        #expect(!ConfigFormRules.canRestoreDefault(item("window-save-state")))
    }

    @Test func leavingATextBoxWritesOnlyWhatChanged() {
        #expect(!ConfigFormRules.shouldWrite("13", over: item("font-size")))
        #expect(ConfigFormRules.shouldWrite("14", over: item("font-size")))
    }

    @Test func onlyANarrowRangeIsASlider() {
        #expect(ConfigFormRules.usesSlider(item("background-opacity")))
        #expect(!ConfigFormRules.usesSlider(item("font-size")))
        #expect(ConfigFormRules.sliderText(0.9) == "0.9")
        #expect(ConfigFormRules.sliderText(1) == "1")
        #expect(ConfigFormRules.sliderText(0.25) == "0.25")
        #expect(ConfigFormRules.sliderText(0) == "0")
    }

    @Test func aThemePairSplitsAndJoins() {
        #expect(ConfigFormRules.themePair("light:A,dark:B") == ("A", "B"))
        #expect(ConfigFormRules.themePair("dark: B , light: A") == ("A", "B"))
        #expect(ConfigFormRules.themePair("Solo") == ("Solo", "Solo"))
        #expect(ConfigFormRules.themePair("") == ("", ""))
        #expect(ConfigFormRules.themeValue(light: "A", dark: "B") == "light:A,dark:B")
        #expect(ConfigFormRules.themeValue(light: "Solo", dark: "Solo") == "Solo")
        #expect(ConfigFormRules.themeValue(light: "", dark: "") == "")
    }

    // MARK: Whose file

    /// A process started on its own config file (every test instance) must
    /// not write the one the core finds by the default search -- that is
    /// the person's own.
    @Test func aProcessOnAnotherConfigFileDoesNotWrite() throws {
        #expect(ConfigFormRules.formWritesAllowed(hostConfigPath: nil, formMain: "/a/config.polter"))
        #expect(!ConfigFormRules.formWritesAllowed(hostConfigPath: "/tmp/test/isolated.polter", formMain: "/a/config.polter"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("config.polter")
        try Data().write(to: real)
        let link = dir.appendingPathComponent("link.polter")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ConfigFormRules.formWritesAllowed(hostConfigPath: link.path, formMain: real.path))
    }

    // MARK: Names (#973)

    private var zhHans: Bundle? {
        Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test func aNamedKeyShowsItsNameAndItsSentence() throws {
        let fontSize = item("font-size")
        #expect(fontSize.label == "Font Size")
        #expect(ConfigFormRules.title(fontSize, bundle: .main) != "font-size")
        #expect(ConfigFormRules.sentence(fontSize, bundle: .main) != nil)
        // Ghostty's text is one click away, not gone.
        #expect(ConfigFormRules.hasMore(fontSize))
        let zh = try #require(zhHans)
        #expect(ConfigFormRules.title(fontSize, bundle: zh) == "字号")
        #expect(ConfigFormRules.sentence(fontSize, bundle: zh) == "以点为单位，可以带小数。")
    }

    /// All Options' keys have no name: the key is the label and the first
    /// paragraph of Ghostty's text is the sentence.
    @Test func anUnnamedKeyIsShownByItsKey() {
        let theme = item("theme")
        #expect(theme.label == nil)
        #expect(ConfigFormRules.title(theme) == "theme")
        #expect(ConfigFormRules.sentence(theme) == "The theme.")
        #expect(ConfigFormRules.hasMore(theme))
        #expect(ConfigFormRules.sentence(item("keybind")) == nil)
        #expect(!ConfigFormRules.hasMore(item("keybind")))
    }

    /// Every name and sentence the real core hands over has Chinese behind
    /// it -- the strings gate cannot see these, they are not Swift literals.
    @MainActor
    @Test func everyNameTheCoreHandsOverIsTranslated() throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        let json = try #require(PersonaCatalog.readJSON({ ghostty_app_config_form(app, $0, $1) }))
        let form = try #require(ConfigForm.parse(json))
        let zh = try #require(zhHans)
        let named = form.items.filter { $0.group != nil }
        #expect(named.count >= 30)
        for item in named {
            let label = try #require(item.label, "\(item.key) has no label")
            let summary = try #require(item.summary, "\(item.key) has no summary")
            #expect(ConfigFormRules.localized(label, bundle: zh) != label, "\(item.key): \(label) has no Chinese")
            #expect(ConfigFormRules.localized(summary, bundle: zh) != summary, "\(item.key): \(summary) has no Chinese")
            // Every value of a named enum has a name, and the name Chinese
            // (#977); the proper nouns (Bash, fish, ...) are their own.
            if item.control == .choice {
                let names = try #require(item.choiceLabels, "\(item.key) has no choice names")
                #expect(names.count == item.choices?.count)
                for name in names where !Self.properNouns.contains(name) {
                    #expect(ConfigFormRules.localized(name, bundle: zh) != name, "\(item.key): \(name) has no Chinese")
                }
            }
        }
    }

    // MARK: Choices and widths (#977)

    static let properNouns: Set<String> = ["Bash", "Elvish", "fish", "Nushell", "PowerShell", "Zsh"]

    @Test func aValueIsShownByItsNameAndWrittenAsItself() throws {
        let saveState = item("window-save-state")
        let zh = try #require(zhHans)
        #expect(ConfigFormRules.choiceTitle("never", of: saveState, bundle: zh) == "从不")
        #expect(ConfigFormRules.choiceTitle("default", of: saveState, bundle: zh) == "跟随系统")
        // A value the table does not name (a newer core) is shown as itself.
        #expect(ConfigFormRules.choiceTitle("sometimes", of: saveState, bundle: zh) == "sometimes")
        // An enum with no names at all (All Options) is shown by its values.
        var unnamed = saveState
        unnamed.choiceLabels = nil
        #expect(ConfigFormRules.choiceTitle("never", of: unnamed, bundle: zh) == "never")
    }

    @Test func aShortBoxIsSizedForWhatGoesInIt() {
        let fontSize = item("font-size")
        #expect(ConfigFormRules.fieldWidth(fontSize, control: .number, in: .font) == 120)
        #expect(ConfigFormRules.fieldWidth(fontSize, control: .text, in: .font) == 160)
        #expect(ConfigFormRules.fieldWidth(fontSize, control: .font, in: .font) == nil)
        #expect(ConfigFormRules.fieldWidth(item("theme"), control: .theme, in: .appearance) == nil)
        // All Options' one-line boxes take the row: any key can be there.
        #expect(ConfigFormRules.fieldWidth(fontSize, control: .text, in: .all) == nil)
    }
}
