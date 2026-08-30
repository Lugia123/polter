//! The panel, written down so it is still there in the morning.
//!
//! Leaving the terminals to work overnight is the entire reason the panel
//! exists, and a blank panel at nine the next morning is the same as no
//! panel at all. So it is on disk.
//!
//! **The shape is `daylog.Tree`, which is the shape already here.** One
//! directory per group, one file per local day, one JSON object per line --
//! the same layout `ChatLog`'s record half and the terminal transcript use,
//! under `<state>/tasks` beside `<state>/chat` and `<state>/terminals`.
//! Inventing a third layout was the specific thing `docs/poltergeist/gaps.md`
//! warns about: one state directory holding two rules that disagree about
//! where a given name's files go. The encoding of a group name into a
//! directory name is decided in exactly one place and this is not it.
//!
//! What a line holds is this file's own business, and it is an **event**,
//! not a row: created, assigned, progressed, closed, cancelled. Events
//! rather than snapshots because the record is append-only -- nothing in a
//! `daylog` tree is ever rewritten or moved aside -- so the way to say a
//! task changed is to write that it changed. Replaying them in order at
//! startup rebuilds the panel, and the file doubles as the answer to "what
//! actually happened last night", which a table of final states cannot give.
//!
//! Failure is a warning and nothing else, the same as the chat record: not
//! being able to write tonight's notes is not a reason to stop the
//! terminals working tonight.

const TaskLog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");
const Tasks = @import("Tasks.zig");

const log = std.log.scoped(.poltergeist);

/// The most one day file this will read back at startup.
///
/// A ceiling rather than a promise: a task event is under two hundred
/// bytes, so this is hundreds of thousands of them in one group on one day,
/// and past that the restore is the wrong tool anyway.
const max_replay_bytes: usize = 8 * 1024 * 1024;

alloc: Allocator,
io: std.Io,

/// Owned: the tree borrows it.
dir: []const u8,

tree: daylog.Tree,

/// What one line says happened.
///
/// Five, matching the five things the panel can be told. There is no
/// "edited": a title that was wrong is a task that gets cancelled and one
/// that gets made, which is also what the worker needs to hear.
pub const Op = enum {
    created,
    assigned,
    progressed,
    closed,
    cancelled,
};

/// Open the record under a state directory, making it if it is not there.
pub fn open(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!TaskLog {
    const dir = try std.fs.path.join(alloc, &.{ state_dir, "tasks" });
    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .tree = .{
            .alloc = alloc,
            .io = io,
            .dir = dir,
            .label = "task log",

            // Nothing here carries a sequence number: the task's own id is
            // the identity, and it is written on every line. Null is the
            // honest answer and `head` is never asked.
            .probe = null,
        },
    };
}

pub fn deinit(self: *TaskLog) void {
    self.tree.deinit();
    self.alloc.free(self.dir);
    self.* = undefined;
}

/// Record one thing that happened to one task.
///
/// Everything about the task goes on every line, not just the field that
/// moved. It costs a few dozen bytes and it buys a replay that cannot be
/// wrong: a line that lands in a file whose earlier lines were lost --
/// which the record explicitly tolerates, see `daylog` -- still says what
/// the task is called and who has it.
pub fn append(self: *TaskLog, at_ms: i64, op: Op, task: Tasks.Task) void {
    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();

    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    render(&s, at_ms, op, task) catch |err| {
        log.warn("task log: could not render err={}", .{err});
        return;
    };
    buf.writer.writeByte('\n') catch return;

    self.tree.write(task.group, at_ms, buf.written());
}

fn render(
    s: *std.json.Stringify,
    at_ms: i64,
    op: Op,
    task: Tasks.Task,
) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("at_ms");
    try s.write(at_ms);
    try s.objectField("op");
    try s.write(@tagName(op));
    try s.objectField("task");
    try s.write(task.id);
    try s.objectField("group");
    try s.write(task.group);
    try s.objectField("title");
    try s.write(task.title);

    // As the same `0x…` text every other id in this system is written in,
    // so one reader parses them all.
    var idbuf: [18]u8 = undefined;
    try s.objectField("owner");
    try s.write(std.fmt.bufPrint(&idbuf, "0x{x:0>16}", .{task.owner}) catch unreachable);

    try s.objectField("state");
    try s.write(@tagName(task.state));
    try s.objectField("progress");
    try s.write(@tagName(task.progress));
    try s.endObject();
}

