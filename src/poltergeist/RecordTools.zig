//! What an agent may look back through, and the looking (task 1511):
//! `record_list`, `record_search`, `record_read` over the terminal
//! transcripts, `log_list` and `log_read` over Polter's own logs.
//!
//! **Who may read what** is one rule, `reachOf`, and it is about time, not
//! only about terminals:
//!
//!   * **its own**: a terminal reads everything it wrote, and everything
//!     written by an earlier run that ran the same agent session -- ids
//!     change at every restart, a resumed session does not;
//!   * **a group's supervisor** reads what a member wrote *while it was a
//!     member of that group*, and nothing from before it joined or after it
//!     left. A supervisor is a terminal that is a member of the group and
//!     wears the supervisor role now;
//!   * **a project** -- the supervisor of a group tied to it reads what a
//!     terminal wrote while in that project's tabs, except what it wrote
//!     while in some group: that belongs to the group, and another group's
//!     supervisor may not have it;
//!   * **nobody else.** Another group's record is refused (`NotYourGroup`),
//!     not filtered to nothing, so a supervisor can tell "not mine" from
//!     "nothing there".
//!
//! **The shield is not consulted** (the user, 2026-10-15): no shielded
//! stretch is recorded and nothing is filtered by it.
//!
//! ⚠️ **This rules the tools, not the disk.** The transcripts are the
//! user's own files and an agent with a shell can read them. What this
//! decides is what Polter hands an agent when it asks, which is the
//! agreement about what an agent should look at -- not a wall.
//!
//! Every reply is bounded: a page of terminals, a page of lines no bigger
//! than `max_reply_bytes`, a search that reads at most `search_budget`
//! bytes before it hands back a cursor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const daylog = @import("daylog.zig");
const Records = @import("Records.zig");
const SessionLog = @import("SessionLog.zig");
const TerminalMeta = @import("TerminalMeta.zig");

/// About as much as one reply can carry and still be read whole.
pub const max_reply_bytes: usize = 96 * 1024;
pub const max_lines: usize = 400;
pub const default_lines: usize = 200;
pub const max_terminals: usize = 50;
pub const max_hits: usize = 50;
pub const snippet_chars: usize = 240;
/// How much of the record one `record_search` reads before it stops and
/// hands back where it got to.
pub const search_budget: u64 = 64 * 1024 * 1024;

/// Who is asking, as the app knows it now.
pub const Access = struct {
    caller: u64,
    /// The groups the caller supervises: it is a member and a supervisor.
    supervises: []const []const u8,
    /// The projects those groups are tied to.
    projects: []const []const u8,
};

/// A refusal, with the sentence that says what to do about it.
pub const Refusal = struct {
    code: []const u8,
    message: []const u8,
};

pub const Answer = union(enum) {
    json: []const u8,
    refused: Refusal,
};

/// Which terminals a list or a search is about. Exactly one, or none for
/// the caller's own.
pub const Scope = union(enum) {
    mine,
    group: []const u8,
    project: []const u8,
    task: u64,
    terminal: u64,
    session: []const u8,
};

/// A stretch of time; `to` null is open.
pub const Window = struct {
    from: i64,
    to: ?i64,

    fn holds(self: Window, at: i64) bool {
        if (at < self.from) return false;
        return if (self.to) |to| at <= to else true;
    }
};

fn anyHolds(ws: []const Window, at: i64) bool {
    for (ws) |w| if (w.holds(at)) return true;
    return false;
}

/// What the caller may read of one terminal.
pub const Reach = struct {
    /// All of it: the caller's own, or the same agent session.
    all: bool = false,
    /// Stints in the caller's groups.
    groups: []const Window = &.{},
    /// Stretches in the caller's projects ...
    projects: []const Window = &.{},
    /// ... less any stretch the terminal spent in any group at all.
    in_any_group: []const Window = &.{},

    pub fn readable(self: Reach, at: i64) bool {
        if (self.all) return true;
        if (anyHolds(self.groups, at)) return true;
        return anyHolds(self.projects, at) and !anyHolds(self.in_any_group, at);
    }

    pub fn none(self: Reach) bool {
        return !self.all and self.groups.len == 0 and self.projects.len == 0;
    }
};

