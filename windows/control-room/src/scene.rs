//! Everything the control room draws, as a list for a host to paint.
//!
//! A host that draws with GDI cannot be run off Windows, so what it would
//! get wrong without looking wrong is worked out here instead: which
//! rectangle, which words, which face and weight, which colour. The host
//! walks the list and paints each item; it has no sizes or colours of its
//! own and it never looks at a row.
//!
//! The units are the design's points, with the origin at the top left of
//! whatever is being drawn (the list panel, or the right side). **Every
//! colour that leaves here is opaque**: the table's see-through ones are
//! laid over what is under them first, because GDI has no alpha to give
//! them.
//!
//! The macOS host's `ControlRoomListView.swift` places the same things by
//! the same numbers.

use crate::lend::{msg as lend_msg, Detail as Detail_};
use crate::layout::{AskFit, ListLayout, Rect};
use crate::list::{self, List, Row};
use crate::look::{font, line, pane, radius, selection, side, space, Rgba, Theme};
use crate::snapshot::Shown;

/// The English of what the panel says; `build` passes each through the
/// host's translation. `{}` is where the one argument goes.
pub mod msg {
    use crate::n_;

    pub const WAITING_HEADER: &str = n_("{} groups waiting for you");
    pub const NONE_WAITING_HEADER: &str = n_("No group is waiting for you");
    pub const QUIET_HEADER: &str = n_("{} groups need nothing from you");
    /// The snapshot could not be read. `{}` is what was wrong with it.
    pub const UNREADABLE: &str = n_("The control room's data could not be read ({}).");
    /// No snapshot has been worked out yet.
    pub const NOT_YET: &str = n_("Nothing has been worked out yet.");
    pub const NO_SELECTION: &str = n_("Select a group on the left.");
    pub const NO_SUPERVISOR: &str = n_("This group has no supervisor.");
    pub const IN_ITS_OWN_TAB: &str = n_("The supervisor's terminal is in its own tab.");
    pub const GO_TO_ITS_TAB: &str = n_("Go to Its Tab");
    pub const HIDDEN_STEPS: &str = n_("{} more steps");
    /// The one button of the list: at the right end of its header.
    pub const NEW_GROUP: &str = n_("New Group");
    /// What the right side says of a group with no supervisor, by what the
    /// core says became of starting one. The macOS host's sentences.
    pub const STARTING: &str = n_("Starting the supervisor…");
    pub const NEVER_OPENED: &str = n_("The supervisor did not start: its tab never opened.");
    #[rustfmt::skip]
    pub const NEVER_CONNECTED: &str = n_("The supervisor did not start: its tab opened, but no agent connected from it. Its tab shows why.");
    pub const CLOSED_FIRST: &str = n_("The supervisor did not start: its tab was closed first.");
    pub const CLI_NOT_FOUND: &str = n_("The supervisor did not start: its agent CLI was not found. Its tab shows why.");
    pub const CLI_DID_NOT_START: &str = n_("The supervisor did not start: its agent CLI could not be started. Its tab shows why.");
    pub const DID_NOT_START: &str = n_("The supervisor did not start.");
    pub const ROLE: &str = n_("Role");
    pub const DIRECTORY: &str = n_("Directory");
    pub const CHOOSE: &str = n_("Choose…");
    pub const START_SUPERVISOR: &str = n_("Start Supervisor");
    /// The directory, when the core names none: the new tab's own.
    pub const WHERE_THE_TAB_STARTS: &str = n_("Where the tab starts");
    /// The role Polter ships, as the role library shows it.
    pub const POLTER_SUPERVISOR: &str = n_("Polter Supervisor");
    /// The right side, for a row that is a terminal in no group: it is
    /// itself what would be shown there. The macOS host's sentences.
    pub const TERMINAL_GONE: &str = n_("This terminal is no longer open.");
    pub const TERMINAL_IN_ITS_OWN_TAB: &str = n_("This terminal is in its own tab.");
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Face {
    /// The interface's face.
    Ui,
    /// The terminal's: group names, commands and paths.
    Mono,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Style {
    pub size: f64,
    /// A CSS-style weight, as the table gives it.
    pub weight: f64,
    pub face: Face,
    pub color: Rgba,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Align {
    Left,
    Right,
    Centre,
}

/// Where a part of a line sits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    /// From the left, at its own width, in order.
    Lead,
    /// From the right, at its own width; the last one listed is rightmost.
    Trail,
    /// Whatever is left between the two, cut short with an ellipsis.
    Rest,
    /// From the right like `Trail`, but only in the room the leading and
    /// trailing parts leave: the first to give way. One that does not fit
    /// is cut short with an ellipsis, and with no room at all is left out.
    /// Of several, the leftmost gives way first.
    Squeezed,
}

/// Where one part of a line is painted, in the host's pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placed {
    pub left: i32,
    pub right: i32,
    /// It has less room than its words: they end in an ellipsis.
    pub cut: bool,
}

/// Where each part of a line goes between `left` and `right`, given what a
/// host measured: its side, the gap before it and its width. None for a
/// part there is no room for.
///
/// **What keeps its width, in order**: the trailing parts, all of them;
/// then the leading parts, up to where the trailing ones begin; then the
/// squeezed ones, from the right, in what is left; and the rest between.
/// So on a waiting row the status word is whole, the group's name is cut
/// only by the status word, and who is waiting is what gives way to a long
/// name -- never the other way round, which is how a row once showed a
/// worker's whole title and no group at all (task 1444, defect 3).
pub fn place_line(left: i32, right: i32, parts: &[(Side, i32, i32)]) -> Vec<Option<Placed>> {
    let mut out = vec![None; parts.len()];
    let mut trail = right;
    for (i, (side, gap, width)) in parts.iter().enumerate().rev() {
        if *side == Side::Trail {
            out[i] = Some(Placed { left: trail - width, right: trail, cut: false });
            trail -= width + gap;
        }
    }
    let mut lead = left;
    for (i, (side, gap, width)) in parts.iter().enumerate() {
        if *side == Side::Lead {
            lead += gap;
            let end = (lead + width).min(trail);
            if end > lead {
                out[i] = Some(Placed { left: lead, right: end, cut: end < lead + width });
            }
            lead += width;
        }
    }
    let mut end = trail;
    let mut room = true;
    for (i, (side, gap, width)) in parts.iter().enumerate().rev() {
        if *side == Side::Squeezed && room {
            let has = (end - (lead + gap)).min(*width);
            if has <= 0 {
                // Nothing further left fits either.
                room = false;
                continue;
            }
            out[i] = Some(Placed { left: end - has, right: end, cut: has < *width });
            end -= has + gap;
        }
    }
    for (i, (side, gap, _)) in parts.iter().enumerate() {
        if *side == Side::Rest {
            let from = lead + gap;
            if end > from {
                out[i] = Some(Placed { left: from, right: end, cut: true });
            }
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq)]
pub enum Piece {
    Words { text: String, style: Style },
    Glyph { shown: Shown, color: Rgba, size: f64, pulses: bool },
    /// The glyph of a terminal the person is holding (`glyph::held`): not a
    /// status, never moving, and only in a pane's title.
    Held { color: Rgba, size: f64 },
}

/// One part of a line. A host measures the words; that is the one thing
/// this cannot do for it.
#[derive(Debug, Clone, PartialEq)]
pub struct Part {
    pub piece: Piece,
    pub side: Side,
    /// The space between this part and the one before it on its side.
    pub gap: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    /// A filled rectangle with square corners: a line, a track.
    Fill { rect: Rect, color: Rgba },
    /// A filled rectangle with round corners and, when `edge` is there, a
    /// line one device pixel wide just inside it.
    Round { rect: Rect, radius: f64, color: Rgba, edge: Option<Rgba> },
    /// Words in a box, on one line, centred up and down, cut short with an
    /// ellipsis when they do not fit.
    Text { rect: Rect, text: String, style: Style, align: Align },
    /// Several parts on one line, centred up and down.
    Line { rect: Rect, parts: Vec<Part> },
    /// Running text in a box `lines` lines high: wrapped at the box's
    /// width, and when there is more than fits, the last line ends in an
    /// ellipsis. `rect.h` is `lines` times the line height the layout used.
    Block { rect: Rect, text: String, style: Style, lines: usize },
}

/// One colour laid over another: `top` at its own alpha times `amount`.
/// The answer is opaque.
pub fn over(base: Rgba, top: Rgba, amount: f64) -> Rgba {
    let a = (top.a * amount).clamp(0.0, 1.0);
    let mix = |b: u8, t: u8| (b as f64 + (t as f64 - b as f64) * a).round() as u8;
    Rgba { r: mix(base.r, top.r), g: mix(base.g, top.g), b: mix(base.b, top.b), a: 1.0 }
}

const WHITE: Rgba = Rgba { r: 255, g: 255, b: 255, a: 1.0 };
const BLACK: Rgba = Rgba { r: 0, g: 0, b: 0, a: 1.0 };

/// The list panel's own colour, as it ends up on the window.
pub fn panel_color(theme: &Theme) -> Rgba {
    over(theme.window_base, theme.side_panel, 1.0)
}

/// The selected row's chip: white mixed into the panel by the table's
/// amount. `lift` is 0 at rest and 1 in the air.
pub fn chip_color(theme: &Theme, lift: f64) -> Rgba {
    let tint = theme.selection_tint + (theme.selection_tint_moving - theme.selection_tint) * lift;
    over(panel_color(theme), WHITE, tint)
}

/// A hairline at `scale` device pixels to the point: how thick to draw it,
/// in points, and how much of its colour to use. Half a point is half a
/// pixel at 100%, which nothing can draw, so there it is one pixel at half
/// strength; from 200% up it is whole pixels at full strength.
pub fn hairline(scale: f64) -> (f64, f64) {
    let want = line::HAIRLINE * scale;
    let px = want.round().max(1.0);
    (px / scale, (want / px).min(1.0))
}

fn fill(rect: Rect, color: Rgba) -> Item {
    Item::Fill { rect, color }
}

fn inset_x(r: Rect, by: f64) -> Rect {
    Rect { x: r.x + by, y: r.y, w: (r.w - 2.0 * by).max(0.0), h: r.h }
}

fn body(color: Rgba) -> Style {
    Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color }
}

fn words(text: impl Into<String>, style: Style, side: Side, gap: f64) -> Part {
    Part { piece: Piece::Words { text: text.into(), style }, side, gap }
}

/// The colour of a status word. Where the word is not red is the table's
/// to say (`text_on`).
fn ink(theme: &Theme, shown: Shown, selected: bool) -> Rgba {
    match shown {
        Shown::NeedsYou | Shown::DoneUnseen => theme.attention_text,
        Shown::Trouble => {
            if selected { theme.problem_text_on_row_selected } else { theme.problem_text_on_row }
        }
        Shown::Working | Shown::None => theme.text_secondary,
    }
}

/// Who is waiting, in the person's language; empty when there is nothing to
/// say. Which words is `list::waiter`'s; this only translates and fills.
fn waiter_words(row: &Row, tr: &dyn Fn(&str) -> String) -> String {
    list::waiter(&row.waiter).map_or(String::new(), |(template, arg)| list::fill(&tr(template), &arg))
}

/// The colour a glyph is filled with.
pub fn glyph_color(theme: &Theme, shown: Shown) -> Rgba {
    match shown {
        Shown::NeedsYou | Shown::DoneUnseen => theme.attention,
        Shown::Trouble => theme.problem,
        Shown::Working | Shown::None => theme.working,
    }
}

/// Which rows are written the way a selected row is: its name heavier, its
/// status word in the colour that reads on the chip.
///
/// At rest it is the selected row and no other. While the chip slides it is
/// on neither row, so the panel is built twice: once with `Nobody`, which
/// is what shows outside the chip, and once with `Every`, which the host
/// draws through the chip's own outline. What is under the chip then reads
/// as selected and what is not does not, and the line between the two is
/// the chip's edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lit {
    Selection,
    Every,
    Nobody,
}

