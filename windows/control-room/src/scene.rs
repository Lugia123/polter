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
use crate::look::{font, line, pane, radius, side, space, Rgba, Theme};
use crate::snapshot::{Fix, Shown};

/// The English of what the panel says; `build` passes each through the
/// host's translation. `{}` is where the one argument goes.
pub mod msg {
    // What the list draws besides its rows (task 1661).
    pub const ASKED_REPORT: &str = n_("Asked the supervisor for a progress report");
    pub const ASKED_CLOSE_IDLE: &str = n_("Asked the supervisor to close idle workers");
    pub const ASKED_TIDY_WORKERS: &str = n_("Asked the supervisor to tidy its workers");
    pub const NOT_DELIVERED: &str = n_("Not delivered: {}");
    pub const NOT_DELIVERED_RETRIED: &str = n_("Not delivered yet: {}. It will be tried again.");
    pub const ARCHIVED_HEADER: &str = n_("Archived ({})");
    /// The month and then the day, as numbers.
    pub const ARCHIVED_ON: &str = n_("archived {}/{}");
    // The group's brief, edited in the panel at the right (task 1661).
    pub const NOTE_TITLE: &str = n_("{}'s brief");
    pub const NOTE_WHO: &str = n_("The group's supervisor and workers can all read this.");
    pub const NOTE_COUNT: &str = n_("{} characters");
    pub const NOTE_COUNT_UNSAVED: &str = n_("{} characters, not saved");
    use crate::n_;

    /// The snapshot could not be read. `{}` is what was wrong with it.
    pub const UNREADABLE: &str = n_("The control room's data could not be read ({}).");
    /// No snapshot has been worked out yet.
    pub const NOT_YET: &str = n_("Nothing has been worked out yet.");
    /// The macOS words (`ControlRoomLending.swift`), task 1550.
    pub const NO_SELECTION: &str = n_("Select a group to see its supervisor.");
    pub const NO_SUPERVISOR: &str = n_("This group has no supervisor.");
    pub const IN_ITS_OWN_TAB: &str = n_("Showing in the supervisor's tab");
    /// The second line when the terminal is in another window: the whole
    /// of the right-hand side is the button, and pressing goes there.
    pub const GO_THERE: &str = n_("Click to go there");
    /// The second line when the person took the terminal back to its own
    /// tab: pressing anywhere on the side brings it here again (task 1758,
    /// macOS's `switchHere`).
    pub const SWITCH_HERE: &str = n_("Click to switch here");
    pub const HIDDEN_STEPS: &str = n_("{} more steps");
    /// The one button of the list: at the right end of its header.
    pub const NEW_GROUP: &str = n_("New Group");
    /// The empty name field's placeholder: macOS's msgid (task 1758).
    pub const GROUP_NAME: &str = n_("Group name");
    /// The first sweep of old records waits for the person (task 1511).
    /// `%@` is a size; the macOS host's sentence and its format, so the two
    /// share a translation.
    pub const RETENTION_WAITING: &str = n_("The new retention settings will clear %@ of old records");
    pub const OK: &str = n_("OK");
    /// The button on a card that reads "Failed" (task 1560), and what it
    /// says, greyed, once pressed. The macOS host's words.
    pub const FIX: &str = n_("Fix");
    pub const FIX_SENT: &str = n_("Supervisor notified");
    /// What the right side says of a group with no supervisor, by what the
    /// core says became of starting one. The macOS host's sentences.
    pub const STARTING: &str = n_("Starting the supervisor…");
    /// Starting, and its CLI asks the person something in its tab (task
    /// 1746), with the button that goes there.
    pub const ASKING: &str = n_("The supervisor is waiting in its tab for you to answer a question.");
    pub const GO_TO_ITS_TAB: &str = n_("Go to Its Tab");
    pub const NEVER_OPENED: &str = n_("The supervisor did not start: its tab never opened.");
    pub const PROJECT_NEVER_OPENED: &str = n_("The supervisor did not start: its group's project never opened.");
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
    /// The same button for a group whose start opens its project (task
    /// 1756): the macOS host's word (`ProjectLink.startTitle`).
    pub const OPEN: &str = n_("Open");
    // The sentence under it (task 1756): the macOS host's words
    // (`ProjectLinkRules.startNote`).
    pub const NO_PROJECT_YET: &str = n_("This group has no project yet, so only the supervisor starts. Once it takes up the group, its tab is saved as a project of the group's name; you are told when it is, and it can be undone.");
    /// `{}` is how many pages its project has.
    pub const ALL_PAGES_BACK: &str = n_("All {} page(s) of its project come back and the supervisor starts in its own pane. The workers' panes come back as terminals only; who is called back is the supervisor's to decide.");
    pub const EVERY_PAGE_BACK: &str = n_("Every page of its project comes back and the supervisor starts in its own pane. The workers' panes come back as terminals only; who is called back is the supervisor's to decide.");
    // What the group's last supervisor was. The sentences are the macOS
    // host's, word for word (`ControlRoomStartChoice.lastSupervisorText`).
    /// The first `{}` is the directory, the second the agent CLI.
    pub const LAST_IN_USING: &str = n_("The last supervisor worked in {}, using {}.");
    pub const LAST_IN: &str = n_("The last supervisor worked in {}.");
    pub const LAST_USED: &str = n_("The last supervisor used {}.");
    // The two sessions a start can use.
    pub const GO_ON: &str = n_("Go on with the last session");
    pub const NEW_SESSION: &str = n_("New session");
    // Why a start will not go on with the last session
    // (`ControlRoomStartChoice.resumeNote`).
    pub const WHY_NO_SESSION: &str = n_("A new session will be started: the last supervisor's CLI never said which session it was in.");
    pub const WHY_LAST_TRY_FAILED: &str = n_("A new session will be started: going on with the last one did not work the last time it was tried.");
    pub const WHY_CLI_DIFFERS: &str = n_("A new session will be started: the last session was in another CLI.");
    pub const WHY_CLIS_UNREAD: &str = n_("Checking whether the last session can be gone on with…");
    pub const WHY_CLI_CANNOT_RESUME: &str = n_("A new session will be started: this CLI cannot go on with an earlier session.");
    pub const WHY_SESSION_IN_USE: &str = n_("A new session will be started: an open terminal is in the last session now.");
    /// The label of the line of agent CLIs a start can use (#1678), shown
    /// only when the role can be started in more than one.
    pub const AGENT_CLI: &str = n_("Agent CLI");
    /// Why "Go on with the last session" is greyed: another CLI was picked
    /// than the one that session was in. The first `{}` is that session's
    /// CLI, the second the one picked.
    pub const LAST_SESSION_WAS: &str = n_("The last session was {}'s; {} can't go on with it.");
    /// The CLI the last supervisor used is held back because its program
    /// is not on this machine (task 1744). The `{}` is that CLI.
    /// Where "Go on with the last session" will be, while it is looked for
    /// (task 1741).
    pub const LOOKING: &str = n_("Looking for the last session…");
    /// Where it would be, when it was looked for and cannot be gone on with
    /// (task 1741). Why is said on hover.
    pub const DIDNT_FIND: &str = n_("Didn't find the last session");
    pub const LAST_CLI_NOT_HERE: &str = n_("{}, which the last supervisor used, is not installed on this machine.");
    /// The directory, when the core names none: the new tab's own.
    pub const WHERE_THE_TAB_STARTS: &str = n_("Where the tab starts");
    /// The right side, for a row that is a terminal in no group: it is
    /// itself what would be shown there. The macOS host's sentences.
    pub const TERMINAL_GONE: &str = n_("This terminal is no longer open.");
    pub const TERMINAL_IN_ITS_OWN_TAB: &str = n_("Showing in its own tab");
    /// The button on the frame of a supervisor somebody started by hand
    /// (task 1635), and the title of the question it asks. The macOS
    /// host's words.
    pub const TAKE_OVER: &str = n_("Let the control room take over?");
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
    /// From the right like `Trail`, but left out -- all of them -- when with
    /// them the first leading part would not be whole: what a line gives up
    /// before what leads it. A supervisor's status word, which goes before
    /// its badge does (task 1692); the glyph left of it moves to the end.
    Yield,
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
/// worker's whole title and no group at all (task 1444, defect 3). Before
/// any of that, the yielding parts are left out when keeping them would cut
/// the first leading part.
pub fn place_line(left: i32, right: i32, parts: &[(Side, i32, i32)]) -> Vec<Option<Placed>> {
    let mut out = vec![None; parts.len()];
    let trailing = |side: Side, yields: bool| side == Side::Trail || (yields && side == Side::Yield);
    // Where the trailing parts would begin with the yielding ones kept.
    let with = right - parts.iter().filter(|(side, _, _)| trailing(*side, true)).map(|(_, gap, width)| width + gap).sum::<i32>();
    let first = parts.iter().find(|(side, _, _)| *side == Side::Lead).map_or(0, |(_, gap, width)| gap + width);
    let yields = left + first <= with;
    let mut trail = right;
    for (i, (side, gap, width)) in parts.iter().enumerate().rev() {
        if trailing(*side, yields) {
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
    /// Pinned or muted, beside a group's name (`glyph::mark`); the
    /// supervisor's flag, before its name on a stack's tab.
    Mark { mark: crate::glyph::Mark, color: Rgba, size: f64 },
    /// The supervisor's badge at the left end of its title (task 1692, the
    /// design's `supervisor-pane-v1` C): the flag and `text` in `style`, on
    /// `ground`, round at both ends and `look::supervisor_badge` in size.
    /// As wide as the two and its paddings; a host given less draws the
    /// flag alone on it, and nothing when even that does not fit.
    ///
    /// `mark` is the flag for the supervisor and the dot for any other pane
    /// with a colour (task 1700); `text` empty is the mark alone.
    Badge { mark: crate::glyph::Mark, text: String, style: Style, ground: Rgba },
    /// A place where a name will be, not known yet (task 1741: an agent
    /// CLI's, before the adapters are read): a rounded bar `width` by
    /// `height` points, centred on the line. Never the key in its place.
    Bar { color: Rgba, width: f64, height: f64 },
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
    /// What follows is drawn only inside `rect`, until the next `Clip`;
    /// none draws everywhere again. The scrolled rows are drawn this way,
    /// so that one half out of the viewport is cut at its edge (task 1657).
    Clip { rect: Option<Rect> },
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

pub fn body_style(color: Rgba) -> Style {
    body(color)
}

fn body(color: Rgba) -> Style {
    Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color }
}

fn words(text: impl Into<String>, style: Style, side: Side, gap: f64) -> Part {
    Part { piece: Piece::Words { text: text.into(), style }, side, gap }
}

/// The group's brief, being edited in the panel at the right (task 1661,
/// design v21 `04-B`, with the user's changes: no cross at the top -- the
/// button at the bottom closes it -- and the buttons the settings window's).
/// `rect` is the panel's, in the room's points. What is typed is the host's
/// own multi-line box, put where `field` says, inset by `field_inset`; the
/// two buttons are the host's own too, in the band `buttons` leaves at the
/// bottom, at its right.
pub struct Note {
    pub items: Vec<Item>,
    pub field: Rect,
    pub buttons: Rect,
}

/// How far the typed text stands in from the box's edge.
pub const NOTE_FIELD_INSET: f64 = space::FRAME_TO_CONTENT / 2.0;

/// `chars` is how long the brief is as typed; `dirty` that it differs from
/// the group's. `band` is how high the host's buttons need the bottom band
/// to be, in points.
pub fn build_note(group: &str, rect: Rect, theme: &Theme, scale: f64, chars: usize, dirty: bool, band: f64, tr: &dyn Fn(&str) -> String) -> Note {
    let panel = panel_color(theme);
    let pad = space::FRAME_TO_CONTENT;
    let mut items = vec![Item::Round {
        rect,
        radius: radius::SIDE_PANEL,
        color: panel,
        edge: Some(over(panel, theme.side_panel_edge, hairline(scale).1)),
    }];
    let inner = Rect { x: rect.x + pad, y: rect.y + pad, w: (rect.w - 2.0 * pad).max(0.0), h: (rect.h - 2.0 * pad).max(0.0) };
    // The title, and who reads it.
    let title = Rect { h: side::HEADER_HEIGHT, ..inner };
    items.push(Item::Text {
        rect: title,
        text: list::fill(&tr(msg::NOTE_TITLE), group),
        style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.text) },
        align: Align::Left,
    });
    let who = Rect { y: title.y + title.h, h: side::ASK_LINE_HEIGHT, ..inner };
    items.push(Item::Text { rect: who, text: tr(msg::NOTE_WHO), style: body(theme.text_secondary), align: Align::Left });
    // The band at the bottom: how long it is, and the buttons.
    let band_rect = Rect { x: rect.x, y: (rect.y + rect.h - band).max(who.y + who.h), w: rect.w, h: band.min(rect.h) };
    let count = Rect { x: inner.x, y: band_rect.y, w: inner.w, h: band_rect.h };
    let said = list::fill(&tr(if dirty { msg::NOTE_COUNT_UNSAVED } else { msg::NOTE_COUNT }), &chars.to_string());
    items.push(Item::Text { rect: count, text: said, style: body(theme.text_secondary), align: Align::Left });
    // The box, between the two.
    let top = who.y + who.h + side::ROW_GAP;
    let field = Rect { x: inner.x, y: top, w: inner.w, h: (band_rect.y - top).max(0.0) };
    items.push(Item::Round { rect: field, radius: radius::ROW, color: theme.window_base, edge: Some(theme.line_faint) });
    Note { items, field, buttons: Rect { x: inner.x, y: band_rect.y, w: inner.w, h: band_rect.h } }
}

/// What the line under a row says (task 1661, design v21 `03` and `07`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnderLine {
    /// Why the name typed for the row was refused, as the person is told
    /// it; the field above it is underlined in red.
    Refused(String),
    /// The supervisor was asked to report, or to close idle workers: the
    /// sentence was typed into its terminal. Not "done" -- asked.
    Asked(crate::act::Ask),
    /// It could not be typed in, and why, in a few words; `retried` when
    /// the core will try again by itself. `ask` is what was asked, for the
    /// line that replaces this one when a retry goes in, and `on` the
    /// message it is about, once a snapshot has said (`act::follow_ask`).
    NotDelivered { why: String, retried: bool, ask: crate::act::Ask, on: Option<u64> },
}

/// The allowance block at the bottom of the list (task 1755): the macOS
/// host's `ControlRoomQuotaView`, drawn where the layout left it
/// (`ListLayout::quota`). The hairline that closes the list; each account
/// at or past the limit line opened out -- which and how much in the
/// problem colour, the triangle when it is all gone, when it comes back at
/// the right, a bar, and the way out under it when the core names one;
/// then the one line, each account and its number. Every word is
/// `quota`'s and every size `look::quota`'s; nothing here can be pressed.
/// Nothing when the list has no block. `offset_ms` is the person's clock
/// against UTC, for a moment said as a time of day.
pub fn build_quota(list: &List, at: &ListLayout, view: &View, offset_ms: i64, tr: &dyn Fn(&str) -> String) -> Vec<Item> {
    use crate::look::quota as q;
    use crate::quota::{self as qt, Level, State};
    let Some(quota) = list.quota.as_ref() else { return Vec::new() };
    if at.quota.h <= 0.0 {
        return Vec::new();
    }
    let theme = view.theme;
    let panel = panel_color(theme);
    let shape = qt::layout(quota);
    let block = at.quota;
    let x = block.x + q::PADDING_X;
    let w = (block.w - 2.0 * q::PADDING_X).max(0.0);
    let mut out = Vec::new();

    let (hair_h, hair_strength) = hairline(view.scale);
    out.push(fill(Rect { x, y: block.y, w, h: hair_h }, over(panel, theme.line_faint, hair_strength)));

    for (alert, &(y, _, note)) in quota.alerts.iter().zip(shape.parts.iter()) {
        let top = block.y + y + q::ALERT_PADDING_TOP;
        let mut parts = Vec::new();
        if alert.level == Level::Out {
            parts.push(Part {
                piece: Piece::Glyph { shown: Shown::Trouble, color: glyph_color(theme, Shown::Trouble), size: side::GLYPH, pulses: false },
                side: Side::Lead,
                gap: 0.0,
            });
        }
        let gap = if parts.is_empty() { 0.0 } else { q::ALERT_GLYPH_GAP };
        parts.push(words(qt::alert_title(alert, tr), Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.problem_text_on_row) }, Side::Rest, gap));
        parts.push(words(qt::when_text(alert, offset_ms, tr), body(theme.text), Side::Trail, q::LABEL_GAP));
        out.push(Item::Line { rect: Rect { x, y: top, w, h: q::ALERT_TITLE_HEIGHT }, parts });

        // The bar: a track, and as much of it as is used. An old number's
        // is an outline the same length and not filled, so that it does
        // not read as a measurement taken now.
        let bar_y = top + q::ALERT_TITLE_HEIGHT + q::BAR_SPACE_ABOVE;
        let track = Rect { x, y: bar_y, w, h: q::BAR_HEIGHT };
        out.push(Item::Round { rect: track, radius: q::BAR_RADIUS, color: theme.line, edge: None });
        let filled = Rect { w: (w * alert.used as f64 / 100.0).max(q::BAR_MIN_FILL).min(w), ..track };
        out.push(match alert.stale {
            Some(_) => Item::Round { rect: filled, radius: q::BAR_RADIUS, color: theme.line, edge: Some(theme.text_tertiary) },
            None => Item::Round { rect: filled, radius: q::BAR_RADIUS, color: theme.problem, edge: None },
        });
        if note {
            if let Some(way) = qt::way_out_text(alert, tr) {
                let note_y = bar_y + q::BAR_HEIGHT + q::BAR_SPACE_BELOW;
                out.push(Item::Text { rect: Rect { x, y: note_y, w, h: q::NOTE_LINE_HEIGHT }, text: way, style: body(theme.text), align: Align::Left });
            }
        }
    }

    if let (Some(line), Some(line_y)) = (quota.line.as_ref(), shape.line_y) {
        let mut parts = vec![words(qt::label_text(line.label, tr), body(theme.text_secondary), Side::Lead, 0.0)];
        if line.entries.is_empty() {
            parts.push(words(tr(qt::msg::NONE_YET), body(theme.text_secondary), Side::Trail, q::LABEL_GAP));
        } else {
            for (i, entry) in line.entries.iter().enumerate() {
                // The name a step back; the number in the main colour unless
                // the core says it is old, unreadable or come round again.
                let ink = match entry.state {
                    State::Fresh => theme.text,
                    State::Stale | State::Recovered | State::Unreadable => theme.text_secondary,
                };
                let gap = if i == 0 { q::LABEL_GAP } else { q::ENTRY_GAP };
                parts.push(words(format!("{} ", qt::name(entry.family)), body(theme.text_secondary), Side::Trail, gap));
                parts.push(words(qt::entry_number(entry, tr), body(ink), Side::Trail, 0.0));
            }
        }
        out.push(Item::Line { rect: Rect { x, y: block.y + line_y, w, h: q::LINE_HEIGHT }, parts });
    }
    out
}

