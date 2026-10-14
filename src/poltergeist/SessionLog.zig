//! Who was in which group, when, as what, and which agent session they ran
//! (task 1511).
//!
//! **Nothing else on disk says it.** Adding a terminal to a group changes
//! memory and the snapshot in `session.json`, which holds only who is in a
//! group *now*. The chat record names whoever spoke and the panel whoever
//! held a task, so a member that never did either left no trace at all,
//! and the agent's session id lived only in memory. A supervisor looking
//! back through a group's work needs every terminal that worked in it, and
//! the transcript of each for the time it was there; this is what finds
//! them.
//!
//! **Written when it happens, not worked out afterwards.** What can be
//! worked out afterwards -- speakers, task holders -- misses the silent,
//! and the session ids were never written anywhere to work them out from.
//! Older groups are filled in once from what there is (`backfill` in the
//! app), with every such line marked `inferred`.
//!
//! The shape is the other per-group records': `<state>/sessions/<group>/
//! <day>.jsonl`, one JSON object per line, a `daylog.GroupTree` whose owner
//! is `group_stores.Root.sessions` -- so renaming a group moves these with
//! everything else, and a group's name is written in exactly one place
//! where a rename has to find it. A terminal's own directory under
//! `terminals/` never names a group, for the same reason.
//!
//! Failure is a warning and nothing else, the same as the other records.

const SessionLog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");

const log = std.log.scoped(.poltergeist);

alloc: Allocator,
io: std.Io,

/// Owned: the tree borrows it.
dir: []const u8,

tree: daylog.GroupTree,

/// What a terminal was when it joined. Every field is what the app
/// already knows; empty when it does not.
pub const Member = struct {
    role: []const u8 = "",
    cli: []const u8 = "",
    cwd: []const u8 = "",
    title: []const u8 = "",
    session_id: []const u8 = "",
    transcript_path: []const u8 = "",
};

/// An agent in a member terminal started, or said, a session.
pub const Agent = struct {
    cli: []const u8,
    session_id: []const u8,
    transcript_path: []const u8,
};

pub fn open(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!SessionLog {
    const dir = try std.fs.path.join(alloc, &.{ state_dir, "sessions" });
    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .tree = .{
            .owner = .sessions,
            .alloc = alloc,
            .io = io,
            .dir = dir,
            .label = "session log",
            // No sequence numbers: a line is identified by its group,
            // terminal and time.
            .probe = null,
        },
    };
}

pub fn deinit(self: *SessionLog) void {
    self.tree.deinit();
    self.alloc.free(self.dir);
    self.* = undefined;
}

/// Let go of the open day file. The next write opens what is then there.
pub fn closeHandles(self: *SessionLog) void {
    self.tree.close();
}

pub fn joined(self: *SessionLog, group: []const u8, at_ms: i64, terminal: u64, m: Member, inferred: bool) void {
    self.write(group, at_ms, .{ .joined = .{ .terminal = terminal, .member = m, .inferred = inferred } });
}

pub fn left(self: *SessionLog, group: []const u8, at_ms: i64, terminal: u64, inferred: bool) void {
    self.write(group, at_ms, .{ .left = .{ .terminal = terminal, .inferred = inferred } });
}

pub fn agent(self: *SessionLog, group: []const u8, at_ms: i64, terminal: u64, a: Agent) void {
    self.write(group, at_ms, .{ .agent = .{ .terminal = terminal, .agent = a } });
}

/// The group was tied to a project, or untied (`name` null).
pub fn project(self: *SessionLog, group: []const u8, at_ms: i64, name: ?[]const u8) void {
    self.write(group, at_ms, .{ .project = name });
}

/// What `backfill` found for a group, written so that it is not looked
/// for again: a group whose only speaker was the person has no members to
/// infer, and without this line would be read through at every start.
fn backfilled(self: *SessionLog, group: []const u8, at_ms: i64, members: usize) void {
    self.write(group, at_ms, .{ .backfilled = members });
}

/// What every record holds for a terminal in one group: first and last
/// seen.
const Seen = struct { first: i64, last: i64 };

