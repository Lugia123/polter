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

use crate::n_;
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
    /// Log Management (task 1511): what each kind of record takes, how
    /// long it is kept, and "Clear…". Drawn by `logs_ui.rs`, not as a form.
    Logs,
    /// screenshot.md §12.1: before Keyboard Shortcuts.
    Screenshot,
    All,
    Keybinds,
    Advanced,
    About,
}

impl Group {
    pub const ALL: [Group; 11] = [
        Group::Appearance,
        Group::Font,
        Group::Terminal,
        Group::Windows,
        Group::Polter,
        Group::Logs,
        // The macOS order (`GeneralGroup`): All Options, then Screenshot
        // (task 1604; this side had them the other way round).
        Group::All,
        Group::Screenshot,
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
            Group::Logs => "logs",
            Group::Screenshot => "screenshot",
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
            Group::Appearance => n_("Appearance"),
            Group::Font => n_("Font"),
            Group::Terminal => n_("Terminal"),
            Group::Windows => n_("Windows & Tabs"),
            Group::Polter => n_("Polter"),
            Group::Logs => n_("Log Management"),
            Group::Screenshot => n_("Screenshot"),
            Group::All => n_("All Options"),
            Group::Keybinds => n_("Keyboard Shortcuts"),
            Group::Advanced => n_("Advanced"),
            Group::About => n_("About"),
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
            Group::Logs => Some("logs"),
            Group::Screenshot => Some("screenshot"),
            Group::All | Group::Keybinds | Group::Advanced | Group::About => None,
        }
    }

    /// Drawn from the core's form table. Log Management's settings are in
    /// the table (so a search finds them and says where they live), but the
    /// page is its own: each setting stands in the row of what it keeps.
    pub fn is_form(self) -> bool {
        (self.core().is_some() || self == Group::All) && self != Group::Logs
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
    /// A folder: a path box, "Choose…" and "Show in Explorer"
    /// (screenshot.md §12.3). Written like `Text`; empty restores the default.
    Directory,
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
            "directory" => Control::Directory,
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

/// What a row stands for. Only a `Key` is something the form writes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// A configuration key, from the core's `items`.
    Key,
    /// A section's `shortcuts` row (screenshot.md §12.1's last line): `key`
    /// is the action, `value` the keys bound to it now, read-only, with a
    /// link to the Keyboard Shortcuts page.
    Shortcut,
    /// A search result that is no form row -- a role, a project, a plugin,
    /// an action: `label` and `summary` are already in the user's language,
    /// and clicking it goes where it lives (screenshot.md §12.2).
    Jump,
}

/// One row of the core's table.
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub kind: Kind,
    pub key: String,
    /// The §7.1 group the core puts it in on this OS; `None` for a key only
    /// in All Options.
    pub group: Option<String>,
    pub control: Control,
    pub choices: Vec<String>,
    /// The display name of each of `choices`, same order, English msgids
    /// (#977); empty where the table names none. `None` is a value the
    /// table leaves to `choice_template`.
    pub choice_labels: Vec<Option<String>>,
    /// A msgid with one `%s`, for the values `choice_labels` leaves `None`:
    /// the value's modifiers, written this platform's way, go in
    /// (`screenshot-mouse-trigger`'s `%s + Double-Click`).
    pub choice_template: Option<String>,
    /// What a switch writes; `None` is `true` / `false`.
    /// `screenshot-agent-access` writes `allow` / `deny`, and the core
    /// refuses `true` for it.
    pub on: Option<String>,
    pub off: Option<String>,
    /// Words the search also finds this by. Not msgids; never translated.
    pub aliases: Vec<String>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub default: String,
    pub value: String,
    pub doc: Option<String>,
    /// The core's Chinese for the first paragraph of `doc` (task 1751). The
    /// host fills it only when the interface is Chinese, so its presence is
    /// the whole decision: `None` shows Ghostty's English.
    pub doc_zh: Option<String>,
    /// The Chinese for the whole of `doc` (phase B), filled on the same terms.
    pub doc_full_zh: Option<String>,
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
        return (0..items.len())
            .filter(|&i| items[i].kind == Kind::Key && (needle.is_empty() || items[i].key.to_lowercase().contains(&needle)))
            .collect();
    }
    let Some(name) = group.core() else { return Vec::new() };
    let Some((_, keys)) = sections.iter().find(|(g, _)| g == name) else { return Vec::new() };
    keys.iter().filter_map(|k| items.iter().position(|it| &it.key == k)).collect()
}

pub fn is_writable(it: &Item) -> bool {
    it.kind == Kind::Key && it.readonly.is_none() && it.control != Control::ReadOnly
}

/// The two files the read-only banner names -- the one this process reads,
/// the one the form would write -- when the core writes nothing for it
/// (`form.zig`'s `"writable": false`, #1743: a process started with
/// `--config-file`). None when the form may write, and from a core that
/// predates the field. The mac host's `ConfigFormRules.readOnlyFiles`.
pub fn read_only_files(writable: Option<bool>, reads: Option<&str>, main: &str) -> Option<(String, String)> {
    (writable == Some(false)).then(|| (reads.unwrap_or_default().to_string(), main.to_string()))
}

/// Every key row read-only, for a form the core writes nothing for. The
/// rows say nothing of their own about it (`readonly_note`): the banner over
/// them says it once.
pub fn hold_every_key(items: &mut [Item]) {
    for it in items.iter_mut().filter(|it| it.kind == Kind::Key && it.readonly.is_none()) {
        it.readonly = Some(ELSEWHERE.to_string());
    }
}

/// `form.zig`'s `Reason.elsewhere`.
pub const ELSEWHERE: &str = "elsewhere";

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
    it.kind == Kind::Key && it.value != it.default
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

/// Whether a switch is on: its value is the one it writes when turned on
/// (`on`, else `true`).
pub fn is_on(it: &Item) -> bool {
    it.value == it.on.as_deref().unwrap_or("true")
}

