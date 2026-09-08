//! The keybind listing: what the core has bound, and what it has not.
//!
//! # Why this reads a different table than the menu does
//!
//! `menu.rs` asks `ghostty_config_trigger` "what key runs this action?", which
//! the core answers out of `Binding.Set.reverse`. **That map deliberately
//! omits `performable` bindings** so a GUI toolkit does not register them as
//! menu accelerators -- the core says so in `Binding.zig`, and it is the right
//! call for a menu, because GTK handles accelerators too early in the event
//! lifecycle for `performable` to work.
//!
//! The consequence is that a menu cannot print those shortcuts. The keys work;
//! the menu is simply unable to name them. **A page whose whole job is "show
//! me the shortcuts" must not inherit that**, so it reads the forward table
//! through `config_keybind_count` / `config_keybind`.
//!
//! # Rows are actions, not keys
//!
//! Three row sets were measured before this was written, and they are not the
//! same size:
//!
//!   * **93 bindings** -- every key that does something.
//!   * **96 command-palette entries**, covering **63** of the core's actions.
//!   * **93 actions** (`Binding.Action`), of which **45** have a default key.
//!
//! Listing keys leaves out the 48 actions that have no key at all, which is
//! the half of the map a reader does not already know -- `toggle_secure_input`
//! among them. Listing commands drops nine actions that *are* bound and are
//! pressed daily: `goto_tab`, `next_tab`, `previous_tab`, `last_tab`,
//! `resize_split`, `jump_to_prompt`, `toggle_command_palette`,
//! `adjust_selection` and `esc`.
//!
//! So the page lists **actions**, each with the keys it has or none.
//!
//! ⚠️ **The two 93s above are a coincidence**, not one number seen twice.

use crate::ffi::{Keybind, Trigger};

/// One action and every key bound to it.
#[derive(Debug, Clone)]
pub struct Row {
    /// The action's stable tag. Borrowed from the core, which owns it for the
    /// life of the process.
    pub action: &'static str,
    /// The triggers bound to it, in the order the configuration declared
    /// them. **Empty means the action has no key at all** -- a row, not an
    /// omission.
    pub triggers: Vec<Trigger>,
    /// Set when any of this action's bindings is `performable`, which is the
    /// same as saying the menu cannot show it.
    pub hidden_from_menu: bool,
    /// Set when any of this action's bindings is reached through a leader-key
    /// sequence, in which case its trigger is only the first step.
    pub sequence: bool,
}

/// Fold the core's flat listing into one row per action, keeping declaration
/// order.
///
/// **Separated from the FFI read so it can be tested without a core.** The
/// grouping is where an off-by-one would silently merge two actions, and that
/// is not something a running program would make obvious.
pub fn group(rows: &[Keybind]) -> Vec<Row> {
    let mut out: Vec<Row> = Vec::new();
    for kb in rows {
        let Some(action) = kb.action() else { continue };
        let at = match out.iter().position(|r| r.action == action) {
            Some(i) => i,
            None => {
                out.push(Row {
                    action,
                    triggers: Vec::new(),
                    hidden_from_menu: false,
                    sequence: false,
                });
                out.len() - 1
            }
        };
        if kb.bound {
            out[at].triggers.push(kb.trigger);
            out[at].hidden_from_menu |= kb.hidden_from_menu();
            out[at].sequence |= kb.sequence;
        }
    }
    out
}

/// Read the whole listing out of the core.
///
/// Returns an empty vector when the API is not loaded yet, which is the same
/// answer a caller would get before startup finishes; it is not an error
/// worth a dialog.
pub fn rows() -> Vec<Row> {
    let Some(api) = crate::api_opt() else {
        return Vec::new();
    };
    // `config_handle` is a raw pointer that is null until startup puts one
    // there; it is not an Option, so the check is here rather than in it.
    let cfg = crate::config_handle();
    if cfg.is_null() {
        return Vec::new();
    }

    // SAFETY: both calls take the config handle the host already owns, and
    // neither allocates or hands back anything to free -- `action` points at
    // static storage in the core.
    let n = unsafe { (api.config_keybind_count)(cfg) };
    let mut flat = Vec::with_capacity(n as usize);
    for i in 0..n {
        flat.push(unsafe { (api.config_keybind)(cfg, i) });
    }
    group(&flat)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::BINDING_PERFORMABLE;

    fn kb(action: &'static str, bound: bool, key: u32, flags: u8) -> Keybind {
        Keybind {
            action: action.as_ptr(),
            action_len: action.len(),
            bound,
            trigger: Trigger { tag: 0, key, mods: 0 },
            flags,
            sequence: false,
        }
    }

    #[test]
    fn one_row_per_action_in_declaration_order() {
        let flat = [
            kb("goto_tab", true, 1, 0),
            kb("new_tab", true, 2, 0),
            kb("goto_tab", true, 3, 0),
        ];
        let rows = group(&flat);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].action, "goto_tab");
        assert_eq!(rows[0].triggers.len(), 2);
        assert_eq!(rows[1].action, "new_tab");
    }

    /// **An action with no key is a row.** Dropping it here would put the
    /// page back to listing keys, and `toggle_secure_input` back out of
    /// sight.
    #[test]
    fn an_unbound_action_keeps_its_row() {
        let rows = group(&[kb("toggle_secure_input", false, 0, 0)]);
        assert_eq!(rows.len(), 1);
        assert!(rows[0].triggers.is_empty());
        assert!(!rows[0].hidden_from_menu);
    }

    /// One performable binding is enough to make the action invisible to the
    /// menu, even when a plain binding sits beside it.
    #[test]
    fn performable_anywhere_marks_the_action() {
        let rows = group(&[
            kb("undo", true, 1, 0),
            kb("undo", true, 2, BINDING_PERFORMABLE),
        ]);
        assert_eq!(rows.len(), 1);
        assert!(rows[0].hidden_from_menu);
    }

    /// The row an out-of-range index returns names nothing, and must not
    /// become a row of its own.
    #[test]
    fn a_nameless_row_is_dropped() {
        let mut empty = kb("x", false, 0, 0);
        empty.action_len = 0;
        assert!(group(&[empty]).is_empty());
    }
}
