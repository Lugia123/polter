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
    }

    enum Control: String, Equatable {
        case toggle, choice, number, text, font, color, theme, readonly
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
        var min: Double?
        var max: Double?
        var `default`: String
        /// As the config file writes it; a repeatable key's lines joined
        /// with `\n`.
        var value: String
        var doc: String?
        var source: Source
        /// Why the form may not write it: `repeatable`, `multiple`, `cli`,
        /// `file`; nil when it may.
        var readonly: String?

        var id: String { key }

        private enum CodingKeys: String, CodingKey {
            case key, group, control, choices, min, max, `default`, value, doc, source, readonly
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            group = try c.decodeIfPresent(String.self, forKey: .group)
            // A control this build does not know (a newer core) is shown,
            // read-only, rather than dropping the key or the whole table.
            control = Control(rawValue: try c.decode(String.self, forKey: .control)) ?? .readonly
            choices = try c.decodeIfPresent([String].self, forKey: .choices)
            min = try c.decodeIfPresent(Double.self, forKey: .min)
            max = try c.decodeIfPresent(Double.self, forKey: .max)
            `default` = try c.decode(String.self, forKey: .default)
            value = try c.decode(String.self, forKey: .value)
            doc = try c.decodeIfPresent(String.self, forKey: .doc)
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

    static func isOn(_ item: ConfigForm.Item) -> Bool { item.value == "true" }

    static func toggleValue(_ on: Bool) -> String { on ? "true" : "false" }

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
