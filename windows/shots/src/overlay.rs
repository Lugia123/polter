//! What a key does while the frozen screen is up (§9.2).
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
//!
//! While the text box has the keyboard none of this applies: the keys go to
//! the box, and the host does not ask.

use crate::dclick::Mods;
use crate::style::Tool;

pub const VK_BACK: u16 = 0x08;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_DELETE: u16 = 0x2E;
pub const VK_Z: u16 = 0x5A;
/// `[` and `]` on a US layout.
pub const VK_OEM_4: u16 = 0xDB;
pub const VK_OEM_6: u16 = 0xDD;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    /// Leave without a trace.
    Cancel,
    /// Take the selection as it is.
    Finish,
    Undo,
    Redo,
    /// Pick up a tool.
    Tool(Tool),
    /// The n-th colour, counted from 0.
    Colour(u8),
    /// One step thinner/smaller (-1) or thicker/larger (+1).
    Step(i8),
    /// Delete the selected annotation.
    Delete,
    /// Move the selected annotation by this many pixels.
    Nudge(i32, i32),
    Ignored,
}

impl Key {
    /// The word the log line uses.
    pub fn label(self) -> &'static str {
        match self {
            Key::Cancel => "cancel",
            Key::Finish => "finish",
            Key::Undo => "undo",
            Key::Redo => "redo",
            Key::Tool(_) => "tool",
            Key::Colour(_) => "colour",
            Key::Step(_) => "step",
            Key::Delete => "delete",
            Key::Nudge(..) => "nudge",
            Key::Ignored => "ignored",
        }
    }
}

