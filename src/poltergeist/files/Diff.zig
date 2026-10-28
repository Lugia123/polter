//! A line diff (task 2562 C4, PLAN §1.6): Myers' O(ND) algorithm, from two
//! lists of lines to the places where they differ. Pure: slices in, hunks out.
//!
//! **A text is cut at `\n` and nowhere else**, so `"a\n"` is `["a", ""]` and
//! `""` is `[""]`; `join` is the exact inverse. The trailing empty line is
//! what carries "ends in a newline", so no flag has to travel next to the
//! lines. (A `\r` is part of its line: a file's line ends are normalised by
//! `Write`, not here.)
//!
//! **The work is bounded, and says so.** The trace Myers keeps is quadratic
//! in the number of edits, so past `max_edits` the diff gives up with
//! `error.TooDifferent` rather than spending the memory; the caller
//! (`Merge`) treats that like too many segments: one conflict, the whole file.

const Diff = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The most edits (deleted plus inserted lines) the search goes to before
/// giving up. The trace is one snapshot of 2d+1 entries (`i32`, 4 bytes) per
/// round d, so ~(`max_edits`+1)² entries: ~9 million, ~36 MB, at this value
/// -- **per diff, and `Merge` makes two in the same arena, so ~72 MB** until
/// the arena goes. The time is O((N+M)·D) line comparisons, which for a 1 MB
/// file of ~30 000 lines and D near the limit is in the hundreds of millions:
/// **not for the app thread** (the slice that wires this to a tool must run
/// it elsewhere, or lower this).
pub const max_edits: usize = 3000;

pub const Error = Allocator.Error || error{TooDifferent};

/// `a[a_start .. a_start + a_len]` is replaced by `b[b_start .. b_start + b_len]`.
/// Either length may be 0 (a pure insertion or a pure deletion), never both.
pub const Hunk = struct {
    a_start: usize,
    a_len: usize,
    b_start: usize,
    b_len: usize,
};

/// Cut at `\n`. The slices point into `text`.
pub fn lines(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(arena, l);
    return out.items;
}

/// The inverse of `lines`.
pub fn join(arena: Allocator, ls: []const []const u8) Allocator.Error![]u8 {
    return std.mem.join(arena, "\n", ls);
}

