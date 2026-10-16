//! What the menu on a group's row of the list holds (task 1661; the user
//! chose the design in `control-room-design/v21/`): which items, in which
//! groups, for what the core says of the group. Which item does what, and
//! how it is drawn, is the host's.
//!
//! **One rule on both hosts.** The macOS host's
//! `ControlRoomRowMenu.swift` is the same rule, and
//! `tools/control-room-hosts-agree.py` prints it for every state on both
//! sides and holds the two to one answer.
//!
//! The rule, from the top: where to go (the supervisor, or starting one);
//! asking the supervisor to do something; finding the group; how it stands
//! in the list; changing it; putting it away. Items that need a supervisor
//! are left out -- not greyed -- when there is none: a menu holds only what
//! can be used. A group left empty goes with its separator, and there is no
//! separator at either end. An archived group's menu has three items only.

use crate::n_;

/// The group's supervisor, as far as the menu cares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sup {
    /// None at all.
    None,
    /// One, whose hooks report its state.
    Hooked,
    /// One that reports nothing: started by hand (task 1635). The control
    /// room can take it over.
    Hookless,
}

impl Sup {
    pub const ALL: [Sup; 3] = [Sup::None, Sup::Hooked, Sup::Hookless];

    /// How the comparison spells it.
    pub fn name(self) -> &'static str {
        match self {
            Sup::None => "none",
            Sup::Hooked => "hooked",
            Sup::Hookless => "hookless",
        }
    }
}

/// The supervisor of the group on `row`, as the menu needs it (task 1635):
/// hookless only where the core offers to take it over -- the question it
/// would ask is in the snapshot. One it could not recognise, or is still
/// asking about, has nothing to offer here and is only jumped to. A
/// supervisor is one the frame has a title for: the core named it and it
/// is open -- what both hosts' rows carry. `ControlRoomRowMenu.supervisor(of:)`
/// is the macOS host's.
pub fn sup_of(row: &crate::list::Row) -> Sup {
    let Some(title) = &row.title else { return Sup::None };
    let offered = title.take_over.as_ref().is_some_and(|t| t.offered && t.confirm.is_some());
    if offered { Sup::Hookless } else { Sup::Hooked }
}

/// What the menu is made from: what the core says of the group.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct State {
    pub archived: bool,
    pub sup: Sup,
    /// The last supervisor's session can be gone on with. Only asked when
    /// there is no supervisor.
    pub resumable: bool,
    pub pinned: bool,
    pub muted: bool,
}

/// One line of the menu.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Entry {
    /// An item, by its id; `submenu` when it opens one (`submenu`).
    Item { id: &'static str, submenu: bool },
    Separator,
}

/// The menu for a group in `state`, top to bottom.
pub fn entries(state: State) -> Vec<Entry> {
    let item = |id: &'static str| Entry::Item { id, submenu: false };
    let opens = |id: &'static str| Entry::Item { id, submenu: true };
    let groups: Vec<Vec<Entry>> = if state.archived {
        vec![vec![item("reveal")], vec![item("unarchive")], vec![item("delete")]]
    } else {
        let has = state.sup != Sup::None;
        let go: Vec<Entry> = match state.sup {
            Sup::Hooked => vec![item("jump_to_supervisor")],
            Sup::Hookless => vec![item("jump_to_supervisor"), item("take_over")],
            Sup::None if state.resumable => vec![item("start_resume"), item("start_new")],
            Sup::None => vec![item("start")],
        };
        let ask: Vec<Entry> = if has { vec![item("report_progress"), item("close_idle_workers")] } else { Vec::new() };
        let find: Vec<Entry> = if has { vec![item("reveal"), item("copy_supervisor_id")] } else { vec![item("reveal")] };
        let stand = vec![item(if state.pinned { "unpin" } else { "pin" }), if state.muted { item("unmute") } else { opens("mute") }];
        let change = vec![item("rename"), item("edit_note"), opens("project")];
        let away = vec![item("archive"), item("delete")];
        vec![go, ask, find, stand, change, away]
    };
    let mut out = Vec::new();
    for group in groups.into_iter().filter(|g| !g.is_empty()) {
        if !out.is_empty() {
            out.push(Entry::Separator);
        }
        out.extend(group);
    }
    out
}

