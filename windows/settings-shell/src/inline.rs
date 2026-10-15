//! One help line under a General row, flowed as the macOS form flows it
//! (`ConfigFormView.help`, task 1604): the key as the config file spells it,
//! in the fixed-width face; the sentence after it; and "More…" at the end of
//! the sentence's last line rather than on a line of its own.
//!
//! The Windows form drew all of it with one `DrawTextW` -- one face, so the
//! key could not be fixed-width -- and gave the link a line under it. Which
//! words go on which line is decided here, with the measuring handed in, so
//! it can be checked without a window.

/// What a run is, which is how it is drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Run {
    /// The key, fixed-width. Never broken.
    Key,
    /// The sentence. Broken after a space, or around a wide character.
    Text,
    /// "More…" / "Less", or the way to Keyboard Shortcuts. Never broken.
    Link,
}

/// A stretch of one run on one line, `x` from the line's left edge.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Piece {
    pub run: Run,
    pub text: String,
    pub line: usize,
    pub x: i32,
    pub w: i32,
}

/// The flowed line: its pieces, and how many lines it takes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Flow {
    pub pieces: Vec<Piece>,
    pub lines: usize,
}

impl Flow {
    /// Where the link is, as `(line, x, w)`; `None` when there is none.
    pub fn link(&self) -> Option<(usize, i32, i32)> {
        self.pieces.iter().find(|p| p.run == Run::Link).map(|p| (p.line, p.x, p.w))
    }
}

/// A character that is a word on its own: CJK, kana, Hangul, full-width
/// forms. A line may break before or after one.
fn wide(c: char) -> bool {
    matches!(c as u32, 0x2E80..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF | 0xFE30..=0xFE4F | 0xFF00..=0xFFEF)
}

/// Punctuation that does not start a line: it stays with what is before it.
fn closing(c: char) -> bool {
    "，。；：、！？）】」』》〉,.;:!?)]}…".contains(c)
}

