//! Where the box somebody types a text into goes, and how big it is.
//!
//! Specification §9.3 for where it goes, §9.8 for what it looks like. **The
//! box has no paper**: the picture under it is seen through it, and all that
//! is drawn is a dashed frame, the words, the caret, what is selected and
//! what an input method is composing ([`view`], [`draw_frame`], [`halo`],
//! [`draw_caret`]). The host's native control is still there, to take the
//! keyboard and the input method and to keep the selection and the undo
//! stack, but it draws nothing: the overlay draws what it holds ([`Typed`]).
//!
//! It was once four lines tall whatever was in it and stopped only at the
//! bottom of the monitor, so at the largest size, opened low in the
//! selection, it lay over the toolbar and the colour row -- which are how
//! the text being typed is given another colour (task 1104).
//!
//! The rules, the same on both hosts:
//!
//!  * **As tall as what is in it**: one line to begin with, a line more for
//!    each line break. `line` is the height of one line in the font the
//!    host draws with, which the host measures; this file never guesses it.
//!  * **Inside the selection**: a new text starts no lower than one line
//!    above the selection's bottom edge ([`origin`]), and its box stops
//!    growing there ([`rect`]). What is typed past that scrolls in the box.
//!  * **Clear of the toolbar**: the box ends above any toolbar rectangle it
//!    would otherwise reach. Where one line cannot avoid it -- a text
//!    opened for editing again that already sits there -- the toolbar is
//!    drawn over it and a press there is the toolbar's ([`on_toolbar`]).

use crate::editor::Measure;
use crate::geom::{Point, Rect};
use crate::look::{colour, text_box};
use crate::pixels;
use crate::style;

/// The narrowest a box is, in ems of the font: room to see a few
/// characters before the box scrolls sideways.
pub const MIN_EMS: i32 = 4;
/// And never narrower than this many points, for the smallest sizes.
pub const MIN_WIDTH: u32 = 40;

/// The narrowest box for a font `font_px` pixels tall.
pub fn min_width(font_px: i32, scale: f64) -> i32 {
    (font_px * MIN_EMS).max(style::px(MIN_WIDTH, scale))
}

/// How many lines `text` is: one, and one more for each line break.
pub fn lines(text: &str) -> i32 {
    1 + text.matches('\n').count() as i32
}

fn overlaps_across(r: Rect, x: i32, w: i32) -> bool {
    r.x < x + w && r.right() > x
}

/// Where a new text starts for a press at `click` inside `selection`: the
/// press itself, pulled up and to the left just far enough that one line
/// `line` tall and `min_w` wide is inside the selection and above any of
/// `keep_clear` that lies inside it (the toolbar, when the selection is as
/// tall as the monitor and the toolbar has nowhere else to go).
///
/// A selection smaller than one line, or narrower than `min_w`, cannot hold
/// the box: the text then starts at the selection's own top or left edge.
pub fn origin(click: Point, line: i32, min_w: i32, selection: Rect, keep_clear: &[Rect]) -> Point {
    let mut bottom = selection.bottom();
    for r in keep_clear {
        let inside = r.y > selection.y && r.y < selection.bottom() && overlaps_across(*r, selection.x, selection.w);
        if inside {
            bottom = bottom.min(r.y);
        }
    }
    let y = click.y.min(bottom - line).max(selection.y);
    let x = click.x.min(selection.right() - min_w).max(selection.x);
    Point::new(x, y)
}

/// How wide the box is for text whose widest line is `widest` pixels: that
/// and room for the caret and for a letter more, never narrower than
/// `min_w`. The box follows what is typed; it is not as wide as the
/// selection to begin with (#1197).
pub fn width_for(widest: i32, min_w: i32, font_px: i32) -> i32 {
    (widest + (font_px + 1) / 2).max(min_w)
}

/// The box for a text at `at` holding `lines` lines of height `line`, whose
/// content is `content_w` wide (`width_for`).
///
/// Its width is `content_w`, at least `min_w`, and **never past the
/// selection's right edge** (stopped at the monitor's edge). Its height is a whole number of lines:
/// as many as the text has, but no more than fit above the selection's
/// bottom edge -- or the monitor's, for a text that is not in the selection
/// at all -- and above the top of any of `keep_clear` below it. Never less
/// than one line: what is being typed has to be seen.
pub fn rect(at: Point, lines: i32, line: i32, content_w: i32, min_w: i32, selection: Rect, monitor: Rect, keep_clear: &[Rect]) -> Rect {
    let line = line.max(1);
    let w = content_w.min(selection.right() - at.x).max(min_w).min(monitor.right() - at.x).max(1);
    let in_selection = at.y >= selection.y && at.y < selection.bottom();
    let mut limit = if in_selection { selection.bottom() } else { monitor.bottom() };
    for r in keep_clear {
        // Below the text's first row, or holding it: one that holds it
        // leaves no room at all, and the one line is all there is.
        if r.bottom() > at.y && overlaps_across(*r, at.x, w) {
            limit = limit.min(r.y);
        }
    }
    let fit = ((limit - at.y) / line).max(1);
    Rect::new(at.x, at.y, w, lines.clamp(1, fit) * line)
}

/// Whether a press at `p` is the toolbar's even though the box is there:
/// the toolbar is asked first, always.
pub fn on_toolbar(p: Point, keep_clear: &[Rect]) -> bool {
    keep_clear.iter().any(|r| r.contains(p))
}

/// Whether window message `msg` is one after which the native control may
/// hold something else -- other text, another selection, another scroll
/// position -- so that the host reads it again ([`Typed`]) and has the
/// overlay paint. `left_down`: the left button is held, which is what makes
/// a mouse move a selection being dragged.
///
/// **A list of the messages that change it, not everything but a list of
/// those that do not.** It was the second once, with seven questions
/// excepted, when the overlay drew the toolbar back over a box that had its
/// own paper: drawing was itself a source of messages to the box that were
/// not among the seven, the window thread drew, was asked, drew again, and
/// never read its queue (package 31c90b552). A message missing from this
/// list costs a stale caret until the next key; one too many on the other
/// kind of list cost the program.
///
/// **Nothing the host sends to read the control back may be here**, nor
/// anything painting sends or causes. The test below names those.
pub fn changes_box(msg: u32, left_down: bool) -> bool {
    match msg {
        WM_MOUSEMOVE => left_down,
        _ => CHANGES.contains(&msg),
    }
}

