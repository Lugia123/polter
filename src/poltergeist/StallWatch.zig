//! Names what the app thread is stuck on, while it is stuck (task 1729).
//!
//! **Why.** On 2026-10-18 the user's Polter stopped answering for about 47 s
//! (12:25:39–12:26:28) and again near 12:42:39. Both times the stall came
//! right after a `role_put`, the mailbox filled behind it, and nothing on
//! record said what the app thread was doing: no sample was taken while it
//! happened, and the thread that is stuck is the one thread that cannot
//! say so. So another thread says it.
//!
//! **What it costs the app thread.** `begin` and `end` are a handful of
//! atomic stores and one clock read -- no lock, no allocation, no log. The
//! label is two static strings (a mailbox message's tag, an rpc method's
//! name) and a terminal id, stored as pointers and lengths, so nothing is
//! copied. Everything else -- reading the clock against a threshold,
//! formatting, logging -- happens on the watching thread (`run`).
//!
//! **What it reports.** Once per stall: when one item has taken longer than
//! the threshold (`Event.stalled`), and once more when it ends, with how
//! long it took altogether (`Event.recovered`). An item that ends before the
//! threshold is never mentioned. **What it cannot see**: the app thread stuck
//! anywhere that is not between a `begin` and an `end` -- in the apprt's own
//! code, outside a tick -- looks the same as an idle app, because to this
//! file it is one.
//!
//! The watching side is `poll`, a pure function of the shared state, the
//! time and what it reported last, so the rules are tested without threads;
//! one test runs it on real threads as well.

const StallWatch = @This();

const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.poltergeist);

/// What the app thread is busy with. All three are the caller's static
/// strings and id: they are kept by pointer, never copied.
pub const Label = struct {
    /// What kind of work: a mailbox message's tag, or `tick`.
    kind: []const u8,
    /// For an agent's request, its method; empty otherwise.
    method: []const u8 = "",
    /// For an agent's request, the terminal it came from; 0 otherwise.
    caller: u64 = 0,
};

/// Which item is in hand: incremented by every `begin`. Zero is never one.
gen: std.atomic.Value(u64) = .init(0),
/// The `gen` of the item in hand, or 0 between items. Stored last by
/// `begin` and first by `end`, so a reader that sees the same non-zero
/// value before and after reading the rest has read one item's fields.
active: std.atomic.Value(u64) = .init(0),
started_ns: std.atomic.Value(u64) = .init(0),
kind_ptr: std.atomic.Value(usize) = .init(0),
kind_len: std.atomic.Value(usize) = .init(0),
method_ptr: std.atomic.Value(usize) = .init(0),
method_len: std.atomic.Value(usize) = .init(0),
caller: std.atomic.Value(u64) = .init(0),
/// When the last item ended, and which it was.
ended_ns: std.atomic.Value(u64) = .init(0),
ended_gen: std.atomic.Value(u64) = .init(0),

/// How long one item may take before it is reported; 0 is off. Set from
/// `poltergeist-stall-warn-after`.
threshold_ns: std.atomic.Value(u64) = .init(2 * std.time.ns_per_s),

/// The app thread: an item starts. `now_ns` is `nowNs`.
pub fn begin(self: *StallWatch, now_ns: u64, label: Label) void {
    const g = self.gen.load(.monotonic) + 1;
    self.gen.store(g, .monotonic);
    self.started_ns.store(now_ns, .monotonic);
    self.kind_ptr.store(@intFromPtr(label.kind.ptr), .monotonic);
    self.kind_len.store(label.kind.len, .monotonic);
    self.method_ptr.store(@intFromPtr(label.method.ptr), .monotonic);
    self.method_len.store(label.method.len, .monotonic);
    self.caller.store(label.caller, .monotonic);
    self.active.store(g, .release);
}

/// The app thread: the item `begin` started is done.
pub fn end(self: *StallWatch, now_ns: u64) void {
    const g = self.active.load(.monotonic);
    self.active.store(0, .release);
    self.ended_ns.store(now_ns, .monotonic);
    self.ended_gen.store(g, .release);
}

/// The clock both sides read. Monotonic, and not stopped by sleep: a
/// machine that slept through a stall should not report the sleep as one.
pub fn nowNs(io: Io) u64 {
    const t: Io.Timestamp = .now(io, .awake);
    return @intCast(@max(0, t.nanoseconds));
}

/// What `poll` found worth saying.
pub const Event = union(enum) {
    /// One item has taken longer than the threshold, and is still going.
    stalled: struct { label: Label, elapsed_ms: u64 },
    /// The item reported as stalled has ended, after this long in all.
    recovered: struct { label: Label, total_ms: u64 },
};

/// The watching side's memory: the stall it has reported and not yet seen
/// end. Only the watching thread touches it.
pub const Seen = struct {
    gen: u64 = 0,
    started_ns: u64 = 0,
    label: Label = .{ .kind = "" },
};

