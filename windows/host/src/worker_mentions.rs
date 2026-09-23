//! The worker-mentions switch (task 575, `dev-docs/poltergeist/mentions.md`
//! §5-6), as all three menus draw it: the menu bar's Agents menu
//! (`menu.rs`), the tab strip's right-click menu (`strip.rs`) and the
//! terminal's own right-click menu (`ctxmenu.rs`).
//!
//! **One place for the two questions every menu asks of the row** -- is it on
//! the menu at all, and is it ticked. Each of the three used to answer them
//! for itself, and two of them spelled "is a supervisor" as a bare `1`. A menu
//! that disagrees about whether a row exists is the one that sends a person
//! looking for it in the wrong place (`tools/the-switch-is-in-the-menu-the-
//! refusal-names.py` is the floor for the last time that happened).
//!
//! **The row's words and binding string are *not* taken from here**, and that
//! was tried first. Each table spells them as literals, like every row beside
//! it, because the things that read those tables read literals:
//! `src/input/command.zig`'s `menu labels reach the palette` skips a row whose
//! label is a path -- silently, in two of the three tables -- and
//! `windows/tools/menu-actions-handled.py` could not read it either. A reader
//! that pretends a row it cannot read is not there is worse than three copies
//! of a string, because the copies can be checked:
//! `windows/tools/the-worker-mentions-row-is-in-every-agent-menu.py` holds
//! every table's literals to `LABEL` and `ACTION` below.
//!
//! **What the switch is.** A supervisor's own setting, off by default. Off,
//! a worker naming another worker in the group has that mention rewritten to
//! this supervisor, who decides what to pass on. On, workers reach each other
//! directly and this supervisor only has the message unread. The rewriting,
//! delivery and refusals are all the core's; this host draws the row, sends
//! `ACTION` to the supervisor's surface, and reads the state back as
//! `worker_mentions` on the ordinary poltergeist mark (byte 15, see
//! `ffi::Action::as_poltergeist_mark`). No new action tag.
//!
//! **Not in the command palette and bound to no key**, the same as the
//! authorise switch: it is a decision about who may reach whom, made on
//! purpose from a menu.
//!
//! Pure -- no window, no core, no other module -- so its tests run with a bare
//! `rustc --test` on any machine, not only on Windows.

/// The row's words, **as the tables must spell them** -- the macOS label,
/// byte for byte (`Localizable.strings`), so one `po/` entry serves both.
///
/// Not wrapped in `n_` and not read by any menu: it is the reference the
/// tables are checked against, not the label they draw. `n_` here would put a
/// fourth source location on the msgid for a string nobody sees.
#[allow(dead_code)] // read by the gate named above and by the tests below
pub const LABEL: &str = "Let Workers Name Each Other Directly";

/// The core binding string, as the tables must spell it. Performed on the
/// **supervisor's** surface; on any other surface the core does nothing with
/// it.
#[allow(dead_code)] // read by the gate named above and by the tests below
pub const ACTION: &str = "poltergeist_toggle_worker_mentions";

/// `ghostty_action_poltergeist_role_e`'s supervisor.
pub const ROLE_SUPERVISOR: u8 = 1;

/// Whether the row is on the menu at all.
///
/// **Left out rather than greyed** on anything that is not a supervisor, and
/// that is not the hiding `§3.4.3` warns about. That rule is for a row that
/// exists for this terminal and cannot be used *now*; greyed says "this
/// exists, not now". On a worker the setting is not about this terminal at
/// all and never will be -- a greyed row would send someone looking for how
/// to earn it.
///
/// `None` is "no mark has arrived for this terminal", and it gets no row: a
/// terminal whose role is not known is not known to be a supervisor.
pub fn offered(role: Option<u8>) -> bool {
    role == Some(ROLE_SUPERVISOR)
}

/// Whether the row is ticked.
///
/// **Only ever on a row that is offered.** The core sends the bit false on
/// anything that is not a supervisor, but a row that is not drawn cannot show
/// a tick, and a menu asking this about a worker should get the same answer
/// the drawing would.
pub fn ticked(role: Option<u8>, worker_mentions: bool) -> bool {
    offered(role) && worker_mentions
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A supervisor is offered the row; nothing else is -- including a
    /// terminal whose mark never arrived.
    #[test]
    fn only_a_supervisor_is_offered_the_row() {
        assert!(offered(Some(ROLE_SUPERVISOR)));
        assert!(!offered(Some(0)), "a plain terminal");
        assert!(!offered(Some(2)), "a watched worker");
        assert!(!offered(None), "no mark yet is not a supervisor");
    }

    /// **Off by default.** A supervisor whose mark carries the bit clear has
    /// the row drawn and unticked -- the rewrite is the default, and a tick
    /// that appeared without the bit would claim the opposite.
    #[test]
    fn the_row_is_unticked_until_the_bit_is_set() {
        assert!(!ticked(Some(ROLE_SUPERVISOR), false));
        assert!(ticked(Some(ROLE_SUPERVISOR), true));
    }

    /// The bit alone does not tick a row that is not there.
    #[test]
    fn a_worker_never_shows_a_tick() {
        assert!(!ticked(Some(2), true));
        assert!(!ticked(Some(0), true));
        assert!(!ticked(None, true));
    }

    /// The contract's names. A one-letter drift in either is a menu row that
    /// does nothing when clicked (`binding_action` just returns false) or
    /// words that miss their translation, and neither says so anywhere.
    #[test]
    fn the_strings_are_the_contracts() {
        assert_eq!(ACTION, "poltergeist_toggle_worker_mentions");
        assert_eq!(LABEL, "Let Workers Name Each Other Directly");
    }
}
