//! The tabs over a pane that holds several terminals, one in front of the
//! rest: where each tab is and how wide (`dev-docs/poltergeist/
//! control-room.md`, 12.6.2, "the look"; the design's `06-panes` and
//! `07-tab-corners`).
//!
//! **Nothing draws this and nothing can make a stack yet**: the split tree
//! has none on either host. This is the same arithmetic as the macOS
//! host's `PaneStackStripLayout`, held to the same answers by
//! `tools/control-room-hosts-agree.py`, so that when the Windows host does
//! draw a strip it is the same strip.
//!
//! **The rule, in the order it gives way:**
//!
//!  1. Every tab is as wide as its name wants.
//!  2. When they do not all fit, the widest are cut to one common width --
//!     the long names give way first and the short are left whole -- down
//!     to `min_width` and no further. The tab in front is not cut.
//!  3. When they do not fit at that either, the ones there is no room for
//!     go behind a `more` button at the right end of the tabs. The tab in
//!     front is never one of them. The tabs that stay then share the room
//!     there is by rule 2.
//!  4. The status at the right end gives way before the tab in front
//!     does; and a tab in front that does not fit even alone is cut to
//!     what there is.
//!
//! Lengths are points, measured from the frame's content edge.

use crate::look::{side, stack_tab as t};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tab {
    /// Which member this is: an index into the stack.
    pub member: usize,
    pub x: f64,
    pub width: f64,
    pub current: bool,
    /// A hairline at this tab's left edge: between two tabs neither of
    /// which is in front.
    pub separator_before: bool,
    /// Less than the tab wanted: its name ends in an ellipsis.
    pub squeezed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    /// The tabs that are drawn, in order.
    pub tabs: Vec<Tab>,
    /// The members behind `more`, in order.
    pub hidden: Vec<usize>,
    /// Where `more` starts; none when every tab is drawn.
    pub more_x: Option<f64>,
    /// Where the plus starts.
    pub add_x: f64,
    /// Where the status at the right end starts and ends; none when there
    /// is no room for it or nothing to say.
    pub status: Option<(f64, f64)>,
}

/// How wide a tab's name wants it with no font to measure by: so many cells
/// of `nominal_cell_width`, a wide character two, between the tab's
/// paddings, and room for its glyph when it has one.
pub fn nominal_width(name: &str, glyph: bool) -> f64 {
    let cells: usize = name.chars().map(|c| if c as u32 >= 0x2E80 { 2 } else { 1 }).sum();
    let mut w = 2.0 * t::PADDING_X + cells as f64 * t::NOMINAL_CELL_WIDTH;
    if glyph {
        w += t::GAP + side::GLYPH;
    }
    w
}

/// `wants` with the widest cut to one common width so that they add up to
/// `total`, and nothing that was wider than `least` cut below it. The
/// caller has seen to it that they fit at `least`.
pub fn capped(wants: &[f64], total: f64, least: f64) -> Vec<f64> {
    // Every tab starts out as one that will be cut. An even share of the
    // room among those is worked out; any that wants no more than its share
    // is left whole, which leaves more for the rest, so the share is worked
    // out again -- until none of them moves.
    let mut whole = vec![false; wants.len()];
    let mut ceiling = f64::MAX;
    loop {
        let left = total - wants.iter().zip(&whole).filter(|(_, w)| **w).map(|(v, _)| *v).sum::<f64>();
        let cut = whole.iter().filter(|w| !**w).count();
        if cut == 0 {
            break;
        }
        let share = left / cut as f64;
        let mut moved = false;
        for i in 0..wants.len() {
            if !whole[i] && wants[i] <= share {
                whole[i] = true;
                moved = true;
            }
        }
        if !moved {
            // Whole points, so that two hosts adding the same numbers get
            // the same tabs.
            ceiling = least.max(share.floor());
            break;
        }
    }
    wants.iter().map(|w| w.min(ceiling)).collect()
}

