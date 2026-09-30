//! The settings window's rules, with nothing drawn: which section a route
//! opens, when leaving asks first, how big the window opens, and whether a
//! remembered rectangle is still on a screen.
//!
//! The specification is `dev-docs/poltergeist/settings.md`, shared with the
//! macOS side; section numbers below are that file's.
//!
//! **Why this is a crate of its own.** `polter-host`'s tests compile only for
//! a Windows target and run only on the Windows machine (see
//! `windows/Cargo.toml`), so every rule here would otherwise be one that
//! could be broken on the Mac with everything green. The host's
//! `settings_win.rs` asks these functions and decides nothing itself;
//! `windows/tools/pure-crates-pass-their-tests.py` runs the tests below.

pub mod plugins;

// ================================================================ sections

/// The four sections of the sidebar, in the order they are listed (§2.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Roles,
    Projects,
    Plugins,
    General,
}

impl Section {
    pub const ALL: [Section; 4] = [Section::Roles, Section::Projects, Section::Plugins, Section::General];

    /// The route name (§3.1). **Shared with the macOS side word for word**,
    /// because a route is something both hosts are asked to open.
    pub fn key(self) -> &'static str {
        match self {
            Section::Roles => "roles",
            Section::Projects => "projects",
            Section::Plugins => "plugins",
            Section::General => "general",
        }
    }

    pub fn from_key(k: &str) -> Option<Section> {
        Section::ALL.into_iter().find(|s| s.key() == k)
    }

    /// Whether the section has items to select. `general` has none (§3.1),
    /// so an item named for it is dropped rather than carried around as a
    /// selection that means nothing.
    pub fn has_items(self) -> bool {
        self != Section::General
    }
}

// =================================================================== routes

/// `openSettings(route)` (§3.1): a section and maybe an item in it. No
/// section is the call with no argument, "where I was last".
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Route {
    pub section: Option<Section>,
    pub item: Option<String>,
}

impl Route {
    pub fn none() -> Route {
        Route::default()
    }

    pub fn to(section: Section, item: Option<&str>) -> Route {
        let item = item.filter(|i| !i.is_empty() && section.has_items()).map(str::to_string);
        Route { section: Some(section), item }
    }

    /// `""`, `"roles"`, `"roles/<key>"`. `None` for a section nobody knows,
    /// **not** the no-argument route: a misspelt route opening "wherever I
    /// was" would look like it worked. The item is everything after the
    /// first `/`, so a key may itself contain one.
    pub fn parse(text: &str) -> Option<Route> {
        let text = text.trim();
        if text.is_empty() {
            return Some(Route::none());
        }
        let (sec, item) = match text.split_once('/') {
            Some((s, i)) => (s, Some(i)),
            None => (text, None),
        };
        Some(Route::to(Section::from_key(sec)?, item))
    }
}

impl std::fmt::Display for Route {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match (self.section, &self.item) {
            (None, _) => Ok(()),
            (Some(s), None) => f.write_str(s.key()),
            (Some(s), Some(i)) => write!(f, "{}/{}", s.key(), i),
        }
    }
}

/// Where the window is: a section, and the item in it when the route named
/// one. `item: None` means "whatever the section itself chooses" -- the last
/// one selected, else the first (§3.1) -- which the section knows and this
/// does not.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Place {
    pub section: Section,
    pub item: Option<String>,
}

/// Where a route lands. No section is "where I was last", and the very
/// first opening, with nothing remembered, is the first section.
pub fn resolve(route: &Route, last: Option<&Place>) -> Place {
    match route.section {
        Some(section) => Place { section, item: route.item.clone() },
        None => last.cloned().unwrap_or(Place { section: Section::ALL[0], item: None }),
    }
}

/// Whether going to `target` has to ask "save / don't save / cancel" first
/// (§2.4): only when something is unsaved **and the route points
/// elsewhere**. The same section with no item named is not elsewhere --
/// pressing Ctrl+, again on a half-edited role must not ask about it.
pub fn must_ask(current: Option<&Place>, dirty: bool, target: &Place) -> bool {
    let Some(cur) = current else { return false };
    if !dirty {
        return false;
    }
    if cur.section != target.section {
        return true;
    }
    match &target.item {
        None => false,
        Some(t) => cur.item.as_deref() != Some(t.as_str()),
    }
}

// ========================================================= the unsaved protocol

/// §2.4: what every section with an unsaved state answers. The same three
/// calls on macOS are a protocol.
pub trait Unsaved {
    fn is_dirty(&self) -> bool;
    /// On failure the section shows why itself; the window stays where it is.
    fn save(&mut self) -> Result<(), String>;
    fn revert(&mut self);
}

/// The three answers to "save your changes?".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    Save,
    DontSave,
    Cancel,
}

/// Whether leaving may go ahead, asking only when there is something to
/// lose. **`ask` is not called when nothing is dirty** -- a question with
/// nothing behind it teaches people to click through the one that matters.
///
/// Don't Save **reverts**: a draft left in place would come back dirty the
/// next time the section is shown, and ask again about what was already
/// thrown away. A failed save stays (§2.4: "the window does not close or
/// move").
pub fn leave<U: Unsaved + ?Sized>(u: &mut U, ask: impl FnOnce() -> Answer) -> bool {
    if !u.is_dirty() {
        return true;
    }
    match ask() {
        Answer::Save => u.save().is_ok(),
        Answer::DontSave => {
            u.revert();
            true
        }
        Answer::Cancel => false,
    }
}

// ================================================================= geometry

/// A rectangle in physical pixels, the shape Win32's `RECT` has.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    pub fn new(left: i32, top: i32, right: i32, bottom: i32) -> Rect {
        Rect { left, top, right, bottom }
    }
    pub fn width(&self) -> i32 {
        self.right - self.left
    }
    pub fn height(&self) -> i32 {
        self.bottom - self.top
    }
    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.left && x < self.right && y >= self.top && y < self.bottom
    }
    fn intersect(&self, o: &Rect) -> Option<Rect> {
        let r = Rect::new(self.left.max(o.left), self.top.max(o.top), self.right.min(o.right), self.bottom.min(o.bottom));
        (r.left < r.right && r.top < r.bottom).then_some(r)
    }
}

/// §2.2, in 96-DPI logical pixels.
pub const FIRST_W: i32 = 1180;
pub const FIRST_H: i32 = 800;
pub const MIN_W: i32 = 900;
pub const MIN_H: i32 = 620;

pub fn scale(v: i32, dpi: i32) -> i32 {
    v * dpi / 96
}

/// The smallest the window may be dragged to, at `dpi`.
pub fn min_size(dpi: i32) -> (i32, i32) {
    (scale(MIN_W, dpi), scale(MIN_H, dpi))
}

