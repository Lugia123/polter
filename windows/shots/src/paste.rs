//! Which clipboard format a paste is answered from, and when a saved image is
//! reused instead of saved again.

use std::path::{Path, PathBuf};

/// What is on the clipboard, as three independent facts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Available {
    /// Non-empty text.
    pub text: bool,
    /// A file list (`CF_HDROP`).
    pub files: bool,
    /// A bitmap.
    pub image: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Text,
    Files,
    Image,
    /// Nothing this host can paste. The read is answered `UNAVAILABLE`, which
    /// is what lets `ctrl+v` fall through to the pty.
    Nothing,
}

/// Text, then files, then an image.
///
/// **Text wins even when an image is there too**: copying from a web page puts
/// both on the clipboard and the person copied the words.
///
/// **`paste_image = false` is today's behaviour exactly**: text or nothing.
/// It switches off the file list as well as the image, because before this
/// existed a clipboard holding only files answered `UNAVAILABLE` and `ctrl+v`
/// reached the program in the terminal -- which is what the setting promises
/// to give back.
pub fn choose(on: Available, paste_image: bool) -> Source {
    match on {
        Available { text: true, .. } => Source::Text,
        _ if !paste_image => Source::Nothing,
        Available { files: true, .. } => Source::Files,
        Available { image: true, .. } => Source::Image,
        _ => Source::Nothing,
    }
}

/// The last image saved off the clipboard, keyed by the clipboard's sequence
/// number, so pasting the same image twice writes one file.
///
/// A screenshot is remembered the same way, at the moment it is put on the
/// clipboard, together with the line that goes with it and, for a long one,
/// its tiles -- so a paste made later, by hand, names the screenshot's own
/// files and can send that line after them. **That paste is the only way a
/// screenshot reaches a terminal**: finishing one pastes nothing.
#[derive(Debug, Default)]
pub struct Reuse {
    last: Option<(u32, PathBuf, Vec<PathBuf>, Option<String>)>,
}

/// What [`Reuse::lookup`] found: the file, the tiles it was cut into if it
/// was a long screenshot (none otherwise), and the line that goes with it if
/// it was a screenshot that has one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Saved<'a> {
    pub path: &'a Path,
    pub tiles: &'a [PathBuf],
    pub note: Option<&'a str>,
}

/// One of the pastes that follow the first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Piece<'a> {
    /// A tile's path.
    Tile(&'a Path),
    /// The line of text, last.
    Line(&'a str),
}

/// What goes between one pasted piece and the next (#1198). **Each piece is a
/// paste of its own, and the line editor behind them joins what they
/// carry**: the path and the `[screenshot annotations …]` line, or two
/// tiles' paths, arrived as `…752.png[…` and `…-1.png…-2.png`. A path is
/// followed by this when anything follows it; the line, which is last, has
/// nothing before it. One place to change.
pub const SEPARATOR: &str = " ";

/// One piece of text to paste, and when (milliseconds after the first).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Text {
    pub delay_ms: u64,
    /// `true` for the annotation line (or the long screenshot's), `false`
    /// for a tile's path: for the log.
    pub is_line: bool,
    pub text: String,
}

impl<'a> Saved<'a> {
    /// The text of each paste, ready to send: `quote` turns a path into what
    /// a shell takes. The first is what answers the paste itself. **Between
    /// any two adjacent pieces, when the texts are put one after the other,
    /// there is [`SEPARATOR`]**: after every path that something follows,
    /// and never before the line.
    pub fn texts(&self, quote: impl Fn(&Path) -> String) -> (String, Vec<Text>) {
        let (first, later) = self.pastes();
        let mut pieces: Vec<Text> = later
            .iter()
            .map(|(delay_ms, p)| match p {
                Piece::Tile(path) => Text { delay_ms: *delay_ms, is_line: false, text: quote(path) },
                Piece::Line(line) => Text { delay_ms: *delay_ms, is_line: true, text: (*line).to_string() },
            })
            .collect();
        let mut first = quote(first);
        // A path is followed by the separator when anything follows it.
        if !pieces.is_empty() {
            first.push_str(SEPARATOR);
        }
        let n = pieces.len();
        for (i, p) in pieces.iter_mut().enumerate() {
            if !p.is_line && i + 1 < n {
                p.text.push_str(SEPARATOR);
            }
        }
        (first, pieces)
    }

