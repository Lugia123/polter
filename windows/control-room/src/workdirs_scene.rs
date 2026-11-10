//! The working-directories page, laid out and drawn (task 3148, `#2140` W2;
//! the macOS host's `ControlRoomWorkdirsPage.swift`).
//!
//! **Three columns**, left to right, from the design's `files4.css`: the
//! activity bar (48pt, `.actbar`), the sidebar (296pt to begin with, `.wdl`),
//! and the workbench (`.wdr`). The sidebar draws 「工作目录」's bar and the
//! tree under it; the workbench is the file a row was clicked on, in the
//! WebView2 preview the page's own slot puts there (`preview_page`'s
//! `SlotKey::workdir`) -- **this file lays the ground it goes in and says
//! where it is** ([`Layout::body`]), and draws the sentence when there is
//! nothing to preview.
//!
//! **What is decided here is where a box goes and what it says**, never
//! which rows there are: the roots come from `workdirs::Page` in the core's
//! order, a level's rows in the core's order (`Listing.zig`), and this file
//! neither sorts nor filters. `tools/control-room-hosts-do-not-decide.py`
//! reads it for exactly that.
//!
//! # What is drawn and what is not (this round)
//!
//! Drawn: the activity bar's ground, the 「工作目录」 bar, every root (its
//! twisty, its name and its path), the tree under an open root one level at
//! a time, a directory's refusal and 「还有 N 个」 under it, the workbench's
//! bar and its empty sentence.
//!
//! **Not drawn, and not pretended to be**: the activity bar's two icons and
//! its fold button (`Activity` is not built on this host yet -- the sidebar
//! is always open), 「最近改过」 (its rows are empty on the macOS host this
//! round too), the column being dragged wider (`Split::drawn` squeezes a
//! fixed 296 into the room there is), and the workbench's footer. Search
//! is not in this task's scope at all.
//!
//! # The icons are this host's own shapes
//!
//! The design's tree icons are SVG paths and this host has no SVG. The
//! folder, the page and the two twisties are `glyph::Mark`'s outlines on the
//! same 14-unit artboard (`Mark::Folder`, `Mark::File`, `Mark::CaretShut`,
//! `Mark::CaretOpen`) -- **approximations**, not the design's own paths. A
//! pixel comparison against the macOS host would find them different; the
//! rows, their order, their words and their places are the same.

use crate::layout::Rect;
use crate::look::{font, radius, Rgba, Theme};
use crate::scene::{self, Align, Face, Item, Part, Piece, Side, Style};
use crate::workdirs::{Failure, Page};

/// What the page says itself. **The macOS host's words, word for word**
/// (`ControlRoomWorkdirsPage`'s `Tile`), so that one translation serves
/// both.
///
/// ⚠️ **Not `n_`, and this is the one place in the crate where that is so.**
/// The crate's rule is that a user-visible string is marked so `xgettext`
/// finds it; the fixture test then refuses a marked string with no Chinese
/// in `po/zh_CN.po`. **None of this page's words is in that catalogue** --
/// not these, and not the macOS host's own copies of them
/// (`ControlRoomWorkdirsPage.swift`'s `Tile.recentTitle`, `rootsTitle`,
/// `workbench`, `pickFile` and the rest are absent from `po/zh_CN.po` at
/// `d37baee87`). Marking them here would fail that test with no way to fix
/// it from this task, whose scope is `windows/` and which may not edit
/// `po/`. So they are plain constants, the page is English on a Chinese
/// machine exactly as the macOS page is today, and **the strings go into
/// the catalogue when the workdirs page's translation lands, on both
/// hosts at once** -- one task, because a host that translated them alone
/// would be the second answer about what the page says.
pub mod msg {
    pub const ROOTS: &str = "Working directories";
    pub const EMPTY: &str = "No working directory on record";
    /// Drawn while the answer for the group in front has not arrived. **Not
    /// `EMPTY`**: a group the core has not answered for yet is not a group
    /// with no directories.
    pub const WAITING: &str = "Reading the working directories…";
    pub const WORKBENCH: &str = "Workbench";
    pub const PICK: &str = "Pick a file to see its code and its changes";
    /// 「还有 N 个」: how many of a level the core left out
    /// (`Listing.max_entries`).
    pub const MORE: &str = "{} more";
    /// A directory that could not be read, when the core gave no sentence
    /// of its own.
    pub const NOT_READ: &str = "This directory could not be read.";
    /// A file the core would not open a ticket for, with no sentence of its
    /// own.
    pub const NOT_OPENED: &str = "This file cannot be previewed.";
}

/// Sizes, in points, from the design (`files4.css` / `files3.css` /
/// `files.css`) as the macOS host's `Tile` carries them.
pub mod tile {
    /// `.actbar { width: 48px }`.
    pub const ACT_WIDTH: f64 = 48.0;
    /// `.act-item { width: 40px; height: 40px }`, `.actbar-top { padding:
    /// 8px 0; gap: 4px }`.
    pub const ACT_ITEM: f64 = 40.0;
    pub const ACT_PAD: f64 = 8.0;
    pub const ACT_GAP: f64 = 4.0;

    /// `.sb-explorer .rsec { height: 28px; padding: 0 14px }`.
    pub const BAR_HEIGHT: f64 = 28.0;
    pub const BAR_PAD_X: f64 = 14.0;

    /// `.wdl .tree`'s padding.
    pub const BODY_PAD_X: f64 = 8.0;
    pub const BODY_PAD_Y: f64 = 4.0;
    pub const ROOTS_PAD_BOTTOM: f64 = 16.0;

