//! What a key does while the frozen screen is up.
//!
//! **The modifiers are an argument, and how the host reads them matters.**
//! They have to be the keyboard as it was when *this* key message was made
//! (`GetKeyState`), not as it is at the instant the handler runs
//! (`GetAsyncKeyState`). A chord that is pressed and released quickly -- any
//! injected one, and a real one whenever the window thread is behind -- has
//! its Ctrl already up by the time the `Z` is handled, so the asynchronous
//! reading says "no Ctrl" and the chord does nothing. That was defect D1 of
//! task 1085: `Ctrl+Z` did not undo while `Esc` and `Enter`, which need no
//! modifier, worked.

use crate::dclick::Mods;

pub const VK_RETURN: u16 = 0x0D;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_Z: u16 = 0x5A;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    /// Leave without a trace.
    Cancel,
    /// Take the selection as it is.
    Finish,
    /// Remove the last annotation.
    Undo,
    Ignored,
}

impl Key {
    /// The word the log line uses.
    pub fn label(self) -> &'static str {
        match self {
            Key::Cancel => "cancel",
            Key::Finish => "finish",
            Key::Undo => "undo",
            Key::Ignored => "ignored",
        }
    }
}

/// What the key `vk`, pressed with `mods` held, does.
///
///  * `Esc` cancels whatever is held: a way out must not depend on letting
///    go of a key first.
///  * `Enter` finishes when there is a selection, and is nothing otherwise.
///  * `Ctrl+Z` undoes -- exactly Ctrl. `Ctrl+Shift+Z` is redo everywhere
///    else and must not quietly undo instead.
pub fn key(vk: u16, mods: Mods, has_selection: bool) -> Key {
    const CTRL: Mods = Mods { ctrl: true, shift: false, alt: false, win: false };
    match vk {
        VK_ESCAPE => Key::Cancel,
        VK_RETURN if has_selection => Key::Finish,
        VK_Z if mods == CTRL => Key::Undo,
        _ => Key::Ignored,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CTRL: Mods = Mods { ctrl: true, shift: false, alt: false, win: false };

    #[test]
    fn ctrl_z_undoes() {
        assert_eq!(key(VK_Z, CTRL, true), Key::Undo);
        assert_eq!(key(VK_Z, CTRL, false), Key::Undo, "nothing to undo is the caller's to find out");
    }

    #[test]
    fn z_without_exactly_ctrl_is_not_undo() {
        // The reading D1 got: the Z arrives and Ctrl is reported up.
        assert_eq!(key(VK_Z, Mods::NONE, true), Key::Ignored);
        assert_eq!(key(VK_Z, Mods::CTRL_SHIFT, true), Key::Ignored, "that is redo elsewhere");
        assert_eq!(key(VK_Z, Mods { alt: true, ..CTRL }, true), Key::Ignored);
        assert_eq!(key(VK_Z, Mods { win: true, ..CTRL }, true), Key::Ignored);
        assert_eq!(key(VK_Z, Mods { shift: true, ..Mods::NONE }, true), Key::Ignored);
    }

    #[test]
    fn another_letter_with_ctrl_is_not_undo() {
        assert_eq!(key(0x59, CTRL, true), Key::Ignored); // Y
        assert_eq!(key(0x41, CTRL, true), Key::Ignored); // A
    }

    #[test]
    fn escape_cancels_whatever_is_held() {
        for mods in [Mods::NONE, CTRL, Mods::CTRL_SHIFT, Mods { alt: true, ..Mods::NONE }] {
            assert_eq!(key(VK_ESCAPE, mods, true), Key::Cancel);
            assert_eq!(key(VK_ESCAPE, mods, false), Key::Cancel);
        }
    }

    #[test]
    fn enter_finishes_only_when_there_is_a_selection() {
        assert_eq!(key(VK_RETURN, Mods::NONE, true), Key::Finish);
        assert_eq!(key(VK_RETURN, Mods::NONE, false), Key::Ignored);
    }
}
