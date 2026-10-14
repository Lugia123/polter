//! Keeping what goes round to its limits: once when Polter starts, then
//! every hour, on a thread of its own (task 1511).
//!
//! The rule is `Retention.plan`; this is the part that touches the disk --
//! lists the files of each kind, says which are live, deletes what the rule
//! chose. Run by the application only. A command Polter runs (`+hook`,
//! `+mcp`, `+chat`) never sweeps: there are many of them at once, and two
//! sweeps deciding about the same files at the same moment is how a file
//! somebody else is about to read disappears.
//!
//! **What is never touched here**: the chat record and its stream, the task
//! record, the session record and group shells (kept for ever, cleared
//! only by hand), projects, and anything in a directory this does not
//! recognise by name. A name this does not recognise is not ours.

const Sweeper = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const daylog = @import("daylog.zig");
const Records = @import("Records.zig");
const Retention = @import("Retention.zig");
const SessionLog = @import("SessionLog.zig");
const TerminalMeta = @import("TerminalMeta.zig");

const log = std.log.scoped(.poltergeist);

/// How long between two sweeps.
pub const every_ms: u64 = 60 * 60 * 1000;

/// How long a group's rename backup is kept. Not a setting: the backup is
/// for finishing a rename that a crash interrupted, which happens at the
/// next start or not at all.
pub const rename_backup_days: u32 = 7;

/// What a sweep is told. Strings belong to whoever made it.
pub const Settings = struct {
    state_dir: []const u8,
    /// Where screenshots are, as the host says; null when it has not said,
    /// and then screenshots are left alone.
    shots_dir: ?[]const u8 = null,
    logs: Retention.Limits,
    shots: Retention.Limits,
    /// Transcripts by tier.
    group: Retention.Limits,
    project: Retention.Limits,
    other: Retention.Limits,
};

/// What one sweep did, or -- with `delete` false -- would have done.
pub const Report = struct {
    files: usize = 0,
    bytes: u64 = 0,
    dirs: usize = 0,
    /// False: work out what would go, and touch nothing.
    delete: bool = true,
    /// Set when the sweep was held back for the person to agree to: how
    /// much it would have deleted. Nothing was deleted.
    held_bytes: ?u64 = null,
};

/// Past this, the first sweep there has ever been waits for the person.
///
/// **Why there is a first sweep to ask about.** The rules came with an
/// upgrade, after the records had been growing with none: a machine that
/// has been used for a month starts with hundreds of megabytes the new
/// limits say should go (the development machine: 417MB of transcripts
/// from one month). That is what the person asked for, and still not
/// something to find out about afterwards. So the first sweep that would
/// delete more than this deletes nothing and says how much it would; it
/// goes ahead once the person has agreed, or has changed the limits.
/// Under it, it goes ahead and counts as agreed: the next one never asks.
pub const consent_threshold_bytes: u64 = 50 * 1024 * 1024;

/// Whether the person has agreed to sweeping, as far as the state directory
/// says: the file `consent_file` is there.
pub const consent_file = "retention-consent.json";

/// One sweep, now. `today` is the local day, as `daylog.dayOf` writes it;
/// `dayOf` turns a moment into one (tests pass a fixed one). Without
/// `consented`, a sweep over `consent_threshold_bytes` is only measured.
pub fn sweepOnce(alloc: Allocator, io: Io, s: Settings, today: u32, dayOf: Records.DayOf, consented: bool) Report {
    return sweepGated(alloc, io, s, today, dayOf, if (consented) null else consent_threshold_bytes);
}

/// `sweepOnce` with the threshold said: null sweeps whatever it comes to.
fn sweepGated(alloc: Allocator, io: Io, s: Settings, today: u32, dayOf: Records.DayOf, threshold: ?u64) Report {
    if (threshold) |limit| {
        var dry: Report = .{ .delete = false };
        pass(alloc, io, s, today, dayOf, &dry);
        if (dry.bytes > limit) return .{ .delete = false, .held_bytes = dry.bytes };
    }
    var r: Report = .{};
    pass(alloc, io, s, today, dayOf, &r);
    return r;
}

