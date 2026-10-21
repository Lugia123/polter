//! The lines a supervisor draws for one pane (task 1993, #1985 §2):
//! `limits` on `role_launch` / `terminal_open`, and `terminal_limits`.
//!
//! ```
//! {"memory":    {"warn": ["8G", "40%"], "kill": "19G", "for": "10s"},
//!  "processes": {"warn": [300], "kill": 2000},
//!  "warn_tells_supervisor": false}
//! ```
//!
//! - Memory is a size (`512M`, `8G`, `1.5G`; binary units) or a share of
//!   the machine (`40%`); processes are a count. A bare number for memory is
//!   refused: "8" could be bytes or gigabytes, and a wrong guess is a pane
//!   killed at 8 bytes.
//! - `warn` is one line or several, `kill` at most one, `for` how long a
//!   reading has to stay over a line before it counts (default 10 s).
//! - **No defaults anywhere**: a metric not named is not judged, and `{}`
//!   is no limits at all -- the pane is measured and nothing else.
//! - A key this does not know is refused rather than ignored, so a typo
//!   ("memroy") is an error and not a pane that is never judged.
//!
//! Pure: JSON in, `Limits` out, and `check` against the machine's memory.
//! What a reading against these lines means is `judge.zig`'s.

const std = @import("std");

/// How many warn lines one metric may have.
pub const max_warns = 4;

/// How long over a line before it counts, when `for` is not given.
pub const default_for_ms: u32 = 10_000;

pub const Value = union(enum) {
    bytes: u64,
    /// Of the machine's physical memory, in hundredths of a percent.
    share: u16,
    count: u32,

    /// What this is against a machine with `phys` bytes.
    pub fn resolve(self: Value, phys: u64) u64 {
        return switch (self) {
            .bytes => |b| b,
            .share => |s| @intCast(@as(u128, phys) * s / 10_000),
            .count => |c| c,
        };
    }
};

pub const Metric = struct {
    warn: [max_warns]Value,
    warn_len: u8,
    kill: ?Value,
    for_ms: u32,

    pub const none: Metric = .{ .warn = undefined, .warn_len = 0, .kill = null, .for_ms = default_for_ms };

    pub fn warns(self: *const Metric) []const Value {
        return self.warn[0..self.warn_len];
    }

    pub fn isEmpty(self: *const Metric) bool {
        return self.warn_len == 0 and self.kill == null;
    }
};

pub const Limits = struct {
    memory: Metric,
    processes: Metric,
    warn_tells_supervisor: bool,

    pub const none: Limits = .{ .memory = .none, .processes = .none, .warn_tells_supervisor = false };

    pub fn isEmpty(self: *const Limits) bool {
        return self.memory.isEmpty() and self.processes.isEmpty();
    }

    pub fn hasKill(self: *const Limits) bool {
        return self.memory.kill != null or self.processes.kill != null;
    }
};

pub const Error = error{Invalid};

/// `why` is set to what was wrong, naming the key, whenever this fails.
pub fn parse(v: std.json.Value, why: *[]const u8) Error!Limits {
    const obj = switch (v) {
        .object => |o| o,
        else => return bad(why, "limits: an object, like {\"memory\": {\"kill\": \"19G\"}}"),
    };
    var out: Limits = .none;
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.eql(u8, k, "memory")) {
            out.memory = try metric(e.value_ptr.*, .memory, why);
        } else if (std.mem.eql(u8, k, "processes")) {
            out.processes = try metric(e.value_ptr.*, .processes, why);
        } else if (std.mem.eql(u8, k, "warn_tells_supervisor")) {
            out.warn_tells_supervisor = switch (e.value_ptr.*) {
                .bool => |b| b,
                else => return bad(why, "limits.warn_tells_supervisor: true or false"),
            };
        } else return bad(why, "limits: only memory, processes and warn_tells_supervisor");
    }
    return out;
}

const Kind = enum { memory, processes };

fn metric(v: std.json.Value, kind: Kind, why: *[]const u8) Error!Metric {
    const obj = switch (v) {
        .object => |o| o,
        else => return bad(why, switch (kind) {
            .memory => "limits.memory: an object with warn, kill and for",
            .processes => "limits.processes: an object with warn, kill and for",
        }),
    };
    var m: Metric = .none;
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const x = e.value_ptr.*;
        if (std.mem.eql(u8, k, "warn")) {
            const items: []const std.json.Value = switch (x) {
                .array => |a| a.items,
                else => (&x)[0..1],
            };
            if (items.len == 0 or items.len > max_warns) return bad(why, switch (kind) {
                .memory => "limits.memory.warn: one to four lines",
                .processes => "limits.processes.warn: one to four lines",
            });
            for (items, 0..) |item, i| m.warn[i] = try value(item, kind, .warn, why);
            m.warn_len = @intCast(items.len);
        } else if (std.mem.eql(u8, k, "kill")) {
            m.kill = try value(x, kind, .kill, why);
        } else if (std.mem.eql(u8, k, "for")) {
            m.for_ms = duration(x) orelse return bad(why, switch (kind) {
                .memory => "limits.memory.for: a duration from 2s to 1h, like \"10s\" or \"2m\"",
                .processes => "limits.processes.for: a duration from 2s to 1h, like \"10s\" or \"2m\"",
            });
        } else return bad(why, switch (kind) {
            .memory => "limits.memory: only warn, kill and for",
            .processes => "limits.processes: only warn, kill and for",
        });
    }
    return m;
}

