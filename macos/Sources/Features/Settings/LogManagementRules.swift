import Foundation

// Settings > General > Log Management (task 1511), with no AppKit in it:
// what the core says (`ghostty_app_storage_usage`, `Storage.writeUsage`),
// what each row and each confirmation says, and how a retention field's
// text becomes the value written to the config file.

/// The page's figures, as the core gives them.
struct StorageUsage: Decodable, Equatable {
    var stateDir: String
    var totalBytes: UInt64
    /// The first sweep is waiting for the person, and would delete this much.
    var waitingBytes: UInt64?
    var kinds: [Kind]

    struct Kind: Decodable, Equatable, Identifiable {
        var key: String
        /// `cycle`, `fixed` or `forever`.
        var kept: String
        var bytes: UInt64
        var files: Int
        var daysKey: String?
        var mbKey: String?
        var fixedDays: Int?
        /// `clear` or `compact`.
        var action: String

        var id: String { key }
        var goesRound: Bool { kept != "forever" }
    }

    static func parse(_ json: String) -> StorageUsage? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(StorageUsage.self, from: Data(json.utf8))
    }
}

/// The columns, right to left from the content's right edge
/// (`log-management-v3/README.md`: the tenth run found the English page's
/// "days" broken in two at a unit of 28, and "Compact…" has no room in 80).
enum LogManagementColumns {
    static let button: CGFloat = 96
    static let size: CGFloat = 72
    static let days: CGFloat = 44
    static let mb: CGFloat = 56
    static let unit: CGFloat = 36
    static let gap: CGFloat = 8
    /// The least a row is; one whose description wraps grows.
    static let rowHeight: CGFloat = 40
    /// A description wraps rather than being cut off -- the English ones
    /// run past their column -- but to no more than this.
    static let detailLines = 2
    /// Both fields and their units, which a row with no fields fills with
    /// one sentence instead.
    static var rule: CGFloat { days + unit + gap + mb + unit + gap }

    /// The least the name and description are given beside the controls.
    /// Less than this and the row is stacked: the name and description on
    /// top across the whole width, the controls under them, in the same
    /// columns from the right edge -- the Windows page's rule
    /// (`windows/settings-shell/src/logs.rs`, `TEXT_MIN_W`).
    ///
    /// Task 1604: at the settings window's least width, 900, a row is 388
    /// wide and the controls take 372 of it; the name was given the 16 left
    /// and drawn one character to a line.
    static let textMin: CGFloat = 200
    /// In a stacked row, between the description and the controls under it.
    static let stackGap: CGFloat = 4

    /// What a row's name and description are given beside the controls, in
    /// a row `rowWidth` wide: everything but the rule, the size, the button
    /// and the gaps before each.
    static func textWidth(rowWidth: CGFloat) -> CGFloat {
        max(0, rowWidth - (days + unit + gap + mb + unit) - size - button - 3 * gap)
    }

    /// Whether a row `rowWidth` wide is stacked ([`textMin`]).
    static func stacks(rowWidth: CGFloat) -> Bool {
        textWidth(rowWidth: rowWidth) < textMin
    }
}

enum LogManagementRules {
    /// The two groups of rows, in the core's order within each.
    static func sections(_ usage: StorageUsage) -> (cycle: [StorageUsage.Kind], forever: [StorageUsage.Kind]) {
        (usage.kinds.filter(\.goesRound), usage.kinds.filter { !$0.goesRound })
    }

    static func title(_ key: String) -> String {
        switch key {
        case "group_transcripts": String(localized: "Terminal Records · In Groups", comment: "日志管理：一行的名字，在群里工作期间的终端记录")
        case "project_transcripts": String(localized: "Terminal Records · In Projects", comment: "日志管理：一行的名字，项目标签页里的终端记录")
        case "other_transcripts": String(localized: "Terminal Records · Other", comment: "日志管理：一行的名字，不在群也不在项目里的终端记录")
        case "logs": String(localized: "Logs", comment: "日志管理：一行的名字，Polter 自己的日志")
        case "shots": String(localized: "Screenshots", comment: "日志管理：一行的名字，截图")
        case "rename_backups": String(localized: "Group Rename Backups", comment: "日志管理：一行的名字，改群名时留下的备份")
        case "chat": String(localized: "Group Chat Records", comment: "日志管理：一行的名字，群聊记录")
        case "tasks": String(localized: "Task Records", comment: "日志管理：一行的名字，任务记录")
        case "history": String(localized: "Shell History", comment: "日志管理：一行的名字，Shell 命令历史")
        case "archive": String(localized: "Archive Plugin's Copy", comment: "日志管理：一行的名字，归档插件另存的群聊")
        default: key
        }
    }

