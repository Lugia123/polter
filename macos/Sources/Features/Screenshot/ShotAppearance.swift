import CoreFoundation
import Foundation

/// What `appearance` in a screenshot's `.json` says: the light or dark the
/// **system** asks applications to use at the moment the file is written --
/// not the colours of Polter's own windows
/// (`dev-docs/poltergeist/screenshot.md`, section 11).
///
/// It used to be `NSApp.effectiveAppearance`, which is whatever Polter's
/// windows are drawn in: with the window theme set to dark in the
/// configuration, a screenshot taken on a light system said `"dark"`
/// (task 1198). The Windows host reads `AppsUseLightTheme` for the same
/// reason.
enum ShotAppearance {
    /// The setting's name in the global preferences. Present, and `Dark`,
    /// when the system is dark; absent when it is light. With
    /// "Auto" it comes and goes with the time of day.
    static let key = "AppleInterfaceStyle"

    /// `dark` when `interfaceStyle` is the system's `Dark`, else `light`.
    static func name(interfaceStyle: String?) -> String {
        interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame ? "dark" : "light"
    }

    /// The value the system has now: read from the global preferences
    /// themselves (not through this app's defaults, which an application's
    /// own setting of the same name would shadow, and which cache).
    static func systemInterfaceStyle() -> String? {
        CFPreferencesCopyValue(
            key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    /// The system's appearance now.
    static var system: String { name(interfaceStyle: systemInterfaceStyle()) }
}
