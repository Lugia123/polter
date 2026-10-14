//! Where the Windows host's own logs go, and which of them may be deleted.
//!
//! # What this replaces (task 1510)
//!
//! Every process wrote `<exe stem>-<pid>.log` **beside the executable**: the
//! GUI one, and one more for every `polter-cli` child a terminal started --
//! `+mcp` for each agent CLI, `+chat` for each chat tab. Nothing ever deleted
//! any of them. A person who keeps Polter in `Program Files`-like folders, or
//! simply looks at the folder they unzipped it into, found it full of logs
//! that only grew -- which is how this was reported.
//!
//! # What is kept, and why it may not move
//!
//! **One file per process, named by pid.** An older host left running once
//! appended to the same file as a new one, and its heartbeat read as proof
//! that the new process was alive while that one was deadlocked. See
//! `log_path_given` in `host/src/main.rs`. Only the directory changes here.
//!
//! # The directory
//!
//! [`log_dir`]: the core's state directory rule -- `XDG_STATE_HOME`, else
//! `LOCALAPPDATA` (`src/os/xdg.zig`, `state` with `windows_env =
//! "LOCALAPPDATA"`), then `polter\logs`. The host's plugin logs already sit
//! beside it in `polter\plugins` by the same rule (`plugins.rs::log_path`).
//! When neither variable is set, or the directory cannot be made, the host
//! falls back to the temporary directory -- **never** to the executable's.
//!
//! # Which processes get a file of their own
//!
//! [`shares_a_daily_file`]. The GUI and the resident `+action`s (`+mcp`,
//! `+chat`, ...) keep one file per process. **One-shot `+action`s share one
//! file per day**, `<stem>-day-<yyyymmdd>.log`, every line carrying its pid:
//! Claude Code runs `+hook` for every hook and `+statusline` for every status
//! line refresh, and the test machine (task 1509) had 606 pairs of
//! per-process files from one package directory in twenty hours.
//!
//! # The sweep
//!
//! [`plan`] decides, [`sweep`] reads the directory and deletes. Run by the GUI
//! process only, at startup and once an hour after that; `polter-cli`
//! children start often and several at once, and are never the ones to
//! delete each other's files.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The two executables this workspace builds. Their logs are
/// `<stem>-<pid>.log` and, for the stdio verdict, `<stem>-stdio-<pid>.log`.
pub const STEMS: [&str; 2] = ["polter-host", "polter-cli"];

/// `<state root>\polter\logs`, or `None` when neither variable names one.
///
/// An empty variable counts as unset, as it does in the core: `set X=` in
/// `cmd` leaves an empty string rather than removing `X`.
pub fn log_dir(xdg_state_home: Option<&OsStr>, local_app_data: Option<&OsStr>) -> Option<PathBuf> {
    let base = xdg_state_home.filter(|v| !v.is_empty()).or(local_app_data.filter(|v| !v.is_empty()))?;
    Some(PathBuf::from(base).join("polter").join("logs"))
}

/// Whose a log file is, read off its name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    /// `<stem>-<pid>.log` or `<stem>-stdio-<pid>.log`: one process's.
    Pid(u32),
    /// `<stem>-day-<yyyymmdd>.log`: shared by every one-shot `+action` that
    /// ran that day.
    Day,
}

/// The `+action`s that keep running, and so keep a log file of their own.
///
/// Read off `src/cli/ghostty.zig`'s `Action`, one by one:
///
///  * `mcp`, `mcp-slot` -- an MCP server for the life of an agent CLI.
///  * `chat` -- the group chat TUI, for the life of its tab.
///  * `launch` -- becomes the agent CLI in its terminal and waits for it.
///  * `ssh` -- the ssh session it wraps.
///  * `boo` -- an animation that runs until a key is pressed.
///  * `list-themes` -- an interactive preview when it has a terminal.
///  * `edit-config` -- waits for the editor it opened.
///
/// **Everything else is one-shot and shares the day's file**: `hook`,
/// `statusline`, `version`, `help`, `list-fonts`, `list-keybinds`,
/// `list-colors`, `list-actions`, `ssh-cache`, `show-config`,
/// `explain-config`, `validate-config`, `show-face`, `crash-report`,
/// `new-window`, `new-tab`, `toggle-quick-terminal` -- and any name not in
/// this list, including one the core does not know (it exits at once).
///
/// **The default is the shared file on purpose.** A resident action wrongly
/// left out of this list still logs, every line marked with its pid, into a
/// file the sweep keeps while it is written to; a one-shot action wrongly put
/// in it is the defect this change ends -- a new file per run, thousands a
/// day.
pub const RESIDENT_ACTIONS: [&str; 8] =
    ["mcp", "mcp-slot", "chat", "launch", "ssh", "boo", "list-themes", "edit-config"];

