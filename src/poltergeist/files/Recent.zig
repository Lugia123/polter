//! "Recently changed" for one working directory (task 2145 C5, PLAN §1.4).
//! Pure: every call is given the time, nothing here reads a clock.
//! **That time must come from a monotonic clock** (the app's elapsed time),
//! not the wall clock: after the wall clock is set back, `now - at_ms` is
//! negative and always inside the window, so every later change would be
//! merged into the old row and named after the old agent.
//!
//! Two sources feed one table, **one row per file**:
//!
//! 1. the hook, which knows *who* (`editing`: a PreToolUse has come and the
//!    turn has not ended; `stopped`: Stop or StopFailure, and the row becomes
//!    "done at that moment");
//! 2. the watcher, which only knows that something changed.
//!
//! **Who is the hook's.** When both see the same file within `dedupe_ms` of
//! each other they are one row and it keeps the hook's `who`. A change the
//! watcher alone sees, later than that, is somebody else's (a CLI without
//! hooks, the user's editor): the row's `who` goes back to null rather than
//! keep naming an agent that was not there.
//!
//! In memory only, at most `max_entries` rows, the oldest dropped. A table
//! belongs to a working directory and follows its group; this file does not
//! know either.

const Recent = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Two sightings of one file this close are one change.
pub const dedupe_ms: i64 = 2000;

pub const max_entries: usize = 200;

pub const State = enum {
    /// A hook said the agent is writing it and its turn has not ended.
    editing,
    /// Written. `Entry.at_ms` is when it was last seen changing, or when the
    /// turn that was writing it ended.
    done,
};

pub const Entry = struct {
    /// Relative to the working directory, owned by the table.
    path: []const u8,
    /// Which terminal or seat; null for a change only the watcher saw.
    who: ?[]const u8,
    state: State,
    at_ms: i64,
};

alloc: Allocator,
/// Newest first.
rows: std.ArrayList(Entry) = .empty,

pub fn init(alloc: Allocator) Recent {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Recent) void {
    for (self.rows.items) |e| self.free(e);
    self.rows.deinit(self.alloc);
}

pub fn entries(self: *const Recent) []const Entry {
    return self.rows.items;
}

fn free(self: *Recent, e: Entry) void {
    self.alloc.free(e.path);
    if (e.who) |w| self.alloc.free(w);
}

fn find(self: *const Recent, path: []const u8) ?usize {
    for (self.rows.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.path, path)) return i;
    }
    return null;
}

/// Put `e` (already owning its strings) in front, replacing row `at` if any.
/// **Ownership:** on success the table owns `e`; on error `e` is still the
/// caller's to free (the callers hold `errdefer`s for their copies). Freeing
/// it here as well freed the same bytes twice when the insert ran out of
/// memory.
fn put(self: *Recent, at: ?usize, e: Entry) Allocator.Error!void {
    if (at) |i| {
        self.free(self.rows.items[i]);
        _ = self.rows.orderedRemove(i);
    }
    try self.rows.insert(self.alloc, 0, e);
    while (self.rows.items.len > max_entries) {
        self.free(self.rows.pop().?);
    }
}

/// A PreToolUse for a file-writing tool: `who` is about to change `path`.
pub fn hookEditing(self: *Recent, path: []const u8, who: []const u8, now_ms: i64) Allocator.Error!void {
    const p = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(p);
    const w = try self.alloc.dupe(u8, who);
    errdefer self.alloc.free(w);
    try self.put(self.find(path), .{ .path = p, .who = w, .state = .editing, .at_ms = now_ms });
}

/// The watcher saw `path` change.
pub fn watched(self: *Recent, path: []const u8, now_ms: i64) Allocator.Error!void {
    const at = self.find(path);
    if (at) |i| {
        const old = self.rows.items[i];
        if (now_ms - old.at_ms <= dedupe_ms or old.state == .editing) {
            // The same change, or more of the same edit: one row, the hook's
            // `who`, moved to the front.
            var e = old;
            e.at_ms = @max(old.at_ms, now_ms);
            _ = self.rows.orderedRemove(i);
            self.rows.insert(self.alloc, 0, e) catch unreachable; // a slot was just freed
            return;
        }
    }
    const p = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(p);
    try self.put(at, .{ .path = p, .who = null, .state = .done, .at_ms = now_ms });
}

/// Stop or StopFailure of `who`'s turn: what it was writing is written.
pub fn stopped(self: *Recent, who: []const u8, now_ms: i64) void {
    for (self.rows.items) |*e| {
        if (e.state != .editing) continue;
        const w = e.who orelse continue;
        if (!std.mem.eql(u8, w, who)) continue;
        e.state = .done;
        e.at_ms = now_ms;
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "2569 C5: hook and watcher seeing one file within the window are one row, and it keeps the hook's who" {
    var r: Recent = .init(testing.allocator);
    defer r.deinit();
    try r.hookEditing("src/a.zig", "t1", 10_000);
    r.stopped("t1", 10_500);
    try r.watched("src/a.zig", 11_000);
    try testing.expectEqual(1, r.entries().len);
    try testing.expectEqualStrings("t1", r.entries()[0].who.?);
    try testing.expectEqual(11_000, r.entries()[0].at_ms);
}

test "2569 C5: a watcher-only change is nobody's, and later than the window it unnames the hook's who" {
    var r: Recent = .init(testing.allocator);
    defer r.deinit();
    try r.watched("b.txt", 1000);
    try testing.expect(r.entries()[0].who == null);
    try testing.expectEqual(State.done, r.entries()[0].state);

    try r.hookEditing("a.txt", "t1", 1000);
    r.stopped("t1", 1500);
    try r.watched("a.txt", 1500 + dedupe_ms + 1);
    try testing.expectEqual(2, r.entries().len);
    try testing.expect(r.entries()[0].who == null);
}

test "2569 C5: Stop turns what the same who was editing into done at that moment, and only theirs" {
    var r: Recent = .init(testing.allocator);
    defer r.deinit();
    try r.hookEditing("a", "t1", 100);
    try r.hookEditing("b", "t2", 200);
    r.stopped("t1", 900);
    // newest first: b, a
    try testing.expectEqualStrings("b", r.entries()[0].path);
    try testing.expectEqual(State.editing, r.entries()[0].state);
    try testing.expectEqual(State.done, r.entries()[1].state);
    try testing.expectEqual(900, r.entries()[1].at_ms);
    try testing.expectEqualStrings("t1", r.entries()[1].who.?);
}

test "2569 C5: more watcher events during an edit never end it, however late" {
    var r: Recent = .init(testing.allocator);
    defer r.deinit();
    try r.hookEditing("a", "t1", 0);
    try r.watched("a", 60_000);
    try testing.expectEqual(State.editing, r.entries()[0].state);
    try testing.expectEqualStrings("t1", r.entries()[0].who.?);
}

test "2569 C5: newest first, one row per file, and at most 200 rows" {
    var r: Recent = .init(testing.allocator);
    defer r.deinit();
    var buf: [16]u8 = undefined;
    for (0..max_entries + 5) |i| {
        const name = try std.fmt.bufPrint(&buf, "f{d}", .{i});
        try r.watched(name, @intCast(i * 10_000));
    }
    try testing.expectEqual(max_entries, r.entries().len);
    try testing.expectEqualStrings("f204", r.entries()[0].path);
    try testing.expectEqualStrings("f5", r.entries()[max_entries - 1].path);
    // Touching an old one moves it up and does not add a row.
    try r.watched("f5", 9_999_999);
    try testing.expectEqual(max_entries, r.entries().len);
    try testing.expectEqualStrings("f5", r.entries()[0].path);
}
