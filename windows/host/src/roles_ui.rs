//! The role library window: every role on the left, one of them being edited
//! on the right.
//!
//! A port of `macos/Sources/Features/Roles/RoleLibraryView.swift`, behaviour
//! for behaviour. The values and the five calls are `roles.rs`; this file
//! reads nothing from disk except the one height it remembers (see
//! [`height_path`]).
//!
//! **The page is computed by pure functions and painting decides nothing.**
//! The reason is where this crate's tests run: they build for Windows but run
//! without a window, so anything decided inside `WM_PAINT` or a `WM_COMMAND`
//! arm is decided where no test can look. `settings_ui.rs`'s `head_layout`
//! exists for the same reason. So:
//!
//! | question | answered by |
//! | --- | --- |
//! | what the draft is, whether it is dirty, what New/Duplicate/Revert do | [`Editor`] |
//! | which field may be typed in | [`editable`] |
//! | which button may be pressed | [`buttons`] |
//! | the `3/40` on a tab | [`tab_count`] / [`tab_label`] |
//! | whether leaving asks first | [`leave_needs_asking`] / [`selecting_is_a_change`] |
//! | what a click or a keystroke changes | [`apply`] |
//! | every row on the right, and where it goes | [`rows`] then [`place`] |
//! | where the fixed parts of the window go | [`frame_layout`] |
//! | where a role is in the list | [`role_row_rect_at`] |
//!
//! What is left below the line is Win32: creating the controls those
//! functions ask for, moving them where [`place`] says, and handing their
//! notifications to [`apply`].
//!
//! **Controls are real child windows** for the reason `settings_ui.rs` gives
//! -- an `EDIT` brings its own caret, selection and TSF document, so the
//! instructions can be typed in Chinese. They are **kept by key and
//! reconciled**, not rebuilt: rebuilding on every keystroke would destroy the
//! box being typed into. The rule that keeps the caret where it is: a field
//! that has the keyboard is never written to (see `reconcile`).
//!
//! ⚠️ **Nothing here dispatches a message while a `RefCell` is borrowed.**
//! Every block that borrows `ST` computes and returns; the Win32 calls come
//! after, with the cell released. `settings_ui.rs` records the crash that
//! taught this (`SetWindowTextW` on a custom-drawn button re-enters the
//! parent's procedure before it returns), and
//! `windows/tools/borrow-across-dispatch.py` holds every file to it.

use std::cell::{Cell as StdCell, RefCell};
use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU16, Ordering};
use std::time::{Duration, Instant};

use windows::core::{s, w, BOOL, HRESULT, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWINDOWATTRIBUTE};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW};
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::roles::{self, AgentCli, Catalog, CliChoice, CliItem, CliSnapshot, ItemGroup, ItemKind, Open, Role};
use crate::theme;

// ================================================================ the editor

/// Which part of a role is on screen. **Kept across roles on purpose**, as
/// the macOS side does: somebody going down the list tuning MCP servers
/// wants to stay on the MCP tab.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Tab {
    #[default]
    Basics,
    Skills,
    Mcp,
}

impl Tab {
    pub const ALL: [Tab; 3] = [Tab::Basics, Tab::Skills, Tab::Mcp];

    fn kind(self) -> Option<ItemKind> {
        match self {
            Tab::Basics => None,
            Tab::Skills => Some(ItemKind::Skill),
            Tab::Mcp => Some(ItemKind::Mcp),
        }
    }
}

/// The editing state: which role is selected, the copy being edited, and
/// what "saved" means for it. `RoleLibraryEditor` on the macOS side.
///
/// **A copy rather than editing in place**, because the library is the
/// core's and changes only when a save succeeds. A field typed into and never
/// saved must not look saved -- in the list, in the launch menu, anywhere.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Editor {
    pub selection: Option<String>,
    pub draft: Option<Role>,
    pub original: Option<Role>,
    pub is_new: bool,
    pub active_cli: Option<String>,
    pub status: Option<String>,
    pub tab: Tab,
    /// Whether the key still follows the name. It stops the moment the
    /// person types a key of their own.
    pub key_follows_name: bool,
}

fn taken(cat: &Catalog) -> HashSet<String> {
    cat.roles.iter().map(|r| r.key.clone()).collect()
}

impl Editor {
    pub fn is_dirty(&self) -> bool {
        match &self.draft {
            None => false,
            Some(d) => self.is_new || Some(d) != self.original.as_ref(),
        }
    }

    pub fn load(&mut self, cat: &Catalog, key: Option<&str>) {
        self.selection = key.map(str::to_string);
        self.is_new = false;
        self.status = None;
        let role = key.and_then(|k| cat.role(k)).cloned();
        self.original = role.clone();
        self.active_cli = role.as_ref().and_then(|r| r.clis.first()).map(|c| c.cli.clone());
        self.draft = role;
    }

    /// After the library changed underneath: keep the draft, refresh what
    /// "saved" means for it, and drop a selection that is gone.
    pub fn library_changed(&mut self, cat: &Catalog) {
        if self.is_new {
            return;
        }
        let Some(key) = self.draft.as_ref().map(|d| d.key.clone()).or_else(|| self.selection.clone()) else {
            return;
        };
        match cat.role(&key) {
            Some(fresh) => {
                if !self.is_dirty() {
                    self.draft = Some(fresh.clone());
                }
                self.original = Some(fresh.clone());
            }
            None if !self.is_dirty() => self.load(cat, None),
            None => {}
        }
    }

    /// Call only once leaving the current draft has been agreed to.
    pub fn new_role(&mut self, cat: &Catalog, clis: &CliSnapshot) {
        let mut role = Role::new(&Role::suggested_key("", &taken(cat)), &tr("New Role"));
        // The first CLI there is, so the list to pick from is on the screen
        // straight away instead of behind one more click.
        if let Some(first) = clis.clis.first() {
            role.clis = vec![CliChoice::new(&first.key)];
        }
        self.selection = None;
        self.is_new = true;
        self.key_follows_name = true;
        self.original = None;
        self.active_cli = role.clis.first().map(|c| c.cli.clone());
        self.draft = Some(role);
        self.status = None;
    }

    /// Call only once leaving the current draft has been agreed to.
    pub fn duplicate(&mut self, cat: &Catalog) {
        let Some(source) = self.draft.clone() else { return };
        let mut role = source.clone();
        // A copy of a built-in role is the user's: theirs to change, and
        // saved under a key of its own.
        role.builtin = false;
        role.name = tr("{} Copy").replace("{}", &source.display_name());
        role.summary = source.display_summary();
        role.key = Role::suggested_key(&source.key, &taken(cat));
        self.selection = None;
        self.is_new = true;
        self.key_follows_name = false;
        self.original = None;
        self.active_cli = role.clis.first().map(|c| c.cli.clone());
        self.draft = Some(role);
        self.status = None;
    }

    pub fn name_changed(&mut self, cat: &Catalog) {
        if !(self.is_new && self.key_follows_name) {
            return;
        }
        let t = taken(cat);
        if let Some(d) = self.draft.as_mut() {
            d.key = Role::suggested_key(&d.name, &t);
        }
    }

    pub fn set_cli(&mut self, cli: &str, used: bool) {
        let Some(role) = self.draft.as_mut() else { return };
        if used {
            if role.choice(cli).is_none() {
                role.clis.push(CliChoice::new(cli));
            }
            self.active_cli = Some(cli.to_string());
        } else {
            role.clis.retain(|c| c.cli != cli);
            if self.active_cli.as_deref() == Some(cli) {
                self.active_cli = role.clis.first().map(|c| c.cli.clone());
            }
        }
    }

    pub fn update_choice(&mut self, cli: &str, change: impl FnOnce(&mut CliChoice)) {
        if let Some(c) = self.draft.as_mut().and_then(|d| d.choice_mut(cli)) {
            change(c);
        }
    }

    /// What `put` should be handed, or why not.
    ///
    /// `Ok(None)` is a built-in role: there is nothing of the user's to save,
    /// and leaving it is fine. **Checked here and not left to the core** for
    /// the one case the core cannot tell apart: a *new* role whose key is
    /// already used would be a replacement to the core, and the user asked for
    /// a new one.
    pub fn save_request(&self, cat: &Catalog) -> Result<Option<Role>, String> {
        let Some(role) = self.draft.as_ref() else { return Ok(None) };
        if role.builtin {
            return Ok(None);
        }
        if self.is_new && cat.role(&role.key).is_some() {
            return Err(tr("Another role already uses this key."));
        }
        Ok(Some(role.clone()))
    }

    /// The core took the role; `cat` is the library read back after it.
    pub fn saved(&mut self, cat: &Catalog, key: &str) {
        let fallback = self.draft.clone();
        self.is_new = false;
        self.status = None;
        self.selection = Some(key.to_string());
        self.original = cat.role(key).cloned().or(fallback);
        self.draft = self.original.clone();
    }

    pub fn revert(&mut self, cat: &Catalog) {
        if self.is_new {
            self.load(cat, None);
        } else {
            let key = self.draft.as_ref().map(|d| d.key.clone());
            self.load(cat, key.as_deref());
        }
    }
}

// ================================================= what may be done, and when

/// Whether leaving the draft has to ask first. The same question for
/// selecting another role, New, Duplicate and closing the window.
pub fn leave_needs_asking(ed: &Editor) -> bool {
    ed.is_dirty()
}

/// Whether clicking `key` in the list changes anything. Clicking the role
/// already open is not leaving it, and must not ask.
pub fn selecting_is_a_change(ed: &Editor, key: &str) -> bool {
    ed.is_new || ed.draft.as_ref().map(|d| d.key.as_str()) != Some(key)
}

/// Which parts of the draft can be typed into.
///
/// **A built-in role is read-only, not hidden** -- what it does is the point
/// of looking at it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Editable {
    pub name: bool,
    pub key: bool,
    pub summary: bool,
    pub instructions: bool,
    /// Supervisor, may-authorise, shield, and "open in".
    pub polter: bool,
    pub watch: bool,
    pub quiet: bool,
    pub clis: bool,
    pub start: bool,
    pub items: bool,
}

pub fn editable(ed: &Editor) -> Editable {
    let Some(d) = ed.draft.as_ref() else { return Editable::default() };
    let own = !d.builtin;
    let p = &d.polter;
    Editable {
        name: own,
        // A key is chosen once: after saving, roles and terminals refer to
        // the role by it.
        key: own && ed.is_new,
        summary: own,
        instructions: own,
        polter: own,
        // A supervisor watches, it is not watched; a shielded terminal is out
        // of every tool's reach, a supervisor's included.
        watch: own && !p.supervisor && !p.shielded,
        quiet: own && !p.shielded,
        clis: own,
        start: own,
        items: own,
    }
}

/// Which buttons may be pressed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Buttons {
    pub new: bool,
    pub duplicate: bool,
    pub delete: bool,
    pub launch: bool,
    pub revert: bool,
    pub save: bool,
}

/// `can_launch`: is there a terminal to open the tab beside. Asked by the
/// caller every time, because a window can open or close while this one
/// stays up.
pub fn buttons(ed: &Editor, cat: &Catalog, can_launch: bool) -> Buttons {
    let broken = cat.error.is_some();
    let dirty = ed.is_dirty();
    let has = ed.draft.is_some();
    let builtin = ed.draft.as_ref().is_some_and(|d| d.builtin);
    let clis = ed.draft.as_ref().map_or(0, |d| d.clis.len());
    Buttons {
        new: !broken,
        duplicate: has && !broken,
        delete: has && !builtin && !broken,
        // **Unsaved changes block a launch**: the core launches what is in the
        // file, so launching a dirty draft would start something other than
        // what is on the screen.
        launch: has && !dirty && clis > 0 && can_launch,
        revert: dirty,
        save: dirty && !broken,
    }
}

/// The sentence the footer shows when nothing more urgent is there. On the
/// macOS side this is the launch button's tooltip; here it is visible,
/// because a greyed button with no reason next to it is a button that looks
/// broken.
pub fn footer_note(ed: &Editor, can_launch: bool) -> Option<(String, bool)> {
    if let Some(s) = &ed.status {
        return Some((s.clone(), true));
    }
    ed.draft.as_ref()?;
    if ed.is_dirty() {
        return Some((tr("Unsaved changes"), false));
    }
    if !can_launch {
        return Some((tr("Open a terminal window first; the new tab goes beside it."), false));
    }
    None
}

/// Kept of installed, for the CLI on screen: `(kept, all)`. `None` when there
/// is no CLI, or it has nothing of this kind -- a `0/0` says nothing.
pub fn tab_count(ed: &Editor, clis: &CliSnapshot, kind: ItemKind) -> Option<(usize, usize)> {
    let key = ed.active_cli.as_deref()?;
    let cli = clis.cli(key)?;
    let choice = ed.draft.as_ref()?.choice(key)?;
    let all = cli.items_of(kind);
    if all.is_empty() {
        return None;
    }
    let sel = match kind {
        ItemKind::Skill => &choice.skills,
        ItemKind::Mcp => &choice.mcp,
    };
    Some((all.iter().filter(|i| i.locked || sel.is_on(&i.id)).count(), all.len()))
}

pub fn tab_label(tab: Tab, ed: &Editor, clis: &CliSnapshot) -> String {
    let count = |k| tab_count(ed, clis, k).map(|(on, all)| format!("{on}/{all}"));
    match tab {
        Tab::Basics => tr("Basics"),
        Tab::Skills => match count(ItemKind::Skill) {
            Some(c) => tr("Skills {}").replace("{}", &c),
            None => tr("Skills"),
        },
        Tab::Mcp => match count(ItemKind::Mcp) {
            Some(c) => tr("MCP {}").replace("{}", &c),
            None => tr("MCP"),
        },
    }
}

// ============================================================ the left list

/// One row of the role list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListRow {
    /// `None` for the unsaved new role, which has no key of its own yet in
    /// the library and cannot be clicked back to.
    pub key: Option<String>,
    pub title: String,
    pub subtitle: String,
    /// Comes with Polter: drawn with a lock.
    pub builtin: bool,
    /// Drawn with a dot.
    pub unsaved: bool,
    pub selected: bool,
}

pub fn list_rows(ed: &Editor, cat: &Catalog, clis: &CliSnapshot) -> Vec<ListRow> {
    let row = |r: &Role, key: Option<String>, unsaved: bool, selected: bool| ListRow {
        key,
        title: if r.display_name().is_empty() { r.key.clone() } else { r.display_name() },
        subtitle: if r.clis.is_empty() {
            tr("No agent CLI")
        } else {
            r.clis.iter().map(|c| clis.label(&c.cli)).collect::<Vec<_>>().join(" · ")
        },
        builtin: r.builtin,
        unsaved,
        selected,
    };
    let mut out = Vec::new();
    if ed.is_new {
        if let Some(d) = &ed.draft {
            out.push(row(d, None, true, true));
        }
    }
    for r in &cat.roles {
        let open = !ed.is_new && ed.draft.as_ref().is_some_and(|d| d.key == r.key);
        // The dot goes on the saved row while its draft is dirty: what the
        // list shows is the library, and the dot says the screen differs.
        out.push(row(r, Some(r.key.clone()), open && ed.is_dirty(), open));
    }
    out
}

/// The sentence where the list would be, when there is no list. **Empty is
/// not the same as not read yet**: `loaded == false` is a library nobody has
/// looked at.
pub fn list_empty_note(ed: &Editor, cat: &Catalog) -> Option<(String, String)> {
    if !cat.roles.is_empty() || ed.is_new {
        return None;
    }
    if !cat.loaded {
        return Some((tr("Reading the role library…"), String::new()));
    }
    Some((
        tr("No roles yet"),
        tr("A role is a saved way to start an agent CLI: which skills and MCP servers it keeps, and what it's told."),
    ))
}

// ============================================================ the right pane

/// Which font a piece of text is drawn in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Font {
    Normal,
    Bold,
    Small,
    Mono,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    Text,
    Dim,
    Warn,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Width {
    Fixed(i32),
    /// As wide as its text, or the control's natural size.
    Auto,
    /// What is left, shared between every `Fill` in the row.
    Fill,
}

/// One thing in a row: text the pane paints, or a control it creates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    /// `lines == 1` is one line cut with an ellipsis; `0` wraps without
    /// limit; more wraps up to that many.
    Text { text: String, tone: Tone, font: Font, right: bool, lines: u32 },
    /// The padlock beside a built-in role or a locked item.
    Lock,
    /// `height` in DIP. `multi` is the instructions box.
    Edit { text: String, cue: String, multi: bool, height: i32, mono: bool, number: bool },
    Check { text: String, on: bool },
    Button { text: String },
    /// A flat button that reads as a link: Keep All, Show More, a group's
    /// header.
    Link { text: String },
    /// One of a row of buttons of which one is chosen: the CLI switcher.
    Segment { text: String, selected: bool },
    Combo { options: Vec<String>, sel: usize },
    /// The strip under the instructions box that drags it taller.
    Grip,
}

