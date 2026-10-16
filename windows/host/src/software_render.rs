//! Starting again with software rendering when the driver refuses the OpenGL
//! the renderer needs (#18).
//!
//! **The machine this is for.** A Windows box whose only display adapter is
//! virtual -- a server's BMC, many VMs, an RDP session -- has an OpenGL that
//! will not give a 4.3 core profile. The first tab cannot be created, and
//! before this the process showed why in a box and closed. On such machines
//! Mesa's ICD is often what answered, and it has a software rasteriser,
//! `llvmpipe`, that does give 4.5: `GALLIUM_DRIVER=llvmpipe` was measured to
//! make Polter start on the #18 machine.
//!
//! **Why a second process and not a second try in this one.** The ICD reads
//! `GALLIUM_DRIVER` when it is loaded, and it is loaded by the failure itself:
//! by the time the host knows the driver said no, setting the variable
//! changes nothing in this process (#18's first comment). So the host starts
//! itself again with the variable set and leaves.
//!
//! **Once, and only for that failure.** The process it starts carries
//! [`RETRY_VAR`], and a process carrying it never starts another: if
//! software rendering fails as well, it shows the box. A person who set
//! `GALLIUM_DRIVER` themselves is not overruled either -- starting again with
//! another value would be choosing for them. Any other failure is not
//! something llvmpipe mends, and goes to the box as before.
//!
//! **What it costs.** llvmpipe draws on the CPU; on the #18 machine a large
//! burst of output took three to four times as long as in a plain console
//! and used about three cores. That is why the log says it, the second
//! process says what it is, and nothing here happens on a machine whose
//! driver gave 4.3.

use std::ffi::OsString;

use crate::{logf, plogf};

/// Set, to the pid of the process that gave up, in the process started with
/// software rendering. Its presence is what makes the retry happen once.
pub const RETRY_VAR: &str = "POLTER_SOFTWARE_RENDER_RETRY";

/// The variable Mesa's ICD chooses its driver by, and the driver chosen.
const GALLIUM_VAR: &str = "GALLIUM_DRIVER";
const SOFTWARE: &str = "llvmpipe";

/// What the core's reason starts with when the driver refused the core
/// profile (`wgl.zig`'s `error.VersionUnsupported`, written by
/// `apprt/failure.zig`'s `describe` as "name: detail"). The one failure a
/// software rasteriser can do something about.
const REFUSED: &str = "VersionUnsupported";

/// Whether to start again, and if not, why not -- the why goes in the log.
#[derive(Debug, PartialEq, Eq)]
pub enum Retry {
    Restart,
    Not(&'static str),
}

/// The rule, apart from the process it is about.
///
/// `reason` is `ghostty_app_last_error` for the first tab; `retry_of` is
/// [`RETRY_VAR`] as this process was started with it; `gallium` is
/// `GALLIUM_DRIVER` as it is.
pub fn decide(reason: &str, retry_of: Option<u32>, gallium: Option<&str>) -> Retry {
    if retry_of.is_some() {
        return Retry::Not("this process already is the software-rendering retry");
    }
    if gallium.is_some() {
        return Retry::Not("GALLIUM_DRIVER is already set, and is not overruled");
    }
    if !reason.starts_with(REFUSED) {
        return Retry::Not("the failure is not the driver refusing the OpenGL version");
    }
    Retry::Restart
}

/// [`RETRY_VAR`] as this process was started with it: the pid of the one
/// that gave up, or None. Read once, before [`forget_retry_var`] takes it out
/// of the environment the terminals inherit.
pub fn retry_of() -> Option<u32> {
    static OF: std::sync::OnceLock<Option<u32>> = std::sync::OnceLock::new();
    *OF.get_or_init(|| std::env::var(RETRY_VAR).ok().and_then(|v| v.trim().parse().ok()))
}

/// Take [`RETRY_VAR`] out of this process's environment, so the shells it
/// starts do not inherit it and a Polter started from one of them is not
/// taken for a retry. `GALLIUM_DRIVER` stays: it is what made this process
/// work, and the ICD may read it again for a later window.
pub fn forget_retry_var() {
    let _ = retry_of();
    std::env::remove_var(RETRY_VAR);
}

/// In the process started with software rendering: wait for the one that
/// started it to be gone, so the two never run side by side -- the log, the
/// session and the core's pipe are each one per Polter. Called before the
/// first log line, so it says nothing itself; `announce` does.
pub fn wait_for_the_one_that_gave_up() -> Option<bool> {
    use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
    use windows::Win32::System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};
    let pid = retry_of()?;
    // Gone already is the ordinary case: it exits right after starting this.
    let Ok(h) = (unsafe { OpenProcess(PROCESS_SYNCHRONIZE, false, pid) }) else {
        return Some(true);
    };
    let gone = unsafe { WaitForSingleObject(h, 10_000) } == WAIT_OBJECT_0;
    let _ = unsafe { CloseHandle(h) };
    Some(gone)
}

