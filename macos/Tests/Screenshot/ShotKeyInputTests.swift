import Foundation
import Testing
@testable import Ghostty

/// What AppKit's key events are taken for
/// (`dev-docs/poltergeist/screenshot.md`, 9.2).
struct ShotKeyInputTests {
    private func input(_ keyCode: UInt16, _ characters: String?) -> EditorKey.Input {
        .of(keyCode: keyCode, characters: characters)
    }

    @Test func theKeysWithNoCharacterGoByPosition() {
        #expect(input(53, "\u{1b}") == .escape)
        #expect(input(36, "\r") == .enter)
        #expect(input(76, "\u{3}") == .enter, "the number pad's Enter")
        #expect(input(51, "\u{7f}") == .delete)
        #expect(input(117, "\u{f728}") == .delete, "forward delete")
        #expect(input(123, "\u{f702}") == .left)
        #expect(input(124, "\u{f703}") == .right)
        #expect(input(125, "\u{f701}") == .down)
        #expect(input(126, "\u{f700}") == .up)
    }

    @Test func aKeyIsWhatItTypes() {
        #expect(input(15, "r") == .letter("r"))
        #expect(input(15, "R") == .letter("R"), "with Shift")
        #expect(input(33, "[") == .bracketLeft)
        #expect(input(30, "]") == .bracketRight)
        #expect(input(18, "1") == .digit(1))
        #expect(input(29, "0") == .digit(0))
        #expect(input(87, "5") == .digit(5), "the number pad")
        // On Dvorak the key in the O position types R: it is the rectangle
        // tool, not the ellipse.
        #expect(input(31, "r") == .letter("r"))
        #expect(input(47, ".") == .other)
        #expect(input(49, " ") == .other)
    }

    @Test func aKeyThatTypesNoLatinGoesByItsPosition() {
        // A Russian layout: the R key types к.
        #expect(input(15, "к") == .letter("r"))
        #expect(input(6, "я") == .letter("z"))
        #expect(input(9, "м") == .letter("v"))
        #expect(input(33, "х") == .bracketLeft)
        #expect(input(30, "ъ") == .bracketRight)
        // Shift on the digit row types a symbol; the key is still the digit.
        #expect(input(18, "!") == .digit(1))
        #expect(input(25, "(") == .digit(9))
        #expect(input(91, nil) == .digit(8), "number pad 8 with nothing reported")
        #expect(input(15, nil) == .letter("r"))
        #expect(input(15, "") == .letter("r"))
        #expect(input(200, "к") == .other)
        #expect(input(200, nil) == .other)
    }

    @Test func everyDigitIsWhereAnAnsiKeyboardHasIt() {
        let row: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        let pad: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for digit in 0...9 {
            #expect(input(row[digit], "§") == .digit(digit), "top row \(digit)")
            #expect(input(pad[digit], nil) == .digit(digit), "number pad \(digit)")
        }
    }

    @Test func everyToolIsReachableByItsPosition() {
        let positions: [(UInt16, AnnotationTool)] = [
            (9, .select), (15, .rect), (31, .ellipse), (37, .line), (0, .arrow),
            (35, .pen), (4, .highlighter), (17, .text), (45, .number), (46, .mosaic),
        ]
        for (keyCode, tool) in positions {
            #expect(EditorKey.of(input(keyCode, "ж"), mods: [], hasSelection: true) == .tool(tool), "\(tool)")
        }
        #expect(EditorKey.of(input(6, "я"), mods: [.command], hasSelection: true) == .undo)
    }
}
