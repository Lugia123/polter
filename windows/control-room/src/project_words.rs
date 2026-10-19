//! What the Windows host says about a group's project (task 1714): the
//! words of the "Project ›" menu, the row's right end and its tooltip, the
//! banner on the right, the confirmation when a project already has the
//! group's name, the line saying a project was made and what undoing it
//! does. Which of them is shown is [`crate::project_link`]'s; this only
//! puts the words together.
//!
//! The words are the designs' (`project-link-v1`, `-v2`, with v2's changes
//! to v1), in English as msgids; `po/zh_CN.po` has the Chinese the designs
//! were drawn in. What the core does not say -- when the blocking project
//! was saved, how many pages it has, which projects there are and whose --
//! the host reads from its own list of projects and hands in.

use crate::confirm::Question;
use crate::list::fill;
use crate::project_link::{Item, Note};

pub mod msg {
    use crate::n_;
    // The "Project ›" menu (§3.3), by item.
    pub const OPEN_PROJECT: &str = n_("Open Project “{}”");
    pub const SHOW_IN_SETTINGS: &str = n_("Show in Project Settings");
    pub const UNLINK_PROJECT: &str = n_("Stop Using It as This Group's Project…");
    pub const SAVE_SUPERVISOR_TAB: &str = n_("Save the Supervisor's Tab as Project “{}”");
    pub const LINK_EXISTING: &str = n_("Use an Existing Project");
    pub const DECLINE_PROJECT: &str = n_("This Group Has No Project");
    pub const UNDECLINE_PROJECT: &str = n_("Use a Project for This Group");
    pub const JOIN_EXISTING: &str = n_("Join and Link");
    pub const REPLACE_EXISTING: &str = n_("Replace “{}”…");
    pub const OPEN_BLOCKER: &str = n_("Open “{}”");
    pub const USE_THIS: &str = n_("Use “{}”");
    // The line at the top of the menu that says why, by reason.
    pub const NAME_TAKEN_HEADER: &str = n_("There is already a project “{}”, in no group");
    pub const SEVERAL_HEADER: &str = n_("More than one project says it is this group's");
    pub const PROJECT_HAS_GROUP: &str = n_("The supervisor's tab is in a project that is another group's.");
    pub const SUPERVISOR_HAS_PROJECT: &str =
        n_("This supervisor already looks after another group, which has a project. One supervisor, one project.");
    pub const SUPERVISOR_OF_SEVERAL: &str =
        n_("This supervisor looks after several groups with no project, so it is not known which one its tab is for.");
    pub const OTHER_SUPERVISOR: &str = n_("There is more than one supervisor in this group.");
    pub const PROJECTS_UNKNOWN: &str = n_("The projects on this computer have not been read yet");
    pub const PROJECT_UNREADABLE: &str = n_("A project file could not be read");
    // "Use an Existing Project ›", one line per project: whose it is.
    pub const IN_NO_GROUP: &str = n_("{} — in no group");
    pub const OF_GROUP: &str = n_("{} — group “{}”");
    pub const NO_PROJECTS: &str = n_("No projects");
    // A tab with a group's supervisor in it (v1 C, brief 7).
    pub const SAVE_FOR_GROUP: &str = n_("Save as the Project of Group “{}”…");
    pub const FOR_GROUP_TICK: &str = n_("As the project of group “{}”");
    // Linking would leave two projects with the group's name: the other is
    // renamed first, when the person says so (v1 B).
    pub const RENAME_FIRST: &str = n_("Another project is called “{}”. Rename it “{}” and link?");
    pub const OLD_NAME: &str = n_("{} (old)");
    pub const RENAME_AND_LINK: &str = n_("Rename and Link");
    // The right end of the row (§3.4).
    pub const WORD_NAME_TAKEN: &str = n_("Same-name project");
    pub const WORD_SEVERAL: &str = n_("Two projects");
    pub const WORD_NOT_MADE: &str = n_("Project not made");
    pub const WORD_UNREADABLE: &str = n_("Project file unreadable");
    // The banner on the right (v2 D: it asks, it does not report).
    pub const BANNER_NAME_TAKEN: &str = n_(
        "There is already a project “{}” ({}, {} pages), in no group. A group's project has the group's name: add the supervisor's tab to it, as this group's project?",
    );
    pub const BANNER_SEVERAL: &str = n_("More than one project says it is this group's. Choose the one it uses; the others lose the group's name, and no file is deleted.");
    // Task 1807: the group's project is kept while a file does not read.
    pub const BANNER_UNREADABLE: &str = n_(
        "The project file {} could not be read, so this group keeps its project as it is. Once the file reads again, the project is used again by itself.",
    );
    pub const OPEN_FIRST: &str = n_("Open “{}” First");
    pub const LINK_EXISTING_DOTS: &str = n_("Use an Existing Project…");
    // The confirmation (v2 B1), a task dialog with command links.
    pub const JOIN_MAIN: &str = n_("There is already a project “{}”. Add the supervisor's tab to it?");
    pub const JOIN_BODY: &str = n_("A group's project has the group's name. “{}” was saved on {}, has {} pages, and is in no group.");
    pub const JOIN_NOTE: &str = n_(
        "The supervisor's tab becomes one of its pages; the pages already there stay. The file is rewritten in the current format, and the old one is kept as the previous version.",
    );
    pub const REPLACE_NOTE: &str = n_("The supervisor's tab takes its place. What is there now is kept as the previous version.");
    pub const NOT_NOW: &str = n_("Not Now");
    pub const NOT_NOW_NOTE: &str = n_("Asked again the next time Polter starts; until then the control room keeps saying so.");
    pub const DECLINE_NOTE: &str = n_("Never asked again. To change your mind: right-click the group, Project.");
    // Replacing, asked a second time.
    pub const REPLACE_MAIN: &str = n_("Replace “{}”?");
    pub const REPLACE_BODY: &str =
        n_("“{}” will be replaced by the tab “{}” ({} panes), and the tab is saved to it automatically from then on. The layout it replaces is kept as the previous version.");
    pub const REPLACE_RESTORE: &str = n_("To get the old page back: Settings › Projects, choose “{}”, Restore Previous Version.");
    pub const REPLACE: &str = n_("Replace");
    pub const CANCEL: &str = n_("Cancel");
    // "Stop Using It as This Group's Project…".
    pub const UNLINK_MAIN: &str = n_("Stop using “{}” as the project of group “{}”?");
    pub const UNLINK_BODY: &str = n_("The tabs stay as they are. The group then has no project until you choose one.");
    pub const UNLINK_ALSO_DELETE: &str = n_("Also move the project file to the Recycle Bin");
    pub const UNLINK: &str = n_("Stop Using It");
    // The line saying a project was made (v2 A1).
    pub const HINT_CREATED: &str = n_("Saved the supervisor's tab as project “{}”, this group's project.");
    pub const HINT_RENAMED: &str = n_("The supervisor's tab was in project “{}”; it was renamed “{}”, this group's project.");
    pub const HINT_JOINED: &str = n_("Joined project “{}”, which is this group's now.");
    pub const HINT_BOUND: &str = n_("Project “{}”, which the supervisor's tab is in, is this group's now.");
    pub const HINT_REPLACED: &str = n_("Replaced project “{}” with the supervisor's tab; the old one is the previous version. It is this group's now.");
    pub const HINT_SHORT: &str = n_("Saved as project “{}”, this group's.");
    pub const UNDO: &str = n_("Undo");
    pub const UNDONE_CREATED: &str = n_("Undone: project “{}” is in the Recycle Bin, and this group has no project. To change that, right-click the group, Project.");
    pub const UNDONE_RENAMED: &str = n_("Undone: the project is called “{}” again, and this group has no project. To change that, right-click the group, Project.");
    pub const UNDONE_JOINED: &str = n_("Undone: project “{}” is back as it was before the tab joined it, and this group has no project. To change that, right-click the group, Project.");
    pub const UNDONE_BOUND: &str = n_("Undone: project “{}” is in no group again, and this group has no project. To change that, right-click the group, Project.");
    pub const UNDONE_REPLACED: &str = n_("Undone: project “{}” is back as it was, and this group has no project. To change that, right-click the group, Project.");
}

