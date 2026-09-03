//! What the core asks the pointer to look like, and the half that makes it stick.
//!
//! # Two halves, and only the second one is visible
//!
//! The core announces a pointer shape with `GHOSTTY_ACTION_MOUSE_SHAPE` and
//! its visibility with `GHOSTTY_ACTION_MOUSE_VISIBILITY`. Recording what it
//! asked for is the easy half. **The half that makes it stick is
//! `WM_SETCURSOR`**: the pane's window class carries `IDC_ARROW`, so
//! `DefWindowProc` puts the arrow back the moment the pointer moves. A host
//! that called `SetCursor` in the action and stopped there would set the
//! cursor once and lose it on the next mouse message -- and both versions
//! answer the core `true`.
//!
//! # The table is lossy, and it says where
//!
//! `ghostty_action_mouse_shape_e` has thirty-four members; Win32 ships about
//! fourteen stock cursors. Some shapes have an exact Win32 twin, some have a
//! near relative, and some have nothing at all. **Every pick carries which of
//! the three it was, and the action log prints it**, because a shape that
//! quietly fell back to the arrow and a shape that was mapped correctly look
//! identical on screen. They do not look identical in the log:
//!
//! ```text
//! [action] mouse_shape 8 (text) -> IDC_IBEAM [exact]
//! [action] mouse_shape 1 (context_menu) -> IDC_ARROW [fallback]
//! ```
//!
//! # Why visibility needs a push and shape does not
//!
//! Windows sends `WM_SETCURSOR` when the pointer *moves*. A shape change
//! always coincides with pointer movement -- the core changes it because the
//! pointer entered a link, or left one -- so `WM_SETCURSOR` is enough.
//!
//! **Hiding is the opposite case.** The core hides the pointer when the user
//! *types*, which is exactly when the pointer is not moving and no
//! `WM_SETCURSOR` will arrive. By the time one does, the pointer has moved and
//! the core has already asked for it back. Recording the flag and waiting
//! would therefore hide the pointer **never**, while looking in every other
//! respect like an implementation. So the action posts
//! `WM_POLTER_MOUSE_VISIBILITY` to the pane, and the pane hides it there --
//! on the thread that owns the window, which is where `SetCursor` belongs.
//!
//! `SetCursor(None)` rather than `ShowCursor(false)`: `ShowCursor` keeps a
//! per-thread counter that has to be balanced exactly, and an unbalanced one
//! leaves the pointer invisible over the whole desktop. The next
//! `WM_SETCURSOR` brings it back by itself, which is also the semantics macOS
//! uses (`setHiddenUntilMouseMoves`).

use std::sync::Mutex;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{HWND, POINT};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::hlogf;

/// Posted to a **pane** window when the core changed the pointer's visibility.
///
/// `WM_APP + 13`: every smaller offset is spoken for somewhere in this crate
/// (`tabs::WM_POLTER_OP`, the palette, search, the key-sequence overlay, the
/// HUD, settings, the menu self-test, the prompt). Message ids only have to be
/// unique per window class, but a shared numbering is one fewer thing to be
/// wrong about.
pub const WM_POLTER_MOUSE_VISIBILITY: u32 = WM_APP + 13;

/// How well the Win32 cursor answers the shape the core asked for.
///
/// **Three values, not two.** "There is a related cursor" and "there is
/// nothing and this is the arrow" are different amounts of wrong, and a
/// two-valued version would file them together -- so the log could no longer
/// tell a shape that degraded from a shape that was never going to work.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fidelity {
    /// Win32 ships this cursor.
    Exact,
    /// Win32 ships something related, and it is being used instead.
    Substitute,
    /// Win32 ships nothing close. The arrow, and the log says so.
    Fallback,
}

impl Fidelity {
    pub fn name(self) -> &'static str {
        match self {
            Fidelity::Exact => "exact",
            Fidelity::Substitute => "substitute",
            Fidelity::Fallback => "fallback",
        }
    }
}

/// One row of the table: what the core called it, what we load, and how good
/// the answer is.
pub struct Pick {
    /// The core's name for the shape, for the log. An unknown ordinal reads
    /// `unknown`.
    pub shape: &'static str,
    pub cursor: PCWSTR,
    /// The `IDC_*` identifier by name, because `PCWSTR` prints as a pointer.
    pub cursor_name: &'static str,
    pub fidelity: Fidelity,
}

