//! The control room's rules that do not need a window
//! (`dev-docs/poltergeist/control-room.md`).
//!
//! | module | what |
//! |---|---|
//! | [`look`] | what it looks like: sizes, colours, durations, light and dark (generated) |

pub mod look;

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
        let sizes = [look::font::BODY, look::font::GROUP_NAME, look::font::MINUTES];
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