/// The first opening (§2.2): 1180 × 800 at the monitor's DPI, cut to 90%
/// of the work area in each direction it does not fit, centred.
///
/// **90% wins over the minimum** on a screen too small for both: a window
/// larger than the screen hides its own Save button, which is worse than a
/// sidebar that is narrower than planned.
pub fn first_rect(work: Rect, dpi: i32) -> Rect {
    let w = scale(FIRST_W, dpi).min(work.width() * 9 / 10);
    let h = scale(FIRST_H, dpi).min(work.height() * 9 / 10);
    let left = work.left + (work.width() - w) / 2;
    let top = work.top + (work.height() - h) / 2;
    Rect::new(left, top, left + w, top + h)
}

/// How tall the strip is that has to be on a screen for a remembered
/// rectangle to count as "still there": about a title bar, in physical
/// pixels. A window whose title bar is off every screen cannot be dragged
/// back, which is the case §2.2 falls back for.
const TITLE_STRIP: i32 = 24;
/// How much of that strip has to be showing, across.
const TITLE_SHOWING: i32 = 100;

/// Whether a remembered rectangle is still reachable on one of `works` (each
/// monitor's work area): the top strip is wholly inside one vertically and
/// at least `TITLE_SHOWING` of it across (or all of it, for a narrower one).
///
/// Not "does it touch any monitor": a window with one pixel left on a
/// screen touches it and cannot be grabbed.
pub fn on_some_screen(r: Rect, works: &[Rect]) -> bool {
    screen_of(r, works).is_some()
}

/// The work area a rectangle counts as being on, by the rule above.
fn screen_of(r: Rect, works: &[Rect]) -> Option<Rect> {
    let strip = Rect::new(r.left, r.top, r.right, r.top + TITLE_STRIP);
    let need = TITLE_SHOWING.min(r.width());
    works.iter().copied().find(|w| {
        strip.top >= w.top && strip.bottom <= w.bottom && strip.intersect(w).is_some_and(|i| i.width() >= need)
    })
}

/// A window rectangle moved -- and, if it must, shrunk -- to lie wholly
/// inside `work` (#896: after 96 → 250 dpi the suggested rectangle ran 7
/// pixels past the work area's corner, and was remembered like that). Moved
/// before shrunk: a rectangle that fits is only moved, keeping its size.
pub fn clamp_into(r: Rect, work: Rect) -> Rect {
    let w = r.width().min(work.width());
    let h = r.height().min(work.height());
    let left = r.left.clamp(work.left, work.right - w);
    let top = r.top.clamp(work.top, work.bottom - h);
    Rect::new(left, top, left + w, top + h)
}

/// `clamp_into` the work area `r` is mostly on: the one holding its title
/// strip, else the one it overlaps most, else `r` unchanged (no screens
/// known).
pub fn clamp_onto_screen(r: Rect, works: &[Rect]) -> Rect {
    let area = |w: &Rect| r.intersect(w).map_or(0i64, |i| i.width() as i64 * i.height() as i64);
    let work = screen_of(r, works).or_else(|| works.iter().copied().max_by_key(area).filter(|w| area(w) > 0));
    work.map_or(r, |w| clamp_into(r, w))
}

/// Where the window opens (§2.2): the remembered rectangle when it is still
/// on a screen, else the first-opening rule on `primary_work` at `dpi`.
///
/// A remembered size below today's minimum is grown to it, keeping its
/// corner: the file can be older than the rule, or written by hand. Then
/// the whole is put inside the work area it is on -- a remembered rectangle
/// that ran past the screen's edge comes back inside it.
pub fn opening_rect(saved: Option<Rect>, works: &[Rect], primary_work: Rect, dpi: i32) -> Rect {
    match saved {
        Some(r) if r.width() > 0 && r.height() > 0 => match screen_of(r, works) {
            Some(work) => {
                let (mw, mh) = min_size(dpi);
                clamp_into(Rect::new(r.left, r.top, r.left + r.width().max(mw), r.top + r.height().max(mh)), work)
            }
            None => first_rect(primary_work, dpi),
        },
        _ => first_rect(primary_work, dpi),
    }
}

/// The remembered rectangle, as the file spells it: four integers, left top
/// right bottom. Anything else is no memory at all.
pub fn parse_rect(text: &str) -> Option<Rect> {
    let v: Vec<i32> = text.split_whitespace().map(|t| t.parse().ok()).collect::<Option<_>>()?;
    match v[..] {
        [l, t, r, b] if r > l && b > t => Some(Rect::new(l, t, r, b)),
        _ => None,
    }
}

pub fn format_rect(r: Rect) -> String {
    format!("{} {} {} {}", r.left, r.top, r.right, r.bottom)
}

/// What the window remembers (§2.2): its normal ("restored") rectangle, and
/// whether it was maximized when it closed.
///
/// ⚠️ **Two facts, not one.** Remembering only the rectangle is how a window
/// closed maximized came back carrying the maximized flag over a normal-sized
/// rectangle -- the title bar showed Restore, and the first drag snapped it
/// to another size (#896 D1). Opening now puts it back the way it was:
/// maximized over this rectangle, or normal at it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Saved {
    pub rect: Rect,
    pub maximized: bool,
}

/// The file: `left top right bottom`, then ` max` when it was maximized. A
/// file from before the flag existed is four integers and reads as normal.
pub fn parse_saved(text: &str) -> Option<Saved> {
    let mut words: Vec<&str> = text.split_whitespace().collect();
    let maximized = words.last() == Some(&"max");
    if maximized {
        words.pop();
    }
    Some(Saved { rect: parse_rect(&words.join(" "))?, maximized })
}

pub fn format_saved(s: Saved) -> String {
    if s.maximized {
        format!("{} max", format_rect(s.rect))
    } else {
        format_rect(s.rect)
    }
}

/// How the window opens: the rectangle it is normal at, and whether it is
/// maximized over it. **Maximized only when the remembered rectangle is
/// used** -- a rectangle off every screen falls back to the first-opening
/// rule, and a first opening is never maximized.
pub fn opening(saved: Option<Saved>, works: &[Rect], primary_work: Rect, dpi: i32) -> (Rect, bool) {
    let r = opening_rect(saved.map(|s| s.rect), works, primary_work, dpi);
    let used = saved.is_some_and(|s| on_some_screen(s.rect, works));
    (r, used && saved.is_some_and(|s| s.maximized))
}

