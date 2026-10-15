//! The places that hold more than one terminal (control-room.md, 12.6.2;
//! task 1583): the table beside the tree, and what changes it.
//!
//! A port of the stack half of `macos/Sources/Features/Splits/SplitTree.swift`
//! (`// MARK: SplitTree Stacks`), function for function and in the same
//! order, held to `SplitStackTests.swift` by `stack_tests` in `tests.rs`.
//!
//! **The one rule everything turns on: a terminal put behind another is
//! still in the tree** -- for `contains`, `len`, `members` and `layout`
//! (where it is `Hidden`), and after every operation on the tree. The ones
//! behind have no place on screen to show that they are missing.
//!
//! Deviation, the same as the rest of this crate: Swift names a terminal by
//! its view and compares with `===`; here it is a [`PaneId`].

use crate::{Error, NewSplit, Node, PaneId, Stack, Tree};

impl Tree {
    /// This tree with another root and zoom, and the stacks whose place is
    /// still in it (Swift's `derived`). What every operation that returns a
    /// tree ends with.
    pub(crate) fn derived(&self, root: Option<Node>, zoomed: Option<PaneId>) -> Tree {
        let mut shown = Vec::new();
        if let Some(r) = &root {
            r.collect_leaves(&mut shown);
        }
        Tree {
            root,
            zoomed,
            stacks: self.stacks.iter().filter(|s| shown.contains(&s.shown)).cloned().collect(),
        }
    }

    /// The places that hold more than one terminal.
    pub fn stacks(&self) -> &[Stack] {
        &self.stacks
    }

    /// Every terminal in the tree: place by place in tree order, and inside
    /// a place in the order of its tabs. "Is this terminal in this tab",
    /// "does anything here have a program running", "which windows does
    /// this tab own" are all asked through this; what is on screen is
    /// [`Tree::shown_panes`].
    pub fn members(&self) -> Vec<PaneId> {
        match &self.root {
            Some(root) => self.members_under(root),
            None => Vec::new(),
        }
    }

    /// Every terminal under `node`: each place's whole stack.
    pub fn members_under(&self, node: &Node) -> Vec<PaneId> {
        let mut shown = Vec::new();
        node.collect_leaves(&mut shown);
        shown
            .into_iter()
            .flat_map(|p| match self.stack_of(p) {
                Some(s) => s.members.clone(),
                None => vec![p],
            })
            .collect()
    }

    /// The stack `pane` is in -- shown or behind -- or none when its place
    /// holds only it, or it is not in this tree.
    pub fn stack_of(&self, pane: PaneId) -> Option<&Stack> {
        self.stacks.iter().find(|s| s.members.contains(&pane))
    }

    /// The pane shown in the place `pane` belongs to: itself, unless it is
    /// stacked behind another. None when it is not in this tree.
    pub fn shown_for(&self, pane: PaneId) -> Option<PaneId> {
        match self.stack_of(pane) {
            Some(s) => Some(s.shown),
            None => self.path_of(pane).map(|_| pane),
        }
    }

    /// Whether `pane` is what its place is showing.
    pub fn is_shown(&self, pane: PaneId) -> bool {
        self.shown_for(pane) == Some(pane)
    }

    /// This tree with the place showing `old` showing `new` instead, and
    /// `stacks` for its stacks. Zoom follows the place.
    fn swapping(&self, old: PaneId, new: PaneId, stacks: Vec<Stack>) -> Result<Tree, Error> {
        let root = self.root.as_ref().ok_or(Error::PaneNotFound)?;
        let path = self.path_of(old).ok_or(Error::PaneNotFound)?;
        let root = root.replacing(&path, Node::Leaf(new))?;
        let zoomed = if self.zoomed == Some(old) { Some(new) } else { self.zoomed };
        Ok(Tree { root: Some(root), zoomed, stacks })
    }

    /// The stacks other than the one `pane` is in.
    fn others(&self, pane: PaneId) -> Vec<Stack> {
        self.stacks.iter().filter(|s| !s.members.contains(&pane)).cloned().collect()
    }

    /// Put `pane` into the place `target` is in: it becomes the one the
    /// place shows, and its tab is the last. `target` may be the place's
    /// shown pane or one behind it.
    pub fn stacking(&self, pane: PaneId, onto: PaneId) -> Result<Tree, Error> {
        if self.contains(pane) {
            return Err(Error::AlreadyPresent);
        }
        let front = self.shown_for(onto).ok_or(Error::PaneNotFound)?;
        let mut members = self.stack_of(front).map(|s| s.members.clone()).unwrap_or_else(|| vec![front]);
        members.push(pane);
        let mut stacks = self.others(front);
        stacks.push(Stack { shown: pane, members });
        self.swapping(front, pane, stacks)
    }