/// Fill the `{}`s of `template` in order.
fn fill_all(template: &str, args: &[&str]) -> String {
    args.iter().fold(template.to_string(), |t, a| fill(&t, a))
}

/// The words of a menu item. `name`: the project the group is bound to or
/// the one in the way; `group`: the group's own name.
pub fn item_label(item: &Item, name: &str, group: &str, tr: &dyn Fn(&str) -> String) -> String {
    match item {
        Item::OpenProject => fill(&tr(msg::OPEN_PROJECT), name),
        Item::ShowInSettings => tr(msg::SHOW_IN_SETTINGS),
        Item::UnlinkProject => tr(msg::UNLINK_PROJECT),
        Item::SaveSupervisorTab => fill(&tr(msg::SAVE_SUPERVISOR_TAB), group),
        Item::LinkExisting => tr(msg::LINK_EXISTING),
        Item::DeclineProject => tr(msg::DECLINE_PROJECT),
        Item::UndeclineProject => tr(msg::UNDECLINE_PROJECT),
        Item::JoinExisting => tr(msg::JOIN_EXISTING),
        Item::ReplaceExisting => fill(&tr(msg::REPLACE_EXISTING), name),
        Item::OpenBlocker => fill(&tr(msg::OPEN_BLOCKER), name),
        Item::Header(why) => reason(why, name, tr),
    }
}

