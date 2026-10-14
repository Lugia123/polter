//! What a terminal was, beside its transcript: the agent session it ran,
//! the project tab it sat in, the role it was started as (task 1511).
//!
//! `<state>/terminals/<id>.meta.jsonl`, one JSON object per line, next to
//! the terminal's transcript directory `<id>-<title>/` -- a file of its own
//! rather than a file inside that directory, because the directory's name
//! is settled by the transcript's first line and this may be written
//! before it.
//!
//! **No group is named here.** Which groups a terminal was in is
//! `SessionLog`'s, filed under each group so that renaming one moves it.
//! A group's name written here would be one more place a rename had to
//! find, and the one it would miss.
//!
//! Each kind of line is written when its value changes, not on every event
//! that carries it: an agent says its session id on every hook.

const TerminalMeta = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");

const log = std.log.scoped(.poltergeist);

alloc: Allocator,
io: std.Io,

/// `<state>/terminals`. Owned.
dir: []const u8,

/// What was last written for each terminal, so a repeat is not written.
last: std.AutoHashMapUnmanaged(u64, Last) = .empty,

warned: bool = false,

const Last = struct {
    agent: u64 = 0,
    project: u64 = 0,
    role: u64 = 0,
    /// The agent's own record of its session, kept for `SessionLog`'s join
    /// line: the bus remembers the session id but not this. Owned.
    transcript_path: []const u8 = "",
};

pub fn open(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!TerminalMeta {
    return .{
        .alloc = alloc,
        .io = io,
        .dir = try std.fs.path.join(alloc, &.{ state_dir, "terminals" }),
    };
}

pub fn deinit(self: *TerminalMeta) void {
    var it = self.last.valueIterator();
    while (it.next()) |l| if (l.transcript_path.len > 0) self.alloc.free(l.transcript_path);
    self.last.deinit(self.alloc);
    self.alloc.free(self.dir);
    self.* = undefined;
}

/// The terminal is gone: a later terminal given the same id is another.
pub fn forget(self: *TerminalMeta, id: u64) void {
    if (self.last.fetchRemove(id)) |kv| {
        if (kv.value.transcript_path.len > 0) self.alloc.free(kv.value.transcript_path);
    }
}

/// The last `transcript_path` the terminal's agent gave, or "".
pub fn transcriptPathOf(self: *const TerminalMeta, id: u64) []const u8 {
    const l = self.last.get(id) orelse return "";
    return l.transcript_path;
}

/// The agent said which session it is. True when that is news -- the
/// first time, or a different session -- and was written down.
pub fn agent(self: *TerminalMeta, id: u64, at_ms: i64, cli: []const u8, session_id: []const u8, transcript_path: []const u8) bool {
    const h = hash(&.{ cli, session_id, transcript_path });
    const l = self.entry(id) orelse return false;
    if (l.agent == h) return false;
    l.agent = h;
    if (!std.mem.eql(u8, l.transcript_path, transcript_path)) {
        const owned = self.alloc.dupe(u8, transcript_path) catch "";
        if (l.transcript_path.len > 0) self.alloc.free(l.transcript_path);
        l.transcript_path = owned;
    }
    self.write(id, at_ms, .{ .agent = .{ .cli = cli, .session_id = session_id, .transcript_path = transcript_path } });
    return true;
}

/// The terminal is now in this project's tab, or in none (null).
pub fn project(self: *TerminalMeta, id: u64, at_ms: i64, name: ?[]const u8) void {
    const h = if (name) |n| hash(&.{n}) else 1;
    const l = self.entry(id) orelse return;
    if (l.project == h) return;
    // Nothing known yet and nothing to say: no line.
    if (l.project == 0 and name == null) {
        l.project = h;
        return;
    }
    l.project = h;
    self.write(id, at_ms, .{ .project = name });
}

/// The terminal was started as this role.
pub fn role(self: *TerminalMeta, id: u64, at_ms: i64, key: []const u8) void {
    const h = hash(&.{key});
    const l = self.entry(id) orelse return;
    if (l.role == h) return;
    l.role = h;
    self.write(id, at_ms, .{ .role = key });
}

fn entry(self: *TerminalMeta, id: u64) ?*Last {
    const gop = self.last.getOrPut(self.alloc, id) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// Never zero, which `Last` uses for "nothing yet", and never one, which
/// `project` uses for "no project".
fn hash(parts: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0x1511);
    for (parts) |p| {
        h.update(p);
        h.update(&.{0});
    }
    return h.final() | 2;
}

const Line = union(enum) {
    agent: struct { cli: []const u8, session_id: []const u8, transcript_path: []const u8 },
    project: ?[]const u8,
    role: []const u8,
};

/// The file a terminal's notes go in. Caller owns it.
pub fn pathOf(alloc: Allocator, dir: []const u8, id: u64) Allocator.Error![]const u8 {
    var name: [32]u8 = undefined;
    const base = std.fmt.bufPrint(&name, "{x:0>16}.meta.jsonl", .{id}) catch unreachable;
    return std.fs.path.join(alloc, &.{ dir, base });
}

fn write(self: *TerminalMeta, id: u64, at_ms: i64, line: Line) void {
    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    render(&s, at_ms, line) catch return;
    buf.writer.writeByte('\n') catch return;

    const path = pathOf(self.alloc, self.dir, id) catch return;
    defer self.alloc.free(path);
    std.Io.Dir.cwd().createDirPath(self.io, self.dir) catch {};
    var f = daylog.openAppend(self.io, path) catch |err| {
        self.warnOnce(err);
        return;
    };
    defer f.close(self.io);
    const end = if (f.stat(self.io)) |st| st.size else |_| 0;
    f.writePositionalAll(self.io, buf.written(), end) catch |err| self.warnOnce(err);
}

fn warnOnce(self: *TerminalMeta, err: anyerror) void {
    if (self.warned) return;
    self.warned = true;
    log.warn("terminal meta: could not write err={}", .{err});
}

fn render(s: *std.json.Stringify, at_ms: i64, line: Line) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("at_ms");
    try s.write(at_ms);
    try s.objectField("event");
    try s.write(@tagName(line));
    switch (line) {
        .agent => |a| {
            try s.objectField("cli");
            try s.write(a.cli);
            try s.objectField("session_id");
            try s.write(a.session_id);
            try s.objectField("transcript_path");
            try s.write(a.transcript_path);
        },
        .project => |p| {
            try s.objectField("project");
            try s.write(p);
        },
        .role => |r| {
            try s.objectField("role");
            try s.write(r);
        },
    }
    try s.endObject();
}

