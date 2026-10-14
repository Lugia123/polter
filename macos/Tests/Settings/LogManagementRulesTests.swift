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
}
