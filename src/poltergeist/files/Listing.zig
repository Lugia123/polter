//! One directory of a working directory, one level deep (task 2668;
//! `polter-artifacts/2145/PLAN.md` §2.5's `files_list(token, rel_dir)`, which
//! was planned there and never written).
//!
//! **The core says what is in a directory and the host draws it.** The order
//! is decided here -- directories first, then by name, ASCII case ignored --
//! so the two hosts cannot come to differ about it.
//! `tools/control-room-hosts-do-not-decide.py` refuses a host that sorts, and
//! the reason it gives is the reason this file exists: a second order worked
//! out on the host is a second answer about what the tree looks like, and the
//! second answer is the one on screen.
//!
//! **What is left out is `Watch.excluded_dirs`** -- `.git`, `node_modules`,
//! `.zig-cache`, `zig-out`, `target`, `.build`, `DerivedData` -- which is the
//! one table the change watcher already uses. "The tree does not show the
//! build output" and "the watcher does not report it" are then one rule
//! rather than two, and case is ignored on the filesystems that ignore it
//! (`Watch.default_ignore_case`, which is `Watch`'s rule and not a second
//! one). `.gitignore` is not read, on `Watch`'s terms.
//!
//! **A level of names, and nothing else.** No file's bytes are read here and
//! no size or time is asked for: the design's tree rows are a name and an
//! icon, and one `stat` per entry is a syscall on the app thread for a
//! number nobody draws. The one exception is a link, whose target decides
//! whether it is a folder -- a link to a directory that drew as a file would
//! be a row that cannot be opened.
//!
//! **Over `max_entries` the answer says how many were left**, rather than
//! being cut off in silence: `more` is what the design draws as 「还有 N 个」.
//! The whole level is collected before it is cut, because which 2000 a sorted
//! level keeps cannot be known until it is sorted -- cutting during the walk
//! would keep whichever 2000 the filesystem happened to hand over first.
//!
//! Pure but for the directory read itself, which is the point: the tests make
//! real directories and read them.

const Listing = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Watch = @import("Watch.zig");

/// The most rows one level answers with. Past it the answer carries `more`
/// and the host draws 「还有 N 个」 (`polter-artifacts/2665/v3`, the supervisor's
/// ruling of 2026-11-02).
pub const max_entries: usize = 2000;

/// One thing in a directory, as the tree draws it.
pub const Entry = struct {
    /// The name only, never a path: the level is already known.
    name: []const u8,
    /// A directory, or a link that leads to one. Decides which icon the host
    /// draws and whether the row opens.
    is_dir: bool,
};

pub const Answer = struct {
    /// Directories first, then by name. At most `max_entries` of them.
    entries: []const Entry,
    /// How many were left out past `max_entries`; 0 when all of them fit.
    more: usize,
};

/// What is directly inside `dir`, or null when it cannot be read at all.
///
/// ⚠️ **Null and an empty answer are two different things**, which is why
/// this is not an empty list: a directory that is empty and one that may not
/// be opened draw the same tree, but only one of them is a fact about the
/// directory. The caller says the other one out loud (`Tickets.list` answers
/// a refusal), the way `Access` answers `unreadable` rather than "nothing
/// there".
pub fn of(arena: Allocator, io: Io, dir: []const u8) Allocator.Error!?Answer {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);

    var all: std.ArrayListUnmanaged(Entry) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (Watch.isExcluded(e.name)) continue;
        const is_dir = switch (e.kind) {
            .directory => true,
            // **The link's target decides.** `entry.kind` is the link
            // itself, so a folder reached through one would otherwise draw
            // as a file and be a row nobody can open.
            .sym_link => blk: {
                const st = d.statFile(io, e.name, .{}) catch break :blk false;
                break :blk st.kind == .directory;
            },
            else => false,
        };
        try all.append(arena, .{ .name = try arena.dupe(u8, e.name), .is_dir = is_dir });
    }

    std.mem.sort(Entry, all.items, {}, less);

    if (all.items.len <= max_entries) return .{ .entries = all.items, .more = 0 };
    return .{
        .entries = all.items[0..max_entries],
        .more = all.items.len - max_entries,
    };
}