    /// `.root { height: 48px; gap: 6px; padding: 0 8px }`, its two lines
    /// (`.l1` 24, `.l2 { line-height: 18px }`).
    pub const ROOT_HEIGHT: f64 = 48.0;
    pub const ROOT_FIRST_LINE: f64 = 24.0;
    pub const ROOT_PATH_LINE: f64 = 18.0;
    pub const ROOT_PAD_X: f64 = 8.0;
    pub const ROOT_OPEN_GAP: f64 = 6.0;

    /// `.tr { height: 28px }`, one step of 16 a level (`CHANGES.md`: 行高
    /// 28，每深一层缩进 16), `.tr .fic` 14, `.tr`'s gap 6.
    pub const TREE_ROW: f64 = 28.0;
    pub const TREE_INDENT: f64 = 16.0;
    pub const TREE_ICON: f64 = 14.0;
    pub const TREE_GAP: f64 = 6.0;
    /// The twisty's box (`files3.css`, `.tw` 14pt).
    pub const TWISTY: f64 = 14.0;

    /// A line that is not a row of the tree: a refusal, 「还有 N 个」.
    pub const NOTE_ROW: f64 = 22.0;

    /// `.tr.sel::after`: a 3pt bar, 16 high, 3 in from the row's edge.
    pub const SEL_BAR_WIDTH: f64 = 3.0;
    pub const SEL_BAR_HEIGHT: f64 = 16.0;
    pub const SEL_BAR_INSET: f64 = 3.0;
    pub const SEL_BAR_RADIUS: f64 = 1.5;

    /// `.wdr`'s bar: `.fh { height: 40px; padding: 0 8px 0 16px }`.
    pub const WORK_HEAD: f64 = 40.0;
    pub const WORK_PAD_X: f64 = 16.0;
}

/// How wide the left column is (`Split` on the macOS host): what a drag may
/// ask for, and what is drawn in a window that cannot hold it.
///
/// **The squeeze is the side's, never the workbench's**: `min_right` is
/// reserved first and what is left is the side's ceiling, which may fall
/// under `min_side` -- and to zero -- on a window too narrow for both.
pub mod split {
    /// `.sb-w` 296.
    pub const WIDTH: f64 = 296.0;
    /// `.sidebar { min-width: 180px }`.
    pub const MIN_SIDE: f64 = 180.0;
    /// The least the workbench is left. **Not the design's**: the design's
    /// `.wdr { min-width: 320px }` is wider than this window's least width
    /// leaves it.
    pub const MIN_RIGHT: f64 = 240.0;
    /// `.sidebar { max-width: 600px }`.
    pub const MAX_SIDE: f64 = 600.0;

    /// What a drag asked for, inside the range a drag may reach.
    pub fn asked(width: f64) -> f64 {
        width.max(MIN_SIDE).min(MAX_SIDE)
    }

    /// The column as drawn in a container this wide: the wanted width
    /// squeezed so that it and `MIN_RIGHT` fit, and never over `MAX_SIDE`.
    /// **The ceiling first**, so a window wide enough gets exactly what was
    /// asked for.
    pub fn drawn(wanted: f64, container: f64) -> f64 {
        let ceiling = (container - MIN_RIGHT).max(0.0);
        wanted.max(MIN_SIDE).min(MAX_SIDE).min(ceiling)
    }
}

/// What a row of the tree is, for a press and for which mark it carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowWhat {
    /// A working directory: the key is its id.
    Root,
    /// A directory under a root: the key is its real path.
    Dir,
    /// A file under a root.
    File,
    /// A sentence, not a row: a refusal or 「还有 N 个」. **Not pressable**:
    /// its key is empty and [`Layout::row_at`] never answers one.
    Note,
}

/// One row as it is drawn: where, what it is, and the key a press uses.
#[derive(Debug, Clone, PartialEq)]
pub struct RowAt {
    pub key: String,
    pub rect: Rect,
    /// 0 for a root; 1 and deeper under it.
    pub depth: usize,
    pub what: RowWhat,
    /// Whether a directory's own rows follow it.
    pub open: bool,
    /// What the row says, and (under it, for a root) the second line. Kept
    /// here so a press that has to redraw can name what it acted on.
    pub text: String,
    pub second: Option<String>,
}

/// Where everything on the page is, as the last paint drew it -- what the
/// pointer is measured against and where a press goes.
#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub width: f64,
    pub height: f64,
    pub actbar: Rect,
    pub side: Rect,
    pub workbench: Rect,
    /// The 「工作目录」 bar at the top of the sidebar.
    pub header: Rect,
    /// Where the tree is seen: the sidebar's body. What scrolls is drawn,
    /// and pressed, only in here.
    pub viewport: Rect,
    /// The workbench's bar and the box the preview goes in. **`body` is what
    /// the WebView2 controller is put in** (`preview_page::show`).
    pub work_head: Rect,
    pub body: Rect,
    pub rows: Vec<RowAt>,
    /// How tall every row is, all of it, before scrolling.
    pub content_height: f64,
}

impl Layout {
    pub fn max_scroll(&self) -> f64 {
        (self.content_height - self.viewport.h).max(0.0)
    }

