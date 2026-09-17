//! The host's user-visible strings, through the catalogues that already exist.
//!
//! # Why this file exists at all
//!
//! `plugins.rs` states the rule: "Polter's own text goes through gettext
//! (`po/`, `src/os/i18n.zig`)". **The Windows host was the one place that did
//! not**, and it did not because there was nowhere for a translation to go:
//! `src/build/GhosttyI18n.zig` walks `src/apprt/gtk` and names two more files
//! by hand, and `windows/host/src` was in neither list. A string here could
//! not reach the template, so no translator in any of the 32 languages was
//! ever offered one.
//!
//! That is the same finding `src/cli/chat.zig` already carries in that build
//! file -- "which is why every string in it was a Chinese literal for as long
//! as it existed" -- one platform over, and the settings page shows it in the
//! other direction: **its buttons are in English while the menu two windows
//! away is in Chinese.** Neither is translated; they are hardcoded in
//! different languages.
//!
//! # What this is not
//!
//! **Not a second mechanism.** `libghostty` already exports
//! `ghostty_translate`, the core already calls `i18n.init` from
//! `global.zig`'s startup, and the catalogues are in `po/`. Every piece was
//! there; the host simply never resolved the symbol. Inventing a string table
//! here would have been a second answer to a question that already had one.
//!
//! # What a caller has to know
//!
//! **The msgid is English and it is the fallback.** `ghostty_translate`
//! returns its argument unchanged when the catalogue has no entry, so a
//! string that has not been translated yet shows in English rather than
//! disappearing or showing a key. That is also why `tr` is safe to call
//! before anything is translated: the visible result is exactly today's.
//!
//! ⚠️ **The name `tr` is load-bearing.** `xgettext` is invoked with
//! `--keyword=tr` (for the conversations window's own wrapper), so calls
//! written as `tr("Save")` are extracted with no further argument. Renaming
//! this function without changing that build file takes every string in the
//! host back out of the template, and nothing goes red -- the strings keep
//! working until somebody updates the translations, and then quietly stop.
//! That exact failure is described in `src/build/GhosttyI18n.zig`.

use std::ffi::CString;

/// A user-visible string, translated if the catalogue has it.
///
/// Takes and returns an owned `String` rather than a `&'static str` because
/// the core hands back a pointer it owns and the caller needs to keep the
/// text; copying it is the only honest thing to do with a borrow whose
/// lifetime is the DLL's.
pub fn tr(msgid: &str) -> String {
    // **Before the API is loaded, the msgid is the answer.** `crate::api()`
    // dereferences the pointer without checking it, so this asks the guarded
    // way: the settings page cannot open before startup, but a log line or a
    // panic path could reach a string earlier, and a null deref for the sake
    // of a translation would be a poor trade.
    let Some(api) = crate::api_opt() else {
        return msgid.to_string();
    };
    let Ok(c) = CString::new(msgid) else {
        // An interior NUL. Nothing in this host has one; if one appears, the
        // English is still the right thing to show.
        return msgid.to_string();
    };
    let out = unsafe { (api.translate)(c.as_ptr()) };
    if out.is_null() {
        return msgid.to_string();
    }
    unsafe { std::ffi::CStr::from_ptr(out) }
        .to_string_lossy()
        .into_owned()
}

