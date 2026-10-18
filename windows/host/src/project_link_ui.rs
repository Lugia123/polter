//! A group's project, on Windows (task 1714, `project-link-interface.md`
//! §3): the group's "Project ›" menu and what each of its items does, the
//! question put when a project already has the group's name, and the line
//! saying a project was made for a group, with its Undo.
//!
//! **What is offered is not decided here.** The menu's items are
//! `project_link::menu`'s, the words `project_words`', both in the
//! control-room crate where they are tested and compared with the macOS
//! host's. This builds the system's menu from them and carries each out:
//! the person's word goes to the core as one of its four acts
//! (`project_decline`, `project_undecline`, `project_link`,
//! `project_not_now`), and what is done to a project file is done by the
//! same code the core's own orders use (`project_session`).

use std::cell::RefCell;
use std::path::PathBuf;

use polter_control_room::act::{self, Act};
use polter_control_room::list::Row;
use polter_control_room::project_link::{self, HintClock, Item};
use polter_control_room::project_words::{self as words, Answer, Blocker, Made, UndoStep};
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, GetForegroundWindow, GA_ROOT};

use crate::i18n::tr;
use crate::project_session::{self, Known};
use crate::{plogf, tabs};

/// The prefix of a "Project ›" item's id in the row menu's list of ids;
/// what follows it is the item's (`project_link::Item::id`).
pub const ITEM: &str = "project:";
/// "Use an Existing Project ›": the project, by name.
pub const LINK: &str = "project_link:";
/// For several projects: "Use “X”".
pub const USE: &str = "project_use:";

/// One line of the "Project ›" submenu, as the system's menu takes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub id: String,
    pub label: String,
    pub enabled: bool,
    /// The lines of the submenu it opens: only "Use an Existing Project ›".
    pub sub: Vec<Line>,
}

/// The group's tie, as the menu, the banner and the question need it.
fn tie_of(row: &Row) -> (String, String) {
    match row.project.as_ref() {
        Some(p) => (p.tie.clone(), p.why.clone()),
        // A core before task 1714: nothing is known, so nothing is offered
        // but saying so.
        None => ("undecided".into(), "projects_unknown".into()),
    }
}

/// The project in the way of `group`: the one with its name.
fn blocker(group: &str, known: &[Known]) -> Option<Blocker> {
    let k = known.iter().find(|k| k.name == group)?;
    Some(Blocker {
        name: k.name.clone(),
        saved: polter_settings_shell::projects::format_time(k.saved_at, crate::projects_ui::local_offset()),
        pages: k.pages,
    })
}

/// The "Project ›" submenu of `row`'s menu.
pub fn submenu(row: &Row) -> Vec<Line> {
    let group = row.name().to_string();
    let (tie, why) = tie_of(row);
    let known = project_session::known();
    let bound = row.project_name.clone().unwrap_or_default();
    let name = if tie == "bound" { bound } else { group.clone() };
    let t = |s: &str| tr(s);
    let mut out = Vec::new();
    for item in project_link::menu(&tie, &why, row.steward.is_some()) {
        let label = words::item_label(&item, &name, &group, &t);
        match &item {
            Item::Header(_) => out.push(Line { id: format!("{ITEM}{}", item.id()), label, enabled: false, sub: Vec::new() }),
            Item::LinkExisting => {
                let projects: Vec<(String, Option<String>)> = known.iter().map(|k| (k.name.clone(), k.group.clone())).collect();
                let mut sub: Vec<Line> = words::link_choices(&projects, &t)
                    .into_iter()
                    .map(|c| Line { id: format!("{LINK}{}", c.name), label: c.label, enabled: c.enabled, sub: Vec::new() })
                    .collect();
                if sub.is_empty() {
                    sub.push(Line { id: format!("{LINK}"), label: tr(words::msg::NO_PROJECTS), enabled: false, sub: Vec::new() });
                }
                out.push(Line { id: format!("{ITEM}{}", item.id()), label, enabled: true, sub });
            }
            _ => out.push(Line { id: format!("{ITEM}{}", item.id()), label, enabled: true, sub: Vec::new() }),
        }
        // Several projects say they are the group's: one line for each,
        // under the line that says so.
        if item == Item::Header("several_projects".into()) {
            for k in known.iter().filter(|k| k.group.as_deref() == Some(group.as_str())) {
                out.push(Line { id: format!("{USE}{}", k.name), label: polter_control_room::list::fill(&tr(words::msg::USE_THIS), &k.name), enabled: true, sub: Vec::new() });
            }
        }
    }
    out
}