/// What `build` is told that the list does not hold.
pub struct View<'a> {
    pub theme: &'a Theme,
    /// Device pixels to the point.
    pub scale: f64,
    pub selection: Option<&'a str>,
    pub lit: Lit,
    /// Where the chip is right now; `layout.chip(selection)` when it is at
    /// rest, somewhere on the way when it is sliding.
    pub chip: Option<Rect>,
    /// 0 with the chip at rest, 1 with it in the air.
    pub lift: f64,
    /// The row whose glyph breathes (`pulse::pulsing_row`).
    pub pulsing: Option<&'a str>,
    /// The person pressed "new group" and has not made one or given up:
    /// the header is the field for its name.
    pub naming: Option<Naming<'a>>,
}

/// A group being named.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Naming<'a> {
    /// Why the name as typed made no group; said under the field.
    pub refusal: Option<&'a str>,
}

/// Where pressing makes a new group: the right end of the header, where
/// the words are. 暂定: the right two fifths of the header, since only a
/// host can measure the words.
pub fn new_group_hit(header: Rect) -> Rect {
    let w = header.w * 0.4;
    Rect { x: header.x + header.w - w, y: header.y, w, h: header.h }
}

/// The field a new group is named in, where the header was: its outline,
/// and inside it where the host puts what is typed.
pub fn name_field(header: Rect) -> (Rect, Rect) {
    let outline = inset_x(header, side::HEADER_PADDING_X - side::ROW_PADDING_X);
    let h = side::ASK_LINE_HEIGHT;
    let typed = Rect { y: outline.y + (outline.h - h) / 2.0, h, ..inset_x(outline, side::ROW_PADDING_X) };
    (outline, typed)
}

/// Where the reason a name made no group is said: under the field, over
/// the rows, two lines of it.
pub fn name_note(header: Rect) -> Rect {
    let (outline, _) = name_field(header);
    Rect { y: outline.y + outline.h, h: 2.0 * side::ASK_LINE_HEIGHT + 2.0 * side::ROW_PADDING_Y, ..outline }
}

impl View<'_> {
    /// Whether this row is written as a selected one.
    fn lit(&self, id: &str) -> bool {
        match self.lit {
            Lit::Selection => self.selection == Some(id),
            Lit::Every => true,
            Lit::Nobody => false,
        }
    }
}

/// The list panel, top to bottom, in the order to paint it.
pub fn build(list: &List, at: &ListLayout, view: &View, tr: &dyn Fn(&str) -> String) -> Vec<Item> {
    let theme = view.theme;
    let panel = panel_color(theme);
    let mut out = Vec::new();

    // The panel itself: an independent piece with a faint edge.
    out.push(Item::Round {
        rect: Rect { x: 0.0, y: 0.0, w: at.width, h: at.height },
        radius: radius::SIDE_PANEL,
        color: panel,
        edge: Some(over(panel, theme.side_panel_edge, hairline(view.scale).1)),
    });

    // The chip goes under everything it lights, and its shadow under it.
    if let Some(chip) = view.chip {
        for (rect, radius, color) in crate::tabstrip::shadow(chip, radius::ROW, panel, theme, view.lift, 1.0) {
            out.push(Item::Round { rect, radius, color, edge: None });
        }
        let color = chip_color(theme, view.lift);
        let edge = theme.selection_edge;
        let toward = if edge < 0.0 { BLACK } else { WHITE };
        out.push(Item::Round { rect: chip, radius: radius::ROW, color, edge: Some(over(color, toward, edge.abs())) });
    }

    let (hair_h, hair_strength) = hairline(view.scale);
    let hair = |r: Rect, under: Rgba| fill(Rect { x: r.x, y: r.y, w: r.w, h: hair_h }, over(under, theme.line_faint, hair_strength));

    match view.naming {
        // The field's outline; what is typed in it is the host's own
        // control, put where `name_field` says.
        Some(_) => out.push(Item::Round { rect: name_field(at.header).0, radius: radius::ROW, color: panel, edge: Some(theme.attention_text) }),
        None => {
            let all = inset_x(at.header, side::HEADER_PADDING_X);
            // The one button of the list, at the header's right end; the
            // header's own words have what is to its left.
            let button = new_group_hit(at.header);
            let button = Rect { w: (all.x + all.w - button.x).max(0.0), ..button };
            out.push(Item::Text {
                rect: Rect { w: (button.x - side::ROW_ITEM_GAP - all.x).max(0.0), ..all },
                text: if list.waiting_count == 0 {
                    tr(msg::NONE_WAITING_HEADER)
                } else {
                    list::fill(&tr(msg::WAITING_HEADER), &list.waiting_count.to_string())
                },
                style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.text) },
                align: Align::Left,
            });
            out.push(Item::Text { rect: button, text: format!("+ {}", tr(msg::NEW_GROUP)), style: body(theme.text_secondary), align: Align::Right });
        }
    }

    for row in &list.waiting {
        if let (Some(rect), Some(fit)) = (at.chip(Some(&row.id)), at.fit(&row.id)) {
            waiting_row(&mut out, row, rect, fit, view, tr);
        }
    }

    if at.quiet_header.h > 0.0 {
        out.push(hair(at.separator, panel));
        out.push(Item::Text {
            rect: inset_x(at.quiet_header, side::HEADER_PADDING_X),
            text: list::fill(&tr(msg::QUIET_HEADER), &list.quiet_count.to_string()),
            style: body(theme.text_secondary),
            align: Align::Left,
        });
    }

    for row in &list.quiet {
        let Some(rect) = at.chip(Some(&row.id)) else { continue };
        quiet_row(&mut out, row, rect, view);
    }

    // Last, so it lies over the rows: it is there only until the name is
    // put right.
    if let Some(Naming { refusal: Some(why) }) = view.naming {
        let note = name_note(at.header);
        out.push(Item::Round { rect: note, radius: radius::ROW, color: theme.window_base, edge: None });
        out.push(Item::Block {
            rect: Rect { x: note.x + side::ROW_PADDING_X, y: note.y + side::ROW_PADDING_Y, w: (note.w - 2.0 * side::ROW_PADDING_X).max(0.0), h: 2.0 * side::ASK_LINE_HEIGHT },
            text: why.to_string(),
            style: body(theme.problem_text_on_row),
            lines: 2,
        });
    }

    out
}

/// What a row that needs nothing says after its name: what the group is
/// doing when the core knows, the status word when it does not, and nothing
/// for a group with neither. The macOS host's `quietText`.
pub fn quiet_text(row: &Row) -> String {
    if row.what.lines.is_empty() { row.word.clone() } else { list::drawn(&row.what).join(" ") }
}

/// The column every row's glyph stands in, so that the eye runs down one
/// line of them: where it starts, and where what follows it starts.
fn glyph_column(rect: Rect) -> (f64, f64) {
    let x = rect.x + side::ROW_PADDING_X;
    (x, x + side::GLYPH + side::ROW_ITEM_GAP)
}

/// A group that needs nothing: the glyph in the same column as every other
/// row's, the name, and what it is doing. A group with nothing to say is
/// its name alone, a step back.
fn quiet_row(out: &mut Vec<Item>, row: &Row, rect: Rect, view: &View) {
    let theme = view.theme;
    let selected = view.lit(&row.id);
    let said = quiet_text(row);
    let idle = row.shown == Shown::None && said.is_empty();
    let (glyph_x, text_x) = glyph_column(rect);
    let right = rect.x + rect.w - side::ROW_PADDING_X;
    if row.shown != Shown::None {
        out.push(Item::Line {
            rect: Rect { x: glyph_x, y: rect.y, w: side::GLYPH, h: rect.h },
            parts: vec![Part {
                piece: Piece::Glyph { shown: row.shown, color: glyph_color(theme, row.shown), size: side::GLYPH, pulses: false },
                side: Side::Lead,
                gap: 0.0,
            }],
        });
    }
    let name = words(
        row.name().to_string(),
        Style {
            size: font::BODY,
            weight: if selected { font::WEIGHT_STRONG } else { font::WEIGHT_BODY },
            face: Face::Mono,
            color: if idle && !selected { theme.text_secondary } else { theme.text },
        },
        // The name is what a quiet row is: it keeps its width, and what the
        // group is doing takes what is left.
        if said.is_empty() { Side::Rest } else { Side::Lead },
        0.0,
    );
    let mut parts = vec![name];
    if !said.is_empty() {
        parts.push(words(said, body(theme.text_secondary), Side::Rest, side::ROW_ITEM_GAP));
    }
    out.push(Item::Line { rect: Rect { x: text_x, y: rect.y, w: (right - text_x).max(0.0), h: rect.h }, parts });
}

/// A group that is waiting (control-room.md, 3.2): the glyph in its column;
/// the name, and at the right who is waiting and for which of the four;
/// then what it is waiting for, the heaviest thing on the row -- a sentence
/// in the interface's face, a command in the terminal's, one step to a
/// line. `fit` is how many lines each step has (`AskFit`); the row's height
/// came from the same, so nothing here measures.
fn waiting_row(out: &mut Vec<Item>, row: &Row, rect: Rect, fit: &AskFit, view: &View, tr: &dyn Fn(&str) -> String) {
    let theme = view.theme;
    let selected = view.lit(&row.id);
    let word_ink = ink(theme, row.shown, selected);
    let (glyph_x, text_x) = glyph_column(rect);
    let top = rect.y + side::ROW_PADDING_Y;
    let width = (rect.x + rect.w - side::ROW_PADDING_X - text_x).max(0.0);

    out.push(Item::Line {
        rect: Rect { x: glyph_x, y: top, w: side::GLYPH, h: side::ROW_LINE1_HEIGHT },
        parts: vec![Part {
            piece: Piece::Glyph {
                shown: row.shown,
                color: glyph_color(theme, row.shown),
                size: side::GLYPH,
                pulses: view.pulsing == Some(row.id.as_str()),
            },
            side: Side::Lead,
            gap: 0.0,
        }],
    });

    // First line: the name; at the right, who is waiting and then which of
    // the four it is.
    let mut first = vec![words(
        row.name().to_string(),
        Style {
            size: font::GROUP_NAME,
            weight: if selected { font::WEIGHT_STRONG } else { font::WEIGHT_GROUP_NAME },
            face: Face::Mono,
            color: theme.text,
        },
        // The name keeps its place: only the status word cuts it short,
        // and who is waiting takes what the two leave (`place_line`).
        Side::Lead,
        0.0,
    )];
    first.extend(waiter_parts(row, theme, tr));
    first.push(words(row.word.clone(), Style { weight: font::WEIGHT_EMPHASIS, ..body(word_ink) }, Side::Trail, side::ROW_ITEM_GAP));
    out.push(Item::Line { rect: Rect { x: text_x, y: top, w: width, h: side::ROW_LINE1_HEIGHT }, parts: first });

    // What it waits on: the steps that have lines, each in a box of its own
    // lines. The rest are counted below.
    let code = list::is_code(&row.what);
    let ask = Style { face: if code { Face::Mono } else { Face::Ui }, ..body(theme.text) };
    let mut y = top + side::ROW_LINE1_HEIGHT;
    for (step, lines) in list::drawn(&row.what).into_iter().zip(fit.lines.iter().copied()) {
        let h = lines as f64 * side::ASK_LINE_HEIGHT;
        out.push(Item::Block { rect: Rect { x: text_x, y, w: width, h }, text: step, style: ask, lines });
        y += h;
    }
    let mut note = |text: String| {
        out.push(Item::Text {
            rect: Rect { x: text_x, y, w: width, h: side::ASK_LINE_HEIGHT },
            text,
            style: body(theme.text_secondary),
            align: Align::Left,
        });
        y += side::ASK_LINE_HEIGHT;
    };
    if fit.hidden > 0 {
        note(list::fill(&tr(msg::HIDDEN_STEPS), &fit.hidden.to_string()));
    }
    // 暂定: a line of its own under what the row waits on. The design drew
    // no row with a second thing waiting.
    if let Some((template, n)) = list::others(row.others) {
        note(list::fill(&tr(template), &n));
    }
    // **Nothing on a row can be pressed.** A row says that somebody is
    // waiting and for what; the person goes to the terminal to answer. A
    // tick and a cross were here for a day and were taken out again (the
    // user's ruling, 2026-10-12): a row is too small to show what is being
    // agreed to, and what is being asked is often not a yes or a no.
}