// ------------------------------------------------------------ reading

/// One line of one terminal's notes, read back. Strings belong to the arena.
pub const Note = struct {
    terminal: u64,
    at_ms: i64,
    kind: enum { agent, project, role },
    cli: []const u8 = "",
    session_id: []const u8 = "",
    transcript_path: []const u8 = "",
    /// For `project`: null is "in no project from here on".
    project: ?[]const u8 = null,
    role: []const u8 = "",
};

/// Every terminal's notes under `state_dir`, each terminal's in the order
/// written. What cannot be read is left out.
pub fn read(arena: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error![]Note {
    var out: std.ArrayListUnmanaged(Note) = .empty;
    const dir = try std.fs.path.join(arena, &.{ state_dir, "terminals" });
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer d.close(io);

    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const id = idOfMetaFile(e.name) orelse continue;
        const path = try std.fs.path.join(arena, &.{ dir, e.name });
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(1024 * 1024)) catch continue;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const obj = switch (v) {
                .object => |o| o,
                else => continue,
            };
            const at_ms = switch (obj.get("at_ms") orelse continue) {
                .integer => |n| n,
                else => continue,
            };
            const event = str(obj, "event") orelse continue;
            if (std.mem.eql(u8, event, "agent")) {
                try out.append(arena, .{ .terminal = id, .at_ms = at_ms, .kind = .agent, .cli = str(obj, "cli") orelse "", .session_id = str(obj, "session_id") orelse "", .transcript_path = str(obj, "transcript_path") orelse "" });
            } else if (std.mem.eql(u8, event, "project")) {
                try out.append(arena, .{ .terminal = id, .at_ms = at_ms, .kind = .project, .project = str(obj, "project") });
            } else if (std.mem.eql(u8, event, "role")) {
                try out.append(arena, .{ .terminal = id, .at_ms = at_ms, .kind = .role, .role = str(obj, "role") orelse "" });
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The terminal id a `<16 hex>.meta.jsonl` name is for.
pub fn idOfMetaFile(name: []const u8) ?u64 {
    const suffix = ".meta.jsonl";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const hex = name[0 .. name.len - suffix.len];
    if (hex.len != 16) return null;
    return std.fmt.parseUnsigned(u64, hex, 16) catch null;
}

/// The terminal id a transcript directory `<16 hex>[-<title>]` is for.
pub fn idOfTranscriptDir(name: []const u8) ?u64 {
    if (name.len < 16) return null;
    if (name.len > 16 and name[16] != '-') return null;
    return std.fmt.parseUnsigned(u64, name[0..16], 16) catch null;
}

const testing = std.testing;

test "a repeat is not written again, a change is" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-meta-{x}", .{&raw});
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    {
        var m = try TerminalMeta.open(alloc, io, dir);
        defer m.deinit();
        try testing.expect(m.agent(0x11, 1, "claude-code", "s-1", "/x/s-1.jsonl"));
        try testing.expect(!m.agent(0x11, 2, "claude-code", "s-1", "/x/s-1.jsonl"));
        try testing.expect(m.agent(0x11, 3, "claude-code", "s-2", "/x/s-2.jsonl"));
        try testing.expectEqualStrings("/x/s-2.jsonl", m.transcriptPathOf(0x11));
        m.project(0x11, 4, null); // nothing known and nothing to say
        m.project(0x11, 5, "polter");
        m.project(0x11, 6, "polter");
        m.project(0x11, 7, null);
        m.role(0x11, 8, "polter-dev");
        m.role(0x11, 9, "polter-dev");
    }

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const notes = try read(arena.allocator(), io, dir);
    try testing.expectEqual(@as(usize, 5), notes.len);
    try testing.expectEqualStrings("s-1", notes[0].session_id);
    try testing.expectEqualStrings("s-2", notes[1].session_id);
    try testing.expectEqualStrings("polter", notes[2].project.?);
    try testing.expectEqual(@as(?[]const u8, null), notes[3].project);
    try testing.expectEqualStrings("polter-dev", notes[4].role);
    try testing.expectEqual(@as(u64, 0x11), notes[4].terminal);
}

test "names are read back to the terminal they are for" {
    try testing.expectEqual(@as(?u64, 0x0e18248b0511f1d0), idOfMetaFile("0e18248b0511f1d0.meta.jsonl"));
    try testing.expectEqual(@as(?u64, null), idOfMetaFile("0e18.meta.jsonl"));
    try testing.expectEqual(@as(?u64, 0x0e18248b0511f1d0), idOfTranscriptDir("0e18248b0511f1d0-zsh"));
    try testing.expectEqual(@as(?u64, 0x0e18248b0511f1d0), idOfTranscriptDir("0e18248b0511f1d0"));
    try testing.expectEqual(@as(?u64, null), idOfTranscriptDir("0e18248b0511f1d0x"));
    try testing.expectEqual(@as(?u64, null), idOfTranscriptDir("zz18248b0511f1d0-a"));
}
