//! The history grid of the performance page (#1985 §9, task 2015 Q1): the
//! day files `ResourceHistory` writes, read back into one row of cells per
//! pane.
//!
//! Two spans. **24 hours**: 48 cells of the 30-minute slots themselves, the
//! last the slot now open. **7 days**: 42 cells of four local hours, six to
//! a day, the last the four hours now open. A cell is the highest level any
//! line in it says the pane reached, or empty -- the pane was not there.
//!
//! **Lines are taken at their highest, never their latest.** The same pane
//! and the same `at` can be written twice: a crash between a slot's line
//! and the rewrite of `open.jsonl` writes it again on the next start
//! (`ResourceHistory.File.recover`). Taking the highest of each makes the
//! second line harmless, which is the rule the reader keeps.
//!
//! Each cell also keeps the one event a hover is for: the worst in it -- a
//! kill over a withheld kill over a warning -- and of equals the latest.
//!
//! Pure but for `readDays`; the open slots, which are in no file yet, are
//! handed in by the caller.

const ResourceGrid = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const History = @import("ResourceHistory.zig");
const Level = History.Level;

pub const Span = enum {
    /// 48 cells of 30 minutes.
    day,
    /// 42 cells of 4 hours.
    week,

    pub fn cellMs(self: Span) i64 {
        return switch (self) {
            .day => History.slot_ms,
            .week => 8 * History.slot_ms,
        };
    }

    pub fn cells(self: Span) usize {
        return switch (self) {
            .day => 48,
            .week => 42,
        };
    }
};

/// What a cell's hover says about the worst line that counted in it.
pub const Mark = struct {
    pub const What = enum { warn, withheld, kill };

    what: What,
    at_ms: i64,
    metric: Metric,
    value: u64,
    /// Which line: 0 for the kill line, 1–4 for the warn lines.
    line: u8,
    at_line: u64,
    for_ms: u32,
    top: [16]u8,
    top_len: u8,
    count: u32,
    fast: bool,
    told_person: bool,
    told_supervisor: bool,

    pub const Metric = enum { memory, processes };

    pub fn topName(self: *const Mark) []const u8 {
        return self.top[0..self.top_len];
    }

    /// Whether `self` is the one to show over `other`.
    fn worse(self: Mark, other: Mark) bool {
        if (self.what != other.what) return @intFromEnum(self.what) > @intFromEnum(other.what);
        return self.at_ms >= other.at_ms;
    }
};

pub const Cell = struct {
    /// Null: no line of the pane fell in it.
    level: ?Level = null,
    /// The most memory held in it, and the most processes.
    mem: u64 = 0,
    procs: u32 = 0,
    mark: ?Mark = null,
};

pub const Row = struct {
    pane: u64,
    cells: []Cell,
};

pub const Grid = struct {
    span: Span,
    /// The first cell's start, wall-clock milliseconds.
    start_ms: i64,
    /// One per pane, in the order each first appears in time.
    rows: []Row,
    /// Lines that were not lines: cut short, or not JSON.
    skipped: usize,

    pub fn deinit(self: *Grid, alloc: Allocator) void {
        for (self.rows) |r| alloc.free(r.cells);
        alloc.free(self.rows);
        self.* = undefined;
    }

    pub fn cellMs(self: *const Grid) i64 {
        return self.span.cellMs();
    }
};

/// Where the grid of `span` starts at `now_ms`: the cells are the reader's
/// own local hours, the last the one `now_ms` is in.
pub fn startOf(span: Span, now_ms: i64, offset_ms: i64) i64 {
    const cell = span.cellMs();
    const local = now_ms + offset_ms;
    const current = local - @mod(local, cell) - offset_ms;
    return current - @as(i64, @intCast(span.cells() - 1)) * cell;
}

/// One line as it is on disk; fields a kind does not have are left out.
const Line = struct {
    t: []const u8 = "",
    pane: []const u8 = "",
    at: i64 = 0,
    level: []const u8 = "",
    mem: u64 = 0,
    procs: u32 = 0,
    metric: []const u8 = "",
    value: u64 = 0,
    line: []const u8 = "",
    at_line: u64 = 0,
    for_ms: u32 = 0,
    top: []const u8 = "",
    count: u32 = 0,
    fast: bool = false,
    told_person: bool = false,
    told_supervisor: bool = false,
};

