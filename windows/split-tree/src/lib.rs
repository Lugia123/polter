//! The split layout tree: which pane sits where, how big, and who is next to
//! whom.
//!
//! **Where this came from.** This is a port of
//! `macos/Sources/Features/Splits/SplitTree.swift`. That file is the one
//! piece of the macOS app that is a data structure rather than a view: the
//! tree, the ratios, the traversal, the spatial neighbour search, and the
//! collapse that happens when a leaf is closed. The algorithms here are the
//! same algorithms, deliberately kept in the same shape and the same order so
//! the two files can be read side by side when one of them changes. Every
//! place they differ is marked `Deviation:` with the reason.
//!
//! **What this deliberately does not know.** A libghostty surface is bound to
//! one HWND for its whole life and `wgl.zig` holds that window's device
//! context, so every pane has to be its own child window -- the same
//! constraint the tab strip already lives under (see `tabs.rs`). None of that
//! is in here. This tree says *what is where*; creating, moving and
//! destroying the windows is the host's job. So the leaf is a `PaneId`, an
//! opaque number the host maps to an HWND and a surface pointer, and nothing
//! in this file can call Win32 even by accident.
//!
//! **Coordinates are Y-down**, matching Win32 client coordinates: `y` grows
//! downward, `(0,0)` is the top-left. The Swift file carries two different
//! conventions -- `calculateViewBounds` is Y-up for AppKit view coordinates
//! and `spatialSlots` is Y-down -- which is why its two rectangle splitters
//! disagree with each other. Only the Y-down one is ported.

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A pane's identity. The host assigns these and never reuses one, so a
/// `PaneId` is a stable name for a surface for as long as it is open.
///
/// Deviation: Swift's leaf holds the `NSView` itself and compares leaves with
/// `===`, object identity. Rust has no object identity for a value type, and
/// putting an `Rc<RefCell<Pane>>` in the tree would drag the whole host into
/// this file and out of `cargo test`. An opaque id gives the same thing --
/// two leaves are the same leaf iff their ids match -- and lets the tree be
/// `Clone` + `PartialEq` + `Debug` for free.
pub type PaneId = u64;

/// How a split arranges its two children.
///
/// Note the trap, inherited from the Swift naming: `Horizontal` means the
/// children sit side by side, so the *divider* between them is a vertical
/// line. `Vertical` means one above the other. The name describes the
/// arrangement, not the divider.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Axis {
    /// Children laid out left | right.
    Horizontal,
    /// Children laid out top / bottom.
    Vertical,
}

/// Where a newly created pane goes, relative to the pane that was focused
/// when the split was asked for. This is the argument of the `new_split`
/// action.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum NewSplit {
    Left,
    Right,
    Up,
    Down,
}

/// A direction in the laid-out plane. Used for spatial focus movement
/// (`goto_split`) and for moving a divider (`resize_split`).
///
/// Deviation: Swift has four near-identical direction enums (`Direction`,
/// `NewDirection`, `Spatial.Direction`, `FocusDirection`) and tells them
/// apart by the type context that `.left` is written in. Rust has no leading
/// dot, so they have to be named apart anyway; this is `Axis` + `NewSplit` +
/// `Side` + `Focus`, same four concepts.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Side {
    Left,
    Right,
    Up,
    Down,
}

/// Which pane focus should move to.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Focus {
    /// The previous leaf in tree order, wrapping around.
    Previous,
    /// The next leaf in tree order, wrapping around.
    Next,
    /// The nearest pane in a direction on screen.
    Spatial(Side),
}

/// One step down the tree.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Branch {
    Left,
    Right,
}

/// The address of a node: the branches taken from the root to reach it. The
/// empty path is the root.
///
/// Deviation: Swift addresses nodes by passing the `Node` value itself around
/// and searching for it with structural equality (`path(to:)`). That works
/// there because a leaf carries a unique view reference, but it is an O(n)
/// search on every call and it is ambiguous for two structurally identical
/// subtrees. Here the path *is* the address, and `path_of` converts a
/// `PaneId` to one when the caller only has an id.
pub type Path = Vec<Branch>;

