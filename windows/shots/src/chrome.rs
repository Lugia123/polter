//! What the overlay draws that is not the picture: the toolbar's plate and
//! its cells in each of their states, the selection's outline and knobs,
//! the frame and grips of a selected annotation, the plates words sit on.
//!
//! Specification §9.8. **Every length and colour is the look's**
//! (`look.rs`, generated from the one data file both hosts read); nothing
//! here is a number of its own. The words on the plates are the host's to
//! draw, in the system's menu font; everything else is drawn here, into
//! the pixels, so it can be looked at by a test on any machine.

use std::collections::HashMap;

use crate::geom::{Handle, Point, Rect};
use crate::glass::Glass;
use crate::icon::{self, Mask};
use crate::look::{self, annotation, colour, levels, size, Rgba};
use crate::paint::{Box2, Surface};
use crate::style::{self, px_f, Props, Tool};
use crate::toolbar::{Button, Layout};

/// How a cell is drawn (§9.8.4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Normal,
    Hover,
    /// The button is held on it.
    Down,
    Selected,
    SelectedHover,
    /// Cannot be pressed; the pointer over it and a press on it change
    /// nothing.
    Off,
}

/// The state of a cell that can be pressed (`enabled`), is the current
/// tool, colour or step (`current`), has the pointer over it and has the
/// button held on it.
pub fn state(enabled: bool, current: bool, hovered: bool, pressed: bool) -> State {
    match (enabled, pressed, current, hovered) {
        (false, ..) => State::Off,
        (_, true, ..) => State::Down,
        (_, _, true, true) => State::SelectedHover,
        (_, _, true, false) => State::Selected,
        (_, _, false, true) => State::Hover,
        _ => State::Normal,
    }
}

/// One cell of the toolbar and how it is to be drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cell {
    pub button: Button,
    pub rect: Rect,
    pub state: State,
}

/// The icons as they have been drawn so far, one for each size asked for:
/// drawing one is a few thousand distances, and a frame draws twenty.
#[derive(Default)]
pub struct Icons {
    drawn: HashMap<(&'static str, i32, u64), Mask>,
}

impl Icons {
    pub fn new() -> Icons {
        Icons::default()
    }

    /// The icon called `key` for a cell `cell` pixels on a side.
    pub fn get(&mut self, key: &'static str, cell: i32, scale: f64) -> Option<&Mask> {
        let icon = look::icon(key)?;
        Some(self.drawn.entry((key, cell, scale.to_bits())).or_insert_with(|| icon::mask(icon, cell, scale)))
    }
}

/// The icon a button of the first row wears.
pub fn icon_of(button: Button) -> Option<&'static str> {
    Some(match button {
        Button::Tool(Tool::Select) => "select",
        Button::Tool(Tool::Rect) => "rect",
        Button::Tool(Tool::Ellipse) => "ellipse",
        Button::Tool(Tool::Line) => "line",
        Button::Tool(Tool::Arrow) => "arrow",
        Button::Tool(Tool::Pen) => "pen",
        Button::Tool(Tool::Highlighter) => "highlighter",
        Button::Tool(Tool::Text) => "text",
        Button::Tool(Tool::Number) => "number",
        Button::Tool(Tool::Mosaic) => "mosaic",
        Button::Undo => "undo",
        Button::Redo => "redo",
        Button::Long => "long",
        Button::Save => "save",
        Button::Cancel => "cancel",
        Button::Done => "done",
        Button::Colour(_) | Button::Level(_) => return None,
    })
}

fn with_alpha(c: Rgba, a: f64) -> Rgba {
    Rgba { a, ..c }
}

/// The few colours everything here is drawn in. The look's own
/// ([`Tones::LOOK`]) -- or, in high-contrast mode, the system's, which the
/// person chose so as to be able to see (§9.8.10): the host fills those in.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tones {
    /// Icons and words.
    pub ink: Rgba,
    /// The lesser words: a tooltip's key, the status line's hint.
    pub ink_dim: Rgba,
    /// What cannot be pressed.
    pub ink_off: Rgba,
    /// The ring, a chosen cell's picture, the selection's line.
    pub accent: Rgba,
    /// What is drawn on the accent colour: Done's tick while it is held.
    pub on_accent: Rgba,
    /// A plate that is not glass, and the line round it.
    pub plate: Rgba,
    pub plate_edge: Rgba,
}

impl Tones {
    pub const LOOK: Tones = Tones {
        ink: colour::INK,
        ink_dim: colour::INK_DIM,
        ink_off: colour::INK_OFF,
        accent: colour::ACCENT,
        on_accent: colour::DONE_DOWN_INK,
        plate: colour::PLATE_OPAQUE,
        plate_edge: colour::PLATE_OPAQUE_EDGE,
    };
}

/// A plate of glass at `rect` with corners rounded by `radius` points: its
/// shadow, the dark line round it, the glass, the light line inside its
/// edge (§9.8.6.2). On a system that asks for less transparency: its
/// shadow, the opaque colour and one line.
pub fn plate(s: &mut Surface, glass: &Glass, rect: Rect, radius: f64, scale: f64, tones: &Tones) {
    let b = Box2::of(rect);
    let r = radius * scale;
    s.shadow(b.moved(0.0, size::PLATE_SHADOW_DY * scale), r, size::PLATE_SHADOW_SIGMA * scale, b, colour::PLATE_SHADOW);
    let edge = px_f(size::PLATE_EDGE, scale) as f64;
    if !glass.is_frosted() {
        s.rounded(b, r, tones.plate);
        s.ring(b, r, px_f(1.0, scale) as f64, tones.plate_edge);
        return;
    }
    s.outline(b, r, edge, colour::PLATE_OUTER_EDGE);
    s.picture(rect, &glass.plate(rect, scale), b, r);
    s.ring(b, r, edge, colour::PLATE_INNER_EDGE);
}

/// What is drawn in a step's cell on the block-size row: a frame and, in
/// it, a chequerboard of `n` squares a side.
fn chequer(s: &mut Surface, cell: Box2, n: usize, ink: Rgba, scale: f64) {
    let unit = size::ICON * scale / look::icon_grid::ARTBOARD;
    let side = size::MOSAIC_FRAME * unit;
    let b = cell.centred(side);
    let step = side / n as f64;
    for row in 0..n {
        for col in 0..n {
            if (row + col) % 2 == 0 {
                s.rounded(Box2::new(b.x + col as f64 * step, b.y + row as f64 * step, step, step), 0.0, ink);
            }
        }
    }
    s.ring(b, 0.0, size::MOSAIC_FRAME_LINE * unit, with_alpha(ink, ink.a * colour::MOSAIC_FRAME.a));
}

/// Draw one cell: what is under its picture according to its state, then
/// the picture. `props` is the property row showing, which is what a step
/// is a step of. `glow` is false on a system that asks for less
/// transparency.
fn cell(s: &mut Surface, c: &Cell, props: Props, scale: f64, glow: bool, icons: &mut Icons, tones: &Tones) {
    let b = Box2::of(c.rect);
    let r = size::CELL_RADIUS * scale;
    let done_down = c.button == Button::Done && c.state == State::Down;
    match c.state {
        // Lighter by a wash of the ink's own colour: white, in the look.
        State::Hover => {
            s.rounded(b, r, with_alpha(tones.ink, colour::HOVER.a));
            s.ring(b, r, size::PLATE_EDGE * scale, with_alpha(tones.ink, colour::HOVER_EDGE.a));
        }
        State::SelectedHover => s.rounded(b, r, with_alpha(tones.ink, colour::HOVER.a)),
        State::Down if done_down => s.rounded(b, r, tones.accent),
        State::Down => s.rounded(b, r, with_alpha(tones.accent, colour::DOWN.a)),
        State::Normal | State::Selected | State::Off => {}
    }
    let lit = matches!(c.state, State::Down | State::Selected | State::SelectedHover);
    if lit {
        if glow {
            s.glow(b, r, size::GLOW_SIGMA * scale, with_alpha(tones.accent, colour::GLOW.a));
        }
        if !done_down {
            s.ring(b, r, size::RING * scale, tones.accent);
        }
    }
    let ink = match c.state {
        State::Off => tones.ink_off,
        _ if done_down => tones.on_accent,
        _ if lit => tones.accent,
        _ => tones.ink,
    };
    let disc = |s: &mut Surface, points: f64, c: Rgba| {
        let d = points * scale;
        s.rounded(b.centred(d), d / 2.0, c);
    };
    match c.button {
        // A colour is its own whatever the state.
        Button::Colour(i) => {
            let (cr, cg, cb) = style::COLOURS[i as usize % style::COLOURS.len()];
            disc(s, size::SWATCH, Rgba { r: cr, g: cg, b: cb, a: 1.0 });
            let d = size::SWATCH * scale;
            s.ring(b.centred(d), d / 2.0, size::SWATCH_EDGE * scale, with_alpha(tones.ink, colour::SWATCH_EDGE.a));
        }
        Button::Level(l) => {
            let l = (l as usize).min(levels::DOTS.len() - 1);
            match props {
                Props::Font => {
                    if let Some(m) = icons.get(look::FONT_ICONS[l], c.rect.w, scale) {
                        s.ink(c.rect.x, c.rect.y, m, ink);
                    }
                }
                Props::Block => chequer(s, b, levels::MOSAIC_CELLS[l] as usize, ink, scale),
                _ => disc(s, levels::DOTS[l], ink),
            }
        }
        button => {
            if let Some(m) = icon_of(button).and_then(|k| icons.get(k, c.rect.w, scale)) {
                s.ink(c.rect.x, c.rect.y, m, ink);
            }
        }
    }
}