/// Rebuild the panel out of the record.
///
/// Every group's directory, oldest day first, every line in order. A line
/// that will not parse is skipped rather than fatal: a torn tail is a
/// normal way for a record to end, and a panel short by one task beats no
/// panel at all.
pub fn restore(self: *TaskLog, tasks: *Tasks) void {
    var d = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch return;
    defer d.close(self.io);

    var it = d.iterate();
    while (it.next(self.io) catch null) |entry| {
        // `readdir` reports `unknown` on some filesystems.
        const kind = if (entry.kind != .unknown) entry.kind else k: {
            const st = d.statFile(self.io, entry.name, .{
                .follow_symlinks = false,
            }) catch continue;
            break :k st.kind;
        };
        if (kind != .directory) continue;

        const seg = self.alloc.dupe(u8, entry.name) catch continue;
        defer self.alloc.free(seg);
        self.restoreGroup(tasks, seg);
    }
}

fn restoreGroup(self: *TaskLog, tasks: *Tasks, seg: []const u8) void {
    var days = self.tree.daysIn(self.alloc, seg) catch return;
    defer days.deinit(self.alloc);

    // `daysIn` sorts newest first, which is the direction paging back
    // wants and the wrong one for a replay: an event only means anything
    // after the ones before it.
    std.mem.reverse(daylog.Tree.DayFile, days.items);

    for (days.items) |day| {
        const path = self.tree.partPathIn(self.alloc, seg, day.day, day.part) catch continue;
        defer self.alloc.free(path);

        const bytes = std.Io.Dir.readFileAlloc(
            .cwd(),
            self.io,
            path,
            self.alloc,
            .limited(max_replay_bytes),
        ) catch continue;
        defer self.alloc.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            self.applyLine(tasks, line);
        }
    }
}

fn applyLine(self: *TaskLog, tasks: *Tasks, line: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        line,
        .{},
    ) catch return;

    const obj = switch (parsed) {
        .object => |o| o,
        else => return,
    };

    const id: Tasks.TaskId = switch (obj.get("task") orelse return) {
        .integer => |n| if (n < 0) return else @intCast(n),
        else => return,
    };

    const group = str(obj, "group") orelse return;
    const title = str(obj, "title") orelse return;

    const owner: Tasks.Id = if (str(obj, "owner")) |t|
        std.fmt.parseUnsigned(Tasks.Id, t, 0) catch Tasks.nobody
    else
        Tasks.nobody;

    const state = std.meta.stringToEnum(
        Tasks.State,
        str(obj, "state") orelse "open",
    ) orelse .open;

    const progress = std.meta.stringToEnum(
        Tasks.Progress,
        str(obj, "progress") orelse "queued",
    ) orelse .queued;

    // Every line carries the whole task, so applying one is the same
    // operation whichever `op` it was: put the task where this line says
    // it was. Later lines overwrite earlier ones, which is what "in order"
    // means when the state is carried rather than derived.
    if (tasks.get(id) != null) {
        tasks.assign(id, owner) catch {};
        tasks.setProgress(id, owner, progress) catch {};
        switch (state) {
            .open => {},
            .closed => tasks.close(id) catch {},
            .cancelled => tasks.cancel(id) catch {},
        }
        return;
    }

    tasks.restore(.{
        .id = id,
        .group = group,
        .title = title,
        .owner = owner,
        .state = state,
        .progress = progress,
    }) catch {};
}

fn str(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |v| v,
        else => null,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn testDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-tasklog-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "the panel comes back after a restart" {
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
        var tasks: Tasks = .init(alloc, .{});
        defer tasks.deinit();
        var l = try TaskLog.open(alloc, io, dir);
        defer l.deinit();

        const one = try tasks.create("build", "get the core building");
        l.append(at, .created, tasks.get(one).?);
        try tasks.assign(one, 0x2222);
        l.append(at, .assigned, tasks.get(one).?);
        try tasks.setProgress(one, 0x2222, .working);
        l.append(at, .progressed, tasks.get(one).?);

        const two = try tasks.create("build", "and the docs");
        l.append(at, .created, tasks.get(two).?);
        try tasks.close(two);
        l.append(at, .closed, tasks.get(two).?);

        const three = try tasks.create("ops", "watch the deploy");
        l.append(at, .created, tasks.get(three).?);
    }

    var tasks: Tasks = .init(alloc, .{});
    defer tasks.deinit();
    var l = try TaskLog.open(alloc, io, dir);
    defer l.deinit();
    l.restore(&tasks);

    const build = try tasks.inGroup(alloc, "build");
    defer alloc.free(build);
    try testing.expectEqual(@as(usize, 2), build.len);

    try testing.expectEqualStrings("get the core building", build[0].title);
    try testing.expectEqual(@as(Tasks.Id, 0x2222), build[0].owner);
    try testing.expectEqual(Tasks.Progress.working, build[0].progress);
    try testing.expectEqual(Tasks.State.open, build[0].state);

    try testing.expectEqual(Tasks.State.closed, build[1].state);

    const ops = try tasks.inGroup(alloc, "ops");
    defer alloc.free(ops);
    try testing.expectEqual(@as(usize, 1), ops.len);

    // And a fresh task does not land on a number the record already used.
    try testing.expect(try tasks.create("build", "new") > 3);
}

