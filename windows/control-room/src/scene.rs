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

use crate::layout::{self, ListLayout, Rect};
use crate::list::{self, Detail, List, Row};
use crate::look::{font, line, radius, selection, side, space, Rgba, Theme};
use crate::snapshot::Shown;

/// The English of what the panel says; `build` passes each through the
/// host's translation. `{}` is where the one argument goes.
pub mod msg {
    pub const WAITING_HEADER: &str = "{} groups waiting for you";
    pub const QUIET_HEADER: &str = "{} groups need nothing from you";
    pub const MINUTES_UNIT: &str = "min";
    pub const BAND_HEADER: &str = "Kept you waiting today";
    pub const BAND_TOTAL: &str = "{} min";
    pub const NOW: &str = "now";
    /// The snapshot could not be read. `{}` is what was wrong with it.
    pub const UNREADABLE: &str = "The control room's data could not be read ({}).";
    /// No snapshot has been worked out yet.
    pub const NOT_YET: &str = "Nothing has been worked out yet.";
    pub const NO_SELECTION: &str = "Select a group on the left.";
    pub const NO_SUPERVISOR: &str = "This group has no supervisor.";
    pub const IN_ITS_OWN_TAB: &str = "The supervisor's terminal is in its own tab.";
    pub const GO_TO_ITS_TAB: &str = "Go to Its Tab";
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
}

#[derive(Debug, Clone, PartialEq)]
pub enum Piece {
    Words { text: String, style: Style },
    Glyph { shown: Shown, color: Rgba, size: f64, pulses: bool },
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

/// The colour of a status word and of the minutes beside it. Where the
/// word is not red is the table's to say (`text_on`).
fn ink(theme: &Theme, shown: Shown, selected: bool) -> (Rgba, Rgba) {
    match shown {
        Shown::NeedsYou | Shown::DoneUnseen => (theme.attention_text, theme.attention_text),
        Shown::Trouble => (
            if selected { theme.problem_text_on_row_selected } else { theme.problem_text_on_row },
            theme.problem_text,
        ),
        Shown::Working | Shown::None => (theme.text_secondary, theme.text_secondary),
    }
}

/// The colour a glyph is filled with.
pub fn glyph_color(theme: &Theme, shown: Shown) -> Rgba {
    match shown {
        Shown::NeedsYou | Shown::DoneUnseen => theme.attention,
        Shown::Trouble => theme.problem,
        Shown::Working | Shown::None => theme.working,
    }
}

/// What `build` is told that the list does not hold.
pub struct View<'a> {
    pub theme: &'a Theme,
    /// Device pixels to the point.
    pub scale: f64,
    pub selection: Option<&'a str>,
    /// Where the chip is right now; `layout.chip(selection)` when it is at
    /// rest, somewhere on the way when it is sliding.
    pub chip: Option<Rect>,
    /// 0 with the chip at rest, 1 with it in the air.
    pub lift: f64,
    /// The row whose glyph breathes (`pulse::pulsing_row`).
    pub pulsing: Option<&'a str>,
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

    // The chip goes under everything it lights.
    if let Some(chip) = view.chip {
        let color = chip_color(theme, view.lift);
        let edge = theme.selection_edge;
        let toward = if edge < 0.0 { BLACK } else { WHITE };
        out.push(Item::Round { rect: chip, radius: radius::ROW, color, edge: Some(over(color, toward, edge.abs())) });
    }

    let (hair_h, hair_strength) = hairline(view.scale);
    let hair = |r: Rect, under: Rgba| fill(Rect { x: r.x, y: r.y, w: r.w, h: hair_h }, over(under, theme.line_faint, hair_strength));

