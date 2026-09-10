//! Where a pane's captured commands live: one plain-text file per pane,
//! one command per line, fed by OSC 60 (`src/terminal/osc/parsers/command_capture.zig`)
//! as the shell's preexec hook sees each command.
//!
//! **Why plain text, one line per command.** This is deliberately the same
//! shape as a bash or zsh `HISTFILE` in its plain (non-`extended_history`)
//! form, so the file this module writes can be handed to bash/zsh directly
//! as `HISTFILE` when restoring a pane -- no conversion step, and the
//! shell's own up-arrow reads exactly what Ghostty captured. Fish is
//! different: it owns its history store by session name, not by file, so a
//! fish pane's `Project.Leaf.history` is a session name for `fish_history`,
//! not a filename this module manages. See `Project.zig`'s doc comment on
//! `Leaf.history` for the full split.
//!
//! **This file is not guaranteed complete after a crash.** A command is
//! appended when the shell's preexec fires, which is before the command
//! runs -- so a normal exit or even most crashes still leave the file
//! caught up to the last command *typed*. But the write itself is not
//! synced to disk, and a kill mid-write (or a filesystem that reorders
//! writes) can still lose the last line or two. Don't build anything that
//! assumes "the file exists" means "the file has every command."
//!
//! **A multi-line command (a heredoc, a backslash continuation, a pasted
//! block) is not captured with its line breaks intact.** All three shell
//! integrations (`src/shell-integration/{zsh,bash}/*`, `fish/vendor_conf.d/
//! ghostty-shell-integration.fish`) replace every control byte in the
//! command -- including `\n` and `\t` -- with a space before the OSC ever
//! leaves the shell, the same way they already do for the OSC 2 title.
//! So `append`'s own rejection of a command containing `\r`/`\n` (below) is
//! not what a heredoc actually hits in this pipeline: by the time text
//! reaches here it has already been flattened to one line. That rejection
//! exists as a second, independent check against a command reaching this
//! function some other way (directly, or through a shell integration that
//! doesn't flatten), not as the thing users actually experience. What
//! users experience is a heredoc's body run together on one line, spaces
//! where the newlines were -- a real loss of shape, just not a dropped
//! entry, and not the same claim this comment used to make.
const CommandHistory = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Where history files live, given Ghostty's state directory (see
/// `src/os/xdg.zig`'s `state`). A sibling of `Project.defaultDir`, not
/// nested under it: a pane's history outlives any one project it gets
/// saved into, and not every pane with a history file was ever saved to a
/// project at all.
pub fn defaultDir(alloc: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "history" });
}

/// A fresh filename for a new pane's history, unrelated to any other pane's.
/// Caller owns the returned slice.
pub fn newFilename(alloc: Allocator, io: std.Io) Allocator.Error![]const u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.fmt.allocPrint(alloc, "{x}.history", .{&raw});
}

/// Append one command to a pane's history file, creating the file (and
/// `dir`, if needed) on first use.
///
/// A command containing a newline can't be represented in this format (see
/// the module doc comment) and is silently dropped -- callers should not
/// be able to produce one anyway, since `command_capture.zig` already
/// rejects it before it becomes a `Command`, but this function doesn't
/// trust that from the outside.
///
/// Reopens the file for every call rather than holding it open: the shell
/// this file is also `HISTFILE` for may replace it wholesale at exit
/// (`shopt -s histappend` or not), and a long-held file handle would then
/// be writing into a file nothing points at anymore.
pub fn append(
    alloc: Allocator,
    io: std.Io,
    dir: []const u8,
    filename: []const u8,
    command: []const u8,
) !void {
    if (command.len == 0) return;
    if (std.mem.indexOfAny(u8, command, "\r\n") != null) return;

    try std.Io.Dir.cwd().createDirPath(io, dir);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, filename, .{
        .truncate = false,
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    });
    defer f.close(io);

    // Positional rather than seek-then-stream: multiple surfaces could in
    // principle share an `Io` implementation whose files aren't
    // thread-isolated, and a positional write at the size we just read
    // doesn't disturb a global seek position anything else might be
    // relying on. See `stat`'s own note that positional is the more
    // threadsafe default.
    const end = (try f.stat(io)).size;

    const line = try alloc.alloc(u8, command.len + 1);
    defer alloc.free(line);
    @memcpy(line[0..command.len], command);
    line[command.len] = '\n';

    try f.writePositionalAll(io, line, end);
}

