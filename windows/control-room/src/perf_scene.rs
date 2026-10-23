//! The performance page, laid out and drawn (task 2015, Q8; ui-v4,
//! `polter-artifacts/1985/ui-v4/CHANGES.md`): the overview -- the machine's
//! line and the history grid -- and under it a card for each terminal.
//!
//! **Where everything goes is worked out here, and the host paints it**: a
//! list of `Draw`s, which are the scene's items plus the three things a card
//! has that the rest of the control room does not -- an arc, a line through
//! points, and the area under one. Every colour is laid over what it lies
//! on first, as the scene's are, because GDI has no alpha.
//!
//! Lengths are points from the page's top left (`rightpage::Paged::page`),
//! with the page scrolled up by `scroll`.
//!
//! **The words are the core's** (`perf`); only their widths are the host's,
//! through `Measure`.

use crate::layout::Rect;
use crate::level::{level_ink, Level};
use crate::look::{font, perf_card as c, perf_grid as g, perf_page as p, Rgba, Theme};
use crate::perf::{Card, Curves, Resources, Span, Toned};
use crate::scene::{self, Align, Face, Item, Part, Piece, Side, Style};

/// **Not in the look yet**: the least a history cell and the gap between
/// two are scaled to (L3, 739abea4b, did not take them).
pub mod x {
    /// The least a history cell and the gap between two are scaled to
    /// before only the newest cells are drawn (group seq 223, the
    /// supervisor's numbers after 0x4881's real-machine reading).
    pub const MIN_CELL: f64 = 8.0;
    pub const MIN_CELL_GAP: f64 = 2.0;
}

/// How wide `text` is in `style`, in points: the host's fonts.
pub type Measure<'a> = &'a dyn Fn(&str, &Style) -> f64;

/// The machine's line in the order it is drawn: its label, the memory and
/// what it is out of, the swap, the pressure, the terminals, the day.
pub mod machine_item {
    pub const LABEL: usize = 0;
    pub const MEM: usize = 1;
    pub const SWAP: usize = 2;
    pub const PRESSURE: usize = 3;
    pub const PANES: usize = 4;
    pub const DAY: usize = 5;
    /// **Which go first when the line is too narrow** (group seq 263: not
    /// every item cut to "…"): the day, the terminals, the swap, the label,
    /// the pressure. The memory never goes. The mac host drops in the same
    /// order (`ControlRoomPerfPage.machineDropOrder`).
    pub const DROP_ORDER: [usize; 5] = [DAY, PANES, SWAP, LABEL, PRESSURE];
}

/// Which of the items a line keeps in `room`: `widths[i]` wide, `gaps[i]`
/// before it when an item is kept before it; dropped in `drop_order` until
/// the rest fit whole. One never in `drop_order` is always kept, fit or
/// not. Nothing is shortened.
pub fn keep_by_priority(widths: &[f64], gaps: &[f64], drop_order: &[usize], room: f64) -> Vec<bool> {
    let mut keep = vec![true; widths.len()];
    let total = |keep: &[bool]| {
        let mut sum = 0.0;
        let mut any = false;
        for (i, w) in widths.iter().enumerate() {
            if keep[i] {
                if any {
                    sum += gaps[i];
                }
                sum += w;
                any = true;
            }
        }
        sum
    };
    for &i in drop_order {
        if total(&keep) <= room + 1e-9 {
            break;
        }
        if i < keep.len() {
            keep[i] = false;
        }
    }
    keep
}

/// Where the axis's words go, or none for one left out: `marks[i]` is a
/// drawn cell's left edge and its word's width, in order. The first word
/// starts at its cell's left, the last ends at its cell's right, the rest
/// are centred on theirs -- and **one that would come nearer than `gap` to
/// another is not drawn** (group seq 263: "昨天…" lay over "06:00"). The
/// last ("now") is placed first, then the first, then the rest from the
/// left. The mac host places them by the same rule
/// (`ControlRoomPerfLayout.axisPlaces`).
pub fn axis_places(marks: &[(f64, f64)], size: f64, gap: f64) -> Vec<Option<f64>> {
    let n = marks.len();
    let want = |i: usize| {
        let (left, w) = marks[i];
        if i + 1 == n && n > 1 {
            left + size - w
        } else if i == 0 {
            left
        } else {
            left + size / 2.0 - w / 2.0
        }
    };
    let mut order: Vec<usize> = Vec::with_capacity(n);
    if n > 0 {
        order.push(n - 1);
    }
    order.extend(0..n.saturating_sub(1));
    let mut placed: Vec<Option<f64>> = vec![None; n];
    for i in order {
        let x = want(i);
        let w = marks[i].1;
        let clear = placed.iter().enumerate().all(|(j, at)| match at {
            Some(xj) => x + w + gap <= *xj + 1e-9 || *xj + marks[j].1 + gap <= x + 1e-9,
            None => true,
        });
        if clear {
            placed[i] = Some(x);
        }
    }
    placed
}

#[derive(Debug, Clone, PartialEq)]
pub enum Draw {
    Item(Item),
    /// Part of a circle, `width` wide with round ends: from `from` degrees,
    /// `sweep` degrees on, clockwise on the screen (three o'clock is 0, y
    /// down).
    Arc { centre: (f64, f64), radius: f64, from: f64, sweep: f64, width: f64, color: Rgba },
    /// A line through `points`, round at its ends and joins; dashed `(on,
    /// off)` when `dash` is there.
    Stroke { points: Vec<(f64, f64)>, width: f64, color: Rgba, dash: Option<(f64, f64)> },
    /// The polygon `points` closes, filled.
    Area { points: Vec<(f64, f64)>, color: Rgba },
    /// `color` over what is there, whole at one edge of `rect` and gone at
    /// the other: the top one when `from_top`. What says a list goes on
    /// past its edge (#2083).
    Fade { rect: Rect, color: Rgba, from_top: bool },
}

/// Where the page's parts are.
#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub width: f64,
    /// The box round the machine's line and the grid.
    pub summary: Rect,
    /// The machine's line, inside it, and the span buttons at its right.
    pub top: Rect,
    pub spans: Vec<(Span, Rect)>,
    pub grid_head: Rect,
    /// The grid's names, its first cell, the first row's top.
    pub label_x: f64,
    pub cells_x: f64,
    /// How the cells stand in the room from `cells_x` on.
    pub cells: Cells,
    pub rows_top: f64,
    pub panes: usize,
    pub span: Span,
    pub axis: Rect,
    pub cards_head: Rect,
    pub cards: Vec<Rect>,
    /// How tall the page is unscrolled: what `scroll` is held under.
    pub content_height: f64,
}

/// The span button's words, set the way the one in front is.
pub fn span_style(theme: &Theme, on: bool) -> Style {
    Style {
        size: font::BODY,
        weight: if on { font::WEIGHT_EMPHASIS } else { font::WEIGHT_BODY },
        face: Face::Ui,
        color: if on { theme.text } else { theme.text_secondary },
    }
}

fn l3(color: Rgba) -> Style {
    Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color }
}

fn strong(color: Rgba) -> Style {
    Style { weight: font::WEIGHT_EMPHASIS, ..l3(color) }
}

/// How many cards stand side by side in `inner` points: as many whole
/// cards of `perf_card::WIDTH` as fit with `perf_card::BETWEEN` between
/// them, and never none.
pub fn columns(inner: f64) -> usize {
    (((inner + c::BETWEEN) / (c::WIDTH + c::BETWEEN)).floor() as usize).max(1)
}

/// How the history's cells are drawn in the room the overview has for them
/// (group seq 223, after 0x4881 found the 48 cells running past the frame
/// at the window's first size): at the look's size when they fit; scaled
/// down together -- square, no smaller than `x::MIN_CELL` with `x::
/// MIN_CELL_GAP` between -- when they do not; and when even that is too
/// wide, **the newest that fit**, against the right end, from `first`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cells {
    pub size: f64,
    pub gap: f64,
    pub group_gap: f64,
    /// The first cell drawn; 0 when all are.
    pub first: usize,
    /// How many there are.
    pub count: usize,
    pub span: Span,
    /// Where the first drawn cell's left edge is, from the left of the room.
    pub lead: f64,
}

impl Cells {
    /// Day boundaries crossed from cell `a` to cell `b` (a week stands in
    /// days of `DAY_GROUP`; a day does not).
    fn days_between(span: Span, a: usize, b: usize) -> usize {
        match span {
            Span::Day => 0,
            Span::Week => b / g::DAY_GROUP as usize - a / g::DAY_GROUP as usize,
        }
    }