/// The grid of `span` at `now_ms`, from `bytes` -- the day files' lines --
/// and the slots still open, which no file has yet.
pub fn build(alloc: Allocator, span: Span, now_ms: i64, offset_ms: i64, bytes: []const u8, open: []const History.Closed) Allocator.Error!Grid {
    const start = startOf(span, now_ms, offset_ms);
    var b: Builder = .{ .alloc = alloc, .span = span, .start = start };
    errdefer b.deinit();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |text| {
        if (text.len == 0) continue;
        _ = arena.reset(.retain_capacity);
        const l = std.json.parseFromSliceLeaky(Line, arena.allocator(), text, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                b.skipped += 1;
                continue;
            },
        };
        try b.add(l);
    }
    for (open) |c| {
        const cell = try b.cellFor(c.pane, c.slot.start_ms) orelse continue;
        raise(cell, c.slot.level, c.slot.mem, c.slot.procs);
    }
    return b.finish();
}

const Builder = struct {
    alloc: Allocator,
    span: Span,
    start: i64,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// When each row's pane first appears, for the order.
    first: std.ArrayListUnmanaged(i64) = .empty,
    skipped: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.rows.items) |r| self.alloc.free(r.cells);
        self.rows.deinit(self.alloc);
        self.first.deinit(self.alloc);
    }

    fn add(self: *Builder, l: Line) Allocator.Error!void {
        const pane = paneOf(l.pane) orelse {
            self.skipped += 1;
            return;
        };
        if (std.mem.eql(u8, l.t, "slot")) {
            const level = std.meta.stringToEnum(Level, l.level) orelse {
                self.skipped += 1;
                return;
            };
            const cell = try self.cellFor(pane, l.at) orelse return;
            raise(cell, level, l.mem, l.procs);
            return;
        }
        const what = std.meta.stringToEnum(Mark.What, l.t) orelse {
            self.skipped += 1;
            return;
        };
        const mark = markOf(what, l) orelse {
            self.skipped += 1;
            return;
        };
        const cell = try self.cellFor(pane, l.at) orelse return;
        // The event is in the cell's level too: its slot may not be
        // written yet.
        raise(cell, switch (what) {
            .kill => .killed,
            .withheld => .withheld,
            .warn => .ofWarn(mark.line - 1),
        }, 0, 0);
        if (cell.mark == null or mark.worse(cell.mark.?)) cell.mark = mark;
    }

    /// The cell `at_ms` falls in for `pane`, its row made if need be; null
    /// outside the grid.
    fn cellFor(self: *Builder, pane: u64, at_ms: i64) Allocator.Error!?*Cell {
        if (at_ms < self.start) return null;
        const i: usize = @intCast(@divFloor(at_ms - self.start, self.span.cellMs()));
        if (i >= self.span.cells()) return null;
        for (self.rows.items, 0..) |r, n| if (r.pane == pane) {
            self.first.items[n] = @min(self.first.items[n], at_ms);
            return &r.cells[i];
        };
        const cells = try self.alloc.alloc(Cell, self.span.cells());
        errdefer self.alloc.free(cells);
        @memset(cells, .{});
        try self.rows.append(self.alloc, .{ .pane = pane, .cells = cells });
        errdefer _ = self.rows.pop();
        try self.first.append(self.alloc, at_ms);
        return &cells[i];
    }

    fn finish(self: *Builder) Allocator.Error!Grid {
        const Ctx = struct {
            first: []i64,
            rows: []Row,
            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                return c.first[a] < c.first[b] or (c.first[a] == c.first[b] and c.rows[a].pane < c.rows[b].pane);
            }
            pub fn swap(c: @This(), a: usize, b: usize) void {
                std.mem.swap(Row, &c.rows[a], &c.rows[b]);
                std.mem.swap(i64, &c.first[a], &c.first[b]);
            }
        };
        std.sort.insertionContext(0, self.rows.items.len, Ctx{ .first = self.first.items, .rows = self.rows.items });
        self.first.deinit(self.alloc);
        return .{
            .span = self.span,
            .start_ms = self.start,
            .rows = try self.rows.toOwnedSlice(self.alloc),
            .skipped = self.skipped,
        };
    }
};