/// The hunks that turn `a` into `b`, in order, none touching the next (two
/// hunks always have at least one equal line between them).
pub fn diff(arena: Allocator, a: []const []const u8, b: []const []const u8) Error![]const Hunk {
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and eql(a[pre], b[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and
        eql(a[a.len - 1 - suf], b[b.len - 1 - suf])) suf += 1;
    const am = a[pre .. a.len - suf];
    const bm = b[pre .. b.len - suf];

    var hunks: std.ArrayList(Hunk) = .empty;
    if (am.len == 0 and bm.len == 0) return hunks.items;
    if (am.len == 0 or bm.len == 0) {
        try hunks.append(arena, .{ .a_start = pre, .a_len = am.len, .b_start = pre, .b_len = bm.len });
        return hunks.items;
    }
    try myers(arena, am, bm, pre, &hunks);
    return hunks.items;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn myers(arena: Allocator, a: []const []const u8, b: []const []const u8, base: usize, out: *std.ArrayList(Hunk)) Error!void {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const cap: isize = @intCast(@min(a.len + b.len, max_edits));
    const off: isize = cap + 1;
    // Scratch, then one snapshot of the used diagonals per round.
    const v = try arena.alloc(isize, @intCast(2 * cap + 3));
    @memset(v, 0);
    var trace: std.ArrayList([]i32) = .empty;

    var found: ?isize = null;
    var d: isize = 0;
    search: while (d <= cap) : (d += 1) {
        // The snapshot of round d holds what round d-1 left on -d..d.
        const snap = try arena.alloc(i32, @intCast(2 * d + 1));
        for (snap, v[@intCast(off - d)..@intCast(off + d + 1)]) |*dst, src| dst.* = @intCast(src);
        try trace.append(arena, snap);
        var k = -d;
        while (k <= d) : (k += 2) {
            var x: isize = if (d == 0)
                0
            else if (k == -d or (k != d and v[@intCast(off + k - 1)] < v[@intCast(off + k + 1)]))
                v[@intCast(off + k + 1)]
            else
                v[@intCast(off + k - 1)] + 1;
            var y = x - k;
            while (x < n and y < m and eql(a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[@intCast(off + k)] = x;
            if (x >= n and y >= m) {
                found = d;
                break :search;
            }
        }
    }
    const last = found orelse return error.TooDifferent;

    // Back from (n, m): every step is one deleted or one inserted line.
    // Collected last-first, then walked forward into hunks.
    const Step = struct { x: isize, y: isize, del: bool };
    var steps: std.ArrayList(Step) = .empty;
    var x = n;
    var y = m;
    var dd = last;
    while (dd > 0) : (dd -= 1) {
        const s = trace.items[@intCast(dd)];
        const k = x - y;
        const at = struct {
            fn f(sn: []const i32, dk: isize, kk: isize) isize {
                return sn[@intCast(kk + dk)];
            }
        }.f;
        const down = k == -dd or (k != dd and at(s, dd, k - 1) < at(s, dd, k + 1));
        const pk = if (down) k + 1 else k - 1;
        const px = at(s, dd, pk);
        const py = px - pk;
        // The diagonal run after the edit is skipped by landing on (px, py).
        try steps.append(arena, .{ .x = px, .y = py, .del = !down });
        x = px;
        y = py;
    }

    var i = steps.items.len;
    while (i > 0) {
        i -= 1;
        const st = steps.items[i];
        const px: usize = @as(usize, @intCast(st.x)) + base;
        const py: usize = @as(usize, @intCast(st.y)) + base;
        if (out.items.len > 0) {
            const h = &out.items[out.items.len - 1];
            if (h.a_start + h.a_len == px and h.b_start + h.b_len == py) {
                if (st.del) h.a_len += 1 else h.b_len += 1;
                continue;
            }
        }
        try out.append(arena, .{
            .a_start = px,
            .a_len = if (st.del) 1 else 0,
            .b_start = py,
            .b_len = if (st.del) 0 else 1,
        });
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn run(arena: Allocator, a: []const u8, b: []const u8) ![]const Hunk {
    return diff(arena, try lines(arena, a), try lines(arena, b));
}

/// The oracle: applying the hunks to `a` must give `b`, and no two hunks
/// may touch.
fn expectApplies(arena: Allocator, a: []const u8, b: []const u8) !void {
    const al = try lines(arena, a);
    const bl = try lines(arena, b);
    const hs = try diff(arena, al, bl);
    var out: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    var prev_end: ?usize = null;
    for (hs) |h| {
        try testing.expect(h.a_len != 0 or h.b_len != 0);
        if (prev_end) |p| try testing.expect(h.a_start > p);
        try testing.expect(h.a_start >= pos);
        try out.appendSlice(arena, al[pos..h.a_start]);
        try out.appendSlice(arena, bl[h.b_start .. h.b_start + h.b_len]);
        pos = h.a_start + h.a_len;
        prev_end = pos;
    }
    try out.appendSlice(arena, al[pos..]);
    try testing.expectEqual(bl.len, out.items.len);
    for (bl, out.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "2562 C4: lines cut at newline only, and join is the inverse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), (try lines(a, "")).len);
    try testing.expectEqual(@as(usize, 2), (try lines(a, "a\n")).len);
    try testing.expectEqual(@as(usize, 3), (try lines(a, "a\r\nb\n")).len);
    for ([_][]const u8{ "", "a", "a\n", "\n\n", "a\r\nb" }) |t|
        try testing.expectEqualStrings(t, try join(a, try lines(a, t)));
}

test "2562 C4: hunks are exactly the changed places" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try run(a, "a\nb\nc", "a\nb\nc")).len);

    const one = try run(a, "a\nb\nc", "a\nB\nc");
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(Hunk{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 }, one[0]);

    const ins = try run(a, "a\nc", "a\nb\nc");
    try testing.expectEqual(Hunk{ .a_start = 1, .a_len = 0, .b_start = 1, .b_len = 1 }, ins[0]);

    const del = try run(a, "a\nb\nc", "a\nc");
    try testing.expectEqual(Hunk{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 0 }, del[0]);

    // Two separate places are two hunks.
    const two = try run(a, "a\nb\nc\nd\ne", "A\nb\nc\nd\nE");
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqual(@as(usize, 0), two[0].a_start);
    try testing.expectEqual(@as(usize, 4), two[1].a_start);

    // Everything replaced is one hunk.
    const all = try run(a, "a\nb", "x\ny\nz");
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqual(Hunk{ .a_start = 0, .a_len = 2, .b_start = 0, .b_len = 3 }, all[0]);
}

test "2562 C4: applying the hunks to a gives b, over a table of shapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "", "" },
        .{ "", "a" },
        .{ "a", "" },
        .{ "a\n", "a" },
        .{ "a", "a\n" },
        .{ "a\nb\nc\nd\ne\nf", "b\nc\nX\ne\nf\ng" },
        .{ "x\nx\nx\nx", "x\nx" },
        .{ "a\nb\na\nb\na", "b\na\nb\na\nb" },
        .{ "1\n2\n3\n4\n5\n6\n7\n8\n9", "9\n8\n7\n6\n5\n4\n3\n2\n1" },
        .{ "a\n\n\nb", "a\n\nb\n\n" },
        .{ "a\r\nb", "a\nb" },
    };
    for (cases) |c| try expectApplies(a, c[0], c[1]);
}

test "2562 C4: a long file with a few changes is cheap and right" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    var dst: std.ArrayList(u8) = .empty;
    for (0..20000) |i| {
        try src.print(a, "line {d}\n", .{i});
        if (i % 4000 == 1) try dst.print(a, "changed {d}\n", .{i}) else try dst.print(a, "line {d}\n", .{i});
    }
    try expectApplies(a, src.items, dst.items);
    try testing.expectEqual(@as(usize, 5), (try run(a, src.items, dst.items)).len);
}

test "2562 C4: more edits than the search goes to is an error, not a hang" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    var dst: std.ArrayList(u8) = .empty;
    for (0..max_edits) |i| {
        try src.print(a, "a{d}\n", .{i});
        try dst.print(a, "b{d}\n", .{i});
    }
    try testing.expectError(error.TooDifferent, run(a, src.items, dst.items));
}
