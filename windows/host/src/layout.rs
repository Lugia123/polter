//! Rearranging a tab's panes into a shape given from outside.
//!
//! # Why a whole shape arrives at once
//!
//! Placing four workers used to mean four `new_split` calls, and **each one
//! is a round trip against a layout that is still moving**: the person can
//! take focus, another agent can close a pane, and a call that fails half way
//! leaves half a layout with nothing anywhere recording what was meant.
//!
//! It is also the only way to learn which panes were made. `new_split` is
//! queued to the window thread and answers before the op runs -- its own
//! result cell says `will_split`, not `split` -- so the pane it creates has
//! no id to report at the moment it returns. **That is why splitting four
//! times produced a chain**: nothing could name the panes it had just made.
//! ⚠️ It was *not* because a shape needs a subtree operation; every binary
//! tree is reachable by splitting leaves in the right order, and believing
//! otherwise cost a day.
//!
//! # ⚠️ This returns only after draining the window's whole queue
//!
//! Building panes has to happen on the thread that owns windows, and this
//! host does that through the queue. So the shape is queued and then
//! `tabs::run_ops` is called before returning, which is what makes the reply
//! -- the ids of the panes that were made -- available at all.
//!
//! **`run_ops` empties the queue; it does not run one op.** It cannot: `C6`
//! forbids reordering, and skipping ahead to this op would be reordering. So
//! **either everything queued before this runs too, or this cannot answer**.
//! There is no third option, and the first is chosen: any op queued before
//! this one has already run by the time this returns. Said out loud because
//! it is a timing effect nobody would predict from the tool's name.

use std::sync::{Arc, Mutex};

use polter_split_tree::{Axis, Node, PaneId, Split, Stack, Tree};

use crate::ffi::{Action, Surface};
use crate::{tabs, wlogf};

/// `ghostty_action_poltergeist_layout_result_e`. **`unsupported` (0) is not
/// written here**: it is what an apprt that does not do this leaves behind,
/// and this one does.
const APPLIED: i32 = 1;
const REFUSED: i32 = 2;

/// What the op writes back, on the window thread, for this call to read.
pub type Outcome = Arc<Mutex<Option<Result<String, String>>>>;

/// One cell of the shape a caller asked for, before ids are handed out.
/// A surface, as the core hands it over: the same handle every action target
/// carries. **Not a `PaneId`** -- see the note on `Shape::Existing`.
pub type SurfaceKey = usize;

#[derive(Debug)]
pub enum Shape {
    /// A pane that is already in this tab, **named by its surface**.
    ///
    /// ⚠️ **A `PaneId` is this host's private numbering and no agent can
    /// learn it** -- no tool hands one out, and the first version of this
    /// took one anyway. A caller following the tool description gave the
    /// terminal id it uses everywhere else and was told the layout left out
    /// a pane that was in it (task 406). The core translates terminal ids to
    /// surfaces on the way in and back on the way out, so the only
    /// namespace that crosses this boundary is the one the caller has.
    Existing(SurfaceKey),
    /// A pane to make. `cwd` is where its shell starts, or the default.
    ///
    /// `history` is `ghostty_surface_config_s.history_restore`
    /// (`Project.Leaf.history`) for the pane this cell creates -- passed
    /// through unread, same as `cwd`. **Not part of the `poltergeist_layout`
    /// tool's documented contract**: it exists so task 533's project loader
    /// can reuse this pipeline rather than build a second way to create a
    /// tab, and every caller that never sends a `"history"` key (which is
    /// every caller except that loader, today) gets `None` here exactly as
    /// before this field existed.
    ///
    /// `scrollback` is `ghostty_surface_config_s.scrollback_restore`: the
    /// absolute path of a snapshot saved with a project. **Only a project
    /// can put one here** (`parse_project`); `parse`, which is what the
    /// `poltergeist_layout` tool reaches, refuses the key. The core deletes a
    /// snapshot it cannot decode, so accepting a path from a caller would be
    /// letting any agent name a `.snap` file for the core to remove.
    New { cwd: Option<String>, history: Option<String>, scrollback: Option<String> },
    Split {
        axis: Axis,
        ratio: f64,
        left: Box<Shape>,
        right: Box<Shape>,
    },
    /// Several terminals in one place, one in front (task 1583; macOS's
    /// `PoltergeistLayoutShape.stack`): `{"stack":[cell,…],"shown":n}`.
    /// Every member is an `Existing` or a `New` -- never a split or another
    /// stack -- there are two or more, and `shown` is one of them.
    Stack { members: Vec<Shape>, shown: usize },
}