/// Everything read off the disk once per call.
pub const World = struct {
    sessions: SessionLog.Record,
    notes: []const TerminalMeta.Note,
    /// Every transcript directory, by terminal.
    dirs: []const Dir,

    pub const Dir = struct { terminal: u64, name: []const u8 };

    pub fn read(arena: Allocator, io: Io, state_dir: []const u8) Allocator.Error!World {
        var dirs: std.ArrayListUnmanaged(Dir) = .empty;
        const root = try std.fs.path.join(arena, &.{ state_dir, "terminals" });
        if (Io.Dir.cwd().openDir(io, root, .{ .iterate = true })) |opened| {
            var d = opened;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |e| {
                const id = TerminalMeta.idOfTranscriptDir(e.name) orelse continue;
                if (TerminalMeta.idOfMetaFile(e.name) != null) continue;
                try dirs.append(arena, .{ .terminal = id, .name = try arena.dupe(u8, e.name) });
            }
        } else |_| {}
        std.mem.sort(Dir, dirs.items, {}, struct {
            fn lt(_: void, a: Dir, b: Dir) bool {
                return a.terminal < b.terminal;
            }
        }.lt);
        return .{
            .sessions = try SessionLog.read(arena, io, state_dir),
            .notes = try TerminalMeta.read(arena, io, state_dir),
            .dirs = dirs.items,
        };
    }

    fn sessionIdsOf(self: World, arena: Allocator, terminal: u64) Allocator.Error![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sessions.sessions) |s| if (s.terminal == terminal and s.session_id.len > 0) try out.append(arena, s.session_id);
        for (self.notes) |n| if (n.terminal == terminal and n.kind == .agent and n.session_id.len > 0) try out.append(arena, n.session_id);
        return out.items;
    }

    fn ranSession(self: World, terminal: u64, ids: []const []const u8) bool {
        for (self.sessions.sessions) |s| {
            if (s.terminal != terminal) continue;
            for (ids) |id| if (std.mem.eql(u8, id, s.session_id)) return true;
        }
        for (self.notes) |n| {
            if (n.terminal != terminal or n.kind != .agent) continue;
            for (ids) |id| if (std.mem.eql(u8, id, n.session_id)) return true;
        }
        return false;
    }

    /// The stretches `terminal` spent in a project's tabs, one per name.
    fn projectWindows(self: World, arena: Allocator, terminal: u64, names: []const []const u8) Allocator.Error![]const Window {
        var out: std.ArrayListUnmanaged(Window) = .empty;
        var open: ?struct { from: i64, mine: bool } = null;
        for (self.notes) |n| {
            if (n.terminal != terminal or n.kind != .project) continue;
            if (open) |o| if (o.mine) try out.append(arena, .{ .from = o.from, .to = n.at_ms });
            open = null;
            if (n.project) |p| open = .{ .from = n.at_ms, .mine = contains(names, p) };
        }
        if (open) |o| if (o.mine) try out.append(arena, .{ .from = o.from, .to = null });
        return out.items;
    }
};

fn contains(names: []const []const u8, s: []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// What `access.caller` may read of `terminal`.
pub fn reachOf(arena: Allocator, world: World, access: Access, terminal: u64) Allocator.Error!Reach {
    if (terminal == access.caller) return .{ .all = true };
    const mine = try world.sessionIdsOf(arena, access.caller);
    if (mine.len > 0 and world.ranSession(terminal, mine)) return .{ .all = true };

    var groups: std.ArrayListUnmanaged(Window) = .empty;
    var any: std.ArrayListUnmanaged(Window) = .empty;
    for (world.sessions.stints) |s| {
        if (s.terminal != terminal) continue;
        const w: Window = .{ .from = s.from_ms, .to = s.to_ms };
        try any.append(arena, w);
        if (contains(access.supervises, s.group)) try groups.append(arena, w);
    }
    return .{
        .groups = groups.items,
        .projects = try world.projectWindows(arena, terminal, access.projects),
        .in_any_group = any.items,
    };
}

/// The terminals a scope is about, before reach is asked. Refused when the
/// scope itself is not the caller's.
fn terminalsOf(arena: Allocator, io: Io, state_dir: []const u8, world: World, access: Access, scope: Scope) Allocator.Error!union(enum) { ok: []const u64, refused: Refusal } {
    var out: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    switch (scope) {
        .mine => {
            try out.put(arena, access.caller, {});
            const mine = try world.sessionIdsOf(arena, access.caller);
            for (world.dirs) |d| if (mine.len > 0 and world.ranSession(d.terminal, mine)) try out.put(arena, d.terminal, {});
        },
        .group => |g| {
            if (!contains(access.supervises, g)) return .{ .refused = .{
                .code = "NotYourGroup",
                .message = "only that group's supervisor may look back through what its members did; your own record is record_list with no scope.",
            } };
            for (world.sessions.stints) |s| if (std.mem.eql(u8, s.group, g)) try out.put(arena, s.terminal, {});
        },
        .project => |p| {
            if (!contains(access.projects, p)) return .{ .refused = .{
                .code = "NotYourProject",
                .message = "only the supervisor of a group tied to that project may look back through its terminals.",
            } };
            for (world.notes) |n| if (n.kind == .project and n.project != null and std.mem.eql(u8, n.project.?, p)) try out.put(arena, n.terminal, {});
        },
        .task => |id| {
            const held = try taskHolders(arena, io, state_dir, id);
            const g = held.group orelse return .{ .refused = .{
                .code = "NoSuchTask",
                .message = "no task with that number is in the record.",
            } };
            const own = contains64(held.owners, access.caller);
            if (!own and !contains(access.supervises, g)) return .{ .refused = .{
                .code = "NotYourGroup",
                .message = "that task is another group's; only its supervisor may look back through who worked on it.",
            } };
            for (held.owners) |o| try out.put(arena, o, {});
        },
        .terminal => |t| try out.put(arena, t, {}),
        .session => |sid| {
            const want = [_][]const u8{sid};
            for (world.dirs) |d| if (world.ranSession(d.terminal, &want)) try out.put(arena, d.terminal, {});
            for (world.sessions.sessions) |s| if (std.mem.eql(u8, s.session_id, sid)) try out.put(arena, s.terminal, {});
        },
    }
    return .{ .ok = out.keys() };
}

fn contains64(ids: []const u64, x: u64) bool {
    for (ids) |y| if (x == y) return true;
    return false;
}

/// Which group a task is in, and every terminal that held it.
fn taskHolders(arena: Allocator, io: Io, state_dir: []const u8, task: u64) Allocator.Error!struct { group: ?[]const u8, owners: []const u64 } {
    var owners: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    var group: ?[]const u8 = null;
    const root = try std.fs.path.join(arena, &.{ state_dir, "tasks" });
    var d = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return .{ .group = null, .owners = &.{} };
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const gdir = try std.fs.path.join(arena, &.{ root, e.name });
        var g = Io.Dir.cwd().openDir(io, gdir, .{ .iterate = true }) catch continue;
        defer g.close(io);
        var fit = g.iterate();
        while (fit.next(io) catch null) |f| {
            if (daylog.TerminalTree.parseDayFile(f.name) == null) continue;
            const path = try std.fs.path.join(arena, &.{ gdir, f.name });
            const bytes = Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(16 * 1024 * 1024)) catch continue;
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
                const obj = switch (v) {
                    .object => |o| o,
                    else => continue,
                };
                const t = switch (obj.get("task") orelse continue) {
                    .integer => |n| n,
                    else => continue,
                };
                if (t < 0 or @as(u64, @intCast(t)) != task) continue;
                if (obj.get("group")) |gv| if (gv == .string) {
                    group = gv.string;
                };
                if (obj.get("owner")) |ov| if (ov == .string) if (SessionLog.parseId(ov.string)) |o| if (o != 0) try owners.put(arena, o, {});
            }
        }
    }
    return .{ .group = group, .owners = owners.keys() };
}