const WM_MOUSEMOVE: u32 = 0x0200;
/// `WM_SETFOCUS`, `WM_SETFONT`; `EM_SETSEL`, `EM_LINESCROLL`,
/// `EM_REPLACESEL`, `EM_UNDO`; `WM_KEYDOWN`, `WM_CHAR`; the left button
/// down, up and twice, the wheel; `WM_CUT`, `WM_PASTE`, `WM_CLEAR`,
/// `WM_UNDO`. The input method's messages are not here: the host answers
/// those itself and reads the control back as part of the answer.
const CHANGES: [u32; 16] = [
    0x0007, 0x0030, 0x00B1, 0x00B6, 0x00C2, 0x00C7, 0x0100, 0x0102, 0x0201, 0x0202, 0x0203, 0x020A, 0x0300, 0x0302, 0x0303, 0x0304,
];

/// Whether `msg` may have added or removed a line, so that the host fits
/// the box to what is in it again: a key, a character, a paste, a cut, a
/// clear, an undo.
///
/// **Fitting writes to the control** -- it moves it and may scroll it
/// (`EM_LINESCROLL`) -- and so does putting in what an input method
/// committed (`EM_REPLACESEL`). Neither of those, nor anything the host
/// sends to read the control back, is a message this says yes to: a write
/// the host makes is read back once ([`changes_box`]) and that is the end
/// of it. The test below holds both lists to that.
pub fn may_change_lines(msg: u32) -> bool {
    matches!(msg, 0x0100 | 0x0102 | 0x0300 | 0x0302 | 0x0303 | 0x0304)
}

/// What the host sends the control to read it back: `WM_GETTEXT`,
/// `WM_GETTEXTLENGTH`, `EM_GETSEL`, `EM_GETLINECOUNT`,
/// `EM_GETFIRSTVISIBLELINE`, `EM_POSFROMCHAR`.
pub const HOST_READS: [u32; 6] = [0x000D, 0x000E, 0x00B0, 0x00BA, 0x00CE, 0x00D6];
/// What the host sends the control that changes it, apart from opening it:
/// `EM_LINESCROLL` and what moving a window sends it (fitting),
/// `EM_REPLACESEL` (an input method's committed text), `WM_SETFONT`
/// (another size), `EM_SETSEL`.
pub const HOST_WRITES: [u32; 10] = [0x00B6, 0x0046, 0x0047, 0x0083, 0x0085, 0x0005, 0x0003, 0x00C2, 0x0030, 0x00B1];

// ------------------------------------------------------ what is drawn

/// What the native control holds, as the host last read it. Offsets count
/// UTF-16 code units, because that is what the control counts; a line break
/// in `units` is the control's own, CR LF.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Typed {
    pub units: Vec<u16>,
    /// What is selected, start then end. Equal: nothing, and the caret.
    pub sel: (usize, usize),
    /// Which end of a selection the caret is at.
    pub caret_at_start: bool,
    /// The first line the control shows: what it has scrolled up by.
    pub first_line: i32,
    /// How far it has scrolled sideways, in pixels.
    pub scroll_x: i32,
    /// What an input method is composing, which the control does not hold:
    /// it is shown where the caret is and is not part of the text yet.
    pub comp: Vec<u16>,
    /// The input method's own caret, in units of `comp`.
    pub comp_caret: usize,
}

/// Where everything of the box goes, in pixels from the box's top-left
/// corner. Nothing here is clipped: the host draws it clipped to the box.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct View {
    /// The words, composition included, a `\n` between lines: drawn in one
    /// piece the way a finished text annotation is, from `origin`.
    pub text: String,
    pub origin: Point,
    pub caret: Rect,
    /// One rectangle for each line with something selected in it.
    pub selected: Vec<Rect>,
    /// Under what is being composed.
    pub underline: Option<Rect>,
}

use crate::style::px_f as px;

/// So much of a colour, in parts of 256.
fn parts(alpha: f64) -> u32 {
    (alpha * 256.0).round() as u32
}

/// The lines of `units` as ranges of it, without their line breaks.
fn line_ranges(units: &[u16]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let (mut start, mut i) = (0, 0);
    while i < units.len() {
        let brk = match units[i] {
            0x000D if units.get(i + 1) == Some(&0x000A) => 2,
            0x000D | 0x000A => 1,
            _ => 0,
        };
        if brk > 0 {
            out.push((start, i));
            start = i + brk;
            i = start;
        } else {
            i += 1;
        }
    }
    out.push((start, units.len()));
    out
}

/// `at` moved back off the second half of a surrogate pair: half a
/// character is not a place.
fn whole(units: &[u16], at: usize) -> usize {
    let at = at.min(units.len());
    if at > 0 && at < units.len() && (0xDC00..0xE000).contains(&units[at]) && (0xD800..0xDC00).contains(&units[at - 1]) {
        at - 1
    } else {
        at
    }
}

/// Lay out what is typed in a box `box_w` wide whose lines are `line` tall.
///
/// The control decides what is scrolled where (`first_line`, `scroll_x`):
/// it is the one that keeps the caret's line in view, and that was measured
/// on a real machine (task 1106). What it cannot know is the composition,
/// so a composition that would put the caret past the box's right edge
/// moves everything left by what is missing, for as long as it lasts.
pub fn view(t: &Typed, box_w: i32, line: i32, font_px: i32, scale: f64, m: &dyn Measure) -> View {
    let line = line.max(1);
    let lines = line_ranges(&t.units);
    let composing = !t.comp.is_empty();
    let (s, e) = (whole(&t.units, t.sel.0.min(t.sel.1)), whole(&t.units, t.sel.0.max(t.sel.1)));
    let caret = if composing || t.caret_at_start { s } else { e };
    // The line the caret is on: the last one that starts at or before it (a
    // caret between a CR and its LF is at the end of the line before).
    let li = lines.iter().rposition(|(a, _)| *a <= caret).unwrap_or(0);
    let (la, lb) = lines[li];
    let caret = caret.min(lb);

    let width = |units: &[u16]| if units.is_empty() { 0 } else { m.text(&String::from_utf16_lossy(units), font_px).0 };
    let comp_caret = whole(&t.comp, t.comp_caret);
    let mut shown: Vec<u16> = t.units[la..caret].to_vec();
    let before_comp = width(&shown);
    shown.extend_from_slice(&t.comp[..if composing { comp_caret } else { 0 }]);
    let caret_x = width(&shown);
    shown.extend_from_slice(&t.comp[if composing { comp_caret } else { 0 }..]);
    let after_comp = width(&shown);
    shown.extend_from_slice(&t.units[caret..lb]);

    let caret_w = px(text_box::CARET_WIDTH, scale);
    let mut x0 = -t.scroll_x;
    if composing {
        let over = x0 + caret_x + caret_w - box_w;
        if over > 0 {
            x0 -= over;
        }
        if x0 + caret_x < 0 {
            x0 = -caret_x;
        }
    }
    let top = |i: usize| (i as i32 - t.first_line) * line;
    let caret_h = ((font_px as f64 * text_box::CARET_HEIGHT_EM).round() as i32).clamp(1, line);
    let caret_rect = Rect::new(x0 + caret_x, top(li) + (line - caret_h) / 2, caret_w, caret_h);

    let mut selected = Vec::new();
    if !composing && s < e {
        for (i, (a, b)) in lines.iter().enumerate() {
            if e <= *a || s > *b {
                continue;
            }
            let (from, to) = (s.max(*a), e.min(*b));
            // A selection that goes on past the end of the line has the
            // line break in it, and that is shown as a little more.
            let more = if e > *b { (font_px / 3).max(1) } else { 0 };
            let (xa, xb) = (width(&t.units[*a..from]), width(&t.units[*a..to]));
            if xb - xa + more > 0 {
                selected.push(Rect::new(x0 + xa, top(i), xb - xa + more, line));
            }
        }
    }
    let marked = px(text_box::MARKED_LINE, scale);
    let underline = (composing && after_comp > before_comp)
        .then(|| Rect::new(x0 + before_comp, top(li) + line - marked, after_comp - before_comp, marked));

    let mut text = String::new();
    for (i, (a, b)) in lines.iter().enumerate() {
        if i > 0 {
            text.push('\n');
        }
        text.push_str(&String::from_utf16_lossy(if i == li { &shown } else { &t.units[*a..*b] }));
    }
    View { text, origin: Point::new(x0, -t.first_line * line), caret: caret_rect, selected, underline }
}

