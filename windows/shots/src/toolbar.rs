//! The two-row toolbar: where each button is, and what its tooltip says.
//!
//! Specification §9.1 and §9.8.2. The first row is the tools and the
//! commands; the second is the properties of the current tool, or of the
//! selected annotation. **One plate holds both rows**, as wide as the first
//! whatever the second holds. The sizes are the look's (`look::size`, in
//! points): 28-point cells, 4 between them, 12 between groups, 6 of
//! padding, nothing between the rows. A colour and a step each have a whole
//! cell, like a tool; what is drawn in it is smaller (`chrome`).

use crate::geom::{Point, Rect};
use crate::look::size;
use crate::style::{self, Props, Tool};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Tool(Tool),
    Undo,
    Redo,
    Long,
    /// Finish as Done does, and keep a copy in Downloads (#1197).
    Save,
    Cancel,
    Done,
    /// A colour swatch on the property row.
    Colour(u8),
    /// A step of thickness, font size or block size on the property row.
    Level(u8),
}

/// The first row's groups, left to right.
const ROW: [&[Button]; 5] = [
    &[Button::Tool(Tool::Select)],
    &[
        Button::Tool(Tool::Rect),
        Button::Tool(Tool::Ellipse),
        Button::Tool(Tool::Line),
        Button::Tool(Tool::Arrow),
        Button::Tool(Tool::Pen),
        Button::Tool(Tool::Highlighter),
        Button::Tool(Tool::Text),
        Button::Tool(Tool::Number),
        Button::Tool(Tool::Mosaic),
    ],
    &[Button::Undo, Button::Redo],
    &[Button::Long, Button::Save],
    &[Button::Cancel, Button::Done],
];

/// Where everything on the toolbar is, in virtual-screen pixels.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    /// The first row.
    pub bar: Rect,
    /// The property row, when it is shown: under the first, as wide.
    pub props: Option<Rect>,
    pub buttons: Vec<(Button, Rect)>,
}

impl Layout {
    pub fn button_at(&self, p: Point) -> Option<Button> {
        self.buttons.iter().find(|(_, r)| r.contains(p)).map(|(b, _)| *b)
    }

    /// Whether `p` is on the toolbar at all -- a click there is the
    /// toolbar's even between two buttons, not a stroke on the picture.
    pub fn covers(&self, p: Point) -> bool {
        self.bar.contains(p) || self.props.is_some_and(|r| r.contains(p))
    }

    /// The plate: both rows when the second is shown, the first alone
    /// when it is not.
    pub fn plate(&self) -> Rect {
        Rect::new(self.bar.x, self.bar.y, self.bar.w, self.props.map_or(self.bar.bottom(), |r| r.bottom()) - self.bar.y)
    }

    pub fn rect_of(&self, button: Button) -> Option<Rect> {
        self.buttons.iter().find(|(b, _)| *b == button).map(|(_, r)| *r)
    }
}

/// The size both rows take together, in pixels: what is kept clear for the
/// toolbar whether or not the property row is showing, so that picking a
/// tool does not make it jump.
pub fn footprint(scale: f64) -> (i32, i32) {
    let px = |points: f64| style::px_f(points, scale);
    let buttons: i32 = ROW.iter().map(|g| g.len() as i32).sum();
    let inner_gaps: i32 = ROW.iter().map(|g| g.len() as i32 - 1).sum();
    let width =
        px(size::PADDING) * 2 + buttons * px(size::BUTTON) + inner_gaps * px(size::GAP) + (ROW.len() as i32 - 1) * px(size::GROUP_GAP);
    (width, row_height(scale) * 2 + row_gap(scale))
}

/// A row's height: a cell and the padding over and under it.
pub fn row_height(scale: f64) -> i32 {
    style::px_f(size::BUTTON, scale) + style::px_f(size::PADDING, scale) * 2
}

/// Between the two rows: nothing, by the look. Not `px_f`, which never
/// gives less than a pixel.
fn row_gap(scale: f64) -> i32 {
    (size::ROW_GAP * scale).round() as i32
}