/// Whether a process running `action` (as `polter_cliargs::cli_action_name`
/// names it) logs to the day's shared file rather than to one of its own.
pub fn shares_a_daily_file(action: &str) -> bool {
    !RESIDENT_ACTIONS.contains(&action)
}

/// The day's shared file: `<stem>-day-<yyyymmdd>.log`, by local date.
///
/// `-day-` and eight digits, so it can never be read as a pid: a bare
/// `<stem>-20261015.log` would parse as pid 20261015, and the sweep would ask
/// Windows whether that process is alive.
pub fn day_log_name(stem: &str, year: u16, month: u16, day: u16) -> String {
    format!("{stem}-day-{year:04}{month:02}{day:02}.log")
}

/// A day file written to less than this long ago is treated as in use.
///
/// It has no single owner whose pid could be asked about: any one-shot
/// `+action` may open it next. Deleting it while one has it open leaves the
/// name delete-pending, and the next process's open of it fails. One-shot
/// actions last seconds, so an hour without a write means nobody is writing.
pub const DAY_FILE_IN_USE: Duration = Duration::from_secs(60 * 60);

/// Whose file `name` is, or `None` for any name this program does not write.
///
/// **The name is the only mark of ownership.** The state directory is shared
/// with everything else under `LOCALAPPDATA\polter`, and a person may put
/// anything into `logs` -- a log they saved on purpose, renamed. So this
/// accepts exactly `<stem>-<digits>.log` and `<stem>-stdio-<digits>.log` for a
/// stem in [`STEMS`] or `own_stem` (the running executable's, in case
/// somebody renamed it), and nothing looser: no other extension, no suffix
/// after the pid, no case folding.
pub fn parse(name: &str, own_stem: &str) -> Option<Owner> {
    let rest = name.strip_suffix(".log")?;
    let (head, digits) = rest.rsplit_once('-')?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let ours = |stem: &str| STEMS.contains(&stem) || (!own_stem.is_empty() && stem == own_stem);
    if let Some(stem) = head.strip_suffix("-day") {
        return (digits.len() == 8 && ours(stem)).then_some(Owner::Day);
    }
    let pid: u32 = digits.parse().ok()?;
    let stem = head.strip_suffix("-stdio").unwrap_or(head);
    ours(stem).then_some(Owner::Pid(pid))
}

/// The three bounds of the sweep.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// A file older than this goes, unless its process is alive.
    pub max_age: Duration,
    /// After that, the oldest go until at most this many of ours remain...
    pub max_files: usize,
    /// ...and they come to at most this many bytes.
    pub max_bytes: u64,
}

impl Limits {
    /// **Seven days**: long enough that a person who hits a problem on
    /// Monday can still send Friday's log. **A hundred files**: a GUI run
    /// that starts an agent CLI per terminal writes one `polter-cli` log per
    /// agent, and a hundred is a few days of a busy run. **64 MiB**: well
    /// above one ordinary day of a GUI log (the `[loop]` line once a second
    /// is most of it, roughly half a megabyte an hour -- an estimate from the
    /// code, see the task 1510 report), and small enough that nobody finds it
    /// while looking for what filled their disk.
    pub const DEFAULT: Limits = Limits {
        max_age: Duration::from_secs(7 * 24 * 60 * 60),
        max_files: 100,
        max_bytes: 64 * 1024 * 1024,
    };
}

/// One regular file in the directory.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    /// How long ago it was modified. A file modified in the future has age
    /// zero.
    pub age: Duration,
    pub size: u64,
}