    out.push(Item::Text {
        rect: inset_x(at.header, side::HEADER_PADDING_X),
        text: list::fill(&tr(msg::WAITING_HEADER), &list.waiting_count.to_string()),
        style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.text) },
        align: Align::Left,
    });

    for row in &list.waiting {
        if let Some(rect) = at.chip(Some(&row.id)) {
            waiting_row(&mut out, row, rect, view, tr);
        }
    }

    out.push(hair(at.separator, panel));
    out.push(Item::Text {
        rect: inset_x(at.quiet_header, side::HEADER_PADDING_X),
        text: list::fill(&tr(msg::QUIET_HEADER), &list.quiet_count.to_string()),
        style: body(theme.text_secondary),
        align: Align::Left,
    });

    for row in &list.quiet {
        let Some(rect) = at.chip(Some(&row.id)) else { continue };
        let selected = view.selection == Some(row.id.as_str());
        let color = if selected { theme.text } else { theme.text_secondary };
        let mut parts = vec![words(
            row.id.clone(),
            Style {
                size: font::BODY,
                weight: if selected { font::WEIGHT_EMPHASIS } else { font::WEIGHT_BODY },
                face: Face::Mono,
                color,
            },
            Side::Rest,
            0.0,
        )];
        parts.push(words(row.word.clone(), body(color), Side::Trail, side::ROW_ITEM_GAP));
        if row.shown != Shown::None {
            parts.push(Part {
                piece: Piece::Glyph { shown: row.shown, color: glyph_color(theme, row.shown), size: side::GLYPH, pulses: false },
                side: Side::Trail,
                gap: side::QUIET_ITEM_GAP,
            });
        }
        out.push(Item::Line { rect: inset_x(rect, side::ROW_PADDING_X), parts });
    }

    // Today's waiting, hung from the bottom.
    let band = &list.band;
    out.push(hair(at.band_header, panel));
    out.push(Item::Text {
        rect: at.band_header,
        text: tr(msg::BAND_HEADER),
        style: body(theme.text_secondary),
        align: Align::Left,
    });
    out.push(Item::Text {
        rect: at.band_header,
        text: list::fill(&tr(msg::BAND_TOTAL), &band.total_min.to_string()),
        style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.text) },
        align: Align::Right,
    });
    for (lane, rect) in band.lanes.iter().zip(at.lanes.iter()) {
        out.push(Item::Text {
            rect: Rect { x: rect.x, y: rect.y, w: side::TIME_LANE_LABEL_WIDTH, h: rect.h },
            text: lane.name.clone(),
            style: Style { size: font::MIN, weight: font::WEIGHT_BODY, face: Face::Mono, color: theme.text_secondary },
            align: Align::Left,
        });
        let track_x = rect.x + side::TIME_LANE_LABEL_WIDTH + side::ROW_ITEM_GAP;
        let track_w = layout::track_width(rect.w);
        let mid = rect.y + rect.h / 2.0;
        out.push(fill(
            Rect { x: track_x, y: mid - line::STROKE / 2.0, w: track_w, h: line::STROKE },
            over(panel, theme.line, 1.0),
        ));
        for piece in layout::segments(lane, band, track_w) {
            out.push(Item::Round {
                rect: Rect {
                    x: track_x + piece.x,
                    y: mid - side::TIME_SEGMENT_HEIGHT / 2.0,
                    w: piece.w,
                    h: side::TIME_SEGMENT_HEIGHT,
                },
                radius: side::TIME_SEGMENT_RADIUS,
                color: if piece.ongoing { theme.text } else { theme.text_secondary },
                edge: None,
            });
        }
    }
    out.push(Item::Text { rect: at.axis, text: band.start_label.clone(), style: body(theme.text_tertiary), align: Align::Left });
    out.push(Item::Text { rect: at.axis, text: tr(msg::NOW), style: body(theme.text_tertiary), align: Align::Right });

    out
}