/// The sentence for a reason the tie was not made: the menu's first line,
/// the row's tooltip, the banner's text for those with no banner of their
/// own. Empty for one there is nothing to say about.
pub fn reason(why: &str, name: &str, tr: &dyn Fn(&str) -> String) -> String {
    match why {
        "project_name_taken" => fill(&tr(msg::NAME_TAKEN_HEADER), name),
        "several_projects" => tr(msg::SEVERAL_HEADER),
        "project_has_group" => tr(msg::PROJECT_HAS_GROUP),
        "supervisor_has_project" => tr(msg::SUPERVISOR_HAS_PROJECT),
        "supervisor_of_several" => tr(msg::SUPERVISOR_OF_SEVERAL),
        "other_supervisor" => tr(msg::OTHER_SUPERVISOR),
        "projects_unknown" => tr(msg::PROJECTS_UNKNOWN),
        "project_unreadable" => tr(msg::PROJECT_UNREADABLE),
        _ => String::new(),
    }
}

/// The word at the right end of the row; none for a note with none.
pub fn note_word(note: &Note, tr: &dyn Fn(&str) -> String) -> Option<String> {
    match note {
        Note::None => None,
        Note::Name(n) => Some(n.clone()),
        Note::Attention("name_taken") => Some(tr(msg::WORD_NAME_TAKEN)),
        Note::Attention("several") => Some(tr(msg::WORD_SEVERAL)),
        Note::Attention("unreadable") => Some(tr(msg::WORD_UNREADABLE)),
        Note::Attention(_) => Some(tr(msg::WORD_NOT_MADE)),
    }
}

/// One project in "Use an Existing Project ›": its words, and whether it
/// can be chosen -- one that is another group's cannot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choice {
    pub name: String,
    pub label: String,
    pub enabled: bool,
}

/// The projects `(name, group it says it is)`, in the order given. One that
/// is a group's -- another's, or this one's when it is bound (then the menu
/// does not offer this at all) -- is grey and says whose.
pub fn link_choices(projects: &[(String, Option<String>)], tr: &dyn Fn(&str) -> String) -> Vec<Choice> {
    projects
        .iter()
        .map(|(name, owner)| match owner.as_deref() {
            None | Some("") => Choice { name: name.clone(), label: fill(&tr(msg::IN_NO_GROUP), name), enabled: true },
            Some(g) => Choice {
                name: name.clone(),
                label: fill_all(&tr(msg::OF_GROUP), &[name, g]),
                enabled: false,
            },
        })
        .collect()
}

/// The project in the way, as the host's list has it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Blocker {
    pub name: String,
    /// When it was saved, as the host writes a date.
    pub saved: String,
    pub pages: usize,
}