    /// How wide the cells from `from` to the last are at these sizes.
    fn width(span: Span, count: usize, from: usize, size: f64, gap: f64, group_gap: f64) -> f64 {
        if count == 0 || from >= count {
            return 0.0;
        }
        let n = (count - from) as f64;
        n * size + (n - 1.0) * gap + Self::days_between(span, from, count - 1) as f64 * group_gap
    }

    pub fn fit(span: Span, count: usize, room: f64) -> Cells {
        let full = Self::width(span, count, 0, g::CELL, g::CELL_GAP, g::GROUP_GAP);
        let (size, gap, group_gap) = if full <= room || full == 0.0 {
            (g::CELL, g::CELL_GAP, g::GROUP_GAP)
        } else {
            let k = room / full;
            ((g::CELL * k).max(x::MIN_CELL), (g::CELL_GAP * k).max(x::MIN_CELL_GAP), (g::GROUP_GAP * k).max(x::MIN_CELL_GAP))
        };
        let mut first = 0;
        while first + 1 < count && Self::width(span, count, first, size, gap, group_gap) > room + 1e-9 {
            first += 1;
        }
        let lead = if first > 0 { (room - Self::width(span, count, first, size, gap, group_gap)).max(0.0) } else { 0.0 };
        Cells { size, gap, group_gap, first, count, span, lead }
    }

    /// How many are drawn, and in how many days a week's are.
    pub fn drawn(&self) -> usize {
        self.count.saturating_sub(self.first)
    }

    pub fn groups(&self) -> usize {
        match self.drawn() {
            0 => 0,
            _ if self.span == Span::Week => Self::days_between(self.span, self.first, self.count - 1) + 1,
            _ => 1,
        }
    }

    /// The left edge of `cell` from the left of the room; none for one
    /// before `first`, which is not drawn.
    pub fn offset(&self, cell: usize) -> Option<f64> {
        (cell >= self.first && cell < self.count).then(|| {
            self.lead + (cell - self.first) as f64 * (self.size + self.gap) + Self::days_between(self.span, self.first, cell) as f64 * self.group_gap
        })
    }
}

/// `r`'s page `width` points wide, scrolled up by `scroll`.
/// What the core said of the grid and what the page draws of it at `width`
/// (group seq 315): `grid.span`, `grid.cells` and the first terminal's cell
/// count as sent, and the cells and days laid out. Written as the mac host
/// writes it (`ControlRoomPerfFeed.drewLine`), so the two read alike.
pub fn drew_line(r: &Resources, at: &Layout) -> String {
    let first = r.grid.panes.first().map_or("none".to_string(), |p| p.cells.len().to_string());
    let c = &at.cells;
    format!(
        "answer span={} cells={} first pane={}; drew {} cells from {} in {} group(s), {} pt at width {}",
        r.grid.span.name(),
        r.grid.cells,
        first,
        c.drawn(),
        c.first,
        c.groups(),
        c.size as i64,
        at.width as i64
    )
}

pub fn layout(r: &Resources, width: f64, scroll: f64, theme: &Theme, measure: Measure) -> Layout {
    let x0 = p::PADDING;
    let inner = (width - 2.0 * p::PADDING).max(0.0);
    let y0 = p::PADDING - scroll;
    let top = Rect { x: x0 + p::SUMMARY_PAD_X, y: y0 + p::SUMMARY_PAD_Y, w: (inner - 2.0 * p::SUMMARY_PAD_X).max(0.0), h: p::MACHINE_HEIGHT };
    // The span buttons, from the right end of the machine's line.
    let mut spans = Vec::new();
    let mut right = top.x + top.w;
    for (span, words) in r.grid.spans.iter().rev() {
        let w = measure(words, &span_style(theme, *span == r.grid.span));
        spans.push((*span, Rect { x: right - w, y: top.y + (p::MACHINE_HEIGHT - p::SEG_HEIGHT) / 2.0, w, h: p::SEG_HEIGHT }));
        right -= w + p::SEG_GAP;
    }
    spans.reverse();
    let grid_head = Rect { x: top.x, y: top.y + top.h + p::SUMMARY_LAYER_GAP, w: top.w, h: g::HEAD_HEIGHT };
    let rows_top = grid_head.y + grid_head.h + g::ROWS_TOP;
    let n = r.grid.panes.len();
    let rows_h = if n == 0 { 0.0 } else { n as f64 * g::ROW_HEIGHT + (n - 1) as f64 * g::ROW_GAP };
    let axis = Rect { x: top.x, y: rows_top + rows_h + g::AXIS_GAP, w: top.w, h: g::AXIS_HEIGHT };
    let summary = Rect { x: x0, y: y0, w: inner, h: axis.y + axis.h + p::SUMMARY_PAD_Y - y0 };
    let cards_head = Rect {
        x: x0 + p::CARDS_TITLE_INSET,
        y: summary.y + summary.h + p::CARDS_TITLE_TOP,
        w: (inner - 2.0 * p::CARDS_TITLE_INSET).max(0.0),
        h: p::CARDS_TITLE_HEIGHT,
    };
    let cards_top = cards_head.y + cards_head.h + p::CARDS_TOP;
    let cols = columns(inner);
    let cards: Vec<Rect> = (0..r.cards.len())
        .map(|i| Rect {
            x: x0 + (i % cols) as f64 * (c::WIDTH + c::BETWEEN),
            y: cards_top + (i / cols) as f64 * (c::HEIGHT + c::BETWEEN),
            w: c::WIDTH,
            h: c::HEIGHT,
        })
        .collect();
    let bottom = cards.last().map_or(cards_top, |r| r.y + r.h) + p::PADDING;
    Layout {
        width,
        summary,
        top,
        spans,
        grid_head,
        label_x: top.x,
        cells_x: top.x + g::LABEL_WIDTH + g::LABEL_GAP,
        cells: Cells::fit(r.grid.span, r.grid.cells, (top.w - g::LABEL_WIDTH - g::LABEL_GAP).max(0.0)),
        rows_top,
        panes: n,
        span: r.grid.span,
        axis,
        cards_head,
        cards,
        content_height: bottom + scroll,
    }
}

impl Layout {
    /// How far the page can scroll in a page `height` points tall.
    pub fn max_scroll(&self, height: f64) -> f64 {
        (self.content_height - height).max(0.0)
    }

    /// Row `row`'s line in the grid.
    pub fn row_rect(&self, row: usize) -> Rect {
        Rect { x: self.label_x, y: self.rows_top + row as f64 * (g::ROW_HEIGHT + g::ROW_GAP), w: g::LABEL_WIDTH, h: g::ROW_HEIGHT }
    }

    /// One cell: square, in the middle of its row's height; none for one
    /// before the first drawn (`Cells`).
    pub fn cell_rect(&self, row: usize, cell: usize) -> Option<Rect> {
        let r = self.row_rect(row);
        let size = self.cells.size;
        self.cells.offset(cell).map(|dx| Rect { x: self.cells_x + dx, y: r.y + (g::ROW_HEIGHT - size) / 2.0, w: size, h: size })
    }

    /// The cell under `(x, y)`, as `(row, cell)`: only a drawn one.
    pub fn cell_at(&self, x: f64, y: f64, _cells: usize) -> Option<(usize, usize)> {
        (0..self.panes).find_map(|row| {
            (self.cells.first..self.cells.count).find_map(|cell| {
                let r = self.cell_rect(row, cell)?;
                (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h).then_some((row, cell))
            })
        })
    }

    pub fn span_at(&self, x: f64, y: f64) -> Option<Span> {
        self.spans.iter().find(|(_, r)| x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h).map(|(s, _)| *s)
    }
}

fn text(rect: Rect, words: &str, style: Style, align: Align) -> Draw {
    Draw::Item(Item::Text { rect, text: words.to_string(), style, align })
}

fn line(rect: Rect, parts: Vec<Part>) -> Draw {
    Draw::Item(Item::Line { rect, parts })
}

fn words(text: &str, style: Style, side: Side, gap: f64) -> Part {
    Part { piece: Piece::Words { text: text.to_string(), style }, side, gap }
}