fn pass(alloc: Allocator, io: Io, s: Settings, today: u32, dayOf: Records.DayOf, r: *Report) void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    sweepTranscripts(a, io, s, today, dayOf, r) catch |err| log.warn("sweep: transcripts err={}", .{err});
    sweepLogs(a, io, s, today, dayOf, r) catch |err| log.warn("sweep: logs err={}", .{err});
    if (s.shots_dir) |dir| sweepShots(a, io, dir, s.shots, today, dayOf, r) catch |err| log.warn("sweep: screenshots err={}", .{err});
    sweepRenameBackups(a, io, s.state_dir, today, dayOf, r) catch |err| log.warn("sweep: rename backups err={}", .{err});
}

/// Whether `state_dir` holds the person's agreement.
pub fn hasConsent(io: Io, state_dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ state_dir, std.fs.path.sep, consent_file }) catch return false;
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Write the agreement down, with how it was given.
pub fn writeConsent(io: Io, state_dir: []const u8, at_ms: i64, how: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ state_dir, std.fs.path.sep, consent_file }) catch return;
    var f = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        log.warn("sweep: could not write the agreement err={}", .{err});
        return;
    };
    defer f.close(io);
    var line: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{{\"at_ms\":{d},\"how\":\"{s}\"}}\n", .{ at_ms, how }) catch return;
    f.writePositionalAll(io, text, 0) catch {};
}

/// A file the sweep might delete, with what the rule needs to know.
const Candidate = struct {
    path: []const u8,
    file: Retention.File,
};

fn deleteChosen(io: Io, files: []const Candidate, limits: Retention.Limits, today: u32, alloc: Allocator, r: *Report) !void {
    const plain = try alloc.alloc(Retention.File, files.len);
    for (files, 0..) |c, i| plain[i] = c.file;
    const chosen = try Retention.plan(alloc, plain, today, limits);
    for (chosen) |i| {
        if (r.delete) Io.Dir.cwd().deleteFile(io, files[i].path) catch continue;
        r.files += 1;
        r.bytes += files[i].file.bytes;
    }
}

fn sizeOf(io: Io, path: []const u8) ?Io.File.Stat {
    return Io.Dir.cwd().statFile(io, path, .{}) catch null;
}

fn dayOfStat(st: Io.File.Stat, dayOf: Records.DayOf) u32 {
    const ms: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms));
    return dayOf(ms);
}

/// The day files of one `daylog` directory, live one marked.
fn dayFilesIn(alloc: Allocator, io: Io, dir: []const u8, today: u32, out: *std.ArrayListUnmanaged(Candidate)) !usize {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    const first = out.items.len;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const df = daylog.TerminalTree.parseDayFile(e.name) orelse continue;
        const path = try std.fs.path.join(alloc, &.{ dir, e.name });
        const st = sizeOf(io, path) orelse continue;
        try out.append(alloc, .{ .path = path, .file = .{ .day = df.day, .part = df.part, .bytes = st.size } });
    }
    // Live: the newest part of today, which a writer may hold open.
    var newest: ?usize = null;
    for (out.items[first..], first..) |c, i| {
        if (c.file.day != today) continue;
        if (newest == null or c.file.part > out.items[newest.?].file.part) newest = i;
    }
    if (newest) |i| out.items[i].file.live = true;
    return out.items.len - first;
}

