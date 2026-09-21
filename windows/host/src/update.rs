//! Task 649: "is there a newer Polter release", asked of GitHub and nothing
//! else.
//!
//! # Only a prompt, on purpose
//!
//! The user's own words: "可以做成看 github，但只给提示，不做自动更新，先简单点，
//! mac 也能用" -- look at GitHub, but only prompt, no auto-update, keep it
//! simple, and match macOS. So this module downloads nothing and replaces
//! nothing; it makes one GET request, compares two version strings, and if
//! the remote one is newer it raises a desktop notification through
//! `notify::on_notification` -- the same mechanism `OSC 9`/`OSC 777` already
//! use to tell a person something while they are looking elsewhere. Clicking
//! it raises the window; it does not open a browser, because that is
//! `notify.rs`'s existing click behaviour and giving this one row a
//! different behaviour would be a second, undocumented kind of notification.
//!
//! # Why WinHTTP and not a crate
//!
//! `Cargo.toml` has no HTTP client dependency today, and reaching for one
//! (`reqwest`, `ureq`) would pull in an async runtime or a sizeable pure-Rust
//! TLS stack for a request this host makes at most a few times an hour, on
//! demand. WinHTTP ships with every supported Windows version, handles TLS
//! itself, and is already the shape this host reaches for -- see the
//! `windows` crate dependency this file's `Cargo.toml` entry sits next to.
//!
//! # Why a background thread and not `WINHTTP_FLAG_ASYNC`
//!
//! Every WinHTTP call below is the synchronous kind, which blocks the
//! calling thread until the network answers or times out. Doing that on the
//! UI thread would freeze every window in the process for as long as GitHub
//! takes to respond, so the request runs on its own thread
//! (`std::thread::Builder::new().spawn`, the same primitive `main.rs`'s
//! watchdog already uses) and reports back only through `plogf!` and
//! `notify::on_notification`, both of which are already safe to call from
//! any thread.
//!
//! # What this does not do
//!
//! No background polling, no startup check, no download, no install. The
//! check only runs when `ACTION_CHECK_FOR_UPDATES` arrives, which today means
//! only when a person opens the menu row or the palette command -- exactly
//! as manual as the macOS side's `checkForUpdates()`.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};

use windows::core::PCWSTR;
use windows::Win32::Foundation::{GetLastError, HWND};
use windows::Win32::Networking::WinHttp::{
    WinHttpCloseHandle, WinHttpConnect, WinHttpOpen, WinHttpOpenRequest, WinHttpQueryHeaders,
    WinHttpReadData, WinHttpReceiveResponse, WinHttpSendRequest, WinHttpSetTimeouts,
    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_FLAG_SECURE, WINHTTP_OPEN_REQUEST_FLAGS,
    WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE,
};

use crate::{notify, plogf};

/// This host's own version, computed by `build.rs` the same way
/// `PolterVersion.zig` computes the macOS bundle's `CFBundleShortVersionString`
/// -- see that function's doc comment for why the two must agree.
pub const VERSION: &str = env!("POLTER_VERSION");

/// `"tag"`, `"branch"`, or `"fallback"` -- `build.rs`'s `emit_polter_version`,
/// mirroring `PolterVersion.zig`'s `Source`. `check` refuses to compare
/// `VERSION` against GitHub when this is `"fallback"`: see the comment on
/// that arm for why.
pub const VERSION_SOURCE: &str = env!("POLTER_VERSION_SOURCE");

const HOST: &str = "api.github.com";
const PATH: &str = "/repos/Lugia123/polter/releases/latest";

/// How many checks are in flight, so a person mashing the menu item does not
/// pile up an unbounded number of background threads each holding their own
/// WinHTTP session. One at a time; a second request while the first is still
/// running is dropped rather than queued, because the answer to "is there an
/// update" does not change in the seconds a request takes.
static IN_FLIGHT: AtomicU32 = AtomicU32::new(0);

/// What the response said, before it is turned into a log line or a
/// notification.
enum Outcome {
    /// A newer, non-draft, non-prerelease release exists.
    Newer { version: String, html_url: String },
    /// Reached GitHub; nothing newer.
    UpToDate,
    /// GitHub answered 403. Anonymous requests are capped at 60/hour/IP.
    ///
    /// **Its own case on purpose.** A 403 and "reached GitHub, nothing
    /// newer" must never produce the same log line -- that collapse is
    /// exactly what would make a rate limit unfalsifiable from the log
    /// task 649's verification reads.
    RateLimited,
    Failed(String),
}

