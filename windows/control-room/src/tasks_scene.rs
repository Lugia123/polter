//! The task page, laid out and drawn (task 2015, Q10; the design's v9
//! `main-tasks`, without its Stats and Files tabs): the group's goal, the
//! columns' heading, the open tasks -- the one open lifted on a pane of
//! glass with its wording, its history and what the group said of it -- the
//! closed ones folded under a line, and the keys at the bottom.
//!
//! The same shape as `perf_scene`: a list of `Draw`s a host paints, from
//! the core's words (`tasks`) and the host's measurements. Lengths are
//! points from the page's top left, the page scrolled up by `scroll`; the
//! keys at the bottom stay where they are, on a strip of their own that the
//! list ends above (#2083).

use crate::layout::{self, Rect};
use crate::look::{font, radius, side, task_page as k, task_symbol, Rgba, Theme};
use crate::perf_scene::{Draw, Measure};
use crate::scene::{self, Align, Face, Item, Part, Piece, Side, Style};
use crate::tasks::{Detail, Glyph, Hint, LogLine, Task, Tasks};

/// A task's line on the page.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskAt {
    pub id: u64,
    pub rect: Rect,
    pub closed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub width: f64,
    pub goal: Rect,
    /// The goal's rows as drawn, at most `GOAL_ROWS` (`goal_rows`).
    pub goal_rows: Vec<String>,
    /// The filter box under the goal, when there is one (#2083).
    pub filter: Option<FilterAt>,
    /// Where the list is seen: under the goal (and the filter box), over
    /// the keys' strip. What scrolls is drawn, and pressed, only in here.
    pub viewport: Rect,
    pub head: Rect,
    /// What says nothing matched (#2083), under the heading.
    pub no_match: Option<Rect>,
    pub tasks: Vec<TaskAt>,
    /// The closed tasks' line: pressing it opens or folds them. None when
    /// the core gave no such line.
    pub section: Option<Rect>,
    /// The glass round the open task and its detail; none when none is open.
    pub glass: Option<Rect>,
    /// What the detail draws, worked out here because how tall it is
    /// depends on how its words wrap.
    pub detail: Vec<Draw>,
    /// The keys' strip, the page's width at its bottom: **its own room, not
    /// over the list** (#2083, plan A; the user on 0.11.2217: the keys lay
    /// over the tasks).
    pub strip: Rect,
    /// The key kept at the strip's right: pressing it does what c does.
    pub hint_closed: Option<Rect>,
    /// How tall what scrolls is, all of it.
    pub content_height: f64,
}

/// The filter box's parts (#2083): its outline, where what is typed goes
/// -- the host's own text control is put there -- what it found, at its
/// right inside it, and the key that clears it, after it.
#[derive(Debug, Clone, PartialEq)]
pub struct FilterAt {
    pub field: Rect,
    pub typed: Rect,
    pub count: Option<Rect>,
    pub clear: Rect,
}

/// What the pointer is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hover {
    Task(u64),
    /// The closed tasks' line.
    Closed,
}

impl Layout {
    pub fn max_scroll(&self) -> f64 {
        (self.content_height - self.viewport.h).max(0.0)
    }

    /// How far to scroll, from `scroll`, for task `id`'s line to be in sight
    /// **with a line's room past it** (#2083: ↑↓ ran off the page's edge and
    /// the list stayed where it was; the design keeps the next line in
    /// sight): by as little as it takes, and not at all when that is so
    /// already or the task is not on the page.
    pub fn follow(&self, id: u64, scroll: f64) -> f64 {
        let Some(t) = self.tasks.iter().find(|t| t.id == id) else { return scroll };
        let (top, bottom) = (self.viewport.y + k::ROW_HEIGHT, self.viewport.y + self.viewport.h - k::ROW_HEIGHT);
        let to = if t.rect.y < top {
            scroll - (top - t.rect.y)
        } else if t.rect.y + t.rect.h > bottom {
            scroll + (t.rect.y + t.rect.h - bottom)
        } else {
            scroll
        };
        to.clamp(0.0, self.max_scroll())
    }

    /// Where the list goes for the selected task `id` to be brought back
    /// into sight (Esc, the words changed, another selected by them):
    /// **the open one's line at the top**, its detail under it (group seq
    /// 35, as the mac host does; round 7d, 3: Windows only just brought its
    /// line in at the bottom, the detail out of sight); any other as
    /// `follow` does, a line's room either side.
    pub fn reveal(&self, id: u64, scroll: f64) -> f64 {
        let Some(t) = self.tasks.iter().find(|t| t.id == id) else { return scroll };
        if self.glass.is_some_and(|g| g.y == t.rect.y) {
            // A line of room over it, as any other has (task 2124: at the
            // top it was 16 points under the fade).
            return (scroll + t.rect.y - self.viewport.y - k::ROW_HEIGHT).clamp(0.0, self.max_scroll());
        }
        self.follow(id, scroll)
    }

    fn in_list(&self, y: f64) -> bool {
        y >= self.viewport.y && y < self.viewport.y + self.viewport.h
    }

    /// The task whose line is under `(x, y)`; none outside the viewport.
    pub fn task_at(&self, x: f64, y: f64) -> Option<u64> {
        if !self.in_list(y) {
            return None;
        }
        self.tasks.iter().find(|t| inside(t.rect, x, y)).map(|t| t.id)
    }

    pub fn on_section(&self, x: f64, y: f64) -> bool {
        self.in_list(y) && self.section.is_some_and(|s| inside(s, x, y))
    }

    /// What the pointer at `(x, y)` is on.
    pub fn hover_at(&self, x: f64, y: f64) -> Option<Hover> {
        if self.on_section(x, y) {
            return Some(Hover::Closed);
        }
        self.task_at(x, y).map(Hover::Task)
    }

    /// On the strip's right-hand key.
    pub fn on_hint_closed(&self, x: f64, y: f64) -> bool {
        self.hint_closed.is_some_and(|r| inside(r, x, y))
    }

    /// On the key beside the filter box that clears it.
    pub fn on_clear(&self, x: f64, y: f64) -> bool {
        self.filter.as_ref().is_some_and(|f| inside(f.clear, x, y))
    }
}

fn inside(r: Rect, x: f64, y: f64) -> bool {
    x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

fn l3(color: Rgba) -> Style {
    Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color }
}

fn mono(color: Rgba) -> Style {
    Style { face: Face::Mono, ..l3(color) }
}

fn strong(style: Style) -> Style {
    Style { weight: font::WEIGHT_EMPHASIS, ..style }
}

fn words(text: &str, style: Style, side: Side, gap: f64) -> Part {
    Part { piece: Piece::Words { text: text.to_string(), style }, side, gap }
}

/// `text` broken into lines `width` wide in `style`: at its own line ends
/// first, then where the words run out of room (`layout::wrap`).
/// The most rows the goal takes: the chat's brief takes as many (`briefRows`
/// in chat.zig, #2043), and the mac host's `ControlRoomTasks.goalRows` too.
pub const GOAL_ROWS: usize = 2;

/// The goal's rows `width` wide: each of the core's lines wrapped on its own
/// (#2060: the lines run together read "…工具条- api: …"), the empty ones
/// skipped, and no more than `GOAL_ROWS` in all -- a first line that wraps
/// to two leaves no room for the second. What does not fit is not drawn:
/// the group's brief is in the chat and in the list's row, whole.
pub fn goal_rows(lines: &[String], style: &Style, width: f64, measure: Measure) -> Vec<String> {
    // The goal's text lines as drawn -- not the list's rows.
    let mut shown = Vec::new();
    for line in lines {
        if shown.len() >= GOAL_ROWS {
            break;
        }
        if line.trim().is_empty() {
            continue;
        }
        shown.extend(wrapped(line, style, width, measure));
    }
    shown.truncate(GOAL_ROWS);
    shown
}

