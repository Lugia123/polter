//! Stitching a long screenshot out of frames taken while the person scrolls.
//!
//! Specification §9.6. Each frame is the same rectangle of the screen, a
//! moment later. Three things can have happened between two frames, and the
//! whole of this module is telling them apart without guessing:
//!
//!  * the content **scrolled down** by some rows -- the rows that came into
//!    view at the bottom are new and are added;
//!  * it **scrolled back** -- nothing is new, but where the frame now sits in
//!    what has been collected has to be remembered, so that scrolling down
//!    again does not add the same rows twice;
//!  * it did **something else** (scrolled further than one frame's height,
//!    or the content itself changed) -- there is no overlap to trust, and
//!    the frame is dropped. Joining it anyway would produce a picture with a
//!    seam in it that looks like a real page.
//!
//! Bands at the top and bottom that do not move while the middle does -- a
//! fixed header, a status bar -- are found from the first pair of frames that
//! scrolled, and kept once.
//!
//! Frames are B, G, R, X rows, top row first, like everything in `pixels`.

/// The tallest a long screenshot may get, in pixels.
pub const MAX_HEIGHT: usize = 20_000;

/// The least two frames must share for the match to be believed: this many
/// rows, or an eighth of the moving band, whichever is more.
const MIN_OVERLAP: usize = 24;
/// The share of the overlapping rows that must be identical. Not all of
/// them: a blinking caret or a hover highlight changes a row or two.
const AGREE_PER_MILLE: usize = 970;
/// The overlap must have at least this many different-looking rows. A blank
/// stretch matches itself at every offset and says nothing about which.
const MIN_DISTINCT: usize = 4;

/// What a frame turned out to be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// The first frame: the picture so far is this frame.
    First,
    /// Nothing moved.
    Unchanged,
    /// The content scrolled down and this many new rows were added.
    Added(usize),
    /// It scrolled down, but only over rows already collected (after a
    /// scroll back).
    Seen,
    /// It scrolled back up. Nothing is added and nothing is lost.
    Back,
    /// No trustworthy overlap with the last frame: dropped. Tell the person
    /// to scroll more slowly.
    Lost,
    /// The picture reached [`MAX_HEIGHT`]; what fitted was added and nothing
    /// more will be.
    Full,
    /// Not a frame of this session's size: ignored.
    WrongSize,
    /// Not the same as the frame offered just before it: the screen was
    /// still changing, so it is held back, not joined (`offer`).
    Moving,
}

fn row_hashes(frame: &[u8], width: usize) -> Vec<u64> {
    frame
        .chunks_exact(width * 4)
        .map(|row| {
            // FNV-1a over B, G, R; the fourth byte is not part of the picture.
            let mut h = 0xcbf2_9ce4_8422_2325u64;
            for px in row.chunks_exact(4) {
                for b in &px[..3] {
                    h = (h ^ *b as u64).wrapping_mul(0x0100_0000_01b3);
                }
            }
            h
        })
        .collect()
}

/// How `now` relates to `before` inside the band `[top, bottom)` of rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Motion {
    None,
    Down(usize),
    Up(usize),
    Unknown,
}

/// Whether `a` shifted by `shift` rows lines up with `b`: `a[i + shift]`
/// against `b[i]` over their overlap.
fn lines_up(a: &[u64], b: &[u64], shift: usize) -> bool {
    let overlap = a.len() - shift;
    let agree = (0..overlap).filter(|i| a[i + shift] == b[*i]).count();
    if agree * 1000 < overlap * AGREE_PER_MILLE {
        return false;
    }
    let mut distinct: Vec<u64> = b[..overlap].to_vec();
    distinct.sort_unstable();
    distinct.dedup();
    distinct.len() >= MIN_DISTINCT.min(overlap)
}

fn motion(before: &[u64], now: &[u64]) -> Motion {
    if before == now {
        return Motion::None;
    }
    let band = before.len();
    let least = MIN_OVERLAP.max(band / 8).min(band);
    // The smallest shift that lines up, down before up: a page that repeats
    // would line up at several, and the smallest adds the least that could
    // be wrong.
    for shift in 1..=band.saturating_sub(least) {
        if lines_up(before, now, shift) {
            return Motion::Down(shift);
        }
        if lines_up(now, before, shift) {
            return Motion::Up(shift);
        }
    }
    Motion::Unknown
}