/// Screen coordinates to the *workspace* coordinates `WINDOWPLACEMENT`
/// speaks for a top-level window: offset by where the primary monitor's
/// work area starts inside the monitor. The two differ whenever the taskbar
/// is on the top or the left, which is how a placement can land off by the
/// taskbar's height on a machine other than the one it was written on
/// (`session.rs` says the same).
pub fn to_workspace(r: Rect, primary_monitor: Rect, primary_work: Rect) -> Rect {
    let (dx, dy) = (primary_work.left - primary_monitor.left, primary_work.top - primary_monitor.top);
    Rect::new(r.left - dx, r.top - dy, r.right - dx, r.bottom - dy)
}

/// The inverse of `to_workspace`.
pub fn from_workspace(r: Rect, primary_monitor: Rect, primary_work: Rect) -> Rect {
    let (dx, dy) = (primary_work.left - primary_monitor.left, primary_work.top - primary_monitor.top);
    Rect::new(r.left + dx, r.top + dy, r.right + dx, r.bottom + dy)
}

/// Where the keyboard goes when a question ("save your changes?") closes
/// (#896 W35): **back to the control that raised it** -- the list when ↑/↓ in
/// the list asked, the sidebar when the sidebar did -- if that control still
/// exists; else the window. Windows itself gives it to the dialog's owner,
/// the whole window, and the next ↓ then moved the sidebar instead of the
/// list. Handles as integers, so the rule is testable off Windows.
pub fn focus_after_question(before: isize, before_usable: bool, window: isize) -> isize {
    if before != 0 && before_usable {
        before
    } else {
        window
    }
}

/// Whether the process is finished (#896 D3): no terminal window left
/// **and** the settings window not open. The settings window counts as a
/// window: closing the last terminal under it does not take it -- and a
/// draft in it -- away; closing it with no terminal left does.
pub fn quits(terminal_windows_left: usize, settings_open: bool) -> bool {
    terminal_windows_left == 0 && !settings_open
}

// =================================================================== layout

/// The layout grid, §2.3a. **The one place these numbers are written**: the
/// settings window and every section take them from here, and the macOS
/// side's `SettingsLayout` carries the same names and values. All in 96-DPI
/// logical pixels, all multiples of 4 (a test holds that).
pub mod grid {
    /// The top band, full width: the search field on the left, the
    /// breadcrumb on the right, one rule under both.
    pub const TOP: i32 = 52;
    /// The bottom band, full width: one bar with the list's buttons, the
    /// status text and Launch / Revert / Save. Present in every section,
    /// buttons or not, so the body never changes height.
    pub const BOTTOM: i32 = 52;
    pub const SIDEBAR: i32 = 220;
    /// A section's own list of items (roles, projects).
    pub const LIST: i32 = 260;
    /// The outer margin, and **every column's content left edge**: the
    /// column's left line plus `PAD` -- the breadcrumb, the list's item
    /// text and the band's + button all start there (§2.3a).
    pub const PAD: i32 = 16;
    /// The sidebar's own margin: the search field's left and right edges
    /// and the selected row's highlight are both this far in, and the text
    /// inside both is this far in again.
    pub const PAD_SIDEBAR: i32 = 8;
    /// Between one control row and the next.
    pub const ROW_GAP: i32 = 8;
    /// Before a group's heading.
    pub const GROUP_GAP: i32 = 24;
    /// The search field and every button in the bands.
    pub const CONTROL_H: i32 = 28;
    /// A form's label column, right-aligned; the control column starts
    /// `LABEL_GAP` after it. Check boxes and drop-downs go in the control
    /// column too.
    pub const LABEL_W: i32 = 120;
    pub const LABEL_GAP: i32 = 8;
    /// A sidebar row.
    pub const SECTION_ROW_H: i32 = 32;
    /// Between two buttons that belong together (+ ⧉ −).
    pub const BUTTON_GAP: i32 = 4;
    /// Between groups of buttons, and between Launch / Revert / Save.
    pub const BUTTONS_GAP: i32 = 8;
    /// Launch, Revert, Save.
    pub const ACTION_W: [i32; 3] = [112, 96, 96];
    /// A check box's square. Scaled like everything else here: a fixed 16
    /// pixels is how the box stayed 16 at 250% (#896 D2).
    pub const CHECK_BOX: i32 = 16;
    /// Between a check box and its label.
    pub const CHECK_GAP: i32 = 8;

    /// Every value above, for the test that holds them to multiples of 4.
    pub const ALL: [i32; 19] = [
        TOP, BOTTOM, SIDEBAR, LIST, PAD, PAD_SIDEBAR, ROW_GAP, GROUP_GAP, CONTROL_H, LABEL_W, LABEL_GAP, SECTION_ROW_H,
        BUTTON_GAP, BUTTONS_GAP, ACTION_W[0], ACTION_W[1], ACTION_W[2], CHECK_BOX, CHECK_GAP,
    ];
}

use grid::*;

/// The window's grid in a client area `w` × `h`, in pixels. **The only place
/// that decides**: the painter, the click and the sections all ask it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    pub sidebar: Rect,
    /// The search field's frame, `CONTROL_H` tall, centred in the top band.
    pub search: Rect,
    /// The box the breadcrumb's text is laid in: **the same rows as
    /// `search`**, so with the same font the two share a baseline.
    pub breadcrumb: Rect,
    /// One per `Section::ALL`, in order: **the selected highlight's box**,
    /// the same left and right as `search`. A click anywhere across the
    /// sidebar's width on that row counts (`section_at`).
    pub rows: [Rect; 4],
    /// Where the text in the sidebar starts: the search field's text and the
    /// rows' labels.
    pub sidebar_text_left: i32,
    /// Where the text in the content column starts: the column's left line
    /// plus `PAD`. The breadcrumb starts here, and so do a section's list
    /// item text and its + button (`SectionGrid::text_left`, in the
    /// section's coordinates).
    pub content_text_left: i32,
    /// The rule under the top band: one line, the whole width.
    pub top_rule: Rect,
    /// The rule over the bottom band: one line, the whole width.
    pub bottom_rule: Rect,
    /// The line between the sidebar and the content, top to bottom, through
    /// both bands -- the only vertical line the bands have.
    pub divider: Rect,
    /// What a section owns: the content column from under the top rule to
    /// the window's bottom, **bottom band included**, so a section's own
    /// buttons can sit in it. `section_grid` lays it out.
    pub content: Rect,
}

