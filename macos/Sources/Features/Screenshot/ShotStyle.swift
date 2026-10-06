import Foundation

/// What an annotation can look like: nine colours and five steps of each
/// of thickness, font size and mosaic block
/// (`dev-docs/poltergeist/screenshot.md`, 9.1 and 9.5). A port of the
/// Windows host's `style.rs`; see `PixelGeometry.swift`.
enum ShotStyle {
    struct RGB: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

    /// The preset colours, in the order of the number keys 1 to 9: red,
    /// orange, yellow, green, cyan, blue, purple, black, white.
    static let colours: [RGB] = [
        RGB(r: 0xE6, g: 0x28, b: 0x28),
        RGB(r: 0xF5, g: 0x82, b: 0x1F),
        RGB(r: 0xFF, g: 0xD4, b: 0x00),
        RGB(r: 0x2D, g: 0xB8, b: 0x4D),
        RGB(r: 0x17, g: 0xB5, b: 0xC8),
        RGB(r: 0x2F, g: 0x6F, b: 0xED),
        RGB(r: 0x8E, g: 0x44, b: 0xD6),
        RGB(r: 0x1A, g: 0x1A, b: 0x1A),
        RGB(r: 0xFF, g: 0xFF, b: 0xFF),
    ]

    /// Every stepped property has this many steps.
    static let levels = 5
    /// The step a tool starts on: the second.
    static let defaultLevel = 1
    static let defaultColour = 0

    /// Stroke widths, in points.
    static let widths = [1, 2, 4, 6, 10]
    /// Font sizes, in points.
    static let fonts = [14, 18, 24, 32, 44]
    /// Mosaic blocks: the block's edge in points, and `k` -- the most blocks
    /// allowed along the region's short side.
    static let mosaic: [(points: Int, k: Int)] = [(8, 12), (12, 10), (16, 8), (24, 6), (32, 4)]
    /// A highlighter is this many times as wide as a pen at the same step.
    static let highlighterFactor = 4

    static func colour(_ index: Int) -> RGB {
        colours[((index % colours.count) + colours.count) % colours.count]
    }

    /// `#RRGGBB`.
    static func hex(_ index: Int) -> String {
        let c = colour(index)
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    static func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// The colour `#RRGGBB` names, either case; nil for anything else.
    static func rgb(ofHex hex: String) -> RGB? {
        let digits = Array(hex.utf8)
        guard digits.count == 7, digits[0] == UInt8(ascii: "#") else { return nil }
        var parts: [UInt8] = []
        for i in stride(from: 1, to: 7, by: 2) {
            guard let high = Character(UnicodeScalar(digits[i])).hexDigitValue,
                  let low = Character(UnicodeScalar(digits[i + 1])).hexDigitValue else { return nil }
            parts.append(UInt8(high * 16 + low))
        }
        return RGB(r: parts[0], g: parts[1], b: parts[2])
    }

    /// The index of the preset `#RRGGBB` names, if it is one of them.
    static func index(ofHex hex: String) -> Int? {
        (0..<colours.count).first { self.hex($0).caseInsensitiveCompare(hex) == .orderedSame }
    }

    private static func clampLevel(_ level: Int) -> Int {
        min(max(level, 0), levels - 1)
    }

    /// Points to physical pixels, never less than one.
    static func px(_ points: Int, scale: Double) -> Int {
        max(Int((Double(points) * scale).rounded()), 1)
    }

    static func widthPx(level: Int, scale: Double) -> Int {
        px(widths[clampLevel(level)], scale: scale)
    }

    static func fontPx(level: Int, scale: Double) -> Int {
        px(fonts[clampLevel(level)], scale: scale)
    }

    /// The edge of a mosaic block in pixels: `max(step × scale, short side
    /// / k)`.
    ///
    /// **The second term is what makes a large region unreadable too.** A
    /// fixed block that hides a password field leaves a full-screen region
    /// legible -- big letters survive small blocks. Dividing the short side
    /// by `k`, rounded up, keeps it to at most `k` blocks across however
    /// large the region is.
    static func mosaicBlock(level: Int, scale: Double, shortSide: Int) -> Int {
        let step = mosaic[clampLevel(level)]
        let side = max(shortSide, 0)
        let bySide = (side + step.k - 1) / step.k
        return max(px(step.points, scale: scale), bySide)
    }
}

/// What the pointer does when it is pressed inside the selection.
enum AnnotationTool: Int, CaseIterable, Equatable, Hashable {
    case select, rect, ellipse, line, arrow, pen, highlighter, text, number, mosaic

