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

use polter_split_tree::{Axis, Node, PaneId, Split};

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
    New { cwd: Option<String>, history: Option<String> },
    Split {
        axis: Axis,
        ratio: f64,
        left: Box<Shape>,
        right: Box<Shape>,
    },
}

/// Parse the JSON a caller sent.
///
/// **Refuses rather than repairing.** A ratio outside `(0, 1)`, an unknown
/// key, a split missing a side -- each is a caller who meant something this
/// cannot work out, and quietly choosing a half for them is how a tool comes
/// to report success for a shape nobody asked for.
pub fn parse(v: &serde_json::Value) -> Result<Shape, String> {
    let obj = v.as_object().ok_or_else(|| "each cell must be an object".to_string())?;

    if let Some(p) = obj.get("pane") {
        let s = p
            .as_str()
            .ok_or_else(|| "\"pane\" must be a terminal id as a string".to_string())?;
        return Ok(Shape::Existing(parse_key(s)?));
    }

    if let Some(n) = obj.get("new") {
        let (cwd, history) = match n {
            serde_json::Value::Object(o) => {
                let cwd = match o.get("cwd") {
                    Some(serde_json::Value::String(s)) if !s.is_empty() => Some(s.clone()),
                    _ => None,
                };
                let history = match o.get("history") {
                    Some(serde_json::Value::String(s)) if !s.is_empty() => Some(s.clone()),
                    _ => None,
                };
                (cwd, history)
            }
            serde_json::Value::Null => (None, None),
            _ => return Err("\"new\" must be an object or null".to_string()),
        };
        return Ok(Shape::New { cwd, history });
    }

    let axis = match obj.get("split").and_then(|s| s.as_str()) {
        Some("h") => Axis::Horizontal,
        Some("v") => Axis::Vertical,
        Some(other) => return Err(format!("\"split\" must be \"h\" or \"v\", not {other:?}")),
        None => {
            return Err(
                "a cell must be {\"pane\":…}, {\"new\":…} or {\"split\":\"h\"|\"v\",…}".to_string()
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

    let left = parse(obj.get("left").ok_or_else(|| "a split needs \"left\"".to_string())?)?;
    let right = parse(obj.get("right").ok_or_else(|| "a split needs \"right\"".to_string())?)?;
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
    }
}

/// Every cell that needs a pane made, in the order they will be numbered:
/// its `cwd` and, for task 533's loader, its `history`.
pub fn fresh<'a>(shape: &'a Shape, out: &mut Vec<(&'a Option<String>, &'a Option<String>)>) {
    match shape {
        Shape::Existing(_) => {}
        Shape::New { cwd, history } => out.push((cwd, history)),
        Shape::Split { left, right, .. } => {
            fresh(left, out);
            fresh(right, out);
        }
    }
}

/// Turn the shape into a tree, taking one id from `made` per `new` cell and
/// resolving each named surface to the pane it is.
pub fn to_node(
    shape: &Shape,
    made: &mut std::vec::IntoIter<PaneId>,
    pane_of: &dyn Fn(SurfaceKey) -> Option<PaneId>,
) -> Node {
    match shape {
        // Checked before this runs; a surface with no pane here would have
        // been refused by name.
        Shape::Existing(key) => Node::Leaf(pane_of(*key).unwrap_or(0)),
        Shape::New { .. } => Node::Leaf(made.next().expect("one id per new cell")),
        Shape::Split { axis, ratio, left, right } => Node::Split(Box::new(Split {
            axis: *axis,
            ratio: *ratio,
            left: to_node(left, made, pane_of),
            right: to_node(right, made, pane_of),
        })),
    }
}

/// The shape as it ended up, as JSON, **named by surface**.
///
/// ⚠️ `surface_of` maps this host's private pane numbering back to the
/// handles the core can turn into terminal ids. Emitting the pane numbers --
/// which the first version did -- gives the caller ids it cannot feed back
/// into `terminal_read` or `terminal_send`, **which is the whole reason this
/// call exists** (task 406).
pub fn describe(node: &Node, surface_of: &dyn Fn(PaneId) -> Option<SurfaceKey>) -> serde_json::Value {
    match node {
        Node::Leaf(id) => match surface_of(*id) {
            Some(k) => serde_json::json!({ "pane": format!("0x{k:x}") }),
            // A pane in the tree with no surface is a bug this side, and
            // saying so beats handing back a number from the wrong
            // namespace.
            None => serde_json::json!({ "pane": null }),
        },
        Node::Split(s) => serde_json::json!({
            "split": match s.axis { Axis::Horizontal => "h", Axis::Vertical => "v" },
            "ratio": s.ratio,
            "left": describe(&s.left, surface_of),
            "right": describe(&s.right, surface_of),
        }),
    }
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
    let shape = match parse(&parsed) {
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
        tabs::Op::ApplyLayout(shape, at, outcome.clone()),
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
