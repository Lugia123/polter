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