/// The log line saying what this process is, once the log exists.
pub fn announce(waited: Option<bool>) {
    match (retry_of(), waited) {
        // process-wide: said once, at startup, before there is any window
        (Some(pid), w) => plogf!(
            "[render] this is the software-rendering retry for pid {pid}: {}={}; the process that gave up {}",
            GALLIUM_VAR,
            std::env::var(GALLIUM_VAR).unwrap_or_default(),
            if w == Some(false) { "was still running after 10 s" } else { "is gone" }
        ),
        (None, _) => {}
    }
}

/// The first tab failed with `reason`. Start this program again with
/// software rendering when [`decide`] says so; **returns only when it did
/// not**, and then the caller shows the box as before. When it did, this
/// process exits here.
pub fn restart_or_return(reason: &str) {
    let gallium = std::env::var(GALLIUM_VAR).ok();
    match decide(reason, retry_of(), gallium.as_deref()) {
        Retry::Not(why) => {
            // process-wide: the first tab of the process failed; one line per process
            plogf!("[render] not starting again with software rendering: {why}");
        }
        Retry::Restart => {
            let exe = match std::env::current_exe() {
                Ok(e) => e,
                Err(e) => {
                    // process-wide: the first tab of the process failed; one line per process
                    plogf!("[render] cannot start again with software rendering: current_exe() failed: {e}");
                    return;
                }
            };
            let args: Vec<OsString> = std::env::args_os().skip(1).collect();
            let started = std::process::Command::new(&exe)
                .args(&args)
                .env(GALLIUM_VAR, SOFTWARE)
                .env(RETRY_VAR, std::process::id().to_string())
                .spawn();
            match started {
                Ok(child) => {
                    // process-wide: this process is about to exit and hand over to the one it started
                    plogf!(
                        "[render] the driver refused the OpenGL version; started {} again as pid {} with {}={} (software rendering, slower and heavier on the CPU) and exiting",
                        exe.display(),
                        child.id(),
                        GALLIUM_VAR,
                        SOFTWARE
                    );
                    logf!("FATAL could not create the first tab; handed over to the software-rendering retry");
                    std::process::exit(1);
                }
                Err(e) => {
                    // process-wide: the first tab of the process failed; one line per process
                    plogf!("[render] could not start again with software rendering: {e}");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REASON: &str = "VersionUnsupported: the driver refused an OpenGL 4.3 core profile context; \
        the OpenGL driver here is \"D3D12 (Microsoft Basic Render Driver)\", which offers OpenGL 3.3";

    #[test]
    fn a_refused_version_starts_again_once() {
        assert_eq!(decide(REASON, None, None), Retry::Restart);
    }

    #[test]
    fn the_retry_never_starts_another() {
        assert!(matches!(decide(REASON, Some(1234), None), Retry::Not(_)));
        // Not even with the variable it set still in its environment.
        assert!(matches!(decide(REASON, Some(1234), Some(SOFTWARE)), Retry::Not(_)));
    }

    #[test]
    fn a_driver_the_person_chose_is_not_overruled() {
        assert!(matches!(decide(REASON, None, Some("d3d12")), Retry::Not(_)));
    }

    #[test]
    fn another_failure_goes_to_the_box() {
        assert!(matches!(decide("ContextFailed: the system could not create any OpenGL context for this window", None, None), Retry::Not(_)));
        assert!(matches!(decide("", None, None), Retry::Not(_)));
    }
}
