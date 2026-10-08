//! Annotations as data: what they are, where a click lands on one, how one
//! is moved and reshaped, and how they leave -- the sidecar `.json` beside a
//! shot and the one line of text pasted after the image's path.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md` §4, §9.4 and §11.
//!
//! **Coordinates are the frozen screen's**, not the selection's (§9.4): an
//! annotation stays where it was drawn when the selection is moved or
//! resized afterwards. [`Item::relative_to`] the selection's origin is done
//! once, on the way out.

use crate::geom::{Handle, Point, Rect};
use crate::name::Stamp;
use crate::style::{self, Props, Tool};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Shape {
    /// A hollow rectangle.
    Rect(Rect),
    /// A hollow ellipse inscribed in the rectangle.
    Ellipse(Rect),
    Line { from: Point, to: Point },
    Arrow { from: Point, to: Point },
    /// A freehand line.
    Pen(Vec<Point>),
    /// A freehand line four times as wide, laid over the picture like a
    /// marker rather than painted on it.
    Highlighter(Vec<Point>),
    /// `at` is the top-left corner of the first line. `size` is what the
    /// text measures in the font it is drawn in, kept so a click can be
    /// tested against it without a font.
    Text { at: Point, text: String, size: (i32, i32) },
    /// A numbered circle centred on `at`, with the sentence typed after
    /// placing it. `size` is the sentence's measured size.
    Number { n: u32, at: Point, text: String, size: (i32, i32) },
    /// A rectangle whose contents are made unreadable.
    Mosaic(Rect),
}

/// One annotation: a shape, and the colour and step it is drawn with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub shape: Shape,
    /// Index into [`style::COLOURS`]. Unused by a mosaic.
    pub colour: u8,
    /// The step of whichever property the shape has: thickness, font size
    /// or block size.
    pub level: u8,
    /// A colour that is not one of the nine: an agent may ask for any
    /// (§10.1). `None` for everything drawn by hand, which uses `colour`.
    pub rgb: Option<(u8, u8, u8)>,
}

/// Where a shape can be taken hold of to change it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Grip {
    /// One of the eight handles of a rectangle, an ellipse or a mosaic.
    Box(Handle),
    /// The start (`false`) or end (`true`) of a line or an arrow.
    End(bool),
}

/// A number's circle: its radius in pixels. The diameter is one and a half
/// times the font's height.
pub fn number_radius(level: u8, scale: f64) -> i32 {
    (style::font_px(level, scale) * 3 + 2) / 4
}

/// Where a number's sentence starts (top-left), given the circle's centre:
/// to the right of the circle by 0.3 of the font's height, centred on it.
pub fn caption_at(at: Point, level: u8, scale: f64, caption_height: i32) -> Point {
    let font = style::font_px(level, scale);
    Point::new(at.x + number_radius(level, scale) + (font * 3 + 5) / 10, at.y - caption_height / 2)
}

impl Item {
    /// The colour this is drawn in, as R, G, B.
    pub fn colour_rgb(&self) -> (u8, u8, u8) {
        self.rgb.unwrap_or(style::COLOURS[self.colour as usize % style::COLOURS.len()])
    }

    /// The same, as `#RRGGBB`.
    pub fn colour_hex(&self) -> String {
        let (r, g, b) = self.colour_rgb();
        format!("#{r:02X}{g:02X}{b:02X}")
    }

    /// The tool that makes this kind of annotation.
    pub fn tool(&self) -> Tool {
        match self.shape {
            Shape::Rect(_) => Tool::Rect,
            Shape::Ellipse(_) => Tool::Ellipse,
            Shape::Line { .. } => Tool::Line,
            Shape::Arrow { .. } => Tool::Arrow,
            Shape::Pen(_) => Tool::Pen,
            Shape::Highlighter(_) => Tool::Highlighter,
            Shape::Text { .. } => Tool::Text,
            Shape::Number { .. } => Tool::Number,
            Shape::Mosaic(_) => Tool::Mosaic,
        }
    }

    /// What the property row shows for this annotation.
    pub fn props(&self) -> Props {
        self.tool().props()
    }

    /// The stroke's width in pixels, for the shapes that have one.
    pub fn stroke_px(&self, scale: f64) -> i32 {
        let w = style::width_px(self.level, scale);
        match self.shape {
            Shape::Highlighter(_) => w * style::HIGHLIGHTER_FACTOR as i32,
            _ => w,
        }
    }

    /// The rectangle everything this annotation draws falls inside.
    pub fn bounds(&self, scale: f64) -> Rect {
        let grow = |r: Rect, by: i32| Rect::new(r.x - by, r.y - by, r.w + by * 2, r.h + by * 2);
        let half = (self.stroke_px(scale) + 1) / 2;
        let empty = Rect::new(0, 0, 0, 0);
        match &self.shape {
            Shape::Rect(r) | Shape::Ellipse(r) => grow(*r, half),
            Shape::Mosaic(r) => *r,
            Shape::Line { from, to } => grow(bbox(&[*from, *to]).unwrap_or(empty), half),
            // An arrow's head is five widths long and as wide.
            Shape::Arrow { from, to } => grow(bbox(&[*from, *to]).unwrap_or(empty), self.stroke_px(scale) * 5),
            Shape::Pen(points) | Shape::Highlighter(points) => grow(bbox(points).unwrap_or(empty), half),
            Shape::Text { at, size, .. } => Rect::new(at.x, at.y, size.0, size.1),
            Shape::Number { at, size, .. } => {
                let r = number_radius(self.level, scale);
                let circle = Rect::new(at.x - r, at.y - r, r * 2, r * 2);
                if size.0 <= 0 {
                    return circle;
                }
                let c = caption_at(*at, self.level, scale, size.1);
                let (l, t) = (circle.x.min(c.x), circle.y.min(c.y));
                Rect::from_ltrb(l, t, circle.right().max(c.x + size.0), circle.bottom().max(c.y + size.1))
            }
        }
    }

    /// Whether a click at `p` lands on this annotation.
    ///
    /// **By the stroke, not by the bounding box** (§9.4): the inside of a
    /// hollow rectangle is not the rectangle, and something drawn inside it
    /// has to stay clickable. A thin line is given a few pixels either side
    /// so it can be hit at all. Text and numbers are hit anywhere in their
    /// box; a mosaic anywhere in its rectangle.
    pub fn hit(&self, p: Point, scale: f64) -> bool {
        let reach = (self.stroke_px(scale) as f64 / 2.0).max(4.0 * scale);
        let on_path = |points: &[Point]| match points {
            [only] => dist(p, *only) <= reach,
            _ => points.windows(2).any(|s| dist_to_segment(p, s[0], s[1]) <= reach),
        };
        match &self.shape {
            Shape::Rect(r) => {
                let (a, b) = (r.origin(), Point::new(r.right(), r.y));
                let (c, d) = (Point::new(r.right(), r.bottom()), Point::new(r.x, r.bottom()));
                on_path(&[a, b, c, d, a])
            }
            Shape::Ellipse(r) => dist_to_ellipse(p, *r) <= reach,
            Shape::Line { from, to } | Shape::Arrow { from, to } => on_path(&[*from, *to]),
            Shape::Pen(points) | Shape::Highlighter(points) => on_path(points),
            Shape::Text { .. } | Shape::Number { .. } | Shape::Mosaic(_) => self.bounds(scale).contains(p),
        }
    }

    /// Whether `p` is inside what this outlines: a rectangle's or an ellipse's
    /// inside, which [`Self::hit`] does not take (they are hollow, and what is
    /// inside them can be selected). **Only the selected annotation is held
    /// by its inside** (`Editor`): that is the second of two clicks.
    pub fn holds(&self, p: Point) -> bool {
        match &self.shape {
            Shape::Rect(r) => r.contains(p),
            Shape::Ellipse(r) => {
                let (a, b) = (r.w as f64 / 2.0, r.h as f64 / 2.0);
                let (x, y) = (p.x as f64 - (r.x as f64 + a), p.y as f64 - (r.y as f64 + b));
                a > 0.0 && b > 0.0 && (x / a).powi(2) + (y / b).powi(2) <= 1.0
            }
            _ => false,
        }
    }

