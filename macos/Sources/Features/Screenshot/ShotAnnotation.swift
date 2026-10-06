import CoreGraphics
import Foundation

/// One of the colours an annotation can be drawn in.
struct ShotColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let red = ShotColor(red: 1.0, green: 0.23, blue: 0.19)
    static let yellow = ShotColor(red: 1.0, green: 0.8, blue: 0.0)
    static let blue = ShotColor(red: 0.0, green: 0.48, blue: 1.0)
    static let white = ShotColor(red: 1.0, green: 1.0, blue: 1.0)

    /// The palette, in the order the toolbar shows it. The first is the
    /// default.
    static let palette: [ShotColor] = [.red, .yellow, .blue, .white]
}

/// Something drawn on a selection. Coordinates are the overlay's: points,
/// origin at the top left of the display, as `ShotGeometry` has them.
enum ShotAnnotation: Equatable {
    case rect(CGRect, color: ShotColor)
    case arrow(from: CGPoint, to: CGPoint, color: ShotColor)
    case pen([CGPoint], color: ShotColor)
    case text(at: CGPoint, String, color: ShotColor)
    case number(Int, at: CGPoint, text: String, color: ShotColor)
}

/// The annotations on one screenshot, in the order they were made.
struct ShotAnnotations: Equatable {
    private(set) var items: [ShotAnnotation] = []

    var isEmpty: Bool { items.isEmpty }

    /// The number the next numbered marker gets: one more than the highest
    /// there is. Undoing the last marker therefore gives its number back.
    var nextNumber: Int {
        let highest = items.compactMap { item -> Int? in
            if case let .number(n, _, _, _) = item { return n }
            return nil
        }.max() ?? 0
        return highest + 1
    }

    mutating func add(_ annotation: ShotAnnotation) {
        items.append(annotation)
    }

    /// Replace the last annotation, for one that is still being drawn or
    /// whose text is still being typed.
    mutating func replaceLast(with annotation: ShotAnnotation) {
        guard !items.isEmpty else { return }
        items[items.count - 1] = annotation
    }

    /// Take the last one back. False when there was nothing to take.
    @discardableResult
    mutating func undo() -> Bool {
        guard !items.isEmpty else { return false }
        items.removeLast()
        return true
    }
}

/// A screenshot's annotations as data: the `.json` written beside the image
/// and the one line of text pasted after its path
/// (`dev-docs/poltergeist/screenshot.md`, section 4).
enum ShotExport {
    /// An annotation in **image pixels**, origin at the image's top left --
    /// what both outputs are written in.
    enum Item: Equatable {
        case number(Int, x: Int, y: Int, text: String)
        case rect(x: Int, y: Int, width: Int, height: Int)
        case arrow(fromX: Int, fromY: Int, toX: Int, toY: Int)
        case text(x: Int, y: Int, text: String)
        case pen(x: Int, y: Int, width: Int, height: Int)
    }

    /// Where the selection came from.
    struct Source: Equatable {
        enum Kind: String { case window, region }
        var kind: Kind
        /// Only for a window, and only when they could be read.
        var app: String?
        var title: String?

        static let region = Source(kind: .region)
    }

    struct Metadata: Equatable {
        /// The image's file name, without a directory.
        var image: String
        var takenAt: Date
        var timeZone: TimeZone
        var pixelWidth: Int
        var pixelHeight: Int
        var scale: Double
        var source: Source
    }

    // MARK: Points to pixels

