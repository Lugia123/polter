//! The shells a new tab can start (task 1778 ②): which there are, what each
//! one's `command` is, and which of them the configuration already names.
//!
//! **Detected, not configured** -- the same thing Windows Terminal calls its
//! dynamic profiles. The host reads the machine (is PowerShell 7 at either of
//! its paths, which WSL distributions are registered) and hands the facts to
//! [`profiles`]; everything that can be wrong in an interesting way -- the
//! order, the quoting, which registry entries are not distributions somebody
//! would want a tab of, which row a `command` line is -- is decided here,
//! where it is testable off Windows.
//!
//! **The order is the core's.** `default_shell.pick` (`src/os/default_shell.zig`)
//! tries PowerShell 7, then Windows PowerShell, then falls back to `cmd.exe`;
//! the list here puts them in that order, so "Automatic" and the first row
//! are the same shell and the menu's "default" mark can be worked out without
//! asking the core.

use crate::general::{Control, Item, Source};
use crate::n_;

/// Which kind of shell a row is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Pwsh,
    WindowsPowerShell,
    Cmd,
    Wsl,
}

/// One row: what to call it and what to start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Profile {
    pub kind: Kind,
    /// The row's text. A WSL row is the distribution's own name; the others
    /// are msgids the host translates.
    pub name: String,
    /// The `command` value that starts it, quoted the way the core's
    /// `splitWindowsShell` reads it.
    pub command: String,
}

/// What the host found on the machine.
pub struct Machine<'a> {
    /// The absolute path of PowerShell 7, when it is installed.
    pub pwsh: Option<&'a str>,
    /// The absolute path of Windows PowerShell, when it is there (always,
    /// on a supported Windows).
    pub windows_powershell: Option<&'a str>,
    /// The WSL registrations, as read from `HKCU\...\Lxss\{guid}`.
    pub wsl: &'a [WslEntry],
}

/// One `Lxss` subkey: its `DistributionName` and its `State` when it has one.
#[derive(Clone, Debug)]
pub struct WslEntry {
    pub name: String,
    pub state: Option<u32>,
}

/// `State` of a registration that is installed and usable. Others are a
/// distribution being installed, converted or removed.
const WSL_INSTALLED: u32 = 1;

/// The rows, in the core's default order, then the WSL distributions.
pub fn profiles(m: &Machine) -> Vec<Profile> {
    let mut out = Vec::new();
    if let Some(p) = m.pwsh {
        out.push(Profile {
            kind: Kind::Pwsh,
            name: "PowerShell 7".into(),
            command: quote(p),
        });
    }
    if let Some(p) = m.windows_powershell {
        out.push(Profile {
            kind: Kind::WindowsPowerShell,
            name: n_("Windows PowerShell").into(),
            command: quote(p),
        });
    }
    out.push(Profile {
        kind: Kind::Cmd,
        name: n_("Command Prompt").into(),
        command: "cmd.exe".into(),
    });
    for name in wsl_names(m.wsl) {
        let command = format!("wsl.exe -d {} --cd ~", quote(&name));
        out.push(Profile {
            kind: Kind::Wsl,
            name,
            command,
        });
    }
    out
}

/// The WSL distributions worth a row: installed, named, and not Docker
/// Desktop's two internal ones -- `docker-desktop` and `docker-desktop-data`
/// are registered as distributions but are its engine, not a shell anybody
/// opens (Windows Terminal hides them for the same reason). Duplicates by
/// name, ignoring case, appear once, in registry order.
pub fn wsl_names(entries: &[WslEntry]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for e in entries {
        let name = e.name.trim();
        if name.is_empty() {
            continue;
        }
        if e.state.is_some_and(|s| s != WSL_INSTALLED) {
            continue;
        }
        if name.to_ascii_lowercase().starts_with("docker-desktop") {
            continue;
        }
        if out.iter().any(|o| o.eq_ignore_ascii_case(name)) {
            continue;
        }
        out.push(name.to_string());
    }
    out
}

/// Quoted when it has whitespace: the core splits a `command` on unquoted
/// whitespace, and `C:\Program Files\...` has some.
fn quote(s: &str) -> String {
    if s.contains([' ', '\t']) {
        format!("\"{s}\"")
    } else {
        s.to_string()
    }
}