    /// The same annotation moved by `(dx, dy)`.
    pub fn moved(&self, dx: i32, dy: i32) -> Item {
        let m = |p: &Point| Point::new(p.x + dx, p.y + dy);
        let mr = |r: &Rect| Rect::new(r.x + dx, r.y + dy, r.w, r.h);
        let shape = match &self.shape {
            Shape::Rect(r) => Shape::Rect(mr(r)),
            Shape::Ellipse(r) => Shape::Ellipse(mr(r)),
            Shape::Mosaic(r) => Shape::Mosaic(mr(r)),
            Shape::Line { from, to } => Shape::Line { from: m(from), to: m(to) },
            Shape::Arrow { from, to } => Shape::Arrow { from: m(from), to: m(to) },
            Shape::Pen(points) => Shape::Pen(points.iter().map(m).collect()),
            Shape::Highlighter(points) => Shape::Highlighter(points.iter().map(m).collect()),
            Shape::Text { at, text, size } => Shape::Text { at: m(at), text: text.clone(), size: *size },
            Shape::Number { n, at, text, size } => Shape::Number { n: *n, at: m(at), text: text.clone(), size: *size },
        };
        Item { shape, colour: self.colour, level: self.level, rgb: self.rgb }
    }

    /// The same annotation in a space whose origin is `origin`.
    pub fn relative_to(&self, origin: Point) -> Item {
        self.moved(-origin.x, -origin.y)
    }

    /// Where this annotation can be reshaped from: eight handles for a
    /// rectangle, an ellipse and a mosaic, the two ends of a line and an
    /// arrow, and nowhere for the rest (they only move).
    pub fn grips(&self) -> Vec<(Grip, Point)> {
        match &self.shape {
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Mosaic(r) => {
                Handle::ALL.iter().map(|h| (Grip::Box(*h), h.at(*r))).collect()
            }
            Shape::Line { from, to } | Shape::Arrow { from, to } => {
                vec![(Grip::End(false), *from), (Grip::End(true), *to)]
            }
            _ => Vec::new(),
        }
    }

    /// The grip within `reach` pixels of `p`, if any.
    pub fn grip_at(&self, p: Point, reach: i32) -> Option<Grip> {
        self.grips()
            .into_iter()
            .find(|(_, at)| (p.x - at.x).abs() <= reach && (p.y - at.y).abs() <= reach)
            .map(|(g, _)| g)
    }

    /// The same annotation with `grip` dragged to `to`. A grip that is not
    /// this shape's changes nothing.
    pub fn reshaped(&self, grip: Grip, to: Point) -> Item {
        const EVERYWHERE: Rect = Rect::new(i32::MIN / 4, i32::MIN / 4, i32::MAX / 2, i32::MAX / 2);
        let shape = match (&self.shape, grip) {
            (Shape::Rect(r), Grip::Box(h)) => Shape::Rect(crate::geom::resize(*r, h, to, EVERYWHERE)),
            (Shape::Ellipse(r), Grip::Box(h)) => Shape::Ellipse(crate::geom::resize(*r, h, to, EVERYWHERE)),
            (Shape::Mosaic(r), Grip::Box(h)) => Shape::Mosaic(crate::geom::resize(*r, h, to, EVERYWHERE)),
            (Shape::Line { from, to: end }, Grip::End(e)) => {
                if e {
                    Shape::Line { from: *from, to }
                } else {
                    Shape::Line { from: to, to: *end }
                }
            }
            (Shape::Arrow { from, to: end }, Grip::End(e)) => {
                if e {
                    Shape::Arrow { from: *from, to }
                } else {
                    Shape::Arrow { from: to, to: *end }
                }
            }
            (other, _) => other.clone(),
        };
        Item { shape, colour: self.colour, level: self.level, rgb: self.rgb }
    }

    /// Whether the shape is too small to be worth keeping: a rectangle,
    /// ellipse or mosaic under two pixels either way, a line of no length, a
    /// freehand stroke of a single point, a text with nothing in it.
    pub fn is_degenerate(&self) -> bool {
        match &self.shape {
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Mosaic(r) => r.w < 2 || r.h < 2,
            Shape::Line { from, to } | Shape::Arrow { from, to } => from == to,
            Shape::Pen(points) | Shape::Highlighter(points) => points.len() < 2,
            Shape::Text { text, .. } => text.trim().is_empty(),
            Shape::Number { .. } => false,
        }
    }
}

fn dist(a: Point, b: Point) -> f64 {
    (((a.x - b.x) as f64).powi(2) + ((a.y - b.y) as f64).powi(2)).sqrt()
}

/// How far `p` is from the segment `a`-`b`.
pub fn dist_to_segment(p: Point, a: Point, b: Point) -> f64 {
    let (vx, vy) = ((b.x - a.x) as f64, (b.y - a.y) as f64);
    let len2 = vx * vx + vy * vy;
    if len2 == 0.0 {
        return dist(p, a);
    }
    let t = ((((p.x - a.x) as f64) * vx + ((p.y - a.y) as f64) * vy) / len2).clamp(0.0, 1.0);
    let (cx, cy) = (a.x as f64 + t * vx, a.y as f64 + t * vy);
    ((p.x as f64 - cx).powi(2) + (p.y as f64 - cy).powi(2)).sqrt()
}

/// How far `p` is from the outline of the ellipse inscribed in `r`, measured
/// along the line from the centre through `p`. Exact for a circle and close
/// enough for a click everywhere else.
fn dist_to_ellipse(p: Point, r: Rect) -> f64 {
    let (a, b) = (r.w as f64 / 2.0, r.h as f64 / 2.0);
    if a <= 0.0 || b <= 0.0 {
        return f64::INFINITY;
    }
    let (x, y) = (p.x as f64 - (r.x as f64 + a), p.y as f64 - (r.y as f64 + b));
    let radius = (x * x + y * y).sqrt();
    let k = ((x / a).powi(2) + (y / b).powi(2)).sqrt();
    if k == 0.0 {
        return a.min(b);
    }
    (radius - radius / k).abs()
}

/// The topmost annotation under `p`: the last one drawn that the point hits.
pub fn hit_test(items: &[Item], p: Point, scale: f64) -> Option<usize> {
    items.iter().rposition(|i| i.hit(p, scale))
}

/// The number the next numbered circle gets: one more than the highest there
/// is, so undoing ③ makes the next one ③ again, and deleting ② from the
/// middle does not renumber anything.
pub fn next_number(items: &[Item]) -> u32 {
    items.iter().filter_map(|i| if let Shape::Number { n, .. } = i.shape { Some(n) } else { None }).max().unwrap_or(0)
        + 1
}

/// The smallest rectangle holding every point, both ends included. `None`
/// for no points.
pub fn bbox(points: &[Point]) -> Option<Rect> {
    let first = points.first()?;
    let (mut l, mut t, mut r, mut b) = (first.x, first.y, first.x, first.y);
    for p in points {
        l = l.min(p.x);
        t = t.min(p.y);
        r = r.max(p.x);
        b = b.max(p.y);
    }
    Some(Rect::from_ltrb(l, t, r + 1, b + 1))
}

/// A line or arrow from `from` towards `to`, turned to the nearest multiple
/// of 45 degrees and kept the same length (shift held while drawing).
pub fn snap_45(from: Point, to: Point) -> Point {
    let (dx, dy) = ((to.x - from.x) as f64, (to.y - from.y) as f64);
    let len = (dx * dx + dy * dy).sqrt();
    if len == 0.0 {
        return to;
    }
    let step = std::f64::consts::FRAC_PI_4;
    let angle = (dy.atan2(dx) / step).round() * step;
    Point::new(from.x + (len * angle.cos()).round() as i32, from.y + (len * angle.sin()).round() as i32)
}

