//! A terminal lit up for the person to find (`terminal_highlight`, task
//! 1690; the design is `highlight-v1/README.md` of the control-room
//! designs): the parts of it that need no window.
//!
//! **What the host paints is decided here, not where it paints.** The other
//! panes of the window are dimmed, the lit one wears a border, a card sits
//! in its middle -- or, too small for the card, the border alone -- and the
//! border, the card's edge, the tab and the stack tab breathe together. How
//! much each is lit at a moment is [`breath`]; whether the card fits is
//! [`fits_card`]; what a key does to it is [`key`]; why it ended is [`Why`].

/// Why a highlight ended: the word in the log's closing line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Why {
    /// Its time ran out.
    Timeout,
    /// A key was pressed in its window. The log says this and **not which
    /// key**: the key went nowhere, and what the person typed is theirs.
    Key,
    /// A click in its window, the strip included. The click itself goes on.
    Click,
    /// Another terminal was lit; one at a time.
    Replaced,
    /// The caller asked for 0 seconds.
    Cancelled,
    /// The terminal was closed, or moved to another window.
    Closed,
}

impl Why {
    pub fn word(self) -> &'static str {
        match self {
            Why::Timeout => "timeout",
            Why::Key => "key",
            Why::Click => "click",
            Why::Replaced => "replaced",
            Why::Cancelled => "cancelled",
            Why::Closed => "closed",
        }
    }
}

/// How lit the breathing parts are at `t` seconds since the highlight began,
/// from `low` to `high`: **`low` at the start of each breath, `high` half a
/// period in**, smoothly between.
///
/// With motion turned off in the system (`animate` false) it is `high` and
/// stays there: a still highlight, never a dim one.
pub fn breath(t: f64, period: f64, low: f64, high: f64, animate: bool) -> f64 {
    if !animate || !(period > 0.0) {
        return high;
    }
    let phase = (t / period).rem_euclid(1.0);
    low + (high - low) * 0.5 * (1.0 - (std::f64::consts::TAU * phase).cos())
}

/// Whether a pane of `width` by `height` points has room for the card; when
/// it does not, the pane wears the border alone (the design's A), which
/// still breathes.
pub fn fits_card(width: f64, height: f64, min_width: f64, min_height: f64) -> bool {
    width >= min_width && height >= min_height
}

/// The whole seconds the card says are left: 24.2 left is "25", so the
/// number reaches 0 only as the time does.
pub fn seconds_left(now_ms: u64, until_ms: u64) -> u64 {
    until_ms.saturating_sub(now_ms).div_ceil(1000)
}

/// How full the countdown bar is, from 1 at the start to 0 at the end.
pub fn bar_fraction(now_ms: u64, from_ms: u64, until_ms: u64) -> f64 {
    if until_ms <= from_ms {
        return 0.0;
    }
    let left = until_ms.saturating_sub(now_ms.max(from_ms)) as f64;
    (left / (until_ms - from_ms) as f64).clamp(0.0, 1.0)
}

/// What a key pressed in the lit window does.
///
/// **A chord does not end it** (the supervisor's ruling on 2026-10-18, its
/// option A, which differs from the design's README): Ctrl+Tab and the like
/// move between tabs, and the lit terminal's tab is meant to go on
/// breathing after the person has moved away from it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// A modifier on its own, or a chord with Ctrl, Alt or the Windows key:
    /// the key goes on as it would have, and the highlight stays.
    Ignored,
    /// The highlight ends and **the key goes nowhere** -- Escape, Return and
    /// letters alike. The person was most likely talking to the supervisor,
    /// and the keyboard may now be in the lit terminal.
    EndAndSwallow,
}

/// `modifier_only` is whether the key pressed is itself Shift, Ctrl, Alt or
/// the Windows key; `chorded` whether Ctrl, Alt or the Windows key is held
/// with it. Shift is not a chord: Shift+A is a letter.
pub fn key(modifier_only: bool, chorded: bool) -> Key {
    if modifier_only || chorded {
        Key::Ignored
    } else {
        Key::EndAndSwallow
    }
}

/// Whether a press of a mouse button ends the highlight: **only in the
/// panes** -- a terminal, or a pane's own title or stack strip. A press on
/// the window's tab strip switches tabs and the lit tab goes on breathing
/// (option A, as for [`key`]); one on the window's frame does nothing to it.
pub fn click_ends(in_a_pane: bool) -> bool {
    in_a_pane
}

/// Whether lighting a terminal moves the keyboard into it: only when the
/// tab it was in went out of view (`tab`), or the stack member it was in is
/// the one the lit terminal now covers (`stack` and `covered_had_it`). The
/// supervisor's pane in the same tab keeps it from start to end.
pub fn keyboard_moves(tab: bool, stack: bool, covered_had_it: bool) -> bool {
    tab || (stack && covered_had_it)
}

/// How far the point `(x, y)` is outside a `w` by `h` rectangle at the
/// origin whose corners are rounded by `radius`; negative inside.
pub fn outside(x: f64, y: f64, w: f64, h: f64, radius: f64) -> f64 {
    let r = radius.min(w / 2.0).min(h / 2.0).max(0.0);
    let qx = (x - w / 2.0).abs() - (w / 2.0 - r);
    let qy = (y - h / 2.0).abs() - (h / 2.0 - r);
    let (ox, oy) = (qx.max(0.0), qy.max(0.0));
    (ox * ox + oy * oy).sqrt() + qx.max(qy).min(0.0) - r
}

