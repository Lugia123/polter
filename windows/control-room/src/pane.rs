//! The frame a pane of a split terminal tab wears
//! (`dev-docs/poltergeist/control-room.md`, 12.6 and 12.6.1; the design's
//! `06-panes`).
//!
//! Three things, each without a window:
//!
//!  1. **Whether a pane wears a frame, and which** -- [`drawn`]. Which of
//!     the three is the core's answer and arrives as `pane` on each of the
//!     snapshot's `terminals`, with the title, the glyph and the word beside
//!     it. What is decided here is only whether one is drawn at all, which
//!     is about where the pane is. The same table as the macOS host's
//!     `PaneFrame.drawn`, held to the same answers by
//!     `tools/control-room-hosts-agree.py`.
//!  2. **Where the frame and the terminal in it go**, in device pixels --
//!     [`frame_px`] and [`well_px`]. A pane here is a child window, so the
//!     terminal has to be moved out of the way of its own title; the split
//!     tree is not told, and still tiles the whole content area.
//!  3. **What the frame draws** -- [`build`], as the items `scene` draws the
//!     control room from, for the same painter.
//!
//! **What a Windows frame does not have** that the design and the macOS
//! host do: the corners of the terminal itself are square (a child window
//! is a rectangle, and cutting one to a shape costs a region per resize),
//! so a worker's and an ordinary terminal's frame is round at the top and
//! square at the bottom; a supervisor's is round outside and square
//! inside. Nothing has a shadow: a scene has no item for one.

use crate::layout::Rect;
use crate::look::{font, pane, radius, side, space, supervisor_badge, window_tab, Rgba, Theme};
use crate::pane_color::Color as PaneColor;
use crate::scene::{self, Face, Item, Part, Piece, Side, Style};
use crate::snapshot::{BarShown, Shown, Terminal};

pub use crate::snapshot::Pane as Wears;

/// The English of the word after a pane's name that says what it is; a host
/// translates it. An ordinary terminal has none.
pub mod msg {
    use crate::n_;

    pub const WORKER: &str = n_("Worker");
}

/// The name, the glyph and the word.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Title {
    pub name: String,
    /// The glyph at the title's right end: a status, or held.
    pub shown: BarShown,
    pub word: String,
}

/// What one pane wears.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Drawn {
    pub wears: Wears,
    pub title: Title,
    /// The colour a person set on the terminal (task 1700): the *set* one,
    /// none being `None`. What it is drawn in is [`shown`](crate::pane_color::shown).
    pub color: Option<PaneColor>,
}

/// What a pane's title has at its left end (`pane-color-interface.md` §6):
/// the supervisor's flag badge, a coloured pane's dot badge, or nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BadgeKind {
    Flag,
    Dot,
    None,
}

impl BadgeKind {
    pub fn name(self) -> &'static str {
        match self {
            BadgeKind::Flag => "flag",
            BadgeKind::Dot => "dot",
            BadgeKind::None => "none",
        }
    }
}

/// Which badge a pane's title draws, and in which colour: the supervisor's
/// flag in its shown colour (purple when none is set), a dot in the colour
/// of any other pane that has one, and nothing where nothing is drawn.
pub fn badge(drawn: Option<&Drawn>) -> (BadgeKind, Option<PaneColor>) {
    let Some(d) = drawn else { return (BadgeKind::None, None) };
    match (d.wears, crate::pane_color::shown(d.color, d.wears)) {
        (Wears::Supervisor, c) => (BadgeKind::Flag, c),
        (_, Some(c)) => (BadgeKind::Dot, Some(c)),
        (_, None) => (BadgeKind::None, None),
    }
}

/// Where a pane is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Place {
    /// `poltergeist-pane-frames`.
    pub enabled: bool,
    /// It is in the quick terminal, which is never framed.
    pub quick_terminal: bool,
    /// It is the only pane showing in its tab: the tab is not split, or
    /// this pane is zoomed to fill it.
    pub alone: bool,
}

/// What the pane of `terminal` wears at `place`; none when it is drawn as
/// it was before there were frames.
///
/// - A terminal `terminals` (the snapshot's) does not list -- one the core
///   has not placed yet, or no snapshot at all -- is an ordinary one, under
///   the name its own pane has (`own_name`), with nothing to say.
/// - An ordinary terminal alone in its tab wears nothing: the window's tab
///   already says which it is. A supervisor or a worker wears its frame
///   even alone.
pub fn drawn(terminal: Option<&str>, own_name: &str, place: Place, terminals: Option<&[Terminal]>, color: Option<PaneColor>) -> Option<Drawn> {
    if !place.enabled || place.quick_terminal {
        return None;
    }
    let listed = terminal.and_then(|id| terminals?.iter().find(|t| t.id == id));
    let drawn = match listed {
        Some(t) => Drawn {
            wears: t.pane.unwrap_or(Wears::Plain),
            // The pair the core says the title draws. Only a snapshot from
            // before it said so falls back to the status.
            title: match &t.bar {
                Some(bar) => Title { name: t.title.clone(), shown: bar.shown, word: bar.text.clone() },
                None => Title { name: t.title.clone(), shown: BarShown::of(t.shown), word: t.text.clone() },
            },
            color,
        },
        None => Drawn { wears: Wears::Plain, title: Title { name: own_name.to_string(), shown: BarShown::None, word: String::new() }, color },
    };
    if drawn.wears == Wears::Plain && place.alone {
        return None;
    }
    Some(drawn)
}

/// The colour of the edge the pane of `terminal` at `place` is drawn with:
/// a line just inside it, all round, and nothing else (task 1692, the
/// design's `supervisor-pane-v1`, situation 2; any coloured pane since task
/// 1700). Only where it wears no frame because the setting is off -- with no
/// title there is nowhere for a badge to go -- and in the pane's shown
/// colour, so a supervisor with none set has the purple one; alone in its
/// tab too, as its frame would be. Never in the quick terminal. macOS's
/// `PaneFrame.edged`.
pub fn edged(terminal: Option<&str>, place: Place, terminals: Option<&[Terminal]>, color: Option<PaneColor>) -> Option<PaneColor> {
    if place.enabled || place.quick_terminal {
        return None;
    }
    let listed = terminal.and_then(|id| terminals?.iter().find(|t| t.id == id));
    let wears = listed.and_then(|t| t.pane).unwrap_or(Wears::Plain);
    crate::pane_color::shown(color, wears)
}

/// The ground of the supervisor's badge: the pane's own colour when it has
/// one, the supervisor's colour (the app icon's purple) when it has not.
/// **The one place it is chosen** (task 1692; `pane_color` is the colour
/// *set*, task 1700). macOS's `PaneFrame.badgeGround`.
pub fn badge_ground(pane_color: Option<PaneColor>, theme: &Theme) -> Rgba {
    pane_color.unwrap_or(PaneColor::Purple).badge(theme)
}

/// How thick the supervisor's edge is, in device pixels: never less than one.
pub fn edge_px(scale: f64) -> i32 {
    len_px(supervisor_badge::EDGE, scale).max(1)
}

/// Where the terminal's own window goes in a pane with the supervisor's
/// edge ([`edged`]): `cell` less the edge on every side.
pub fn edged_well_px(cell: Px, scale: f64) -> Px {
    let e = edge_px(scale);
    Px { x: cell.x + e, y: cell.y + e, w: (cell.w - 2 * e).max(1), h: (cell.h - 2 * e).max(1) }
}