impl Kind {
    pub fn is_control(&self) -> bool {
        !matches!(self, Kind::Text { .. } | Kind::Lock | Kind::Grip)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cell {
    /// The control's identity across refreshes, and what its notifications
    /// are mapped back to. Empty for painted text.
    pub key: String,
    pub kind: Kind,
    pub width: Width,
    pub enabled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub cells: Vec<Cell>,
    /// DIP from the pane's left padding.
    pub indent: i32,
    /// DIP above the row, on top of the ordinary gap.
    pub gap: i32,
}

/// Everything [`rows`] reads.
pub struct View<'a> {
    pub ed: &'a Editor,
    pub clis: &'a CliSnapshot,
    /// DIP.
    pub instr_h: i32,
    pub search: &'a str,
    pub collapsed: &'a HashSet<String>,
    pub expanded: &'a HashSet<String>,
}

const LABEL_W: i32 = 104;
const LABEL_GAP: i32 = 10;
const SECTION_GAP: i32 = 12;
pub const INSTR_DEFAULT: i32 = 240;
pub const INSTR_MIN: i32 = 100;
pub const INSTR_MAX: i32 = 900;
const QUIET_MIN_MINUTES: u64 = 1;
const QUIET_MAX_MINUTES: u64 = 240;
const QUIET_DEFAULT_MS: u64 = 10 * 60_000;

fn text(t: impl Into<String>, tone: Tone, font: Font) -> Cell {
    Cell {
        key: String::new(),
        kind: Kind::Text { text: t.into(), tone, font, right: false, lines: 0 },
        width: Width::Fill,
        enabled: true,
    }
}
fn short(t: impl Into<String>, tone: Tone, font: Font) -> Cell {
    Cell {
        key: String::new(),
        kind: Kind::Text { text: t.into(), tone, font, right: false, lines: 1 },
        width: Width::Auto,
        enabled: true,
    }
}
fn ctl(key: impl Into<String>, kind: Kind, width: Width, enabled: bool) -> Cell {
    Cell { key: key.into(), kind, width, enabled }
}
fn row(cells: Vec<Cell>) -> Row {
    Row { cells, indent: 0, gap: 0 }
}
fn heading(t: impl Into<String>) -> Row {
    Row { cells: vec![text(t, Tone::Text, Font::Bold)], indent: 0, gap: SECTION_GAP }
}
fn note(t: impl Into<String>, indent: i32) -> Row {
    Row { cells: vec![text(t, Tone::Dim, Font::Small)], indent, gap: 0 }
}
fn edit(text: &str, cue: String, mono: bool) -> Kind {
    Kind::Edit { text: text.to_string(), cue, multi: false, height: FIELD_H, mono, number: false }
}
/// A label in the left column and something beside it, the macOS
/// `labeled(...)`.
fn field(label: String, cell: Cell) -> Row {
    let lab = Cell {
        key: String::new(),
        kind: Kind::Text { text: label, tone: Tone::Dim, font: Font::Normal, right: true, lines: 1 },
        width: Width::Fixed(LABEL_W),
        enabled: true,
    };
    row(vec![lab, cell])
}
fn check(key: impl Into<String>, t: impl Into<String>, on: bool, enabled: bool) -> Cell {
    ctl(key, Kind::Check { text: t.into(), on }, Width::Auto, enabled)
}

pub fn quiet_minutes(ms: u64) -> u64 {
    (ms / 60_000).max(QUIET_MIN_MINUTES)
}

/// What the minutes box means, or `None` for a box that says nothing yet --
/// an empty field half-way through being retyped is not a request for zero.
pub fn parse_minutes(text: &str) -> Option<u64> {
    let n: u64 = text.trim().parse().ok()?;
    Some(n.clamp(QUIET_MIN_MINUTES, QUIET_MAX_MINUTES) * 60_000)
}

/// The CLI a skills or MCP tab is showing: the active one, or the first.
fn shown_cli(ed: &Editor) -> Option<String> {
    let d = ed.draft.as_ref()?;
    ed.active_cli.clone().filter(|c| d.choice(c).is_some()).or_else(|| d.clis.first().map(|c| c.cli.clone()))
}

/// Every item of one kind, and those the filter lets through.
///
/// **Case-insensitive against name, description and group**, as the macOS
/// side filters -- a person who remembers "the one about browsers" types
/// that, not its name.
pub fn items_in_view(cli: &AgentCli, kind: ItemKind, search: &str) -> (Vec<CliItem>, Vec<CliItem>) {
    let all: Vec<CliItem> = cli.items_of(kind).into_iter().cloned().collect();
    let q = search.trim().to_lowercase();
    if q.is_empty() {
        return (all.clone(), all);
    }
    let visible = all
        .iter()
        .filter(|i| {
            i.name.to_lowercase().contains(&q)
                || i.summary.to_lowercase().contains(&q)
                || i.group.as_deref().unwrap_or(&i.source).to_lowercase().contains(&q)
        })
        .cloned()
        .collect();
    (all, visible)
}

/// The CLI switcher, shown when a role is set up for more than one.
fn cli_segments(ed: &Editor, clis: &CliSnapshot) -> Option<Row> {
    let d = ed.draft.as_ref()?;
    if d.clis.len() < 2 {
        return None;
    }
    let active = shown_cli(ed);
    let cells = d
        .clis
        .iter()
        .map(|c| {
            ctl(
                format!("seg:{}", c.cli),
                Kind::Segment { text: clis.label(&c.cli), selected: active.as_deref() == Some(&c.cli) },
                Width::Auto,
                true,
            )
        })
        .collect();
    Some(Row { cells, indent: 0, gap: 4 })
}

/// Every row of the right-hand pane, top to bottom.
pub fn rows(v: &View) -> Vec<Row> {
    let Some(d) = v.ed.draft.as_ref() else {
        return vec![Row {
            cells: vec![text(tr("Select a role, or make a new one."), Tone::Dim, Font::Normal)],
            indent: 0,
            gap: 40,
        }];
    };
    match v.ed.tab.kind() {
        None => basics_rows(v, d),
        Some(kind) => item_rows(v, d, kind),
    }
}

fn basics_rows(v: &View, d: &Role) -> Vec<Row> {
    let e = editable(v.ed);
    let mut out = Vec::new();

    out.push(field(tr("Name"), ctl("name", edit(&d.display_name(), String::new(), false), Width::Fill, e.name)));
    if v.ed.is_new {
        out.push(field(tr("Key"), ctl("key", edit(&d.key, String::new(), true), Width::Fill, e.key)));
        let ok = Role::is_valid_key(&d.key);
        let (t, tone) = if ok {
            (tr("Lowercase letters, digits and dashes. It can't be changed after saving."), Tone::Dim)
        } else {
            (tr("Only lowercase letters, digits and dashes, at most 32."), Tone::Warn)
        };
        out.push(Row { cells: vec![text(t, tone, Font::Small)], indent: LABEL_W + LABEL_GAP, gap: -2 });
    } else {
        // Read-only rather than painted: a key is the thing people copy.
        out.push(field(tr("Key"), ctl("key", edit(&d.key, String::new(), true), Width::Fill, false)));
    }
    out.push(field(
        tr("Description"),
        ctl("summary", edit(&d.display_summary(), tr("What this role is for, for whoever picks it"), false), Width::Fill, e.summary),
    ));

    out.push(heading(tr("Instructions")));
    out.push(row(vec![ctl(
        "instr",
        Kind::Edit { text: d.instructions.clone(), cue: String::new(), multi: true, height: v.instr_h, mono: false, number: false },
        Width::Fill,
        e.instructions,
    )]));
    // The grip sits flush under the box: a gap would read as a separate
    // thing rather than the box's own bottom edge.
    out.push(Row { cells: vec![ctl("grip", Kind::Grip, Width::Fill, true)], indent: 0, gap: -ROW_GAP });
    out.push(note(
        tr("Added to the agent's system prompt when it starts. Leave it empty to add nothing. Drag the bottom edge to make the box taller."),
        0,
    ));

    let p = &d.polter;
    out.push(heading(tr("Polter")));
    out.push(row(vec![check("sup", tr("Make this terminal a supervisor"), p.supervisor, e.polter)]));
    out.push(row(vec![check("auth", tr("Let the supervisor answer this terminal's permission prompts"), p.may_authorise, e.polter)]));
    out.push(row(vec![check("shield", tr("Shield it: no tool can reach it, a supervisor's included"), p.shielded, e.polter)]));
    out.push(note(
        tr("These three give the terminal something, so only you can set them, here. A supervisor that edits roles can't change them."),
        20,
    ));
    out.push(Row { cells: vec![check("watch", tr("Hand it to the supervisor to watch"), p.watch, e.watch)], indent: 0, gap: 4 });
    // The macOS side has this as the toggle's tooltip. Here it is on the
    // page: the rule is not guessable, and a hover nobody makes teaches
    // nothing.
    out.push(note(tr("The supervisor that started it, or the only one there is. With several and you starting it, nobody."), 20));
    let mut quiet = vec![check("quiet", tr("Report it as still after"), p.quiet_ms.is_some(), e.quiet)];
    if let Some(ms) = p.quiet_ms {
        quiet.push(ctl(
            "quietmin",
            Kind::Edit { text: quiet_minutes(ms).to_string(), cue: String::new(), multi: false, height: FIELD_H, mono: false, number: true },
            Width::Fixed(56),
            e.quiet,
        ));
        quiet.push(short(tr("min"), Tone::Dim, Font::Normal));
    }
    out.push(row(quiet));
    out.push(Row {
        cells: vec![
            short(tr("Open in"), Tone::Dim, Font::Normal),
            ctl(
                "open",
                Kind::Combo {
                    options: vec![tr("Here when at a prompt, else a new tab"), tr("Always a new tab")],
                    sel: usize::from(p.open == Open::Tab),
                },
                Width::Auto,
                e.polter,
            ),
        ],
        indent: 0,
        gap: 4,
    });
    out.push(note(
        tr("Applied once, when the role starts an agent CLI. Putting the role on a terminal that's already running changes its tools, not these."),
        0,
    ));

    out.push(heading(tr("Agent CLIs")));
    if v.clis.stale && v.clis.clis.is_empty() {
        out.push(note(tr("Reading what's installed…"), 0));
    } else if v.clis.clis.is_empty() {
        out.push(note(tr("No plugin that manages an agent CLI is installed and switched on."), 0));
    } else {
        for c in &v.clis.clis {
            let mut cells = vec![check(format!("cli:{}", c.key), c.label.clone(), d.choice(&c.key).is_some(), e.clis)];
            if c.installed == Some(false) {
                cells.push(short(tr("{} isn't on this machine's PATH").replace("{}", &c.bin), Tone::Warn, Font::Small));
            }
            if c.error.is_some() {
                cells.push(short(tr("Its plugin couldn't list what's installed"), Tone::Warn, Font::Small));
            }
            out.push(row(cells));
        }
        // Choices for a CLI no plugin offers any more are still in the role;
        // say so rather than hide them.
        for orphan in d.clis.iter().filter(|c| v.clis.cli(&c.cli).is_none()) {
            out.push(row(vec![
                check(format!("orphan:{}", orphan.cli), orphan.cli.clone(), true, e.clis),
                short(tr("No plugin manages this CLI any more"), Tone::Warn, Font::Small),
            ]));
        }
        if let Some(seg) = cli_segments(v.ed, v.clis) {
            out.push(seg);
        }
    }

    if let Some(cli) = v.ed.active_cli.as_deref() {
        if let Some(choice) = d.choice(cli) {
            out.push(heading(tr("Starting {}").replace("{}", &v.clis.label(cli))));
            out.push(field(
                tr("Model"),
                ctl("model", edit(&choice.model, tr("The CLI's default"), false), Width::Fixed(260), e.start),
            ));
            // A command line, not a sentence, so the cue is not translated.
            out.push(field(
                tr("Extra Arguments"),
                ctl("args", edit(&roles::args_join(&choice.args), "--permission-mode auto".into(), true), Width::Fill, e.start),
            ));
            out.push(Row {
                cells: vec![text(tr("Added to the command line as typed. Quote anything with a space in it."), Tone::Dim, Font::Small)],
                indent: LABEL_W + LABEL_GAP,
                gap: -2,
            });
        }
    }
    out
}

/// A plugin's item is named `plugin:item`; under that plugin's own header
/// the prefix only says the header again.
fn item_display_name(item: &CliItem, group: &ItemGroup) -> String {
    if group.id.starts_with("plugin:") {
        if let Some(rest) = item.name.strip_prefix(&format!("{}:", group.title)) {
            return rest.to_string();
        }
    }
    item.name.clone()
}

/// A description long enough to be cut at three lines gets a Show More.
pub fn is_long(summary: &str) -> bool {
    summary.chars().count() > 160 || summary.contains('\n')
}

fn item_rows(v: &View, d: &Role, kind: ItemKind) -> Vec<Row> {
    let e = editable(v.ed);
    let mut out = Vec::new();
    if d.clis.is_empty() {
        out.push(note(tr("Pick an agent CLI under Basics first: skills and MCP servers belong to a CLI."), 0));
        out.push(row(vec![ctl("gobasics", Kind::Link { text: tr("Go to Basics") }, Width::Auto, true)]));
        return out;
    }
    if let Some(seg) = cli_segments(v.ed, v.clis) {
        out.push(seg);
    }
    let Some(key) = shown_cli(v.ed) else { return out };
    let Some(cli) = v.clis.cli(&key) else {
        out.push(note(
            if v.clis.stale { tr("Reading what's installed…") } else { tr("No plugin manages this CLI any more") },
            0,
        ));
        return out;
    };

    if let Some(err) = &cli.error {
        out.push(row(vec![text(tr("Its plugin couldn't list what's installed"), Tone::Warn, Font::Normal)]));
        out.push(note(err.clone(), 0));
    }

    let (cue, title, keep_later, none, elsewhere) = match kind {
        ItemKind::Skill => (
            tr("Filter skills"),
            tr("Skills"),
            tr("Keep skills installed later"),
            tr("No skills are installed for this CLI."),
            tr("This list is what the CLI has on this machine. A project's own skills aren't in it; at launch they follow the switch above."),
        ),
        ItemKind::Mcp => (
            tr("Filter MCP servers"),
            tr("MCP Servers"),
            tr("Keep MCP servers added later"),
            tr("No MCP servers are configured for this CLI."),
            tr("This list is what the CLI has on this machine. A project's own MCP servers aren't in it; at launch they follow the switch above."),
        ),
    };
    out.push(Row {
        cells: vec![
            ctl("search", edit(v.search, cue, false), Width::Fill, true),
            // A glyph, not a word: it is the macOS side's arrow, and there is
            // nothing to translate.
            ctl("reload", Kind::Button { text: "↻".into() }, Width::Fixed(36), !v.clis.refreshing),
        ],
        indent: 0,
        gap: 4,
    });

    let choice = d.choice(&key);
    let sel = choice.map(|c| match kind {
        ItemKind::Skill => c.skills.clone(),
        ItemKind::Mcp => c.mcp.clone(),
    });
    let sel = sel.unwrap_or_default();
    let (all, visible) = items_in_view(cli, kind, v.search);
    let kept = all.iter().filter(|i| i.locked || sel.is_on(&i.id)).count();

    out.push(Row {
        cells: vec![
            short(title, Tone::Text, Font::Bold),
            short(tr("{} of {} kept").replacen("{}", &kept.to_string(), 1).replacen("{}", &all.len().to_string(), 1), Tone::Dim, Font::Small),
            text("", Tone::Dim, Font::Small),
            ctl("keepall", Kind::Link { text: tr("Keep All") }, Width::Auto, e.items && !visible.is_empty()),
            ctl("alloff", Kind::Link { text: tr("Turn All Off") }, Width::Auto, e.items && !visible.is_empty()),
        ],
        indent: 0,
        gap: SECTION_GAP,
    });
    out.push(row(vec![check("keepdef", keep_later, sel.keep_by_default, e.items)]));
    out.push(note(
        tr("What happens to anything that isn't listed here yet, such as something installed tomorrow or a project's own."),
        26,
    ));
    // **What the window asks is not what a launch asks.** The inventory is
    // the core's cache, read once per CLI with no directory; a launch asks
    // again from the terminal's own, so a project's `.mcp.json` and
    // `.claude/skills` are in that answer and never in this list. The role
    // does cover them -- through the default above -- and a list that shows
    // fewer things than the launch keeps has to say which it is.
    out.push(note(elsewhere, 26));

    if all.is_empty() {
        out.push(row(vec![text(none, Tone::Dim, Font::Normal)]));
    } else if visible.is_empty() {
        out.push(row(vec![text(tr("Nothing matches the filter."), Tone::Dim, Font::Normal)]));
    }

    for g in ItemGroup::groups(&visible) {
        let collapsed = v.collapsed.contains(&g.id);
        let on = g.items.iter().filter(|i| i.locked || sel.is_on(&i.id)).count();
        let chevron = if collapsed { "▶" } else { "▼" };
        out.push(Row {
            cells: vec![
                ctl(format!("gcollapse:{}", g.id), Kind::Link { text: format!("{chevron}  {}", g.title) }, Width::Auto, true),
                short(format!("{on}/{}", g.items.len()), Tone::Dim, Font::Small),
                text("", Tone::Dim, Font::Small),
                // The whole group at once. The macOS side's switch; its
                // tooltip becomes the label, for the same reason as the
                // watch note above.
                check(format!("gtoggle:{}", g.id), tr("Keep or turn off everything in this group"), on == g.items.len(), e.items),
            ],
            indent: 0,
            gap: 8,
        });
        if collapsed {
            continue;
        }
        if let Some(s) = g.summary.as_deref().filter(|s| !s.is_empty()) {
            out.push(note(s.to_string(), 24));
        }
        for item in &g.items {
            let is_on = item.locked || sel.is_on(&item.id);
            let mut cells = vec![check(format!("item:{}", item.id), item_display_name(item, &g), is_on, e.items && !item.locked)];
            if item.locked {
                cells.push(Cell { key: String::new(), kind: Kind::Lock, width: Width::Fixed(12), enabled: true });
            }
            if !item.detail.is_empty() {
                cells.push(short(item.detail.clone(), Tone::Dim, Font::Mono));
            }
            out.push(Row { cells, indent: 8, gap: 2 });
            // A plugin's MCP server carries the plugin's description as its
            // own; under that plugin's header it would only say the same
            // paragraph twice.
            if !item.summary.is_empty() && Some(item.summary.as_str()) == g.summary.as_deref() {
                continue;
            }
            if item.summary.is_empty() {
                out.push(Row { cells: vec![text(tr("No description"), Tone::Dim, Font::Small)], indent: 34, gap: -4 });
                continue;
            }
            let expanded = v.expanded.contains(&item.id);
            let lines = if expanded { 0 } else { 3 };
            out.push(Row {
                cells: vec![Cell {
                    key: String::new(),
                    kind: Kind::Text { text: item.summary.clone(), tone: Tone::Dim, font: Font::Small, right: false, lines },
                    width: Width::Fill,
                    enabled: true,
                }],
                indent: 34,
                gap: -4,
            });
            if is_long(&item.summary) {
                let label = if expanded { tr("Show Less") } else { tr("Show More") };
                out.push(Row {
                    cells: vec![ctl(format!("more:{}", item.id), Kind::Link { text: label }, Width::Auto, true)],
                    indent: 30,
                    gap: -4,
                });
            }
        }
    }

    let prefix = match kind {
        ItemKind::Skill => "skill:",
        ItemKind::Mcp => "mcp:",
    };
    let missing: Vec<&str> = sel
        .except
        .iter()
        .filter(|id| id.starts_with(prefix) && !all.iter().any(|i| &i.id == *id))
        .map(String::as_str)
        .collect();
    if !missing.is_empty() {
        out.push(Row {
            cells: vec![text(tr("Also in this role but not installed here: {}").replace("{}", &missing.join(", ")), Tone::Dim, Font::Small)],
            indent: 0,
            gap: SECTION_GAP,
        });
    }
    for n in &cli.notes {
        out.push(note(n.clone(), 0));
    }
    out
}

// ================================================================== actions

/// Everything the window holds that is not the core's: the editor, and the
/// pane's own view state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub ed: Editor,
    pub search: String,
    pub collapsed: HashSet<String>,
    pub expanded: HashSet<String>,
    /// DIP.
    pub instr_h: i32,
}

impl Default for Model {
    fn default() -> Self {
        Model {
            ed: Editor::default(),
            search: String::new(),
            collapsed: HashSet::new(),
            expanded: HashSet::new(),
            instr_h: INSTR_DEFAULT,
        }
    }
}

/// What a control reported.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Text(String, String),
    Check(String, bool),
    Click(String),
    Choose(String, usize),
}

/// What the window has to do after an action, beyond redrawing.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct After {
    /// Ask the adapters again (`roles::clis(true)`).
    pub reread_clis: bool,
}

fn set_tab(m: &mut Model, tab: Tab) {
    if m.ed.tab != tab {
        m.ed.tab = tab;
        // A new tab starts unfiltered: a filter left over from the other list
        // hides things for no visible reason.
        m.search.clear();
    }
}

