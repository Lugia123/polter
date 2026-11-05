//! A message's blocks as rectangles (task 2802, W3b-B2).
//!
//! **One plan for measure, draw and hit-test.** Given the immutable
//! `Document`, the available pixel width, the actual font faces (ascent and
//! descent from the host's chosen fonts) and one width-measuring callback,
//! this returns every block, line, inline piece and table cell with its
//! rectangle. The host draws those rectangles; it never wraps again, and a
//! click is answered by the same rectangles.
//!
//! Hard line breaks in the source stay hard breaks. Wrapping is by measured
//! pixel width, one character at a time, preferring a space; Chinese needs
//! no special case because any character may break. A code block and a
//! table that is wider than the message area report their content width, and
//! the host gives those their own horizontal view -- the chat's vertical
//! scroll is never taken over.

use crate::{Align, Block, Document, ListKind, Run};

/// One face's real vertical metrics, from the host's chosen font.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Face {
    pub ascent: i32,
    pub descent: i32,
}

impl Face {
    pub fn height(self) -> i32 {
        (self.ascent + self.descent).max(1)
    }
}

/// The four faces a message may use. The code face draws `code` runs; a
/// heading uses the strong face; strike and link are a style on top of one
/// of these.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fonts {
    pub body: Face,
    pub strong: Face,
    pub emphasis: Face,
    pub code: Face,
}

/// Which face a run is measured and drawn in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FontKind {
    Body,
    Strong,
    Emphasis,
    Code,
}

impl Fonts {
    pub fn face(&self, kind: FontKind) -> Face {
        match kind {
            FontKind::Body => self.body,
            FontKind::Strong => self.strong,
            FontKind::Emphasis => self.emphasis,
            FontKind::Code => self.code,
        }
    }
}

