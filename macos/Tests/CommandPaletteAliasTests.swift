import Testing
@testable import Ghostty

/// Task 1604: in a Chinese interface every command's title is translated,
/// and "split" found nothing. A command is found by its action too, in
/// English, and ranked below anything the person can read in the row.
struct CommandPaletteAliasTests {
    private func command(_ title: String, _ action: String) -> CommandOption {
        CommandOption(title: title, aliases: [CommandOption.actionAlias(action)]) {}
    }

    @Test func anActionIsWordsToSearchBy() {
        #expect(CommandOption.actionAlias("new_split:right") == "new split right")
        #expect(CommandOption.actionAlias("toggle_fullscreen") == "toggle fullscreen")
    }

    @Test func anEnglishQueryFindsATranslatedCommand() {
        let right = command("向右分屏", "new_split:right")
        let tab = command("新建标签页", "new_tab")
        #expect([right, tab].filteredAndSorted(query: "split") == [right])
        #expect([right, tab].filteredAndSorted(query: "分屏") == [right])
    }

    @Test func whatTheRowShowsOutranksAnAlias() {
        let byAlias = command("向右分屏", "new_split:right")
        let byTitle = CommandOption(title: "Split notes", aliases: ["zzz"]) {}
        #expect([byAlias, byTitle].filteredAndSorted(query: "split") == [byTitle, byAlias])
    }
}
