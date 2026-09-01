//! Tests for the split tree.
//!
//! Every one of these runs on the machine the port is written on. That is the
//! point of the crate having no dependencies: a test that can only run on the
//! Windows box is a test nobody checks.

use super::*;

const A: PaneId = 1;
const B: PaneId = 2;
const C: PaneId = 3;
const D: PaneId = 4;

/// `a | b`
fn row() -> Tree {
    Tree::with_pane(A).insert(B, A, NewSplit::Right).unwrap()
}

/// `a | (b | c)` -- three in a row, nested right.
fn row3() -> Tree {
    row().insert(C, B, NewSplit::Right).unwrap()
}

/// ```text
/// +---+---+
/// | a | b |
/// +---+---+
/// | c | d |
/// +---+---+
/// ```
fn grid() -> Tree {
    row()
        .insert(C, A, NewSplit::Down)
        .unwrap()
        .insert(D, B, NewSplit::Down)
        .unwrap()
}

fn approx(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

fn assert_rect(got: Rect, x: f64, y: f64, w: f64, h: f64) {
    assert!(
        approx(got.x, x) && approx(got.y, y) && approx(got.w, w) && approx(got.h, h),
        "expected ({x}, {y}, {w}, {h}), got ({}, {}, {}, {})",
        got.x,
        got.y,
        got.w,
        got.h
    );
}

fn rect_of(tree: &Tree, bounds: Rect, pane: PaneId) -> Rect {
    tree.layout(bounds)
        .into_iter()
        .find(|(p, _)| *p == pane)
        .unwrap_or_else(|| panic!("pane {pane} not in layout"))
        .1
        .rect()
        .unwrap_or_else(|| panic!("pane {pane} is hidden, not placed"))
}

// -- shape -----------------------------------------------------------------

#[test]
fn empty_tree() {
    let t = Tree::new();
    assert!(t.is_empty());
    assert!(!t.is_split());
    assert_eq!(t.len(), 0);
    assert!(t.panes().is_empty());
    assert!(t.layout(Rect::new(0.0, 0.0, 100.0, 100.0)).is_empty());
    assert_eq!(t.path_of(A), None);
}

#[test]
fn single_pane_fills_everything() {
    let t = Tree::with_pane(A);
    assert!(!t.is_empty());
    assert!(!t.is_split());
    assert_eq!(t.panes(), vec![A]);
    assert_eq!(t.path_of(A), Some(vec![]));

    let b = Rect::new(0.0, 0.0, 800.0, 600.0);
    assert_eq!(t.layout(b), vec![(A, Placement::Visible(b))]);
}

#[test]
fn insert_into_missing_pane_is_an_error() {
    assert_eq!(
        Tree::with_pane(A).insert(B, C, NewSplit::Right),
        Err(Error::PaneNotFound)
    );
    assert_eq!(Tree::new().insert(B, A, NewSplit::Right), Err(Error::PaneNotFound));
}

#[test]
fn split_right_puts_the_new_pane_on_the_right() {
    let t = row();
    assert!(t.is_split());
    assert_eq!(t.panes(), vec![A, B]);

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 100.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 100.0, 0.0, 100.0, 100.0);
}

#[test]
fn split_left_puts_the_new_pane_on_the_left() {
    let t = Tree::with_pane(A).insert(B, A, NewSplit::Left).unwrap();
    assert_eq!(t.panes(), vec![B, A]);

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 0.0, 0.0, 100.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 100.0, 0.0, 100.0, 100.0);
}

#[test]
fn split_down_stacks_the_new_pane_below() {
    let t = Tree::with_pane(A).insert(B, A, NewSplit::Down).unwrap();
    assert_eq!(t.panes(), vec![A, B]);

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 200.0, 50.0);
    assert_rect(rect_of(&t, bounds, B), 0.0, 50.0, 200.0, 50.0);
}

