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
/// The scrollbar's track width, in logical points.
pub const BAR_W_PT: f64 = 10.0;
/// The gap between the track and the window's right edge, in logical points.
pub const BAR_GAP_PT: f64 = 6.0;
/// The thumb is never shorter than this, in logical points.
pub const THUMB_MIN_PT: f64 = 36.0;

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
    /// The date divider above the first message of a local day.
    pub date: i32,
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
            date: line.max(1),
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
    /// This row starts a local day: one divider line above it.
    pub date: bool,
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
    /// The date divider above this row, when it starts a local day.
    pub date: bool,
    pub date_height: i32,
    /// The last measurement of this row failed. Its heights are a
    /// placeholder, and the next update measures it again.
    pub failed: bool,
    /// Where the last published height came from.
    pub source: Option<Source>,
    /// **The structured semantic identity** that height was measured for:
    /// the message's group, canonical anchor and content version, the
    /// document it came from, and the width/DPI/font it was measured with.
    /// Never a delimited string, so an opaque group or anchor that contains
    /// the delimiter cannot be mistaken for another field.
    pub identity: Option<Identity>,
    /// An old published height kept as temporary geometry while a new
    /// semantic is waiting its turn. **Stale is not a cache hit**: it is
    /// readable geometry until the row is republished.
    pub stale: bool,
    /// Never published at all: a placeholder, not a successful height.
    pub placeholder: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Raw,
    Markdown,
}

/// What a published height is semantically: **all fields, no delimiter**.
/// The row's display id is deliberately absent -- it is the row's own
/// identity (`RowBox.id`), kept separately so a live `l:` row that history
/// later names by its canonical `p:` anchor stays the same row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    /// The message's group, opaque.
    pub group: String,
    pub generation: u64,
    /// The **canonical** anchor, opaque. Not the feed row id.
    pub anchor: String,
    /// The message's content version.
    pub version: u64,
    /// The document identity (the host's `Arc<Document>` pointer); 0 for a
    /// height measured from the original text.
    pub doc: usize,
    pub width: i32,
    pub dpi: i32,
    /// The host's font-semantics id (face, size, weight, DPI), not a font
    /// handle.
    pub font: u64,
}

/// A row as the publisher names it: the **stable feed row id** and the
/// content version, exactly as `Layout` was given them.
#[derive(Debug, Clone, Copy)]
pub struct RowIdentity<'a> {
    pub id: &'a str,
    pub version: u64,
    /// This row starts a local day: one divider line above it.
    pub date: bool,
}

/// One row's newly measured height, for one semantic.
#[derive(Debug, Clone, Copy)]
pub struct PublishedHeight<'a> {
    /// The stable feed row id -- the same string `Layout` was given, never
    /// the canonical anchor.
    pub id: &'a str,
    pub version: u64,
    pub source: Source,
    /// The complete structured semantic this height was measured for.
    pub identity: &'a Identity,
    pub author_height: i32,
    pub text_height: i32,
}

/// One row in sight, as the host found it this tick: its stable feed id,
/// its content version, the complete semantic its current content,
/// document, size and font imply, and whether the source that semantic
/// draws from is actually in hand.
#[derive(Debug, Clone)]
pub struct Candidate {
    pub id: String,
    pub version: u64,
    pub identity: Identity,
    /// **Can this row be drawn from that semantic right now?** A raw row
    /// always can (its original text is in the feed). A Markdown row can
    /// only when a view plan for exactly this identity is still held --
    /// not merely when the document is still cached. Kept explicit, with
    /// no default, so a projection that forgets it cannot compile.
    pub draw_ready: bool,
}

/// **The host's one projection into a pure candidate.** `doc_cached` says
/// a parsed document for this key exists; `plan_present` says this view
/// still holds a plan measured for exactly this identity (same row id,
/// anchor, content version, document, width, DPI and font). Raw rows need
/// no plan; Markdown rows without one are not draw-ready, so `schedule`
/// cannot keep them `Fresh` while paint would have to show raw text.
pub fn view_candidate(
    id: &str,
    version: u64,
    identity: Identity,
    doc_cached: bool,
    plan_present: bool,
) -> Candidate {
    Candidate {
        id: id.to_owned(),
        version,
        draw_ready: !doc_cached || plan_present,
        identity,
    }
}

/// What the host should do with one candidate this tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Current semantics already published: keep it, spend no budget.
    Fresh,
    /// Semantics no longer match but this row did not get a measurement
    /// this tick: keep the old height as temporary geometry.
    Stale,
    /// Measure this row now and publish the replacement.
    Measure,
}

#[derive(Debug, Clone, Copy)]
pub struct PlanEntry<'a> {
    pub id: &'a str,
    pub version: u64,
    pub action: Action,
}

/// **What this tick should publish**, decided from what is already
/// published and what the host found in sight. The host uses this exact
/// function; a candidate whose full identity still matches is `Fresh` and
/// costs nothing, only a genuinely invalid row is `Stale` or measured, and
/// at most `budget` rows are told to measure. Candidates are visited in
/// page order, so the rows that miss this tick's budget are the next
/// tick's first: no first-four/next-four pair can starve the other.
pub fn schedule<'a>(
    rows: &[RowBox],
    candidates: &'a [Candidate],
    budget: usize,
) -> Vec<PlanEntry<'a>> {
    let mut left = budget;
    let mut out = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let old = rows
            .iter()
            .find(|r| r.id == candidate.id && r.version == candidate.version);
        let fresh = candidate.draw_ready
            && old.is_some_and(|r| {
                !r.stale
                    && !r.placeholder
                    && r.source.is_some()
                    && r.identity.as_ref() == Some(&candidate.identity)
            });
        let action = if fresh {
            Action::Fresh
        } else if left > 0 {
            left -= 1;
            Action::Measure
        } else {
            Action::Stale
        };
        out.push(PlanEntry {
            id: candidate.id.as_str(),
            version: candidate.version,
            action,
        });
    }
    out
}

