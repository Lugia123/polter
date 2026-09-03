//! Embed the application manifest.
//!
//! **Why a build script rather than a crate.** `embed-resource` would do this,
//! and it would also add a dependency fetched over the network for a job that
//! is one call to a tool the cross-compiler already ships. The whole of it is
//! below.
//!
//! **What happens when the tool is not there.** Nothing, loudly: the build
//! goes on and prints what was lost. A build script that failed here would
//! turn "your toolchain has no resource compiler" into "the project does not
//! build", on machines whose only crime is not being the one this port is
//! cross-compiled from. But it must not be silent either -- **an exe with no
//! manifest is exactly the defect this file exists to fix**, and it looks
//! completely normal until somebody notices the controls are from 1995.
//!
//! **What happens when the manifest is there and broken.** The build fails,
//! and that difference is deliberate. A missing manifest costs you the 1995
//! look; a malformed one costs you the program: the loader refuses an exe
//! whose manifest does not parse, so it does not start at all, and nothing
//! about the build says so. `windres` embeds the bytes without reading them,
//! the `.rsrc` section is present, the manifest text is inside the exe, and
//! `cargo build` exits 0 -- every check that asks "is it in there" passes.
//! None of them ask "does it still run".
//!
//! That is not a hypothetical either. The manifest shipped with two hyphens in
//! a row inside its own comment, which XML forbids, and the resulting exe
//! could not be launched. The prose in a comment was inert to the loader in
//! the sense that mattered to the reader, and very much not inert to the
//! parser.

use std::path::PathBuf;
use std::process::Command;

