//! An hourly line of what a group looked like, written by the program.
//!
//! **The point is the morning after a night nobody wrote anything down.**
//! The messages and the panel's events already say what *happened*; this
//! says what it *looked like at the time* -- how many tasks were open at
//! two, how many had gone past the mark. Both are derivable from the events
//! by replaying the whole night, and that is exactly the cost this removes:
//! "what did two in the morning look like" becomes one line to read instead
//! of a replay.
//!
//! Written by the program on a clock, and that is only acceptable because
//! it interrupts nobody. `docs/poltergeist/stats.md` argues at length
//! against an hourly summary *from the supervisor* -- it spends the one
//! thing that is scarcest here, and an hour with nothing new in it still
//! has to say something, so it says "all is well" until nobody reads it.
//! None of that applies to a file: nothing reads it until somebody goes
//! looking, and a quiet hour costs a line of disk.
//!
//! The shape is `daylog.Tree` again -- one directory per group, one file
//! per local day, one JSON object per line, under `<state>/stats` beside
//! `<state>/tasks` and `<state>/chat`. A third layout in one state
//! directory is the thing `docs/poltergeist/gaps.md` warns about, and how a
//! group name becomes a directory name is decided in exactly one place,
//! which is not this file.
//!
//! Failure is a warning and nothing else, the same as the other two: not
//! being able to write tonight's notes is no reason to stop the terminals
//! working tonight.

const StatsLog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");
const TaskLog = @import("TaskLog.zig");

const log = std.log.scoped(.poltergeist);

/// How long between one group's snapshots.
///
/// An hour because that is the resolution the question has: "what did two
/// in the morning look like". Finer would be a bigger file saying the same
/// thing, and the events are already there for anybody who needs the exact
/// minute.
pub const every_ms: i64 = 60 * 60 * 1000;

alloc: Allocator,
io: std.Io,

/// Owned: the tree borrows it.
dir: []const u8,

tree: daylog.Tree,

/// When each group was last written down.
///
/// In memory only, and deliberately: a restart writes one extra line, and
/// one extra line is a better failure than a missing hour. Keyed by the
/// group's name, which this owns a copy of.
last: std.StringHashMapUnmanaged(i64) = .empty,

/// What one line says. Counts and durations, nothing that took a judgement.
///
/// `over` is the one that has to be read carefully: it is how many open
/// tasks had gone longer than the configured mark without an event. **Not
/// how many are stuck** -- see `poltergeist-task-idle-after`. It is written
/// down because "two had gone past the mark at 02:00" is a fact about that
/// hour that cannot be recovered later without knowing what the mark was at
/// the time.
pub const Snap = struct {
    tasks: usize = 0,
    open: usize = 0,
    closed: usize = 0,
    cancelled: usize = 0,
    over: usize = 0,

    /// How long the group had been silent, and how long the quietest open
    /// task had been untouched, as of this line.
    quiet_ms: u64 = 0,
    idlest_ms: u64 = 0,

    /// The mark `over` and `idlest_ms` are to be read against, so a line
    /// written under one setting still means something after the setting
    /// changes.
    mark_ms: u64 = 0,
};

/// One task off the panel, as a snapshot counts it.
pub const Task = struct {
    id: u64,
    state: enum { open, closed, cancelled },
};

