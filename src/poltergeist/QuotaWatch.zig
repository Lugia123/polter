//! Where the allowance numbers come from, and the one thread that reads
//! them (`quota.zig` has what is made of them).
//!
//! Two sources, both files, both read here and nowhere on the app thread:
//!
//!   * **Claude Code**: `<state>/quota/claude.json`, left by `polter
//!     +statusline` each time a Claude Code that Polter started with a role
//!     refreshes its status line. A Claude Code the person started by hand
//!     has no such status line and leaves nothing; the last number stays
//!     and grows old.
//!   * **Codex**: its own session records, `$CODEX_HOME/sessions/YYYY/MM/DD/
//!     rollout-*.jsonl`, which carry the allowance on every `token_count`
//!     line. Read only, the newest few files of the newest few days, from
//!     the end backwards.
//!
//! **Neither says whose account it is**, so one family is one row: with two
//! accounts of one family the row is whichever was heard from last.
//!
//! **Not a timer.** `kick` is called when something happened in a
//! terminal; the thread waits a moment for the files to be written, reads,
//! and reads once more after `min_gap_ms` only if it was kicked again
//! meanwhile. With nothing happening it does not exist.

const QuotaWatch = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");
const daylog = @import("daylog.zig");
const quota = @import("quota.zig");
const ControlWake = @import("ControlWake.zig");

const log = std.log.scoped(.poltergeist);

/// How long after a kick the files are read: what was happening has to
/// have reached the disk.
pub const settle_ms: u64 = 1_500;

/// The least time between two reads while kicks keep coming.
pub const min_gap_ms: u64 = 15_000;

/// How much of the end of a Codex session record is read.
const tail_bytes: usize = 256 * 1024;

/// How many of the newest day directories, and of the newest records in
/// them, are looked at.
const days_read = 3;
const files_read = 5;

const families = std.enums.values(quota.Family).len;

alloc: Allocator,
io: Io,
/// Called on the reading thread when what was read differs from before.
fire: *const fn (ctx: *anyopaque) void,
ctx: *anyopaque,

mutex: Io.Mutex = .init,
last: [families]?quota.Reading = @splat(null),
running: bool = false,
again: bool = false,
stopping: bool = false,
thread: ?std.Thread = null,

/// What the thread sleeps on, so that `stop` does not wait out a gap.
generation: std.atomic.Value(u32) = .init(0),

/// How many times the files have been read, for the tests.
reads: std.atomic.Value(u64) = .init(0),

/// Where the files are, when a test says; otherwise the environment's.
dirs: ?Dirs = null,

pub const Dirs = struct {
    /// `<state>/quota`.
    drop: ?[]const u8,
    /// `$CODEX_HOME`, or `~/.codex`.
    codex: ?[]const u8,
};

/// Read soon, unless a read is already on its way -- and then once more
/// after it. **The app thread only**, for the reason `agent_cli.Cache.
/// refresh` gives.
pub fn kick(self: *QuotaWatch) void {
    self.mutex.lockUncancelable(self.io);
    if (self.stopping) {
        self.mutex.unlock(self.io);
        return;
    }
    if (self.running) {
        self.again = true;
        self.mutex.unlock(self.io);
        return;
    }
    self.running = true;
    const previous = self.thread;
    self.thread = null;
    self.mutex.unlock(self.io);

    if (previous) |t| t.join();

    const t = std.Thread.spawn(.{}, work, .{self}) catch |err| {
        log.warn("quota: could not start the reading thread err={}", .{err});
        self.mutex.lockUncancelable(self.io);
        self.running = false;
        self.mutex.unlock(self.io);
        return;
    };
    self.mutex.lockUncancelable(self.io);
    self.thread = t;
    self.mutex.unlock(self.io);
}

pub fn stop(self: *QuotaWatch) void {
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    const t = self.thread;
    self.thread = null;
    self.mutex.unlock(self.io);
    _ = self.generation.fetchAdd(1, .release);
    self.io.futexWake(u32, &self.generation.raw, 1);
    if (t) |thread| thread.join();
}

/// What was last read, one to a family at most, into `buf`.
pub fn readings(self: *QuotaWatch, buf: *[families]quota.Reading) []const quota.Reading {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var n: usize = 0;
    for (self.last) |maybe| if (maybe) |r| {
        buf[n] = r;
        n += 1;
    };
    return buf[0..n];
}

