//! Turning dropped file paths into something safe to type at a shell prompt.
//!
//! **This is not the macOS rule, and the difference is not a preference.**
//! `Ghostty.Shell.escape` prefixes the unsafe characters with a backslash,
//! which is right for a POSIX shell and catastrophic on Windows: backslash is
//! the path separator here, so `C:\Users\a b` would come out as
//! `C:\\Users\\a b` -- both wrong *and* still split at the space. Windows
//! shells quote instead, so this quotes.
//!
//! **What quoting does and does not fix.** It fixes argument splitting, which
//! is the failure that actually happens: drop `C:\My Documents\notes.txt`
//! without quotes and the shell reports "cannot find C:\My", naming only the
//! first half, and the user reads that as the file being missing. It does
//! **not** neutralise `cmd.exe`'s `%VAR%` expansion or delayed `!VAR!`
//! expansion -- those happen *inside* double quotes and no quoting style
//! prevents them. A file called `100%.txt` will still be mangled by `cmd`.
//! That is written down rather than papered over, because the alternative is
//! a comment claiming this is safe.
//!
//! **Which shell.** Double quotes, because they are the one form `cmd.exe`,
//! PowerShell and `CommandLineToArgvW` all agree on. A POSIX shell running
//! under Windows (git-bash, WSL) reads double quotes too; it would prefer
//! single quotes, but a path containing a single quote is legal on Windows
//! and would then need escaping that `cmd` cannot read. One rule that is
//! right for the two native shells beats three rules chosen by guessing which
//! shell is running, which the host cannot know.

/// Characters that need no quoting.
///
/// **An allowlist, not a denylist**, which is the same shape macOS chose and
/// for the same reason: a denylist is wrong the first time somebody uses a
/// character nobody thought of, and it is wrong silently.
///
/// `is_alphanumeric` rather than `is_ascii_alphanumeric` on purpose --
/// `C:\项目\说明.txt` needs no quotes and wrapping it in them would be noise
/// on every drop for a large share of users.
fn is_safe(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | ':' | '\\' | '/' | '@' | '+' | '=')
}

/// Quote one path for a Windows shell command line.
///
/// Returns the path unchanged when it needs nothing, so the common case reads
/// as what the user dropped.
pub fn quote(path: &str) -> String {
    if !path.is_empty() && path.chars().all(is_safe) {
        return path.to_string();
    }

    let mut out = String::with_capacity(path.len() + 8);
    out.push('"');
    // Count of consecutive backslashes seen, because a run of them
    // immediately before the closing quote has to be doubled -- see below.
    let mut backslashes = 0usize;
    for c in path.chars() {
        match c {
            '\\' => {
                backslashes += 1;
                out.push('\\');
            }
            '"' => {
                // A quote inside a path. **Windows filenames cannot contain
                // one** -- `"` is one of the nine characters the filesystem
                // rejects -- so this branch is defensive, not a case anyone
                // will hit by dragging a file. It exists because the string
                // comes from an `IDataObject` handed over by another process,
                // and "the API can only give me valid paths" is an assumption
                // about somebody else's code.
                //
                // Doubling is what `cmd.exe` and PowerShell read.
                // `CommandLineToArgvW` wants `\"` instead; the two cannot both
                // be satisfied, and the shells are what receives this.
                out.push_str("\"\"");
                backslashes = 0;
            }
            _ => {
                out.push(c);
                backslashes = 0;
            }
        }
    }
    // **The trailing-backslash trap, and it is a real drop, not a corner
    // case**: dragging a drive root gives `C:\`, and `"C:\"` is a string
    // whose closing quote has been escaped by the backslash in front of it --
    // the shell then swallows the rest of the line. Doubling the trailing run
    // gives `"C:\\"`, which every one of these parsers reads as `C:\`.
    for _ in 0..backslashes {
        out.push('\\');
    }
    out.push('"');
    out
}

