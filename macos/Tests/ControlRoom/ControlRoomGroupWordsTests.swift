import Foundation
import Testing
@testable import Ghostty

/// What the group row's menu and what it opens say (task 1660).
struct ControlRoomGroupWordsTests {
    private typealias Words = ControlRoomGroupWords

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private let zh = Locale(identifier: "zh_Hans_CN")

    // MARK: Muting

    @Test func anHourIsAnHourAndTomorrowIsNineTheNextDay() {
        let now = at(2026, 10, 16, 14, 40)
        #expect(Words.muteEnd(.hour, now: now, calendar: calendar) == at(2026, 10, 16, 15, 40))
        #expect(Words.muteEnd(.tomorrow, now: now, calendar: calendar) == at(2026, 10, 17, 9, 0))
        #expect(Words.muteEnd(.forever, now: now, calendar: calendar) == nil)
    }

    /// Before nine in the morning, "tomorrow" is still the next day's nine,
    /// not this morning's.
    @Test func tomorrowIsTheNextDayEvenBeforeNine() {
        let now = at(2026, 10, 16, 7, 30)
        #expect(Words.muteEnd(.tomorrow, now: now, calendar: calendar) == at(2026, 10, 17, 9, 0))
    }

    @Test func anHourPastMidnightEndsTheNextDay() {
        let now = at(2026, 10, 16, 23, 30)
        #expect(Words.muteEnd(.hour, now: now, calendar: calendar) == at(2026, 10, 17, 0, 30))
    }

    @Test func eachLengthSaysWhenItEnds() {
        let now = at(2026, 10, 16, 14, 40)
        let hour = Words.muteEndText(.hour, now: now, calendar: calendar, locale: zh)
        let tomorrow = Words.muteEndText(.tomorrow, now: now, calendar: calendar, locale: zh)
        #expect(hour?.contains("15:40") == true)
        #expect(tomorrow?.contains("9:00") == true)
        #expect(Words.muteEndText(.forever, now: now, calendar: calendar, locale: zh) == nil)
    }

    @Test func unmuteSaysUntilWhenAsNearAsItIs() {
        let now = at(2026, 10, 16, 14, 40)
        let today = Words.mutedUntilText(at(2026, 10, 16, 15, 40), now: now, calendar: calendar, locale: zh)
        let tomorrow = Words.mutedUntilText(at(2026, 10, 17, 9, 0), now: now, calendar: calendar, locale: zh)
        let later = Words.mutedUntilText(at(2026, 10, 20, 9, 0), now: now, calendar: calendar, locale: zh)
        #expect(today?.contains("15:40") == true)
        #expect(today?.contains("tomorrow") == false)
        #expect(tomorrow?.contains("tomorrow") == true)
        #expect(tomorrow?.contains("9:00") == true)
        // A day further off names the day.
        #expect(later?.contains("20") == true)
        #expect(later?.contains("tomorrow") == false)
        // Muted for good: nothing at the right.
        #expect(Words.mutedUntilText(nil, now: now, calendar: calendar, locale: zh) == nil)
    }

    // MARK: The note

    @Test func aNoteCountsWhatThePersonSeesAsOneCharacter() {
        #expect(Words.noteCount("abc", changed: false) == "3 characters")
        #expect(Words.noteCount("群简介", changed: true) == "3 characters, not saved")
        // An emoji made of several scalars, and a letter with its accent.
        #expect(Words.noteCount("👩‍💻e\u{301}", changed: false) == "2 characters")
        #expect(Words.noteCount("", changed: false) == "0 characters")
    }

    // MARK: Archiving and deleting

    @Test func archivingARunningGroupSaysItsTerminalsStayOpen() {
        let quiet = Words.archiveQuestion(name: "web-app", supervisorRunning: false)
        let running = Words.archiveQuestion(name: "web-app", supervisorRunning: true)
        #expect(quiet.title == "Archive web-app?")
        #expect(!quiet.body.contains("still running"))
        #expect(running.body.contains("still running"))
        #expect(running.body.hasPrefix(quiet.body))
    }

