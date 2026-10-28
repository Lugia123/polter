//! Three-way merge by lines, diff3 style (task 2562 C4, PLAN §1.6,
//! `2140/v2/EDITING.md` §4). **The merge is made here, once, in the core**,
//! so the two hosts cannot disagree about it; the editor page only draws the
//! table this returns, and hands the user's choices back.
//!
//! Input: `base` (what the editor was opened on), `mine` (what the editor
//! holds), `theirs` (what the disk holds now). Output: a table of segments,
//! in file order, that cover the whole text:
//!
//! | kind | meaning | what the final text gets |
//! | --- | --- | --- |
//! | `same` | nobody changed it, **or both made the identical change** | the lines |
//! | `mine_only` | only the editor changed it | mine |
//! | `theirs_only` | only the disk changed it | theirs |
//! | `conflict` | both changed it, differently | the user's `Choice` |
//!
//! **"Both made exactly the same change" is not a conflict.** It is a `same`
//! segment whose lines differ from `base`: there is nothing to decide, and
//! asking would put a question on the screen with only one answer.
//!
//! **Changes that touch are one place.** A hunk of mine and a hunk of
//! theirs that overlap, or sit next to each other with no unchanged line
//! between them, are grouped into one region before the two sides are
//! compared (two insertions at the same point included): diff3's rule, and
//! the cautious one -- the alternative is to guess the order of two
//! neighbouring edits.
//!
//! **The guard.** More than `max_segments` segments, or a diff the search
//! gave up on (`Diff.max_edits`), makes the whole file one segment
//! (`Merged.whole_file`): a table of thousands of pieces is not something a
//! person can decide piece by piece, and the search should not be what a
//! large paste costs the app. **It is a conflict only if both sides moved
//! away from `base`**; a side that is `base` has changed nothing, so the
//! other side's change goes in as `mine_only` / `theirs_only`.

const Merge = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diff = @import("Diff.zig");

pub const max_segments: usize = 5000;

pub const Kind = enum { same, mine_only, theirs_only, conflict };

pub const Segment = struct {
    kind: Kind,
    /// The three sides of this stretch, as lines (slices of the texts given).
    /// For `same`, `mine` and `theirs` are equal; for `mine_only`, `theirs`
    /// is `base`, and the other way round for `theirs_only`.
    base: []const []const u8,
    mine: []const []const u8,
    theirs: []const []const u8,
};

pub const Merged = struct {
    segments: []const Segment,
    /// How many `conflict` segments there are: how many `Choice`s `assemble`
    /// wants.
    conflicts: usize,
    /// The guard fired: `segments` is one segment for the whole file.
    whole_file: bool,
};

/// The user's decision for one conflict (PLAN §1.6).
pub const Choice = union(enum) {
    use_mine,
    use_theirs,
    /// Mine, then theirs.
    both,
    /// The text the user typed instead. One trailing `\n` is the end of the
    /// last line, not a further empty line; the empty string is no lines.
    edit: []const u8,
};

pub fn merge(arena: Allocator, base: []const u8, mine: []const u8, theirs: []const u8) Allocator.Error!Merged {
    return mergeLines(
        arena,
        try Diff.lines(arena, base),
        try Diff.lines(arena, mine),
        try Diff.lines(arena, theirs),
    );
}

pub fn mergeLines(
    arena: Allocator,
    base: []const []const u8,
    mine: []const []const u8,
    theirs: []const []const u8,
) Allocator.Error!Merged {
    if (try table(arena, base, mine, theirs)) |segs| {
        if (segs.len <= max_segments) {
            var conflicts: usize = 0;
            for (segs) |s| {
                if (s.kind == .conflict) conflicts += 1;
            }
            return .{ .segments = segs, .conflicts = conflicts, .whole_file = false };
        }
    }
    return wholeFile(arena, base, mine, theirs);
}

