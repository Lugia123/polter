//! The find bar's counter, as text.
//!
//! **Why this is its own file.** Nothing below needs Win32, and that is the
//! point: `polter-host` only builds for a Windows target, so a unit test
//! inside `search.rs` runs nowhere on the machine the port is written on
//! (`dev-docs/windows/development.md` §4.0). A rule about what a number means
//! is exactly the kind that breaks quietly, so it is kept apart where a test
//! runs against the same bytes. `search.rs` is the only caller.

/// How the counter is toned, so the caller names the colour once instead of
/// repeating the same match a second time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Tone {
    /// The core has not answered yet, or it gave a total with no selection.
    Dim,
    /// The core answered that nothing matched.
    None,
    /// A selection out of a total.
    Text,
}

/// The counter as the bar shows it, and in which tone.
///
/// **`selected` is zero-based** -- the core's `0` is the first match -- and a
/// counter is read by people, so it goes out one-based. GTK's overlay adds
/// the one in `closureMatchLabel`, and the macOS host does it in
/// `SurfaceSearchOverlay`; Windows painted the core's number unchanged, so
/// the first match read `0/30` (task 3239). A total of zero keeps its own
/// `0/0`: that is not a selection, and adding one to a selection that does
/// not exist would invent a match (task 1791).
pub(crate) fn counter_label(total: Option<i64>, selected: Option<i64>) -> (String, Tone) {
    match (total, selected) {
        (None, _) => (String::new(), Tone::Dim),
        (Some(0), _) => ("0/0".to_string(), Tone::None),
        (Some(t), Some(s)) => (format!("{}/{}", s + 1, t), Tone::Text),
        (Some(t), None) => (format!("-/{}", t), Tone::Dim),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Task 3239: `0` from the core is the first match, so the bar reads
    /// `1/30`. The last match is the total, not one past it.
    #[test]
    fn the_core_count_is_shown_one_based() {
        let (first, tone) = counter_label(Some(30), Some(0));
        assert_eq!(first, "1/30");
        assert_eq!(tone, Tone::Text);

        let (last, _) = counter_label(Some(30), Some(29));
        assert_eq!(last, "30/30");
    }

    /// The three other states keep the shape task 1791 established; moving
    /// the selected index to one-based must not shift them (task 3239).
    #[test]
    fn a_state_that_is_not_a_selection_is_not_shifted() {
        let (unanswered, tone) = counter_label(None, None);
        assert_eq!(unanswered, "");
        assert_eq!(tone, Tone::Dim);

        let (none, tone) = counter_label(Some(0), Some(0));
        assert_eq!(none, "0/0");
        assert_eq!(tone, Tone::None);

        let (no_selection, tone) = counter_label(Some(7), None);
        assert_eq!(no_selection, "-/7");
        assert_eq!(tone, Tone::Dim);
    }
}
