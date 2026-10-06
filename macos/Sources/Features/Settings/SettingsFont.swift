import AppKit
import SwiftUI

/// The smallest text the settings window and the project windows may show
/// (settings.md §2.3b): **the size of the system's menu font**, asked of the
/// system rather than written down. Anything that would have been a caption,
/// a footnote or a callout is set in one of these instead; text that is
/// already larger (`.body` and up, titles) keeps its own style.
///
/// `tools/no-text-below-the-menu-font.py` holds the other half: inside the
/// directories this covers, the smaller text styles and literal sizes are
/// not allowed to be written at all.
enum SettingsFont {
    /// What a menu item is set in. `ofSize: 0` is how AppKit is asked for
    /// the default size of a font it defines.
    static var minimumPointSize: CGFloat { NSFont.menuFont(ofSize: 0).pointSize }

    /// Secondary text: hints, statuses, counts, notes under a control.
    static var minimum: Font { .system(size: minimumPointSize) }

    /// The same size for keys, paths and log lines.
    static var minimumMonospaced: Font { .system(size: minimumPointSize, design: .monospaced) }
}
