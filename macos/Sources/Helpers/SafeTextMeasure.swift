import AppKit
import OSLog

/// How big a text is set in a font, measured where an exception from the
/// text system cannot take the app down.
///
/// A measurement for the control room's list once threw an
/// `NSInvalidArgumentException` from inside CoreText, on the main thread in
/// the middle of a SwiftUI layout, and the app aborted (task 1718). An
/// Objective-C exception cannot be caught in Swift, so every measurement goes
/// through `GhosttyMeasureTextSafely`, which catches it; when it does, the
/// size is guessed from the number of characters (`estimate`) and the
/// failure is logged. A guess makes a name cut a little early or late on one
/// render; an abort loses every terminal.
enum SafeTextMeasure {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: "SafeTextMeasure"
    )

    /// How wide `text` is in `font` on one line.
    static func width(_ text: String, font: NSFont) -> CGFloat {
        size(NSAttributedString(string: text, attributes: [.font: font])).width
    }

    /// How wide `text` is on one line, in the fonts it carries.
    static func width(_ text: NSAttributedString) -> CGFloat {
        size(text).width
    }

    /// How high `text` is in `font` when it wraps at `width`.
    static func height(_ text: String, font: NSFont, wrappingAt width: CGFloat) -> CGFloat {
        size(NSAttributedString(string: text, attributes: [.font: font]), wrappingAt: width).height
    }

    /// The size of `text`: wrapped at `wrappingAt` when it is given, on one
    /// line otherwise. `failForTesting` makes the measurement throw the
    /// exception of task 1718 inside the guard.
    static func size(_ text: NSAttributedString, wrappingAt: CGFloat? = nil,
                     failForTesting: Bool = false) -> CGSize {
        switch measure(text, wrappingAt: wrappingAt, failForTesting: failForTesting) {
        case .success(let size):
            return size
        case .failure(let error):
            let guess = estimate(text, wrappingAt: wrappingAt)
            logger.error("measuring \(text.length) characters threw: \(error.localizedDescription, privacy: .public); guessed \(guess.width)x\(guess.height)")
            return guess
        }
    }

    /// The text system's own measurement, or the exception it threw.
    static func measure(_ text: NSAttributedString, wrappingAt: CGFloat? = nil,
                        failForTesting: Bool = false) -> Result<CGSize, NSError> {
        var measured = CGSize.zero
        var error: NSError?
        if GhosttyMeasureTextSafely(text, wrappingAt ?? 0, failForTesting, &measured, &error) {
            return .success(measured)
        }
        return .failure(error ?? NSError(domain: "Ghostty.ObjCException", code: 3))
    }

    /// A size made up from the characters alone, touching no layout: an
    /// em for a wide character (CJK, emoji), six tenths of one for the
    /// rest -- what SF Mono advances, and at least what the system face
    /// does for most Latin text.
    static func estimate(_ text: NSAttributedString, wrappingAt: CGFloat? = nil) -> CGSize {
        let string = text.string
        let font = text.length > 0
            ? (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            : nil
        let em = font?.pointSize ?? NSFont.systemFontSize
        let lineHeight = ceil((font?.ascender ?? em) - (font?.descender ?? 0) + (font?.leading ?? 0))
        var lines: [CGFloat] = [0]
        for character in string {
            if character.isNewline {
                lines.append(0)
                continue
            }
            lines[lines.count - 1] += (isWide(character) ? 1.0 : 0.6) * em
        }
        guard let wrap = wrappingAt, wrap > 0 else {
            return CGSize(width: lines.max() ?? 0, height: lineHeight * CGFloat(lines.count))
        }
        let count = lines.reduce(0) { $0 + max(1, ceil($1 / wrap)) }
        return CGSize(width: min(wrap, lines.max() ?? 0), height: lineHeight * count)
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
