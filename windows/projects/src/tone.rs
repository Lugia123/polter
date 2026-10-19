//! The colour a project is given when it has none (task 1796): the one of
//! eight that the other projects use least, ties going to the earlier in
//! [`ORDER`]. Purple is not one of them -- it is a supervisor's -- so a
//! project never shows the colour that says "this pane supervises".
//!
//! The macOS host has the same rule as `ProjectTone.swift`;
//! `tools/control-room-hosts-agree.py` holds the two to one table.

use polter_projectfile::PaneColor;

/// The order a project's colour is offered and given in: the design's
/// (task 1796 v2), so the first projects are the easiest to tell apart.
pub const ORDER: [PaneColor; 8] = [
    PaneColor::Blue,
    PaneColor::Orange,
    PaneColor::Green,
    PaneColor::Pink,
    PaneColor::Teal,
    PaneColor::Yellow,
    PaneColor::Red,
    PaneColor::Graphite,
];

/// The colour for a new project, given the colours the others have. A
/// colour not in [`ORDER`] (none, purple) counts for nothing.
pub fn pick(used: &[PaneColor]) -> PaneColor {
    let count = |c: PaneColor| used.iter().filter(|u| **u == c).count();
    // min_by_key keeps the first of equal keys, which is ORDER's tie-break.
    ORDER.into_iter().min_by_key(|c| count(*c)).unwrap_or(PaneColor::Blue)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_used_is_blue_and_the_order_follows_after() {
        let mut used = Vec::new();
        for want in ORDER {
            let got = pick(&used);
            assert_eq!(got, want, "after {used:?}");
            used.push(got);
        }
        // Every one once: round again from the start.
        assert_eq!(pick(&used), PaneColor::Blue);
    }

    #[test]
    fn the_least_used_wins_and_ties_go_to_the_earlier() {
        use PaneColor::*;
        assert_eq!(pick(&[Blue, Blue, Orange]), Green);
        assert_eq!(pick(&[Blue, Orange, Green, Pink, Teal, Yellow, Red, Graphite, Blue]), Orange);
        assert_eq!(pick(&[Orange]), Blue);
        assert_eq!(pick(&[Purple, Purple, None]), Blue, "purple and none are not a project's and count for nothing");
    }

    #[test]
    fn a_project_may_be_every_pane_colour_but_none_and_purple() {
        let left: Vec<PaneColor> = PaneColor::ALL.into_iter().filter(|c| !ORDER.contains(c)).collect();
        assert_eq!(left, vec![PaneColor::None, PaneColor::Purple]);
        // And the file's reader agrees.
        for c in PaneColor::ALL {
            assert_eq!(polter_projectfile::project_color(c.name()).is_some(), ORDER.contains(&c), "{c:?}");
        }
    }
}
