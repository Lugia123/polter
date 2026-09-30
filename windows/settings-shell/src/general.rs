//! The General section's rules (settings.md §7), with nothing drawn: its
//! groups and where a route lands, which items a group shows, what a row
//! draws and when it writes, and the geometry of the group list, the
//! keyboard shortcuts list and the form. **The macOS side's `GeneralRules`
//! and `ConfigFormRules` say the same things**; the tests below carry the
//! same cases.
//!
//! The core decides what a value may be and where it is written
//! (`src/config/form.zig`); the host only draws and asks. The table comes
//! in as JSON and the host fills [`Item`] from it -- this crate has no
//! dependencies, so no parser.

use crate::grid::*;
use crate::{scale, Rect};

// ================================================================= groups

/// The groups of §7.1, in list order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Group {
    Appearance,
    Font,
    Terminal,
    Windows,
    Polter,
    All,
    Keybinds,
    Advanced,
    About,
}

impl Group {
    pub const ALL: [Group; 9] = [
        Group::Appearance,
        Group::Font,
        Group::Terminal,
        Group::Windows,
        Group::Polter,
        Group::All,
        Group::Keybinds,
        Group::Advanced,
        Group::About,
    ];

    /// What a route's item names. **The macOS side's `GeneralGroup` raw
    /// values**, word for word: a route is something both hosts open.
    pub fn key(self) -> &'static str {
        match self {
            Group::Appearance => "appearance",
            Group::Font => "font",
            Group::Terminal => "terminal",
            Group::Windows => "windows",
            Group::Polter => "polter",
            Group::All => "all",
            Group::Keybinds => "keybinds",
            Group::Advanced => "advanced",
            Group::About => "about",
        }
    }

    pub fn from_key(k: &str) -> Option<Group> {
        Group::ALL.into_iter().find(|g| g.key() == k)
    }

    /// The label, as an English msgid -- the macOS side's.
    pub fn msgid(self) -> &'static str {
        match self {
            Group::Appearance => "Appearance",
            Group::Font => "Font",
            Group::Terminal => "Terminal",
            Group::Windows => "Windows & Tabs",
            Group::Polter => "Polter",
            Group::All => "All Options",
            Group::Keybinds => "Keyboard Shortcuts",
            Group::Advanced => "Advanced",
            Group::About => "About",
        }
    }

    /// The core's name for it (`form.zig`'s `Group`); `None` for the groups
    /// the core's table does not hold: All Options is every item, and the
    /// last three need no table.
    pub fn core(self) -> Option<&'static str> {
        match self {
            Group::Appearance => Some("appearance"),
            Group::Font => Some("font"),
            Group::Terminal => Some("terminal"),
            Group::Windows => Some("window"),
            Group::Polter => Some("polter"),
            Group::All | Group::Keybinds | Group::Advanced | Group::About => None,
        }
    }

    /// Drawn from the core's form table.
    pub fn is_form(self) -> bool {
        self.core().is_some() || self == Group::All
    }
}

/// Which group a route to General lands on: the one it names; with none
/// named, a window just opened takes the first and one already open stays.
/// A name that is no group counts as none. (`GeneralRules.groupToSelect`.)
pub fn group_to_select(item: Option<&str>, fresh: bool, current: Group) -> Group {
    if let Some(g) = item.and_then(Group::from_key) {
        return g;
    }
    if fresh {
        Group::ALL[0]
    } else {
        current
    }
}

// =================================================================== items

/// What a key draws, as the core names it (`form.zig`'s `Control`). A
/// control this build does not know -- a newer core -- is shown read-only,
/// never dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Control {
    Toggle,
    Choice,
    Number,
    Text,
    Font,
    Color,
    Theme,
    ReadOnly,
}