/// Directories first; then by name with ASCII case ignored; and, for two
/// names that differ only in case, by their bytes -- so `A.txt` and `a.txt`
/// always come in the same order rather than in whichever one the filesystem
/// handed over first. A stable order matters here because the host draws the
/// rows in the order it is given them and does not sort.
fn less(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const o = std.ascii.orderIgnoreCase(a.name, b.name);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// The answer as JSON, in the shape a host reads.
///
/// **`is_dir` and not `kind`.** The gate that holds "a host draws and does
/// not decide" refuses a host that reads a `kind` at all, on the ground that
/// there is nothing a kind is for except comparing it; `is_dir` is the one
/// thing the row is asked and cannot be compared with anything.
pub fn writeJson(w: *Io.Writer, a: Answer) Io.Writer.Error!void {
    try w.writeAll("{\"entries\":[");
    for (a.entries, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":{f},\"is_dir\":{}}}", .{ std.json.fmt(e.name, .{}), e.is_dir });
    }
    try w.print("],\"more\":{d}}}", .{a.more});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// A real temporary directory, because the read is a real one.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena: std.heap.ArenaAllocator,

    fn init() !Fixture {
        var f: Fixture = .{
            .tmp = testing.tmpDir(.{}),
            .root = undefined,
            .arena = .init(testing.allocator),
        };
        errdefer f.tmp.cleanup();
        f.root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return f;
    }

    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.root);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn a(f: *Fixture) Allocator {
        return f.arena.allocator();
    }

    fn dir(f: *Fixture, sub: []const u8) !void {
        try f.tmp.dir.createDirPath(testing.io, sub);
    }

    fn put(f: *Fixture, sub: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }
};

test "2668 S1: a level is directories first, then by name, case ignored" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.dir("w/zeta");
    try f.dir("w/Alpha");
    try f.put("w/b.txt", "b");
    try f.put("w/a.txt", "a");
    try f.put("w/Middle.txt", "m");

    const got = (try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w" }))).?;
    try testing.expectEqual(@as(usize, 5), got.entries.len);
    try testing.expectEqual(@as(usize, 0), got.more);
    try testing.expectEqualStrings("Alpha", got.entries[0].name);
    try testing.expect(got.entries[0].is_dir);
    try testing.expectEqualStrings("zeta", got.entries[1].name);
    try testing.expect(got.entries[1].is_dir);
    // Case ignored: `a.txt` before `b.txt` before `Middle.txt`, which a
    // byte-wise order would have put second.
    try testing.expectEqualStrings("a.txt", got.entries[2].name);
    try testing.expectEqualStrings("b.txt", got.entries[3].name);
    try testing.expectEqualStrings("Middle.txt", got.entries[4].name);
    // `is_dir` is a fact about the row, and the files are not directories.
    for (got.entries[2..]) |e| try testing.expect(!e.is_dir);
}

test "2668 S1: the order is a total one, so two names that differ only in case never swap" {
    // **A pure test, and it has to be**: a case-insensitive filesystem
    // (APFS, NTFS) cannot hold `B.txt` and `b.txt` at once, so a level made
    // of real files could never reach this tie to check it. This is the
    // tie-break the whole order rests on -- without it the two rows come in
    // whichever order the directory handed them over, which is the thing
    // `std.mem.sort` is allowed to do and the host may not fix.
    const rows = [_]Entry{
        .{ .name = "b.txt", .is_dir = false },
        .{ .name = "B.txt", .is_dir = false },
        .{ .name = "sub", .is_dir = true },
        .{ .name = "A.txt", .is_dir = false },
    };
    var sorted = rows;
    std.mem.sort(Entry, &sorted, {}, less);
    try testing.expectEqualStrings("sub", sorted[0].name);
    try testing.expectEqualStrings("A.txt", sorted[1].name);
    try testing.expectEqualStrings("B.txt", sorted[2].name);
    try testing.expectEqualStrings("b.txt", sorted[3].name);

    // And the same comparison the other way round: the order is a strict
    // one and not "less or equal" wearing one name.
    try testing.expect(!less({}, rows[0], rows[1]));
    try testing.expect(less({}, rows[1], rows[0]));
}

