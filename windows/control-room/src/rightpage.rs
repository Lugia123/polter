//! The right side's four pages and the tabs over them (task 2015, Q6;
//! `polter-artifacts/1985/DESIGN-v2.md` §5–6, `polter-artifacts/2015/API.md`
//! §4): Supervisor, Chat, Tasks, Performance.
//!
//! **The tabs take the place of the supervisor frame's title bar**, as a
//! stack's strip takes it on a pane (the macOS host's `PaneFrameView` stack
//! slot): the strip is `stack_tab::STRIP_HEIGHT` high, which is the bar's
//! `pane::BAR_HEIGHT`, so the supervisor's terminal stays exactly where
//! `scene::terminal_rect` put it before there were pages. What the bar said
//! at its right end -- the supervisor's state and "Let the control room take
//! over?" -- goes to the strip's right end, on all four pages (API.md §6,
//! change log).
//!
//! The tabs are a stack's tabs without a close button or a plus: there is
//! nothing to close and nothing to add. They keep the stack's paddings,
//! insets and the way the widest give way first (`stackstrip::capped`).
//!
//! **Which page is in front is the host's, per group, for the life of the
//! process** (API.md §4), and never the core's. The supervisor's terminal
//! is hidden, not closed, while another page is in front: `View::page`
//! decides whether `Paged::right.terminal` is there at all, and the host
//! places the terminal by that alone.

use crate::glyph::Mark;
use crate::layout::Rect;
use crate::lend::Detail as Detail_;
use crate::list::Row;
use crate::look::{font, pane, radius, side, stack_tab as t, Rgba, Theme};
use crate::level::{level_ink, Level};
use crate::scene::{self, Face, Item, Part, Piece, Side, Style};

pub mod msg {
    use crate::n_;
    pub const CHAT: &str = n_("Chat");
    pub const TASKS: &str = n_("Tasks");
    pub const PERFORMANCE: &str = n_("Performance");
    /// On the chat page, after the chat's program ended: nothing is opened
    /// again until the person asks (group seq 223 -- a chat that ends as it
    /// starts would otherwise be opened again and again).
    pub const CHAT_ENDED: &str = n_("The chat has ended. Click here to open it again.");
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Page {
    /// The group's supervisor's own terminal, as before there were pages.
    #[default]
    Supervisor,
    /// A chat pane of the person's own, open on this group (API.md §3).
    Chat,
    Tasks,
    Performance,
}

impl Page {
    /// In the order the tabs stand.
    pub const ALL: [Page; 4] = [Page::Supervisor, Page::Chat, Page::Tasks, Page::Performance];

    pub fn index(self) -> usize {
        match self {
            Page::Supervisor => 0,
            Page::Chat => 1,
            Page::Tasks => 2,
            Page::Performance => 3,
        }
    }

    /// The tab's name, untranslated.
    pub fn label(self) -> &'static str {
        match self {
            Page::Supervisor => crate::lend::msg::SUPERVISOR,
            Page::Chat => msg::CHAT,
            Page::Tasks => msg::TASKS,
            Page::Performance => msg::PERFORMANCE,
        }
    }

    /// Whether the supervisor's terminal is what this page shows.
    pub fn shows_terminal(self) -> bool {
        self == Page::Supervisor
    }
}

/// What stands before a tab's name: the supervisor's flag on its own tab,
/// and on "Performance" a dot in the colour of the worst any terminal of
/// the group is doing -- none while all are well or nothing is measured
/// (DESIGN-v2 §6: "都正常时不显示"; API.md §1: `none` draws no dot).
pub fn mark(page: Page, level: Level, theme: &Theme, current: bool) -> Option<(Mark, Rgba)> {
    match page {
        Page::Supervisor => Some((Mark::Supervisor, label_style(theme, current).color)),
        Page::Performance => level_ink(theme, level).map(|ink| (Mark::Dot, ink.base)),
        Page::Chat | Page::Tasks => None,
    }
}

/// How a tab's name is written: the one in front emphasised, as a stack's.
pub fn label_style(theme: &Theme, current: bool) -> Style {
    Style {
        size: font::BODY,
        weight: if current { font::WEIGHT_EMPHASIS } else { font::WEIGHT_BODY },
        face: Face::Ui,
        color: if current { theme.text } else { theme.text_secondary },
    }
}