// ------------------------------------------------------------ the tools

pub const ListArgs = struct {
    scope: Scope,
    since_ms: i64 = 0,
    until_ms: i64 = 0,
    cursor: u64 = 0,
    limit: u64 = 0,
};

/// `record_list`: the terminals in scope the caller may read anything of,
/// with what is known about each and which days there are.
pub fn list(arena: Allocator, io: Io, state_dir: []const u8, access: Access, args: ListArgs) Allocator.Error!Answer {
    const world = try World.read(arena, io, state_dir);
    const found = try terminalsOf(arena, io, state_dir, world, access, args.scope);
    const ids = switch (found) {
        .refused => |r| return .{ .refused = r },
        .ok => |v| v,
    };
    const want: usize = if (args.limit == 0) max_terminals else @intCast(@min(args.limit, max_terminals));

    var buf: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &buf.writer };
    try begin(&s, "terminals");
    var shown: usize = 0;
    var i: usize = @intCast(@min(args.cursor, ids.len));
    while (i < ids.len and shown < want) : (i += 1) {
        const t = ids[i];
        const reach = try reachOf(arena, world, access, t);
        if (reach.none()) continue;
        try writeTerminal(arena, io, state_dir, &s, world, access, t, reach, args);
        shown += 1;
    }
    try end(&s, if (i < ids.len) i else null);
    return .{ .json = buf.written() };
}

fn begin(s: *std.json.Stringify, field: []const u8) Allocator.Error!void {
    s.beginObject() catch return error.OutOfMemory;
    s.objectField(field) catch return error.OutOfMemory;
    s.beginArray() catch return error.OutOfMemory;
}

fn end(s: *std.json.Stringify, cursor: ?usize) Allocator.Error!void {
    s.endArray() catch return error.OutOfMemory;
    s.objectField("more") catch return error.OutOfMemory;
    s.write(cursor != null) catch return error.OutOfMemory;
    if (cursor) |c| {
        s.objectField("cursor") catch return error.OutOfMemory;
        s.write(c) catch return error.OutOfMemory;
    }
    s.endObject() catch return error.OutOfMemory;
}

fn idText(buf: *[18]u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "0x{x:0>16}", .{id}) catch unreachable;
}

fn dayText(buf: *[10]u8, day: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ day / 10000, day / 100 % 100, day % 100 }) catch unreachable;
}

fn writeTerminal(arena: Allocator, io: Io, state_dir: []const u8, s: *std.json.Stringify, world: World, access: Access, t: u64, reach: Reach, args: ListArgs) Allocator.Error!void {
    writeTerminalInner(arena, io, state_dir, s, world, access, t, reach, args) catch return error.OutOfMemory;
}

