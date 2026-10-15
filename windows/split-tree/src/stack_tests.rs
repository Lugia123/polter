//! A place that holds more than one terminal (task 1583): the tests of
//! `macos/Tests/Splits/SplitStackTests.swift`, one for one and under the
//! same names, so the two files can be read side by side. Above all the one
//! rule: **a terminal put behind another is still in the tree**, for every
//! question asked of it and after every operation on it.

use super::*;

const A: PaneId = 1;
const B: PaneId = 2;
const C: PaneId = 3;
const D: PaneId = 4;
const E: PaneId = 5;

/// Three places, a | (b over c), and a fourth and fifth terminal to stack.
fn fixture() -> Tree {
    Tree::with_pane(A).insert(B, A, NewSplit::Right).unwrap().insert(C, B, NewSplit::Down).unwrap()
}

/// What has to be true of any tree, whatever was done to it.
#[track_caller]
fn sound(tree: &Tree) {
    let shown = tree.shown_panes();
    for stack in tree.stacks() {
        assert!(stack.members.len() > 1, "{stack:?}");
        assert_eq!(stack.members.iter().filter(|m| **m == stack.shown).count(), 1, "{stack:?}");
        assert!(shown.contains(&stack.shown), "{stack:?} shown {shown:?}");
    }
    let all = tree.members();
    let mut unique = all.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(unique.len(), all.len(), "a terminal twice: {all:?}");
    for p in &shown {
        assert!(all.contains(p), "{p} shown but not a member");
    }
    // Every member is laid out once: shown ones visible, the rest hidden.
    let laid: Vec<PaneId> = tree.layout(Rect::new(0.0, 0.0, 800.0, 600.0)).into_iter().map(|(p, _)| p).collect();
    assert_eq!(laid, all, "layout covers every member once, in order");
}

/// The tree's one stack.
#[track_caller]
fn only(tree: &Tree) -> Stack {
    assert_eq!(tree.stacks().len(), 1, "{:?}", tree.stacks());
    tree.stacks()[0].clone()
}

// ---- Stacking

#[test]
fn stacking_puts_the_new_terminal_in_front_and_keeps_the_one_it_covered() {
    let tree = fixture().stacking(D, B).unwrap();
    sound(&tree);
    // The place shows the new one; the tree has the same three places.
    assert_eq!(tree.shown_panes(), [A, D, C]);
    assert!(tree.is_shown(D));
    assert!(!tree.is_shown(B));
    assert_eq!(tree.shown_for(B), Some(D));
    // And the one behind is still in the tree, for every way of asking.
    assert_eq!(tree.members(), [A, B, D, C]);
    assert_eq!(tree.len(), 4);
    assert!(tree.contains(B));
    // One stack, in the order of its tabs: the new one last.
    assert_eq!(only(&tree), Stack { shown: D, members: vec![B, D] });
}

#[test]
fn stacking_at_a_place_puts_it_there_in_front() {
    let tree = fixture().stacking(D, B).unwrap().stacking_at(E, B, 1).unwrap();
    sound(&tree);
    assert_eq!(only(&tree), Stack { shown: E, members: vec![B, E, D] });
    // Past the end is the end; onto a place of one, a stack of two.
    let two = fixture().stacking_at(D, A, 9).unwrap();
    sound(&two);
    assert_eq!(only(&two).members, [A, D]);
    let first = fixture().stacking_at(D, A, 0).unwrap();
    assert_eq!(only(&first).members, [D, A]);
}

#[test]
fn reordering_moves_only_the_tab_and_not_what_the_place_shows() {
    let mut tree = fixture().stacking(D, B).unwrap().stacking(E, B).unwrap();
    tree = tree.reordering(E, 0).unwrap();
    sound(&tree);
    assert_eq!(only(&tree), Stack { shown: E, members: vec![E, B, D] });
    tree = tree.reordering(B, 99).unwrap();
    assert_eq!(only(&tree).members, [E, D, B]);
    assert_eq!(tree.shown_panes(), [A, E, C]);
    // A place of one has no tabs to reorder.
    assert_eq!(fixture().reordering(A, 0), Err(Error::NotStacked));
}

#[test]
fn stacking_onto_a_terminal_that_is_behind_goes_into_the_same_place() {
    let tree = fixture().stacking(D, B).unwrap().stacking(E, B).unwrap();
    sound(&tree);
    assert_eq!(tree.stacks().len(), 1);
    assert_eq!(only(&tree).members, [B, D, E]);
    assert_eq!(tree.shown_panes(), [A, E, C]);
}

