import CoreGraphics
import Foundation

// The General section's form (settings.md §7.2-7.4), with no AppKit in it:
// the core's table as Swift values, which items a group shows, and the
// small decisions a control makes before it writes. The core decides what
// is valid and where it is written; the host only draws and asks.

/// `ghostty_app_config_form`'s answer; the shape is `writeJson` in
/// `src/config/form.zig`.
struct ConfigForm: Decodable, Equatable {
    var main: String
    /// The copy taken before this run's first write, once there is one.
    var backup: String?
    var errors: [String]
    var sections: [Section]
    var items: [Item]

    struct Section: Decodable, Equatable {
        var group: String
        var keys: [String]
        /// The rows of this group that show a binding rather than a setting
        /// (screenshot.md §12.1); none in most groups, and none at all from
        /// a core that predates them.
        var shortcuts: [Shortcut]

        private enum CodingKeys: String, CodingKey { case group, keys, shortcuts }

        init(group: String, keys: [String], shortcuts: [Shortcut] = []) {
            self.group = group
            self.keys = keys
            self.shortcuts = shortcuts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            group = try c.decode(String.self, forKey: .group)
            keys = try c.decode([String].self, forKey: .keys)
            shortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
        }
    }

    /// A row that shows what an action is bound to. `label` and `summary`
    /// are English msgids; `aliases` are search words, used as they are.
    struct Shortcut: Decodable, Equatable, Identifiable {
        var action: String
        var label: String
        var summary: String?
        var aliases: [String]?

        var id: String { action }
    }

    enum Control: String, Equatable {
        case toggle, choice, number, text, font, color, theme, readonly
        /// A folder: a path box, a button that chooses one and a button
        /// that shows it. Written like `text`; empty restores the default.
        case directory
    }

    struct Source: Decodable, Equatable {
        enum Kind: String, Decodable { case `default`, main, file, cli }
        var kind: Kind
        var path: String?
        var line: Int?
    }

    struct Item: Decodable, Equatable, Identifiable {
        var key: String
        /// The §7.1 group the core puts it in on this OS; nil for a key that
        /// is only in "All Options".
        var group: String?
        var control: Control
        var choices: [String]?
        /// The display name of each of `choices`, same order, English
        /// msgids (#977); nil where the table names none. **One name may
        /// itself be nil**: a value the table leaves for the host to spell
        /// (through `choice_template`), and until the host does, shown as
        /// the value. Decoding these as plain strings made one such row
        /// fail the whole table, and every group showed nothing.
        var choiceLabels: [String?]?
        /// A msgid with one `%s` in it, for the values `choiceLabels` leaves
        /// nil: the host writes the value's modifier keys the way this
        /// platform writes them and puts them where the `%s` is.
        var choiceTemplate: String?
        /// What a toggle writes when it is not over a true/false key; nil
        /// for one that is. Writing `true` to a key that wants `allow` is
        /// refused by the core.
        var on: String?
        var off: String?
        /// Other words a search finds this by. Not msgids: never translated.
        var aliases: [String]
        var min: Double?
        var max: Double?
        var `default`: String
        /// As the config file writes it; a repeatable key's lines joined
        /// with `\n`.
        var value: String
        var doc: String?
        /// The form's own name and sentence for it, English msgids (#973);
        /// nil for a key that is only in All Options.
        var label: String?
        var summary: String?
        var source: Source
        /// Why the form may not write it: `repeatable`, `multiple`, `cli`,
        /// `file`; nil when it may.
        var readonly: String?

        var id: String { key }

        private enum CodingKeys: String, CodingKey {
            case key, group, control, choices, choiceLabels = "choice_labels", min, max, `default`, value, doc, label, summary, source, readonly
            case choiceTemplate = "choice_template", on, off, aliases
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            group = try c.decodeIfPresent(String.self, forKey: .group)
            // A control this build does not know (a newer core) is shown,
            // read-only, rather than dropping the key or the whole table.
            control = Control(rawValue: try c.decode(String.self, forKey: .control)) ?? .readonly
            choices = try c.decodeIfPresent([String].self, forKey: .choices)
            choiceLabels = try c.decodeIfPresent([String?].self, forKey: .choiceLabels)
            choiceTemplate = try c.decodeIfPresent(String.self, forKey: .choiceTemplate)
            on = try c.decodeIfPresent(String.self, forKey: .on)
            off = try c.decodeIfPresent(String.self, forKey: .off)
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
            min = try c.decodeIfPresent(Double.self, forKey: .min)
            max = try c.decodeIfPresent(Double.self, forKey: .max)
            `default` = try c.decode(String.self, forKey: .default)
            value = try c.decode(String.self, forKey: .value)
            doc = try c.decodeIfPresent(String.self, forKey: .doc)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            source = try c.decode(Source.self, forKey: .source)
            readonly = try c.decodeIfPresent(String.self, forKey: .readonly)
        }
    }

    static func parse(_ json: String) -> ConfigForm? {
        try? JSONDecoder().decode(ConfigForm.self, from: Data(json.utf8))
    }
}