/// Mark a string for extraction **without translating it here**.
///
/// For strings that have to sit in a `const` -- a table cannot call a
/// function -- so the marker says "this is ours to translate" where a person
/// reads it, and `tr` does the lookup at the point of use.
///
/// ⚠️ **Without this the string is translated at runtime and absent from the
/// catalogue**, which is the worst of the three states: `tr` looks up a msgid
/// no translator was ever offered, it always misses, and nothing anywhere
/// says why.
pub const fn n_(s: &'static str) -> &'static str {
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    // **Generated, and it is everything.** `build.rs` walks
    // `windows/host/src` and writes one entry per `.rs` file, so a file
    // added tomorrow is checked tomorrow. The list this replaced was
    // hand-written with a comment asking people to register their file,
    // and within the hour a new file had gone unregistered -- silently,
    // which is the exact failure shape this whole test exists to end.
    include!(concat!(env!("OUT_DIR"), "/i18n-sources.rs"));

    /// Files deliberately left out, each with the reason. **Anything not
    /// named here is checked**, so leaving a file alone now costs a line
    /// somebody else can read and argue with.
    const EXEMPT: &[(&str, &str)] = &[(
        "i18n.rs",
        "its own test fixtures are written as calls, so the scanner would \
         report the scanner's sample strings as product text",
    )];


    /// **Every msgid this host shows must have a translation to find.**
    ///
    /// This is the gap that let a whole round of work look finished when it
    /// was not. `windows/tools/translated-strings-reach-the-user.py` asks
    /// "can the host reach the catalogue?" and says yes; it says so in its
    /// own last line -- *NOT CHECKED: whether the catalogue for the user\'s
    /// language is installed*. Nothing asked the other half: **is there an
    /// entry?** A msgid nobody has translated behaves exactly like a correct
    /// one on the machine the port is written on, and shows English to the
    /// person the work was for.
    ///
    /// A failure here is not a bug in the code above it. It is a list of
    /// phrases somebody has to put in `po/zh_CN.po`, and the message prints
    /// that list so it can be handed over as it stands.
    ///
    /// **Every file in `windows/host/src` is checked**, from a list
    /// `build.rs` generates by walking the directory. It used to be a list
    /// written by hand, and that defaulted the wrong way: a file nobody
    /// remembered to add was not checked, and *not checked* is indis-
    /// tinguishable from *nothing wrong*. A file that should be left out is
    /// named in `EXEMPT` below with the reason, where it can be argued with.
    ///
    /// ⚠️ A consequence worth expecting: while several people are converting
    /// different files, this test reports **their** untranslated msgids too.
    /// That is the honest reading -- those strings really would show in
    /// English -- and the list names the file, so it is clear whose it is.
    #[test]
    fn every_msgid_this_host_shows_has_a_translation() {
        // `SOURCES` and `EXEMPT` are just below the module header.
        const PO: &str = include_str!("../../../po/zh_CN.po");

        // The floor under the floor: pointed at an empty or wrong file, every
        // lookup below would miss and the failure would read as "nothing is
        // translated" rather than "the test is broken".
        assert!(
            PO.contains("msgid \"Close Tab\"") && PO.contains("Language: zh_CN"),
            "the included catalogue is not po/zh_CN.po any more"
        );

        let mut missing: Vec<String> = Vec::new();
        for (name, src) in SOURCES {
            if EXEMPT.iter().any(|(n, _)| n == name) {
                continue;
            }
            for msgid in extract_msgids(src) {
                match translation_of(PO, &msgid) {
                    Some(t) if !t.is_empty() => {}
                    Some(_) => missing.push(format!("{name}: {msgid:?} -- entry exists, msgstr empty")),
                    None => missing.push(format!("{name}: {msgid:?} -- no entry")),
                }
            }
        }
        missing.sort();
        missing.dedup();
        assert!(
            missing.is_empty(),
            "{} msgid(s) would show in English on a Chinese machine:\n{}",
            missing.len(),
            missing.join("\n")
        );
    }

    /// **The floor under the scanner above, and it earned it.** The first
    /// version counted `push_str("…")` as a translated string, because that
    /// name ends in the two letters it was looking for. A scanner that
    /// over-reports does not look broken: it looks like a longer list of work
    /// to do, and the extra line is made of a real file and a real string.
    ///
    /// The negative cases are the point. The positive ones only show it still
    /// does anything at all.
    #[test]
    fn the_scanner_counts_calls_and_not_names_that_end_the_same_way() {
        let found = extract_msgids(
            concat!(
                "let a = tr(\"yes one\");\n",
                "let b = n_(\"yes two\");\n",
                "let c = crate::i18n::tr(\"yes three\");\n",
                "preview.push_str(\"no, a name ending in t r\");\n",
                "thing.attr(\"no, another one\");\n",
                "let d = concat_n_(\"no, a name ending in n underscore\");\n",
                "// tr(\"no, this one is a comment\")\n",
            )
            .to_string()
            .as_str(),
        );
        assert_eq!(found, vec!["yes one", "yes two", "yes three"]);
    }

    /// Pull out what a `tr(...)` or `n_(...)` call was given, when it was
    /// given a literal. Comment lines are skipped: a sentence *about* one of
    /// these calls contains the call, and a scanner that reads comments would
    /// count the explanation as a string the product shows.
    fn extract_msgids(src: &str) -> Vec<String> {
        let mut out = Vec::new();
        for line in src.lines() {
            if line.trim_start().starts_with("//") {
                continue;
            }
            let mut rest = line;
            while let Some(at) = rest.find("(\"") {
                let (before, from) = rest.split_at(at);
                // ⚠️ **The name has to end where the call does.**
                // `preview.push_str("…")` ends with `tr` too, and the first
                // version of this counted it: the report then named a string
                // the product never translates, which reads exactly like a
                // real omission. So the character before the name must not be
                // one a name could continue with.
                let is_call = ["tr", "n_"].iter().any(|name| {
                    before.strip_suffix(*name).is_some_and(|head| {
                        !head
                            .chars()
                            .next_back()
                            .is_some_and(|c| c.is_alphanumeric() || c == '_')
                    })
                });
                rest = &from[2..];
                if !is_call {
                    continue;
                }
                let mut lit = String::new();
                let mut chars = rest.char_indices();
                let mut end = None;
                while let Some((i, c)) = chars.next() {
                    match c {
                        '\\' => {
                            if let Some((_, e)) = chars.next() {
                                lit.push(match e {
                                    'n' => '\n',
                                    't' => '\t',
                                    other => other,
                                });
                            }
                        }
                        '"' => {
                            end = Some(i);
                            break;
                        }
                        other => lit.push(other),
                    }
                }
                if let Some(i) = end {
                    rest = &rest[i + 1..];
                    if !lit.is_empty() {
                        out.push(lit);
                    }
                }
            }
        }
        out
    }

    /// The `msgstr` for an exact `msgid`, or `None` when the catalogue has no
    /// such entry.
    ///
    /// ⚠️ **Continuation lines are the whole reason this is a parser and not
    /// a `contains`.** `xgettext` wraps a long entry over several quoted
    /// lines, so the paste warning this host reuses does not appear anywhere
    /// in the file as one searchable string. A check that only understood
    /// single-line entries would call the longest, most-reused phrases
    /// "missing" -- and the report would look exactly like real work to do.
    fn translation_of(po: &str, msgid: &str) -> Option<String> {
        let mut id = String::new();
        let mut msg = String::new();
        let mut in_id = false;
        let mut in_str = false;
        let mut found: Option<String> = None;

        let flush = |id: &str, msg: &str, found: &mut Option<String>| {
            if found.is_none() && id == msgid {
                *found = Some(msg.to_string());
            }
        };

        for line in po.lines() {
            let t = line.trim();
            if let Some(rest) = t.strip_prefix("msgid ") {
                flush(&id, &msg, &mut found);
                id.clear();
                msg.clear();
                id.push_str(&unquote(rest));
                in_id = true;
                in_str = false;
            } else if let Some(rest) = t.strip_prefix("msgstr ") {
                msg.push_str(&unquote(rest));
                in_id = false;
                in_str = true;
            } else if t.starts_with('"') {
                let piece = unquote(t);
                if in_id {
                    id.push_str(&piece);
                } else if in_str {
                    msg.push_str(&piece);
                }
            } else if t.is_empty() {
                flush(&id, &msg, &mut found);
                id.clear();
                msg.clear();
                in_id = false;
                in_str = false;
            }
        }
        flush(&id, &msg, &mut found);
        found
    }

    /// One `"..."` line from a catalogue, with the escapes gettext writes
    /// turned back into the characters they stand for.
    fn unquote(s: &str) -> String {
        let body = s.trim().trim_start_matches('"').trim_end_matches('"');
        let mut out = String::new();
        let mut chars = body.chars();
        while let Some(c) = chars.next() {
            if c != '\\' {
                out.push(c);
                continue;
            }
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(other) => out.push(other),
                None => {}
            }
        }
        out
    }

    /// **Runs on Windows only**, like every test in this crate, and what it
    /// pins is the fallback rather than any translation: with no API loaded
    /// the msgid comes back unchanged, which is the property that makes it
    /// safe to wrap a string before anybody has translated it.
    #[test]
    fn an_untranslated_string_is_its_own_msgid() {
        // **Through variables on purpose.** Written as `tr("Save")` this test
        // would be extracted like any other call site: the catalogue would
        // carry a source reference into a test, and `tr("")` would put an
        // empty msgid in the template -- which gettext reserves for the file
        // header and warns about by name.
        let sample = "Save";
        assert_eq!(tr(sample), sample);
        let empty = "";
        assert_eq!(tr(empty), empty);
    }

    /// `n_` is the identity, and this is here because its whole job is to be
    /// invisible at runtime: if it ever stopped returning its argument, every
    /// phrase marked with it would break at once.
    #[test]
    fn the_extraction_marker_changes_nothing() {
        let s = "Keeps the conversations";
        assert_eq!(n_("Keeps the conversations"), s);
    }
}
