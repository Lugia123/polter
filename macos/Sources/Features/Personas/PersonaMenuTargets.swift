import AppKit
import GhosttyKit

/// The four binding actions the core is to add to `src/input/Binding.zig`'s
/// `Action` union (contract §0.5).
///
/// They are keybinding action strings, sent exactly the way
/// `poltergeist_toggle_shielded` is. The contract chose this over a new FFI
/// export on purpose: `windows/host/src/menu.rs`'s `assert_actions_exist`
/// scans `Binding.zig` for union members, so a name that never joins the
/// union is a menu row that silently does nothing -- and "clicked it, nothing
/// happened" looks exactly like "not wired up yet".
///
/// ⚠️ **All four are in the union now, and all four still answer `false`.**
/// `Surface.zig` handles them by returning "did not handle this binding",
/// because the core side behind them is not built yet. So a click does
/// visibly nothing -- the honest answer -- and `sendPersonaAction` below is
/// what keeps it from being a *silent* nothing.
///
/// The two toggles spell their direction `on,` / `off,` and carry the
/// **core's minted id**, not the skill or slot's own name. Both halves of
/// that were settled after this side raised them:
///
/// - `+` is not in the charset `menu.rs`'s
///   `action_strings_have_a_binding_shape` allows (`[a-z0-9_:,-]`), so
///   `…skill:+argus` was a string that gate turns red on while `…skill:-argus`
///   passed -- half green, which is the shape that reads most like working.
/// - Names cannot be constrained to that charset either, because they are
///   **other people's**: `claude_ai_Claude_Docs` has capitals, and
///   `kanban:task-review` carries a `:` that would split in the wrong place.
///   So the action carries an id the core mints inside `[a-z0-9-]`, and the
///   name never enters an action string at all.
///
/// ⚠️ An id is only valid for the face it was minted for. A menu is built at
/// right-click and an editor window can sit open for minutes, so the core
/// must **refuse an id it does not recognise, visibly** -- a silently dropped
/// toggle and a feature that was never wired up look exactly the same on
/// screen.
enum PersonaAction {
    static func set(_ key: String?) -> String {
        guard let key else { return "poltergeist_persona_clear" }
        return "poltergeist_persona_set:\(key)"
    }

    static func skill(_ id: String, _ on: Bool) -> String {
        "poltergeist_persona_skill:\(on ? "on" : "off"),\(id)"
    }

    static func mcp(_ id: String, _ on: Bool) -> String {
        "poltergeist_persona_mcp:\(on ? "on" : "off"),\(id)"
    }
}

// MARK: - Surface

extension Ghostty.SurfaceView: PersonaMenuTarget {
    @objc func setPoltergeistPersona(_ sender: NSMenuItem) {
        // `representedObject` carries the persona key, or nil for "No Role",
        // which is what lets one selector serve every row.
        sendPersonaAction(PersonaAction.set(sender.representedObject as? String))
    }

    /// Send one persona action, and handle the core saying no.
    ///
    /// Contract §0.5: an id minted for an older epoch **must be refused
    /// visibly**, because "that id expired" and "the click did nothing" are
    /// the same thing on screen. The core's half is to return false, put the
    /// reason in this terminal's face as `error_kind: "stale_id"`, and send
    /// a mark action anyway. This side's half is what happens here: on
    /// false, re-read the face and show what it says, rather than treating
    /// false as nothing-to-see.
    ///
    /// ⚠️ **Deliberately does not compare epochs itself.** It could -- the
    /// menu knows which epoch it was built against -- and it must not.
    /// Contract §0.5: one judge, the core. A second judge on this side is
    /// two sets of rules, and the lenient one decides.
    private func sendPersonaAction(_ action: String) {
        guard let surface = self.surface else { return }
        let accepted = ghostty_surface_binding_action(
            surface, action, UInt(action.lengthOfBytes(using: .utf8)))
        if !accepted {
            AppDelegate.logger.warning(
                "persona action refused action=\(action, privacy: .public)")
            // Re-read rather than assume: the core puts its reason in this
            // terminal's face (`error_kind`), so the way to find out what
            // "no" meant is to ask, not to guess from the action string.
            reloadPersonaFace()
        }
    }

    func reloadPersonaFace() {
        guard let surface = self.surface else { return }
        poltergeistPersonaFace = PersonaFace.read(surface: surface) ?? .init()
    }

    /// The snapshot the editor draws, gathered fresh.
}

// MARK: - Controller
//
// The tab strip's copy. Its items point at the controller for the tab that
// was right-clicked, not the focused one -- which is the whole reason the
// section is worth having in the tab menu -- so the work goes to *that*
// controller's `focusedSurface`.

extension TerminalController: PersonaMenuTarget {
    @objc func setPoltergeistPersona(_ sender: NSMenuItem) {
        focusedSurface?.setPoltergeistPersona(sender)
    }
}
