//! The find bar's keys (task 2120): which way a key in its text box walks
//! the matches. Out of `polter-host` so that the rule is tested where it is
//! written -- the host's own tests only run on Windows.
//!
//! The core binds the same keys for a terminal with a search open
//! (`Config.zig`: `f3` next, `shift+f3` previous); while the box has the
//! keyboard the key never reaches the core, so the box says it itself, and
//! it has to say the same. Shift walks backwards, the convention every find
//! bar uses -- with Enter, and with F3.

/// Virtual-key codes, as Win32 numbers them.
pub const VK_RETURN: u16 = 0x0D;
pub const VK_F3: u16 = 0x72;

/// Which way a key down in the find bar's box walks: `Some(true)` to the
/// next match, `Some(false)` to the previous one, `None` for a key that is
/// the box's own.
pub fn walks(vk: u16, shift: bool) -> Option<bool> {
    match vk {
        VK_RETURN | VK_F3 => Some(!shift),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Task 2120: Shift+F3 walked forwards, as F3 does (the box's F3 never
    /// looked at Shift, from 6454c1354 on). It walks back, as Shift+Enter
    /// always did and as the core binds `shift+f3`.
    #[test]
    fn shift_walks_back_with_f3_as_with_enter() {
        assert_eq!(walks(VK_F3, false), Some(true));
        assert_eq!(walks(VK_F3, true), Some(false));
        assert_eq!(walks(VK_RETURN, false), Some(true));
        assert_eq!(walks(VK_RETURN, true), Some(false));
        assert_eq!(walks(0x41, true), None);
    }
}