    static func detail(_ key: String) -> String {
        switch key {
        case "group_transcripts": String(localized: "What terminals printed while working in a group; supervisors look back through it", comment: "日志管理：一行的说明，群里的终端记录")
        case "project_transcripts": String(localized: "In a project's tabs, while in no group", comment: "日志管理：一行的说明，项目里的终端记录")
        case "other_transcripts": String(localized: "Terminals in no group and no project", comment: "日志管理：一行的说明，其它终端记录")
        case "logs": String(localized: "Plugins' older logs, crash reports, hourly group snapshots", comment: "日志管理：一行的说明，日志")
        case "shots": String(localized: "Polter's screenshots; nothing else in the folder is touched", comment: "日志管理：一行的说明，截图")
        case "rename_backups": String(localized: "Old files a rename set aside, only to finish an interrupted one", comment: "日志管理：一行的说明，改名备份")
        case "chat": String(localized: "What each group said, day by day", comment: "日志管理：一行的说明，群聊记录")
        case "tasks": String(localized: "The task panel's history; compacting keeps where each task stands", comment: "日志管理：一行的说明，任务记录")
        case "history": String(localized: "Each pane's commands; clearing removes only what no project uses", comment: "日志管理：一行的说明，Shell 历史")
        case "archive": String(localized: "The archive plugin's own copy of the chat, not Polter's records", comment: "日志管理：一行的说明，归档插件的副本")
        default: ""
        }
    }

    /// `shown` as it is in `usage`, read again just now; nil when the core
    /// no longer lists it, and then nothing is asked.
    static func current(_ shown: StorageUsage.Kind, in usage: StorageUsage?) -> StorageUsage.Kind? {
        usage?.kinds.first { $0.key == shown.key }
    }

    /// What the button on a row says.
    static func action(_ kind: StorageUsage.Kind) -> String {
        kind.action == "compact"
            ? String(localized: "Compact…", comment: "日志管理：任务记录那一行的按钮，压实")
            : String(localized: "Clear…", comment: "日志管理：每一行的清理按钮")
    }

    /// A size, the way the Finder writes one -- but nothing is "0 KB", not
    /// "Zero KB": the formatter spells zero out unless told not to, and
    /// in a column of figures the word stands out as something else.
    static func size(_ bytes: UInt64) -> String {
        sizeFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// What a retention field shows for the value in the config file.
    static func fieldText(_ value: String) -> String {
        value == "unlimited" ? noLimit : value
    }

    static var noLimit: String { String(localized: "No limit", comment: "日志管理：保留天数或总量不设上限时框里的字") }

    /// What to write for what was typed: a whole number, or "unlimited"
    /// for an empty field or the words for no limit. Nil when it is
    /// neither, and then nothing is written.
    static func valueToWrite(_ typed: String) -> String? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == noLimit || t.lowercased() == "unlimited" { return "unlimited" }
        guard let n = UInt32(t) else { return nil }
        return String(n)
    }

    struct Confirmation: Equatable {
        var title: String
        var lines: [String]
        var button: String
    }