/// The lines under rows, the archived section, and the red line under a
/// name being typed when it was refused -- what the list draws besides its
/// rows (task 1661). In the viewport, as the rows are. `archived` is the
/// list's, in its order; `open` whether its section is; `offset_ms` how
/// far local time is ahead of UTC, for the day each was put away.
pub fn build_extras(
    list: &List,
    at: &ListLayout,
    view: &View,
    under: &[(String, UnderLine)],
    open: bool,
    offset_ms: i64,
    tr: &dyn Fn(&str) -> String,
) -> Vec<Item> {
    let theme = view.theme;
    let panel = panel_color(theme);
    let mut out = vec![Item::Clip { rect: Some(at.viewport) }];
    for (id, line) in under {
        let (Some((_, r)), Some(row)) = (at.line_rects.iter().find(|(u, _)| u == id), at.chip(Some(id))) else { continue };
        let (_, text_x) = glyph_column(row);
        let rect = Rect { x: text_x, y: r.y, w: (row.x + row.w - side::ROW_PADDING_X - text_x).max(0.0), h: r.h };
        let (text, color) = match line {
            UnderLine::Refused(why) => (why.clone(), theme.problem_text_on_row),
            UnderLine::Asked(ask) => (
                format!(
                    "\u{2713} {}",
                    tr(match ask {
                        crate::act::Ask::Report => msg::ASKED_REPORT,
                        crate::act::Ask::CloseIdle => msg::ASKED_CLOSE_IDLE,
                        crate::act::Ask::TidyWorkers => msg::ASKED_TIDY_WORKERS,
                    })
                ),
                theme.text_secondary,
            ),
            UnderLine::NotDelivered { why, retried, .. } => (
                format!("\u{26a0} {}", list::fill(&tr(if *retried { msg::NOT_DELIVERED_RETRIED } else { msg::NOT_DELIVERED }), why)),
                theme.problem_text_on_row,
            ),
        };
        out.push(Item::Text { rect, text, style: body(color), align: Align::Left });
        if matches!(line, UnderLine::Refused(_)) {
            // The field's underline, red: in the strip `rename_field` keeps
            // clear of the field, where the field cannot paint over it
            // (task 1671: it used to sit under the field's own window).
            if let Some(f) = rename_field(list, at, id) {
                out.push(fill(Rect { x: f.x, y: f.y + f.h, w: f.w, h: crate::look::line::STROKE }, theme.problem_text_on_row));
            }
        }
    }
    if at.archived_header.h > 0.0 {
        out.push(fill(Rect { h: hairline(view.scale).0, ..at.archived_separator }, over(panel, theme.line_faint, hairline(view.scale).1)));
        let head = inset_x(at.archived_header, side::HEADER_PADDING_X);
        let fold = if open { "\u{25be}" } else { "\u{25b8}" };
        out.push(Item::Text {
            rect: head,
            text: format!("{fold} {}", list::fill(&tr(msg::ARCHIVED_HEADER), &list.archived.len().to_string())),
            style: body(theme.text_secondary),
            align: Align::Left,
        });
        for (name, r) in &at.archived_rows {
            let Some(a) = list.archived.iter().find(|a| &a.name == name) else { continue };
            let (_, text_x) = glyph_column(*r);
            let (_, m, d) = crate::rowmenu::civil((a.archived_ms as i64 + offset_ms).div_euclid(86_400_000));
            let when = list::fill(&list::fill(&tr(msg::ARCHIVED_ON), &m.to_string()), &d.to_string());
            out.push(Item::Line {
                rect: Rect { x: text_x, y: r.y, w: (r.x + r.w - side::ROW_PADDING_X - text_x).max(0.0), h: r.h },
                parts: vec![
                    words(name.clone(), Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Mono, color: theme.text_tertiary }, Side::Lead, 0.0),
                    words(when, body(theme.text_tertiary), Side::Rest, side::ROW_ITEM_GAP),
                ],
            });
        }
    }
    out.push(Item::Clip { rect: None });
    out
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
    /// Why the last "Fix" was refused, and on which row (`Row::id`): said
    /// beside the button (`act::fix_refusal_stands` says how long).
    pub fix_refusal: Option<(&'a str, &'a str)>,
}

/// A group being named.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Naming<'a> {
    /// Why the name as typed made no group; said under the field.
    pub refusal: Option<&'a str>,
}

/// The "Fix" button on a waiting row whose rect is `row`: on the line the
/// layout left at the row's bottom (`side::FIX_LINE_HEIGHT`), under the
/// row's text. A press here is the button's and not the row's. 暂定: a
/// fixed width, the room "Supervisor notified" takes, since only a host can
/// measure the words.
pub fn fix_hit(row: Rect) -> Rect {
    let (_, text_x) = glyph_column(row);
    let line_y = row.y + row.h - side::ROW_PADDING_Y - side::FIX_LINE_HEIGHT;
    let h = crate::layout::NOTICE_BUTTON_H;
    Rect { x: text_x, y: line_y + (side::FIX_LINE_HEIGHT - h) / 2.0, w: FIX_BUTTON_W, h }
}

/// See `fix_hit`.
pub const FIX_BUTTON_W: f64 = 136.0;
/// 暂定: a push button's corner, rounder than nothing and not a row's, so
/// that it is not read as a second selection chip.
pub const FIX_BUTTON_RADIUS: f64 = 4.0;

/// The notice's OK: under its two lines, at its left.
pub fn retention_ok_hit(notice: Rect) -> Rect {
    Rect {
        x: notice.x + side::ROW_PADDING_X,
        y: notice.y + side::ROW_PADDING_Y + 2.0 * side::ASK_LINE_HEIGHT + 4.0,
        w: crate::layout::NOTICE_BUTTON_W,
        h: crate::layout::NOTICE_BUTTON_H,
    }
}

/// A size the way Explorer writes one. The settings page's own
/// (`polter_settings_shell::logs::size_text`) is in a crate this one does
/// not depend on; the two are tested to agree on the same numbers.
pub fn size_text(bytes: u64) -> String {
    const K: f64 = 1024.0;
    let b = bytes as f64;
    if b < K {
        format!("{bytes} B")
    } else if b < K * K {
        format!("{:.0} KB", b / K)
    } else if b < K * K * K {
        format!("{:.1} MB", b / (K * K))
    } else {
        format!("{:.2} GB", b / (K * K * K))
    }
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

    // When the rows are more than their room holds, they and the chip are
    // drawn only in it, and scroll there (task 1657): one half out of the
    // room is cut at its edge, and none is drawn over the header or the
    // allowance block.
    let clips = crate::layout::scroll::max(at.content_height, at.viewport) > 0.0;
    let seen = |r: Rect| !clips || (r.y < at.viewport.y + at.viewport.h && r.y + r.h > at.viewport.y);
    if clips {
        out.push(Item::Clip { rect: Some(at.viewport) });
    }

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
    if clips {
        out.push(Item::Clip { rect: None });
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
                text: {
                    let (words, n) = list.waiting_heading();
                    list::fill(&tr(words), &n)
                },
                style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.text) },
                align: Align::Left,
            });
            out.push(Item::Text { rect: button, text: format!("+ {}", tr(msg::NEW_GROUP)), style: body(theme.text_secondary), align: Align::Right });
        }
    }

    if clips {
        out.push(Item::Clip { rect: Some(at.viewport) });
    }
    for row in &list.waiting {
        if let (Some(rect), Some(fit)) = (at.chip(Some(&row.id)), at.fit(&row.id)) {
            if seen(rect) {
                waiting_row(&mut out, row, rect, fit, view, tr);
            }
        }
    }

    if at.quiet_header.h > 0.0 && seen(at.quiet_header) {
        out.push(hair(at.separator, panel));
        out.push(Item::Text {
            rect: inset_x(at.quiet_header, side::HEADER_PADDING_X),
            text: {
                let (words, n) = list.quiet_heading();
                list::fill(&tr(words), &n)
            },
            style: body(theme.text_secondary),
            align: Align::Left,
        });
    }

    for row in &list.quiet {
        let Some(rect) = at.chip(Some(&row.id)) else { continue };
        if seen(rect) {
            quiet_row(&mut out, row, rect, view, tr);
        }
    }
    if clips {
        out.push(Item::Clip { rect: None });
    }

    // The first sweep of old records waiting for the person: in the room
    // the layout left under the header (task 1511). Not a row and not an
    // answer to an agent -- `tools/control-room-rows-only-tell.py` -- but
    // about Polter's own records, there until the OK.
    if let (Some(n), Some(bytes)) = (at.notice, list.retention_waiting_bytes) {
        out.push(Item::Round { rect: n, radius: radius::ROW, color: theme.window_base, edge: None });
        let text = Rect {
            x: n.x + side::ROW_PADDING_X,
            y: n.y + side::ROW_PADDING_Y,
            w: (n.w - 2.0 * side::ROW_PADDING_X).max(0.0),
            h: 2.0 * side::ASK_LINE_HEIGHT,
        };
        out.push(Item::Block {
            rect: text,
            text: tr(msg::RETENTION_WAITING).replace("%@", &size_text(bytes)),
            style: body(theme.text),
            lines: 2,
        });
        let ok = retention_ok_hit(n);
        out.push(Item::Round { rect: ok, radius: radius::ROW, color: panel, edge: Some(theme.line_faint) });
        out.push(Item::Text { rect: ok, text: tr(msg::OK), style: body(theme.text), align: Align::Centre });
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
/// Where the field is that a group's name becomes while it is renamed, in
/// the list's coordinates (scrolled as the rows are): the name's line, from
/// the text column to the row's end, less a `line::STROKE` at its foot for
/// the red line a refused name is underlined with -- a strip the host's edit
/// control does not cover. `None` when the group has no row.
pub fn rename_field(list: &List, at: &ListLayout, id: &str) -> Option<Rect> {
    let row = at.chip(Some(id))?;
    let waiting = list.waiting.iter().any(|w| w.id == id);
    let (_, text_x) = glyph_column(row);
    let (top, h) = if waiting { (row.y + side::ROW_PADDING_Y, side::ROW_LINE1_HEIGHT) } else { (row.y, side::QUIET_ROW_HEIGHT) };
    Some(Rect { x: text_x, y: top, w: (row.x + row.w - side::ROW_PADDING_X - text_x).max(1.0), h: (h - line::STROKE).max(1.0) })
}

fn glyph_column(rect: Rect) -> (f64, f64) {
    let x = rect.x + side::ROW_PADDING_X;
    (x, x + side::GLYPH + side::ROW_ITEM_GAP)
}

/// A group that needs nothing: the glyph in the same column as every other
/// row's, the name, and what it is doing. A group with nothing to say is
/// its name alone, a step back.
fn quiet_row(out: &mut Vec<Item>, row: &Row, rect: Rect, view: &View, tr: &dyn Fn(&str) -> String) {
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
    let marks = marks(row, theme);
    // With marks the name is a lead part, so that they stand after it.
    let name = if marks.is_empty() { name } else { Part { side: Side::Lead, ..name } };
    let mut parts = vec![name];
    parts.extend(marks);
    // A project's name is given what is left after what the group is
    // doing, and cut short when there is not room for it (task 1714): the
    // words for what it is doing stand where they always did and keep
    // their width, rather than giving way to it.
    let project = project_note(row, theme, tr);
    let name_last = project.iter().any(|p| p.side == Side::Squeezed);
    if !said.is_empty() {
        parts.push(words(said, body(theme.text_secondary), if name_last { Side::Lead } else { Side::Rest }, side::ROW_ITEM_GAP));
    }
    parts.extend(project);
    out.push(Item::Line { rect: Rect { x: text_x, y: rect.y, w: (right - text_x).max(0.0), h: rect.h }, parts });
}

/// What the right end of a group's row says of its project (task 1714,
/// `project_link::note`): the project's name in the second ink, last to be
/// given room and the first to be cut short (`Side::Squeezed`); or, when
/// there is something to answer, the attention glyph -- the same one, in
/// the same colour, as a row waiting for approval -- and a short word in
/// the colour of words that ask. Nothing for a group with neither.
fn project_note(row: &Row, theme: &Theme, tr: &dyn Fn(&str) -> String) -> Vec<Part> {
    let Some(p) = row.project.as_ref() else { return Vec::new() };
    let note = crate::project_link::note(&p.tie, &p.why, row.project_name.as_deref());
    let Some(word) = crate::project_words::note_word(&note, tr) else { return Vec::new() };
    match note {
        crate::project_link::Note::Name(_) => vec![words(word, body(theme.text_secondary), Side::Squeezed, side::ROW_ITEM_GAP)],
        _ => vec![
            Part {
                piece: Piece::Glyph { shown: Shown::NeedsYou, color: theme.attention, size: side::GLYPH, pulses: false },
                side: Side::Trail,
                gap: side::ROW_ITEM_GAP,
            },
            words(word, body(theme.attention_text), Side::Trail, pane::BAR_GAP),
        ],
    }
}

/// The marks after a group's name (task 1661, design v21 `05`): pinned
/// first, then muted, the first `ROW_ITEM_GAP` from the name and the second
/// `MARK_GAP` from the first, each the size of a status glyph, in the
/// quietest ink a row has. None on a row that is neither.
fn marks(row: &Row, theme: &Theme) -> Vec<Part> {
    let mut out = Vec::new();
    for (on, mark) in [(row.pinned, crate::glyph::Mark::Pinned), (row.muted.is_some(), crate::glyph::Mark::Muted)] {
        if on {
            let gap = if out.is_empty() { side::ROW_ITEM_GAP } else { side::MARK_GAP };
            out.push(Part { piece: Piece::Mark { mark, color: theme.text_tertiary, size: side::GLYPH }, side: Side::Lead, gap });
        }
    }
    out
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
    first.extend(marks(row, theme));
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
    // **Nothing on a row answers for the person.** A row says that somebody
    // is waiting and for what; the person goes to the terminal to answer. A
    // tick and a cross were here for a day and were taken out again (the
    // user's ruling, 2026-10-12): a row is too small to show what is being
    // agreed to, and what is being asked is often not a yes or a no.
    //
    // "Fix" on a card that reads "Failed" (task 1560) answers nothing: it
    // has the core tell the card's supervisor, which decides.
    if row.fix != Fix::None {
        let button = fix_hit(rect);
        let offered = row.fix == Fix::Offered;
        let ink = if offered { theme.text } else { theme.text_tertiary };
        let panel = panel_color(theme);
        out.push(Item::Round { rect: button, radius: FIX_BUTTON_RADIUS, color: panel, edge: Some(over(panel, theme.line_faint, 1.0)) });
        out.push(Item::Text {
            rect: button,
            text: tr(if offered { msg::FIX } else { msg::FIX_SENT }),
            style: body(ink),
            align: Align::Centre,
        });
        if let Some((_, why)) = view.fix_refusal.filter(|(id, _)| offered && *id == row.id) {
            let x = button.x + button.w + side::ROW_ITEM_GAP;
            out.push(Item::Text {
                rect: Rect { x, y: button.y, w: (rect.x + rect.w - side::ROW_PADDING_X - x).max(0.0), h: button.h },
                text: why.to_string(),
                style: body(theme.text_secondary),
                align: Align::Left,
            });
        }
    }
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
                        Piece::Words { text, .. } | Piece::Badge { text, .. } => out.push(text.as_str()),
                        Piece::Glyph { .. } | Piece::Bar { .. } => {}
                        Piece::Held { .. } | Piece::Mark { .. } => {}
                    }
                }
            }
            Item::Fill { .. } | Item::Round { .. } | Item::Clip { .. } => {}
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
            Piece::Held { .. } | Piece::Mark { .. } | Piece::Badge { .. } | Piece::Bar { .. } => false,
        }),
        Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => false,
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

/// Two lines of `line_h` with `gap` between them, centred up and down in
/// `place` and as wide as it is less its padding: where the side puts what
/// it says when the terminal is somewhere else (macOS's `VStack` there).
pub fn centred_lines(place: Rect, line_h: f64, gap: f64) -> [Rect; 2] {
    let pad = space::FRAME_TO_CONTENT;
    let w = (place.w - 2.0 * pad).max(0.0);
    let top = place.y + ((place.h - 2.0 * line_h - gap) / 2.0).max(pad);
    [Rect { x: place.x + pad, y: top, w, h: line_h }, Rect { x: place.x + pad, y: top + line_h + gap, w, h: line_h }]
}

/// What pressing the right-hand side does (`Right::press`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Press {
    /// It is in another window: go there (`lend::Place::Elsewhere`).
    GoThere,
    /// The person took it back to its own tab: bring it here again
    /// (`lend::Event::AskedFor`, task 1758).
    SwitchHere,
}

/// The right-hand side: the selected group's supervisor, or a sentence
/// saying why it is not there.
#[derive(Debug, Clone, PartialEq)]
pub struct Right {
    pub items: Vec<Item>,
    /// Where a press does something, and what: the whole of this side, when
    /// the supervisor is somewhere else. The second line says which and is
    /// not the only place to press.
    pub press: Option<(Rect, Press)>,
    /// Where the supervisor's own terminal goes, when it is shown here. The
    /// host puts the terminal's window exactly there; this draws only the
    /// frame round it.
    pub terminal: Option<Rect>,
    /// "Let the control room take over?", when the frame offers it: the
    /// title bar it is on. It is the bar's last part on the right, so it is
    /// pressed from the bar's right end back as far as its words reach --
    /// which the host measures, as it does every word it draws.
    pub take_over: Option<Rect>,
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
    /// Which session they picked; none while they have picked neither,
    /// and then it is the last one (`act::session_sent`).
    pub session: Option<crate::act::Session>,
    /// Which agent CLI they picked; none while they have picked none, and
    /// then it is the one `cli_choice` puts on.
    pub cli: Option<&'a str>,
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
    /// "Start Supervisor", when it can be pressed: not while the last
    /// session is looked for, unless a new one was picked (task 1741,
    /// `start_enabled`).
    pub start: Option<Rect>,
    /// Where the button is drawn, whether or not it can be pressed (task
    /// 1741): the same place in every state of the session's two lines.
    pub button: Option<Rect>,
    /// What hovering a line says, and where (task 1741: "Didn't find the
    /// last session" -- why). A host puts a tooltip there.
    pub tip: Option<(Rect, String)>,
    /// "Go to Its Tab", and the terminal it goes to: while a supervisor
    /// being started waits in its tab for the person (task 1746).
    pub go_to_tab: Option<(String, Rect)>,
    /// The two sessions' lines, when the core says the last one can be
    /// gone on with: pressing one picks it. Empty otherwise. **Not one
    /// whose line is greyed**: pressing that picks nothing.
    pub sessions: Vec<(crate::act::Session, Rect)>,
    /// The agent CLIs' lines, by CLI key, when the role can be started in
    /// more than one: pressing one picks it (#1678). Empty otherwise.
    pub clis: Vec<(String, Rect)>,
}

