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
//!  3. When they do not fit at that either, **they scroll sideways** (task
//!     1582): every tab keeps its least width, the tabs together are wider
//!     than the room for them, and the room is a window onto them. They used
//!     to go behind a `more` menu, which hid who was there.
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
    /// Every tab, in order, at its place among the others: `x` is where it
    /// stands when the tabs are not scrolled.
    pub tabs: Vec<Tab>,
    /// How wide the room for the tabs is: the window onto them.
    pub viewport: f64,
    /// How wide the tabs are together. Wider than `viewport` is a strip
    /// that scrolls.
    pub content: f64,
    /// Where the plus starts: after the tabs, or after the room for them
    /// when they scroll.
    pub add_x: f64,
    /// Where the status at the right end starts and ends; none when there
    /// is no room for it or nothing to say.
    pub status: Option<(f64, f64)>,
}

impl Layout {
    /// Whether the tabs are wider than the room for them.
    pub fn scrolls(&self) -> bool {
        self.content > self.viewport
    }

    /// The furthest the tabs scroll.
    pub fn max_offset(&self) -> f64 {
        (self.content - self.viewport).max(0.0)
    }
}

/// The members waiting out of sight, scrolled at `offset`: on each side,
/// the first of `urgent` -- the core's order, most pressing first -- whose
/// tab is not wholly in view that way. What the strip draws at that end so
/// that a terminal waiting off the edge is not waiting unseen (what `more`
/// used to carry). None on a side with none.
pub fn beyond(layout: &Layout, urgent: &[usize], offset: f64) -> (Option<usize>, Option<usize>) {
    let offset = offset.clamp(0.0, layout.max_offset());
    let side = |test: &dyn Fn(&Tab) -> bool| {
        urgent.iter().copied().find(|m| layout.tabs.iter().find(|t| t.member == *m).is_some_and(test))
    };
    (
        side(&|t: &Tab| t.x - t::INSET < offset),
        side(&|t: &Tab| t.x - t::INSET + t.width > offset + layout.viewport),
    )
}

/// How far to scroll the tabs, from `offset`, so that the tab of `member`
/// is wholly in view -- the least move that does it, and none when it
/// already is (task 1582: the tab in front is scrolled into view, as the
/// window's own tabs do). `offset` is how far the tabs are scrolled now,
/// 0 for not at all.
///
/// **In view is clear of the fades** (task 1594): an end with more tabs
/// past it fades out over `scroll_fade` of the window, and a tab brought
/// only to the window's edge stood under it -- its name's end and its close
/// button faded away on a real machine. So the tab is brought `scroll_fade`
/// inside the edge it comes in at. At the very start and end there is no
/// fade, and the clamp leaves the first and the last tab at the edge.
pub fn revealing(layout: &Layout, member: usize, offset: f64) -> f64 {
    let offset = offset.clamp(0.0, layout.max_offset());
    let Some(tab) = layout.tabs.iter().find(|t| t.member == member) else {
        return offset;
    };
    let fade = t::SCROLL_FADE;
    let start = tab.x - t::INSET;
    let end = start + tab.width;
    let to = if start < offset + fade {
        start - fade
    } else if end > offset + layout.viewport - fade {
        end - layout.viewport + fade
    } else {
        offset
    };
    to.clamp(0.0, layout.max_offset())
}

/// Where the tabs are scrolled to when the strip is drawn again, from where
/// they were (`offset`): `changed` is whether the tab in front, the number
/// of tabs or the strip's width changed since, `wheeled` whether the person
/// scrolled them with the wheel since the last such change.
///
/// **Brought into view unless the person has scrolled since** (task 1599).
/// It used to be brought in only when one of the three changed -- and a
/// new terminal's name comes after it is made, so the tab widened, the
/// tabs' end moved on and the tab in front was left half under the fade.
/// Scrolled by the wheel, the tabs stay where they were put until one of
/// the three changes, which clears it (the caller keeps `wheeled`).
pub fn settle(layout: &Layout, member: usize, offset: f64, changed: bool, wheeled: bool) -> f64 {
    if changed || !wheeled {
        revealing(layout, member, offset)
    } else {
        offset.clamp(0.0, layout.max_offset())
    }
}