#[test]
fn split_up_stacks_the_new_pane_above() {
    let t = Tree::with_pane(A).insert(B, A, NewSplit::Up).unwrap();
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 0.0, 0.0, 200.0, 50.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 50.0, 200.0, 50.0);
}

#[test]
fn splitting_a_pane_only_divides_that_pane() {
    // c is created by splitting b, so it takes half of b's half and a is
    // untouched.
    let t = row3();
    let bounds = Rect::new(0.0, 0.0, 400.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 200.0, 0.0, 100.0, 100.0);
    assert_rect(rect_of(&t, bounds, C), 300.0, 0.0, 100.0, 100.0);
}

#[test]
fn grid_layout() {
    let t = grid();
    assert_eq!(t.len(), 4);

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 100.0, 50.0);
    assert_rect(rect_of(&t, bounds, C), 0.0, 50.0, 100.0, 50.0);
    assert_rect(rect_of(&t, bounds, B), 100.0, 0.0, 100.0, 50.0);
    assert_rect(rect_of(&t, bounds, D), 100.0, 50.0, 100.0, 50.0);
}

#[test]
fn layout_covers_the_bounds_exactly() {
    let bounds = Rect::new(10.0, 20.0, 333.0, 177.0);
    let area: f64 = grid()
        .layout(bounds)
        .iter()
        .filter_map(|(_, p)| p.rect())
        .map(|r| r.w * r.h)
        .sum();
    assert!(approx(area, bounds.w * bounds.h), "panes covered {area}");
}

// -- traversal and addressing ----------------------------------------------

#[test]
fn panes_come_out_in_tree_order() {
    assert_eq!(grid().panes(), vec![A, C, B, D]);
}

#[test]
fn path_and_node_round_trip() {
    let t = grid();
    assert_eq!(t.path_of(A), Some(vec![Branch::Left, Branch::Left]));
    assert_eq!(t.path_of(C), Some(vec![Branch::Left, Branch::Right]));
    assert_eq!(t.path_of(B), Some(vec![Branch::Right, Branch::Left]));
    assert_eq!(t.path_of(D), Some(vec![Branch::Right, Branch::Right]));
    assert_eq!(t.path_of(99), None);

    for pane in t.panes() {
        let path = t.path_of(pane).unwrap();
        assert_eq!(t.node_at(&path), Some(&Node::Leaf(pane)));
    }

    // The empty path is the root, and the root here is a split.
    assert!(matches!(t.node_at(&[]), Some(Node::Split(_))));
    assert_eq!(t.node_at(&[Branch::Left, Branch::Left, Branch::Left]), None);
}

#[test]
fn contains() {
    let t = row();
    assert!(t.contains(A));
    assert!(t.contains(B));
    assert!(!t.contains(C));
}

#[test]
fn leftmost_and_rightmost() {
    let t = grid();
    let root = t.root().unwrap();
    assert_eq!(root.leftmost_leaf(), A);
    assert_eq!(root.rightmost_leaf(), D);
}

#[test]
fn next_and_previous_wrap() {
    let t = grid(); // order: a, c, b, d
    assert_eq!(t.focus_target(Focus::Next, A), Some(C));
    assert_eq!(t.focus_target(Focus::Next, C), Some(B));
    assert_eq!(t.focus_target(Focus::Next, B), Some(D));
    assert_eq!(t.focus_target(Focus::Next, D), Some(A));

    assert_eq!(t.focus_target(Focus::Previous, A), Some(D));
    assert_eq!(t.focus_target(Focus::Previous, D), Some(B));

    // A single pane is its own neighbour in both directions.
    let one = Tree::with_pane(A);
    assert_eq!(one.focus_target(Focus::Next, A), Some(A));
    assert_eq!(one.focus_target(Focus::Previous, A), Some(A));

    assert_eq!(t.focus_target(Focus::Next, 99), None);
}

// -- spatial neighbours ----------------------------------------------------