fn writeTerminalInner(arena: Allocator, io: Io, state_dir: []const u8, s: *std.json.Stringify, world: World, access: Access, t: u64, reach: Reach, args: ListArgs) !void {
    var idb: [18]u8 = undefined;
    try s.beginObject();
    try s.objectField("terminal");
    try s.write(idText(&idb, t));
    try s.objectField("reach");
    try s.write(if (reach.all) "all" else "while_yours");

    var dir_name: ?[]const u8 = null;
    for (world.dirs) |d| if (d.terminal == t) {
        dir_name = d.name;
    };
    try s.objectField("title");
    try s.write(if (dir_name) |n| (if (n.len > 17) n[17..] else "") else "");

    // The groups it was in that the caller may see: its own, or theirs.
    try s.objectField("groups");
    try s.beginArray();
    for (world.sessions.stints) |st| {
        if (st.terminal != t) continue;
        if (!reach.all and !contains(access.supervises, st.group)) continue;
        try s.beginObject();
        try s.objectField("group");
        try s.write(st.group);
        try s.objectField("role");
        try s.write(st.role);
        try s.objectField("from_ms");
        try s.write(st.from_ms);
        try s.objectField("to_ms");
        try s.write(st.to_ms);
        try s.objectField("inferred");
        try s.write(st.inferred);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("sessions");
    try s.beginArray();
    for (world.notes) |n| {
        if (n.terminal != t or n.kind != .agent) continue;
        try s.beginObject();
        try s.objectField("at_ms");
        try s.write(n.at_ms);
        try s.objectField("cli");
        try s.write(n.cli);
        try s.objectField("session_id");
        try s.write(n.session_id);
        // Where the CLI keeps its own record. Polter does not read it.
        try s.objectField("transcript_path");
        try s.write(n.transcript_path);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("roles");
    try s.beginArray();
    for (world.notes) |n| if (n.terminal == t and n.kind == .role) try s.write(n.role);
    try s.endArray();

    // Its days, as far as anything in them may be read and they fall
    // inside since / until.
    try s.objectField("days");
    try s.beginArray();
    if (dir_name) |name| {
        const path = try std.fs.path.join(arena, &.{ state_dir, "terminals", name });
        const files = try dayFiles(arena, io, path);
        std.mem.sort(DayPart, files.items, {}, DayPart.older);
        for (files.items) |f| {
            if (!dayMayHold(reach, f.day, args)) continue;
            var db: [10]u8 = undefined;
            try s.beginObject();
            try s.objectField("day");
            try s.write(dayText(&db, f.day));
            try s.objectField("part");
            try s.write(f.part);
            try s.objectField("bytes");
            try s.write(f.bytes);
            try s.endObject();
        }
    }
    try s.endArray();
    try s.endObject();
}

const DayPart = struct {
    day: u32,
    part: u32,
    bytes: u64,
    name: []const u8,

    fn older(_: void, a: DayPart, b: DayPart) bool {
        if (a.day != b.day) return a.day < b.day;
        return a.part < b.part;
    }
};

fn dayFiles(arena: Allocator, io: Io, path: []const u8) Allocator.Error!std.ArrayListUnmanaged(DayPart) {
    var out: std.ArrayListUnmanaged(DayPart) = .empty;
    var d = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const df = daylog.TerminalTree.parseDayFile(e.name) orelse continue;
        const full = try std.fs.path.join(arena, &.{ path, e.name });
        const st = Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        try out.append(arena, .{ .day = df.day, .part = df.part, .bytes = st.size, .name = full });
    }
    return out;
}

/// Whether a day could hold a readable line inside since / until. Days,
/// not moments, so it errs towards listing a day: `record_read` filters
/// each line.
fn dayMayHold(reach: Reach, day: u32, args: ListArgs) bool {
    if (args.since_ms > 0 and day < daylog.dayOf(args.since_ms)) return false;
    if (args.until_ms > 0 and day > daylog.dayOf(args.until_ms)) return false;
    if (reach.all) return true;
    for ([_][]const Window{ reach.groups, reach.projects }) |ws| for (ws) |w| {
        if (day < daylog.dayOf(w.from)) continue;
        if (w.to) |to| if (day > daylog.dayOf(to)) continue;
        return true;
    };
    return false;
}

pub const ReadArgs = struct {
    terminal: u64,
    /// `YYYY-MM-DD`.
    day: []const u8,
    part: u64 = 1,
    from_line: u64 = 0,
    limit: u64 = 0,
};

/// `record_read`: the lines of one day of one transcript the caller may
/// read, from `from_line` on. Lines it may not read are counted, not shown.
pub fn read(arena: Allocator, io: Io, state_dir: []const u8, access: Access, args: ReadArgs) Allocator.Error!Answer {
    const world = try World.read(arena, io, state_dir);
    const reach = try reachOf(arena, world, access, args.terminal);
    if (reach.none()) return .{ .refused = .{
        .code = "NotReachable",
        .message = "nothing of that terminal's record is yours to read: it is not yours, and was never in a group you supervise.",
    } };
    var name: ?[]const u8 = null;
    for (world.dirs) |d| if (d.terminal == args.terminal) {
        name = d.name;
    };
    const dir = name orelse return .{ .refused = .{ .code = "NoRecord", .message = "that terminal has no transcript on disk." } };
    if (args.day.len != 10) return .{ .refused = .{ .code = "BadDay", .message = "day is written YYYY-MM-DD, as record_list gives it." } };
    const file = if (args.part <= 1)
        try std.fmt.allocPrint(arena, "{s}.jsonl", .{args.day})
    else
        try std.fmt.allocPrint(arena, "{s}.part{d}.jsonl", .{ args.day, args.part });
    if (daylog.TerminalTree.parseDayFile(file) == null) return .{ .refused = .{ .code = "BadDay", .message = "day is written YYYY-MM-DD, as record_list gives it." } };
    const path = try std.fs.path.join(arena, &.{ state_dir, "terminals", dir, file });
    const bytes = Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(64 * 1024 * 1024)) catch
        return .{ .refused = .{ .code = "NoRecord", .message = "there is no such day in that terminal's transcript; record_list says which there are." } };

    const want: usize = if (args.limit == 0) default_lines else @intCast(@min(args.limit, max_lines));
    var buf: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &buf.writer };
    writeLines(arena, &s, bytes, reach, args.from_line, want) catch return error.OutOfMemory;
    return .{ .json = buf.written() };
}