/// How much of the edge covers a pixel whose centre is `d` pixels outside
/// the lit pane: a line `line` pixels wide against the pane, and past it,
/// when `glow` is not 0, a glow that fades out over `glow` pixels (the
/// design's A). Nothing inside the pane: the terminal is not covered.
pub fn edge_coverage(d: f64, line: f64, glow: f64) -> f64 {
    let solid = (d + 0.5).clamp(0.0, 1.0) * (line - d + 0.5).clamp(0.0, 1.0);
    if glow <= 0.0 || d < line {
        return solid;
    }
    let past = (d - line) / glow;
    solid.max(0.5 * (-3.0 * past * past).exp())
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: f64 = 1.2;

    #[test]
    fn a_breath_goes_from_low_to_high_and_back_in_one_period() {
        let at_start = breath(0.0, P, 0.35, 1.0, true);
        assert!((at_start - 0.35).abs() < 1e-9, "starts at low, got {at_start}");
        let half = breath(P / 2.0, P, 0.35, 1.0, true);
        assert!((half - 1.0).abs() < 1e-9, "high half a period in, got {half}");
        let again = breath(P * 3.0, P, 0.35, 1.0, true);
        assert!((again - 0.35).abs() < 1e-9, "a whole period later it is low again, got {again}");
    }

    #[test]
    fn a_breath_moves_and_stays_inside_its_range() {
        let samples: Vec<f64> = (0..48).map(|i| breath(i as f64 * 0.05, P, 0.35, 1.0, true)).collect();
        assert!(samples.iter().all(|a| (0.35 - 1e-9..=1.0 + 1e-9).contains(a)));
        let lo = samples.iter().cloned().fold(f64::MAX, f64::min);
        let hi = samples.iter().cloned().fold(f64::MIN, f64::max);
        assert!(hi - lo > 0.5, "it has to visibly breathe: {lo}..{hi}");
    }

    #[test]
    fn with_motion_off_it_is_still_and_fully_lit() {
        for i in 0..10 {
            assert_eq!(breath(i as f64 * 0.13, P, 0.35, 1.0, false), 1.0);
        }
    }

    #[test]
    fn a_pane_too_small_for_the_card_wears_the_border_alone() {
        assert!(fits_card(280.0, 160.0, 280.0, 160.0));
        assert!(!fits_card(279.0, 400.0, 280.0, 160.0));
        assert!(!fits_card(600.0, 159.0, 280.0, 160.0));
    }

    #[test]
    fn the_seconds_left_reach_zero_only_with_the_time() {
        assert_eq!(seconds_left(0, 24_200), 25);
        assert_eq!(seconds_left(0, 24_000), 24);
        assert_eq!(seconds_left(29_999, 30_000), 1);
        assert_eq!(seconds_left(30_000, 30_000), 0);
        assert_eq!(seconds_left(31_000, 30_000), 0);
    }

    #[test]
    fn the_bar_empties_from_full() {
        assert_eq!(bar_fraction(0, 0, 30_000), 1.0);
        assert!((bar_fraction(15_000, 0, 30_000) - 0.5).abs() < 1e-9);
        assert_eq!(bar_fraction(40_000, 0, 30_000), 0.0);
        assert_eq!(bar_fraction(5, 10, 10), 0.0);
    }

    #[test]
    fn the_first_plain_key_ends_it_and_a_chord_leaves_it_alone() {
        assert_eq!(key(true, false), Key::Ignored);
        assert_eq!(key(true, true), Key::Ignored);
        assert_eq!(key(false, false), Key::EndAndSwallow);
        assert_eq!(key(false, true), Key::Ignored, "Ctrl+Tab moves away and the tab goes on breathing");
    }

    #[test]
    fn only_a_press_in_a_pane_ends_it() {
        assert!(click_ends(true));
        assert!(!click_ends(false), "the tab strip switches tabs; the lit tab goes on breathing");
    }

    #[test]
    fn outside_is_the_distance_from_a_rounded_rectangle() {
        assert!((outside(5.0, 5.0, 10.0, 10.0, 0.0) + 5.0).abs() < 1e-9, "the centre is half the side inside");
        assert!((outside(12.0, 5.0, 10.0, 10.0, 0.0) - 2.0).abs() < 1e-9);
        // Past a rounded corner, along the diagonal from its centre.
        let d = outside(-2.0, -2.0, 10.0, 10.0, 4.0);
        assert!((d - (2.0 * 6.0f64.powi(2)).sqrt() + 4.0).abs() < 1e-9, "got {d}");
    }

    #[test]
    fn the_edge_covers_its_line_and_never_the_pane() {
        assert_eq!(edge_coverage(-3.0, 2.0, 0.0), 0.0, "inside the pane");
        assert_eq!(edge_coverage(1.0, 2.0, 0.0), 1.0, "on the line");
        assert_eq!(edge_coverage(4.0, 2.0, 0.0), 0.0, "past it, with no glow");
        let near = edge_coverage(4.0, 3.0, 14.0);
        let far = edge_coverage(15.0, 3.0, 14.0);
        assert!(near > far && far > 0.0 && near <= 0.5, "the glow fades: {near} then {far}");
    }

    #[test]
    fn the_keyboard_stays_unless_what_had_it_went_out_of_view() {
        assert!(!keyboard_moves(false, false, false), "same tab, nothing switched");
        assert!(!keyboard_moves(false, false, true));
        assert!(!keyboard_moves(false, true, false), "a stack switched in a pane the keyboard was not in");
        assert!(keyboard_moves(false, true, true), "the member that had it is covered now");
        assert!(keyboard_moves(true, false, false), "another tab: the one it was in is gone from view");
    }

    #[test]
    fn every_ending_has_its_own_word() {
        let all = [Why::Timeout, Why::Key, Why::Click, Why::Replaced, Why::Cancelled, Why::Closed];
        let words: std::collections::BTreeSet<_> = all.iter().map(|w| w.word()).collect();
        assert_eq!(words.len(), all.len());
        assert_eq!(Why::Key.word(), "key");
    }
}