/// Where a manifest stops being well formed, as `(line, column, what)`.
///
/// **What this reads, and what it does not.** It is the small part of XML a
/// manifest is: elements, attributes, comments, one processing instruction,
/// no text content. It checks the rules that a hand-written manifest actually
/// breaks -- two hyphens inside a comment, a comment that never ends, a tag
/// that never closes, mismatched or unclosed element names, an unquoted or
/// unterminated attribute value, more than one root -- and reports the first
/// one with a line and column, the way a parser would.
///
/// It is not a validator. It says nothing about whether the assembly means
/// what it should: a manifest that parses and declares the wrong version, or
/// omits the dependency entirely, passes here and is a matter for the reader.
/// `windows/tools/manifest-parses.py` runs a real XML parser over the same
/// file for a second opinion; this one is here because it must run on every
/// build, with no interpreter and no crate to fetch.
fn manifest_fault(src: &str) -> Option<(usize, usize, String)> {
    let b: Vec<char> = src.chars().collect();
    let (mut line, mut col, mut i) = (1usize, 1usize, 0usize);
    let mut stack: Vec<(String, usize, usize)> = Vec::new();
    let mut roots = 0usize;
    // Advance one character, keeping the position a person can look at.
    macro_rules! bump {
        ($n:expr) => {{
            for _ in 0..$n {
                if i < b.len() {
                    if b[i] == '\n' {
                        line += 1;
                        col = 1;
                    } else {
                        col += 1;
                    }
                    i += 1;
                }
            }
        }};
    }
    let starts = |i: usize, s: &str| src[..].chars().skip(i).take(s.chars().count()).eq(s.chars());

    while i < b.len() {
        if starts(i, "<!--") {
            let (l0, c0) = (line, col);
            bump!(4);
            loop {
                if i >= b.len() {
                    return Some((l0, c0, "a comment that is never closed".into()));
                }
                if starts(i, "-->") {
                    bump!(3);
                    break;
                }
                if starts(i, "--") {
                    return Some((
                        line,
                        col,
                        "two hyphens in a row inside a comment. XML forbids the \
                         sequence, the loader refuses the exe, and nothing else in \
                         the build notices"
                            .into(),
                    ));
                }
                if b[i] == '-' && starts(i + 1, "->") {
                    return Some((line, col, "a comment ending in a hyphen".into()));
                }
                bump!(1);
            }
        } else if starts(i, "<?") {
            while i < b.len() && !starts(i, "?>") {
                bump!(1);
            }
            if i >= b.len() {
                return Some((line, col, "a processing instruction with no `?>`".into()));
            }
            bump!(2);
        } else if b[i] == '<' {
            let (l0, c0) = (line, col);
            bump!(1);
            let closing = i < b.len() && b[i] == '/';
            if closing {
                bump!(1);
            }
            let mut name = String::new();
            while i < b.len() && !b[i].is_whitespace() && b[i] != '>' && b[i] != '/' {
                name.push(b[i]);
                bump!(1);
            }
            if name.is_empty() {
                return Some((l0, c0, "a `<` that begins no tag".into()));
            }
            // Attributes, and the quoting that goes with them.
            let mut selfclose = false;
            loop {
                if i >= b.len() {
                    return Some((l0, c0, format!("`<{name}` is never closed by `>`")));
                }
                if b[i] == '"' || b[i] == '\'' {
                    let q = b[i];
                    let (ql, qc) = (line, col);
                    bump!(1);
                    while i < b.len() && b[i] != q {
                        bump!(1);
                    }
                    if i >= b.len() {
                        return Some((ql, qc, "an attribute value with no closing quote".into()));
                    }
                    bump!(1);
                    continue;
                }
                if b[i] == '/' {
                    selfclose = true;
                    bump!(1);
                    continue;
                }
                if b[i] == '>' {
                    bump!(1);
                    break;
                }
                selfclose = false;
                bump!(1);
            }
            if closing {
                match stack.pop() {
                    Some((open, _, _)) if open == name => {}
                    Some((open, ol, oc)) => {
                        return Some((
                            l0,
                            c0,
                            format!("`</{name}>` closes `<{open}>`, opened at line {ol} column {oc}"),
                        ))
                    }
                    None => return Some((l0, c0, format!("`</{name}>` closes nothing"))),
                }
            } else if !selfclose {
                if stack.is_empty() {
                    roots += 1;
                    if roots > 1 {
                        return Some((l0, c0, format!("`<{name}>` is a second root element")));
                    }
                }
                stack.push((name, l0, c0));
            } else if stack.is_empty() {
                roots += 1;
                if roots > 1 {
                    return Some((l0, c0, format!("`<{name}/>` is a second root element")));
                }
            }
        } else {
            bump!(1);
        }
    }
    if let Some((open, ol, oc)) = stack.pop() {
        return Some((ol, oc, format!("`<{open}>` is never closed")));
    }
    if roots == 0 {
        return Some((1, 1, "no root element at all".into()));
    }
    None
}

/// The commit this host is being built from, and whether the tree was clean.
///
/// **Emitted for every target, before anything else can return early.** A
/// provenance stamp that is only present on some builds is worse than none:
/// the check that reads it would then have to treat "absent" as "fine", and
/// absent is exactly the state it exists to object to.
///
/// # Why the same git command the core uses
///
/// The core stamps itself with `git log --pretty=format:%h -n 1`
/// (`src/build/GitVersion.zig`). `%h` abbreviates to whatever `core.abbrev`
/// says -- seven characters usually, nine in this repository, and it grows
/// as the history does. **Running a different command here would make the
/// two stamps differ in length for a reason that has nothing to do with
/// whether they match**, and a length difference read as a mismatch is a
/// false alarm. Same command, same abbreviation, by construction.
///
/// # What "dirty" is and is not
///
/// `git status --porcelain` says the working tree had uncommitted changes.
/// **It says nothing about which**, and it over-reports on purpose: an edit
/// to a document marks the build dirty even though no byte of the binary
/// changed. That is the safe direction -- the flag downgrades how much a
/// matching commit is worth, and never turns a match into a mismatch.
///
/// This matters here more than it would elsewhere: several people edit this
/// one tree at the same time, so "same commit" and "same source" come apart
/// routinely.
///
/// # The unknown case
///
/// No git, no repository, a source tarball: the stamp is **empty**. Empty is
/// not a value that can accidentally equal anything -- which is the whole
/// point, because the core has a fallback of its own (`0000000`) and two
/// fallbacks comparing equal would manufacture a match out of two absences.
fn emit_provenance() {
    // `windows/host` -> the repository root.
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default())
        .join("..")
        .join("..");

    let git = |args: &[&str]| -> Option<String> {
        let out = Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(args)
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
    };

    // Identical to `GitVersion.zig`'s, deliberately -- see above.
    let commit = git(&["-c", "log.showSignature=false", "log", "--pretty=format:%h", "-n", "1"])
        .unwrap_or_default();
    let dirty = match git(&["status", "--porcelain"]) {
        Some(s) => !s.is_empty(),
        // Could not ask. Not "clean": an unanswered question must not be
        // recorded as a reassuring answer.
        None => false,
    };

    println!("cargo:rustc-env=POLTER_HOST_COMMIT={commit}");
    println!("cargo:rustc-env=POLTER_HOST_DIRTY={}", if dirty { "1" } else { "0" });

    // So a new commit actually re-stamps the binary. Missing paths are
    // harmless here: cargo re-runs the script, which is the safe direction.
    for p in ["HEAD", "index"] {
        println!("cargo:rerun-if-changed={}", root.join(".git").join(p).display());
    }
}

