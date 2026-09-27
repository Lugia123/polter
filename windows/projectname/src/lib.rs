//! The rule that turns a project name into the name of its file.
//!
//! **Written three times, pinned once.** `src/Project.zig`
//! (`sanitizeFilename`), `macos/Sources/Features/Projects/ProjectFilename.swift`
//! and this crate each implement it, and for most of their lives the three
//! disagreed without anything noticing (issue #23). All three now run every
//! row of `test/fixtures/project-filenames.tsv` in their own tests.
//!
//! **Why this is a crate of its own.** The rule used to live in
//! `polter-host`'s `project.rs`, and that crate's tests cannot run anywhere
//! but Windows -- `windows`'s own dependencies do not compile for a macOS
//! target (see `windows/Cargo.toml`). So the table test for this
//! implementation ran only on the Windows machine: changing the 200-byte cap
//! to 199 on the Mac left `cargo test --no-run --target x86_64-pc-windows-gnu`
//! at exit 0 and `tools/every-project-filename-rule-reads-the-table.py` green
//! (measured 2026-09-27), while the same change to the Zig or Swift copy failed
//! its test. With no dependencies,
//! `cargo test -p polter-projectname` runs here, and
//! `windows/tools/pure-crates-pass-their-tests.py` runs it.

/// A project name that names no file: nothing is left once it is sanitized.
/// Matches `Project.zig`'s `error.InvalidName`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidName;

const MAX_FILENAME_LEN: usize = 200;

/// The rule that names a new project file (#838). **One rule for all three
/// implementations**, pinned by `test/fixtures/project-filenames.tsv`, which
/// the tests below run row by row -- `src/Project.zig` and
/// `ProjectFilename.swift` run the same file.
///
/// Walk the name by Unicode scalar -- no normalisation, and **not** by
/// grapheme cluster: cluster boundaries depend on the Unicode version each
/// language's standard library ships, so a rule written in them could not be
/// identical in three languages. Replace every scalar at or below U+001F,
/// U+007F, and `/ \ : * ? " < > |` with `_`. Stop before the scalar that
/// would take the result past 200 UTF-8 bytes, so a multi-byte character is
/// never cut in half. Nothing left is `InvalidName`; otherwise append `.json`.
///
/// ⚠️ **What this replaced**, so it is not rebuilt: it walked `bytes()` and
/// pushed each byte `as char`, which turns every UTF-8 byte into its own
/// Latin-1 code point -- `写` came out as `å\u{86}\u{99}` -- so every
/// non-ASCII name got a different filename from the other two platforms,
/// and the 200 cap counted the mangled length. The round trip still passed,
/// because the writer and the reader mangled alike (#23).
pub fn sanitize_filename(name: &str) -> Result<String, InvalidName> {
    let mut buf = String::new();
    for c in name.chars() {
        let safe = match c {
            '\u{0}'..='\u{1f}' | '\u{7f}' | '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            other => other,
        };
        if buf.len() + safe.len_utf8() > MAX_FILENAME_LEN {
            break;
        }
        buf.push(safe);
    }
    if buf.is_empty() {
        return Err(InvalidName);
    }
    buf.push_str(".json");
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **The shared table, every row** (#838). The rule is a function, and
    /// a function cannot be pinned by a sample file of fields: it is pinned
    /// by input -> expected pairs that all three implementations run.
    ///
    /// ⚠️ **The row count is asserted against the table's own `# rows:`**:
    /// a reader that parsed nothing would otherwise pass every row it saw.
    /// `draft` rows are run and counted but not compared -- see the table's
    /// header for why they are still undecided.
    #[test]
    fn the_shared_filename_table_holds_for_this_implementation() {
        const TABLE: &str = include_str!("../../../test/fixtures/project-filenames.tsv");
        fn unhex(s: &str) -> Vec<u8> {
            (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex")).collect()
        }
        let mut declared = None;
        let (mut rows, mut asserted, mut drafts) = (0, 0, 0);
        let mut wrong = Vec::new();
        for (n, line) in TABLE.lines().enumerate() {
            let line = line.trim_end_matches('\r');
            if let Some(v) = line.strip_prefix("# rows:") {
                declared = Some(v.trim().parse::<usize>().expect("# rows: is a number"));
                continue;
            }
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            assert_eq!(f.len(), 4, "line {}: {} fields", n + 1, f.len());
            rows += 1;
            let input = String::from_utf8(unhex(f[0])).expect("input is UTF-8");
            let got = match sanitize_filename(&input) {
                Ok(name) => name,
                Err(InvalidName) => "ERR:InvalidName".to_string(),
            };
            let want = if f[1] == "ERR:InvalidName" {
                f[1].to_string()
            } else {
                String::from_utf8(unhex(f[1])).expect("expected is UTF-8")
            };
            match f[2] {
                "ok" => {
                    asserted += 1;
                    if got != want {
                        wrong.push(format!("line {} ({}): got {:?}, want {:?}", n + 1, f[3], got, want));
                    }
                }
                "draft" => drafts += 1,
                other => panic!("line {}: unknown status {other:?}", n + 1),
            }
        }
        assert_eq!(Some(rows), declared, "ran {rows} rows, the table declares {declared:?}");
        assert!(asserted > 0, "no row was compared");
        assert!(wrong.is_empty(), "{} of {} rows disagree ({} draft rows not compared):\n{}", wrong.len(), asserted, drafts, wrong.join("\n"));
    }

    /// **The NTFS characters, spelled out.** The table holds the same two
    /// rows in hex; these say them readably, because this is the platform
    /// where they bite: `a:b.json` is accepted by `CreateFileW` and becomes an
    /// extensionless `a` with the data in an alternate stream, silently.
    #[test]
    fn ntfs_reserved_characters_are_replaced_on_this_platform_at_least() {
        assert_eq!(sanitize_filename("a:b"), Ok("a_b.json".to_string()));
        assert_eq!(sanitize_filename("*?\"<>|"), Ok("______.json".to_string()));
    }
}