/// The text to insert for a whole drop: every path quoted, space separated.
///
/// A trailing space is **not** added. macOS does not add one either, and the
/// difference matters when a single file is dropped onto an empty prompt: the
/// user is one keystroke from running it, and a trailing space is a keystroke
/// they cannot see to remove.
pub fn join(paths: &[String]) -> String {
    paths
        .iter()
        .map(|p| quote(p))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ordinary case must not be decorated. If every path came back
    /// quoted the tests below would all pass while the terminal filled with
    /// quotes nobody asked for.
    #[test]
    fn a_plain_path_is_left_alone() {
        assert_eq!(quote(r"C:\Users\lugia\notes.txt"), r"C:\Users\lugia\notes.txt");
        assert_eq!(quote(r"D:/mixed/separators.md"), r"D:/mixed/separators.md");
    }

    /// **The failure this whole module exists for.** Unquoted, the shell sees
    /// two arguments and says it cannot find `C:\My`, which reads as the file
    /// being missing rather than as the terminal having split it.
    #[test]
    fn a_path_with_a_space_is_quoted() {
        assert_eq!(
            quote(r"C:\My Documents\notes.txt"),
            "\"C:\\My Documents\\notes.txt\""
        );
    }

    /// A tab is whitespace too, and is a legal filename character.
    #[test]
    fn other_whitespace_is_quoted_as_well() {
        assert_eq!(quote("C:\\a\tb.txt"), "\"C:\\a\tb.txt\"");
    }

    /// A quote in the input. Windows will not produce one, but the string
    /// arrives from another process, so the function has to be total.
    #[test]
    fn an_embedded_quote_is_doubled() {
        assert_eq!(quote(r#"C:\a"b.txt"#), r#""C:\a""b.txt""#);
    }

    /// **The drive root.** `C:\` is what dragging a drive gives, and the
    /// naive `"C:\"` has its closing quote escaped by the backslash -- the
    /// shell then eats the rest of the command line. This is the one case
    /// where getting it wrong breaks something other than the path itself.
    #[test]
    fn a_trailing_backslash_is_doubled_before_the_closing_quote() {
        // Quoted because of the space, and the run at the end is doubled.
        assert_eq!(quote(r"C:\My Dir\"), "\"C:\\My Dir\\\\\"");
        // Two trailing backslashes become four.
        assert_eq!(quote(r"C:\My Dir\\"), "\"C:\\My Dir\\\\\\\\\"");
    }

    /// A backslash **not** at the end must not be doubled -- that would turn
    /// every quoted path into an unusable one, which is the mistake made by
    /// reaching for `CommandLineToArgvW`'s rules wholesale.
    #[test]
    fn interior_backslashes_are_not_doubled() {
        assert_eq!(
            quote(r"C:\a b\c\d.txt"),
            "\"C:\\a b\\c\\d.txt\"",
            "only a run immediately before the closing quote is doubled"
        );
    }

    /// UNC paths: the leading `\\` is part of the path, not an escape, and
    /// must survive untouched.
    #[test]
    fn a_unc_path_keeps_its_leading_double_backslash() {
        // No space: nothing to quote, and the `\\` must not be mangled.
        assert_eq!(quote(r"\\server\share\file.txt"), r"\\server\share\file.txt");
        // With a space: quoted, and the leading `\\` is still two.
        assert_eq!(
            quote(r"\\server\my share\file.txt"),
            "\"\\\\server\\my share\\file.txt\""
        );
    }

    /// A UNC share root is the trailing-backslash trap and the UNC case at
    /// once, which is the combination least likely to be tried by hand.
    #[test]
    fn a_unc_share_root_survives_both_rules() {
        assert_eq!(quote(r"\\server\my share\"), "\"\\\\server\\my share\\\\\"");
    }

    /// `cmd.exe` splits on these even though they are legal in a filename, so
    /// they have to force quoting. `&` in particular: `a&b.txt` unquoted runs
    /// `b.txt` as a second command.
    #[test]
    fn cmd_metacharacters_force_quoting() {
        for p in [r"C:\a&b.txt", r"C:\a,b.txt", r"C:\a;b.txt", r"C:\(a).txt", r"C:\a^b.txt"] {
            assert!(quote(p).starts_with('"'), "{p} was not quoted");
        }
    }

    /// Non-ASCII needs no quoting. Quoting it would be harmless but would put
    /// quotes around a large share of real users' every drop.
    #[test]
    fn a_cjk_path_is_not_quoted() {
        assert_eq!(quote(r"C:\项目\说明.txt"), r"C:\项目\说明.txt");
    }

    /// The empty string quotes to an empty argument rather than vanishing.
    /// A path that disappeared would silently shift every argument after it.
    #[test]
    fn the_empty_path_becomes_an_empty_argument() {
        assert_eq!(quote(""), "\"\"");
    }

    #[test]
    fn several_paths_are_space_separated() {
        let v = vec![r"C:\a.txt".to_string(), r"C:\b c.txt".to_string()];
        assert_eq!(join(&v), "C:\\a.txt \"C:\\b c.txt\"");
    }

    /// One path is not decorated by the join either, and there is no trailing
    /// space: a single dropped file leaves the cursor right after it.
    #[test]
    fn one_path_joins_to_itself() {
        let v = vec![r"C:\a.txt".to_string()];
        assert_eq!(join(&v), r"C:\a.txt");
        assert!(!join(&v).ends_with(' '));
    }

    #[test]
    fn no_paths_is_the_empty_string() {
        assert_eq!(join(&[]), "");
    }

    /// **The floor for the join tests.** A join that quoted everything, or
    /// nothing, would still pass a test that only looked at one shape. Mixed
    /// input has to come back mixed.
    #[test]
    fn a_mixed_drop_quotes_only_what_needs_it() {
        let v = vec![
            r"C:\plain.txt".to_string(),
            r"C:\with space.txt".to_string(),
            r"C:\also_plain.txt".to_string(),
        ];
        let out = join(&v);
        assert_eq!(out.matches('"').count(), 2, "exactly one path should be quoted: {out}");
        assert!(out.starts_with(r"C:\plain.txt "));
        assert!(out.ends_with(r" C:\also_plain.txt"));
    }

    /// Round trip through the rule `CommandLineToArgvW` and `cmd` share, done
    /// by hand: the quoted form, read back, must give the original path.
    ///
    /// **This is the only test here that checks the rule rather than the
    /// output string.** The others pin what the function produces; this one
    /// pins that what it produces means what it should, which is the question
    /// a hand-written expected-string test cannot ask.
    #[test]
    fn quoting_round_trips_through_a_parser() {
        for original in [
            r"C:\Users\lugia\notes.txt",
            r"C:\My Documents\notes.txt",
            r"C:\My Dir\",
            r"\\server\my share\file.txt",
            r"\\server\my share\",
            r"C:\a&b.txt",
            r"C:\项目\说明.txt",
            "",
        ] {
            let quoted = quote(original);
            assert_eq!(
                unquote(&quoted),
                original,
                "{quoted:?} did not read back as {original:?}"
            );
        }
    }

    /// The reading half of the rule above: strip one layer of double quotes,
    /// halve a doubled backslash run that sits before the closing quote, and
    /// halve doubled quotes. Deliberately written from the rule rather than
    /// from `quote`, so that a mistake in `quote` is not reproduced here.
    fn unquote(s: &str) -> String {
        if !s.starts_with('"') {
            return s.to_string();
        }
        let inner = &s[1..s.len() - 1];
        let mut out = String::new();
        let mut chars = inner.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '"' && chars.peek() == Some(&'"') {
                chars.next();
                out.push('"');
            } else {
                out.push(c);
            }
        }
        // Halve a run of backslashes at the very end.
        let trailing = out.len() - out.trim_end_matches('\\').len();
        if trailing > 0 {
            out.truncate(out.len() - trailing / 2);
        }
        out
    }
}