impl Control {
    pub fn parse(s: &str) -> Control {
        match s {
            "toggle" => Control::Toggle,
            "choice" => Control::Choice,
            "number" => Control::Number,
            "text" => Control::Text,
            "font" => Control::Font,
            "color" => Control::Color,
            "theme" => Control::Theme,
            _ => Control::ReadOnly,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    Default,
    Main { path: String, line: u32 },
    File { path: String, line: u32 },
    Cli { arg: u32 },
}

/// One row of the core's table.
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub key: String,
    /// The §7.1 group the core puts it in on this OS; `None` for a key only
    /// in All Options.
    pub group: Option<String>,
    pub control: Control,
    pub choices: Vec<String>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub default: String,
    pub value: String,
    pub doc: Option<String>,
    pub source: Source,
    /// Why the form may not write it (`repeatable`, `multiple`, `cli`,
    /// `file`); `None` when it may.
    pub readonly: Option<String>,
}

/// A group's keys, in the core's order (`sections` in the JSON).
pub type Sections = Vec<(String, Vec<String>)>;

/// The items `group` shows, as indices into `items`, in the table's order.
/// All Options is every item whose key contains `query` (ignoring case and
/// surrounding spaces), in the core's order.
pub fn items_in(group: Group, items: &[Item], sections: &Sections, query: &str) -> Vec<usize> {
    if group == Group::All {
        let needle = query.trim().to_lowercase();
        return (0..items.len()).filter(|&i| needle.is_empty() || items[i].key.to_lowercase().contains(&needle)).collect();
    }
    let Some(name) = group.core() else { return Vec::new() };
    let Some((_, keys)) = sections.iter().find(|(g, _)| g == name) else { return Vec::new() };
    keys.iter().filter_map(|k| items.iter().position(|it| &it.key == k)).collect()
}

pub fn is_writable(it: &Item) -> bool {
    it.readonly.is_none() && it.control != Control::ReadOnly
}

/// What a row draws. The form never writes a read-only one; in All Options
/// every other key is one line of text, checked by the core against the
/// key's type (§7.1).
pub fn control_for(it: &Item, group: Group) -> Control {
    if !is_writable(it) {
        return Control::ReadOnly;
    }
    if group == Group::All {
        Control::Text
    } else {
        it.control
    }
}

/// When a row writes (§7.3): a switch or a choice the moment it changes, a
/// text box on Return or when it loses focus, a read-only row never.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Commit {
    Immediately,
    OnEnterOrBlur,
    Never,
}

pub fn commit_for(c: Control) -> Commit {
    match c {
        Control::Toggle | Control::Choice => Commit::Immediately,
        Control::ReadOnly => Commit::Never,
        _ => Commit::OnEnterOrBlur,
    }
}

/// The dot beside the label (§7.3).
pub fn differs_from_default(it: &Item) -> bool {
    it.value != it.default
}

/// "Restore Default" deletes the main file's line (§7.2 rule 5), so it is
/// offered only where there is such a line.
pub fn can_restore_default(it: &Item) -> bool {
    is_writable(it) && matches!(it.source, Source::Main { .. })
}

/// Whether leaving a text box writes: only when it no longer says what the
/// file says.
pub fn should_write(edited: &str, it: &Item) -> bool {
    edited != it.value
}

pub fn is_on(it: &Item) -> bool {
    it.value == "true"
}

pub fn toggle_value(on: bool) -> &'static str {
    if on {
        "true"
    } else {
        "false"
    }
}

/// `theme = light:A,dark:B` as its two halves; a single name is both.
pub fn theme_pair(value: &str) -> (String, String) {
    let mut light = None;
    let mut dark = None;
    for part in value.split(',') {
        let p = part.trim();
        if let Some(v) = p.strip_prefix("light:") {
            light = Some(v.trim().to_string());
        } else if let Some(v) = p.strip_prefix("dark:") {
            dark = Some(v.trim().to_string());
        }
    }
    if light.is_none() && dark.is_none() {
        let single = value.trim().to_string();
        return (single.clone(), single);
    }
    (light.unwrap_or_default(), dark.unwrap_or_default())
}

/// The two halves written back the way the file writes them: one name when
/// both are the same.
pub fn theme_value(light: &str, dark: &str) -> String {
    let (l, d) = (light.trim(), dark.trim());
    if l == d {
        l.to_string()
    } else {
        format!("light:{l},dark:{d}")
    }
}

