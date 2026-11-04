//! The native chat page's row layout, apart from the window (task 2802,
//! W2b).
//!
//! **Pure.** Nothing here reads a clock, a screen or the core. The host
//! hands in the rows the feed holds, the width in pixels, the DPI and one
//! way to measure text; it gets back each row's height, its offset, the
//! rows actually in sight and how to keep a scroll anchor when the body
//! changes above the reader.
//!
//! **Measured once, not once per paint.** A row is re-measured only when
//! its own content version, the width or the DPI changes; an unchanged tick
//! measures nothing and draws from the cached heights. The host calls this
//! module with the same functions the tests do -- there is no second copy of
//! the wrap or the arithmetic.
//!
//! **Design constants are logical points, converted once.** Padding, the
//! gap between rows and the line height are taken from `look::font::BODY`
//! and the design's spacing and multiplied by the DPI scale in `Metrics`;
//! nothing downstream multiplies again. Widths and the scroll offset itself
//! are already pixels (`TreeRect`'s unit), so they pass through untouched.

use crate::layout;
use crate::look;

/// Space around the rows, in logical points.
pub const PAD_PT: f64 = 12.0;
/// Between one row's lines, in logical points.
pub const ROW_GAP_PT: f64 = 6.0;
/// A line's height as a multiple of the body size.
pub const LINE_FACTOR: f64 = 1.35;

/// The page's measurements at one DPI. **Built once per size change**; the
/// constants above are multiplied here and nowhere else.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Metrics {
    pub scale: f64,
    pub pad: i32,
    pub gap: i32,
    /// One line of body text.
    pub line: i32,
    /// The author line above a message.
    pub author: i32,
}

impl Metrics {
    pub fn for_dpi(dpi: i32) -> Metrics {
        let scale = dpi as f64 / 96.0;
        let line = (look::font::BODY * LINE_FACTOR * scale).round() as i32;
        Metrics {
            scale,
            pad: (PAD_PT * scale).round() as i32,
            gap: (ROW_GAP_PT * scale).round() as i32,
            line: line.max(1),
            author: line.max(1),
        }
    }
}

/// One row as the host has it: a stable display id, the content version
/// that bumps when its words change, and the words themselves.
pub struct RowInput<'a> {
    pub id: &'a str,
    pub version: u64,
    pub author: &'a str,
    pub text: &'a str,
}

/// The font a measurement was made in, **by the parameters that made it**
/// (`dpi`, size, weight, face) -- never a freshly created `HFONT` handle:
/// a new handle every paint would defeat the cache and say nothing about
/// the glyphs.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FontKey {
    pub dpi: i32,
    pub size_px: i32,
    pub weight: i32,
    pub face: String,
}

/// What one row's real font measured: the author line and the wrapped body
/// under it, in pixels. The host gets these from the selected font with the
/// same DrawText flags it draws with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Measured {
    pub author_height: i32,
    pub text_height: i32,
}

/// A measurement that could not be made. **A failure is not a zero**: an
/// `Ok(0, 0)` would be cached and a row would silently collapse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeasureError;

/// One row's place in the page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowBox {
    pub id: String,
    pub version: u64,
    /// Its top, in pixels, from the first row's top.
    pub top: i32,
    /// The whole row: author line, its text and the gap after it.
    pub height: i32,
    /// The author's single line, and the wrapped text under it. Kept so a
    /// paint draws the two without measuring again.
    pub author_height: i32,
    pub text_height: i32,
    /// The last measurement of this row failed. Its heights are a
    /// placeholder, and the next update measures it again.
    pub failed: bool,
}

/// The page of rows, with the heights the last measurement gave them.
#[derive(Debug, Default)]
pub struct Layout {
    width: i32,
    scale: f64,
    rows: Vec<RowBox>,
    /// The font the cached heights were measured in. Its parameters, not a
    /// handle: see `FontKey`.
    font: Option<FontKey>,
    /// Heights that may be reused, keyed by the same identity `update`
    /// checks: id, content version, width and font.
    cache: Vec<Cached>,
    /// How many times the last `update` asked the caller to measure. The
    /// host's tests use it to hold "an unchanged tick measures nothing".
    measured: usize,
}

