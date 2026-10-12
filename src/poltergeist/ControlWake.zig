//! The one thing that wakes the control room when nothing has happened: a
//! thread that sleeps until the next moment something could change on its
//! own, and not a moment before.
//!
//! **Not a timer with a period.** While there is no such moment -- nobody
//! in a turn, no worker's first minute running, no snooze counting down --
//! the thread is blocked with no timeout at all, and the process is not
//! woken on the control room's account. `ControlRoom.refresh` says when the
//! next moment is; `arm` is how it gets here.
//!
//! It only says that the moment has come (`fire`). Working out what changed
//! is the app thread's, where everything it would read lives.

const ControlWake = @This();

const std = @import("std");
const Io = std.Io;

io: Io,
fire: *const fn (ctx: *anyopaque) void,
ctx: *anyopaque,

mutex: Io.Mutex = .init,
/// When to fire, or null to wait until told otherwise.
deadline: ?Io.Clock.Timestamp = null,
/// The `at_ms` the deadline was set from, so asking for the same moment
/// twice does not wake the thread to be told what it knows.
armed_ms: ?u64 = null,
stopping: bool = false,

/// Bumped on every change, and what the thread sleeps on.
generation: std.atomic.Value(u32) = .init(0),

/// How many times the thread has come out of its sleep, for the test that
/// says it does not when there is nothing to wait for.
wakeups: std.atomic.Value(u64) = .init(0),

thread: ?std.Thread = null,

pub fn start(self: *ControlWake) std.Thread.SpawnError!void {
    self.thread = try std.Thread.spawn(.{}, main, .{self});
}

pub fn stop(self: *ControlWake) void {
    const t = self.thread orelse return;
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    self.mutex.unlock(self.io);
    self.poke();
    t.join();
    self.thread = null;
}

/// Fire once at `at_ms`, given that it is `now_ms` now; null for never.
/// Replaces whatever was asked before.
pub fn arm(self: *ControlWake, at_ms: ?u64, now_ms: u64) void {
    self.mutex.lockUncancelable(self.io);
    if (self.armed_ms == at_ms) {
        self.mutex.unlock(self.io);
        return;
    }
    self.armed_ms = at_ms;
    self.deadline = if (at_ms) |at| .fromNow(self.io, .{
        .raw = .fromMilliseconds(waitMs(at, now_ms)),
        // The clock the bus counts on: it stops while the machine sleeps,
        // and so does everything this is waiting for.
        .clock = .awake,
    }) else null;
    self.mutex.unlock(self.io);
    self.poke();
}

/// The longest this will wait. Nothing it is asked about is further off
/// than a snooze, and a snooze "until next year" is as good as asked for
/// again after a restart.
pub const longest_wait_ms: u64 = 366 * std.time.ms_per_day;

/// How long to sleep for a moment `at_ms` away, for the clock's signed
/// type: never negative, never more than `longest_wait_ms`.
///
/// **Safe for any two numbers.** This was `@intCast(at -| now_ms)`, which
/// is only right while every caller hands in a moment near now -- and one
/// did not (a sentinel of `maxInt(u64)`, see `Bus.Agent.expected_said`).
/// In a debug build that is a panic on the app thread; in a release build
/// it is whatever the wrapped number happens to be. Woken early, the
/// caller works out again what there is to wait for; that is all an early
/// wake costs.
pub fn waitMs(at_ms: u64, now_ms: u64) i64 {
    return @intCast(@min(at_ms -| now_ms, longest_wait_ms));
}