    /// What pasting this is: the path that answers the paste itself, and
    /// what follows it, each with how long after the paste it is due.
    ///
    /// An ordinary image is its own path, then its line if it has one. A
    /// long screenshot is its tiles instead of itself -- a CLI shrinks
    /// anything much over 2000 px, and the whole picture shrunk cannot be
    /// read -- at most [`MAX_TILES_PASTED`] of them, one every
    /// [`SECOND_PASTE_DELAY_MS`], and then the line, which is there when
    /// tiles were left out and says how many and where the whole picture is.
    ///
    /// **Every piece is a paste of its own**, for the reason the line is
    /// (see `SECOND_PASTE_DELAY_MS`).
    pub fn pastes(&self) -> (&'a Path, Vec<(u64, Piece<'a>)>) {
        let tiles = &self.tiles[..self.tiles.len().min(MAX_TILES_PASTED)];
        let (first, rest) = match tiles.split_first() {
            Some((first, rest)) => (first.as_path(), rest),
            None => (self.path, tiles),
        };
        let mut later: Vec<(u64, Piece<'a>)> = rest
            .iter()
            .enumerate()
            .map(|(i, t)| (SECOND_PASTE_DELAY_MS * (i as u64 + 1), Piece::Tile(t.as_path())))
            .collect();
        if let Some(note) = self.note {
            later.push((SECOND_PASTE_DELAY_MS * (later.len() as u64 + 1), Piece::Line(note)));
        }
        (first, later)
    }
}

impl Reuse {
    pub const fn new() -> Self {
        Reuse { last: None }
    }

    /// The path saved for clipboard state `seq`, if that is still the state
    /// and the file is still there -- and so is every tile a paste would
    /// name. One of them deleted and the answer is `None`, which has the
    /// caller save the clipboard's image afresh: a path to nothing is worse
    /// than a second file.
    ///
    /// **`seq == 0` never matches**, because [`Reuse::remember`] never keeps
    /// one.
    pub fn lookup(&self, seq: u32) -> Option<Saved<'_>> {
        match &self.last {
            Some((s, p, tiles, note))
                if *s == seq && p.is_file() && tiles.iter().take(MAX_TILES_PASTED).all(|t| t.is_file()) =>
            {
                Some(Saved { path: p, tiles, note: note.as_deref() })
            }
            _ => None,
        }
    }

    /// Record that clipboard state `seq` was saved to `path`, cut into
    /// `tiles` if it is a long screenshot (empty otherwise).
    ///
    /// **`seq == 0` records nothing and forgets what was there.**
    /// `GetClipboardSequenceNumber` returns 0 when it cannot tell (no access
    /// to the window station's clipboard), and "I do not know" must not read
    /// as "unchanged since the last 0".
    pub fn remember(&mut self, seq: u32, path: PathBuf, tiles: Vec<PathBuf>, note: Option<String>) {
        self.last = (seq != 0).then_some((seq, path, tiles, note));
    }
}

/// How long after the image's path the line describing its annotations is
/// pasted, in milliseconds.
///
/// **They are two pastes, and the gap is what makes them two.** With none,
/// the program in the terminal receives the path and the line in one read
/// and has no way to treat the first as an attachment and the second as
/// text. macOS waits 0.15 s for the same reason; this is that number.
pub const SECOND_PASTE_DELAY_MS: u64 = 150;

