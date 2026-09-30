import Testing
@testable import Ghostty

/// Covers `KeybindsModel.fold` and `keysLabel`: how the core's listing
/// becomes one row per action, and how a row's keys are written.
struct KeybindsModelTests {
    private func b(_ action: String, _ key: String?, bound: Bool = true, performable: Bool = false) -> KeybindsModel.Binding {
        .init(action: action, bound: bound, key: key, performable: performable)
    }

    @Test func oneRowPerActionInTheOrderTheCoreAnswered() {
        let rows = KeybindsModel.fold([b("goto_tab", "⌘1"), b("new_tab", "⌘T"), b("goto_tab", "⌘2")])
        #expect(rows.map(\.action) == ["goto_tab", "new_tab"])
        #expect(rows[0].keys == ["⌘1", "⌘2"])
    }

    /// The physical digit and the character it types are two bindings that
    /// both read "⌘1"; the row lists the key once.
    @Test func aKeyWrittenTheSameWayTwiceIsListedOnce() {
        let rows = KeybindsModel.fold([
            b("goto_tab", "⌘1"), b("goto_tab", "⌘1"), b("goto_tab", "⌘2"), b("goto_tab", "⌘2"),
        ])
        #expect(rows[0].keys == ["⌘1", "⌘2"])
    }

    @Test func anActionWithNoKeyKeepsItsRow() {
        let rows = KeybindsModel.fold([b("toggle_secure_input", nil, bound: false)])
        #expect(rows == [.init(action: "toggle_secure_input", keys: [], hiddenFromMenu: false)])
    }

    @Test func aPerformableBindingHidesTheRowFromTheMenu() {
        let rows = KeybindsModel.fold([b("copy_to_clipboard", "⌘C"), b("copy_to_clipboard", "Copy", performable: true)])
        #expect(rows[0].hiddenFromMenu)
        #expect(rows[0].keys == ["⌘C", "Copy"])
    }

    /// A line may end between two keys, never inside one.
    @Test func aKeyIsNeverBrokenAcrossLines() {
        let label = KeybindsModel.keysLabel(["⇧Page Up", "⇧Page Down", "⌘1"])
        #expect(label == "⇧Page\u{00A0}Up   ⇧Page\u{00A0}Down   ⌘1")
        #expect(!label.contains("Page Up"))
    }

    @Test func noKeysIsADash() {
        #expect(KeybindsModel.keysLabel([]) == "—")
    }

    @Test func theKeyboardShortcutsMenuRoutesToItsGroup() {
        #expect(SettingsRoute.general(.keybinds) == SettingsRoute(section: .general, item: "keybinds"))
        #expect(GeneralRules.groupToSelect(item: SettingsRoute.general(.keybinds).item, fresh: true, current: .appearance) == .keybinds)
    }
}