/// `ACTION_CHECK_FOR_UPDATES`'s handler. Returns immediately; the request
/// and everything after it happen on a spawned thread.
///
/// `true` means the action was acted on -- a check is now running, or one
/// already was. `false` is reserved for the one way this can fail before it
/// starts: the thread itself would not spawn.
pub fn check(origin: Option<HWND>) -> bool {
    // **Checked first, before `IN_FLIGHT` and before any thread spawns.**
    // Task 651: a build not cut from a tag or a `feature/vX.Y` branch
    // reports `VERSION` as `0.1.<commit count>` -- indistinguishable, by the
    // numbers alone, from a real `0.1.x` release. Comparing that guess
    // against GitHub's latest tag would almost always say "update
    // available", because a fallback build is normally a dev checkout ahead
    // of the last release, not behind it -- which is an update prompt asking
    // the person to downgrade. No network request goes out for this arm.
    if VERSION_SOURCE == "fallback" {
        // process-wide: whether this build can name its own version is a
        // fact about the build, not about the window that asked
        plogf!(
            "[update] check_for_updates: cannot tell what version this build is \
             (current={VERSION}, POLTER_VERSION_SOURCE=fallback); not comparing against \
             GitHub -- a fallback build is usually ahead of the last release, not behind it"
        );
        notify::on_notification(
            origin,
            Some("Can't Check for Updates".to_string()),
            Some(
                "This build's own version could not be determined (it was not built from a \
                 release tag or version branch)."
                    .to_string(),
            ),
        );
        return true;
    }

    if IN_FLIGHT.fetch_add(1, Ordering::AcqRel) > 0 {
        IN_FLIGHT.fetch_sub(1, Ordering::AcqRel);
        // not-gated: `IN_FLIGHT > 0` is not a suppressor sitting in front of
        // an otherwise-unconditional line -- it *is* the event this line
        // reports (a second check was requested while one was still
        // running). Its absence from the log means that never happened, not
        // that this arm went unreached: `check` gets called on every press
        // of the menu row or palette command, gate included.
        //
        // process-wide: whether a check is already running is a fact about
        // the process, not about the window that asked again
        plogf!("[update] check_for_updates: one is already in flight; not starting a second");
        return true;
    }

    // `HWND` is a raw pointer under the hood and is not `Send`; carried
    // across the thread boundary as the bare address it wraps; `notify`'s
    // own `on_notification` already does the same for its `frame` argument,
    // one layer further in.
    let origin_addr = origin.map(|h| h.0 as isize);

    let spawned = std::thread::Builder::new()
        .name("polter-update-check".into())
        .spawn(move || {
            // `Builder::name` above is Rust-side only -- invisible to
            // Windows and to anything sampling the process. This is the
            // half a debugger or `NtQueryInformationThread` can actually
            // read, and the log line it writes is how "is this the update
            // check or something else" gets answered from `[thread]` alone.
            crate::name_this_thread("polter-update-check");
            let origin = origin_addr.map(|a| HWND(a as *mut std::ffi::c_void));
            let outcome = fetch_latest();
            report(origin, outcome);
            IN_FLIGHT.fetch_sub(1, Ordering::AcqRel);
        });

    if let Err(e) = spawned {
        IN_FLIGHT.fetch_sub(1, Ordering::AcqRel);
        // process-wide: a thread that failed to start belongs to the
        // process, not to any one window
        plogf!("[update] check_for_updates: could not start the check thread: {e:?}");
        return false;
    }
    true
}

/// Turns an [`Outcome`] into the one log line and (for `Newer` only) the one
/// notification task 649 asks for.
fn report(origin: Option<HWND>, outcome: Outcome) {
    match outcome {
        Outcome::Newer { version, html_url } => {
            // process-wide: whether a newer release exists is a fact about
            // this build, not about the window that triggered the check
            plogf!(
                "[update] check_for_updates: current={VERSION} latest={version} -> update \
                 available ({html_url})"
            );
            notify::on_notification(
                origin,
                Some("Update Available".to_string()),
                Some(format!("Polter {version} is available: {html_url}")),
            );
        }
        Outcome::UpToDate => {
            // process-wide: whether a newer release exists is a fact about
            // this build, not about the window that triggered the check
            plogf!("[update] check_for_updates: current={VERSION} -> up to date");
        }
        Outcome::RateLimited => {
            // **Must read differently from `UpToDate` above.** GitHub caps
            // anonymous requests at 60/hour/IP; a 403 means the question was
            // never actually answered, and saying so is the entire point of
            // this arm existing separately from it.
            //
            // process-wide: same as the other two arms here
            plogf!(
                "[update] check_for_updates: GitHub rate-limited this request (403); this is \
                 NOT \"up to date\" -- the check did not run"
            );
        }
        Outcome::Failed(reason) => {
            // process-wide: same as the other arms here
            plogf!("[update] check_for_updates: failed: {reason}");
        }
    }
}