/// An axis-aligned rectangle, Y-down.
///
/// Deviation: `CGRect` with no Foundation. Only the four operations this file
/// actually uses are provided.
#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Rect { x, y, w, h }
    }

    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
}

/// A node is either a pane or a division of space between two nodes.
#[derive(Clone, PartialEq, Debug)]
pub enum Node {
    Leaf(PaneId),
    Split(Box<Split>),
}

/// A division of space. `ratio` is the fraction given to `left`; `right` gets
/// the rest.
///
/// For a `Vertical` axis, `left` is the **top** child and `right` is the
/// bottom one. The names are kept from the Swift file so the two can be
/// diffed, but that asymmetry is exactly where its two rectangle splitters
/// drifted apart, so it is worth saying twice.
#[derive(Clone, PartialEq, Debug)]
pub struct Split {
    pub axis: Axis,
    pub ratio: f64,
    pub left: Node,
    pub right: Node,
}

/// What can go wrong.
///
/// Deviation: Swift throws a single `SplitError.viewNotFound` for three
/// different situations, including "the pane exists but has no ancestor split
/// on the axis you asked to resize". Those are told apart here, because the
/// last one is a normal thing for a user to ask for (resizing the only pane)
/// and the host should be able to ignore it quietly rather than treat it as a
/// lost pane.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Error {
    /// No pane with that id is in this tree.
    PaneNotFound,
    /// The path does not address a node in this tree.
    PathInvalid,
    /// The pane has no ancestor split on the axis the resize needs, so there
    /// is no divider to move.
    NoSplitOnAxis,
}

/// The tree of panes for one tab.
#[derive(Clone, PartialEq, Debug, Default)]
pub struct Tree {
    root: Option<Node>,
    /// The pane that is zoomed to fill the whole area, if any.
    ///
    /// Deviation: Swift stores a `Node`, so a whole subtree can be zoomed.
    /// Nothing asks for that -- `toggle_split_zoom` acts on the focused
    /// surface, which is always a leaf -- and storing an id instead makes the
    /// bookkeeping on removal a single comparison instead of a subtree
    /// search.
    zoomed: Option<PaneId>,
}

// ---------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------

impl Tree {
    /// An empty tree.
    pub fn new() -> Self {
        Tree { root: None, zoomed: None }
    }

    /// A tree holding a single pane.
    pub fn with_pane(pane: PaneId) -> Self {
        Tree { root: Some(Node::Leaf(pane)), zoomed: None }
    }

    pub fn root(&self) -> Option<&Node> {
        self.root.as_ref()
    }

    pub fn is_empty(&self) -> bool {
        self.root.is_none()
    }

    /// True if the tree has more than one pane.
    pub fn is_split(&self) -> bool {
        matches!(self.root, Some(Node::Split(_)))
    }

    pub fn zoomed(&self) -> Option<PaneId> {
        self.zoomed
    }

    /// Every pane, in tree order (left to right, top to bottom).
    pub fn panes(&self) -> Vec<PaneId> {
        let mut out = Vec::new();
        if let Some(root) = &self.root {
            root.collect_leaves(&mut out);
        }
        out
    }

    pub fn len(&self) -> usize {
        self.panes().len()
    }

    pub fn contains(&self, pane: PaneId) -> bool {
        self.path_of(pane).is_some()
    }

    /// The address of a pane, or `None` if it is not in this tree.
    pub fn path_of(&self, pane: PaneId) -> Option<Path> {
        let root = self.root.as_ref()?;
        let mut acc = Vec::new();
        if root.find_path(pane, &mut acc) {
            Some(acc)
        } else {
            None
        }
    }

    /// The node at an address.
    pub fn node_at(&self, path: &[Branch]) -> Option<&Node> {
        self.root.as_ref()?.node_at(path)
    }

