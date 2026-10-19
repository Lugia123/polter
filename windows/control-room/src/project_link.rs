//! The rules for what the person sees of a group's project and can do about
//! it (task 1714, `project-link-interface.md` §3): the group's "Project ›"
//! menu, the words at the right end of its row, and how long the line
//! saying a project was made for it stays.
//!
//! **The macOS host has the same three** (`ProjectLinkRules.swift`):
//! `tools/control-room-hosts-agree.py` prints both over
//! `src/poltergeist/testdata/project_link_cases.json` and compares them
//! line by line. The core's words for the tie and the reason
//! (`ControlRoom.ProjectOut.tie`, `.why`) are taken as written.

use crate::look::group_note;

/// One item of the group's "Project ›" menu. The host words and wires each
/// by its id; a header is a line that says why and does nothing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Item {
    OpenProject,
    ShowInSettings,
    UnlinkProject,
    SaveSupervisorTab,
    LinkExisting,
    DeclineProject,
    UndeclineProject,
    JoinExisting,
    ReplaceExisting,
    OpenBlocker,
    Header(String),
}

impl Item {
    /// The id the hosts agree on.
    pub fn id(&self) -> String {
        match self {
            Item::OpenProject => "open_project".into(),
            Item::ShowInSettings => "show_in_settings".into(),
            Item::UnlinkProject => "unlink_project".into(),
            Item::SaveSupervisorTab => "save_supervisor_tab".into(),
            Item::LinkExisting => "link_existing".into(),
            Item::DeclineProject => "decline_project".into(),
            Item::UndeclineProject => "undecline_project".into(),
            Item::JoinExisting => "join_existing".into(),
            Item::ReplaceExisting => "replace_existing".into(),
            Item::OpenBlocker => "open_blocker".into(),
            Item::Header(why) => format!("header:{why}"),
        }
    }
}

/// The reasons a tie was not made that the person can do something about
/// by linking another project (`Projects.Why`).
pub const NOT_MADE: [&str; 4] = ["project_has_group", "supervisor_has_project", "supervisor_of_several", "other_supervisor"];

fn not_made(why: &str) -> bool {
    NOT_MADE.contains(&why)
}

/// What the group's "Project ›" menu offers, in order (§3.3). Only what can
/// be done is listed; a group whose projects are not known yet has only
/// the line saying so. `steward`: the group has a supervisor on screen,
/// whose tab could be saved.
pub fn menu(tie: &str, why: &str, steward: bool) -> Vec<Item> {
    if tie == "bound" {
        return vec![Item::OpenProject, Item::ShowInSettings, Item::UnlinkProject];
    }
    if tie == "declined" {
        return vec![Item::UndeclineProject];
    }
    match why {
        "projects_unknown" => vec![Item::Header(why.into())],
        "project_name_taken" => vec![
            Item::Header(why.into()),
            Item::JoinExisting,
            Item::ReplaceExisting,
            Item::OpenBlocker,
            Item::DeclineProject,
        ],
        // The candidates are the host's to list, under the header.
        "several_projects" => vec![Item::Header(why.into()), Item::DeclineProject],
        _ if not_made(why) => vec![Item::Header(why.into()), Item::LinkExisting, Item::DeclineProject],
        _ if steward => vec![Item::SaveSupervisorTab, Item::LinkExisting, Item::DeclineProject],
        _ => vec![Item::LinkExisting, Item::DeclineProject],
    }
}

/// What the right end of a group's row says of its project (§3.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Note {
    None,
    /// The project's name, in the second ink.
    Name(String),
    /// The attention glyph and a short word: there is something to answer.
    /// The word's key: `name_taken`, `several`, `not_made`, `unreadable`.
    Attention(&'static str),
}

impl Note {
    /// How the hosts agree to write it.
    pub fn said(&self) -> String {
        match self {
            Note::None => "none".into(),
            Note::Name(n) => format!("name:{n}"),
            Note::Attention(w) => format!("attention:{w}"),
        }
    }
}

pub fn note(tie: &str, why: &str, name: Option<&str>) -> Note {
    // Kept, and its file does not read (task 1807): that, before its name.
    if tie == "bound" && why == "project_unreadable" {
        return Note::Attention("unreadable");
    }
    if tie == "bound" {
        if let Some(name) = name {
            return Note::Name(name.into());
        }
    }
    if tie != "undecided" {
        return Note::None;
    }
    match why {
        "project_name_taken" => Note::Attention("name_taken"),
        "several_projects" => Note::Attention("several"),
        _ if not_made(why) => Note::Attention("not_made"),
        _ => Note::None,
    }
}

