//! The role library: every role on the left, one of them being edited on the
//! right. **A section of the settings window** (`settings_win.rs`), not a
//! window of its own: `dev-docs/poltergeist/settings.md` §4 moved it in as it
//! was, so what is below is the old window's content in a child window, and
//! the shell around it -- the title bar, the size, closing, where the
//! keyboard goes after -- is `settings_win.rs`'s.
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

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{
    GetLastError, COLORREF, ERROR_CLASS_ALREADY_EXISTS, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::i18n::tr;
use crate::roles::{self, AgentCli, Catalog, CliChoice, CliItem, CliSnapshot, ItemGroup, ItemKind, Official, Open, Role, SkillCatalog};
use crate::theme;
use polter_settings_shell::official::{self as shipped, Entry, State as OfficialState};
use polter_settings_shell::{grid, section_grid};

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
    /// The official skill on screen, when it is one of those and not a
    /// role (`draft` is then `None`): its name, its whole text as it is
    /// being typed, and the text it was loaded with.
    pub skill: Option<String>,
    pub skill_text: String,
    pub skill_saved: String,
}

fn taken(cat: &Catalog) -> HashSet<String> {
    cat.roles.iter().map(|r| r.key.clone()).collect()
}

impl Editor {
    pub fn is_dirty(&self) -> bool {
        if self.skill.is_some() {
            return self.skill_text != self.skill_saved;
        }
        match &self.draft {
            None => false,
            Some(d) => self.is_new || Some(d) != self.original.as_ref(),
        }
    }

    pub fn load(&mut self, cat: &Catalog, key: Option<&str>) {
        self.skill = None;
        self.skill_text.clear();
        self.skill_saved.clear();
        self.selection = key.map(str::to_string);
        self.is_new = false;
        self.status = None;
        let role = key.and_then(|k| cat.role(k)).cloned();
        self.original = role.clone();
        self.active_cli = role.as_ref().and_then(|r| r.clis.first()).map(|c| c.cli.clone());
        self.draft = role;
    }

    /// Put an official skill on screen in place of a role. Call only once
    /// leaving the current draft has been agreed to.
    pub fn load_skill(&mut self, cat: &Catalog, skills: &SkillCatalog, name: &str) {
        self.load(cat, None);
        let text = skills.skill(name).map(|k| k.source.clone()).unwrap_or_default();
        self.skill = Some(name.to_string());
        self.skill_text = text.clone();
        self.skill_saved = text;
    }