    /// Split the pane at `at`, putting `new_pane` on the given side of it.
    ///
    /// The new split takes the place of the existing leaf and gets ratio 0.5.
    /// Zoom is always cleared: a new pane the user cannot see is not what
    /// they asked for.
    pub fn insert(&self, new_pane: PaneId, at: PaneId, dir: NewSplit) -> Result<Tree, Error> {
        let root = self.root.as_ref().ok_or(Error::PaneNotFound)?;
        let path = self.path_of(at).ok_or(Error::PaneNotFound)?;

        let (axis, new_on_left) = match dir {
            NewSplit::Left => (Axis::Horizontal, true),
            NewSplit::Right => (Axis::Horizontal, false),
            NewSplit::Up => (Axis::Vertical, true),
            NewSplit::Down => (Axis::Vertical, false),
        };

        let existing = Node::Leaf(at);
        let fresh = Node::Leaf(new_pane);
        let split = Node::Split(Box::new(Split {
            axis,
            ratio: 0.5,
            left: if new_on_left { fresh.clone() } else { existing.clone() },
            right: if new_on_left { existing } else { fresh },
        }));

        Ok(Tree {
            root: Some(root.replacing(&path, split)?),
            zoomed: None,
        })
    }

    /// Close a pane. Its sibling takes the place of their parent split, which
    /// is how a three-pane row becomes a two-pane row rather than leaving a
    /// hole.
    ///
    /// Removing the last pane leaves an empty tree. Removing a pane that is
    /// not in the tree is a no-op.
    pub fn remove(&self, pane: PaneId) -> Tree {
        let Some(root) = &self.root else { return self.clone() };
        let new_root = root.removing_leaf(pane);
        Tree {
            root: new_root,
            zoomed: if self.zoomed == Some(pane) { None } else { self.zoomed },
        }
    }

    /// Close every pane under an address at once. Used when a whole split is
    /// torn down rather than one surface.
    pub fn remove_subtree(&self, path: &[Branch]) -> Result<Tree, Error> {
        let root = self.root.as_ref().ok_or(Error::PathInvalid)?;
        let doomed = root.node_at(path).ok_or(Error::PathInvalid)?;
        let mut gone = Vec::new();
        doomed.collect_leaves(&mut gone);

        let new_root = root.removing_at(path, 0);
        Ok(Tree {
            root: new_root,
            zoomed: match self.zoomed {
                Some(z) if gone.contains(&z) => None,
                other => other,
            },
        })
    }

    /// Zoom a pane, or un-zoom if it is already zoomed. A pane that is not in
    /// the tree is ignored.
    pub fn toggle_zoom(&self, pane: PaneId) -> Tree {
        if !self.contains(pane) {
            return self.clone();
        }
        Tree {
            root: self.root.clone(),
            zoomed: if self.zoomed == Some(pane) { None } else { Some(pane) },
        }
    }

    /// Where focus should go from `from`.
    ///
    /// Deviation: Swift takes a `Node`, which may be a split, and so needs
    /// `leftmostLeaf`/`rightmostLeaf` to decide where a traversal starts.
    /// Focus always lives on a surface, so this takes a `PaneId` and the two
    /// cases collapse into one.
    pub fn focus_target(&self, focus: Focus, from: PaneId) -> Option<PaneId> {
        let leaves = self.panes();
        let idx = leaves.iter().position(|&p| p == from)?;

        match focus {
            Focus::Previous => {
                let n = leaves.len();
                Some(leaves[(idx + n - 1) % n])
            }
            Focus::Next => Some(leaves[(idx + 1) % leaves.len()]),
            Focus::Spatial(side) => {
                let from_path = self.path_of(from)?;
                let spatial = self.spatial(None);
                let candidates = spatial.slots_toward(side, &from_path);
                let best = candidates.first()?;

                // The nearest candidate that is a pane wins. Splits are in
                // the candidate list too because they occupy space, but they
                // cannot hold focus.
                if let Some(leaf) = candidates.iter().find(|s| s.pane.is_some()) {
                    return leaf.pane;
                }

                // Unreachable in practice: a split's bounds contain its
                // children's, so any split that passes the direction filter
                // brings its leaves along with it. Ported anyway, because the
                // Swift file has it and a silent divergence is worse than a
                // dead branch.
                let node = self.node_at(&best.path)?;
                Some(match side {
                    Side::Up | Side::Left => node.leftmost_leaf(),
                    Side::Down | Side::Right => node.rightmost_leaf(),
                })
            }
        }
    }