/// What `publish` was told to do for one row. `KeepFresh` asserts the
/// published semantic is still current (and is not a claim that an
/// unmentioned row is invalid); `KeepStale` keeps an old height as
/// temporary geometry; `Replace` atomically installs a new measurement.
#[derive(Debug, Clone, Copy)]
pub enum Decision<'a> {
    KeepFresh { id: &'a str, version: u64 },
    KeepStale { id: &'a str, version: u64 },
    Replace(PublishedHeight<'a>),
}

/// **What a horizontal drag is bound to**: the complete message and plan
/// identity plus the block. A reused block index alone is never enough.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DragTarget {
    pub row_id: String,
    pub version: u64,
    /// The document identity (the host's `Arc<Document>` pointer).
    pub doc: usize,
    pub width: i32,
    pub dpi: i32,
    pub font: u64,
    pub block: usize,
}

/// One plan the view still holds, projected for the pure check: its
/// message/plan identity and which scrollable blocks it has.
pub struct HeldPlan<'a> {
    pub row_id: &'a str,
    pub version: u64,
    pub doc: usize,
    pub width: i32,
    pub dpi: i32,
    pub font: u64,
    pub blocks: &'a [usize],
}

impl DragTarget {
    /// Still a real target this tick? A row that left sight, a plan that
    /// was rebuilt at another size, a new document or a missing block all
    /// answer no.
    pub fn alive(&self, held: &[HeldPlan<'_>]) -> bool {
        held.iter().any(|p| {
            p.row_id == self.row_id
                && p.version == self.version
                && p.doc == self.doc
                && p.width == self.width
                && p.dpi == self.dpi
                && p.font == self.font
                && p.blocks.contains(&self.block)
        })
    }
}

/// **The explicit action a cancellation asks for**, never just a "did the
/// state change" bool. `#[must_use]`: a host call site that drops it would
/// silently keep the capture or skip a repaint. Merging is field-wise OR,
/// so a later step can never overwrite an earlier `true`.
#[must_use]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InputAction {
    pub release_own_capture: bool,
    pub invalidate: bool,
}

impl InputAction {
    pub const NONE: InputAction = InputAction {
        release_own_capture: false,
        invalidate: false,
    };

    pub fn merge(self, other: InputAction) -> InputAction {
        InputAction {
            release_own_capture: self.release_own_capture || other.release_own_capture,
            invalidate: self.invalidate || other.invalidate,
        }
    }

    pub fn release() -> InputAction {
        InputAction {
            release_own_capture: true,
            invalidate: false,
        }
    }

    pub fn invalidate() -> InputAction {
        InputAction {
            release_own_capture: false,
            invalidate: true,
        }
    }
}

/// The drag's pure state. **Cancel is a state action here**; releasing the
/// OS capture is the caller's separate step, after the borrow.
#[derive(Debug, Default)]
pub struct DragState {
    target: Option<DragTarget>,
}

impl DragState {
    pub fn start(&mut self, target: DragTarget) {
        self.target = Some(target);
    }

    pub fn target(&self) -> Option<&DragTarget> {
        self.target.as_ref()
    }

    /// The button came up: the drag ends. **This window's capture is still
    /// ours to release**, even when the drag was already cleared. A
    /// still-valid keyboard focus is kept by the caller.
    pub fn end(&mut self) -> InputAction {
        let had = self.target.take().is_some();
        InputAction {
            release_own_capture: true,
            invalidate: had,
        }
    }

    /// Hide, leave, close or `WM_CANCELMODE`: cancel and always ask for
    /// this window's capture to be released.
    pub fn cancel(&mut self) -> InputAction {
        let had = self.target.take().is_some();
        InputAction {
            release_own_capture: true,
            invalidate: had,
        }
    }

    /// `WM_CAPTURECHANGED`: another window took the capture. Only forget
    /// our own drag; never release that other window's capture.
    pub fn capture_lost(&mut self) -> InputAction {
        let had = self.target.take().is_some();
        InputAction {
            release_own_capture: false,
            invalidate: had,
        }
    }