/// How wide a tab wants to be when its name measures `name` points: its
/// paddings, the name, and the mark before it when it has one.
pub fn want(name: f64, marked: bool) -> f64 {
    let mut w = 2.0 * t::PADDING_X + name;
    if marked {
        w += side::GLYPH + t::GAP;
    }
    w
}

/// `want` with no font to measure by: `stack_tab::NOMINAL_CELL_WIDTH` a
/// character, a wide one two (`stackstrip::nominal_width`'s rule). For
/// tests and the coordinate dump; a host measures.
pub fn nominal_want(name: &str, marked: bool) -> f64 {
    let cells: usize = name.chars().map(|c| if c as u32 >= 0x2E80 { 2 } else { 1 }).sum();
    want(cells as f64 * t::NOMINAL_CELL_WIDTH, marked)
}

/// The narrowest a tab other than the one in front is cut to: its paddings
/// and two cells, enough for a letter and the ellipsis.
pub const LEAST: f64 = 2.0 * t::PADDING_X + 2.0 * t::NOMINAL_CELL_WIDTH;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tab {
    pub page: Page,
    /// In the right side's points.
    pub rect: Rect,
    pub current: bool,
    /// A hairline at its left edge: between two tabs neither of which is in
    /// front, as a stack's.
    pub separator_before: bool,
    /// Less than it wanted: its name ends in an ellipsis.
    pub squeezed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Strip {
    pub tabs: Vec<Tab>,
    /// The whole strip: the right side's top `STRIP_HEIGHT` points.
    pub bar: Rect,
    /// After the last tab to the strip's right end: where what the
    /// supervisor's bar said at its right end now goes.
    pub status: Rect,
}

impl Strip {
    /// The page whose tab is under `(x, y)`, in the right side's points.
    pub fn hit(&self, x: f64, y: f64) -> Option<Page> {
        self.tabs.iter().find(|tab| x >= tab.rect.x && x < tab.rect.x + tab.rect.w && y >= tab.rect.y && y < tab.rect.y + tab.rect.h).map(|tab| tab.page)
    }
}

/// Where the four tabs go over a right side `width` points wide, each
/// wanting `wants[page.index()]` (`want`), with `current` in front.
///
/// From inside the frame's border, `stack_tab::INSET` in; up to
/// `stack_tab::TRAILING` short of its right end. When they do not fit, the
/// widest of the others are cut to one common width, down to `LEAST`; the
/// one in front is cut only when even that is not enough, and then to what
/// there is.
pub fn strip(width: f64, wants: [f64; 4], current: Page) -> Strip {
    let left = pane::SUPERVISOR_BORDER;
    let right = (width - pane::SUPERVISOR_BORDER).max(left);
    let start = left + t::INSET;
    let room = (right - t::TRAILING - start).max(0.0);
    let front = current.index();
    let mut widths = wants.to_vec();
    if wants.iter().sum::<f64>() > room {
        let mut others = wants.to_vec();
        others.remove(front);
        let least: f64 = others.iter().map(|w| w.min(LEAST)).sum();
        let front_w = wants[front].min((room - least).max(0.0));
        let cut = if others.iter().sum::<f64>() <= room - front_w {
            others
        } else if least <= room - front_w {
            crate::stackstrip::capped(&others, room - front_w, LEAST)
        } else {
            others.iter().map(|w| w.min(LEAST)).collect()
        };
        widths = cut;
        widths.insert(front, front_w);
    }
    let y = t::STRIP_HEIGHT - t::HEIGHT;
    let mut x = start;
    let mut tabs = Vec::new();
    for page in Page::ALL {
        let i = page.index();
        tabs.push(Tab {
            page,
            rect: Rect { x, y, w: widths[i], h: t::HEIGHT },
            current: i == front,
            separator_before: i > 0 && i != front && i - 1 != front,
            squeezed: widths[i] < wants[i],
        });
        x += widths[i];
    }
    let status_x = x + t::STATUS_GAP;
    Strip {
        tabs,
        bar: Rect { x: 0.0, y: 0.0, w: width.max(0.0), h: t::STRIP_HEIGHT },
        status: Rect { x: status_x, y: 0.0, w: (right - t::TRAILING - status_x).max(0.0), h: t::STRIP_HEIGHT },
    }
}

/// What the strip draws: the tab in front as a raised piece of `front`
/// (the colour of what is under it, so the two read as one), the hairlines
/// between the others on `ground`, and every tab's mark and name.
pub fn items(strip: &Strip, level: Level, theme: &Theme, scale: f64, ground: Rgba, front: Rgba, tr: &dyn Fn(&str) -> String) -> Vec<Item> {
    let mut items = Vec::new();
    let (hair, amount) = scene::hairline(scale);
    for tab in &strip.tabs {
        let r = tab.rect;
        if tab.current {
            items.push(Item::Round { rect: r, radius: t::CORNER_RADIUS, color: front, edge: None });
            // Square at its foot, and over the strip's lower edge.
            let half = r.h / 2.0;
            items.push(Item::Fill { rect: Rect { x: r.x, y: r.y + half, w: r.w, h: half + t::OVERLAP_BELOW }, color: front });
        }
        if tab.separator_before {
            items.push(Item::Fill {
                rect: Rect { x: r.x - hair / 2.0, y: r.y + (r.h - t::SEPARATOR_HEIGHT) / 2.0, w: hair, h: t::SEPARATOR_HEIGHT },
                color: scene::over(ground, theme.stack_tab_separator, amount),
            });
        }
        let mut parts = Vec::new();
        if let Some((m, color)) = mark(tab.page, level, theme, tab.current) {
            parts.push(Part { piece: Piece::Mark { mark: m, color, size: side::GLYPH }, side: Side::Lead, gap: 0.0 });
        }
        let gap = if parts.is_empty() { 0.0 } else { t::GAP };
        parts.push(Part { piece: Piece::Words { text: tr(tab.page.label()), style: label_style(theme, tab.current) }, side: Side::Lead, gap });
        items.push(Item::Line { rect: Rect { x: r.x + t::PADDING_X, y: r.y, w: (r.w - 2.0 * t::PADDING_X).max(0.0), h: r.h }, parts });
    }
    items
}

/// What the host says about the pages when it builds the right side.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct View {
    pub page: Page,
    /// How wide each tab wants to be, by `Page::index`: the host measures
    /// each name in `label_style` and hands it to `want`.
    pub wants: [f64; 4],
    /// The group's `resource_level`.
    pub level: Level,
}