fn wholeFile(
    arena: Allocator,
    base: []const []const u8,
    mine: []const []const u8,
    theirs: []const []const u8,
) Allocator.Error!Merged {
    // **Whose change it is still decides**, as in the table: a side that is
    // `base` changed nothing, so the other side's whole-file change is simply
    // that side's, and there is nothing to ask. Only when both sides moved
    // away from `base`, and differently, is it one conflict. (This used to
    // compare only mine with theirs, so a large edit over an unchanged disk
    // came back as a conflict and could not be saved.)
    const kind: Kind = if (linesEql(mine, theirs))
        .same
    else if (linesEql(theirs, base))
        .mine_only
    else if (linesEql(mine, base))
        .theirs_only
    else
        .conflict;
    const segs = try arena.alloc(Segment, 1);
    segs[0] = .{ .kind = kind, .base = base, .mine = mine, .theirs = theirs };
    return .{ .segments = segs, .conflicts = if (kind == .conflict) 1 else 0, .whole_file = true };
}

/// Null when the diff gave up.
fn table(
    arena: Allocator,
    base: []const []const u8,
    mine: []const []const u8,
    theirs: []const []const u8,
) Allocator.Error!?[]const Segment {
    const hm = Diff.diff(arena, base, mine) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooDifferent => return null,
    };
    const ht = Diff.diff(arena, base, theirs) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooDifferent => return null,
    };

    var segs: std.ArrayList(Segment) = .empty;
    var i: usize = 0; // position in base
    var im: usize = 0;
    var it: usize = 0;
    // How far each side's line numbers are from base's, up to `i`.
    var dm: isize = 0;
    var dt: isize = 0;

    while (true) {
        const nm: usize = if (im < hm.len) hm[im].a_start else std.math.maxInt(usize);
        const nt: usize = if (it < ht.len) ht[it].a_start else std.math.maxInt(usize);
        const start = @min(nm, nt);
        if (start == std.math.maxInt(usize)) break;

        if (start > i) {
            try segs.append(arena, .{
                .kind = .same,
                .base = base[i..start],
                .mine = mine[at(i, dm)..at(start, dm)],
                .theirs = theirs[at(i, dt)..at(start, dt)],
            });
            if (segs.items.len > max_segments) return null;
        }

        // The region: grows while a hunk of either side starts inside it or
        // right at its end.
        var re = start;
        const m0 = im;
        const t0 = it;
        var dmi: isize = 0;
        var dti: isize = 0;
        var grew = true;
        while (grew) {
            grew = false;
            while (im < hm.len and hm[im].a_start <= re) : (im += 1) {
                re = @max(re, hm[im].a_start + hm[im].a_len);
                dmi += @as(isize, @intCast(hm[im].b_len)) - @as(isize, @intCast(hm[im].a_len));
                grew = true;
            }
            while (it < ht.len and ht[it].a_start <= re) : (it += 1) {
                re = @max(re, ht[it].a_start + ht[it].a_len);
                dti += @as(isize, @intCast(ht[it].b_len)) - @as(isize, @intCast(ht[it].a_len));
                grew = true;
            }
        }

        const seg_base = base[start..re];
        const seg_mine = mine[at(start, dm)..at(re, dm + dmi)];
        const seg_theirs = theirs[at(start, dt)..at(re, dt + dti)];
        const has_m = im > m0;
        const has_t = it > t0;
        const kind: Kind = if (has_m and !has_t)
            .mine_only
        else if (has_t and !has_m)
            .theirs_only
        else if (linesEql(seg_mine, seg_theirs))
            .same
        else
            .conflict;
        try segs.append(arena, .{ .kind = kind, .base = seg_base, .mine = seg_mine, .theirs = seg_theirs });
        if (segs.items.len > max_segments) return null;

        i = re;
        dm += dmi;
        dt += dti;
    }

    if (i < base.len or at(i, dm) < mine.len or at(i, dt) < theirs.len) {
        try segs.append(arena, .{
            .kind = .same,
            .base = base[i..],
            .mine = mine[at(i, dm)..],
            .theirs = theirs[at(i, dt)..],
        });
    }
    return segs.items;
}

fn at(pos: usize, delta: isize) usize {
    return @intCast(@as(isize, @intCast(pos)) + delta);
}

fn linesEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub const AssembleError = Allocator.Error || error{
    /// A conflict has no `Choice`.
    Unresolved,
    /// More `Choice`s than conflicts.
    TooManyChoices,
};