/// Whether the close button of `member`'s tab is whole inside the window
/// the tabs are seen through, scrolled to `offset`: it sits at the tab's
/// right end inside its padding. Only then is it drawn or pressed.
///
/// **Never over the plus** (task 1600, #1601 W3 on a real machine): the
/// person scrolled the tab in front under the plus, and its close button
/// was drawn on top of the plus.
pub fn close_seen(layout: &Layout, member: usize, offset: f64) -> bool {
    let Some(tab) = layout.tabs.iter().find(|t| t.member == member) else {
        return false;
    };
    let x = tab.x - t::INSET - offset + tab.width - t::PADDING_X - t::CLOSE_BUTTON;
    x >= -0.5 && x + t::CLOSE_BUTTON <= layout.viewport + 0.5
}

/// How wide a tab's name wants it with no font to measure by: so many cells
/// of `nominal_cell_width`, a wide character two, between the tab's
/// paddings, room for its glyph when it has one, and the close button's
/// place, which every tab keeps (task 1582).
pub fn nominal_width(name: &str, glyph: bool) -> f64 {
    let cells: usize = name.chars().map(|c| if c as u32 >= 0x2E80 { 2 } else { 1 }).sum();
    let mut w = 2.0 * t::PADDING_X + cells as f64 * t::NOMINAL_CELL_WIDTH + t::CLOSE_GAP + t::CLOSE_BUTTON;
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

/// `layout`, with the least a tab is cut to given rather than read from
/// the table: for pictures of the other candidate.
pub fn layout_with(wants: &[f64], current: usize, width: f64, status: f64, min_width: f64) -> Layout {
    let front = if current < wants.len() { current } else { 0 };
    let room = |status: f64| {
        let mut r = width - t::INSET - t::ADD_BUTTON - t::TRAILING;
        if status > 0.0 {
            r -= t::STATUS_GAP + status;
        }
        r
    };

    // The status gives way before the tab in front does.
    let front_wants = wants.get(front).copied().unwrap_or(0.0);
    let said = if status > 0.0 && room(status) >= front_wants { status } else { 0.0 };
    let fits = room(said).max(0.0);

    let mut widths = wants.to_vec();
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
            // Not even at the least: every tab at its least, and they
            // scroll. One too wide even alone is cut to the room there is.
            widths = least;
            widths[front] = widths[front].min(fits);
        }
    }

    let mut x = t::INSET;
    let mut tabs = Vec::new();
    for i in 0..wants.len() {
        tabs.push(Tab {
            member: i,
            x,
            width: widths[i],
            current: i == front,
            separator_before: i > 0 && i != front && i - 1 != front,
            squeezed: widths[i] < wants[i],
        });
        x += widths[i];
    }
    // `fold` from 0, not `sum`: the sum of nothing is -0 in Rust, and the
    // other host prints 0 (`control-room-hosts-agree`).
    let content = widths.iter().fold(0.0, |a, w| a + w);
    let end = width - t::TRAILING;
    Layout {
        tabs,
        viewport: fits,
        content,
        add_x: t::INSET + content.min(fits),
        status: if said > 0.0 { Some((end - said, end)) } else { None },
    }
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
        assert_eq!((t::INSET, t::ADD_BUTTON, t::TRAILING, t::STATUS_GAP, t::MIN_WIDTH), (20.0, 28.0, 12.0, 8.0, 104.0));
        assert_eq!((t::CLOSE_BUTTON, t::CLOSE_GAP), (16.0, 4.0));
    }

    #[test]
    fn tabs_that_fit_are_as_wide_as_they_want_one_after_another_from_the_inset() {
        let l = layout(&[100.0, 60.0, 60.0], 1, 400.0, 50.0);
        assert_eq!(xs(&l), [20.0, 120.0, 180.0]);
        assert_eq!(widths(&l), [100.0, 60.0, 60.0]);
        assert!(l.tabs.iter().all(|t| !t.squeezed));
        assert!(!l.scrolls());
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
        assert!(!fits.scrolls());
        assert!(layout(&[200.0, 72.0, 200.0, 200.0], 1, 443.0, 0.0).scrolls());
        // At 68 the same four still fit where at 104 they did not.
        assert_eq!(widths(&layout_with(&[200.0, 72.0, 200.0, 200.0], 1, 336.0, 0.0, 68.0)), [68.0, 72.0, 68.0, 68.0]);
        assert!(layout(&[200.0, 72.0, 200.0, 200.0], 1, 336.0, 0.0).scrolls());
    }

    #[test]
    fn what_there_is_no_room_for_scrolls_and_every_tab_is_still_there() {
        // Task 1582: no tab goes behind a menu. All eight are laid out, at
        // their least, the one in front whole, and the room is a window.
        let l = layout(&[150.0; 8], 6, 400.0, 0.0);
        assert_eq!(members(&l), [0, 1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(widths(&l), [104.0, 104.0, 104.0, 104.0, 104.0, 104.0, 150.0, 104.0]);
        assert_eq!((l.viewport, l.content), (340.0, 878.0));
        assert!(l.scrolls());
        // The plus stands after the room, not after the tabs.
        assert_eq!(l.add_x, 360.0);
    }

    #[test]
    fn a_waiting_terminal_off_an_edge_is_carried_by_that_edge_in_the_cores_order() {
        // Eight at 104 (the seventh 150), a 340 window. Scrolled to 434:
        // tabs 0-3 are off the left (4 is cut at its left), 7 off the right.
        let l = layout(&[150.0; 8], 6, 400.0, 0.0);
        assert_eq!(beyond(&l, &[6, 4, 0, 7], 434.0), (Some(4), Some(7)));
        // The core's order is not second-guessed: 0 before 4.
        assert_eq!(beyond(&l, &[0, 4], 434.0), (Some(0), None));
        // Not scrolled: nothing off the left, and the first of the order
        // that is off the right.
        assert_eq!(beyond(&l, &[1, 5, 3], 0.0), (None, Some(5)));
        assert_eq!(beyond(&l, &[], 434.0), (None, None));
    }

    #[test]
    fn the_tab_in_front_is_scrolled_into_view_by_the_least_move() {
        let l = layout(&[150.0; 8], 6, 400.0, 0.0);
        // Tab 6 runs from 624 to 774 of the tabs; the window is 340 wide.
        // Its end comes to 16 (the fade) inside the window's right edge.
        assert_eq!(revealing(&l, 6, 0.0), 450.0);
        // Already in view, clear of both fades: no move.
        assert_eq!(revealing(&l, 6, 500.0), 500.0);
        // To its left: its start comes to 16 inside the window's left edge.
        assert_eq!(revealing(&l, 1, 500.0), 88.0);
        // Never past either end.
        assert_eq!(revealing(&l, 7, 0.0), 538.0);
        assert_eq!(revealing(&l, 0, 900.0), 0.0);
        // A strip that does not scroll does not move.
        let roomy = layout(&[100.0, 60.0, 60.0], 1, 400.0, 0.0);
        assert_eq!(revealing(&roomy, 2, 0.0), 0.0);
    }

    /// Task 1599: a terminal made in a stack has no name yet; when its name
    /// comes, its tab widens, the tabs' end moves on, and the tab drawn at
    /// the old end stood half under the right-hand fade (a real machine,
    /// #1594 T2). Nothing the strip is keyed on had changed. Until the
    /// person scrolls, the tab in front is kept in view whatever widens.
    #[test]
    fn a_new_tab_whose_name_comes_later_is_still_brought_into_view() {
        // Eleven at 104 and the new one, nameless, at 60: it is in front.
        let mut wants = vec![150.0; 11];
        wants.push(60.0);
        let before = layout(&wants, 11, 400.0, 0.0);
        let first = settle(&before, 11, 0.0, true, false);
        assert_eq!(first, before.max_offset());
        // Its name comes: 60 becomes 200, and nothing else changed.
        wants[11] = 200.0;
        let after = layout(&wants, 11, 400.0, 0.0);
        let then = settle(&after, 11, first, false, false);
        let tab = after.tabs.iter().find(|t| t.member == 11).unwrap();
        let (start, end) = (tab.x - t::INSET - then, tab.x - t::INSET - then + tab.width);
        assert!(start >= 0.0 && end <= after.viewport, "the tab runs {start}..{end} of a {} window", after.viewport);
        // Scrolled by the person: left where they put it, until one of the
        // three changes.
        assert_eq!(settle(&after, 11, 100.0, false, true), 100.0);
        assert_eq!(settle(&after, 11, 100.0, true, true), revealing(&after, 11, 100.0));
    }

    #[test]
    fn the_status_gives_way_before_the_tab_in_front_and_then_the_tab_itself() {
        let l = layout(&[120.0, 150.0], 0, 200.0, 60.0);
        assert_eq!(l.status, None);
        // The room is 140: the one in front whole, the other at its least,
        // and they scroll.
        assert_eq!((widths(&l), l.viewport), (vec![120.0, 104.0], 140.0));
        assert!(l.scrolls());
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
        assert_eq!(nominal_width("api", false), 68.0);
        assert_eq!(nominal_width("api", true), 90.0);
        assert_eq!(nominal_width("任务", false), 76.0);
    }
}