/// The shape the core sent, as a Win32 cursor.
///
/// The ordinals are `ghostty_action_mouse_shape_e` in `include/ghostty.h`, in
/// declaration order, starting at zero. **Written out rather than computed**:
/// the enum is a C ABI and the only thing that keeps this in agreement with it
/// is that both are lists somebody can read side by side.
///
/// An ordinal outside the enum is not an error to refuse -- the core may grow
/// a member before this table does. It takes the arrow and says `unknown`,
/// which is the one case where the log line is the whole of the warning.
pub fn pick(shape: i32) -> Pick {
    let (name, cursor, cursor_name, fidelity) = match shape {
        0 => ("default", IDC_ARROW, "IDC_ARROW", Fidelity::Exact),
        // Win32 has no context-menu pointer. `IDC_ARROW` is not a near miss,
        // it is the absence of an answer.
        1 => ("context_menu", IDC_ARROW, "IDC_ARROW", Fidelity::Fallback),
        2 => ("help", IDC_HELP, "IDC_HELP", Fidelity::Exact),
        3 => ("pointer", IDC_HAND, "IDC_HAND", Fidelity::Exact),
        4 => ("progress", IDC_APPSTARTING, "IDC_APPSTARTING", Fidelity::Exact),
        5 => ("wait", IDC_WAIT, "IDC_WAIT", Fidelity::Exact),
        // CSS `cell` is a thick plus; `IDC_CROSS` is a thin one. Close enough
        // to be worth using and different enough to be worth saying.
        6 => ("cell", IDC_CROSS, "IDC_CROSS", Fidelity::Substitute),
        7 => ("crosshair", IDC_CROSS, "IDC_CROSS", Fidelity::Exact),
        8 => ("text", IDC_IBEAM, "IDC_IBEAM", Fidelity::Exact),
        // No sideways I-beam in Win32. The upright one at least says "text".
        9 => ("vertical_text", IDC_IBEAM, "IDC_IBEAM", Fidelity::Substitute),
        10 => ("alias", IDC_ARROW, "IDC_ARROW", Fidelity::Fallback),
        11 => ("copy", IDC_ARROW, "IDC_ARROW", Fidelity::Fallback),
        12 => ("move", IDC_SIZEALL, "IDC_SIZEALL", Fidelity::Exact),
        // Win32 has one refusal cursor and CSS has two. `no_drop` and
        // `not_allowed` therefore land on the same one, and only one of them
        // is an exact answer.
        13 => ("no_drop", IDC_NO, "IDC_NO", Fidelity::Substitute),
        14 => ("not_allowed", IDC_NO, "IDC_NO", Fidelity::Exact),
        // No open hand and no closed fist. `IDC_HAND` is a hand, which is the
        // most this platform has to say -- and it makes `grab` and `grabbing`
        // indistinguishable on screen. That is a real loss, recorded here
        // rather than discovered.
        15 => ("grab", IDC_HAND, "IDC_HAND", Fidelity::Substitute),
        16 => ("grabbing", IDC_HAND, "IDC_HAND", Fidelity::Substitute),
        17 => ("all_scroll", IDC_SIZEALL, "IDC_SIZEALL", Fidelity::Exact),
        18 => ("col_resize", IDC_SIZEWE, "IDC_SIZEWE", Fidelity::Exact),
        19 => ("row_resize", IDC_SIZENS, "IDC_SIZENS", Fidelity::Exact),
        // The eight compass directions collapse onto four double-headed
        // cursors, which is what Win32 has: it names an axis, not a side.
        20 => ("n_resize", IDC_SIZENS, "IDC_SIZENS", Fidelity::Exact),
        21 => ("e_resize", IDC_SIZEWE, "IDC_SIZEWE", Fidelity::Exact),
        22 => ("s_resize", IDC_SIZENS, "IDC_SIZENS", Fidelity::Exact),
        23 => ("w_resize", IDC_SIZEWE, "IDC_SIZEWE", Fidelity::Exact),
        24 => ("ne_resize", IDC_SIZENESW, "IDC_SIZENESW", Fidelity::Exact),
        25 => ("nw_resize", IDC_SIZENWSE, "IDC_SIZENWSE", Fidelity::Exact),
        26 => ("se_resize", IDC_SIZENWSE, "IDC_SIZENWSE", Fidelity::Exact),
        27 => ("sw_resize", IDC_SIZENESW, "IDC_SIZENESW", Fidelity::Exact),
        28 => ("ew_resize", IDC_SIZEWE, "IDC_SIZEWE", Fidelity::Exact),
        29 => ("ns_resize", IDC_SIZENS, "IDC_SIZENS", Fidelity::Exact),
        30 => ("nesw_resize", IDC_SIZENESW, "IDC_SIZENESW", Fidelity::Exact),
        31 => ("nwse_resize", IDC_SIZENWSE, "IDC_SIZENWSE", Fidelity::Exact),
        32 => ("zoom_in", IDC_ARROW, "IDC_ARROW", Fidelity::Fallback),
        33 => ("zoom_out", IDC_ARROW, "IDC_ARROW", Fidelity::Fallback),
        _ => ("unknown", IDC_ARROW, "IDC_ARROW", Fidelity::Fallback),
    };
    Pick { shape: name, cursor, cursor_name, fidelity }
}