/// Change the model the way a control asked. **The whole of what a click or
/// a keystroke means is here**, so it can be tested; the window only reads
/// the control and passes the result in.
pub fn apply(m: &mut Model, cat: &Catalog, clis: &CliSnapshot, a: Action) -> After {
    let mut after = After::default();
    let e = editable(&m.ed);
    match a {
        Action::Click(k) if k == "tab:0" => set_tab(m, Tab::Basics),
        Action::Click(k) if k == "tab:1" => set_tab(m, Tab::Skills),
        Action::Click(k) if k == "tab:2" => set_tab(m, Tab::Mcp),
        Action::Click(k) if k == "gobasics" => set_tab(m, Tab::Basics),
        Action::Click(k) if k == "reload" => after.reread_clis = true,
        Action::Click(k) if k.starts_with("seg:") => {
            let cli = k["seg:".len()..].to_string();
            if m.ed.active_cli.as_deref() != Some(&cli) {
                m.ed.active_cli = Some(cli);
                m.search.clear();
            }
        }
        Action::Click(k) if k.starts_with("gcollapse:") => {
            let id = k["gcollapse:".len()..].to_string();
            if !m.collapsed.remove(&id) {
                m.collapsed.insert(id);
            }
        }
        Action::Click(k) if k.starts_with("more:") => {
            let id = k["more:".len()..].to_string();
            if !m.expanded.remove(&id) {
                m.expanded.insert(id);
            }
        }
        Action::Click(k) if k == "keepall" || k == "alloff" => {
            if e.items {
                let on = k == "keepall";
                with_items(m, clis, |sel, _all, visible| {
                    for i in visible.iter().filter(|i| !i.locked) {
                        sel.set(&i.id, on);
                    }
                });
            }
        }
        Action::Text(k, t) if k == "search" => m.search = t,
        Action::Text(k, t) => {
            let Some(d) = m.ed.draft.as_mut() else { return after };
            match k.as_str() {
                "name" if e.name => {
                    d.name = t;
                    m.ed.name_changed(cat);
                }
                "key" if e.key => {
                    d.key = t;
                    m.ed.key_follows_name = false;
                }
                "summary" if e.summary => d.summary = t,
                "instr" if e.instructions => d.instructions = t,
                "quietmin" if e.quiet => {
                    if let Some(ms) = parse_minutes(&t) {
                        d.polter.quiet_ms = Some(ms);
                    }
                }
                "model" | "args" if e.start => {
                    if let Some(cli) = m.ed.active_cli.clone() {
                        m.ed.update_choice(&cli, |c| {
                            if k == "model" {
                                c.model = t;
                            } else {
                                c.args = roles::args_split(&t);
                            }
                        });
                    }
                }
                _ => {}
            }
        }
        Action::Check(k, on) => {
            if k.starts_with("cli:") || k.starts_with("orphan:") {
                if e.clis {
                    let cli = k.split_once(':').map(|x| x.1).unwrap_or_default().to_string();
                    // An orphan can only be taken away; its box is ticked
                    // because the role still names it.
                    m.ed.set_cli(&cli, on && k.starts_with("cli:"));
                }
                return after;
            }
            if k == "keepdef" {
                if e.items {
                    with_items(m, clis, |sel, all, _| {
                        let ids: Vec<String> = all.iter().map(|i| i.id.clone()).collect();
                        sel.set_default(on, &ids);
                    });
                }
                return after;
            }
            if let Some(gid) = k.strip_prefix("gtoggle:") {
                if e.items {
                    let gid = gid.to_string();
                    with_items(m, clis, |sel, _all, visible| {
                        if let Some(g) = ItemGroup::groups(visible).into_iter().find(|g| g.id == gid) {
                            for i in g.items.iter().filter(|i| !i.locked) {
                                sel.set(&i.id, on);
                            }
                        }
                    });
                }
                return after;
            }
            if let Some(id) = k.strip_prefix("item:") {
                if e.items {
                    let id = id.to_string();
                    with_items(m, clis, |sel, all, _| {
                        // A locked item -- Polter's own MCP server -- is how
                        // the agent reaches Polter at all. Its box is
                        // disabled; this is the same rule where no box can
                        // reach.
                        if all.iter().any(|i| i.id == id && !i.locked) {
                            sel.set(&id, on);
                        }
                    });
                }
                return after;
            }
            let Some(d) = m.ed.draft.as_mut() else { return after };
            let p = &mut d.polter;
            match k.as_str() {
                "sup" if e.polter => p.supervisor = on,
                "auth" if e.polter => p.may_authorise = on,
                "shield" if e.polter => p.shielded = on,
                "watch" if e.watch => p.watch = on,
                "quiet" if e.quiet => p.quiet_ms = on.then_some(QUIET_DEFAULT_MS),
                _ => {}
            }
        }
        Action::Choose(k, i) if k == "open" && e.polter => {
            if let Some(d) = m.ed.draft.as_mut() {
                d.polter.open = if i == 1 { Open::Tab } else { Open::Auto };
            }
        }
        _ => {}
    }
    after
}

/// Run `f` on the selection of the tab on screen, with every item of that
/// kind and the ones the filter shows.
fn with_items(m: &mut Model, clis: &CliSnapshot, f: impl FnOnce(&mut roles::Selection, &[CliItem], &[CliItem])) {
    let Some(kind) = m.ed.tab.kind() else { return };
    let Some(key) = shown_cli(&m.ed) else { return };
    let Some(cli) = clis.cli(&key) else { return };
    let (all, visible) = items_in_view(cli, kind, &m.search);
    m.ed.update_choice(&key, |c| {
        let sel = match kind {
            ItemKind::Skill => &mut c.skills,
            ItemKind::Mcp => &mut c.mcp,
        };
        f(sel, &all, &visible);
    });
}

// ================================================================= geometry

const W0: i32 = 920;
const H0: i32 = 720;
const MIN_W: i32 = 760;
const MIN_H: i32 = 560;
const LIST_W: i32 = 220;
const ROLE_ROW_H: i32 = 44;
const PAD: i32 = 12;
const FIELD_H: i32 = 26;
const BTN_H: i32 = 28;
const ROW_GAP: i32 = 6;
const CELL_GAP: i32 = 8;
const TABBAR_H: i32 = 44;
const TABS_MAX_W: i32 = 420;
const FOOTER_H: i32 = 52;
const BANNER_H: i32 = 44;
const GRIP_H: i32 = 9;

/// A cell with somewhere to be, in the pane's content coordinates (before
/// scrolling).
#[derive(Clone, Debug, PartialEq)]
pub struct Placed {
    pub key: String,
    pub kind: Kind,
    pub rect: RECT,
    pub enabled: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Laid {
    pub cells: Vec<Placed>,
    /// Content height, bottom padding included.
    pub height: i32,
}

/// How big a piece of text is: `(text, max width, font, one line) -> (w, h)`
/// in pixels. The window measures with GDI; the tests pass arithmetic.
pub type Measure<'a> = &'a dyn Fn(&str, i32, Font, bool) -> (i32, i32);

/// Where every cell goes, for a pane `width` pixels wide at `dpi`.
///
/// **The only place that decides**: the control positions and the painting
/// both walk what this returns, so a label cannot be drawn anywhere but
/// beside its field.
pub fn place(rows: &[Row], width: i32, dpi: i32, measure: Measure) -> Laid {
    let s = |v: i32| v * dpi / 96;
    let mut out = Vec::new();
    let mut y = s(PAD);
    for r in rows {
        y += s(r.gap);
        let x0 = s(PAD + r.indent);
        let right = width - s(PAD);
        let avail = (right - x0).max(s(40));
        let gaps = s(CELL_GAP) * (r.cells.len() as i32 - 1).max(0);

        // Widths: fixed and natural first, then share what is left.
        let natural = |c: &Cell| -> Option<i32> {
            match (&c.width, &c.kind) {
                (Width::Fixed(v), _) => Some(s(*v)),
                (Width::Fill, _) => None,
                (Width::Auto, Kind::Text { text, font, .. }) => Some(measure(text, avail, *font, true).0),
                (Width::Auto, Kind::Check { text, .. }) => Some(measure(text, avail, Font::Normal, true).0 + s(26)),
                (Width::Auto, Kind::Button { text }) => Some((measure(text, avail, Font::Normal, true).0 + s(24)).max(s(72))),
                (Width::Auto, Kind::Link { text }) => Some(measure(text, avail, Font::Normal, true).0 + s(8)),
                (Width::Auto, Kind::Segment { text, .. }) => Some(measure(text, avail, Font::Normal, true).0 + s(28)),
                (Width::Auto, Kind::Combo { options, .. }) => {
                    Some(options.iter().map(|o| measure(o, avail, Font::Normal, true).0).max().unwrap_or(0) + s(40))
                }
                (Width::Auto, Kind::Lock) => Some(s(12)),
                (Width::Auto, _) => None,
            }
        };
        let widths: Vec<Option<i32>> = r.cells.iter().map(natural).collect();
        let used: i32 = widths.iter().flatten().sum();
        let fills = widths.iter().filter(|w| w.is_none()).count() as i32;
        let fill_w = if fills > 0 { ((avail - gaps - used) / fills).max(0) } else { 0 };
        let widths: Vec<i32> = widths.iter().map(|w| w.unwrap_or(fill_w).min(avail)).collect();

        let heights: Vec<i32> = r
            .cells
            .iter()
            .zip(&widths)
            .map(|(c, &w)| match &c.kind {
                Kind::Text { text, font, lines, .. } => {
                    if text.is_empty() {
                        return 0;
                    }
                    let (_, h) = measure(text, w, *font, *lines == 1);
                    if *lines > 1 {
                        let line = measure("Ag", 10_000, *font, true).1;
                        h.min(line * *lines as i32)
                    } else {
                        h
                    }
                }
                Kind::Edit { height, .. } => s(*height),
                Kind::Check { .. } => s(22),
                Kind::Button { .. } | Kind::Segment { .. } => s(BTN_H),
                Kind::Link { .. } => s(22),
                Kind::Combo { .. } => s(FIELD_H),
                Kind::Lock => s(14),
                Kind::Grip => s(GRIP_H),
            })
            .collect();
        let row_h = heights.iter().copied().max().unwrap_or(0);

        let mut x = x0;
        for ((c, &w), &h) in r.cells.iter().zip(&widths).zip(&heights) {
            // Everything is centred on the row, so a label sits level with
            // its field; text that wraps to more than a line starts at the
            // top instead, where a reader starts.
            let top = if h < row_h { y + (row_h - h) / 2 } else { y };
            out.push(Placed {
                key: c.key.clone(),
                kind: c.kind.clone(),
                rect: RECT { left: x, top, right: x + w, bottom: top + h },
                enabled: c.enabled,
            });
            x += w + s(CELL_GAP);
        }
        y += row_h + s(ROW_GAP);
    }
    Laid { cells: out, height: y + s(PAD) }
}

/// The fixed parts of the window, in client pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub list: RECT,
    pub list_buttons: [RECT; 3],
    pub error: Option<RECT>,
    pub banner: Option<RECT>,
    pub banner_dup: Option<RECT>,
    pub tabs: Option<[RECT; 3]>,
    pub pane: RECT,
    pub footer: Option<RECT>,
    pub status: RECT,
    /// Launch, Revert, Save, left to right.
    pub footer_buttons: [RECT; 3],
}

/// `error_h`: the measured height of the library-error text, when there is
/// one. Measured by the caller because the core's message is any length.
pub fn frame_layout(w: i32, h: i32, dpi: i32, error_h: Option<i32>, builtin: bool, has_draft: bool) -> Frame {
    let s = |v: i32| v * dpi / 96;
    let list = RECT { left: 0, top: 0, right: s(LIST_W), bottom: h };
    let bw = (s(LIST_W) - s(8) * 2 - s(4) * 2) / 3;
    let by = h - s(8) - s(BTN_H);
    let list_buttons = [0, 1, 2].map(|i| {
        let x = s(8) + i * (bw + s(4));
        RECT { left: x, top: by, right: x + bw, bottom: by + s(BTN_H) }
    });

    let left = s(LIST_W) + 1;
    let mut y = 0;
    let error = error_h.map(|eh| {
        let r = RECT { left, top: y, right: w, bottom: y + eh + s(16) };
        y = r.bottom;
        r
    });
    let (banner, banner_dup) = if has_draft && builtin {
        let r = RECT { left, top: y, right: w, bottom: y + s(BANNER_H) };
        y = r.bottom;
        let dw = s(96);
        let top = r.top + (s(BANNER_H) - s(BTN_H)) / 2;
        (Some(r), Some(RECT { left: w - s(PAD) - dw, top, right: w - s(PAD), bottom: top + s(BTN_H) }))
    } else {
        (None, None)
    };
    let tabs = has_draft.then(|| {
        let tw = (w - left - s(36)).min(s(TABS_MAX_W)).max(s(90));
        let x0 = left + ((w - left) - tw) / 2;
        let top = y + (s(TABBAR_H) - s(BTN_H)) / 2;
        let one = tw / 3;
        [0, 1, 2].map(|i| RECT { left: x0 + i * one, top, right: x0 + (i + 1) * one, bottom: top + s(BTN_H) })
    });
    if has_draft {
        y += s(TABBAR_H);
    }

    let footer = has_draft.then(|| RECT { left, top: h - s(FOOTER_H), right: w, bottom: h });
    let pane_bottom = footer.map_or(h, |f| f.top);
    let pane = RECT { left, top: y, right: w, bottom: pane_bottom.max(y) };

    let fy = h - s(FOOTER_H) + (s(FOOTER_H) - s(BTN_H)) / 2;
    let save = RECT { left: w - s(PAD) - s(96), top: fy, right: w - s(PAD), bottom: fy + s(BTN_H) };
    let revert = RECT { left: save.left - s(8) - s(96), top: fy, right: save.left - s(8), bottom: fy + s(BTN_H) };
    let launch = RECT { left: revert.left - s(8) - s(110), top: fy, right: revert.left - s(8), bottom: fy + s(BTN_H) };
    let status = RECT { left: left + s(PAD), top: h - s(FOOTER_H), right: launch.left - s(PAD), bottom: h };
    Frame { list, list_buttons, error, banner, banner_dup, tabs, pane, footer, status, footer_buttons: [launch, revert, save] }
}

/// Where the role list draws row `index`, with `top` the first row shown,
/// or `None` when it is scrolled away above. **The only place that
/// decides** -- the painter and the click both ask it, which is the rule
/// `settings_ui.rs`'s `plugin_row_rect_at` records and
/// `one-place-decides-where-a-row-is.py` holds.
pub fn role_row_rect_at(dpi: i32, top: usize, index: usize) -> Option<RECT> {
    let s = |v: i32| v * dpi / 96;
    let n = index.checked_sub(top)?;
    let y = s(8) + n as i32 * s(ROLE_ROW_H);
    Some(RECT { left: 0, top: y, right: s(LIST_W), bottom: y + s(ROLE_ROW_H) })
}

/// Which row contains `y`, among the `count` rows that end above `limit`.
/// **Asks the rectangles rather than inverting them**, so the padding above
/// the first row is outside every row.
pub fn role_row_at_y(dpi: i32, top: usize, count: usize, y: i32, limit: i32) -> Option<usize> {
    (top..count).find(|&i| {
        role_row_rect_at(dpi, top, i).is_some_and(|r| r.bottom <= limit && y >= r.top && y < r.bottom)
    })
}

/// How many rows fit above `limit`, for scrolling the list.
fn role_rows_fitting(dpi: i32, limit: i32) -> usize {
    (0..).take_while(|&i| role_row_rect_at(dpi, 0, i).is_some_and(|r| r.bottom <= limit)).count()
}

/// Whether a field's text is written into its control.
///
/// ⚠️ **The two reasons a field can differ from the model are opposites.**
/// While somebody types, the model follows the control, and writing it back
/// would put their caret at the start of what they just typed -- so a
/// control with the keyboard is left alone. But when the whole draft is
/// replaced -- another role selected, reverted, saved, changed on disk --
/// the control is the stale one, and "it has the keyboard" is exactly the
/// wrong reason to leave it. The window opens with the name field focused,
/// which is how selecting another role left its old name on screen with
/// everything else changed.
pub fn text_needs_writing(focused: bool, matches: bool, whole_draft_changed: bool) -> bool {
    !matches && (!focused || whole_draft_changed)
}

pub fn clamp_instructions_height(h: i32) -> i32 {
    h.clamp(INSTR_MIN, INSTR_MAX)
}

/// The remembered height, as the file spells it. Anything unreadable is no
/// memory at all rather than a height of zero.
pub fn parse_height(text: &str) -> Option<i32> {
    text.trim().parse::<i32>().ok().map(clamp_instructions_height)
}

// ==================================================================== window
//
// Below here is Win32. It decides nothing the functions above do not.

/// Close the window, asking first when there is something unsaved. Posted by
/// a child control's Escape. **`WM_APP + 15`**, because every offset from 8
/// to 14 is already used by some other window in this host, several of them
/// twice (`grep 'WM_APP +'` lists them). Each is posted to one window and
/// never broadcast, which is what would make a clash harmless -- but a free
/// number makes the question not arise.
const WM_ROLES_CLOSE: u32 = WM_APP + 15;
/// Save, from a child control's Ctrl+S.
const WM_ROLES_SAVE: u32 = WM_APP + 16;

const ID_NEW: u16 = 100;
const ID_DUP: u16 = 101;
const ID_DEL: u16 = 102;
const ID_TAB0: u16 = 110;
const ID_BANNER_DUP: u16 = 120;
const ID_LAUNCH: u16 = 130;
const ID_REVERT: u16 = 131;
const ID_SAVE: u16 = 132;
/// Pane controls take ids from here up.
const ID_DYNAMIC: u16 = 1000;
const TIMER_CLIS: usize = 1;
/// How often the window asks whether there is a terminal to launch beside.
/// Cheap (it reads the window registry), and the alternative is a button
/// whose greyness is a fact about when the window was opened.
const TIMER_TERMINALS: usize = 2;
const TERMINALS_EVERY_MS: u32 = 1000;
/// The macOS side polls every half second for thirty seconds.
const POLL_EVERY_MS: u32 = 500;
const POLL_FOR: Duration = Duration::from_secs(30);

const PROP_PREV: PCWSTR = w!("PolterRolesPrevProc");
const PROP_SEG: PCWSTR = w!("PolterRolesSegment");

static MAIN: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static PANE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
/// Set while `reconcile` writes into controls, so the notifications those
/// writes cause are not read back as the person typing.
static APPLYING: AtomicBool = AtomicBool::new(false);
static NEXT_ID: AtomicU16 = AtomicU16::new(ID_DYNAMIC);

/// The fonts. **Outside `ST`** for the reason `settings_ui.rs` gives for its
/// one: they are read on the drawing path, which is entered from inside our
/// own calls, and a value that is not in the cell cannot meet a borrow.
static FONT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_BOLD: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_SMALL: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static FONT_MONO: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

fn main_hwnd() -> HWND {
    HWND(MAIN.load(Ordering::Acquire))
}
fn pane_hwnd() -> HWND {
    HWND(PANE.load(Ordering::Acquire))
}
fn font(f: Font) -> HFONT {
    HFONT(
        match f {
            Font::Normal => &FONT,
            Font::Bold => &FONT_BOLD,
            Font::Small => &FONT_SMALL,
            Font::Mono => &FONT_MONO,
        }
        .load(Ordering::Acquire),
    )
}

fn dpi_of(h: HWND) -> i32 {
    unsafe { GetDpiForWindow(h) }.max(96) as i32
}

/// The window handles that do not change: made once with the window.
#[derive(Clone, Copy)]
struct Fixed {
    list_buttons: [HWND; 3],
    tabs: [HWND; 3],
    banner_dup: HWND,
    footer: [HWND; 3],
}

/// A control the pane made, remembered by key.
struct Live {
    hwnd: HWND,
    id: u16,
    tag: Tag,
    rect: RECT,
    label: String,
    options: Vec<String>,
    /// The `draft_gen` this control's text was last put in step with.
    gen: u64,
}

/// What a control *is*, for deciding whether an existing one can be reused:
/// a window's class and most of its style are fixed when it is created.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tag {
    Edit { multi: bool, mono: bool, number: bool },
    Check,
    Button,
    Link,
    Segment,
    Combo,
}

fn tag_of(k: &Kind) -> Option<Tag> {
    Some(match k {
        Kind::Edit { multi, mono, number, .. } => Tag::Edit { multi: *multi, mono: *mono, number: *number },
        Kind::Check { .. } => Tag::Check,
        Kind::Button { .. } => Tag::Button,
        Kind::Link { .. } => Tag::Link,
        Kind::Segment { .. } => Tag::Segment,
        Kind::Combo { .. } => Tag::Combo,
        _ => return None,
    })
}

struct State {
    model: Model,
    cat: Catalog,
    clis: CliSnapshot,
    /// The terminal window this one belongs to, re-answered at every open.
    owner: HWND,
    prev_focus: HWND,
    laid: Laid,
    /// Pixels the pane is scrolled down by.
    scroll: i32,
    list_top: usize,
    /// Control id to key, for mapping a notification back.
    ids: HashMap<u16, String>,
    /// A drag of the instructions grip: where it started (screen y) and the
    /// height then (DIP).
    drag: Option<(i32, i32)>,
    poll_until: Option<Instant>,
    /// What the last look said about there being a terminal to launch
    /// beside. `None` until it has been asked once.
    launchable: Option<bool>,
    /// Bumped every time the draft is replaced wholesale rather than typed
    /// into; `reconcile` writes even a focused field when it has moved on.
    /// See `text_needs_writing`.
    draft_gen: u64,
}