#[test]
fn spatial_neighbours_in_a_grid() {
    let t = grid();
    use Focus::Spatial;

    assert_eq!(t.focus_target(Spatial(Side::Right), A), Some(B));
    assert_eq!(t.focus_target(Spatial(Side::Down), A), Some(C));
    assert_eq!(t.focus_target(Spatial(Side::Left), B), Some(A));
    assert_eq!(t.focus_target(Spatial(Side::Down), B), Some(D));
    assert_eq!(t.focus_target(Spatial(Side::Up), C), Some(A));
    assert_eq!(t.focus_target(Spatial(Side::Right), C), Some(D));
    assert_eq!(t.focus_target(Spatial(Side::Left), D), Some(C));
    assert_eq!(t.focus_target(Spatial(Side::Up), D), Some(B));
}

#[test]
fn spatial_stops_at_the_edge() {
    let t = grid();
    use Focus::Spatial;
    assert_eq!(t.focus_target(Spatial(Side::Left), A), None);
    assert_eq!(t.focus_target(Spatial(Side::Up), A), None);
    assert_eq!(t.focus_target(Spatial(Side::Right), D), None);
    assert_eq!(t.focus_target(Spatial(Side::Down), D), None);
}

#[test]
fn spatial_crosses_more_than_one_pane() {
    // a | b | c, so moving right from a lands on b, not c.
    let t = row3();
    assert_eq!(t.focus_target(Focus::Spatial(Side::Right), A), Some(B));
    assert_eq!(t.focus_target(Focus::Spatial(Side::Right), B), Some(C));
    assert_eq!(t.focus_target(Focus::Spatial(Side::Left), C), Some(B));
    assert_eq!(t.focus_target(Focus::Spatial(Side::Left), B), Some(A));
}

#[test]
fn spatial_slots_include_splits_and_are_sorted_by_distance() {
    let t = grid();
    let spatial = t.spatial(None);

    // Four panes plus three splits.
    assert_eq!(spatial.slots.len(), 7);
    assert_eq!(spatial.slots.iter().filter(|s| s.pane.is_some()).count(), 4);

    let from = t.path_of(A).unwrap();
    let right = spatial.slots_toward(Side::Right, &from);
    // The right column's split and both of its panes.
    assert_eq!(right.len(), 3);
    // Nearest pane first among the panes.
    assert_eq!(right.iter().find_map(|s| s.pane), Some(B));
}

#[test]
fn borders() {
    let t = grid();
    let spatial = t.spatial(None);
    let a = t.path_of(A).unwrap();
    let d = t.path_of(D).unwrap();

    assert!(spatial.borders(Side::Up, &a));
    assert!(spatial.borders(Side::Left, &a));
    assert!(!spatial.borders(Side::Down, &a));
    assert!(!spatial.borders(Side::Right, &a));

    assert!(spatial.borders(Side::Down, &d));
    assert!(spatial.borders(Side::Right, &d));
    assert!(!spatial.borders(Side::Up, &d));

    // A single pane borders every side.
    let one = Tree::with_pane(A);
    let s = one.spatial(None);
    for side in [Side::Up, Side::Down, Side::Left, Side::Right] {
        assert!(s.borders(side, &[]));
    }
}

// -- closing a pane --------------------------------------------------------

#[test]
fn closing_the_only_pane_empties_the_tree() {
    let t = Tree::with_pane(A).remove(A);
    assert!(t.is_empty());
    assert_eq!(t.panes(), Vec::<PaneId>::new());
}

#[test]
fn closing_one_of_two_collapses_the_split() {
    let t = row().remove(A);
    assert!(!t.is_split());
    assert_eq!(t.panes(), vec![B]);

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 0.0, 0.0, 200.0, 100.0);
}

#[test]
fn closing_the_middle_of_three_leaves_the_other_two() {
    let t = row3().remove(B);
    assert_eq!(t.panes(), vec![A, C]);

    // The outer split kept its ratio; c simply took b's slot.
    let bounds = Rect::new(0.0, 0.0, 400.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, C), 200.0, 0.0, 200.0, 100.0);
}

