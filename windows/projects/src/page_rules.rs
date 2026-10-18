//! What the interface does about a tab being a page of a project: which
//! tabs "Save as Project" offers, what the menus say and offer, whether
//! closing a page asks first, and what saving over a project that exists
//! is allowed to replace. Decided here, drawn in the host.
//!
//! The macOS host's `ProjectPageRules.swift`, rule for rule and word for
//! word (a `{}` here is a `%@` there); `save_over` is the three refusals at
//! the top of its `ProjectSession.save`.

use std::collections::BTreeSet;

use crate::n_;

// ---- Save as Project

/// One tab of the window "Save as Project" was asked in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tab {
    pub id: u64,
    pub title: String,
    pub panes: usize,
    /// The project it is a page of already, if any.
    pub project: Option<String>,
    /// Whether it is the tab the person asked from.
    pub is_current: bool,
}

/// What stands at the right of a tab's row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Note {
    /// The tab the person asked from.
    ThisPage,
    Panes(usize),
    /// A page of a project already: it cannot be saved into another.
    InProject(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub id: u64,
    pub title: String,
    pub note: Note,
    /// False for a tab that is a page of a project already. **A tab is a
    /// page of at most one project**: two projects each saving the same tab
    /// would each write its panes' scrollback, under numbers that mean
    /// something else in the other.
    pub can_check: bool,
}

/// One row per tab, in the order of the tabs.
pub fn save_as_rows(tabs: &[Tab]) -> Vec<Row> {
    tabs.iter()
        .map(|tab| match &tab.project {
            Some(project) => Row { id: tab.id, title: tab.title.clone(), note: Note::InProject(project.clone()), can_check: false },
            None => Row { id: tab.id, title: tab.title.clone(), note: if tab.is_current { Note::ThisPage } else { Note::Panes(tab.panes) }, can_check: true },
        })
        .collect()
}

/// What is checked when the box opens: **the tab it was asked from and no
/// other** -- and not even that one when it is a page of a project already.
pub fn initially_checked(tabs: &[Tab]) -> BTreeSet<u64> {
    tabs.iter().filter(|t| t.is_current && t.project.is_none()).map(|t| t.id).collect()
}

/// The tabs a save takes, in the order of the tabs: the checked ones that
/// can be. A check left on a row that cannot be checked is not a way round
/// the rule.
pub fn tabs_to_save(checked: &BTreeSet<u64>, rows: &[Row]) -> Vec<u64> {
    rows.iter().filter(|r| r.can_check && checked.contains(&r.id)).map(|r| r.id).collect()
}

/// What is checked after a press on `row` -- a click on it, or Space: its
/// tick turned over, when it can be checked. A row that cannot be (a page
/// of a project already) is left as it is, as the macOS sheet's row
/// ignores a tap on it.
pub fn toggled(checked: &BTreeSet<u64>, row: &Row) -> BTreeSet<u64> {
    let mut out = checked.clone();
    if row.can_check && !out.remove(&row.id) {
        out.insert(row.id);
    }
    out
}

/// Whether "Save as Project" can be pressed: there is a name, and at least
/// one tab to save.
pub fn can_save(name: &str, checked: &BTreeSet<u64>, rows: &[Row]) -> bool {
    !name.trim().is_empty() && !tabs_to_save(checked, rows).is_empty()
}

/// A sentence to translate, and what goes into its `{}`s in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Words {
    pub msgid: &'static str,
    pub args: Vec<String>,
}

impl Words {
    fn of(msgid: &'static str, args: &[&str]) -> Words {
        Words { msgid, args: args.iter().map(|a| a.to_string()).collect() }
    }

    /// The sentence with its `{}`s filled, given the translation of
    /// `msgid` (or `msgid` itself).
    pub fn filled(&self, translated: &str) -> String {
        self.args.iter().fold(translated.to_string(), |s, a| s.replacen("{}", a, 1))
    }
}

pub fn note_words(note: &Note) -> Words {
    match note {
        Note::ThisPage => Words::of(n_("This page"), &[]),
        Note::Panes(count) => Words::of(n_("{} pane(s)"), &[&count.to_string()]),
        Note::InProject(name) => Words::of(n_("Already in the project \"{}\""), &[name]),
    }
}

