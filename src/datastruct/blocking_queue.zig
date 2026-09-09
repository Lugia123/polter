//! Blocking queue implementation aimed primarily for message passing
//! between threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compat_thread = @import("../lib/compat/thread.zig");

/// Returns a blocking queue implementation for type T.
///
/// This is tailor made for ghostty usage so it isn't meant to be maximally
/// generic, but I'm happy to make it more generic over time. Traits of this
/// queue that are specific to our usage:
///
///   - Fixed size. We expect our queue to quickly drain and also not be
///     too large so we prefer a fixed size queue for now.
///   - No blocking pop. We use an external event loop mechanism such as
///     eventfd to notify our waiter that there is no data available so
///     we don't need to implement a blocking pop.
///   - Drain function. Most queues usually pop one at a time. We have
///     a mechanism for draining since on every IO loop our TTY drains
///     the full queue so we can get rid of the overhead of a ton of
///     locks and bounds checking and do a one-time drain.
///
/// One key usage pattern is that our blocking queues are single producer
/// single consumer (SPSC). This should let us do some interesting optimizations
/// in the future. At the time of writing this, the blocking queue implementation
/// is purposely naive to build something quickly, but we should benchmark
/// and make this more optimized as necessary.
/// Something that can be woken up.
///
/// **The queue takes one so that "somebody is waiting" and "somebody has been
/// told" stop being two facts that a single fault can separate.** The comment
/// on `cond_not_full` says the empty side uses *external* notifiers; being
/// external is exactly what let a consumer sleep through a producer's wait,
/// and the producer then waited for a wake-up nobody was going to send.
///
/// ⚠️ **Contract, and it is not optional**: `func` is called **with the
/// queue's mutex held**. It must not block, and it must not re-enter this
/// queue. Today's Windows implementation only posts a completion packet and
/// returns, which satisfies both -- but that is the implementation being
/// convenient, not the interface being safe, so the requirement is written
/// here rather than left to be rediscovered.
pub const Waker = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,

    pub fn wake(self: Waker) void {
        self.func(self.ctx);
    }
};

pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        // The type we use for queue size types. We can optimize this
        // in the future to be the correct bit-size for our preallocated
        // size for this queue.
        pub const Size = u32;

        // The bounds of this queue. We recast this to Size so we can do math.
        const bounds: Size = @intCast(capacity);

        /// Specifies the timeout for an operation.
        pub const Timeout = union(enum) {
            /// Fail instantly (non-blocking).
            instant: void,

            /// Run forever or until interrupted
            forever: void,

            /// Nanoseconds
            ns: u64,
        };

        /// Our data. The values are undefined until they are written.
        data: [bounds]T = undefined,

        /// The next location to write (next empty loc) and next location
        /// to read (next non-empty loc). The number of written elements.
        write: Size = 0,
        read: Size = 0,
        len: Size = 0,

        /// The big mutex that must be held to read/write.
        mutex: std.Io.Mutex = .init,

        /// A CV for being notified when the queue is no longer full. This is
        /// used for writing. Note we DON'T have a CV for waiting on the
        /// queue not being EMPTY because we use external notifiers for that.
        cond_not_full: std.Io.Condition = .init,
        not_full_waiters: usize = 0,

        /// A smaller ceiling than the compile-time one, or zero for none.
        ///
        /// ⭐ **This exists so that "full" can be reached on purpose.** The
        /// state a full mailbox puts the system into could only be produced,
        /// before this, by the very fault that was fixed -- so the fix and
        /// "the fault no longer happens" became impossible to tell apart from
        /// the outside. A run that never fills the mailbox and a run whose
        /// handling of a full mailbox works produce the same evidence: none.
        ///
        /// ⚠️ **It changes when the queue is full, not what any caller does
        /// about it.** `full()` was always on this path and every caller
        /// already branched on it; only the number it compares against moves.
        /// Nothing is added to a path that did not already exist, which is
        /// the line an instrument may not cross.
        ///
        /// **Zero is off and zero is the default**, so a build nobody
        /// configured compares against the compile-time bound exactly as it
        /// did before this field existed.
        capacity_limit: Size = 0,

        /// Woken when a push is about to wait. See `Waker` for the contract.
        ///
        /// **Only when the queue is full**, never on the fast path: a push
        /// that fits is byte-for-byte what it was before this field existed.
        waker: ?Waker = null,

        /// Allocate the blocking queue on the heap.
        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);

            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .init,
                .cond_not_full = .init,
                .not_full_waiters = 0,
                .waker = null,
                .capacity_limit = 0,
            };

            return ptr;
        }

        /// Free all the resources for this queue. This should only be
        /// called once all producers and consumers have quit.
        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        /// Push a value to the queue. This returns the total size of the
        /// queue (unread items) after the push. A return value of zero
        /// means that the push failed.
        pub fn push(self: *Self, io: std.Io, value: T, timeout: Timeout) Size {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // The
            if (self.full()) {
                // **Woken here, in each arm that is about to sleep, and
                // nowhere else.** A producer going to sleep on a queue only
                // the consumer can drain is the one moment where "somebody is
                // waiting" and "somebody has been told" must not be able to
                // come apart -- and it is the only moment, which is why a
                // push that fits pays nothing.
                //
                // ⚠️ **Written twice rather than hoisted into a switch of its
                // own.** The first draft hoisted it and left the second
                // switch with an `unreachable` arm for `.instant`; that arm
                // really is unreachable, but `unreachable` is undefined
                // behaviour in a release build, and buying tidiness with UB
                // on a path this hot is a bad trade.
                switch (timeout) {
                    // If we're not waiting, then we failed to write.
                    .instant => return 0,

                    .forever => {
                        if (self.waker) |w| w.wake();
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.waitUncancelable(io, &self.mutex);
                    },

                    .ns => |ns| {
                        if (self.waker) |w| w.wake();
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        compat_thread.waitTimeout(
                            &self.cond_not_full,
                            io,
                            &self.mutex,
                            .{
                                .duration = .{
                                    .raw = .fromNanoseconds(ns),
                                    .clock = .awake,
                                },
                            },
                        ) catch return 0;
                    },
                }

                // If we're still full, then we failed to write. This can
                // happen in situations where we are interrupted.
                if (self.full()) return 0;
            }

            // Add our data and update our accounting
            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;

            return self.len;
        }

        /// Pop a value from the queue without blocking.
        pub fn pop(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // If we're empty we have nothing
            if (self.len == 0) return null;

            // Get the index we're going to read data from and do some
            // accounting. We don't copy the value here to avoid copying twice.
            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            // If we have consumers waiting on a full queue, notify.
            if (self.not_full_waiters > 0) self.cond_not_full.signal(io);

            return self.data[n];
        }

        /// Pop all values from the queue. This will hold the big mutex
        /// until `deinit` is called on the return value. This is used if
        /// you know you're going to "pop" and utilize all the values
        /// quickly to avoid many locks, bounds checks, and cv signals.
        pub fn drain(self: *Self, io: std.Io) DrainIterator {
            self.mutex.lockUncancelable(io);
            return .{ .queue = self };
        }

        pub const DrainIterator = struct {
            queue: *Self,

            pub fn next(self: *DrainIterator) ?T {
                if (self.queue.len == 0) return null;

                // Read and account
                const n = self.queue.read;
                self.queue.read += 1;
                if (self.queue.read >= bounds) self.queue.read -= bounds;
                self.queue.len -= 1;

                return self.queue.data[n];
            }

            pub fn deinit(self: *DrainIterator, io: std.Io) void {
                // If we have consumers waiting on a full queue, notify.
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.signal(io);

                // Unlock
                self.queue.mutex.unlock(io);
            }
        };

        /// Returns true if the queue is full. This is not public because
        /// it requires the lock to be held.
        inline fn full(self: *Self) bool {
            // ⚠️ **`>=`, not `==`.** With a ceiling below the compile-time
            // bound, a queue can be over it rather than exactly on it -- if
            // the ceiling is ever lowered while entries are in flight, `==`
            // would step straight past the only test that stops a write.
            if (self.capacity_limit > 0) return self.len >= self.capacity_limit;
            return self.len == bounds;
        }
    };
}

test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Should have no values
    try testing.expect(q.pop(io) == null);

    // Push until we're full
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(io, 3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(io, 4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 5, .{ .instant = {} }));

    // Pop!
    try testing.expect(q.pop(io).? == 1);
    try testing.expect(q.pop(io).? == 2);
    try testing.expect(q.pop(io).? == 3);
    try testing.expect(q.pop(io).? == 4);
    try testing.expect(q.pop(io) == null);

    // Drain does nothing
    var it = q.drain(io);
    try testing.expect(it.next() == null);
    it.deinit(io);

    // Verify we can still push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
}

test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));

    // Timed push should fail
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .ns = 1000 }));
}