fn sweepTranscripts(a: Allocator, io: Io, s: Settings, today: u32, dayOf: Records.DayOf, r: *Report) !void {
    const root = try std.fs.path.join(a, &.{ s.state_dir, "terminals" });
    var d = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer d.close(io);

    const sessions = try SessionLog.read(a, io, s.state_dir);
    const notes = try TerminalMeta.read(a, io, s.state_dir);

    var tiers: [3]std.ArrayListUnmanaged(Candidate) = .{ .empty, .empty, .empty };
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    var ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var metas: std.ArrayListUnmanaged(struct { id: u64, path: []const u8 }) = .empty;

    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (TerminalMeta.idOfMetaFile(e.name)) |id| {
            try metas.append(a, .{ .id = id, .path = try std.fs.path.join(a, &.{ root, e.name }) });
            continue;
        }
        const id = TerminalMeta.idOfTranscriptDir(e.name) orelse continue;
        const dir = try std.fs.path.join(a, &.{ root, e.name });
        try dirs.append(a, dir);
        try ids.put(a, id, {});

        var files: std.ArrayListUnmanaged(Candidate) = .empty;
        _ = try dayFilesIn(a, io, dir, today, &files);
        const where = try Records.whereWas(a, id, sessions, notes, dayOf);
        for (files.items) |c| {
            const tier = Retention.tierOf(c.file.day, where.groups, where.projects);
            try tiers[@intFromEnum(tier)].append(a, c);
        }
    }

    try deleteChosen(io, tiers[@intFromEnum(Retention.Tier.group)].items, s.group, today, a, r);
    try deleteChosen(io, tiers[@intFromEnum(Retention.Tier.project)].items, s.project, today, a, r);
    try deleteChosen(io, tiers[@intFromEnum(Retention.Tier.none)].items, s.other, today, a, r);

    // A directory with nothing left in it goes; a terminal that is still
    // open makes it again at its next line.
    if (r.delete) for (dirs.items) |dir| {
        Io.Dir.cwd().deleteDir(io, dir) catch continue;
        r.dirs += 1;
    };

    // A terminal's notes go once its transcript has, and once nobody has
    // written them for a day -- a terminal that has not printed a line yet
    // has notes and no directory.
    if (r.delete) for (metas.items) |m| {
        var still = false;
        var di = d.iterate();
        while (di.next(io) catch null) |e| {
            if (TerminalMeta.idOfTranscriptDir(e.name)) |id| if (id == m.id) {
                still = true;
                break;
            };
        }
        if (still) continue;
        const st = sizeOf(io, m.path) orelse continue;
        if (Retention.ageInDays(dayOfStat(st, dayOf), today) < 1) continue;
        Io.Dir.cwd().deleteFile(io, m.path) catch continue;
        r.files += 1;
        r.bytes += st.size;
    };
}

fn sweepLogs(a: Allocator, io: Io, s: Settings, today: u32, dayOf: Records.DayOf, r: *Report) !void {
    var files: std.ArrayListUnmanaged(Candidate) = .empty;

    // The hourly snapshots: one directory per group.
    const stats = try std.fs.path.join(a, &.{ s.state_dir, "stats" });
    if (Io.Dir.cwd().openDir(io, stats, .{ .iterate = true })) |sd| {
        var d = sd;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            const dir = try std.fs.path.join(a, &.{ stats, e.name });
            _ = try dayFilesIn(a, io, dir, today, &files);
        }
    } else |_| {}

    // Crash reports: every file in the directory is one.
    try mtimeFiles(a, io, try std.fs.path.join(a, &.{ s.state_dir, "crash" }), dayOf, &files, struct {
        fn ours(name: []const u8) bool {
            return std.mem.endsWith(u8, name, ".ghosttycrash");
        }
    }.ours);

    // Plugins' older log generation. The current one is held open by the
    // running plugin's host and is bounded by its own rotation.
    try mtimeFiles(a, io, try std.fs.path.join(a, &.{ s.state_dir, "plugins" }), dayOf, &files, struct {
        fn ours(name: []const u8) bool {
            return std.mem.endsWith(u8, name, ".log.1");
        }
    }.ours);

    try deleteChosen(io, files.items, s.logs, today, a, r);
}

fn mtimeFiles(
    a: Allocator,
    io: Io,
    dir: []const u8,
    dayOf: Records.DayOf,
    out: *std.ArrayListUnmanaged(Candidate),
    comptime ours: fn ([]const u8) bool,
) !void {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory or !ours(e.name)) continue;
        const path = try std.fs.path.join(a, &.{ dir, e.name });
        const st = sizeOf(io, path) orelse continue;
        try out.append(a, .{ .path = path, .file = .{ .day = dayOfStat(st, dayOf), .bytes = st.size } });
    }
}

