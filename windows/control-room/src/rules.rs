//! The control room's tab: the decisions that need no window to make.
//!
//! The macOS host's `ControlRoomRules.swift` is the same thing. A host asks
//! these and does what they say; nothing here knows what a window is.
//!
//! The rulings marked 暂定 there are 暂定 here: it can be closed, there is
//! one in the application, it starts as the first tab and is not pulled back
//! when the person moves it.

/// What the menu item, the key binding and the command palette entry all do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trigger {
    /// It is open somewhere: go to it. Never a second one.
    Select,
    /// It is not open: open it as the asking window's first tab.
    OpenAsFirstTab,
}

/// `open` is how many control-room tabs the application holds right now, as
/// the host counted them under its lock. More than one is already a fault,
/// and the answer to it is still "go to one", never "make another".
pub fn trigger(open: usize) -> Trigger {
    if open == 0 {
        Trigger::OpenAsFirstTab
    } else {
        Trigger::Select
    }
}

/// A group the person has just made is selected once the core lists it --
/// not before: the list on screen when the answer comes back may be the one
/// from before the group existed, and a selection that names no row is
/// dropped (`list::restored_selection`). `awaited` is the name they gave it;
/// the answer is that name when a row has it. The macOS host's
/// `madeGroupToSelect`.
pub fn made_group_to_select<'a>(awaited: Option<&'a str>, list: &crate::list::List) -> Option<&'a str> {
    let awaited = awaited?;
    list.row(awaited).map(|_| awaited)
}

/// The name a new group is awaited under: what was typed, as the core
/// keeps it -- it trims the ends and makes nothing else of it.
pub fn made_group_name(typed: &str) -> &str {
    typed.trim()
}

/// Which window a tab the core asked for goes into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Home {
    /// The window of the terminal the tab was asked from -- its own tab's,
    /// wherever it is being shown at the moment.
    Askers,
    /// The window the control room is a tab of, whether or not a terminal
    /// tab is there yet.
    ControlRooms,
    /// The terminal window the person used last.
    Frontmost,
}

/// Where a tab the core asked for goes. The macOS host's
/// `ControlRoomRules.newTab`, with the same answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NewTab {
    /// Beside the terminal it was asked from, and in front: what a key and
    /// a menu item have always done.
    InFront(Home),
    /// As a tab of that window, **without being brought in front**: the
    /// person is looking at the control room and stays there.
    Behind(Home),
    /// In a window of its own: there is no terminal window to put a tab in,
    /// and the control room is not the tab in front.
    OwnWindow,
    /// Not opened, and the core is told so. Nothing holds the terminal it
    /// was asked from.
    Refused,
}

/// `asker` is the terminal the tab was asked from, when there is one:
/// whether the control room is showing it, and whether a window still holds
/// it. With no asker the request came from the application itself -- the
/// control room starting a supervisor is one -- and the three facts after
/// it say where there is room.
///
/// `by_person` is a key or a menu item; false is the application's own. A
/// tab the person asked for on the control room comes in front.
pub fn new_tab(asker: Option<(bool, bool)>, by_person: bool, control_room_in_front: bool, tabs_beside_control_room: bool, any_terminal_window: bool) -> NewTab {
    if let Some((lent, has_home)) = asker {
        if !has_home {
            return NewTab::Refused;
        }
        return if lent { NewTab::Behind(Home::Askers) } else { NewTab::InFront(Home::Askers) };
    }
    // Alone on screen, the control room's window takes the tab too: it
    // answered `OwnWindow` there, which this host cannot open, so starting
    // a supervisor from a lone control room opened nothing.
    if control_room_in_front && (tabs_beside_control_room || !any_terminal_window) {
        return if by_person { NewTab::InFront(Home::ControlRooms) } else { NewTab::Behind(Home::ControlRooms) };
    }
    if any_terminal_window {
        NewTab::InFront(Home::Frontmost)
    } else {
        NewTab::OwnWindow
    }
}

/// What a tab is called when its shell's title is the path of the program
/// that was started in it: that program's name. A console's title starts
/// as the full path of what was launched (`C:\WINDOWS\...\powershell.exe`)
/// and stays that until the shell sets its own; any other title is kept as
/// it came. 暂定.
pub fn shown_title(title: &str) -> &str {
    let lower = title.to_ascii_lowercase();
    let is_path = lower.ends_with(".exe") && title.contains('\\') && title.as_bytes().get(1) == Some(&b':');
    if !is_path {
        return title;
    }
    let name = &title[title.rfind('\\').map_or(0, |i| i + 1)..];
    &name[..name.len() - ".exe".len()]
}