#[test]
fn closing_a_pane_promotes_its_sibling_into_the_parent_slot() {
    // a | (b | c) with the outer ratio equalized to 1/3, then close a. The
    // inner split becomes the root and keeps its own ratio; the outer 1/3 is
    // gone with the split that held it.
    let t = row3().equalize().remove(A);
    assert_eq!(t.panes(), vec![B, C]);

    let bounds = Rect::new(0.0, 0.0, 400.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, C), 200.0, 0.0, 200.0, 100.0);
}

#[test]
fn closing_a_pane_in_a_grid_widens_its_row() {
    // Close c: the left column's vertical split collapses and a gets the
    // whole left column.
    let t = grid().remove(C);
    assert_eq!(t.panes(), vec![A, B, D]);

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 100.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 100.0, 0.0, 100.0, 50.0);
    assert_rect(rect_of(&t, bounds, D), 100.0, 50.0, 100.0, 50.0);
}

#[test]
fn closing_everything_one_at_a_time_ends_empty() {
    let mut t = grid();
    for pane in [A, B, C, D] {
        assert!(t.contains(pane));
        t = t.remove(pane);
        assert!(!t.contains(pane));
    }
    assert!(t.is_empty());
}

#[test]
fn closing_a_pane_that_is_not_there_changes_nothing() {
    let t = grid();
    assert_eq!(t.remove(99), t);
}

#[test]
fn closing_a_subtree_takes_all_of_it() {
    let t = grid();
    let right_column = vec![Branch::Right];
    let after = t.remove_subtree(&right_column).unwrap();
    assert_eq!(after.panes(), vec![A, C]);

    assert_eq!(
        t.remove_subtree(&[Branch::Left, Branch::Left, Branch::Left]),
        Err(Error::PathInvalid)
    );
}

// -- zoom ------------------------------------------------------------------

#[test]
fn zoom_hides_the_other_panes() {
    let t = grid().toggle_zoom(B);
    assert_eq!(t.zoomed(), Some(B));

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    // Every pane still appears; zoom hides the others rather than omitting
    // them. A caller that applies exactly what it is handed is now correct.
    assert_eq!(
        t.layout(bounds),
        vec![
            (A, Placement::Hidden),
            (C, Placement::Hidden),
            (B, Placement::Visible(bounds)),
            (D, Placement::Hidden),
        ]
    );

    // The tree itself is untouched, so un-zooming restores the layout.
    let back = t.toggle_zoom(B);
    assert_eq!(back.zoomed(), None);
    assert_eq!(back.layout(bounds), grid().layout(bounds));
}

#[test]
fn closing_the_zoomed_pane_clears_the_zoom() {
    let t = grid().toggle_zoom(B);
    assert_eq!(t.remove(B).zoomed(), None);
    assert_eq!(t.remove(A).zoomed(), Some(B));
    assert_eq!(t.remove_subtree(&[Branch::Right]).unwrap().zoomed(), None);
}

#[test]
fn splitting_or_resizing_clears_the_zoom() {
    let t = row().toggle_zoom(A);
    assert_eq!(t.insert(C, A, NewSplit::Right).unwrap().zoomed(), None);
    assert_eq!(
        t.resize(A, 10, Side::Right, Rect::new(0.0, 0.0, 200.0, 100.0))
            .unwrap()
            .zoomed(),
        None
    );
}

#[test]
fn zooming_a_pane_that_is_not_there_changes_nothing() {
    let t = grid();
    assert_eq!(t.toggle_zoom(99), t);
}

