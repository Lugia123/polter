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
        assert!(!asks(&["polter-host.exe", "--draw-on-paint"]));
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
}
