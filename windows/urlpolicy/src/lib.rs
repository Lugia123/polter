//! May this URL be handed to the shell, and who chose it?
//!
//! # The distinction the core draws, and why it has to survive the port
//!
//! `open_url` carries a `kind` (`ghostty_action_open_url_kind_e`), and one of
//! the four is not like the others. `text`, `html` and `unknown` come from
//! something the person at the keyboard did -- a path they selected, a file
//! the host was asked to show. **`osc8` is a hyperlink emitted by whatever is
//! running in the terminal**: a program, a remote host over ssh, the output
//! of `cat` on a file somebody else wrote.
//!
//! macOS routes that kind through a separate opener with a confirmation
//! (`openUntrustedURL` in `Ghostty.App.swift`). If the port drops the
//! distinction, `ShellExecuteW` becomes reachable from terminal output, and
//! the interesting targets are not web pages:
//!
//!   * `file:///…` and bare `\\server\share\thing.exe` hand a local or remote
//!     file to the shell, which runs it by its association.
//!   * `ms-…:` and the rest of the registered protocol handlers are a long
//!     list of programs that take an argument from a URL.
//!   * A `.lnk`, `.url`, `.bat` or `.scr` behind an innocent-looking display
//!     text is the oldest trick on this platform, and OSC 8 exists precisely
//!     to let the display text differ from the target.
//!
//! # What this crate is and is not
//!
//! It is the **decision**, as a pure function, so it can be tested where the
//! port is written. It is not the opening -- `links.rs` in `polter-host` does
//! that -- and it is not a URL parser: it reads the scheme and nothing else,
//! because the scheme is the whole of what the decision turns on.
//!
//! **The default is refusal.** A scheme this file has not heard of is not
//! opened when the terminal chose it. That direction is deliberate: a new
//! protocol handler installed by some other program appears on the machine
//! without anything here changing, and a whitelist is the only shape where
//! that arrival is safe by default.

/// What the host should do with an `open_url` action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// Hand it to `ShellExecuteW`.
    Open,
    /// Do not open it. The string says why, for the log line -- **a refusal
    /// that says nothing is indistinguishable from a link that did not
    /// arrive**, and the two have very different answers.
    Refuse(&'static str),
}

/// The schemes an OSC 8 hyperlink may use.
///
/// Short on purpose. These are the ones a hyperlink in terminal output is
/// actually for, and every one of them ends at a program whose job is to be
/// handed a URL by a stranger.
const OSC8_ALLOWED: &[&str] = &["http", "https", "mailto"];

/// The scheme of `url`, lowercased, or `None` if it has none.
///
/// **Not a parser.** RFC 3986 says a scheme is a letter followed by letters,
/// digits, `+`, `-` or `.`, up to the first `:` -- that is the whole rule and
/// it is written out here rather than pulled in, because the alternative is a
/// dependency in a crate whose entire reason for existing is to be buildable
/// anywhere.
///
/// A Windows drive letter is deliberately **not** a scheme: `C:\Users\…` has
/// a one-letter prefix and a colon, and reading it as the scheme `c` would
/// send every absolute path down the "unknown scheme" branch, which is the
/// wrong description of it.
pub fn scheme(url: &str) -> Option<String> {
    let colon = url.find(':')?;
    let head = &url[..colon];
    if head.len() < 2 {
        return None;
    }
    let mut chars = head.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphabetic() {
        return None;
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.') {
        return None;
    }
    Some(head.to_ascii_lowercase())
}

/// Does this look like a path rather than a URL?
///
/// Used only to describe a refusal accurately. A UNC path (`\\host\share`) is
/// called out on its own because it is the one that reaches another machine.
fn shape(url: &str) -> &'static str {
    if url.starts_with("\\\\") || url.starts_with("//") {
        "a UNC path, which reaches another machine"
    } else {
        "a local path"
    }
}

/// The decision, for a URL and the `kind` the core gave it.
///
/// `osc8` is the only kind that is filtered; the other three were chosen by
/// the person at the keyboard and are opened as asked, which is what the
/// other apprts do.
pub fn verdict(kind_is_osc8: bool, url: &str) -> Verdict {
    let url = url.trim();
    if url.is_empty() {
        return Verdict::Refuse("the URL is empty");
    }
    // A control character in a URL is either a mistake or an attempt to make
    // the log line and the target disagree. Refused for every kind, because
    // no legitimate caller sends one.
    if url.chars().any(|c| c.is_control()) {
        return Verdict::Refuse("the URL contains a control character");
    }

    if !kind_is_osc8 {
        return Verdict::Open;
    }

    match scheme(url) {
        Some(s) if OSC8_ALLOWED.contains(&s.as_str()) => Verdict::Open,
        Some(_) => Verdict::Refuse(
            "an OSC 8 hyperlink may only use http, https or mailto: this scheme was chosen \
             by whatever is running in the terminal, and every other scheme on Windows ends \
             at a program that will act on it",
        ),
        None => Verdict::Refuse(
            "an OSC 8 hyperlink with no scheme is a path, and a path from terminal output \
             is a file the shell would run by its association",
        ),
    }
}