/// The right side with its pages.
#[derive(Debug, Clone, PartialEq)]
pub struct Paged {
    /// What is drawn, where a press goes, where the supervisor's terminal
    /// is put -- none on a page that is not its -- and where the take-over
    /// button is measured back from: the same fields as without pages.
    pub right: scene::Right,
    /// None where there are no pages: nothing selected, or a terminal on
    /// its own, which is not a group.
    pub strip: Option<Strip>,
    /// Where the page in front goes when it is not the supervisor's: what
    /// the chat pane is placed in and what the other two pages are drawn
    /// inside. Always `scene::terminal_rect`, whichever page and whether or
    /// not the group has a supervisor, so a page does not move when one
    /// starts.
    pub page: Option<Rect>,
}

/// Whether the right side has pages: a group is selected. Nothing
/// selected, or a terminal on its own -- which is not a group -- has none.
pub fn has_pages(detail: &Detail_, row: Option<&Row>) -> bool {
    row.is_some_and(|r| r.alone.is_none()) && !matches!(detail, Detail_::NothingSelected)
}

/// How wide what starting a supervisor offers is laid out
/// (`scene::build_start`): the terminal's width inside the frame when the
/// side has pages and no supervisor is shown here, the side's otherwise.
pub fn start_width(width: f64, detail: &Detail_, row: Option<&Row>) -> f64 {
    if has_pages(detail, row) && !matches!(detail, Detail_::Terminal(_)) {
        scene::terminal_rect(width, 0.0).w
    } else {
        width
    }
}

/// What starting a supervisor offers (`scene::build_start`), where it is
/// with the pages over the side: moved down by the strip with the rest of
/// the supervisor's page when no supervisor is shown -- what is pressed
/// moves with what is drawn -- and not there at all on another page.
pub fn place_start(start: scene::Start, detail: &Detail_, row: Option<&Row>, page: Page) -> scene::Start {
    if !has_pages(detail, row) || matches!(detail, Detail_::Terminal(_)) {
        return start;
    }
    if !page.shows_terminal() {
        return scene::Start::default();
    }
    // Where the terminal would be: the side's sentence is there (`build`),
    // and what starting one offers was laid out at its width
    // (`start_width`).
    let inside = scene::terminal_rect(0.0, 0.0);
    let down = |r: Rect| Rect { x: r.x + inside.x, y: r.y + inside.y, ..r };
    scene::Start {
        items: scene::moved(start.items, inside.x, inside.y),
        role: start.role.map(down),
        directory: start.directory.map(down),
        start: start.start.map(down),
        button: start.button.map(down),
        tip: start.tip.map(|(r, s)| (down(r), s)),
        go_to_tab: start.go_to_tab.map(|(s, r)| (s, down(r))),
        sessions: start.sessions.into_iter().map(|(s, r)| (s, down(r))).collect(),
        clis: start.clis.into_iter().map(|(c, r)| (c, down(r))).collect(),
    }
}