/// The final text: auto-merged segments as the table says, each conflict as
/// its `Choice` (in file order) says.
pub fn assemble(arena: Allocator, merged: Merged, choices: []const Choice) AssembleError![]u8 {
    if (choices.len > merged.conflicts) return error.TooManyChoices;
    if (choices.len < merged.conflicts) return error.Unresolved;
    var out: std.ArrayList([]const u8) = .empty;
    var c: usize = 0;
    for (merged.segments) |s| switch (s.kind) {
        .same, .mine_only => try out.appendSlice(arena, s.mine),
        .theirs_only => try out.appendSlice(arena, s.theirs),
        .conflict => {
            switch (choices[c]) {
                .use_mine => try out.appendSlice(arena, s.mine),
                .use_theirs => try out.appendSlice(arena, s.theirs),
                .both => {
                    // A last empty line of mine is the file's final newline
                    // (see `Diff.lines`); with theirs after it, it would be a
                    // blank line in the middle.
                    const m = if (s.mine.len > 1 and s.mine[s.mine.len - 1].len == 0) s.mine[0 .. s.mine.len - 1] else s.mine;
                    try out.appendSlice(arena, m);
                    try out.appendSlice(arena, s.theirs);
                },
                .edit => |text| {
                    // **Lines are LF here.** A `\r\n` text is the caller's to
                    // normalise first (`Write.commit` does, for a CRLF file).
                    if (text.len == 0) {} else {
                        const body = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
                        try out.appendSlice(arena, try Diff.lines(arena, body));
                    }
                },
            }
            c += 1;
        },
    };
    return Diff.join(arena, out.items);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn expectKinds(want: []const Kind, m: Merged) !void {
    var buf: [64]Kind = undefined;
    try testing.expect(m.segments.len <= buf.len);
    for (m.segments, 0..) |s, i| buf[i] = s.kind;
    try testing.expectEqualSlices(Kind, want, buf[0..m.segments.len]);
}

test "2562 C4: nobody changed anything is one same segment, and assembles to the text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try merge(a, "a\nb\nc", "a\nb\nc", "a\nb\nc");
    try expectKinds(&.{.same}, m);
    try testing.expectEqual(@as(usize, 0), m.conflicts);
    try testing.expect(!m.whole_file);
    try testing.expectEqualStrings("a\nb\nc", try assemble(a, m, &.{}));
}

test "2562 C4: changes in different places merge by themselves, and say whose they are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "1\n2\n3\n4\n5\n6\n7";
    const mine = "1\nTWO\n3\n4\n5\n6\n7";
    const theirs = "1\n2\n3\n4\n5\nSIX\n7";
    const m = try merge(a, base, mine, theirs);
    try expectKinds(&.{ .same, .mine_only, .same, .theirs_only, .same }, m);
    try testing.expectEqual(@as(usize, 0), m.conflicts);
    try testing.expectEqualStrings("1\nTWO\n3\n4\n5\nSIX\n7", try assemble(a, m, &.{}));
    // The mine_only segment carries all three sides.
    try testing.expectEqualStrings("2", m.segments[1].base[0]);
    try testing.expectEqualStrings("TWO", m.segments[1].mine[0]);
    try testing.expectEqualStrings("2", m.segments[1].theirs[0]);
}

test "2562 C4: insertions and deletions on either side keep the lines straight" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Mine adds two lines at the top, theirs deletes one at the bottom.
    const m = try merge(a, "a\nb\nc\nd", "x\ny\na\nb\nc\nd", "a\nb\nc");
    try expectKinds(&.{ .mine_only, .same, .theirs_only }, m);
    try testing.expectEqualStrings("x\ny\na\nb\nc", try assemble(a, m, &.{}));
    // And the other way round, with the shifts in the middle.
    const m2 = try merge(a, "a\nb\nc\nd\ne", "a\nc\nd\ne", "a\nb\nc\nd\nE\nF");
    try testing.expectEqual(@as(usize, 0), m2.conflicts);
    try testing.expectEqualStrings("a\nc\nd\nE\nF", try assemble(a, m2, &.{}));
}