/// A banner button: the menu item it is the same as, and its words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Button {
    pub item: Item,
    pub label: String,
}

/// The banner on the right for a group whose tie was not made (§3.4), or
/// none for a group with nothing to answer. `blocker`: the project with
/// the group's name, when that is why. `candidates`: for several, the
/// projects that say they are the group's. `unreadable`: the project files
/// that do not read, which a group kept for one names (task 1807).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Banner {
    pub text: String,
    pub buttons: Vec<Button>,
    /// For several: one "Use “X”" per candidate, in the order given.
    pub uses: Vec<(String, String)>,
}

pub fn banner(
    note: &Note,
    why: &str,
    blocker: Option<&Blocker>,
    candidates: &[String],
    unreadable: &[String],
    tr: &dyn Fn(&str) -> String,
) -> Option<Banner> {
    let decline = || Button { item: Item::DeclineProject, label: tr(msg::DECLINE_PROJECT) };
    match note {
        Note::Attention("name_taken") => {
            let b = blocker?;
            let pages = b.pages.to_string();
            Some(Banner {
                text: fill_all(&tr(msg::BANNER_NAME_TAKEN), &[&b.name, &b.saved, &pages]),
                buttons: vec![
                    Button { item: Item::JoinExisting, label: tr(msg::JOIN_EXISTING) },
                    Button { item: Item::ReplaceExisting, label: fill(&tr(msg::REPLACE_EXISTING), &b.name) },
                    Button { item: Item::OpenBlocker, label: fill(&tr(msg::OPEN_FIRST), &b.name) },
                    decline(),
                ],
                uses: Vec::new(),
            })
        }
        Note::Attention("several") => Some(Banner {
            text: tr(msg::BANNER_SEVERAL),
            buttons: vec![decline()],
            uses: candidates.iter().map(|c| (c.clone(), fill(&tr(msg::USE_THIS), c))).collect(),
        }),
        // Which file to mend is what the person needs: they are named. Nothing
        // to press -- mending it is outside Polter, and it comes back by itself.
        Note::Attention("unreadable") => Some(Banner {
            text: if unreadable.is_empty() { reason(why, "", tr) } else { fill(&tr(msg::BANNER_UNREADABLE), &unreadable.join(", ")) },
            buttons: Vec::new(),
            uses: Vec::new(),
        }),
        Note::Attention(_) => Some(Banner {
            text: reason(why, "", tr),
            buttons: vec![Button { item: Item::LinkExisting, label: tr(msg::LINK_EXISTING_DOTS) }, decline()],
            uses: Vec::new(),
        }),
        _ => None,
    }
}

/// One answer in the task dialog: a command link, its words under it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub answer: Answer,
    pub label: String,
    pub note: String,
}

/// What the person answered the confirmation with (§3.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    Join,
    Replace,
    /// Also what Escape and closing the dialog mean.
    NotNow,
    Decline,
}

/// The confirmation (v2 B1) as a task dialog: the main instruction, the
/// content, and the four command links in order, "Join and Link" first
/// (and the default), "This Group Has No Project" last, furthest from it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JoinQuestion {
    pub main: String,
    pub body: String,
    pub links: Vec<Link>,
}

pub fn join_question(b: &Blocker, tr: &dyn Fn(&str) -> String) -> JoinQuestion {
    let pages = b.pages.to_string();
    JoinQuestion {
        main: fill(&tr(msg::JOIN_MAIN), &b.name),
        body: fill_all(&tr(msg::JOIN_BODY), &[&b.name, &b.saved, &pages]),
        links: vec![
            Link { answer: Answer::Join, label: tr(msg::JOIN_EXISTING), note: tr(msg::JOIN_NOTE) },
            Link { answer: Answer::Replace, label: fill(&tr(msg::REPLACE_EXISTING), &b.name), note: tr(msg::REPLACE_NOTE) },
            Link { answer: Answer::NotNow, label: tr(msg::NOT_NOW), note: tr(msg::NOT_NOW_NOTE) },
            Link { answer: Answer::Decline, label: tr(msg::DECLINE_PROJECT), note: tr(msg::DECLINE_NOTE) },
        ],
    }
}

