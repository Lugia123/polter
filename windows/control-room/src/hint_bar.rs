//! The line saying a project was made for a group (task 1714, design
//! `project-link-v2` A1): above the supervisor's pane in its tab, and above
//! its terminal in the control room's right-hand frame -- the same line in
//! both, so that Undo or ✕ in one takes it from both. Where it is and what
//! is pressed on it, in points from the line's own corner; the host
//! measures the Undo button's words and paints.
//!
//! Its size is the design's reading (`metrics.json`): one line 40 high, a
//! button 24 high centred in it, 12 in from each end, 8 between things,
//! the cross 16 square -- the products' `space::FRAME_TO_CONTENT`,
//! `pane::BAR_GAP` and `window_tab::CLOSE`.

use crate::layout::Rect;
use crate::look::{font, pane, radius, space, window_tab, Theme};
use crate::scene::{Align, Face, Item, Style};

/// How high the line is.
pub const HEIGHT: f64 = 40.0;
/// How high its Undo button is.
pub const BUTTON: f64 = 24.0;

/// What a point on the line is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    Undo,
    Close,
    /// On the line, on nothing that does anything.
    Line,
    Outside,
}

/// Where the parts of a line in `rect` are. `undo_w`: the Undo button's
/// width, its words measured by the host and padded; none on a line that
/// says what was undone, which has only its cross.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    pub rect: Rect,
    pub text: Rect,
    pub undo: Option<Rect>,
    pub close: Rect,
}

pub fn geometry(rect: Rect, undo_w: Option<f64>) -> Geometry {
    let c = window_tab::CLOSE;
    let close = Rect { x: rect.x + rect.w - space::FRAME_TO_CONTENT - c, y: rect.y + (rect.h - c) / 2.0, w: c, h: c };
    let undo = undo_w.map(|w| Rect { x: close.x - pane::BAR_GAP - w, y: rect.y + (rect.h - BUTTON) / 2.0, w, h: BUTTON });
    let right = undo.map_or(close.x, |u| u.x) - pane::BAR_GAP;
    let left = rect.x + space::FRAME_TO_CONTENT;
    let text = Rect { x: left, y: rect.y, w: (right - left).max(0.0), h: rect.h };
    Geometry { rect, text, undo, close }
}

/// What is under `at`.
pub fn hit(g: &Geometry, at: (f64, f64)) -> Hit {
    let inside = |r: &Rect| at.0 >= r.x && at.0 < r.x + r.w && at.1 >= r.y && at.1 < r.y + r.h;
    if !inside(&g.rect) {
        Hit::Outside
    } else if g.undo.as_ref().is_some_and(inside) {
        Hit::Undo
    } else if inside(&g.close) {
        Hit::Close
    } else {
        Hit::Line
    }
}

/// The line drawn: its ground, its words, the Undo button with its words.
/// The cross is the host's to draw at `close`, as every other close cross
/// it has (`strip::draw_cross`).
pub fn build(g: &Geometry, text: &str, undo: Option<&str>, theme: &Theme) -> Vec<Item> {
    let body = |color| Style { size: font::BODY, weight: font::WEIGHT_BODY, face: Face::Ui, color };
    let mut out = vec![
        Item::Fill { rect: g.rect, color: theme.surface_row },
        // The words after Undo say what was undone, in the second ink.
        Item::Text { rect: g.text, text: text.to_string(), style: body(if undo.is_some() { theme.text } else { theme.text_secondary }), align: Align::Left },
    ];
    if let (Some(r), Some(words)) = (g.undo, undo) {
        out.push(Item::Round { rect: r, radius: radius::ROW, color: theme.window_base, edge: Some(theme.line_faint) });
        out.push(Item::Text { rect: r, text: words.to_string(), style: body(theme.text), align: Align::Centre });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_parts_sit_where_the_design_measured_them() {
        let g = geometry(Rect { x: 100.0, y: 50.0, w: 600.0, h: HEIGHT }, Some(56.0));
        // ✕ 12 from the right end, centred.
        assert_eq!(g.close, Rect { x: 100.0 + 600.0 - 12.0 - 16.0, y: 50.0 + 12.0, w: 16.0, h: 16.0 });
        // Undo 8 before it, 24 high, centred.
        let u = g.undo.unwrap();
        assert_eq!((u.x + u.w, u.y, u.h), (g.close.x - 8.0, 58.0, 24.0));
        // The words from 12 in to 8 before Undo.
        assert_eq!((g.text.x, g.text.x + g.text.w), (112.0, u.x - 8.0));
    }

    #[test]
    fn undo_and_the_cross_are_told_apart_from_the_line() {
        let g = geometry(Rect { x: 0.0, y: 0.0, w: 400.0, h: HEIGHT }, Some(50.0));
        let u = g.undo.unwrap();
        assert_eq!(hit(&g, (u.x + 1.0, u.y + 1.0)), Hit::Undo);
        assert_eq!(hit(&g, (g.close.x + 8.0, g.close.y + 8.0)), Hit::Close);
        assert_eq!(hit(&g, (20.0, 20.0)), Hit::Line);
        assert_eq!(hit(&g, (20.0, HEIGHT + 1.0)), Hit::Outside);
        // Undone: no button, the words reach the cross.
        let done = geometry(Rect { x: 0.0, y: 0.0, w: 400.0, h: HEIGHT }, None);
        assert_eq!(done.undo, None);
        assert_eq!(done.text.x + done.text.w, done.close.x - 8.0);
        assert_eq!(hit(&done, (done.close.x - 20.0, 20.0)), Hit::Line);
    }
}