/// `wants` is how wide each tab's body wants to be, in the stack's order
/// (a host's measurement); `current` is which is in front; `width` is the
/// strip's, between the content's edges; `status` is how wide the status
/// at the right end is, 0 for none.
pub fn layout(wants: &[f64], current: usize, width: f64, status: f64) -> Layout {
    layout_with(wants, current, width, status, t::MIN_WIDTH)
}

/// The member whose glyph `more` carries: the first of `urgent` -- the
/// members that have a glyph to show, **in the core's order, most pressing
/// first** -- that is behind it. None when nothing is behind `more`, or
/// nothing behind it has a glyph. A walk down a list and a test of
/// membership: nothing here ranks one glyph over another.
pub fn behind_more(layout: &Layout, urgent: &[usize]) -> Option<usize> {
    urgent.iter().copied().find(|i| layout.hidden.contains(i))
}

/// `layout`, with the least a tab is cut to given rather than read from
/// the table: for pictures of the other candidate.
pub fn layout_with(wants: &[f64], current: usize, width: f64, status: f64, min_width: f64) -> Layout {
    let front = if current < wants.len() { current } else { 0 };
    let room = |status: f64, more: bool| {
        let mut r = width - t::INSET - t::ADD_BUTTON - t::TRAILING;
        if status > 0.0 {
            r -= t::STATUS_GAP + status;
        }
        if more {
            r -= t::MORE_BUTTON;
        }
        r
    };

    // The status gives way before the tab in front does.
    let front_wants = wants.get(front).copied().unwrap_or(0.0);
    let said = if status > 0.0 && room(status, false) >= front_wants { status } else { 0.0 };
    let fits = room(said, false);

    let mut widths = wants.to_vec();
    let mut shown: Vec<usize> = (0..wants.len()).collect();
    let mut hidden = Vec::new();

    if wants.iter().sum::<f64>() > fits {
        let least: Vec<f64> =
            wants.iter().enumerate().map(|(i, w)| if i == front { *w } else { w.min(min_width) }).collect();
        if least.iter().sum::<f64>() <= fits {
            let mut others = wants.to_vec();
            others.remove(front);
            let mut cut = capped(&others, fits - front_wants, min_width);
            cut.insert(front, front_wants);
            widths = cut;
        } else {
            // Not even at the least: some go behind `more`.
            widths = least.clone();
            let fits_with_more = room(said, true);
            let mut taken = Vec::new();
            let mut used = least[front];
            for i in (0..wants.len()).filter(|i| *i != front) {
                if used + least[i] > fits_with_more {
                    break;
                }
                taken.push(i);
                used += least[i];
            }
            // In the stack's order, the one in front where it belongs.
            shown = (0..wants.len()).filter(|i| *i == front || taken.contains(i)).collect();
            hidden = (0..wants.len()).filter(|i| !shown.contains(i)).collect();
            // Too wide even alone: it is cut to what there is.
            widths[front] = least[front].min(fits_with_more).max(0.0);
            // Those that stayed were counted at their least; what room is
            // left over goes back to them, the widest cut first as before.
            let stayed: Vec<usize> = shown.iter().copied().filter(|i| *i != front).collect();
            let back = capped(&stayed.iter().map(|i| wants[*i]).collect::<Vec<_>>(), fits_with_more - widths[front], min_width);
            for (n, i) in stayed.iter().enumerate() {
                widths[*i] = back[n];
            }
        }
    }

    let mut x = t::INSET;
    let mut tabs = Vec::new();
    for (place, i) in shown.iter().enumerate() {
        let before = if place > 0 { Some(shown[place - 1]) } else { None };
        tabs.push(Tab {
            member: *i,
            x,
            width: widths[*i],
            current: *i == front,
            separator_before: before.is_some() && *i != front && before != Some(front),
            squeezed: widths[*i] < wants[*i],
        });
        x += widths[*i];
    }
    let more_x = if hidden.is_empty() {
        None
    } else {
        let at = x;
        x += t::MORE_BUTTON;
        Some(at)
    };
    let end = width - t::TRAILING;
    Layout { tabs, hidden, more_x, add_x: x, status: if said > 0.0 { Some((end - said, end)) } else { None } }
}

