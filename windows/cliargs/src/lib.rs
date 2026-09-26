//! Does this command line ask for a CLI action, or for a window?
//!
//! # Why this question is asked here as well as by the core
//!
//! The core answers it during `ghostty_init`, from `GetCommandLineW()`, in
//! `cli/action.zig`'s `detectIter` plus the `detectSpecialCase` decl on
//! `cli/ghostty.zig`'s `Action`. That answer is authoritative and it is the
//! one that decides what actually runs.
//!
//! But the Windows host has to answer it **before** `ghostty_init`, twice:
//!
//!   * A CLI action must not delete the log file of the GUI instance that
//!     pinned it (`owns_the_log` in `main.rs`).
//!   * A CLI action is a terminal program, and the host otherwise turns on
//!     `GHOSTTY_LOG=stderr`. Logging to stderr underneath a full-screen TUI
//!     scribbles over it.
//!
//! and then a third time, after `ghostty_init`, to decide whether a run that
//! the core declined to act on should open a window or exit non-zero.
//!
//! # The defect this crate is the fix for
//!
//! The host's rule used to be the whole of `args.skip(1).any(|a|
//! a.starts_with('+'))`. The core's rule is not that: `--help` and `-h` are a
//! fallback to `+help`, `--version` is `+version` outright, and `-e` cuts the
//! search off. So `polter-cli.exe --help` was a command line the core would
//! have run `help` for, and the host never asked it to -- the guard was
//! false, `ghostty_cli_try_action` was never called, and the run went
//! straight on to load the API, create a frame window, create a tab, spawn a
//! shell and enter the message loop. **`--help` started a full resident
//! instance.** Nothing said so: `--help` is one of the arguments a reader
//! assumes is only a question, and the assumption was the reader's, not the
//! program's.
//!
//! # What is deliberately *not* the same as the core
//!
//! **`argv[0]` is skipped here and walked there.** `detectIter` starts at the
//! first element of the command line, so an executable living under a
//! directory named `+something` is read by the core as naming an action. That
//! is true on POSIX too and `global.zig` says it is left alone rather than
//! special-cased on one platform. Here the program's own path is skipped, so
//! this side never *invents* an action -- the divergence only runs in the
//! direction of opening a window, which is the recoverable one.
//!
//! **`+a +b` and `+nonsense` are reported as actions.** The core turns both
//! into a `DetectError`, which fails `ghostty_init`, and the host reports
//! that as a fatal and exits 1. Reporting them here as "an action was asked
//! for" is what keeps that failure out of the log the GUI instance pinned.

/// Every way a command line can name a CLI action without a `+`.
///
/// Ported one for one from `Action.detectSpecialCase` in
/// `src/cli/ghostty.zig`. Kept as an enum rather than three `if`s so that the
/// port has the same shape as the thing it is a port of, and a new special
/// case upstream lands as a missing match arm rather than as nothing.
enum Special {
    /// This is the action, whatever else the line says.
    Action,
    /// This is the action if no `+action` is found.
    Fallback,
    /// If nothing has named an action yet, nothing on this line will.
    AbortIfNoAction,
}

fn special_case(arg: &str) -> Option<Special> {
    match arg {
        // `ghostty -e ghostty +command` must run `-e`'s command, not the
        // action inside it.
        "-e" => Some(Special::AbortIfNoAction),
        "--version" => Some(Special::Action),
        "--help" | "-h" => Some(Special::Fallback),
        _ => None,
    }
}

/// Does this command line ask for a CLI action?
///
/// `args` is the process's arguments **including** `argv[0]`, exactly as
/// `std::env::args()` yields them; the first is skipped for the reason in the
/// module note.
///
/// `true` means: the core is going to run something and exit, so do not open a
/// window, do not take the pinned log, and do not point core logging at the
/// stderr the action is writing on.
pub fn asks_for_a_cli_action<I, S>(args: I) -> bool
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut pending = false;
    let mut fallback = false;

    for arg in args.into_iter().skip(1) {
        let arg = arg.as_ref();

        if let Some(special) = special_case(arg) {
            match special {
                Special::Action => return true,
                Special::Fallback => fallback = true,
                Special::AbortIfNoAction => {
                    if !pending {
                        return false;
                    }
                }
            }
            // No `continue`, and that is not an oversight -- `detectIter`
            // falls through here too. None of the special spellings begins
            // with `+`, so the test below declines them all anyway; keeping
            // the shape means the next special case added upstream behaves
            // the same on both sides without anyone rereading this.
        }

        if arg.starts_with('+') {
            pending = true;
        }
    }

    pending || fallback
}

