//! Where everything in the list panel is, in the panel's own units with the
//! origin at its top left. Sizes come from `look`; this adds only the
//! arithmetic, so that whatever draws places things and never measures.
//!
//! The units are the design's points. A host multiplies by its scale at
//! the last moment and nowhere else.

use crate::list::List;
use crate::snapshot::Fix;
use crate::look::{line, side, space};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// How much of what a row waits on is drawn: how many lines each step gets,
/// and how many steps are said only as a number.
///
/// **The rule** (control-room.md, 3.5): what is cut is the end of a line,
/// never a step. A sentence wraps to `ASK_MAX_LINES` and ends in an
/// ellipsis. A command of that many steps or fewer gives each step a line
/// first and what is left over to the earliest steps that need a second. A
/// command of more steps than that keeps one line a step -- the row grows --
/// up to `ASK_MAX_STEPS`; past that the last line says how many steps are
/// not shown. So a step is either on the row from its first character or
/// counted on it, and none goes without a word. The macOS host's
/// `ControlRoomAskFit` is the same rule.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AskFit {
    /// How many lines each step that is shown is drawn on, in order.
    pub lines: Vec<usize>,
    /// Steps that are not shown and are said as a number instead.
    pub hidden: usize,
}

impl AskFit {
    /// Every line this takes on the row, the one that says `hidden` among
    /// them.
    pub fn drawn(&self) -> usize {
        self.lines.iter().sum::<usize>() + usize::from(self.hidden > 0)
    }

    /// `needed` is how many lines each step would take with all the room it
    /// wanted, in order: a measurement, which is the host's to make.
    pub fn fit(needed: &[usize]) -> AskFit {
        let max_lines = side::ASK_MAX_LINES as usize;
        let max_steps = side::ASK_MAX_STEPS as usize;
        let steps = needed.len();
        if steps == 0 {
            return AskFit::default();
        }
        if steps > max_steps {
            // One line is kept for the number.
            return AskFit { lines: vec![1; max_steps - 1], hidden: steps - (max_steps - 1) };
        }
        let mut lines = vec![1; steps];
        let mut spare = max_lines.saturating_sub(steps);
        for (at, want) in needed.iter().enumerate() {
            let more = spare.min(want.max(&1) - 1);
            lines[at] += more;
            spare -= more;
        }
        AskFit { lines, hidden: 0 }
    }
}

/// How many lines `text` takes with no font to measure it by: so many cells
/// to a line (`ASK_CELLS_PER_LINE`), a wide character two. What the two
/// hosts are held to one answer with; a host that draws measures with its
/// own font and hands that to `ListLayout::measured`.
pub fn nominal_lines(text: &str) -> usize {
    let per_line = side::ASK_CELLS_PER_LINE as usize;
    let cells: usize = text.chars().map(|c| if c as u32 >= 0x2E80 { 2 } else { 1 }).sum();
    cells.div_ceil(per_line).max(1)
}

/// Break `text` into lines, given how much of a string fits on one.
///
/// `fits` is the host's measurement: how many characters from the start of
/// what it is handed fit in the width a row gives. A line breaks after the
/// last space that fits and drops it; with no space to break at -- a path,
/// a long flag -- it breaks where the room ends. Text that is empty is one
/// empty line: a step has a line whether or not there is anything on it.
///
/// A host that draws with a system call that wraps for it does not need
/// this. GDI's wraps at the font's own line height, not the row's
/// (`ASK_LINE_HEIGHT`), so the Windows host breaks lines here and draws
/// them one at a time.
pub fn wrap(text: &str, fits: &dyn Fn(&str) -> usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text.trim_end();
    // A measurement that says "nothing fits" still moves one character on,
    // or this would never end.
    while !rest.is_empty() && out.len() < 1000 {
        let total = rest.chars().count();
        let n = fits(rest).clamp(1, total);
        if n >= total {
            break;
        }
        let end: usize = rest.char_indices().nth(n).map_or(rest.len(), |(at, _)| at);
        let head = &rest[..end];
        // After the last space that fits, unless the very next character is
        // one (then the whole of `head` is a word's end already).
        let next_is_space = rest[end..].starts_with(char::is_whitespace);
        let cut = if next_is_space { end } else { head.rfind(char::is_whitespace).map_or(end, |at| if at == 0 { end } else { at }) };
        out.push(rest[..cut].trim_end().to_string());
        rest = rest[cut..].trim_start();
    }
    out.push(rest.to_string());
    out
}

