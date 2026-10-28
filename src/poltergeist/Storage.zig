//! What Settings > General > Log Management shows and does (task 1511):
//! how much each kind of record takes, and "Clear…" for one kind.
//!
//! The kinds are the ones `dev-docs/poltergeist/storage.md` ("保留与清理")
//! lists. Most go round by `Sweeper`'s rule and are listed by the same
//! collectors it sweeps with, so what this counts is what a sweep would
//! see. Clearing one is that kind's sweep with nothing kept -- except that
//! a file being written is never touched, by this or by a sweep.
//!
//! The kinds kept for good have a clearing of their own each:
//!
//!   * **chat**: every group's day files before today. The group shells
//!     (`group.json`), the stream (`chat.jsonl`) and the session record are
//!     left alone: the list of groups, the last supervisor, the project
//!     ties and the message numbering do not depend on old days. The
//!     record's floor is held first (`ChatLog.holdFloor`), or the next
//!     start would fill the cleared days back in from the stream;
//!   * **tasks**: compacted, not deleted -- `TaskLog.compact`, which the
//!     app calls with the panel in hand;
//!   * **shell history**: only the files no saved project and no open
//!     pane names;
//!   * **the archive plugin's copy**: its day files before today.
//!
//! Nothing here touches a view. The words a host shows are its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ChatLog = @import("ChatLog.zig");
const daylog = @import("daylog.zig");
const Records = @import("Records.zig");
const Retention = @import("Retention.zig");
const Sweeper = @import("Sweeper.zig");

pub const Kind = enum {
    group_transcripts,
    project_transcripts,
    other_transcripts,
    logs,
    shots,
    rename_backups,
    chat,
    tasks,
    history,
    archive,

    /// Kept going round by `Sweeper`, as opposed to kept until cleared.
    pub fn goesRound(self: Kind) bool {
        return switch (self) {
            .group_transcripts, .project_transcripts, .other_transcripts, .logs, .shots, .rename_backups => true,
            .chat, .tasks, .history, .archive => false,
        };
    }

    fn tier(self: Kind) ?Retention.Tier {
        return switch (self) {
            .group_transcripts => .group,
            .project_transcripts => .project,
            .other_transcripts => .none,
            else => null,
        };
    }
};

/// How a kind is kept, as the page shows it and binds its fields: the two
/// config keys its row edits, or a fixed number of days, or for good.
pub const Rule = struct {
    kept: enum { cycle, fixed, forever },
    days_key: ?[]const u8 = null,
    mb_key: ?[]const u8 = null,
    fixed_days: ?u32 = null,
    /// What "Clear…" is called: tasks are compacted, not cleared.
    action: enum { clear, compact } = .clear,
};

pub fn ruleOf(kind: Kind) Rule {
    return switch (kind) {
        .group_transcripts => .{ .kept = .cycle, .mb_key = "poltergeist-terminal-log-group-max-mb" },
        .project_transcripts => .{ .kept = .cycle, .days_key = "poltergeist-terminal-log-project-keep-days", .mb_key = "poltergeist-terminal-log-project-max-mb" },
        .other_transcripts => .{ .kept = .cycle, .days_key = "poltergeist-terminal-log-keep-days", .mb_key = "poltergeist-terminal-log-max-mb" },
        .logs => .{ .kept = .cycle, .days_key = "poltergeist-log-keep-days", .mb_key = "poltergeist-log-max-mb" },
        .shots => .{ .kept = .cycle, .days_key = "poltergeist-shots-keep-days", .mb_key = "poltergeist-shots-max-mb" },
        .rename_backups => .{ .kept = .fixed, .fixed_days = Sweeper.rename_backup_days },
        .chat, .history, .archive => .{ .kept = .forever },
        .tasks => .{ .kept = .forever, .action = .compact },
    };
}