    /// Reset every ratio so each split divides its space by how many panes
    /// are on each side, counting only panes that are actually laid out along
    /// that split's own axis. A child split on the *other* axis counts as one,
    /// because from this split's point of view it occupies one slot.
    pub fn equalize(&self) -> Tree {
        Tree {
            root: self.root.as_ref().map(|r| r.equalized()),
            zoomed: self.zoomed,
        }
    }

    /// Move the divider nearest to `pane` by `pixels`, in the given
    /// direction, given the area the tree is laid out in.
    ///
    /// The nearest *ancestor* split on the matching axis is the one that
    /// moves: up/down needs a `Vertical` split, left/right a `Horizontal`
    /// one. Note that this moves a boundary rather than growing the pane --
    /// asking to resize `Left` always moves that divider left, whether the
    /// pane is on its left or its right side. That is the Swift behaviour and
    /// it matches what `resize_split` means.
    ///
    /// Ratios are clamped to [0.1, 0.9] so a pane can never be resized to
    /// nothing. Zoom is cleared, since a resize the user cannot see is not
    /// what they asked for.
    pub fn resize(
        &self,
        pane: PaneId,
        pixels: u16,
        side: Side,
        bounds: Rect,
    ) -> Result<Tree, Error> {
        let root = self.root.as_ref().ok_or(Error::PaneNotFound)?;
        let path = self.path_of(pane).ok_or(Error::PaneNotFound)?;

        let wanted = match side {
            Side::Up | Side::Down => Axis::Vertical,
            Side::Left | Side::Right => Axis::Horizontal,
        };

        // Walk up from the pane to the root, taking the first split on the
        // axis we need.
        let mut found: Option<(Path, Split)> = None;
        for i in (0..path.len()).rev() {
            let parent_path = &path[..i];
            if let Some(Node::Split(split)) = root.node_at(parent_path) {
                if split.axis == wanted {
                    found = Some((parent_path.to_vec(), (**split).clone()));
                    break;
                }
            }
        }
        let (split_path, split) = found.ok_or(Error::NoSplitOnAxis)?;

        // How big that split is on screen decides what a pixel is worth.
        let spatial = self.spatial(Some(bounds));
        let slot = spatial
            .slots
            .iter()
            .find(|s| s.path == split_path)
            .ok_or(Error::PathInvalid)?;

        let offset = pixels as f64;
        let delta = match wanted {
            Axis::Horizontal => offset / slot.bounds.w,
            Axis::Vertical => offset / slot.bounds.h,
        };
        let raw = match side {
            Side::Left | Side::Up => split.ratio - delta,
            Side::Right | Side::Down => split.ratio + delta,
        };
        let ratio = raw.clamp(0.1, 0.9);

        let new_split = Node::Split(Box::new(Split { ratio, ..split }));
        Ok(Tree {
            root: Some(root.replacing(&split_path, new_split)?),
            zoomed: None,
        })
    }

    /// Where each pane goes inside `bounds`. This is what the host feeds to
    /// `SetWindowPos` for the child windows.
    ///
    /// A zoomed pane is the only one returned, filling the whole area.
    ///
    /// Deviation: the Swift app has no equivalent -- SwiftUI's `SplitView`
    /// walks the tree itself and zoom is handled in the view layer. Win32 has
    /// no layout engine to hand the tree to, so producing the rectangles is
    /// part of the model here.
    pub fn layout(&self, bounds: Rect) -> Vec<(PaneId, Rect)> {
        let Some(root) = &self.root else { return Vec::new() };

        if let Some(z) = self.zoomed {
            if self.contains(z) {
                return vec![(z, bounds)];
            }
        }

        let mut out = Vec::new();
        root.layout_into(bounds, &mut out);
        out
    }