/// The names to delete.
///
///  1. Only names [`parse`] accepts are ever named. Everything else is
///     neither deleted nor counted against the limits.
///  2. **A file whose process is alive is never named**: this process's own
///     (`self_pid`), and any pid `is_live` says is running. A day file counts
///     as alive while it was written to within [`DAY_FILE_IN_USE`]. ⚠️ "The delete
///     failed, so someone has it open" is not a substitute: Rust opens files
///     on Windows with `FILE_SHARE_DELETE`, so a log being written to can be
///     deleted out from under its writer. A pid reused by an unrelated
///     process only keeps a file longer, which is the safe direction.
///  3. A file older than `max_age` goes.
///  4. Of what remains, the oldest go first until at most `max_files` remain
///     and they hold at most `max_bytes`. Live files count toward both bounds
///     but are never chosen; when they alone exceed them, every other file
///     goes and the bounds stay exceeded -- truncating a live log would
///     destroy the evidence it exists to keep.
pub fn plan(
    entries: &[Entry],
    own_stem: &str,
    self_pid: u32,
    is_live: &dyn Fn(u32) -> bool,
    limits: Limits,
) -> Vec<String> {
    let ours: Vec<(&Entry, bool)> = entries
        .iter()
        .filter_map(|e| {
            parse(&e.name, own_stem).map(|owner| {
                let live = match owner {
                    Owner::Pid(pid) => pid == self_pid || is_live(pid),
                    Owner::Day => e.age < DAY_FILE_IN_USE,
                };
                (e, live)
            })
        })
        .collect();

    let mut doomed: Vec<String> = Vec::new();
    let mut kept: Vec<(&Entry, bool)> = Vec::new();
    for (e, live) in ours {
        if !live && e.age > limits.max_age {
            doomed.push(e.name.clone());
        } else {
            kept.push((e, live));
        }
    }

    let mut count = kept.len();
    let mut bytes: u64 = kept.iter().map(|(e, _)| e.size).sum();
    let mut candidates: Vec<&Entry> = kept.iter().filter(|(_, live)| !live).map(|(e, _)| *e).collect();
    // Oldest first; the name breaks ties so the plan does not depend on the
    // order the directory happened to list.
    candidates.sort_by(|a, b| b.age.cmp(&a.age).then_with(|| a.name.cmp(&b.name)));
    for e in candidates {
        if count <= limits.max_files && bytes <= limits.max_bytes {
            break;
        }
        doomed.push(e.name.clone());
        count -= 1;
        bytes -= e.size;
    }
    doomed
}

/// What a sweep did, for the log line.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// Names deleted.
    pub deleted: Vec<String>,
    /// Files of ours left, and their total size.
    pub kept: usize,
    pub kept_bytes: u64,
    /// Names [`plan`] chose that could not be deleted, with the reason.
    pub failed: Vec<(String, String)>,
}