/// How much of a band of `rows` rows that did not change is believably
/// fixed. `row(0)` is the band's row nearest the scrolling middle, `row(1)`
/// the next one out. Rows at that inner edge that all look alike are given
/// up, and a band that is alike all through is no band.
fn firm(rows: usize, row: impl Fn(usize) -> u64) -> usize {
    let flat = (1..rows).take_while(|i| row(*i) == row(0)).count();
    if rows > 0 && flat + 1 == rows {
        0
    } else {
        rows - flat
    }
}

/// The long picture as it is collected.
pub struct Stitcher {
    width: usize,
    height: usize,
    /// The first frame, kept until the fixed bands are known.
    first: Vec<u8>,
    /// Rows at the top and bottom that do not scroll; known after the first
    /// pair of frames that moved.
    bands: Option<(usize, usize)>,
    /// The scrolling middle, every row of it seen so far, once.
    strip: Vec<u8>,
    /// Where the last accepted frame's middle starts in `strip`, in rows.
    position: usize,
    /// The last accepted frame: its row hashes, and the frame itself for the
    /// bottom band.
    last_hashes: Vec<u64>,
    last: Vec<u8>,
    full: bool,
    /// The frame offered last, joined or not (`offer`).
    offered: Vec<u8>,
}

impl Stitcher {
    /// A stitcher for frames `width` by `height` pixels. `None` for a size
    /// that is not a picture.
    pub fn new(width: usize, height: usize) -> Option<Stitcher> {
        (width > 0 && height > 0).then(|| Stitcher {
            width,
            height,
            first: Vec::new(),
            bands: None,
            strip: Vec::new(),
            position: 0,
            last_hashes: Vec::new(),
            last: Vec::new(),
            full: false,
            offered: Vec::new(),
        })
    }

    fn row(&self) -> usize {
        self.width * 4
    }

    /// The picture's height so far.
    pub fn total_height(&self) -> usize {
        match self.bands {
            None => {
                if self.first.is_empty() {
                    0
                } else {
                    self.height
                }
            }
            Some((top, bottom)) => top + self.strip.len() / self.row() + bottom,
        }
    }

    pub fn is_full(&self) -> bool {
        self.full
    }

    /// Offer a frame taken off a live screen (screenshot.md §9.7). **Only a
    /// frame that is, pixel for pixel, the one offered just before it is
    /// joined**; any other is `Moving` and is only remembered.
    ///
    /// A screen caught between two states is not a state. An application
    /// that scrolls by moving what it has and painting the newly exposed
    /// strip afterwards (Notepad does) can be caught with the strip still
    /// blank. Nothing in such a frame says so: the blank rows lie below the
    /// rows two frames are lined up on, so it lines up perfectly and its
    /// blank rows are joined as if they were the page. From there it goes
    /// one of two ways, both seen on the test machine -- a few blank rows
    /// stay in the picture across a line of text, or, with more of them,
    /// no later frame lines up with that one again and the picture stops
    /// growing. Two captures in a row that are identical were not taken
    /// mid-change, whatever the application and however it paints.
    ///
    /// The cost is one capture interval before a frame counts, and a region
    /// that never holds still -- a video, a spinner -- adds nothing at all,
    /// where a frame's 3% tolerance used to let a small animation through.
    pub fn offer(&mut self, frame: &[u8]) -> Step {
        if frame.len() != self.row() * self.height {
            return Step::WrongSize;
        }
        if self.offered != frame {
            self.offered.clear();
            self.offered.extend_from_slice(frame);
            return Step::Moving;
        }
        self.push(frame)
    }