impl Default for State {
    fn default() -> Self {
        State {
            model: Model::default(),
            cat: Catalog::default(),
            clis: CliSnapshot::default(),
            owner: HWND(std::ptr::null_mut()),
            prev_focus: HWND(std::ptr::null_mut()),
            laid: Laid::default(),
            scroll: 0,
            list_top: 0,
            ids: HashMap::new(),
            drag: None,
            poll_until: None,
            launchable: None,
            draft_gen: 0,
        }
    }
}

thread_local! {
    static ST: RefCell<State> = RefCell::new(State::default());
    static LIVE: RefCell<HashMap<String, Live>> = RefCell::new(HashMap::new());
    static FIXED: StdCell<Option<Fixed>> = const { StdCell::new(None) };
}

// ------------------------------------------------------ remembered height

/// `%LOCALAPPDATA%\polter\role-library-instructions-height`, the sibling of
/// `language` and `session.json`. **Remembered between windows and
/// launches**, as the macOS side's `@AppStorage`: somebody who writes long
/// instructions wants the tall box every time, not once.
fn height_path() -> Option<PathBuf> {
    Some(crate::plugins::user_dir()?.parent()?.join("role-library-instructions-height"))
}

fn load_height() -> i32 {
    height_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| parse_height(&t))
        .unwrap_or(INSTR_DEFAULT)
}

fn save_height(h: i32) {
    let Some(path) = height_path() else {
        // process-wide: the role library window is one per process
        crate::plogf!("[roles-ui] no LOCALAPPDATA; the instructions height is not remembered");
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Temporary file and rename, like `language.rs`: a half-written number
    // reads back as no number, which is the default height.
    let tmp = path.with_extension("tmp");
    let ok = std::fs::write(&tmp, h.to_string()).is_ok() && std::fs::rename(&tmp, &path).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        // process-wide: the role library window is one per process
        crate::plogf!("[roles-ui] could not write {}", path.display());
    }
}

// --------------------------------------------------------------- opening

/// Open the role library over `parent`, or bring it to the front.
///
/// **One window for the process**, as on macOS: the library is one file, and
/// two windows editing it would be two drafts racing each other to save.
/// Called on the UI thread, from the menu.
pub fn open(parent: HWND) {
    if main_hwnd().0.is_null() && !create() {
        return;
    }
    let win = main_hwnd();
    let was_visible = unsafe { IsWindowVisible(win) }.as_bool();
    // ⚠️ **What this is handed is not always a terminal window.** The menu
    // bar's row passes the frame; the tab's right-click menu passes the
    // *surface* (`ctxmenu.rs` hands `personas::perform` the surface window,
    // and that is what reaches here). Both were taken as a frame, and
    // everything a frame is for then went wrong quietly: `tabs::window` does
    // not know a surface, so "is there a terminal to launch beside" answered
    // no and the Launch button was grey with a terminal in front of it; and
    // `GWLP_HWNDPARENT` was set to a child window, which is not an owner, so
    // Windows had nothing to hand activation back to on close.
    let owner = frame_for(parent);
    ST.with(|c| c.borrow_mut().owner = owner);
    // Owned, not topmost -- the reason is in `settings_ui::own_and_place`.
    // Re-owned at every open, because which terminal window this belongs to
    // is a fact about this opening.
    unsafe {
        SetWindowLongPtrW(win, GWLP_HWNDPARENT, owner.0 as isize);
    }
    if was_visible {
        let _ = unsafe { SetForegroundWindow(win) };
        return;
    }

    let cat = roles::catalog();
    let clis = roles::clis(false);
    let h = load_height();
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.cat = cat;
        s.clis = clis;
        s.model.instr_h = h;
        s.scroll = 0;
        s.list_top = 0;
        if s.model.ed.draft.is_none() && !s.model.ed.is_new {
            let first = s.cat.roles.first().map(|r| r.key.clone());
            s.model.ed.load(&s.cat, first.as_deref());
        }
        draft_replaced(s);
    });
    start_polling_if_needed(false);

    let dpi = dpi_of(win);
    let (w, h) = (W0 * dpi / 96, H0 * dpi / 96);
    let mut fr = RECT::default();
    let (x, y) = if !owner.0.is_null() && unsafe { GetWindowRect(owner, &mut fr) }.is_ok() {
        (fr.left + ((fr.right - fr.left) - w) / 2, fr.top + ((fr.bottom - fr.top) - h) / 3)
    } else {
        (CW_USEDEFAULT, CW_USEDEFAULT)
    };
    unsafe {
        let _ = SetWindowPos(win, Some(HWND_TOP), x, y, w, h, SWP_SHOWWINDOW);
        // **Whether a launch is possible is not a fact about this opening.**
        // Terminal windows open and close while this one stays up, and the
        // Launch button has to follow them; nothing else would tell it, so
        // it asks on a timer while it is on screen.
        SetTimer(Some(win), TIMER_TERMINALS, TERMINALS_EVERY_MS, None);
    }
    refresh();

    // The window has real edit controls, so the terminal's TSF document has
    // to go back before any of them takes focus. Same contract as the
    // settings page.
    let first = LIVE.with(|l| l.borrow().get("name").map(|x| x.hwnd));
    let prev = crate::overlay::focus_to_edit(first.unwrap_or(win), "roles");
    ST.with(|c| c.borrow_mut().prev_focus = prev);
    // process-wide: the role library window is one per process; it is not
    // opened *for* a terminal window, only placed over one
    crate::plogf!("[roles-ui] shown");
}

/// Hide the window, once leaving has been agreed to. The draft goes with it:
/// the next opening starts from the library, as a new window does on macOS.
fn close() {
    if !confirm_leaving() {
        return;
    }
    let win = main_hwnd();
    let prev = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        s.model.ed = Editor::default();
        s.model.search.clear();
        s.poll_until = None;
        s.prev_focus
    });
    unsafe {
        let _ = KillTimer(Some(win), TIMER_CLIS);
        let _ = KillTimer(Some(win), TIMER_TERMINALS);
        let _ = ShowWindow(win, SW_HIDE);
    }
    // ⚠️ **Focus and the foreground are two different pieces of state**, and
    // only one of them was being handed back: on the test machine the closed
    // window was still the foreground one, so every keystroke went into
    // something invisible. `overlay.rs` has the whole story -- it is the
    // command palette's bug, and it reaches any window that hides itself.
    // Being owned was supposed to make Windows do this by itself, and did
    // not, which is its own reason to hand it back and read it back.
    crate::overlay::foreground_back(win, prev, "roles");
    crate::overlay::focus_back(prev, "roles");
    // process-wide: the role library window is one per process
    crate::plogf!("[roles-ui] hidden");
}

fn make_font(dpi: i32, px: i32, weight: i32, face: PCWSTR) -> HFONT {
    unsafe {
        CreateFontW(
            -(px * dpi / 96),
            0,
            0,
            0,
            weight,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            face,
        )
    }
}

fn make_fonts(dpi: i32) {
    for (slot, f) in [
        (&FONT, make_font(dpi, 14, FW_NORMAL.0 as i32, w!("Segoe UI"))),
        (&FONT_BOLD, make_font(dpi, 14, FW_SEMIBOLD.0 as i32, w!("Segoe UI"))),
        (&FONT_SMALL, make_font(dpi, 12, FW_NORMAL.0 as i32, w!("Segoe UI"))),
        (&FONT_MONO, make_font(dpi, 13, FW_NORMAL.0 as i32, w!("Consolas"))),
    ] {
        let old = slot.swap(f.0, Ordering::AcqRel);
        if !old.is_null() {
            let _ = unsafe { DeleteObject(HGDIOBJ(old)) };
        }
    }
}

fn hinst() -> HINSTANCE {
    unsafe { GetModuleHandleW(None) }.map(Into::into).unwrap_or_default()
}

/// Register the classes and make the window, once.
fn create() -> bool {
    let hi = hinst();
    unsafe {
        for (proc_fn, class) in [
            (main_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT, w!("PolterRoles")),
            (pane_proc, w!("PolterRolesPane")),
        ] {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                // **Repaint the whole client area when the size changes.**
                // Without these two, Windows keeps the old pixels and only
                // invalidates what the new size uncovered -- and on the test
                // machine, maximising left the previous layout's controls
                // painted where they used to be, with the third tab showing
                // the first one's label. What a window shows must not depend
                // on what it showed before it was resized.
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(proc_fn),
                hInstance: hi,
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hbrBackground: HBRUSH(std::ptr::null_mut()),
                lpszClassName: class,
                ..Default::default()
            };
            if RegisterClassExW(&wc) == 0 {
                // process-wide: registering the window class, once per process
                // absence: means it was not reached -- this is the failure arm
                // of a call made once, the first time the library is opened,
                // so a log with neither this line nor `[roles-ui] ready` means
                // `open` was never called, not that the class registered.
                crate::plogf!("[roles-ui] RegisterClassExW failed");
                return false;
            }
        }
        let title: Vec<u16> = tr("Role Library").encode_utf16().chain(Some(0)).collect();
        // A real, resizable window with a title bar: this is an editor people
        // spend time in, not a popup that is dismissed with a click.
        let win = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterRoles"),
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            W0,
            H0,
            None,
            None,
            Some(hi),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the role library window, one per process
                crate::plogf!("[roles-ui] CreateWindowExW failed: {e:?}");
                return false;
            }
        };
        MAIN.store(win.0, Ordering::Release);
        make_fonts(dpi_of(win));
        if theme::custom_drawing() {
            // The dark title bar, as `shell.rs` asks for the frame's.
            let on: BOOL = true.into();
            let _ = DwmSetWindowAttribute(
                win,
                DWMWINDOWATTRIBUTE(20),
                &on as *const BOOL as *const c_void,
                std::mem::size_of::<BOOL>() as u32,
            );
        }
        let pane = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterRolesPane"),
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN,
            0,
            0,
            10,
            10,
            Some(win),
            None,
            Some(hi),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the role library window, one per process
                crate::plogf!("[roles-ui] pane CreateWindowExW failed: {e:?}");
                return false;
            }
        };
        PANE.store(pane.0, Ordering::Release);
        if theme::custom_drawing() {
            let _ = SetWindowTheme(pane, w!("DarkMode_Explorer"), PCWSTR::null());
        }

        let mk = |id: u16, label: String, seg: bool| -> HWND {
            let h = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("BUTTON"),
                PCWSTR::null(),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(BS_PUSHBUTTON as u32),
                0,
                0,
                10,
                10,
                Some(win),
                Some(HMENU(id as usize as *mut c_void)),
                Some(hi),
                None,
            )
            .unwrap_or_default();
            if !h.0.is_null() {
                if seg {
                    let _ = SetPropW(h, PROP_SEG, Some(HANDLE(1 as *mut c_void)));
                }
                SendMessageW(h, WM_SETFONT, Some(WPARAM(font(Font::Normal).0 as usize)), Some(LPARAM(1)));
                set_text(h, &label);
                subclass(h);
            }
            h
        };
        let fixed = Fixed {
            list_buttons: [
                mk(ID_NEW, tr("New Role"), false),
                mk(ID_DUP, tr("Duplicate"), false),
                mk(ID_DEL, tr("Delete"), false),
            ],
            tabs: [mk(ID_TAB0, String::new(), true), mk(ID_TAB0 + 1, String::new(), true), mk(ID_TAB0 + 2, String::new(), true)],
            banner_dup: mk(ID_BANNER_DUP, tr("Duplicate"), false),
            footer: [mk(ID_LAUNCH, tr("Launch"), false), mk(ID_REVERT, tr("Revert"), false), mk(ID_SAVE, tr("Save"), false)],
        };
        FIXED.with(|f| f.set(Some(fixed)));
        // process-wide: the role library window, one per process
        crate::plogf!("[roles-ui] ready");
    }
    true
}

// ------------------------------------------------------------- refreshing

/// The terminal window a handle belongs to: the handle itself when it is one,
/// the window above it when it is a surface or another child, and whichever
/// window is in front when it is neither. **Never a handle this host does not
/// know**, because every use of it -- owning this window, placing it, asking
/// which terminal a launch goes beside -- is a use that fails silently on one.
fn frame_for(hwnd: HWND) -> HWND {
    crate::winid::frame_of_window(hwnd).unwrap_or_else(crate::tabs::overlay_frame)
}

/// The terminal a launch opens its tab beside, **asked afresh every time**
/// rather than remembered from the opening: the window this one belongs to
/// can be closed while it stays up, and another can be opened.
fn launch_surface() -> crate::ffi::Surface {
    let owner = ST.with(|c| c.borrow().owner);
    let surface = crate::tabs::active_surface(owner);
    if !surface.is_null() {
        return surface;
    }
    // The window it was opened over is gone: the button is about whether
    // there is a terminal at all, so ask the question that way.
    crate::tabs::active_surface(crate::tabs::overlay_frame())
}

fn can_launch() -> bool {
    !launch_surface().is_null()
}

fn measure_with(hdc: HDC) -> impl Fn(&str, i32, Font, bool) -> (i32, i32) {
    move |t: &str, width: i32, f: Font, single: bool| {
        if t.is_empty() {
            return (0, 0);
        }
        let mut r = RECT { left: 0, top: 0, right: width.max(1), bottom: 0 };
        let mut wide: Vec<u16> = t.encode_utf16().collect();
        let flags = DT_CALCRECT | DT_NOPREFIX | if single { DT_SINGLELINE } else { DT_WORDBREAK | DT_EDITCONTROL };
        unsafe {
            let old = SelectObject(hdc, font(f).into());
            DrawTextW(hdc, &mut wide, &mut r, flags);
            SelectObject(hdc, old);
        }
        ((r.right - r.left).min(width), r.bottom - r.top)
    }
}