/// How long the line saying a project was made for a group stays (§3.2):
/// `group_note::FEEDBACK_SECONDS` of being seen -- the window in front and
/// the line on screen -- added up; time not seen does not count, and ✕
/// takes it away at once.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HintClock {
    /// Seconds seen so far.
    pub seen: f64,
    /// When it was last looked at, and whether it was seen then.
    pub last: Option<(f64, bool)>,
    pub closed: bool,
}

impl HintClock {
    pub const LASTS: f64 = group_note::FEEDBACK_SECONDS;

    /// Look at it at `at`: the time since the last look counts when it was
    /// seen then.
    pub fn look(&mut self, at: f64, visible: bool) {
        if let Some((then, seen)) = self.last {
            if seen {
                self.seen += (at - then).max(0.0);
            }
        }
        self.last = Some((at, visible));
    }

    pub fn close(&mut self) {
        self.closed = true;
    }

    pub fn gone(&self) -> bool {
        self.closed || self.seen >= Self::LASTS
    }

    pub fn remaining(&self) -> f64 {
        if self.gone() {
            0.0
        } else {
            Self::LASTS - self.seen
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(items: Vec<Item>) -> Vec<String> {
        items.iter().map(Item::id).collect()
    }

    #[test]
    fn a_bound_group_opens_shows_or_lets_go_of_its_project() {
        let got = ids(menu("bound", "none", false));
        assert_eq!(got, ["open_project", "show_in_settings", "unlink_project"]);
    }

    #[test]
    fn only_a_group_with_its_supervisor_on_screen_offers_to_save_its_tab() {
        let with = ids(menu("undecided", "not_taken_up", true));
        assert_eq!(with, ["save_supervisor_tab", "link_existing", "decline_project"]);
        let without = ids(menu("undecided", "not_taken_up", false));
        assert_eq!(without, ["link_existing", "decline_project"]);
    }

    #[test]
    fn a_taken_name_offers_the_four_answers_under_its_header() {
        let got = ids(menu("undecided", "project_name_taken", true));
        assert_eq!(
            got,
            ["header:project_name_taken", "join_existing", "replace_existing", "open_blocker", "decline_project"]
        );
    }

    #[test]
    fn a_tie_not_made_offers_another_project_whoever_is_on_screen() {
        for why in NOT_MADE {
            let got = ids(menu("undecided", why, true));
            assert_eq!(got, [format!("header:{why}"), "link_existing".into(), "decline_project".into()], "{why}");
        }
    }

    #[test]
    fn unknown_projects_offer_nothing_but_saying_so_and_declined_only_the_way_back() {
        let unknown = ids(menu("undecided", "projects_unknown", true));
        assert_eq!(unknown, ["header:projects_unknown"]);
        let declined = ids(menu("declined", "declined", true));
        assert_eq!(declined, ["undecline_project"]);
    }

    #[test]
    fn the_row_names_a_bound_project_and_flags_what_needs_an_answer() {
        assert_eq!(note("bound", "none", Some("web")), Note::Name("web".into()));
        assert_eq!(note("undecided", "project_name_taken", None).said(), "attention:name_taken");
        assert_eq!(note("undecided", "several_projects", None).said(), "attention:several");
        assert_eq!(note("undecided", "other_supervisor", None).said(), "attention:not_made");
        // Nothing to answer: nothing said.
        assert_eq!(note("undecided", "not_taken_up", None), Note::None);
        assert_eq!(note("declined", "project_name_taken", None), Note::None);
    }

    #[test]
    fn the_hint_counts_only_time_it_was_seen() {
        let mut c = HintClock::default();
        c.look(0.0, true);
        c.look(3.0, false);
        c.look(60.0, true);
        let remaining = c.remaining();
        assert_eq!(remaining, HintClock::LASTS - 3.0);
        c.look(66.0, true);
        let gone = c.gone();
        assert!(gone);
    }

    #[test]
    fn closing_the_hint_takes_it_away_at_once() {
        let mut c = HintClock::default();
        c.look(0.0, true);
        c.close();
        let gone = c.gone();
        assert!(gone);
        assert_eq!(c.remaining(), 0.0);
    }
}
