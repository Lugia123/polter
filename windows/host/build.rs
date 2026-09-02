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

use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=polter.rc");
    println!("cargo:rerun-if-changed=polter.manifest");

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