/// The blocking half: one HTTPS GET, entirely synchronous WinHTTP calls.
/// Runs on the thread `check` spawned, never on the caller's.
fn fetch_latest() -> Outcome {
    let session = match Session::open() {
        Ok(s) => s,
        Err(e) => return Outcome::Failed(e),
    };

    let (status, body) = match session.get(HOST, PATH) {
        Ok(r) => r,
        Err(e) => return Outcome::Failed(e),
    };

    if status == 403 {
        return Outcome::RateLimited;
    }
    if status != 200 {
        return Outcome::Failed(format!("unexpected HTTP status {status}"));
    }

    let value: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => return Outcome::Failed(format!("could not parse GitHub's response: {e}")),
    };
    let Some(tag_name) = value.get("tag_name").and_then(|v| v.as_str()) else {
        return Outcome::Failed("GitHub's response had no `tag_name`".to_string());
    };
    let html_url = value.get("html_url").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    let draft = value.get("draft").and_then(|v| v.as_bool()).unwrap_or(false);
    let prerelease = value.get("prerelease").and_then(|v| v.as_bool()).unwrap_or(false);

    if draft || prerelease {
        return Outcome::UpToDate;
    }

    let latest_version = tag_name.strip_prefix('v').unwrap_or(tag_name);

    let (Some(latest), Some(current)) = (semver(latest_version), semver(VERSION)) else {
        return Outcome::Failed(format!(
            "could not compare versions (latest={latest_version:?} current={VERSION:?})"
        ));
    };

    if latest > current {
        Outcome::Newer { version: latest_version.to_string(), html_url }
    } else {
        Outcome::UpToDate
    }
}

/// `"0.6.657"` -> `Some((0, 6, 657))`. Anything that is not exactly three
/// dot-separated integers is `None` rather than guessed at -- `VERSION`
/// never carries a `-dev` suffix (see `build.rs`'s `emit_polter_version`), so
/// there is no such suffix to strip here either.
fn semver(s: &str) -> Option<(u32, u32, u32)> {
    let mut parts = s.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}

/// A UTF-16, NUL-terminated copy of an ASCII string literal, for the WinHTTP
/// calls that want `PCWSTR`. Every caller here passes a `'static` ASCII
/// constant (`HOST`, `PATH`, header names), never anything from the
/// response, so a lossy or partial conversion is not a concern this needs to
/// handle.
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// `windows-rs` binds every `WinHttp*` handle as a bare `*mut c_void` --
/// there is no `HINTERNET` newtype to lean on for a null check, so this
/// wrapper is that check, done once.
struct Handle(*mut c_void);

impl Handle {
    fn open(raw: *mut c_void, what: &str) -> Result<Self, String> {
        if raw.is_null() {
            let err = unsafe { GetLastError() };
            return Err(format!("{what} failed: {err:?}"));
        }
        Ok(Self(raw))
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = WinHttpCloseHandle(self.0);
            }
        }
    }
}

/// One WinHTTP session handle, closed on drop.
struct Session(Handle);

impl Session {
    fn open() -> Result<Self, String> {
        let agent = wide("Polter-UpdateCheck/1.0");
        let raw = unsafe {
            WinHttpOpen(
                PCWSTR(agent.as_ptr()),
                WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                PCWSTR::null(),
                PCWSTR::null(),
                0,
            )
        };
        Ok(Self(Handle::open(raw, "WinHttpOpen")?))
    }

