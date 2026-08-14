//! A cheap, content-only hash of what a terminal is currently showing.
//!
//! Poltergeist's sensing layer measures exactly one thing: how long a
//! terminal's visible screen has gone unchanged. It deliberately does not
//! interpret *what* is on screen -- that judgement belongs to the supervisor
//! AI. See `docs/poltergeist/sensing.md`.
//!
//! This file is pure: it takes opaque bytes per row and knows nothing about
//! `Screen`, `Page` or `Cell`. The caller decides what a "row" hashes over.
//! Keeping it decoupled is what lets it be tested without a terminal.

const Fingerprint = @This();

const std = @import("std");
const assert = std.debug.assert;

/// Hash of every sampled row, combined in row order. Two samples of the same
/// visible content produce the same value; this is the only field quiescence
/// is decided on.
screen: u64,

/// How many rows differed from the previous sample. Reported to the
/// supervisor as context only. Nothing in Poltergeist branches on it: the
/// moment we start treating "few rows changed" as "not really changed" we
/// have reinvented the spinner-stripping heuristic that the design removed.
changed_rows: u16,

/// How many rows this sample covered.
total_rows: u16,

/// Seed for a row's own hash. Distinct from `screen_seed` so that a
/// single-row screen does not hash to the same value as that row.
const row_seed: u64 = 0x706f_6c74_6572_0001;

/// Seed for the combined screen hash.
const screen_seed: u64 = 0x706f_6c74_6572_0002;

/// Hash one row's bytes. Exposed so a caller can pre-hash rows it already
/// knows are unchanged, but `Builder` is the normal entry point.
pub fn hashRow(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(row_seed, bytes);
}

/// Accumulates rows into a `Fingerprint` while counting how many changed
/// against the previous sample.
///
/// The caller owns both slices. `rows` is written with this sample's per-row
/// hashes and becomes the `prev` of the next sample, so callers typically
/// keep two buffers and swap them, or keep one and copy.
pub const Builder = struct {
    hasher: std.hash.Wyhash,

    /// Per-row hashes of the previous sample. May be empty (first sample) or
    /// a different length than `rows` (the terminal was resized).
    prev: []const u64,

    /// Output buffer for this sample's per-row hashes.
    rows: []u64,

    index: usize = 0,
    changed: u16 = 0,

    pub fn init(rows: []u64, prev: []const u64) Builder {
        return .{
            .hasher = .init(screen_seed),
            .prev = prev,
            .rows = rows,
        };
    }

    /// Add the next row. Must be called at most `rows.len` times.
    pub fn addRow(self: *Builder, bytes: []const u8) void {
        self.addRowHash(hashRow(bytes));
    }

    /// Add a row whose hash the caller already computed.
    pub fn addRowHash(self: *Builder, hash: u64) void {
        assert(self.index < self.rows.len);

        self.rows[self.index] = hash;

        // A row past the end of the previous sample counts as changed: the
        // screen grew, so there is genuinely new content there.
        if (self.index >= self.prev.len or self.prev[self.index] != hash) {
            self.changed +|= 1;
        }

        self.hasher.update(std.mem.asBytes(&hash));
        self.index += 1;
    }

    pub fn finish(self: *Builder) Fingerprint {
        // Fold the row count in so that a screen which shrank to a prefix of
        // itself does not collide with the taller original.
        const rows: u16 = @intCast(@min(self.index, std.math.maxInt(u16)));
        self.hasher.update(std.mem.asBytes(&rows));

        return .{
            .screen = self.hasher.final(),
            .changed_rows = self.changed,
            .total_rows = rows,
        };
    }
};

test "identical rows produce identical fingerprints" {
    var a_rows: [3]u64 = undefined;
    var b_rows: [3]u64 = undefined;

    var a: Builder = .init(&a_rows, &.{});
    a.addRow("hello");
    a.addRow("world");
    a.addRow("");
    const fa = a.finish();

    var b: Builder = .init(&b_rows, &.{});
    b.addRow("hello");
    b.addRow("world");
    b.addRow("");
    const fb = b.finish();

    try std.testing.expectEqual(fa.screen, fb.screen);
    try std.testing.expectEqual(@as(u16, 3), fa.total_rows);
}

