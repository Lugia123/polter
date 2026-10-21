//! Each pane's last few minutes, for its card on the performance page
//! (task 2015 Q2, #1985 ui-v4): the curve in row 4, the trend in row 2,
//! "about 8 min to the line" in row 3, the cores and the time it has run
//! at its foot.
//!
//! **The last `cap` readings**, one every two seconds: five minutes. Each
//! carries the reading's `seq`, so a page that has the points up to one
//! asks only for what came after (`firstAfter`).
//!
//! **Cores** are two readings' CPU time over the wall time between them.
//! The time is summed over the processes alive at each reading, so one that
//! ends takes its time away and the sum goes down: that interval is not
//! counted, the last figure stands, and the next is measured from here.
//!
//! **The trend** is the least-squares slope of the last `window_ms`, per
//! minute; under `flat` of the memory held (or 16 MiB, whichever is more)
//! it is level. Unknown with fewer than `min_points` points or under
//! `min_span_ms` of them -- a pane just opened has no trend.
//!
//! Pure: readings in, figures out. Kept by `App` per pane, dropped with it.

const ResourceRecent = @This();

const std = @import("std");

/// Five minutes of readings two seconds apart.
pub const cap = 150;
/// How far back the trend looks.
pub const window_ms: i64 = 60_000;
pub const min_points = 3;
pub const min_span_ms: i64 = 6_000;
/// Level: a minute's change under this many hundredths of the memory held.
pub const flat_percent = 1;
pub const flat_floor: u64 = 16 << 20;

pub const Point = struct {
    seq: u64,
    at_ms: i64,
    mem: u64,
};

pub const Trend = struct {
    /// Bytes a minute; negative when falling.
    per_min: i64,
    flat: bool,
};

buf: [cap]Point = undefined,
len: usize = 0,
/// Where the oldest is.
head: usize = 0,

cpu_last_ns: ?u64 = null,
cpu_last_ms: i64 = 0,
/// Thousandths of a core over the last interval that could be measured.
cpu_milli: ?u32 = null,

/// When the pane's work started (`ledger.Usage.started_ms`).
started_ms: ?i64 = null,

/// One reading.
pub fn push(self: *ResourceRecent, p: Point, cpu_ns: u64, started_ms: ?i64) void {
    if (self.len < cap) {
        self.buf[(self.head + self.len) % cap] = p;
        self.len += 1;
    } else {
        self.buf[self.head] = p;
        self.head = (self.head + 1) % cap;
    }
    if (self.cpu_last_ns) |last| {
        const dt = p.at_ms - self.cpu_last_ms;
        if (cpu_ns >= last and dt > 0) {
            const used: u128 = cpu_ns - last;
            self.cpu_milli = @intCast(@min(used * 1000 / (@as(u128, @intCast(dt)) * std.time.ns_per_ms), std.math.maxInt(u32)));
        }
    }
    self.cpu_last_ns = cpu_ns;
    self.cpu_last_ms = p.at_ms;
    self.started_ms = started_ms;
}

/// The `i`th point, oldest first.
pub fn at(self: *const ResourceRecent, i: usize) Point {
    std.debug.assert(i < self.len);
    return self.buf[(self.head + i) % cap];
}

pub fn newest(self: *const ResourceRecent) ?Point {
    if (self.len == 0) return null;
    return self.at(self.len - 1);
}

/// The index of the first point after `seq`: `len` when there is none.
/// With `seq` 0, every point.
pub fn firstAfter(self: *const ResourceRecent, seq: u64) usize {
    var i: usize = self.len;
    while (i > 0 and self.at(i - 1).seq > seq) i -= 1;
    return i;
}

/// The trend of the last `window_ms`; null when there is too little of it.
pub fn trend(self: *const ResourceRecent) ?Trend {
    const last = self.newest() orelse return null;
    var first = self.len;
    while (first > 0 and last.at_ms - self.at(first - 1).at_ms <= window_ms) first -= 1;
    const n = self.len - first;
    if (n < min_points) return null;
    if (last.at_ms - self.at(first).at_ms < min_span_ms) return null;

    // Least squares, times from the first point and memory from its value,
    // so the sums stay small.
    const t0 = self.at(first).at_ms;
    const m0: f64 = @floatFromInt(self.at(first).mem);
    var st: f64 = 0;
    var sm: f64 = 0;
    var stt: f64 = 0;
    var stm: f64 = 0;
    for (first..self.len) |i| {
        const p = self.at(i);
        const t: f64 = @floatFromInt(p.at_ms - t0);
        const m: f64 = @as(f64, @floatFromInt(p.mem)) - m0;
        st += t;
        sm += m;
        stt += t * t;
        stm += t * m;
    }
    const nf: f64 = @floatFromInt(n);
    const den = nf * stt - st * st;
    if (den == 0) return null;
    const per_ms = (nf * stm - st * sm) / den;
    const per_min: i64 = @intFromFloat(@round(std.math.clamp(per_ms * 60_000, -9.0e18, 9.0e18)));
    const level = @max(flat_floor, last.mem / 100 * flat_percent);
    return .{ .per_min = per_min, .flat = @abs(per_min) < level };
}

/// Seconds until the memory reaches `line` at the present trend; null
/// when it is not rising, or is there already.
pub fn secondsTo(self: *const ResourceRecent, line: u64) ?i64 {
    const t = self.trend() orelse return null;
    const last = self.newest() orelse return null;
    if (t.flat or t.per_min <= 0 or last.mem >= line) return null;
    return @intCast(@divFloor(@as(u128, line - last.mem) * 60, @as(u128, @intCast(t.per_min))));
}