fn waiting_row(out: &mut Vec<Item>, row: &Row, rect: Rect, view: &View, tr: &dyn Fn(&str) -> String) {
    let theme = view.theme;
    let selected = view.selection == Some(row.id.as_str());
    let (word_ink, minutes_ink) = ink(theme, row.shown, selected);
    let inner = Rect {
        x: rect.x + side::ROW_PADDING_X,
        y: rect.y + side::ROW_PADDING_Y,
        w: (rect.w - 2.0 * side::ROW_PADDING_X).max(0.0),
        h: (rect.h - 2.0 * side::ROW_PADDING_Y).max(0.0),
    };

    // First line: the name, and how long it has waited.
    let mut first = vec![words(
        row.id.clone(),
        Style {
            size: font::GROUP_NAME,
            weight: if selected { font::WEIGHT_STRONG } else { font::WEIGHT_GROUP_NAME },
            face: Face::Mono,
            color: theme.text,
        },
        Side::Rest,
        0.0,
    )];
    let line1 = Rect { x: inner.x, y: inner.y, w: inner.w, h: side::ROW_LINE1_HEIGHT };
    out.push(Item::Line { rect: line1, parts: std::mem::take(&mut first) });
    if let Some(minutes) = row.waited_min {
        // Two fixed columns at the right end, so the numbers of every row
        // end on one line whatever their width.
        let unit_x = line1.x + line1.w - side::MINUTES_UNIT_WIDTH;
        out.push(Item::Text {
            rect: Rect { x: unit_x - side::MINUTES_WIDTH, y: line1.y, w: side::MINUTES_WIDTH, h: line1.h },
            text: minutes.to_string(),
            style: Style { size: font::MINUTES, weight: font::WEIGHT_STRONG, face: Face::Ui, color: minutes_ink },
            align: Align::Right,
        });
        out.push(Item::Text {
            rect: Rect { x: unit_x, y: line1.y, w: side::MINUTES_UNIT_WIDTH, h: line1.h },
            text: tr(msg::MINUTES_UNIT),
            style: body(theme.text_secondary),
            align: Align::Right,
        });
    }

    // Second line: the glyph, which of the four it is, and what it waits on.
    let detail = match &row.detail {
        Detail::Reason(text) => text.clone(),
        Detail::SameAs(other) => list::fill(&tr(list::msg::SAME_SUPERVISOR), other),
    };
    let mut parts = vec![
        Part {
            piece: Piece::Glyph {
                shown: row.shown,
                color: glyph_color(theme, row.shown),
                size: side::GLYPH,
                pulses: view.pulsing == Some(row.id.as_str()),
            },
            side: Side::Lead,
            gap: 0.0,
        },
        words(row.word.clone(), Style { weight: font::WEIGHT_EMPHASIS, ..body(word_ink) }, Side::Lead, side::STATUS_WORD_GAP),
        words(
            detail,
            Style { face: if row.detail_is_code { Face::Mono } else { Face::Ui }, ..body(theme.text_secondary) },
            Side::Rest,
            side::ROW_ITEM_GAP,
        ),
    ];
    if let Some((template, n)) = list::others(row.others) {
        parts.push(words(list::fill(&tr(template), &n), body(theme.text_secondary), Side::Trail, side::ROW_ITEM_GAP));
    }
    out.push(Item::Line {
        rect: Rect { x: inner.x, y: inner.y + inner.h - side::ROW_LINE2_HEIGHT, w: inner.w, h: side::ROW_LINE2_HEIGHT },
        parts,
    });
}

