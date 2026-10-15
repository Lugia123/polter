//! A pane that holds several terminals, one in front (control-room.md,
//! 12.6.2; task 1583): what its strip of tabs says, where everything in it
//! is, what a point on it is, and what it draws -- for the Windows host.
//!
//! The macOS host's `PaneStackRules`, `PaneStack`, `PolterPaneTabRules` and
//! `PaneStackStripView`, the parts that are decisions rather than drawing.
//! **Where each tab is and how wide is not here**: that is
//! [`crate::stackstrip`], the same arithmetic as the macOS host's and held
//! to it by `tools/control-room-hosts-agree.py`; this calls it.
//!
//! Lengths are points from the frame's own top left, as [`crate::pane`]'s.

use crate::layout::Rect;
use crate::look::{font, pane as look_pane, radius, side, stack_tab as t, Rgba, Theme};
use crate::pane::{self, Place, Title, Wears};
use crate::scene::{self, Face, Item, Part, Piece, Side, Style};
use crate::snapshot::{BarShown, Shown, Terminal};
use crate::stackstrip::{self, Layout};

/// The English the strip and its menu say; a host translates them. The
/// macOS host's msgids (task 1582).
pub mod msg {
    use crate::n_;

    /// The plus at the end of the tabs.
    pub const ADD: &str = n_("Add a terminal to this pane");
    /// A tab's close button, and the first row of a tab's menu.
    pub const CLOSE_TERMINAL: &str = n_("Close Terminal");
    pub const CLOSE_OTHERS: &str = n_("Close Others");
    pub const CLOSE_RIGHT: &str = n_("Close to the Right");
    pub const CLOSE_LEFT: &str = n_("Close to the Left");
}

/// One terminal of the stack, as much of it as its tab shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    /// The terminal's name, as its frame's title would say it.
    pub name: String,
    /// The glyph its frame's title draws at the right end.
    pub shown: BarShown,
    /// Which frame it wears when it is the one in front.
    pub wears: Wears,
    /// The word after the name that says what it is; none for an ordinary
    /// terminal. English; a host translates it.
    pub role: Option<&'static str>,
}

/// What a pane holding a stack draws.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneStack {
    /// In the order of the tabs. Never empty.
    pub members: Vec<Member>,
    /// Which member is in front.
    pub current: usize,
    /// The members that have a glyph to show, the most pressing first: the
    /// core's order (`pulses`), kept to this stack.
    pub urgent: Vec<usize>,
}

impl PaneStack {
    /// The member in front; the first when `current` is out of range.
    pub fn showing(&self) -> Option<&Member> {
        self.members.get(self.current).or_else(|| self.members.first())
    }
}

/// What a pane holding `members` -- each the core's id for it when it has
/// one, and what its own pane calls it -- showing `shown`, draws. Every
/// member's name, glyph and frame are the core's words for that terminal
/// ([`pane::drawn`], asked as for a pane that is not alone: in a stack every
/// member has a name to show). `pulses` is the core's order of who is
/// waiting. macOS's `PaneStackRules.stack`.
pub fn stack(members: &[(Option<&str>, &str)], shown: usize, terminals: Option<&[Terminal]>, pulses: &[&str]) -> PaneStack {
    let place = Place { enabled: true, quick_terminal: false, alone: false };
    let drawn: Vec<Member> = members
        .iter()
        .map(|(terminal, own)| match pane::drawn(*terminal, own, place, terminals) {
            Some(d) => Member { name: d.title.name, shown: d.title.shown, wears: d.wears, role: pane::role_word(d.wears) },
            None => Member { name: own.to_string(), shown: BarShown::None, wears: Wears::Plain, role: None },
        })
        .collect();
    let urgent = pulses.iter().filter_map(|w| members.iter().position(|(t, _)| *t == Some(*w))).collect();
    PaneStack { current: if shown < drawn.len() { shown } else { 0 }, members: drawn, urgent }
}

/// The frame a pane holding `stack` wears: the member in front's
/// (`Choices.frameFollowsShown`). **Never nothing**: a stack with no strip
/// is terminals nobody can reach, so it is framed even alone in its tab and
/// with `poltergeist-pane-frames` off.
pub fn wears(stack: &PaneStack) -> Wears {
    stack.showing().map_or(Wears::Plain, |m| m.wears)
}

/// The title a stack hands its frame for the status at the strip's right
/// end: the member in front's name, glyph and word.
pub fn status_title(stack: &PaneStack, word: &str) -> Title {
    match stack.showing() {
        Some(m) => Title { name: m.name.clone(), shown: m.shown, word: word.to_string() },
        None => Title { name: String::new(), shown: BarShown::None, word: String::new() },
    }
}

// ---------------------------------------------------------------- rules

/// Whether a close button shows: on the tab the pointer is over, and always
/// on the one in front. macOS's `PolterPaneTabRules.closeShows`.
pub fn close_shows(hovering: bool, current: bool) -> bool {
    hovering || current
}

/// The three ways of closing the tabs of a stack around one of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Closing {
    Others,
    Right,
    Left,
}

impl Closing {
    pub const ALL: [Closing; 3] = [Closing::Others, Closing::Right, Closing::Left];