#[derive(Debug, Clone)]
struct Cached {
    id: String,
    version: u64,
    width: i32,
    font: FontKey,
    author_height: i32,
    text_height: i32,
}

impl Layout {
    pub fn new() -> Layout {
        Layout::default()
    }

    pub fn rows(&self) -> &[RowBox] {
        &self.rows
    }

    pub fn width(&self) -> i32 {
        self.width
    }

    pub fn total(&self) -> i32 {
        self.rows.last().map_or(0, |r| r.top + r.height)
    }

    /// Measurements taken by the last `update`, not a running total.
    pub fn measured(&self) -> usize {
        self.measured
    }

    /// The rows in the order given, with heights measured only where they
    /// can have changed. Returns whether anything the host draws changed.
    pub fn update(
        &mut self,
        rows: &[RowInput],
        width: i32,
        metrics: &Metrics,
        measure: &dyn Fn(&str) -> i32,
    ) -> bool {
        self.measured = 0;
        let wide = width != self.width || metrics.scale != self.scale;
        self.width = width;
        self.scale = metrics.scale;
        self.font = None;

        let old: Vec<RowBox> = std::mem::take(&mut self.rows);
        let mut out: Vec<RowBox> = Vec::with_capacity(rows.len());
        let mut top = 0;
        for row in rows {
            // A row whose id is unchanged and whose own version, the width
            // and the scale are all unchanged keeps its measured height.
            let known = old
                .iter()
                .find(|r| r.id == row.id && r.version == row.version);
            let (author_height, text_height) = if !wide {
                if let Some(known) = known {
                    (known.author_height, known.text_height)
                } else {
                    self.measure_row(row, width, metrics, measure)
                }
            } else {
                self.measure_row(row, width, metrics, measure)
            };
            let body = author_height + text_height + metrics.gap;
            out.push(RowBox {
                id: row.id.to_owned(),
                version: row.version,
                top,
                height: body,
                author_height,
                text_height,
                failed: false,
            });
            top += body;
        }

        let changed = out != old;
        self.rows = out;
        changed
    }

    fn measure_row(
        &mut self,
        row: &RowInput,
        width: i32,
        metrics: &Metrics,
        measure: &dyn Fn(&str) -> i32,
    ) -> (i32, i32) {
        let _ = row.author; // The author line is one fixed line.
        let lines = wrap_to_width(row.text, width, measure);
        self.measured += lines.measured;
        (metrics.author, (lines.lines.max(1) as i32) * metrics.line)
    }