const Which = enum { warn, kill };

fn value(v: std.json.Value, kind: Kind, which: Which, why: *[]const u8) Error!Value {
    switch (kind) {
        .memory => {
            const s = switch (v) {
                .string => |s| s,
                else => null,
            };
            if (s) |text| if (size(text)) |got| return got;
            return bad(why, switch (which) {
                .warn => "limits.memory.warn: a size like \"8G\" or \"512M\", or a share like \"40%\"",
                .kill => "limits.memory.kill: a size like \"19G\" or \"512M\", or a share like \"60%\"",
            });
        },
        .processes => {
            const n: ?i64 = switch (v) {
                .integer => |n| n,
                else => null,
            };
            if (n) |c| if (c >= 1 and c <= std.math.maxInt(u32)) return .{ .count = @intCast(c) };
            return bad(why, switch (which) {
                .warn => "limits.processes.warn: a whole number of processes, like 300",
                .kill => "limits.processes.kill: a whole number of processes, like 2000",
            });
        },
    }
}

/// "8G", "512M", "1.5G", "40%", "12.5%". Null when it is none of those, or
/// is zero, or is over 100%.
pub fn size(text: []const u8) ?Value {
    const t = std.mem.trim(u8, text, " ");
    if (t.len < 2) return null;
    const unit = std.ascii.toUpper(t[t.len - 1]);
    // Hundredths, from at most two decimals: exact, no float.
    const n = hundredths(t[0 .. t.len - 1]) orelse return null;
    if (n == 0) return null;
    if (unit == '%') {
        if (n > 10_000) return null;
        return .{ .share = @intCast(n) };
    }
    const shift: u6 = switch (unit) {
        'K' => 10,
        'M' => 20,
        'G' => 30,
        'T' => 40,
        else => return null,
    };
    const bytes = std.math.mul(u64, n, @as(u64, 1) << shift) catch return null;
    return .{ .bytes = bytes / 100 };
}

fn hundredths(t: []const u8) ?u64 {
    const dot = std.mem.indexOfScalar(u8, t, '.');
    const whole = t[0 .. dot orelse t.len];
    const frac = if (dot) |d| t[d + 1 ..] else "";
    if (whole.len == 0 or frac.len > 2 or (dot != null and frac.len == 0)) return null;
    for (whole) |c| if (!std.ascii.isDigit(c)) return null;
    for (frac) |c| if (!std.ascii.isDigit(c)) return null;
    var n = std.fmt.parseInt(u64, whole, 10) catch return null;
    n = std.math.mul(u64, n, 100) catch return null;
    var f: u64 = 0;
    for (0..2) |i| f = f * 10 + (if (i < frac.len) frac[i] - '0' else 0);
    return n + f;
}

/// "10s", "2m", "1h"; 2 s to 1 h. Null otherwise.
fn duration(v: std.json.Value) ?u32 {
    const t = switch (v) {
        .string => |s| s,
        else => return null,
    };
    if (t.len < 2) return null;
    const n = std.fmt.parseInt(u32, t[0 .. t.len - 1], 10) catch return null;
    const ms: u64 = @as(u64, n) * @as(u64, switch (t[t.len - 1]) {
        's' => 1_000,
        'm' => 60_000,
        'h' => 3_600_000,
        else => return null,
    });
    if (ms < 2_000 or ms > 3_600_000) return null;
    return @intCast(ms);
}

/// Null when these lines make sense on a machine with `phys` bytes;
/// otherwise what does not. A kill line at or under a warn line would kill
/// before it warned.
pub fn check(l: *const Limits, phys: u64) ?[]const u8 {
    for ([_]struct { m: *const Metric, msg: []const u8 }{
        .{ .m = &l.memory, .msg = "limits.memory: kill has to be above every warn line" },
        .{ .m = &l.processes, .msg = "limits.processes: kill has to be above every warn line" },
    }) |c| {
        const kill = c.m.kill orelse continue;
        for (c.m.warns()) |w| if (w.resolve(phys) >= kill.resolve(phys)) return c.msg;
    }
    return null;
}

fn bad(why: *[]const u8, msg: []const u8) Error {
    why.* = msg;
    return error.Invalid;
}

const testing = std.testing;

fn parseText(text: []const u8, why: *[]const u8) !Limits {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer p.deinit();
    return parse(p.value, why);
}