    /// Take the next frame as it is. `offer` is the one for frames off a
    /// live screen; this joins whatever it is given.
    pub fn push(&mut self, frame: &[u8]) -> Step {
        if frame.len() != self.row() * self.height {
            return Step::WrongSize;
        }
        let hashes = row_hashes(frame, self.width);
        if self.first.is_empty() {
            self.first = frame.to_vec();
            self.last_hashes = hashes;
            return Step::First;
        }
        if self.full {
            return Step::Full;
        }

        // The fixed bands: as found on the first pair that moved, the same
        // from then on.
        let ((top, bottom), moved) = match self.bands {
            Some((top, bottom)) => {
                let middle = top..self.height - bottom;
                ((top, bottom), motion(&self.last_hashes[middle.clone()], &hashes[middle]))
            }
            None => {
                if hashes == self.last_hashes {
                    return Step::Unchanged;
                }
                let top = hashes.iter().zip(&self.last_hashes).take_while(|(a, b)| a == b).count();
                let bottom =
                    hashes.iter().rev().zip(self.last_hashes.iter().rev()).take_while(|(a, b)| a == b).count();
                // They cannot meet: the frames differ somewhere.
                let bottom = bottom.min(self.height - top);
                // First on the plain reading: every row that did not change
                // is a fixed band. If nothing lines up that way, on the
                // other one -- that the flat rows at a band's inner edge
                // are the page's own white space, which looks unchanged
                // while it scrolls. In that order, because a real header
                // very often *has* a flat edge, and taking it for page
                // would put rows that never move among the ones compared.
                let plain = (top, bottom);
                let trimmed =
                    (firm(top, |i| hashes[top - 1 - i]), firm(bottom, |i| hashes[self.height - bottom + i]));
                let try_with = |(top, bottom): (usize, usize)| {
                    let middle = top..self.height - bottom;
                    motion(&self.last_hashes[middle.clone()], &hashes[middle])
                };
                match try_with(plain) {
                    Motion::Unknown if trimmed != plain => (trimmed, try_with(trimmed)),
                    found => (plain, found),
                }
            }
        };
        let middle = top..self.height - bottom;

        let band = middle.len();
        let step = match moved {
            Motion::None => Step::Unchanged,
            Motion::Unknown => return Step::Lost,
            Motion::Up(shift) => {
                if self.bands.is_none() {
                    // Scrolling back before anything was collected below the
                    // first frame: there is nothing above it to go back to.
                    return Step::Lost;
                }
                self.position = self.position.saturating_sub(shift);
                Step::Back
            }
            Motion::Down(shift) => {
                if self.bands.is_none() {
                    // Now the bands are known, the first frame's middle is
                    // the start of the strip.
                    self.bands = Some((top, bottom));
                    self.strip = self.first[top * self.row()..(self.height - bottom) * self.row()].to_vec();
                    self.position = 0;
                }
                self.position += shift;
                let have = self.strip.len() / self.row();
                let reach = self.position + band;
                if reach <= have {
                    Step::Seen
                } else {
                    // Rows of this frame's middle that lie below what is held.
                    let from = have - self.position;
                    let room = MAX_HEIGHT.saturating_sub(top + have + bottom);
                    let take = (band - from).min(room);
                    let start = (top + from) * self.row();
                    self.strip.extend_from_slice(&frame[start..start + take * self.row()]);
                    if take < band - from {
                        self.full = true;
                        // The frame is not kept as the last one: its bottom
                        // band belongs under rows that did not fit.
                        return Step::Full;
                    }
                    Step::Added(take)
                }
            }
        };
        self.last = frame.to_vec();
        self.last_hashes = hashes;
        step
    }

    /// Row `y` of the picture so far.
    fn picture_row(&self, y: usize) -> &[u8] {
        let row = self.row();
        let Some((top, bottom)) = self.bands else { return &self.first[y * row..(y + 1) * row] };
        let strip_rows = self.strip.len() / row;
        if y < top {
            &self.first[y * row..(y + 1) * row]
        } else if y < top + strip_rows {
            &self.strip[(y - top) * row..(y - top + 1) * row]
        } else {
            let y = self.height - bottom + (y - top - strip_rows);
            &self.last[y * row..(y + 1) * row]
        }
    }

