//! Where the terminal and the file preview go in one cell, when the preview
//! is open (task 2623, #2140 S2; the design's `INTERACTION.md` §一 宽窄,
//! `src/files.css`'s `.split > .cv` and `.split.over > .fp`).
//!
//! **One rule, both hosts** (`dev-docs/poltergeist/control-room.md`, 3.5).
//! The macOS host has the same function in
//! `macos/Sources/Features/ControlRoom/PreviewLayout.swift`; the numbers are
//! the data's (`look::preview`), and `tools/control-room-hosts-agree.py`
//! holds the two to each other over
//! `src/poltergeist/testdata/preview_layout_cases.json`, line by line.
//! `PreviewLayout.swift` and this file are also what
//! `preview_layout_cases.json`'s names come from, so a case one host has and
//! the other does not is a line printed once.
//!
//! **The rule, in the order it gives way:**
//!
//!  1. Nothing is open: the terminal has the whole cell and there is no
//!     preview.
//!  2. A cell at least `CELL_MIN_WIDTH_SIDE_BY_SIDE` wide puts them side by
//!     side. The preview wants what the divider was dragged to, or -- never
//!     dragged -- half the cell (`PREVIEW_DEFAULT_FRACTION`). It is then
//!     held between `PREVIEW_MIN_WIDTH` and what leaves the terminal
//!     `TERMINAL_MIN_WIDTH`. The terminal takes the rest, on the left.
//!  3. A narrower cell has the preview **over** the terminal: the terminal
//!     keeps the whole cell, and the preview starts `OVERLAY_LEFT_EXPOSE`
//!     in, leaving that much of the terminal in sight, dimmed, with `‹ 终端`
//!     over it.
//!
//! ⚠️ **No size is ever negative** (the supervisor's ruling of 2026-11-01,
//! task 2623). A cell narrower than `OVERLAY_LEFT_EXPOSE` -- or a `cell_w`
//! that is not a size at all -- is not a case the design drew, and a
//! negative width reaches `CGRect`/`iced` as a rectangle that is inside out.
//! So `cell_w` is brought to zero or more on the way in, and the overlay's
//! width is held at zero or more on the way out.
//!
//! **The widths are the whole of it.** The heights are the cell's, and
//! neither host is told one here: this says only where the two split a cell
//! across, which is the part the design states and the part that has to
//! agree.

use crate::look::preview;

/// Where the terminal and the preview go in one cell. `x` is measured from
/// the cell's left edge, and `preview_x` is where the preview starts: the
/// terminal's width when they are side by side, `OVERLAY_LEFT_EXPOSE` when
/// it is over the terminal, and nowhere at all when it is not open.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Layout {
    pub terminal_x: f64,
    pub terminal_width: f64,
    pub preview_x: f64,
    pub preview_width: f64,
    /// The preview is over the terminal rather than beside it.
    pub overlay: bool,
}

/// `v` brought within `lo..=hi`. **Never a panic**: `f64::clamp` panics
/// when the two are the wrong way round, and a cell narrow enough to make
/// them so is a cell a host can be given. `lo` is what such a range means
/// here -- the preview's least width is the one the design names.
pub fn clamp(v: f64, lo: f64, hi: f64) -> f64 {
    if hi < lo {
        return lo;
    }
    v.max(lo).min(hi)
}

