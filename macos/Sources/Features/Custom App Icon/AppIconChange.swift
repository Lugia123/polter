import Foundation

/// What applying the configured app icon has left to do (task 1873).
///
/// **Applying it used to do everything every time**: write the defaults,
/// tell the Dock tile plugin, set the bundle's icon with
/// `NSWorkspace.setIcon` and `noteFileSystemChanged` -- at launch, again at
/// the configuration reload every launch does, and at every reload after.
/// Setting a bundle's icon is LaunchServices registering the bundle again,
/// and Finder and the Dock reading its icon again; in a background login
/// session a test instance's start-up stalled the window server for nine
/// seconds, twice, one right after the other (2026-10-20), while the same
/// window work from TextEdit stalled it for at most 1.3.
///
/// So each part is done only when it would change something:
///
/// - the defaults and the plugin, when the icon is not the one they hold;
/// - the bundle, when the icon is not the one they hold, or when the bundle
///   does not carry what is wanted -- a copy of the app put in its place
///   comes without the custom icon, whatever the defaults remember.
struct AppIconChange: Equatable {
    /// Write the icon to the defaults and tell the Dock tile plugin.
    let defaults: Bool
    /// Set the bundle's icon again.
    let bundle: Bool

    static let nothing = AppIconChange(defaults: false, bundle: false)

    /// `want` is the icon the configuration asks for, nil for the official
    /// one; `stored` the one the defaults hold; `bundleHasCustomIcon`
    /// whether the app's bundle carries a custom icon now.
    static func of<Icon: Equatable>(want: Icon?, stored: Icon?, bundleHasCustomIcon: Bool) -> AppIconChange {
        let changed = want != stored
        let bundleMatches = (want != nil) == bundleHasCustomIcon
        return AppIconChange(defaults: changed, bundle: changed || !bundleMatches)
    }

    /// Whether the bundle at `path` carries a custom icon: `setIcon` gives a
    /// directory one as an `Icon\r` file inside it.
    static func bundleHasCustomIcon(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("Icon\r"))
    }
}