/// What is drawn on each of the `lines` lines a step has: its wrapped
/// lines, and when there are more of them than that, **all of the rest on
/// the last one** -- the host draws that line cut at its end with an
/// ellipsis, so what is lost is the end of a line and never a line from the
/// middle. Fewer than `lines` when the text is shorter.
pub fn block_lines(text: &str, lines: usize, fits: &dyn Fn(&str) -> usize) -> Vec<String> {
    let lines = lines.max(1);
    let mut all = wrap(text, fits);
    if all.len() > lines {
        let rest = all.split_off(lines - 1).join(" ");
        all.push(rest);
    }
    all
}

/// How wide what a row waits on is: the row, less its padding and the
/// column the glyph stands in.
pub fn ask_width() -> f64 {
    side::WIDTH - 2.0 * space::SIDE_PANEL_PADDING - 2.0 * side::ROW_PADDING_X - side::GLYPH - side::ROW_ITEM_GAP
}

/// How high a waiting row is: its first line, the lines of what it waits
/// on, one more when other terminals of the group wait too, and the line
/// with "Fix" on a card that has it (task 1560). The macOS host's
/// `ControlRoomListLayout.rowHeight`.
pub fn row_height(fit: &AskFit, others: u64, fix: Fix) -> f64 {
    let lines = fit.drawn() + usize::from(others > 0);
    2.0 * side::ROW_PADDING_Y
        + side::ROW_LINE1_HEIGHT
        + lines as f64 * side::ASK_LINE_HEIGHT
        + if fix == Fix::None { 0.0 } else { side::FIX_LINE_HEIGHT }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ListLayout {
    pub width: f64,
    pub height: f64,
    pub header: Rect,
    /// The waiting rows and then the quiet ones, by `Row::id`.
    pub rows: Vec<(String, Rect)>,
    /// How what each waiting row waits on is fitted, by `Row::id`. The
    /// row's height came from this, so whatever draws the row draws by it.
    pub fits: Vec<(String, AskFit)>,
    pub separator: Rect,
    pub quiet_header: Rect,
    /// The notice that the first sweep of old records waits for the
    /// person, under the header, when there is one: the rows start below
    /// it. Two lines of text and an OK (`scene::retention_ok_hit`).
    pub notice: Option<Rect>,
}

/// How high the notice is: two lines, the OK under them, and the row's
/// padding round both. Fixed rather than measured: the sentence is one
/// short line in every language this ships in, and the second line is room.
pub fn notice_height() -> f64 {
    2.0 * side::ASK_LINE_HEIGHT + NOTICE_BUTTON_H + 4.0 + 2.0 * side::ROW_PADDING_Y
}

/// The notice's OK.
pub const NOTICE_BUTTON_H: f64 = 24.0;
pub const NOTICE_BUTTON_W: f64 = 56.0;

impl ListLayout {
    /// Laid out by the nominal count of lines.
    pub fn new(list: &List, height: f64) -> ListLayout {
        Self::measured(list, height, &|text, _| nominal_lines(text))
    }

    /// `needed` says how many lines one step would take with all the room
    /// it wanted, and whether it is set in the terminal's face: the host's
    /// measurement.
    pub fn measured(list: &List, height: f64, needed: &dyn Fn(&str, bool) -> usize) -> ListLayout {
        let pad = space::SIDE_PANEL_PADDING;
        let width = side::WIDTH;
        let inner = width - 2.0 * pad;
        let pad_x = side::HEADER_PADDING_X;
        let header_h = side::HEADER_HEIGHT;

        let mut y = pad;
        let header = Rect { x: pad, y, w: inner, h: header_h };
        y += header_h;
        // The first sweep waiting for the person: under the header, and the
        // rows move down to make room (task 1511).
        let notice = list.retention_waiting_bytes.map(|_| {
            let r = Rect { x: pad, y, w: inner, h: notice_height() };
            y += r.h + side::ROW_GAP;
            r
        });

        let mut rows = Vec::new();
        let mut fits = Vec::new();
        for row in &list.waiting {
            let code = crate::list::is_code(&row.what);
            let wanted: Vec<usize> = crate::list::drawn(&row.what).iter().map(|line| needed(line, code)).collect();
            let fit = AskFit::fit(&wanted);
            let row_h = row_height(&fit, row.others, row.fix);
            rows.push((row.id.clone(), Rect { x: pad, y, w: inner, h: row_h }));
            fits.push((row.id.clone(), fit));
            y += row_h + side::ROW_GAP;
        }

        let (separator, quiet_header) = if list.waiting_count == 0 {
            // The core says nobody is waiting: the one header says so, and
            // the groups follow it with no line and no second header
            // between. Both are kept, with no height, where they would be.
            (Rect { x: pad + pad_x, y, w: inner - 2.0 * pad_x, h: 0.0 }, Rect { x: pad, y, w: inner, h: 0.0 })
        } else {
            y += side::SEPARATOR_SPACE_ABOVE;
            let separator = Rect { x: pad + pad_x, y, w: inner - 2.0 * pad_x, h: line::HAIRLINE };
            y += line::HAIRLINE + side::SEPARATOR_SPACE_BELOW;
            let quiet_header = Rect { x: pad, y, w: inner, h: header_h };
            y += header_h;
            (separator, quiet_header)
        };
        for row in &list.quiet {
            rows.push((row.id.clone(), Rect { x: pad, y, w: inner, h: side::QUIET_ROW_HEIGHT }));
            y += side::QUIET_ROW_HEIGHT;
        }

        ListLayout { width, height, header, rows, fits, separator, quiet_header, notice }
    }

    /// The row under a point of the panel, by its group's name.
    pub fn row_at(&self, x: f64, y: f64) -> Option<&str> {
        self.rows
            .iter()
            .find(|(_, r)| x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
            .map(|(name, _)| name.as_str())
    }

    /// How what a waiting row waits on is fitted; none for a row that is
    /// not a waiting one.
    pub fn fit(&self, id: &str) -> Option<&AskFit> {
        self.fits.iter().find(|(name, _)| name == id).map(|(_, f)| f)
    }

    /// Where the selection chip rests for a row; none for a row not listed.
    pub fn chip(&self, id: Option<&str>) -> Option<Rect> {
        let id = id?;
        self.rows.iter().find(|(name, _)| name == id).map(|(_, r)| *r)
    }
}

/// The control room's two sides inside its tab, whose content area is
/// `width` by `height`: the list panel on the left, and what is left for the
/// selected group on the right.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Room {
    pub panel: Rect,
    pub right: Rect,
}

impl Room {
    pub fn new(width: f64, height: f64) -> Room {
        let edge = space::WINDOW_EDGE;
        let h = (height - 2.0 * edge).max(0.0);
        let panel = Rect { x: edge, y: edge, w: side::WIDTH, h };
        let x = panel.x + panel.w + space::BETWEEN_FRAMES;
        Room { panel, right: Rect { x, y: edge, w: (width - x - edge).max(0.0), h } }
    }
}

/// The chip's slide, as numbers: an under-damped spring from 0 to 1. Where
/// the chip is at a moment of a slide, and when the slide is over, is
/// `crate::slide`.
pub mod spring {
    use crate::look::selection;

    /// Progress at `t` seconds: 0 at the start, settling on 1.
    pub fn progress(t: f64) -> f64 {
        progress_with(t, selection::SPRING_PERIOD, selection::SPRING_DAMPING)
    }

    pub fn progress_with(t: f64, period: f64, damping: f64) -> f64 {
        if t <= 0.0 || period <= 0.0 {
            return 0.0;
        }
        let omega = 2.0 * std::f64::consts::PI / period;
        if damping >= 1.0 {
            // Critically damped: no overshoot.
            return 1.0 - (1.0 + omega * t) * (-omega * t).exp();
        }
        let wd = omega * (1.0 - damping * damping).sqrt();
        let decay = (-damping * omega * t).exp();
        1.0 - decay * ((wd * t).cos() + damping * omega / wd * (wd * t).sin())
    }

    /// How far past 1 it goes at its furthest, as a fraction.
    pub fn overshoot(damping: f64) -> f64 {
        if damping >= 1.0 {
            return 0.0;
        }
        (-damping * std::f64::consts::PI / (1.0 - damping * damping).sqrt()).exp()
    }
}
