import CoreGraphics
import Foundation

/// How much of each account's allowance is used: the block at the bottom of
/// the group list (`dev-docs/poltergeist/control-room.md`, 3.6), exactly as
/// the core's snapshot says it (`src/poltergeist/quota.zig` has the shape).
///
/// **Everything in here was decided by the core**: which account is opened
/// out and which is a number in the one line, whether a number is old,
/// whether its window has come round again, whether a way out is named, and
/// how the moment it comes back is to be said. The host puts the core's
/// words into the person's language and formats one count and one moment.
/// It compares no percentages: the limit line is not a number this file
/// knows.
///
/// A word the host does not know is an error, and the whole snapshot is
/// not read -- the same as every other word in it.
struct ControlRoomQuota: Decodable, Equatable {
    enum Family: String, Decodable, Equatable {
        case claude
        case codex
    }

    enum Span: String, Decodable, Equatable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case month
        case other
    }

    /// How old a number is, once it is old.
    struct Ago: Decodable, Equatable {
        enum Unit: String, Decodable, Equatable {
            case hours
            case days
        }

        var unit: Unit
        var n: Int
    }

    /// How the moment an allowance comes back is said.
    struct When: Decodable, Equatable {
        enum Form: String, Decodable, Equatable {
            /// `n` of them from now.
            case minutes
            case hours
            case days
            /// The time of day of `resets_ms`.
            case clock
            /// Its day and time of day.
            case date
        }

        var form: Form
        var n: Int
    }

    /// One window of an account, for a tooltip.
    struct Window: Decodable, Equatable {
        var span: Span
        var used: Int
        /// False once its reset has passed.
        var live: Bool
        var resets_ms: UInt64
    }

    /// An account at or past the limit line: opened out.
    struct Alert: Decodable, Equatable {
        enum Level: String, Decodable, Equatable {
            case near
            /// All of it is gone: the triangle.
            case out
        }

        var family: Family
        var level: Level
        var span: Span
        var used: Int
        /// Wall clock.
        var resets_ms: UInt64
        var when: When
        var stale: Ago?
        /// An account that has room, when the core names one.
        var way_out: Family?
        var at_ms: UInt64
        var windows: [Window]
    }

    /// An account in the one line.
    struct Entry: Decodable, Equatable {
        enum State: String, Decodable, Equatable {
            case fresh
            case stale
            /// Its windows have come round again; the old number is not
            /// said.
            case recovered
            case unreadable
        }

        var family: Family
        var state: State
        var used: Int?
        var span: Span?
        var stale: Ago?
        var at_ms: UInt64?
        var windows: [Window]
    }

    struct Line: Decodable, Equatable {
        enum Label: String, Decodable, Equatable {
            case used
            /// No number from anybody; `entries` is empty.
            case noneYet = "none_yet"
        }

        var label: Label
        var entries: [Entry]
    }

    var alerts: [Alert]
    /// Nil when every account is opened out.
    var line: Line?
}

// MARK: - What it says

