//! Where everything in the list panel is, in the panel's own units with the
//! origin at its top left. Sizes come from `look`; this adds only the
//! arithmetic, so that whatever draws places things and never measures.
//!
//! The units are the design's points. A host multiplies by its scale at
//! the last moment and nowhere else.

use crate::list::List;
use crate::look::{line, side, space};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ListLayout {
    pub width: f64,
    pub height: f64,
    pub header: Rect,
    /// The waiting rows and then the quiet ones, by `Row::id`.
    pub rows: Vec<(String, Rect)>,
    pub separator: Rect,
    pub quiet_header: Rect,
}

impl ListLayout {
    pub fn new(list: &List, height: f64) -> ListLayout {
        let pad = space::SIDE_PANEL_PADDING;
        let width = side::WIDTH;
        let inner = width - 2.0 * pad;
        let pad_x = side::HEADER_PADDING_X;
        let header_h = side::HEADER_HEIGHT;

        let mut y = pad;
        let header = Rect { x: pad, y, w: inner, h: header_h };
        y += header_h;

        let mut rows = Vec::new();
        for row in &list.waiting {
            rows.push((row.id.clone(), Rect { x: pad, y, w: inner, h: side::ROW_HEIGHT }));
            y += side::ROW_HEIGHT + side::ROW_GAP;
        }

        y += side::SEPARATOR_SPACE_ABOVE;
        let separator = Rect { x: pad + pad_x, y, w: inner - 2.0 * pad_x, h: line::HAIRLINE };
        y += line::HAIRLINE + side::SEPARATOR_SPACE_BELOW;

        let quiet_header = Rect { x: pad, y, w: inner, h: header_h };
        y += header_h;
        for row in &list.quiet {
            rows.push((row.id.clone(), Rect { x: pad, y, w: inner, h: side::QUIET_ROW_HEIGHT }));
            y += side::QUIET_ROW_HEIGHT;
        }

        ListLayout { width, height, header, rows, separator, quiet_header }
    }

    /// The row under a point of the panel, by its group's name.
    pub fn row_at(&self, x: f64, y: f64) -> Option<&str> {
        self.rows
            .iter()
            .find(|(_, r)| x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
            .map(|(name, _)| name.as_str())
    }

    /// Where the selection chip rests for a row; none for a row not listed.
    pub fn chip(&self, id: Option<&str>) -> Option<Rect> {
        let id = id?;
        self.rows.iter().find(|(name, _)| name == id).map(|(_, r)| *r)
    }
}

/// The control room's two sides inside its tab, whose content area is
/// `width` by `height`: the list panel on the left, and what is left for the
/// selected group on the right.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Room {
    pub panel: Rect,
    pub right: Rect,
}

impl Room {
    pub fn new(width: f64, height: f64) -> Room {
        let edge = space::WINDOW_EDGE;
        let h = (height - 2.0 * edge).max(0.0);
        let panel = Rect { x: edge, y: edge, w: side::WIDTH, h };
        let x = panel.x + panel.w + space::BETWEEN_FRAMES;
        Room { panel, right: Rect { x, y: edge, w: (width - x - edge).max(0.0), h } }
    }
}

/// Where the chip is `t` seconds into a slide from one row to another: the
/// spring's progress between the two rectangles. It passes the far one a
/// little and comes back.
pub fn chip_between(from: Rect, to: Rect, t: f64) -> Rect {
    let p = spring::progress(t);
    let mix = |a: f64, b: f64| a + (b - a) * p;
    Rect { x: mix(from.x, to.x), y: mix(from.y, to.y), w: mix(from.w, to.w), h: mix(from.h, to.h) }
}

/// Whether a slide that began `t` seconds ago has come to rest: within a
/// hundredth of the way for good, which for this spring is after its second
/// period.
pub fn chip_settled(t: f64) -> bool {
    t >= 2.0 * crate::look::selection::SPRING_PERIOD
}

/// The chip's slide, as numbers: an under-damped spring from 0 to 1.
pub mod spring {
    use crate::look::selection;

    /// Progress at `t` seconds: 0 at the start, settling on 1.
    pub fn progress(t: f64) -> f64 {
        progress_with(t, selection::SPRING_PERIOD, selection::SPRING_DAMPING)
    }

    pub fn progress_with(t: f64, period: f64, damping: f64) -> f64 {
        if t <= 0.0 || period <= 0.0 {
            return 0.0;
        }
        let omega = 2.0 * std::f64::consts::PI / period;
        if damping >= 1.0 {
            // Critically damped: no overshoot.
            return 1.0 - (1.0 + omega * t) * (-omega * t).exp();
        }
        let wd = omega * (1.0 - damping * damping).sqrt();
        let decay = (-damping * omega * t).exp();
        1.0 - decay * ((wd * t).cos() + damping * omega / wd * (wd * t).sin())
    }

    /// How far past 1 it goes at its furthest, as a fraction.
    pub fn overshoot(damping: f64) -> f64 {
        if damping >= 1.0 {
            return 0.0;
        }
        (-damping * std::f64::consts::PI / (1.0 - damping * damping).sqrt()).exp()
    }
}
