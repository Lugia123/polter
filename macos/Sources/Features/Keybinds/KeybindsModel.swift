import Cocoa
import SwiftUI
import GhosttyKit

/// The keybind listing: every action the core knows, with the keys bound to it.
///
/// # Why this reads a different table than the menus do
///
/// The menu bar asks `ghostty_config_trigger`, which the core answers out of
/// `Binding.Set.reverse` -- and that map deliberately omits `performable`
/// bindings so a toolkit does not register them as accelerators. Correct for a
/// menu, wrong for a listing: a page built on it is blind in exactly the places
/// the menu is. This reads the forward table, through
/// `ghostty_config_keybind_count` / `ghostty_config_keybind`.
///
/// # Rows are actions, not keys
///
/// Measured on the core before either platform's page was written: **93
/// bindings covering 45 actions, out of 93 action tags** -- so 48 actions have
/// no key at all, and a page that listed keys would leave out the half of the
/// map a reader does not already know. `toggle_secure_input` is one of those.
///
/// ⚠️ The two 93s are a coincidence, not one number seen twice.
struct KeybindRow: Identifiable {
    /// The action's stable tag, e.g. `goto_tab`. This is the column that is
    /// always there.
    let action: String

    /// What the core calls this action for a person to read, already
    /// translated -- "Go to Tab", "跳转到标签页".
    ///
    /// **Nil is a real answer, not a missing one.** Not every action is in
    /// the command palette (`poltergeist_*` are switches over an agent, not
    /// commands), and inventing a name by prettifying the tag would put a
    /// phrase on screen that exists nowhere else in the product and cannot
    /// be translated. When this is nil the tag is what is shown, which is
    /// what the whole page showed before names were available at all.
    let name: String?

    /// Every key bound to it, already written the way a person reads them.
    /// **Empty means the action has no key**, which is a row, not an omission.
    let keys: [String]

    /// Any of this action's bindings is `performable`, which is the same as
    /// saying the menu bar cannot print its shortcut.
    let hiddenFromMenu: Bool

    var id: String { action }

    /// What the notes column says. Four states, and they are not
    /// interchangeable: a reader who cannot tell "no key" from "a key the menu
    /// will not show" learns the wrong thing, and the second is the defect this
    /// page exists to make visible.
    var note: String {
        if action.hasPrefix("poltergeist_") {
            return String(localized: "These are your switches over an agent; the keys are set by the product.", comment: "快捷键一览的说明列")
        }
        if action == "toggle_secure_input" {
            return String(localized: "Not turned on automatically.", comment: "快捷键一览的说明列")
        }
        if hiddenFromMenu {
            return String(localized: "Not shown in the menus (the key still works).", comment: "快捷键一览的说明列")
        }
        if keys.isEmpty {
            return String(localized: "No shortcut yet.", comment: "快捷键一览的说明列")
        }
        return ""
    }
}