/// The most tiles of a long screenshot that one paste puts into a pane
/// (§9.6). More than this and the line that follows says how many there are
/// and where the whole picture is.
pub const MAX_TILES_PASTED: usize = 8;

/// Things to do later, each addressed to a target and due at a time.
///
/// For the second paste: `T` is the identity of the pane the first paste
/// went into. **An identity, not "wherever the keyboard is by then"** -- the
/// host looks the pane up again when the entry falls due, and a pane that
/// has been closed in the meantime resolves to nothing, so the text is
/// dropped rather than typed into whatever took its place.
#[derive(Debug)]
pub struct Later<T> {
    waiting: Vec<(u64, T, String)>,
}

impl<T> Default for Later<T> {
    fn default() -> Self {
        Later { waiting: Vec::new() }
    }
}

impl<T> Later<T> {
    pub const fn new() -> Self {
        Later { waiting: Vec::new() }
    }

    /// Queue `text` for `target`, due `delay_ms` after `now_ms`.
    pub fn push(&mut self, now_ms: u64, delay_ms: u64, target: T, text: String) {
        self.waiting.push((now_ms.saturating_add(delay_ms), target, text));
    }

    /// Remove and return everything due at `now_ms`, in the order queued.
    pub fn take_due(&mut self, now_ms: u64) -> Vec<(T, String)> {
        let mut due = Vec::new();
        let mut rest = Vec::new();
        for (at, target, text) in self.waiting.drain(..) {
            if at <= now_ms {
                due.push((target, text));
            } else {
                rest.push((at, target, text));
            }
        }
        self.waiting = rest;
        due
    }

    /// Drop everything still waiting whose target `gone` says yes to.
    ///
    /// For a second paste into a pane whose first is still arriving: the
    /// second starts the pieces again from the first, and what was left of
    /// the earlier run would otherwise arrive in between them.
    pub fn forget(&mut self, gone: impl Fn(&T) -> bool) -> usize {
        let before = self.waiting.len();
        self.waiting.retain(|(_, target, _)| !gone(target));
        before - self.waiting.len()
    }

