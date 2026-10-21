//! Seven days of what each pane's resources came to (task 1993, #1985 §9):
//! the history grid behind the performance page, and the record to read the
//! morning after.
//!
//! `<state>/resources/<YYYY-MM-DD>.jsonl`, one file per local day, one JSON
//! object per line, two kinds of line:
//!
//! ```
//! {"t":"slot","pane":"0x…","at":1700000000000,"level":"warn2","mem":15032385536,"procs":23}
//!     one pane's 30 minutes, written when they are over: the highest level
//!     it reached (ok | warn1…warn4 | withheld | killed) and the most it held
//! {"t":"warn"|"withheld"|"kill","pane":"0x…","at":…,"metric":"memory",
//!  "value":…,"line":"warn2"|"kill","at_line":…,"for_ms":10000,"top":"python3.13",
//!  "count":7,"fast":false,"told_person":true,"told_supervisor":false}
//!     a line that counted, at the moment it did
//! ```
//!
//! The 7-day view is the 30-minute slots taken eight at a time; nothing else
//! is kept for it.
//!
//! **Seven days, fixed, rolling**: the first write of a day deletes the day
//! files older than that. Not the user's retention setting and not the
//! archive -- a grid past seven days is empty on purpose.
//!
//! Failure is a warning: a pane is not judged worse for a full disk.

const ResourceHistory = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const daylog = @import("daylog.zig");
const judge = @import("judge.zig");

const log = std.log.scoped(.resources);

/// One slot of the grid.
pub const slot_ms: i64 = 30 * 60 * 1000;
/// How many days are kept, today among them.
pub const keep_days: u32 = 7;

/// The highest a pane reached in a slot, in the order a slot keeps the
/// highest.
pub const Level = enum(u8) {
    ok,
    warn1,
    warn2,
    warn3,
    warn4,
    /// The kill line counted on a pane that may not be stopped.
    withheld,
    killed,

    pub fn ofWarn(i: u8) Level {
        return @enumFromInt(@min(@as(u8, 4), i + 1));
    }

    pub fn max(a: Level, b: Level) Level {
        return if (@intFromEnum(b) > @intFromEnum(a)) b else a;
    }
};

/// What a pane's state says it is in now: the highest warn line that has
/// counted and not yet re-armed (`judge.State`). Kills and withheld kills
/// are events, raised into the slot by `noteEvent`.
pub fn levelOf(state: *const judge.State) Level {
    var best: Level = .ok;
    inline for (.{ &state.memory, &state.processes }) |tracks| {
        for (tracks[0..judge.kill_slot], 0..) |t, i| {
            if (!t.armed) best = best.max(.ofWarn(@intCast(i)));
        }
    }
    return best;
}

pub const Slot = struct {
    start_ms: i64,
    level: Level,
    mem: u64,
    procs: u32,
};

/// The local 30 minutes `at_ms` is in, as the wall clock's milliseconds of
/// its start: aligned to the reader's own half hours, not UTC's.
pub fn slotStart(at_ms: i64, offset_ms: i64) i64 {
    const local = at_ms + offset_ms;
    return local - @mod(local, slot_ms) - offset_ms;
}

/// Each pane's current slot. In memory; written when the slot is over, or
/// when the pane goes, or when the app stops. Kept on disk as well, as
/// they stand (`File.keepOpen`): an app that stops is seldom told so.
slots: std.AutoHashMapUnmanaged(u64, Slot) = .empty,

/// What to write: whatever a reading closed.
pub const Closed = struct { pane: u64, slot: Slot };

/// A reading of `pane` at `at_ms`. Returns the slot it closed, if the
/// reading is in a new one.
pub fn note(self: *ResourceHistory, alloc: Allocator, pane: u64, at_ms: i64, offset_ms: i64, level: Level, mem: u64, procs: u32) Allocator.Error!?Closed {
    const start = slotStart(at_ms, offset_ms);
    const e = try self.slots.getOrPut(alloc, pane);
    if (!e.found_existing) {
        e.value_ptr.* = .{ .start_ms = start, .level = level, .mem = mem, .procs = procs };
        return null;
    }
    const s = e.value_ptr;
    if (s.start_ms != start) {
        const closed: Closed = .{ .pane = pane, .slot = s.* };
        s.* = .{ .start_ms = start, .level = level, .mem = mem, .procs = procs };
        return closed;
    }
    s.level = s.level.max(level);
    s.mem = @max(s.mem, mem);
    s.procs = @max(s.procs, procs);
    return null;
}

