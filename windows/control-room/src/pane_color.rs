//! The colour a person gives a pane (task 1700, `pane-color-interface.md`
//! §1.1), and which of the look's colours each one is.
//!
//! **Nine colours, and none is not one of them**: a pane with no colour set
//! is `None` of an `Option<Color>`, so nothing can ask what "none" looks
//! like. The core's `ghostty_poltergeist_pane_color_e` is the palette with
//! none at 0, so a colour's value there is its place in [`Color::ALL`] plus
//! one ([`Color::from_c`]).
//!
//! **The colour set is not always the colour shown**: a supervisor with
//! none set shows purple ([`shown`]). That rule is here and in the core's
//! `Bus.shownColor`, and nowhere else.

use crate::look::{Rgba, Theme};
use crate::snapshot::Pane as Wears;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Blue,
    Purple,
    Pink,
    Red,
    Orange,
    Yellow,
    Green,
    Teal,
    Graphite,
}

impl Color {
    /// In the palette's order, after none.
    pub const ALL: [Color; 9] =
        [Color::Blue, Color::Purple, Color::Pink, Color::Red, Color::Orange, Color::Yellow, Color::Green, Color::Teal, Color::Graphite];

    /// The colour the core's enum value `c` is: none for 0, and nothing a
    /// value outside the enum is either -- `None` both, which the caller
    /// that reads the core tells apart before it gets here.
    pub fn from_c(c: usize) -> Option<Color> {
        c.checked_sub(1).and_then(|i| Color::ALL.get(i).copied())
    }

    /// Its value in the core's enum: one past its place here.
    pub fn to_c(self) -> usize {
        Color::ALL.iter().position(|c| *c == self).map_or(0, |i| i + 1)
    }

    /// The word a file, a tool and a binding action write for it.
    pub fn name(self) -> &'static str {
        match self {
            Color::Blue => "blue",
            Color::Purple => "purple",
            Color::Pink => "pink",
            Color::Red => "red",
            Color::Orange => "orange",
            Color::Yellow => "yellow",
            Color::Green => "green",
            Color::Teal => "teal",
            Color::Graphite => "graphite",
        }
    }

    /// The colour a file or a tool names; `None` for "none" and for a
    /// word that is no colour -- a caller that must tell those apart asks
    /// for "none" first.
    pub fn from_name(name: &str) -> Option<Color> {
        Color::ALL.into_iter().find(|c| c.name() == name)
    }

    /// The menu's word for it, an English msgid (`pane-color-interface.md`
    /// §6 strings).
    pub fn label(self) -> &'static str {
        match self {
            Color::Blue => crate::n_("Blue"),
            Color::Purple => crate::n_("Purple"),
            Color::Pink => crate::n_("Pink"),
            Color::Red => crate::n_("Red"),
            Color::Orange => crate::n_("Orange"),
            Color::Yellow => crate::n_("Yellow"),
            Color::Green => crate::n_("Green"),
            Color::Teal => crate::n_("Teal"),
            Color::Graphite => crate::n_("Graphite"),
        }
    }

    /// The dot: on a tab, before a name on a stack's tab, round a pane with
    /// no frames, in the menu -- and the flag on a tab.
    pub fn ink(self, theme: &Theme) -> Rgba {
        match self {
            Color::Blue => theme.pane_blue,
            Color::Purple => theme.pane_purple,
            Color::Pink => theme.pane_pink,
            Color::Red => theme.pane_red,
            Color::Orange => theme.pane_orange,
            Color::Yellow => theme.pane_yellow,
            Color::Green => theme.pane_green,
            Color::Teal => theme.pane_teal,
            Color::Graphite => theme.pane_graphite,
        }
    }

    /// The ground of its badge at the left end of a pane's title.
    pub fn badge(self, theme: &Theme) -> Rgba {
        match self {
            Color::Blue => theme.pane_blue_badge,
            Color::Purple => theme.pane_purple_badge,
            Color::Pink => theme.pane_pink_badge,
            Color::Red => theme.pane_red_badge,
            Color::Orange => theme.pane_orange_badge,
            Color::Yellow => theme.pane_yellow_badge,
            Color::Green => theme.pane_green_badge,
            Color::Teal => theme.pane_teal_badge,
            Color::Graphite => theme.pane_graphite_badge,
        }
    }

    /// What is written on its badge: the mark and the word.
    pub fn badge_text(self, theme: &Theme) -> Rgba {
        match self {
            Color::Blue => theme.pane_blue_badge_text,
            Color::Purple => theme.pane_purple_badge_text,
            Color::Pink => theme.pane_pink_badge_text,
            Color::Red => theme.pane_red_badge_text,
            Color::Orange => theme.pane_orange_badge_text,
            Color::Yellow => theme.pane_yellow_badge_text,
            Color::Green => theme.pane_green_badge_text,
            Color::Teal => theme.pane_teal_badge_text,
            Color::Graphite => theme.pane_graphite_badge_text,
        }
    }
}

/// The colour a pane is drawn in: the one set, or purple for a supervisor
/// with none set; none for anything else with none set.
pub fn shown(set: Option<Color>, wears: Wears) -> Option<Color> {
    set.or((wears == Wears::Supervisor).then_some(Color::Purple))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look;

    #[test]
    fn the_core_s_values_are_the_palette_with_none_at_0() {
        assert_eq!(Color::from_c(0), None);
        assert_eq!(Color::from_c(10), None);
        for (i, c) in Color::ALL.iter().enumerate() {
            assert_eq!(Color::from_c(i + 1), Some(*c));
            assert_eq!(c.to_c(), i + 1);
        }
        assert_eq!(Color::from_c(2), Some(Color::Purple), "purple is 2, as in TerminalTabColor");
    }

    #[test]
    fn a_supervisor_with_none_set_is_purple_and_nobody_else_is_given_one() {
        assert_eq!(shown(None, Wears::Supervisor), Some(Color::Purple));
        assert_eq!(shown(Some(Color::Orange), Wears::Supervisor), Some(Color::Orange));
        assert_eq!(shown(None, Wears::Worker), None);
        assert_eq!(shown(None, Wears::Plain), None);
        assert_eq!(shown(Some(Color::Teal), Wears::Plain), Some(Color::Teal));
    }

    /// Every colour has three looks of its own in both themes: a palette
    /// that drew two colours the same would be one colour less.
    #[test]
    fn no_two_colours_look_the_same() {
        for dark in [false, true] {
            let t = look::theme(dark);
            for (i, a) in Color::ALL.iter().enumerate() {
                for b in &Color::ALL[i + 1..] {
                    assert_ne!(a.ink(t), b.ink(t), "{a:?} and {b:?} dark={dark}");
                }
            }
        }
    }
}
