//! What to delete from a store that is kept going round: the rule, and
//! nothing that touches a disk (task 1511).
//!
//! **One shape for every kind.** A store that is not kept for ever is kept
//! by two numbers: how many days back, and how much in all. Past the first,
//! a file goes; past the second, the oldest go until what is left fits.
//! Logs, terminal transcripts at each of their three tiers, screenshots --
//! all of them are this one function with different numbers, so "how does
//! Polter decide what to forget" has one answer and one set of tests.
//!
//! **What is being written is never deleted.** A file another part of the
//! program holds open for appending is `live`: it counts towards the total,
//! because it is on the disk, and it is never chosen, because deleting it
//! would send the rest of today's writes into a file nobody can find. So a
//! store can sit over its limit for as long as the one live file alone is
//! bigger than the limit -- until the day turns and it stops being live.
//!
//! The Windows host's own logs follow the same shape and the same setting
//! names in Rust (`windows/hostlog`), because those files are the host's.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How a store is kept. Null in either field is "no limit on that".
pub const Limits = struct {
    /// A file dated more than this many days before today goes. Zero keeps
    /// only today.
    keep_days: ?u32,
    /// Past this many bytes in all, the oldest files go until it fits.
    max_bytes: ?u64,

    pub const unlimited: Limits = .{ .keep_days = null, .max_bytes = null };

    /// From the two settings as the config holds them: days, and megabytes.
    /// `std.math.maxInt` of either type is the config's `unlimited`.
    pub fn fromConfig(keep_days: u32, max_mb: u32) Limits {
        return .{
            .keep_days = if (keep_days == std.math.maxInt(u32)) null else keep_days,
            .max_bytes = if (max_mb == std.math.maxInt(u32)) null else @as(u64, max_mb) * 1024 * 1024,
        };
    }
};

/// One file of a store, as far as the rule cares.
pub const File = struct {
    /// The local day it is dated by, as `daylog.dayOf` writes it: 20261015.
    /// For a file with no day in its name, the day it was last written.
    day: u32,
    /// Its part within the day; ties within a day go oldest part first.
    part: u32 = 1,
    bytes: u64,
    /// Being written to now: counted, never chosen.
    live: bool = false,
};

/// The files to delete, as indices into `files`, oldest first. Caller owns
/// the slice.
pub fn plan(alloc: Allocator, files: []const File, today: u32, limits: Limits) Allocator.Error![]usize {
    var order: std.ArrayListUnmanaged(usize) = .empty;
    defer order.deinit(alloc);
    for (files, 0..) |f, i| if (!f.live) try order.append(alloc, i);
    std.mem.sort(usize, order.items, files, olderFirst);

    var out: std.ArrayListUnmanaged(usize) = .empty;
    errdefer out.deinit(alloc);

    var total: u64 = 0;
    for (files) |f| total += f.bytes;

    var kept: usize = 0;
    for (order.items) |i| {
        const f = files[i];
        if (limits.keep_days) |days| {
            if (ageInDays(f.day, today) > days) {
                try out.append(alloc, i);
                total -= f.bytes;
                continue;
            }
        }
        order.items[kept] = i;
        kept += 1;
    }

    if (limits.max_bytes) |max| {
        for (order.items[0..kept]) |i| {
            if (total <= max) break;
            try out.append(alloc, i);
            total -= files[i].bytes;
        }
    }

    return out.toOwnedSlice(alloc);
}

fn olderFirst(files: []const File, a: usize, b: usize) bool {
    const fa = files[a];
    const fb = files[b];
    if (fa.day != fb.day) return fa.day < fb.day;
    return fa.part < fb.part;
}

/// Mark which files of one terminal's (or one group's) directory are live:
/// the newest part of today. Earlier parts of today are finished -- the
/// writer moved on to the next -- and can go like any other.
pub fn markLive(files: []File, today: u32) void {
    var newest: ?usize = null;
    for (files, 0..) |f, i| {
        if (f.day != today) continue;
        if (newest == null or f.part > files[newest.?].part) newest = i;
    }
    if (newest) |i| files[i].live = true;
}

/// Whole days from `day` to `today`, both `yyyymmdd`. Negative when `day`
/// is after `today` (a clock that went back): such a file is the newest
/// there is, and is treated as such.
pub fn ageInDays(day: u32, today: u32) i64 {
    return epochDay(today) - epochDay(day);
}

