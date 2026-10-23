//! How bad it is for a terminal, or the worst in a group (task 2015): the
//! snapshot's `resource_level` and the performance page's `tone`
//! (`polter-artifacts/2015/API.md` §0–1), and the colours each is drawn in.
//!
//! **The colours are the look's** (`colors.level_*` in
//! `src/input/control-room-look.json`): every level the core names has its
//! own four keys there, warn3, warn4 and withheld included -- the json says
//! they wear warn2's values, so nothing here decides that.

use crate::look::{Rgba, Theme};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    /// Nothing measured: not the same as `Ok`.
    None,
    Ok,
    Warn1,
    Warn2,
    Warn3,
    Warn4,
    /// Over its kill line and not stopped: shielded, held, or someone
    /// typing in it.
    Withheld,
    Killed,
}

impl Level {
    pub fn parse(s: &str) -> Option<Level> {
        Some(match s {
            "none" => Level::None,
            "ok" => Level::Ok,
            "warn1" => Level::Warn1,
            "warn2" => Level::Warn2,
            "warn3" => Level::Warn3,
            "warn4" => Level::Warn4,
            "withheld" => Level::Withheld,
            "killed" => Level::Killed,
            _ => return None,
        })
    }
}

/// The four colours a level past `ok` is drawn in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LevelInk {
    /// `level_<tone>`: the arc, a grid cell, the dot before "Performance".
    pub base: Rgba,
    /// `level_<tone>_text`.
    pub text: Rgba,
    /// `level_<tone>_edge`: a card's outline.
    pub edge: Rgba,
    /// `level_<tone>_badge`: a badge's ground.
    pub badge: Rgba,
}

/// The inks of `level`; none for `None` and `Ok`, which are drawn in the
/// theme's own text colours and have no edge, badge or dot.
pub fn level_ink(theme: &Theme, level: Level) -> Option<LevelInk> {
    let t = theme;
    let ink = |base, text, edge, badge| Some(LevelInk { base, text, edge, badge });
    match level {
        Level::None | Level::Ok => None,
        Level::Warn1 => ink(t.level_warn1, t.level_warn1_text, t.level_warn1_edge, t.level_warn1_badge),
        Level::Warn2 => ink(t.level_warn2, t.level_warn2_text, t.level_warn2_edge, t.level_warn2_badge),
        Level::Warn3 => ink(t.level_warn3, t.level_warn3_text, t.level_warn3_edge, t.level_warn3_badge),
        Level::Warn4 => ink(t.level_warn4, t.level_warn4_text, t.level_warn4_edge, t.level_warn4_badge),
        Level::Withheld => ink(t.level_withheld, t.level_withheld_text, t.level_withheld_edge, t.level_withheld_badge),
        Level::Killed => ink(t.level_killed, t.level_killed_text, t.level_killed_edge, t.level_killed_badge),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::{DARK, LIGHT};

    #[test]
    fn every_level_the_core_names_is_read_and_another_is_not() {
        for (s, l) in [
            ("none", Level::None),
            ("ok", Level::Ok),
            ("warn1", Level::Warn1),
            ("warn2", Level::Warn2),
            ("warn3", Level::Warn3),
            ("warn4", Level::Warn4),
            ("withheld", Level::Withheld),
            ("killed", Level::Killed),
        ] {
            assert_eq!(Level::parse(s), Some(l), "{s}");
        }
        assert_eq!(Level::parse("warn5"), None);
        assert_eq!(Level::parse(""), None);
    }

    /// Each level wears its own keys, and none and ok wear nothing. Tried
    /// on a theme whose every level key differs: in the json warn3, warn4
    /// and withheld have warn2's values, and reading warn2's keys for them
    /// would pass on the real themes.
    #[test]
    fn each_level_wears_its_own_keys_and_none_and_ok_wear_nothing() {
        let mut odd = DARK.clone();
        let mut n = 0u8;
        let mut next = || {
            n += 1;
            Rgba { r: n, g: 0, b: 0, a: 1.0 }
        };
        for k in [
            &mut odd.level_warn1, &mut odd.level_warn1_text, &mut odd.level_warn1_edge, &mut odd.level_warn1_badge,
            &mut odd.level_warn2, &mut odd.level_warn2_text, &mut odd.level_warn2_edge, &mut odd.level_warn2_badge,
            &mut odd.level_warn3, &mut odd.level_warn3_text, &mut odd.level_warn3_edge, &mut odd.level_warn3_badge,
            &mut odd.level_warn4, &mut odd.level_warn4_text, &mut odd.level_warn4_edge, &mut odd.level_warn4_badge,
            &mut odd.level_withheld, &mut odd.level_withheld_text, &mut odd.level_withheld_edge, &mut odd.level_withheld_badge,
            &mut odd.level_killed, &mut odd.level_killed_text, &mut odd.level_killed_edge, &mut odd.level_killed_badge,
        ] {
            *k = next();
        }
        for t in [&DARK, &LIGHT, &odd] {
            let i = |l| level_ink(t, l).unwrap();
            assert_eq!(i(Level::Warn1), LevelInk { base: t.level_warn1, text: t.level_warn1_text, edge: t.level_warn1_edge, badge: t.level_warn1_badge });
            assert_eq!(i(Level::Warn2), LevelInk { base: t.level_warn2, text: t.level_warn2_text, edge: t.level_warn2_edge, badge: t.level_warn2_badge });
            assert_eq!(i(Level::Warn3), LevelInk { base: t.level_warn3, text: t.level_warn3_text, edge: t.level_warn3_edge, badge: t.level_warn3_badge });
            assert_eq!(i(Level::Warn4), LevelInk { base: t.level_warn4, text: t.level_warn4_text, edge: t.level_warn4_edge, badge: t.level_warn4_badge });
            assert_eq!(
                i(Level::Withheld),
                LevelInk { base: t.level_withheld, text: t.level_withheld_text, edge: t.level_withheld_edge, badge: t.level_withheld_badge }
            );
            assert_eq!(i(Level::Killed), LevelInk { base: t.level_killed, text: t.level_killed_text, edge: t.level_killed_edge, badge: t.level_killed_badge });
            assert_eq!(level_ink(t, Level::None), None);
            assert_eq!(level_ink(t, Level::Ok), None);
        }
    }
}