    /// The spatial map: every node with the rectangle it occupies.
    ///
    /// With `None` for bounds, the rectangle is a grid where every pane is
    /// one unit wide and one unit tall, which is enough for neighbour
    /// searching and does not need to know the window size. With `Some`, the
    /// real ratios apply, which is what a resize needs.
    pub fn spatial(&self, bounds: Option<Rect>) -> Spatial {
        let Some(root) = &self.root else { return Spatial { slots: Vec::new() } };

        let area = match bounds {
            Some(b) => b,
            None => {
                let (w, h) = root.grid_dimensions();
                Rect::new(0.0, 0.0, w as f64, h as f64)
            }
        };

        let mut slots = Vec::new();
        root.spatial_into(area, Vec::new(), &mut slots);
        Spatial { slots }
    }

    /// The size needed to hold every pane at its natural size, assuming a
    /// perfect grid and no padding. Used to fit a window to its content.
    ///
    /// Deviation: Swift reads `NSView.bounds` off the leaf. The size of a
    /// pane is not something this file can know, so the caller supplies it.
    /// That also makes the function testable without a window.
    pub fn natural_size(&self, size_of: &dyn Fn(PaneId) -> (f64, f64)) -> (f64, f64) {
        match &self.root {
            None => (0.0, 0.0),
            Some(root) => root.natural_size(size_of),
        }
    }
}

// ---------------------------------------------------------------------------
// Node
// ---------------------------------------------------------------------------

impl Node {
    fn collect_leaves(&self, out: &mut Vec<PaneId>) {
        match self {
            Node::Leaf(p) => out.push(*p),
            Node::Split(s) => {
                s.left.collect_leaves(out);
                s.right.collect_leaves(out);
            }
        }
    }

    /// The first pane in this subtree, in tree order. For a horizontal split
    /// that is the leftmost pane; for a vertical one, the topmost.
    pub fn leftmost_leaf(&self) -> PaneId {
        match self {
            Node::Leaf(p) => *p,
            Node::Split(s) => s.left.leftmost_leaf(),
        }
    }

    /// The last pane in this subtree, in tree order.
    pub fn rightmost_leaf(&self) -> PaneId {
        match self {
            Node::Leaf(p) => *p,
            Node::Split(s) => s.right.rightmost_leaf(),
        }
    }

    fn find_path(&self, pane: PaneId, acc: &mut Path) -> bool {
        match self {
            Node::Leaf(p) => *p == pane,
            Node::Split(s) => {
                acc.push(Branch::Left);
                if s.left.find_path(pane, acc) {
                    return true;
                }
                acc.pop();

                acc.push(Branch::Right);
                if s.right.find_path(pane, acc) {
                    return true;
                }
                acc.pop();

                false
            }
        }
    }

    fn node_at(&self, path: &[Branch]) -> Option<&Node> {
        let Some((first, rest)) = path.split_first() else { return Some(self) };
        let Node::Split(s) = self else { return None };
        match first {
            Branch::Left => s.left.node_at(rest),
            Branch::Right => s.right.node_at(rest),
        }
    }

    /// A copy of this subtree with the node at `path` replaced. Rebuilds the
    /// spine, same as the Swift version -- a `Node` is a value, so there is
    /// nothing to mutate in place.
    fn replacing(&self, path: &[Branch], new_node: Node) -> Result<Node, Error> {
        let Some((first, rest)) = path.split_first() else { return Ok(new_node) };
        let Node::Split(s) = self else { return Err(Error::PathInvalid) };

        Ok(Node::Split(Box::new(match first {
            Branch::Left => Split {
                axis: s.axis,
                ratio: s.ratio,
                left: s.left.replacing(rest, new_node)?,
                right: s.right.clone(),
            },
            Branch::Right => Split {
                axis: s.axis,
                ratio: s.ratio,
                left: s.left.clone(),
                right: s.right.replacing(rest, new_node)?,
            },
        })))
    }

