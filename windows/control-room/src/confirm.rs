//! The two questions the menu on a group's row asks before it acts (task
//! 1661, design v21 `06`): archiving, which can be undone and so says yes
//! on Return, and deleting, which cannot and so says no on Return. What
//! each says comes from what the core says of the group; the host shows it
//! in its one question box and sends the act on the first button.
//!
//! The words are the design's, with the product's own word for a group's
//! brief (「群简介」).

use crate::list::{fill, Row};
use crate::snapshot::DeleteCost;

/// A question, as the host's box takes it: the buttons in order, **the last
/// the one that does nothing** (Escape presses it), and which Return
/// presses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Question {
    pub main: String,
    pub body: String,
    pub buttons: Vec<String>,
    pub default: usize,
    /// The warning sign: on a question whose yes cannot be undone.
    pub warning: bool,
}

pub mod msg {
    use crate::n_;
    pub const ARCHIVE_MAIN: &str = n_("Archive {}?");
    pub const ARCHIVE_BODY: &str = n_("It goes into “Archived” at the bottom of the list, and you are not notified about it any more. Its chat, tasks, brief and project are all kept; right-click it in “Archived” and choose “Unarchive” to bring it back.");
    pub const ARCHIVE_RUNNING: &str = n_("The supervisor is still running. Archiving does not close its terminal or its workers'.");
    pub const ARCHIVE: &str = n_("Archive");
    pub const CANCEL: &str = n_("Cancel");
    pub const DELETE_MAIN: &str = n_("Delete the group {}?");
    pub const DELETE_MEMBERS_AND_TASKS: &str = n_("This group still has {} members and {} unfinished tasks. Deleting does not close their terminals, but they leave the group, and the unfinished tasks are deleted too.");
    pub const DELETE_MEMBERS: &str = n_("This group still has {} members. Deleting does not close their terminals, but they leave the group.");
    pub const DELETE_TASKS: &str = n_("This group still has {} unfinished tasks. They are deleted with it.");
    pub const DELETE_GONE: &str = n_("Its chat, task panel and brief are deleted with it, and cannot be recovered.");
    pub const DELETE_PROJECT: &str = n_("The project {} stays; it just no longer belongs to any group.");
    pub const DELETE_RATHER: &str = n_("If you would rather not delete this much, archive it instead.");
    pub const DELETE: &str = n_("Delete Group");
}

/// Fill the `{}`s of `template` in order.
fn fill_all(template: &str, args: &[&str]) -> String {
    args.iter().fold(template.to_string(), |t, a| fill(&t, a))
}

/// "Archive {group}?" -- Return archives (it can be undone).
pub fn archive(row: &Row, tr: &dyn Fn(&str) -> String) -> Question {
    let mut body = tr(msg::ARCHIVE_BODY);
    if row.steward.is_some() {
        body.push_str("\n\n");
        body.push_str(&tr(msg::ARCHIVE_RUNNING));
    }
    Question {
        main: fill(&tr(msg::ARCHIVE_MAIN), row.name()),
        body,
        buttons: vec![tr(msg::ARCHIVE), tr(msg::CANCEL)],
        default: 0,
        warning: false,
    }
}

/// "Delete the group {group}?" -- Return cancels (it cannot be undone).
/// With members or unfinished tasks it says how many first, as the core
/// counted them; `cost` is what the delete hands back.
pub fn delete(name: &str, cost: DeleteCost, project: Option<&str>, tr: &dyn Fn(&str) -> String) -> Question {
    let (m, t) = (cost.members.to_string(), cost.open_tasks.to_string());
    let mut parts = Vec::new();
    match (cost.members, cost.open_tasks) {
        (0, 0) => {}
        (_, 0) => parts.push(format!("\u{26a0} {}", fill_all(&tr(msg::DELETE_MEMBERS), &[&m]))),
        (0, _) => parts.push(format!("\u{26a0} {}", fill_all(&tr(msg::DELETE_TASKS), &[&t]))),
        _ => parts.push(format!("\u{26a0} {}", fill_all(&tr(msg::DELETE_MEMBERS_AND_TASKS), &[&m, &t]))),
    }
    parts.push(tr(msg::DELETE_GONE));
    let mut last = String::new();
    if let Some(p) = project.filter(|p| !p.is_empty()) {
        last.push_str(&fill(&tr(msg::DELETE_PROJECT), p));
        // A sentence that ends in an English full stop is followed by a
        // space; one in Chinese punctuation is not.
        if last.ends_with('.') {
            last.push(' ');
        }
    }
    last.push_str(&tr(msg::DELETE_RATHER));
    parts.push(last);
    Question {
        main: fill(&tr(msg::DELETE_MAIN), name),
        body: parts.join("\n\n"),
        buttons: vec![tr(msg::DELETE), tr(msg::CANCEL)],
        default: 1,
        warning: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn same(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn deleting_says_what_goes_and_says_no_on_return() {
        let plain = delete("notes", DeleteCost { members: 0, open_tasks: 0 }, None, &same);
        assert_eq!(plain.main, "Delete the group notes?");
        assert!(!plain.body.contains('\u{26a0}'));
        assert!(plain.body.starts_with(msg::DELETE_GONE));
        assert_eq!(plain.buttons, vec!["Delete Group", "Cancel"]);
        assert_eq!(plain.default, 1);
        assert!(plain.warning);
        let busy = delete("web-app", DeleteCost { members: 3, open_tasks: 4 }, Some("web-app"), &same);
        assert!(busy.body.starts_with("\u{26a0} This group still has 3 members and 4 unfinished tasks."), "{}", busy.body);
        assert!(busy.body.ends_with("The project web-app stays; it just no longer belongs to any group. If you would rather not delete this much, archive it instead."));
        assert!(delete("x", DeleteCost { members: 2, open_tasks: 0 }, None, &same).body.starts_with("\u{26a0} This group still has 2 members."));
        assert!(delete("x", DeleteCost { members: 0, open_tasks: 5 }, None, &same).body.starts_with("\u{26a0} This group still has 5 unfinished tasks."));
    }

    #[test]
    fn archiving_says_where_it_goes_and_says_yes_on_return() {
        const FIXTURE: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/poltergeist/testdata/control_snapshot.json"));
        let l = crate::list::List::from_snapshot(&crate::snapshot::decode(FIXTURE).unwrap());
        let with = l.rows().find(|r| r.steward.is_some()).unwrap();
        let q = archive(with, &same);
        assert_eq!(q.main, format!("Archive {}?", with.id));
        assert!(q.body.ends_with(msg::ARCHIVE_RUNNING));
        assert_eq!((q.buttons.clone(), q.default, q.warning), (vec!["Archive".to_string(), "Cancel".to_string()], 0, false));
        let mut none = with.clone();
        none.steward = None;
        assert_eq!(archive(&none, &same).body, msg::ARCHIVE_BODY);
    }
}