pub const TABS_TO_SAVE: &str = n_("Tabs of this window to save");
pub const SAVED_FROM_NOW_ON: &str =
    n_("Once saved, these tabs are saved back to the project whenever their layout changes. There is no need to save again.");

// ---- The menus

/// The line at the top of the `Project` menu, which cannot be chosen: which
/// project the tab in front is a page of.
pub fn menu_header(project: Option<&str>) -> Words {
    match project {
        None => Words::of(n_("This page is in no project"), &[]),
        Some(project) => Words::of(n_("This page is in the project \"{}\""), &[project]),
    }
}

/// The things the `Project` menu and a tab's own menu do to a page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Item {
    SaveAs,
    Open,
    Manage,
    /// Put this tab into a project that exists.
    AddTo,
    Rename,
    /// Take this page out of its project; the tab stays open.
    TakeOut,
    /// Close every page of the project. They stay its pages.
    CloseProject,
}

impl Item {
    pub const ALL: [Item; 7] = [Item::SaveAs, Item::Open, Item::Manage, Item::AddTo, Item::Rename, Item::TakeOut, Item::CloseProject];
}

/// Whether `item` can be chosen for a tab that is a page of `project`
/// (none: of none).
///
/// The three that act on the project need one. "Add to Project" needs there
/// to be none -- a tab is a page of at most one. "Save as Project" is
/// always offered: the box it opens says which tabs it can take.
pub fn offered(item: Item, page_of: Option<&str>) -> bool {
    match item {
        Item::SaveAs | Item::Open | Item::Manage => true,
        Item::AddTo => page_of.is_none(),
        Item::Rename | Item::TakeOut | Item::CloseProject => page_of.is_some(),
    }
}

/// "Take This Page Out of the Project", naming the project when the tab has
/// one -- so that the item says what it would be taken out of, which "Close
/// Project" beside it does not.
pub fn take_out_title(project: Option<&str>) -> Words {
    match project {
        None => Words::of(n_("Take This Page Out of the Project"), &[]),
        Some(project) => Words::of(n_("Take This Page Out of \"{}\""), &[project]),
    }
}

pub const ADD_TO_PROJECT: &str = n_("Add to Project");
pub const CLOSE_PROJECT: &str = n_("Close Project");
pub const RENAME_PROJECT: &str = n_("Rename Project…");
/// Why a page with the group's supervisor on it is not taken out
/// (`SupervisorPage`, the core's answer to `project_remove`).
pub const SUPERVISOR_PAGE: &str = n_("The group's supervisor is on this page, so it stays in the group's project.");

// ---- Closing a page

/// What a person chose to have happen from now on when a page closes.
/// "Ask" is what nothing stored means.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseChoice {
    Ask,
    /// Close it, and it stays a page: the project brings it back.
    Keep,
    /// Close it and take it out of the project.
    TakeOut,
}

impl CloseChoice {
    pub const ALL: [CloseChoice; 3] = [CloseChoice::Ask, CloseChoice::Keep, CloseChoice::TakeOut];

    /// The word it is stored as; the macOS host's raw values.
    pub fn stored(self) -> &'static str {
        match self {
            CloseChoice::Ask => "ask",
            CloseChoice::Keep => "keep",
            CloseChoice::TakeOut => "takeOut",
        }
    }

    /// Read back; anything else -- nothing, or a word from a later build --
    /// is "ask", which loses nobody a page.
    pub fn from_stored(word: &str) -> CloseChoice {
        CloseChoice::ALL.into_iter().find(|c| c.stored() == word).unwrap_or(CloseChoice::Ask)
    }

    pub fn msgid(self) -> &'static str {
        match self {
            CloseChoice::Ask => n_("Ask each time"),
            CloseChoice::Keep => n_("Keep it in the project"),
            CloseChoice::TakeOut => n_("Take it out of the project"),
        }
    }
}

/// How a page comes to be closing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseScope {
    /// The one tab, by itself.
    Tab,
    /// Its whole window.
    Window,
    /// "Close Project".
    Project,
    Quit,
}