test "ControlRoom wake thread: any moment at all can be asked for" {
    try testing.expectEqual(@as(i64, 30), waitMs(1_030, 1_000));
    // Already past is now, not a negative wait.
    try testing.expectEqual(@as(i64, 0), waitMs(1_000, 5_000));
    // The end of time, and everything past what the clock's type holds.
    const longest: i64 = @intCast(longest_wait_ms);
    try testing.expectEqual(longest, waitMs(std.math.maxInt(u64), 0));
    try testing.expectEqual(longest, waitMs(std.math.maxInt(u64), 1_000));
    try testing.expectEqual(longest, waitMs(@as(u64, std.math.maxInt(i64)) + 1, 0));
    try testing.expectEqual(longest, waitMs(longest_wait_ms + 1, 0));
    try testing.expectEqual(longest - 1, waitMs(longest_wait_ms - 1, 0));

    // And through the door it was a crash at: armed for the end of time,
    // the thread simply does not fire.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var c: Counter = .{};
    var w: ControlWake = .{ .io = io, .fire = Counter.fire, .ctx = &c };
    try w.start();
    defer w.stop();
    w.arm(std.math.maxInt(u64), 1_000);
    try Io.sleep(io, .fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(u32, 0), c.fired.load(.monotonic));
    // Still armable for something real afterwards.
    w.arm(1_020, 1_000);
    try waitFor(io, &c, 1, 5_000);
}

fn poke(self: *ControlWake) void {
    _ = self.generation.fetchAdd(1, .release);
    self.io.futexWake(u32, &self.generation.raw, 1);
}

fn main(self: *ControlWake) void {
    while (true) {
        const seen = self.generation.load(.acquire);

        self.mutex.lockUncancelable(self.io);
        const stopping = self.stopping;
        const deadline = self.deadline;
        self.mutex.unlock(self.io);
        if (stopping) return;

        self.io.futexWaitTimeout(
            u32,
            &self.generation.raw,
            seen,
            if (deadline) |d| .{ .deadline = d } else .none,
        ) catch return;
        _ = self.wakeups.fetchAdd(1, .monotonic);

        // Told something new: go round and read it.
        if (self.generation.load(.acquire) != seen) continue;

        // Otherwise it is the deadline, or a wake nobody asked for.
        const d = deadline orelse continue;
        if (d.durationFromNow(self.io).raw.nanoseconds > 0) continue;

        self.mutex.lockUncancelable(self.io);
        const still = self.generation.load(.acquire) == seen;
        if (still) {
            self.deadline = null;
            self.armed_ms = null;
        }
        self.mutex.unlock(self.io);
        if (still) self.fire(self.ctx);
    }
}

const testing = std.testing;

const Counter = struct {
    fired: std.atomic.Value(u32) = .init(0),

    fn fire(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        _ = self.fired.fetchAdd(1, .monotonic);
    }
};

fn waitFor(io: Io, c: *const Counter, want: u32, within_ms: u64) !void {
    var waited: u64 = 0;
    while (c.fired.load(.monotonic) < want) : (waited += 5) {
        if (waited >= within_ms) return error.TestNeverFired;
        try Io.sleep(io, .fromMilliseconds(5), .awake);
    }
}

test "ControlRoom wake thread: with nothing to wait for it does not wake at all" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var c: Counter = .{};
    var w: ControlWake = .{ .io = io, .fire = Counter.fire, .ctx = &c };
    try w.start();
    defer w.stop();

    // Long against the 30 ms the armed case below takes to fire.
    try Io.sleep(io, .fromMilliseconds(300), .awake);
    try testing.expectEqual(@as(u32, 0), c.fired.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), w.wakeups.load(.monotonic));

    // Asking for "never" again changes nothing and wakes nothing.
    w.arm(null, 0);
    try Io.sleep(io, .fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(u64, 0), w.wakeups.load(.monotonic));
}

test "ControlRoom wake thread: it fires once at the moment asked for, and then waits again" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var c: Counter = .{};
    var w: ControlWake = .{ .io = io, .fire = Counter.fire, .ctx = &c };
    try w.start();
    defer w.stop();

    w.arm(1_030, 1_000);
    try testing.expectEqual(@as(u32, 0), c.fired.load(.monotonic));
    try waitFor(io, &c, 1, 5_000);

    // Once, not every 30 ms from then on.
    try Io.sleep(io, .fromMilliseconds(200), .awake);
    try testing.expectEqual(@as(u32, 1), c.fired.load(.monotonic));

    // A later moment replaces an earlier one that has not come yet.
    w.arm(60_000, 0);
    w.arm(20, 0);
    try waitFor(io, &c, 2, 5_000);
    try Io.sleep(io, .fromMilliseconds(100), .awake);
    try testing.expectEqual(@as(u32, 2), c.fired.load(.monotonic));
}