fn writeLines(alloc: Allocator, s: *std.json.Stringify, bytes: []const u8, reach: Reach, from_line: u64, want: usize) !void {
    try s.beginObject();
    try s.objectField("lines");
    try s.beginArray();
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var n: u64 = 0;
    var shown: usize = 0;
    var size: usize = 0;
    var withheld: u64 = 0;
    var next: ?u64 = null;
    while (it.next()) |line| : (n += 1) {
        if (line.len == 0) continue;
        if (n < from_line) continue;
        if (shown >= want or size + line.len > max_reply_bytes) {
            next = n;
            break;
        }
        const at = atOf(line) orelse continue;
        if (!reach.readable(at)) {
            withheld += 1;
            continue;
        }
        try s.beginObject();
        try s.objectField("line");
        try s.write(n);
        try s.objectField("at_ms");
        try s.write(at);
        try s.objectField("text");
        try s.write(textOf(alloc, line));
        try s.endObject();
        shown += 1;
        size += line.len;
    }
    try s.endArray();
    // Said, so that a page with gaps is not read as the whole of the day.
    try s.objectField("withheld");
    try s.write(withheld);
    try s.objectField("more");
    try s.write(next != null);
    if (next) |v| {
        try s.objectField("next_line");
        try s.write(v);
    }
    try s.endObject();
}

/// The `at_ms` of a transcript line, without parsing the rest.
fn atOf(line: []const u8) ?i64 {
    const key = "\"at_ms\":";
    const i = std.mem.indexOf(u8, line, key) orelse return null;
    var j = i + key.len;
    const start = j;
    while (j < line.len and (std.ascii.isDigit(line[j]) or line[j] == '-')) j += 1;
    return std.fmt.parseInt(i64, line[start..j], 10) catch null;
}

/// The text of a transcript line, as written before it was escaped. A line
/// that will not parse is handed on as it is rather than dropped.
fn textOf(alloc: Allocator, line: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(struct { text: []const u8 = "" }, alloc, line, .{
        .ignore_unknown_fields = true,
    }) catch return line;
    return parsed.text;
}

pub const SearchArgs = struct {
    scope: Scope,
    query: []const u8,
    since_ms: i64 = 0,
    until_ms: i64 = 0,
    /// Where the last page stopped: the file, counted in the order this
    /// walks them, and the line in it.
    after_file: u64 = 0,
    after_line: u64 = 0,
};

/// `record_search`: lines the caller may read that contain `query`, as
/// typed, ignoring ASCII case. At most `max_hits` a page, and at most
/// `search_budget` bytes read; either way the reply says where to go on.
pub fn search(arena: Allocator, io: Io, state_dir: []const u8, access: Access, args: SearchArgs) Allocator.Error!Answer {
    if (args.query.len == 0) return .{ .refused = .{ .code = "BadQuery", .message = "say what to look for." } };
    const world = try World.read(arena, io, state_dir);
    const found = try terminalsOf(arena, io, state_dir, world, access, args.scope);
    const ids = switch (found) {
        .refused => |r| return .{ .refused = r },
        .ok => |v| v,
    };

    // Every file in scope, in one order a cursor can name.
    const Target = struct { terminal: u64, reach: Reach, f: DayPart };
    var targets: std.ArrayListUnmanaged(Target) = .empty;
    for (ids) |t| {
        const reach = try reachOf(arena, world, access, t);
        if (reach.none()) continue;
        for (world.dirs) |d| {
            if (d.terminal != t) continue;
            const path = try std.fs.path.join(arena, &.{ state_dir, "terminals", d.name });
            const files = try dayFiles(arena, io, path);
            std.mem.sort(DayPart, files.items, {}, DayPart.older);
            for (files.items) |f| if (dayMayHold(reach, f.day, .{ .scope = .mine, .since_ms = args.since_ms, .until_ms = args.until_ms })) try targets.append(arena, .{ .terminal = t, .reach = reach, .f = f });
        }
    }

    var buf: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &buf.writer };
    writeHits(arena, io, &s, targets.items, args) catch return error.OutOfMemory;
    return .{ .json = buf.written() };
}