    /// Put `pane` into the place `onto` is in at tab `index` of its stack,
    /// in front (a tab let go on a stack's strip). `index` is where it ends
    /// up, from 0; past the end is the end. A place of one becomes a stack
    /// of two.
    pub fn stacking_at(&self, pane: PaneId, onto: PaneId, index: usize) -> Result<Tree, Error> {
        let stacked = self.stacking(pane, onto)?;
        let Some(stack) = stacked.stack_of(pane).cloned() else { return Ok(stacked) };
        let mut members: Vec<PaneId> = stack.members.iter().copied().filter(|m| *m != pane).collect();
        members.insert(index.min(members.len()), pane);
        let mut stacks = stacked.others(pane);
        stacks.push(Stack { shown: stack.shown, members });
        Ok(Tree { root: stacked.root, zoomed: stacked.zoomed, stacks })
    }

    /// `pane`'s tab moved to `index` of its own stack (a tab dragged along
    /// its strip). Which terminal the place shows does not change; nothing
    /// else in the tree does. Past the end is the end.
    pub fn reordering(&self, pane: PaneId, index: usize) -> Result<Tree, Error> {
        let stack = self.stack_of(pane).cloned().ok_or(self.not_stacked(pane))?;
        let mut members: Vec<PaneId> = stack.members.iter().copied().filter(|m| *m != pane).collect();
        members.insert(index.min(members.len()), pane);
        let mut stacks = self.others(pane);
        stacks.push(Stack { shown: stack.shown, members });
        Ok(Tree { root: self.root.clone(), zoomed: self.zoomed, stacks })
    }

    /// What a pane with no stack is refused with: not stacked when it is a
    /// place of its own, not found when it is not here.
    fn not_stacked(&self, pane: PaneId) -> Error {
        if self.path_of(pane).is_some() {
            Error::NotStacked
        } else {
            Error::PaneNotFound
        }
    }

    /// Bring `pane`, which is stacked behind another, to the front of its
    /// place. Showing what is already shown changes nothing.
    pub fn showing(&self, pane: PaneId) -> Result<Tree, Error> {
        let stack = self.stack_of(pane).cloned().ok_or(self.not_stacked(pane))?;
        if stack.shown == pane {
            return Ok(self.clone());
        }
        let mut stacks = self.others(pane);
        stacks.push(Stack { shown: pane, members: stack.members });
        self.swapping(stack.shown, pane, stacks)
    }

    /// Take `pane` out of the tree by itself, wherever in its place it is.
    ///
    /// The one a place shows is followed by the next tab of its stack (the
    /// one before it, for the last); with one terminal left the place is an
    /// ordinary leaf again and its stack is gone from the table. A place's
    /// only terminal takes the place with it, as [`Tree::remove`] always
    /// has.
    pub fn removing_member(&self, pane: PaneId) -> Result<Tree, Error> {
        let Some(stack) = self.stack_of(pane).cloned() else {
            if self.path_of(pane).is_none() {
                return Err(Error::PaneNotFound);
            }
            return Ok(self.remove(pane));
        };
        let at = stack.members.iter().position(|m| *m == pane).ok_or(Error::PaneNotFound)?;
        let mut members = stack.members.clone();
        members.remove(at);
        let next = if stack.shown == pane { members[at.min(members.len() - 1)] } else { stack.shown };
        let mut kept = self.others(pane);
        if members.len() > 1 {
            kept.push(Stack { shown: next, members });
        }
        if stack.shown == pane {
            return self.swapping(pane, next, kept);
        }
        Ok(Tree { root: self.root.clone(), zoomed: self.zoomed, stacks: kept })
    }

    /// Take `pane` out of its stack and make it a place of its own beside
    /// the place it was in. Like every new split, this resets the zoom.
    pub fn unstacking(&self, pane: PaneId, dir: NewSplit) -> Result<Tree, Error> {
        let stack = self.stack_of(pane).cloned().ok_or(self.not_stacked(pane))?;
        let without = self.removing_member(pane)?;
        let place = stack
            .members
            .iter()
            .copied()
            .find(|m| *m != pane && without.is_shown(*m))
            .ok_or(Error::PaneNotFound)?;
        without.insert(pane, place, dir)
    }

    /// Every terminal of `tab` made one new place beside the place `target`
    /// is in: a window tab dropped onto a pane (task 1558).
    ///
    /// The new place holds them in `tab`'s order ([`Tree::members`]) and
    /// shows `shown`, the one `tab` had the keyboard on. A tab of one
    /// terminal makes an ordinary pane, as [`Tree::insert`] does: one is not
    /// a stack. `tab`'s splits are not kept -- the tab becomes one place.
    pub fn inserting_tab(&self, tab: &Tree, shown: PaneId, target: PaneId, dir: NewSplit) -> Result<Tree, Error> {
        let incoming = tab.members();
        if !incoming.contains(&shown) {
            return Err(Error::PaneNotFound);
        }
        if incoming.iter().any(|p| self.contains(*p)) {
            return Err(Error::AlreadyPresent);
        }
        let place = self.shown_for(target).ok_or(Error::PaneNotFound)?;
        let inserted = self.insert(shown, place, dir)?;
        if incoming.len() <= 1 {
            return Ok(inserted);
        }
        let mut stacks = inserted.stacks.clone();
        stacks.push(Stack { shown, members: incoming });
        Ok(Tree { root: inserted.root, zoomed: inserted.zoomed, stacks })
    }