/// Sleep, unless told to stop. False when stopping.
fn pause(self: *QuotaWatch, ms: u64) bool {
    const seen = self.generation.load(.acquire);
    self.mutex.lockUncancelable(self.io);
    const stopping = self.stopping;
    self.mutex.unlock(self.io);
    if (stopping) return false;
    self.io.futexWaitTimeout(u32, &self.generation.raw, seen, .{
        .duration = .{
            // Through the same clamp the control room's wake uses: `ms` is a
            // setting today, and this must not be the line that finds out when
            // it stops being one.
            .raw = .fromMilliseconds(ControlWake.waitMs(ms, 0)),
            .clock = .awake,
        },
    }) catch return false;
    return self.generation.load(.acquire) == seen;
}

fn work(self: *QuotaWatch) void {
    var wait = settle_ms;
    while (true) {
        if (!self.pause(wait)) break;

        const fresh = self.readAll();
        _ = self.reads.fetchAdd(1, .monotonic);

        self.mutex.lockUncancelable(self.io);
        const changed = !std.meta.eql(fresh, self.last);
        self.last = fresh;
        const more = self.again;
        self.again = false;
        self.mutex.unlock(self.io);

        if (changed) self.fire(self.ctx);
        if (!more) break;
        wait = min_gap_ms;
    }

    self.mutex.lockUncancelable(self.io);
    self.running = false;
    self.mutex.unlock(self.io);
}

fn readAll(self: *QuotaWatch) [families]?quota.Reading {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const dirs: Dirs = self.dirs orelse blk: {
        var env = global.environMap() catch break :blk .{ .drop = null, .codex = null };
        // Not freed before the paths made from it are used: they are the
        // arena's.
        defer env.deinit();
        break :blk .{
            .drop = dropDir(aa, self.io, &env) catch null,
            .codex = codexHome(aa, &env) catch null,
        };
    };

    const now_ms: u64 = @intCast(@max(0, daylog.nowMs(self.io)));
    var out: [families]?quota.Reading = @splat(null);
    if (dirs.drop) |d| out[@intFromEnum(quota.Family.claude)] = readClaude(aa, self.io, d);
    if (dirs.codex) |d| out[@intFromEnum(quota.Family.codex)] = readCodex(aa, self.io, d, now_ms);
    return out;
}

// -- the files --------------------------------------------------------------

/// `<state>/quota`, in `alloc`.
pub fn dropDir(alloc: Allocator, io: Io, env: *const std.process.Environ.Map) ![]u8 {
    const state = try internal_os.xdg.state(io, alloc, env, .{ .subdir = "polter" });
    defer alloc.free(state);
    return std.fs.path.join(alloc, &.{ state, "quota" });
}

fn codexHome(alloc: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("CODEX_HOME")) |h| if (h.len > 0) return alloc.dupe(u8, h);
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".codex" });
}

fn dropName(family: quota.Family) []const u8 {
    return switch (family) {
        .claude => "claude.json",
        .codex => "codex.json",
    };
}

/// Leave one family's windows in `dir` for the app to read. Whole or not
/// at all: a status line is cut off mid-write as a matter of course.
///
/// The same windows again within a minute are not written again; a status
/// line refreshes several times a second while an agent is talking.
pub fn writeDrop(
    aa: Allocator,
    io: Io,
    dir: []const u8,
    family: quota.Family,
    windows: [quota.max_windows]?quota.Window,
    now_ms: u64,
) !void {
    if (readDrop(aa, io, dir, family)) |old| {
        if (old.state == .have and std.meta.eql(old.windows, windows) and
            now_ms -| old.at_ms < std.time.ms_per_min) return;
    }

    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try quota.writeDrop(&w, windows, now_ms);

    var atomic = try d.createFileAtomic(io, dropName(family), .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, w.buffered());
    try atomic.replace(io);
}

fn readDrop(arena: Allocator, io: Io, dir: []const u8, family: quota.Family) ?quota.Reading {
    const path = std.fs.path.join(arena, &.{ dir, dropName(family) }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        // Never written: nothing is known, which is not a failure to read.
        error.FileNotFound => return null,
        else => return .unreadable(family, 0),
    };
    return quota.readDrop(arena, family, bytes) orelse .unreadable(family, 0);
}

/// What `+statusline` last left, or null when it never left anything.
pub fn readClaude(arena: Allocator, io: Io, dir: []const u8) ?quota.Reading {
    return readDrop(arena, io, dir, .claude);
}

fn allDigits(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn descending(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .gt;
}

/// The names in `path` that are all digits, largest first. Null when the
/// directory is not there; an error when it is and cannot be listed.
fn numbered(arena: Allocator, io: Io, path: []const u8) !?[]const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !allDigits(entry.name)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, descending);
    return names.items;
}

const Record = struct {
    path: []const u8,
    mtime: i96,

    fn newer(_: void, a: Record, b: Record) bool {
        return a.mtime > b.mtime;
    }
};