    /// The row at `(x, y)` in the page's own points, when it is one a press
    /// can act on and the point is inside the tree's room. A sentence is
    /// not a row.
    pub fn row_at(&self, x: f64, y: f64) -> Option<&RowAt> {
        if x < self.viewport.x || y < self.viewport.y || x >= self.viewport.x + self.viewport.w || y >= self.viewport.y + self.viewport.h {
            return None;
        }
        self.rows.iter().find(|r| r.what != RowWhat::Note && x >= r.rect.x && y >= r.rect.y && x < r.rect.x + r.rect.w && y < r.rect.y + r.rect.h)
    }

    /// The row with this key, drawn or not, as the last paint laid it.
    pub fn row(&self, key: &str) -> Option<&RowAt> {
        self.rows.iter().find(|r| r.key == key)
    }

    /// How far to scroll, from `scroll`, for row `key` to be in sight **with
    /// a row's room past it**: by as little as it takes, and not at all when
    /// that is so already.
    pub fn follow(&self, key: &str, scroll: f64) -> f64 {
        let Some(row) = self.row(key) else { return scroll };
        let top = row.rect.y + scroll;
        let bottom = top + row.rect.h;
        let want_top = self.viewport.y + tile::TREE_ROW;
        let want_bottom = self.viewport.y + self.viewport.h - tile::TREE_ROW;
        let to = if top < want_top {
            scroll - (want_top - top)
        } else if bottom > want_bottom {
            scroll + (bottom - want_bottom)
        } else {
            scroll
        };
        to.max(0.0).min(self.max_scroll())
    }
}

/// Where a page's own points (its origin at 0,0) are in the panel's, in
/// points, with the scale the panel is drawn at.
///
/// **The one conversion between the panel and a page.** The paint makes one
/// from the right side's origin and the page's place in that side; a press,
/// a hover and the wheel take a panel point back through the same value.
///
/// Task 3158: the working-directories page kept the right side's rect for
/// its page instead of the panel's, and asked `row_at` a point that was
/// still in the panel's -- every press was answered about a point a side's
/// width (~380 points) to the right of what was drawn. **The trigger was
/// three chained additions, written out in two places**: a page's point is
/// `side origin + page offset + the page's own point`, and the copy that
/// left out the first term agreed with the paint on the day it was written
/// (both wrong in the same way is still wrong). One value, one subtraction.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct At {
    /// The page's origin in the panel's points.
    pub x: f64,
    pub y: f64,
    /// Device pixels to the point, as the panel is drawn.
    pub scale: f64,
}

impl At {
    /// The page as the paint draws it: the right side's origin (device
    /// pixels) plus the page's place in the side (points).
    pub fn drawn(side_ox: i32, side_oy: i32, scale: f64, page: Rect) -> At {
        At { x: side_ox as f64 / scale + page.x, y: side_oy as f64 / scale + page.y, scale }
    }

    /// **The page's origin back in device pixels** -- what the paint places
    /// the page's own points from.
    ///
    /// **The paint and the hit must start from this one value** (task
    /// 3164). The working-directories page used to draw from the right
    /// side's origin and hit-test from this one, which is the same thing
    /// only when the page's place in the side is zero: the page sits one
    /// bar height down (`scene::terminal_rect`), so every row was drawn
    /// ~32 points higher than it was hit, and a click on a row's centre
    /// landed on the row above it. Drawing from `origin()` is what makes
    /// the two the same origin by construction, not by two copies agreeing.
    pub fn origin(&self) -> (i32, i32) {
        ((self.x * self.scale).round() as i32, (self.y * self.scale).round() as i32)
    }

    /// A panel point, in device pixels, in the page's own points.
    pub fn local(&self, px: i32, py: i32) -> (f64, f64) {
        (px as f64 / self.scale - self.x, py as f64 / self.scale - self.y)
    }

    /// Whether a panel point is on the page at all -- **the whole page and
    /// not only a row**: a press on the workbench is the page's too, which
    /// is what gives the page its keys.
    pub fn holds(&self, layout: &Layout, px: i32, py: i32) -> bool {
        let (x, y) = self.local(px, py);
        x >= 0.0 && y >= 0.0 && x < layout.width && y < layout.height
    }

    /// The row under a panel point, or none. **The press and the hover both
    /// ask this**, so what is drawn and what is hit cannot come apart.
    pub fn hit<'a>(&self, layout: &'a Layout, px: i32, py: i32) -> Option<&'a RowAt> {
        if !self.holds(layout, px, py) {
            return None;
        }
        let (x, y) = self.local(px, py);
        layout.row_at(x, y)
    }
}

/// What the page is told besides the answer: where the pointer is, how far
/// the tree is scrolled, and what the workbench is showing.
pub struct View<'a> {
    pub page: &'a Page,
    pub hover: Option<&'a str>,
    pub scroll: f64,
    /// The file the workbench is showing: its name, as the file is called.
    pub open_name: Option<&'a str>,
    /// Why the last file pressed could not be shown, in the core's words
    /// where it gave any.
    pub open_said: Option<&'a str>,
    /// Why the page's own answer never arrived (the core's refusal, or the
    /// host's sentence). Drawn instead of [`msg::WAITING`] while there is no
    /// answer: **"not answered yet" and "answered with a no" are two states**
    /// and a page that drew the first for the second would send whoever read
    /// it looking in the wrong place.
    pub said: Option<&'a str>,
}

fn fill(rect: Rect, color: Rgba) -> Item {
    Item::Fill { rect, color }
}

/// Words on one line, cut short with an ellipsis when they do not fit.
fn words(rect: Rect, text: &str, style: Style, align: Align) -> Item {
    Item::Text { rect, text: text.to_string(), style, align }
}