/// A tone's text colour, or `none` where it has no ink of its own.
fn toned_style(theme: &Theme, tone: Option<Level>, none: Rgba) -> Style {
    match tone.and_then(|l| level_ink(theme, l)) {
        Some(ink) => strong(ink.text),
        None => l3(none),
    }
}

/// A grid cell's colour on `ground`.
fn cell_color(theme: &Theme, level: Level, ground: Rgba) -> Rgba {
    match level {
        Level::None => scene::over(ground, theme.level_none, 1.0),
        Level::Ok => scene::over(ground, theme.level_ok, 1.0),
        other => level_ink(theme, other).map_or(ground, |ink| ink.base),
    }
}

/// The page under `at`, with `hovered` -- `(row, cell)` -- lit and its
/// tip drawn when the core says something about it.
#[allow(clippy::too_many_arguments)]
pub fn build(r: &Resources, curves: &Curves, at: &Layout, theme: &Theme, scale: f64, hovered: Option<(usize, usize)>, measure: Measure) -> Vec<Draw> {
    let ground = theme.terminal_background;
    let panel = scene::over(ground, theme.perf_card, 1.0);
    let panel_edge = scene::over(panel, theme.perf_card_edge, scene::hairline(scale).1);
    let mut out = Vec::new();

    // The overview.
    out.push(Draw::Item(Item::Round { rect: at.summary, radius: c::RADIUS_WINDOWS, color: panel, edge: Some(panel_edge) }));
    let m = &r.machine;
    let top_end = at.spans.first().map_or(at.top.x + at.top.w, |(_, s)| s.x - p::MACHINE_ITEM_GAP);
    // The items, whole, as many as fit (`machine_item::DROP_ORDER`).
    let secondary = l3(theme.text_secondary);
    let big = Style { size: c::FONT_BIG, weight: font::WEIGHT_EMPHASIS, face: Face::Ui, color: theme.text };
    let pressure_style = toned_style(theme, m.pressure_tone, theme.text_secondary);
    let none = String::new();
    let label = m.label.as_ref().unwrap_or(&none);
    let swap = m.swap.as_ref().unwrap_or(&none);
    let mem = m.mem.as_ref().unwrap_or(&none);
    let mem_of = m.mem_of.as_ref().unwrap_or(&none);
    let pressure = m.pressure.as_ref().unwrap_or(&none);
    let width_of = |s: &str, style: &Style| if scene::draws(s) { measure(s, style) } else { 0.0 };
    let widths = [
        width_of(label, &secondary),
        width_of(mem, &big) + 2.0 + width_of(mem_of, &secondary),
        width_of(swap, &secondary),
        width_of(pressure, &pressure_style),
        width_of(&m.panes, &secondary),
        width_of(&m.day, &secondary),
    ];
    let item_gap = p::MACHINE_ITEM_GAP;
    let gaps = [0.0, p::SUMMARY_PAD_X / 2.0, item_gap, item_gap, item_gap, item_gap];
    let present = [scene::draws(label), true, scene::draws(swap), scene::draws(pressure), scene::draws(&m.panes), scene::draws(&m.day)];
    let widths: Vec<f64> = widths.iter().zip(present).map(|(w, p)| if p { *w } else { 0.0 }).collect();
    let mut keep = keep_by_priority(&widths, &gaps, &machine_item::DROP_ORDER, (top_end - at.top.x).max(0.0));
    for (k, p) in keep.iter_mut().zip(present) {
        *k = *k && p;
    }
    let mut top = Vec::new();
    let gap_before = |top: &Vec<Part>, g: f64| if top.is_empty() { 0.0 } else { g };
    if keep[machine_item::LABEL] {
        top.push(words(label, secondary, Side::Lead, 0.0));
    }
    let g = gap_before(&top, p::SUMMARY_PAD_X / 2.0);
    // Each half only when the core read it (API.md §2.0); `tidy` leaves out
    // an empty part, gap and all.
    top.push(words(mem, big, Side::Lead, g));
    top.push(words(mem_of, secondary, Side::Lead, 2.0));
    if keep[machine_item::SWAP] {
        top.push(words(swap, secondary, Side::Lead, item_gap));
    }
    if keep[machine_item::PRESSURE] {
        top.push(words(pressure, pressure_style, Side::Lead, item_gap));
    }
    if keep[machine_item::PANES] {
        top.push(words(&m.panes, secondary, Side::Lead, item_gap));
    }
    if keep[machine_item::DAY] {
        top.push(words(&m.day, secondary, Side::Lead, item_gap));
    }
    out.push(line(Rect { w: (top_end - at.top.x).max(0.0), ..at.top }, top));
    for ((span, rect), (_, label)) in at.spans.iter().zip(&r.grid.spans) {
        let on = *span == r.grid.span;
        out.push(text(*rect, label, span_style(theme, on), Align::Left));
        if on {
            // Under the one in front a short rule; no grey ground (the
            // user's rule: "选中不用灰底").
            out.push(Draw::Item(Item::Fill { rect: Rect { y: rect.y + rect.h - p::SEG_RULE, h: p::SEG_RULE, ..*rect }, color: theme.text }));
        }
    }

    // The grid's heading: the title and what a cell is on the left, the
    // legend on the right -- each whole or not at all: the subtitle goes
    // first, then the legend (group seq 263).
    let title_w = width_of(&r.grid.title, &strong(theme.text));
    let subtitle_w = width_of(&r.grid.subtitle, &secondary);
    let legend_w: f64 = r.grid.legend.iter().map(|(_, w)| g::LABEL_GAP + g::LEGEND_SWATCH + g::LEGEND_GAP + width_of(w, &secondary)).sum();
    let head_keep = keep_by_priority(&[title_w, subtitle_w, legend_w], &[0.0, g::LABEL_GAP, 0.0], &[1, 2], at.grid_head.w);
    let mut legend_x = at.grid_head.x + at.grid_head.w;
    let mut legend = Vec::new();
    for (level, words_) in r.grid.legend.iter().rev().filter(|_| head_keep[2]) {
        let w = measure(words_, &l3(theme.text_secondary));
        legend_x -= w;
        legend.push(text(Rect { x: legend_x, y: at.grid_head.y, w, h: at.grid_head.h }, words_, l3(theme.text_secondary), Align::Left));
        legend_x -= g::LEGEND_GAP + g::LEGEND_SWATCH;
        let sw = Rect { x: legend_x, y: at.grid_head.y + (at.grid_head.h - g::LEGEND_SWATCH) / 2.0, w: g::LEGEND_SWATCH, h: g::LEGEND_SWATCH };
        legend.push(Draw::Item(Item::Round { rect: sw, radius: g::CELL_RADIUS, color: cell_color(theme, *level, panel), edge: None }));
        legend_x -= g::LABEL_GAP;
    }
    out.push(line(
        Rect { w: (legend_x - at.grid_head.x).max(0.0), ..at.grid_head },
        if head_keep[1] {
            vec![words(&r.grid.title, strong(theme.text), Side::Lead, 0.0), words(&r.grid.subtitle, l3(theme.text_secondary), Side::Lead, g::LABEL_GAP)]
        } else {
            vec![words(&r.grid.title, strong(theme.text), Side::Lead, 0.0)]
        },
    ));
    out.extend(legend);

    for (i, row) in r.grid.panes.iter().enumerate() {
        let lit = hovered.is_some_and(|(hr, _)| hr == i);
        let name_style = Style { face: Face::Mono, ..l3(if lit { theme.text } else { theme.text_secondary }) };
        out.push(text(at.row_rect(i), &row.name, name_style, Align::Left));
        for (k, level) in row.cells.iter().enumerate() {
            let Some(cell) = at.cell_rect(i, k) else { continue };
            let edge = if hovered == Some((i, k)) {
                Some(theme.text)
            } else {
                (*level == Level::Killed).then(|| level_ink(theme, Level::Killed).map(|ink| scene::over(panel, ink.edge, 1.0))).flatten()
            };
            out.push(Draw::Item(Item::Round { rect: cell, radius: g::CELL_RADIUS, color: cell_color(theme, *level, panel), edge }));
        }
    }
    // Earlier cells than there is room for: a faint mark at the left of the
    // first drawn, the height of the rows -- no words of the host's own.
    if at.cells.first > 0 && at.panes > 0 {
        let top = at.row_rect(0).y;
        let bottom = at.row_rect(at.panes - 1).y + g::ROW_HEIGHT;
        let mid = (top + bottom) / 2.0;
        let cx = at.cells_x + at.cells.lead - g::LABEL_GAP / 2.0;
        let h = 4.0;
        out.push(Draw::Stroke { points: vec![(cx + h / 2.0, mid - h), (cx - h / 2.0, mid), (cx + h / 2.0, mid + h)], width: 1.0, color: theme.text_tertiary, dash: None });
    }
    // The axis: the first word from its cell's left, the last ending at
    // its cell's right, the rest centred on theirs.
    // Only the words of drawn cells, on the same cells' places.
    // None nearer another than the label gap (`axis_places`).
    let marks: Vec<(f64, &String)> = r.grid.axis.iter().filter_map(|(cell, w)| at.cells.offset(*cell).map(|dx| (at.cells_x + dx, w))).collect();
    let widths: Vec<(f64, f64)> = marks.iter().map(|(left, words_)| (*left, measure(words_, &l3(theme.text_tertiary)))).collect();
    for ((x, (_, words_)), (_, w)) in axis_places(&widths, at.cells.size, g::LABEL_GAP).into_iter().zip(&marks).zip(&widths) {
        if let Some(x) = x {
            out.push(text(Rect { x, w: *w, ..at.axis }, words_, l3(theme.text_tertiary), Align::Left));
        }
    }

    // The line over the cards.
    // The line over the cards: the note on the right goes first when the
    // two do not fit whole (group seq 290, as the machine's line); the line
    // is one string of the core's, and only it left and still too long, it
    // is cut.
    let note_fits = keep_by_priority(
        &[width_of(&r.now_line, &secondary), width_of(&r.now_note, &secondary)],
        &[0.0, p::MACHINE_ITEM_GAP],
        &[1],
        at.cards_head.w,
    )[1];
    let mut over_cards = vec![words(&r.now_line, secondary, Side::Rest, 0.0)];
    if note_fits {
        over_cards.push(words(&r.now_note, secondary, Side::Trail, 0.0));
    }
    out.push(line(at.cards_head, over_cards));
    for (card, rect) in r.cards.iter().zip(&at.cards) {
        out.extend(build_card(card, curves.points(&card.id), *rect, r.now_ms, curve_span(r), theme, scale, measure));
    }

    if let Some((row, cell)) = hovered {
        out.extend(build_tip(r, at, row, cell, theme, scale, measure));
    }
    tidy(out)
}