    /// The annotations in image pixels: each is moved so that the
    /// selection's origin is zero, then scaled.
    ///
    /// A text annotation with nothing typed in it, and a pen stroke that
    /// never moved, are not annotations and are left out.
    static func items(
        _ annotations: [ShotAnnotation],
        selectionOrigin origin: CGPoint,
        scale: CGFloat
    ) -> [Item] {
        func px(_ p: CGPoint) -> (x: Int, y: Int) {
            (Int(((p.x - origin.x) * scale).rounded()), Int(((p.y - origin.y) * scale).rounded()))
        }
        struct Box { var x: Int, y: Int, w: Int, h: Int }
        func box(_ r: CGRect) -> Box {
            let a = px(CGPoint(x: r.minX, y: r.minY))
            let b = px(CGPoint(x: r.maxX, y: r.maxY))
            return Box(x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y)
        }

        return annotations.compactMap { annotation in
            switch annotation {
            case let .rect(rect, _):
                let b = box(rect.standardized)
                return .rect(x: b.x, y: b.y, width: b.w, height: b.h)

            case let .arrow(from, to, _):
                let a = px(from), b = px(to)
                return .arrow(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y)

            case let .pen(points, _):
                guard points.count >= 2 else { return nil }
                let xs = points.map(\.x), ys = points.map(\.y)
                let b = box(CGRect(
                    x: xs.min()!, y: ys.min()!,
                    width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
                return .pen(x: b.x, y: b.y, width: b.w, height: b.h)

            case let .text(at, text, _):
                let text = oneLine(text)
                guard !text.isEmpty else { return nil }
                let p = px(at)
                return .text(x: p.x, y: p.y, text: text)

            case let .number(n, at, text, _):
                let p = px(at)
                return .number(n, x: p.x, y: p.y, text: oneLine(text))
            }
        }
    }

    /// What the person typed, on one line: every run of line breaks, tabs
    /// and other control characters becomes one space, and the ends are
    /// trimmed. The pasted line has to stay one line, and a tab in a
    /// terminal is a completion request.
    static func oneLine(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let isBreak = scalar.properties.generalCategory == .control
                || scalar == "\u{2028}" || scalar == "\u{2029}"
            if isBreak || scalar == " " {
                pendingSpace = true
                continue
            }
            if pendingSpace && !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    // MARK: The sidecar

    /// The `.json` beside the image. Keys in the order the specification
    /// lists them, one annotation to a line, so that two of these can be
    /// compared by eye.
    static func json(_ metadata: Metadata, items: [Item]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = metadata.timeZone

        var source = "{\"kind\": \(quote(metadata.source.kind.rawValue))"
        if metadata.source.kind == .window {
            // Absent when unknown, never an empty string.
            if let app = metadata.source.app, !app.isEmpty { source += ", \"app\": \(quote(app))" }
            if let title = metadata.source.title, !title.isEmpty { source += ", \"title\": \(quote(title))" }
        }
        source += "}"

        let annotations = items.map { item -> String in
            switch item {
            case let .number(n, x, y, text):
                return "{\"n\": \(n), \"type\": \"number\", \"at\": [\(x), \(y)], \"text\": \(quote(text))}"
            case let .rect(x, y, width, height):
                return "{\"type\": \"rect\", \"rect\": [\(x), \(y), \(width), \(height)], \"text\": \"\"}"
            case let .arrow(fromX, fromY, toX, toY):
                return "{\"type\": \"arrow\", \"from\": [\(fromX), \(fromY)], \"to\": [\(toX), \(toY)]}"
            case let .text(x, y, text):
                return "{\"type\": \"text\", \"at\": [\(x), \(y)], \"text\": \(quote(text))}"
            case let .pen(x, y, width, height):
                return "{\"type\": \"pen\", \"bbox\": [\(x), \(y), \(width), \(height)]}"
            }
        }

        var out = "{\n"
        out += "  \"version\": 1,\n"
        out += "  \"image\": \(quote(metadata.image)),\n"
        out += "  \"taken_at\": \(quote(formatter.string(from: metadata.takenAt))),\n"
        out += "  \"size\": [\(metadata.pixelWidth), \(metadata.pixelHeight)],\n"
        out += "  \"scale\": \(number(metadata.scale)),\n"
        out += "  \"source\": \(source),\n"
        if annotations.isEmpty {
            out += "  \"annotations\": []\n"
        } else {
            out += "  \"annotations\": [\n"
            out += annotations.map { "    " + $0 }.joined(separator: ",\n")
            out += "\n  ]\n"
        }
        out += "}\n"
        return out
    }

    /// A JSON number that always has a decimal point: `2.0`, not `2`.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "1.0" }
        if value == value.rounded() { return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return String(value)
    }

    /// A JSON string literal.
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: The line

    /// The words of the line, in the reader's language. The English ones are
    /// the msgids `src/input/screenshot.zig` names.
    struct Words: Equatable {
        var header: String
        var text: String
        var rect: String
        var arrow: String
        var pen: String
        var separator: String
        var see: String
    }

    /// The one line of text that follows the image's path into a terminal:
    ///
    ///     [Screenshot annotations 1280×800] ① (412,96) misaligned; Text
    ///     (60,500) too wide; Box (380,80,240,44). See /…/shot.json
    ///
    /// Nil when there are no annotations: then nothing is sent after the
    /// path. Shapes with no words are still sent -- where something was
    /// marked is itself what the person is saying.
    static func line(
        items: [Item],
        pixelWidth: Int,
        pixelHeight: Int,
        jsonPath: String,
        words: Words
    ) -> String? {
        guard !items.isEmpty else { return nil }

        let parts = items.map { item -> String in
            switch item {
            case let .number(n, x, y, text):
                let mark = "\(circled(n)) (\(x),\(y))"
                return text.isEmpty ? mark : "\(mark) \(text)"
            case let .rect(x, y, width, height):
                return "\(words.rect) (\(x),\(y),\(width),\(height))"
            case let .arrow(fromX, fromY, toX, toY):
                return "\(words.arrow) (\(fromX),\(fromY))→(\(toX),\(toY))"
            case let .text(x, y, text):
                return "\(words.text) (\(x),\(y)) \(text)"
            case let .pen(x, y, width, height):
                return "\(words.pen) (\(x),\(y),\(width),\(height))"
            }
        }

        return "[\(words.header) \(pixelWidth)×\(pixelHeight)] "
            + parts.joined(separator: words.separator)
            + words.see + jsonPath
    }

    /// ① to ⑳ as single characters; past twenty there are none, so `(21)`.
    static func circled(_ n: Int) -> String {
        guard (1...20).contains(n), let scalar = Unicode.Scalar(0x2460 + UInt32(n - 1)) else {
            return "(\(n))"
        }
        return String(Character(scalar))
    }
}