    pub fn label(self) -> &'static str {
        match self {
            Closing::Others => msg::CLOSE_OTHERS,
            Closing::Right => msg::CLOSE_RIGHT,
            Closing::Left => msg::CLOSE_LEFT,
        }
    }
}

/// The members `which` closes around the tab at `index` of a stack of
/// `count`, in the stack's order. Empty when there is none to close --
/// which is when the menu greys the row.
pub fn closing(which: Closing, index: usize, count: usize) -> Vec<usize> {
    if index >= count {
        return Vec::new();
    }
    match which {
        Closing::Others => (0..count).filter(|i| *i != index).collect(),
        Closing::Right => (index + 1..count).collect(),
        Closing::Left => (0..index).collect(),
    }
}

/// Whether closing `members` of a stack of `count` takes the pane with it:
/// every member goes.
pub fn closes_pane(members: &[usize], count: usize) -> bool {
    count > 0 && (0..count).all(|i| members.contains(&i))
}

/// How far a wheel moves the tabs sideways, in points: a sideways wheel as
/// it is, and one that only turns up and down turned sideways. Windows says
/// a wheel in 120ths of a notch; a notch is `line` points (macOS's 16).
/// Positive is away from the person, which moves the tabs back towards
/// their start, as macOS's `PolterPaneTabRules.scroll`.
pub fn scroll(delta_x: i32, delta_y: i32, line: f64) -> f64 {
    let d = if delta_x.abs() >= delta_y.abs() { delta_x } else { delta_y };
    -(d as f64 / 120.0) * line
}

/// Where a tab dragged along its own strip ends up, from where it was and
/// the insertion it was let go at -- which counts the tab itself, while
/// where it ends up does not. None when it would not move.
pub fn reorder_to(from: usize, index: usize) -> Option<usize> {
    let to = if index > from { index - 1 } else { index };
    (to != from).then_some(to)
}

/// The line one wheel notch scrolls, in points.
pub const WHEEL_LINE: f64 = 16.0;

// ------------------------------------------------------------- geometry

/// How far a frame keeps what is inside from its left and right edges: a
/// supervisor's border, nothing for the other two (`PaneFrameChrome.room`).
fn side_room(wears: Wears) -> f64 {
    match wears {
        Wears::Supervisor => look_pane::SUPERVISOR_BORDER,
        Wears::Worker | Wears::Plain => 0.0,
    }
}

/// Where everything in one stack's strip is, at one scroll, in points from
/// the frame's top left.
#[derive(Debug, Clone, PartialEq)]
pub struct Geometry {
    /// The strip: across the frame between the content's edges, at its top.
    pub strip: Rect,
    pub layout: Layout,
    /// How far the tabs are scrolled, already kept to what they can be.
    pub offset: f64,
}

/// How wide a tab's body wants to be, from the widths a host measured of
/// its name (at the heavier of its two weights) and of the word for what it
/// is: the paddings, a glyph's place and the close button's, whether or not
/// either is showing (macOS's `wanted`).
pub fn wanted(name: f64, role: Option<f64>) -> f64 {
    let mut w = name;
    if let Some(r) = role {
        w += look_pane::NAME_ROLE_GAP + r;
    }
    2.0 * t::PADDING_X + w + t::GAP + side::GLYPH + t::CLOSE_GAP + t::CLOSE_BUTTON
}

/// How wide the status at the right end is: the glyph, the gap, the word;
/// 0 when there is nothing to say.
pub fn status_width(title: &Title, word: f64) -> f64 {
    if title.shown == BarShown::None && !scene::draws(&title.word) {
        return 0.0;
    }
    side::GLYPH + side::STATUS_WORD_GAP + if scene::draws(&title.word) { word } else { 0.0 }
}

/// Where the strip of a frame `w` points wide is, and its tabs scrolled on
/// from `offset` by `stackstrip::settle`: `changed` -- the tab in front, the
/// number of tabs or the strip's width changed -- and `wheeled` -- the
/// person scrolled them since -- decide whether the tab in front is brought
/// into view (task 1599: it is, unless they scrolled).
pub fn geometry(wears: Wears, w: f64, wants: &[f64], current: usize, status: f64, offset: f64, changed: bool, wheeled: bool) -> Geometry {
    let room = side_room(wears);
    let strip = Rect { x: room, y: 0.0, w: (w - 2.0 * room).max(0.0), h: t::STRIP_HEIGHT };
    let layout = stackstrip::layout(wants, current, strip.w, status);
    let offset = stackstrip::settle(&layout, current, offset, changed, wheeled);
    Geometry { strip, layout, offset }
}

impl Geometry {
    /// Where among the tabs a terminal let go at `x` (points from the
    /// frame's left) goes in: how many tabs have their middle left of it,
    /// scrolled (macOS's `insertion(atRowX:)`, task 1582).
    pub fn insertion(&self, x: f64) -> usize {
        self.layout.tabs.iter().filter(|tab| self.strip.x + tab.x - self.offset + tab.width / 2.0 < x).count()
    }

    /// Where the caret for an insertion at `index` stands: the left edge of
    /// the tab that will follow it, or the end of the last.
    pub fn caret_x(&self, index: usize) -> f64 {
        match self.layout.tabs.get(index) {
            Some(tab) => self.strip.x + tab.x - self.offset,
            None => self.strip.x + t::INSET + self.layout.content - self.offset,
        }
    }