    @Test func deletingAnEmptyGroupHasNoWarningAndNoWayOut() {
        let q = Words.deleteQuestion(name: "notes", project: "notes", still: .init(supervisor: false, workers: 0, openTasks: 0))
        #expect(q.title == "Delete the group notes?")
        #expect(q.warning == nil)
        #expect(q.aside?.contains("The project notes stays") == true)
        #expect(q.aside?.contains("archive it instead") == false)
    }

    @Test func deletingAGroupWithPeopleAndWorkSaysHowManyAndOffersArchiving() {
        let q = Words.deleteQuestion(name: "web-app", project: "web-app", still: .init(supervisor: true, workers: 2, openTasks: 4))
        #expect(q.warning?.contains("3 members (the supervisor and 2 workers)") == true)
        #expect(q.warning?.contains("4 unfinished tasks") == true)
        #expect(q.aside?.hasSuffix("To keep everything, archive it instead.") == true)
    }

    @Test func theWarningNamesOnlyWhatIsThere() {
        let workersOnly = Words.warning(.init(supervisor: false, workers: 2, openTasks: 0))
        let tasksOnly = Words.warning(.init(supervisor: false, workers: 0, openTasks: 1))
        // Who is still there is the one clause after "still has".
        #expect(workersOnly?.hasPrefix("This group still has 2 workers. ") == true)
        #expect(tasksOnly?.hasPrefix("This group still has 1 unfinished tasks. ") == true)
        #expect(Words.warning(.init(supervisor: false, workers: 0, openTasks: 0)) == nil)
    }

    @Test func aGroupWithNoProjectSaysNothingAboutOne() {
        let q = Words.deleteQuestion(name: "x", project: nil, still: .init(supervisor: false, workers: 0, openTasks: 0))
        #expect(q.aside == nil)
    }

    // MARK: Archived

    @Test func theArchivedHeaderCountsAndEachRowSaysItsDay() {
        #expect(Words.archivedHeader(3) == "Archived (3)")
        let day = Words.archivedOn(UInt64(at(2026, 10, 12, 18, 0).timeIntervalSince1970 * 1000), calendar: calendar, locale: zh)
        #expect(day.contains("10"))
        #expect(day.contains("12"))
        #expect(day.hasPrefix("archived "))
    }

    /// The day is the person's: a group put away at 1:00 in Shanghai on the
    /// 13th is the 13th there, though it is the 12th in UTC.
    @Test func theArchivedDayIsTheLocalOne() {
        let ms = UInt64(at(2026, 10, 13, 1, 0).timeIntervalSince1970 * 1000)
        #expect(Words.archivedOn(ms, calendar: calendar, locale: zh).contains("13"))
    }

    // MARK: Asking the supervisor

    /// It says what was asked, never what was done.
    @Test func theLineSaysAskedNotDone() {
        for ask in Words.Ask.allCases {
            #expect(Words.asked(ask).hasPrefix("Asked the supervisor"))
        }
        #expect(Words.notDelivered("there is unsent text in its input") == "Not delivered: there is unsent text in its input")
    }

    /// The two the core tries again by itself say so; the rest do not, and
    /// one with no short form is the core's own sentence.
    @Test func aReasonSaysWhetherItWillBeTriedAgain() {
        let again = ", will try again"
        #expect(Words.askReason("DraftInLine").hasSuffix(again))
        #expect(Words.askReason("UserPresent").hasSuffix(again))
        for final in ["NoAgent", "ChildExited", "NoSupervisor", "NoSuchGroup"] {
            #expect(!Words.askReason(final).hasSuffix(again), "\(final)")
        }
        #expect(Words.askReason("NoSuchGroup") == ControlRoomActions.Refusal(name: "NoSuchGroup").message)
    }
}