fn writeHits(arena: Allocator, io: Io, s: *std.json.Stringify, targets: anytype, args: SearchArgs) !void {
    try s.beginObject();
    try s.objectField("hits");
    try s.beginArray();
    var read_bytes: u64 = 0;
    var hits: usize = 0;
    var stop: ?struct { file: u64, line: u64 } = null;
    // One line's parse at a time: a search reads tens of megabytes.
    var line_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer line_arena.deinit();
    var fi: usize = @intCast(@min(args.after_file, targets.len));
    outer: while (fi < targets.len) : (fi += 1) {
        const tg = targets[fi];
        if (read_bytes + tg.f.bytes > search_budget and read_bytes > 0) {
            stop = .{ .file = fi, .line = 0 };
            break;
        }
        const bytes = Io.Dir.readFileAlloc(.cwd(), io, tg.f.name, arena, .limited(64 * 1024 * 1024)) catch continue;
        read_bytes += bytes.len;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        var n: u64 = 0;
        const first: u64 = if (fi == args.after_file) args.after_line else 0;
        while (it.next()) |line| : (n += 1) {
            if (n < first or line.len == 0) continue;
            const at = atOf(line) orelse continue;
            if (args.since_ms > 0 and at < args.since_ms) continue;
            if (args.until_ms > 0 and at > args.until_ms) continue;
            if (!tg.reach.readable(at)) continue;
            _ = line_arena.reset(.retain_capacity);
            const text = textOf(line_arena.allocator(), line);
            const k = std.ascii.indexOfIgnoreCase(text, args.query) orelse continue;
            if (hits >= max_hits) {
                stop = .{ .file = fi, .line = n };
                break :outer;
            }
            var idb: [18]u8 = undefined;
            var db: [10]u8 = undefined;
            try s.beginObject();
            try s.objectField("terminal");
            try s.write(idText(&idb, tg.terminal));
            try s.objectField("day");
            try s.write(dayText(&db, tg.f.day));
            try s.objectField("part");
            try s.write(tg.f.part);
            try s.objectField("line");
            try s.write(n);
            try s.objectField("at_ms");
            try s.write(at);
            const lo = k -| snippet_chars / 2;
            const hi = @min(text.len, lo + snippet_chars);
            try s.objectField("snippet");
            try s.write(text[lo..hi]);
            try s.endObject();
            hits += 1;
        }
    }
    try s.endArray();
    try s.objectField("more");
    try s.write(stop != null);
    if (stop) |st| {
        try s.objectField("after_file");
        try s.write(st.file);
        try s.objectField("after_line");
        try s.write(st.line);
    }
    try s.objectField("read_bytes");
    try s.write(read_bytes);
    try s.endObject();
}

// ------------------------------------------------------------ logs

/// A log `log_list` names, relative to the state directory.
fn isLogName(name: []const u8) bool {
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.startsWith(u8, name, "plugins/")) return std.mem.endsWith(u8, name, ".log") or std.mem.endsWith(u8, name, ".log.1");
    if (std.mem.startsWith(u8, name, "logs/")) return std.mem.endsWith(u8, name, ".log");
    return false;
}

/// `log_list`: Polter's own logs -- each plugin's, the Windows host's --
/// and the crash reports, by name. Crash reports are listed and not read:
/// they are binary dumps for a debugger.
pub fn logList(arena: Allocator, io: Io, state_dir: []const u8) Allocator.Error!Answer {
    var buf: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &buf.writer };
    logListInner(arena, io, state_dir, &s) catch return error.OutOfMemory;
    return .{ .json = buf.written() };
}

fn logListInner(arena: Allocator, io: Io, state_dir: []const u8, s: *std.json.Stringify) !void {
    try s.beginObject();
    try s.objectField("logs");
    try s.beginArray();
    for ([_][]const u8{ "plugins", "logs", "crash" }) |sub| {
        const dir = try std.fs.path.join(arena, &.{ state_dir, sub });
        var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind == .directory) continue;
            const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, e.name });
            const crash = std.mem.eql(u8, sub, "crash");
            if (!crash and !isLogName(rel)) continue;
            const st = Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ dir, e.name }), .{}) catch continue;
            try s.beginObject();
            try s.objectField("name");
            try s.write(rel);
            try s.objectField("bytes");
            try s.write(st.size);
            try s.objectField("modified_ms");
            try s.write(@as(i64, @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms))));
            try s.objectField("readable");
            try s.write(!crash);
            try s.endObject();
        }
    }
    try s.endArray();
    try s.endObject();
}

pub const LogReadArgs = struct {
    name: []const u8,
    /// Null: the last `limit` lines.
    from_line: ?u64 = null,
    limit: u64 = 0,
};

/// `log_read`: lines of one log `log_list` named.
pub fn logRead(arena: Allocator, io: Io, state_dir: []const u8, args: LogReadArgs) Allocator.Error!Answer {
    if (!isLogName(args.name)) return .{ .refused = .{
        .code = "NoSuchLog",
        .message = "name a log as log_list gives it; crash reports are listed, not read.",
    } };
    const path = try std.fs.path.join(arena, &.{ state_dir, args.name });
    const bytes = Io.Dir.readFileAlloc(.cwd(), io, path, arena, .limited(64 * 1024 * 1024)) catch
        return .{ .refused = .{ .code = "NoSuchLog", .message = "that log is not there now; log_list says what is." } };

    // Lines, not newlines: a log that ends in one has no empty line after it.
    var count: u64 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |_| count += 1;
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') count -= 1;
    const want: u64 = if (args.limit == 0) default_lines else @min(args.limit, max_lines);
    const from = args.from_line orelse (count -| want);

    var buf: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &buf.writer };
    writeLogLines(&s, bytes, from, want) catch return error.OutOfMemory;
    return .{ .json = buf.written() };
}

