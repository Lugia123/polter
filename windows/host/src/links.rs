//! Opening a URL, and hovering over one.
//!
//! Two actions, one file, because they are the two halves of the same thing:
//! `mouse_over_link` says a link is under the pointer and `open_url` says one
//! was chosen. Both carry text the terminal produced, and both have to answer
//! "who chose this?" before doing anything with it.
//!
//! **The decision about what may be opened is not here.** It is
//! `polter-urlpolicy`, a crate with no dependencies, because `polter-host`
//! cannot be built for the machine this port is written on and a security
//! rule nobody can run a test against is a security rule nobody has checked.
//! What is here is the Windows half: expanding `~`, calling `ShellExecuteW`,
//! and reading its answer.

use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

use polter_urlpolicy::{verdict, Verdict};

use crate::{plogf, wlogf};

/// `~` and `~/…` to the user's profile directory.
///
/// **Only a leading `~` followed by nothing or a separator.** A file actually
/// named `~weird` exists on some machines and expanding it would open the
/// wrong thing; the macOS side has the same narrowing through
/// `standardizingPath`.
fn expand_home(url: &str) -> String {
    let rest = match url.strip_prefix('~') {
        Some(r) => r,
        None => return url.to_string(),
    };
    if !(rest.is_empty() || rest.starts_with('/') || rest.starts_with('\\')) {
        return url.to_string();
    }
    match std::env::var("USERPROFILE") {
        Ok(home) if !home.is_empty() => format!("{home}{rest}"),
        _ => url.to_string(),
    }
}

/// Hand `url` to the shell. Returns whether it started, and how long the call
/// took.
///
/// `ShellExecuteW` returns a value typed as an `HINSTANCE` that is not one:
/// anything **at or below 32** is an error code. The same reading is in
/// `main.rs`'s `open_config` arm, which is the other caller in this port.
///
/// # Why there is a line before the call and not only after it
///
/// This runs **on the thread that owns every window in this process**, and it
/// is unbounded: `ShellExecuteW` goes into the shell, which may start a
/// process, load a handler, or put up UI of its own. Nothing here times it
/// out.
///
/// When it did not come back -- Ctrl+click on an OSC 8 link, and the main
/// thread never ran again -- **the log said nothing whatsoever**. Every line
/// this file wrote was on a way *out*: no URL, refused, or the result. So the
/// evidence for "it went in and never came out" was the *absence* of three
/// different lines, and an absence has three readings that look identical:
/// the click never arrived, a branch refused without logging, or the call is
/// still running. Telling them apart took half an hour and two process dumps.
///
/// One line before the call collapses that to a read, which is why it names
/// the call and says what its being last means.
fn shell_open(frame: Option<HWND>, url: &str) -> (bool, u128) {
    let wide: Vec<u16> = url.encode_utf16().chain(Some(0)).collect();
    match frame {
        Some(f) => wlogf!(
            f,
            "[link] handing {url:?} to ShellExecuteW on the thread that owns the windows; \
             IF THIS IS THE LAST LINE IN THE LOG, the call did not return"
        ),
        // process-wide: the action named no surface, so there is no window
        // this line could belong to -- and the line still has to exist,
        // because it is the one that says where the process went
        None => plogf!(
            "[link] handing {url:?} to ShellExecuteW on the thread that owns the windows; \
             IF THIS IS THE LAST LINE IN THE LOG, the call did not return"
        ),
    }
    let started = std::time::Instant::now();
    let r = unsafe {
        ShellExecuteW(
            None,
            windows::core::w!("open"),
            PCWSTR(wide.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    // **Reported even when it returns**, because "it came back after 9
    // seconds" and "it came back at once" are the same line without it -- and
    // the first is the reading that says this call is the thing to move off
    // this thread.
    (r.0 as usize > 32, started.elapsed().as_millis())
}

/// The `open_url` action.
///
/// `kind` is `ghostty_action_open_url_kind_e`; the only one that changes what
/// happens is `osc8`, which is the kind whose target was chosen by whatever
/// is running in the terminal rather than by the person at the keyboard.
///
/// # What the return value means here
///
/// `cb_action`'s boolean is a claim that the host performed the action, and
/// the core stops looking for another route when it hears `true`. **A refusal
/// returns `false`** -- the URL was not opened, and saying otherwise would
/// leave the core believing a link had been followed. A URL that was handed
/// to the shell and rejected *by the shell* also returns `false`, for the
/// same reason.
pub fn on_open_url(frame: Option<HWND>, kind: i32, url: Option<String>) -> bool {
    let Some(url) = url else {
        match frame {
            Some(f) => wlogf!(f, "[link] open_url with no URL (kind {kind}); nothing opened"),
            // process-wide: the action named no surface, so there is no window
            // this refusal belongs to
            None => plogf!("[link] open_url with no URL (kind {kind}); nothing opened"),
        }
        return false;
    };

    let osc8 = kind == crate::ffi::OPEN_URL_KIND_OSC8;
    if let Verdict::Refuse(why) = verdict(osc8, &url) {
        let detail = polter_urlpolicy::describe(&url);
        match frame {
            Some(f) => wlogf!(
                f,
                "[link] refused to open {url:?} (kind {kind}): {why} [{detail}]"
            ),
            // process-wide: a refusal about a URL, with no window to attribute
            // it to because the action named no surface
            None => plogf!("[link] refused to open {url:?} (kind {kind}): {why} [{detail}]"),
        }
        return false;
    }

    let target = expand_home(url.trim());
    let (ok, ms) = shell_open(frame, &target);
    match frame {
        Some(f) => wlogf!(f, "[link] open_url kind={kind} {target:?} -> {ok} in {ms}ms"),
        // process-wide: the action named no surface, so this line is about the
        // process opening something rather than about a window
        None => plogf!("[link] open_url kind={kind} {target:?} -> {ok} in {ms}ms"),
    }
    ok
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **The narrowing, not the expansion.** The expansion needs an
    /// environment variable and a real profile directory; the rule worth
    /// pinning is which strings are left alone.
    #[test]
    fn only_a_leading_tilde_before_a_separator_is_a_home_directory() {
        assert_eq!(expand_home("~weird/file"), "~weird/file");
        assert_eq!(expand_home("/tmp/~/x"), "/tmp/~/x");
        assert_eq!(expand_home("https://example.com/~user"), "https://example.com/~user");
    }
}