impl CloseScope {
    pub const ALL: [CloseScope; 4] = [CloseScope::Tab, CloseScope::Window, CloseScope::Project, CloseScope::Quit];
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseStep {
    Ask,
    Close { taking_out: bool },
}

/// What happens when a tab closes.
///
/// **Closing a page is not taking it out**: left alone, the project brings
/// it back the next time it is opened. So the only question is whether to
/// take it out as well, and it is asked only where the answer could be
/// wanted: one page closed by itself, of a project that has other pages
/// open. A window closing, the project closing and the application quitting
/// are a person putting the project away, not thinning it; a project's last
/// open page closing is the project being closed. None of those asks, and
/// none takes anything out.
pub fn close_step(page_of: Option<&str>, other_pages_open: usize, scope: CloseScope, choice: CloseChoice) -> CloseStep {
    if page_of.is_none() || scope != CloseScope::Tab || other_pages_open == 0 {
        return CloseStep::Close { taking_out: false };
    }
    match choice {
        CloseChoice::Ask => CloseStep::Ask,
        CloseChoice::Keep => CloseStep::Close { taking_out: false },
        CloseChoice::TakeOut => CloseStep::Close { taking_out: true },
    }
}

/// What is remembered after the question was answered: the answer, when
/// "don't ask again" was ticked with it; otherwise what it was.
pub fn choice_after(taking_out: bool, dont_ask_again: bool, was: CloseChoice) -> CloseChoice {
    if !dont_ask_again {
        return was;
    }
    if taking_out {
        CloseChoice::TakeOut
    } else {
        CloseChoice::Keep
    }
}

/// The question, in the order a box shows it: its title, the sentence under
/// it, and the tick boxes.
pub fn close_question_title(tab_title: &str) -> Words {
    Words::of(n_("Close the page \"{}\""), &[tab_title])
}

pub fn close_question_body(project: &str) -> Words {
    Words::of(n_("It is a page of the project \"{}\". If you only close it, it comes back the next time the project is opened."), &[project])
}

pub const ALSO_TAKE_OUT: &str = n_("Also take it out of the project");
pub const DONT_ASK_AGAIN: &str = n_("Don't ask again (do as chosen this time)");

// ---- How big a project is

/// "3 pages · 7 panes": a project is counted whole, not by its first page.
pub fn size(pages: usize, panes: usize) -> Words {
    Words::of(n_("{} page(s) · {} pane(s)"), &[&pages.to_string(), &panes.to_string()])
}

// ---- Saving over a project that exists

/// What saving `chosen` tabs under a name may do, given the tabs the
/// project of that name has open now (`its_open_tabs`; empty when it is not
/// open) and, for each chosen tab, the project it is a page of already.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SaveOver {
    /// The project becomes these tabs. Whatever pages it had are replaced
    /// -- the replaced version is kept as the previous one -- and its
    /// group, if it had one, stays its group.
    Replace,
    /// These are exactly the tabs it is open in: its own project, saved
    /// again by hand.
    Again,
    /// It is open in other tabs: its pages there would be written straight
    /// back over this.
    OpenElsewhere,
    /// This chosen tab is a page of this other project: a tab is a page of
    /// at most one.
    PageOfAnother { tab: u64, project: String },
}

pub fn save_over(name: &str, its_open_tabs: &[u64], chosen: &[(u64, Option<String>)]) -> SaveOver {
    if !its_open_tabs.is_empty() {
        let all_chosen = its_open_tabs.iter().all(|t| chosen.iter().any(|(c, _)| c == t));
        let all_its = chosen.iter().all(|(c, p)| its_open_tabs.contains(c) && p.as_deref() == Some(name));
        return if all_chosen && all_its { SaveOver::Again } else { SaveOver::OpenElsewhere };
    }
    match chosen.iter().find_map(|(tab, p)| p.clone().map(|p| (*tab, p))) {
        Some((tab, project)) => SaveOver::PageOfAnother { tab, project },
        None => SaveOver::Replace,
    }
}

pub fn open_elsewhere_words(name: &str) -> Words {
    Words::of(n_("\"{}\" is open in other tabs, which save it automatically. Close those tabs first."), &[name])
}

pub fn page_of_another_words(tab_title: &str, project: &str) -> Words {
    Words::of(n_("The tab \"{}\" is already a page of the project \"{}\". Take it out of that project first."), &[tab_title, project])
}
