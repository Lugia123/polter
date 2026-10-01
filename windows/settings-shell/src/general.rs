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
    /// The display name of each of `choices`, same order, English msgids
    /// (#977); empty where the table names none.
    pub choice_labels: Vec<String>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub default: String,
    pub value: String,
    pub doc: Option<String>,
    /// The form's own name and sentence for it, English msgids the host
    /// translates (#973); `None` for a key only in All Options.
    pub label: Option<String>,
    pub summary: Option<String>,
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

/// A range narrow enough to drag -- background opacity's 0-1 -- is a
/// slider; an integer type comes with its type's whole range, which is not
/// (`ConfigFormRules.usesSlider`).
pub fn uses_slider(it: &Item) -> bool {
    match (it.control, it.min, it.max) {
        (Control::Number, Some(min), Some(max)) => max > min && max - min <= 1.0,
        _ => false,
    }
}

/// Whether row `it` draws a slider in `group`: a writable number with a
/// narrow range, and not in All Options, where every writable key is one
/// line of text.
pub fn slider_for(it: &Item, group: Group) -> bool {
    control_for(it, group) == Control::Number && uses_slider(it)
}

/// A slider's value as it is written: two decimals, trailing zeros dropped
/// (`0.9`, `1`, `0.25`) -- `ConfigFormRules.sliderText`.
pub fn slider_text(v: f64) -> String {
    let s = format!("{v:.2}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s == "-0" || s.is_empty() {
        "0".to_string()
    } else {
        s.to_string()
    }
}

/// A trackbar is integers: this many steps from `min` to `max`, so a
/// step is a hundredth of the 0-1 range, the precision `slider_text`
/// writes.
pub const SLIDER_STEPS: i32 = 100;

/// The trackbar position for `value` (the effective value, as the file
/// writes it). A value that does not read as a number, or lies outside the
/// range, sits at the nearer end rather than nowhere.
pub fn slider_pos(value: &str, min: f64, max: f64) -> i32 {
    let v = value.trim().parse::<f64>().unwrap_or(min);
    if max <= min {
        return 0;
    }
    (((v - min) / (max - min)) * SLIDER_STEPS as f64).round().clamp(0.0, SLIDER_STEPS as f64) as i32
}

/// The value a trackbar position stands for.
pub fn slider_value(pos: i32, min: f64, max: f64) -> f64 {
    min + (max - min) * (pos.clamp(0, SLIDER_STEPS) as f64) / SLIDER_STEPS as f64
}

/// The slider's widest, as on the macOS side (`.frame(maxWidth: 240)`).
pub const SLIDER_MAX_W: i32 = 240;
/// Room for the value beside it: "0.25" and a little.
pub const SLIDER_TEXT_W: i32 = 48;

/// A slider row's two parts inside its control cell: the slider from the
/// control column's left edge, at most `SLIDER_MAX_W`, and the value after
/// it, a row gap away.
pub fn slider_parts(control: Rect, dpi: i32) -> (Rect, Rect) {
    let s = |v| scale(v, dpi);
    let room = (control.width() - s(ROW_GAP) - s(SLIDER_TEXT_W)).max(s(CONTROL_H));
    let w = room.min(s(SLIDER_MAX_W));
    let slider = Rect::new(control.left, control.top, control.left + w, control.bottom);
    let text = Rect::new(slider.right + s(ROW_GAP), control.top, (slider.right + s(ROW_GAP) + s(SLIDER_TEXT_W)).min(control.right.max(slider.right)), control.bottom);
    (slider, text)
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

/// What the label column says for a row: the form's name for it, translated,
/// else the key itself (All Options' keys have no name). Same rule as mac
/// `ConfigFormRules.title`.
pub fn row_title(it: &Item, translate: impl Fn(&str) -> String) -> String {
    match &it.label {
        Some(label) => translate(label),
        None => it.key.clone(),
    }
}

/// The line under a row's control when nothing is wrong: for a named key,
/// the key as the config file spells it and then the form's sentence,
/// translated (#973, mac `ConfigFormView.help`); for the rest, the first
/// paragraph of Ghostty's help.
pub fn row_help(it: &Item, translate: impl Fn(&str) -> String) -> String {
    match (&it.label, &it.summary) {
        (Some(_), Some(summary)) => format!("{}  {}", it.key, translate(summary)),
        (Some(_), None) => it.key.clone(),
        _ => it.doc.as_deref().map(doc_summary).unwrap_or_default(),
    }
}

/// Why the table is being read (#986; mac `ConfigFormRules.FormRead`):
/// right after the form's own write, or for any other reason -- the window
/// came forward, the configuration was reloaded, another group was chosen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FormRead {
    AfterOwnWrite,
    Reread,
}