/// How a run is drawn: the face its styles choose.
pub fn font_of(style: &crate::Style, heading: bool) -> FontKind {
    if style.code {
        FontKind::Code
    } else if style.strong || heading {
        FontKind::Strong
    } else if style.emphasis {
        FontKind::Emphasis
    } else {
        FontKind::Body
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub fn contains(self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
}

/// A piece of one run on one line: a byte range of that run's text, at a
/// rectangle. The host draws the slice with the run's style.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Piece {
    pub run: usize,
    pub text: std::ops::Range<usize>,
    pub rect: Rect,
    /// The face this piece is measured and drawn in.
    pub kind: FontKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub rect: Rect,
    pub ascent: i32,
    pub descent: i32,
    pub pieces: Vec<Piece>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlockKind {
    Paragraph,
    Heading(u8),
    Quote(usize),
    ListItem {
        kind: ListKind,
        ordinal: u64,
        depth: usize,
        checked: Option<bool>,
    },
    Code {
        language: Option<String>,
    },
    /// A table block. Its table is found by this block's index through
    /// `Plan::table_at`; the variant carries no integer that could be
    /// mistaken for a table ordinal.
    Table,
    Rule,
}

/// A block and the rectangle the host draws it in. `prefix` is a list's
/// marker (a bullet, an ordinal, a task box) or nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockPlan {
    pub kind: BlockKind,
    pub rect: Rect,
    pub lines: Vec<Line>,
    pub prefix: Option<(String, Rect)>,
    /// Set for a code block (and reported by a table through its entry in
    /// `Plan::tables`): the content is wider than the message area.
    pub horizontal: Option<Horiz>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Horiz {
    pub content_width: i32,
    pub viewport_width: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CellPlan {
    pub rect: Rect,
    pub lines: Vec<Line>,
    pub align: Align,
    pub head: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TablePlan {
    /// The block this table belongs to (its index in `Plan::blocks`).
    pub block: usize,
    /// Each column's whole width, padding included.
    pub columns: Vec<i32>,
    pub header: Vec<CellPlan>,
    pub rows: Vec<Vec<CellPlan>>,
    pub horizontal: Option<Horiz>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub width: i32,
    pub height: i32,
    pub blocks: Vec<BlockPlan>,
    pub tables: Vec<TablePlan>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hit {
    Block(usize),
    Cell {
        table: usize,
        head: bool,
        row: usize,
        column: usize,
    },
}

impl Horiz {
    /// How far the content can move left before its last pixel is at the
    /// viewport's right edge. Never negative.
    pub fn max_offset(self) -> i32 {
        (self.content_width - self.viewport_width).max(0)
    }

    /// An offset kept inside the content, including the exact end.
    pub fn clamp(self, offset: i32) -> i32 {
        offset.clamp(0, self.max_offset())
    }

    /// The visible rail and its thumb, **the same rectangles the mouse
    /// drags and the draw fills**. `rect` is the block's rectangle in the
    /// page; the rail sits at its bottom.
    pub fn thumb(self, rect: Rect, handle_h: i32, offset: i32) -> (Rect, Rect) {
        let off = self.clamp(offset);
        let h = handle_h.max(1);
        let track = Rect {
            x: rect.x,
            y: rect.y + rect.h.saturating_sub(h),
            w: self.viewport_width.max(1),
            h,
        };
        let thumb_w = ((self.viewport_width * track.w) / self.content_width.max(1))
            .clamp(16.min(track.w), track.w);
        let max = self.max_offset();
        let thumb_x = if max == 0 {
            0
        } else {
            (off.saturating_mul(track.w - thumb_w)) / max
        };
        (
            track,
            Rect {
                x: track.x + thumb_x,
                y: track.y,
                w: thumb_w,
                h: track.h,
            },
        )
    }

    /// The offset a click at `x` (in viewport pixels) asks for: the thumb
    /// centres on the pointer.
    pub fn offset_at(self, track_w: i32, pointer_x: i32) -> i32 {
        let (_, thumb) = self.thumb(
            Rect {
                x: 0,
                y: 0,
                w: track_w,
                h: 1,
            },
            1,
            0,
        );
        let span = (track_w - thumb.w).max(1);
        let max = self.max_offset();
        ((pointer_x.clamp(0, span).saturating_mul(max)) / span).clamp(0, max)
    }
}

/// A rail the mouse can grab: **viewport coordinates, no content offset**.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BarHit {
    pub block: usize,
    pub horiz: Horiz,
    pub track: Rect,
    pub thumb: Rect,
}

impl Plan {
    /// **The rail comes first.** Its track and thumb sit in the viewport,
    /// so this hit applies no horizontal offset at all; only content may
    /// call `hit_scrolled`. `x` is viewport pixels, `y` is plan pixels.
    pub fn bar_at<F: Fn(usize) -> i32>(
        &self,
        x: i32,
        y: i32,
        offset: F,
        handle_h: i32,
    ) -> Option<BarHit> {
        for (block, plan) in self.blocks.iter().enumerate() {
            let Some(horiz) = self.horizontal(block) else {
                continue;
            };
            let rect = Rect {
                x: 0,
                y: plan.rect.y,
                w: horiz.viewport_width,
                h: plan.rect.h,
            };
            let (track, thumb) = horiz.thumb(rect, handle_h, offset(block));
            if x >= track.x
                && x < track.x.saturating_add(track.w)
                && y >= track.y
                && y < track.y.saturating_add(track.h)
            {
                return Some(BarHit {
                    block,
                    horiz,
                    track,
                    thumb,
                });
            }
        }
        None
    }

    /// **The table a block index names.** `TablePlan.block` is the source
    /// Document/Plan block index, so this is the only correct way from a
    /// `BlockKind::Table` to its table: the `tables` vector is compact and
    /// its positions are table ordinals, not block indices.
    pub fn table_at(&self, block_index: usize) -> Option<&TablePlan> {
        self.tables.iter().find(|t| t.block == block_index)
    }

    /// The horizontal range of one block: its own for a code block, the
    /// table's for a table block. `None` when the block fits.
    pub fn horizontal(&self, block: usize) -> Option<Horiz> {
        if let Some(b) = self.blocks.get(block) {
            if b.horizontal.is_some() {
                return b.horizontal;
            }
        }
        self.tables
            .iter()
            .find(|t| t.block == block)
            .and_then(|t| t.horizontal)
    }

    /// **The same rectangles the draw uses, in viewport coordinates.**
    /// `offset` answers how far each block is scrolled horizontally; the
    /// y axis is untouched, so a vertical hit is never moved by a
    /// horizontal offset.
    pub fn hit_scrolled<F: Fn(usize) -> i32>(&self, x: i32, y: i32, offset: F) -> Option<Hit> {
        let block = self
            .blocks
            .iter()
            .position(|b| y >= b.rect.y && y < b.rect.y.saturating_add(b.rect.h))?;
        let x = x.saturating_add(offset(block));
        self.hit(x, y)
    }

    /// The same rectangles the draw uses, asked for one point.
    pub fn hit(&self, x: i32, y: i32) -> Option<Hit> {
        for (ti, table) in self.tables.iter().enumerate() {
            for (column, cell) in table.header.iter().enumerate() {
                if cell.rect.contains(x, y) {
                    return Some(Hit::Cell {
                        table: ti,
                        head: true,
                        row: 0,
                        column,
                    });
                }
            }
            for (ri, row) in table.rows.iter().enumerate() {
                for (column, cell) in row.iter().enumerate() {
                    if cell.rect.contains(x, y) {
                        return Some(Hit::Cell {
                            table: ti,
                            head: false,
                            row: ri,
                            column,
                        });
                    }
                }
            }
        }
        self.blocks
            .iter()
            .position(|b| b.rect.contains(x, y))
            .map(Hit::Block)
    }
}

/// Space around the content, and a list's step per depth, in DIP (multiplied
/// by the DPI scale once here).
pub const PAD_DIP: i32 = 12;
pub const INDENT_DIP: i32 = 16;
pub const QUOTE_DIP: i32 = 16;
/// A table column's text width, and the padding round it.
pub const COLUMN_MIN_DIP: i32 = 44;
pub const COLUMN_MAX_DIP: i32 = 220;
pub const CELL_PAD_DIP: i32 = 8;
pub const CELL_VERT_DIP: i32 = 4;
/// The rail a scrollable block reserves at its bottom, in DIP. **Part of
/// the block's height**: the thumb never covers the last line.
pub const HANDLE_DIP: i32 = 5;

/// The reserved rail in pixels at one DPI.
pub fn handle_height(scale: f64) -> i32 {
    dip(HANDLE_DIP, scale).max(1)
}

pub struct Inputs<'a> {
    pub width: i32,
    /// DPI / 96.
    pub scale: f64,
    pub fonts: Fonts,
    /// The width of `text` in the face, in pixels.
    pub measure: &'a dyn Fn(FontKind, &str) -> i32,
}

fn dip(v: i32, scale: f64) -> i32 {
    (v as f64 * scale).round() as i32
}

/// Lay one message out. `width` is the message area in pixels.
pub fn layout(doc: &Document, input: &Inputs<'_>) -> Plan {
    let width = input.width.max(1);
    let mut blocks = Vec::new();
    let mut tables = Vec::new();
    let mut y = 0i32;

    for block in &doc.blocks {
        match block {
            Block::Paragraph(runs) => {
                let lines = wrap(runs, width, 0, input);
                let h = sum_heights(&lines);
                blocks.push(BlockPlan {
                    kind: BlockKind::Paragraph,
                    rect: Rect {
                        x: 0,
                        y,
                        w: width,
                        h,
                    },
                    lines,
                    prefix: None,
                    horizontal: None,
                });
                y = y.saturating_add(h);
            }
            Block::Heading { level, runs } => {
                let lines = wrap_heading(runs, width, input);
                let h = sum_heights(&lines);
                blocks.push(BlockPlan {
                    kind: BlockKind::Heading(*level),
                    rect: Rect {
                        x: 0,
                        y,
                        w: width,
                        h,
                    },
                    lines,
                    prefix: None,
                    horizontal: None,
                });
                y = y.saturating_add(h);
            }
            Block::Quote { depth, runs } => {
                let indent = dip(QUOTE_DIP, input.scale) * (*depth as i32).max(1);
                let lines = wrap(runs, (width - indent).max(1), indent, input);
                let h = sum_heights(&lines);
                blocks.push(BlockPlan {
                    kind: BlockKind::Quote(*depth),
                    rect: Rect {
                        x: 0,
                        y,
                        w: width,
                        h,
                    },
                    lines,
                    prefix: None,
                    horizontal: None,
                });
                y = y.saturating_add(h);
            }
            Block::ListItem(item) => {
                let indent = dip(INDENT_DIP, input.scale) * item.depth as i32;
                let prefix_text = match item.kind {
                    ListKind::Ordered => format!("{}.", item.ordinal),
                    ListKind::Unordered => match item.checked {
                        Some(true) => "☑".to_owned(),
                        Some(false) => "☐".to_owned(),
                        None => "•".to_owned(),
                    },
                };
                let prefix_w = (input.measure)(FontKind::Body, &prefix_text);
                let text_left = indent + prefix_w + dip(6, input.scale);
                let lines = wrap(&item.runs, (width - text_left).max(1), text_left, input);
                let h = sum_heights(&lines);
                blocks.push(BlockPlan {
                    kind: BlockKind::ListItem {
                        kind: item.kind,
                        ordinal: item.ordinal,
                        depth: item.depth,
                        checked: item.checked,
                    },
                    rect: Rect {
                        x: 0,
                        y,
                        w: width,
                        h,
                    },
                    lines,
                    prefix: Some((
                        prefix_text,
                        Rect {
                            x: indent,
                            y,
                            w: prefix_w,
                            h: input.fonts.body.height(),
                        },
                    )),
                    horizontal: None,
                });
                y = y.saturating_add(h);
            }
            Block::Code { language, text, .. } => {
                let mut line_count = 0usize;
                let line_h = input.fonts.code.height();
                let mut content = 0;
                let mut plans = Vec::new();
                // **Ranges are absolute in the block's own text**: the
                // host draws each piece with `code.get(piece.text)`, so a
                // per-line 0..len would draw the block's first line again
                // for every line. LF and CRLF are separators, never glyphs.
                let mut base = 0usize;
                for line in text.split('\n') {
                    let start = base;
                    let mut end = base.saturating_add(line.len());
                    if text.get(start..end).is_some_and(|s| s.ends_with('\r')) {
                        end = end.saturating_sub(1);
                    }
                    let shown = text.get(start..end).unwrap_or("");
                    let w = (input.measure)(FontKind::Code, shown);
                    content = content.max(w);
                    plans.push(Line {
                        rect: Rect {
                            x: 0,
                            y,
                            w: w.max(1),
                            h: line_h,
                        },
                        ascent: input.fonts.code.ascent,
                        descent: input.fonts.code.descent,
                        pieces: vec![Piece {
                            run: 0,
                            text: start..end,
                            rect: Rect {
                                x: 0,
                                y,
                                w: w.max(1),
                                h: line_h,
                            },
                            kind: FontKind::Code,
                        }],
                    });
                    base = start.saturating_add(line.len()).saturating_add(1);
                    line_count += 1;
                    y = y.saturating_add(line_h);
                }
                let content_h = (line_count as i32).max(1) * line_h;
                let horizontal = (content > width).then_some(Horiz {
                    content_width: content,
                    viewport_width: width,
                });
                let h = content_h
                    .saturating_add(horizontal.map_or(0, |_| handle_height(input.scale)));
                blocks.push(BlockPlan {
                    kind: BlockKind::Code {
                        language: language.clone(),
                    },
                    rect: Rect {
                        x: 0,
                        y: y.saturating_sub(content_h),
                        w: width,
                        h,
                    },
                    lines: plans,
                    prefix: None,
                    horizontal,
                });
                y = y.saturating_add(horizontal.map_or(0, |_| handle_height(input.scale)));
            }
            Block::Table(table) => {
                let index = blocks.len();
                let plan = table_plan(table, index, width, y, input);
                y = y.saturating_add(plan.height);
                blocks.push(BlockPlan {
                    kind: BlockKind::Table,
                    rect: Rect {
                        x: 0,
                        y: y.saturating_sub(plan.height),
                        w: width,
                        h: plan.height,
                    },
                    lines: Vec::new(),
                    prefix: None,
                    horizontal: plan.plan.horizontal,
                });
                tables.push(plan.plan);
            }
            Block::Rule => {
                let h = 1;
                blocks.push(BlockPlan {
                    kind: BlockKind::Rule,
                    rect: Rect {
                        x: 0,
                        y,
                        w: width,
                        h,
                    },
                    lines: Vec::new(),
                    prefix: None,
                    horizontal: None,
                });
                y = y.saturating_add(h);
            }
        }
        y = y.saturating_add(dip(4, input.scale));
    }
    Plan {
        width,
        height: y,
        blocks,
        tables,
    }
}

struct TableBuilt {
    plan: TablePlan,
    height: i32,
}

fn table_plan(
    table: &crate::Table,
    block: usize,
    width: i32,
    top: i32,
    input: &Inputs<'_>,
) -> TableBuilt {
    let scale = input.scale;
    let pad = dip(CELL_PAD_DIP, scale);
    let vpad = dip(CELL_VERT_DIP, scale);
    let min = dip(COLUMN_MIN_DIP, scale);
    let max = dip(COLUMN_MAX_DIP, scale);
    let cols = table.columns.len();

    // Natural content width of each column, header and rows together.
    let mut natural = vec![0i32; cols];
    for (c, cell) in table.header.iter().enumerate() {
        natural[c] = natural[c].max(runs_width(cell, input));
    }
    for row in &table.rows {
        for (c, cell) in row.iter().take(cols).enumerate() {
            natural[c] = natural[c].max(runs_width(cell, input));
        }
    }
    let columns: Vec<i32> = natural
        .iter()
        .map(|n| (n + pad * 2).clamp(min + pad * 2, max + pad * 2))
        .collect();
    let content_width: i32 = columns.iter().sum();
    let mut y = top;
    let mut header = Vec::new();
    // Header row: strong face.
    let mut head_h = 0;
    let mut head_cells = Vec::new();
    let mut x = 0;
    for (c, cell) in table.header.iter().enumerate() {
        let col_w = columns[c];
        let lines = wrap_cell(cell, col_w - pad * 2, x + pad, y + vpad, input, true);
        let h = sum_heights(&lines) + vpad * 2;
        head_h = head_h.max(h);
        head_cells.push((c, lines));
        x += col_w;
    }
    for (c, lines) in head_cells {
        let col_w = columns[c];
        let mut lines = lines;
        align_lines(&mut lines, table.columns[c], col_w, pad);
        header.push(CellPlan {
            rect: Rect {
                x: columns[..c].iter().sum::<i32>(),
                y,
                w: col_w,
                h: head_h.max(1),
            },
            lines,
            align: table.columns[c],
            head: true,
        });
    }
    y = y.saturating_add(head_h.max(1));
    let mut rows = Vec::new();
    for row in &table.rows {
        let mut cells = Vec::new();
        let mut row_h = 0;
        let mut x = 0;
        let mut built = Vec::new();
        for (c, cell) in row.iter().take(cols).enumerate() {
            let col_w = columns[c];
            let lines = wrap_cell(cell, col_w - pad * 2, x + pad, y + vpad, input, false);
            let h = sum_heights(&lines) + vpad * 2;
            row_h = row_h.max(h);
            built.push((c, lines, x, col_w));
            x += col_w;
        }
        for (c, mut lines, x, col_w) in built {
            align_lines(&mut lines, table.columns[c], col_w, pad);
            cells.push(CellPlan {
                rect: Rect {
                    x,
                    y,
                    w: col_w,
                    h: row_h.max(1),
                },
                lines,
                align: table.columns[c],
                head: false,
            });
        }
        y = y.saturating_add(row_h.max(1));
        rows.push(cells);
    }
    let horizontal = (content_width > width).then_some(Horiz {
        content_width,
        viewport_width: width,
    });
    TableBuilt {
        plan: TablePlan {
            block,
            columns,
            header,
            rows,
            horizontal,
        },
        height: (y - top)
            .max(1)
            .saturating_add(horizontal.map_or(0, |_| handle_height(scale))),
    }
}

/// Move each line's pieces to its column's alignment. The rectangles the
/// draw uses are the ones the hit-test answers.
fn align_lines(lines: &mut [Line], align: Align, column_width: i32, pad: i32) {
    let free_base = (column_width - pad * 2).max(0);
    for line in lines {
        let used: i32 = line.pieces.iter().map(|p| p.rect.w).sum();
        let shift = match align {
            Align::Left => 0,
            Align::Center => ((free_base - used) / 2).max(0),
            Align::Right => (free_base - used).max(0),
        };
        for piece in &mut line.pieces {
            piece.rect.x = piece.rect.x.saturating_add(shift);
        }
    }
}

fn runs_width(runs: &[Run], input: &Inputs<'_>) -> i32 {
    runs.iter()
        .map(|run| (input.measure)(font_of(&run.style, false), &run.text))
        .sum()
}

fn sum_heights(lines: &[Line]) -> i32 {
    lines.iter().map(|l| l.rect.h).sum()
}

/// Wrap runs into lines, by measured width. Newlines in the text are hard
/// breaks. `left` is the x where the content starts.
fn wrap(runs: &[Run], width: i32, left: i32, input: &Inputs<'_>) -> Vec<Line> {
    wrap_cell(runs, width, left, 0, input, false)
}

fn wrap_heading(runs: &[Run], width: i32, input: &Inputs<'_>) -> Vec<Line> {
    wrap_cell(runs, width, 0, 0, input, true)
}

struct Open {
    pieces: Vec<Piece>,
    ascent: i32,
    descent: i32,
    line_y: i32,
}

impl Open {
    fn close(&mut self, left: i32, width: i32, lines: &mut Vec<Line>) -> i32 {
        let h = (self.ascent + self.descent).max(1);
        lines.push(Line {
            rect: Rect {
                x: left,
                y: self.line_y,
                w: width.max(1),
                h,
            },
            ascent: self.ascent,
            descent: self.descent,
            pieces: std::mem::take(&mut self.pieces),
        });
        self.ascent = 0;
        self.descent = 0;
        h
    }
}

fn push_piece(
    open: &mut Open,
    run: usize,
    start: usize,
    end: usize,
    x: i32,
    face: Face,
    w: i32,
    kind: FontKind,
) {
    if start >= end {
        return;
    }
    open.ascent = open.ascent.max(face.ascent);
    open.descent = open.descent.max(face.descent);
    open.pieces.push(Piece {
        run,
        text: start..end,
        rect: Rect {
            x,
            y: open.line_y,
            w: w.max(1),
            h: face.height(),
        },
        kind,
    });
}

fn wrap_cell(
    runs: &[Run],
    width: i32,
    left: i32,
    top: i32,
    input: &Inputs<'_>,
    heading: bool,
) -> Vec<Line> {
    let width = width.max(1);
    let right = left.saturating_add(width);
    let mut lines = Vec::new();
    let mut open = Open {
        pieces: Vec::new(),
        ascent: 0,
        descent: 0,
        line_y: top,
    };
    // Where the next piece on the current line starts: the end of what has
    // already been committed. `chunk_x` is where the current uncommitted
    // chunk starts; it is **not** the running end.
    let mut line_end = left;

    for (ri, run) in runs.iter().enumerate() {
        let kind = font_of(&run.style, heading);
        let face = input.fonts.face(kind);
        let bytes = run.text.as_bytes();
        let mut chunk_start = 0usize;
        let mut chunk_x = line_end;
        let mut i = 0usize;
        while i < bytes.len() {
            let ch = run.text[i..].chars().next().unwrap_or(' ');
            let next = i + ch.len_utf8();
            // A line terminator ends the line the source had.
            if ch == '\n' || ch == '\r' {
                if i > chunk_start {
                    let w = (input.measure)(kind, &run.text[chunk_start..i]);
                    push_piece(&mut open, ri, chunk_start, i, chunk_x, face, w, kind);
                    line_end = chunk_x.saturating_add(w);
                }
                let h = open.close(left, width, &mut lines);
                open.line_y = open.line_y.saturating_add(h);
                i = if ch == '\r' && bytes.get(next) == Some(&b'\n') {
                    next + 1
                } else {
                    next
                };
                chunk_start = i;
                chunk_x = left;
                line_end = left;
                continue;
            }
            // The whole candidate chunk, measured with the real font: the
            // prefix widths are never added together.
            let candidate = (input.measure)(kind, &run.text[chunk_start..next]);
            if chunk_x.saturating_add(candidate) <= right {
                i = next;
                continue;
            }
            // The chunk starts an empty line and not even this one glyph
            // fits: commit it once, explicitly overflowing, and advance so
            // the loop can never stall.
            if i == chunk_start && chunk_x == left {
                push_piece(&mut open, ri, chunk_start, next, chunk_x, face, candidate, kind);
                let h = open.close(left, width, &mut lines);
                open.line_y = open.line_y.saturating_add(h);
                chunk_start = next;
                i = next;
                chunk_x = left;
                line_end = left;
                continue;
            }
            // Prefer the last space; the space itself is the separator.
            if let Some(rel) = run.text[chunk_start..i].rfind(' ') {
                let at = chunk_start + rel;
                if at > chunk_start {
                    let w = (input.measure)(kind, &run.text[chunk_start..at]);
                    push_piece(&mut open, ri, chunk_start, at, chunk_x, face, w, kind);
                    line_end = chunk_x.saturating_add(w);
                    let h = open.close(left, width, &mut lines);
                    open.line_y = open.line_y.saturating_add(h);
                    chunk_start = at + 1;
                    // Rescan from the new start: no character is skipped.
                    i = chunk_start;
                    chunk_x = left;
                    line_end = left;
                    continue;
                }
            }
            if i > chunk_start {
                // Commit what fits and retry this character on the next
                // line.
                let w = (input.measure)(kind, &run.text[chunk_start..i]);
                push_piece(&mut open, ri, chunk_start, i, chunk_x, face, w, kind);
                line_end = chunk_x.saturating_add(w);
                let h = open.close(left, width, &mut lines);
                open.line_y = open.line_y.saturating_add(h);
                chunk_start = i;
                chunk_x = left;
                line_end = left;
                continue;
            }
            // An empty chunk whose first character did not fit because the
            // line already carries earlier runs: wrap first, then retry.
            let h = open.close(left, width, &mut lines);
            open.line_y = open.line_y.saturating_add(h);
            chunk_x = left;
            line_end = left;
        }
        // The run ended: commit its tail once, and the next run starts at
        // that end.
        if run.text.len() > chunk_start {
            let w = (input.measure)(kind, &run.text[chunk_start..]);
            push_piece(
                &mut open,
                ri,
                chunk_start,
                run.text.len(),
                chunk_x,
                face,
                w,
                kind,
            );
            line_end = chunk_x.saturating_add(w);
        }
    }
    // **No text is no line**: an empty table cell keeps its rectangle and
    // its column, not a phantom line of height.
    if !open.pieces.is_empty() {
        open.close(left, width, &mut lines);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Style, Table};

    fn faces() -> Fonts {
        Fonts {
            body: Face {
                ascent: 12,
                descent: 4,
            },
            strong: Face {
                ascent: 15,
                descent: 5,
            },
            emphasis: Face {
                ascent: 13,
                descent: 4,
            },
            code: Face {
                ascent: 10,
                descent: 6,
            },
        }
    }

    fn measure(kind: FontKind, text: &str) -> i32 {
        let per = match kind {
            FontKind::Body => 7,
            FontKind::Strong => 9,
            FontKind::Emphasis => 8,
            FontKind::Code => 6,
        };
        text.chars().count() as i32 * per
    }

    fn inputs<'a>(
        width: i32,
        fonts: &'a Fonts,
        measure: &'a dyn Fn(FontKind, &str) -> i32,
    ) -> Inputs<'a> {
        Inputs {
            width,
            scale: 1.0,
            fonts: *fonts,
            measure,
        }
    }

    fn run(text: &str, style: Style) -> Run {
        Run {
            text: text.to_owned(),
            style,
            spans: Vec::new(),
        }
    }

    #[test]
    fn inline_styles_share_a_line_and_the_tallest_face_sets_its_height() {
        let fonts = faces();
        let doc = Document {
            blocks: vec![Block::Paragraph(vec![
                run("a", Style::default()),
                run(
                    "b",
                    Style {
                        strong: true,
                        ..Style::default()
                    },
                ),
                run(
                    "c",
                    Style {
                        emphasis: true,
                        ..Style::default()
                    },
                ),
                run(
                    "d",
                    Style {
                        code: true,
                        ..Style::default()
                    },
                ),
            ])],
        };
        let plan = layout(&doc, &inputs(1000, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].pieces.len(), 4, "one piece per styled run");
        // The line covers the largest ascent and the largest descent among
        // its faces, which need not come from the same one (strong 15,
        // code 6).
        assert_eq!(lines[0].ascent, 15);
        assert_eq!(lines[0].descent, 6);
        assert_eq!(lines[0].rect.h, 21);
    }

    #[test]
    fn a_hard_break_is_a_new_line_and_a_heading_uses_the_strong_face() {
        let fonts = faces();
        let doc = Document {
            blocks: vec![
                Block::Heading {
                    level: 2,
                    runs: vec![run("title", Style::default())],
                },
                Block::Paragraph(vec![run("one\ntwo", Style::default())]),
            ],
        };
        let plan = layout(&doc, &inputs(1000, &fonts, &measure));
        assert_eq!(plan.blocks[0].lines[0].rect.h, 20, "heading face");
        assert_eq!(plan.blocks[1].lines.len(), 2, "hard break kept");
    }

    #[test]
    fn a_narrow_width_wraps_more_and_pieces_stay_inside_it() {
        let fonts = faces();
        let doc = Document {
            blocks: vec![Block::Paragraph(vec![run("abcdefghij", Style::default())])],
        };
        let wide = layout(&doc, &inputs(1000, &fonts, &measure));
        let narrow = layout(&doc, &inputs(21, &fonts, &measure));
        assert_eq!(wide.blocks[0].lines.len(), 1);
        assert!(narrow.blocks[0].lines.len() > 1);
        for line in &narrow.blocks[0].lines {
            for piece in &line.pieces {
                assert!(piece.rect.w <= 21, "a piece never overflows the width");
            }
        }
    }

    #[test]
    fn a_code_block_keeps_its_lines_and_reports_its_own_horizontal_width() {
        let fonts = faces();
        let doc = Document {
            blocks: vec![Block::Code {
                language: Some("rust".to_owned()),
                text: "one\n
long line here"
                    .replace("\n", "\n"),
                spans: Vec::new(),
            }],
        };
        // Two logical lines, the second far wider than the viewport.
        let doc = Document {
            blocks: vec![Block::Code {
                language: Some("rust".to_owned()),
                text: "one\nlong line here".to_owned(),
                spans: Vec::new(),
            }],
        };
        let plan = layout(&doc, &inputs(40, &fonts, &measure));
        let block = &plan.blocks[0];
        assert_eq!(block.lines.len(), 2);
        let horiz = block.horizontal.expect("wider than the viewport");
        assert!(horiz.content_width > horiz.viewport_width);
        assert_eq!(horiz.viewport_width, 40);
    }

    #[test]
    fn a_table_is_a_grid_with_empty_cells_kept_and_shared_column_widths() {
        let fonts = faces();
        let table = Table {
            columns: vec![Align::Left, Align::Center, Align::Right],
            header: vec![
                vec![run("a", Style::default())],
                vec![],
                vec![run("c", Style::default())],
            ],
            rows: vec![
                vec![
                    vec![run("1", Style::default())],
                    vec![],
                    vec![run("3", Style::default())],
                ],
                vec![
                    vec![run("longer text", Style::default())],
                    vec![run("x", Style::default())],
                    vec![],
                ],
            ],
        };
        let doc = Document {
            blocks: vec![Block::Table(table)],
        };
        let plan = layout(&doc, &inputs(600, &fonts, &measure));
        let t = &plan.tables[0];
        assert_eq!(t.columns.len(), 3);
        assert_eq!(t.header.len(), 3);
        assert!(
            t.header[1].lines.is_empty(),
            "an empty header cell is still a cell"
        );
        assert_eq!(t.rows.len(), 2);
        assert_eq!(t.rows[0].len(), 3);
        assert!(
            t.rows[1][2].lines.is_empty(),
            "an empty body cell keeps its place"
        );
        // Every row shares the column widths.
        for row in &t.rows {
            for (c, cell) in row.iter().enumerate() {
                assert_eq!(cell.rect.w, t.columns[c]);
            }
        }
        // Clamped: at least 44 DIP of content and at most 220.
        for width in &t.columns {
            assert!(*width >= 44 + 16 && *width <= 220 + 16, "column {width}");
        }
        // Alignments are carried.
        assert_eq!(t.header[0].align, Align::Left);
        assert_eq!(t.header[1].align, Align::Center);
        assert_eq!(t.header[2].align, Align::Right);
        // Hit test answers the same rectangles the draw would use.
        let cell = &t.rows[0][0];
        assert_eq!(
            plan.hit(cell.rect.x + 1, cell.rect.y + 1),
            Some(Hit::Cell {
                table: 0,
                head: false,
                row: 0,
                column: 0
            })
        );
    }

    #[test]
    fn a_wide_table_reports_its_horizontal_range_covering_the_last_column() {
        let fonts = faces();
        let row: Vec<Vec<Run>> = (0..4)
            .map(|_| vec![run(&"x".repeat(60), Style::default())])
            .collect();
        let table = Table {
            columns: vec![Align::Left; 4],
            header: row.clone(),
            rows: vec![row.clone()],
        };
        let doc = Document {
            blocks: vec![Block::Table(table)],
        };
        let plan = layout(&doc, &inputs(300, &fonts, &measure));
        let horiz = plan.tables[0].horizontal.expect("wider than the viewport");
        assert!(horiz.content_width > horiz.viewport_width);
        assert_eq!(
            horiz.content_width,
            plan.tables[0].columns.iter().sum::<i32>()
        );
        // The last cell ends at the content width the scrollbar reaches.
        let last = &plan.tables[0].rows[0][3];
        assert_eq!(last.rect.x + last.rect.w, horiz.content_width);
    }

    #[test]
    fn two_tables_keep_independent_offsets_and_both_reach_the_last_column() {
        let fonts = faces();
        let row: Vec<Vec<Run>> = (0..4)
            .map(|_| vec![run(&"x".repeat(60), Style::default())])
            .collect();
        let table = || Table {
            columns: vec![Align::Left; 4],
            header: row.clone(),
            rows: vec![row.clone()],
        };
        let doc = Document {
            blocks: vec![Block::Table(table()), Block::Table(table())],
        };
        let plan = layout(&doc, &inputs(300, &fonts, &measure));
        let first = plan.tables[0].block;
        let second = plan.tables[1].block;
        let h0 = plan.horizontal(first).expect("first table is wide");
        let h1 = plan.horizontal(second).expect("second table is wide");
        assert!(h0.content_width > h0.viewport_width);
        assert!(h1.content_width > h1.viewport_width);

        // The first table is at its end, the second at its start.
        let max0 = h0.max_offset();
        let offsets = |block: usize| if block == first { max0 } else { 0 };
        let last = &plan.tables[0].rows[0][3];
        assert_eq!(
            last.rect.x + last.rect.w - max0,
            h0.viewport_width,
            "the end offset puts the last column's right edge at the viewport edge"
        );
        let x = h0.viewport_width - 1;
        let y0 = plan.tables[0].rows[0][0].rect.y + 1;
        assert_eq!(
            plan.hit_scrolled(x, y0, offsets),
            Some(Hit::Cell {
                table: 0,
                head: false,
                row: 0,
                column: 3
            }),
            "the last column is reachable at the end offset"
        );

        // The second table did not move: its hit is exactly the unscrolled
        // one, so two tables' offsets cannot leak into each other.
        let y1 = plan.tables[1].rows[0][0].rect.y + 1;
        assert_eq!(
            plan.hit_scrolled(x, y1, offsets),
            plan.hit(x, y1),
            "the other table kept its own offset"
        );

        // Offset clamps: never negative, never past the end, and repeated
        // keyboard steps reach the last column exactly.
        assert_eq!(h0.clamp(-9), 0);
        assert_eq!(h0.clamp(max0 + 99), max0);
        assert_eq!(h0.offset_at(300, 300), max0);
        assert_eq!(h0.offset_at(300, 0), 0);
        let mut stepped = 0;
        for _ in 0..100 {
            stepped = h0.clamp(stepped + 40);
        }
        assert_eq!(stepped, max0, "arrow steps end at the last column");
        let (track, thumb) = h0.thumb(
            Rect {
                x: 0,
                y: 0,
                w: 300,
                h: 10,
            },
            4,
            max0,
        );
        assert_eq!(thumb.x + thumb.w, track.x + track.w, "thumb reaches the track end");

        // **The rail is viewport-fixed**: it is grabbable at the same
        // viewport pixels at offset 0, a partial offset and the end, and
        // the end thumb can be grabbed and dragged back.
        let handle = handle_height(1.0);
        let rail_y = plan.blocks[first].rect.y + plan.blocks[first].rect.h - 1;
        for off in [0, 40, max0] {
            let pick = |b: usize| if b == first { off } else { 0 };
            let bar = plan
                .bar_at(0, rail_y, pick, handle)
                .expect("the rail's left edge is grabbable");
            assert_eq!(bar.block, first, "offset {off}");
            let right = bar.track.x + bar.track.w - 1;
            assert_eq!(
                plan.bar_at(right, rail_y, pick, handle).map(|b| b.block),
                Some(first),
                "the rail's right edge is grabbable at offset {off}"
            );
            assert_eq!(
                plan.bar_at(bar.thumb.x, bar.thumb.y, pick, handle)
                    .map(|b| b.block),
                Some(first),
                "the thumb's left edge is grabbable at offset {off}"
            );
            assert_eq!(
                plan.bar_at(bar.thumb.x + bar.thumb.w - 1, bar.thumb.y, pick, handle)
                    .map(|b| b.block),
                Some(first),
                "the thumb's right edge is grabbable at offset {off}"
            );
        }
        let pick_max = |b: usize| if b == first { max0 } else { 0 };
        let end = plan
            .bar_at(0, rail_y, pick_max, handle)
            .expect("rail at the end offset");
        let grabbed = plan
            .bar_at(end.thumb.x + end.thumb.w / 2, end.thumb.y, pick_max, handle)
            .expect("the end thumb is grabbable");
        assert_eq!(
            grabbed.horiz.offset_at(grabbed.track.w, 0),
            0,
            "dragging the end thumb back reaches the start"
        );
    }

    #[test]
    fn a_horizontal_offset_never_moves_a_vertical_hit_or_the_plan() {
        let fonts = faces();
        let row: Vec<Vec<Run>> = (0..4)
            .map(|_| vec![run(&"y".repeat(60), Style::default())])
            .collect();
        let doc = Document {
            blocks: vec![Block::Table(Table {
                columns: vec![Align::Left; 4],
                header: row.clone(),
                rows: vec![row.clone(), row.clone()],
            })],
        };
        let plan = layout(&doc, &inputs(300, &fonts, &measure));
        let block = plan.tables[0].block;
        let h = plan.horizontal(block).unwrap();
        let height_before = plan.height;
        let rows_before = plan.tables[0].rows.len();
        for offset in [0, 40, h.max_offset()] {
            let off = |b: usize| if b == block { offset } else { 0 };
            let y = plan.tables[0].rows[1][0].rect.y + 1;
            assert_eq!(
                plan.hit_scrolled(20, y, off),
                plan.hit(20 + offset, y),
                "x follows the offset, y does not"
            );
        }
        assert_eq!(plan.height, height_before, "scrolling never re-lays out");
        assert_eq!(plan.tables[0].rows.len(), rows_before);
    }

    #[test]
    fn a_task_marker_is_checked_or_unchecked_and_a_scrollable_block_reserves_its_rail() {
        let fonts = faces();
        let item = |checked| {
            Block::ListItem(crate::ListItem {
                kind: crate::ListKind::Unordered,
                ordinal: 0,
                depth: 0,
                checked,
                runs: vec![run("task", Style::default())],
            })
        };
        let doc = Document {
            blocks: vec![
                item(Some(true)),
                item(Some(false)),
                item(None),
                Block::Code {
                    language: None,
                    text: "x".repeat(60),
                    spans: Vec::new(),
                },
            ],
        };
        let plan = layout(&doc, &inputs(200, &fonts, &measure));
        assert_eq!(plan.blocks[0].prefix.as_ref().unwrap().0, "☑");
        assert_eq!(plan.blocks[1].prefix.as_ref().unwrap().0, "☐");
        assert_eq!(plan.blocks[2].prefix.as_ref().unwrap().0, "•");

        // A scrollable block's rail is **part of its height**: the last
        // line ends above the reserved band.
        let code = &plan.blocks[3];
        let handle = handle_height(1.0);
        assert!(code.horizontal.is_some());
        assert_eq!(code.rect.h, 16 + handle, "one 16px line plus the rail");
        let last = code.lines.last().unwrap();
        assert_eq!(
            last.rect.y + last.rect.h,
            code.rect.y + code.rect.h - handle,
            "the thumb never covers a glyph"
        );
    }

    #[test]
    fn a_list_marker_and_a_quote_indent_take_space_from_the_text() {
        let fonts = faces();
        let doc = Document {
            blocks: vec![
                Block::ListItem(crate::ListItem {
                    kind: crate::ListKind::Ordered,
                    ordinal: 7,
                    depth: 1,
                    checked: None,
                    runs: vec![run("item", Style::default())],
                }),
                Block::Quote {
                    depth: 2,
                    runs: vec![run("quote", Style::default())],
                },
            ],
        };
        let plan = layout(&doc, &inputs(400, &fonts, &measure));
        let prefix = &plan.blocks[0].prefix.as_ref().unwrap().0;
        assert_eq!(prefix, "7.");
        assert!(plan.blocks[0].lines[0].rect.x >= 16);
        assert!(plan.blocks[1].lines[0].rect.x >= 32);
    }

    /// Every piece on a line starts where the previous one ended; the
    /// first one starts at the line's own left. This is the production
    /// geometry the host draw consumes, not a mirror of the code.
    fn assert_pieces_are_placed(runs: &[Run], lines: &[Line], left: i32, width: i32) {
        let mut joined = String::new();
        for line in lines {
            let mut x = left;
            for piece in &line.pieces {
                assert_eq!(
                    piece.rect.x, x,
                    "piece {:?} starts at the line's next position",
                    &runs[piece.run].text[piece.text.clone()]
                );
                // Only a **single glyph wider than the whole line** may
                // overflow: a multi-character chunk that overruns is a
                // positioning bug, not an exception.
                let text = &runs[piece.run].text[piece.text.clone()];
                let single_glyph_overflow = text.chars().count() == 1
                    && piece.rect.x == left
                    && piece.rect.w > width;
                assert!(
                    piece.rect.x + piece.rect.w <= left + width || single_glyph_overflow,
                    "piece {text:?} stays inside the line's content width"
                );
                x = piece.rect.x + piece.rect.w;
                joined.push_str(&runs[piece.run].text[piece.text.clone()]);
            }
        }
        // The pieces carry every non-separator character exactly once, in
        // order. Spaces used as soft-break separators and the source's own
        // line terminators are the only ones absent.
        let squash = |text: &str| -> String {
            text.chars().filter(|c| !c.is_whitespace()).collect()
        };
        let source: String = runs.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(
            squash(&joined),
            squash(&source),
            "recomposing the pieces loses or repeats text"
        );
    }

    #[test]
    fn a_wrapped_paragraph_places_each_piece_at_the_previous_end() {
        let fonts = faces();
        let runs = vec![
            run("abcdefghij", Style::default()),
            run("klmnopqrst", Style::default()),
        ];
        let doc = Document {
            blocks: vec![Block::Paragraph(runs.clone())],
        };
        let plan = layout(&doc, &inputs(21, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        assert!(lines.len() > 1, "the fixture must wrap");
        assert_pieces_are_placed(&runs, lines, 0, 21);
    }

    #[test]
    fn chinese_a_hard_break_and_a_run_that_starts_too_late_wrap_at_the_left() {
        let fonts = faces();
        // Chinese breaks between characters; the run after the break
        // starts on a fresh line even though its first character did not
        // fit at the end of the previous line.
        let runs = vec![
            run("中文多行验收一二三四五六", Style::default()),
            run("尾run首字", Style::default()),
        ];
        let doc = Document {
            blocks: vec![Block::Paragraph(runs.clone())],
        };
        let plan = layout(&doc, &inputs(35, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        assert!(lines.len() > 1);
        assert_pieces_are_placed(&runs, lines, 0, 35);

        // A source hard break is its own line and resets the position.
        let hard = vec![run("ab\ncd", Style::default())];
        let doc = Document {
            blocks: vec![Block::Paragraph(hard.clone())],
        };
        let plan = layout(&doc, &inputs(100, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        assert_eq!(lines.len(), 2);
        assert_pieces_are_placed(&hard, lines, 0, 100);
        assert_eq!(lines[0].pieces[0].rect.x, 0);
        assert_eq!(lines[1].pieces[0].rect.x, 0);
    }

    #[test]
    fn a_second_blocks_pieces_are_in_its_own_space_not_the_plans() {
        use std::sync::Arc;
        let fonts = faces();
        let first = vec![run("first paragraph", Style::default())];
        let second = vec![
            run("see ", Style::default()),
            run(
                "f",
                Style {
                    link: Some(Arc::from("/abs/file")),
                    link_raw: Some(Arc::from("/abs/file")),
                    ..Style::default()
                },
            ),
            run(" now", Style::default()),
        ];
        let doc = Document {
            blocks: vec![
                Block::Paragraph(first),
                Block::Paragraph(second.clone()),
            ],
        };
        let plan = layout(&doc, &inputs(300, &fonts, &measure));
        let block = &plan.blocks[1];
        assert!(block.rect.y > 0, "{:?}", block.rect);
        let piece = block
            .lines
            .iter()
            .flat_map(|l| &l.pieces)
            .find(|p| p.run == 1)
            .expect("the link's piece");
        // **Block-relative**: a block's first line starts at 0 even though
        // the block begins at `block.rect.y` in the plan. The host's link
        // hit must subtract that offset; comparing a plan y directly is
        // the defect task 2978 B reported (a link in the second block
        // could never be clicked).
        assert_eq!(piece.rect.y, 0, "{:?}", piece.rect);
        let x = piece.rect.x + 1;
        let plan_y = block.rect.y + piece.rect.y + 1;
        assert!(piece.rect.contains(x, plan_y - block.rect.y));
        assert!(
            !piece.rect.contains(x, plan_y),
            "a plan y compared directly must not be taken as the answer"
        );
    }

    #[test]
    fn a_wrapped_table_cell_starts_inside_its_padding() {
        let fonts = faces();
        let row = vec![vec![run(&"x".repeat(40), Style::default())]];
        let doc = Document {
            blocks: vec![Block::Table(Table {
                columns: vec![Align::Left],
                header: vec![vec![run("header_a", Style::default())]],
                rows: vec![row],
            })],
        };
        let plan = layout(&doc, &inputs(300, &fonts, &measure));
        let cell = &plan.tables[0].rows[0][0];
        let left = cell.rect.x + 8;
        let width = cell.rect.w - 16;
        assert!(cell.lines.len() > 1, "the cell must wrap");
        let runs = vec![run(&"x".repeat(40), Style::default())];
        assert_pieces_are_placed(&runs, &cell.lines, left, width);
    }

    #[test]
    fn an_english_space_breakback_keeps_every_line_and_character() {
        let fonts = faces();
        let runs = vec![run("ab cdefghij", Style::default())];
        let doc = Document {
            blocks: vec![Block::Paragraph(runs.clone())],
        };
        // 7px a character: "ab cd" is exactly 35, and the overflow is
        // reached after several characters, so the space fallback has to
        // put the line back at its start while rescanning from "c".
        let plan = layout(&doc, &inputs(35, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        let texts: Vec<String> = lines
            .iter()
            .map(|line| {
                line.pieces
                    .iter()
                    .map(|p| &runs[p.run].text[p.text.clone()])
                    .collect::<String>()
            })
            .collect();
        assert_eq!(texts, vec!["ab", "cdefg", "hij"]);
        assert_pieces_are_placed(&runs, lines, 0, 35);
    }

    #[test]
    fn a_run_that_starts_at_the_exact_end_wraps_with_its_own_style() {
        let fonts = faces();
        let runs = vec![
            run("abc", Style::default()),
            run(
                "d",
                Style {
                    strong: true,
                    ..Style::default()
                },
            ),
        ];
        let doc = Document {
            blocks: vec![Block::Paragraph(runs.clone())],
        };
        // "abc" fills the 21px line exactly; the strong run's first (and
        // only) character starts the next line, with its own face.
        let plan = layout(&doc, &inputs(21, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        assert_eq!(lines.len(), 2, "the second run starts a new line");
        assert_eq!(lines[0].pieces[0].rect.x, 0);
        assert_eq!(lines[0].pieces.last().unwrap().rect.x + lines[0].pieces.last().unwrap().rect.w, 21);
        let first = &lines[1].pieces[0];
        assert_eq!(first.rect.x, 0, "the wrapped run starts at the line left");
        assert_eq!(first.run, 1, "the run identity is kept");
        assert_eq!(first.kind, FontKind::Strong, "the style keeps its face");
        assert_eq!(&runs[first.run].text[first.text.clone()], "d");
        let joined: String = lines
            .iter()
            .flat_map(|l| l.pieces.iter())
            .map(|p| &runs[p.run].text[p.text.clone()])
            .collect();
        assert_eq!(joined, "abcd", "the wrapped character appears exactly once");
    }

    #[test]
    fn crlf_and_a_single_oversized_glyph_advance() {
        let fonts = faces();
        let hard = vec![run("ab\r\ncd", Style::default())];
        let doc = Document {
            blocks: vec![Block::Paragraph(hard.clone())],
        };
        let plan = layout(&doc, &inputs(100, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        assert_eq!(lines.len(), 2, "CRLF is one hard break");
        assert_eq!(lines[0].pieces[0].rect.x, 0);
        assert_eq!(lines[1].pieces[0].rect.x, 0);
        assert_pieces_are_placed(&hard, lines, 0, 100);

        // One glyph wider than the whole line is an explicit, advancing
        // overflow: it becomes its own piece and the next glyph moves on.
        let wide = vec![run("中a", Style::default())];
        let doc = Document {
            blocks: vec![Block::Paragraph(wide.clone())],
        };
        let plan = layout(&doc, &inputs(5, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        assert_eq!(lines.len(), 2, "each glyph advances; no stall");
        assert_eq!(lines[0].pieces[0].rect.x, 0);
        assert_eq!(&wide[lines[0].pieces[0].run].text[lines[0].pieces[0].text.clone()], "中");
        assert_eq!(lines[0].pieces[0].text.len(), 3, "one UTF-8 glyph, whole");
        assert_eq!(lines[1].pieces[0].rect.x, 0);
        assert_eq!(&wide[lines[1].pieces[0].run].text[lines[1].pieces[0].text.clone()], "a");
        assert_pieces_are_placed(&wide, lines, 0, 5);
    }

    #[test]
    fn a_table_is_found_by_its_source_block_after_other_blocks() {
        let fonts = faces();
        let table_a = Table {
            columns: vec![Align::Left, Align::Left, Align::Left],
            header: vec![
                vec![run("header_a", Style::default())],
                vec![],
                vec![run("LAST_A", Style::default())],
            ],
            rows: vec![vec![
                vec![run(&"x".repeat(60), Style::default())],
                vec![],
                vec![run("last_a", Style::default())],
            ]],
        };
        let table_b = Table {
            columns: vec![Align::Left, Align::Left, Align::Left],
            header: vec![
                vec![run("TABLE_B", Style::default())],
                vec![],
                vec![run("LAST_B", Style::default())],
            ],
            rows: vec![vec![
                vec![run(&"y".repeat(60), Style::default())],
                vec![],
                vec![run("last_b", Style::default())],
            ]],
        };
        let doc = Document {
            blocks: vec![
                Block::Paragraph(vec![run("before", Style::default())]),
                Block::Table(table_a),
                Block::Paragraph(vec![run("between", Style::default())]),
                Block::Table(table_b),
            ],
        };
        let plan = layout(&doc, &inputs(300, &fonts, &measure));
        let table_blocks: Vec<usize> = plan
            .blocks
            .iter()
            .enumerate()
            .filter(|(_, b)| matches!(b.kind, BlockKind::Table))
            .map(|(i, _)| i)
            .collect();
        assert_eq!(table_blocks, vec![1, 3], "tables are not the first blocks");

        // The host's entry: each table is found by its **source block
        // index**, and each is the right table with its own rectangles.
        let a = plan.table_at(table_blocks[0]).expect("table A by block index");
        assert_eq!(a.block, 1);
        assert!(!a.header[0].lines.is_empty(), "header_a is present");
        assert!(a.header[1].lines.is_empty(), "the empty header cell stays");
        assert!(a.rows[0][1].lines.is_empty(), "the empty body cell stays");
        assert!(a.horizontal.is_some(), "the wide table keeps its range");
        let b = plan.table_at(table_blocks[1]).expect("table B by block index");
        assert_eq!(b.block, 3);
        assert!(!std::ptr::eq(a, b), "different blocks are different tables");
        assert_ne!(a.header[0].rect.y, b.header[0].rect.y);

        // What the old host indexing did: a block index is not a table
        // ordinal -- it finds table B (or nothing) for A, and nothing for
        // B's own block.
        assert!(plan.tables.get(1).is_some_and(|t| t.block != 1));
        assert!(plan.tables.get(3).is_none());
        assert!(plan.table_at(0).is_none(), "a paragraph names no table");
    }

    #[test]
    fn code_pieces_are_absolute_ranges_into_the_whole_block() {
        let fonts = faces();
        let source = "first = 001\n中文第二行\n\nCODE_LAST_LINE";
        let doc = Document {
            blocks: vec![Block::Code {
                language: None,
                text: source.to_owned(),
                spans: Vec::new(),
            }],
        };
        let plan = layout(&doc, &inputs(2000, &fonts, &measure));
        let lines = &plan.blocks[0].lines;
        let expected = ["first = 001", "中文第二行", "", "CODE_LAST_LINE"];
        assert_eq!(lines.len(), expected.len(), "empty and last lines kept");
        let mut ranges = Vec::new();
        for (line, want) in lines.iter().zip(expected) {
            let piece = &line.pieces[0];
            let got = source.get(piece.text.clone()).expect("a valid UTF-8 range");
            assert_eq!(got, want, "the draw's own code.get(range) sees this line");
            ranges.push(piece.text.clone());
        }
        for pair in ranges.windows(2) {
            assert!(
                pair[0].end < pair[1].start,
                "ranges advance past the separator"
            );
        }

        // CRLF: the separator is not a visible glyph either.
        let crlf = "a\r\nb";
        let doc = Document {
            blocks: vec![Block::Code {
                language: None,
                text: crlf.to_owned(),
                spans: Vec::new(),
            }],
        };
        let plan = layout(&doc, &inputs(200, &fonts, &measure));
        let got: Vec<&str> = plan.blocks[0]
            .lines
            .iter()
            .map(|l| crlf.get(l.pieces[0].text.clone()).unwrap())
            .collect();
        assert_eq!(got, vec!["a", "b"]);
    }
}
