import AppKit
import CoreText
import OSLog

/// The one font annotations are written in: the Noto Sans SC Regular that
/// ships with the app (`dev-docs/poltergeist/screenshot.md`, 9.1).
///
/// It is read from its file, not looked up by name: a font of the same name
/// that the user installed is not the pinned one, and the two hosts are
/// meant to draw the same glyphs.
///
/// **A missing file is said out loud** -- a line in the log here, and a line
/// on the toolbar from `isAvailable` -- because text quietly drawn in the
/// system font is a screenshot that looks different on the other platform
/// with nothing to say why. A character the file has no glyph for is
/// another matter: Core Text finds it elsewhere, one character at a time,
/// and that is ordinary.
enum ShotFont {
    static let fileName = "NotoSansSC-Regular.otf"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: "ShotFont"
    )

    /// Where the font is inside the resources of an app bundle.
    static func url(resources: URL?) -> URL? {
        resources?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("polter", isDirectory: true)
            .appendingPathComponent("fonts", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The font's description, read from the file once.
    private static let descriptor: CTFontDescriptor? = {
        guard let url = url(resources: Bundle.main.resourceURL) else {
            logger.error("screenshot: the app has no resources directory, so no annotation font; the system font is used")
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("screenshot: the annotation font is missing at \(url.path, privacy: .public); the system font is used")
            return nil
        }
        guard let all = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = all.first else {
            logger.error("screenshot: the annotation font at \(url.path, privacy: .public) could not be read; the system font is used")
            return nil
        }
        logger.info("screenshot: annotation font loaded from \(url.path, privacy: .public)")
        return first
    }()

    /// Whether annotations are drawn in the bundled font. False is shown on
    /// the toolbar.
    static var isAvailable: Bool { descriptor != nil }

    /// The font at `size`, in whatever unit the caller draws in: pixels for
    /// the picture, points for the text box.
    static func font(size: CGFloat) -> CTFont {
        if let descriptor { return CTFontCreateWithFontDescriptor(descriptor, size, nil) }
        return CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// The distance from one line's top to the next one's, in whole units.
    static func lineHeight(of font: CTFont) -> Int {
        Int((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up))
    }

    /// `text` as one line in `font` and `colour`.
    static func line(_ text: String, font: CTFont, colour: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}

/// How text measures in the annotation font: what `ShotEditor` asks when a
/// piece of text is committed or its size changes.
struct ShotTextMeasure: TextMeasure {
    func size(of text: String, fontPx: Int) -> Annotation.PixelSize {
        let font = ShotFont.font(size: CGFloat(fontPx))
        let lines = text.components(separatedBy: "\n")
        let black = CGColor(gray: 0, alpha: 1)
        let widest = lines.map { line -> Double in
            CTLineGetTypographicBounds(ShotFont.line(line, font: font, colour: black), nil, nil, nil)
        }.max() ?? 0
        return .init(Int(widest.rounded(.up)), lines.count * ShotFont.lineHeight(of: font))
    }
}