/// The items of the submenu item `id` opens, top to bottom; none for an
/// item that opens none. Which of the project's are greyed is the core's
/// to say (what project the group has), and is not part of this rule.
pub fn submenu(id: &str) -> &'static [&'static str] {
    match id {
        "mute" => &["mute_hour", "mute_tomorrow", "mute_forever"],
        "project" => &["open_project", "save_project", "link_project"],
        _ => &[],
    }
}

/// How the comparison prints one state's menu: the ids, a submenu's with
/// `>` after it, and `-` for a separator.
pub fn line(state: State) -> String {
    let items: Vec<String> = entries(state)
        .into_iter()
        .map(|e| match e {
            Entry::Item { id, submenu: true } => format!("{id}>"),
            Entry::Item { id, submenu: false } => id.to_string(),
            Entry::Separator => "-".to_string(),
        })
        .collect();
    format!(
        "group_menu archived={} sup={} resumable={} pinned={} muted={} items={}",
        u8::from(state.archived),
        state.sup.name(),
        u8::from(state.resumable),
        u8::from(state.pinned),
        u8::from(state.muted),
        items.join(" ")
    )
}

/// Every state, in the comparison's order: archived 0, 1 × sup none,
/// hooked, hookless × resumable 0, 1 × pinned 0, 1 × muted 0, 1.
pub fn every_state() -> Vec<State> {
    let mut out = Vec::new();
    for archived in [false, true] {
        for sup in Sup::ALL {
            for resumable in [false, true] {
                for pinned in [false, true] {
                    for muted in [false, true] {
                        out.push(State { archived, sup, resumable, pinned, muted });
                    }
                }
            }
        }
    }
    out
}

/// What each item is called on Windows, in English; the host passes it
/// through its translation (`po/`). "Show in Explorer" is this host's
/// word; the macOS host says Finder.
pub fn label(id: &str) -> Option<&'static str> {
    Some(match id {
        "jump_to_supervisor" => n_("Go to Supervisor"),
        "take_over" => n_("Let the Control Room Take Over…"),
        "start_resume" => n_("Start Supervisor, Going On with the Last Session"),
        "start_new" => n_("Start Supervisor with a New Session"),
        "start" => n_("Start Supervisor"),
        "report_progress" => n_("Ask the Supervisor for a Progress Report"),
        "close_idle_workers" => n_("Ask the Supervisor to Close Idle Workers"),
        "reveal" => n_("Show in Explorer"),
        "copy_supervisor_id" => n_("Copy Supervisor's Terminal ID"),
        "pin" => n_("Pin"),
        "unpin" => n_("Unpin"),
        "mute" => n_("Mute This Group's Notifications"),
        "unmute" => n_("Unmute"),
        "mute_hour" => n_("For 1 Hour"),
        "mute_tomorrow" => n_("Until Tomorrow"),
        "mute_forever" => n_("Until Turned Back On"),
        "rename" => n_("Rename Group…"),
        "edit_note" => n_("Edit Group Note…"),
        "project" => n_("Project"),
        "open_project" => n_("Load Project…"),
        "save_project" => n_("Save as Project…"),
        "link_project" => n_("Link to Project…"),
        "archive" => n_("Archive…"),
        "unarchive" => n_("Unarchive"),
        "delete" => n_("Delete Group…"),
        _ => return None,
    })
}

/// The words in the right-hand column of an item, untranslated and with
/// the time to put in them (`list::fill`): when a mute from the submenu
/// would end, and when the one in force does. `until_ms` is wall-clock
/// milliseconds, `offset_ms` how far local time is ahead of UTC. Today is
/// "until 15:40", tomorrow "until tomorrow 9:00"; further off, the date
/// too. None for an item that says no time (and for a mute that has none).
pub fn when(until_ms: u64, now_ms: u64, offset_ms: i64) -> (&'static str, String) {
    const DAY: i64 = 86_400_000;
    let local = |ms: u64| ms as i64 + offset_ms;
    let (at, now) = (local(until_ms), local(now_ms));
    let days = at.div_euclid(DAY) - now.div_euclid(DAY);
    let minutes = at.rem_euclid(DAY) / 60_000;
    let clock = format!("{}:{:02}", minutes / 60, minutes % 60);
    match days {
        ..=0 => (msg::UNTIL, clock),
        1 => (msg::UNTIL_TOMORROW, clock),
        _ => {
            let (_, m, d) = civil(at.div_euclid(DAY));
            (msg::UNTIL, format!("{m}-{d:02} {clock}"))
        }
    }
}