    /// Scrolled by `by` points, kept to what the tabs can scroll.
    pub fn scrolled(&self, by: f64) -> f64 {
        (self.offset + by).clamp(0.0, self.layout.max_offset())
    }
}

impl Geometry {
    /// The top of the tabs: they stand on the strip's bottom.
    fn tab_top(&self) -> f64 {
        self.strip.y + t::STRIP_HEIGHT - t::HEIGHT
    }

    /// Where the tab of `member` is, scrolled.
    pub fn tab_rect(&self, member: usize) -> Option<Rect> {
        let tab = self.layout.tabs.iter().find(|tab| tab.member == member)?;
        Some(Rect { x: self.strip.x + tab.x - self.offset, y: self.tab_top(), w: tab.width, h: t::HEIGHT })
    }

    /// The window the tabs are seen through: the room the layout gives
    /// them, and a foot's width more on each side for the tab in front.
    pub fn row(&self) -> Rect {
        let foot = t::REVERSE_ARC_RADIUS;
        Rect { x: self.strip.x + t::INSET - foot, y: self.strip.y, w: self.layout.viewport + 2.0 * foot, h: t::STRIP_HEIGHT }
    }

    /// The close button of the tab of `member`: at the tab's right end,
    /// inside its padding, centred up and down.
    pub fn close_rect(&self, member: usize) -> Option<Rect> {
        let r = self.tab_rect(member)?;
        Some(Rect {
            x: r.x + r.w - t::PADDING_X - t::CLOSE_BUTTON,
            y: r.y + (r.h - t::CLOSE_BUTTON) / 2.0,
            w: t::CLOSE_BUTTON,
            h: t::CLOSE_BUTTON,
        })
    }

    /// The plus.
    pub fn add_rect(&self) -> Rect {
        Rect { x: self.strip.x + self.layout.add_x, y: self.tab_top(), w: t::ADD_BUTTON, h: t::HEIGHT }
    }

    /// Whether the tabs are scrolled away from their start, and whether
    /// there is more of them past the window's right edge: where the strip
    /// fades out.
    pub fn fades(&self) -> (bool, bool) {
        (self.offset > 0.5, self.offset < self.layout.max_offset() - 0.5)
    }
}

/// What a point on a strip is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hit {
    /// A tab's close button.
    Close(usize),
    /// A tab, anywhere but its close button.
    Tab(usize),
    Add,
    /// The strip, between and around those.
    Strip,
    Outside,
}

fn inside(r: &Rect, (x, y): (f64, f64)) -> bool {
    x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

/// What is under `(x, y)`. A tab past the window's edge is not under
/// anything; a close button counts wherever the pointer is over its tab,
/// which is when it shows.
pub fn hit(g: &Geometry, at: (f64, f64)) -> Hit {
    if !inside(&g.strip, at) {
        return Hit::Outside;
    }
    if inside(&g.add_rect(), at) {
        return Hit::Add;
    }
    let row = g.row();
    let seen = Rect { x: row.x + t::REVERSE_ARC_RADIUS, w: g.layout.viewport, ..row };
    if inside(&seen, at) {
        for tab in &g.layout.tabs {
            if g.close_rect(tab.member).is_some_and(|c| inside(&c, at)) {
                return Hit::Close(tab.member);
            }
            if g.tab_rect(tab.member).is_some_and(|r| inside(&r, at)) {
                return Hit::Tab(tab.member);
            }
        }
    }
    Hit::Strip
}

// ---------------------------------------------------------------- drawing

/// What `build` is told that the stack does not hold.
pub struct View<'a> {
    pub theme: &'a Theme,
    pub scale: f64,
    /// The ground of the terminal in front, which the tab in front is a
    /// piece of.
    pub well: Rgba,
    /// The tab the pointer is over.
    pub hovered: Option<usize>,
}

/// The ground the tabs stand on: a supervisor's border, a worker's band,
/// and a worker's band for an ordinary terminal's stack too
/// (`PlainStyle.band`).
pub fn band(wears: Wears, theme: &Theme) -> Rgba {
    match wears {
        Wears::Supervisor => scene::over(theme.window_base, theme.supervisor_bezel, 1.0),
        Wears::Worker | Wears::Plain => theme.worker_band,
    }
}

/// The name of the tab in front, and every other name, the plus and the
/// close buttons.
pub fn inks(wears: Wears, theme: &Theme) -> (Rgba, Rgba) {
    match wears {
        Wears::Supervisor => (theme.text, theme.text_secondary),
        Wears::Worker | Wears::Plain => (theme.terminal_bold, theme.terminal_dim),
    }
}

/// The status word's colour, by the table.
fn word_ink(wears: Wears, shown: BarShown, theme: &Theme) -> Rgba {
    match shown {
        BarShown::NeedsYou | BarShown::DoneUnseen => theme.attention_text,
        BarShown::Trouble => match wears {
            Wears::Supervisor => theme.problem_text_on_supervisor_bar,
            Wears::Worker | Wears::Plain => theme.problem_text_on_worker_band,
        },
        BarShown::Working | BarShown::None | BarShown::Held => inks(wears, theme).1,
    }
}