/// `ghostty_app_config_set`'s answer (`setJson` in `form.zig`).
struct ConfigSetResult: Decodable, Equatable {
    var ok: Bool
    var key: String
    /// The file written, or nil when nothing needed writing.
    var wrote: String?
    /// The configuration's errors after the write.
    var errors: [String]?
    /// `unknown_key`, `invalid_value`, `read_only`, `busy`, `failed`.
    var code: String?
    var message: String?
    var source: ConfigForm.Source?

    static func parse(_ json: String) -> ConfigSetResult? {
        try? JSONDecoder().decode(ConfigSetResult.self, from: Data(json.utf8))
    }
}

enum ConfigFormRules {
    /// The core's name for a §7.1 group; nil for the groups it does not
    /// hold (All Options is every item; the last three need no table).
    static func coreGroup(_ group: GeneralGroup) -> String? {
        switch group {
        case .appearance: "appearance"
        case .font: "font"
        case .terminal: "terminal"
        case .windows: "window"
        case .polter: "polter"
        case .screenshot: "screenshot"
        case .all, .keybinds, .advanced, .about: nil
        }
    }

    /// The items a group shows, in the table's order. All Options is every
    /// item whose key contains `query` (ignoring case and surrounding
    /// spaces), in the core's order.
    static func items(in group: GeneralGroup, of form: ConfigForm, query: String = "") -> [ConfigForm.Item] {
        if group == .all {
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return form.items }
            return form.items.filter { $0.key.localizedCaseInsensitiveContains(needle) }
        }
        guard let name = coreGroup(group),
              let keys = form.sections.first(where: { $0.group == name })?.keys
        else { return [] }
        return keys.compactMap { key in form.items.first { $0.key == key } }
    }

    /// What a row draws. The form never writes a read-only one; in All
    /// Options every other key is one line of text, checked by the core
    /// against the key's type (§7.1).
    static func control(for item: ConfigForm.Item, in group: GeneralGroup) -> ConfigForm.Control {
        if !isWritable(item) { return .readonly }
        return group == .all ? .text : item.control
    }

    /// Whether this process may write through the form at all. The core
    /// writes the file it finds by the default search (`form.main`); a
    /// process started with its own config file (`GHOSTTY_CONFIG_PATH`, as
    /// every test instance is) reads another one, and a write would land in
    /// a file this process does not read -- the person's own, in the case
    /// of a test instance. So an override writes only when it is that same
    /// file.
    static func formWritesAllowed(hostConfigPath: String?, formMain: String) -> Bool {
        guard let hostConfigPath else { return true }
        func canonical(_ p: String) -> String {
            URL(fileURLWithPath: (p as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canonical(hostConfigPath) == canonical(formMain)
    }

    /// A msgid the core hands over, in the person's language: the same
    /// table the Swift literals use, looked up by the English text.
    static func localized(_ msgid: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: msgid, value: msgid, table: nil)
    }

    /// What the label column says: the form's name for the key, else the
    /// key itself (All Options' keys have no name).
    static func title(_ item: ConfigForm.Item, bundle: Bundle = .main) -> String {
        item.label.map { localized($0, bundle: bundle) } ?? item.key
    }

    /// The sentence under the control: the form's own summary, else the
    /// first paragraph of Ghostty's help. Nil when there is neither.
    static func sentence(_ item: ConfigForm.Item, bundle: Bundle = .main) -> String? {
        if let summary = item.summary { return localized(summary, bundle: bundle) }
        guard let doc = item.doc else { return nil }
        let first = doc.components(separatedBy: "\n\n").first?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? nil : first
    }

    /// Whether "More…" has anything to show: Ghostty's help text, unless
    /// the sentence already is the whole of it.
    static func hasMore(_ item: ConfigForm.Item, bundle: Bundle = .main) -> Bool {
        guard let doc = item.doc?.trimmingCharacters(in: .whitespacesAndNewlines), !doc.isEmpty else { return false }
        return item.summary != nil || sentence(item, bundle: bundle) != doc.replacingOccurrences(of: "\n", with: " ")
    }

    /// What a value is called in the list: its name from the table,
    /// translated, else the value itself (#977). What is written is always
    /// the value.
    ///
    /// A value the table gives no name spells itself through the item's
    /// template -- `super+shift` is `⇧⌘ + Double-Click` -- and so does a
    /// value that is not in the table at all, which is what the config
    /// file holds when somebody wrote a combination the form does not
    /// offer: it is shown as what it is, not as the first choice.
    static func choiceTitle(_ value: String, of item: ConfigForm.Item, bundle: Bundle = .main) -> String {
        if let values = item.choices, let names = item.choiceLabels, names.count == values.count,
           let i = values.firstIndex(of: value), let name = names[i] {
            return localized(name, bundle: bundle)
        }
        guard let template = item.choiceTemplate, let keys = modifierSymbols(value) else { return value }
        return localized(template, bundle: bundle).replacingOccurrences(of: "%s", with: keys)
    }

    /// Modifier keys named the way the config file names them
    /// (`super+shift`), written the way macOS writes them (`⇧⌘`): always
    /// in the order Control, Option, Shift, Command, whatever order they
    /// were named in. Nil when a name is not a modifier, or there is none.
    static func modifierSymbols(_ value: String) -> String? {
        var held = Set<Character>()
        for name in value.split(separator: "+") {
            switch name.trimmingCharacters(in: .whitespaces).lowercased() {
            case "ctrl", "control": held.insert("⌃")
            case "alt", "opt", "option": held.insert("⌥")
            case "shift": held.insert("⇧")
            case "super", "cmd", "command": held.insert("⌘")
            default: return nil
            }
        }
        guard !held.isEmpty else { return nil }
        return String("⌃⌥⇧⌘".filter(held.contains))
    }

    /// The values a list offers, in the table's order, and the current one
    /// after them when the table does not have it.
    static func choices(of item: ConfigForm.Item) -> [String] {
        let listed = item.choices ?? []
        return listed.contains(item.value) ? listed : listed + [item.value]
    }

    /// How wide a text box is (#977): a number or a short value is sized
    /// for what goes in it and starts on the control column; a font name,
    /// a theme pair and every All Options box take the row. Nil is "the
    /// whole row".
    static func fieldWidth(_ item: ConfigForm.Item, control: ConfigForm.Control, in group: GeneralGroup) -> CGFloat? {
        if group == .all { return nil }
        switch control {
        case .number: return 120
        case .text, .color: return 160
        case .font, .theme, .toggle, .choice, .readonly, .directory: return nil
        }
    }

    /// Why the table is being read (#986): right after the form's own write
    /// -- whose refusal is what the red text under the control says -- or
    /// for any other reason: the window came forward, the configuration was
    /// reloaded, another group was chosen.
    enum FormRead: Equatable { case afterOwnWrite, reread }

    /// The refusals still shown after a read. A refusal belongs to the write
    /// that caused it: it stays while the person is still at that field,
    /// and goes when the form is read again for any other reason -- by then
    /// it no longer describes anything on screen.
    static func errors(_ errors: [String: String], after read: FormRead) -> [String: String] {
        read == .afterOwnWrite ? errors : [:]
    }

    static func isWritable(_ item: ConfigForm.Item) -> Bool {
        item.readonly == nil && item.control != .readonly
    }

    /// The dot beside the label (§7.3).
    static func differsFromDefault(_ item: ConfigForm.Item) -> Bool {
        item.value != item.default
    }

    /// "Restore Default" deletes the main file's line (§7.2 rule 5), so it
    /// is offered only where there is such a line to delete.
    static func canRestoreDefault(_ item: ConfigForm.Item) -> Bool {
        isWritable(item) && item.source.kind == .main
    }

    /// Whether leaving a text box writes: only when what is in it is not
    /// what the file already says.
    static func shouldWrite(_ edited: String, over item: ConfigForm.Item) -> Bool {
        edited != item.value
    }

    /// Whether a toggle is on: its value is the one the table says "on"
    /// writes, which for most keys is `true`.
    static func isOn(_ item: ConfigForm.Item) -> Bool { item.value == (item.on ?? "true") }

    /// What a toggle writes. The table's own words where it has them
    /// (`allow` / `deny`): the core refuses `true` for such a key.
    static func toggleValue(_ on: Bool, of item: ConfigForm.Item) -> String {
        on ? (item.on ?? "true") : (item.off ?? "false")
    }

    /// The shortcut rows a group shows after its settings.
    static func shortcuts(in group: GeneralGroup, of form: ConfigForm) -> [ConfigForm.Shortcut] {
        guard let name = coreGroup(group) else { return [] }
        return form.sections.first { $0.group == name }?.shortcuts ?? []
    }

    /// What a shortcut row says the action is bound to: its keys, or that
    /// it has none.
    static func bindingText(_ keys: [String], bundle: Bundle = .main) -> String {
        keys.isEmpty ? localized("Not set", bundle: bundle) : keys.joined(separator: "   ")
    }

    /// A range narrow enough to drag (background opacity's 0-1). Integer
    /// types come with their type's whole range, which is not a slider.
    static func usesSlider(_ item: ConfigForm.Item) -> Bool {
        guard item.control == .number, let min = item.min, let max = item.max else { return false }
        return max > min && max - min <= 1
    }

    /// A slider's value as it is written: two decimals, trailing zeros
    /// dropped (`0.9`, `1`, `0.25`).
    static func sliderText(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// `theme = light:A,dark:B` as its two halves; a single name is both.
    static func themePair(_ value: String) -> (light: String, dark: String) {
        var light: String?
        var dark: String?
        for part in value.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("light:") { light = String(p.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces) }
            else if p.hasPrefix("dark:") { dark = String(p.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces) }
        }
        if light == nil && dark == nil {
            let single = value.trimmingCharacters(in: .whitespaces)
            return (single, single)
        }
        return (light ?? "", dark ?? "")
    }

    /// The two halves written back the way the file writes them: one name
    /// when both are the same, nothing when both are empty.
    static func themeValue(light: String, dark: String) -> String {
        let l = light.trimmingCharacters(in: .whitespaces)
        let d = dark.trimmingCharacters(in: .whitespaces)
        if l == d { return l }
        return "light:\(l),dark:\(d)"
    }
}
