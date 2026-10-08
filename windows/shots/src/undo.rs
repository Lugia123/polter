//! Undo and redo for the text box, as many steps as there are changes.
//!
//! The native control has one level, and joins a change to the one before
//! it when it begins where that one ended: type `hello world`, copy it all,
//! paste at the end, and Ctrl+Z took both away (task 1200). So the box
//! keeps its own history, and the control's is never asked.
//!
//! What is recorded is what the host reads back after each change
//! (`textbox::Typed`). **Whether a change joins the one before is decided
//! from the two texts and nothing else** -- not from which message the
//! change came by: a key's character, a `VK_PACKET`, the text services'
//! own insertion and an input method's committed English all arrive
//! differently and must be one run of typing (task 1200, second round).
//! A run is one step: characters inserted one after another at the end of
//! the last; Backspace pressed one after another; Delete likewise. A paste
//! (more than a character), a cut, a deletion of a selection, a change of
//! kind, and a move of the caret (the same text with another selection)
//! each end it.

/// What was in the box and where the selection was.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snap {
    pub units: Vec<u16>,
    pub sel: (usize, usize),
}

/// How many units make "a character": one, or two for a surrogate pair.
/// More than that in one change is a paste or an input method's word.
const CHARACTER: usize = 2;

/// How many steps back are kept.
pub const DEPTH: usize = 200;

/// A run of one kind of typing, and where the next of it would be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Run {
    /// Characters going in: the next goes in at this offset.
    Inserting(usize),
    /// Backspace: the next removes the character before this offset.
    Backspacing(usize),
    /// Delete: the next removes the character at this offset.
    Deleting(usize),
}

/// What changed between two texts: where, what went, what came.
fn diff<'a>(old: &'a [u16], new: &'a [u16]) -> (usize, &'a [u16], &'a [u16]) {
    let mut p = 0;
    while p < old.len() && p < new.len() && old[p] == new[p] {
        p += 1;
    }
    let mut q = 0;
    while q < old.len() - p && q < new.len() - p && old[old.len() - 1 - q] == new[new.len() - 1 - q] {
        q += 1;
    }
    (p, &old[p..old.len() - q], &new[p..new.len() - q])
}

#[derive(Clone, Debug)]
pub struct History {
    past: Vec<Snap>,
    now: Snap,
    future: Vec<Snap>,
    run: Option<Run>,
}

impl History {
    pub fn new(units: Vec<u16>, sel: (usize, usize)) -> History {
        History { past: Vec::new(), now: Snap { units, sel }, future: Vec::new(), run: None }
    }

    /// The box was read back holding `units`, the selection `sel`. The same
    /// text is no change (the selection is only remembered, and a run of
    /// typing ends if it moved: the caret has been taken somewhere);
    /// another text is one, joined to the run before it if it carries it on.
    pub fn record(&mut self, units: &[u16], sel: (usize, usize)) {
        if units == self.now.units.as_slice() {
            if sel != self.now.sel {
                self.now.sel = sel;
                // The caret where the run left it is where it already was:
                // a read that caught the selection a moment before it
                // settled there (a text service inserts by selecting and
                // replacing) is no move.
                let expected = self.run.map(|r| match r {
                    Run::Inserting(w) | Run::Backspacing(w) | Run::Deleting(w) => (w, w),
                });
                if expected != Some(sel) {
                    self.run = None;
                }
            }
            return;
        }
        let (at, gone, came) = diff(&self.now.units, units);
        let before = self.now.sel;
        let (next, kind) = if gone.is_empty() && !came.is_empty() && came.len() <= CHARACTER {
            let end = at + came.len();
            (Some(Run::Inserting(end)), matches!(self.run, Some(Run::Inserting(w)) if w == at))
        } else if came.is_empty() && !gone.is_empty() && gone.len() <= CHARACTER && before.0 == before.1 {
            // Which key: Backspace had the caret after what went.
            if before.1 == at + gone.len() {
                (Some(Run::Backspacing(at)), matches!(self.run, Some(Run::Backspacing(w)) if w == at + gone.len()))
            } else if before.1 == at {
                (Some(Run::Deleting(at)), matches!(self.run, Some(Run::Deleting(w)) if w == at))
            } else {
                (None, false)
            }
        } else {
            (None, false)
        };
        if !kind {
            self.past.push(self.now.clone());
            if self.past.len() > DEPTH {
                self.past.remove(0);
            }
        }
        self.now = Snap { units: units.to_vec(), sel };
        self.run = next;
        self.future.clear();
    }

    /// One step back: what to put in the box, or `None` at the start.
    pub fn undo(&mut self) -> Option<Snap> {
        let back = self.past.pop()?;
        self.future.push(std::mem::replace(&mut self.now, back));
        self.run = None;
        Some(self.now.clone())
    }