/// What was last put on screen for a pane, so the log can be written on
/// change rather than on every mouse message.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Applied {
    Hidden,
    Shape(i32),
}

struct Rec {
    surface: usize,
    shape: i32,
    hidden: bool,
    applied: Option<Applied>,
}

/// Keyed by surface, which is unique in the process, and **not by pane
/// index**: panes are reordered and removed.
///
/// **Its own lock, not the tab registry's.** `WM_SETCURSOR` arrives for every
/// pixel of pointer movement, and putting this behind the lock the whole tab
/// model shares would put the tab model on the mouse's critical path.
static SHAPES: Mutex<Vec<Rec>> = Mutex::new(Vec::new());

fn with_rec<T>(surface: usize, f: impl FnOnce(&mut Rec) -> T) -> T {
    let mut g = SHAPES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(i) = g.iter().position(|r| r.surface == surface) {
        return f(&mut g[i]);
    }
    g.push(Rec { surface, shape: 0, hidden: false, applied: None });
    let last = g.len() - 1;
    f(&mut g[last])
}

fn peek(surface: usize) -> Option<(i32, bool)> {
    let g = SHAPES.lock().unwrap_or_else(|e| e.into_inner());
    g.iter().find(|r| r.surface == surface).map(|r| (r.shape, r.hidden))
}

/// The core asked for a shape. Returns what it will look like, for the log.
pub fn record_shape(surface: usize, shape: i32) -> Pick {
    with_rec(surface, |r| r.shape = shape);
    pick(shape)
}

/// The core asked for the pointer to be shown or hidden.
pub fn record_visibility(surface: usize, hidden: bool) {
    with_rec(surface, |r| r.hidden = hidden);
}

/// Forget a surface. Called when its pane is freed.
///
/// **Not an optimisation.** A surface is a heap pointer and the allocator
/// reuses them, so a row left behind is a row the *next* surface at that
/// address inherits -- a new pane opening with the closed one's shape, or
/// with its pointer hidden.
pub fn forget(surface: usize) {
    let mut g = SHAPES.lock().unwrap_or_else(|e| e.into_inner());
    g.retain(|r| r.surface != surface);
}

/// Answer `WM_SETCURSOR` for a pane. `false` means "nothing recorded for this
/// surface" -- the caller should fall through to `DefWindowProcW` and let the
/// window class answer, rather than invent a shape.
pub fn apply(hwnd: HWND, surface: usize) -> bool {
    let Some((shape, hidden)) = peek(surface) else {
        return false;
    };

    let want = if hidden { Applied::Hidden } else { Applied::Shape(shape) };
    let changed = with_rec(surface, |r| {
        let changed = r.applied != Some(want);
        r.applied = Some(want);
        changed
    });

    if hidden {
        unsafe { SetCursor(None) };
        if changed {
            hlogf!(hwnd, "[mouse] cursor hidden");
        }
        return true;
    }

    let p = pick(shape);
    if let Ok(cur) = unsafe { LoadCursorW(None, p.cursor) } {
        unsafe { SetCursor(Some(cur)) };
    }
    // **On change only.** `WM_SETCURSOR` arrives for every pixel the pointer
    // moves; a line here unconditionally would bury every other line in the
    // file under a mouse gesture.
    if changed {
        hlogf!(
            hwnd,
            "[mouse] cursor {} -> {} [{}]",
            p.shape,
            p.cursor_name,
            p.fidelity.name()
        );
    }
    true
}