/// An event raises its pane's slot (a kill is `killed` for the rest of it).
pub fn raise(self: *ResourceHistory, pane: u64, level: Level) void {
    const s = self.slots.getPtr(pane) orelse return;
    s.level = s.level.max(level);
}

/// The pane is gone: its slot, to write.
pub fn take(self: *ResourceHistory, pane: u64) ?Closed {
    const kv = self.slots.fetchRemove(pane) orelse return null;
    return .{ .pane = kv.key, .slot = kv.value };
}

pub fn deinit(self: *ResourceHistory, alloc: Allocator) void {
    self.slots.deinit(alloc);
}

// ------------------------------------------------------------------ lines

pub fn writeSlot(w: *std.Io.Writer, c: Closed) std.Io.Writer.Error!void {
    try w.print("{{\"t\":\"slot\",\"pane\":\"0x{x}\",\"at\":{d},\"level\":\"{t}\",\"mem\":{d},\"procs\":{d}}}\n", .{
        c.pane, c.slot.start_ms, c.slot.level, c.slot.mem, c.slot.procs,
    });
}

/// The `at` of a whole `writeSlot` line, newline left off; null for
/// anything else -- a line a crash cut short among them.
fn slotAt(line: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, line, "{\"t\":\"slot\",") or !std.mem.endsWith(u8, line, "}")) return null;
    const key = "\"at\":";
    const i = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
}

pub const Told = struct { person: bool, supervisor: bool };

pub fn writeEvent(w: *std.Io.Writer, pane: u64, at_ms: i64, e: judge.Event, for_ms: u32, top: []const u8, top_count: u32, told: Told) std.Io.Writer.Error!void {
    var nm: [16]u8 = undefined;
    const kind: []const u8 = switch (e.what) {
        .warn => "warn",
        .withheld => "withheld",
        .kill => "kill",
    };
    try w.print("{{\"t\":\"{s}\",\"pane\":\"0x{x}\",\"at\":{d},\"metric\":\"{t}\",\"value\":{d},\"line\":\"", .{ kind, pane, at_ms, e.metric, e.value });
    switch (e.line) {
        .warn => |i| try w.print("warn{d}", .{@as(u32, i) + 1}),
        .kill => try w.writeAll("kill"),
    }
    // `safeName`: printable ASCII only, so nothing in it needs escaping
    // but the two characters JSON reserves.
    try w.print("\",\"at_line\":{d},\"for_ms\":{d},\"top\":\"", .{ e.at, for_ms });
    for (judge.safeName(&nm, top)) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.print("\",\"count\":{d},\"fast\":{},\"told_person\":{},\"told_supervisor\":{}}}\n", .{
        top_count, e.isFast(), told.person, told.supervisor,
    });
}

// -------------------------------------------------------------- retention