/// Read every command in a pane's history file, in the order they were
/// appended. An empty slice for a pane that never captured anything --
/// including one whose file doesn't exist yet, which is not a distinct
/// condition worth a named error here the way `Project.read` needs one:
/// nobody picked this file by name expecting it to exist, the way they
/// pick a project. Everything returned is arena-owned.
pub fn read(
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
    filename: []const u8,
) Allocator.Error![]const []const u8 {
    const path = std.fs.path.join(arena, &.{ dir, filename }) catch return &.{};

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(64 * 1024 * 1024),
    ) catch return &.{};

    var commands: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        // The file ends with a trailing '\n', so the split's last piece
        // is always "" -- not a blank command someone captured.
        if (line.len == 0) continue;
        try commands.append(arena, line);
    }

    return commands.items;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn tmpDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-history-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "appended commands read back in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try append(alloc, io, dir, "pane.history", "echo one");
    try append(alloc, io, dir, "pane.history", "echo two");
    try append(alloc, io, dir, "pane.history", "ls; pwd");

    const commands = try read(alloc, io, dir, "pane.history");
    try testing.expectEqual(@as(usize, 3), commands.len);
    try testing.expectEqualStrings("echo one", commands[0]);
    try testing.expectEqualStrings("echo two", commands[1]);
    try testing.expectEqualStrings("ls; pwd", commands[2]);
}

test "a pane that never ran anything reads back empty, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const commands = try read(alloc, io, dir, "never-written.history");
    try testing.expectEqual(@as(usize, 0), commands.len);
}

test "reading from a directory that does not exist yet is empty too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const commands = try read(alloc, io, "/tmp/polter-history-does-not-exist-9c1f", "pane.history");
    try testing.expectEqual(@as(usize, 0), commands.len);
}

test "an empty command is not appended" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try append(alloc, io, dir, "pane.history", "");
    const commands = try read(alloc, io, dir, "pane.history");
    try testing.expectEqual(@as(usize, 0), commands.len);
}

test "a command with an embedded newline is dropped rather than corrupting the format" {
    // Exercises `append`'s own defensive check directly, bypassing the
    // shell integration scripts that flatten control bytes to spaces
    // before the OSC ever goes out (see the module doc comment). In the
    // real pipeline a heredoc arrives here as one flattened line, not a
    // raw newline for this branch to catch -- this test is about what
    // `append` does when something reaches it unflattened, not a claim
    // about what a heredoc looks like when it gets here normally.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try append(alloc, io, dir, "pane.history", "echo one");
    try append(alloc, io, dir, "pane.history", "cat <<EOF\nheredoc body\nEOF");
    try append(alloc, io, dir, "pane.history", "echo two");

    const commands = try read(alloc, io, dir, "pane.history");
    try testing.expectEqual(@as(usize, 2), commands.len);
    try testing.expectEqualStrings("echo one", commands[0]);
    try testing.expectEqualStrings("echo two", commands[1]);
}

test "two panes writing to the same directory don't interfere" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try append(alloc, io, dir, "a.history", "in pane a");
    try append(alloc, io, dir, "b.history", "in pane b");

    const a = try read(alloc, io, dir, "a.history");
    const b = try read(alloc, io, dir, "b.history");
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqual(@as(usize, 1), b.len);
    try testing.expectEqualStrings("in pane a", a[0]);
    try testing.expectEqualStrings("in pane b", b[0]);
}

test "newFilename gives out different names" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try newFilename(testing.allocator, io);
    defer testing.allocator.free(a);
    const b = try newFilename(testing.allocator, io);
    defer testing.allocator.free(b);

    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(std.mem.endsWith(u8, a, ".history"));
}
