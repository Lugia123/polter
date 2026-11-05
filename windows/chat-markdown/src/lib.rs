//! A chat message as the blocks a native page draws (task 2802, W3a).
//!
//! **Parsing only.** No window, no core, no files, no network, no threads.
//! The official CommonMark parser is driven event by event, with exactly
//! three extensions on -- tables, strikethrough and task lists -- into a
//! small typed model the host can draw. Whatever the model cannot express
//! is a `PlainFallback`: the caller keeps showing the message's original
//! text, and nothing is silently dropped or half-parsed.
//!
//! A bounded LRU cache lives beside it: one identity (group, generation,
//! anchor, content version) per entry, 200 entries and 4 MiB for the whole
//! host. Keys and retained strings are counted by one `cost` function; a
//! fallback caches its reason only, never a second copy of the source.

use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use std::sync::Arc;

pub mod cache;
pub mod coordinator;
pub mod layout;
pub use cache::{Cache, Entry, Key};

/// What one message came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    Document(Document),
    /// The message cannot be shown as blocks. The caller keeps its source.
    PlainFallback(Reason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    /// A structure the model cannot express (a list item with several
    /// blocks, an extension switched off but present in the source).
    Unsupported,
    /// One of the parse bounds was reached.
    Limit,
}

/// The parse bounds. Checked before allocating the next structure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub input_bytes: usize,
    pub nesting: usize,
    pub blocks: usize,
    pub runs: usize,
    pub table_columns: usize,
    pub table_cells: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            input_bytes: 256 * 1024,
            nesting: 32,
            blocks: 4096,
            runs: 16_384,
            table_columns: 64,
            table_cells: 4096,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Document {
    pub blocks: Vec<Block>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Align {
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListKind {
    Unordered,
    Ordered,
}

/// One inline run. Styles stack; adjacent runs with the same style merge.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Style {
    pub strong: bool,
    pub emphasis: bool,
    pub strike: bool,
    pub code: bool,
    /// The link's destination as pulldown decoded it, **shared**: a long URL
    /// must not be copied once per styled run. Metadata only.
    pub link: Option<Arc<str>>,
    /// **The destination exactly as the message wrote it**, escapes and
    /// entities untouched. `None` when this parser cannot recover it; a
    /// caller must then not offer the link as a file reference.
    pub link_raw: Option<Arc<str>>,
}

/// One proven mapping between a byte range of displayed text and the
/// message source it came from.
///
/// `exact` means the two slices are byte-identical (a verbatim copy).
/// `false` means the display text is a decoded unit -- a backslash escape
/// or an entity -- and a source highlight maps to that whole unit. **A run
/// or code block with no span covering a piece is not highlighted**; this
/// model never guesses a character mapping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub text: std::ops::Range<usize>,
    pub source: std::ops::Range<usize>,
    pub exact: bool,
}

/// The display byte ranges of `spans` that a source byte range covers.
/// This is the one conversion the host paints from: raw hit range in,
/// rendered text range out. A partial overlap of a decoded unit maps to
/// the whole unit; an uncovered source range stays uncovered.
pub fn display_ranges(spans: &[Span], source: std::ops::Range<usize>) -> Vec<std::ops::Range<usize>> {
    let mut out = Vec::new();
    for span in spans {
        let start = source.start.max(span.source.start);
        let end = source.end.min(span.source.end);
        if start >= end {
            continue;
        }
        if span.exact {
            let at = span.text.start + (start - span.source.start);
            out.push(at..at + (end - start));
        } else {
            out.push(span.text.clone());
        }
    }
    out
}