/// The cases both hosts lay out for `tools/control-room-hosts-agree.py`:
/// what each tab wants, which is in front, the strip's width, the status's.
/// The macOS side has the same list.
pub const CASES: &[(&[f64], usize, f64, f64)] = &[
    (&[], 0, 400.0, 0.0),
    (&[60.0], 0, 300.0, 0.0),
    (&[100.0, 60.0, 60.0], 1, 400.0, 50.0),
    (&[60.0, 60.0, 60.0, 60.0], 0, 600.0, 0.0),
    (&[60.0, 60.0, 60.0, 60.0], 2, 600.0, 0.0),
    (&[60.0, 60.0, 60.0, 60.0], 3, 600.0, 0.0),
    (&[200.0, 60.0, 200.0, 60.0], 1, 460.0, 0.0),
    (&[200.0, 60.0, 200.0, 60.0], 0, 460.0, 0.0),
    (&[200.0, 72.0, 200.0, 200.0], 1, 336.0, 0.0),
    (&[200.0, 72.0, 200.0, 200.0], 1, 335.0, 0.0),
    (&[100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0], 6, 400.0, 0.0),
    (&[100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0], 1, 400.0, 0.0),
    (&[120.0, 80.0], 0, 200.0, 60.0),
    (&[120.0, 80.0], 0, 330.0, 60.0),
    (&[60.0, 60.0], 7, 400.0, 0.0),
    (&[94.0, 70.0, 48.0, 126.0, 56.0, 150.0, 78.0], 3, 520.0, 70.0),
    (&[94.0, 70.0, 48.0, 126.0, 56.0, 150.0, 78.0, 94.0, 56.0, 142.0, 78.0, 56.0], 9, 520.0, 70.0),
    (&[300.0], 0, 100.0, 40.0),
];

#[cfg(test)]
mod tests {
    use super::*;

    fn xs(l: &Layout) -> Vec<f64> {
        l.tabs.iter().map(|t| t.x).collect()
    }
    fn widths(l: &Layout) -> Vec<f64> {
        l.tabs.iter().map(|t| t.width).collect()
    }
    fn members(l: &Layout) -> Vec<usize> {
        l.tabs.iter().map(|t| t.member).collect()
    }

    #[test]
    fn the_numbers_these_tests_add_up_with() {
        assert_eq!((t::INSET, t::ADD_BUTTON, t::TRAILING, t::STATUS_GAP, t::MORE_BUTTON, t::MIN_WIDTH), (20.0, 28.0, 12.0, 8.0, 60.0, 104.0));
    }

    #[test]
    fn tabs_that_fit_are_as_wide_as_they_want_one_after_another_from_the_inset() {
        let l = layout(&[100.0, 60.0, 60.0], 1, 400.0, 50.0);
        assert_eq!(xs(&l), [20.0, 120.0, 180.0]);
        assert_eq!(widths(&l), [100.0, 60.0, 60.0]);
        assert!(l.tabs.iter().all(|t| !t.squeezed));
        assert!(l.hidden.is_empty());
        assert_eq!(l.more_x, None);
        assert_eq!(l.add_x, 240.0);
        assert_eq!(l.status, Some((338.0, 388.0)));
    }

    #[test]
    fn a_hairline_stands_only_between_two_tabs_neither_of_which_is_in_front() {
        let seps = |cur| layout(&[60.0; 4], cur, 600.0, 0.0).tabs.iter().map(|t| t.separator_before).collect::<Vec<_>>();
        assert_eq!(seps(0), [false, false, true, true]);
        assert_eq!(seps(2), [false, true, false, false]);
        assert_eq!(seps(3), [false, true, true, false]);
    }

    #[test]
    fn when_they_do_not_fit_the_widest_are_cut_to_one_width_and_the_short_left_whole() {
        let l = layout(&[200.0, 60.0, 200.0, 60.0], 1, 460.0, 0.0);
        assert_eq!(widths(&l), [140.0, 60.0, 140.0, 60.0]);
        assert_eq!(l.add_x, 420.0);
    }