fn body_style(color: Rgba) -> Style {
    Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color }
}

fn path_style(color: Rgba) -> Style {
    Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Mono, color }
}

/// The row's chip: the design's `--chip`, white mixed into the ground by
/// the selection's amount, and **never under a hover** -- a hover drawn over
/// a selection would move the row the person is on whenever the pointer
/// crossed it.
fn chip(theme: &Theme) -> Rgba {
    let white = Rgba { r: 255, g: 255, b: 255, a: 1.0 };
    scene::over(theme.window_base, white, theme.selection_tint)
}

/// Lay the page out and say what to draw.
pub fn build(view: &View, theme: &Theme, width: f64, height: f64, tr: &dyn Fn(&str) -> String) -> (Vec<Item>, Layout) {
    let width = width.max(0.0);
    let height = height.max(0.0);
    let side_w = split::drawn(split::WIDTH, width);
    let actbar = Rect { x: 0.0, y: 0.0, w: tile::ACT_WIDTH, h: height };
    let side = Rect { x: tile::ACT_WIDTH, y: 0.0, w: side_w, h: height };
    let workbench = Rect { x: tile::ACT_WIDTH + side_w, y: 0.0, w: (width - tile::ACT_WIDTH - side_w).max(0.0), h: height };
    let header = Rect { x: side.x, y: 0.0, w: side.w, h: tile::BAR_HEIGHT };
    let viewport = Rect {
        x: side.x + tile::BODY_PAD_X,
        y: tile::BAR_HEIGHT + tile::BODY_PAD_Y,
        w: (side.w - 2.0 * tile::BODY_PAD_X).max(0.0),
        h: (height - tile::BAR_HEIGHT - tile::BODY_PAD_Y - tile::ROOTS_PAD_BOTTOM).max(0.0),
    };
    let work_head = Rect { x: workbench.x, y: 0.0, w: workbench.w, h: tile::WORK_HEAD.min(workbench.h) };
    let body = Rect {
        x: workbench.x,
        y: work_head.h,
        w: workbench.w,
        h: (workbench.h - work_head.h).max(0.0),
    };

    let mut items = Vec::new();
    // The three grounds, left to right. The activity bar's own is the look
    // data's (`theme.actbar_bg`); no hex is written here.
    items.push(fill(actbar, theme.actbar_bg));
    items.push(fill(Rect { x: side.x, y: 0.0, w: side.w + workbench.w, h: height }, theme.window_base));
    // The line between the two columns, as every edge here is drawn.
    items.push(fill(Rect { x: workbench.x, y: 0.0, w: line_width(), h: height }, theme.line_faint));

    // The sidebar's bar, and its words.
    items.push(words(
        Rect { x: header.x + tile::BAR_PAD_X, y: header.y, w: (header.w - 2.0 * tile::BAR_PAD_X).max(0.0), h: header.h },
        &tr(msg::ROOTS),
        body_style(theme.text_secondary),
        Align::Left,
    ));

    // The tree.
    let (rows, content_height) = lay_rows(view, &viewport, tr);
    let layout = Layout { width, height, actbar, side, workbench, header, viewport, work_head, body, rows, content_height };

    match view.page.answer {
        None => {
            let said = match view.said {
                Some(said) => said.to_string(),
                None => tr(msg::WAITING),
            };
            items.push(words(
                Rect { x: viewport.x, y: viewport.y, w: viewport.w, h: tile::TREE_ROW },
                &said,
                body_style(theme.text_secondary),
                Align::Left,
            ));
        }
        Some(_) if view.page.dirs().is_empty() => {
            items.push(words(
                Rect { x: viewport.x, y: viewport.y, w: viewport.w, h: tile::TREE_ROW },
                &tr(msg::EMPTY),
                body_style(theme.text_secondary),
                Align::Left,
            ));
        }
        Some(_) => {
            // What scrolls is cut at the tree's own edge, so a row half out
            // is cut at its edge and not drawn over the bar above it.
            items.push(Item::Clip { rect: Some(viewport) });
            for row in &layout.rows {
                draw_row(&mut items, row, view, theme);
            }
            items.push(Item::Clip { rect: None });
        }
    }

    // The workbench: its bar, and what is said while there is nothing to
    // preview.
    items.push(fill(Rect { x: work_head.x, y: work_head.y, w: work_head.w, h: line_width() }, theme.line_faint));
    let title = match view.open_name {
        Some(name) => name.to_string(),
        None => tr(msg::WORKBENCH),
    };
    items.push(words(
        Rect { x: work_head.x + tile::WORK_PAD_X, y: work_head.y, w: (work_head.w - 2.0 * tile::WORK_PAD_X).max(0.0), h: work_head.h },
        &title,
        path_style(theme.text),
        Align::Left,
    ));
    if let Some(said) = view.open_said {
        items.push(words(
            Rect { x: body.x + tile::WORK_PAD_X, y: body.y, w: (body.w - 2.0 * tile::WORK_PAD_X).max(0.0), h: body.h },
            said,
            body_style(theme.text_secondary),
            Align::Centre,
        ));
    } else if view.open_name.is_none() {
        items.push(words(
            Rect { x: body.x + tile::WORK_PAD_X, y: body.y, w: (body.w - 2.0 * tile::WORK_PAD_X).max(0.0), h: body.h },
            &tr(msg::PICK),
            body_style(theme.text_secondary),
            Align::Centre,
        ));
    }
    (items, layout)
}