fn sweepShots(a: Allocator, io: Io, dir: []const u8, limits: Retention.Limits, today: u32, dayOf: Records.DayOf, r: *Report) !void {
    var files: std.ArrayListUnmanaged(Candidate) = .empty;
    try mtimeFiles(a, io, dir, dayOf, &files, isShot);
    try deleteChosen(io, files.items, limits, today, a, r);
}

/// A name Polter gave a screenshot, its sidecar or one of its tiles:
/// `YYYYMMDD-HHMMSS-mmm.png`, `.json`, or `…-N.png` with N of 1 to 3
/// digits. The same rule as the hosts' (`ShotStore.isOurs`,
/// `windows/shots` `sweep`), so a file the user put in the folder is
/// never ours to delete.
pub fn isShot(name: []const u8) bool {
    const png = std.mem.endsWith(u8, name, ".png");
    if (!png and !std.mem.endsWith(u8, name, ".json")) return false;
    const body = name[0 .. name.len - (if (png) @as(usize, 4) else 5)];
    const stem = 8 + 1 + 6 + 1 + 3;
    if (body.len < stem) return false;
    for (body[0..stem], 0..) |b, i| {
        if (i == 8 or i == 15) {
            if (b != '-') return false;
        } else if (!std.ascii.isDigit(b)) return false;
    }
    const rest = body[stem..];
    if (rest.len == 0) return true;
    if (!png or rest[0] != '-') return false;
    const n = rest[1..];
    if (n.len < 1 or n.len > 3) return false;
    for (n) |b| if (!std.ascii.isDigit(b)) return false;
    return true;
}

fn sweepRenameBackups(a: Allocator, io: Io, state_dir: []const u8, today: u32, dayOf: Records.DayOf, r: *Report) !void {
    // A rename that is not finished may still need its backup.
    const intent = try std.fs.path.join(a, &.{ state_dir, "rename-intent.json" });
    if (sizeOf(io, intent) != null) return;

    const root = try std.fs.path.join(a, &.{ state_dir, "rename-backup" });
    var d = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const path = try std.fs.path.join(a, &.{ root, e.name });
        const st = sizeOf(io, path) orelse continue;
        if (Retention.ageInDays(dayOfStat(st, dayOf), today) <= rename_backup_days) continue;
        if (r.delete) Io.Dir.cwd().deleteTree(io, path) catch continue;
        r.dirs += 1;
    }
}

// ------------------------------------------------------------ the thread

alloc: Allocator,
io: Io,

mutex: Io.Mutex = .init,
/// The settings the next sweep uses, owned (`own`). Null until the app has
/// said them, and then nothing is swept.
settings: ?Settings = null,
stopping: bool = false,
/// Not sweeping yet: something the first sweep needs is still being
/// written (the app's backfill of older groups). `release` lets it go.
held: bool = false,
/// The first sweep is waiting for the person: how much it would delete.
/// Null when it is not waiting. Read with `waitingBytes`.
waiting: ?u64 = null,
/// Told, on the sweeper's thread, when `waiting` changes.
on_waiting: ?struct { f: *const fn (ctx: *anyopaque) void, ctx: *anyopaque } = null,
generation: std.atomic.Value(u32) = .init(0),
thread: ?std.Thread = null,

pub fn init(alloc: Allocator, io: Io) Sweeper {
    return .{ .alloc = alloc, .io = io };
}

/// Start sweeping: now, and every hour after.
pub fn start(self: *Sweeper) std.Thread.SpawnError!void {
    if (self.thread != null) return;
    self.thread = try std.Thread.spawn(.{}, main, .{self});
}

/// Stop the thread and wait for it. A sweep under way finishes first.
pub fn stop(self: *Sweeper) void {
    const t = self.thread orelse return;
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    self.mutex.unlock(self.io);
    self.poke();
    t.join();
    self.thread = null;
}