/// The same refusal, with the shape of the target named, for the log.
///
/// Split from [`verdict`] so the decision has no formatting in it and the
/// message has no decision in it.
pub fn describe(url: &str) -> String {
    match verdict(true, url) {
        Verdict::Open => "allowed".into(),
        Verdict::Refuse(why) => {
            if scheme(url).is_none() {
                format!("{why} ({})", shape(url))
            } else {
                why.to_string()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn osc8(u: &str) -> Verdict {
        verdict(true, u)
    }
    fn chosen(u: &str) -> Verdict {
        verdict(false, u)
    }

    #[test]
    fn a_hyperlink_from_terminal_output_may_be_a_web_page() {
        assert_eq!(osc8("https://example.com/x"), Verdict::Open);
        assert_eq!(osc8("http://example.com"), Verdict::Open);
        assert_eq!(osc8("mailto:someone@example.com"), Verdict::Open);
        // The scheme is case-insensitive per RFC 3986, and a check that was
        // not would be bypassed by shouting.
        assert_eq!(osc8("HTTPS://example.com"), Verdict::Open);
        assert_eq!(osc8("HtTpS://example.com"), Verdict::Open);
    }

    /// **The whole point of the crate.** Each of these is a target that
    /// `ShellExecuteW` acts on, chosen by whatever was writing to the
    /// terminal.
    #[test]
    fn a_hyperlink_from_terminal_output_may_not_reach_the_shell() {
        for u in [
            "file:///C:/Windows/System32/calc.exe",
            "file://server/share/x.bat",
            "ms-settings:windowsupdate",
            "javascript:alert(1)",
            "vbscript:x",
            "search-ms:query=x",
            "shell:startup",
            "C:\\Users\\somebody\\thing.lnk",
            "\\\\attacker\\share\\payload.exe",
            "//attacker/share/payload.exe",
            "./relative.bat",
        ] {
            assert!(
                matches!(osc8(u), Verdict::Refuse(_)),
                "an OSC 8 hyperlink to {u:?} was allowed to reach ShellExecuteW"
            );
        }
    }

    /// A scheme nobody here has heard of is refused rather than allowed. The
    /// list of protocol handlers on a Windows machine is written by every
    /// program that has ever been installed on it, so "not on my list" is the
    /// only answer that stays correct without this file being edited.
    #[test]
    fn an_unknown_scheme_is_refused_and_not_waved_through() {
        assert!(matches!(osc8("zoommtg://x"), Verdict::Refuse(_)));
        assert!(matches!(osc8("some-app-installed-tomorrow://x"), Verdict::Refuse(_)));
    }

    /// The three kinds the person at the keyboard chose are not filtered --
    /// filtering them would break opening a config file, which is the reason
    /// `text` exists.
    #[test]
    fn the_kinds_the_person_chose_are_opened_as_asked() {
        assert_eq!(chosen("C:\\Users\\somebody\\ghostty\\config"), Verdict::Open);
        assert_eq!(chosen("file:///C:/x"), Verdict::Open);
        assert_eq!(chosen("https://example.com"), Verdict::Open);
    }

    /// Refused for every kind: nothing legitimate carries one, and a newline
    /// in a URL makes the log line and the target disagree.
    #[test]
    fn control_characters_are_refused_whoever_chose_them() {
        assert!(matches!(osc8("https://example.com\nrm -rf"), Verdict::Refuse(_)));
        assert!(matches!(chosen("https://example.com\u{0}x"), Verdict::Refuse(_)));
    }

    #[test]
    fn a_drive_letter_is_not_a_scheme() {
        assert_eq!(scheme("C:\\Windows"), None);
        assert_eq!(scheme("https://x"), Some("https".into()));
        assert_eq!(scheme("mailto:a@b"), Some("mailto".into()));
        assert_eq!(scheme("no-colon-here"), None);
        // A leading digit is not a scheme either.
        assert_eq!(scheme("1foo:bar"), None);
    }

    /// A refusal has to say enough for the person reading the log to tell
    /// "the link was blocked" from "the link never arrived".
    #[test]
    fn a_refusal_says_which_kind_of_target_it_was() {
        assert!(describe("\\\\attacker\\share\\x.exe").contains("UNC"));
        assert!(describe("C:\\x.lnk").contains("local path"));
        assert!(describe("ms-settings:x").contains("http, https or mailto"));
        assert_eq!(describe("https://example.com"), "allowed");
    }
}
