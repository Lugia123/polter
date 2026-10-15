//! Find the core's catalogue template for the tests, at compile time.
//!
//! The tests used to list `po/` through `env!("CARGO_MANIFEST_DIR")` when
//! they ran, which is a path on the machine that built them; a test binary
//! cross-compiled on the Mac and run on the Windows machine has no source
//! tree beside it (task 1540). So the template is found here, by its
//! extension as before -- its name is the bundle id and is not written down
//! -- and the tests `include_str!` the path this hands them.

use std::path::PathBuf;

fn main() {
    let po = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../po");
    // A directory: rerun when a file in it changes, so a renamed template is
    // found again rather than remembered.
    println!("cargo:rerun-if-changed={}", po.display());
    let pot = std::fs::read_dir(&po)
        .unwrap_or_else(|e| panic!("cannot list {}: {e}", po.display()))
        .filter_map(|d| d.ok().map(|d| d.path()))
        .find(|p| p.extension().is_some_and(|x| x == "pot"))
        .unwrap_or_else(|| panic!("no .pot in {}", po.display()));
    println!("cargo:rustc-env=POLTER_CORE_POT={}", pot.canonicalize().unwrap().display());
}