/// Lay the toolbar out beside `selection` on `monitor`: below it, or above,
/// or inside its bottom edge (`geom::toolbar_origin`). `props` is which
/// property row to show.
pub fn layout(selection: Rect, monitor: Rect, scale: f64, props: Props) -> Layout {
    let (width, height) = footprint(scale);
    let origin = crate::geom::toolbar_origin(selection, (width, height), monitor, style::px_f(size::OFFSET, scale));
    layout_at(origin, scale, props)
}

/// Where the toolbar's top-left corner may be put by hand: the whole
/// footprint stays on `monitor`.
pub fn keep_on(origin: Point, monitor: Rect, scale: f64) -> Point {
    let (w, h) = footprint(scale);
    Point::new(origin.x.min(monitor.right() - w).max(monitor.x), origin.y.min(monitor.bottom() - h).max(monitor.y))
}

/// The toolbar with its top-left corner at `origin`, wherever that came from:
/// beside the selection ([`layout`]) or where the user dragged it.
pub fn layout_at(origin: Point, scale: f64, props: Props) -> Layout {
    let px = |points: f64| style::px_f(points, scale);
    let (width, _) = footprint(scale);
    let row_h = row_height(scale);
    let (cell, step) = (px(size::BUTTON), px(size::BUTTON) + px(size::GAP));
    let mut buttons = Vec::new();

    let mut x = origin.x + px(size::PADDING);
    let y = origin.y + px(size::PADDING);
    for (g, group) in ROW.iter().enumerate() {
        if g > 0 {
            x += px(size::GROUP_GAP) - px(size::GAP);
        }
        for button in group.iter() {
            buttons.push((*button, Rect::new(x, y, cell, cell)));
            x += step;
        }
    }
    let bar = Rect::new(origin.x, origin.y, width, row_h);

    let mut props_rect = None;
    if props != Props::None {
        let top = origin.y + row_h + row_gap(scale);
        let mut x = origin.x + px(size::PADDING);
        if props != Props::Block {
            for c in 0..style::COLOURS.len() as u8 {
                buttons.push((Button::Colour(c), Rect::new(x, top + px(size::PADDING), cell, cell)));
                x += step;
            }
            x += px(size::GROUP_GAP) - px(size::GAP);
        }
        for l in 0..style::LEVELS {
            buttons.push((Button::Level(l), Rect::new(x, top + px(size::PADDING), cell, cell)));
            x += step;
        }
        // As wide as the first row: the contents are at the left and the
        // rest of the plate is empty.
        props_rect = Some(Rect::new(origin.x, top, width, row_h));
    }
    Layout { bar, props: props_rect, buttons }
}

/// The nine colours' names, in palette order.
pub const COLOUR_NAMES: [&str; 9] = ["Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Black", "White"];

/// A button's name -- the English msgid; the host translates it. `props` is
/// the property row that is showing, which is what a step button is a step
/// *of*.
///
/// **Every word the overlay shows is in this file or in `annot::EN`**, and
/// every one of them is a msgid the core's catalogue has -- [`words`] lists
/// them and a test below reads the catalogue to check. The core's own list is
/// `src/input/screenshot.zig`; a word made up here would show in English in
/// every language and fail nowhere.
pub fn name(button: Button, props: Props) -> &'static str {
    match button {
        Button::Tool(Tool::Select) => "Select",
        Button::Tool(Tool::Rect) => "Rectangle",
        Button::Tool(Tool::Ellipse) => "Ellipse",
        // Not `Line`: that is the word for a line in the pasted text.
        Button::Tool(Tool::Line) => "Straight Line",
        Button::Tool(Tool::Arrow) => "Arrow",
        Button::Tool(Tool::Pen) => "Pen",
        Button::Tool(Tool::Highlighter) => "Highlighter",
        Button::Tool(Tool::Text) => "Text",
        Button::Tool(Tool::Number) => "Number",
        Button::Tool(Tool::Mosaic) => "Mosaic",
        Button::Undo => "Undo",
        Button::Redo => "Redo",
        Button::Long => LONG,
        Button::Save => "Save",
        Button::Cancel => "Cancel",
        Button::Done => "Done",
        Button::Colour(c) => COLOUR_NAMES[c as usize % COLOUR_NAMES.len()],
        Button::Level(_) => match props {
            Props::Font => "Font Size",
            Props::Block => "Block Size",
            _ => "Thickness",
        },
    }
}