/// Whether the tab's ground shows between and around its panes: it does as
/// soon as one pane of it wears a frame. With none framed the panes meet at
/// the divider, as they always did.
pub fn ground_shows(panes: &[Option<Drawn>]) -> bool {
    panes.iter().any(|p| p.is_some())
}

/// The word after the name that says what the pane is, in English; none
/// for an ordinary terminal, which says nothing.
pub fn role_word(wears: Wears) -> Option<&'static str> {
    match wears {
        Wears::Supervisor => Some(crate::lend::msg::SUPERVISOR),
        Wears::Worker => Some(msg::WORKER),
        Wears::Plain => None,
    }
}

// ---------------------------------------------------------------- pixels

/// A rectangle in device pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Px {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Px {
    pub fn right(&self) -> i32 {
        self.x + self.w
    }
    pub fn bottom(&self) -> i32 {
        self.y + self.h
    }
}

/// A length of the table's, in device pixels at `scale` to the point. The
/// same rounding the scene's painter does, so that what is placed and what
/// is painted meet.
pub fn len_px(points: f64, scale: f64) -> i32 {
    (points * scale).round() as i32
}

/// How thick a worker's line is: half a point, and never less than one
/// device pixel.
pub fn line_px(scale: f64) -> i32 {
    len_px(pane::WORKER_LINE, scale).max(1)
}

/// Where the frame of the pane in `cell` goes, when the tab's ground shows.
///
/// `cell` is the rectangle the split tree gave the pane and `bounds` the
/// area the tree tiles. The frame keeps half the gap between two frames
/// clear on every side that faces another pane, and the whole distance to
/// the window's edge on every side that is the edge of `bounds` -- so two
/// frames are `between_frames` apart and the outermost are `window_edge`
/// from the window, at every scale, and the tree is told nothing.
pub fn frame_px(cell: Px, bounds: Px, scale: f64) -> Px {
    let half = len_px(space::BETWEEN_FRAMES / 2.0, scale);
    let edge = len_px(space::WINDOW_EDGE, scale);
    let left = if cell.x <= bounds.x { edge } else { half };
    let top = if cell.y <= bounds.y { edge } else { half };
    let right = if cell.right() >= bounds.right() { edge } else { half };
    let bottom = if cell.bottom() >= bounds.bottom() { edge } else { half };
    Px { x: cell.x + left, y: cell.y + top, w: (cell.w - left - right).max(1), h: (cell.h - top - bottom).max(1) }
}

/// Where the terminal's own window goes inside a frame: under the title,
/// and inside whatever the frame draws round it.
pub fn well_px(frame: Px, wears: Wears, scale: f64) -> Px {
    let (side, top, bottom) = match wears {
        Wears::Supervisor => {
            let b = len_px(pane::SUPERVISOR_BORDER, scale);
            (b, len_px(pane::BAR_HEIGHT, scale), b)
        }
        Wears::Worker => {
            let l = line_px(scale);
            (l, len_px(pane::BAR_HEIGHT, scale), l)
        }
        Wears::Plain => (0, len_px(pane::PLAIN_TITLE_BAND_HEIGHT, scale), 0),
    };
    Px { x: frame.x + side, y: frame.y + top, w: (frame.w - 2 * side).max(1), h: (frame.h - top - bottom).max(1) }
}

// ----------------------------------------------------------------- scene

/// What `build` is told that the pane does not hold.
pub struct View<'a> {
    pub theme: &'a Theme,
    /// Device pixels to the point.
    pub scale: f64,
    /// The terminal in the frame has the keyboard.
    pub focused: bool,
    /// The ground of the terminal in it: what its title is written on when
    /// the frame is an ordinary terminal's, and what shows for the moment
    /// before the terminal's window is over its place.
    pub well: Rgba,
    /// The title keeps room at its right end for the close cross
    /// ([`close_shows`]); the host draws the cross there ([`close_px`]).
    pub close: bool,
}

// ----------------------------------------------------------------- close

/// Whether a pane's title shows its close cross (task 1583; the macOS
/// host's rule in task 1582). **Only in a tab that is split**: a pane alone
/// in its tab closes with the tab, whose own cross is on the strip. Then
/// while the pointer is over the title, and always on the pane with the
/// keyboard -- the strip's tabs show theirs the same way.
pub fn close_shows(alone: bool, focused: bool, hovered: bool) -> bool {
    !alone && (focused || hovered)
}

/// How far the title's words keep from the frame's left and right edges,
/// in points.
fn title_inset_x(wears: Wears) -> f64 {
    match wears {
        Wears::Supervisor => pane::SUPERVISOR_BORDER + pane::SUPERVISOR_BAR_PADDING_X,
        Wears::Worker => pane::BAR_PADDING_X,
        Wears::Plain => pane::PLAIN_TITLE_INSET_X,
    }
}

/// Where the close cross's box is, in the frame window's pixels: a square
/// the size of a window tab's, at the right end of the title, right of the
/// state, centred in the title's height. `frame` as [`frame_px`] gave it.
pub fn close_px(frame: Px, wears: Wears, scale: f64) -> Px {
    let side = len_px(window_tab::CLOSE, scale);
    let band = well_px(frame, wears, scale).y - frame.y;
    let right = frame.right() - len_px(title_inset_x(wears), scale);
    Px { x: right - side, y: frame.y + (band - side) / 2, w: side, h: side }
}

/// The colours a title is written in: the name's, and everything else's.
fn inks(wears: Wears, theme: &Theme) -> (Rgba, Rgba) {
    match wears {
        Wears::Supervisor => (theme.text, theme.text_secondary),
        Wears::Worker => (theme.terminal_bold, theme.terminal_dim),
        Wears::Plain => (theme.terminal_dim, theme.terminal_dim),
    }
}

/// The close cross's colour: the title's second ink, and the name's while
/// the pointer is on the cross -- except on an ordinary terminal, whose
/// name is in the second ink too, so the cross takes the terminal's bold
/// (task 1590: on a plain frame it did not light at all, #1585 P1). The
/// step is the other two frames' step, from dim to the brightest ink.
pub fn close_ink(wears: Wears, theme: &Theme, lit: bool) -> Rgba {
    let (name, second) = inks(wears, theme);
    match (lit, wears) {
        (false, _) => second,
        (true, Wears::Plain) => theme.terminal_bold,
        (true, _) => name,
    }
}