/// **The one direction `layout` is not complete in, as an assertion.**
///
/// A removed pane does not appear at all -- not even as `Hidden` -- because
/// the tree no longer knows it exists. The host still has a window for it.
/// This test exists so that the sentence in `layout`'s documentation is
/// something that fails when it stops being true, rather than prose nobody
/// re-reads.
#[test]
fn removed_panes_do_not_appear_in_the_layout_at_all() {
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    let t = grid().remove(C);

    let placed: Vec<PaneId> = t.layout(bounds).into_iter().map(|(p, _)| p).collect();
    assert!(!placed.contains(&C), "removed pane must not be placed");
    assert!(
        !t.layout(bounds).iter().any(|(p, pl)| *p == C && *pl == Placement::Hidden),
        "a removed pane is not Hidden either -- it is absent, and the host has \
         to find it by diffing its own windows against panes()"
    );

    // The rest still come out complete, so "absent" is specific to the pane
    // that was removed and not a hole in the whole answer.
    assert_eq!(placed, t.panes());
}

/// Whatever the zoom state, the answer names every pane the tree knows about
/// exactly once. This is the property a caller is allowed to rely on.
#[test]
fn every_known_pane_appears_exactly_once_in_every_zoom_state() {
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    for t in [grid(), grid().toggle_zoom(B), row3(), Tree::with_pane(A)] {
        let placed: Vec<PaneId> = t.layout(bounds).into_iter().map(|(p, _)| p).collect();
        let mut sorted = placed.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), placed.len(), "a pane was named twice");
        assert_eq!(placed, t.panes(), "layout and panes() must agree, in order");
    }
}

/// Exactly one pane is visible while zoomed, and it is the zoomed one.
#[test]
fn zoom_leaves_exactly_one_visible() {
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    let t = grid().toggle_zoom(D);
    let visible: Vec<PaneId> = t
        .layout(bounds)
        .into_iter()
        .filter(|(_, p)| p.rect().is_some())
        .map(|(p, _)| p)
        .collect();
    assert_eq!(visible, vec![D]);
}

// -- equalize --------------------------------------------------------------

#[test]
fn equalize_gives_three_in_a_row_a_third_each() {
    let t = row3().equalize();
    let bounds = Rect::new(0.0, 0.0, 300.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 100.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 100.0, 0.0, 100.0, 100.0);
    assert_rect(rect_of(&t, bounds, C), 200.0, 0.0, 100.0, 100.0);
}

#[test]
fn equalize_counts_a_cross_axis_child_as_one_slot() {
    // a | (b / c): the vertical split is one column, so the horizontal split
    // stays at half even though it holds three panes.
    let t = row()
        .insert(C, B, NewSplit::Down)
        .unwrap()
        .equalize();

    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 100.0, 100.0);
    assert_rect(rect_of(&t, bounds, B), 100.0, 0.0, 100.0, 50.0);
    assert_rect(rect_of(&t, bounds, C), 100.0, 50.0, 100.0, 50.0);
}

#[test]
fn equalize_undoes_a_resize() {
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    let skewed = row().resize(A, 40, Side::Right, bounds).unwrap();
    assert_rect(rect_of(&skewed, bounds, A), 0.0, 0.0, 140.0, 100.0);

    let t = skewed.equalize();
    assert_rect(rect_of(&t, bounds, A), 0.0, 0.0, 100.0, 100.0);
}

#[test]
fn equalize_keeps_a_single_pane_and_an_empty_tree_alone() {
    assert_eq!(Tree::new().equalize(), Tree::new());
    assert_eq!(Tree::with_pane(A).equalize(), Tree::with_pane(A));
}

// -- resize ----------------------------------------------------------------

#[test]
fn resize_moves_the_divider_not_the_pane() {
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    let t = row();

    // Right moves the divider right, whichever pane asked.
    assert_rect(
        rect_of(&t.resize(A, 20, Side::Right, bounds).unwrap(), bounds, A),
        0.0, 0.0, 120.0, 100.0,
    );
    assert_rect(
        rect_of(&t.resize(B, 20, Side::Right, bounds).unwrap(), bounds, A),
        0.0, 0.0, 120.0, 100.0,
    );

    // Left moves it left.
    assert_rect(
        rect_of(&t.resize(A, 20, Side::Left, bounds).unwrap(), bounds, A),
        0.0, 0.0, 80.0, 100.0,
    );
}