/// Black or white, whichever is the other side of `rgb`: black for a colour
/// whose relative luminance is a half or more. Of the nine annotation
/// colours only yellow and white have black (§9.8).
pub fn inverse((r, g, b): (u8, u8, u8)) -> (u8, u8, u8) {
    let lin = |c: u8| {
        let c = c as f64 / 255.0;
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    if 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) >= text_box::LIGHT_TEXT_LUMINANCE {
        (0, 0, 0)
    } else {
        (255, 255, 255)
    }
}

// The frame: how far its line is from the box, the line's width and the
// length of one of its segments are the look's (`look::text_box`: 2 / 3 / 4,
// 1 / 2 / 2 and 4 / 6 / 8 pixels at 100 / 150 / 200%), and so are the two
// colours it is drawn in (`look::colour`: black at 72%, white at 95%).

/// The rectangle the frame's line is the outer edge of.
pub fn frame_rect(b: Rect, scale: f64) -> Rect {
    let out = px(text_box::OFFSET, scale) + px(text_box::LINE, scale);
    Rect::new(b.x - out, b.y - out, b.w + 2 * out, b.h + 2 * out)
}

/// Everything the overlay has to paint again when the box at `b` changes:
/// the frame, and the few pixels a halo reaches past it.
pub fn damage(b: Rect, scale: f64) -> Rect {
    let out = px(text_box::OFFSET, scale) + px(text_box::LINE, scale) + halo_reach(scale);
    Rect::new(b.x - out, b.y - out, b.w + 2 * out, b.h + 2 * out)
}

/// Draw the frame of the box at `b` into `dst`, a B, G, R, X buffer
/// covering `dst_rect`: a line one point wide, two points out from the box,
/// square corners, in segments that are dark and light by turns starting
/// dark at the top-left corner and going clockwise.
///
/// **Dark and light, so that it reads as dashes on anything.** On white
/// the dark ones show and the light ones are lost; on black the other way
/// round; the rhythm is the same. A dark line with white dashes beside it
/// read as one grey line on white, which is why it is not that.
///
/// Whole pixels and no smoothing: the whole line dark first, then the light
/// segments over it, as the design gives it.
pub fn draw_frame(dst: &mut [u8], dst_rect: Rect, b: Rect, scale: f64) {
    if dst.len() != dst_rect.w.max(0) as usize * dst_rect.h.max(0) as usize * 4 {
        return;
    }
    let o = frame_rect(b, scale);
    let (t, dash) = (px(text_box::LINE, scale), px(text_box::DASH, scale));
    let (dark_parts, light_parts) = (parts(colour::BOX_DARK.a), parts(colour::BOX_LIGHT.a));
    if o.w < 2 * t || o.h < 2 * t {
        return;
    }
    let mut put = |x: i32, y: i32, along: i32| {
        let (ax, ay) = (o.x + x, o.y + y);
        if !dst_rect.contains(Point::new(ax, ay)) {
            return;
        }
        let at = ((ay - dst_rect.y) as usize * dst_rect.w as usize + (ax - dst_rect.x) as usize) * 4;
        let light = (along / dash) % 2 == 1;
        for c in &mut dst[at..at + 3] {
            let dark = *c as u32 * (256 - dark_parts) / 256;
            *c = if light { (dark * (256 - light_parts) + 255 * light_parts) / 256 } else { dark } as u8;
        }
        dst[at + 3] = 255;
    };
    for k in 0..t {
        // Top, left to right; right, downwards; bottom, right to left;
        // left, upwards. `along` is how far round from the top-left corner.
        for x in 0..o.w {
            put(x, k, x);
        }
        for y in t..o.h {
            put(o.w - 1 - k, y, o.w + (y - t));
        }
        for x in (0..o.w - t).rev() {
            put(x, o.h - 1 - k, o.w + (o.h - t) + (o.w - t - 1 - x));
        }
        for y in (t..o.h - t).rev() {
            put(k, y, o.w + (o.h - t) + (o.w - t) + (o.h - t - 1 - y));
        }
    }
}

/// The two halos round the words being typed: how far each spreads in
/// points (a Gaussian's sigma) and how strong it is, the wide one first.
pub const HALOS: [(f64, f64); 2] =
    [(text_box::HALO_FAR_SIGMA, text_box::HALO_FAR_ALPHA), (text_box::HALO_NEAR_SIGMA, text_box::HALO_NEAR_ALPHA)];

/// How many pixels past the words a halo can reach: three sigmas of the
/// wide one.
pub fn halo_reach(scale: f64) -> i32 {
    (HALOS[0].0 * scale * 3.0).ceil() as i32
}

fn gauss(mask: &[f32], w: usize, h: usize, sigma: f64) -> Vec<f32> {
    let r = (sigma * 3.0).ceil() as i32;
    let kernel: Vec<f32> = (-r..=r).map(|i| (-(i * i) as f64 / (2.0 * sigma * sigma)).exp() as f32).collect();
    let sum: f32 = kernel.iter().sum();
    let pass = |src: &[f32], across: bool| {
        let mut out = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let mut acc = 0f32;
                for (k, weight) in kernel.iter().enumerate() {
                    let d = k as i32 - r;
                    let (sx, sy) = if across { (x as i32 + d, y as i32) } else { (x as i32, y as i32 + d) };
                    if sx >= 0 && sy >= 0 && (sx as usize) < w && (sy as usize) < h {
                        acc += src[sy as usize * w + sx as usize] * weight;
                    }
                }
                out[y * w + x] = acc / sum;
            }
        }
        out
    };
    pass(&pass(mask, true), false)
}