    /// After the library changed underneath: keep the draft, refresh what
    /// "saved" means for it, and drop a selection that is gone.
    pub fn library_changed(&mut self, cat: &Catalog, skills: &SkillCatalog) {
        if let Some(name) = self.skill.clone() {
            if !self.is_dirty() {
                self.load_skill(cat, skills, &name);
            }
            return;
        }
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

    /// What `put` should be handed, or why not. `Ok(None)` is nothing to
    /// save: no role on screen.
    ///
    /// **An official role is saved like any other** (#1507). It used to be
    /// `Ok(None)` here, which was right while nothing in one could be typed
    /// into -- and would have been "saved" with nothing saved the moment
    /// something could. The core keeps what may change as the person's
    /// change and refuses the rest by name.
    ///
    /// **Checked here and not left to the core** for the one case the core
    /// cannot tell apart: a *new* role whose key is already used would be a
    /// replacement to the core, and the user asked for a new one.
    pub fn save_request(&self, cat: &Catalog) -> Result<Option<Role>, String> {
        let Some(role) = self.draft.as_ref() else { return Ok(None) };
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
        if self.skill.is_some() {
            self.skill_text = self.skill_saved.clone();
            self.status = None;
        } else if self.is_new {
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
    ed.is_new || ed.skill.is_some() || ed.draft.as_ref().map(|d| d.key.as_str()) != Some(key)
}

/// The same for an official skill in the list.
pub fn selecting_skill_is_a_change(ed: &Editor, name: &str) -> bool {
    ed.skill.as_deref() != Some(name)
}

/// What "Restore Factory Settings…" would act on, for the official role or
/// skill on screen: where it stands. `None` when there is no official thing
/// on screen -- then there is no strip and no button.
pub fn official_on_screen<'a>(ed: &'a Editor, skills: &'a SkillCatalog) -> Option<(bool, Option<&'a Official>)> {
    if let Some(name) = &ed.skill {
        return Some((true, skills.skill(name).map(|k| &k.official)));
    }
    ed.draft.as_ref().filter(|d| d.builtin && !ed.is_new)?;
    Some((false, ed.original.as_ref().and_then(|o| o.official.as_ref())))
}

/// Which parts of the draft can be typed into.
///
/// **An official role is mostly editable** (#1507): its name, its
/// description and the three switches that grant the terminal something are
/// shown and locked (`official::locks`), and everything else can be changed
/// and put back.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Editable {
    pub name: bool,
    pub key: bool,
    pub summary: bool,
    pub instructions: bool,
    /// Supervisor, may-authorise, shield.
    pub standing: bool,
    /// "Open in". Its own field: it used to share one with the three above,
    /// which is one rule for two different things.
    pub open: bool,
    pub watch: bool,
    pub quiet: bool,
    pub clis: bool,
    pub start: bool,
    pub items: bool,
}

pub fn editable(ed: &Editor) -> Editable {
    let Some(d) = ed.draft.as_ref() else { return Editable::default() };
    let locks = shipped::locks(d.builtin);
    let p = &d.polter;
    Editable {
        name: !locks.name,
        // A key is chosen once: after saving, roles and terminals refer to
        // the role by it.
        key: !d.builtin && ed.is_new,
        summary: !locks.summary,
        instructions: true,
        standing: !locks.standing,
        open: true,
        // A supervisor watches, it is not watched; a shielded terminal is out
        // of every tool's reach, a supervisor's included.
        watch: !p.supervisor && !p.shielded,
        quiet: !p.shielded,
        clis: true,
        start: true,
        items: true,
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
    /// "Restore Factory Settings…", in the official strip: there is
    /// something to put back.
    pub restore: bool,
}

/// `can_launch`: is there a terminal to open the tab beside. Asked by the
/// caller every time, because a window can open or close while this one
/// stays up.
pub fn buttons(ed: &Editor, cat: &Catalog, skills: &SkillCatalog, can_launch: bool) -> Buttons {
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
        restore: official_on_screen(ed, skills).and_then(|(_, o)| o).is_some_and(Official::can_restore),
    }
}

/// The sentence the footer shows when nothing more urgent is there: why
/// Launch is grey, else that there are unsaved changes. **The macOS footer's
/// order** (`RoleLibraryView.launchBlockedReason`, task 1604): no terminal
/// window, then unsaved changes ("save it first", the reason Launch is
/// grey), then no CLI. It said only "Unsaved changes" before, which is not a
/// reason, and never said a role with no CLI cannot be launched.
pub fn footer_note(ed: &Editor, can_launch: bool) -> Option<(String, bool)> {
    if let Some(s) = &ed.status {
        return Some((s.clone(), true));
    }
    if ed.draft.is_none() && ed.skill.is_none() {
        return None;
    }
    // An official skill is not launched; the reason Launch is grey is not
    // this page's to give, and its footer says only that it is changed.
    if ed.skill.is_none() {
        if !can_launch {
            return Some((tr("Open a terminal window first; the new tab goes beside it."), false));
        }
        if ed.is_dirty() {
            return Some((tr("Save the role before launching it."), false));
        }
        if ed.draft.as_ref().is_some_and(|d| d.clis.is_empty()) {
            return Some((tr("Pick an agent CLI under Basics to launch this role."), false));
        }
        return None;
    }
    if ed.is_dirty() {
        return Some((tr("Unsaved changes"), false));
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

/// One row of the list column: a role, the official skills' heading, or an
/// official skill.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListRow {
    /// What it is: `Entry::Role(None)` is the unsaved new role, which has no
    /// key of its own yet in the library and cannot be clicked back to.
    pub entry: Entry,
    pub title: String,
    pub subtitle: String,
    /// Comes with Polter: drawn with the "Official" mark.
    pub builtin: bool,
    /// Drawn with a dot: unsaved here, or changed from factory settings.
    pub dot: bool,
    pub selected: bool,
}

#[cfg(test)]
impl ListRow {
    pub fn key(&self) -> Option<&str> {
        match &self.entry {
            Entry::Role(k) => k.as_deref(),
            _ => None,
        }
    }
}

pub fn list_rows(ed: &Editor, cat: &Catalog, skills: &SkillCatalog, clis: &CliSnapshot) -> Vec<ListRow> {
    let row = |r: &Role, key: Option<String>, unsaved: bool, selected: bool| ListRow {
        entry: Entry::Role(key),
        title: if r.display_name().is_empty() { r.key.clone() } else { r.display_name() },
        subtitle: if r.clis.is_empty() {
            tr("No agent CLI")
        } else {
            r.clis.iter().map(|c| clis.label(&c.cli)).collect::<Vec<_>>().join(" · ")
        },
        builtin: r.builtin,
        dot: shipped::dot(unsaved, r.official.as_ref().map(|o| o.state)),
        selected,
    };
    let mut out = Vec::new();
    if ed.is_new {
        if let Some(d) = &ed.draft {
            out.push(row(d, None, true, true));
        }
    }
    for r in &cat.roles {
        let open = !ed.is_new && ed.skill.is_none() && ed.draft.as_ref().is_some_and(|d| d.key == r.key);
        // The dot goes on the saved row while its draft is dirty: what the
        // list shows is the library, and the dot says the screen differs.
        out.push(row(r, Some(r.key.clone()), open && ed.is_dirty(), open));
    }
    // The skills Polter ships, under the roles: the same list, because a
    // role is where a person meets them, and the same mark.
    if !skills.skills.is_empty() {
        out.push(ListRow {
            entry: Entry::Heading,
            title: tr("Official Skills"),
            subtitle: String::new(),
            builtin: false,
            dot: false,
            selected: false,
        });
        for k in &skills.skills {
            let open = ed.skill.as_deref() == Some(k.name.as_str());
            out.push(ListRow {
                entry: Entry::Skill(k.name.clone()),
                title: k.name.clone(),
                // Its name and the mark, nothing under them: the macOS row
                // (task 1550). The description is on its page.
                subtitle: String::new(),
                builtin: true,
                dot: shipped::dot(open && ed.is_dirty(), Some(k.official.state)),
                selected: open,
            });
        }
    }
    out
}

/// The sentence where the list would be, when there is no list. **Empty is
/// not the same as not read yet**: `loaded == false` is a library nobody has
/// looked at.
pub fn list_empty_note(ed: &Editor, cat: &Catalog) -> Option<(String, String)> {
    if !cat.roles.is_empty() || ed.is_new || ed.skill.is_some() {
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
    /// are mapped back to. Empty for painted text, except the words a locked
    /// field shows in its box's place, which keep the box's key (`locked`).
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
    pub cat: &'a Catalog,
    pub skills: &'a SkillCatalog,
    pub clis: &'a CliSnapshot,
    /// DIP.
    pub instr_h: i32,
    pub search: &'a str,
    pub collapsed: &'a HashSet<String>,
    pub expanded: &'a HashSet<String>,
}

// The form's columns and gaps are the settings window's grid (settings.md
// §2.3a), taken from the one place that writes them.
const LABEL_W: i32 = grid::LABEL_W;
const LABEL_GAP: i32 = grid::LABEL_GAP;
const SECTION_GAP: i32 = grid::GROUP_GAP;
/// Where the control column starts: check boxes, drop-downs and the notes
/// under them go here as well as the fields beside labels, so the page has
/// two left edges -- the margin and this -- and no third.
const CONTROL_COL: i32 = LABEL_W + LABEL_GAP;
/// The lock after a locked field, and the room kept for it on the rows
/// beside one (the place's natural width of `Kind::Lock` is this too).
const LOCK_W: i32 = 12;
/// An official skill's text box: the macOS side's minimum. The whole file is
/// in it, frontmatter and all, so it is the page.
const SKILL_TEXT_H: i32 = 320;
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
    field_with(label, vec![cell])
}
/// A label and more than one thing beside it: a locked box and its lock.
fn field_with(label: String, cells: Vec<Cell>) -> Row {
    let lab = Cell {
        key: String::new(),
        kind: Kind::Text { text: label, tone: Tone::Dim, font: Font::Normal, right: true, lines: 1 },
        width: Width::Fixed(LABEL_W),
        enabled: true,
    };
    row(std::iter::once(lab).chain(cells).collect())
}
/// A row in the control column, with nothing in the label column: check
/// boxes and the notes under them (settings.md §2.3a).
fn in_controls(cells: Vec<Cell>, gap: i32) -> Row {
    Row { cells, indent: CONTROL_COL, gap }
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
    Some(Row { cells, indent: CONTROL_COL, gap: 4 })
}

/// Every row of the right-hand pane, top to bottom: what the library and
/// the thing on screen have to say for themselves, then the page.
pub fn rows(v: &View) -> Vec<Row> {
    let mut out = notice_rows(v);
    let page = if v.ed.skill.is_some() {
        skill_rows(v)
    } else if let Some(d) = v.ed.draft.as_ref() {
        match v.ed.tab.kind() {
            None => basics_rows(v, d),
            Some(kind) => item_rows(v, d, kind),
        }
    } else {
        vec![Row {
            cells: vec![text(tr("Select a role, or make a new one."), Tone::Dim, Font::Normal)],
            indent: 0,
            gap: 40,
        }]
    };
    // The page starts a group's gap under the notices, as a section does.
    let had_notices = !out.is_empty();
    for (i, mut r) in page.into_iter().enumerate() {
        if i == 0 && had_notices {
            r.gap = r.gap.max(SECTION_GAP);
        }
        out.push(r);
    }
    out
}

/// A notice: its first line, with a button beside it when it has one, and
/// a second line under it.
fn notice(out: &mut Vec<Row>, first: String, warn: bool, button: Option<(String, String)>, second: Option<String>) {
    let tone = if warn { Tone::Warn } else { Tone::Text };
    let mut cells = vec![text(first, tone, Font::Bold)];
    if let Some((key, label)) = button {
        cells.push(ctl(key, Kind::Button { text: label }, Width::Auto, true));
    }
    out.push(Row { cells, indent: 0, gap: if out.is_empty() { 0 } else { ROW_GAP } });
    if let Some(t) = second.filter(|t| !t.is_empty()) {
        out.push(Row { cells: vec![text(t, Tone::Dim, Font::Small)], indent: 0, gap: -4 });
    }
}

/// What the macOS side shows as banners over the page: the file of changes
/// that could not be read, the person's roles an official one has taken the
/// key of, and -- for the official role or skill on screen -- that the
/// shipped one has moved since, or that the changes to it were not read.
///
/// **Rows of the page, not fixed bands**: each is a sentence of any length
/// in any language, and `place` already wraps a sentence and puts a button
/// beside it at every width (the overlap tests hold that).
fn notice_rows(v: &View) -> Vec<Row> {
    let mut out = Vec::new();
    if let Some(why) = &v.cat.overrides_error {
        notice(&mut out, tr("Your changes to official roles couldn't be read, so they are not in use."), true, None, Some(why.clone()));
    }
    for (key, name) in &v.cat.shadowed {
        let line = tr("Your role \"{}\" has the key {}, which is now an official role's. Yours is kept in the file but isn't in use.")
            .replacen("{}", name, 1)
            .replacen("{}", key, 1);
        notice(&mut out, line, true, Some((format!("adopt:{key}"), tr("Keep It Under a New Key"))), None);
    }
    if let Some((_, Some(o))) = official_on_screen(v.ed, v.skills) {
        match o.state {
            OfficialState::ModifiedStale => {
                let mut fields: Vec<String> = shipped::stale_sections(&o.stale).into_iter().map(tr).collect();
                fields.sort();
                let first = if fields.is_empty() || v.ed.skill.is_some() {
                    tr("The official version has changed")
                } else {
                    tr("The official version has changed: {}").replace("{}", &fields.join(", "))
                };
                notice(
                    &mut out,
                    first,
                    false,
                    Some(("keepmine".into(), tr("Keep Mine"))),
                    Some(tr("The official version of what you changed here has changed since. Yours is still the one in use.")),
                );
            }
            OfficialState::Unknown => notice(
                &mut out,
                tr("Your changes weren't read, so the factory settings are in use."),
                true,
                None,
                o.reason.clone(),
            ),
            OfficialState::Pristine | OfficialState::Modified => {}
        }
    }
    out
}

/// A field that may be locked: a box when it can be changed, and when it
/// cannot, **its words and the lock after them** -- not a grey box, which
/// reads as a box that is broken (task 1550, the macOS row). The words keep
/// the box's key, so whatever looks for the field still finds it; only
/// controls are made into windows (`Kind::is_control`).
fn locked(key: &str, value: &str, mono: bool, editable: bool) -> Vec<Cell> {
    if editable {
        return vec![ctl(key, edit(value, String::new(), mono), Width::Fill, true)];
    }
    vec![
        Cell {
            key: key.into(),
            kind: Kind::Text { text: value.into(), tone: Tone::Text, font: if mono { Font::Mono } else { Font::Normal }, right: false, lines: 0 },
            width: Width::Fill,
            enabled: true,
        },
        Cell { key: String::new(), kind: Kind::Lock, width: Width::Fixed(LOCK_W), enabled: true },
    ]
}

/// The room the lock takes, kept on a row with no lock so the boxes above
/// and below end on one line.
fn lock_room() -> Cell {
    Cell {
        key: String::new(),
        kind: Kind::Text { text: String::new(), tone: Tone::Dim, font: Font::Small, right: false, lines: 1 },
        width: Width::Fixed(LOCK_W),
        enabled: true,
    }
}

/// An official skill: its name, which is its file's and cannot change,
/// where it stands, and its whole text.
fn skill_rows(v: &View) -> Vec<Row> {
    let Some(name) = v.ed.skill.as_deref() else { return Vec::new() };
    let mut out = Vec::new();
    out.push(field_with(tr("Name"), locked("skillname", name, true, false)));
    let state = v.skills.skill(name).map(|k| &k.official);
    let words = match state {
        Some(o) if o.state == OfficialState::Unknown => tr(o.state.text()).replace("{}", o.reason.as_deref().unwrap_or("")),
        Some(o) => tr(o.state.text()),
        // Gone from the list since it was opened: say nothing rather than
        // a state nobody reported.
        None => String::new(),
    };
    out.push(field(tr("Status"), text(words, Tone::Dim, Font::Normal)));
    out.push(heading(tr("Skill Text")));
    out.push(row(vec![ctl(
        "skilltext",
        Kind::Edit { text: v.ed.skill_text.clone(), cue: String::new(), multi: true, height: SKILL_TEXT_H, mono: true, number: false },
        Width::Fill,
        true,
    )]));
    out.push(note(
        tr("Takes effect as soon as it's saved. When an agent that is already running reads the new text depends on the tool it uses."),
        0,
    ));
    out
}

fn basics_rows(v: &View, d: &Role) -> Vec<Row> {
    let e = editable(v.ed);
    let mut out = Vec::new();

    // An official role's name and description are shown with a lock; the
    // key keeps the lock's room so the three boxes end on one line.
    let official = d.builtin && !v.ed.is_new;
    out.push(field_with(tr("Name"), locked("name", &d.display_name(), false, e.name)));
    if v.ed.is_new {
        out.push(field(tr("Key"), ctl("key", edit(&d.key, String::new(), true), Width::Fill, e.key)));
        let ok = Role::is_valid_key(&d.key);
        let (t, tone) = if ok {
            (tr("Lowercase letters, digits and dashes. It can't be changed after saving."), Tone::Dim)
        } else {
            (tr("Only lowercase letters, digits and dashes, at most 32."), Tone::Warn)
        };
        out.push(Row { cells: vec![text(t, tone, Font::Small)], indent: CONTROL_COL, gap: -4 });
    } else {
        // Read-only rather than painted: a key is the thing people copy.
        let mut key_row = field(tr("Key"), ctl("key", edit(&d.key, String::new(), true), Width::Fill, false));
        if official {
            key_row.cells.push(lock_room());
        }
        out.push(key_row);
    }
    let summary = if e.summary {
        vec![ctl("summary", edit(&d.display_summary(), tr("What this role is for, for whoever picks it"), false), Width::Fill, true)]
    } else {
        locked("summary", &d.display_summary(), false, false)
    };
    out.push(field_with(tr("Description"), summary));

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
    out.push(in_controls(vec![check("sup", tr("Make this terminal a supervisor"), p.supervisor, e.standing)], 0));
    out.push(in_controls(vec![check("auth", tr("Let the supervisor answer this terminal's permission prompts"), p.may_authorise, e.standing)], 0));
    out.push(in_controls(vec![check("shield", tr("Shield it: no tool can reach it, a supervisor's included"), p.shielded, e.standing)], 0));
    out.push(note(tr(shipped::standing_note(d.builtin)), CONTROL_COL));
    out.push(in_controls(vec![check("watch", tr("Hand it to the supervisor to watch"), p.watch, e.watch)], 4));
    // The macOS side has this as the toggle's tooltip. Here it is on the
    // page: the rule is not guessable, and a hover nobody makes teaches
    // nothing.
    out.push(note(tr("The supervisor that started it, or the only one there is. With several and you starting it, nobody."), CONTROL_COL));
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
    out.push(in_controls(quiet, 0));
    // A drop-down beside its label, like every other field: the label in
    // the label column, the control in the control column.
    let mut open_in = field(
        tr("Open in"),
        ctl(
            "open",
            Kind::Combo {
                options: vec![tr("Here when at a prompt, else a new tab"), tr("Always a new tab")],
                sel: usize::from(p.open == Open::Tab),
            },
            Width::Auto,
            e.open,
        ),
    );
    open_in.gap = 4;
    out.push(open_in);
    out.push(note(
        tr("Applied once, when the role starts an agent CLI. Putting the role on a terminal that's already running changes its tools, not these."),
        CONTROL_COL,
    ));

    out.push(heading(tr("Agent CLIs")));
    if v.clis.stale && v.clis.clis.is_empty() {
        out.push(note(tr("Reading what's installed…"), CONTROL_COL));
    } else if v.clis.clis.is_empty() {
        out.push(note(tr("No plugin that manages an agent CLI is installed and switched on."), CONTROL_COL));
    } else {
        for c in &v.clis.clis {
            let mut cells = vec![check(format!("cli:{}", c.key), c.label.clone(), d.choice(&c.key).is_some(), e.clis)];
            if c.installed == Some(false) {
                cells.push(short(tr("{} isn't on this machine's PATH").replace("{}", &c.bin), Tone::Warn, Font::Small));
            }
            if c.error.is_some() {
                cells.push(short(tr("Its plugin couldn't list what's installed"), Tone::Warn, Font::Small));
            }
            out.push(in_controls(cells, 0));
        }
        // Choices for a CLI no plugin offers any more are still in the role;
        // say so rather than hide them.
        for orphan in d.clis.iter().filter(|c| v.clis.cli(&c.cli).is_none()) {
            out.push(in_controls(
                vec![
                    check(format!("orphan:{}", orphan.cli), orphan.cli.clone(), true, e.clis),
                    short(tr("No plugin manages this CLI any more"), Tone::Warn, Font::Small),
                ],
                0,
            ));
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
                indent: CONTROL_COL,
                gap: -4,
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
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct After {
    /// Ask the adapters again (`roles::clis(true)`).
    pub reread_clis: bool,
    /// "Keep Mine" was pressed on the official role or skill on screen.
    pub keep_mine: bool,
    /// "Keep It Under a New Key" was pressed for this key.
    pub adopt: Option<String>,
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
        Action::Click(k) if k == "keepmine" => after.keep_mine = true,
        Action::Click(k) if k.starts_with("adopt:") => after.adopt = Some(k["adopt:".len()..].to_string()),
        // The whole file, as the box has it. The window hands it over with
        // `\n` line ends already (`from_box` on `EN_CHANGE`); this keeps a
        // caller that did not -- a test, a paste into a model -- from
        // differing from the saved text by every line.
        Action::Text(k, t) if k == "skilltext" => {
            if m.ed.skill.is_some() {
                m.ed.skill_text = t.replace("\r\n", "\n");
            }
        }
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
                "sup" if e.standing => p.supervisor = on,
                "auth" if e.standing => p.may_authorise = on,
                "shield" if e.standing => p.shielded = on,
                "watch" if e.watch => p.watch = on,
                "quiet" if e.quiet => p.quiet_ms = on.then_some(QUIET_DEFAULT_MS),
                _ => {}
            }
        }
        Action::Choose(k, i) if k == "open" && e.open => {
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

/// The size this section is given inside the settings window when that
/// opens, and at its smallest (settings.md §2.2). Not a window of its own
/// any more, so the tests below lay it out at these.
#[cfg(test)]
const W0: i32 = polter_settings_shell::content_size(polter_settings_shell::FIRST_W, polter_settings_shell::FIRST_H).0;
#[cfg(test)]
const H0: i32 = polter_settings_shell::content_size(polter_settings_shell::FIRST_W, polter_settings_shell::FIRST_H).1;
#[cfg(test)]
const MIN_W: i32 = polter_settings_shell::content_size(polter_settings_shell::MIN_W, polter_settings_shell::MIN_H).0;
#[cfg(test)]
const MIN_H: i32 = polter_settings_shell::content_size(polter_settings_shell::MIN_W, polter_settings_shell::MIN_H).1;
// The grid's values, under the names this file has always used for them.
const LIST_W: i32 = grid::LIST;
const PAD: i32 = grid::PAD;
const FIELD_H: i32 = grid::CONTROL_H;
const BTN_H: i32 = grid::CONTROL_H;
const ROW_GAP: i32 = grid::ROW_GAP;
const CELL_GAP: i32 = grid::BUTTONS_GAP;
// This section's own sizes.
const ROLE_ROW_H: i32 = 44;
const TABBAR_H: i32 = 44;
const TABS_MAX_W: i32 = 420;
const GRIP_H: i32 = 8;
/// Between a list row's name and the "Official" mark, and between the mark
/// and the dot: the macOS `OfficialMark.gap`, one number for both since
/// task 1514.
const MARK_GAP: i32 = 6;

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
                (Width::Auto, Kind::Check { text, .. }) => {
                    Some(measure(text, avail, Font::Normal, true).0 + s(grid::CHECK_BOX + grid::CHECK_GAP) + 2)
                }
                (Width::Auto, Kind::Button { text }) => Some((measure(text, avail, Font::Normal, true).0 + s(24)).max(s(72))),
                (Width::Auto, Kind::Link { text }) => Some(measure(text, avail, Font::Normal, true).0 + s(8)),
                (Width::Auto, Kind::Segment { text, .. }) => Some(measure(text, avail, Font::Normal, true).0 + s(28)),
                (Width::Auto, Kind::Combo { options, .. }) => {
                    Some(options.iter().map(|o| measure(o, avail, Font::Normal, true).0).max().unwrap_or(0) + s(40))
                }
                (Width::Auto, Kind::Lock) => Some(s(LOCK_W)),
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
            // **Never past the row's right edge.** A natural width is capped
            // at the whole row above, not at what is left of it after the
            // cells before -- so a drop-down beside a 120 label (the control
            // column, settings.md §2.3a) ran out of the pane at 400 wide.
            let w = w.min((right - x).max(0));
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

/// The fixed parts of the section, in its client pixels. The list, its
/// divider, the bottom rule and band and every button in the band are the
/// settings window's grid (`section_grid`, settings.md §2.3a); only what is
/// inside the editor column is decided here.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub list: RECT,
    /// The line between the list and the editor, from the top rule to the
    /// bottom rule.
    pub list_divider: RECT,
    /// + ⧉ −, at the left end of the bottom band.
    pub list_buttons: [RECT; 3],
    pub error: Option<RECT>,
    /// "Restore Factory Settings…" over an official role or skill: in the
    /// bottom band, beside Launch, as on macOS (`official::footer`).
    pub restore: Option<RECT>,
    pub tabs: Option<[RECT; 3]>,
    pub pane: RECT,
    /// The rule over the bottom band: the window's rule, on the same row.
    pub bottom_rule: RECT,
    /// The bottom band, **always there** -- with no role open it is empty,
    /// and the body above it does not grow into it.
    pub band: RECT,
    pub status: RECT,
    /// Launch, Discard Changes, Save, left to right.
    pub footer_buttons: [RECT; 3],
    /// Where a list row's text starts: the list's left line plus `PAD`,
    /// the + button's x and the breadcrumb's (§2.3a).
    pub text_left: i32,
}

fn rect(r: polter_settings_shell::Rect) -> RECT {
    RECT { left: r.left, top: r.top, right: r.right, bottom: r.bottom }
}

/// What decides the fixed parts besides the size: whatever was measured.
/// **One value for both callers** -- the refresh that moves the controls and
/// the paint that draws round them -- so they cannot work it out twice and
/// disagree (`frame_inputs` makes it).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrameInputs {
    /// The measured height of the library-error text, when there is one.
    /// Measured because the core's message is any length.
    pub error_h: Option<i32>,
    /// The band's buttons' words, measured: Launch, Discard Changes, Save,
    /// Restore Factory Settings… -- each button is as wide as its words.
    pub footer_text_w: [i32; 4],
    /// An official role or skill is on screen: Restore is in the band.
    pub official: bool,
    /// A role is on screen: the tab bar. Not for a skill, which is one page.
    pub tabs: bool,
}

pub fn frame_layout(w: i32, h: i32, dpi: i32, fi: FrameInputs) -> Frame {
    let s = |v: i32| v * dpi / 96;
    let g = section_grid(w, h, dpi, true);
    let (Some(list), Some(list_divider), Some(list_buttons)) = (g.list, g.list_divider, g.list_buttons) else {
        unreachable!("section_grid with a list returns one")
    };
    let left = g.editor.left;
    let body = g.editor.bottom;
    let mut y = 0;
    let error = fi.error_h.map(|eh| {
        let r = RECT { left, top: y, right: w, bottom: y + eh + s(PAD) };
        y = r.bottom;
        r
    });
    let has_draft = fi.tabs;
    let foot = shipped::footer(&g, dpi, fi.footer_text_w, has_draft, fi.official);
    let tabs = has_draft.then(|| {
        let tw = (w - left - 2 * s(PAD)).min(s(TABS_MAX_W)).max(s(90));
        let x0 = left + ((w - left) - tw) / 2;
        let top = y + (s(TABBAR_H) - s(BTN_H)) / 2;
        let one = tw / 3;
        [0, 1, 2].map(|i| RECT { left: x0 + i * one, top, right: x0 + (i + 1) * one, bottom: top + s(BTN_H) })
    });
    if has_draft {
        y += s(TABBAR_H);
    }
    let pane = RECT { left, top: y.min(body), right: w, bottom: body };
    Frame {
        list: rect(list),
        list_divider: rect(list_divider),
        list_buttons: list_buttons.map(rect),
        error,
        restore: foot.restore.map(rect),
        tabs,
        pane,
        bottom_rule: rect(g.bottom_rule),
        band: rect(g.band),
        status: rect(foot.status),
        footer_buttons: foot.actions.map(rect),
        text_left: g.text_left,
    }
}

/// Where the role list draws row `index`, with `top` the first row shown,
/// or `None` when it is scrolled away above. **The only place that
/// decides** -- the painter and the click both ask it, which is the rule
/// `settings_ui.rs`'s `plugin_row_rect_at` records and
/// `one-place-decides-where-a-row-is.py` holds.
pub fn role_row_rect_at(dpi: i32, top: usize, index: usize) -> Option<RECT> {
    let s = |v: i32| v * dpi / 96;
    let n = index.checked_sub(top)?;
    let y = s(ROW_GAP) + n as i32 * s(ROLE_ROW_H);
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

/// Where the keyboard goes when this window hides: the window that had it
/// before, or the terminal this one belongs to.
///
/// ⚠️ **"The window that had it" can be this window.** The handle was read
/// after the window was already on screen, so it was this one -- and the
/// close handed the keyboard back to a window it had just hidden. The log
/// said so and read as success: *handed back to HWND(0x6101ee) ok=1 --
/// GetForegroundWindow now HWND(0x6101ee): the window that had it*. All
/// three of "nothing had it", "this window had it" and "the window that had
/// it is gone" end in the same place, which is the terminal this one was
/// opened over; a window that hides itself must leave the keyboard
/// somewhere a person can type into.
pub fn handback_to(prev: isize, prev_usable: bool, owner: isize) -> isize {
    if prev != 0 && prev_usable {
        prev
    } else {
        owner
    }
}

/// What a window that is gone leaves behind: nothing that names it.
///
/// An owned window is destroyed with its owner, and everything remembered
/// about it -- the handles, the controls, what was on screen -- stops being
/// true at that moment. **The draft goes too**: the next opening starts from
/// the library, exactly as it does after a close.
pub fn forgotten(m: &mut Model) {
    m.ed = Editor::default();
    m.search.clear();
    m.collapsed.clear();
    m.expanded.clear();
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
/// "Restore Factory Settings…", in the official strip.
const ID_RESTORE: u16 = 120;
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
    restore: HWND,
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
    skills: SkillCatalog,
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
    /// What the settings window's search box says; the list shows only the
    /// roles it matches (settings.md §2.3).
    list_filter: String,
    /// The role selected when the settings window last closed, so the next
    /// opening with no role named comes back to it (§3.1). Kept by
    /// `forget_window`, which is about handles, not about this.
    remembered: Option<String>,
}

impl Default for State {
    fn default() -> Self {
        State {
            model: Model::default(),
            cat: Catalog::default(),
            skills: SkillCatalog::default(),
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
            list_filter: String::new(),
            remembered: None,
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

/// Put the library into the settings window `host`, at `rect` in `host`'s
/// client coordinates, making it the first time.
///
/// `origin` is the window the settings were opened from, **re-answered at
/// every showing**: it is only what a Launch opens its tab beside, and the
/// settings window itself belongs to no terminal (settings.md §2.1).
///
/// `item` is the role key a route named (§3.1): `None` keeps what is on
/// screen, else the role selected when the window last closed, else the
/// first. **Asks nothing** -- leaving a dirty draft for another role was
/// agreed to by the settings window before this is called
/// (`polter_settings_shell::must_ask`), so a named role that differs from
/// the one on screen replaces it here.
pub fn show(host: HWND, rect: RECT, origin: HWND, item: Option<&str>) {
    // ⚠️ **A handle remembered for a window that is gone names nothing.**
    // The library used to be owned by a terminal window and was destroyed
    // with it, after which `open` believed the stale handle and wrote
    // `[roles-ui] shown` about a window that had not existed for some time
    // (status.md, the role library's section). It is now a child of a
    // window nothing owns, so that path is closed; this is the second
    // reading, kept because being wrong here is silent.
    if !main_hwnd().0.is_null() && !unsafe { IsWindow(Some(main_hwnd())) }.as_bool() {
        forget_window();
    }
    if main_hwnd().0.is_null() && !create(host) {
        return;
    }
    let win = main_hwnd();
    let was_visible = unsafe { IsWindowVisible(win) }.as_bool();
    // ⚠️ **What this is handed is not always a terminal window**: the tab's
    // right-click menu hands over the surface. See `frame_for`.
    let owner = frame_for(origin);
    ST.with(|c| c.borrow_mut().owner = owner);
    if !was_visible {
        let cat = roles::catalog();
        let skills = roles::skills();
        let clis = roles::clis(false);
        let h = load_height();
        ST.with(|c| {
            let s = &mut *c.borrow_mut();
            s.cat = cat;
            s.skills = skills;
            s.clis = clis;
            s.model.instr_h = h;
            s.scroll = 0;
            s.list_top = 0;
        });
        start_polling_if_needed(false);
    }
    let (named, unknown) = ST.with(|c| {
        let s = &mut *c.borrow_mut();
        let named = item.filter(|k| s.cat.role(k).is_some()).map(str::to_string);
        let unknown = item.is_some() && named.is_none();
        match &named {
            Some(k) if s.model.ed.is_new || s.model.ed.selection.as_deref() != Some(k.as_str()) => {
                s.model.ed.load(&s.cat, Some(k));
                s.scroll = 0;
                draft_replaced(s);
            }
            Some(_) => {}
            None if s.model.ed.draft.is_none() && !s.model.ed.is_new && s.model.ed.skill.is_none() => {
                let key = s
                    .remembered
                    .clone()
                    .filter(|k| s.cat.role(k).is_some())
                    .or_else(|| s.cat.roles.first().map(|r| r.key.clone()));
                s.model.ed.load(&s.cat, key.as_deref());
                draft_replaced(s);
            }
            None => {}
        }
        (named, unknown)
    });
    unsafe {
        let _ = SetWindowPos(
            win,
            None,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
        // **Whether a launch is possible is not a fact about this opening.**
        // Terminal windows open and close while this one stays up, and the
        // Launch button has to follow them; nothing else would tell it, so
        // it asks on a timer while it is on screen.
        SetTimer(Some(win), TIMER_TERMINALS, TERMINALS_EVERY_MS, None);
    }
    refresh();
    if !was_visible {
        // The page has real edit controls, so the terminal's TSF document
        // has to go back before any of them takes focus.
        let first = LIVE.with(|l| l.borrow().get("name").map(|x| x.hwnd));
        let _ = crate::overlay::focus_to_edit(first.unwrap_or(win), "roles");
    }
    // process-wide: the role library is a section of the one settings
    // window; it is not opened *for* a terminal window
    crate::plogf!(
        "[roles-ui] shown in the settings window: named={:?} unknown_key={} was_visible={}",
        named,
        unknown,
        was_visible
    );
}

/// Take the library off screen, because the settings window moved to another
/// section or closed. **The draft stays** -- leaving was agreed to before
/// this, and a section switch that was answered "Cancel" never gets here.
pub fn hide() {
    let win = main_hwnd();
    if win.0.is_null() {
        return;
    }
    ST.with(|c| c.borrow_mut().poll_until = None);
    unsafe {
        let _ = KillTimer(Some(win), TIMER_CLIS);
        let _ = KillTimer(Some(win), TIMER_TERMINALS);
        // hides without handing the foreground back: a child window, which
        // cannot be the foreground; the settings window does the handback
        let _ = ShowWindow(win, SW_HIDE);
    }
}

/// The settings window closed: the next opening starts from the library, as
/// a new window does on macOS -- at the role that was selected (§3.1).
pub fn forget_draft() {
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        if let Some(k) = s.model.ed.selection.clone() {
            s.remembered = Some(k);
        }
        forgotten(&mut s.model);
    });
}

/// The settings window was resized.
pub fn move_to(rect: RECT) {
    let win = main_hwnd();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return;
    }
    unsafe {
        let _ = SetWindowPos(
            win,
            None,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOZORDER | SWP_NOACTIVATE,
        );
    }
}

/// The settings window became active again: the terminal may have taken the
/// TSF document meanwhile, and the library may have been changed from
/// somewhere else -- a supervisor's `role_put`, or the file edited by hand.
pub fn activated() {
    let win = main_hwnd();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return;
    }
    crate::ime_focus(false);
    let cat = roles::catalog();
    let skills = roles::skills();
    with_model(|s| {
        s.cat = cat;
        s.skills = skills;
        s.model.ed.library_changed(&s.cat, &s.skills);
        draft_replaced(s);
    });
    refresh();
}

/// This section's half of the settings window's grid log (settings.md
/// §2.3a), in the settings window's client pixels so the two lines compare
/// directly: the bottom rule's row, the list divider's column and rows, and
/// the band's buttons' rows. Silent when the section is not on screen.
pub fn log_grid() {
    let win = main_hwnd();
    if win.0.is_null() || !unsafe { IsWindowVisible(win) }.as_bool() {
        return;
    }
    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let f = frame_layout(rc.right, rc.bottom, dpi_of(win), FrameInputs { tabs: true, ..FrameInputs::default() });
    let root = dialog_owner();
    let mut origin = [POINT { x: 0, y: 0 }];
    unsafe {
        let _ = MapWindowPoints(Some(win), Some(root), &mut origin);
    }
    let (ox, oy) = (origin[0].x, origin[0].y);
    // process-wide: the role library is a section of the one settings window
    crate::plogf!(
        "[roles-ui] grid in settings-window pixels: bottom rule row {} (x {}..{}), list divider col {} (rows {}..{}), \
         + button rows {}..{} x {}, save rows {}..{}",
        oy + f.bottom_rule.top,
        ox + f.bottom_rule.left,
        ox + f.bottom_rule.right - 1,
        ox + f.list_divider.left,
        oy + f.list_divider.top,
        oy + f.list_divider.bottom - 1,
        oy + f.list_buttons[0].top,
        oy + f.list_buttons[0].bottom - 1,
        ox + f.list_buttons[0].left,
        oy + f.footer_buttons[2].top,
        oy + f.footer_buttons[2].bottom - 1
    );
}

/// The system colours or the theme changed. Sent to top-level windows only,
/// so the settings window passes it on. The pane's controls are rebuilt,
/// not only repainted: whether the combo is owner-drawn is a style fixed at
/// creation, and high contrast has to be able to take it back.
pub fn theme_changed() {
    let win = main_hwnd();
    if win.0.is_null() {
        return;
    }
    drop_controls();
    theme::system().dress_scrollbars(HWND(PANE.load(Ordering::Acquire)));
    refresh();
    theme::repaint_all(win);
}

/// The settings window moved to a monitor with another DPI. A child is not
/// sent `WM_DPICHANGED`, so its parent passes it on.
pub fn dpi_changed() {
    let win = main_hwnd();
    if win.0.is_null() {
        return;
    }
    make_fonts(dpi_of(win));
    drop_controls();
    if let Some(f) = FIXED.with(|c| c.get()) {
        for h in f.list_buttons.iter().chain(&f.tabs).chain(&f.footer).chain(std::iter::once(&f.restore)) {
            unsafe {
                SendMessageW(*h, WM_SETFONT, Some(WPARAM(font(Font::Normal).0 as usize)), Some(LPARAM(1)));
            }
        }
    }
    refresh();
}

// ------------------------------------------ what the settings window asks

/// §2.4's `is_dirty`.
pub fn is_dirty() -> bool {
    ST.with(|c| c.borrow().model.ed.is_dirty())
}

/// §2.4's `save`. On failure the reason is already on the page (the status
/// line), and it is also returned.
pub fn save_now() -> Result<(), String> {
    if save() {
        Ok(())
    } else {
        Err(ST.with(|c| c.borrow().model.ed.status.clone()).unwrap_or_default())
    }
}

/// §2.4's `revert`.
pub fn revert_now() {
    revert();
}

/// The role on screen, for the breadcrumb: its name, or its key when it has
/// none. `None` with nothing selected.
pub fn current() -> Option<(Option<String>, String)> {
    ST.with(|c| {
        let s = c.borrow();
        let ed = &s.model.ed;
        if let Some(name) = &ed.skill {
            return Some((None, name.clone()));
        }
        ed.draft.as_ref().map(|d| {
            let name = d.display_name();
            (ed.selection.clone(), if name.is_empty() { d.key.clone() } else { name })
        })
    })
}

/// Every role as the search lists it: the name shown and the key a route
/// selects it by (screenshot.md §12.3).
pub fn search_rows() -> Vec<(String, String)> {
    let cat = ST.with(|c| {
        let s = c.borrow();
        (!s.cat.roles.is_empty()).then(|| s.cat.roles.iter().map(|r| (r.display_name(), r.key.clone())).collect())
    });
    // Before the section was ever shown the library has not been read here.
    cat.unwrap_or_else(|| roles::catalog().roles.iter().map(|r| (r.display_name(), r.key.clone())).collect())
}

/// The list as shown: `list_rows`, narrowed by the search box. A new,
/// unsaved role is always shown -- it is the one being edited, and it has
/// no key the search could have been looking for.
/// The heading over the official skills stays only while a skill under it
/// does: a heading over nothing reads as "there are none".
pub fn filtered_rows(rows: Vec<ListRow>, query: &str) -> Vec<ListRow> {
    let kept: Vec<ListRow> = rows
        .into_iter()
        .filter(|r| match &r.entry {
            Entry::Role(None) | Entry::Heading => true,
            Entry::Role(Some(k)) => polter_settings_shell::matches(query, &r.title) || polter_settings_shell::matches(query, k),
            Entry::Skill(name) => polter_settings_shell::matches(query, name),
        })
        .collect();
    let any_skill = kept.iter().any(|r| matches!(r.entry, Entry::Skill(_)));
    kept.into_iter().filter(|r| any_skill || r.entry != Entry::Heading).collect()
}

fn shown_rows(s: &State) -> Vec<ListRow> {
    filtered_rows(list_rows(&s.model.ed, &s.cat, &s.skills, &s.clis), &s.list_filter)
}

/// What the search has done to the list (settings.md §2.3a).
fn filter_state() -> polter_settings_shell::Filtered {
    ST.with(|c| {
        let s = c.borrow();
        let rows = shown_rows(&s);
        let on_screen = s.model.ed.draft.is_some() || s.model.ed.skill.is_some();
        let selected = on_screen.then(|| rows.iter().any(|r| r.selected));
        polter_settings_shell::filtered(&s.list_filter, rows.len(), selected)
    })
}

/// Whether the role on screen is one the search has hidden from the list,
/// for the breadcrumb's "(not in the search results)".
pub fn selection_hidden() -> bool {
    filter_state().selection_hidden
}

/// Ask the settings window to close, which asks about anything unsaved.
fn request_close(win: HWND) {
    let root = unsafe { GetAncestor(win, GA_ROOT) };
    if !root.0.is_null() {
        let _ = unsafe { PostMessageW(Some(root), WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
}

/// The window a question is asked over: the settings window, never this
/// child -- a dialog owned by a child is owned by nothing Windows can
/// activate on its return.
fn dialog_owner() -> HWND {
    unsafe { GetAncestor(main_hwnd(), GA_ROOT) }
}

fn make_fonts(dpi: i32) {
    for (slot, f) in [
        (&FONT, crate::uifont::ui(dpi, polter_settings_shell::type_size::BODY, FW_NORMAL.0 as i32)),
        (&FONT_BOLD, crate::uifont::ui(dpi, polter_settings_shell::type_size::HEADING, FW_SEMIBOLD.0 as i32)),
        (&FONT_SMALL, crate::uifont::ui(dpi, polter_settings_shell::type_size::SMALL, FW_NORMAL.0 as i32)),
        (&FONT_MONO, crate::uifont::mono(dpi)),
    ] {
        let old = slot.swap(f.0, Ordering::AcqRel);
        if !old.is_null() {
            let _ = unsafe { DeleteObject(HGDIOBJ(old)) };
        }
    }
}

/// Make the fonts the custom-drawn buttons use (`common`), **only when the
/// role library has not made them itself**: another section of the settings
/// window can be shown first, and its buttons are drawn here. Once the
/// library exists it keeps them itself (`dpi_changed`), and remaking them
/// here would pull them out from under its controls.
pub(crate) fn ensure_fonts(dpi: i32) {
    if main_hwnd().0.is_null() {
        make_fonts(dpi);
    }
}

fn hinst() -> HINSTANCE {
    unsafe { GetModuleHandleW(None) }.map(Into::into).unwrap_or_default()
}

/// Register the classes and make the window, once.
fn create(host: HWND) -> bool {
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
            // **`ERROR_CLASS_ALREADY_EXISTS` is not a failure here.** The
            // window can be made a second time -- after it was destroyed with
            // its owner -- and the class from the first time is still
            // registered, so refusing on it would mean the library opens once
            // per process and then never again.
            if RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS {
                // process-wide: registering the window class, once per process
                // absence: means it was not reached -- this is the failure arm
                // of a call made once, the first time the library is opened,
                // so a log with neither this line nor `[roles-ui] ready` means
                // `open` was never called, not that the class registered.
                crate::plogf!("[roles-ui] RegisterClassExW failed");
                return false;
            }
        }
        // A child of the settings window (settings.md §4): the title bar,
        // the size and closing are that window's.
        let win = match CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("PolterRoles"),
            PCWSTR::null(),
            WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
            0,
            0,
            10,
            10,
            Some(host),
            None,
            Some(hi),
            None,
        ) {
            Ok(h) => h,
            Err(e) => {
                // process-wide: the role library, one per process
                crate::plogf!("[roles-ui] CreateWindowExW failed: {e:?}");
                return false;
            }
        };
        MAIN.store(win.0, Ordering::Release);
        make_fonts(dpi_of(win));
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
        theme::system().dress_scrollbars(pane);

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
            // + ⧉ −, as the macOS list has them (settings.md §2.3a). Square,
            // one control tall, so they fit the band with the status text
            // beside them.
            list_buttons: [mk(ID_NEW, "+".into(), false), mk(ID_DUP, "\u{29c9}".into(), false), mk(ID_DEL, "\u{2212}".into(), false)],
            tabs: [mk(ID_TAB0, String::new(), true), mk(ID_TAB0 + 1, String::new(), true), mk(ID_TAB0 + 2, String::new(), true)],
            restore: mk(ID_RESTORE, tr("Restore Factory Settings…"), false),
            footer: [mk(ID_LAUNCH, tr("Launch"), false), mk(ID_REVERT, tr("Discard Changes"), false), mk(ID_SAVE, tr("Save"), false)],
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
        has_draft: bool,
        has_page: bool,
        launch_label: String,
    }
    let plan = ST.with(|c| {
        let s = c.borrow();
        let ed = &s.model.ed;
        let v = View {
            ed,
            cat: &s.cat,
            skills: &s.skills,
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
            buttons: buttons(ed, &s.cat, &s.skills, launchable),
            has_draft: ed.draft.is_some(),
            has_page: ed.draft.is_some() || ed.skill.is_some(),
            // More than one CLI opens a menu of them, and says so.
            launch_label: if many { format!("{} ▾", tr("Launch")) } else { tr("Launch") },
        }
    });

    let mut rc = RECT::default();
    let _ = unsafe { GetClientRect(win, &mut rc) };
    let hdc = unsafe { GetDC(Some(win)) };
    let fi = frame_inputs(hdc, rc.right, dpi);
    let frame = frame_layout(rc.right, rc.bottom, dpi, fi);
    unsafe {
        ReleaseDC(Some(win), hdc);
    }

    place_fixed(&frame, &plan.tab_labels, plan.tab, plan.buttons, &plan.launch_label, plan.has_draft, plan.has_page);
    let pr = frame.pane;
    unsafe {
        // ⚠️ **`SWP_FRAMECHANGED`, because this window has a scroll bar and a
        // scroll bar is not in the client area.** Invalidating the client
        // area -- which a resize, a repaint and every tab switch do -- never
        // reaches it, so after maximising, the bar stayed drawn down the
        // column where the window's right edge used to be, over the text
        // that now runs past it. It survived every redraw and went away on
        // restore, which is the shape of a non-client area nobody asked to
        // be recalculated.
        let _ = SetWindowPos(
            pane,
            None,
            pr.left,
            pr.top,
            pr.right - pr.left,
            pr.bottom - pr.top,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        );
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
        let _ = RedrawWindow(
            Some(pane),
            None,
            None,
            RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN,
        );
    }
    // The breadcrumb above names the role on screen.
    crate::settings_win::crumb_changed();
}

/// What the fixed parts are laid out around, measured with `hdc` -- the
/// one place that does it, so the refresh that moves the controls and the
/// paint that draws round them cannot disagree about the strip or the error
/// band (they used to work the band out once each).
fn frame_inputs(hdc: HDC, width: i32, dpi: i32) -> FrameInputs {
    let (error, official, tabs) = ST.with(|c| {
        let s = c.borrow();
        let ed = &s.model.ed;
        (s.cat.error.clone(), official_on_screen(ed, &s.skills).is_some(), ed.draft.is_some() && ed.skill.is_none())
    });
    let measure = measure_with(hdc);
    FrameInputs {
        error_h: error.map(|e| measure(&error_banner_text(&e), width - dpi * (LIST_W + PAD * 2) / 96, Font::Normal, false).1),
        footer_text_w: [tr("Launch"), tr("Discard Changes"), tr("Save"), tr("Restore Factory Settings…")].map(|t| measure(&t, width, Font::Normal, true).0),
        official,
        tabs,
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
fn place_fixed(frame: &Frame, tab_labels: &[String; 3], tab: Tab, b: Buttons, launch_label: &str, has_draft: bool, has_page: bool) {
    let Some(f) = FIXED.with(|c| c.get()) else { return };
    let put = |h: HWND, r: &RECT, show: bool, enabled: bool| unsafe {
        // Off the keyboard before it is hidden or greyed (task 1010).
        if !show {
            crate::settings_win::keep_keyboard_off(h);
        }
        let _ = SetWindowPos(h, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
        let _ = ShowWindow(h, if show { SW_SHOWNA } else { SW_HIDE });
        crate::settings_win::enable(h, enabled);
    };
    for (i, h) in f.list_buttons.iter().enumerate() {
        let enabled = [b.new, b.duplicate, b.delete][i];
        put(*h, &frame.list_buttons[i], true, enabled);
    }
    let empty = RECT::default();
    for (i, h) in f.tabs.iter().enumerate() {
        let r = frame.tabs.map(|t| t[i]).unwrap_or(empty);
        put(*h, &r, frame.tabs.is_some(), true);
        set_text_if_changed(*h, &tab_labels[i]);
        set_segment(*h, Tab::ALL[i] == tab);
    }
    put(f.restore, &frame.restore.unwrap_or(empty), frame.restore.is_some(), b.restore);
    let enabled = [b.launch, b.revert, b.save];
    // Launch is a role's; an official skill has Revert and Save only, as on
    // the macOS side.
    let shown = [has_draft, has_page, has_page];
    for (i, h) in f.footer.iter().enumerate() {
        put(*h, &frame.footer_buttons[i], shown[i], enabled[i]);
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
            if tag == Tag::Combo {
                fit_combo(h, r.bottom - r.top);
            }
            live.rect = r;
        }
        match &p.kind {
            Kind::Edit { text, cue, .. } => {
                // `\n` in the model, `\r\n` in the box: a multi-line box
                // draws a bare `\n` as no line end at all (task 1541).
                let same = polter_settings_shell::from_box(&get_text(h)) == *text;
                if text_needs_writing(h == focus, same, live.gen != gen) {
                    set_text(h, &polter_settings_shell::to_box(text));
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
                crate::settings_win::enable(h, want_enabled);
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
            theme::system().dress_scrollbars(h);
        }
        // **As much as the box can hold.** An edit control takes 32 767
        // characters typed unless told otherwise, and the supervising
        // skill alone is 63 KB: its whole text went in (setting it is not
        // limited), and then not one more character could be typed.
        if matches!(tag, Tag::Edit { multi: true, .. }) {
            SendMessageW(h, EM_SETLIMITTEXT, Some(WPARAM(0)), Some(LPARAM(0)));
        }
    }
    subclass(h);
    Some(Live { hwnd: h, id, tag, rect: RECT::default(), label: String::new(), options: Vec::new(), gen: u64::MAX })
}

/// Everything this module remembers about a window that no longer exists.
///
/// **The controls are not destroyed here**: they went with the window that
/// owned them. What is left is this side's memory of them, and every part of
/// it is now a handle to nothing -- which is exactly the state that made a
/// destroyed window look like one that was already open.
fn forget_window() {
    MAIN.store(std::ptr::null_mut(), Ordering::Release);
    PANE.store(std::ptr::null_mut(), Ordering::Release);
    FIXED.with(|f| f.set(None));
    LIVE.with(|l| l.borrow_mut().clear());
    ST.with(|c| {
        let s = &mut *c.borrow_mut();
        forgotten(&mut s.model);
        s.laid = Laid::default();
        s.ids.clear();
        s.scroll = 0;
        s.list_top = 0;
        s.drag = None;
        s.poll_until = None;
        s.launchable = None;
        s.prev_focus = HWND(std::ptr::null_mut());
        s.owner = HWND(std::ptr::null_mut());
    });
    // process-wide: the role library window is one per process
    crate::plogf!("[roles-ui] the window is gone; the next opening makes a new one");
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
/// parent never sees. **Not the Escape forwarding `overlay.rs` had for the
/// old plugin page** (gone with that page), which kept the previous
/// procedure in `GWLP_USERDATA` and knew only Escape; this one keeps it in a
/// window property.
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
                // **Escape closes nothing** (settings.md §2.3): long text and
                // an input method both use it, and a window that vanished on
                // it took the draft's context with it. Swallowed so an edit
                // does not beep; an open drop-down still closes on it.
                if vk == VK_ESCAPE && SendMessageW(h, CB_GETDROPPEDSTATE, None, None).0 == 0 {
                    return LRESULT(0);
                }
                if crate::settings_win::is_close_key(vk.0) {
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
            WM_CHAR if wp.0 == 0x13 || wp.0 == 0x17 || wp.0 == 0x1B => return LRESULT(0),
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

/// `warning`: the question deletes or restores something, and wears the
/// warning sign, as the macOS alert's `.warning` (task 1550). The keyboard
/// goes back to the control that had it (#896 W35) -- the question box does
/// that for every caller.
fn ask(owner: HWND, main: &str, body: &str, first: &str, second: Option<&str>, warning: bool) -> Answer {
    ask_modal(owner, main, body, first, second, warning)
}

fn ask_modal(owner: HWND, main: &str, body: &str, first: &str, second: Option<&str>, warning: bool) -> Answer {
    // The settings window's one question box (`projects_ui::ask_with_default`,
    // task 1550): one title and one look for every question in the window.
    // Cancel is the last button, which Escape and the cross answer.
    let mut buttons = vec![first.to_string()];
    if let Some(s) = second {
        buttons.push(s.to_string());
    }
    buttons.push(tr("Cancel"));
    let pressed = crate::projects_ui::ask_with_default(owner, "[roles-ui]", main, body, &buttons, 0, warning);
    match pressed {
        Some(0) => Answer::First,
        Some(1) if second.is_some() => Answer::Second,
        _ => Answer::Cancel,
    }
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
        dialog_owner(),
        &tr("Save changes to this role?"),
        &tr("Your changes will be lost if you don't save them."),
        &tr("Save"),
        Some(&tr("Don't Save")), false,
    ) {
        Answer::First => save(),
        Answer::Second => true,
        Answer::Cancel => false,
    }
}

/// The settings window's question before leaving this section with a
/// dirty draft (settings.md §2.4), in the words this section already asks
/// it in.
pub fn ask_to_save() -> polter_settings_shell::Answer {
    match ask(
        dialog_owner(),
        &tr("Save changes to this role?"),
        &tr("Your changes will be lost if you don't save them."),
        &tr("Save"),
        Some(&tr("Don't Save")), false,
    ) {
        Answer::First => polter_settings_shell::Answer::Save,
        Answer::Second => polter_settings_shell::Answer::DontSave,
        Answer::Cancel => polter_settings_shell::Answer::Cancel,
    }
}

/// The same question for another section's item (§2.4: one protocol, one
/// dialog): `question` names what would be lost -- the plugins section asks
/// "Save changes to this plugin?". `owner` is the settings window: the
/// role library's own window may never have been made.
pub fn ask_to_save_this(owner: HWND, question: &str) -> polter_settings_shell::Answer {
    match ask(owner, question, &tr("Your changes will be lost if you don't save them."), &tr("Save"), Some(&tr("Don't Save")), false) {
        Answer::First => polter_settings_shell::Answer::Save,
        Answer::Second => polter_settings_shell::Answer::DontSave,
        Answer::Cancel => polter_settings_shell::Answer::Cancel,
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

/// Put an official skill on screen, asking first about unsaved changes.
fn select_skill(name: &str) {
    if !ST.with(|c| selecting_skill_is_a_change(&c.borrow().model.ed, name)) {
        return;
    }
    if confirm_leaving() {
        with_model(|s| {
            s.model.ed.load_skill(&s.cat, &s.skills, name);
            s.scroll = 0;
            draft_replaced(s);
        });
    }
    refresh();
}

/// A list row was picked: a role or a skill. The heading is nothing.
fn pick(entry: &Entry) {
    match entry {
        Entry::Role(Some(key)) => select(key),
        Entry::Skill(name) => select_skill(name),
        Entry::Role(None) | Entry::Heading => {}
    }
}

/// ↑ / ↓ in the list: the next or previous role or skill in the list as
/// shown, over the skills' heading, stopping at the ends, through `pick`
/// (which asks about unsaved changes first), then scrolled so it is on
/// screen.
fn step_list(down: bool) {
    let win = main_hwnd();
    let (rows, list_top) = ST.with(|c| {
        let s = c.borrow();
        (shown_rows(&s), s.list_top)
    });
    let current = rows.iter().position(|r| r.selected);
    let entries: Vec<Entry> = rows.iter().map(|r| r.entry.clone()).collect();
    let Some(next) = shipped::step(&entries, current, down) else { return };
    let target = entries[next].clone();
    pick(&target);
    // Only when the move happened: a Cancel leaves the selection, and the
    // list where it was.
    let moved = ST.with(|c| {
        let ed = &c.borrow().model.ed;
        match &target {
            Entry::Role(Some(k)) => ed.skill.is_none() && ed.selection.as_deref() == Some(k.as_str()),
            Entry::Skill(n) => ed.skill.as_deref() == Some(n.as_str()),
            _ => false,
        }
    });
    if moved {
        let mut rc = RECT::default();
        let _ = unsafe { GetClientRect(win, &mut rc) };
        let dpi = dpi_of(win);
        let fit = role_rows_fitting(dpi, frame_layout(rc.right, rc.bottom, dpi, FrameInputs::default()).list.bottom);
        ST.with(|c| {
            let s = &mut *c.borrow_mut();
            s.list_top = polter_settings_shell::keep_visible(list_top, next, fit);
        });
        let _ = unsafe { InvalidateRect(Some(win), None, false) };
    }
}

/// Save the draft. True when it was saved or there was nothing to save.
fn save() -> bool {
    if let Some((name, text)) = ST.with(|c| {
        let ed = &c.borrow().model.ed;
        ed.skill.clone().map(|n| (n, ed.skill_text.clone()))
    }) {
        return save_skill(&name, &text);
    }
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

fn save_skill(name: &str, text: &str) -> bool {
    let result = roles::skill_put(name, text);
    let skills = roles::skills();
    // process-wide: the role library is app-scoped, not any one window's
    crate::plogf!("[roles-ui] save skill {} -> {}", name, if result.is_ok() { "ok" } else { "refused" });
    let ok = result.is_ok();
    with_model(|s| {
        s.skills = skills;
        match result {
            Ok(()) => s.model.ed.load_skill(&s.cat, &s.skills, name),
            Err(why) => s.model.ed.status = Some(why),
        }
        draft_replaced(s);
    });
    refresh();
    ok
}

/// Read the library and the skills again after the core changed them, and
/// tell the editor.
fn reread(s: &mut State) {
    s.cat = roles::catalog();
    s.skills = roles::skills();
}

/// "Restore Factory Settings…" for the official role or skill on screen,
/// asked first; and when the file of changes cannot be read at all, asked a
/// second time, because then it is every official role and skill that goes
/// back (`ghostty_app_persona_restore`'s `everything`).
fn restore() {
    let (skill, role) = ST.with(|c| {
        let ed = &c.borrow().model.ed;
        (ed.skill.clone(), ed.original.clone().filter(|r| r.builtin && !ed.is_new && ed.skill.is_none()))
    });
    let name = match (&skill, &role) {
        (Some(n), _) => n.clone(),
        (None, Some(r)) => r.name.clone(),
        (None, None) => return,
    };
    let first = ask(
        dialog_owner(),
        &tr("Restore \"{}\" to factory settings?").replace("{}", &name),
        &tr("Your changes to it are removed, along with anything typed here and not saved. This can't be undone."),
        &tr("Restore"),
        None, true,
    );
    if first != Answer::First {
        return;
    }
    let result = match (&skill, &role) {
        (Some(n), _) => roles::skill_restore(n),
        (None, Some(r)) => {
            let mut code = roles::restore(&r.key, false);
            if code.as_ref().err().map(String::as_str) == Some("OverridesUnreadable") {
                // One role cannot be taken out of a file nobody can read.
                // The core sets the whole file aside, and only when told to
                // -- so the person is told what that costs first.
                let all = ask(
                    dialog_owner(),
                    &tr("The file that holds your changes can't be read."),
                    &tr("Restoring will put every official role and skill back to factory settings, not only this one. The file of your changes and your own copies of official skills are kept where they were, renamed, so nothing in them is lost."),
                    &tr("Restore All"),
                    None, true);
                if all != Answer::First {
                    return;
                }
                code = roles::restore(&r.key, true);
            }
            code.map_err(|c| roles::message(&c))
        }
        (None, None) => return,
    };
    // process-wide: the role library is app-scoped, not any one window's
    crate::plogf!("[roles-ui] restore {} -> {}", name, if result.is_ok() { "ok" } else { "refused" });
    with_model(|s| {
        reread(s);
        match &skill {
            Some(n) => s.model.ed.load_skill(&s.cat, &s.skills, n),
            None => {
                let key = role.as_ref().map(|r| r.key.clone());
                s.model.ed.load(&s.cat, key.as_deref());
            }
        }
        s.model.ed.status = result.err();
        draft_replaced(s);
    });
    refresh();
}

/// "Keep Mine": the notice that the official version moved goes, and what
/// was changed here stays -- including anything typed and not saved.
fn keep_mine() {
    let (skill, key, was_dirty) = ST.with(|c| {
        let ed = &c.borrow().model.ed;
        (ed.skill.clone(), ed.original.as_ref().map(|o| o.key.clone()), ed.is_dirty())
    });
    let result = match (&skill, &key) {
        (Some(n), _) => roles::skill_acknowledge(n),
        (None, Some(k)) => roles::acknowledge(k),
        (None, None) => return,
    };
    // process-wide: the role library is app-scoped, not any one window's
    crate::plogf!("[roles-ui] keep mine -> {}", if result.is_ok() { "ok" } else { "refused" });
    with_model(|s| {
        reread(s);
        // The text or the draft is the person's either way; only what
        // "saved" means is refreshed under it.
        s.model.ed.library_changed(&s.cat, &s.skills);
        if !was_dirty && skill.is_none() {
            s.model.ed.load(&s.cat, key.as_deref());
        }
        s.model.ed.status = result.err();
        draft_replaced(s);
    });
    refresh();
}

/// "Keep It Under a New Key" for a role of the person's an official one has
/// taken the key of.
fn adopt(key: &str) {
    let result = roles::adopt(key);
    // process-wide: the role library is app-scoped, not any one window's
    crate::plogf!("[roles-ui] adopt {} -> {}", key, if result.is_ok() { "ok" } else { "refused" });
    with_model(|s| {
        reread(s);
        s.model.ed.library_changed(&s.cat, &s.skills);
        s.model.ed.status = result.err();
        draft_replaced(s);
    });
    refresh();
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
        dialog_owner(),
        &tr("Delete the role \"{}\"?").replace("{}", &role.name),
        &tr("Terminals wearing it are taken out of it. Agents already running keep running."),
        &tr("Delete"),
        None, true,
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
    if after.keep_mine {
        keep_mine();
        return;
    }
    if let Some(key) = after.adopt {
        adopt(&key);
        return;
    }
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
        // Back to `\n`, the way the model and the files keep it.
        EN_CHANGE => Action::Text(key, polter_settings_shell::from_box(&get_text(h))),
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
    let no_match = filter_state().no_match_row;
    let (list, empty, error, has_page, list_top, ed) = ST.with(|c| {
        let s = c.borrow();
        let ed = &s.model.ed;
        (
            shown_rows(&s),
            list_empty_note(ed, &s.cat),
            s.cat.error.clone(),
            ed.draft.is_some() || ed.skill.is_some(),
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
        let frame = frame_layout(rc.right, rc.bottom, dpi, frame_inputs(hdc, rc.right, dpi));

        fill(hdc, &rc, theme::bg());
        fill(hdc, &frame.list, theme::panel());

        // The list.
        let limit = frame.list.bottom;
        for (i, row) in list.iter().enumerate() {
            let Some(r) = role_row_rect_at(dpi, list_top, i) else { continue };
            if r.bottom > limit {
                break;
            }
            // The official skills' heading: small and dim, on the row's
            // lower half, so it sits over the skills rather than under the
            // last role.
            if row.entry == Entry::Heading {
                let t = RECT { left: frame.text_left, top: r.top, right: r.right - s(PAD), bottom: r.bottom - s(4) };
                draw_text(hdc, &row.title, &t, Font::Small, theme::dim(), DT_LEFT | DT_SINGLELINE | DT_BOTTOM | DT_END_ELLIPSIS);
                continue;
            }
            let (fg, dim) = if row.selected {
                theme::fill_round(hdc, &RECT { left: s(6), right: r.right - s(6), ..r }, s(polter_settings_shell::grid::SECTION_ROW_RADIUS), theme::sel());
                (theme::sel_text(), theme::sel_text())
            } else {
                (theme::text(), theme::dim())
            };
            let x = frame.text_left;
            let right = r.right - s(PAD);
            // The marks go after the name, so the name is measured first and
            // cut short enough to leave them room.
            // The mark on an official role is the word, in a thin frame: a
            // lock said "cannot be changed", which is not what official
            // means (the core keeps a person's changes to one, #1504).
            let official = tr("Official");
            let badge_w = if row.builtin { measure(&official, right - x, Font::Small, true).0 + s(10) } else { 0 };
            // One gap, 6, between the name and the mark and between the mark
            // and the dot -- the macOS `OfficialMark.gap` (task 1514).
            let marks = if row.builtin { badge_w + s(MARK_GAP) } else { 0 } + (s(MARK_GAP) + s(6)) * i32::from(row.dot);
            let (tw, _) = measure(&row.title, right - x - marks, Font::Normal, true);
            // A row with nothing under its name has the name in its middle.
            let title = if row.subtitle.is_empty() {
                let mid = (r.top + r.bottom) / 2;
                RECT { left: x, top: mid - s(10), right: x + tw, bottom: mid + s(10) }
            } else {
                RECT { left: x, top: r.top + s(4), right: x + tw, bottom: r.top + s(24) }
            };
            draw_text(hdc, &row.title, &title, Font::Normal, fg, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            let mut mx = title.right + s(MARK_GAP);
            if row.builtin {
                let badge = RECT { left: mx, top: title.top + s(1), right: mx + badge_w, bottom: title.bottom - s(1) };
                frame_rect(hdc, &badge, theme::border());
                draw_text(hdc, &official, &badge, Font::Small, dim, DT_CENTER | DT_SINGLELINE | DT_VCENTER);
                mx = badge.right + s(MARK_GAP);
            }
            if row.dot {
                draw_dot(hdc, mx + s(3), (title.top + title.bottom) / 2, s(3), theme::focus());
            }
            let sub = RECT { left: x, top: r.top + s(23), right, bottom: r.bottom - s(3) };
            draw_text(hdc, &row.subtitle, &sub, Font::Small, dim, DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
        // §2.3a: a search that leaves nothing says so, rather than leave the
        // list blank beside an editor that still shows the selected role.
        if empty.is_none() && no_match {
            let r = role_row_rect_at(dpi, 0, 0).unwrap_or_default();
            let t = RECT { left: frame.text_left, right: r.right - s(PAD), ..r };
            draw_text(hdc, &tr("No matching roles"), &t, Font::Normal, theme::dim(), DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        }
        if let Some((head, body)) = empty {
            let r = RECT { left: s(PAD), top: s(PAD * 2), right: s(LIST_W - PAD), bottom: s(PAD * 2 + BTN_H) };
            draw_text(hdc, &head, &r, Font::Bold, theme::dim(), DT_CENTER | DT_SINGLELINE);
            let r = RECT { left: s(PAD), top: s(PAD * 2 + BTN_H + ROW_GAP), right: s(LIST_W - PAD), bottom: limit };
            draw_text(hdc, &body, &r, Font::Small, theme::dim(), DT_CENTER | DT_WORDBREAK);
        }

        if let (Some(r), Some(e)) = (frame.error, error.as_ref()) {
            let inner = RECT { left: r.left + s(PAD), top: r.top + s(8), right: r.right - s(PAD), bottom: r.bottom - s(8) };
            draw_text(hdc, &error_banner_text(e), &inner, Font::Normal, theme::warn(), DT_LEFT | DT_WORDBREAK);
            fill(hdc, &RECT { top: r.bottom - 1, ..r }, theme::border());
        }
        // The bottom band is always there (settings.md §2.3a), with its text
        // only when a role is open.
        if let Some((t, is_error)) = footer.filter(|_| has_page) {
            let colour = if is_error { theme::warn() } else { theme::dim() };
            draw_text(hdc, &t, &frame.status, Font::Normal, colour, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
        if frame.tabs.is_some() {
            let y = frame.pane.top - 1;
            fill(hdc, &RECT { left: frame.pane.left, top: y, right: rc.right, bottom: y + 1 }, theme::border());
        }
        // The lines last, so nothing paints over a crossing: the list's
        // divider from the top rule to the bottom rule, and the bottom rule
        // itself on the window's row.
        fill(hdc, &frame.list_divider, theme::border());
        fill(hdc, &frame.bottom_rule, theme::border());
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
            // Scaled with the DPI (#896 D2: a fixed 12..16 stayed 16 pixels
            // at 250%), and never taller than the control.
            let dpi = dpi_of(h);
            let side = polter_settings_shell::check_box(dpi, rc.bottom - rc.top);
            let top = rc.top + ((rc.bottom - rc.top) - side) / 2;
            let b = RECT { left: rc.left, top, right: rc.left + side, bottom: top + side };
            fill(hdc, &b, if hot && !disabled { theme::btn_hot() } else { theme::field_bg() });
            frame_rect(hdc, &b, if focus { theme::focus() } else { theme::border() });
            if SendMessageW(h, BM_GETCHECK, Some(WPARAM(0)), Some(LPARAM(0))).0 == 1 {
                let pen = CreatePen(PS_SOLID, (2 * dpi / 96).max(2), COLORREF(fg));
                let old = SelectObject(hdc, pen.into());
                let mut pt = POINT::default();
                let _ = MoveToEx(hdc, b.left + side / 5, b.top + side / 2, Some(&mut pt));
                let _ = LineTo(hdc, b.left + side * 2 / 5, b.bottom - side / 4);
                let _ = LineTo(hdc, b.right - side / 5, b.top + side / 4);
                SelectObject(hdc, old);
                let _ = DeleteObject(pen.into());
            }
            let t = RECT { left: b.right + grid::CHECK_GAP * dpi / 96, ..rc };
            draw_text(hdc, &label, &t, Font::Normal, fg, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            return;
        }

        if is_link {
            fill(hdc, &rc, theme::bg());
            let colour = if disabled { theme::dim() } else if hot { theme::text() } else { theme::link() };
            draw_text(hdc, &label, &rc, Font::Normal, colour, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            if focus {
                frame_rect(hdc, &rc, theme::focus());
            }
            return;
        }

        let selected = seg == 2;
        // The button Return presses wears the accent, as on both systems
        // (task 1550); greyed, it is a button like the others.
        let accent = (kind == BS_DEFPUSHBUTTON && !disabled && seg == 0).then(|| theme::system().default_button()).flatten();
        if let Some((face, text)) = accent {
            fill(hdc, &rc, face);
            if focus {
                frame_rect(hdc, &RECT { left: rc.left + 3, top: rc.top + 3, right: rc.right - 3, bottom: rc.bottom - 3 }, text);
            }
            if down {
                rc.top += 1;
                rc.left += 1;
            }
            draw_text(hdc, &label, &rc, Font::Normal, text, DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            return;
        }
        // The page tab that is showing wears the accent, as the macOS
        // segmented control's selected segment does (task 1604; it was the
        // list's grey selection). Under high contrast there is no accent
        // and it keeps the system's selection colours.
        let seg_accent = (selected && !disabled).then(|| theme::system().default_button()).flatten();
        let face = if let Some((face, _)) = seg_accent {
            face
        } else if selected {
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
        let fg = if let Some((_, text)) = seg_accent {
            text
        } else if selected {
            theme::sel_text()
        } else {
            fg
        };
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

/// Make a drop-down's closed box `want` pixels tall, as the row it sits in
/// is. **Every drop-down in the settings window is placed through this**
/// (the General form, a plugin's form, the role editor): where it is put
/// does not decide how tall it is -- see `combo_field_height` for why, and
/// for the 26 px it stood at beside 28 px controls.
///
/// Called after each placement, not once at creation: the field's height is
/// in pixels, so a window moved to a screen of another DPI needs it again.
pub(crate) fn fit_combo(h: HWND, want: i32) {
    if h.0.is_null() {
        return;
    }
    unsafe {
        let mut wr = RECT::default();
        if GetWindowRect(h, &mut wr).is_err() {
            return;
        }
        // The selection field is item -1; CB_ERR is -1 too, and is refused
        // by the rule as "cannot be told".
        let field = SendMessageW(h, CB_GETITEMHEIGHT, Some(WPARAM(usize::MAX)), None).0 as i32;
        let closed = wr.bottom - wr.top;
        if let Some(fitted) = polter_settings_shell::combo_field_height(closed, field, want) {
            SendMessageW(h, CB_SETITEMHEIGHT, Some(WPARAM(usize::MAX)), Some(LPARAM(fitted as isize)));
            let mut now = RECT::default();
            let _ = GetWindowRect(h, &mut now);
            // process-wide: every drop-down fitted is in the one settings window
            crate::plogf!(
                "[settings] drop-down fitted: closed {} -> {} px (wanted {}), field {} -> {} px",
                closed,
                now.bottom - now.top,
                want,
                field,
                fitted
            );
        }
    }
}

/// A window's class name, for telling which control sent a notification.
fn class_of(h: HWND) -> String {
    let mut buf = [0u16; 64];
    let n = unsafe { GetClassNameW(h, &mut buf) }.max(0) as usize;
    String::from_utf16_lossy(&buf[..n])
}

/// The messages both procedures answer the same way: colours, custom draw,
/// the owner-drawn combo.
/// The messages every window holding these controls answers the same way --
/// colours, the custom-drawn buttons, the owner-drawn combo. `pub(crate)`
/// because the settings window around this one holds a button too.
pub(crate) unsafe fn common(win: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
    unsafe {
        match msg {
            WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC | WM_CTLCOLORLISTBOX | WM_CTLCOLORBTN => {
                theme::ctl_color(HDC(wp.0 as *mut c_void)).map(|b| LRESULT(b.0 as isize))
            }
            WM_NOTIFY => {
                let nm = &*(lp.0 as *const NMHDR);
                // Buttons only: a tooltip or a trackbar sends the same
                // notification and is the system's to draw (#1591 R4).
                if nm.code == NM_CUSTOMDRAW && theme::custom_drawing() && polter_settings_shell::custom_draws(&class_of(nm.hwndFrom)) {
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
                    ID_DUP => duplicate(),
                    ID_RESTORE => restore(),
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
            WM_ROLES_CLOSE => {
                request_close(win);
                LRESULT(0)
            }
            WM_ROLES_SAVE => {
                save();
                LRESULT(0)
            }
            WM_KEYDOWN => {
                let vk = VIRTUAL_KEY(wp.0 as u16);
                if crate::settings_win::is_close_key(vk.0) {
                    request_close(win);
                } else if vk.0 == u16::from(b'S') && held(VK_CONTROL) {
                    save();
                } else if (vk == VK_UP || vk == VK_DOWN) && GetFocus() == win {
                    // Only while the list has the keyboard (a click on it
                    // gives it); the pane forwards its keys here too, and an
                    // arrow in the pane is not a request for another role.
                    step_list(vk == VK_DOWN);
                }
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let (x, y) = lparam_xy(lp);
                let dpi = dpi_of(win);
                let mut rc = RECT::default();
                let _ = GetClientRect(win, &mut rc);
                let list = frame_layout(rc.right, rc.bottom, dpi, FrameInputs::default()).list;
                if x < list.right && y < list.bottom {
                    // The keyboard comes to the list, so ↑ / ↓ go on from
                    // here (settings.md §2.3a).
                    let _ = SetFocus(Some(win));
                    let limit = list.bottom;
                    let hit = ST.with(|c| {
                        let s = c.borrow();
                        let list = shown_rows(&s);
                        role_row_at_y(dpi, s.list_top, list.len(), y, limit).map(|i| list[i].entry.clone())
                    });
                    if let Some(entry) = hit {
                        pick(&entry);
                    }
                }
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                let delta = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
                let mut pt = POINT { x: (lp.0 & 0xFFFF) as i16 as i32, y: ((lp.0 >> 16) & 0xFFFF) as i16 as i32 };
                let _ = ScreenToClient(win, &mut pt);
                let dpi = dpi_of(win);
                let mut rc = RECT::default();
                let _ = GetClientRect(win, &mut rc);
                let list = frame_layout(rc.right, rc.bottom, dpi, FrameInputs::default()).list;
                if pt.x < list.right {
                    let fit = role_rows_fitting(dpi, list.bottom);
                    ST.with(|c| {
                        let s = &mut *c.borrow_mut();
                        let n = shown_rows(s).len();
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
                // `RDW_FRAME` as well: a child's scroll bar lives outside its
                // client area, and this is the message after which one of
                // them was left drawn at the old width.
                let _ = RedrawWindow(
                    Some(win),
                    None,
                    None,
                    RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN | RDW_UPDATENOW,
                );
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
            // Destroyed with the settings window, should that ever be
            // destroyed rather than hidden. See `forget_window`.
            WM_NCDESTROY => {
                forget_window();
                DefWindowProcW(win, msg, wp, lp)
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
        Catalog { loaded: true, roles: keys.iter().map(|k| role(k)).collect(), ..Catalog::default() }
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
    fn an_official_role_locks_its_name_description_and_standing_and_nothing_else() {
        let mut c = cat(&["polter-supervisor"]);
        c.roles[0].builtin = true;
        let mut ed = Editor::default();
        ed.load(&c, Some("polter-supervisor"));
        let e = editable(&ed);
        assert!(!e.name && !e.summary && !e.standing && !e.key, "{e:?}");
        assert!(e.instructions && e.open && e.watch && e.quiet && e.clis && e.start && e.items, "{e:?}");
        // The floor: the same role, not built in, has the three back.
        c.roles[0].builtin = false;
        ed.load(&c, Some("polter-supervisor"));
        let e = editable(&ed);
        assert!(e.name && e.summary && e.standing && e.open, "{e:?}");
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
        assert!(buttons(&ed, &c, &SkillCatalog::default(), true).launch);
        assert!(!buttons(&ed, &c, &SkillCatalog::default(), false).launch, "no terminal to open the tab beside");
        ed.draft.as_mut().unwrap().summary = "changed".into();
        assert!(!buttons(&ed, &c, &SkillCatalog::default(), true).launch, "a dirty draft is not what the core would launch");
        // No CLI, and saved that way.
        c.roles[0].clis.clear();
        ed.load(&c, Some("r"));
        assert!(!ed.is_dirty());
        assert!(!buttons(&ed, &c, &SkillCatalog::default(), true).launch, "no CLI");
    }

    #[test]
    fn save_and_revert_need_a_change_and_delete_needs_a_role_of_ones_own() {
        let mut c = cat(&["r", "polter-supervisor"]);
        c.roles[1].builtin = true;
        let mut ed = editing(&mut c);
        let b = buttons(&ed, &c, &SkillCatalog::default(), true);
        assert!(!b.save && !b.revert && b.delete && b.duplicate && b.new);
        ed.draft.as_mut().unwrap().name = "x".into();
        let b = buttons(&ed, &c, &SkillCatalog::default(), true);
        assert!(b.save && b.revert);
        // A library file that does not parse: nothing is saved over it.
        let mut broken = c.clone();
        broken.error = Some("line 3".into());
        let b = buttons(&ed, &broken, &SkillCatalog::default(), true);
        assert!(!b.save && !b.new && !b.delete && !b.duplicate && b.revert);
        ed.load(&c, Some("polter-supervisor"));
        assert!(!buttons(&ed, &c, &SkillCatalog::default(), true).delete, "a built-in role cannot be deleted");
        assert!(buttons(&ed, &c, &SkillCatalog::default(), true).duplicate, "but it can be copied");
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
    fn an_official_role_ignores_edits_to_what_it_locks_and_takes_the_rest() {
        let mut c = cat(&["polter-supervisor"]);
        c.roles[0].builtin = true;
        c.roles[0].clis = vec![CliChoice::new("claude")];
        let mut m = Model::default();
        m.ed.load(&c, Some("polter-supervisor"));
        let before = m.ed.clone();
        let clis = snapshot();
        for a in [
            Action::Text("name".into(), "x".into()),
            Action::Text("summary".into(), "x".into()),
            Action::Check("sup".into(), true),
            Action::Check("auth".into(), true),
            Action::Check("shield".into(), true),
        ] {
            apply(&mut m, &c, &clis, a);
        }
        assert_eq!(m.ed.draft, before.draft, "the locked parts did not move");
        assert!(!m.ed.is_dirty());
        apply(&mut m, &c, &clis, Action::Text("instr".into(), "mine".into()));
        apply(&mut m, &c, &clis, Action::Choose("open".into(), 1));
        let d = m.ed.draft.as_ref().unwrap();
        assert_eq!(d.instructions, "mine");
        assert_eq!(d.polter.open, Open::Tab, "\"open in\" is not one of the three");
        assert!(m.ed.is_dirty());
        // And it is saved, not passed over: `Ok(None)` here was "saved" with
        // nothing saved.
        assert_eq!(m.ed.save_request(&c).unwrap().map(|r| r.instructions), Some("mine".to_string()));
    }

    // ------------------------------------------------------------- list

    #[test]
    fn the_list_marks_builtin_roles_and_unsaved_ones() {
        let mut c = cat(&["r", "polter-supervisor"]);
        c.roles[1].builtin = true;
        let mut ed = editing(&mut c);
        let rows = list_rows(&ed, &c, &SkillCatalog::default(), &snapshot());
        assert!(!rows[0].builtin && rows[1].builtin);
        assert!(rows.iter().all(|r| !r.dot));
        assert!(rows[0].selected && !rows[1].selected);
        assert_eq!(rows[0].subtitle, "Claude Code");
        assert_eq!(rows[1].subtitle, "No agent CLI");

        ed.draft.as_mut().unwrap().summary = "x".into();
        let rows = list_rows(&ed, &c, &SkillCatalog::default(), &snapshot());
        assert!(rows[0].dot && !rows[1].dot);

        ed.new_role(&c, &snapshot());
        let rows = list_rows(&ed, &c, &SkillCatalog::default(), &snapshot());
        assert_eq!(rows.len(), 3);
        assert!(rows[0].dot && rows[0].key().is_none() && rows[0].selected);
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
        let v = View { ed: &ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &snapshot(), instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        assert_eq!(keys(&rows(&v)), vec!["gobasics".to_string()]);
    }

    #[test]
    fn two_clis_put_a_switcher_on_the_tab_and_one_does_not() {
        let mut c = cat(&["r"]);
        let mut ed = editing(&mut c);
        ed.tab = Tab::Skills;
        let empty = HashSet::new();
        let clis = snapshot();
        let v = View { ed: &ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        assert!(!keys(&rows(&v)).iter().any(|k| k.starts_with("seg:")));
        ed.set_cli("codex", true);
        let v = View { ed: &ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
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
            let v = View { ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
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
        let v = View { ed: &ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &clis, instr_h: 240, search: "", collapsed: &collapsed, expanded: &empty };
        let k = keys(&rows(&v));
        assert!(k.contains(&"gtoggle:user".to_string()));
        assert!(!k.contains(&"item:skill:a".to_string()));
        assert!(k.contains(&"item:skill:c".to_string()), "the other group is open");
        let v = View { ed: &ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        assert!(keys(&rows(&v)).contains(&"item:skill:a".to_string()));
    }

    // ----------------------------------------------------------- layout

    fn basics_laid(dpi: i32, width: i32) -> Laid {
        let mut c = cat(&["r"]);
        let ed = editing(&mut c);
        let empty = HashSet::new();
        let clis = snapshot();
        let v = View { ed: &ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
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
            let v = View { ed: &ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &clis, instr_h: h, search: "", collapsed: &empty, expanded: &empty };
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
        let pick = tr("Pick an agent CLI under Basics to launch this role.");
        let clean = footer_note(&ed, true);
        if ed.draft.as_ref().unwrap().clis.is_empty() {
            assert_eq!(clean.map(|x| x.0), Some(pick.clone()));
        } else {
            assert_eq!(clean, None);
        }
        let (no_terminal, is_error) = footer_note(&ed, false).unwrap();
        assert!(!is_error);
        assert_eq!(no_terminal, tr("Open a terminal window first; the new tab goes beside it."));
        // The macOS order (task 1604): no terminal first, then "save it
        // first", then no CLI; an error beats them all.
        ed.draft.as_mut().unwrap().name = "x".into();
        assert_eq!(footer_note(&ed, false).unwrap().0, tr("Open a terminal window first; the new tab goes beside it."));
        assert_eq!(footer_note(&ed, true).unwrap().0, tr("Save the role before launching it."));
        ed.draft.as_mut().unwrap().clis.clear();
        assert_eq!(footer_note(&ed, true).unwrap().0, tr("Save the role before launching it."));
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
        let f = frame_layout(W0, H0, 96, FrameInputs { tabs: true, ..FrameInputs::default() });
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
            let f = frame_layout(w, h, dpi, FrameInputs { tabs: true, ..FrameInputs::default() });
            let tabs = f.tabs.unwrap();
            assert!(tabs[0].bottom <= f.pane.top && f.pane.bottom <= f.bottom_rule.top);
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

    /// ⚠️ **The close that handed the keyboard back to itself.** All three
    /// of "nothing had it", "this window had it" and "what had it is gone"
    /// answer the same way, and it is never this window.
    #[test]
    fn hiding_hands_the_keyboard_to_something_a_person_can_type_into() {
        // ⚠️ **Three different numbers.** With the terminal and the owner
        // written as one, an implementation that ignored `usable` passed
        // this test -- measured, not supposed: the mutation that drops the
        // check went green here until they were told apart.
        let (terminal, owner, this_window, none) = (0x1234, 0xabcd, 0x6101ee, 0);
        assert_eq!(handback_to(terminal, true, owner), terminal);
        // What had it was this window, or a window that has since gone.
        assert_eq!(handback_to(this_window, false, owner), owner);
        // Nothing had it.
        assert_eq!(handback_to(none, true, owner), owner);
        assert_eq!(handback_to(none, false, owner), owner);
        // And with no terminal either, there is nothing to invent.
        assert_eq!(handback_to(none, false, none), none);
    }

    /// A window that is gone leaves nothing behind that names it: the next
    /// opening starts from the library, as it does after a close.
    #[test]
    fn a_destroyed_window_is_forgotten_down_to_the_draft() {
        let mut c = cat(&["r", "s"]);
        let mut m = Model { ed: editing(&mut c), ..Model::default() };
        m.ed.draft.as_mut().unwrap().name = "half typed".into();
        m.search = "pdf".into();
        m.collapsed.insert("user".into());
        m.expanded.insert("skill:a".into());
        assert!(m.ed.is_dirty());
        forgotten(&mut m);
        assert!(m.ed.draft.is_none() && !m.ed.is_dirty() && !m.ed.is_new);
        assert!(m.search.is_empty() && m.collapsed.is_empty() && m.expanded.is_empty());
        // And the page it would draw is the one with no role open.
        let v = View { ed: &m.ed, cat: &Catalog::default(), skills: &SkillCatalog::default(), clis: &snapshot(), instr_h: 240, search: "", collapsed: &m.collapsed, expanded: &m.expanded };
        assert_eq!(keys(&rows(&v)), Vec::<String>::new());
        assert_eq!(buttons(&m.ed, &c, &SkillCatalog::default(), true), Buttons { new: true, ..Buttons::default() });
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
            // The English words, the widest, at about 13 px.
            let fi = FrameInputs { error_h: Some(40), footer_text_w: [45, 100, 30, 160].map(|v| v * dpi / 96), official: true, tabs: true };
            let f = frame_layout(w, h, dpi, fi);
            let tabs = f.tabs.unwrap();
            let restore = f.restore.unwrap();
            assert!(f.error.unwrap().bottom <= tabs[0].top);
            assert!(restore.top >= f.band.top && restore.bottom <= f.band.bottom, "Restore is in the band at {dpi}");
            assert!(restore.right <= f.footer_buttons[0].left && restore.left >= f.status.right);
            assert!(tabs[0].bottom <= f.pane.top);
            assert!(f.pane.bottom <= f.bottom_rule.top && f.bottom_rule.bottom <= f.band.top);
            assert!(f.pane.bottom - f.pane.top > 100 * dpi / 96, "a pane with room to edit in at {dpi}");
            let [launch, revert, save] = f.footer_buttons;
            assert!(launch.right <= revert.left && revert.right <= save.left && save.right <= w);
            assert!(f.status.right <= restore.left);
            assert!(f.list_buttons[2].right <= f.status.left);
            assert!(tabs[0].right <= tabs[1].left && tabs[2].right <= w);
        }
        // No role open: no tabs and no Restore, but the bottom band is still
        // there and the pane stops at its rule (settings.md §2.3a).
        let f = frame_layout(W0, H0, 96, FrameInputs::default());
        assert!(f.tabs.is_none() && f.restore.is_none());
        // An official skill: Restore in the band and no tabs; the pane
        // starts at the top, with no strip over it any more.
        let f = frame_layout(W0, H0, 96, FrameInputs { official: true, ..FrameInputs::default() });
        assert!(f.tabs.is_none() && f.restore.is_some());
        assert_eq!(f.pane.top, 0);
        assert_eq!(f.pane.bottom, f.bottom_rule.top);
        assert_eq!(f.band.bottom, H0);
    }

    /// §2.3a: this section's fixed parts are the settings window's grid --
    /// its bottom rule on the window's row, its list divider from the top
    /// rule to the bottom rule, + ⧉ − starting where the list's rows'
    /// text does, and the band's buttons in one row.
    #[test]
    fn the_section_sits_on_the_settings_windows_grid() {
        for dpi in [96, 120, 144, 192] {
            let (ww, wh) = (1164 * dpi / 96, 761 * dpi / 96);
            let l = polter_settings_shell::layout(ww, wh, dpi);
            let (w, h) = (l.content.width(), l.content.height());
            for has_draft in [true, false] {
                let fi = FrameInputs { error_h: Some(40), footer_text_w: [40, 90, 30, 100], official: has_draft, tabs: has_draft };
                let f = frame_layout(w, h, dpi, fi);
                assert_eq!(l.content.top + f.bottom_rule.top, l.bottom_rule.top, "at {dpi}");
                assert_eq!(l.content.top + f.list_divider.top, l.top_rule.bottom, "at {dpi}");
                assert_eq!(l.content.top + f.list_divider.bottom, l.bottom_rule.top, "at {dpi}");
                assert_eq!(f.list.bottom, f.bottom_rule.top, "at {dpi}");
                assert_eq!(f.list_buttons[0].left, PAD * dpi / 96, "at {dpi}");
                assert_eq!(f.text_left, f.list_buttons[0].left, "the rows' text starts where + does");
                assert_eq!(l.content.left + f.text_left, l.content_text_left, "and where the breadcrumb does");
                for b in f.list_buttons.iter().chain(f.footer_buttons.iter()) {
                    assert_eq!((b.top, b.bottom), (f.list_buttons[0].top, f.list_buttons[0].bottom), "at {dpi}");
                }
                assert!(f.pane.bottom <= f.bottom_rule.top, "at {dpi}");
            }
        }
    }

    /// §2.3a: the form has two left edges, the margin and the control
    /// column. Every field, check box, drop-down and the notes under them
    /// start on the control column; headings and the instructions box on
    /// the margin; nothing anywhere else.
    #[test]
    fn the_form_has_two_left_edges() {
        let dpi = 96;
        let laid = basics_laid(dpi, 700);
        let margin = PAD;
        let control = PAD + CONTROL_COL;
        // Headings on the margin.
        let headings: Vec<i32> =
            laid.cells.iter().filter(|p| matches!(&p.kind, Kind::Text { font: Font::Bold, .. })).map(|p| p.rect.left).collect();
        assert!(headings.len() >= 3 && headings.iter().all(|&x| x == margin), "{headings:?}");
        // Labels end where the control column's gap begins.
        for p in laid.cells.iter().filter(|p| matches!(&p.kind, Kind::Text { right: true, .. })) {
            assert_eq!((p.rect.left, p.rect.right), (margin, margin + LABEL_W), "{:?}", p.kind);
        }
        // The notes under the controls. (A small warning beside a check
        // box starts after it, right of the control column.)
        for p in laid.cells.iter().filter(|p| matches!(&p.kind, Kind::Text { font: Font::Small, .. }) && p.rect.left <= control) {
            assert!(p.rect.left == margin || p.rect.left == control, "{:?} at {}", p.kind, p.rect.left);
        }
        for key in ["sup", "auth", "shield", "watch", "quiet", "open", "cli:claude", "name", "summary"] {
            let p = laid.cells.iter().find(|p| p.key == key).unwrap_or_else(|| panic!("{key}"));
            assert_eq!(p.rect.left, control, "{key}");
        }
        let instr = laid.cells.iter().find(|p| p.key == "instr").unwrap();
        assert_eq!(instr.rect.left, margin);
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

    fn listed(key: Option<&str>, title: &str) -> ListRow {
        ListRow {
            entry: Entry::Role(key.map(str::to_string)),
            title: title.to_string(),
            subtitle: String::new(),
            builtin: false,
            dot: false,
            selected: false,
        }
    }

    /// The settings window's search narrows this list (settings.md §2.3) by
    /// the rule the jump to this section uses, so the jump never lands on a
    /// list that then hides every match.
    #[test]
    fn the_search_narrows_the_list_by_name_or_key_and_keeps_a_new_role() {
        let rows = vec![listed(None, "New Role"), listed(Some("reviewer"), "审查员"), listed(Some("dev"), "Developer")];
        let keys = |q: &str| filtered_rows(rows.clone(), q).into_iter().map(|r| r.key().map(str::to_string)).collect::<Vec<_>>();
        assert_eq!(keys("审查"), vec![None, Some("reviewer".to_string())]);
        assert_eq!(keys("REVIEW"), vec![None, Some("reviewer".to_string())]);
        assert_eq!(keys("devel"), vec![None, Some("dev".to_string())]);
        assert_eq!(keys("zzz"), vec![None]);
        assert_eq!(keys("").len(), 3);
    }

    // ------------------------------------------------- official (#1507)

    fn official(state: OfficialState) -> Official {
        Official { state, overridden: Vec::new(), stale: vec!["instructions".into(), "polter.open".into()], reason: Some("why".into()) }
    }

    fn shipped_skills() -> SkillCatalog {
        let skill = |name: &str, state| roles::OfficialSkill {
            name: name.into(),
            summary: format!("What {name} is for\nand more"),
            official: official(state),
            source: format!("---\nname: {name}\n---\n"),
        };
        SkillCatalog { error: None, skills: vec![skill("supervising", OfficialState::Modified), skill("reading", OfficialState::Pristine)] }
    }

    fn official_cat(state: OfficialState) -> Catalog {
        let mut c = cat(&["mine", "polter-supervisor"]);
        c.roles[1].builtin = true;
        c.roles[1].official = Some(official(state));
        c
    }

    #[test]
    fn the_official_skills_are_listed_under_their_heading_with_the_mark_and_the_dot() {
        let c = official_cat(OfficialState::Pristine);
        let k = shipped_skills();
        let mut ed = Editor::default();
        ed.load(&c, Some("mine"));
        let rows = list_rows(&ed, &c, &k, &snapshot());
        let entries: Vec<Entry> = rows.iter().map(|r| r.entry.clone()).collect();
        assert_eq!(
            entries,
            vec![
                Entry::Role(Some("mine".into())),
                Entry::Role(Some("polter-supervisor".into())),
                Entry::Heading,
                Entry::Skill("supervising".into()),
                Entry::Skill("reading".into()),
            ]
        );
        assert!(rows[3].builtin && rows[3].dot, "changed from factory settings");
        assert!(rows[4].builtin && !rows[4].dot);
        assert_eq!(rows[3].subtitle, "", "a skill's row is its name and the mark, as on macOS");
        assert!(!rows[1].dot, "a pristine official role has no dot");
        // A search that leaves no skill takes the heading with it.
        let kept: Vec<Entry> = filtered_rows(rows.clone(), "mine").into_iter().map(|r| r.entry).collect();
        assert_eq!(kept, vec![Entry::Role(Some("mine".into()))]);
        let kept: Vec<Entry> = filtered_rows(rows, "read").into_iter().map(|r| r.entry).collect();
        assert_eq!(kept, vec![Entry::Heading, Entry::Skill("reading".into())]);
        // No skills known: no heading.
        assert!(list_rows(&ed, &c, &SkillCatalog::default(), &snapshot()).iter().all(|r| r.entry != Entry::Heading));
    }

    #[test]
    fn a_skill_on_screen_is_its_text_and_is_dirty_only_when_that_differs() {
        let c = official_cat(OfficialState::Pristine);
        let k = shipped_skills();
        let mut m = Model::default();
        m.ed.load(&c, Some("mine"));
        assert!(selecting_skill_is_a_change(&m.ed, "supervising"));
        m.ed.load_skill(&c, &k, "supervising");
        assert!(m.ed.draft.is_none() && m.ed.selection.is_none());
        assert!(!m.ed.is_dirty() && !selecting_skill_is_a_change(&m.ed, "supervising"));
        assert!(selecting_is_a_change(&m.ed, "mine"), "a role is a change from a skill");
        apply(&mut m, &c, &snapshot(), Action::Text("skilltext".into(), "---\r\nname: supervising\r\n---\r\n".into()));
        assert!(!m.ed.is_dirty(), "a pasted CRLF copy of the same text is the same text");
        apply(&mut m, &c, &snapshot(), Action::Text("skilltext".into(), "changed".into()));
        assert!(m.ed.is_dirty() && leave_needs_asking(&m.ed));
        let b = buttons(&m.ed, &c, &k, true);
        assert!(b.save && b.revert && !b.launch && !b.delete && !b.duplicate, "{b:?}");
        assert!(b.restore, "the skill is changed from factory settings");
        assert_eq!(footer_note(&m.ed, false).map(|x| x.0), Some("Unsaved changes".to_string()));
        m.ed.revert(&c);
        assert_eq!(m.ed.skill_text, "---\nname: supervising\n---\n");
        assert!(!m.ed.is_dirty());
        // Launching is not this page's, so its reason is not said here.
        assert_eq!(footer_note(&m.ed, false), None);
        // Back to a role: the skill is gone from the editor.
        m.ed.load(&c, Some("mine"));
        assert!(m.ed.skill.is_none() && m.ed.skill_text.is_empty());
    }

    #[test]
    fn restore_is_there_for_an_official_thing_and_pressable_when_it_was_changed() {
        let k = shipped_skills();
        let mut ed = Editor::default();
        let c = official_cat(OfficialState::Pristine);
        ed.load(&c, Some("polter-supervisor"));
        assert!(official_on_screen(&ed, &k).is_some(), "the strip is there");
        assert!(!buttons(&ed, &c, &k, true).restore, "nothing to put back");
        for state in [OfficialState::Modified, OfficialState::ModifiedStale, OfficialState::Unknown] {
            let c = official_cat(state);
            ed.load(&c, Some("polter-supervisor"));
            assert!(buttons(&ed, &c, &k, true).restore, "{state:?}");
        }
        ed.load(&c, Some("mine"));
        assert!(official_on_screen(&ed, &k).is_none(), "a role of one's own has no strip");
        assert!(!buttons(&ed, &c, &k, true).restore);
        ed.duplicate(&c);
        assert!(official_on_screen(&ed, &k).is_none(), "nor does a copy of an official one");
        ed.load_skill(&c, &k, "reading");
        assert!(official_on_screen(&ed, &k).is_some() && !buttons(&ed, &c, &k, true).restore);
    }

    fn page(ed: &Editor, c: &Catalog, k: &SkillCatalog) -> Vec<Row> {
        let empty = HashSet::new();
        let clis = snapshot();
        let v = View { ed, cat: c, skills: k, clis: &clis, instr_h: 240, search: "", collapsed: &empty, expanded: &empty };
        rows(&v)
    }

    fn texts(rows: &[Row]) -> Vec<String> {
        rows.iter()
            .flat_map(|r| r.cells.iter())
            .filter_map(|c| match &c.kind {
                Kind::Text { text, .. } if !text.is_empty() => Some(text.clone()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn the_notices_say_what_moved_and_what_was_not_read_with_their_buttons() {
        let k = shipped_skills();
        let mut ed = Editor::default();
        let c = official_cat(OfficialState::ModifiedStale);
        ed.load(&c, Some("polter-supervisor"));
        let r = page(&ed, &c, &k);
        assert!(keys(&r).contains(&"keepmine".to_string()));
        let t = texts(&r);
        assert_eq!(t[0], "The official version has changed: Instructions, Polter");
        assert!(t[1].starts_with("The official version of what you changed here"));
        let c = official_cat(OfficialState::Unknown);
        ed.load(&c, Some("polter-supervisor"));
        let r = page(&ed, &c, &k);
        assert!(!keys(&r).contains(&"keepmine".to_string()));
        let t = texts(&r);
        assert_eq!(t[0], "Your changes weren't read, so the factory settings are in use.");
        assert_eq!(t[1], "why", "the reason under it");
        // The library's own: the file of changes, and a role an official
        // one has taken the key of -- shown whatever is on screen.
        let mut c = official_cat(OfficialState::Pristine);
        c.overrides_error = Some("Could not read x".into());
        c.shadowed = vec![("polter-worker".into(), "Mine".into())];
        ed.load(&c, Some("mine"));
        let r = page(&ed, &c, &k);
        assert!(keys(&r).contains(&"adopt:polter-worker".to_string()));
        let t = texts(&r);
        assert!(t[0].starts_with("Your changes to official roles couldn't be read"));
        assert_eq!(t[1], "Could not read x");
        assert!(t[2].starts_with("Your role \"Mine\" has the key polter-worker,"), "{}", t[2]);
        // And the buttons do what they say.
        let mut m = Model { ed: ed.clone(), ..Model::default() };
        assert_eq!(apply(&mut m, &c, &snapshot(), Action::Click("adopt:polter-worker".into())).adopt.as_deref(), Some("polter-worker"));
        assert!(apply(&mut m, &c, &snapshot(), Action::Click("keepmine".into())).keep_mine);
        // Nothing to say: no notices, and the page starts at the top.
        let c = official_cat(OfficialState::Modified);
        ed.load(&c, Some("polter-supervisor"));
        let r = page(&ed, &c, &k);
        assert_eq!(r[0].gap, 0);
        assert_eq!(keys(&r)[0], "name");
    }

    #[test]
    fn an_official_roles_locked_fields_carry_a_lock_and_the_three_boxes_end_together() {
        let k = shipped_skills();
        let c = official_cat(OfficialState::Modified);
        let mut ed = Editor::default();
        ed.load(&c, Some("polter-supervisor"));
        let laid = place(&page(&ed, &c, &k), 560, 96, &fake_measure);
        let at = |key: &str| laid.cells.iter().find(|p| p.key == key).unwrap().rect;
        let (name, key, summary) = (at("name"), at("key"), at("summary"));
        // Locked: the words, not a box (task 1550).
        let kind = |key: &str| laid.cells.iter().find(|p| p.key == key).unwrap().kind.clone();
        assert!(matches!(kind("name"), Kind::Text { .. }) && matches!(kind("summary"), Kind::Text { .. }));
        assert_eq!(name.right, key.right);
        assert_eq!(key.right, summary.right);
        let locks: Vec<&Placed> = laid.cells.iter().filter(|p| p.kind == Kind::Lock).collect();
        assert_eq!(locks.len(), 2, "name and description");
        assert!(locks.iter().all(|l| l.rect.left > name.right));
        assert!(texts(&page(&ed, &c, &k)).iter().any(|t| t.starts_with("These three are part of the official role")));
        // A role of one's own: no lock, and the boxes run to the edge.
        ed.load(&c, Some("mine"));
        let laid = place(&page(&ed, &c, &k), 560, 96, &fake_measure);
        assert!(laid.cells.iter().all(|p| p.kind != Kind::Lock));
        assert_eq!(laid.cells.iter().find(|p| p.key == "name").unwrap().rect.right, 560 - PAD);
    }

    #[test]
    fn the_skill_page_is_its_name_status_and_whole_text() {
        let k = shipped_skills();
        let c = official_cat(OfficialState::Pristine);
        let mut ed = Editor::default();
        ed.load_skill(&c, &k, "supervising");
        let r = page(&ed, &c, &k);
        assert_eq!(keys(&r), vec!["skillname".to_string(), "skilltext".to_string()]);
        assert!(texts(&r).contains(&"Changed".to_string()));
        for (dpi, width) in [(96, 400), (144, 600), (192, 800)] {
            let laid = place(&r, width, dpi, &fake_measure);
            for p in laid.cells.iter().filter(|p| p.kind.is_control()) {
                assert!(p.rect.left >= 0 && p.rect.right <= width, "{} escapes at {dpi}", p.key);
            }
        }
    }

    /// Notices with buttons, at the narrowest pane and at three DPIs: the
    /// button is whole and inside, the words wrap beside it.
    #[test]
    fn notices_with_buttons_fit_the_narrowest_pane() {
        let k = shipped_skills();
        let mut c = official_cat(OfficialState::ModifiedStale);
        c.shadowed = vec![("polter-worker".into(), "A role with a long name of its own".into())];
        let mut ed = Editor::default();
        ed.load(&c, Some("polter-supervisor"));
        let r = page(&ed, &c, &k);
        for dpi in [96, 144, 192] {
            let width = (MIN_W - LIST_W - 1) * dpi / 96;
            let laid = place(&r, width, dpi, &fake_measure);
            for key in ["keepmine", "adopt:polter-worker"] {
                let b = laid.cells.iter().find(|p| p.key == key).unwrap();
                assert!(b.rect.right <= width - PAD * dpi / 96 && b.rect.left >= 0, "{key} at {dpi}");
                let words = laid.cells.iter().find(|p| p.rect.top < b.rect.bottom && b.rect.top < p.rect.bottom && matches!(p.kind, Kind::Text { .. }) && p.rect.right <= b.rect.left);
                assert!(words.is_some(), "{key}'s words are beside it at {dpi}");
            }
        }
    }
}