/// The page's JSON:
///
/// ```
/// {"state_dir":"…","total_bytes":N,"waiting_bytes":N|null,
///  "kinds":[{"key":"other_transcripts","kept":"cycle"|"fixed"|"forever",
///            "bytes":N,"files":N,"days_key":"…"|null,"mb_key":"…"|null,
///            "fixed_days":N|null,"action":"clear"|"compact"}, …]}
/// ```
///
/// The kinds come in `Kind` order, which is the page's order.
pub fn writeUsage(w: *std.Io.Writer, state_dir: []const u8, usages: []const Usage, waiting: ?u64) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    var total: u64 = 0;
    for (usages) |u| total += u.bytes;
    try s.beginObject();
    try s.objectField("state_dir");
    try s.write(state_dir);
    try s.objectField("total_bytes");
    try s.write(total);
    try s.objectField("waiting_bytes");
    try s.write(waiting);
    try s.objectField("kinds");
    try s.beginArray();
    for (usages) |u| {
        const r = ruleOf(u.kind);
        try s.beginObject();
        try s.objectField("key");
        try s.write(@tagName(u.kind));
        try s.objectField("kept");
        try s.write(@tagName(r.kept));
        try s.objectField("bytes");
        try s.write(u.bytes);
        try s.objectField("files");
        try s.write(u.files);
        try s.objectField("days_key");
        try s.write(r.days_key);
        try s.objectField("mb_key");
        try s.write(r.mb_key);
        try s.objectField("fixed_days");
        try s.write(r.fixed_days);
        try s.objectField("action");
        try s.write(@tagName(r.action));
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

pub const Usage = struct {
    kind: Kind,
    bytes: u64 = 0,
    files: usize = 0,
};

fn add(u: *Usage, files: []const Sweeper.Candidate) void {
    for (files) |c| {
        u.bytes += c.file.bytes;
        u.files += 1;
    }
}

/// How much each kind takes now, in `Kind` order.
pub fn usage(a: Allocator, io: Io, state_dir: []const u8, shots_dir: ?[]const u8, today: u32, dayOf: Records.DayOf) ![]Usage {
    const out = try a.alloc(Usage, std.enums.values(Kind).len);
    for (std.enums.values(Kind), out) |k, *u| u.* = .{ .kind = k };

    if (try Sweeper.collectTranscripts(a, io, state_dir, today, dayOf)) |t| {
        add(&out[@intFromEnum(Kind.group_transcripts)], t.tiers[@intFromEnum(Retention.Tier.group)]);
        add(&out[@intFromEnum(Kind.project_transcripts)], t.tiers[@intFromEnum(Retention.Tier.project)]);
        add(&out[@intFromEnum(Kind.other_transcripts)], t.tiers[@intFromEnum(Retention.Tier.none)]);
    }
    add(&out[@intFromEnum(Kind.logs)], try Sweeper.collectLogs(a, io, state_dir, today, dayOf));
    if (shots_dir) |d| add(&out[@intFromEnum(Kind.shots)], try Sweeper.collectShots(a, io, d, dayOf));
    if (try Sweeper.collectRenameBackups(a, io, state_dir, dayOf)) |b| add(&out[@intFromEnum(Kind.rename_backups)], b);
    add(&out[@intFromEnum(Kind.chat)], try groupDays(a, io, state_dir, "chat", today, false));
    add(&out[@intFromEnum(Kind.tasks)], try groupDays(a, io, state_dir, "tasks", today, false));
    add(&out[@intFromEnum(Kind.history)], try historyFiles(a, io, state_dir));
    add(&out[@intFromEnum(Kind.archive)], try archiveDays(a, io, state_dir, today, false));
    return out;
}

/// Clear one kind, as far as it can be: what is being written stays, and
/// for the kinds kept for good, what their own clearing keeps. `keep_history`
/// is every shell history file a saved project or an open pane names.
///
/// `tasks` is not cleared here: it is compacted by the app
/// (`TaskLog.compact`), which has the panel to compact it from.
pub fn clear(a: Allocator, io: Io, state_dir: []const u8, shots_dir: ?[]const u8, kind: Kind, keep_history: []const []const u8, today: u32, dayOf: Records.DayOf) !Sweeper.Report {
    var r: Sweeper.Report = .{};
    const nothing_kept: Retention.Limits = .{ .keep_days = null, .max_bytes = 0 };
    switch (kind) {
        .group_transcripts, .project_transcripts, .other_transcripts => {
            const t = (try Sweeper.collectTranscripts(a, io, state_dir, today, dayOf)) orelse return r;
            try Sweeper.deleteChosen(io, t.tiers[@intFromEnum(kind.tier().?)], nothing_kept, today, a, &r);
            Sweeper.tidyTranscripts(io, t, today, dayOf, &r);
        },
        .logs => try Sweeper.deleteChosen(io, try Sweeper.collectLogs(a, io, state_dir, today, dayOf), nothing_kept, today, a, &r),
        .shots => if (shots_dir) |d| try Sweeper.deleteChosen(io, try Sweeper.collectShots(a, io, d, dayOf), nothing_kept, today, a, &r),
        .rename_backups => if (try Sweeper.collectRenameBackups(a, io, state_dir, dayOf)) |backups| for (backups) |b| {
            Io.Dir.cwd().deleteTree(io, b.path) catch continue;
            r.dirs += 1;
            r.bytes += b.file.bytes;
        },
        // The floor first, for the same reason as deleting a group
        // (`ChatLog.holdFloor`, task 1665): the old days hold the highest
        // numbers whenever nobody has spoken today, and the next start would
        // fill them all back in from the stream.
        .chat => {
            try ChatLog.holdFloor(a, io, state_dir);
            deleteAll(io, try groupDays(a, io, state_dir, "chat", today, true), &r);
        },
        .archive => deleteAll(io, try archiveDays(a, io, state_dir, today, true), &r),
        .history => {
            const files = try historyFiles(a, io, state_dir);
            for (files) |c| {
                if (contains(keep_history, std.fs.path.basename(c.path))) continue;
                Io.Dir.cwd().deleteFile(io, c.path) catch continue;
                r.files += 1;
                r.bytes += c.file.bytes;
            }
        },
        .tasks => unreachable,
    }
    return r;
}

fn deleteAll(io: Io, files: []const Sweeper.Candidate, r: *Sweeper.Report) void {
    for (files) |c| {
        Io.Dir.cwd().deleteFile(io, c.path) catch continue;
        r.files += 1;
        r.bytes += c.file.bytes;
    }
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// The day files of every group under `<state>/<root>`; with `before_today`,
/// only the ones dated before today -- the clearable ones.
fn groupDays(a: Allocator, io: Io, state_dir: []const u8, comptime root: []const u8, today: u32, before_today: bool) ![]Sweeper.Candidate {
    var out: std.ArrayListUnmanaged(Sweeper.Candidate) = .empty;
    const base = try std.fs.path.join(a, &.{ state_dir, root });
    var d = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory and e.kind != .unknown) continue;
        try dayFiles(a, io, try std.fs.path.join(a, &.{ base, e.name }), today, before_today, &out);
    }
    return out.items;
}