    /// Remove one pane, collapsing the split that held it. `None` means the
    /// whole subtree is gone.
    fn removing_leaf(&self, pane: PaneId) -> Option<Node> {
        match self {
            Node::Leaf(p) => {
                if *p == pane {
                    None
                } else {
                    Some(self.clone())
                }
            }
            Node::Split(s) => {
                let left = s.left.removing_leaf(pane);
                let right = s.right.removing_leaf(pane);
                match (left, right) {
                    (None, None) => None,
                    (None, Some(r)) => Some(r),
                    (Some(l), None) => Some(l),
                    (Some(l), Some(r)) => Some(Node::Split(Box::new(Split {
                        axis: s.axis,
                        ratio: s.ratio,
                        left: l,
                        right: r,
                    }))),
                }
            }
        }
    }

    /// Remove whatever is at `path`, collapsing the same way.
    fn removing_at(&self, path: &[Branch], depth: usize) -> Option<Node> {
        if depth >= path.len() {
            return None;
        }
        let Node::Split(s) = self else { return Some(self.clone()) };

        let (left, right) = match path[depth] {
            Branch::Left => (s.left.removing_at(path, depth + 1), Some(s.right.clone())),
            Branch::Right => (Some(s.left.clone()), s.right.removing_at(path, depth + 1)),
        };
        match (left, right) {
            (None, None) => None,
            (None, Some(r)) => Some(r),
            (Some(l), None) => Some(l),
            (Some(l), Some(r)) => Some(Node::Split(Box::new(Split {
                axis: s.axis,
                ratio: s.ratio,
                left: l,
                right: r,
            }))),
        }
    }

    fn equalized(&self) -> Node {
        match self {
            Node::Leaf(_) => self.clone(),
            Node::Split(s) => {
                let lw = s.left.weight_along(s.axis);
                let rw = s.right.weight_along(s.axis);
                Node::Split(Box::new(Split {
                    axis: s.axis,
                    ratio: lw as f64 / (lw + rw) as f64,
                    left: s.left.equalized(),
                    right: s.right.equalized(),
                }))
            }
        }
    }

    /// How many slots this subtree takes up along one axis. A child split on
    /// the same axis contributes all of its panes; one on the other axis
    /// contributes a single slot, because it stacks in the other direction.
    fn weight_along(&self, axis: Axis) -> usize {
        match self {
            Node::Leaf(_) => 1,
            Node::Split(s) if s.axis == axis => {
                s.left.weight_along(axis) + s.right.weight_along(axis)
            }
            Node::Split(_) => 1,
        }
    }

    /// Split a rectangle the way this node divides it.
    fn subdivide(split: &Split, bounds: Rect) -> (Rect, Rect) {
        match split.axis {
            Axis::Horizontal => {
                let lw = bounds.w * split.ratio;
                (
                    Rect::new(bounds.x, bounds.y, lw, bounds.h),
                    Rect::new(bounds.x + lw, bounds.y, bounds.w - lw, bounds.h),
                )
            }
            Axis::Vertical => {
                let lh = bounds.h * split.ratio;
                (
                    Rect::new(bounds.x, bounds.y, bounds.w, lh),
                    Rect::new(bounds.x, bounds.y + lh, bounds.w, bounds.h - lh),
                )
            }
        }
    }

    fn layout_into(&self, bounds: Rect, out: &mut Vec<(PaneId, Rect)>) {
        match self {
            Node::Leaf(p) => out.push((*p, bounds)),
            Node::Split(s) => {
                let (l, r) = Node::subdivide(s, bounds);
                s.left.layout_into(l, out);
                s.right.layout_into(r, out);
            }
        }
    }

    fn spatial_into(&self, bounds: Rect, path: Path, out: &mut Vec<Slot>) {
        match self {
            Node::Leaf(p) => out.push(Slot { path, pane: Some(*p), bounds }),
            Node::Split(s) => {
                out.push(Slot { path: path.clone(), pane: None, bounds });
                let (lb, rb) = Node::subdivide(s, bounds);

                let mut lp = path.clone();
                lp.push(Branch::Left);
                s.left.spatial_into(lb, lp, out);

                let mut rp = path;
                rp.push(Branch::Right);
                s.right.spatial_into(rb, rp, out);
            }
        }
    }