/// Replacing, asked a second time: "Replace" is the default and is not
/// red -- what it replaces is kept as the previous version.
pub fn replace_question(name: &str, tab: &str, panes: usize, tr: &dyn Fn(&str) -> String) -> Question {
    let panes = panes.to_string();
    Question {
        main: fill(&tr(msg::REPLACE_MAIN), name),
        body: format!("{}\n\n{}", fill_all(&tr(msg::REPLACE_BODY), &[name, tab, &panes]), fill(&tr(msg::REPLACE_RESTORE), name)),
        buttons: vec![tr(msg::REPLACE), tr(msg::CANCEL)],
        default: 0,
        warning: false,
    }
}

/// "Stop Using It as This Group's Project…": the question, and the words of
/// its tick box, which starts unticked.
pub fn unlink_question(name: &str, group: &str, tr: &dyn Fn(&str) -> String) -> (Question, String) {
    (
        Question {
            main: fill_all(&tr(msg::UNLINK_MAIN), &[name, group]),
            body: tr(msg::UNLINK_BODY),
            buttons: vec![tr(msg::UNLINK), tr(msg::CANCEL)],
            default: 0,
            warning: false,
        },
        tr(msg::UNLINK_ALSO_DELETE),
    )
}

/// What a line saying a project was made is about, and so what undoing it
/// does (§3.2). Each carries what the undoing needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Made {
    /// The core's `create`: the file, to go to the Recycle Bin.
    Created { name: String, path: String },
    /// The core's `bind`: the name it had, to be given back.
    Renamed { from: String, to: String, path: String },
    /// "Join and Link": the page added, to be taken out again.
    Joined { name: String, path: String },
    /// "Replace…": the previous version, to be put back.
    Replaced { name: String, path: String },
}

impl Made {
    pub fn name(&self) -> &str {
        match self {
            Made::Created { name, .. } | Made::Joined { name, .. } | Made::Replaced { name, .. } => name,
            Made::Renamed { to, .. } => to,
        }
    }
}

/// The line's words; `short` for the narrow copy in the supervisor's tab.
pub fn hint_text(made: &Made, short: bool, tr: &dyn Fn(&str) -> String) -> String {
    if short {
        return fill(&tr(msg::HINT_SHORT), made.name());
    }
    match made {
        Made::Created { name, .. } => fill(&tr(msg::HINT_CREATED), name),
        // A `bind` that did not rename: the tab was in a project with the
        // group's name already.
        Made::Renamed { from, to, .. } if from == to => fill(&tr(msg::HINT_BOUND), to),
        Made::Renamed { from, to, .. } => fill_all(&tr(msg::HINT_RENAMED), &[from, to]),
        Made::Joined { name, .. } => fill(&tr(msg::HINT_JOINED), name),
        Made::Replaced { name, .. } => fill(&tr(msg::HINT_REPLACED), name),
    }
}

/// The line that stays after Undo, with its ✕ and no button.
pub fn undone_text(made: &Made, tr: &dyn Fn(&str) -> String) -> String {
    match made {
        Made::Created { name, .. } => fill(&tr(msg::UNDONE_CREATED), name),
        Made::Renamed { from, to, .. } if from == to => fill(&tr(msg::UNDONE_BOUND), to),
        Made::Renamed { from, .. } => fill(&tr(msg::UNDONE_RENAMED), from),
        Made::Joined { name, .. } => fill(&tr(msg::UNDONE_JOINED), name),
        Made::Replaced { name, .. } => fill(&tr(msg::UNDONE_REPLACED), name),
    }
}

/// One step of undoing, in order (§3.2). **The group is said to have no
/// project first**: otherwise the core's next `offer` makes it again, and
/// the undo was for nothing. None of the steps touches a running terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UndoStep {
    /// `project_decline` for the group.
    Decline,
    /// The product's "Delete Project": into the Recycle Bin.
    Recycle { path: String },
    /// Give the project back the name it had and take the group's off it.
    RenameBack { path: String, to: String },
    /// The tabs stop being pages of the project, and its file is left as
    /// it is: what has to happen before the file can be moved or put back,
    /// or the next save of an open tab writes over it.
    LetGo { path: String },
    /// Put the previous version back, byte for byte.
    RestorePrevious { path: String },
}