/// A glyph for `shown`: a status, or held. None for no status.
fn glyph(shown: BarShown, ink: Rgba, theme: &Theme) -> Option<Piece> {
    match shown.status() {
        Some(Shown::None) => None,
        Some(status) => Some(Piece::Glyph { shown: status, color: scene::glyph_color(theme, status), size: side::GLYPH, pulses: false }),
        None => Some(Piece::Held { color: ink, size: side::GLYPH }),
    }
}

/// What a strip draws, **in the order it is painted** (task 1583: the
/// band was once painted after the tabs and covered every one of them on
/// a real machine): `under` -- what the tabs stand on -- then `row`, the
/// tabs, clipped to [`Geometry::row`], then `over`, the status and the
/// glyphs at the edges; then the close buttons, the plus and the fades,
/// which are lines a scene has no item for and the host draws itself.
#[derive(Debug, Clone, PartialEq)]
pub struct Drawn {
    pub under: Vec<Item>,
    pub row: Vec<Item>,
    pub over: Vec<Item>,
    /// The close buttons that show, each with whether the pointer is on it.
    pub closes: Vec<(usize, Rect)>,
    /// Where the plus is.
    pub add: Rect,
    /// The colour of the plus, the closes and the fades' ground.
    pub ink: Rgba,
    pub band: Rgba,
}