pub fn wrapped(text: &str, style: &Style, width: f64, measure: Measure) -> Vec<String> {
    let fits = |s: &str| -> usize {
        // The most characters from the start that fit: found by halving.
        let chars: Vec<(usize, char)> = s.char_indices().collect();
        let (mut lo, mut hi) = (0usize, chars.len());
        while lo < hi {
            let mid = (lo + hi).div_ceil(2);
            let end = chars.get(mid).map_or(s.len(), |(at, _)| *at);
            if measure(&s[..end], style) <= width {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        lo
    };
    let pushed = |s: &str| break_before(s, fits(s));
    text.split('\n').flat_map(|para| layout::wrap(para, &pushed)).collect()
}

/// What may not begin a line (Chinese and Japanese line breaking, 避头): a
/// full stop, a comma, a closing bracket and their kin.
pub fn closes(c: char) -> bool {
    "。，、．：；！？）」』】〉》〕｝…—”’%,.;:!?)]}".contains(c)
}

/// Where a line of `s` ends when `n` characters fit: there, unless the next
/// line would begin with what may not begin one (group seq 223: 0x4881
/// found a 。 alone at the start of a line) -- then earlier, so that **the
/// character before goes down with it** (推出, group seq 276). W5 hung the
/// mark on the line before instead, and that line, a character too wide,
/// was cut to an ellipsis. A line cannot be pushed out to nothing: when
/// every character but the first would have to go, it ends at `n` after
/// all.
pub fn break_before(s: &str, n: usize) -> usize {
    let chars: Vec<char> = s.chars().collect();
    if n == 0 || n >= chars.len() {
        return n;
    }
    let mut k = n;
    while k > 1 && closes(chars[k]) {
        k -= 1;
    }
    if closes(chars[k]) { n } else { k }
}

/// A press on task `id`: it is selected, and opened -- or shut, when it is
/// the open one. `(selected, open)`.
pub fn after_press(id: u64, open: Option<u64>) -> (Option<u64>, Option<u64>) {
    (Some(id), if open == Some(id) { None } else { Some(id) })
}

/// Enter with `selected` (or, with none, `first`) and `open`: the selected
/// one opened when it is not the open one -- the open one, if another, shut
/// by that -- and shut when it is. ↑↓ move only the selection. **The
/// selection and the open one are two things** (group seq 290, the mac
/// host's reading; this host had the same one flag): with one flag for "the
/// selected one is open", ↓ carried the opening to the next task and Enter
/// then shut it. The mac host's `ControlRoomTasks.afterReturn`.
pub fn after_return(selected: Option<u64>, open: Option<u64>, first: Option<u64>) -> (Option<u64>, Option<u64>) {
    match selected.or(first) {
        None => (None, open),
        Some(s) => (Some(s), if open == Some(s) { None } else { Some(s) }),
    }
}

/// The columns of a task's line inside `row`: glyph, id, state, title,
/// owner, idle. **Narrow, the idle column goes** (#2083): when the title
/// would be narrower than `title_min`, the idle column is 0 wide -- not
/// drawn -- and the owner takes `col_owner_narrow`. The mac host's
/// `ControlRoomTasks.columns`.
pub fn columns(row: Rect) -> [Rect; 6] {
    let x0 = row.x + k::ROW_PAD_X;
    let right = row.x + row.w - k::ROW_PAD_X;
    let col = |x: f64, w: f64| Rect { x, y: row.y, w: w.max(0.0), h: row.h };
    let glyph = col(x0, k::COL_GLYPH);
    let id = col(glyph.x + glyph.w, k::COL_ID);
    // **The title keeps `title_min`; the other columns give way for it**
    // (task 2124: at a page 388 wide the title was 30 wide, the state and
    // the owner having all they asked): the idle column first, then the
    // owner, then the state -- the first of these that leaves the title its
    // room, and the last when none does.
    let room = right - (id.x + id.w);
    let tiers = [(k::COL_STATE, k::COL_OWNER, k::COL_IDLE), (k::COL_STATE, k::COL_OWNER_NARROW, 0.0), (k::COL_STATE, 0.0, 0.0), (0.0, 0.0, 0.0)];
    let (state_w, owner_w, idle_w) = tiers.iter().copied().find(|(s, o, i)| room - s - o - i >= k::TITLE_MIN).unwrap_or(tiers[3]);
    let state = col(id.x + id.w, state_w);
    let idle = col(right - idle_w, idle_w);
    let owner = col(idle.x - owner_w, owner_w);
    let title = col(state.x + state.w, owner.x - (state.x + state.w));
    [glyph, id, state, title, owner, idle]
}

/// The column labels' small heading at `at`, `w` wide: its words, and a
/// rule from after them to the end.
fn label(text: &str, at: (f64, f64), w: f64, theme: &Theme, scale: f64, measure: Measure) -> Vec<Draw> {
    let style = l3(theme.text_secondary);
    let tw = measure(text, &style);
    let (hair, amount) = scene::hairline(scale);
    let rule_x = at.0 + tw + k::HEADING_RULE_GAP;
    let mut out = vec![Draw::Item(Item::Text { rect: Rect { x: at.0, y: at.1, w: tw, h: k::HEADING_HEIGHT }, text: text.to_string(), style, align: Align::Left })];
    if rule_x < at.0 + w {
        out.push(Draw::Item(Item::Fill {
            rect: Rect { x: rule_x, y: at.1 + k::HEADING_HEIGHT / 2.0, w: at.0 + w - rule_x, h: hair },
            color: scene::over(theme.terminal_background, theme.stack_tab_separator, amount),
        }));
    }
    out
}

/// What the open task shows under its line, from `(x0, y0)` in a space
/// `w` wide; and how tall it is.
pub fn detail(d: &Detail, x0: f64, y0: f64, w: f64, theme: &Theme, scale: f64, measure: Measure) -> (Vec<Draw>, f64) {
    let mut out = Vec::new();
    let left_w = k::DETAIL_LEFT_WIDTH.min(((w - k::DETAIL_COLUMN_GAP) / 2.0).max(0.0)).max(0.0);
    let right_x = x0 + left_w + k::DETAIL_COLUMN_GAP;
    let right_w = (x0 + w - right_x).max(0.0);
    let body = l3(theme.text);

    // Left: the wording, then the history.
    let mut y = y0;
    out.extend(label(&d.body_title, (x0, y), left_w, theme, scale, measure));
    y += k::HEADING_HEIGHT;
    for line in wrapped(&d.body, &body, left_w, measure) {
        if scene::draws(&line) {
            out.push(Draw::Item(Item::Text { rect: Rect { x: x0, y, w: left_w, h: k::BODY_LINE_HEIGHT }, text: line, style: body, align: Align::Left }));
        }
        y += k::BODY_LINE_HEIGHT;
    }
    y += k::BODY_BOTTOM;
    out.extend(label(&d.log_title, (x0, y), left_w, theme, scale, measure));
    y += k::HEADING_HEIGHT;
    let rail_x = x0 + k::LOG_TIME + k::LOG_TRACK_X;
    let rail_color = scene::over(theme.terminal_background, theme.text_tertiary, 0.6);
    let n = d.log.len();
    for (i, l) in d.log.iter().enumerate() {
        match l {
            LogLine::Event { at, who, text, last } => {
                let h = k::LOG_ROW;
                // The rail runs through every line, from the first dot down
                // to the last.
                let top = if i == 0 { y + h / 2.0 } else { y };
                let bottom = if i + 1 == n { y + h / 2.0 } else { y + h };
                out.push(Draw::Stroke { points: vec![(rail_x, top), (rail_x, bottom)], width: 0.5, color: rail_color, dash: None });
                let dot = Rect { x: rail_x - k::LOG_DOT / 2.0, y: y + k::LOG_DOT_TOP, w: k::LOG_DOT, h: k::LOG_DOT };
                let (fill, edge) = if *last { (theme.text, None) } else { (theme.terminal_background, Some(theme.text_secondary)) };
                out.push(Draw::Item(Item::Round { rect: dot, radius: k::LOG_DOT / 2.0, color: fill, edge }));
                let row = |cx: f64, cw: f64| Rect { x: cx, y, w: cw, h };
                if let Some(at) = at {
                    out.push(Draw::Item(Item::Text { rect: row(x0, k::LOG_TIME), text: at.clone(), style: mono(theme.text_secondary), align: Align::Left }));
                }
                let who_x = x0 + k::LOG_TIME + k::LOG_TRACK;
                if let Some(who) = who {
                    out.push(Draw::Item(Item::Text { rect: row(who_x, k::LOG_WHO), text: who.clone(), style: mono(theme.text_secondary), align: Align::Left }));
                }
                let text_x = who_x + k::LOG_WHO;
                out.push(Draw::Item(Item::Text { rect: row(text_x, (x0 + left_w - text_x).max(0.0)), text: text.clone(), style: body, align: Align::Left }));
                y += h;
            }
            LogLine::Gap { text } => {
                let h = k::LOG_GAP_ROW;
                out.push(Draw::Stroke { points: vec![(rail_x, y), (rail_x, y + h)], width: 0.5, color: rail_color, dash: Some((k::GAP_DASH, k::GAP_DASH_GAP)) });
                let who_x = x0 + k::LOG_TIME + k::LOG_TRACK;
                out.push(Draw::Item(Item::Text { rect: Rect { x: who_x, y, w: (x0 + left_w - who_x).max(0.0), h }, text: text.clone(), style: l3(theme.text_secondary), align: Align::Left }));
                y += h;
            }
        }
    }
    let left_h = y - y0;

    // Right: what the group said of it, newest last.
    let mut y = y0;
    out.extend(label(&d.said_title, (right_x, y), right_w, theme, scale, measure));
    y += k::HEADING_HEIGHT;
    for s in &d.said {
        out.push(Draw::Item(Item::Line {
            rect: Rect { x: right_x, y, w: right_w, h: k::BODY_LINE_HEIGHT },
            parts: vec![words(&s.at, mono(theme.text_secondary), Side::Lead, 0.0), words(&s.who, strong(mono(theme.text)), Side::Lead, k::SAID_HEAD_GAP)],
        }));
        y += k::BODY_LINE_HEIGHT;
        for line in wrapped(&s.text, &body, right_w, measure) {
            if scene::draws(&line) {
                out.push(Draw::Item(Item::Text { rect: Rect { x: right_x, y, w: right_w, h: k::BODY_LINE_HEIGHT }, text: line, style: body, align: Align::Left }));
            }
            y += k::BODY_LINE_HEIGHT;
        }
        y += k::SAID_BOTTOM;
    }
    let right_h = y - y0;
    (out, left_h.max(right_h))
}

/// `t`'s page `width` by `height`, its list scrolled up by `scroll`: the
/// goal and the filter box at the top, then the list's viewport, then the
/// keys' strip (#2083).
#[allow(clippy::too_many_arguments)]
pub fn layout(t: &Tasks, width: f64, height: f64, scroll: f64, theme: &Theme, scale: f64, measure: Measure) -> Layout {
    let x0 = k::PAD_X;
    let inner = (width - 2.0 * k::PAD_X).max(0.0);
    // A row more than one makes the goal a line taller each.
    let goal_shown = goal_rows(&t.goal_lines, &l3(theme.text_secondary), inner, measure);
    let goal_h = k::GOAL_HEIGHT + goal_shown.len().saturating_sub(1) as f64 * k::BODY_LINE_HEIGHT;
    let goal = Rect { x: x0, y: 0.0, w: inner, h: goal_h };
    let mut top = goal_h;
    let filter = t.filter.as_ref().map(|f| {
        let y = top + k::FILTER_TOP;
        top = y + k::ROW_HEIGHT + k::FILTER_BOTTOM;
        let clear_w = keyed_width(&f.clear, theme, measure);
        let clear = Rect { x: x0 + inner - clear_w, y, w: clear_w, h: k::ROW_HEIGHT };
        let field = Rect { x: x0, y, w: (clear.x - k::FILTER_GAP - x0).max(0.0), h: k::ROW_HEIGHT };
        let count = f.count.as_ref().map(|c| {
            let w = measure(c, &l3(theme.text_secondary));
            Rect { x: field.x + field.w - k::FILTER_PAD_X - w, y, w, h: k::ROW_HEIGHT }
        });
        let typed_right = count.map_or(field.x + field.w - k::FILTER_PAD_X, |c| c.x - k::FILTER_GAP);
        let typed = Rect { x: field.x + k::FILTER_PAD_X, y: y + (k::ROW_HEIGHT - k::BODY_LINE_HEIGHT) / 2.0, w: (typed_right - field.x - k::FILTER_PAD_X).max(0.0), h: k::BODY_LINE_HEIGHT };
        FilterAt { field, typed, count, clear }
    });
    let strip = Rect { x: 0.0, y: (height - k::BAR_HEIGHT).max(top), w: width, h: k::BAR_HEIGHT };
    let viewport = Rect { x: 0.0, y: top, w: width, h: (strip.y - top).max(0.0) };

    let mut y = top - scroll;
    let head = Rect { x: x0, y, w: inner, h: k::ROW_HEIGHT };
    y += k::ROW_HEIGHT;
    let no_match = t.no_match.as_ref().map(|_| {
        let r = Rect { x: x0, y: y + k::NO_MATCH_TOP, w: inner, h: 2.0 * k::BODY_LINE_HEIGHT + k::NO_MATCH_GAP };
        y = r.y + r.h;
        r
    });
    let mut tasks = Vec::new();
    let mut glass = None;
    let mut drawn = Vec::new();
    for task in &t.open {
        let open = task.detail.as_ref();
        if open.is_some() {
            y += k::DETAIL_MARGIN_Y;
        }
        let rect = Rect { x: x0, y, w: inner, h: k::ROW_HEIGHT };
        tasks.push(TaskAt { id: task.id, rect, closed: false });
        y += k::ROW_HEIGHT;
        if let Some(d) = open {
            let (draws, h) = detail(
                d,
                x0 + k::DETAIL_PAD_LEFT,
                y + k::DETAIL_PAD_TOP,
                (inner - k::DETAIL_PAD_LEFT - k::DETAIL_PAD_RIGHT).max(0.0),
                theme,
                scale,
                measure,
            );
            drawn = draws;
            y += k::DETAIL_PAD_TOP + h + k::DETAIL_PAD_BOTTOM;
            glass = Some(Rect { x: x0, y: rect.y, w: inner, h: y - rect.y });
            y += k::DETAIL_MARGIN_Y;
        }
    }
    let section = t.closed_title.as_ref().map(|_| {
        y += k::CLOSED_TOP;
        let r = Rect { x: x0, y, w: inner, h: k::ROW_HEIGHT };
        y += k::ROW_HEIGHT;
        r
    });
    for task in &t.closed {
        tasks.push(TaskAt { id: task.id, rect: Rect { x: x0, y, w: inner, h: k::ROW_HEIGHT }, closed: true });
        y += k::ROW_HEIGHT;
    }
    let content_height = y + scroll - top;
    let hint_closed = t.hint_closed.as_ref().map(|h| {
        let w = keyed_width(h, theme, measure);
        Rect { x: width - k::BAR_PAD_X - w, y: strip.y, w, h: strip.h }
    });
    Layout { width, goal, goal_rows: goal_shown, filter, viewport, head, no_match, tasks, section, glass, detail: drawn, strip, hint_closed, content_height }
}

fn key_style(theme: &Theme) -> Style {
    Style { size: k::KEY_FONT_WINDOWS, ..mono(theme.text) }
}

/// A key in its cap and what it does: how wide.
fn keyed_width(h: &Hint, theme: &Theme, measure: Measure) -> f64 {
    measure(&h.0, &key_style(theme)) + 2.0 * k::KEY_PAD_X + k::KEY_GAP + measure(&h.1, &l3(theme.text_secondary))
}

/// A key in its cap at `x`, in the middle of `row`, and what it does in
/// `words`.
fn keyed(h: &Hint, x: f64, row: Rect, words: Rgba, theme: &Theme, measure: Measure) -> Vec<Draw> {
    let kw = measure(&h.0, &key_style(theme)) + 2.0 * k::KEY_PAD_X;
    let cap = Rect { x, y: row.y + (row.h - k::KEY_HEIGHT) / 2.0, w: kw, h: k::KEY_HEIGHT };
    let ww = measure(&h.1, &l3(words));
    vec![
        Draw::Item(Item::Round { rect: cap, radius: k::KEY_RADIUS, color: scene::over(theme.terminal_background, theme.perf_card_edge, 1.0), edge: None }),
        Draw::Item(Item::Text { rect: cap, text: h.0.clone(), style: key_style(theme), align: Align::Centre }),
        Draw::Item(Item::Text { rect: Rect { x: x + kw + k::KEY_GAP, w: ww, ..row }, text: h.1.clone(), style: l3(words), align: Align::Left }),
    ]
}

/// A state's symbol and colour, from the look (`strings.task_symbol`,
/// `colors.task_<state>`): the same data the macOS host draws by.
pub fn symbol_of(g: Glyph, theme: &Theme) -> (&'static str, Rgba) {
    match g {
        Glyph::Queued => (task_symbol::QUEUED, theme.task_queued),
        Glyph::Working => (task_symbol::WORKING, theme.task_working),
        Glyph::Blocked => (task_symbol::BLOCKED, theme.task_blocked),
        Glyph::Done => (task_symbol::DONE, theme.task_done),
        Glyph::Closed => (task_symbol::CLOSED, theme.task_closed),
        Glyph::Cancelled => (task_symbol::CANCELLED, theme.task_cancelled),
    }
}

/// The symbol the look names, in a box `side::GLYPH` square about `c`,
/// drawn as the system symbol of that name is on macOS: `circle` a ring;
/// `clock` a ring with a clock's hands; `minus.circle`, `checkmark.circle`
/// and `xmark.circle` a ring with a bar, a tick, a cross; `checkmark` a
/// tick alone. A name this build cannot draw draws nothing
/// (`every_symbol_the_look_names_is_drawn` holds the look to these).
pub fn symbol(name: &str, c: (f64, f64), color: Rgba) -> Vec<Draw> {
    let r = side::GLYPH / 2.0 - 1.5;
    let w = k::GLYPH_STROKE;
    let stroke = |pts: Vec<(f64, f64)>| Draw::Stroke { points: pts.into_iter().map(|(dx, dy)| (c.0 + dx, c.1 + dy)).collect(), width: w, color, dash: None };
    let tick = |s: f64| stroke(vec![(-0.55 * s, 0.0), (-0.15 * s, 0.4 * s), (0.6 * s, -0.4 * s)]);
    let (ringed, inner) = match name.strip_suffix(".circle") {
        Some(inner) => (true, inner),
        None if name == "circle" || name == "clock" => (true, name),
        None => (false, name),
    };
    let mut out = Vec::new();
    if ringed {
        out.push(Draw::Arc { centre: c, radius: r, from: 0.0, sweep: 360.0, width: w, color });
    }
    match inner {
        "circle" => {}
        "clock" => out.push(stroke(vec![(0.0, -0.55 * r), (0.0, 0.0), (0.45 * r, 0.3 * r)])),
        "minus" => out.push(stroke(vec![(-0.5 * r, 0.0), (0.5 * r, 0.0)])),
        "checkmark" => out.push(tick(if ringed { 0.75 * r } else { r })),
        "xmark" => {
            out.push(stroke(vec![(-0.4 * r, -0.4 * r), (0.4 * r, 0.4 * r)]));
            out.push(stroke(vec![(0.4 * r, -0.4 * r), (-0.4 * r, 0.4 * r)]));
        }
        _ => return Vec::new(),
    }
    out
}

/// One task's line in `row`: glyph, id, state, title, owner, idle; bold
/// when it is the open one, faint when it is closed.
fn task_line(task: &Task, row: Rect, closed: bool, on_chip: Option<Rgba>, theme: &Theme, measure: Measure) -> Vec<Draw> {
    let [g, id, state, title, owner, idle] = columns(row);
    let (main, side) = if closed { (theme.text_tertiary, theme.text_tertiary) } else if task.emph { (theme.text, theme.text) } else { (theme.text, theme.text_secondary) };
    let w = |s: Style| if task.emph { strong(s) } else { s };
    // In the middle of its column (0x4881, group seq 221: it stood at the
    // column's left, 37–49 in a column 36–62); none when the core named no
    // glyph this build knows (`tasks::task`).
    let mut out = match task.glyph {
        Some(glyph) => {
            let (name, color) = symbol_of(glyph, theme);
            symbol(name, (g.x + g.w / 2.0, g.y + g.h / 2.0), color)
        }
        None => Vec::new(),
    };
    let text = |rect: Rect, t: String, style: Style, align: Align| Draw::Item(Item::Text { rect, text: t, style, align });
    out.push(text(id, format!("#{}", task.id), w(mono(side)), Align::Left));
    // Not drawn when the page is too narrow for it (`columns`).
    if state.w > 0.0 {
        out.push(text(state, task.state.clone(), w(l3(main)), Align::Left));
    }
    match &task.title_parts {
        Some(parts) => out.extend(title_pieces(parts, title, w(l3(main)), on_chip, theme, measure)),
        None => out.push(text(title, task.title.clone(), w(l3(main)), Align::Left)),
    }
    if owner.w > 0.0 {
        out.push(text(owner, task.owner.clone(), w(mono(side)), Align::Left));
    }
    // None when the page is too narrow for it (`columns`).
    if idle.w > 0.0 {
        out.push(text(idle, task.idle.clone(), w(l3(side)), Align::Right));
    }
    out
}

/// A title in the core's pieces (#2083): one after another from the
/// column's left, those the filter found bold on a ground of their own;
/// the one that reaches the column's end cut there, and none after it.
fn title_pieces(parts: &[(String, bool)], col: Rect, style: Style, on_chip: Option<Rgba>, theme: &Theme, measure: Measure) -> Vec<Draw> {
    let mut out = Vec::new();
    let mut x = col.x;
    let end = col.x + col.w;
    for (words, hit) in parts {
        if x >= end {
            break;
        }
        let mut style = if *hit { strong(style) } else { style };
        let w = measure(words, &style).min(end - x);
        let rect = Rect { x, w, ..col };
        if *hit {
            let ground = Rect { x, y: col.y + (col.h - k::BODY_LINE_HEIGHT) / 2.0, w, h: k::BODY_LINE_HEIGHT };
            // **On the chip it is turned over** (task 2124: `task_hit` is
            // the chip's own colour, and only the bold was left of it): the
            // main text colour for the ground and the chip's for the words,
            // which is 15:1 in light and 9:1 in dark, and holds for either
            // since no one ground clears 3:1 to the chip and 4.5:1 to the
            // words in dark at once.
            let color = if let Some(chip) = on_chip {
                style.color = chip;
                theme.text
            } else {
                theme.task_hit
            };
            out.push(Draw::Item(Item::Round { rect: ground, radius: k::HIT_RADIUS, color, edge: None }));
        }
        out.push(Draw::Item(Item::Text { rect, text: words.clone(), style, align: Align::Left }));
        x += w;
    }
    out
}

const WHITE: Rgba = Rgba { r: 255, g: 255, b: 255, a: 1.0 };

/// What the chip is made of over `ground`: the group list's tint of white
/// with the keyboard here, the ground itself without it.
pub fn chip_colour(ground: Rgba, theme: &Theme, keys: bool) -> Rgba {
    if keys { scene::over(ground, WHITE, theme.selection_tint) } else { ground }
}

/// The arrow keys' task (#2083, plan S2): the group list's chip -- its
/// shadow first, lifted while the pointer is on it -- and a bar at its left
/// in the main text colour, since the chip alone is all but white on white
/// (1.01 to the page, the design's reading); with the keyboard elsewhere,
/// an outline and the bar. **Never a grey ground.**
pub fn chip(rect: Rect, ground: Rgba, theme: &Theme, keys: bool, lifted: bool) -> Vec<Draw> {
    const BLACK: Rgba = Rgba { r: 0, g: 0, b: 0, a: 1.0 };
    let mut out = Vec::new();
    if keys {
        out.extend(
            crate::tabstrip::shadow(rect, radius::ROW, ground, theme, if lifted { 1.0 } else { 0.0 }, 1.0)
                .into_iter()
                .map(|(rect, radius, color)| Draw::Item(Item::Round { rect, radius, color, edge: None })),
        );
        let color = chip_colour(ground, theme, keys);
        let toward = if theme.selection_edge < 0.0 { BLACK } else { WHITE };
        out.push(Draw::Item(Item::Round { rect, radius: radius::ROW, color, edge: Some(scene::over(color, toward, theme.selection_edge.abs())) }));
    } else {
        out.push(Draw::Item(Item::Round { rect, radius: radius::ROW, color: ground, edge: Some(scene::over(ground, theme.line, 1.0)) }));
    }
    let bar = Rect { x: rect.x + k::MARK_X, y: rect.y + k::MARK_INSET_Y, w: k::MARK_WIDTH, h: (rect.h - 2.0 * k::MARK_INSET_Y).max(0.0) };
    out.push(Draw::Item(Item::Round { rect: bar, radius: k::MARK_RADIUS, color: theme.text, edge: None }));
    out
}

/// Under the pointer and not the arrow keys' task: a faint flat ground,
/// the window tabs' hover -- no edge and no shadow, so it is never read as
/// the chip (#2083).
pub fn hover_ground(rect: Rect, ground: Rgba, theme: &Theme) -> Draw {
    Draw::Item(Item::Round { rect, radius: radius::ROW, color: scene::over(ground, theme.window_tab_hover, 1.0), edge: None })
}

/// The page under `at`. `selected` is the task the arrow keys are on;
/// `keys` whether the page (or its filter box) has the keyboard; `hover`
/// what the pointer is on.
#[allow(clippy::too_many_arguments)]
pub fn build(t: &Tasks, at: &Layout, theme: &Theme, scale: f64, selected: Option<u64>, keys: bool, hover: Option<Hover>, measure: Measure) -> Vec<Draw> {
    let ground = theme.terminal_background;
    let (hair, amount) = scene::hairline(scale);
    let rule = scene::over(ground, theme.stack_tab_separator, amount);
    let mut out = Vec::new();
    // The goal's rows, a line each, in the middle of the goal's height.
    let pad = (k::GOAL_HEIGHT - k::BODY_LINE_HEIGHT) / 2.0;
    for (i, row) in at.goal_rows.iter().enumerate() {
        let rect = Rect { y: at.goal.y + pad + i as f64 * k::BODY_LINE_HEIGHT, h: k::BODY_LINE_HEIGHT, ..at.goal };
        out.push(Draw::Item(Item::Text { rect, text: row.clone(), style: l3(theme.text_secondary), align: Align::Left }));
    }
    // The filter box: its outline as the group list's name field has it;
    // what is typed is the host's own control, at `typed`.
    if let (Some(f), Some(fa)) = (t.filter.as_ref(), at.filter.as_ref()) {
        out.push(Draw::Item(Item::Round { rect: fa.field, radius: radius::ROW, color: ground, edge: Some(theme.attention_text) }));
        if let (Some(c), Some(r)) = (f.count.as_ref(), fa.count) {
            out.push(Draw::Item(Item::Text { rect: r, text: c.clone(), style: l3(theme.text_secondary), align: Align::Right }));
        }
        out.extend(keyed(&f.clear, fa.clear.x, fa.clear, theme.text_secondary, theme, measure));
    }

    // What scrolls, only inside the viewport.
    out.push(Draw::Item(Item::Clip { rect: Some(at.viewport) }));
    let [_, id, state, title, owner, idle] = columns(at.head);
    let h = &t.head;
    for (rect, words_, align) in [(id, &h.id, Align::Left), (state, &h.state, Align::Left), (title, &h.title, Align::Left), (owner, &h.owner, Align::Left), (idle, &h.idle, Align::Right)] {
        if rect.w > 0.0 {
            out.push(Draw::Item(Item::Text { rect, text: words_.clone(), style: l3(theme.text_secondary), align }));
        }
    }
    out.push(Draw::Item(Item::Fill { rect: Rect { y: at.head.y + at.head.h - hair, h: hair, ..at.head }, color: rule }));
    if let (Some(m), Some(r)) = (t.no_match.as_ref(), at.no_match) {
        let x = r.x + k::ROW_PAD_X;
        let w = (r.w - 2.0 * k::ROW_PAD_X).max(0.0);
        out.push(Draw::Item(Item::Text { rect: Rect { x, y: r.y, w, h: k::BODY_LINE_HEIGHT }, text: m.title.clone(), style: strong(l3(theme.text)), align: Align::Left }));
        out.push(Draw::Item(Item::Text { rect: Rect { x, y: r.y + k::BODY_LINE_HEIGHT + k::NO_MATCH_GAP, w, h: k::BODY_LINE_HEIGHT }, text: m.detail.clone(), style: l3(theme.text_secondary), align: Align::Left }));
    }

    if let Some(g) = at.glass {
        out.push(Draw::Item(Item::Round { rect: g, radius: k::DETAIL_RADIUS_WINDOWS, color: scene::over(ground, theme.perf_card, 1.0), edge: Some(scene::over(ground, theme.perf_card_edge, 1.0)) }));
    }
    let tasks: Vec<&Task> = t.in_order().collect();
    let card = scene::over(ground, theme.perf_card, 1.0);
    for (k, (task, place)) in tasks.iter().zip(&at.tasks).enumerate() {
        let lit = selected == Some(task.id);
        // A hairline between two lines, but not round the glass, the
        // chip or the first closed one.
        let after_glass = k > 0 && tasks[k - 1].detail.is_some();
        let after_lit = k > 0 && selected == Some(tasks[k - 1].id);
        let first_closed = place.closed && (k == 0 || !at.tasks[k - 1].closed);
        if k > 0 && task.detail.is_none() && !after_glass && !first_closed && !lit && !after_lit {
            out.push(Draw::Item(Item::Fill { rect: Rect { h: hair, ..place.rect }, color: rule }));
        }
        let under = if task.detail.is_some() { card } else { ground };
        if lit {
            out.extend(chip(place.rect, under, theme, keys, hover == Some(Hover::Task(task.id))));
        } else if hover == Some(Hover::Task(task.id)) {
            out.push(hover_ground(place.rect, under, theme));
        }
        out.extend(task_line(task, place.rect, place.closed, lit.then(|| chip_colour(under, theme, keys)), theme, measure));
    }
    out.extend(at.detail.iter().cloned());

    // The closed tasks' line: its words, a rule to the key at its right,
    // and what the key does; under the pointer, the flat ground and no rule.
    if let (Some(title), Some(s)) = (t.closed_title.as_ref(), at.section) {
        let over_it = hover == Some(Hover::Closed);
        if over_it {
            out.push(hover_ground(s, ground, theme));
        }
        let style = l3(theme.text_secondary);
        let tw = measure(title, &style);
        out.push(Draw::Item(Item::Text { rect: Rect { x: s.x + k::ROW_PAD_X, w: tw, ..s }, text: title.clone(), style, align: Align::Left }));
        let key_x = t.closed_key.as_ref().map_or(s.x + s.w - k::ROW_PAD_X, |h| s.x + s.w - k::ROW_PAD_X - keyed_width(h, theme, measure));
        if let Some(h) = &t.closed_key {
            out.extend(keyed(h, key_x, s, theme.text_secondary, theme, measure));
        }
        let rule_x = s.x + k::ROW_PAD_X + tw + k::CLOSED_RULE_GAP;
        let rule_end = key_x - k::CLOSED_RULE_GAP;
        if !over_it && rule_x < rule_end {
            out.push(Draw::Item(Item::Fill { rect: Rect { x: rule_x, y: s.y + s.h / 2.0, w: rule_end - rule_x, h: hair }, color: rule }));
        }
    }
    out.push(Draw::Item(Item::Clip { rect: None }));

    // A fade at an edge of the list while there is more of it that way.
    let scroll = at.viewport.y - (at.head.y);
    let fade = k::EDGE_FADE.min(at.viewport.h / 2.0);
    if scroll > 0.5 {
        out.push(Draw::Fade { rect: Rect { h: fade, ..at.viewport }, color: ground, from_top: true });
    }
    if scroll < at.max_scroll() - 0.5 {
        out.push(Draw::Fade { rect: Rect { y: at.viewport.y + at.viewport.h - fade, h: fade, ..at.viewport }, color: ground, from_top: false });
    }

    // The keys' strip: a hairline along its top, the keys at its left -- as
    // many as fit before the right-hand one, the first first, since one cut
    // in half says nothing -- and the right-hand one always.
    let s = at.strip;
    out.push(Draw::Item(Item::Fill { rect: s, color: ground }));
    out.push(Draw::Item(Item::Fill { rect: Rect { h: hair, ..s }, color: rule }));
    let right = at.hint_closed.map_or(s.x + s.w - k::BAR_PAD_X, |r| r.x - k::HINTS_GAP);
    let mut kx = s.x + k::BAR_PAD_X;
    for (i, h) in t.hints.iter().enumerate() {
        let x = if i > 0 { kx + k::HINTS_GAP } else { kx };
        let w = keyed_width(h, theme, measure);
        if x + w > right {
            break;
        }
        out.extend(keyed(h, x, s, theme.text_secondary, theme, measure));
        kx = x + w;
    }
    if let (Some(h), Some(r)) = (t.hint_closed.as_ref(), at.hint_closed) {
        out.extend(keyed(h, r.x, s, theme.text, theme, measure));
    }
    // Nothing empty handed on (`scene::draws`).
    out.into_iter()
        .filter(|d| !matches!(d, Draw::Item(Item::Text { text, .. }) if !scene::draws(text)))
        .collect()
}

/// The selection once an answer has come: **the selected one kept while
/// the answer has it** -- the words changed or not -- and, while filtering,
/// the first it found when it has not; none otherwise (group seq 35, as the
/// mac host does; round 7d, 4: Windows was seen to move off #104 to the
/// first found though #104 was still found).
pub fn reselect(t: &Tasks, selected: Option<u64>, filtering: bool) -> Option<u64> {
    match selected {
        Some(s) if t.in_order().any(|x| x.id == s) => Some(s),
        _ if filtering => t.in_order().next().map(|x| x.id),
        _ => None,
    }
}

/// Where the arrow keys go from `selected` among the tasks in order: one
/// on, one back, held at the ends; the first when none is selected.
pub fn step(t: &Tasks, selected: Option<u64>, down: bool) -> Option<u64> {
    let ids: Vec<u64> = t.in_order().map(|x| x.id).collect();
    let first = *ids.first()?;
    let Some(at) = selected.and_then(|s| ids.iter().position(|i| *i == s)) else { return Some(first) };
    let to = if down { (at + 1).min(ids.len() - 1) } else { at.saturating_sub(1) };
    Some(ids[to])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::DARK;
    use crate::tasks::decode;
    use crate::tasks::tests::{CLOSED, NULLS, OPEN};

    fn nominal(s: &str, style: &Style) -> f64 {
        let cells: usize = s.chars().map(|c| if c as u32 >= 0x2E80 { 2 } else { 1 }).sum();
        cells as f64 * crate::look::stack_tab::NOMINAL_CELL_WIDTH * style.size / font::BODY
    }

    fn texts(d: &[Draw]) -> Vec<(Rect, String)> {
        d.iter()
            .filter_map(|d| match d {
                Draw::Item(Item::Text { rect, text, .. }) => Some((*rect, text.clone())),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn the_columns_stand_as_v9_has_them_and_the_title_takes_the_rest() {
        let [g, id, st, title, owner, idle] = columns(Rect { x: 24.0, y: 0.0, w: 1000.0, h: 28.0 });
        assert_eq!((g.x, g.w), (36.0, 26.0));
        assert_eq!((id.x, id.w), (62.0, 60.0));
        assert_eq!((st.x, st.w), (122.0, 104.0));
        assert_eq!(title.x, 226.0);
        assert_eq!((idle.x + idle.w, idle.w), (1012.0, 96.0));
        assert_eq!((owner.x + owner.w, owner.w), (idle.x, 120.0));
        assert_eq!(title.x + title.w, owner.x);
    }

    #[test]
    fn the_open_task_is_lifted_with_its_detail_and_the_others_follow_it() {
        let t = decode(OPEN).unwrap();
        let at = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        assert_eq!((at.goal.y, at.head.y), (0.0, 28.0));
        assert_eq!(at.tasks[0].rect.y, 56.0);
        // #215 is second: a margin of glass before it.
        assert_eq!(at.tasks[1].rect.y, 56.0 + 28.0 + 6.0);
        let g = at.glass.expect("glass round the open task");
        assert_eq!(g.y, at.tasks[1].rect.y);
        assert_eq!(at.tasks[2].rect.y, g.y + g.h + 6.0);
        // Rows after it are 28 apart, then the closed line 4 below.
        assert_eq!(at.tasks[3].rect.y, at.tasks[2].rect.y + 28.0);
        assert_eq!(at.section.unwrap().y, at.tasks[5].rect.y + 28.0 + 4.0);
        // The detail starts inside the glass at its padding.
        let first = texts(&at.detail)[0].0;
        assert_eq!((first.x, first.y), (24.0 + 38.0, at.tasks[1].rect.y + 28.0 + 4.0));
    }

    #[test]
    fn the_detail_is_as_tall_as_its_taller_column() {
        let t = decode(OPEN).unwrap();
        let d = t.open[1].detail.as_ref().unwrap();
        let (_, h) = detail(d, 0.0, 0.0, 1000.0, &DARK, 1.0, &nominal);
        // Left: label, three lines of wording, room, label, seven events and two gaps.
        let left = 24.0 + 3.0 * 20.0 + 12.0 + 24.0 + 7.0 * 24.0 + 2.0 * 20.0;
        assert_eq!(h, left);
        // A short history: the messages are the taller column, and the
        // detail is as tall as they are -- at least a heading and four
        // messages of a line, a line and the room under each.
        let mut short = d.clone();
        short.log.truncate(1);
        let short_left = 24.0 + 3.0 * 20.0 + 12.0 + 24.0 + 24.0;
        let (_, h) = detail(&short, 0.0, 0.0, 1000.0, &DARK, 1.0, &nominal);
        assert!(h >= 24.0 + 4.0 * (20.0 + 20.0 + 12.0) && h > short_left, "{h}");
    }

    #[test]
    fn a_line_breaks_where_the_words_run_out_and_at_its_own_ends() {
        let style = l3(DARK.text);
        let lines = wrapped("aaaa bbbb cccc\ndd", &style, 9.0 * 8.0, &nominal);
        assert_eq!(lines, vec!["aaaa bbbb", "cccc", "dd"]);
        for l in &lines {
            assert!(nominal(l, &style) <= 72.0);
        }
        // Ten cells wide: "aaaa bbbb c" is eleven and does not fit.
        assert_eq!(wrapped("aaaa bbbb c dd", &style, 80.0, &nominal), vec!["aaaa bbbb", "c dd"]);
    }

    #[test]
    fn a_full_stop_or_a_closing_bracket_never_begins_a_line() {
        // Six fit; the seventh is 。: the line ends a character early, and
        // that character goes down with it.
        assert_eq!(break_before("一二三四五六。七", 6), 5);
        // A run of them -- 」。 -- takes the one before the run down.
        assert_eq!(break_before("一二三四」。五", 4), 3);
        // Nothing to push: where it fits.
        assert_eq!(break_before("一二三四五六七", 6), 6);
        assert_eq!(break_before("一二三", 3), 3, "all of it fits");
        // A line is not pushed out to nothing.
        assert_eq!(break_before("一。。。", 1), 1);
        // Through `wrapped`, 0x4881's line (group seq 274): five fit, the
        // sixth is 。 -- 五 goes down with it, and no line is wider than
        // five, so nothing is cut short.
        let style = l3(DARK.text);
        let lines = wrapped("一二三四五。六七", &style, 5.0 * 16.0, &nominal);
        assert_eq!(lines, vec!["一二三四".to_string(), "五。六七".to_string()]);
        let five = 5.0 * 16.0;
        assert!(lines.iter().all(|x| nominal(x, &style) <= five + 1e-9), "{lines:?}");
        assert!(lines.iter().all(|x| !x.starts_with('。')));
    }

    /// A history whose lines have no time and no who (API.md §2.0) is
    /// drawn: its words, its dots, no empty text in their place.
    #[test]
    fn a_history_without_times_or_whos_is_drawn() {
        let drawn = |json: &str| {
            let t = decode(json).unwrap();
            let at = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
            format!("{:?}", build(&t, &at, &DARK, 1.0, None, true, None, &nominal))
        };
        let (with, without) = (drawn(OPEN), drawn(NULLS));
        assert!(without.contains("建了这条任务"));
        // The history's times are gone; what the group said keeps its own.
        let times = |s: &str| s.matches("\"13:02\"").count();
        let log_times = decode(OPEN).unwrap().open.iter().filter_map(|x| x.detail.as_ref()).flat_map(|d| d.log.iter()).filter(|l| matches!(l, LogLine::Event { at: Some(a), .. } if a == "13:02")).count();
        assert!(log_times > 0);
        assert_eq!(times(&with) - times(&without), log_times);
    }

    /// The mac host's 0x373c steps (group seq 289): press #2 (opened), ↓ to
    /// #3, Enter -- #3 opened, #2 shut; Enter again shuts #3.
    #[test]
    fn enter_acts_on_the_selected_task() {
        let (mut selected, mut open) = after_press(2, None);
        assert_eq!((selected, open), (Some(2), Some(2)));
        selected = Some(3);
        (selected, open) = after_return(selected, open, Some(2));
        assert_eq!((selected, open), (Some(3), Some(3)));
        (selected, open) = after_return(selected, open, Some(2));
        assert_eq!((selected, open), (Some(3), None));
        assert_eq!(after_return(None, None, Some(7)), (Some(7), Some(7)));
        assert_eq!(after_return(None, None, None), (None, None));
        assert_eq!(after_press(3, Some(3)), (Some(3), None));
    }

    /// The goal a line at a time (#2060), as the chat's brief is
    /// (`briefRows`): each line wrapped on its own, the empty ones skipped,
    /// two rows at most.
    #[test]
    fn the_goal_is_its_lines_each_wrapped_and_two_rows_at_most() {
        let style = l3(DARK.text_secondary);
        let lines: Vec<String> = ["第 5 轮进行中（2026-10-22）：", "", "- frontend：列表多选和工具条", "- api: PATCH /api/tasks"].iter().map(|s| s.to_string()).collect();
        // Wide: the first two lines, not run together, and no third.
        assert_eq!(goal_rows(&lines, &style, 1000.0, &nominal), vec![lines[0].clone(), lines[2].clone()]);
        // The first line wrapping to two leaves no room for the second.
        let narrow = goal_rows(&lines, &style, 10.0 * 16.0, &nominal);
        let first = wrapped(&lines[0], &style, 10.0 * 16.0, &nominal);
        assert!(first.len() >= 2, "{first:?}");
        assert_eq!(narrow, first[..2].to_vec(), "the first line's rows, nothing of the second");
        // Before the bracket, not at the one space (task 2105; it was 「第 5」):
        // the rows the mac host's `theGoalIsItsLinesEachWrappedAndTwoRowsAtMost` has.
        assert_eq!(narrow, vec!["第 5 轮进行中".to_string(), "（2026-10-22）：".to_string()]);
        // None, no rows; one short line, one row.
        assert!(goal_rows(&[], &style, 1000.0, &nominal).is_empty());
        assert_eq!(goal_rows(&lines[3..], &style, 1000.0, &nominal), vec![lines[3].clone()]);
    }

    /// One row keeps the goal's height; a second makes it a line taller,
    /// and what is under it moves down by as much.
    #[test]
    fn a_second_goal_row_makes_the_goal_a_line_taller() {
        let mut t = decode(OPEN).unwrap();
        let one = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        assert_eq!((one.goal.h, one.head.y, one.goal_rows.len()), (k::GOAL_HEIGHT, k::GOAL_HEIGHT, 1));
        t.goal_lines = vec!["第 5 轮进行中（2026-10-22）：".into(), "- frontend：列表多选和工具条".into(), "- api: PATCH /api/tasks".into()];
        let two = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        assert_eq!(two.goal_rows.len(), 2);
        assert_eq!(two.goal.h, k::GOAL_HEIGHT + k::BODY_LINE_HEIGHT);
        assert_eq!(two.head.y, one.head.y + k::BODY_LINE_HEIGHT);
        // What is drawn is those rows, a line apart, and not `goal`.
        let d = build(&t, &two, &DARK, 1.0, None, true, None, &nominal);
        let rows: Vec<(f64, String)> = d.iter().filter_map(|x| match x {
            Draw::Item(Item::Text { rect, text, .. }) if rect.y < two.head.y => Some((rect.y, text.clone())),
            _ => None,
        }).collect();
        assert_eq!(rows.iter().map(|r| r.1.as_str()).collect::<Vec<_>>(), vec!["第 5 轮进行中（2026-10-22）：", "- frontend：列表多选和工具条"]);
        assert_eq!(rows[1].0 - rows[0].0, k::BODY_LINE_HEIGHT);
        t.goal_lines.clear();
        let none = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        assert_eq!((none.goal.h, none.goal_rows.len()), (k::GOAL_HEIGHT, 0), "no goal keeps its room");
    }

    /// The state's symbol stands in the middle of its column.
    #[test]
    fn the_symbol_is_in_the_middle_of_its_column() {
        let t = decode(OPEN).unwrap();
        let at = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let d = build(&t, &at, &DARK, 1.0, None, true, None, &nominal);
        let [g, ..] = columns(at.tasks[0].rect);
        let ring = d.iter().find_map(|x| match x {
            Draw::Arc { centre, .. } if centre.1 == at.tasks[0].rect.y + at.tasks[0].rect.h / 2.0 => Some(*centre),
            _ => None,
        });
        assert_eq!(ring.map(|c| c.0), Some(g.x + g.w / 2.0));
    }

    #[test]
    fn the_rail_runs_from_the_first_dot_to_the_last_and_a_gap_is_dashed() {
        let t = decode(OPEN).unwrap();
        let d = t.open[1].detail.as_ref().unwrap();
        let (draws, _) = detail(d, 0.0, 100.0, 1000.0, &DARK, 1.0, &nominal);
        let rails: Vec<(f64, f64, bool)> = draws
            .iter()
            .filter_map(|d| match d {
                Draw::Stroke { points, dash, .. } if points[0].0 == points[1].0 => Some((points[0].1, points[1].1, dash.is_some())),
                _ => None,
            })
            .collect();
        assert_eq!(rails.len(), 9);
        assert_eq!(rails.iter().filter(|r| r.2).count(), 2);
        let ev_top = 100.0 + 24.0 + 3.0 * 20.0 + 12.0 + 24.0;
        assert_eq!(rails[0].0, ev_top + 12.0, "from the first dot");
        let last = rails.last().unwrap();
        assert_eq!(last.1, last.0 + 12.0, "to the last dot");
        // Each piece starts where the one before it ended.
        for w in rails.windows(2) {
            assert_eq!(w[0].1, w[1].0);
        }
    }

    #[test]
    fn a_press_finds_its_task_and_the_closed_line() {
        let t = decode(CLOSED).unwrap();
        let at = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        assert!(at.glass.is_none());
        let r = at.tasks[7].rect;
        assert_eq!(at.task_at(r.x + 1.0, r.y + 1.0), Some(t.closed[1].id));
        assert!(at.tasks[7].closed && !at.tasks[0].closed);
        let section = at.section.unwrap();
        assert!(at.on_section(section.x + 2.0, section.y + 2.0));
        assert_eq!(at.task_at(section.x + 2.0, section.y + 2.0), None);
        // The closed ones follow their line.
        assert_eq!(at.tasks[6].rect.y, section.y + 28.0);
    }

    #[test]
    fn the_arrows_go_through_the_tasks_in_order_and_stop_at_the_ends() {
        let t = decode(CLOSED).unwrap();
        assert_eq!(step(&t, None, true), Some(214));
        assert_eq!(step(&t, Some(214), false), Some(214));
        assert_eq!(step(&t, Some(219), true), Some(213), "on into the closed ones");
        assert_eq!(step(&t, Some(206), true), Some(206));
        assert_eq!(step(&t, Some(999), true), Some(214), "one no longer there starts again");
    }

    #[test]
    fn the_keys_have_a_strip_of_their_own_and_the_list_scrolls_above_it() {
        let t = decode(OPEN).unwrap();
        let a = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let b = layout(&t, 1200.0, 800.0, 50.0, &DARK, 1.0, &nominal);
        // #2083, plan A: the strip is the page's width and 40 tall at its
        // bottom; the list is seen from under the goal to the strip's top.
        assert_eq!(a.strip, Rect { x: 0.0, y: 760.0, w: 1200.0, h: 40.0 });
        assert_eq!(a.viewport, Rect { x: 0.0, y: 28.0, w: 1200.0, h: 760.0 - 28.0 });
        assert_eq!((a.strip, a.viewport, a.goal), (b.strip, b.viewport, b.goal));
        assert_eq!(b.tasks[3].rect.y, a.tasks[3].rect.y - 50.0);
        assert_eq!(a.content_height, b.content_height);
        assert_eq!(a.content_height, a.section.unwrap().y + 28.0 - a.viewport.y);
        // Nothing is pressed through the strip.
        let tall = layout(&decode(CLOSED).unwrap(), 1200.0, 300.0, 0.0, &DARK, 1.0, &nominal);
        let under = tall.tasks.iter().find(|x| x.rect.y < tall.strip.y + 10.0 && x.rect.y + x.rect.h > tall.strip.y + 10.0).unwrap();
        assert_eq!(tall.task_at(under.rect.x + 1.0, tall.strip.y + 10.0), None);
    }

    /// #2083: ↑↓ keeps a line's room past the selected task in sight: the
    /// list scrolls by as little as that takes, and not at all when it is
    /// so already.
    #[test]
    fn the_selected_task_is_kept_a_line_inside_the_list() {
        let t = decode(CLOSED).unwrap();
        // 300 tall: the list is seen from 28 to 260.
        let at = layout(&t, 1200.0, 300.0, 0.0, &DARK, 1.0, &nominal);
        let id = |i: usize| at.tasks[i].id;
        assert_eq!(at.follow(id(0), 0.0), 0.0);
        // #7 is at 56 + 7 * 28 = 252: brought up so its bottom is a line
        // over the strip.
        let to = at.follow(id(7), 0.0);
        let after = layout(&t, 1200.0, 300.0, to, &DARK, 1.0, &nominal);
        assert_eq!(after.tasks[7].rect.y + 28.0, after.viewport.y + after.viewport.h - 28.0);
        // Going back up: a line's room over it.
        let down = layout(&t, 1200.0, 300.0, 200.0, &DARK, 1.0, &nominal);
        let up = down.follow(id(3), 200.0);
        let back = layout(&t, 1200.0, 300.0, up, &DARK, 1.0, &nominal);
        assert_eq!(back.tasks[3].rect.y, back.viewport.y + 28.0);
        // Never past the ends.
        assert_eq!(at.follow(id(13), 0.0), at.max_scroll());
    }

    /// Group seq 35 (round 7d, 3): the selected one, when it is the open
    /// one, is brought back with its line at the top of the list -- not
    /// only just in sight -- and any other as the arrow keys bring it.
    #[test]
    fn the_open_one_comes_back_with_its_line_at_the_top() {
        let t = decode(OPEN).unwrap();
        let at = layout(&t, 1200.0, 300.0, 0.0, &DARK, 1.0, &nominal);
        let open = at.tasks[1].clone();
        assert_eq!(at.glass.map(|g| g.y), Some(open.rect.y));
        // In sight with a line's room already: following would not move.
        assert_eq!(at.follow(open.id, 0.0), 0.0);
        let to = at.reveal(open.id, 0.0);
        assert!(to <= at.max_scroll());
        let after = layout(&t, 1200.0, 300.0, to, &DARK, 1.0, &nominal);
        // A line of room over it, as any other has (task 2124).
        assert_eq!(after.tasks[1].rect.y, after.viewport.y + 28.0);
        // Any other: as the arrow keys bring it.
        let low = layout(&t, 1200.0, 300.0, 200.0, &DARK, 1.0, &nominal);
        assert_eq!(low.reveal(low.tasks[0].id, 200.0), low.follow(low.tasks[0].id, 200.0));
    }

    /// Group seq 35 (round 7d, 4): an answer leaves the selection where it
    /// is while the answer has it, whatever the words; the first found only
    /// when it is not found, and only while filtering.
    #[test]
    fn an_answer_keeps_the_selected_one_while_it_has_it() {
        let t = decode(CLOSED).unwrap();
        let ids: Vec<u64> = t.in_order().map(|x| x.id).collect();
        let (first, later) = (ids[0], ids[3]);
        let kept = reselect(&t, Some(later), true);
        assert_eq!(kept, Some(later));
        let unfiltered = reselect(&t, Some(later), false);
        assert_eq!(unfiltered, Some(later));
        let gone = reselect(&t, Some(u64::MAX), true);
        assert_eq!(gone, Some(first));
        let none = reselect(&t, None, true);
        assert_eq!(none, Some(first));
        let gone_unfiltered = reselect(&t, Some(u64::MAX), false);
        assert_eq!(gone_unfiltered, None);
    }

    /// #2083, plan S2: the arrow keys' task wears the group list's chip and
    /// a bar at its left in the main text colour -- never a grey ground;
    /// with the keyboard elsewhere an outline and the bar. Under the
    /// pointer, a flat faint ground; the chip under it is lifted.
    #[test]
    fn the_selected_task_wears_the_chip_and_its_bar() {
        let t = decode(CLOSED).unwrap();
        let at = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let r = at.tasks[2].rect;
        let rounds = |d: &[Draw]| -> Vec<(Rect, Rgba, Option<Rgba>)> {
            d.iter().filter_map(|x| match x {
                Draw::Item(Item::Round { rect, color, edge, .. }) => Some((*rect, *color, *edge)),
                _ => None,
            }).collect()
        };
        let bar = Rect { x: r.x + 3.0, y: r.y + 6.0, w: 3.0, h: 16.0 };
        let lit = rounds(&build(&t, &at, &DARK, 1.0, Some(at.tasks[2].id), true, None, &nominal));
        assert!(lit.iter().any(|x| x.0 == bar && x.1 == DARK.text), "no bar");
        let chip_ = lit.iter().find(|x| x.0 == r).expect("the chip");
        let grey = scene::over(DARK.terminal_background, DARK.perf_card, 1.0);
        assert_ne!(chip_.1, grey, "a grey ground");
        assert!(lit.iter().filter(|x| x.0.y < r.y && x.0.w > r.w).count() >= 1, "no shadow round the chip");
        // The keyboard elsewhere: an outline, no shadow, the bar still.
        let idle = rounds(&build(&t, &at, &DARK, 1.0, Some(at.tasks[2].id), false, None, &nominal));
        let outline = idle.iter().find(|x| x.0 == r).unwrap();
        assert_eq!((outline.1, outline.2), (DARK.terminal_background, Some(scene::over(DARK.terminal_background, DARK.line, 1.0))));
        assert!(idle.iter().any(|x| x.0 == bar));
        assert!(!idle.iter().any(|x| x.0.w > r.w));
        // Hovered: the flat ground, no bar.
        let hovered = rounds(&build(&t, &at, &DARK, 1.0, None, true, Some(Hover::Task(at.tasks[2].id)), &nominal));
        assert!(hovered.iter().any(|x| x.0 == r && x.1 == scene::over(DARK.terminal_background, DARK.window_tab_hover, 1.0) && x.2.is_none()));
        assert!(!hovered.iter().any(|x| x.0 == bar));
        // Selected and hovered: the chip lifted, its shadow further down.
        let lifted = rounds(&build(&t, &at, &DARK, 1.0, Some(at.tasks[2].id), true, Some(Hover::Task(at.tasks[2].id)), &nominal));
        let low = |v: &[(Rect, Rgba, Option<Rgba>)]| v.iter().filter(|x| x.0.w > r.w).map(|x| x.0.y + x.0.h).fold(0.0, f64::max);
        assert!(low(&lifted) > low(&lit));
    }

    fn ratio(a: Rgba, b: Rgba) -> f64 {
        let lin = |c: u8| {
            let c = c as f64 / 255.0;
            if c <= 0.03928 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        };
        let l = |c: Rgba| 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
        let (x, y) = (l(a).max(l(b)), l(a).min(l(b)));
        (x + 0.05) / (y + 0.05)
    }

    /// Task 2124: on the selected row the found words' ground was the
    /// chip's own colour, only the bold left of it. **Turned over there**:
    /// the ground to the chip is at least 3:1, the words on it at least
    /// 4.5:1 -- in both themes, with the keyboard here or not.
    #[test]
    fn the_found_words_on_the_chip_are_seen() {
        let t = decode(crate::tasks::tests::FILTER).unwrap();
        for theme in [&DARK, &crate::look::LIGHT] {
            for keys in [true, false] {
                let at = layout(&t, 1200.0, 800.0, 0.0, theme, 1.0, &nominal);
                let d = build(&t, &at, theme, 1.0, Some(at.tasks[0].id), keys, None, &nominal);
                let chip = chip_colour(theme.terminal_background, theme, keys);
                let ground = d.iter().find_map(|x| match x {
                    Draw::Item(Item::Round { rect, color, .. }) if rect.h == k::BODY_LINE_HEIGHT && rect.y > at.tasks[0].rect.y && rect.y < at.tasks[0].rect.y + at.tasks[0].rect.h => Some(*color),
                    _ => None,
                });
                let ground = ground.expect("a ground under the found words");
                assert_ne!(ground, theme.task_hit, "the chip's own colour, dark={} keys={keys}", theme.dark);
                assert!(ratio(ground, chip) >= 3.0, "ground to chip {:.2}, dark={} keys={keys}", ratio(ground, chip), theme.dark);
                let words = d.iter().find_map(|x| match x {
                    Draw::Item(Item::Text { rect, style, text, .. }) if text.contains("批量") && rect.y == at.tasks[0].rect.y && style.weight == font::WEIGHT_EMPHASIS => Some(style.color),
                    _ => None,
                }).expect("the found words");
                assert!(ratio(words, ground) >= 4.5, "words on ground {:.2}, dark={} keys={keys}", ratio(words, ground), theme.dark);
            }
        }
    }

    /// Task 2124: at a page 388 wide the title was 30 wide. **The title keeps
    /// `title_min`**; the idle column goes first, then the owner, then the
    /// state -- and what is gone is not drawn.
    #[test]
    fn the_title_keeps_its_room_and_the_other_columns_give_way() {
        let row = |w: f64| columns(Rect { x: 0.0, y: 0.0, w, h: 28.0 });
        let at388 = row(388.0 - 48.0);
        assert!(at388[3].w >= 200.0, "the title is {} wide", at388[3].w);
        assert_eq!((at388[2].w, at388[4].w, at388[5].w), (0.0, 0.0, 0.0));
        // Wide enough for the state but not the owner.
        let mid = row(500.0);
        assert!(mid[3].w >= 200.0 && mid[2].w == 104.0 && mid[4].w == 0.0, "{:?}", mid.map(|r| r.w));
        // None of them overlaps the next, whatever the width.
        for w in [150.0, 300.0, 340.0, 420.0, 520.0, 629.0, 800.0, 1200.0] {
            let c = row(w);
            for pair in [(2, 3), (3, 4), (4, 5)] {
                assert!(c[pair.0].x + c[pair.0].w <= c[pair.1].x + 0.001 || c[pair.0].w == 0.0 || c[pair.1].w == 0.0, "width {w}: {:?}", c.map(|r| (r.x, r.w)));
            }
        }
        let t = decode(OPEN).unwrap();
        let at = layout(&t, 388.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let said: Vec<String> = texts(&build(&t, &at, &DARK, 1.0, None, true, None, &nominal)).into_iter().map(|(_, s)| s).collect();
        assert!(!said.contains(&"状态".to_string()) && !said.contains(&"负责人".to_string()) && !said.contains(&"多久没动".to_string()), "{said:?}");
    }

    /// #2083: filtering, the box under the goal and the list under it; each
    /// title in the core's pieces, the found ones bold on `task_hit`.
    #[test]
    fn a_filter_puts_its_box_under_the_goal_and_marks_what_it_found() {
        let t = decode(crate::tasks::tests::FILTER).unwrap();
        let at = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let f = at.filter.as_ref().unwrap();
        assert_eq!((f.field.y, f.field.h), (28.0 + 4.0, 28.0));
        assert_eq!(at.viewport.y, 28.0 + 4.0 + 28.0 + 8.0);
        assert_eq!(f.clear.x + f.clear.w, 1200.0 - 24.0);
        assert!(f.field.x + f.field.w <= f.clear.x - 12.0);
        assert!(f.typed.x >= f.field.x && f.typed.x + f.typed.w <= f.count.unwrap().x);
        let d = build(&t, &at, &DARK, 1.0, None, true, None, &nominal);
        let hits: Vec<&Draw> = d.iter().filter(|x| matches!(x, Draw::Item(Item::Round { color, .. }) if *color == DARK.task_hit)).collect();
        assert_eq!(hits.len(), 2);
        let bold_hit = d.iter().any(|x| matches!(x, Draw::Item(Item::Text { text, style, .. }) if text == "批量" && style.weight == font::WEIGHT_EMPHASIS));
        assert!(bold_hit);
        let said: Vec<String> = texts(&d).into_iter().map(|(_, s)| s).collect();
        assert!(said.contains(&"2 / 6 条".to_string()) && said.contains(&"清空".to_string()));
        // Nothing matched: what the core says of it, under the heading.
        let n = decode(crate::tasks::tests::NOMATCH).unwrap();
        let nat = layout(&n, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        assert!(nat.tasks.is_empty());
        let nd: Vec<String> = texts(&build(&n, &nat, &DARK, 1.0, None, true, None, &nominal)).into_iter().map(|(_, s)| s).collect();
        assert!(nd.contains(&"没有标题里含「弹窗」的任务".to_string()));
    }

    /// #2083: the strip's right-hand key is always drawn; the left ones,
    /// as many as fit before it.
    #[test]
    fn the_right_hand_key_stays_and_the_left_ones_give_way() {
        let t = decode(OPEN).unwrap();
        let wide = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let r = wide.hint_closed.unwrap();
        assert_eq!(r.x + r.w, 1200.0 - 24.0);
        let said = |w: f64| -> Vec<String> {
            let at = layout(&t, w, 800.0, 0.0, &DARK, 1.0, &nominal);
            texts(&build(&t, &at, &DARK, 1.0, None, true, None, &nominal)).into_iter().filter(|(rect, _)| rect.y >= at.strip.y).map(|(_, s)| s).collect()
        };
        let all = said(1200.0);
        assert!(all.contains(&"选任务".to_string()) && all.contains(&"按标题筛选".to_string()) && all.contains(&"显示已关闭的 8 条".to_string()));
        let narrow = said(400.0);
        assert!(narrow.contains(&"显示已关闭的 8 条".to_string()));
        assert!(!narrow.contains(&"按标题筛选".to_string()));
        // On the key: does what c does.
        assert!(wide.on_hint_closed(r.x + 1.0, r.y + 1.0));
        // The keys' own words are asked at 14, the menu's size on Windows
        // (seq 88 of #2083). Every other word is raised to the menu's size
        // where the font is made (`uifont::make`, in the host).
        let d = build(&t, &wide, &DARK, 1.0, None, true, None, &nominal);
        let keys: Vec<f64> = d.iter().filter_map(|x| match x {
            Draw::Item(Item::Text { rect, style, .. }) if rect.y >= wide.strip.y && style.face == Face::Mono => Some(style.size),
            _ => None,
        }).collect();
        assert!(keys.len() == 4 && keys.iter().all(|s| *s >= 14.0), "{keys:?}");
    }

    /// #2083: a fade at an edge of the list while there is more that way.
    #[test]
    fn a_fade_says_there_is_more() {
        let t = decode(CLOSED).unwrap();
        let fades = |scroll: f64| -> Vec<bool> {
            let at = layout(&t, 1200.0, 300.0, scroll, &DARK, 1.0, &nominal);
            build(&t, &at, &DARK, 1.0, None, true, None, &nominal).iter().filter_map(|d| match d {
                Draw::Fade { from_top, .. } => Some(*from_top),
                _ => None,
            }).collect()
        };
        assert_eq!(fades(0.0), [false]);
        let max = layout(&t, 1200.0, 300.0, 0.0, &DARK, 1.0, &nominal).max_scroll();
        assert_eq!(fades(max), [true]);
        assert_eq!(fades(max / 2.0), [true, false]);
    }

    /// #2083: narrower than `title_min` for the title, the idle column goes.
    #[test]
    fn narrow_the_idle_column_goes() {
        let row = |w: f64| columns(Rect { x: 0.0, y: 0.0, w, h: 28.0 });
        let wide = row(630.0);
        assert_eq!((wide[3].w, wide[4].w, wide[5].w), (200.0, 120.0, 96.0));
        let narrow = row(629.0);
        assert_eq!((narrow[4].w, narrow[5].w), (96.0, 0.0));
        assert_eq!(narrow[4].x + narrow[4].w, 617.0);
        // Its heading and its words are not drawn.
        let t = decode(OPEN).unwrap();
        let at = layout(&t, 629.0 + 48.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let said: Vec<String> = texts(&build(&t, &at, &DARK, 1.0, None, true, None, &nominal)).into_iter().map(|(_, s)| s).collect();
        assert!(!said.contains(&"多久没动".to_string()) && !said.contains(&"17 分钟".to_string()));
    }

    #[test]
    fn every_word_drawn_is_the_cores_or_a_tasks_number() {
        let t = decode(OPEN).unwrap();
        let at = layout(&t, 1200.0, 800.0, 0.0, &DARK, 1.0, &nominal);
        let d = build(&t, &at, &DARK, 1.0, None, true, None, &nominal);
        let mut said: Vec<String> = texts(&d).into_iter().map(|(_, s)| s).collect();
        for d in &d {
            if let Draw::Item(Item::Line { parts, .. }) = d {
                for p in parts {
                    if let Piece::Words { text, .. } = &p.piece {
                        said.push(text.clone());
                    }
                }
            }
        }
        for s in &said {
            let number = s.strip_prefix('#').is_some_and(|n| n.parse::<u64>().is_ok());
            // The wording comes back a line at a time.
            assert!(number || OPEN.contains(s.as_str()), "{s:?} is not the core's");
        }
        assert!(said.iter().any(|s| s == "#215"));
    }

    #[test]
    fn every_symbol_the_look_names_is_drawn_and_each_state_its_own() {
        let all = [Glyph::Queued, Glyph::Working, Glyph::Blocked, Glyph::Done, Glyph::Closed, Glyph::Cancelled];
        let drawn: Vec<Vec<Draw>> = all
            .iter()
            .map(|g| {
                let (name, color) = symbol_of(*g, &DARK);
                symbol(name, (7.0, 7.0), color)
            })
            .collect();
        for (g, d) in all.iter().zip(&drawn) {
            assert!(!d.is_empty(), "{g:?}: the look names a symbol this build cannot draw");
        }
        for i in 0..all.len() {
            for k in i + 1..all.len() {
                assert_ne!(drawn[i], drawn[k], "{:?} and {:?}", all[i], all[k]);
            }
        }
        // A ringed name has a ring and the bare tick none.
        assert!(symbol("checkmark", (0.0, 0.0), DARK.text).iter().all(|d| !matches!(d, Draw::Arc { .. })));
        assert!(symbol("checkmark.circle", (0.0, 0.0), DARK.text).iter().any(|d| matches!(d, Draw::Arc { .. })));
        assert!(symbol("star.fill", (0.0, 0.0), DARK.text).is_empty());
        assert!(symbol("star.circle", (0.0, 0.0), DARK.text).is_empty(), "not a ring alone for a ringed name it cannot draw");
        // In the state's own colour.
        assert!(matches!(&drawn[1][0], Draw::Arc { color, .. } if *color == DARK.task_working));

    }
}