/// Parse the JSON a caller sent.
///
/// **Refuses rather than repairing.** A ratio outside `(0, 1)`, an unknown
/// key, a split missing a side -- each is a caller who meant something this
/// cannot work out, and quietly choosing a half for them is how a tool comes
/// to report success for a shape nobody asked for.
pub fn parse(v: &serde_json::Value) -> Result<Shape, String> {
    parse_from(v, Source::Tool)
}

/// `parse`, for a shape a saved project built (`project::to_layout_shape`):
/// the one source allowed to carry `"scrollback"`. See `Shape::New`.
pub fn parse_project(v: &serde_json::Value) -> Result<Shape, String> {
    parse_from(v, Source::Project)
}

#[derive(Clone, Copy, PartialEq)]
enum Source {
    Tool,
    Project,
}

fn parse_from(v: &serde_json::Value, source: Source) -> Result<Shape, String> {
    let obj = v.as_object().ok_or_else(|| "each cell must be an object".to_string())?;

    if let Some(p) = obj.get("pane") {
        let s = p
            .as_str()
            .ok_or_else(|| "\"pane\" must be a terminal id as a string".to_string())?;
        return Ok(Shape::Existing(parse_key(s)?));
    }

    if let Some(n) = obj.get("new") {
        let (cwd, history, scrollback) = match n {
            serde_json::Value::Object(o) => {
                let cwd = match o.get("cwd") {
                    Some(serde_json::Value::String(s)) if !s.is_empty() => Some(s.clone()),
                    _ => None,
                };
                let history = match o.get("history") {
                    Some(serde_json::Value::String(s)) if !s.is_empty() => Some(s.clone()),
                    _ => None,
                };
                let scrollback = match (o.get("scrollback"), source) {
                    (None, _) => None,
                    (Some(_), Source::Tool) => {
                        return Err("\"scrollback\" is not accepted here; only a saved project restores one".to_string())
                    }
                    (Some(serde_json::Value::String(s)), Source::Project) if !s.is_empty() => Some(s.clone()),
                    (Some(_), Source::Project) => None,
                };
                (cwd, history, scrollback)
            }
            serde_json::Value::Null => (None, None, None),
            _ => return Err("\"new\" must be an object or null".to_string()),
        };
        return Ok(Shape::New { cwd, history, scrollback });
    }

    // The macOS host's words, refusal for refusal (`PoltergeistLayoutShape`).
    if let Some(listed) = obj.get("stack") {
        let listed = listed.as_array().ok_or_else(|| "\"stack\" must be a list of cells".to_string())?;
        // One is not a stack and none is nothing at all.
        if listed.len() < 2 {
            return Err("a stack holds two terminals or more; for one, write the cell itself".to_string());
        }
        let members = listed.iter().map(|m| parse_from(m, source)).collect::<Result<Vec<_>, _>>()?;
        if members.iter().any(|m| matches!(m, Shape::Split { .. } | Shape::Stack { .. })) {
            return Err(
                "a stack's members are terminals: each must be {\"pane\":…} or {\"new\":…}, not a split or another stack".to_string()
            );
        }
        let shown = match obj.get("shown") {
            None => 0,
            Some(v) => {
                let n = v
                    .as_u64()
                    .ok_or_else(|| "\"shown\" must be a whole number: which member is in front, counting from 0".to_string())?;
                if n as usize >= members.len() {
                    return Err(format!("\"shown\" is {n}, and the stack has members 0 to {}", members.len() - 1));
                }
                n as usize
            }
        };
        return Ok(Shape::Stack { members, shown });
    }

    let axis = match obj.get("split").and_then(|s| s.as_str()) {
        Some("h") => Axis::Horizontal,
        Some("v") => Axis::Vertical,
        Some(other) => return Err(format!("\"split\" must be \"h\" or \"v\", not {other:?}")),
        None => {
            return Err(
                "a cell must be {\"pane\":…}, {\"new\":…}, {\"split\":\"h\"|\"v\",…} or {\"stack\":[…]}".to_string()
            )
        }
    };

    // **A ratio out of range is refused, not clamped.** Clamping would apply
    // a layout the caller did not ask for and report that it worked.
    let ratio = match obj.get("ratio") {
        None => 0.5,
        Some(r) => {
            let f = r.as_f64().ok_or_else(|| "\"ratio\" must be a number".to_string())?;
            if !(f > 0.0 && f < 1.0) {
                return Err(format!("\"ratio\" must be between 0 and 1, not {f}"));
            }
            f
        }
    };

    let left = parse_from(obj.get("left").ok_or_else(|| "a split needs \"left\"".to_string())?, source)?;
    let right = parse_from(obj.get("right").ok_or_else(|| "a split needs \"right\"".to_string())?, source)?;
    Ok(Shape::Split { axis, ratio, left: Box::new(left), right: Box::new(right) })
}