/// Who is waiting, as the parts of a line's right end: the worker's name in
/// the terminal's face, the words round it in the interface's.
fn waiter_parts(row: &Row, theme: &Theme, tr: &dyn Fn(&str) -> String) -> Vec<Part> {
    let Some((template, name)) = list::waiter(&row.waiter) else { return Vec::new() };
    let said = tr(template);
    let ui = body(theme.text_secondary);
    let mono = Style { face: Face::Mono, ..ui };
    // The template has the name's place in it, or it is the whole of what
    // is said ("Supervisor").
    let Some((before, after)) = said.split_once("{}") else {
        return vec![words(said, ui, Side::Squeezed, side::ROW_ITEM_GAP)];
    };
    // Left to right; a trailing part's gap is on its left.
    let mut parts = Vec::new();
    let mut gap = side::ROW_ITEM_GAP;
    for (text, style) in [(before.to_string(), ui), (name, mono), (after.to_string(), ui)] {
        if draws(&text) {
            parts.push(words(text, style, Side::Squeezed, gap));
            gap = 0.0;
        }
    }
    parts
}

/// What a row says when it is read out rather than looked at: the group,
/// who is waiting, which of the four it is, what it waits on, and how many
/// others -- the same things the row draws, with the glyph's meaning carried
/// by the status word.
pub fn spoken(row: &Row, tr: &dyn Fn(&str) -> String) -> String {
    let mut parts = vec![row.name().to_string()];
    let who = waiter_words(row, tr);
    if !who.is_empty() {
        parts.push(who);
    }
    if !row.word.is_empty() {
        parts.push(row.word.clone());
    }
    // Every step, whole: nothing read out is cut short.
    parts.extend(list::drawn(&row.what).into_iter().filter(|l| !l.is_empty()));
    if let Some((template, n)) = list::others(row.others) {
        parts.push(list::fill(&tr(template), &n));
    }
    parts.join(", ")
}

/// A number that stands for a group's name where an interface wants a
/// number for identity (a UI Automation runtime id). The name is the
/// identity; this is FNV-1a over it, so the same group is the same number
/// in every snapshot and its place in the list never is.
pub fn stable_id(name: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in name.bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Whether a piece of text is something to draw or to measure. **A host
/// asks this before it hands the text to the system, every time.**
///
/// A scene carries empty text on purpose: a group nobody is waiting on has
/// a status with no word (the core's `none`), and a wait can come with no
/// reason. Leaving the part in keeps a row's columns where they are. But
/// "draw these zero characters" is not a harmless request on Windows --
/// `DrawTextW` given a count of 0 and the pointer an empty buffer has reads
/// through the pointer, inside `USER32`, on Windows 11 build 26200. The
/// control room's first real machine died of it on every opening that had
/// such a row (task 1439).
pub fn draws(text: &str) -> bool {
    !text.is_empty()
}

/// Every piece of text a scene asks a host for, drawn or measured: the
/// `Text` items and the words of every line.
pub fn all_text(items: &[Item]) -> Vec<&str> {
    let mut out = Vec::new();
    for item in items {
        match item {
            Item::Text { text, .. } | Item::Block { text, .. } => out.push(text.as_str()),
            Item::Line { parts, .. } => {
                for part in parts {
                    match &part.piece {
                        Piece::Words { text, .. } => out.push(text.as_str()),
                        Piece::Glyph { .. } => {}
                        Piece::Held { .. } => {}
                    }
                }
            }
            Item::Fill { .. } | Item::Round { .. } => {}
        }
    }
    out
}

/// Whether anything in a scene moves while nothing changes: a glyph that
/// breathes, or the spinner. A host keeps a clock running only while this
/// is so, and otherwise is not woken at all.
pub fn moves(items: &[Item]) -> bool {
    items.iter().any(|item| match item {
        Item::Line { parts, .. } => parts.iter().any(|p| match &p.piece {
            Piece::Glyph { shown, pulses, .. } => *pulses || *shown == Shown::Working,
            Piece::Words { .. } => false,
            Piece::Held { .. } => false,
        }),
        Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } => false,
    })
}

/// The same question for one glyph on a window tab.
pub fn glyph_moves(shown: Shown, pulses: bool) -> bool {
    pulses || shown == Shown::Working
}

/// The panel when there is no list to draw: the panel itself and one
/// sentence. Never an empty list, which would read as "no groups".
pub fn build_message(width: f64, height: f64, theme: &Theme, scale: f64, text: String) -> Vec<Item> {
    let panel = panel_color(theme);
    vec![
        Item::Round {
            rect: Rect { x: 0.0, y: 0.0, w: width, h: height },
            radius: radius::SIDE_PANEL,
            color: panel,
            edge: Some(over(panel, theme.side_panel_edge, hairline(scale).1)),
        },
        Item::Text {
            rect: Rect {
                x: space::SIDE_PANEL_PADDING + side::HEADER_PADDING_X,
                y: space::SIDE_PANEL_PADDING,
                w: (width - 2.0 * (space::SIDE_PANEL_PADDING + side::HEADER_PADDING_X)).max(0.0),
                h: side::HEADER_HEIGHT,
            },
            text,
            style: body(theme.text_secondary),
            align: Align::Left,
        },
    ]
}

/// The right-hand side: the selected group's supervisor, or a sentence
/// saying why it is not there.
#[derive(Debug, Clone, PartialEq)]
pub struct Right {
    pub items: Vec<Item>,
    /// Where "go to its tab" is, when the supervisor is in another window.
    pub go: Option<Rect>,
    /// Where the supervisor's own terminal goes, when it is shown here. The
    /// host puts the terminal's window exactly there; this draws only the
    /// frame round it.
    pub terminal: Option<Rect>,
}

/// What the person has picked for the supervisor about to be started, and
/// what the last press came to. All of it is about one group.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StartView<'a> {
    /// The roles the core lists, and whether it says there is a choice.
    pub roles: &'a [crate::snapshot::SupervisorRole],
    pub choose_role: bool,
    /// What they picked; none while they have picked nothing, and then it
    /// is the core's (`start.role`, `start.cwd`).
    pub role: Option<&'a str>,
    pub cwd: Option<&'a str>,
    /// Why the last press of "Start Supervisor" did nothing.
    pub refusal: Option<&'a str>,
    /// The person's home directory, shown as `~`.
    pub home: &'a str,
}

/// What starting a supervisor offers under the right side's sentence, and
/// where each thing to press is.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Start {
    pub items: Vec<Item>,
    /// The role's line, when there is a choice of role.
    pub role: Option<Rect>,
    /// The directory's line: pressing it picks another.
    pub directory: Option<Rect>,
    /// "Start Supervisor".
    pub start: Option<Rect>,
}

/// What the right side says of a group with no supervisor: which sentence
/// is the core's word (`state`, `failed`).
pub fn no_supervisor_words(start: Option<&crate::snapshot::SupervisorStart>) -> &'static str {
    use crate::snapshot::{StartFailure as F, SupervisorState as S};
    match start.map(|s| (s.state, s.failed)) {
        Some((S::Starting, _)) => msg::STARTING,
        Some((S::Failed, F::TerminalNeverOpened)) => msg::NEVER_OPENED,
        Some((S::Failed, F::AgentNeverConnected)) => msg::NEVER_CONNECTED,
        Some((S::Failed, F::TerminalClosed)) => msg::CLOSED_FIRST,
        Some((S::Failed, F::CliNotFound)) => msg::CLI_NOT_FOUND,
        Some((S::Failed, F::CliDidNotStart)) => msg::CLI_DID_NOT_START,
        Some((S::Failed, F::None)) => msg::DID_NOT_START,
        Some((S::Present, _)) | Some((S::Absent, _)) | None => msg::NO_SUPERVISOR,
    }
}

/// A directory as it is shown: the home directory as `~`. Either slash
/// ends the home directory's name.
pub fn shown_directory(path: &str, home: &str, tr: &dyn Fn(&str) -> String) -> String {
    if path.is_empty() {
        return tr(msg::WHERE_THE_TAB_STARTS);
    }
    if home.is_empty() {
        return path.to_string();
    }
    if path == home {
        return "~".to_string();
    }
    match path.strip_prefix(home) {
        Some(rest) if rest.starts_with('/') || rest.starts_with('\\') => format!("~{rest}"),
        Some(_) | None => path.to_string(),
    }
}

/// The name a role is shown under.
pub fn role_name(role: &crate::snapshot::SupervisorRole, tr: &dyn Fn(&str) -> String) -> String {
    if role.key == "polter-supervisor" {
        tr(msg::POLTER_SUPERVISOR)
    } else {
        role.name.clone()
    }
}

/// How far down the right side the sentence of a group with no supervisor
/// ends: where what starting one offers begins.
fn start_top() -> f64 {
    space::FRAME_TO_CONTENT + side::HEADER_HEIGHT + 2.0 * side::ASK_LINE_HEIGHT + side::ROW_GAP
}

