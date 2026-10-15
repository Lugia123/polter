//! Embed `test/project-format/` into the tests at compile time.
//!
//! **Why not read it at run time.** The tests used to open the directory
//! through `env!("CARGO_MANIFEST_DIR")`, which is a path on the machine that
//! built them; a test binary cross-compiled on the Mac and run on the Windows
//! machine has no source tree beside it (task 1540).
//!
//! **Why a build script and not `include_bytes!` per file.** One of the tests
//! holds "no file there that `index.txt` does not name", and that needs the
//! listing, not a list somebody typed. Listed here, at the time of the build,
//! every file in the directory is embedded under its name.

use std::path::PathBuf;

fn main() {
    let dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../test/project-format");
    // A directory: Cargo reruns this when a file in it is added, removed or
    // changed, so the listing cannot go stale.
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("cannot list {}: {e}", dir.display()))
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let mut out = String::from("&[\n");
    for name in &names {
        let path = dir.join(name).canonicalize().unwrap();
        out.push_str(&format!("    ({name:?}, include_bytes!({:?}) as &[u8]),\n", path.to_string_lossy()));
    }
    out.push_str("]\n");
    let to = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("project_format_files.rs");
    std::fs::write(&to, out).unwrap();
}
