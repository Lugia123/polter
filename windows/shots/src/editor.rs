//! The screenshot overlay as a state machine: what every click, drag and key
//! does, with no window in it.
//!
//! Specification §3.2 and §9. The host forwards the mouse and the keyboard,
//! draws what [`Editor`] holds, and owns the one thing this cannot: the text
//! box (a native control, so the input method works in it). Everything a
//! person could find surprising -- what a click on empty space does in each
//! tool, what one undo takes back, what the right button backs out of -- is
//! decided here, where it can be tested on the machine it is written on and
//! where the macOS host's behaviour can be laid beside it rule for rule.
//!
//! Coordinates are physical pixels on the virtual screen throughout.

use crate::annot::{self, Grip, Item, Shape};
use crate::dclick::Mods;
use crate::geom::{self, Handle, Hit, Point, Rect};
use crate::overlay::{self, Key};
use crate::style::{self, Prefs, Props, Tool};
use crate::toolbar::{self, Button, Layout};

/// How text measures in the font it will be drawn in. The host's is GDI; a
/// test's is arithmetic.
pub trait Measure {
    /// The width and height of `text` (which may have several lines) at a
    /// font `font_px` pixels tall.
    fn text(&self, text: &str, font_px: i32) -> (i32, i32);
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Monitor {
    pub rect: Rect,
    /// DPI over 96.
    pub scale: f64,
}

/// A top-level window as it was when the screen was frozen, topmost first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Window {
    pub id: u64,
    pub rect: Rect,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Selection {
    pub rect: Rect,
    pub monitor: usize,
    /// The window this selection is, while it is still exactly that window.
    pub window: Option<u64>,
}

/// The text being typed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextBox {
    /// Top-left corner of the box.
    pub at: Point,
    /// What the box starts with: empty, or the text being edited again.
    pub text: String,
    pub colour: u8,
    pub level: u8,
    /// The annotation this edits, or `None` for a new piece of text.
    pub editing: Option<usize>,
    /// Whether it is a number's sentence rather than a text annotation.
    pub caption: bool,
    /// Whether the number was placed by the same click that opened the box
    /// (so the two are one step to undo).
    fresh: bool,
}

/// What the host has to do after an event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    None,
    Repaint,
    /// Capture the mouse and repaint: a drag began.
    Capture,
    /// Release the mouse and repaint: a drag ended.
    Release,
    /// Close the overlay, touching nothing.
    Cancel,
    /// Compose and deliver ([`Editor::export`]).
    Finish,
    /// Long-screenshot mode was entered ([`Editor::is_long`]): open the
    /// selection to the live screen and start taking frames.
    Long,
    /// Long-screenshot mode was left without finishing: stop taking frames
    /// and cover the selection again.
    LeaveLong,
    /// Open the text box described by [`Editor::text_box`].
    OpenText,
    /// The text box's colour or size changed; restyle it.
    RestyleText,
    /// Read the text box, close it, and call [`Editor::end_text`].
    CommitText,
}

enum Drag {
    None,
    PickRegion { down: Point },
    ResizeRegion(Handle),
    MoveRegion { last: Point },
    /// A rectangle, ellipse, line, arrow or mosaic being drawn.
    Draw { start: Point },
    /// A pen or highlighter stroke being drawn.
    Stroke,
    MoveItem { index: usize, last: Point, before: Vec<Item>, changed: bool },
    ReshapeItem { index: usize, grip: Grip, before: Vec<Item>, changed: bool },
}

pub struct Editor {
    monitors: Vec<Monitor>,
    windows: Vec<Window>,
    hover: Option<(usize, Rect)>,
    forming: Option<(Rect, usize)>,
    selection: Option<Selection>,
    items: Vec<Item>,
    undo: Vec<Vec<Item>>,
    redo: Vec<Vec<Item>>,
    tool: Tool,
    prefs: Prefs,
    selected: Option<usize>,
    drag: Drag,
    live: Option<Item>,
    text: Option<TextBox>,
    hover_button: Option<Button>,
    long: bool,
}

/// What leaves when the person is done.
#[derive(Clone, Debug, PartialEq)]
pub struct Export {
    pub selection: Selection,
    pub scale: f64,
    /// Every annotation that reaches into the selection, in **screen**
    /// coordinates and drawing order, for composing the picture.
    pub on_screen: Vec<Item>,
    /// The same annotations in **image** coordinates, for the sidecar and
    /// the pasted line.
    pub on_image: Vec<Item>,
}

impl Editor {
    /// A new session over frozen `monitors` and `windows`. `preselect` is
    /// where a mouse trigger happened: the window there starts selected.
    pub fn new(monitors: Vec<Monitor>, windows: Vec<Window>, prefs: Prefs, preselect: Option<Point>) -> Editor {
        let mut e = Editor {
            monitors,
            windows,
            hover: None,
            forming: None,
            selection: None,
            items: Vec::new(),
            undo: Vec::new(),
            redo: Vec::new(),
            tool: Tool::Select,
            prefs,
            selected: None,
            drag: Drag::None,
            live: None,
            text: None,
            hover_button: None,
            long: false,
        };
        e.selection = preselect.and_then(|p| e.window_at(p));
        e
    }

    // ------------------------------------------------------------- reading