/// How long the work has run at `now_ms`, seconds; null with none.
pub fn runSeconds(self: *const ResourceRecent, now_ms: i64) ?i64 {
    const s = self.started_ms orelse return null;
    return @divFloor(@max(0, now_ms - s), 1000);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const mib: u64 = 1 << 20;
const gib: u64 = 1 << 30;

test "2015: the last 150 readings are kept, and a page asks only for what came after its last" {
    var r: ResourceRecent = .{};
    for (1..201) |i| r.push(.{ .seq = i, .at_ms = @intCast(i * 2000), .mem = i }, 0, null);
    try testing.expectEqual(@as(usize, cap), r.len);
    try testing.expectEqual(@as(u64, 51), r.at(0).seq);
    try testing.expectEqual(@as(u64, 200), r.newest().?.seq);
    // Everything after 190: ten points.
    try testing.expectEqual(@as(usize, cap - 10), r.firstAfter(190));
    // Nothing after the newest; all of it after 0, and after a seq older
    // than what is kept.
    try testing.expectEqual(@as(usize, cap), r.firstAfter(200));
    try testing.expectEqual(@as(usize, 0), r.firstAfter(0));
    try testing.expectEqual(@as(usize, 0), r.firstAfter(10));
}

test "2015: cores are CPU time over wall time, and an ended process's time is not a negative" {
    var r: ResourceRecent = .{};
    r.push(.{ .seq = 1, .at_ms = 0, .mem = 0 }, 1_000 * std.time.ns_per_ms, null);
    try testing.expectEqual(@as(?u32, null), r.cpu_milli);
    // 3 s of CPU in 2 s: one and a half cores.
    r.push(.{ .seq = 2, .at_ms = 2000, .mem = 0 }, 4_000 * std.time.ns_per_ms, null);
    try testing.expectEqual(@as(?u32, 1500), r.cpu_milli);
    // A process ended and took its 3.5 s away: the 1.5 stands.
    r.push(.{ .seq = 3, .at_ms = 4000, .mem = 0 }, 500 * std.time.ns_per_ms, null);
    try testing.expectEqual(@as(?u32, 1500), r.cpu_milli);
    // Measured from there on.
    r.push(.{ .seq = 4, .at_ms = 6000, .mem = 0 }, 700 * std.time.ns_per_ms, null);
    try testing.expectEqual(@as(?u32, 100), r.cpu_milli);
}

test "2015: memory climbing 0.6 GB a minute reaches a line 4.8 GB off in eight minutes" {
    var r: ResourceRecent = .{};
    // A reading every two seconds for a minute, 20 MB more each: 600 MB a
    // minute.
    for (0..31) |i| r.push(.{ .seq = i + 1, .at_ms = @intCast(i * 2000), .mem = 10 * gib + i * 20 * mib }, 0, null);
    const t = r.trend().?;
    try testing.expect(!t.flat);
    try testing.expectEqual(@as(i64, 600 * mib), t.per_min);
    const now = r.newest().?.mem;
    try testing.expectEqual(@as(?i64, 8 * 60), r.secondsTo(now + 4800 * mib));
    // Over the line already, or the line below: no time to it.
    try testing.expectEqual(@as(?i64, null), r.secondsTo(now));
}

test "2015: a pane wavering under a hundredth of what it holds is level, and a falling one has no time to the line" {
    var flat: ResourceRecent = .{};
    for (0..31) |i| flat.push(.{ .seq = i + 1, .at_ms = @intCast(i * 2000), .mem = 10 * gib + (i % 3) * 30 * mib }, 0, null);
    try testing.expect(flat.trend().?.flat);
    try testing.expectEqual(@as(?i64, null), flat.secondsTo(19 * gib));

    var falling: ResourceRecent = .{};
    for (0..31) |i| falling.push(.{ .seq = i + 1, .at_ms = @intCast(i * 2000), .mem = 10 * gib - i * 20 * mib }, 0, null);
    const t = falling.trend().?;
    try testing.expect(!t.flat);
    try testing.expectEqual(-@as(i64, 600 * mib), t.per_min);
    try testing.expectEqual(@as(?i64, null), falling.secondsTo(19 * gib));
}

test "2015: a pane just opened has no trend, and only the last minute counts" {
    var r: ResourceRecent = .{};
    r.push(.{ .seq = 1, .at_ms = 0, .mem = 1 * gib }, 0, null);
    r.push(.{ .seq = 2, .at_ms = 2000, .mem = 2 * gib }, 0, null);
    try testing.expectEqual(@as(?Trend, null), r.trend());
    // A climb four minutes ago, then a minute level: level.
    var old: ResourceRecent = .{};
    for (0..30) |i| old.push(.{ .seq = i + 1, .at_ms = @intCast(i * 2000), .mem = @as(u64, i) * 100 * mib }, 0, null);
    for (0..31) |i| old.push(.{ .seq = 100 + i, .at_ms = @intCast(180_000 + i * 2000), .mem = 3 * gib }, 0, null);
    try testing.expect(old.trend().?.flat);
}

test "2015: the time a pane's work has run" {
    var r: ResourceRecent = .{};
    r.push(.{ .seq = 1, .at_ms = 0, .mem = 0 }, 0, 1_000_000);
    try testing.expectEqual(@as(?i64, 4320), r.runSeconds(1_000_000 + 4320 * 1000));
    r.push(.{ .seq = 2, .at_ms = 2000, .mem = 0 }, 0, null);
    try testing.expectEqual(@as(?i64, null), r.runSeconds(9_000_000));
}