/// The surface handle the core substituted for the caller's terminal id.
///
/// Written as `0x…` like every other handle in this ABI. ⚠️ **The caller
/// never sees this**: it wrote a terminal id and the core replaced it, for
/// the reason on `Shape::Existing`.
fn parse_key(s: &str) -> Result<SurfaceKey, String> {
    let t = s.trim();
    let r = if let Some(hex) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16)
    } else {
        t.parse::<u64>()
    };
    r.map_err(|_| format!("{s:?} is not a terminal id"))
        .map(|v| v as SurfaceKey)
}

/// Every existing pane the shape names, in the order it names them.
pub fn existing(shape: &Shape, out: &mut Vec<SurfaceKey>) {
    match shape {
        Shape::Existing(id) => out.push(*id),
        Shape::New { .. } => {}
        Shape::Split { left, right, .. } => {
            existing(left, out);
            existing(right, out);
        }
        Shape::Stack { members, .. } => members.iter().for_each(|m| existing(m, out)),
    }
}

/// A cell that needs a pane made: what `Shape::New` carries, by name, so the
/// three strings cannot be taken in the wrong order.
pub struct Fresh<'a> {
    pub cwd: &'a Option<String>,
    pub history: &'a Option<String>,
    pub scrollback: &'a Option<String>,
}

/// Every cell that needs a pane made, in the order they will be numbered.
pub fn fresh<'a>(shape: &'a Shape, out: &mut Vec<Fresh<'a>>) {
    match shape {
        Shape::Existing(_) => {}
        Shape::New { cwd, history, scrollback } => out.push(Fresh { cwd, history, scrollback }),
        Shape::Split { left, right, .. } => {
            fresh(left, out);
            fresh(right, out);
        }
        Shape::Stack { members, .. } => members.iter().for_each(|m| fresh(m, out)),
    }
}

/// Turn the shape into a tree, taking one id from `made` per `new` cell (in
/// `fresh`'s order) and resolving each named surface to the pane it is. A
/// stack cell is a leaf showing its `shown` member and a row of the tree's
/// stacks. **Refused when the tree refuses the stacks** -- a terminal in
/// two places, which the caller's checks already stop.
pub fn to_tree(
    shape: &Shape,
    made: &mut std::vec::IntoIter<PaneId>,
    pane_of: &dyn Fn(SurfaceKey) -> Option<PaneId>,
) -> Result<Tree, String> {
    let mut stacks = Vec::new();
    let root = to_node(shape, made, pane_of, &mut stacks);
    Tree::with_root_and_stacks(root, stacks).map_err(|e| format!("the layout's stacks do not fit its shape ({e:?})"))
}

