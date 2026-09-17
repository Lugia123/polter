import AppKit

/// Every SF Symbol the role interface names, in one place.
///
/// **Why an enum and not the string at each call site.** A symbol name that
/// does not exist is not an error anywhere: `NSImage(systemSymbolName:)`
/// returns `nil`, `Image(systemName:)` draws nothing, and the only thing
/// that happens is a gap on screen. That is the one failure in this feature
/// with no compiler and no crash behind it, so the names have to be somewhere
/// a check can walk over all of them -- and they have to be *the same* names
/// the views use, or the check is walking over a copy that can go stale
/// while every assertion on it still passes.
///
/// So this is the source, `allCases` is the list, and the views spell no
/// symbol of their own. A symbol added to a view without a case here does
/// not compile; a case added here without a view using it still gets
/// checked, which is the harmless direction.
enum PersonaSymbol: String, CaseIterable {
    /// The `Role ▸` item itself.
    case parent = "person.crop.square.filled.and.at.rectangle"

    /// Agents are kept out of this terminal.
    case shield = "lock"

    /// The change may not have taken effect yet.
    case pendingRestart = "clock.arrow.circlepath"

    /// A persona is set but nobody is connected to wear it.
    case noAgent = "person.slash"

    /// Nothing has reported which personas exist.
    case rolesUnknown = "ellipsis"

    /// The list was reported and is empty.
    case noRoles = "tray"

    /// Open the editor.
    case editor = "slider.horizontal.3"

    /// The editor's picker, on the chosen row.
    case selected = "checkmark.circle.fill"

    /// The editor's picker, on every other row.
    case unselected = "circle"

    /// The core sent an error with the persona file.
    case loadError = "exclamationmark.triangle"

    /// The slot count on screen is a lower bound.
    case countMayBeLow = "questionmark.circle"

    /// Whether this symbol resolves to an image on the system running now.
    ///
    /// ⚠️ **On the system running now.** A symbol introduced in macOS 14
    /// answers `true` here on 26 and draws nothing on 13, so a green from
    /// this is a statement about one machine -- see the checklist's item 7,
    /// which is still a human's job on older systems for exactly that
    /// reason.
    var resolves: Bool {
        NSImage(systemSymbolName: rawValue, accessibilityDescription: nil) != nil
    }
}