/// Why a row cannot be written, to say under it (§7.2 rule 4, §7.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadOnlyNote {
    /// A list-like key, or one with more than one line: edit it in the file.
    InTheFile,
    /// Set by another file: "Set by <path>:<line>" and "Open that file".
    SetBy { path: String, line: u32 },
    /// The command line has the last word.
    CommandLine,
}

pub fn readonly_note(it: &Item) -> Option<ReadOnlyNote> {
    if is_writable(it) {
        return None;
    }
    Some(match (&it.readonly.as_deref(), &it.source) {
        (Some("file"), Source::File { path, line }) => ReadOnlyNote::SetBy { path: path.clone(), line: *line },
        (Some("cli"), _) => ReadOnlyNote::CommandLine,
        _ => ReadOnlyNote::InTheFile,
    })
}

/// The first line of a key's documentation, for under its control: the
/// whole text is `+show-config --docs`, far longer than a form row.
pub fn doc_summary(doc: &str) -> String {
    let mut out = String::new();
    for line in doc.lines() {
        let l = line.trim();
        if l.is_empty() {
            if out.is_empty() {
                continue;
            }
            break;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(l);
    }
    out
}

// ================================================================= layout

/// One group's row in the section's list column: `SECTION_ROW_H` tall, the
/// sidebar's rhythm, from `PAD` below the list's top, with the list's text
/// edge.
pub fn group_row(list: Rect, dpi: i32, index: usize) -> Rect {
    let s = |v| scale(v, dpi);
    let top = list.top + s(ROW_GAP) + index as i32 * s(SECTION_ROW_H);
    Rect::new(list.left + s(PAD_SIDEBAR), top, list.right - s(PAD_SIDEBAR), top + s(SECTION_ROW_H))
}

/// Which group row a click at `y` is on.
pub fn group_at(list: Rect, dpi: i32, x: i32, y: i32) -> Option<Group> {
    if x < list.left || x >= list.right {
        return None;
    }
    (0..Group::ALL.len()).find(|&i| {
        let r = group_row(list, dpi, i);
        y >= r.top && y < r.bottom
    }).map(|i| Group::ALL[i])
}

/// The filter box All Options has above its form, and the form's body
/// under it; the other form groups' body is the editor less `PAD`.
pub fn form_area(editor: Rect, dpi: i32, with_filter: bool) -> (Option<Rect>, Rect) {
    let s = |v| scale(v, dpi);
    let left = editor.left + s(PAD);
    let right = editor.right - s(PAD);
    let top = editor.top + s(PAD);
    if with_filter {
        let f = Rect::new(left, top, right, top + s(CONTROL_H));
        (Some(f), Rect::new(left, f.bottom + s(ROW_GAP), right, (editor.bottom - s(PAD)).max(f.bottom + s(ROW_GAP))))
    } else {
        (None, Rect::new(left, top, right, (editor.bottom - s(PAD)).max(top)))
    }
}

// ------------------------------------------------------ keyboard shortcuts

/// The Keyboard Shortcuts columns: name, keys, note (`GeneralRules.
/// KeybindColumns`). Where less than `MIN_NOTE` is left for the note, it
/// goes on a line of its own under the keys rather than one character a
/// line.
pub const KB_NAME_W: i32 = 220;
pub const KB_KEYS_W: i32 = 160;
pub const KB_GAP: i32 = 12;
pub const KB_MIN_NOTE: i32 = 160;
/// A row, and one with the note under it.
pub const KB_ROW_H: i32 = 24;
pub const KB_ROW_H_TALL: i32 = 44;
/// The legend line above the rows.
pub const KB_HEADER: i32 = 32;

pub fn keybind_note_below(content_w: i32, dpi: i32) -> bool {
    content_w < scale(KB_NAME_W + KB_GAP + KB_KEYS_W + KB_GAP + KB_MIN_NOTE, dpi)
}

/// How many rows fit in a list `h` pixels tall.
pub fn kb_fit(h: i32, dpi: i32, note_below: bool) -> usize {
    let row = scale(if note_below { KB_ROW_H_TALL } else { KB_ROW_H }, dpi);
    ((h - scale(KB_HEADER, dpi)).max(0) / row.max(1)).max(1) as usize
}

/// Row `index`'s rectangle in a list `w` wide, scrolled so `top` is first,
/// showing `fit` rows. **One function for the painter, the click and the UI
/// Automation provider** (`one-place-decides-where-a-row-is.py`). `None`
/// off the view in either direction, and when the list is not showing
/// (`top == usize::MAX`).
pub fn kb_row_rect_at(top: usize, fit: usize, dpi: i32, w: i32, note_below: bool, index: usize) -> Option<Rect> {
    if top == usize::MAX {
        return None;
    }
    let n = index.checked_sub(top)?;
    if n >= fit {
        return None;
    }
    let row = scale(if note_below { KB_ROW_H_TALL } else { KB_ROW_H }, dpi);
    let y = scale(KB_HEADER, dpi) + n as i32 * row;
    Some(Rect::new(0, y, w, y + row))
}

/// The first row shown after scrolling by `by` rows, held inside the list.
pub fn kb_scroll(top: usize, by: i32, len: usize, fit: usize) -> usize {
    let last = len.saturating_sub(fit);
    (top as i32 + by).clamp(0, last as i32) as usize
}

// ================================================================== about

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AboutLabel {
    Version,
    Build,
    Commit,
}

/// Version, build and commit (§7.1 "About"). A value missing or blank is
/// left out rather than shown empty: a blank commit reads as "this build has
/// no commit", which is a claim. (`GeneralRules.aboutRows`.)
pub fn about_rows(version: Option<&str>, build: Option<&str>, commit: Option<&str>) -> Vec<(AboutLabel, String)> {
    [(AboutLabel::Version, version), (AboutLabel::Build, build), (AboutLabel::Commit, commit)]
        .into_iter()
        .filter_map(|(l, v)| v.map(str::trim).filter(|v| !v.is_empty()).map(|v| (l, v.to_string())))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(key: &str, group: Option<&str>, control: Control, default: &str, value: &str) -> Item {
        Item {
            key: key.into(),
            group: group.map(str::to_string),
            control,
            choices: Vec::new(),
            min: None,
            max: None,
            default: default.into(),
            value: value.into(),
            doc: None,
            source: Source::Default,
            readonly: None,
        }
    }

    #[test]
    fn group_keys_are_the_macos_raw_values() {
        let keys: Vec<_> = Group::ALL.iter().map(|g| g.key()).collect();
        assert_eq!(keys, ["appearance", "font", "terminal", "windows", "polter", "all", "keybinds", "advanced", "about"]);
        for g in Group::ALL {
            assert_eq!(Group::from_key(g.key()), Some(g));
        }
        // The core calls the window group `window`; the route calls it
        // `windows`, as the macOS side does.
        assert_eq!(Group::Windows.core(), Some("window"));
        assert!(Group::All.is_form() && !Group::Keybinds.is_form());
    }

    #[test]
    fn a_route_lands_on_its_group_else_first_or_stays() {
        assert_eq!(group_to_select(Some("keybinds"), false, Group::Font), Group::Keybinds);
        assert_eq!(group_to_select(None, true, Group::Font), Group::Appearance);
        assert_eq!(group_to_select(None, false, Group::Font), Group::Font);
        assert_eq!(group_to_select(Some("nope"), false, Group::About), Group::About);
        assert_eq!(group_to_select(Some("nope"), true, Group::About), Group::Appearance);
    }

    #[test]
    fn a_group_shows_its_keys_in_the_tables_order_and_all_filters() {
        let items = vec![
            item("font-size", Some("font"), Control::Number, "13", "13"),
            item("theme", Some("appearance"), Control::Theme, "", ""),
            item("font-family", Some("font"), Control::Font, "", ""),
            item("keybind", None, Control::ReadOnly, "", ""),
        ];
        let sections: Sections = vec![("font".into(), vec!["font-family".into(), "font-size".into()])];
        assert_eq!(items_in(Group::Font, &items, &sections, ""), vec![2, 0]);
        // Not in the answer's sections: nothing, not a crash.
        assert!(items_in(Group::Terminal, &items, &sections, "").is_empty());
        assert!(items_in(Group::About, &items, &sections, "").is_empty());
        assert_eq!(items_in(Group::All, &items, &sections, ""), vec![0, 1, 2, 3]);
        assert_eq!(items_in(Group::All, &items, &sections, "  FONT "), vec![0, 2]);
    }

    #[test]
    fn a_row_draws_by_whether_it_can_be_written() {
        let mut t = item("copy-on-select", Some("terminal"), Control::Choice, "true", "true");
        assert_eq!(control_for(&t, Group::Terminal), Control::Choice);
        // All Options: one line of text for anything writable.
        assert_eq!(control_for(&t, Group::All), Control::Text);
        t.readonly = Some("file".into());
        assert_eq!(control_for(&t, Group::Terminal), Control::ReadOnly);
        assert_eq!(control_for(&item("x", None, Control::ReadOnly, "", ""), Group::All), Control::ReadOnly);
        assert_eq!(Control::parse("slider-of-the-future"), Control::ReadOnly);
    }

    #[test]
    fn switches_write_at_once_boxes_on_enter_readonly_never() {
        assert_eq!(commit_for(Control::Toggle), Commit::Immediately);
        assert_eq!(commit_for(Control::Choice), Commit::Immediately);
        assert_eq!(commit_for(Control::Number), Commit::OnEnterOrBlur);
        assert_eq!(commit_for(Control::Theme), Commit::OnEnterOrBlur);
        assert_eq!(commit_for(Control::ReadOnly), Commit::Never);
    }

    #[test]
    fn the_dot_and_restore_default() {
        let mut it = item("font-size", Some("font"), Control::Number, "13", "15");
        assert!(differs_from_default(&it));
        // Different from the default but not from a main-file line: there is
        // nothing to delete.
        assert!(!can_restore_default(&it));
        it.source = Source::Main { path: "c".into(), line: 3 };
        assert!(can_restore_default(&it));
        it.readonly = Some("cli".into());
        assert!(!can_restore_default(&it));
        assert!(!differs_from_default(&item("a", None, Control::Text, "x", "x")));
        assert!(should_write("16", &item("a", None, Control::Text, "x", "15")));
        assert!(!should_write("15", &item("a", None, Control::Text, "x", "15")));
    }

    #[test]
    fn toggles_are_true_and_false() {
        assert!(is_on(&item("a", None, Control::Toggle, "false", "true")));
        assert!(!is_on(&item("a", None, Control::Toggle, "false", "false")));
        assert_eq!(toggle_value(true), "true");
        assert_eq!(toggle_value(false), "false");
    }

    #[test]
    fn theme_pairs_round_trip() {
        assert_eq!(theme_pair("light:A, dark:B"), ("A".into(), "B".into()));
        assert_eq!(theme_pair("Dracula"), ("Dracula".into(), "Dracula".into()));
        assert_eq!(theme_pair("dark:B"), ("".into(), "B".into()));
        assert_eq!(theme_value("A", "A"), "A");
        assert_eq!(theme_value(" A ", "B"), "light:A,dark:B");
        let (l, d) = theme_pair(&theme_value("X", "Y"));
        assert_eq!((l.as_str(), d.as_str()), ("X", "Y"));
    }

    #[test]
    fn a_readonly_row_says_why() {
        let mut it = item("font-family", Some("font"), Control::Font, "", "a\nb");
        assert_eq!(readonly_note(&it), None);
        it.readonly = Some("multiple".into());
        assert_eq!(readonly_note(&it), Some(ReadOnlyNote::InTheFile));
        it.readonly = Some("file".into());
        it.source = Source::File { path: "/x/extra".into(), line: 7 };
        assert_eq!(readonly_note(&it), Some(ReadOnlyNote::SetBy { path: "/x/extra".into(), line: 7 }));
        it.readonly = Some("cli".into());
        it.source = Source::Cli { arg: 2 };
        assert_eq!(readonly_note(&it), Some(ReadOnlyNote::CommandLine));
    }

    #[test]
    fn the_doc_summary_is_the_first_paragraph() {
        assert_eq!(doc_summary("\nThe size of the font.\nIn points.\n\nMore here."), "The size of the font. In points.");
        assert_eq!(doc_summary(""), "");
    }

    #[test]
    fn group_rows_are_the_sidebar_rhythm_and_clicks_find_them() {
        let dpi = 144;
        let list = Rect::new(0, 0, scale(LIST, dpi), 900);
        let r0 = group_row(list, dpi, 0);
        assert_eq!(r0.top, scale(ROW_GAP, dpi));
        assert_eq!(r0.height(), scale(SECTION_ROW_H, dpi));
        assert_eq!((r0.left, r0.right), (scale(PAD_SIDEBAR, dpi), list.right - scale(PAD_SIDEBAR, dpi)));
        let r8 = group_row(list, dpi, 8);
        assert_eq!(group_at(list, dpi, 5, (r8.top + r8.bottom) / 2), Some(Group::About));
        assert_eq!(group_at(list, dpi, 5, r0.top - 1), None);
        assert_eq!(group_at(list, dpi, list.right, r0.top + 1), None);
        // All nine fit at the smallest window.
        let (_, h) = crate::content_size(crate::MIN_W, crate::MIN_H);
        let body = h - BOTTOM - 1;
        assert!(group_row(list, 96, 8).bottom <= body);
    }

    #[test]
    fn the_filter_sits_above_the_form_on_the_content_edge() {
        let dpi = 96;
        let editor = Rect::new(261, 0, 900, 500);
        let (f, body) = form_area(editor, dpi, true);
        let f = f.unwrap();
        assert_eq!(f.left, editor.left + PAD);
        assert_eq!(body.left, f.left);
        assert_eq!(body.top, f.bottom + ROW_GAP);
        let (none, b2) = form_area(editor, dpi, false);
        assert!(none.is_none());
        assert_eq!(b2.top, editor.top + PAD);
    }

    #[test]
    fn keybind_rows_do_not_overlap_and_scroll_into_the_same_slots() {
        let (dpi, w) = (96, 800);
        let fit = kb_fit(500, dpi, false);
        assert_eq!(fit, ((500 - KB_HEADER) / KB_ROW_H) as usize);
        let mut prev: Option<Rect> = None;
        for i in 0..fit {
            let r = kb_row_rect_at(0, fit, dpi, w, false, i).expect("visible");
            if let Some(p) = prev {
                assert!(r.top >= p.bottom, "row {i} overlaps");
            }
            prev = Some(r);
        }
        assert_eq!(kb_row_rect_at(0, fit, dpi, w, false, 0), kb_row_rect_at(40, fit, dpi, w, false, 40));
        assert!(kb_row_rect_at(40, fit, dpi, w, false, 39).is_none());
        assert!(kb_row_rect_at(40, fit, dpi, w, false, 40 + fit).is_none());
        assert!(kb_row_rect_at(usize::MAX, fit, dpi, w, false, 0).is_none());
        let at192 = kb_row_rect_at(0, fit, 192, 2 * w, false, 3).unwrap();
        let at96 = kb_row_rect_at(0, fit, 96, w, false, 3).unwrap();
        assert_eq!(at192.top, at96.top * 2);
    }

    #[test]
    fn a_narrow_page_puts_the_note_under_the_keys() {
        // The minimum window's editor (418 at 96 DPI on the macOS side).
        assert!(keybind_note_below(418, 96));
        assert!(!keybind_note_below(KB_NAME_W + KB_GAP + KB_KEYS_W + KB_GAP + KB_MIN_NOTE, 96));
        assert!(kb_fit(500, 96, true) < kb_fit(500, 96, false));
    }

    #[test]
    fn keybind_scrolling_holds_at_the_ends() {
        assert_eq!(kb_scroll(0, -3, 100, 18), 0);
        assert_eq!(kb_scroll(80, 30, 100, 18), 82);
        assert_eq!(kb_scroll(5, 1, 10, 18), 0);
    }

    #[test]
    fn about_leaves_out_what_is_blank() {
        let rows = about_rows(Some("0.9.1"), Some("  "), Some("abc123"));
        assert_eq!(rows, vec![(AboutLabel::Version, "0.9.1".to_string()), (AboutLabel::Commit, "abc123".to_string())]);
        assert!(about_rows(None, None, None).is_empty());
    }
}