fn to_node(
    shape: &Shape,
    made: &mut std::vec::IntoIter<PaneId>,
    pane_of: &dyn Fn(SurfaceKey) -> Option<PaneId>,
    stacks: &mut Vec<Stack>,
) -> Node {
    match shape {
        // Checked before this runs; a surface with no pane here would have
        // been refused by name.
        Shape::Existing(key) => Node::Leaf(pane_of(*key).unwrap_or(0)),
        Shape::New { .. } => Node::Leaf(made.next().expect("one id per new cell")),
        Shape::Split { axis, ratio, left, right } => Node::Split(Box::new(Split {
            axis: *axis,
            ratio: *ratio,
            left: to_node(left, made, pane_of, stacks),
            right: to_node(right, made, pane_of, stacks),
        })),
        Shape::Stack { members, shown } => {
            let ids: Vec<PaneId> = members
                .iter()
                .map(|m| match to_node(m, made, pane_of, stacks) {
                    Node::Leaf(id) => id,
                    // Refused when it was read: a member is a terminal.
                    Node::Split(_) => 0,
                })
                .collect();
            let front = ids.get(*shown).copied().unwrap_or(0);
            stacks.push(Stack { shown: front, members: ids });
            Node::Leaf(front)
        }
    }
}

/// The shape as it ended up, as JSON, **named by surface**.
///
/// ⚠️ `surface_of` maps this host's private pane numbering back to the
/// handles the core can turn into terminal ids. Emitting the pane numbers --
/// which the first version did -- gives the caller ids it cannot feed back
/// into `terminal_read` or `terminal_send`, **which is the whole reason this
/// call exists** (task 406).
// `key_of`, not `surface_of`: that name is a real function in `tabs.rs` that
// takes the window lock, and `lock-reentry.py` matches callees by name -- so
// a parameter wearing it made this pure walk, and every other `describe` by
// the same bare name (`project::describe` inside a `with_windows` closure),
// read as taking the lock while it was held.
///
/// A place holding a stack is said as the stack, every member of it in the
/// order of its tabs and which is in front (task 1583; macOS's
/// `describingForLayoutReply`): a terminal behind another is never missing
/// from what the caller is told is there.
pub fn describe(tree: &Tree, key_of: &dyn Fn(PaneId) -> Option<SurfaceKey>) -> serde_json::Value {
    match tree.root() {
        Some(root) => describe_node(tree, root, key_of),
        None => serde_json::Value::Null,
    }
}

fn describe_pane(id: PaneId, key_of: &dyn Fn(PaneId) -> Option<SurfaceKey>) -> serde_json::Value {
    match key_of(id) {
        Some(k) => serde_json::json!({ "pane": format!("0x{k:x}") }),
        // A pane in the tree with no surface is a bug this side, and
        // saying so beats handing back a number from the wrong
        // namespace.
        None => serde_json::json!({ "pane": null }),
    }
}

fn describe_node(tree: &Tree, node: &Node, key_of: &dyn Fn(PaneId) -> Option<SurfaceKey>) -> serde_json::Value {
    match node {
        Node::Leaf(id) => match tree.stack_of(*id) {
            Some(s) => serde_json::json!({
                "stack": s.members.iter().map(|m| describe_pane(*m, key_of)).collect::<Vec<_>>(),
                "shown": s.members.iter().position(|m| *m == s.shown).unwrap_or(0),
            }),
            None => describe_pane(*id, key_of),
        },
        Node::Split(s) => serde_json::json!({
            "split": match s.axis { Axis::Horizontal => "h", Axis::Vertical => "v" },
            "ratio": s.ratio,
            "left": describe_node(tree, &s.left, key_of),
            "right": describe_node(tree, &s.right, key_of),
        }),
    }
}

/// Where a tool's shape goes (task 1571), read from the core's envelope.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Where {
    /// The tab of the pane the action was aimed at.
    Here,
    /// A new tab right of the tab holding this surface, in its window.
    NewTabBeside(SurfaceKey),
    /// A new window.
    NewWindow,
}

