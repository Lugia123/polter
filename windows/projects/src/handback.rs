//! What a pane restored from a project hands back to the core: the marks a
//! person put on it, which live in the core and not in the host
//! (`pane-color-interface.md` §7.2; task 1700).
//!
//! **The core's first word on a new terminal is the defaults.** It says so
//! from inside `ghostty_surface_new`, before anything has been handed back;
//! a host that took that word as the pane's marks would save the defaults
//! over the file a second later. So a restored pane whose file says
//! something other than the defaults is "not told yet" until these actions
//! have gone, and only what comes back after them is believed
//! (`Marks::told_after`).
//!
//! The seat is the project's own mark and is not handed back.

use polter_projectfile::{PaneColor, SavedLeaf, Workers};

/// The three marks a pane hands back, as the file has them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Marks {
    pub color: PaneColor,
    pub workers: Workers,
    pub shielded: bool,
}

impl Marks {
    /// What a terminal the core has just made is: what its first word says.
    pub const DEFAULT: Marks = Marks { color: PaneColor::None, workers: Workers::Allowed, shielded: false };

    /// The marks of a leaf as read from a file. A leaf `parse_snapshot` hands
    /// back always says; one that does not -- built some other way -- has
    /// nothing to hand back for what it does not say.
    pub fn of(leaf: &SavedLeaf) -> Marks {
        Marks {
            color: leaf.color.unwrap_or(PaneColor::None),
            workers: leaf.workers.unwrap_or(Workers::Allowed),
            shielded: leaf.shielded.unwrap_or(false),
        }
    }

    /// Whether there is anything to hand back. A pane with nothing to hand
    /// back takes the core's first word as it is: it is the truth.
    pub fn is_default(&self) -> bool {
        *self == Marks::DEFAULT
    }

    /// The binding actions that hand these back, one per mark that is not
    /// the default, in a fixed order. Each is idempotent: handing back twice
    /// changes nothing the second time.
    pub fn actions(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.color != PaneColor::None {
            out.push(format!("poltergeist_set_pane_color:{}", self.color.name()));
        }
        if self.workers == Workers::Refused {
            out.push("poltergeist_set_workers:refused".to_string());
        }
        if self.shielded {
            out.push("poltergeist_set_shielded:on".to_string());
        }
        out
    }
}

/// One mark of a pane as the host knows it: not told yet, or told.
///
/// **What turns "not told" into "told" is the core's word arriving after
/// the hand-back has gone**, and nothing else (`accept`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Waiting {
    /// A pane that had nothing to hand back, or whose hand-back has gone:
    /// whatever the core says next is believed.
    No,
    /// A restored pane whose hand-back has not gone yet: what the core says
    /// now is its first word, the defaults, and is not believed.
    ToHandBack(Marks),
}

impl Waiting {
    /// What a pane made from `marks` waits for: nothing when they are the
    /// defaults.
    pub fn for_restored(marks: Marks) -> Waiting {
        if marks.is_default() {
            Waiting::No
        } else {
            Waiting::ToHandBack(marks)
        }
    }

    /// Whether a word from the core, arriving now, is believed.
    pub fn accept(&self) -> bool {
        matches!(self, Waiting::No)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use polter_projectfile::Agent;

    #[test]
    fn only_what_is_not_the_default_is_handed_back_and_in_one_order() {
        assert!(Marks::DEFAULT.actions().is_empty());
        let all = Marks { color: PaneColor::Teal, workers: Workers::Refused, shielded: true };
        assert_eq!(all.actions(), ["poltergeist_set_pane_color:teal", "poltergeist_set_workers:refused", "poltergeist_set_shielded:on"]);
        let one = Marks { shielded: true, ..Marks::DEFAULT };
        assert_eq!(one.actions(), ["poltergeist_set_shielded:on"]);
    }

    #[test]
    fn every_colour_but_none_is_handed_back_by_its_file_name() {
        for c in PaneColor::ALL {
            let got = Marks { color: c, ..Marks::DEFAULT }.actions();
            if c == PaneColor::None {
                assert!(got.is_empty());
            } else {
                assert_eq!(got, [format!("poltergeist_set_pane_color:{}", c.name())]);
            }
        }
    }

    /// The race the whole module is for: a restored pane with marks does not
    /// believe the core's first word; one without does.
    #[test]
    fn a_restored_pane_with_marks_does_not_believe_the_first_word() {
        let marked = SavedLeaf { color: Some(PaneColor::Orange), ..SavedLeaf::plain("/a", Agent::None) };
        let w = Waiting::for_restored(Marks::of(&marked));
        assert!(!w.accept());
        assert_eq!(w, Waiting::ToHandBack(Marks { color: PaneColor::Orange, ..Marks::DEFAULT }));
        assert!(Waiting::for_restored(Marks::of(&SavedLeaf::plain("/a", Agent::None))).accept());
    }
}
