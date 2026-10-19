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
            name: "Windows PowerShell".into(),
            command: quote(p),
        });
    }
    out.push(Profile {
        kind: Kind::Cmd,
        name: "Command Prompt".into(),
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
}
