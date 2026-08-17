//! What it takes to pick things up again tomorrow.
//!
//! Not a restore: nothing here puts the supervision back by itself. It is
//! **material**, written down so that after a restart the supervisor can
//! read what last night's arrangement was and rebuild it. Deciding which
//! terminal on screen now is which one from last night is a judgement, and
//! judgements belong to the supervisor -- see `docs/poltergeist/supervisor.md`
//! for why the program guessing that is worse than it asking.
//!
//! What is deliberately absent is as much of the design as what is here:
//!
//!   - **`Surface.id`** is a fresh random number every run. Storing it
//!     would be storing noise.
//!   - **Quiet durations and `rounds`** are measurements of *now*. Carrying
//!     `rounds` across a restart claims "we counted to three last night, so
//!     tonight starts at four" when that process is gone and the agent has
//!     restarted too. "N consecutive rounds" has no meaning across a
//!     restart, and pretending otherwise turns n into a number nobody can
//!     explain.
//!
//! Written after every change rather than at exit, because the cases this
//! exists for -- the machine shutting down, Polter being killed -- are
//! precisely the ones where there is no exit.

const Session = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");

const log = std.log.scoped(.poltergeist);

/// One terminal as it was last night.
pub const Member = struct {
    /// Where it was working. The one thing a resume needs.
    cwd: []const u8 = "",

    /// What its tab said, which is how a person tells them apart.
    title: []const u8 = "",

    /// What it was doing here, so the supervisor can put it back.
    role: Bus.Role = .none,
    work_mode: Bus.WorkMode = .clock_off,
};

/// One group as it was last night.
pub const Group = struct {
    name: []const u8,
    brief: []const u8 = "",
    members: []const Member = &.{},
};

/// Everything worth writing down.
pub const Snapshot = struct {
    groups: []const Group = &.{},
};

/// Where the file lives, given the state directory. Caller owns it.
pub fn defaultPath(alloc: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "session.json" });
}

/// Write the snapshot, replacing whatever was there.
///
/// Written whole and atomically: a half-written session file read tomorrow
/// morning would be worse than none, because it looks like an answer.
///
/// Failure is logged and swallowed. Not being able to write tomorrow's
/// notes is not a reason to stop the terminals talking tonight.
pub fn write(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    snapshot: Snapshot,
) void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    writeJson(&s, snapshot) catch |err| {
        log.warn("session: could not render err={}", .{err});
        return;
    };

    const dir = std.fs.path.dirname(path) orelse return;
    const basename = std.fs.path.basename(path);

    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err| {
        log.warn("session: could not open {s} err={}", .{ dir, err });
        return;
    };
    defer d.close(io);

    // Owner-only: it records what the user was working on and where.
    var atomic = d.createFileAtomic(io, basename, .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    }) catch |err| {
        log.warn("session: could not write err={}", .{err});
        return;
    };
    defer atomic.deinit(io);

    atomic.file.writeStreamingAll(io, buf.written()) catch |err| {
        log.warn("session: could not write err={}", .{err});
        return;
    };
    atomic.replace(io) catch |err| {
        log.warn("session: could not commit err={}", .{err});
    };
}