// ---------------------------------------------------------------------------
// The host's own flags (issue #21)
// ---------------------------------------------------------------------------

/// The prefix every flag that belongs to the Windows host carries.
///
/// **Why a prefix at all.** The core reads the whole command line on this
/// platform (`GetCommandLineW()`, `global.zig`) and, since #21, loads config
/// from it (`ghostty_config_load_cli_args`). Every argument it does not know
/// becomes a config diagnostic, and the host shows diagnostics in a window at
/// start-up -- so a bare `--selftest` would put an error window in front of
/// every self-test. The core skips this prefix (`ArgsIterator` in
/// `src/cli/args.zig`), and **the host must know every flag under it and
/// refuse the rest** (`host_flags`): a prefix both sides ignore would bring
/// back #21 itself -- a flag written, read by nobody, reported by nobody.
///
/// **Values go with `=`, in the one token.** A value in the next argument
/// would not start with `--`, and the core reports that as `invalid field`
/// whatever it follows; `=` keeps the core from having to know which host
/// flags take a value.
pub const HOST_PREFIX: &str = "--polter-host-";

/// Whether a host flag carries a value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Takes {
    Nothing,
    /// `--polter-host-x` or `--polter-host-x=v`.
    Optional,
    /// Only `--polter-host-x=v`.
    Required,
}

/// **Every host flag, and the only list of them.** The host reads flags only
/// through `HostFlags`, which refuses a name that is not here -- so a flag
/// cannot be read without being listed, and a listed flag cannot be misspelt
/// on the command line without being refused.
pub const HOST_FLAGS: &[(&str, Takes)] = &[
    ("menu-selftest", Takes::Nothing),
    ("panic-test", Takes::Optional),
    ("draw-on-paint", Takes::Nothing),
    ("ops-delay", Takes::Required),
    ("clock", Takes::Nothing),
    ("striptest", Takes::Nothing),
    ("qttest", Takes::Nothing),
    ("selftest", Takes::Nothing),
    ("selfresize", Takes::Nothing),
    ("write-settings-fixture", Takes::Required),
    ("write-project-fixture", Takes::Required),
];

/// Why a command line was refused. Each names the argument as written.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Rejection {
    /// `--polter-host-…` that is not in `HOST_FLAGS`.
    Unknown(String),
    /// A `Takes::Required` flag with no `=value`.
    MissingValue(String),
    /// A `Takes::Nothing` flag given `=value`.
    UnexpectedValue(String),
    /// A host flag under the name it had before the prefix (`--selftest`).
    /// **Refused by name, with the new one**: these were typed by hand for a
    /// month, and left to the core the old spelling would come back as a
    /// generic "unknown field" in the config error window, which sends the
    /// person to their config file instead of to the new name.
    Renamed { given: String, now: String },
}

impl std::fmt::Display for Rejection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Rejection::Unknown(a) => write!(f, "{a}: not a flag this program knows"),
            Rejection::MissingValue(a) => write!(f, "{a}: needs a value, written {a}=<value>"),
            Rejection::UnexpectedValue(a) => write!(f, "{a}: takes no value"),
            Rejection::Renamed { given, now } => write!(f, "{given} has been renamed to {now}"),
        }
    }
}

/// The host flags a command line carries.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HostFlags {
    found: Vec<(&'static str, Option<String>)>,
}

impl HostFlags {
    /// Whether `name` (without the prefix) was given.
    ///
    /// ⚠️ **Panics on a name that is not in `HOST_FLAGS`**: asking for an
    /// unlisted flag is a program error that would otherwise read as "not
    /// given", forever.
    pub fn has(&self, name: &str) -> bool {
        listed(name);
        self.found.iter().any(|(n, _)| *n == name)
    }

    /// The value given with `name`, if any. Same panic as `has`.
    pub fn value(&self, name: &str) -> Option<&str> {
        listed(name);
        self.found.iter().find(|(n, _)| *n == name).and_then(|(_, v)| v.as_deref())
    }
}

fn listed(name: &str) -> (&'static str, Takes) {
    *HOST_FLAGS
        .iter()
        .find(|(n, _)| *n == name)
        .unwrap_or_else(|| panic!("{HOST_PREFIX}{name} is not in HOST_FLAGS"))
}