/// The corner opposite `from` of the square a drag towards `to` makes (shift
/// held while drawing a rectangle or an ellipse): the longer of the two
/// sides, in the drag's direction on each axis.
pub fn square_corner(from: Point, to: Point) -> Point {
    let side = (to.x - from.x).abs().max((to.y - from.y).abs());
    let sign = |d: i32| if d < 0 { -1 } else { 1 };
    Point::new(from.x + side * sign(to.x - from.x), from.y + side * sign(to.y - from.y))
}

/// The annotations that reach into `selection`, moved into the image's
/// coordinates. Ones wholly outside are left out; ones partly outside keep
/// their true geometry, so a coordinate can be negative or past the image's
/// size -- the picture is cut at the edge, the description is not bent to it.
pub fn exported(items: &[Item], selection: Rect, scale: f64) -> Vec<Item> {
    items
        .iter()
        .filter(|i| i.bounds(scale).intersect(selection).is_some())
        .map(|i| i.relative_to(selection.origin()))
        .collect()
}

// ------------------------------------------------------------ the sidecar

/// Who took the shot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum By {
    User,
    /// An agent, through the MCP tools; the terminal it runs in.
    Agent { terminal: String },
}

/// What a shot is of. Rectangles are in physical pixels on the virtual
/// screen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// A window chosen by clicking it. Any of its names may be unknown.
    Window {
        app: Option<String>,
        title: Option<String>,
        pid: Option<u32>,
        window_rect: Option<Rect>,
        selection_rect: Rect,
    },
    /// A free selection.
    Region { selection_rect: Rect },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Display {
    pub index: usize,
    pub size: (u32, u32),
    pub scale: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Terminal {
    pub id: String,
    pub cwd: Option<String>,
    /// `(head, dirty)` when `cwd` is in a git repository and git answered in
    /// time.
    pub git: Option<(String, bool)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tile {
    pub image: String,
    pub y: u32,
    pub height: u32,
}

/// Everything in the sidecar that is not an annotation.
#[derive(Clone, Debug, PartialEq)]
pub struct Meta {
    /// The image's file name, without a directory.
    pub image: String,
    /// Local time the shot was taken.
    pub taken: Stamp,
    /// The local time zone's offset from UTC in minutes, east positive.
    pub utc_offset_minutes: i32,
    /// The image's width and height in pixels.
    pub size: (u32, u32),
    /// The monitor's scale factor: its DPI over 96.
    pub scale: f64,
    pub by: By,
    pub display: Option<Display>,
    /// `light` or `dark`.
    pub appearance: Option<String>,
    pub source: Source,
    pub terminal: Option<Terminal>,
    /// The file name of the previous shot of the same window.
    pub previous: Option<String>,
    /// A long screenshot's pieces. Empty for an ordinary one.
    pub tiles: Vec<Tile>,
    /// Rectangles of the image painted black because a shielded terminal
    /// was there, in image pixels. Only an agent's shots have any.
    pub redacted: Vec<Rect>,
}

fn quoted(s: &str) -> String {
    // `to_string` on a `&str` cannot fail; the fallback is never taken.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

fn taken_at(t: &Stamp, offset_minutes: i32) -> String {
    let sign = if offset_minutes < 0 { '-' } else { '+' };
    let off = offset_minutes.unsigned_abs();
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{}{:02}:{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second, sign, off / 60, off % 60
    )
}

/// `{:?}` on an `f64` always shows a fraction (2.0, 1.25); a scale that is
/// not a positive number is written as 1.0.
fn scale_text(scale: f64) -> String {
    format!("{:?}", if scale.is_finite() && scale > 0.0 { scale } else { 1.0 })
}

fn rect_text(r: &Rect) -> String {
    format!("[{}, {}, {}, {}]", r.x, r.y, r.w, r.h)
}

/// One annotation as its sidecar entry. Sizes are the step's value in
/// logical points, not pixels: `width` for strokes, `font_size` for text and
/// numbers, `block` for a mosaic -- which records where and how coarse, and
/// nothing of what was under it.
fn entry(item: &Item) -> String {
    let colour = item.colour_hex();
    let level = item.level.min(style::LEVELS - 1) as usize;
    let stroke = format!("\"color\": \"{colour}\", \"width\": {}", style::WIDTHS[level]);
    let font = format!("\"color\": \"{colour}\", \"font_size\": {}", style::FONTS[level]);
    let empty = Rect::new(0, 0, 0, 0);
    let ends = |kind: &str, from: &Point, to: &Point| {
        format!(
            "{{\"type\": \"{kind}\", \"from\": [{}, {}], \"to\": [{}, {}], {stroke}}}",
            from.x, from.y, to.x, to.y
        )
    };
    match &item.shape {
        Shape::Number { n, at, text, .. } => format!(
            "{{\"n\": {n}, \"type\": \"number\", \"at\": [{}, {}], \"text\": {}, {font}}}",
            at.x,
            at.y,
            quoted(text)
        ),
        Shape::Rect(r) => format!("{{\"type\": \"rect\", \"rect\": {}, \"text\": \"\", {stroke}}}", rect_text(r)),
        Shape::Ellipse(r) => format!("{{\"type\": \"ellipse\", \"rect\": {}, {stroke}}}", rect_text(r)),
        Shape::Line { from, to } => ends("line", from, to),
        Shape::Arrow { from, to } => ends("arrow", from, to),
        Shape::Text { at, text, .. } => {
            format!("{{\"type\": \"text\", \"at\": [{}, {}], \"text\": {}, {font}}}", at.x, at.y, quoted(text))
        }
        Shape::Pen(points) => {
            format!("{{\"type\": \"pen\", \"bbox\": {}, {stroke}}}", rect_text(&bbox(points).unwrap_or(empty)))
        }
        Shape::Highlighter(points) => format!(
            "{{\"type\": \"highlighter\", \"bbox\": {}, {stroke}}}",
            rect_text(&bbox(points).unwrap_or(empty))
        ),
        Shape::Mosaic(r) => {
            format!("{{\"type\": \"mosaic\", \"rect\": {}, \"block\": {}}}", rect_text(r), style::MOSAIC[level].0)
        }
    }
}

/// The sidecar `.json`, version 2. `items` are in image pixels.
///
/// Keys are written in the specification's order, which is why this is
/// assembled by hand; every string goes through `serde_json` for escaping.
/// **A key whose value is unknown is left out, not written empty** -- that
/// goes for an empty string as much as for a `None`.
pub fn sidecar(meta: &Meta, items: &[Item]) -> String {
    let named = |key: &str, value: &Option<String>| {
        value.as_deref().filter(|v| !v.is_empty()).map(|v| format!("\"{key}\": {}", quoted(v)))
    };
    let source = {
        let mut parts = Vec::new();
        match &meta.source {
            Source::Region { selection_rect } => {
                parts.push("\"kind\": \"region\"".to_string());
                parts.push(format!("\"selection_rect\": {}", rect_text(selection_rect)));
            }
            Source::Window { app, title, pid, window_rect, selection_rect } => {
                parts.push("\"kind\": \"window\"".to_string());
                parts.extend(named("app", app));
                parts.extend(named("title", title));
                parts.extend(pid.map(|p| format!("\"pid\": {p}")));
                parts.extend(window_rect.as_ref().map(|r| format!("\"window_rect\": {}", rect_text(r))));
                parts.push(format!("\"selection_rect\": {}", rect_text(selection_rect)));
            }
        }
        format!("{{{}}}", parts.join(", "))
    };

    let mut lines = vec![
        "\"version\": 2".to_string(),
        format!("\"image\": {}", quoted(&meta.image)),
        format!("\"taken_at\": {}", quoted(&taken_at(&meta.taken, meta.utc_offset_minutes))),
        format!("\"size\": [{}, {}]", meta.size.0, meta.size.1),
        format!("\"scale\": {}", scale_text(meta.scale)),
    ];
    match &meta.by {
        By::User => lines.push("\"by\": \"user\"".to_string()),
        By::Agent { terminal } => {
            lines.push("\"by\": \"agent\"".to_string());
            lines.extend(named("agent_terminal", &Some(terminal.clone())));
        }
    }
    if let Some(d) = &meta.display {
        lines.push(format!(
            "\"display\": {{\"index\": {}, \"size\": [{}, {}], \"scale\": {}}}",
            d.index,
            d.size.0,
            d.size.1,
            scale_text(d.scale)
        ));
    }
    lines.extend(named("appearance", &meta.appearance));
    lines.push(format!("\"source\": {source}"));
    if let Some(t) = &meta.terminal {
        // Each part that is known; a terminal about which nothing is known
        // is not written at all.
        let mut parts = Vec::new();
        parts.extend(named("id", &Some(t.id.clone())));
        parts.extend(named("cwd", &t.cwd));
        if let Some((head, dirty)) = t.git.as_ref().filter(|g| !g.0.is_empty()) {
            parts.push(format!("\"git\": {{\"head\": {}, \"dirty\": {dirty}}}", quoted(head)));
        }
        if !parts.is_empty() {
            lines.push(format!("\"terminal\": {{{}}}", parts.join(", ")));
        }
    }
    lines.extend(named("previous", &meta.previous));
    if !meta.tiles.is_empty() {
        let tiles: Vec<String> = meta
            .tiles
            .iter()
            .map(|t| format!("{{\"image\": {}, \"y\": {}, \"height\": {}}}", quoted(&t.image), t.y, t.height))
            .collect();
        lines.push(format!("\"tiles\": [{}]", tiles.join(", ")));
    }
    if !meta.redacted.is_empty() {
        let rects: Vec<String> = meta.redacted.iter().map(rect_text).collect();
        lines.push(format!("\"redacted\": [{}]", rects.join(", ")));
    }
    let entries: Vec<String> = items.iter().map(entry).collect();
    lines.push(if entries.is_empty() {
        "\"annotations\": []".to_string()
    } else {
        format!("\"annotations\": [\n    {}\n  ]", entries.join(",\n    "))
    });
    format!("{{\n  {}\n}}\n", lines.join(",\n  "))
}

// ---------------------------------------------------------- the one line

/// The words of the pasted line, so each host can supply its own language.
///
/// **One field per msgid in `src/input/screenshot.zig`**, which is where the
/// two hosts' wording is kept the same; the comments give the English msgid
/// and the Chinese it is translated to.
#[derive(Clone, Copy, Debug)]
pub struct Labels<'a> {
    /// `Screenshot annotations` / `截图标注`
    pub header: &'a str,
    /// `Text` / `文字`
    pub text: &'a str,
    /// `Box` / `框`
    pub rect: &'a str,
    /// `Circle` / `圆`
    pub ellipse: &'a str,
    /// `Line` / `线`
    pub line: &'a str,
    /// `Arrow` / `箭头`
    pub arrow: &'a str,
    /// `Pen` / `画笔`
    pub pen: &'a str,
    /// `Highlighter` / `荧光笔`
    pub highlighter: &'a str,
    /// `Mosaic` / `马赛克`
    pub mosaic: &'a str,
    /// Between two annotations: `; ` / `；`
    pub separator: &'a str,
    /// After the last annotation and before the path: `. See ` / `。详见 `.
    /// Its spaces are part of it.
    pub see: &'a str,
}

/// The specification's own wording.
pub const ZH: Labels<'static> = Labels {
    header: "截图标注",
    text: "文字",
    rect: "框",
    ellipse: "圆",
    line: "线",
    arrow: "箭头",
    pen: "画笔",
    highlighter: "荧光笔",
    mosaic: "马赛克",
    separator: "；",
    see: "。详见 ",
};

/// The msgids themselves.
pub const EN: Labels<'static> = Labels {
    header: "Screenshot annotations",
    text: "Text",
    rect: "Box",
    ellipse: "Circle",
    line: "Line",
    arrow: "Arrow",
    pen: "Pen",
    highlighter: "Highlighter",
    mosaic: "Mosaic",
    separator: "; ",
    see: ". See ",
};