/// The session records in one day's directory.
fn recordsIn(arena: Allocator, io: Io, path: []const u8, out: *std.ArrayListUnmanaged(Record)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "rollout-") or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        try out.append(arena, .{
            .path = try std.fs.path.join(arena, &.{ path, entry.name }),
            .mtime = st.mtime.nanoseconds,
        });
    }
}

/// The newest allowance line in the end of one session record.
fn lastIn(arena: Allocator, io: Io, path: []const u8) !?quota.CodexLine {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const end = (try file.stat(io)).size;
    const want: usize = @intCast(@min(end, tail_bytes));
    const buf = try arena.alloc(u8, want);
    const n = try file.readPositionalAll(io, buf, end - want);

    // Backwards, and the first that reads. The first line of the window is
    // very likely the back half of one; it does not parse and is passed
    // over like any other line that is not the one wanted.
    var lines = std.mem.splitBackwardsScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (quota.fromCodexLine(arena, line)) |got| return got;
    }
    return null;
}

/// Codex's allowance as its newest session record has it. Null when Codex
/// has never run here, or has only ever run on an account that pays by the
/// token.
pub fn readCodex(arena: Allocator, io: Io, codex_home: []const u8, now_ms: u64) ?quota.Reading {
    return readCodexInner(arena, io, codex_home) catch |err| {
        log.warn("quota: Codex's session records could not be read err={}", .{err});
        return .unreadable(.codex, now_ms);
    };
}

fn readCodexInner(arena: Allocator, io: Io, codex_home: []const u8) !?quota.Reading {
    const sessions = try std.fs.path.join(arena, &.{ codex_home, "sessions" });
    var records: std.ArrayListUnmanaged(Record) = .empty;
    var days: usize = 0;

    const years = (try numbered(arena, io, sessions)) orelse return null;
    walk: for (years) |y| {
        const year = try std.fs.path.join(arena, &.{ sessions, y });
        for ((try numbered(arena, io, year)) orelse continue) |m| {
            const month = try std.fs.path.join(arena, &.{ year, m });
            for ((try numbered(arena, io, month)) orelse continue) |d| {
                const before = records.items.len;
                try recordsIn(arena, io, try std.fs.path.join(arena, &.{ month, d }), &records);
                if (records.items.len > before) days += 1;
                if (days == days_read) break :walk;
            }
        }
    }
    if (records.items.len == 0) return null;
    std.mem.sort(Record, records.items, {}, Record.newer);

    var best: ?quota.CodexLine = null;
    var failed: usize = 0;
    const look = records.items[0..@min(records.items.len, files_read)];
    for (look) |r| {
        const got = lastIn(arena, io, r.path) catch {
            failed += 1;
            continue;
        } orelse continue;
        if (best == null or got.at_ms > best.?.at_ms) best = got;
    }
    if (best) |b| return .{ .family = .codex, .state = .have, .windows = b.windows, .at_ms = b.at_ms };
    if (failed == look.len) return error.NoRecordCouldBeRead;
    return null;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const Rig = struct {
    threaded: Io.Threaded,
    root: []u8,

    fn init(self: *Rig) !void {
        self.threaded = .init(testing.allocator, .{});
        var raw: [6]u8 = undefined;
        self.threaded.io().random(&raw);
        self.root = try std.fmt.allocPrint(testing.allocator, "/tmp/polter-quota-{x}", .{&raw});
        try std.Io.Dir.cwd().createDirPath(self.threaded.io(), self.root);
    }

    fn deinit(self: *Rig) void {
        std.Io.Dir.cwd().deleteTree(self.threaded.io(), self.root) catch {};
        testing.allocator.free(self.root);
        self.threaded.deinit();
    }

    fn write(self: *Rig, arena: Allocator, rel: []const u8, data: []const u8) !void {
        const io = self.threaded.io();
        const path = try std.fs.path.join(arena, &.{ self.root, rel });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, data);
    }
};

fn codexLine(comptime stamp: []const u8, comptime used: []const u8) []const u8 {
    return "{\"timestamp\":\"" ++ stamp ++ "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null," ++
        "\"rate_limits\":{\"primary\":{\"used_percent\":" ++ used ++ ",\"window_minutes\":300,\"resets_at\":1700003600},\"secondary\":null}}}\n";
}

const other_line = "{\"timestamp\":\"2023-11-14T22:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}\n";

