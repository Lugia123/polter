import Testing
@testable import Ghostty

/// «Copy Terminal ID» (task 1643). The same cases as the Windows host's
/// `terminal_id.rs` tests.
struct TerminalIDCopyTests {
    private typealias Copy = TerminalIDCopy
    private typealias Entry = TerminalIDCopy.Entry

    @Test func theIdIsWrittenTheWayTerminalListWritesIt() {
        // Sixteen lower-case digits, leading zeros kept: the tools match the
        // whole string.
        #expect(Copy.text(0x2d546c530d49f5e1) == "0x2d546c530d49f5e1")
        #expect(Copy.text(0xab) == "0x00000000000000ab")
    }

    @Test func zeroNamesNoTerminalAndIsNeverOffered() {
        #expect(!Copy.known(0))
        #expect(Copy.known(1))
        #expect(Copy.offer([Entry(id: 0, title: "x")]) == nil)
        #expect(Copy.offer([]) == nil)
    }

    @Test func oneTerminalIsCopiedStraightAndSeveralGetARowEach() {
        let a = Entry(id: 1, title: "a")
        let b = Entry(id: 2, title: "b")
        #expect(Copy.offer([a]) == .single(a))
        #expect(Copy.offer([a, b]) == .each([a, b]))
        // One with no id beside one with: the one there is.
        #expect(Copy.offer([Entry(id: 0, title: "gone"), b]) == .single(b))
    }

    @Test func aRowIsTheTitleThenTheIdOnOneLine() {
        #expect(Copy.rowLabel(Entry(id: 0x1f, title: "zsh")) == "zsh — 0x000000000000001f")
        #expect(Copy.rowLabel(Entry(id: 0x1f, title: "a\nb ")) == "a b — 0x000000000000001f")
        #expect(Copy.rowLabel(Entry(id: 0x1f, title: "  ")) == "0x000000000000001f")
    }

    @Test func aLongTitleIsCutInTheRowButNotInCopyAll() {
        let long = String(repeating: "x", count: 50)
        let e = Entry(id: 7, title: long)
        #expect(Copy.rowLabel(e) == String(repeating: "x", count: Copy.titleLimit) + "… — 0x0000000000000007")
        #expect(Copy.allText([e]) == long + " — 0x0000000000000007")
    }

    @Test func copyAllIsOneLinePerTerminalInOrder() {
        let text = Copy.allText([Entry(id: 2, title: "b"), Entry(id: 1, title: "a")])
        #expect(text == "b — 0x0000000000000002\na — 0x0000000000000001")
    }
}