/// What the right side offers for the selected group when it has no
/// supervisor: the role (only when the core says there is a choice), the
/// directory, and the button -- **only when the core says one can be
/// started** (`can_start`). Nothing otherwise.
///
/// This is on the right side, not on a row: a row still has nothing to
/// press but itself.
pub fn build_start(detail: &Detail_, row: Option<&Row>, width: f64, theme: &Theme, view: &StartView, tr: &dyn Fn(&str) -> String) -> Start {
    let Detail_::NoSupervisor { .. } = detail else { return Start::default() };
    let Some(start) = row.and_then(|r| r.start.as_ref()) else { return Start::default() };
    if !start.can_start {
        return Start::default();
    }
    let pad = space::FRAME_TO_CONTENT;
    let line_h = side::HEADER_HEIGHT;
    let w = (width - 2.0 * pad).min(side::WIDTH * 1.5).max(0.0);
    let mut y = start_top();
    let mut out = Start::default();
    let label = |text: &str| words(tr(text), body(theme.terminal_dim), Side::Lead, 0.0);

    if view.choose_role {
        let key = view.role.or(start.role.as_deref());
        let name = key.and_then(|k| view.roles.iter().find(|r| r.key == k)).map(|r| role_name(r, tr)).unwrap_or_default();
        let rect = Rect { x: pad, y, w, h: line_h };
        let mut parts = vec![label(msg::ROLE)];
        if draws(&name) {
            parts.push(words(name, Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.terminal_text) }, Side::Lead, side::ROW_ITEM_GAP));
        }
        parts.push(words(tr(msg::CHOOSE), body(theme.attention_text), Side::Trail, side::ROW_ITEM_GAP));
        out.items.push(Item::Line { rect, parts });
        out.role = Some(rect);
        y += line_h;
    }

    let rect = Rect { x: pad, y, w, h: line_h };
    out.items.push(Item::Line {
        rect,
        parts: vec![
            label(msg::DIRECTORY),
            words(
                shown_directory(view.cwd.unwrap_or(&start.cwd), view.home, tr),
                Style { face: Face::Mono, ..body(theme.terminal_text) },
                Side::Rest,
                side::ROW_ITEM_GAP,
            ),
            words(tr(msg::CHOOSE), body(theme.attention_text), Side::Trail, side::ROW_ITEM_GAP),
        ],
    });
    out.directory = Some(rect);
    y += line_h + side::ROW_GAP;

    let button = Rect { x: pad, y, w: side::WIDTH / 2.0, h: line_h };
    out.items.push(Item::Round { rect: button, radius: radius::ROW, color: theme.terminal_background, edge: Some(theme.attention_text) });
    out.items.push(Item::Text {
        rect: button,
        text: tr(msg::START_SUPERVISOR),
        style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.attention_text) },
        align: Align::Centre,
    });
    out.start = Some(button);
    y += line_h + side::ROW_GAP;

    if let Some(why) = view.refusal.filter(|w| draws(w)) {
        out.items.push(Item::Block {
            rect: Rect { x: pad, y, w, h: 2.0 * side::ASK_LINE_HEIGHT },
            text: why.to_string(),
            style: body(theme.problem_text_on_terminal),
            lines: 2,
        });
    }
    out
}

/// Where the terminal sits inside the right-hand side when it is shown:
/// under the frame's title bar, inside its border.
pub fn terminal_rect(width: f64, height: f64) -> Rect {
    let b = pane::SUPERVISOR_BORDER;
    Rect { x: b, y: pane::BAR_HEIGHT, w: (width - 2.0 * b).max(0.0), h: (height - pane::BAR_HEIGHT - b).max(0.0) }
}