    /// Drop the drag when its complete target no longer exists. **A
    /// removed target asks for release**: whatever happened to the plan,
    /// this window may still own the capture.
    pub fn drop_dead(&mut self, held: &[HeldPlan<'_>]) -> InputAction {
        if self.target.as_ref().is_some_and(|t| !t.alive(held)) {
            self.target = None;
            InputAction {
                release_own_capture: true,
                invalidate: true,
            }
        } else {
            InputAction::NONE
        }
    }
}

/// Clear a focus that no longer has a target. A focus alone never owns the
/// capture, so this asks only for a repaint.
#[must_use]
pub fn drop_focus_if_dead(focus: &mut Option<DragTarget>, held: &[HeldPlan<'_>]) -> InputAction {
    if focus.as_ref().is_some_and(|t| !t.alive(held)) {
        *focus = None;
        InputAction::invalidate()
    } else {
        InputAction::NONE
    }
}

/// Keep every invalidation and release that any of the several cancel
/// paths asked for.
#[must_use]
pub fn action_or(actions: impl IntoIterator<Item = InputAction>) -> InputAction {
    actions
        .into_iter()
        .fold(InputAction::NONE, InputAction::merge)
}

/// The one helper the host calls after plans are retained: a dead drag or
/// focus is dropped and **both** requested effects come back.
#[must_use]
pub fn drop_dead_input(
    drag: &mut DragState,
    focus: &mut Option<DragTarget>,
    held: &[HeldPlan<'_>],
) -> InputAction {
    action_or([drag.drop_dead(held), drop_focus_if_dead(focus, held)])
}

/// Hide/leave/close/`WM_CANCELMODE`: cancel the drag and clear the focus,
/// always asking for this window's capture to be released.
#[must_use]
pub fn cancel_input(drag: &mut DragState, focus: &mut Option<DragTarget>) -> InputAction {
    let cleared_focus = focus.take().is_some();
    action_or([
        drag.cancel(),
        InputAction {
            release_own_capture: false,
            invalidate: cleared_focus,
        },
    ])
}

/// `WM_CAPTURECHANGED`: end the drag and update what is drawn, nothing
/// else. It **does not ask for a capture release** (the capture is already
/// gone, and it may belong to another window now) and it **cannot touch the
/// keyboard focus**: the capture and the keyboard's selected block are
/// separate, so a normal button-up release must not lose the target the
/// person just clicked. Only an explicit cancel or a dead target clears
/// focus (`cancel_input` / `drop_dead_input`).
#[must_use]
pub fn capture_lost_input(drag: &mut DragState) -> InputAction {
    drag.capture_lost()
}

impl<'a> Decision<'a> {
    pub fn id(&self) -> &'a str {
        match self {
            Decision::KeepFresh { id, .. } | Decision::KeepStale { id, .. } => id,
            Decision::Replace(p) => p.id,
        }
    }

    pub fn version(&self) -> u64 {
        match self {
            Decision::KeepFresh { version, .. } | Decision::KeepStale { version, .. } => *version,
            Decision::Replace(p) => p.version,
        }
    }
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
            let date_height = if row.date { metrics.date } else { 0 };
            let body = date_height + author_height + text_height + metrics.gap;
            out.push(RowBox {
                id: row.id.to_owned(),
                version: row.version,
                top,
                height: body,
                author_height,
                text_height,
                date: row.date,
                date_height,
                failed: false,
                source: None,
                identity: None,
                stale: false,
                placeholder: false,
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
            let date_height = if row.date { metrics.date } else { 0 };
            let height = date_height
                .saturating_add(author_height)
                .saturating_add(text_height)
                .saturating_add(metrics.gap);
            out.push(RowBox {
                id: row.id.to_owned(),
                version: row.version,
                top,
                height,
                author_height,
                text_height,
                date: row.date,
                date_height,
                failed,
                source: None,
                identity: None,
                stale: false,
                placeholder: false,
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

    /// **Publish this round's heights.** `rows` is the whole body in the
    /// feed's order (id and content version are the row identity, nothing
    /// more); `decisions` say, per row, whether its published semantic is
    /// still current (`KeepFresh`), has been invalidated but was not
    /// measured this tick (`KeepStale`), or was measured now (`Replace`).
    ///
    /// **A row with no decision is not invalid**: it keeps exactly what it
    /// had (including its fresh/stale flag). Only a row whose content
    /// version itself changed is treated as invalid, and even that keeps
    /// its old height as stale geometry. A row that has never been
    /// published gets a placeholder.
    ///
    /// The caller takes the scroll anchor before this and restores it by
    /// the same row id and offset after; `top`/`total`/`visible`/`clamp`
    /// all read the published geometry.
    pub fn publish(
        &mut self,
        rows: &[RowIdentity<'_>],
        decisions: &[Decision<'_>],
        metrics: &Metrics,
        width: i32,
    ) -> bool {
        let old_rows = std::mem::take(&mut self.rows);
        let mut out: Vec<RowBox> = Vec::with_capacity(rows.len());
        let mut top = 0i32;
        for row in rows {
            let decision = decisions
                .iter()
                .find(|d| d.id() == row.id && d.version() == row.version);
            let exact = old_rows
                .iter()
                .find(|r| r.id == row.id && r.version == row.version);
            let same_id = old_rows.iter().find(|r| r.id == row.id);
            let date_height = if row.date { metrics.date } else { 0 };
            let (author_height, text_height, source, identity, stale, placeholder, failed) =
                match (decision, exact, same_id) {
                    (Some(Decision::Replace(u)), _, _) => (
                        u.author_height.max(0),
                        u.text_height.max(0),
                        Some(u.source),
                        Some(u.identity.clone()),
                        false,
                        false,
                        false,
                    ),
                    (Some(Decision::KeepFresh { .. }), Some(o), _) if !o.placeholder => (
                        o.author_height,
                        o.text_height,
                        o.source,
                        o.identity.clone(),
                        false,
                        false,
                        o.failed,
                    ),
                    (Some(Decision::KeepStale { .. }), Some(o), _) if !o.placeholder => (
                        o.author_height,
                        o.text_height,
                        o.source,
                        o.identity.clone(),
                        true,
                        false,
                        o.failed,
                    ),
                    // KeepStale for a **new content version** of a row we
                    // already have: the old height is still the best
                    // readable geometry, but the version is now the row's
                    // current one and the old identity no longer describes
                    // it. Only a row with no old id at all is a placeholder.
                    (Some(Decision::KeepStale { .. }), _, Some(o)) if !o.placeholder => (
                        o.author_height,
                        o.text_height,
                        o.source,
                        None,
                        true,
                        false,
                        o.failed,
                    ),
                    // No decision and the same content version: keep the
                    // published state untouched -- absent is not invalid.
                    (None, Some(o), _) => (
                        o.author_height,
                        o.text_height,
                        o.source,
                        o.identity.clone(),
                        o.stale,
                        o.placeholder,
                        o.failed,
                    ),
                    // Same row id but a new content version: the old height
                    // is no longer this row's semantic. Keep it as stale
                    // geometry until its turn, never as a fresh hit.
                    (None, None, Some(o)) if !o.placeholder => (
                        o.author_height,
                        o.text_height,
                        o.source,
                        None,
                        true,
                        false,
                        o.failed,
                    ),
                    _ => (
                        metrics.author.max(0),
                        metrics.line.max(0),
                        None,
                        None,
                        false,
                        true,
                        false,
                    ),
                };
            let height = date_height
                .saturating_add(author_height)
                .saturating_add(text_height)
                .saturating_add(metrics.gap);
            out.push(RowBox {
                id: row.id.to_owned(),
                version: row.version,
                top,
                height,
                author_height,
                text_height,
                date: row.date,
                date_height,
                failed,
                source,
                identity,
                stale,
                placeholder,
            });
            top = top.saturating_add(height);
        }
        let changed = out != old_rows;
        self.rows = out;
        self.width = width;
        changed
    }

    /// The row at `scroll`, plus one above and one below so a
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

    /// **The fallback when the row a view was anchored to is gone** (the
    /// window budget dropped it): the published row whose top is nearest
    /// `at`. A view lands beside where it was instead of jumping to the
    /// top, and the host records the fallback once rather than silently
    /// re-anchoring. A measured row is preferred over a failed one.
    pub fn nearest_measured(&self, at: i32) -> Option<i32> {
        let nearest = |measured: bool| {
            self.rows
                .iter()
                .filter(|r| !r.placeholder && (!measured || !r.failed))
                .min_by_key(|r| r.top.saturating_sub(at).saturating_abs())
                .map(|r| r.top)
        };
        nearest(true).or_else(|| nearest(false))
    }

    /// A scroll kept inside the content: never above the first row, never
    /// past the last.
    pub fn clamp(&self, scroll: i32, viewport: i32) -> i32 {
        let max = (self.total() - viewport).max(0);
        scroll.clamp(0, max)
    }

    /// How many rows the viewport covers at `scroll`, at least one.
    fn in_sight_rows(&self, scroll: i32, viewport: i32) -> usize {
        let bottom = scroll.saturating_add(viewport);
        self.rows
            .iter()
            .filter(|r| r.top.saturating_add(r.height) > scroll && r.top < bottom)
            .count()
            .max(1)
    }

    /// Where `scroll` sits in the loaded map, 0..=1: **the top row's index
    /// plus how far into that row the view starts**, normalised by how far
    /// the top row can travel (the rows below the viewport). Rows are the
    /// unit; `log_seq` never enters this, and neither does anything the
    /// bar would have to read.
    pub fn position(&self, scroll: i32, viewport: i32) -> Option<f64> {
        if self.rows.is_empty() || viewport <= 0 {
            return None;
        }
        let i = self.rows.iter().rposition(|r| r.top <= scroll).unwrap_or(0);
        let row = &self.rows[i];
        let frac = if row.height > 0 {
            ((scroll - row.top) as f64 / row.height as f64).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let span = self.rows.len() as f64 - self.in_sight_rows(scroll, viewport) as f64;
        if span <= 0.0 {
            return Some(0.0);
        }
        Some(((i as f64 + frac) / span).clamp(0.0, 1.0))
    }

    /// The scroll that puts the view at `ratio` of the loaded map -- the
    /// inverse of `position`, used by a drag. **It never leaves the loaded
    /// map**: there is nothing beyond the rows the feed holds to drag to.
    pub fn scroll_at_ratio(&self, ratio: f64, viewport: i32) -> Option<i32> {
        if self.rows.is_empty() || viewport <= 0 {
            return None;
        }
        let span = (self.rows.len() as f64 - self.in_sight_rows(0, viewport) as f64).max(0.0);
        let at = (ratio.clamp(0.0, 1.0) * span).min(self.rows.len() as f64 - f64::EPSILON);
        let index = at.floor().max(0.0) as usize;
        let row = &self.rows[index.min(self.rows.len() - 1)];
        let frac = at - index as f64;
        Some(row.top.saturating_add((frac * row.height as f64).round() as i32))
    }

    /// The bar for `track`: its thumb sized by the rows in sight and
    /// placed by `position`. **`ticks` is the loaded row count** -- what
    /// the bar is graduated in.
    pub fn string_bar(
        &self,
        scroll: i32,
        viewport: i32,
        track: (i32, i32, i32, i32),
        min_thumb: i32,
    ) -> Option<StringBar> {
        let (x, y, w, h) = track;
        if self.rows.is_empty() || viewport <= 0 || h <= 0 {
            return None;
        }
        let in_sight = self.in_sight_rows(scroll, viewport);
        let thumb_h = (((h as i64 * in_sight as i64) / self.rows.len() as i64) as i32)
            .max(min_thumb)
            .min(h);
        let span = (h - thumb_h).max(0);
        let pos = self.position(scroll, viewport).unwrap_or(0.0);
        let thumb_y = y + ((pos * span as f64).round() as i32).clamp(0, span);
        Some(StringBar {
            track: (x, y, w, h),
            thumb_y,
            thumb_h,
            ticks: self.rows.len(),
        })
    }
}

/// One vertical scrollbar's geometry. **Graduated in loaded rows**: the
/// thumb's place is the top row's index plus its fraction, its size is the
/// share of rows in sight. No `log_seq`, no message text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StringBar {
    pub track: (i32, i32, i32, i32),
    pub thumb_y: i32,
    pub thumb_h: i32,
    /// The loaded row count.
    pub ticks: usize,
}

impl RowBox {
    /// **Paint's one criterion.** Only a Markdown height that is fresh and
    /// was measured for exactly `current` (same group, canonical anchor,
    /// content version, document, width, DPI and font) may draw its plan;
    /// a stale row -- including the whole window after a resize, before the
    /// tick has republished anything -- draws raw text inside the published
    /// rectangle. Reading the height never measures anything.
    ///
    /// The row's display id is checked separately by the caller: `current`
    /// deliberately carries the canonical anchor, not the id.
    pub fn draws(&self, current: &Identity) -> bool {
        self.source == Some(Source::Markdown)
            && !self.stale
            && !self.placeholder
            && self.identity.as_ref() == Some(current)
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
    /// The core cancelled the scan before it answered about the history.
    /// **Not Empty**: the group may well have records.
    Cancelled,
    /// Records in the captured range could not be read, so an empty page
    /// is not an empty group.
    Gap,
}

pub mod msg {
    use crate::n_;
    pub const LOADING: &str = n_("Loading");
    pub const CANCELLED: &str = n_("Loading was cancelled.");
    pub const GAP: &str = n_("Some records could not be read.");
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
        Load::Cancelled => Some(msg::CANCELLED),
        Load::Gap => Some(msg::GAP),
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
            date: false,
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

    fn identity(group: &str, anchor: &str, version: u64, doc: usize, width: i32) -> Identity {
        Identity {
            group: group.to_owned(),
            generation: 7,
            anchor: anchor.to_owned(),
            version,
            doc,
            width,
            dpi: 96,
            font: 5,
        }
    }

    fn replace<'a>(
        id: &'a str,
        version: u64,
        source: Source,
        identity: &'a Identity,
        text_height: i32,
    ) -> Decision<'a> {
        Decision::Replace(PublishedHeight {
            id,
            version,
            source,
            identity,
            author_height: 21,
            text_height,
        })
    }

    #[test]
    fn published_plan_heights_drive_top_total_visible_clamp_and_keep_the_anchor() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let raw = identity("g", "a", 1, 0, 300);
        let plan = identity("g", "b", 1, 0x1000, 300);
        let rows = [
            RowIdentity {
                id: "a",
                version: 1,
                date: false,
            },
            RowIdentity {
                id: "b",
                version: 1,
                date: false,
            },
            RowIdentity {
                id: "c",
                version: 1,
                date: false,
            },
        ];
        // Raw first: a measured, b measured, c never.
        layout.publish(
            &rows,
            &[
                replace("a", 1, Source::Raw, &raw, 100),
                replace("b", 1, Source::Raw, &raw, 50),
            ],
            &m,
            300,
        );
        assert!(layout.rows()[2].placeholder);
        let raw_total = layout.total();
        assert_eq!(layout.rows()[1].top, 21 + 100 + m.gap);
        let anchor = {
            let (id, off) = layout.anchor(layout.rows()[1].top).unwrap();
            (id.to_owned(), off)
        };
        assert_eq!(anchor.0, "b");

        // The same content version republished from a Markdown plan, taller.
        layout.publish(
            &rows,
            &[replace("b", 1, Source::Markdown, &plan, 300)],
            &m,
            300,
        );
        assert!(layout.total() > raw_total, "plan height drives total");
        assert_eq!(layout.rows()[1].text_height, 300);
        assert_eq!(layout.rows()[1].source, Some(Source::Markdown));
        assert_eq!(layout.rows()[1].top, 21 + 100 + m.gap);
        // **No decision is not invalid**: a keeps its fresh published
        // height, it is not marked stale just because b was republished.
        assert!(
            !layout.rows()[0].stale,
            "absence of an update is not invalidity"
        );
        assert_eq!(layout.rows()[0].text_height, 100, "kept its height");
        // The anchor still names the same row and offset, from the old id.
        let scroll = layout.scroll_for(&anchor.0, anchor.1).expect("still kept");
        assert_eq!(layout.anchor(scroll).unwrap().0, "b");
        // visible/clamp read the new geometry.
        let v = layout.visible(layout.rows()[1].top + 1, m.line);
        assert!(v.contains(&1));
        assert_eq!(layout.clamp(layout.total(), 100), layout.total() - 100);
    }

    #[test]
    fn schedule_finishes_more_than_eight_candidates_without_starving_or_repeating() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let ids: Vec<String> = (0..10).map(|i| format!("r{i}")).collect();
        let rows: Vec<RowIdentity<'_>> = ids
            .iter()
            .map(|id| RowIdentity {
                id,
                version: 1,
                date: false,
            })
            .collect();
        let identities: Vec<Identity> = ids.iter().map(|id| identity("g", id, 1, 0, 300)).collect();
        let candidates: Vec<Candidate> = ids
            .iter()
            .zip(&identities)
            .map(|(id, identity)| view_candidate(id, 1, identity.clone(), false, false))
            .collect();

        let mut rounds = 0;
        loop {
            let plan = schedule(layout.rows(), &candidates, 4);
            let measuring: Vec<&PlanEntry<'_>> = plan
                .iter()
                .filter(|e| e.action == Action::Measure)
                .collect();
            let decisions: Vec<Decision<'_>> = plan
                .iter()
                .map(|entry| match entry.action {
                    Action::Fresh => Decision::KeepFresh {
                        id: entry.id,
                        version: entry.version,
                    },
                    Action::Stale => Decision::KeepStale {
                        id: entry.id,
                        version: entry.version,
                    },
                    Action::Measure => {
                        let at = ids.iter().position(|id| id == entry.id).unwrap();
                        replace(
                            entry.id,
                            entry.version,
                            Source::Markdown,
                            &identities[at],
                            100 + at as i32,
                        )
                    }
                })
                .collect();
            layout.publish(&rows, &decisions, &m, 300);
            if measuring.is_empty() {
                break;
            }
            assert!(
                measuring.len() <= 4,
                "more than four expensive measurements in one tick"
            );
            rounds += 1;
            assert!(rounds <= 4, "ten candidates must finish within four ticks");
        }
        assert_eq!(rounds, 3, "10 candidates at 4 a tick");
        assert!(
            layout.rows().iter().all(|r| !r.placeholder && !r.stale),
            "every candidate finished"
        );
        // The semantic is now stable: no further tick measures anything.
        let quiet = schedule(layout.rows(), &candidates, 4);
        assert!(
            quiet.iter().all(|e| e.action == Action::Fresh),
            "an unchanged tick must measure nothing"
        );
    }

    #[test]
    fn a_resize_keeps_unmeasured_rows_old_heights_instead_of_collapsing_them() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let ids: Vec<String> = (0..10).map(|i| format!("r{i}")).collect();
        let rows: Vec<RowIdentity<'_>> = ids
            .iter()
            .map(|id| RowIdentity {
                id,
                version: 1,
                date: false,
            })
            .collect();
        let old: Vec<Identity> = ids.iter().map(|id| identity("g", id, 1, 0, 300)).collect();
        let old_decisions: Vec<Decision<'_>> = rows
            .iter()
            .zip(&old)
            .map(|(r, identity)| replace(r.id, 1, Source::Raw, identity, 100))
            .collect();
        layout.publish(&rows, &old_decisions, &m, 300);
        let before: i32 = layout.total();

        // A resize: every candidate's width changed. One tick may measure
        // only four; the rest are told KeepStale, not placeholder.
        let new: Vec<Identity> = ids.iter().map(|id| identity("g", id, 1, 0, 200)).collect();
        let candidates: Vec<Candidate> = ids
            .iter()
            .zip(&new)
            .map(|(id, identity)| view_candidate(id, 1, identity.clone(), false, false))
            .collect();
        let plan = schedule(layout.rows(), &candidates, 4);
        let decisions: Vec<Decision<'_>> = plan
            .iter()
            .map(|entry| match entry.action {
                Action::Fresh => Decision::KeepFresh {
                    id: entry.id,
                    version: entry.version,
                },
                Action::Stale => Decision::KeepStale {
                    id: entry.id,
                    version: entry.version,
                },
                Action::Measure => {
                    let at = ids.iter().position(|id| id == entry.id).unwrap();
                    replace(entry.id, entry.version, Source::Raw, &new[at], 120)
                }
            })
            .collect();
        layout.publish(&rows, &decisions, &m, 200);
        assert!(layout.rows()[5].stale);
        assert!(!layout.rows()[5].placeholder);
        assert_eq!(
            layout.rows()[5].text_height,
            100,
            "not collapsed to a placeholder"
        );
        assert!(layout.total() > before / 2);
        // The anchor row is still findable by its stable id.
        assert!(layout.scroll_for(&ids[5], 0).is_some());
    }

    #[test]
    fn a_live_row_keeps_its_id_when_history_names_its_canonical_anchor() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        // The feed saw this message live (`l:`) and history later names the
        // same message by its canonical `p:` anchor. The display id must
        // stay `l:`; only the semantic identity carries `p:`.
        let rows = [RowIdentity {
            id: "l:row",
            version: 1,
            date: false,
        }];
        let live = identity("g|with|pipes", "p|canonical|anchor", 1, 0, 300);
        // The document is cached but no plan exists yet.
        let candidates = [view_candidate("l:row", 1, live.clone(), true, false)];
        let plan = schedule(layout.rows(), &candidates, 4);
        assert_eq!(plan[0].id, "l:row", "the anchor must not become the row id");
        assert_eq!(plan[0].action, Action::Measure);
        layout.publish(
            &rows,
            &[replace("l:row", 1, Source::Markdown, &live, 90)],
            &m,
            300,
        );
        assert_eq!(layout.rows()[0].id, "l:row");
        assert_eq!(
            layout.rows()[0].identity.as_ref().unwrap().anchor,
            "p|canonical|anchor"
        );

        // Still the same row, the same canonical name and the plan is in
        // hand: no remeasure.
        let kept = [view_candidate("l:row", 1, live.clone(), true, true)];
        let again = schedule(layout.rows(), &kept, 4);
        assert_eq!(again[0].action, Action::Fresh);

        // A row whose *id* is the canonical anchor is a different row: it
        // must not inherit the `l:` row's height.
        let other = [view_candidate(
            "p|canonical|anchor",
            1,
            live.clone(),
            true,
            true,
        )];
        let other_plan = schedule(layout.rows(), &other, 4);
        assert_eq!(other_plan[0].action, Action::Measure);
    }

    #[test]
    fn a_resize_before_the_tick_draws_raw_not_the_old_plan() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let old = identity("g", "a", 1, 0x2000, 300);
        layout.publish(
            &[RowIdentity {
                id: "a",
                version: 1,
                date: false,
            }],
            &[replace("a", 1, Source::Markdown, &old, 90)],
            &m,
            300,
        );
        // A paint at the old size, with a matching plan, may draw.
        assert!(layout.rows()[0].draws(&old));
        // A paint after the resize but before the tick: the published
        // identity has the old width, so the old plan must not be drawn.
        let resized = identity("g", "a", 1, 0x2000, 200);
        assert!(!layout.rows()[0].draws(&resized));
        // A different document at the same size is not the published one.
        let other_doc = identity("g", "a", 1, 0x3000, 300);
        assert!(!layout.rows()[0].draws(&other_doc));
        // A raw height never draws a plan even with a matching identity.
        let mut raw_layout = Layout::new();
        raw_layout.publish(
            &[RowIdentity {
                id: "a",
                version: 1,
                date: false,
            }],
            &[replace("a", 1, Source::Raw, &old, 90)],
            &m,
            300,
        );
        assert!(!raw_layout.rows()[0].draws(&old));
    }

    #[test]
    fn a_released_plan_is_rebuilt_when_the_row_scrolls_back() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let md = identity("g", "a", 1, 0x4000, 300);
        let rows = [RowIdentity {
            id: "a",
            version: 1,
            date: false,
        }];
        layout.publish(
            &rows,
            &[replace("a", 1, Source::Markdown, &md, 300)],
            &m,
            300,
        );
        // In sight with the plan in hand: nothing to do.
        let present = [view_candidate("a", 1, md.clone(), true, true)];
        assert_eq!(
            schedule(layout.rows(), &present, 4)[0].action,
            Action::Fresh
        );

        // The row left the window: the view released the plan, but the
        // document is still cached. It is **not** Fresh -- a Fresh row
        // would keep its tall height while paint had to fall back to raw.
        let away = [view_candidate("a", 1, md.clone(), true, false)];
        assert_eq!(schedule(layout.rows(), &away, 4)[0].action, Action::Measure);

        // Scrolled back: the host rebuilds the plan for the same document
        // and republishes the same height.
        layout.publish(
            &rows,
            &[replace("a", 1, Source::Markdown, &md, 300)],
            &m,
            300,
        );
        let back = [view_candidate("a", 1, md.clone(), true, true)];
        for _ in 0..3 {
            assert_eq!(schedule(layout.rows(), &back, 4)[0].action, Action::Fresh);
        }
    }

    #[test]
    fn a_burst_of_version_changes_keeps_old_heights_and_the_anchor() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let ids: Vec<String> = (0..6).map(|i| format!("r{i}")).collect();
        let v1: Vec<Identity> = ids.iter().map(|id| identity("g", id, 1, 0, 300)).collect();
        let rows1: Vec<RowIdentity<'_>> = ids
            .iter()
            .map(|id| RowIdentity {
                id,
                version: 1,
                date: false,
            })
            .collect();
        let first: Vec<Decision<'_>> = rows1
            .iter()
            .zip(&v1)
            .map(|(r, identity)| replace(r.id, 1, Source::Raw, identity, 100))
            .collect();
        layout.publish(&rows1, &first, &m, 300);
        let before = layout.total();
        let scroll = layout.rows()[4].top + 10;
        let (anchor_id, anchor_offset) = {
            let (id, off) = layout.anchor(scroll).unwrap();
            (id.to_owned(), off)
        };
        assert_eq!(anchor_id, "r4");

        // Every row's content version changes at once. Only four may be
        // measured this tick; the other two keep their old height.
        let v2: Vec<Identity> = ids.iter().map(|id| identity("g", id, 2, 0, 300)).collect();
        let rows2: Vec<RowIdentity<'_>> = ids
            .iter()
            .map(|id| RowIdentity {
                id,
                version: 2,
                date: false,
            })
            .collect();
        let candidates: Vec<Candidate> = ids
            .iter()
            .zip(&v2)
            .map(|(id, identity)| view_candidate(id, 2, identity.clone(), false, false))
            .collect();
        let plan = schedule(layout.rows(), &candidates, 4);
        let decisions: Vec<Decision<'_>> = plan
            .iter()
            .map(|entry| match entry.action {
                Action::Fresh => Decision::KeepFresh {
                    id: entry.id,
                    version: entry.version,
                },
                Action::Stale => Decision::KeepStale {
                    id: entry.id,
                    version: entry.version,
                },
                Action::Measure => {
                    let at = ids.iter().position(|id| id == entry.id).unwrap();
                    replace(entry.id, entry.version, Source::Raw, &v2[at], 40)
                }
            })
            .collect();
        layout.publish(&rows2, &decisions, &m, 300);

        // The two that missed the budget keep their old height as stale
        // geometry, carry the **new** version, and have no identity.
        for row in &layout.rows()[4..] {
            assert_eq!(row.version, 2);
            assert_eq!(row.text_height, 100, "old height must not collapse");
            assert!(!row.placeholder);
            assert!(row.stale);
            assert!(row.identity.is_none(), "the old identity is not current");
        }
        assert!(layout.total() > before / 2);
        // The anchor still names the same row and offset.
        let restored = layout.scroll_for(&anchor_id, anchor_offset).unwrap();
        assert_eq!(layout.anchor(restored).unwrap().0, anchor_id);
    }