    /// The production update: **heights from the font that will draw
    /// them.**
    ///
    /// The host hands in the same selected font it draws with (`font`), the
    /// body's pixel width, and one callback that measures a row with that
    /// font and the same DrawText flags. An `Err` is a measurement that
    /// failed: the row keeps a one-line placeholder, is marked `failed`,
    /// and is **not** put in the cache, so the next update measures it
    /// again. Nothing else about the page moves.
    ///
    /// Cached heights are reused when the row's id, its content version,
    /// the width and the font are all unchanged; nothing is measured on an
    /// unchanged tick.
    pub fn update_measured(
        &mut self,
        rows: &[RowInput<'_>],
        width: i32,
        metrics: &Metrics,
        font: &FontKey,
        measure: &mut dyn FnMut(&RowInput<'_>, i32) -> Result<Measured, MeasureError>,
    ) -> bool {
        self.measured = 0;
        self.width = width;
        self.scale = metrics.scale;
        self.font = Some(font.clone());

        let old_rows = std::mem::take(&mut self.rows);
        let old_cache = std::mem::take(&mut self.cache);
        let mut out: Vec<RowBox> = Vec::with_capacity(rows.len());
        let mut cache: Vec<Cached> = Vec::with_capacity(rows.len());
        let mut top = 0i32;
        for row in rows {
            let reusable = old_cache.iter().find(|c| {
                c.id == row.id && c.version == row.version && c.width == width && &c.font == font
            });
            let measured = match reusable {
                Some(c) => Some(Measured {
                    author_height: c.author_height,
                    text_height: c.text_height,
                }),
                None => {
                    self.measured += 1;
                    measure(row, width).ok()
                }
            };
            let failed = measured.is_none();
            let m = measured.unwrap_or(Measured {
                // A placeholder while the host retries: one line, never a
                // successful cache entry.
                author_height: metrics.author,
                text_height: metrics.line,
            });
            let author_height = m.author_height.max(0);
            let text_height = m.text_height.max(0);
            let height = author_height
                .saturating_add(text_height)
                .saturating_add(metrics.gap);
            out.push(RowBox {
                id: row.id.to_owned(),
                version: row.version,
                top,
                height,
                author_height,
                text_height,
                failed,
            });
            top = top.saturating_add(height);
            if !failed {
                cache.push(Cached {
                    id: row.id.to_owned(),
                    version: row.version,
                    width,
                    font: font.clone(),
                    author_height,
                    text_height,
                });
            }
        }

        let changed = out != old_rows;
        self.rows = out;
        self.cache = cache;
        changed
    }

    /// The font the cached heights were measured in.
    pub fn font(&self) -> Option<&FontKey> {
        self.font.as_ref()
    }

    /// The rows in sight at `scroll`, plus one above and one below so a
    /// partly drawn neighbour is never a hole. Empty when there are none.
    pub fn visible(&self, scroll: i32, viewport: i32) -> std::ops::Range<usize> {
        if self.rows.is_empty() || viewport <= 0 {
            return 0..0;
        }
        let top = scroll;
        let bottom = scroll + viewport;
        let mut first = self.rows.len();
        let mut last = 0;
        for (i, row) in self.rows.iter().enumerate() {
            if row.top + row.height <= top {
                continue;
            }
            if row.top >= bottom {
                break;
            }
            first = first.min(i);
            last = i + 1;
        }
        if first >= self.rows.len() {
            return 0..0;
        }
        let first = first.saturating_sub(1);
        let last = (last + 1).min(self.rows.len());
        first..last
    }

    /// The row at the top of the view and how far into it the view starts:
    /// **the row id the contract anchors on**, never an index.
    pub fn anchor(&self, scroll: i32) -> Option<(&str, i32)> {
        let row = self
            .rows
            .iter()
            .rev()
            .find(|r| r.top <= scroll)
            .or_else(|| self.rows.first())?;
        Some((row.id.as_str(), scroll - row.top))
    }

    /// Where to scroll to put `id` at `offset` pixels below the view's top.
    /// `None` when that row is no longer kept (the window budget dropped it).
    pub fn scroll_for(&self, id: &str, offset: i32) -> Option<i32> {
        self.rows
            .iter()
            .find(|r| r.id == id)
            .map(|r| r.top + offset)
    }

    /// A scroll kept inside the content: never above the first row, never
    /// past the last.
    pub fn clamp(&self, scroll: i32, viewport: i32) -> i32 {
        let max = (self.total() - viewport).max(0);
        scroll.clamp(0, max)
    }
}

/// What one wrapped text came to.
struct Wrapped {
    lines: usize,
    measured: usize,
}

/// Wrap `text` to `width` pixels with the caller's measurement.
///
/// **Hard line breaks first.** The text a message carries is already
/// lines -- paragraphs and a table, separated by CRLF, a lone CR or LF --
/// and `layout::wrap` knows only width: handed the whole body it packs the
/// lines together and counts far too few. So the body is split at those
/// terminators and each logical line is wrapped with `layout::wrap`'s own
/// rule (Chinese breaks between any two characters, an English word that
/// does not fit goes down whole). The measurement is never handed a CR or
/// an LF.
///
/// An empty logical line is one line of height, wherever it is. A single
/// terminator at the very end does not add a blank line after it, while a
/// run of them keeps every blank between its ends. Empty text is one line.
fn wrap_to_width(text: &str, width: i32, measure: &dyn Fn(&str) -> i32) -> Wrapped {
    let calls = std::cell::Cell::new(0usize);
    let fits = |rest: &str| -> usize {
        calls.set(calls.get() + 1);
        fit_chars(rest, width, measure)
    };

    let bytes = text.as_bytes();
    let mut lines = 0usize;
    let mut start = 0usize;
    let mut i = 0usize;
    let mut any = false;
    while i < bytes.len() {
        let b = bytes[i];
        if b != b'\r' && b != b'\n' {
            i += 1;
            continue;
        }
        lines += layout::wrap(&text[start..i], &fits).len();
        any = true;
        // CRLF is one terminator, not two.
        if b == b'\r' && i + 1 < bytes.len() && bytes[i + 1] == b'\n' {
            i += 1;
        }
        i += 1;
        start = i;
    }
    // The text after the last terminator: a terminator at the very end
    // leaves nothing here, and that is not a line of its own. Empty text
    // has had no terminator at all and is one line.
    let tail = &text[start..];
    if !tail.is_empty() || !any {
        lines += layout::wrap(tail, &fits).len();
    }
    Wrapped {
        lines: lines.max(1),
        measured: calls.get(),
    }
}

/// How many characters of `text` fit in `width` pixels, measured by the
/// caller. Zero is answered as zero; `layout::wrap` moves at least one
/// character on.
fn fit_chars(text: &str, width: i32, measure: &dyn Fn(&str) -> i32) -> usize {
    let total = text.chars().count();
    if total == 0 || width <= 0 {
        return 0;
    }
    if measure(text) <= width {
        return total;
    }
    // Binary search the largest prefix that fits. Every probe is a char
    // boundary by construction.
    let mut lo = 0usize;
    let mut hi = total;
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        let at: usize = text
            .char_indices()
            .nth(mid)
            .map_or(text.len(), |(at, _)| at);
        if measure(&text[..at]) <= width {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    lo
}

/// What decides whether the native page may read at all. **The one list**:
/// the host fills it from its own window facts and this decides.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sight {
    /// The control room's tab is the one in front.
    pub room_tab: bool,
    /// The group's page is the Chat page.
    pub chat_page: bool,
    /// The frame and every window above it are shown.
    pub ancestors_visible: bool,
    /// The frame is minimised. `IsWindowVisible` stays true then, which is
    /// exactly why this is its own fact.
    pub iconic: bool,
    /// The page's rectangle, in pixels.
    pub rect_w: f64,
    pub rect_h: f64,
}

pub fn in_sight(s: &Sight) -> bool {
    s.room_tab
        && s.chat_page
        && s.ancestors_visible
        && !s.iconic
        && s.rect_w > 0.0
        && s.rect_h > 0.0
}

/// What the page shows when it has no rows of its own to show.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Load {
    Loading,
    Empty,
    Ready,
}

pub mod msg {
    use crate::n_;
    pub const LOADING: &str = n_("Loading");
    pub const EMPTY: &str = n_("No messages yet.");
    pub const READ_FAILED: &str = n_("The chat could not be read.");
    pub const UNAVAILABLE: &str = n_("This chat is not available now.");
    pub const TOO_LARGE: &str = n_("This page is too large to show.");
    pub const EXPIRED: &str = n_("This history has expired.");
    pub const UNSUPPORTED: &str = n_("This build cannot show the chat.");
    pub const MEASURE_FAILED: &str = n_("This message could not be measured.");
}

/// The sentence for a state with no rows. `None` for Ready: a ready page
/// with no rows draws no placeholder here.
pub fn load_word(load: Load) -> Option<&'static str> {
    match load {
        Load::Loading => Some(msg::LOADING),
        Load::Empty => Some(msg::EMPTY),
        Load::Ready => None,
    }
}

