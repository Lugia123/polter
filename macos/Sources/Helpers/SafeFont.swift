import AppKit
import OSLog
import SwiftUI

/// A system face that may not be there, and a cache that only remembers
/// the faces it got.
///
/// `NSFont.systemFont(ofSize:weight:)` and `monospacedSystemFont(ofSize:weight:)`
/// are typed nonnull, but one of them returned nil in the user's app at
/// 03:43 on 2026-10-18 (task 1753). Swift cannot test a non-optional for
/// nil, so the nil went into `[.font: font]`, and CoreText, finding no font
/// in the attributes, copied them and threw on the nil value. That throw is
/// reproduced frame for frame by measuring with a nil font. Why the system
/// had no face to give is an inference only: the data volume was under
/// high-urgency cache deletion in the minutes before.
///
/// So faces are made through `GhosttySystemFontOrNil`, where nil is an
/// ordinary optional, and kept by `SafeFace`, which does not keep a nil: a
/// face made once at launch (task 1718) and nil would be nil for the rest of
/// the process; this one is asked for again on the next render.
final class SafeFace: @unchecked Sendable {
    enum Design {
        case system
        case monospaced
        /// The menu's face (`menuFont`); the weight is not asked for.
        case menu
        /// The title bar's face (`titleBarFont`); the weight is not asked
        /// for.
        case titleBar
    }

    typealias Maker = (_ size: CGFloat, _ weight: NSFont.Weight, _ design: Design) -> NSFont?

    let size: CGFloat
    let weight: NSFont.Weight
    let design: Design

    private let make: Maker
    private let standIn: Maker
    private let lock = NSLock()
    private var made: NSFont?
    private var failing = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: "SafeFont"
    )

    init(size: CGFloat, weight: NSFont.Weight = .regular, design: Design = .system,
         make: @escaping Maker = SafeFace.system, standIn: @escaping Maker = SafeFace.standIn) {
        self.size = size
        self.weight = weight
        self.design = design
        self.make = make
        self.standIn = standIn
    }

    /// The face; while the system has none to give, a face that stands in
    /// for it; nil when there is neither. Only the system's face is kept:
    /// a stand-in is asked for again, after the system's, on the next call.
    var font: NSFont? {
        lock.lock()
        defer { lock.unlock() }
        if let made { return made }
        if let font = make(size, weight, design) {
            made = font
            if failing {
                failing = false
                Self.logger.info("\(self.describe, privacy: .public) is back")
            }
            return font
        }
        if !failing {
            // Once per run of failures, not once per render.
            failing = true
            Self.logger.error("the system gave no font for \(self.describe, privacy: .public); using a stand-in or an estimate until it does")
        }
        return standIn(size, weight, design)
    }

    private var describe: String {
        "\(design) \(size)pt weight \(weight.rawValue)"
    }

    /// The size text in this face is set at: `size`, or for a size of 0,
    /// which asks AppKit for its default, the size the face came at -- and
    /// the system's font size while there is no face. What an estimate is
    /// made at (`SafeTextMeasure`).
    var pointSize: CGFloat {
        if size > 0 { return size }
        return font?.pointSize ?? NSFont.systemFontSize
    }

    /// The system's face for these.
    static func system(_ size: CGFloat, _ weight: NSFont.Weight, _ design: Design) -> NSFont? {
        switch design {
        case .system, .monospaced:
            return GhosttySystemFontOrNil(size, weight.rawValue, design == .monospaced)
        case .menu:
            return GhosttyMenuFontOrNil(size)
        case .titleBar:
            return GhosttyTitleBarFontOrNil(size)
        }
    }

    /// Faces that stand in for the system's, in order, each of which may be
    /// missing for the same reason.
    static func standIn(_ size: CGFloat, _ weight: NSFont.Weight, _ design: Design) -> NSFont? {
        switch design {
        case .monospaced:
            return NSFont(name: "Menlo", size: size) ?? NSFont.userFixedPitchFont(ofSize: size)
        case .system, .menu, .titleBar:
            return GhosttySystemFontOrNil(size > 0 ? size : NSFont.systemFontSize, NSFont.Weight.regular.rawValue, false)
                ?? NSFont.userFont(ofSize: size)
        }
    }
}

extension SafeFace {
    /// The menu's face at its own size: nothing in Polter's own windows is
    /// set smaller (`SettingsFont`). Shared, as the face is the same
    /// wherever it is asked for (task 1805).
    static let menu = SafeFace(size: 0, design: .menu)
}

extension SafeFace {
    /// The face for a SwiftUI `Text`; while the system has no font for it,
    /// SwiftUI's own system face at the same size, so the text still shows.
    var swiftUI: Font {
        if let font { return Font(font) }
        return .system(size: pointSize, design: design == .monospaced ? .monospaced : .default)
    }
}