/// `scene::build_right_with`, with the pages over it when `view` says
/// there are and the selection is a group.
///
/// The supervisor's frame keeps its bezel on every page and the strip
/// stands in its bar. With no supervisor shown here **the frame is the
/// same**: the bezel from the top with the strip in it, and what the right
/// side said before in the terminal's place, on the supervisor's page; the
/// terminal's ground there on the others.
#[allow(clippy::too_many_arguments)]
pub fn build(
    detail: &Detail_,
    row: Option<&Row>,
    width: f64,
    height: f64,
    theme: &Theme,
    scale: f64,
    in_terminal: bool,
    tr: &dyn Fn(&str) -> String,
    notice: Option<&crate::project_notice::Band>,
    view: Option<&View>,
) -> Paged {
    let paged = view.filter(|_| has_pages(detail, row)).copied();
    let Some(view) = paged else {
        return Paged { right: scene::build_right_with(detail, row, width, height, theme, scale, in_terminal, tr, notice), strip: None, page: None };
    };
    let strip = strip(width, view.wants, view.page);
    let page = (!view.page.shows_terminal()).then(|| scene::terminal_rect(width, height));
    // What is said about the group's project is the supervisor's page's.
    let notice = if view.page.shows_terminal() { notice } else { None };

    if let Detail_::Terminal(_) = detail {
        let mut right = scene::build_right_with(detail, row, width, height, theme, scale, in_terminal, tr, notice);
        let bezel = scene::over(theme.window_base, theme.supervisor_bezel, 1.0);
        // The bar is the first line the frame draws: its name and role go
        // (the list says which group this is, and the tab says what), and
        // what it said at its right end moves to the strip's.
        if let Some(i) = right.items.iter().position(|it| matches!(it, Item::Line { .. })) {
            let Item::Line { parts, .. } = right.items.remove(i) else { unreachable!() };
            // What gave way by being cut on the bar gives way whole on the
            // strip (group seq 315): a status cut to "不认得的 C…" says
            // less than none.
            let kept: Vec<Part> = parts
                .into_iter()
                .filter(|p| p.side != Side::Lead)
                .map(|p| if p.side == Side::Squeezed { Part { side: Side::Whole, ..p } } else { p })
                .collect();
            let mut put = items(&strip, view.level, theme, scale, bezel, theme.terminal_background, tr);
            put.push(Item::Line { rect: strip.status, parts: kept });
            for (k, it) in put.into_iter().enumerate() {
                right.items.insert(i + k, it);
            }
        }
        right.take_over = right.take_over.map(|_| strip.status);
        if !view.page.shows_terminal() {
            right.terminal = None;
        }
        return Paged { right, strip: Some(strip), page };
    }

    // No supervisor shown here: **the same frame as with one** (0x4881's
    // real-machine reading, group seq 218: the strip used to stand on the
    // window over a frame that began 32 lower). The supervisor's bezel from
    // the top, the strip in it, and what the side says in the terminal's
    // place, as wide and as high as the terminal would be.
    let bezel = scene::over(theme.window_base, theme.supervisor_bezel, 1.0);
    let frame = Rect { x: 0.0, y: 0.0, w: width.max(0.0), h: height.max(0.0) };
    let mut out = vec![Item::Round { rect: frame, radius: radius::SUPERVISOR_OUTER, color: bezel, edge: Some(scene::over(bezel, theme.supervisor_edge, 1.0)) }];
    out.extend(items(&strip, view.level, theme, scale, bezel, theme.terminal_background, tr));
    let inside = scene::terminal_rect(width, height);
    let right = if view.page.shows_terminal() {
        let inner = scene::build_right_with(detail, row, inside.w, inside.h, theme, scale, in_terminal, tr, notice);
        let shift = |r: Rect| Rect { x: r.x + inside.x, y: r.y + inside.y, ..r };
        out.extend(scene::moved(inner.items, inside.x, inside.y));
        scene::Right { items: out, press: inner.press.map(|(r, p)| (shift(r), p)), terminal: inner.terminal.map(shift), take_over: inner.take_over.map(shift) }
    } else {
        out.push(Item::Fill { rect: inside, color: theme.terminal_background });
        scene::Right { items: out, press: None, terminal: None, take_over: None }
    };
    Paged { right, strip: Some(strip), page }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::DARK;

    fn wants() -> [f64; 4] {
        // The design's Windows page: 总管 with its flag, then three plain
        // names, the last with its dot.
        [nominal_want("总管", true), nominal_want("群聊", false), nominal_want("任务", false), nominal_want("性能", true)]
    }

    #[test]
    fn the_strip_is_the_bar_so_the_terminal_does_not_move() {
        assert_eq!(t::STRIP_HEIGHT, pane::BAR_HEIGHT);
    }

    #[test]
    fn four_tabs_in_order_from_the_inset_each_as_wide_as_it_wants() {
        let s = strip(900.0, wants(), Page::Supervisor);
        let pages: Vec<Page> = s.tabs.iter().map(|t| t.page).collect();
        assert_eq!(pages, Page::ALL.to_vec());
        // 12 + 32 + 12 + 14 + 8 = 78 for the flagged; 12 + 32 + 12 = 56.
        assert_eq!(s.tabs.iter().map(|t| t.rect.w).collect::<Vec<_>>(), vec![78.0, 56.0, 56.0, 78.0]);
        assert_eq!(s.tabs[0].rect.x, pane::SUPERVISOR_BORDER + t::INSET);
        for w in s.tabs.windows(2) {
            assert_eq!(w[0].rect.x + w[0].rect.w, w[1].rect.x);
        }
        assert!(s.tabs.iter().all(|t| t.rect.y == 4.0 && t.rect.h == 28.0 && !t.squeezed));
        // The status runs from the last tab plus its gap to the trailing edge.
        let last = s.tabs[3].rect;
        assert_eq!(s.status.x, last.x + last.w + t::STATUS_GAP);
        assert_eq!(s.status.x + s.status.w, 900.0 - pane::SUPERVISOR_BORDER - t::TRAILING);
    }

    #[test]
    fn separators_only_between_two_tabs_neither_in_front() {
        let s = strip(900.0, wants(), Page::Tasks);
        let sep: Vec<bool> = s.tabs.iter().map(|t| t.separator_before).collect();
        // Supervisor|Chat yes; Chat|Tasks no (Tasks in front); Tasks|Perf no.
        assert_eq!(sep, vec![false, true, false, false]);
        assert!(s.tabs[2].current && s.tabs.iter().filter(|t| t.current).count() == 1);
    }

    #[test]
    fn a_press_on_a_tab_is_its_page_and_between_or_below_them_is_none() {
        let s = strip(900.0, wants(), Page::Supervisor);
        for tab in &s.tabs {
            assert_eq!(s.hit(tab.rect.x + 1.0, tab.rect.y + 1.0), Some(tab.page));
            assert_eq!(s.hit(tab.rect.x + tab.rect.w - 0.5, tab.rect.y + tab.rect.h - 0.5), Some(tab.page));
        }
        assert_eq!(s.hit(s.tabs[0].rect.x - 1.0, 10.0), None);
        assert_eq!(s.hit(s.tabs[0].rect.x + 1.0, 2.0), None, "above the tabs, in the strip's top");
        assert_eq!(s.hit(s.tabs[0].rect.x + 1.0, t::STRIP_HEIGHT + 1.0), None, "under the strip");
    }

    #[test]
    fn too_narrow_the_others_give_way_and_the_one_in_front_does_not() {
        let w = wants();
        // Room for the front whole and the rest at less than they want.
        let width = 2.0 * pane::SUPERVISOR_BORDER + t::INSET + t::TRAILING + w[3] + 3.0 * 50.0;
        let s = strip(width, w, Page::Performance);
        assert_eq!(s.tabs[3].rect.w, w[3]);
        assert!(!s.tabs[3].squeezed);
        assert!(s.tabs[..3].iter().all(|t| t.squeezed && t.rect.w >= LEAST));
        let end = s.tabs[3].rect.x + s.tabs[3].rect.w;
        assert!(end <= width - pane::SUPERVISOR_BORDER - t::TRAILING + 1e-9);
        // Narrower than even that: the others at LEAST, the front cut to what is left.
        let s = strip(2.0 * pane::SUPERVISOR_BORDER + t::INSET + t::TRAILING + 3.0 * LEAST + 30.0, w, Page::Performance);
        assert!(s.tabs[..3].iter().all(|t| t.rect.w == LEAST));
        assert_eq!(s.tabs[3].rect.w, 30.0);
        assert_eq!(s.status.w, 0.0);
    }

    #[test]
    fn the_dot_is_drawn_for_a_warning_or_worse_and_never_for_ok_or_nothing_measured() {
        assert_eq!(mark(Page::Performance, Level::None, &DARK, false), None);
        assert_eq!(mark(Page::Performance, Level::Ok, &DARK, false), None);
        for l in [Level::Warn1, Level::Warn2, Level::Warn3, Level::Warn4, Level::Withheld, Level::Killed] {
            let (m, c) = mark(Page::Performance, l, &DARK, false).expect("a dot");
            assert_eq!(m, Mark::Dot);
            assert_eq!(c, level_ink(&DARK, l).unwrap().base);
        }
        assert_eq!(mark(Page::Supervisor, Level::Killed, &DARK, false).map(|m| m.0), Some(Mark::Supervisor));
        assert_eq!(mark(Page::Chat, Level::Killed, &DARK, false), None);
        assert_eq!(mark(Page::Tasks, Level::Killed, &DARK, false), None);
    }

    const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/poltergeist/testdata/control_snapshot.json"));

    fn same(s: &str) -> String {
        s.to_string()
    }

    fn words(items: &[Item]) -> Vec<String> {
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
                _ => {}
            }
        }
        out
    }

    fn view(page: Page) -> View {
        View { page, wants: wants(), level: Level::Warn1 }
    }

    /// A supervisor started by hand (task 1635) says so in a note, which the
    /// bar cuts first (`Side::Squeezed`); on the strip it goes whole or not
    /// at all (`Side::Whole`, group seq 315).
    #[test]
    fn the_strips_note_is_whole_or_not_there() {
        use crate::lend::Loan;
        use crate::list::List;
        let l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let mut with = l.rows().find(|r| r.steward.is_some() && r.alone.is_none() && r.title.is_some()).expect("a group with a titled supervisor").clone();
        let note = "An agent this build does not know; its state is unknown";
        with.title.as_mut().unwrap().note = Some(crate::snapshot::Say { key: "x".into(), template: note.into(), args: Vec::new() });
        let detail = Detail_::Terminal(Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() });
        let theme = crate::look::theme(true);
        // On the bar, without pages, it gives way by being cut.
        let bar = scene::build_right(&detail, Some(&with), 600.0, 700.0, theme, 1.0, false, &same);
        let side_of = |items: &[Item]| items.iter().find_map(|i| match i {
            Item::Line { parts, .. } => parts.iter().find(|p| matches!(&p.piece, Piece::Words { text, .. } if text == note)).map(|p| p.side),
            _ => None,
        });
        assert_eq!(side_of(&bar.items), Some(Side::Squeezed));
        for page in Page::ALL {
            let p = build(&detail, Some(&with), 600.0, 700.0, theme, 1.0, false, &same, None, Some(&view(page)));
            assert_eq!(side_of(&p.right.items), Some(Side::Whole), "{page:?}");
        }
    }

    /// The supervisor's frame with pages: its terminal where it was on its
    /// own page and nowhere on the others, where the page goes instead; the
    /// bar's name gone, its state at the strip's right end on every page.
    #[test]
    fn the_supervisors_terminal_is_shown_on_its_page_only_and_its_state_on_all_four() {
        use crate::lend::Loan;
        use crate::list::List;
        let l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let with = l.rows().find(|r| r.steward.is_some() && r.alone.is_none() && !r.word.is_empty()).expect("a group with a supervisor and a state");
        let detail = Detail_::Terminal(Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() });
        let theme = crate::look::theme(true);
        let plain = scene::build_right(&detail, Some(with), 600.0, 700.0, theme, 1.0, false, &same);
        for page in Page::ALL {
            let p = build(&detail, Some(with), 600.0, 700.0, theme, 1.0, false, &same, None, Some(&view(page)));
            let strip = p.strip.as_ref().expect("a group has pages");
            if page.shows_terminal() {
                assert_eq!(p.right.terminal, plain.terminal, "{page:?}");
                assert_eq!(p.page, None);
            } else {
                assert_eq!(p.right.terminal, None, "{page:?}");
                assert_eq!(p.page, Some(scene::terminal_rect(600.0, 700.0)));
            }
            let said = words(&p.right.items);
            assert!(!said.contains(&with.id), "{page:?}: the bar's name is not drawn: {said:?}");
            assert!(said.contains(&with.word), "{page:?}: the state is: {said:?}");
            let status = p.right.items.iter().find_map(|i| match i {
                Item::Line { rect, parts } if *rect == strip.status => Some(parts),
                _ => None,
            });
            assert!(status.is_some_and(|parts| parts.iter().all(|p| p.side != Side::Lead)), "{page:?}");
            for tab in Page::ALL {
                assert!(said.contains(&tab.label().to_string()), "{page:?}: {:?} has its tab", tab);
            }
        }
    }

    /// What starting a supervisor offers moves down with the sentence over
    /// it, every place a press lands with it; on another page it is gone.
    #[test]
    fn what_starting_a_supervisor_offers_moves_with_the_page_and_is_gone_from_the_others() {
        use crate::list::List;
        let l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let theme = crate::look::theme(false);
        let home = String::new();
        // The fixture's groups all have one: this one is made to have none
        // and to be able to start one, as `scene`'s own tests do.
        let mut row = l.rows().find(|r| r.alone.is_none() && r.start.is_some()).unwrap().clone();
        if let Some(st) = row.start.as_mut() {
            st.state = crate::snapshot::SupervisorState::Absent;
            st.can_start = true;
        }
        let row = &row;
        let detail = Detail_::NoSupervisor { group: row.id.clone() };
        let view = scene::StartView { home: &home, ..Default::default() };
        let start = scene::build_start(&detail, Some(row), 600.0, theme, &view, &same);
        let button = start.button.expect("the button is drawn");
        let moved = place_start(start.clone(), &detail, Some(row), Page::Supervisor);
        let inside = scene::terminal_rect(0.0, 0.0);
        assert_eq!(moved.button, Some(Rect { x: button.x + inside.x, y: button.y + inside.y, ..button }));
        assert_eq!(moved.start.map(|r| (r.x, r.y)), start.start.map(|r| (r.x + inside.x, r.y + inside.y)));
        assert_eq!(moved.items, scene::moved(start.items.clone(), inside.x, inside.y));
        // Laid out as wide as the terminal would be.
        assert_eq!(start_width(600.0, &detail, Some(row)), scene::terminal_rect(600.0, 0.0).w);
        assert_eq!(start_width(600.0, &Detail_::NothingSelected, None), 600.0);
        assert_eq!(place_start(start.clone(), &detail, Some(row), Page::Chat), scene::Start::default());
        // No pages: as it was.
        assert_eq!(place_start(start.clone(), &Detail_::NothingSelected, None, Page::Chat), start);
    }

    /// What is said about the group's project is the supervisor's page's:
    /// drawn there and nowhere else, so it never lies over another page.
    #[test]
    fn the_band_about_the_project_is_on_the_supervisors_page_only() {
        use crate::lend::Loan;
        use crate::list::List;
        use crate::project_notice::{band, Notice};
        let l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let with = l.rows().find(|r| r.steward.is_some() && r.alone.is_none()).unwrap();
        let detail = Detail_::Terminal(Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() });
        let theme = crate::look::theme(false);
        let (_, _, w) = scene::notice_origin(600.0);
        let b = band(Notice::Hint { text: "Saved.", undo: Some("Undo") }, w, theme, &|s: &str| 8.0 * s.chars().count() as f64);
        for page in Page::ALL {
            let p = build(&detail, Some(with), 600.0, 700.0, theme, 1.0, false, &same, Some(&b), Some(&view(page)));
            assert_eq!(words(&p.right.items).contains(&"Saved.".to_string()), page.shows_terminal(), "{page:?}");
        }
    }

    /// No supervisor shown here: on its page, what the side said before,
    /// under the strip, with the press moved with it; on the others an
    /// empty frame and the same page rectangle as with a supervisor.
    #[test]
    fn without_a_supervisor_the_side_moves_down_under_the_strip() {
        use crate::lend::Loan;
        use crate::list::List;
        let l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let with = l.rows().find(|r| r.steward.is_some() && r.alone.is_none()).unwrap();
        let detail = Detail_::Elsewhere(Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() });
        let theme = crate::look::theme(false);
        let p = build(&detail, Some(with), 600.0, 700.0, theme, 1.0, false, &same, None, Some(&view(Page::Supervisor)));
        // In the terminal's place: as wide and high as the terminal, at its corner.
        let inside = scene::terminal_rect(600.0, 700.0);
        let under = scene::build_right(&detail, Some(with), inside.w, inside.h, theme, 1.0, false, &same);
        let (r, kind) = under.press.unwrap();
        assert_eq!(p.right.press, Some((Rect { x: r.x + inside.x, y: r.y + inside.y, ..r }, kind)));
        assert!(words(&p.right.items).contains(&scene::msg::GO_THERE.to_string()));

        let p = build(&detail, Some(with), 600.0, 700.0, theme, 1.0, false, &same, None, Some(&view(Page::Tasks)));
        assert_eq!((p.right.press, p.right.terminal, p.right.take_over), (None, None, None));
        assert_eq!(p.page, Some(scene::terminal_rect(600.0, 700.0)));
        assert!(!words(&p.right.items).contains(&scene::msg::GO_THERE.to_string()));
    }

    /// With a supervisor or without, the side is one frame from its top with
    /// the strip in it, and the strip is at the same place (0x4881, group seq
    /// 218: without one, the strip stood on the window over a frame 32
    /// lower).
    #[test]
    fn with_or_without_a_supervisor_the_frame_begins_at_the_top_with_the_strip_in_it() {
        use crate::lend::Loan;
        use crate::list::List;
        let l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let with = l.rows().find(|r| r.steward.is_some() && r.alone.is_none()).unwrap();
        let loan = Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() };
        let theme = crate::look::theme(true);
        let frame = |d: &Detail_, page: Page| {
            let p = build(d, Some(with), 600.0, 700.0, theme, 1.0, false, &same, None, Some(&view(page)));
            let first = match p.right.items.first() {
                Some(Item::Round { rect, color, .. }) => (*rect, *color),
                other => panic!("the frame comes first: {other:?}"),
            };
            (first, p.strip.unwrap().tabs)
        };
        let shown = frame(&Detail_::Terminal(loan.clone()), Page::Supervisor);
        for (d, page) in [
            (Detail_::NoSupervisor { group: with.id.clone() }, Page::Supervisor),
            (Detail_::NoSupervisor { group: with.id.clone() }, Page::Tasks),
            (Detail_::Elsewhere(loan.clone()), Page::Supervisor),
        ] {
            let (f, tabs) = frame(&d, page);
            assert_eq!(f.0, Rect { x: 0.0, y: 0.0, w: 600.0, h: 700.0 }, "{d:?} {page:?}");
            assert_eq!(f.1, shown.0 .1, "{d:?} {page:?}: the bezel's colour, as with a supervisor");
            assert_eq!(tabs.iter().map(|t| t.rect.y).collect::<Vec<_>>(), shown.1.iter().map(|t| t.rect.y).collect::<Vec<_>>());
        }
    }

    /// Nothing selected, a lone terminal, or a host that passes no view:
    /// the side exactly as it was before there were pages.
    #[test]
    fn no_pages_where_there_is_no_group_or_no_view() {
        let theme = crate::look::theme(false);
        let p = build(&Detail_::NothingSelected, None, 600.0, 700.0, theme, 1.0, false, &same, None, Some(&view(Page::Chat)));
        assert_eq!(p.strip, None);
        assert_eq!(p.right, scene::build_right(&Detail_::NothingSelected, None, 600.0, 700.0, theme, 1.0, false, &same));
        use crate::list::List;
        let l = List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let g = l.rows().find(|r| r.alone.is_none()).unwrap();
        let d = Detail_::NoSupervisor { group: g.id.clone() };
        let p = build(&d, Some(g), 600.0, 700.0, theme, 1.0, false, &same, None, None);
        assert_eq!((p.strip, p.page), (None, None));
        assert_eq!(p.right, scene::build_right(&d, Some(g), 600.0, 700.0, theme, 1.0, false, &same));
    }
}