/// A number as the pasted line writes it: `#1`, `#2`, ...
///
/// **Plain ASCII, and that is a measured requirement, not a taste.** The
/// line is pasted into console programs, and on Windows a pasted `①`
/// (U+2460) or `×` (U+00D7) reaches them as U+0000 (task 1090; the cause is
/// the console's, tracked separately). So everything this crate itself puts
/// in the line -- the size, the numbers, the arrow between two points -- is
/// ASCII. The words are the translator's and what the person typed is theirs.
/// The circle drawn on the picture still shows the number; the sidecar is
/// unchanged.
pub fn numbered(n: u32) -> String {
    format!("#{n}")
}

/// `text` with every control character turned into a space.
///
/// **This is what keeps the line one line.** It is pasted at a prompt, and a
/// newline typed into a caption -- text annotations may have several lines --
/// would otherwise submit half the line.
fn flat(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect::<String>().trim().to_string()
}

/// The one line pasted after the image's path, or `None` when there are no
/// annotations and so nothing to say. Shapes with no words still make a line:
/// where they are is the information. A mosaic says only where it is.
///
/// `[截图标注 1280x800] #1 (412,96) 这个按钮没对齐；文字 (60,500) 间距太大；框
/// (380,80,240,44)；箭头 (100,300)->(220,340)。详见 <json path>`
pub fn line(size: (u32, u32), items: &[Item], json_path: &str, l: &Labels) -> Option<String> {
    if items.is_empty() {
        return None;
    }
    let with = |head: String, text: &str| {
        let text = flat(text);
        if text.is_empty() {
            head
        } else {
            format!("{head} {text}")
        }
    };
    let boxed = |word: &str, r: &Rect| format!("{word} ({},{},{},{})", r.x, r.y, r.w, r.h);
    let ends = |word: &str, a: &Point, b: &Point| format!("{word} ({},{})->({},{})", a.x, a.y, b.x, b.y);
    let empty = Rect::new(0, 0, 0, 0);
    let parts: Vec<String> = items
        .iter()
        .map(|i| match &i.shape {
            Shape::Number { n, at, text, .. } => with(format!("{} ({},{})", numbered(*n), at.x, at.y), text),
            Shape::Text { at, text, .. } => with(format!("{} ({},{})", l.text, at.x, at.y), text),
            Shape::Rect(r) => boxed(l.rect, r),
            Shape::Ellipse(r) => boxed(l.ellipse, r),
            Shape::Mosaic(r) => boxed(l.mosaic, r),
            Shape::Line { from, to } => ends(l.line, from, to),
            Shape::Arrow { from, to } => ends(l.arrow, from, to),
            Shape::Pen(points) => boxed(l.pen, &bbox(points).unwrap_or(empty)),
            Shape::Highlighter(points) => boxed(l.highlighter, &bbox(points).unwrap_or(empty)),
        })
        .collect();
    Some(format!("[{} {}x{}] {}{}{}", l.header, size.0, size.1, parts.join(l.separator), l.see, flat(json_path)))
}