/// Nothing empty is handed on (`scene::draws`): a core that has nothing to
/// say in a place -- `foot.right` before Q2 (API.md §2.1) -- says it with an
/// empty string, and an empty part of a line would still take its gap.
fn tidy(draws: Vec<Draw>) -> Vec<Draw> {
    draws
        .into_iter()
        .filter_map(|d| match d {
            Draw::Item(Item::Text { text, .. }) if !scene::draws(&text) => None,
            Draw::Item(Item::Line { rect, parts }) => {
                let parts: Vec<Part> = parts.into_iter().filter(|p| !matches!(&p.piece, Piece::Words { text, .. } if !scene::draws(text))).collect();
                (!parts.is_empty()).then_some(Draw::Item(Item::Line { rect, parts }))
            }
            other => Some(other),
        })
        .collect()
}

/// A point on a circle about `centre`, at `degrees` clockwise from three
/// o'clock on a screen.
pub fn on_circle(centre: (f64, f64), radius: f64, degrees: f64) -> (f64, f64) {
    let a = degrees.to_radians();
    (centre.0 + radius * a.cos(), centre.1 + radius * a.sin())
}

/// Where the parts of a card go, from its top left (ui-v4's grid): the
/// dial's box, the right column's four lines, the foot.
pub struct CardGrid {
    pub head: Rect,
    pub dial: Rect,
    pub cap: Rect,
    pub r1: Rect,
    pub r2: Rect,
    pub r3: Rect,
    pub r4: Rect,
    pub foot: Rect,
}

pub fn card_grid(card: Rect) -> CardGrid {
    let x = card.x + c::PAD_X;
    let inner = c::WIDTH - 2.0 * c::PAD_X;
    let head = Rect { x, y: card.y + c::PAD_Y, w: inner, h: c::HEAD };
    let body = head.y + c::HEAD + c::GAP;
    let col = x + c::DIAL + c::DIAL_GAP;
    let row = |y: f64, h: f64| Rect { x: col, y, w: c::COLUMN, h };
    let r1 = row(body, c::ROW1);
    let r2 = row(r1.y + r1.h + c::ROW_GAP, c::ROW2);
    let r3 = row(r2.y + r2.h + c::ROW_GAP, c::ROW3);
    let r4 = row(r3.y + r3.h + c::ROW_GAP, c::ROW4);
    CardGrid {
        head,
        dial: Rect { x, y: body, w: c::DIAL, h: c::DIAL },
        cap: Rect { x, y: body + c::DIAL_CAP_TOP, w: c::DIAL, h: c::DIAL_CAP_HEIGHT },
        r1,
        r2,
        r3,
        r4,
        foot: Rect { x, y: body + c::BODY + c::GAP, w: inner, h: c::FOOT },
    }
}

fn build_card(card: &Card, points: &[(u64, u64)], rect: Rect, now_ms: u64, span_ms: u64, theme: &Theme, scale: f64, measure: Measure) -> Vec<Draw> {
    let ground = theme.terminal_background;
    let bg = scene::over(ground, theme.perf_card, 1.0);
    let ink = level_ink(theme, card.tone);
    let edge = match ink {
        Some(i) => scene::over(bg, i.edge, 1.0),
        None => scene::over(bg, theme.perf_card_edge, scene::hairline(scale).1),
    };
    let cg = card_grid(rect);
    let mut out = vec![Draw::Item(Item::Round { rect, radius: c::RADIUS_WINDOWS, color: bg, edge: Some(edge) })];

    // The head: the name, its role, and at the right end the badge.
    let mut head_w = cg.head.w;
    if let Some(badge) = &card.badge {
        let style = toned_style(theme, badge.tone, theme.text_secondary);
        let w = measure(&badge.text, &style) + 2.0 * c::BADGE_PAD_X;
        let b = Rect { x: cg.head.x + cg.head.w - w, y: cg.head.y + (cg.head.h - c::BADGE_HEIGHT) / 2.0, w, h: c::BADGE_HEIGHT };
        let ground = badge.tone.and_then(|l| level_ink(theme, l)).map_or(bg, |i| scene::over(bg, i.badge, 1.0));
        out.push(Draw::Item(Item::Round { rect: b, radius: c::BADGE_RADIUS, color: ground, edge: None }));
        out.push(text(b, &badge.text, style, Align::Centre));
        head_w -= w + c::BADGE_PAD_X;
    }
    let mut head = vec![words(&card.name, Style { face: Face::Mono, ..strong(theme.text) }, Side::Lead, 0.0)];
    if let Some(role) = &card.role {
        head.push(words(role, l3(theme.text_tertiary), Side::Lead, c::BADGE_PAD_X));
    }
    out.push(line(Rect { w: head_w.max(0.0), ..cg.head }, head));

    // The dial -- only when the core said how full it is (a missing fill
    // reads as no dial, not as a dial at 0: `perf::card`).
    if let Some(dial) = &card.dial {
        // The dial: the track, the reading, the ticks; the number in the
        // middle; what the arc is measured against in its gap.
        let centre = (cg.dial.x + c::DIAL / 2.0, cg.dial.y + c::DIAL / 2.0);
        let from = c::DIAL_START_DEGREES;
        let sweep = c::DIAL_OPEN_DEGREES;
        out.push(Draw::Arc { centre, radius: c::DIAL_RADIUS, from, sweep, width: c::DIAL_STROKE, color: scene::over(bg, theme.perf_dial_track, 1.0) });
        let fill = dial.fraction.clamp(0.0, 1.0);
        if fill > 0.0 {
            let color = ink.map_or(theme.level_ok_arc, |i| i.base);
            out.push(Draw::Arc { centre, radius: c::DIAL_RADIUS, from, sweep: sweep * fill, width: c::DIAL_STROKE, color });
        }
        let mut ticks: Vec<(f64, Rgba)> = dial
            .ticks
            .iter()
            .enumerate()
            .filter_map(|(i, t)| level_ink(theme, if i == 0 { Level::Warn1 } else { Level::Warn2 }).map(|ink| (*t, ink.base)))
            .collect();
        if card.line_at.is_some() {
            if let Some(k) = level_ink(theme, Level::Killed) {
                ticks.push((1.0, k.base));
            }
        }
        for (t, color) in ticks {
            let a = from + sweep * t.clamp(0.0, 1.0);
            out.push(Draw::Stroke { points: vec![on_circle(centre, c::DIAL_TICK_INNER, a), on_circle(centre, c::DIAL_TICK_OUTER, a)], width: c::DIAL_TICK_STROKE, color, dash: None });
        }
        let big_style = Style {
            size: c::FONT_BIG,
            weight: font::WEIGHT_EMPHASIS,
            face: Face::Ui,
            color: if card.tone == Level::Killed { ink.map_or(theme.text, |i| i.text) } else { theme.text },
        };
        let unit_style = l3(theme.text_secondary);
        let (wb, wu) = (measure(&dial.big, &big_style), measure(&dial.unit, &unit_style));
        let start = cg.dial.x + (c::DIAL - (wb + 1.0 + wu)) / 2.0;
        // The big number's line, a 28-point line in the dial's middle; the unit
        // on its baseline.
        let big_y = centre.1 - 14.0;
        out.push(text(Rect { x: start, y: big_y, w: wb, h: 28.0 }, &dial.big, big_style, Align::Left));
        out.push(text(Rect { x: start + wb + 1.0, y: big_y + 8.0, w: wu, h: 20.0 }, &dial.unit, unit_style, Align::Left));
        out.push(text(cg.cap, &dial.cap, l3(theme.text_tertiary), Align::Centre));
    }

    // The four lines; one with nothing to say is left empty, and nothing
    // under it moves up.
    if let Some((value, rest)) = &card.r1 {
        out.push(line(
            cg.r1,
            vec![
                words(value, Style { size: c::FONT_VALUE, weight: font::WEIGHT_EMPHASIS, face: Face::Ui, color: theme.text }, Side::Lead, 0.0),
                words(rest, l3(theme.text_tertiary), Side::Rest, 4.0),
            ],
        ));
    }
    let said = |t: &Option<Toned>, rect: Rect, none: Rgba| t.as_ref().map(|t| text(rect, &t.text, toned_style(theme, t.tone, none), Align::Left));
    out.extend(said(&card.r2, cg.r2, theme.text_tertiary));
    out.extend(said(&card.r3, cg.r3, theme.text_secondary));
    out.extend(curve(points, card.line_at, cg.r4, now_ms, span_ms, bg, theme));

    out.push(line(cg.foot, vec![words(&card.foot.0, l3(theme.text_tertiary), Side::Rest, 0.0), words(&card.foot.1, l3(theme.text_tertiary), Side::Trail, 0.0)]));
    out
}

