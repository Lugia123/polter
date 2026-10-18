//! The question asked before closing or quitting kills something still
//! running (task 1757): what it says and what its buttons say. **The macOS
//! host's words, sentence for sentence** (`BaseTerminalController`'s
//! `confirmClose`, `TerminalController`'s close-other-tabs and
//! close-to-the-right, `AppDelegate`'s quit), and its buttons: one that
//! says what it does -- Close, Terminate -- and Cancel, not the system's
//! Yes and No. Return presses the first, as there; Escape, the title bar's
//! cross and a box that could not be shown are Cancel.
//!
//! What is here is the words; the box is `host/src/projects_ui.rs`'s `ask`.

use crate::n_;

/// What is being closed. **Two different jobs, kept apart on purpose**: the
/// words on the box are a sentence a person reads, so they are translated;
/// `log_key` is an identifier somebody greps a log for, so it is not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Subject {
    /// Every window: the core's `quit` (task 1551).
    App,
    Tab,
    Window,
    Pane,
    OtherTabs,
    RightTabs,
}

impl Subject {
    pub const ALL: [Subject; 6] = [Subject::App, Subject::Tab, Subject::Window, Subject::Pane, Subject::OtherTabs, Subject::RightTabs];

    /// ⚠️ **Never translated, and that is the point.** What `[close] asked
    /// about ...` prints.
    pub fn log_key(self) -> &'static str {
        match self {
            Subject::App => "app",
            Subject::Tab => "tab",
            Subject::Window => "window",
            Subject::Pane => "pane",
            Subject::OtherTabs => "other_tabs",
            Subject::RightTabs => "right_tabs",
        }
    }
}

/// The box's words, as msgids: the question, the sentence under it, and the
/// button that does it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Words {
    pub main: &'static str,
    pub body: &'static str,
    pub confirm: &'static str,
}

pub const CLOSE: &str = n_("Close");
pub const CANCEL: &str = n_("Cancel");

/// A terminal still running something, closed: a pane, or a tab -- which is
/// a window on macOS, and asks this there (`windowShouldClose`).
const TERMINAL: Words = Words {
    main: n_("Close Terminal?"),
    body: n_("The terminal still has a running process. If you close the terminal the process will be killed."),
    confirm: CLOSE,
};

pub fn words(subject: Subject) -> Words {
    match subject {
        Subject::App => Words {
            main: n_("Quit Polter?"),
            body: n_("The terminal still has a running process. If you quit, the process will be killed."),
            confirm: n_("Terminate"),
        },
        Subject::Tab | Subject::Pane => TERMINAL,
        Subject::Window => Words {
            main: n_("Close Window?"),
            body: n_("All terminal sessions in this window will be terminated."),
            confirm: CLOSE,
        },
        Subject::OtherTabs => Words {
            main: n_("Close Other Tabs?"),
            body: n_("At least one other tab still has a running process. If you close the tab the process will be killed."),
            confirm: CLOSE,
        },
        Subject::RightTabs => Words {
            main: n_("Close Tabs on the Right?"),
            body: n_("At least one tab to the right still has a running process. If you close the tab the process will be killed."),
            confirm: CLOSE,
        },
    }
}

/// The buttons in order, translated: the one that does it, then Cancel --
/// **the last the one that does nothing**, as the host's box takes them.
pub fn buttons(subject: Subject, tr: &dyn Fn(&str) -> String) -> Vec<String> {
    vec![tr(words(subject).confirm), tr(CANCEL)]
}

/// Return presses the button that does it, as macOS's first button.
pub const DEFAULT: usize = 0;

/// Whether the answer `pressed` (the box's index; `None` when it could not
/// be shown) is to go ahead: the first button and nothing else.
pub fn confirmed(pressed: Option<usize>) -> bool {
    pressed == Some(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAC: &str = include_str!("../../../macos/Sources/App/Base.lproj/Localizable.strings");
    const MAC_ZH: &str = include_str!("../../../macos/Sources/App/zh-Hans.lproj/Localizable.strings");
    const PO_ZH: &str = include_str!("../../../po/zh_CN.po");

    /// The value of `"key" = "value";` in a `.strings` table.
    fn strings_value<'a>(table: &'a str, key: &str) -> Option<&'a str> {
        let head = format!("\"{}\" = \"", key);
        table.lines().find_map(|l| l.strip_prefix(head.as_str())).and_then(|rest| rest.strip_suffix("\";"))
    }

    /// The msgstr of a one-line `msgid` in a catalogue.
    fn po_value<'a>(po: &'a str, msgid: &str) -> Option<&'a str> {
        let head = format!("msgid \"{}\"", msgid);
        let mut lines = po.lines();
        lines.find(|l| *l == head)?;
        lines.next()?.strip_prefix("msgstr \"")?.strip_suffix('"')
    }

    fn every_msgid() -> Vec<&'static str> {
        let mut all: Vec<&'static str> = Subject::ALL.iter().flat_map(|s| {
            let w = words(*s);
            [w.main, w.body, w.confirm]
        }).collect();
        all.push(CANCEL);
        all
    }

    /// Task 1757: every word on the box is one the macOS host shows for the
    /// same close, and none is the system's Yes or No.
    #[test]
    fn every_word_is_the_macos_hosts_own() {
        assert!(strings_value(MAC, "Close Terminal?").is_some(), "the floor's own floor: the macOS table did not parse");
        for msgid in every_msgid() {
            assert!(strings_value(MAC, msgid).is_some(), "{msgid:?} is not a macOS string");
        }
        for s in Subject::ALL {
            let b = buttons(s, &|m| m.to_string());
            assert_eq!(b.len(), 2, "{s:?}");
            assert_eq!(b[1], "Cancel", "{s:?}: the last button is the one that does nothing");
            for label in &b {
                assert!(!["Yes", "No", "OK"].contains(&label.as_str()), "{s:?}: {label:?}");
            }
        }
        // Closing a terminal says so, as ⌘W on a split does on macOS.
        assert_eq!(words(Subject::Pane).main, "Close Terminal?");
        assert_eq!(words(Subject::App).confirm, "Terminate");
    }

    /// And the Chinese is macOS's Chinese: what `po/zh_CN.po` gives each
    /// msgid is what `zh-Hans.lproj` gives the same key.
    #[test]
    fn the_chinese_is_the_macos_hosts_chinese() {
        for msgid in every_msgid() {
            let mac = strings_value(MAC_ZH, msgid).unwrap_or_else(|| panic!("{msgid:?}: no macOS Chinese"));
            let ours = po_value(PO_ZH, msgid).unwrap_or_else(|| panic!("{msgid:?}: not in po/zh_CN.po"));
            assert_eq!(ours, mac, "{msgid:?}");
        }
    }

    #[test]
    fn only_the_first_button_goes_ahead() {
        assert!(confirmed(Some(DEFAULT)));
        assert!(!confirmed(Some(1)), "Cancel");
        assert!(!confirmed(None), "a box that could not be shown closes nothing");
    }

    #[test]
    fn the_log_says_the_same_word_whatever_the_language() {
        let keys: Vec<&str> = Subject::ALL.iter().map(|s| s.log_key()).collect();
        assert_eq!(keys, ["app", "tab", "window", "pane", "other_tabs", "right_tabs"]);
    }
}