    #[test]
    fn a_drag_target_dies_with_its_plan_on_offscreen_resize_or_document_change() {
        let target = DragTarget {
            row_id: "r1".to_owned(),
            version: 1,
            doc: 0x100,
            width: 300,
            dpi: 96,
            font: 5,
            block: 2,
        };
        let held_blocks = [2usize];
        let held = [HeldPlan {
            row_id: "r1",
            version: 1,
            doc: 0x100,
            width: 300,
            dpi: 96,
            font: 5,
            blocks: &held_blocks,
        }];
        assert!(target.alive(&held), "the live plan is the positive control");
        let mut drag = DragState::default();
        drag.start(target.clone());
        assert_eq!(
            drag.drop_dead(&held),
            InputAction::NONE,
            "an unchanged target keeps the drag"
        );
        assert!(drag.target().is_some());

        // Off-screen: the view released the plan. Hide/leave/close empty
        // the same held list.
        let empty: [HeldPlan<'_>; 0] = [];
        assert_eq!(
            drag.drop_dead(&empty),
            InputAction {
                release_own_capture: true,
                invalidate: true
            }
        );
        assert!(drag.target().is_none());

        // Resize/rebuild: same message, another plan size.
        let resized = [HeldPlan {
            row_id: "r1",
            version: 1,
            doc: 0x100,
            width: 200,
            dpi: 96,
            font: 5,
            blocks: &held_blocks,
        }];
        assert!(
            !target.alive(&resized),
            "a rebuilt plan is not the drag's plan"
        );

        // Document changed.
        let new_doc = [HeldPlan {
            row_id: "r1",
            version: 1,
            doc: 0x200,
            width: 300,
            dpi: 96,
            font: 5,
            blocks: &held_blocks,
        }];
        assert!(
            !target.alive(&new_doc),
            "a new document is not the drag's document"
        );

        // The block index is not enough: it must exist in this plan.
        let other_blocks = [3usize];
        let other = [HeldPlan {
            row_id: "r1",
            version: 1,
            doc: 0x100,
            width: 300,
            dpi: 96,
            font: 5,
            blocks: &other_blocks,
        }];
        assert!(
            !target.alive(&other),
            "a reused block index is not the target"
        );

        // Cancel paths clear the state; releasing the OS capture is the
        // caller's separate action.
        for clear in ["cancel", "capture_lost", "end"] {
            drag.start(target.clone());
            let action = match clear {
                "cancel" => drag.cancel(),
                "capture_lost" => drag.capture_lost(),
                _ => drag.end(),
            };
            assert!(action.invalidate, "{clear}");
            let wants_release = clear != "capture_lost";
            assert_eq!(
                action.release_own_capture, wants_release,
                "{clear} release request"
            );
            assert!(drag.target().is_none(), "{clear} left a target");
        }
    }

    #[test]
    fn cancellation_actions_are_merged_and_survive_an_early_return() {
        let target = DragTarget {
            row_id: "r1".to_owned(),
            version: 1,
            doc: 0x100,
            width: 300,
            dpi: 96,
            font: 5,
            block: 2,
        };
        let empty: [HeldPlan<'_>; 0] = [];

        // The retain removed the plan: dropping the drag must ask for
        // **both** a capture release and a repaint, and clear the focus.
        let mut drag = DragState::default();
        drag.start(target.clone());
        let mut focus = Some(target.clone());
        let dead = drop_dead_input(&mut drag, &mut focus, &empty);
        assert!(
            dead.release_own_capture,
            "a removed target still owns capture"
        );
        assert!(dead.invalidate, "a removed target changes what is drawn");
        assert!(drag.target().is_none());
        assert!(focus.is_none());

        // **Even with no drag left**, a cancel call site must still ask to
        // release this window's capture: no relying on the next event.
        let again = cancel_input(&mut drag, &mut focus);
        assert!(
            again.release_own_capture,
            "an empty drag must not suppress release"
        );

        // Field-wise OR: a later `false` never overwrites an earlier
        // `true`, and multi-stage accumulation keeps both.
        let mut acc = InputAction::NONE;
        acc = acc.merge(InputAction::invalidate());
        drag.start(target.clone());
        acc = acc.merge(cancel_input(&mut drag, &mut focus));
        assert!(acc.invalidate, "a later stage overwrote invalidate");
        assert!(acc.release_own_capture, "release was lost");

        // The key path's early return still carries the action: a dead
        // target at the start yields it before any measurement.
        drag.start(target.clone());
        let early = drop_dead_input(&mut drag, &mut focus, &empty);
        assert!(early.invalidate && early.release_own_capture);
    }

    #[test]
    fn capture_lost_ends_the_drag_and_keeps_the_keyboard_target() {
        let target = DragTarget {
            row_id: "B".to_owned(),
            version: 1,
            doc: 0x300,
            width: 300,
            dpi: 96,
            font: 5,
            block: 2,
        };
        let held_blocks = [2usize];
        let held = [HeldPlan {
            row_id: "B",
            version: 1,
            doc: 0x300,
            width: 300,
            dpi: 96,
            font: 5,
            blocks: &held_blocks,
        }];

        // Choose B, start the drag, release the button normally.
        let mut drag = DragState::default();
        let mut focus = Some(target.clone());
        drag.start(target.clone());
        let end = drag.end();
        assert!(
            end.release_own_capture,
            "our own capture is released on end"
        );
        assert!(end.invalidate);
        assert_eq!(focus.as_ref(), Some(&target), "end keeps the focus");

        // **The capture-lost notification after that release**: the drag is
        // already empty, so it is idempotent and asks for no release --
        // and the focus must still be B with B's plan alive.
        let lost = capture_lost_input(&mut drag);
        assert!(
            !lost.release_own_capture,
            "a lost capture is not ours to release"
        );
        assert!(!lost.invalidate, "an empty drag has nothing to repaint");
        assert!(drag.target().is_none());
        assert_eq!(focus.as_ref(), Some(&target), "focus survives the release");
        assert!(focus.as_ref().unwrap().alive(&held));

        // An external window taking the capture ends our drag but still
        // never releases that other window's capture.
        drag.start(target.clone());
        let stolen = capture_lost_input(&mut drag);
        assert!(stolen.invalidate, "an active drag ends here");
        assert!(!stolen.release_own_capture);
        assert!(drag.target().is_none());
        assert_eq!(focus.as_ref(), Some(&target));

        // A real cancel still clears the focus; so does a dead target.
        let cancelled = cancel_input(&mut drag, &mut focus);
        assert!(cancelled.release_own_capture && cancelled.invalidate);
        assert!(focus.is_none(), "explicit cancel clears the focus");

        let mut dead_focus = Some(target.clone());
        drag.start(target.clone());
        let empty: [HeldPlan<'_>; 0] = [];
        let dead = drop_dead_input(&mut drag, &mut dead_focus, &empty);
        assert!(dead.release_own_capture && dead.invalidate);
        assert!(dead_focus.is_none(), "a dead target clears the focus");
    }

    #[test]
    fn a_row_that_was_never_measured_is_an_explicit_placeholder() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        layout.publish(
            &[RowIdentity {
                id: "a",
                version: 1,
                date: false,
            }],
            &[],
            &m,
            300,
        );
        assert!(layout.rows()[0].placeholder);
        assert!(!layout.rows()[0].stale);
        assert_eq!(layout.rows()[0].height, m.author + m.line + m.gap);
        assert!(layout.rows()[0].identity.is_none());
    }

    #[test]
    fn a_date_divider_is_one_line_of_its_own_and_belongs_to_its_row() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let rows = [
            RowInput {
                id: "a",
                version: 1,
                author: "a",
                text: "hi",
                date: false,
            },
            RowInput {
                id: "b",
                version: 1,
                author: "b",
                text: "hi",
                date: true,
            },
        ];
        assert!(layout.update(&rows, 300, &m, &measure(1)));
        assert_eq!(layout.rows()[0].date_height, 0);
        assert_eq!(layout.rows()[1].date_height, m.date);
        assert_eq!(layout.rows()[1].top, layout.rows()[0].height);
        assert_eq!(layout.rows()[1].height, m.date + m.author + m.line + m.gap);

        // The same rows with the boundary moved: the divider's line is the
        // only thing that changes.
        let moved = [
            RowInput {
                id: "a",
                version: 1,
                author: "a",
                text: "hi",
                date: true,
            },
            RowInput {
                id: "b",
                version: 1,
                author: "b",
                text: "hi",
                date: false,
            },
        ];
        assert!(layout.update(&moved, 300, &m, &measure(1)));
        assert_eq!(layout.rows()[0].date_height, m.date);
        assert_eq!(layout.rows()[1].date_height, 0);
        assert_eq!(layout.total(), 2 * (m.author + m.line + m.gap) + m.date);
    }

    #[test]
    fn an_evicted_anchor_lands_on_the_nearest_measured_row() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let rows = [row("a", 1, "one"), row("b", 1, "two"), row("c", 1, "three")];
        layout.update(&rows, 300, &m, &measure(1));
        let tops: Vec<i32> = layout.rows().iter().map(|r| r.top).collect();
        // The row that was anchored is gone; the nearest published top is
        // where the view lands -- never silently back at the top.
        assert_eq!(layout.nearest_measured(0), Some(tops[0]));
        assert_eq!(layout.nearest_measured(tops[1] + 1), Some(tops[1]));
        assert_eq!(
            layout.nearest_measured(i32::MAX / 2),
            Some(*tops.last().unwrap())
        );
    }