fn archiveDays(a: Allocator, io: Io, state_dir: []const u8, today: u32, before_today: bool) ![]Sweeper.Candidate {
    var out: std.ArrayListUnmanaged(Sweeper.Candidate) = .empty;
    try dayFiles(a, io, try std.fs.path.join(a, &.{ state_dir, "archive" }), today, before_today, &out);
    return out.items;
}

fn dayFiles(a: Allocator, io: Io, dir: []const u8, today: u32, before_today: bool, out: *std.ArrayListUnmanaged(Sweeper.Candidate)) !void {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const df = daylog.TerminalTree.parseDayFile(e.name) orelse continue;
        if (before_today and df.day >= today) continue;
        const path = try std.fs.path.join(a, &.{ dir, e.name });
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try out.append(a, .{ .path = path, .file = .{ .day = df.day, .part = df.part, .bytes = st.size } });
    }
}

fn historyFiles(a: Allocator, io: Io, state_dir: []const u8) ![]Sweeper.Candidate {
    var out: std.ArrayListUnmanaged(Sweeper.Candidate) = .empty;
    const dir = try std.fs.path.join(a, &.{ state_dir, "history" });
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".history")) continue;
        const path = try std.fs.path.join(a, &.{ dir, e.name });
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        try out.append(a, .{ .path = path, .file = .{ .day = 0, .bytes = st.size } });
    }
    return out.items;
}

/// Every shell history file a saved project names: the `history` of each
/// pane in `<state>/projects/*.json`. A project that will not read keeps
/// nothing out of this list -- and then `clear` would delete what it names
/// -- so a file that will not parse makes the whole answer "cannot tell",
/// and the caller clears no history at all.
pub fn historyNamedByProjects(a: Allocator, io: Io, state_dir: []const u8) !?[]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const dir = try std.fs.path.join(a, &.{ state_dir, "projects" });
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".json")) continue;
        const path = try std.fs.path.join(a, &.{ dir, e.name });
        const bytes = Io.Dir.readFileAlloc(.cwd(), io, path, a, .limited(16 * 1024 * 1024)) catch return null;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return null;
        try collectHistory(a, v, &out);
    }
    return out.items;
}

