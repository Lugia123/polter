import Testing
@testable import Ghostty

/// Covers `GeneralRules`: the General section's groups, where a route lands
/// in them, and what About lists (settings.md §7).
struct GeneralRulesTests {
    /// §7.1's table, in its order: the five form groups, All Options, then
    /// the three that need no form.
    @Test func theGroupsAreTheSpecsInItsOrder() {
        #expect(GeneralGroup.allCases.map(\.rawValue) == [
            "appearance", "font", "terminal", "windows", "polter", "all", "keybinds", "advanced", "about",
        ])
    }

    @Test func onlyTheFormGroupsWaitForTheCoresTable() {
        #expect(GeneralGroup.allCases.filter(\.needsForm) == [.appearance, .font, .terminal, .windows, .polter, .all])
    }

    @Test func aRouteLandsOnTheGroupItNames() {
        #expect(GeneralRules.groupToSelect(item: "keybinds", fresh: true, current: .about) == .keybinds)
        #expect(GeneralRules.groupToSelect(item: "about", fresh: false, current: .font) == .about)
    }

    @Test func withNoneNamedANewWindowTakesTheFirstAndAnOpenOneStays() {
        #expect(GeneralRules.groupToSelect(item: nil, fresh: true, current: .advanced) == .appearance)
        #expect(GeneralRules.groupToSelect(item: nil, fresh: false, current: .advanced) == .advanced)
        #expect(GeneralRules.groupToSelect(item: "no such group", fresh: false, current: .advanced) == .advanced)
    }

    @Test func aboutListsVersionBuildAndCommitInThatOrder() {
        #expect(GeneralRules.aboutRows(version: "0.9.3", build: "412", commit: "1f9d4de14") == [
            .init(label: .version, value: "0.9.3"),
            .init(label: .build, value: "412"),
            .init(label: .commit, value: "1f9d4de14"),
        ])
    }

    /// A blank commit would read as "this build has no commit".
    @Test func aboutLeavesOutWhatTheBundleDoesNotSay() {
        #expect(GeneralRules.aboutRows(version: "0.9.3", build: nil, commit: "  ") == [
            .init(label: .version, value: "0.9.3"),
        ])
    }

    /// At the window's minimum the page is 418 wide (386 inside its margins):
    /// the note goes under the keys. At the first-open size (698) it has a
    /// column. The edge is name + keys + two gaps + 160 for the note.
    @Test func theNoteGoesUnderTheKeysOnlyWhenItWouldBeSqueezed() {
        #expect(GeneralRules.keybindNoteBelow(contentWidth: 386))
        #expect(!GeneralRules.keybindNoteBelow(contentWidth: 666))
        #expect(!GeneralRules.keybindNoteBelow(contentWidth: 564))
        #expect(GeneralRules.keybindNoteBelow(contentWidth: 563))
    }
}
