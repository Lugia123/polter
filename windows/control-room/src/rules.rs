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
        // Not marked, on purpose: `act::Refusal::message`. Nothing shows a
        // refusal to the person now -- the one act the control room sends is
        // "seen", and a refusal of that goes to the log -- so those
        // sentences have no place in a translator's list until something
        // does show them.
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
