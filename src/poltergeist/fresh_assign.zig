//! `task_assign` with `fresh` (#64), between the /clear and the line that
//! tells the worker the task is theirs.
//!
//! **Why it waits at all.** The line is typed with a return, and typed
//! while the CLI is still throwing its context away it could be thrown away
//! with it, or land in a prompt that is about to be redrawn. Claude Code
//! says when the clear is done -- a `SessionStart` hook with `source:
//! clear`, and a new session id -- so the request is held until that
//! arrives, or `wait_ms` passes. Past that the line is typed anyway and the
//! reply says `cleared: unconfirmed`, rather than leaving the supervisor
//! with a task that was never handed over.
//!
//! **Held, not blocked**: requests run on the app thread, which is every
//! terminal's thread. `Server.Pending` is built for being answered later,
//! the way `persona_wait` and screenshots already are.
//!
//! Its own file so the bookkeeping is tested without an app.

const std = @import("std");
const Allocator = std.mem.Allocator;

const AgentEvent = @import("agent_event.zig");
const Bus = @import("Bus.zig");

/// How long the line waits for the CLI to say it cleared.
pub const wait_ms: u64 = 10 * std.time.ms_per_s;

/// Whether an agent event says the session `before` was cleared: Claude
/// Code's `SessionStart` with `source: clear`, or a session that is not the
/// one it had. Any other event, or the same session starting again, is not.
pub fn clearedBy(event: AgentEvent.Kind, detail: ?[]const u8, session_id: ?[]const u8, before: ?[]const u8) bool {
    if (event != .session_started) return false;
    if (detail) |d| if (std.mem.eql(u8, d, "clear")) return true;
    const now = session_id orelse return false;
    const was = before orelse return true;
    return !std.mem.eql(u8, now, was);
}

pub fn Waits(comptime Held: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            held: Held,
            id: Bus.Id,
            task: u64,
            /// The session it had when /clear was typed. Owned.
            before: ?[]u8,
            deadline_ms: u64,
        };

        entries: std.ArrayListUnmanaged(Entry) = .empty,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.entries.items) |e| free(alloc, e);
            self.entries.deinit(alloc);
        }

        pub fn free(alloc: Allocator, e: Entry) void {
            if (e.before) |b| alloc.free(b);
        }

        pub fn park(
            self: *Self,
            alloc: Allocator,
            held: Held,
            id: Bus.Id,
            task: u64,
            before: ?[]const u8,
            now_ms: u64,
        ) Allocator.Error!void {
            const b: ?[]u8 = if (before) |v| try alloc.dupe(u8, v) else null;
            errdefer if (b) |v| alloc.free(v);
            try self.entries.append(alloc, .{
                .held = held,
                .id = id,
                .task = task,
                .before = b,
                .deadline_ms = now_ms +| wait_ms,
            });
        }

        /// One wait of `id`'s that this event finishes, taken out. Call
        /// until null: one clear can answer two assignments made to the
        /// same terminal in the same ten seconds.
        pub fn takeCleared(
            self: *Self,
            id: Bus.Id,
            event: AgentEvent.Kind,
            detail: ?[]const u8,
            session_id: ?[]const u8,
        ) ?Entry {
            for (self.entries.items, 0..) |e, i| {
                if (e.id != id) continue;
                if (!clearedBy(event, detail, session_id, e.before)) continue;
                return self.entries.orderedRemove(i);
            }
            return null;
        }

        /// One wait whose time is up, taken out. Call until null.
        pub fn takeExpired(self: *Self, now_ms: u64) ?Entry {
            for (self.entries.items, 0..) |e, i| {
                if (now_ms >= e.deadline_ms) return self.entries.orderedRemove(i);
            }
            return null;
        }
    };
}

const testing = std.testing;

test "fresh assign: only a session that started anew says the clear happened" {
    // Claude Code's own word for it.
    try testing.expect(clearedBy(.session_started, "clear", "s1", "s1"));
    // A new session id, whatever the source said.
    try testing.expect(clearedBy(.session_started, "startup", "s2", "s1"));
    // Nothing known before, and a session now.
    try testing.expect(clearedBy(.session_started, null, "s2", null));
    // The same session starting again (`resume`) is not a clear.
    try testing.expect(!clearedBy(.session_started, "resume", "s1", "s1"));
    // Any other event is not, even with a new id on it.
    try testing.expect(!clearedBy(.turn_started, "clear", "s2", "s1"));
    try testing.expect(!clearedBy(.turn_ended, null, "s2", "s1"));
}

test "fresh assign: the event finishes that terminal's wait and no other" {
    const W = Waits(u8);
    var w: W = .{};
    defer w.deinit(testing.allocator);
    try w.park(testing.allocator, 1, 0xa, 7, "old", 1_000);
    try w.park(testing.allocator, 2, 0xb, 8, "other", 1_000);

    // Another terminal clearing finishes nothing of 0xa's.
    try testing.expect(w.takeCleared(0xa, .session_started, "resume", "old") == null);
    const e = w.takeCleared(0xa, .session_started, "clear", "new").?;
    defer W.free(testing.allocator, e);
    try testing.expectEqual(@as(u64, 7), e.task);
    try testing.expectEqual(@as(u8, 1), e.held);
    try testing.expectEqual(@as(usize, 1), w.entries.items.len);
    try testing.expectEqual(@as(Bus.Id, 0xb), w.entries.items[0].id);
}

test "fresh assign: a wait runs out at ten seconds, not before" {
    const W = Waits(u8);
    var w: W = .{};
    defer w.deinit(testing.allocator);
    try w.park(testing.allocator, 1, 0xa, 7, null, 1_000);
    try testing.expect(w.takeExpired(1_000 + wait_ms - 1) == null);
    const e = w.takeExpired(1_000 + wait_ms).?;
    W.free(testing.allocator, e);
    try testing.expectEqual(@as(usize, 0), w.entries.items.len);
}
