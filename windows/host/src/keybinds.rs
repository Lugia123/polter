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

use crate::ffi::Keybind;
use crate::keys::TriggerC as Trigger;

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
    /// A human title, when the action names exactly one command. **Absent for
    /// most rows**, which is why `action` is the column always shown.
    pub title: Option<String>,
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
                    title: None,
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

/// What the page prints in the note column for one row.
///
/// **Four states, and they are not interchangeable.** A reader who cannot
/// tell "this has no key" from "this has a key the menu cannot print" learns
/// the wrong thing from the page, and the second of those is the defect the
/// page exists to make visible.
pub fn note(row: &Row) -> &'static str {
    // The five gates the user has over an agent. They have keys now (333) and
    // the page must show them, but rebinding them is a policy question and
    // not this version's to answer.
    if is_agent_gate(row.action) {
        return "这几条是你对 agent 的开关，键由产品定，暂不支持自行更改。";
    }
    // ⚠️ On Windows the core's own "is this a password prompt" detection is
    // not implemented, so this never turns itself on -- and the screen-capture
    // exclusion it brings with it never turns itself on either. Without this
    // line the only way to find it is to already know its name.
    if row.action == "toggle_secure_input" {
        return "Windows 上不自动开启，需手动打开";
    }
    if row.hidden_from_menu {
        return "菜单里不显示这个快捷键（键仍然有效）";
    }
    if row.triggers.is_empty() {
        return "尚无快捷键";
    }
    ""
}

/// The Poltergeist gates: the switches a person holds over an agent.
///
/// **Matched on the prefix, and that is the safe direction.** Naming the five
/// would mean a sixth added later is treated as an ordinary action -- shown as
/// something to rebind, with no note saying what it governs. Defaulting the
/// other way costs at most a note on a row that did not need one.
///
/// ⚠️ **It also keeps this file from spelling out the hold toggle's name.**
/// `windows/tools/poltergeist-close-and-hold-are-wired.py` requires that one
/// action to be named in `menu.rs` and nowhere else under
/// `windows/host/src`, because **every site naming it is the host asserting
/// that a person did it**. A listing is not such a site, but the gate counts
/// sites and says outright that it cannot read intent -- so the answer is to
/// not need an exemption rather than to write one into a gate whose whole
/// value is that it has none.
///
/// ⚠️ And this comment does not write the name either: the gate reads text,
/// so prose about the rule would break the rule.
pub fn is_agent_gate(action: &str) -> bool {
    action.starts_with("poltergeist_")
}

/// Every key bound to this action, rendered the way the menu renders one.
///
/// **`keys::format_trigger`, not a second renderer.** Two spellings of one
/// shortcut that disagree would disagree quietly, and the disagreement would
/// be between this page and the menu it is here to compensate for.
pub fn keys_label(row: &Row) -> String {
    let mut parts: Vec<String> = Vec::new();
    for t in &row.triggers {
        if let Some(s) = crate::keys::format_trigger(*t) {
            parts.push(s);
        }
    }
    if parts.is_empty() {
        "—".to_string()
    } else {
        parts.join("   ")
    }
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
    let mut rows = group(&flat);

    // A human title where the action names exactly one command. 63 of the
    // core's 93 actions are commands at all, and the parameterised ones name
    // several, so most rows keep their tag -- which is why the tag is the
    // column that is always there and the title is the one that is not.
    for (tag, title) in crate::palette::action_titles(cfg) {
        if let Some(r) = rows.iter_mut().find(|r| r.action == tag) {
            r.title = Some(title);
        }
    }
    rows
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

    fn row(action: &'static str, keys: usize, hidden: bool) -> Row {
        Row {
            action,
            triggers: vec![Trigger::default(); keys],
            hidden_from_menu: hidden,
            sequence: false,
            title: None,
        }
    }

    /// **The four notes are not interchangeable.** A reader who cannot tell
    /// "no key" from "a key the menu will not print" learns the wrong thing,
    /// and the second is the defect this page exists for.
    #[test]
    fn each_state_says_a_different_thing() {
        let gate = note(&row("poltergeist_toggle_shielded", 1, false));
        let secure = note(&row("toggle_secure_input", 0, false));
        let hidden = note(&row("undo", 2, true));
        let unbound = note(&row("move_tab", 0, false));
        let plain = note(&row("new_tab", 1, false));

        assert!(gate.contains("agent"));
        assert!(secure.contains("手动"));
        assert!(hidden.contains("菜单"));
        assert!(unbound.contains("尚无"));
        assert_eq!(plain, "");

        // No two of them are the same sentence.
        let all = [gate, secure, hidden, unbound];
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert_ne!(a, b);
            }
        }
    }

    /// The agent gates keep their note **even though they now have keys**
    /// (333). Showing the key and withholding the rebind is the whole of this
    /// version's decision, so a note that only fired for unbound actions
    /// would drop it exactly where it matters.
    #[test]
    fn an_agent_gate_with_a_key_still_says_so() {
        assert!(note(&row("poltergeist_toggle_watch", 1, false)).contains("agent"));
    }

    /// **A gate added later is a gate.** The five that exist today are
    /// spelled with the prefix, and so will the sixth be; treating an unknown
    /// one as ordinary is the failure that costs something.
    ///
    /// ⚠️ Written without the one name a checker reserves for `menu.rs`; see
    /// `is_agent_gate`.
    #[test]
    fn anything_under_the_prefix_is_a_gate() {
        assert!(is_agent_gate("poltergeist_supervisor"));
        assert!(is_agent_gate("poltergeist_toggle_watch"));
        assert!(is_agent_gate("poltergeist_toggle_shielded"));
        assert!(is_agent_gate("poltergeist_toggle_chat"));
        assert!(is_agent_gate("poltergeist_something_added_later"));
        assert!(!is_agent_gate("toggle_shielded"));
        assert!(!is_agent_gate("new_tab"));
    }

    /// An action with no key shows a dash, not an empty cell that reads like
    /// a rendering failure.
    #[test]
    fn no_key_is_a_dash() {
        assert_eq!(keys_label(&row("move_tab", 0, false)), "—");
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
