//! How the control room's last ask of each group's supervisor went (task
//! 1671).
//!
//! "Ask the Supervisor for a Progress Report" is a mention, and a mention
//! refused for a reason that clears by itself is typed again later
//! (`MentionRetry`). The act's own answer is the first try's: a host that
//! said "not delivered, will try again" from it had nothing to say the
//! retry went in -- measured on the test machine (#1666), the line still
//! said "will try again" forty seconds after the supervisor had the
//! sentence. This is the rest of the story, kept per group for the
//! snapshot: the ask's message, and whether it is still being tried, went
//! in, or was given up on.
//!
//! Only the last ask of a group is kept; one made after it replaces it, so
//! a host compares `seq` with the one it is waiting on. Nothing is kept
//! across a restart, and nor are the retries.

const ControlAsk = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const MentionRetry = @import("MentionRetry.zig");

pub const State = enum {
    /// Refused for a reason that clears by itself; it will be typed again.
    retrying,
    /// In the supervisor's terminal, first time or on a retry.
    delivered,
    /// Not typed, and not going to be.
    gave_up,
};

/// As the snapshot says it, on a group's row.
pub const Ask = struct {
    /// The group message the ask was kept as.
    seq: u64,
    state: State,
    /// The last refusal, as `group_post` names it (`MentionRetry.codeOf`);
    /// null once delivered. A static string.
    code: ?[]const u8,
};

/// Keyed by group name; the keys are owned.
asks: std.StringHashMapUnmanaged(Ask) = .empty,

pub fn deinit(self: *ControlAsk, alloc: Allocator) void {
    var it = self.asks.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    self.asks.deinit(alloc);
}

/// An ask was just made and kept as `seq`: refused with `err` (null when it
/// went in), and `pending` when that refusal was queued to be tried again.
pub fn asked(self: *ControlAsk, alloc: Allocator, group: []const u8, seq: u64, err: ?anyerror, pending: bool) Allocator.Error!void {
    const ask: Ask = if (err) |e|
        .{ .seq = seq, .state = if (pending) .retrying else .gave_up, .code = MentionRetry.codeOf(e) }
    else
        .{ .seq = seq, .state = .delivered, .code = null };
    const gop = try self.asks.getOrPut(alloc, group);
    if (!gop.found_existing) {
        gop.key_ptr.* = alloc.dupe(u8, group) catch |e| {
            self.asks.removeByPtr(gop.key_ptr);
            return e;
        };
    }
    gop.value_ptr.* = ask;
}

/// A retry of the mention kept as `seq` in `group` came to an end:
/// `gave_up` is the last refusal's code, null when it went in. True when
/// that was the group's last ask and it was still being tried -- what the
/// snapshot says has changed.
pub fn settled(self: *ControlAsk, group: []const u8, seq: u64, gave_up: ?[]const u8) bool {
    const ask = self.asks.getPtr(group) orelse return false;
    if (ask.seq != seq or ask.state != .retrying) return false;
    ask.* = if (gave_up) |code|
        .{ .seq = seq, .state = .gave_up, .code = code }
    else
        .{ .seq = seq, .state = .delivered, .code = null };
    return true;
}

/// The group's last ask; null when none was made since the start.
pub fn of(self: *const ControlAsk, group: []const u8) ?Ask {
    return self.asks.get(group);
}

/// The group is called `new` now; its ask goes with it.
pub fn renameGroup(self: *ControlAsk, alloc: Allocator, old: []const u8, new: []const u8) Allocator.Error!void {
    const ask = self.asks.get(old) orelse return;
    const key = try alloc.dupe(u8, new);
    errdefer alloc.free(key);
    self.forget(alloc, new);
    try self.asks.put(alloc, key, ask);
    self.forget(alloc, old);
}

/// The group was deleted (task 1659).
pub fn forget(self: *ControlAsk, alloc: Allocator, group: []const u8) void {
    const kv = self.asks.fetchRemove(group) orelse return;
    alloc.free(kv.key);
}

const testing = std.testing;

test "ControlAsk: a retried ask says it went in once the retry is typed, and only that ask" {
    const alloc = testing.allocator;
    var a: ControlAsk = .{};
    defer a.deinit(alloc);
    try testing.expect(a.of("web-app") == null);

    try a.asked(alloc, "web-app", 7, error.DraftInLine, true);
    try testing.expectEqual(State.retrying, a.of("web-app").?.state);
    try testing.expectEqualStrings("DraftInLine", a.of("web-app").?.code.?);

    // Another message's retry, or another group's, is not this ask's.
    try testing.expect(!a.settled("web-app", 6, null));
    try testing.expect(!a.settled("billing", 7, null));
    try testing.expectEqual(State.retrying, a.of("web-app").?.state);

    try testing.expect(a.settled("web-app", 7, null));
    try testing.expectEqual(Ask{ .seq = 7, .state = .delivered, .code = null }, a.of("web-app").?);
    // Said once: the next word on it changes nothing.
    try testing.expect(!a.settled("web-app", 7, "UserPresent"));
}

test "ControlAsk: a retry given up on says why; a refusal not tried again is given up at once" {
    const alloc = testing.allocator;
    var a: ControlAsk = .{};
    defer a.deinit(alloc);
    try a.asked(alloc, "web-app", 3, error.UserPresent, true);
    try testing.expect(a.settled("web-app", 3, "UserPresent"));
    try testing.expectEqual(State.gave_up, a.of("web-app").?.state);
    try testing.expectEqualStrings("UserPresent", a.of("web-app").?.code.?);

    try a.asked(alloc, "billing", 4, error.NoAgent, false);
    try testing.expectEqual(State.gave_up, a.of("billing").?.state);
    try a.asked(alloc, "billing", 5, null, false);
    try testing.expectEqual(Ask{ .seq = 5, .state = .delivered, .code = null }, a.of("billing").?);

    a.forget(alloc, "billing");
    try testing.expect(a.of("billing") == null);
    try testing.expect(a.of("web-app") != null);

    try a.renameGroup(alloc, "web-app", "site");
    try testing.expect(a.of("web-app") == null);
    try testing.expectEqual(State.gave_up, a.of("site").?.state);
}