/// The toolbar: one plate, the line between its rows when the second is
/// shown, and every cell.
pub fn toolbar(
    s: &mut Surface,
    glass: &Glass,
    layout: &Layout,
    cells: &[Cell],
    props: Props,
    scale: f64,
    icons: &mut Icons,
    tones: &Tones,
) {
    let whole = layout.plate();
    plate(s, glass, whole, size::PLATE_RADIUS, scale, tones);
    if let Some(row) = layout.props {
        s.fill(Rect::new(whole.x, row.y, whole.w, px_f(size::ROW_DIVIDER, scale)), with_alpha(tones.ink, colour::ROW_DIVIDER.a));
    }
    for c in cells {
        cell(s, c, props, scale, glass.is_frosted(), icons, tones);
    }
}

/// The plate words sit on: a tooltip, the size beside the selection, the
/// long screenshot's status line.
pub fn label(s: &mut Surface, glass: &Glass, rect: Rect, scale: f64, tones: &Tones) {
    plate(s, glass, rect, size::LABEL_RADIUS, scale, tones);
}

/// The little plate a tooltip's key sits on.
pub fn key_plate(s: &mut Surface, rect: Rect, scale: f64, tones: &Tones) {
    s.rounded(Box2::of(rect), size::TIP_KEY_RADIUS * scale, with_alpha(tones.ink, colour::TIP_KEY_PLATE.a));
}

/// The red dot of a long screenshot in progress, centred in `cell`, with
/// its ring.
pub fn status_dot(s: &mut Surface, cell: Rect, scale: f64) {
    let b = Box2::of(cell);
    let d = size::STATUS_DOT * scale;
    let halo = d + 2.0 * size::STATUS_DOT_HALO * scale;
    s.rounded(b.centred(halo), halo / 2.0, colour::STATUS_DOT_HALO);
    s.rounded(b.centred(d), d / 2.0, colour::STATUS_DOT);
}

/// The selection's outline, outside it, and its eight round knobs when
/// `knobs` -- which is when the select tool is the mouse and no annotation
/// is selected (§9.8.11A.7).
pub fn selection(s: &mut Surface, sel: Rect, knobs: bool, scale: f64, tones: &Tones) {
    s.outline(Box2::of(sel), 0.0, px_f(size::SELECTION_LINE, scale) as f64, tones.accent);
    if knobs {
        let d = px_f(size::SELECTION_KNOB, scale) as f64;
        for handle in Handle::ALL {
            let c = handle.at(sel);
            let b = Box2::new(c.x as f64 - d / 2.0, c.y as f64 - d / 2.0, d, d);
            s.rounded(b, d / 2.0, colour::KNOB_FILL);
            s.ring(b, d / 2.0, px_f(1.0, scale) as f64, tones.accent);
        }
    }
}

/// The line round the window the pointer is over, inside its edge and
/// square: the window's rectangle is all that is known of it.
pub fn window_outline(s: &mut Surface, window: Rect, scale: f64, tones: &Tones) {
    s.ring(Box2::of(window), 0.0, px_f(size::WINDOW_LINE, scale) as f64, tones.accent);
}

// --------------------------------------------------- where the words go

/// A plate for words `text` pixels in size, with the look's padding round
/// them, and where the words start in it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Tag {
    pub plate: Rect,
    pub text: Point,
}

fn kept_on(r: Rect, monitor: Rect) -> Rect {
    let x = r.x.min(monitor.right() - r.w).max(monitor.x);
    let y = r.y.min(monitor.bottom() - r.h).max(monitor.y);
    Rect::new(x, y, r.w, r.h)
}

/// The selection's size: over its top-left corner, six points clear of it
/// -- or, when there is no room over it, inside the corner by four.
pub fn size_label(sel: Rect, text: (i32, i32), scale: f64, monitor: Rect) -> Tag {
    let (px, py) = (px_f(size::SIZE_LABEL_PAD_X, scale), px_f(size::SIZE_LABEL_PAD_Y, scale));
    let (w, h) = (text.0 + 2 * px, text.1 + 2 * py);
    let above = sel.y - px_f(size::SIZE_LABEL_OFFSET, scale) - h;
    let inset = px_f(size::SIZE_LABEL_INSET, scale);
    let plate = if above >= monitor.y { Rect::new(sel.x, above, w, h) } else { Rect::new(sel.x + inset, sel.y + inset, w, h) };
    let plate = kept_on(plate, monitor);
    Tag { plate, text: Point::new(plate.x + px, plate.y + py) }
}

/// The tag beside the pointer while a shape is reshaped: twelve points
/// right of it and below.
pub fn pointer_tag(pointer: Point, text: (i32, i32), scale: f64, monitor: Rect) -> Tag {
    let (px, py) = (px_f(size::SIZE_LABEL_PAD_X, scale), px_f(size::SIZE_LABEL_PAD_Y, scale));
    let off = px_f(annotation::TAG_OFFSET, scale);
    let plate = kept_on(Rect::new(pointer.x + off, pointer.y + off, text.0 + 2 * px, text.1 + 2 * py), monitor);
    Tag { plate, text: Point::new(plate.x + px, plate.y + py) }
}

/// A tooltip: the name, and the key that does the same on a little plate
/// of its own after it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Tip {
    pub plate: Rect,
    pub name: Point,
    /// The key's plate and where its text starts.
    pub key: Option<(Rect, Point)>,
}

/// Where a line of words beside the toolbar goes: `before` is the height
/// already taken there by other lines. Under the plate by four points
/// when that is on the monitor, over it when it is not.
fn beside_plate(plate: Rect, height: i32, before: i32, scale: f64, monitor: Rect) -> i32 {
    let off = px_f(size::TIP_OFFSET, scale);
    let under = plate.bottom() + off + before;
    if under + height <= monitor.bottom() {
        under
    } else {
        plate.y - off - before - height
    }
}

/// The tooltip of the cell at `cell`: its left edge on the cell's, beside
/// the toolbar's `plate`. `name` and `key` are the sizes of the two pieces
/// of text.
pub fn tooltip(cell: Rect, plate: Rect, before: i32, name: (i32, i32), key: Option<(i32, i32)>, scale: f64, monitor: Rect) -> Tip {
    let (px, py) = (px_f(size::TIP_PAD_X, scale), px_f(size::TIP_PAD_Y, scale));
    let (kx, ky) = (px_f(size::TIP_KEY_PAD_X, scale), px_f(size::TIP_KEY_PAD_Y, scale));
    let gap = px_f(size::TIP_KEY_GAP, scale);
    let key_w = key.map_or(0, |k| gap + k.0 + 2 * kx);
    let (w, h) = (name.0 + key_w + 2 * px, name.1 + 2 * py);
    let plate = kept_on(Rect::new(cell.x, beside_plate(plate, h, before, scale, monitor), w, h), monitor);
    let name_at = Point::new(plate.x + px, plate.y + py);
    let key = key.map(|k| {
        let r = Rect::new(name_at.x + name.0 + gap, plate.y + (h - k.1 - 2 * ky) / 2, k.0 + 2 * kx, k.1 + 2 * ky);
        (r, Point::new(r.x + kx, r.y + ky))
    });
    Tip { plate, name: name_at, key }
}