/// Whether a posted hide request should actually hide the pointer.
///
/// **A function of two bools, on its own, so that it can be shown to refuse.**
/// The request is posted to one pane while the pointer may be over another
/// window entirely -- the user is typing, which is the whole reason the core
/// asked. Hiding on the request alone would blank the pointer wherever it
/// happens to be, including over another application, and **that failure and
/// the correct behaviour are the same code path minus one condition**.
pub fn should_hide(hidden: bool, pointer_over_pane: bool) -> bool {
    hidden && pointer_over_pane
}

/// Is the pointer over this window right now?
fn pointer_over(hwnd: HWND) -> bool {
    let mut pt = POINT::default();
    if unsafe { GetCursorPos(&mut pt) }.is_err() {
        // Unknown is not "yes". Failing closed here means a hide that does not
        // happen, which is visible; failing open means hiding somebody else's
        // pointer, which looks like the pointer vanishing at random.
        return false;
    }
    (unsafe { WindowFromPoint(pt) }) == hwnd
}

/// A pane received `WM_POLTER_MOUSE_VISIBILITY`.
///
/// Only the hiding half does anything here. Showing it again needs no push:
/// the pointer has to move for the user to want it back, and moving is what
/// sends `WM_SETCURSOR`.
pub fn on_visibility_message(hwnd: HWND, surface: usize) {
    let Some((_, hidden)) = peek(surface) else {
        // Tagged, not process-wide: this is about one pane, and `hlogf!`
        // resolves its frame. The message is posted by the action and can
        // outlive the row it was posted about -- a pane closed between the
        // post and its delivery -- so this is a race to be seen, not a gap.
        hlogf!(hwnd, "[mouse] visibility message for a surface with no record; ignored");
        return;
    };
    let over = pointer_over(hwnd);
    if should_hide(hidden, over) {
        unsafe { SetCursor(None) };
        with_rec(surface, |r| r.applied = Some(Applied::Hidden));
        hlogf!(hwnd, "[mouse] cursor hidden on request (pointer over this pane)");
    } else {
        // **Both refusals are logged, and they are logged apart.** "The core
        // asked us to show it" and "the pointer is somewhere else" are the two
        // reasons nothing happened, and a single line would make the guard
        // untestable from a log.
        hlogf!(
            hwnd,
            "[mouse] visibility request not applied: hidden={} pointer_over_pane={}",
            hidden as u8,
            over as u8
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **All four cells, and the third is the one that matters.** A guard
    /// written as `if hidden` passes the first two and fails only here -- and
    /// its symptom in the field is the pointer disappearing over another
    /// window while the user types, which nobody would connect to this file.
    #[test]
    fn hide_only_when_the_pointer_is_on_this_pane() {
        assert!(should_hide(true, true));
        assert!(!should_hide(true, false), "a hide request must not reach a pointer that is elsewhere");
        assert!(!should_hide(false, true));
        assert!(!should_hide(false, false));
    }

    /// The table answers for every ordinal the C enum declares, and for the
    /// ones it does not. **The `unknown` row is checked by name**: a
    /// `_ => arrow` that forgot to mark itself would be invisible otherwise,
    /// which is the exact failure the fidelity column exists to prevent.
    #[test]
    fn every_declared_shape_is_named_and_the_rest_say_so() {
        for shape in 0..34 {
            let p = pick(shape);
            assert_ne!(p.shape, "unknown", "shape {shape} is declared in the C enum but not in this table");
        }
        for shape in [-1, 34, 999] {
            let p = pick(shape);
            assert_eq!(p.shape, "unknown");
            assert_eq!(p.fidelity, Fidelity::Fallback);
        }
    }

    /// Nothing may claim `Exact` while loading the arrow, except `default`.
    /// **This is the assertion that would have caught a lazy row**: adding a
    /// shape by copying the line above it and forgetting to change the cursor
    /// leaves a mapping that reads as correct and shows an arrow.
    #[test]
    fn only_default_is_an_exact_arrow() {
        for shape in 0..34 {
            let p = pick(shape);
            if p.cursor_name == "IDC_ARROW" && p.fidelity == Fidelity::Exact {
                assert_eq!(p.shape, "default", "shape {shape} claims an exact arrow");
            }
        }
    }
}