    /// Which row of properties goes with a tool, or with an annotation it
    /// made.
    enum Props: Equatable {
        case none, stroke, font, block
    }

    /// The key that chooses it.
    var letter: Character {
        switch self {
        case .select: return "V"
        case .rect: return "R"
        case .ellipse: return "O"
        case .line: return "L"
        case .arrow: return "A"
        case .pen: return "P"
        case .highlighter: return "H"
        case .text: return "T"
        case .number: return "N"
        case .mosaic: return "M"
        }
    }

    init?(letter: Character) {
        let upper = Character(letter.uppercased())
        guard let tool = Self.allCases.first(where: { $0.letter == upper }) else { return nil }
        self = tool
    }

    var props: Props {
        switch self {
        case .select: return .none
        case .text, .number: return .font
        case .mosaic: return .block
        default: return .stroke
        }
    }

    /// The name it is saved under in `shot-tools.json`, and its `type` in a
    /// sidecar.
    var name: String {
        switch self {
        case .select: return "select"
        case .rect: return "rect"
        case .ellipse: return "ellipse"
        case .line: return "line"
        case .arrow: return "arrow"
        case .pen: return "pen"
        case .highlighter: return "highlighter"
        case .text: return "text"
        case .number: return "number"
        case .mosaic: return "mosaic"
        }
    }
}

/// The colour and step each tool was last used with. Kept for the length of
/// a screenshot and saved between them in `shot-tools.json`, beside the
/// screenshot directory -- not in the configuration.
struct ToolPrefs: Equatable {
    private var byTool: [AnnotationTool: (colour: Int, level: Int)] = [:]

    static func == (lhs: ToolPrefs, rhs: ToolPrefs) -> Bool {
        AnnotationTool.allCases.allSatisfy {
            lhs.colour(of: $0) == rhs.colour(of: $0) && lhs.level(of: $0) == rhs.level(of: $0)
        }
    }

    func colour(of tool: AnnotationTool) -> Int {
        byTool[tool]?.colour ?? ShotStyle.defaultColour
    }

    func level(of tool: AnnotationTool) -> Int {
        byTool[tool]?.level ?? ShotStyle.defaultLevel
    }

    mutating func setColour(_ colour: Int, of tool: AnnotationTool) {
        byTool[tool] = (min(max(colour, 0), ShotStyle.colours.count - 1), level(of: tool))
    }

    mutating func setLevel(_ level: Int, of tool: AnnotationTool) {
        byTool[tool] = (colour(of: tool), min(max(level, 0), ShotStyle.levels - 1))
    }

    /// The file's text. The tools with no properties are not in it.
    func json() -> String {
        let tools = AnnotationTool.allCases
            .filter { $0.props != .none }
            .map { "    \"\($0.name)\": {\"color\": \(colour(of: $0)), \"level\": \(level(of: $0))}" }
        return "{\n  \"version\": 1,\n  \"tools\": {\n\(tools.joined(separator: ",\n"))\n  }\n}\n"
    }

    /// What a file says, read leniently: anything missing, malformed or out
    /// of range leaves that tool at its default, so a file from a newer
    /// build -- or one somebody edited -- never stops a screenshot.
    init(json text: String) {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let tools = root["tools"] as? [String: Any] else { return }
        for tool in AnnotationTool.allCases {
            guard let entry = tools[tool.name] as? [String: Any] else { continue }
            if let colour = Self.wholeNumber(entry["color"]), (0..<ShotStyle.colours.count).contains(colour) {
                setColour(colour, of: tool)
            }
            if let level = Self.wholeNumber(entry["level"]), (0..<ShotStyle.levels).contains(level) {
                setLevel(level, of: tool)
            }
        }
    }

    init() {}

    /// A JSON number that is a non-negative whole number. `true` is not one,
    /// though `NSNumber` would let it pass for 1.
    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double == double.rounded(), double < 1_000_000 else { return nil }
        return Int(double)
    }
}
