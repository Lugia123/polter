//! The bundle id, written down once for both sides of the build.
//!
//! **It has to be one place, and it was two.** The runtime reads
//! `build_config.bundle_id` and the build system used its own copy -- so a
//! fork that changed the id changed exactly one of them, and every
//! translation in the program stopped resolving without a single error
//! anywhere: `dgettext` was asked for `com.lugia.polter` while the catalogs
//! were installed as `com.mitchellh.ghostty.mo`. gettext answers a domain it
//! cannot find by handing back the msgid, which is a readable English
//! sentence, so the failure looked exactly like "this string was never
//! translated".
//!
//! This file is deliberately tiny and imports nothing: `src/build_config.zig`
//! needs it at run time and `src/build/*.zig` needs it while the build graph
//! is being made, and anything with a dependency could not be read by both.
//!
//! The comment on `build_config.bundle_id` still stands -- there are other
//! places that spell the id out, mostly Linux resources that keep upstream's
//! name on purpose. This closes the one that was silently load-bearing.

pub const value = "com.lugia.polter";