/// Everything on screen, brought up to date with the model.
///
/// Three steps, and the order is the rule this file keeps: **compute with
/// the cell borrowed, act with it released, record with it borrowed again.**
fn refresh() {
    let win = main_hwnd();
    let pane = pane_hwnd();
    if win.0.is_null() || pane.0.is_null() {
        return;
    }
    let launchable = can_launch();
    let dpi = dpi_of(win);

    struct Plan {
        rows: Vec<Row>,
        tab_labels: [String; 3],
        tab: Tab,
        buttons: Buttons,
        error: Option<String>,
        builtin: bool,
        has_draft: bool,
        launch_label: String,
    }
    let plan = ST.with(|c| {
        let s = c.borrow();
        let ed = &s.model.ed;
        let v = View {
            ed,
            clis: &s.clis,
            instr_h: s.model.instr_h,
            search: &s.model.search,
            collapsed: &s.model.collapsed,
            expanded: &s.model.expanded,
        };
        let many = ed.draft.as_ref().is_some_and(|d| d.clis.len() > 1);
        Plan {
            rows: rows(&v),
            tab_labels: Tab::ALL.map(|t| tab_label(t, ed, &s.clis)),
            tab: ed.tab,
            buttons: buttons(ed, &s.cat, launchable),
            error: s.cat.error.clone(),
            builtin: ed.draft.as_ref().is_some_and(|d| d.builtin),
            has_draft: ed.draft.is_some(),
            // More than one CLI opens a menu of them, and says so.
            launch_label: if many { format!("{} ▾", tr("Launch")) } else { tr("Launch") },
        }
    });

    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let hdc = unsafe { GetDC(Some(win)) };
    let measure = measure_with(hdc);
    let error_h = plan.error.as_ref().map(|e| {
        let w = rc.right - dpi * (LIST_W + PAD * 2) / 96;
        measure(&error_banner_text(e), w, Font::Normal, false).1
    });
    let frame = frame_layout(rc.right, rc.bottom, dpi, error_h, plan.builtin, plan.has_draft);
    unsafe {
        ReleaseDC(Some(win), hdc);
    }

    place_fixed(&frame, &plan.tab_labels, plan.tab, plan.buttons, &plan.launch_label, plan.builtin, plan.has_draft);
    let pr = frame.pane;
    unsafe {
        let _ = SetWindowPos(pane, None, pr.left, pr.top, pr.right - pr.left, pr.bottom - pr.top, SWP_NOZORDER | SWP_NOACTIVATE);
    }

    let mut pc = RECT::default();
    let _ = unsafe { GetClientRect(pane, &mut pc) };
    let pdc = unsafe { GetDC(Some(pane)) };
    let laid = place(&plan.rows, pc.right, dpi, &measure_with(pdc));
    unsafe {
        ReleaseDC(Some(pane), pdc);
    }

    // Clamp the scroll to what there now is to scroll.
    let max_scroll = (laid.height - pc.bottom).max(0);
    let scroll = ST.with(|c| {
        let mut s = c.borrow_mut();
        s.scroll = s.scroll.clamp(0, max_scroll);
        s.scroll
    });

    let gen = ST.with(|c| {
        c.borrow().draft_gen
    });
    let ids = reconcile(pane, &laid, scroll, dpi, gen);
    let height = laid.height;
    ST.with(|c| {
        let mut s = c.borrow_mut();
        s.laid = laid;
        s.ids = ids;
    });

    unsafe {
        // Always shown, disabled when there is nothing to scroll: a bar that
        // appears and disappears changes the pane's width, and the layout
        // above was made for this one.
        let si = SCROLLINFO {
            cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
            fMask: SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL,
            nMin: 0,
            nMax: (height - 1).max(0),
            nPage: pc.bottom.max(0) as u32,
            nPos: scroll,
            nTrackPos: 0,
        };
        SetScrollInfo(pane, SB_VERT, &si, true);
        let _ = InvalidateRect(Some(win), None, false);
        let _ = RedrawWindow(Some(pane), None, None, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
    }
}

fn error_banner_text(detail: &str) -> String {
    format!(
        "{}\n{}",
        tr("The role library file has an error in it. Roles can't be changed here until it's fixed."),
        detail
    )
}

/// Move, label, enable and show the controls that are always there.
fn place_fixed(frame: &Frame, tab_labels: &[String; 3], tab: Tab, b: Buttons, launch_label: &str, builtin: bool, has_draft: bool) {
    let Some(f) = FIXED.with(|c| c.get()) else { return };
    let put = |h: HWND, r: &RECT, show: bool, enabled: bool| unsafe {
        let _ = SetWindowPos(h, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
        let _ = ShowWindow(h, if show { SW_SHOWNA } else { SW_HIDE });
        let _ = EnableWindow(h, enabled);
    };
    for (i, h) in f.list_buttons.iter().enumerate() {
        let enabled = [b.new, b.duplicate, b.delete][i];
        put(*h, &frame.list_buttons[i], true, enabled);
    }
    let empty = RECT::default();
    for (i, h) in f.tabs.iter().enumerate() {
        let r = frame.tabs.map(|t| t[i]).unwrap_or(empty);
        put(*h, &r, has_draft, true);
        set_text_if_changed(*h, &tab_labels[i]);
        set_segment(*h, Tab::ALL[i] == tab);
    }
    put(f.banner_dup, &frame.banner_dup.unwrap_or(empty), has_draft && builtin, b.duplicate);
    let enabled = [b.launch, b.revert, b.save];
    for (i, h) in f.footer.iter().enumerate() {
        put(*h, &frame.footer_buttons[i], has_draft, enabled[i]);
    }
    set_text_if_changed(f.footer[0], launch_label);
}

fn set_segment(h: HWND, selected: bool) {
    let want = if selected { 2 } else { 1 };
    unsafe {
        if GetPropW(h, PROP_SEG).0 as usize != want {
            let _ = SetPropW(h, PROP_SEG, Some(HANDLE(want as *mut c_void)));
            let _ = InvalidateRect(Some(h), None, false);
        }
    }
}

fn set_text(h: HWND, s: &str) {
    let wide: Vec<u16> = s.encode_utf16().chain(Some(0)).collect();
    let _ = unsafe { SetWindowTextW(h, PCWSTR(wide.as_ptr())) };
}

/// A control's whole text. **Measured first**: the instructions are longer
/// than any fixed buffer a page like this would pick.
fn get_text(h: HWND) -> String {
    let n = unsafe { GetWindowTextLengthW(h) }.max(0) as usize;
    let mut buf = vec![0u16; n + 1];
    let got = unsafe { GetWindowTextW(h, &mut buf) }.max(0) as usize;
    String::from_utf16_lossy(&buf[..got.min(n)])
}

fn set_text_if_changed(h: HWND, s: &str) {
    if get_text(h) != s {
        set_text(h, s);
    }
}

/// Make, move and update the pane's controls to match `laid`, and destroy
/// the ones it no longer has. Returns the id-to-key map.
///
/// **A control with the keyboard is never written to.** That one rule is
/// what lets the model be rebuilt on every keystroke: the box being typed
/// into already holds what the model was just set from, and writing it back
/// would move the caret to the start. When focus leaves, the next refresh
/// brings it in line -- `args` normalised, a cleared minutes box restored.
fn reconcile(pane: HWND, laid: &Laid, scroll: i32, dpi: i32, gen: u64) -> HashMap<u16, String> {
    APPLYING.store(true, Ordering::Release);
    let mut old = LIVE.with(|l| std::mem::take(&mut *l.borrow_mut()));
    let mut now: HashMap<String, Live> = HashMap::new();
    let focus = unsafe { GetFocus() };
    let s = |v: i32| v * dpi / 96;

    for p in laid.cells.iter().filter(|p| p.kind.is_control()) {
        let Some(tag) = tag_of(&p.kind) else { continue };
        let mut live = match old.remove(&p.key) {
            Some(l) if l.tag == tag => l,
            other => {
                if let Some(l) = other {
                    let _ = unsafe { DestroyWindow(l.hwnd) };
                }
                match make_control(pane, tag) {
                    Some(l) => l,
                    None => continue,
                }
            }
        };
        let h = live.hwnd;
        let r = RECT { top: p.rect.top - scroll, bottom: p.rect.bottom - scroll, ..p.rect };
        if r != live.rect {
            // A combo box's height is its list's too; see `settings_ui.rs`'s
            // `CHOICE_LIST_ROWS` for why this is only the ask.
            let extra = if tag == Tag::Combo { s(20 * 6) } else { 0 };
            unsafe {
                let _ = SetWindowPos(
                    h,
                    None,
                    r.left,
                    r.top,
                    r.right - r.left,
                    r.bottom - r.top + extra,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW,
                );
            }
            live.rect = r;
        }
        match &p.kind {
            Kind::Edit { text, cue, .. } => {
                let same = get_text(h) == *text;
                if text_needs_writing(h == focus, same, live.gen != gen) {
                    set_text(h, text);
                }
                live.gen = gen;
                if live.label != *cue {
                    let wide: Vec<u16> = cue.encode_utf16().chain(Some(0)).collect();
                    unsafe {
                        SendMessageW(h, EM_SETCUEBANNER, Some(WPARAM(0)), Some(LPARAM(wide.as_ptr() as isize)));
                    }
                    live.label = cue.clone();
                }
                // **Read-only rather than disabled**: a built-in role's
                // instructions are there to be read and copied, and a
                // disabled box can be neither.
                unsafe {
                    SendMessageW(h, EM_SETREADONLY, Some(WPARAM(usize::from(!p.enabled))), Some(LPARAM(0)));
                }
            }
            Kind::Check { text, on } => {
                if live.label != *text {
                    set_text(h, text);
                    live.label = text.clone();
                }
                let is = unsafe { SendMessageW(h, BM_GETCHECK, None, None) }.0 == 1;
                if is != *on {
                    unsafe {
                        SendMessageW(h, BM_SETCHECK, Some(WPARAM(usize::from(*on))), Some(LPARAM(0)));
                    }
                }
            }
            Kind::Button { text } | Kind::Link { text } => {
                if live.label != *text {
                    set_text(h, text);
                    live.label = text.clone();
                }
            }
            Kind::Segment { text, selected } => {
                if live.label != *text {
                    set_text(h, text);
                    live.label = text.clone();
                }
                set_segment(h, *selected);
            }
            Kind::Combo { options, sel } => {
                if live.options != *options {
                    unsafe {
                        SendMessageW(h, CB_RESETCONTENT, None, None);
                    }
                    for o in options {
                        let wide: Vec<u16> = o.encode_utf16().chain(Some(0)).collect();
                        unsafe {
                            SendMessageW(h, CB_ADDSTRING, Some(WPARAM(0)), Some(LPARAM(wide.as_ptr() as isize)));
                        }
                    }
                    live.options = options.clone();
                }
                let cur = unsafe { SendMessageW(h, CB_GETCURSEL, None, None) }.0;
                if cur != *sel as isize {
                    unsafe {
                        SendMessageW(h, CB_SETCURSEL, Some(WPARAM(*sel)), Some(LPARAM(0)));
                    }
                }
            }
            _ => {}
        }
        // Edits stay enabled and go read-only instead; see above.
        let want_enabled = matches!(p.kind, Kind::Edit { .. }) || p.enabled;
        unsafe {
            if IsWindowEnabled(h).as_bool() != want_enabled {
                let _ = EnableWindow(h, want_enabled);
            }
        }
        now.insert(p.key.clone(), live);
    }
    for (_, l) in old {
        let _ = unsafe { DestroyWindow(l.hwnd) };
    }
    let ids = now.iter().map(|(k, l)| (l.id, k.clone())).collect();
    LIVE.with(|l| *l.borrow_mut() = now);
    APPLYING.store(false, Ordering::Release);
    ids
}

fn make_control(pane: HWND, tag: Tag) -> Option<Live> {
    let custom = theme::custom_drawing();
    // `WS_BORDER` only when the system draws: the themed border is a light
    // line no `WM_CTLCOLOR*` answer reaches, so the pane draws the frame
    // instead. `settings_ui.rs` has the longer version.
    let border = if custom { WINDOW_STYLE(0) } else { WS_BORDER };
    let (class, style) = match tag {
        Tag::Edit { multi: true, .. } => (
            w!("EDIT"),
            WINDOW_STYLE((ES_MULTILINE | ES_WANTRETURN | ES_AUTOVSCROLL) as u32) | WS_VSCROLL | border,
        ),
        Tag::Edit { number, .. } => (
            w!("EDIT"),
            WINDOW_STYLE((ES_AUTOHSCROLL | if number { ES_NUMBER } else { 0 }) as u32) | border,
        ),
        Tag::Check => (w!("BUTTON"), WINDOW_STYLE(BS_AUTOCHECKBOX as u32)),
        Tag::Button | Tag::Segment => (w!("BUTTON"), WINDOW_STYLE(BS_PUSHBUTTON as u32)),
        Tag::Link => (w!("BUTTON"), WINDOW_STYLE((BS_PUSHBUTTON | BS_FLAT) as u32)),
        Tag::Combo => (
            w!("COMBOBOX"),
            WINDOW_STYLE((CBS_DROPDOWNLIST | CBS_HASSTRINGS | if custom { CBS_OWNERDRAWFIXED } else { 0 }) as u32),
        ),
    };
    let id = NEXT_ID.fetch_add(1, Ordering::AcqRel);
    let h = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class,
            PCWSTR::null(),
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | style,
            0,
            0,
            10,
            10,
            Some(pane),
            Some(HMENU(id as usize as *mut c_void)),
            Some(hinst()),
            None,
        )
    }
    .ok()?;
    let f = match tag {
        Tag::Edit { mono: true, .. } => font(Font::Mono),
        _ => font(Font::Normal),
    };
    unsafe {
        SendMessageW(h, WM_SETFONT, Some(WPARAM(f.0 as usize)), Some(LPARAM(1)));
        if tag == Tag::Segment {
            let _ = SetPropW(h, PROP_SEG, Some(HANDLE(1 as *mut c_void)));
        }
        if matches!(tag, Tag::Edit { multi: true, .. }) && custom {
            let _ = SetWindowTheme(h, w!("DarkMode_Explorer"), PCWSTR::null());
        }
    }
    subclass(h);
    Some(Live { hwnd: h, id, tag, rect: RECT::default(), label: String::new(), options: Vec::new(), gen: u64::MAX })
}

/// Throw every pane control away, so the next refresh makes them again --
/// for a DPI or theme change, where the font or the style they were created
/// with is what changed.
fn drop_controls() {
    let old = LIVE.with(|l| std::mem::take(&mut *l.borrow_mut()));
    for (_, l) in old {
        let _ = unsafe { DestroyWindow(l.hwnd) };
    }
}

// ------------------------------------------------------ child keyboard

/// Every control this window makes goes through here: Escape and Ctrl+S
/// have to work wherever the keyboard is, and a control swallows keys its
/// parent never sees. **Not `overlay::forward_escape_to_parent`**, which
/// keeps the previous procedure in `GWLP_USERDATA` and knows only Escape;
/// this one keeps it in a window property, so the two could not collide
/// even on one control.
fn subclass(h: HWND) {
    unsafe {
        let prev = SetWindowLongPtrW(h, GWLP_WNDPROC, child_proc as *const () as isize);
        let _ = SetPropW(h, PROP_PREV, Some(HANDLE(prev as *mut c_void)));
    }
}

/// `CB_GETDROPPEDSTATE`: Escape on an open drop-down closes the drop-down,
/// not the window.
const CB_GETDROPPEDSTATE: u32 = 0x0157;
const EM_SETCUEBANNER: u32 = 0x1501;
const EM_SETREADONLY: u32 = 0x00CF;

fn held(vk: VIRTUAL_KEY) -> bool {
    (unsafe { GetKeyState(vk.0 as i32) } as u16 & 0x8000) != 0
}

unsafe extern "system" fn child_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        let prev = GetPropW(h, PROP_PREV).0 as isize;
        let main = main_hwnd();
        match msg {
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if vk == VK_ESCAPE && SendMessageW(h, CB_GETDROPPEDSTATE, None, None).0 == 0 {
                    let _ = PostMessageW(Some(main), WM_ROLES_CLOSE, WPARAM(0), LPARAM(0));
                    return LRESULT(0);
                }
                if vk.0 == u16::from(b'S') && held(VK_CONTROL) {
                    let _ = PostMessageW(Some(main), WM_ROLES_SAVE, WPARAM(0), LPARAM(0));
                    return LRESULT(0);
                }
            }
            // The characters those two keys also produce, which an `EDIT`
            // would otherwise answer with a beep.
            WM_CHAR if wp.0 == 0x13 || wp.0 == 0x1B => return LRESULT(0),
            // ⚠️ **The wheel goes to whatever has the keyboard, not to
            // whatever is under the pointer.** The page opens with the name
            // field focused, an `EDIT` answers the wheel itself, and the
            // page therefore did not scroll at all until the person clicked
            // somewhere that was not a control -- with a section of Basics
            // below the bottom edge at the default size. So every control
            // this window makes hands the wheel to the pane, which is the
            // thing that scrolls.
            //
            // Two exceptions, both because the control really does scroll:
            // the instructions box, which has its own scroll bar, and a
            // combo box with its list open.
            WM_MOUSEWHEEL => {
                let style = GetWindowLongPtrW(h, GWL_STYLE) as u32;
                let multiline = style & ES_MULTILINE as u32 != 0;
                let dropped = SendMessageW(h, CB_GETDROPPEDSTATE, None, None).0 != 0;
                if !multiline && !dropped {
                    if let Ok(parent) = GetParent(h) {
                        SendMessageW(parent, WM_MOUSEWHEEL, Some(wp), Some(lp));
                        return LRESULT(0);
                    }
                }
            }
            WM_NCDESTROY => {
                let _ = RemovePropW(h, PROP_PREV);
                let _ = RemovePropW(h, PROP_SEG);
            }
            _ => {}
        }
        if prev == 0 {
            return DefWindowProcW(h, msg, wp, lp);
        }
        let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT = std::mem::transmute(prev);
        CallWindowProcW(Some(f), h, msg, wp, lp)
    }
}

// ----------------------------------------------------------- asking

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Answer {
    First,
    Second,
    Cancel,
}

type TaskDialogIndirectFn =
    unsafe extern "system" fn(*const TASKDIALOGCONFIG, *mut i32, *mut i32, *mut BOOL) -> HRESULT;

/// `TaskDialogIndirect`, found at run time.
///
/// **Not imported**: it exists only in comctl32 version 6, and a static
/// import of it is resolved when the program loads -- so a build without the
/// manifest that selects version 6 would not merely lack this dialog, it
/// would not start. `polter-cli` is built from the same `main.rs`. Looked up
/// instead, and when it is not there, [`ask`] falls back to a message box.
fn task_dialog_indirect() -> Option<TaskDialogIndirectFn> {
    unsafe {
        let m = LoadLibraryW(w!("comctl32.dll")).ok()?;
        let p = GetProcAddress(m, s!("TaskDialogIndirect"))?;
        Some(std::mem::transmute::<unsafe extern "system" fn() -> isize, TaskDialogIndirectFn>(p))
    }
}

/// Ask a question with two named answers and Cancel. **Named buttons**, as
/// the macOS alert has -- "Save / Don't Save / Cancel" is answerable at a
/// glance, "Yes / No / Cancel" needs the question read twice.
fn ask(owner: HWND, main: &str, body: &str, first: &str, second: Option<&str>) -> Answer {
    let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(Some(0)).collect() };
    let (m, b, f1, f2, cancel, title) =
        (wide(main), wide(body), wide(first), wide(second.unwrap_or("")), wide(&tr("Cancel")), wide(&tr("Role Library")));
    // process-wide: a modal question from the role library window, one per
    // process. Said before the dialog, because until it is answered this
    // thread is inside it and nothing else is logged.
    crate::plogf!("[roles-ui] asking: {main}");
    if let Some(tdi) = task_dialog_indirect() {
        let mut buttons = vec![TASKDIALOG_BUTTON { nButtonID: 100, pszButtonText: PCWSTR(f1.as_ptr()) }];
        if second.is_some() {
            buttons.push(TASKDIALOG_BUTTON { nButtonID: 101, pszButtonText: PCWSTR(f2.as_ptr()) });
        }
        buttons.push(TASKDIALOG_BUTTON { nButtonID: IDCANCEL.0, pszButtonText: PCWSTR(cancel.as_ptr()) });
        let cfg = TASKDIALOGCONFIG {
            cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
            hwndParent: owner,
            dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW,
            pszWindowTitle: PCWSTR(title.as_ptr()),
            pszMainInstruction: PCWSTR(m.as_ptr()),
            pszContent: PCWSTR(b.as_ptr()),
            cButtons: buttons.len() as u32,
            pButtons: buttons.as_ptr(),
            nDefaultButton: 100,
            ..Default::default()
        };
        let mut pressed = 0i32;
        let hr = unsafe { tdi(&cfg, &mut pressed, std::ptr::null_mut(), std::ptr::null_mut()) };
        if hr.is_ok() {
            let a = match pressed {
                100 => Answer::First,
                101 => Answer::Second,
                _ => Answer::Cancel,
            };
            // process-wide: as above
            crate::plogf!("[roles-ui] answered {a:?}");
            return a;
        }
        // process-wide: as above
        crate::plogf!("[roles-ui] TaskDialogIndirect failed ({hr:?}); asking with a message box");
    }
    let text = wide(&format!("{main}\n\n{body}"));
    let style = if second.is_some() { MB_YESNOCANCEL | MB_ICONWARNING } else { MB_OKCANCEL | MB_ICONWARNING };
    let r = unsafe { MessageBoxW(Some(owner), PCWSTR(text.as_ptr()), PCWSTR(title.as_ptr()), style) };
    let a = match r {
        IDYES | IDOK => Answer::First,
        IDNO => Answer::Second,
        _ => Answer::Cancel,
    };
    // process-wide: as above
    crate::plogf!("[roles-ui] answered {a:?} (message box)");
    a
}

// ---------------------------------------------------------- doing things

/// True when it is fine to throw the draft away: nothing unsaved, or the
/// person said so, or it was saved.
fn confirm_leaving() -> bool {
    let dirty = ST.with(|c| leave_needs_asking(&c.borrow().model.ed));
    if !dirty {
        return true;
    }
    match ask(
        main_hwnd(),
        &tr("Save changes to this role?"),
        &tr("Your changes will be lost if you don't save them."),
        &tr("Save"),
        Some(&tr("Don't Save")),
    ) {
        Answer::First => save(),
        Answer::Second => true,
        Answer::Cancel => false,
    }
}

fn with_model<R>(f: impl FnOnce(&mut State) -> R) -> R {
    ST.with(|c| f(&mut c.borrow_mut()))
}

/// Say that the draft was replaced rather than typed into, so that the
/// fields are written even where the keyboard is. Every way a role is
/// swapped goes through here; see `text_needs_writing`.
fn draft_replaced(s: &mut State) {
    s.draft_gen = s.draft_gen.wrapping_add(1);
}

fn select(key: &str) {
    if !ST.with(|c| selecting_is_a_change(&c.borrow().model.ed, key)) {
        return;
    }
    if confirm_leaving() {
        with_model(|s| {
            s.model.ed.load(&s.cat, Some(key));
            s.scroll = 0;
            draft_replaced(s);
        });
    }
    refresh();
}

/// Save the draft. True when it was saved or there was nothing to save.
fn save() -> bool {
    let req = ST.with(|c| {
        let s = c.borrow();
        s.model.ed.save_request(&s.cat)
    });
    let role = match req {
        Ok(Some(r)) => r,
        Ok(None) => return true,
        Err(why) => {
            with_model(|s| {
                s.model.ed.status = Some(why);
            });
            refresh();
            return false;
        }
    };
    let result = roles::put(&role);
    let cat = roles::catalog();
    // process-wide: the role library is app-scoped, not any one window's
    crate::plogf!("[roles-ui] save {} -> {}", role.key, if result.is_ok() { "ok" } else { "refused" });
    let ok = result.is_ok();
    with_model(|s| {
        s.cat = cat;
        match result {
            Ok(()) => s.model.ed.saved(&s.cat, &role.key),
            Err(why) => s.model.ed.status = Some(why),
        }
        draft_replaced(s);
    });
    refresh();
    ok
}

fn new_role() {
    if confirm_leaving() {
        with_model(|s| {
            s.model.ed.new_role(&s.cat, &s.clis);
            s.scroll = 0;
            draft_replaced(s);
        });
    }
    refresh();
}

fn duplicate() {
    if ST.with(|c| c.borrow().model.ed.draft.is_none()) {
        return;
    }
    if confirm_leaving() {
        with_model(|s| {
            s.model.ed.duplicate(&s.cat);
            s.scroll = 0;
            draft_replaced(s);
        });
    }
    refresh();
}

fn delete() {
    let (role, is_new) = ST.with(|c| {
        let s = c.borrow();
        (s.model.ed.draft.clone(), s.model.ed.is_new)
    });
    let Some(role) = role.filter(|r| !r.builtin) else { return };
    if is_new {
        with_model(|s| {
            s.model.ed.load(&s.cat, None);
            draft_replaced(s);
        });
        refresh();
        return;
    }
    let answer = ask(
        main_hwnd(),
        &tr("Delete the role \"{}\"?").replace("{}", &role.name),
        &tr("Terminals wearing it are taken out of it. Agents already running keep running."),
        &tr("Delete"),
        None,
    );
    if answer != Answer::First {
        return;
    }
    let result = roles::delete(&role.key);
    let cat = roles::catalog();
    // process-wide: the role library is app-scoped, not any one window's
    crate::plogf!("[roles-ui] delete {} -> {}", role.key, if result.is_ok() { "ok" } else { "refused" });
    with_model(|s| {
        s.cat = cat;
        match result {
            Ok(()) => s.model.ed.load(&s.cat, None),
            Err(why) => s.model.ed.status = Some(why),
        }
        draft_replaced(s);
    });
    refresh();
}