/// The core's envelope for a tool layout: `{"layout": cell, "into": …}`
/// (`App.poltergeistLayout`, task 1571). The cell is read by `parse`, so a
/// tool shape still cannot carry a snapshot path.
pub fn parse_envelope(v: &serde_json::Value) -> Result<(Shape, Where), String> {
    let obj = v.as_object().ok_or_else(|| "the layout did not arrive in its envelope".to_string())?;
    let cell = obj.get("layout").ok_or_else(|| "the layout did not arrive in its envelope".to_string())?;
    let shape = parse(cell)?;
    let bad = || "\"into\" must be {\"new_tab_beside\":…} or {\"new_window\":true}".to_string();
    let into = match obj.get("into") {
        None | Some(serde_json::Value::Null) => Where::Here,
        Some(serde_json::Value::Object(o)) if o.len() == 1 => {
            if o.get("new_window") == Some(&serde_json::Value::Bool(true)) {
                Where::NewWindow
            } else if let Some(s) = o.get("new_tab_beside").and_then(|v| v.as_str()) {
                Where::NewTabBeside(parse_key(s)?)
            } else {
                return Err(bad());
            }
        }
        Some(_) => return Err(bad()),
    };
    Ok((shape, into))
}

/// A refusal whose code is not `Refused`, in the form the core reads it
/// (`App.polterRefusal`): `{"code","message"}`.
pub fn coded(code: &str, message: &str) -> String {
    serde_json::json!({ "code": code, "message": message }).to_string()
}

/// Perform `polter_tab_move` (task 1571): queued and drained like a layout,
/// for the same reason -- it moves windows, which is the window thread's.
pub fn perform_tab_move(action: &Action, target: Option<Surface>) -> bool {
    let (index, window, out) = action.as_polter_tab_move();
    let write = |code: i32, text: &str| {
        if out.is_null() {
            return;
        }
        unsafe {
            (*out).result = code;
            if !(*out).buf.is_null() && (*out).cap > 0 {
                let n = text.len().min((*out).cap);
                std::ptr::copy_nonoverlapping(text.as_ptr(), (*out).buf, n);
                (*out).len = n;
            }
        }
    };
    let Some(surface) = target else {
        write(REFUSED, "the tab move named no terminal");
        return false;
    };
    let Some(frame) = tabs::frame_of_surface(surface) else {
        write(REFUSED, "that terminal is not in a window this host is tracking");
        return false;
    };
    let outcome: Outcome = Arc::new(Mutex::new(None));
    tabs::post_op(
        frame,
        tabs::Op::MoveTabForTool(surface as usize, index as usize, window as usize, outcome.clone()),
        "tab move action",
    );
    tabs::drain_for_layout(frame);
    let answer = outcome.lock().ok().and_then(|mut o| o.take());
    match answer {
        Some(Ok(json)) => write(APPLIED, &json),
        Some(Err(why)) => write(REFUSED, &why),
        None => {
            write(REFUSED, "the tab move was queued and did not run; the window may have closed");
            wlogf!(frame, "[tab-move] queued op produced no answer");
        }
    }
    true
}

/// Perform `polter_highlight` (task 1690): queued and drained like a tab
/// move, so the answer -- what was switched, whether the window came
/// forward -- is read before this returns (#1689's interface, section 2).
pub fn perform_highlight(action: &Action, target: Option<Surface>) -> bool {
    let (seconds, label, out) = action.as_polter_highlight();
    let write = |code: i32, text: &str| {
        if out.is_null() {
            return;
        }
        unsafe {
            (*out).result = code;
            if !(*out).buf.is_null() && (*out).cap > 0 {
                let n = text.len().min((*out).cap);
                std::ptr::copy_nonoverlapping(text.as_ptr(), (*out).buf, n);
                (*out).len = n;
            }
        }
    };
    let Some(surface) = target else {
        write(REFUSED, &coded("NotShown", "the highlight named no terminal"));
        return false;
    };
    let Some(frame) = tabs::frame_of_surface(surface) else {
        write(REFUSED, &coded("NotShown", "that terminal is in no window this host shows; the quick terminal is not brought out for it"));
        return false;
    };
    let outcome: Outcome = Arc::new(Mutex::new(None));
    tabs::post_op(frame, tabs::Op::Highlight(surface as usize, seconds, label, outcome.clone()), "highlight action");
    tabs::drain_for_layout(frame);
    let answer = outcome.lock().ok().and_then(|mut o| o.take());
    match answer {
        Some(Ok(json)) => write(APPLIED, &json),
        Some(Err(why)) => write(REFUSED, &why),
        None => {
            write(REFUSED, &coded("HighlightNotRun", "the highlight was queued and did not run; the window may have closed"));
            wlogf!(frame, "[highlight] queued op produced no answer");
        }
    }
    true
}