enum KeybindsModel {
    /// Read the whole listing out of the core and fold it into one row per
    /// action, keeping the order the core answered in.
    ///
    /// **Nothing here sorts, reverses or drops anything from what the core
    /// said.** The grouping walks the reply once; the reply's own order is the
    /// page's order.
    static func rows(config: ghostty_config_t?) -> [KeybindRow] {
        guard let cfg = config else { return [] }

        var order: [String] = []
        var keys: [String: [String]] = [:]
        var hidden: [String: Bool] = [:]

        let n = ghostty_config_keybind_count(cfg)
        for i in 0..<n {
            let row = ghostty_config_keybind(cfg, i)
            guard row.action_len > 0, let ptr = row.action else { continue }
            // **`const char*` reaches Swift as `UnsafePointer<CChar>`, which
            // is `Int8`, and UTF8 decoding wants `UInt8`.** Rebound rather
            // than read with `String(cString:)`, because the core reports a
            // length and the length is what this should trust: a NUL scan
            // would be a second opinion about where the name ends.
            //
            // ⚠️ This line is where a stubbed `GhosttyKit` cannot help. A
            // stub written by the same hand that writes the call agrees with
            // it; the header is the only thing that disagrees, and only a
            // real build asks the header.
            let action = ptr.withMemoryRebound(to: UInt8.self, capacity: Int(row.action_len)) {
                String(
                    decoding: UnsafeBufferPointer(start: $0, count: Int(row.action_len)),
                    as: UTF8.self)
            }

            if keys[action] == nil {
                order.append(action)
                keys[action] = []
                hidden[action] = false
            }
            guard row.bound else { continue }
            if let text = display(trigger: row.trigger) {
                keys[action]?.append(text)
            }
            let flags = Ghostty.Input.BindingFlags(rawValue: UInt32(row.flags))
            if flags.contains(.performable) { hidden[action] = true }
        }

        let names = titles(config: cfg)
        return order.map { action in
            KeybindRow(
                action: action,
                name: names[action] ?? namedByTag(action),
                keys: keys[action] ?? [],
                hiddenFromMenu: hidden[action] ?? false)
        }
    }

    /// The name for an action the core gives no command for.
    ///
    /// **Thirty-one of the ninety-four actions have no palette entry**, and
    /// that is a decision written down in `src/input/command.zig`: they take
    /// a parameter (`goto_tab`, `resize_split`) or they do not belong in a
    /// palette (`next_tab`, `toggle_command_palette`). None of that makes
    /// them nameless -- a listing still has to call them something, and
    /// `goto_tab` in a row of `⌘1 ⌘2 ⌘3` is the page the user reported as
    /// "neither Chinese nor English".
    ///
    /// So they are named here, in the table, keyed by the tag. The set is
    /// not open-ended and is not maintained by hand: the gate
    /// `tools/the-mac-strings-still-have-a-chinese-half.py` reads those same
    /// arms out of `command.zig` and fails if one of them has no Chinese, so
    /// an action that stops having a command starts needing a name here.
    ///
    /// Nil when the table has no entry, which is the tag falling through to
    /// the screen -- the same thing this page did for every row before.
    private static func namedByTag(_ tag: String) -> String? {
        let name = Bundle.main.localizedString(forKey: tag, value: tag, table: nil)
        return name == tag ? nil : name
    }

