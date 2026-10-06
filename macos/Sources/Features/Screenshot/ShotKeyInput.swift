import Foundation

extension EditorKey.Input {
    /// A key as AppKit reports it: its position (`keyCode`) and what it
    /// types with no modifier but Shift (`charactersIgnoringModifiers`).
    ///
    /// The keys with no character -- Esc, Enter, Delete, the arrows -- go by
    /// position. A key that types an ASCII letter, digit or bracket is that,
    /// whatever the layout: on Dvorak the rectangle tool is the key that
    /// types R. A key that types none of those (a Cyrillic or Greek layout,
    /// or Shift on the digit row) falls back to where it is on an ANSI
    /// keyboard, so the tools can still be reached without switching
    /// layouts.
    static func of(keyCode: UInt16, characters: String?) -> EditorKey.Input {
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51, 117: return .delete
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }
        if let characters, characters.count == 1, let c = characters.first, c.isASCII {
            if c == "[" { return .bracketLeft }
            if c == "]" { return .bracketRight }
            if let digit = c.wholeNumberValue { return .digit(digit) }
            if c.isLetter { return .letter(c) }
        }
        if keyCode == 33 { return .bracketLeft }
        if keyCode == 30 { return .bracketRight }
        if let digit = digitAt[keyCode] { return .digit(digit) }
        if let letter = letterAt[keyCode] { return .letter(letter) }
        return .other
    }

    /// The digit keys by position: the top row, then the number pad.
    private static let digitAt: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// The letter keys by position on an ANSI keyboard.
    private static let letterAt: [UInt16: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
        40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s",
        17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]
}