extension ControlRoomQuota {
    /// The products' own names, the same in every language.
    static func name(_ family: Family) -> String {
        switch family {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Which window, as the person calls it; nil for one with no name.
    static func spanText(_ span: Span) -> String? {
        switch span {
        case .fiveHour: return String(localized: "5-hour", comment: "总控台额度：5 小时的那一段")
        case .sevenDay: return String(localized: "7-day", comment: "总控台额度：7 天的那一段")
        case .month: return String(localized: "30-day", comment: "总控台额度：30 天的那一段（免费档只有这一段）")
        case .other: return nil
        }
    }

    static func agoText(_ ago: Ago) -> String {
        switch ago.unit {
        case .hours: return String(localized: "\(String(ago.n)) h ago", comment: "总控台额度：这个数是几小时前的")
        case .days: return String(localized: "\(String(ago.n)) d ago", comment: "总控台额度：这个数是几天前的")
        }
    }

    /// The left of the one line.
    static func labelText(_ label: Line.Label) -> String {
        switch label {
        case .used: return String(localized: "Allowance used", comment: "总控台额度：那一行的标题，后面跟各家已用的百分比")
        case .noneYet: return String(localized: "Allowance", comment: "总控台额度：还没有任何数时那一行的标题")
        }
    }

    /// What stands at the right of the one line when nobody has a number.
    static var noneYetText: String {
        String(localized: "No numbers yet", comment: "总控台额度：一个数都没有")
    }

    static var noneYetHelp: String {
        String(localized: "No numbers yet. Once a session has run, this shows how much is used.",
               comment: "总控台额度：一个数都没有时的悬停说明")
    }

    /// What an account says after its name in the one line.
    static func entryValue(_ entry: Entry) -> String {
        switch entry.state {
        case .fresh, .stale:
            return entry.used.map { "\($0)%" } ?? ""
        case .recovered:
            return String(localized: "reset", comment: "总控台额度：这一家的那一段已经过了恢复时刻，旧的数不再显示")
        case .unreadable:
            return String(localized: "unreadable", comment: "总控台额度：这一家的额度读不到")
        }
    }

    /// What follows an account's name in the one line: its number, and
    /// how old the number is when the core says it is old.
    static func entryNumber(_ entry: Entry) -> String {
        let value = entryValue(entry)
        guard let stale = entry.stale else { return value }
        return String(localized: "\(value), \(agoText(stale))", comment: "总控台额度：一个旧的数，后面跟它有多旧")
    }

    /// The first line of an opened-out account.
    static func alertTitle(_ alert: Alert) -> String {
        let who = name(alert.family)
        let span = spanText(alert.span)
        // The sign goes in with the number: a bare `%` in the sentence
        // would be one more thing for a translation to get wrong.
        let percent = "\(alert.used)%"
        switch alert.level {
        case .near:
            if let span {
                return String(localized: "\(who) \(span) \(percent) used",
                              comment: "总控台额度：某一家某一段快用完了。依次是家、哪一段、百分比")
            }
            return String(localized: "\(who) \(percent) used",
                          comment: "总控台额度：某一家快用完了，这一段没有名字")
        case .out:
            if let span {
                return String(localized: "\(who) \(span) allowance used up",
                              comment: "总控台额度：某一家某一段用完了")
            }
            return String(localized: "\(who) allowance used up", comment: "总控台额度：某一家用完了，这一段没有名字")
        }
    }

    /// When an opened-out account comes back, in the form the core chose.
    static func whenText(_ alert: Alert, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let n = String(alert.when.n)
        switch alert.when.form {
        case .minutes:
            return String(localized: "back in \(n) min", comment: "总控台额度：几分钟后恢复")
        case .hours:
            return String(localized: "back in \(n) h", comment: "总控台额度：几小时后恢复")
        case .days:
            return String(localized: "back in \(n) d", comment: "总控台额度：几天后恢复")
        case .clock, .date:
            let moment = momentText(alert.resets_ms, withDay: alert.when.form == .date, timeZone: timeZone, locale: locale)
            return String(localized: "back at \(moment)", comment: "总控台额度：某个时刻恢复，%@ 是时刻")
        }
    }

    /// The way out, when the core names one.
    static func wayOutText(_ alert: Alert) -> String? {
        alert.way_out.map {
            String(localized: "\(name($0)) has room.", comment: "总控台额度：这一家用完了，另一家还有余量")
        }
    }

    /// A moment on the wall clock as the person reads one: the time of day,
    /// and the day before it when the core asks for the day.
    static func momentText(_ ms: UInt64, withDay: Bool, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(withDay ? "MMMdHHmm" : "HHmm")
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// One window, for a tooltip: which, and how much -- or that it has
    /// come round again.
    static func windowText(_ window: Window) -> String {
        let value = window.live
            ? "\(window.used)%"
            : String(localized: "reset", comment: "总控台额度：这一家的那一段已经过了恢复时刻，旧的数不再显示")
        guard let span = spanText(window.span) else { return value }
        return "\(span) \(value)"
    }

    /// Everything about an account the block has no room for: every
    /// window, and when the numbers were taken.
    static func details(windows: [Window], atMs: UInt64?, stale: Ago?,
                        timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var parts = windows.map(windowText)
        if let atMs {
            let taken = momentText(atMs, withDay: stale != nil, timeZone: timeZone, locale: locale)
            parts.append(String(localized: "as of \(taken)", comment: "总控台额度：这些数是什么时候的，%@ 是时刻"))
        }
        return parts.joined(separator: "\n")
    }

    static func help(for entry: Entry, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let who = name(entry.family)
        if entry.state == .unreadable {
            return String(localized: "\(who): this account's allowance could not be read.",
                          comment: "总控台额度：读不到这一家的额度")
        }
        return who + "\n" + details(windows: entry.windows, atMs: entry.at_ms, stale: entry.stale,
                                    timeZone: timeZone, locale: locale)
    }

    static func help(for alert: Alert, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        name(alert.family) + "\n" + details(windows: alert.windows, atMs: alert.at_ms, stale: alert.stale,
                                            timeZone: timeZone, locale: locale)
    }

    /// An account in the one line, read out: its name, its number, and how
    /// old the number is.
    static func spoken(_ entry: Entry) -> String {
        [name(entry.family), entryNumber(entry)].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func spoken(_ alert: Alert) -> String {
        var parts = [alertTitle(alert), whenText(alert)]
        if let stale = alert.stale { parts.append(agoText(stale)) }
        if let out = wayOutText(alert) { parts.append(out) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Where things are

/// How high the block is and where its parts are, top to bottom, in the
/// block's own points. Sizes are `ControlRoomLook.Quota`'s; this is only the
/// adding up.
struct ControlRoomQuotaLayout: Equatable {
    typealias Look = ControlRoomLook

    /// One opened-out account: the whole of it, and how high it is.
    struct Part: Equatable {
        var y: CGFloat
        var height: CGFloat
        /// Whether the way out is written under the bar.
        var note: Bool
    }

    var parts: [Part]
    /// The one line; nil when there is none.
    var lineY: CGFloat?
    var height: CGFloat

    /// The hairline that closes the list above, and the space under it.
    static var separatorHeight: CGFloat {
        CGFloat(Look.Line.hairline) + CGFloat(Look.Quota.separatorSpaceBelow)
    }

    static func partHeight(note: Bool) -> CGFloat {
        let q = Look.Quota.self
        var h = q.alertPaddingTop + q.alertTitleHeight + q.barSpaceAbove + q.barHeight + q.barSpaceBelow
        if note { h += q.noteLineHeight + q.notePaddingBottom }
        return CGFloat(h + q.alertPaddingBottom)
    }

    init(quota: ControlRoomQuota) {
        var y = Self.separatorHeight
        var parts: [Part] = []
        for alert in quota.alerts {
            // The core says whether there is a way out; nothing is
            // compared to find one.
            let note = alert.way_out != nil
            let h = Self.partHeight(note: note)
            parts.append(Part(y: y, height: h, note: note))
            y += h
        }
        self.parts = parts
        if quota.line != nil {
            lineY = y
            y += CGFloat(Look.Quota.lineHeight)
        } else {
            lineY = nil
        }
        height = y + CGFloat(Look.Quota.paddingBottom)
    }
}

// MARK: - Made-up data

extension ControlRoomQuota {
    /// The design's eight states (v19, `Q3-04-states.png`), with made-up
    /// numbers, for still pictures and tests. None of it is anybody's
    /// account.
    enum Sample {
        /// 2023-11-14 12:00 UTC.
        static let now: UInt64 = 1_699_963_200_000
        static let minute: UInt64 = 60_000
        static let hour: UInt64 = 60 * minute
        static let day: UInt64 = 24 * hour

        static func windows(_ short: Int, _ long: Int?) -> [Window] {
            var out = [Window(span: .fiveHour, used: short, live: true, resets_ms: now + 100 * minute)]
            if let long { out.append(Window(span: .sevenDay, used: long, live: true, resets_ms: now + 3 * day)) }
            return out
        }

        static func entry(_ family: Family, _ used: Int, long: Int? = nil) -> Entry {
            Entry(family: family, state: .fresh, used: used, span: .fiveHour, stale: nil,
                  at_ms: now - 2 * minute, windows: windows(used, long))
        }

        static let ordinary = ControlRoomQuota(
            alerts: [],
            line: Line(label: .used, entries: [entry(.claude, 61, long: 12), entry(.codex, 20, long: 9)]))

        static let near = ControlRoomQuota(
            alerts: [Alert(family: .claude, level: .near, span: .fiveHour, used: 92,
                           resets_ms: now + 40 * minute, when: When(form: .minutes, n: 40), stale: nil,
                           way_out: nil, at_ms: now - minute, windows: windows(92, 30))],
            line: Line(label: .used, entries: [entry(.codex, 20)]))

        static let outWithRoom = ControlRoomQuota(
            alerts: [Alert(family: .claude, level: .out, span: .fiveHour, used: 100,
                           resets_ms: now + 100 * minute, when: When(form: .clock, n: 0), stale: nil,
                           way_out: .codex, at_ms: now - minute, windows: windows(100, 64))],
            line: Line(label: .used, entries: [entry(.codex, 20)]))

        static let outBothHigh = ControlRoomQuota(
            alerts: [
                Alert(family: .claude, level: .out, span: .fiveHour, used: 100,
                      resets_ms: now + 100 * minute, when: When(form: .clock, n: 0), stale: nil,
                      way_out: nil, at_ms: now - minute, windows: windows(100, 64)),
                Alert(family: .codex, level: .near, span: .sevenDay, used: 85,
                      resets_ms: now + 3 * day, when: When(form: .days, n: 3), stale: nil,
                      way_out: nil, at_ms: now - minute, windows: windows(40, 85)),
            ],
            line: nil)

        static let stale = ControlRoomQuota(
            alerts: [],
            line: Line(label: .used, entries: [
                entry(.claude, 61, long: 12),
                Entry(family: .codex, state: .stale, used: 20, span: .sevenDay,
                      stale: Ago(unit: .hours, n: 3), at_ms: now - 3 * hour,
                      windows: [Window(span: .sevenDay, used: 20, live: true, resets_ms: now + 3 * day)]),
            ]))

        static let recovered = ControlRoomQuota(
            alerts: [],
            line: Line(label: .used, entries: [
                entry(.claude, 61, long: 12),
                Entry(family: .codex, state: .recovered, used: nil, span: nil, stale: nil, at_ms: now - 2 * day,
                      windows: [Window(span: .fiveHour, used: 97, live: false, resets_ms: now - day)]),
            ]))

        static let unreadable = ControlRoomQuota(
            alerts: [],
            line: Line(label: .used, entries: [
                entry(.claude, 61, long: 12),
                Entry(family: .codex, state: .unreadable, used: nil, span: nil, stale: nil, at_ms: nil, windows: []),
            ]))

        static let noneYet = ControlRoomQuota(alerts: [], line: Line(label: .noneYet, entries: []))

        /// In the order the task lists them.
        static let all: [(name: String, quota: ControlRoomQuota)] = [
            ("1-ordinary", ordinary),
            ("2-near", near),
            ("3-out-with-room", outWithRoom),
            ("4-out-both-high", outBothHigh),
            ("5-stale", stale),
            ("6-recovered", recovered),
            ("7-unreadable", unreadable),
            ("8-none-yet", noneYet),
        ]
    }
}