/// The frame of one pane, in points from the frame's own top left; `frame`
/// is its size in device pixels (`frame_px`). The terminal's window covers
/// `well_px` of it; everything else is this.
pub fn build(frame: Px, drawn: &Drawn, view: &View, tr: &dyn Fn(&str) -> String) -> Vec<Item> {
    let scale = view.scale.max(0.1);
    let theme = view.theme;
    let pt = |px: i32| px as f64 / scale;
    let (w, h) = (pt(frame.w), pt(frame.h));
    let whole = Rect { x: 0.0, y: 0.0, w, h };
    // The terminal's place, from the same arithmetic that places it.
    let at = well_px(Px { x: 0, y: 0, w: frame.w, h: frame.h }, drawn.wears, scale);
    let well = Rect { x: pt(at.x), y: pt(at.y), w: pt(at.w), h: pt(at.h) };

    let mut items = Vec::new();
    let (name_ink, second_ink) = inks(drawn.wears, theme);
    let (mut bar, name_weight, trouble_ink) = match drawn.wears {
        Wears::Supervisor => {
            // A thick border whose top edge is the title bar; the edge
            // darkens (lightens, in the dark) while the terminal in it has
            // the keyboard.
            let bezel = scene::over(theme.window_base, theme.supervisor_bezel, 1.0);
            let edge = if view.focused { theme.supervisor_edge_focused } else { theme.supervisor_edge };
            items.push(Item::Round { rect: whole, radius: radius::SUPERVISOR_OUTER, color: bezel, edge: Some(scene::over(bezel, edge, 1.0)) });
            let x = title_inset_x(Wears::Supervisor);
            (
                Rect { x, y: 0.0, w: (w - 2.0 * x).max(0.0), h: pane::BAR_HEIGHT },
                font::WEIGHT_EMPHASIS,
                theme.problem_text_on_supervisor_bar,
            )
        }
        Wears::Worker => {
            // The band is the frame's own colour, so the frame is drawn in
            // it and the terminal's ground laid over the rest.
            let edge = scene::over(theme.worker_band, theme.worker_edge, scene::hairline(scale).1);
            items.push(Item::Round { rect: whole, radius: radius::WORKER, color: theme.worker_band, edge: Some(edge) });
            let x = title_inset_x(Wears::Worker);
            (
                Rect { x, y: 0.0, w: (w - 2.0 * x).max(0.0), h: pane::BAR_HEIGHT },
                font::WEIGHT_EMPHASIS,
                theme.problem_text_on_worker_band,
            )
        }
        Wears::Plain => {
            // No line and no band: the terminal's ground, all of it.
            items.push(Item::Round { rect: whole, radius: radius::PLAIN, color: view.well, edge: None });
            let x = title_inset_x(Wears::Plain);
            (
                Rect { x, y: 0.0, w: (w - 2.0 * x).max(0.0), h: pane::PLAIN_TITLE_BAND_HEIGHT },
                font::WEIGHT_BODY,
                theme.problem_text_on_terminal,
            )
        }
    };
    // The terminal's ground, for the moment before its window is there.
    items.push(Item::Fill { rect: well, color: view.well });
    // The close cross's room, and a gap before it, come off the line's
    // right end: the state stays left of the cross (`close_px`).
    if view.close {
        bar.w = (bar.w - window_tab::CLOSE - pane::BAR_GAP).max(0.0);
    }

    // The name and what it is on the left; its state on the right. Words
    // that are not there are not put in the line at all.
    //
    // A supervisor says what it is with the badge at the left end, in place
    // of the word after the name (task 1692, the design's C), and its status
    // word is what goes before the badge would be cut (`Side::Yield`): the
    // name is cut first, then the word goes, and the badge stays.
    let ui = |color: Rgba, weight: f64| Style { size: font::BODY, weight, face: Face::Ui, color };
    // Since task 1700 any pane with a colour has a badge too: the
    // supervisor's flag and its word, or a coloured pane's dot and the word
    // that says what it is (an ordinary terminal's dot has none), on the
    // colour's own ground. Given too little room it is the mark alone.
    let (kind, color) = badge(Some(drawn));
    let badge = kind != BadgeKind::None;
    let mut parts = Vec::new();
    if let (true, Some(c)) = (badge, color) {
        let (mark, text) = match kind {
            BadgeKind::Flag => (crate::glyph::Mark::Supervisor, tr(crate::lend::msg::SUPERVISOR)),
            BadgeKind::Dot | BadgeKind::None => (crate::glyph::Mark::Dot, role_word(drawn.wears).map(tr).unwrap_or_default()),
        };
        parts.push(Part {
            piece: Piece::Badge { mark, text, style: ui(c.badge_text(theme), font::WEIGHT_EMPHASIS), ground: badge_ground(Some(c), theme) },
            side: Side::Lead,
            gap: 0.0,
        });
    }
    if scene::draws(&drawn.title.name) {
        parts.push(Part {
            piece: Piece::Words {
                text: drawn.title.name.clone(),
                style: Style { size: font::BODY, weight: name_weight, face: Face::Mono, color: name_ink },
            },
            side: Side::Lead,
            gap: if badge { pane::BAR_GAP } else { 0.0 },
        });
    }
    if let Some(role) = role_word(drawn.wears).filter(|_| !badge) {
        parts.push(Part {
            piece: Piece::Words { text: tr(role), style: ui(second_ink, font::WEIGHT_BODY) },
            side: Side::Lead,
            gap: pane::NAME_ROLE_GAP,
        });
    }
    let shown = drawn.title.shown;
    match shown.status() {
        Some(Shown::None) => {}
        Some(status) => parts.push(Part {
            piece: Piece::Glyph { shown: status, color: scene::glyph_color(theme, status), size: side::GLYPH, pulses: false },
            side: Side::Trail,
            gap: pane::BAR_GAP,
        }),
        // Held is not a status and has no colour of its own: the design
        // draws it in the title's second ink.
        None => parts.push(Part { piece: Piece::Held { color: second_ink, size: side::GLYPH }, side: Side::Trail, gap: pane::BAR_GAP }),
    }
    if scene::draws(&drawn.title.word) {
        let ink = match shown {
            BarShown::NeedsYou | BarShown::DoneUnseen => theme.attention_text,
            // Where the word is not red is the table's to say.
            BarShown::Trouble => trouble_ink,
            BarShown::Working | BarShown::None | BarShown::Held => second_ink,
        };
        parts.push(Part {
            piece: Piece::Words { text: drawn.title.word.clone(), style: ui(ink, font::WEIGHT_EMPHASIS) },
            side: if badge { Side::Yield } else { Side::Trail },
            gap: side::STATUS_WORD_GAP,
        });
    }
    if !parts.is_empty() {
        items.push(Item::Line { rect: bar, parts });
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look;
    use crate::snapshot;

    const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/poltergeist/testdata/control_snapshot.json"));

    fn terminals() -> Vec<Terminal> {
        snapshot::decode(FIXTURE).unwrap().terminals
    }

    const SPLIT: Place = Place { enabled: true, quick_terminal: false, alone: false };
    const ALONE: Place = Place { enabled: true, quick_terminal: false, alone: true };

    const SUPERVISOR: &str = "0x00000000000000a1";
    const WORKER: &str = "0x00000000000000b1";
    const WAITING_SHELL: &str = "0x00000000000000c1";
    const SHELL: &str = "0x00000000000000c2";

    fn title(name: &str, shown: Shown, word: &str) -> Title {
        Title { name: name.to_string(), shown: BarShown::of(shown), word: word.to_string() }
    }

    fn wears(id: &str, place: Place) -> Option<Wears> {
        drawn(Some(id), "", place, Some(&terminals()), None).map(|d| d.wears)
    }

    // ---- which of the three (the same cases as PaneFrameTests.swift)

    #[test]
    fn the_fixture_says_which_frame_every_terminal_wears() {
        use Wears::*;
        let all: Vec<Option<Wears>> = terminals().iter().map(|t| t.pane).collect();
        let want = [Supervisor, Supervisor, Supervisor, Supervisor, Supervisor, Supervisor, Supervisor, Worker, Worker, Worker, Plain, Plain];
        assert_eq!(all, want.map(Some));
    }

    #[test]
    fn a_pane_wears_the_frame_the_core_names_for_its_terminal() {
        assert_eq!(wears(SUPERVISOR, SPLIT), Some(Wears::Supervisor));
        assert_eq!(wears(WORKER, SPLIT), Some(Wears::Worker));
        assert_eq!(wears(SHELL, SPLIT), Some(Wears::Plain));
    }

    #[test]
    fn the_title_is_the_terminals_own_name_glyph_and_word() {
        let all = terminals();
        let b = drawn(Some(WORKER), "not this", SPLIT, Some(&all), None).unwrap();
        assert_eq!(b.title, title("web-app worker", Shown::NeedsYou, "Awaiting approval"));
        // Not the first one listed, and not another terminal's.
        let c = drawn(Some(SHELL), "not this", SPLIT, Some(&all), None).unwrap();
        assert_eq!(c.title, title("zsh", Shown::None, ""));
    }

    #[test]
    fn an_ordinary_terminal_that_waits_says_so() {
        let c = drawn(Some(WAITING_SHELL), "", SPLIT, Some(&terminals()), None);
        assert_eq!(c, Some(Drawn { wears: Wears::Plain, title: title("zsh — ~/work", Shown::NeedsYou, "Awaiting approval"), color: None }));
    }

    // ---- alone in its tab

    #[test]
    fn an_ordinary_terminal_alone_in_its_tab_wears_nothing() {
        assert_eq!(drawn(Some(SHELL), "zsh", ALONE, Some(&terminals()), None), None);
    }

    #[test]
    fn a_supervisor_wears_its_frame_even_alone() {
        assert_eq!(wears(SUPERVISOR, ALONE), Some(Wears::Supervisor));
    }

    #[test]
    fn a_worker_wears_its_frame_even_alone() {
        assert_eq!(wears(WORKER, ALONE), Some(Wears::Worker));
    }

    // ---- off, and the quick terminal

    #[test]
    fn with_the_setting_off_nothing_is_framed() {
        for alone in [false, true] {
            let place = Place { enabled: false, quick_terminal: false, alone };
            for id in [SUPERVISOR, WORKER, SHELL] {
                assert_eq!(drawn(Some(id), "zsh", place, Some(&terminals()), None), None, "{id} alone={alone}");
            }
        }
    }

    /// With no frames, a supervisor's pane still says it is one: an edge
    /// just inside it, alone in its tab or not; no other pane has one, nor
    /// any pane with frames on, nor the quick terminal (task 1692).
    #[test]
    fn with_the_setting_off_only_the_supervisors_pane_has_the_edge() {
        let all = terminals();
        for alone in [false, true] {
            let place = Place { enabled: false, quick_terminal: false, alone };
            for t in &all {
                assert_eq!(edged(Some(&t.id), place, Some(&all), None).is_some(), t.pane == Some(Wears::Supervisor), "{} alone={alone}", t.id);
            }
            assert!(edged(None, place, Some(&all), None).is_none());
            assert!(edged(Some("0xee"), place, Some(&all), None).is_none());
            assert!(edged(Some(SUPERVISOR), place, None, None).is_none());
            assert!(edged(Some(SUPERVISOR), Place { enabled: true, ..place }, Some(&all), None).is_none());
            assert!(edged(Some(SUPERVISOR), Place { quick_terminal: true, ..place }, Some(&all), None).is_none());
        }
        // The terminal's window is the edge in from its cell on every side,
        // and never less than a pixel in.
        let cell = Px { x: 10, y: 20, w: 300, h: 200 };
        for (scale, e) in [(1.0, 2), (1.5, 3), (2.0, 4), (0.25, 1)] {
            assert_eq!(edged_well_px(cell, scale), Px { x: 10 + e, y: 20 + e, w: 300 - 2 * e, h: 200 - 2 * e }, "{scale}");
        }
    }

    #[test]
    fn the_quick_terminal_is_never_framed() {
        let place = Place { enabled: true, quick_terminal: true, alone: false };
        for id in [SUPERVISOR, WORKER, SHELL] {
            assert_eq!(drawn(Some(id), "zsh", place, Some(&terminals()), None), None, "{id}");
        }
    }

    // ---- a terminal the snapshot does not list

    #[test]
    fn a_terminal_the_core_has_not_listed_is_an_ordinary_one_under_its_own_name() {
        let all = terminals();
        let plain = Some(Drawn { wears: Wears::Plain, title: title("fish", Shown::None, ""), color: None });
        assert_eq!(drawn(Some("0x00000000000000ff"), "fish", SPLIT, Some(&all), None), plain);
        assert_eq!(drawn(None, "fish", SPLIT, Some(&all), None), plain);
        assert_eq!(drawn(Some(SUPERVISOR), "fish", SPLIT, None, None), plain);
        // And alone, that is nothing.
        assert_eq!(drawn(None, "fish", ALONE, Some(&all), None), None);
    }

    #[test]
    fn a_snapshot_from_before_the_core_said_which_frame_draws_an_ordinary_one() {
        let old = FIXTURE.replace("\"pane\": \"supervisor\",", "").replace("\"pane\": \"worker\",", "").replace("\"pane\": \"plain\",", "");
        let all = snapshot::decode(&old).unwrap().terminals;
        assert!(all.iter().all(|t| t.pane.is_none()));
        let d = drawn(Some(SUPERVISOR), "", SPLIT, Some(&all), None);
        assert_eq!(d, Some(Drawn { wears: Wears::Plain, title: title("web-app", Shown::NeedsYou, "Awaiting approval"), color: None }));
    }

    #[test]
    fn a_snapshot_that_lists_no_terminals_at_all_still_reads() {
        let v = crate::json::parse(FIXTURE).unwrap();
        assert!(v.get("terminals").is_some());
        // Cut the list out by name: what an older core wrote.
        let at = FIXTURE.find("\"terminals\"").unwrap();
        let end = FIXTURE[at..].find("\n  ],").unwrap() + at + "\n  ],".len();
        let without = format!("{}{}", &FIXTURE[..at], &FIXTURE[end..]);
        let read = snapshot::decode(&without).unwrap();
        assert!(read.terminals.is_empty());
        assert_eq!(read.groups.len(), 8);
    }

    #[test]
    fn a_frame_the_host_does_not_know_is_an_error_not_an_ordinary_terminal() {
        let odd = FIXTURE.replacen("\"pane\": \"worker\"", "\"pane\": \"stacked\"", 1);
        assert!(matches!(snapshot::decode(&odd), Err(snapshot::DecodeError::UnknownValue(_))));
    }

    // ---- the ground

    #[test]
    fn the_ground_shows_as_soon_as_one_pane_is_framed() {
        let framed = Some(Drawn { wears: Wears::Worker, title: title("w", Shown::None, ""), color: None });
        assert!(ground_shows(&[None, framed.clone()]));
        assert!(ground_shows(&[framed]));
        assert!(!ground_shows(&[None]));
        assert!(!ground_shows(&[None, None]));
        assert!(!ground_shows(&[]));
    }

    #[test]
    fn an_ordinary_terminal_has_no_word_for_what_it_is() {
        assert_eq!(role_word(Wears::Plain), None);
        assert!(role_word(Wears::Supervisor).is_some());
        assert!(role_word(Wears::Worker).is_some());
        assert_ne!(role_word(Wears::Supervisor), role_word(Wears::Worker));
    }

    // ---- pixels

    const SCALES: [f64; 5] = [1.0, 1.25, 1.5, 1.75, 2.0];

    /// The design's `06` layout as the split tree would tile a content area
    /// `w` by `h` at `x, y`: a column on the left, and on the right one
    /// pane over two side by side.
    fn cells(b: Px) -> [Px; 4] {
        let (lw, th) = (b.w / 2, b.h * 5 / 9);
        let rw = b.w - lw;
        [
            Px { x: b.x, y: b.y, w: lw, h: b.h },
            Px { x: b.x + lw, y: b.y, w: rw, h: th },
            Px { x: b.x + lw, y: b.y + th, w: rw / 2, h: b.h - th },
            Px { x: b.x + lw + rw / 2, y: b.y + th, w: rw - rw / 2, h: b.h - th },
        ]
    }

    #[test]
    fn two_frames_are_the_tables_gap_apart_and_the_outermost_its_edge_from_the_window_at_every_scale() {
        for scale in SCALES {
            let b = Px { x: 0, y: len_px(36.0, scale), w: len_px(1440.0, scale) + 1, h: len_px(840.0, scale) + 3 };
            let [left, top, low_left, low_right] = cells(b).map(|c| frame_px(c, b, scale));
            let gap = len_px(space::BETWEEN_FRAMES, scale);
            let edge = len_px(space::WINDOW_EDGE, scale);
            // Whole pixels, and the same number everywhere.
            assert_eq!(gap, 2 * len_px(space::BETWEEN_FRAMES / 2.0, scale), "at {scale}");
            assert_eq!(top.x - left.right(), gap, "at {scale}");
            assert_eq!(low_left.x - left.right(), gap, "at {scale}");
            assert_eq!(low_right.x - low_left.right(), gap, "at {scale}");
            assert_eq!(low_left.y - top.bottom(), gap, "at {scale}");
            assert_eq!(low_right.y - top.bottom(), gap, "at {scale}");
            assert_eq!(left.x - b.x, edge, "at {scale}");
            assert_eq!(left.y - b.y, edge, "at {scale}");
            assert_eq!(b.bottom() - left.bottom(), edge, "at {scale}");
            assert_eq!(b.right() - top.right(), edge, "at {scale}");
            assert_eq!(top.y - b.y, edge, "at {scale}");
            assert_eq!(b.right() - low_right.right(), edge, "at {scale}");
            assert_eq!(b.bottom() - low_right.bottom(), edge, "at {scale}");
            assert_eq!(b.bottom() - low_left.bottom(), edge, "at {scale}");
        }
    }

    #[test]
    fn a_pane_alone_keeps_the_edge_on_all_four_sides() {
        for scale in SCALES {
            let b = Px { x: 0, y: 40, w: 1001, h: 701 };
            let f = frame_px(b, b, scale);
            let edge = len_px(space::WINDOW_EDGE, scale);
            assert_eq!((f.x - b.x, f.y - b.y, b.right() - f.right(), b.bottom() - f.bottom()), (edge, edge, edge, edge), "at {scale}");
        }
    }

    #[test]
    fn the_terminal_sits_under_the_title_and_inside_what_its_frame_draws() {
        for scale in SCALES {
            let f = Px { x: 13, y: 57, w: 701, h: 523 };
            let bar = len_px(pane::BAR_HEIGHT, scale);
            let b = len_px(pane::SUPERVISOR_BORDER, scale);
            let s = well_px(f, Wears::Supervisor, scale);
            assert_eq!((s.x - f.x, s.y - f.y, f.right() - s.right(), f.bottom() - s.bottom()), (b, bar, b, b), "supervisor at {scale}");
            let l = line_px(scale);
            assert!(l >= 1);
            let k = well_px(f, Wears::Worker, scale);
            assert_eq!((k.x - f.x, k.y - f.y, f.right() - k.right(), f.bottom() - k.bottom()), (l, bar, l, l), "worker at {scale}");
            let band = len_px(pane::PLAIN_TITLE_BAND_HEIGHT, scale);
            let p = well_px(f, Wears::Plain, scale);
            assert_eq!((p.x - f.x, p.y - f.y, f.right() - p.right(), f.bottom() - p.bottom()), (0, band, 0, 0), "plain at {scale}");
        }
        // The title is 32 points whatever is in it: 32, 40, 48 pixels.
        assert_eq!([1.0, 1.25, 1.5].map(|s| len_px(pane::BAR_HEIGHT, s)), [32, 40, 48]);
        assert_eq!([1.0, 1.25, 1.5].map(|s| len_px(pane::SUPERVISOR_BORDER, s)), [4, 5, 6]);
        assert_eq!([1.0, 1.25, 1.5, 2.0].map(line_px), [1, 1, 1, 1]);
    }

    #[test]
    fn a_cell_too_small_for_its_frame_still_gets_a_window_with_a_size() {
        for w in Wears::ALL {
            let f = frame_px(Px { x: 0, y: 0, w: 3, h: 3 }, Px { x: 0, y: 0, w: 100, h: 100 }, 1.5);
            let t = well_px(f, w, 1.5);
            assert!(f.w >= 1 && f.h >= 1 && t.w >= 1 && t.h >= 1, "{w:?}");
        }
    }

    // ---- what a frame draws

    fn same(s: &str) -> String {
        s.to_string()
    }

    fn view(dark: bool, scale: f64, focused: bool) -> View<'static> {
        View { theme: look::theme(dark), scale, focused, well: Rgba { r: 1, g: 2, b: 3, a: 1.0 }, close: false }
    }

    fn a(wears: Wears, name: &str, shown: Shown, word: &str) -> Drawn {
        Drawn { wears, title: title(name, shown, word), color: None }
    }

    fn words(items: &[Item]) -> Vec<String> {
        scene::all_text(items).into_iter().map(str::to_string).collect()
    }

    fn fills(items: &[Item]) -> Vec<(Rect, Rgba)> {
        items
            .iter()
            .filter_map(|i| match i {
                Item::Fill { rect, color } => Some((*rect, *color)),
                Item::Round { .. } | Item::Text { .. } | Item::Line { .. } | Item::Block { .. } | Item::Clip { .. } => None,
            })
            .collect()
    }

    fn first_round(items: &[Item]) -> (Rect, f64, Rgba, Option<Rgba>) {
        match &items[0] {
            Item::Round { rect, radius, color, edge } => (*rect, *radius, *color, *edge),
            other => panic!("a frame starts with its shape, not {other:?}"),
        }
    }

    // ---- the close cross (task 1583)

    /// Never alone in its tab; otherwise under the pointer or with the
    /// keyboard, as a window tab's.
    #[test]
    fn the_close_cross_shows_on_a_split_tabs_pane_under_the_pointer_or_with_the_keyboard() {
        assert!(!close_shows(false, false, false));
        assert!(close_shows(false, true, false));
        assert!(close_shows(false, false, true));
        assert!(close_shows(false, true, true));
        for (focused, hovered) in [(false, false), (true, false), (false, true), (true, true)] {
            assert!(!close_shows(true, focused, hovered), "alone, focused={focused} hovered={hovered}");
        }
    }

    /// The cross sits in the title, at its right end, inside the frame, and
    /// clear of the line the state is written in when room is kept for it.
    #[test]
    fn the_close_cross_is_at_the_titles_right_end_and_the_state_keeps_clear_of_it() {
        let longest = |items: &[Item]| {
            items
                .iter()
                .find_map(|i| match i {
                    Item::Line { rect, .. } => Some(*rect),
                    _ => None,
                })
                .expect("a title line")
        };
        for scale in SCALES {
            for wears in Wears::ALL {
                let f = Px { x: 40, y: 90, w: 703, h: 511 };
                let c = close_px(f, wears, scale);
                let well = well_px(f, wears, scale);
                // In the title band, and inside the frame.
                assert!(c.y >= f.y && c.bottom() <= well.y, "{wears:?} at {scale}: {c:?} title to {}", well.y);
                assert!(c.x > f.x && c.right() <= f.right(), "{wears:?} at {scale}: {c:?}");
                // At the right end: what is left of the frame past it is the
                // title's own inset.
                assert_eq!(f.right() - c.right(), len_px(title_inset_x(wears), scale), "{wears:?} at {scale}");
                // Centred up and down, to a pixel.
                assert!(((c.y - f.y) - (well.y - c.bottom())).abs() <= 1, "{wears:?} at {scale}: {c:?}");

                let d = a(wears, "a-name", Shown::NeedsYou, "等批准");
                let mut v = view(false, scale, false);
                let open = longest(&build(f, &d, &v, &same));
                v.close = true;
                let kept = longest(&build(f, &d, &v, &same));
                // The line ends left of the cross, with a gap.
                let end = f.x + ((kept.x + kept.w) * scale).round() as i32;
                assert!(end + len_px(pane::BAR_GAP, scale) - 1 <= c.x, "{wears:?} at {scale}: line ends {end}, cross at {}", c.x);
                // And without the cross it would have run over it.
                let open_end = f.x + ((open.x + open.w) * scale).round() as i32;
                assert!(open_end > c.x, "{wears:?} at {scale}");
            }
        }
    }

    /// Lit, the cross is in the name's ink; at rest in the second ink.
    #[test]
    fn the_close_cross_lights_in_the_names_ink() {
        for dark in [false, true] {
            let theme = look::theme(dark);
            assert_eq!(close_ink(Wears::Supervisor, theme, true), theme.text);
            assert_eq!(close_ink(Wears::Supervisor, theme, false), theme.text_secondary);
            assert_eq!(close_ink(Wears::Worker, theme, true), theme.terminal_bold);
            assert_eq!(close_ink(Wears::Worker, theme, false), theme.terminal_dim);
            assert_eq!(close_ink(Wears::Plain, theme, true), theme.terminal_bold);
            assert_eq!(close_ink(Wears::Plain, theme, false), theme.terminal_dim);
        }
    }

    /// Task 1590: under the pointer the cross is another colour than at
    /// rest, on every frame and in both themes -- a plain frame's did not
    /// change at all (#1585 P1).
    #[test]
    fn the_close_cross_changes_colour_under_the_pointer_on_every_frame() {
        for dark in [false, true] {
            let theme = look::theme(dark);
            for wears in [Wears::Supervisor, Wears::Worker, Wears::Plain] {
                assert_ne!(close_ink(wears, theme, true), close_ink(wears, theme, false), "{wears:?} dark={dark}");
            }
        }
    }

    #[test]
    fn a_title_says_the_name_what_it_is_and_its_state_and_an_ordinary_one_not_what_it_is() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        let v = view(false, 1.0, false);
        assert_eq!(words(&build(f, &a(Wears::Supervisor, "web-app", Shown::NeedsYou, "等批准"), &v, &same)), ["Supervisor", "web-app", "等批准"]);
        assert_eq!(words(&build(f, &a(Wears::Worker, "api", Shown::Trouble, "出错"), &v, &same)), ["api", "Worker", "出错"]);
        assert_eq!(words(&build(f, &a(Wears::Plain, "zsh", Shown::None, ""), &v, &same)), ["zsh"]);
        // The word for what it is goes through the host's translation.
        let zh = |s: &str| if s == "Worker" { "worker".to_string() } else { s.to_string() };
        assert_eq!(words(&build(f, &a(Wears::Worker, "api", Shown::None, ""), &v, &zh)), ["api", "worker"]);
    }

    /// The design's C (task 1692): a supervisor's title leads with the
    /// badge -- the flag and its word on the icon's colour -- with no word
    /// after the name, and its status word is what yields before the badge
    /// would be cut. Nothing else changes on any other frame.
    #[test]
    fn a_supervisors_title_leads_with_the_badge_and_its_status_word_yields() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        for dark in [false, true] {
            let theme = look::theme(dark);
            let v = view(dark, 1.0, false);
            let line = |wears: Wears| -> Vec<Part> {
                build(f, &a(wears, "web-app", Shown::Working, "在干活"), &v, &same)
                    .into_iter()
                    .find_map(|i| match i {
                        Item::Line { parts, .. } => Some(parts),
                        _ => None,
                    })
                    .unwrap()
            };
            let sv = line(Wears::Supervisor);
            assert_eq!(
                sv[0],
                Part {
                    piece: Piece::Badge {
                        mark: crate::glyph::Mark::Supervisor,
                        text: "Supervisor".into(),
                        style: Style { size: font::BODY, weight: font::WEIGHT_EMPHASIS, face: Face::Ui, color: theme.pane_purple_badge_text },
                        ground: theme.pane_purple_badge,
                    },
                    side: Side::Lead,
                    gap: 0.0,
                }
            );
            assert!(matches!(&sv[1].piece, Piece::Words { text, .. } if text == "web-app") && sv[1].gap == pane::BAR_GAP);
            assert_eq!(sv.iter().map(|p| p.side).collect::<Vec<_>>(), [Side::Lead, Side::Lead, Side::Trail, Side::Yield]);
            for wears in [Wears::Worker, Wears::Plain] {
                let other = line(wears);
                assert!(!other.iter().any(|p| matches!(p.piece, Piece::Badge { .. })), "{wears:?}");
                assert!(!other.iter().any(|p| p.side == Side::Yield), "{wears:?}");
                assert_eq!(other[0].gap, 0.0);
            }
        }
    }

    #[test]
    fn nothing_empty_is_ever_handed_to_a_host_to_draw() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        for wears in Wears::ALL {
            for (name, shown, word) in [("", Shown::None, ""), ("x", Shown::Working, ""), ("", Shown::NeedsYou, "等批准")] {
                let items = build(f, &a(wears, name, shown, word), &view(true, 1.25, false), &same);
                assert!(scene::all_text(&items).iter().all(|t| scene::draws(t)), "{wears:?} {name:?} {word:?}");
            }
        }
        // An ordinary terminal with no name and no state has no title line.
        let bare = build(f, &a(Wears::Plain, "", Shown::None, ""), &view(false, 1.0, false), &same);
        assert!(bare.iter().all(|i| !matches!(i, Item::Line { .. })));
    }

    #[test]
    fn the_ground_laid_for_the_terminal_is_exactly_where_the_terminal_is_put() {
        for scale in SCALES {
            for wears in Wears::ALL {
                let f = Px { x: 40, y: 90, w: 703, h: 511 };
                let items = build(f, &a(wears, "n", Shown::None, ""), &view(false, scale, false), &same);
                let (rect, color) = fills(&items)[0];
                assert_eq!(color, view(false, scale, false).well);
                // As the painter turns points into pixels, from the frame's corner.
                let px = |v: f64| (v * scale).round() as i32;
                let painted = Px { x: f.x + px(rect.x), y: f.y + px(rect.y), w: px(rect.x + rect.w) - px(rect.x), h: px(rect.y + rect.h) - px(rect.y) };
                assert_eq!(painted, well_px(f, wears, scale), "{wears:?} at {scale}");
            }
        }
    }

    #[test]
    fn each_frame_has_its_own_shape_and_the_supervisors_edge_changes_with_the_keyboard() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        let d = |w| a(w, "n", Shown::None, "");
        for dark in [false, true] {
            let theme = look::theme(dark);
            let v = view(dark, 1.0, false);
            let (rect, r, color, edge) = first_round(&build(f, &d(Wears::Supervisor), &v, &same));
            assert_eq!((rect.w, rect.h, r), (700.0, 500.0, radius::SUPERVISOR_OUTER));
            assert_eq!(color, scene::over(theme.window_base, theme.supervisor_bezel, 1.0));
            let (_, _, _, focused) = first_round(&build(f, &d(Wears::Supervisor), &view(dark, 1.0, true), &same));
            assert_ne!(edge, focused, "dark={dark}");
            assert_eq!(focused, Some(scene::over(color, theme.supervisor_edge_focused, 1.0)));

            let (_, r, color, edge) = first_round(&build(f, &d(Wears::Worker), &v, &same));
            assert_eq!((r, color), (radius::WORKER, theme.worker_band));
            assert!(edge.is_some());
            // A worker's does not change with the keyboard.
            assert_eq!(build(f, &d(Wears::Worker), &v, &same), build(f, &d(Wears::Worker), &view(dark, 1.0, true), &same));

            // An ordinary terminal's is its own ground, with no line.
            let (_, r, color, edge) = first_round(&build(f, &d(Wears::Plain), &v, &same));
            assert_eq!((r, color, edge), (radius::PLAIN, v.well, None));
        }
    }

    #[test]
    fn a_red_word_is_red_only_where_the_table_says() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        let ink = |wears: Wears, dark: bool| -> Rgba {
            let items = build(f, &a(wears, "n", Shown::Trouble, "出错"), &view(dark, 1.0, false), &same);
            items
                .iter()
                .find_map(|i| match i {
                    Item::Line { parts, .. } => parts.iter().find_map(|p| match &p.piece {
                        Piece::Words { text, style } if text == "出错" => Some(style.color),
                        Piece::Words { .. } | Piece::Glyph { .. } | Piece::Held { .. } | Piece::Mark { .. } | Piece::Badge { .. } => None,
                    }),
                    Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => None,
                })
                .unwrap()
        };
        for dark in [false, true] {
            let t = look::theme(dark);
            assert_eq!(ink(Wears::Supervisor, dark), t.problem_text_on_supervisor_bar);
            assert_eq!(ink(Wears::Worker, dark), t.problem_text_on_worker_band);
            assert_eq!(ink(Wears::Plain, dark), t.problem_text_on_terminal);
        }
        // Which is not one colour three times, in the dark.
        assert_ne!(ink(Wears::Worker, true), ink(Wears::Plain, true));
    }

    #[test]
    fn nothing_in_a_frame_moves_so_no_clock_runs_for_it() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        for wears in Wears::ALL {
            let items = build(f, &a(wears, "n", Shown::NeedsYou, "等批准"), &view(false, 1.0, false), &same);
            let pulses = items.iter().any(|i| match i {
                Item::Line { parts, .. } => parts.iter().any(|p| matches!(&p.piece, Piece::Glyph { pulses: true, .. })),
                Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => false,
            });
            assert!(!pulses, "{wears:?}");
        }
    }

    #[test]
    fn nothing_is_set_below_the_smallest_size() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        for wears in Wears::ALL {
            let items = build(f, &a(wears, "n", Shown::Trouble, "出错"), &view(false, 1.0, false), &same);
            for item in &items {
                if let Item::Line { parts, .. } = item {
                    for p in parts {
                        if let Piece::Words { style, .. } | Piece::Badge { style, .. } = &p.piece {
                            assert!(style.size >= font::MIN);
                        }
                    }
                }
            }
        }
    }

    // ---- the right end of the title: the core's pair (task 1468)

    use crate::snapshot::Bar;

    fn listed(shown: Shown, text: &str, bar: Option<(BarShown, &str)>) -> Vec<Terminal> {
        vec![Terminal {
            id: "0x01".to_string(),
            title: "t".to_string(),
            shown,
            text: text.to_string(),
            pane: Some(Wears::Worker),
            bar: bar.map(|(shown, text)| Bar { shown, text: text.to_string() }),
            who: None,
        }]
    }

    #[test]
    fn the_titles_glyph_and_word_are_the_pair_the_core_gives_for_every_terminal() {
        let all = terminals();
        for t in &all {
            let bar = t.bar.clone().unwrap_or_else(|| panic!("{} has no bar", t.id));
            let d = drawn(Some(&t.id), "", SPLIT, Some(&all), None).unwrap();
            assert_eq!(d.title, Title { name: t.title.clone(), shown: bar.shown, word: bar.text }, "{}", t.id);
        }
    }

    #[test]
    fn a_held_worker_of_the_fixture_says_held_and_its_status_is_untouched() {
        let all = terminals();
        let held = all.iter().find(|t| t.title == "tokens").unwrap();
        assert_eq!(held.bar, Some(Bar { shown: BarShown::Held, text: "Held".to_string() }));
        // What a row or a window tab would draw of it is still its status.
        assert_eq!((held.shown, held.text.as_str()), (Shown::None, "Off duty"));
        let d = drawn(Some(&held.id), "", SPLIT, Some(&all), None);
        assert_eq!(d, Some(Drawn { wears: Wears::Worker, title: Title { name: "tokens".to_string(), shown: BarShown::Held, word: "Held".to_string() }, color: None }));
        let held_ones: Vec<&str> = all.iter().filter(|t| t.bar.as_ref().is_some_and(|b| b.shown == BarShown::Held)).map(|t| t.title.as_str()).collect();
        assert_eq!(held_ones, ["tokens"]);
    }

    #[test]
    fn the_host_takes_the_pair_as_given_and_works_nothing_out() {
        // Whatever the status says: the title is the pair. Which wins when a
        // terminal is held and also waiting is the core's rule, not this.
        for status in [Shown::NeedsYou, Shown::Trouble, Shown::DoneUnseen, Shown::Working, Shown::None] {
            for bar in BarShown::ALL {
                let all = listed(status, "status", Some((bar, "pair")));
                let d = drawn(Some("0x01"), "", SPLIT, Some(&all), None).unwrap();
                assert_eq!(d.title, Title { name: "t".to_string(), shown: bar, word: "pair".to_string() }, "{status:?} {bar:?}");
            }
        }
    }

    #[test]
    fn a_snapshot_from_before_the_core_gave_the_pair_says_the_status() {
        let all = listed(Shown::Working, "在干活", None);
        let d = drawn(Some("0x01"), "", SPLIT, Some(&all), None).unwrap();
        assert_eq!(d.title, title("t", Shown::Working, "在干活"));
        // And such a snapshot reads: the fixture with every `bar` cut out.
        let mut old = String::new();
        let mut rest = FIXTURE;
        while let Some(at) = rest.find("      \"bar\": {") {
            old.push_str(&rest[..at]);
            let end = rest[at..].find("},\n").unwrap() + at + "},\n".len();
            rest = &rest[end..];
        }
        old.push_str(rest);
        let read = snapshot::decode(&old).unwrap().terminals;
        assert_eq!(read.len(), 12);
        assert!(read.iter().all(|t| t.bar.is_none()));
    }

    #[test]
    fn a_glyph_the_host_does_not_know_is_an_error_not_a_blank_title() {
        let odd = FIXTURE.replacen("\"shown\": \"held\"", "\"shown\": \"muted\"", 1);
        assert!(matches!(snapshot::decode(&odd), Err(snapshot::DecodeError::UnknownValue(_))));
        assert!(FIXTURE.contains("\"shown\": \"held\""));
    }

    #[test]
    fn held_is_the_only_glyph_of_a_title_that_is_not_a_status() {
        for status in [Shown::NeedsYou, Shown::Trouble, Shown::DoneUnseen, Shown::Working, Shown::None] {
            assert_eq!(BarShown::of(status).status(), Some(status));
            assert_eq!(BarShown::of(status).name(), status.name());
        }
        let not: Vec<BarShown> = BarShown::ALL.into_iter().filter(|b| b.status().is_none()).collect();
        assert_eq!(not, [BarShown::Held]);
        assert_eq!(BarShown::Held.name(), "held");
    }

    #[test]
    fn a_held_title_draws_the_two_bars_and_its_words_in_the_second_ink_and_nothing_moves() {
        let f = Px { x: 0, y: 0, w: 700, h: 500 };
        for dark in [false, true] {
            let theme = look::theme(dark);
            for (wears, second) in [(Wears::Supervisor, theme.text_secondary), (Wears::Worker, theme.terminal_dim), (Wears::Plain, theme.terminal_dim)] {
                let d = Drawn { wears, title: Title { name: "tests".to_string(), shown: BarShown::Held, word: "被按住".to_string() }, color: None };
                let items = build(f, &d, &view(dark, 1.0, false), &same);
                let parts = items
                    .iter()
                    .find_map(|i| match i {
                        Item::Line { parts, .. } => Some(parts),
                        Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => None,
                    })
                    .unwrap();
                // The glyph, then the word to its right: both trailing.
                let held: Vec<&Part> = parts.iter().filter(|p| matches!(p.piece, Piece::Held { .. })).collect();
                assert_eq!(held.len(), 1, "{wears:?}");
                assert_eq!(held[0].piece, Piece::Held { color: second, size: side::GLYPH }, "{wears:?} dark={dark}");
                assert_eq!(held[0].side, Side::Trail);
                let word = parts.last().unwrap();
                assert!(matches!(&word.piece, Piece::Words { text, style } if text == "被按住" && style.color == second && style.weight == font::WEIGHT_EMPHASIS), "{wears:?}");
                // No status glyph beside it, and no clock for it.
                assert!(!parts.iter().any(|p| matches!(p.piece, Piece::Glyph { .. })));
                assert!(!scene::moves(&items));
            }
        }
        // The two bars: inside the glyph's box, as the design has them.
        let bars = crate::glyph::held();
        assert_eq!(bars.len(), 2);
        for (bar, x) in bars.iter().zip([3.8, 7.8]) {
            assert_eq!(bar.outline, crate::glyph::Outline::RoundRect(x, 3.0, 2.4, 8.0, 0.8));
            assert_eq!(bar.level, 1.0);
        }
    }
}