/// Fill in the groups that were working before this record existed: every
/// group with a chat or task record and no session record gets a joined
/// line at the first moment each terminal shows in it -- speaking, or
/// holding a task -- and a left line at the last, both `inferred`.
///
/// **What this cannot find, said once:** a member that never spoke and
/// never held a task left nothing behind, and is not in the result. Its
/// transcript is kept and read as one in no group.
///
/// On the app thread, before any terminal can join: the lines written
/// here and the ones `joined` writes go through the same open file.
pub fn backfill(self: *SessionLog, state_dir: []const u8, now_ms: i64, user_id: u64) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const chat = std.fs.path.join(a, &.{ state_dir, "chat" }) catch return;
    var d = std.Io.Dir.cwd().openDir(self.io, chat, .{ .iterate = true }) catch return;
    defer d.close(self.io);

    var it = d.iterate();
    while (it.next(self.io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        const mine = std.fs.path.join(a, &.{ self.dir, entry.name }) catch continue;
        if (std.Io.Dir.cwd().statFile(self.io, mine, .{})) |_| continue else |_| {}
        const group = (daylog.decodeSegment(a, entry.name) catch continue) orelse continue;

        var seen: std.AutoArrayHashMapUnmanaged(u64, Seen) = .empty;
        inline for (.{ .{ "chat", "from" }, .{ "tasks", "owner" } }) |src| {
            gather(a, self.io, state_dir, src[0], entry.name, src[1], &seen) catch {};
        }

        var n: usize = 0;
        var si = seen.iterator();
        while (si.next()) |kv| {
            if (kv.key_ptr.* == user_id or kv.key_ptr.* == 0) continue;
            self.joined(group, kv.value_ptr.first, kv.key_ptr.*, .{}, true);
            self.left(group, kv.value_ptr.last, kv.key_ptr.*, true);
            n += 1;
        }
        self.backfilled(group, now_ms, n);
        if (n > 0) log.info("session log: inferred {d} members of a group from its record", .{n});
    }
}

fn gather(
    a: Allocator,
    io: std.Io,
    state_dir: []const u8,
    comptime root: []const u8,
    seg: []const u8,
    comptime field: []const u8,
    seen: *std.AutoArrayHashMapUnmanaged(u64, Seen),
) !void {
    const dir = try std.fs.path.join(a, &.{ state_dir, root });
    const tree: daylog.GroupTree = .{ .owner = .chat, .alloc = a, .io = io, .dir = dir };
    const days = try tree.daysIn(a, seg);
    for (days.items) |day| {
        const path = tree.partPathIn(a, seg, day.day, day.part) catch continue;
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, a, .limited(64 * 1024 * 1024)) catch continue;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
            const obj = switch (v) {
                .object => |o| o,
                else => continue,
            };
            const id = parseId(str(obj, field) orelse continue) orelse continue;
            const at = int(obj, "at_ms") orelse continue;
            const gop = try seen.getOrPut(a, id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .first = at, .last = at };
            } else {
                gop.value_ptr.first = @min(gop.value_ptr.first, at);
                gop.value_ptr.last = @max(gop.value_ptr.last, at);
            }
        }
    }
}

const Line = union(enum) {
    joined: struct { terminal: u64, member: Member, inferred: bool },
    left: struct { terminal: u64, inferred: bool },
    agent: struct { terminal: u64, agent: Agent },
    project: ?[]const u8,
    backfilled: usize,
};

fn write(self: *SessionLog, group: []const u8, at_ms: i64, line: Line) void {
    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();

    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    render(&s, group, at_ms, line) catch |err| {
        log.warn("session log: could not render err={}", .{err});
        return;
    };
    buf.writer.writeByte('\n') catch return;

    self.tree.write(group, at_ms, buf.written());
}

fn render(s: *std.json.Stringify, group: []const u8, at_ms: i64, line: Line) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("at_ms");
    try s.write(at_ms);
    try s.objectField("group");
    try s.write(group);
    try s.objectField("event");
    try s.write(@tagName(line));
    switch (line) {
        .joined => |j| {
            try terminalField(s, j.terminal);
            try s.objectField("role");
            try s.write(j.member.role);
            try s.objectField("cli");
            try s.write(j.member.cli);
            try s.objectField("cwd");
            try s.write(j.member.cwd);
            try s.objectField("title");
            try s.write(j.member.title);
            try s.objectField("session_id");
            try s.write(j.member.session_id);
            try s.objectField("transcript_path");
            try s.write(j.member.transcript_path);
            try s.objectField("inferred");
            try s.write(j.inferred);
        },
        .left => |l| {
            try terminalField(s, l.terminal);
            try s.objectField("inferred");
            try s.write(l.inferred);
        },
        .agent => |a| {
            try terminalField(s, a.terminal);
            try s.objectField("cli");
            try s.write(a.agent.cli);
            try s.objectField("session_id");
            try s.write(a.agent.session_id);
            try s.objectField("transcript_path");
            try s.write(a.agent.transcript_path);
        },
        .project => |name| {
            try s.objectField("project");
            try s.write(name);
        },
        .backfilled => |n| {
            try s.objectField("members");
            try s.write(n);
        },
    }
    try s.endObject();
}