    #[test]
    fn a_placeholder_is_not_what_a_fallback_anchors_on() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let first = [row("a", 1, "one")];
        layout.update(&first, 300, &m, &measure(1));
        // "new" has never been published: it is an explicit placeholder,
        // so a fallback must land on "a" instead of the placeholder's top.
        let ids = [
            RowIdentity {
                id: "a",
                version: 1,
                date: false,
            },
            RowIdentity {
                id: "new",
                version: 1,
                date: false,
            },
        ];
        layout.publish(&ids, &[], &m, 300);
        assert!(layout.rows()[1].placeholder);
        assert_eq!(layout.nearest_measured(i32::MAX / 2), Some(0));
    }

    #[test]
    fn the_bar_is_graduated_in_loaded_rows_and_reaches_both_ends() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let ids: Vec<String> = (0..20).map(|i| format!("r{i}")).collect();
        let rows: Vec<RowInput> = ids.iter().map(|id| row(id, 1, "x")).collect();
        layout.update(&rows, 300, &m, &measure(1));
        let track = (100, 0, 10, 200);
        let top = layout.string_bar(0, 200, track, 36).expect("a bar");
        assert_eq!(top.thumb_y, track.1);
        // **The graduation is the loaded row count**, not any message
        // number: 20 rows here, and no `log_seq` was ever handed in.
        assert_eq!(top.ticks, 20);
        assert!(top.thumb_h >= 36);

        let max = (layout.total() - 200).max(0);
        let bottom = layout.string_bar(max, 200, track, 36).expect("a bar");
        assert_eq!(bottom.thumb_y, track.1 + track.3 - bottom.thumb_h);
    }

    #[test]
    fn a_drag_ratio_maps_back_into_the_loaded_map() {
        let m = Metrics::for_dpi(96);
        let mut layout = Layout::new();
        let ids: Vec<String> = (0..20).map(|i| format!("r{i}")).collect();
        let rows: Vec<RowInput> = ids.iter().map(|id| row(id, 1, "x")).collect();
        layout.update(&rows, 300, &m, &measure(1));
        assert_eq!(layout.scroll_at_ratio(0.0, 200), Some(0));
        // A round trip lands inside the row it started in, never outside
        // the loaded map.
        let at = layout.rows()[10].top + 5;
        let ratio = layout.position(at, 200).expect("a position");
        let back = layout.scroll_at_ratio(ratio, 200).expect("a scroll");
        assert!(
            (back - at).abs() <= layout.rows()[10].height,
            "back {back} vs at {at}"
        );
        // Dragging to the bottom lands at the last scroll the content
        // allows, not past it.
        let highest = layout.scroll_at_ratio(1.0, 200).expect("a scroll");
        let max = (layout.total() - 200).max(0);
        assert!(highest <= max + 1, "highest {highest} vs max {max}");
        assert!(
            highest + layout.rows().last().unwrap().height >= max,
            "highest {highest} vs max {max}"
        );
    }

    #[test]
    fn the_page_says_a_state_and_not_a_raw_code() {
        assert_eq!(load_word(Load::Loading), Some(msg::LOADING));
        assert_eq!(load_word(Load::Cancelled), Some(msg::CANCELLED));
        assert_eq!(load_word(Load::Gap), Some(msg::GAP));
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