/// What a row says when it is read out rather than looked at: the group,
/// which of the four it is, what it waits on, how long, and how many others
/// -- the same things the row draws, in the order it draws them, with the
/// glyph's meaning carried by the status word beside it.
pub fn spoken(row: &Row, tr: &dyn Fn(&str) -> String) -> String {
    let mut parts = vec![row.id.clone()];
    if !row.word.is_empty() {
        parts.push(row.word.clone());
    }
    let detail = match &row.detail {
        Detail::Reason(text) => text.clone(),
        Detail::SameAs(other) => list::fill(&tr(list::msg::SAME_SUPERVISOR), other),
    };
    if !detail.is_empty() {
        parts.push(detail);
    }
    if let Some(minutes) = row.waited_min {
        parts.push(list::fill(&tr(msg::BAND_TOTAL), &minutes.to_string()));
    }
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

/// Whether anything in a scene moves while nothing changes: a glyph that
/// breathes, or the spinner. A host keeps a clock running only while this
/// is so, and otherwise is not woken at all.
pub fn moves(items: &[Item]) -> bool {
    items.iter().any(|item| match item {
        Item::Line { parts, .. } => parts.iter().any(|p| match &p.piece {
            Piece::Glyph { shown, pulses, .. } => *pulses || *shown == Shown::Working,
            Piece::Words { .. } => false,
        }),
        Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } => false,
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

/// What the right side says about the selected group, until the
/// supervisor's own terminal is put there.
#[derive(Debug, Clone, PartialEq)]
pub struct Right {
    pub items: Vec<Item>,
    /// Where "go to its tab" is, when there is a tab to go to.
    pub go: Option<Rect>,
}

/// `selected` is the selected row, none for none. `width` and `height` are
/// the right side's own.
pub fn build_right(selected: Option<&Row>, width: f64, height: f64, theme: &Theme, scale: f64, tr: &dyn Fn(&str) -> String) -> Right {
    let frame = Rect { x: 0.0, y: 0.0, w: width, h: height };
    let ground = theme.terminal_background;
    let mut items = vec![Item::Round {
        rect: frame,
        radius: radius::SUPERVISOR_OUTER,
        color: ground,
        edge: Some(over(ground, theme.side_panel_edge, hairline(scale).1)),
    }];
    let pad = space::FRAME_TO_CONTENT;
    let line_h = side::HEADER_HEIGHT;
    let inner_w = (width - 2.0 * pad).max(0.0);
    let line_at = |n: f64| Rect { x: pad, y: pad + n * line_h, w: inner_w, h: line_h };
    let Some(row) = selected else {
        items.push(Item::Text { rect: line_at(0.0), text: tr(msg::NO_SELECTION), style: body(theme.text_secondary), align: Align::Left });
        return Right { items, go: None };
    };
    items.push(Item::Text {
        rect: line_at(0.0),
        text: row.id.clone(),
        style: Style { size: font::GROUP_NAME, weight: font::WEIGHT_STRONG, face: Face::Mono, color: theme.terminal_bold },
        align: Align::Left,
    });
    if row.steward.is_none() {
        items.push(Item::Text { rect: line_at(1.0), text: tr(msg::NO_SUPERVISOR), style: body(theme.terminal_dim), align: Align::Left });
        return Right { items, go: None };
    }
    items.push(Item::Text { rect: line_at(1.0), text: tr(msg::IN_ITS_OWN_TAB), style: body(theme.terminal_dim), align: Align::Left });
    // A button the width of the list's rows would be lost on a wide side;
    // it is as wide as a tab and sits on the content's left edge.
    let go = Rect { x: pad, y: pad + 2.0 * line_h + space::BETWEEN_FRAMES, w: side::WIDTH / 2.0, h: line_h };
    let button = over(ground, theme.text, selection::LIFT_IN);
    items.push(Item::Round { rect: go, radius: radius::ROW, color: button, edge: Some(over(button, theme.side_panel_edge, 1.0)) });
    items.push(Item::Text {
        rect: go,
        text: tr(msg::GO_TO_ITS_TAB),
        style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.terminal_text) },
        align: Align::Centre,
    });
    Right { items, go: Some(go) }
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
        let view = View { theme: look::theme(dark), scale, selection, chip: at.chip(selection), lift: 0.0, pulsing };
        build(list, &at, &view, &same)
    }

    fn styles(items: &[Item]) -> Vec<Style> {
        let mut out = Vec::new();
        for item in items {
            match item {
                Item::Text { style, .. } => out.push(*style),
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
            Item::Fill { rect, .. } | Item::Round { rect, .. } | Item::Text { rect, .. } | Item::Line { rect, .. } => *rect,
        }
    }

    fn texts(items: &[Item]) -> Vec<String> {
        let mut out = Vec::new();
        for item in items {
            match item {
                Item::Text { text, .. } => out.push(text.clone()),
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
            let right = build_right(l.row(&first), 600.0, 700.0, look::theme(dark), 1.0, &same);
            for s in styles(&right.items) {
                assert!(s.size >= font::MIN, "{s:?}");
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
                    Item::Text { .. } | Item::Line { .. } => {}
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

    #[test]
    fn the_words_of_every_row_and_header_start_on_one_line() {
        // The grid: the panel's padding plus the row's, which the headers
        // share. A row's words and a header's start at the same x.
        let l = list();
        let want = space::SIDE_PANEL_PADDING + side::ROW_PADDING_X;
        assert_eq!(side::ROW_PADDING_X, side::HEADER_PADDING_X);
        let mut lines = 0;
        for item in scene(&l, None, false, 1.0, None) {
            match &item {
                Item::Line { rect, .. } => {
                    assert_eq!(rect.x, want, "{item:?}");
                    assert_eq!(rect.x + rect.w, side::WIDTH - want, "{item:?}");
                    lines += 1;
                }
                Item::Text { rect, align: Align::Left, .. } => assert_eq!(rect.x, want, "{item:?}"),
                // The minutes stand one fixed column in from the right edge,
                // so that the unit after them ends on it.
                Item::Text { rect, align: Align::Right, style, .. } if style.size == font::MINUTES => {
                    assert_eq!(rect.x + rect.w, side::WIDTH - want - side::MINUTES_UNIT_WIDTH, "{item:?}")
                }
                Item::Text { rect, align: Align::Right, .. } => assert_eq!(rect.x + rect.w, side::WIDTH - want, "{item:?}"),
                Item::Text { .. } | Item::Fill { .. } | Item::Round { .. } => {}
            }
        }
        // Two lines for each waiting row and one for each quiet one.
        assert_eq!(lines, 2 * l.waiting.len() + l.quiet.len());
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
            let at = said.iter().position(|t| *t == row.id).unwrap_or_else(|| panic!("{} is not drawn", row.id));
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
        // The panel, then the chip, then everything else.
        assert!(matches!(items[0], Item::Round { radius, .. } if radius == radius::SIDE_PANEL));
        assert!(matches!(items[1], Item::Round { radius, .. } if radius == radius::ROW));
        let at = ListLayout::new(&l, 900.0);
        assert_eq!(rect_of(&items[1]), at.chip(Some(&first)).unwrap());
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
            assert!(said.starts_with(&row.id), "{said}");
            if !row.word.is_empty() {
                assert!(said.contains(&row.word), "{said} leaves out the status word {:?}", row.word);
            }
            if let Detail::Reason(text) = &row.detail {
                assert!(said.contains(text.as_str()), "{said}");
            }
            if let Some(minutes) = row.waited_min {
                assert!(said.contains(&format!("{minutes} min")), "{said}");
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

    #[test]
    fn the_right_side_offers_the_tab_only_when_the_group_has_a_supervisor() {
        let l = list();
        let theme = look::theme(false);
        let with = l.rows().find(|r| r.steward.is_some()).expect("the fixture has a group with a supervisor");
        let right = build_right(Some(with), 600.0, 700.0, theme, 1.0, &same);
        assert!(right.go.is_some());
        assert!(texts(&right.items).contains(&with.id));
        assert!(texts(&right.items).contains(&msg::IN_ITS_OWN_TAB.to_string()));

        let mut without = with.clone();
        without.steward = None;
        let right = build_right(Some(&without), 600.0, 700.0, theme, 1.0, &same);
        assert!(right.go.is_none());
        assert!(texts(&right.items).contains(&msg::NO_SUPERVISOR.to_string()));

        let right = build_right(None, 600.0, 700.0, theme, 1.0, &same);
        assert!(right.go.is_none());
        assert_eq!(texts(&right.items), vec![msg::NO_SELECTION.to_string()]);
    }

    #[test]
    fn a_list_that_could_not_be_read_is_a_sentence_and_not_an_empty_panel() {
        let items = build_message(side::WIDTH, 400.0, look::theme(false), 1.0, "why".into());
        assert_eq!(texts(&items), vec!["why".to_string()]);
    }
}
