//! Which terminal was where, worked out from what `SessionLog` and
//! `TerminalMeta` wrote down (task 1511). Nothing here reads or writes a
//! file: it is handed both records, already read.
//!
//! Two questions, the same facts:
//!
//!   * the sweep asks, of each terminal, which days it was in a group and
//!     which in a project, to keep its transcript by the right tier;
//!   * the record tools ask, of a group, which terminals were in it and
//!     when, to find and to cut what a supervisor may read.

const std = @import("std");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");
const Retention = @import("Retention.zig");
const SessionLog = @import("SessionLog.zig");
const TerminalMeta = @import("TerminalMeta.zig");

/// One terminal's days in groups and in projects.
pub const Where = struct {
    groups: []Retention.Days,
    projects: []Retention.Days,
};

/// How a moment becomes a local day. `daylog.dayOf` in the app; a fixed
/// one in tests, so that they do not depend on the machine's time zone.
pub const DayOf = *const fn (at_ms: i64) u32;

/// Where `terminal` was, in local days. Allocated from `arena`.
pub fn whereWas(
    arena: Allocator,
    terminal: u64,
    sessions: SessionLog.Record,
    notes: []const TerminalMeta.Note,
    dayOf: DayOf,
) Allocator.Error!Where {
    var groups: std.ArrayListUnmanaged(Retention.Days) = .empty;
    for (sessions.stints) |s| {
        if (s.terminal != terminal) continue;
        try groups.append(arena, .{
            .from = dayOf(s.from_ms),
            .to = if (s.to_ms) |to| dayOf(to) else null,
        });
    }

    // A project note holds until the next one for the same terminal.
    var projects: std.ArrayListUnmanaged(Retention.Days) = .empty;
    var open: ?u32 = null;
    for (notes) |n| {
        if (n.terminal != terminal or n.kind != .project) continue;
        if (open) |from| {
            try projects.append(arena, .{ .from = from, .to = dayOf(n.at_ms) });
            open = null;
        }
        if (n.project != null) open = dayOf(n.at_ms);
    }
    if (open) |from| try projects.append(arena, .{ .from = from, .to = null });

    return .{ .groups = try groups.toOwnedSlice(arena), .projects = try projects.toOwnedSlice(arena) };
}

/// The stretches of time, in milliseconds, during which `terminal` was a
/// member of `group`. What a group's supervisor may read of that
/// terminal's transcript is the lines written inside one of these.
pub fn stintsIn(
    arena: Allocator,
    group: []const u8,
    terminal: u64,
    sessions: SessionLog.Record,
) Allocator.Error![]const SessionLog.Stint {
    var out: std.ArrayListUnmanaged(SessionLog.Stint) = .empty;
    for (sessions.stints) |s| {
        if (s.terminal == terminal and std.mem.eql(u8, s.group, group)) try out.append(arena, s);
    }
    return out.toOwnedSlice(arena);
}

/// Whether a line written at `at_ms` falls inside one of `stints`.
pub fn inside(stints: []const SessionLog.Stint, at_ms: i64) bool {
    for (stints) |s| {
        if (at_ms < s.from_ms) continue;
        if (s.to_ms) |to| if (at_ms > to) continue;
        return true;
    }
    return false;
}

/// Whether `terminal` was ever in any group.
pub fn everInAGroup(terminal: u64, sessions: SessionLog.Record) bool {
    for (sessions.stints) |s| if (s.terminal == terminal) return true;
    return false;
}

const testing = std.testing;

/// A day per thousand milliseconds from 20261001: enough to tell days apart.
fn fakeDay(at_ms: i64) u32 {
    return 20261001 + @as(u32, @intCast(@divFloor(at_ms, 1000)));
}

test "a stint becomes the days it covered, an open one has no end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stints = [_]SessionLog.Stint{
        .{ .group = "build", .terminal = 0x11, .from_ms = 1000, .to_ms = 3500, .role = "", .cli = "", .inferred = false },
        .{ .group = "ops", .terminal = 0x11, .from_ms = 5000, .to_ms = null, .role = "", .cli = "", .inferred = true },
        .{ .group = "build", .terminal = 0x22, .from_ms = 0, .to_ms = null, .role = "", .cli = "", .inferred = false },
    };
    const rec: SessionLog.Record = .{ .stints = &stints, .sessions = &.{}, .ties = &.{} };
    const w = try whereWas(a, 0x11, rec, &.{}, fakeDay);
    try testing.expectEqual(@as(usize, 2), w.groups.len);
    try testing.expectEqual(Retention.Days{ .from = 20261002, .to = 20261004 }, w.groups[0]);
    try testing.expectEqual(Retention.Days{ .from = 20261006, .to = null }, w.groups[1]);
    try testing.expectEqual(Retention.Tier.group, Retention.tierOf(20261003, w.groups, w.projects));
    try testing.expectEqual(Retention.Tier.none, Retention.tierOf(20261005, w.groups, w.projects));
}

test "a project holds until the next note says otherwise" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const notes = [_]TerminalMeta.Note{
        .{ .terminal = 0x11, .at_ms = 1000, .kind = .project, .project = "polter" },
        .{ .terminal = 0x11, .at_ms = 2000, .kind = .agent, .session_id = "s" },
        .{ .terminal = 0x11, .at_ms = 4000, .kind = .project, .project = null },
        .{ .terminal = 0x11, .at_ms = 6000, .kind = .project, .project = "other" },
        .{ .terminal = 0x22, .at_ms = 0, .kind = .project, .project = "x" },
    };
    const rec: SessionLog.Record = .{ .stints = &.{}, .sessions = &.{}, .ties = &.{} };
    const w = try whereWas(a, 0x11, rec, &notes, fakeDay);
    try testing.expectEqual(@as(usize, 2), w.projects.len);
    try testing.expectEqual(Retention.Days{ .from = 20261002, .to = 20261005 }, w.projects[0]);
    try testing.expectEqual(Retention.Days{ .from = 20261007, .to = null }, w.projects[1]);
    try testing.expectEqual(Retention.Tier.project, Retention.tierOf(20261003, w.groups, w.projects));
    try testing.expectEqual(Retention.Tier.none, Retention.tierOf(20261006, w.groups, w.projects));
}

test "a line is readable only inside a stint in that group" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var stints = [_]SessionLog.Stint{
        .{ .group = "build", .terminal = 0x11, .from_ms = 100, .to_ms = 200, .role = "", .cli = "", .inferred = false },
        .{ .group = "ops", .terminal = 0x11, .from_ms = 300, .to_ms = null, .role = "", .cli = "", .inferred = false },
        .{ .group = "build", .terminal = 0x11, .from_ms = 500, .to_ms = null, .role = "", .cli = "", .inferred = false },
    };
    const rec: SessionLog.Record = .{ .stints = &stints, .sessions = &.{}, .ties = &.{} };
    const mine = try stintsIn(arena.allocator(), "build", 0x11, rec);
    try testing.expectEqual(@as(usize, 2), mine.len);
    try testing.expect(!inside(mine, 99));
    try testing.expect(inside(mine, 100));
    try testing.expect(inside(mine, 200));
    try testing.expect(!inside(mine, 201));
    // In "ops" then, not in "build".
    try testing.expect(!inside(mine, 400));
    try testing.expect(inside(mine, 9999));
    try testing.expect(everInAGroup(0x11, rec));
    try testing.expect(!everInAGroup(0x99, rec));
}