fn main() {
    // **First.** Everything below can return early for a non-Windows target,
    // and a stamp that depends on the target is a stamp the reader has to
    // reason about.
    emit_provenance();

    println!("cargo:rerun-if-changed=polter.rc");
    println!("cargo:rerun-if-changed=polter.manifest");

    // **Before the target check, on purpose.** A manifest that does not parse
    // is broken on every machine, and the one that reads it last is the
    // loader on a user's desktop. Failing here is the only moment where the
    // fault is cheap.
    let manifest = std::fs::read_to_string("polter.manifest")
        .unwrap_or_else(|e| panic!("polter.manifest could not be read: {e}"));
    if let Some((line, col, what)) = manifest_fault(&manifest) {
        panic!(
            "polter.manifest is not well-formed XML: line {line} column {col}: {what}.\n\
             \n\
             This is a hard failure and not a warning. An exe with a malformed \
             manifest does not start, and every other signal is green: windres \
             embeds the bytes without reading them, the .rsrc section is there, \
             the text is inside the exe, and the build exits 0."
        );
    }

    let target = std::env::var("TARGET").unwrap_or_default();
    if !target.contains("windows") {
        return;
    }

    // The gnu toolchain's resource compiler, named for the target it is for.
    // `windres` alone is the host's, if the host has one at all.
    let windres = if target.contains("gnu") {
        "x86_64-w64-mingw32-windres"
    } else {
        // The msvc toolchain uses `rc.exe`, whose command line differs. Nobody
        // builds this port that way today, so it is a skip with a reason
        // rather than a second untested code path.
        println!(
            "cargo:warning=no resource compiler wired up for {target}: the manifest is NOT \
             embedded, so every standard control (the palette filter, the search box, the \
             rename box, the title box, the settings page) will be drawn by comctl32 v5 -- \
             the pre-XP look."
        );
        return;
    };

    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("polter-manifest.o");
    let status = Command::new(windres)
        .args(["polter.rc", "-O", "coff", "-o"])
        .arg(&out)
        .status();

    match status {
        Ok(s) if s.success() => {
            // Handed straight to the linker: the object holds one `.rsrc`
            // section and nothing else.
            println!("cargo:rustc-link-arg={}", out.display());
        }
        Ok(s) => println!(
            "cargo:warning={windres} failed ({s}); the manifest is NOT embedded and the \
             standard controls will be drawn by comctl32 v5 -- the pre-XP look."
        ),
        Err(e) => println!(
            "cargo:warning={windres} could not be run ({e}); the manifest is NOT embedded and \
             the standard controls will be drawn by comctl32 v5 -- the pre-XP look."
        ),
    }
}