    /// A small copy of the picture so far, for the preview beside the
    /// selection: no wider than `max_width` and no taller than `max_height`,
    /// in proportion, nearest pixel. Its width, height and rows.
    pub fn thumbnail(&self, max_width: usize, max_height: usize) -> Option<(usize, usize, Vec<u8>)> {
        let total = self.total_height();
        if total == 0 || max_width == 0 || max_height == 0 {
            return None;
        }
        // The larger of the two reductions, as a fraction num/den <= 1.
        let (w, h) = if self.width * max_height >= total * max_width {
            (max_width.min(self.width), (total * max_width.min(self.width) / self.width).max(1))
        } else {
            ((self.width * max_height.min(total) / total).max(1), max_height.min(total))
        };
        let mut out = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            let source = self.picture_row(y * total / h);
            for x in 0..w {
                let at = (x * self.width / w) * 4;
                out.extend_from_slice(&source[at..at + 4]);
            }
        }
        Some((w, h, out))
    }

    /// The picture: its width, and its rows -- the top band, everything that
    /// scrolled past, the bottom band as it last was. `None` before any
    /// frame.
    pub fn finish(&self) -> Option<(u32, Vec<u8>)> {
        if self.first.is_empty() {
            return None;
        }
        let Some((top, bottom)) = self.bands else { return Some((self.width as u32, self.first.clone())) };
        let row = self.row();
        let mut out = Vec::with_capacity((top + bottom) * row + self.strip.len());
        out.extend_from_slice(&self.first[..top * row]);
        out.extend_from_slice(&self.strip);
        out.extend_from_slice(&self.last[(self.height - bottom) * row..]);
        Some((self.width as u32, out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pixels::tests::Lcg;

    const W: usize = 16;
    /// Frame height, and the fixed bands of the page used below.
    const H: usize = 120;
    const HEADER: usize = 10;
    const FOOTER: usize = 6;
    const VIEW: usize = H - HEADER - FOOTER;

    /// `rows` rows of noise: every row different from every other.
    fn noise(rows: usize, seed: u64) -> Vec<u8> {
        let mut g = Lcg(seed);
        (0..rows * W).flat_map(|_| { let v = g.next(); [v as u8, (v >> 8) as u8, (v >> 16) as u8, 0] }).collect()
    }

    /// A page 2000 rows long under a fixed header and over a fixed footer.
    struct Page {
        header: Vec<u8>,
        body: Vec<u8>,
        footer: Vec<u8>,
    }

    impl Page {
        fn new() -> Page {
            Page { header: noise(HEADER, 1), body: noise(2000, 2), footer: noise(FOOTER, 3) }
        }

        /// The frame seen with the body scrolled to row `y`.
        fn frame(&self, y: usize) -> Vec<u8> {
            let mut f = self.header.clone();
            f.extend_from_slice(&self.body[y * W * 4..(y + VIEW) * W * 4]);
            f.extend_from_slice(&self.footer);
            f
        }

        /// What the stitched picture must be after scrolling as far as `y`.
        fn expected(&self, y: usize) -> Vec<u8> {
            let mut f = self.header.clone();
            f.extend_from_slice(&self.body[..(y + VIEW) * W * 4]);
            f.extend_from_slice(&self.footer);
            f
        }
    }

    fn stitcher() -> Stitcher {
        Stitcher::new(W, H).unwrap()
    }

    #[test]
    fn scrolling_down_adds_exactly_the_rows_that_came_into_view() {
        let page = Page::new();
        let mut s = stitcher();
        assert_eq!(s.push(&page.frame(0)), Step::First);
        assert_eq!(s.total_height(), H);
        assert_eq!(s.push(&page.frame(30)), Step::Added(30));
        assert_eq!(s.push(&page.frame(75)), Step::Added(45));
        assert_eq!(s.push(&page.frame(76)), Step::Added(1));
        assert_eq!(s.total_height(), H + 76);
        let (width, picture) = s.finish().unwrap();
        assert_eq!(width as usize, W);
        assert_eq!(picture, page.expected(76));
    }

    #[test]
    fn the_fixed_header_and_footer_are_kept_once() {
        let page = Page::new();
        let mut s = stitcher();
        for y in [0, 40, 80, 120, 160] {
            s.push(&page.frame(y));
        }
        let (_, picture) = s.finish().unwrap();
        assert_eq!(picture.len() / (W * 4), HEADER + 160 + VIEW + FOOTER);
        let row = |i: usize| &picture[i * W * 4..(i + 1) * W * 4];
        assert_eq!(row(0), &page.header[..W * 4]);
        let last = picture.len() / (W * 4) - 1;
        assert_eq!(row(last), &page.footer[(FOOTER - 1) * W * 4..]);
        // The header's first row appears once in the whole picture.
        let copies = (0..=last).filter(|i| row(*i) == row(0)).count();
        assert_eq!(copies, 1);
        assert_eq!(picture, page.expected(160));
    }

    #[test]
    fn a_frame_that_did_not_move_adds_nothing() {
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(0));
        assert_eq!(s.push(&page.frame(0)), Step::Unchanged);
        s.push(&page.frame(20));
        assert_eq!(s.push(&page.frame(20)), Step::Unchanged);
        assert_eq!(s.finish().unwrap().1, page.expected(20));
    }

    #[test]
    fn scrolling_back_and_down_again_neither_repeats_nor_tears() {
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(0));
        assert_eq!(s.push(&page.frame(50)), Step::Added(50));
        assert_eq!(s.push(&page.frame(20)), Step::Back);
        assert_eq!(s.push(&page.frame(5)), Step::Back);
        assert_eq!(s.total_height(), H + 50, "going back loses nothing");
        // Down again over what is already held: nothing new until past it.
        assert_eq!(s.push(&page.frame(40)), Step::Seen);
        assert_eq!(s.push(&page.frame(70)), Step::Added(20));
        assert_eq!(s.finish().unwrap().1, page.expected(70));
    }

    #[test]
    fn a_frame_scrolled_too_far_to_overlap_is_dropped_not_joined() {
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(0));
        s.push(&page.frame(30));
        // A whole view further: nothing in common with the last frame.
        assert_eq!(s.push(&page.frame(30 + VIEW)), Step::Lost);
        assert_eq!(s.total_height(), H + 30, "nothing was added");
        // Too little in common is not trusted either (the minimum is 24 rows).
        assert_eq!(s.push(&page.frame(30 + VIEW - 10)), Step::Lost);
        // Twenty rows in common: more than an eighth of the band (13), still
        // under the twenty-four that are the least believed.
        assert_eq!(s.push(&page.frame(30 + VIEW - 20)), Step::Lost);
        // Scrolled back to within reach of the last good frame: it goes on.
        assert_eq!(s.push(&page.frame(60)), Step::Added(30));
        assert_eq!(s.finish().unwrap().1, page.expected(60));
    }

    #[test]
    fn a_page_that_repeats_is_taken_to_have_moved_the_least_and_downwards() {
        // Twenty rows, over and over: scrolled down by ten it lines up at a
        // shift of 10, 30, 50 and 70 -- and, the period being twice the
        // scroll, scrolling *up* by ten looks exactly the same.
        let period = noise(20, 31);
        let body: Vec<u8> = (0..20).flat_map(|_| period.clone()).collect();
        let frame = |y: usize| body[y * W * 4..(y + H) * W * 4].to_vec();
        let mut s = stitcher();
        s.push(&frame(0));
        // The smallest shift, and down before up: the least that could be
        // wrong is added.
        assert_eq!(s.push(&frame(10)), Step::Added(10));
        assert_eq!(s.total_height(), H + 10);
    }

    #[test]
    fn the_footer_is_the_last_frames_not_the_firsts() {
        // A status bar that is still while the first two frames are taken
        // and has changed by the third: a clock, a scroll position.
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(0));
        s.push(&page.frame(30));
        let later = noise(FOOTER, 41);
        let mut third = page.header.clone();
        third.extend_from_slice(&page.body[60 * W * 4..(60 + VIEW) * W * 4]);
        third.extend_from_slice(&later);
        assert_eq!(s.push(&third), Step::Added(30));
        let mut expected = page.header.clone();
        expected.extend_from_slice(&page.body[..(60 + VIEW) * W * 4]);
        expected.extend_from_slice(&later);
        assert_eq!(s.finish().unwrap().1, expected);
    }

    #[test]
    fn content_that_changed_rather_than_scrolled_is_dropped() {
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(0));
        s.push(&page.frame(30));
        // The same header and footer around a different body: a video frame,
        // a page that reloaded.
        let mut other = page.header.clone();
        other.extend_from_slice(&noise(VIEW, 77));
        other.extend_from_slice(&page.footer);
        assert_eq!(s.push(&other), Step::Lost);
        assert_eq!(s.finish().unwrap().1, page.expected(30));
    }

    #[test]
    fn a_blank_stretch_is_not_trusted_to_say_how_far_it_moved() {
        // Text, then a long stretch of one flat colour, then text again.
        let mut body = noise(40, 5);
        body.extend(std::iter::repeat([200u8, 200, 200, 0]).take(140 * W).flatten());
        body.extend(noise(200, 6));
        let frame = |y: usize| body[y * W * 4..(y + H) * W * 4].to_vec();
        let mut s = stitcher();
        s.push(&frame(0));
        // Scrolled by 80: what the two frames share is all blank, and blank
        // lines up with blank at 40 as well as at 80. Taking the first that
        // fits would join the picture 40 rows short, seamlessly.
        assert_eq!(s.push(&frame(80)), Step::Lost);
        assert_eq!(s.total_height(), H);
        // A smaller move keeps some of the text in the overlap: trusted.
        assert_eq!(s.push(&frame(20)), Step::Added(20));
        assert_eq!(s.finish().unwrap().1, body[..(20 + H) * W * 4].to_vec());
    }

    #[test]
    fn white_space_under_the_text_is_not_mistaken_for_a_fixed_footer() {
        // Both frames end in the same blank rows -- the page's own, which
        // scroll with it. Read as a footer they would leave too little of
        // the frame to match on.
        let mut body = noise(40, 5);
        body.extend(std::iter::repeat([200u8, 200, 200, 0]).take(140 * W).flatten());
        body.extend(noise(200, 6));
        let frame = |y: usize| body[y * W * 4..(y + H) * W * 4].to_vec();
        let mut s = stitcher();
        s.push(&frame(0));
        assert_eq!(s.push(&frame(20)), Step::Added(20));
        assert_eq!(s.push(&frame(30)), Step::Added(10));
        // On through the blank part and out the other side, in steps small
        // enough that text stays in the overlap.
        for y in [50, 70, 85, 100, 130] {
            assert!(matches!(s.push(&frame(y)), Step::Added(_) | Step::Lost), "y = {y}");
        }
        let (_, picture) = s.finish().unwrap();
        assert_eq!(picture, body[..picture.len()].to_vec(), "whatever was joined is the page, unbroken");
    }

    #[test]
    fn a_real_footer_under_white_space_keeps_only_its_firm_part() {
        // The page's white space sits right above a real fixed footer, so
        // everything from the white space down is unchanged between frames.
        let mut body = noise(40, 5);
        body.extend(std::iter::repeat([200u8, 200, 200, 0]).take(140 * W).flatten());
        let footer = noise(6, 8);
        let frame = |y: usize| {
            let mut f = body[y * W * 4..(y + H - 6) * W * 4].to_vec();
            f.extend_from_slice(&footer);
            f
        };
        let mut s = stitcher();
        s.push(&frame(0));
        // On the plain reading 80 rows are "footer" and the 40 left overlap
        // by 10: not enough. Giving the flat rows back to the page, it fits.
        assert_eq!(s.push(&frame(30)), Step::Added(30));
        let (_, picture) = s.finish().unwrap();
        let mut expected = body[..(30 + H - 6) * W * 4].to_vec();
        expected.extend_from_slice(&footer);
        assert_eq!(picture, expected, "the page down to where it was scrolled, and the footer once");
    }

    #[test]
    fn a_header_with_a_flat_edge_is_still_a_header() {
        // A fixed header whose bottom rows are plain padding -- as most are.
        let mut header = noise(6, 21);
        header.extend(std::iter::repeat([40u8, 40, 40, 0]).take(10 * W).flatten());
        let body = noise(600, 22);
        let frame = |y: usize| {
            let mut f = header.clone();
            f.extend_from_slice(&body[y * W * 4..(y + H - 16) * W * 4]);
            f
        };
        let mut s = stitcher();
        s.push(&frame(0));
        // A small first move: with the padding read as page it would still
        // line up (two rows out of a hundred disagree), and the bands would
        // be fixed wrongly for every frame after.
        assert_eq!(s.push(&frame(2)), Step::Added(2));
        assert_eq!(s.push(&frame(40)), Step::Added(38), "the padding was not taken for scrolling page");
        assert_eq!(s.push(&frame(90)), Step::Added(50));
        let mut expected = header.clone();
        expected.extend_from_slice(&body[..(90 + H - 16) * W * 4]);
        assert_eq!(s.finish().unwrap().1, expected);
    }

    #[test]
    fn a_band_keeps_its_firm_part_and_gives_up_its_flat_inner_edge() {
        // Rows from the inner edge outward: three alike, then two that differ.
        let rows = [7u64, 7, 7, 1, 2];
        assert_eq!(firm(5, |i| rows[i]), 3, "the two distinct rows and one of the alike ones");
        assert_eq!(firm(5, |_| 7), 0, "alike all through: not a band");
        assert_eq!(firm(1, |_| 7), 0);
        assert_eq!(firm(0, |_| 7), 0);
        let distinct = [1u64, 2, 3];
        assert_eq!(firm(3, |i| distinct[i]), 3);
    }

    #[test]
    fn a_caret_blinking_in_the_overlap_does_not_lose_the_frame() {
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(0));
        let mut blink = page.frame(30);
        // One row of the overlap differs.
        for b in &mut blink[(HEADER + 5) * W * 4..(HEADER + 6) * W * 4] {
            *b ^= 0xFF;
        }
        assert_eq!(s.push(&blink), Step::Added(30));
    }

    #[test]
    fn with_no_fixed_bands_the_whole_frame_scrolls() {
        let body = noise(600, 9);
        let frame = |y: usize| body[y * W * 4..(y + H) * W * 4].to_vec();
        let mut s = stitcher();
        s.push(&frame(0));
        assert_eq!(s.push(&frame(50)), Step::Added(50));
        assert_eq!(s.push(&frame(110)), Step::Added(60));
        assert_eq!(s.finish().unwrap().1, body[..(110 + H) * W * 4].to_vec());
    }

    #[test]
    fn it_stops_at_the_height_limit_and_keeps_what_fitted() {
        let tall = 256usize;
        let body = noise(MAX_HEIGHT + 2000, 11);
        let frame = |y: usize| body[y * W * 4..(y + tall) * W * 4].to_vec();
        let mut s = Stitcher::new(W, tall).unwrap();
        s.push(&frame(0));
        let mut y = 0;
        let mut last = Step::First;
        while y + 200 + tall <= MAX_HEIGHT + 1500 && last != Step::Full {
            y += 200;
            last = s.push(&frame(y));
        }
        assert_eq!(last, Step::Full);
        assert!(s.is_full());
        assert_eq!(s.total_height(), MAX_HEIGHT);
        assert_eq!(s.finish().unwrap().1, body[..MAX_HEIGHT * W * 4].to_vec(), "the first 20000 rows, unbroken");
        assert_eq!(s.push(&frame(y + 100)), Step::Full, "and nothing after");
        assert_eq!(s.total_height(), MAX_HEIGHT);
    }

    #[test]
    fn the_thumbnail_is_the_picture_in_proportion_within_its_box() {
        let page = Page::new();
        let mut s = stitcher();
        assert!(s.thumbnail(8, 100).is_none(), "nothing yet");
        s.push(&page.frame(0));
        // 16 x 120: limited by the width.
        let (w, h, px) = s.thumbnail(8, 100).unwrap();
        assert_eq!((w, h, px.len()), (8, 60, 8 * 60 * 4));
        for y in [40, 80, 120] {
            s.push(&page.frame(y));
        }
        // 16 x 240: now limited by the height.
        let (w, h, px) = s.thumbnail(8, 60).unwrap();
        assert_eq!((w, h), (4, 60));
        // Its rows are the picture's, top to bottom: first the header's first
        // row, last a row of the footer; each pixel one of that row's.
        let (_, whole) = s.finish().unwrap();
        assert_eq!(px[..4], whole[..4]);
        let last_source = 59 * 240 / 60;
        assert_eq!(px[59 * 4 * 4..59 * 4 * 4 + 4], whole[last_source * W * 4..last_source * W * 4 + 4]);
        assert_eq!(px[59 * 4 * 4 + 4..59 * 4 * 4 + 8], whole[last_source * W * 4 + 16..last_source * W * 4 + 20]);
        // A box bigger than the picture does not enlarge it.
        assert_eq!(s.thumbnail(500, 5000).map(|t| (t.0, t.1)), Some((16, 240)));
    }

    #[test]
    fn one_frame_alone_is_the_picture() {
        let page = Page::new();
        let mut s = stitcher();
        assert!(s.finish().is_none());
        assert_eq!(s.total_height(), 0);
        s.push(&page.frame(0));
        assert_eq!(s.finish().unwrap().1, page.frame(0));
    }

    #[test]
    fn a_frame_of_another_size_is_ignored() {
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(0));
        assert_eq!(s.push(&page.frame(0)[..W * 4 * (H - 1)]), Step::WrongSize);
        assert_eq!(s.push(&[]), Step::WrongSize);
        assert!(Stitcher::new(0, 10).is_none());
        assert!(Stitcher::new(10, 0).is_none());
    }

    #[test]
    fn scrolling_back_before_anything_was_added_is_not_a_place_to_go() {
        let page = Page::new();
        let mut s = stitcher();
        s.push(&page.frame(50));
        assert_eq!(s.push(&page.frame(20)), Step::Lost, "there is nothing above the first frame");
        assert_eq!(s.push(&page.frame(80)), Step::Added(30));
        assert_eq!(s.finish().unwrap().1[HEADER * W * 4..(HEADER + 5) * W * 4], page.body[50 * W * 4..55 * W * 4]);
    }

    /// `page` scrolled to `y`, caught before the strip that just came into
    /// view was painted to the bottom: its last `unpainted` rows are still
    /// the window's blank ground.
    fn half_painted(page: &Page, y: usize, unpainted: usize) -> Vec<u8> {
        let mut f = page.frame(y);
        let end = (HEADER + VIEW) * W * 4;
        for b in &mut f[end - unpainted * W * 4..end] {
            *b = 0xff;
        }
        f
    }

    /// What a capture timer sees of an application that scrolls `by` rows
    /// at a time and paints the exposed strip late: after each scroll one
    /// frame with `unpainted` rows still blank, then the finished frame
    /// three times over.
    fn late_painter(page: &Page, by: usize, scrolls: usize, unpainted: usize) -> Vec<Vec<u8>> {
        let mut frames = vec![page.frame(0); 3];
        for n in 1..=scrolls {
            frames.push(half_painted(page, n * by, unpainted));
            frames.extend(vec![page.frame(n * by); 3]);
        }
        frames
    }

    fn blank_rows(picture: &[u8]) -> usize {
        picture.chunks_exact(W * 4).filter(|row| row.chunks_exact(4).all(|px| px[..3] == [0xff, 0xff, 0xff])).count()
    }

    /// Defect 3, first form (the test machine, Notepad, a notch every
    /// 350 ms): the picture came out the right height with every line in
    /// it, and with two bands of blank rows across half a line of text.
    /// Two blank rows are inside what `lines_up` forgives, so the frames
    /// after a half-painted one are joined to it and its blank rows stay.
    #[test]
    fn a_frame_caught_half_painted_leaves_no_blank_rows_in_the_picture() {
        let page = Page::new();
        let frames = late_painter(&page, 20, 6, 2);
        // What `push` alone does with them -- the defect, kept as the
        // statement of what `offer` is for.
        let mut raw = stitcher();
        for f in &frames {
            raw.push(f);
        }
        assert_eq!(raw.total_height(), H + 120, "the height was right on the test machine too");
        let (_, torn) = raw.finish().unwrap();
        assert!(blank_rows(&torn) > 0 && torn != page.expected(120), "this sequence no longer shows the defect");

        let mut s = stitcher();
        let steps: Vec<Step> = frames.iter().map(|f| s.offer(f)).collect();
        assert!(!steps.contains(&Step::Lost), "{steps:?}");
        assert_eq!(steps.iter().filter(|s| matches!(s, Step::Added(20))).count(), 6, "{steps:?}");
        let (_, picture) = s.finish().unwrap();
        assert_eq!(blank_rows(&picture), 0);
        assert_eq!(picture, page.expected(120));
    }

    /// Defect 3, second form (a notch every 600 ms): five notches were
    /// joined and nothing after them, 101 of 128 frames dropped, and the
    /// picture ended in blank rows. With more rows unpainted than
    /// `lines_up` forgives, no later frame lines up with the half-painted
    /// one, and it stays the frame everything is compared against.
    #[test]
    fn a_frame_caught_half_painted_does_not_stop_the_picture_growing() {
        let page = Page::new();
        let frames = late_painter(&page, 20, 6, 12);
        let mut raw = stitcher();
        let lost = frames.iter().filter(|f| raw.push(f) == Step::Lost).count();
        assert!(lost > frames.len() / 2, "only {lost} of {} dropped: this sequence no longer shows the defect", frames.len());
        assert_eq!(raw.total_height(), H + 20, "it stuck after the first notch");
        let (_, stuck) = raw.finish().unwrap();
        assert_eq!(blank_rows(&stuck), 12, "and ended in the blank rows");

        let mut s = stitcher();
        let steps: Vec<Step> = frames.iter().map(|f| s.offer(f)).collect();
        assert!(!steps.contains(&Step::Lost), "{steps:?}");
        assert_eq!(s.total_height(), H + 120);
        let (_, picture) = s.finish().unwrap();
        assert_eq!(picture, page.expected(120));
    }

    /// The rule itself: a frame counts when it is the one offered just
    /// before it, and only then.
    #[test]
    fn only_a_frame_seen_twice_running_is_joined() {
        let page = Page::new();
        let mut s = stitcher();
        assert_eq!(s.offer(&page.frame(0)), Step::Moving);
        assert_eq!(s.total_height(), 0, "one capture alone is not a picture yet");
        assert_eq!(s.offer(&page.frame(0)), Step::First);
        // Scrolling: every frame differs from the one before, none joined.
        for y in [5, 12, 20] {
            assert_eq!(s.offer(&page.frame(y)), Step::Moving, "at {y}");
        }
        assert_eq!(s.total_height(), H);
        // It stops: the second look at the same frame joins it.
        assert_eq!(s.offer(&page.frame(30)), Step::Moving);
        assert_eq!(s.offer(&page.frame(30)), Step::Added(30));
        // Still there: nothing new, and not "moving".
        assert_eq!(s.offer(&page.frame(30)), Step::Unchanged);
        // A frame seen twice, but not twice running, is not steady.
        assert_eq!(s.offer(&page.frame(40)), Step::Moving);
        assert_eq!(s.offer(&page.frame(50)), Step::Moving);
        assert_eq!(s.offer(&page.frame(40)), Step::Moving);
        assert_eq!(s.total_height(), H + 30);
        assert_eq!(s.offer(&page.frame(40)), Step::Added(10));
        // The fourth byte is not part of the picture, but a frame of
        // another size is still said to be that.
        assert_eq!(s.offer(&page.frame(0)[4..]), Step::WrongSize);
        assert_eq!(s.finish().unwrap().1, page.expected(40));
    }
}
