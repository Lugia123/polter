import Testing
import AppKit
@testable import Ghostty

/// Issue #22: "Save as a Project Before Closing?" killed the tab on every
/// answer but "Save" -- and offered no other answer -- and closed it even
/// when the save it was waiting for failed.
@Suite
struct ProjectSaveBeforeCloseTests {
    private typealias Prompt = ProjectSaveBeforeClose

    private func response(_ index: Int) -> NSApplication.ModalResponse {
        .init(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    @MainActor
    @Test func theAlertHasAWayOutAndOnlyOneButtonCloses() {
        let alert = Prompt.makeAlert()
        let meanings = alert.buttons.indices.map { Prompt.choice(for: response($0)) }
        #expect(meanings == [.save, .closeWithoutSaving, .keepOpen])
        #expect(meanings.filter { $0 == .closeWithoutSaving }.count == 1)
    }

    /// NSAlert binds Esc by itself only to a button titled "Cancel" in
    /// English. Under a translated title it would bind nothing, so this
    /// builds the alert with the Chinese titles -- in English the explicit
    /// binding is redundant and a test couldn't tell it was missing.
    @MainActor
    @Test func escKeepsTheTabOpenUnderATranslatedTitle() throws {
        let titles: [ProjectSaveBeforeClose.Choice: String] = [.save: "存成项目…", .closeWithoutSaving: "不保存直接关闭", .keepOpen: "取消"]
        let alert = Prompt.makeAlert { titles[$0] ?? "" }
        let escape = alert.buttons.indices.filter { alert.buttons[$0].keyEquivalent == "\u{1b}" }
        #expect(escape.count == 1)
        let index = try #require(escape.first)
        #expect(Prompt.choice(for: response(index)) == .keepOpen)
    }

    /// Anything that isn't a button -- the sheet ended some other way --
    /// keeps the tab open. Closing kills processes, so it is never a default.
    @Test func responsesThatAreNotButtonsKeepTheTabOpen() {
        for other in [NSApplication.ModalResponse.abort, .stop, .cancel, .OK, response(3)] {
            #expect(Prompt.choice(for: other) == .keepOpen)
        }
    }

    /// The floor for the second half of #22: make the save *fail*. A test
    /// that only saved successfully and checked the tab closed would pass
    /// with the bug in place.
    @Test func aFailedSaveKeepsTheTabOpenAndSaysWhy() {
        struct DiskFull: Error {}
        var closed = false
        var reported: Error?
        Prompt.saveThenClose(save: { throw DiskFull() }, reportFailure: { reported = $0 }, close: { closed = true })
        #expect(!closed)
        #expect(reported is DiskFull)

        Prompt.saveThenClose(save: {}, reportFailure: { reported = $0 }, close: { closed = true })
        #expect(closed)
    }
}