fn writeLogLines(s: *std.json.Stringify, bytes: []const u8, from: u64, want: u64) !void {
    try s.beginObject();
    try s.objectField("lines");
    try s.beginArray();
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var n: u64 = 0;
    var shown: u64 = 0;
    var size: usize = 0;
    var next: ?u64 = null;
    while (it.next()) |line| : (n += 1) {
        if (n < from) continue;
        if (line.len == 0 and it.peek() == null) break;
        if (shown >= want or size + line.len > max_reply_bytes) {
            next = n;
            break;
        }
        try s.write(line);
        shown += 1;
        size += line.len;
    }
    try s.endArray();
    try s.objectField("from_line");
    try s.write(from);
    try s.objectField("more");
    try s.write(next != null);
    if (next) |v| {
        try s.objectField("next_line");
        try s.write(v);
    }
    try s.endObject();
}

const testing = std.testing;

test "a supervisor reads a member only while it was a member" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var stints = [_]SessionLog.Stint{
        .{ .group = "build", .terminal = 0x22, .from_ms = 100, .to_ms = 200, .role = "", .cli = "", .inferred = false },
        .{ .group = "ops", .terminal = 0x22, .from_ms = 300, .to_ms = null, .role = "", .cli = "", .inferred = false },
    };
    const world: World = .{ .sessions = .{ .stints = &stints, .sessions = &.{}, .ties = &.{} }, .notes = &.{}, .dirs = &.{} };
    const r = try reachOf(arena.allocator(), world, .{ .caller = 0x11, .supervises = &.{"build"}, .projects = &.{} }, 0x22);
    try testing.expect(!r.readable(99));
    try testing.expect(r.readable(150));
    try testing.expect(!r.readable(201));
    // In "ops" then: another group's, not this supervisor's.
    try testing.expect(!r.readable(400));
}

test "a terminal reads all of its own, and of an earlier run of its session" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const notes = [_]TerminalMeta.Note{
        .{ .terminal = 0x11, .at_ms = 1, .kind = .agent, .session_id = "s-1" },
        .{ .terminal = 0x05, .at_ms = 0, .kind = .agent, .session_id = "s-1" },
        .{ .terminal = 0x06, .at_ms = 0, .kind = .agent, .session_id = "s-9" },
    };
    const world: World = .{ .sessions = .{ .stints = &.{}, .sessions = &.{}, .ties = &.{} }, .notes = &notes, .dirs = &.{} };
    const access: Access = .{ .caller = 0x11, .supervises = &.{}, .projects = &.{} };
    try testing.expect((try reachOf(arena.allocator(), world, access, 0x11)).all);
    try testing.expect((try reachOf(arena.allocator(), world, access, 0x05)).all);
    try testing.expect((try reachOf(arena.allocator(), world, access, 0x06)).none());
}

test "a project is read only outside any group's stretch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var stints = [_]SessionLog.Stint{
        .{ .group = "other", .terminal = 0x22, .from_ms = 150, .to_ms = 160, .role = "", .cli = "", .inferred = false },
    };
    const notes = [_]TerminalMeta.Note{
        .{ .terminal = 0x22, .at_ms = 100, .kind = .project, .project = "polter" },
        .{ .terminal = 0x22, .at_ms = 300, .kind = .project, .project = null },
    };
    const world: World = .{ .sessions = .{ .stints = &stints, .sessions = &.{}, .ties = &.{} }, .notes = &notes, .dirs = &.{} };
    const r = try reachOf(arena.allocator(), world, .{ .caller = 0x11, .supervises = &.{"mine"}, .projects = &.{"polter"} }, 0x22);
    try testing.expect(r.readable(120));
    // Then it was in "other": that group's, not the project's.
    try testing.expect(!r.readable(155));
    try testing.expect(r.readable(200));
    try testing.expect(!r.readable(301));
    // A project that is not the caller's: nothing.
    const r2 = try reachOf(arena.allocator(), world, .{ .caller = 0x11, .supervises = &.{}, .projects = &.{"else"} }, 0x22);
    try testing.expect(r2.none());
}

test "another group's record is refused, not filtered to nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const world: World = .{ .sessions = .{ .stints = &.{}, .sessions = &.{}, .ties = &.{} }, .notes = &.{}, .dirs = &.{} };
    const got = try terminalsOf(arena.allocator(), threaded.io(), "/tmp/polter-records-none-3c1d", world, .{ .caller = 1, .supervises = &.{"mine"}, .projects = &.{} }, .{ .group = "theirs" });
    try testing.expect(got == .refused);
    try testing.expectEqualStrings("NotYourGroup", got.refused.code);
}

test "a read says how many lines it held back and where to go on" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var s: std.json.Stringify = .{ .writer = &buf.writer };
    const day =
        \\{"at_ms":100,"text":"before"}
        \\{"at_ms":150,"text":"during one"}
        \\{"at_ms":160,"text":"during two"}
        \\{"at_ms":300,"text":"after"}
        \\
    ;
    const windows = [_]Window{.{ .from = 120, .to = 200 }};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try writeLines(arena.allocator(), &s, day, .{ .groups = &windows }, 0, 1);
    try testing.expectEqualStrings(
        \\{"lines":[{"line":1,"at_ms":150,"text":"during one"}],"withheld":1,"more":true,"next_line":2}
    , buf.written());
}