/// The words of the line that follows a long screenshot's tiles.
///
/// ⚠️ **One sentence today, and due to change.** The core's catalogue has
/// this as a single msgid ending in `Whole image: `; a two-part wording
/// (`{n} tiles, first {m} pasted` and `whole image`) is agreed and not yet
/// merged. Everything about the wording is in this struct, [`LONG_EN`] and
/// [`long_line`], so the change is here and nowhere else.
#[derive(Clone, Copy, Debug)]
pub struct LongLabels<'a> {
    /// `Long Screenshot` / `长截图`
    pub header: &'a str,
    /// `{n} tiles, first {m} pasted` / `共 {n} 片，已粘贴前 {m} 片` -- `{n}`
    /// and `{m}` are replaced with the two numbers, in whichever order the
    /// language puts them.
    pub tiles: &'a str,
    /// `whole image` / `整图`; a space and the image's path follow.
    pub whole: &'a str,
    /// `; ` / `；`, between the two halves.
    pub separator: &'a str,
    /// `. See ` / `。详见 `
    pub see: &'a str,
}

/// The core's msgids (`src/input/screenshot.zig`: `screenshot`'s long form,
/// `long_tiles`, `long_whole`, `separator`, `see`).
pub const LONG_EN: LongLabels<'static> = LongLabels {
    header: "Long Screenshot",
    tiles: "{n} tiles, first {m} pasted",
    whole: "whole image",
    separator: "; ",
    see: ". See ",
};