/// Whether `id`, from the row menu's list, is one of this submenu's.
pub fn owns(id: &str) -> bool {
    id.starts_with(ITEM) || id.starts_with(LINK) || id.starts_with(USE)
}

/// Send one of the four acts for `group`; the core's refusal, in its name.
fn send(what: &Act) -> Result<(), String> {
    let Some(request) = act::encode(what) else { return Err("BadRequest".into()) };
    let done = crate::control_room_source::act(&request);
    plogf!("[project-link] {} -> {:?}", request, done);
    done
}

/// Say a refusal under the group's row.
fn refused(hwnd: HWND, group: &str, why: &str) {
    crate::control_room::say_refused(hwnd, group, why);
}

/// What one of the submenu's items does, for `row`'s group. `hwnd` is the
/// control room's.
pub fn pick(hwnd: HWND, row: &Row, id: &str) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    let group = row.name().to_string();
    if let Some(name) = id.strip_prefix(LINK).or_else(|| id.strip_prefix(USE)) {
        link(hwnd, frame, &group, name);
        return;
    }
    let Some(item) = id.strip_prefix(ITEM) else { return };
    let known = project_session::known();
    let file_of = |name: &str| known.iter().find(|k| k.name == name).map(|k| k.path.clone());
    let bound = row.project_name.clone().unwrap_or_default();
    match item {
        "open_project" => open(frame, file_of(&bound)),
        "open_blocker" => open(frame, file_of(&group)),
        "show_in_settings" => crate::settings_win::request(
            polter_settings_shell::Route::to(polter_settings_shell::Section::Projects, Some(bound.as_str())),
            frame,
        ),
        "unlink_project" => unlink(hwnd, frame, &group, &bound, file_of(&bound)),
        "save_supervisor_tab" => save_supervisor_tab(hwnd, frame, row),
        "decline_project" => {
            if let Err(why) = send(&Act::ProjectDecline { group: &group }) {
                refused(hwnd, &group, &why);
            }
        }
        "undecline_project" => {
            if let Err(why) = send(&Act::ProjectUndecline { group: &group }) {
                refused(hwnd, &group, &why);
            }
        }
        "join_existing" => answer(hwnd, frame, row, Answer::Join),
        "replace_existing" => answer(hwnd, frame, row, Answer::Replace),
        other => plogf!("[project-link] {:?}: no such item {:?}", group, other),
    }
}

fn open(frame: HWND, file: Option<PathBuf>) {
    match file {
        Some(file) => {
            let opened = crate::project_ui::open_project(frame, crate::app_handle(), hinst(), &file);
            plogf!("[project-link] open {:?} -> {:?}", file, opened);
        }
        None => plogf!("[project-link] open: no such project"),
    }
}

fn hinst() -> windows::Win32::Foundation::HINSTANCE {
    unsafe { windows::Win32::System::LibraryLoader::GetModuleHandleW(None) }.map(Into::into).unwrap_or_default()
}

/// "Use an Existing Project ›" and "Use “X”": the group uses `name`. When
/// another project has the group's name, the person is asked whether to
/// rename that one "X (old)" first (v1 B), and the link is asked again.
fn link(hwnd: HWND, frame: HWND, group: &str, name: &str) {
    match send(&Act::ProjectLink { group, project: name }) {
        Ok(()) => {}
        Err(why) if why == "ProjectNameTaken" => {
            let old = polter_control_room::list::fill(&tr(words::msg::OLD_NAME), group);
            let main = polter_control_room::list::fill(&polter_control_room::list::fill(&tr(words::msg::RENAME_FIRST), group), &old);
            if crate::projects_ui::ask_with_default(frame, "[project-link]", &main, "", &[tr(words::msg::RENAME_AND_LINK), tr(words::msg::CANCEL)], 0, false) != Some(0) {
                return;
            }
            let known = project_session::known();
            let Some(other) = known.iter().find(|k| k.name == group) else { return };
            match project_session::rename_project(&other.path, &old) {
                Ok(()) => {
                    if let Err(why) = send(&Act::ProjectLink { group, project: name }) {
                        refused(hwnd, group, &why);
                    }
                }
                Err(e) => refused(hwnd, group, &e),
            }
        }
        Err(why) => refused(hwnd, group, &why),
    }
}

