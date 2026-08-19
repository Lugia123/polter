//! Telling the agent's runtime that Polter is here.
//!
//! Polter puts a socket path and a token in every terminal's environment,
//! which is everything an agent needs to *reach* it. What that does not do
//! is make the tools appear: an MCP client only loads servers it has been
//! configured with, so an agent in a directory nobody registered has the
//! socket, the token, and no way to use either.
//!
//! That gap survived three rounds of real-machine testing because the test
//! directory had a hand-written `.mcp.json` in it and every run stayed
//! inside that tree. The first supervisor started outside it reported the
//! tools simply were not there -- correctly, and with no way to fix it
//! itself.
//!
//! **Registration goes through `claude mcp`, not through the file.** The
//! user-scoped config is `~/.claude.json`, which holds that user's entire
//! Claude Code setup; parsing and re-serialising it to add one key would
//! reformat the whole thing and reorder every key in it. The tool that owns
//! the file knows how to edit it, so it is asked to.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.poltergeist);

/// What happened, for the log and for tests.
pub const Outcome = enum {
    /// Already pointing at this build. Nothing was written.
    unchanged,

    /// The registration was missing or stale, and has been replaced.
    updated,

    /// No `claude` on PATH. Not an error: the agent may be something else
    /// entirely, and Polter works the same either way.
    unavailable,

    /// It was tried and did not work. Logged, never fatal.
    failed,
};

/// The env key holding the build that wrote the registration.
///
/// The command path alone would catch a move or a reinstall elsewhere, but
/// not a build whose arguments or protocol changed while living at the same
/// path -- which is every in-place upgrade. The marker makes "written by a
/// different build" a thing that can be seen.
pub const version_key = "POLTER_REGISTERED";

/// Make sure the user-scoped registration points at this build.
///
/// Reads first and writes only on a mismatch: this file is rewritten by
/// Claude Code itself while it runs, and rewriting it on every launch for
/// no reason is asking for the one race that eats somebody's settings.
pub fn ensure(
    alloc: Allocator,
    io: std.Io,
    exe_path: []const u8,
    version: []const u8,
) Outcome {
    switch (current(alloc, io, exe_path, version)) {
        .matches => return .unchanged,
        .missing_tool => return .unavailable,
        .stale => {},
    }

    // `add` refuses a name that is already there, so a stale entry is
    // removed first. A failure here is ignored: the common case is that
    // there was nothing to remove.
    _ = run(io, &.{ "claude", "mcp", "remove", "--scope", "user", "polter" });

    const marker = std.fmt.allocPrint(alloc, version_key ++ "={s}", .{version}) catch
        return .failed;
    defer alloc.free(marker);

    // `--` separates our arguments from the served command's, so a future
    // flag on the served side cannot be read as one of ours.
    const ok = run(io, &.{
        "claude",  "mcp",  "add",
        "--scope", "user", "polter",
        "-e",      marker, "--",
        exe_path,  "+mcp",
    });

    if (!ok) {
        log.warn("poltergeist: could not register the MCP server", .{});
        return .failed;
    }

    log.info("poltergeist: registered {s} as the polter MCP server", .{exe_path});
    return .updated;
}

const State = enum { matches, stale, missing_tool };

/// What the registration says now, as `claude` reports it.
///
/// Asked of the tool rather than read from the file for the same reason it
/// is written through the tool: where a scope lives is that tool's business
/// and has moved before.
fn current(
    alloc: Allocator,
    io: std.Io,
    exe_path: []const u8,
    version: []const u8,
) State {
    const out = capture(alloc, io, &.{ "claude", "mcp", "get", "polter" }) orelse
        return .missing_tool;
    defer alloc.free(out);

    // `get` on a name that is not there exits non-zero, which `capture`
    // already turned into null -- so reaching here means there is an entry
    // and the only question is whether it is ours.
    const has_path = std.mem.indexOf(u8, out, exe_path) != null;
    const has_version = std.mem.indexOf(u8, out, version) != null;

    return if (has_path and has_version) .matches else .stale;
}

/// Run something, caring only whether it worked.
fn run(io: std.Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;

    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Run something and keep what it said, or null when it failed to run or
/// exited non-zero. The result belongs to `alloc`.
fn capture(alloc: Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(io, &buf);
        _ = reader.interface.streamRemaining(&out.writer) catch {};
        stdout.close(io);
        child.stdout = null;
    }

    const term = child.wait(io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return out.toOwnedSlice() catch null;
}