/// As the same `0x…` text every other id in this system is written in.
fn terminalField(s: *std.json.Stringify, id: u64) std.Io.Writer.Error!void {
    var idbuf: [18]u8 = undefined;
    try s.objectField("terminal");
    try s.write(std.fmt.bufPrint(&idbuf, "0x{x:0>16}", .{id}) catch unreachable);
}

// ------------------------------------------------------------ reading

/// One terminal's time in one group: from joining to leaving, or to the
/// end of what was written down when it never left (the app ended first).
pub const Stint = struct {
    group: []const u8,
    terminal: u64,
    from_ms: i64,
    /// Null: never said to have left.
    to_ms: ?i64,
    role: []const u8,
    cli: []const u8,
    inferred: bool,
};

/// An agent session a member terminal ran, as it was reported in a group.
pub const Session = struct {
    group: []const u8,
    terminal: u64,
    at_ms: i64,
    cli: []const u8,
    session_id: []const u8,
    transcript_path: []const u8,
};

/// A group's tie to a project, from `at_ms` until the next one.
pub const ProjectTie = struct {
    group: []const u8,
    at_ms: i64,
    /// Null: untied.
    project: ?[]const u8,
};

/// Everything the record says, in the order it was written within each
/// group. Every string belongs to `arena`.
pub const Record = struct {
    stints: []Stint,
    sessions: []Session,
    ties: []ProjectTie,
};

/// How much of one day file is read. A day of joins and leaves is a few
/// kilobytes; this is a wall against a file that is not ours.
const max_day_bytes = 8 * 1024 * 1024;

/// Read the whole record under `state_dir`. Never fails for a missing or
/// unreadable file: what can be read is what there is.
pub fn read(arena: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!Record {
    var stints: std.ArrayListUnmanaged(Stint) = .empty;
    var sessions: std.ArrayListUnmanaged(Session) = .empty;
    var ties: std.ArrayListUnmanaged(ProjectTie) = .empty;

    const dir = try std.fs.path.join(arena, &.{ state_dir, "sessions" });
    var root = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch
        return .{ .stints = &.{}, .sessions = &.{}, .ties = &.{} };
    defer root.close(io);

    const tree: daylog.GroupTree = .{ .owner = .sessions, .alloc = arena, .io = io, .dir = dir };

    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        const seg = try arena.dupe(u8, entry.name);
        const days = try tree.daysIn(arena, seg);
        // Oldest first: a leave only means anything after its join.
        std.mem.reverse(daylog.GroupTree.DayFile, days.items);
        for (days.items) |day| {
            const path = tree.partPathIn(arena, seg, day.day, day.part) catch continue;
            const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(max_day_bytes)) catch continue;
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                try apply(arena, line, &stints, &sessions, &ties);
            }
        }
    }

    return .{
        .stints = try stints.toOwnedSlice(arena),
        .sessions = try sessions.toOwnedSlice(arena),
        .ties = try ties.toOwnedSlice(arena),
    };
}