pub fn deinit(self: *Sweeper) void {
    self.stop();
    if (self.settings) |s| self.free(s);
    self.* = undefined;
}

/// How much the first sweep would delete, while it waits for the person.
pub fn waitingBytes(self: *Sweeper) ?u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.waiting;
}

/// Sweep now, whatever the clock says: the person has just agreed.
pub fn sweepNow(self: *Sweeper) void {
    self.poke();
}

/// What the first sweep was waiting for is written: sweep now.
pub fn release(self: *Sweeper) void {
    self.mutex.lockUncancelable(self.io);
    const was = self.held;
    self.held = false;
    self.mutex.unlock(self.io);
    if (was) self.poke();
}

/// Replace the settings. When they are different from the last -- the
/// first time above all, which is the sweep at start -- a sweep runs now;
/// the same settings said again (every new terminal says them) do not.
pub fn configure(self: *Sweeper, s: Settings) Allocator.Error!void {
    const owned = try self.own(s);
    self.mutex.lockUncancelable(self.io);
    const old = self.settings;
    self.settings = owned;
    self.mutex.unlock(self.io);
    const changed = if (old) |o| !same(o, owned) else true;
    if (old) |o| self.free(o);
    if (changed) self.poke();
}

fn same(a: Settings, b: Settings) bool {
    if (!std.mem.eql(u8, a.state_dir, b.state_dir)) return false;
    if ((a.shots_dir == null) != (b.shots_dir == null)) return false;
    if (a.shots_dir) |d| if (!std.mem.eql(u8, d, b.shots_dir.?)) return false;
    return std.meta.eql(a.logs, b.logs) and std.meta.eql(a.shots, b.shots) and
        std.meta.eql(a.group, b.group) and std.meta.eql(a.project, b.project) and
        std.meta.eql(a.other, b.other);
}

fn own(self: *Sweeper, s: Settings) Allocator.Error!Settings {
    var out = s;
    out.state_dir = try self.alloc.dupe(u8, s.state_dir);
    errdefer self.alloc.free(out.state_dir);
    out.shots_dir = if (s.shots_dir) |d| try self.alloc.dupe(u8, d) else null;
    return out;
}

fn free(self: *Sweeper, s: Settings) void {
    self.alloc.free(s.state_dir);
    if (s.shots_dir) |d| self.alloc.free(d);
}

fn poke(self: *Sweeper) void {
    _ = self.generation.fetchAdd(1, .release);
    self.io.futexWake(u32, &self.generation.raw, 1);
}

fn main(self: *Sweeper) void {
    while (true) {
        const seen = self.generation.load(.acquire);

        // Copied under the lock, so `configure` can replace them meanwhile.
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        self.mutex.lockUncancelable(self.io);
        const stopping = self.stopping;
        const s: ?Settings = if (self.held) null else if (self.settings) |v| copy(arena.allocator(), v) catch null else null;
        self.mutex.unlock(self.io);
        if (stopping) return;

        if (s) |settings| {
            const now = daylog.nowMs(self.io);
            const consented = hasConsent(self.io, settings.state_dir);
            const r = sweepOnce(std.heap.page_allocator, self.io, settings, daylog.dayOf(now), daylog.dayOf, consented);
            if (r.held_bytes) |held| {
                log.info("sweep: waiting for agreement before the first sweep, which would delete bytes={d}", .{held});
            } else {
                if (r.files > 0 or r.dirs > 0) log.info("sweep: deleted files={d} bytes={d} dirs={d}", .{ r.files, r.bytes, r.dirs });
                // Under the threshold the first time: agreed, never asked.
                if (!consented) writeConsent(self.io, settings.state_dir, now, "first-sweep-under-threshold");
            }
            self.mutex.lockUncancelable(self.io);
            const changed = self.waiting != r.held_bytes;
            self.waiting = r.held_bytes;
            self.mutex.unlock(self.io);
            if (changed) if (self.on_waiting) |cb| cb.f(cb.ctx);
        }

        const deadline: Io.Clock.Timestamp = .fromNow(self.io, .{
            .raw = .fromMilliseconds(@intCast(every_ms)),
            .clock = .awake,
        });
        self.io.futexWaitTimeout(u32, &self.generation.raw, seen, .{ .deadline = deadline }) catch return;
    }
}