test "a push that must wait wakes the consumer before it waits" {
    // ⭐ **The assertion is about order, not about presence.** "There is a
    // wake-up somewhere" is satisfied by a wake-up in the wrong place, and a
    // wake-up after the wait is exactly the bug this is guarding: the waiter
    // is already asleep, so the signal it needed has already gone past.
    //
    // The probe records the queue's own waiter count at the moment it is
    // called. Called before the wait, that count is still zero; called after,
    // it is one. **Two different failures, one number.**
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 2);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    const Probe = struct {
        q: *Q,
        calls: usize = 0,
        waiters_at_call: usize = 0,

        fn wake(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.waiters_at_call = self.q.not_full_waiters;
        }
    };
    var probe: Probe = .{ .q = q };
    q.waker = .{ .ctx = &probe, .func = &Probe.wake };

    // Fill it. Nothing is woken for a push that fits.
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(usize, 0), probe.calls);

    // Full. A push with a timeout has to wait, so it must wake first.
    // The timeout is short because this test is about the order of two
    // events, not about how long either of them takes.
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 3, .{ .ns = 20 * std.time.ns_per_ms }));
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(@as(usize, 0), probe.waiters_at_call);
}

test "an instant push on a full queue wakes nobody" {
    // The floor for the cell above: without this, moving the wake-up to the
    // top of `push` would satisfy it, and every non-blocking producer would
    // start paying for a wake-up it does not need.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    const Probe = struct {
        calls: usize = 0,
        fn wake(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
    };
    var probe: Probe = .{};
    q.waker = .{ .ctx = &probe, .func = &Probe.wake };

    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(usize, 0), probe.calls);
}

test "an unbounded push also wakes the consumer before it waits" {
    // ⚠️ **The cell above only covers the timed arm.** Deleting the wake-up
    // from the unbounded arm left every check green -- found by mutation, not
    // by reading. The two arms are two pieces of code and they need two
    // cells; one test per behaviour is not the same as one test per branch.
    //
    // Unbounded means this cannot be asserted on the calling thread, so the
    // push goes on a detached thread and is released at the end.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    const Probe = struct {
        q: *Q,
        called: std.atomic.Value(bool) = .init(false),
        waiters_at_call: usize = 999,
        done: std.atomic.Value(bool) = .init(false),

        fn wake(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.waiters_at_call = self.q.not_full_waiters;
            self.called.store(true, .release);
        }

        fn run(self: *@This(), qq: *Q, iio: std.Io) void {
            _ = qq.push(iio, 2, .{ .forever = {} });
            self.done.store(true, .release);
        }
    };
    var probe: Probe = .{ .q = q };
    q.waker = .{ .ctx = &probe, .func = &Probe.wake };

    try testing.expect(q.push(io, 1, .{ .instant = {} }) != 0);

    const th = try std.Thread.spawn(.{}, Probe.run, .{ &probe, q, io });
    th.detach();

    var waited: usize = 0;
    while (waited < 2_000 and !probe.called.load(.acquire)) : (waited += 10) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    const woke = probe.called.load(.acquire);
    const waiters = probe.waiters_at_call;

    // Release the pusher before the queue goes away, whatever the verdict.
    _ = q.pop(io);
    var drain: usize = 0;
    while (drain < 1_000 and !probe.done.load(.acquire)) : (drain += 10) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    try testing.expect(woke);
    try testing.expectEqual(@as(usize, 0), waiters);
}

test "with no ceiling set, the queue holds exactly what it always held" {
    // ⭐ **The floor for the ceiling.** A field that changes when a queue is
    // full is one edit away from changing it for everybody, and the build
    // nobody configured is the one that must be byte-for-byte what it was.
    // Asserting the default is off is not enough: off has to mean the old
    // number, and this counts to it.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 8);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    try testing.expectEqual(@as(Q.Size, 0), q.capacity_limit);

    var i: u64 = 0;
    while (i < 8) : (i += 1) {
        try testing.expectEqual(@as(Q.Size, @intCast(i + 1)), q.push(io, i, .{ .instant = {} }));
    }
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 99, .{ .instant = {} }));
}

test "a lowered ceiling makes the queue full early, on the ordinary path" {
    // ⭐ **This is the whole point of the field**: reaching "full" without
    // the fault that used to cause it. Without a way to get here, a machine
    // can only report that nothing went wrong -- which is what it reports
    // when the case is broken and never reached, too.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 8);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);
    q.capacity_limit = 2;

    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    // Full at two, with six slots of storage still unused.
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 3, .{ .instant = {} }));

    // And it is the same "full" the waiting arms see: a timed push gives up
    // rather than finding room that the array physically has.
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 3, .{ .ns = 20 * std.time.ns_per_ms }));

    // Popping one lets exactly one more in.
    _ = q.pop(io);
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 4, .{ .instant = {} }));
}