fn apply(
    arena: Allocator,
    line: []const u8,
    stints: *std.ArrayListUnmanaged(Stint),
    sessions: *std.ArrayListUnmanaged(Session),
    ties: *std.ArrayListUnmanaged(ProjectTie),
) Allocator.Error!void {
    // A torn last line is a normal way for a record to end; skip it.
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    const event = str(obj, "event") orelse return;
    const group = str(obj, "group") orelse return;
    const at_ms = int(obj, "at_ms") orelse return;

    if (std.mem.eql(u8, event, "project")) {
        try ties.append(arena, .{ .group = group, .at_ms = at_ms, .project = str(obj, "project") });
        return;
    }

    const terminal = parseId(str(obj, "terminal") orelse return) orelse return;

    if (std.mem.eql(u8, event, "joined")) {
        try stints.append(arena, .{
            .group = group,
            .terminal = terminal,
            .from_ms = at_ms,
            .to_ms = null,
            .role = str(obj, "role") orelse "",
            .cli = str(obj, "cli") orelse "",
            .inferred = if (obj.get("inferred")) |b| b == .bool and b.bool else false,
        });
        const sid = str(obj, "session_id") orelse "";
        if (sid.len > 0) try sessions.append(arena, .{
            .group = group,
            .terminal = terminal,
            .at_ms = at_ms,
            .cli = str(obj, "cli") orelse "",
            .session_id = sid,
            .transcript_path = str(obj, "transcript_path") orelse "",
        });
    } else if (std.mem.eql(u8, event, "left")) {
        // The latest open stint of this terminal in this group ends here.
        var i = stints.items.len;
        while (i > 0) {
            i -= 1;
            const st = &stints.items[i];
            if (st.terminal == terminal and st.to_ms == null and std.mem.eql(u8, st.group, group)) {
                st.to_ms = at_ms;
                break;
            }
        }
    } else if (std.mem.eql(u8, event, "agent")) {
        try sessions.append(arena, .{
            .group = group,
            .terminal = terminal,
            .at_ms = at_ms,
            .cli = str(obj, "cli") orelse "",
            .session_id = str(obj, "session_id") orelse "",
            .transcript_path = str(obj, "transcript_path") orelse "",
        });
    }
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn int(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

/// `0x…` hex, the way ids are written everywhere in the records.
pub fn parseId(s: []const u8) ?u64 {
    const hex = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
    if (hex.len == 0 or hex.len > 16) return null;
    return std.fmt.parseUnsigned(u64, hex, 16) catch null;
}

const testing = std.testing;

fn testDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-sessionlog-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "a stint runs from joining to leaving, and a silent member is in it" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    const at: i64 = 1_700_000_000_000;
    {
        var l = try SessionLog.open(alloc, io, dir);
        defer l.deinit();
        l.joined("build", at, 0x11, .{ .role = "worker", .cli = "claude-code" }, false);
        l.joined("build", at + 1, 0x22, .{}, false);
        l.agent("build", at + 2, 0x11, .{ .cli = "claude-code", .session_id = "s-1", .transcript_path = "/x/s-1.jsonl" });
        l.left("build", at + 3, 0x11, false);
        l.project("build", at + 4, "polter");
        l.joined("ops", at + 5, 0x11, .{}, true);
    }

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try read(arena.allocator(), io, dir);

    try testing.expectEqual(@as(usize, 3), r.stints.len);
    var build11: ?Stint = null;
    var build22: ?Stint = null;
    var ops11: ?Stint = null;
    for (r.stints) |s| {
        if (s.terminal == 0x11 and std.mem.eql(u8, s.group, "build")) build11 = s;
        if (s.terminal == 0x22) build22 = s;
        if (s.terminal == 0x11 and std.mem.eql(u8, s.group, "ops")) ops11 = s;
    }
    try testing.expectEqual(@as(?i64, at + 3), build11.?.to_ms);
    try testing.expectEqualStrings("worker", build11.?.role);
    try testing.expect(!build11.?.inferred);
    // Never spoke, never left: still there, with no end.
    try testing.expectEqual(@as(?i64, null), build22.?.to_ms);
    try testing.expect(ops11.?.inferred);

    try testing.expectEqual(@as(usize, 1), r.sessions.len);
    try testing.expectEqualStrings("s-1", r.sessions[0].session_id);
    try testing.expectEqualStrings("/x/s-1.jsonl", r.sessions[0].transcript_path);

    try testing.expectEqual(@as(usize, 1), r.ties.len);
    try testing.expectEqualStrings("polter", r.ties[0].project.?);
}

test "leaving ends only that group's stint" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    const at: i64 = 1_700_000_000_000;
    {
        var l = try SessionLog.open(alloc, io, dir);
        defer l.deinit();
        l.joined("a", at, 0x11, .{}, false);
        l.joined("b", at, 0x11, .{}, false);
        l.left("a", at + 1, 0x11, false);
    }

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try read(arena.allocator(), io, dir);
    for (r.stints) |s| {
        if (std.mem.eql(u8, s.group, "a")) try testing.expectEqual(@as(?i64, at + 1), s.to_ms);
        if (std.mem.eql(u8, s.group, "b")) try testing.expectEqual(@as(?i64, null), s.to_ms);
    }
}

test "no record is an empty one" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try read(arena.allocator(), threaded.io(), "/tmp/polter-sessionlog-does-not-exist-7f3a");
    try testing.expectEqual(@as(usize, 0), r.stints.len);
}