/// Put the halo of the words into `dst` (covering `dst_rect`): `mask` is
/// how much of each pixel of `mask_rect` the words cover, 0 to 255, and the
/// halo is that spread out twice ([`HALOS`]) in `rgb` -- the colour the
/// words are not ([`inverse`]). The words themselves are drawn after, over
/// it. With it white words on a white picture can be read while they are
/// typed; a finished text has none.
pub fn halo(dst: &mut [u8], dst_rect: Rect, mask: &[u8], mask_rect: Rect, rgb: (u8, u8, u8), scale: f64) {
    let (w, h) = (mask_rect.w.max(0) as usize, mask_rect.h.max(0) as usize);
    if mask.len() != w * h || dst.len() != dst_rect.w.max(0) as usize * dst_rect.h.max(0) as usize * 4 || mask.iter().all(|m| *m == 0) {
        return;
    }
    let cover: Vec<f32> = mask.iter().map(|m| *m as f32 / 255.0).collect();
    let Some(both) = mask_rect.intersect(dst_rect) else { return };
    for (sigma, strength) in HALOS {
        let spread = gauss(&cover, w, h, sigma * scale);
        for y in both.y..both.bottom() {
            for x in both.x..both.right() {
                let a = spread[(y - mask_rect.y) as usize * w + (x - mask_rect.x) as usize] * strength as f32;
                if a <= 0.0 {
                    continue;
                }
                let at = ((y - dst_rect.y) as usize * dst_rect.w as usize + (x - dst_rect.x) as usize) * 4;
                for (c, ink) in dst[at..at + 3].iter_mut().zip([rgb.2, rgb.1, rgb.0]) {
                    *c = (*c as f32 + (ink as f32 - *c as f32) * a.min(1.0)).round() as u8;
                }
            }
        }
    }
}

/// How strong the line round the caret is, of 256: 60% when it is black,
/// 75% when it is white.
pub fn caret_edge(inverse: (u8, u8, u8)) -> u32 {
    parts(if inverse == (0, 0, 0) { colour::CARET_EDGE_DARK.a } else { colour::CARET_EDGE_LIGHT.a })
}

/// Draw the caret at `caret` into `dst`: `rgb` solid, with a line one point
/// wide round it in the colour it is not, so that it shows on its own
/// colour. Nothing is drawn outside `clip`.
pub fn draw_caret(dst: &mut [u8], dst_rect: Rect, caret: Rect, clip: Rect, rgb: (u8, u8, u8), scale: f64) {
    let edge = px(text_box::CARET_EDGE, scale);
    let inv = inverse(rgb);
    let round = Rect::new(caret.x - edge, caret.y - edge, caret.w + 2 * edge, caret.h + 2 * edge);
    if let Some(r) = round.intersect(clip) {
        pixels::blend(dst, dst_rect, r, inv, caret_edge(inv));
    }
    if let Some(r) = caret.intersect(clip) {
        pixels::blend(dst, dst_rect, r, rgb, 256);
    }
}

#[cfg(test)]
mod tests {
    /// A content wider than any selection: the box runs to its edge.
    const WIDE: i32 = 100_000;
    use super::*;
    use crate::style::{Props, FONTS, LEVELS};
    use crate::toolbar;

    /// A line of the annotation font is taller than its size; the hosts
    /// measure it. This is near what Noto Sans SC gives and is only a
    /// stand-in: nothing here depends on the ratio.
    fn line_of(font_px: i32) -> i32 {
        (font_px * 29 + 19) / 20
    }

    fn bars(selection: Rect, monitor: Rect, scale: f64) -> Vec<Rect> {
        let l = toolbar::layout(selection, monitor, scale, Props::Font);
        let mut out = vec![l.bar];
        out.extend(l.props);
        out
    }

    fn within(inner: Rect, outer: Rect) -> bool {
        inner.x >= outer.x && inner.y >= outer.y && inner.right() <= outer.right() && inner.bottom() <= outer.bottom()
    }

