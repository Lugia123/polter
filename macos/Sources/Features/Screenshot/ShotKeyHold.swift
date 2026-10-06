import Foundation

/// Who has the keyboard while a screenshot is on the screen
/// (`dev-docs/poltergeist/screenshot.md`, 3.2; task 1110).
///
/// The frozen picture covers every display and is modal: `Esc`, `Enter`,
/// the tools' keys and the text of an annotation are all its own. Its
/// windows are panels that can be key and never main, and nothing kept them
/// key: when another window of this application was made key behind them --
/// a tab an agent opened, a window raised by an accessibility client -- the
/// picture stayed on the screen with its text box open, and what was typed
/// went to the terminal underneath and was run there.
///
/// So the session watches which window becomes key and takes the keyboard
/// back. The alternative, refusing to let the other windows become key while
/// a screenshot is up, means every window class in the application asking
/// the screenshot first; this is one observer that goes away with the
/// session.
enum ShotKeyHold {
    /// A window that has just become key and is not one of the overlays
    /// (between those the keyboard follows the pointer, and the session
    /// does not ask).
    struct Window: Equatable {
        /// Its window level.
        var level: Int
        /// The application is running a modal session for it (an alert).
        var isModal: Bool
    }

    /// Whether the overlay takes the keyboard back from `window`.
    ///
    /// Not from an alert the application is waiting on, and not from
    /// anything put at the overlay's level or above it, which is
    /// over the picture and can be seen to have the keyboard. Everything
    /// else is behind the picture, where typing is typing blind.
    static func takesBack(from window: Window, overlayLevel: Int) -> Bool {
        !window.isModal && window.level < overlayLevel
    }
}