/// Work out one line's figures.
///
/// A free function over what it is given, so the arithmetic can be tested
/// without a disk: `App` reads the panel and the record, this counts them,
/// `append` writes the result down.
///
/// **Nothing here is a judgement.** `over` counts open tasks whose last
/// event is older than `mark_ms`, and that is all it means.
pub fn summarise(
    now_ms: i64,
    mark_ms: u64,
    quiet_ms: u64,
    tasks: []const Task,
    events: []const TaskLog.Event,
) Snap {
    var snap: Snap = .{
        .tasks = tasks.len,
        .quiet_ms = quiet_ms,
        .mark_ms = mark_ms,
    };

    for (tasks) |t| {
        switch (t.state) {
            .closed => {
                snap.closed += 1;
                continue;
            },
            .cancelled => {
                snap.cancelled += 1;
                continue;
            },
            .open => snap.open += 1,
        }

        var last: ?i64 = null;
        for (events) |e| {
            if (e.task != t.id) continue;
            if (last == null or e.at_ms > last.?) last = e.at_ms;
        }

        // A task with nothing in the record is not counted as idle: the
        // record may simply not reach back that far, and a snapshot that
        // rounded "unknown" up to "past the mark" would be a fact about
        // the log dressed as a fact about the night.
        const touched = last orelse continue;
        const silent: u64 = @intCast(@max(now_ms - touched, 0));
        if (silent > snap.idlest_ms) snap.idlest_ms = silent;
        if (mark_ms > 0 and silent >= mark_ms) snap.over += 1;
    }

    return snap;
}

pub fn open(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!StatsLog {
    const dir = try std.fs.path.join(alloc, &.{ state_dir, "stats" });
    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .tree = .{
            .alloc = alloc,
            .io = io,
            .dir = dir,
            .label = "stats log",

            // Nothing here carries a sequence number: a line is identified
            // by its group and its hour. Null is the honest answer and
            // `head` is never asked.
            .probe = null,
        },
    };
}

pub fn deinit(self: *StatsLog) void {
    var it = self.last.keyIterator();
    while (it.next()) |k| self.alloc.free(k.*);
    self.last.deinit(self.alloc);

    self.tree.deinit();
    self.alloc.free(self.dir);
    self.* = undefined;
}

/// Whether `group` is due a line at `at_ms`.
///
/// Asked separately from writing one so the caller does not gather figures
/// it is about to throw away: working out a snapshot means reading the
/// panel's record off disk.
pub fn due(self: *const StatsLog, group: []const u8, at_ms: i64) bool {
    const last = self.last.get(group) orelse return true;
    return at_ms -| last >= every_ms;
}

/// Write one line, and remember that this group has had one.
///
/// The clock is advanced whatever the write does, because a disk that will
/// not take this line will not take the next one either, and retrying every
/// five minutes for the rest of the night buys nothing.
pub fn append(self: *StatsLog, at_ms: i64, group: []const u8, snap: Snap) void {
    self.remember(group, at_ms);

    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();

    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    render(&s, at_ms, group, snap) catch |err| {
        log.warn("stats log: could not render err={}", .{err});
        return;
    };
    buf.writer.writeByte('\n') catch return;

    self.tree.write(group, at_ms, buf.written());
}

fn remember(self: *StatsLog, group: []const u8, at_ms: i64) void {
    if (self.last.getPtr(group)) |v| {
        v.* = at_ms;
        return;
    }

    // Its own copy of the name: the caller's belongs to the chat, and a
    // group that is destroyed while this holds a key would leave a map
    // keyed on freed bytes.
    const owned = self.alloc.dupe(u8, group) catch return;
    self.last.put(self.alloc, owned, at_ms) catch self.alloc.free(owned);
}

fn render(
    s: *std.json.Stringify,
    at_ms: i64,
    group: []const u8,
    snap: Snap,
) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("at_ms");
    try s.write(at_ms);
    try s.objectField("group");
    try s.write(group);
    try s.objectField("tasks");
    try s.write(snap.tasks);
    try s.objectField("open");
    try s.write(snap.open);
    try s.objectField("closed");
    try s.write(snap.closed);
    try s.objectField("cancelled");
    try s.write(snap.cancelled);
    try s.objectField("over");
    try s.write(snap.over);
    try s.objectField("quiet_ms");
    try s.write(snap.quiet_ms);
    try s.objectField("idlest_ms");
    try s.write(snap.idlest_ms);
    try s.objectField("mark_ms");
    try s.write(snap.mark_ms);
    try s.endObject();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn testDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-statslog-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn readAll(alloc: Allocator, io: std.Io, l: *StatsLog, group: []const u8) ![]u8 {
    var days = try l.tree.days(alloc, group);
    defer days.deinit(alloc);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (days.items) |d| {
        const path = try l.tree.partPath(alloc, group, d.day, d.part);
        defer alloc.free(path);

        const bytes = try std.Io.Dir.readFileAlloc(
            .cwd(),
            io,
            path,
            alloc,
            .limited(1024 * 1024),
        );
        defer alloc.free(bytes);
        try out.appendSlice(alloc, bytes);
    }
    return out.toOwnedSlice(alloc);
}