fn collectHistory(a: Allocator, v: std.json.Value, out: *std.ArrayListUnmanaged([]const u8)) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "history") and kv.value_ptr.* == .string) {
                    if (kv.value_ptr.string.len > 0) try out.append(a, kv.value_ptr.string);
                } else try collectHistory(a, kv.value_ptr.*, out);
            }
        },
        .array => |arr| for (arr.items) |x| try collectHistory(a, x, out),
        else => {},
    }
}

const testing = std.testing;

fn testState(alloc: Allocator, io: Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-storage-{x}", .{&raw});
    try Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn put(io: Io, a: Allocator, base: []const u8, rel: []const u8, text: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ base, rel });
    defer a.free(path);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    var f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writePositionalAll(io, text, 0);
}

fn exists(io: Io, a: Allocator, base: []const u8, rel: []const u8) bool {
    const path = std.fs.path.join(a, &.{ base, rel }) catch return false;
    defer a.free(path);
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn fakeDay(at_ms: i64) u32 {
    return 20261001 + @as(u32, @intCast(@max(@divFloor(at_ms, 1000), 0)));
}

test "clearing the chat keeps today, the group shells and the stream" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try testState(alloc, io);
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try put(io, alloc, state, "chat/build/2026-10-01.jsonl", "x\n");
    try put(io, alloc, state, "chat/build/2026-10-14.part2.jsonl", "x\n");
    try put(io, alloc, state, "chat/build/2026-10-15.jsonl", "x\n");
    try put(io, alloc, state, "chat/build/group.json", "{}");
    try put(io, alloc, state, "chat/chat.jsonl", "x\n");
    try put(io, alloc, state, "sessions/build/2026-10-01.jsonl", "x\n");

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try clear(arena.allocator(), io, state, null, .chat, &.{}, 20261015, fakeDay);
    try testing.expectEqual(@as(usize, 2), r.files);
    try testing.expect(!exists(io, alloc, state, "chat/build/2026-10-01.jsonl"));
    try testing.expect(!exists(io, alloc, state, "chat/build/2026-10-14.part2.jsonl"));
    try testing.expect(exists(io, alloc, state, "chat/build/2026-10-15.jsonl"));
    try testing.expect(exists(io, alloc, state, "chat/build/group.json"));
    try testing.expect(exists(io, alloc, state, "chat/chat.jsonl"));
    try testing.expect(exists(io, alloc, state, "sessions/build/2026-10-01.jsonl"));
}

test "a cleared chat is not filled back in from the stream at the next start (task 1665)" {
    // Nobody has spoken today, so every day file is before today and every
    // one goes: measured off the files, the record then goes nowhere, and
    // the next start would copy the whole stream back in.
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try testState(alloc, io);
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    {
        var l = try ChatLog.open(alloc, io, state);
        defer l.deinit();
        _ = l.append("build", 7, "worker", 1000, false, "old one", 0);
        _ = l.append("build", 7, "worker", 2000, false, "old two", 0);
    }
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try clear(arena.allocator(), io, state, null, .chat, &.{}, 20261015, fakeDay);
    try testing.expectEqual(@as(usize, 1), r.files);

    // The restart.
    {
        var l = try ChatLog.open(alloc, io, state);
        defer l.deinit();
    }
    const left = try groupDays(arena.allocator(), io, state, "chat", 20261015, false);
    try testing.expectEqual(@as(usize, 0), left.len);
    try testing.expect(exists(io, alloc, state, "chat/chat.jsonl"));
}

