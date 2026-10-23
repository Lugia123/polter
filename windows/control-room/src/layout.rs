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
/// what it is handed fit in the width a row gives. A line breaks where the
/// room ends when that is between words or beside a Chinese, Japanese or
/// Korean character; inside a word, at the last space or such character
/// before it (`break_at`), and with neither -- a path, a long flag -- where
/// the room ends. Text that is empty is one empty line: a step has a line
/// whether or not there is anything on it.
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
        let cut = break_at(rest, end);
        out.push(rest[..cut].trim_end().to_string());
        rest = rest[cut..].trim_start();
    }
    out.push(rest.to_string());
    out
}

/// Where a line of `s` ends when the room runs out at byte `end` (task
/// 2105): there, when the next character is a space or either side of it
/// is Chinese, Japanese or Korean -- text in those breaks between any two
/// characters. Otherwise the room ran out inside a word: at the last space
/// before it, or the last edge of such a character, so the word goes down
/// whole; at `end` when there is neither. **Never after an opening
/// bracket** (避尾, the other half of `tasks_scene::closes`): 「（」 goes
/// down with what it opens.
///
/// **Only a space was a break before, and any space back to the start of
/// the line.** A Chinese line with one space in it ended there: a group's
/// goal drawn as 「第 6」 and the rest on the next line (0x8d10, round six).
pub fn break_at(s: &str, end: usize) -> usize {
    let next = s[end..].chars().next();
    let prev = s[..end].chars().next_back();
    let free = !prev.is_some_and(opens);
    if next.is_none_or(char::is_whitespace) || (free && (prev.is_some_and(wide) || next.is_some_and(wide))) {
        return end;
    }
    let mut last = None;
    let mut before: Option<char> = None;
    for (at, c) in s[..end].char_indices() {
        if at > 0 && !before.is_some_and(opens) && (c.is_whitespace() || wide(c) || before.is_some_and(wide)) {
            last = Some(at);
        }
        before = Some(c);
    }
    last.unwrap_or(end)
}

/// What may not end a line (避尾): an opening bracket or quote.
pub fn opens(c: char) -> bool {
    "（【「『《〈〔［｛“‘([{".contains(c)
}

/// Whether `c` is from a script that breaks between any two characters --
/// Chinese, Japanese, Korean -- or is one of their full-width marks.
pub fn wide(c: char) -> bool {
    matches!(c as u32,
        0x1100..=0x115F | 0x2E80..=0x303E | 0x3041..=0x33FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF
        | 0xA000..=0xA4CF | 0xAC00..=0xD7A3 | 0xF900..=0xFAFF | 0xFE30..=0xFE4F | 0xFF00..=0xFF60
        | 0xFFE0..=0xFFE6 | 0x20000..=0x3FFFD)
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
    /// The allowance block, against the panel's bottom, as high as
    /// `quota::layout` says (task 1755); no height when the list has none.
    pub quota: Rect,
    /// Where the rows are seen: from under the header (and the notice)
    /// down to the allowance block, or to the panel's bottom when there is
    /// none. The rows are clipped to it and scroll inside it (task 1657;
    /// the macOS host's `ControlRoomListLayout.viewport`, task 1654).
    pub viewport: Rect,
    /// How tall what scrolls in `viewport` is: from its top to under the
    /// last row.
    pub content_height: f64,
    /// How far the rows are scrolled up, already kept to what they can
    /// be: every rect in `rows`, `separator` and `quiet_header` is where it
    /// is seen, that much higher than where it was laid out.
    pub scrolled: f64,
    /// The line under a row (task 1661): why a new name for it was
    /// refused, or that its supervisor was asked something -- for the rows
    /// that have one. The row is taller by the line; this is where the line
    /// is in it.
    pub line_rects: Vec<(String, Rect)>,
    /// The list's last section (task 1661, design v21 `06`): the groups
    /// put away. Its line and its header have no height when there are
    /// none; its rows, by name, only while the person has it open.
    pub archived_separator: Rect,
    pub archived_header: Rect,
    pub archived_rows: Vec<(String, Rect)>,
}