/// Whether the two-way choice of session is drawn: only when the core says
/// a start can go on with the last session. Offering it otherwise would be
/// offering something that then does not happen.
pub fn offers_session(start: Option<&crate::snapshot::SupervisorStart>) -> bool {
    start.and_then(|s| s.last.as_ref()).is_some_and(|l| l.can_resume)
}

/// How "Go on with the last session" stands for the CLI picked (#1678).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resume {
    /// Offered and can be picked: the picked CLI can go on with it.
    Live,
    /// Drawn grey, with "New session" taken instead: another CLI of the
    /// role could go on with it, the picked one cannot (01b). The layout
    /// does not jump as the CLI changes.
    Greyed,
    /// Still being looked for (task 1741): the adapters not read yet. The
    /// line says so beside a spinner, over "New session"; "Start" waits
    /// until the look ends or a new session is picked.
    Checking,
    /// Looked for, and not to be had (task 1741): "Didn't find the last
    /// session" over "New session", on; why, on hover.
    Missing,
    /// Not drawn: there never was a supervisor to go on from.
    Hidden,
}

impl Resume {
    pub fn name(self) -> &'static str {
        match self {
            Resume::Live => "live",
            Resume::Greyed => "greyed",
            Resume::Checking => "checking",
            Resume::Missing => "missing",
            Resume::Hidden => "hidden",
        }
    }
}

/// What a start offers of the role's agent CLIs (#1678; the macOS host's
/// `ControlRoomStartChoice`), for the role on screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliChoice {
    /// The CLIs the role can be started in: the core's list, whose plugins
    /// are on, in the role's order.
    pub clis: Vec<crate::snapshot::RoleCli>,
    /// The "Agent CLI" line is drawn: only for more than one (01c).
    pub shown: bool,
    /// How many CLIs the "Agent CLI" line has room for, drawn or not: the
    /// ones in `clis` and the ones held back only because their program is
    /// not here -- which are in `clis` until the adapters are read, so the
    /// number is the same before and after (task 1741). 0 for no line: one
    /// or none. Above `clis.len()`, the rest is kept empty, so the button
    /// under it does not move when the read takes a CLI away.
    pub room: usize,
    /// The CLI the start uses; none when the core names none.
    pub picked: Option<String>,
    pub resume: Resume,
    /// Why the picked CLI does not go on with the last session; `None` (the
    /// reason) when it does.
    pub why: crate::snapshot::ResumeWhy,
    /// The CLI the last supervisor used, by name, when the role holds it
    /// back because its program is not here (task 1744); none otherwise.
    pub last_gone: Option<String>,
}

/// Whether a start in `cli` goes on with the last session, and why not:
/// the core's answer for that CLI (`resume_by_cli`), and never one worked
/// out here. A core from before it said gives the one answer it has for
/// the CLI it names (`resume`); a CLI it gives no answer for is not gone
/// on with.
pub fn resume_for(last: &crate::snapshot::SupervisorLast, cli: Option<&str>) -> (bool, crate::snapshot::ResumeWhy) {
    if let Some(r) = last.by_cli.iter().find(|r| Some(r.cli.as_str()) == cli) {
        return (r.can, r.why);
    }
    if last.by_cli.is_empty() || cli == last.cli.as_deref() {
        return (last.can_resume, last.why);
    }
    (false, crate::snapshot::ResumeWhy::CliDiffers)
}

/// The CLI choice for a start in `role` (the core's when none is picked),
/// with `picked` the CLI the person pressed, none while they pressed none.
///
/// Which one is on before they press: for the core's role, the core's
/// (`supervisor.cli`); for another, the CLI the last supervisor used when
/// the role lists it, else the role's first -- the rule the core uses for
/// its own (`startCliOf`). A pick the role does not list is not kept.
pub fn cli_choice(
    start: &crate::snapshot::SupervisorStart,
    roles: &[crate::snapshot::SupervisorRole],
    role: Option<&str>,
    picked: Option<&str>,
) -> CliChoice {
    use crate::snapshot::ResumeWhy;
    let key = role.or(start.role.as_deref());
    let clis = key.and_then(|k| roles.iter().find(|r| r.key == k)).map(|r| r.clis.clone()).unwrap_or_default();
    let listed = |c: &str| clis.iter().any(|x| x.key == c);
    let last = start.last.as_ref();
    let core_default = if key == start.role.as_deref() { last.and_then(|l| l.cli.clone()) } else { None };
    let chosen = picked
        .filter(|c| listed(c))
        .map(str::to_string)
        .or_else(|| core_default.filter(|c| clis.is_empty() || listed(c)))
        .or_else(|| last.and_then(|l| l.last_cli.clone()).filter(|c| listed(c)))
        .or_else(|| clis.first().map(|c| c.key.clone()));
    let shown = clis.len() > 1;
    let gone = key.and_then(|k| roles.iter().find(|r| r.key == k)).map_or(0, |r| r.held_back.iter().filter(|h| h.why == crate::snapshot::HeldWhy::NotInstalled).count());
    let room = if clis.len() + gone > 1 { clis.len() + gone } else { 0 };
    let Some(last) = last else {
        return CliChoice { clis, shown, room, picked: chosen, resume: Resume::Hidden, why: ResumeWhy::NoRecord, last_gone: None };
    };
    // The last supervisor's CLI, held back because it is not installed here.
    let last_gone = last.last_cli.as_deref().and_then(|was| {
        let held = key.and_then(|k| roles.iter().find(|r| r.key == k))?.held_back.iter().find(|h| h.key == was)?;
        if held.why != crate::snapshot::HeldWhy::NotInstalled {
            return None;
        }
        cli_name(Some(was), held.label.as_deref().or(last.last_cli_label.as_deref()))
    });
    let (can, why) = resume_for(last, chosen.as_deref());
    let resume = if can {
        Resume::Live
    } else if shown && clis.iter().any(|c| resume_for(last, Some(&c.key)).0) {
        Resume::Greyed
    } else if why == ResumeWhy::ClisUnread {
        Resume::Checking
    } else if last.heard_ms.is_some() {
        Resume::Missing
    } else {
        Resume::Hidden
    };
    CliChoice { clis, shown, room, picked: chosen, resume, why: if can { ResumeWhy::None } else { why }, last_gone }
}

/// What the start sends for its session (`act::session_sent`): the one
/// picked while "Go on" can be picked, and nothing otherwise -- greyed or
/// not drawn, the core starts a new one by itself.
pub fn session_for(choice: &CliChoice, picked: Option<crate::act::Session>) -> Option<crate::act::Session> {
    // While looking, only "New session" can be picked, and then it is said
    // (task 1741): the core would answer the look with "not yet", a new
    // session the person did not choose.
    if choice.resume == Resume::Checking {
        return picked.filter(|p| *p == crate::act::Session::New);
    }
    crate::act::session_sent(choice.resume == Resume::Live, picked)
}

/// Whether "Start Supervisor" can be pressed (task 1741): not while the
/// last session is being looked for, unless a new one was picked -- the
/// start would otherwise go on with nothing and quietly drop the session the
/// person meant. The macOS host's `startEnabled`.
pub fn start_enabled(choice: &CliChoice, picked: Option<crate::act::Session>) -> bool {
    choice.resume != Resume::Checking || picked == Some(crate::act::Session::New)
}

/// What hovering "Didn't find the last session" says (task 1741): why, in
/// the core's words; that line's own words when there is no more to say.
/// None in any other state. The macOS host's `resumeTooltip`.
pub fn resume_tooltip(choice: &CliChoice, last: Option<&crate::snapshot::SupervisorLast>) -> Option<(&'static str, Vec<String>)> {
    if choice.resume != Resume::Missing {
        return None;
    }
    Some(resume_why(choice, last).unwrap_or((msg::DIDNT_FIND, Vec::new())))
}

/// The sentence under the sessions, as the English to translate and what
/// goes where its `{}` are; none when there is nothing to say. Greyed
/// because another CLI was picked: whose session it was, and which CLI
/// cannot go on with it. Otherwise the core's reason (`resume_note`).
pub fn resume_said(choice: &CliChoice, last: Option<&crate::snapshot::SupervisorLast>) -> Option<(&'static str, Vec<String>)> {
    // Only when "Go on" is greyed; not found says why on hover, so that
    // nothing moves (task 1741).
    if choice.resume != Resume::Greyed {
        return None;
    }
    resume_why(choice, last)
}

/// Why a start does not go on with the last session, as the English to
/// translate and its arguments; none when there is nothing to say. Its CLI
/// not on this machine; the session another CLI's; otherwise the core's
/// reason (`resume_note`). The macOS host's `resumeWhyText`.
pub fn resume_why(choice: &CliChoice, last: Option<&crate::snapshot::SupervisorLast>) -> Option<(&'static str, Vec<String>)> {
    use crate::snapshot::ResumeWhy;
    if choice.resume == Resume::Live {
        return None;
    }
    // Its CLI is not on this machine: that, before which session it was.
    if let Some(gone) = &choice.last_gone {
        return Some((msg::LAST_CLI_NOT_HERE, vec![gone.clone()]));
    }
    if choice.resume == Resume::Greyed && choice.why == ResumeWhy::CliDiffers {
        let last = last?;
        let was = cli_name(last.last_cli.as_deref(), last.last_cli_label.as_deref());
        let now = choice.picked.as_deref().and_then(|p| {
            let label = choice.clis.iter().find(|c| c.key == p).and_then(|c| c.label.as_deref());
            cli_name(Some(p), label)
        });
        if let (Some(was), Some(now)) = (was, now) {
            return Some((msg::LAST_SESSION_WAS, vec![was, now]));
        }
    }
    resume_note(choice.why).map(|t| (t, Vec::new()))
}

/// What an option of the choice is called.
pub fn session_words(session: crate::act::Session) -> &'static str {
    match session {
        crate::act::Session::Last => msg::GO_ON,
        crate::act::Session::New => msg::NEW_SESSION,
    }
}

/// One sentence about the supervisor this group last had -- where it
/// worked and which agent CLI it was -- as the English to translate and
/// what goes where its `{}` are, in order. None when the core has no
/// record of one, and then the right side is what it was before.
///
/// **The directory is said only when it is not the one on the line
/// above.** `starting_in` is the directory the person picked for this
/// start, none while they have picked nothing -- and then the start uses
/// the core's, which is drawn there already; said again it was the same
/// path twice in three lines (the user, 2026-10-13). And only when the
/// core says the directory it names is that supervisor's
/// (`cwd_from: last_supervisor`).
///
/// The CLI is said only when it was written down: by the name the core
/// gives for it (`cli_label`), and by its key when the core has none.
pub fn last_supervisor_said(
    start: Option<&crate::snapshot::SupervisorStart>,
    starting_in: Option<&str>,
    home: &str,
    tr: &dyn Fn(&str) -> String,
) -> Option<(&'static str, Vec<String>)> {
    let start = start?;
    let last = start.last.as_ref()?;
    last.heard_ms?;
    let elsewhere = starting_in.unwrap_or(&start.cwd) != start.cwd;
    let directory = (last.cwd_is_last && !start.cwd.is_empty() && elsewhere).then(|| shown_directory(&start.cwd, home, tr));
    let cli = cli_name(last.last_cli.as_deref(), last.last_cli_label.as_deref());
    match (directory, cli) {
        (Some(directory), Some(cli)) => Some((msg::LAST_IN_USING, vec![directory, cli])),
        (Some(directory), None) => Some((msg::LAST_IN, vec![directory])),
        (None, Some(cli)) => Some((msg::LAST_USED, vec![cli])),
        (None, None) => None,
    }
}

/// What a CLI is written as: the core's name for it, and its key when the
/// core has none. None when there is no CLI to name.
pub fn cli_name(key: Option<&str>, label: Option<&str>) -> Option<String> {
    let key = key.filter(|k| !k.is_empty())?;
    Some(label.filter(|l| !l.is_empty()).unwrap_or(key).to_string())
}

/// A name not read yet (task 1741): a bar where it will be, about as wide
/// as a name.
fn name_bar(theme: &Theme) -> Piece {
    Piece::Bar { color: theme.line_faint, width: 56.0, height: font::BODY * 0.8 }
}

/// The sentence `last_supervisor_words` says, cut where the CLI's name goes,
/// while that name is not read yet (task 1741): the right side draws a bar
/// between the two, never the key. None when the names are read, or the
/// sentence names no CLI. The macOS host's `lastSupervisorParts`.
pub fn last_supervisor_parts(start: &crate::snapshot::SupervisorStart, cwd: Option<&str>, home: &str, tr: &dyn Fn(&str) -> String) -> Option<(String, String)> {
    if start.clis_read {
        return None;
    }
    let last = start.last.as_ref()?;
    if last.last_cli.as_deref().is_none_or(str::is_empty) {
        return None;
    }
    let mut held = start.clone();
    if let Some(l) = held.last.as_mut() {
        l.last_cli_label = Some(NAME_PLACE.to_string());
    }
    let said = last_supervisor_words(Some(&held), cwd, home, tr)?;
    let (before, after) = said.split_once(NAME_PLACE)?;
    Some((before.to_string(), after.to_string()))
}

/// What stands for a name not read yet while a sentence is made, to be cut
/// out of it: no translation holds it.
const NAME_PLACE: &str = "\u{FFFC}";

/// The same sentence, translated and filled.
pub fn last_supervisor_words(
    start: Option<&crate::snapshot::SupervisorStart>,
    starting_in: Option<&str>,
    home: &str,
    tr: &dyn Fn(&str) -> String,
) -> Option<String> {
    let (template, args) = last_supervisor_said(start, starting_in, home, tr)?;
    Some(args.iter().fold(tr(template), |said, arg| list::fill(&said, arg)))
}

/// Why this start will not go on with the last session, in a sentence;
/// none where there is nothing worth saying -- it can, or there never was a
/// supervisor to go on from. **Every reason the core gives has an arm
/// here**: one added there does not compile here until somebody says what
/// the person is told.
pub fn resume_note(why: crate::snapshot::ResumeWhy) -> Option<&'static str> {
    use crate::snapshot::ResumeWhy as W;
    match why {
        W::None | W::NoRecord => None,
        W::NoSession => Some(msg::WHY_NO_SESSION),
        W::LastTryFailed => Some(msg::WHY_LAST_TRY_FAILED),
        W::CliDiffers => Some(msg::WHY_CLI_DIFFERS),
        W::ClisUnread => Some(msg::WHY_CLIS_UNREAD),
        W::CliCannotResume => Some(msg::WHY_CLI_CANNOT_RESUME),
        W::SessionInUse => Some(msg::WHY_SESSION_IN_USE),
    }
}

/// How many lines a sentence is given on the right side, by a count of its
/// cells (a wide character two) against the width: one, or two. The host
/// draws it wrapped inside the room this leaves.
fn sentence_lines(text: &str, width: f64) -> usize {
    let cells: usize = text.chars().map(|c| if c as u32 >= 0x2E80 { 2 } else { 1 }).sum();
    if cells as f64 * font::BODY * 0.55 > width { 2 } else { 1 }
}