fn revert() {
    with_model(|s| {
        s.model.ed.revert(&s.cat);
        draft_replaced(s);
    });
    refresh();
}

/// Launch the role in a new tab beside the terminal this window belongs to.
fn launch() {
    let (owner, role, labels) = ST.with(|c| {
        let s = c.borrow();
        let role = s.model.ed.draft.clone();
        let labels: Vec<(String, String)> = role
            .as_ref()
            .map(|r| r.clis.iter().map(|c| (c.cli.clone(), s.clis.label(&c.cli))).collect())
            .unwrap_or_default();
        (s.owner, role, labels)
    });
    let Some(role) = role else { return };
    let cli = match labels.len() {
        0 => return,
        1 => labels[0].0.clone(),
        _ => match pick_cli(&labels) {
            Some(c) => c,
            None => return,
        },
    };
    // The same question the button asked, asked again at the moment it is
    // acted on: between the two, a window can have closed.
    let surface = launch_surface();
    let frame = frame_for(owner);
    crate::wlogf!(frame, "[roles-ui] launching {} with {}", role.key, cli);
    let result = roles::launch(surface, &role.key, &cli);
    crate::wlogf!(frame, "[roles-ui] launch {} -> {}", role.key, if result.is_ok() { "ok" } else { "refused" });
    if let Err(why) = result {
        with_model(|s| s.model.ed.status = Some(format!("{} — {}", tr("The role couldn't be launched"), why)));
    }
    refresh();
}

/// The Launch button's menu, for a role set up for more than one CLI.
fn pick_cli(labels: &[(String, String)]) -> Option<String> {
    let win = main_hwnd();
    let btn = FIXED.with(|c| c.get())?.footer[0];
    let mut r = RECT::default();
    unsafe {
        let _ = GetWindowRect(btn, &mut r);
        let menu = CreatePopupMenu().ok()?;
        for (i, (_, label)) in labels.iter().enumerate() {
            let wide: Vec<u16> = label.encode_utf16().chain(Some(0)).collect();
            let _ = AppendMenuW(menu, MF_STRING, i + 1, PCWSTR(wide.as_ptr()));
        }
        let picked = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_BOTTOMALIGN, r.left, r.top, None, win, None);
        let _ = DestroyMenu(menu);
        let i = picked.0 as usize;
        (i >= 1).then(|| labels.get(i - 1).map(|l| l.0.clone())).flatten()
    }
}

/// Keep reading the CLI inventory while the core says a newer answer is on
/// its way. The core never blocks on the adapters, so this is how the window
/// learns the read finished.
fn start_polling_if_needed(fresh: bool) {
    let win = main_hwnd();
    let busy = ST.with(|c| {
        let mut s = c.borrow_mut();
        let busy = s.clis.refreshing || s.clis.stale;
        if busy && (fresh || s.poll_until.is_none()) {
            s.poll_until = Some(Instant::now() + POLL_FOR);
        }
        busy
    });
    if busy {
        unsafe {
            SetTimer(Some(win), TIMER_CLIS, POLL_EVERY_MS, None);
        }
    }
}

fn on_timer() {
    let win = main_hwnd();
    let clis = roles::clis(false);
    let stop = ST.with(|c| {
        let mut s = c.borrow_mut();
        s.clis = clis;
        let past = s.poll_until.is_none_or(|t| Instant::now() > t);
        let stop = past || !(s.clis.refreshing || s.clis.stale);
        if stop {
            s.poll_until = None;
        }
        stop
    });
    if stop {
        let _ = unsafe { KillTimer(Some(win), TIMER_CLIS) };
    }
    refresh();
}

fn run_action(a: Action) {
    let after = with_model(|s| {
        let (cat, clis) = (&s.cat, &s.clis);
        apply(&mut s.model, cat, clis, a)
    });
    if after.reread_clis {
        let clis = roles::clis(true);
        with_model(|s| {
            s.clis = clis;
        });
        start_polling_if_needed(true);
    }
    refresh();
}

/// A notification from a pane control, turned into an [`Action`].
fn on_pane_command(wp: WPARAM, lp: LPARAM) {
    if APPLYING.load(Ordering::Acquire) {
        return;
    }
    let id = (wp.0 & 0xFFFF) as u16;
    let code = ((wp.0 >> 16) & 0xFFFF) as u32;
    let h = HWND(lp.0 as *mut c_void);
    let Some(key) = ST.with(|c| c.borrow().ids.get(&id).cloned()) else { return };
    let action = match code {
        EN_CHANGE => Action::Text(key, get_text(h)),
        // Focus left a field: bring it in line with the model.
        EN_KILLFOCUS => {
            refresh();
            return;
        }
        BN_CLICKED => {
            let style = unsafe { GetWindowLongPtrW(h, GWL_STYLE) } as u32;
            if (style & BS_TYPEMASK as u32) as i32 == BS_AUTOCHECKBOX {
                Action::Check(key, unsafe { SendMessageW(h, BM_GETCHECK, None, None) }.0 == 1)
            } else {
                Action::Click(key)
            }
        }
        CBN_SELCHANGE => Action::Choose(key, unsafe { SendMessageW(h, CB_GETCURSEL, None, None) }.0.max(0) as usize),
        _ => return,
    };
    run_action(action);
}

fn scroll_pane_to(y: i32) {
    ST.with(|c| {
        c.borrow_mut().scroll = y.max(0);
    });
    refresh();
}

fn scroll_pane_by(dy: i32) {
    let now = ST.with(|c| c.borrow().scroll);
    scroll_pane_to(now + dy);
}

/// The grip's rectangle in pane client coordinates, if it is on screen.
fn grip_rect() -> Option<RECT> {
    ST.with(|c| {
        let s = c.borrow();
        s.laid.cells.iter().find(|p| p.key == "grip").map(|p| RECT {
            top: p.rect.top - s.scroll,
            bottom: p.rect.bottom - s.scroll,
            ..p.rect
        })
    })
}