test "ids are read the way they are written" {
    try testing.expectEqual(@as(?u64, 0x0e18248b0511f1d0), parseId("0x0e18248b0511f1d0"));
    try testing.expectEqual(@as(?u64, 0x0e18248b0511f1d0), parseId("0e18248b0511f1d0"));
    try testing.expectEqual(@as(?u64, null), parseId("0x"));
    try testing.expectEqual(@as(?u64, null), parseId("nope"));
}

test "an older group's members are inferred once from who spoke and who held a task" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    const write_file = struct {
        fn f(io_: std.Io, a: Allocator, base: []const u8, rel: []const u8, text: []const u8) !void {
            const path = try std.fs.path.join(a, &.{ base, rel });
            defer a.free(path);
            try std.Io.Dir.cwd().createDirPath(io_, std.fs.path.dirname(path).?);
            var file = try std.Io.Dir.cwd().createFile(io_, path, .{});
            defer file.close(io_);
            try file.writePositionalAll(io_, text, 0);
        }
    }.f;

    try write_file(io, alloc, dir, "chat/old/2026-10-01.jsonl",
        \\{"seq":1,"at_ms":1000,"group":"old","from":"0x0000000000000011","author":"w","text":"hi"}
        \\{"seq":2,"at_ms":1500,"group":"old","from":"0x0000000000000000","author":"me","text":"go"}
        \\{"seq":3,"at_ms":3000,"group":"old","from":"0x0000000000000011","author":"w","text":"done"}
        \\
    );
    try write_file(io, alloc, dir, "tasks/old/2026-10-01.jsonl",
        \\{"at_ms":2000,"op":"assigned","task":1,"group":"old","title":"t","owner":"0x0000000000000022","state":"open","progress":"queued","kind":"other"}
        \\
    );
    // A group the record already knows is left as it is.
    try write_file(io, alloc, dir, "chat/new/2026-10-01.jsonl",
        \\{"seq":4,"at_ms":1000,"group":"new","from":"0x0000000000000033","author":"x","text":"hi"}
        \\
    );
    try write_file(io, alloc, dir, "sessions/new/2026-10-01.jsonl",
        \\{"at_ms":1,"group":"new","event":"backfilled","members":0}
        \\
    );

    {
        var l = try SessionLog.open(alloc, io, dir);
        defer l.deinit();
        l.backfill(dir, 9000, 0);
    }

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try read(arena.allocator(), io, dir);
    try testing.expectEqual(@as(usize, 2), r.stints.len);
    for (r.stints) |s| {
        try testing.expectEqualStrings("old", s.group);
        try testing.expect(s.inferred);
        if (s.terminal == 0x11) {
            try testing.expectEqual(@as(i64, 1000), s.from_ms);
            try testing.expectEqual(@as(?i64, 3000), s.to_ms);
        } else {
            try testing.expectEqual(@as(u64, 0x22), s.terminal);
            try testing.expectEqual(@as(i64, 2000), s.from_ms);
        }
    }

    // Once: the second start finds the group's record and reads nothing.
    {
        var l = try SessionLog.open(alloc, io, dir);
        defer l.deinit();
        l.backfill(dir, 9500, 0);
    }
    var arena2: std.heap.ArenaAllocator = .init(alloc);
    defer arena2.deinit();
    const again = try read(arena2.allocator(), io, dir);
    try testing.expectEqual(@as(usize, 2), again.stints.len);
}

test "a leave read while another group's stint is open ends the right one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stints: std.ArrayListUnmanaged(Stint) = .empty;
    var sessions: std.ArrayListUnmanaged(Session) = .empty;
    var ties: std.ArrayListUnmanaged(ProjectTie) = .empty;
    // The order a reader can meet them in: groups are read one directory
    // at a time, in whatever order the directory lists them.
    for ([_][]const u8{
        \\{"at_ms":1,"group":"a","event":"joined","terminal":"0x0000000000000011"}
        ,
        \\{"at_ms":1,"group":"b","event":"joined","terminal":"0x0000000000000011"}
        ,
        \\{"at_ms":2,"group":"a","event":"left","terminal":"0x0000000000000011"}
        ,
    }) |line| try apply(a, line, &stints, &sessions, &ties);
    try testing.expectEqualStrings("a", stints.items[0].group);
    try testing.expectEqual(@as(?i64, 2), stints.items[0].to_ms);
    try testing.expectEqual(@as(?i64, null), stints.items[1].to_ms);
}
