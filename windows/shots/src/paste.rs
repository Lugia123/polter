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
/// clipboard, together with the line describing its annotations -- so a paste
/// made later, by hand, names the screenshot's own file and can send that
/// line after it.
#[derive(Debug, Default)]
pub struct Reuse {
    last: Option<(u32, PathBuf, Option<String>)>,
}

/// What [`Reuse::lookup`] found: the file, and the annotation line that goes
/// with it if it was a screenshot that had annotations.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Saved<'a> {
    pub path: &'a Path,
    pub note: Option<&'a str>,
}

impl Reuse {
    pub const fn new() -> Self {
        Reuse { last: None }
    }

    /// The path saved for clipboard state `seq`, if that is still the state
    /// and the file is still there.
    ///
    /// **`seq == 0` never matches**, because [`Reuse::remember`] never keeps
    /// one.
    pub fn lookup(&self, seq: u32) -> Option<Saved<'_>> {
        match &self.last {
            Some((s, p, note)) if *s == seq && p.is_file() => Some(Saved { path: p, note: note.as_deref() }),
            _ => None,
        }
    }

    /// Record that clipboard state `seq` was saved to `path`.
    ///
    /// **`seq == 0` records nothing and forgets what was there.**
    /// `GetClipboardSequenceNumber` returns 0 when it cannot tell (no access
    /// to the window station's clipboard), and "I do not know" must not read
    /// as "unchanged since the last 0".
    pub fn remember(&mut self, seq: u32, path: PathBuf, note: Option<String>) {
        self.last = (seq != 0).then_some((seq, path, note));
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
        r.remember(7, p.clone(), None);
        assert_eq!(r.lookup(7), Some(Saved { path: &p, note: None }));
        assert_eq!(r.lookup(8), None, "the clipboard changed");
    }

    #[test]
    fn a_screenshots_annotation_line_comes_back_with_its_file() {
        let s = Scratch::new("note");
        std::fs::create_dir_all(&s.0).unwrap();
        let p = s.0.join("a.png");
        std::fs::write(&p, b"x").unwrap();
        let mut r = Reuse::new();
        r.remember(7, p.clone(), Some("[notes] 1".into()));
        assert_eq!(r.lookup(7), Some(Saved { path: &p, note: Some("[notes] 1") }));
        // The next thing saved is not a screenshot and has no line.
        r.remember(9, p.clone(), None);
        assert_eq!(r.lookup(9), Some(Saved { path: &p, note: None }));
    }

    #[test]
    fn a_file_that_was_deleted_is_not_reused() {
        let s = Scratch::new("gone");
        std::fs::create_dir_all(&s.0).unwrap();
        let p = s.0.join("a.png");
        std::fs::write(&p, b"x").unwrap();
        let mut r = Reuse::new();
        r.remember(7, p.clone(), None);
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
        r.remember(0, p.clone(), None);
        assert_eq!(r.lookup(0), None);
        // And an unknown reading forgets the known one rather than keeping a
        // path that may belong to an older clipboard.
        r.remember(7, p.clone(), None);
        r.remember(0, p, None);
        assert_eq!(r.lookup(7), None);
    }
}