fn raise(cell: *Cell, level: Level, mem: u64, procs: u32) void {
    cell.level = if (cell.level) |l| l.max(level) else level;
    cell.mem = @max(cell.mem, mem);
    cell.procs = @max(cell.procs, procs);
}

fn paneOf(text: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, text, "0x")) return null;
    return std.fmt.parseUnsigned(u64, text[2..], 16) catch null;
}

fn markOf(what: Mark.What, l: Line) ?Mark {
    const metric = std.meta.stringToEnum(Mark.Metric, l.metric) orelse return null;
    const line: u8 = if (std.mem.eql(u8, l.line, "kill"))
        0
    else if (l.line.len == 5 and std.mem.startsWith(u8, l.line, "warn") and l.line[4] >= '1' and l.line[4] <= '4')
        l.line[4] - '0'
    else
        return null;
    // A warning is on a warn line, a kill on the kill line.
    if ((what == .warn) != (line != 0)) return null;
    var m: Mark = .{
        .what = what,
        .at_ms = l.at,
        .metric = metric,
        .value = l.value,
        .line = line,
        .at_line = l.at_line,
        .for_ms = l.for_ms,
        .top = undefined,
        .top_len = @intCast(@min(l.top.len, 16)),
        .count = l.count,
        .fast = l.fast,
        .told_person = l.told_person,
        .told_supervisor = l.told_supervisor,
    };
    @memcpy(m.top[0..m.top_len], l.top[0..m.top_len]);
    return m;
}

/// Every day file in `<state>/resources`, one after the other. A file that
/// cannot be read is left out, as a day with nothing in it.
pub fn readDays(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    const dir = try std.fs.path.join(alloc, &.{ state_dir, "resources" });
    defer alloc.free(dir);
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory or !isDayFile(entry.name)) continue;
        const bytes = d.readFileAlloc(io, entry.name, alloc, .limited(64 << 20)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer alloc.free(bytes);
        try out.appendSlice(alloc, bytes);
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

fn isDayFile(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".jsonl")) return false;
    const stem = name[0 .. name.len - ".jsonl".len];
    return stem.len == 10 and stem[4] == '-' and stem[7] == '-';
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const min: i64 = 60 * 1000;
const hour: i64 = 60 * min;
/// 2026-10-21 12:00 UTC; the tests read in UTC+8, as the person does.
const noon: i64 = 1792584000000;
const plus8: i64 = 8 * hour;

fn rowOf(g: *const Grid, pane: u64) Row {
    for (g.rows) |r| if (r.pane == pane) return r;
    @panic("no such row");
}

fn slotLine(buf: []u8, pane: u64, at: i64, level: []const u8, mem: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"t\":\"slot\",\"pane\":\"0x{x}\",\"at\":{d},\"level\":\"{s}\",\"mem\":{d},\"procs\":1}}\n", .{ pane, at, level, mem }) catch unreachable;
}

test "2015: the 24-hour grid is the last 48 half hours, local, the last the one open now" {
    const start = startOf(.day, noon + 10 * min, plus8);
    // 20:10 local: the last cell is 20:00, the first 47 half hours before.
    try testing.expectEqual(noon - 47 * 30 * min, start);
    // The 7-day grid: four-hour cells on the local clock -- 16:00 to
    // 20:00, 20:00 to 24:00 -- the last the one 20:10 is in.
    const week = startOf(.week, noon + 10 * min, plus8);
    try testing.expectEqual(noon - 41 * 4 * hour, week);
    try testing.expectEqual(@as(i64, 0), @mod(week + plus8, 4 * hour));
}