    /// A tree from a whole shape and its stacks at once: a project read
    /// back, or a layout an agent stated. **Strict**, as Swift's stored form
    /// is: a stack must name a shown pane of `root` among its members, have
    /// more than one member, and no terminal may be in two places.
    pub fn with_root_and_stacks(root: Node, stacks: Vec<Stack>) -> Result<Tree, Error> {
        let mut shown = Vec::new();
        root.collect_leaves(&mut shown);
        let mut all: Vec<PaneId> = Vec::new();
        for p in &shown {
            match stacks.iter().filter(|s| s.shown == *p).count() {
                0 => all.push(*p),
                1 => {}
                _ => return Err(Error::AlreadyPresent),
            }
        }
        for s in &stacks {
            if s.members.len() < 2 || !s.members.contains(&s.shown) || !shown.contains(&s.shown) {
                return Err(Error::PaneNotFound);
            }
            all.extend(s.members.iter().copied());
        }
        let mut sorted = all.clone();
        sorted.sort_unstable();
        sorted.dedup();
        if sorted.len() != all.len() {
            return Err(Error::AlreadyPresent);
        }
        Ok(Tree { root: Some(root), zoomed: None, stacks })
    }

    /// The places' ids that removing the subtree at `path` takes out of the
    /// tree, the ones stacked behind included: what a host has to destroy
    /// the windows of (Swift's `removed(by:)` for a split).
    pub fn removed_by_subtree(&self, path: &[crate::Branch]) -> Vec<PaneId> {
        match self.node_at(path) {
            Some(node) => self.members_under(node),
            None => Vec::new(),
        }
    }
}

/// One of the stack's verbs (`Binding.zig`'s `pane_stack`, by the numbers
/// of `ghostty_action_pane_stack_e`): what it does to the place the
/// keyboard is in. macOS's `PaneStackRules.Verb`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verb {
    /// A new terminal in this place, in front.
    New,
    /// The next tab of this place's stack, and the one before.
    Next,
    Previous,
    /// This terminal out of its stack, into a place of its own beside.
    Out,
    /// This place's terminal onto the next place's stack, and the one
    /// before: two places become one.
    OntoNext,
    OntoPrevious,
}

impl Verb {
    /// `GHOSTTY_PANE_STACK_*`, in the header's order; none for a number it
    /// does not have.
    pub fn from_c(v: i32) -> Option<Verb> {
        Some(match v {
            0 => Verb::New,
            1 => Verb::Next,
            2 => Verb::Previous,
            3 => Verb::Out,
            4 => Verb::OntoNext,
            5 => Verb::OntoPrevious,
            _ => return None,
        })
    }
}

/// Whether `verb` has anything to do, so a menu can grey what has not and
/// a key that has nothing to do falls through. `stacked`: the place holds
/// more than one terminal; `places`: how many the tab shows; `quick`: the
/// quick terminal, which holds no stacks. macOS's `PaneStackRules.offers`.
pub fn offers(verb: Verb, stacked: bool, places: usize, quick: bool) -> bool {
    if quick {
        return false;
    }
    match verb {
        Verb::New => true,
        Verb::Next | Verb::Previous | Verb::Out => stacked,
        Verb::OntoNext | Verb::OntoPrevious => places > 1,
    }
}

/// The member a step along the tabs from `current` lands on, round the
/// ends; none when there is nowhere else to go (`PaneStackRules.neighbour`).
pub fn neighbour(current: usize, count: usize, step: isize) -> Option<usize> {
    if count < 2 || current >= count {
        return None;
    }
    let n = count as isize;
    let to = (((current as isize + step) % n + n) % n) as usize;
    (to != current).then_some(to)
}

impl Tree {
    /// The terminal of `pane`'s stack a step along its tabs from the one
    /// shown: what `next` and `previous` bring to the front.
    pub fn stack_neighbour(&self, pane: PaneId, step: isize) -> Option<PaneId> {
        let stack = self.stack_of(pane)?;
        let at = stack.members.iter().position(|m| *m == stack.shown)?;
        neighbour(at, stack.members.len(), step).map(|i| stack.members[i])
    }

    /// `pane` -- shown or behind -- onto the stack of the place `target` is
    /// in: out of where it is, in front there (Swift's `stack(_:onto:)`,
    /// `removing(member:)` then `stacking`). Refused for the same place.
    pub fn stacking_onto(&self, pane: PaneId, target: PaneId) -> Result<Tree, Error> {
        let place = self.shown_for(target).ok_or(Error::PaneNotFound)?;
        if self.shown_for(pane) == Some(place) {
            return Err(Error::AlreadyPresent);
        }
        let without = self.removing_member(pane)?;
        without.stacking(pane, place)
    }
}