/// Where a new control-room tab goes among its window's tabs. Only at
/// creation: the person may move it afterwards and it stays moved.
pub const OPENS_AT: usize = 0;

/// A window, a tab or a terminal as the core spells it in the snapshot
/// (`"0x0000000000000021"`). The host has these as numbers; the snapshot's
/// are strings to be tested for equality and nothing else, so the host's
/// number is put into the snapshot's spelling rather than the other way.
pub fn key(id: u64) -> String {
    format!("0x{id:016x}")
}

/// What a tab is, for the questions whose answer depends on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Terminal,
    ControlRoom,
}

/// Closing this tab may need the person's say-so: the core is asked about
/// each terminal in it. The control room holds no process and loses
/// nothing; opening it again shows the same thing.
pub fn asks_before_closing(kind: Kind) -> bool {
    match kind {
        Kind::Terminal => true,
        Kind::ControlRoom => false,
    }
}

/// A closed tab of this kind is kept for "reopen closed tab". The control
/// room comes back through its own menu item, and has no directory to come
/// back in.
pub fn remembered_when_closed(kind: Kind) -> bool {
    match kind {
        Kind::Terminal => true,
        Kind::ControlRoom => false,
    }
}

/// The person may give this tab a name of their own.
pub fn can_be_renamed(kind: Kind) -> bool {
    match kind {
        Kind::Terminal => true,
        Kind::ControlRoom => false,
    }
}

/// The English of the tab's fixed name and of its window's title; a host
/// translates them.
pub mod msg {
    use crate::n_;

    pub const TAB_TITLE: &str = n_("Control Room");
    pub const WINDOW_TITLE: &str = n_("Polter — Control Room");
    /// What a window says before any program in it has named itself.
    pub const NO_TITLE: &str = n_("Polter");
}

/// What a window's caption says. `room` is the control room's window title
/// when its tab is the one in front, `over` a title somebody set for the
/// window, `program` what the program in it last announced (empty for
/// nothing yet).
///
/// The control room in front names the window whatever else was set: the
/// other two are about a terminal, and it is not the one being looked at.
/// They come back the moment another tab is in front -- and a window that
/// has nothing to come back to says the product's name, never the control
/// room's left behind.
pub fn caption<'a>(room: Option<&'a str>, over: Option<&'a str>, program: &'a str) -> &'a str {
    if let Some(room) = room {
        return room;
    }
    if let Some(over) = over {
        return over;
    }
    if program.is_empty() {
        msg::NO_TITLE
    } else {
        program
    }
}

/// Rows of the host's own menus (`__polter_*`) that act on a terminal's
/// tab. The control room's tab is not one, so with it in front they act on
/// the tab of the terminal it is showing, and are greyed when it shows none.
pub const HOST_ROWS_ON_A_TERMINAL: &[&str] = &["__polter_save_project"];

/// Whether a menu row can be chosen with the control room's tab in front.
/// `host_row` is a row the host performs itself (its action starts
/// `__polter_`); the rest are the core's bindings, which `reach` sorts.
/// `lent` is whether the control room is showing a terminal of this window
/// on its right-hand side.
///
/// The Project menu, with the control room in front: loading and managing
/// are offered always, and saving while a terminal is shown -- what is
/// saved is that terminal's own tab (`project_tab`). The macOS host's
/// `ControlRoomRules.projectItemOffered`.
pub fn menu_row_offered(action: &str, host_row: bool, any_terminal: bool, lent: bool) -> bool {
    if host_row {
        lent || !HOST_ROWS_ON_A_TERMINAL.contains(&action)
    } else {
        crate::reach::offered(action, any_terminal)
    }
}

/// Which tab "Save as Project" saves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectTab {
    /// The tab in front: a terminal's.
    Front,
    /// The tab of the terminal the control room is showing. The pane never
    /// left that tab's tree, so the tab saves as it always did.
    OfTheLentTerminal,
    /// Nothing to save: the control room is in front and shows no terminal.
    None,
}