fn writeJson(s: *std.json.Stringify, snapshot: Snapshot) !void {
    try s.beginObject();
    try s.objectField("groups");
    try s.beginArray();
    for (snapshot.groups) |g| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(g.name);
        if (g.brief.len > 0) {
            try s.objectField("brief");
            try s.write(g.brief);
        }
        try s.objectField("members");
        try s.beginArray();
        for (g.members) |m| {
            try s.beginObject();
            if (m.cwd.len > 0) {
                try s.objectField("cwd");
                try s.write(m.cwd);
            }
            if (m.title.len > 0) {
                try s.objectField("title");
                try s.write(m.title);
            }
            try s.objectField("role");
            try s.write(@tagName(m.role));
            try s.objectField("work_mode");
            try s.write(@tagName(m.work_mode));
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// Read what was written, or null when there is nothing to read.
///
/// A file that will not parse is treated as nothing rather than as an
/// error: it is a note to the supervisor, and a corrupt note is worth no
/// more than a missing one. Everything it borrows comes from `arena`.
pub fn read(arena: Allocator, io: std.Io, path: []const u8) ?Snapshot {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(4 * 1024 * 1024),
    ) catch return null;

    return parse(arena, bytes);
}

/// The same, for bytes already in hand. Everything it borrows comes from
/// `arena`.
pub fn parse(arena: Allocator, bytes: []const u8) ?Snapshot {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{},
    ) catch |err| {
        log.warn("session: last night's notes will not parse err={}", .{err});
        return null;
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    const raw_groups = switch (obj.get("groups") orelse return null) {
        .array => |a| a.items,
        else => return null,
    };

    var groups: std.ArrayListUnmanaged(Group) = .empty;
    for (raw_groups) |item| {
        const go = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = str(go.get("name")) orelse continue;

        var members: std.ArrayListUnmanaged(Member) = .empty;
        if (go.get("members")) |ms| switch (ms) {
            .array => |a| for (a.items) |mi| {
                const mo = switch (mi) {
                    .object => |o| o,
                    else => continue,
                };
                members.append(arena, .{
                    .cwd = str(mo.get("cwd")) orelse "",
                    .title = str(mo.get("title")) orelse "",
                    .role = enumOf(Bus.Role, mo.get("role")) orelse .none,
                    .work_mode = enumOf(Bus.WorkMode, mo.get("work_mode")) orelse .clock_off,
                }) catch return null;
            },
            else => {},
        };

        groups.append(arena, .{
            .name = name,
            .brief = str(go.get("brief")) orelse "",
            .members = members.items,
        }) catch return null;
    }

    return .{ .groups = groups.items };
}

/// What the previous run left behind, taken before this run can write.
///
/// **Constructing it is the read.** There is no way to ask for the material
/// later, and that is the whole point of the type: the file is overwritten
/// early and often -- "this terminal is now the supervisor" is itself a
/// change worth saving, and it is the *first step* of a restore -- so by
/// the time anybody asks, the file holds this run's empty arrangement
/// rather than last night's. Reading late gave the supervisor an empty
/// list and a whole night's work to not find. Reading at construction
/// makes that ordering impossible to get wrong rather than merely
/// documented.
///
/// See `docs/poltergeist/supervisor.md`, and note that this is *recall*:
/// the arrangement that was lost. The live one is what the group tools
/// are for.
pub const Recall = struct {
    /// The file as it was, or empty when there was nothing usable. Owned.
    bytes: []const u8 = "",

    /// Read the file now, keeping it only if it says something.
    ///
    /// A file that will not parse is kept as nothing rather than passed
    /// on: a corrupt note is worth no more than a missing one, and handing
    /// the supervisor damaged JSON is worse than handing it none, because
    /// it will try to act on it.
    ///
    /// The bytes are kept as they were read rather than re-rendered from
    /// the parse. Anything a later version writes that this one does not
    /// model still reaches the supervisor intact -- and the supervisor,
    /// unlike this parser, can make sense of a field it has never seen.
    pub fn open(alloc: Allocator, io: std.Io, path: []const u8) Recall {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            alloc,
            .limited(4 * 1024 * 1024),
        ) catch return .{};

        // Parsed only to find out whether it is worth keeping. The result
        // is thrown away with the arena; what is served is the original.
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();

        if (parse(arena.allocator(), bytes) == null) {
            alloc.free(bytes);
            return .{};
        }

        return .{ .bytes = bytes };
    }

    pub fn deinit(self: *Recall, alloc: Allocator) void {
        if (self.bytes.len > 0) alloc.free(self.bytes);
        self.* = .{};
    }

    /// The material, or an empty string when there is none.
    pub fn text(self: Recall) []const u8 {
        return self.bytes;
    }
};

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |x| x,
        else => null,
    };
}

fn enumOf(comptime T: type, v: ?std.json.Value) ?T {
    return std.meta.stringToEnum(T, str(v) orelse return null);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "what is written comes back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-sess-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try defaultPath(alloc, dir);

    const members = [_]Member{
        .{
            .cwd = "/work/repo",
            .title = "✳ Write retry.py",
            .role = .watched,
            .work_mode = .infinite_directed,
        },
        .{ .cwd = "/work/repo", .title = "✳ tests", .role = .watched },
    };
    const groups = [_]Group{
        .{ .name = "build", .brief = "写 retry 装饰器", .members = &members },
        .{ .name = "research" },
    };

    write(alloc, io, path, .{ .groups = &groups });

    const back = read(alloc, io, path) orelse return error.NothingRead;
    try testing.expectEqual(@as(usize, 2), back.groups.len);
    try testing.expectEqualStrings("build", back.groups[0].name);
    try testing.expectEqualStrings("写 retry 装饰器", back.groups[0].brief);
    try testing.expectEqual(@as(usize, 2), back.groups[0].members.len);
    try testing.expectEqualStrings("/work/repo", back.groups[0].members[0].cwd);
    try testing.expectEqual(Bus.Role.watched, back.groups[0].members[0].role);
    try testing.expectEqual(
        Bus.WorkMode.infinite_directed,
        back.groups[0].members[0].work_mode,
    );

    // A group nobody said anything about still round-trips.
    try testing.expectEqualStrings("research", back.groups[1].name);
    try testing.expectEqualStrings("", back.groups[1].brief);
}

test "nothing written reads as nothing, not as an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    try testing.expect(read(
        arena.allocator(),
        threaded.io(),
        "/tmp/polter-does-not-exist-9c1f/session.json",
    ) == null);
}

test "a corrupt file reads as nothing rather than as an answer" {
    // Half a file is worse than no file, because it looks like an answer.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-sess-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try defaultPath(alloc, dir);
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "session.json", .{});
    try f.writeStreamingAll(io, "{\"groups\": [{\"name\": \"bui");
    f.close(io);

    try testing.expect(read(alloc, io, path) == null);
}