/// Where the terminal and the preview go in a cell `cell_w` wide, with the
/// preview open or not, and the width the divider was dragged to (`None`
/// for never dragged).
pub fn layout(cell_w: f64, open: bool, dragged_w: Option<f64>) -> Layout {
    // A cell is a size. Anything else -- a negative, a NaN, an infinity --
    // is a caller that has lost its place, and the rule below is only
    // written for sizes, so it is shown nothing rather than a cell turned
    // inside out. (`f64::max` alone would not do it for an infinity: half
    // of one is still one, and `w - pw` would be `inf - inf`.)
    let w = if cell_w.is_finite() { cell_w.max(0.0) } else { 0.0 };
    if !open {
        return Layout {
            terminal_x: 0.0,
            terminal_width: w,
            preview_x: 0.0,
            preview_width: 0.0,
            overlay: false,
        };
    }
    if w >= preview::CELL_MIN_WIDTH_SIDE_BY_SIDE {
        let want = dragged_w.unwrap_or(w * preview::PREVIEW_DEFAULT_FRACTION);
        let pw = clamp(want, preview::PREVIEW_MIN_WIDTH, w - preview::TERMINAL_MIN_WIDTH);
        return Layout {
            terminal_x: 0.0,
            terminal_width: w - pw,
            preview_x: w - pw,
            preview_width: pw,
            overlay: false,
        };
    }
    Layout {
        terminal_x: 0.0,
        terminal_width: w,
        preview_x: w.min(preview::OVERLAY_LEFT_EXPOSE),
        preview_width: (w - preview::OVERLAY_LEFT_EXPOSE).max(0.0),
        overlay: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::{self, Value};

    /// The cells both hosts and the acceptance fixture are asked about, in
    /// the file the two hosts read: one list, so a case added there and not
    /// here is a line one side prints.
    const CASES: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../src/poltergeist/testdata/preview_layout_cases.json"
    ));

    /// What each of those cells makes, worked out from the rule and written
    /// down **by hand** -- not read from the file, so that a case whose
    /// answer moved is red here and not only in the comparison of the two
    /// hosts. `(name, cell_w, open, dragged_w, (tx, tw, px, pw), overlay)`.
    const WANT: &[(&str, f64, bool, Option<f64>, (f64, f64, f64, f64), bool)] = &[
        ("closed-800", 800.0, false, None, (0.0, 800.0, 0.0, 0.0), false),
        ("closed-799", 799.0, false, None, (0.0, 799.0, 0.0, 0.0), false),
        ("open-799-default", 799.0, true, None, (0.0, 799.0, 40.0, 759.0), true),
        ("open-800-default", 800.0, true, None, (0.0, 360.0, 360.0, 440.0), false),
        ("open-801-default", 801.0, true, None, (0.0, 361.0, 361.0, 440.0), false),
        ("open-800-drag-at-min", 800.0, true, Some(360.0), (0.0, 360.0, 360.0, 440.0), false),
        ("open-800-drag-below", 800.0, true, Some(359.0), (0.0, 360.0, 360.0, 440.0), false),
        ("open-800-drag-default", 800.0, true, Some(440.0), (0.0, 360.0, 360.0, 440.0), false),
        ("open-800-drag-at-max", 800.0, true, Some(440.0), (0.0, 360.0, 360.0, 440.0), false),
        ("open-800-drag-above", 800.0, true, Some(441.0), (0.0, 360.0, 360.0, 440.0), false),
        ("open-800-drag-1000", 800.0, true, Some(1000.0), (0.0, 360.0, 360.0, 440.0), false),
        ("open-1200-drag-840", 1200.0, true, Some(840.0), (0.0, 360.0, 360.0, 840.0), false),
        ("open-1200-drag-841", 1200.0, true, Some(841.0), (0.0, 360.0, 360.0, 840.0), false),
        ("open-1200-drag-360", 1200.0, true, Some(360.0), (0.0, 760.0, 760.0, 440.0), false),
        ("open-1200-drag-none", 1200.0, true, None, (0.0, 600.0, 600.0, 600.0), false),
        ("open-720-drag-360", 720.0, true, Some(360.0), (0.0, 720.0, 40.0, 680.0), true),
        ("open-361-none", 361.0, true, None, (0.0, 361.0, 40.0, 321.0), true),
        ("open-360-none", 360.0, true, None, (0.0, 360.0, 40.0, 320.0), true),
        ("open-400-none", 400.0, true, None, (0.0, 400.0, 40.0, 360.0), true),
        ("open-399-none", 399.0, true, None, (0.0, 399.0, 40.0, 359.0), true),
        ("open-neg-drag", 1000.0, true, Some(-50.0), (0.0, 560.0, 560.0, 440.0), false),
        ("open-huge-drag", 1000.0, true, Some(1_000_000.0), (0.0, 360.0, 360.0, 640.0), false),
        ("open-zero-cell", 0.0, true, None, (0.0, 0.0, 0.0, 0.0), true),
        ("open-zero-cell-drag", 0.0, true, Some(500.0), (0.0, 0.0, 0.0, 0.0), true),
        ("open-1-none", 1.0, true, None, (0.0, 1.0, 1.0, 0.0), true),
        ("open-39-none", 39.0, true, None, (0.0, 39.0, 39.0, 0.0), true),
        ("open-40-none", 40.0, true, None, (0.0, 40.0, 40.0, 0.0), true),
        ("open-41-none", 41.0, true, None, (0.0, 41.0, 40.0, 1.0), true),
        ("open-neg-cell", -5.0, true, None, (0.0, 0.0, 0.0, 0.0), true),
        ("design-03-read", 424.0, true, None, (0.0, 424.0, 40.0, 384.0), true),
        ("open-neg-cell-1000", -1000.0, true, Some(1000.0), (0.0, 0.0, 0.0, 0.0), true),
    ];

    fn number(v: &Value, key: &str) -> Option<f64> {
        match v.get(key) {
            None | Some(Value::Null) => None,
            Some(Value::Int(n)) => Some(*n as f64),
            Some(Value::Float(f)) => Some(*f),
            other => panic!("preview_layout_cases.json: {key} is {other:?}, not a number"),
        }
    }

    /// The case list the fixture holds, as `(name, cell_w, open, dragged_w)`.
    fn fixture() -> Vec<(String, f64, bool, Option<f64>)> {
        let v = json::parse(CASES).expect("preview_layout_cases.json is JSON");
        let Some(Value::Arr(cases)) = v.get("cases") else {
            panic!("preview_layout_cases.json: no cases");
        };
        if cases.is_empty() {
            panic!("preview_layout_cases.json: no cases at all, so nothing was checked");
        }
        cases
            .iter()
            .map(|c| {
                let name = match c.get("case") {
                    Some(Value::Str(s)) => s.clone(),
                    _ => panic!("preview_layout_cases.json: a case has no name"),
                };
                let cell_w = number(c, "cell_w").unwrap_or_else(|| panic!("{name}: no cell_w"));
                let open = match c.get("open") {
                    Some(Value::Bool(b)) => *b,
                    _ => panic!("{name}: no open"),
                };
                (name, cell_w, open, number(c, "dragged_w"))
            })
            .collect()
    }

    fn want(name: &str) -> (&'static str, f64, bool, Option<f64>, (f64, f64, f64, f64), bool) {
        *WANT
            .iter()
            .find(|w| w.0 == name)
            .unwrap_or_else(|| panic!("{name} is in the fixture and not in WANT: what it makes has not been written down"))
    }

    /// Every case the fixture lists, against the hand-written answer for it.
    /// A case in the fixture that `WANT` does not carry is a failure by name.
    #[test]
    fn every_case_the_two_hosts_print_is_the_rule() {
        let cases = fixture();
        assert_eq!(cases.len(), WANT.len(), "the fixture and WANT are not the same case list");
        for (name, cell_w, open, dragged) in cases {
            let (_, _, _, _, want, overlay) = want(&name);
            let got = layout(cell_w, open, dragged);
            assert_eq!(
                (got.terminal_x, got.terminal_width, got.preview_x, got.preview_width),
                want,
                "{name}: cell_w={cell_w} open={open} dragged={dragged:?}"
            );
            assert_eq!(got.overlay, overlay, "{name}: cell_w={cell_w} open={open}");
        }
    }

    /// The four numbers are the data's, under the names the design and the
    /// acceptance fixture use (`control-room-look.json`, `numbers.preview`).
    #[test]
    fn the_numbers_are_the_ones_the_design_gives() {
        assert_eq!(preview::CELL_MIN_WIDTH_SIDE_BY_SIDE, 800.0);
        assert_eq!(preview::TERMINAL_MIN_WIDTH, 360.0);
        assert_eq!(preview::PREVIEW_MIN_WIDTH, 440.0);
        assert_eq!(preview::PREVIEW_DEFAULT_FRACTION, 0.5);
        assert_eq!(preview::OVERLAY_LEFT_EXPOSE, 40.0);
        // The threshold is the two least widths added up, which is where the
        // design's 800 comes from; a cell of exactly that much has no room
        // for half and gives the preview its least instead.
        assert_eq!(
            preview::CELL_MIN_WIDTH_SIDE_BY_SIDE,
            preview::TERMINAL_MIN_WIDTH + preview::PREVIEW_MIN_WIDTH
        );
    }

    /// The two sides of the threshold, one apart.
    #[test]
    fn the_threshold_is_the_last_cell_that_can_hold_both() {
        let under = layout(799.0, true, None);
        assert!(under.overlay, "799 is over the terminal, not beside it");
        assert_eq!(under.terminal_width, 799.0, "over the terminal it keeps the whole cell");
        let at = layout(800.0, true, None);
        assert!(!at.overlay);
        assert_eq!(at.terminal_width, 360.0, "the terminal is left its least");
        assert_eq!(at.preview_width, 440.0, "half the cell is under the least; the least is what it gets");
    }

    /// Never dragged: half the cell, unless one of the two least widths
    /// says otherwise.
    #[test]
    fn the_default_is_half_the_cell() {
        let wide = layout(1600.0, true, None);
        assert_eq!(wide.preview_width, 800.0, "half of 1600, with neither side near its least");
        assert_eq!(wide.terminal_width, 800.0);
        let tight = layout(900.0, true, None);
        assert_eq!(tight.preview_width, 450.0);
    }

    /// Dragged: what it was dragged to, held between the preview's least
    /// and what leaves the terminal its least.
    #[test]
    fn a_drag_is_held_between_the_two_least_widths() {
        assert_eq!(layout(1200.0, true, Some(600.0)).preview_width, 600.0);
        assert_eq!(layout(1200.0, true, Some(360.0)).preview_width, 440.0, "under the least it is the least");
        assert_eq!(layout(1200.0, true, Some(-50.0)).preview_width, 440.0, "a negative drag is the least");
        assert_eq!(layout(1200.0, true, Some(841.0)).preview_width, 840.0, "past the top the terminal keeps its least");
        assert_eq!(layout(1200.0, true, Some(1e9)).preview_width, 840.0);
        // The terminal is what is left, and the two add back up.
        for cell_w in [800.0, 801.0, 1000.0, 1200.0, 3000.0] {
            for dragged in [None, Some(0.0), Some(360.0), Some(700.0), Some(1e6)] {
                let l = layout(cell_w, true, dragged);
                assert_eq!(l.preview_x, l.terminal_width);
                assert_eq!(l.terminal_width + l.preview_width, cell_w, "at {cell_w} dragged {dragged:?}");
                assert!(l.terminal_width >= preview::TERMINAL_MIN_WIDTH);
                assert!(l.preview_width >= preview::PREVIEW_MIN_WIDTH);
            }
        }
    }

    /// Over the terminal: it keeps the cell, the preview starts 40 in, and
    /// the divider's width is not a thing that was dragged.
    #[test]
    fn over_the_terminal_it_leaves_forty_of_it_in_sight() {
        let l = layout(400.0, true, None);
        assert!(l.overlay);
        assert_eq!((l.terminal_x, l.terminal_width), (0.0, 400.0));
        assert_eq!((l.preview_x, l.preview_width), (40.0, 360.0));
        assert_eq!(l.preview_x + l.preview_width, l.terminal_width, "the preview ends at the cell's right edge");
        let dragged = layout(400.0, true, Some(700.0));
        assert_eq!(dragged, l, "a drag means nothing when the two are not side by side");
    }

    /// Closed: the terminal has the whole cell and the preview is nowhere.
    #[test]
    fn closed_is_the_whole_cell_and_no_preview() {
        for cell_w in [0.0, 400.0, 800.0, 2000.0] {
            let l = layout(cell_w, false, Some(500.0));
            assert_eq!((l.terminal_x, l.terminal_width), (0.0, cell_w));
            assert_eq!((l.preview_x, l.preview_width, l.overlay), (0.0, 0.0, false));
        }
    }

    /// ⚠️ No size is ever negative (the supervisor's ruling of 2026-11-01):
    /// a cell narrower than what the preview leaves in sight, and a `cell_w`
    /// that is not a size at all.
    #[test]
    fn no_size_is_ever_negative() {
        for cell_w in [-1e9, -1000.0, -5.0, -0.0, 0.0, 1.0, 39.0, 39.999, 40.0, 41.0, 799.0, 800.0, 1e9] {
            for open in [false, true] {
                for dragged in [None, Some(-1e9), Some(0.0), Some(1e9)] {
                    let l = layout(cell_w, open, dragged);
                    for (what, v) in [
                        ("terminal_x", l.terminal_x),
                        ("terminal_width", l.terminal_width),
                        ("preview_x", l.preview_x),
                        ("preview_width", l.preview_width),
                    ] {
                        assert!(v >= 0.0, "{what} is {v} at cell_w={cell_w} open={open} dragged={dragged:?}");
                        assert!(v.is_finite(), "{what} is {v} at cell_w={cell_w} open={open} dragged={dragged:?}");
                    }
                    // The preview ends at the cell's right edge either way:
                    // beside the terminal, the two add up to the cell; over
                    // it, the preview takes what the cell has past the
                    // inset. Never past it.
                    assert!(l.preview_x + l.preview_width <= cell_w.max(0.0) + 1e-9,
                            "the preview sticks out of the cell at cell_w={cell_w} open={open}");
                    assert!(l.terminal_x + l.terminal_width <= cell_w.max(0.0) + 1e-9,
                            "the terminal sticks out of the cell at cell_w={cell_w} open={open}");
                }
            }
        }
        // A negative cell is nothing to show, not a cell shown backwards.
        assert_eq!(layout(-5.0, true, None), layout(0.0, true, None));
        assert_eq!(layout(-1000.0, true, Some(1000.0)), layout(0.0, true, None));
    }

    /// `clamp` is the shape of the guard: a range the wrong way round takes
    /// the lower end rather than panicking the way `f64::clamp` would.
    #[test]
    fn a_range_the_wrong_way_round_takes_the_lower_end() {
        assert_eq!(clamp(500.0, 440.0, 840.0), 500.0);
        assert_eq!(clamp(0.0, 440.0, 840.0), 440.0);
        assert_eq!(clamp(1e9, 440.0, 840.0), 840.0);
        assert_eq!(clamp(500.0, 440.0, 360.0), 440.0, "the range is empty; the lower end is what it means");
        assert_eq!(clamp(-500.0, 440.0, 360.0), 440.0, "and it is the lower end for a value under it too");
        // A value that is not a number: `v.max(lo)` would keep the NaN
        // (`f64::max` answers the *other* operand only when one of them is
        // not a NaN). A drag is not a NaN; it is "not dragged".
        assert_eq!(clamp(f64::NAN, 440.0, 840.0), 440.0, "a NaN takes the lower end");
        assert_eq!(clamp(f64::NAN, 440.0, 360.0), 440.0, "even when the range is empty");
    }

    /// A cell width or a dragged width that is not a size at all -- a NaN, an
    /// infinity: the guard leaves four finite, non-negative sizes.
    ///
    /// ⚠️ This is the pair of cases that are **not** the same on the two
    /// hosts unless each is written for them:
    /// * `f64::max(NaN, 0.0)` is `0.0` in Rust (max answers the other
    ///   operand), but `max(NaN, 0)` is `NaN` in Swift;
    /// * an infinity passes any `max(·, 0)` guard, and then half of it is
    ///   still an infinity and `w - pw` is `inf - inf` = NaN.
    ///
    /// So both hosts name the finite case out loud rather than relying on
    /// what `max` does with a NaN. (The fixture's 31 cells have no such
    /// input, so `tools/control-room-hosts-agree.py` cannot catch this: this
    /// test and its Swift twin are the only places it is held.)
    #[test]
    fn a_cell_that_is_not_a_size_shows_nothing_rather_than_a_nan() {
        for (what, cell_w, dragged) in [
            ("a NaN cell", f64::NAN, None),
            ("a NaN cell, dragged", f64::NAN, Some(500.0)),
            ("an infinite cell", f64::INFINITY, None),
            ("an infinite cell, dragged", f64::INFINITY, Some(500.0)),
        ] {
            let l = layout(cell_w, true, dragged);
            for (field, v) in [
                ("terminal_x", l.terminal_x),
                ("terminal_width", l.terminal_width),
                ("preview_x", l.preview_x),
                ("preview_width", l.preview_width),
            ] {
                assert!(v.is_finite() && v >= 0.0, "{field} is {v} for {what}");
            }
        }
        // A dragged width that is not a number, in a cell that is one: the
        // same rule as an empty range -- the preview takes its least, and the
        // terminal keeps the rest. It deliberately does **not** mean "never
        // dragged": that is what `None` is for, and reading it as such would
        // be a second rule in each host.
        assert_eq!(layout(1200.0, true, Some(f64::NAN)), layout(1200.0, true, Some(-1.0)));
        assert_eq!(layout(1200.0, true, Some(f64::NAN)).preview_width, preview::PREVIEW_MIN_WIDTH);
        assert_eq!(layout(800.0, true, Some(f64::NAN)), layout(800.0, true, None));
    }
}