/// The line pasted after a long screenshot's tiles when not all of them were
/// pasted: how many there are, how many went in, and where the whole picture
/// is. `None` when every tile was pasted -- there is then nothing to add.
///
/// `[Long Screenshot 1280x9000] 12 tiles, first 8 pasted; whole image <png
/// path>. See <json path>` -- the same line the macOS side writes
/// (`ShotSidecar.longLine`).
pub fn long_line(
    size: (u32, u32),
    tiles: usize,
    pasted: usize,
    image_path: &str,
    json_path: &str,
    l: &LongLabels,
) -> Option<String> {
    if tiles <= pasted {
        return None;
    }
    let count = l.tiles.replace("{n}", &tiles.to_string()).replace("{m}", &pasted.to_string());
    Some(format!(
        "[{} {}x{}] {}{}{} {}{}{}",
        l.header,
        size.0,
        size.1,
        count,
        l.separator,
        l.whole,
        flat(image_path),
        l.see,
        flat(json_path)
    ))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    const P: fn(i32, i32) -> Point = Point::new;

    pub(crate) fn it(shape: Shape) -> Item {
        Item { shape, colour: 0, level: 1, rgb: None }
    }

    fn text(at: Point, s: &str) -> Shape {
        Shape::Text { at, text: s.into(), size: (s.chars().count() as i32 * 10, 18) }
    }

    fn number(n: u32, at: Point, s: &str) -> Shape {
        let size = (s.chars().count() as i32 * 10, if s.is_empty() { 0 } else { 18 });
        Shape::Number { n, at, text: s.into(), size }
    }

    /// The specification's example, §4.1 and §4.2.
    fn example() -> Vec<Item> {
        vec![
            it(number(1, P(412, 96), "这个按钮没对齐")),
            it(Shape::Rect(Rect::new(380, 80, 240, 44))),
            it(Shape::Arrow { from: P(100, 300), to: P(220, 340) }),
            it(text(P(60, 500), "间距太大")),
            it(Shape::Pen(vec![P(10, 10), P(89, 30), P(40, 49)])),
        ]
    }

    fn meta(source: Source) -> Meta {
        Meta {
            image: "20261006-153012-123.png".into(),
            taken: Stamp { year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12, milli: 123 },
            utc_offset_minutes: 480,
            size: (1280, 800),
            scale: 2.0,
            by: By::User,
            display: None,
            appearance: None,
            source,
            terminal: None,
            previous: None,
            tiles: Vec::new(),
            redacted: Vec::new(),
        }
    }

    const SEL: Rect = Rect::new(120, 80, 1280, 800);

    #[test]
    fn the_sidecar_is_the_specified_document() {
        let source = Source::Window {
            app: Some("Google Chrome".into()),
            title: Some("…".into()),
            pid: Some(4242),
            window_rect: Some(SEL),
            selection_rect: SEL,
        };
        let mut m = meta(source);
        m.display = Some(Display { index: 0, size: (2560, 1440), scale: 2.0 });
        m.appearance = Some("dark".into());
        m.terminal =
            Some(Terminal { id: "0x17e4".into(), cwd: Some("/w/proj".into()), git: Some(("3d65ad0".into(), true)) });
        m.previous = Some("20261006-152233-101.png".into());
        m.tiles = vec![Tile { image: "20261006-153012-123-1.png".into(), y: 0, height: 1800 }];
        let expected = r##"{
  "version": 2,
  "image": "20261006-153012-123.png",
  "taken_at": "2026-10-06T15:30:12+08:00",
  "size": [1280, 800],
  "scale": 2.0,
  "by": "user",
  "display": {"index": 0, "size": [2560, 1440], "scale": 2.0},
  "appearance": "dark",
  "source": {"kind": "window", "app": "Google Chrome", "title": "…", "pid": 4242, "window_rect": [120, 80, 1280, 800], "selection_rect": [120, 80, 1280, 800]},
  "terminal": {"id": "0x17e4", "cwd": "/w/proj", "git": {"head": "3d65ad0", "dirty": true}},
  "previous": "20261006-152233-101.png",
  "tiles": [{"image": "20261006-153012-123-1.png", "y": 0, "height": 1800}],
  "annotations": [
    {"n": 1, "type": "number", "at": [412, 96], "text": "这个按钮没对齐", "color": "#E62828", "font_size": 18},
    {"type": "rect", "rect": [380, 80, 240, 44], "text": "", "color": "#E62828", "width": 2},
    {"type": "arrow", "from": [100, 300], "to": [220, 340], "color": "#E62828", "width": 2},
    {"type": "text", "at": [60, 500], "text": "间距太大", "color": "#E62828", "font_size": 18},
    {"type": "pen", "bbox": [10, 10, 80, 40], "color": "#E62828", "width": 2}
  ]
}
"##;
        assert_eq!(sidecar(&m, &example()), expected);
    }

    #[test]
    fn the_new_shapes_have_their_own_entries() {
        let items = vec![
            Item { shape: Shape::Ellipse(Rect::new(1, 2, 30, 40)), colour: 5, level: 4, rgb: None },
            Item { shape: Shape::Line { from: P(1, 2), to: P(3, 4) }, colour: 8, level: 0, rgb: None },
            Item { shape: Shape::Highlighter(vec![P(10, 10), P(29, 19)]), colour: 2, level: 2, rgb: None },
            Item { shape: Shape::Mosaic(Rect::new(5, 6, 70, 80)), colour: 0, level: 3, rgb: None },
            Item { shape: number(2, P(9, 9), ""), colour: 3, level: 4, rgb: None },
        ];
        let doc = sidecar(&meta(Source::Region { selection_rect: SEL }), &items);
        let v: serde_json::Value = serde_json::from_str(&doc).unwrap();
        let a = &v["annotations"];
        assert_eq!(
            a[0],
            serde_json::json!({"type": "ellipse", "rect": [1, 2, 30, 40], "color": "#2F6FED", "width": 10})
        );
        assert_eq!(
            a[1],
            serde_json::json!({"type": "line", "from": [1, 2], "to": [3, 4], "color": "#FFFFFF", "width": 1})
        );
        assert_eq!(
            a[2],
            serde_json::json!({"type": "highlighter", "bbox": [10, 10, 20, 10], "color": "#FFD400", "width": 4})
        );
        assert_eq!(
            a[3],
            serde_json::json!({"type": "mosaic", "rect": [5, 6, 70, 80], "block": 24}),
            "where and how coarse, nothing else"
        );
        assert_eq!(
            a[4],
            serde_json::json!({"n": 2, "type": "number", "at": [9, 9], "text": "", "color": "#2DB84D", "font_size": 44})
        );
    }

    #[test]
    fn the_sidecar_parses_as_json_whatever_was_typed() {
        let nasty = "a \"quoted\" \\ back\nslash\tand } ] , \u{1}";
        let items = vec![it(text(P(1, 2), nasty)), it(number(2, P(3, 4), nasty))];
        let source = Source::Window {
            app: Some(nasty.into()),
            title: Some(nasty.into()),
            pid: None,
            window_rect: None,
            selection_rect: SEL,
        };
        let mut m = meta(source);
        m.terminal = Some(Terminal { id: nasty.into(), cwd: Some(nasty.into()), git: Some((nasty.into(), false)) });
        m.by = By::Agent { terminal: nasty.into() };
        let v: serde_json::Value = serde_json::from_str(&sidecar(&m, &items)).unwrap();
        assert_eq!(v["annotations"][0]["text"], nasty);
        assert_eq!(v["annotations"][1]["text"], nasty);
        assert_eq!(v["source"]["app"], nasty);
        assert_eq!(v["source"]["title"], nasty);
        assert_eq!(v["terminal"]["cwd"], nasty);
        assert_eq!(v["terminal"]["git"]["head"], nasty);
        assert_eq!(v["by"], "agent");
        assert_eq!(v["agent_terminal"], nasty);
        assert_eq!(v["version"], 2);
    }

    #[test]
    fn what_is_unknown_or_empty_is_left_out() {
        let v = |m: &Meta| -> serde_json::Value { serde_json::from_str(&sidecar(m, &[])).unwrap() };
        let w = v(&meta(Source::Window {
            app: None,
            title: Some(String::new()),
            pid: None,
            window_rect: None,
            selection_rect: SEL,
        }));
        assert_eq!(w["source"], serde_json::json!({"kind": "window", "selection_rect": [120, 80, 1280, 800]}));
        let r = v(&meta(Source::Region { selection_rect: SEL }));
        assert_eq!(r["source"], serde_json::json!({"kind": "region", "selection_rect": [120, 80, 1280, 800]}));
        assert_eq!(r["annotations"], serde_json::json!([]));
        for key in ["display", "appearance", "terminal", "previous", "tiles", "agent_terminal", "redacted"] {
            assert!(r.get(key).is_none(), "{key} has no value and must not be written");
        }
        assert_eq!(r["by"], "user");
        // A terminal with no cwd and no git; a previous that is the empty string.
        let mut m = meta(Source::Region { selection_rect: SEL });
        m.terminal = Some(Terminal { id: "0x1".into(), cwd: None, git: None });
        m.previous = Some(String::new());
        m.appearance = Some(String::new());
        let t = v(&m);
        assert_eq!(t["terminal"], serde_json::json!({"id": "0x1"}));
        // The id is the part a host may not have: the rest is still written.
        m.terminal = Some(Terminal { id: String::new(), cwd: Some("/w".into()), git: Some(("abc1234".into(), false)) });
        assert_eq!(v(&m)["terminal"], serde_json::json!({"cwd": "/w", "git": {"head": "abc1234", "dirty": false}}));
        m.terminal = Some(Terminal { id: String::new(), cwd: None, git: None });
        assert!(v(&m).get("terminal").is_none(), "nothing known is nothing written");
        m.terminal = Some(Terminal { id: "0x1".into(), cwd: None, git: None });
        assert!(t.get("previous").is_none());
        assert!(t.get("appearance").is_none());
    }

    #[test]
    fn what_was_blacked_out_is_on_record() {
        let mut m = meta(Source::Region { selection_rect: SEL });
        m.redacted = vec![Rect::new(10, 20, 300, 200), Rect::new(0, 0, 5, 5)];
        let v: serde_json::Value = serde_json::from_str(&sidecar(&m, &[])).unwrap();
        assert_eq!(v["redacted"], serde_json::json!([[10, 20, 300, 200], [0, 0, 5, 5]]));
    }

    #[test]
    fn the_time_carries_its_offset_and_the_scale_its_fraction() {
        let mut m = meta(Source::Region { selection_rect: SEL });
        m.utc_offset_minutes = -210;
        m.scale = 1.25;
        let v: serde_json::Value = serde_json::from_str(&sidecar(&m, &[])).unwrap();
        assert_eq!(v["taken_at"], "2026-10-06T15:30:12-03:30");
        assert!(sidecar(&m, &[]).contains("\"scale\": 1.25,"));
        m.utc_offset_minutes = 0;
        m.scale = f64::NAN;
        assert!(sidecar(&m, &[]).contains("+00:00"));
        assert!(sidecar(&m, &[]).contains("\"scale\": 1.0,"));
    }

    #[test]
    fn annotations_on_the_screen_land_on_the_image_and_those_outside_are_left_out() {
        // The selection, on a monitor left of the primary.
        let sel = Rect::new(-3000, 100, 1280, 800);
        let on_screen = vec![
            it(number(1, P(-2588, 196), "x")),
            it(Shape::Rect(Rect::new(-2620, 180, 240, 44))),
            it(Shape::Pen(vec![P(-2990, 110), P(-2911, 149)])),
            // Wholly to the left of the selection.
            it(Shape::Rect(Rect::new(-3500, 200, 100, 100))),
            // Straddling its right edge: kept, with its true geometry.
            it(Shape::Ellipse(Rect::new(-1800, 200, 200, 100))),
            // Below it.
            it(text(P(-2900, 1000), "below")),
        ];
        let got = exported(&on_screen, sel, 1.0);
        assert_eq!(
            got,
            vec![
                it(number(1, P(412, 96), "x")),
                it(Shape::Rect(Rect::new(380, 80, 240, 44))),
                it(Shape::Pen(vec![P(10, 10), P(89, 49)])),
                it(Shape::Ellipse(Rect::new(1200, 100, 200, 100))),
            ]
        );
    }

    #[test]
    fn a_stroke_that_only_touches_the_selection_with_its_thickness_is_still_exported() {
        // A line 4 px left of the selection, 10 pt wide at scale 2: 20 px.
        let sel = Rect::new(100, 100, 200, 200);
        let near = Item { shape: Shape::Line { from: P(96, 150), to: P(96, 250) }, colour: 0, level: 4, rgb: None };
        assert_eq!(exported(&[near.clone()], sel, 2.0).len(), 1);
        let thin = Item { level: 0, ..near };
        assert_eq!(exported(&[thin], sel, 1.0).len(), 0);
    }

    #[test]
    fn the_line_is_the_specified_sentence() {
        let got = line((1280, 800), &example(), r"C:\shots\20261006-153012-123.json", &ZH).unwrap();
        assert_eq!(
            got,
            "[截图标注 1280x800] #1 (412,96) 这个按钮没对齐；框 (380,80,240,44)；\
             箭头 (100,300)->(220,340)；文字 (60,500) 间距太大；画笔 (10,10,80,40)。\
             详见 C:\\shots\\20261006-153012-123.json"
        );
    }

    #[test]
    fn the_line_has_a_word_for_each_new_shape_and_a_mosaic_says_only_where() {
        let items = vec![
            it(Shape::Ellipse(Rect::new(1, 2, 3, 4))),
            it(Shape::Line { from: P(1, 2), to: P(3, 4) }),
            it(Shape::Highlighter(vec![P(10, 10), P(29, 19)])),
            Item { shape: Shape::Mosaic(Rect::new(5, 6, 7, 8)), colour: 0, level: 4, rgb: None },
        ];
        assert_eq!(
            line((10, 10), &items, "j", &ZH).unwrap(),
            "[截图标注 10x10] 圆 (1,2,3,4)；线 (1,2)->(3,4)；荧光笔 (10,10,20,10)；马赛克 (5,6,7,8)。详见 j"
        );
        assert_eq!(
            line((10, 10), &items, "j", &EN).unwrap(),
            "[Screenshot annotations 10x10] Circle (1,2,3,4); Line (1,2)->(3,4); \
             Highlighter (10,10,20,10); Mosaic (5,6,7,8). See j"
        );
    }

    #[test]
    fn a_long_screenshot_says_how_many_tiles_there_are_only_when_some_were_left_out() {
        assert_eq!(long_line((1280, 9000), 5, 5, "a.png", "a.json", &LONG_EN), None);
        assert_eq!(long_line((1280, 9000), 8, 8, "a.png", "a.json", &LONG_EN), None);
        assert_eq!(
            long_line((1280, 19000), 12, 8, "a.png", "a.json", &LONG_EN).unwrap(),
            "[Long Screenshot 1280x19000] 12 tiles, first 8 pasted; whole image a.png. See a.json"
        );
        // The catalogue's Chinese, and a wording that puts the two numbers
        // the other way round.
        let zh = LongLabels { header: "长截图", tiles: "共 {n} 片，已粘贴前 {m} 片", whole: "整图", separator: "；", see: "。详见 " };
        assert_eq!(
            long_line((1280, 19000), 12, 8, "a.png", "a.json", &zh).unwrap(),
            "[长截图 1280x19000] 共 12 片，已粘贴前 8 片；整图 a.png。详见 a.json"
        );
        let turned = LongLabels { tiles: "已粘贴前 {m} 片，共 {n} 片", ..zh };
        assert_eq!(
            long_line((1280, 19000), 12, 8, "a.png", "a.json", &turned).unwrap(),
            "[长截图 1280x19000] 已粘贴前 8 片，共 12 片；整图 a.png。详见 a.json"
        );
    }

    #[test]
    fn no_annotations_is_no_line_but_shapes_without_words_are_one() {
        assert_eq!(line((10, 10), &[], "x.json", &ZH), None);
        let shapes = [it(Shape::Rect(Rect::new(1, 2, 3, 4)))];
        assert_eq!(line((10, 10), &shapes, "x.json", &ZH).unwrap(), "[截图标注 10x10] 框 (1,2,3,4)。详见 x.json");
    }

    #[test]
    fn a_text_of_several_lines_does_not_break_the_line() {
        let items = [it(text(P(1, 2), "first\r\nsecond\tthird\u{1b}[0m")), it(number(1, P(3, 4), "\n"))];
        let got = line((10, 10), &items, "x.json", &ZH).unwrap();
        assert!(!got.chars().any(char::is_control), "{got:?}");
        assert_eq!(got, "[截图标注 10x10] 文字 (1,2) first  second third [0m；#1 (3,4)。详见 x.json");
    }

    #[test]
    fn what_this_crate_puts_in_the_line_is_ascii() {
        // Shapes only, English words: nothing here is the person's or the
        // translator's, so every character is this crate's own.
        let items = vec![
            it(number(7, P(1, 2), "")),
            it(Shape::Rect(Rect::new(1, 2, 3, 4))),
            it(Shape::Arrow { from: P(1, 2), to: P(3, 4) }),
            it(Shape::Line { from: P(1, 2), to: P(3, 4) }),
            it(Shape::Mosaic(Rect::new(1, 2, 3, 4))),
        ];
        let got = line((1280, 800), &items, "C:\\s\\a.json", &EN).unwrap();
        assert!(got.is_ascii(), "{got}");
        assert!(got.starts_with("[Screenshot annotations 1280x800] #7 (1,2); "), "{got}");
        assert!(got.contains("Arrow (1,2)->(3,4)"), "{got}");
        let long = long_line((1280, 19000), 12, 8, "a.png", "a.json", &LONG_EN).unwrap();
        assert!(long.is_ascii(), "{long}");
    }

    #[test]
    fn numbers_are_written_with_a_hash() {
        let n = |n| it(number(n, P(0, 0), ""));
        let got = line((1, 1), &[n(2), n(20), n(21)], "j", &ZH).unwrap();
        assert_eq!(got, "[截图标注 1x1] #2 (0,0)；#20 (0,0)；#21 (0,0)。详见 j");
    }

    #[test]
    fn the_next_number_follows_the_highest_and_deleting_one_does_not_renumber() {
        let mut items = example();
        assert_eq!(next_number(&[]), 1);
        assert_eq!(next_number(&items), 2);
        items.push(it(number(2, P(0, 0), "")));
        items.push(it(number(3, P(0, 0), "")));
        assert_eq!(next_number(&items), 4);
        items.remove(5); // #2 goes; ③ stays ③
        assert_eq!(next_number(&items), 4);
        items.pop();
        assert_eq!(next_number(&items), 2);
    }

    #[test]
    fn a_bounding_box_includes_both_ends() {
        assert_eq!(bbox(&[P(10, 10), P(89, 30), P(40, 49)]), Some(Rect::new(10, 10, 80, 40)));
        assert_eq!(bbox(&[P(5, 6)]), Some(Rect::new(5, 6, 1, 1)));
        assert_eq!(bbox(&[]), None);
    }

    // ------------------------------------------------------------ hitting

    #[test]
    fn a_hollow_rectangle_is_hit_on_its_outline_not_its_inside() {
        let r = it(Shape::Rect(Rect::new(100, 100, 200, 100)));
        assert!(r.hit(P(100, 150), 1.0), "left edge");
        assert!(r.hit(P(200, 200), 1.0), "bottom edge");
        assert!(r.hit(P(303, 150), 1.0), "within reach outside the right edge");
        assert!(!r.hit(P(200, 150), 1.0), "the middle is not the rectangle");
        assert!(!r.hit(P(310, 150), 1.0));
    }

    #[test]
    fn an_ellipse_is_hit_on_its_outline_not_its_inside() {
        let e = it(Shape::Ellipse(Rect::new(100, 100, 200, 100)));
        assert!(e.hit(P(100, 150), 1.0), "leftmost point");
        assert!(e.hit(P(200, 100), 1.0), "topmost point");
        assert!(!e.hit(P(200, 150), 1.0), "the centre");
        assert!(!e.hit(P(100, 100), 1.0), "the corner of its box is outside the ellipse");
    }

    #[test]
    fn a_line_is_hit_along_its_length_within_reach() {
        let l = it(Shape::Line { from: P(100, 100), to: P(300, 100) });
        assert!(l.hit(P(200, 100), 1.0));
        assert!(l.hit(P(200, 104), 1.0), "four pixels off a thin line still counts");
        assert!(!l.hit(P(200, 105), 1.0));
        assert!(!l.hit(P(306, 100), 1.0), "past the end");
        // A thick stroke reaches as far as it is drawn; so does a scaled one.
        let thick = Item { level: 4, ..l.clone() };
        assert!(thick.hit(P(200, 105), 1.0));
        assert!(l.hit(P(200, 108), 2.0), "the reach is in points, so it doubles at 200%");
        // A highlighter is four times its step.
        let h = Item { shape: Shape::Highlighter(vec![P(100, 100), P(300, 100)]), colour: 2, level: 3, rgb: None };
        assert!(h.hit(P(200, 112), 1.0));
        assert!(!h.hit(P(200, 113), 1.0));
    }

    #[test]
    fn a_freehand_stroke_is_hit_on_any_of_its_segments() {
        let p = it(Shape::Pen(vec![P(0, 0), P(100, 0), P(100, 100)]));
        assert!(p.hit(P(50, 2), 1.0));
        assert!(p.hit(P(98, 60), 1.0));
        assert!(!p.hit(P(50, 50), 1.0), "inside the corner it turns, but on neither segment");
    }

    #[test]
    fn text_numbers_and_mosaics_are_hit_anywhere_in_their_box() {
        let t = it(text(P(100, 100), "hello"));
        assert!(t.hit(P(120, 110), 1.0));
        assert!(!t.hit(P(151, 110), 1.0), "past its measured width of 50");
        let n = it(number(1, P(100, 100), ""));
        assert_eq!(number_radius(1, 1.0), 14);
        assert!(n.hit(P(110, 110), 1.0));
        assert!(!n.hit(P(120, 100), 1.0));
        let with_caption = it(number(1, P(100, 100), "hello"));
        assert!(with_caption.hit(P(140, 100), 1.0), "on the caption");
        let m = it(Shape::Mosaic(Rect::new(0, 0, 50, 50)));
        assert!(m.hit(P(25, 25), 1.0), "a mosaic is solid");
        assert!(!m.hit(P(50, 25), 1.0));
    }

    #[test]
    fn the_topmost_annotation_under_the_point_is_the_one_hit() {
        let items = vec![
            it(Shape::Mosaic(Rect::new(0, 0, 200, 200))),
            it(Shape::Line { from: P(0, 100), to: P(200, 100) }),
            it(Shape::Rect(Rect::new(50, 50, 100, 100))),
        ];
        assert_eq!(hit_test(&items, P(100, 100), 1.0), Some(1), "the line, drawn over the mosaic");
        assert_eq!(hit_test(&items, P(50, 100), 1.0), Some(2), "the rectangle's edge, drawn last");
        assert_eq!(hit_test(&items, P(20, 20), 1.0), Some(0));
        assert_eq!(hit_test(&items, P(300, 300), 1.0), None);
    }

    // ------------------------------------------------- moving and reshaping

    #[test]
    fn moving_keeps_everything_but_the_position() {
        let before = Item { shape: number(3, P(10, 20), "x"), colour: 4, level: 2, rgb: None };
        let after = before.moved(5, -7);
        assert_eq!(after, Item { shape: number(3, P(15, 13), "x"), colour: 4, level: 2, rgb: None });
        let pen = it(Shape::Pen(vec![P(0, 0), P(1, 1)])).moved(10, 10);
        assert_eq!(pen.shape, Shape::Pen(vec![P(10, 10), P(11, 11)]));
        let m = it(Shape::Mosaic(Rect::new(1, 2, 3, 4))).moved(1, 1);
        assert_eq!(m.shape, Shape::Mosaic(Rect::new(2, 3, 3, 4)));
    }

    #[test]
    fn a_colour_outside_the_palette_is_kept_through_moving_and_reshaping() {
        let teal = Item { shape: Shape::Rect(Rect::new(0, 0, 10, 10)), colour: 0, level: 1, rgb: Some((1, 2, 3)) };
        assert_eq!(teal.colour_hex(), "#010203");
        assert_eq!(teal.moved(5, 5).rgb, Some((1, 2, 3)));
        assert_eq!(teal.reshaped(Grip::Box(Handle::SE), P(20, 20)).colour_hex(), "#010203");
        assert_eq!(teal.relative_to(P(3, 3)).colour_rgb(), (1, 2, 3));
        assert_eq!(it(Shape::Rect(Rect::new(0, 0, 10, 10))).colour_hex(), "#E62828", "none given: the palette's");
        let v: serde_json::Value =
            serde_json::from_str(&sidecar(&meta(Source::Region { selection_rect: SEL }), &[teal])).unwrap();
        assert_eq!(v["annotations"][0]["color"], "#010203");
    }

    #[test]
    fn boxes_have_eight_grips_lines_two_and_the_rest_none() {
        let b = Rect::new(0, 0, 10, 10);
        for shape in [Shape::Rect(b), Shape::Ellipse(b), Shape::Mosaic(b)] {
            assert_eq!(it(shape).grips().len(), 8);
        }
        let l = it(Shape::Arrow { from: P(1, 2), to: P(30, 40) });
        assert_eq!(l.grips(), vec![(Grip::End(false), P(1, 2)), (Grip::End(true), P(30, 40))]);
        let stroke = vec![P(0, 0), P(9, 9)];
        for shape in
            [Shape::Pen(stroke.clone()), Shape::Highlighter(stroke), text(P(0, 0), "x"), number(1, P(0, 0), "")]
        {
            assert!(it(shape).grips().is_empty());
        }
    }

    #[test]
    fn a_grip_reshapes_only_what_it_holds() {
        let r = it(Shape::Rect(Rect::new(100, 100, 200, 100)));
        assert_eq!(r.grip_at(P(302, 198), 4), Some(Grip::Box(Handle::SE)));
        assert_eq!(r.grip_at(P(200, 150), 4), None);
        assert_eq!(r.reshaped(Grip::Box(Handle::SE), P(350, 250)).shape, Shape::Rect(Rect::new(100, 100, 250, 150)));
        assert_eq!(r.reshaped(Grip::Box(Handle::W), P(50, 999)).shape, Shape::Rect(Rect::new(50, 100, 250, 100)));
        // Nothing confines an annotation to the monitor: it may be dragged past it.
        assert_eq!(r.reshaped(Grip::Box(Handle::N), P(0, -500)).shape, Shape::Rect(Rect::new(100, -500, 200, 700)));
        let a = it(Shape::Arrow { from: P(0, 0), to: P(10, 10) });
        assert_eq!(a.reshaped(Grip::End(true), P(50, 5)).shape, Shape::Arrow { from: P(0, 0), to: P(50, 5) });
        assert_eq!(a.reshaped(Grip::End(false), P(-5, -5)).shape, Shape::Arrow { from: P(-5, -5), to: P(10, 10) });
        // A grip that is not this shape's changes nothing.
        assert_eq!(a.reshaped(Grip::Box(Handle::N), P(99, 99)), a);
        assert_eq!(r.reshaped(Grip::End(true), P(99, 99)), r);
    }

    #[test]
    fn shift_makes_a_square_and_snaps_a_line_to_forty_five_degrees() {
        assert_eq!(square_corner(P(100, 100), P(180, 130)), P(180, 180));
        assert_eq!(square_corner(P(100, 100), P(60, 190)), P(10, 190), "left and down");
        assert_eq!(square_corner(P(100, 100), P(100, 100)), P(100, 100));
        // Nearly horizontal: horizontal, same length.
        assert_eq!(snap_45(P(0, 0), P(100, 8)), P(100, 0));
        // Nearly diagonal: exactly diagonal.
        assert_eq!(snap_45(P(0, 0), P(100, 90)), P(95, 95));
        assert_eq!(snap_45(P(0, 0), P(-5, -100)), P(0, -100));
        assert_eq!(snap_45(P(50, 50), P(50, 50)), P(50, 50));
    }

    #[test]
    fn what_is_too_small_to_keep() {
        assert!(it(Shape::Rect(Rect::new(0, 0, 1, 50))).is_degenerate());
        assert!(!it(Shape::Rect(Rect::new(0, 0, 2, 2))).is_degenerate());
        assert!(it(Shape::Mosaic(Rect::new(0, 0, 50, 1))).is_degenerate());
        assert!(it(Shape::Line { from: P(1, 1), to: P(1, 1) }).is_degenerate());
        assert!(!it(Shape::Line { from: P(1, 1), to: P(1, 2) }).is_degenerate());
        assert!(it(Shape::Pen(vec![P(1, 1)])).is_degenerate());
        assert!(it(text(P(0, 0), "  \n ")).is_degenerate());
        assert!(!it(number(1, P(0, 0), "")).is_degenerate(), "a number with no sentence is still a number");
    }

    #[test]
    fn bounds_take_in_the_stroke_and_the_caption() {
        let r = Item { shape: Shape::Rect(Rect::new(100, 100, 50, 50)), colour: 0, level: 4, rgb: None };
        assert_eq!(r.bounds(1.0), Rect::new(95, 95, 60, 60));
        assert_eq!(it(Shape::Mosaic(Rect::new(1, 2, 3, 4))).bounds(1.0), Rect::new(1, 2, 3, 4));
        let n = it(number(1, P(100, 100), "hello"));
        // Circle of radius 14; caption 50 x 18 starting 14 + 5 to the right.
        assert_eq!(caption_at(P(100, 100), 1, 1.0, 18), P(119, 91));
        assert_eq!(n.bounds(1.0), Rect::from_ltrb(86, 86, 169, 114));
    }
}
