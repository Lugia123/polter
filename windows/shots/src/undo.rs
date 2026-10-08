//! Undo and redo for the text box, as many steps as there are changes.
//!
//! The native control has one level, and joins a change to the one before
//! it when it begins where that one ended: type `hello world`, copy it all,
//! paste at the end, and Ctrl+Z took both away (task 1200). So the box
//! keeps its own history, and the control's is never asked.
//!
//! What is recorded is what the host reads back after each change
//! (`textbox::Typed`), with what kind of change it was. A run of typing is
//! one step, as in a text view on macOS; a paste, a cut, an input method's
//! committed text, and a deletion by a selection each are one step of their
//! own; moving the caret ends a run, so what is typed after it is another.

/// What was in the box and where the selection was.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snap {
    pub units: Vec<u16>,
    pub sel: (usize, usize),
}

/// The kind of change that led to a text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// A character or Backspace or Delete: joins the run before it.
    Typing,
    /// Anything else (a paste, a cut, committed input): its own step.
    Other,
}

/// How many steps back are kept.
pub const DEPTH: usize = 200;

#[derive(Clone, Debug)]
pub struct History {
    past: Vec<Snap>,
    now: Snap,
    future: Vec<Snap>,
    last: Option<Kind>,
}

impl History {
    pub fn new(units: Vec<u16>, sel: (usize, usize)) -> History {
        History { past: Vec::new(), now: Snap { units, sel }, future: Vec::new(), last: None }
    }

    /// The box was read back holding `units`. The same text is no change
    /// (the selection is only remembered, and a run of typing ends: the
    /// caret has moved); another text is one, joined to the typing before
    /// it if both are typing.
    pub fn record(&mut self, units: &[u16], sel: (usize, usize), kind: Kind) {
        if units == self.now.units.as_slice() {
            if sel != self.now.sel {
                self.now.sel = sel;
                self.last = None;
            }
            return;
        }
        if !(kind == Kind::Typing && self.last == Some(Kind::Typing)) {
            self.past.push(self.now.clone());
            if self.past.len() > DEPTH {
                self.past.remove(0);
            }
        }
        self.now = Snap { units: units.to_vec(), sel };
        self.last = Some(kind);
        self.future.clear();
    }

    /// One step back: what to put in the box, or `None` at the start.
    pub fn undo(&mut self) -> Option<Snap> {
        let back = self.past.pop()?;
        self.future.push(std::mem::replace(&mut self.now, back));
        self.last = None;
        Some(self.now.clone())
    }

    /// One step forward again.
    pub fn redo(&mut self) -> Option<Snap> {
        let forth = self.future.pop()?;
        self.past.push(std::mem::replace(&mut self.now, forth));
        self.last = None;
        Some(self.now.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    /// Typing `s` one character at a time.
    fn type_into(h: &mut History, from: &str, s: &str) -> String {
        let mut text = from.to_string();
        for c in s.chars() {
            text.push(c);
            h.record(&u(&text), (text.len(), text.len()), Kind::Typing);
        }
        text
    }

    fn text(s: Snap) -> String {
        String::from_utf16(&s.units).unwrap()
    }

    #[test]
    fn undo_after_a_paste_takes_the_paste_and_not_the_typing_before_it() {
        let mut h = History::new(Vec::new(), (0, 0));
        let typed = type_into(&mut h, "", "hello world");
        // Select all, copy, End: the text is the same, the selection moves.
        h.record(&u(&typed), (0, 11), Kind::Other);
        h.record(&u(&typed), (11, 11), Kind::Other);
        let pasted = format!("{typed}{typed}");
        h.record(&u(&pasted), (22, 22), Kind::Other);
        assert_eq!(h.undo().map(text), Some("hello world".to_string()));
        assert_eq!(h.undo().map(text), Some(String::new()));
        assert_eq!(h.undo(), None);
    }

    #[test]
    fn a_run_of_typing_is_one_step_and_a_caret_move_ends_it() {
        let mut h = History::new(Vec::new(), (0, 0));
        let a = type_into(&mut h, "", "abc");
        // The caret goes to the start and back: a new run.
        h.record(&u(&a), (0, 0), Kind::Other);
        h.record(&u(&a), (3, 3), Kind::Other);
        type_into(&mut h, &a, "def");
        assert_eq!(h.undo().map(text), Some("abc".to_string()));
        assert_eq!(h.undo().map(text), Some(String::new()));
    }

    #[test]
    fn redo_goes_forward_and_a_new_change_forgets_it() {
        let mut h = History::new(Vec::new(), (0, 0));
        let a = type_into(&mut h, "", "ab");
        h.record(&u("abXY"), (4, 4), Kind::Other);
        assert_eq!(h.undo().map(text), Some(a.clone()));
        assert_eq!(h.redo().map(text), Some("abXY".to_string()));
        assert_eq!(h.redo(), None);
        h.undo();
        h.record(&u("abZ"), (3, 3), Kind::Other);
        assert_eq!(h.redo(), None, "a new change ends the way forward");
    }

    #[test]
    fn what_a_step_back_gives_back_is_the_selection_it_had() {
        let mut h = History::new(u("hello"), (5, 5));
        h.record(&u("hello"), (0, 5), Kind::Other);
        h.record(&u(""), (0, 0), Kind::Other);
        let back = h.undo().unwrap();
        assert_eq!((text(back.clone()), back.sel), ("hello".to_string(), (0, 5)));
    }

    #[test]
    fn only_so_many_steps_are_kept() {
        let mut h = History::new(Vec::new(), (0, 0));
        for i in 0..DEPTH + 50 {
            h.record(&u(&"x".repeat(i + 1)), (i + 1, i + 1), Kind::Other);
        }
        let mut n = 0;
        while h.undo().is_some() {
            n += 1;
        }
        assert_eq!(n, DEPTH);
    }
}
