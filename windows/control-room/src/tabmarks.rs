//! What a window tab carries for the panes in it that have a colour: the
//! supervisor's flag first, then a dot for each other coloured pane, two
//! rows of them filled a column at a time, and past eight a count
//! (task 1700; design `pane-color-v1`, figure 02, scheme A, which the user
//! chose on 2026-10-18).
//!
//! **A pane with no colour is not on the tab at all.** The dots say which
//! colours are in the tab, not where the panes are, so a tab with four
//! panes and one colour carries one dot. That is the design's choice
//! (`README.md` G-9), not something left out.
//!
//! Like [`crate::tabstrip`], in whole device pixels, and placed relative to
//! the cluster's own top left: the host decides where on the tab it goes
//! and measures the count's words, and this decides nothing else.

use crate::layout::Rect;
use crate::look::{tab_dots, window_tab};
use crate::pane_color::Color;

/// How many dots are drawn out of `coloured`, and how many the count says
/// are not: all of them up to the table's most, and past that the table's
/// fewer, so that the count has the room the last column had.
pub fn shown(coloured: usize) -> (usize, usize) {
    let (most, kept) = (tab_dots::MAX as usize, tab_dots::SHOWN_WHEN_OVER as usize);
    if coloured <= most {
        (coloured, 0)
    } else {
        (kept, coloured - kept)
    }
}

/// The flag a supervisor's pane puts on its tab (the core's
/// `ghostty_poltergeist_flag_e`, less none).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flag {
    /// ⚑: it is at work.
    Raised,
    /// ⚐: it has been quiet a long time.
    Lowered,
}

impl Flag {
    pub fn name(self) -> &'static str {
        match self {
            Flag::Raised => "raised",
            Flag::Lowered => "lowered",
        }
    }
}

/// One pane of a tab as its cluster sees it: its name, the colour set on
/// it, and its flag when it is the supervisor's.
#[derive(Clone, Debug, PartialEq)]
pub struct Seen {
    pub name: String,
    pub color: Option<Color>,
    pub flag: Option<Flag>,
}

/// What a tab's cluster draws for `panes`, in reading order
/// (`pane-color-interface.md` §4): the supervisor's flag in its shown
/// colour (purple when none is set), and a dot for every other pane with a
/// colour. The supervisor is never also a dot; a pane with no colour is
/// nothing.
pub fn of_panes(panes: &[Seen]) -> (Option<(Flag, Color)>, Vec<Color>) {
    let flag = panes.iter().find_map(|p| p.flag.map(|f| (f, p.color.unwrap_or(Color::Purple))));
    let dots = panes.iter().filter(|p| p.flag.is_none()).filter_map(|p| p.color).collect();
    (flag, dots)
}

/// What the cluster's tooltip says, as English msgids joined by new lines
/// (the host translates each): a heading, then a line for each pane on the
/// cluster in its order -- the supervisor's says so, and names its colour
/// only when it is not the purple it has by default.
///
/// `say(msgid)` is the host's translation; `fill(template, args)` puts the
/// words in. Kept apart so that the dump (`examples/dump.rs`) writes the
/// English and the host the person's language from the one rule.
pub fn tip(panes: &[Seen], say: &dyn Fn(&str) -> String) -> Option<String> {
    let mut lines = Vec::new();
    for p in panes {
        let line = match (p.flag, p.color) {
            (Some(_), None) | (Some(_), Some(Color::Purple)) => say(TIP_SUPERVISOR).replacen("{}", &p.name, 1),
            (Some(_), Some(c)) => say(TIP_SUPERVISOR_COLOR).replacen("{}", &p.name, 1).replacen("{}", &say(c.label()), 1),
            (None, Some(c)) => say(TIP_PANE).replacen("{}", &p.name, 1).replacen("{}", &say(c.label()), 1),
            (None, None) => continue,
        };
        lines.push(line);
    }
    if lines.is_empty() {
        return None;
    }
    lines.insert(0, say(TIP_HEADING));
    Some(lines.join("\n"))
}

/// The tooltip's words (`pane-color-interface.md` §4, item 5).
pub const TIP_HEADING: &str = crate::n_("Panes with a colour");
pub const TIP_PANE: &str = crate::n_("{}, {}");
pub const TIP_SUPERVISOR: &str = crate::n_("{}, supervisor");
pub const TIP_SUPERVISOR_COLOR: &str = crate::n_("{}, supervisor, {}");

/// Where everything in one tab's cluster goes.
#[derive(Debug, Clone, PartialEq)]
pub struct Cluster<C> {
    /// The cluster's size: as wide as what is in it, and the glyph's
    /// height whatever is in it, so that every tab's title starts on the
    /// same line.
    pub w: f64,
    pub h: f64,
    /// The supervisor's flag, in the glyph's square, and its pane's colour.
    pub flag: Option<(Rect, C)>,
    /// Each dot drawn, and its colour, in the order given.
    pub dots: Vec<(Rect, C)>,
    /// The count of dots not drawn, and where its words go: as wide as the
    /// host measured them, as high as the cluster.
    pub more: Option<(Rect, usize)>,
}

