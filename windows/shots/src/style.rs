//! The tools, and what an annotation can look like: nine colours, five
//! steps of thickness, of font size and of mosaic block.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md` §9.1. Sizes are in
//! **logical points**; a monitor's scale (its DPI over 96) turns them into
//! the physical pixels everything else in this crate is in.

/// The nine preset colours as R, G, B, in the order the number keys 1-9
/// choose them: red, orange, yellow, green, cyan, blue, purple, black, white.
pub const COLOURS: [(u8, u8, u8); 9] = [
    (0xE6, 0x28, 0x28),
    (0xF5, 0x82, 0x1F),
    (0xFF, 0xD4, 0x00),
    (0x2D, 0xB8, 0x4D),
    (0x17, 0xB5, 0xC8),
    (0x2F, 0x6F, 0xED),
    (0x8E, 0x44, 0xD6),
    (0x1A, 0x1A, 0x1A),
    (0xFF, 0xFF, 0xFF),
];

/// How many steps every sized property has.
pub const LEVELS: u8 = 5;
/// The step a tool starts on: the second.
pub const DEFAULT_LEVEL: u8 = 1;
/// The colour a tool starts on: red.
pub const DEFAULT_COLOUR: u8 = 0;

/// Stroke widths, in points.
pub const WIDTHS: [u32; 5] = [1, 2, 4, 6, 10];
/// Font sizes, in points.
pub const FONTS: [u32; 5] = [14, 18, 24, 32, 44];
/// Mosaic steps: the block's edge in points, and `k` -- the most blocks the
/// region's short side may be cut into.
pub const MOSAIC: [(u32, u32); 5] = [(8, 12), (12, 10), (16, 8), (24, 6), (32, 4)];
/// A highlighter stroke is this many times its step's width.
pub const HIGHLIGHTER_FACTOR: u32 = 4;

/// `#RRGGBB` for colour `index`.
pub fn hex(index: u8) -> String {
    let (r, g, b) = COLOURS[index as usize % COLOURS.len()];
    format!("#{r:02X}{g:02X}{b:02X}")
}

/// Points to physical pixels, never less than one.
pub fn px(points: u32, scale: f64) -> i32 {
    ((points as f64 * scale).round() as i32).max(1)
}

/// A stroke's width in pixels at `level`.
pub fn width_px(level: u8, scale: f64) -> i32 {
    px(WIDTHS[level.min(LEVELS - 1) as usize], scale)
}

/// A font's height in pixels at `level`.
pub fn font_px(level: u8, scale: f64) -> i32 {
    px(FONTS[level.min(LEVELS - 1) as usize], scale)
}

/// The edge of a mosaic block in pixels: `max(step x scale, short side / k)`.
///
/// **The second term is what makes a large region unreadable too.** A fixed
/// block that hides a password field leaves a full-screen region legible --
/// big letters survive small blocks. Dividing the short side by `k` keeps it
/// to at most `k` blocks across however large the region is.
pub fn mosaic_block(level: u8, scale: f64, short_side: i32) -> i32 {
    let (points, k) = MOSAIC[level.min(LEVELS - 1) as usize];
    // Rounded up: `k` is a ceiling on the number of blocks, and rounding the
    // edge down would let one more in.
    let by_side = (short_side.max(0) as u32).div_ceil(k) as i32;
    px(points, scale).max(by_side)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tool {
    Select,
    Rect,
    Ellipse,
    Line,
    Arrow,
    Pen,
    Highlighter,
    Text,
    Number,
    Mosaic,
}

/// Which property a tool's second toolbar row offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Props {
    /// Nothing: the row is not shown.
    None,
    /// Nine colours and five thicknesses.
    Stroke,
    /// Nine colours and five font sizes.
    Font,
    /// Five block sizes, no colour.
    Block,
}

impl Tool {
    /// Every tool, in toolbar order.
    pub const ALL: [Tool; 10] = [
        Tool::Select,
        Tool::Rect,
        Tool::Ellipse,
        Tool::Line,
        Tool::Arrow,
        Tool::Pen,
        Tool::Highlighter,
        Tool::Text,
        Tool::Number,
        Tool::Mosaic,
    ];

    /// The letter that selects it (§9.2), upper case -- also its virtual key.
    pub fn letter(self) -> char {
        match self {
            Tool::Select => 'V',
            Tool::Rect => 'R',
            Tool::Ellipse => 'O',
            Tool::Line => 'L',
            Tool::Arrow => 'A',
            Tool::Pen => 'P',
            Tool::Highlighter => 'H',
            Tool::Text => 'T',
            Tool::Number => 'N',
            Tool::Mosaic => 'M',
        }
    }