/// Days since 1970-01-01 of a packed `YYYYMMDD` (the civil calendar).
pub fn epochDay(packed_day: u32) i64 {
    var y: i64 = packed_day / 10000;
    const m: i64 = (packed_day / 100) % 100;
    const d: i64 = packed_day % 100;
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Whether the file `name` in the directory is a day file past keeping on
/// `today`. A name that is not a day file is never deleted.
pub fn expired(name: []const u8, today: u32) bool {
    if (!std.mem.endsWith(u8, name, ".jsonl")) return false;
    const stem = name[0 .. name.len - ".jsonl".len];
    if (stem.len != 10 or stem[4] != '-' or stem[7] != '-') return false;
    const y = std.fmt.parseUnsigned(u32, stem[0..4], 10) catch return false;
    const m = std.fmt.parseUnsigned(u32, stem[5..7], 10) catch return false;
    const d = std.fmt.parseUnsigned(u32, stem[8..10], 10) catch return false;
    if (m < 1 or m > 12 or d < 1 or d > 31) return false;
    return epochDay(today) - epochDay(y * 10000 + m * 100 + d) >= keep_days;
}

// --------------------------------------------------------------- the file

/// The day file being appended to. Opened on the first line of a day, which
/// is also when the old days go.
pub const File = struct {
    io: std.Io,
    /// Owned.
    dir: []const u8,
    day: u32 = 0,
    file: ?std.Io.File = null,
    /// Where the next line goes: positional, as `daylog` writes.
    written: u64 = 0,
    /// What `keepOpen` last put in `open_name`. Owned.
    kept: std.ArrayListUnmanaged(u8) = .empty,

    /// The slots still open, beside the day files (P4b). `App.deinit` is
    /// not where they can be written: neither host frees the app when it
    /// quits -- the mac's applicationWillTerminate does not, nor does the
    /// Windows host -- so ⌘Q lost every pane's last half hour. They are
    /// kept here instead, rewritten whenever they change, and `recover`
    /// puts them into their days on the next start. A quit, a crash or a
    /// kill loses the last reading at most.
    pub const open_name = "open.jsonl";

    pub fn init(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!File {
        return .{ .io = io, .dir = try std.fs.path.join(alloc, &.{ state_dir, "resources" }) };
    }

    pub fn deinit(self: *File, alloc: Allocator) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
        self.kept.deinit(alloc);
        alloc.free(self.dir);
    }

    /// `bytes` -- one `writeSlot` line per open slot -- as `open_name`,
    /// whole: written beside it and renamed over it. Nothing open, no file.
    /// Unchanged, nothing done.
    pub fn keepOpen(self: *File, alloc: Allocator, bytes: []const u8) void {
        if (std.mem.eql(u8, self.kept.items, bytes)) return;
        self.kept.clearRetainingCapacity();
        self.kept.appendSlice(alloc, bytes) catch {
            // Written again on the next change.
            self.kept.clearRetainingCapacity();
        };
        var d = self.openDir() catch |err| {
            log.warn("could not keep the open half hours in {s} err={}", .{ self.dir, err });
            return;
        };
        defer d.close(self.io);
        if (bytes.len == 0) {
            d.deleteFile(self.io, open_name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("could not delete the open half hours err={}", .{err}),
            };
            return;
        }
        const tmp = open_name ++ ".tmp";
        {
            var f = d.createFile(self.io, tmp, .{}) catch |err| {
                log.warn("could not keep the open half hours err={}", .{err});
                return;
            };
            defer f.close(self.io);
            f.writeStreamingAll(self.io, bytes) catch |err| {
                log.warn("could not keep the open half hours err={}", .{err});
                return;
            };
        }
        d.rename(tmp, d, open_name, self.io) catch |err| {
            log.warn("could not keep the open half hours err={}", .{err});
            d.deleteFile(self.io, tmp) catch {};
        };
    }

    /// The half hours the last run left open, each into its day, and the
    /// file gone. Before this run keeps any of its own.
    pub fn recover(self: *File, alloc: Allocator) void {
        var d = self.openDir() catch return;
        defer d.close(self.io);
        const bytes = d.readFileAlloc(self.io, open_name, alloc, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                log.warn("could not read the open half hours err={}", .{err});
                return;
            },
        };
        defer alloc.free(bytes);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const at = slotAt(line) orelse continue;
            var buf: [512]u8 = undefined;
            if (line.len + 1 > buf.len) continue;
            @memcpy(buf[0..line.len], line);
            buf[line.len] = '\n';
            self.write(at, buf[0 .. line.len + 1]);
            n += 1;
        }
        d.deleteFile(self.io, open_name) catch |err| log.warn("could not delete the open half hours err={}", .{err});
        if (n > 0) log.info("wrote the {d} half hours the last run left open", .{n});
    }

    fn openDir(self: *File) !std.Io.Dir {
        std.Io.Dir.cwd().createDirPath(self.io, self.dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return std.Io.Dir.cwd().openDir(self.io, self.dir, .{});
    }

    pub fn write(self: *File, at_ms: i64, bytes: []const u8) void {
        const today = daylog.dayOf(at_ms);
        if (self.file == null or self.day != today) self.open(today) catch |err| {
            log.warn("could not open the resource history in {s} err={}", .{ self.dir, err });
            return;
        };
        const f = self.file orelse return;
        f.writePositionalAll(self.io, bytes, self.written) catch |err| {
            log.warn("could not write the resource history err={}", .{err});
            // Reopened on the next line: the cheapest way to recover a
            // handle gone bad, as `daylog` does.
            f.close(self.io);
            self.file = null;
            return;
        };
        self.written += bytes.len;
    }

    fn open(self: *File, today: u32) !void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
        std.Io.Dir.cwd().createDirPath(self.io, self.dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        self.sweep(today);
        var name: [32]u8 = undefined;
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const day_name = std.fmt.bufPrint(&name, "{d:0>4}-{d:0>2}-{d:0>2}.jsonl", .{ today / 10000, (today / 100) % 100, today % 100 }) catch unreachable;
        const full = try std.fmt.bufPrint(&path, "{s}{c}{s}", .{ self.dir, std.fs.path.sep, day_name });
        const f = try daylog.openAppend(self.io, full);
        self.written = (f.stat(self.io) catch |err| {
            f.close(self.io);
            return err;
        }).size;
        self.file = f;
        self.day = today;
    }

    /// Delete the day files past keeping.
    fn sweep(self: *File, today: u32) void {
        var d = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch return;
        defer d.close(self.io);
        var it = d.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind == .directory or !expired(entry.name, today)) continue;
            d.deleteFile(self.io, entry.name) catch |err| {
                log.warn("could not delete the old resource history {s} err={}", .{ entry.name, err });
                continue;
            };
            log.info("deleted the resource history of {s}: past {d} days", .{ entry.name, keep_days });
        }
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;
const G: u64 = 1 << 30;