test "only Polter's logs can be named for reading" {
    try testing.expect(isLogName("plugins/archive.log"));
    try testing.expect(isLogName("plugins/archive.log.1"));
    try testing.expect(isLogName("logs/polter-host-12.log"));
    try testing.expect(!isLogName("crash/x.ghosttycrash"));
    try testing.expect(!isLogName("plugins/../session.json"));
    try testing.expect(!isLogName("plugins/archive.json"));
    try testing.expect(!isLogName("chat/build/2026-10-15.jsonl"));
}

test "the tools on a state directory: list, read, search, logs" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const state = try std.fmt.allocPrint(alloc, "/tmp/polter-records-{x}", .{&raw});
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    const put = struct {
        fn f(io_: Io, a: Allocator, base: []const u8, rel: []const u8, text: []const u8) !void {
            const path = try std.fs.path.join(a, &.{ base, rel });
            defer a.free(path);
            try Io.Dir.cwd().createDirPath(io_, std.fs.path.dirname(path).?);
            var file = try Io.Dir.cwd().createFile(io_, path, .{});
            defer file.close(io_);
            try file.writePositionalAll(io_, text, 0);
        }
    }.f;
    // Moments a day file is really dated by, and the file named from them.
    const base: i64 = 1_791_000_000_000;
    var db: [10]u8 = undefined;
    const day = dayText(&db, daylog.dayOf(base));
    const rel = try std.fmt.allocPrint(alloc, "terminals/0000000000000022-zsh/{s}.jsonl", .{day});
    defer alloc.free(rel);
    const body = try std.fmt.allocPrint(alloc,
        \\{{"at_ms":{d},"text":"before it joined: secret"}}
        \\{{"at_ms":{d},"text":"building the thing"}}
        \\{{"at_ms":{d},"text":"after it left: secret"}}
        \\
    , .{ base - 50, base + 30, base + 180 });
    defer alloc.free(body);
    try put(io, alloc, state, rel, body);
    try put(io, alloc, state, "plugins/archive.log", "one\ntwo\nthree\n");
    {
        var l = try SessionLog.open(alloc, io, state);
        defer l.deinit();
        l.joined("build", base, 0x22, .{ .role = "worker" }, false);
        l.left("build", base + 100, 0x22, false);
    }

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const boss: Access = .{ .caller = 0x11, .supervises = &.{"build"}, .projects = &.{} };

    const listed = try list(a, io, state, boss, .{ .scope = .{ .group = "build" } });
    try testing.expect(std.mem.indexOf(u8, listed.json, "\"terminal\":\"0x0000000000000022\"") != null);
    try testing.expect(std.mem.indexOf(u8, listed.json, "\"reach\":\"while_yours\"") != null);
    try testing.expect(std.mem.indexOf(u8, listed.json, "\"title\":\"zsh\"") != null);

    const page = try read(a, io, state, boss, .{ .terminal = 0x22, .day = day });
    try testing.expect(std.mem.indexOf(u8, page.json, "building the thing") != null);
    try testing.expect(std.mem.indexOf(u8, page.json, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, page.json, "\"withheld\":2") != null);

    // Only the line inside the stint is found.
    const none = try search(a, io, state, boss, .{ .scope = .{ .group = "build" }, .query = "SECRET" });
    try testing.expect(std.mem.indexOf(u8, none.json, "\"hits\":[]") != null);
    const one = try search(a, io, state, boss, .{ .scope = .{ .group = "build" }, .query = "Building" });
    try testing.expect(std.mem.indexOf(u8, one.json, "\"line\":1") != null);

    // Somebody else's group, and a terminal that was never in yours.
    const theirs = try list(a, io, state, .{ .caller = 0x33, .supervises = &.{"ops"}, .projects = &.{} }, .{ .scope = .{ .group = "build" } });
    try testing.expect(theirs == .refused);
    try testing.expectEqualStrings("NotYourGroup", theirs.refused.code);
    const stranger = try read(a, io, state, .{ .caller = 0x33, .supervises = &.{}, .projects = &.{} }, .{ .terminal = 0x22, .day = day });
    try testing.expect(stranger == .refused);
    try testing.expectEqualStrings("NotReachable", stranger.refused.code);
    // Its own: everything.
    const own = try read(a, io, state, .{ .caller = 0x22, .supervises = &.{}, .projects = &.{} }, .{ .terminal = 0x22, .day = day });
    try testing.expect(std.mem.indexOf(u8, own.json, "\"withheld\":0") != null);

    const logs = try logList(a, io, state);
    try testing.expect(std.mem.indexOf(u8, logs.json, "\"name\":\"plugins/archive.log\"") != null);
    const tail = try logRead(a, io, state, .{ .name = "plugins/archive.log", .limit = 2 });
    try testing.expectEqualStrings("{\"lines\":[\"two\",\"three\"],\"from_line\":1,\"more\":false}", tail.json);
}