    pub fn from_letter(letter: char) -> Option<Tool> {
        Tool::ALL.into_iter().find(|t| t.letter() == letter.to_ascii_uppercase())
    }

    pub fn props(self) -> Props {
        match self {
            Tool::Select => Props::None,
            Tool::Text | Tool::Number => Props::Font,
            Tool::Mosaic => Props::Block,
            _ => Props::Stroke,
        }
    }

    /// The name the state file and the sidecar use.
    pub fn name(self) -> &'static str {
        match self {
            Tool::Select => "select",
            Tool::Rect => "rect",
            Tool::Ellipse => "ellipse",
            Tool::Line => "line",
            Tool::Arrow => "arrow",
            Tool::Pen => "pen",
            Tool::Highlighter => "highlighter",
            Tool::Text => "text",
            Tool::Number => "number",
            Tool::Mosaic => "mosaic",
        }
    }
}

/// The colour and step each tool was last used with.
///
/// Remembered per tool for the length of a screenshot, and written to the
/// host's state file so the next screenshot starts where this one left off.
/// It is state, not configuration: nobody edits it by hand.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prefs {
    by_tool: [(u8, u8); 10],
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs { by_tool: [(DEFAULT_COLOUR, DEFAULT_LEVEL); 10] }
    }
}

impl Prefs {
    fn slot(tool: Tool) -> usize {
        Tool::ALL.iter().position(|t| *t == tool).unwrap_or(0)
    }

    pub fn colour(&self, tool: Tool) -> u8 {
        self.by_tool[Self::slot(tool)].0
    }

    pub fn level(&self, tool: Tool) -> u8 {
        self.by_tool[Self::slot(tool)].1
    }

    /// Out-of-range values are brought into range rather than stored.
    pub fn set_colour(&mut self, tool: Tool, colour: u8) {
        self.by_tool[Self::slot(tool)].0 = colour.min(COLOURS.len() as u8 - 1);
    }

    pub fn set_level(&mut self, tool: Tool, level: u8) {
        self.by_tool[Self::slot(tool)].1 = level.min(LEVELS - 1);
    }

    /// The state file's contents.
    pub fn to_json(&self) -> String {
        let tools: Vec<String> = Tool::ALL
            .iter()
            .filter(|t| t.props() != Props::None)
            .map(|t| format!("    \"{}\": {{\"color\": {}, \"level\": {}}}", t.name(), self.colour(*t), self.level(*t)))
            .collect();
        format!("{{\n  \"version\": 1,\n  \"tools\": {{\n{}\n  }}\n}}\n", tools.join(",\n"))
    }