test "2562 C4: the same place changed two ways is a conflict, and each choice puts the text together" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try merge(a, "a\nb\nc", "a\nMINE\nc", "a\nTHEIRS\nc");
    try expectKinds(&.{ .same, .conflict, .same }, m);
    try testing.expectEqual(@as(usize, 1), m.conflicts);
    try testing.expectEqualStrings("a\nMINE\nc", try assemble(a, m, &.{.use_mine}));
    try testing.expectEqualStrings("a\nTHEIRS\nc", try assemble(a, m, &.{.use_theirs}));
    try testing.expectEqualStrings("a\nMINE\nTHEIRS\nc", try assemble(a, m, &.{.both}));
    try testing.expectEqualStrings("a\nmy own\nsecond\nc", try assemble(a, m, &.{.{ .edit = "my own\nsecond\n" }}));
    try testing.expectEqualStrings("a\nc", try assemble(a, m, &.{.{ .edit = "" }}));
    // One trailing newline is the end of the line; two make a blank one.
    try testing.expectEqualStrings("a\nx\n\nc", try assemble(a, m, &.{.{ .edit = "x\n\n" }}));
}

test "2562 C4: both sides making the identical change is not a conflict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try merge(a, "a\nb\nc", "a\nSAME\nc", "a\nSAME\nc");
    try expectKinds(&.{ .same, .same, .same }, m);
    try testing.expectEqual(@as(usize, 0), m.conflicts);
    // It is a change, not an untouched line: the table still says what it replaced.
    try testing.expectEqualStrings("b", m.segments[1].base[0]);
    try testing.expectEqualStrings("SAME", m.segments[1].mine[0]);
    try testing.expectEqualStrings("a\nSAME\nc", try assemble(a, m, &.{}));
    // Both deleting the same line, and both adding the same line.
    const del = try merge(a, "a\nb\nc", "a\nc", "a\nc");
    try testing.expectEqual(@as(usize, 0), del.conflicts);
    try testing.expectEqualStrings("a\nc", try assemble(a, del, &.{}));
    const ins = try merge(a, "a\nc", "a\nb\nc", "a\nb\nc");
    try testing.expectEqual(@as(usize, 0), ins.conflicts);
    try testing.expectEqualStrings("a\nb\nc", try assemble(a, ins, &.{}));
}

test "2562 C4: changes that touch are one place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Mine changes b, theirs changes c: next to each other, no line between.
    const adj = try merge(a, "a\nb\nc\nd", "a\nB\nc\nd", "a\nb\nC\nd");
    try testing.expectEqual(@as(usize, 1), adj.conflicts);
    try testing.expectEqualStrings("a\nB\nc\nd", try assemble(a, adj, &.{.use_mine}));
    // One line between them: apart, merged by themselves.
    const apart = try merge(a, "a\nb\nc\nd", "a\nB\nc\nd", "a\nb\nc\nD");
    try testing.expectEqual(@as(usize, 0), apart.conflicts);
    try testing.expectEqualStrings("a\nB\nc\nD", try assemble(a, apart, &.{}));
    // Two different insertions at the same point.
    const ins = try merge(a, "a\nc", "a\nM\nc", "a\nT\nc");
    try testing.expectEqual(@as(usize, 1), ins.conflicts);
    try testing.expectEqualStrings("a\nM\nT\nc", try assemble(a, ins, &.{.both}));
    // Mine deletes what theirs edits.
    const de = try merge(a, "a\nb\nc", "a\nc", "a\nB\nc");
    try testing.expectEqual(@as(usize, 1), de.conflicts);
    try testing.expectEqualStrings("a\nc", try assemble(a, de, &.{.use_mine}));
    try testing.expectEqualStrings("a\nB\nc", try assemble(a, de, &.{.use_theirs}));
}

test "2562 C4: several conflicts take their choices in file order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try merge(a, "a\nb\nc\nd\ne", "a\nB1\nc\nd\nE1", "a\nB2\nc\nd\nE2");
    try testing.expectEqual(@as(usize, 2), m.conflicts);
    try testing.expectEqualStrings("a\nB1\nc\nd\nE2", try assemble(a, m, &.{ .use_mine, .use_theirs }));
    try testing.expectEqualStrings("a\nB2\nc\nd\nE1", try assemble(a, m, &.{ .use_theirs, .use_mine }));
    try testing.expectError(error.Unresolved, assemble(a, m, &.{.use_mine}));
    try testing.expectError(error.Unresolved, assemble(a, m, &.{}));
    try testing.expectError(error.TooManyChoices, assemble(a, m, &.{ .use_mine, .use_mine, .use_mine }));
}