    /// One step forward again.
    pub fn redo(&mut self) -> Option<Snap> {
        let forth = self.future.pop()?;
        self.past.push(std::mem::replace(&mut self.now, forth));
        self.run = None;
        Some(self.now.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn text(s: Snap) -> String {
        String::from_utf16(&s.units).unwrap()
    }

    /// Typing `s` at the end of `from`, one character at a time, the
    /// selection going to the new end after each (what reading the box back
    /// after a character shows).
    fn type_into(h: &mut History, from: &str, s: &str) -> String {
        let mut now = from.to_string();
        for c in s.chars() {
            now.push(c);
            let n = u(&now).len();
            h.record(&u(&now), (n, n));
        }
        now
    }

    #[test]
    fn ten_characters_typed_one_after_another_are_one_step() {
        let mut h = History::new(Vec::new(), (0, 0));
        type_into(&mut h, "", "abcdefghij");
        assert_eq!(h.undo().map(text), Some(String::new()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn a_selection_that_settles_where_the_run_left_the_caret_is_not_a_move() {
        let mut h = History::new(Vec::new(), (0, 0));
        h.record(&u("a"), (0, 1));
        h.record(&u("a"), (1, 1));
        h.record(&u("ab"), (1, 2));
        h.record(&u("ab"), (2, 2));
        h.record(&u("abc"), (3, 3));
        assert_eq!(h.undo().map(text), Some(String::new()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn typing_in_the_middle_of_a_text_is_one_step_too() {
        // "XY" typed at the start of "abc": the insertion point moves with it.
        let mut h = History::new(u("abc"), (0, 0));
        h.record(&u("Xabc"), (1, 1));
        h.record(&u("XYabc"), (2, 2));
        assert_eq!(h.undo().map(text), Some("abc".to_string()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn an_explicit_move_of_the_caret_makes_two_steps() {
        let mut h = History::new(Vec::new(), (0, 0));
        let a = type_into(&mut h, "", "abcde");
        // Home, then End: the text is the same, the selection moves.
        h.record(&u(&a), (0, 0));
        h.record(&u(&a), (5, 5));
        type_into(&mut h, &a, "fghij");
        assert_eq!(h.undo().map(text), Some("abcde".to_string()));
        assert_eq!(h.undo().map(text), Some(String::new()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn backspace_pressed_a_few_times_is_one_step() {
        let mut h = History::new(u("abcdefghij"), (10, 10));
        let mut now = "abcdefghij".to_string();
        for _ in 0..4 {
            now.pop();
            let n = now.len();
            h.record(&u(&now), (n, n));
        }
        assert_eq!(now, "abcdef");
        assert_eq!(h.undo().map(text), Some("abcdefghij".to_string()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn delete_pressed_a_few_times_is_one_step() {
        let mut h = History::new(u("abcdef"), (0, 0));
        h.record(&u("bcdef"), (0, 0));
        h.record(&u("cdef"), (0, 0));
        h.record(&u("def"), (0, 0));
        assert_eq!(h.undo().map(text), Some("abcdef".to_string()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn a_deletion_right_after_typing_is_a_step_of_its_own() {
        let mut h = History::new(Vec::new(), (0, 0));
        let a = type_into(&mut h, "", "abc");
        h.record(&u(&a[..2]), (2, 2));
        assert_eq!(h.undo().map(text), Some("abc".to_string()));
        assert_eq!(h.undo().map(text), Some(String::new()));
        // And the other way: typing right after Backspace.
        let mut h = History::new(u("abc"), (3, 3));
        h.record(&u("ab"), (2, 2));
        h.record(&u("abX"), (3, 3));
        assert_eq!(h.undo().map(text), Some("ab".to_string()));
        assert_eq!(h.undo().map(text), Some("abc".to_string()));
    }

    #[test]
    fn undo_after_a_paste_takes_the_paste_and_not_the_typing_before_it() {
        let mut h = History::new(Vec::new(), (0, 0));
        let typed = type_into(&mut h, "", "hello world");
        // Select all, copy, End: the text is the same, the selection moves.
        h.record(&u(&typed), (0, 11));
        h.record(&u(&typed), (11, 11));
        let pasted = format!("{typed}{typed}");
        h.record(&u(&pasted), (22, 22));
        assert_eq!(h.undo().map(text), Some("hello world".to_string()));
        assert_eq!(h.undo().map(text), Some(String::new()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn typing_right_after_a_paste_is_not_joined_to_it() {
        let mut h = History::new(Vec::new(), (0, 0));
        h.record(&u("hello"), (5, 5));
        h.record(&u("helloX"), (6, 6));
        h.record(&u("helloXY"), (7, 7));
        assert_eq!(h.undo().map(text), Some("hello".to_string()));
        assert_eq!(h.undo().map(text), Some(String::new()));
    }

    #[test]
    fn a_character_of_two_units_is_a_character() {
        let mut h = History::new(Vec::new(), (0, 0));
        h.record(&u("a"), (1, 1));
        h.record(&u("a\u{1F600}"), (3, 3));
        h.record(&u("a\u{1F600}b"), (4, 4));
        assert_eq!(h.undo().map(text), Some(String::new()));
    }

    #[test]
    fn redo_goes_forward_and_a_new_change_forgets_it() {
        let mut h = History::new(Vec::new(), (0, 0));
        let a = type_into(&mut h, "", "ab");
        h.record(&u("abXYZ"), (5, 5));
        assert_eq!(h.undo().map(text), Some(a.clone()));
        assert_eq!(h.redo().map(text), Some("abXYZ".to_string()));
        assert_eq!(h.redo(), None);
        h.undo();
        h.record(&u("abZ"), (3, 3));
        assert_eq!(h.redo(), None, "a new change ends the way forward");
    }

    #[test]
    fn what_a_step_back_gives_back_is_the_selection_it_had() {
        let mut h = History::new(u("hello"), (5, 5));
        h.record(&u("hello"), (0, 5));
        h.record(&u(""), (0, 0));
        let back = h.undo().unwrap();
        assert_eq!((text(back.clone()), back.sel), ("hello".to_string(), (0, 5)));
    }

    #[test]
    fn only_so_many_steps_are_kept() {
        let mut h = History::new(Vec::new(), (0, 0));
        for i in 0..DEPTH + 50 {
            h.record(&u(&"x".repeat((i + 1) * 3)), ((i + 1) * 3, (i + 1) * 3));
        }
        let mut n = 0;
        while h.undo().is_some() {
            n += 1;
        }
        assert_eq!(n, DEPTH);
    }
}