/// The strip of a frame with a stack. `geometry` is where it all is;
/// `title` the status at the right end.
pub fn build(g: &Geometry, stack: &PaneStack, wears: Wears, title: &Title, view: &View, tr: &dyn Fn(&str) -> String) -> Drawn {
    let theme = view.theme;
    let band = band(wears, theme);
    let (current_ink, other_ink) = inks(wears, theme);
    let mut under = Vec::new();
    let mut row = Vec::new();
    let mut over = Vec::new();

    // An ordinary terminal has no band of its own: the strip brings one,
    // round at the top like the frame and square where the terminal begins
    // (the terminal's own window covers the rest of the round shape).
    if wears == Wears::Plain {
        under.push(Item::Round {
            rect: Rect { x: g.strip.x, y: g.strip.y, w: g.strip.w, h: g.strip.h + radius::PLAIN },
            radius: radius::PLAIN,
            color: band,
            edge: None,
        });
    }

    // The tab in front: round at the top, and at its foot an arc on each
    // side turning out into the content below, so that the tab and the
    // terminal are one piece of ground (the design's `07-tab-corners`).
    if let Some(front) = g.layout.tabs.iter().find(|tab| tab.current).and_then(|tab| g.tab_rect(tab.member)) {
        let foot = t::REVERSE_ARC_RADIUS;
        let bottom = front.y + front.h;
        for x in [front.x - foot, front.x + front.w] {
            row.push(Item::Fill { rect: Rect { x, y: bottom - foot, w: foot, h: foot + t::OVERLAP_BELOW }, color: view.well });
        }
        // The arcs: the band's colour, round, centred a foot out and a
        // foot up from each corner of the tab's foot.
        for cx in [front.x - foot, front.x + front.w + foot] {
            row.push(Item::Round { rect: Rect { x: cx - foot, y: bottom - 2.0 * foot, w: 2.0 * foot, h: 2.0 * foot }, radius: foot, color: band, edge: None });
        }
        row.push(Item::Round { rect: front, radius: t::CORNER_RADIUS, color: view.well, edge: None });
        // Square at the foot, and a hair past it over the content's line.
        let low = Rect { x: front.x, y: front.y + t::CORNER_RADIUS, w: front.w, h: front.h - t::CORNER_RADIUS + t::OVERLAP_BELOW };
        row.push(Item::Fill { rect: low, color: view.well });
    }

    let separator = scene::over(band, theme.stack_tab_separator, 1.0);
    for tab in &g.layout.tabs {
        let Some(r) = g.tab_rect(tab.member) else { continue };
        let Some(member) = stack.members.get(tab.member) else { continue };
        if tab.separator_before {
            let (w, _) = scene::hairline(view.scale);
            row.push(Item::Fill {
                rect: Rect { x: r.x - w / 2.0, y: r.y + (r.h - t::SEPARATOR_HEIGHT) / 2.0, w, h: t::SEPARATOR_HEIGHT },
                color: separator,
            });
        }
        let mut parts = Vec::new();
        if scene::draws(&member.name) {
            let weight = if tab.current { font::WEIGHT_EMPHASIS } else { font::WEIGHT_BODY };
            let ink = if tab.current { current_ink } else { other_ink };
            parts.push(Part {
                piece: Piece::Words { text: member.name.clone(), style: Style { size: font::BODY, weight, face: Face::Mono, color: ink } },
                side: Side::Rest,
                gap: 0.0,
            });
        }
        if let Some(role) = member.role {
            parts.push(Part {
                piece: Piece::Words {
                    text: tr(role),
                    style: Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color: other_ink },
                },
                side: Side::Trail,
                gap: look_pane::NAME_ROLE_GAP,
            });
        }
        // The glyph's place is kept when there is none to draw.
        let mut right = r.x + r.w - t::PADDING_X - t::CLOSE_GAP - t::CLOSE_BUTTON;
        match glyph(member.shown, other_ink, theme) {
            Some(piece) => parts.push(Part { piece, side: Side::Trail, gap: t::GAP }),
            None => right -= side::GLYPH + t::GAP,
        }
        let left = r.x + t::PADDING_X;
        if !parts.is_empty() && right > left {
            row.push(Item::Line { rect: Rect { x: left, y: r.y, w: right - left, h: r.h }, parts });
        }
    }

    // A terminal waiting past an edge shows its glyph at that edge.
    let (left, right) = stackstrip::beyond(&g.layout, &stack.urgent, g.offset);
    let row_r = g.row();
    let top = g.tab_top();
    for (member, x) in [
        (left, row_r.x + t::REVERSE_ARC_RADIUS),
        (right, row_r.x + row_r.w - t::REVERSE_ARC_RADIUS - side::GLYPH),
    ] {
        let Some(m) = member.and_then(|i| stack.members.get(i)) else { continue };
        if let Some(piece) = glyph(m.shown, other_ink, theme) {
            over.push(Item::Line { rect: Rect { x, y: top, w: side::GLYPH, h: t::HEIGHT }, parts: vec![Part { piece, side: Side::Lead, gap: 0.0 }] });
        }
    }

    // The status at the right end: the glyph, then the word.
    if let Some((from, to)) = g.layout.status {
        let mut parts = Vec::new();
        if let Some(piece) = glyph(title.shown, other_ink, theme) {
            parts.push(Part { piece, side: Side::Trail, gap: 0.0 });
        }
        if scene::draws(&title.word) {
            parts.push(Part {
                piece: Piece::Words {
                    text: title.word.clone(),
                    style: Style { size: font::BODY, weight: font::WEIGHT_EMPHASIS, face: Face::Ui, color: word_ink(wears, title.shown, theme) },
                },
                side: Side::Trail,
                gap: side::STATUS_WORD_GAP,
            });
        }
        if !parts.is_empty() {
            over.push(Item::Line { rect: Rect { x: g.strip.x + from, y: top, w: to - from, h: t::HEIGHT }, parts });
        }
    }

    let closes = g
        .layout
        .tabs
        .iter()
        .filter(|tab| close_shows(view.hovered == Some(tab.member), tab.current))
        .filter_map(|tab| g.close_rect(tab.member).map(|r| (tab.member, r)))
        .collect();
    Drawn { under, row, over, closes, add: g.add_rect(), ink: other_ink, band }
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

    const SUPERVISOR: &str = "0x00000000000000a1";
    const WORKER: &str = "0x00000000000000b1";
    const SHELL: &str = "0x00000000000000c2";

    // ---- what the tabs say (PaneStackRulesTests)

    #[test]
    fn every_member_says_what_its_title_would_and_the_frame_follows_the_one_in_front() {
        let all = terminals();
        let s = stack(&[(Some(SHELL), "x"), (Some(WORKER), "y"), (None, "own")], 1, Some(&all), &[]);
        assert_eq!(s.members[0], Member { name: "zsh".into(), shown: BarShown::None, wears: Wears::Plain, role: None });
        assert_eq!(s.members[1].name, "web-app worker");
        assert_eq!(s.members[1].shown, BarShown::NeedsYou);
        assert_eq!(s.members[1].role, Some(pane::msg::WORKER));
        // One the core has not listed: an ordinary terminal under its own name.
        assert_eq!(s.members[2], Member { name: "own".into(), shown: BarShown::None, wears: Wears::Plain, role: None });
        assert_eq!(wears(&s), Wears::Worker);
        let front = stack(&[(Some(SUPERVISOR), ""), (Some(SHELL), "")], 0, Some(&all), &[]);
        assert_eq!(wears(&front), Wears::Supervisor);
        // An ordinary terminal's stack is still framed.
        assert_eq!(wears(&stack(&[(Some(SHELL), ""), (None, "b")], 1, Some(&all), &[])), Wears::Plain);
    }

    #[test]
    fn who_is_waiting_is_the_cores_order_kept_to_this_stack() {
        let s = stack(&[(Some("a"), ""), (Some("b"), ""), (Some("c"), "")], 0, None, &["z", "c", "a"]);
        assert_eq!(s.urgent, [2, 0]);
        // A current out of range is the first.
        assert_eq!(stack(&[(None, "a"), (None, "b")], 9, None, &[]).current, 0);
    }

    // ---- rules (PolterPaneTabRulesTests)

    #[test]
    fn a_close_button_shows_under_the_pointer_and_on_the_one_in_front() {
        assert!(!close_shows(false, false));
        assert!(close_shows(true, false));
        assert!(close_shows(false, true));
    }

    #[test]
    fn closing_others_right_and_left_and_when_there_is_none() {
        assert_eq!(closing(Closing::Others, 1, 4), [0, 2, 3]);
        assert_eq!(closing(Closing::Right, 1, 4), [2, 3]);
        assert_eq!(closing(Closing::Left, 1, 4), [0]);
        assert!(closing(Closing::Right, 3, 4).is_empty());
        assert!(closing(Closing::Left, 0, 4).is_empty());
        assert!(closing(Closing::Others, 0, 1).is_empty());
        assert!(closing(Closing::Others, 5, 4).is_empty());
        assert!(closes_pane(&[0, 1, 2], 3));
        assert!(!closes_pane(&[0, 2], 3));
        assert!(!closes_pane(&[0, 0, 2], 3));
        assert!(!closes_pane(&[], 0));
    }

    #[test]
    fn a_wheel_that_turns_up_and_down_scrolls_the_tabs_sideways() {
        // A notch away from the person goes back towards the start.
        assert_eq!(scroll(0, 120, WHEEL_LINE), -16.0);
        assert_eq!(scroll(0, -240, WHEEL_LINE), 32.0);
        // A sideways wheel as it is, when it is the larger.
        assert_eq!(scroll(-120, 60, WHEEL_LINE), 16.0);
    }

    // ---- dropping onto a strip

    #[test]
    fn where_a_terminal_let_go_on_the_strip_goes_in() {
        // Three at 100 from 20: middles at 70, 170, 270.
        let geo = g(&[100.0; 3], 0, 500.0, 0.0);
        assert_eq!(geo.insertion(30.0), 0);
        assert_eq!(geo.insertion(71.0), 1);
        assert_eq!(geo.insertion(171.0), 2);
        assert_eq!(geo.insertion(400.0), 3);
        assert_eq!(geo.caret_x(1), 120.0);
        assert_eq!(geo.caret_x(3), 320.0);
        // Scrolled: the middles move with the tabs.
        let far = g(&[150.0; 8], 6, 400.0, 0.0);
        let t6 = far.tab_rect(6).unwrap();
        assert_eq!(far.insertion(t6.x + 1.0), 6);
        assert_eq!(far.insertion(t6.x + t6.w / 2.0 + 1.0), 7);
        assert_eq!(far.caret_x(6), t6.x);
    }

    #[test]
    fn along_its_own_strip_a_tab_lands_where_it_was_let_go() {
        // a b c d: b let go before d (insertion 3) ends up third.
        assert_eq!(reorder_to(1, 3), Some(2));
        assert_eq!(reorder_to(3, 0), Some(0));
        // Let go either side of itself: it does not move.
        assert_eq!(reorder_to(1, 1), None);
        assert_eq!(reorder_to(1, 2), None);
    }

    // ---- geometry

    fn g(wants: &[f64], current: usize, w: f64, offset: f64) -> Geometry {
        geometry(Wears::Worker, w, wants, current, 0.0, offset, true, false)
    }

    #[test]
    fn a_supervisors_strip_is_inside_its_border_and_the_others_reach_the_edges() {
        let s = geometry(Wears::Supervisor, 400.0, &[100.0], 0, 0.0, 0.0, true, false);
        assert_eq!(s.strip, Rect { x: 4.0, y: 0.0, w: 392.0, h: 32.0 });
        let w = geometry(Wears::Worker, 400.0, &[100.0], 0, 0.0, 0.0, true, false);
        assert_eq!(w.strip, Rect { x: 0.0, y: 0.0, w: 400.0, h: 32.0 });
        // The tabs stand on the strip's bottom.
        assert_eq!(w.tab_rect(0), Some(Rect { x: 20.0, y: 4.0, w: 100.0, h: 28.0 }));
    }

    #[test]
    fn the_tab_in_front_is_scrolled_into_view_and_the_rest_move_with_it() {
        // Eight at least 104 (the seventh 150) in a 400 strip: they scroll.
        let geo = g(&[150.0; 8], 6, 400.0, 0.0);
        assert_eq!(geo.offset, 450.0);
        let r = geo.tab_rect(6).unwrap();
        assert!(r.x >= geo.row().x + t::REVERSE_ARC_RADIUS && r.x + r.w <= geo.row().x + geo.row().w - t::REVERSE_ARC_RADIUS, "{r:?}");
        assert_eq!(geo.fades(), (true, true));
        assert_eq!(g(&[100.0, 60.0], 0, 400.0, 0.0).fades(), (false, false));
    }

    /// Task 1594: the twelfth tab was brought in only half way, the right
    /// end's fade over its name and its close button. Brought into view, the
    /// tab in front is clear of every fade that shows.
    #[test]
    fn the_tab_in_front_is_brought_clear_of_the_fades() {
        let fade = t::REVERSE_ARC_RADIUS + t::SCROLL_FADE;
        let wants = [94.0, 70.0, 48.0, 126.0, 56.0, 150.0, 78.0, 94.0, 56.0, 142.0, 78.0, 56.0];
        for w in [300.0, 400.0, 520.0] {
            for current in 0..wants.len() {
                for from in [0.0, 250.0, 10000.0] {
                    let geo = geometry(Wears::Worker, w, &wants, current, 0.0, from, true, false);
                    let r = geo.tab_rect(current).unwrap();
                    let row = geo.row();
                    let (left, right) = geo.fades();
                    let (lo, hi) = (row.x + if left { fade } else { 0.0 }, row.x + row.w - if right { fade } else { 0.0 });
                    assert!(r.x >= lo - 1e-9 && r.x + r.w <= hi + 1e-9, "w={w} current={current} from={from}: {r:?} not within {lo}..{hi}");
                }
            }
        }
    }

    #[test]
    fn the_wheel_leaves_the_tabs_where_it_put_them_until_something_changes() {
        // Not revealing: the offset stays where the wheel left it, in range.
        let still = geometry(Wears::Worker, 400.0, &[150.0; 8], 6, 0.0, 100.0, false, true);
        assert_eq!(still.offset, 100.0);
        assert_eq!(geometry(Wears::Worker, 400.0, &[150.0; 8], 6, 0.0, 9999.0, false, true).offset, still.layout.max_offset());
        assert_eq!(still.scrolled(-500.0), 0.0);
        assert_eq!(still.scrolled(16.0), 116.0);
        // Revealing: the tab in front comes into view.
        assert_eq!(geometry(Wears::Worker, 400.0, &[150.0; 8], 6, 0.0, 100.0, true, false).offset, 450.0);
    }

    #[test]
    fn what_a_point_on_the_strip_is() {
        let geo = g(&[100.0, 100.0, 100.0], 1, 500.0, 0.0);
        // The first tab runs 20..120, its close button 92..108 across, 10..26 down.
        assert_eq!(hit(&geo, (30.0, 18.0)), Hit::Tab(0));
        assert_eq!(hit(&geo, (100.0, 18.0)), Hit::Close(0));
        assert_eq!(hit(&geo, (150.0, 18.0)), Hit::Tab(1));
        assert_eq!(hit(&geo, (geo.add_rect().x + 4.0, 18.0)), Hit::Add);
        assert_eq!(hit(&geo, (10.0, 18.0)), Hit::Strip);
        assert_eq!(hit(&geo, (30.0, 40.0)), Hit::Outside);
        // Scrolled: a tab past the window's edge is not under the pointer.
        let far = g(&[150.0; 8], 6, 400.0, 0.0);
        assert_eq!(hit(&far, (far.row().x + 9.0, 18.0)), Hit::Tab(4));
        assert_eq!(hit(&far, (far.row().x + 2.0, 18.0)), Hit::Strip);
    }

    #[test]
    fn a_tab_wants_its_name_its_word_and_the_places_of_its_glyph_and_close_button() {
        assert_eq!(wanted(40.0, None), 24.0 + 40.0 + 8.0 + 14.0 + 4.0 + 16.0);
        assert_eq!(wanted(40.0, Some(30.0)), wanted(40.0, None) + 8.0 + 30.0);
        let title = Title { name: "x".into(), shown: BarShown::None, word: String::new() };
        assert_eq!(status_width(&title, 50.0), 0.0);
        let waiting = Title { shown: BarShown::NeedsYou, word: "等批准".into(), ..title };
        assert_eq!(status_width(&waiting, 50.0), 14.0 + 5.0 + 50.0);
    }

    // ---- drawing

    fn view(theme: &'static Theme, hovered: Option<usize>) -> View<'static> {
        View { theme, scale: 1.0, well: Rgba { r: 1, g: 2, b: 3, a: 1.0 }, hovered }
    }

    fn named(names: &[&str]) -> PaneStack {
        PaneStack {
            members: names.iter().map(|n| Member { name: n.to_string(), shown: BarShown::None, wears: Wears::Worker, role: None }).collect(),
            current: 1,
            urgent: Vec::new(),
        }
    }

    #[test]
    fn every_tab_says_its_name_and_the_one_in_front_is_heavier() {
        let s = named(&["a", "b", "c"]);
        let geo = g(&[100.0; 3], 1, 500.0, 0.0);
        let title = status_title(&s, "");
        let d = build(&geo, &s, Wears::Worker, &title, &view(look::theme(false), None), &|x| x.to_string());
        assert_eq!(scene::all_text(&d.row), ["a", "b", "c"]);
        let weights: Vec<f64> = d
            .row
            .iter()
            .filter_map(|i| match i {
                Item::Line { parts, .. } => parts.iter().find_map(|p| match &p.piece {
                    Piece::Words { style, .. } => Some(style.weight),
                    _ => None,
                }),
                _ => None,
            })
            .collect();
        assert_eq!(weights, [font::WEIGHT_BODY, font::WEIGHT_EMPHASIS, font::WEIGHT_BODY]);
    }

    #[test]
    fn the_close_buttons_that_show_are_the_one_in_front_and_the_one_under_the_pointer() {
        let s = named(&["a", "b", "c"]);
        let geo = g(&[100.0; 3], 1, 500.0, 0.0);
        let title = status_title(&s, "");
        let theme = look::theme(false);
        let shown = |hovered| build(&geo, &s, Wears::Worker, &title, &view(theme, hovered), &|x| x.to_string()).closes.iter().map(|(m, _)| *m).collect::<Vec<_>>();
        assert_eq!(shown(None), [1]);
        assert_eq!(shown(Some(2)), [1, 2]);
    }

    #[test]
    fn the_tab_in_front_is_the_terminals_ground_and_the_name_keeps_clear_of_the_close_button() {
        let mut s = named(&["a", "b"]);
        // With a glyph: its place is then not given up, and the line runs to
        // just short of the close button.
        for m in &mut s.members {
            m.shown = BarShown::NeedsYou;
        }
        let geo = g(&[100.0, 100.0], 1, 500.0, 0.0);
        let well = view(look::theme(true), None).well;
        let d = build(&geo, &s, Wears::Worker, &status_title(&s, ""), &view(look::theme(true), None), &|x| x.to_string());
        let front = geo.tab_rect(1).unwrap();
        assert!(d.row.iter().any(|i| matches!(i, Item::Round { rect, color, .. } if *rect == front && *color == well)));
        let close = geo.close_rect(1).unwrap();
        for i in &d.row {
            if let Item::Line { rect, .. } = i {
                assert!(rect.x + rect.w <= close.x, "{rect:?} runs into the close button at {}", close.x);
            }
        }
    }

    #[test]
    fn a_waiting_terminal_past_an_edge_is_drawn_at_that_edge() {
        let mut s = named(&["a", "b", "c", "d", "e", "f", "g", "h"]);
        s.current = 6;
        s.members[0].shown = BarShown::NeedsYou;
        s.urgent = vec![0];
        let geo = g(&[150.0; 8], 6, 400.0, 0.0);
        let d = build(&geo, &s, Wears::Worker, &status_title(&s, ""), &view(look::theme(false), None), &|x| x.to_string());
        let edge = d.over.iter().any(|i| matches!(i, Item::Line { rect, parts } if rect.x == geo.row().x + t::REVERSE_ARC_RADIUS && matches!(parts[0].piece, Piece::Glyph { shown: Shown::NeedsYou, .. })));
        assert!(edge, "{:?}", d.over);
    }

    fn rect_of(i: &Item) -> Option<Rect> {
        match i {
            Item::Fill { rect, .. } | Item::Round { rect, .. } | Item::Text { rect, .. } | Item::Line { rect, .. } | Item::Block { rect, .. } => Some(*rect),
        }
    }

    fn overlaps(a: &Rect, b: &Rect) -> bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    /// Task 1583, the first real machine: only the close buttons and the
    /// plus were on the strip. **What is painted after the tabs must not
    /// cover them**, and the window they are clipped to must be a window.
    #[test]
    fn nothing_painted_after_the_tabs_covers_them_and_their_clip_is_not_empty() {
        let theme = look::theme(true);
        for wears in [Wears::Plain, Wears::Worker, Wears::Supervisor] {
            for (wants, current, w) in [(vec![100.0, 100.0], 1, 400.0), (vec![150.0; 8], 6, 400.0), (vec![120.0], 0, 300.0)] {
                let mut s = named(&vec!["n"; wants.len()]);
                s.current = current;
                for m in &mut s.members {
                    m.wears = wears;
                }
                let geo = geometry(wears, w, &wants, current, 0.0, 0.0, true, false);
                let d = build(&geo, &s, wears, &status_title(&s, ""), &view(theme, None), &|x| x.to_string());
                let clip = geo.row();
                assert!(clip.w > 0.0 && clip.h > 0.0, "{wears:?} {wants:?}: the clip is empty: {clip:?}");
                // The tab in front is wholly inside the clip, and every tab
                // is at least partly, or scrolled wholly out of it.
                let front = geo.tab_rect(current).unwrap();
                assert!(front.x >= clip.x && front.x + front.w <= clip.x + clip.w, "{wears:?}: {front:?} outside {clip:?}");
                assert!(front.y >= clip.y && front.y + front.h <= clip.y + clip.h, "{wears:?}: {front:?} outside {clip:?}");
                // Nothing over the tabs is a shape that would hide them.
                for i in &d.over {
                    assert!(matches!(i, Item::Line { .. }), "{wears:?}: {i:?} is painted over the tabs");
                }
                // And what is under them is under every tab's place.
                for i in &d.under {
                    let r = rect_of(i).unwrap();
                    assert!(overlaps(&r, &front), "{wears:?}: {r:?} is not under the tabs");
                }
                // The tabs themselves are in `row`: the front tab's ground.
                assert!(d.row.iter().any(|i| matches!(i, Item::Round { rect, .. } if *rect == front)), "{wears:?}");
            }
        }
    }

    #[test]
    fn an_ordinary_terminals_stack_brings_its_own_band() {
        let mut s = named(&["a", "b"]);
        for m in &mut s.members {
            m.wears = Wears::Plain;
        }
        let geo = geometry(Wears::Plain, 400.0, &[100.0, 100.0], 1, 0.0, 0.0, true, false);
        let theme = look::theme(false);
        let d = build(&geo, &s, Wears::Plain, &status_title(&s, ""), &view(theme, None), &|x| x.to_string());
        // Under the tabs: painted first, so they stand on it.
        assert!(matches!(d.under.first(), Some(Item::Round { color, .. }) if *color == theme.worker_band));
        // Above them, the band's colour is only in the circles that cut the
        // feet of the tab in front -- never a shape the size of the strip.
        assert!(!d.over.iter().chain(&d.row).any(|i| matches!(i, Item::Round { color, rect, .. } if *color == theme.worker_band && rect.w > 2.0 * t::REVERSE_ARC_RADIUS)));
        let w = build(&geo, &s, Wears::Worker, &status_title(&s, ""), &view(theme, None), &|x| x.to_string());
        assert!(w.under.is_empty());
    }
}
