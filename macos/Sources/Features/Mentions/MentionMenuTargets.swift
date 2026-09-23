import AppKit
import GhosttyKit

/// The binding action the direct-mentions switch sends.
///
/// Settled by the core in task 575's contract (v1): a keybinding action run
/// on the **supervisor's** surface, the same shape as
/// `poltergeist_toggle_authorise`. Run on any other surface it does nothing,
/// which is why the item is only shown on a supervisor. The state comes back
/// on the poltergeist mark as `worker_mentions`, not through a new action
/// tag -- the tag numbering the Windows host reads by hand stays where it is.
///
/// Deliberately user-only, like `may_authorise`: no default key and no
/// command-palette entry, because an agent can open the palette with
/// `terminal_key` and would then be granting itself the permission.
enum MentionAction {
    static let toggle = "poltergeist_toggle_worker_mentions"
}

// MARK: - Surface

extension Ghostty.SurfaceView: MentionMenuTarget {
    @objc func togglePoltergeistDirectMentions(_ sender: NSMenuItem) {
        guard let surface = self.surface else { return }
        let action = MentionAction.toggle
        if !ghostty_surface_binding_action(
            surface, action, UInt(action.lengthOfBytes(using: .utf8))
        ) {
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
        }
    }
}

// MARK: - Controller
//
// The tab strip's copy points at the controller of the tab that was
// right-clicked, not the focused one, so the work goes to *that*
// controller's `focusedSurface` -- the same routing `Role` uses.

extension TerminalController: MentionMenuTarget {
    @objc func togglePoltergeistDirectMentions(_ sender: NSMenuItem) {
        focusedSurface?.togglePoltergeistDirectMentions(sender)
    }
}