/// `detail` is what `lend::Lending` says the right side shows; `row` is the
/// selected row, for its name and state. `in_terminal` is whether the
/// terminal shown here has the keyboard. `width` and `height` are the right
/// side's own.
pub fn build_right(
    detail: &Detail_,
    row: Option<&Row>,
    width: f64,
    height: f64,
    theme: &Theme,
    scale: f64,
    in_terminal: bool,
    tr: &dyn Fn(&str) -> String,
) -> Right {
    let frame = Rect { x: 0.0, y: 0.0, w: width, h: height };
    let hair = hairline(scale).1;

    if let Detail_::Terminal(loan) = detail {
        // The supervisor's frame: a thick border whose top edge is the
        // title bar, floating; the edge darkens (lightens, in the dark)
        // while the terminal in it has the keyboard.
        let bezel = over(theme.window_base, theme.supervisor_bezel, 1.0);
        let edge = if in_terminal { theme.supervisor_edge_focused } else { theme.supervisor_edge };
        let mut items = vec![Item::Round { rect: frame, radius: radius::SUPERVISOR_OUTER, color: bezel, edge: Some(over(bezel, edge, 1.0)) }];
        let bar = Rect {
            x: pane::SUPERVISOR_BAR_PADDING_X,
            y: 0.0,
            w: (width - 2.0 * pane::SUPERVISOR_BAR_PADDING_X).max(0.0),
            h: pane::BAR_HEIGHT,
        };
        // The name and what it is on the left; its state on the right.
        // A group's row: the group and "Supervisor". A terminal on its own:
        // its title, and the word for the frame its own pane wears -- none
        // for an ordinary one. The frame here is a supervisor's either way.
        let alone = row.and_then(|r| r.alone.as_ref());
        let mut parts = vec![words(
            alone.map_or(loan.group.clone(), |a| a.title.clone()),
            Style { size: font::BODY, weight: font::WEIGHT_STRONG, face: Face::Mono, color: theme.text },
            Side::Lead,
            0.0,
        )];
        let role = match alone {
            Some(a) => crate::pane::role_word(a.pane),
            None => Some(lend_msg::SUPERVISOR),
        };
        if let Some(role) = role {
            parts.push(words(tr(role), body(theme.text_secondary), Side::Lead, pane::BAR_GAP));
        }
        if let Some(row) = row {
            let word_ink = match row.shown {
                Shown::NeedsYou | Shown::DoneUnseen => theme.attention_text,
                // Where the word is not red is the table's to say.
                Shown::Trouble => theme.problem_text_on_supervisor_bar,
                Shown::Working | Shown::None => theme.text_secondary,
            };
            if row.shown != Shown::None {
                parts.push(Part {
                    piece: Piece::Glyph { shown: row.shown, color: glyph_color(theme, row.shown), size: side::GLYPH, pulses: false },
                    side: Side::Trail,
                    gap: pane::BAR_GAP,
                });
            }
            parts.push(words(row.word.clone(), Style { weight: font::WEIGHT_EMPHASIS, ..body(word_ink) }, Side::Trail, side::STATUS_WORD_GAP));
        }
        items.push(Item::Line { rect: bar, parts });
        // The terminal's own ground, for the moment before the terminal's
        // window is over it.
        let terminal = terminal_rect(width, height);
        items.push(Item::Fill { rect: terminal, color: theme.terminal_background });
        return Right { items, go: None, terminal: Some(terminal) };
    }

    let ground = theme.terminal_background;
    let mut items = vec![Item::Round {
        rect: frame,
        radius: radius::SUPERVISOR_OUTER,
        color: ground,
        edge: Some(over(ground, theme.side_panel_edge, hair)),
    }];
    let pad = space::FRAME_TO_CONTENT;
    let line_h = side::HEADER_HEIGHT;
    let inner_w = (width - 2.0 * pad).max(0.0);
    let line_at = |n: f64| Rect { x: pad, y: pad + n * line_h, w: inner_w, h: line_h };
    // A terminal with a row of its own has no supervisor to speak of: it
    // is itself what this side would show. It goes by its title, and what
    // is said of it is said of a terminal.
    let alone = row.and_then(|r| r.alone.as_ref());
    let name = |items: &mut Vec<Item>, group: &str| {
        let text = alone.map_or(group, |a| a.title.as_str());
        // A terminal may have no title yet; nothing empty is handed over.
        if draws(text) {
            items.push(Item::Text {
                rect: line_at(0.0),
                text: text.to_string(),
                style: Style { size: font::GROUP_NAME, weight: font::WEIGHT_STRONG, face: Face::Mono, color: theme.terminal_bold },
                align: Align::Left,
            })
        }
    };
    let says = |items: &mut Vec<Item>, at: f64, sentence: &str| {
        items.push(Item::Text { rect: line_at(at), text: tr(sentence), style: body(theme.terminal_dim), align: Align::Left })
    };
    let mut go = None;
    match detail {
        Detail_::NothingSelected => {
            items.push(Item::Text { rect: line_at(0.0), text: tr(msg::NO_SELECTION), style: body(theme.text_secondary), align: Align::Left });
        }
        // Which sentence is the core's word; some are long, so it has two
        // lines. What starting one offers goes under it (`build_start`).
        Detail_::NoSupervisor { group } => {
            name(&mut items, group);
            items.push(Item::Block {
                rect: Rect { x: pad, y: pad + line_h, w: inner_w, h: 2.0 * side::ASK_LINE_HEIGHT },
                text: tr(match alone {
                    Some(_) => msg::TERMINAL_GONE,
                    None => no_supervisor_words(row.and_then(|r| r.start.as_ref())),
                }),
                style: body(theme.terminal_dim),
                lines: 2,
            });
        }
        Detail_::SupervisorGone { group } => {
            name(&mut items, group);
            says(&mut items, 1.0, if alone.is_some() { msg::TERMINAL_GONE } else { lend_msg::GONE });
        }
        // In its own tab, by the person's choice: said, and left there.
        Detail_::TakenBack(loan) => {
            name(&mut items, &loan.group);
            says(&mut items, 1.0, if alone.is_some() { msg::TERMINAL_IN_ITS_OWN_TAB } else { msg::IN_ITS_OWN_TAB });
        }
        // In another window: said, with the way there.
        Detail_::Elsewhere(loan) => {
            name(&mut items, &loan.group);
            says(&mut items, 1.0, if alone.is_some() { msg::TERMINAL_IN_ITS_OWN_TAB } else { msg::IN_ITS_OWN_TAB });
            // A button the width of the list's rows would be lost on a wide
            // side; it is as wide as a tab and sits on the content's left
            // edge.
            let rect = Rect { x: pad, y: pad + 2.0 * line_h + space::BETWEEN_FRAMES, w: side::WIDTH / 2.0, h: line_h };
            let button = over(ground, theme.text, selection::LIFT_IN);
            items.push(Item::Round { rect, radius: radius::ROW, color: button, edge: Some(over(button, theme.side_panel_edge, 1.0)) });
            items.push(Item::Text {
                rect,
                text: tr(msg::GO_TO_ITS_TAB),
                style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.terminal_text) },
                align: Align::Centre,
            });
            go = Some(rect);
        }
        Detail_::Terminal(_) => {}
    }
    Right { items, go, terminal: None }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look;
    use crate::snapshot;

    const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/poltergeist/testdata/control_snapshot.json"));

    fn list() -> List {
        List::from_snapshot(&snapshot::decode(FIXTURE).unwrap())
    }

    fn same(s: &str) -> String {
        s.to_string()
    }

    fn scene(list: &List, selection: Option<&str>, dark: bool, scale: f64, pulsing: Option<&str>) -> Vec<Item> {
        let at = ListLayout::new(list, 900.0);
        let view = View { theme: look::theme(dark), scale, selection, lit: Lit::Selection, chip: at.chip(selection), lift: 0.0, pulsing, naming: None };
        build(list, &at, &view, &same)
    }

    fn styles(items: &[Item]) -> Vec<Style> {
        let mut out = Vec::new();
        for item in items {
            match item {
                Item::Text { style, .. } | Item::Block { style, .. } => out.push(*style),
                Item::Line { parts, .. } => {
                    for p in parts {
                        if let Piece::Words { style, .. } = &p.piece {
                            out.push(*style);
                        }
                    }
                }
                Item::Fill { .. } | Item::Round { .. } => {}
            }
        }
        out
    }

    fn rect_of(item: &Item) -> Rect {
        match item {
            Item::Fill { rect, .. } | Item::Round { rect, .. } | Item::Text { rect, .. } | Item::Line { rect, .. } | Item::Block { rect, .. } => *rect,
        }
    }

    fn texts(items: &[Item]) -> Vec<String> {
        let mut out = Vec::new();
        for item in items {
            match item {
                Item::Text { text, .. } | Item::Block { text, .. } => out.push(text.clone()),
                Item::Line { parts, .. } => {
                    for p in parts {
                        if let Piece::Words { text, .. } = &p.piece {
                            out.push(text.clone());
                        }
                    }
                }
                Item::Fill { .. } | Item::Round { .. } => {}
            }
        }
        out
    }

    /// What the first real machine died of (task 1439): the scene of the
    /// core's own fixture asks for text that has no characters in it, and
    /// a host that passes that to `DrawTextW` is gone. So the scene really
    /// does carry such text -- this is the case, not a supposition -- and
    /// `draws` is the question that stops it at the host's door.
    #[test]
    fn a_scene_carries_text_with_nothing_in_it_and_a_host_is_told_not_to_draw_it() {
        // What the machine had: a status the core gives no word for
        // (`Attention.Word.none` is the empty string), on a row that is
        // drawn with its word at the right end whatever the word is.
        let mut list = list();
        list.waiting[0].word = String::new();
        let items = scene(&list, None, false, 1.0, None);
        let all = all_text(&items);
        let empty = all.iter().filter(|t| t.is_empty()).count();
        assert!(empty > 0, "a row with a wordless status no longer puts an empty text in the scene; this test needs a case that does");
        // Every one of them is refused, and nothing with a character in it is.
        for text in &all {
            assert_eq!(draws(text), !text.is_empty(), "{text:?}");
        }
        assert_eq!(all.iter().filter(|t| !draws(t)).count(), empty);
        // The right side too, for every row that can be selected.
        for row in list.rows() {
            let right = build_right(&Detail_::NoSupervisor { group: row.id.clone() }, Some(row), 600.0, 600.0, look::theme(false), 1.0, false, &same);
            for text in all_text(&right.items) {
                assert_eq!(draws(text), !text.is_empty(), "{text:?}");
            }
        }
    }

    #[test]
    fn nothing_is_set_smaller_than_the_menu_font() {
        for dark in [false, true] {
            let l = list();
            let first = l.waiting[0].id.clone();
            let items = scene(&l, Some(&first), dark, 1.0, None);
            let all = styles(&items);
            assert!(all.len() > 10);
            for s in all {
                assert!(s.size >= font::MIN, "{s:?}");
            }
            let row = l.row(&first);
            let loan = crate::lend::Loan { group: first.clone(), terminal: "0x0000000000000001".into() };
            for detail in [
                Detail_::NothingSelected,
                Detail_::NoSupervisor { group: first.clone() },
                Detail_::SupervisorGone { group: first.clone() },
                Detail_::Elsewhere(loan.clone()),
                Detail_::TakenBack(loan.clone()),
                Detail_::Terminal(loan.clone()),
            ] {
                let right = build_right(&detail, row, 600.0, 700.0, look::theme(dark), 1.0, false, &same);
                let all = styles(&right.items);
                assert!(!all.is_empty());
                for s in all {
                    assert!(s.size >= font::MIN, "{s:?}");
                }
            }
        }
    }

    #[test]
    fn every_colour_handed_to_the_host_is_opaque() {
        for dark in [false, true] {
            let l = list();
            let first = l.waiting[0].id.clone();
            for item in scene(&l, Some(&first), dark, 1.0, None) {
                match item {
                    Item::Fill { color, .. } => assert_eq!(color.a, 1.0),
                    Item::Round { color, edge, .. } => {
                        assert_eq!(color.a, 1.0);
                        assert!(edge.is_none_or(|e| e.a == 1.0));
                    }
                    Item::Text { .. } | Item::Line { .. } | Item::Block { .. } => {}
                }
            }
        }
    }

    #[test]
    fn everything_is_inside_the_panel() {
        let l = list();
        let at = ListLayout::new(&l, 900.0);
        for item in scene(&l, None, false, 1.0, None) {
            let r = rect_of(&item);
            assert!(r.x >= 0.0 && r.y >= 0.0 && r.x + r.w <= at.width + 1e-9 && r.y + r.h <= at.height + 1e-9, "{item:?}");
        }
    }

    fn is_glyph(item: &Item) -> bool {
        match item {
            Item::Line { parts, .. } => parts.iter().any(|p| match &p.piece {
                Piece::Glyph { .. } => true,
                Piece::Words { .. } => false,
                Piece::Held { .. } => false,
            }),
            Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } => false,
        }
    }

    #[test]
    fn every_glyph_stands_in_one_column_and_every_rows_words_start_on_one_line() {
        // The grid (control-room.md, 3.2): the glyphs of every row, waiting
        // or not, stand on one vertical line -- the one the headers start
        // on -- and what a row says starts a glyph and a gap to its right.
        let l = list();
        let column = space::SIDE_PANEL_PADDING + side::ROW_PADDING_X;
        let words_at = column + side::GLYPH + side::ROW_ITEM_GAP;
        let right = side::WIDTH - column;
        assert_eq!(side::ROW_PADDING_X, side::HEADER_PADDING_X);
        let (mut glyphs, mut lines, mut blocks) = (0, 0, 0);
        for item in scene(&l, None, false, 1.0, None) {
            match &item {
                Item::Line { rect, .. } if is_glyph(&item) => {
                    assert_eq!(rect.x, column, "{item:?}");
                    assert_eq!(rect.w, side::GLYPH, "{item:?}");
                    glyphs += 1;
                }
                Item::Line { rect, .. } => {
                    assert_eq!(rect.x, words_at, "{item:?}");
                    assert_eq!(rect.x + rect.w, right, "{item:?}");
                    lines += 1;
                }
                Item::Block { rect, .. } => {
                    assert_eq!(rect.x, words_at, "{item:?}");
                    assert_eq!(rect.x + rect.w, right, "{item:?}");
                    blocks += 1;
                }
                // A header starts in the glyphs' column; a note under what
                // a row waits on starts with the row's words.
                // The one thing set from the right: "new group", which ends
                // where every row's words end.
                Item::Text { rect, align: Align::Right, .. } => assert_eq!(rect.x + rect.w, right, "{item:?}"),
                Item::Text { rect, .. } => assert!(rect.x == column || rect.x == words_at, "{item:?}"),
                Item::Fill { .. } | Item::Round { .. } => {}
            }
        }
        // One line of words a row; a glyph for every waiting row and for
        // the quiet ones that have one; a block for every step drawn.
        assert_eq!(lines, l.waiting.len() + l.quiet.len());
        assert_eq!(glyphs, l.waiting.len() + l.quiet.iter().filter(|r| r.shown != Shown::None).count());
        let at = ListLayout::new(&l, 900.0);
        let steps: usize = l.waiting.iter().map(|r| at.fit(&r.id).unwrap().lines.len()).sum();
        assert_eq!(blocks, steps);
        assert!(blocks > l.waiting.len(), "the fixture has a command of several steps; each is its own block");
    }

    #[test]
    fn what_a_row_waits_on_is_one_step_to_a_block_and_fills_the_row_the_layout_made() {
        let l = list();
        let at = ListLayout::new(&l, 900.0);
        let items = scene(&l, None, false, 1.0, None);
        for row in &l.waiting {
            let rect = at.chip(Some(&row.id)).unwrap();
            let fit = at.fit(&row.id).unwrap();
            let inside: Vec<&Item> = items
                .iter()
                .filter(|i| {
                    let r = rect_of(i);
                    r.y >= rect.y && r.y + r.h <= rect.y + rect.h + 1e-9 && r.x > rect.x
                })
                .collect();
            let blocks: Vec<(&String, usize, Rect)> = inside
                .iter()
                .filter_map(|i| match i {
                    Item::Block { text, lines, rect, .. } => Some((text, *lines, *rect)),
                    Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Line { .. } => None,
                })
                .collect();
            // The steps the fit gives lines to, in order, each with its own
            // lines and exactly that high.
            let drawn = list::drawn(&row.what);
            assert_eq!(blocks.len(), fit.lines.len(), "{}", row.id);
            for (((text, lines, r), want), step) in blocks.iter().zip(&fit.lines).zip(&drawn) {
                assert_eq!(*text, step, "{}", row.id);
                assert_eq!(lines, want, "{}", row.id);
                assert_eq!(r.h, *want as f64 * side::ASK_LINE_HEIGHT, "{}", row.id);
            }
            // Top to bottom with nothing between and nothing left over: the
            // last thing drawn ends where the row's padding begins.
            let bottom = inside.iter().map(|i| rect_of(i)).map(|r| r.y + r.h).fold(0.0, f64::max);
            assert!((bottom - (rect.y + rect.h - side::ROW_PADDING_Y)).abs() < 1e-9, "{}: {bottom} in {rect:?}", row.id);
            // And it is set in the primary colour: it is the heaviest thing
            // on the row.
            for i in &inside {
                if let Item::Block { style, .. } = i {
                    assert_eq!(style.color, look::theme(false).text);
                    assert_eq!(style.face == Face::Mono, list::is_code(&row.what));
                }
            }
        }
    }

    #[test]
    fn steps_that_are_not_shown_are_counted_on_the_row_and_so_are_the_others_waiting() {
        let mut l = list();
        let row = &mut l.waiting[0];
        row.what.lines = (1..=8).map(|n| format!("&& step{n}")).collect();
        row.others = 2;
        let id = row.id.clone();
        let at = ListLayout::new(&l, 900.0);
        let fit = at.fit(&id).unwrap();
        assert_eq!((fit.lines.len(), fit.hidden), (5, 3));
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"3 more steps".to_string()), "{said:?}");
        assert!(said.contains(&"2 more".to_string()), "{said:?}");
        // The sixth step and after are not drawn; the first five are.
        assert!(said.contains(&"&& step5".to_string()) && !said.contains(&"&& step6".to_string()));
    }

    #[test]
    fn who_is_waiting_is_at_the_right_with_the_workers_name_in_the_terminals_face() {
        let l = list();
        let items = scene(&l, None, false, 1.0, None);
        let row = l.waiting.iter().find(|r| !r.waiter.name.is_empty()).expect("the fixture has a worker waiting");
        let mut found = false;
        for item in &items {
            let Item::Line { parts, .. } = item else { continue };
            for p in parts {
                if let Piece::Words { text, style } = &p.piece {
                    if *text == row.waiter.name {
                        assert_eq!(style.face, Face::Mono);
                        // From the right, and the first to give way to a
                        // long group name (`place_line`).
                        assert_eq!(p.side, Side::Squeezed);
                        found = true;
                    } else if p.side == Side::Trail || p.side == Side::Squeezed {
                        assert_eq!(style.face, Face::Ui, "{text:?}");
                    }
                }
            }
        }
        assert!(found, "{} is not on its row", row.waiter.name);
    }

    #[test]
    fn a_quiet_row_says_what_the_group_is_doing_after_its_name() {
        let mut l = list();
        let row = &mut l.quiet[0];
        row.word = "working".into();
        row.what.lines.clear();
        row.what.cut = crate::snapshot::Cut::None;
        assert_eq!(quiet_text(row), "working");
        row.what.lines = vec!["fix the login page".into()];
        assert_eq!(quiet_text(row), "fix the login page");
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"fix the login page".to_string()));
    }

    #[test]
    fn the_header_numbers_are_the_cores_and_not_how_many_rows_there_are() {
        let mut l = list();
        l.waiting_count = 41;
        l.quiet_count = 17;
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"41 groups waiting for you".to_string()), "{said:?}");
        assert!(said.contains(&"17 groups need nothing from you".to_string()), "{said:?}");
    }

    #[test]
    fn the_rows_are_drawn_in_the_order_they_came() {
        let l = list();
        let said = texts(&scene(&l, None, false, 1.0, None));
        let mut last = 0;
        for row in l.rows() {
            let at = said.iter().position(|t| t == row.name()).unwrap_or_else(|| panic!("{} is not drawn", row.id));
            assert!(at >= last, "{} is drawn out of order", row.id);
            last = at;
        }
    }

    #[test]
    fn the_chip_is_under_the_words_and_only_when_something_is_selected() {
        let l = list();
        let first = l.waiting[0].id.clone();
        let rounds = |items: &[Item]| items.iter().filter(|i| matches!(i, Item::Round { radius, .. } if *radius == radius::ROW)).count();
        assert_eq!(rounds(&scene(&l, None, false, 1.0, None)), 0);
        let items = scene(&l, Some(&first), false, 1.0, None);
        assert_eq!(rounds(&items), 1);
        // The panel, then the chip's shadow, then the chip, then
        // everything else.
        assert!(matches!(items[0], Item::Round { radius, .. } if radius == radius::SIDE_PANEL));
        let chip = items.iter().position(|i| matches!(i, Item::Round { radius, .. } if *radius == radius::ROW)).unwrap();
        assert!(chip >= 2, "no shadow under the chip");
        for under in &items[1..chip] {
            assert!(matches!(under, Item::Round { radius, edge: None, .. } if *radius > radius::ROW), "{under:?}");
        }
        assert!(items[chip + 1..].iter().all(|i| !matches!(i, Item::Round { .. })));
        let at = ListLayout::new(&l, 900.0);
        assert_eq!(rect_of(&items[chip]), at.chip(Some(&first)).unwrap());
    }

    #[test]
    fn a_lifted_chips_shadow_reaches_further_down() {
        let l = list();
        let first = l.waiting[0].id.clone();
        let at = ListLayout::new(&l, 900.0);
        let chip = at.chip(Some(&first)).unwrap();
        let lowest = |lift: f64| {
            let view = View { theme: look::theme(false), scale: 1.0, selection: Some(&first), lit: Lit::Selection, chip: Some(chip), lift, pulsing: None, naming: None };
            build(&l, &at, &view, &same)
                .iter()
                .filter_map(|i| match i {
                    Item::Round { rect, radius, .. } if *radius > radius::ROW && *radius < radius::SIDE_PANEL => Some(rect.y + rect.h),
                    _ => None,
                })
                .fold(f64::MIN, f64::max)
        };
        assert!(lowest(0.0) > chip.y + chip.h);
        assert!(lowest(1.0) > lowest(0.0));
    }

    #[test]
    fn under_a_sliding_chip_every_row_reads_selected_and_outside_it_none_does() {
        // The two passes a host draws while the chip is between rows.
        let l = list();
        let (first, second) = (l.waiting[0].id.clone(), l.waiting[1].id.clone());
        let at = ListLayout::new(&l, 900.0);
        let names = |lit: Lit| {
            let view = View { theme: look::theme(true), scale: 1.0, selection: Some(&second), lit, chip: at.chip(Some(&second)), lift: 1.0, pulsing: None, naming: None };
            let items = build(&l, &at, &view, &same);
            [&first, &second].map(|id| {
                items.iter().find_map(|i| match i {
                    Item::Line { parts, .. } => parts.iter().find_map(|p| match &p.piece {
                        Piece::Words { text, style } if text == id => Some(style.weight),
                        _ => None,
                    }),
                    _ => None,
                })
            })
        };
        assert_eq!(names(Lit::Selection), [Some(font::WEIGHT_GROUP_NAME), Some(font::WEIGHT_STRONG)]);
        assert_eq!(names(Lit::Every), [Some(font::WEIGHT_STRONG), Some(font::WEIGHT_STRONG)]);
        assert_eq!(names(Lit::Nobody), [Some(font::WEIGHT_GROUP_NAME), Some(font::WEIGHT_GROUP_NAME)]);
        // Both passes have the chip in them, in the same place: what
        // differs is only how the rows are written.
        let chips = |lit: Lit| {
            let view = View { theme: look::theme(true), scale: 1.0, selection: Some(&second), lit, chip: at.chip(Some(&second)), lift: 1.0, pulsing: None, naming: None };
            build(&l, &at, &view, &same).into_iter().filter(|i| matches!(i, Item::Round { radius, .. } if *radius == radius::ROW)).count()
        };
        assert_eq!((chips(Lit::Every), chips(Lit::Nobody)), (1, 1));
    }

    #[test]
    fn the_selected_rows_name_is_set_heavier() {
        let l = list();
        let first = l.waiting[0].id.clone();
        let weight_of = |items: &[Item]| {
            items.iter().find_map(|i| match i {
                Item::Line { parts, .. } => parts.iter().find_map(|p| match &p.piece {
                    Piece::Words { text, style } if *text == first => Some(style.weight),
                    _ => None,
                }),
                _ => None,
            })
        };
        assert_eq!(weight_of(&scene(&l, None, false, 1.0, None)), Some(font::WEIGHT_GROUP_NAME));
        assert_eq!(weight_of(&scene(&l, Some(&first), false, 1.0, None)), Some(font::WEIGHT_STRONG));
    }

    fn pulsing_glyphs(items: &[Item]) -> usize {
        items
            .iter()
            .map(|i| match i {
                Item::Line { parts, .. } => parts.iter().filter(|p| matches!(p.piece, Piece::Glyph { pulses: true, .. })).count(),
                _ => 0,
            })
            .sum()
    }

    #[test]
    fn one_glyph_breathes_and_it_is_the_row_that_was_named() {
        let l = list();
        assert_eq!(pulsing_glyphs(&scene(&l, None, false, 1.0, None)), 0);
        let second = l.waiting[1].id.clone();
        assert_eq!(pulsing_glyphs(&scene(&l, None, false, 1.0, Some(&second))), 1);
    }

    #[test]
    fn a_dark_trouble_word_on_the_selected_row_is_the_colour_the_table_gives() {
        let l = list();
        let Some(row) = l.rows().find(|r| r.shown == Shown::Trouble) else {
            panic!("the fixture has a row in trouble");
        };
        let dark = look::theme(true);
        let colour_of = |selection: Option<&str>| {
            scene(&l, selection, true, 1.0, None).iter().find_map(|i| match i {
                Item::Line { parts, .. } => parts.iter().find_map(|p| match &p.piece {
                    Piece::Words { text, style } if *text == row.word && style.weight == font::WEIGHT_EMPHASIS => Some(style.color),
                    _ => None,
                }),
                _ => None,
            })
        };
        assert_eq!(colour_of(Some(&row.id)), Some(dark.problem_text_on_row_selected));
        assert_ne!(dark.problem_text_on_row_selected, dark.problem_text_on_row);
    }

    #[test]
    fn a_row_read_out_says_what_the_row_draws() {
        let l = list();
        for row in l.rows() {
            let said = spoken(row, &same);
            assert!(said.starts_with(row.name()), "{said}");
            if !row.word.is_empty() {
                assert!(said.contains(&row.word), "{said} leaves out the status word {:?}", row.word);
            }
            // Every step of what it waits on, none dropped.
            for line in &row.what.lines {
                assert!(said.contains(line.as_str()), "{said} leaves out {line:?}");
            }
            if let Some((template, arg)) = list::waiter(&row.waiter) {
                assert!(said.contains(&list::fill(template, &arg)), "{said} does not say who is waiting");
            }
            if row.others > 0 {
                assert!(said.contains(&format!("{} more", row.others)), "{said}");
            }
            assert!(!said.contains(", ,") && !said.ends_with(", "), "{said}");
        }
        // Two rows are never read out the same.
        let all: Vec<String> = l.rows().map(|r| spoken(r, &same)).collect();
        for i in 0..all.len() {
            for j in i + 1..all.len() {
                assert_ne!(all[i], all[j]);
            }
        }
    }

    #[test]
    fn a_group_is_the_same_number_wherever_it_is_listed_and_two_groups_are_two() {
        let l = list();
        assert_eq!(stable_id("web-app"), stable_id("web-app"));
        let ids: Vec<u64> = l.rows().map(|r| stable_id(&r.id)).collect();
        for i in 0..ids.len() {
            for j in i + 1..ids.len() {
                assert_ne!(ids[i], ids[j]);
            }
        }
        // FNV-1a's own published value, so the function is the one it says.
        assert_eq!(stable_id(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(stable_id("a"), 0xaf63_dc4c_8601_ec8c);
    }

    #[test]
    fn a_clock_is_wanted_only_while_something_breathes_or_spins() {
        let mut l = list();
        let first = l.waiting[0].id.clone();
        // The fixture has a group at work, whose spinner turns.
        assert!(l.rows().any(|r| r.shown == Shown::Working));
        assert!(moves(&scene(&l, None, false, 1.0, None)));
        // With nobody at work, nothing moves until a glyph is told to breathe.
        l.quiet.retain(|r| r.shown != Shown::Working);
        l.waiting.retain(|r| r.shown != Shown::Working);
        assert!(!moves(&scene(&l, None, false, 1.0, None)));
        assert!(moves(&scene(&l, None, false, 1.0, Some(&first))));
        assert!(glyph_moves(Shown::NeedsYou, true));
        assert!(!glyph_moves(Shown::NeedsYou, false));
        assert!(!glyph_moves(Shown::Trouble, false));
    }

    #[test]
    fn a_hairline_is_one_pixel_at_every_scale_up_to_two_and_fainter_below_it() {
        assert_eq!(hairline(1.0), (1.0, 0.5));
        let (h, s) = hairline(1.25);
        assert!((h * 1.25 - 1.0).abs() < 1e-9 && (s - 0.625).abs() < 1e-9);
        let (h, s) = hairline(1.5);
        assert!((h * 1.5 - 1.0).abs() < 1e-9 && (s - 0.75).abs() < 1e-9);
        assert_eq!(hairline(2.0), (0.5, 1.0));
        let (h, s) = hairline(3.0);
        assert!((h * 3.0 - 2.0).abs() < 1e-9 && (s - 0.75).abs() < 1e-9);
    }

    #[test]
    fn laying_a_colour_over_another_goes_from_one_to_the_other() {
        let base = Rgba { r: 0, g: 100, b: 200, a: 1.0 };
        assert_eq!(over(base, WHITE, 0.0), base);
        assert_eq!(over(base, WHITE, 1.0), WHITE);
        assert_eq!(over(base, WHITE, 0.5), Rgba { r: 128, g: 178, b: 228, a: 1.0 });
        // The top colour's own alpha counts.
        assert_eq!(over(base, Rgba { a: 0.5, ..WHITE }, 1.0), over(base, WHITE, 0.5));
    }

    fn right(detail: &Detail_, row: Option<&Row>, in_terminal: bool) -> Right {
        build_right(detail, row, 600.0, 700.0, look::theme(false), 1.0, in_terminal, &same)
    }

    #[test]
    fn the_right_side_says_which_nothing_it_is_and_offers_the_tab_only_for_another_window() {
        use crate::lend::Loan;
        let l = list();
        let with = l.rows().find(|r| r.steward.is_some()).expect("the fixture has a group with a supervisor");
        let loan = Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() };

        let r = right(&Detail_::Elsewhere(loan.clone()), Some(with), false);
        assert!(r.go.is_some() && r.terminal.is_none());
        assert!(texts(&r.items).contains(&with.id));
        assert!(texts(&r.items).contains(&msg::IN_ITS_OWN_TAB.to_string()));
        assert!(texts(&r.items).contains(&msg::GO_TO_ITS_TAB.to_string()));

        let r = right(&Detail_::NoSupervisor { group: with.id.clone() }, Some(with), false);
        assert!(r.go.is_none() && r.terminal.is_none());
        assert!(texts(&r.items).contains(&msg::NO_SUPERVISOR.to_string()));

        let r = right(&Detail_::SupervisorGone { group: with.id.clone() }, Some(with), false);
        assert!(r.go.is_none() && r.terminal.is_none());
        assert!(texts(&r.items).contains(&lend_msg::GONE.to_string()));

        let r = right(&Detail_::TakenBack(loan), Some(with), false);
        assert!(r.go.is_none() && r.terminal.is_none());
        assert!(texts(&r.items).contains(&msg::IN_ITS_OWN_TAB.to_string()));

        let r = right(&Detail_::NothingSelected, None, false);
        assert!(r.go.is_none() && r.terminal.is_none());
        assert_eq!(texts(&r.items), vec![msg::NO_SELECTION.to_string()]);
    }

    #[test]
    fn a_borrowed_terminal_sits_under_the_title_bar_inside_the_frames_border() {
        use crate::lend::Loan;
        let l = list();
        let with = l.rows().find(|r| r.steward.is_some()).unwrap();
        let loan = Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() };
        let r = right(&Detail_::Terminal(loan), Some(with), false);
        let t = r.terminal.expect("the terminal has a place");
        assert_eq!(t, terminal_rect(600.0, 700.0));
        assert_eq!((t.x, t.y), (pane::SUPERVISOR_BORDER, pane::BAR_HEIGHT));
        assert_eq!(t.x + t.w, 600.0 - pane::SUPERVISOR_BORDER);
        assert_eq!(t.y + t.h, 700.0 - pane::SUPERVISOR_BORDER);
        assert!(r.go.is_none());
        // The bar says whose it is, what it is, and its state.
        let said = texts(&r.items);
        assert!(said.contains(&with.id) && said.contains(&lend_msg::SUPERVISOR.to_string()) && said.contains(&with.word), "{said:?}");
        // Nothing but the terminal's own ground is drawn where the terminal goes.
        for item in &r.items {
            let b = rect_of(item);
            let overlaps = b.x < t.x + t.w && b.x + b.w > t.x && b.y < t.y + t.h && b.y + b.h > t.y;
            let is_frame = matches!(item, Item::Round { .. });
            let is_ground = matches!(item, Item::Fill { rect, .. } if *rect == t);
            assert!(!overlaps || is_frame || is_ground, "{item:?} is drawn over the terminal");
        }
        // A window too small for one has an empty place, not a negative one.
        assert_eq!(terminal_rect(4.0, 10.0).w, 0.0);
        assert_eq!(terminal_rect(4.0, 10.0).h, 0.0);
    }

    #[test]
    fn the_frames_edge_says_whether_the_terminal_in_it_has_the_keyboard() {
        use crate::lend::Loan;
        let l = list();
        let with = l.rows().find(|r| r.steward.is_some()).unwrap();
        let loan = Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() };
        let edge_of = |r: &Right| match &r.items[0] {
            Item::Round { edge, .. } => *edge,
            other => panic!("the frame is drawn first, not {other:?}"),
        };
        let resting = right(&Detail_::Terminal(loan.clone()), Some(with), false);
        let typing = right(&Detail_::Terminal(loan), Some(with), true);
        assert_ne!(edge_of(&resting), edge_of(&typing));
    }

    #[test]
    fn a_list_that_could_not_be_read_is_a_sentence_and_not_an_empty_panel() {
        let items = build_message(side::WIDTH, 400.0, look::theme(false), 1.0, "why".into());
        assert_eq!(texts(&items), vec!["why".to_string()]);
    }

    // ---- a line's parts: what keeps its width (task 1444, defect 3)

    #[test]
    fn a_long_worker_title_never_takes_the_groups_name_off_its_row() {
        use Side::*;
        // name, "<worker>" + ", via the supervisor", status word; 322 wide.
        let parts = |name: i32, who: i32| [(Lead, 0, name), (Squeezed, 8, who), (Squeezed, 0, 120), (Trail, 8, 48)];
        // Everything fits: each at its width, the waiter against the word.
        let fit = place_line(0, 322, &parts(60, 70));
        assert_eq!(fit[0], Some(Placed { left: 0, right: 60, cut: false }));
        assert_eq!(fit[3], Some(Placed { left: 274, right: 322, cut: false }));
        assert_eq!(fit[2], Some(Placed { left: 146, right: 266, cut: false }));
        assert_eq!(fit[1], Some(Placed { left: 76, right: 146, cut: false }));
        // A worker's title far too long for the row: the name is whole, the
        // word is whole, and the title is what is cut.
        let long = place_line(0, 322, &parts(60, 400));
        assert_eq!(long[0], Some(Placed { left: 0, right: 60, cut: false }));
        assert_eq!(long[3], Some(Placed { left: 274, right: 322, cut: false }));
        assert_eq!(long[2], Some(Placed { left: 146, right: 266, cut: false }));
        assert_eq!(long[1], Some(Placed { left: 68, right: 146, cut: true }));
        // A long name too: it is cut only where the status word begins,
        // and who is waiting has no room and is left out.
        let both = place_line(0, 322, &parts(300, 400));
        assert_eq!(both[0], Some(Placed { left: 0, right: 266, cut: true }));
        assert_eq!(both[3], Some(Placed { left: 274, right: 322, cut: false }));
        assert_eq!((both[1], both[2]), (None, None));
        // Nothing is ever placed outside the line or over the status word.
        for name in [0, 40, 200, 266, 267, 900] {
            for who in [0, 30, 200, 900] {
                let placed = place_line(10, 332, &parts(name, who));
                for (i, p) in placed.iter().enumerate() {
                    let Some(p) = p else { continue };
                    assert!(p.left >= 10 && p.right <= 332 && p.left < p.right, "{name} {who}: {placed:?}");
                    assert!(i == 3 || p.right <= placed[3].unwrap().left, "{name} {who}: {placed:?}");
                }
                assert!(placed[0].is_some() || name == 0, "the name is gone at {name} {who}: {placed:?}");
            }
        }
    }

    #[test]
    fn the_rest_of_a_line_is_what_the_others_leave_as_it_always_was() {
        use Side::*;
        let placed = place_line(0, 300, &[(Lead, 0, 50), (Rest, 8, 999), (Trail, 8, 40)]);
        assert_eq!(placed[1], Some(Placed { left: 58, right: 252, cut: true }));
        // With no room between them it is not drawn.
        let none = place_line(0, 100, &[(Lead, 0, 70), (Rest, 8, 999), (Trail, 8, 40)]);
        assert_eq!(none[1], None);
        assert_eq!(none[0], Some(Placed { left: 0, right: 52, cut: true }));
    }

    #[test]
    fn on_a_waiting_row_the_name_leads_and_only_who_is_waiting_gives_way() {
        let l = list();
        let items = scene(&l, None, false, 1.0, None);
        for row in &l.waiting {
            let line = items
                .iter()
                .find_map(|i| match i {
                    Item::Line { parts, .. } => parts
                        .iter()
                        .any(|p| matches!(&p.piece, Piece::Words { text, style } if text == row.name() && style.size == font::GROUP_NAME))
                        .then_some(parts),
                    Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } => None,
                })
                .unwrap_or_else(|| panic!("{} has no first line", row.id));
            assert_eq!(line[0].side, Side::Lead, "{}", row.id);
            assert_eq!(line.last().unwrap().side, Side::Trail, "{}", row.id);
            assert!(line[1..line.len() - 1].iter().all(|p| p.side == Side::Squeezed), "{}: {line:?}", row.id);
        }
    }

    // ---- a new group

    fn naming_scene(refusal: Option<&str>) -> Vec<Item> {
        let l = list();
        let at = ListLayout::new(&l, 900.0);
        let view = View { theme: look::theme(false), scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: Some(Naming { refusal }) };
        build(&l, &at, &view, &same)
    }

    #[test]
    fn the_header_ends_in_the_one_button_and_naming_a_group_puts_a_field_where_it_was() {
        let l = list();
        let at = ListLayout::new(&l, 900.0);
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"+ New Group".to_string()), "{said:?}");
        // Where it is pressed is inside the header, at its right end.
        let hit = new_group_hit(at.header);
        assert_eq!((hit.x + hit.w, hit.y, hit.h), (at.header.x + at.header.w, at.header.y, at.header.h));
        assert!(hit.x > at.header.x + at.header.w / 2.0);

        let naming = naming_scene(None);
        let said = texts(&naming);
        assert!(!said.contains(&"+ New Group".to_string()) && !said.iter().any(|t| t.contains("waiting for you")), "{said:?}");
        let (outline, typed) = name_field(at.header);
        assert!(naming.iter().any(|i| matches!(i, Item::Round { rect, edge: Some(e), .. } if *rect == outline && *e == look::theme(false).attention_text)));
        // What is typed sits inside the outline, a line high, in its middle.
        assert!(typed.x > outline.x && typed.x + typed.w < outline.x + outline.w);
        assert_eq!(typed.y - outline.y, outline.y + outline.h - (typed.y + typed.h));
        assert_eq!(typed.h, side::ASK_LINE_HEIGHT);
    }

    #[test]
    fn why_a_name_made_no_group_is_said_under_the_field_over_the_rows_and_last() {
        let l = list();
        let at = ListLayout::new(&l, 900.0);
        let why = "There is already a group by that name.";
        let items = naming_scene(Some(why));
        let Some(Item::Block { rect, text, style, .. }) = items.last() else { panic!("the note is not last: {:?}", items.last()) };
        assert_eq!(text, why);
        assert_eq!(style.color, look::theme(false).problem_text_on_row);
        let note = name_note(at.header);
        assert_eq!(note.y, at.header.y + at.header.h);
        assert!(rect.y >= note.y && rect.y + rect.h <= note.y + note.h && rect.x >= note.x);
        // Without a refusal there is no note at all.
        assert!(!texts(&naming_scene(None)).contains(&why.to_string()));
    }

    // ---- starting a supervisor

    fn start_row(state: crate::snapshot::SupervisorState, can_start: bool, failed: crate::snapshot::StartFailure) -> Row {
        let mut row = list().quiet[0].clone();
        row.start = Some(crate::snapshot::SupervisorStart { state, can_start, failed, role: Some("polter-supervisor".into()), cwd: "/Users/me/work".into() });
        row
    }

    fn roles() -> Vec<crate::snapshot::SupervisorRole> {
        vec![
            crate::snapshot::SupervisorRole { key: "polter-supervisor".into(), name: "Polter Supervisor".into() },
            crate::snapshot::SupervisorRole { key: "reviewer".into(), name: "Reviewer".into() },
        ]
    }

    #[test]
    fn which_sentence_a_group_with_no_supervisor_gets_is_the_cores_word() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let says = |s, f| no_supervisor_words(start_row(s, true, f).start.as_ref());
        assert_eq!(says(S::Absent, F::None), msg::NO_SUPERVISOR);
        assert_eq!(says(S::Starting, F::None), msg::STARTING);
        assert_eq!(says(S::Failed, F::TerminalNeverOpened), msg::NEVER_OPENED);
        assert_eq!(says(S::Failed, F::AgentNeverConnected), msg::NEVER_CONNECTED);
        assert_eq!(says(S::Failed, F::TerminalClosed), msg::CLOSED_FIRST);
        // What the launcher said itself, each with its own sentence, and
        // neither the timer's.
        assert_eq!(says(S::Failed, F::CliNotFound), msg::CLI_NOT_FOUND);
        assert_eq!(says(S::Failed, F::CliDidNotStart), msg::CLI_DID_NOT_START);
        assert_ne!(msg::CLI_NOT_FOUND, msg::CLI_DID_NOT_START);
        assert_ne!(msg::CLI_NOT_FOUND, msg::NEVER_CONNECTED);
        assert_eq!(says(S::Failed, F::None), msg::DID_NOT_START);
        assert_eq!(no_supervisor_words(None), msg::NO_SUPERVISOR);
        // And it is what the right side draws.
        let row = start_row(S::Failed, true, F::TerminalClosed);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let right = build_right(&detail, Some(&row), 600.0, 600.0, look::theme(false), 1.0, false, &same);
        assert!(all_text(&right.items).contains(&msg::CLOSED_FIRST));
    }

    #[test]
    fn the_button_is_there_only_when_the_core_says_one_can_be_started() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let all = roles();
        let view = StartView { roles: &all, choose_role: false, home: "/Users/me", ..Default::default() };
        let theme = look::theme(false);
        let offered = |row: Option<&Row>, detail: &Detail_| build_start(detail, row, 600.0, theme, &view, &same);
        let row = start_row(S::Absent, true, F::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let shown = offered(Some(&row), &detail);
        assert!(shown.start.is_some() && shown.directory.is_some());
        assert!(all_text(&shown.items).contains(&msg::START_SUPERVISOR));
        // Not on the state: the core's `can_start` alone.
        for (state, can) in [(S::Absent, false), (S::Starting, false), (S::Failed, false), (S::Present, false)] {
            let row = start_row(state, can, F::None);
            assert_eq!(offered(Some(&row), &detail), Start::default(), "{state:?}");
        }
        let failed = start_row(S::Failed, true, F::AgentNeverConnected);
        assert!(offered(Some(&failed), &detail).start.is_some());
        // A row the core says nothing about, no row, and any other detail.
        let mut silent = row.clone();
        silent.start = None;
        assert_eq!(offered(Some(&silent), &detail), Start::default());
        assert_eq!(offered(None, &detail), Start::default());
        assert_eq!(offered(Some(&row), &Detail_::NothingSelected), Start::default());
        assert_eq!(offered(Some(&row), &Detail_::SupervisorGone { group: row.id.clone() }), Start::default());
    }

    #[test]
    fn the_role_is_offered_only_when_the_core_says_there_is_a_choice() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let all = roles();
        let row = start_row(S::Absent, true, F::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let theme = look::theme(false);
        // Two roles listed and the core says no choice: none is offered.
        let one = build_start(&detail, Some(&row), 600.0, theme, &StartView { roles: &all, choose_role: false, home: "", ..Default::default() }, &same);
        assert_eq!(one.role, None);
        assert!(!all_text(&one.items).contains(&msg::ROLE));
        let two = build_start(&detail, Some(&row), 600.0, theme, &StartView { roles: &all, choose_role: true, home: "", ..Default::default() }, &same);
        assert!(two.role.is_some());
        // The core's role until the person picks another; Polter's own under its shown name.
        assert!(all_text(&two.items).contains(&msg::POLTER_SUPERVISOR));
        let picked = build_start(&detail, Some(&row), 600.0, theme, &StartView { roles: &all, choose_role: true, role: Some("reviewer"), home: "", ..Default::default() }, &same);
        assert!(all_text(&picked.items).contains(&"Reviewer") && !all_text(&picked.items).contains(&msg::POLTER_SUPERVISOR));
        // The three things to press do not overlap, top to bottom.
        let (r, d, s) = (two.role.unwrap(), two.directory.unwrap(), two.start.unwrap());
        assert!(r.y + r.h <= d.y && d.y + d.h <= s.y);
    }

    #[test]
    fn the_directory_is_the_cores_until_another_is_picked_and_home_is_a_tilde() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let row = start_row(S::Absent, true, F::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let theme = look::theme(false);
        let shown = |cwd: Option<&str>, home: &str| {
            let s = build_start(&detail, Some(&row), 600.0, theme, &StartView { cwd, home, ..Default::default() }, &same);
            all_text(&s.items).into_iter().map(str::to_string).collect::<Vec<_>>()
        };
        assert!(shown(None, "/Users/me").contains(&"~/work".to_string()));
        assert!(shown(Some("/srv/x"), "/Users/me").contains(&"/srv/x".to_string()));
        assert_eq!(shown_directory("/Users/me", "/Users/me", &same), "~");
        assert_eq!(shown_directory("C:\\Users\\me\\src", "C:\\Users\\me", &same), "~\\src");
        // Another directory that only starts with the same letters is not under home.
        assert_eq!(shown_directory("/Users/meg/x", "/Users/me", &same), "/Users/meg/x");
        assert_eq!(shown_directory("", "/Users/me", &same), msg::WHERE_THE_TAB_STARTS);
        assert_eq!(shown_directory("/x", "", &same), "/x");
    }

    #[test]
    fn why_a_press_did_nothing_is_said_under_the_button_and_nothing_empty_is_drawn() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let row = start_row(S::Absent, true, F::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let theme = look::theme(false);
        let why = "That directory is not there.";
        let said = build_start(&detail, Some(&row), 600.0, theme, &StartView { refusal: Some(why), home: "", ..Default::default() }, &same);
        let Some(Item::Block { rect, text, .. }) = said.items.last() else { panic!("{:?}", said.items.last()) };
        assert_eq!(text, why);
        assert!(rect.y >= said.start.unwrap().y + said.start.unwrap().h);
        for refusal in [None, Some("")] {
            let s = build_start(&detail, Some(&row), 600.0, theme, &StartView { refusal, choose_role: true, home: "", ..Default::default() }, &same);
            assert!(all_text(&s.items).iter().all(|t| draws(t)), "{refusal:?}");
            assert!(!matches!(s.items.last(), Some(Item::Block { .. })));
        }
        // What it offers starts under the sentence, which has two lines.
        let top = said.directory.unwrap().y;
        assert!(top >= space::FRAME_TO_CONTENT + side::HEADER_HEIGHT + 2.0 * side::ASK_LINE_HEIGHT);
    }

    // ---- a terminal in no group: its row, and the right side (task 1471)

    const LONE: &str = "terminal:0x00000000000000c1";

    fn lone_row(pane: crate::snapshot::Pane) -> Row {
        let mut row = list().row(LONE).unwrap().clone();
        row.alone.as_mut().unwrap().pane = pane;
        row
    }

    #[test]
    fn a_lone_terminals_row_is_drawn_under_its_title_never_its_id() {
        let l = list();
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"zsh — ~/work".to_string()), "{said:?}");
        assert!(!said.iter().any(|t| t.contains("terminal:0x")), "{said:?}");
        // It waits like any other row: its status word and what it waits on.
        assert!(said.contains(&"git push".to_string()), "{said:?}");
        // Read out, it is its title too, and says nobody is beside it.
        let spoken = spoken(l.row(LONE).unwrap(), &same);
        assert!(spoken.starts_with("zsh — ~/work, 等批准"), "{spoken}");
        // It is selected by its row's identity, and lit like any other.
        let at = ListLayout::new(&l, 900.0);
        assert!(at.chip(Some(LONE)).is_some());
        let lit = scene(&l, Some(LONE), false, 1.0, None);
        let weights: Vec<f64> = lit
            .iter()
            .filter_map(|i| match i {
                Item::Line { parts, .. } => parts.iter().find_map(|p| match &p.piece {
                    Piece::Words { text, style } if text == "zsh — ~/work" => Some(style.weight),
                    Piece::Words { .. } | Piece::Glyph { .. } | Piece::Held { .. } => None,
                }),
                Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } => None,
            })
            .collect();
        assert_eq!(weights, [font::WEIGHT_STRONG]);
    }

    #[test]
    fn the_bar_over_the_right_side_says_what_a_lone_terminal_is_and_not_always_supervisor() {
        use crate::snapshot::Pane;
        let bar = |row: &Row| -> Vec<String> {
            let loan = crate::lend::Loan { group: row.id.clone(), terminal: row.steward.clone().unwrap() };
            let r = right(&Detail_::Terminal(loan), Some(row), false);
            r.items
                .iter()
                .find_map(|i| match i {
                    Item::Line { parts, .. } => Some(
                        parts
                            .iter()
                            .filter_map(|p| match &p.piece {
                                Piece::Words { text, .. } => Some(text.clone()),
                                Piece::Glyph { .. } | Piece::Held { .. } => None,
                            })
                            .collect(),
                    ),
                    Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } => None,
                })
                .unwrap()
        };
        // An ordinary agent: its title and its state, and no word between.
        assert_eq!(bar(&lone_row(Pane::Plain)), ["zsh — ~/work", "等批准"]);
        // A worker somebody minds says so; a supervisor with no group too.
        assert_eq!(bar(&lone_row(Pane::Worker)), ["zsh — ~/work", "Worker", "等批准"]);
        assert_eq!(bar(&lone_row(Pane::Supervisor)), ["zsh — ~/work", "Supervisor", "等批准"]);
        // A group's supervisor: the group's name and "Supervisor", as ever.
        let l = list();
        let group = l.row("web-app").unwrap();
        assert_eq!(bar(group)[..2], ["web-app".to_string(), "Supervisor".to_string()]);
        // Never the row's identity.
        assert!(!bar(&lone_row(Pane::Plain)).iter().any(|t| t.contains("terminal:")));
    }

    #[test]
    fn what_the_right_side_says_of_a_lone_terminal_that_is_not_shown_is_said_of_a_terminal() {
        let row = lone_row(crate::snapshot::Pane::Plain);
        let loan = crate::lend::Loan { group: row.id.clone(), terminal: "0x00000000000000c1".to_string() };
        let said = |d: &Detail_, row: Option<&Row>| -> Vec<String> { all_text(&right(d, row, false).items).into_iter().map(str::to_string).collect() };
        for (detail, sentence) in [
            (Detail_::SupervisorGone { group: row.id.clone() }, msg::TERMINAL_GONE),
            (Detail_::NoSupervisor { group: row.id.clone() }, msg::TERMINAL_GONE),
            (Detail_::TakenBack(loan.clone()), msg::TERMINAL_IN_ITS_OWN_TAB),
            (Detail_::Elsewhere(loan.clone()), msg::TERMINAL_IN_ITS_OWN_TAB),
        ] {
            let texts = said(&detail, Some(&row));
            assert!(texts.contains(&sentence.to_string()), "{detail:?}: {texts:?}");
            // Under its title, not its row's identity; nothing about a supervisor.
            assert_eq!(texts[0], "zsh — ~/work", "{detail:?}");
            assert!(!texts.iter().any(|t| t.contains("terminal:0x") || t.contains("supervisor")), "{detail:?}: {texts:?}");
        }
        // The same for a group is said of its supervisor, under the group's name.
        let l = list();
        let group = l.row("web-app").unwrap();
        let texts = said(&Detail_::SupervisorGone { group: "web-app".to_string() }, Some(group));
        assert_eq!(texts, ["web-app", crate::lend::msg::GONE]);
        // Nothing is offered to start for it, whatever the right side shows.
        let view = StartView { home: "", ..Default::default() };
        assert_eq!(build_start(&Detail_::NoSupervisor { group: row.id.clone() }, Some(&row), 600.0, look::theme(false), &view, &same), Start::default());
        // A lone terminal with no title yet: no empty words are handed over.
        let mut untitled = row.clone();
        untitled.alone.as_mut().unwrap().title.clear();
        let texts = said(&Detail_::SupervisorGone { group: row.id.clone() }, Some(&untitled));
        assert!(texts.iter().all(|t| draws(t)), "{texts:?}");
    }
}