/// A line of words beside the toolbar with nothing before the words (the
/// notice that the annotation font is missing).
pub fn line(plate: Rect, before: i32, text: (i32, i32), scale: f64, monitor: Rect) -> Tag {
    let (px, py) = (px_f(size::STATUS_PAD_X, scale), px_f(size::STATUS_PAD_Y, scale));
    let (w, h) = (text.0 + 2 * px, text.1 + 2 * py);
    let r = kept_on(Rect::new(plate.x, beside_plate(plate, h, before, scale, monitor), w, h), monitor);
    Tag { plate: r, text: Point::new(r.x + px, r.y + py) }
}

/// The long screenshot's status line: a plate, the cell its red dot is
/// centred in, and where the words start after it.
pub fn status(plate: Rect, before: i32, text: (i32, i32), scale: f64, monitor: Rect) -> (Tag, Rect) {
    let (px, py) = (px_f(size::STATUS_PAD_X, scale), px_f(size::STATUS_PAD_Y, scale));
    let dot = px_f(size::STATUS_DOT, scale) + 2 * px_f(size::STATUS_DOT_HALO, scale);
    let gap = px_f(size::STATUS_GAP, scale);
    let h = text.1.max(dot) + 2 * py;
    let w = px + dot + gap + text.0 + px;
    let r = kept_on(Rect::new(plate.x, beside_plate(plate, h, before, scale, monitor), w, h), monitor);
    let cell = Rect::new(r.x + px, r.y + (h - dot) / 2, dot, dot);
    (Tag { plate: r, text: Point::new(cell.right() + gap, r.y + (h - text.1) / 2) }, cell)
}

// ------------------------------------------------- a selected annotation

/// How a grip is drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Grip {
    Normal,
    /// The pointer is over it.
    Hot,
    /// It is being dragged.
    Held,
}

/// The rectangle a selected annotation's frame runs round: its ink's box
/// grown by four points, so that the frame does not lie on the
/// annotation's own line. The grips are centred on its corners and sides.
pub fn frame_box(ink: Rect, scale: f64) -> Rect {
    let out = px_f(annotation::FRAME_OFFSET, scale);
    Rect::new(ink.x - out, ink.y - out, ink.w + 2 * out, ink.h + 2 * out)
}

/// The frame of a selected annotation round `ink`, the box of what it
/// drew: a white line with accent dashes over it -- blue and white by
/// turns, so that it shows on white, where the white is lost, and on blue,
/// where the blue is -- and the same glow a chosen cell has.
pub fn annotation_frame(s: &mut Surface, ink: Rect, scale: f64, glow: bool, tones: &Tones) {
    let b = Box2::of(frame_box(ink, scale));
    let r = annotation::FRAME_RADIUS * scale;
    let line = px_f(annotation::FRAME_LINE, scale) as f64;
    let outer = b.inset(-line);
    if glow {
        // Along the line: its middle is half a line outside the box.
        s.glow(b.inset(-line / 2.0), r + line / 2.0, size::GLOW_SIGMA * scale, with_alpha(tones.accent, colour::GLOW.a));
    }
    s.outline(b, r, line, colour::FRAME_LIGHT);
    let (on, off) = (px_f(annotation::FRAME_DASH_ON, scale) as f64, px_f(annotation::FRAME_DASH_OFF, scale) as f64);
    // The dashes: the same line again in the accent colour, where the way
    // round from the top-left corner falls in a dash.
    let (w, h) = (outer.w, outer.h);
    let area = outer.pixels(1.0);
    let Some(area) = area.intersect(s.rect).and_then(|a| a.intersect(s.clip)) else { return };
    let mut dashes = Vec::new();
    for y in area.y..area.bottom() {
        for x in area.x..area.right() {
            let (px, py) = (x as f64 + 0.5, y as f64 + 0.5);
            let cover = (0.5 - outer.distance(r + line, px, py)).clamp(0.0, 1.0) - (0.5 - b.distance(r, px, py)).clamp(0.0, 1.0);
            if cover <= 0.0 {
                continue;
            }
            let (dx, dy) = (px - outer.x, py - outer.y);
            // Which side it is nearest, and how far round that is.
            let sides = [(dy, dx), (w - dx, w + dy), (h - dy, w + h + (w - dx)), (dx, 2.0 * w + h + (h - dy))];
            let along = sides.iter().min_by(|a, b| a.0.total_cmp(&b.0)).map_or(0.0, |s| s.1);
            if along.rem_euclid(on + off) < on {
                dashes.push((x, y, cover));
            }
        }
    }
    for (x, y, cover) in dashes {
        s.fill_one(x, y, with_alpha(tones.accent, cover));
    }
}

/// A grip centred on `at`.
pub fn grip(s: &mut Surface, at: Point, how: Grip, scale: f64, glow: bool, tones: &Tones) {
    let side = px_f(if how == Grip::Normal { annotation::GRIP } else { annotation::GRIP_HOT }, scale) as f64;
    let b = Box2::new(at.x as f64 - side / 2.0, at.y as f64 - side / 2.0, side, side);
    let r = annotation::GRIP_RADIUS * scale;
    let line = px_f(annotation::GRIP_LINE, scale) as f64;
    if how != Grip::Normal && glow {
        s.glow(b, r, size::GLOW_SIGMA * scale, with_alpha(tones.accent, colour::GLOW.a));
    }
    // A fine dark line outside, which is what shows a white grip on white.
    s.outline(b, r, annotation::GRIP_SHADOW * scale, colour::GRIP_SHADOW);
    let (fill, edge) = if how == Grip::Held { (tones.accent, colour::GRIP_FILL) } else { (colour::GRIP_FILL, tones.accent) };
    s.rounded(b, r, fill);
    s.ring(b, r, line, edge);
}