test "1993: a slot is the local half hour, and keeps the highest level and the most held" {
    // Eight hours east of UTC: 08:00 local is 00:00 UTC.
    const east: i64 = 8 * 3600 * 1000;
    try testing.expectEqual(@as(i64, 0), slotStart(29 * 60 * 1000, east));
    try testing.expectEqual(@as(i64, slot_ms), slotStart(slot_ms, east));
    // A zone half an hour off still aligns to its own half hours.
    const india: i64 = 5 * 3600 * 1000 + 30 * 60 * 1000;
    try testing.expectEqual(@as(i64, 0), slotStart(10, india));

    var h: ResourceHistory = .{};
    defer h.deinit(testing.allocator);
    try testing.expectEqual(@as(?Closed, null), try h.note(testing.allocator, 0xa, 0, 0, .ok, 4 * G, 3));
    try testing.expectEqual(@as(?Closed, null), try h.note(testing.allocator, 0xa, 60_000, 0, .warn2, 14 * G, 23));
    try testing.expectEqual(@as(?Closed, null), try h.note(testing.allocator, 0xa, 120_000, 0, .warn1, 9 * G, 30));
    h.raise(0xa, .killed);
    const closed = (try h.note(testing.allocator, 0xa, slot_ms + 1, 0, .ok, 1 * G, 2)).?;
    try testing.expectEqual(Level.killed, closed.slot.level);
    try testing.expectEqual(14 * G, closed.slot.mem);
    try testing.expectEqual(@as(u32, 30), closed.slot.procs);
    try testing.expectEqual(@as(i64, 0), closed.slot.start_ms);
    // Without an event: a reading lower than an earlier one in the same
    // half hour does not lower it.
    _ = try h.note(testing.allocator, 0xb, 0, 0, .warn2, 1 * G, 1);
    _ = try h.note(testing.allocator, 0xb, 60_000, 0, .warn1, 1 * G, 1);
    try testing.expectEqual(Level.warn2, (try h.note(testing.allocator, 0xb, slot_ms + 1, 0, .ok, 1 * G, 1)).?.slot.level);

    // The next slot starts from its own first reading.
    const gone = h.take(0xa).?;
    try testing.expectEqual(Level.ok, gone.slot.level);
    try testing.expectEqual(@as(i64, slot_ms), gone.slot.start_ms);
    try testing.expectEqual(@as(?Closed, null), h.take(0xa));
}