/// How long the curve shows: as many periods as a card keeps points
/// (`perf::KEPT_POINTS`), five minutes at two seconds (DESIGN-v2 §1).
pub fn curve_span(r: &Resources) -> u64 {
    crate::perf::KEPT_POINTS as u64 * r.period_ms
}

/// The last `span_ms` of `points` in `rect`: the area under the line,
/// the line, and the kill line dashed across when there is one. The top of
/// the scale is a little over the kill line, or twice and more the highest
/// point when there is none (ui-v4 `perf2.py` `spark`).
pub fn curve(points: &[(u64, u64)], line_at: Option<u64>, rect: Rect, now_ms: u64, span_ms: u64, ground: Rgba, theme: &Theme) -> Vec<Draw> {
    let span_ms = span_ms.max(1);
    let start = now_ms.saturating_sub(span_ms);
    let shown: Vec<&(u64, u64)> = points.iter().filter(|(t, _)| *t >= start && *t <= now_ms).collect();
    let highest = shown.iter().map(|(_, v)| *v).max().unwrap_or(0) as f64;
    let top = match line_at {
        Some(l) => l as f64 * 1.08,
        None => (highest * 2.2).max(1.0),
    };
    // Saturating: a point from before the window is at its left edge, never a wrapped number.
    let x = |t: u64| rect.x + t.saturating_sub(start) as f64 / span_ms as f64 * rect.w;
    let y = |v: f64| rect.y + rect.h - 1.0 - (rect.h - 2.0) * v.min(top) / top;
    let mut out = Vec::new();
    if shown.len() >= 2 {
        let line: Vec<(f64, f64)> = shown.iter().map(|(t, v)| (x(*t), y(*v as f64))).collect();
        let mut area = line.clone();
        area.push((line[line.len() - 1].0, rect.y + rect.h));
        area.push((line[0].0, rect.y + rect.h));
        out.push(Draw::Area { points: area, color: scene::over(ground, theme.perf_curve_fill, 1.0) });
        out.push(Draw::Stroke { points: line, width: c::CURVE_STROKE, color: theme.perf_curve, dash: None });
    }
    if let (Some(l), Some(k)) = (line_at, level_ink(theme, Level::Killed)) {
        let ly = y(l as f64);
        out.push(Draw::Stroke { points: vec![(rect.x, ly), (rect.x + rect.w, ly)], width: c::LINE_STROKE, color: k.base, dash: Some((c::CURVE_DASH, c::CURVE_GAP)) });
    }
    out
}