test "2015: the same pane and slot written twice is taken at its highest" {
    var buf: [4][160]u8 = undefined;
    const at = noon - 2 * hour;
    // What the double write on a pane's close left (seq 116): the real
    // reading and an empty one, in either order.
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, slotLine(&buf[0], 0x54ce, at, "warn1", 2212248));
    try text.appendSlice(testing.allocator, slotLine(&buf[1], 0x54ce, at, "ok", 0));
    try text.appendSlice(testing.allocator, slotLine(&buf[2], 0x77, at, "ok", 0));
    try text.appendSlice(testing.allocator, slotLine(&buf[3], 0x77, at, "warn2", 9000));

    var g = try build(testing.allocator, .day, noon, plus8, text.items, &.{});
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.rows.len);
    const i: usize = @intCast(@divFloor(at - g.start_ms, g.cellMs()));
    const a = rowOf(&g, 0x54ce).cells[i];
    try testing.expectEqual(@as(?Level, .warn1), a.level);
    try testing.expectEqual(@as(u64, 2212248), a.mem);
    const b = rowOf(&g, 0x77).cells[i];
    try testing.expectEqual(@as(?Level, .warn2), b.level);
    try testing.expectEqual(@as(u64, 9000), b.mem);
    // Either side of it, the pane was not there.
    try testing.expectEqual(@as(?Level, null), rowOf(&g, 0x54ce).cells[i - 1].level);
}

test "2015: a week cell is the highest of its eight half hours, and the open slots count" {
    var buf: [3][160]u8 = undefined;
    // 16:00 and 18:30 local fall in the same four hours (16:00–20:00).
    const eight = noon - 4 * hour;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, slotLine(&buf[0], 0x1, eight, "warn1", 5));
    try text.appendSlice(testing.allocator, slotLine(&buf[1], 0x1, eight + 150 * min, "warn3", 7));
    // Eight days ago: off the grid.
    try text.appendSlice(testing.allocator, slotLine(&buf[2], 0x1, noon - 8 * 24 * hour, "killed", 99));
    // The half hour open now, in no file yet.
    const open = [_]History.Closed{.{ .pane = 0x2, .slot = .{ .start_ms = noon, .level = .withheld, .mem = 3, .procs = 2 } }};

    var g = try build(testing.allocator, .week, noon + 5 * min, plus8, text.items, &open);
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.rows.len);
    const cell = g.rows[0].cells[@intCast(@divFloor(eight - g.start_ms, g.cellMs()))];
    try testing.expectEqual(@as(?Level, .warn3), cell.level);
    try testing.expectEqual(@as(u64, 7), cell.mem);
    for (g.rows[0].cells) |c| try testing.expect(c.level != .killed);
    const last = g.rows[1].cells[g.rows[1].cells.len - 1];
    try testing.expectEqual(@as(?Level, .withheld), last.level);
}

test "2015: a cell's hover is its worst event, a kill over a warning, the later of two alike" {
    const at = noon - 3 * hour;
    var buf: [3][400]u8 = undefined;
    const warn = std.fmt.bufPrint(&buf[0], "{{\"t\":\"warn\",\"pane\":\"0x9\",\"at\":{d},\"metric\":\"memory\",\"value\":15,\"line\":\"warn2\",\"at_line\":13,\"for_ms\":10000,\"top\":\"node\",\"count\":1,\"fast\":false,\"told_person\":true,\"told_supervisor\":false}}\n", .{at + 20 * min}) catch unreachable;
    const kill = std.fmt.bufPrint(&buf[1], "{{\"t\":\"kill\",\"pane\":\"0x9\",\"at\":{d},\"metric\":\"memory\",\"value\":20,\"line\":\"kill\",\"at_line\":19,\"for_ms\":10000,\"top\":\"python3.13\",\"count\":7,\"fast\":false,\"told_person\":true,\"told_supervisor\":true}}\n", .{at + 5 * min}) catch unreachable;
    const later = std.fmt.bufPrint(&buf[2], "{{\"t\":\"warn\",\"pane\":\"0x9\",\"at\":{d},\"metric\":\"memory\",\"value\":16,\"line\":\"warn1\",\"at_line\":8,\"for_ms\":10000,\"top\":\"node\",\"count\":1,\"fast\":false,\"told_person\":false,\"told_supervisor\":false}}\n", .{at + 25 * min}) catch unreachable;

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, warn);
    try text.appendSlice(testing.allocator, kill);
    try text.appendSlice(testing.allocator, later);
    var g = try build(testing.allocator, .day, noon, plus8, text.items, &.{});
    defer g.deinit(testing.allocator);
    const cell = g.rows[0].cells[@intCast(@divFloor(at - g.start_ms, g.cellMs()))];
    // No slot line yet: the events alone make the level.
    try testing.expectEqual(@as(?Level, .killed), cell.level);
    const m = cell.mark.?;
    try testing.expectEqual(Mark.What.kill, m.what);
    try testing.expectEqualStrings("python3.13", m.topName());
    try testing.expectEqual(@as(u32, 7), m.count);
    try testing.expect(m.told_supervisor);

    // Two warnings alone: the later one, whichever comes first in the file.
    var both: std.ArrayListUnmanaged(u8) = .empty;
    defer both.deinit(testing.allocator);
    try both.appendSlice(testing.allocator, later);
    try both.appendSlice(testing.allocator, warn);
    var g3 = try build(testing.allocator, .day, noon, plus8, both.items, &.{});
    defer g3.deinit(testing.allocator);
    const m3 = g3.rows[0].cells[@intCast(@divFloor(at - g3.start_ms, g3.cellMs()))].mark.?;
    try testing.expectEqual(@as(u64, 16), m3.value);
}