/// What a switch writes: the table's `on` / `off` for this key, else
/// `true` / `false`.
pub fn toggle_value(it: &Item, on: bool) -> String {
    if on {
        it.on.clone().unwrap_or_else(|| "true".to_string())
    } else {
        it.off.clone().unwrap_or_else(|| "false".to_string())
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
    // A shortcut row or a result that jumps is not a key somebody set
    // somewhere: there is nothing of that kind to explain.
    if it.kind != Kind::Key || is_writable(it) || it.readonly.as_deref() == Some(ELSEWHERE) {
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
        // Already a name in the user's language: a role, a project.
        Some(label) if it.kind == Kind::Jump => label.clone(),
        Some(label) => translate(label),
        None => it.key.clone(),
    }
}

/// The line under a row's control when nothing is wrong: for a named key,
/// the key as the config file spells it and then the form's sentence,
/// translated (#973, mac `ConfigFormView.help`); for the rest, the first
/// paragraph of Ghostty's help.
pub fn row_help(it: &Item, translate: impl Fn(&str) -> String) -> String {
    match it.kind {
        Kind::Key => {}
        // No key to spell: the sentence alone.
        Kind::Shortcut => return it.summary.as_deref().map(&translate).unwrap_or_default(),
        Kind::Jump => return it.summary.clone().unwrap_or_default(),
    }
    match (&it.label, &it.summary) {
        (Some(_), Some(summary)) => format!("{}  {}", it.key, translate(summary)),
        (Some(_), None) => it.key.clone(),
        _ => match &it.doc_zh {
            Some(zh) => zh.clone(),
            None => it.doc.as_deref().map(doc_summary).unwrap_or_default(),
        },
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

/// The values a list offers: the table's, and after them the value in
/// effect when it is not one of them -- `screenshot-mouse-trigger` set to
/// three modifiers in the config file. It is shown and selected as itself;
/// showing the first row instead would say "Off" about a trigger that is
/// on (screenshot.md §12.3).
pub fn shown_choices(it: &Item) -> Vec<String> {
    let mut out = it.choices.clone();
    if !it.value.is_empty() && !out.contains(&it.value) {
        out.push(it.value.clone());
    }
    out
}

/// `super+shift` as this platform writes a shortcut's modifiers:
/// `Shift+Win`, in the order the menus use (`keyseq::mods_label`: Ctrl,
/// Alt, Shift, Win). A word that is no modifier is kept as written, after
/// them, so a value this build does not know is still told apart.
pub fn modifiers_text(value: &str) -> String {
    const ORDER: [(&str, &str); 4] = [("ctrl", "Ctrl"), ("alt", "Alt"), ("shift", "Shift"), ("super", "Win")];
    let words: Vec<String> = value.split('+').map(|w| w.trim().to_ascii_lowercase()).filter(|w| !w.is_empty()).collect();
    let mut out: Vec<String> = ORDER.iter().filter(|(k, _)| words.iter().any(|w| w == k)).map(|(_, n)| n.to_string()).collect();
    out.extend(words.iter().filter(|w| !ORDER.iter().any(|(k, _)| k == w)).cloned());
    out.join("+")
}

/// What each of `shown_choices` is called in its list: the table's name,
/// translated; where the table leaves it to the template, the value's
/// modifiers in the translated template; else the value itself (#977; mac
/// `ConfigFormRules.choiceTitle`). What is written is always the value.
pub fn choice_titles(it: &Item, translate: impl Fn(&str) -> String) -> Vec<String> {
    let named = it.choice_labels.len() == it.choices.len();
    shown_choices(it)
        .iter()
        .enumerate()
        .map(|(i, value)| match (named.then(|| it.choice_labels.get(i).cloned().flatten()).flatten(), &it.choice_template) {
            (Some(label), _) => translate(&label),
            (None, Some(template)) => translate(template).replacen("%s", &modifiers_text(value), 1),
            (None, None) => value.clone(),
        })
        .collect()
}

/// The list row that is the value in effect; `None` only for an empty
/// value that is no choice.
pub fn choice_index(it: &Item) -> Option<usize> {
    shown_choices(it).iter().position(|c| *c == it.value)
}

/// The value to write for the list's selected row: the row's value, never
/// the name it is shown by (#977). `None` for no selection (`CB_ERR`, -1)
/// or a row past the end.
pub fn choice_value(it: &Item, selected: isize) -> Option<String> {
    usize::try_from(selected).ok().and_then(|i| shown_choices(it).get(i).cloned())
}

/// A folder row's three parts inside its control cell: the path box, then
/// "Choose…" and "Show in Explorer", each as wide as asked, a button gap
/// apart, ending on the cell's right edge. The box keeps at least a
/// control's height of width.
pub fn directory_parts(control: Rect, dpi: i32, choose_w: i32, reveal_w: i32) -> (Rect, Rect, Rect) {
    let gap = scale(BUTTONS_GAP, dpi);
    let reveal = Rect::new((control.right - reveal_w).max(control.left), control.top, control.right, control.bottom);
    let choose = Rect::new((reveal.left - gap - choose_w).max(control.left), control.top, (reveal.left - gap).max(control.left), control.bottom);
    let edit_right = (choose.left - gap).max(control.left + scale(CONTROL_H, dpi)).min(control.right);
    (Rect::new(control.left, control.top, edit_right, control.bottom), choose, reveal)
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
        Control::Font | Control::Theme | Control::Toggle | Control::Choice | Control::Directory | Control::ReadOnly => None,
    }
}

/// Whether a row offers "More…" for Ghostty's own help text (mac
/// `ConfigFormRules.hasMore`): there is one, and the line under the control
/// is not already the whole of it.
pub fn has_more(it: &Item) -> bool {
    if it.kind != Kind::Key {
        return false;
    }
    let Some(doc) = it.doc.as_deref().map(str::trim).filter(|d| !d.is_empty()) else { return false };
    it.summary.is_some() || doc_summary(doc) != doc.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The line under the control with "More…" opened: the usual line, then
/// Ghostty's text in full.
pub fn expanded_help(it: &Item, translate: impl Fn(&str) -> String) -> String {
    let line = row_help(it, &translate);
    match it.doc_full_zh.as_deref().or(it.doc.as_deref()).map(str::trim) {
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
/// sidebar's rhythm (`section_pitch` apart), from `PAD` below the list's top, with the list's text
/// edge.
pub fn group_row(list: Rect, dpi: i32, index: usize) -> Rect {
    let s = |v| scale(v, dpi);
    let top = list.top + s(ROW_GAP) + index as i32 * crate::section_pitch(dpi);
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
    let (filter, _, body) = form_area_with_banner(editor, dpi, with_filter, None);
    (filter, body)
}

/// `form_area` with the read-only banner (#1743) between the filter and the
/// rows, as the macOS page puts it: `banner_h` is its text's height, already
/// measured in the width it is given.
pub fn form_area_with_banner(editor: Rect, dpi: i32, with_filter: bool, banner_h: Option<i32>) -> (Option<Rect>, Option<Rect>, Rect) {
    let (filter, body) = form_area_plain(editor, dpi, with_filter);
    let Some(h) = banner_h else { return (filter, None, body) };
    let banner = Rect::new(body.left, body.top, body.right, body.top + h);
    let top = banner.bottom + scale(ROW_GAP, dpi);
    (filter, Some(banner), Rect::new(body.left, top, body.right, body.bottom.max(top)))
}

fn form_area_plain(editor: Rect, dpi: i32, with_filter: bool) -> (Option<Rect>, Rect) {
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

/// One row of the Keyboard Shortcuts page as it is shown: what is painted
/// and what a UI Automation client reads are this one value, so the two
/// cannot say different things.
#[derive(Clone, Default, Debug, PartialEq, Eq)]
pub struct KbShown {
    /// The action's tag.
    pub action: String,
    /// Its title, translated already; the tag when it has none.
    pub name: String,
    /// `keys_label`'s text.
    pub keys: String,
    /// The note, translated; empty when there is none.
    pub note: String,
}

impl KbShown {
    /// The row as shown. **The note is translated here, once** (#1750): the
    /// page used to keep the English and translate it when painting, so the
    /// screen said it in Chinese and a screen reader in English.
    pub fn new(action: &str, title: Option<&str>, keys: String, note: &str, tr: &dyn Fn(&str) -> String) -> Self {
        KbShown {
            action: action.to_string(),
            name: title.map_or_else(|| action.to_string(), str::to_string),
            keys,
            note: if note.is_empty() { String::new() } else { tr(note) },
        }
    }

    /// What a UI Automation client is told the row is: all three columns,
    /// as the page shows them.
    pub fn spoken(&self) -> String {
        if self.note.is_empty() {
            format!("{}  {}", self.name, self.keys)
        } else {
            format!("{}  {}  {}", self.name, self.keys, self.note)
        }
    }
}

/// The keys column as lines: whole keys, `KEY_GAP` apart, packed into at
/// most `max_lines` lines; the last ends in "…" when the rest does not fit.
/// Never a break inside a key ("Page" / "Down"), as the macOS column
/// (`KeybindsModel.keysLabel`). `label` is `keys_label`'s text, keys
/// separated by `KEY_GAP`.
///
/// **Broken here rather than by `DrawText`** (#1750): drawn with
/// `DT_WORDBREAK`, a row of three-space gaps came out with a line that
/// started with the gap's leftover spaces ("  Ctrl+Shift+V", indented) and a
/// stray third line under "Ctrl+Shift+C". What `DrawText` makes of a run of
/// spaces at a break is its own business; lines made here are drawn one at a
/// time with `DT_SINGLELINE`, and there is nothing left for it to decide.
pub fn pack_keys(label: &str, fits: impl Fn(&str) -> bool, max_lines: usize) -> Vec<String> {
    let keys: Vec<&str> = label.split(KEY_GAP).filter(|k| !k.is_empty()).collect();
    let mut lines: Vec<String> = Vec::new();
    let mut at = 0;
    while at < keys.len() && max_lines > 0 {
        if lines.len() + 1 == max_lines {
            lines.push(elide_end(&keys[at..].join(KEY_GAP), &fits));
            return lines;
        }
        let mut line = keys[at].to_string();
        at += 1;
        while at < keys.len() && fits(&format!("{line}{KEY_GAP}{}", keys[at])) {
            line = format!("{line}{KEY_GAP}{}", keys[at]);
            at += 1;
        }
        lines.push(if fits(&line) { line } else { elide_end(&line, &fits) });
    }
    lines
}

/// Between two keys in the keys column, as the macOS page writes it.
pub const KEY_GAP: &str = "   ";

/// The table's English name for an action the core gives no command for;
/// None when it has none, and the tag is what shows.
pub fn name_by_tag(tag: &str) -> Option<&'static str> {
    ACTION_NAMES.iter().find(|(t, _)| *t == tag).map(|(_, n)| *n)
}

/// Names for the actions the core gives no command for, keyed by the action's
/// tag (#1750): the macOS page's `KeybindsModel.namedByTag` table
/// (`macos/Sources/App/Base.lproj/Localizable.strings`, "The keybind listing's
/// names"), word for word, so the two pages call an action the same thing.
/// English msgids; `tr` translates them where they are shown. A test below
/// holds this to the macOS table.
pub const ACTION_NAMES: &[(&str, &str)] = &[
    ("activate_key_table", n_("Activate Key Table")),
    ("activate_key_table_once", n_("Activate Key Table Once")),
    ("adjust_selection", n_("Adjust Selection")),
    ("crash", n_("Crash (for debugging)")),
    ("csi", n_("Send CSI Sequence")),
    ("cursor_key", n_("Send Cursor Key Sequence")),
    ("deactivate_all_key_tables", n_("Deactivate All Key Tables")),
    ("deactivate_key_table", n_("Deactivate Key Table")),
    ("end_key_sequence", n_("End Key Sequence")),
    ("esc", n_("Send Escape Sequence")),
    ("goto_tab", n_("Go to Tab")),
    ("ignore", n_("Do Nothing")),
    ("jump_to_prompt", n_("Jump to Prompt")),
    ("last_tab", n_("Go to Last Tab")),
    ("next_tab", n_("Next Tab")),
    ("poltergeist_toggle_authorise", n_("Toggle: Let a Supervisor Answer Prompts")),
    ("poltergeist_toggle_worker_mentions", n_("Toggle: Let Workers Name Each Other Directly")),
    ("poltergeist_persona_set", n_("Set This Terminal's Role")),
    ("poltergeist_set_shielded", n_("Set: Keep Agents Out of This Terminal")),
    ("poltergeist_set_pane_color", n_("Set This Pane's Colour")),
    ("poltergeist_set_workers", n_("Set: Don't Start Workers in This Terminal")),
    ("poltergeist_persona_clear", n_("Clear This Terminal's Role")),
    ("poltergeist_persona_skill", n_("Switch One Skill On or Off Here")),
    ("poltergeist_persona_mcp", n_("Switch One MCP Server On or Off Here")),
    ("previous_tab", n_("Previous Tab")),
    ("resize_split", n_("Resize Split")),
    ("scroll_page_fractional", n_("Scroll by a Fraction of a Page")),
    ("scroll_page_lines", n_("Scroll by Lines")),
    ("scroll_to_row", n_("Scroll to Row")),
    ("search", n_("Search in Terminal")),
    ("set_font_size", n_("Set Font Size")),
    ("set_surface_title", n_("Set Terminal Title")),
    ("set_tab_title", n_("Set Tab Title")),
    ("set_window_title", n_("Set Window Title")),
    ("toggle_command_palette", n_("Toggle Command Palette")),
    ("toggle_quick_terminal", n_("Toggle Quick Terminal")),
    ("toggle_visibility", n_("Toggle Polter Visibility")),
    ("unbind", n_("Unbind This Key")),
    ("write_scrollback_file", n_("Write Scrollback to a File")),
];

/// The Keyboard Shortcuts columns: name, keys, note (`GeneralRules.
/// KeybindColumns`). Where less than `MIN_NOTE` is left for the note, it
/// goes on a line of its own under the keys rather than one character a
/// line.
pub const KB_NAME_W: i32 = 220;
pub const KB_KEYS_W: i32 = 160;
pub const KB_GAP: i32 = 12;
pub const KB_MIN_NOTE: i32 = 160;
/// A row -- the name, and the action's tag under it in the fixed-width face,
/// as the macOS page (task 1550; the tag is what a config file is written
/// in) -- and one with the note under those as well. Each is the height of
/// a row whose keys take two lines; one whose keys take more is taller by a
/// line for each (`kb_row_h`).
pub const KB_ROW_H: i32 = 44;
pub const KB_ROW_H_TALL: i32 = 64;
/// One line of a row: the name's, the keys', the tag's.
pub const KB_LINE_H: i32 = 20;
/// The legend line above the rows.
pub const KB_HEADER: i32 = 32;

pub fn keybind_note_below(content_w: i32, dpi: i32) -> bool {
    content_w < scale(KB_NAME_W + KB_GAP + KB_KEYS_W + KB_GAP + KB_MIN_NOTE, dpi)
}

/// How tall a row is whose keys take `lines` lines (`pack_keys` with no
/// limit): **as tall as its keys**, as a macOS row is (#1750). The page used
/// to give every row two lines and cut the rest with "…": `copy` lost
/// Ctrl+C, `paste` Ctrl+V, and `adjust_selection` showed four of its eight.
pub fn kb_row_h(lines: usize, dpi: i32, note_below: bool) -> i32 {
    let base = if note_below { KB_ROW_H_TALL } else { KB_ROW_H };
    scale(base + lines.saturating_sub(2) as i32 * KB_LINE_H, dpi)
}

/// How many rows, from `top` on, fit whole in a list `h` pixels tall;
/// `lines` is each row's lines of keys. At least one, so that a row taller
/// than the list is still shown (cut at the bottom) rather than none.
pub fn kb_fit(h: i32, dpi: i32, note_below: bool, lines: &[usize], top: usize) -> usize {
    let mut room = h - scale(KB_HEADER, dpi);
    let mut n = 0;
    for &l in lines.iter().skip(top) {
        room -= kb_row_h(l, dpi, note_below);
        if room < 0 {
            break;
        }
        n += 1;
    }
    n.max(1)
}

/// The last row the list can be scrolled to start at: the one from which
/// every row to the end fits, so that the end is reached and no further.
pub fn kb_last_top(h: i32, dpi: i32, note_below: bool, lines: &[usize]) -> usize {
    let mut room = h - scale(KB_HEADER, dpi);
    let mut top = lines.len();
    while top > 0 {
        room -= kb_row_h(lines[top - 1], dpi, note_below);
        if room < 0 {
            break;
        }
        top -= 1;
    }
    top.min(lines.len().saturating_sub(1))
}

/// Row `index`'s rectangle in a list `w` wide, scrolled so `top` is first,
/// showing `fit` rows, each as tall as `lines` says. **One function for the
/// painter, the click and the UI Automation provider**
/// (`one-place-decides-where-a-row-is.py`). `None` off the view in either
/// direction, and when the list is not showing (`top == usize::MAX`).
pub fn kb_row_rect_at(top: usize, fit: usize, dpi: i32, w: i32, note_below: bool, lines: &[usize], index: usize) -> Option<Rect> {
    if top == usize::MAX {
        return None;
    }
    let n = index.checked_sub(top)?;
    if n >= fit || index >= lines.len() {
        return None;
    }
    let y = scale(KB_HEADER, dpi) + lines[top..index].iter().map(|&l| kb_row_h(l, dpi, note_below)).sum::<i32>();
    Some(Rect::new(0, y, w, y + kb_row_h(lines[index], dpi, note_below)))
}

/// The first row shown after scrolling by `by` rows, held between the first
/// and `last` (`kb_last_top`).
pub fn kb_scroll(top: usize, by: i32, last: usize) -> usize {
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

/// The About block's version and build, as the host has them (task 1786,
/// issue #89): **Version is Polter's own** -- the host's, the number its
/// FileVersion carries and the macOS About window shows from its bundle --
/// and the core's version, which is Ghostty's numbering (what programs in
/// the terminal see as `TERM_PROGRAM_VERSION`), goes at the end of Build.
/// It used to be Version, so an About window on Windows said `1.3.2-HEAD+…`
/// where the Mac's said `0.10.2135`.
pub fn about_version_and_build(polter: &str, core: Option<&str>, mode: &str, identity: &str) -> (String, String) {
    let mut build = format!("{mode} \u{b7} {identity}");
    if let Some(core) = core.map(str::trim).filter(|c| !c.is_empty()) {
        build.push_str(&format!(" \u{b7} core {core}"));
    }
    (polter.to_string(), build)
}

/// A setting's key in the label column, broken into at most `max_lines`
/// lines after its hyphens, as the macOS form's label wraps
/// ("font-family-bold-" / "italic"); the last line ends in "…" when the rest
/// does not fit. None for a label with a space in it (a name, not a key),
/// which `DrawText`'s own word break already handles.
///
/// #1750 (1742's W3): a key wider than the column was measured as one line
/// -- `DT_WORDBREAK` does not break inside a word, it widens the box -- and
/// drawn right-aligned on one line, so its *start* fell off the left edge
/// (":-family-bold-italic").
pub fn wrap_key_label(text: &str, fits: impl Fn(&str) -> bool, max_lines: usize) -> Option<Vec<String>> {
    if text.chars().any(char::is_whitespace) || max_lines == 0 {
        return None;
    }
    if fits(text) {
        return Some(vec![text.to_string()]);
    }
    // The pieces a line may end after: each up to and including a hyphen.
    let mut pieces: Vec<&str> = Vec::new();
    let mut start = 0;
    for (i, c) in text.char_indices() {
        if c == '-' {
            pieces.push(&text[start..i + 1]);
            start = i + 1;
        }
    }
    if start < text.len() {
        pieces.push(&text[start..]);
    }
    let mut lines: Vec<String> = Vec::new();
    let mut at = 0;
    while at < pieces.len() {
        if lines.len() + 1 == max_lines {
            lines.push(elide_end(&pieces[at..].concat(), &fits));
            return Some(lines);
        }
        let mut line = pieces[at].to_string();
        at += 1;
        while at < pieces.len() && fits(&(line.clone() + pieces[at])) {
            line.push_str(pieces[at]);
            at += 1;
        }
        lines.push(if fits(&line) { line } else { elide_end(&line, &fits) });
    }
    Some(lines)
}

/// An About value cut to what fits, with the mark where the rest would be:
/// the longest start of `text` that `fits` once `…` is put after it. The
/// whole text when it fits as it is, and the mark alone when not even one
/// character does.
///
/// **The values are read-only boxes, and a box cuts without saying so**
/// (#1552): the Build line -- the build mode and this binary's identity --
/// ran off the right of the page and read as complete. Whoever shows the cut
/// one shows the whole one under the pointer.
pub fn elide_end(text: &str, fits: impl Fn(&str) -> bool) -> String {
    const MARK: &str = "\u{2026}";
    if fits(text) {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let with = |n: usize| -> String { chars[..n].iter().collect::<String>() + MARK };
    // The longest `n` whose cut fits: `fits` grows no wider as `n` shrinks.
    let (mut lo, mut hi) = (0usize, chars.len());
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        if fits(&with(mid)) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    with(lo)
}

/// How wide the tooltip that shows an About value whole may grow before it
/// wraps, in pixels, on a screen whose work area is `work_w` wide at
/// `scale`: a third of the work area, but never under 240 points or wider
/// than the work area less 16 points on each side.
///
/// **A width at all is the fix** (#1579 V9): with none the tooltip is one
/// line, and the Build line ran past the right of the screen with its
/// `mtime` cut off -- the only place the whole value is shown.
pub fn tip_max_width(work_w: i32, scale: f64) -> i32 {
    let px = |pt: f64| (pt * scale).round() as i32;
    let most = (work_w - px(32.0)).max(1);
    (work_w / 3).max(px(240.0)).min(most)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rows_note_is_read_aloud_in_the_words_it_is_shown_in() {
        let zh = |t: &str| if t == "The menu does not show this shortcut (the key still works)." { "菜单里不显示这个快捷键（按键仍然有效）。".to_string() } else { t.to_string() };
        let row = KbShown::new("paste_from_selection", Some("从选区粘贴"), "Shift+Insert".into(), "The menu does not show this shortcut (the key still works).", &zh);
        assert_eq!(row.note, "菜单里不显示这个快捷键（按键仍然有效）。");
        assert_eq!(row.spoken(), "从选区粘贴  Shift+Insert  菜单里不显示这个快捷键（按键仍然有效）。");
        // No note: no trailing gap, and nothing handed to the translator.
        let bare = KbShown::new("copy", None, "Ctrl+C".into(), "", &|_| panic!("an empty note is not translated"));
        assert_eq!(bare.spoken(), "copy  Ctrl+C");
    }

    #[test]
    fn the_about_tooltip_wraps_inside_the_screen() {
        // The test machine: 1440 wide at 100%.
        assert_eq!(tip_max_width(1440, 1.0), 480);
        // Narrow screens: never under 240pt, never past the edges.
        assert_eq!(tip_max_width(600, 1.0), 240);
        assert_eq!(tip_max_width(250, 1.0), 218);
        assert_eq!(tip_max_width(2880, 2.0), 960);
    }

    #[test]
    fn a_key_too_long_for_its_column_wraps_after_a_hyphen_and_keeps_its_start() {
        // Twelve characters a line, standing in for the column's width.
        let fits = |s: &str| s.chars().count() <= 12;
        let lines = wrap_key_label("font-family-bold-italic", fits, 2).unwrap();
        assert_eq!(lines, ["font-family-", "bold-italic"]);
        assert!(lines[0].starts_with("font"), "the start is never what is cut");
        // More than two lines' worth: the second ends in the mark.
        let lines = wrap_key_label("font-family-bold-italic-extra", fits, 2).unwrap();
        assert_eq!(lines, ["font-family-", "bold-italic\u{2026}"]);
        // One that fits stays whole; a name with a space is DrawText's.
        assert_eq!(wrap_key_label("font-style", fits, 2).unwrap(), ["font-style"]);
        assert_eq!(wrap_key_label("Font family bold", fits, 2), None);
    }

    #[test]
    fn an_about_value_that_does_not_fit_ends_in_the_mark() {
        let ten = |s: &str| s.chars().count() <= 10;
        assert_eq!(elide_end("ReleaseFast", ten), "ReleaseFa\u{2026}");
        assert_eq!(elide_end("short", ten), "short", "a value that fits is left alone");
        assert_eq!(elide_end("构建模式与标识符很长很长", ten), "构建模式与标识符很\u{2026}", "cut by character, not by byte");
        assert_eq!(elide_end("abc", |_| false), "\u{2026}", "nothing fits: the mark alone");
    }

    fn item(key: &str, group: Option<&str>, control: Control, default: &str, value: &str) -> Item {
        Item {
            kind: Kind::Key,
            key: key.into(),
            group: group.map(str::to_string),
            control,
            choices: Vec::new(),
            choice_labels: Vec::new(),
            choice_template: None,
            on: None,
            off: None,
            aliases: Vec::new(),
            min: None,
            max: None,
            default: default.into(),
            value: value.into(),
            doc: None,
            doc_zh: None,
            doc_full_zh: None,
            label: None,
            summary: None,
            source: Source::Default,
            readonly: None,
        }
    }

    #[test]
    fn group_keys_are_the_macos_raw_values() {
        let keys: Vec<_> = Group::ALL.iter().map(|g| g.key()).collect();
        // In the macOS order: `GeneralGroup`'s cases, as they are listed.
        assert_eq!(keys, ["appearance", "font", "terminal", "windows", "polter", "logs", "all", "screenshot", "keybinds", "advanced", "about"]);
        for g in Group::ALL {
            assert_eq!(Group::from_key(g.key()), Some(g));
        }
        // The core calls the window group `window`; the route calls it
        // `windows`, as the macOS side does.
        assert_eq!(Group::Windows.core(), Some("window"));
        assert!(Group::All.is_form() && !Group::Keybinds.is_form());
        // Its settings are in the core's table; its page is not a form.
        assert_eq!(Group::Logs.core(), Some("logs"));
        assert!(!Group::Logs.is_form());
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
        let plain = item("a", None, Control::Toggle, "false", "true");
        assert_eq!(toggle_value(&plain, true), "true");
        assert_eq!(toggle_value(&plain, false), "false");
    }

    /// screenshot.md §12.3: `screenshot-agent-access` is a switch whose two
    /// values are `allow` and `deny`. Writing `true` is refused by the core.
    #[test]
    fn a_switch_reads_and_writes_the_tables_own_two_values() {
        let mut it = item("screenshot-agent-access", Some("screenshot"), Control::Toggle, "allow", "allow");
        it.on = Some("allow".into());
        it.off = Some("deny".into());
        assert!(is_on(&it));
        it.value = "deny".into();
        assert!(!is_on(&it));
        // `true` is not this switch's "on".
        it.value = "true".into();
        assert!(!is_on(&it));
        assert_eq!(toggle_value(&it, true), "allow");
        assert_eq!(toggle_value(&it, false), "deny");
    }

    fn trigger(value: &str) -> Item {
        let mut it = item("screenshot-mouse-trigger", Some("screenshot"), Control::Choice, "ctrl+shift", value);
        it.choices = ["none", "super+shift", "ctrl+shift", "alt+shift", "super+alt", "ctrl+alt", "super+ctrl"].map(String::from).to_vec();
        it.choice_labels = vec![Some("Off".into()), None, None, None, None, None, None];
        it.choice_template = Some("%s + Double-Click".into());
        it
    }

    #[test]
    fn modifiers_are_written_the_way_the_menus_write_them() {
        assert_eq!(modifiers_text("ctrl+shift"), "Ctrl+Shift");
        assert_eq!(modifiers_text("super+shift"), "Shift+Win");
        assert_eq!(modifiers_text("super+ctrl"), "Ctrl+Win");
        assert_eq!(modifiers_text("shift+alt+ctrl"), "Ctrl+Alt+Shift");
        assert_eq!(modifiers_text(" Super + ALT "), "Alt+Win");
        // A word this build does not know is kept, not dropped.
        assert_eq!(modifiers_text("hyper+shift"), "Shift+hyper");
    }

    #[test]
    fn a_templated_choice_is_named_from_its_modifiers() {
        let zh = |s: &str| match s {
            "Off" => "关".to_string(),
            "%s + Double-Click" => "%s + 双击".to_string(),
            other => other.to_string(),
        };
        let it = trigger("ctrl+shift");
        assert_eq!(
            choice_titles(&it, zh),
            ["关", "Shift+Win + 双击", "Ctrl+Shift + 双击", "Alt+Shift + 双击", "Alt+Win + 双击", "Ctrl+Alt + 双击", "Ctrl+Win + 双击"]
        );
        assert_eq!(choice_index(&it), Some(2));
        assert_eq!(choice_value(&it, 0).as_deref(), Some("none"));
        assert_eq!(choice_value(&it, 6).as_deref(), Some("super+ctrl"));
    }

    /// The config file says three modifiers, which the table does not list:
    /// the list gains that value as a row of its own, selected. It must not
    /// read as the first row -- "Off" -- while the trigger is on.
    #[test]
    fn a_value_the_table_does_not_list_is_a_row_of_its_own_and_selected() {
        let it = trigger("ctrl+alt+shift");
        let titles = choice_titles(&it, |s| s.to_string());
        assert_eq!(titles.len(), 8);
        assert_eq!(titles[7], "Ctrl+Alt+Shift + Double-Click");
        assert_eq!(choice_index(&it), Some(7));
        assert_ne!(choice_index(&it), Some(0));
        // Selecting it again writes it back unchanged.
        assert_eq!(choice_value(&it, 7).as_deref(), Some("ctrl+alt+shift"));
        assert_eq!(choice_value(&it, 8), None);
        // A listed value adds no row.
        assert_eq!(shown_choices(&trigger("none")).len(), 7);
    }

    #[test]
    fn a_folder_row_is_a_box_and_two_buttons() {
        assert_eq!(Control::parse("directory"), Control::Directory);
        assert_eq!(commit_for(Control::Directory), Commit::OnEnterOrBlur);
        assert_eq!(field_width(Control::Directory, Group::Screenshot), None);
        for dpi in [96, 144] {
            let cell = Rect::new(100, 10, 600, 10 + scale(CONTROL_H, dpi));
            let (edit, choose, reveal) = directory_parts(cell, dpi, 80, 130);
            let gap = scale(BUTTONS_GAP, dpi);
            assert_eq!((edit.left, reveal.right), (cell.left, cell.right));
            assert_eq!((choose.width(), reveal.width()), (80, 130));
            assert_eq!(choose.left - edit.right, gap);
            assert_eq!(reveal.left - choose.right, gap);
            for r in [edit, choose, reveal] {
                assert_eq!((r.top, r.bottom), (cell.top, cell.bottom));
            }
        }
        // Too narrow for both buttons: nothing leaves the cell.
        let cell = Rect::new(0, 0, 120, CONTROL_H);
        let (edit, choose, reveal) = directory_parts(cell, 96, 80, 130);
        for r in [edit, choose, reveal] {
            assert!(r.left >= cell.left && r.right <= cell.right && r.left <= r.right, "{r:?}");
        }        // Narrower than one control is tall: the box still ends in the cell.
        let cell = Rect::new(0, 0, 10, CONTROL_H);
        let (edit, choose, reveal) = directory_parts(cell, 96, 80, 130);
        for r in [edit, choose, reveal] {
            assert!(r.left >= cell.left && r.right <= cell.right && r.left <= r.right, "{r:?}");
        }
    }

    fn shortcut() -> Item {
        let mut it = item("screenshot", Some("screenshot"), Control::ReadOnly, "", "Ctrl+Shift+0");
        it.kind = Kind::Shortcut;
        it.label = Some("Screenshot Shortcut".into());
        it.summary = Some("Change it with a keybind line in the config file.".into());
        it
    }

    /// §12.1's last row: read-only, with its own sentence under it and no
    /// "edit this one in the config file" -- it is not a key that was set
    /// somewhere -- and it is not one of All Options' keys.
    #[test]
    fn a_shortcut_row_is_read_only_and_says_its_own_sentence() {
        let it = shortcut();
        let zh = |s: &str| if s == "Screenshot Shortcut" { "截图快捷键".to_string() } else { format!("<{s}>") };
        assert_eq!(control_for(&it, Group::Screenshot), Control::ReadOnly);
        assert!(!is_writable(&it) && !can_restore_default(&it) && !differs_from_default(&it));
        assert_eq!(readonly_note(&it), None);
        assert_eq!(row_title(&it, zh), "截图快捷键");
        assert_eq!(row_help(&it, zh), "<Change it with a keybind line in the config file.>");
        assert!(!has_more(&it));
        let items = vec![item("font-size", Some("font"), Control::Number, "13", "13"), it];
        let sections: Sections = vec![("screenshot".into(), vec!["screenshot".into()])];
        assert_eq!(items_in(Group::Screenshot, &items, &sections, ""), vec![1]);
        assert_eq!(items_in(Group::All, &items, &sections, ""), vec![0]);
        assert_eq!(items_in(Group::All, &items, &sections, "screenshot"), Vec::<usize>::new());
    }

    /// A result that jumps carries text already in the user's language: it
    /// is not looked up again.
    #[test]
    fn a_jump_row_shows_its_text_as_given() {
        let mut it = item("", None, Control::ReadOnly, "", "");
        it.kind = Kind::Jump;
        it.label = Some("Off".into());
        it.summary = Some("A role".into());
        let zh = |s: &str| format!("<{s}>");
        assert_eq!(row_title(&it, zh), "Off");
        assert_eq!(row_help(&it, zh), "A role");
        assert_eq!(readonly_note(&it), None);
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
        it.choice_labels = vec![Some("System Default".into()), Some("Never".into()), Some("Always".into())];
        assert_eq!(choice_titles(&it, zh), ["跟随系统", "从不", "Always"]);
        // What is written is the value of the selected row, not its name.
        assert_eq!(choice_value(&it, 1).as_deref(), Some("never"));
        assert_eq!(choice_value(&it, -1), None);
        assert_eq!(choice_value(&it, 3), None);
        assert_eq!(choice_index(&it), Some(1));
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

    /// Task 1751: an unnamed key's line is the core's Chinese when the host
    /// handed it over, else Ghostty's English; "More…" does not depend on it.
    #[test]
    fn an_unnamed_key_shows_its_chinese_when_it_has_one() {
        let zh = |s: &str| format!("<{s}>");
        let mut it = item("font-thicken", None, Control::Toggle, "false", "false");
        it.label = None;
        it.doc = Some("Draw fonts thicker.\n\nMore.".into());
        assert_eq!(row_help(&it, zh), "Draw fonts thicker.");
        it.doc_zh = Some("用更粗的笔画绘制字体。".into());
        assert_eq!(row_help(&it, zh), "用更粗的笔画绘制字体。");
        assert!(has_more(&it));
        it.doc = Some("Draw fonts thicker.".into());
        assert!(!has_more(&it), "a one-paragraph doc has nothing more, in either language");
        // A key the form names keeps its own sentence.
        it.label = Some("Thicker".into());
        it.summary = Some("S".into());
        assert_eq!(row_help(&it, zh), "font-thicken  <S>");
    }

    /// Task 1751 phase B: "More…" opens the core's Chinese for the whole text
    /// when the host handed it over, else Ghostty's English.
    #[test]
    fn more_opens_the_whole_text_in_chinese_when_it_has_it() {
        let zh = |s: &str| format!("<{s}>");
        let mut it = item("font-thicken", None, Control::Toggle, "false", "false");
        it.label = None;
        it.doc = Some("Draw fonts thicker.\n\nMore.".into());
        it.doc_zh = Some("用更粗的笔画绘制字体。".into());
        assert_eq!(expanded_help(&it, zh), "用更粗的笔画绘制字体。\n\nDraw fonts thicker.\n\nMore.");
        it.doc_full_zh = Some("用更粗的笔画绘制字体。\n\n更多。".into());
        assert_eq!(expanded_help(&it, zh), "用更粗的笔画绘制字体。\n\n用更粗的笔画绘制字体。\n\n更多。");
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
        let last = Group::ALL.len() - 1;
        let r8 = group_row(list, dpi, last);
        assert_eq!(group_at(list, dpi, 5, (r8.top + r8.bottom) / 2), Some(Group::About));
        // Screenshot sits before Keyboard Shortcuts (screenshot.md §12.1).
        let at = |g: Group| Group::ALL.iter().position(|x| *x == g).unwrap();
        assert!(at(Group::Screenshot) < at(Group::Keybinds));
        let r5 = group_row(list, dpi, at(Group::Screenshot));
        assert_eq!(group_at(list, dpi, 5, (r5.top + r5.bottom) / 2), Some(Group::Screenshot));
        assert_eq!(group_at(list, dpi, 5, r0.top - 1), None);
        assert_eq!(group_at(list, dpi, list.right, r0.top + 1), None);
        // All of them fit at the smallest window.
        let (_, h) = crate::content_size(crate::MIN_W, crate::MIN_H);
        let body = h - BOTTOM - 1;
        assert!(group_row(list, 96, last).bottom <= body);
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
    fn a_form_the_core_will_not_write_holds_every_key_and_names_both_files() {
        // #1743: `--config-file=t.conf` on Windows. The core says so; the
        // host must not let a row write into the person's own file.
        let files = read_only_files(Some(false), Some("C:/t/t.conf"), "C:/u/config.polter");
        assert_eq!(files, Some(("C:/t/t.conf".to_string(), "C:/u/config.polter".to_string())));
        assert_eq!(read_only_files(Some(true), None, "C:/u/config.polter"), None);
        assert_eq!(read_only_files(None, None, "C:/u/config.polter"), None, "a core that predates the field");

        let mut items = vec![item("font-size", Some("font"), Control::Number, "13", "13"), item("title", None, Control::Text, "", "")];
        items[1].readonly = Some("file".into());
        hold_every_key(&mut items);
        assert!(!is_writable(&items[0]));
        assert!(!is_writable(&items[1]));
        // The banner says why, once; a row the core already explains keeps
        // its own reason.
        assert_eq!(readonly_note(&items[0]), None);
        assert_eq!(items[1].readonly.as_deref(), Some("file"));
    }

    #[test]
    fn the_banner_sits_between_the_filter_and_the_rows() {
        let dpi = 96;
        let editor = Rect::new(261, 0, 900, 500);
        let (f, banner, body) = form_area_with_banner(editor, dpi, true, Some(40));
        let (f, banner) = (f.unwrap(), banner.unwrap());
        assert_eq!(banner.top, f.bottom + ROW_GAP);
        assert_eq!(banner.height(), 40);
        assert_eq!(body.top, banner.bottom + ROW_GAP);
        assert_eq!((banner.left, banner.right), (body.left, body.right));
        let (_, none, plain) = form_area_with_banner(editor, dpi, true, None);
        assert!(none.is_none());
        assert_eq!(Some(plain), Some(form_area(editor, dpi, true).1));
    }

    #[test]
    fn an_action_with_no_command_is_named_by_the_table() {
        assert_eq!(name_by_tag("goto_tab"), Some("Go to Tab"));
        assert_eq!(name_by_tag("copy_to_clipboard"), None, "a command's tag is named by the core");
    }

    #[test]
    fn keys_are_packed_whole_and_no_line_starts_with_a_gap() {
        // Twenty characters a line, standing in for the column's width.
        let fits = |s: &str| s.chars().count() <= 20;
        let lines = pack_keys("Copy   Ctrl+Insert   Ctrl+Shift+C", fits, 2);
        assert_eq!(lines, ["Copy   Ctrl+Insert", "Ctrl+Shift+C"]);
        for l in &lines {
            assert!(!l.starts_with(' ') && !l.ends_with(' '), "no line carries the gap: {l:?}");
        }
        // A key with a space in it is never split.
        assert_eq!(pack_keys("Shift+Page Down   Shift+Home", fits, 2), ["Shift+Page Down", "Shift+Home"]);
        // More than two lines' worth: the second ends in the mark.
        let lines = pack_keys("Ctrl+1   Ctrl+2   Ctrl+3   Ctrl+4   Ctrl+5   Ctrl+6", fits, 2);
        assert_eq!(lines.len(), 2);
        assert!(lines[1].ends_with('\u{2026}'));
        assert_eq!(pack_keys("\u{2014}", fits, 2), ["\u{2014}"]);
    }

    #[test]
    fn the_tag_names_are_the_macos_table_word_for_word() {
        // The macOS page names these from its own table; two tables kept
        // by hand drift, so this one is read against that one.
        let mac = include_str!("../../../macos/Sources/App/Base.lproj/Localizable.strings");
        let start = mac.find("The keybind listing's names").expect("the macOS table's header");
        let section = &mac[start..];
        let section = &section[..section.find("\n\n").unwrap_or(section.len())];
        let mut theirs: Vec<(String, String)> = Vec::new();
        for line in section.lines().filter(|l| l.starts_with('"')) {
            let parts: Vec<&str> = line.split('"').collect();
            theirs.push((parts[1].to_string(), parts[3].to_string()));
        }
        let ours: Vec<(String, String)> = ACTION_NAMES.iter().map(|(t, n)| (t.to_string(), n.to_string())).collect();
        assert!(!theirs.is_empty());
        assert_eq!(ours, theirs);
    }

    #[test]
    fn keybind_rows_do_not_overlap_and_scroll_into_the_same_slots() {
        let (dpi, w) = (96, 800);
        let lines = vec![1; 100];
        let fit = kb_fit(500, dpi, false, &lines, 0);
        assert_eq!(fit, ((500 - KB_HEADER) / KB_ROW_H) as usize);
        let mut prev: Option<Rect> = None;
        for i in 0..fit {
            let r = kb_row_rect_at(0, fit, dpi, w, false, &lines, i).expect("visible");
            if let Some(p) = prev {
                assert!(r.top >= p.bottom, "row {i} overlaps");
            }
            prev = Some(r);
        }
        assert_eq!(kb_row_rect_at(0, fit, dpi, w, false, &lines, 0), kb_row_rect_at(40, fit, dpi, w, false, &lines, 40));
        assert!(kb_row_rect_at(40, fit, dpi, w, false, &lines, 39).is_none());
        assert!(kb_row_rect_at(40, fit, dpi, w, false, &lines, 40 + fit).is_none());
        assert!(kb_row_rect_at(usize::MAX, fit, dpi, w, false, &lines, 0).is_none());
        let at192 = kb_row_rect_at(0, fit, 192, 2 * w, false, &lines, 3).unwrap();
        let at96 = kb_row_rect_at(0, fit, 96, w, false, &lines, 3).unwrap();
        assert_eq!(at192.top, at96.top * 2);
    }

    /// #1750, 0x1b95 on 59dcb1462: at a 1152-wide window `adjust_selection`
    /// showed four of its eight keys and `copy` lost Ctrl+C. A row is now as
    /// tall as its keys, and the rows under it move down by as much.
    #[test]
    fn a_row_is_as_tall_as_its_keys_and_the_next_starts_under_it() {
        let (dpi, w) = (96, 800);
        // A key column that holds two keys a line: eight keys, four lines.
        let fits = |t: &str| t.split(KEY_GAP).count() <= 2;
        let eight = "Shift+Left   Shift+Right   Shift+Up   Shift+Down   Shift+Page Up   Shift+Page Down   Shift+Home   Shift+End";
        let packed = pack_keys(eight, fits, usize::MAX);
        assert_eq!(packed.len(), 4);
        assert_eq!(packed.join(KEY_GAP), eight, "every key, none cut");
        let lines = [1, packed.len(), 2, 1];
        let rows: Vec<Rect> = (0..4).map(|i| kb_row_rect_at(0, 4, dpi, w, false, &lines, i).expect("shown")).collect();
        assert_eq!(rows[0].height(), KB_ROW_H);
        assert_eq!(rows[1].height(), KB_ROW_H + 2 * KB_LINE_H);
        assert_eq!(rows[2].height(), KB_ROW_H);
        assert_eq!(rows[2].top, rows[1].bottom);
        assert_eq!(rows[3].top, KB_HEADER + 3 * KB_ROW_H + 2 * KB_LINE_H);
        // With the note under the keys, the same two extra lines.
        assert_eq!(kb_row_h(4, dpi, true), KB_ROW_H_TALL + 2 * KB_LINE_H);
        // Fewer rows fit when one is tall.
        let h = KB_HEADER + 3 * KB_ROW_H;
        assert_eq!(kb_fit(h, dpi, false, &[1, 1, 1], 0), 3);
        assert_eq!(kb_fit(h, dpi, false, &[1, 4, 1], 0), 2);
        assert_eq!(kb_fit(h, dpi, false, &[1, 4, 1], 1), 2);
    }

    #[test]
    fn a_narrow_page_puts_the_note_under_the_keys() {
        // The minimum window's editor (418 at 96 DPI on the macOS side).
        assert!(keybind_note_below(418, 96));
        assert!(!keybind_note_below(KB_NAME_W + KB_GAP + KB_KEYS_W + KB_GAP + KB_MIN_NOTE, 96));
        let lines = vec![2; 30];
        assert!(kb_fit(500, 96, true, &lines, 0) < kb_fit(500, 96, false, &lines, 0));
    }

    #[test]
    fn keybind_scrolling_holds_at_the_ends() {
        assert_eq!(kb_scroll(0, -3, 82), 0);
        assert_eq!(kb_scroll(80, 30, 82), 82);
        assert_eq!(kb_scroll(5, 1, 0), 0);
        // The last top is the one from which the rest fits: the end is
        // reached, a tall last row whole.
        let h = KB_HEADER + 3 * KB_ROW_H;
        assert_eq!(kb_last_top(h, 96, false, &[1; 10]), 7);
        assert_eq!(kb_last_top(h, 96, false, &[1, 1, 1, 1, 1, 1, 1, 1, 1, 4]), 8);
        assert_eq!(kb_last_top(h, 96, false, &[1, 1]), 0);
        assert_eq!(kb_last_top(h, 96, false, &[]), 0);
        // A row taller than the list: it can still be scrolled to.
        assert_eq!(kb_last_top(h, 96, false, &[1, 1, 9]), 2);
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
        let (version, build) = about_version_and_build("0.10.2135", Some("1.3.2-HEAD+df00a498e"), "ReleaseFast", "sha 1234");
        // Polter's, as the Mac says it; Ghostty's after the build, not instead (task 1786).
        assert_eq!(version, "0.10.2135");
        assert_eq!(build, "ReleaseFast \u{b7} sha 1234 \u{b7} core 1.3.2-HEAD+df00a498e");
        let (_, no_core) = about_version_and_build("0.10.2135", Some("  "), "Debug", "x");
        assert_eq!(no_core, "Debug \u{b7} x");

        let rows = about_rows(Some("0.9.1"), Some("  "), Some("abc123"));
        assert_eq!(rows, vec![(AboutLabel::Version, "0.9.1".to_string()), (AboutLabel::Commit, "abc123".to_string())]);
        assert!(about_rows(None, None, None).is_empty());
    }
}