/// The units a line may break between, for one run of the sentence. A
/// `"\n"` unit is a forced break.
fn units(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    for c in text.chars() {
        if c == '\n' {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            out.push("\n".to_string());
        } else if closing(c) && cur.is_empty() && out.last().is_some_and(|u| u != "\n") {
            // Kept with the unit before, so no line starts with it.
            out.last_mut().unwrap().push(c);
        } else if wide(c) {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            cur.push(c);
            out.push(std::mem::take(&mut cur));
        } else {
            cur.push(c);
            if c == ' ' {
                out.push(std::mem::take(&mut cur));
            }
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Flow `runs` into lines `width` wide. `gap` is the space between two runs
/// (the key and the sentence; the sentence and the link). `max_text_lines`
/// is how many lines the key and sentence may take, 0 for any: past it they
/// end in "…". The link goes on the last line when it fits there, else on a
/// line of its own.
pub fn flow(runs: &[(Run, String)], width: i32, gap: i32, measure: &dyn Fn(Run, &str) -> i32, max_text_lines: usize) -> Flow {
    let width = width.max(1);
    let mut pieces: Vec<Piece> = Vec::new();
    let (mut line, mut x) = (0usize, 0i32);
    let mut cut = false;
    let place = |pieces: &mut Vec<Piece>, run: Run, text: &str, line: usize, x: i32, w: i32| {
        // Joined to the piece before it when it is the same run on the
        // same line, so a line is drawn in as few calls as it has faces.
        if let Some(last) = pieces.last_mut() {
            if last.run == run && last.line == line && last.x + last.w == x {
                last.text.push_str(text);
                last.w += w;
                return;
            }
        }
        pieces.push(Piece { run, text: text.to_string(), line, x, w });
    };
    for (i, (run, text)) in runs.iter().enumerate() {
        if text.is_empty() {
            continue;
        }
        let lead = if i > 0 && x > 0 { gap } else { 0 };
        if *run == Run::Link {
            let w = measure(Run::Link, text);
            if x > 0 && x + lead + w > width {
                line += 1;
                x = 0;
            } else {
                x += lead;
            }
            place(&mut pieces, Run::Link, text, line, x, w);
            x += w;
            continue;
        }
        if cut {
            continue;
        }
        let us = if *run == Run::Key { vec![text.clone()] } else { units(text) };
        let mut first = true;
        for u in us {
            if u == "\n" {
                line += 1;
                x = 0;
                first = false;
                continue;
            }
            let w = measure(*run, &u);
            let lead_here = if first { lead } else { 0 };
            if x > 0 && x + lead_here + w > width {
                line += 1;
                x = 0;
            } else {
                x += lead_here;
            }
            first = false;
            if max_text_lines > 0 && line >= max_text_lines {
                // Past the lines allowed: what is kept ends in "…".
                line = max_text_lines - 1;
                if let Some(last) = pieces.iter_mut().rev().find(|p| p.run != Run::Link) {
                    last.text = format!("{}…", last.text.trim_end());
                    last.w = measure(last.run, &last.text);
                    x = last.x + last.w;
                }
                cut = true;
                break;
            }
            place(&mut pieces, *run, &u, line, x, w);
            x += w;
        }
    }
    let lines = if pieces.is_empty() { 0 } else { line + 1 };
    Flow { pieces, lines }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Ten per character, the fixed-width face twelve.
    fn m(run: Run, s: &str) -> i32 {
        let per = if run == Run::Key { 12 } else { 10 };
        s.chars().count() as i32 * per
    }

    fn r(run: Run, s: &str) -> (Run, String) {
        (run, s.to_string())
    }

    /// Task 1604, the macOS row: the key, its sentence, and "More…" at the
    /// end of the same line when it fits -- not on a line under it.
    #[test]
    fn the_link_follows_the_sentence_on_its_last_line() {
        let f = flow(&[r(Run::Key, "font-family"), r(Run::Text, "使用的字体"), r(Run::Link, "更多…")], 1000, 8, &m, 3);
        assert_eq!(f.lines, 1);
        assert_eq!(f.pieces[0], Piece { run: Run::Key, text: "font-family".into(), line: 0, x: 0, w: 132 });
        assert_eq!(f.pieces[1], Piece { run: Run::Text, text: "使用的字体".into(), line: 0, x: 140, w: 50 });
        assert_eq!(f.link(), Some((0, 198, 30)));
    }

    #[test]
    fn a_link_that_does_not_fit_takes_the_next_line() {
        let f = flow(&[r(Run::Text, "abcdefghij"), r(Run::Link, "More…")], 120, 8, &m, 3);
        assert_eq!(f.lines, 2);
        assert_eq!(f.link(), Some((1, 0, 50)));
    }

    #[test]
    fn chinese_breaks_between_characters_and_keeps_punctuation_with_the_word() {
        let f = flow(&[r(Run::Text, "一二三四。五六")], 40, 8, &m, 0);
        let lines: Vec<(usize, &str)> = f.pieces.iter().map(|p| (p.line, p.text.as_str())).collect();
        // "四。" is one unit: the full stop does not start the second line.
        assert_eq!(lines, [(0, "一二三"), (1, "四。五六")]);
    }

    #[test]
    fn english_breaks_after_a_space() {
        let f = flow(&[r(Run::Text, "aaa bbb ccc")], 80, 8, &m, 0);
        let lines: Vec<(usize, &str)> = f.pieces.iter().map(|p| (p.line, p.text.as_str())).collect();
        assert_eq!(lines, [(0, "aaa bbb "), (1, "ccc")]);
    }

    #[test]
    fn the_key_is_never_broken() {
        let f = flow(&[r(Run::Key, "window-padding-balance"), r(Run::Text, "x")], 100, 8, &m, 0);
        assert_eq!(f.pieces[0].text, "window-padding-balance");
        assert_eq!(f.pieces[0].line, 0);
        assert_eq!(f.pieces[1].line, 1);
    }

    #[test]
    fn past_the_lines_allowed_the_sentence_ends_in_an_ellipsis_and_the_link_still_shows() {
        let f = flow(&[r(Run::Text, "aaaa bbbb cccc dddd"), r(Run::Link, "More…")], 60, 8, &m, 2);
        let text: Vec<&str> = f.pieces.iter().filter(|p| p.run == Run::Text).map(|p| p.text.as_str()).collect();
        assert_eq!(text, ["aaaa ", "bbbb…"]);
        assert!(f.link().is_some_and(|(line, _, _)| line <= 2));
    }

    #[test]
    fn a_new_line_in_the_text_breaks_the_line() {
        let f = flow(&[r(Run::Text, "ab\ncd")], 1000, 8, &m, 0);
        assert_eq!(f.lines, 2);
        assert_eq!(f.pieces[1], Piece { run: Run::Text, text: "cd".into(), line: 1, x: 0, w: 20 });
    }
}
