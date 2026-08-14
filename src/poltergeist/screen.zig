//! Glue between a live terminal `Screen` and the pure sensing core.
//!
//! This is the only file in `src/poltergeist/` that knows what a terminal
//! is. Everything it does is walk the viewport once and hand each row to a
//! `Watcher` as opaque bytes; all the decisions live in `Sampler`.
//!
//! The caller is responsible for holding the renderer state lock. See
//! `docs/poltergeist/sensing.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const terminal = @import("../terminal/main.zig");
const Sampler = @import("Sampler.zig");
const Watcher = @import("Watcher.zig");

/// Hash the visible viewport of `screen` and feed it to `watcher`.
///
/// Rows are hashed over their raw cell bytes rather than their decoded text.
/// That is one pass at memcpy speed and it catches every visual change --
/// including colour-only ones, which decoded text would miss.
///
/// The cost is that a cell's style id is part of the hash, so a rebuilt
/// style table could make an unchanged screen look changed. That error is in
/// the safe direction: it reads as "still working", so the supervisor is
/// told about fewer quiet terminals, never about more.
///
/// The caller must hold the renderer state mutex.
pub fn sample(
    watcher: *Watcher,
    screen: *const terminal.Screen,
    now_ms: u64,
) Allocator.Error!?Sampler.Event {
    const row_count: usize = screen.pages.rows;

    var builder = try watcher.begin(row_count);

    // If we bail out before `end`, drop the sample rather than letting a
    // half-read screen register as a change.
    var completed = false;
    defer if (!completed) watcher.abort();

    var it = screen.pages.rowIterator(
        .right_down,
        .{ .viewport = .{} },
        null,
    );
    var seen: usize = 0;
    while (it.next()) |pin| {
        if (seen >= row_count) break;
        const rac = pin.rowAndCell();
        const cells = pin.node.page().getCells(rac.row);
        builder.addRow(std.mem.sliceAsBytes(cells));
        seen += 1;
    }

    completed = true;
    return watcher.end(&builder, now_ms);
}

test "sampling a screen twice with no writes reports no change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try terminal.Screen.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer s.deinit();
    try s.testWriteString("hello poltergeist");

    var w: Watcher = .init(alloc, .{ .quiescence_ms = 1000, .repeat_ms = 5000 });
    defer w.deinit();

    // Arm, then sample again with nothing written in between.
    try testing.expect(try sample(&w, &s, 0) == null);
    try testing.expect(try sample(&w, &s, 500) == null);

    const e = (try sample(&w, &s, 1000)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.quiet_ms);
    try testing.expect(w.isQuiescent());
}

test "writing to the screen keeps it out of quiescence" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try terminal.Screen.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer s.deinit();

    var w: Watcher = .init(alloc, .{ .quiescence_ms = 1000, .repeat_ms = 5000 });
    defer w.deinit();

    try testing.expect(try sample(&w, &s, 0) == null);

    try s.testWriteString("tick");
    try testing.expect(try sample(&w, &s, 1000) == null);

    try s.testWriteString("tock");
    try testing.expect(try sample(&w, &s, 2000) == null);

    try testing.expect(!w.isQuiescent());
}

test "a quiescent screen that changes reports resumed with the quiet duration" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try terminal.Screen.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer s.deinit();
    try s.testWriteString("idle");

    var w: Watcher = .init(alloc, .{ .quiescence_ms = 1000, .repeat_ms = 5000 });
    defer w.deinit();

    _ = try sample(&w, &s, 0);
    _ = try sample(&w, &s, 1000);
    try testing.expect(w.isQuiescent());

    try s.testWriteString(" again");
    const e = (try sample(&w, &s, 9000)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 9000), e.resumed.quiet_ms);
    try testing.expect(!w.isQuiescent());
}

test "the row count matches the viewport, not the scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Five visible rows with room for scrollback behind them.
    var s = try terminal.Screen.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 1 << 16 });
    defer s.deinit();
    try s.testWriteString("a\nb\nc\nd\ne\nf\ng\nh");

    var w: Watcher = .init(alloc, .{ .quiescence_ms = 1000, .repeat_ms = 5000 });
    defer w.deinit();

    _ = try sample(&w, &s, 0);
    const e = (try sample(&w, &s, 1000)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u16, 5), e.quiescent.total_rows);
}
