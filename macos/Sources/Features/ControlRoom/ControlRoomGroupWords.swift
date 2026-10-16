import Foundation

/// What the group row's menu and what it opens say, worked out from what
/// they are given (task 1660, design v21): when a group would be muted
/// until, how many characters a note is, what the archive and delete
/// questions ask, what the line under a row says once the supervisor was
/// asked something. Nothing here draws; each piece is tested without the
/// app.
enum ControlRoomGroupWords {
    // MARK: Muting

    /// The three lengths in "Mute This Group's Notifications ▸".
    enum MuteFor: CaseIterable {
        case hour
        /// Until 9:00 the next day (the supervisor's ruling, 2026-10-16).
        case tomorrow
        case forever
    }

    /// What hour of the next day "until tomorrow" ends at.
    static let tomorrowHour = 9

    /// When a group muted at `now` for `length` is heard again; nil for
    /// never.
    static func muteEnd(_ length: MuteFor, now: Date, calendar: Calendar) -> Date? {
        switch length {
        case .hour:
            return now.addingTimeInterval(3600)
        case .tomorrow:
            let today = calendar.startOfDay(for: now)
            guard let next = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return calendar.date(bySettingHour: tomorrowHour, minute: 0, second: 0, of: next)
        case .forever:
            return nil
        }
    }