/// Which row the configuration's `command` is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Selection {
    /// No `command`: the core picks, in [`profiles`]' order.
    Auto,
    /// This row.
    Row(usize),
    /// A `command` that is none of the rows, kept as it is.
    Custom,
}

pub fn selection(rows: &[Profile], command: Option<&str>) -> Selection {
    let Some(c) = command.map(str::trim).filter(|c| !c.is_empty()) else {
        return Selection::Auto;
    };
    let want = normalize(c);
    match rows.iter().position(|r| normalize(&r.command) == want) {
        Some(i) => Selection::Row(i),
        None => Selection::Custom,
    }
}

/// The row the "default" mark goes on: the selected one, or under
/// [`Selection::Auto`] the first of the rows that are not WSL -- the shell
/// the core will start. `None` for a custom command.
pub fn default_row(rows: &[Profile], sel: Selection) -> Option<usize> {
    match sel {
        Selection::Row(i) => Some(i),
        Selection::Auto => rows.iter().position(|r| r.kind != Kind::Wsl),
        Selection::Custom => None,
    }
}

/// What choosing an entry in the "Default Shell" list does to the `command`
/// line of the config file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Write {
    /// "Automatic": take the line out, so the core's own order decides --
    /// and a PowerShell 7 installed later is picked up without anybody
    /// coming back here. Writing the shell that "automatic" resolves to
    /// today would freeze that choice.
    Remove,
    /// A row: `command = <this>`.
    Set(String),
    /// The custom entry, which is the line already there: nothing to write.
    Keep,
}

pub fn write_for(rows: &[Profile], chosen: Selection) -> Write {
    match chosen {
        Selection::Auto => Write::Remove,
        Selection::Row(i) => match rows.get(i) {
            Some(r) => Write::Set(r.command.clone()),
            // A row that is not there writes nothing rather than something.
            None => Write::Keep,
        },
        Selection::Custom => Write::Keep,
    }
}

/// The same command written two ways is the same row: case (Windows paths
/// ignore it), `/` for `\`, and quotes around the whole of a single path.
fn normalize(s: &str) -> String {
    let s = s.trim();
    let s = if s.len() >= 2
        && s.starts_with('"')
        && s.ends_with('"')
        && !s[1..s.len() - 1].contains('"')
    {
        &s[1..s.len() - 1]
    } else {
        s
    };
    s.replace('/', "\\").to_lowercase()
}

// ============================================================ the menu

/// One line of the shell list under the strip's chevron (task 1804).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Line {
    /// Row `index` of [`profiles`], with its text: the name, then -- after
    /// a tab, where a menu puts what goes on the right -- "WSL" for a
    /// distribution and "Default" for the shell a new tab starts.
    Row { index: usize, text: String },
    Separator,
    /// "Change Default Shell…", which opens the settings window's Terminal
    /// group (the "Default Shell" row).
    ChangeDefault(String),
}

/// The list, top to bottom: the Windows shells, the WSL distributions after
/// a line when there are any, a line, then "Change Default Shell…". `tr`
/// is the host's translation; a WSL row's name is the distribution's own
/// and is not translated.
pub fn menu(rows: &[Profile], sel: Selection, tr: &dyn Fn(&str) -> String) -> Vec<Line> {
    let default = default_row(rows, sel);
    let text = |i: usize, r: &Profile| {
        let name = if r.kind == Kind::Wsl { r.name.clone() } else { tr(&r.name) };
        let mut tags: Vec<String> = Vec::new();
        if r.kind == Kind::Wsl {
            tags.push("WSL".to_string());
        }
        if default == Some(i) {
            tags.push(tr(n_("Default")));
        }
        if tags.is_empty() {
            name
        } else {
            format!("{name}\t{}", tags.join(" · "))
        }
    };
    let mut out = Vec::new();
    for (i, r) in rows.iter().enumerate().filter(|(_, r)| r.kind != Kind::Wsl) {
        out.push(Line::Row { index: i, text: text(i, r) });
    }
    let mut wsl = rows.iter().enumerate().filter(|(_, r)| r.kind == Kind::Wsl).peekable();
    if wsl.peek().is_some() {
        out.push(Line::Separator);
        for (i, r) in wsl {
            out.push(Line::Row { index: i, text: text(i, r) });
        }
    }
    out.push(Line::Separator);
    out.push(Line::ChangeDefault(tr(n_("Change Default Shell…"))));
    out
}