test "1993: limits read sizes, shares and counts, and leave out what is not named" {
    var why: []const u8 = "";
    const l = try parseText(
        \\{"memory": {"warn": ["8G", "40%"], "kill": "19.5G", "for": "30s"},
        \\ "processes": {"warn": 300}, "warn_tells_supervisor": true}
    , &why);
    try testing.expectEqual(@as(usize, 2), l.memory.warns().len);
    try testing.expectEqual(Value{ .bytes = 8 << 30 }, l.memory.warns()[0]);
    try testing.expectEqual(Value{ .share = 4000 }, l.memory.warns()[1]);
    try testing.expectEqual(Value{ .bytes = (39 << 30) / 2 }, l.memory.kill.?);
    try testing.expectEqual(@as(u32, 30_000), l.memory.for_ms);
    // A single warn line, not in an array.
    try testing.expectEqual(Value{ .count = 300 }, l.processes.warns()[0]);
    try testing.expectEqual(@as(?Value, null), l.processes.kill);
    try testing.expectEqual(default_for_ms, l.processes.for_ms);
    try testing.expect(l.warn_tells_supervisor);
    try testing.expect(l.hasKill());

    const empty = try parseText("{}", &why);
    try testing.expect(empty.isEmpty());
    try testing.expect(!empty.hasKill());
    try testing.expect(!empty.warn_tells_supervisor);
}

test "1993: a size is exact, and a share is of this machine" {
    try testing.expectEqual(Value{ .bytes = 512 << 20 }, size("512M").?);
    try testing.expectEqual(Value{ .bytes = 3 << 29 }, size("1.5g").?);
    try testing.expectEqual(Value{ .share = 1250 }, size("12.5%").?);
    try testing.expectEqual(@as(u64, 12 << 30), (Value{ .share = 3750 }).resolve(32 << 30));
    try testing.expectEqual(@as(u64, 32 << 30), (Value{ .share = 10_000 }).resolve(32 << 30));
}

test "1993: limits refuse what they cannot read, naming the key" {
    const Case = struct { text: []const u8, says: []const u8 };
    const cases = [_]Case{
        // A bare number for memory: bytes or gigabytes?
        .{ .text = "{\"memory\": {\"kill\": 19}}", .says = "limits.memory.kill" },
        .{ .text = "{\"memory\": {\"kill\": \"19\"}}", .says = "limits.memory.kill" },
        .{ .text = "{\"memory\": {\"kill\": \"0G\"}}", .says = "limits.memory.kill" },
        .{ .text = "{\"memory\": {\"warn\": [\"101%\"]}}", .says = "limits.memory.warn" },
        .{ .text = "{\"memory\": {\"warn\": [\"8Q\"]}}", .says = "limits.memory.warn" },
        .{ .text = "{\"memory\": {\"warn\": [\"1.234G\"]}}", .says = "limits.memory.warn" },
        .{ .text = "{\"memory\": {\"warn\": []}}", .says = "limits.memory.warn" },
        .{ .text = "{\"memory\": {\"warn\": [\"1G\",\"2G\",\"3G\",\"4G\",\"5G\"]}}", .says = "limits.memory.warn" },
        .{ .text = "{\"memory\": {\"for\": \"1s\"}}", .says = "limits.memory.for" },
        .{ .text = "{\"memory\": {\"for\": \"2d\"}}", .says = "limits.memory.for" },
        .{ .text = "{\"processes\": {\"kill\": \"300\"}}", .says = "limits.processes.kill" },
        .{ .text = "{\"processes\": {\"warn\": [0]}}", .says = "limits.processes.warn" },
        // Typos are refused, not ignored.
        .{ .text = "{\"memroy\": {\"kill\": \"19G\"}}", .says = "limits: only" },
        .{ .text = "{\"memory\": {\"kil\": \"19G\"}}", .says = "limits.memory: only" },
        .{ .text = "{\"warn_tells_supervisor\": 1}", .says = "limits.warn_tells_supervisor" },
        .{ .text = "[]", .says = "limits: an object" },
    };
    for (cases) |c| {
        var why: []const u8 = "";
        if (parseText(c.text, &why)) |_| {
            std.debug.print("accepted: {s}\n", .{c.text});
            return error.TestUnexpectedResult;
        } else |_| {}
        try testing.expect(std.mem.startsWith(u8, why, c.says));
    }
}

test "1993: a kill line has to be above every warn line, on this machine" {
    var why: []const u8 = "";
    const ok = try parseText("{\"memory\": {\"warn\": [\"8G\", \"40%\"], \"kill\": \"19G\"}}", &why);
    try testing.expectEqual(@as(?[]const u8, null), check(&ok, 32 << 30));
    // 40% of 64 GB is 25.6 GB: over the kill line on that machine only.
    try testing.expect(check(&ok, 64 << 30) != null);
    const procs = try parseText("{\"processes\": {\"warn\": [300], \"kill\": 300}}", &why);
    try testing.expectEqualStrings("limits.processes: kill has to be above every warn line", check(&procs, 32 << 30).?);
}