/// Days since 1970-01-01 of a `yyyymmdd`, by the civil calendar.
fn epochDay(day: u32) i64 {
    const y0: i64 = @intCast(day / 10000);
    const m: i64 = @intCast(day / 100 % 100);
    const d: i64 = @intCast(day % 100);
    // Howard Hinnant's days_from_civil.
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Which of a terminal transcript's three tiers a file is in.
///
/// Ordered: a file that is two things at once is the higher one, and is
/// kept by that tier's rule -- a morning in a group and an afternoon on
/// its own make one file that belongs to the group.
pub const Tier = enum {
    /// Written while the terminal was a member of a group.
    group,
    /// Not in a group, but in a project's tab.
    project,
    /// Neither.
    none,
};

/// A stretch of time, in local days, during which something held: a
/// terminal was in a group, or in a project. `to` null is still holding,
/// or never said to have stopped.
pub const Days = struct {
    from: u32,
    to: ?u32,

    fn covers(self: Days, day: u32) bool {
        if (day < self.from) return false;
        return if (self.to) |to| day <= to else true;
    }
};

/// The tier of one file, dated `day`, of a terminal that was in groups
/// during `groups` and in projects during `projects`. Any overlap counts:
/// keeping a file a tier too long costs disk, deleting one a tier too soon
/// costs the record.
pub fn tierOf(day: u32, groups: []const Days, projects: []const Days) Tier {
    for (groups) |g| if (g.covers(day)) return .group;
    for (projects) |p| if (p.covers(day)) return .project;
    return .none;
}

const testing = std.testing;

fn planOf(files: []const File, today: u32, limits: Limits) ![]usize {
    return plan(testing.allocator, files, today, limits);
}

test "a file older than the days kept goes, one inside them stays" {
    const files = [_]File{
        .{ .day = 20261001, .bytes = 10 },
        .{ .day = 20261014, .bytes = 10 },
    };
    const out = try planOf(&files, 20261015, .{ .keep_days = 7, .max_bytes = null });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(usize, &.{0}, out);
}

test "exactly the days kept is still kept" {
    const files = [_]File{.{ .day = 20261008, .bytes = 10 }};
    const out = try planOf(&files, 20261015, .{ .keep_days = 7, .max_bytes = null });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "zero days keeps only today" {
    const files = [_]File{
        .{ .day = 20261014, .bytes = 10 },
        .{ .day = 20261015, .bytes = 10 },
    };
    const out = try planOf(&files, 20261015, .{ .keep_days = 0, .max_bytes = null });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(usize, &.{0}, out);
}

test "over the total, the oldest go until it fits" {
    const files = [_]File{
        .{ .day = 20261013, .bytes = 40 },
        .{ .day = 20261011, .bytes = 40 },
        .{ .day = 20261012, .bytes = 40 },
    };
    const out = try planOf(&files, 20261015, .{ .keep_days = null, .max_bytes = 80 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(usize, &.{1}, out);
}

test "within one day the earlier part goes first" {
    const files = [_]File{
        .{ .day = 20261014, .part = 2, .bytes = 50 },
        .{ .day = 20261014, .part = 1, .bytes = 50 },
    };
    const out = try planOf(&files, 20261015, .{ .keep_days = null, .max_bytes = 50 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(usize, &.{1}, out);
}

test "a live file counts towards the total but is never chosen" {
    const files = [_]File{
        .{ .day = 20261015, .bytes = 100, .live = true },
        .{ .day = 20261014, .bytes = 10 },
    };
    const out = try planOf(&files, 20261015, .{ .keep_days = null, .max_bytes = 50 });
    defer testing.allocator.free(out);
    // The old one goes because the live one alone is over; the live one stays.
    try testing.expectEqualSlices(usize, &.{1}, out);
}

test "a live file is not deleted for its age either" {
    const files = [_]File{.{ .day = 20260101, .bytes = 1, .live = true }};
    const out = try planOf(&files, 20261015, .{ .keep_days = 1, .max_bytes = 0 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "what the days already took is not taken twice for the total" {
    const files = [_]File{
        .{ .day = 20260101, .bytes = 100 },
        .{ .day = 20261014, .bytes = 30 },
        .{ .day = 20261015, .bytes = 30 },
    };
    const out = try planOf(&files, 20261015, .{ .keep_days = 30, .max_bytes = 60 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(usize, &.{0}, out);
}

test "unlimited deletes nothing" {
    const files = [_]File{.{ .day = 19990101, .bytes = 1 << 40 }};
    const out = try planOf(&files, 20261015, .unlimited);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "the config's unlimited is no limit, and megabytes are mebibytes" {
    const max = std.math.maxInt(u32);
    try testing.expectEqual(Limits.unlimited, Limits.fromConfig(max, max));
    const l = Limits.fromConfig(14, 128);
    try testing.expectEqual(@as(?u32, 14), l.keep_days);
    try testing.expectEqual(@as(?u64, 128 * 1024 * 1024), l.max_bytes);
}

test "age counts calendar days across a month and a leap year" {
    try testing.expectEqual(@as(i64, 1), ageInDays(20240229, 20240301));
    try testing.expectEqual(@as(i64, 1), ageInDays(20231231, 20240101));
    try testing.expectEqual(@as(i64, 366), ageInDays(20240101, 20250101));
    try testing.expectEqual(@as(i64, -1), ageInDays(20261016, 20261015));
}

test "only the newest part of today is live" {
    var files = [_]File{
        .{ .day = 20261015, .part = 1, .bytes = 1 },
        .{ .day = 20261015, .part = 3, .bytes = 1 },
        .{ .day = 20261015, .part = 2, .bytes = 1 },
        .{ .day = 20261014, .part = 9, .bytes = 1 },
    };
    markLive(&files, 20261015);
    try testing.expect(!files[0].live);
    try testing.expect(files[1].live);
    try testing.expect(!files[2].live);
    try testing.expect(!files[3].live);
}

test "nothing from today, nothing live" {
    var files = [_]File{.{ .day = 20261014, .bytes = 1 }};
    markLive(&files, 20261015);
    try testing.expect(!files[0].live);
}

test "a file on a day the terminal was in a group is the group's" {
    const groups = [_]Days{.{ .from = 20261010, .to = 20261012 }};
    const projects = [_]Days{.{ .from = 20261001, .to = null }};
    try testing.expectEqual(Tier.group, tierOf(20261010, &groups, &projects));
    try testing.expectEqual(Tier.group, tierOf(20261012, &groups, &projects));
    try testing.expectEqual(Tier.project, tierOf(20261013, &groups, &projects));
    try testing.expectEqual(Tier.project, tierOf(20261009, &groups, &projects));
}

test "a stretch that never ended covers every day after it began" {
    const groups = [_]Days{.{ .from = 20261010, .to = null }};
    try testing.expectEqual(Tier.group, tierOf(20991231, &groups, &.{}));
    try testing.expectEqual(Tier.none, tierOf(20261009, &groups, &.{}));
}

test "no stretches, no tier" {
    try testing.expectEqual(Tier.none, tierOf(20261015, &.{}, &.{}));
}
