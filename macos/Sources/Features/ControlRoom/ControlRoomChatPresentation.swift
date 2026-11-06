import Foundation

/// What a message row says about itself (DESIGN-v2 §4): a local clock, a day
/// separator when the day changes, the channel it came from, the role the
/// speaker wore and the terminals it named.
///
/// **Rules, not a view.** The row draws these strings; the arithmetic that
/// decides whether there is a divider, what the clock reads and which name a
/// mention has is here, where a test can hold it without a window. Nothing
/// here invents a fact: a missing role, channel word or mention title is
/// omitted, never written as "no role".
enum ControlRoomChatPresentation {
    /// The local day a message belongs to, as `year * 10_000 + month * 100 +
    /// day` in `calendar`. Used only to compare two messages; nil when the
    /// calendar cannot make a date out of the timestamp.
    static func dayKey(atMs: Int64, calendar: Calendar = .current) -> Int? {
        let parts = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: Double(atMs) / 1000)
        )
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        return year * 10_000 + month * 100 + day
    }

    /// Whether a divider goes before `current`: always for the first row, and
    /// whenever the local day differs from `previous`'s.
    static func needsDayDivider(
        previous: Int64?,
        current: Int64,
        calendar: Calendar = .current
    ) -> Bool {
        guard let previous else { return true }
        guard let before = dayKey(atMs: previous, calendar: calendar),
              let now = dayKey(atMs: current, calendar: calendar)
        else { return true }
        return before != now
    }

    enum Day: Equatable {
        case today
        case yesterday
        case other
    }

    static func day(atMs: Int64, nowMs: Int64, calendar: Calendar = .current) -> Day {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(atMs) / 1000))
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(nowMs) / 1000))
        if day == now { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .other
    }

    /// The day separator's words: "Today", "Yesterday", or the date itself.
    static func dateText(
        atMs: Int64,
        nowMs: Int64,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        switch day(atMs: atMs, nowMs: nowMs, calendar: calendar) {
        case .today:
            return String(localized: "Today", comment: "总控台：群聊页，日期分隔：今天")
        case .yesterday:
            return String(localized: "Yesterday", comment: "总控台：群聊页，日期分隔：昨天")
        case .other:
            let date = Date(timeIntervalSince1970: Double(atMs) / 1000)
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }

    /// A message's local time of day, 24-hour and always with seconds: the
    /// design's `10:12:05`. Built from calendar parts rather than a formatter
    /// so that two rows cannot disagree through a locale.
    static func timeText(atMs: Int64, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents(
            [.hour, .minute, .second],
            from: Date(timeIntervalSince1970: Double(atMs) / 1000)
        )
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
            return ""
        }
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    /// The channel tag's words; nil is not possible today (0 is the public
    /// channel), but the row omits nothing that is present.
    static func channelText(channel: UInt64) -> String {
        if channel == 0 {
            return String(localized: "Group chat", comment: "总控台：群聊页，消息频道：群聊")
        }
        return String(localized: "Task #\(String(channel))", comment: "总控台：群聊页，消息频道：任务编号")
    }

    /// A summary is not somebody speaking; the row carries the design's own
    /// label instead of an author.
    static func summaryText() -> String {
        String(localized: "Handover summary", comment: "总控台：群聊页，交接摘要标签")
    }

    /// The name a row is drawn under: the author, or "You" for a message the
    /// reader sent, or nothing at all when the record carries no name.
    static func authorText(author: String, fromSelf: Bool) -> String {
        if !author.isEmpty { return author }
        if fromSelf {
            return String(localized: "You", comment: "总控台：群聊页，自己发的消息作者名")
        }
        return ""
    }

    /// **Who a row is from**, as the rule above it compares it: the name it
    /// is drawn under, the role the speaker wore, the channel it came in, and
    /// whether it is a handover summary (nobody speaking). Two rows are the
    /// same speaker only when all of those agree -- a new role or a new
    /// channel is a change of subject even under one name (task 2999 ①).
    struct Speaker: Equatable {
        var author: String
        var role: String?
        var channel: UInt64
        var summary: Bool

        /// **An empty role is no role**: a record carrying `""` must not be
        /// compared, or drawn, as one.
        init(author: String, role: String?, channel: UInt64, summary: Bool) {
            self.author = author
            self.role = (role?.isEmpty ?? true) ? nil : role
            self.channel = channel
            self.summary = summary
        }
    }

    /// Whether a hairline goes above `current`: the speaker is not the one
    /// directly above it. **The first row has none** -- its day divider is
    /// already the separation -- and the view draws this rule only where a
    /// day divider is not drawn, so the two never stack (task 2999 ①).
    static func needsSpeakerRule(previous: Speaker?, current: Speaker) -> Bool {
        guard let previous else { return false }
        return previous != current
    }

    /// The rule above every row of `speakers`, decided once so that a test
    /// can hold the whole list ("A, A, B": no rule, no rule, rule) rather
    /// than one pair at a time.
    static func speakerRules(_ speakers: [Speaker]) -> [Bool] {
        speakers.enumerated().map { index, speaker in
            needsSpeakerRule(
                previous: index > 0 ? speakers[index - 1] : nil,
                current: speaker
            )
        }
    }

    /// What a named terminal is drawn as. The title it had when it was named
    /// is the name a reader recognises; the id is only a fallback for a line
    /// that recorded no title.
    static func mentionText(_ mention: ControlRoomChatData.Mention) -> String {
        if let title = mention.title, !title.isEmpty {
            return "@" + title
        }
        return "@" + mention.id
    }

    /// **The list as it is drawn**, not the feed's array: a message, or a
    /// boundary where the window released a run of records. The view
    /// exhausts this enum, so a gap cannot be forgotten by a different
    /// reader; and the plan is what a test hands real inputs to.
    enum ListRow: Equatable {
        case message(id: String)
        case gap(Gap)

        var id: String {
            switch self {
            case let .message(id): return "m:" + id
            case let .gap(gap): return "g:" + gap.id
            }
        }
    }

    enum Gap: Equatable {
        /// Records older than the first kept message went.
        case before(String)
        /// A run between the message named and the next row went.
        case after(String)

        var id: String {
            switch self {
            case let .before(id): return "before:" + id
            case let .after(id): return "after:" + id
            }
        }
    }

    /// Place the released runs among `order`. **The released run is its own
    /// row**: the message before it and the message after it are never drawn
    /// next to each other, whether or not the view remembers to ask.
    ///
    /// `trimmedAfter` names a row that should still be in `order`. If it is
    /// not (the reader moved on and that row itself was released), the gap
    /// is still real and is said at the top rather than dropped.
    static func listRows(
        order: [String],
        trimmedBefore: String?,
        trimmedAfter: String?
    ) -> [ListRow] {
        var rows: [ListRow] = []
        let afterIsPlaced = trimmedAfter.map(order.contains) ?? true
        if let first = order.first,
           trimmedBefore != nil || !afterIsPlaced {
            rows.append(.gap(.before(first)))
        }
        for id in order {
            rows.append(.message(id: id))
            if let trimmedAfter, id == trimmedAfter {
                rows.append(.gap(.after(id)))
            }
        }
        return rows
    }

    /// **Every non-empty brief may be expanded.** A character count is not a
    /// measurement: seventy Chinese characters in a narrow window are more
    /// than two lines, and the words past the clamp would be unreachable with
    /// no control. The control is cheap; hiding words is not.
    static func showsBriefToggle(_ brief: String) -> Bool {
        !brief.isEmpty
    }
}