test "clearing shell history keeps what a project or an open pane names" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try testState(alloc, io);
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try put(io, alloc, state, "history/aaaa.history", "ls\n");
    try put(io, alloc, state, "history/bbbb.history", "ls\n");
    try put(io, alloc, state, "history/cccc.history", "ls\n");
    try put(io, alloc, state, "projects/web.json",
        \\{"format":2,"pages":[{"tree":{"kind":"leaf","cwd":"/w","history":"aaaa.history"}}]}
    );

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const named = (try historyNamedByProjects(a, io, state)).?;
    var keep: std.ArrayListUnmanaged([]const u8) = .empty;
    try keep.appendSlice(a, named);
    try keep.append(a, "bbbb.history"); // an open pane's
    const r = try clear(a, io, state, null, .history, keep.items, 20261015, fakeDay);
    try testing.expectEqual(@as(usize, 1), r.files);
    try testing.expect(exists(io, alloc, state, "history/aaaa.history"));
    try testing.expect(exists(io, alloc, state, "history/bbbb.history"));
    try testing.expect(!exists(io, alloc, state, "history/cccc.history"));
}

test "a project that will not read keeps every shell history" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try testState(alloc, io);
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try put(io, alloc, state, "projects/broken.json", "{ not json");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const []const u8, null), try historyNamedByProjects(arena.allocator(), io, state));
}

test "clearing one tier of transcripts leaves the others and the file being written" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try testState(alloc, io);
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try put(io, alloc, state, "terminals/0000000000000011-a/2026-10-02.jsonl", "x\n");
    try put(io, alloc, state, "terminals/0000000000000022-b/2026-10-02.jsonl", "x\n");
    try put(io, alloc, state, "terminals/0000000000000022-b/2026-10-15.jsonl", "x\n");
    {
        const SessionLog = @import("SessionLog.zig");
        var l = try SessionLog.open(alloc, io, state);
        defer l.deinit();
        l.joined("build", 1000, 0x11, .{}, false);
    }
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try usage(a, io, state, null, 20261015, fakeDay);
    try testing.expectEqual(@as(usize, 1), before[@intFromEnum(Kind.group_transcripts)].files);
    try testing.expectEqual(@as(usize, 2), before[@intFromEnum(Kind.other_transcripts)].files);

    const r = try clear(a, io, state, null, .other_transcripts, &.{}, 20261015, fakeDay);
    try testing.expectEqual(@as(usize, 1), r.files);
    try testing.expect(exists(io, alloc, state, "terminals/0000000000000011-a/2026-10-02.jsonl"));
    try testing.expect(!exists(io, alloc, state, "terminals/0000000000000022-b/2026-10-02.jsonl"));
    try testing.expect(exists(io, alloc, state, "terminals/0000000000000022-b/2026-10-15.jsonl"));
}

test "clearing the archive keeps today's file" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try testState(alloc, io);
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try put(io, alloc, state, "archive/2026-10-01.jsonl", "x\n");
    try put(io, alloc, state, "archive/2026-10-15.jsonl", "x\n");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const r = try clear(arena.allocator(), io, state, null, .archive, &.{}, 20261015, fakeDay);
    try testing.expectEqual(@as(usize, 1), r.files);
    try testing.expect(exists(io, alloc, state, "archive/2026-10-15.jsonl"));
}

test "the page's JSON names each row's settings and how it is kept" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const usages = [_]Usage{
        .{ .kind = .group_transcripts, .bytes = 10, .files = 1 },
        .{ .kind = .tasks, .bytes = 5, .files = 2 },
        .{ .kind = .rename_backups, .bytes = 0, .files = 0 },
    };
    try writeUsage(&buf.writer, "/s", &usages, 7);
    try testing.expectEqualStrings(
        \\{"state_dir":"/s","total_bytes":15,"waiting_bytes":7,"kinds":[{"key":"group_transcripts","kept":"cycle","bytes":10,"files":1,"days_key":null,"mb_key":"poltergeist-terminal-log-group-max-mb","fixed_days":null,"action":"clear"},{"key":"tasks","kept":"forever","bytes":5,"files":2,"days_key":null,"mb_key":null,"fixed_days":null,"action":"compact"},{"key":"rename_backups","kept":"fixed","bytes":0,"files":0,"days_key":null,"mb_key":null,"fixed_days":7,"action":"clear"}]}
    , buf.written());
}

test "every key a row edits is a config key the log-management form has" {
    const Key = @import("../config/key.zig").Key;
    for (std.enums.values(Kind)) |k| {
        const r = ruleOf(k);
        if (r.days_key) |key| try testing.expect(std.meta.stringToEnum(Key, key) != null);
        if (r.mb_key) |key| try testing.expect(std.meta.stringToEnum(Key, key) != null);
        try testing.expect((r.kept == .cycle) == (r.mb_key != null));
    }
}