    /// What "Clear…" asks before it does anything: how much goes and
    /// whether it comes back, what it is, and what stops working or stays.
    static func confirmation(_ kind: StorageUsage.Kind) -> Confirmation {
        let size = size(kind.bytes)
        let deleted = String(format: String(localized: "%1$@ (%2$lld files) will be deleted. This cannot be undone.", comment: "日志管理：确认框第一行，%1$@ 是大小，%2$lld 是文件数"), size, Int64(kind.files))
        let lookBack = String(localized: "After this, the AI can no longer find them when it looks back.", comment: "日志管理：确认框，删终端记录的后果")
        let today = String(localized: "Today's file that is still being written is kept.", comment: "日志管理：确认框，正在写的不删")
        let clear = String(localized: "Clear Now", comment: "日志管理：确认框的按钮，清理")
        let named = String(format: String(localized: "Clear “%@”?", comment: "日志管理：确认框标题，%@ 是这一行的名字"), title(kind.key))
        switch kind.key {
        case "group_transcripts":
            return .init(title: named, lines: [deleted, String(localized: "These are what terminals printed while working in a group.", comment: "日志管理：确认框，群里的终端记录是什么"), lookBack, today], button: clear)
        case "project_transcripts":
            return .init(title: named, lines: [deleted, String(localized: "These are what terminals printed in a project's tabs while in no group.", comment: "日志管理：确认框，项目里的终端记录是什么"), lookBack, today], button: clear)
        case "other_transcripts":
            return .init(title: named, lines: [deleted, String(localized: "These are what terminals printed while in no group and no project's tab.", comment: "日志管理：确认框，其它终端记录是什么"), lookBack, today], button: clear)
        case "logs":
            return .init(title: named, lines: [deleted, String(localized: "They are only for finding out what went wrong; nothing Polter does depends on them.", comment: "日志管理：确认框，删日志的后果"), today], button: clear)
        case "shots":
            return .init(title: named, lines: [deleted, String(localized: "Only Polter's own screenshots go; nothing else in the folder is touched. The AI can no longer list or open them.", comment: "日志管理：确认框，删截图的后果")], button: clear)
        case "rename_backups":
            return .init(title: named, lines: [deleted, String(localized: "They are only needed to finish a rename that was interrupted, and none is under way.", comment: "日志管理：确认框，删改名备份的后果")], button: clear)
        case "chat":
            return .init(
                title: String(localized: "Clear the group chat records?", comment: "日志管理：确认框标题，群聊记录"),
                lines: [
                    String(format: String(localized: "Every group's chat before today will be deleted, at most %@. This cannot be undone.", comment: "日志管理：确认框，删群聊记录，%@ 是大小"), size),
                    String(localized: "The list of groups, their notes, the last supervisor and project ties are kept.", comment: "日志管理：确认框，删群聊记录保留什么"),
                    String(localized: "The chat page and the AI reading back a group can no longer reach messages before today.", comment: "日志管理：确认框，删群聊记录的后果"),
                ],
                button: clear)
        case "tasks":
            return .init(
                title: String(localized: "Compact the task records?", comment: "日志管理：确认框标题，压实任务记录"),
                lines: [
                    String(format: String(localized: "Each task keeps only where it stands now: title, owner, progress, open or closed. The history of changes before today, at most %@, will be deleted. This cannot be undone.", comment: "日志管理：确认框，压实任务记录，%@ 是大小"), size),
                    String(localized: "The task panel is unchanged and task numbers stay the same.", comment: "日志管理：确认框，压实任务记录保留什么"),
                    String(localized: "The history of task changes and the statistics page will no longer show events before today.", comment: "日志管理：确认框，压实任务记录的后果"),
                ],
                button: String(localized: "Compact", comment: "日志管理：确认框的按钮，压实"))
        case "history":
            return .init(
                title: String(localized: "Clear shell history?", comment: "日志管理：确认框标题，Shell 历史"),
                lines: [
                    String(format: String(localized: "History files no saved project and no open pane uses will be deleted, at most %@. This cannot be undone.", comment: "日志管理：确认框，删 Shell 历史，%@ 是大小"), size),
                    String(localized: "Panes opened from a project, and panes open now, keep their history.", comment: "日志管理：确认框，删 Shell 历史保留什么"),
                ],
                button: clear)
        default:
            return .init(
                title: named,
                lines: [
                    String(format: String(localized: "The archive plugin's copies before today will be deleted, at most %@. This cannot be undone.", comment: "日志管理：确认框，删归档插件的副本，%@ 是大小"), size),
                    String(localized: "This is the archive plugin's own copy of the chat; Polter's chat records are not touched.", comment: "日志管理：确认框，删归档插件的副本不影响什么"),
                ],
                button: clear)
        }
    }

    /// The one-time notice, here and in the control room.
    static func noticeTitle(_ bytes: UInt64) -> String {
        String(format: String(localized: "The new retention settings will clear %@ of old records", comment: "日志管理与总控台：第一次清理前的提示，%@ 是大小"), size(bytes))
    }

    static var noticeDetail: String {
        String(localized: "This is the first clearing since the upgrade, and nothing is deleted until you choose OK. You can change the settings below first; a change counts as agreeing.", comment: "日志管理：第一次清理前的提示，第二行")
    }
}