test "2562 C4: both keeps no blank line between the two when mine ends in the final newline" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try merge(a, "a", "M\n", "T");
    try testing.expectEqual(@as(usize, 1), m.conflicts);
    try testing.expectEqualStrings("M\nT", try assemble(a, m, &.{.both}));
}

test "2562 C4: the end of the file travels as an empty last line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Mine adds a line and keeps the final newline, theirs edits the top.
    const m = try merge(a, "a\nb\n", "a\nb\nc\n", "A\nb\n");
    try testing.expectEqual(@as(usize, 0), m.conflicts);
    try testing.expectEqualStrings("A\nb\nc\n", try assemble(a, m, &.{}));
    // An empty file on all sides.
    const e = try merge(a, "", "", "");
    try testing.expectEqualStrings("", try assemble(a, e, &.{}));
}

test "2562 C4: past 5000 segments the whole file is one conflict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base: std.ArrayList(u8) = .empty;
    var mine: std.ArrayList(u8) = .empty;
    var theirs: std.ArrayList(u8) = .empty;
    for (0..5400) |i| {
        try base.print(a, "l{d}\n", .{i});
        // Every other line, in the first 5200: 2600 hunks, ~5200 segments.
        if (i < 5200 and i % 2 == 0) try mine.print(a, "m{d}\n", .{i}) else try mine.print(a, "l{d}\n", .{i});
        if (i == 5300) try theirs.print(a, "t{d}\n", .{i}) else try theirs.print(a, "l{d}\n", .{i});
    }
    const m = try merge(a, base.items, mine.items, theirs.items);
    try testing.expect(m.whole_file);
    try testing.expectEqual(@as(usize, 1), m.segments.len);
    try testing.expectEqual(Kind.conflict, m.segments[0].kind);
    try testing.expectEqual(@as(usize, 1), m.conflicts);
    try testing.expectEqualStrings(mine.items, try assemble(a, m, &.{.use_mine}));
    try testing.expectEqualStrings(theirs.items, try assemble(a, m, &.{.use_theirs}));

    // Just under the line: the same shape with 1000 hunks merges normally.
    var mine2: std.ArrayList(u8) = .empty;
    for (0..5400) |i| {
        if (i < 2000 and i % 2 == 0) try mine2.print(a, "m{d}\n", .{i}) else try mine2.print(a, "l{d}\n", .{i});
    }
    const ok = try merge(a, base.items, mine2.items, theirs.items);
    try testing.expect(!ok.whole_file);
    try testing.expectEqual(@as(usize, 0), ok.conflicts);
}

test "2562 C4: a diff the search gives up on is the whole file as one piece, a conflict only if both moved" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base: std.ArrayList(u8) = .empty;
    var mine: std.ArrayList(u8) = .empty;
    for (0..Diff.max_edits) |i| {
        try base.print(a, "a{d}\n", .{i});
        try mine.print(a, "b{d}\n", .{i});
    }
    // The disk did not move: it is mine's change alone, and it can be saved.
    const m = try merge(a, base.items, mine.items, base.items);
    try testing.expect(m.whole_file);
    try testing.expectEqual(Kind.mine_only, m.segments[0].kind);
    try testing.expectEqual(@as(usize, 0), m.conflicts);
    try testing.expectEqualStrings(mine.items, try assemble(a, m, &.{}));
    // And the other way round: the editor did not move.
    const t = try merge(a, base.items, base.items, mine.items);
    try testing.expectEqual(Kind.theirs_only, t.segments[0].kind);
    try testing.expectEqual(@as(usize, 0), t.conflicts);
    try testing.expectEqualStrings(mine.items, try assemble(a, t, &.{}));
    // Both moved, differently: the one case that is a conflict.
    var other: std.ArrayList(u8) = .empty;
    for (0..Diff.max_edits) |i| try other.print(a, "c{d}\n", .{i});
    const c = try merge(a, base.items, mine.items, other.items);
    try testing.expectEqual(@as(usize, 1), c.conflicts);
    // Both sides the same after all: nothing to decide, even then.
    const s = try merge(a, base.items, mine.items, mine.items);
    try testing.expect(s.whole_file);
    try testing.expectEqual(@as(usize, 0), s.conflicts);
}