/// The other words the overlay shows.
pub const LONG: &str = "Long Screenshot";
pub const FONT_MISSING: &str = "The annotation font is missing, so the system font is used.";
pub const LONG_SLOWER: &str = "Scroll slower";
/// What to do, shown until the first new rows have been joined.
pub const LONG_HINT: &str = "Scroll down slowly. What comes into view is added at the bottom.";

/// Shown when the region has not held still for one frame yet: nothing can
/// be added to a picture that keeps changing (a video, a spinner).
pub const LONG_RESTLESS: &str = "The picture keeps changing, so nothing can be added.";
/// How many frames in a row have to be held back, with none joined yet,
/// before the status line says so: about a second of them. The first frame
/// of every long screenshot is held back once, and a page caught while it
/// settles a few times more.
pub const LONG_RESTLESS_AFTER: u32 = 8;

/// Whether to say the region keeps changing: no frame was ever joined
/// (`Stitcher::never_steady`) and `held` were held back.
pub fn long_restless(never_steady: bool, held: u32) -> bool {
    never_steady && held >= LONG_RESTLESS_AFTER
}

/// What a long screenshot's status line says after the height, if
/// anything: that the region keeps changing, that the last frame could not
/// be followed, that the limit was reached, or -- while nothing has been
/// added yet -- what to do. `last` is the last frame that said something;
/// `added` whether any rows have been joined below the first frame;
/// `restless` is `long_restless`. A msgid.
pub fn long_hint(last: crate::stitch::Step, added: bool, restless: bool) -> Option<&'static str> {
    use crate::stitch::Step;
    match last {
        _ if restless => Some(LONG_RESTLESS),
        Step::Lost => Some(LONG_SLOWER),
        Step::Full => Some(LONG_FULL),
        _ if !added => Some(LONG_HINT),
        _ => None,
    }
}
pub const LONG_FULL: &str = "The height limit was reached.";
/// What the status line says while the program scrolls (shared msgids,
/// `src/input/screenshot.zig`).
pub const LONG_AUTO: &str = "Scrolling down\u{2026} Enter keeps what is joined so far, Esc cancels.";
/// The notice when the program had to stop because the page could not be followed.
pub const LONG_FOLLOWED: &str = "The page could not be followed any further, so the picture ends here.";
/// The save notices: that it was saved (`{name}` is the file), that it was not.
pub const SAVED: &str = "Saved to Downloads: {name}";
pub const SAVE_FAILED: &str = "The picture could not be saved.";
/// The magnifier's flash after Ctrl+C.
pub const COPIED: &str = "Copied";
/// The notice when the hotkey cannot be registered: its title and its body.
pub const HOTKEY_FAILED: &str = "The screenshot shortcut could not be registered";
pub const HOTKEY_TAKEN: &str =
    "Another application is already using it. Choose a different one with a `screenshot` keybind in the configuration.";

/// Every msgid this crate asks a host to translate.
pub fn words() -> Vec<&'static str> {
    let mut all: Vec<&'static str> = Vec::new();
    for props in [Props::Stroke, Props::Font, Props::Block] {
        all.push(name(Button::Level(0), props));
    }
    all.extend(Tool::ALL.iter().map(|t| name(Button::Tool(*t), Props::None)));
    for b in [Button::Undo, Button::Redo, Button::Long, Button::Save, Button::Cancel, Button::Done] {
        all.push(name(b, Props::None));
    }
    all.extend(COLOUR_NAMES);
    all.extend([FONT_MISSING, LONG_HINT, LONG_SLOWER, LONG_FULL, LONG_RESTLESS, HOTKEY_FAILED, HOTKEY_TAKEN]);
    all.extend([LONG_AUTO, LONG_FOLLOWED, SAVED, SAVE_FAILED, COPIED]);
    let l = crate::annot::EN;
    all.extend([
        l.header, l.text, l.rect, l.ellipse, l.line, l.arrow, l.pen, l.highlighter, l.mosaic, l.separator, l.see,
    ]);
    let long = crate::annot::LONG_EN;
    all.extend([long.header, long.tiles, long.whole, long.separator, long.see]);
    all.sort_unstable();
    all.dedup();
    all
}

