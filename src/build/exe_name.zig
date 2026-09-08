//! The name of the shipped executable, written down once for both sides of
//! the build.
//!
//! **The same shape, and the same reason, as `bundle_id.zig` next to it.**
//! That file exists because one forked name lived in two places and a fork
//! changed only one of them, with no error anywhere. This one closes a
//! narrower version of the same gap: `GhosttyExe.zig` names the binary
//! `polter`, and every CLI message that tells a person what to type spelled
//! it `ghostty`. **Those are not two styles of the same word -- one of them
//! is a command that does not exist**, and the person reading it is by
//! definition someone who does not yet know that.
//!
//! Deliberately tiny and importing nothing, so that `src/build_config.zig`
//! can read it at run time and `src/build/*.zig` while the build graph is
//! being made -- see the note in `bundle_id.zig`, which is the whole of why
//! neither file may grow a dependency.
//!
//! ⚠️ **Internal artefacts keep the upstream name on purpose.** The terminfo
//! entry is `xterm-ghostty`, `TERM_PROGRAM` is `ghostty`, the shell
//! integration scripts are `ghostty.bash` and `ghostty.ps1`, and the C ABI
//! symbols are `ghostty_*`. `windows/AGENTS.md` states the rule this file
//! serves: *user-visible strings are Polter; internal artifacts keep the
//! upstream Ghostty names, so merging upstream stays cheap.*

pub const value = "polter";

/// The product's name as it is written in prose, and in the one place a
/// sentence has to start with it.
///
/// **Not derived from `value` by capitalising it.** A transformation would
/// read as a rule about spelling when the two are simply two facts, and the
/// day a fork's binary is `pltr` the derived prose would be `Pltr`.
pub const display = "Polter";
