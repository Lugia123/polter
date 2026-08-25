//! How far the archive has got, written down.
//!
//! Under `$XDG_STATE_HOME` rather than `$XDG_CONFIG_HOME`, and the
//! difference matters. A plugin's `<key>.json` is configuration: the user
//! writes it, it goes in a dotfiles repository, it is copied between
//! machines. A cursor is none of those things -- it is a byte offset into
//! *this* machine's log, and carrying it to another machine would silently
//! skip everything that machine had not archived. It lives beside the log
//! it points into, so wiping state takes both together and a cursor can
//! never outlive the file it names.
//!
//! The extension is `.cursor` rather than `.json` so that nobody mistakes
//! it for something to hand-edit. The contents are still one line of JSON,
//! because `ChatLog.Mark` has a default for every field and so a file
//! missing one degrades to "no hint" rather than to an error.

const Cursor = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ChatLog = @import("ChatLog.zig");

const log = std.log.scoped(.poltergeist);

/// The most a cursor file can be and still be one.
///
/// Three integers and their names come to well under a hundred bytes. A
/// file longer than this is not a cursor that grew, it is something else
/// wearing the name, and reading it as one would be guessing.
const max_bytes: usize = 1024;

pub const Error = Allocator.Error || error{
    /// The key would escape the directory it is meant to name a file in.
    BadKey,

    /// The directory could not be made.
    OpenFailed,
};

alloc: Allocator,
io: std.Io,

/// `<state_dir>/plugins/<key>.cursor`. Owned.
path: []const u8,

/// Make the directory and work out the path. Nothing is read yet.
///
/// The key is checked before it is joined onto anything: it comes out of a
/// manifest the plugin author wrote, so pasting it into a path unchecked is
/// a traversal waiting to happen.
pub fn open(
    alloc: Allocator,
    io: std.Io,
    state_dir: []const u8,
    key: []const u8,
) Error!Cursor {
    if (!keyIsSafe(key)) {
        log.warn("plugin {s}: that key cannot name a file", .{key});
        return error.BadKey;
    }

    const dir = try std.fs.path.join(alloc, &.{ state_dir, "plugins" });
    defer alloc.free(dir);

    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("cursor: could not make {s} err={}", .{ dir, err });
            return error.OpenFailed;
        },
    };

    const name = try std.fmt.allocPrint(alloc, "{s}.cursor", .{key});
    defer alloc.free(name);

    return .{
        .alloc = alloc,
        .io = io,
        .path = try std.fs.path.join(alloc, &.{ dir, name }),
    };
}

pub fn deinit(self: *Cursor) void {
    self.alloc.free(self.path);
    self.* = undefined;
}

/// What was written down last, or the beginning of the log.
///
/// Missing, unreadable and unparseable all read as the beginning. That is
/// the safe direction: re-sending a message the plugin already has is a
/// duplicate it can drop by seq, whereas guessing forward loses it.
pub fn read(self: *const Cursor) ChatLog.Mark {
    const file = std.Io.Dir.openFileAbsolute(self.io, self.path, .{}) catch |err| switch (err) {
        // The first run has no cursor, and that is not bad news: it is
        // "start at the beginning" said in the only way a file can say it.
        error.FileNotFound => return .{},
        else => {
            log.warn("cursor: could not read {s} err={}", .{ self.path, err });
            return .{};
        },
    };
    defer file.close(self.io);

    var buf: [max_bytes]u8 = undefined;
    const n = file.readPositionalAll(self.io, &buf, 0) catch |err| {
        log.warn("cursor: could not read {s} err={}", .{ self.path, err });
        return .{};
    };

    // A full buffer means the file did not end where a cursor ends, so
    // what was read is a prefix of something else. Truncated JSON either
    // fails to parse or -- far worse -- parses into a number that is
    // wrong, and a wrong number here skips messages silently. Replaying
    // the lot is the cheaper mistake.
    if (n == 0 or n == buf.len) {
        log.warn("cursor: {s} is not one; starting from the beginning", .{self.path});
        return .{};
    }

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    // Unknown fields ignored and missing ones defaulted, both on purpose:
    // every field of `Mark` has a default, so a file holding only `seq`
    // degrades to "a number, and no shortcut" rather than to an error.
    return std.json.parseFromSliceLeaky(ChatLog.Mark, arena.allocator(), buf[0..n], .{
        .ignore_unknown_fields = true,
    }) catch {
        log.warn("cursor: {s} would not parse; starting from the beginning", .{self.path});
        return .{};
    };
}