/// How far from a grip's centre a press still takes it, in pixels.
pub fn grip_reach(scale: f64) -> i32 {
    px_f(annotation::GRIP_REACH, scale)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::toolbar;

    const MON: Rect = Rect::new(0, 0, 1400, 900);
    const SEL: Rect = Rect::new(100, 100, 1200, 500);
    const ACCENT: (u8, u8, u8) = (0x41, 0x9C, 0xFF);

    fn flat(grey: u8) -> Vec<u8> {
        let mut v = vec![grey; MON.w as usize * MON.h as usize * 4];
        v.chunks_exact_mut(4).for_each(|p| p[3] = 255);
        v
    }
    fn at(buf: &[u8], x: i32, y: i32) -> (u8, u8, u8) {
        let i = (y as usize * MON.w as usize + x as usize) * 4;
        (buf[i + 2], buf[i + 1], buf[i])
    }
    fn near(a: (u8, u8, u8), b: (u8, u8, u8), by: i32) -> bool {
        (a.0 as i32 - b.0 as i32).abs() <= by && (a.1 as i32 - b.1 as i32).abs() <= by && (a.2 as i32 - b.2 as i32).abs() <= by
    }

    /// The toolbar at 200% over a picture of one grey, every cell in
    /// `state_of` its button.
    fn drawn(paper: u8, props: Props, frosted: bool, state_of: impl Fn(Button) -> State) -> (Vec<u8>, Layout) {
        let pic = flat(paper);
        let glass = if frosted { Glass::new(MON, &pic, 2.0) } else { Glass::plain(MON, &pic) }.unwrap();
        let layout = toolbar::layout(SEL, MON, 2.0, props);
        let cells: Vec<Cell> = layout.buttons.iter().map(|(b, r)| Cell { button: *b, rect: *r, state: state_of(*b) }).collect();
        let mut buf = pic.clone();
        toolbar(&mut Surface::new(&mut buf, MON).unwrap(), &glass, &layout, &cells, props, 2.0, &mut Icons::new(), &Tones::LOOK);
        (buf, layout)
    }

    #[test]
    fn a_cells_state_is_one_of_six() {
        assert_eq!(state(true, false, false, false), State::Normal);
        assert_eq!(state(true, false, true, false), State::Hover);
        assert_eq!(state(true, true, false, false), State::Selected);
        assert_eq!(state(true, true, true, false), State::SelectedHover);
        // Held is held, whatever else.
        assert_eq!(state(true, false, true, true), State::Down);
        assert_eq!(state(true, true, true, true), State::Down);
        // One that cannot be pressed is off under the pointer and under a press.
        for (current, hovered, pressed) in [(false, false, false), (false, true, false), (false, true, true), (true, true, true)] {
            assert_eq!(state(false, current, hovered, pressed), State::Off);
        }
    }

    #[test]
    fn every_button_has_a_picture_and_none_of_them_is_from_a_font() {
        let l = toolbar::layout(SEL, MON, 1.0, Props::None);
        let keys: Vec<&str> = l.buttons.iter().map(|(b, _)| icon_of(*b).unwrap()).collect();
        assert_eq!(keys, look::TOOLBAR_ICONS, "the first row in order");
        assert_eq!((icon_of(Button::Colour(0)), icon_of(Button::Level(0))), (None, None));
        let mut icons = Icons::new();
        for key in look::TOOLBAR_ICONS.iter().chain(look::FONT_ICONS.iter()) {
            let m = icons.get(key, 56, 2.0).unwrap();
            assert!(m.ink().count > 0, "{key}");
        }
        assert!(icons.get("no such icon", 56, 2.0).is_none());
        // Asked for again, it is the one already drawn.
        assert_eq!(icons.drawn.len(), 21);
        icons.get("rect", 56, 2.0);
        assert_eq!(icons.drawn.len(), 21);
        icons.get("rect", 42, 1.5);
        assert_eq!(icons.drawn.len(), 22);
    }

    #[test]
    fn the_plate_is_dark_glass_on_white_and_on_black_with_white_ink_on_it() {
        for (paper, glass_colour) in [(255u8, (0x3E, 0x40, 0x40)), (0, (0x13, 0x14, 0x15))] {
            let (buf, l) = drawn(paper, Props::None, true, |_| State::Normal);
            let p = l.plate();
            // Between two cells, well inside the plate: the glass (§9.8.13 D).
            let gap = l.rect_of(Button::Tool(Tool::Rect)).unwrap();
            assert!(near(at(&buf, gap.right() + 4, gap.y + 28), glass_colour, 1), "paper {paper}: {:?}", at(&buf, gap.right() + 4, gap.y + 28));
            // The corner pixel is not plate at all: it is rounded by 24 px.
            assert_ne!(at(&buf, p.x, p.y), glass_colour);
            // An icon is white: the straight line's middle is on the cell's.
            let line = l.rect_of(Button::Tool(Tool::Line)).unwrap();
            assert_eq!(at(&buf, line.x + 28, line.y + 27), (255, 255, 255), "paper {paper}");
            // Nothing far from the plate is touched.
            assert_eq!(at(&buf, 50, 50), (paper, paper, paper));
            // A shadow under it on white: a little darker just below.
            if paper == 255 {
                let below = at(&buf, p.x + p.w / 2, p.bottom() + 6).0;
                assert!(below < 250 && below > 150, "{below}");
            }
        }
    }

    #[test]
    fn a_chosen_cell_has_the_ring_and_the_glow_and_its_picture_turns_accent() {
        // §9.8.13 C at 200%: the ring is 3 px from the cell's edge in, the
        // accent colour; the glow can be seen 2 px outside the cell and is
        // gone 10 px outside it.
        let chosen = Button::Tool(Tool::Line);
        let (plain, l) = drawn(255, Props::None, true, |_| State::Normal);
        let (buf, _) = drawn(255, Props::None, true, |b| if b == chosen { State::Selected } else { State::Normal });
        let r = l.rect_of(chosen).unwrap();
        let (mid, y) = (r.x + 28, r.y + 28);
        for d in 0..3 {
            assert!(near(at(&buf, r.x + d, y - 10), ACCENT, 8), "{d} px in: {:?}", at(&buf, r.x + d, y - 10));
        }
        assert!(!near(at(&buf, r.x + 4, y - 10), ACCENT, 60), "the ring is 3 px and no more");
        // The glow: bluer than the same pixel unchosen, 2 px outside; the
        // same as unchosen 10 px outside (above the cell: beside it there
        // is a neighbour).
        let (lit, unlit) = (at(&buf, mid, r.y - 2), at(&plain, mid, r.y - 2));
        assert!(lit.2 as i32 - unlit.2 as i32 >= 8, "{lit:?} against {unlit:?}");
        assert!(near(at(&buf, mid, r.y - 10), at(&plain, mid, r.y - 10), 3));
        // The picture is the accent colour: the line's own middle.
        assert!(near(at(&buf, mid, y - 1), ACCENT, 8), "{:?}", at(&buf, mid, y - 1));
        // No tinted paper under it: inside the ring, off the icon, the
        // glass is only as much bluer as the glow makes it there.
        let inside = at(&buf, r.x + 8, r.y + 8);
        assert!(inside.2 as i32 - at(&plain, r.x + 8, r.y + 8).2 as i32 <= 14, "{inside:?}");
        // The neighbours' pictures are as they were.
        let next = l.rect_of(Button::Tool(Tool::Arrow)).unwrap();
        assert_eq!(at(&buf, next.x + 28, next.y + 28), at(&plain, next.x + 28, next.y + 28));
    }

    #[test]
    fn the_five_kinds_of_chosen_cell_wear_the_same_ring() {
        // A tool, a colour, a thickness, a font size, a block size.
        for (props, chosen) in [
            (Props::Stroke, Button::Tool(Tool::Rect)),
            (Props::Stroke, Button::Colour(8)),
            (Props::Stroke, Button::Level(2)),
            (Props::Font, Button::Level(4)),
            (Props::Block, Button::Level(0)),
        ] {
            let (buf, l) = drawn(0, props, true, |b| if b == chosen { State::Selected } else { State::Normal });
            let r = l.rect_of(chosen).unwrap();
            // The middle of the ring on the left side, and where it ends.
            assert!(near(at(&buf, r.x + 1, r.y + 28), ACCENT, 8), "{chosen:?}: {:?}", at(&buf, r.x + 1, r.y + 28));
            assert!(near(at(&buf, r.right() - 2, r.y + 28), ACCENT, 8), "{chosen:?}");
            assert!(!near(at(&buf, r.x + 4, r.y + 28), ACCENT, 60), "{chosen:?}");
        }
    }

    #[test]
    fn a_swatch_keeps_its_colour_and_the_ring_stands_clear_of_it() {
        for (i, rgb) in [(8u8, (0xFF, 0xFF, 0xFF)), (7, (0x1A, 0x1A, 0x1A)), (5, (0x2F, 0x6F, 0xED))] {
            let (buf, l) = drawn(128, Props::Stroke, true, |b| if b == Button::Colour(i) { State::Selected } else { State::Normal });
            let r = l.rect_of(Button::Colour(i)).unwrap();
            let (cx, cy) = (r.x + 28, r.y + 28);
            assert_eq!(at(&buf, cx, cy), rgb, "its own colour, chosen or not");
            // A disc 32 px across: its colour 14 px from the middle, glass 18 px.
            assert!(near(at(&buf, cx + 14, cy), rgb, 2), "{:?}", at(&buf, cx + 14, cy));
            assert!(!near(at(&buf, cx + 18, cy), rgb, 8));
            // Between disc and ring, at least 8 px that are neither.
            let between = (17..25).filter(|d| !near(at(&buf, cx + d, cy), rgb, 12) && !near(at(&buf, cx + d, cy), ACCENT, 40)).count();
            assert!(between >= 8, "colour {i}: {between}");
        }
    }

    #[test]
    fn the_pointer_over_a_cell_lightens_it_without_a_trace_of_blue() {
        let over = Button::Tool(Tool::Ellipse);
        let (plain, l) = drawn(128, Props::None, true, |_| State::Normal);
        let (buf, _) = drawn(128, Props::None, true, |b| if b == over { State::Hover } else { State::Normal });
        let r = l.rect_of(over).unwrap();
        // Off the icon, inside the cell: lighter by 20 to 40 a channel, the
        // three channels by the same (§9.8.13 C).
        let (a, b) = (at(&buf, r.x + 8, r.y + 8), at(&plain, r.x + 8, r.y + 8));
        let rise = [a.0 as i32 - b.0 as i32, a.1 as i32 - b.1 as i32, a.2 as i32 - b.2 as i32];
        assert!(rise.iter().all(|d| (20..=40).contains(d)), "{rise:?}");
        assert!(rise.iter().max().unwrap() - rise.iter().min().unwrap() <= 6, "{rise:?}");
        // No glow: 2 px outside the cell is as it was.
        assert_eq!(at(&buf, r.x + 28, r.y - 2), at(&plain, r.x + 28, r.y - 2));
        // And the icon stays white: the top of the ellipse.
        assert_eq!((at(&buf, r.x + 28, r.y + 15), at(&plain, r.x + 28, r.y + 15)), ((255, 255, 255), (255, 255, 255)));
    }

    #[test]
    fn a_held_cell_is_tinted_ringed_and_glowing_and_done_is_solid_with_a_white_tick() {
        let (plain, l) = drawn(128, Props::None, true, |_| State::Normal);
        let (buf, _) = drawn(128, Props::None, true, |b| if matches!(b, Button::Cancel | Button::Done) { State::Down } else { State::Normal });
        // Cancel: the ordinary held cell -- bluer inside, off the icon.
        let c = l.rect_of(Button::Cancel).unwrap();
        let (a, b) = (at(&buf, c.x + 28, c.y + 8), at(&plain, c.x + 28, c.y + 8));
        assert!((a.2 as i32 - b.2 as i32) - (a.0 as i32 - b.0 as i32) >= 15, "{a:?} against {b:?}");
        assert!(near(at(&buf, c.x + 1, c.y + 28), ACCENT, 8), "the ring");
        // Done: the accent colour through and through, the tick white.
        let d = l.rect_of(Button::Done).unwrap();
        assert!(near(at(&buf, d.x + 8, d.y + 8), ACCENT, 3), "{:?}", at(&buf, d.x + 8, d.y + 8));
        assert!(near(at(&buf, d.x + 28, d.y + 28), ACCENT, 3));
        let white = (0..56).flat_map(|y| (0..56).map(move |x| (x, y))).filter(|(x, y)| at(&buf, d.x + x, d.y + y) == (255, 255, 255)).count();
        assert!(white > 60, "{white}");
        // Unheld, the two are as quiet as their neighbours (reading A).
        assert_eq!(at(&plain, d.x + 8, d.y + 8), at(&plain, c.x + 8, c.y + 8));
    }

    #[test]
    fn a_cell_that_cannot_be_pressed_is_faint_and_nothing_else() {
        let (plain, l) = drawn(0, Props::None, true, |_| State::Normal);
        let (buf, _) = drawn(0, Props::None, true, |b| if b == Button::Undo { State::Off } else { State::Normal });
        let r = l.rect_of(Button::Undo).unwrap();
        let (mut faint, mut differ) = (0, 0);
        for y in r.y..r.bottom() {
            for x in r.x..r.right() {
                let (a, b) = (at(&buf, x, y), at(&plain, x, y));
                if b == (255, 255, 255) {
                    // White at 32% over the glass on black, #131415.
                    assert!(near(a, (95, 95, 96), 2), "{a:?}");
                    faint += 1;
                }
                if a != b {
                    differ += 1;
                }
            }
        }
        assert!(faint > 100, "{faint}");
        // Only the icon's own pixels changed: no paper, no ring, no glow.
        let icon = Icons::new().get("undo", 56, 2.0).unwrap().alpha.iter().filter(|a| **a > 0).count();
        assert!(differ <= icon, "{differ} pixels changed for an icon of {icon}");
    }

    #[test]
    fn the_steps_are_five_dots_five_ts_or_five_boards() {
        let ink = |props: Props, l: u8| {
            let (buf, layout) = drawn(0, props, true, |_| State::Normal);
            let r = layout.rect_of(Button::Level(l)).unwrap();
            let lit: Vec<(i32, i32)> =
                (0..56).flat_map(|y| (0..56).map(move |x| (x, y))).filter(|(x, y)| at(&buf, r.x + x, r.y + y).0 > 200).collect();
            let (x0, x1) = (lit.iter().map(|p| p.0).min().unwrap(), lit.iter().map(|p| p.0).max().unwrap());
            let (y0, y1) = (lit.iter().map(|p| p.1).min().unwrap(), lit.iter().map(|p| p.1).max().unwrap());
            (x1 - x0 + 1, y1 - y0 + 1, x0 + x1, y0 + y1)
        };
        // Dots 3 / 5 / 8 / 11 / 15 pt across: 6, 10, 16, 22, 30 px, centred.
        for (l, d) in [6, 10, 16, 22, 30].into_iter().enumerate() {
            let (w, h, cx, cy) = ink(Props::Stroke, l as u8);
            assert!((w - d).abs() <= 1 && (h - d).abs() <= 1, "dot {l}: {w}x{h} for {d}");
            assert!((cx - 55).abs() <= 1 && (cy - 55).abs() <= 1, "dot {l}: its middle is the cell's");
        }
        // The five Ts grow, each at least 3 px taller than the one before.
        let heights: Vec<i32> = (0..5).map(|l| ink(Props::Font, l).1).collect();
        assert!(heights.windows(2).all(|w| w[1] - w[0] >= 3), "{heights:?}");
        // The boards: a square 16 units of 40 / 24 px, so 27 px, whatever
        // the step -- and fewer, larger squares as the step grows.
        for l in 0..5u8 {
            let (w, h, cx, cy) = ink(Props::Block, l);
            assert!((w - 27).abs() <= 1 && (h - 27).abs() <= 1, "board {l}: {w}x{h}");
            assert!((cx - 55).abs() <= 2 && (cy - 55).abs() <= 2);
        }
        let count = |l: u8| {
            let (buf, layout) = drawn(0, Props::Block, true, |_| State::Normal);
            let r = layout.rect_of(Button::Level(l)).unwrap();
            // Runs of white along a row through the first squares.
            let row: Vec<bool> = (0..56).map(|x| at(&buf, r.x + x, r.y + 17).0 > 200).collect();
            row.windows(2).filter(|w| !w[0] && w[1]).count()
        };
        assert_eq!([count(0), count(1), count(2), count(3), count(4)], [3, 3, 2, 2, 1], "6, 5, 4, 3 and 2 a side: every other one is filled");
    }

    #[test]
    fn the_line_between_the_rows_is_there_only_with_the_second_row() {
        let (one, l1) = drawn(0, Props::None, true, |_| State::Normal);
        let (two, l2) = drawn(0, Props::Stroke, true, |_| State::Normal);
        let y = l2.props.unwrap().y;
        let x = l2.bar.right() - 40;
        // White at 18% over the glass on black: lighter than the glass.
        assert!(at(&two, x, y).0 > at(&two, x, y + 3).0 + 20, "{:?} {:?}", at(&two, x, y), at(&two, x, y + 3));
        assert_eq!(at(&two, x, y + 1), at(&two, x, y + 3), "one pixel of it");
        // With one row that pixel is under the plate: the paper, shadowed.
        assert!(at(&one, x, y).0 < 0x13);
        assert_eq!(l1.plate().h * 2, l2.plate().h);
    }

    #[test]
    fn with_less_transparency_the_plate_is_opaque_and_nothing_glows() {
        let chosen = Button::Tool(Tool::Line);
        let (buf, l) = drawn(255, Props::None, false, |b| if b == chosen { State::Selected } else { State::Normal });
        let gap = l.rect_of(Button::Tool(Tool::Rect)).unwrap();
        assert_eq!(at(&buf, gap.right() + 4, gap.y + 28), (0x3D, 0x3F, 0x40));
        // One line round it, #8E8F90, a point wide.
        let p = l.plate();
        assert_eq!(at(&buf, p.x + p.w / 2, p.y), (0x8E, 0x8F, 0x90));
        assert_eq!(at(&buf, p.x + p.w / 2, p.y + 2), (0x3D, 0x3F, 0x40));
        // The ring is still there; the glow is not.
        let r = l.rect_of(chosen).unwrap();
        assert!(near(at(&buf, r.x + 1, r.y + 28), ACCENT, 8));
        assert_eq!(at(&buf, r.x + 28, r.y - 2), (0x3D, 0x3F, 0x40));
    }

    #[test]
    fn the_selection_has_a_line_outside_it_and_round_knobs_only_when_asked() {
        for (scale, line, knob) in [(1.0, 1, 7), (1.5, 2, 11), (2.0, 2, 14)] {
            let sel = Rect::new(300, 200, 400, 300);
            let mut buf = flat(0);
            selection(&mut Surface::new(&mut buf, MON).unwrap(), sel, false, scale, &Tones::LOOK);
            // Outside the selection, `line` px of it; nothing inside.
            for d in 1..=line {
                assert_eq!(at(&buf, sel.x - d, 350), ACCENT, "scale {scale}");
                assert_eq!(at(&buf, 500, sel.bottom() - 1 + d), ACCENT);
            }
            assert_eq!(at(&buf, sel.x - line - 1, 350), (0, 0, 0));
            assert_eq!(at(&buf, sel.x, 350), (0, 0, 0), "the selection is the picture, to its edge");
            assert_eq!(at(&buf, 500, 201), (0, 0, 0), "no knob");
            let mut buf = flat(0);
            selection(&mut Surface::new(&mut buf, MON).unwrap(), sel, true, scale, &Tones::LOOK);
            // A knob on the middle of the top side: white in the middle,
            // `knob` px across, round.
            let (cx, cy) = (sel.x + sel.w / 2, sel.y);
            assert_eq!(at(&buf, cx, cy), (255, 255, 255));
            let across = (cx - 20..cx + 20).filter(|x| at(&buf, *x, cy - line - 1) != (0, 0, 0)).count() as i32;
            assert!((across - knob).abs() <= 2 || across >= knob - 4, "scale {scale}: {across} for {knob}");
            let half = knob / 2;
            assert_eq!(at(&buf, cx - half - 2, cy - half - 2), (0, 0, 0), "its corner is cut off: a disc");
            assert!(near(at(&buf, cx, cy - half + 0), ACCENT, 90) || near(at(&buf, cx, cy - half + 1), ACCENT, 90), "an accent edge");
            // Eight of them.
            let lit = Handle::ALL.iter().filter(|h| at(&buf, h.at(sel).x, h.at(sel).y) == (255, 255, 255)).count();
            assert_eq!(lit, 8);
        }
    }

    #[test]
    fn the_window_under_the_pointer_is_outlined_inside_its_edge() {
        let mut buf = flat(0);
        let win = Rect::new(200, 150, 500, 400);
        window_outline(&mut Surface::new(&mut buf, MON).unwrap(), win, 2.0, &Tones::LOOK);
        for d in 0..4 {
            assert_eq!(at(&buf, win.x + d, 300), ACCENT);
        }
        assert_eq!((at(&buf, win.x + 4, 300), at(&buf, win.x - 1, 300)), ((0, 0, 0), (0, 0, 0)));
        assert_eq!(at(&buf, win.x, win.y), ACCENT, "square corners");
    }

    #[test]
    fn a_selected_annotations_frame_is_blue_and_white_by_turns_and_clear_of_its_ink() {
        // §9.8.13 G at 200%: 8 px from the ink, 2 px wide, blue 8 and
        // white 6 by turns.
        for (scale, gap, line, on, off) in [(1.0, 4, 1, 4, 3), (1.5, 6, 2, 6, 5), (2.0, 8, 2, 8, 6)] {
            let ink = Rect::new(300, 200, 400, 240);
            assert_eq!(frame_box(ink, scale), Rect::new(300 - gap, 200 - gap, 400 + 2 * gap, 240 + 2 * gap));
            let mut seen = Vec::new();
            for paper in [255u8, 0] {
                let mut buf = flat(paper);
                annotation_frame(&mut Surface::new(&mut buf, MON).unwrap(), ink, scale, false, &Tones::LOOK);
                let b = frame_box(ink, scale);
                // The line is outside the box: `gap` px of paper between
                // it and the ink, on every side.
                for d in 0..gap {
                    assert_eq!(at(&buf, 500, ink.y - 1 - d), (paper, paper, paper), "scale {scale}");
                    assert_eq!(at(&buf, ink.x - 1 - d, 300), (paper, paper, paper));
                }
                for d in 0..line {
                    assert_ne!(at(&buf, 500 + 3, b.y - 1 - d).2, 0, "scale {scale}: the line, {d} px out");
                }
                assert_eq!(at(&buf, 500, b.y - 1 - line), (paper, paper, paper));
                // Along the top: accent and white by turns, `on` and `off`.
                let white = (paper as f64 + (255.0 - paper as f64) * 0.85).round() as u8;
                let row: Vec<bool> = (b.x + 10..b.right() - 10).map(|x| near(at(&buf, x, b.y - 1), ACCENT, 6)).collect();
                let mut runs: Vec<(bool, i32)> = Vec::new();
                for v in &row {
                    match runs.last_mut() {
                        Some((last, n)) if last == v => *n += 1,
                        _ => runs.push((*v, 1)),
                    }
                }
                for (blue, n) in &runs[1..runs.len() - 1] {
                    assert_eq!(*n, if *blue { on } else { off }, "scale {scale} paper {paper}: {runs:?}");
                }
                assert!(runs.len() > 10);
                // What is not blue is the white line.
                let x = b.x + 10 + row.iter().position(|v| !v).unwrap() as i32;
                assert!(near(at(&buf, x, b.y - 1), (white, white, white), 2), "{:?}", at(&buf, x, b.y - 1));
                seen.push(runs.len());
            }
            assert_eq!(seen[0], seen[1], "as many dashes on white as on black");
        }
        // With its glow the paper beside the line is bluer; without, not.
        let ink = Rect::new(300, 200, 400, 240);
        let (mut lit, mut unlit) = (flat(0), flat(0));
        annotation_frame(&mut Surface::new(&mut lit, MON).unwrap(), ink, 2.0, true, &Tones::LOOK);
        annotation_frame(&mut Surface::new(&mut unlit, MON).unwrap(), ink, 2.0, false, &Tones::LOOK);
        let b = frame_box(ink, 2.0);
        assert!(at(&lit, 500, b.y - 5).2 > at(&unlit, 500, b.y - 5).2 + 8);
        assert_eq!(at(&lit, 500, b.y - 20), (0, 0, 0));
    }

    #[test]
    fn a_grip_is_a_white_square_edged_in_accent_larger_under_the_pointer_and_accent_when_held() {
        for (scale, side, hot) in [(1.0, 7, 9), (1.5, 11, 14), (2.0, 14, 18)] {
            let c = Point::new(400, 300);
            let width = |buf: &[u8]| (c.x - 30..c.x + 30).filter(|x| at(buf, *x, c.y) != (0, 0, 0)).count() as i32;
            let mut buf = flat(0);
            grip(&mut Surface::new(&mut buf, MON).unwrap(), c, Grip::Normal, scale, true, &Tones::LOOK);
            assert_eq!(at(&buf, c.x, c.y), (255, 255, 255));
            assert!(near(at(&buf, c.x - side / 2, c.y), ACCENT, if side % 2 == 0 { 8 } else { 140 }), "scale {scale}: an accent edge");
            // As wide as said, and a hair of shadow outside it.
            assert!((width(&buf) - side).abs() <= 2, "scale {scale}: {} for {side}", width(&buf));
            let mut buf = flat(0);
            grip(&mut Surface::new(&mut buf, MON).unwrap(), c, Grip::Hot, scale, false, &Tones::LOOK);
            assert!((width(&buf) - hot).abs() <= 2, "scale {scale}: {} for {hot}", width(&buf));
            assert_eq!(at(&buf, c.x, c.y), (255, 255, 255));
            let mut buf = flat(0);
            grip(&mut Surface::new(&mut buf, MON).unwrap(), c, Grip::Held, scale, false, &Tones::LOOK);
            assert_eq!(at(&buf, c.x, c.y), ACCENT, "held: accent inside");
            assert_eq!(grip_reach(scale), [6, 9, 12][((scale - 1.0) * 2.0) as usize]);
        }
        // On white, the fine dark line is what shows it.
        let mut buf = flat(255);
        grip(&mut Surface::new(&mut buf, MON).unwrap(), Point::new(400, 300), Grip::Normal, 2.0, false, &Tones::LOOK);
        assert!(at(&buf, 400 - 8, 300).0 < 200, "{:?}", at(&buf, 400 - 8, 300));
    }

    /// Not a test: pictures of what this crate draws, for a person to look
    /// at, written into the directory named by `SHOT_CHROME_DIR`. No words
    /// are in them -- words are the host's, drawn by the system -- so the
    /// plates for words are empty.
    ///
    ///     SHOT_CHROME_DIR=/tmp/out cargo test --release -p polter-shots chrome::tests::pictures -- --ignored
    #[test]
    #[ignore = "writes pictures, run by hand"]
    fn pictures_of_everything_for_a_person_to_look_at() {
        let Ok(dir) = std::env::var("SHOT_CHROME_DIR") else { return };
        let save = |name: &str, rect: Rect, buf: &[u8]| {
            let image = crate::Image::from_bgrx(rect.w as u32, rect.h as u32, buf).unwrap();
            std::fs::write(format!("{dir}/{name}.png"), crate::encode::png(&image).unwrap()).unwrap();
        };
        // A made-up screen, `light` or dark, drawn at `scale`.
        let screen = |rect: Rect, scale: f64, light: bool| {
            let mut pic = vec![255u8; rect.w as usize * rect.h as usize * 4];
            for (i, p) in pic.chunks_exact_mut(4).enumerate() {
                let (x, y) = (((i % rect.w as usize) as f64 / scale) as i32, ((i / rect.w as usize) as f64 / scale) as i32);
                let c: (u8, u8, u8) = if light {
                    if (x / 30) % 4 == 1 && y % 110 > 30 {
                        [(0xE6, 0x28, 0x28), (0x2D, 0xB8, 0x4D), (0x2F, 0x6F, 0xED), (0xFF, 0xD4, 0x00)][(x / 120 % 4) as usize]
                    } else if y % 110 < 2 {
                        (200, 200, 205)
                    } else {
                        (247, 247, 249)
                    }
                } else if y % 22 < 2 && (x / 90) % 3 != 2 {
                    [(90, 200, 250), (240, 110, 110), (150, 220, 140)][(y / 22 % 3) as usize]
                } else {
                    (24, 25, 30)
                };
                p[..3].copy_from_slice(&[c.2, c.1, c.0]);
            }
            pic
        };
        let pt = |v: i32, scale: f64| (v as f64 * scale).round() as i32;
        for (scale, tag) in [(1.0, "100"), (1.5, "150"), (2.0, "200")] {
            for (light, paper) in [(true, "light"), (false, "dark")] {
                let rect = Rect::new(0, 0, pt(700, scale), pt(470, scale));
                let at = |x: i32, y: i32, w: i32, h: i32| Rect::new(pt(x, scale), pt(y, scale), pt(w, scale), pt(h, scale));
                let pic = screen(rect, scale, light);
                let glass = Glass::new(rect, &pic, scale).unwrap();

                // The toolbar in its three property rows and every state,
                // the selection with its knobs, the window outline, the
                // plates for words (empty) and the status dot.
                let sel = at(70, 30, 560, 150);
                let mut buf = vec![0u8; pic.len()];
                glass.frame(&mut buf, rect, &pic, Some(sel), rect);
                let mut s = Surface::new(&mut buf, rect).unwrap();
                selection(&mut s, sel, true, scale, &Tones::LOOK);
                let mut icons = Icons::new();
                for (row, props) in [Props::Stroke, Props::Font, Props::Block].into_iter().enumerate() {
                    let anchor = Rect::new(sel.x, sel.y, sel.w, pt(40 + row as i32 * 100, scale));
                    let layout = toolbar::layout(anchor, rect, scale, props);
                    let cells: Vec<Cell> = layout
                        .buttons
                        .iter()
                        .enumerate()
                        .map(|(i, (b, r))| {
                            let state = match (row, i) {
                                (0, 3) | (_, 17) | (_, 26) => State::Selected,
                                (0, 5) => State::Hover,
                                (1, 6) => State::SelectedHover,
                                (1, 13) | (1, 14) | (2, 2) => State::Down,
                                (_, 10) => State::Off,
                                (2, 16) => State::Selected,
                                _ => State::Normal,
                            };
                            Cell { button: *b, rect: *r, state }
                        })
                        .collect();
                    toolbar(&mut s, &glass, &layout, &cells, props, scale, &mut icons, &Tones::LOOK);
                }
                window_outline(&mut s, at(20, 400, 150, 60), scale, &Tones::LOOK);
                label(&mut s, &glass, at(70, 6, 92, 20), scale, &Tones::LOOK);
                label(&mut s, &glass, at(300, 420, 150, 28), scale, &Tones::LOOK);
                key_plate(&mut s, at(395, 425, 45, 18), scale, &Tones::LOOK);
                label(&mut s, &glass, at(480, 420, 200, 28), scale, &Tones::LOOK);
                status_dot(&mut s, at(490, 427, 14, 14), scale);
                save(&format!("toolbar-{tag}pct-on-{paper}"), rect, &buf);

                // A selected annotation: a rectangle (frame and eight
                // grips -- one under the pointer, one held), a line (two
                // grips, no frame), something that can only be moved (a
                // frame, no grips), and one reaching out of the selection.
                let sel = at(60, 40, 520, 330);
                let mut buf = vec![0u8; pic.len()];
                glass.frame(&mut buf, rect, &pic, Some(sel), rect);
                let red = Rgba { r: 0xE6, g: 0x28, b: 0x28, a: 1.0 };
                let blue = Rgba { r: 0x2F, g: 0x6F, b: 0xED, a: 1.0 };
                let stroke = (4.0 * scale).round();
                let (shape, text, out) = (at(110, 80, 200, 110), at(360, 250, 150, 40), at(480, 90, 170, 70));
                {
                    let mut s = Surface::new(&mut buf, rect).unwrap();
                    s.ring(Box2::of(shape), 0.0, stroke, red);
                    s.ring(Box2::of(out), 0.0, stroke, blue);
                    for i in 0..pt(150, scale) {
                        s.rounded(Box2::new((pt(120, scale) + i) as f64, (pt(320, scale) - i / 2) as f64, stroke, stroke), stroke / 2.0, blue);
                    }
                    // A stand-in for a piece of text: bars where words would be.
                    for k in 0..4 {
                        s.rounded(Box2::of(at(366 + k * 36, 262, 28, 16)), 3.0 * scale, red);
                    }
                }
                glass.veil(&mut buf, rect, sel, Rect::new(out.x - 2, out.y - 2, out.w + 4, out.h + 4), annotation::OUTSIDE_OPACITY);
                let mut s = Surface::new(&mut buf, rect).unwrap();
                selection(&mut s, sel, false, scale, &Tones::LOOK);
                annotation_frame(&mut s, shape, scale, true, &Tones::LOOK);
                let b = frame_box(shape, scale);
                for (i, h) in Handle::ALL.iter().enumerate() {
                    grip(&mut s, h.at(b), [Grip::Normal, Grip::Hot, Grip::Held, Grip::Normal][i % 4], scale, true, &Tones::LOOK);
                }
                annotation_frame(&mut s, text, scale, true, &Tones::LOOK);
                annotation_frame(&mut s, out, scale, true, &Tones::LOOK);
                grip(&mut s, Point::new(pt(120, scale), pt(320, scale)), Grip::Normal, scale, true, &Tones::LOOK);
                grip(&mut s, Point::new(pt(270, scale), pt(245, scale)), Grip::Normal, scale, true, &Tones::LOOK);
                label(&mut s, &glass, at(330, 200, 80, 24), scale, &Tones::LOOK);
                save(&format!("annotation-selected-{tag}pct-on-{paper}"), rect, &buf);

                // The text box: the dashed frame, something selected, the
                // underline of a composition, the caret. No words.
                let sel = at(60, 40, 580, 330);
                let mut buf = vec![0u8; pic.len()];
                glass.frame(&mut buf, rect, &pic, Some(sel), rect);
                for (k, colour) in [(0xFF, 0xFF, 0xFF), (0x1A, 0x1A, 0x1A), (0xE6, 0x28, 0x28), (0xFF, 0xD4, 0x00)].into_iter().enumerate() {
                    let b = at(100, 70 + k as i32 * 72, 420, 44);
                    crate::textbox::draw_frame(&mut buf, rect, b, scale);
                    let sel_part = Rect::new(b.x + pt(60, scale), b.y, pt(120, scale), b.h);
                    crate::pixels::blend(&mut buf, rect, sel_part, (0x41, 0x9C, 0xFF), (look::text_box::SELECTION_ALPHA * 256.0).round() as u32);
                    let line = px_f(look::text_box::MARKED_LINE, scale);
                    crate::pixels::blend(&mut buf, rect, Rect::new(b.x + pt(230, scale), b.bottom() - line, pt(90, scale), line), colour, 256);
                    let caret = Rect::new(b.x + pt(320, scale), b.y + pt(5, scale), px_f(look::text_box::CARET_WIDTH, scale), pt(34, scale));
                    crate::textbox::draw_caret(&mut buf, rect, caret, b, colour, scale);
                }
                Surface::new(&mut buf, rect).unwrap();
                save(&format!("textbox-{tag}pct-on-{paper}"), rect, &buf);
            }
        }
    }

    #[test]
    fn the_words_have_the_looks_padding_and_stay_on_the_monitor() {
        // At 200%: the size label 16 by 10 of padding, 12 over the selection.
        let sel = Rect::new(300, 200, 400, 300);
        let t = size_label(sel, (120, 30), 2.0, MON);
        assert_eq!(t.plate, Rect::new(300, 200 - 12 - 50, 120 + 32, 30 + 20));
        assert_eq!(t.text, Point::new(316, 148));
        // No room over it: inside its corner by 8.
        let top = Rect::new(300, 20, 400, 300);
        assert_eq!(size_label(top, (120, 30), 2.0, MON).plate, Rect::new(308, 28, 152, 50));
        // The tag beside the pointer: 24 right and below, pulled back in
        // at the monitor's corner.
        assert_eq!(pointer_tag(Point::new(500, 400), (100, 30), 2.0, MON).plate, Rect::new(524, 424, 132, 50));
        let cornered = pointer_tag(Point::new(1395, 895), (100, 30), 2.0, MON).plate;
        assert_eq!((cornered.right(), cornered.bottom()), (MON.right(), MON.bottom()));

        // A tooltip: 20 by 12 of padding, under the plate by 8, its left
        // edge the cell's; the key on a plate of its own, 16 after the name.
        let plate = Rect::new(200, 500, 1040, 80);
        let cell = Rect::new(292, 512, 56, 56);
        let tip = tooltip(cell, plate, 0, (150, 30), Some((20, 30)), 2.0, MON);
        assert_eq!(tip.plate, Rect::new(292, 588, 20 + 150 + 16 + (20 + 20) + 20, 54));
        assert_eq!(tip.name, Point::new(312, 600));
        let (key_plate, key_text) = tip.key.unwrap();
        assert_eq!(key_plate, Rect::new(312 + 150 + 16, 588 + (54 - 38) / 2, 40, 38));
        assert_eq!(key_text, Point::new(key_plate.x + 10, key_plate.y + 4));
        // Without a key it is as wide as its name.
        assert_eq!(tooltip(cell, plate, 0, (150, 30), None, 2.0, MON).plate.w, 190);
        // Under another line: that much lower.
        assert_eq!(tooltip(cell, plate, 60, (150, 30), None, 2.0, MON).plate.y, 648);
        // A toolbar at the monitor's bottom: the words go over it instead.
        let low = Rect::new(200, 810, 1040, 80);
        assert_eq!(tooltip(cell, low, 0, (150, 30), None, 2.0, MON).plate.bottom(), 810 - 8);
        assert_eq!(tooltip(cell, low, 60, (150, 30), None, 2.0, MON).plate.bottom(), 810 - 8 - 60);
        // A cell at the right edge: the tooltip is pulled back onto the monitor.
        let last = Rect::new(1330, 512, 56, 56);
        assert_eq!(tooltip(last, plate, 0, (150, 30), None, 2.0, MON).plate.right(), MON.right());

        // The status line: the dot's cell is 16 + 2 x 6 across, 20 in from
        // the left, the words 16 after it, all centred on one line.
        let (tag, dot) = status(plate, 0, (300, 30), 2.0, MON);
        assert_eq!(tag.plate, Rect::new(200, 588, 20 + 28 + 16 + 300 + 20, 30 + 24));
        assert_eq!(dot, Rect::new(220, 588 + (54 - 28) / 2, 28, 28));
        assert_eq!(tag.text, Point::new(264, 600));
        assert_eq!(line(plate, 0, (300, 30), 2.0, MON).plate, Rect::new(200, 588, 340, 54));
    }

    #[test]
    fn in_high_contrast_everything_is_drawn_in_the_colours_it_is_given() {
        // Black on white, as a person might set it, with a magenta accent.
        let c = |r: u8, g: u8, b: u8| Rgba { r, g, b, a: 1.0 };
        let tones = Tones {
            ink: c(0, 0, 0),
            ink_dim: c(0, 0, 0),
            ink_off: c(120, 120, 120),
            accent: c(200, 0, 200),
            on_accent: c(255, 255, 255),
            plate: c(255, 255, 255),
            plate_edge: c(0, 0, 0),
        };
        let pic = flat(128);
        let glass = Glass::plain(MON, &pic).unwrap();
        let layout = toolbar::layout(SEL, MON, 2.0, Props::None);
        let chosen = Button::Tool(Tool::Line);
        let cells: Vec<Cell> = layout
            .buttons
            .iter()
            .map(|(b, r)| {
                let state = if *b == chosen {
                    State::Selected
                } else if *b == Button::Undo {
                    State::Off
                } else {
                    State::Normal
                };
                Cell { button: *b, rect: *r, state }
            })
            .collect();
        let mut buf = pic.clone();
        let mut s = Surface::new(&mut buf, MON).unwrap();
        toolbar(&mut s, &glass, &layout, &cells, Props::None, 2.0, &mut Icons::new(), &tones);
        selection(&mut s, Rect::new(300, 700, 200, 100), false, 2.0, &tones);
        // The plate is the colour given, its edge the edge given.
        let gap = layout.rect_of(Button::Tool(Tool::Rect)).unwrap();
        assert_eq!(at(&buf, gap.right() + 4, gap.y + 28), (255, 255, 255));
        let p = layout.plate();
        assert_eq!(at(&buf, p.x + p.w / 2, p.y), (0, 0, 0));
        // An icon is the ink given; the chosen one and its ring the accent;
        // the one that cannot be pressed the grey; and nothing glows.
        let arrow = layout.rect_of(Button::Tool(Tool::Arrow)).unwrap();
        let dark = (0..56).filter(|d| at(&buf, arrow.x + d, arrow.y + 55 - d) == (0, 0, 0)).count();
        assert!(dark > 10, "{dark}");
        let r = layout.rect_of(chosen).unwrap();
        assert_eq!(at(&buf, r.x + 1, r.y + 28), (200, 0, 200));
        assert_eq!(at(&buf, r.x + 28, r.y + 27), (200, 0, 200));
        assert_eq!(at(&buf, r.x + 28, r.y - 2), (255, 255, 255));
        let undo = layout.rect_of(Button::Undo).unwrap();
        let grey = (0..56 * 56).filter(|k| at(&buf, undo.x + k % 56, undo.y + k / 56) == (120, 120, 120)).count();
        assert!(grey > 60, "{grey}");
        assert_eq!(at(&buf, 299, 750), (200, 0, 200), "the selection's line");
        // With the look's own tones everything is as the other tests have it.
        assert_eq!(Tones::LOOK.accent, colour::ACCENT);
    }

    #[test]
    fn a_label_is_the_same_glass_and_a_status_dot_is_red_in_a_ring() {
        let pic = flat(255);
        let glass = Glass::new(MON, &pic, 2.0).unwrap();
        let mut buf = pic.clone();
        let r = Rect::new(300, 300, 240, 60);
        let mut s = Surface::new(&mut buf, MON).unwrap();
        label(&mut s, &glass, r, 2.0, &Tones::LOOK);
        key_plate(&mut s, Rect::new(460, 314, 60, 32), 2.0, &Tones::LOOK);
        status_dot(&mut s, Rect::new(320, 314, 32, 32), 2.0);
        assert_eq!(at(&buf, 420, 330), (0x3E, 0x40, 0x40), "the glass");
        // The key's plate is white at 12% over it.
        let k = at(&buf, 490, 330);
        assert!(k.0 > 0x3E + 15 && k.0 < 0x3E + 30, "{k:?}");
        // The dot: 16 px of #E04040, and a ring 6 px wide at 30% round it.
        assert_eq!(at(&buf, 336, 330), (0xE0, 0x40, 0x40));
        let ring = at(&buf, 336 + 11, 330);
        assert!(ring.0 > 0x60 && ring.0 < 0xA0 && ring.1 < 0x50, "{ring:?}");
        assert_eq!(at(&buf, 336 + 15, 330), (0x3E, 0x40, 0x40));
    }
}