#[test]
fn stacking_refuses_a_terminal_already_in_the_tree_and_a_target_that_is_not() {
    assert_eq!(fixture().stacking(A, B), Err(Error::AlreadyPresent));
    assert_eq!(fixture().stacking(D, E), Err(Error::PaneNotFound));
    // Behind counts as already in it.
    let tree = fixture().stacking(D, B).unwrap();
    assert_eq!(tree.stacking(B, A), Err(Error::AlreadyPresent));
}

#[test]
fn two_places_each_keep_their_own_stack() {
    let tree = fixture().stacking(D, A).unwrap().stacking(E, C).unwrap();
    sound(&tree);
    assert_eq!(tree.stacks().len(), 2);
    assert_eq!(tree.members(), [A, D, B, C, E]);
    assert_eq!(tree.shown_panes(), [D, B, E]);
    assert_eq!(tree.stack_of(B), None);
}

// ---- Showing

#[test]
fn showing_brings_one_from_behind_to_the_front_without_reordering_the_tabs() {
    let mut tree = fixture().stacking(D, B).unwrap().stacking(E, B).unwrap();
    tree = tree.showing(B).unwrap();
    sound(&tree);
    assert_eq!(tree.shown_panes(), [A, B, C]);
    assert_eq!(only(&tree), Stack { shown: B, members: vec![B, D, E] });
    assert_eq!(tree.len(), 5);
    // Showing what is shown changes nothing.
    assert_eq!(tree.showing(B).unwrap(), tree);
}

#[test]
fn showing_refuses_a_place_of_one_and_a_terminal_that_is_not_there() {
    assert_eq!(fixture().showing(A), Err(Error::NotStacked));
    assert_eq!(fixture().showing(D), Err(Error::PaneNotFound));
}

// ---- Removing

#[test]
fn removing_the_shown_one_lets_the_next_tab_take_its_place_in_the_same_place() {
    let tree = fixture().stacking(D, B).unwrap().stacking(E, B).unwrap().showing(D).unwrap();
    // b, [d], e: closing d shows e, the tab after it.
    let after = tree.remove(D);
    sound(&after);
    assert_eq!(after.shown_panes(), [A, E, C]);
    assert_eq!(after.members(), [A, B, E, C]);
    assert!(!after.contains(D));
    // b, [e]: closing the last tab shows the one before it, and with one
    // left the place is an ordinary leaf again.
    let last = after.remove(E);
    sound(&last);
    assert_eq!(last.shown_panes(), [A, B, C]);
    assert!(last.stacks().is_empty());
}

#[test]
fn removing_one_from_behind_leaves_the_place_showing_what_it_showed() {
    let tree = fixture().stacking(D, B).unwrap().stacking(E, B).unwrap();
    let after = tree.removing_member(B).unwrap();
    sound(&after);
    assert_eq!(after.shown_panes(), [A, E, C]);
    assert_eq!(only(&after).members, [D, E]);
    assert!(!after.contains(B));
    assert_eq!(after.removing_member(B), Err(Error::PaneNotFound));
}

#[test]
fn removing_a_split_takes_every_terminal_under_it_the_ones_behind_too() {
    let tree = fixture().stacking(D, B).unwrap();
    // The right-hand split: (b, [d]) over c.
    let right = [Branch::Right];
    assert_eq!(tree.removed_by_subtree(&right), [B, D, C]);
    let after = tree.remove_subtree(&right).unwrap();
    sound(&after);
    assert_eq!(after.members(), [A]);
    assert!(after.stacks().is_empty());
}

#[test]
fn removing_a_place_of_one_is_what_it_always_was() {
    let tree = fixture().stacking(D, B).unwrap();
    let after = tree.remove(A);
    sound(&after);
    assert_eq!(after.shown_panes(), [D, C]);
    // The stack in another place is untouched.
    assert_eq!(after.members(), [B, D, C]);
}

// ---- Unstacking

#[test]
fn unstacking_makes_it_a_place_of_its_own_beside_the_place_it_was_in() {
    let tree = fixture().stacking(D, B).unwrap().stacking(E, B).unwrap();
    // From behind: the place goes on showing e; d appears to its right.
    let behind = tree.unstacking(D, NewSplit::Right).unwrap();
    sound(&behind);
    assert_eq!(behind.shown_panes(), [A, E, D, C]);
    assert_eq!(only(&behind).members, [B, E]);
    assert_eq!(behind.len(), 5);
    // The shown one: the next tab takes the place, and it lands on the left.
    let front = tree.unstacking(E, NewSplit::Left).unwrap();
    sound(&front);
    assert_eq!(front.shown_panes(), [A, E, D, C]);
    assert_eq!(only(&front).members, [B, D]);
    // Out of a stack of two: no stack is left, and nothing is lost.
    let apart = fixture().stacking(D, B).unwrap().unstacking(B, NewSplit::Down).unwrap();
    sound(&apart);
    assert!(apart.stacks().is_empty());
    assert_eq!(apart.shown_panes(), [A, D, B, C]);
}