/// The same steps as the macOS host's (`ProjectLinkPlan.undo`).
pub fn undo_steps(made: &Made) -> Vec<UndoStep> {
    let mut steps = vec![UndoStep::Decline];
    match made {
        Made::Created { path, .. } => steps.extend([UndoStep::LetGo { path: path.clone() }, UndoStep::Recycle { path: path.clone() }]),
        Made::Renamed { from, path, .. } => steps.push(UndoStep::RenameBack { path: path.clone(), to: from.clone() }),
        // **The file as it was before the join, byte for byte** (task 1714,
        // after the first macOS test run): the join's own write kept it as
        // the previous version, and taking the page out instead would write
        // again and rotate it away -- the way back for an old file nothing
        // else has a copy of.
        Made::Joined { path, .. } | Made::Replaced { path, .. } => {
            steps.extend([UndoStep::LetGo { path: path.clone() }, UndoStep::RestorePrevious { path: path.clone() }])
        }
    }
    steps
}

/// Whether the host should put the confirmation up now (§2): the core says
/// to (`ask`), the person is there -- the window in front, with the control
/// room or the supervisor's tab in front of it -- and it has not been put
/// up for this group yet this run. Only selecting the group's row is not
/// enough: that is looking, not doing.
pub fn should_ask(ask: bool, window_in_front: bool, showing_control_room_or_supervisor: bool, asked_this_run: bool) -> bool {
    ask && window_in_front && showing_control_room_or_supervisor && !asked_this_run
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project_link::{menu, note};

    fn en(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn every_item_the_menu_can_offer_has_words() {
        let whys = [
            "none", "pending", "not_taken_up", "declined", "project_name_taken", "several_projects", "project_has_group",
            "supervisor_has_project", "supervisor_of_several", "other_supervisor", "no_supervisor", "projects_unknown",
            "project_unreadable",
        ];
        for tie in ["undecided", "bound", "declined"] {
            for why in whys {
                for steward in [false, true] {
                    for item in menu(tie, why, steward) {
                        let words = item_label(&item, "web", "notes", &en);
                        assert!(!words.is_empty(), "{tie} {why} {steward} {}", item.id());
                        assert!(!words.contains("{}"), "{words}");
                    }
                }
            }
        }
    }

    #[test]
    fn the_menu_names_the_project_and_the_group_where_it_should() {
        let open = item_label(&Item::OpenProject, "web", "notes", &en);
        assert_eq!(open, "Open Project “web”");
        let save = item_label(&Item::SaveSupervisorTab, "web", "notes", &en);
        assert_eq!(save, "Save the Supervisor's Tab as Project “notes”");
    }

    #[test]
    fn a_project_that_is_another_groups_is_grey_and_says_whose() {
        let projects = vec![("scratch".to_string(), None), ("website".to_string(), Some("web".to_string()))];
        let c = link_choices(&projects, &en);
        assert_eq!(c[0], Choice { name: "scratch".into(), label: "scratch — in no group".into(), enabled: true });
        assert_eq!(c[1].label, "website — group “web”");
        let grey = !c[1].enabled;
        assert!(grey);
    }

    #[test]
    fn the_row_says_a_short_word_and_the_banner_asks() {
        let n = note("undecided", "project_name_taken", None);
        assert_eq!(note_word(&n, &en).as_deref(), Some("Same-name project"));
        let b = Blocker { name: "polter".into(), saved: "13 Oct".into(), pages: 1 };
        let banner = banner(&n, "project_name_taken", Some(&b), &[], &[], &en).expect("one to answer");
        assert!(banner.text.contains("“polter” (13 Oct, 1 pages)"), "{}", banner.text);
        let order: Vec<String> = banner.buttons.iter().map(|b| b.item.id()).collect();
        assert_eq!(order, ["join_existing", "replace_existing", "open_blocker", "decline_project"]);
        // A bound group, and one with nothing to answer, have none.
        assert_eq!(banner_of("bound", "none"), None);
        assert_eq!(banner_of("undecided", "not_taken_up"), None);
    }

    fn banner_of(tie: &str, why: &str) -> Option<Banner> {
        banner(&note(tie, why, Some("web")), why, None, &[], &[], &en)
    }

    /// Task 1807: a group kept for a project whose file does not read says
    /// so, before its name, and names the files to mend; nothing to press.
    #[test]
    fn a_kept_project_whose_file_does_not_read_names_the_file() {
        let n = note("bound", "project_unreadable", Some("web"));
        assert_eq!(n.said(), "attention:unreadable");
        assert_eq!(note_word(&n, &en).as_deref(), Some("Project file unreadable"));
        let files = ["web.json".to_string(), "notes.json".to_string()];
        let b = banner(&n, "project_unreadable", None, &[], &files, &en).expect("one to say");
        assert!(b.text.contains("web.json, notes.json"), "{}", b.text);
        assert!(!b.text.contains("{}"), "{}", b.text);
        assert!(b.buttons.is_empty() && b.uses.is_empty());
        // The same project, read: its name as ever.
        assert_eq!(note("bound", "none", Some("web")).said(), "name:web");
    }

    #[test]
    fn the_confirmation_puts_join_first_and_no_project_last() {
        let b = Blocker { name: "polter".into(), saved: "13 Oct".into(), pages: 1 };
        let q = join_question(&b, &en);
        let answers: Vec<Answer> = q.links.iter().map(|l| l.answer).collect();
        assert_eq!(answers, [Answer::Join, Answer::Replace, Answer::NotNow, Answer::Decline]);
        assert_eq!(q.main, "There is already a project “polter”. Add the supervisor's tab to it?");
        let replace = replace_question("polter", "polter", 2, &en);
        assert_eq!(replace.default, 0);
        let not_red = !replace.warning;
        assert!(not_red);
    }

    #[test]
    fn undoing_says_the_group_has_no_project_before_it_undoes() {
        let go = || UndoStep::LetGo { path: "p".into() };
        let cases = [
            (Made::Created { name: "notes".into(), path: "p".into() }, vec![go(), UndoStep::Recycle { path: "p".into() }]),
            (
                Made::Renamed { from: "scratch".into(), to: "notes".into(), path: "p".into() },
                vec![UndoStep::RenameBack { path: "p".into(), to: "scratch".into() }],
            ),
            // Put back as it was, not a page taken out (which writes).
            (Made::Joined { name: "polter".into(), path: "p".into() }, vec![go(), UndoStep::RestorePrevious { path: "p".into() }]),
            (Made::Replaced { name: "polter".into(), path: "p".into() }, vec![go(), UndoStep::RestorePrevious { path: "p".into() }]),
        ];
        for (made, back) in cases {
            let steps = undo_steps(&made);
            let mut want = vec![UndoStep::Decline];
            want.extend(back);
            assert_eq!(steps, want, "{made:?}");
            let words = undone_text(&made, &en);
            assert!(words.contains("this group has no project"), "{words}");
        }
    }

    #[test]
    fn the_hint_names_what_was_made() {
        let renamed = Made::Renamed { from: "scratch".into(), to: "notes".into(), path: "p".into() };
        let words = hint_text(&renamed, false, &en);
        assert_eq!(words, "The supervisor's tab was in project “scratch”; it was renamed “notes”, this group's project.");
        let short = hint_text(&renamed, true, &en);
        assert_eq!(short, "Saved as project “notes”, this group's.");
    }

    #[test]
    fn the_confirmation_waits_for_the_person_and_comes_once() {
        let now = should_ask(true, true, true, false);
        assert!(now);
        let core_did_not_say = should_ask(false, true, true, false);
        assert!(!core_did_not_say);
        let away = should_ask(true, false, true, false);
        assert!(!away);
        let elsewhere = should_ask(true, true, false, false);
        assert!(!elsewhere);
        let again = should_ask(true, true, true, true);
        assert!(!again);
    }
}