    /// One GET over HTTPS, port 443. Returns the status code and the whole
    /// body -- GitHub's release JSON is a few kilobytes, nowhere near
    /// worth streaming.
    fn get(&self, host: &str, path: &str) -> Result<(u32, Vec<u8>), String> {
        let host_w = wide(host);
        let raw = unsafe { WinHttpConnect(self.0.0, PCWSTR(host_w.as_ptr()), 443, 0) };
        let connect = Handle::open(raw, "WinHttpConnect")?;

        let path_w = wide(path);
        let verb = wide("GET");
        let accept = wide("application/vnd.github+json");
        // `WinHttpOpenRequest` wants a NUL-terminated array of `PCWSTR`, not
        // an `Option` of one -- an empty accept list is spelled with a null
        // pointer here, not `None`.
        let accept_types = [PCWSTR(accept.as_ptr()), PCWSTR::null()];
        let raw = unsafe {
            WinHttpOpenRequest(
                connect.0,
                PCWSTR(verb.as_ptr()),
                PCWSTR(path_w.as_ptr()),
                PCWSTR::null(),
                PCWSTR::null(),
                accept_types.as_ptr(),
                WINHTTP_OPEN_REQUEST_FLAGS(WINHTTP_FLAG_SECURE.0),
            )
        };
        let request = Handle::open(raw, "WinHttpOpenRequest")?;

        // A hung DNS lookup or a stalled server must not leave the check
        // thread blocked forever -- there is no cancellation path back to
        // it once `check` has returned.
        unsafe { WinHttpSetTimeouts(request.0, 10_000, 10_000, 10_000, 10_000) }
            .map_err(|e| format!("WinHttpSetTimeouts: {e}"))?;

        unsafe { WinHttpSendRequest(request.0, None, None, 0, 0, 0) }
            .map_err(|e| format!("WinHttpSendRequest: {e}"))?;

        unsafe { WinHttpReceiveResponse(request.0, std::ptr::null_mut()) }
            .map_err(|e| format!("WinHttpReceiveResponse: {e}"))?;

        let mut status: u32 = 0;
        let mut status_size = std::mem::size_of::<u32>() as u32;
        unsafe {
            WinHttpQueryHeaders(
                request.0,
                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                PCWSTR::null(),
                Some(&mut status as *mut u32 as *mut c_void),
                &mut status_size,
                std::ptr::null_mut(),
            )
        }
        .map_err(|e| format!("WinHttpQueryHeaders: {e}"))?;

        let mut body = Vec::new();
        loop {
            let mut buf = [0u8; 8192];
            let mut read: u32 = 0;
            unsafe {
                WinHttpReadData(request.0, buf.as_mut_ptr() as *mut c_void, buf.len() as u32, &mut read)
            }
            .map_err(|e| format!("WinHttpReadData: {e}"))?;
            if read == 0 {
                break;
            }
            body.extend_from_slice(&buf[..read as usize]);
            // A body larger than this is not a release JSON GitHub would
            // ever send; treat it as a runaway response rather than read
            // forever.
            if body.len() > 1_048_576 {
                return Err("response exceeded 1 MiB; aborting".to_string());
            }
        }

        Ok((status, body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_parses_exactly_three_components() {
        assert_eq!(semver("0.6.657"), Some((0, 6, 657)));
        assert_eq!(semver("0.6"), None);
        assert_eq!(semver("0.6.657.1"), None);
        assert_eq!(semver("0.6.dev"), None);
    }

    #[test]
    fn newer_compares_lexicographically_by_component() {
        assert!(semver("0.7.0").unwrap() > semver("0.6.999").unwrap());
        assert!(semver("0.6.658").unwrap() > semver("0.6.657").unwrap());
        assert!(!(semver("0.6.657").unwrap() > semver("0.6.657").unwrap()));
    }

    // A real-machine floor for task 651's fallback guard was run here (not
    // kept as a permanent test): `crate::test_log::logged` around
    // `check(None)`, rebuilt three times on this same worktree.
    //
    // Detached HEAD (no tag, no branch), guard disabled -- reproduces the
    // original bug:
    //
    //   [update] check_for_updates: current=0.1.693 latest=0.6.656 -> update available (…)
    //
    // Detached HEAD, guard restored -- the fix:
    //
    //   [update] check_for_updates: cannot tell what version this build is
    //   (current=0.1.693, POLTER_VERSION_SOURCE=fallback); not comparing
    //   against GitHub -- a fallback build is usually ahead of the last
    //   release, not behind it
    //
    // On a branch named `tmp-verify-651` (does not match `feature/vX.Y`) --
    // the same fallback line as detached HEAD, confirming both "no branch at
    // all" and "on a branch with an unversioned name" collapse to the same
    // safe answer.
    //
    // On a branch named `feature/v0.9` -- the guard does *not* fire, and the
    // ordinary comparison runs:
    //
    //   [update] check_for_updates: current=0.9.693 -> up to date
    //
    // confirming the guard is scoped to `fallback` and does not also
    // swallow a build that genuinely knows its version.
    //
    // Not kept permanently because `VERSION_SOURCE` is baked in at compile
    // time from wherever this crate was built: a hard assertion on it would
    // pass or fail depending on which of the above this crate happened to be
    // built from, rather than on whether the guard is correct -- and no
    // other test in this crate makes a live network call, which the
    // non-fallback half of this floor requires.
}