/// `front` is the kind of the tab in front; `lent` whether the control
/// room is showing a terminal. **Not whether the keyboard is in it**: the
/// row used to light up once the person had clicked into that terminal and
/// then saved the tab in front, which was the control room's own.
pub fn project_tab(front: Kind, lent: bool) -> ProjectTab {
    match front {
        Kind::Terminal => ProjectTab::Front,
        Kind::ControlRoom if lent => ProjectTab::OfTheLentTerminal,
        Kind::ControlRoom => ProjectTab::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_opens_once_and_after_that_it_is_gone_to() {
        assert_eq!(trigger(0), Trigger::OpenAsFirstTab);
        assert_eq!(trigger(1), Trigger::Select);
    }

    #[test]
    fn two_already_open_is_never_answered_with_a_third() {
        for open in 1..5 {
            assert_eq!(trigger(open), Trigger::Select, "with {open} open");
        }
    }

    #[test]
    fn the_control_room_in_front_names_the_window_and_gives_the_name_back() {
        let room = Some(msg::WINDOW_TITLE);
        assert_eq!(caption(room, None, ""), msg::WINDOW_TITLE);
        assert_eq!(caption(room, Some("mine"), "vim"), msg::WINDOW_TITLE);
        // Another tab in front: what was there before, in its old order.
        assert_eq!(caption(None, Some("mine"), "vim"), "mine");
        assert_eq!(caption(None, None, "vim"), "vim");
        // Nothing to come back to is the product's name, not the room's.
        assert_eq!(caption(None, None, ""), "Polter");
        assert_ne!(msg::TAB_TITLE, msg::WINDOW_TITLE);
    }

    #[test]
    fn on_the_control_room_a_menu_row_is_offered_only_if_it_can_be_done_there() {
        // The host's own rows, bar the one that saves the terminal tab in front.
        assert!(menu_row_offered("__polter_settings", true, false, false));
        assert!(menu_row_offered("__polter_load_project", true, false, false));
        assert!(!menu_row_offered("__polter_save_project", true, true, false));
        // The core's: a tab action yes, an app action with a terminal
        // somewhere, a terminal's own never.
        assert!(menu_row_offered("new_tab", false, false, false));
        assert!(menu_row_offered("quit", false, true, false));
        assert!(!menu_row_offered("quit", false, false, false));
        assert!(!menu_row_offered("copy_to_clipboard", false, true, false));
        assert!(!menu_row_offered("new_split:right", false, true, false));
    }

    #[test]
    fn the_project_menu_works_with_the_control_room_in_front() {
        // Loading and managing need no terminal: offered whether or not
        // the control room is showing one, and with no terminal anywhere.
        for lent in [false, true] {
            for any_terminal in [false, true] {
                assert!(menu_row_offered("__polter_load_project", true, any_terminal, lent));
                assert!(menu_row_offered("__polter_manage_projects", true, any_terminal, lent));
            }
        }
        // Saving saves a tab, and the control room's is not one: offered
        // only while it shows a terminal, whose tab is then what is saved.
        assert!(menu_row_offered("__polter_save_project", true, true, true));
        assert!(!menu_row_offered("__polter_save_project", true, true, false));
        assert_eq!(project_tab(Kind::ControlRoom, true), ProjectTab::OfTheLentTerminal);
        assert_eq!(project_tab(Kind::ControlRoom, false), ProjectTab::None);
        // A terminal's tab in front saves itself, whatever is on loan.
        assert_eq!(project_tab(Kind::Terminal, false), ProjectTab::Front);
        assert_eq!(project_tab(Kind::Terminal, true), ProjectTab::Front);
        // A terminal's own rows are still not lit by a loan: the keyboard
        // being in that terminal is what lights them, and that is the
        // host's to see.
        assert!(!menu_row_offered("copy_to_clipboard", false, true, true));
    }

    #[test]
    fn every_sentence_the_control_room_says_is_marked_for_the_translation_template() {
        // The template is made from string literals inside `n_(…)`
        // (`src/build/GhosttyI18n.zig` reads this crate's sources). A
        // sentence written bare is never extracted, and is then English on
        // every machine with nothing to say why.
        let mut marked = 0;
        for (name, src) in [
            ("rules.rs", include_str!("rules.rs")),
            ("scene.rs", include_str!("scene.rs")),
            ("list.rs", include_str!("list.rs")),
            ("lend.rs", include_str!("lend.rs")),
        ] {
            let start = src.find("pub mod msg {").unwrap_or_else(|| panic!("{name} has no `msg`"));
            let body = &src[start..];
            let body = &body[..body.find("\n}").unwrap_or(body.len())];
            for line in body.lines().map(str::trim).filter(|l| l.starts_with("pub const ")) {
                assert!(line.contains("&str = n_(\""), "{name}: not marked for translation: {line}");
                marked += 1;
            }
        }
        // A reader that stopped matching would find nothing to complain of.
        assert!(marked >= 16, "only {marked} sentences were read");
        // Not marked, on purpose: the refusals of `act::Refusal::message`
        // that nothing shows to the person -- of "seen", which goes to the
        // log. The ones that are shown, of making a group and of starting a
        // supervisor, are marked there, each inside its own `n_(…)`.
        let refusals = include_str!("act.rs");
        for shown in ["Refusal::BadName =>", "Refusal::GroupExists =>", "Refusal::OpenFailed =>", "Refusal::NoSuchDirectory =>"] {
            let line = refusals.lines().find(|l| l.trim_start().starts_with(shown)).unwrap_or_else(|| panic!("no arm {shown}"));
            assert!(line.contains("=> n_(\""), "act.rs: not marked for translation: {line}");
        }
    }

    /// Rust source with `//` comments taken out, so that a sentence about
    /// a thing is not read as the thing.
    fn code(src: &str) -> String {
        src.lines().map(|l| l.split("//").next().unwrap_or("")).collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn a_row_only_says_who_is_waiting_and_for_what_and_nothing_on_it_can_be_pressed() {
        // The user's ruling, 2026-10-12: a row is too small to show what is
        // being agreed to, and what is asked is often not a yes or a no. So
        // the control room tells and does not act: no approve, no refuse, no
        // reply from a row, by a button or by a key or through UI
        // Automation. This reads what draws and what handles input, and
        // fails when any of it sends one of those acts or reads the core's
        // word for "this can be approved" -- which is how such a button
        // would come back.
        let host = concat!(env!("CARGO_MANIFEST_DIR"), "/../host/src/");
        let mut sources = vec![("scene.rs".to_string(), include_str!("scene.rs").to_string())];
        for name in ["control_room.rs", "control_room_keys.rs", "control_room_source.rs", "uia.rs"] {
            let text = std::fs::read_to_string(format!("{host}{name}")).unwrap_or_else(|e| panic!("cannot read the host's {name}: {e}"));
            sources.push((name.to_string(), text));
        }
        // The reading has a floor: these files are large, and one that came
        // back empty would have nothing in it to object to.
        assert!(sources.iter().all(|(_, text)| text.len() > 2000), "a source that should be read was nearly empty");
        for (name, text) in &sources {
            let code = code(text);
            for forbidden in ["approvable", "Act::Approve", "Act::Refuse", "Act::Reply", "InvokePattern"] {
                // `uia.rs` has other windows' buttons in it; only the
                // control room's own providers are held to "no Invoke".
                let scope: &str = if name == "uia.rs" {
                    let from = code.find("struct ControlRoomRoot").expect("the control room's providers are in uia.rs");
                    let to = code[from..].find("pub fn on_get_object_control_room").map_or(code.len(), |n| from + n);
                    &code[from..to]
                } else {
                    &code
                };
                assert!(!scope.contains(forbidden), "{name} has `{forbidden}`: a row would be acting, not telling");
            }
        }
    }

    #[test]
    fn it_opens_as_the_first_tab() {
        assert_eq!(OPENS_AT, 0);
    }

    #[test]
    fn a_number_is_spelled_the_way_the_snapshot_spells_it() {
        // The fixture's own: `"tab": "0x0000000000000021"`.
        assert_eq!(key(0x21), "0x0000000000000021");
        assert_eq!(key(0), "0x0000000000000000");
        assert_eq!(key(u64::MAX), "0xffffffffffffffff");
    }

    #[test]
    fn the_control_room_is_closed_without_asking_and_not_kept_for_reopening() {
        assert!(!asks_before_closing(Kind::ControlRoom));
        assert!(!remembered_when_closed(Kind::ControlRoom));
        assert!(!can_be_renamed(Kind::ControlRoom));
        assert!(asks_before_closing(Kind::Terminal));
        assert!(remembered_when_closed(Kind::Terminal));
        assert!(can_be_renamed(Kind::Terminal));
    }
}