fn copy(a: Allocator, s: Settings) Allocator.Error!Settings {
    var out = s;
    out.state_dir = try a.dupe(u8, s.state_dir);
    out.shots_dir = if (s.shots_dir) |d| try a.dupe(u8, d) else null;
    return out;
}

const testing = std.testing;

test "only Polter's own screenshot names are screenshots" {
    try testing.expect(isShot("20261015-010203-004.png"));
    try testing.expect(isShot("20261015-010203-004.json"));
    try testing.expect(isShot("20261015-010203-004-12.png"));
    try testing.expect(!isShot("20261015-010203-004-12.json"));
    try testing.expect(!isShot("20261015-010203-004-1234.png"));
    try testing.expect(!isShot("holiday.png"));
    try testing.expect(!isShot("20261015_010203-004.png"));
    try testing.expect(!isShot("20261015-010203-004.txt"));
}

/// A day per thousand milliseconds from 20261001, as `Records`' tests use.
fn fakeDay(at_ms: i64) u32 {
    return 20261001 + @as(u32, @intCast(@max(@divFloor(at_ms, 1000), 0)));
}

fn put(io: Io, dir: []const u8, name: []const u8, bytes: usize) !void {
    try Io.Dir.cwd().createDirPath(io, dir);
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    var f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var line: [64]u8 = @splat('x');
    var left = bytes;
    var at: u64 = 0;
    while (left > 0) {
        const n = @min(left, line.len);
        try f.writePositionalAll(io, line[0..n], at);
        at += n;
        left -= n;
    }
}

fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test "a sweep keeps each tier by its own rule and never the live file" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const state = try std.fmt.allocPrint(alloc, "/tmp/polter-sweep-{x}", .{&raw});
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    var p: [512]u8 = undefined;
    const in_group = try std.fmt.bufPrint(&p, "{s}/terminals/0000000000000011-a", .{state});
    const in_group_dir = try alloc.dupe(u8, in_group);
    defer alloc.free(in_group_dir);
    try put(io, in_group_dir, "2026-10-02.jsonl", 100);
    try put(io, in_group_dir, "2026-10-05.jsonl", 100);

    const alone = try std.fmt.bufPrint(&p, "{s}/terminals/0000000000000022-b", .{state});
    const alone_dir = try alloc.dupe(u8, alone);
    defer alloc.free(alone_dir);
    try put(io, alone_dir, "2026-10-01.jsonl", 100);
    try put(io, alone_dir, "2026-10-14.jsonl", 100);
    try put(io, alone_dir, "2026-10-15.jsonl", 100);
    try put(io, alone_dir, "2026-10-15.part2.jsonl", 100);

    const gone = try std.fmt.bufPrint(&p, "{s}/terminals/0000000000000033-c", .{state});
    const gone_dir = try alloc.dupe(u8, gone);
    defer alloc.free(gone_dir);
    try put(io, gone_dir, "2026-09-01.jsonl", 10);

    const stats = try std.fmt.bufPrint(&p, "{s}/stats/build", .{state});
    const stats_dir = try alloc.dupe(u8, stats);
    defer alloc.free(stats_dir);
    try put(io, stats_dir, "2026-09-01.jsonl", 10);
    try put(io, stats_dir, "2026-10-14.jsonl", 10);

    // 0x11 was in "build" on the 2nd and 3rd of the month, and only then.
    {
        var l = try SessionLog.open(alloc, io, state);
        defer l.deinit();
        l.joined("build", 1000, 0x11, .{}, false);
        l.left("build", 2000, 0x11, false);
    }

    const today: u32 = 20261015;
    const r = sweepOnce(alloc, io, .{
        .state_dir = state,
        .logs = .{ .keep_days = 14, .max_bytes = null },
        .shots = .unlimited,
        .group = .unlimited,
        .project = .unlimited,
        .other = .{ .keep_days = 7, .max_bytes = 50 },
    }, today, fakeDay, true);

    var q: [512]u8 = undefined;
    // In the group that day: kept, however old.
    try testing.expect(exists(io, try std.fmt.bufPrint(&q, "{s}/2026-10-02.jsonl", .{in_group_dir})));
    // The same terminal after it left: the "other" rule, and too old.
    try testing.expect(!exists(io, try std.fmt.bufPrint(&q, "{s}/2026-10-05.jsonl", .{in_group_dir})));
    // Never in a group: too old goes, recent stays...
    try testing.expect(!exists(io, try std.fmt.bufPrint(&q, "{s}/2026-10-01.jsonl", .{alone_dir})));
    // ...and over the 50 bytes, the oldest of what is left goes, today's
    // finished first part with it -- but today's newest part, being
    // written, is never chosen, though it alone is over the limit.
    try testing.expect(!exists(io, try std.fmt.bufPrint(&q, "{s}/2026-10-14.jsonl", .{alone_dir})));
    try testing.expect(!exists(io, try std.fmt.bufPrint(&q, "{s}/2026-10-15.jsonl", .{alone_dir})));
    try testing.expect(exists(io, try std.fmt.bufPrint(&q, "{s}/2026-10-15.part2.jsonl", .{alone_dir})));
    // A directory left empty goes with its last file.
    try testing.expect(!exists(io, gone_dir));
    // Logs: by their own days.
    try testing.expect(!exists(io, try std.fmt.bufPrint(&q, "{s}/2026-09-01.jsonl", .{stats_dir})));
    try testing.expect(exists(io, try std.fmt.bufPrint(&q, "{s}/2026-10-14.jsonl", .{stats_dir})));
    // The session record is not something a sweep touches.
    try testing.expect(exists(io, try std.fmt.bufPrint(&q, "{s}/sessions", .{state})));

    try testing.expectEqual(@as(usize, 1), r.dirs);
    try testing.expectEqual(@as(usize, 6), r.files);
}

