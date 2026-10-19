import AppKit

/// What each item of the group row's menu is called and drawn with (task
/// 1660, design v21 `01`, `02`, `06`), and the `NSMenu` made of them. Which
/// items there are, in which order, is not decided here: that is
/// `ControlRoomRowMenu`'s, the rule both hosts hold. Items are named by the
/// keys that rule prints (`jump_to_supervisor`, ...), so this file and that
/// one meet at those strings and nowhere else.
///
/// The menu is the system's own: its rows, its insets, its highlight and
/// its fonts are the ones every other menu in the app has. The design's
/// numbers for them describe what the system draws; none is set here.
enum ControlRoomRowMenuItems {
    /// One line of a menu: an item by its key, with the keys of its submenu
    /// when it opens one; or a line between groups.
    enum Line: Equatable {
        case item(String, submenu: [String]?)
        case separator
    }

    /// The rule's menu as lines. `startNew` is what "with a new session"
    /// opens when it opens anything: the ids of `cliSubmenu`.
    static func lines(_ entries: [ControlRoomRowMenu.Entry], startNew: [String]? = nil) -> [Line] {
        entries.map { entry in
            switch entry {
            case .separator: return .separator
            case .item(let item):
                if item == .startNew, let startNew { return .item(item.rawValue, submenu: startNew) }
                return .item(item.rawValue, submenu: item.submenu?.map(\.rawValue))
            }
        }
    }

    /// What stands at the right of the CLI the last supervisor used, in the
    /// submenu of CLIs (02A).
    static var lastUsedText: String {
        String(localized: "Last used", comment: "总控台：群行右键「启动总管，用新会话」子菜单里，上次总管用的那个 CLI 右侧的标注")
    }

    /// Every key the rule can hand in, with what it says.
    static func title(_ key: String) -> String? {
        switch key {
        case "jump_to_supervisor": return String(localized: "Jump to Supervisor", comment: "总控台：群行右键菜单，跳到总管")
        case "take_over": return String(localized: "Let the Control Room Take Over…", comment: "总控台：群行右键菜单，总管没接钩子时让总控台接管（要确认）")
        case "start_resume": return String(localized: "Start Supervisor, Going On with the Last Session", comment: "总控台：群行右键菜单，没有总管时：启动总管，接着上次的会话")
        case "start_new": return String(localized: "Start Supervisor, New Session", comment: "总控台：群行右键菜单，没有总管时：启动总管，用新会话")
        case "start": return String(localized: "Start Supervisor…", comment: "总控台：群行右键菜单，没有总管、也没有上次的会话时")
        case "report_progress": return String(localized: "Ask the Supervisor to Report Progress", comment: "总控台：群行右键菜单，请总管汇报进度")
        case "close_idle_workers": return String(localized: "Ask the Supervisor to Close Idle Workers", comment: "总控台：群行右键菜单，让总管关闭闲置 worker")
        case "tidy_workers": return String(localized: "Ask the Supervisor to Tidy Its Workers", comment: "总控台：群行右键菜单，让总管把 worker 收进它右边那一摞（#1797）")
        case "reveal": return String(localized: "Show in Finder", comment: "总控台：群行右键菜单，在访达中显示这个群的记录")
        case "copy_supervisor_id": return String(localized: "Copy Supervisor Terminal ID", comment: "总控台：群行右键菜单，复制总管终端 ID")
        case "pin": return String(localized: "Pin", comment: "总控台：群行右键菜单，置顶")
        case "unpin": return String(localized: "Unpin", comment: "总控台：群行右键菜单，取消置顶")
        case "mute": return String(localized: "Mute This Group's Notifications", comment: "总控台：群行右键菜单，静音这个群的通知（子菜单）")
        case "unmute": return String(localized: "Unmute", comment: "总控台：群行右键菜单，取消静音")
        case "rename": return String(localized: "Rename Group…", comment: "总控台：群行右键菜单，重命名群")
        case "edit_note": return String(localized: "Edit Group Note…", comment: "总控台：群行右键菜单，编辑群简介")
        case "project": return String(localized: "Project", comment: "总控台：群行右键菜单，项目（子菜单）")
        case "archive": return String(localized: "Archive…", comment: "总控台：群行右键菜单，归档（要确认）")
        case "unarchive": return String(localized: "Unarchive", comment: "总控台：已归档的群右键菜单，取消归档")
        case "delete": return String(localized: "Delete Group…", comment: "总控台：群行右键菜单，删除群（要确认）")
        case "mute_hour": return String(localized: "1 Hour", comment: "总控台：静音子菜单，1 小时")
        case "mute_tomorrow": return String(localized: "Until Tomorrow", comment: "总控台：静音子菜单，到明天")
        case "mute_forever": return String(localized: "Until Turned Back On", comment: "总控台：静音子菜单，一直（直到取消静音）")
        default: return nil
        }
    }

