import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Settings > General > Log Management (task 1511): what the core says is
/// read as it says it, a field writes only what the config takes, and no
/// confirmation names a tool.
struct LogManagementRulesTests {
    private let json = #"""
    {"state_dir":"/s","total_bytes":15,"waiting_bytes":7,"kinds":[
     {"key":"group_transcripts","kept":"cycle","bytes":10,"files":1,"days_key":null,"mb_key":"poltergeist-terminal-log-group-max-mb","fixed_days":null,"action":"clear"},
     {"key":"rename_backups","kept":"fixed","bytes":0,"files":0,"days_key":null,"mb_key":null,"fixed_days":7,"action":"clear"},
     {"key":"tasks","kept":"forever","bytes":5,"files":2,"days_key":null,"mb_key":null,"fixed_days":null,"action":"compact"}]}
    """#

    @Test func theCoresFiguresAreReadAsTheCoreWritesThem() throws {
        let usage = try #require(StorageUsage.parse(json))
        #expect(usage.stateDir == "/s")
        #expect(usage.totalBytes == 15)
        #expect(usage.waitingBytes == 7)
        #expect(usage.kinds[0].mbKey == "poltergeist-terminal-log-group-max-mb")
        #expect(usage.kinds[0].daysKey == nil)
        #expect(usage.kinds[1].fixedDays == 7)
        #expect(usage.kinds[2].action == "compact")
    }

    @Test func nothingWaitingIsNil() throws {
        let usage = try #require(StorageUsage.parse(json.replacingOccurrences(of: "\"waiting_bytes\":7", with: "\"waiting_bytes\":null")))
        #expect(usage.waitingBytes == nil)
    }

    @Test func fixedAndCycleGoRoundAndForeverDoesNot() throws {
        let usage = try #require(StorageUsage.parse(json))
        let sections = LogManagementRules.sections(usage)
        #expect(sections.cycle.map(\.key) == ["group_transcripts", "rename_backups"])
        #expect(sections.forever.map(\.key) == ["tasks"])
    }

    @Test func aFieldWritesANumberOrUnlimitedAndNothingElse() {
        #expect(LogManagementRules.valueToWrite("30") == "30")
        #expect(LogManagementRules.valueToWrite(" 512 ") == "512")
        #expect(LogManagementRules.valueToWrite("") == "unlimited")
        #expect(LogManagementRules.valueToWrite("unlimited") == "unlimited")
        #expect(LogManagementRules.valueToWrite(LogManagementRules.noLimit) == "unlimited")
        #expect(LogManagementRules.valueToWrite("-1") == nil)
        #expect(LogManagementRules.valueToWrite("1.5") == nil)
        #expect(LogManagementRules.valueToWrite("thirty") == nil)
    }

    @Test func unlimitedIsShownInWords() {
        #expect(LogManagementRules.fieldText("unlimited") == LogManagementRules.noLimit)
        #expect(LogManagementRules.fieldText("14") == "14")
    }

    @Test func tasksAreCompactedAndTheRestCleared() throws {
        let usage = try #require(StorageUsage.parse(json))
        #expect(LogManagementRules.confirmation(usage.kinds[2]).button != LogManagementRules.confirmation(usage.kinds[0]).button)
        #expect(LogManagementRules.action(usage.kinds[2]) != LogManagementRules.action(usage.kinds[0]))
    }

    /// The user (2026-10-15): no tool names or inner words in what a person
    /// reads before deleting something.
    @Test func noConfirmationNamesATool() {
        let keys = ["group_transcripts", "project_transcripts", "other_transcripts", "logs", "shots",
                    "rename_backups", "chat", "tasks", "history", "archive"]
        for key in keys {
            let kind = StorageUsage.Kind(key: key, kept: "cycle", bytes: 1024, files: 3, daysKey: nil, mbKey: nil,
                                         fixedDays: nil, action: key == "tasks" ? "compact" : "clear")
            let c = LogManagementRules.confirmation(kind)
            let text = ([c.title] + c.lines).joined(separator: " ")
            for word in ["record_", "task_history", "group_history", "log_list", "log_read", "_transcripts", "retention"] {
                #expect(!text.contains(word), "\(key): \(word)")
            }
            #expect(c.lines.count >= 2, "\(key)")
            #expect(LogManagementRules.title(key) != key, "\(key) has a name")
        }
    }

    // The tenth run, D5: the formatter's own "Zero KB" in a column of figures.
    @Test func nothingIsANumberNotAWord() {
        let zero = LogManagementRules.size(0)
        #expect(zero.first?.isNumber == true, "\(zero)")
        #expect(LogManagementRules.size(2048).first?.isNumber == true)
    }

    // The tenth run, D4: the confirmation said "at most 17 bytes" and 33 went.
    @Test func theConfirmationIsOfTheFiguresReadWhenItIsAsked() throws {
        let shown = try #require(StorageUsage.parse(json)).kinds[0]
        let later = try #require(StorageUsage.parse(json.replacingOccurrences(of: "\"bytes\":10,\"files\":1", with: "\"bytes\":33,\"files\":4")))
        let now = try #require(LogManagementRules.current(shown, in: later))
        #expect(now.bytes == 33)
        #expect(now.files == 4)
        #expect(LogManagementRules.confirmation(now) != LogManagementRules.confirmation(shown))
        // Gone since the page was drawn: nothing to ask about.
        let gone = try #require(StorageUsage.parse(json.replacingOccurrences(of: "\"key\":\"group_transcripts\"", with: "\"key\":\"x\"")))
        #expect(LogManagementRules.current(shown, in: gone) == nil)
        #expect(LogManagementRules.current(shown, in: nil) == nil)
    }

    // Return answers Cancel, in the person's language as much as in English:
    // NSAlert's own binding goes by the title "Cancel", and 取消 is not it.
    @MainActor @Test func returnCancelsAndDeletesNothing() throws {
        let usage = try #require(StorageUsage.parse(json))
        for cancel in ["Cancel", "取消"] {
            let alert = LogManagementAlert.make(LogManagementRules.confirmation(usage.kinds[0]), cancel: cancel)
            #expect(alert.buttons.count == 2)
            #expect(alert.buttons[0].hasDestructiveAction)
            #expect(alert.buttons[0].keyEquivalent == "", "\(cancel): the deleting button answers Return")
            #expect(alert.buttons[1].title == cancel)
            #expect(alert.buttons[1].keyEquivalent == "\r", "\(cancel): Cancel does not answer Return")
        }
    }

    // Esc is Cancel too (task 1551) -- answered by `run`, since Cancel's one
    // key equivalent is Return. Esc alone; not with a modifier.
    @Test func escapeIsAnsweredAndOnlyBare() {
        #expect(LogManagementAlert.isEscape(keyCode: 53, flags: []))
        #expect(!LogManagementAlert.isEscape(keyCode: 53, flags: [.command]))
        #expect(!LogManagementAlert.isEscape(keyCode: 53, flags: [.option]))
        #expect(!LogManagementAlert.isEscape(keyCode: 36, flags: []))
    }

    /// Task 1604: at the settings window's least width, 900, a row is 388
    /// wide and the controls take 372 of it. The name was given 16 and drawn
    /// a character to a line; now the row stacks, as the Windows page does
    /// (`logs.rs`, `TEXT_MIN_W` 200), and both hosts stack at the same width.
    @Test func aRowTooNarrowForItsNameIsStackedAtTheWindowsWidth() {
        #expect(LogManagementColumns.textWidth(rowWidth: 388) == 16)
        #expect(LogManagementColumns.stacks(rowWidth: 388))
        #expect(LogManagementColumns.stacks(rowWidth: 571))
        #expect(!LogManagementColumns.stacks(rowWidth: 572))
        // 1180, the window's first size: beside, as before.
        #expect(!LogManagementColumns.stacks(rowWidth: 668))
    }
}