#[cfg(test)]
mod colour_tests {
    use super::*;
    use crate::look;
    use crate::pane_color::Color;

    fn d(wears: Wears, color: Option<Color>) -> Drawn {
        Drawn { wears, title: Title { name: "n".into(), shown: BarShown::None, word: String::new() }, color }
    }

    /// The supervisor's flag whatever its colour, purple when none is set;
    /// a dot for any other pane with one; nothing for one without, or where
    /// no frame is drawn.
    #[test]
    fn the_badge_is_the_flag_for_the_supervisor_and_a_dot_for_any_other_coloured_pane() {
        assert_eq!(badge(Some(&d(Wears::Supervisor, None))), (BadgeKind::Flag, Some(Color::Purple)));
        assert_eq!(badge(Some(&d(Wears::Supervisor, Some(Color::Teal)))), (BadgeKind::Flag, Some(Color::Teal)));
        assert_eq!(badge(Some(&d(Wears::Worker, Some(Color::Orange)))), (BadgeKind::Dot, Some(Color::Orange)));
        assert_eq!(badge(Some(&d(Wears::Plain, Some(Color::Red)))), (BadgeKind::Dot, Some(Color::Red)));
        assert_eq!(badge(Some(&d(Wears::Worker, None))), (BadgeKind::None, None));
        assert_eq!(badge(None), (BadgeKind::None, None));
    }