/// What the right side says of a group with no supervisor: which sentence
/// is the core's word (`state`, `failed`).
pub fn no_supervisor_words(start: Option<&crate::snapshot::SupervisorStart>) -> &'static str {
    use crate::snapshot::{StartFailure as F, SupervisorState as S};
    match start.map(|s| (s.state, s.failed)) {
        Some((S::Starting, _)) if start.is_some_and(|s| s.asking) => msg::ASKING,
        Some((S::Starting, _)) => msg::STARTING,
        Some((S::Failed, F::TerminalNeverOpened)) => msg::NEVER_OPENED,
        Some((S::Failed, F::ProjectNeverOpened)) => msg::PROJECT_NEVER_OPENED,
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

/// The name a role is shown under: its name. The official supervisor role
/// used to be put into the reader's language by its key; official roles are
/// English as shipped (#1504), so the core's name is the one to show.
pub fn role_name(role: &crate::snapshot::SupervisorRole, _tr: &dyn Fn(&str) -> String) -> String {
    role.name.clone()
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
    let pad = space::FRAME_TO_CONTENT;
    let line_h = side::HEADER_HEIGHT;
    if let (crate::snapshot::SupervisorState::Starting, true, Some(terminal)) = (start.state, start.asking, start.terminal.as_ref()) {
        // Where "Start Supervisor" would be: the one thing to do is go
        // and answer it. Polter never does.
        let button = Rect { x: pad, y: start_top(), w: side::WIDTH / 2.0, h: line_h };
        let mut out = Start::default();
        out.items.push(Item::Round { rect: button, radius: radius::ROW, color: theme.terminal_background, edge: Some(theme.attention_text) });
        out.items.push(Item::Text {
            rect: button,
            text: tr(msg::GO_TO_ITS_TAB),
            style: Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.attention_text) },
            align: Align::Centre,
        });
        out.go_to_tab = Some((terminal.clone(), button));
        return out;
    }
    if !start.can_start {
        return Start::default();
    }
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

    // Where it starts -- not asked when it opens the group's project, whose
    // supervisor's pane has its own (task 1756, as on macOS).
    let project = row.and_then(|r| r.project.as_ref());
    if asks_directory(project) {
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
        y += line_h;
    }

    // What the last supervisor was, when the core has a record of one.
    let mut sentence = |out: &mut Start, y: &mut f64, text: String| {
        let lines = sentence_lines(&text, w);
        let h = lines as f64 * side::ASK_LINE_HEIGHT;
        out.items.push(Item::Block { rect: Rect { x: pad, y: *y + (line_h - side::ASK_LINE_HEIGHT) / 2.0, w, h }, text, style: body(theme.terminal_dim), lines });
        *y += h + (line_h - side::ASK_LINE_HEIGHT);
    };
    if let Some((before, after)) = last_supervisor_parts(start, view.cwd, view.home, tr) {
        // The CLI's name not read yet (task 1741): a bar where it will be.
        let mut parts = Vec::new();
        if draws(&before) {
            parts.push(words(before, body(theme.terminal_dim), Side::Lead, 0.0));
        }
        parts.push(Part { piece: name_bar(theme), side: Side::Lead, gap: 0.0 });
        if draws(&after) {
            parts.push(words(after, body(theme.terminal_dim), Side::Lead, 0.0));
        }
        out.items.push(Item::Line { rect: Rect { x: pad, y, w, h: line_h }, parts });
        y += line_h;
    } else if let Some(said) = last_supervisor_words(Some(start), view.cwd, view.home, tr).filter(|s| draws(s)) {
        sentence(&mut out, &mut y, said);
    }
    // A ring for each choice: the one in use filled in the attention colour,
    // never a grey ground; another an empty ring; one that cannot be
    // picked, greyed with its words.
    let radio = |out: &mut Start, y: f64, on: bool, enabled: bool, text: String| -> Rect {
        let rect = Rect { x: pad, y, w, h: side::QUIET_ROW_HEIGHT };
        let mark = Rect { x: pad, y: y + (side::QUIET_ROW_HEIGHT - side::GLYPH) / 2.0, w: side::GLYPH, h: side::GLYPH };
        let ink = if on { theme.attention_text } else if enabled { theme.terminal_dim } else { theme.text_tertiary };
        out.items.push(Item::Round { rect: mark, radius: side::GLYPH / 2.0, color: if on { ink } else { theme.terminal_background }, edge: Some(ink) });
        if on {
            let hole = side::GLYPH / 3.0;
            out.items.push(Item::Round {
                rect: Rect { x: mark.x + hole, y: mark.y + hole, w: side::GLYPH - 2.0 * hole, h: side::GLYPH - 2.0 * hole },
                radius: (side::GLYPH - 2.0 * hole) / 2.0,
                color: theme.terminal_background,
                edge: None,
            });
        }
        let lead = side::GLYPH + side::ROW_ITEM_GAP;
        // An empty one is never handed to a host (`draws`): a CLI's name
        // not read yet is a bar drawn on its own (task 1741).
        if draws(&text) {
            out.items.push(Item::Text {
                rect: Rect { x: pad + lead, y, w: (w - lead).max(0.0), h: side::QUIET_ROW_HEIGHT },
                text,
                style: body(if enabled { theme.terminal_text } else { theme.text_tertiary }),
                align: Align::Left,
            });
        }
        rect
    };

    // Which agent CLI (#1678): only when the role can be started in more
    // than one. Its rings stand on the same left edge as the sessions'.
    let choice = cli_choice(start, view.roles, view.role, view.cli);
    let top = y;
    if choice.shown {
        out.items.push(Item::Line { rect: Rect { x: pad, y, w, h: line_h }, parts: vec![label(msg::AGENT_CLI)] });
        y += line_h;
        for c in &choice.clis {
            let on = choice.picked.as_deref() == Some(c.key.as_str());
            // Its name not read yet (task 1741): a bar, never the key.
            let name = if start.clis_read { cli_name(Some(&c.key), c.label.as_deref()).unwrap_or_default() } else { String::new() };
            let rect = radio(&mut out, y, on, true, name);
            if !start.clis_read {
                let lead = side::GLYPH + side::ROW_ITEM_GAP;
                out.items.push(Item::Line { rect: Rect { x: pad + lead, y, w: (w - lead).max(0.0), h: side::QUIET_ROW_HEIGHT }, parts: vec![Part { piece: name_bar(theme), side: Side::Lead, gap: 0.0 }] });
            }
            out.clis.push((c.key.clone(), rect));
            y += side::QUIET_ROW_HEIGHT;
        }
    }
    // Its room, whatever of it is drawn (`CliChoice::room`, task 1741): a
    // CLI the read of the adapters takes away leaves its place empty.
    if choice.room > 0 {
        y = y.max(top + line_h + choice.room as f64 * side::QUIET_ROW_HEIGHT);
    }

    // Go on with its session or start a new one -- only when the core says
    // the first can be done, for some CLI on screen. Greyed when it can for
    // another CLI than the one picked. When it cannot, a sentence says why.
    // Always two lines high (task 1741), so the button under them is where
    // it was when the look for the last session ends.
    match choice.resume {
        Resume::Live | Resume::Greyed => {
            let live = choice.resume == Resume::Live;
            let picked = session_for(&choice, view.session).unwrap_or(crate::act::Session::New);
            for one in crate::act::Session::ALL {
                let enabled = live || one == crate::act::Session::New;
                let rect = radio(&mut out, y, picked == one, enabled, tr(session_words(one)));
                if enabled {
                    out.sessions.push((one, rect));
                }
                y += side::QUIET_ROW_HEIGHT;
            }
        }
        Resume::Checking | Resume::Missing => {
            let looking = choice.resume == Resume::Checking;
            let rect = Rect { x: pad, y, w, h: side::QUIET_ROW_HEIGHT };
            let text = tr(if looking { msg::LOOKING } else { msg::DIDNT_FIND });
            let mut parts = Vec::new();
            if looking {
                parts.push(Part { piece: Piece::Glyph { shown: Shown::Working, color: theme.working, size: side::GLYPH, pulses: false }, side: Side::Lead, gap: 0.0 });
            }
            let gap = if looking { side::ROW_ITEM_GAP } else { side::GLYPH + side::ROW_ITEM_GAP };
            parts.push(words(text, body(theme.terminal_dim), Side::Lead, gap));
            out.items.push(Item::Line { rect, parts });
            if let Some((template, args)) = resume_tooltip(&choice, start.last.as_ref()) {
                out.tip = Some((rect, args.iter().fold(tr(template), |said, arg| list::fill(&said, arg))));
            }
            y += side::QUIET_ROW_HEIGHT;
            let on = !looking || view.session == Some(crate::act::Session::New);
            let rect = radio(&mut out, y, on, true, tr(session_words(crate::act::Session::New)));
            out.sessions.push((crate::act::Session::New, rect));
            y += side::QUIET_ROW_HEIGHT;
        }
        Resume::Hidden => {}
    }
    if let Some((template, args)) = resume_said(&choice, start.last.as_ref()) {
        let said = args.iter().fold(tr(template), |said, arg| list::fill(&said, arg));
        sentence(&mut out, &mut y, said);
    }
    y += side::ROW_GAP;

    let button = Rect { x: pad, y, w: side::WIDTH / 2.0, h: line_h };
    // Not while the last session is looked for, unless a new one was picked
    // (task 1741): greyed, and not pressable.
    let can_press = start_enabled(&choice, view.session);
    let ink = if can_press { theme.attention_text } else { theme.text_tertiary };
    out.items.push(Item::Round { rect: button, radius: radius::ROW, color: theme.terminal_background, edge: Some(ink) });
    out.items.push(Item::Text {
        rect: button,
        text: tr(start_title(project)),
        style: Style { weight: font::WEIGHT_EMPHASIS, ..body(ink) },
        align: Align::Centre,
    });
    out.button = Some(button);
    out.start = can_press.then_some(button);
    y += line_h + side::ROW_GAP;
    // What starting it brings back, or that it has no project yet.
    if let Some((template, args)) = start_note(project) {
        let said = args.iter().fold(tr(template), |said, arg| list::fill(&said, arg));
        sentence(&mut out, &mut y, said);
    }

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

/// What the button that starts a group says (task 1756): "Open" when the
/// core says starting opens the group's project, "Start Supervisor"
/// otherwise -- which is also what it says when the core has said nothing
/// of a project. The macOS host's rule (`ProjectLinkRules.startTitle`).
pub fn start_title(project: Option<&crate::snapshot::ProjectTie>) -> &'static str {
    if project.is_some_and(|p| p.opens_project) {
        msg::OPEN
    } else {
        msg::START_SUPERVISOR
    }
}

/// Whether a start asks where the supervisor starts (task 1756): not when
/// it opens the group's project, whose supervisor's pane has its own. The
/// macOS host's rule (`ProjectLinkRules.asksDirectory`).
pub fn asks_directory(project: Option<&crate::snapshot::ProjectTie>) -> bool {
    !project.is_some_and(|p| p.opens_project)
}

/// The sentence under a group's start button (task 1756), as a template and
/// what fills it: how many pages come back when it opens the group's
/// project -- the count left out when the core does not know it -- or, for a
/// group with no project yet whose supervisor will be offered one, that its
/// tab will be saved as one and that this can be undone. `None` otherwise.
/// The macOS host's rule (`ProjectLinkRules.startNote`).
pub fn start_note(project: Option<&crate::snapshot::ProjectTie>) -> Option<(&'static str, Vec<String>)> {
    let p = project?;
    if !p.opens_project && p.tie == "undecided" && ["not_taken_up", "none", "pending"].contains(&p.why.as_str()) {
        return Some((msg::NO_PROJECT_YET, Vec::new()));
    }
    if !p.opens_project {
        return None;
    }
    Some(match p.pages {
        Some(n) => (msg::ALL_PAGES_BACK, vec![n.to_string()]),
        None => (msg::EVERY_PAGE_BACK, Vec::new()),
    })
}

/// Where the terminal sits inside the right-hand side when it is shown:
/// under the frame's title bar, inside its border.
pub fn terminal_rect(width: f64, height: f64) -> Rect {
    terminal_rect_with(width, height, 0.0)
}

/// `terminal_rect`, with `notice` points between the title bar and the
/// terminal for what is said about the group's project (task 1714,
/// `project_notice`): the terminal moves down by that much and is that much
/// shorter. The host places the terminal's window with the same number the
/// frame is drawn with.
pub fn terminal_rect_with(width: f64, height: f64, notice: f64) -> Rect {
    let b = pane::SUPERVISOR_BORDER;
    Rect { x: b, y: pane::BAR_HEIGHT + notice, w: (width - 2.0 * b).max(0.0), h: (height - pane::BAR_HEIGHT - b - notice).max(0.0) }
}

/// The band about the group's project, in the right side's points: under
/// the title bar, as wide as the terminal under it.
pub fn notice_origin(width: f64) -> (f64, f64, f64) {
    let t = terminal_rect(width, 0.0);
    (t.x, t.y, t.w)
}

/// `items` moved by `(dx, dy)`.
pub fn moved(items: Vec<Item>, dx: f64, dy: f64) -> Vec<Item> {
    let m = |r: Rect| Rect { x: r.x + dx, y: r.y + dy, ..r };
    items
        .into_iter()
        .map(|i| match i {
            Item::Fill { rect, color } => Item::Fill { rect: m(rect), color },
            Item::Round { rect, radius, color, edge } => Item::Round { rect: m(rect), radius, color, edge },
            Item::Text { rect, text, style, align } => Item::Text { rect: m(rect), text, style, align },
            Item::Line { rect, parts } => Item::Line { rect: m(rect), parts },
            Item::Block { rect, text, style, lines } => Item::Block { rect: m(rect), text, style, lines },
            Item::Clip { rect } => Item::Clip { rect: rect.map(m) },
        })
        .collect()
}

/// `detail` is what `lend::Lending` says the right side shows; `row` is the
/// selected row, for its name and state. `in_terminal` is whether the
/// terminal shown here has the keyboard. `width` and `height` are the right
/// side's own.
/// How "Let the control room take over?" is set on the supervisor's bar:
/// what a host measures to know how far back from the bar's right end a
/// press is the button's (`Right::take_over`).
pub fn take_over_style(theme: &Theme) -> Style {
    Style { weight: font::WEIGHT_EMPHASIS, ..body(theme.attention_text) }
}

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
    build_right_with(detail, row, width, height, theme, scale, in_terminal, tr, None)
}

