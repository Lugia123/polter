//! Polter's own version, which is not Ghostty's.
//!
//! Upstream's version comes from git tags (`GitVersion.zig`) and describes
//! Ghostty releases. This fork has none of those and should not pretend to:
//! showing `1.3.2-dev` in the About window would name a release nobody here
//! built. So the number shown to the user is worked out from this repository
//! instead.
//!
//! **major.minor comes from the branch.** A branch called `feature/vX.Y` is
//! version X.Y, the same scheme the other repositories here use. Anything
//! else -- `feature/poltergeist`, a detached HEAD in CI -- falls back to
//! `fallback_major`.`fallback_minor`, because a build that cannot tell what
//! version it is should say the earliest one rather than guess upward.
//!
//! **patch is how many commits are this fork's own.** Not `rev-list --count
//! HEAD`, which is 17,247 here: this branch carries the whole of Ghostty's
//! history, and counting it would produce a number that says nothing about
//! Polter and moves whenever upstream is merged. Counted from the fork point
//! instead, so the patch is the number of commits that exist because of this
//! project.
//!
//! The fork point is written down rather than discovered. Deriving it needs
//! a second branch to compare against, and which branch that is depends on
//! the clone: here `main` is upstream Ghostty, but in `Lugia123/polter` the
//! branch called `main` *is* this work, so `main..HEAD` would come back
//! empty and every build in that clone would call itself `0.1.0`.

const std = @import("std");

/// The commit this fork began at -- the parent of its first commit.
///
/// Any clone with the history can count from here and get the same answer,
/// which is the point: the version must not depend on which branches happen
/// to exist locally.
const fork_point = "f81dcadc82ea2afdcf2dc92929037701122f05b5";

const fallback_major = 0;
const fallback_minor = 1;

pub const Version = struct {
    /// `0.1.71`, ready for `MARKETING_VERSION`.
    string: []const u8,

    /// The patch alone, for `CURRENT_PROJECT_VERSION`, which Apple wants to
    /// see increase on every build it is asked to compare.
    count: u32,

    /// Short hash, or empty when git could not say. Empty rather than
    /// "unknown": the About window already leaves the row out when there is
    /// nothing to put in it, and a word pretending to be a hash is worse
    /// than a missing row.
    commit: []const u8,
};

/// Work it out, or fall back to something honest.
///
/// Never fails. A missing git, a tarball with no history, a clone without
/// the fork point: all of them produce `0.1.0` with no commit, which reads
/// as "a build that could not tell" rather than stopping a build that is
/// otherwise fine.
pub fn detect(b: *std.Build) Version {
    const count = countCommits(b) orelse 0;
    return .{
        .string = b.fmt("{d}.{d}.{d}", .{ major(b), minor(b), count }),
        .count = count,
        .commit = shortHash(b) orelse "",
    };
}

fn branch(b: *std.Build) ?[]const u8 {
    const out = git(b, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) orelse return null;

    // Detached HEAD. Not an error -- CI checks out a commit routinely --
    // and not a version either.
    if (std.mem.eql(u8, out, "HEAD")) return null;
    return out;
}

/// `feature/v0.2` -> 0, `feature/poltergeist` -> the fallback.
fn versionFromBranch(b: *std.Build) ?struct { major: u32, minor: u32 } {
    const name = branch(b) orelse return null;

    const prefix = "feature/v";
    if (!std.mem.startsWith(u8, name, prefix)) return null;

    const rest = name[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;

    const maj = std.fmt.parseUnsigned(u32, rest[0..dot], 10) catch return null;
    const min = std.fmt.parseUnsigned(u32, rest[dot + 1 ..], 10) catch return null;
    return .{ .major = maj, .minor = min };
}

fn major(b: *std.Build) u32 {
    const v = versionFromBranch(b) orelse return fallback_major;
    return v.major;
}

fn minor(b: *std.Build) u32 {
    const v = versionFromBranch(b) orelse return fallback_minor;
    return v.minor;
}

fn countCommits(b: *std.Build) ?u32 {
    const out = git(b, &.{ "rev-list", "--count", fork_point ++ "..HEAD" }) orelse return null;
    return std.fmt.parseUnsigned(u32, out, 10) catch null;
}

fn shortHash(b: *std.Build) ?[]const u8 {
    return git(b, &.{ "rev-parse", "--short", "HEAD" });
}

/// Run git and hand back its trimmed output, or null for anything at all
/// going wrong.
///
/// Deliberately incurious about *why* it failed. Every caller here has the
/// same answer for a missing git, a missing repository and a missing fork
/// point, so telling them apart would only be work.
fn git(b: *std.Build, args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{
        "git",
        "-C",
        b.build_root.path orelse ".",
    }) catch return null;
    argv.appendSlice(b.allocator, args) catch return null;

    // `-C` rather than a working directory, and `runAllowFail` rather than
    // spawning by hand: both are what `GitVersion.zig` next door already
    // does, and the build has one way of asking git things.
    var code: u8 = 0;
    const out = b.runAllowFail(argv.items, &code, .ignore) catch return null;
    if (code != 0) return null;

    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) return null;
    return b.dupe(trimmed);
}