/// The key that does what the button does, as it is written on a Windows
/// keyboard; `None` when there is none.
pub fn shortcut(button: Button) -> Option<String> {
    match button {
        Button::Tool(t) => Some(t.letter().to_string()),
        Button::Undo => Some("Ctrl+Z".into()),
        Button::Redo => Some("Ctrl+Shift+Z".into()),
        Button::Cancel => Some("Esc".into()),
        Button::Done => Some("Enter".into()),
        Button::Save => Some("Ctrl+S".into()),
        Button::Colour(c) => Some((c + 1).to_string()),
        Button::Long | Button::Level(_) => None,
    }
}

/// The tooltip: `Rectangle (R)`, or just the name when no key does it.
/// `translate` turns the English name into the app's language.
pub fn tooltip(button: Button, props: Props, translate: impl Fn(&str) -> String) -> String {
    let name = translate(name(button, props));
    match shortcut(button) {
        Some(key) => format!("{name} ({key})"),
        None => name,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MON: Rect = Rect::new(0, 0, 2560, 1440);
    const SEL: Rect = Rect::new(400, 200, 900, 500);

    fn same(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn the_first_row_is_the_specified_sixteen_in_order() {
        let l = layout(SEL, MON, 1.0, Props::None);
        let row: Vec<Button> = l.buttons.iter().map(|(b, _)| *b).collect();
        let mut expected: Vec<Button> = Tool::ALL.iter().map(|t| Button::Tool(*t)).collect();
        expected.extend([Button::Undo, Button::Redo, Button::Long, Button::Save, Button::Cancel, Button::Done]);
        assert_eq!(row, expected);
        assert!(l.buttons.windows(2).all(|w| w[0].1.right() <= w[1].1.x), "left to right, not overlapping");
        assert!(l.props.is_none());
    }

    #[test]
    fn buttons_sit_on_the_grid_with_wider_gaps_between_groups() {
        let l = layout(SEL, MON, 1.0, Props::None);
        let x = |b: Button| l.rect_of(b).unwrap().x;
        assert_eq!(footprint(1.0), (2 * 6 + 16 * 28 + 11 * 4 + 4 * 12, 2 * 40), "552 x 80: one plate, nothing between its rows");
        assert_eq!(l.bar, Rect::new(SEL.right() - 552, SEL.bottom() + 8, 552, 40));
        assert_eq!(l.rect_of(Button::Tool(Tool::Select)), Some(Rect::new(l.bar.x + 6, l.bar.y + 6, 28, 28)));
        // Select | Rect: a group gap.  Rect, Ellipse: an ordinary one.
        assert_eq!(x(Button::Tool(Tool::Rect)) - x(Button::Tool(Tool::Select)), 28 + 12);
        assert_eq!(x(Button::Tool(Tool::Ellipse)) - x(Button::Tool(Tool::Rect)), 28 + 4);
        assert_eq!(x(Button::Undo) - x(Button::Tool(Tool::Mosaic)), 28 + 12);
        assert_eq!(x(Button::Long) - x(Button::Redo), 28 + 12);
        assert_eq!(x(Button::Save) - x(Button::Long), 28 + 4, "Long and Save are one group");
        assert_eq!(x(Button::Cancel) - x(Button::Save), 28 + 12);
        assert_eq!(l.rect_of(Button::Done).unwrap().right(), l.bar.right() - 6, "the last button ends at the padding");
    }

    #[test]
    fn everything_scales_with_the_monitor() {
        let l = layout(SEL, MON, 1.5, Props::Stroke);
        assert_eq!(l.rect_of(Button::Tool(Tool::Select)).unwrap().w, 42);
        assert_eq!(l.rect_of(Button::Colour(0)).unwrap().w, 42, "a colour has a whole cell");
        assert_eq!(footprint(1.5).0, 2 * 9 + 16 * 42 + 11 * 6 + 4 * 18);
    }

    #[test]
    fn the_property_row_follows_the_kind_of_property() {
        let count = |props| {
            let l = layout(SEL, MON, 1.0, props);
            let colours = l.buttons.iter().filter(|(b, _)| matches!(b, Button::Colour(_))).count();
            let levels = l.buttons.iter().filter(|(b, _)| matches!(b, Button::Level(_))).count();
            (colours, levels, l.props.is_some())
        };
        assert_eq!(count(Props::None), (0, 0, false));
        assert_eq!(count(Props::Stroke), (9, 5, true));
        assert_eq!(count(Props::Font), (9, 5, true));
        assert_eq!(count(Props::Block), (0, 5, true), "a mosaic has no colour");
    }

    #[test]
    fn the_property_row_is_under_the_first_and_holds_its_buttons() {
        let l = layout(SEL, MON, 1.0, Props::Stroke);
        let row = l.props.unwrap();
        // Directly under the first row and as wide: one plate.
        assert_eq!(row, Rect::new(l.bar.x, l.bar.bottom(), l.bar.w, 40));
        assert_eq!(l.plate(), Rect::new(l.bar.x, l.bar.y, 552, 80));
        assert_eq!(layout(SEL, MON, 1.0, Props::None).plate(), Rect::new(l.bar.x, l.bar.y, 552, 40));
        for (b, r) in &l.buttons {
            if matches!(b, Button::Colour(_) | Button::Level(_)) {
                assert!(r.x >= row.x + 6 && r.right() <= row.right() - 6 && r.y >= row.y && r.bottom() <= row.bottom(), "{b:?}");
                assert_eq!((r.w, r.h), (28, 28), "{b:?}: a whole cell");
            }
        }
        // The contents are at the left: 464 of the 552 points.
        assert_eq!(l.rect_of(Button::Level(4)).unwrap().right() + 6 - row.x, 2 * 6 + 9 * 28 + 8 * 4 + 12 + 5 * 28 + 4 * 4);
        assert_eq!(l.rect_of(Button::Colour(0)), Some(Rect::new(row.x + 6, row.y + 6, 28, 28)));
        let block = layout(SEL, MON, 1.0, Props::Block);
        assert_eq!(block.rect_of(Button::Level(0)).unwrap().x, block.bar.x + 6, "with no swatches the steps start at the left");
        assert_eq!(block.props.unwrap().w, 552, "and the plate is as wide all the same");
    }

    /// The grid at 200%, in pixels: arithmetic, so it is exact (§9.8.13 B).
    #[test]
    fn at_two_hundred_percent_every_cell_is_on_the_grid_to_the_pixel() {
        let l = layout(SEL, MON, 2.0, Props::Font);
        let first: Vec<Rect> = l.buttons.iter().filter(|(b, _)| !matches!(b, Button::Colour(_) | Button::Level(_))).map(|(_, r)| *r).collect();
        assert_eq!(first.len(), 16);
        assert!(first.iter().all(|r| r.y == first[0].y && (r.w, r.h) == (56, 56)));
        // Within a group 64 apart, across groups 80: 1 / 9 / 2 / 1 / 2.
        let steps: Vec<i32> = first.windows(2).map(|w| w[1].x - w[0].x).collect();
        assert_eq!(steps, [80, 64, 64, 64, 64, 64, 64, 64, 64, 80, 64, 80, 64, 80, 64]);
        let second: Vec<Rect> = l.buttons.iter().filter(|(b, _)| matches!(b, Button::Colour(_) | Button::Level(_))).map(|(_, r)| *r).collect();
        assert!(second.iter().all(|r| r.y == second[0].y && (r.w, r.h) == (56, 56)));
        let steps: Vec<i32> = second.windows(2).map(|w| w[1].x - w[0].x).collect();
        assert_eq!(steps, [64, 64, 64, 64, 64, 64, 64, 64, 80, 64, 64, 64, 64], "nine colours, a group gap, five steps");
        // Both rows start at the plate's left edge and 12, the plate is 1104
        // wide and 160 tall, and the second row's cells are 24 under the first's.
        assert_eq!((first[0].x, second[0].x), (l.bar.x + 12, l.bar.x + 12));
        assert_eq!((l.plate().w, l.plate().h, layout(SEL, MON, 2.0, Props::None).plate().h), (1104, 160, 80));
        assert_eq!(second[0].y, first[0].bottom() + 24);
    }

    #[test]
    fn showing_the_property_row_does_not_move_the_first() {
        let without = layout(SEL, MON, 1.0, Props::None);
        let with = layout(SEL, MON, 1.0, Props::Font);
        assert_eq!(without.bar, with.bar);
        assert_eq!(without.rect_of(Button::Done), with.rect_of(Button::Done));
    }

    #[test]
    fn it_goes_above_when_both_rows_do_not_fit_below() {
        // Room for one row under the selection but not for two.
        let low = Rect::new(400, 800, 900, 590);
        let l = layout(low, MON, 1.0, Props::Stroke);
        assert_eq!(l.bar.y, low.y - 8 - 80);
        assert!(l.props.unwrap().bottom() <= low.y - 8);
        // The whole monitor selected: inside the bottom edge.
        let l = layout(MON, MON, 1.0, Props::Stroke);
        assert_eq!(l.props.unwrap().bottom(), MON.bottom() - 8);
    }

    #[test]
    fn a_click_finds_its_button_and_the_bar_swallows_the_gaps() {
        let l = layout(SEL, MON, 1.0, Props::Stroke);
        let r = l.rect_of(Button::Tool(Tool::Arrow)).unwrap();
        assert_eq!(l.button_at(Point::new(r.x + 5, r.y + 5)), Some(Button::Tool(Tool::Arrow)));
        let gap = Point::new(r.right() + 1, r.y + 5);
        assert_eq!(l.button_at(gap), None);
        assert!(l.covers(gap), "between two buttons is still the toolbar");
        let swatch = l.rect_of(Button::Colour(3)).unwrap();
        assert_eq!(l.button_at(Point::new(swatch.x, swatch.y)), Some(Button::Colour(3)));
        assert!(l.covers(Point::new(swatch.x, swatch.y - 2)));
        assert!(!l.covers(Point::new(SEL.x + 10, SEL.y + 10)));
        // There is no "between the rows": the plate is one piece.
        assert!(l.covers(Point::new(l.bar.x + 10, l.bar.bottom())));
        assert!(l.covers(Point::new(l.bar.right() - 1, l.props.unwrap().bottom() - 1)), "the empty right of the second row too");
        assert!(!l.covers(Point::new(l.bar.x + 10, l.props.unwrap().bottom())));
    }

    #[test]
    fn a_tooltip_is_the_name_and_the_key() {
        let tip = |b| tooltip(b, Props::Stroke, same);
        assert_eq!(tip(Button::Tool(Tool::Rect)), "Rectangle (R)");
        assert_eq!(tip(Button::Tool(Tool::Select)), "Select (V)");
        assert_eq!(tip(Button::Tool(Tool::Line)), "Straight Line (L)");
        assert_eq!(tip(Button::Undo), "Undo (Ctrl+Z)");
        assert_eq!(tip(Button::Redo), "Redo (Ctrl+Shift+Z)");
        assert_eq!(tip(Button::Done), "Done (Enter)");
        assert_eq!(tip(Button::Cancel), "Cancel (Esc)");
        assert_eq!(tip(Button::Long), "Long Screenshot", "no key, no brackets");
        assert_eq!(tip(Button::Colour(0)), "Red (1)");
        assert_eq!(tip(Button::Colour(8)), "White (9)");
        assert_eq!(
            tooltip(Button::Tool(Tool::Mosaic), Props::None, |s| format!("<{s}>")),
            "<Mosaic> (M)",
            "the name is translated, the key is not"
        );
    }

    #[test]
    fn a_step_button_is_named_for_what_it_is_a_step_of() {
        assert_eq!(tooltip(Button::Level(2), Props::Stroke, same), "Thickness");
        assert_eq!(tooltip(Button::Level(2), Props::Font, same), "Font Size");
        assert_eq!(tooltip(Button::Level(2), Props::Block, same), "Block Size");
    }

    /// **The floor for every word in this crate.** A host passes the English
    /// to the core's catalogue; a word that is not a msgid there comes back
    /// unchanged, so a Chinese toolbar shows one English tooltip and nothing
    /// anywhere fails. This reads the catalogue's template.
    #[test]
    fn every_word_shown_is_a_msgid_in_the_cores_catalogue() {
        // The template is named after the bundle id; found by its extension
        // so the name is not written here.
        let po = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../po");
        let pot = std::fs::read_dir(&po)
            .unwrap_or_else(|e| panic!("cannot list {}: {e}", po.display()))
            .filter_map(|d| d.ok().map(|d| d.path()))
            .find(|p| p.extension().is_some_and(|x| x == "pot"))
            .unwrap_or_else(|| panic!("no .pot in {}", po.display()));
        let catalogue =
            std::fs::read_to_string(&pot).unwrap_or_else(|e| panic!("cannot read {}: {e}", pot.display()));
        let all = words();
        assert!(all.len() >= 35, "only {} words were collected", all.len());
        for word in all {
            let entry = format!("\nmsgid {}\n", serde_json::to_string(word).unwrap());
            assert!(catalogue.contains(&entry), "{word:?} is not a msgid in {}", pot.display());
        }
    }

    #[test]
    fn every_tools_tooltip_names_the_key_that_selects_it() {
        for tool in Tool::ALL {
            let tip = tooltip(Button::Tool(tool), Props::None, same);
            assert!(tip.ends_with(&format!("({})", tool.letter())), "{tip}");
            assert_eq!(crate::overlay::key(tool.letter() as u16, crate::dclick::Mods::NONE, true), crate::overlay::Key::Tool(tool));
        }
    }

    #[test]
    fn the_status_line_says_what_to_do_until_something_was_added() {
        use crate::stitch::Step;
        for quiet in [Step::First, Step::Unchanged, Step::Moving, Step::Seen, Step::Back] {
            assert_eq!(long_hint(quiet, false, false), Some(LONG_HINT), "{quiet:?}");
            assert_eq!(long_hint(quiet, true, false), None, "{quiet:?}");
        }
        assert_eq!(long_hint(Step::Added(5), true, false), None);
        // A frame that could not be followed, and the limit, say so whether
        // or not anything was added before.
        for added in [false, true] {
            assert_eq!(long_hint(Step::Lost, added, false), Some(LONG_SLOWER));
            assert_eq!(long_hint(Step::Full, added, false), Some(LONG_FULL));
        }
    }

    #[test]
    fn the_status_line_says_when_the_region_never_holds_still() {
        use crate::stitch::Step;
        // Not at once: the first frame of every long screenshot is held
        // back, and nobody has done anything wrong yet.
        assert!(!long_restless(true, 0));
        assert!(!long_restless(true, LONG_RESTLESS_AFTER - 1));
        assert!(long_restless(true, LONG_RESTLESS_AFTER));
        // Frames held back while scrolling, after one was joined, are not it.
        assert!(!long_restless(false, 500));
        // And then it is said in place of what to do, which cannot help.
        assert_eq!(long_hint(Step::Unchanged, false, true), Some(LONG_RESTLESS));
        assert_eq!(long_hint(Step::Unchanged, false, false), Some(LONG_HINT));
        assert!(words().contains(&LONG_RESTLESS));
    }
}
