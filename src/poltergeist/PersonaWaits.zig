//! The `persona_wait` requests that are being held rather than answered.
//!
//! A slot process, or `+mcp` itself, asks "tell me when this terminal's
//! persona might want me differently", and the honest answer is usually
//! "not yet". Holding the request is how that is said: the machinery
//! already exists, because `Server.Pending` is built for the app answering
//! later, so this is bookkeeping rather than plumbing.
//!
//! **Its own file so it can be tested without an app.** Held inside
//! `App.zig` the logic was reachable only through a running application,
//! which meant the one part of the persona path nobody could put a floor
//! under. Everything decided here now arrives as a parameter -- the clock,
//! and what the terminal currently wants -- so a test can construct the
//! situation instead of arranging for it.
//!
//! ⚠️ **What this does not cover, stated here so the coverage is not read
//! as more than it is:** that choosing a persona in a menu reaches these
//! functions at all. That is `App` and `Surface` wiring, and it is judged
//! by running the thing.

const PersonaWaits = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Server = @import("Server.zig");
const wire = @import("wire.zig");

/// How long a wait is held before it is answered with `timeout: true`.
///
/// ⚠️ **Swept when something else happens, not by a timer.** On a
/// completely idle app a parked wait can overstay this. That is a real
/// limitation rather than a rounding error, but it costs nothing on the
/// path this exists for: what wakes a wait is the persona changing, and a
/// persona changes because somebody did something. The timeout is for
/// noticing a connection that died quietly, and a dead connection on an
/// idle machine harms nobody until the machine stops being idle.
pub const timeout_ms: u64 = 30 * std.time.ms_per_s;

pub const Entry = struct {
    /// Ours until we complete it; a reference was taken when it was parked.
    pending: *Server.Pending,
    id: Bus.Id,

    /// The epoch the caller had when it asked.
    epoch: u64,

    /// Borrowed from the pending's own arena, so it lives exactly as long
    /// as the request does.
    slot: []const u8,

    /// When to give up and answer `timeout`.
    deadline_ms: u64,
};

/// What the caller is told when a wait is answered. The app works this out;
/// this file does not know what a persona is.
pub const Answer = struct {
    wanted: bool,
    epoch: u64,
};

alloc: Allocator,
io: std.Io,
entries: std.ArrayListUnmanaged(Entry) = .empty,

pub fn deinit(self: *PersonaWaits) void {
    self.entries.deinit(self.alloc);
    self.* = undefined;
}

/// Hold this request, if there is nothing to tell it yet.
///
/// Returns true when it has been parked and the caller must not answer it.
/// Returns false when the caller should answer it as usual.
///
/// `current_epoch` is where the terminal is now; `asked_epoch` is where the
/// caller thinks it is.
///
/// ⚠️ **A caller that is already behind is never parked.** It was away
/// while the persona changed, and putting it to sleep on an epoch that is
/// already history is how a wake gets missed -- it would then wait for a
/// change that has already happened, which is indistinguishable from
/// nothing happening.
pub fn park(
    self: *PersonaWaits,
    pending: *Server.Pending,
    id: Bus.Id,
    slot: []const u8,
    asked_epoch: u64,
    current_epoch: u64,
    now_ms: u64,
) bool {
    if (current_epoch != asked_epoch) return false;

    self.entries.append(self.alloc, .{
        .pending = pending,
        .id = id,
        .epoch = asked_epoch,
        .slot = slot,
        .deadline_ms = now_ms + timeout_ms,
    }) catch return false;

    // The submitting path's own `defer pending.release()` drops the
    // reference it was handed; this is the one that keeps the request alive
    // while it is parked.
    pending.retain();
    return true;
}

/// Everything parked for this terminal, taken out of the list.
///
/// The caller answers them -- it is the one that can work out `wanted` --
/// and each must be passed to `answer` exactly once.
pub fn take(self: *PersonaWaits, alloc: Allocator, id: Bus.Id) ![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (self.entries.items[i].id != id) {
            i += 1;
            continue;
        }
        try out.append(alloc, self.entries.swapRemove(i));
    }
    return out.toOwnedSlice(alloc);
}

/// Everything whose deadline has passed, taken out of the list.
pub fn takeExpired(self: *PersonaWaits, alloc: Allocator, now_ms: u64) ![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (now_ms < self.entries.items[i].deadline_ms) {
            i += 1;
            continue;
        }
        try out.append(alloc, self.entries.swapRemove(i));
    }
    return out.toOwnedSlice(alloc);
}

/// Answer one, and drop the reference that was held for it.
///
/// ⚠️ **`timed_out` is not "nothing happened".** It means the wait ran out
/// with this terminal's epoch where the caller left it. The caller still
/// has to compare `wanted` against what it had, because the epoch belongs
/// to the whole terminal: somebody switching an unrelated skill wakes every
/// slot on it without changing any of their answers.
pub fn answer(self: *PersonaWaits, e: Entry, a: Answer, timed_out: bool) void {
    defer e.pending.release();
    e.pending.complete(self.io, .{ .persona_slot = .{
        .wanted = a.wanted,
        .epoch = a.epoch,
        .timeout = timed_out,
    } });
}