    pub fn monitors(&self) -> &[Monitor] {
        &self.monitors
    }
    /// The bounds window `id` had when the screen was frozen.
    pub fn window_rect(&self, id: u64) -> Option<Rect> {
        self.windows.iter().find(|w| w.id == id).map(|w| w.rect)
    }
    pub fn selection(&self) -> Option<&Selection> {
        self.selection.as_ref()
    }
    /// A region being dragged out, before the button comes up.
    pub fn forming(&self) -> Option<(Rect, usize)> {
        self.forming
    }
    /// The window under the pointer while nothing is selected yet.
    pub fn hover(&self) -> Option<(usize, Rect)> {
        self.hover
    }
    pub fn items(&self) -> &[Item] {
        &self.items
    }
    /// The annotation being drawn.
    pub fn live(&self) -> Option<&Item> {
        self.live.as_ref()
    }
    pub fn tool(&self) -> Tool {
        self.tool
    }
    pub fn selected(&self) -> Option<usize> {
        self.selected
    }
    pub fn text_box(&self) -> Option<&TextBox> {
        self.text.as_ref()
    }
    pub fn hover_button(&self) -> Option<Button> {
        self.hover_button
    }
    pub fn prefs(&self) -> &Prefs {
        &self.prefs
    }
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }
    /// Whether a long screenshot is being taken: the selection shows the
    /// live screen, and nothing can be drawn.
    pub fn is_long(&self) -> bool {
        self.long
    }

    /// The scale of the monitor the selection is on (1.0 before there is one).
    pub fn scale(&self) -> f64 {
        self.selection.and_then(|s| self.monitors.get(s.monitor)).map_or(1.0, |m| m.scale)
    }

    /// The annotations in the order they are drawn: mosaics first (§9.5.4),
    /// then the rest as made. Each with its index in [`Self::items`].
    pub fn draw_order(&self) -> Vec<(usize, &Item)> {
        let is_mosaic = |i: &Item| matches!(i.shape, Shape::Mosaic(_));
        let mut out: Vec<(usize, &Item)> = self.items.iter().enumerate().filter(|(_, i)| is_mosaic(i)).collect();
        out.extend(self.items.iter().enumerate().filter(|(_, i)| !is_mosaic(i)));
        out
    }

    /// Which property row is showing: the selected annotation's if there is
    /// one, else the text being typed, else the current tool's.
    pub fn props(&self) -> Props {
        if let Some(t) = &self.text {
            return if t.caption { Tool::Number.props() } else { Tool::Text.props() };
        }
        match self.selected.and_then(|i| self.items.get(i)) {
            Some(item) => item.props(),
            None => self.tool.props(),
        }
    }

    /// The colour and step the property row marks as current.
    pub fn current(&self) -> (u8, u8) {
        if let Some(t) = &self.text {
            return (t.colour, t.level);
        }
        match self.selected.and_then(|i| self.items.get(i)) {
            Some(item) => (item.colour, item.level),
            None => (self.prefs.colour(self.tool), self.prefs.level(self.tool)),
        }
    }

    /// Where the toolbar is, once there is a selection.
    pub fn layout(&self) -> Option<Layout> {
        let s = self.selection?;
        let m = self.monitors.get(s.monitor)?;
        Some(toolbar::layout(s.rect, m.rect, m.scale, self.props()))
    }

    fn rects(&self) -> Vec<Rect> {
        self.windows.iter().map(|w| w.rect).collect()
    }

    fn monitor_at(&self, p: Point) -> Option<usize> {
        self.monitors.iter().position(|m| m.rect.contains(p))
    }

    fn window_at(&self, p: Point) -> Option<Selection> {
        let monitor = self.monitor_at(p)?;
        let (i, rect) = geom::pick_window(&self.rects(), p, self.monitors[monitor].rect)?;
        Some(Selection { rect, monitor, window: Some(self.windows[i].id) })
    }

    // ------------------------------------------------------------- history

    /// Remember the annotations as they are, before changing them: one step
    /// for undo. Anything new also forgets what could have been redone.
    fn checkpoint(&mut self) {
        self.undo.push(self.items.clone());
        self.redo.clear();
    }

    fn undo(&mut self) -> Effect {
        let Some(previous) = self.undo.pop() else { return Effect::None };
        self.redo.push(std::mem::replace(&mut self.items, previous));
        self.selected = None;
        Effect::Repaint
    }

    fn redo(&mut self) -> Effect {
        let Some(next) = self.redo.pop() else { return Effect::None };
        self.undo.push(std::mem::replace(&mut self.items, next));
        self.selected = None;
        Effect::Repaint
    }

    // --------------------------------------------------------------- tools

    fn set_tool(&mut self, tool: Tool) -> Effect {
        self.tool = tool;
        self.selected = None;
        Effect::Repaint
    }

    /// Change the colour of whatever the property row is showing: the text
    /// being typed, else the selected annotation, else the current tool.
    /// A selected annotation's change does not touch the tool's memory.
    fn set_colour(&mut self, colour: u8) -> Effect {
        let colour = colour.min(style::COLOURS.len() as u8 - 1);
        if let Some(t) = &mut self.text {
            t.colour = colour;
            let tool = if t.caption { Tool::Number } else { Tool::Text };
            self.prefs.set_colour(tool, colour);
            return Effect::RestyleText;
        }
        if let Some(i) = self.selected.filter(|i| *i < self.items.len()) {
            if self.items[i].props() == Props::Block || self.items[i].colour == colour {
                return Effect::None;
            }
            self.checkpoint();
            self.items[i].colour = colour;
            return Effect::Repaint;
        }
        if matches!(self.tool.props(), Props::None | Props::Block) {
            return Effect::None;
        }
        self.prefs.set_colour(self.tool, colour);
        Effect::Repaint
    }

    fn set_level(&mut self, level: u8, m: &dyn Measure) -> Effect {
        let level = level.min(style::LEVELS - 1);
        if let Some(t) = &mut self.text {
            t.level = level;
            let tool = if t.caption { Tool::Number } else { Tool::Text };
            self.prefs.set_level(tool, level);
            return Effect::RestyleText;
        }
        if let Some(i) = self.selected.filter(|i| *i < self.items.len()) {
            if self.items[i].level == level {
                return Effect::None;
            }
            self.checkpoint();
            let scale = self.scale();
            let item = &mut self.items[i];
            item.level = level;
            // Text takes a different amount of room at a different size.
            let font = style::font_px(level, scale);
            match &mut item.shape {
                Shape::Text { text, size, .. } => *size = m.text(text, font),
                Shape::Number { text, size, .. } if !text.is_empty() => *size = m.text(text, font),
                _ => {}
            }
            return Effect::Repaint;
        }
        if self.tool.props() == Props::None {
            return Effect::None;
        }
        self.prefs.set_level(self.tool, level);
        Effect::Repaint
    }

    /// One step down or up from the current one, stopping at the ends.
    fn step_level(&mut self, by: i8, m: &dyn Measure) -> Effect {
        if self.props() == Props::None {
            return Effect::None;
        }
        let now = self.current().1 as i8;
        let next = (now + by).clamp(0, style::LEVELS as i8 - 1);
        if next == now {
            return Effect::None;
        }
        self.set_level(next as u8, m)
    }

    /// Into long-screenshot mode: the annotations go (its result carries
    /// none), as one step that undo brings back once the mode is left.
    fn enter_long(&mut self) -> Effect {
        if self.selection.is_none() {
            return Effect::None;
        }
        self.clear_annotations();
        self.tool = Tool::Select;
        self.live = None;
        self.drag = Drag::None;
        self.long = true;
        Effect::Long
    }

    fn leave_long(&mut self) -> Effect {
        self.long = false;
        Effect::LeaveLong
    }

    fn press(&mut self, button: Button, m: &dyn Measure) -> Effect {
        if self.long {
            // Only the three that mean something while frames are taken.
            return match button {
                Button::Long => self.leave_long(),
                Button::Cancel => Effect::Cancel,
                Button::Done => Effect::Finish,
                _ => Effect::None,
            };
        }
        match button {
            Button::Tool(t) => self.set_tool(t),
            Button::Undo => self.undo(),
            Button::Redo => self.redo(),
            Button::Long => self.enter_long(),
            Button::Cancel => Effect::Cancel,
            Button::Done => Effect::Finish,
            Button::Colour(c) => self.set_colour(c),
            Button::Level(l) => self.set_level(l, m),
        }
    }

    // --------------------------------------------------------------- mouse

    /// The left button went down at `p`.
    pub fn pointer_down(&mut self, p: Point, mods: Mods, m: &dyn Measure) -> Effect {
        if self.long {
            // The selection is the live screen and clicks in it are not
            // ours; of the overlay, only the toolbar answers.
            return match self.layout().and_then(|l| l.button_at(p)) {
                Some(b) => self.press(b, m),
                None => Effect::None,
            };
        }
        if self.text.is_some() {
            // A click outside the box keeps what was typed. That is all this
            // click does: the next one starts something new.
            return match self.layout().and_then(|l| l.button_at(p)) {
                Some(b @ (Button::Colour(_) | Button::Level(_))) => self.press(b, m),
                _ => Effect::CommitText,
            };
        }
        let Some(sel) = self.selection else {
            self.drag = Drag::PickRegion { down: p };
            return Effect::Capture;
        };
        if let Some(layout) = self.layout() {
            if let Some(b) = layout.button_at(p) {
                return self.press(b, m);
            }
            if layout.covers(p) {
                return Effect::None;
            }
        }
        let scale = self.scale();
        let reach = style::px(6, scale);

        if self.tool == Tool::Select || mods.ctrl {
            // The selected annotation's own grips come first: they sit on
            // top of everything, including other annotations.
            if let Some(i) = self.selected.filter(|i| *i < self.items.len()) {
                if let Some(grip) = self.items[i].grip_at(p, reach) {
                    self.drag = Drag::ReshapeItem { index: i, grip, before: self.items.clone(), changed: false };
                    return Effect::Capture;
                }
            }
            if let Some(i) = annot::hit_test(&self.items, p, scale) {
                self.selected = Some(i);
                self.drag = Drag::MoveItem { index: i, last: p, before: self.items.clone(), changed: false };
                return Effect::Capture;
            }
            let had = self.selected.take().is_some();
            if self.tool != Tool::Select {
                // Ctrl+click on nothing, with a drawing tool in hand.
                return if had { Effect::Repaint } else { Effect::None };
            }
            return match geom::hit(sel.rect, p, reach) {
                Hit::Handle(h) => {
                    self.drag = Drag::ResizeRegion(h);
                    Effect::Capture
                }
                Hit::Inside => {
                    self.drag = Drag::MoveRegion { last: p };
                    Effect::Capture
                }
                // Outside with nothing drawn: choose again. With annotations
                // that would be a way to lose them all by a slip.
                Hit::Outside if self.items.is_empty() => {
                    self.selection = None;
                    self.hover = self.window_at(p).map(|s| (s.monitor, s.rect));
                    self.drag = Drag::PickRegion { down: p };
                    Effect::Capture
                }
                Hit::Outside => {
                    if had {
                        Effect::Repaint
                    } else {
                        Effect::None
                    }
                }
            };
        }

        self.selected = None;
        if !sel.rect.contains(p) {
            return Effect::None;
        }
        let (colour, level) = (self.prefs.colour(self.tool), self.prefs.level(self.tool));
        match self.tool {
            Tool::Pen => self.live = Some(Item { shape: Shape::Pen(vec![p]), colour, level }),
            Tool::Highlighter => self.live = Some(Item { shape: Shape::Highlighter(vec![p]), colour, level }),
            Tool::Text => {
                self.text = Some(TextBox { at: p, text: String::new(), colour, level, editing: None, caption: false, fresh: false });
                return Effect::OpenText;
            }
            Tool::Number => {
                // The circle and the sentence typed after it are one step.
                self.checkpoint();
                let n = annot::next_number(&self.items);
                self.items.push(Item { shape: Shape::Number { n, at: p, text: String::new(), size: (0, 0) }, colour, level });
                let at = annot::caption_at(p, level, scale, style::font_px(level, scale));
                self.text = Some(TextBox {
                    at,
                    text: String::new(),
                    colour,
                    level,
                    editing: Some(self.items.len() - 1),
                    caption: true,
                    fresh: true,
                });
                return Effect::OpenText;
            }
            _ => {
                self.live = None;
                self.drag = Drag::Draw { start: p };
                return Effect::Capture;
            }
        }
        self.drag = Drag::Stroke;
        Effect::Capture
    }

    /// The shape a drag from `start` to `end` draws with the current tool.
    fn drawn(&self, start: Point, end: Point, shift: bool) -> Option<Item> {
        let (colour, level) = (self.prefs.colour(self.tool), self.prefs.level(self.tool));
        let corner = if shift { annot::square_corner(start, end) } else { end };
        let tip = if shift { annot::snap_45(start, end) } else { end };
        let shape = match self.tool {
            Tool::Rect => Shape::Rect(Rect::spanning(start, corner)),
            Tool::Ellipse => Shape::Ellipse(Rect::spanning(start, corner)),
            Tool::Mosaic => Shape::Mosaic(Rect::spanning(start, end)),
            Tool::Line => Shape::Line { from: start, to: tip },
            Tool::Arrow => Shape::Arrow { from: start, to: tip },
            _ => return None,
        };
        Some(Item { shape, colour, level })
    }

    /// The pointer moved to `p`.
    pub fn pointer_move(&mut self, p: Point, mods: Mods) -> Effect {
        if self.text.is_some() {
            return Effect::None;
        }
        let monitors: Vec<Rect> = self.monitors.iter().map(|m| m.rect).collect();
        match &mut self.drag {
            Drag::None => {
                if self.selection.is_some() {
                    let over = self.layout().and_then(|l| l.button_at(p));
                    if over == self.hover_button {
                        return Effect::None;
                    }
                    self.hover_button = over;
                    return Effect::Repaint;
                }
                let hover = self.window_at(p).map(|s| (s.monitor, s.rect));
                if hover == self.hover {
                    return Effect::None;
                }
                self.hover = hover;
            }
            Drag::PickRegion { down } => {
                let down = *down;
                if !geom::is_drag(down, p) {
                    return Effect::None;
                }
                // Confined to the monitor the drag started on.
                let Some(m) = geom::monitor_at(&monitors, down) else { return Effect::None };
                self.forming = geom::drag_selection(down, p, monitors[m]).map(|r| (r, m));
            }
            Drag::ResizeRegion(h) => {
                let h = *h;
                if let Some(sel) = &mut self.selection {
                    sel.rect = geom::resize(sel.rect, h, p, monitors[sel.monitor]);
                    sel.window = None;
                }
            }
            Drag::MoveRegion { last } => {
                let delta = Point::new(p.x - last.x, p.y - last.y);
                *last = p;
                if let Some(sel) = &mut self.selection {
                    sel.rect = geom::move_by(sel.rect, delta, monitors[sel.monitor]);
                    sel.window = None;
                }
            }
            Drag::Draw { start } => {
                let start = *start;
                self.live = self.drawn(start, p, mods.shift);
            }
            Drag::Stroke => {
                if let Some(Item { shape: Shape::Pen(points) | Shape::Highlighter(points), .. }) = &mut self.live {
                    if points.last() == Some(&p) {
                        return Effect::None;
                    }
                    points.push(p);
                }
            }
            Drag::MoveItem { index, last, changed, .. } => {
                let (dx, dy) = (p.x - last.x, p.y - last.y);
                if dx == 0 && dy == 0 {
                    return Effect::None;
                }
                *last = p;
                *changed = true;
                let i = *index;
                self.items[i] = self.items[i].moved(dx, dy);
            }
            Drag::ReshapeItem { index, grip, changed, .. } => {
                let (i, grip) = (*index, *grip);
                let next = self.items[i].reshaped(grip, p);
                if next == self.items[i] {
                    return Effect::None;
                }
                *changed = true;
                self.items[i] = next;
            }
        }
        Effect::Repaint
    }

    /// The left button came up at `p`.
    pub fn pointer_up(&mut self, p: Point) -> Effect {
        match std::mem::replace(&mut self.drag, Drag::None) {
            Drag::None => return Effect::None,
            Drag::PickRegion { .. } => {
                self.selection = match self.forming.take() {
                    Some((rect, monitor)) => Some(Selection { rect, monitor, window: None }),
                    // A click: the window under it, as it was frozen. Asked
                    // of the click's own position, not taken from `hover`,
                    // which is only as fresh as the last mouse move.
                    None => self.window_at(p),
                };
                self.hover = None;
            }
            Drag::ResizeRegion(_) | Drag::MoveRegion { .. } => {}
            Drag::Draw { .. } | Drag::Stroke => {
                if let Some(item) = self.live.take().filter(|i| !i.is_degenerate()) {
                    self.checkpoint();
                    self.items.push(item);
                }
            }
            // One drag is one step, however many moves it was made of.
            Drag::MoveItem { before, changed, .. } | Drag::ReshapeItem { before, changed, .. } => {
                if changed {
                    self.undo.push(before);
                    self.redo.clear();
                }
            }
        }
        Effect::Release
    }

    /// A double click at `p` (the host gets this instead of the second
    /// button-down).
    pub fn double_click(&mut self, p: Point, mods: Mods, m: &dyn Measure) -> Effect {
        if self.long {
            return self.pointer_down(p, mods, m);
        }
        if self.text.is_some() {
            return Effect::CommitText;
        }
        let Some(sel) = self.selection else { return self.pointer_down(p, mods, m) };
        if self.layout().is_some_and(|l| l.covers(p)) {
            return self.pointer_down(p, mods, m);
        }
        if self.tool == Tool::Select || mods.ctrl {
            let scale = self.scale();
            match annot::hit_test(&self.items, p, scale) {
                Some(i) => {
                    // Text is edited again where it stands; so is a number's
                    // sentence.
                    let item = &self.items[i];
                    let (at, text, caption) = match &item.shape {
                        Shape::Text { at, text, .. } => (*at, text.clone(), false),
                        Shape::Number { at, text, size, .. } => {
                            let h = if size.1 > 0 { size.1 } else { style::font_px(item.level, scale) };
                            (annot::caption_at(*at, item.level, scale, h), text.clone(), true)
                        }
                        _ => return self.pointer_down(p, mods, m),
                    };
                    self.selected = Some(i);
                    self.text = Some(TextBox {
                        at,
                        text,
                        colour: item.colour,
                        level: item.level,
                        editing: Some(i),
                        caption,
                        fresh: false,
                    });
                    return Effect::OpenText;
                }
                None if self.tool == Tool::Select && sel.rect.contains(p) => return Effect::Finish,
                None => {}
            }
        }
        // With a drawing tool in hand it is just the second of two clicks.
        self.pointer_down(p, mods, m)
    }

    /// The text box closed with `text` in it. Call after
    /// [`Effect::CommitText`], and when the box ends itself (Ctrl+Enter,
    /// Esc, losing the keyboard).
    pub fn end_text(&mut self, text: &str, m: &dyn Measure) -> Effect {
        let Some(t) = self.text.take() else { return Effect::None };
        let text = text.trim().replace("\r\n", "\n");
        let font = style::font_px(t.level, self.scale());
        let size = if text.is_empty() { (0, 0) } else { m.text(&text, font) };
        match t.editing {
            Some(i) if i < self.items.len() => {
                let mut next = self.items[i].clone();
                next.colour = t.colour;
                next.level = t.level;
                match &mut next.shape {
                    Shape::Number { text: caption, size: s, .. } => {
                        *caption = text;
                        *s = size;
                    }
                    Shape::Text { text: body, size: s, .. } => {
                        *body = text.clone();
                        *s = size;
                    }
                    _ => return Effect::Repaint,
                }
                if next == self.items[i] {
                    return Effect::Repaint;
                }
                // A number just placed already made its step; anything else
                // that changes is a step of its own.
                if !t.fresh {
                    self.checkpoint();
                }
                if next.is_degenerate() {
                    // A text edited down to nothing is deleted.
                    self.items.remove(i);
                    self.selected = None;
                } else {
                    self.items[i] = next;
                }
            }
            Some(_) => {}
            None => {
                if !text.is_empty() {
                    self.checkpoint();
                    self.items.push(Item { shape: Shape::Text { at: t.at, text, size }, colour: t.colour, level: t.level });
                }
            }
        }
        Effect::Repaint
    }

    /// The right button: step back once (§9.4). Out of the text box, then
    /// out of a selected annotation, then out of the tool, then -- only when
    /// nothing has been drawn -- out of the selection, then out of the
    /// screenshot. **With annotations it stops before the selection**, so a
    /// stray right click cannot take them all.
    pub fn right_click(&mut self) -> Effect {
        if self.long {
            return self.leave_long();
        }
        if self.text.is_some() {
            return Effect::CommitText;
        }
        if self.selected.take().is_some() {
            return Effect::Repaint;
        }
        if self.tool != Tool::Select {
            return self.set_tool(Tool::Select);
        }
        if !self.items.is_empty() {
            return Effect::None;
        }
        if self.selection.is_some() || self.forming.is_some() {
            self.selection = None;
            self.forming = None;
            self.live = None;
            self.drag = Drag::None;
            self.hover_button = None;
            return Effect::Release;
        }
        Effect::Cancel
    }

    // ---------------------------------------------------------------- keys

    /// A key went down while the overlay (not the text box) had the
    /// keyboard. Returns what the key was taken for, for the log, and what
    /// to do.
    pub fn key(&mut self, vk: u16, mods: Mods, m: &dyn Measure) -> (Key, Effect) {
        let key = overlay::key(vk, mods, self.selection.is_some());
        let effect = match key {
            Key::Cancel => Effect::Cancel,
            Key::Finish => Effect::Finish,
            // While frames are taken nothing else is a command.
            _ if self.long => Effect::None,
            Key::Undo => self.undo(),
            Key::Redo => self.redo(),
            // Tools, colours and sizes mean nothing before there is a
            // selection to use them on.
            Key::Tool(_) | Key::Colour(_) | Key::Step(_) if self.selection.is_none() => Effect::None,
            Key::Tool(t) => self.set_tool(t),
            Key::Colour(c) => self.set_colour(c),
            Key::Step(by) => self.step_level(by, m),
            Key::Delete => match self.selected.take().filter(|i| *i < self.items.len()) {
                Some(i) => {
                    self.checkpoint();
                    self.items.remove(i);
                    Effect::Repaint
                }
                None => Effect::None,
            },
            Key::Nudge(dx, dy) => match self.selected.filter(|i| *i < self.items.len()) {
                Some(i) => {
                    self.checkpoint();
                    self.items[i] = self.items[i].moved(dx, dy);
                    Effect::Repaint
                }
                None => Effect::None,
            },
            Key::Ignored => Effect::None,
        };
        (key, effect)
    }

    // -------------------------------------------------------------- export

    /// Remove every annotation, as one step that undo brings back (entering
    /// long-screenshot mode, whose result carries none).
    pub fn clear_annotations(&mut self) {
        if !self.items.is_empty() {
            self.checkpoint();
            self.items.clear();
        }
        self.selected = None;
    }

    /// What leaves: the selection, and the annotations that reach into it.
    pub fn export(&self) -> Option<Export> {
        let selection = self.selection?;
        let scale = self.scale();
        let reaches = |i: &Item| i.bounds(scale).intersect(selection.rect).is_some();
        let on_screen: Vec<Item> = self.draw_order().into_iter().map(|(_, i)| i).filter(|i| reaches(i)).cloned().collect();
        Some(Export { selection, scale, on_screen, on_image: annot::exported(&self.items, selection.rect, scale) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: fn(i32, i32) -> Point = Point::new;
    const NONE: Mods = Mods::NONE;
    const CTRL: Mods = Mods { ctrl: true, shift: false, alt: false, win: false };
    const SHIFT: Mods = Mods { ctrl: false, shift: true, alt: false, win: false };

    /// Ten pixels a character wide, one font-height a line tall.
    struct Fake;
    impl Measure for Fake {
        fn text(&self, text: &str, font_px: i32) -> (i32, i32) {
            let lines: Vec<&str> = text.split('\n').collect();
            let widest = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0) as i32;
            (widest * 10, lines.len() as i32 * font_px)
        }
    }

    const MON: Rect = Rect::new(0, 0, 2560, 1440);
    /// A window to select, and the desktop behind it.
    const WIN: Rect = Rect::new(400, 200, 900, 500);

    fn fresh() -> Editor {
        let monitors = vec![Monitor { rect: MON, scale: 1.0 }];
        let windows = vec![Window { id: 7, rect: WIN }, Window { id: 1, rect: MON }];
        Editor::new(monitors, windows, Prefs::default(), None)
    }

    /// An editor with `WIN` selected.
    fn selected() -> Editor {
        let mut e = fresh();
        click(&mut e, P(500, 300));
        assert_eq!(e.selection().map(|s| s.rect), Some(WIN));
        e
    }

    fn click(e: &mut Editor, p: Point) -> Effect {
        let down = e.pointer_down(p, NONE, &Fake);
        e.pointer_up(p);
        down
    }

    fn drag(e: &mut Editor, from: Point, to: Point) {
        drag_with(e, from, to, NONE);
    }

    fn drag_with(e: &mut Editor, from: Point, to: Point, mods: Mods) {
        e.pointer_down(from, mods, &Fake);
        e.pointer_move(P((from.x + to.x) / 2, (from.y + to.y) / 2), mods);
        e.pointer_move(to, mods);
        e.pointer_up(to);
    }

    fn key(e: &mut Editor, vk: u16) -> Effect {
        e.key(vk, NONE, &Fake).1
    }

    fn letter(e: &mut Editor, c: char) -> Effect {
        key(e, c as u16)
    }

    fn press(e: &mut Editor, b: Button) -> Effect {
        let r = e.layout().unwrap().rect_of(b).unwrap_or_else(|| panic!("{b:?} is not on the toolbar"));
        click(e, P(r.x + 2, r.y + 2))
    }

    fn rect_of(e: &Editor, i: usize) -> Rect {
        match e.items()[i].shape {
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Mosaic(r) => r,
            _ => panic!("item {i} is not a box"),
        }
    }

    /// Type `s` into the open text box and commit it.
    fn type_text(e: &mut Editor, s: &str) {
        assert!(e.text_box().is_some(), "no text box is open");
        e.end_text(s, &Fake);
    }

    // ----------------------------------------------------------- selecting

    #[test]
    fn a_click_selects_the_window_under_it_and_a_drag_a_region() {
        let mut e = fresh();
        assert_eq!(e.pointer_move(P(500, 300), NONE), Effect::Repaint);
        assert_eq!(e.hover(), Some((0, WIN)));
        click(&mut e, P(500, 300));
        assert_eq!(e.selection(), Some(&Selection { rect: WIN, monitor: 0, window: Some(7) }));
        assert_eq!(e.tool(), Tool::Select, "the tool a session starts with");

        let mut e = fresh();
        drag(&mut e, P(100, 100), P(300, 250));
        assert_eq!(e.selection(), Some(&Selection { rect: Rect::new(100, 100, 200, 150), monitor: 0, window: None }));
    }

    #[test]
    fn a_click_selects_what_is_under_it_even_with_no_mouse_move_before() {
        let mut e = fresh();
        // No pointer_move: `hover` was never set.
        click(&mut e, P(2000, 1000));
        assert_eq!(e.selection().map(|s| (s.rect, s.window)), Some((MON, Some(1))));
    }

    #[test]
    fn a_mouse_trigger_opens_with_the_window_under_it_selected() {
        let monitors = vec![Monitor { rect: MON, scale: 1.0 }];
        let windows = vec![Window { id: 7, rect: WIN }];
        let e = Editor::new(monitors.clone(), windows.clone(), Prefs::default(), Some(P(500, 300)));
        assert_eq!(e.selection().map(|s| s.window), Some(Some(7)));
        let e = Editor::new(monitors, windows, Prefs::default(), Some(P(10, 10)));
        assert!(e.selection().is_none(), "nothing under the pointer");
    }

    #[test]
    fn in_the_select_tool_the_selection_can_be_moved_and_resized_even_with_annotations() {
        let mut e = selected();
        letter(&mut e, 'R');
        drag(&mut e, P(500, 300), P(600, 380));
        letter(&mut e, 'V');
        // Drag the inside: the selection moves, the annotation does not.
        drag(&mut e, P(900, 600), P(950, 650));
        assert_eq!(e.selection().unwrap().rect, Rect::new(450, 250, 900, 500));
        assert_eq!(e.selection().unwrap().window, None, "it is no longer exactly that window");
        assert_eq!(rect_of(&e, 0), Rect::new(500, 300, 100, 80), "annotations are in screen coordinates");
        // Drag its bottom-right handle.
        drag(&mut e, P(1350, 750), P(1250, 700));
        assert_eq!(e.selection().unwrap().rect, Rect::new(450, 250, 800, 450));
        assert_eq!(e.items().len(), 1);
    }

    #[test]
    fn the_selections_handles_are_not_live_while_a_drawing_tool_is_in_hand() {
        let mut e = selected();
        letter(&mut e, 'R');
        // A drag starting exactly on the selection's top-left corner draws.
        drag(&mut e, P(400, 200), P(500, 300));
        assert_eq!(e.selection().unwrap().rect, WIN, "the selection did not move");
        assert_eq!(rect_of(&e, 0), Rect::new(400, 200, 100, 100));
    }

    #[test]
    fn clicking_outside_reselects_only_while_nothing_is_drawn() {
        let mut e = selected();
        click(&mut e, P(2000, 1000));
        assert_eq!(e.selection().map(|s| s.rect), Some(MON), "re-picked: the desktop");

        let mut e = selected();
        letter(&mut e, 'R');
        drag(&mut e, P(500, 300), P(600, 380));
        letter(&mut e, 'V');
        click(&mut e, P(2000, 1000));
        assert_eq!(e.selection().map(|s| s.rect), Some(WIN), "with an annotation, a click outside does nothing");
    }

    // ------------------------------------------------------------- drawing

    #[test]
    fn each_drawing_tool_draws_its_own_shape() {
        let cases: [(char, Shape); 5] = [
            ('R', Shape::Rect(Rect::new(500, 300, 100, 80))),
            ('O', Shape::Ellipse(Rect::new(500, 300, 100, 80))),
            ('M', Shape::Mosaic(Rect::new(500, 300, 100, 80))),
            ('L', Shape::Line { from: P(500, 300), to: P(600, 380) }),
            ('A', Shape::Arrow { from: P(500, 300), to: P(600, 380) }),
        ];
        for (c, shape) in cases {
            let mut e = selected();
            letter(&mut e, c);
            drag(&mut e, P(500, 300), P(600, 380));
            assert_eq!(e.items().len(), 1, "{c}");
            assert_eq!(e.items()[0].shape, shape, "{c}");
            assert_eq!(e.selected(), None, "a new shape is not selected");
            assert_eq!(e.tool(), Tool::from_letter(c).unwrap(), "the tool stays in hand");
        }
        for (c, pen) in [('P', true), ('H', false)] {
            let mut e = selected();
            letter(&mut e, c);
            drag(&mut e, P(500, 300), P(600, 380));
            let points = vec![P(500, 300), P(550, 340), P(600, 380)];
            assert_eq!(e.items()[0].shape, if pen { Shape::Pen(points) } else { Shape::Highlighter(points) });
        }
    }

    #[test]
    fn a_shape_takes_its_tools_colour_and_step() {
        let mut e = selected();
        letter(&mut e, 'R');
        key(&mut e, 0x36); // 6: blue
        key(&mut e, overlay::VK_OEM_6); // one step thicker
        drag(&mut e, P(500, 300), P(600, 380));
        assert_eq!((e.items()[0].colour, e.items()[0].level), (5, 2));
        // The ellipse tool was not touched.
        letter(&mut e, 'O');
        drag(&mut e, P(700, 300), P(800, 380));
        assert_eq!((e.items()[1].colour, e.items()[1].level), (0, 1));
        assert_eq!(e.prefs().colour(Tool::Rect), 5, "and the rectangle tool remembers");
    }

    #[test]
    fn shift_constrains_while_drawing() {
        let mut e = selected();
        letter(&mut e, 'R');
        drag_with(&mut e, P(500, 300), P(600, 340), SHIFT);
        assert_eq!(rect_of(&e, 0), Rect::new(500, 300, 100, 100), "a square");
        letter(&mut e, 'O');
        drag_with(&mut e, P(700, 300), P(730, 380), SHIFT);
        assert_eq!(rect_of(&e, 1), Rect::new(700, 300, 80, 80), "a circle");
        letter(&mut e, 'L');
        drag_with(&mut e, P(500, 500), P(600, 506), SHIFT);
        assert_eq!(e.items()[2].shape, Shape::Line { from: P(500, 500), to: P(600, 500) }, "horizontal");
        letter(&mut e, 'M');
        drag_with(&mut e, P(900, 300), P(1000, 340), SHIFT);
        assert_eq!(rect_of(&e, 3), Rect::new(900, 300, 100, 40), "a mosaic is not squared");
    }

    #[test]
    fn something_too_small_is_not_kept_and_is_not_a_step() {
        let mut e = selected();
        letter(&mut e, 'R');
        drag(&mut e, P(500, 300), P(501, 400));
        letter(&mut e, 'L');
        click(&mut e, P(500, 300));
        letter(&mut e, 'P');
        click(&mut e, P(500, 300));
        assert!(e.items().is_empty());
        assert!(!e.can_undo());
    }

    #[test]
    fn a_drawing_starts_only_inside_the_selection_but_may_run_out_of_it() {
        let mut e = selected();
        letter(&mut e, 'R');
        drag(&mut e, P(100, 100), P(200, 200));
        assert!(e.items().is_empty(), "started outside");
        drag(&mut e, P(1200, 600), P(1500, 900));
        assert_eq!(rect_of(&e, 0), Rect::new(1200, 600, 300, 300), "ran past the selection's corner at 1300,700");
    }

    // ------------------------------------------------ selecting annotations

    fn with_two_rects() -> Editor {
        let mut e = selected();
        letter(&mut e, 'R');
        drag(&mut e, P(500, 300), P(600, 380));
        drag(&mut e, P(700, 300), P(800, 380));
        e
    }

    #[test]
    fn the_select_tool_selects_by_the_stroke_and_drags_to_move() {
        let mut e = with_two_rects();
        letter(&mut e, 'V');
        click(&mut e, P(500, 340));
        assert_eq!(e.selected(), Some(0), "clicked the first rectangle's left edge");
        click(&mut e, P(550, 340));
        assert_eq!(e.selected(), None, "its inside is not it");
        drag(&mut e, P(700, 340), P(720, 350));
        assert_eq!(e.selected(), Some(1));
        assert_eq!(rect_of(&e, 1), Rect::new(720, 310, 100, 80));
        assert_eq!(e.selection().unwrap().rect, WIN, "the selection region did not move with it");
    }

    #[test]
    fn ctrl_click_selects_with_any_tool_in_hand() {
        let mut e = with_two_rects();
        assert_eq!(e.tool(), Tool::Rect);
        e.pointer_down(P(500, 340), CTRL, &Fake);
        e.pointer_up(P(500, 340));
        assert_eq!(e.selected(), Some(0));
        assert_eq!(e.items().len(), 2, "and did not draw a third");
        assert_eq!(e.tool(), Tool::Rect);
        // Ctrl+click on nothing lets go of it, and still draws nothing.
        e.pointer_down(P(900, 600), CTRL, &Fake);
        e.pointer_up(P(900, 600));
        assert_eq!(e.selected(), None);
        assert_eq!(e.items().len(), 2);
    }

    #[test]
    fn a_selected_box_is_reshaped_by_its_handles_and_a_line_by_its_ends() {
        let mut e = with_two_rects();
        letter(&mut e, 'V');
        click(&mut e, P(500, 340));
        drag(&mut e, P(600, 380), P(650, 420)); // its bottom-right handle
        assert_eq!(rect_of(&e, 0), Rect::new(500, 300, 150, 120));

        let mut e = selected();
        letter(&mut e, 'A');
        drag(&mut e, P(500, 300), P(600, 300));
        letter(&mut e, 'V');
        click(&mut e, P(550, 300));
        drag(&mut e, P(600, 300), P(620, 360)); // its tip
        assert_eq!(e.items()[0].shape, Shape::Arrow { from: P(500, 300), to: P(620, 360) });
    }

    #[test]
    fn the_property_row_shows_the_selected_annotations_properties() {
        let mut e = with_two_rects();
        assert_eq!(e.props(), Props::Stroke);
        letter(&mut e, 'M');
        drag(&mut e, P(900, 300), P(1000, 400));
        assert_eq!(e.props(), Props::Block);
        letter(&mut e, 'V');
        assert_eq!(e.props(), Props::None, "the select tool with nothing selected has no row");
        assert!(e.layout().unwrap().props.is_none());
        click(&mut e, P(500, 340));
        assert_eq!(e.props(), Props::Stroke, "a rectangle is selected");
        click(&mut e, P(950, 350));
        assert_eq!(e.props(), Props::Block, "the mosaic is selected");
        // Even with another tool in hand, a ctrl-selected annotation's row shows.
        letter(&mut e, 'T');
        assert_eq!(e.props(), Props::Font);
        e.pointer_down(P(950, 350), CTRL, &Fake);
        e.pointer_up(P(950, 350));
        assert_eq!(e.props(), Props::Block);
    }

    #[test]
    fn a_colour_or_step_goes_to_the_selected_annotation_and_not_to_the_tool() {
        let mut e = with_two_rects();
        letter(&mut e, 'V');
        click(&mut e, P(500, 340));
        key(&mut e, 0x34); // 4: green
        key(&mut e, overlay::VK_OEM_4); // one step thinner
        assert_eq!((e.items()[0].colour, e.items()[0].level), (3, 0));
        assert_eq!((e.items()[1].colour, e.items()[1].level), (0, 1));
        assert_eq!((e.prefs().colour(Tool::Rect), e.prefs().level(Tool::Rect)), (0, 1), "the tool's memory is its own");
        assert_eq!(e.current(), (3, 0));
        // The toolbar's swatches and steps do the same as the keys.
        press(&mut e, Button::Colour(8));
        press(&mut e, Button::Level(4));
        assert_eq!((e.items()[0].colour, e.items()[0].level), (8, 4));
    }

    #[test]
    fn the_steps_stop_at_the_ends() {
        let mut e = selected();
        letter(&mut e, 'R');
        for _ in 0..9 {
            key(&mut e, overlay::VK_OEM_6);
        }
        assert_eq!(e.prefs().level(Tool::Rect), 4);
        assert_eq!(key(&mut e, overlay::VK_OEM_6), Effect::None, "already at the top");
        for _ in 0..9 {
            key(&mut e, overlay::VK_OEM_4);
        }
        assert_eq!(e.prefs().level(Tool::Rect), 0);
    }

    #[test]
    fn a_mosaic_has_steps_but_no_colour() {
        let mut e = selected();
        letter(&mut e, 'M');
        assert_eq!(key(&mut e, 0x35), Effect::None);
        assert_eq!(e.prefs().colour(Tool::Mosaic), 0);
        key(&mut e, overlay::VK_OEM_6);
        assert_eq!(e.prefs().level(Tool::Mosaic), 2);
        drag(&mut e, P(500, 300), P(600, 400));
        letter(&mut e, 'V');
        click(&mut e, P(550, 350));
        assert_eq!(key(&mut e, 0x35), Effect::None, "nor does a selected one");
        assert!(e.layout().unwrap().rect_of(Button::Colour(0)).is_none());
    }

    #[test]
    fn delete_removes_the_selected_annotation_and_arrows_nudge_it() {
        let mut e = with_two_rects();
        letter(&mut e, 'V');
        assert_eq!(key(&mut e, overlay::VK_DELETE), Effect::None, "nothing is selected");
        click(&mut e, P(700, 340));
        key(&mut e, overlay::VK_RIGHT);
        e.key(overlay::VK_UP, SHIFT, &Fake);
        assert_eq!(rect_of(&e, 1), Rect::new(701, 290, 100, 80));
        key(&mut e, overlay::VK_BACK);
        assert_eq!(e.items().len(), 1);
        assert_eq!(e.selected(), None);
        assert_eq!(rect_of(&e, 0), Rect::new(500, 300, 100, 80), "the other one is untouched");
    }

    // ---------------------------------------------------------- undo, redo

    #[test]
    fn every_kind_of_change_is_one_step_and_comes_back() {
        let mut e = with_two_rects();
        letter(&mut e, 'V');
        let drawn = e.items().to_vec();

        drag(&mut e, P(500, 340), P(540, 360)); // move: several pointer moves, one step
        let moved = e.items().to_vec();
        drag(&mut e, P(640, 400), P(700, 450)); // reshape by its bottom-right handle
        let reshaped = e.items().to_vec();
        key(&mut e, 0x32); // colour
        let coloured = e.items().to_vec();
        key(&mut e, overlay::VK_OEM_6); // step
        let stepped = e.items().to_vec();
        key(&mut e, overlay::VK_LEFT); // nudge
        let nudged = e.items().to_vec();
        key(&mut e, overlay::VK_DELETE);
        assert_eq!(e.items().len(), 1);

        let undo = |e: &mut Editor| e.key(overlay::VK_Z, CTRL, &Fake).1;
        for expected in [&nudged, &stepped, &coloured, &reshaped, &moved, &drawn] {
            assert_eq!(undo(&mut e), Effect::Repaint);
            assert_eq!(e.items(), &expected[..]);
        }
        undo(&mut e);
        assert_eq!(e.items().len(), 1, "the second rectangle's drawing");
        undo(&mut e);
        assert!(e.items().is_empty());
        assert_eq!(undo(&mut e), Effect::None, "nothing left to undo");

        // And forwards again.
        let redo = |e: &mut Editor| e.key(overlay::VK_Z, Mods::CTRL_SHIFT, &Fake).1;
        redo(&mut e);
        redo(&mut e);
        assert_eq!(e.items(), &drawn[..]);
        redo(&mut e);
        assert_eq!(e.items(), &moved[..]);
    }

    #[test]
    fn a_new_change_forgets_what_could_have_been_redone() {
        let mut e = with_two_rects();
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert!(e.can_redo());
        drag(&mut e, P(900, 300), P(950, 350));
        assert!(!e.can_redo());
        assert_eq!(e.key(overlay::VK_Z, Mods::CTRL_SHIFT, &Fake).1, Effect::None);
        assert_eq!(e.items().len(), 2);
    }

    #[test]
    fn a_click_that_moves_nothing_is_not_a_step() {
        let mut e = with_two_rects();
        letter(&mut e, 'V');
        e.key(overlay::VK_Z, CTRL, &Fake);
        click(&mut e, P(500, 340)); // select only
        assert!(e.can_redo(), "selecting is not a change");
        assert_eq!(e.items().len(), 1);
    }

    #[test]
    fn the_toolbars_undo_and_redo_are_the_keys() {
        let mut e = with_two_rects();
        press(&mut e, Button::Undo);
        assert_eq!(e.items().len(), 1);
        press(&mut e, Button::Redo);
        assert_eq!(e.items().len(), 2);
    }

    // ----------------------------------------------------------------- text

    #[test]
    fn the_text_tool_makes_a_new_piece_at_every_click() {
        let mut e = selected();
        letter(&mut e, 'T');
        assert_eq!(click(&mut e, P(500, 300)), Effect::OpenText);
        assert_eq!(e.text_box().map(|t| (t.at, t.editing, t.caption)), Some((P(500, 300), None, false)));
        type_text(&mut e, "first");
        // The tool is still in hand: the next click is the next piece.
        assert_eq!(click(&mut e, P(500, 400)), Effect::OpenText);
        type_text(&mut e, "second\nline");
        assert_eq!(e.items().len(), 2);
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(500, 300), text: "first".into(), size: (50, 18) });
        assert_eq!(e.items()[1].shape, Shape::Text { at: P(500, 400), text: "second\nline".into(), size: (60, 36) });
    }

    #[test]
    fn a_click_outside_the_box_commits_and_does_nothing_else() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        assert_eq!(e.pointer_down(P(800, 500), NONE, &Fake), Effect::CommitText);
        assert!(e.text_box().is_some(), "the host reads the box and then calls end_text");
        e.end_text("kept", &Fake);
        assert_eq!(e.items().len(), 1);
        assert!(e.text_box().is_none(), "that click did not open another box");
    }

    #[test]
    fn nothing_typed_is_nothing_made() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        type_text(&mut e, "   \r\n ");
        assert!(e.items().is_empty());
        assert!(!e.can_undo());
    }

    #[test]
    fn colour_and_size_changed_while_typing_apply_to_the_whole_piece() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        // While the box has the keyboard the host does not send keys here;
        // the property row is clicked instead.
        let swatch = e.layout().unwrap().rect_of(Button::Colour(5)).unwrap();
        assert_eq!(e.pointer_down(P(swatch.x + 1, swatch.y + 1), NONE, &Fake), Effect::RestyleText);
        let step = e.layout().unwrap().rect_of(Button::Level(3)).unwrap();
        assert_eq!(e.pointer_down(P(step.x + 1, step.y + 1), NONE, &Fake), Effect::RestyleText);
        assert_eq!(e.text_box().map(|t| (t.colour, t.level)), Some((5, 3)));
        type_text(&mut e, "big");
        assert_eq!((e.items()[0].colour, e.items()[0].level), (5, 3));
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(500, 300), text: "big".into(), size: (30, 32) });
        assert_eq!((e.prefs().colour(Tool::Text), e.prefs().level(Tool::Text)), (5, 3), "and the tool remembers");
    }

    #[test]
    fn double_clicking_a_text_edits_it_again() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        type_text(&mut e, "first");
        letter(&mut e, 'V');
        assert_eq!(e.double_click(P(510, 305), NONE, &Fake), Effect::OpenText);
        let t = e.text_box().unwrap();
        assert_eq!((t.at, t.text.as_str(), t.editing), (P(500, 300), "first", Some(0)));
        type_text(&mut e, "changed");
        assert_eq!(e.items().len(), 1);
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(500, 300), text: "changed".into(), size: (70, 18) });
        // One step back is the text as it was; another is no text.
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(500, 300), text: "first".into(), size: (50, 18) });
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert!(e.items().is_empty());
    }

    #[test]
    fn a_colour_picked_while_editing_a_text_again_becomes_that_texts_colour() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        type_text(&mut e, "first");
        letter(&mut e, 'V');
        e.double_click(P(510, 305), NONE, &Fake);
        let swatch = e.layout().unwrap().rect_of(Button::Colour(6)).unwrap();
        e.pointer_down(P(swatch.x + 1, swatch.y + 1), NONE, &Fake);
        type_text(&mut e, "first");
        assert_eq!(e.items()[0].colour, 6, "same words, new colour: that is a change");
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert_eq!(e.items()[0].colour, 0, "and a step");
    }

    #[test]
    fn editing_a_text_down_to_nothing_deletes_it_and_leaving_it_alone_is_no_step() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        type_text(&mut e, "first");
        letter(&mut e, 'V');
        e.double_click(P(510, 305), NONE, &Fake);
        type_text(&mut e, "first");
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert!(e.items().is_empty(), "the untouched edit was not a step; this undo took the text's creation");
        e.key(overlay::VK_Z, Mods::CTRL_SHIFT, &Fake);
        e.double_click(P(510, 305), NONE, &Fake);
        type_text(&mut e, "");
        assert!(e.items().is_empty());
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert_eq!(e.items().len(), 1, "and deleting it that way is undone like any other");
    }

    #[test]
    fn a_number_and_its_sentence_are_one_step() {
        let mut e = selected();
        letter(&mut e, 'N');
        assert_eq!(click(&mut e, P(500, 300)), Effect::OpenText);
        assert_eq!(e.items().len(), 1, "the circle is there while its sentence is typed");
        let t = e.text_box().unwrap();
        assert_eq!((t.caption, t.editing), (true, Some(0)));
        assert_eq!(t.at, annot::caption_at(P(500, 300), 1, 1.0, 18));
        type_text(&mut e, "this one");
        click(&mut e, P(600, 300));
        type_text(&mut e, "");
        assert_eq!(e.items()[0].shape, Shape::Number { n: 1, at: P(500, 300), text: "this one".into(), size: (80, 18) });
        assert_eq!(e.items()[1].shape, Shape::Number { n: 2, at: P(600, 300), text: String::new(), size: (0, 0) });
        e.key(overlay::VK_Z, CTRL, &Fake);
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert!(e.items().is_empty(), "two numbers, two steps");
    }

    #[test]
    fn a_selected_texts_size_is_measured_again_when_its_step_changes() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        type_text(&mut e, "abc");
        letter(&mut e, 'V');
        click(&mut e, P(510, 305));
        key(&mut e, overlay::VK_OEM_6);
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(500, 300), text: "abc".into(), size: (30, 24) });
    }

    // ----------------------------------------------------------- stepping back

    #[test]
    fn the_right_button_steps_back_in_the_specified_order() {
        let mut e = with_two_rects();
        letter(&mut e, 'T');
        click(&mut e, P(900, 600));
        assert_eq!(e.right_click(), Effect::CommitText, "1. out of the text box");
        e.end_text("note", &Fake);
        e.pointer_down(P(500, 340), CTRL, &Fake);
        e.pointer_up(P(500, 340));
        assert_eq!(e.selected(), Some(0));
        assert_eq!(e.right_click(), Effect::Repaint, "2. let go of the annotation");
        assert_eq!(e.selected(), None);
        assert_eq!(e.tool(), Tool::Text);
        assert_eq!(e.right_click(), Effect::Repaint, "3. put the tool down");
        assert_eq!(e.tool(), Tool::Select);
        assert_eq!(e.right_click(), Effect::None, "with annotations it goes no further");
        assert_eq!(e.items().len(), 3);
        assert!(e.selection().is_some());
    }

    #[test]
    fn with_nothing_drawn_the_right_button_clears_the_selection_and_then_cancels() {
        let mut e = selected();
        assert_eq!(e.right_click(), Effect::Release);
        assert!(e.selection().is_none());
        assert_eq!(e.right_click(), Effect::Cancel);
    }

    // ----------------------------------------------------------- the toolbar

    #[test]
    fn the_toolbar_takes_the_click_and_the_picture_does_not() {
        let mut e = selected();
        assert_eq!(press(&mut e, Button::Tool(Tool::Rect)), Effect::Repaint);
        assert_eq!(e.tool(), Tool::Rect);
        // Between two buttons: the toolbar swallows it; nothing is drawn.
        let r = e.layout().unwrap().rect_of(Button::Tool(Tool::Rect)).unwrap();
        drag(&mut e, P(r.right() + 1, r.y + 3), P(r.right() + 60, r.y + 60));
        assert!(e.items().is_empty());
        assert_eq!(press(&mut e, Button::Done), Effect::Finish);
        assert_eq!(press(&mut e, Button::Cancel), Effect::Cancel);
        assert_eq!(press(&mut e, Button::Long), Effect::Long);
    }

    #[test]
    fn the_pointer_over_a_button_is_what_the_tooltip_follows() {
        let mut e = selected();
        let r = e.layout().unwrap().rect_of(Button::Tool(Tool::Arrow)).unwrap();
        assert_eq!(e.pointer_move(P(r.x + 3, r.y + 3), NONE), Effect::Repaint);
        assert_eq!(e.hover_button(), Some(Button::Tool(Tool::Arrow)));
        assert_eq!(e.pointer_move(P(r.x + 5, r.y + 5), NONE), Effect::None, "still the same button");
        e.pointer_move(P(900, 500), NONE);
        assert_eq!(e.hover_button(), None);
    }

    #[test]
    fn keys_for_tools_mean_nothing_before_there_is_a_selection() {
        let mut e = fresh();
        assert_eq!(letter(&mut e, 'R'), Effect::None);
        assert_eq!(e.tool(), Tool::Select);
        assert_eq!(key(&mut e, overlay::VK_RETURN), Effect::None);
        assert_eq!(key(&mut e, overlay::VK_ESCAPE), Effect::Cancel);
    }

    #[test]
    fn a_double_click_finishes_only_in_the_select_tool_on_empty_selection() {
        let mut e = with_two_rects();
        assert_eq!(e.double_click(P(900, 600), NONE, &Fake), Effect::Capture, "with a tool in hand it is a second click");
        e.pointer_up(P(900, 600));
        // Ctrl held makes a click a selecting one, not a finishing one.
        assert_eq!(e.double_click(P(900, 600), CTRL, &Fake), Effect::None);
        letter(&mut e, 'V');
        assert_eq!(e.double_click(P(900, 600), NONE, &Fake), Effect::Finish);
        assert_eq!(e.double_click(P(500, 340), NONE, &Fake), Effect::Capture, "on a rectangle it grabs the rectangle");
        e.pointer_up(P(500, 340));
        // Outside the selection, with annotations: it lets go of the
        // rectangle and does nothing more -- no re-pick, no finish.
        assert_eq!(e.double_click(P(100, 100), NONE, &Fake), Effect::Repaint);
        assert_eq!(e.selected(), None);
        assert_eq!(e.double_click(P(100, 100), NONE, &Fake), Effect::None);
        assert_eq!(e.selection().map(|s| s.rect), Some(WIN));
    }

    // -------------------------------------------------------------- export

    #[test]
    fn what_leaves_is_what_reaches_into_the_selection_mosaics_first() {
        let mut e = selected();
        letter(&mut e, 'R');
        drag(&mut e, P(500, 300), P(600, 380));
        letter(&mut e, 'M');
        drag(&mut e, P(700, 300), P(800, 380));
        letter(&mut e, 'A');
        drag(&mut e, P(1200, 600), P(1500, 900)); // runs out of the selection
        // Shrink the selection so the first rectangle is wholly outside it.
        letter(&mut e, 'V');
        drag(&mut e, P(400, 450), P(650, 450)); // its west handle
        assert_eq!(e.selection().unwrap().rect, Rect::new(650, 200, 650, 500));

        let x = e.export().unwrap();
        assert_eq!(x.selection.rect, Rect::new(650, 200, 650, 500));
        assert_eq!(x.on_screen.len(), 2);
        assert!(matches!(x.on_screen[0].shape, Shape::Mosaic(_)), "the mosaic is drawn first");
        assert_eq!(x.on_screen[0].shape, Shape::Mosaic(Rect::new(700, 300, 100, 80)), "in screen coordinates");
        // For the sidecar: image coordinates, in the order they were made.
        assert_eq!(x.on_image[0].shape, Shape::Mosaic(Rect::new(50, 100, 100, 80)));
        assert_eq!(x.on_image[1].shape, Shape::Arrow { from: P(550, 400), to: P(850, 700) }, "true geometry, past the edge");
        assert_eq!(e.items().len(), 3, "the one outside is still there if the selection grows back");
    }

    #[test]
    fn mosaics_are_drawn_first_whatever_order_they_were_made_in() {
        let mut e = with_two_rects();
        letter(&mut e, 'M');
        drag(&mut e, P(900, 300), P(1000, 400));
        let order: Vec<usize> = e.draw_order().into_iter().map(|(i, _)| i).collect();
        assert_eq!(order, [2, 0, 1]);
    }

    #[test]
    fn entering_long_mode_clears_the_annotations_as_one_step() {
        let mut e = with_two_rects();
        e.clear_annotations();
        assert!(e.items().is_empty());
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert_eq!(e.items().len(), 2);
    }

    #[test]
    fn long_mode_clears_the_annotations_and_answers_only_to_its_three_buttons() {
        let mut e = with_two_rects();
        assert_eq!(press(&mut e, Button::Long), Effect::Long);
        assert!(e.is_long());
        assert!(e.items().is_empty(), "a long screenshot carries no annotations");
        assert_eq!(e.props(), Props::None);
        assert_eq!(e.tool(), Tool::Select);
        // Nothing can be drawn, selected or chosen.
        assert_eq!(letter(&mut e, 'R'), Effect::None);
        assert_eq!(e.tool(), Tool::Select);
        assert_eq!(click(&mut e, P(500, 340)), Effect::None, "a click in the live selection is not ours");
        drag(&mut e, P(900, 600), P(950, 650));
        assert_eq!(e.selection().map(|s| s.rect), Some(WIN), "nor does a drag move the selection");
        assert_eq!(press(&mut e, Button::Tool(Tool::Pen)), Effect::None);
        assert_eq!(press(&mut e, Button::Undo), Effect::None);
        assert_eq!(e.key(overlay::VK_Z, CTRL, &Fake).1, Effect::None);
        assert!(e.items().is_empty() && e.is_long());
        // The three that work.
        assert_eq!(press(&mut e, Button::Done), Effect::Finish);
        assert_eq!(press(&mut e, Button::Cancel), Effect::Cancel);
        assert_eq!(key(&mut e, overlay::VK_RETURN), Effect::Finish);
        assert_eq!(key(&mut e, overlay::VK_ESCAPE), Effect::Cancel);
    }

    #[test]
    fn leaving_long_mode_gives_the_annotations_back_to_undo() {
        let mut e = with_two_rects();
        press(&mut e, Button::Long);
        assert_eq!(e.right_click(), Effect::LeaveLong, "the right button steps back out of it");
        assert!(!e.is_long());
        assert!(e.items().is_empty());
        e.key(overlay::VK_Z, CTRL, &Fake);
        assert_eq!(e.items().len(), 2, "entering was one step, and undo takes it back");
        // The button toggles too.
        press(&mut e, Button::Long);
        assert_eq!(press(&mut e, Button::Long), Effect::LeaveLong);
        assert!(!e.is_long());
    }

    #[test]
    fn long_mode_needs_a_selection() {
        let mut e = fresh();
        assert_eq!(e.enter_long(), Effect::None);
        assert!(!e.is_long());
    }

    #[test]
    fn sizes_follow_the_monitor_the_selection_is_on() {
        let monitors = vec![Monitor { rect: MON, scale: 1.0 }, Monitor { rect: Rect::new(2560, 0, 3840, 2160), scale: 2.0 }];
        let windows = vec![Window { id: 9, rect: Rect::new(3000, 200, 1600, 1000) }];
        let mut e = Editor::new(monitors, windows, Prefs::default(), Some(P(3100, 300)));
        assert_eq!(e.scale(), 2.0);
        assert_eq!(e.layout().unwrap().rect_of(Button::Done).unwrap().w, 56);
        letter(&mut e, 'T');
        click(&mut e, P(3100, 300));
        type_text(&mut e, "abc");
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(3100, 300), text: "abc".into(), size: (30, 36) }, "18 pt at 200%");
    }
}