    /// The reading the test machine brought back (task 1104): a 900x500
    /// selection at 144 DPI, the largest size, opened at (1450,650).
    #[test]
    fn the_box_the_test_machine_measured_no_longer_reaches_the_toolbar() {
        let (scale, monitor) = (1.5, Rect::new(0, 0, 2560, 1600));
        let selection = Rect::from_ltrb(1350, 300, 2250, 800);
        let keep = bars(selection, monitor, scale);
        let font = style::font_px(4, scale);
        assert_eq!(font, 66);
        // What it was: four lines whatever was typed, 264 px, to y = 914,
        // over a toolbar that starts under the selection at 812.
        assert_eq!(keep[0].y, 812);
        assert!(650 + font * 4 > keep[0].y);

        let line = line_of(font);
        let at = origin(Point::new(1450, 650), line, min_width(font, scale), selection, &keep);
        assert_eq!(at, Point::new(1450, 650), "there is room: the text starts where it was pressed");
        let one = rect(at, 1, line, WIDE, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(one, Rect::new(1450, 650, 800, line));
        // It grows a line at a time and stops at the selection's bottom.
        let two = rect(at, 2, line, WIDE, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(two.h, (2 * line).min((800 - 650) / line * line));
        let many = rect(at, 40, line, WIDE, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(many.h, (800 - 650) / line * line);
        assert!(many.bottom() <= selection.bottom());
        for r in &keep {
            assert_eq!(many.intersect(*r), None);
        }
    }

    #[test]
    fn at_every_size_and_scale_the_box_is_in_the_selection_whole_lines_tall_and_off_the_toolbar() {
        for scale in [1.0, 1.5, 2.0] {
            let monitor = Rect::new(0, 0, 2560, 1600);
            // Under it, over it (no room under), and inside its bottom edge
            // (as tall as the monitor): the three places a toolbar goes.
            for selection in [Rect::from_ltrb(400, 300, 1300, 800), Rect::from_ltrb(400, 900, 1300, 1590), Rect::from_ltrb(400, 0, 1300, 1600)] {
                let keep = bars(selection, monitor, scale);
                for level in 0..LEVELS {
                    let font = style::font_px(level, scale);
                    let (line, min_w) = (line_of(font), min_width(font, scale));
                    // Pressed at the top, in the middle, and on the last
                    // pixel row; and at the left, and on the last column.
                    for click_y in [selection.y, selection.y + selection.h / 2, selection.bottom() - 1] {
                        for click_x in [selection.x, selection.x + selection.w / 2, selection.right() - 1] {
                            let click = Point::new(click_x, click_y);
                            if on_toolbar(click, &keep) {
                                // That press is the toolbar's, not a text.
                                continue;
                            }
                            let at = origin(click, line, min_w, selection, &keep);
                            for typed in [1, 2, 3, 50] {
                                let b = rect(at, typed, line, WIDE, min_w, selection, monitor, &keep);
                                let what = format!("scale {scale} selection {selection:?} level {level} click {click:?} lines {typed}: {b:?}");
                                assert!(within(b, selection), "{what}");
                                assert_eq!(b.h % line, 0, "{what}");
                                assert!(b.h >= line && b.h <= typed * line, "{what}");
                                assert!(b.w >= min_w, "{what}");
                                for r in &keep {
                                    assert_eq!(b.intersect(*r), None, "{what} meets {r:?}");
                                }
                                // One line where it was pressed, when it fits there.
                                if typed == 1 && click.y + line <= selection.bottom() && !keep.iter().any(|r| r.y > click.y && r.y < click.y + line) {
                                    assert_eq!(at.y, click.y, "{what}");
                                    assert_eq!(b.h, line, "{what}");
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_new_text_is_pulled_only_as_far_as_one_line_needs() {
        let selection = Rect::from_ltrb(100, 100, 700, 500);
        // Room: where it was pressed.
        assert_eq!(origin(Point::new(300, 200), 30, 120, selection, &[]), Point::new(300, 200));
        // On the bottom row: up by a line, less the row it was on.
        assert_eq!(origin(Point::new(300, 499), 30, 120, selection, &[]), Point::new(300, 470));
        assert_eq!(origin(Point::new(300, 470), 30, 120, selection, &[]), Point::new(300, 470));
        assert_eq!(origin(Point::new(300, 471), 30, 120, selection, &[]), Point::new(300, 470));
        // On the last column: left until the narrowest box fits.
        assert_eq!(origin(Point::new(699, 200), 30, 120, selection, &[]), Point::new(580, 200));
        // A toolbar inside the selection's bottom edge is the floor instead.
        let bar = Rect::new(300, 440, 400, 50);
        assert_eq!(origin(Point::new(350, 430), 30, 120, selection, &[bar]), Point::new(350, 410));
        // One outside it is not: the selection's edge already keeps clear.
        let under = Rect::new(300, 508, 400, 50);
        assert_eq!(origin(Point::new(350, 499), 30, 120, selection, &[under]), Point::new(350, 470));
        // A selection that cannot hold a line: its own corner.
        let thin = Rect::from_ltrb(100, 100, 150, 110);
        assert_eq!(origin(Point::new(140, 105), 30, 120, thin, &[]), Point::new(100, 100));
    }

    #[test]
    fn a_text_edited_again_outside_the_selection_stops_at_the_toolbar_or_the_monitor() {
        let monitor = Rect::new(0, 0, 1920, 1080);
        let selection = Rect::from_ltrb(100, 100, 700, 500);
        // Left behind above the selection when it was moved: the selection
        // is not its floor, the monitor is.
        let above = rect(Point::new(200, 20), 99, 30, WIDE, 120, selection, monitor, &[]);
        assert_eq!((above.y, above.h), (20, (1080 - 20) / 30 * 30));
        // Beside the toolbar's top: it ends there.
        let bar = Rect::new(300, 508, 400, 40);
        let beside = rect(Point::new(350, 20), 99, 30, WIDE, 120, selection, monitor, &[bar]);
        assert_eq!(beside.bottom(), 20 + (508 - 20) / 30 * 30);
        assert!(beside.bottom() <= bar.y);
        // A toolbar off to the side of the box is no floor.
        let aside = rect(Point::new(720, 20), 2, 30, WIDE, 120, selection, monitor, &[Rect::new(900, 30, 100, 40)]);
        assert_eq!(aside.h, 60);
        // Sitting on the toolbar already: one line, and the press is the
        // toolbar's all the same.
        let on = rect(Point::new(350, 520), 3, 30, WIDE, 120, selection, monitor, &[bar]);
        assert_eq!(on.h, 30);
        assert!(on_toolbar(Point::new(360, 525), &[bar]));
        assert!(!on_toolbar(Point::new(360, 560), &[bar]));
    }

    /// A text opened for editing again where the toolbar now is (task
    /// 1107: the box was 800x96 at (1450,704) and four points of the
    /// toolbar's first row read the box's white paper). The box has no
    /// paper and no window to press now; what is left of that reading is
    /// that a press on those points is the toolbar's.
    #[test]
    fn a_press_where_the_box_lies_on_the_toolbar_is_the_toolbars() {
        let (scale, monitor) = (1.5, Rect::new(0, 0, 2560, 1600));
        let selection = Rect::from_ltrb(1350, 300, 2250, 720);
        let keep = bars(selection, monitor, scale);
        let font = style::font_px(4, scale);
        let large = rect(Point::new(1450, 704), 1, 96, WIDE, min_width(font, scale), selection, monitor, &keep);
        assert_eq!(large, Rect::new(1450, 704, 800, 96), "the box the log gave");
        for p in [Point::new(1560, 762), Point::new(2220, 762), Point::new(2000, 745), Point::new(2000, 790)] {
            assert!(large.contains(p) && on_toolbar(p, &keep), "{p:?}");
        }
        // In the box and off the toolbar: the box's.
        assert!(large.contains(Point::new(1500, 716)) && !on_toolbar(Point::new(1500, 716), &keep));
    }

    /// The host reads the control back and has the overlay paint after one
    /// of `CHANGES`, and fits the box after one of `may_change_lines`.
    /// Reading, fitting and painting must never be the cause of either:
    /// that is a loop, and one like it stopped the window thread once.
    #[test]
    fn reading_the_box_back_and_writing_to_it_never_ask_for_another_round() {
        // Reading it back changes nothing and asks for nothing.
        for read in HOST_READS {
            assert!(!changes_box(read, false) && !changes_box(read, true), "{read:#06x}");
            assert!(!may_change_lines(read), "{read:#06x}");
        }
        // What the host writes is read back (or not), and never fitted
        // again: fitting is what sends some of these.
        for write in HOST_WRITES {
            assert!(!may_change_lines(write), "{write:#06x}");
        }
        // The writes that change what is shown are read back once.
        for write in [0x00B6, 0x00C2, 0x0030, 0x00B1] {
            assert!(changes_box(write, false), "{write:#06x}");
        }
        // WM_GETOBJECT (what a listener sends on hearing the caret moved),
        // the caret's own timer, what the system asks of a window under the
        // pointer, being moved, painted, erased and ended, the input
        // method's notifications and its question about the caret.
        for other in [0x003D, 0x0118, 0x0084, 0x0020, 0x000F, 0x0014, 0x0087, 0x0008, 0x0002, 0x0082, 0x0281, 0x0282, 0x0288] {
            assert!(!changes_box(other, false), "{other:#06x}");
            assert!(!may_change_lines(other), "{other:#06x}");
        }
        // A pointer passing over is not a selection being dragged.
        assert!(!changes_box(WM_MOUSEMOVE, false));
        assert!(changes_box(WM_MOUSEMOVE, true));
        assert!(!changes_box(0x003D, true));

        // And both are lists: the ones named and no other, of every message
        // number there is below the application's own.
        let named: Vec<u32> = (0..0x0400).filter(|m| changes_box(*m, false)).collect();
        assert_eq!(named, CHANGES);
        let fitted: Vec<u32> = (0..0x0400).filter(|m| may_change_lines(*m)).collect();
        assert_eq!(fitted, [0x0100, 0x0102, 0x0300, 0x0302, 0x0303, 0x0304]);
        // Everything that is fitted after is read back after too.
        for m in fitted {
            assert!(changes_box(m, false), "{m:#06x}");
        }
    }

    /// Every character is `font_px / 2` wide, a wide one (CJK) `font_px`.
    struct Half;
    impl Measure for Half {
        fn text(&self, text: &str, font_px: i32) -> (i32, i32) {
            let w = text.lines().map(|l| l.chars().map(|c| if c as u32 >= 0x2E80 { font_px } else { font_px / 2 }).sum::<i32>()).max().unwrap_or(0);
            (w, text.split('\n').count() as i32 * line_of(font_px))
        }
    }

    fn typed(text: &str, sel: (usize, usize)) -> Typed {
        Typed { units: text.encode_utf16().collect(), sel, ..Default::default() }
    }

    #[test]
    fn the_caret_is_where_the_control_says_on_the_line_it_is_on() {
        let (font, line) = (20, 29);
        // "ab" CR LF "cde", the caret after the "d": unit 6.
        let v = view(&typed("ab\r\ncde", (6, 6)), 400, line, font, 1.0, &Half);
        assert_eq!(v.text, "ab\ncde");
        assert_eq!(v.origin, Point::new(0, 0));
        // 2 px wide, 1.08 x 20 = 22 px tall, in the middle of the 2nd line.
        assert_eq!(v.caret, Rect::new(20, 29 + (29 - 22) / 2, 2, 22));
        assert!(v.selected.is_empty() && v.underline.is_none());
        // At the very end, and in nothing at all.
        assert_eq!(view(&typed("ab\r\ncde", (7, 7)), 400, line, font, 1.0, &Half).caret.x, 30);
        assert_eq!(view(&typed("", (0, 0)), 400, line, font, 1.0, &Half).caret, Rect::new(0, 3, 2, 22));
        // After a line break with nothing typed yet: the start of line 3.
        let v = view(&typed("ab\r\ncde\r\n", (9, 9)), 400, line, font, 1.0, &Half);
        assert_eq!((v.caret.x, v.caret.y), (0, 2 * 29 + 3));
        assert_eq!(v.text, "ab\ncde\n");
        // Between a CR and its LF is the end of that line, not half a break.
        assert_eq!(view(&typed("ab\r\ncde", (3, 3)), 400, line, font, 1.0, &Half).caret.x, 20);
        // Past the end, or backwards: clamped, never a panic.
        assert_eq!(view(&typed("ab", (99, 5)), 400, line, font, 1.0, &Half).caret.x, 20);
        // Twice the scale is twice the caret's width.
        assert_eq!(view(&typed("", (0, 0)), 400, 58, 40, 2.0, &Half).caret, Rect::new(0, (58 - 43) / 2, 4, 43));
    }

    #[test]
    fn what_the_control_scrolled_is_where_the_words_are_drawn_from() {
        let mut t = typed("L1\r\nL2\r\nL3\r\nL4\r\nL5", (18, 18));
        // The control shows from the 2nd line (the box stopped growing at
        // four lines; task 1106, T2) and has scrolled 15 px sideways.
        t.first_line = 1;
        t.scroll_x = 15;
        let v = view(&t, 400, 29, 20, 1.0, &Half);
        assert_eq!(v.origin, Point::new(-15, -29));
        // The caret's line, the 5th, is the 4th row of the box: in view.
        assert_eq!((v.caret.x, v.caret.y), (20 - 15, 3 * 29 + 3));
        assert!(v.caret.bottom() <= 4 * 29);
    }

    #[test]
    fn what_is_selected_is_a_rectangle_a_line_and_the_caret_is_at_its_own_end() {
        // "abcd" CR LF "ef" CR LF "gh": from after "b" to after "g".
        let mut t = typed("abcd\r\nef\r\ngh", (2, 11));
        let v = view(&t, 400, 29, 20, 1.0, &Half);
        // The 1st and 2nd lines go on past their ends (20 / 3 = 6 more).
        assert_eq!(v.selected, [Rect::new(20, 0, 20 + 6, 29), Rect::new(0, 29, 20 + 6, 29), Rect::new(0, 58, 10, 29)]);
        assert_eq!((v.caret.x, v.caret.y), (10, 58 + 3));
        t.caret_at_start = true;
        assert_eq!((view(&t, 400, 29, 20, 1.0, &Half).caret.x, view(&t, 400, 29, 20, 1.0, &Half).caret.y), (20, 3));
        // Ctrl+A on an empty line and a full one.
        let v = view(&typed("\r\nab", (0, 4)), 400, 29, 20, 1.0, &Half);
        assert_eq!(v.selected, [Rect::new(0, 0, 6, 29), Rect::new(0, 29, 20, 29)]);
    }

    #[test]
    fn what_is_being_composed_is_shown_at_the_caret_and_underlined() {
        // "ab|cd" with "ni'hao" composing, the input method's caret at its end.
        let mut t = typed("ab\r\nabcd", (6, 6));
        t.comp = "ni'hao".encode_utf16().collect();
        t.comp_caret = 6;
        let v = view(&t, 400, 29, 20, 1.0, &Half);
        assert_eq!(v.text, "ab\nabni'haocd");
        assert_eq!(v.underline, Some(Rect::new(20, 29 + 29 - 2, 60, 2)));
        assert_eq!(v.caret.x, 80);
        // The input method's caret in the middle of it.
        t.comp_caret = 2;
        assert_eq!(view(&t, 400, 29, 20, 1.0, &Half).caret.x, 40);
        // A selection is what the composition replaces: not shown beside it.
        t.sel = (4, 6);
        let v = view(&t, 400, 29, 20, 1.0, &Half);
        assert!(v.selected.is_empty());
        assert_eq!(v.underline.map(|u| u.x), Some(0));
        // A composition the box is too narrow for: everything moves left
        // until the caret is inside, which the control could not have done.
        let mut t = typed("abcd", (4, 4));
        t.comp = "ni'hao".encode_utf16().collect();
        t.comp_caret = 6;
        let v = view(&t, 60, 29, 20, 1.0, &Half);
        assert_eq!(v.caret.right(), 60);
        assert_eq!(v.origin.x, 60 - 2 - 100);
        // Nothing composing: nothing moves, nothing is underlined.
        let v = view(&typed("abcdefghij", (10, 10)), 60, 29, 20, 1.0, &Half);
        assert_eq!((v.origin.x, v.underline), (0, None));
    }

    #[test]
    fn half_a_character_is_not_a_place() {
        // U+1F600 is two units; a caret reported between them is before it.
        let v = view(&typed("a\u{1F600}b", (2, 2)), 400, 29, 20, 1.0, &Half);
        assert_eq!(v.caret.x, 10);
        assert_eq!(v.text, "a\u{1F600}b");
    }

    #[test]
    fn only_yellow_and_white_have_black_for_their_other_side() {
        let black: Vec<usize> = (0..style::COLOURS.len()).filter(|i| inverse(style::COLOURS[*i]) == (0, 0, 0)).collect();
        let names: Vec<String> = black.iter().map(|i| style::hex(*i as u8)).collect();
        assert_eq!(black.len(), 2, "{names:?}");
        assert!(names.contains(&"#FFFFFF".to_string()), "{names:?}");
        assert_eq!(inverse((0, 0, 0)), (255, 255, 255));
        assert_eq!((caret_edge((0, 0, 0)), caret_edge((255, 255, 255))), (154, 192));
    }

    fn sheet(rect: Rect, grey: u8) -> Vec<u8> {
        vec![grey; rect.w as usize * rect.h as usize * 4]
    }
    fn at(buf: &[u8], rect: Rect, x: i32, y: i32) -> u8 {
        buf[((y - rect.y) as usize * rect.w as usize + (x - rect.x) as usize) * 4]
    }
    /// The lengths of the runs of equal value along `values`.
    fn runs(values: &[u8]) -> Vec<(u8, usize)> {
        let mut out: Vec<(u8, usize)> = Vec::new();
        for v in values {
            match out.last_mut() {
                Some((last, n)) if last == v => *n += 1,
                _ => out.push((*v, 1)),
            }
        }
        out
    }

    #[test]
    fn the_frame_is_dark_and_light_by_turns_at_every_scale_and_on_any_paper() {
        // Scale, the gap, the line's width, a segment's length (§9.8).
        for (scale, gap, t, dash) in [(1.0, 2, 1, 4), (1.5, 3, 2, 6), (2.0, 4, 2, 8)] {
            let canvas = Rect::new(100, 100, 400, 300);
            let b = Rect::new(200, 180, 160, 64);
            assert_eq!(frame_rect(b, scale), Rect::new(200 - gap - t, 180 - gap - t, 160 + 2 * (gap + t), 64 + 2 * (gap + t)));
            let o = frame_rect(b, scale);
            let mut seen = Vec::new();
            for paper in [255u8, 0] {
                let mut buf = sheet(canvas, paper);
                draw_frame(&mut buf, canvas, b, scale);
                // Dark: black at 72%. Light: white at 95% over that.
                let dark = (paper as u32 * (256 - 184) / 256) as u8;
                let light = ((dark as u32 * (256 - 243) + 255 * 243) / 256) as u8;
                assert!(light >= 242 && dark <= 72, "{dark} {light}");
                let top: Vec<u8> = (o.x..o.right()).map(|x| at(&buf, canvas, x, o.y)).collect();
                let r = runs(&top);
                // Dark first, from the corner, and every whole one `dash` long.
                assert_eq!(r[0], (dark, dash as usize), "scale {scale} paper {paper}: {r:?}");
                assert_eq!(r[1], (light, dash as usize), "scale {scale} paper {paper}: {r:?}");
                for (v, n) in &r[..r.len() - 1] {
                    assert!((*v == dark || *v == light) && *n == dash as usize, "scale {scale}: {r:?}");
                }
                seen.push(r.len());
                // As wide as it is said to be, and nothing inside it or
                // outside it is touched: the box is the picture.
                let on = |x: i32, y: i32| [dark, light].contains(&at(&buf, canvas, x, y));
                for k in 0..t {
                    assert!(on(o.x + 20, o.y + k) && on(o.x + k, o.y + 20) && on(o.right() - 1 - k, o.y + 20) && on(o.x + 20, o.bottom() - 1 - k));
                }
                assert_eq!(at(&buf, canvas, o.x + 20, o.y + t), paper);
                assert_eq!(at(&buf, canvas, o.x + 20, o.y - 1), paper);
                for y in b.y..b.bottom() {
                    for x in b.x..b.right() {
                        assert_eq!(at(&buf, canvas, x, y), paper);
                    }
                }
                // On white every pixel of the line differs from the paper:
                // the ring and only the ring. (On black the dark ones are
                // the paper's own colour -- which is the point of the light.)
                if paper == 255 {
                    let changed = buf.chunks_exact(4).filter(|p| p[0] != paper).count() as i32;
                    assert_eq!(changed, 2 * t * (o.w + o.h) - 4 * t * t);
                } else {
                    assert!(buf.chunks_exact(4).any(|p| p[0] == light));
                }
                // Clockwise: the right edge goes on where the top stopped.
                let down: Vec<u8> = (o.y + t..o.bottom()).map(|y| at(&buf, canvas, o.right() - 1, y)).collect();
                let whole: Vec<u8> = top.iter().chain(down.iter()).copied().collect();
                for (v, n) in &runs(&whole)[1..runs(&whole).len() - 1] {
                    assert!((*v == dark || *v == light) && *n == dash as usize, "round the corner: {:?}", runs(&whole));
                }
            }
            // The same number of segments on white as on black.
            assert_eq!(seen[0], seen[1]);
        }
        // A box partly off the buffer, and a buffer of the wrong size: no panic.
        let canvas = Rect::new(0, 0, 50, 50);
        let mut buf = sheet(canvas, 255);
        draw_frame(&mut buf, canvas, Rect::new(-20, 40, 100, 30), 2.0);
        draw_frame(&mut buf[..8], canvas, Rect::new(10, 10, 10, 10), 1.0);
    }

    #[test]
    fn the_halo_is_the_colour_the_words_are_not_and_fades_within_its_reach() {
        for scale in [1.0, 1.5, 2.0] {
            let reach = halo_reach(scale);
            assert_eq!(reach, [4, 6, 8][((scale - 1.0) * 2.0) as usize]);
            let canvas = Rect::new(0, 0, 80, 60);
            let mask_rect = Rect::new(10, 10, 60, 40);
            // A stroke 3 px wide down the middle of the mask.
            let mut mask = vec![0u8; 60 * 40];
            for y in 0..40 {
                for x in 29..32 {
                    mask[y * 60 + x] = 255;
                }
            }
            // White words on white: the halo is black, and darkest on them.
            let mut buf = sheet(canvas, 255);
            halo(&mut buf, canvas, &mask, mask_rect, (0, 0, 0), scale);
            let row: Vec<u8> = (0..80).map(|x| at(&buf, canvas, x, 30)).collect();
            assert!(row[40] < 255 - 100, "scale {scale}: {}", row[40]);
            // Falling away on both sides, the same on both.
            for d in 1..reach as usize {
                assert!(row[40 + d] >= row[40 + d - 1], "scale {scale}: {row:?}");
                assert_eq!(row[40 + d], row[40 - d], "scale {scale}");
            }
            // Beside the words it can still be seen; past its reach, nothing.
            assert!(row[42 + 1] < 250, "scale {scale}: {row:?}");
            assert_eq!(row[41 + reach as usize + 1], 255, "scale {scale}: {row:?}");
            assert_eq!(row[39 - reach as usize - 1], 255);
            // Nothing outside the mask's rectangle, whatever it holds.
            assert_eq!(at(&buf, canvas, 40, 9), 255);
            // Black words on black: the halo is white.
            let mut buf = sheet(canvas, 0);
            halo(&mut buf, canvas, &mask, mask_rect, (255, 255, 255), scale);
            assert!(at(&buf, canvas, 40, 30) > 100);
            // No words, no halo; and a mask of the wrong size is left alone.
            let mut buf = sheet(canvas, 200);
            halo(&mut buf, canvas, &vec![0u8; 60 * 40], mask_rect, (0, 0, 0), scale);
            halo(&mut buf, canvas, &mask[..10], mask_rect, (0, 0, 0), scale);
            assert!(buf.iter().all(|c| *c == 200));
        }
    }

    #[test]
    fn the_caret_shows_on_its_own_colour_and_stays_in_the_box() {
        let canvas = Rect::new(0, 0, 60, 60);
        let caret = Rect::new(20, 10, 4, 30);
        // A white caret on white paper: a dark line round it, 2 px at 200%.
        let mut buf = sheet(canvas, 255);
        draw_caret(&mut buf, canvas, caret, canvas, (255, 255, 255), 2.0);
        assert_eq!(at(&buf, canvas, 21, 20), 255);
        let edge = (255 * (256 - 154) / 256) as u8;
        assert_eq!((at(&buf, canvas, 19, 20), at(&buf, canvas, 18, 20), at(&buf, canvas, 17, 20)), (edge, edge, 255));
        assert_eq!((at(&buf, canvas, 24, 20), at(&buf, canvas, 25, 20), at(&buf, canvas, 26, 20)), (edge, edge, 255));
        assert_eq!((at(&buf, canvas, 21, 8), at(&buf, canvas, 21, 7)), (edge, 255));
        // A black caret on black paper: a light line, at 75%.
        let mut buf = sheet(canvas, 0);
        draw_caret(&mut buf, canvas, caret, canvas, (0, 0, 0), 1.0);
        assert_eq!((at(&buf, canvas, 21, 20), at(&buf, canvas, 19, 20), at(&buf, canvas, 18, 20)), (0, (255 * 192 / 256) as u8, 0));
        // Scrolled half out of the box: what is outside is not drawn.
        let mut buf = sheet(canvas, 255);
        draw_caret(&mut buf, canvas, caret, Rect::new(0, 0, 22, 60), (255, 0, 0), 1.0);
        assert_eq!((at(&buf, canvas, 21, 20), at(&buf, canvas, 22, 20), at(&buf, canvas, 24, 20)), (0, 255, 255));
    }

    #[test]
    fn what_has_to_be_painted_again_holds_the_frame_and_the_halo() {
        for scale in [1.0, 1.5, 2.0] {
            let b = Rect::new(200, 180, 160, 64);
            let (d, f) = (damage(b, scale), frame_rect(b, scale));
            assert!(within(f, d));
            assert_eq!(d.x, f.x - halo_reach(scale));
            assert_eq!(d.bottom(), f.bottom() + halo_reach(scale));
        }
    }

    #[test]
    fn the_width_runs_to_the_selections_edge_and_is_never_too_narrow_to_type_in() {
        let monitor = Rect::new(0, 0, 1920, 1080);
        let selection = Rect::from_ltrb(100, 100, 700, 500);
        assert_eq!(rect(Point::new(300, 200), 1, 30, WIDE, 120, selection, monitor, &[]).w, 400);
        // Past the selection's right edge (a text left there): the least.
        assert_eq!(rect(Point::new(690, 200), 1, 30, WIDE, 120, selection, monitor, &[]).w, 120);
        // At the monitor's edge there is only what there is.
        assert_eq!(rect(Point::new(1900, 200), 1, 30, WIDE, 120, selection, monitor, &[]).w, 20);
        for (level, points) in FONTS.iter().enumerate() {
            assert_eq!(min_width(style::font_px(level as u8, 1.0), 1.0), (*points as i32 * MIN_EMS).max(40));
        }
    }

    /// #1197 item 4: the box is as wide as what is in it, from the least
    /// width up to the selection's edge, and never past it.
    #[test]
    fn the_width_follows_the_content_and_stops_at_the_selections_edge() {
        let monitor = Rect::new(0, 0, 1920, 1080);
        let selection = Rect::from_ltrb(100, 100, 700, 500);
        let at = Point::new(300, 200);
        let w = |content| rect(at, 1, 30, content, 120, selection, monitor, &[]).w;
        assert_eq!(w(width_for(0, 120, 24)), 120, "empty: the least");
        assert_eq!(w(width_for(200, 120, 24)), 212, "the words and room for a letter more");
        assert_eq!(w(width_for(5000, 120, 24)), 400, "not past the selection");
        assert!(w(width_for(200, 120, 24)) < w(width_for(300, 120, 24)), "wider as it is typed");
    }

    #[test]
    fn a_line_break_is_a_line() {
        assert_eq!(lines(""), 1);
        assert_eq!(lines("abc"), 1);
        assert_eq!(lines("a\nb"), 2);
        assert_eq!(lines("a\n"), 2);
        assert_eq!(lines("\n\n"), 3);
    }
}