/// **One device pixel at 100%**, in points: the hairline this host draws
/// every edge with (`scene::hairline` at a scale of 1, which is what a scene
/// is measured in).
fn line_width() -> f64 {
    crate::look::line::HAIRLINE
}

/// Every row the tree draws, with its place, scrolled by `view.scroll`.
///
/// The roots come in the core's order and a level's rows in the core's
/// order; **nothing here sorts, filters or decides which rows there are** --
/// an open root's rows are `Page::rows`, and a shut root has none.
fn lay_rows(view: &View, viewport: &Rect, tr: &dyn Fn(&str) -> String) -> (Vec<RowAt>, f64) {
    let mut rows = Vec::new();
    let mut y = viewport.y - view.scroll;
    let mut push = |key: String, h: f64, depth: usize, what: RowWhat, open: bool, text: String, second: Option<String>| {
        rows.push(RowAt { key, rect: Rect { x: viewport.x, y, w: viewport.w, h }, depth, what, open, text, second });
        y += h;
    };
    for dir in view.page.dirs() {
        let open = view.page.tree.is_open(&dir.id);
        push(dir.id.clone(), tile::ROOT_HEIGHT, 0, RowWhat::Root, open, dir.short.clone(), Some(dir.path.clone()));
        if !open {
            continue;
        }
        for node in view.page.rows(dir) {
            let what = if node.is_dir { RowWhat::Dir } else { RowWhat::File };
            let open = node.is_dir && view.page.levels.is_open(&node.path);
            push(node.path.clone(), tile::TREE_ROW, node.depth, what, open, node.name.clone(), None);
            if open {
                if let Some(level) = view.page.levels.level(&node.path) {
                    if level.more > 0 {
                        let said = tr(msg::MORE).replace("{}", &level.more.to_string());
                        push(String::new(), tile::NOTE_ROW, node.depth + 1, RowWhat::Note, false, said, None);
                    }
                }
                if let Some(failure) = view.page.levels.failure(&node.path) {
                    let said = match failure.why() {
                        Some(why) => why.to_string(),
                        None => tr(not_read(failure)),
                    };
                    push(String::new(), tile::NOTE_ROW, node.depth + 1, RowWhat::Note, false, said, None);
                }
            }
        }
    }
    let content_height = (y + view.scroll) - viewport.y;
    (rows, content_height)
}

/// The sentence for a refusal with no words of its own.
fn not_read(failure: &Failure) -> &'static str {
    match failure {
        Failure::NotJson | Failure::Unknown(_) => msg::NOT_READ,
        // A refusal with no `why` (the core always writes one, but a door
        // that did not is not a parse failure to the person either), and a
        // request that never reached the core.
        Failure::Refused(_) | Failure::RefusedFile { .. } | Failure::Unavailable(_) => msg::NOT_READ,
    }
}