pub fn layout(w: i32, h: i32, dpi: i32) -> Layout {
    let s = |v| scale(v, dpi);
    let side = s(SIDEBAR);
    let left = side + 1;
    let right = w.max(left + 2 * s(PAD));
    let top = s(TOP);
    let bottom_rule_top = h - s(BOTTOM) - 1;
    let ctl_top = (top - s(CONTROL_H)) / 2;
    let ctl_bottom = ctl_top + s(CONTROL_H);
    let search = Rect::new(s(PAD_SIDEBAR), ctl_top, side - s(PAD_SIDEBAR), ctl_bottom);
    let breadcrumb = Rect::new(left + s(PAD), ctl_top, right - s(PAD), ctl_bottom);
    let top_rule = Rect::new(0, top, right, top + 1);
    let bottom_rule = Rect::new(0, bottom_rule_top, right, bottom_rule_top + 1);
    let divider = Rect::new(side, 0, side + 1, h);
    let first = top_rule.bottom + s(ROW_GAP);
    let rows = [0, 1, 2, 3].map(|i| {
        let t = first + i * s(SECTION_ROW_H);
        Rect::new(search.left, t, search.right, t + s(SECTION_ROW_H))
    });
    let sidebar = Rect::new(0, 0, side, h);
    let content = Rect::new(left, top_rule.bottom, right, h.max(top_rule.bottom));
    let sidebar_text_left = search.left + s(PAD_SIDEBAR);
    let content_text_left = left + s(PAD);
    Layout { sidebar, search, breadcrumb, rows, sidebar_text_left, content_text_left, top_rule, bottom_rule, divider, content }
}

/// A section's grid, in its own coordinates: `w` × `h` is `Layout::content`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SectionGrid {
    /// The item list, when the section has one.
    pub list: Option<Rect>,
    /// The line between the list and the editor, body only.
    pub list_divider: Option<Rect>,
    /// Everything right of the list, down to the bottom rule.
    pub editor: Rect,
    /// The same line as `Layout::bottom_rule`, in this section's coordinates.
    pub bottom_rule: Rect,
    /// The bottom band under it.
    pub band: Rect,
    /// + ⧉ −, from the list's left edge plus `PAD`.
    pub list_buttons: Option<[Rect; 3]>,
    /// Between the list's buttons and Launch.
    pub status: Rect,
    /// Where the list's item text starts, in this section's coordinates:
    /// `PAD` from the list's left line, like the + button under it.
    pub text_left: i32,
    /// Launch, Revert, Save, right-aligned.
    pub actions: [Rect; 3],
}

pub fn section_grid(w: i32, h: i32, dpi: i32, has_list: bool) -> SectionGrid {
    let s = |v| scale(v, dpi);
    let body_bottom = (h - s(BOTTOM) - 1).max(0);
    let bottom_rule = Rect::new(0, body_bottom, w, body_bottom + 1);
    let band = Rect::new(0, bottom_rule.bottom, w, h.max(bottom_rule.bottom));
    let btn_top = band.top + (s(BOTTOM) - s(CONTROL_H)) / 2;
    let btn = |l: i32, width: i32| Rect::new(l, btn_top, l + width, btn_top + s(CONTROL_H));
    let (list, list_divider, editor_left) = if has_list {
        let lw = s(LIST);
        (Some(Rect::new(0, 0, lw, body_bottom)), Some(Rect::new(lw, 0, lw + 1, body_bottom)), lw + 1)
    } else {
        (None, None, 0)
    };
    let editor = Rect::new(editor_left, 0, w.max(editor_left), body_bottom);
    let list_buttons = has_list.then(|| {
        [0, 1, 2].map(|i| btn(s(PAD) + i * (s(CONTROL_H) + s(BUTTON_GAP)), s(CONTROL_H)))
    });
    let save = btn(w - s(PAD) - s(ACTION_W[2]), s(ACTION_W[2]));
    let revert = btn(save.left - s(BUTTONS_GAP) - s(ACTION_W[1]), s(ACTION_W[1]));
    let launch = btn(revert.left - s(BUTTONS_GAP) - s(ACTION_W[0]), s(ACTION_W[0]));
    let status_left = list_buttons.map_or(s(PAD), |b| b[2].right + s(PAD));
    let status = Rect::new(status_left, band.top, (launch.left - s(PAD)).max(status_left), band.bottom);
    let text_left = s(PAD);
    SectionGrid { list, list_divider, editor, bottom_rule, band, list_buttons, status, text_left, actions: [launch, revert, save] }
}

/// What a window's frame takes from its outer size, in 96-DPI pixels: the
/// sizing borders and the caption at Windows 10/11's standard metrics. An
/// allowance, not a measurement -- the minimum track size is an outer size,
/// and a section is laid out in what is left inside.
pub const FRAME_ALLOW_W: i32 = 16;
pub const FRAME_ALLOW_H: i32 = 39;

/// The area a section is given (`Layout::content`, bottom band included)
/// when the window's outer size is `outer_w` × `outer_h`, in 96-DPI pixels.
/// **What a section's own layout tests are run at**, so "nothing is cut off
/// at the minimum" (§2.2) is asked of the size the section really gets.
pub const fn content_size(outer_w: i32, outer_h: i32) -> (i32, i32) {
    (outer_w - FRAME_ALLOW_W - SIDEBAR - 1, outer_h - FRAME_ALLOW_H - TOP - 1)
}

/// A check box's square, at `dpi`, in a control `row_h` tall: the grid's
/// size scaled, never taller than the row.
pub fn check_box(dpi: i32, row_h: i32) -> i32 {
    scale(CHECK_BOX, dpi).min(row_h).max(1)
}

/// Which section row a click at `(x, y)` is on.
pub fn section_at(l: &Layout, x: i32, y: i32) -> Option<Section> {
    if x < l.sidebar.left || x >= l.sidebar.right {
        return None;
    }
    l.rows.iter().position(|r| y >= r.top && y < r.bottom).map(|i| Section::ALL[i])
}

/// The line above the content (§2.3): `Section › item`, or the section
/// alone when there is no item.
pub fn breadcrumb(section_label: &str, item_label: Option<&str>) -> String {
    match item_label.filter(|i| !i.is_empty()) {
        Some(i) => format!("{section_label} \u{203a} {i}"),
        None => section_label.to_string(),
    }
}

/// The item's name when the search has hidden it from its list (§2.3a):
/// the translated sentence, `{}` standing for the name. The macOS side's
/// msgid spells the same sentence with `%@`; each side keeps its own
/// placeholder, as `Role (beta): {}` already does.
pub fn hidden_item(sentence: &str, name: &str) -> String {
    sentence.replacen("{}", name, 1)
}

/// ↑ / ↓ in a list of `len` rows (§2.3a: the keys must not be lost):
/// the next or previous row, **stopping at the ends** rather than wrapping.
/// From nothing selected, ↓ is the first row and ↑ the last. `None` for an
/// empty list.
pub fn step(current: Option<usize>, len: usize, down: bool) -> Option<usize> {
    if len == 0 {
        return None;
    }
    Some(match (current.filter(|&i| i < len), down) {
        (None, true) => 0,
        (None, false) => len - 1,
        (Some(i), true) => (i + 1).min(len - 1),
        (Some(i), false) => i.saturating_sub(1),
    })
}