/// A row's refusal after a read. It belongs to the write that caused it:
/// kept while the person is still at that field, gone on any other read,
/// when it no longer describes anything on screen.
pub fn error_after(read: FormRead, error: Option<String>) -> Option<String> {
    match read {
        FormRead::AfterOwnWrite => error,
        FormRead::Reread => None,
    }
}

/// What each value of an enum is called in its list: the table's name,
/// translated, else the value itself (#977; mac `ConfigFormRules.choiceTitle`).
/// What is written is always the value.
pub fn choice_titles(it: &Item, translate: impl Fn(&str) -> String) -> Vec<String> {
    if it.choice_labels.len() == it.choices.len() {
        it.choice_labels.iter().map(|l| translate(l)).collect()
    } else {
        it.choices.clone()
    }
}

/// The value to write for the list's selected row: the row's value, never
/// the name it is shown by (#977). `None` for no selection (`CB_ERR`, -1)
/// or a row past the end.
pub fn choice_value(it: &Item, selected: isize) -> Option<String> {
    usize::try_from(selected).ok().and_then(|i| it.choices.get(i)).cloned()
}

/// How wide a text box is, in 96-DPI pixels (#977; mac
/// `ConfigFormRules.fieldWidth`): a number 120, a short value 160, starting
/// on the control column; `None` takes the row -- a font, a theme pair, and
/// every box in All Options, where any key can be.
pub fn field_width(control: Control, group: Group) -> Option<i32> {
    if group == Group::All {
        return None;
    }
    match control {
        Control::Number => Some(120),
        Control::Text | Control::Color => Some(160),
        Control::Font | Control::Theme | Control::Toggle | Control::Choice | Control::ReadOnly => None,
    }
}

