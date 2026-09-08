const Version = @This();

const std = @import("std");

/// The short hash (7 characters) of the latest commit.
short_hash: []const u8,

/// True if there was a diff at build time.
changes: bool,

/// The tag -- if any -- that this commit is a part of.
tag: ?[]const u8,

/// The branch that was checked out at the time of the build.
branch: []const u8,

/// Initialize the version and detect it from the Git environment. This
/// allocates using the build allocator and doesn't free.
pub fn detect(b: *std.Build) !Version {
    // Execute a bunch of git commands to determine the automatic version.
    var code: u8 = 0;
    const branch: []const u8 = b: {
        const tmp: []u8 = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--abbrev-ref", "HEAD" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            error.ExitCodeFailure => return error.GitNotRepository,
            else => return err,
        };

        // **Trim first, then sanitise. The order is the whole of this.**
        //
        // `git rev-parse` ends its output with a newline, and the loop below
        // turns anything outside `[0-9A-Za-z-]` into `-` -- a newline
        // included. Run the other way round, the trim finds nothing left to
        // trim and **every branch name gains a trailing hyphen**: the version
        // string read `1.3.2-HEAD-+1ca47f03b`, with `version_pre = "HEAD-"`.
        //
        // ⚠️ There *was* a `trimEnd` on this value, at the `return` below.
        // It had simply already lost: by the time it ran, the newline was a
        // hyphen and a hyphen is legal in a pre-release identifier. **A call
        // that cannot fire is worse than a missing one** -- anyone reading
        // that line concluded the branch was trimmed, which is why this
        // survived long enough to reach a version string.
        // Length, then re-slice the mutable buffer: `trimEnd` hands back a
        // `[]const u8`, and the loop below writes.
        const trimmed = tmp[0..std.mem.trimEnd(u8, tmp, "\r\n ").len];

        // Replace characters that are not valid in semantic version
        // pre-release identifiers (which only allow [0-9A-Za-z-]).
        // Slashes would also mess up dist tarball paths.
        for (trimmed) |*c| {
            if (!std.ascii.isAlphanumeric(c.*) and c.* != '-') c.* = '-';
        }

        break :b trimmed;
    };

    const short_hash = short_hash: {
        const output = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "-c", "log.showSignature=false", "log", "--pretty=format:%h", "-n", "1" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };

        break :short_hash std.mem.trimEnd(u8, output, "\r\n ");
    };

    const tag = b.runAllowFail(
        &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "describe", "--exact-match", "--tags" },
        &code,
        .ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => "", // expected
        else => return err,
    };

    _ = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "diff",
        "--quiet",
        "--exit-code",
    }, &code, .ignore) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => {}, // expected
        else => return err,
    };
    const changes = code != 0;

    return .{
        .short_hash = short_hash,
        .changes = changes,
        .tag = if (tag.len > 0) std.mem.trimEnd(u8, tag, "\r\n ") else null,
        // Already trimmed, above, before the sanitiser could hide the
        // newline. Trimming again here is what this looked like when it was
        // broken.
        .branch = branch,
    };
}