test "a single changed row changes the screen hash" {
    var a_rows: [2]u64 = undefined;
    var b_rows: [2]u64 = undefined;

    var a: Builder = .init(&a_rows, &.{});
    a.addRow("same");
    a.addRow("before");
    const fa = a.finish();

    var b: Builder = .init(&b_rows, &.{});
    b.addRow("same");
    b.addRow("after");
    const fb = b.finish();

    try std.testing.expect(fa.screen != fb.screen);
}

test "row order matters" {
    var a_rows: [2]u64 = undefined;
    var b_rows: [2]u64 = undefined;

    var a: Builder = .init(&a_rows, &.{});
    a.addRow("one");
    a.addRow("two");
    const fa = a.finish();

    var b: Builder = .init(&b_rows, &.{});
    b.addRow("two");
    b.addRow("one");
    const fb = b.finish();

    try std.testing.expect(fa.screen != fb.screen);
}

test "changed_rows counts only the rows that differ" {
    var first: [3]u64 = undefined;
    var second: [3]u64 = undefined;

    var a: Builder = .init(&first, &.{});
    a.addRow("a");
    a.addRow("b");
    a.addRow("c");
    const fa = a.finish();

    // Every row is new on the first sample.
    try std.testing.expectEqual(@as(u16, 3), fa.changed_rows);

    var b: Builder = .init(&second, &first);
    b.addRow("a");
    b.addRow("B");
    b.addRow("c");
    const fb = b.finish();

    try std.testing.expectEqual(@as(u16, 1), fb.changed_rows);
}

test "an unchanged screen reports zero changed rows" {
    var first: [2]u64 = undefined;
    var second: [2]u64 = undefined;

    var a: Builder = .init(&first, &.{});
    a.addRow("x");
    a.addRow("y");
    _ = a.finish();

    var b: Builder = .init(&second, &first);
    b.addRow("x");
    b.addRow("y");
    const fb = b.finish();

    try std.testing.expectEqual(@as(u16, 0), fb.changed_rows);
    try std.testing.expectEqualSlices(u64, &first, &second);
}

test "a shrunk screen does not collide with its taller original" {
    var tall_rows: [3]u64 = undefined;
    var short_rows: [2]u64 = undefined;

    var tall: Builder = .init(&tall_rows, &.{});
    tall.addRow("a");
    tall.addRow("b");
    tall.addRow("");
    const ftall = tall.finish();

    var short: Builder = .init(&short_rows, &.{});
    short.addRow("a");
    short.addRow("b");
    const fshort = short.finish();

    try std.testing.expect(ftall.screen != fshort.screen);
}

test "growing past the previous sample counts the new rows as changed" {
    var first: [2]u64 = undefined;
    var second: [4]u64 = undefined;

    var a: Builder = .init(&first, &.{});
    a.addRow("a");
    a.addRow("b");
    _ = a.finish();

    var b: Builder = .init(&second, &first);
    b.addRow("a");
    b.addRow("b");
    b.addRow("c");
    b.addRow("d");
    const fb = b.finish();

    try std.testing.expectEqual(@as(u16, 2), fb.changed_rows);
    try std.testing.expectEqual(@as(u16, 4), fb.total_rows);
}

test "a one row screen does not hash to its own row hash" {
    var rows: [1]u64 = undefined;
    var b: Builder = .init(&rows, &.{});
    b.addRow("only");
    const f = b.finish();

    try std.testing.expect(f.screen != hashRow("only"));
}

test "addRowHash matches addRow" {
    var a_rows: [1]u64 = undefined;
    var b_rows: [1]u64 = undefined;

    var a: Builder = .init(&a_rows, &.{});
    a.addRow("payload");
    const fa = a.finish();

    var b: Builder = .init(&b_rows, &.{});
    b.addRowHash(hashRow("payload"));
    const fb = b.finish();

    try std.testing.expectEqual(fa.screen, fb.screen);
}
