//! «Copy Terminal ID» (task 1643): what goes on the clipboard and what the
//! rows say, and the copy itself.
//!
//! **The id is the one the MCP tools take**: `terminal_list`'s `id`,
//! `ghostty_surface_poltergeist_id` written `0x{:016x}`. The point is to paste
//! it to an agent so it acts on that terminal and no other, so it is the whole
//! sixteen digits, never a shortened one.
//!
//! The macOS host has the same rules in
//! `macos/Sources/Features/Splits/TerminalIDCopy.swift`, with the same cases
//! in its tests.
//!
//! Three menus offer it: the terminal's own (`ctxmenu.rs`), a pane's title
//! and a stack's tab, and the window tab's (both `strip.rs`).

use windows::Win32::Foundation::HWND;

use crate::ffi::Surface;
use crate::i18n::n_;
use crate::wlogf;

/// The label of every «Copy Terminal ID» row, and of the tab's submenu.
pub const COPY_TERMINAL_ID: &str = n_("Copy Terminal ID");
/// The last row of the tab's submenu: every terminal, one per line.
pub const COPY_ALL: &str = n_("Copy All");

/// One terminal: its id, and the title shown beside it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: u64,
    pub title: String,
}

/// What a tab's menu offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Offer {
    /// One terminal in the tab: the row copies it.
    Single(Entry),
    /// Several: a submenu of one row each, then «Copy All».
    Each(Vec<Entry>),
}

/// The id as `terminal_list` writes it. 0 names no terminal (the core
/// answers 0 for none), so it is never offered: see [`known`].
pub fn text(id: u64) -> String {
    format!("0x{id:016x}")
}

pub fn known(id: u64) -> bool {
    id != 0
}

/// The longest title a submenu row shows before it is cut.
pub const TITLE_LIMIT: usize = 40;

/// A row of the submenu: "title — 0x…", the title on one line and cut at
/// [`TITLE_LIMIT`]; just the id when there is no title.
pub fn row_label(e: &Entry) -> String {
    label(e, Some(TITLE_LIMIT))
}

/// «Copy All»: one line per terminal, as its row says it but with the whole
/// title, in the tab's order.
pub fn all_text(entries: &[Entry]) -> String {
    entries.iter().map(|e| label(e, None)).collect::<Vec<_>>().join("\n")
}

/// What the tab's menu offers for these terminals, those with no id left
/// out; `None` when none is left.
pub fn offer(entries: Vec<Entry>) -> Option<Offer> {
    let mut offered: Vec<Entry> = entries.into_iter().filter(|e| known(e.id)).collect();
    match offered.len() {
        0 => None,
        1 => Some(Offer::Single(offered.remove(0))),
        _ => Some(Offer::Each(offered)),
    }
}

fn label(e: &Entry, limit: Option<usize>) -> String {
    let flat = e.title.lines().collect::<Vec<_>>().join(" ");
    let flat = flat.trim();
    if flat.is_empty() {
        return text(e.id);
    }
    let shown = match limit {
        Some(n) if flat.chars().count() > n => format!("{}…", flat.chars().take(n).collect::<String>()),
        _ => flat.to_string(),
    };
    format!("{shown} — {}", text(e.id))
}

/// The id of `surface`'s terminal; 0 for a null surface.
pub fn id_of(surface: Surface) -> u64 {
    if surface.is_null() {
        return 0;
    }
    unsafe { (crate::api().surface_poltergeist_id)(surface) }
}

/// Put `text` on the clipboard and say so in `frame`'s log. Nothing is
/// shown: the person pastes it.
pub fn copy(frame: HWND, text: &str, what: &str) -> bool {
    match crate::tabs::copy_to_clipboard(text) {
        Ok(()) => {
            wlogf!(frame, "[termid] copied {what}: {:?}", text);
            true
        }
        Err(why) => {
            wlogf!(frame, "[termid] could not copy {what}: {why}");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(id: u64, title: &str) -> Entry {
        Entry { id, title: title.to_string() }
    }

    #[test]
    fn the_id_is_written_the_way_terminal_list_writes_it() {
        assert_eq!(text(0x2d546c530d49f5e1), "0x2d546c530d49f5e1");
        assert_eq!(text(0xab), "0x00000000000000ab");
    }

    #[test]
    fn zero_names_no_terminal_and_is_never_offered() {
        assert!(!known(0));
        assert!(known(1));
        assert_eq!(offer(vec![e(0, "x")]), None);
        assert_eq!(offer(vec![]), None);
    }

    #[test]
    fn one_terminal_is_copied_straight_and_several_get_a_row_each() {
        assert_eq!(offer(vec![e(1, "a")]), Some(Offer::Single(e(1, "a"))));
        assert_eq!(offer(vec![e(1, "a"), e(2, "b")]), Some(Offer::Each(vec![e(1, "a"), e(2, "b")])));
        assert_eq!(offer(vec![e(0, "gone"), e(2, "b")]), Some(Offer::Single(e(2, "b"))));
    }

    #[test]
    fn a_row_is_the_title_then_the_id_on_one_line() {
        assert_eq!(row_label(&e(0x1f, "zsh")), "zsh — 0x000000000000001f");
        assert_eq!(row_label(&e(0x1f, "a\nb ")), "a b — 0x000000000000001f");
        assert_eq!(row_label(&e(0x1f, "  ")), "0x000000000000001f");
    }

    #[test]
    fn a_long_title_is_cut_in_the_row_but_not_in_copy_all() {
        let long = "x".repeat(50);
        assert_eq!(row_label(&e(7, &long)), format!("{}… — 0x0000000000000007", "x".repeat(TITLE_LIMIT)));
        assert_eq!(all_text(&[e(7, &long)]), format!("{long} — 0x0000000000000007"));
    }

    #[test]
    fn copy_all_is_one_line_per_terminal_in_order() {
        assert_eq!(all_text(&[e(2, "b"), e(1, "a")]), "b — 0x0000000000000002\na — 0x0000000000000001");
    }
}