#[test]
fn unstacking_refuses_a_place_of_one_and_a_terminal_that_is_not_there() {
    assert_eq!(fixture().unstacking(A, NewSplit::Right), Err(Error::NotStacked));
    assert_eq!(fixture().unstacking(D, NewSplit::Right), Err(Error::PaneNotFound));
}

// ---- A tab dropped onto a place

const X: PaneId = 11;
const Y: PaneId = 12;
const Z: PaneId = 13;
const W: PaneId = 14;
const TARGET: PaneId = 20;

/// A tab of three places, x | (y over z), with w stacked behind z: four
/// terminals in the order x, y, z, w. The keyboard is on y.
fn dropped_tab() -> Tree {
    Tree::with_pane(X)
        .insert(Y, X, NewSplit::Right)
        .unwrap()
        .insert(Z, Y, NewSplit::Down)
        .unwrap()
        .stacking(W, Z)
        .unwrap()
        .showing(Z)
        .unwrap()
}

#[test]
fn a_tab_of_several_dropped_on_a_place_of_one_becomes_one_stacked_place() {
    let tree = Tree::with_pane(TARGET).inserting_tab(&dropped_tab(), Y, TARGET, NewSplit::Left).unwrap();
    sound(&tree);
    // Two places: the new one on the side it was dropped, showing y.
    assert_eq!(tree.shown_panes(), [Y, TARGET]);
    // Every terminal of the tab is in it, in the tab's order.
    assert_eq!(only(&tree), Stack { shown: Y, members: vec![X, Y, Z, W] });
    assert_eq!(tree.len(), 5);
}

#[test]
fn a_tab_of_several_dropped_on_one_place_of_several_stacks_beside_that_place() {
    let tree = fixture().inserting_tab(&dropped_tab(), Y, B, NewSplit::Down).unwrap();
    sound(&tree);
    assert_eq!(tree.shown_panes(), [A, B, Y, C]);
    assert_eq!(only(&tree), Stack { shown: Y, members: vec![X, Y, Z, W] });
    assert_eq!(tree.members(), [A, B, X, Y, Z, W, C]);
}

#[test]
fn a_tab_of_one_dropped_on_a_place_is_an_ordinary_place() {
    let tab = Tree::with_pane(X);
    let one = Tree::with_pane(TARGET).inserting_tab(&tab, X, TARGET, NewSplit::Right).unwrap();
    sound(&one);
    assert_eq!(one.shown_panes(), [TARGET, X]);
    assert!(one.stacks().is_empty());
    let several = fixture().inserting_tab(&tab, X, A, NewSplit::Up).unwrap();
    sound(&several);
    assert_eq!(several.shown_panes(), [X, A, B, C]);
    assert!(several.stacks().is_empty());
}

#[test]
fn a_tab_dropped_on_a_stacked_place_goes_beside_that_place_and_leaves_its_stack() {
    let stacked = fixture().stacking(D, B).unwrap();
    // Named by the terminal behind: still that place.
    let tree = stacked.inserting_tab(&dropped_tab(), W, B, NewSplit::Right).unwrap();
    sound(&tree);
    assert_eq!(tree.shown_panes(), [A, D, W, C]);
    assert_eq!(tree.stacks().len(), 2);
    assert_eq!(tree.stack_of(B).map(|s| s.members.clone()), Some(vec![B, D]));
    assert_eq!(tree.stack_of(X).cloned(), Some(Stack { shown: W, members: vec![X, Y, Z, W] }));
}

#[test]
fn a_tab_drop_refuses_a_terminal_already_here_a_shown_one_not_in_the_tab_and_a_target_not_here() {
    let f = fixture();
    let t = dropped_tab();
    assert_eq!(f.inserting_tab(&t, A, B, NewSplit::Left), Err(Error::PaneNotFound));
    assert_eq!(f.inserting_tab(&t, X, D, NewSplit::Left), Err(Error::PaneNotFound));
    assert_eq!(f.inserting_tab(&f, A, B, NewSplit::Left), Err(Error::AlreadyPresent));
}

// ---- Zoom