test "1993: a pane's level is the highest warn line that counted and has not re-armed" {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"memory\": {\"warn\": [\"8G\", \"13G\"], \"kill\": \"19G\"}}", .{});
    defer p.deinit();
    var why: []const u8 = "";
    const l = try @import("limits.zig").parse(p.value, &why);
    var s: judge.State = .fresh;
    _ = judge.step(&s, &l, .{ .mem = 14 * G, .procs = 1 }, 0, 32 * G, .none);
    try testing.expectEqual(Level.ok, levelOf(&s));
    _ = judge.step(&s, &l, .{ .mem = 14 * G, .procs = 1 }, 10_000, 32 * G, .none);
    try testing.expectEqual(Level.warn2, levelOf(&s));
    // Under 80% of 13 GB: warn 2 re-arms, warn 1 has not.
    _ = judge.step(&s, &l, .{ .mem = 10 * G, .procs = 1 }, 12_000, 32 * G, .none);
    try testing.expectEqual(Level.warn1, levelOf(&s));
}

test "1993: the history's lines are JSON, one to a line" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSlot(&w, .{ .pane = 0x1993, .slot = .{ .start_ms = 1_700_000_000_000, .level = .warn2, .mem = 14 * G, .procs = 23 } });
    const e: judge.Event = .{ .metric = .memory, .line = .kill, .what = .kill, .value = 30 * G, .at = 19 * G, .tell_person = true };
    try writeEvent(&w, 0x1993, 1_700_000_100_000, e, 10_000, "py\"th\\on", 7, .{ .person = true, .supervisor = true });
    const text = w.buffered();
    try testing.expectEqualStrings(
        "{\"t\":\"slot\",\"pane\":\"0x1993\",\"at\":1700000000000,\"level\":\"warn2\",\"mem\":15032385536,\"procs\":23}\n" ++
            "{\"t\":\"kill\",\"pane\":\"0x1993\",\"at\":1700000100000,\"metric\":\"memory\",\"value\":32212254720,\"line\":\"kill\"," ++
            "\"at_line\":20401094656,\"for_ms\":10000,\"top\":\"py\\\"th\\\\on\",\"count\":7,\"fast\":true,\"told_person\":true,\"told_supervisor\":true}\n",
        text,
    );
    var lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    while (lines.next()) |line| {
        const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        v.deinit();
    }
}

test "1993: seven days are kept, today among them, and nothing else in the directory is touched" {
    try testing.expectEqual(@as(i64, 0), epochDay(19700101));
    try testing.expectEqual(@as(i64, 20_747), epochDay(20261021));
    try testing.expectEqual(@as(i64, 1), epochDay(20250301) - epochDay(20250228));
    try testing.expectEqual(@as(i64, 2), epochDay(20240301) - epochDay(20240228));

    const today: u32 = 20261021;
    try testing.expect(!expired("2026-10-21.jsonl", today));
    try testing.expect(!expired("2026-10-15.jsonl", today));
    try testing.expect(expired("2026-10-14.jsonl", today));
    // Across a month and a year.
    try testing.expect(!expired("2026-12-28.jsonl", 20270103));
    try testing.expect(expired("2026-12-27.jsonl", 20270103));
    for ([_][]const u8{ "notes.txt", "2026-10-01.json", "2026-1-01.jsonl", "2026-13-01.jsonl", "2026-10-01.part2.jsonl" }) |name| {
        try testing.expect(!expired(name, today));
    }
}

