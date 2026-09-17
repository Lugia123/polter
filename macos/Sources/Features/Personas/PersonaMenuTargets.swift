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
/// ⚠️ **PENDING-W1-568: none of these exists in the union yet.** Until they
/// do, every one of them makes `ghostty_surface_binding_action` return false
/// and log a warning. Nothing happens, and nothing claims to have happened.
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
            // PENDING-W1-568: the re-read lands here once
            // `ghostty_surface_persona_face` exists. Until then the mark
            // action the core sends alongside the refusal is what gets the
            // editor redrawn, and there is nothing in the face to show.
            AppDelegate.logger.warning(
                "persona action refused action=\(action, privacy: .public)")
            refreshPersonaEditor()
        }
    }

    @objc func showPoltergeistPersonaEditor(_ sender: NSMenuItem) {
        PersonaEditor.shared.present(
            for: self,
            model: personaEditorModel,
            onSelectPersona: { [weak self] key in
                self?.sendPersonaAction(PersonaAction.set(key))
            },
            onToggleSkill: { [weak self] entry, on in
                self?.sendPersonaAction(PersonaAction.skill(entry.id, on))
            },
            onToggleMCP: { [weak self] entry, on in
                self?.sendPersonaAction(PersonaAction.mcp(entry.id, on))
            },
            onResetToPersona: { [weak self] in
                // Re-picking the persona *is* the reset: contract §② defines
                // "set to a persona" as assigning the key and resetting the
                // face to its declaration. A fourth action would be a second
                // definition of the same thing, free to drift from the first.
                guard let self, let key = self.poltergeistPersonaState.key else { return }
                self.sendPersonaAction(PersonaAction.set(key))
            })
    }

    /// The snapshot the editor draws, gathered fresh.
    var personaEditorModel: PersonaEditorModel {
        let catalog = PersonaCatalog.shared
        catalog.reload()
        return PersonaEditorModel(
            terminalTitle: title,
            state: poltergeistPersonaState,
            personas: catalog.personas,
            personasKnown: catalog.isKnown,
            face: poltergeistPersonaFace,
            inventory: catalog.inventory,
            shielded: poltergeistShielded)
    }

    /// Push current state into this terminal's editor window, if one is up.
    ///
    /// Called from wherever the core's report lands. Cheap and a no-op when
    /// no editor is open, so the call site does not have to know.
    func refreshPersonaEditor() {
        guard PersonaEditor.shared.isOpen(for: self) else { return }
        PersonaEditor.shared.update(for: self, model: personaEditorModel)
    }
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

    @objc func showPoltergeistPersonaEditor(_ sender: NSMenuItem) {
        focusedSurface?.showPoltergeistPersonaEditor(sender)
    }
}