/// What the key `vk`, pressed with `mods` held, does.
///
///  * `Esc` cancels whatever is held: a way out must not depend on letting
///    go of a key first.
///  * `Enter` finishes when there is a selection, and is nothing otherwise.
///  * `Ctrl+Z` undoes and `Ctrl+Shift+Z` redoes -- exactly those modifiers.
///  * A tool's letter, a colour's digit, `[` and `]`, `Delete` and
///    `Backspace` count only with **no** modifier held: `Ctrl+R` is not the
///    rectangle tool.
///  * An arrow key moves the selected annotation one pixel, ten with Shift.
pub fn key(vk: u16, mods: Mods, has_selection: bool) -> Key {
    const CTRL: Mods = Mods { ctrl: true, shift: false, alt: false, win: false };
    const SHIFT: Mods = Mods { ctrl: false, shift: true, alt: false, win: false };
    let plain = mods == Mods::NONE;
    let step = if mods == SHIFT { 10 } else { 1 };
    match vk {
        VK_ESCAPE => Key::Cancel,
        VK_RETURN if has_selection && plain => Key::Finish,
        VK_Z if mods == CTRL => Key::Undo,
        VK_Z if mods == Mods::CTRL_SHIFT => Key::Redo,
        VK_LEFT if plain || mods == SHIFT => Key::Nudge(-step, 0),
        VK_RIGHT if plain || mods == SHIFT => Key::Nudge(step, 0),
        VK_UP if plain || mods == SHIFT => Key::Nudge(0, -step),
        VK_DOWN if plain || mods == SHIFT => Key::Nudge(0, step),
        _ if !plain => Key::Ignored,
        VK_DELETE | VK_BACK => Key::Delete,
        VK_OEM_4 => Key::Step(-1),
        VK_OEM_6 => Key::Step(1),
        // '1'..'9' on the top row and on the number pad.
        0x31..=0x39 => Key::Colour((vk - 0x31) as u8),
        0x61..=0x69 => Key::Colour((vk - 0x61) as u8),
        0x41..=0x5A => Tool::from_letter(vk as u8 as char).map_or(Key::Ignored, Key::Tool),
        _ => Key::Ignored,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CTRL: Mods = Mods { ctrl: true, shift: false, alt: false, win: false };
    const SHIFT: Mods = Mods { ctrl: false, shift: true, alt: false, win: false };

    #[test]
    fn ctrl_z_undoes_and_ctrl_shift_z_redoes() {
        assert_eq!(key(VK_Z, CTRL, true), Key::Undo);
        assert_eq!(key(VK_Z, CTRL, false), Key::Undo, "nothing to undo is the caller's to find out");
        assert_eq!(key(VK_Z, Mods::CTRL_SHIFT, true), Key::Redo);
    }

    #[test]
    fn z_without_exactly_those_modifiers_is_neither() {
        // The reading D1 got: the Z arrives and Ctrl is reported up.
        assert_eq!(key(VK_Z, Mods::NONE, true), Key::Ignored);
        assert_eq!(key(VK_Z, Mods { alt: true, ..CTRL }, true), Key::Ignored);
        assert_eq!(key(VK_Z, Mods { win: true, ..CTRL }, true), Key::Ignored);
        assert_eq!(key(VK_Z, Mods { alt: true, ..Mods::CTRL_SHIFT }, true), Key::Ignored);
        assert_eq!(key(VK_Z, SHIFT, true), Key::Ignored);
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
        assert_eq!(key(VK_RETURN, CTRL, true), Key::Ignored);
    }

    #[test]
    fn each_tool_has_its_letter() {
        let letters = [
            ('V', Tool::Select),
            ('R', Tool::Rect),
            ('O', Tool::Ellipse),
            ('L', Tool::Line),
            ('A', Tool::Arrow),
            ('P', Tool::Pen),
            ('H', Tool::Highlighter),
            ('T', Tool::Text),
            ('N', Tool::Number),
            ('M', Tool::Mosaic),
        ];
        for (letter, tool) in letters {
            assert_eq!(key(letter as u16, Mods::NONE, true), Key::Tool(tool), "{letter}");
        }
        assert_eq!(key('B' as u16, Mods::NONE, true), Key::Ignored);
        assert_eq!(key('Z' as u16, Mods::NONE, true), Key::Ignored);
    }

    #[test]
    fn a_letter_with_a_modifier_is_not_a_tool() {
        for mods in [CTRL, SHIFT, Mods::CTRL_SHIFT, Mods { alt: true, ..Mods::NONE }, Mods { win: true, ..Mods::NONE }] {
            assert_eq!(key('R' as u16, mods, true), Key::Ignored, "{mods:?}");
            assert_eq!(key(0x31, mods, true), Key::Ignored, "{mods:?}");
            assert_eq!(key(VK_DELETE, mods, true), Key::Ignored, "{mods:?}");
            assert_eq!(key(VK_OEM_4, mods, true), Key::Ignored, "{mods:?}");
        }
    }

    #[test]
    fn digits_are_colours_and_brackets_are_steps() {
        assert_eq!(key(0x31, Mods::NONE, true), Key::Colour(0));
        assert_eq!(key(0x39, Mods::NONE, true), Key::Colour(8));
        assert_eq!(key(0x30, Mods::NONE, true), Key::Ignored, "there is no tenth colour");
        assert_eq!(key(0x65, Mods::NONE, true), Key::Colour(4), "number pad 5");
        assert_eq!(key(VK_OEM_4, Mods::NONE, true), Key::Step(-1));
        assert_eq!(key(VK_OEM_6, Mods::NONE, true), Key::Step(1));
    }

    #[test]
    fn delete_and_backspace_delete() {
        assert_eq!(key(VK_DELETE, Mods::NONE, true), Key::Delete);
        assert_eq!(key(VK_BACK, Mods::NONE, true), Key::Delete);
    }

    #[test]
    fn arrows_nudge_by_one_and_by_ten_with_shift() {
        assert_eq!(key(VK_LEFT, Mods::NONE, true), Key::Nudge(-1, 0));
        assert_eq!(key(VK_RIGHT, Mods::NONE, true), Key::Nudge(1, 0));
        assert_eq!(key(VK_UP, Mods::NONE, true), Key::Nudge(0, -1));
        assert_eq!(key(VK_DOWN, Mods::NONE, true), Key::Nudge(0, 1));
        assert_eq!(key(VK_LEFT, SHIFT, true), Key::Nudge(-10, 0));
        assert_eq!(key(VK_DOWN, SHIFT, true), Key::Nudge(0, 10));
        assert_eq!(key(VK_DOWN, CTRL, true), Key::Ignored);
    }
}
