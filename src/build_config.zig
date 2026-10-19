//! Build options, available at comptime. Used to configure features. This
//! will reproduce some of the fields from builtin and build_options just
//! so we can limit the amount of imports we need AND give us the ability
//! to shim logic and values into them later.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const assert = std.debug.assert;
const apprt = @import("apprt.zig");
const font = @import("font/main.zig");
const rendererpkg = @import("renderer.zig");
const BuildConfig = @import("build/Config.zig");

pub const ReleaseChannel = BuildConfig.ReleaseChannel;

/// The semantic version of this build.
pub const version = options.app_version;
pub const version_string = options.app_version_string;

/// Polter's own version (`build/PolterVersion.zig`), `0.10.2135`: the one a
/// person is shown, the same number as the mac bundle's and the Windows
/// host's (task 1786). Empty where it was not worked out. `version` above
/// is Ghostty's numbering and is what programs in the terminal see.
pub const polter_version: []const u8 = options.polter_version;

/// Where `polter_version`'s major.minor came from: `tag`, `branch` or
/// `fallback` (`build/PolterVersion.zig`).
pub const polter_version_source: []const u8 = options.polter_version_source;

/// The version to show a person: Polter's, or the core's when there is no
/// Polter one to say.
pub fn shownVersion() []const u8 {
    return shown(polter_version, version_string);
}

fn shown(polter: []const u8, core: []const u8) []const u8 {
    return if (polter.len > 0) polter else core;
}

/// What goes after the version wherever it is shown: said when the number
/// is a guess (task 1786). A detached checkout with no tag and no
/// `feature/vX.Y` branch is `0.1.N`, and says so rather than pass for a
/// release. Empty otherwise.
pub fn shownVersionNote() []const u8 {
    return note(polter_version, polter_version_source);
}

fn note(polter: []const u8, source: []const u8) []const u8 {
    if (polter.len == 0) return "";
    return if (std.mem.eql(u8, source, "fallback")) " (no tag or version branch: a fallback number)" else "";
}

test "1786: what a person is shown is Polter's version, and Ghostty's only when there is none" {
    const testing = std.testing;
    try testing.expectEqualStrings("0.10.2135", shown("0.10.2135", "1.3.2-HEAD+df00a498e"));
    try testing.expectEqualStrings("1.3.2-HEAD+df00a498e", shown("", "1.3.2-HEAD+df00a498e"));
    // A guessed number says it is one; a tagged or branch one says nothing more.
    try testing.expectEqualStrings(" (no tag or version branch: a fallback number)", note("0.1.2137", "fallback"));
    try testing.expectEqualStrings("", note("0.10.2135", "tag"));
    try testing.expectEqualStrings("", note("0.11.12", "branch"));
    try testing.expectEqualStrings("", note("", "fallback"));
}

test "1786: this build's Polter version is Polter's numbering, not the core's" {
    const testing = std.testing;
    // Worked out by the build from this repository (`PolterVersion.detect`):
    // three numbers, and never the Ghostty version the core carries.
    const v = try std.SemanticVersion.parse(polter_version);
    try testing.expect(v.pre == null and v.build == null);
    try testing.expect(!std.mem.eql(u8, polter_version, version_string));
    try testing.expect(v.major != version.major or v.minor != version.minor);
    try testing.expectEqualStrings(polter_version, shownVersion());
}

/// The release channel for this build.
pub const release_channel = std.meta.stringToEnum(ReleaseChannel, @tagName(options.release_channel)).?;

/// The optimization mode as a string.
pub const mode_string = mode: {
    const m = @tagName(builtin.mode);
    if (std.mem.lastIndexOfScalar(u8, m, '.')) |i| break :mode m[i..];
    break :mode m;
};

/// The artifact we're producing. This can be used to determine if we're
/// building a standalone exe, an embedded lib, etc.
pub const artifact = Artifact.detect();

/// Our build configuration. We re-export a lot of these back at the
/// top-level so its a bit cleaner to use throughout the code. See the doc
/// comments in BuildConfig for details on each.
const config = BuildConfig.fromOptions();
pub const exe_entrypoint = config.exe_entrypoint;
pub const flatpak = options.flatpak;
pub const snap = options.snap;
pub const app_runtime: apprt.Runtime = config.app_runtime;
pub const font_backend: font.Backend = config.font_backend;
pub const renderer: rendererpkg.Backend = config.renderer;
pub const i18n: bool = config.i18n;

/// Whether the `[rphase]` renderer phase lines are compiled in. Off by
/// default; see `log_render_phase` in build/Config.zig for why it is not
/// budgeted instead.
pub const log_render_phase: bool = config.log_render_phase;

/// The bundle ID for the app. This is used in many places and is currently
/// hardcoded here. We could make this configurable in the future if there
/// is a reason to do so.
///
/// On macOS, this must match the App bundle ID. We can get that dynamically
/// via an API but I don't want to pay the cost of that at runtime.
///
/// On GTK, this should match the various folders with resources.
///
/// There are many places that don't use this variable so simply swapping
/// this variable is NOT ENOUGH to change the bundle ID. I just wanted to
/// avoid it in Zig coe as much as possible.
pub const bundle_id = @import("build/bundle_id.zig").value;

/// The shipped executable's name, and the product's name in prose. Read from
/// the same file the build graph names the binary with, so a CLI message that
/// tells a person what to type cannot name a command that was never built.
pub const exe_name = @import("build/exe_name.zig").value;
pub const app_name = @import("build/exe_name.zig").display;

/// True if we should have "slow" runtime safety checks. The initial motivation
/// for this was terminal page/pagelist integrity checks. These were VERY
/// slow but very thorough. But they made it so slow that the terminal couldn't
/// be used for real work. We'd love to have an option to run a build with
/// safety checks that could be used for real work. This lets us do that.
pub const slow_runtime_safety = std.debug.runtime_safety and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe,
    .ReleaseSmall,
    .ReleaseFast,
    => false,
};

pub const Artifact = enum {
    /// Standalone executable
    exe,

    /// Embeddable library
    lib,

    /// The WASM-targeted module.
    wasm_module,

    pub fn detect() Artifact {
        if (builtin.target.cpu.arch.isWasm()) {
            assert(builtin.output_mode == .Obj);
            assert(builtin.link_mode == .Static);
            return .wasm_module;
        }

        return switch (builtin.output_mode) {
            .Exe => .exe,
            .Lib => .lib,
            else => {
                @compileLog(builtin.output_mode);
                @compileError("unsupported artifact output mode");
            },
        };
    }
};

/// True if runtime safety checks are enabled.
pub const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