test "an hour is written down once" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    var l = try StatsLog.open(alloc, io, dir);
    defer l.deinit();

    const at: i64 = 1_700_000_000_000;

    // Nothing written yet, so the first hour is due.
    try testing.expect(l.due("build", at));
    l.append(at, "build", .{ .tasks = 71, .open = 11, .closed = 60, .over = 2 });

    // And not again until the hour is up.
    try testing.expect(!l.due("build", at + 60_000));
    try testing.expect(!l.due("build", at + every_ms - 1));
    try testing.expect(l.due("build", at + every_ms));

    // Another group keeps its own clock.
    try testing.expect(l.due("ops", at));

    const body = try readAll(alloc, io, &l, "build");
    defer alloc.free(body);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\n"));
    try testing.expect(std.mem.indexOf(u8, body, "\"tasks\":71") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"open\":11") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"over\":2") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"group\":\"build\"") != null);
}

test "the mark is written beside the count it explains" {
    // Without it, "two had gone past the mark" is unreadable a week later
    // when the setting has been changed: the number would be about a
    // threshold nothing recorded.
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    var l = try StatsLog.open(alloc, io, dir);
    defer l.deinit();

    l.append(1_700_000_000_000, "build", .{
        .over = 2,
        .mark_ms = 12 * 60 * 60 * 1000,
        .idlest_ms = 49 * 60 * 60 * 1000,
    });

    const body = try readAll(alloc, io, &l, "build");
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"mark_ms\":43200000") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"idlest_ms\":176400000") != null);
}

test "a snapshot counts what is there and leaves what is unknown alone" {
    const hour: i64 = 60 * 60 * 1000;
    const events = [_]TaskLog.Event{
        .{ .seq = 1, .at_ms = 50 * hour, .op = "assigned", .task = 1, .title = "a", .owner = 0x2222, .state = "open", .progress = "queued" },
        .{ .seq = 2, .at_ms = 99 * hour, .op = "progressed", .task = 2, .title = "b", .owner = 0x2222, .state = "open", .progress = "working" },
    };
    const tasks = [_]Task{
        .{ .id = 1, .state = .open },
        .{ .id = 2, .state = .open },

        // Open, and with nothing in the record: not counted as idle.
        .{ .id = 3, .state = .open },
        .{ .id = 4, .state = .closed },
        .{ .id = 5, .state = .cancelled },
    };

    const snap = summarise(100 * hour, 12 * 60 * 60 * 1000, 90 * 60 * 1000, &tasks, &events);

    try testing.expectEqual(@as(usize, 5), snap.tasks);
    try testing.expectEqual(@as(usize, 3), snap.open);
    try testing.expectEqual(@as(usize, 1), snap.closed);
    try testing.expectEqual(@as(usize, 1), snap.cancelled);

    // Task 1 only: task 2 moved an hour ago and task 3 is unknown.
    try testing.expectEqual(@as(usize, 1), snap.over);
    try testing.expectEqual(@as(u64, 50 * 60 * 60 * 1000), snap.idlest_ms);
    try testing.expectEqual(@as(u64, 90 * 60 * 1000), snap.quiet_ms);
}

test "a group whose name is not a directory name still round-trips" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    var l = try StatsLog.open(alloc, io, dir);
    defer l.deinit();

    l.append(1_700_000_000_000, "a/b", .{ .tasks = 1 });

    const body = try readAll(alloc, io, &l, "a/b");
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"group\":\"a/b\"") != null);
}