/// What the list's layout depends on besides the list (task 1661): the
/// rows with a line under them, the groups put away in the core's order,
/// and whether the person opened their section.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Extras {
    pub lines_under: Vec<String>,
    pub archived: Vec<String>,
    pub archived_open: bool,
}

/// Scrolling the rows in the viewport, as numbers: the same rules as the
/// macOS host's `ControlRoomListLayout.reveal` and `inSight`, which
/// `tools/control-room-hosts-agree.py` holds the two to. A row here is
/// where it was laid out, before any scroll.
pub mod scroll {
    use super::Rect;

    /// The furthest the rows scroll: until the last of them is at the
    /// viewport's bottom.
    pub fn max(content_height: f64, viewport: Rect) -> f64 {
        (content_height - viewport.h).max(0.0)
    }

    /// `scrolled` kept to what the rows can be scrolled.
    pub fn kept(scrolled: f64, content_height: f64, viewport: Rect) -> f64 {
        scrolled.clamp(0.0, max(content_height, viewport))
    }

    /// Whether the whole of `row` is seen with the rows scrolled up by
    /// `scrolled`. A row with no height never is.
    pub fn in_view(row: Rect, viewport: Rect, scrolled: f64) -> bool {
        let (top, bottom) = (viewport.y + scrolled, viewport.y + viewport.h + scrolled);
        row.h > 0.0 && row.y >= top && row.y + row.h <= bottom
    }