test "a member the host knew nothing about still gets written" {
    // A bare shell has no title, and a directory is only known once the
    // shell reports one. That is a member with empty fields -- worth
    // writing, because its role and mode are still part of the picture.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-sess-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try defaultPath(alloc, dir);
    const members = [_]Member{.{ .role = .watched, .work_mode = .infinite_sequential }};
    const groups = [_]Group{.{ .name = "build", .members = &members }};

    write(alloc, io, path, .{ .groups = &groups });

    const back = read(alloc, io, path) orelse return error.NothingRead;
    try testing.expectEqual(@as(usize, 1), back.groups[0].members.len);
    try testing.expectEqualStrings("", back.groups[0].members[0].cwd);
    try testing.expectEqual(
        Bus.WorkMode.infinite_sequential,
        back.groups[0].members[0].work_mode,
    );
}

test "writing twice leaves one file, not two halves" {
    // The point of writing atomically: a reader tomorrow gets either the
    // old arrangement or the new one, never a torn mixture.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-sess-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try defaultPath(alloc, dir);

    const first = [_]Group{.{ .name = "build" }};
    write(alloc, io, path, .{ .groups = &first });

    const second = [_]Group{ .{ .name = "build" }, .{ .name = "research" } };
    write(alloc, io, path, .{ .groups = &second });

    const back = read(alloc, io, path) orelse return error.NothingRead;
    try testing.expectEqual(@as(usize, 2), back.groups.len);
}

/// A scratch directory that cleans itself up, for the Recall tests below.
fn tmpDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-recall-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "recall with no file to read is empty, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r: Recall = .open(testing.allocator, io, "/tmp/polter-no-such-session-4a1f");
    defer r.deinit(testing.allocator);

    try testing.expectEqualStrings("", r.text());
    _ = alloc;
}

test "a corrupt file recalls as nothing rather than as damaged JSON" {
    // Handing the supervisor half a file is worse than handing it none:
    // none it can see, and damage it will try to act on.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "session.json", .{});
    try f.writeStreamingAll(io, "{\"groups\":[{\"name\":\"buil");
    f.close(io);

    var r: Recall = .open(testing.allocator, io, try defaultPath(alloc, dir));
    defer r.deinit(testing.allocator);

    try testing.expectEqualStrings("", r.text());
}

test "recall hands back what was actually written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try defaultPath(alloc, dir);

    const members = [_]Member{.{ .cwd = "/work/alpha", .title = "◑ colstat", .role = .watched }};
    const groups = [_]Group{.{ .name = "alpha", .brief = "CSV 列统计", .members = &members }};
    write(alloc, io, path, .{ .groups = &groups });

    var r: Recall = .open(testing.allocator, io, path);
    defer r.deinit(testing.allocator);

    const back = parse(alloc, r.text()) orelse return error.NothingRead;
    try testing.expectEqual(@as(usize, 1), back.groups.len);
    try testing.expectEqualStrings("alpha", back.groups[0].name);
    try testing.expectEqualStrings("CSV 列统计", back.groups[0].brief);
    try testing.expectEqualStrings("/work/alpha", back.groups[0].members[0].cwd);
}

test "this run overwriting the file does not take the recall with it" {
    // The bug this type exists for. On startup there are no groups in
    // memory, and "this terminal is now the supervisor" is itself a change
    // worth saving -- and it is the *first step* of a restore. So the file
    // is replaced by this run's empty arrangement before the supervisor
    // can ask its first question. Read late, it answered `{"groups":[]}`
    // and a restore supervisor spent a night finding nothing.
    //
    // Reading at construction is what makes that ordering unwritable.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try defaultPath(alloc, dir);

    // Last night.
    const groups = [_]Group{
        .{ .name = "alpha", .brief = "CSV 列统计" },
        .{ .name = "beta", .brief = "路径去重" },
    };
    write(alloc, io, path, .{ .groups = &groups });

    // This morning: the material is taken first...
    var r: Recall = .open(testing.allocator, io, path);
    defer r.deinit(testing.allocator);

    // ...and then this run writes its own, empty, arrangement over it.
    write(alloc, io, path, .{});
    const on_disk = read(alloc, io, path) orelse return error.NothingRead;
    try testing.expectEqual(@as(usize, 0), on_disk.groups.len);

    // The supervisor still gets last night.
    const back = parse(alloc, r.text()) orelse return error.NothingRecalled;
    try testing.expectEqual(@as(usize, 2), back.groups.len);
    try testing.expectEqualStrings("alpha", back.groups[0].name);
    try testing.expectEqualStrings("路径去重", back.groups[1].brief);
}

test "a field this version does not model still reaches the supervisor" {
    // The bytes are served as they were read, not re-rendered from the
    // parse. A later version's field would be dropped by re-rendering --
    // and the supervisor, unlike this parser, can make sense of something
    // it has never seen before.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "session.json", .{});
    try f.writeStreamingAll(io,
        \\{"groups":[{"name":"alpha","deadline":"2026-08-20","members":[]}]}
    );
    f.close(io);

    var r: Recall = .open(testing.allocator, io, try defaultPath(alloc, dir));
    defer r.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, r.text(), "deadline") != null);
    try testing.expect(std.mem.indexOf(u8, r.text(), "2026-08-20") != null);
}