/// "Stop Using It as This Group's Project…": asked, with the tick box that
/// also moves the file to the Recycle Bin, unticked.
fn unlink(hwnd: HWND, frame: HWND, group: &str, name: &str, file: Option<PathBuf>) {
    let (q, check) = words::unlink_question(name, group, &|s| tr(s));
    let Some((0, ticked)) = crate::projects_ui::ask_with_check(frame, "[project-link]", &q.main, &q.body, &q.buttons, q.default, &check) else {
        return;
    };
    if let Err(why) = send(&Act::ProjectDecline { group }) {
        refused(hwnd, group, &why);
        return;
    }
    if ticked {
        if let Some(file) = file {
            if let Err(e) = crate::projects_ui::recycle_project(&file) {
                refused(hwnd, group, &e);
            }
        }
    }
}

/// The group's supervisor's tab, and its window.
fn supervisors_tab(row: &Row) -> Option<(String, HWND, tabs::TabId)> {
    let key = row.steward.clone()?;
    let (frame, tab) = tabs::tab_of_terminal(&key)?;
    Some((key, frame, tab))
}

/// "Save the Supervisor's Tab as Project “X”": the person's own doing, so
/// no line says it was done.
fn save_supervisor_tab(hwnd: HWND, frame: HWND, row: &Row) {
    let group = row.name().to_string();
    let Some((key, tab_frame, tab)) = supervisors_tab(row) else {
        plogf!("[project-link] save the supervisor's tab of {:?}: it has none on screen", group);
        return;
    };
    match project_session::save_for_group(&[(tab_frame, tab)], &group, &key) {
        Ok(_) => {
            if let Err(why) = send(&Act::ProjectLink { group: &group, project: &group }) {
                refused(hwnd, &group, &why);
            }
        }
        Err(e) => {
            plogf!("[project-link] save the supervisor's tab of {:?} as a project: {}", group, e);
            refused(hwnd, &group, &e);
        }
    }
    let _ = frame;
}

/// The group whose supervisor is in `tab`, if one is (task 1714, the tab's
/// «Save as the Project of Group “X”…»).
pub fn group_supervised_in(tab: tabs::TabId) -> Option<String> {
    let rows: Vec<(String, String)> = crate::control_room_source::with(|d| match d {
        crate::control_room_source::Data::Ready(r) => r.list.rows().filter_map(|row| Some((row.name().to_string(), row.steward.clone()?))).collect(),
        _ => Vec::new(),
    });
    rows.into_iter().find_map(|(group, steward)| (tabs::tab_of_terminal(&steward).map(|(_, t)| t) == Some(tab)).then_some(group))
}

/// «Save as the Project of Group “X”…» on `tab`: saved under the group's
/// name, naming the group, its supervisor's pane marked, and the group told
/// to use it (`project_link`, which also takes back "no project"). A name
/// already taken is asked about as the save's own overwrite is, and what
/// it replaces is kept as the previous version. Whether it was saved.
pub fn save_tab_for_group(frame: HWND, tab: tabs::TabId, group: &str) -> bool {
    let steward = crate::control_room_source::with(|d| match d {
        crate::control_room_source::Data::Ready(r) => r.list.row(group).and_then(|row| row.steward.clone()),
        _ => None,
    });
    let Some(key) = steward else {
        plogf!("[project-link] save tab as {:?}'s project: the group has no supervisor any more", group);
        return false;
    };
    let known = project_session::known();
    let saved = match known.iter().find(|k| k.name == group) {
        Some(k) => {
            let existing = crate::project::read_file(&k.path).ok();
            if !crate::projects_ui::confirm_save_as_overwrite(frame, group, existing.as_ref()) {
                return false;
            }
            project_session::replace(&k.path, &[(frame, tab)], group, &key)
        }
        None => project_session::save_for_group(&[(frame, tab)], group, &key).map(|_| ()),
    };
    if let Err(e) = saved {
        plogf!("[project-link] save tab as {:?}'s project: {}", group, e);
        let room = crate::control_room::panel_hwnd().unwrap_or_default();
        refused(room, group, &e);
        return false;
    }
    if let Err(why) = send(&Act::ProjectLink { group, project: group }) {
        let room = crate::control_room::panel_hwnd().unwrap_or_default();
        refused(room, group, &why);
    }
    true
}

