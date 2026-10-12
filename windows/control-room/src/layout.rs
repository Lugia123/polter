//! Where everything in the list panel is, in the panel's own units with the
//! origin at its top left. Sizes come from `look`; this adds only the
//! arithmetic, so that whatever draws places things and never measures.
//!
//! The units are the design's points. A host multiplies by its scale at
//! the last moment and nowhere else.

use crate::list::List;
use crate::look::{line, side, space};
use crate::snapshot::{Band, Lane};

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
    pub band_header: Rect,
    pub lanes: Vec<Rect>,
    pub axis: Rect,
}

impl ListLayout {
    pub fn new(list: &List, height: f64) -> ListLayout {
        Self::with_lanes(list, height, list.band.lanes.len())
    }

    /// The same, for a band with `lane_count` lanes.
    pub fn with_lanes(list: &List, height: f64, lane_count: usize) -> ListLayout {
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

        // The time band hangs from the bottom: its own padding, the axis,
        // one lane per group, and its header on top.
        let lane_h = side::TIME_LANE_LABELLED_HEIGHT;
        let axis_h = side::TIME_AXIS_HEIGHT;
        let band_x = pad + pad_x;
        let band_w = inner - 2.0 * pad_x;
        let axis_top = height - pad - side::TIME_BAND_PADDING_BOTTOM - axis_h;
        let axis = Rect { x: band_x, y: axis_top, w: band_w, h: axis_h };
        let lanes_top = axis_top - lane_count as f64 * lane_h;
        let lanes = (0..lane_count)
            .map(|n| Rect { x: band_x, y: lanes_top + n as f64 * lane_h, w: band_w, h: lane_h })
            .collect();
        let band_header = Rect { x: band_x, y: lanes_top - header_h, w: band_w, h: header_h };

        ListLayout { width, height, header, rows, separator, quiet_header, band_header, lanes, axis }
    }

    /// Where the selection chip rests for a row; none for a row not listed.
    pub fn chip(&self, id: Option<&str>) -> Option<Rect> {
        let id = id?;
        self.rows.iter().find(|(name, _)| name == id).map(|(_, r)| *r)
    }
}

/// How wide the part of a lane that draws time is, once the name at its
/// left end and the gap after it are taken off.
pub fn track_width(lane_width: f64) -> f64 {
    (lane_width - side::TIME_LANE_LABEL_WIDTH - side::ROW_ITEM_GAP).max(0.0)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Segment {
    pub x: f64,
    pub w: f64,
    pub ongoing: bool,
}

/// The pieces of one lane, as x and width inside a track `width` wide. A
/// span is clipped to the band, and one that ends before it starts or lies
/// wholly outside is dropped.
pub fn segments(lane: &Lane, band: &Band, width: f64) -> Vec<Segment> {
    let now = band.now_ms;
    if now <= band.start_ms || width <= 0.0 {
        return Vec::new();
    }
    let total = (now - band.start_ms) as f64;
    lane.spans
        .iter()
        .filter_map(|span| {
            let from = span.from_ms.max(band.start_ms);
            let to = (if span.ongoing { now } else { span.to_ms }).min(now);
            (to > from).then(|| Segment {
                x: (from - band.start_ms) as f64 / total * width,
                w: (to - from) as f64 / total * width,
                ongoing: span.ongoing,
            })
        })
        .collect()
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
