//! The two-row toolbar: where each button is, and what its tooltip says.
//!
//! Specification §9.1. The first row is the tools and the commands; the
//! second is the properties of the current tool, or of the selected
//! annotation. Sizes are in points and follow the grid the macOS toolbar
//! uses: 28-point buttons, 4 between them, 12 between groups, 6 of padding.

use crate::geom::{Point, Rect};
use crate::style::{self, Props, Tool};

pub const BUTTON: u32 = 28;
pub const GAP: u32 = 4;
pub const GROUP_GAP: u32 = 12;
pub const PADDING: u32 = 6;
/// Between the two rows.
pub const ROW_GAP: u32 = 4;
pub const SWATCH: u32 = 20;
/// Between the selection and the toolbar.
pub const OFFSET: u32 = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Tool(Tool),
    Undo,
    Redo,
    Long,
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
    &[Button::Long],
    &[Button::Cancel, Button::Done],
];

/// Where everything on the toolbar is, in virtual-screen pixels.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    /// The first row's background.
    pub bar: Rect,
    /// The property row's background, when it is shown.
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

    pub fn rect_of(&self, button: Button) -> Option<Rect> {
        self.buttons.iter().find(|(b, _)| *b == button).map(|(_, r)| *r)
    }
}

/// The size both rows take together, in pixels: what is kept clear for the
/// toolbar whether or not the property row is showing, so that picking a
/// tool does not make it jump.
pub fn footprint(scale: f64) -> (i32, i32) {
    let px = |points: u32| style::px(points, scale);
    let buttons: i32 = ROW.iter().map(|g| g.len() as i32).sum();
    let inner_gaps: i32 = ROW.iter().map(|g| g.len() as i32 - 1).sum();
    let width = px(PADDING) * 2 + buttons * px(BUTTON) + inner_gaps * px(GAP) + (ROW.len() as i32 - 1) * px(GROUP_GAP);
    let row = px(BUTTON) + px(PADDING) * 2;
    (width, row * 2 + px(ROW_GAP))
}

/// Lay the toolbar out beside `selection` on `monitor`: below it, or above,
/// or inside its bottom edge (`geom::toolbar_origin`). `props` is which
/// property row to show.
pub fn layout(selection: Rect, monitor: Rect, scale: f64, props: Props) -> Layout {
    let px = |points: u32| style::px(points, scale);
    let (width, height) = footprint(scale);
    let origin = crate::geom::toolbar_origin(selection, (width, height), monitor, px(OFFSET));
    let row_h = px(BUTTON) + px(PADDING) * 2;
    let mut buttons = Vec::new();

    let mut x = origin.x + px(PADDING);
    let y = origin.y + px(PADDING);
    for (g, group) in ROW.iter().enumerate() {
        if g > 0 {
            x += px(GROUP_GAP) - px(GAP);
        }
        for button in group.iter() {
            buttons.push((*button, Rect::new(x, y, px(BUTTON), px(BUTTON))));
            x += px(BUTTON) + px(GAP);
        }
    }
    let bar = Rect::new(origin.x, origin.y, width, row_h);

    let mut props_rect = None;
    if props != Props::None {
        let top = origin.y + row_h + px(ROW_GAP);
        let mut x = origin.x + px(PADDING);
        if props != Props::Block {
            let inset = (px(BUTTON) - px(SWATCH)) / 2;
            for c in 0..style::COLOURS.len() as u8 {
                buttons.push((Button::Colour(c), Rect::new(x, top + px(PADDING) + inset, px(SWATCH), px(SWATCH))));
                x += px(SWATCH) + px(GAP);
            }
            x += px(GROUP_GAP) - px(GAP);
        }
        for l in 0..style::LEVELS {
            buttons.push((Button::Level(l), Rect::new(x, top + px(PADDING), px(BUTTON), px(BUTTON))));
            x += px(BUTTON) + px(GAP);
        }
        props_rect = Some(Rect::new(origin.x, top, x - px(GAP) + px(PADDING) - origin.x, row_h));
    }
    Layout { bar, props: props_rect, buttons }
}