fn in_rect(r: &RECT, x: i32, y: i32) -> bool {
    x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

fn lparam_xy(lp: LPARAM) -> (i32, i32) {
    ((lp.0 & 0xFFFF) as i16 as i32, ((lp.0 >> 16) & 0xFFFF) as i16 as i32)
}

// --------------------------------------------------------------- drawing

fn tone_colour(t: Tone) -> u32 {
    match t {
        Tone::Text => theme::text(),
        Tone::Dim => theme::dim(),
        Tone::Warn => theme::warn(),
    }
}

fn fill(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        FillRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

fn frame_rect(hdc: HDC, r: &RECT, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        let _ = FrameRect(hdc, r, b);
        let _ = DeleteObject(b.into());
    }
}

fn draw_text(hdc: HDC, s: &str, r: &RECT, f: Font, colour: u32, flags: DRAW_TEXT_FORMAT) {
    let mut wide: Vec<u16> = s.encode_utf16().collect();
    if wide.is_empty() {
        return;
    }
    let mut r = *r;
    unsafe {
        let old = SelectObject(hdc, font(f).into());
        SetTextColor(hdc, COLORREF(colour));
        SetBkMode(hdc, TRANSPARENT);
        DrawTextW(hdc, &mut wide, &mut r, flags | DT_NOPREFIX);
        SelectObject(hdc, old);
    }
}

/// A padlock, drawn rather than taken from a font: the emoji is not in
/// Segoe UI, and a glyph that falls back to a different font is a different
/// size on every machine.
fn draw_lock(hdc: HDC, x: i32, y: i32, size: i32, colour: u32) {
    let body = RECT { left: x, top: y + size * 2 / 5, right: x + size, bottom: y + size };
    fill(hdc, &body, colour);
    unsafe {
        let pen = CreatePen(PS_SOLID, (size / 7).max(1), COLORREF(colour));
        let old = SelectObject(hdc, pen.into());
        let old_brush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
        let _ = Arc(
            hdc,
            x + size / 5,
            y,
            x + size - size / 5,
            y + size * 4 / 5,
            x + size - size / 5,
            y + size * 2 / 5,
            x + size / 5,
            y + size * 2 / 5,
        );
        SelectObject(hdc, old_brush);
        SelectObject(hdc, old);
        let _ = DeleteObject(pen.into());
    }
}

fn draw_dot(hdc: HDC, cx: i32, cy: i32, r: i32, colour: u32) {
    unsafe {
        let b = CreateSolidBrush(COLORREF(colour));
        let pen = CreatePen(PS_SOLID, 1, COLORREF(colour));
        let ob = SelectObject(hdc, b.into());
        let op = SelectObject(hdc, pen.into());
        let _ = Ellipse(hdc, cx - r, cy - r, cx + r, cy + r);
        SelectObject(hdc, ob);
        SelectObject(hdc, op);
        let _ = DeleteObject(b.into());
        let _ = DeleteObject(pen.into());
    }
}

fn paint_main(win: HWND) {
    // Everything this paints is read out first; nothing below borrows.
    let (list, empty, error, builtin, has_draft, list_top, ed) = ST.with(|c| {
        let s = c.borrow();
        let ed = &s.model.ed;
        (
            list_rows(ed, &s.cat, &s.clis),
            list_empty_note(ed, &s.cat),
            s.cat.error.clone(),
            ed.draft.as_ref().is_some_and(|d| d.builtin),
            ed.draft.is_some(),
            s.list_top,
            ed.clone(),
        )
    });
    let footer = footer_note(&ed, can_launch());

    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(win, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(win, &mut rc);
        let dpi = dpi_of(win);
        let s = |v: i32| v * dpi / 96;
        let measure = measure_with(hdc);
        let error_h = error.as_ref().map(|e| {
            measure(&error_banner_text(e), rc.right - s(LIST_W + PAD * 2), Font::Normal, false).1
        });
        let frame = frame_layout(rc.right, rc.bottom, dpi, error_h, builtin, has_draft);

        fill(hdc, &rc, theme::bg());
        fill(hdc, &frame.list, theme::panel());
        let sep = RECT { left: frame.list.right, top: 0, right: frame.list.right + 1, bottom: rc.bottom };
        fill(hdc, &sep, theme::border());

        // The list.
        let limit = frame.list_buttons[0].top - s(8);
        for (i, row) in list.iter().enumerate() {
            let Some(r) = role_row_rect_at(dpi, list_top, i) else { continue };
            if r.bottom > limit {
                break;
            }
            let (fg, dim) = if row.selected {
                fill(hdc, &RECT { left: s(6), right: r.right - s(6), ..r }, theme::sel());
                (theme::sel_text(), theme::sel_text())
            } else {
                (theme::text(), theme::dim())
            };
            let x = s(PAD);
            let right = r.right - s(PAD);
            // The marks go after the name, so the name is measured first and
            // cut short enough to leave them room.
            let marks = s(14) * (i32::from(row.builtin) + i32::from(row.unsaved));
            let (tw, _) = measure(&row.title, right - x - marks, Font::Normal, true);
            let title = RECT { left: x, top: r.top + s(4), right: x + tw, bottom: r.top + s(24) };
            draw_text(hdc, &row.title, &title, Font::Normal, fg, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            let mut mx = title.right + s(5);
            if row.builtin {
                draw_lock(hdc, mx, title.top + s(5), s(10), dim);
                mx += s(14);
            }
            if row.unsaved {
                draw_dot(hdc, mx + s(3), (title.top + title.bottom) / 2, s(3), theme::focus());
            }
            let sub = RECT { left: x, top: r.top + s(23), right, bottom: r.bottom - s(3) };
            draw_text(hdc, &row.subtitle, &sub, Font::Small, dim, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
        if let Some((head, body)) = empty {
            let r = RECT { left: s(PAD), top: s(PAD * 2), right: s(LIST_W - PAD), bottom: s(PAD * 2 + 24) };
            draw_text(hdc, &head, &r, Font::Bold, theme::dim(), DT_CENTER | DT_SINGLELINE);
            let r = RECT { left: s(PAD), top: s(PAD * 2 + 28), right: s(LIST_W - PAD), bottom: limit };
            draw_text(hdc, &body, &r, Font::Small, theme::dim(), DT_CENTER | DT_WORDBREAK);
        }

        if let (Some(r), Some(e)) = (frame.error, error.as_ref()) {
            let inner = RECT { left: r.left + s(PAD), top: r.top + s(8), right: r.right - s(PAD), bottom: r.bottom - s(8) };
            draw_text(hdc, &error_banner_text(e), &inner, Font::Normal, theme::warn(), DT_LEFT | DT_WORDBREAK);
            fill(hdc, &RECT { top: r.bottom - 1, ..r }, theme::border());
        }
        if let (Some(r), Some(d)) = (frame.banner, frame.banner_dup) {
            fill(hdc, &r, theme::panel());
            draw_lock(hdc, r.left + s(PAD), r.top + s(15), s(12), theme::dim());
            let t = RECT { left: r.left + s(PAD + 20), top: r.top, right: d.left - s(PAD), bottom: r.bottom };
            draw_text(
                hdc,
                &tr("This role comes with Polter and can't be changed or deleted. Duplicate it to make one of your own."),
                &t,
                Font::Normal,
                theme::dim(),
                DT_LEFT | DT_VCENTER | DT_WORDBREAK | DT_END_ELLIPSIS,
            );
        }
        if let Some(f) = frame.footer {
            fill(hdc, &RECT { bottom: f.top + 1, ..f }, theme::border());
            if let Some((t, is_error)) = footer {
                let colour = if is_error { theme::warn() } else { theme::dim() };
                draw_text(hdc, &t, &frame.status, Font::Normal, colour, DT_LEFT | DT_VCENTER | DT_WORDBREAK | DT_END_ELLIPSIS);
            }
        }
        if frame.tabs.is_some() {
            let y = frame.pane.top - 1;
            fill(hdc, &RECT { left: frame.pane.left, top: y, right: rc.right, bottom: y + 1 }, theme::border());
        }
        let _ = EndPaint(win, &ps);
    }
}

fn paint_pane(win: HWND) {
    let (cells, scroll) = ST.with(|c| {
        let s = c.borrow();
        (s.laid.cells.clone(), s.scroll)
    });
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let hdc = BeginPaint(win, &mut ps);
        if hdc.is_invalid() {
            return;
        }
        let mut rc = RECT::default();
        let _ = GetClientRect(win, &mut rc);
        fill(hdc, &rc, theme::bg());
        let dpi = dpi_of(win);
        for p in &cells {
            let r = RECT { top: p.rect.top - scroll, bottom: p.rect.bottom - scroll, ..p.rect };
            if r.bottom < 0 || r.top > rc.bottom {
                continue;
            }
            match &p.kind {
                Kind::Text { text, tone, font: f, right, lines } => {
                    let align = if *right { DT_RIGHT } else { DT_LEFT };
                    let flags = if *lines == 1 {
                        align | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS
                    } else {
                        align | DT_WORDBREAK | DT_EDITCONTROL | DT_END_ELLIPSIS
                    };
                    draw_text(hdc, text, &r, *f, tone_colour(*tone), flags);
                }
                Kind::Lock => draw_lock(hdc, r.left, r.top + 2, (r.right - r.left).min(r.bottom - r.top) - 2, theme::dim()),
                Kind::Grip => {
                    // The strip, and a short bar in the middle of it: the
                    // shape every resizable edge has.
                    fill(hdc, &r, theme::panel());
                    let cx = (r.left + r.right) / 2;
                    let cy = (r.top + r.bottom) / 2;
                    let bar = RECT { left: cx - 18 * dpi / 96, top: cy - 1, right: cx + 18 * dpi / 96, bottom: cy + 2 };
                    fill(hdc, &bar, theme::dim());
                }
                // The frame around every text field, from the same rectangle
                // the control was placed at. Only when this page draws: under
                // high contrast the field has `WS_BORDER` and draws its own.
                Kind::Edit { .. } if theme::custom_drawing() => {
                    let fr = RECT { left: r.left - 1, top: r.top - 1, right: r.right + 1, bottom: r.bottom + 1 };
                    frame_rect(hdc, &fr, theme::border());
                }
                _ => {}
            }
        }
        let _ = EndPaint(win, &ps);
    }
}

/// A button's paint, from its custom-draw notification. The same six states
/// `settings_ui.rs::draw_button` draws, plus two shapes it has no need of: a
/// flat link and a chosen segment. **Reads no `ST`**: this is entered from
/// inside `SetWindowTextW`.
unsafe fn draw_button(cd: &NMCUSTOMDRAW) {
    unsafe {
        let h = cd.hdr.hwndFrom;
        let hdc = cd.hdc;
        let has = |f: NMCUSTOMDRAW_DRAW_STATE_FLAGS| cd.uItemState.contains(f);
        let (hot, down, disabled, focus) = (has(CDIS_HOT), has(CDIS_SELECTED), has(CDIS_DISABLED), has(CDIS_FOCUS));
        let style = GetWindowLongPtrW(h, GWL_STYLE) as u32;
        let kind = (style & BS_TYPEMASK as u32) as i32;
        let is_check = kind == BS_AUTOCHECKBOX || kind == BS_CHECKBOX;
        let is_link = style & BS_FLAT as u32 != 0;
        let seg = GetPropW(h, PROP_SEG).0 as usize;
        let label = {
            let mut buf = [0u16; 512];
            let n = GetWindowTextW(h, &mut buf) as usize;
            String::from_utf16_lossy(&buf[..n])
        };
        let mut rc = cd.rc;
        let fg = if disabled { theme::dim() } else { theme::btn_text() };

        if is_check {
            fill(hdc, &rc, theme::bg());
            let side = (rc.bottom - rc.top).clamp(12, 16);
            let top = rc.top + ((rc.bottom - rc.top) - side) / 2;
            let b = RECT { left: rc.left, top, right: rc.left + side, bottom: top + side };
            fill(hdc, &b, if hot && !disabled { theme::btn_hot() } else { theme::field_bg() });
            frame_rect(hdc, &b, if focus { theme::focus() } else { theme::border() });
            if SendMessageW(h, BM_GETCHECK, Some(WPARAM(0)), Some(LPARAM(0))).0 == 1 {
                let pen = CreatePen(PS_SOLID, 2, COLORREF(fg));
                let old = SelectObject(hdc, pen.into());
                let mut pt = POINT::default();
                let _ = MoveToEx(hdc, b.left + side / 5, b.top + side / 2, Some(&mut pt));
                let _ = LineTo(hdc, b.left + side * 2 / 5, b.bottom - side / 4);
                let _ = LineTo(hdc, b.right - side / 5, b.top + side / 4);
                SelectObject(hdc, old);
                let _ = DeleteObject(pen.into());
            }
            let t = RECT { left: b.right + 8, ..rc };
            draw_text(hdc, &label, &t, Font::Normal, fg, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            return;
        }

        if is_link {
            fill(hdc, &rc, theme::bg());
            let colour = if disabled { theme::dim() } else if hot { theme::text() } else { theme::focus() };
            draw_text(hdc, &label, &rc, Font::Normal, colour, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            if focus {
                frame_rect(hdc, &rc, theme::focus());
            }
            return;
        }

        let selected = seg == 2;
        let face = if selected {
            theme::sel()
        } else if disabled {
            theme::btn_face()
        } else if down {
            theme::btn_down()
        } else if hot {
            theme::btn_hot()
        } else {
            theme::btn_face()
        };
        fill(hdc, &rc, face);
        frame_rect(hdc, &rc, theme::border());
        if focus && !disabled {
            frame_rect(hdc, &RECT { left: rc.left + 3, top: rc.top + 3, right: rc.right - 3, bottom: rc.bottom - 3 }, theme::focus());
        }
        if down {
            rc.top += 1;
            rc.left += 1;
        }
        let fg = if selected { theme::sel_text() } else { fg };
        draw_text(hdc, &label, &rc, Font::Normal, fg, DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    }
}

/// One row of the "Open in" drop-down, and its closed face. See
/// `settings_ui.rs::draw_combo_item` for what the frame around it is not.
unsafe fn draw_combo_item(dis: &DRAWITEMSTRUCT) {
    unsafe {
        if dis.itemID == u32::MAX {
            fill(dis.hDC, &dis.rcItem, theme::field_bg());
            return;
        }
        let selected = dis.itemState.0 & ODS_SELECTED.0 != 0;
        let in_edit = dis.itemState.0 & ODS_COMBOBOXEDIT.0 != 0;
        let (bg, fg) = if selected && !in_edit { (theme::sel(), theme::sel_text()) } else { (theme::field_bg(), theme::text()) };
        fill(dis.hDC, &dis.rcItem, bg);
        let mut buf = [0u16; 256];
        let n = SendMessageW(dis.hwndItem, CB_GETLBTEXT, Some(WPARAM(dis.itemID as usize)), Some(LPARAM(buf.as_mut_ptr() as isize))).0;
        if n > 0 {
            let t = String::from_utf16_lossy(&buf[..n as usize]);
            let r = RECT { left: dis.rcItem.left + 4, ..dis.rcItem };
            draw_text(dis.hDC, &t, &r, Font::Normal, fg, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        }
        if in_edit && dis.itemState.0 & ODS_FOCUS.0 != 0 {
            frame_rect(dis.hDC, &dis.rcItem, theme::focus());
        }
    }
}

/// The messages both procedures answer the same way: colours, custom draw,
/// the owner-drawn combo.
unsafe fn common(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
    unsafe {
        match msg {
            WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC | WM_CTLCOLORLISTBOX | WM_CTLCOLORBTN => {
                theme::ctl_color(HDC(wp.0 as *mut c_void)).map(|b| LRESULT(b.0 as isize))
            }
            WM_NOTIFY => {
                let nm = &*(lp.0 as *const NMHDR);
                if nm.code == NM_CUSTOMDRAW && theme::custom_drawing() {
                    let cd = &*(lp.0 as *const NMCUSTOMDRAW);
                    if cd.dwDrawStage == CDDS_PREPAINT {
                        draw_button(cd);
                        return Some(LRESULT(CDRF_SKIPDEFAULT as isize));
                    }
                }
                None
            }
            WM_DRAWITEM => {
                let dis = &*(lp.0 as *const DRAWITEMSTRUCT);
                if dis.CtlType == ODT_COMBOBOX && theme::custom_drawing() {
                    draw_combo_item(dis);
                    return Some(LRESULT(1));
                }
                None
            }
            WM_MEASUREITEM => {
                let mis = &mut *(lp.0 as *mut MEASUREITEMSTRUCT);
                if mis.CtlType == ODT_COMBOBOX {
                    mis.itemHeight = (dpi_of(win) * 20 / 96) as u32;
                    return Some(LRESULT(1));
                }
                None
            }
            _ => None,
        }
    }
}

// ------------------------------------------------------ window procedures

unsafe extern "system" fn main_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if let Some(r) = common(win, msg, wp, lp) {
            return r;
        }
        match msg {
            WM_COMMAND => {
                let id = (wp.0 & 0xFFFF) as u16;
                match id {
                    ID_NEW => new_role(),
                    ID_DUP | ID_BANNER_DUP => duplicate(),
                    ID_DEL => delete(),
                    ID_LAUNCH => launch(),
                    ID_REVERT => revert(),
                    ID_SAVE => {
                        save();
                    }
                    t if (ID_TAB0..ID_TAB0 + 3).contains(&t) => run_action(Action::Click(format!("tab:{}", t - ID_TAB0))),
                    _ => {}
                }
                LRESULT(0)
            }
            WM_ROLES_CLOSE | WM_CLOSE => {
                close();
                LRESULT(0)
            }
            WM_ROLES_SAVE => {
                save();
                LRESULT(0)
            }
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if vk == VK_ESCAPE {
                    close();
                } else if vk.0 == u16::from(b'S') && held(VK_CONTROL) {
                    save();
                }
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let (x, y) = lparam_xy(lp);
                let dpi = dpi_of(win);
                if x < LIST_W * dpi / 96 {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let limit = rc.bottom - (8 + BTN_H + 8) * dpi / 96;
                    let hit = ST.with(|c| {
                        let s = c.borrow();
                        let list = list_rows(&s.model.ed, &s.cat, &s.clis);
                        role_row_at_y(dpi, s.list_top, list.len(), y, limit).and_then(|i| list[i].key.clone())
                    });
                    if let Some(key) = hit {
                        select(&key);
                    }
                }
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
                let mut pt = POINT { x: (lp.0 & 0xFFFF) as i16 as i32, y: ((lp.0 >> 16) & 0xFFFF) as i16 as i32 };
                let _ = ScreenToClient(win, &mut pt);
                let dpi = dpi_of(win);
                if pt.x < LIST_W * dpi / 96 {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(win, &mut rc);
                    let fit = role_rows_fitting(dpi, rc.bottom - (8 + BTN_H + 8) * dpi / 96);
                    ST.with(|c| {
                        let s = &mut *c.borrow_mut();
                        let n = list_rows(&s.model.ed, &s.cat, &s.clis).len();
                        let last = n.saturating_sub(fit);
                        let step: i32 = if delta > 0 { -1 } else { 1 };
                        s.list_top = (s.list_top as i32 + step).clamp(0, last as i32) as usize;
                    });
                    let _ = InvalidateRect(Some(win), None, false);
                } else {
                    scroll_pane_by(-delta * 60 * dpi / 96 / 120);
                }
                LRESULT(0)
            }
            WM_ACTIVATE => {
                if (wp.0 & 0xFFFF) as u32 != WA_INACTIVE {
                    // Coming back to the window: the terminal may have taken
                    // the TSF document meanwhile, and the library may have
                    // been changed from somewhere else -- a supervisor's
                    // `role_put`, or the file edited by hand.
                    crate::ime_focus(false);
                    let cat = roles::catalog();
                    with_model(|s| {
                        s.cat = cat;
                        s.model.ed.library_changed(&s.cat);
                        draft_replaced(s);
                    });
                    refresh();
                }
                DefWindowProcW(win, msg, wp, lp)
            }
            WM_TIMER if wp.0 == TIMER_CLIS => {
                on_timer();
                LRESULT(0)
            }
            // **Only when the answer changed.** A refresh a second rebuilds
            // nothing visibly, but it would move the caret out of a field
            // somebody is typing in the moment the rule in `reconcile`
            // stopped holding, and it would hide any such mistake behind a
            // repaint nobody asked for.
            WM_TIMER if wp.0 == TIMER_TERMINALS => {
                let now = can_launch();
                let changed = ST.with(|c| {
                    let mut s = c.borrow_mut();
                    let changed = s.launchable != Some(now);
                    s.launchable = Some(now);
                    changed
                });
                if changed {
                    refresh();
                }
                LRESULT(0)
            }
            WM_GETMINMAXINFO => {
                let mmi = &mut *(lp.0 as *mut MINMAXINFO);
                let dpi = dpi_of(win);
                mmi.ptMinTrackSize = POINT { x: MIN_W * dpi / 96, y: MIN_H * dpi / 96 };
                LRESULT(0)
            }
            // The last word after a drag-resize: a size that arrived while
            // the pointer was still down is not always the size it ends at.
            WM_EXITSIZEMOVE => {
                refresh();
                LRESULT(0)
            }
            WM_SIZE => {
                // Everything moves: the list, the tabs, the pane and every
                // control in it. **Then the whole window is redrawn,
                // children included** -- a moved child keeps its old pixels
                // until something asks for new ones, and `RDW_ALLCHILDREN`
                // is that asking.
                refresh();
                let _ = RedrawWindow(
                    Some(win),
                    None,
                    None,
                    RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN,
                );
                LRESULT(0)
            }
            WM_DPICHANGED => {
                make_fonts(dpi_of(win));
                drop_controls();
                if let Some(f) = FIXED.with(|c| c.get()) {
                    for h in f.list_buttons.iter().chain(&f.tabs).chain(&f.footer).chain(std::iter::once(&f.banner_dup)) {
                        SendMessageW(*h, WM_SETFONT, Some(WPARAM(font(Font::Normal).0 as usize)), Some(LPARAM(1)));
                    }
                }
                let r = &*(lp.0 as *const RECT);
                let _ = SetWindowPos(win, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
                refresh();
                LRESULT(0)
            }
            // A theme change rebuilds the pane's controls, not only repaints
            // them: whether the combo is owner-drawn is a style fixed at
            // creation, and high contrast has to be able to take it back.
            WM_SYSCOLORCHANGE | WM_THEMECHANGED => {
                drop_controls();
                refresh();
                theme::repaint_all(win);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint_main(win);
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

unsafe extern "system" fn pane_proc(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if let Some(r) = common(win, msg, wp, lp) {
            return r;
        }
        match msg {
            WM_COMMAND => {
                on_pane_command(wp, lp);
                LRESULT(0)
            }
            WM_VSCROLL => {
                let dpi = dpi_of(win);
                let mut rc = RECT::default();
                let _ = GetClientRect(win, &mut rc);
                let line = 40 * dpi / 96;
                let cur = ST.with(|c| c.borrow().scroll);
                let to = match SCROLLBAR_COMMAND((wp.0 & 0xFFFF) as i32) {
                    SB_LINEUP => cur - line,
                    SB_LINEDOWN => cur + line,
                    SB_PAGEUP => cur - rc.bottom,
                    SB_PAGEDOWN => cur + rc.bottom,
                    SB_THUMBTRACK | SB_THUMBPOSITION => {
                        let mut si = SCROLLINFO {
                            cbSize: std::mem::size_of::<SCROLLINFO>() as u32,
                            fMask: SIF_TRACKPOS,
                            ..Default::default()
                        };
                        let _ = GetScrollInfo(win, SB_VERT, &mut si);
                        si.nTrackPos
                    }
                    SB_TOP => 0,
                    SB_BOTTOM => i32::MAX / 2,
                    _ => cur,
                };
                if to != cur {
                    scroll_pane_to(to);
                }
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
                scroll_pane_by(-delta * 60 * dpi_of(win) / 96 / 120);
                LRESULT(0)
            }
            WM_KEYDOWN => {
                // Escape and Ctrl+S, when the pane itself has the keyboard.
                let _ = PostMessageW(Some(main_hwnd()), msg, wp, lp);
                LRESULT(0)
            }
            WM_SETCURSOR => {
                let mut pt = POINT::default();
                let _ = GetCursorPos(&mut pt);
                let _ = ScreenToClient(win, &mut pt);
                let dragging = ST.with(|c| c.borrow().drag.is_some());
                if dragging || grip_rect().is_some_and(|r| in_rect(&r, pt.x, pt.y)) {
                    SetCursor(LoadCursorW(None, IDC_SIZENS).ok());
                    return LRESULT(1);
                }
                DefWindowProcW(win, msg, wp, lp)
            }
            WM_LBUTTONDOWN => {
                let (x, y) = lparam_xy(lp);
                let _ = SetFocus(Some(win));
                if grip_rect().is_some_and(|r| in_rect(&r, x, y)) {
                    let mut pt = POINT::default();
                    let _ = GetCursorPos(&mut pt);
                    ST.with(|c| {
                        let mut s = c.borrow_mut();
                        let h = s.model.instr_h;
                        s.drag = Some((pt.y, h));
                    });
                    SetCapture(win);
                }
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                let drag = ST.with(|c| c.borrow().drag);
                if let Some((start_y, start_h)) = drag {
                    let mut pt = POINT::default();
                    let _ = GetCursorPos(&mut pt);
                    let dip = (pt.y - start_y) * 96 / dpi_of(win);
                    let h = clamp_instructions_height(start_h + dip);
                    let changed = ST.with(|c| {
                        let mut s = c.borrow_mut();
                        let changed = s.model.instr_h != h;
                        s.model.instr_h = h;
                        changed
                    });
                    if changed {
                        refresh();
                    }
                }
                LRESULT(0)
            }
            WM_LBUTTONUP | WM_CAPTURECHANGED => {
                let ended = ST.with(|c| {
                    let mut s = c.borrow_mut();
                    s.drag.take().map(|_| s.model.instr_h)
                });
                if let Some(h) = ended {
                    if msg == WM_LBUTTONUP {
                        let _ = ReleaseCapture();
                    }
                    save_height(h);
                }
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_PAINT => {
                paint_pane(win);
                LRESULT(0)
            }
            _ => DefWindowProcW(win, msg, wp, lp),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::roles::{AgentCli, Catalog, CliItem, CliSnapshot, ItemKind, Role};

    fn role(key: &str) -> Role {
        Role::new(key, key)
    }

    fn cat(keys: &[&str]) -> Catalog {
        Catalog { loaded: true, error: None, path: None, roles: keys.iter().map(|k| role(k)).collect() }
    }

    fn item(id: &str, kind: ItemKind, source: &str, locked: bool) -> CliItem {
        CliItem {
            id: id.into(),
            kind,
            name: id.trim_start_matches("skill:").trim_start_matches("mcp:").into(),
            summary: String::new(),
            detail: String::new(),
            source: source.into(),
            group: None,
            group_summary: None,
            locked,
        }
    }

    fn snapshot() -> CliSnapshot {
        CliSnapshot {
            stale: false,
            refreshing: false,
            clis: vec![AgentCli {
                key: "claude".into(),
                label: "Claude Code".into(),
                bin: "claude".into(),
                error: None,
                installed: Some(true),
                items: vec![
                    item("skill:a", ItemKind::Skill, "user", false),
                    item("skill:b", ItemKind::Skill, "user", false),
                    item("skill:c", ItemKind::Skill, "project", false),
                    item("mcp:polter", ItemKind::Mcp, "user", true),
                    item("mcp:x", ItemKind::Mcp, "user", false),
                ],
                notes: Vec::new(),
            }],
        }
    }

    /// An editor on a saved role `r` set up for `claude`.
    fn editing(c: &mut Catalog) -> Editor {
        c.roles[0].clis = vec![CliChoice::new("claude")];
        let mut ed = Editor::default();
        ed.load(c, Some("r"));
        ed
    }

    /// Arithmetic text: seven pixels a character, eighteen a line.
    fn fake_measure(t: &str, width: i32, _f: Font, single: bool) -> (i32, i32) {
        let w = t.chars().count() as i32 * 7;
        if single || w <= width {
            return (w.min(width), 18);
        }
        let lines = (w + width - 1) / width.max(1);
        (width, 18 * lines)
    }

    // ------------------------------------------------------------ counts

    /// The tab says kept of installed **for the CLI on screen**, and a
    /// locked item counts as kept whatever the selection says: it is kept.
    #[test]
    fn the_tab_counts_kept_of_installed_and_a_locked_item_is_kept() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        let clis = snapshot();
        assert_eq!(tab_count(&ed, &clis, ItemKind::Skill), Some((3, 3)));
        ed.update_choice("claude", |ch| {
            ch.skills.set("skill:a", false);
            ch.mcp.keep_by_default = false;
        });
        assert_eq!(tab_count(&ed, &clis, ItemKind::Skill), Some((2, 3)));
        // Everything off by default, and the locked one still counted.
        assert_eq!(tab_count(&ed, &clis, ItemKind::Mcp), Some((1, 2)));
        assert_eq!(tab_label(Tab::Skills, &ed, &clis), "Skills 2/3");
        assert_eq!(tab_label(Tab::Mcp, &ed, &clis), "MCP 1/2");
    }

    /// No CLI is not `0/0`: a count that says nothing is not shown at all.
    #[test]
    fn a_role_with_no_cli_has_no_count() {
        let mut ed = Editor::default();
        ed.load(&cat(&["r"]), Some("r"));
        assert_eq!(tab_count(&ed, &snapshot(), ItemKind::Skill), None);
        assert_eq!(tab_label(Tab::Skills, &ed, &snapshot()), "Skills");
        assert_eq!(tab_label(Tab::Basics, &ed, &snapshot()), "Basics");
    }

    // -------------------------------------------------------- editability

    /// A built-in role: **everything** read-only, not only the fields that
    /// look important.
    #[test]
    fn a_builtin_role_is_read_only_everywhere() {
        let mut c = cat(&["polter-supervisor"]);
        c.roles[0].builtin = true;
        let mut ed = Editor::default();
        ed.load(&c, Some("polter-supervisor"));
        assert_eq!(editable(&ed), Editable::default());
        // The floor: the same role, not built in, is editable -- or the
        // assertion above would pass on a function that answered no to
        // everything.
        c.roles[0].builtin = false;
        ed.load(&c, Some("polter-supervisor"));
        let e = editable(&ed);
        assert!(e.name && e.summary && e.instructions && e.polter && e.clis && e.items);
    }

    /// The key is chosen once: editable while new, fixed after saving.
    #[test]
    fn the_key_is_editable_only_while_the_role_is_new() {
        let c = cat(&["r"]);
        let mut ed = Editor::default();
        ed.new_role(&c, &snapshot());
        assert!(editable(&ed).key);
        let key = ed.draft.as_ref().unwrap().key.clone();
        let mut after = c.clone();
        after.roles.push(ed.draft.clone().unwrap());
        ed.saved(&after, &key);
        assert!(!editable(&ed).key);
        assert!(editable(&ed).name, "only the key stops being editable");
    }

    /// Watching needs a terminal a supervisor may reach: not a supervisor,
    /// not shielded. Quiet needs only not shielded.
    #[test]
    fn watch_and_quiet_follow_supervisor_and_shield() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        assert!(editable(&ed).watch && editable(&ed).quiet);
        ed.draft.as_mut().unwrap().polter.supervisor = true;
        assert!(!editable(&ed).watch);
        assert!(editable(&ed).quiet, "a supervisor can still be reported as still");
        ed.draft.as_mut().unwrap().polter.supervisor = false;
        ed.draft.as_mut().unwrap().polter.shielded = true;
        assert!(!editable(&ed).watch && !editable(&ed).quiet);
    }

    // ------------------------------------------------------------ buttons

    #[test]
    fn launch_needs_a_saved_role_a_cli_and_a_terminal() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        assert!(buttons(&ed, &c, true).launch);
        assert!(!buttons(&ed, &c, false).launch, "no terminal to open the tab beside");
        ed.draft.as_mut().unwrap().summary = "changed".into();
        assert!(!buttons(&ed, &c, true).launch, "a dirty draft is not what the core would launch");
        // No CLI, and saved that way.
        c.roles[0].clis.clear();
        ed.load(&c, Some("r"));
        assert!(!ed.is_dirty());
        assert!(!buttons(&ed, &c, true).launch, "no CLI");
    }

    #[test]
    fn save_and_revert_need_a_change_and_delete_needs_a_role_of_ones_own() {
        let mut c = cat(&["r", "polter-supervisor"]);
        c.roles[1].builtin = true;
        let mut ed = editing(&mut c);
        let b = buttons(&ed, &c, true);
        assert!(!b.save && !b.revert && b.delete && b.duplicate && b.new);
        ed.draft.as_mut().unwrap().name = "x".into();
        let b = buttons(&ed, &c, true);
        assert!(b.save && b.revert);
        // A library file that does not parse: nothing is saved over it.
        let mut broken = c.clone();
        broken.error = Some("line 3".into());
        let b = buttons(&ed, &broken, true);
        assert!(!b.save && !b.new && !b.delete && !b.duplicate && b.revert);
        ed.load(&c, Some("polter-supervisor"));
        assert!(!buttons(&ed, &c, true).delete, "a built-in role cannot be deleted");
        assert!(buttons(&ed, &c, true).duplicate, "but it can be copied");
    }

    // ------------------------------------------------------------ leaving

    #[test]
    fn leaving_asks_exactly_when_something_is_unsaved() {
        let mut c = cat(&["r", "s"]);
        let mut ed = editing(&mut c);
        assert!(!leave_needs_asking(&ed));
        ed.draft.as_mut().unwrap().instructions = "x".into();
        assert!(leave_needs_asking(&ed));
        // Typing it back is not a change.
        ed.draft.as_mut().unwrap().instructions = String::new();
        assert!(!leave_needs_asking(&ed));
        // A new role is unsaved from the moment it exists.
        ed.new_role(&c, &snapshot());
        assert!(leave_needs_asking(&ed));
    }

    #[test]
    fn clicking_the_role_already_open_is_not_leaving_it() {
        let mut c = cat(&["r", "s"]);
        let ed = editing(&mut c);
        assert!(!selecting_is_a_change(&ed, "r"));
        assert!(selecting_is_a_change(&ed, "s"));
        let mut fresh = ed.clone();
        fresh.new_role(&c, &snapshot());
        assert!(selecting_is_a_change(&fresh, "r"), "leaving a new role for any row is leaving");
    }

    // ------------------------------------------------------------ editing

    #[test]
    fn a_new_roles_key_follows_its_name_until_a_key_is_typed() {
        let c = cat(&["r"]);
        let mut m = Model::default();
        m.ed.new_role(&c, &snapshot());
        let clis = snapshot();
        apply(&mut m, &c, &clis, Action::Text("name".into(), "Code Reviewer".into()));
        assert_eq!(m.ed.draft.as_ref().unwrap().key, "code-reviewer");
        apply(&mut m, &c, &clis, Action::Text("key".into(), "mine".into()));
        apply(&mut m, &c, &clis, Action::Text("name".into(), "Something Else".into()));
        assert_eq!(m.ed.draft.as_ref().unwrap().key, "mine");
    }

    #[test]
    fn a_duplicate_of_a_builtin_role_is_the_users_under_a_new_key() {
        let mut c = cat(&["polter-supervisor"]);
        c.roles[0].builtin = true;
        let mut ed = Editor::default();
        ed.load(&c, Some("polter-supervisor"));
        ed.duplicate(&c);
        let d = ed.draft.as_ref().unwrap();
        assert!(!d.builtin && ed.is_new);
        assert_ne!(d.key, "polter-supervisor");
        assert!(editable(&ed).name);
    }

    /// A new role may not quietly replace an existing one.
    #[test]
    fn a_new_role_with_a_key_already_used_is_refused_before_the_core() {
        let c = cat(&["r"]);
        let mut ed = Editor::default();
        ed.new_role(&c, &snapshot());
        ed.draft.as_mut().unwrap().key = "r".into();
        assert!(ed.save_request(&c).is_err());
        ed.draft.as_mut().unwrap().key = "other".into();
        assert!(matches!(ed.save_request(&c), Ok(Some(_))));
    }

    /// "Items installed later" changes the default **without** changing any
    /// box the person can see, and the group switch leaves a locked item
    /// alone.
    #[test]
    fn the_default_switch_keeps_every_visible_box_and_groups_skip_locked_items() {
        let mut c = cat(&["r"]);
        let mut m = Model { ed: editing(&mut c), ..Model::default() };
        let clis = snapshot();
        m.ed.tab = Tab::Skills;
        apply(&mut m, &c, &clis, Action::Check("item:skill:a".into(), false));
        apply(&mut m, &c, &clis, Action::Check("keepdef".into(), false));
        let sel = &m.ed.draft.as_ref().unwrap().clis[0].skills;
        assert!(!sel.keep_by_default);
        assert!(!sel.is_on("skill:a") && sel.is_on("skill:b") && sel.is_on("skill:c"));
        assert!(!sel.is_on("skill:installed-tomorrow"));

        m.ed.tab = Tab::Mcp;
        apply(&mut m, &c, &clis, Action::Check("gtoggle:user".into(), false));
        apply(&mut m, &c, &clis, Action::Check("item:mcp:polter".into(), false));
        let sel = &m.ed.draft.as_ref().unwrap().clis[0].mcp;
        assert!(!sel.is_on("mcp:x"));
        assert!(!sel.except.contains(&"mcp:polter".to_string()), "a locked item is never switched");
        assert_eq!(tab_count(&m.ed, &clis, ItemKind::Mcp), Some((1, 2)));
    }

    /// Keep All and Turn All Off act on what the filter shows, not on
    /// everything -- the macOS buttons say "current filter" for a reason.
    #[test]
    fn keep_all_acts_on_the_filtered_list_only() {
        let mut c = cat(&["r"]);
        let mut m = Model { ed: editing(&mut c), ..Model::default() };
        let clis = snapshot();
        m.ed.tab = Tab::Skills;
        apply(&mut m, &c, &clis, Action::Text("search".into(), "c".into()));
        apply(&mut m, &c, &clis, Action::Click("alloff".into()));
        let sel = &m.ed.draft.as_ref().unwrap().clis[0].skills;
        assert!(!sel.is_on("skill:c"));
        assert!(sel.is_on("skill:a") && sel.is_on("skill:b"));
        // Switching tab clears the filter.
        apply(&mut m, &c, &clis, Action::Click("tab:2".into()));
        assert_eq!(m.search, "");
    }

    #[test]
    fn a_builtin_role_ignores_every_edit_that_reaches_it() {
        let mut c = cat(&["polter-supervisor"]);
        c.roles[0].builtin = true;
        c.roles[0].clis = vec![CliChoice::new("claude")];
        let mut m = Model::default();
        m.ed.load(&c, Some("polter-supervisor"));
        let before = m.ed.clone();
        let clis = snapshot();
        for a in [
            Action::Text("name".into(), "x".into()),
            Action::Text("instr".into(), "x".into()),
            Action::Check("sup".into(), true),
            Action::Check("cli:claude".into(), false),
            Action::Check("keepdef".into(), false),
        ] {
            apply(&mut m, &c, &clis, a);
        }
        assert_eq!(m.ed.draft, before.draft);
        assert!(!m.ed.is_dirty());
    }

    // ------------------------------------------------------------- list

    #[test]
    fn the_list_marks_builtin_roles_and_unsaved_ones() {
        let mut c = cat(&["r", "polter-supervisor"]);
        c.roles[1].builtin = true;
        let mut ed = editing(&mut c);
        let rows = list_rows(&ed, &c, &snapshot());
        assert!(!rows[0].builtin && rows[1].builtin);
        assert!(rows.iter().all(|r| !r.unsaved));
        assert!(rows[0].selected && !rows[1].selected);
        assert_eq!(rows[0].subtitle, "Claude Code");
        assert_eq!(rows[1].subtitle, "No agent CLI");

        ed.draft.as_mut().unwrap().summary = "x".into();
        let rows = list_rows(&ed, &c, &snapshot());
        assert!(rows[0].unsaved && !rows[1].unsaved);

        ed.new_role(&c, &snapshot());
        let rows = list_rows(&ed, &c, &snapshot());
        assert_eq!(rows.len(), 3);
        assert!(rows[0].unsaved && rows[0].key.is_none() && rows[0].selected);
        assert!(!rows[1].selected);
    }

    #[test]
    fn an_empty_list_says_whether_it_was_read() {
        let ed = Editor::default();
        let unread = list_empty_note(&ed, &Catalog::default()).unwrap();
        let empty = list_empty_note(&ed, &Catalog { loaded: true, ..Catalog::default() }).unwrap();
        assert_ne!(unread.0, empty.0);
        assert_eq!(list_empty_note(&ed, &cat(&["r"])), None);
    }

    // ------------------------------------------------------------- rows

    fn keys(rows: &[Row]) -> Vec<String> {
        rows.iter().flat_map(|r| r.cells.iter().map(|c| c.key.clone())).filter(|k| !k.is_empty()).collect()
    }

    #[test]
    fn a_tab_with_no_cli_sends_the_person_to_basics() {
        let c = cat(&["r"]);
        let mut ed = Editor::default();
        ed.load(&c, Some("r"));
        ed.tab = Tab::Skills;
        let empty = HashSet::new();
        let v = View { ed: &ed, clis: &snapshot(), instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        assert_eq!(keys(&rows(&v)), vec!["gobasics".to_string()]);
    }

    #[test]
    fn two_clis_put_a_switcher_on_the_tab_and_one_does_not() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        ed.tab = Tab::Skills;
        let empty = HashSet::new();
        let clis = snapshot();
        let v = View { ed: &ed, clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        assert!(!keys(&rows(&v)).iter().any(|k| k.starts_with("seg:")));
        ed.set_cli("codex", true);
        let v = View { ed: &ed, clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        let k = keys(&rows(&v));
        assert!(k.contains(&"seg:claude".to_string()) && k.contains(&"seg:codex".to_string()));
    }

    /// The list is the machine's, the launch is the terminal's, and the
    /// difference is on the page rather than in a surprise at launch.
    #[test]
    fn both_item_tabs_say_that_a_projects_own_are_not_listed() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        let empty = HashSet::new();
        let clis = snapshot();
        let said = |ed: &Editor| {
            let v = View { ed, clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
            rows(&v)
                .iter()
                .flat_map(|r| r.cells.iter())
                .filter_map(|c| match &c.kind {
                    Kind::Text { text, .. } => Some(text.clone()),
                    _ => None,
                })
                .find(|t| t.contains("aren't in it"))
        };
        ed.tab = Tab::Skills;
        let skills = said(&ed).expect("the skills tab says it");
        ed.tab = Tab::Mcp;
        let mcp = said(&ed).expect("the MCP tab says it");
        assert_ne!(skills, mcp, "each tab names the thing it lists");
        // Not on Basics, which lists neither.
        ed.tab = Tab::Basics;
        assert_eq!(said(&ed), None);
    }

    #[test]
    fn a_collapsed_group_keeps_its_switch_and_hides_its_items() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        ed.tab = Tab::Skills;
        let empty = HashSet::new();
        let collapsed: HashSet<String> = ["user".to_string()].into();
        let clis = snapshot();
        let v = View { ed: &ed, clis: &clis, instr_h: 240, search: "", collapsed: &collapsed, expanded: &empty };
        let k = keys(&rows(&v));
        assert!(k.contains(&"gtoggle:user".to_string()));
        assert!(!k.contains(&"item:skill:a".to_string()));
        assert!(k.contains(&"item:skill:c".to_string()), "the other group is open");
        let v = View { ed: &ed, clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        assert!(keys(&rows(&v)).contains(&"item:skill:a".to_string()));
    }

    // ----------------------------------------------------------- layout

    fn basics_laid(dpi: i32, width: i32) -> Laid {
        let mut c = cat(&["r"]);
        let ed = editing(&mut c);
        let empty = HashSet::new();
        let clis = snapshot();
        let v = View { ed: &ed, clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        place(&rows(&v), width, dpi, &fake_measure)
    }

    /// No two controls overlap, and every one is inside the pane.
    #[test]
    fn controls_do_not_overlap_and_stay_inside_the_pane() {
        for (dpi, width) in [(96, 560), (144, 840), (96, 400)] {
            let laid = basics_laid(dpi, width);
            let ctls: Vec<&Placed> = laid.cells.iter().filter(|p| p.kind.is_control() || p.kind == Kind::Grip).collect();
            assert!(ctls.len() > 10);
            for (i, a) in ctls.iter().enumerate() {
                assert!(a.rect.left >= 0 && a.rect.right <= width, "{} escapes the pane at {dpi}", a.key);
                assert!(a.rect.bottom > a.rect.top, "{} has no height", a.key);
                for b in &ctls[i + 1..] {
                    let overlap = a.rect.left < b.rect.right
                        && b.rect.left < a.rect.right
                        && a.rect.top < b.rect.bottom
                        && b.rect.top < a.rect.bottom;
                    assert!(!overlap, "{} overlaps {} at {dpi}", a.key, b.key);
                }
            }
        }
    }

    /// The grip is directly under the instructions box and as wide as it:
    /// it is the box's bottom edge, not a separate thing.
    #[test]
    fn the_grip_is_the_instructions_boxs_bottom_edge() {
        let laid = basics_laid(96, 560);
        let find = |k: &str| laid.cells.iter().find(|p| p.key == k).unwrap().rect;
        let (instr, grip) = (find("instr"), find("grip"));
        assert_eq!(instr.bottom - instr.top, 240);
        assert_eq!((grip.left, grip.right), (instr.left, instr.right));
        assert!(grip.top >= instr.bottom && grip.top - instr.bottom <= 2, "{instr:?} {grip:?}");
    }

    /// Dragging makes the box taller, and the rest of the page moves down
    /// by exactly that much.
    #[test]
    fn a_taller_box_pushes_the_page_down_by_the_difference() {
        let mut c = cat(&["r"]);
        let ed = editing(&mut c);
        let empty = HashSet::new();
        let clis = snapshot();
        let at = |h: i32| {
            let v = View { ed: &ed, clis: &clis, instr_h: h, search: "", collapsed: &empty, expanded: &empty };
            place(&rows(&v), 560, 96, &fake_measure)
        };
        let (a, b) = (at(240), at(400));
        assert_eq!(b.height - a.height, 160);
        let sup = |l: &Laid| l.cells.iter().find(|p| p.key == "sup").unwrap().rect.top;
        assert_eq!(sup(&b) - sup(&a), 160);
    }

    /// ⚠️ **The rule that left a role's old name on screen.** The window
    /// opens with the name field focused; selecting another role changed
    /// every other field and not that one, because "it has the keyboard"
    /// was read as "the person is typing in it".
    #[test]
    fn a_focused_field_is_left_alone_while_typing_and_written_when_the_draft_is_replaced() {
        // Typing: the model already holds what the control shows, and where
        // it does not, the control is the newer of the two.
        assert!(!text_needs_writing(true, true, false));
        assert!(!text_needs_writing(true, false, false));
        // The draft was replaced: the control is the stale one, keyboard or
        // not.
        assert!(text_needs_writing(true, false, true));
        assert!(text_needs_writing(false, false, false));
        // Nothing to write either way when they already agree.
        assert!(!text_needs_writing(false, true, true));
        assert!(!text_needs_writing(true, true, true));
    }

    /// The footer says why Launch is grey, because the button cannot.
    #[test]
    fn the_footer_says_why_launching_is_not_offered() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        assert_eq!(footer_note(&ed, true), None);
        let (no_terminal, is_error) = footer_note(&ed, false).unwrap();
        assert!(!is_error);
        assert_eq!(no_terminal, tr("Open a terminal window first; the new tab goes beside it."));
        // An unsaved change is the nearer reason, and an error beats both.
        ed.draft.as_mut().unwrap().name = "x".into();
        assert_eq!(footer_note(&ed, false).unwrap().0, tr("Unsaved changes"));
        ed.status = Some("refused".into());
        assert_eq!(footer_note(&ed, false).unwrap(), ("refused".to_string(), true));
        // With no role open there is nothing to say.
        ed.load(&c, None);
        assert_eq!(footer_note(&ed, false), None);
    }

    /// ⚠️ **Basics does not fit the window it opens at**, which is why the
    /// wheel has to reach the pane from wherever the keyboard is: the last
    /// section is below the bottom edge until the page is scrolled.
    #[test]
    fn the_basics_page_is_taller_than_the_pane_it_opens_in() {
        let f = frame_layout(W0, H0, 96, None, false, true);
        let pane_h = f.pane.bottom - f.pane.top;
        let laid = basics_laid(96, f.pane.right - f.pane.left);
        assert!(laid.height > pane_h, "{} vs {pane_h}", laid.height);
        let last = laid.cells.iter().map(|p| p.rect.bottom).max().unwrap();
        assert!(last > pane_h, "the last row starts on screen and ends below it");
        // And the CLI checkboxes are among what is out of sight.
        let cli = laid.cells.iter().find(|p| p.key == "cli:claude").unwrap();
        assert!(cli.rect.top > pane_h, "{:?}", cli.rect);
    }

    /// A maximised window is a size like any other: everything is laid out
    /// for it, nothing is left where it was.
    #[test]
    fn a_maximised_size_lays_out_like_any_other() {
        for (w, h, dpi) in [(2560, 1440, 96), (3840, 2160, 192)] {
            let f = frame_layout(w, h, dpi, None, false, true);
            let tabs = f.tabs.unwrap();
            assert!(tabs[0].bottom <= f.pane.top && f.pane.bottom <= f.footer.unwrap().top);
            assert!(f.footer_buttons[2].right <= w);
            // The tab bar stays its own width and centred on the pane rather
            // than stretching across a wide screen.
            assert!(tabs[2].right - tabs[0].left <= TABS_MAX_W * dpi / 96);
            let mid = (tabs[0].left + tabs[2].right) / 2;
            assert!((mid - (f.pane.left + w) / 2).abs() <= 2 * dpi / 96, "tabs are centred");
            let laid = basics_laid(dpi, f.pane.right - f.pane.left);
            for p in laid.cells.iter() {
                assert!(p.rect.right <= f.pane.right - f.pane.left, "{} escapes", p.key);
            }
        }
    }

    #[test]
    fn the_instructions_height_is_held_between_100_and_900() {
        assert_eq!(clamp_instructions_height(20), 100);
        assert_eq!(clamp_instructions_height(5000), 900);
        assert_eq!(clamp_instructions_height(333), 333);
        assert_eq!(parse_height(" 333\n"), Some(333));
        assert_eq!(parse_height("9999"), Some(900));
        assert_eq!(parse_height("tall"), None, "an unreadable file is no memory, not zero");
    }

    #[test]
    fn the_frame_fits_at_the_smallest_size_and_nothing_overlaps() {
        for dpi in [96, 120, 144, 192] {
            let (w, h) = (MIN_W * dpi / 96, MIN_H * dpi / 96);
            let f = frame_layout(w, h, dpi, Some(40), true, true);
            let tabs = f.tabs.unwrap();
            let banner = f.banner.unwrap();
            let footer = f.footer.unwrap();
            assert!(f.error.unwrap().bottom <= banner.top);
            assert!(banner.bottom <= tabs[0].top);
            assert!(tabs[0].bottom <= f.pane.top);
            assert!(f.pane.bottom <= footer.top);
            assert!(f.pane.bottom - f.pane.top > 100 * dpi / 96, "a pane with room to edit in at {dpi}");
            let [launch, revert, save] = f.footer_buttons;
            assert!(launch.right <= revert.left && revert.right <= save.left && save.right <= w);
            assert!(f.status.right <= launch.left && f.status.left < f.status.right);
            assert!(f.list_buttons[2].right <= f.list.right);
            assert!(tabs[0].right <= tabs[1].left && tabs[2].right <= w);
        }
        // No role open: no tabs, no footer, and the pane takes the rest.
        let f = frame_layout(920, 720, 96, None, false, false);
        assert!(f.tabs.is_none() && f.footer.is_none() && f.banner.is_none());
        assert_eq!(f.pane.bottom, 720);
    }

    #[test]
    fn a_click_between_rows_or_above_the_first_selects_nothing() {
        let r0 = role_row_rect_at(96, 0, 0).unwrap();
        assert_eq!(role_row_at_y(96, 0, 5, r0.top - 1, 1000), None, "the padding above row 0");
        assert_eq!(role_row_at_y(96, 0, 5, r0.top, 1000), Some(0));
        assert_eq!(role_row_at_y(96, 0, 5, r0.bottom, 1000), Some(1));
        assert_eq!(role_row_at_y(96, 0, 2, r0.bottom * 3, 1000), None, "below the last row");
        // Scrolled: the row at the top of the view is `top`, not 0.
        assert_eq!(role_row_at_y(96, 3, 5, r0.top, 1000), Some(3));
        assert!(role_row_rect_at(96, 3, 2).is_none());
        // A row cut by the buttons below the list is not clickable.
        assert_eq!(role_row_at_y(96, 0, 5, r0.top + 1, r0.bottom - 1), None);
    }

    #[test]
    fn quiet_minutes_round_trip_and_an_empty_box_asks_for_nothing() {
        assert_eq!(quiet_minutes(600_000), 10);
        assert_eq!(quiet_minutes(1_000), 1, "under a minute still shows one");
        assert_eq!(parse_minutes("15"), Some(900_000));
        assert_eq!(parse_minutes("0"), Some(60_000));
        assert_eq!(parse_minutes("999"), Some(240 * 60_000));
        assert_eq!(parse_minutes(""), None);
    }
}
