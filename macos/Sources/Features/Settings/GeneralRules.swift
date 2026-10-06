import CoreGraphics
import Foundation

// The General section's rules, with no AppKit in them (settings.md §7):
// which groups it has, in what order, which of them wait for the core's
// form table, and what the About group says.

/// The groups of the General section, in list order (§7.1). The raw values
/// are what a route's `item` names.
enum GeneralGroup: String, CaseIterable, Identifiable {
    case appearance, font, terminal, windows, polter, all, screenshot, keybinds, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: String(localized: "Appearance", comment: "设置窗口·通用：分组，外观")
        case .font: String(localized: "Font", comment: "设置窗口·通用：分组，字体")
        case .terminal: String(localized: "Terminal", comment: "设置窗口·通用：分组，终端")
        case .windows: String(localized: "Windows & Tabs", comment: "设置窗口·通用：分组，窗口与标签")
        case .polter: "Polter"
        case .all: String(localized: "All Options", comment: "设置窗口·通用：分组，全部选项")
        case .screenshot: String(localized: "Screenshot", comment: "设置窗口·通用：分组，截图")
        case .keybinds: String(localized: "Keyboard Shortcuts", comment: "快捷键一览窗口的标题")
        case .advanced: String(localized: "Advanced", comment: "设置窗口·通用：分组，高级")
        case .about: String(localized: "About", comment: "设置窗口·通用：分组，关于")
        }
    }

    /// Drawn from the core's form table (§7.2), which the host does not have
    /// yet: these show a placeholder until it does.
    var needsForm: Bool {
        switch self {
        case .appearance, .font, .terminal, .windows, .polter, .all, .screenshot: true
        case .keybinds, .advanced, .about: false
        }
    }
}

enum GeneralRules {
    /// Which group a route to General lands on: the one it names; with none
    /// named, a newly opened window takes the first and an open one stays
    /// where it is. A name that is no group counts as none.
    static func groupToSelect(item: String?, fresh: Bool, current: GeneralGroup) -> GeneralGroup {
        if let item, let named = GeneralGroup(rawValue: item) { return named }
        return fresh ? GeneralGroup.allCases[0] : current
    }

    /// The Keyboard Shortcuts columns: name, keys, note. The note needs
    /// room to be read; where there is less than `minNote` left for it (the
    /// window near its minimum, where the page is 418 wide), it goes on a
    /// line of its own under the keys instead of being squeezed to one
    /// character a line.
    enum KeybindColumns {
        static let name: CGFloat = 220
        static let keys: CGFloat = 160
        static let gap: CGFloat = 12
        static let minNote: CGFloat = 160
    }

    static func keybindNoteBelow(contentWidth: CGFloat) -> Bool {
        typealias C = KeybindColumns
        return contentWidth < C.name + C.gap + C.keys + C.gap + C.minNote
    }

    /// One line of the About group.
    struct AboutRow: Equatable {
        enum Label: Hashable { case version, build, commit }
        var label: Label
        var value: String
    }

    /// Version, build and commit, as the bundle states them (§7.1 "About").
    /// A value that is missing or blank is left out rather than shown empty:
    /// a blank commit reads as "this build has no commit", which is a claim.
    static func aboutRows(version: String?, build: String?, commit: String?) -> [AboutRow] {
        [(AboutRow.Label.version, version), (.build, build), (.commit, commit)].compactMap { label, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return AboutRow(label: label, value: value)
        }
    }
}
