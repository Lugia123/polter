//! The thread that reads the machine every `period_ms` and splits it by
//! pane (task 1993, #1985): `procscan` then `ledger`, off the app thread.
//!
//! The app hands it the panes (`setPanes`) and takes what it found
//! (`take`), both under the mutex; `fire` says a reading is ready, and the
//! app picks it up on its next tick -- the same shape as `ControlWake`.
//! Nothing here judges anything: what a reading means is the app's.

const ResourceSampler = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const procscan = @import("procscan.zig");
const ledger = @import("ledger.zig");

/// How often the machine is read.
pub const period_ms: u64 = 2_000;

io: Io,
/// Used from the thread: must be safe to share.
alloc: Allocator,
fire: *const fn (ctx: *anyopaque) void,
ctx: *anyopaque,

mutex: Io.Mutex = .init,
panes: []ledger.Pane = &.{},
result: ?[]ledger.Usage = null,
stopping: bool = false,
generation: std.atomic.Value(u32) = .init(0),
thread: ?std.Thread = null,

/// How many readings were taken, for the test.
readings: std.atomic.Value(u64) = .init(0),

pub fn start(self: *ResourceSampler) std.Thread.SpawnError!void {
    self.thread = try std.Thread.spawn(.{}, main, .{self});
}

pub fn stop(self: *ResourceSampler) void {
    if (self.thread) |t| {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        _ = self.generation.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.generation.raw, 1);
        t.join();
        self.thread = null;
    }
    self.alloc.free(self.panes);
    self.panes = &.{};
    if (self.result) |r| self.alloc.free(r);
    self.result = null;
}

/// The panes the next reading is split by. Copied.
pub fn setPanes(self: *ResourceSampler, panes: []const ledger.Pane) Allocator.Error!void {
    const copy = try self.alloc.dupe(ledger.Pane, panes);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.alloc.free(self.panes);
    self.panes = copy;
}

/// The latest reading, if one came since the last take. The caller owns
/// it and frees it with `alloc`.
pub fn take(self: *ResourceSampler) ?[]ledger.Usage {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const r = self.result;
    self.result = null;
    return r;
}

fn main(self: *ResourceSampler) void {
    while (true) {
        const seen = self.generation.load(.acquire);
        self.mutex.lockUncancelable(self.io);
        const stopping = self.stopping;
        self.mutex.unlock(self.io);
        if (stopping) return;

        self.read() catch {};

        const deadline: Io.Clock.Timestamp = .fromNow(self.io, .{ .raw = .fromMilliseconds(period_ms), .clock = .awake });
        self.io.futexWaitTimeout(u32, &self.generation.raw, seen, .{ .deadline = deadline }) catch {};
    }
}

fn read(self: *ResourceSampler) Allocator.Error!void {
    self.mutex.lockUncancelable(self.io);
    const panes = self.alloc.dupe(ledger.Pane, self.panes) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    };
    self.mutex.unlock(self.io);
    defer self.alloc.free(panes);

    // No panes: no reading, but still a turn of the app's, which hands the
    // panes over -- the first reading of a session starts with none.
    const procs = if (panes.len == 0) try self.alloc.alloc(procscan.Proc, 0) else try procscan.scan(self.alloc);
    defer self.alloc.free(procs);
    const usage = try ledger.account(self.alloc, procs, panes);

    self.mutex.lockUncancelable(self.io);
    if (self.result) |old| self.alloc.free(old);
    self.result = usage;
    self.mutex.unlock(self.io);
    _ = self.readings.fetchAdd(1, .monotonic);
    self.fire(self.ctx);
}

test "1993: the sampler reads this process's tree and says so" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const Count = struct {
        n: std.atomic.Value(u32) = .init(0),
        fn fire(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            _ = c.n.fetchAdd(1, .release);
        }
    };
    var c: Count = .{};
    var s: ResourceSampler = .{ .io = threaded.io(), .alloc = testing.allocator, .fire = Count.fire, .ctx = &c };
    // This test binary as a pane of its own: its own pid is the root.
    try s.setPanes(&.{.{ .id = 0x1993, .root = @intCast(std.c.getpid()), .tty = null }});
    try s.start();
    defer s.stop();
    var waited: u32 = 0;
    while (c.n.load(.acquire) == 0 and waited < 5_000) : (waited += 10) try Io.sleep(threaded.io(), .fromMilliseconds(10), .awake);
    const got = s.take() orelse return error.NoReading;
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(u64, 0x1993), got[0].id);
    try testing.expect(got[0].procs >= 1);
    try testing.expect(got[0].mem > 1 << 20);
}