test "1993: the first write of a day deletes the days past keeping" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    try tmp.dir.createDirPath(io, "resources");
    const now = daylog.nowMs(io);
    const today = daylog.dayOf(now);
    var old_name: [32]u8 = undefined;
    const ancient = std.fmt.bufPrint(&old_name, "{d}-01-01.jsonl", .{today / 10000 - 1}) catch unreachable;
    var rd = try tmp.dir.openDir(io, "resources", .{});
    defer rd.close(io);
    for ([_][]const u8{ ancient, "keep-me.txt" }) |n| {
        var f = try rd.createFile(io, n, .{});
        f.close(io);
    }

    var file = try File.init(testing.allocator, io, root);
    defer file.deinit(testing.allocator);
    file.write(now, "{\"t\":\"slot\"}\n");
    file.write(now, "{\"t\":\"slot\"}\n");

    try testing.expectError(error.FileNotFound, rd.access(io, ancient, .{}));
    try rd.access(io, "keep-me.txt", .{});
    var name: [32]u8 = undefined;
    const today_name = std.fmt.bufPrint(&name, "{d:0>4}-{d:0>2}-{d:0>2}.jsonl", .{ today / 10000, (today / 100) % 100, today % 100 }) catch unreachable;
    const written = try rd.readFileAlloc(io, today_name, testing.allocator, .limited(4096));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("{\"t\":\"slot\"}\n{\"t\":\"slot\"}\n", written);
}

test "1993: the open half hours are kept beside the days, rewritten only when they change" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    var file = try File.init(testing.allocator, io, root);
    defer file.deinit(testing.allocator);
    const one = "{\"t\":\"slot\",\"pane\":\"0x1\",\"at\":1,\"level\":\"ok\",\"mem\":5,\"procs\":1}\n";
    file.keepOpen(testing.allocator, one);
    var rd = try tmp.dir.openDir(io, "resources", .{});
    defer rd.close(io);
    {
        const kept = try rd.readFileAlloc(io, File.open_name, testing.allocator, .limited(4096));
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings(one, kept);
    }
    // The same again -- a reading under the peak -- touches nothing: the
    // file taken away is not put back.
    try rd.deleteFile(io, File.open_name);
    file.keepOpen(testing.allocator, one);
    try testing.expectError(error.FileNotFound, rd.access(io, File.open_name, .{}));
    // A new peak is written.
    const two = "{\"t\":\"slot\",\"pane\":\"0x1\",\"at\":1,\"level\":\"ok\",\"mem\":9,\"procs\":1}\n";
    file.keepOpen(testing.allocator, two);
    try rd.access(io, File.open_name, .{});
    // Nothing open: no file.
    file.keepOpen(testing.allocator, "");
    try testing.expectError(error.FileNotFound, rd.access(io, File.open_name, .{}));
}

test "1993: a start puts the last run's open half hours into their days, and skips a line cut short" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    const now = daylog.nowMs(io);
    const today = daylog.dayOf(now);
    var lines_buf: [1024]u8 = undefined;
    const good = try std.fmt.bufPrint(&lines_buf, "{{\"t\":\"slot\",\"pane\":\"0x1\",\"at\":{d},\"level\":\"warn1\",\"mem\":5,\"procs\":1}}\n", .{now});
    const second = try std.fmt.bufPrint(lines_buf[good.len..], "{{\"t\":\"slot\",\"pane\":\"0x2\",\"at\":{d},\"level\":\"ok\",\"mem\":7,\"procs\":2}}\n", .{now});
    // What a crash in the middle of a write leaves.
    const cut = try std.fmt.bufPrint(lines_buf[good.len + second.len ..], "{{\"t\":\"slot\",\"pane\":\"0x3\",\"at\":{d},\"lev", .{now});
    try tmp.dir.createDirPath(io, "resources");
    var rd = try tmp.dir.openDir(io, "resources", .{});
    defer rd.close(io);
    {
        var f = try rd.createFile(io, File.open_name, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, lines_buf[0 .. good.len + second.len + cut.len]);
    }

    var file = try File.init(testing.allocator, io, root);
    defer file.deinit(testing.allocator);
    file.recover(testing.allocator);

    try testing.expectError(error.FileNotFound, rd.access(io, File.open_name, .{}));
    var name: [32]u8 = undefined;
    const today_name = std.fmt.bufPrint(&name, "{d:0>4}-{d:0>2}-{d:0>2}.jsonl", .{ today / 10000, (today / 100) % 100, today % 100 }) catch unreachable;
    const written = try rd.readFileAlloc(io, today_name, testing.allocator, .limited(4096));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(lines_buf[0 .. good.len + second.len], written);
}