/// Perform `poltergeist_layout`.
pub fn perform(action: &Action, target: Option<Surface>) -> bool {
    let (spec, out) = action.as_poltergeist_layout();

    let write = |code: i32, text: &str| {
        if out.is_null() {
            return;
        }
        unsafe {
            (*out).result = code;
            if !(*out).buf.is_null() && (*out).cap > 0 {
                let n = text.len().min((*out).cap);
                std::ptr::copy_nonoverlapping(text.as_ptr(), (*out).buf, n);
                (*out).len = n;
            }
        }
    };

    let Some(surface) = target else {
        write(REFUSED, "the layout named no terminal");
        return false;
    };
    let Some(frame) = tabs::frame_of_surface(surface) else {
        write(REFUSED, "that terminal is not in a window this host is tracking");
        return false;
    };

    let parsed: serde_json::Value = match serde_json::from_str(&spec) {
        Ok(v) => v,
        Err(e) => {
            write(REFUSED, &format!("the layout is not JSON: {e}"));
            return true;
        }
    };
    let (shape, into) = match parse_envelope(&parsed) {
        Ok(s) => s,
        Err(why) => {
            write(REFUSED, &why);
            return true;
        }
    };

    let outcome: Outcome = Arc::new(Mutex::new(None));
    wlogf!(frame, "[layout] queued; draining this window's queue to answer");
    // **The pane the call named travels with the shape.** It is what says
    // which tab; without it the op lands on whichever tab is in front by the
    // time it runs (task 407).
    let at = tabs::pane_id_of_surface(surface);
    tabs::post_op(
        frame,
        tabs::Op::ArrangeLayout(shape, at, into, outcome.clone()),
        "layout action",
    );

    // **The queue is drained here, and that is why this can answer at all.**
    // See the note at the top of this file: everything queued before this op
    // runs too, because the queue may not be reordered.
    tabs::drain_for_layout(frame);

    let answer = outcome.lock().ok().and_then(|mut o| o.take());
    match answer {
        Some(Ok(json)) => {
            write(APPLIED, &json);
            true
        }
        Some(Err(why)) => {
            write(REFUSED, &why);
            true
        }
        None => {
            // The op did not run: the window went, or the queue refused it.
            write(REFUSED, "the layout was queued and did not run; the window may have closed");
            wlogf!(frame, "[layout] queued op produced no answer");
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Task 1583: a stack cell is read the way the macOS host reads it,
    /// built into one place of the tree, and said back as a stack.
    #[test]
    fn a_stack_cell_is_one_place_holding_its_members_and_comes_back_as_one() {
        let v = serde_json::json!({ "split": "h",
            "left": { "pane": "0x10" },
            "right": { "stack": [ { "pane": "0x20" }, { "new": null }, { "pane": "0x30" } ], "shown": 1 } });
        let shape = parse(&v).expect("a stack cell reads");
        let mut named = Vec::new();
        existing(&shape, &mut named);
        assert_eq!(named, [0x10, 0x20, 0x30]);
        let mut wanted = Vec::new();
        fresh(&shape, &mut wanted);
        assert_eq!(wanted.len(), 1);
        // 0x10 -> pane 1, 0x20 -> 2, 0x30 -> 3; the new one is 9.
        let pane_of = |k: SurfaceKey| match k { 0x10 => Some(1), 0x20 => Some(2), 0x30 => Some(3), _ => None };
        let mut made = vec![9].into_iter();
        let tree = to_tree(&shape, &mut made, &pane_of).expect("the tree takes it");
        assert_eq!(tree.shown_panes(), [1, 9]);
        assert_eq!(tree.members(), [1, 2, 9, 3]);
        let key_of = |p: PaneId| match p { 1 => Some(0x10), 2 => Some(0x20), 3 => Some(0x30), 9 => Some(0x90), _ => None };
        let back = describe(&tree, &key_of);
        assert_eq!(back["right"], serde_json::json!({ "stack": [ { "pane": "0x20" }, { "pane": "0x90" }, { "pane": "0x30" } ], "shown": 1 }));
        assert_eq!(back["left"], serde_json::json!({ "pane": "0x10" }));
    }

    #[test]
    fn a_stack_cell_is_refused_in_the_macos_hosts_words() {
        let refused = |v: serde_json::Value| parse(&v).err().expect("refused");
        assert_eq!(refused(serde_json::json!({ "stack": [ { "pane": "0x1" } ] })), "a stack holds two terminals or more; for one, write the cell itself");
        assert!(refused(serde_json::json!({ "stack": [ { "pane": "0x1" }, { "split": "h", "left": { "new": null }, "right": { "new": null } } ] })).starts_with("a stack's members are terminals"));
        assert_eq!(refused(serde_json::json!({ "stack": [ { "pane": "0x1" }, { "new": null } ], "shown": 2 })), "\"shown\" is 2, and the stack has members 0 to 1");
        assert!(refused(serde_json::json!({ "stack": [ { "pane": "0x1" }, { "new": null } ], "shown": true })).starts_with("\"shown\" must be a whole number"));
        assert_eq!(refused(serde_json::json!({ "stack": "no" })), "\"stack\" must be a list of cells");
        // Left out, the first is in front.
        assert!(matches!(parse(&serde_json::json!({ "stack": [ { "pane": "0x1" }, { "new": null } ] })), Ok(Shape::Stack { shown: 0, .. })));
    }

    /// **The tool cannot name a snapshot.** The core deletes a snapshot it
    /// cannot decode, so a `"scrollback"` accepted here would let any agent
    /// pick a `.snap` file for the core to remove. Refused, not ignored: a
    /// caller who sent it meant something this will not do.
    #[test]
    fn the_layout_tool_refuses_a_scrollback_path() {
        let v = serde_json::json!({ "split": "h", "left": { "new": null },
            "right": { "new": { "cwd": "/a", "scrollback": "C:\\x\\0.snap" } } });
        let err = parse(&v).err().expect("the tool path must refuse it");
        assert!(err.contains("scrollback"), "{err}");
    }

    /// The envelope says where the shape goes, and a key spelled wrong is
    /// refused rather than read as "here" -- which would lay the shape out
    /// over the tab the caller was trying to leave alone (task 1571).
    #[test]
    fn the_envelope_says_where_the_shape_goes() {
        let here = serde_json::json!({ "layout": { "pane": "0x10" } });
        assert_eq!(parse_envelope(&here).unwrap().1, Where::Here);
        let win = serde_json::json!({ "layout": { "pane": "0x10" }, "into": { "new_window": true } });
        assert_eq!(parse_envelope(&win).unwrap().1, Where::NewWindow);
        let tab = serde_json::json!({ "layout": { "pane": "0x10" }, "into": { "new_tab_beside": "0x2a" } });
        assert_eq!(parse_envelope(&tab).unwrap().1, Where::NewTabBeside(0x2a));
        let typo = serde_json::json!({ "layout": { "pane": "0x10" }, "into": { "new_tab": "0x2a" } });
        assert!(parse_envelope(&typo).is_err());
        let bare = serde_json::json!({ "pane": "0x10" });
        assert!(parse_envelope(&bare).is_err());
    }

    /// And a project's shape carries it, at any depth -- the source has to
    /// reach the nested cells, not just the root.
    #[test]
    fn a_project_shape_carries_its_scrollback_paths_down_the_tree() {
        let v = serde_json::json!({ "split": "v", "left": { "new": { "scrollback": "/p/x.scrollback/0.snap" } },
            "right": { "split": "h", "left": { "new": null },
                       "right": { "new": { "cwd": "/b", "scrollback": "/p/x.scrollback/2.snap" } } } });
        let shape = parse_project(&v).expect("a project shape parses");
        let mut cells = Vec::new();
        fresh(&shape, &mut cells);
        let got: Vec<Option<&str>> = cells.iter().map(|c| c.scrollback.as_deref()).collect();
        assert_eq!(got, [Some("/p/x.scrollback/0.snap"), None, Some("/p/x.scrollback/2.snap")]);
    }
}