/// The year, month and day of a count of days since 1970-01-01.
pub(crate) fn civil(days: i64) -> (i64, i64, i64) {
    // Howard Hinnant's days_from_civil, backwards.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

pub mod msg {
    use crate::n_;
    /// "{}" is a time, or a date and a time.
    pub const UNTIL: &str = n_("until {}");
    pub const UNTIL_TOMORROW: &str = n_("until tomorrow {}");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(state: State) -> String {
        line(state).split(" items=").nth(1).unwrap().to_string()
    }

    fn st(archived: bool, sup: Sup, resumable: bool, pinned: bool, muted: bool) -> State {
        State { archived, sup, resumable, pinned, muted }
    }

    /// The four menus of `02-menu-four-states`, item for item.
    #[test]
    fn the_four_menus_the_user_chose() {
        assert_eq!(
            ids(st(false, Sup::Hooked, false, false, false)),
            "jump_to_supervisor - report_progress close_idle_workers - reveal copy_supervisor_id - pin mute> - rename edit_note project> - archive delete"
        );
        assert_eq!(
            ids(st(false, Sup::None, true, false, false)),
            "start_resume start_new - reveal - pin mute> - rename edit_note project> - archive delete"
        );
        assert_eq!(
            ids(st(false, Sup::Hookless, false, false, false)),
            "jump_to_supervisor take_over - report_progress close_idle_workers - reveal copy_supervisor_id - pin mute> - rename edit_note project> - archive delete"
        );
        assert_eq!(
            ids(st(false, Sup::Hooked, false, true, true)),
            "jump_to_supervisor - report_progress close_idle_workers - reveal copy_supervisor_id - unpin unmute - rename edit_note project> - archive delete"
        );
    }

    #[test]
    fn an_old_group_with_no_session_has_one_start_and_an_archived_one_three_items() {
        assert_eq!(ids(st(false, Sup::None, false, false, false)), "start - reveal - pin mute> - rename edit_note project> - archive delete");
        for sup in Sup::ALL {
            assert_eq!(ids(st(true, sup, true, true, true)), "reveal - unarchive - delete");
        }
    }

    /// No separator at an end or next to another, whatever the state;
    /// every item has words.
    #[test]
    fn no_menu_has_an_empty_group_and_every_item_is_named() {
        let states = every_state();
        assert_eq!(states.len(), 48);
        for s in states {
            let e = entries(s);
            assert!(!matches!(e.first(), Some(Entry::Separator) | None), "{s:?}");
            assert!(!matches!(e.last(), Some(Entry::Separator)), "{s:?}");
            assert!(!e.windows(2).any(|w| w[0] == Entry::Separator && w[1] == Entry::Separator), "{s:?}");
            for item in e {
                if let Entry::Item { id, submenu: opens } = item {
                    assert!(label(id).is_some(), "{id}");
                    assert_eq!(opens, !submenu(id).is_empty(), "{id}");
                    for sub in submenu(id) {
                        assert!(label(sub).is_some(), "{sub}");
                    }
                }
            }
        }
    }

    #[test]
    fn a_mute_says_when_it_ends_by_the_local_clock() {
        const HOUR: u64 = 3_600_000;
        let offset = 8 * HOUR as i64;
        // 2026-10-16 15:40 in Shanghai.
        let now = 1_792_136_400_000;
        assert_eq!(when(now + HOUR, now, offset), (msg::UNTIL, "16:40".to_string()));
        assert_eq!(when(1_792_198_800_000, now, offset), (msg::UNTIL_TOMORROW, "9:00".to_string()));
        assert_eq!(when(1_792_198_800_000 + 3 * 24 * HOUR, now, offset), (msg::UNTIL, "10-20 9:00".to_string()));
        // Past midnight, local: tomorrow, though UTC is the same day.
        assert_eq!(when(now + 9 * HOUR, now, offset), (msg::UNTIL_TOMORROW, "0:40".to_string()));
    }
}