#[test]
fn the_zoom_stays_on_the_place_when_what_it_shows_changes() {
    // Deviation: a zoom here is a pane, never a split (lib.rs, `zoomed`),
    // so only the first half of Swift's test applies.
    let mut tree = fixture().toggle_zoom(B);
    tree = tree.stacking(D, B).unwrap();
    assert_eq!(tree.zoomed(), Some(D));
    tree = tree.showing(B).unwrap();
    assert_eq!(tree.zoomed(), Some(B));
    tree = tree.remove(B);
    assert_eq!(tree.zoomed(), Some(D));
    // Zooming a terminal behind zooms its place.
    let behind = fixture().stacking(D, B).unwrap().toggle_zoom(B);
    assert_eq!(behind.zoomed(), Some(D));
    // While zoomed, the place's other terminals are hidden like any other.
    let laid = behind.layout(Rect::new(0.0, 0.0, 800.0, 600.0));
    assert_eq!(laid.iter().filter(|(_, p)| p.rect().is_some()).map(|(id, _)| *id).collect::<Vec<_>>(), [D]);
    assert_eq!(laid.len(), 4);
}

// ---- Every other operation keeps the stacks

#[test]
fn nothing_else_that_returns_a_tree_drops_the_terminals_behind() {
    let tree = fixture().stacking(D, B).unwrap();
    let want = [A, B, D, C];
    let bounds = Rect::new(0.0, 0.0, 800.0, 600.0);

    let inserted = tree.insert(E, C, NewSplit::Right).unwrap();
    sound(&inserted);
    assert_eq!(inserted.members(), [A, B, D, C, E]);

    let equal = tree.equalize();
    sound(&equal);
    assert_eq!(equal.members(), want);

    let resized = tree.resize(D, 10, Side::Left, bounds).unwrap();
    sound(&resized);
    assert_eq!(resized.members(), want);

    let dragged = tree.resize_at(&[], 300.0, bounds).unwrap();
    sound(&dragged);
    assert_eq!(dragged.members(), want);

    let zoomed = tree.toggle_zoom(A).toggle_zoom(A);
    sound(&zoomed);
    assert_eq!(zoomed.members(), want);

    // Moving a pane inside the tab keeps the other place's stack.
    let moved = tree.moving(A, C, NewSplit::Down).unwrap();
    sound(&moved);
    assert_eq!(moved.members(), [B, D, C, A]);
    // Moving the one behind out of its stack: it becomes a place, and the
    // stack of two is gone.
    let out = tree.moving(B, A, NewSplit::Left).unwrap();
    sound(&out);
    assert_eq!(out.shown_panes(), [B, A, D, C]);
    assert!(out.stacks().is_empty());
}

#[test]
fn a_tree_with_no_stacks_answers_every_question_as_it_did_before() {
    let f = fixture();
    assert!(f.stacks().is_empty());
    assert_eq!(f.members(), f.shown_panes());
    assert_eq!(f.len(), 3);
    assert!(f.is_shown(A));
    assert_eq!(f.shown_for(D), None);
    assert_eq!(f.remove(B).members(), [A, C]);
    assert_eq!(f.removing_member(B).unwrap().members(), [A, C]);
}

// ---- Built whole (a project read back, a layout an agent stated)

#[test]
fn a_tree_built_whole_takes_sound_stacks_and_refuses_the_rest() {
    let root = fixture().root().unwrap().clone();
    let ok = Tree::with_root_and_stacks(root.clone(), vec![Stack { shown: B, members: vec![D, B] }]).unwrap();
    sound(&ok);
    assert_eq!(ok.members(), [A, D, B, C]);
    // A stack of one, a shown pane not in the tree, a shown pane not among
    // its members, a terminal twice.
    for bad in [
        vec![Stack { shown: B, members: vec![B] }],
        vec![Stack { shown: D, members: vec![D, E] }],
        vec![Stack { shown: B, members: vec![D, E] }],
        vec![Stack { shown: B, members: vec![B, A] }],
        vec![Stack { shown: B, members: vec![B, D] }, Stack { shown: C, members: vec![C, D] }],
    ] {
        assert!(Tree::with_root_and_stacks(root.clone(), bad.clone()).is_err(), "{bad:?}");
    }
}

// ---- The verbs (PaneStackRulesTests)

#[test]
fn what_each_verb_offers() {
    use crate::stack::{offers, Verb::*};
    for v in [New, Next, Previous, Out, OntoNext, OntoPrevious] {
        assert!(!offers(v, true, 3, true), "{v:?}: the quick terminal holds no stacks");
    }
    assert!(offers(New, false, 1, false));
    for v in [Next, Previous, Out] {
        assert!(!offers(v, false, 3, false), "{v:?}");
        assert!(offers(v, true, 1, false), "{v:?}");
    }
    for v in [OntoNext, OntoPrevious] {
        assert!(!offers(v, true, 1, false), "{v:?}");
        assert!(offers(v, false, 2, false), "{v:?}");
    }
}

