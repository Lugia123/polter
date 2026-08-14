//! Ties `Fingerprint` and `Sampler` together for one surface.
//!
//! Owns the two per-row hash buffers a sample needs (this sample's and the
//! previous one's) and hands out a `Fingerprint.Builder` pointed at them, so
//! callers never manage that double buffer themselves.
//!
//! Still pure with respect to the terminal: it takes rows as bytes and time
//! as a parameter. The glue that walks a real `Screen` and reads the clock
//! lives outside this file, which is what keeps all of this testable without
//! a terminal. See `docs/poltergeist/sensing.md`.

const Watcher = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Fingerprint = @import("Fingerprint.zig");
const Sampler = @import("Sampler.zig");

alloc: Allocator,
sampler: Sampler,

/// This sample's per-row hashes. Length is the capacity, not the row count.
rows: []u64 = &.{},

/// The previous sample's per-row hashes, and how many of them were used.
prev: []u64 = &.{},
prev_len: usize = 0,

/// pty bytes seen since the last completed sample.
pending_bytes: u64 = 0,

/// True between `begin` and `end`. Guards against a caller starting a second
/// sample while one is open, which would hand out aliasing row buffers.
sampling: bool = false,

pub fn init(alloc: Allocator, config: Sampler.Config) Watcher {
    return .{ .alloc = alloc, .sampler = .init(config) };
}

pub fn deinit(self: *Watcher) void {
    self.alloc.free(self.rows);
    self.alloc.free(self.prev);
    self.* = undefined;
}

/// Record pty output. Cheap enough to call from the read path; the count is
/// folded into the next sample and then reset.
pub fn noteBytes(self: *Watcher, n: u64) void {
    self.pending_bytes +|= n;
}

/// Whether the sampler currently considers this terminal quiescent.
pub fn isQuiescent(self: *const Watcher) bool {
    return self.sampler.isQuiescent();
}

/// Begin a sample covering `row_count` rows. Feed every row into the
/// returned builder, then pass it to `end`.
pub fn begin(self: *Watcher, row_count: usize) Allocator.Error!Fingerprint.Builder {
    assert(!self.sampling);

    if (self.rows.len < row_count) {
        self.rows = try self.alloc.realloc(self.rows, row_count);
    }

    self.sampling = true;
    return .init(self.rows[0..row_count], self.prev[0..self.prev_len]);
}

/// Finish the sample and feed it to the sampler. Returns an event only on a
/// transition worth reporting.
pub fn end(
    self: *Watcher,
    builder: *Fingerprint.Builder,
    now_ms: u64,
) ?Sampler.Event {
    assert(self.sampling);
    self.sampling = false;

    const fingerprint = builder.finish();
    const used = builder.index;

    const event = self.sampler.observe(.{
        .now_ms = now_ms,
        .fingerprint = fingerprint,
        .bytes = self.pending_bytes,
    });
    self.pending_bytes = 0;

    // Swap: this sample's rows become the next sample's `prev`. Swapping
    // rather than copying keeps a sample at one pass over the rows.
    const old_prev = self.prev;
    self.prev = self.rows;
    self.prev_len = used;
    self.rows = old_prev;

    return event;
}

/// Abandon an open sample without feeding it to the sampler. Used when the
/// caller could not read the screen (for example it failed to take the
/// terminal lock) and must not let a partial screen look like a change.
pub fn abort(self: *Watcher) void {
    assert(self.sampling);
    self.sampling = false;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const fast: Sampler.Config = .{ .quiescence_ms = 1000, .repeat_ms = 5000 };

/// Feed one whole screen through the watcher.
fn feed(w: *Watcher, now_ms: u64, screen: []const []const u8) !?Sampler.Event {
    var b = try w.begin(screen.len);
    for (screen) |row| b.addRow(row);
    return w.end(&b, now_ms);
}

test "an unchanging screen goes quiescent" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    const screen: []const []const u8 = &.{ "line one", "line two" };

    try testing.expect(try feed(&w, 0, screen) == null);
    try testing.expect(try feed(&w, 500, screen) == null);

    const e = (try feed(&w, 1000, screen)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.quiet_ms);
    try testing.expect(w.isQuiescent());
}

test "a changing screen stays active" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    try testing.expect(try feed(&w, 0, &.{ "a", "b" }) == null);
    try testing.expect(try feed(&w, 1000, &.{ "a", "c" }) == null);
    try testing.expect(try feed(&w, 2000, &.{ "a", "d" }) == null);
    try testing.expect(!w.isQuiescent());
}

test "changed_rows is reported against the previous sample" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    _ = try feed(&w, 0, &.{ "a", "b", "c" });

    var b = try w.begin(3);
    b.addRow("a");
    b.addRow("B");
    b.addRow("c");
    _ = w.end(&b, 100);

    // The builder's own count is the observable; the sampler passes it
    // through on the next report.
    try testing.expectEqual(@as(u16, 1), b.changed);
}

test "the row buffers really do swap" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    _ = try feed(&w, 0, &.{ "x", "y" });
    const first_prev = w.prev.ptr;

    _ = try feed(&w, 100, &.{ "x", "y" });
    try testing.expect(w.prev.ptr != first_prev);
    try testing.expectEqual(@as(usize, 2), w.prev_len);
}

test "a resize does not confuse the previous sample" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    _ = try feed(&w, 0, &.{ "a", "b", "c", "d" });

    // Shrink. The first two rows match, so only the loss of rows should
    // register -- and the screen hash must still differ from the tall one.
    var b = try w.begin(2);
    b.addRow("a");
    b.addRow("b");
    _ = w.end(&b, 100);

    try testing.expectEqual(@as(u16, 0), b.changed);
    try testing.expectEqual(@as(usize, 2), w.prev_len);
    try testing.expect(!w.isQuiescent());
}

test "growing the screen reallocates without losing the previous sample" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    _ = try feed(&w, 0, &.{"a"});
    _ = try feed(&w, 100, &.{ "a", "b", "c", "d", "e" });
    try testing.expectEqual(@as(usize, 5), w.prev_len);
    try testing.expect(w.rows.len >= 1);
}

test "noteBytes reaches the report and then resets" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    const screen: []const []const u8 = &.{"idle"};

    w.noteBytes(64);
    _ = try feed(&w, 0, screen);

    // No further bytes: silence should track the full gap.
    const e = (try feed(&w, 1000, screen)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.silent_ms);
    try testing.expectEqual(@as(u64, 0), w.pending_bytes);
}

test "abort leaves the sampler untouched" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    const screen: []const []const u8 = &.{"stable"};
    _ = try feed(&w, 0, screen);

    // A sample we could not complete -- say the terminal lock was busy.
    var b = try w.begin(1);
    b.addRow("half a scr");
    w.abort();

    // The aborted partial screen must not count as a change: the terminal
    // should still cross into quiescence on schedule.
    const e = (try feed(&w, 1000, screen)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.quiet_ms);
}

test "an empty screen is a valid sample" {
    var w: Watcher = .init(testing.allocator, fast);
    defer w.deinit();

    try testing.expect(try feed(&w, 0, &.{}) == null);
    const e = (try feed(&w, 1000, &.{})) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u16, 0), e.quiescent.total_rows);
}