/// Look once. Says a stall the first time it is past the threshold, and its
/// end the first time it is over; null otherwise -- including every look
/// at a stall already said.
pub fn poll(self: *const StallWatch, seen: *Seen, now_ns: u64) ?Event {
    // A stall said and not yet seen to end: has it?
    if (seen.gen != 0) {
        if (self.active.load(.acquire) != seen.gen) {
            const ended = self.ended_gen.load(.acquire) == seen.gen;
            const until = if (ended) self.ended_ns.load(.monotonic) else now_ns;
            const total = until -| seen.started_ns;
            const label = seen.label;
            seen.* = .{};
            return .{ .recovered = .{ .label = label, .total_ms = total / std.time.ns_per_ms } };
        }
        return null;
    }

    const threshold = self.threshold_ns.load(.monotonic);
    if (threshold == 0) return null;

    const g = self.active.load(.acquire);
    if (g == 0) return null;
    const started = self.started_ns.load(.monotonic);
    const label: Label = .{
        .kind = slice(self.kind_ptr.load(.monotonic), self.kind_len.load(.monotonic)),
        .method = slice(self.method_ptr.load(.monotonic), self.method_len.load(.monotonic)),
        .caller = self.caller.load(.monotonic),
    };
    // Changed while being read: one item's start and another's label.
    // The next look reads it whole.
    if (self.active.load(.acquire) != g) return null;

    const elapsed = now_ns -| started;
    if (elapsed < threshold) return null;
    seen.* = .{ .gen = g, .started_ns = started, .label = label };
    return .{ .stalled = .{ .label = label, .elapsed_ms = elapsed / std.time.ns_per_ms } };
}

fn slice(ptr: usize, len: usize) []const u8 {
    if (len == 0) return "";
    const p: [*]const u8 = @ptrFromInt(ptr);
    return p[0..len];
}

/// The line an event is logged as.
pub fn describe(w: *std.Io.Writer, event: Event) std.Io.Writer.Error!void {
    switch (event) {
        .stalled => |s| {
            try w.print("app thread: {d} ms into one {s}", .{ s.elapsed_ms, s.label.kind });
            try writeRequest(w, s.label);
            try w.writeAll(" and not done -- nothing else on the app thread is being handled");
        },
        .recovered => |r| {
            try w.print("app thread: free again after {d} ms in one {s}", .{ r.total_ms, r.label.kind });
            try writeRequest(w, r.label);
        },
    }
}

fn writeRequest(w: *std.Io.Writer, label: Label) std.Io.Writer.Error!void {
    if (label.method.len > 0) try w.print(" method={s}", .{label.method});
    if (label.caller != 0) try w.print(" from=0x{x:0>16}", .{label.caller});
}

/// The watching thread. Looks every `every_ms` until `stop` is set, and
/// hands each event to `sink` (`logSink` in the app).
pub fn run(
    self: *const StallWatch,
    io: Io,
    stop: *const std.atomic.Value(bool),
    every_ms: u32,
    sink: *const fn (ctx: ?*anyopaque, event: Event) void,
    ctx: ?*anyopaque,
) void {
    var seen: Seen = .{};
    while (!stop.load(.acquire)) {
        io.sleep(.fromMilliseconds(every_ms), .awake) catch return;
        if (self.poll(&seen, nowNs(io))) |event| sink(ctx, event);
    }
}

/// `run`'s sink in the app: one warning line per event.
pub fn logSink(_: ?*anyopaque, event: Event) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    describe(&w, event) catch {};
    log.warn("{s}", .{w.buffered()});
}

// ----------------------------------------------------------------- tests

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "stall watch: a long item is said once past the threshold, and its end once with the total" {
    var watch: StallWatch = .{};
    var seen: Seen = .{};

    watch.begin(1000 * ms, .{ .kind = "poltergeist_request", .method = "role_put", .caller = 0x9c60 });
    try testing.expect(watch.poll(&seen, 2000 * ms) == null);
    try testing.expect(watch.poll(&seen, 2999 * ms) == null);

    const stalled = watch.poll(&seen, 3100 * ms).?;
    try testing.expect(stalled == .stalled);
    try testing.expectEqualStrings("poltergeist_request", stalled.stalled.label.kind);
    try testing.expectEqualStrings("role_put", stalled.stalled.label.method);
    try testing.expectEqual(@as(u64, 0x9c60), stalled.stalled.label.caller);
    try testing.expectEqual(@as(u64, 2100), stalled.stalled.elapsed_ms);

    // Still stuck: nothing more, however often it is looked at.
    try testing.expect(watch.poll(&seen, 3500 * ms) == null);
    try testing.expect(watch.poll(&seen, 9000 * ms) == null);

    // It ends; the next look says so, with the time it ended, not the time
    // it was looked at.
    watch.end(48_000 * ms);
    const back = watch.poll(&seen, 49_000 * ms).?;
    try testing.expect(back == .recovered);
    try testing.expectEqualStrings("role_put", back.recovered.label.method);
    try testing.expectEqual(@as(u64, 47_000), back.recovered.total_ms);
    try testing.expect(watch.poll(&seen, 50_000 * ms) == null);
}