/// Whether a row offers "More…" for Ghostty's own help text (mac
/// `ConfigFormRules.hasMore`): there is one, and the line under the control
/// is not already the whole of it.
pub fn has_more(it: &Item) -> bool {
    let Some(doc) = it.doc.as_deref().map(str::trim).filter(|d| !d.is_empty()) else { return false };
    it.summary.is_some() || doc_summary(doc) != doc.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The line under the control with "More…" opened: the usual line, then
/// Ghostty's text in full.
pub fn expanded_help(it: &Item, translate: impl Fn(&str) -> String) -> String {
    let line = row_help(it, &translate);
    match it.doc.as_deref().map(str::trim) {
        Some(doc) if !doc.is_empty() => format!("{line}\n\n{doc}"),
        _ => line,
    }
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

// ============================================================ config file

/// How "Open config file…" opens it (task 999).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Opener {
    /// The program the machine associates with `.polter`, through the shell.
    Associated,
    /// Notepad, named: nothing claims `.polter`, and handing the file to the
    /// shell then only puts up "How do you want to open this file?" -- which
    /// the test machine did, with nothing opened. The macOS side opens the
    /// system's default text editor; Notepad is that here.
    Notepad,
}

/// `assoc_exe` is what `AssocQueryStringW(ASSOCSTR_EXECUTABLE)` answered for
/// `.polter`, or `None` when it found nothing. **The Open With picker is not
/// an editor**: some machines answer with it for an unclaimed extension.
pub fn config_opener(assoc_exe: Option<&str>) -> Opener {
    let Some(exe) = assoc_exe.map(str::trim).filter(|e| !e.is_empty()) else { return Opener::Notepad };
    let name = exe.rsplit(['\\', '/']).next().unwrap_or(exe).to_ascii_lowercase();
    if name == "openwith.exe" {
        Opener::Notepad
    } else {
        Opener::Associated
    }
}

/// The arguments Notepad is started with: the path, quoted, so a space in
/// the user name is not an argument boundary.
pub fn notepad_args(path: &str) -> String {
    format!("\"{}\"", path.trim_matches('"'))
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
            choice_labels: Vec::new(),
            min: None,
            max: None,
            default: default.into(),
            value: value.into(),
            doc: None,
            label: None,
            summary: None,
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

    fn ranged(key: &str, min: Option<f64>, max: Option<f64>) -> Item {
        let mut it = item(key, Some("appearance"), Control::Number, "1", "0.9");
        it.min = min;
        it.max = max;
        it
    }

    /// **The macOS side's `onlyANarrowRangeIsASlider`**, the same items.
    #[test]
    fn only_a_narrow_range_is_a_slider() {
        assert!(uses_slider(&ranged("background-opacity", Some(0.0), Some(1.0))));
        assert!(!uses_slider(&ranged("font-size", Some(1.0), None)));
        assert_eq!(slider_text(0.9), "0.9");
        assert_eq!(slider_text(1.0), "1");
        assert_eq!(slider_text(0.25), "0.25");
        assert_eq!(slider_text(0.0), "0");
        // And the edges of the rule: a whole integer range, an empty or
        // backwards one, and a range that is not a number's.
        assert!(!uses_slider(&ranged("scrollback", Some(0.0), Some(4294967295.0))));
        assert!(!uses_slider(&ranged("x", Some(1.0), Some(1.0))));
        assert!(!uses_slider(&ranged("x", Some(1.0), Some(0.0))));
        assert!(uses_slider(&ranged("x", Some(0.5), Some(1.5))));
        let mut t = ranged("x", Some(0.0), Some(1.0));
        t.control = Control::Text;
        assert!(!uses_slider(&t));
    }

    #[test]
    fn a_slider_only_where_the_row_is_a_writable_number_outside_all() {
        let it = ranged("background-opacity", Some(0.0), Some(1.0));
        assert!(slider_for(&it, Group::Appearance));
        assert!(!slider_for(&it, Group::All));
        let mut ro = it.clone();
        ro.readonly = Some("file".into());
        assert!(!slider_for(&ro, Group::Appearance));
    }

    #[test]
    fn slider_positions_round_trip_to_what_is_written() {
        assert_eq!(slider_pos("0.9", 0.0, 1.0), 90);
        assert_eq!(slider_pos("1", 0.0, 1.0), SLIDER_STEPS);
        assert_eq!(slider_pos("junk", 0.0, 1.0), 0);
        assert_eq!(slider_pos("7", 0.0, 1.0), SLIDER_STEPS);
        assert_eq!(slider_pos("-3", 0.0, 1.0), 0);
        // Rounded, not cut: 0.29 * 100 is 28.999... in a double, and a
        // truncating conversion would put a file's own 0.29 on step 28.
        assert_eq!(slider_pos("0.29", 0.0, 1.0), 29);
        assert_eq!(slider_pos("0.57", 0.0, 1.0), 57);
        assert_eq!(slider_pos("0.456", 0.0, 1.0), 46);
        for p in [0, 1, 25, 33, 90, 100] {
            let v = slider_value(p, 0.0, 1.0);
            assert_eq!(slider_pos(&slider_text(v), 0.0, 1.0), p, "position {p}");
        }
        assert_eq!(slider_text(slider_value(90, 0.0, 1.0)), "0.9");
        assert_eq!(slider_text(slider_value(100, 0.5, 1.5)), "1.5");
    }

    #[test]
    fn the_slider_starts_on_the_control_column_and_stops_at_240() {
        let dpi = 96;
        let wide = Rect::new(128, 0, 900, CONTROL_H);
        let (sl, tx) = slider_parts(wide, dpi);
        assert_eq!(sl.left, wide.left);
        assert_eq!(sl.width(), SLIDER_MAX_W);
        assert_eq!(tx.left, sl.right + ROW_GAP);
        assert_eq!((sl.top, sl.bottom), (wide.top, wide.bottom));
        // Narrow: the slider gives way, the value keeps its room.
        let narrow = Rect::new(128, 0, 128 + 200, CONTROL_H);
        let (sl, tx) = slider_parts(narrow, dpi);
        assert_eq!(tx.right, narrow.right);
        assert_eq!(tx.width(), SLIDER_TEXT_W);
        assert!(sl.width() < SLIDER_MAX_W);
        let (sl2, _) = slider_parts(wide, 192);
        assert_eq!(sl2.width(), 2 * SLIDER_MAX_W);
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

    /// #973: a named key shows its name, and its key before its sentence;
    /// an unnamed one is shown by its key and Ghostty's first paragraph.
    #[test]
    fn a_named_key_shows_its_name_and_its_key_before_its_sentence() {
        let zh = |s: &str| match s {
            "Font Size" => "字号".to_string(),
            "In points; may be fractional." => "以点为单位，可以带小数。".to_string(),
            other => other.to_string(),
        };
        let mut named = item("font-size", Some("font"), Control::Number, "13", "13");
        named.label = Some("Font Size".into());
        named.summary = Some("In points; may be fractional.".into());
        named.doc = Some("Font size in points.\n\nMore.".into());
        assert_eq!(row_title(&named, zh), "字号");
        assert_eq!(row_help(&named, zh), "font-size  以点为单位，可以带小数。");

        let mut unnamed = item("font-thicken", None, Control::Toggle, "false", "false");
        unnamed.doc = Some("Draw fonts thicker.\n\nMore.".into());
        assert_eq!(row_title(&unnamed, zh), "font-thicken");
        assert_eq!(row_help(&unnamed, zh), "Draw fonts thicker.");
    }

    /// #977: a value is shown by its name and written as itself; a list
    /// the table does not name is shown by its values.
    #[test]
    fn a_value_is_shown_by_its_name() {
        let zh = |s: &str| match s {
            "Never" => "从不".to_string(),
            "System Default" => "跟随系统".to_string(),
            other => other.to_string(),
        };
        let mut it = item("window-save-state", Some("window"), Control::Choice, "default", "never");
        it.choices = vec!["default".into(), "never".into(), "always".into()];
        it.choice_labels = vec!["System Default".into(), "Never".into(), "Always".into()];
        assert_eq!(choice_titles(&it, zh), ["跟随系统", "从不", "Always"]);
        // What is written is the value of the selected row, not its name.
        assert_eq!(choice_value(&it, 1).as_deref(), Some("never"));
        assert_eq!(choice_value(&it, -1), None);
        assert_eq!(choice_value(&it, 3), None);
        it.choice_labels.clear();
        assert_eq!(choice_titles(&it, zh), ["default", "never", "always"]);
    }

    #[test]
    fn a_short_box_is_sized_for_what_goes_in_it() {
        assert_eq!(field_width(Control::Number, Group::Font), Some(120));
        assert_eq!(field_width(Control::Text, Group::Appearance), Some(160));
        assert_eq!(field_width(Control::Font, Group::Font), None);
        assert_eq!(field_width(Control::Text, Group::All), None);
    }

    #[test]
    fn more_opens_ghosttys_text_under_the_line() {
        let zh = |s: &str| if s == "In points." { "以点为单位。".to_string() } else { s.to_string() };
        let mut it = item("font-size", Some("font"), Control::Number, "13", "13");
        it.label = Some("Font Size".into());
        it.summary = Some("In points.".into());
        it.doc = Some("Font size in points.\n\nMore.".into());
        assert!(has_more(&it));
        assert_eq!(expanded_help(&it, zh), "font-size  以点为单位。\n\nFont size in points.\n\nMore.");
        // Nothing more to show: a one-paragraph doc that is already the line.
        let mut plain = item("x", None, Control::Text, "", "");
        plain.doc = Some("Just this.".into());
        assert!(!has_more(&plain));
        plain.doc = None;
        assert!(!has_more(&plain));
    }

    /// #986: a refusal stays through the form's own read after the write,
    /// and goes on any other read.
    #[test]
    fn a_refusal_lasts_until_the_form_is_read_again() {
        let red = Some("font-size: invalid value".to_string());
        assert_eq!(error_after(FormRead::AfterOwnWrite, red.clone()), red);
        assert_eq!(error_after(FormRead::Reread, red), None);
        assert_eq!(error_after(FormRead::AfterOwnWrite, None), None);
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
    fn an_unclaimed_config_file_opens_in_notepad() {
        assert_eq!(config_opener(None), Opener::Notepad);
        assert_eq!(config_opener(Some("  ")), Opener::Notepad);
        assert_eq!(config_opener(Some("C:\\Windows\\System32\\OpenWith.exe")), Opener::Notepad);
        assert_eq!(config_opener(Some("C:\\Program Files\\Microsoft VS Code\\Code.exe")), Opener::Associated);
        assert_eq!(config_opener(Some("C:\\Windows\\system32\\NOTEPAD.EXE")), Opener::Associated);
        assert_eq!(notepad_args("C:\\Users\\a b\\AppData\\Local\\polter\\config.polter"), "\"C:\\Users\\a b\\AppData\\Local\\polter\\config.polter\"");
        assert_eq!(notepad_args("\"C:\\x.polter\""), "\"C:\\x.polter\"");
    }

    #[test]
    fn about_leaves_out_what_is_blank() {
        let rows = about_rows(Some("0.9.1"), Some("  "), Some("abc123"));
        assert_eq!(rows, vec![(AboutLabel::Version, "0.9.1".to_string()), (AboutLabel::Commit, "abc123".to_string())]);
        assert!(about_rows(None, None, None).is_empty());
    }
}