// ============================================== the "Default Shell" row

/// The config key the "Default Shell" row writes.
pub const KEY: &str = "command";

/// The value the row's "Automatic" entry stands for: no `command` line. An
/// empty value is never a `command` (the core refuses it), so it cannot be
/// mistaken for one.
pub const AUTOMATIC: &str = "";

/// Make the form's `command` item the "Default Shell" list (1778 v1,
/// picture 2): "Automatic", then each of `rows`, and -- when the files set
/// a `command` that is none of them -- that value, shown as it is written
/// and left alone when chosen. Any other item is not touched.
///
/// The core sends `command` as a line of text: its choices are this
/// machine's, which the core does not know. What is in effect when no file
/// sets it is the core's own pick, so a value from the defaults is shown as
/// "Automatic" -- written down, it would freeze today's pick (`Write`).
pub fn offer(it: &mut Item, rows: &[Profile]) {
    if it.key != KEY {
        return;
    }
    let set = (it.source != Source::Default).then(|| it.value.clone());
    it.control = Control::Choice;
    it.choices = std::iter::once(AUTOMATIC.to_string()).chain(rows.iter().map(|r| r.command.clone())).collect();
    it.choice_labels = std::iter::once(Some(n_("Automatic").to_string())).chain(rows.iter().map(|r| Some(r.name.clone()))).collect();
    it.choice_template = None;
    it.default = AUTOMATIC.to_string();
    // The row's own spelling of what the file says, so the list finds it;
    // a value that is no row stays as written and becomes a row of its own
    // (`general::shown_choices`).
    it.value = match (selection(rows, set.as_deref()), set) {
        (Selection::Auto, _) => AUTOMATIC.to_string(),
        (Selection::Row(i), _) => rows[i].command.clone(),
        (Selection::Custom, Some(v)) => v,
        (Selection::Custom, None) => AUTOMATIC.to_string(),
    };
}

