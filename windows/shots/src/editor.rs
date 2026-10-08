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
use crate::textbox;
use crate::chrome;
use crate::glass;
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
    /// Whether the host has begun closing the box ([`Editor::close_text`]).
    closing: bool,
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
    /// Finish as Done does, and also keep a copy in the Downloads folder.
    Save,
    /// Put the colour under the pointer on the clipboard and say so
    /// (`Editor::magnifier`).
    CopyColour,
    /// Close the text box and keep what is in it: [`Editor::close_text`],
    /// then read the box and destroy it, then [`Editor::end_text`].
    CommitText,
}

enum Drag {
    None,
    PickRegion { down: Point },
    ResizeRegion(Handle),
    MoveRegion { last: Point },
    /// The toolbar held by its plate; `grab` is from its corner to the pointer.
    MoveBar { grab: Point },
    /// A rectangle, ellipse, line, arrow or mosaic being drawn.
    Draw { start: Point },
    /// A pen or highlighter stroke being drawn.
    Stroke,
    MoveItem { index: usize, last: Point, before: Vec<Item>, changed: bool },
    /// `offset`: from the pointer to the point of the shape the grip moves.
    /// A grip is drawn on the frame, a little outside that point.
    ReshapeItem { index: usize, grip: Grip, offset: Point, before: Vec<Item>, changed: bool },
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
    /// The toolbar cell the button is held on, until it comes up.
    pressed: Option<Button>,
    /// The grip of the selected annotation the pointer is over.
    hover_grip: Option<Grip>,
    /// Where the pointer was last seen.
    pointer: Option<Point>,
    long: bool,
    /// Where the user dragged the toolbar to (its top-left corner). Until
    /// then, and again with the next selection, it sits beside the selection.
    bar_at: Option<Point>,
}

/// What the pointer looks like (§9.8.11A.4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cursor {
    /// The current tool's: a cross.
    Tool,
    Arrow,
    /// Over the selected annotation: it can be moved.
    Move,
    UpDown,
    LeftRight,
    /// North-west to south-east.
    Diagonal,
    /// North-east to south-west.
    AntiDiagonal,
}