    fn bar(drawn: &Drawn, dark: bool) -> Vec<Item> {
        let theme = look::theme(dark);
        let view = View { theme, scale: 1.0, focused: false, well: theme.terminal_background, close: false };
        build(Px { x: 0, y: 0, w: 600, h: 300 }, drawn, &view, &|s| s.to_string())
    }

    fn badges(items: &[Item]) -> Vec<Piece> {
        items
            .iter()
            .flat_map(|i| match i {
                Item::Line { parts, .. } => parts.iter().map(|p| p.piece.clone()).collect::<Vec<_>>(),
                _ => Vec::new(),
            })
            .filter(|p| matches!(p, Piece::Badge { .. }))
            .collect()
    }

    /// A coloured worker's badge is its dot and its word on the colour's own
    /// ground, and the word does not follow the name as well; a coloured
    /// ordinary terminal's is the dot alone.
    #[test]
    fn a_coloured_pane_s_badge_is_its_dot_and_its_word_on_its_colour() {
        for dark in [false, true] {
            let t = look::theme(dark);
            let w = badges(&bar(&d(Wears::Worker, Some(Color::Orange)), dark));
            assert_eq!(w.len(), 1, "dark={dark}");
            match &w[0] {
                Piece::Badge { mark, text, style, ground } => {
                    assert_eq!((*mark, text.as_str(), style.color, *ground), (crate::glyph::Mark::Dot, "Worker", t.pane_orange_badge_text, t.pane_orange_badge));
                }
                _ => unreachable!(),
            }
            let p = badges(&bar(&d(Wears::Plain, Some(Color::Teal)), dark));
            assert!(matches!(&p[..], [Piece::Badge { mark: crate::glyph::Mark::Dot, text, .. }] if text.is_empty()), "dark={dark}: {p:?}");
            // With none set: no badge, and the worker's word after its name.
            assert!(badges(&bar(&d(Wears::Worker, None), dark)).is_empty());
            let sv = badges(&bar(&d(Wears::Supervisor, Some(Color::Green)), dark));
            assert!(matches!(&sv[..], [Piece::Badge { mark: crate::glyph::Mark::Supervisor, ground, .. }] if *ground == t.pane_green_badge), "dark={dark}");
        }
    }

    #[test]
    fn with_no_frames_any_coloured_pane_has_its_edge_in_its_colour() {
        let off = Place { enabled: false, quick_terminal: false, alone: false };
        assert_eq!(edged(None, off, Some(&[]), Some(Color::Pink)), Some(Color::Pink));
        assert_eq!(edged(None, off, Some(&[]), None), None);
        assert_eq!(edged(None, Place { enabled: true, ..off }, Some(&[]), Some(Color::Pink)), None);
        assert_eq!(edged(None, Place { quick_terminal: true, ..off }, Some(&[]), Some(Color::Pink)), None);
    }
}