/// What choosing `value` in the row writes: `None` -- take the line out --
/// for "Automatic", the value otherwise. Asked of a choice list only; no
/// other list has an empty value.
pub fn written<'a>(control: Control, value: &'a str) -> Option<&'a str> {
    if control == Control::Choice && value == AUTOMATIC {
        None
    } else {
        Some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PWSH: &str = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
    const WINPS: &str = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

    fn wsl(name: &str, state: Option<u32>) -> WslEntry {
        WslEntry {
            name: name.into(),
            state,
        }
    }

    #[test]
    fn the_order_is_the_cores_then_wsl() {
        let w = [wsl("Ubuntu", Some(1)), wsl("Debian", None)];
        let rows = profiles(&Machine {
            pwsh: Some(PWSH),
            windows_powershell: Some(WINPS),
            wsl: &w,
        });
        let kinds: Vec<Kind> = rows.iter().map(|r| r.kind).collect();
        assert_eq!(
            kinds,
            vec![
                Kind::Pwsh,
                Kind::WindowsPowerShell,
                Kind::Cmd,
                Kind::Wsl,
                Kind::Wsl
            ]
        );
        assert_eq!(rows[0].command, format!("\"{PWSH}\""));
        assert_eq!(rows[1].command, WINPS);
        assert_eq!(rows[3].command, "wsl.exe -d Ubuntu --cd ~");
        assert_eq!(rows[4].name, "Debian");
    }

    #[test]
    fn no_powershell_7_means_no_row_for_it() {
        let rows = profiles(&Machine {
            pwsh: None,
            windows_powershell: Some(WINPS),
            wsl: &[],
        });
        assert_eq!(
            rows.iter().map(|r| r.kind).collect::<Vec<_>>(),
            vec![Kind::WindowsPowerShell, Kind::Cmd]
        );
    }

    #[test]
    fn docker_desktop_half_installed_unnamed_and_repeated_registrations_are_not_rows() {
        let w = [
            wsl("docker-desktop", Some(1)),
            wsl("docker-desktop-data", Some(1)),
            wsl("Ubuntu-22.04", Some(1)),
            wsl("Alpine", Some(3)),
            wsl("  ", Some(1)),
            wsl("ubuntu-22.04", Some(1)),
        ];
        assert_eq!(wsl_names(&w), vec!["Ubuntu-22.04".to_string()]);
    }

    #[test]
    fn the_configured_command_is_found_however_it_is_written() {
        let rows = profiles(&Machine {
            pwsh: Some(PWSH),
            windows_powershell: Some(WINPS),
            wsl: &[wsl("Ubuntu", None)],
        });
        assert_eq!(selection(&rows, None), Selection::Auto);
        assert_eq!(selection(&rows, Some("  ")), Selection::Auto);
        assert_eq!(
            selection(&rows, Some(&format!("\"{PWSH}\""))),
            Selection::Row(0)
        );
        assert_eq!(
            selection(&rows, Some("\"c:/program files/powershell/7/PWSH.EXE\"")),
            Selection::Row(0)
        );
        assert_eq!(selection(&rows, Some("CMD.EXE")), Selection::Row(2));
        assert_eq!(
            selection(&rows, Some("wsl.exe -d Ubuntu --cd ~")),
            Selection::Row(3)
        );
        assert_eq!(selection(&rows, Some("wsl.exe ~")), Selection::Custom);
    }

    #[test]
    fn automatic_removes_the_line_a_row_sets_it_and_custom_keeps_it() {
        let rows = profiles(&Machine {
            pwsh: Some(PWSH),
            windows_powershell: Some(WINPS),
            wsl: &[],
        });
        assert_eq!(write_for(&rows, Selection::Auto), Write::Remove);
        assert_eq!(
            write_for(&rows, Selection::Row(0)),
            Write::Set(format!("\"{PWSH}\""))
        );
        assert_eq!(write_for(&rows, Selection::Custom), Write::Keep);
        assert_eq!(write_for(&rows, Selection::Row(99)), Write::Keep);
        // What is written is read back as the same row.
        let Write::Set(line) = write_for(&rows, Selection::Row(1)) else {
            panic!()
        };
        assert_eq!(selection(&rows, Some(&line)), Selection::Row(1));
    }

    #[test]
    fn the_default_mark_sits_on_the_shell_that_will_start() {
        let w = [wsl("Ubuntu", None)];
        let with7 = profiles(&Machine {
            pwsh: Some(PWSH),
            windows_powershell: Some(WINPS),
            wsl: &w,
        });
        assert_eq!(default_row(&with7, Selection::Auto), Some(0));
        assert_eq!(default_row(&with7, Selection::Row(3)), Some(3));
        assert_eq!(default_row(&with7, Selection::Custom), None);
        // Nothing but cmd and WSL: the mark is cmd, never a WSL row.
        let bare = profiles(&Machine {
            pwsh: None,
            windows_powershell: None,
            wsl: &w,
        });
        assert_eq!(
            bare[default_row(&bare, Selection::Auto).unwrap()].kind,
            Kind::Cmd
        );
    }

    // -- task 1804: the strip's list and the settings row -------------------

    fn upper(s: &str) -> String {
        s.to_uppercase()
    }

    fn texts(lines: &[Line]) -> Vec<String> {
        lines
            .iter()
            .map(|l| match l {
                Line::Row { index, text } => format!("{index}:{text}"),
                Line::Separator => "--".to_string(),
                Line::ChangeDefault(t) => format!("change:{t}"),
            })
            .collect()
    }

    #[test]
    fn the_list_is_the_windows_shells_then_wsl_then_change_default() {
        let w = [wsl("Ubuntu", None), wsl("Debian", None)];
        let rows = profiles(&Machine { pwsh: Some(PWSH), windows_powershell: Some(WINPS), wsl: &w });
        let lines = texts(&menu(&rows, Selection::Auto, &upper));
        assert_eq!(
            lines,
            vec![
                "0:POWERSHELL 7\tDEFAULT",
                "1:WINDOWS POWERSHELL",
                "2:COMMAND PROMPT",
                "--",
                "3:Ubuntu\tWSL",
                "4:Debian\tWSL",
                "--",
                "change:CHANGE DEFAULT SHELL…",
            ]
        );
    }

    #[test]
    fn no_wsl_means_one_line_before_change_default_and_the_mark_follows_the_file() {
        let w = [wsl("Ubuntu", None)];
        let bare = profiles(&Machine { pwsh: None, windows_powershell: Some(WINPS), wsl: &[] });
        let lines = texts(&menu(&bare, Selection::Auto, &upper));
        assert_eq!(lines, vec!["0:WINDOWS POWERSHELL\tDEFAULT", "1:COMMAND PROMPT", "--", "change:CHANGE DEFAULT SHELL…"]);
        // A WSL distribution set as the shell: marked there, both words.
        let rows = profiles(&Machine { pwsh: None, windows_powershell: Some(WINPS), wsl: &w });
        let wsl_default = texts(&menu(&rows, Selection::Row(2), &upper));
        assert_eq!(wsl_default[0], "0:WINDOWS POWERSHELL");
        assert_eq!(wsl_default[3], "2:Ubuntu\tWSL · DEFAULT");
        // A command that is none of them: nobody is marked.
        let custom = texts(&menu(&rows, Selection::Custom, &upper));
        // Only the shells' own lines: "Change Default Shell…" has the word
        // in its name and is no mark.
        let marked: Vec<&String> = custom.iter().filter(|t| !t.starts_with("change:")).filter(|t| t.contains("DEFAULT")).collect();
        assert!(marked.is_empty(), "{custom:?}");
    }

    fn command_item(value: &str, source: Source) -> Item {
        Item {
            kind: crate::general::Kind::Key,
            key: KEY.into(),
            group: Some("terminal".into()),
            control: Control::Text,
            choices: Vec::new(),
            choice_labels: Vec::new(),
            choice_template: None,
            on: None,
            off: None,
            aliases: Vec::new(),
            min: None,
            max: None,
            default: String::new(),
            value: value.into(),
            doc: None,
            doc_zh: None,
            doc_full_zh: None,
            label: Some("Default Shell".into()),
            summary: None,
            source,
            readonly: None,
        }
    }

    fn from_file() -> Source {
        Source::Main { path: "config".into(), line: 3 }
    }

    /// Picture 2: Automatic, each shell, and the file's own value when it is
    /// none of them. What is in effect by default reads as Automatic.
    #[test]
    fn the_command_row_lists_automatic_each_shell_and_a_custom_value() {
        let rows = profiles(&Machine { pwsh: Some(PWSH), windows_powershell: Some(WINPS), wsl: &[] });
        let quoted = format!("\"{PWSH}\"");

        // Nothing in the files: the core's pick is shown as Automatic.
        let mut it = command_item(&quoted, Source::Default);
        offer(&mut it, &rows);
        assert_eq!(it.control, Control::Choice);
        let choices = it.choices.clone();
        assert_eq!(choices, vec![AUTOMATIC.to_string(), quoted.clone(), WINPS.to_string(), "cmd.exe".to_string()]);
        let labels = it.choice_labels.clone();
        assert_eq!(labels[0].as_deref(), Some("Automatic"));
        assert_eq!(labels[3].as_deref(), Some("Command Prompt"));
        let auto = crate::general::choice_index(&it);
        assert_eq!(auto, Some(0));

        // Set to a shell, written another way: its row, in the row's spelling.
        let mut it = command_item("C:/program files/powershell/7/PWSH.EXE", from_file());
        offer(&mut it, &rows);
        let row = crate::general::choice_index(&it);
        assert_eq!(row, Some(1));

        // Set to something else: a row of its own, after the shells.
        let mut it = command_item("wsl.exe ~", from_file());
        offer(&mut it, &rows);
        let shown = crate::general::shown_choices(&it);
        assert_eq!(shown.last().map(String::as_str), Some("wsl.exe ~"));
        let custom = crate::general::choice_index(&it);
        assert_eq!(custom, Some(4));
        // Chosen again, it is what the file says: nothing to write.
        let again = crate::general::should_write("wsl.exe ~", &it);
        assert!(!again);

        // Every other key is left as it was.
        let mut other = command_item("x", from_file());
        other.key = "font-size".into();
        offer(&mut other, &rows);
        assert_eq!(other.control, Control::Text);
    }

    /// Automatic takes the line out; a shell writes its command.
    #[test]
    fn choosing_automatic_takes_the_line_out() {
        let none = written(Control::Choice, AUTOMATIC);
        assert_eq!(none, None);
        let set = written(Control::Choice, "cmd.exe");
        assert_eq!(set, Some("cmd.exe"));
        // An empty text box is not this row's business.
        let text = written(Control::Text, "");
        assert_eq!(text, Some(""));
    }
}