impl<C> Cluster<C> {
    /// Nothing to draw: no supervisor and no coloured pane. Such a tab
    /// keeps all of its width for the title.
    pub fn is_empty(&self) -> bool {
        self.flag.is_none() && self.dots.is_empty() && self.more.is_none()
    }
}

/// A tab's cluster at `scale`.
///
/// - `flag`: the colour of the supervisor's pane, when the supervisor is in
///   this tab. The supervisor is never also a dot.
/// - `dots`: the colours of the tab's other coloured panes, in reading
///   order of their top left corners.
/// - `more_w`: how wide the host's words for `+N` are, in device pixels,
///   given the `N` [`shown`] says. Asked for only when there is a count.
pub fn cluster<C: Copy>(flag: Option<C>, dots: &[C], scale: f64, more_w: impl Fn(usize) -> f64) -> Cluster<C> {
    let px = |points: f64| (points * scale).round().max(1.0);
    // Two rows fill the glyph's height exactly at the design's scale
    // (6 + 2 + 6 = 14). At any other the height and the dot are rounded
    // first and the gap is what is left, so two rows never stand taller
    // than the glyph does.
    let h = px(window_tab::GLYPH);
    let dot = px(tab_dots::DOT);
    let gap = (h - 2.0 * dot).max(1.0);
    let (flag_gap, plus_gap) = (px(tab_dots::FLAG_GAP), px(tab_dots::PLUS_GAP));

    let mut x = 0.0;
    let mut out = Cluster { w: 0.0, h, flag: None, dots: Vec::new(), more: None };
    if let Some(c) = flag {
        out.flag = Some((Rect { x, y: 0.0, w: h, h }, c));
        x += h;
    }
    let (n, more) = shown(dots.len());
    if n > 0 {
        if out.flag.is_some() {
            x += flag_gap;
        }
        // One dot alone sits in the middle, not on the top row.
        let single = n == 1;
        for (i, c) in dots.iter().take(n).enumerate() {
            let (col, row) = (i / 2, i % 2);
            let y = if single { ((h - dot) / 2.0).floor() } else { row as f64 * (dot + gap) };
            out.dots.push((Rect { x: x + col as f64 * (dot + gap), y, w: dot, h: dot }, *c));
        }
        let cols = n.div_ceil(2) as f64;
        x += cols * dot + (cols - 1.0) * gap;
    }
    if more > 0 {
        x += plus_gap;
        let w = more_w(more).round().max(0.0);
        out.more = Some((Rect { x, y: 0.0, w, h }, more));
        x += w;
    }
    out.w = x;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCALES: [f64; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];
    /// What a host might measure `+N` at, 13pt: about 15.5 at 1x.
    fn words(scale: f64) -> impl Fn(usize) -> f64 {
        move |n| (if n < 10 { 15.5 } else { 23.0 }) * scale
    }

    #[test]
    fn up_to_eight_dots_are_drawn_and_past_that_six_and_a_count() {
        assert_eq!(shown(0), (0, 0));
        assert_eq!(shown(1), (1, 0));
        assert_eq!(shown(8), (8, 0));
        assert_eq!(shown(9), (6, 3));
        assert_eq!(shown(30), (6, 24));
    }

    /// The design's readings at 1x (`pane-color-v1/metrics.json`): the flag
    /// and a column of two, 24; one dot, 6; six dots and «+3», 41.5 there,
    /// where the words were 15.5 wide.
    #[test]
    fn at_the_designs_own_scale_it_is_the_designs_widths() {
        let w = words(1.0);
        assert_eq!(cluster(Some(0), &[1, 2], 1.0, &w).w, 24.0);
        assert_eq!(cluster(None, &[1], 1.0, &w).w, 6.0);
        // 22 of dots, 4 between, the words rounded to 16.
        assert_eq!(cluster(None, &[1; 9], 1.0, &w).w, 42.0);
        // The flag alone is the glyph's square.
        assert_eq!(cluster(Some(0), &[] as &[u8], 1.0, &w).w, 14.0);
        // Two rows are the glyph's height exactly.
        let c = cluster(None, &[1, 2], 1.0, &w);
        assert_eq!((c.dots[0].0.y, c.dots[1].0.y + c.dots[1].0.h), (0.0, 14.0));
    }

    #[test]
    fn nothing_is_an_empty_cluster_that_takes_no_width() {
        let c = cluster::<u8>(None, &[], 1.5, words(1.5));
        assert!(c.is_empty());
        assert_eq!(c.w, 0.0);
    }

    /// Column first: the second dot is under the first, the third starts
    /// the next column. The order of the colours is kept.
    #[test]
    fn the_dots_fill_a_column_before_the_next_and_keep_their_order() {
        let c = cluster(None, &['a', 'b', 'c'], 1.0, words(1.0));
        let at: Vec<(f64, f64, char)> = c.dots.iter().map(|(r, c)| (r.x, r.y, *c)).collect();
        assert_eq!(at, vec![(0.0, 0.0, 'a'), (0.0, 8.0, 'b'), (8.0, 0.0, 'c')]);
    }

    #[test]
    fn one_dot_alone_is_in_the_middle_and_not_on_the_top_row() {
        for scale in SCALES {
            let c = cluster(None, &[1], scale, words(scale));
            let (r, _) = c.dots[0];
            let (above, below) = (r.y, c.h - r.y - r.h);
            assert!(below >= above && below - above <= 1.0, "{above} above, {below} below at {scale}");
        }
    }

    #[test]
    fn nothing_has_half_a_pixel_in_it_and_nothing_leaves_the_cluster_at_any_scale() {
        for scale in SCALES {
            for n in [1usize, 2, 3, 8, 9, 14] {
                let dots: Vec<usize> = (0..n).collect();
                for flag in [None, Some(99)] {
                    let c = cluster(flag, &dots, scale, words(scale));
                    let mut all: Vec<Rect> = c.dots.iter().map(|(r, _)| *r).collect();
                    all.extend(c.flag.map(|(r, _)| r));
                    all.extend(c.more.map(|(r, _)| r));
                    for r in all {
                        assert!([r.x, r.y, r.w, r.h].iter().all(|v| v.fract() == 0.0), "{r:?} at {scale}");
                        assert!(r.x >= 0.0 && r.y >= 0.0 && r.x + r.w <= c.w && r.y + r.h <= c.h, "{r:?} outside {}x{} at {scale}", c.w, c.h);
                    }
                    // No two dots touch.
                    for (i, (a, _)) in c.dots.iter().enumerate() {
                        for (b, _) in &c.dots[i + 1..] {
                            let apart = a.x + a.w < b.x || b.x + b.w < a.x || a.y + a.h < b.y || b.y + b.h < a.y;
                            assert!(apart, "{a:?} and {b:?} touch at {scale}");
                        }
                    }
                    assert_eq!(c.h, (window_tab::GLYPH * scale).round(), "the glyph's height at {scale}");
                }
            }
        }
    }

    #[test]
    fn the_count_comes_last_and_says_how_many_are_not_drawn() {
        let c = cluster(Some(0), &[1; 11], 1.0, words(1.0));
        let (r, n) = c.more.expect("a count");
        assert_eq!(n, 5);
        assert_eq!(c.dots.len(), 6);
        assert!(c.dots.iter().all(|(d, _)| d.x + d.w < r.x));
        assert_eq!(r.x + r.w, c.w);
    }

    fn seen(name: &str, color: Option<Color>, flag: Option<Flag>) -> Seen {
        Seen { name: name.into(), color, flag }
    }

    #[test]
    fn the_supervisor_is_the_flag_and_never_a_dot_and_a_pane_without_a_colour_is_nothing() {
        let panes = [
            seen("api", Some(Color::Orange), None),
            seen("web", None, Some(Flag::Raised)),
            seen("tests", None, None),
            seen("ui", Some(Color::Teal), None),
        ];
        assert_eq!(of_panes(&panes), (Some((Flag::Raised, Color::Purple)), vec![Color::Orange, Color::Teal]));
        let coloured = [seen("boss", Some(Color::Green), Some(Flag::Lowered))];
        assert_eq!(of_panes(&coloured), (Some((Flag::Lowered, Color::Green)), vec![]));
        assert_eq!(of_panes(&[seen("zsh", None, None)]), (None, vec![]));
    }

    #[test]
    fn the_tooltip_names_each_pane_on_the_cluster_and_the_supervisor_s_colour_only_when_not_purple() {
        let say = |m: &str| m.to_string();
        let panes = [seen("web", None, Some(Flag::Raised)), seen("api", Some(Color::Orange), None), seen("tests", None, None)];
        assert_eq!(tip(&panes, &say).as_deref(), Some("Panes with a colour\nweb, supervisor\napi, Orange"));
        let teal = [seen("boss", Some(Color::Teal), Some(Flag::Lowered))];
        assert_eq!(tip(&teal, &say).as_deref(), Some("Panes with a colour\nboss, supervisor, Teal"));
        let purple = [seen("boss", Some(Color::Purple), Some(Flag::Raised))];
        assert_eq!(tip(&purple, &say).as_deref(), Some("Panes with a colour\nboss, supervisor"));
        assert_eq!(tip(&[seen("zsh", None, None)], &say), None);
    }
}