    /// The system symbol drawn at an item's left, as the design drew them;
    /// nil for the submenus' items, which have none.
    static func symbol(_ key: String) -> String? {
        switch key {
        case "jump_to_supervisor": return "arrow.up.forward.square"
        case "take_over": return "link"
        case "start_resume": return "arrow.counterclockwise"
        case "start_new", "start": return "play"
        case "report_progress": return "text.bubble"
        case "close_idle_workers": return "moon"
        case "tidy_workers": return "square.stack"
        case "reveal": return "folder"
        case "copy_supervisor_id": return "doc.on.doc"
        case "pin": return "pin"
        case "unpin": return "pin.slash"
        case "mute": return "bell.slash"
        case "unmute": return "bell"
        case "rename": return "pencil"
        case "edit_note": return "doc.text"
        case "project": return "square.on.square"
        case "archive", "unarchive": return "archivebox"
        case "delete": return "trash"
        default: return nil
        }
    }

    /// The one item set in red: it cannot be undone.
    static func isDestructive(_ key: String) -> Bool { key == "delete" }

    /// The menu for `lines`.
    ///
    /// - Parameters:
    ///   - trailing: what stands at an item's right -- until when a mute
    ///     would last, or does -- by its key; nil for nothing.
    ///   - enabled: whether an item can be chosen now. Only the project's
    ///     submenu greys anything: the rule leaves out what cannot be used.
    ///   - choose: what to do when an item is chosen, by its key.
    @MainActor
    static func menu(_ lines: [Line],
                     title named: (String) -> String? = { _ in nil },
                     trailing: (String) -> String? = { _ in nil },
                     enabled: (String) -> Bool = { _ in true },
                     choose: @escaping (String) -> Void) -> NSMenu {
        let target = Target(choose)
        func build(_ lines: [Line]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for line in lines {
                switch line {
                case .separator:
                    menu.addItem(.separator())
                case .item(let key, let submenu):
                    let item = NSMenuItem(title: named(key) ?? title(key) ?? key, action: #selector(Target.chosen(_:)), keyEquivalent: "")
                    item.representedObject = key
                    item.target = target
                    item.isEnabled = enabled(key)
                    if let symbol = symbol(key) {
                        item.image = image(symbol, red: isDestructive(key))
                    }
                    if isDestructive(key) {
                        // No font while the system has none: the menu's own
                        // is used, and a nil never reaches CoreText (task 1805).
                        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemRed]
                        if let font = SafeFace.menu.font { attributes[.font] = font }
                        item.attributedTitle = NSAttributedString(string: item.title, attributes: attributes)
                    }
                    if let right = trailing(key) {
                        put(right, on: item)
                    }
                    if let submenu {
                        item.action = nil
                        item.submenu = build(submenu.map { .item($0, submenu: nil) })
                    }
                    menu.addItem(item)
                }
            }
            return menu
        }
        let menu = build(lines)
        // The target lives as long as the menu does.
        objc_setAssociatedObject(menu, &Target.key, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return menu
    }

    /// The "Project ›" submenu of `lines` (task 1713): a header is the
    /// system's section header, which cannot be chosen.
    @MainActor
    static func projectMenu(_ lines: [ProjectLinkMenu.Line], choose: @escaping (String) -> Void) -> NSMenu {
        let target = Target(choose)
        func build(_ lines: [ProjectLinkMenu.Line]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for line in lines {
                switch line {
                case .header(let text):
                    let item: NSMenuItem
                    if #available(macOS 14.0, *) {
                        item = NSMenuItem.sectionHeader(title: text)
                    } else {
                        item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    }
                    item.isEnabled = false
                    menu.addItem(item)
                case .item(let key, let title, let enabled):
                    let item = NSMenuItem(title: title, action: #selector(Target.chosen(_:)), keyEquivalent: "")
                    item.representedObject = key
                    item.target = target
                    item.isEnabled = enabled
                    menu.addItem(item)
                case .submenu(let key, let title, let inner):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.representedObject = key
                    item.submenu = build(inner)
                    item.isEnabled = !inner.isEmpty
                    menu.addItem(item)
                }
            }
            return menu
        }
        let menu = build(lines)
        objc_setAssociatedObject(menu, &Target.key, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return menu
    }

    /// What an item says at its right, in the system's place for it: the
    /// badge on macOS 14 and later, the end of its title before that.
    @MainActor
    private static func put(_ text: String, on item: NSMenuItem) {
        if #available(macOS 14.0, *) {
            item.badge = NSMenuItemBadge(string: text)
        } else {
            item.title += "  " + text
        }
    }

    @MainActor
    private static func image(_ symbol: String, red: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        guard red else { return base }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let tinted = base.withSymbolConfiguration(config)
        tinted?.isTemplate = false
        return tinted
    }

    private final class Target: NSObject {
        static var key = 0
        let choose: (String) -> Void
        init(_ choose: @escaping (String) -> Void) { self.choose = choose }
        @objc func chosen(_ sender: NSMenuItem) {
            if let key = sender.representedObject as? String { choose(key) }
        }
    }
}