    /// How long from `now_ms` until the next entry is due: 0 when one is
    /// already, `None` when nothing is waiting.
    pub fn next_in(&self, now_ms: u64) -> Option<u64> {
        self.waiting.iter().map(|(at, _, _)| at.saturating_sub(now_ms)).min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::Scratch;

    fn on(text: bool, files: bool, image: bool) -> Available {
        Available { text, files, image }
    }

    #[test]
    fn text_wins_over_files_and_images() {
        assert_eq!(choose(on(true, true, true), true), Source::Text);
        assert_eq!(choose(on(true, false, true), true), Source::Text);
        assert_eq!(choose(on(true, true, false), true), Source::Text);
    }

    #[test]
    fn files_win_over_an_image() {
        assert_eq!(choose(on(false, true, true), true), Source::Files);
        assert_eq!(choose(on(false, true, false), true), Source::Files);
    }

    #[test]
    fn an_image_alone_is_pasted() {
        assert_eq!(choose(on(false, false, true), true), Source::Image);
    }

    #[test]
    fn an_empty_clipboard_is_nothing() {
        assert_eq!(choose(on(false, false, false), true), Source::Nothing);
    }

    #[test]
    fn switched_off_it_is_text_or_nothing_for_every_clipboard() {
        for files in [false, true] {
            for image in [false, true] {
                assert_eq!(choose(on(true, files, image), false), Source::Text);
                assert_eq!(choose(on(false, files, image), false), Source::Nothing);
            }
        }
    }

    #[test]
    fn the_second_paste_waits_its_delay() {
        let mut q: Later<u64> = Later::new();
        assert_eq!(q.next_in(1000), None);
        q.push(1000, SECOND_PASTE_DELAY_MS, 7, "note".into());
        assert_eq!(q.next_in(1000), Some(SECOND_PASTE_DELAY_MS));
        assert!(q.take_due(1000).is_empty(), "not in the same instant as the first paste");
        assert!(q.take_due(1000 + SECOND_PASTE_DELAY_MS - 1).is_empty());
        assert_eq!(q.next_in(1000 + SECOND_PASTE_DELAY_MS - 1), Some(1));
        assert_eq!(q.take_due(1000 + SECOND_PASTE_DELAY_MS), vec![(7, "note".to_string())]);
        assert_eq!(q.next_in(2000), None);
        assert!(q.take_due(9999).is_empty(), "delivered once");
    }

    #[test]
    fn the_delay_is_long_enough_to_be_two_pastes() {
        // The measured gap that was the defect: 0 ms in one path, 12 in the other.
        assert!(SECOND_PASTE_DELAY_MS >= 100);
    }

    #[test]
    fn each_entry_keeps_its_own_target_and_its_own_time() {
        let mut q: Later<u64> = Later::new();
        q.push(1000, 150, 7, "for seven".into());
        q.push(1100, 150, 9, "for nine".into());
        assert_eq!(q.next_in(1000), Some(150), "the timer is set for the nearest, not the furthest");
        assert_eq!(q.take_due(1150), vec![(7, "for seven".to_string())]);
        assert_eq!(q.next_in(1150), Some(100));
        assert_eq!(q.take_due(1250), vec![(9, "for nine".to_string())]);
    }

    #[test]
    fn everything_due_comes_out_in_the_order_it_went_in() {
        let mut q: Later<u64> = Later::new();
        q.push(1000, 150, 7, "a".into());
        q.push(1001, 150, 7, "b".into());
        q.push(5000, 150, 8, "later".into());
        assert_eq!(q.take_due(3000), vec![(7, "a".to_string()), (7, "b".to_string())]);
        assert_eq!(q.next_in(3000), Some(2150));
        assert_eq!(q.next_in(6000), Some(0), "overdue is due now, not a negative wait");
    }

    #[test]
    fn the_same_sequence_number_reuses_the_file() {
        let s = Scratch::new("reuse");
        std::fs::create_dir_all(&s.0).unwrap();
        let p = s.0.join("a.png");
        std::fs::write(&p, b"x").unwrap();
        let mut r = Reuse::new();
        assert_eq!(r.lookup(7), None);
        r.remember(7, p.clone(), Vec::new(), None);
        assert_eq!(r.lookup(7), Some(Saved { path: &p, tiles: &[], note: None }));
        assert_eq!(r.lookup(8), None, "the clipboard changed");
    }

    #[test]
    fn a_screenshots_annotation_line_comes_back_with_its_file() {
        let s = Scratch::new("note");
        std::fs::create_dir_all(&s.0).unwrap();
        let p = s.0.join("a.png");
        std::fs::write(&p, b"x").unwrap();
        let mut r = Reuse::new();
        r.remember(7, p.clone(), Vec::new(), Some("[notes] 1".into()));
        assert_eq!(r.lookup(7), Some(Saved { path: &p, tiles: &[], note: Some("[notes] 1") }));
        // The next thing saved is not a screenshot and has no line.
        r.remember(9, p.clone(), Vec::new(), None);
        assert_eq!(r.lookup(9), Some(Saved { path: &p, tiles: &[], note: None }));
    }

    /// Finishing a screenshot pastes nothing, so this is the only way one
    /// reaches a terminal -- and the person may paste it into several.
    #[test]
    fn every_paste_of_a_screenshot_gives_the_file_and_the_line() {
        let s = Scratch::new("again");
        std::fs::create_dir_all(&s.0).unwrap();
        let p = s.0.join("a.png");
        std::fs::write(&p, b"x").unwrap();
        let mut r = Reuse::new();
        r.remember(7, p.clone(), Vec::new(), Some("[notes] 1".into()));
        let first = r.lookup(7).map(|f| (f.pastes().0.to_path_buf(), f.note.map(str::to_string)));
        let second = r.lookup(7).map(|f| (f.pastes().0.to_path_buf(), f.note.map(str::to_string)));
        assert_eq!(first, Some((p, Some("[notes] 1".to_string()))));
        assert_eq!(second, first, "looking it up does not use it up");
    }

    /// What finishing a long screenshot used to send by itself, a paste
    /// sends now: the same paths at the same times.
    #[test]
    fn a_long_screenshot_is_pasted_as_its_tiles_one_at_a_time() {
        let whole = PathBuf::from("a.png");
        let tiles: Vec<PathBuf> = (1..=6).map(|i| PathBuf::from(format!("a-{i}.png"))).collect();
        let saved = Saved { path: &whole, tiles: &tiles, note: None };
        let (first, later) = saved.pastes();
        assert_eq!(first, tiles[0].as_path(), "the first tile answers the paste, not the whole picture");
        let want: Vec<(u64, Piece)> =
            (1..6).map(|i| (SECOND_PASTE_DELAY_MS * i as u64, Piece::Tile(tiles[i].as_path()))).collect();
        assert_eq!(later, want);
    }

    #[test]
    fn past_eight_tiles_the_rest_are_left_out_and_the_line_comes_last() {
        let whole = PathBuf::from("a.png");
        let tiles: Vec<PathBuf> = (1..=12).map(|i| PathBuf::from(format!("a-{i}.png"))).collect();
        let saved = Saved { path: &whole, tiles: &tiles, note: Some("12 tiles, first 8 pasted") };
        let (first, later) = saved.pastes();
        assert_eq!(first, tiles[0].as_path());
        assert_eq!(later.len(), 8, "seven more tiles and the line");
        assert_eq!(later[6], (SECOND_PASTE_DELAY_MS * 7, Piece::Tile(tiles[7].as_path())));
        assert_eq!(later[7], (SECOND_PASTE_DELAY_MS * 8, Piece::Line("12 tiles, first 8 pasted")));
        assert!(!later.iter().any(|(_, p)| *p == Piece::Tile(tiles[8].as_path())), "the ninth is not pasted");
    }

    #[test]
    fn an_ordinary_screenshot_is_its_path_and_then_its_line() {
        let whole = PathBuf::from("a.png");
        let plain = Saved { path: &whole, tiles: &[], note: None };
        assert_eq!(plain.pastes(), (whole.as_path(), vec![]));
        let noted = Saved { path: &whole, tiles: &[], note: Some("[notes] 1") };
        assert_eq!(noted.pastes(), (whole.as_path(), vec![(SECOND_PASTE_DELAY_MS, Piece::Line("[notes] 1"))]));
    }

    #[test]
    fn a_long_screenshot_missing_a_tile_it_would_paste_is_not_reused() {
        let s = Scratch::new("tiles");
        std::fs::create_dir_all(&s.0).unwrap();
        let whole = s.0.join("a.png");
        let tiles: Vec<PathBuf> = (1..=10).map(|i| s.0.join(format!("a-{i}.png"))).collect();
        for f in tiles.iter().chain([&whole]) {
            std::fs::write(f, b"x").unwrap();
        }
        let mut r = Reuse::new();
        r.remember(7, whole.clone(), tiles.clone(), None);
        assert_eq!(r.lookup(7).map(|f| f.tiles.len()), Some(10));
        // The tenth is never pasted, so losing it loses nothing.
        std::fs::remove_file(&tiles[9]).unwrap();
        assert!(r.lookup(7).is_some());
        std::fs::remove_file(&tiles[2]).unwrap();
        assert_eq!(r.lookup(7), None, "a path to a file that is gone is not pasted");
    }

    /// A second paste into a pane whose tiles are still arriving starts them
    /// again; what was left of the first run must not land in between. A
    /// different pane's are its own.
    #[test]
    fn pasting_again_into_the_same_pane_drops_what_the_first_paste_still_owed() {
        let mut q: Later<u64> = Later::new();
        for i in 1..=3u64 {
            q.push(1000, SECOND_PASTE_DELAY_MS * i, 7, format!("first run, tile {}", i + 1));
        }
        q.push(1000, SECOND_PASTE_DELAY_MS * 2, 9, "another pane".into());
        assert_eq!(q.take_due(1150), vec![(7, "first run, tile 2".to_string())]);
        // Pane 7 is pasted into again at 1200.
        assert_eq!(q.forget(|pane| *pane == 7), 2);
        q.push(1200, SECOND_PASTE_DELAY_MS, 7, "second run, tile 2".into());
        assert_eq!(
            q.take_due(9999),
            vec![(9, "another pane".to_string()), (7, "second run, tile 2".to_string())],
            "pane 9 still gets what it was owed"
        );
        assert_eq!(q.forget(|pane| *pane == 7), 0);
    }

    #[test]
    fn a_file_that_was_deleted_is_not_reused() {
        let s = Scratch::new("gone");
        std::fs::create_dir_all(&s.0).unwrap();
        let p = s.0.join("a.png");
        std::fs::write(&p, b"x").unwrap();
        let mut r = Reuse::new();
        r.remember(7, p.clone(), Vec::new(), None);
        std::fs::remove_file(&p).unwrap();
        assert_eq!(r.lookup(7), None);
    }

    #[test]
    fn sequence_zero_means_unknown_and_never_matches() {
        let s = Scratch::new("zero");
        std::fs::create_dir_all(&s.0).unwrap();
        let p = s.0.join("a.png");
        std::fs::write(&p, b"x").unwrap();
        let mut r = Reuse::new();
        r.remember(0, p.clone(), Vec::new(), None);
        assert_eq!(r.lookup(0), None);
        // And an unknown reading forgets the known one rather than keeping a
        // path that may belong to an older clipboard.
        r.remember(7, p.clone(), Vec::new(), None);
        r.remember(0, p, Vec::new(), None);
        assert_eq!(r.lookup(7), None);
    }

    /// #1198: the pieces, laid end to end the way the line editor sees them,
    /// are separated: a path, a space, the line; tile, space, tile.
    #[test]
    fn adjacent_pieces_are_separated_and_the_line_has_no_leading_space() {
        let q = |p: &Path| p.display().to_string();
        let whole = PathBuf::from("C:\\s\\752.png");
        let plain = Saved { path: &whole, tiles: &[], note: None };
        assert_eq!(plain.texts(q), ("C:\\s\\752.png".to_string(), vec![]), "nothing follows: nothing added");
        let noted = Saved { path: &whole, tiles: &[], note: Some("[notes] 1") };
        let (first, later) = noted.texts(q);
        assert_eq!(first, "C:\\s\\752.png ");
        assert_eq!(later.len(), 1);
        assert_eq!(later[0].text, "[notes] 1");
        assert!(later[0].is_line);
        let tiles: Vec<PathBuf> = (1..=3).map(|i| PathBuf::from(format!("C:\\s\\752-{i}.png"))).collect();
        let long = Saved { path: &whole, tiles: &tiles, note: Some("[long] 3") };
        let (first, later) = long.texts(q);
        let all: String = std::iter::once(first).chain(later.iter().map(|t| t.text.clone())).collect();
        assert_eq!(all, "C:\\s\\752-1.png C:\\s\\752-2.png C:\\s\\752-3.png [long] 3");
        // Without a line the last tile has nothing after it.
        let bare = Saved { path: &whole, tiles: &tiles, note: None };
        let (first, later) = bare.texts(q);
        let all: String = std::iter::once(first).chain(later.iter().map(|t| t.text.clone())).collect();
        assert_eq!(all, "C:\\s\\752-1.png C:\\s\\752-2.png C:\\s\\752-3.png");
    }
}