    /// How far to scroll so that the whole of `row` is seen, from
    /// `scrolled`: the least scroll that does it, as a selection walked
    /// with the arrow keys expects -- the row's top to the viewport's top
    /// when it is above (or taller than the viewport), its bottom to the
    /// viewport's bottom when it is below. None when it is in sight
    /// already, or has no height.
    pub fn reveal(row: Rect, viewport: Rect, scrolled: f64) -> Option<f64> {
        if row.h <= 0.0 {
            return None;
        }
        let (top, bottom) = (viewport.y + scrolled, viewport.y + viewport.h + scrolled);
        if row.y < top || row.h > viewport.h {
            return Some(row.y - viewport.y);
        }
        if row.y + row.h > bottom {
            return Some(row.y + row.h - (viewport.y + viewport.h));
        }
        None
    }
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
        Self::measured_with(list, height, needed, &Extras::default())
    }

    /// The same with `extras`. The macOS host's `ControlRoomListLayout`
    /// with `linesUnder`, `archived` and `archivedOpen` is the same
    /// arithmetic, and `tools/control-room-hosts-agree.py` holds the two
    /// to it.
    pub fn measured_with(list: &List, height: f64, needed: &dyn Fn(&str, bool) -> usize, extras: &Extras) -> ListLayout {
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

        let line_h = side::ASK_LINE_HEIGHT;
        let has_line = |id: &str| extras.lines_under.iter().any(|u| u == id);
        let mut rows = Vec::new();
        let mut fits = Vec::new();
        let mut line_rects = Vec::new();
        for row in &list.waiting {
            let code = crate::list::is_code(&row.what);
            let wanted: Vec<usize> = crate::list::drawn(&row.what).iter().map(|line| needed(line, code)).collect();
            let fit = AskFit::fit(&wanted);
            let more = if has_line(&row.id) { line_h } else { 0.0 };
            let row_h = row_height(&fit, row.others, row.fix) + more;
            rows.push((row.id.clone(), Rect { x: pad, y, w: inner, h: row_h }));
            if more > 0.0 {
                // Under what it waits on, above "Fix" when it has that.
                let fix_h = if row.fix == Fix::None { 0.0 } else { side::FIX_LINE_HEIGHT };
                line_rects.push((row.id.clone(), Rect { x: pad, y: y + row_h - side::ROW_PADDING_Y - fix_h - line_h, w: inner, h: line_h }));
            }
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
        let quiet_h = side::QUIET_ROW_HEIGHT;
        for row in &list.quiet {
            let more = if has_line(&row.id) { line_h } else { 0.0 };
            rows.push((row.id.clone(), Rect { x: pad, y, w: inner, h: quiet_h + more }));
            if more > 0.0 {
                line_rects.push((row.id.clone(), Rect { x: pad, y: y + quiet_h, w: inner, h: line_h }));
            }
            y += quiet_h + more;
        }

        // The groups put away: a line, their header, and while it is open
        // a quiet row each.
        let mut archived_rows = Vec::new();
        let (archived_separator, archived_header) = if extras.archived.is_empty() {
            (Rect { x: pad + pad_x, y, w: inner - 2.0 * pad_x, h: 0.0 }, Rect { x: pad, y, w: inner, h: 0.0 })
        } else {
            y += side::SEPARATOR_SPACE_ABOVE;
            let line = Rect { x: pad + pad_x, y, w: inner - 2.0 * pad_x, h: line::HAIRLINE };
            y += line::HAIRLINE + side::SEPARATOR_SPACE_BELOW;
            let head = Rect { x: pad, y, w: inner, h: header_h };
            y += header_h;
            if extras.archived_open {
                for name in &extras.archived {
                    archived_rows.push((name.clone(), Rect { x: pad, y, w: inner, h: quiet_h }));
                    y += quiet_h;
                }
            }
            (line, head)
        };

        let list_top = notice.map_or(header.y + header.h, |n| n.y + n.h + side::ROW_GAP);
        let quota = Rect { x: pad, y: height, w: inner, h: 0.0 };
        let viewport = Rect { x: 0.0, y: list_top, w: width, h: (height - list_top).max(0.0) };
        let content_height = y + pad - list_top;
        ListLayout {
            width,
            height,
            header,
            rows,
            fits,
            separator,
            quiet_header,
            notice,
            quota,
            viewport,
            content_height,
            scrolled: 0.0,
            line_rects,
            archived_separator,
            archived_header,
            archived_rows,
        }
        // The list's allowance block, as the macOS host's layout takes it
        // (`ControlRoomListLayout`, `quotaH`): the rows' room ends over it.
        .with_quota(list.quota.as_ref().map_or(0.0, |q| crate::quota::layout(q).height))
    }

    /// The same with the allowance block `height` high at the panel's
    /// bottom, and the rows' room ending where it starts. `measured_with`
    /// gives every layout the list's own block this way.
    pub fn with_quota(mut self, height: f64) -> ListLayout {
        let h = height.max(0.0);
        let pad = space::SIDE_PANEL_PADDING;
        self.quota = if h > 0.0 {
            Rect { x: pad, y: self.height - pad - h, w: self.width - 2.0 * pad, h }
        } else {
            Rect { x: pad, y: self.height, w: self.width - 2.0 * pad, h: 0.0 }
        };
        let bottom = if h > 0.0 { self.quota.y } else { self.height };
        self.viewport.h = (bottom - self.viewport.y).max(0.0);
        let scrolled = self.scrolled;
        self.scrolled_to(scrolled)
    }

    /// The same with the rows scrolled up by `scrolled`, kept to what they
    /// can be: every row, the line and the quiet header are moved to where
    /// they are seen. What draws, what is clicked and what a screen reader
    /// is told all read the one scrolled layout, so they agree.
    pub fn scrolled_to(mut self, scrolled: f64) -> ListLayout {
        let to = scroll::kept(scrolled, self.content_height, self.viewport);
        let by = to - self.scrolled;
        if by != 0.0 {
            for (_, r) in self.rows.iter_mut().chain(self.line_rects.iter_mut()).chain(self.archived_rows.iter_mut()) {
                r.y -= by;
            }
            self.separator.y -= by;
            self.quiet_header.y -= by;
            self.archived_separator.y -= by;
            self.archived_header.y -= by;
            self.scrolled = to;
        }
        self
    }

    /// Where a row was laid out, before any scroll.
    fn laid_out(&self, id: &str) -> Option<Rect> {
        self.rows.iter().find(|(name, _)| name == id).map(|(_, r)| Rect { y: r.y + self.scrolled, ..*r })
    }

    /// What a selection was brought into sight for (task 1664): the row,
    /// and where it was laid out -- before any scroll, so that the person
    /// scrolling away changes nothing, while a row put above it (a group
    /// just made, one pinned, a line under another row) does. None for a
    /// row not listed. A host brings the selection into sight again
    /// whenever this is not what it was the last time.
    pub fn sight_key(&self, id: Option<&str>) -> Option<(String, Option<(f64, f64)>)> {
        let id = id?;
        Some((id.to_string(), self.laid_out(id).map(|r| (r.y, r.h))))
    }

    /// The archived group under a point of the panel, by name; only in the
    /// viewport.
    pub fn archived_at(&self, x: f64, y: f64) -> Option<&str> {
        if y < self.viewport.y || y >= self.viewport.y + self.viewport.h {
            return None;
        }
        self.archived_rows.iter().find(|(_, r)| x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h).map(|(n, _)| n.as_str())
    }

    /// Whether a point of the panel is on the archived section's header,
    /// which opens and closes it.
    pub fn on_archived_header(&self, x: f64, y: f64) -> bool {
        let r = self.archived_header;
        r.h > 0.0 && y >= self.viewport.y && y < self.viewport.y + self.viewport.h && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
    }

    /// How far to scroll so that the whole of row `id` is seen
    /// (`scroll::reveal`); None when it already is, or is not listed.
    pub fn reveal(&self, id: Option<&str>) -> Option<f64> {
        scroll::reveal(self.laid_out(id?)?, self.viewport, self.scrolled)
    }

    /// Whether the whole of row `id` is seen.
    pub fn in_view(&self, id: &str) -> bool {
        self.laid_out(id).is_some_and(|r| scroll::in_view(r, self.viewport, self.scrolled))
    }

    /// The row under a point of the panel, by its group's name. Only in
    /// the viewport: a row scrolled under the header is not pressed there.
    pub fn row_at(&self, x: f64, y: f64) -> Option<&str> {
        if y < self.viewport.y || y >= self.viewport.y + self.viewport.h {
            return None;
        }
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
    /// The group's brief being edited, at the right (task 1661, design v21
    /// `04-B`): the right side gives up its width and the space between.
    pub note: Option<Rect>,
}

impl Room {
    pub fn new(width: f64, height: f64) -> Room {
        let edge = space::WINDOW_EDGE;
        let h = (height - 2.0 * edge).max(0.0);
        let panel = Rect { x: edge, y: edge, w: side::WIDTH, h };
        let x = panel.x + panel.w + space::BETWEEN_FRAMES;
        Room { panel, right: Rect { x, y: edge, w: (width - x - edge).max(0.0), h }, note: None }
    }

    /// The same with the brief's panel open at the right, `group_note::
    /// PANEL_WIDTH` wide: the right side narrower by that and the space
    /// between frames -- which leaves it no narrower than nothing.
    pub fn with_note(mut self, open: bool) -> Room {
        if open {
            let w = crate::look::group_note::PANEL_WIDTH;
            let give = (w + space::BETWEEN_FRAMES).min(self.right.w);
            self.right.w -= give;
            self.note = Some(Rect {
                x: self.right.x + self.right.w + space::BETWEEN_FRAMES,
                y: self.right.y,
                w: (give - space::BETWEEN_FRAMES).max(0.0),
                h: self.right.h,
            });
        }
        self
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

#[cfg(test)]
mod scroll_tests {
    use super::*;

    fn r(y: f64, h: f64) -> Rect {
        Rect { x: 0.0, y, w: 100.0, h }
    }

    /// Task 1657: the least scroll that shows the whole of a row, the
    /// macOS host's rule (task 1654).
    #[test]
    fn a_row_out_of_sight_is_brought_to_the_nearer_end() {
        let view = r(40.0, 200.0);
        // In sight, from its top to its bottom: no scroll.
        assert_eq!(scroll::reveal(r(40.0, 28.0), view, 0.0), None);
        assert_eq!(scroll::reveal(r(212.0, 28.0), view, 0.0), None);
        // Below: its bottom to the viewport's bottom.
        assert_eq!(scroll::reveal(r(230.0, 28.0), view, 0.0), Some(18.0));
        // Above: its top to the viewport's top -- not the list's top.
        assert_eq!(scroll::reveal(r(100.0, 28.0), view, 150.0), Some(60.0));
        assert_eq!(scroll::reveal(r(40.0, 28.0), view, 150.0), Some(0.0));
        // Taller than the room: its top.
        assert_eq!(scroll::reveal(r(100.0, 300.0), view, 0.0), Some(60.0));
        // Nothing to show.
        assert_eq!(scroll::reveal(r(100.0, 0.0), view, 0.0), None);
        assert!(scroll::in_view(r(212.0, 28.0), view, 0.0));
        assert!(!scroll::in_view(r(213.0, 28.0), view, 0.0));
        assert!(!scroll::in_view(r(40.0, 28.0), view, 1.0));
    }

    #[test]
    fn the_rows_scroll_no_further_than_the_last_one_reaching_the_bottom() {
        let view = r(40.0, 200.0);
        assert_eq!(scroll::max(500.0, view), 300.0);
        assert_eq!(scroll::max(100.0, view), 0.0);
        assert_eq!(scroll::kept(-5.0, 500.0, view), 0.0);
        assert_eq!(scroll::kept(900.0, 500.0, view), 300.0);
    }

    fn long() -> List {
        const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/poltergeist/testdata/control_snapshot.json"));
        let mut l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let one = l.quiet[0].clone();
        l.quiet = (0..30).map(|n| crate::list::Row { id: format!("g{n}"), ..one.clone() }).collect();
        l
    }

    /// What is seen moves and what was laid out does not: a scrolled
    /// layout's rows are higher by the scroll, and a press above the
    /// viewport -- on the header -- is no row's.
    #[test]
    fn a_scrolled_layout_moves_the_rows_and_only_the_viewport_is_pressed() {
        let l = long();
        let at = ListLayout::new(&l, 600.0).with_quota(80.0);
        assert_eq!(at.viewport.y, at.header.y + at.header.h);
        assert_eq!(at.viewport.y + at.viewport.h, at.quota.y);
        assert!(at.content_height > at.viewport.h);
        let last = at.chip(Some("g29")).unwrap();
        assert!(last.y + last.h > at.quota.y);
        let to = at.reveal(Some("g29")).unwrap();
        assert_eq!(to, last.y + last.h - (at.viewport.y + at.viewport.h));
        let end = at.clone().scrolled_to(to);
        assert_eq!(end.scrolled, to);
        assert_eq!(end.chip(Some("g29")).unwrap().y, last.y - to);
        assert!(end.in_view("g29"));
        assert_eq!(end.reveal(Some("g29")), None);
        let first = l.rows().next().unwrap().id.clone();
        assert!(!end.in_view(&first));
        assert_eq!(end.reveal(Some(&first)), Some(0.0));
        // Past the end it stops at the end.
        assert_eq!(at.clone().scrolled_to(1.0e6).scrolled, scroll::max(at.content_height, at.viewport));
        // A row scrolled under the header is not pressed there.
        let under = end.chip(Some(&first)).unwrap();
        assert!(under.y + under.h <= end.viewport.y);
        assert_eq!(end.row_at(under.x + 1.0, under.y + under.h - 1.0), None);
        let seen = end.chip(Some("g29")).unwrap();
        assert_eq!(end.row_at(seen.x + 1.0, seen.y + 1.0), Some("g29"));
    }
}

#[cfg(test)]
mod note_tests {
    use super::*;

    /// Design v21 `04-B`: the brief's panel is 420 wide at the right and
    /// the supervisor's side gives up 428 for it; closed, nothing moves.
    #[test]
    fn the_briefs_panel_takes_its_width_from_the_right_side() {
        let closed = Room::new(1400.0, 800.0);
        assert_eq!(closed.with_note(false), closed);
        let open = closed.with_note(true);
        let note = open.note.unwrap();
        assert_eq!(note.w, 420.0);
        assert_eq!(closed.right.w - open.right.w, 428.0);
        assert_eq!(note.x, open.right.x + open.right.w + space::BETWEEN_FRAMES);
        assert_eq!(note.x + note.w, closed.right.x + closed.right.w);
        assert_eq!((note.y, note.h), (closed.right.y, closed.right.h));
        // Too narrow for both: the right side goes to nothing first.
        let narrow = Room::new(700.0, 800.0).with_note(true);
        assert_eq!(narrow.right.w, 0.0);
        assert!(narrow.note.unwrap().w >= 0.0);
    }
}

#[cfg(test)]
mod extras_tests {
    use super::*;

    fn list() -> List {
        const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/poltergeist/testdata/control_snapshot.json"));
        List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap())
    }

    /// Task 1661: a row with a line under it is that line taller, the rows
    /// after it move down by as much, and the line is at its bottom (above
    /// "Fix" on a card that has it); a quiet row's line is under its one.
    #[test]
    fn a_line_under_a_row_makes_it_one_line_taller() {
        let l = list();
        let (w, q) = (l.waiting[0].id.clone(), l.quiet[0].id.clone());
        let plain = ListLayout::new(&l, 900.0);
        let with = ListLayout::measured_with(&l, 900.0, &|t, _| nominal_lines(t), &Extras { lines_under: vec![w.clone(), q.clone()], ..Extras::default() });
        let (a, b) = (plain.chip(Some(&w)).unwrap(), with.chip(Some(&w)).unwrap());
        assert_eq!(b.h - a.h, side::ASK_LINE_HEIGHT);
        let line = with.line_rects.iter().find(|(id, _)| *id == w).unwrap().1;
        assert_eq!(line.y + line.h, b.y + b.h - side::ROW_PADDING_Y);
        let next = l.waiting[1].id.clone();
        assert_eq!(with.chip(Some(&next)).unwrap().y - plain.chip(Some(&next)).unwrap().y, side::ASK_LINE_HEIGHT);
        let quiet = with.chip(Some(&q)).unwrap();
        assert_eq!(quiet.h, side::QUIET_ROW_HEIGHT + side::ASK_LINE_HEIGHT);
        let qline = with.line_rects.iter().find(|(id, _)| *id == q).unwrap().1;
        assert_eq!((qline.y, qline.h), (quiet.y + side::QUIET_ROW_HEIGHT, side::ASK_LINE_HEIGHT));
        assert_eq!(with.content_height - plain.content_height, 2.0 * side::ASK_LINE_HEIGHT);
    }

    /// The groups put away are the list's last section: a line and a
    /// header after the quiet rows, their rows only while it is open; none
    /// of it when there are none. Scrolling moves it with the rest.
    #[test]
    fn the_archived_section_is_last_and_folds() {
        let l = list();
        let archived = vec!["old-app".to_string(), "spike-pdf".to_string()];
        let none = ListLayout::new(&l, 900.0);
        assert_eq!((none.archived_header.h, none.archived_separator.h), (0.0, 0.0));
        let shut = ListLayout::measured_with(&l, 900.0, &|t, _| nominal_lines(t), &Extras { archived: archived.clone(), ..Extras::default() });
        let last = shut.chip(Some(&l.quiet.last().unwrap().id)).unwrap();
        assert_eq!(shut.archived_separator.y, last.y + last.h + side::SEPARATOR_SPACE_ABOVE);
        assert_eq!(shut.archived_header.h, side::HEADER_HEIGHT);
        assert!(shut.archived_rows.is_empty());
        let open = ListLayout::measured_with(&l, 900.0, &|t, _| nominal_lines(t), &Extras { archived: archived.clone(), archived_open: true, ..Extras::default() });
        assert_eq!(open.archived_rows.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>(), archived);
        let first = open.archived_rows[0].1;
        assert_eq!(first.y, open.archived_header.y + open.archived_header.h);
        assert_eq!(open.content_height - shut.content_height, 2.0 * side::QUIET_ROW_HEIGHT);
        assert_eq!(open.archived_at(first.x + 1.0, first.y + 1.0), Some("old-app"));
        assert!(open.on_archived_header(open.archived_header.x + 1.0, open.archived_header.y + 1.0));
        assert_eq!(open.row_at(first.x + 1.0, first.y + 1.0), None);
        let short = ListLayout::measured_with(&l, 300.0, &|t, _| nominal_lines(t), &Extras { archived, archived_open: true, ..Extras::default() });
        let end = short.clone().scrolled_to(1.0e6);
        assert_eq!(end.archived_header.y, short.archived_header.y - end.scrolled);
        assert_eq!(end.archived_rows[1].1.y, short.archived_rows[1].1.y - end.scrolled);
    }
}

#[cfg(test)]
mod sight_tests {
    use super::*;

    fn list() -> List {
        const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/poltergeist/testdata/control_snapshot.json"));
        List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap())
    }

    /// Task 1664: a group made while the control room is open is listed
    /// above the selected one and pushes it down -- the selection did not
    /// change, and it was not brought into sight again. What a host keeps
    /// to know when to is the row and where it was laid out: scrolling
    /// leaves that alone, a row put above it does not.
    #[test]
    fn a_row_put_above_the_selection_changes_what_it_was_brought_into_sight_for() {
        let l = list();
        let last = l.quiet.last().unwrap().id.clone();
        let at = ListLayout::new(&l, 300.0);
        let key = at.sight_key(Some(&last));
        assert!(key.as_ref().unwrap().1.is_some());
        // Scrolled: the same.
        assert_eq!(at.clone().scrolled_to(120.0).sight_key(Some(&last)), key);
        // A group made, listed first among the quiet ones: it moved.
        let mut more = l.clone();
        let mut made = more.quiet[0].clone();
        made.id = "just-made".into();
        more.quiet.insert(0, made);
        let after = ListLayout::new(&more, 300.0);
        assert_ne!(after.sight_key(Some(&last)), key);
        assert!(after.reveal(Some(&last)).is_some());
        // Not listed yet, then listed: that changes it too.
        let early = ListLayout::new(&l, 300.0).sight_key(Some("just-made"));
        assert_eq!(early, Some(("just-made".to_string(), None)));
        assert_ne!(after.sight_key(Some("just-made")), early);
        assert_eq!(at.sight_key(None), None);
    }
}

#[cfg(test)]
mod wrap_tests {
    use super::*;

    /// How many characters from the start fit in `width` columns: one
    /// column for a narrow character, two for a wide one -- the shape of
    /// the host's measurement, without a font.
    fn fits(width: usize) -> impl Fn(&str) -> usize {
        move |s: &str| {
            let mut used = 0;
            let mut n = 0;
            for c in s.chars() {
                used += if wide(c) { 2 } else { 1 };
                if used > width {
                    break;
                }
                n += 1;
            }
            n
        }
    }

    /// Task 2105: the goal 0x8d10 read on Windows, one space in it.
    #[test]
    fn chinese_with_a_stray_space_breaks_where_the_row_is_full() {
        assert_eq!(wrap("第 6 轮进行中，收尾文案和用例", &fits(16)), ["第 6 轮进行中，", "收尾文案和用例"]);
    }

    /// An opening bracket goes down with what it opens: the goal of round
    /// five, twenty columns wide, as both hosts' goal tests have it.
    #[test]
    fn an_opening_bracket_does_not_end_a_line() {
        assert_eq!(wrap("第 5 轮进行中（2026-10-22）：", &fits(20)), ["第 5 轮进行中", "（2026-10-22）："]);
    }

    #[test]
    fn between_chinese_and_a_word_the_break_is_at_their_edge() {
        assert_eq!(wrap("中文中文hello world", &fits(12)), ["中文中文", "hello world"]);
    }

    /// Words break at spaces, as before.
    #[test]
    fn words_still_break_at_the_last_space() {
        assert_eq!(wrap("the quick brown fox", &fits(10)), ["the quick", "brown fox"]);
        assert_eq!(wrap("supercalifragilistic", &fits(6)), ["superc", "alifra", "gilist", "ic"]);
    }
}