/// Read the host flags out of a command line, `argv[0]` first.
///
/// Stops at `-e`: what follows is the command to run inside the terminal, and
/// a `--polter-host-…` there is that command's argument, not this program's.
/// The core's `ArgsIterator` stops skipping at the same place.
pub fn host_flags<I, S>(args: I) -> Result<HostFlags, Rejection>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut out = HostFlags::default();
    for arg in args.into_iter().skip(1) {
        let arg = arg.as_ref();
        if arg == "-e" {
            break;
        }
        let Some(rest) = arg.strip_prefix(HOST_PREFIX) else {
            if let Some(now) = renamed(arg) {
                return Err(Rejection::Renamed { given: arg.to_string(), now });
            }
            continue;
        };
        let (name, value) = match rest.split_once('=') {
            Some((n, v)) => (n, Some(v.to_string())),
            None => (rest, None),
        };
        let Some(&(name, takes)) = HOST_FLAGS.iter().find(|(n, _)| *n == name) else {
            return Err(Rejection::Unknown(arg.to_string()));
        };
        match (takes, &value) {
            (Takes::Required, None) => return Err(Rejection::MissingValue(arg.to_string())),
            (Takes::Nothing, Some(_)) => return Err(Rejection::UnexpectedValue(arg.to_string())),
            _ => {}
        }
        out.found.push((name, value));
    }
    Ok(out)
}