#[test]
fn resize_clamps_so_a_pane_never_vanishes() {
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);
    let t = row();

    let wide = t.resize(A, 10_000, Side::Right, bounds).unwrap();
    assert_rect(rect_of(&wide, bounds, A), 0.0, 0.0, 180.0, 100.0);

    let narrow = t.resize(A, 10_000, Side::Left, bounds).unwrap();
    assert_rect(rect_of(&narrow, bounds, A), 0.0, 0.0, 20.0, 100.0);
}

#[test]
fn resize_finds_the_nearest_ancestor_on_the_right_axis() {
    // a | (b / c). Resizing b down must move the inner vertical divider,
    // measured against the right column's height, not the whole window's.
    let t = row().insert(C, B, NewSplit::Down).unwrap();
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);

    let after = t.resize(B, 10, Side::Down, bounds).unwrap();
    assert_rect(rect_of(&after, bounds, B), 100.0, 0.0, 100.0, 60.0);
    assert_rect(rect_of(&after, bounds, C), 100.0, 60.0, 100.0, 40.0);
    // a is untouched.
    assert_rect(rect_of(&after, bounds, A), 0.0, 0.0, 100.0, 100.0);

    // Resizing b left skips the vertical split and moves the outer one.
    let sideways = t.resize(B, 10, Side::Left, bounds).unwrap();
    assert_rect(rect_of(&sideways, bounds, A), 0.0, 0.0, 90.0, 100.0);
}

#[test]
fn resize_with_no_divider_on_that_axis_says_so() {
    let bounds = Rect::new(0.0, 0.0, 200.0, 100.0);

    // A row has no vertical split at all.
    assert_eq!(row().resize(A, 10, Side::Up, bounds), Err(Error::NoSplitOnAxis));
    // A single pane has no split at all.
    assert_eq!(
        Tree::with_pane(A).resize(A, 10, Side::Left, bounds),
        Err(Error::NoSplitOnAxis)
    );
    // An unknown pane is a different problem and gets a different answer.
    assert_eq!(row().resize(99, 10, Side::Left, bounds), Err(Error::PaneNotFound));
}

#[test]
fn resize_is_measured_against_the_bounds_it_is_given() {
    let t = row();
    let narrow = t.resize(A, 20, Side::Right, Rect::new(0.0, 0.0, 100.0, 100.0)).unwrap();
    let wide = t.resize(A, 20, Side::Right, Rect::new(0.0, 0.0, 400.0, 100.0)).unwrap();

    // 20px is a fifth of 100 but a twentieth of 400.
    assert_rect(rect_of(&narrow, Rect::new(0.0, 0.0, 100.0, 100.0), A), 0.0, 0.0, 70.0, 100.0);
    assert_rect(rect_of(&wide, Rect::new(0.0, 0.0, 400.0, 100.0), A), 0.0, 0.0, 220.0, 100.0);
}

// -- natural size ----------------------------------------------------------

#[test]
fn natural_size_sums_along_the_axis_and_maxes_across_it() {
    let size = |pane: PaneId| match pane {
        A => (80.0, 24.0),
        B => (80.0, 40.0),
        _ => (10.0, 10.0),
    };

    assert_eq!(Tree::new().natural_size(&size), (0.0, 0.0));
    assert_eq!(Tree::with_pane(A).natural_size(&size), (80.0, 24.0));
    // a | b: widths add, heights take the larger.
    assert_eq!(row().natural_size(&size), (160.0, 40.0));
    // a / b: heights add, widths take the larger.
    let column = Tree::with_pane(A).insert(B, A, NewSplit::Down).unwrap();
    assert_eq!(column.natural_size(&size), (80.0, 64.0));
}