    /// Read a state file. **Anything unreadable is the defaults, tool by
    /// tool**: a file from a newer version, a truncated one, a value out of
    /// range -- none of them may stop a screenshot from being taken, and
    /// none of them may put a colour index past the palette into a tool.
    pub fn from_json(text: &str) -> Prefs {
        let mut prefs = Prefs::default();
        let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else { return prefs };
        for tool in Tool::ALL {
            let entry = &v["tools"][tool.name()];
            if let Some(c) = entry["color"].as_u64().filter(|c| *c < COLOURS.len() as u64) {
                prefs.set_colour(tool, c as u8);
            }
            if let Some(l) = entry["level"].as_u64().filter(|l| *l < LEVELS as u64) {
                prefs.set_level(tool, l as u8);
            }
        }
        prefs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_palette_is_the_specified_nine_in_order() {
        let all: Vec<String> = (0..9).map(hex).collect();
        assert_eq!(
            all,
            ["#E62828", "#F5821F", "#FFD400", "#2DB84D", "#17B5C8", "#2F6FED", "#8E44D6", "#1A1A1A", "#FFFFFF"]
        );
    }

    #[test]
    fn points_become_pixels_by_the_monitors_scale() {
        assert_eq!((0..5).map(|l| width_px(l, 1.0)).collect::<Vec<_>>(), [1, 2, 4, 6, 10]);
        assert_eq!((0..5).map(|l| width_px(l, 1.5)).collect::<Vec<_>>(), [2, 3, 6, 9, 15]);
        assert_eq!((0..5).map(|l| font_px(l, 1.0)).collect::<Vec<_>>(), [14, 18, 24, 32, 44]);
        assert_eq!((0..5).map(|l| font_px(l, 2.0)).collect::<Vec<_>>(), [28, 36, 48, 64, 88]);
        assert_eq!(px(1, 0.25), 1, "never thinner than a pixel");
    }

    #[test]
    fn a_small_region_gets_the_steps_own_block() {
        // 100 px short side: 100/12 is 9, the step's 8 pt at 1.5 is 12.
        assert_eq!(mosaic_block(0, 1.5, 100), 12);
        assert_eq!((0..5).map(|l| mosaic_block(l, 1.0, 40)).collect::<Vec<_>>(), [8, 12, 16, 24, 32]);
    }

    #[test]
    fn a_large_region_is_cut_into_at_most_k_blocks_across() {
        for (level, k) in [(0u8, 12), (1, 10), (2, 8), (3, 6), (4, 4)] {
            for short in [600, 1001, 1440, 2160] {
                let block = mosaic_block(level, 1.0, short);
                let blocks_across = (short as u32).div_ceil(block as u32);
                assert!(blocks_across <= k, "level {level}, short side {short}: {blocks_across} blocks of {block}");
            }
        }
        assert_eq!(mosaic_block(0, 1.0, 1440), 120);
        assert_eq!(mosaic_block(4, 1.0, 1440), 360);
    }

    #[test]
    fn each_tool_has_its_letter_and_its_property_row() {
        let letters: String = Tool::ALL.iter().map(|t| t.letter()).collect();
        assert_eq!(letters, "VROLAPHTNM");
        assert_eq!(Tool::from_letter('h'), Some(Tool::Highlighter));
        assert_eq!(Tool::from_letter('M'), Some(Tool::Mosaic));
        assert_eq!(Tool::from_letter('Z'), None);
        assert_eq!(Tool::Select.props(), Props::None);
        for t in [Tool::Rect, Tool::Ellipse, Tool::Line, Tool::Arrow, Tool::Pen, Tool::Highlighter] {
            assert_eq!(t.props(), Props::Stroke, "{t:?}");
        }
        assert_eq!(Tool::Text.props(), Props::Font);
        assert_eq!(Tool::Number.props(), Props::Font);
        assert_eq!(Tool::Mosaic.props(), Props::Block);
    }

    #[test]
    fn each_tool_remembers_its_own_colour_and_step() {
        let mut p = Prefs::default();
        assert_eq!((p.colour(Tool::Rect), p.level(Tool::Rect)), (0, 1), "red, second step");
        p.set_colour(Tool::Rect, 5);
        p.set_level(Tool::Text, 4);
        assert_eq!(p.colour(Tool::Rect), 5);
        assert_eq!(p.colour(Tool::Ellipse), 0, "another tool's colour did not move");
        assert_eq!(p.level(Tool::Text), 4);
        assert_eq!(p.level(Tool::Number), 1);
    }

    #[test]
    fn what_is_saved_is_what_is_read_back() {
        let mut p = Prefs::default();
        p.set_colour(Tool::Arrow, 8);
        p.set_level(Tool::Arrow, 0);
        p.set_level(Tool::Mosaic, 3);
        assert_eq!(Prefs::from_json(&p.to_json()), p);
    }

    #[test]
    fn an_unreadable_state_file_is_the_defaults_and_never_out_of_range() {
        assert_eq!(Prefs::from_json(""), Prefs::default());
        assert_eq!(Prefs::from_json("not json"), Prefs::default());
        assert_eq!(Prefs::from_json("{\"tools\": 5}"), Prefs::default());
        let p = Prefs::from_json(
            r#"{"tools": {"rect": {"color": 9, "level": 5}, "pen": {"color": -1, "level": "x"}, "text": {"color": 3}}}"#,
        );
        assert_eq!((p.colour(Tool::Rect), p.level(Tool::Rect)), (0, 1), "9 and 5 are past the end");
        assert_eq!((p.colour(Tool::Pen), p.level(Tool::Pen)), (0, 1));
        assert_eq!((p.colour(Tool::Text), p.level(Tool::Text)), (3, 1), "the half that is readable is kept");
        // `true` is not the number 1, nor is "2" the number 2, nor 1.5 a step.
        let odd = Prefs::from_json(
            r#"{"tools": {"rect": {"color": true, "level": true}, "pen": {"color": "2", "level": 1.5}}}"#,
        );
        assert_eq!(odd, Prefs::default());
        let mut q = Prefs::default();
        q.set_colour(Tool::Rect, 200);
        q.set_level(Tool::Rect, 200);
        assert_eq!((q.colour(Tool::Rect), q.level(Tool::Rect)), (8, 4));
    }
}