test "2015: a line cut short or not a line is skipped and counted, the rest read" {
    var buf: [160]u8 = undefined;
    const good = slotLine(&buf, 0x1, noon - hour, "ok", 1);
    const text = try std.mem.concat(testing.allocator, u8, &.{
        good,
        "{\"t\":\"slot\",\"pane\":\"0x2\",\"at\":1,\"lev\n",
        "{\"t\":\"slot\",\"pane\":\"nope\",\"at\":1,\"level\":\"ok\"}\n",
        "{\"t\":\"slot\",\"pane\":\"0x3\",\"at\":1,\"level\":\"loud\"}\n",
        "{\"t\":\"warn\",\"pane\":\"0x4\",\"at\":1,\"metric\":\"memory\",\"line\":\"kill\"}\n",
    });
    defer testing.allocator.free(text);
    var g = try build(testing.allocator, .day, noon, plus8, text, &.{});
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.rows.len);
    try testing.expectEqual(@as(usize, 4), g.skipped);
}

test "2015: rows are in the order their panes first appear" {
    var buf: [3][160]u8 = undefined;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, slotLine(&buf[0], 0xb, noon - 1 * hour, "ok", 1));
    try text.appendSlice(testing.allocator, slotLine(&buf[1], 0xa, noon - 5 * hour, "ok", 1));
    try text.appendSlice(testing.allocator, slotLine(&buf[2], 0xc, noon - 3 * hour, "ok", 1));
    var g = try build(testing.allocator, .day, noon, plus8, text.items, &.{});
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0xa), g.rows[0].pane);
    try testing.expectEqual(@as(u64, 0xc), g.rows[1].pane);
    try testing.expectEqual(@as(u64, 0xb), g.rows[2].pane);
}

test "2015: the day files are read, and nothing else in the directory" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    try tmp.dir.createDirPath(io, "resources");
    var rd = try tmp.dir.openDir(io, "resources", .{});
    defer rd.close(io);
    for ([_][2][]const u8{
        .{ "2026-10-20.jsonl", "a\n" },
        // No newline at the end: the next file still starts a line.
        .{ "2026-10-21.jsonl", "b" },
        .{ History.File.open_name, "open\n" },
        .{ "notes.txt", "x\n" },
    }) |f| {
        var file = try rd.createFile(io, f[0], .{});
        defer file.close(io);
        try file.writeStreamingAll(io, f[1]);
    }
    const bytes = try readDays(testing.allocator, io, root);
    defer testing.allocator.free(bytes);
    // The order is the directory's; both lines, whole, are what counts.
    try testing.expectEqual(@as(usize, 4), bytes.len);
    try testing.expect(std.mem.indexOf(u8, bytes, "a\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "b\n") != null);
}