/// Write it down, replacing whatever was there.
///
/// Atomic and owner-only, for the same reason the session file is: a half
/// written cursor read tomorrow looks like an answer.
///
/// Failure is logged and swallowed. Not being able to record where we got
/// to means replaying from an older point next time, which is a cost; it
/// is not a reason to stop archiving.
///
/// Said every time rather than once, which is a deliberate departure from
/// the "warn once" the readers here use. Warning once would need somewhere
/// to remember it, and that would make this `*Cursor` -- a signature the
/// archive is already built against. The trade is cheap: this is one call
/// per batch at two a second at the very most, never a call inside a loop,
/// and both `Session.write` and `ChatLog.append` are just as talkative. By
/// the time writing here is failing, the log itself is already shouting.
pub fn write(self: *const Cursor, mark: ChatLog.Mark) void {
    var buf: [max_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Fixed field order so that two cursors can be compared by eye and
    // grepped for without a parser.
    var s: std.json.Stringify = .{ .writer = &w, .options = .{} };
    render(&s, &w, mark) catch |err| {
        log.warn("cursor: could not render {s} err={}", .{ self.path, err });
        return;
    };

    const dir_path = std.fs.path.dirname(self.path) orelse return;
    const basename = std.fs.path.basename(self.path);

    var d = std.Io.Dir.cwd().openDir(self.io, dir_path, .{}) catch |err| {
        log.warn("cursor: could not open {s} err={}", .{ dir_path, err });
        return;
    };
    defer d.close(self.io);

    // Atomic because a cursor half on the disk still reads like an answer
    // tomorrow morning, and a wrong answer here skips messages rather than
    // repeating them. Owner-only because the log it points into holds the
    // user's own code, paths and stack traces: the pointer and the thing
    // pointed at should not differ on who may see them.
    var atomic = d.createFileAtomic(self.io, basename, .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    }) catch |err| {
        log.warn("cursor: could not write {s} err={}", .{ self.path, err });
        return;
    };
    defer atomic.deinit(self.io);

    atomic.file.writeStreamingAll(self.io, w.buffered()) catch |err| {
        log.warn("cursor: could not write {s} err={}", .{ self.path, err });
        return;
    };
    atomic.replace(self.io) catch |err| {
        log.warn("cursor: could not commit {s} err={}", .{ self.path, err });
    };
}

fn render(s: *std.json.Stringify, w: *std.Io.Writer, mark: ChatLog.Mark) !void {
    try s.beginObject();
    try s.objectField("seq");
    try s.write(mark.seq);
    try s.objectField("offset");
    try s.write(mark.offset);
    try s.objectField("inode");
    try s.write(mark.inode);
    try s.endObject();
    try w.writeByte('\n');
}

/// Whether a key can name a file inside a directory and nothing else.
///
/// A whitelist rather than a search for `..`, because the question is not
/// "does this look like an attack" but "is this one plain filename".
fn keyIsSafe(key: []const u8) bool {
    if (key.len == 0) return false;
    if (std.mem.eql(u8, key, ".")) return false;
    if (std.mem.eql(u8, key, "..")) return false;
    for (key) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

/// A scratch state directory, laid out the way `open` expects one.
fn testDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-cursor-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "a cursor round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const want: ChatLog.Mark = .{ .seq = 1042, .offset = 918273, .inode = 8419021 };
    {
        var c = try Cursor.open(testing.allocator, io, dir, "chat-archive");
        defer c.deinit();

        const expected = try std.fs.path.join(alloc, &.{ dir, "plugins", "chat-archive.cursor" });
        try testing.expectEqualStrings(expected, c.path);

        c.write(want);
    }

    // A second cursor entirely, so that what comes back came off the disk
    // rather than out of the first one's memory.
    var c: Cursor = try .open(testing.allocator, io, dir, "chat-archive");
    defer c.deinit();

    const got = c.read();
    try testing.expectEqual(want.seq, got.seq);
    try testing.expectEqual(want.offset, got.offset);
    try testing.expectEqual(want.inode, got.inode);

    // Owner-only, like the log it points into. Tested as "no bit for
    // anybody else" rather than as an exact mode, because a umask can only
    // take bits away.
    if (builtin.os.tag != .windows and std.posix.mode_t != u0) {
        const st = try std.Io.Dir.cwd().statFile(io, c.path, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0), st.permissions.toMode() & 0o077);
    }
}

test "a missing cursor reads as the beginning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var c: Cursor = try .open(testing.allocator, io, dir, "chat-archive");
    defer c.deinit();

    // Opening makes the directory and nothing else: a plugin that has
    // never been fed leaves no trace to be misread later.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, c.path, .{}),
    );

    const got = c.read();
    try testing.expectEqual(@as(u64, 0), got.seq);
    try testing.expectEqual(@as(u64, 0), got.offset);
    try testing.expectEqual(@as(u64, 0), got.inode);
}

test "a garbage cursor reads as the beginning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var c: Cursor = try .open(testing.allocator, io, dir, "chat-archive");
    defer c.deinit();

    const oversized = try alloc.alloc(u8, max_bytes + 64);
    @memset(oversized, 'x');

    for ([_][]const u8{ "not json", "{\"seq\":10", oversized }) |body| {
        try writeRaw(io, c.path, body);
        const got = c.read();
        try testing.expectEqual(@as(u64, 0), got.seq);
        try testing.expectEqual(@as(u64, 0), got.offset);
        try testing.expectEqual(@as(u64, 0), got.inode);
    }

    // And the case that matters more than any of those: a file that says
    // only how far we got degrades to "a number, and no shortcut", not to
    // the beginning. Losing the hint costs a scan; losing the seq would
    // replay the night.
    try writeRaw(io, c.path, "{\"seq\":5}");
    const got = c.read();
    try testing.expectEqual(@as(u64, 5), got.seq);
    try testing.expectEqual(@as(u64, 0), got.offset);
    try testing.expectEqual(@as(u64, 0), got.inode);
}

/// Put `body` where the cursor lives, whatever it is.
fn writeRaw(io: std.Io, path: []const u8, body: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

test "a key with a slash in it is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    for ([_][]const u8{ "../../etc/passwd", "a/b", "..", ".", "" }) |key| {
        try testing.expectError(
            error.BadKey,
            Cursor.open(testing.allocator, io, dir, key),
        );
    }

    for ([_][]const u8{ "chat-archive", "a.b_c-1" }) |key| {
        var c = try Cursor.open(testing.allocator, io, dir, key);
        c.deinit();
    }
}