    /// The time of day, as the person's clock shows it.
    static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }

    /// What stands at the right of one of the three lengths: when it would
    /// end -- "until 15:40", "tomorrow 9:00" -- or nothing for "always".
    static func muteEndText(_ length: MuteFor, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard let end = muteEnd(length, now: now, calendar: calendar) else { return nil }
        let time = clock(end, calendar: calendar, locale: locale)
        switch length {
        case .hour:
            return String(format: String(localized: "until %@", comment: "总控台：群行右键「静音」子菜单右侧，静音到几点"), time)
        case .tomorrow:
            return String(format: String(localized: "tomorrow %@", comment: "总控台：群行右键「静音到明天」右侧，明天几点"), time)
        case .forever:
            return nil
        }
    }

    /// What stands at the right of "Unmute" on a muted group: until when,
    /// as near as it is -- a time today, "tomorrow" and a time, or a day and
    /// a time -- and nothing for a group muted for good.
    static func mutedUntilText(_ until: Date?, now: Date, calendar: Calendar, locale: Locale) -> String? {
        guard let until else { return nil }
        let time = clock(until, calendar: calendar, locale: locale)
        if calendar.isDate(until, inSameDayAs: now) {
            return String(format: String(localized: "until %@", comment: "总控台：群行右键「静音」子菜单右侧，静音到几点"), time)
        }
        if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: next) {
            return String(format: String(localized: "until tomorrow %@", comment: "总控台：群行右键「取消静音」右侧，静音到明天几点"), time)
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return String(format: String(localized: "until %@", comment: "总控台：群行右键「静音」子菜单右侧，静音到几点"), f.string(from: until))
    }

    // MARK: The note

    /// Under the note being edited: how long it is, and whether what is in
    /// the box is not what is kept. A character is what the person sees as
    /// one -- an emoji or a letter with its accent is one.
    static func noteCount(_ text: String, changed: Bool) -> String {
        let n = text.count
        return changed
            ? String(format: String(localized: "%d characters, not saved", comment: "总控台：群简介面板底部，字数和没保存"), n)
            : String(format: String(localized: "%d characters", comment: "总控台：群简介面板底部，字数"), n)
    }

    // MARK: Renaming

    /// The one refusal the host gives itself, before the core is asked:
    /// the core's own word for it, said the same way. The other two --
    /// taken, and not lowercase letters, digits and dashes -- are the
    /// core's to give.
    static var emptyName: String {
        ControlRoomActions.Refusal(name: "EmptyName").message
    }

    // MARK: Archiving and deleting

    /// What the question to archive a group says (design v21 `06`).
    static func archiveQuestion(name: String, supervisorRunning: Bool) -> (title: String, body: String) {
        let title = String(format: String(localized: "Archive %@?", comment: "总控台：归档确认框的标题"), name)
        var body = String(localized: "It goes into \"Archived\" at the bottom of the list and stops notifying you. Its chat, tasks, note and project are all kept; right-click it in \"Archived\" and choose \"Unarchive\" to bring it back.",
                          comment: "总控台：归档确认框的正文")
        if supervisorRunning {
            body += "\n\n" + String(localized: "The supervisor is still running. Archiving does not close its terminal or the workers'.",
                                   comment: "总控台：归档确认框，总管还在跑时多的一句")
        }
        return (title, body)
    }

    /// Who and what is still in a group about to be deleted.
    struct Still: Equatable {
        /// The supervisor is one of them.
        var supervisor: Bool
        var workers: Int
        var openTasks: Int

        var members: Int { workers + (supervisor ? 1 : 0) }
        var isEmpty: Bool { members == 0 && openTasks == 0 }
    }

    /// What the question to delete a group says (design v21 `06`): the
    /// warning when people or work are still in it, nil when not; what goes
    /// with it; what stays.
    struct DeleteQuestion: Equatable {
        var title: String
        /// The red block; nil with nobody and nothing left in the group.
        var warning: String?
        var body: String
        /// What stays, and the way out; nil when there is neither.
        var aside: String?
    }

    static func deleteQuestion(name: String, project: String?, still: Still) -> DeleteQuestion {
        let title = String(format: String(localized: "Delete the group %@?", comment: "总控台：删除群确认框的标题"), name)
        let body = String(localized: "Its chat, task panel and note are deleted with it, and can't be brought back.",
                          comment: "总控台：删除群确认框，会一起删掉的东西")
        var aside: [String] = []
        if let project {
            aside.append(String(format: String(localized: "The project %@ stays, its tabs and layout as they are; it just no longer belongs to a group.",
                                               comment: "总控台：删除群确认框，项目留着"), project))
        }
        if !still.isEmpty {
            aside.append(String(localized: "To keep everything, archive it instead.", comment: "总控台：删除群确认框，最后给出路"))
        }
        return DeleteQuestion(title: title, warning: warning(still), body: body,
                              aside: aside.isEmpty ? nil : aside.joined(separator: " "))
    }

    /// The red block: how many are still in the group and how much work is
    /// not done, and that deleting closes no terminal.
    static func warning(_ still: Still) -> String? {
        guard !still.isEmpty else { return nil }
        var parts: [String] = []
        if still.members > 0 {
            if still.supervisor {
                parts.append(String(format: String(localized: "%1$d members (the supervisor and %2$d workers)",
                                                   comment: "总控台：删除群警告，成员数：总管和几个 worker"), still.members, still.workers))
            } else {
                parts.append(String(format: String(localized: "%d workers", comment: "总控台：删除群警告，只有 worker"), still.workers))
            }
        }
        if still.openTasks > 0 {
            parts.append(String(format: String(localized: "%d unfinished tasks", comment: "总控台：删除群警告，没做完的任务数"), still.openTasks))
        }
        let who = parts.joined(separator: String(localized: " and ", comment: "总控台：删除群警告，连接成员和任务"))
        return String(format: String(localized: "This group still has %@. Deleting it closes none of their terminals, but they leave the group, and unfinished tasks are deleted with it.",
                                     comment: "总控台：删除群警告的整句"), who)
    }

    // MARK: Archived

    /// The header of the list's last section: how many groups are put away.
    static func archivedHeader(_ count: Int) -> String {
        String(format: String(localized: "Archived (%d)", comment: "总控台：列表底部「已归档 (N)」"), count)
    }

    /// After an archived group's name: the day it was put away.
    static func archivedOn(_ ms: UInt64, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        let day = f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        return String(format: String(localized: "archived %@", comment: "总控台：已归档的群名字后面，哪天归档的"), day)
    }

    // MARK: Asking the supervisor

    /// The two things the menu asks the supervisor to do.
    typealias Ask = ControlRoomActions.Ask

    /// The line under the row once it was asked: what was asked -- not what
    /// was done, since all the control room does is type a sentence into
    /// the supervisor's terminal (design v21 `07`).
    static func asked(_ ask: Ask) -> String {
        switch ask {
        case .reportProgress:
            return String(localized: "Asked the supervisor to report progress", comment: "总控台：群行下的一行，已请总管汇报进度")
        case .closeIdleWorkers:
            return String(localized: "Asked the supervisor to close idle workers", comment: "总控台：群行下的一行，已请总管关闭闲置 worker")
        }
    }

    /// Why a sentence for the supervisor did not go in, short enough for
    /// the one line under a row (design v21 `07`: "the supervisor's input
    /// has text in it"); for a refusal with no short form, the core's own
    /// sentence. The two the core tries again by itself, three times
    /// (#1626), say so.
    static func askReason(_ refusal: String) -> String {
        let again = String(localized: ", will try again", comment: "总控台：没送出去的原因后面，核心会自己再试时加的半句")
        switch refusal {
        case "DraftInLine":
            return String(localized: "the supervisor's input has text in it", comment: "总控台：没送出去的原因：总管的输入框里有字") + again
        case "UserPresent":
            return String(localized: "someone just typed in the supervisor's terminal", comment: "总控台：没送出去的原因：有人刚在总管的终端里打过字") + again
        case "NoAgent":
            return String(localized: "no agent in the supervisor's terminal", comment: "总控台：没送出去的原因：总管的终端里没有 agent")
        case "ChildExited":
            return String(localized: "the supervisor's program has ended", comment: "总控台：没送出去的原因：总管的程序已经退出")
        case "NoSupervisor":
            return String(localized: "this group has no supervisor", comment: "总控台：没送出去的原因：这个群没有总管")
        default:
            return ControlRoomActions.Refusal(name: refusal).message
        }
    }

    /// The same line when the sentence did not go in: why, as the core
    /// said it. No way to the supervisor is offered (the user, 2026-10-16:
    /// the control room shows the supervisor beside the list).
    static func notDelivered(_ why: String) -> String {
        String(format: String(localized: "Not delivered: %@", comment: "总控台：群行下的一行，没送进总管的终端，冒号后是原因"), why)
    }
}