/// The nine colours' names, in palette order.
pub const COLOUR_NAMES: [&str; 9] = ["Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Black", "White"];

/// A button's name -- the English msgid; the host translates it.
///
/// **Every word the overlay shows is in this file or in `annot::EN`**, so
/// that when the core's list of msgids lands there is one place to check
/// against it.
pub fn name(button: Button) -> &'static str {
    match button {
        Button::Tool(Tool::Select) => "Select",
        Button::Tool(Tool::Rect) => "Rectangle",
        Button::Tool(Tool::Ellipse) => "Ellipse",
        Button::Tool(Tool::Line) => "Line",
        Button::Tool(Tool::Arrow) => "Arrow",
        Button::Tool(Tool::Pen) => "Pen",
        Button::Tool(Tool::Highlighter) => "Highlighter",
        Button::Tool(Tool::Text) => "Text",
        Button::Tool(Tool::Number) => "Number",
        Button::Tool(Tool::Mosaic) => "Mosaic",
        Button::Undo => "Undo",
        Button::Redo => "Redo",
        Button::Long => "Long screenshot",
        Button::Cancel => "Cancel",
        Button::Done => "Done",
        Button::Colour(c) => COLOUR_NAMES[c as usize % COLOUR_NAMES.len()],
        Button::Level(_) => "Size",
    }
}

/// The other words the overlay shows.
pub const FONT_MISSING: &str = "The annotation font is missing; text will not be drawn in it.";
pub const LONG_STATUS: &str = "Long screenshot";
pub const LONG_SLOWER: &str = "Scroll more slowly";
pub const LONG_FULL: &str = "Reached the height limit";

/// The key that does what the button does, as it is written on a Windows
/// keyboard; `None` when there is none.
pub fn shortcut(button: Button) -> Option<String> {
    match button {
        Button::Tool(t) => Some(t.letter().to_string()),
        Button::Undo => Some("Ctrl+Z".into()),
        Button::Redo => Some("Ctrl+Shift+Z".into()),
        Button::Cancel => Some("Esc".into()),
        Button::Done => Some("Enter".into()),
        Button::Colour(c) => Some((c + 1).to_string()),
        Button::Long | Button::Level(_) => None,
    }
}