    #[test]
    fn the_tab_in_front_is_not_cut() {
        let l = layout(&[200.0, 60.0, 200.0, 60.0], 0, 500.0, 0.0);
        assert_eq!(widths(&l), [200.0, 60.0, 120.0, 60.0]);
    }

    #[test]
    fn cutting_stops_at_the_least_width_and_the_least_can_be_the_other_candidate() {
        let fits = layout(&[200.0, 72.0, 200.0, 200.0], 1, 444.0, 0.0);
        assert_eq!(widths(&fits), [104.0, 72.0, 104.0, 104.0]);
        assert!(fits.hidden.is_empty());
        assert!(!layout(&[200.0, 72.0, 200.0, 200.0], 1, 443.0, 0.0).hidden.is_empty());
        // At 68 the same four still fit where at 104 they did not.
        assert_eq!(widths(&layout_with(&[200.0, 72.0, 200.0, 200.0], 1, 336.0, 0.0, 68.0)), [68.0, 72.0, 68.0, 68.0]);
        assert!(!layout(&[200.0, 72.0, 200.0, 200.0], 1, 336.0, 0.0).hidden.is_empty());
    }

    #[test]
    fn what_there_is_no_room_for_goes_behind_more_and_the_one_in_front_never_does() {
        let l = layout(&[150.0; 8], 6, 400.0, 0.0);
        assert_eq!(members(&l), [0, 6]);
        // Counted at 104 to see whether it fits; given the 130 there is.
        assert_eq!(widths(&l), [130.0, 150.0]);
        assert_eq!(l.hidden, [1, 2, 3, 4, 5, 7]);
        assert_eq!((l.more_x, l.add_x), (Some(300.0), 360.0));
        // `more` has its own 60: a second tab would fit without it.
        assert_eq!(members(&layout(&[150.0; 8], 6, 434.0, 0.0)), [0, 6]);
        // And the tabs keep the stack's order.
        let second = layout(&[150.0; 8], 1, 520.0, 0.0);
        assert_eq!(members(&second), [0, 1, 2]);
        assert_eq!(widths(&second), [125.0, 150.0, 125.0]);
    }

    #[test]
    fn more_carries_the_first_of_the_cores_order_that_is_behind_it() {
        let l = layout(&[150.0; 8], 6, 400.0, 0.0);
        assert_eq!(behind_more(&l, &[6, 4, 0, 2]), Some(4));
        // The order is the core's and is not second-guessed.
        assert_eq!(behind_more(&l, &[0, 2, 4]), Some(2));
        assert_eq!(behind_more(&l, &[6, 0]), None);
        assert_eq!(behind_more(&l, &[]), None);
        let roomy = layout(&[100.0, 60.0, 60.0], 1, 400.0, 0.0);
        assert_eq!(behind_more(&roomy, &[0, 1, 2]), None);
    }

    #[test]
    fn the_status_gives_way_before_the_tab_in_front_and_then_the_tab_itself() {
        let l = layout(&[120.0, 150.0], 0, 200.0, 60.0);
        assert_eq!(l.status, None);
        assert_eq!((members(&l), widths(&l), l.hidden.clone()), (vec![0], vec![80.0], vec![1]));
        let roomy = layout(&[120.0, 80.0], 0, 330.0, 60.0);
        assert_eq!(roomy.status, Some((258.0, 318.0)));
        assert_eq!(widths(&roomy), [120.0, 80.0]);
    }

    #[test]
    fn a_current_that_is_not_one_of_them_is_the_first_and_no_tabs_is_only_the_plus() {
        let l = layout(&[60.0, 60.0], 7, 400.0, 0.0);
        assert_eq!(l.tabs.iter().map(|t| t.current).collect::<Vec<_>>(), [true, false]);
        let none = layout(&[], 0, 400.0, 0.0);
        assert!(none.tabs.is_empty());
        assert_eq!(none.add_x, 20.0);
    }

    #[test]
    fn a_tabs_nominal_width_is_its_cells_its_paddings_and_its_glyph() {
        assert_eq!(nominal_width("api", false), 48.0);
        assert_eq!(nominal_width("api", true), 70.0);
        assert_eq!(nominal_width("任务", false), 56.0);
    }
}