    /// The core's own name for each action, keyed by the action's tag.
    ///
    /// **Read from the command list rather than written here.** The names
    /// already exist -- the command palette shows them and `po/` translates
    /// them -- so a table in this file would be a second set of names for
    /// the same actions, going stale in a different direction from the
    /// first. Several commands can share a tag (`goto_tab:1`, `goto_tab:2`);
    /// the first one's title wins, which is the one the core lists first.
    private static func titles(config: ghostty_config_t) -> [String: String] {
        var v: ghostty_config_command_list_s = .init()
        let key = "command-palette-entry"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))),
              v.len > 0 else { return [:] }

        var out: [String: String] = [:]
        for c in UnsafeBufferPointer(start: v.commands, count: v.len) {
            let command = Ghostty.Command(cValue: c)
            if out[command.actionKey] == nil { out[command.actionKey] = command.title }
        }
        return out
    }

    /// A trigger, written the way macOS writes keys.
    ///
    /// ⚠️ **Not `Ghostty.keyboardShortcut(for:)`, and not a copy of it.** That
    /// one answers "can this be a menu accelerator?" and returns nil for
    /// everything macOS cannot bind -- function keys among them. A listing has
    /// to be able to write down a key it cannot bind, so this answers a
    /// different question. The modifier half is shared rather than rewritten:
    /// `Ghostty.eventModifierFlags` is the one place mods are decoded.
    static func display(trigger: ghostty_input_trigger_s) -> String? {
        var out = ""
        let mods = Ghostty.eventModifierFlags(mods: trigger.mods)
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }

        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            out += String(Character(scalar)).uppercased()

        case GHOSTTY_TRIGGER_PHYSICAL:
            guard let name = physicalNames[trigger.key.physical] else {
                // ⚠️ **Shown, not dropped.** A key this table has no name for
                // is still a key somebody has bound; a blank cell would say
                // the action has no shortcut, which is a different and wrong
                // thing. The number is the core's own ordinal, so a person
                // reporting it can be answered exactly.
                out += "key #\(trigger.key.physical.rawValue)"
                return out
            }
            out += name

        case GHOSTTY_TRIGGER_CATCH_ALL:
            out += "(any key)"

        default:
            return nil
        }
        return out
    }

    /// Names for the physical keys.
    ///
    /// **Deliberately not built on `Ghostty.Input.keyToEquivalent`**: that table
    /// has fifteen entries because fifteen is what a menu accelerator can carry,
    /// and it maps to `KeyEquivalent` rather than to something readable. This
    /// one covers the physical keys the default configuration actually binds --
    /// measured, not guessed: arrows, page up/down, home, end, escape, the
    /// dedicated copy and paste keys, and the digit row -- plus the function
    /// keys, which is where a menu accelerator gives up.
    ///
    /// ⚠️ Anything outside it renders as `key #N` rather than as a blank.
    private static let physicalNames: [ghostty_input_key_e: String] = {
        var m: [ghostty_input_key_e: String] = [
            GHOSTTY_KEY_ARROW_UP: "↑",
            GHOSTTY_KEY_ARROW_DOWN: "↓",
            GHOSTTY_KEY_ARROW_LEFT: "←",
            GHOSTTY_KEY_ARROW_RIGHT: "→",
            GHOSTTY_KEY_HOME: "Home",
            GHOSTTY_KEY_END: "End",
            GHOSTTY_KEY_PAGE_UP: "Page Up",
            GHOSTTY_KEY_PAGE_DOWN: "Page Down",
            GHOSTTY_KEY_ESCAPE: "Esc",
            GHOSTTY_KEY_ENTER: "Return",
            GHOSTTY_KEY_TAB: "Tab",
            GHOSTTY_KEY_SPACE: "Space",
            GHOSTTY_KEY_BACKSPACE: "Delete",
            GHOSTTY_KEY_DELETE: "Forward Delete",
            GHOSTTY_KEY_COPY: "Copy",
            GHOSTTY_KEY_PASTE: "Paste",
            GHOSTTY_KEY_DIGIT_0: "0",
            GHOSTTY_KEY_DIGIT_1: "1",
            GHOSTTY_KEY_DIGIT_2: "2",
            GHOSTTY_KEY_DIGIT_3: "3",
            GHOSTTY_KEY_DIGIT_4: "4",
            GHOSTTY_KEY_DIGIT_5: "5",
            GHOSTTY_KEY_DIGIT_6: "6",
            GHOSTTY_KEY_DIGIT_7: "7",
            GHOSTTY_KEY_DIGIT_8: "8",
            GHOSTTY_KEY_DIGIT_9: "9",
        ]
        let functionKeys: [(ghostty_input_key_e, String)] = [
            (GHOSTTY_KEY_F1, "F1"), (GHOSTTY_KEY_F2, "F2"), (GHOSTTY_KEY_F3, "F3"),
            (GHOSTTY_KEY_F4, "F4"), (GHOSTTY_KEY_F5, "F5"), (GHOSTTY_KEY_F6, "F6"),
            (GHOSTTY_KEY_F7, "F7"), (GHOSTTY_KEY_F8, "F8"), (GHOSTTY_KEY_F9, "F9"),
            (GHOSTTY_KEY_F10, "F10"), (GHOSTTY_KEY_F11, "F11"), (GHOSTTY_KEY_F12, "F12"),
        ]
        for (k, v) in functionKeys { m[k] = v }
        return m
    }()
}
