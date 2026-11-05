//! Search-result display rules that can be wrong without looking wrong.
//!
//! The core answers with **UTF-8 byte ranges** relative to the snippet. The
//! Win32 text APIs this host draws and selects with count **UTF-16 code
//! units**. A range copied across without mapping highlights the wrong
//! characters as soon as the snippet contains Chinese or an emoji, and the
//! page still looks like it worked.
//!
//! Nothing here reads the core or a window; the host hands in the snippet
//! and the range, and gets back the offsets its own strings use.

/// A raw range in one string, in UTF-8 bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    pub start: u32,
    pub end: u32,
}

/// Map a UTF-8 byte range inside `text` to UTF-16 code-unit offsets.
/// **`None` for a range that is not on character boundaries or past the
/// end**: a highlight placed by guessing is worse than no highlight.
pub fn utf16_range(text: &str, range: ByteRange) -> Option<(usize, usize)> {
    let start = range.start as usize;
    let end = range.end as usize;
    if start > end
        || end > text.len()
        || !text.is_char_boundary(start)
        || !text.is_char_boundary(end)
    {
        return None;
    }
    let units_before = |byte: usize| text[..byte].encode_utf16().count();
    Some((units_before(start), units_before(end)))
}

/// Where a snippet sits in its message, and how much of the message the
/// snippet leaves out on each side. The UI draws the omission itself; the
/// core never puts an ellipsis in the snippet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnippetPlace {
    pub start: u32,
    pub text_bytes: usize,
    pub omitted_before: bool,
    pub omitted_after: bool,
}

/// The place of a snippet in the complete stored text.
pub fn snippet_place(text: &str, snippet_start: u32, snippet: &str) -> Option<SnippetPlace> {
    let start = snippet_start as usize;
    let end = start.checked_add(snippet.len())?;
    if end > text.len()
        || !text.is_char_boundary(start)
        || !text.is_char_boundary(end)
        || text.get(start..end) != Some(snippet)
    {
        return None;
    }
    Some(SnippetPlace {
        start: snippet_start,
        text_bytes: text.len(),
        omitted_before: start > 0,
        omitted_after: end < text.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chinese_and_emoji_ranges_move_from_bytes_to_utf16_units() {
        let text = "批量😀done";
        // "批" is 3 bytes and 1 UTF-16 unit.
        assert_eq!(
            utf16_range(text, ByteRange { start: 0, end: 3 }),
            Some((0, 1))
        );
        // The emoji is 4 bytes and 2 UTF-16 units; the whole prefix
        // "批量😀" is 10 bytes but 4 units.
        assert_eq!(
            utf16_range(text, ByteRange { start: 0, end: 10 }),
            Some((0, 4))
        );
        // A byte in the middle of a character is not a highlight.
        assert_eq!(utf16_range(text, ByteRange { start: 1, end: 3 }), None);
        assert_eq!(
            utf16_range(
                text,
                ByteRange {
                    start: 0,
                    end: text.len() as u32 + 1
                }
            ),
            None
        );
    }

    #[test]
    fn a_snippet_says_what_it_left_out_and_must_be_the_text_itself() {
        let text = "before 批量 after";
        let start = 7u32;
        let snippet = "批量";
        let place = snippet_place(text, start, snippet).expect("an exact substring");
        assert!(place.omitted_before);
        assert!(place.omitted_after);
        assert_eq!(place.start, start);
        // A snippet that is not exactly there (or not on a character
        // boundary) is not a place.
        assert_eq!(snippet_place(text, start, "批量x"), None);
        assert_eq!(snippet_place(text, 8, snippet), None);
    }
}