/// What the core says of `(row, cell)`, in a box at the cell's left, its
/// first line level with the cell (ui-v3: "放在那一格左边、同一高度"). None
/// for a cell it says nothing of.
pub fn build_tip(r: &Resources, at: &Layout, row: usize, cell: usize, theme: &Theme, scale: f64, measure: Measure) -> Vec<Draw> {
    let Some(lines) = r.grid.panes.get(row).and_then(|rw| rw.hover.iter().find(|(c, _)| *c == cell)).map(|(_, l)| l) else {
        return Vec::new();
    };
    let styles: Vec<Style> = lines.iter().map(|l| toned_style(theme, l.tone, theme.text)).collect();
    let w = lines.iter().zip(&styles).map(|(l, s)| measure(&l.text, s)).fold(0.0, f64::max) + 2.0 * g::TIP_PAD_X;
    let h = lines.len() as f64 * g::TIP_LINE_HEIGHT + 2.0 * g::TIP_PAD_Y;
    let Some(c) = at.cell_rect(row, cell) else { return Vec::new() };
    let x = (c.x - g::TIP_OFFSET - w).max(p::PADDING);
    let y = c.y + c.h / 2.0 - g::TIP_LINE_HEIGHT / 2.0 - g::TIP_PAD_Y;
    let edge = scene::over(theme.perf_tip, theme.perf_tip_edge, scene::hairline(scale).1.max(1.0));
    let mut out = vec![Draw::Item(Item::Round { rect: Rect { x, y, w, h }, radius: g::TIP_RADIUS, color: theme.perf_tip, edge: Some(edge) })];
    for (i, (l, s)) in lines.iter().zip(styles).enumerate() {
        out.push(text(Rect { x: x + g::TIP_PAD_X, y: y + g::TIP_PAD_Y + i as f64 * g::TIP_LINE_HEIGHT, w: w - 2.0 * g::TIP_PAD_X, h: g::TIP_LINE_HEIGHT }, &l.text, s, Align::Left));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::DARK;
    use crate::perf::decode;

    const DAY: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/resources-day.json"));
    const WEEK: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/resources-week.json"));
    const NULLS: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/resources-nulls.json"));

    /// Every field that may be null, null (API.md §2.0): the page is drawn
    /// without those items -- no empty words handed on, every card there.
    #[test]
    fn a_page_with_every_nullable_field_null_is_drawn_without_those_items() {
        let r = decode(NULLS).unwrap();
        let at = layout(&r, 1040.0, 0.0, &DARK, &nominal);
        let d = build(&r, &Curves::default(), &at, &DARK, 1.0, None, &nominal);
        let said = format!("{d:?}");
        for c in &r.cards {
            assert!(said.contains(&format!("{:?}", c.name)), "{}", c.name);
        }
        assert!(said.contains(&format!("{:?}", r.machine.panes)));
        assert!(!said.contains("交换 1.2 GB") && !said.contains("23.9"));
        for i in items(&d) {
            if let Item::Text { text, .. } = i {
                assert!(!text.is_empty());
            }
        }
    }

    /// No font: a character is `stack_tab::NOMINAL_CELL_WIDTH` scaled by the
    /// size over the body's, a wide one two.
    fn nominal(s: &str, style: &Style) -> f64 {
        let cells: usize = s.chars().map(|c| if c as u32 >= 0x2E80 { 2 } else { 1 }).sum();
        cells as f64 * crate::look::stack_tab::NOMINAL_CELL_WIDTH * style.size / font::BODY
    }

    fn page(width: f64) -> (Resources, Layout) {
        let r = decode(DAY).unwrap();
        let at = layout(&r, width, 0.0, &DARK, &nominal);
        (r, at)
    }

    fn items(d: &[Draw]) -> Vec<&Item> {
        d.iter().filter_map(|d| if let Draw::Item(i) = d { Some(i) } else { None }).collect()
    }

    #[test]
    fn every_card_is_242_by_196_with_16_between_as_many_a_row_as_fit() {
        assert_eq!(columns(242.0), 1);
        assert_eq!(columns(242.0 * 2.0 + 16.0 - 0.5), 1);
        assert_eq!(columns(242.0 * 2.0 + 16.0), 2);
        assert_eq!(columns(4.0 * 242.0 + 3.0 * 16.0), 4);
        assert_eq!(columns(10.0), 1, "never none");
        let (_, at) = page(1040.0);
        // 1040 - 24 = 1016 = four cards and three gaps.
        assert!(at.cards.iter().all(|r| (r.w, r.h) == (242.0, 196.0)));
        assert_eq!((at.cards[1].x - at.cards[0].x, at.cards[4].y - at.cards[0].y), (258.0, 212.0));
        assert_eq!(at.cards[4].x, at.cards[0].x);
        let (_, narrow) = page(1039.0);
        assert_eq!(narrow.cards[3].y, narrow.cards[0].y + 212.0, "three a row one point narrower");
    }

    /// ui-v4 `metrics.md`: every card's r1–r4, dial and foot sit at the
    /// same place from its top left, whatever it says.
    #[test]
    fn a_cards_parts_are_where_ui_v4_measured_them() {
        let g = card_grid(Rect { x: 100.0, y: 50.0, w: 242.0, h: 196.0 });
        let at = |r: Rect| (r.x - 100.0, r.y - 50.0);
        assert_eq!(at(g.r1), (132.0, 40.0));
        assert_eq!(at(g.r2), (132.0, 72.0));
        assert_eq!(at(g.r3), (132.0, 100.0));
        assert_eq!(at(g.r4), (132.0, 128.0));
        assert_eq!(at(g.dial), (14.0, 40.0));
        assert_eq!(at(g.foot), (14.0, 164.0));
        assert_eq!(at(g.cap), (14.0, 126.0));
        assert_eq!((g.r4.w, g.r4.h), (96.0, 28.0));
        assert_eq!(g.foot.y + g.foot.h + c::PAD_Y, 50.0 + 196.0);
    }

    #[test]
    fn the_overview_holds_the_machine_line_the_heading_the_rows_and_the_axis() {
        let (r, at) = page(1040.0);
        assert_eq!((at.summary.x, at.summary.y), (12.0, 12.0));
        assert_eq!((at.top.x, at.top.y, at.top.h), (28.0, 24.0, 32.0));
        assert_eq!(at.grid_head.y, 24.0 + 32.0 + 10.0);
        assert_eq!(at.rows_top, at.grid_head.y + 20.0 + 8.0);
        // Eight rows of 18 with 4 between.
        assert_eq!(at.axis.y, at.rows_top + 8.0 * 18.0 + 7.0 * 4.0 + 6.0);
        assert_eq!(at.summary.y + at.summary.h, at.axis.y + 18.0 + 12.0);
        assert_eq!(at.cards_head.y, at.summary.y + at.summary.h + 12.0);
        assert_eq!(at.cards[0].y, at.cards_head.y + 20.0 + 8.0);
        assert_eq!(at.cards[0].x, 12.0);
        // The cells: 13 square, 3 apart, in the middle of an 18 row, from
        // after the names.
        assert_eq!(at.cells_x, 28.0 + 132.0 + 12.0);
        let c0 = at.cell_rect(0, 0).unwrap();
        assert_eq!((c0.x, c0.y, c0.w), (at.cells_x, at.rows_top + 2.5, 13.0));
        assert_eq!(at.cell_rect(0, 47).unwrap().x, at.cells_x + 47.0 * 16.0);
        assert_eq!(at.cell_rect(2, 0).unwrap().y, c0.y + 2.0 * 22.0);
        assert_eq!((at.cells.first, at.cells.size, at.cells.gap), (0, 13.0, 3.0), "all at the look's size where they fit");
        // The span buttons end at the line's right end, the second there.
        let (s0, s1) = (at.spans[0].1, at.spans[1].1);
        assert_eq!(s1.x + s1.w, at.top.x + at.top.w);
        assert_eq!(s0.x + s0.w + 16.0, s1.x);
        assert_eq!((at.spans[0].0, at.spans[1].0), (Span::Day, Span::Week));
        assert_eq!(at.content_height, at.cards[7].y + 196.0 + 12.0);
        assert_eq!(r.grid.panes.len(), at.panes);
    }

    #[test]
    fn the_week_stands_in_days_with_a_gap_between() {
        let w = Cells::fit(Span::Week, 42, 2000.0);
        assert_eq!(w.offset(5), Some(5.0 * 16.0));
        assert_eq!(w.offset(6), Some(6.0 * 16.0 + 7.0));
        assert_eq!(w.offset(41), Some(41.0 * 16.0 + 6.0 * 7.0));
        assert_eq!(Cells::fit(Span::Day, 48, 2000.0).offset(41), Some(41.0 * 16.0));
        let r = decode(WEEK).unwrap();
        let at = layout(&r, 1040.0, 0.0, &DARK, &nominal);
        assert_eq!(at.cell_rect(0, 6).unwrap().x - at.cell_rect(0, 5).unwrap().x, 16.0 + 7.0);
    }

    /// 0x4881, group seq 220: at the window's first size the 48 cells ran
    /// past the frame and the newest were cut off. Narrower, they are
    /// scaled down together, square; narrower still, the newest that fit
    /// are drawn against the right end, and the axis only under them.
    #[test]
    fn a_line_too_narrow_drops_whole_items_in_order_and_never_the_memory() {
        use machine_item::DROP_ORDER as ORDER;
        let w = [30.0, 100.0, 50.0, 40.0, 60.0, 70.0];
        let gaps = [0.0, 6.0, 10.0, 10.0, 10.0, 10.0];
        // Whole: 30 + 6+100 + 10+50 + 10+40 + 10+60 + 10+70 = 396.
        assert_eq!(keep_by_priority(&w, &gaps, &ORDER, 396.0), vec![true; 6]);
        // A point short: the day goes, and only the day.
        assert_eq!(keep_by_priority(&w, &gaps, &ORDER, 395.0), vec![true, true, true, true, true, false]);
        // Then the terminals, then the swap.
        assert_eq!(keep_by_priority(&w, &gaps, &ORDER, 316.0), vec![true, true, true, true, true, false]);
        assert_eq!(keep_by_priority(&w, &gaps, &ORDER, 315.0), vec![true, true, true, true, false, false]);
        assert_eq!(keep_by_priority(&w, &gaps, &ORDER, 245.0), vec![true, true, false, true, false, false]);
        // No room at all: the memory stays, whole, and nothing else.
        assert_eq!(keep_by_priority(&w, &gaps, &ORDER, 10.0), vec![false, true, false, false, false, false]);
    }

    #[test]
    fn axis_words_never_come_nearer_than_the_gap_and_now_is_always_drawn() {
        // The first at 0..50; the middle one, centred on its cell, at
        // 10..40, would lie over it; "now" ends at its cell's right, 80..110.
        let marks = [(0.0, 50.0), (20.0, 30.0), (100.0, 30.0)];
        assert_eq!(axis_places(&marks, 10.0, 12.0), vec![Some(0.0), None, Some(80.0)]);
        // A first that would touch "now" is the one left out.
        assert_eq!(axis_places(&[(0.0, 90.0), (100.0, 30.0)], 10.0, 12.0), vec![None, Some(80.0)]);
        // With room, every one where it was.
        let wide = [(0.0, 30.0), (100.0, 30.0), (300.0, 30.0)];
        assert_eq!(axis_places(&wide, 10.0, 12.0), vec![Some(0.0), Some(90.0), Some(280.0)]);
    }

    /// 0x373c's narrow page on mac (group seq 261), here the same numbers:
    /// the overview says fewer things, each whole, and its axis words never
    /// meet.
    #[test]
    fn on_a_narrow_page_the_overview_says_less_but_nothing_is_cut_or_overlaps() {
        let r = decode(DAY).unwrap();
        for width in [449.0, 588.0, 1028.0] {
            let at = layout(&r, width, 0.0, &DARK, &nominal);
            let d = build(&r, &Curves::default(), &at, &DARK, 1.0, None, &nominal);
            let its = items(&d);
            // The machine's line: its parts, whole, inside it.
            let line = its.iter().find_map(|i| match i {
                Item::Line { rect, parts } if rect.y == at.top.y => Some((rect, parts)),
                _ => None,
            });
            let (rect, parts) = line.expect("the machine's line");
            let used: f64 = parts.iter().enumerate().map(|(k, part)| match &part.piece {
                Piece::Words { text, style } => nominal(text, style) + if k == 0 { 0.0 } else { part.gap },
                _ => 0.0,
            }).sum();
            assert!(used <= rect.w + 1e-9, "width {width}: {used} in {}", rect.w);
            assert!(parts.iter().any(|part| matches!(&part.piece, Piece::Words { text, .. } if text == "23.9")), "width {width}: the memory");
            assert!(parts.iter().all(|part| part.side == Side::Lead), "nothing to be cut short");
            // The axis: in order, a gap between each two.
            let mut axis: Vec<(f64, f64)> = its.iter().filter_map(|i| match i {
                Item::Text { rect, .. } if rect.y == at.axis.y => Some((rect.x, rect.x + rect.w)),
                _ => None,
            }).collect();
            axis.sort_by(|a, b| a.0.total_cmp(&b.0));
            for pair in axis.windows(2) {
                assert!(pair[0].1 + g::LABEL_GAP <= pair[1].0 + 1e-9, "width {width}: {pair:?}");
            }
            assert!(!axis.is_empty());
        }
        // Wide, everything is said; narrow, the day is the first to go.
        let said = |width: f64| {
            let at = layout(&r, width, 0.0, &DARK, &nominal);
            format!("{:?}", build(&r, &Curves::default(), &at, &DARK, 1.0, None, &nominal))
        };
        assert!(said(1028.0).contains("24 小时内中断"));
        assert!(!said(449.0).contains("24 小时内中断"));
        assert!(said(449.0).contains("23.9"));
    }

    /// The line over the cards (group seq 290): wide, the line and the note;
    /// narrow, the note goes whole and the line alone is what is left.
    #[test]
    fn over_the_cards_the_note_goes_first() {
        let r = decode(DAY).unwrap();
        let note_drawn = |width: f64| {
            let at = layout(&r, width, 0.0, &DARK, &nominal);
            let d = build(&r, &Curves::default(), &at, &DARK, 1.0, None, &nominal);
            items(&d).iter().any(|i| matches!(i, Item::Line { rect, parts } if rect.y == at.cards_head.y && parts.iter().any(|p| matches!(&p.piece, Piece::Words { text, .. } if *text == r.now_note))))
        };
        assert!(note_drawn(1400.0));
        assert!(!note_drawn(449.0));
    }

    /// The line both hosts write of what the core sent and what was laid
    /// out (group seq 315): a week in 42 cells and 7 days, a day in 48 and
    /// one, a narrow day in its newest.
    #[test]
    fn the_drew_line_says_what_was_sent_and_what_is_laid_out() {
        let w = decode(WEEK).unwrap();
        let at = layout(&w, 1388.0, 0.0, &DARK, &nominal);
        assert!(drew_line(&w, &at).starts_with("answer span=week cells=42 first pane=42; drew 42 cells from 0 in 7 group(s), 13 pt"), "{}", drew_line(&w, &at));
        let d = decode(DAY).unwrap();
        let at = layout(&d, 1388.0, 0.0, &DARK, &nominal);
        assert!(drew_line(&d, &at).starts_with("answer span=day cells=48 first pane=48; drew 48 cells from 0 in 1 group(s)"));
        let at = layout(&d, 588.0, 0.0, &DARK, &nominal);
        assert_eq!((at.cells.drawn(), at.cells.first), (39, 9));
        assert!(drew_line(&d, &at).ends_with("8 pt at width 588"), "{}", drew_line(&d, &at));
    }

    #[test]
    fn too_narrow_the_cells_shrink_and_then_only_the_newest_are_drawn() {
        let room = |at: &Layout| at.top.w - g::LABEL_WIDTH - g::LABEL_GAP;
        // Room for 600: 48 cells scaled, all of them, ending at the room's end.
        let r = decode(DAY).unwrap();
        let at = layout(&r, 600.0 + 144.0 + 32.0 + 24.0, 0.0, &DARK, &nominal);
        assert_eq!(room(&at), 600.0);
        let c = at.cells;
        assert_eq!(c.first, 0);
        assert!(c.size < 13.0 && c.size > 8.0 && c.gap < 3.0);
        let last = at.cell_rect(0, 47).unwrap();
        assert!((last.x + last.w - (at.cells_x + 600.0)).abs() < 1e-9, "{last:?}");
        assert_eq!(last.w, last.h, "square");
        // The window's first size on the test machine: a page 588 wide.
        let at = layout(&r, 588.0, 0.0, &DARK, &nominal);
        let c = at.cells;
        assert_eq!((c.size, c.gap), (x::MIN_CELL, x::MIN_CELL_GAP));
        // 388 of room: 39 cells of 8 with 2 between -- the newest 39.
        assert_eq!(room(&at), 388.0);
        assert_eq!(c.first, 48 - 39);
        assert!(at.cell_rect(0, c.first - 1).is_none());
        let last = at.cell_rect(0, 47).unwrap();
        assert_eq!(last.x + last.w, at.cells_x + 388.0, "against the right end");
        assert!(at.cell_rect(0, c.first).unwrap().x >= at.cells_x);
        // Nothing is drawn past the frame, and the axis only under drawn cells.
        let d = build(&r, &Curves::default(), &at, &DARK, 1.0, None, &nominal);
        let frame_right = at.summary.x + at.summary.w;
        for i in items(&d) {
            if let Item::Round { rect, .. } = i {
                if rect.w == c.size {
                    assert!(rect.x + rect.w <= frame_right, "{rect:?}");
                }
            }
        }
        let said: Vec<String> = items(&d).iter().filter_map(|i| if let Item::Text { text, .. } = i { Some(text.clone()) } else { None }).collect();
        assert!(!said.iter().any(|t| t == "昨天 08:30"), "cell 0 is not drawn");
        assert!(said.iter().any(|t| t == "现在"));
        // The faint mark for what is earlier.
        assert!(d.iter().any(|x| matches!(x, Draw::Stroke { points, .. } if points.len() == 3)));
        // The room's left edge is the first drawn cell's (the 39 fill it
        // exactly), and a press there finds that cell, not cell 0.
        assert_eq!(at.cell_at(at.cells_x + 1.0, at.rows_top + 5.0, 48), Some((0, c.first)));
    }

    #[test]
    fn a_press_finds_its_cell_and_its_span_button_and_the_gaps_find_none() {
        let (_, at) = page(1040.0);
        let c = at.cell_rect(3, 10).unwrap();
        assert_eq!(at.cell_at(c.x + 1.0, c.y + 1.0, 48), Some((3, 10)));
        assert_eq!(at.cell_at(c.x + 13.5, c.y + 1.0, 48), None, "the gap between cells");
        assert_eq!(at.cell_at(c.x + 1.0, c.y - 1.0, 48), None, "above the cell in its row");
        let s = at.spans[1].1;
        assert_eq!(at.span_at(s.x + 1.0, s.y + 1.0), Some(Span::Week));
        assert_eq!(at.span_at(s.x - 1.0, s.y + 1.0), None);
    }

    #[test]
    fn scrolled_everything_moves_up_and_the_page_scrolls_no_further_than_its_end() {
        let r = decode(DAY).unwrap();
        let a = layout(&r, 1040.0, 0.0, &DARK, &nominal);
        let b = layout(&r, 1040.0, 100.0, &DARK, &nominal);
        assert_eq!(b.cards[5].y, a.cards[5].y - 100.0);
        assert_eq!(b.cell_rect(1, 1).unwrap().y, a.cell_rect(1, 1).unwrap().y - 100.0);
        assert_eq!(a.content_height, b.content_height);
        assert_eq!(a.max_scroll(a.content_height + 50.0), 0.0);
        assert_eq!(a.max_scroll(300.0), a.content_height - 300.0);
    }

    #[test]
    fn the_dial_fills_to_its_fraction_and_no_further_and_a_card_without_a_line_has_no_ticks() {
        let (r, at) = page(1040.0);
        let c = Curves::default();
        let d = build(&r, &c, &at, &DARK, 1.0, None, &nominal);
        let arcs: Vec<(f64, f64)> = d.iter().filter_map(|d| if let Draw::Arc { from, sweep, .. } = d { Some((*from, *sweep)) } else { None }).collect();
        // Track and reading per card: 16 arcs, every one from 150°.
        assert_eq!(arcs.len(), 16);
        assert!(arcs.iter().all(|(f, _)| *f == 150.0));
        // screenshot-diff at 0.7421 of 240°; ocr-mask past 1 drawn at 240.
        let sweep_of = |i: usize| arcs[2 * i + 1].1;
        assert!((sweep_of(1) - 240.0 * r.cards[1].dial.as_ref().unwrap().fraction).abs() < 1e-9);
        assert_eq!(sweep_of(3), 240.0);
        // Ticks: a card with a kill line has its two warnings and the line;
        // one without has none.
        let ticks_in = |card: Rect| {
            d.iter()
                .filter(|d| matches!(d, Draw::Stroke { points, dash: None, .. } if points.len() == 2 && points[0].0 >= card.x && points[0].0 <= card.x + card.w && points[0].1 >= card.y && points[0].1 <= card.y + card.h))
                .count()
        };
        assert_eq!(ticks_in(at.cards[1]), 3);
        assert_eq!(ticks_in(at.cards[0]), 0);
    }

    #[test]
    fn the_tip_is_at_the_cells_left_level_with_it_and_only_where_the_core_says_something() {
        let (r, at) = page(1040.0);
        let row = r.grid.panes.iter().position(|rw| !rw.hover.is_empty()).unwrap();
        let cell = r.grid.panes[row].hover[0].0;
        let t = build_tip(&r, &at, row, cell, &DARK, 1.0, &nominal);
        let Some(Draw::Item(Item::Round { rect, .. })) = t.first() else { panic!("no box") };
        let c = at.cell_rect(row, cell).unwrap();
        assert_eq!(rect.x + rect.w + g::TIP_OFFSET, c.x);
        assert_eq!(rect.h, 4.0 * 20.0 + 20.0);
        // The first line's middle is the cell's.
        let Draw::Item(Item::Text { rect: first, .. }) = &t[1] else { panic!() };
        assert_eq!(first.y + first.h / 2.0, c.y + c.h / 2.0);
        assert!(build_tip(&r, &at, row, cell - 1, &DARK, 1.0, &nominal).is_empty());
        assert!(build_tip(&r, &at, 0, 0, &DARK, 1.0, &nominal).is_empty());
    }

    #[test]
    fn the_curve_spans_the_points_a_card_keeps() {
        let r = decode(DAY).unwrap();
        assert_eq!(curve_span(&r), 150 * 2000);
    }

    #[test]
    fn the_curve_shows_five_minutes_under_its_scale_with_the_kill_line_dashed() {
        let rect = Rect { x: 0.0, y: 0.0, w: 96.0, h: 28.0 };
        let now = 1_000_000;
        let g = 1u64 << 30;
        let pts = vec![(now - 400_000, 5 * g), (now - 300_000, 0), (now - 150_000, 10 * g), (now, 30 * g)];
        let d = curve(&pts, Some(19 * g), rect, now, 300_000, DARK.terminal_background, &DARK);
        let Draw::Stroke { points: line, dash: None, .. } = &d[1] else { panic!("{d:?}") };
        // The one older than five minutes is not drawn; the others run from
        // the left edge to the right, over the scale's top clipped to it.
        assert_eq!(line.len(), 3);
        assert_eq!((line[0].0, line[2].0), (0.0, 96.0));
        assert_eq!(line[1].0, 48.0);
        assert_eq!(line[0].1, 27.0, "zero at the bottom less a point");
        assert_eq!(line[2].1, 1.0, "past the top drawn at the top");
        let Draw::Stroke { points: kl, dash: Some(dash), .. } = &d[2] else { panic!() };
        assert_eq!(*dash, (c::CURVE_DASH, c::CURVE_GAP));
        assert!((kl[0].1 - (27.0 - 26.0 / 1.08)).abs() < 1e-9);
        // No kill line: no dashes, and the scale is the highest point's.
        let d = curve(&pts, None, rect, now, 300_000, DARK.terminal_background, &DARK);
        assert_eq!(d.iter().filter(|x| matches!(x, Draw::Stroke { dash: Some(_), .. })).count(), 0);
        // One point is not a line.
        assert!(curve(&pts[3..], None, rect, now, 300_000, DARK.terminal_background, &DARK).is_empty());
    }

    #[test]
    fn every_word_drawn_is_the_cores_and_nothing_is_set_below_the_body_size() {
        let (r, at) = page(1040.0);
        let c = Curves::default();
        let d = build(&r, &c, &at, &DARK, 1.0, Some((3, 46)), &nominal);
        let mut said = Vec::new();
        for i in items(&d) {
            match i {
                Item::Text { text, style, .. } => {
                    assert!(style.size >= font::BODY, "{text}");
                    said.push(text.clone());
                }
                Item::Line { parts, .. } => {
                    for p in parts {
                        if let Piece::Words { text, style } = &p.piece {
                            assert!(style.size >= font::BODY, "{text}");
                            said.push(text.clone());
                        }
                    }
                }
                _ => {}
            }
        }
        let json = DAY;
        for s in &said {
            assert!(json.contains(&format!("\"{s}\"")), "{s:?} is not in the core's answer");
        }
        assert!(said.iter().any(|s| s == "03:14  ocr-mask 被中断"), "the tip is drawn");
    }

    /// The legend stands at the heading's right end: each swatch
    /// `LEGEND_GAP` before its words, `LABEL_GAP` between one entry and the
    /// next, the last words ending at the end.
    #[test]
    fn the_legend_is_at_the_headings_right_swatch_then_words() {
        let (r, at) = page(1040.0);
        let d = build(&r, &Curves::default(), &at, &DARK, 1.0, None, &nominal);
        let swatches: Vec<Rect> = items(&d)
            .into_iter()
            .filter_map(|i| match i {
                Item::Round { rect, .. } if rect.w == g::LEGEND_SWATCH => Some(*rect),
                _ => None,
            })
            .collect();
        let texts: Vec<(Rect, &str)> = r
            .grid
            .legend
            .iter()
            .filter_map(|(_, w)| items(&d).into_iter().find_map(|i| match i {
                Item::Text { rect, text, .. } if text == w => Some((*rect, w.as_str())),
                _ => None,
            }))
            .collect();
        assert_eq!((swatches.len(), texts.len()), (5, 5));
        // Drawn right to left: swatches[0] is the last entry's.
        let mut sw = swatches.clone();
        sw.reverse();
        for (k, ((t, _), s)) in texts.iter().zip(&sw).enumerate() {
            assert_eq!(s.x + s.w + g::LEGEND_GAP, t.x, "entry {k}");
            if k + 1 < texts.len() {
                assert_eq!(t.x + t.w + g::LABEL_GAP, sw[k + 1].x, "entry {k} to the next");
            }
        }
        let (last, _) = texts[4];
        assert_eq!(last.x + last.w, at.grid_head.x + at.grid_head.w);
    }

    /// Before Q2 the foot's right is an empty string (API.md §2.1): nothing
    /// empty reaches the host, which would hand it to `DrawTextW`.
    #[test]
    fn an_empty_string_from_the_core_is_not_handed_on() {
        let mut r = decode(DAY).unwrap();
        for c in &mut r.cards {
            c.foot.1 = String::new();
        }
        r.machine.swap = Some(String::new());
        let at = layout(&r, 1040.0, 0.0, &DARK, &nominal);
        let d = build(&r, &Curves::default(), &at, &DARK, 1.0, None, &nominal);
        for i in items(&d) {
            match i {
                Item::Text { text, .. } => assert!(!text.is_empty()),
                Item::Line { parts, .. } => {
                    assert!(!parts.is_empty());
                    for p in parts {
                        assert!(!matches!(&p.piece, Piece::Words { text, .. } if text.is_empty()));
                    }
                }
                _ => {}
            }
        }
    }
}