/// The hit's byte ranges **inside `text[piece]`**, ordered and disjoint.
///
/// **One mapping for the ground and the word** (task 2997): the host paints
/// the `search_hit` rectangle from these ranges and inks the same bytes with
/// `search_hit_text`, so the two can never land on different characters.
/// A range whose ends are not character boundaries of the piece, or that
/// starts inside the range already returned, is dropped rather than guessed
/// at -- the same rule `display_ranges` follows for a decoded unit.
pub fn hit_ranges_in_piece(
    spans: &[Span],
    text: &str,
    piece: std::ops::Range<usize>,
    hits: &[std::ops::Range<usize>],
) -> Vec<std::ops::Range<usize>> {
    let mut out: Vec<std::ops::Range<usize>> = Vec::new();
    let Some(shown) = text.get(piece.clone()) else {
        return out;
    };
    for hit in hits {
        for range in display_ranges(spans, hit.clone()) {
            let start = range.start.max(piece.start);
            let end = range.end.min(piece.end);
            if start >= end {
                continue;
            }
            let a = start - piece.start;
            let b = end - piece.start;
            if !shown.is_char_boundary(a) || !shown.is_char_boundary(b) {
                continue;
            }
            if out.last().is_some_and(|last| a < last.end) {
                continue;
            }
            out.push(a..b);
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub text: String,
    pub style: Style,
    /// Where this run's text came from, when the parser could prove it.
    /// Empty means no part of this run may be highlighted.
    pub spans: Vec<Span>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListItem {
    pub kind: ListKind,
    /// The item's number in an ordered list; 0 for an unordered one.
    pub ordinal: u64,
    /// 1 for the outermost list.
    pub depth: usize,
    /// A task list marker, when one was present.
    pub checked: Option<bool>,
    pub runs: Vec<Run>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub columns: Vec<Align>,
    /// One cell per column; an empty cell is an empty run list.
    pub header: Vec<Vec<Run>>,
    pub rows: Vec<Vec<Vec<Run>>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Block {
    Paragraph(Vec<Run>),
    Heading {
        level: u8,
        runs: Vec<Run>,
    },
    ListItem(ListItem),
    Quote {
        depth: usize,
        runs: Vec<Run>,
    },
    Code {
        language: Option<String>,
        text: String,
        /// Source spans of `text` (see [`Span`]); empty means no highlight
        /// can be located in this block.
        spans: Vec<Span>,
    },
    Table(Table),
    Rule,
}

// ---------------------------------------------------------------- parsing

/// The destination of an inline link **as the source wrote it**.
///
/// `[label](a\ b "title")` keeps the backslash, `<a b>` keeps the angle
/// brackets removed (they are delimiters, not text), and a link form this
/// does not understand returns `None` rather than a guessed reconstruction.
fn raw_link_destination(source: &str, offset: usize) -> Option<String> {
    // **The current link's own source only.** Parse from its opening `[`,
    // through a balanced label, then its `(destination "title")`; never
    // search beyond the closing `)`, never pick up a later link.
    let s = source.get(offset..)?;
    let mut it = s.char_indices().peekable();
    let (_, first) = it.next()?;
    if first != '[' {
        return None; // reference/autolink has no inline destination here
    }
    let mut depth = 1usize;
    let mut escaped = false;
    let mut close = None;
    for (i, c) in it.by_ref() {
        if escaped {
            escaped = false;
            continue;
        }
        match c {
            '\\' => escaped = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    close = Some(i + c.len_utf8());
                    break;
                }
            }
            _ => {}
        }
    }
    let mut at = close?;
    if s.get(at..)?.chars().next()? != '(' {
        return None; // `[a][ref]` or a shortcut reference
    }
    at += 1;
    let rest = &s[at..];
    let mut chars = rest.char_indices().peekable();
    while chars.peek().is_some_and(|(_, c)| *c == ' ' || *c == '\t') {
        chars.next();
    }
    let (start, first) = *chars.peek()?;
    if first == '<' {
        chars.next();
        let mut out = String::new();
        let mut esc = false;
        for (_, c) in chars.by_ref() {
            if esc {
                out.push(c);
                esc = false;
                continue;
            }
            if c == '\\' {
                esc = true;
                out.push(c);
                continue;
            }
            if c == '>' {
                // The rest must be whitespace/title then `)`.
                let tail = &rest[chars.peek().map(|(i, _)| *i).unwrap_or(rest.len())..];
                if tail.trim_start().starts_with(')') || tail.trim_start().starts_with('"') {
                    return if out.is_empty() { None } else { Some(out) };
                }
                return None;
            }
            out.push(c);
        }
        return None;
    }
    let mut out = String::new();
    let mut esc = false;
    let mut parens = 0usize;
    let mut first_char = true;
    for (_, c) in chars {
        if first_char {
            first_char = false;
            let _ = start;
        }
        if esc {
            out.push(c);
            esc = false;
            continue;
        }
        match c {
            '\\' => {
                esc = true;
                out.push(c);
            }
            '(' => {
                parens += 1;
                out.push(c);
            }
            ')' if parens == 0 => break,
            ')' => {
                parens -= 1;
                out.push(c);
            }
            c if (c == ' ' || c == '\t') && parens == 0 => break,
            _ => out.push(c),
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}
/// Decode one `&...;` entity at the start of `s`: its byte length and the
/// character it renders. Unknown named entities return `None`, which stops
/// the mapping rather than inventing a character.
fn entity_at(s: &str) -> Option<(usize, char)> {
    let end = s.find(';')?;
    if end > 12 {
        return None;
    }
    let body = &s[1..end];
    let decoded = if let Some(hex) = body.strip_prefix("#x").or_else(|| body.strip_prefix("#X")) {
        char::from_u32(u32::from_str_radix(hex, 16).ok()?)?
    } else if let Some(dec) = body.strip_prefix('#') {
        char::from_u32(dec.parse::<u32>().ok()?)?
    } else {
        match body {
            "amp" => '&',
            "lt" => '<',
            "gt" => '>',
            "quot" => '"',
            "apos" => '\'',
            "nbsp" => '\u{a0}',
            _ => return None,
        }
    };
    Some((end + 1, decoded))
}

/// The source range that really holds `text` inside `range`: pulldown's
/// code events include their backtick fence, and a code block's text event
/// may carry indentation. The text itself is copied verbatim, so finding
/// it in the event's own source is exact rather than a reconstruction.
fn content_range(source: &str, range: std::ops::Range<usize>, text: &str) -> Option<std::ops::Range<usize>> {
    let src = source.get(range.clone())?;
    if src == text {
        return Some(range);
    }
    let at = src.find(text)?;
    Some(range.start + at..range.start + at + text.len())
}

/// Map one text event's decoded `text` back to its source range, one span
/// at a time. Returns spans with **text offsets relative to `text`**.
///
/// A verbatim stretch becomes one exact span. A backslash escape or an
/// entity becomes a non-exact unit (one decoded character over its source
/// unit). Anything the parser cannot explain stops the mapping there: the
/// rest of the event gets no span, so no highlight can land on a guess.
fn map_text(source: &str, range: std::ops::Range<usize>, text: &str) -> Vec<Span> {
    let Some(src) = source.get(range.clone()) else {
        return Vec::new();
    };
    if src == text {
        return vec![Span {
            text: 0..text.len(),
            source: range,
            exact: true,
        }];
    }
    let mut spans = Vec::new();
    let (mut so, mut to) = (0usize, 0usize);
    let mut exact: Option<(usize, usize)> = None;
    fn flush(spans: &mut Vec<Span>, exact: &mut Option<(usize, usize)>, src0: usize, to: usize, base: usize) {
        if let Some((s0, t0)) = exact.take() {
            if to > t0 {
                spans.push(Span {
                    text: t0..to,
                    source: base + s0..base + src0,
                    exact: true,
                });
            }
        }
    }
    while to < text.len() {
        let Some(tc) = text[to..].chars().next() else {
            break;
        };
        let tl = tc.len_utf8();
        if src[so..].starts_with(&text[to..to + tl]) {
            if exact.is_none() {
                exact = Some((so, to));
            }
            so += tl;
            to += tl;
            continue;
        }
        flush(&mut spans, &mut exact, so, to, range.start);
        if src[so..].starts_with('\\') {
            let rest = &src[so + 1..];
            if let Some(ec) = rest.chars().next() {
                if ec == tc {
                    spans.push(Span {
                        text: to..to + tl,
                        source: range.start + so..range.start + so + 1 + ec.len_utf8(),
                        exact: false,
                    });
                    so += 1 + ec.len_utf8();
                    to += tl;
                    continue;
                }
            }
        }
        if src[so..].starts_with('&') {
            if let Some((unit, decoded)) = entity_at(&src[so..]) {
                if decoded == tc {
                    spans.push(Span {
                        text: to..to + tl,
                        source: range.start + so..range.start + so + unit,
                        exact: false,
                    });
                    so += unit;
                    to += tl;
                    continue;
                }
            }
        }
        // Unknown transform: claim nothing from here on.
        return spans;
    }
    flush(&mut spans, &mut exact, so, to, range.start);
    spans
}

/// Parse `source` with the default bounds.
pub fn parse(source: &str) -> Parsed {
    parse_with_limits(source, Limits::default())
}

pub fn parse_with_limits(source: &str, limits: Limits) -> Parsed {
    if source.len() > limits.input_bytes {
        return Parsed::PlainFallback(Reason::Limit);
    }
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    let mut p = P::new(limits);
    p.source = source.to_owned();
    for (event, range) in Parser::new_ext(source, options).into_offset_iter() {
        if p.fallback.is_some() {
            break;
        }
        p.event(event, range);
    }
    match p.fallback {
        Some(reason) => Parsed::PlainFallback(reason),
        // **A non-empty message with no visible block is not an empty one**:
        // showing nothing would swallow whatever it held. The caller keeps
        // the source. Truly empty input is a valid empty document.
        None if !source.is_empty() && p.blocks.is_empty() => {
            Parsed::PlainFallback(Reason::Unsupported)
        }
        None => Parsed::Document(Document { blocks: p.blocks }),
    }
}

#[derive(Debug, Clone, Copy)]
struct ListCtx {
    kind: ListKind,
    next: u64,
    depth: usize,
}

struct ItemBuf {
    kind: ListKind,
    ordinal: u64,
    depth: usize,
    checked: Option<bool>,
    runs: Vec<Run>,
    paragraphs: usize,
}

struct CodeBuf {
    language: Option<String>,
    text: String,
    /// The code text's spans in the message source; the host maps a hit's
    /// raw range to a code line through these.
    spans: Vec<Span>,
}

struct TableBuf {
    columns: Vec<Align>,
    header: Option<Vec<Vec<Run>>>,
    rows: Vec<Vec<Vec<Run>>>,
    row: Option<Vec<Vec<Run>>>,
    cell: Option<Vec<Run>>,
    in_head: bool,
    header_seen: bool,
}

struct P {
    limits: Limits,
    /// The message text being parsed, for a link's original destination.
    source: String,
    blocks: Vec<Block>,
    runs: Vec<Run>,
    /// Complete style snapshots; the last is the style new runs get.
    styles: Vec<Style>,
    quote: usize,
    heading: Option<u8>,
    lists: Vec<ListCtx>,
    item: Option<ItemBuf>,
    code: Option<CodeBuf>,
    table: Option<TableBuf>,
    nesting: usize,
    runs_used: usize,
    blocks_used: usize,
    cells_used: usize,
    image_depth: usize,
    /// Parent `End(Item)` events whose item this model already closed when
    /// a nested list began: they have nothing left to push.
    closed_for_nested: usize,
    fallback: Option<Reason>,
}

impl P {
    fn new(limits: Limits) -> P {
        P {
            limits,
            source: String::new(),
            blocks: Vec::new(),
            runs: Vec::new(),
            styles: vec![Style::default()],
            quote: 0,
            heading: None,
            lists: Vec::new(),
            item: None,
            code: None,
            table: None,
            nesting: 0,
            runs_used: 0,
            blocks_used: 0,
            cells_used: 0,
            image_depth: 0,
            closed_for_nested: 0,
            fallback: None,
        }
    }

    fn fail(&mut self, reason: Reason) {
        if self.fallback.is_none() {
            self.fallback = Some(reason);
        }
    }

    fn style(&self) -> Style {
        self.styles.last().cloned().unwrap_or_default()
    }

    fn push_style(&mut self, change: impl FnOnce(&mut Style)) {
        let mut next = self.style();
        change(&mut next);
        self.styles.push(next);
    }

    fn pop_style(&mut self) {
        if self.styles.len() > 1 {
            self.styles.pop();
        }
    }

    fn push_run_mapped(&mut self, text: &str, spans: Vec<Span>) {
        if text.is_empty() {
            return;
        }
        if self.runs_used + 1 > self.limits.runs {
            return self.fail(Reason::Limit);
        }
        let style = self.style();
        let target: &mut Vec<Run> =
            if let Some(cell) = self.table.as_mut().and_then(|t| t.cell.as_mut()) {
                cell
            } else if let Some(item) = self.item.as_mut() {
                &mut item.runs
            } else {
                &mut self.runs
            };
        if let Some(last) = target.last_mut() {
            if last.style == style {
                let base = last.text.len();
                last.text.push_str(text);
                for span in spans {
                    last.spans.push(Span {
                        text: base + span.text.start..base + span.text.end,
                        ..span
                    });
                }
                return;
            }
        }
        self.runs_used += 1;
        target.push(Run {
            text: text.to_owned(),
            style,
            spans,
        });
    }

    fn push_block(&mut self, block: Block) {
        if self.blocks_used + 1 > self.limits.blocks {
            return self.fail(Reason::Limit);
        }
        self.blocks_used += 1;
        self.blocks.push(block);
    }

    fn push_item(&mut self, item: ItemBuf) {
        if let Some(list) = self.lists.last_mut() {
            if list.kind == ListKind::Ordered {
                list.next = list.next.saturating_add(1);
            }
        }
        self.push_block(Block::ListItem(ListItem {
            kind: item.kind,
            ordinal: item.ordinal,
            depth: item.depth,
            checked: item.checked,
            runs: item.runs,
        }));
    }

    fn flush(&mut self, as_quote: bool) {
        if self.runs.is_empty() {
            return;
        }
        let runs = std::mem::take(&mut self.runs);
        if as_quote {
            let depth = self.quote.max(1);
            self.push_block(Block::Quote { depth, runs });
        } else {
            self.push_block(Block::Paragraph(runs));
        }
    }

    fn enter(&mut self) {
        self.nesting += 1;
        if self.nesting > self.limits.nesting {
            self.fail(Reason::Limit);
        }
    }

    fn leave(&mut self) {
        self.nesting = self.nesting.saturating_sub(1);
    }

    fn event(&mut self, event: Event<'_>, range: std::ops::Range<usize>) {
        match event {
            Event::Start(tag) => self.start(tag, range.start),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => {
                // **Mapped before the code/item/run buffer is borrowed**:
                // the source is this parser's, and the spans are absolute.
                let spans = map_text(&self.source, range, &text);
                if self.code.is_some() {
                    if let Some(code) = self.code.as_mut() {
                        let base = code.text.len();
                        code.text.push_str(&text);
                        for span in spans {
                            code.spans.push(Span {
                                text: base + span.text.start..base + span.text.end,
                                ..span
                            });
                        }
                    }
                } else {
                    self.push_run_mapped(&text, spans);
                }
            }
            Event::Code(text) => {
                // The event's range includes its backtick fence; the text
                // itself is verbatim inside it.
                let spans = content_range(&self.source, range, &text)
                    .map(|r| map_text(&self.source, r, &text))
                    .unwrap_or_default();
                self.push_style(|s| s.code = true);
                self.push_run_mapped(&text, spans);
                self.pop_style();
            }
            Event::SoftBreak | Event::HardBreak => {
                let spans = map_text(&self.source, range, "\n");
                if self.code.is_some() {
                    if let Some(code) = self.code.as_mut() {
                        let base = code.text.len();
                        code.text.push('\n');
                        for span in spans {
                            code.spans.push(Span {
                                text: base + span.text.start..base + span.text.end,
                                ..span
                            });
                        }
                    }
                } else {
                    self.push_run_mapped("\n", spans);
                }
            }
            Event::Rule => {
                self.flush(self.quote > 0);
                self.push_block(Block::Rule);
            }
            Event::Html(text) | Event::InlineHtml(text) => {
                let spans = map_text(&self.source, range, &text);
                self.push_run_mapped(&text, spans);
            }
            Event::TaskListMarker(checked) => match self.item.as_mut() {
                Some(item) => item.checked = Some(checked),
                None => self.fail(Reason::Unsupported),
            },
            // Not switched on above; if one ever arrives it is not silently
            // dropped.
            Event::InlineMath(_) | Event::DisplayMath(_) | Event::FootnoteReference(_) => {
                self.fail(Reason::Unsupported)
            }
        }
    }

    fn start(&mut self, tag: Tag<'_>, offset: usize) {
        // **Every tag is a level**, inline and image and paragraph too:
        // one counter for the whole event stack, not only blocks.
        self.enter();
        match tag {
            Tag::Paragraph => {
                if self.item.is_some() {
                    if let Some(item) = self.item.as_mut() {
                        item.paragraphs += 1;
                        if item.paragraphs > 1 {
                            self.fail(Reason::Unsupported);
                        }
                    }
                } else {
                    self.flush(self.quote > 0);
                }
            }
            Tag::Heading { level, .. } => {
                if self.item.is_some() || self.table.is_some() {
                    return self.fail(Reason::Unsupported);
                }
                self.flush(self.quote > 0);
                self.heading = Some(match level {
                    HeadingLevel::H1 => 1,
                    HeadingLevel::H2 => 2,
                    HeadingLevel::H3 => 3,
                    HeadingLevel::H4 => 4,
                    HeadingLevel::H5 => 5,
                    HeadingLevel::H6 => 6,
                });
            }
            Tag::BlockQuote(_) => {
                if self.item.is_some() || self.table.is_some() {
                    return self.fail(Reason::Unsupported);
                }
                self.flush(true);
                self.quote += 1;
            }
            Tag::CodeBlock(kind) => {
                if self.item.is_some() || self.table.is_some() {
                    return self.fail(Reason::Unsupported);
                }
                self.flush(self.quote > 0);
                let language = match kind {
                    CodeBlockKind::Fenced(info) => info
                        .split_whitespace()
                        .next()
                        .filter(|w| !w.is_empty())
                        .map(|w| w.to_owned()),
                    CodeBlockKind::Indented => None,
                };
                self.code = Some(CodeBuf {
                    language,
                    text: String::new(),
                    spans: Vec::new(),
                });
            }
            Tag::HtmlBlock => {}
            Tag::List(start) => {
                // **A nested list is its own run of items at a greater
                // depth.** The item it was inside is closed first, and the
                // `End(Item)` that will still arrive for it is consumed by
                // `closed_for_nested`.
                if let Some(item) = self.item.take() {
                    self.push_item(item);
                    self.closed_for_nested += 1;
                }
                self.flush(self.quote > 0);
                let depth = self.lists.len() + 1;
                let kind = if start.is_some() {
                    ListKind::Ordered
                } else {
                    ListKind::Unordered
                };
                self.lists.push(ListCtx {
                    kind,
                    next: start.unwrap_or(1),
                    depth,
                });
            }
            Tag::Item => {
                let Some(list) = self.lists.last().copied() else {
                    return self.fail(Reason::Unsupported);
                };
                let ordinal = if list.kind == ListKind::Ordered {
                    list.next
                } else {
                    0
                };
                self.flush(self.quote > 0);
                self.item = Some(ItemBuf {
                    kind: list.kind,
                    ordinal,
                    depth: list.depth,
                    checked: None,
                    runs: Vec::new(),
                    paragraphs: 0,
                });
            }
            Tag::Table(alignments) => {
                if self.item.is_some() || self.table.is_some() {
                    return self.fail(Reason::Unsupported);
                }
                self.flush(self.quote > 0);
                if alignments.len() > self.limits.table_columns {
                    return self.fail(Reason::Limit);
                }
                let columns = alignments
                    .into_iter()
                    .map(|a| match a {
                        Alignment::Center => Align::Center,
                        Alignment::Right => Align::Right,
                        _ => Align::Left,
                    })
                    .collect();
                self.table = Some(TableBuf {
                    columns,
                    header: None,
                    rows: Vec::new(),
                    row: None,
                    cell: None,
                    in_head: false,
                    header_seen: false,
                });
            }
            Tag::TableHead => {
                if let Some(table) = self.table.as_mut() {
                    table.in_head = true;
                    table.header_seen = true;
                } else {
                    self.fail(Reason::Unsupported);
                }
            }
            Tag::TableRow => {
                if let Some(table) = self.table.as_mut() {
                    table.row = Some(Vec::new());
                } else {
                    self.fail(Reason::Unsupported);
                }
            }
            Tag::TableCell => {
                let over = self.cells_used + 1 > self.limits.table_cells;
                if over {
                    return self.fail(Reason::Limit);
                }
                self.cells_used += 1;
                if let Some(table) = self.table.as_mut() {
                    // pulldown emits `TableHead` then `TableCell` directly,
                    // with no `TableRow`: the header's row is the first
                    // cell's, opened here.
                    if table.row.is_none() {
                        table.row = Some(Vec::new());
                    }
                    table.cell = Some(Vec::new());
                } else {
                    self.fail(Reason::Unsupported);
                }
            }
            Tag::Emphasis => self.push_style(|s| s.emphasis = true),
            Tag::Strong => self.push_style(|s| s.strong = true),
            Tag::Strikethrough => self.push_style(|s| s.strike = true),
            Tag::Link { dest_url, .. } => {
                let link: Arc<str> = Arc::from(dest_url.as_ref());
                let raw_link = raw_link_destination(&self.source, offset).map(Arc::from);
                self.push_style(move |s| {
                    s.link = Some(link.clone());
                    s.link_raw = raw_link.clone();
                });
            }
            Tag::Image { .. } => {
                // Alt text is the image here; nothing is fetched or decoded.
                self.image_depth += 1;
            }
            // Extensions switched off; named so a future Options change
            // falls back instead of dropping the structure.
            Tag::FootnoteDefinition(_)
            | Tag::MetadataBlock(_)
            | Tag::DefinitionList
            | Tag::DefinitionListTitle
            | Tag::DefinitionListDefinition
            | Tag::Superscript
            | Tag::Subscript => self.fail(Reason::Unsupported),
        }
    }

    fn end(&mut self, tag: TagEnd) {
        self.leave();
        match tag {
            TagEnd::Paragraph => {
                if self.item.is_none() {
                    self.flush(self.quote > 0);
                }
            }
            TagEnd::Heading(_) => {
                let level = self.heading.take().unwrap_or(1);
                let runs = std::mem::take(&mut self.runs);
                self.push_block(Block::Heading { level, runs });
            }
            TagEnd::BlockQuote(_) => {
                self.flush(true);
                self.quote = self.quote.saturating_sub(1);
            }
            TagEnd::CodeBlock => {
                if let Some(code) = self.code.take() {
                    self.push_block(Block::Code {
                        language: code.language,
                        text: code.text,
                        spans: code.spans,
                    });
                }
            }
            TagEnd::HtmlBlock => self.flush(self.quote > 0),
            TagEnd::List(ordered) => {
                self.lists.pop();
                let _ = ordered;
            }
            TagEnd::Item => {
                let Some(item) = self.item.take() else {
                    if self.closed_for_nested > 0 {
                        self.closed_for_nested -= 1;
                        return;
                    }
                    return self.fail(Reason::Unsupported);
                };
                self.push_item(item);
            }
            TagEnd::Table => {
                let Some(table) = self.table.take() else {
                    return self.fail(Reason::Unsupported);
                };
                let mut header = table.header.unwrap_or_default();
                if !header.is_empty() && header.len() != table.columns.len() {
                    return self.fail(Reason::Unsupported);
                }
                if header.is_empty() {
                    // The model keeps a header as wide as the table; a
                    // parser that gave none gets empty cells, not a shape
                    // that cannot be drawn.
                    header = (0..table.columns.len()).map(|_| Vec::new()).collect();
                }
                self.push_block(Block::Table(Table {
                    columns: table.columns,
                    header,
                    rows: table.rows,
                }));
            }
            TagEnd::TableHead => {
                if let Some(table) = self.table.as_mut() {
                    if table.header.is_none() {
                        if let Some(row) = table.row.take() {
                            table.header = Some(row);
                        }
                    }
                    table.in_head = false;
                }
            }
            TagEnd::TableRow => {
                if let Some(table) = self.table.as_mut() {
                    if let Some(row) = table.row.take() {
                        if row.len() != table.columns.len() {
                            return self.fail(Reason::Unsupported);
                        }
                        if table.in_head {
                            table.header = Some(row);
                        } else {
                            table.rows.push(row);
                        }
                    }
                }
            }
            TagEnd::TableCell => {
                if let Some(table) = self.table.as_mut() {
                    if let (Some(cell), Some(row)) = (table.cell.take(), table.row.as_mut()) {
                        row.push(cell);
                    }
                }
            }
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough | TagEnd::Link => {
                self.pop_style()
            }
            TagEnd::Image => self.image_depth = self.image_depth.saturating_sub(1),
            TagEnd::FootnoteDefinition
            | TagEnd::MetadataBlock(_)
            | TagEnd::DefinitionList
            | TagEnd::DefinitionListTitle
            | TagEnd::DefinitionListDefinition
            | TagEnd::Superscript
            | TagEnd::Subscript => self.fail(Reason::Unsupported),
        }
    }
}

impl ListItem {
    pub fn checked(&self) -> Option<bool> {
        self.checked
    }
}

/// Kept for callers that want the whole message's text without blocks: the
/// concatenated runs in reading order, with the source's line breaks.
pub fn visible_text(document: &Document) -> String {
    let mut out = String::new();
    for block in &document.blocks {
        match block {
            Block::Paragraph(runs) | Block::Heading { runs, .. } | Block::Quote { runs, .. } => {
                runs_text(runs, &mut out)
            }
            Block::ListItem(item) => runs_text(&item.runs, &mut out),
            Block::Code { text, .. } => out.push_str(text),
            Block::Table(table) => {
                for cell in &table.header {
                    runs_text(cell, &mut out);
                    out.push('\t');
                }
                out.push('\n');
                for row in &table.rows {
                    for cell in row {
                        runs_text(cell, &mut out);
                        out.push('\t');
                    }
                    out.push('\n');
                }
            }
            Block::Rule => out.push_str("---"),
        }
        out.push('\n');
    }
    out
}

fn runs_text(runs: &[Run], out: &mut String) {
    for run in runs {
        out.push_str(&run.text);
    }
}

#[cfg(test)]
mod tests;
