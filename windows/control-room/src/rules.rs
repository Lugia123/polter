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
    pub const TAB_TITLE: &str = "Control Room";
    pub const WINDOW_TITLE: &str = "Polter — Control Room";
    /// What a window says before any program in it has named itself.
    pub const NO_TITLE: &str = "Polter";
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

/// Rows of the host's own menus (`__polter_*`) that act on the terminal tab
/// in front and so are greyed on the control room's.
pub const HOST_ROWS_ON_A_TERMINAL: &[&str] = &["__polter_save_project"];

/// Whether a menu row can be chosen with the control room's tab in front.
/// `host_row` is a row the host performs itself (its action starts
/// `__polter_`); the rest are the core's bindings, which `reach` sorts.
pub fn menu_row_offered(action: &str, host_row: bool, any_terminal: bool) -> bool {
    if host_row {
        !HOST_ROWS_ON_A_TERMINAL.contains(&action)
    } else {
        crate::reach::offered(action, any_terminal)
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
        assert!(menu_row_offered("__polter_settings", true, false));
        assert!(menu_row_offered("__polter_load_project", true, false));
        assert!(!menu_row_offered("__polter_save_project", true, true));
        // The core's: a tab action yes, an app action with a terminal
        // somewhere, a terminal's own never.
        assert!(menu_row_offered("new_tab", false, false));
        assert!(menu_row_offered("quit", false, true));
        assert!(!menu_row_offered("quit", false, false));
        assert!(!menu_row_offered("copy_to_clipboard", false, true));
        assert!(!menu_row_offered("new_split:right", false, true));
    }

    /// The sentences in a source's `pub mod msg { … }`.
    fn sentences(src: &str) -> Vec<String> {
        let Some(start) = src.find("pub mod msg {") else { return Vec::new() };
        let body = &src[start..];
        let end = body.find("\n}").unwrap_or(body.len());
        body[..end]
            .lines()
            .filter_map(|l| {
                let l = l.trim();
                let rest = l.strip_prefix("pub const ")?;
                let value = rest.split_once("&str = \"")?.1;
                Some(value.strip_suffix("\";")?.to_string())
            })
            .collect()
    }

    #[test]
    fn every_sentence_the_control_room_says_is_where_the_translation_template_reads() {
        // The template is made from string literals in `windows/host/src`
        // (`src/build/GhosttyI18n.zig`). These sentences are literals here
        // and values there, so the host repeats each one inside `n_(…)`.
        let host = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../host/src/control_room.rs"));
        let mut all = Vec::new();
        for src in [include_str!("rules.rs"), include_str!("scene.rs"), include_str!("list.rs")] {
            all.extend(sentences(src));
        }
        // A reader that stopped matching would find nothing to miss.
        assert!(all.len() >= 16, "only {} sentences were read: {all:?}", all.len());
        assert!(all.contains(&msg::TAB_TITLE.to_string()));
        assert!(all.contains(&crate::scene::msg::GO_TO_ITS_TAB.to_string()));
        assert!(all.contains(&crate::list::msg::OTHERS.to_string()));
        for sentence in all {
            assert!(host.contains(&format!("n_(\"{sentence}\")")), "not marked for translation in the host: {sentence:?}");
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