test "QuotaWatch codex: the newest allowance line of the newest records, read from the end" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = rig.threaded.io();

    try rig.write(aa, "sessions/2023/11/13/rollout-a.jsonl", comptime codexLine("2023-11-13T10:00:00.000Z", "55.0"));
    try rig.write(aa, "sessions/2023/11/14/rollout-b.jsonl", comptime (other_line ++
        codexLine("2023-11-14T22:00:00.000Z", "10.0") ++ other_line ++
        codexLine("2023-11-14T22:13:20.000Z", "20.5") ++ other_line ++ "{\"torn"));
    try rig.write(aa, "sessions/2023/11/14/notes.txt", "not a record");

    const got = readCodex(aa, io, rig.root, 5).?;
    const state = got.state;
    try testing.expectEqual(quota.Reading.State.have, state);
    const used = got.windows[0].?.used;
    try testing.expectEqual(@as(u8, 20), used);
    try testing.expectEqual(@as(u64, 1_700_000_000_000), got.at_ms);
}

test "QuotaWatch codex: never run here is nothing known, and records with no allowance in them likewise" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = rig.threaded.io();

    const never = readCodex(aa, io, rig.root, 5);
    try testing.expect(never == null);

    try rig.write(aa, "sessions/2023/11/14/rollout-b.jsonl", other_line ++ other_line);
    const nothing = readCodex(aa, io, rig.root, 5);
    try testing.expect(nothing == null);
}

test "QuotaWatch codex: records that are there and cannot be read are unreadable, not absent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = rig.threaded.io();

    // `sessions` is a file where a directory should be.
    try rig.write(aa, "sessions", "x");
    const got = readCodex(aa, io, rig.root, 5).?;
    const state = got.state;
    try testing.expectEqual(quota.Reading.State.unreadable, state);
}

test "QuotaWatch claude: nothing left is nothing known; something left that does not read is unreadable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = rig.threaded.io();

    const never = readClaude(aa, io, rig.root);
    try testing.expect(never == null);

    const w: quota.Window = .{ .span = .five_hour, .used = 61, .resets_ms = 1_700_003_600_000 };
    try writeDrop(aa, io, rig.root, .claude, .{ w, null }, 1_700_000_000_000);
    const got = readClaude(aa, io, rig.root).?;
    try testing.expectEqual(@as(?quota.Window, w), got.windows[0]);

    // The same again inside a minute is not written again; a new number is.
    try writeDrop(aa, io, rig.root, .claude, .{ w, null }, 1_700_000_030_000);
    const kept = readClaude(aa, io, rig.root).?.at_ms;
    try testing.expectEqual(@as(u64, 1_700_000_000_000), kept);
    var more = w;
    more.used = 62;
    try writeDrop(aa, io, rig.root, .claude, .{ more, null }, 1_700_000_030_000);
    const moved = readClaude(aa, io, rig.root).?.at_ms;
    try testing.expectEqual(@as(u64, 1_700_000_030_000), moved);

    try rig.write(aa, "claude.json", "{ torn");
    const torn = readClaude(aa, io, rig.root).?.state;
    try testing.expectEqual(quota.Reading.State.unreadable, torn);
}

const Fired = struct {
    n: std.atomic.Value(u32) = .init(0),

    fn fire(ctx: *anyopaque) void {
        const self: *Fired = @ptrCast(@alignCast(ctx));
        _ = self.n.fetchAdd(1, .monotonic);
    }
};

test "QuotaWatch: a kick reads once and says so only when what it read is new" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = rig.threaded.io();

    const w: quota.Window = .{ .span = .five_hour, .used = 61, .resets_ms = 1_700_003_600_000 };
    try writeDrop(aa, io, rig.root, .claude, .{ w, null }, 1_700_000_000_000);

    var fired: Fired = .{};
    var watch: QuotaWatch = .{
        .alloc = testing.allocator,
        .io = io,
        .fire = Fired.fire,
        .ctx = &fired,
        .dirs = .{ .drop = rig.root, .codex = rig.root },
    };
    defer watch.stop();

    var buf: [families]quota.Reading = undefined;
    try testing.expectEqual(@as(usize, 0), watch.readings(&buf).len);

    watch.kick();
    var waited: u64 = 0;
    while (watch.reads.load(.monotonic) < 1) : (waited += 20) {
        if (waited > 10_000) return error.TestNeverRead;
        try Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    try Io.sleep(io, .fromMilliseconds(50), .awake);
    const got = watch.readings(&buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u8, 61), got[0].windows[0].?.used);
    const first = fired.n.load(.monotonic);
    try testing.expectEqual(@as(u32, 1), first);

    // The same files again: read, and nobody told.
    watch.kick();
    waited = 0;
    while (watch.reads.load(.monotonic) < 2) : (waited += 20) {
        if (waited > 10_000) return error.TestNeverRead;
        try Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    try Io.sleep(io, .fromMilliseconds(50), .awake);
    const second = fired.n.load(.monotonic);
    try testing.expectEqual(@as(u32, 1), second);
}