/// The sentence for a failure the feed kept. **The raw code is not product
/// copy**: it stays in the log; the page gets one of these.
pub fn trouble_word(code: &str) -> &'static str {
    match code {
        "Unsupported" => msg::UNSUPPORTED,
        "TooLarge" | "TooLargeTransport" => msg::TOO_LARGE,
        "Expired" | "NoSuchJob" => msg::EXPIRED,
        "NoSuchGroup" | "NotAMember" | "LogsClosed" => msg::UNAVAILABLE,
        _ => msg::READ_FAILED,
    }
}

// ------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    /// A measurement where every character is `10 * scale` wide, counting
    /// the calls it was asked for.
    fn measure(scale: i32) -> impl Fn(&str) -> i32 {
        move |text: &str| text.chars().count() as i32 * 10 * scale
    }

    fn counted(scale: i32) -> (impl Fn(&str) -> i32, std::rc::Rc<Cell<usize>>) {
        let calls = std::rc::Rc::new(Cell::new(0));
        let seen = calls.clone();
        let f = move |text: &str| {
            seen.set(seen.get() + 1);
            text.chars().count() as i32 * 10 * scale
        };
        (f, calls)
    }

    fn row<'a>(id: &'a str, version: u64, text: &'a str) -> RowInput<'a> {
        RowInput {
            id,
            version,
            author: "author",
            text,
        }
    }

    #[test]
    fn chinese_wraps_at_any_character_and_narrow_widths_make_more_lines() {
        let text = "开发者正在检查中文换行是否按宽度发生";
        let wide = wrap_to_width(text, 400, &measure(1));
        let narrow = wrap_to_width(text, 120, &measure(1));
        assert!(narrow.lines > wide.lines, "narrow must wrap more");
        assert!(wide.lines >= 1);
        // Every line fits the width it was given.
        let picked = layout::wrap(text, &|rest: &str| fit_chars(rest, 120, &measure(1)));
        for line in picked {
            assert!(measure(1)(&line) <= 120 || line.chars().count() == 1);
        }
    }

    #[test]
    fn dpi_is_applied_once_to_every_design_constant() {
        let one = Metrics::for_dpi(96);
        let two = Metrics::for_dpi(192);
        assert_eq!(one.scale, 1.0);
        assert_eq!(two.scale, 2.0);
        assert_eq!(two.pad, one.pad * 2);
        assert_eq!(two.gap, one.gap * 2);
        // Rounded once at each scale, so the doubled size can differ by a
        // pixel; a value scaled twice would be off by half of it.
        assert!((two.line - one.line * 2).abs() <= 1, "line {}", two.line);
        assert!((two.author - one.author * 2).abs() <= 1);
        // A row measured at 2x is twice as tall, not four times.
        let text = "one line";
        let m1 = Metrics::for_dpi(96);
        let m2 = Metrics::for_dpi(192);
        let h1 = {
            let mut l = Layout::new();
            l.update(&[row("a", 1, text)], 1000, &m1, &measure(1));
            l.total()
        };
        let h2 = {
            let mut l = Layout::new();
            l.update(&[row("a", 1, text)], 1000, &m2, &measure(2));
            l.total()
        };
        assert!((h2 - h1 * 2).abs() <= 2, "height {h2} vs {h1}");
    }

    #[test]
    fn an_unchanged_tick_measures_nothing() {
        let (f, calls) = counted(1);
        let m = Metrics::for_dpi(96);
        let rows = [row("a", 1, "hello"), row("b", 1, "world")];
        let mut layout = Layout::new();
        assert!(layout.update(&rows, 300, &m, &f));
        assert!(calls.get() > 0);
        assert!(layout.measured() > 0);

        calls.set(0);
        assert!(!layout.update(&rows, 300, &m, &f));
        assert_eq!(calls.get(), 0, "an unchanged tick must not measure");
        assert_eq!(layout.measured(), 0);
    }

    #[test]
    fn a_width_or_version_change_re_measures_that_row() {
        let (f, calls) = counted(1);
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        layout.update(&[row("a", 1, "hello")], 300, &m, &f);

        calls.set(0);
        layout.update(&[row("a", 1, "hello")], 120, &m, &f);
        assert!(calls.get() > 0, "a new width measures again");

        calls.set(0);
        layout.update(&[row("a", 2, "hello")], 120, &m, &f);
        assert!(calls.get() > 0, "a new version measures again");
    }

    #[test]
    fn only_the_rows_in_sight_and_one_each_side_are_offered() {
        let m = Metrics::for_dpi(96);
        // Ten rows, each with its own id.
        let rows: Vec<RowInput<'_>> = (0..10)
            .map(|_| row("r", 1, "x"))
            .enumerate()
            .map(|(i, mut r)| {
                r.id = Box::leak(format!("r{i}").into_boxed_str());
                r
            })
            .collect();
        let mut layout = Layout::new();
        layout.update(&rows, 300, &m, &measure(1));
        let h = layout.rows()[0].height;
        assert!(h > 0);
        // Scrolling to the middle of row 4: rows 3..6 plus one each side.
        let at = layout.rows()[4].top + 1;
        let seen = layout.visible(at, h);
        assert!(seen.start <= 3, "one above the first visible");
        assert!(seen.end >= 6, "one below the last visible");
        assert!(seen.end <= 10);
    }

    #[test]
    fn an_anchor_survives_a_front_insert_and_follows_its_row() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        layout.update(
            &[row("a", 1, "one"), row("b", 1, "two")],
            300,
            &m,
            &measure(1),
        );
        let scroll = layout.rows()[1].top;
        let (id, offset) = {
            let (id, offset) = layout.anchor(scroll).expect("an anchor");
            (id.to_owned(), offset)
        };
        assert_eq!(id, "b");
        assert_eq!(offset, 0);

        // A page arrives in front of the body; the same row is now lower.
        layout.update(
            &[row("z", 1, "zero"), row("a", 1, "one"), row("b", 1, "two")],
            300,
            &m,
            &measure(1),
        );
        let at = layout.scroll_for(&id, offset).expect("still kept");
        assert!(at > scroll, "the anchored row moved down with the insert");

        // The budget dropped it: there is no place to go back to.
        layout.update(&[row("z", 1, "zero")], 300, &m, &measure(1));
        assert_eq!(layout.scroll_for("b", 0), None);
    }

    #[test]
    fn a_scroll_is_kept_inside_the_content() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        layout.update(&[row("a", 1, "x")], 300, &m, &measure(1));
        assert_eq!(layout.clamp(-100, 10), 0);
        let total = layout.total();
        assert_eq!(layout.clamp(total + 1000, 10), (total - 10).max(0));
    }

    #[test]
    fn reading_needs_the_page_in_front_and_in_a_window_that_is_not_minimised() {
        let ok = Sight {
            room_tab: true,
            chat_page: true,
            ancestors_visible: true,
            iconic: false,
            rect_w: 400.0,
            rect_h: 300.0,
        };
        assert!(in_sight(&ok));
        for bad in [
            Sight {
                room_tab: false,
                ..ok
            },
            Sight {
                chat_page: false,
                ..ok
            },
            Sight {
                ancestors_visible: false,
                ..ok
            },
            Sight { iconic: true, ..ok },
            Sight { rect_w: 0.0, ..ok },
            Sight { rect_h: 0.0, ..ok },
        ] {
            assert!(!in_sight(&bad), "{bad:?} must not read");
        }
    }

    /// A fixture-shaped body: marker line, Chinese paragraph, a blank
    /// line, a two-row table and a closing line -- six logical lines.
    fn fixture_body() -> &'static str {
        "A001 摘要\n开发者检查中文正文是否按段落下移\n\n| 键 | 值 |\n| -- | -- |\n表格之后的尾行"
    }

    /// Measures characters but **refuses any CR or LF**: the callback must
    /// never be handed a terminator.
    fn measured_no_newlines(calls: &std::cell::Cell<usize>) -> impl Fn(&str) -> i32 + '_ {
        move |text: &str| {
            assert!(
                !text.contains('\n') && !text.contains('\r'),
                "measure saw {text:?}"
            );
            calls.set(calls.get() + 1);
            text.chars().count() as i32 * 10
        }
    }

    #[test]
    fn a_six_line_fixture_keeps_all_six_lines_through_the_production_layout() {
        let calls = std::cell::Cell::new(0usize);
        let measure = measured_no_newlines(&calls);
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        // Wide enough that no logical line needs a width break: the count
        // is the body's own six.
        layout.update(&[row("a", 1, fixture_body())], 10_000, &m, &measure);
        let first = &layout.rows()[0];
        assert_eq!(first.text_height, 6 * m.line, "six logical lines, not one");
        assert!(layout.measured() > 0);

        // And a second row starts below all of it.
        layout.update(
            &[row("a", 1, fixture_body()), row("b", 1, "second")],
            10_000,
            &m,
            &measure,
        );
        assert_eq!(layout.rows()[1].top, layout.rows()[0].height);
    }

    #[test]
    fn crlf_and_a_lone_cr_are_the_same_hard_break_and_blanks_are_kept() {
        let calls = std::cell::Cell::new(0usize);
        let measure = measured_no_newlines(&calls);
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let mut version = 0u64;
        let mut lines = |layout: &mut Layout, text: &str| -> i32 {
            // A different body is a different content version, as the feed
            // would say.
            version += 1;
            layout.update(&[row("a", version, text)], 10_000, &m, &measure);
            layout.rows()[0].text_height / m.line
        };
        assert_eq!(lines(&mut layout, "one\ntwo"), 2);
        assert_eq!(lines(&mut layout, "one\r\ntwo"), 2);
        assert_eq!(lines(&mut layout, "one\rtwo"), 2);
        // A blank line between two is kept...
        assert_eq!(lines(&mut layout, "one\n\ntwo"), 3);
        assert_eq!(lines(&mut layout, "one\r\n\r\ntwo"), 3);
        // ...a single terminator at the end is not a blank line...
        assert_eq!(lines(&mut layout, "one\ntwo\n"), 2);
        // ...and empty text is one line.
        assert_eq!(lines(&mut layout, ""), 1);
    }

    #[test]
    fn a_narrow_width_still_breaks_the_long_logical_line() {
        let calls = std::cell::Cell::new(0usize);
        let measure = measured_no_newlines(&calls);
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let text = "开发者正在检查中文换行是否按宽度发生";
        layout.update(&[row("a", 1, text)], 10_000, &m, &measure);
        let wide = layout.rows()[0].text_height;
        layout.update(&[row("a", 2, text)], 60, &m, &measure);
        let narrow = layout.rows()[0].text_height;
        assert!(narrow > wide, "narrow must wrap more: {narrow} vs {wide}");
    }

    fn font(face: &str) -> FontKey {
        FontKey {
            dpi: 96,
            size_px: 13,
            weight: 400,
            face: face.to_owned(),
        }
    }

    #[test]
    fn the_production_update_consumes_the_measured_heights_and_places_the_next_row() {
        let m = Metrics::for_dpi(96);
        assert_eq!(
            m.line, 18,
            "the model's fixed pitch is what must not be used"
        );
        let f = font("Segoe UI");
        let mut layout = Layout::new();
        let rows = [row("a", 1, "body"), row("b", 1, "next")];
        // The host's font says 21 for the author line and 126 for the body;
        // the model's fixed line is 18.
        let calls = std::cell::Cell::new(0usize);
        let mut measure = |_row: &RowInput<'_>, _width: i32| {
            calls.set(calls.get() + 1);
            Ok(Measured {
                author_height: 21,
                text_height: 126,
            })
        };
        layout.update_measured(&rows, 300, &m, &f, &mut measure);
        let first = &layout.rows()[0];
        assert_eq!(first.author_height, 21);
        assert_eq!(first.text_height, 126, "the real body height is consumed");
        assert_eq!(first.height, 21 + 126 + m.gap);
        assert_eq!(
            layout.rows()[1].top,
            first.height,
            "the next row starts below it"
        );
        assert_eq!(layout.total(), 2 * first.height);
        assert_eq!(calls.get(), 2);

        // The same identity measures nothing.
        let mut none = |_row: &RowInput<'_>, _width: i32| -> Result<Measured, MeasureError> {
            panic!("an unchanged tick must not measure")
        };
        layout.update_measured(&rows, 300, &m, &f, &mut none);
        assert_eq!(layout.measured(), 0);
    }

    #[test]
    fn a_width_or_font_change_measures_again() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let rows = [row("a", 1, "body")];
        let calls = std::cell::Cell::new(0usize);
        let mut measure = |_: &RowInput<'_>, _: i32| {
            calls.set(calls.get() + 1);
            Ok(Measured {
                author_height: 21,
                text_height: 126,
            })
        };
        layout.update_measured(&rows, 300, &m, &font("Segoe UI"), &mut measure);
        assert_eq!(calls.get(), 1);
        // A different width is a different measurement.
        layout.update_measured(&rows, 200, &m, &font("Segoe UI"), &mut measure);
        assert_eq!(calls.get(), 2);
        // So is a different font, even at the same width.
        layout.update_measured(&rows, 200, &m, &font("Microsoft YaHei UI"), &mut measure);
        assert_eq!(calls.get(), 3);
        // The font identity is the parameters, not a handle.
        assert_eq!(layout.font(), Some(&font("Microsoft YaHei UI")));
    }

    #[test]
    fn a_failed_measurement_is_not_cached_as_a_success() {
        let m = Metrics::for_dpi(96);
        let f = font("Segoe UI");
        let mut layout = Layout::new();
        let rows = [row("a", 1, "body")];
        let calls = std::cell::Cell::new(0usize);
        let mut fails = |_: &RowInput<'_>, _: i32| -> Result<Measured, MeasureError> {
            calls.set(calls.get() + 1);
            Err(MeasureError)
        };
        layout.update_measured(&rows, 300, &m, &f, &mut fails);
        assert!(layout.rows()[0].failed);
        assert_eq!(calls.get(), 1);
        // The placeholder does not stop the next update from trying, even
        // though everything else is unchanged.
        let mut works = |_: &RowInput<'_>, _: i32| -> Result<Measured, MeasureError> {
            calls.set(calls.get() + 1);
            Ok(Measured {
                author_height: 21,
                text_height: 126,
            })
        };
        layout.update_measured(&rows, 300, &m, &f, &mut works);
        assert_eq!(calls.get(), 2, "a failure must not be reused as a success");
        assert!(!layout.rows()[0].failed);
        assert_eq!(layout.rows()[0].text_height, 126);
    }

    #[test]
    fn the_page_says_a_state_and_not_a_raw_code() {
        assert_eq!(load_word(Load::Loading), Some(msg::LOADING));
        assert_eq!(load_word(Load::Empty), Some(msg::EMPTY));
        assert_eq!(load_word(Load::Ready), None);
        assert_eq!(trouble_word("Unsupported"), msg::UNSUPPORTED);
        assert_eq!(trouble_word("TooLarge"), msg::TOO_LARGE);
        assert_eq!(trouble_word("Expired"), msg::EXPIRED);
        assert_eq!(trouble_word("NoSuchGroup"), msg::UNAVAILABLE);
        // Unknown codes get a sentence, never the code itself.
        assert_eq!(trouble_word("SomethingNew"), msg::READ_FAILED);
        assert_ne!(trouble_word("SomethingNew"), "SomethingNew");
    }
}