    /// Columns and rows needed to draw this subtree on a grid where every
    /// pane is one cell. Used to give the spatial map sensible bounds when
    /// the real window size is not known or not relevant.
    fn grid_dimensions(&self) -> (u32, u32) {
        match self {
            Node::Leaf(_) => (1, 1),
            Node::Split(s) => {
                let (lw, lh) = s.left.grid_dimensions();
                let (rw, rh) = s.right.grid_dimensions();
                match s.axis {
                    Axis::Horizontal => (lw + rw, lh.max(rh)),
                    Axis::Vertical => (lw.max(rw), lh + rh),
                }
            }
        }
    }

    fn natural_size(&self, size_of: &dyn Fn(PaneId) -> (f64, f64)) -> (f64, f64) {
        match self {
            Node::Leaf(p) => size_of(*p),
            Node::Split(s) => {
                let (lw, lh) = s.left.natural_size(size_of);
                let (rw, rh) = s.right.natural_size(size_of);
                match s.axis {
                    Axis::Horizontal => (lw + rw, lh.max(rh)),
                    Axis::Vertical => (lw.max(rw), lh + rh),
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Spatial
// ---------------------------------------------------------------------------

/// One node with the rectangle it occupies.
#[derive(Clone, PartialEq, Debug)]
pub struct Slot {
    pub path: Path,
    /// `Some` for a pane, `None` for a split.
    pub pane: Option<PaneId>,
    pub bounds: Rect,
}

/// The tree flattened into rectangles. Bounds are only meaningful relative to
/// each other unless real bounds were passed to `Tree::spatial`.
#[derive(Clone, PartialEq, Debug)]
pub struct Spatial {
    pub slots: Vec<Slot>,
}

impl Spatial {
    /// Every slot that lies wholly on one side of the slot at `from`,
    /// nearest first.
    ///
    /// "Wholly on one side" means the candidate's near edge is at or past the
    /// reference's far edge, so a pane that merely overlaps does not count as
    /// being to the left of it. Distance is measured between top-left
    /// corners, which is crude -- a tall pane's corner can be far away while
    /// its body is adjacent -- but it is what the macOS app does, and
    /// changing the metric is a behaviour change, not a port.
    ///
    /// Splits are included as well as panes; the caller filters. See
    /// `Tree::focus_target`.
    pub fn slots_toward(&self, side: Side, from: &[Branch]) -> Vec<&Slot> {
        let Some(reference) = self.slots.iter().find(|s| s.path == from) else {
            return Vec::new();
        };
        let r = reference.bounds;

        let mut out: Vec<&Slot> = self
            .slots
            .iter()
            .filter(|s| {
                if s.path == from {
                    return false;
                }
                match side {
                    Side::Left => s.bounds.max_x() <= r.min_x(),
                    Side::Right => s.bounds.min_x() >= r.max_x(),
                    Side::Up => s.bounds.max_y() <= r.min_y(),
                    Side::Down => s.bounds.min_y() >= r.max_y(),
                }
            })
            .collect();

        let distance = |s: &Slot| {
            let dx = s.bounds.min_x() - r.min_x();
            let dy = s.bounds.min_y() - r.min_y();
            (dx * dx + dy * dy).sqrt()
        };
        out.sort_by(|a, b| {
            distance(a)
                .partial_cmp(&distance(b))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        out
    }

    /// Whether the node at `path` touches one edge of the whole laid-out
    /// area. The host uses this to decide when a focus move should leave the
    /// tree instead of staying inside it.
    pub fn borders(&self, side: Side, path: &[Branch]) -> bool {
        let Some(slot) = self.slots.iter().find(|s| s.path == path) else {
            return false;
        };

        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for s in &self.slots {
            min_x = min_x.min(s.bounds.min_x());
            min_y = min_y.min(s.bounds.min_y());
            max_x = max_x.max(s.bounds.max_x());
            max_y = max_y.max(s.bounds.max_y());
        }

        match side {
            Side::Up => slot.bounds.min_y() == min_y,
            Side::Down => slot.bounds.max_y() == max_y,
            Side::Left => slot.bounds.min_x() == min_x,
            Side::Right => slot.bounds.max_x() == max_x,
        }
    }
}

#[cfg(test)]
mod tests;