/// `build_right`, with what is said about the group's project between the
/// supervisor's title bar and its terminal (task 1714): `notice` laid out
/// by `project_notice::band` at the width `notice_origin` gives. Only on
/// the supervisor's frame; elsewhere it is not drawn.
#[allow(clippy::too_many_arguments)]
pub fn build_right_with(
    detail: &Detail_,
    row: Option<&Row>,
    width: f64,
    height: f64,
    theme: &Theme,
    scale: f64,
    in_terminal: bool,
    tr: &dyn Fn(&str) -> String,
    notice: Option<&crate::project_notice::Band>,
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
        // A group's row: the supervisor terminal's own title and
        // "Supervisor". A terminal on its own: its title, and the word for
        // the frame its own pane wears -- none for an ordinary one. The
        // frame here is a supervisor's either way. Where the core lists no
        // such terminal there is only the group's name to write.
        let alone = row.and_then(|r| r.alone.as_ref());
        let title = row.and_then(|r| r.title.as_ref());
        let mut parts = vec![words(
            title.map_or(loan.group.clone(), |t| t.name.clone()),
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
        // The state is the terminal's own -- the supervisor's -- and not
        // the row's, which may be about one of its workers.
        if let Some(title) = title {
            // A supervisor started by hand (task 1635): said before its
            // status, in the attention ink -- it is why nothing else on
            // this frame will ever change.
            if let Some(note) = &title.note {
                let said = crate::snapshot::fill(&tr(&note.template), &note.args);
                if draws(&said) {
                    // The first to give way when the bar is short (task
                    // 1671; the macOS host lets it go first too): the name,
                    // its role, the status and the button keep their room.
                    parts.push(words(said, body(theme.attention_text), Side::Squeezed, pane::BAR_GAP));
                }
            }
            // What is happening to it, or why the last take-over stopped.
            if let Some(status) = title.take_over.as_ref().and_then(|t| t.status.as_ref()) {
                let said = crate::snapshot::fill(&tr(&status.template), &status.args);
                if draws(&said) {
                    parts.push(words(said, body(theme.text_secondary), Side::Trail, pane::BAR_GAP));
                }
            }
            let word_ink = match title.shown {
                Shown::NeedsYou | Shown::DoneUnseen => theme.attention_text,
                // Where the word is not red is the table's to say.
                Shown::Trouble => theme.problem_text_on_supervisor_bar,
                Shown::Working | Shown::None => theme.text_secondary,
            };
            if title.shown != Shown::None {
                parts.push(Part {
                    piece: Piece::Glyph { shown: title.shown, color: glyph_color(theme, title.shown), size: side::GLYPH, pulses: false },
                    side: Side::Trail,
                    gap: pane::BAR_GAP,
                });
            }
            // Nothing to say is nothing drawn: not an empty string handed on.
            if draws(&title.word) {
                parts.push(words(title.word.clone(), Style { weight: font::WEIGHT_EMPHASIS, ..body(word_ink) }, Side::Trail, side::STATUS_WORD_GAP));
            }
        }
        // The button, last: at the bar's right end, where the host finds it.
        let offered = title.and_then(|t| t.take_over.as_ref()).is_some_and(|t| t.offered && t.confirm.is_some());
        if offered {
            parts.push(words(tr(msg::TAKE_OVER), take_over_style(theme), Side::Trail, pane::BAR_GAP));
        }
        items.push(Item::Line { rect: bar, parts });
        // The terminal's own ground, for the moment before the terminal's
        // window is over it.
        let notice_h = notice.map_or(0.0, |n| n.h);
        if let Some(n) = notice {
            let (x, y, _) = notice_origin(width);
            items.extend(moved(n.items.clone(), x, y));
        }
        let terminal = terminal_rect_with(width, height, notice_h);
        items.push(Item::Fill { rect: terminal, color: theme.terminal_background });
        return Right { items, press: None, terminal: Some(terminal), take_over: offered.then_some(bar) };
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
    let mut press = None;
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
        // Somewhere else -- in its own tab by the person's choice, or in
        // another window: where it is, and what pressing anywhere on the
        // side does, the two lines centred in the side as macOS has them
        // (`ControlRoomElsewhere`, task 1758), with the frosted frame and
        // its shade under them (`elsewhere`). The group's name is not
        // repeated here: it is the row selected beside it.
        Detail_::TakenBack(_) | Detail_::Elsewhere(_) => {
            let (action, what) = match detail {
                Detail_::TakenBack(_) => (msg::SWITCH_HERE, Press::SwitchHere),
                _ => (msg::GO_THERE, Press::GoThere),
            };
            let sentence = if alone.is_some() { msg::TERMINAL_IN_ITS_OWN_TAB } else { msg::IN_ITS_OWN_TAB };
            let [first, second] = centred_lines(frame, line_h, side::ROW_GAP);
            items.push(Item::Text { rect: first, text: tr(sentence), style: body(theme.text_secondary), align: Align::Centre });
            // What a press does, in the colour a link has. It is not one:
            // the whole side takes the press.
            items.push(Item::Text { rect: second, text: tr(action), style: body(theme.attention_text), align: Align::Centre });
            press = Some((frame, what));
        }
        Detail_::Terminal(_) => {}
    }
    Right { items, press, terminal: None, take_over: None }
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
        let view = View { theme: look::theme(dark), scale, selection, lit: Lit::Selection, chip: at.chip(selection), lift: 0.0, pulsing, naming: None, fix_refusal: None };
        build(list, &at, &view, &same)
    }

    /// Task 1714: the right end of a quiet group's row names its project,
    /// or, when there is something to answer, says so with the attention
    /// glyph and a short word; a group with neither says nothing there.
    #[test]
    fn a_quiet_rows_right_end_says_what_is_to_answer_about_its_project() {
        let theme = look::theme(false);
        let trailing = |tie: &str, why: &str, name: Option<&str>| -> Vec<Part> {
            let mut l = list();
            let row = &mut l.quiet[0];
            row.project = Some(snapshot::ProjectTie { tie: tie.into(), why: why.into(), ask: false, opens_project: false, pages: None });
            row.project_name = name.map(str::to_string);
            let who = row.name().to_string();
            let items = scene(&l, None, false, 1.0, None);
            items
                .into_iter()
                .find_map(|i| match i {
                    Item::Line { parts, .. } if parts.iter().any(|p| matches!(&p.piece, Piece::Words { text, .. } if *text == who)) => Some(parts),
                    _ => None,
                })
                .expect("the row is drawn")
                .into_iter()
                .filter(|p| p.side == Side::Trail || p.side == Side::Squeezed)
                .collect()
        };
        let taken = trailing("undecided", "project_name_taken", None);
        assert_eq!(taken.len(), 2, "{taken:?}");
        assert!(matches!(taken[0].piece, Piece::Glyph { shown: Shown::NeedsYou, color, .. } if color == theme.attention), "{taken:?}");
        assert!(matches!(&taken[1].piece, Piece::Words { text, style, .. } if text == "Same-name project" && style.color == theme.attention_text), "{taken:?}");
        let bound = trailing("bound", "none", Some("web"));
        assert!(matches!(&bound[..], [Part { piece: Piece::Words { text, style, .. }, .. }] if text == "web" && style.color == theme.text_secondary), "{bound:?}");
        let quiet = trailing("undecided", "not_taken_up", None);
        assert!(quiet.is_empty(), "{quiet:?}");
    }

    /// Task 1714: a project's name is given the room last. What the group
    /// is doing keeps its width; the name is what is cut short, and on a
    /// row too narrow for it, left out -- the two never overlap.
    #[test]
    fn a_projects_name_gives_way_to_what_the_group_is_doing() {
        let mut l = list();
        let row = l.quiet.iter_mut().find(|r| !quiet_text(r).is_empty()).expect("a quiet row that says something");
        row.project = Some(snapshot::ProjectTie { tie: "bound".into(), why: "none".into(), ask: false, opens_project: false, pages: None });
        row.project_name = Some("a-long-project-name".into());
        let who = row.name().to_string();
        let said = quiet_text(row);
        let items = scene(&l, None, false, 1.0, None);
        let parts = items
            .into_iter()
            .find_map(|i| match i {
                Item::Line { parts, .. } if parts.iter().any(|p| matches!(&p.piece, Piece::Words { text, .. } if *text == who)) => Some(parts),
                _ => None,
            })
            .expect("the row is drawn");
        let side_of = |text: &str| parts.iter().find(|p| matches!(&p.piece, Piece::Words { text: t, .. } if t == text)).map(|p| p.side);
        assert_eq!(side_of(&said), Some(Side::Lead));
        assert_eq!(side_of("a-long-project-name"), Some(Side::Squeezed));
        // Laid out narrow: the name of the group 40, what it is doing 100,
        // the project 120, in 200.
        let widths: Vec<(Side, i32, i32)> = parts
            .iter()
            .map(|p| {
                let w = match &p.piece {
                    Piece::Words { text, .. } if *text == who => 40,
                    Piece::Words { text, .. } if *text == said => 100,
                    Piece::Words { .. } => 120,
                    _ => 10,
                };
                (p.side, 0, w)
            })
            .collect();
        let placed = place_line(0, 200, &widths);
        let at = |w: i32| widths.iter().position(|(_, _, x)| *x == w).and_then(|i| placed[i]).expect("placed");
        let doing = at(100);
        assert!(!doing.cut, "{doing:?}");
        let project = at(120);
        assert!(project.cut, "{project:?}");
        assert!(project.left >= doing.right, "{project:?} overlaps {doing:?}");
    }

    /// Task 1657: rows more than their room holds are drawn only in it --
    /// a clip round them, in pairs -- and a row scrolled wholly out is not
    /// drawn at all; a list that fits has no clip.
    #[test]
    fn rows_that_do_not_fit_are_clipped_to_their_room_and_scrolled() {
        let l = list();
        let fits = ListLayout::new(&l, 900.0);
        let view = |_: &ListLayout| View { theme: look::theme(false), scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: None, fix_refusal: None };
        let clips = |items: &[Item]| items.iter().filter(|i| matches!(i, Item::Clip { .. })).cloned().collect::<Vec<_>>();
        assert!(clips(&build(&l, &fits, &view(&fits), &same)).is_empty());

        let short = ListLayout::new(&l, 300.0);
        let max = crate::layout::scroll::max(short.content_height, short.viewport);
        assert!(max > 0.0);
        let at = short.clone().scrolled_to(max);
        let items = build(&l, &at, &view(&at), &same);
        let c = clips(&items);
        assert_eq!(c.len() % 2, 0, "{c:?}");
        for pair in c.chunks(2) {
            assert_eq!(pair[0], Item::Clip { rect: Some(at.viewport) });
            assert_eq!(pair[1], Item::Clip { rect: None });
        }
        assert!(!c.is_empty());
        // The first waiting row is scrolled out: its words are not drawn,
        // and the last quiet row's are.
        let words = texts(&items);
        let first = &l.waiting[0];
        let last = l.quiet.last().unwrap();
        assert!(!words.iter().any(|w| w.contains(first.name())), "{words:?}");
        assert!(words.iter().any(|w| w.contains(last.name())), "{words:?}");
    }

    /// What a line of parts says, and in which ink, in order.
    fn said(item: &Item) -> Vec<(String, Rgba)> {
        match item {
            Item::Line { parts, .. } => parts
                .iter()
                .filter_map(|p| match &p.piece {
                    Piece::Words { text, style } => Some((text.clone(), style.color)),
                    _ => None,
                })
                .collect(),
            _ => Vec::new(),
        }
    }

    /// Task 1755: the allowance block at the bottom of the list, in the
    /// macOS host's words and inks (`ControlRoomQuotaView`), inside the room
    /// the layout left for it.
    #[test]
    fn the_allowance_block_is_drawn_in_the_room_the_layout_left_it() {
        let l = list();
        let at = ListLayout::measured(&l, 900.0, &|t, _| crate::layout::nominal_lines(t));
        assert!(at.quota.h > 0.0, "the fixture has a block, so the layout leaves room");
        let theme = look::theme(false);
        let view = View { theme, scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: None, fix_refusal: None };
        let items = build_quota(&l, &at, &view, 0, &same);

        // Everything inside the block.
        for i in &items {
            let r = match i {
                Item::Fill { rect, .. } | Item::Round { rect, .. } | Item::Line { rect, .. } | Item::Text { rect, .. } => *rect,
                _ => continue,
            };
            assert!(r.y >= at.quota.y - 0.01 && r.y + r.h <= at.quota.y + at.quota.h + 0.01, "{i:?} is outside {:?}", at.quota);
        }
        let lines: Vec<Vec<(String, Rgba)>> = items.iter().filter(|i| matches!(i, Item::Line { .. })).map(said).collect();
        assert_eq!(lines.len(), 2, "the account opened out, then the one line");
        // Claude, close: which and how much in the problem ink, and when.
        assert_eq!(lines[0], [("Claude 5-hour 92% used".to_string(), theme.problem_text_on_row), ("back in 40 min".to_string(), theme.text)]);
        // The line: the label and the name a step back, the number in the
        // main ink because it is fresh.
        assert_eq!(
            lines[1],
            [("Allowance used".to_string(), theme.text_secondary), ("Codex ".to_string(), theme.text_secondary), ("20%".to_string(), theme.text)]
        );
        // The bar, 92% of the track, filled in the problem colour.
        let rounds: Vec<(Rect, Rgba, Option<Rgba>)> = items
            .iter()
            .filter_map(|i| match i {
                Item::Round { rect, color, edge, .. } => Some((*rect, *color, *edge)),
                _ => None,
            })
            .collect();
        assert_eq!(rounds.len(), 2);
        assert_eq!((rounds[0].1, rounds[1].1, rounds[1].2), (theme.line, theme.problem, None));
        assert!((rounds[1].0.w - rounds[0].0.w * 0.92).abs() < 0.01);

        // No block, nothing drawn.
        let mut none = list();
        none.quota = None;
        let at = ListLayout::measured(&none, 900.0, &|t, _| crate::layout::nominal_lines(t));
        assert_eq!(at.quota.h, 0.0);
        assert!(build_quota(&none, &at, &view, 0, &same).is_empty());
    }

    /// Task 1755: an account whose allowance is all gone leads with the
    /// trouble glyph; an old number's bar is an outline, not a fill.
    #[test]
    fn an_account_used_up_has_the_glyph_and_an_old_number_is_an_outline() {
        let mut l = list();
        let q = l.quota.as_mut().unwrap();
        q.alerts[0].level = crate::quota::Level::Out;
        q.alerts[0].stale = Some(crate::quota::Ago { unit: crate::quota::AgoUnit::Hours, n: 3 });
        let at = ListLayout::measured(&l, 900.0, &|t, _| crate::layout::nominal_lines(t));
        let theme = look::theme(true);
        let view = View { theme, scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: None, fix_refusal: None };
        let items = build_quota(&l, &at, &view, 0, &same);
        let first = items.iter().find_map(|i| match i {
            Item::Line { parts, .. } => Some(parts[0].piece.clone()),
            _ => None,
        });
        assert!(matches!(first, Some(Piece::Glyph { shown: Shown::Trouble, .. })), "{first:?}");
        let edges: Vec<Option<Rgba>> = items
            .iter()
            .filter_map(|i| match i {
                Item::Round { edge, .. } => Some(*edge),
                _ => None,
            })
            .collect();
        assert_eq!(edges, [None, Some(theme.text_tertiary)]);
    }

    /// Task 1661 (design v21 `03`, `06`, `07`): the line under a row says
    /// what it was given to say where the layout left room for it, a
    /// refusal and a failure in red; the archived section says how many and,
    /// open, each one's name and the day it was put away.
    #[test]
    fn the_lines_under_rows_and_the_archived_section_are_drawn_where_the_layout_says() {
        use crate::layout::Extras;
        let mut l = list();
        l.archived = vec![crate::snapshot::Archived { name: "old-app".into(), brief: String::new(), archived_ms: 1_792_136_400_000, record_dir: None, delete_cost: None }];
        let (w, q) = (l.waiting[0].id.clone(), l.quiet[0].id.clone());
        let extras = Extras { lines_under: vec![w.clone(), q.clone()], archived: vec!["old-app".into()], archived_open: true };
        let at = ListLayout::measured_with(&l, 900.0, &|t, _| crate::layout::nominal_lines(t), &extras);
        let theme = look::theme(true);
        let view = View { theme, scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: None, fix_refusal: None };
        let under = vec![
            (w.clone(), UnderLine::NotDelivered { why: "x".into(), retried: true, ask: crate::act::Ask::Report, on: None }),
            (q.clone(), UnderLine::Asked(crate::act::Ask::CloseIdle)),
        ];
        let items = build_extras(&l, &at, &view, &under, true, 8 * 3_600_000, &same);
        assert_eq!(items.first(), Some(&Item::Clip { rect: Some(at.viewport) }));
        assert_eq!(items.last(), Some(&Item::Clip { rect: None }));
        let text_at = |want: &str| {
            items.iter().find_map(|i| match i {
                Item::Text { rect, text, style, .. } if text.contains(want) => Some((*rect, style.color)),
                _ => None,
            })
        };
        let (r, c) = text_at("Not delivered yet: x").unwrap();
        assert_eq!(c, theme.problem_text_on_row);
        assert_eq!(r.y, at.line_rects.iter().find(|(id, _)| *id == w).unwrap().1.y);
        let (r, c) = text_at("Asked the supervisor to close idle workers").unwrap();
        assert_eq!(c, theme.text_secondary);
        assert_eq!(r.y, at.line_rects.iter().find(|(id, _)| *id == q).unwrap().1.y);
        assert!(text_at("Archived (1)").is_some());
        assert!(texts(&items).iter().any(|t| t == "archived 10/16"), "{:?}", texts(&items));
    }

    /// Task 1671 (the test machine, #1666): a refused name's red line is
    /// drawn just under the field, in the strip the field leaves clear --
    /// for a waiting card's name and a quiet row's. It used to be drawn in
    /// the field's last two pixels, where the edit control covered it.
    #[test]
    fn a_refused_names_red_line_is_under_the_field_not_beneath_it() {
        use crate::layout::Extras;
        let l = list();
        let (w, q) = (l.waiting[0].id.clone(), l.quiet[0].id.clone());
        let extras = Extras { lines_under: vec![w.clone(), q.clone()], archived: vec![], archived_open: false };
        let at = ListLayout::measured_with(&l, 900.0, &|t, _| crate::layout::nominal_lines(t), &extras);
        let theme = look::theme(false);
        let view = View { theme, scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: None, fix_refusal: None };
        for id in [&w, &q] {
            let under = vec![(id.clone(), UnderLine::Refused("taken".into()))];
            let items = build_extras(&l, &at, &view, &under, false, 0, &same);
            let field = rename_field(&l, &at, id).unwrap();
            let red: Vec<Rect> = items
                .iter()
                .filter_map(|i| match i {
                    Item::Fill { rect, color, .. } if *color == theme.problem_text_on_row => Some(*rect),
                    _ => None,
                })
                .collect();
            assert_eq!(red.len(), 1, "{id}: {red:?}");
            let line = red[0];
            assert_eq!((line.x, line.w), (field.x, field.w), "{id}");
            assert_eq!(line.y, field.y + field.h, "{id}: the line is just under the field");
            assert!(line.h > 0.0);
            let row = at.chip(Some(id)).unwrap();
            assert!(line.y + line.h <= row.y + row.h, "{id}: and inside its row");
        }
    }

    /// Task 1661 (design v21 `04-B`): the brief's panel says whose brief
    /// and who reads it, how long it is and whether it is saved; the box
    /// to type in fills what is between, and the buttons' band is at the
    /// bottom -- all inside the panel, and no cross anywhere.
    #[test]
    fn the_briefs_panel_has_a_box_between_its_title_and_its_buttons() {
        let rect = Rect { x: 900.0, y: 8.0, w: 420.0, h: 700.0 };
        let theme = look::theme(true);
        let n = build_note("web-app", rect, theme, 1.0, 234, true, 52.0, &same);
        let words = texts(&n.items);
        assert!(words.contains(&"web-app's brief".to_string()), "{words:?}");
        assert!(words.contains(&"234 characters, not saved".to_string()), "{words:?}");
        assert!(!words.iter().any(|w| w == "×" || w == "x"));
        let saved = build_note("web-app", rect, theme, 1.0, 234, false, 52.0, &same);
        assert!(texts(&saved.items).contains(&"234 characters".to_string()));
        assert_eq!(n.buttons.y + n.buttons.h, rect.y + rect.h);
        assert_eq!(n.buttons.h, 52.0);
        assert_eq!(n.field.y + n.field.h, n.buttons.y);
        assert!(n.field.h > 500.0);
        for i in &n.items {
            let r = rect_of(i);
            assert!(r.x >= rect.x && r.x + r.w <= rect.x + rect.w + 1e-9 && r.y >= rect.y && r.y + r.h <= rect.y + rect.h + 1e-9, "{i:?}");
        }
    }

    /// Task 1661 (design v21 `05`): pinned and muted are two marks after
    /// the name, pinned first, `ROW_ITEM_GAP` and then `MARK_GAP` apart,
    /// the size of a status glyph and in the quietest ink -- on a quiet row
    /// and on a waiting one alike; a row that is neither has none.
    #[test]
    fn pinned_and_muted_are_marks_after_the_name() {
        use crate::glyph::Mark;
        let theme = look::theme(true);
        let marks_after = |items: &[Item], name: &str| -> Option<Vec<(Mark, f64)>> {
            items.iter().find_map(|i| match i {
                Item::Line { parts, .. } => {
                    let at = parts.iter().position(|p| matches!(&p.piece, Piece::Words { text, .. } if text == name))?;
                    Some(
                        parts[at + 1..]
                            .iter()
                            .filter_map(|p| match &p.piece {
                                Piece::Mark { mark, color, size } => {
                                    assert_eq!(*color, theme.text_tertiary);
                                    assert_eq!(*size, side::GLYPH);
                                    assert_eq!(p.side, Side::Lead);
                                    Some((*mark, p.gap))
                                }
                                _ => None,
                            })
                            .collect(),
                    )
                }
                _ => None,
            })
        };
        let mut l = list();
        let (quiet, waiting) = (l.quiet[0].id.clone(), l.waiting[0].id.clone());
        let at = ListLayout::new(&l, 900.0);
        let view = View { theme, scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: None, fix_refusal: None };
        let plain = build(&l, &at, &view, &same);
        assert_eq!(marks_after(&plain, &quiet), Some(vec![]));
        assert_eq!(marks_after(&plain, &waiting), Some(vec![]));
        for r in l.quiet.iter_mut().chain(l.waiting.iter_mut()) {
            if r.id == quiet || r.id == waiting {
                r.pinned = true;
                r.muted = Some(crate::snapshot::Muted { until_ms: None });
            }
        }
        let both = build(&l, &at, &view, &same);
        let want = Some(vec![(Mark::Pinned, side::ROW_ITEM_GAP), (Mark::Muted, side::MARK_GAP)]);
        assert_eq!(marks_after(&both, &quiet), want);
        assert_eq!(marks_after(&both, &waiting), want);
        l.quiet[0].pinned = false;
        let muted_only = build(&l, &at, &view, &same);
        assert_eq!(marks_after(&muted_only, &quiet), Some(vec![(Mark::Muted, side::ROW_ITEM_GAP)]));
    }

    /// Task 1560: "Fix" on the card that reads "Failed", at the bottom of
    /// its row, where a press is the button's and not the row's.
    #[test]
    fn fix_is_drawn_on_the_failed_card_only_on_the_line_left_for_it_and_greys_once_pressed() {
        let mut l = list();
        let at = ListLayout::new(&l, 900.0);
        let row = at.chip(Some("docs-site")).unwrap();
        let hit = fix_hit(row);
        // Inside its row, under everything else the row says, on the last
        // line, and clear of the row's padding.
        assert!(hit.x >= row.x && hit.x + hit.w <= row.x + row.w - side::ROW_PADDING_X, "{hit:?} in {row:?}");
        assert!(hit.y >= row.y + row.h - side::ROW_PADDING_Y - side::FIX_LINE_HEIGHT - 1e-9);
        assert!(hit.y + hit.h <= row.y + row.h - side::ROW_PADDING_Y + 1e-9);
        assert_eq!(at.row_at(hit.x + 1.0, hit.y + 1.0), Some("docs-site"));
        let words_below = |items: &[Item], word: &str| -> Vec<Rect> {
            items.iter().filter_map(|i| match i {
                Item::Text { rect, text, .. } if text == word => Some(*rect),
                _ => None,
            }).collect()
        };
        let items = scene(&l, None, false, 1.0, None);
        assert_eq!(words_below(&items, msg::FIX), [hit], "one button, on docs-site's card");
        assert!(words_below(&items, msg::FIX_SENT).is_empty());

        // Pressed: greyed, in its own words, in the same place.
        for r in l.waiting.iter_mut().filter(|r| r.id == "docs-site") {
            r.fix = Fix::Sent;
        }
        let items = scene(&l, None, false, 1.0, None);
        assert!(words_below(&items, msg::FIX).is_empty());
        assert_eq!(words_below(&items, msg::FIX_SENT), [hit]);
        let grey = items.iter().find_map(|i| match i {
            Item::Text { text, style, .. } if text == msg::FIX_SENT => Some(style.color),
            _ => None,
        });
        assert_eq!(grey, Some(look::theme(false).text_tertiary));
    }

    #[test]
    fn why_a_fix_was_refused_is_said_beside_its_own_button_and_nowhere_else() {
        let l = list();
        let at = ListLayout::new(&l, 900.0);
        let said = |refusal: Option<(&str, &str)>| -> Vec<Rect> {
            let view = View { theme: look::theme(false), scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: None, fix_refusal: refusal };
            build(&l, &at, &view, &same).into_iter().filter_map(|i| match i {
                Item::Text { rect, text, .. } if text == "why" => Some(rect),
                _ => None,
            }).collect()
        };
        let hit = fix_hit(at.chip(Some("docs-site")).unwrap());
        let beside = said(Some(("docs-site", "why")));
        assert_eq!(beside.len(), 1);
        assert_eq!(beside[0].y, hit.y);
        assert_eq!(beside[0].x, hit.x + hit.w + side::ROW_ITEM_GAP);
        // About another row: not on this one, and that one has no button.
        assert!(said(Some(("billing", "why"))).is_empty());
        assert!(said(None).is_empty());
    }

    /// Task 1511: the first sweep of old records waiting for the person.
    #[test]
    fn nothing_waiting_means_no_notice_and_no_room() {
        let l = list();
        assert_eq!(l.retention_waiting_bytes, None, "the fixture says null");
        let at = ListLayout::new(&l, 900.0);
        assert_eq!(at.notice, None);
        let items = scene(&l, None, false, 1.0, None);
        assert!(!items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == msg::OK)));
    }

    #[test]
    fn a_waiting_sweep_takes_room_under_the_header_and_says_how_much() {
        let plain = list();
        let mut l = list();
        l.retention_waiting_bytes = Some(419 * 1024 * 1024);
        let (before, at) = (ListLayout::new(&plain, 900.0), ListLayout::new(&l, 900.0));
        let n = at.notice.expect("room for the notice");
        assert_eq!(n.y, at.header.y + at.header.h);
        assert_eq!(n.h, crate::layout::notice_height());
        // Every row moves down by the notice and one gap, and no further.
        let first = plain.waiting[0].id.clone();
        assert_eq!(at.chip(Some(&first)).unwrap().y, before.chip(Some(&first)).unwrap().y + n.h + side::ROW_GAP);
        let items = scene(&l, None, false, 1.0, None);
        let said = items.iter().find_map(|i| match i {
            Item::Block { text, .. } if text.contains("419.0 MB") => Some(text.clone()),
            _ => None,
        });
        assert_eq!(said.as_deref(), Some("The new retention settings will clear 419.0 MB of old records"));
        let ok = retention_ok_hit(n);
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, rect, .. } if text == msg::OK && *rect == ok)));
        assert!(ok.y + ok.h <= n.y + n.h, "the OK is inside the notice");
    }

    /// The same numbers as `polter_settings_shell::logs::size_text`'s test.
    #[test]
    fn sizes_read_the_way_the_settings_page_writes_them() {
        assert_eq!(size_text(512), "512 B");
        assert_eq!(size_text(2048), "2 KB");
        assert_eq!(size_text(5 * 1024 * 1024 + 200 * 1024), "5.2 MB");
        assert_eq!(size_text(3 * 1024 * 1024 * 1024), "3.00 GB");
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
                Item::Fill { .. } | Item::Round { .. } | Item::Clip { .. } => {}
            }
        }
        out
    }

    fn rect_of(item: &Item) -> Rect {
        match item {
            Item::Fill { rect, .. } | Item::Round { rect, .. } | Item::Text { rect, .. } | Item::Line { rect, .. } | Item::Block { rect, .. } => *rect,
            Item::Clip { rect } => rect.unwrap_or(Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 }),
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
                Item::Fill { .. } | Item::Round { .. } | Item::Clip { .. } => {}
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
                    Item::Text { .. } | Item::Line { .. } | Item::Block { .. } | Item::Clip { .. } => {}
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
                Piece::Held { .. } | Piece::Mark { .. } | Piece::Badge { .. } | Piece::Bar { .. } => false,
            }),
            Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => false,
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
                Item::Fill { .. } | Item::Round { .. } | Item::Clip { .. } => {}
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
                    Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Line { .. } | Item::Clip { .. } => None,
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
            // A card with "Fix" ends in its button, centred on its line.
            let bottom = inside.iter().map(|i| rect_of(i)).map(|r| r.y + r.h).fold(0.0, f64::max);
            let end = if row.fix == Fix::None { 0.0 } else { (side::FIX_LINE_HEIGHT - crate::layout::NOTICE_BUTTON_H) / 2.0 };
            assert!((bottom - (rect.y + rect.h - side::ROW_PADDING_Y - end)).abs() < 1e-9, "{}: {bottom} in {rect:?}", row.id);
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
        use crate::snapshot::{Header, HeaderNumber, HeaderOf};
        l.waiting_header = Some(Header { count: 41, of: HeaderOf::Groups, number: HeaderNumber::Other });
        l.quiet_header = Some(Header { count: 17, of: HeaderOf::Groups, number: HeaderNumber::Other });
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"41 groups waiting for you".to_string()), "{said:?}");
        assert!(said.contains(&"17 groups need nothing from you".to_string()), "{said:?}");
        // With terminals in no group under them, neither says "group".
        l.waiting_header = Some(Header { count: 41, of: HeaderOf::Rows, number: HeaderNumber::Other });
        l.quiet_header = Some(Header { count: 1, of: HeaderOf::Rows, number: HeaderNumber::One });
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"41 waiting for you".to_string()), "{said:?}");
        assert!(said.contains(&"1 needs nothing from you".to_string()), "{said:?}");
        // From a core that writes no heading, the groups' counts as before.
        l.waiting_header = None;
        l.quiet_header = None;
        l.waiting_count = 2;
        l.quiet_count = 5;
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"2 groups waiting for you".to_string()), "{said:?}");
        assert!(said.contains(&"5 groups need nothing from you".to_string()), "{said:?}");
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
        // Nothing round over it but the "Fix" buttons on the cards that
        // have one (task 1560).
        assert!(items[chip + 1..].iter().all(|i| !matches!(i, Item::Round { radius, .. } if *radius != FIX_BUTTON_RADIUS)));
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
            let view = View { theme: look::theme(false), scale: 1.0, selection: Some(&first), lit: Lit::Selection, chip: Some(chip), lift, pulsing: None, naming: None, fix_refusal: None };
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
            let view = View { theme: look::theme(true), scale: 1.0, selection: Some(&second), lit, chip: at.chip(Some(&second)), lift: 1.0, pulsing: None, naming: None, fix_refusal: None };
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
            let view = View { theme: look::theme(true), scale: 1.0, selection: Some(&second), lit, chip: at.chip(Some(&second)), lift: 1.0, pulsing: None, naming: None, fix_refusal: None };
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

    /// Task 1671 (the test machine, #1666, 1635-W5): on a bar too short for
    /// all of it, the "started by hand" note gives way -- the name and the
    /// role word beside it stay whole, as do the status and the button. It
    /// used to keep its width and push left over the role word.
    #[test]
    fn the_started_by_hand_note_gives_way_before_the_supervisors_name() {
        use crate::lend::Loan;
        let l = list();
        let row = l.rows().find(|r| r.id == "docs-site").unwrap();
        let loan = Loan { group: row.id.clone(), terminal: row.steward.clone().unwrap() };
        let right = build_right(&Detail_::Terminal(loan), Some(row), 600.0, 700.0, look::theme(false), 1.0, false, &same);
        let Some(Item::Line { parts, .. }) = right.items.iter().find(|i| matches!(i, Item::Line { .. })) else { panic!("no bar") };
        let text = |p: &Part| match &p.piece {
            Piece::Words { text, .. } => text.clone(),
            _ => String::new(),
        };
        let note = parts.iter().position(|p| text(p) == "Started by hand: no status").expect("docs-site's bar has the note");
        // Seven pixels a character, a glyph 14: what a host would measure.
        let measured: Vec<(Side, i32, i32)> = parts
            .iter()
            .map(|p| (p.side, p.gap as i32, match &p.piece { Piece::Words { text, .. } => 7 * text.chars().count() as i32, _ => 14 }))
            .collect();
        let whole: i32 = measured.iter().map(|(_, g, w)| g + w).sum();
        let note_w = measured[note].2;
        // Half the note too short, and short by all of it and its gap.
        for short in [note_w / 2, note_w + measured[note].1] {
            let placed = place_line(0, whole - short, &measured);
            for (i, p) in parts.iter().enumerate() {
                if i == note {
                    assert!(placed[i].is_none_or(|at| at.cut), "the note gives way by {short}: {:?}", placed[i]);
                } else {
                    let at = placed[i].unwrap_or_else(|| panic!("{:?} has no room, {short} short", text(p)));
                    assert!(!at.cut, "{:?} is cut, {short} short", text(p));
                }
            }
        }
    }

    #[test]
    fn a_supervisor_started_by_hand_is_said_to_be_on_its_frame_in_the_persons_language() {
        use crate::lend::Loan;
        let l = list();
        let frame_of = |name: &str, tr: &dyn Fn(&str) -> String| {
            let row = l.rows().find(|r| r.id == name).expect("the fixture has that group");
            let loan = Loan { group: row.id.clone(), terminal: row.steward.clone().unwrap() };
            texts(&build_right(&Detail_::Terminal(loan), Some(row), 600.0, 700.0, look::theme(false), 1.0, false, tr).items)
        };
        let english = |s: &str| s.to_string();
        assert!(frame_of("docs-site", &english).contains(&"Started by hand: no status".to_string()));
        assert!(frame_of("design-system", &english).contains(&"Unknown CLI: no status".to_string()));
        // Said, not copied: the words go through the catalogue.
        let chinese = |s: &str| if s == "Started by hand: no status" { "手动启动，没接上状态".to_string() } else { s.to_string() };
        assert!(frame_of("docs-site", &chinese).contains(&"手动启动，没接上状态".to_string()));
        // Task 1635: docs-site's is offered for taking over -- the button is
        // the bar's last part on the right, and `take_over` is that bar --
        // and design-system's (no adapter knows it) is not.
        let right_of = |name: &str| {
            let row = l.rows().find(|r| r.id == name).unwrap();
            let loan = Loan { group: row.id.clone(), terminal: row.steward.clone().unwrap() };
            build_right(&Detail_::Terminal(loan), Some(row), 600.0, 700.0, look::theme(false), 1.0, false, &english)
        };
        let offered = right_of("docs-site");
        let bar = offered.take_over.expect("docs-site offers the take-over");
        let Some(Item::Line { rect, parts }) = offered.items.iter().find(|i| matches!(i, Item::Line { .. })) else { panic!("no bar") };
        assert_eq!(*rect, bar);
        let last = parts.iter().rev().find(|p| p.side == Side::Trail).unwrap();
        assert!(matches!(&last.piece, Piece::Words { text, style } if text == msg::TAKE_OVER && *style == take_over_style(look::theme(false))));
        assert!(right_of("design-system").take_over.is_none());
        assert_eq!(
            crate::act::encode(&crate::act::Act::TakeOver { group: "docs-site" }).unwrap(),
            r#"{"act":"take_over","group":"docs-site"}"#
        );
        // Every other supervisor's frame says neither.
        for row in l.rows().filter(|r| r.steward.is_some() && r.id != "docs-site" && r.id != "design-system") {
            let t = frame_of(&row.id, &english);
            assert!(!t.iter().any(|w| w.contains("no status")), "{}: {t:?}", row.id);
        }
    }

    /// Task 1714: what is said about the group's project sits between the
    /// supervisor's title bar and its terminal, and the terminal moves down
    /// by exactly its height -- the number the host places the window with.
    #[test]
    fn the_band_about_the_project_pushes_the_terminal_down_by_its_height() {
        use crate::lend::Loan;
        use crate::project_notice::{band, Notice};
        let l = list();
        let with = l.rows().find(|r| r.steward.is_some()).expect("the fixture has a group with a supervisor");
        let loan = Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() };
        let theme = look::theme(false);
        let (_, _, w) = notice_origin(600.0);
        let b = band(Notice::Hint { text: "Saved.", undo: Some("Undo") }, w, theme, &|s: &str| 8.0 * s.chars().count() as f64);
        let plain = build_right(&Detail_::Terminal(loan.clone()), Some(with), 600.0, 700.0, theme, 1.0, false, &same);
        let said = build_right_with(&Detail_::Terminal(loan), Some(with), 600.0, 700.0, theme, 1.0, false, &same, Some(&b));
        let (t0, t1) = (plain.terminal.unwrap(), said.terminal.unwrap());
        assert_eq!(t1, terminal_rect_with(600.0, 700.0, b.h));
        assert_eq!((t1.y - t0.y, t0.h - t1.h), (b.h, b.h));
        // Its words are drawn, under the bar.
        let words = texts(&said.items);
        assert!(words.contains(&"Saved.".to_string()), "{words:?}");
    }

    #[test]
    fn the_right_side_says_which_nothing_it_is_and_offers_the_tab_only_for_another_window() {
        use crate::lend::Loan;
        let l = list();
        let with = l.rows().find(|r| r.steward.is_some()).expect("the fixture has a group with a supervisor");
        let loan = Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() };

        let r = right(&Detail_::Elsewhere(loan.clone()), Some(with), false);
        assert!(r.terminal.is_none());
        // Two lines, centred, as macOS has them (task 1758): not the name.
        assert!(!texts(&r.items).contains(&with.id));
        assert!(texts(&r.items).contains(&msg::IN_ITS_OWN_TAB.to_string()));
        let lines: Vec<&Rect> = r.items.iter().filter_map(|i| match i { Item::Text { rect, align: Align::Centre, .. } => Some(rect), _ => None }).collect();
        assert_eq!(lines.len(), 2);
        let (above, below) = (lines[0].y, 700.0 - (lines[1].y + lines[1].h));
        assert!((above - below).abs() < 0.001, "centred up and down: {above} above, {below} below");
        assert!(texts(&r.items).contains(&msg::GO_THERE.to_string()));
        // The whole side is what is pressed, not a button inside it: the
        // press area is the frame the side is drawn in, and nothing round
        // is drawn but that frame.
        let frame = match &r.items[0] {
            Item::Round { rect, .. } => *rect,
            other => panic!("the side's own frame comes first: {other:?}"),
        };
        assert_eq!(r.press, Some((frame, Press::GoThere)));
        assert_eq!(r.items.iter().filter(|i| matches!(i, Item::Round { .. })).count(), 1);
        // Taken back to its own tab in this window: the whole side brings it
        // here again, and says so (task 1758, as macOS does).
        let r = right(&Detail_::TakenBack(loan.clone()), Some(with), false);
        assert_eq!(r.press, Some((frame, Press::SwitchHere)));
        assert!(texts(&r.items).contains(&msg::SWITCH_HERE.to_string()));
        assert!(!texts(&r.items).contains(&msg::GO_THERE.to_string()));

        let r = right(&Detail_::NoSupervisor { group: with.id.clone() }, Some(with), false);
        assert!(r.press.is_none() && r.terminal.is_none());
        assert!(texts(&r.items).contains(&msg::NO_SUPERVISOR.to_string()));

        let r = right(&Detail_::SupervisorGone { group: with.id.clone() }, Some(with), false);
        assert!(r.press.is_none() && r.terminal.is_none());
        assert!(texts(&r.items).contains(&lend_msg::GONE.to_string()));

        let r = right(&Detail_::TakenBack(loan), Some(with), false);
        assert!(r.terminal.is_none());
        assert!(texts(&r.items).contains(&msg::IN_ITS_OWN_TAB.to_string()));

        let r = right(&Detail_::NothingSelected, None, false);
        assert!(r.press.is_none() && r.terminal.is_none());
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
        assert!(r.press.is_none());
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
    fn a_yielding_part_goes_before_the_first_leading_part_is_cut_and_not_before() {
        use Side::*;
        // A supervisor's title (task 1692): badge 58, name 120, glyph 14,
        // status word 40; 8 between each, 5 before the word.
        let parts = [(Lead, 0, 58), (Lead, 8, 120), (Trail, 8, 14), (Yield, 5, 40)];
        // Room for it all: the word is at the right end, the glyph left of it.
        let wide = place_line(0, 400, &parts);
        assert_eq!(wide[3], Some(Placed { left: 360, right: 400, cut: false }));
        assert_eq!(wide[2], Some(Placed { left: 341, right: 355, cut: false }));
        assert_eq!(wide[1], Some(Placed { left: 66, right: 186, cut: false }));
        // Narrower: the name is cut first, and the word stays...
        let cut = place_line(0, 150, &parts);
        assert_eq!(cut[3], Some(Placed { left: 110, right: 150, cut: false }));
        assert_eq!(cut[1], Some(Placed { left: 66, right: 83, cut: true }));
        // ... down to where the badge would be cut with it: just there it
        // still is, and a pixel narrower the word goes and the glyph takes
        // the end.
        let just = place_line(0, 58 + 8 + 14 + 5 + 40, &parts);
        assert_eq!(just[0], Some(Placed { left: 0, right: 58, cut: false }));
        assert!(just[3].is_some());
        let gone = place_line(0, 58 + 8 + 14 + 5 + 40 - 1, &parts);
        assert_eq!(gone[3], None);
        assert_eq!(gone[2], Some(Placed { left: 110, right: 124, cut: false }));
        assert_eq!(gone[0], Some(Placed { left: 0, right: 58, cut: false }));
        // A line with nothing that yields is placed as it always was.
        let plain = [(Lead, 0, 58), (Lead, 8, 120), (Trail, 8, 14), (Trail, 5, 40)];
        for width in [60, 100, 125, 150, 400] {
            let as_yield = place_line(0, width, &parts);
            let as_trail = place_line(0, width, &plain);
            if as_yield[3].is_some() {
                assert_eq!(as_yield, as_trail, "{width}");
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
                    Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => None,
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
        let view = View { theme: look::theme(false), scale: 1.0, selection: None, lit: Lit::Selection, chip: None, lift: 0.0, pulsing: None, naming: Some(Naming { refusal }), fix_refusal: None };
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
        row.start = Some(crate::snapshot::SupervisorStart { state, can_start, failed, terminal: None, asking: false, clis_read: true, role: Some("polter-supervisor".into()), cwd: "/Users/me/work".into(), last: None, hookless: None });
        // A group with no project: the fixture's first quiet group is bound
        // to one, and its start would open it ("Open", task 1756).
        row.project = None;
        row
    }

    fn roles() -> Vec<crate::snapshot::SupervisorRole> {
        vec![
            crate::snapshot::SupervisorRole { key: "polter-supervisor".into(), name: "Polter Supervisor".into(), clis: Vec::new(), held_back: Vec::new() },
            crate::snapshot::SupervisorRole { key: "reviewer".into(), name: "Reviewer".into(), clis: Vec::new(), held_back: Vec::new() },
        ]
    }

    #[test]
    fn which_sentence_a_group_with_no_supervisor_gets_is_the_cores_word() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let says = |s, f| no_supervisor_words(start_row(s, true, f).start.as_ref());
        assert_eq!(says(S::Absent, F::None), msg::NO_SUPERVISOR);
        assert_eq!(says(S::Starting, F::None), msg::STARTING);
        assert_eq!(says(S::Failed, F::TerminalNeverOpened), msg::NEVER_OPENED);
        assert_eq!(says(S::Failed, F::ProjectNeverOpened), msg::PROJECT_NEVER_OPENED);
        assert_ne!(msg::PROJECT_NEVER_OPENED, msg::NEVER_OPENED);
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
    fn a_group_whose_start_opens_its_project_says_open_on_the_same_button() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let all = roles();
        let view = StartView { roles: &all, choose_role: false, home: "/Users/me", ..Default::default() };
        let theme = look::theme(false);
        let tie = |opens_project| crate::snapshot::ProjectTie { tie: "bound".into(), why: "none".into(), ask: false, opens_project, pages: None };
        let mut row = start_row(S::Absent, true, F::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let plain = build_start(&detail, Some(&row), 600.0, theme, &view, &same);
        row.project = Some(tie(true));
        let opens = build_start(&detail, Some(&row), 600.0, theme, &view, &same);
        let said = all_text(&opens.items);
        assert!(said.contains(&msg::OPEN), "{said:?}");
        assert!(!said.contains(&msg::START_SUPERVISOR), "{said:?}");
        // The same button, pressed the same; one line higher, for the
        // directory is not asked (as on macOS).
        assert_eq!(opens.start.is_some(), plain.start.is_some());
        let (b, p) = (opens.button.unwrap(), plain.button.unwrap());
        assert_eq!((b.x, b.w, b.h), (p.x, p.w, p.h));
        assert_eq!(b.y, p.y - side::HEADER_HEIGHT);
        // A project whose start is a directory, and no project at all.
        row.project = Some(tie(false));
        assert!(all_text(&build_start(&detail, Some(&row), 600.0, theme, &view, &same).items).contains(&msg::START_SUPERVISOR));
        assert_eq!(start_title(None), msg::START_SUPERVISOR);
    }

    /// Task 1756, the macOS start page's two other things: a start that opens
    /// the group's project does not ask where to start, and the button has
    /// the sentence under it that macOS has (`ProjectLinkRules.startNote`).
    #[test]
    fn a_start_that_opens_the_project_asks_no_directory_and_says_what_comes_back() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let all = roles();
        let view = StartView { roles: &all, choose_role: false, home: "/Users/me", ..Default::default() };
        let theme = look::theme(false);
        let tie = |t: &str, why: &str, opens_project, pages| crate::snapshot::ProjectTie { tie: t.into(), why: why.into(), ask: false, opens_project, pages };
        let mut row = start_row(S::Absent, true, F::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let drawn = |row: &Row| build_start(&detail, Some(row), 600.0, theme, &view, &same);

        row.project = Some(tie("bound", "none", true, Some(3)));
        let opens = drawn(&row);
        assert_eq!(opens.directory, None);
        let said = all_text(&opens.items);
        assert!(!said.contains(&msg::DIRECTORY), "{said:?}");
        let note = list::fill(msg::ALL_PAGES_BACK, "3");
        assert!(said.contains(&note.as_str()), "{said:?}");
        // Under the button, not over it.
        let b = opens.button.unwrap();
        let under = opens.items.iter().find_map(|i| match i {
            Item::Block { rect, text, .. } if *text == note => Some(*rect),
            _ => None,
        });
        assert!(under.is_some_and(|r| r.y >= b.y + b.h), "{under:?} {b:?}");
        // The count not known: the sentence without it.
        row.project = Some(tie("bound", "none", true, None));
        assert!(all_text(&drawn(&row).items).contains(&msg::EVERY_PAGE_BACK));

        // No project yet, and one is offered when the supervisor takes the
        // group up: the directory is asked, and the sentence says so.
        row.project = Some(tie("undecided", "not_taken_up", false, None));
        let fresh = drawn(&row);
        assert!(fresh.directory.is_some());
        assert!(all_text(&fresh.items).contains(&msg::NO_PROJECT_YET));
        // Projects not known yet, declined, or no project said at all: no
        // sentence.
        for project in [Some(tie("undecided", "projects_unknown", false, None)), Some(tie("declined", "none", false, None)), None] {
            row.project = project.clone();
            let shown = drawn(&row);
            assert!(shown.directory.is_some(), "{project:?}");
            let said = all_text(&shown.items);
            assert!(![msg::NO_PROJECT_YET, msg::EVERY_PAGE_BACK].iter().any(|m| said.contains(m)), "{project:?}: {said:?}");
        }
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

    /// Task 1746: a supervisor being started whose CLI asks the person a
    /// question in its tab -- Antigravity's trust box -- is said to be
    /// waiting for them, with a button that goes to that tab and nothing
    /// that starts another.
    #[test]
    fn a_start_waiting_on_a_question_says_so_and_offers_its_tab() {
        use crate::snapshot::{StartFailure as F, SupervisorState as S};
        let all = roles();
        let view = StartView { roles: &all, choose_role: false, home: "/Users/me", ..Default::default() };
        let theme = look::theme(false);
        let mut row = start_row(S::Starting, false, F::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        // Starting, not asking: the plain sentence, and nothing to press.
        assert_eq!(no_supervisor_words(row.start.as_ref()), msg::STARTING);
        assert_eq!(build_start(&detail, Some(&row), 600.0, theme, &view, &same), Start::default());

        if let Some(s) = row.start.as_mut() {
            s.asking = true;
            s.terminal = Some("0x00000000000000a9".into());
        }
        assert_eq!(no_supervisor_words(row.start.as_ref()), msg::ASKING);
        let shown = build_start(&detail, Some(&row), 600.0, theme, &view, &same);
        let (terminal, _) = shown.go_to_tab.clone().expect("a button to its tab");
        assert_eq!(terminal, "0x00000000000000a9");
        assert!(all_text(&shown.items).contains(&msg::GO_TO_ITS_TAB));
        assert!(shown.start.is_none() && shown.directory.is_none());
        // And the right side draws the sentence.
        let right = build_right(&detail, Some(&row), 600.0, 600.0, theme, 1.0, false, &same);
        assert!(all_text(&right.items).contains(&msg::ASKING));
        // Asking with no terminal named: nothing to go to.
        if let Some(s) = row.start.as_mut() {
            s.terminal = None;
        }
        assert_eq!(build_start(&detail, Some(&row), 600.0, theme, &view, &same).go_to_tab, None);
    }

    /// A role is shown under the name the core sent, the official
    /// supervisor included. On a name no catalogue has, and with a `tr` that
    /// would change anything it was handed -- the fixture's own name is a
    /// msgid, and `same` would pass a looked-up name as readily as a plain one.
    #[test]
    fn a_role_is_shown_under_the_cores_name_whatever_its_key() {
        let shout = |t: &str| format!("TR<{t}>");
        let boss = crate::snapshot::SupervisorRole { key: "polter-supervisor".into(), name: "Polter Supervisor".into(), clis: Vec::new(), held_back: Vec::new() };
        assert_eq!(role_name(&boss, &shout), "Polter Supervisor");
        let other = crate::snapshot::SupervisorRole { key: "reviewer".into(), name: "Reviewer".into(), clis: Vec::new(), held_back: Vec::new() };
        assert_eq!(role_name(&other, &shout), "Reviewer");
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
        // The core's role until the person picks another, under the name the core gave it.
        assert!(all_text(&two.items).contains(&"Polter Supervisor"));
        let picked = build_start(&detail, Some(&row), 600.0, theme, &StartView { roles: &all, choose_role: true, role: Some("reviewer"), home: "", ..Default::default() }, &same);
        assert!(all_text(&picked.items).contains(&"Reviewer") && !all_text(&picked.items).contains(&"Polter Supervisor"));
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

    // ---- the last supervisor, and which session a start uses (task 1489)

    fn last_row(heard: Option<u64>, last_cli: Option<&str>, cwd_is_last: bool, can: bool, why: crate::snapshot::ResumeWhy) -> Row {
        use crate::snapshot::{StartFailure as F, SupervisorLast, SupervisorState as S};
        let mut row = start_row(S::Absent, true, F::None);
        row.start.as_mut().unwrap().last = Some(SupervisorLast {
            cli: Some("claude-code".into()),
            role: Some("polter-supervisor".into()),
            last_cli: last_cli.map(str::to_string),
            heard_ms: heard,
            can_resume: can,
            why,
            cwd_is_last,
            cli_label: Some("Claude Code".into()),
            last_cli_label: last_cli.filter(|c| !c.is_empty()).map(|_| "Claude Code".to_string()),
            by_cli: Vec::new(),
        });
        row
    }

    #[test]
    fn the_choice_of_session_is_offered_only_when_the_core_says_the_last_can_be_gone_on_with() {
        use crate::act::Session;
        use crate::snapshot::ResumeWhy as W;
        let can = last_row(Some(1), Some("claude-code"), true, true, W::None);
        let cannot = last_row(Some(1), Some("claude-code"), true, false, W::SessionInUse);
        assert!(offers_session(can.start.as_ref()));
        assert!(!offers_session(cannot.start.as_ref()));
        // A core that says nothing of a last supervisor, and no start at all.
        let old = start_row(crate::snapshot::SupervisorState::Absent, true, crate::snapshot::StartFailure::None);
        assert!(!offers_session(old.start.as_ref()));
        assert!(!offers_session(None));

        let theme = look::theme(false);
        let view = StartView { home: "/Users/me", ..Default::default() };
        let detail = Detail_::NoSupervisor { group: can.id.clone() };
        let drawn = build_start(&detail, Some(&can), 600.0, theme, &view, &same);
        // Two lines, the last session first, one under the other, each as
        // high as a quiet row and starting where the directory's line does.
        assert_eq!(drawn.sessions.iter().map(|(s, _)| *s).collect::<Vec<_>>(), [Session::Last, Session::New]);
        let (first, second) = (drawn.sessions[0].1, drawn.sessions[1].1);
        let directory = drawn.directory.unwrap();
        assert_eq!((first.x, first.h, second.h), (directory.x, side::QUIET_ROW_HEIGHT, side::QUIET_ROW_HEIGHT));
        assert_eq!(second.y, first.y + first.h);
        assert!(first.y >= directory.y + directory.h);
        // The button is under them, a row's gap on.
        assert_eq!(drawn.start.unwrap().y, second.y + second.h + side::ROW_GAP);
        let said = all_text(&drawn.items);
        assert!(said.contains(&msg::GO_ON) && said.contains(&msg::NEW_SESSION), "{said:?}");
        // Their words start a mark and a gap in from the line's start.
        let words_at = directory.x + side::GLYPH + side::ROW_ITEM_GAP;
        for item in &drawn.items {
            if let Item::Text { rect, text, .. } = item {
                if text == msg::GO_ON || text == msg::NEW_SESSION {
                    assert_eq!(rect.x, words_at, "{text}");
                }
            }
        }

        // When it cannot (task 1741): "Didn't find the last session" over a
        // new one, and the reason on hover, not on a line of its own.
        let detail = Detail_::NoSupervisor { group: cannot.id.clone() };
        let drawn = build_start(&detail, Some(&cannot), 600.0, theme, &view, &same);
        assert_eq!(drawn.sessions.iter().map(|(s, _)| *s).collect::<Vec<_>>(), [crate::act::Session::New]);
        let said = all_text(&drawn.items);
        assert!(said.contains(&msg::DIDNT_FIND) && said.contains(&msg::NEW_SESSION), "{said:?}");
        assert!(!said.contains(&msg::WHY_SESSION_IN_USE) && !said.contains(&msg::GO_ON), "{said:?}");
        assert_eq!(drawn.tip.as_ref().map(|(_, t)| t.as_str()), Some(msg::WHY_SESSION_IN_USE));

        // One or the other, never both: whether it can is the core's `can`,
        // and a core that says it can while naming a reason is believed
        // about the first.
        let odd = last_row(Some(1), Some("claude-code"), true, true, W::SessionInUse);
        let drawn = build_start(&Detail_::NoSupervisor { group: odd.id.clone() }, Some(&odd), 600.0, theme, &view, &same);
        assert_eq!(drawn.sessions.len(), 2);
        assert!(!all_text(&drawn.items).contains(&msg::WHY_SESSION_IN_USE));
    }

    #[test]
    fn the_mark_that_is_filled_is_the_session_in_use() {
        use crate::act::Session;
        use crate::snapshot::ResumeWhy as W;
        let row = last_row(Some(1), Some("claude-code"), true, true, W::None);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let theme = look::theme(false);
        // Which line's mark is in the attention colour: the y of the one
        // round thing filled with it.
        let filled_at = |session| {
            let view = StartView { home: "", session, ..Default::default() };
            let drawn = build_start(&detail, Some(&row), 600.0, theme, &view, &same);
            let marks: Vec<f64> = drawn
                .items
                .iter()
                .filter_map(|item| match item {
                    Item::Round { rect, color, .. } if *color == theme.attention_text && rect.w == side::GLYPH => Some(rect.y),
                    _ => None,
                })
                .collect();
            assert_eq!(marks.len(), 1, "one mark is filled: {marks:?}");
            let line = drawn.sessions.iter().find(|(_, r)| marks[0] >= r.y && marks[0] < r.y + r.h).map(|(s, _)| *s);
            line.unwrap()
        };
        assert_eq!(filled_at(None), Session::Last);
        assert_eq!(filled_at(Some(Session::Last)), Session::Last);
        assert_eq!(filled_at(Some(Session::New)), Session::New);
    }

    #[test]
    fn the_last_supervisor_is_said_and_its_directory_only_when_it_is_not_the_one_already_shown() {
        use crate::snapshot::ResumeWhy as W;
        let said = |row: &Row, picked: Option<&str>| last_supervisor_words(row.start.as_ref(), picked, "/Users/me", &same);
        let whole = last_row(Some(1), Some("claude-code"), true, true, W::None);
        // Nothing picked: the start uses the last supervisor's directory,
        // which the line above shows. Said again it was the same path
        // twice; so only the CLI, by the core's name for it.
        assert_eq!(said(&whole, None).as_deref(), Some("The last supervisor used Claude Code."));
        // Picked, and the same one: still not said.
        assert_eq!(said(&whole, Some("/Users/me/work")).as_deref(), Some("The last supervisor used Claude Code."));
        // Picked elsewhere: now it tells them something, shown as
        // directories are everywhere else.
        assert_eq!(said(&whole, Some("/srv/other")).as_deref(), Some("The last supervisor worked in ~/work, using Claude Code."));
        // The directory the core names is the last supervisor's only when
        // it says so (`cwd_from: last_supervisor`).
        assert_eq!(said(&last_row(Some(1), Some("claude-code"), false, true, W::None), Some("/srv/other")).as_deref(), Some("The last supervisor used Claude Code."));
        // A CLI nobody wrote down is not said, and neither is an empty one.
        assert_eq!(said(&last_row(Some(1), None, true, true, W::None), Some("/srv/other")).as_deref(), Some("The last supervisor worked in ~/work."));
        assert_eq!(said(&last_row(Some(1), Some(""), true, true, W::None), Some("/srv/other")).as_deref(), Some("The last supervisor worked in ~/work."));
        // Never recorded, or nothing of it left to say: nothing.
        assert_eq!(said(&last_row(None, Some("claude-code"), true, false, W::NoRecord), Some("/srv/other")), None);
        assert_eq!(said(&last_row(Some(1), None, true, false, W::NoSession), None), None);
        assert_eq!(said(&last_row(Some(1), None, false, false, W::NoSession), Some("/srv/other")), None);
        let old = start_row(crate::snapshot::SupervisorState::Absent, true, crate::snapshot::StartFailure::None);
        assert_eq!(said(&old, Some("/srv/other")), None);
        assert_eq!(last_supervisor_words(None, None, "/Users/me", &same), None);
        // No directory at all is not "where the tab starts".
        let mut nowhere = last_row(Some(1), Some("codex"), true, true, W::None);
        nowhere.start.as_mut().unwrap().cwd = String::new();
        nowhere.start.as_mut().unwrap().last.as_mut().unwrap().last_cli_label = None;
        assert_eq!(said(&nowhere, Some("/srv/other")).as_deref(), Some("The last supervisor used codex."));

        // The CLI: the core's name, and the key when the core has none.
        assert_eq!(cli_name(Some("claude-code"), Some("Claude Code")).as_deref(), Some("Claude Code"));
        assert_eq!(cli_name(Some("claude-code"), None).as_deref(), Some("claude-code"));
        assert_eq!(cli_name(Some("claude-code"), Some("")).as_deref(), Some("claude-code"));
        assert_eq!(cli_name(None, Some("Claude Code")), None);
        assert_eq!(cli_name(Some(""), Some("Claude Code")), None);

        // And it is drawn, under the directory's line and above the
        // button, for what the person has picked.
        let row = last_row(Some(1), Some("claude-code"), true, false, W::NoRecord);
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let drawn_for = |cwd: Option<&'static str>| build_start(&detail, Some(&row), 600.0, look::theme(false), &StartView { cwd, home: "/Users/me", ..Default::default() }, &same);
        let sentence = |drawn: &Start| {
            drawn.items.iter().find_map(|item| match item {
                Item::Block { rect, text, .. } if text.starts_with("The last supervisor") => Some((*rect, text.clone())),
                _ => None,
            })
        };
        let drawn = drawn_for(None);
        let (at, text) = sentence(&drawn).expect("the sentence is drawn");
        assert_eq!(text, "The last supervisor used Claude Code.");
        let directory = drawn.directory.unwrap();
        assert_eq!(at.x, directory.x);
        assert!(at.y >= directory.y + directory.h && at.y + at.h <= drawn.start.unwrap().y);
        assert_eq!(sentence(&drawn_for(Some("/srv/other"))).unwrap().1, "The last supervisor worked in ~/work, using Claude Code.");
    }

    #[test]
    fn every_reason_for_not_going_on_has_its_own_sentence_and_the_two_that_need_none_have_none() {
        use crate::snapshot::ResumeWhy as W;
        assert_eq!(resume_note(W::None), None);
        assert_eq!(resume_note(W::NoRecord), None);
        let spoken: Vec<&str> = W::ALL.into_iter().filter_map(resume_note).collect();
        assert_eq!(spoken.len(), 6);
        for (i, a) in spoken.iter().enumerate() {
            assert!(!a.is_empty());
            for b in &spoken[i + 1..] {
                assert_ne!(a, b);
            }
        }
        // The one that changes by itself does not say a new session will
        // be started: that is about to stop being true.
        assert!(msg::WHY_CLIS_UNREAD.ends_with('…'));
        assert!(!msg::WHY_SESSION_IN_USE.ends_with('…'));
    }

    #[test]
    fn a_group_with_no_record_of_a_supervisor_is_drawn_as_it_was() {
        use crate::snapshot::{ResumeWhy as W, StartFailure as F, SupervisorState as S};
        let theme = look::theme(false);
        let view = StartView { home: "", ..Default::default() };
        let before = start_row(S::Absent, true, F::None);
        let detail = Detail_::NoSupervisor { group: before.id.clone() };
        let was = build_start(&detail, Some(&before), 600.0, theme, &view, &same);
        // The core says there is no record: nothing more is said, nothing
        // is offered, and every rectangle is where it was.
        let silent = last_row(None, None, false, false, W::NoRecord);
        let now = build_start(&detail, Some(&silent), 600.0, theme, &view, &same);
        assert_eq!(now, was);
        assert!(now.sessions.is_empty());
    }

    // ---- a terminal in no group: its row, and the right side (task 1471)

    const LONE: &str = "terminal:0x00000000000000c1";

    /// The list with a row for the terminal in no group, which nothing
    /// draws since task 1485: what such a row would say is still held.
    fn lone_list() -> List {
        List::from_snapshot_with(&snapshot::decode(FIXTURE).unwrap(), true)
    }

    fn lone_row(pane: crate::snapshot::Pane) -> Row {
        let mut row = lone_list().row(LONE).unwrap().clone();
        row.alone.as_mut().unwrap().pane = pane;
        row
    }

    #[test]
    fn a_lone_terminals_row_is_drawn_under_its_title_never_its_id() {
        let l = lone_list();
        let said = texts(&scene(&l, None, false, 1.0, None));
        assert!(said.contains(&"zsh — ~/work".to_string()), "{said:?}");
        assert!(!said.iter().any(|t| t.contains("terminal:0x")), "{said:?}");
        // It waits like any other row: its status word and what it waits on.
        assert!(said.contains(&"git push".to_string()), "{said:?}");
        // Read out, it is its title too, and says nobody is beside it.
        let spoken = spoken(l.row(LONE).unwrap(), &same);
        assert!(spoken.starts_with("zsh — ~/work, Awaiting approval"), "{spoken}");
        // It is selected by its row's identity, and lit like any other.
        let at = ListLayout::new(&l, 900.0);
        assert!(at.chip(Some(LONE)).is_some());
        let lit = scene(&l, Some(LONE), false, 1.0, None);
        let weights: Vec<f64> = lit
            .iter()
            .filter_map(|i| match i {
                Item::Line { parts, .. } => parts.iter().find_map(|p| match &p.piece {
                    Piece::Words { text, style } if text == "zsh — ~/work" => Some(style.weight),
                    Piece::Words { .. } | Piece::Glyph { .. } | Piece::Held { .. } | Piece::Mark { .. } | Piece::Badge { .. } | Piece::Bar { .. } => None,
                }),
                Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => None,
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
                                Piece::Glyph { .. } | Piece::Held { .. } | Piece::Mark { .. } | Piece::Badge { .. } | Piece::Bar { .. } => None,
                            })
                            .collect(),
                    ),
                    Item::Fill { .. } | Item::Round { .. } | Item::Text { .. } | Item::Block { .. } | Item::Clip { .. } => None,
                })
                .unwrap()
        };
        // An ordinary agent: its title and its state, and no word between.
        assert_eq!(bar(&lone_row(Pane::Plain)), ["zsh — ~/work", "Awaiting approval"]);
        // A worker somebody minds says so; a supervisor with no group too.
        assert_eq!(bar(&lone_row(Pane::Worker)), ["zsh — ~/work", "Worker", "Awaiting approval"]);
        assert_eq!(bar(&lone_row(Pane::Supervisor)), ["zsh — ~/work", "Supervisor", "Awaiting approval"]);
        // A group's supervisor: that terminal's own title and "Supervisor".
        let l = lone_list();
        let group = l.row("web-app").unwrap();
        assert_eq!(bar(group)[..2], ["web-app".to_string(), "Supervisor".to_string()]);
        // The terminal's title, not the group's name, where they differ.
        let mut renamed = l.row("billing").unwrap().clone();
        renamed.title.as_mut().unwrap().name = "claude — ~/billing".to_string();
        assert_eq!(bar(&renamed), ["claude — ~/billing", "Supervisor", "Awaiting input"]);
        // The state is the supervisor's own and not the row's: in `mobile`
        // a worker waits for approval while the supervisor has nothing to
        // say, and the bar over the supervisor says nothing.
        let mobile = l.row("mobile").unwrap();
        assert_eq!(mobile.word, "Awaiting approval");
        assert_eq!(bar(mobile), ["mobile", "Supervisor"]);
        // A supervisor the core lists no terminal for: the group's name is
        // all there is to write.
        let mut unlisted = mobile.clone();
        unlisted.title = None;
        unlisted.id = "mobile-group".to_string();
        assert_eq!(bar(&unlisted), ["mobile-group", "Supervisor"]);
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
            // Under its title, not its row's identity -- except where it is
            // somewhere else, which says only where and what a press does,
            // centred, as macOS does (task 1758); nothing about a supervisor
            // either way.
            match detail {
                Detail_::TakenBack(_) | Detail_::Elsewhere(_) => assert_eq!(texts[0], sentence, "{detail:?}"),
                _ => assert_eq!(texts[0], "zsh — ~/work", "{detail:?}"),
            }
            assert!(!texts.iter().any(|t| t.contains("terminal:0x") || t.contains("supervisor")), "{detail:?}: {texts:?}");
        }
        // The same for a group is said of its supervisor, under the group's name.
        let l = lone_list();
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

    // ---- which agent CLI a start uses (#1678, role-cli-v1 01a/01b/01c)

    fn rc(key: &str, label: &str) -> crate::snapshot::RoleCli {
        crate::snapshot::RoleCli { key: key.into(), label: Some(label.into()) }
    }

    /// The official supervisor set up for both, both plugins on; the last
    /// supervisor was Claude Code's, and only Claude Code can go on with
    /// its session (the core's answer for each, `resume_by_cli`).
    fn duo() -> (Row, Vec<crate::snapshot::SupervisorRole>) {
        use crate::snapshot::{CliResume, ResumeWhy as W, SupervisorRole};
        let mut row = last_row(Some(1), Some("claude-code"), true, true, W::None);
        row.start.as_mut().unwrap().last.as_mut().unwrap().by_cli = vec![
            CliResume { cli: "claude-code".into(), can: true, why: W::None },
            CliResume { cli: "codex".into(), can: false, why: W::CliDiffers },
        ];
        let roles = vec![
            SupervisorRole { key: "polter-supervisor".into(), name: "Polter Supervisor".into(), clis: vec![rc("claude-code", "Claude Code"), rc("codex", "Codex")], held_back: Vec::new() },
            SupervisorRole { key: "night-lead".into(), name: "Night Lead".into(), clis: vec![rc("codex", "Codex"), rc("claude-code", "Claude Code")], held_back: Vec::new() },
            SupervisorRole { key: "solo".into(), name: "Solo".into(), clis: vec![rc("codex", "Codex")], held_back: Vec::new() },
        ];
        (row, roles)
    }

    #[test]
    fn two_clis_are_a_choice_and_another_than_the_last_greys_going_on() {
        use crate::act::Session;
        use crate::snapshot::ResumeWhy as W;
        let (row, roles) = duo();
        let start = row.start.as_ref().unwrap();
        // 01a: the core's CLI is on, and going on can be picked.
        let a = cli_choice(start, &roles, None, None);
        assert!(a.shown);
        assert_eq!((a.picked.as_deref(), a.resume, a.why), (Some("claude-code"), Resume::Live, W::None));
        assert_eq!(session_for(&a, None), Some(Session::Last));
        assert_eq!(resume_said(&a, start.last.as_ref()), None);
        // 01b: Codex picked -- going on greyed, nothing said of a session,
        // and why in the two CLIs' names.
        let b = cli_choice(start, &roles, None, Some("codex"));
        assert_eq!((b.picked.as_deref(), b.resume, b.why), (Some("codex"), Resume::Greyed, W::CliDiffers));
        assert_eq!(session_for(&b, Some(Session::Last)), None);
        assert_eq!(resume_said(&b, start.last.as_ref()), Some((msg::LAST_SESSION_WAS, vec!["Claude Code".to_string(), "Codex".to_string()])));
        // A pick the role does not list is not kept.
        assert_eq!(cli_choice(start, &roles, None, Some("other-cli")).picked.as_deref(), Some("claude-code"));
    }

    #[test]
    fn one_cli_is_no_choice_and_another_role_starts_where_the_last_one_was() {
        use crate::snapshot::ResumeWhy as W;
        let (row, roles) = duo();
        let start = row.start.as_ref().unwrap();
        // 01c: a role with one CLI draws no line, and Codex cannot go on
        // with Claude Code's session: not found (task 1741), the core's
        // reason on hover.
        let solo = cli_choice(start, &roles, Some("solo"), None);
        assert!(!solo.shown);
        assert_eq!((solo.picked.as_deref(), solo.resume, solo.why), (Some("codex"), Resume::Missing, W::CliDiffers));
        assert_eq!(resume_said(&solo, start.last.as_ref()), None);
        assert_eq!(resume_tooltip(&solo, start.last.as_ref()), Some((msg::WHY_CLI_DIFFERS, Vec::new())));
        // Another role that lists the last supervisor's CLI starts in it,
        // though it is not that role's first.
        assert_eq!(cli_choice(start, &roles, Some("night-lead"), None).picked.as_deref(), Some("claude-code"));
        // Nobody can go on: hidden, whichever is picked.
        let mut nobody = row.clone();
        nobody.start.as_mut().unwrap().last.as_mut().unwrap().by_cli[0].can = false;
        nobody.start.as_mut().unwrap().last.as_mut().unwrap().by_cli[0].why = W::SessionInUse;
        let n = cli_choice(nobody.start.as_ref().unwrap(), &roles, None, None);
        assert_eq!((n.resume, n.why), (Resume::Missing, W::SessionInUse));
        // A core from before the list of CLIs: the CLI it names, its one
        // answer, no line.
        let (old, _) = duo();
        let mut old = old;
        old.start.as_mut().unwrap().last.as_mut().unwrap().by_cli.clear();
        let o = cli_choice(old.start.as_ref().unwrap(), &[], None, None);
        assert_eq!((o.shown, o.picked.as_deref(), o.resume), (false, Some("claude-code"), Resume::Live));
    }

    /// Task 1741: while the last session is looked for, the right side says
    /// so where "Go on" will be, the CLIs' names are bars and never keys,
    /// "Start" waits until a new session is picked, and nothing under the
    /// sessions moves when the look ends -- found or not.
    #[test]
    fn task_1741_the_look_for_the_last_session_moves_nothing_and_waits_for_a_new_one() {
        use crate::act::Session;
        use crate::snapshot::ResumeWhy as W;
        let (row, roles) = duo();
        let theme = look::theme(false);
        let same = |s: &str| s.to_string();
        let mut looking = row.clone();
        {
            let st = looking.start.as_mut().unwrap();
            st.clis_read = false;
            let l = st.last.as_mut().unwrap();
            l.can_resume = false;
            l.why = W::ClisUnread;
            for b in l.by_cli.iter_mut() {
                b.can = false;
                b.why = W::ClisUnread;
            }
        }
        let mut lost = row.clone();
        {
            let l = lost.start.as_mut().unwrap().last.as_mut().unwrap();
            l.can_resume = false;
            l.why = W::SessionInUse;
            for b in l.by_cli.iter_mut() {
                b.can = false;
                b.why = W::SessionInUse;
            }
        }
        let built = |r: &Row, session: Option<Session>| {
            let view = StartView { roles: &roles, session, home: "", ..Default::default() };
            build_start(&Detail_::NoSupervisor { group: r.id.clone() }, Some(r), 600.0, theme, &view, &same)
        };
        let found = built(&row, None);
        let wait = built(&looking, None);
        let none = built(&lost, None);

        // Nothing under the sessions moves when the look ends.
        let found_at = found.button.unwrap().y;
        let wait_at = wait.button.unwrap().y;
        let none_at = none.button.unwrap().y;
        assert_eq!(wait_at, found_at);
        assert_eq!(none_at, found_at);

        // Looking: said, with the spinner, and "Start" waits.
        let wait_text = all_text(&wait.items);
        assert!(wait_text.contains(&msg::LOOKING), "{wait_text:?}");
        assert!(moves(&wait.items));
        assert_eq!(wait.start, None);
        // The names are bars: the sentence's and both rings'; no key, no
        // empty text handed to a host.
        let bars = wait.items.iter().filter(|i| matches!(i, Item::Line { parts, .. } if parts.iter().any(|p| matches!(p.piece, Piece::Bar { .. })))).count();
        assert_eq!(bars, 3);
        assert!(!wait_text.iter().any(|t| t.contains("claude-code") || t.contains("Claude Code") || t.is_empty()), "{wait_text:?}");

        // A new session picked: pressable, and that is what is said.
        let picked = built(&looking, Some(Session::New));
        assert_eq!(picked.start, picked.button);
        let c = cli_choice(looking.start.as_ref().unwrap(), &roles, None, None);
        assert_eq!(session_for(&c, Some(Session::New)), Some(Session::New));
        assert_eq!(session_for(&c, None), None);

        // Found, or not to be had: pressable at once.
        assert_eq!(found.start, found.button);
        assert_eq!(none.start, none.button);
        let none_text = all_text(&none.items);
        assert!(none_text.contains(&msg::DIDNT_FIND) && !none_text.contains(&msg::LOOKING), "{none_text:?}");
    }

    /// Task 1741, as the macOS test machine had it: the role is set up for
    /// Claude Code and Antigravity, and only Antigravity is installed. While
    /// the adapters are read both are offered, as two bars; the read holds
    /// Claude Code back, and one CLI is no line. Its room stays, so the
    /// button does not move -- nor when Claude Code is installed after.
    #[test]
    fn task_1741_a_cli_the_read_takes_away_leaves_its_room_and_the_button_stays() {
        use crate::snapshot::{CliResume, HeldBack, HeldWhy, ResumeWhy as W, SupervisorRole};
        let theme = look::theme(false);
        let same = |s: &str| s.to_string();
        let mut row = last_row(Some(1), Some("agy"), true, true, W::None);
        row.start.as_mut().unwrap().last.as_mut().unwrap().cli = Some("agy".into());
        row.start.as_mut().unwrap().last.as_mut().unwrap().by_cli = vec![CliResume { cli: "agy".into(), can: true, why: W::None }];
        let mut looking = row.clone();
        {
            let st = looking.start.as_mut().unwrap();
            st.clis_read = false;
            let l = st.last.as_mut().unwrap();
            l.can_resume = false;
            l.why = W::ClisUnread;
            l.by_cli = vec![CliResume { cli: "claude-code".into(), can: false, why: W::ClisUnread }, CliResume { cli: "agy".into(), can: false, why: W::ClisUnread }];
        }
        let role = |clis: Vec<crate::snapshot::RoleCli>, held_back: Vec<HeldBack>| vec![SupervisorRole { key: "polter-supervisor".into(), name: "Polter Supervisor".into(), clis, held_back }];
        let both = role(vec![rc("claude-code", "Claude Code"), rc("agy", "Antigravity")], Vec::new());
        let one = role(vec![rc("agy", "Antigravity")], vec![HeldBack { key: "claude-code".into(), label: Some("Claude Code".into()), why: HeldWhy::NotInstalled }]);
        let built = |r: &Row, roles: &[SupervisorRole]| {
            let view = StartView { roles, home: "", ..Default::default() };
            build_start(&Detail_::NoSupervisor { group: r.id.clone() }, Some(r), 600.0, theme, &view, &same)
        };
        let wait = built(&looking, &both);
        let found = built(&row, &one);
        let installed = built(&row, &both);
        // The case itself: two bars while looking, no line once read.
        assert_eq!(wait.clis.len(), 2);
        assert!(found.clis.is_empty());
        assert_eq!(installed.clis.len(), 2);

        let wait_at = wait.button.unwrap();
        let found_at = found.button.unwrap();
        let installed_at = installed.button.unwrap();
        assert_eq!(found_at, wait_at);
        assert_eq!(installed_at, found_at);
        // The sessions stay too.
        assert_eq!(found.sessions.last().unwrap().1, wait.sessions.last().unwrap().1);
    }

    #[test]
    fn the_cli_line_is_drawn_for_two_and_the_greyed_session_cannot_be_pressed() {
        use crate::act::Session;
        let (row, roles) = duo();
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let theme = look::theme(false);
        let drawn = |cli: Option<&'static str>, role: Option<&'static str>| {
            build_start(&detail, Some(&row), 600.0, theme, &StartView { roles: &roles, role, cli, home: "", ..Default::default() }, &same)
        };
        let a = drawn(None, None);
        assert_eq!(a.clis.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(), ["claude-code", "codex"]);
        assert!(all_text(&a.items).contains(&msg::AGENT_CLI));
        assert_eq!(a.sessions.iter().map(|(s, _)| *s).collect::<Vec<_>>(), [Session::Last, Session::New]);
        // The CLIs' rings and the sessions' stand on one left edge.
        assert!(a.clis.iter().chain(a.sessions.iter().map(|(_, r)| r).map(|r| ("", *r)).collect::<Vec<_>>().iter().map(|(k, r)| (k.to_string(), *r)).collect::<Vec<_>>().iter()).all(|(_, r)| r.x == a.clis[0].1.x));
        // 01b: the same lines, so nothing jumps; going on is not pressable,
        // and the reason is drawn.
        let b = drawn(Some("codex"), None);
        assert_eq!(b.clis.len(), 2);
        assert_eq!(b.sessions.iter().map(|(s, _)| *s).collect::<Vec<_>>(), [Session::New]);
        assert_eq!(b.sessions[0].1, a.sessions[1].1, "new session stays where it was");
        assert!(all_text(&b.items).contains(&"The last session was Claude Code's; Codex can't go on with it."), "{:?}", all_text(&b.items));
        // 01c: one CLI, no line, and nothing about CLIs drawn.
        let c = drawn(None, Some("solo"));
        assert!(c.clis.is_empty());
        assert!(!all_text(&c.items).contains(&msg::AGENT_CLI));
        // Not found (task 1741): only a new session, on.
        assert_eq!(c.sessions.iter().map(|(s, _)| *s).collect::<Vec<_>>(), [Session::New]);
    }
}