/// "Save as Project" with "As the project of group “X”" ticked (task 1714,
/// interface §3.5): the project just saved as `name` in `dir` names the
/// group, its supervisor's pane marked, and the group is told to use it --
/// which also takes back "no project", and has the core rename it to the
/// group's name if it is called something else.
pub fn adopt_saved(dir: &std::path::Path, name: &str, group: &str) {
    let steward = crate::control_room_source::with(|d| match d {
        crate::control_room_source::Data::Ready(r) => r.list.row(group).and_then(|row| row.steward.clone()),
        _ => None,
    });
    let Ok(file) = crate::project::path_for(dir, name) else { return };
    let adopted = project_session::adopt(&file, group, steward.as_deref());
    plogf!("[project-link] saved {:?} as {:?}'s project -> {:?}", name, group, adopted);
    let room = crate::control_room::panel_hwnd().unwrap_or_default();
    if let Err(e) = adopted {
        refused(room, group, &e);
        return;
    }
    if let Err(why) = send(&Act::ProjectLink { group, project: name }) {
        refused(room, group, &why);
    }
}

/// Carry out an answer to the question when a project already has the
/// group's name (§3.1): from the question, the banner or the menu.
pub fn answer(hwnd: HWND, frame: HWND, row: &Row, a: Answer) {
    let group = row.name().to_string();
    match a {
        Answer::NotNow => {
            if let Err(why) = send(&Act::ProjectNotNow { group: &group }) {
                refused(hwnd, &group, &why);
            }
        }
        Answer::Decline => {
            if let Err(why) = send(&Act::ProjectDecline { group: &group }) {
                refused(hwnd, &group, &why);
            }
        }
        Answer::Join | Answer::Replace => {
            let Some((key, tab_frame, tab)) = supervisors_tab(row) else {
                plogf!("[project-link] {:?}: the supervisor's tab is not on screen; nothing joined", group);
                return;
            };
            let known = project_session::known();
            let Some(file) = known.iter().find(|k| k.name == group).map(|k| k.path.clone()) else {
                plogf!("[project-link] {:?}: the project with its name is gone", group);
                return;
            };
            let done = if a == Answer::Join {
                project_session::join(&file, tab, &key).map(|()| Made::Joined { name: group.clone(), path: file.to_string_lossy().into_owned() })
            } else {
                let (main, body, buttons) = {
                    let q = words::replace_question(&group, &tabs::title_of_tab(tab), tabs::panes_of_tab(tab), &|s| tr(s));
                    (q.main, q.body, q.buttons)
                };
                if crate::projects_ui::ask_with_default(frame, "[project-link]", &main, &body, &buttons, 0, false) != Some(0) {
                    return;
                }
                project_session::replace(&file, &[(tab_frame, tab)], &group, &key)
                    .map(|()| Made::Replaced { name: group.clone(), path: file.to_string_lossy().into_owned() })
            };
            match done {
                // The core binds it on its next look: the supervisor's tab is
                // now in a project with the group's name and no group.
                Ok(made) => made_for(&group, made),
                Err(e) => refused(hwnd, &group, &e),
            }
        }
    }
}

// ------------------------------------------------------------ the question