/// The first row shown, moved as little as possible so row `index` is on
/// screen when `fit` rows fit.
pub fn keep_visible(top: usize, index: usize, fit: usize) -> usize {
    let fit = fit.max(1);
    if index < top {
        index
    } else if index >= top + fit {
        index + 1 - fit
    } else {
        top
    }
}

/// ↑ / ↓ in the sidebar: the section above or below, stopping at the ends.
pub fn step_section(current: Option<Section>, down: bool) -> Section {
    let i = current.and_then(|c| Section::ALL.iter().position(|s| *s == c));
    Section::ALL[step(i, Section::ALL.len(), down).unwrap_or(0)]
}

/// What a filtered list says about itself (§2.3a): **never a blank list
/// beside a filled editor.**
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Filtered {
    /// Draw the "no matching …" row: a query is typed and nothing in the
    /// list answers it.
    pub no_match_row: bool,
    /// Add "(not in search results)" to the breadcrumb: the item on screen
    /// is one the query hid.
    pub selection_hidden: bool,
}

/// `visible` is how many items the query left; `selected_visible` whether
/// the one on screen is among them (`None` with nothing selected).
pub fn filtered(query: &str, visible: usize, selected_visible: Option<bool>) -> Filtered {
    let active = !query.trim().is_empty();
    Filtered { no_match_row: active && visible == 0, selection_hidden: active && selected_visible == Some(false) }
}

/// Whether a name answers the search box: contains the query, ignoring
/// case. An empty query matches everything -- an empty box is no filter.
/// **One rule** for the jump below and for the lists it narrows, so a
/// section is never jumped to for a name its own list then hides.
pub fn matches(query: &str, name: &str) -> bool {
    let q = query.trim().to_lowercase();
    q.is_empty() || name.to_lowercase().contains(&q)
}

