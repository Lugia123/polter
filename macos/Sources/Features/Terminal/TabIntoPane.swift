import Foundation

/// Dragging a window tab onto a pane, where every terminal of the tab
/// becomes one new pane beside it, stacked (#1558).
///
/// **A tab drag is AppKit's, not ours.** It is no drag-and-drop session:
/// the pasteboard is never written, so no drop target sees it, and let go
/// anywhere but a tab bar it tears the tab off into a window of its own.
/// What makes it a drop onto a pane is `TabIntoPaneFollower` watching it
/// from the side -- the pointer, while the button is down -- and taking
/// the torn-off window apart once AppKit has finished with it. The window
/// is kept invisible while a pane is offered, so the tear-off is never
/// seen.
///
/// This file has no AppKit in it so the rules can be tested without a
/// window.
enum TabIntoPane {
    /// Why a tab cannot go into a pane. Said on the pane while the tab is
    /// over it; let go, the tab is torn off as it always was.
    enum Refusal: Equatable {
        /// A terminal of the tab is on the control room's right-hand side
        /// just now. Its pane cannot be picked up by dragging, so neither
        /// can the tab it is in.
        case lentToControlRoom
    }

    /// What may happen to a tab dragged over a pane.
    static func refusal(tabHasLentTerminal: Bool) -> Refusal? {
        tabHasLentTerminal ? .lentToControlRoom : nil
    }

    /// Whether the dragged tab's window is held invisible: only while it
    /// is going into a pane, so a tear-off nobody wants is never hidden.
    static func holdsWindow(overPane: Bool, refusal: Refusal?) -> Bool {
        overPane && refusal == nil
    }

    /// What to do on a tick after the button has come up.
    enum Step: Equatable {
        /// Not yet: AppKit has not torn the tab off.
        case wait
        /// Take the torn-off window apart into the pane.
        case drop
        /// Stop following; the window is shown again.
        case letGo
    }

    /// How long to wait for AppKit to tear the tab off: half a second at
    /// sixty a second. A tab let go on a tab bar is moved, not torn off,
    /// and stays where AppKit put it.
    static let tearOffTicks = 30

    /// **The drop waits for the tear-off.** Taking the window apart before
    /// AppKit has torn it off leaves AppKit's picture of the dragged tab on
    /// the screen for good (measured: still there forty seconds later).
    static func afterRelease(goingIntoPane: Bool, tornOff: Bool, ticksSinceRelease: Int) -> Step {
        guard goingIntoPane else { return .letGo }
        if tornOff { return .drop }
        return ticksSinceRelease >= tearOffTicks ? .letGo : .wait
    }
}