test "2668 S1: the directories nobody wants to hear about are not listed either" {
    var f = try Fixture.init();
    defer f.deinit();
    // The whole of `Watch.excluded_dirs`, plus names that only begin like
    // one of them, which are not excluded.
    for ([_][]const u8{ ".git", "node_modules", ".zig-cache", "zig-out", "target", ".build", "DerivedData" }) |name| {
        try f.dir(try std.fs.path.join(f.a(), &.{ "w", name }));
    }
    try f.dir("w/targets");
    try f.dir("w/.gitignore-d");
    try f.put("w/keep.txt", "k");

    const got = (try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w" }))).?;
    try testing.expectEqual(@as(usize, 3), got.entries.len);
    for ([_][]const u8{ ".gitignore-d", "targets", "keep.txt" }, 0..) |want, i| {
        try testing.expectEqualStrings(want, got.entries[i].name);
    }
}

test "2668 S1: over the limit the answer says how many were left, and the ones kept are the first of the order" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.dir("w");
    // One past the limit, so exactly one is left out.
    const n = max_entries + 1;
    for (0..n) |i| {
        // Zero-padded so the names sort the way they are numbered.
        try f.put(try std.fmt.allocPrint(f.a(), "w/{d:0>5}.txt", .{i}), "");
    }

    const got = (try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w" }))).?;
    try testing.expectEqual(max_entries, got.entries.len);
    try testing.expectEqual(@as(usize, 1), got.more);
    // The kept ones are the *first* of the sorted order, not the first the
    // filesystem happened to hand over.
    try testing.expectEqualStrings("00000.txt", got.entries[0].name);
    try testing.expectEqualStrings("01999.txt", got.entries[max_entries - 1].name);
}

test "2668 S1: a directory that cannot be opened is not the same answer as an empty one" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.dir("w/empty");

    const empty = (try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w", "empty" }))).?;
    try testing.expectEqual(@as(usize, 0), empty.entries.len);
    try testing.expectEqual(@as(usize, 0), empty.more);

    // Nothing there at all: null, so the caller can say so rather than draw
    // a tree that happens to be empty.
    try testing.expect((try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w", "gone" }))) == null);
    // A file is not a directory to list either.
    try f.put("w/a.txt", "a");
    try testing.expect((try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w", "a.txt" }))) == null);
}

test "2668 S1: a link to a directory is a directory, and a link to a file is not" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.dir("w/real");
    try f.put("w/real.txt", "r");
    try f.tmp.dir.symLink(testing.io, "real", "w/link-dir", .{ .is_directory = true });
    try f.tmp.dir.symLink(testing.io, "real.txt", "w/link-file", .{});

    const got = (try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w" }))).?;
    const dirs = for (got.entries) |e| {
        if (std.mem.eql(u8, e.name, "link-dir")) break e.is_dir;
    } else return error.NoLinkDir;
    const files = for (got.entries) |e| {
        if (std.mem.eql(u8, e.name, "link-file")) break e.is_dir;
    } else return error.NoLinkFile;
    try testing.expect(dirs);
    try testing.expect(!files);
}

test "2668 S1: the answer is JSON a host can read, with every key always there" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.dir("w/sub");
    try f.put("w/a.txt", "a");

    const got = (try of(f.a(), testing.io, try std.fs.path.join(f.a(), &.{ f.root, "w" }))).?;
    var out: Io.Writer.Allocating = .init(f.a());
    try writeJson(&out.writer, got);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, f.a(), out.written(), .{});
    const entries = v.object.get("entries").?.array;
    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expectEqualStrings("sub", entries.items[0].object.get("name").?.string);
    try testing.expect(entries.items[0].object.get("is_dir").?.bool);
    try testing.expectEqualStrings("a.txt", entries.items[1].object.get("name").?.string);
    try testing.expect(!entries.items[1].object.get("is_dir").?.bool);
    try testing.expectEqual(@as(i64, 0), v.object.get("more").?.integer);
}