test "a cancelled task comes back cancelled, not open" {
    // The failure this guards is quiet and specific: a cancellation that
    // did not survive the restart would put the task back in front of the
    // worker in the morning, which is the silent state change the whole
    // cancel path exists to avoid, arriving by another road.
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    {
        var tasks: Tasks = .init(alloc, .{});
        defer tasks.deinit();
        var l = try TaskLog.open(alloc, io, dir);
        defer l.deinit();

        const id = try tasks.create("build", "never mind");
        l.append(1_700_000_000_000, .created, tasks.get(id).?);
        try tasks.assign(id, 0x2222);
        l.append(1_700_000_000_000, .assigned, tasks.get(id).?);
        try tasks.cancel(id);
        l.append(1_700_000_000_001, .cancelled, tasks.get(id).?);
    }

    var tasks: Tasks = .init(alloc, .{});
    defer tasks.deinit();
    var l = try TaskLog.open(alloc, io, dir);
    defer l.deinit();
    l.restore(&tasks);

    const build = try tasks.inGroup(alloc, "build");
    defer alloc.free(build);
    try testing.expectEqual(@as(usize, 1), build.len);
    try testing.expectEqual(Tasks.State.cancelled, build[0].state);

    // And it is not put back in front of its old worker.
    const worker = try tasks.forWorker(alloc, "build", 0x2222);
    defer alloc.free(worker);
    try testing.expectEqual(@as(usize, 0), worker.len);
}

test "a torn line is skipped rather than fatal" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    {
        var tasks: Tasks = .init(alloc, .{});
        defer tasks.deinit();
        var l = try TaskLog.open(alloc, io, dir);
        defer l.deinit();

        const id = try tasks.create("build", "kept");
        l.append(1_700_000_000_000, .created, tasks.get(id).?);

        // Half a line, the way a run that died mid-write leaves one.
        l.tree.write("build", 1_700_000_000_000, "{\"op\":\"crea\n");
    }

    var tasks: Tasks = .init(alloc, .{});
    defer tasks.deinit();
    var l = try TaskLog.open(alloc, io, dir);
    defer l.deinit();
    l.restore(&tasks);

    const build = try tasks.inGroup(alloc, "build");
    defer alloc.free(build);
    try testing.expectEqual(@as(usize, 1), build.len);
    try testing.expectEqualStrings("kept", build[0].title);
}

test "an empty record restores an empty panel" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    var tasks: Tasks = .init(alloc, .{});
    defer tasks.deinit();
    var l = try TaskLog.open(alloc, io, dir);
    defer l.deinit();
    l.restore(&tasks);

    const build = try tasks.inGroup(alloc, "build");
    defer alloc.free(build);
    try testing.expectEqual(@as(usize, 0), build.len);
}

test "a group whose name is not a directory name still round-trips" {
    // The reason this borrows `daylog` rather than joining paths itself.
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    {
        var tasks: Tasks = .init(alloc, .{});
        defer tasks.deinit();
        var l = try TaskLog.open(alloc, io, dir);
        defer l.deinit();

        const id = try tasks.create("a/b", "awkward");
        l.append(1_700_000_000_000, .created, tasks.get(id).?);
    }

    var tasks: Tasks = .init(alloc, .{});
    defer tasks.deinit();
    var l = try TaskLog.open(alloc, io, dir);
    defer l.deinit();
    l.restore(&tasks);

    const got = try tasks.inGroup(alloc, "a/b");
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, 1), got.len);
}
