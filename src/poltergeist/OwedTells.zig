//! The one-off lines Polter types into a terminal about its own standing --
//! "A supervisor is now watching this terminal", and the like
//! (`App.tellSurface`) -- that were refused for a reason that clears, kept
//! to be typed once it has (task 1682).
//!
//! **Why they need keeping.** Such a line is said once, when the standing
//! changes; nothing says it again. It used to be dropped when its terminal
//! refused it -- a key a moment ago, a draft in the line -- which was a
//! small loss. Since a permission box refuses it too (`Surface.mayType`,
//! `ApprovalOnScreen`), the refusal can last as long as the box does, and
//! the moment it was meant for -- a worker told it is now being watched --
//! went by with nothing said at all.
//!
//! **At most one per terminal, the latest.** These lines describe a state,
//! and a later one says what is true now: a terminal that was watched and
//! then let go is told the second, not both.
//!
//! **Typed once.** A line that was typed is forgotten; one refused again
//! stays for the next try; one for a terminal that is gone or has no agent
//! in it any more is forgotten too -- a standing line printed for nobody
//! later is not worth keeping.
//!
//! Its own file so the bookkeeping is tested without an app: `App` does
//! the typing, and hands the outcome back.

const OwedTells = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Id = Bus.Id;

/// The longest line kept: `App.tellSurface`'s buffer.
pub const max_line = 254;

alloc: Allocator,
lines: std.AutoArrayHashMapUnmanaged(Id, []u8) = .empty,

pub fn deinit(self: *OwedTells) void {
    for (self.lines.values()) |l| self.alloc.free(l);
    self.lines.deinit(self.alloc);
}

/// Keep `line` for `id`, in place of anything kept for it before.
pub fn owe(self: *OwedTells, id: Id, line: []const u8) Allocator.Error!void {
    if (line.len > max_line) return;
    const copy = try self.alloc.dupe(u8, line);
    errdefer self.alloc.free(copy);
    const got = try self.lines.getOrPut(self.alloc, id);
    if (got.found_existing) self.alloc.free(got.value_ptr.*);
    got.value_ptr.* = copy;
}

/// What became of one try.
pub const Outcome = enum {
    /// Typed: forgotten.
    typed,
    /// Refused again for a reason that clears: kept for the next try.
    refused,
    /// The terminal is gone, or has no agent in it: forgotten.
    gone,
};

/// Try every line kept: `try_fn(ctx, id, line)` says what happened to it.
pub fn pay(
    self: *OwedTells,
    ctx: anytype,
    comptime try_fn: fn (@TypeOf(ctx), Id, []const u8) Outcome,
) void {
    var i: usize = 0;
    while (i < self.lines.count()) {
        const id = self.lines.keys()[i];
        const line = self.lines.values()[i];
        switch (try_fn(ctx, id, line)) {
            .refused => i += 1,
            .typed, .gone => {
                self.alloc.free(line);
                self.lines.swapRemoveAt(i);
            },
        }
    }
}

pub fn count(self: *const OwedTells) usize {
    return self.lines.count();
}

const testing = std.testing;

const Recorder = struct {
    calls: usize = 0,
    last: []const u8 = "",
    outcome: Outcome = .typed,

    fn try_(self: *Recorder, _: Id, line: []const u8) Outcome {
        self.calls += 1;
        self.last = line;
        return self.outcome;
    }
};

test "1682: an owed standing line is typed once the refusal clears, and only once" {
    var o: OwedTells = .{ .alloc = testing.allocator };
    defer o.deinit();
    try o.owe(0xa1, "[Polter] A supervisor is now watching this terminal");

    // Refused again while the box is up: kept, and tried every time.
    var r: Recorder = .{ .outcome = .refused };
    o.pay(&r, Recorder.try_);
    o.pay(&r, Recorder.try_);
    try testing.expectEqual(@as(usize, 2), r.calls);
    try testing.expectEqual(@as(usize, 1), o.count());

    // The box answered: typed, and then never again.
    r.outcome = .typed;
    o.pay(&r, Recorder.try_);
    try testing.expectEqual(@as(usize, 3), r.calls);
    o.pay(&r, Recorder.try_);
    try testing.expectEqual(@as(usize, 3), r.calls);
    try testing.expectEqual(@as(usize, 0), o.count());
}

test "1682: a later standing line takes the place of the one owed before it" {
    var o: OwedTells = .{ .alloc = testing.allocator };
    defer o.deinit();
    try o.owe(0xa1, "watched");
    try o.owe(0xb2, "held");
    try o.owe(0xa1, "let go");
    try testing.expectEqual(@as(usize, 2), o.count());
    // 0xa1 is owed "let go", not "watched".
    try testing.expectEqualStrings("let go", o.lines.get(0xa1).?);
    var r: Recorder = .{};
    o.pay(&r, Recorder.try_);
    try testing.expectEqual(@as(usize, 2), r.calls);
    try testing.expectEqual(@as(usize, 0), o.count());
}

test "1682: a line owed to a terminal that is gone is forgotten, not kept" {
    var o: OwedTells = .{ .alloc = testing.allocator };
    defer o.deinit();
    try o.owe(0xa1, "watched");
    var r: Recorder = .{ .outcome = .gone };
    o.pay(&r, Recorder.try_);
    try testing.expectEqual(@as(usize, 0), o.count());
    o.pay(&r, Recorder.try_);
    try testing.expectEqual(@as(usize, 1), r.calls);
}