/// The tooltip: `Rectangle (R)`, or just the name when no key does it.
/// `translate` turns the English name into the app's language.
pub fn tooltip(button: Button, translate: impl Fn(&str) -> String) -> String {
    let name = translate(name(button));
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
    fn the_first_row_is_the_specified_fifteen_in_order() {
        let l = layout(SEL, MON, 1.0, Props::None);
        let row: Vec<Button> = l.buttons.iter().map(|(b, _)| *b).collect();
        let mut expected: Vec<Button> = Tool::ALL.iter().map(|t| Button::Tool(*t)).collect();
        expected.extend([Button::Undo, Button::Redo, Button::Long, Button::Cancel, Button::Done]);
        assert_eq!(row, expected);
        assert!(l.buttons.windows(2).all(|w| w[0].1.right() <= w[1].1.x), "left to right, not overlapping");
        assert!(l.props.is_none());
    }

    #[test]
    fn buttons_sit_on_the_grid_with_wider_gaps_between_groups() {
        let l = layout(SEL, MON, 1.0, Props::None);
        let x = |b: Button| l.rect_of(b).unwrap().x;
        assert_eq!(footprint(1.0), (2 * 6 + 15 * 28 + 10 * 4 + 4 * 12, 2 * 40 + 4));
        assert_eq!(l.bar, Rect::new(SEL.right() - 520, SEL.bottom() + 8, 520, 40));
        assert_eq!(l.rect_of(Button::Tool(Tool::Select)), Some(Rect::new(l.bar.x + 6, l.bar.y + 6, 28, 28)));
        // Select | Rect: a group gap.  Rect, Ellipse: an ordinary one.
        assert_eq!(x(Button::Tool(Tool::Rect)) - x(Button::Tool(Tool::Select)), 28 + 12);
        assert_eq!(x(Button::Tool(Tool::Ellipse)) - x(Button::Tool(Tool::Rect)), 28 + 4);
        assert_eq!(x(Button::Undo) - x(Button::Tool(Tool::Mosaic)), 28 + 12);
        assert_eq!(x(Button::Long) - x(Button::Redo), 28 + 12);
        assert_eq!(x(Button::Cancel) - x(Button::Long), 28 + 12);
        assert_eq!(l.rect_of(Button::Done).unwrap().right(), l.bar.right() - 6, "the last button ends at the padding");
    }

    #[test]
    fn everything_scales_with_the_monitor() {
        let l = layout(SEL, MON, 1.5, Props::Stroke);
        assert_eq!(l.rect_of(Button::Tool(Tool::Select)).unwrap().w, 42);
        assert_eq!(l.rect_of(Button::Colour(0)).unwrap().w, 30);
        assert_eq!(footprint(1.5).0, 2 * 9 + 15 * 42 + 10 * 6 + 4 * 18);
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
        assert_eq!((row.x, row.y, row.h), (l.bar.x, l.bar.bottom() + 4, 40));
        assert_eq!(row.w, 6 + 9 * 20 + 8 * 4 + 12 + 5 * 28 + 4 * 4 + 6);
        for (b, r) in &l.buttons {
            if matches!(b, Button::Colour(_) | Button::Level(_)) {
                assert!(r.x >= row.x + 6 && r.right() <= row.right() - 6 && r.y >= row.y && r.bottom() <= row.bottom(), "{b:?}");
            }
        }
        // A swatch is smaller than a button and centred in the row.
        assert_eq!(l.rect_of(Button::Colour(0)), Some(Rect::new(row.x + 6, row.y + 6 + 4, 20, 20)));
        let block = layout(SEL, MON, 1.0, Props::Block);
        assert_eq!(block.rect_of(Button::Level(0)).unwrap().x, block.bar.x + 6, "with no swatches the steps start at the left");
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
        assert_eq!(l.bar.y, low.y - 8 - 84);
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
        // Between the rows is not the toolbar.
        assert!(!l.covers(Point::new(l.bar.x + 10, l.bar.bottom() + 1)));
    }

    #[test]
    fn a_tooltip_is_the_name_and_the_key() {
        assert_eq!(tooltip(Button::Tool(Tool::Rect), same), "Rectangle (R)");
        assert_eq!(tooltip(Button::Tool(Tool::Select), same), "Select (V)");
        assert_eq!(tooltip(Button::Undo, same), "Undo (Ctrl+Z)");
        assert_eq!(tooltip(Button::Redo, same), "Redo (Ctrl+Shift+Z)");
        assert_eq!(tooltip(Button::Done, same), "Done (Enter)");
        assert_eq!(tooltip(Button::Cancel, same), "Cancel (Esc)");
        assert_eq!(tooltip(Button::Long, same), "Long screenshot", "no key, no brackets");
        assert_eq!(tooltip(Button::Colour(0), same), "Red (1)");
        assert_eq!(tooltip(Button::Colour(8), same), "White (9)");
        assert_eq!(tooltip(Button::Tool(Tool::Mosaic), |s| format!("<{s}>")), "<Mosaic> (M)", "the name is translated, the key is not");
    }

    #[test]
    fn every_tools_tooltip_names_the_key_that_selects_it() {
        for tool in Tool::ALL {
            let tip = tooltip(Button::Tool(tool), same);
            assert!(tip.ends_with(&format!("({})", tool.letter())), "{tip}");
            assert_eq!(crate::overlay::key(tool.letter() as u16, crate::dclick::Mods::NONE, true), crate::overlay::Key::Tool(tool));
        }
    }
}