thread_local! {
    /// The groups the question was put for this run: it is put once, and
    /// what was answered is the core's to remember (`project_not_now`).
    static ASKED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

thread_local! {
    static SOON: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Look at whether to ask, a moment from now and off the caller's stack:
/// the question is a modal dialog, and neither a snapshot's reader nor a
/// window's activation is the place to run one.
pub fn soon() {
    if SOON.with(std::cell::Cell::get) != 0 {
        return;
    }
    let id = unsafe { windows::Win32::UI::WindowsAndMessaging::SetTimer(None, 0, 50, Some(soon_timer)) };
    SOON.with(|s| s.set(id));
}

unsafe extern "system" fn soon_timer(_: HWND, _: u32, id: usize, _: u32) {
    let _ = unsafe { windows::Win32::UI::WindowsAndMessaging::KillTimer(None, id) };
    SOON.with(|s| s.set(0));
    let rows: Vec<Row> = crate::control_room_source::with(|d| match d {
        crate::control_room_source::Data::Ready(r) => r.list.rows().cloned().collect(),
        _ => Vec::new(),
    });
    let room = crate::control_room::panel_hwnd().unwrap_or_default();
    consider_asking(&rows, room);
}

/// Put the question for any group the core says to ask about now, if the
/// person is there to answer it (`project_words::should_ask`). Called as
/// each snapshot arrives and when a window comes to the front.
pub fn consider_asking(rows: &[Row], room: HWND) {
    for row in rows {
        let Some(p) = row.project.as_ref() else { continue };
        if !p.ask {
            continue;
        }
        let group = row.name().to_string();
        let asked = ASKED.with(|a| a.borrow().contains(&group));
        let front = unsafe { GetForegroundWindow() };
        let in_front = crate::winid::all().contains(&front);
        let showing = tabs::new_tab_facts().control_room == Some(front)
            || supervisors_tab(row).is_some_and(|(_, f, tab)| f == front && tabs::locate_tab(tab).is_some_and(|(_, _, shown)| shown));
        if !words::should_ask(p.ask, in_front, showing, asked) {
            continue;
        }
        ASKED.with(|a| a.borrow_mut().push(group.clone()));
        let known = project_session::known();
        let Some(b) = blocker(&group, &known) else {
            plogf!("[project-link] {:?}: the core asks, and no project here has its name", group);
            continue;
        };
        let q = words::join_question(&b, &|s| tr(s));
        let links: Vec<(String, String)> = q.links.iter().map(|l| (l.label.clone(), l.note.clone())).collect();
        let not_now = q.links.iter().position(|l| l.answer == Answer::NotNow).unwrap_or(0);
        let picked = crate::projects_ui::ask_links(front, "[project-link]", &q.main, &q.body, &links, 0, not_now);
        let a = picked.and_then(|i| q.links.get(i)).map_or(Answer::NotNow, |l| l.answer);
        plogf!("[project-link] {:?}: asked; answered {:?}", group, a);
        answer(room, front, row, a);
    }
}

/// What the banner's button `item` does: the menu's item of the same name,
/// or one of the question's answers.
pub fn banner_button(hwnd: HWND, row: &Row, item: &Item) {
    let frame = unsafe { GetAncestor(hwnd, GA_ROOT) };
    match item {
        Item::JoinExisting => answer(hwnd, frame, row, Answer::Join),
        Item::ReplaceExisting => answer(hwnd, frame, row, Answer::Replace),
        Item::DeclineProject => answer(hwnd, frame, row, Answer::Decline),
        other => pick(hwnd, row, &format!("{ITEM}{}", other.id())),
    }
}

// ---------------------------------------------- the line saying it was made

/// A line saying a project was made for a group (§3.2).
#[derive(Clone, Debug)]
pub struct Hint {
    pub group: String,
    pub made: Made,
    pub clock: HintClock,
    /// Undo was pressed: the line now says what was undone, with its ✕.
    pub undone: bool,
}

thread_local! {
    static HINTS: RefCell<Vec<Hint>> = const { RefCell::new(Vec::new()) };
}

/// A project was made for `group`: by the core's `create` or `bind`
/// (`project_session::obey`), or by "Join and Link" or "Replace…". Not for
/// a save or a link the person made themselves.
pub fn made_for(group: &str, made: Made) {
    plogf!("[project-link] made for {:?}: {:?}", group, made);
    let keep = HINTS.with(|h| {
        let mut h = h.borrow_mut();
        // The core's `bind` that follows "Join and Link" or "Replace…" (the
        // tab is now in a project with the group's name, and no group) is
        // what was just said, not news: the line that stands has the Undo
        // that undoes it.
        let follows = matches!(&made, Made::Renamed { from, to, .. } if from == to)
            && h.iter().any(|x| x.group == group && !x.undone && !x.clock.gone() && matches!(x.made, Made::Joined { .. } | Made::Replaced { .. }));
        if !follows {
            h.retain(|x| x.group != group);
            h.push(Hint { group: group.to_string(), made, clock: HintClock::default(), undone: false });
        }
        follows
    });
    if keep {
        return;
    }
    crate::pane_frames::hints_changed();
    crate::control_room::hint_changed();
}

/// The line for `group`, if one stands.
pub fn hint_of(group: &str) -> Option<Hint> {
    HINTS.with(|h| h.borrow().iter().find(|x| x.group == group && !x.clock.gone()).cloned())
}

/// Every line that stands.
pub fn hints() -> Vec<Hint> {
    HINTS.with(|h| h.borrow().iter().filter(|x| !x.clock.gone()).cloned().collect())
}

/// It was looked at, at `at` seconds, seen or not: the clock of every line
/// moves (`HintClock`), one seen only while seen. `seen` is the groups whose
/// line is on screen with its window in front. Whether any line went.
pub fn look(at: f64, seen: &[String]) -> bool {
    HINTS.with(|h| {
        let mut h = h.borrow_mut();
        let before = h.len();
        for x in h.iter_mut() {
            x.clock.look(at, seen.contains(&x.group));
        }
        h.retain(|x| !x.clock.gone());
        before != h.len()
    })
}

thread_local! {
    static TICK: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static EPOCH: std::time::Instant = std::time::Instant::now();
}

/// Keep the lines' clocks while any stands: once a second, each line seen
/// -- painted in the window in front, or in the control room's frame on the
/// right with the control room in front -- has the second counted
/// (`HintClock`), and one whose time is up goes. No timer while none stands.
pub fn keep_time() {
    let any = HINTS.with(|h| h.borrow().iter().any(|x| !x.clock.gone()));
    let running = TICK.with(std::cell::Cell::get);
    unsafe {
        use windows::Win32::UI::WindowsAndMessaging::{KillTimer, SetTimer};
        if any && running == 0 {
            let id = SetTimer(None, 0, 1000, Some(tick));
            TICK.with(|t| t.set(id));
            // The first look starts every clock.
            tick_now();
        } else if !any && running != 0 {
            let _ = KillTimer(None, running);
            TICK.with(|t| t.set(0));
        }
    }
}

unsafe extern "system" fn tick(_: HWND, _: u32, _: usize, _: u32) {
    tick_now();
}

fn tick_now() {
    let at = EPOCH.with(|e| e.elapsed().as_secs_f64());
    let front = unsafe { GetForegroundWindow() };
    let mut seen = crate::pane_frames::hints_in(front);
    if tabs::new_tab_facts().control_room == Some(front) {
        seen.extend(crate::control_room::hint_showing());
    }
    if look(at, &seen) {
        crate::pane_frames::hints_changed();
        crate::control_room::hint_changed();
    }
}

/// ✕ on the line: it goes, everywhere it was.
pub fn close(group: &str) {
    HINTS.with(|h| {
        for x in h.borrow_mut().iter_mut().filter(|x| x.group == group) {
            x.clock.close();
        }
    });
    crate::pane_frames::hints_changed();
    crate::control_room::hint_changed();
}

/// Undo on the line: the group is said to have no project first, then
/// what was done is undone (`project_words::undo_steps`). None of it
/// touches a running terminal.
pub fn undo(group: &str) {
    let Some(hint) = hint_of(group) else { return };
    let mut failed = None;
    for step in words::undo_steps(&hint.made) {
        let done = match &step {
            UndoStep::Decline => send(&Act::ProjectDecline { group }),
            UndoStep::Recycle { path } => crate::projects_ui::recycle_project(std::path::Path::new(path)),
            UndoStep::RenameBack { path, to } => project_session::unbind(std::path::Path::new(path), to),
            UndoStep::LetGo { path } => project_session::let_go(std::path::Path::new(path)),
            UndoStep::RestorePrevious { path } => project_session::restore_previous(std::path::Path::new(path)),
        };
        plogf!("[project-link] undo for {:?}: {:?} -> {:?}", group, step, done);
        if let Err(e) = done {
            failed = Some(e);
            break;
        }
    }
    HINTS.with(|h| {
        for x in h.borrow_mut().iter_mut().filter(|x| x.group == group) {
            if failed.is_none() {
                x.undone = true;
                // The line that says it was undone is a new line: its own
                // eight seconds.
                x.clock = HintClock::default();
            }
        }
    });
    crate::pane_frames::hints_changed();
    crate::control_room::hint_changed();
}

/// The line's words: what was made, or what was undone.
pub fn hint_words(hint: &Hint, short: bool) -> String {
    let t = |s: &str| tr(s);
    if hint.undone {
        words::undone_text(&hint.made, &t)
    } else {
        words::hint_text(&hint.made, short, &t)
    }
}