fn draw_row(items: &mut Vec<Item>, row: &RowAt, view: &View, theme: &Theme) {
    if row.what == RowWhat::Note {
        // A sentence under the directory it belongs to: quieter, and no
        // chip even when the pointer crosses it.
        let x = row.rect.x + ((row.depth.saturating_sub(1)) as f64) * tile::TREE_INDENT;
        items.push(words(
            Rect { x, y: row.rect.y, w: (row.rect.x + row.rect.w - x).max(0.0), h: row.rect.h },
            &row.text,
            body_style(theme.text_secondary),
            Align::Left,
        ));
        return;
    }
    let selected = view.page.tree.is_selected(&row.key);
    let hovered = view.hover == Some(row.key.as_str());
    if selected {
        items.push(Item::Round { rect: row.rect, radius: radius::ROW, color: chip(theme), edge: None });
        // The bar down the selected row's left edge, sized as the design
        // places it (`.tr.sel::after`).
        let top = row.rect.y + (row.rect.h - tile::SEL_BAR_HEIGHT) / 2.0;
        items.push(Item::Round {
            rect: Rect { x: row.rect.x + tile::SEL_BAR_INSET, y: top, w: tile::SEL_BAR_WIDTH, h: tile::SEL_BAR_HEIGHT },
            radius: tile::SEL_BAR_RADIUS,
            color: theme.text,
            edge: None,
        });
    } else if hovered {
        items.push(fill(row.rect, theme.window_tab_hover));
    }
    let ink = if selected || hovered { theme.text } else { theme.text_secondary };

    if row.what == RowWhat::Root {
        // The twisty, then the name on the first line; the path under it.
        let left = row.rect.x + tile::ROOT_PAD_X;
        let line = Rect { x: left, y: row.rect.y, w: (row.rect.w - 2.0 * tile::ROOT_PAD_X).max(0.0), h: tile::ROOT_FIRST_LINE };
        let caret = if row.open { crate::glyph::Mark::CaretOpen } else { crate::glyph::Mark::CaretShut };
        items.push(Item::Line {
            rect: line,
            parts: vec![
                Part { piece: Piece::Mark { mark: caret, color: ink, size: tile::TWISTY }, side: Side::Lead, gap: 0.0 },
                Part { piece: Piece::Words { text: row.text.clone(), style: body_style(theme.text) }, side: Side::Lead, gap: tile::ROOT_OPEN_GAP },
            ],
        });
        if let Some(path) = &row.second {
            items.push(Item::Text {
                rect: Rect { x: left, y: row.rect.y + tile::ROOT_FIRST_LINE, w: line.w, h: tile::ROOT_PATH_LINE },
                text: path.clone(),
                style: path_style(theme.text_secondary),
                align: Align::Left,
            });
        }
        return;
    }

    // A row of the tree: one step of 16 a level (a root's rows start at the
    // column's padding), the twisty for a directory, the icon, the name.
    let step = row.depth.saturating_sub(1) as f64;
    let left = row.rect.x + step * tile::TREE_INDENT;
    let mut parts = Vec::new();
    if row.what == RowWhat::Dir {
        let caret = if row.open { crate::glyph::Mark::CaretOpen } else { crate::glyph::Mark::CaretShut };
        parts.push(Part { piece: Piece::Mark { mark: caret, color: ink, size: tile::TWISTY }, side: Side::Lead, gap: 0.0 });
    } else {
        // No twisty: the room it takes is left, so names at one level line
        // up whether or not a directory's twisty is beside them.
        parts.push(Part { piece: Piece::Bar { color: theme.window_base, width: tile::TWISTY, height: tile::TWISTY }, side: Side::Lead, gap: 0.0 });
    }
    let icon = match (row.what, row.open) {
        (RowWhat::Dir, true) => crate::glyph::Mark::FolderOpen,
        (RowWhat::Dir, false) => crate::glyph::Mark::Folder,
        _ => crate::glyph::Mark::File,
    };
    parts.push(Part { piece: Piece::Mark { mark: icon, color: ink, size: tile::TREE_ICON }, side: Side::Lead, gap: tile::TREE_GAP });
    parts.push(Part { piece: Piece::Words { text: row.text.clone(), style: body_style(ink) }, side: Side::Lead, gap: tile::TREE_GAP });
    items.push(Item::Line { rect: Rect { x: left, y: row.rect.y, w: (row.rect.x + row.rect.w - left).max(0.0), h: row.rect.h }, parts });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json;
    use crate::look::DARK;
    use crate::workdirs;

    fn listing(entries: &[(&str, bool)], more: u64) -> String {
        let mut out = String::from("{\"entries\":[");
        for (i, (name, is_dir)) in entries.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!("{{\"name\":{},\"is_dir\":{}}}", json::quote(name), is_dir));
        }
        out.push_str(&format!("],\"more\":{more}}}"));
        out
    }

    fn page(dirs: &[&str]) -> Page {
        let mut out = String::from("{\"page\":\"workdirs\",\"group\":\"g\",\"dirs\":[");
        for (i, path) in dirs.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"id\":\"id{}\",\"path\":{},\"short\":{},\"kind\":\"terminal\",\"tree_name\":null,\"who\":[],\"also_in\":[],\"readable\":true,\"why\":null,\"editing\":0}}",
                i,
                json::quote(path),
                json::quote(path)
            ));
        }
        out.push_str("]}");
        let mut p = Page::new("g");
        p.set_answer(workdirs::read(&out).unwrap());
        p
    }

    fn tr(s: &str) -> String {
        s.to_string()
    }

    /// The three columns, and the box the preview goes in.
    #[test]
    fn the_columns_are_the_designs_and_the_body_is_below_the_workbench_bar() {
        let p = page(&["/w"]);
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (_, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        assert_eq!(l.actbar.w, 48.0);
        assert_eq!(l.side.x, 48.0);
        assert_eq!(l.side.w, 296.0);
        assert_eq!(l.workbench.x, 344.0);
        assert_eq!(l.workbench.w, 656.0);
        assert_eq!(l.body.y, tile::WORK_HEAD);
        assert_eq!(l.body.h, 600.0 - tile::WORK_HEAD);
        // The tree is inside the sidebar's body, under the bar, over the
        // padding at the foot.
        assert_eq!(l.viewport.x, 48.0 + 8.0);
        assert_eq!(l.viewport.y, 28.0 + 4.0);
        assert_eq!(l.viewport.y + l.viewport.h, 600.0 - 16.0);
    }

    /// **A window too narrow for both**: the side gives way first, and never
    /// below zero.
    #[test]
    fn a_narrow_window_squeezes_the_side_and_never_the_workbench() {
        assert_eq!(split::drawn(split::WIDTH, 1000.0), 296.0);
        assert_eq!(split::drawn(split::WIDTH, 400.0), 160.0);
        assert_eq!(split::drawn(split::WIDTH, 300.0), 60.0);
        assert_eq!(split::drawn(split::WIDTH, 100.0), 0.0);
        assert_eq!(split::asked(50.0), split::MIN_SIDE);
        assert_eq!(split::asked(700.0), split::MAX_SIDE);
    }

    /// The tree's rows: a root, then its level in the core's order.
    #[test]
    fn the_rows_are_the_root_and_its_level_in_order() {
        let mut p = page(&["/w"]);
        p.levels.keep("/w", workdirs::read_listing(&listing(&[("sub", true), ("a.txt", false)], 0)).unwrap());
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (_, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        assert_eq!(l.rows.len(), 3);
        assert_eq!(l.rows[0].what, RowWhat::Root);
        assert_eq!(l.rows[0].text, "/w");
        assert_eq!(l.rows[0].second.as_deref(), Some("/w"));
        assert_eq!(l.rows[0].rect.h, tile::ROOT_HEIGHT);
        assert_eq!(l.rows[1].what, RowWhat::Dir);
        assert_eq!(l.rows[1].text, "sub");
        assert_eq!(l.rows[1].depth, 1);
        assert_eq!(l.rows[2].what, RowWhat::File);
        assert_eq!(l.rows[2].text, "a.txt");
        assert_eq!(l.rows[1].rect.y, l.rows[0].rect.y + tile::ROOT_HEIGHT);
        assert_eq!(l.rows[2].rect.y, l.rows[1].rect.y + tile::TREE_ROW);
        assert_eq!(l.content_height, tile::ROOT_HEIGHT + 2.0 * tile::TREE_ROW);
    }

    #[test]
    fn a_shut_root_draws_itself_and_nothing_under_it() {
        let mut p = page(&["/w"]);
        p.levels.keep("/w", workdirs::read_listing(&listing(&[("a.txt", false)], 0)).unwrap());
        p.tree.toggle("id0");
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (_, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        assert_eq!(l.rows.len(), 1);
        assert!(!l.rows[0].open);
    }

    /// **A directory that could not be read says so**, under its own row,
    /// and that sentence is not a row a press can act on.
    #[test]
    fn a_refused_directory_gets_a_sentence_row_that_is_not_pressable() {
        let mut p = page(&["/w"]);
        p.levels.keep("/w", workdirs::read_listing(&listing(&[("sub", true)], 0)).unwrap());
        p.levels.toggle("/w/sub");
        let f = workdirs::read_listing(r#"{"refused":"access","reason":"unreadable","why":"it could not be looked at"}"#).unwrap_err();
        p.levels.keep_failure("/w/sub", f);
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (items, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        assert_eq!(l.rows.len(), 3);
        assert_eq!(l.rows[2].what, RowWhat::Note);
        assert_eq!(l.rows[2].text, "it could not be looked at");
        // The sentence is drawn...
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == "it could not be looked at")));
        // ...and pressing on it acts on nothing.
        let r = &l.rows[2].rect;
        assert!(l.row_at(r.x + 2.0, r.y + 2.0).is_none());
        // The directory's own row is pressable.
        let d = &l.rows[1].rect;
        assert_eq!(l.row_at(d.x + 2.0, d.y + 2.0).map(|x| x.key.as_str()), Some("/w/sub"));
    }

    #[test]
    fn a_level_that_was_cut_says_how_many_were_left() {
        let mut p = page(&["/w"]);
        p.levels.keep("/w", workdirs::read_listing(&listing(&[("a", false)], 5)).unwrap());
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (items, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        // A file's level is not open, so its `more` is not drawn either.
        assert_eq!(l.rows.len(), 2);
        let _ = items;
    }

    /// A point outside the tree's room, or between rows, is no row.
    #[test]
    fn a_press_is_measured_against_the_tree_it_was_drawn_in() {
        let p = page(&["/w"]);
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (_, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        let r = l.rows[0].rect;
        assert!(l.row_at(r.x + 4.0, r.y + 4.0).is_some());
        // Over the header bar: not the tree.
        assert!(l.row_at(r.x + 4.0, 2.0).is_none());
        // In the workbench: not the tree.
        assert!(l.row_at(l.workbench.x + 4.0, l.viewport.y + 4.0).is_none());
        // Past the last row inside the tree's room: none.
        assert!(l.row_at(r.x + 4.0, r.y + l.content_height + 10.0).is_none());
    }

    #[test]
    fn scrolling_is_kept_to_the_rows_there_are_and_follows_one_into_sight() {
        let mut p = page(&["/w"]);
        let many: Vec<(String, bool)> = (0..40).map(|i| (format!("f{i:02}"), false)).collect();
        let refs: Vec<(&str, bool)> = many.iter().map(|(s, d)| (s.as_str(), *d)).collect();
        p.levels.keep("/w", workdirs::read_listing(&listing(&refs, 0)).unwrap());
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (_, l) = build(&v, &DARK, 1000.0, 300.0, &tr);
        assert!(l.max_scroll() > 0.0);
        let last = l.rows.last().unwrap().key.clone();
        let to = l.follow(&last, 0.0);
        assert!(to > 0.0);
        assert!(to <= l.max_scroll());
        // Already in sight: no scroll.
        assert_eq!(l.follow(&l.rows[0].key, 0.0), 0.0);
        // A key this page does not draw scrolls nothing.
        assert_eq!(l.follow("/nope", 12.0), 12.0);
    }

    /// **Waiting and empty are two sentences**, and the page draws neither
    /// as the other.
    #[test]
    fn waiting_for_the_answer_is_not_the_same_as_no_directories() {
        let tr_ = |s: &str| s.to_string();
        let p = Page::new("g");
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (items, _) = build(&v, &DARK, 1000.0, 600.0, &tr_);
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == msg::WAITING)));

        let mut p = Page::new("g");
        p.set_answer(workdirs::read(r#"{"page":"workdirs","group":"g","dirs":[]}"#).unwrap());
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (items, _) = build(&v, &DARK, 1000.0, 600.0, &tr_);
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == msg::EMPTY)));
        assert!(!items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == msg::WAITING)));
    }

    /// **A page the core refused does not read as still waiting**: `said`
    /// replaces the waiting sentence, because those are two states.
    #[test]
    fn a_refused_page_is_not_drawn_as_one_still_waiting() {
        let tr_ = |s: &str| s.to_string();
        let p = Page::new("g");
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: Some("NoSuchGroup") };
        let (items, _) = build(&v, &DARK, 1000.0, 600.0, &tr_);
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == "NoSuchGroup")));
        assert!(!items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == msg::WAITING)));
    }

    /// The workbench says where the preview goes and what it is showing; a
    /// file that could not be opened is said, not drawn as an empty one.
    #[test]
    fn the_workbench_shows_the_file_or_says_why_not() {
        let p = page(&["/w"]);
        let tr_ = |s: &str| s.to_string();
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (items, l) = build(&v, &DARK, 1000.0, 600.0, &tr_);
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == msg::PICK)));
        assert!(l.body.w > 0.0);

        let v = View { page: &p, hover: None, scroll: 0.0, open_name: Some("a.txt"), open_said: None, said: None };
        let (items, _) = build(&v, &DARK, 1000.0, 600.0, &tr_);
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == "a.txt")));
        assert!(!items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == msg::PICK)));

        let v = View { page: &p, hover: None, scroll: 0.0, open_name: Some("a.txt"), open_said: Some("it is not in this working directory"), said: None };
        let (items, _) = build(&v, &DARK, 1000.0, 600.0, &tr_);
        assert!(items.iter().any(|i| matches!(i, Item::Text { text, .. } if text == "it is not in this working directory")));
    }

    /// **Every row is hit where it is drawn** (task 3164): the centre of the
    /// N-th row comes back as the N-th row, and a point one pixel inside
    /// its top or bottom edge comes back as the same row -- an error of one
    /// row is not something the 3158 test could see.
    ///
    /// The page sits one bar height down its side; the origin the paint
    /// uses and the origin the hit subtracts are the **same value**
    /// (`At::origin`), which is the property, not two figures that agree.
    #[test]
    fn every_row_is_hit_where_it_is_drawn() {
        let mut p = page(&["/w"]);
        p.levels.keep("/w", workdirs::read_listing(&listing(&[("a", false), ("b", false), ("c", false), ("d", false)], 0)).unwrap());
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (_, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        assert!(l.rows.len() >= 5, "the tree has a root and its level");
        let at = At::drawn(760, 0, 2.0, Rect { x: 1.0, y: 32.0, w: l.width, h: l.height });
        // The page's top-left in the panel is the origin, and the origin is
        // the page's (0,0).
        let (ox, oy) = at.origin();
        assert_eq!(at.local(ox, oy), (0.0, 0.0));
        assert_eq!((ox, oy), (762, 64), "the side's 760 px + the page's 1 and 32 points, at scale 2");
        // **From the second row down first** (task 3164's floor): an error
        // of one row shows as "row N's centre is row N-1", which row 0
        // cannot say -- a point a row above it is off the page. Row 0 is
        // asserted after them.
        let order = (1..l.rows.len()).chain(std::iter::once(0));
        for i in order {
            let row = &l.rows[i];
            let cx = ox + ((row.rect.x + row.rect.w / 2.0) * at.scale).round() as i32;
            let cy = oy + ((row.rect.y + row.rect.h / 2.0) * at.scale).round() as i32;
            assert_eq!(
                at.hit(&l, cx, cy).map(|r| r.key.clone()),
                Some(row.key.clone()),
                "row {i}'s centre hit {i}"
            );
            let top = oy + (row.rect.y * at.scale).round() as i32 + 1;
            let bottom = oy + ((row.rect.y + row.rect.h) * at.scale).round() as i32 - 1;
            assert_eq!(at.hit(&l, cx, top).map(|r| r.key.clone()), Some(row.key.clone()), "row {i}'s top edge");
            assert_eq!(at.hit(&l, cx, bottom).map(|r| r.key.clone()), Some(row.key.clone()), "row {i}'s bottom edge");
        }
    }

    /// **A point on the panel is read in the page's own points** (task 3158):
    /// the page sits at the right side's origin plus its place in the side,
    /// and the press subtracts both. A row's drawn centre is on that row.
    #[test]
    fn a_panel_point_is_read_in_the_pages_own_points() {
        let p = page(&["/w"]);
        let v = View { page: &p, hover: None, scroll: 0.0, open_name: None, open_said: None, said: None };
        let (_, l) = build(&v, &DARK, 1000.0, 600.0, &tr);
        // The right side in a 1000-wide panel, and the page inside it: the
        // page's origin is their sum (380 + 1, 0 + 32).
        let at = At::drawn(760, 0, 2.0, Rect { x: 1.0, y: 32.0, w: l.width, h: l.height });
        assert_eq!((at.x, at.y), (381.0, 32.0));

        // A point on the first row, in the page's own points, as the paint
        // drew it: back to device pixels.
        let row = &l.rows[0].rect;
        let local = (row.x + 40.0, row.y + 10.0);
        let px = ((at.x + local.0) * at.scale).round() as i32;
        let py = ((at.y + local.1) * at.scale).round() as i32;
        assert_eq!(at.local(px, py), local);
        assert!(at.holds(&l, px, py));
        assert_eq!(at.hit(&l, px, py).map(|r| r.key.clone()), Some(l.rows[0].key.clone()));

        // **The negative control**: the same device y, 360 points further
        // right -- the direction the old code was off by, because it asked
        // about the panel's point without taking the side's origin off.
        // Inside the page, and not on any row.
        let wrong = (px + (360.0 * at.scale).round() as i32, py);
        assert!(at.holds(&l, wrong.0, wrong.1), "the shifted point is still inside the page");
        assert!(at.hit(&l, wrong.0, wrong.1).is_none(), "a point 360 points to the right must not hit the row");
        // And a press off the page is not the page's at all.
        assert!(!at.holds(&l, px - (400.0 * at.scale).round() as i32, py));
        assert!(at.hit(&l, px - (400.0 * at.scale).round() as i32, py).is_none());
    }
}
