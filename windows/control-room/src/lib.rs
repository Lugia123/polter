//! The control room's rules that do not need a window
//! (`dev-docs/poltergeist/control-room.md`).
//!
//! | module | what |
//! |---|---|
//! | [`look`] | what it looks like: sizes, colours, durations, light and dark (generated) |
//! | [`snapshot`] | the core's snapshot, read; an unknown glyph is an error |
//! | [`list`] | the rows in their two sections, what each says, where the selection goes |
//! | [`lone`] | the terminals that are in no group and have a row of their own, read; not drawn by this host yet |
//! | [`layout`] | where everything in the list panel is; the chip's spring |
//! | [`pulse`] | which waiting glyph breathes; what a window tab carries and whether it is drawn |
//! | [`act`] | the person's acts as requests to the core, what a refusal says, when looking marks a group seen |
//! | [`lend`] | which terminal is shown on the right, and what happens to it when anything changes |
//! | [`reach`] | what can still be done with no terminal in front: which actions, and which key is which |
//! | [`rules`] | the control room's tab: one in the application, where it opens, what closing it involves |
//! | [`slide`] | the selection chip's move from one place to the next, a frame at a time, and when it is over |
//! | [`chrome`] | light or dark for a terminal window, from its terminal's background; the strip's ground |
//! | [`tabstrip`] | the window tab strip's track and the chip on the selected tab, in whole pixels |
//! | [`scene`] | everything the panel draws, as a list of rectangles, words and glyphs for a host to paint |
//! | [`pane`] | which frame a pane of a split terminal tab wears, where it and the terminal in it go, and what it draws |
//! | [`glyph`] | the four status glyphs as shapes on the design's artboard |
//! | [`json`] | just enough JSON for the above |
//!
//! **Nothing in here decides what the control room says.** Which rows there
//! are, their order, which need the person, how many, which glyph -- all of
//! that arrives worked out in the snapshot, and a line here that compared a
//! kind or counted rows would be the host deciding it a second time.
//! `tools/control-room-hosts-do-not-decide.py` reads this crate for exactly
//! that, and `tools/control-room-hosts-agree.py` holds what it draws to what
//! the macOS host draws from the same snapshot.

/// Marks a string for the translation template without looking it up: the
/// host translates it where it is shown. `src/build/GhosttyI18n.zig` reads
/// this crate for string literals inside `n_(…)`; one that is not marked is
/// never extracted, and is then English on every machine with nothing to
/// say why. The same name and meaning as the host's `i18n::n_`.
pub const fn n_(s: &'static str) -> &'static str {
    s
}

pub mod act;
pub mod alert;
pub mod chrome;
pub mod glyph;
pub mod hud;
pub mod json;
pub mod layout;
pub mod lend;
pub mod list;
pub mod lone;
pub mod look;
pub mod pane;
pub mod pulse;
pub mod quota;
pub mod reach;
pub mod rules;
pub mod scene;
pub mod slide;
pub mod snapshot;
pub mod stackstrip;
pub mod tabstrip;
pub mod toast;

#[cfg(test)]
mod fixture_tests;

#[cfg(test)]
mod tests {
    use super::look;

    // `look.rs` is generated, and `tools/the-control-room-look-is-one-set.py`
    // holds it to the data. These hold what a host will lean on: that asking
    // for a theme gets that theme, and that the two are not one table twice.

    #[test]
    fn asking_for_dark_gets_dark() {
        assert!(look::theme(true).dark);
        assert!(!look::theme(false).dark);
        assert_eq!(*look::theme(true), look::DARK);
        assert_eq!(*look::theme(false), look::LIGHT);
    }

    #[test]
    fn the_two_themes_differ_where_it_shows() {
        assert_ne!(look::LIGHT.text, look::DARK.text);
        assert_ne!(look::LIGHT.terminal_background, look::DARK.terminal_background);
        assert_ne!(look::LIGHT.selection_tint, look::DARK.selection_tint);
    }

    #[test]
    fn nothing_is_set_below_the_smallest_size() {
        let sizes = [look::font::BODY, look::font::GROUP_NAME];
        assert!(look::font::MIN >= 13.0);
        assert!(sizes.iter().all(|s| *s >= look::font::MIN));
    }

    #[test]
    fn a_dark_status_word_is_red_only_where_the_table_says() {
        // The choice lives in the data (`text_on`); a host reads these fields
        // and never compares a surface itself.
        let d = look::DARK;
        assert_eq!(d.problem_text_on_row, d.problem_text);
        assert_eq!(d.problem_text_on_row_selected, d.text);
        assert_eq!(d.problem_text_on_supervisor_bar, d.text);
        let l = look::LIGHT;
        assert_eq!(l.problem_text_on_row_selected, l.problem_text);
    }

    #[test]
    fn what_is_tentative_is_listed() {
        assert!(look::TENTATIVE.contains(&"stack_tab.inset"));
        assert!(look::TENTATIVE.contains(&"text_on.problem_text"));
    }
}