/// If `arg` is one of the host flags under its name from before the prefix
/// (`--selftest`), the name it has now. None of those names is a core config
/// field (checked against `src/config/Config.zig` when the prefix went in),
/// so this can only ever catch an old host flag.
pub fn renamed(arg: &str) -> Option<String> {
    let bare = arg.strip_prefix("--")?;
    let name = bare.split_once('=').map_or(bare, |(n, _)| n);
    HOST_FLAGS.iter().find(|(n, _)| *n == name).map(|(n, _)| format!("{HOST_PREFIX}{n}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asks(v: &[&str]) -> bool {
        asks_for_a_cli_action(v.iter().copied())
    }

    /// **The defect, as one assertion.** Red before the fix; the run it
    /// describes loaded libghostty, opened a frame, opened a tab and started
    /// a shell.
    #[test]
    fn help_is_a_question_and_not_a_terminal() {
        assert!(
            asks(&["polter-cli.exe", "--help"]),
            "`--help` was not recognised as a CLI action, so the host skips \
             ghostty_cli_try_action and falls through into creating a window: \
             `polter-cli.exe --help` starts a full resident instance instead \
             of printing help"
        );
        assert!(
            asks(&["polter-cli.exe", "-h"]),
            "`-h` is the same request as `--help` to the core \
             (Action.detectSpecialCase), and must be here too"
        );
    }

    /// `--version` is the other one a reader assumes is only a question, and
    /// the core treats it more strongly than `--help`: it wins even against a
    /// `+action` on the same line.
    #[test]
    fn version_is_a_question_too_and_it_wins() {
        assert!(asks(&["polter-cli.exe", "--version"]));
        assert!(asks(&["polter-cli.exe", "+chat", "--version"]));
        assert!(asks(&["polter-cli.exe", "--version", "-e", "vim"]));
    }

    /// The rule that was already there, unchanged. If widening the question
    /// had cost any of these, the widening would be a second defect.
    #[test]
    fn a_plus_argument_is_still_an_action_and_a_bare_run_is_still_a_window() {
        assert!(asks(&["polter-host.exe", "+mcp"]));
        assert!(asks(&["polter-host.exe", "--x", "+chat"]));
        assert!(!asks(&["polter-host.exe"]));
        assert!(!asks(&["polter-host.exe", "--polter-host-draw-on-paint"]));
        // The program's own path is skipped: a directory called `+tools` on
        // somebody's disk must not turn every run into a CLI action.
        assert!(!asks(&["C:\\+tools\\polter-host.exe"]));
    }

    /// **The reason `--help` could not simply be added to the old one-liner.**
    /// `-e` ends the search, so a `--help` that belongs to the command being
    /// run inside the terminal is not this program's `--help`.
    #[test]
    fn dash_e_cuts_the_search_off() {
        assert!(
            !asks(&["polter-host.exe", "-e", "vim", "--help"]),
            "`-e` hands the rest of the line to the command being run; \
             treating vim's `--help` as ours exits without opening the \
             terminal that was asked for"
        );
        assert!(
            !asks(&["polter-host.exe", "--help", "-e", "vim"]),
            "`detectIter` returns null the moment it sees `-e` with no \
             pending action, fallback or not"
        );
        // With an action already pending, `-e` does not abort: the core keeps
        // looking so it can call `+command -e +command` invalid.
        assert!(asks(&["polter-host.exe", "+chat", "-e", "vim"]));
    }

    /// Both of these fail `ghostty_init`. They are actions as far as this
    /// question goes, because the alternative is a failing run that first
    /// deletes the log somebody pinned.
    #[test]
    fn a_line_the_core_will_refuse_is_still_not_a_window() {
        assert!(asks(&["polter-host.exe", "+chat", "+mcp"]));
        assert!(asks(&["polter-host.exe", "+no-such-action"]));
    }

    /// Spelling is exact on the core side (`std.mem.eql`), so it is exact
    /// here. A near miss must go to the config parser, not to help.
    #[test]
    fn near_misses_are_not_the_special_cases() {
        assert!(!asks(&["polter-host.exe", "--help=1"]));
        assert!(!asks(&["polter-host.exe", "--HELP"]));
        assert!(!asks(&["polter-host.exe", "-help"]));
        assert!(!asks(&["polter-host.exe", "--versions"]));
        assert!(!asks(&["polter-host.exe", "-E", "vim"]));
    }

    // -- host flags (#21) --------------------------------------------------

    fn flags(v: &[&str]) -> Result<HostFlags, Rejection> {
        host_flags(std::iter::once("polter-host.exe").chain(v.iter().copied()))
    }

    #[test]
    fn a_known_host_flag_is_read_with_its_value() {
        let f = flags(&["--polter-host-selftest", "--polter-host-write-project-fixture=C:\\x y\\p.json"]).unwrap();
        assert!(f.has("selftest"));
        assert!(!f.has("clock"));
        assert_eq!(f.value("write-project-fixture"), Some("C:\\x y\\p.json"));
        let f = flags(&["--polter-host-panic-test"]).unwrap();
        assert!(f.has("panic-test"));
        assert_eq!(f.value("panic-test"), None);
    }

    /// **The floor for condition 2**: a misspelt host flag is refused by
    /// name. Both sides ignoring it would be #21 again.
    #[test]
    fn a_misspelt_host_flag_is_refused_by_name() {
        assert_eq!(
            flags(&["--polter-host-menu-seltest"]),
            Err(Rejection::Unknown("--polter-host-menu-seltest".to_string()))
        );
    }

    #[test]
    fn a_value_is_required_where_the_table_says_so_and_refused_where_it_does_not() {
        assert_eq!(
            flags(&["--polter-host-ops-delay"]),
            Err(Rejection::MissingValue("--polter-host-ops-delay".to_string()))
        );
        assert_eq!(
            flags(&["--polter-host-clock=1"]),
            Err(Rejection::UnexpectedValue("--polter-host-clock=1".to_string()))
        );
    }

    #[test]
    fn user_config_and_everything_after_dash_e_are_not_host_flags() {
        let f = flags(&["--font-size=12", "-e", "tool", "--selftest", "--polter-host-nonsense"]).unwrap();
        assert_eq!(f, HostFlags::default());
    }

    /// Someone who types the old name is told the new one, by the host, at
    /// once -- not left with a config error window that names neither.
    #[test]
    fn an_old_spelling_is_refused_with_the_new_name() {
        let r = flags(&["--menu-selftest"]).unwrap_err();
        assert_eq!(
            r,
            Rejection::Renamed { given: "--menu-selftest".to_string(), now: "--polter-host-menu-selftest".to_string() }
        );
        assert_eq!(r.to_string(), "--menu-selftest has been renamed to --polter-host-menu-selftest");
        assert!(matches!(flags(&["--write-project-fixture"]), Err(Rejection::Renamed { .. })));
        assert!(matches!(flags(&["--ops-delay=5"]), Err(Rejection::Renamed { .. })));
    }

    #[test]
    fn the_old_spelling_is_pointed_at_the_new_one() {
        assert_eq!(renamed("--selftest"), Some("--polter-host-selftest".to_string()));
        assert_eq!(renamed("--ops-delay=5"), Some("--polter-host-ops-delay".to_string()));
        assert_eq!(renamed("--font-size=12"), None);
    }

    #[test]
    #[should_panic(expected = "is not in HOST_FLAGS")]
    fn asking_for_an_unlisted_flag_is_a_program_error() {
        let _ = HostFlags::default().has("not-a-flag");
    }
}