/// Delete what [`plan`] names from `dir`. A directory that does not exist is
/// an empty report, not an error.
///
/// Only regular files are considered; a directory or a symlink named like a
/// log is not something this program wrote.
pub fn sweep(
    dir: &Path,
    now: SystemTime,
    own_stem: &str,
    self_pid: u32,
    is_live: &dyn Fn(u32) -> bool,
    limits: Limits,
) -> std::io::Result<Report> {
    let read = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Report::default()),
        Err(e) => return Err(e),
    };
    let mut entries = Vec::new();
    for item in read {
        let Ok(item) = item else { continue };
        // `DirEntry::metadata` does not follow symlinks.
        let Ok(meta) = item.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let Some(name) = item.file_name().to_str().map(str::to_owned) else { continue };
        // No modification time means no evidence it is old: skip it.
        let Ok(modified) = meta.modified() else { continue };
        let age = now.duration_since(modified).unwrap_or(Duration::ZERO);
        entries.push(Entry { name, age, size: meta.len() });
    }
    let doomed = plan(&entries, own_stem, self_pid, is_live, limits);
    let mut report = Report::default();
    for name in &doomed {
        match std::fs::remove_file(dir.join(name)) {
            Ok(()) => report.deleted.push(name.clone()),
            Err(e) => report.failed.push((name.clone(), e.to_string())),
        }
    }
    for e in &entries {
        if parse(&e.name, own_stem).is_some() && !report.deleted.contains(&e.name) {
            report.kept += 1;
            report.kept_bytes += e.size;
        }
    }
    report.deleted.sort();
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: Duration = Duration::from_secs(24 * 60 * 60);
    const ME: u32 = 4242;

    fn e(name: &str, days: u64, size: u64) -> Entry {
        Entry { name: name.to_string(), age: DAY * days as u32, size }
    }

    fn dead(_: u32) -> bool {
        false
    }

    fn planned(entries: &[Entry], is_live: &dyn Fn(u32) -> bool, limits: Limits) -> Vec<String> {
        let mut p = plan(entries, "polter-host", ME, is_live, limits);
        p.sort();
        p
    }

    #[test]
    fn the_directory_follows_the_cores_state_rule() {
        let x = OsStr::new("C:\\xdg");
        let l = OsStr::new("C:\\Users\\u\\AppData\\Local");
        let want = |b: &str| Some(PathBuf::from(b).join("polter").join("logs"));
        assert_eq!(log_dir(Some(x), Some(l)), want("C:\\xdg"));
        assert_eq!(log_dir(None, Some(l)), want("C:\\Users\\u\\AppData\\Local"));
        assert_eq!(log_dir(Some(OsStr::new("")), Some(l)), want("C:\\Users\\u\\AppData\\Local"));
        assert_eq!(log_dir(None, Some(OsStr::new(""))), None);
        assert_eq!(log_dir(None, None), None);
    }

    #[test]
    fn only_the_names_this_program_writes_are_ours() {
        assert_eq!(parse("polter-host-123.log", ""), Some(Owner::Pid(123)));
        assert_eq!(parse("polter-cli-7.log", ""), Some(Owner::Pid(7)));
        assert_eq!(parse("polter-host-stdio-55.log", ""), Some(Owner::Pid(55)));
        assert_eq!(parse("polter-cli-stdio-56.log", ""), Some(Owner::Pid(56)));
        assert_eq!(parse("renamed-9.log", "renamed"), Some(Owner::Pid(9)));
        for not in [
            "polter-host.log",
            "polter-host-.log",
            "polter-host-12a.log",
            "polter-host-12.log.bak",
            "polter-host-12.txt",
            "Polter-Host-12.log",
            "polter-host-12-old.log",
            "my-polter-host-12.log",
            "polter-12.log",
            "polter-host-stdio.log",
            "polter-host-99999999999.log",
            "notes.log",
            // An empty own stem must not make `-12.log` ours.
            "-12.log",
            "polter-cli-day-2026101.log",
            "polter-cli-day-202610150.log",
            "polter-cli-day-.log",
            "polter-cli-stdio-day-20261015.log",
            "other-day-20261015.log",
        ] {
            assert_eq!(parse(not, ""), None, "{not} was taken as ours");
        }
    }

    #[test]
    fn the_day_file_is_named_so_it_cannot_be_read_as_a_pid() {
        let n = day_log_name("polter-cli", 2026, 3, 7);
        assert_eq!(n, "polter-cli-day-20260307.log");
        assert_eq!(parse(&n, ""), Some(Owner::Day));
        assert_eq!(parse("renamed-day-20260307.log", "renamed"), Some(Owner::Day));
    }

    #[test]
    fn one_shot_actions_share_a_file_and_resident_ones_do_not() {
        for a in ["hook", "statusline", "version", "help", "list-fonts", "show-config", "new-tab", "nonsense"] {
            assert!(shares_a_daily_file(a), "{a} should share the day's file");
        }
        for a in ["mcp", "mcp-slot", "chat", "launch", "ssh", "boo", "list-themes", "edit-config"] {
            assert!(!shares_a_daily_file(a), "{a} is resident and keeps its own file");
        }
    }

    #[test]
    fn a_day_file_written_to_within_the_hour_is_kept_past_every_bound() {
        let fresh = Entry { name: "polter-cli-day-20261015.log".into(), age: Duration::from_secs(59 * 60), size: 1000 };
        let stale = Entry { name: "polter-cli-day-20261014.log".into(), age: DAY_FILE_IN_USE, size: 1000 };
        let l = Limits { max_files: 0, max_bytes: 0, ..Limits::DEFAULT };
        assert_eq!(planned(&[fresh, stale], &dead, l), ["polter-cli-day-20261014.log"]);
    }

    #[test]
    fn an_old_day_file_goes_by_age_like_any_other() {
        assert_eq!(planned(&[e("polter-cli-day-20261001.log", 8, 1)], &dead, Limits::DEFAULT), ["polter-cli-day-20261001.log"]);
    }

    #[test]
    fn an_old_dead_log_goes_and_a_recent_one_stays() {
        let got = planned(
            &[e("polter-host-1.log", 8, 10), e("polter-cli-2.log", 6, 10)],
            &dead,
            Limits::DEFAULT,
        );
        assert_eq!(got, ["polter-host-1.log"]);
    }

    #[test]
    fn exactly_seven_days_is_not_yet_older_than_seven_days() {
        let at = |age| vec![Entry { name: "polter-host-1.log".into(), age, size: 1 }];
        let l = Limits::DEFAULT;
        assert!(plan(&at(l.max_age), "", ME, &dead, l).is_empty());
        assert_eq!(plan(&at(l.max_age + Duration::from_secs(1)), "", ME, &dead, l).len(), 1);
    }

    #[test]
    fn a_file_that_is_not_ours_is_never_named_however_old_or_large() {
        let got = planned(
            &[
                e("notes.log", 400, 1 << 40),
                e("polter-host-1.log.bak", 400, 1 << 40),
                e("polter-host-1.log", 1, 10),
            ],
            &dead,
            Limits { max_files: 0, max_bytes: 0, ..Limits::DEFAULT },
        );
        assert_eq!(got, ["polter-host-1.log"]);
    }

    #[test]
    fn a_live_process_keeps_its_file_whatever_its_age() {
        let live = |pid: u32| pid == 17;
        let got = planned(
            &[e("polter-cli-17.log", 30, 10), e("polter-host-4242.log", 30, 10), e("polter-cli-18.log", 30, 10)],
            &live,
            Limits::DEFAULT,
        );
        assert_eq!(got, ["polter-cli-18.log"], "own pid {ME} and live pid 17 must both be kept");
    }

    #[test]
    fn the_stdio_sidecar_of_a_live_process_is_kept_with_its_log() {
        let live = |pid: u32| pid == 17;
        let got = planned(&[e("polter-host-stdio-17.log", 30, 1)], &live, Limits::DEFAULT);
        assert!(got.is_empty(), "{got:?}");
    }

    #[test]
    fn past_the_count_the_oldest_go_first() {
        let l = Limits { max_files: 2, ..Limits::DEFAULT };
        let got = planned(
            &[e("polter-cli-1.log", 3, 1), e("polter-cli-2.log", 1, 1), e("polter-cli-3.log", 5, 1), e("polter-cli-4.log", 2, 1)],
            &dead,
            l,
        );
        assert_eq!(got, ["polter-cli-1.log", "polter-cli-3.log"]);
    }

    #[test]
    fn past_the_size_the_oldest_go_until_it_fits() {
        let l = Limits { max_bytes: 100, ..Limits::DEFAULT };
        let got = planned(
            &[e("polter-cli-1.log", 3, 60), e("polter-cli-2.log", 1, 60), e("polter-cli-3.log", 2, 30)],
            &dead,
            l,
        );
        // 150 bytes: dropping the oldest (60) leaves 90, which fits.
        assert_eq!(got, ["polter-cli-1.log"]);
    }

    #[test]
    fn live_files_count_toward_the_bounds_but_are_never_chosen() {
        let live = |pid: u32| pid == 9;
        let l = Limits { max_bytes: 100, ..Limits::DEFAULT };
        let got = planned(
            &[e("polter-host-9.log", 5, 500), e("polter-cli-1.log", 1, 10), e("polter-cli-2.log", 2, 10)],
            &live,
            l,
        );
        // The live 500 bytes alone exceed the bound: everything else goes,
        // and the live file stays.
        assert_eq!(got, ["polter-cli-1.log", "polter-cli-2.log"]);
    }

    #[test]
    fn within_every_bound_nothing_goes() {
        let got = planned(&[e("polter-cli-1.log", 1, 10), e("polter-host-2.log", 2, 10)], &dead, Limits::DEFAULT);
        assert!(got.is_empty(), "{got:?}");
    }

    /// The real directory, through `sweep`: a log of ours past its age goes,
    /// a file of somebody else's beside it does not, and a directory named
    /// like a log is not touched.
    #[test]
    fn sweep_deletes_only_what_plan_names() {
        let dir = std::env::temp_dir().join(format!("polter-hostlog-sweep-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("polter-cli-3.log")).unwrap();
        for n in ["polter-cli-1.log", "polter-host-2.log", "keep-me.log"] {
            std::fs::write(dir.join(n), b"x").unwrap();
        }
        // Seen from eight days on, every file is past its age.
        let later = SystemTime::now() + DAY * 8;
        let live = |pid: u32| pid == 2;
        let r = sweep(&dir, later, "polter-host", ME, &live, Limits::DEFAULT).unwrap();
        let left = |n: &str| dir.join(n).exists();
        let deleted = r.deleted.clone();
        let (a, b, c, d) = (left("polter-cli-1.log"), left("polter-host-2.log"), left("keep-me.log"), left("polter-cli-3.log"));
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(deleted, ["polter-cli-1.log"]);
        assert!(!a);
        assert!(b, "the live process's log was deleted");
        assert!(c, "a file that is not ours was deleted");
        assert!(d, "a directory named like a log was deleted");
        assert_eq!((r.kept, r.kept_bytes), (1, 1));
    }

    #[test]
    fn a_missing_directory_is_an_empty_report() {
        let dir = std::env::temp_dir().join("polter-hostlog-does-not-exist-anywhere");
        assert_eq!(sweep(&dir, SystemTime::now(), "", ME, &dead, Limits::DEFAULT).unwrap(), Report::default());
    }
}