#[test]
fn the_verbs_numbers_are_the_headers() {
    use crate::stack::Verb::{self, *};
    let all: Vec<Option<Verb>> = (0..7).map(Verb::from_c).collect();
    assert_eq!(all, [Some(New), Some(Next), Some(Previous), Some(Out), Some(OntoNext), Some(OntoPrevious), None]);
}

#[test]
fn a_neighbour_goes_round_the_ends() {
    use crate::stack::neighbour;
    assert_eq!(neighbour(0, 3, 1), Some(1));
    assert_eq!(neighbour(2, 3, 1), Some(0));
    assert_eq!(neighbour(0, 3, -1), Some(2));
    assert_eq!(neighbour(0, 1, 1), None);
    assert_eq!(neighbour(3, 3, 1), None);
    let tree = fixture().stacking(D, B).unwrap().stacking(E, B).unwrap();
    // b, d, [e]: next is b, previous is d.
    assert_eq!(tree.stack_neighbour(B, 1), Some(B));
    assert_eq!(tree.stack_neighbour(E, -1), Some(D));
    assert_eq!(fixture().stack_neighbour(A, 1), None);
}

#[test]
fn stacking_onto_another_place_takes_it_out_of_its_own() {
    // a onto b's place: a's place goes, b's place shows a.
    let tree = fixture().stacking_onto(A, B).unwrap();
    sound(&tree);
    assert_eq!(tree.shown_panes(), [A, C]);
    assert_eq!(only(&tree), Stack { shown: A, members: vec![B, A] });
    // One from behind onto another place: its own place keeps showing.
    let s = fixture().stacking(D, B).unwrap().stacking_onto(B, C).unwrap();
    sound(&s);
    assert_eq!(s.shown_panes(), [A, D, B]);
    assert_eq!(only(&s).members, [C, B]);
    // Onto its own place: refused.
    assert_eq!(fixture().stacking(D, B).unwrap().stacking_onto(B, D), Err(Error::AlreadyPresent));
}

#[test]
fn a_stacks_tab_drags_with_auto_even_in_a_tab_of_one_place() {
    use crate::drag::{stack_tab_grip, Setting, TitleGrip};
    assert_eq!(stack_tab_grip(Setting::Auto, false), TitleGrip::Drag);
    assert_eq!(stack_tab_grip(Setting::Always, false), TitleGrip::Drag);
    assert_eq!(stack_tab_grip(Setting::Never, false), TitleGrip::Click);
    for s in [Setting::Auto, Setting::Always, Setting::Never] {
        assert_eq!(stack_tab_grip(s, true), TitleGrip::None, "{s:?}");
    }
}

#[test]
fn a_tab_goes_into_a_pane_unless_it_is_the_control_rooms_its_own_or_lent() {
    use crate::drag::{tab_into_pane_refusal as r, TabIntoPane};
    assert_eq!(r(false, false, false), None);
    assert_eq!(r(true, false, false), Some(TabIntoPane::ControlRoom));
    assert_eq!(r(false, true, false), Some(TabIntoPane::Lent));
    assert_eq!(r(false, false, true), Some(TabIntoPane::OwnTab));
}

/// Task 1597: a layout or a project that makes the terminals of a stack
/// made only the one in front -- the others are `Hidden` in the layout,
/// and the host refused them ("pane N has no place in that layout"). Every
/// member has a place to be made: its own place's.
#[test]
fn every_member_of_a_stack_has_a_place_to_be_made() {
    let bounds = Rect::new(0.0, 0.0, 800.0, 600.0);
    // a | (b, d, e with d in front): what a project of p93's shape builds.
    let root = fixture().root().unwrap().clone();
    let tree = Tree::with_root_and_stacks(root, vec![Stack { shown: B, members: vec![D, B, E] }]).unwrap();
    let place = tree.layout(bounds).into_iter().find(|(p, _)| *p == B).and_then(|(_, at)| at.rect()).unwrap();
    for m in [D, B, E] {
        assert_eq!(tree.rect_to_make(m, bounds), Some(place), "member {m}");
    }
    // A pane hidden by a zoom is made where it would be shown unzoomed.
    let zoomed = fixture().toggle_zoom(A);
    let c = fixture().layout(bounds).into_iter().find(|(p, _)| *p == C).and_then(|(_, at)| at.rect()).unwrap();
    assert_eq!(zoomed.rect_to_make(C, bounds), Some(c));
    // Not in the tree: nowhere.
    assert_eq!(tree.rect_to_make(99, bounds), None);
}