/// Answer one with a failure, for when the app cannot work out an answer.
pub fn answerFailed(self: *PersonaWaits, e: Entry, code: []const u8, message: []const u8) void {
    defer e.pending.release();
    e.pending.complete(self.io, .{ .failed = .{ .code = code, .message = message } });
}

// ----------------------------------------------------------------- tests
//
// ⚠️ **If you take a guard out to check that a test can fail, leave the
// code compiling.** Removing the whole line here twice produced
// `error: unused function parameter` -- a compile error wearing the costume
// of a floor. The exit code is 1 either way, so "I broke it and it went
// red" is true and means nothing: the assertion was never reached. Write
// `if (false and cond)` or `if (now_ms == maxInt(u64))`, and then **read
// the line that came out red** rather than only its colour.

const testing = std.testing;

/// A `Pending` built by hand, which is the whole reason this file exists
/// apart from `App`.
///
/// Nothing here needs a connection: `complete` fills `response` and posts a
/// semaphore, and a post with nobody waiting on it does not block. So the
/// test can read the answer straight off the struct.
fn makePending(alloc: Allocator, slot: []const u8, epoch: u64) !*Server.Pending {
    const p = try alloc.create(Server.Pending);
    p.* = .{
        .alloc = alloc,
        .caller = .{ .terminal = 0x1234 },
        .request = .{ .persona_wait = .{ .slot = slot, .epoch = epoch } },
        .arena = .init(alloc),
    };
    return p;
}

test "persona waits: a parked request is not answered until something moves" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var waits: PersonaWaits = .{ .alloc = testing.allocator, .io = io };
    defer waits.deinit();

    const id: Bus.Id = 0xaaa;
    const p = try makePending(testing.allocator, "argus", 4);
    // The reference the submitting path would have dropped on its way out.
    // Without it the pending is never freed, which the testing allocator
    // reports as a leak -- and that report would be right.
    defer p.release();

    try testing.expect(waits.park(p, id, "argus", 4, 4, 0));

    // **The assertion the parking exists for.** Answering here would make
    // the long poll a poll, which is the thing the whole arrangement is
    // trying not to be.
    try testing.expectEqual(@as(?wire.Response, null), p.response);
    try testing.expectEqual(@as(usize, 1), waits.entries.items.len);

    const woken = try waits.take(testing.allocator, id);
    defer testing.allocator.free(woken);
    try testing.expectEqual(@as(usize, 1), woken.len);

    waits.answer(woken[0], .{ .wanted = true, .epoch = 5 }, false);

    const res = p.response orelse return error.NeverAnswered;
    switch (res) {
        .persona_slot => |v| {
            try testing.expect(v.wanted);
            try testing.expectEqual(@as(u64, 5), v.epoch);
            try testing.expect(!v.timeout);
        },
        else => return error.WrongResponse,
    }
    try testing.expectEqual(@as(usize, 0), waits.entries.items.len);
}

test "persona waits: a caller that is already behind is answered, not parked" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var waits: PersonaWaits = .{ .alloc = testing.allocator, .io = io };
    defer waits.deinit();

    const p = try makePending(testing.allocator, "argus", 4);
    defer p.release();

    // **The missed-wake half.** The terminal has moved on to 5 while this
    // caller was away at 4. Parking it would have it wait for a change that
    // has already happened -- which, from where it sits, is exactly the
    // same as nothing happening, for ever.
    try testing.expect(!waits.park(p, 0xaaa, "argus", 4, 5, 0));
    try testing.expectEqual(@as(usize, 0), waits.entries.items.len);
}

test "persona waits: only the ones that are due come out, and they say they timed out" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var waits: PersonaWaits = .{ .alloc = testing.allocator, .io = io };
    defer waits.deinit();

    const early = try makePending(testing.allocator, "argus", 1);
    defer early.release();
    const late = try makePending(testing.allocator, "kanban", 1);

    try testing.expect(waits.park(early, 0xaaa, "argus", 1, 1, 0));
    try testing.expect(waits.park(late, 0xbbb, "kanban", 1, 1, 10_000));

    // Half way to the second one's deadline: the first is due, the second
    // is not. A sweep that answered both would turn a long poll into a
    // short one for everybody.
    const due = try waits.takeExpired(testing.allocator, timeout_ms + 1);
    defer testing.allocator.free(due);

    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqual(@as(Bus.Id, 0xaaa), due[0].id);
    try testing.expectEqual(@as(usize, 1), waits.entries.items.len);

    waits.answer(due[0], .{ .wanted = false, .epoch = 1 }, true);

    switch (early.response orelse return error.NeverAnswered) {
        .persona_slot => |v| {
            try testing.expect(v.timeout);
            try testing.expect(!v.wanted);
        },
        else => return error.WrongResponse,
    }

    // Tidy the one still parked; nothing answered it, so its reference is
    // the one `park` took plus the one it was created with.
    const rest = try waits.take(testing.allocator, 0xbbb);
    defer testing.allocator.free(rest);
    waits.answer(rest[0], .{ .wanted = false, .epoch = 1 }, true);
    late.release();
}
