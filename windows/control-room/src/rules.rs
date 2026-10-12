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