test "stall watch: an item done inside the threshold is never mentioned" {
    var watch: StallWatch = .{};
    var seen: Seen = .{};
    watch.begin(0, .{ .kind = "surface_message" });
    try testing.expect(watch.poll(&seen, 1900 * ms) == null);
    watch.end(1950 * ms);
    try testing.expect(watch.poll(&seen, 5000 * ms) == null);

    // The next one is judged on its own start, not the first one's.
    watch.begin(6000 * ms, .{ .kind = "tick" });
    try testing.expect(watch.poll(&seen, 7000 * ms) == null);
    try testing.expect(watch.poll(&seen, 8100 * ms).? == .stalled);
}

test "stall watch: two stalls in a row are two reports" {
    var watch: StallWatch = .{};
    var seen: Seen = .{};
    watch.begin(0, .{ .kind = "poltergeist_request", .method = "role_put" });
    try testing.expect(watch.poll(&seen, 3000 * ms).? == .stalled);
    watch.end(3500 * ms);
    // The next starts before the watcher has looked again: the first is
    // still said to have ended, with its own total.
    watch.begin(3600 * ms, .{ .kind = "poltergeist_request", .method = "group_add" });
    const back = watch.poll(&seen, 3700 * ms).?;
    try testing.expectEqual(@as(u64, 3500), back.recovered.total_ms);
    try testing.expectEqualStrings("role_put", back.recovered.label.method);
    const again = watch.poll(&seen, 6000 * ms).?;
    try testing.expectEqualStrings("group_add", again.stalled.label.method);
}

test "stall watch: off is off" {
    var watch: StallWatch = .{};
    watch.threshold_ns.store(0, .monotonic);
    var seen: Seen = .{};
    watch.begin(0, .{ .kind = "tick" });
    try testing.expect(watch.poll(&seen, 60_000 * ms) == null);
}

test "stall watch: the line names the message, the method and the terminal" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try describe(&w, .{ .stalled = .{
        .label = .{ .kind = "poltergeist_request", .method = "role_put", .caller = 0x9c60 },
        .elapsed_ms = 2100,
    } });
    try testing.expectEqualStrings(
        "app thread: 2100 ms into one poltergeist_request method=role_put from=0x0000000000009c60 and not done -- nothing else on the app thread is being handled",
        w.buffered(),
    );
}

test "stall watch: on real threads, an app thread stuck 3 s is named after 2 s and once" {
    const io = testing.io;
    var watch: StallWatch = .{};
    var stop: std.atomic.Value(bool) = .init(false);

    const Sink = struct {
        mutex: Io.Mutex = .init,
        events: [8]Event = undefined,
        at_ms: [8]u64 = undefined,
        n: usize = 0,
        t0: u64 = 0,
        fn take(ctx: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lockUncancelable(testing.io);
            defer self.mutex.unlock(testing.io);
            if (self.n == self.events.len) return;
            self.events[self.n] = event;
            self.at_ms[self.n] = (nowNs(testing.io) - self.t0) / ms;
            self.n += 1;
        }
    };
    var sink: Sink = .{ .t0 = nowNs(io) };

    const watcher = try std.Thread.spawn(.{}, run, .{ &watch, io, &stop, 50, Sink.take, @as(?*anyopaque, &sink) });

    // The app thread: one request that holds it for three seconds.
    watch.begin(nowNs(io), .{ .kind = "poltergeist_request", .method = "role_put", .caller = 0x9c60 });
    try io.sleep(.fromMilliseconds(3000), .awake);
    watch.end(nowNs(io));
    // A moment for the watcher to see it end, then a quick one after.
    try io.sleep(.fromMilliseconds(300), .awake);
    watch.begin(nowNs(io), .{ .kind = "surface_message" });
    watch.end(nowNs(io));
    try io.sleep(.fromMilliseconds(200), .awake);

    stop.store(true, .release);
    watcher.join();

    try testing.expectEqual(@as(usize, 2), sink.n);
    const stalled = sink.events[0].stalled;
    try testing.expectEqualStrings("poltergeist_request", stalled.label.kind);
    try testing.expectEqualStrings("role_put", stalled.label.method);
    try testing.expectEqual(@as(u64, 0x9c60), stalled.label.caller);
    try testing.expect(stalled.elapsed_ms >= 2000 and stalled.elapsed_ms < 2500);
    try testing.expect(sink.at_ms[0] >= 2000 and sink.at_ms[0] < 2500);
    const back = sink.events[1].recovered;
    try testing.expectEqualStrings("role_put", back.label.method);
    try testing.expect(back.total_ms >= 3000 and back.total_ms < 3300);
}