test "the first sweep over the threshold deletes nothing and says how much it would" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const state = try std.fmt.allocPrint(alloc, "/tmp/polter-sweep-{x}", .{&raw});
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    var p: [512]u8 = undefined;
    const dir = try alloc.dupe(u8, try std.fmt.bufPrint(&p, "{s}/terminals/0000000000000022-b", .{state}));
    defer alloc.free(dir);
    try put(io, dir, "2026-09-01.jsonl", 300);
    try put(io, dir, "2026-09-02.jsonl", 300);

    const settings: Settings = .{
        .state_dir = state,
        .logs = .unlimited,
        .shots = .unlimited,
        .group = .unlimited,
        .project = .unlimited,
        .other = .{ .keep_days = 7, .max_bytes = null },
    };
    var q: [512]u8 = undefined;
    const old = try std.fmt.bufPrint(&q, "{s}/2026-09-01.jsonl", .{dir});

    // 600 bytes would go; over a threshold of 500, nothing does.
    const held = sweepGated(alloc, io, settings, 20261015, fakeDay, 500);
    try testing.expectEqual(@as(?u64, 600), held.held_bytes);
    try testing.expect(exists(io, old));

    // Under it, the sweep goes ahead.
    const under = sweepGated(alloc, io, settings, 20261015, fakeDay, 600);
    try testing.expectEqual(@as(?u64, null), under.held_bytes);
    try testing.expectEqual(@as(usize, 2), under.files);
    try testing.expect(!exists(io, old));
}

test "the agreement is a file in the state directory" {
    const alloc = testing.allocator;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const state = try std.fmt.allocPrint(alloc, "/tmp/polter-consent-{x}", .{&raw});
    defer {
        Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try Io.Dir.cwd().createDirPath(io, state);
    try testing.expect(!hasConsent(io, state));
    writeConsent(io, state, 1, "acknowledged");
    try testing.expect(hasConsent(io, state));
}