/// The selected annotation as it is marked: the box of what it draws,
/// whether a frame goes round that, and its grips.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Marked {
    pub ink: Rect,
    pub framed: bool,
    pub grips: Vec<(Point, chrome::Grip)>,
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
    /// A new session over frozen `monitors` and `windows`, with nothing
    /// selected -- however it was triggered. A mouse trigger used to hand
    /// over where it happened and the window there started out selected;
    /// now the window under the pointer is only the clear one, and a click
    /// on the overlay selects it, as after the hotkey.
    pub fn new(monitors: Vec<Monitor>, windows: Vec<Window>, prefs: Prefs) -> Editor {
        Editor {
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
            pressed: None,
            hover_grip: None,
            pointer: None,
            long: false,
            bar_at: None,
        }
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

    /// The height of one line of text at `level`, as the host draws it.
    pub fn text_line(&self, level: u8, m: &dyn Measure) -> i32 {
        m.text("M", style::font_px(level, self.scale())).1.max(1)
    }

    /// What the text box has to stay off: both rows of the toolbar as they
    /// are while a text is typed (`textbox`).
    pub fn text_keep_clear(&self) -> Vec<Rect> {
        if self.selection.is_none() {
            return Vec::new();
        }
        let Some(l) = self.bar_layout(Props::Font) else { return Vec::new() };
        let mut out = vec![l.bar];
        out.extend(l.props);
        out
    }

    /// Where the open text box is, for the text `text` (line breaks `\n` or CR LF): specification
    /// §9.3, and `textbox::rect` for the rule. `None` with no box open.
    pub fn text_rect(&self, text: &str, m: &dyn Measure) -> Option<Rect> {
        let t = self.text.as_ref()?;
        let s = self.selection?;
        let mon = self.monitors.get(s.monitor)?;
        let font = style::font_px(t.level, mon.scale);
        let min_w = textbox::min_width(font, mon.scale);
        let line = self.text_line(t.level, m);
        let lines = textbox::lines(&text.replace("\r\n", "\n"));
        // **An empty line is not measured** (task 1199): the host's `Measure`
        // hands the text to `DrawTextW` as a counted slice, and for an empty
        // one that is a dangling pointer and a count of 0 -- which `USER32`
        // on Windows 11 build 26200 reads through. The first click of the
        // text tool opens an empty box, so this was the first thing it did.
        let widest = text.split('\n').map(|l| l.trim_end_matches('\r')).filter(|l| !l.is_empty()).map(|l| m.text(l, font).0).max().unwrap_or(0);
        let content_w = textbox::width_for(widest, min_w, font);
        Some(textbox::rect(self.text_start(t, lines, line), lines, line, content_w, min_w, s.rect, mon.rect, &self.text_keep_clear()))
    }

    /// Where the box's top-left is, for `lines` lines of height `line`. A
    /// number's sentence is centred on its circle at the box's own height
    /// -- the same place the finished sentence is drawn (`annot::caption_at`)
    /// -- and at the box's own size, not the size the number had when it
    /// was last closed: so an empty box and a full one are level with the
    /// circle alike, and a new colour or size moves it at once.
    fn text_start(&self, t: &TextBox, lines: i32, line: i32) -> Point {
        let centre = match t.editing.and_then(|i| self.items.get(i)).map(|i| &i.shape) {
            Some(Shape::Number { at, .. }) if t.caption => *at,
            _ => return t.at,
        };
        annot::caption_at(centre, t.level, self.scale(), lines.max(1) * line)
    }

    /// The number being given its sentence, as it will look when it is
    /// closed: the colour and size now chosen on the property row, which
    /// the item itself takes only at the close. Its index, and a copy.
    pub fn number_in_edit(&self) -> Option<(usize, Item)> {
        let t = self.text.as_ref().filter(|t| t.caption)?;
        let i = t.editing?;
        let mut item = self.items.get(i)?.clone();
        item.colour = t.colour;
        item.level = t.level;
        Some((i, item))
    }

    /// Where a new text starts for a press at `p`: the press, pulled into
    /// the selection far enough for one line (`textbox::origin`).
    fn text_origin(&self, p: Point, level: u8, m: &dyn Measure) -> Point {
        let Some(s) = self.selection else { return p };
        let scale = self.scale();
        let min_w = textbox::min_width(style::font_px(level, scale), scale);
        textbox::origin(p, self.text_line(level, m), min_w, s.rect, &self.text_keep_clear())
    }
    pub fn hover_button(&self) -> Option<Button> {
        self.hover_button
    }

    /// Where the pointer was last seen. The host tells it once when the
    /// session opens ([`Self::pointer_move`]), so this is known before the
    /// mouse first moves.
    pub fn pointer(&self) -> Option<Point> {
        self.pointer
    }

    /// Where the magnifier is shown, if it is: at the pointer, while there
    /// is no selection (hovering, or dragging one out) and while the
    /// selection is dragged by a handle or by its middle. Not once it is
    /// settled and annotating begins, nor in a long screenshot.
    pub fn magnifier(&self) -> Option<Point> {
        let p = self.pointer?;
        self.monitor_at(p)?;
        if self.long || self.text.is_some() {
            return None;
        }
        let shown = match self.drag {
            Drag::PickRegion { .. } | Drag::ResizeRegion(_) | Drag::MoveRegion { .. } => true,
            Drag::None => self.selection.is_none(),
            _ => false,
        };
        shown.then_some(p)
    }

    /// The part of monitor `index` shown as it is, the rest being glass
    /// (`glass::hole`): the selection, else the window under the pointer.
    pub fn hole(&self, index: usize) -> Option<Rect> {
        let monitor = self.monitors.get(index)?.rect;
        glass::hole(
            index,
            monitor,
            self.selection.map(|s| (s.monitor, s.rect)),
            self.forming.map(|(r, m)| (m, r)),
            self.hover,
            self.pointer.and_then(|p| self.monitor_at(p)),
        )
    }

    /// Whether `button` can be pressed now.
    fn enabled(&self, button: Button) -> bool {
        if self.long {
            return matches!(button, Button::Long | Button::Save | Button::Cancel | Button::Done);
        }
        match button {
            Button::Undo => self.can_undo(),
            Button::Redo => self.can_redo(),
            _ => true,
        }
    }

    /// Every cell of the toolbar and the state it is drawn in (§9.8.4).
    /// Empty before there is a selection.
    pub fn cells(&self) -> Vec<chrome::Cell> {
        let Some(layout) = self.layout() else { return Vec::new() };
        let (colour, level) = self.current();
        layout
            .buttons
            .iter()
            .map(|(button, rect)| {
                let current = match *button {
                    Button::Tool(t) => !self.long && self.tool == t,
                    Button::Colour(c) => c == colour,
                    Button::Level(l) => l == level,
                    Button::Long => self.long,
                    _ => false,
                };
                let state =
                    chrome::state(self.enabled(*button), current, self.hover_button == Some(*button), self.pressed == Some(*button));
                chrome::Cell { button: *button, rect: *rect, state }
            })
            .collect()
    }

    /// Whether the selection shows its eight knobs: while the select tool
    /// is the mouse and no annotation is selected.
    pub fn knobs(&self) -> bool {
        !self.long && self.text.is_none() && self.tool == Tool::Select && self.selected.is_none()
    }

    /// Where the grips of annotation `i` are drawn: a box's on the corners
    /// and sides of its frame, a line's on its two ends.
    fn grip_points(&self, i: usize) -> Vec<(Grip, Point)> {
        let scale = self.scale();
        let item = &self.items[i];
        let frame = chrome::frame_box(item.bounds(scale), scale);
        item.grips().into_iter().map(|(g, at)| (g, if let Grip::Box(h) = g { h.at(frame) } else { at })).collect()
    }

    /// The grip of the selected annotation under `p`.
    fn grip_under(&self, p: Point) -> Option<Grip> {
        let i = self.selected.filter(|i| *i < self.items.len())?;
        let reach = chrome::grip_reach(self.scale());
        self.grip_points(i).into_iter().find(|(_, at)| (p.x - at.x).abs() <= reach && (p.y - at.y).abs() <= reach).map(|(g, _)| g)
    }

    /// How the selected annotation is marked (§9.8.11A): a frame for
    /// everything but a line and an arrow; grips for what can be reshaped,
    /// put away while it is being moved.
    pub fn marked(&self) -> Option<Marked> {
        let i = self.selected.filter(|i| *i < self.items.len())?;
        let item = &self.items[i];
        let framed = !matches!(item.shape, Shape::Line { .. } | Shape::Arrow { .. });
        let held = match &self.drag {
            Drag::ReshapeItem { grip, .. } => Some(*grip),
            _ => None,
        };
        let grips = if matches!(self.drag, Drag::MoveItem { .. }) {
            Vec::new()
        } else {
            self.grip_points(i)
                .into_iter()
                .map(|(g, at)| {
                    let how = if held == Some(g) {
                        chrome::Grip::Held
                    } else if held.is_none() && self.hover_grip == Some(g) {
                        chrome::Grip::Hot
                    } else {
                        chrome::Grip::Normal
                    };
                    (at, how)
                })
                .collect()
        };
        Some(Marked { ink: item.bounds(self.scale()), framed, grips })
    }

    /// What a shape being reshaped measures, for the tag beside the
    /// pointer: a box's width and height in pixels, a line's angle from
    /// the horizontal in whole degrees.
    pub fn reshape_tag(&self) -> Option<String> {
        let Drag::ReshapeItem { index, .. } = &self.drag else { return None };
        match &self.items.get(*index)?.shape {
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Mosaic(r) => Some(format!("{} × {}", r.w, r.h)),
            Shape::Line { from, to } | Shape::Arrow { from, to } => {
                // Up the screen is a positive angle.
                let degrees = ((from.y - to.y) as f64).atan2((to.x - from.x) as f64).to_degrees().round() as i32;
                Some(format!("{}°", degrees.rem_euclid(360)))
            }
            _ => None,
        }
    }

    /// What the pointer looks like at `p` (§9.8.11A.4).
    pub fn cursor(&self, p: Point, mods: Mods) -> Cursor {
        let Some(sel) = self.selection else { return Cursor::Tool };
        if self.text.is_some() {
            return Cursor::Tool;
        }
        if self.long {
            return match self.layout().filter(|l| l.covers(p)) {
                Some(l) if l.button_at(p).is_none() => Cursor::Move,
                Some(_) => Cursor::Arrow,
                None => Cursor::Tool,
            };
        }
        if let Some(l) = self.layout().filter(|l| l.covers(p)) {
            // The plate between the cells takes hold of the whole toolbar.
            return if l.button_at(p).is_some() { Cursor::Arrow } else { Cursor::Move };
        }
        if self.tool != Tool::Select && !mods.ctrl {
            return Cursor::Tool;
        }
        let of = |h: Handle| match h {
            Handle::N | Handle::S => Cursor::UpDown,
            Handle::E | Handle::W => Cursor::LeftRight,
            Handle::NW | Handle::SE => Cursor::Diagonal,
            Handle::NE | Handle::SW => Cursor::AntiDiagonal,
        };
        let scale = self.scale();
        match self.grip_under(p) {
            Some(Grip::Box(h)) => return of(h),
            Some(Grip::End(_)) => return Cursor::Tool,
            None => {}
        }
        match annot::hit_test(&self.items, p, scale) {
            Some(i) if self.selected == Some(i) => return Cursor::Move,
            Some(_) => return Cursor::Arrow,
            None => {}
        }
        // The inside of the selected rectangle or ellipse carries it too
        // (§9.8.11A.4), though only its line is hit by a first click.
        if self.selected_holds(p) {
            return Cursor::Move;
        }
        if self.knobs() {
            if let Hit::Handle(h) = geom::hit(sel.rect, p, style::px(6, scale)) {
                return of(h);
            }
        }
        Cursor::Tool
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
        self.bar_layout(self.props())
    }

    /// The toolbar showing property row `props`: where it was dragged to,
    /// else beside the selection.
    fn bar_layout(&self, props: Props) -> Option<Layout> {
        let s = self.selection?;
        let m = self.monitors.get(s.monitor)?;
        Some(match self.bar_at {
            Some(at) => toolbar::layout_at(toolbar::keep_on(at, m.rect, m.scale), m.scale, props),
            None => toolbar::layout(s.rect, m.rect, m.scale, props),
        })
    }

    /// Whether `p` is inside the selected annotation's outline (a rectangle
    /// or an ellipse), where it is held although it is not on the line.
    fn selected_holds(&self, p: Point) -> bool {
        self.selected.and_then(|i| self.items.get(i)).is_some_and(|it| it.holds(p))
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
            if self.items[i].props() == Props::Block || (self.items[i].colour == colour && self.items[i].rgb.is_none()) {
                return Effect::None;
            }
            self.checkpoint();
            self.items[i].colour = colour;
            // A palette colour replaces whatever colour it had.
            self.items[i].rgb = None;
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
        if let Some(t) = &self.text {
            // A text that is new keeps to the selection at its new size
            // too: a bigger line may no longer fit where it was started.
            // One edited again, or a number's sentence, stays where it is.
            let at = if t.editing.is_none() && !t.caption { self.text_origin(t.at, level, m) } else { t.at };
            let tool = if t.caption { Tool::Number } else { Tool::Text };
            self.prefs.set_level(tool, level);
            if let Some(t) = &mut self.text {
                t.level = level;
                t.at = at;
            }
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
                Shape::Text { text, size, .. } if !text.is_empty() => *size = m.text(text, font),
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

    /// The button went down on toolbar cell `button`. It is drawn held
    /// until the button comes up. What it does it does now -- except
    /// Cancel and Done, which act when the button comes up on them
    /// ([`Self::pointer_up`]): the overlay is gone the moment they act, and
    /// a cell that acted on the way down would never be seen held.
    fn press_down(&mut self, button: Button, m: &dyn Measure) -> Effect {
        if !self.enabled(button) {
            return Effect::None;
        }
        self.pressed = Some(button);
        if matches!(button, Button::Cancel | Button::Done | Button::Save) {
            return Effect::Repaint;
        }
        match self.press(button, m) {
            Effect::None => Effect::Repaint,
            effect => effect,
        }
    }

    fn press(&mut self, button: Button, m: &dyn Measure) -> Effect {
        if self.long {
            // Only the three that mean something while frames are taken.
            return match button {
                Button::Long => self.leave_long(),
                Button::Cancel => Effect::Cancel,
                Button::Done => Effect::Finish,
                Button::Save => Effect::Save,
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
            Button::Save => Effect::Save,
            Button::Colour(c) => self.set_colour(c),
            Button::Level(l) => self.set_level(l, m),
        }
    }

    // --------------------------------------------------------------- mouse

    /// The left button went down at `p`.
    pub fn pointer_down(&mut self, p: Point, mods: Mods, m: &dyn Measure) -> Effect {
        self.pointer = Some(p);
        if self.long {
            // The selection is the live screen and clicks in it are not
            // ours; of the overlay, only the toolbar answers.
            let layout = self.layout();
            return match layout.as_ref().and_then(|l| l.button_at(p)) {
                Some(b) => self.press_down(b, m),
                // The toolbar can be moved in a long screenshot too: it may
                // be over what is being scrolled.
                None => match layout.filter(|l| l.covers(p)) {
                    Some(l) => {
                        self.drag = Drag::MoveBar { grab: Point::new(p.x - l.bar.x, p.y - l.bar.y) };
                        Effect::Capture
                    }
                    None => Effect::None,
                },
            };
        }
        if self.text.is_some() {
            // A click outside the box keeps what was typed. That is all this
            // click does: the next one starts something new.
            return match self.layout().and_then(|l| l.button_at(p)) {
                Some(b @ (Button::Colour(_) | Button::Level(_))) => self.press_down(b, m),
                _ => Effect::CommitText,
            };
        }
        let Some(sel) = self.selection else {
            self.drag = Drag::PickRegion { down: p };
            return Effect::Capture;
        };
        if let Some(layout) = self.layout() {
            if let Some(b) = layout.button_at(p) {
                return self.press_down(b, m);
            }
            if layout.covers(p) {
                // Held by the plate, not a cell: the toolbar moves.
                self.drag = Drag::MoveBar { grab: Point::new(p.x - layout.bar.x, p.y - layout.bar.y) };
                return Effect::Capture;
            }
        }
        let scale = self.scale();
        let reach = style::px(6, scale);

        if self.tool == Tool::Select || mods.ctrl {
            // The selected annotation's own grips come first: they sit on
            // top of everything, including other annotations.
            if let Some(i) = self.selected.filter(|i| *i < self.items.len()) {
                if let Some(grip) = self.grip_under(p) {
                    // The grip is on the frame; what it moves is the
                    // shape's own corner, side or end, and that keeps its
                    // distance from the pointer for the whole drag.
                    let moves = self.items[i].grips().into_iter().find(|(g, _)| *g == grip).map_or(p, |(_, at)| at);
                    let offset = Point::new(moves.x - p.x, moves.y - p.y);
                    self.drag = Drag::ReshapeItem { index: i, grip, offset, before: self.items.clone(), changed: false };
                    return Effect::Capture;
                }
            }
            if let Some(i) = annot::hit_test(&self.items, p, scale) {
                self.selected = Some(i);
                self.drag = Drag::MoveItem { index: i, last: p, before: self.items.clone(), changed: false };
                return Effect::Capture;
            }
            if let Some(i) = self.selected.filter(|_| self.selected_holds(p)) {
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
                    self.bar_at = None;
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

        // A drawing tool lets go of what was selected. Outside the selection
        // nothing is drawn, but letting go is still something to show: the
        // grips have to leave the screen now, not at the next repaint.
        let let_go = self.selected.take().is_some();
        if !sel.rect.contains(p) {
            return if let_go { Effect::Repaint } else { Effect::None };
        }
        let (colour, level) = (self.prefs.colour(self.tool), self.prefs.level(self.tool));
        match self.tool {
            Tool::Pen => self.live = Some(Item { shape: Shape::Pen(vec![p]), colour, level, rgb: None }),
            Tool::Highlighter => self.live = Some(Item { shape: Shape::Highlighter(vec![p]), colour, level, rgb: None }),
            Tool::Text => {
                let at = self.text_origin(p, level, m);
                self.text = Some(TextBox { at, text: String::new(), colour, level, editing: None, caption: false, fresh: false, closing: false });
                return Effect::OpenText;
            }
            Tool::Number => {
                // The circle and the sentence typed after it are one step.
                self.checkpoint();
                let n = annot::next_number(&self.items);
                self.items.push(Item { shape: Shape::Number { n, at: p, text: String::new(), size: (0, 0) }, colour, level, rgb: None });
                let at = annot::caption_at(p, level, scale, style::font_px(level, scale));
                self.text = Some(TextBox {
                    at,
                    text: String::new(),
                    colour,
                    level,
                    editing: Some(self.items.len() - 1),
                    caption: true,
                    fresh: true,
                    closing: false,
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
        Some(Item { shape, colour, level, rgb: None })
    }

    /// The pointer moved to `p`.
    pub fn pointer_move(&mut self, p: Point, mods: Mods) -> Effect {
        self.pointer = Some(p);
        if self.text.is_some() {
            return Effect::None;
        }
        let monitors: Vec<Rect> = self.monitors.iter().map(|m| m.rect).collect();
        match &mut self.drag {
            Drag::None => {
                if self.selection.is_some() {
                    let over = self.layout().and_then(|l| l.button_at(p));
                    let grip = if over.is_none() && !self.long { self.grip_under(p) } else { None };
                    if over == self.hover_button && grip == self.hover_grip {
                        return Effect::None;
                    }
                    self.hover_button = over;
                    self.hover_grip = grip;
                    return Effect::Repaint;
                }
                let hover = self.window_at(p).map(|s| (s.monitor, s.rect));
                if hover == self.hover {
                    // The magnifier follows the pointer.
                    return if self.magnifier().is_some() { Effect::Repaint } else { Effect::None };
                }
                self.hover = hover;
            }
            Drag::PickRegion { down } => {
                let down = *down;
                if !geom::is_drag(down, p) {
                    return Effect::Repaint;
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
            Drag::MoveBar { grab } => {
                let (grab, sel) = (*grab, self.selection);
                let Some(m) = sel.and_then(|s| self.monitors.get(s.monitor)) else { return Effect::None };
                let at = toolbar::keep_on(Point::new(p.x - grab.x, p.y - grab.y), m.rect, m.scale);
                if self.bar_at == Some(at) {
                    return Effect::None;
                }
                self.bar_at = Some(at);
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
            Drag::ReshapeItem { index, grip, offset, changed, .. } => {
                let (i, grip) = (*index, *grip);
                let next = self.items[i].reshaped(grip, Point::new(p.x + offset.x, p.y + offset.y));
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
        let held = self.pressed.take();
        match std::mem::replace(&mut self.drag, Drag::None) {
            Drag::None => {
                return match held {
                    // Cancel and Done act here, if the button comes up on
                    // the cell it went down on; let go elsewhere, it was
                    // not meant.
                    Some(b @ (Button::Cancel | Button::Done | Button::Save)) if self.layout().and_then(|l| l.button_at(p)) == Some(b) => {
                        match b {
                            Button::Cancel => Effect::Cancel,
                            Button::Save => Effect::Save,
                            _ => Effect::Finish,
                        }
                    }
                    // The cell is no longer held: that is something to show.
                    Some(_) => Effect::Repaint,
                    None => Effect::None,
                };
            }
            Drag::PickRegion { .. } => {
                self.bar_at = None;
                self.selection = match self.forming.take() {
                    Some((rect, monitor)) => Some(Selection { rect, monitor, window: None }),
                    // A click: the window under it, as it was frozen. Asked
                    // of the click's own position, not taken from `hover`,
                    // which is only as fresh as the last mouse move.
                    None => self.window_at(p),
                };
                self.hover = None;
            }
            Drag::ResizeRegion(_) | Drag::MoveRegion { .. } | Drag::MoveBar { .. } => {}
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
            // While typing, the second of two quick clicks is a click: two
            // swatches tried one after the other must not end the text.
            return self.pointer_down(p, mods, m);
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
                        closing: false,
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

    /// Begin closing the text box. `true` when there is a box and this is
    /// the call that closes it: the caller then reads the native control,
    /// destroys it and calls [`Self::end_text`] with what it read. `false`
    /// when there is no box **or it is already being closed** -- the caller
    /// does nothing at all.
    ///
    /// **Closing is a state because closing is re-entered.** Destroying the
    /// native control makes it lose the keyboard, and losing the keyboard is
    /// one of the things that closes the box; so the host's close routine is
    /// called a second time from inside the first, before the first has
    /// handed over the text. That second call once ended the box with an
    /// empty string, and every text and every number's sentence was thrown
    /// away with nothing logged (task 1090). No test here saw it: the
    /// re-entry is made by the window system, and these tests drove `Editor`
    /// the way a well-behaved host would. Now the order is this type's to
    /// keep, and a test below re-enters the way the window system does.
    pub fn close_text(&mut self) -> bool {
        match &mut self.text {
            Some(t) if !t.closing => {
                t.closing = true;
                true
            }
            _ => false,
        }
    }

    /// The text box closed with `text` in it. Only after [`Self::close_text`]
    /// said `true`; a call that did not begin the close is ignored, and the
    /// box stays open -- a host that skips the first step gets a box that
    /// will not close, which is seen, rather than text that is quietly lost.
    pub fn end_text(&mut self, text: &str, m: &dyn Measure) -> Effect {
        if !self.text.as_ref().is_some_and(|t| t.closing) {
            return Effect::None;
        }
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
                    self.items.push(Item { shape: Shape::Text { at: t.at, text, size }, colour: t.colour, level: t.level, rgb: None });
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
            self.bar_at = None;
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
            Key::Save => Effect::Save,
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
            Key::CopyColour => if self.magnifier().is_some() { Effect::CopyColour } else { Effect::None },
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

    /// A `Measure` that refuses what the host's cannot do (task 1199): the
    /// host hands the text to `DrawTextW` as a counted slice, and for an
    /// empty one that is a dangling pointer and a count of 0, which `USER32`
    /// on Windows 11 build 26200 reads through -- an access violation on
    /// the first click of the text tool.
    struct NotEmpty;
    impl Measure for NotEmpty {
        fn text(&self, text: &str, font_px: i32) -> (i32, i32) {
            assert!(!text.is_empty(), "the host's measure was asked for an empty text");
            Fake.text(text, font_px)
        }
    }

    /// `n` empty lines.
    fn lines_of(n: usize) -> String {
        "\n".repeat(n - 1)
    }

    const MON: Rect = Rect::new(0, 0, 2560, 1440);
    /// A window to select, and the desktop behind it.
    const WIN: Rect = Rect::new(400, 200, 900, 500);

    fn fresh() -> Editor {
        let monitors = vec![Monitor { rect: MON, scale: 1.0 }];
        let windows = vec![Window { id: 7, rect: WIN }, Window { id: 1, rect: MON }];
        Editor::new(monitors, windows, Prefs::default())
    }

    /// An editor with `WIN` selected.
    fn selected() -> Editor {
        let mut e = fresh();
        click(&mut e, P(500, 300));
        assert_eq!(e.selection().map(|s| s.rect), Some(WIN));
        e
    }

    /// Down and up at `p`. What the click did: Cancel and Done act when
    /// the button comes up, everything else when it goes down.
    fn click(e: &mut Editor, p: Point) -> Effect {
        let down = e.pointer_down(p, NONE, &Fake);
        match e.pointer_up(p) {
            up @ (Effect::Cancel | Effect::Finish) => up,
            _ => down,
        }
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
        host_commit(e, s, true);
    }

    /// **What the host's `commit_edit` does, step for step**, including the
    /// part the window system does to it: destroying the native box makes it
    /// lose the keyboard, and losing the keyboard calls `commit_edit` again
    /// before the first call has handed over the text. `reenter` is that
    /// second call. Keep this the same shape as `shot.rs::commit_edit`.
    fn host_commit(e: &mut Editor, typed: &str, reenter: bool) {
        if !e.close_text() {
            return;
        }
        // The host has read `typed` out of the control by now. Then:
        // DestroyWindow -> WM_KILLFOCUS -> commit_edit, which finds no native
        // control any more and has nothing to read.
        if reenter {
            host_commit(e, "", false);
        }
        e.end_text(typed, &Fake);
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
    fn a_session_opens_with_nothing_selected_and_the_next_click_selects_the_window_under_it() {
        let monitors = vec![Monitor { rect: MON, scale: 1.0 }];
        let windows = vec![Window { id: 7, rect: WIN }];
        let mut e = Editor::new(monitors, windows, Prefs::default());
        assert!(e.selection().is_none(), "however it was triggered");
        // The click after a mouse trigger: the trigger's modifiers are
        // still held, and it selects the window all the same.
        e.pointer_move(P(500, 300), crate::dclick::Mods::CTRL_SHIFT);
        assert_eq!(e.hover().map(|h| h.1), Some(WIN), "the clear one, not yet selected");
        assert!(e.selection().is_none());
        e.pointer_down(P(500, 300), crate::dclick::Mods::CTRL_SHIFT, &Fake);
        e.pointer_up(P(500, 300));
        assert_eq!(e.selection().map(|s| s.window), Some(Some(7)));
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
        assert_eq!(e.selected(), Some(0), "its inside holds it while it is selected (#1198)");
        assert_eq!(e.items().len(), 2, "and a click there draws nothing");
        click(&mut e, P(650, 450));
        assert_eq!(e.selected(), None, "empty space lets go of it");
        click(&mut e, P(550, 340));
        assert_eq!(e.selected(), None, "the inside of one that is not selected is not it");
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
        // An annotation an agent drew in a colour of its own (`rgb`) takes
        // the palette colour chosen for it, even the one its index already
        // says: the custom colour is what goes.
        e.items[0].rgb = Some((1, 2, 3));
        assert_eq!(press(&mut e, Button::Colour(8)), Effect::Repaint);
        assert_eq!((e.items()[0].colour, e.items()[0].rgb), (8, None));
        // And now it is that colour already: pressing it again is no step
        // to undo -- though the cell is still drawn held, which is a repaint.
        let steps = e.undo.len();
        assert_eq!(press(&mut e, Button::Colour(8)), Effect::Repaint);
        assert_eq!(e.undo.len(), steps);
    }

    #[test]
    fn a_cell_is_held_from_the_press_to_the_release_and_done_and_cancel_act_on_the_release() {
        let mut e = selected();
        let at = |e: &Editor, b: Button| {
            let r = e.layout().unwrap().rect_of(b).unwrap();
            P(r.x + 2, r.y + 2)
        };
        let state = |e: &Editor, b: Button| e.cells().into_iter().find(|c| c.button == b).unwrap().state;
        // A tool: chosen on the way down, drawn held until the button is up.
        let rect = Button::Tool(Tool::Rect);
        assert_eq!(e.pointer_down(at(&e, rect), NONE, &Fake), Effect::Repaint);
        assert_eq!((e.tool(), state(&e, rect)), (Tool::Rect, chrome::State::Down));
        assert_eq!(e.pointer_up(at(&e, rect)), Effect::Repaint, "no longer held: that is shown");
        assert_eq!(state(&e, rect), chrome::State::Selected);
        assert_eq!(state(&e, Button::Tool(Tool::Select)), chrome::State::Normal, "the one before it is let go");
        // With the pointer still on it, it is chosen and under the pointer.
        e.pointer_move(at(&e, rect), NONE);
        assert_eq!(state(&e, rect), chrome::State::SelectedHover);
        e.pointer_move(at(&e, Button::Tool(Tool::Arrow)), NONE);
        assert_eq!((state(&e, rect), state(&e, Button::Tool(Tool::Arrow))), (chrome::State::Selected, chrome::State::Hover));

        // Undo with nothing to undo: off, under the pointer and under a press.
        e.pointer_move(at(&e, Button::Undo), NONE);
        assert_eq!(state(&e, Button::Undo), chrome::State::Off);
        assert_eq!(e.pointer_down(at(&e, Button::Undo), NONE, &Fake), Effect::None);
        assert_eq!(state(&e, Button::Undo), chrome::State::Off);
        e.pointer_up(at(&e, Button::Undo));

        // Done: held, and nothing happens until the button comes up on it.
        assert_eq!(e.pointer_down(at(&e, Button::Done), NONE, &Fake), Effect::Repaint);
        assert_eq!(state(&e, Button::Done), chrome::State::Down);
        // Let go somewhere else: it was not meant.
        assert_eq!(e.pointer_up(at(&e, Button::Cancel)), Effect::Repaint);
        assert_eq!(state(&e, Button::Done), chrome::State::Normal);
        e.pointer_down(at(&e, Button::Done), NONE, &Fake);
        assert_eq!(e.pointer_up(at(&e, Button::Done)), Effect::Finish);
        e.pointer_down(at(&e, Button::Cancel), NONE, &Fake);
        assert_eq!(state(&e, Button::Cancel), chrome::State::Down);
        assert_eq!(e.pointer_up(at(&e, Button::Cancel)), Effect::Cancel);

        // A long screenshot: its button is the chosen one, the three that
        // mean something can be pressed, the rest are off.
        let mut e = selected();
        press(&mut e, Button::Long);
        assert!(e.is_long());
        e.pointer_move(P(5, 5), NONE);
        assert_eq!(state(&e, Button::Long), chrome::State::Selected);
        assert_eq!((state(&e, Button::Cancel), state(&e, Button::Done)), (chrome::State::Normal, chrome::State::Normal));
        assert_eq!((state(&e, rect), state(&e, Button::Tool(Tool::Select))), (chrome::State::Off, chrome::State::Off));
    }

    #[test]
    fn a_selected_box_has_a_frame_and_eight_grips_on_it_a_line_two_and_a_text_none() {
        let mut e = selected();
        letter(&mut e, 'R');
        drag(&mut e, P(500, 300), P(700, 420));
        letter(&mut e, 'L');
        drag(&mut e, P(800, 300), P(900, 380));
        letter(&mut e, 'T');
        click(&mut e, P(600, 500));
        type_text(&mut e, "abc");
        letter(&mut e, 'V');
        assert!(e.marked().is_none() && e.knobs(), "nothing selected: the selection's own knobs");

        // The rectangle: its ink is the rectangle and half its line; the
        // frame is 4 px out from that, and the grips are on the frame.
        click(&mut e, P(500, 350));
        let m = e.marked().unwrap();
        let ink = e.items()[0].bounds(1.0);
        let frame = chrome::frame_box(ink, 1.0);
        assert_eq!((m.ink, m.framed, m.grips.len()), (ink, true, 8));
        assert!(!e.knobs(), "never both kinds of handle at once");
        for (at, how) in &m.grips {
            assert_eq!(*how, chrome::Grip::Normal);
            assert!(at.x == frame.x || at.x == frame.right() || at.x == frame.x + frame.w / 2, "{at:?}");
        }
        // The pointer over the frame's corner: that grip is hot, and the
        // pointer is the diagonal one.
        let corner = P(frame.right(), frame.bottom());
        assert_eq!(e.pointer_move(corner, NONE), Effect::Repaint);
        assert_eq!(e.marked().unwrap().grips.iter().filter(|g| g.1 == chrome::Grip::Hot).count(), 1);
        assert_eq!(e.cursor(corner, NONE), Cursor::Diagonal);
        assert_eq!(e.cursor(P(frame.right(), frame.y), NONE), Cursor::AntiDiagonal);
        assert_eq!(e.cursor(P(frame.x + frame.w / 2, frame.y), NONE), Cursor::UpDown);
        assert_eq!(e.cursor(P(frame.x, frame.y + frame.h / 2), NONE), Cursor::LeftRight);
        assert_eq!(e.cursor(P(500, 350), NONE), Cursor::Move, "on its own line");
        assert_eq!(e.cursor(P(850, 340), NONE), Cursor::Arrow, "on another annotation");
        assert_eq!(e.cursor(P(1000, 600), NONE), Cursor::Tool);
        // Dragged from the grip -- which is 5 px outside the corner -- the
        // corner moves by as much as the pointer does, and does not jump
        // to it.
        let before = rect_of(&e, 0);
        e.pointer_down(corner, NONE, &Fake);
        assert_eq!(e.marked().unwrap().grips.iter().filter(|g| g.1 == chrome::Grip::Held).count(), 1);
        assert_eq!(e.reshape_tag().as_deref(), Some("200 × 120"));
        e.pointer_move(P(corner.x + 30, corner.y + 10), NONE);
        assert_eq!(rect_of(&e, 0), Rect::new(before.x, before.y, before.w + 30, before.h + 10));
        assert_eq!(e.reshape_tag().as_deref(), Some("230 × 130"));
        e.pointer_up(P(corner.x + 30, corner.y + 10));
        assert!(e.reshape_tag().is_none());

        // The line: no frame, a grip on each end, a cross over them.
        click(&mut e, P(850, 340));
        let m = e.marked().unwrap();
        assert_eq!((m.framed, m.grips.iter().map(|g| g.0).collect::<Vec<_>>()), (false, vec![P(800, 300), P(900, 380)]));
        assert_eq!(e.cursor(P(900, 380), NONE), Cursor::Tool);
        e.pointer_down(P(900, 380), NONE, &Fake);
        e.pointer_move(P(900, 300), NONE);
        assert_eq!(e.reshape_tag().as_deref(), Some("0°"));
        e.pointer_move(P(800, 200), NONE);
        assert_eq!(e.reshape_tag().as_deref(), Some("90°"));
        e.pointer_up(P(800, 200));

        // The text: a frame and no grips -- it can only be moved -- and
        // while it is being moved the frame goes with it.
        click(&mut e, P(605, 505));
        let m = e.marked().unwrap();
        assert_eq!((m.framed, m.grips.len()), (true, 0));
        e.pointer_down(P(605, 505), NONE, &Fake);
        e.pointer_move(P(625, 515), NONE);
        assert_eq!(e.marked().unwrap().ink, Rect::new(m.ink.x + 20, m.ink.y + 10, m.ink.w, m.ink.h));
        e.pointer_up(P(625, 515));
        // A box being moved puts its grips away until it is let go.
        click(&mut e, P(500, 350));
        e.pointer_down(P(500, 350), NONE, &Fake);
        e.pointer_move(P(510, 350), NONE);
        assert_eq!(e.marked().unwrap().grips.len(), 0);
        e.pointer_up(P(510, 350));
        assert_eq!(e.marked().unwrap().grips.len(), 8);
    }

    #[test]
    fn what_is_clear_is_the_selection_or_the_window_under_the_pointer() {
        let monitors = vec![Monitor { rect: MON, scale: 1.0 }, Monitor { rect: Rect::new(2560, 0, 1920, 1080), scale: 1.0 }];
        let windows = vec![Window { id: 7, rect: WIN }];
        let mut e = Editor::new(monitors, windows, Prefs::default());
        // Nobody has said where the pointer is: glass everywhere.
        assert_eq!((e.hole(0), e.hole(1)), (None, None));
        e.pointer_move(P(500, 300), NONE);
        assert_eq!((e.hole(0), e.hole(1)), (Some(WIN), None));
        // Off the window, on the desktop: the whole of that monitor.
        e.pointer_move(P(50, 50), NONE);
        assert_eq!((e.hole(0), e.hole(1)), (Some(MON), None));
        e.pointer_move(P(3000, 300), NONE);
        assert_eq!((e.hole(0), e.hole(1)), (None, Some(Rect::new(2560, 0, 1920, 1080))));
        // A selection being dragged out, then made: the hole, and the
        // other monitor is glass wherever the pointer goes.
        e.pointer_down(P(100, 100), NONE, &Fake);
        e.pointer_move(P(300, 250), NONE);
        assert_eq!(e.hole(0), Some(Rect::new(100, 100, 200, 150)));
        e.pointer_up(P(300, 250));
        e.pointer_move(P(3000, 300), NONE);
        assert_eq!((e.hole(0), e.hole(1)), (Some(Rect::new(100, 100, 200, 150)), None));
        assert_eq!(e.hole(9), None);
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
    fn undo_and_redo_let_go_of_the_selected_annotation_and_undo_each_other() {
        let mut e = with_two_rects();
        letter(&mut e, 'V');
        click(&mut e, P(500, 340));
        key(&mut e, overlay::VK_RIGHT);
        assert_eq!(e.selected(), Some(0));
        assert_eq!(e.key(overlay::VK_Z, CTRL, &Fake).1, Effect::Repaint);
        assert_eq!(e.selected(), None, "what was selected may not be there any more");
        assert_eq!(rect_of(&e, 0), Rect::new(500, 300, 100, 80));
        click(&mut e, P(700, 340));
        assert_eq!(e.selected(), Some(1));
        assert_eq!(e.key(overlay::VK_Z, Mods::CTRL_SHIFT, &Fake).1, Effect::Repaint);
        assert_eq!(e.selected(), None);
        assert_eq!(rect_of(&e, 0), Rect::new(501, 300, 100, 80));
        // What was redone can be undone again.
        assert_eq!(e.key(overlay::VK_Z, CTRL, &Fake).1, Effect::Repaint);
        assert_eq!(rect_of(&e, 0), Rect::new(500, 300, 100, 80));
        assert_eq!(e.items().len(), 2, "one step back from the redone nudge, not two");
        assert!(e.can_redo());
    }

    #[test]
    fn drawing_lets_go_of_the_selected_annotation() {
        let mut e = with_two_rects();
        let ctrl_click = |e: &mut Editor, p: Point| {
            let down = e.pointer_down(p, CTRL, &Fake);
            e.pointer_up(p);
            down
        };
        ctrl_click(&mut e, P(500, 340));
        assert_eq!(e.selected(), Some(0));
        drag(&mut e, P(900, 300), P(950, 350));
        assert_eq!(e.items().len(), 3);
        assert_eq!(e.selected(), None);
        // A click outside the selection draws nothing, but it lets go too,
        // and says so: the grips have to leave the screen.
        ctrl_click(&mut e, P(500, 340));
        assert_eq!(e.selected(), Some(0));
        assert_eq!(click(&mut e, P(100, 100)), Effect::Repaint);
        assert_eq!(e.selected(), None);
        assert_eq!(click(&mut e, P(100, 100)), Effect::None, "with nothing selected there is nothing to repaint");
        assert_eq!(e.items().len(), 3);
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
    fn a_text_started_on_the_selections_last_rows_is_pulled_up_and_its_box_stays_inside() {
        // WIN is y 200..700 and x 400..1300; `Fake`'s line is the font's
        // height, 18 px at the default size and 44 at the largest.
        let mut e = selected();
        letter(&mut e, 'T');
        assert_eq!(click(&mut e, P(500, 699)), Effect::OpenText);
        assert_eq!(e.text_box().map(|t| t.at), Some(P(500, 682)), "one line above the bottom edge");
        assert_eq!(e.text_rect(&lines_of(1), &Fake).map(|r| (r.x, r.y, r.h)), Some((500, 682, 18)));
        // There is no room under it: more lines scroll, the box does not grow.
        assert_eq!(e.text_rect(&lines_of(5), &Fake).map(|r| (r.x, r.y, r.h)), Some((500, 682, 18)));
        // A bigger size is a taller line, and the text moves up to hold it.
        assert_eq!(press(&mut e, Button::Level(4)), Effect::RestyleText);
        assert_eq!(e.text_box().map(|t| (t.at, t.level)), Some((P(500, 656), 4)));
        let b = e.text_rect(&lines_of(1), &Fake).unwrap();
        assert_eq!((b.x, b.y, b.h), (500, 656, 44));
        for r in e.text_keep_clear() {
            assert_eq!(b.intersect(r), None, "the toolbar is under the selection, the box is in it");
        }
        // What is kept is where it was typed.
        type_text(&mut e, "low");
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(500, 656), text: "low".into(), size: (30, 44) });
    }

    #[test]
    fn the_box_is_as_tall_as_its_lines_until_the_selections_bottom_edge() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        press(&mut e, Button::Level(4));
        assert_eq!(e.text_box().map(|t| t.at), Some(P(500, 300)), "there was room: it did not move");
        assert_eq!(e.text_rect(&lines_of(1), &Fake).map(|r| (r.x, r.y, r.h)), Some((500, 300, 44)));
        assert_eq!(e.text_rect(&lines_of(3), &Fake).map(|r| (r.x, r.y, r.h)), Some((500, 300, 132)));
        // 400 px to the bottom edge is nine lines of 44 and a bit: nine.
        assert_eq!(e.text_rect(&lines_of(99), &Fake).map(|r| (r.x, r.y, r.h)), Some((500, 300, 396)));
        assert_eq!(e.text_rect(&lines_of(1), &Fake).map(|r| r.h), Some(e.text_line(4, &Fake)));
    }

    #[test]
    fn a_text_edited_again_stays_where_it_is_whatever_its_size_becomes() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 690));
        assert_eq!(e.text_box().map(|t| t.at), Some(P(500, 682)));
        type_text(&mut e, "first");
        letter(&mut e, 'V');
        assert_eq!(e.double_click(P(510, 688), NONE, &Fake), Effect::OpenText);
        press(&mut e, Button::Level(4));
        // Its place is the annotation's, which other things were drawn
        // around: one line, even though that line now ends below the edge.
        assert_eq!(e.text_box().map(|t| (t.at, t.editing)), Some((P(500, 682), Some(0))));
        assert_eq!(e.text_rect(&lines_of(3), &Fake).map(|r| (r.x, r.y, r.h)), Some((500, 682, 44)));
    }

    #[test]
    fn a_click_outside_the_box_commits_and_does_nothing_else() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        assert_eq!(e.pointer_down(P(800, 500), NONE, &Fake), Effect::CommitText);
        assert!(e.text_box().is_some(), "the host reads the box and then calls end_text");
        host_commit(&mut e, "kept", true);
        assert_eq!(e.items().len(), 1);
        assert!(e.text_box().is_none(), "that click did not open another box");
    }

    #[test]
    fn closing_the_box_is_re_entered_and_the_text_survives_it() {
        // The defect of task 1090, as the window system produces it.
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        host_commit(&mut e, "abc", true);
        assert_eq!(e.items().len(), 1, "the text that was typed is an annotation");
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(500, 300), text: "abc".into(), size: (30, 18) });
        assert!(e.text_box().is_none());
        // And a number's sentence, which went the same way.
        letter(&mut e, 'N');
        click(&mut e, P(600, 300));
        host_commit(&mut e, "this one", true);
        assert_eq!(e.items()[1].shape, Shape::Number { n: 1, at: P(600, 300), text: "this one".into(), size: (80, 18) });
    }

    #[test]
    fn only_the_call_that_began_the_close_may_end_it() {
        let mut e = selected();
        assert!(!e.close_text(), "no box, nothing to close");
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        // Ending without beginning is ignored, and the box stays.
        assert_eq!(e.end_text("", &Fake), Effect::None);
        assert!(e.text_box().is_some());
        assert!(e.close_text());
        assert!(!e.close_text(), "already closing: a second caller does nothing");
        assert!(!e.close_text());
        assert_eq!(e.end_text("abc", &Fake), Effect::Repaint);
        assert_eq!(e.items().len(), 1);
        assert!(!e.close_text(), "and it is closed");
        assert_eq!(e.end_text("again", &Fake), Effect::None);
        assert_eq!(e.items().len(), 1);
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
    fn two_quick_presses_on_the_row_while_typing_are_two_presses_and_the_text_stays_open() {
        let mut e = selected();
        letter(&mut e, 'T');
        click(&mut e, P(500, 300));
        let swatch = e.layout().unwrap().rect_of(Button::Colour(5)).unwrap();
        let step = e.layout().unwrap().rect_of(Button::Level(3)).unwrap();
        // The host gets the second of two quick presses as a double click.
        assert_eq!(e.pointer_down(P(swatch.x + 1, swatch.y + 1), NONE, &Fake), Effect::RestyleText);
        assert_eq!(e.double_click(P(swatch.x + 1, swatch.y + 1), NONE, &Fake), Effect::RestyleText);
        assert_eq!(e.double_click(P(step.x + 1, step.y + 1), NONE, &Fake), Effect::RestyleText);
        assert_eq!(e.text_box().map(|t| (t.colour, t.level)), Some((5, 3)));
        // Anywhere else it is still a click outside, which ends the text.
        assert_eq!(e.double_click(P(800, 500), NONE, &Fake), Effect::CommitText);
        type_text(&mut e, "still here");
        assert_eq!((e.items()[0].colour, e.items()[0].level), (5, 3));
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
        host_commit(&mut e, "note", true);
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
        // (It takes hold of the toolbar, which moves if the pointer does.)
        assert_eq!(click(&mut e, P(r.right() + 1, r.y + 3)), Effect::Capture);
        drag(&mut e, P(r.right() + 1, r.y + 3), P(r.right() + 60, r.y + 60));
        assert!(e.items().is_empty());
        assert_eq!(press(&mut e, Button::Done), Effect::Finish);
        assert_eq!(press(&mut e, Button::Cancel), Effect::Cancel);
        assert_eq!(press(&mut e, Button::Long), Effect::Long);
    }

    /// With the whole display selected the toolbar is inside the selection,
    /// where a click that missed its buttons would otherwise be a click on
    /// the picture. (With the toolbar outside the selection, as in the test
    /// above, nothing is drawn there whether the toolbar swallows the click
    /// or not -- that one alone does not show that it does.)
    #[test]
    fn a_toolbar_inside_the_selection_still_takes_its_clicks() {
        let mut e = fresh();
        click(&mut e, P(2000, 1000));
        assert_eq!(e.selection().map(|s| s.rect), Some(MON));
        let pen = e.layout().unwrap().rect_of(Button::Tool(Tool::Pen)).unwrap();
        assert!(MON.contains(P(pen.x, pen.y)), "the toolbar is inside the selection");
        // A double click on a button presses it; it does not finish.
        assert_eq!(e.double_click(P(pen.x + 2, pen.y + 2), NONE, &Fake), Effect::Repaint);
        assert_eq!(e.tool(), Tool::Pen);
        letter(&mut e, 'V');
        let gap = P(pen.right() + 1, pen.y + 3);
        assert_eq!(e.layout().unwrap().button_at(gap), None);
        assert_eq!(e.double_click(gap, NONE, &Fake), Effect::Capture, "nor does one between two buttons: it holds the toolbar");
        e.pointer_up(gap);
        // Between two buttons nothing is drawn and nothing is moved.
        letter(&mut e, 'R');
        assert_eq!(e.pointer_down(gap, NONE, &Fake), Effect::Capture);
        e.pointer_up(gap);
        drag(&mut e, gap, P(pen.right() + 60, pen.y - 200));
        assert!(e.items().is_empty());
        assert_eq!(e.selection().map(|s| s.rect), Some(MON));
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
        // And that is the order they leave in for the picture -- here the
        // mosaic was made last, so the order made would put it over the
        // boxes; the file keeps the order they were made in.
        let x = e.export().unwrap();
        let shapes: Vec<Shape> = x.on_screen.iter().map(|i| i.shape.clone()).collect();
        assert_eq!(
            shapes,
            [Shape::Mosaic(Rect::new(900, 300, 100, 100)), Shape::Rect(Rect::new(500, 300, 100, 80)), Shape::Rect(Rect::new(700, 300, 100, 80))]
        );
        let on_image: Vec<Shape> = x.on_image.iter().map(|i| i.shape.clone()).collect();
        assert_eq!(
            on_image,
            [Shape::Rect(Rect::new(100, 100, 100, 80)), Shape::Rect(Rect::new(300, 100, 100, 80)), Shape::Mosaic(Rect::new(500, 100, 100, 100))]
        );
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
        let mut e = Editor::new(monitors, windows, Prefs::default());
        click(&mut e, P(3100, 300));
        assert_eq!(e.scale(), 2.0);
        assert_eq!(e.layout().unwrap().rect_of(Button::Done).unwrap().w, 56);
        letter(&mut e, 'T');
        click(&mut e, P(3100, 300));
        type_text(&mut e, "abc");
        assert_eq!(e.items()[0].shape, Shape::Text { at: P(3100, 300), text: "abc".into(), size: (30, 36) }, "18 pt at 200%");
    }

    /// #1197 item 6: the window under the pointer is the clear one from the
    /// first frame. The host tells the editor where the pointer is when the
    /// session opens, and nothing has to move after that.
    #[test]
    fn the_window_under_the_pointer_is_known_before_the_mouse_moves() {
        let mut e = fresh();
        assert_eq!(e.hover(), None, "nothing is told yet");
        e.pointer_move(P(500, 300), NONE);
        assert_eq!(e.hover(), Some((0, WIN)));
        assert_eq!(e.hole(0), Some(WIN), "the hole is the window, in the first frame");
    }

    /// #1197 item 8: a size can be read at every moment of dragging out,
    /// resizing and moving: the rectangle the host measures changes with
    /// each move.
    #[test]
    fn the_rectangle_to_measure_follows_every_move_of_a_drag() {
        let mut e = fresh();
        e.pointer_down(P(100, 100), NONE, &Fake);
        e.pointer_move(P(200, 180), NONE);
        assert_eq!(e.forming().map(|f| (f.0.w, f.0.h)), Some((100, 80)));
        e.pointer_move(P(300, 380), NONE);
        assert_eq!(e.forming().map(|f| (f.0.w, f.0.h)), Some((200, 280)));
        e.pointer_up(P(300, 380));
        let sel = e.selection().unwrap().rect;
        e.pointer_down(P(sel.x + sel.w / 2, sel.y + sel.h / 2), NONE, &Fake);
        e.pointer_move(P(sel.x + sel.w / 2 + 40, sel.y + sel.h / 2), NONE);
        e.pointer_move(P(sel.x + sel.w / 2 + 80, sel.y + sel.h / 2), NONE);
        assert_eq!(e.selection().map(|s| s.rect.x), Some(sel.x + 80));
    }

    /// #1197 item 4, in the editor: empty, the box is the least wide; it
    /// widens with the longest line and stops at the selection's edge.
    #[test]
    fn the_text_box_is_as_wide_as_its_longest_line_up_to_the_selection() {
        let mut e = selected();
        e.pointer_down(P(520, 320), NONE, &Fake);
        e.key(b'T' as u16, NONE, &Fake);
        click(&mut e, P(520, 320));
        let w = |e: &Editor, s: &str| e.text_rect(s, &Fake).unwrap().w;
        let (empty, short, longer) = (w(&e, ""), w(&e, "abcd"), w(&e, "abcdefgh"));
        assert!(empty < 800 && empty <= short && short < longer, "{empty} {short} {longer}");
        assert_eq!(w(&e, &"x".repeat(500)), WIN.right() - e.text_box().unwrap().at.x, "to the edge, no further");
        assert_eq!(w(&e, "ab\ncdefgh\nij"), w(&e, "cdefgh"), "the longest line counts, not the total");
    }

    /// #1197 items 2 and 3: while a number's sentence is typed, the circle
    /// is drawn in the colour and size on the property row, and the box is
    /// level with it -- empty or not.
    #[test]
    fn a_number_in_edit_wears_the_chosen_colour_and_size_and_its_box_is_level() {
        let mut e = selected();
        letter(&mut e, 'N');
        click(&mut e, P(500, 300));
        let centre = |e: &Editor, text: &str| {
            let b = e.text_rect(text, &Fake).unwrap();
            (b.y + b.h / 2, b.h)
        };
        assert_eq!(centre(&e, "").0, 300, "empty: level with the circle");
        assert_eq!(centre(&e, "x").0, 300, "typed: the same");
        let (_, was) = e.number_in_edit().map(|(i, it)| (i, (it.colour, it.level))).unwrap();
        assert_ne!(was, (3, 4));
        press(&mut e, Button::Colour(3));
        press(&mut e, Button::Level(4));
        let (i, shown) = e.number_in_edit().unwrap();
        assert_eq!((i, shown.colour, shown.level), (0, 3, 4), "what is drawn while typing");
        assert_eq!((e.items()[0].colour, e.items()[0].level), was, "the annotation itself changes when it is closed");
        let b = e.text_rect("", &Fake).unwrap();
        assert_eq!(b.y + b.h / 2, 300, "a bigger size keeps the box level with its circle");
        assert!(b.h > centre(&e, "").1 - 1);
        type_text(&mut e, "ok");
        assert_eq!((e.items()[0].colour, e.items()[0].level), (3, 4));
        assert!(e.number_in_edit().is_none());
    }

    /// #1199: opening the text box measures what is in it, and an empty box
    /// -- the first thing the text tool opens -- and empty lines in a box
    /// are measured as nothing, never handed to the host's measure.
    #[test]
    fn an_empty_text_box_is_placed_without_measuring_an_empty_text() {
        let mut e = selected();
        press(&mut e, Button::Tool(Tool::Text));
        // The click itself, with the strict measure: the editor is given
        // the host's measure on every press.
        e.pointer_down(P(500, 300), NONE, &NotEmpty);
        e.pointer_up(P(500, 300));
        assert!(e.text_box().is_some(), "the click opens a box");
        for text in ["", "\n", "a\n\nb", "\r\n", "x\r\n"] {
            assert!(e.text_rect(text, &NotEmpty).is_some(), "{text:?}");
        }
        // The measure that refuses empty text is what is asserted on: with
        // the filter taken out of `text_rect` this test is red there.
        assert_eq!(e.text_rect("", &NotEmpty), e.text_rect("", &Fake));
    }

    /// #1197 item 5: the toolbar is held by its plate and dragged; it stays
    /// on the monitor, and stays where it was put while the selection moves
    /// -- until the next selection.
    #[test]
    fn the_toolbar_can_be_dragged_by_its_plate_and_stays_where_it_is_put() {
        let mut e = selected();
        let before = e.layout().unwrap();
        let gap = P(before.bar.x + 2, before.bar.y + 2);
        assert_eq!(before.button_at(gap), None, "the corner of the plate is no cell");
        assert_eq!(e.cursor(gap, NONE), Cursor::Move);
        let cell = before.rect_of(Button::Tool(Tool::Pen)).unwrap();
        assert_eq!(e.cursor(P(cell.x + 2, cell.y + 2), NONE), Cursor::Arrow);

        assert_eq!(e.pointer_down(gap, NONE, &Fake), Effect::Capture);
        e.pointer_move(P(gap.x + 100, gap.y - 150), NONE);
        e.pointer_up(P(gap.x + 100, gap.y - 150));
        let after = e.layout().unwrap();
        assert_eq!((after.bar.x, after.bar.y), (before.bar.x + 100, before.bar.y - 150));
        assert_eq!(after.buttons.len(), before.buttons.len());

        // Not off the screen, on any side.
        e.pointer_down(P(after.bar.x + 2, after.bar.y + 2), NONE, &Fake);
        e.pointer_move(P(-5000, -5000), NONE);
        e.pointer_up(P(-5000, -5000));
        let corner = e.layout().unwrap().bar;
        assert_eq!((corner.x, corner.y), (MON.x, MON.y));
        let g = P(corner.x + 2, corner.y + 2);
        e.pointer_down(g, NONE, &Fake);
        e.pointer_move(P(99999, 99999), NONE);
        e.pointer_up(P(99999, 99999));
        let far = e.layout().unwrap();
        assert!(far.plate().right() <= MON.right() && far.bar.y + toolbar::footprint(1.0).1 <= MON.bottom());

        // It does not follow the selection any more.
        let at = e.layout().unwrap().bar;
        drag(&mut e, P(850, 300), P(800, 300));
        assert_eq!(e.layout().unwrap().bar, at, "same place after the selection moved");
    }

    /// And it goes back beside the selection for the next one.
    #[test]
    fn the_toolbar_is_beside_the_selection_again_for_the_next_one() {
        let mut e = selected();
        let beside = e.layout().unwrap().bar;
        let g = P(beside.x + 2, beside.y + 2);
        e.pointer_down(g, NONE, &Fake);
        e.pointer_move(P(g.x + 300, g.y), NONE);
        e.pointer_up(P(g.x + 300, g.y));
        assert_ne!(e.layout().unwrap().bar, beside);
        e.right_click();
        assert!(e.selection().is_none());
        click(&mut e, P(500, 300));
        assert_eq!(e.layout().unwrap().bar, beside);
    }

    /// #1197 item 7: the magnifier is there while hovering without a
    /// selection and for the whole of dragging one out, by a handle or by
    /// its middle; and not once annotating begins.
    #[test]
    fn the_magnifier_follows_the_pointer_until_the_selection_is_settled() {
        let mut e = fresh();
        assert_eq!(e.magnifier(), None, "the host has not told where the pointer is");
        assert_eq!(e.pointer_move(P(100, 100), NONE), Effect::Repaint, "hovering repaints every move");
        assert_eq!(e.pointer_move(P(101, 100), NONE), Effect::Repaint);
        assert_eq!(e.magnifier(), Some(P(101, 100)));
        e.pointer_down(P(100, 100), NONE, &Fake);
        assert_eq!(e.magnifier(), Some(P(100, 100)), "pressed");
        e.pointer_move(P(300, 300), NONE);
        assert_eq!(e.magnifier(), Some(P(300, 300)), "dragging out");
        e.pointer_up(P(300, 300));
        assert!(e.selection().is_some());
        assert_eq!(e.magnifier(), None, "settled");
        // By a handle and by the middle.
        let sel = e.selection().unwrap().rect;
        e.pointer_down(P(sel.right(), sel.bottom()), NONE, &Fake);
        e.pointer_move(P(sel.right() + 20, sel.bottom() + 20), NONE);
        assert_eq!(e.magnifier(), Some(P(sel.right() + 20, sel.bottom() + 20)), "by a handle");
        e.pointer_up(P(sel.right() + 20, sel.bottom() + 20));
        assert_eq!(e.magnifier(), None);
        let sel = e.selection().unwrap().rect;
        e.pointer_down(P(sel.x + 40, sel.y + 40), NONE, &Fake);
        e.pointer_move(P(sel.x + 50, sel.y + 50), NONE);
        assert!(e.magnifier().is_some(), "by the middle");
        e.pointer_up(P(sel.x + 50, sel.y + 50));
        assert_eq!(e.magnifier(), None);
        // Annotating: a drawing tool's drag does not show it.
        letter(&mut e, 'R');
        let sel = e.selection().unwrap().rect;
        e.pointer_down(P(sel.x + 20, sel.y + 20), NONE, &Fake);
        e.pointer_move(P(sel.x + 60, sel.y + 60), NONE);
        assert_eq!(e.magnifier(), None);
    }

    /// Ctrl+C copies the colour only while the magnifier is shown.
    #[test]
    fn ctrl_c_copies_the_colour_only_while_the_magnifier_is_shown() {
        let mut e = fresh();
        e.pointer_move(P(100, 100), NONE);
        assert_eq!(e.key(overlay::VK_C, CTRL, &Fake), (Key::CopyColour, Effect::CopyColour));
        assert_eq!(e.key(overlay::VK_C, NONE, &Fake).1, Effect::None, "C alone is not a command");
        click(&mut e, P(500, 300));
        assert_eq!(e.key(overlay::VK_C, CTRL, &Fake), (Key::CopyColour, Effect::None), "settled: nothing to copy");
    }

    /// #1197 item 9: Save is Done and a copy; like Done it acts when the
    /// button comes up on it, works from Ctrl+S, and is there in a long one.
    #[test]
    fn save_acts_on_release_on_the_button_and_by_ctrl_s() {
        let mut e = selected();
        let r = e.layout().unwrap().rect_of(Button::Save).unwrap();
        let on = P(r.x + 2, r.y + 2);
        assert_eq!(e.pointer_down(on, NONE, &Fake), Effect::Repaint, "held, not yet acting");
        assert_eq!(e.pointer_up(on), Effect::Save);
        e.pointer_down(on, NONE, &Fake);
        assert_ne!(e.pointer_up(P(r.x + 200, r.y + 2)), Effect::Save, "let go elsewhere: not meant");
        assert_eq!(e.key(overlay::VK_S, CTRL, &Fake), (Key::Save, Effect::Save));
        assert_eq!(e.key(overlay::VK_S, NONE, &Fake).1, Effect::None);
        press(&mut e, Button::Long);
        assert_eq!(e.pointer_down(on, NONE, &Fake), Effect::Repaint);
        assert_eq!(e.pointer_up(on), Effect::Save, "also while frames are taken");
    }

    /// #1197 item 5, long: the toolbar can be held by its plate there too.
    #[test]
    fn the_toolbar_can_be_moved_in_a_long_screenshot_too() {
        let mut e = selected();
        press(&mut e, Button::Long);
        let bar = e.layout().unwrap().bar;
        let g = P(bar.x + 2, bar.y + 2);
        assert_eq!(e.pointer_down(g, NONE, &Fake), Effect::Capture);
        e.pointer_move(P(g.x - 50, g.y), NONE);
        e.pointer_up(P(g.x - 50, g.y));
        assert_eq!(e.layout().unwrap().bar.x, bar.x - 50);
    }

    /// #1198: inside a selected rectangle or ellipse -- not on its line -- the
    /// pointer is the mover's and a drag moves it; inside one that is not
    /// selected it is not, and a press there is the selection's own.
    #[test]
    fn inside_a_selected_hollow_shape_it_is_held_and_inside_an_unselected_one_it_is_not() {
        for tool in ['R', 'O'] {
            let mut e = selected();
            letter(&mut e, tool);
            drag(&mut e, P(500, 300), P(700, 450));
            assert_eq!(e.items().len(), 1);
            letter(&mut e, 'V');
            let inside = P(600, 375);
            // Not selected yet: the inside is the selection's, not the shape's.
            e.pointer_down(inside, NONE, &Fake);
            e.pointer_up(inside);
            assert_eq!(e.selected(), None, "{tool}: the inside of an unselected one selects nothing");
            // Selected by its line (the rectangle's top edge, the ellipse's left end).
            let on_line = if tool == 'R' { P(600, 300) } else { P(500, 375) };
            click(&mut e, on_line);
            assert_eq!(e.selected(), Some(0), "{tool}");
            assert_eq!(e.cursor(inside, NONE), Cursor::Move, "{tool}: inside, the mover's pointer");
            assert_eq!(e.cursor(P(10, 10), NONE) == Cursor::Move, false);
            let before = e.items()[0].clone();
            e.pointer_down(inside, NONE, &Fake);
            e.pointer_move(P(inside.x + 30, inside.y + 20), NONE);
            e.pointer_up(P(inside.x + 30, inside.y + 20));
            assert_eq!(e.items()[0], before.moved(30, 20), "{tool}: a drag from inside moves it");
            assert_eq!(e.selected(), Some(0));
        }
        // An ellipse's box corner is outside the ellipse: not held.
        let mut e = selected();
        letter(&mut e, 'O');
        drag(&mut e, P(500, 300), P(700, 450));
        letter(&mut e, 'V');
        click(&mut e, P(500, 375));
        assert_ne!(e.cursor(P(503, 303), NONE), Cursor::Move, "the corner of an ellipse's box is not inside it");
    }
}