/// Which section the sidebar's search jumps to (§2.3): the first, in sidebar
/// order, with an item whose name contains the query, ignoring case. An
/// empty query jumps nowhere. Phase 1 passes only the roles.
pub fn search_target(query: &str, items: &[(Section, Vec<String>)]) -> Option<Section> {
    if query.trim().is_empty() {
        return None;
    }
    Section::ALL
        .into_iter()
        .find(|s| items.iter().any(|(sec, names)| sec == s && names.iter().any(|n| matches(query, n))))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ------------------------------------------------------------ routes

    #[test]
    fn route_names_are_the_shared_four() {
        let keys: Vec<_> = Section::ALL.iter().map(|s| s.key()).collect();
        assert_eq!(keys, ["roles", "projects", "plugins", "general"]);
    }

    #[test]
    fn route_parses_section_and_item() {
        assert_eq!(Route::parse(""), Some(Route::none()));
        assert_eq!(Route::parse("roles"), Some(Route { section: Some(Section::Roles), item: None }));
        assert_eq!(
            Route::parse("roles/reviewer"),
            Some(Route { section: Some(Section::Roles), item: Some("reviewer".into()) })
        );
        assert_eq!(
            Route::parse("plugins/feishu/x"),
            Some(Route { section: Some(Section::Plugins), item: Some("feishu/x".into()) })
        );
        // An empty item is no item: `roles/` from a terminal with no role.
        assert_eq!(Route::parse("roles/"), Some(Route { section: Some(Section::Roles), item: None }));
    }

    #[test]
    fn unknown_section_is_refused_not_opened_as_last() {
        assert_eq!(Route::parse("role"), None);
        assert_eq!(Route::parse("Roles"), None);
    }

    #[test]
    fn general_carries_no_item() {
        assert_eq!(Route::parse("general/x"), Some(Route { section: Some(Section::General), item: None }));
    }

    #[test]
    fn route_round_trips_through_display() {
        for t in ["", "roles", "roles/reviewer", "projects/a b", "general"] {
            assert_eq!(Route::parse(t).unwrap().to_string(), t);
        }
    }

    #[test]
    fn no_argument_route_goes_back_to_last_place() {
        let last = Place { section: Section::Plugins, item: Some("slack".into()) };
        assert_eq!(resolve(&Route::none(), Some(&last)), last);
        assert_eq!(resolve(&Route::none(), None), Place { section: Section::Roles, item: None });
        let r = Route::to(Section::Roles, Some("dev"));
        assert_eq!(resolve(&r, Some(&last)), Place { section: Section::Roles, item: Some("dev".into()) });
    }

    // ------------------------------------------------------------ asking

    fn at(s: Section, i: Option<&str>) -> Place {
        Place { section: s, item: i.map(str::to_string) }
    }

    #[test]
    fn nothing_dirty_never_asks() {
        assert!(!must_ask(Some(&at(Section::Roles, Some("a"))), false, &at(Section::General, None)));
    }

    #[test]
    fn dirty_asks_when_the_route_points_elsewhere() {
        let cur = at(Section::Roles, Some("a"));
        assert!(must_ask(Some(&cur), true, &at(Section::General, None)));
        assert!(must_ask(Some(&cur), true, &at(Section::Roles, Some("b"))));
    }

    #[test]
    fn dirty_does_not_ask_for_where_it_already_is() {
        let cur = at(Section::Roles, Some("a"));
        assert!(!must_ask(Some(&cur), true, &at(Section::Roles, Some("a"))));
        // Ctrl+, again, or the menu row with no item.
        assert!(!must_ask(Some(&cur), true, &at(Section::Roles, None)));
        // Nothing is on screen yet.
        assert!(!must_ask(None, true, &at(Section::Roles, Some("b"))));
    }

    struct Fake {
        dirty: bool,
        save_ok: bool,
        saved: u32,
        reverted: u32,
    }
    impl Unsaved for Fake {
        fn is_dirty(&self) -> bool {
            self.dirty
        }
        fn save(&mut self) -> Result<(), String> {
            self.saved += 1;
            if self.save_ok {
                self.dirty = false;
                Ok(())
            } else {
                Err("no".into())
            }
        }
        fn revert(&mut self) {
            self.reverted += 1;
            self.dirty = false;
        }
    }
    fn fake(dirty: bool, save_ok: bool) -> Fake {
        Fake { dirty, save_ok, saved: 0, reverted: 0 }
    }

    #[test]
    fn leave_does_not_ask_when_clean() {
        let mut f = fake(false, true);
        assert!(leave(&mut f, || panic!("asked with nothing unsaved")));
    }

    #[test]
    fn leave_save_goes_only_when_the_save_worked() {
        let mut ok = fake(true, true);
        assert!(leave(&mut ok, || Answer::Save));
        assert_eq!((ok.saved, ok.reverted), (1, 0));
        let mut bad = fake(true, false);
        assert!(!leave(&mut bad, || Answer::Save));
        assert!(bad.dirty, "a failed save keeps the draft");
    }

    #[test]
    fn leave_dont_save_reverts() {
        let mut f = fake(true, true);
        assert!(leave(&mut f, || Answer::DontSave));
        assert_eq!((f.saved, f.reverted), (0, 1));
        assert!(!f.is_dirty());
    }

    #[test]
    fn leave_cancel_stays_and_keeps_the_draft() {
        let mut f = fake(true, true);
        assert!(!leave(&mut f, || Answer::Cancel));
        assert_eq!((f.saved, f.reverted, f.dirty), (0, 0, true));
    }

    // ---------------------------------------------------------- geometry

    const WORK: Rect = Rect { left: 0, top: 0, right: 1920, bottom: 1040 };

    #[test]
    fn first_opening_is_1180_by_800_centred() {
        let r = first_rect(WORK, 96);
        assert_eq!((r.width(), r.height()), (1180, 800));
        assert_eq!((r.left, r.top), ((1920 - 1180) / 2, (1040 - 800) / 2));
    }

    #[test]
    fn first_opening_scales_with_dpi() {
        let big = Rect::new(0, 0, 3840, 2100);
        let r = first_rect(big, 144);
        assert_eq!((r.width(), r.height()), (1770, 1200));
    }

    #[test]
    fn first_opening_is_cut_to_ninety_percent() {
        let small = Rect::new(0, 0, 1280, 720);
        let r = first_rect(small, 96);
        assert_eq!((r.width(), r.height()), (1152, 648));
        // 150% on the same screen: both directions are cut.
        let r = first_rect(small, 144);
        assert_eq!((r.width(), r.height()), (1152, 648));
    }

    #[test]
    fn first_opening_centres_on_a_second_monitor() {
        let right = Rect::new(1920, 0, 3840, 1040);
        let r = first_rect(right, 96);
        assert!(r.left >= 1920 && r.right <= 3840);
    }

    #[test]
    fn minimum_scales_with_dpi() {
        assert_eq!(min_size(96), (900, 620));
        assert_eq!(min_size(192), (1800, 1240));
    }

    #[test]
    fn a_rect_on_screen_is_restored_as_it_was() {
        let saved = Rect::new(100, 50, 1300, 900);
        assert_eq!(opening_rect(Some(saved), &[WORK], WORK, 96), saved);
    }

    #[test]
    fn a_rect_on_a_monitor_that_is_gone_falls_back() {
        // Remembered on a second monitor to the right; only one is left.
        let saved = Rect::new(2000, 100, 3100, 900);
        assert_eq!(opening_rect(Some(saved), &[WORK], WORK, 96), first_rect(WORK, 96));
        // The same rect with the monitor back is restored.
        let second = Rect::new(1920, 0, 3840, 1040);
        assert_eq!(opening_rect(Some(saved), &[WORK, second], WORK, 96), saved);
    }

    #[test]
    fn a_title_bar_off_every_screen_falls_back() {
        // Touching the screen, but the title bar is above it.
        let above = Rect::new(100, -300, 1300, 500);
        assert!(!on_some_screen(above, &[WORK]));
        // One sliver showing on the right edge.
        let sliver = Rect::new(1900, 100, 3000, 900);
        assert!(!on_some_screen(sliver, &[WORK]));
        assert_eq!(opening_rect(Some(sliver), &[WORK], WORK, 96), first_rect(WORK, 96));
    }

    #[test]
    fn a_remembered_rect_below_the_minimum_is_grown() {
        let saved = Rect::new(10, 10, 410, 310);
        assert_eq!(opening_rect(Some(saved), &[WORK], WORK, 96), Rect::new(10, 10, 910, 630));
    }

    /// #896 third round: after 96 → 250 dpi the window was 657,111
    /// 2950×2000 on a 3600×2104 work area -- 7 past the bottom-right -- and
    /// was remembered so. Both the suggested and the remembered rectangle
    /// are put inside the work area.
    #[test]
    fn a_rectangle_past_the_work_area_is_brought_inside() {
        let work = Rect::new(0, 0, 3600, 2104);
        let r = Rect::new(657, 111, 657 + 2950, 111 + 2000);
        let c = clamp_onto_screen(r, &[work]);
        assert_eq!((c.width(), c.height()), (2950, 2000), "moved, not shrunk, when it fits");
        assert!(c.right <= work.right && c.bottom <= work.bottom && c.left >= 0 && c.top >= 0, "{c:?}");
        assert_eq!(c, Rect::new(650, 104, 3600, 2104));
        // Remembered like that: opens inside.
        assert_eq!(opening_rect(Some(r), &[work], work, 240), c);
        // Larger than the work area: shrunk to it.
        assert_eq!(clamp_into(Rect::new(-50, -50, 4000, 3000), work), work);
        // Already inside: untouched.
        let inside = Rect::new(100, 100, 900, 700);
        assert_eq!(clamp_onto_screen(inside, &[work]), inside);
        // Two screens: kept on the one it is on.
        let right = Rect::new(3600, 0, 5520, 1040);
        let on_right = Rect::new(4000, 100, 5600, 900);
        assert_eq!(clamp_onto_screen(on_right, &[work, right]), Rect::new(3920, 100, 5520, 900));
        // No screens known: unchanged.
        assert_eq!(clamp_onto_screen(r, &[]), r);
    }

    #[test]
    fn nothing_remembered_is_the_first_opening() {
        assert_eq!(opening_rect(None, &[WORK], WORK, 96), first_rect(WORK, 96));
    }

    #[test]
    fn the_maximized_flag_is_remembered_and_old_files_still_read() {
        let r = Rect::new(100, 50, 1300, 900);
        for maximized in [true, false] {
            let s = Saved { rect: r, maximized };
            assert_eq!(parse_saved(&format_saved(s)), Some(s));
        }
        assert_eq!(parse_saved("100 50 1300 900"), Some(Saved { rect: r, maximized: false }), "a file from before the flag");
        assert_eq!(parse_saved("max"), None);
        assert_eq!(parse_saved("1 2 3 max"), None);
    }

    /// #896 D1: closed maximized, it opens maximized over its normal
    /// rectangle; closed normal, it opens normal; off every screen, neither.
    #[test]
    fn it_opens_the_way_it_closed() {
        let r = Rect::new(100, 50, 1300, 900);
        assert_eq!(opening(Some(Saved { rect: r, maximized: true }), &[WORK], WORK, 96), (r, true));
        assert_eq!(opening(Some(Saved { rect: r, maximized: false }), &[WORK], WORK, 96), (r, false));
        let gone = Rect::new(2000, 100, 3100, 900);
        assert_eq!(opening(Some(Saved { rect: gone, maximized: true }), &[WORK], WORK, 96), (first_rect(WORK, 96), false));
        assert_eq!(opening(None, &[WORK], WORK, 96), (first_rect(WORK, 96), false));
    }

    #[test]
    fn workspace_coordinates_move_by_the_taskbar_on_top_or_left() {
        let r = Rect::new(100, 150, 900, 750);
        let mon = Rect::new(0, 0, 1920, 1080);
        // Taskbar at the bottom: the same.
        assert_eq!(to_workspace(r, mon, Rect::new(0, 0, 1920, 1040)), r);
        // Taskbar on top, 40 tall: 40 up.
        assert_eq!(to_workspace(r, mon, Rect::new(0, 40, 1920, 1080)), Rect::new(100, 110, 900, 710));
        // On the left, 60 wide: 60 left.
        assert_eq!(to_workspace(r, mon, Rect::new(60, 0, 1920, 1080)), Rect::new(40, 150, 840, 750));
        let work = Rect::new(60, 40, 1920, 1080);
        assert_eq!(from_workspace(to_workspace(r, mon, work), mon, work), r);
    }

    /// #896 W35.
    #[test]
    fn a_question_gives_the_keyboard_back_to_whoever_asked() {
        assert_eq!(focus_after_question(0x100, true, 0x900), 0x100, "the list asked; the list gets it");
        assert_eq!(focus_after_question(0x100, false, 0x900), 0x900, "gone: the window");
        assert_eq!(focus_after_question(0, true, 0x900), 0x900, "nobody had it: the window");
    }

    /// #896 D3.
    #[test]
    fn the_settings_window_keeps_the_process_alive() {
        assert!(quits(0, false));
        assert!(!quits(0, true), "the last terminal closed under the settings window");
        assert!(!quits(1, false));
        assert!(!quits(2, true));
    }

    /// #896 D2: the check box grows with the DPI (40 at 250%), and never
    /// out of its row.
    #[test]
    fn the_check_box_scales_with_the_dpi() {
        assert_eq!(check_box(96, 28), 16);
        assert_eq!(check_box(144, 42), 24);
        assert_eq!(check_box(240, 70), 40);
        assert_eq!(check_box(240, 30), 30);
    }

    #[test]
    fn rect_file_round_trips_and_refuses_junk() {
        let r = Rect::new(-1910, 20, -700, 840);
        assert_eq!(parse_rect(&format_rect(r)), Some(r));
        assert_eq!(parse_rect("1 2 3"), None);
        assert_eq!(parse_rect("10 10 5 20"), None);
        assert_eq!(parse_rect("a b c d"), None);
        assert_eq!(parse_rect(""), None);
    }

    // ------------------------------------------------------------ layout

    #[test]
    fn every_grid_value_is_a_multiple_of_four() {
        for v in grid::ALL {
            assert_eq!(v % 4, 0, "{v}");
        }
    }

    /// Sizes and DPIs the grid is checked at.
    fn cases() -> Vec<(i32, i32, i32)> {
        let mut out = Vec::new();
        for dpi in [96, 120, 144, 168, 192] {
            for (w, h) in [(884, 581), (1164, 761), (1917, 1017)] {
                out.push((w * dpi / 96, h * dpi / 96, dpi));
            }
        }
        out
    }

    /// §2.3a's criterion ①/②/③/④ as far as the grid decides it: one top
    /// rule and one bottom rule across the whole width, the section's bottom
    /// rule on the very same row, search and breadcrumb on the same rows,
    /// every vertical line one piece from its top to its bottom.
    #[test]
    fn the_bands_and_lines_line_up_across_window_and_section() {
        for (w, h, dpi) in cases() {
            let l = layout(w, h, dpi);
            let g = section_grid(l.content.width(), l.content.height(), dpi, true);
            let at = format!("{w}x{h} at {dpi}");
            // ① one rule under the top band, the whole width; the section
            // starts right under it.
            assert_eq!((l.top_rule.left, l.top_rule.right, l.top_rule.height()), (0, l.content.right, 1), "{at}");
            assert_eq!(l.top_rule.top, scale(TOP, dpi), "{at}");
            assert_eq!(l.content.top, l.top_rule.bottom, "{at}");
            // ② the section's bottom rule is the window's, row for row.
            assert_eq!(l.content.top + g.bottom_rule.top, l.bottom_rule.top, "{at}");
            assert_eq!((g.bottom_rule.left, g.bottom_rule.right), (0, l.content.width()), "{at}");
            assert_eq!(l.content.bottom - l.bottom_rule.bottom, scale(BOTTOM, dpi), "{at}");
            assert_eq!(g.band.height(), scale(BOTTOM, dpi), "{at}");
            // ③ search and breadcrumb share their rows, centred in the band.
            assert_eq!((l.search.top, l.search.bottom), (l.breadcrumb.top, l.breadcrumb.bottom), "{at}");
            assert_eq!(l.search.height(), scale(CONTROL_H, dpi), "{at}");
            assert_eq!(l.search.top, l.top_rule.top - l.search.bottom, "{at}");
            // ④ the sidebar divider runs the whole height; the list divider
            // runs exactly from the top rule to the bottom rule.
            assert_eq!((l.divider.top, l.divider.bottom, l.divider.width()), (0, h, 1), "{at}");
            assert_eq!(l.divider.right, l.content.left, "{at}");
            let d = g.list_divider.unwrap();
            assert_eq!((l.content.top + d.top, l.content.top + d.bottom), (l.top_rule.bottom, l.bottom_rule.top), "{at}");
            assert_eq!(d.width(), 1, "{at}");
            // The bottom band's buttons are one row, centred.
            let b = g.list_buttons.unwrap();
            for r in b.iter().chain(g.actions.iter()) {
                assert_eq!((r.top, r.height()), (b[0].top, scale(CONTROL_H, dpi)), "{at}");
                assert_eq!(r.top - g.band.top, g.band.bottom - r.bottom, "{at}");
            }
            // + ⧉ − start at the list's left edge plus PAD; Save ends PAD
            // from the right; nothing overlaps.
            assert_eq!(b[0].left, g.list.unwrap().left + scale(PAD, dpi), "{at}");
            assert_eq!(g.actions[2].right, l.content.width() - scale(PAD, dpi), "{at}");
            assert!(b[2].right <= g.status.left && g.status.right <= g.actions[0].left, "{at}");
            assert!(g.actions[0].right < g.actions[1].left && g.actions[1].right < g.actions[2].left, "{at}");
        }
    }

    #[test]
    fn a_section_without_a_list_still_has_the_band_and_the_rule() {
        let l = layout(1164, 761, 96);
        let g = section_grid(l.content.width(), l.content.height(), 96, false);
        assert!(g.list.is_none() && g.list_buttons.is_none() && g.list_divider.is_none());
        assert_eq!(l.content.top + g.bottom_rule.top, l.bottom_rule.top);
        assert_eq!(g.editor.left, 0);
        assert_eq!(g.editor.bottom, g.bottom_rule.top);
    }

    #[test]
    fn section_rows_are_found_by_the_click() {
        let l = layout(1164, 761, 96);
        for (i, r) in l.rows.iter().enumerate() {
            assert_eq!(section_at(&l, r.left + 5, r.top + 1), Some(Section::ALL[i]));
        }
        assert_eq!(section_at(&l, 5, l.search.top), None);
        assert_eq!(section_at(&l, 500, l.rows[0].top + 1), None);
        assert!(l.rows[0].top > l.top_rule.bottom);
    }

    /// §2.3a: at the minimum window the editor keeps about 420.
    #[test]
    fn at_the_minimum_the_editor_keeps_about_420() {
        let (w, h) = content_size(MIN_W, MIN_H);
        let g = section_grid(w, h, 96, true);
        assert!(g.editor.width() >= 400, "{}", g.editor.width());
        assert!(g.status.width() > 0);
        let l = layout(MIN_W - FRAME_ALLOW_W, MIN_H - FRAME_ALLOW_H, 96);
        assert_eq!((w, h), (l.content.width(), l.content.height()));
        assert!(l.rows[3].bottom < l.bottom_rule.top);
    }

    #[test]
    fn breadcrumb_names_the_item_when_there_is_one() {
        assert_eq!(breadcrumb("角色", Some("审查员")), "角色 › 审查员");
        assert_eq!(breadcrumb("通用", None), "通用");
        assert_eq!(breadcrumb("角色", Some("")), "角色");
        let hidden = hidden_item("{}（不在搜索结果里）", "审查员");
        assert_eq!(breadcrumb("角色", Some(&hidden)), "角色 › 审查员（不在搜索结果里）");
        assert_eq!(hidden_item("{} (not in the search results)", "Reviewer"), "Reviewer (not in the search results)");
    }

    #[test]
    fn arrows_step_and_stop_at_the_ends() {
        assert_eq!(step(Some(1), 3, true), Some(2));
        assert_eq!(step(Some(2), 3, true), Some(2), "no wrap at the bottom");
        assert_eq!(step(Some(1), 3, false), Some(0));
        assert_eq!(step(Some(0), 3, false), Some(0), "no wrap at the top");
        assert_eq!(step(None, 3, true), Some(0));
        assert_eq!(step(None, 3, false), Some(2));
        assert_eq!(step(Some(7), 3, true), Some(0), "a stale index is no selection");
        assert_eq!(step(None, 0, true), None);
    }

    #[test]
    fn the_selected_row_is_scrolled_into_view() {
        assert_eq!(keep_visible(0, 3, 5), 0);
        assert_eq!(keep_visible(0, 5, 5), 1, "one past the bottom scrolls by one");
        assert_eq!(keep_visible(4, 9, 5), 5);
        assert_eq!(keep_visible(4, 2, 5), 2, "above the top scrolls up to it");
        assert_eq!(keep_visible(3, 3, 0), 3);
    }

    #[test]
    fn arrows_in_the_sidebar_move_between_sections() {
        assert_eq!(step_section(Some(Section::Roles), true), Section::Projects);
        assert_eq!(step_section(Some(Section::General), true), Section::General);
        assert_eq!(step_section(Some(Section::Projects), false), Section::Roles);
        assert_eq!(step_section(None, true), Section::Roles);
    }

    /// §2.3a: a search never leaves a blank list beside a filled editor.
    #[test]
    fn a_search_that_hides_things_says_so() {
        // Nothing matches, and the selection is hidden with it.
        assert_eq!(filtered("角色", 0, Some(false)), Filtered { no_match_row: true, selection_hidden: true });
        // Others match; only the selection is hidden.
        assert_eq!(filtered("dev", 2, Some(false)), Filtered { no_match_row: false, selection_hidden: true });
        // The selection is among the matches.
        assert_eq!(filtered("dev", 2, Some(true)), Filtered { no_match_row: false, selection_hidden: false });
        // No query: nothing to say, whatever the counts.
        assert_eq!(filtered(" ", 0, Some(false)), Filtered { no_match_row: false, selection_hidden: false });
        // Nothing selected: nothing hidden.
        assert_eq!(filtered("x", 0, None), Filtered { no_match_row: true, selection_hidden: false });
    }

    /// §2.3a: one left edge per column. The breadcrumb, the list's item
    /// text and the + button share an x; in the sidebar the search field
    /// and the highlight share both edges, and the text in them an x.
    #[test]
    fn every_column_has_one_left_edge() {
        for (w, h, dpi) in cases() {
            let l = layout(w, h, dpi);
            let g = section_grid(l.content.width(), l.content.height(), dpi, true);
            let at = format!("{w}x{h} at {dpi}");
            assert_eq!(l.breadcrumb.left, l.content_text_left, "{at}");
            assert_eq!(l.content_text_left, l.content.left + g.text_left, "{at}");
            assert_eq!(l.content.left + g.list_buttons.unwrap()[0].left, l.content_text_left, "{at}");
            assert_eq!(l.content_text_left - l.divider.right, scale(PAD, dpi), "{at}");
            for r in l.rows {
                assert_eq!((r.left, r.right), (l.search.left, l.search.right), "{at}");
            }
            assert_eq!(l.search.left, scale(PAD_SIDEBAR, dpi), "{at}");
            assert_eq!(l.sidebar.right - l.search.right, scale(PAD_SIDEBAR, dpi), "{at}");
            assert_eq!(l.sidebar_text_left, l.search.left + scale(PAD_SIDEBAR, dpi), "{at}");
        }
    }

    #[test]
    fn an_empty_query_matches_everything_and_case_is_ignored() {
        assert!(matches("", "anything"));
        assert!(matches("  ", "anything"));
        assert!(matches("rev", "Reviewer"));
        assert!(!matches("xyz", "Reviewer"));
    }

    #[test]
    fn search_jumps_to_the_first_section_with_a_match() {
        let items = vec![
            (Section::Roles, vec!["Reviewer".to_string(), "审查员".to_string()]),
            (Section::Plugins, vec!["review-bot".to_string()]),
        ];
        assert_eq!(search_target("REVIEW", &items), Some(Section::Roles));
        assert_eq!(search_target("审查", &items), Some(Section::Roles));
        assert_eq!(search_target("bot", &items), Some(Section::Plugins));
        assert_eq!(search_target("nothing", &items), None);
        assert_eq!(search_target("  ", &items), None);
    }
}
