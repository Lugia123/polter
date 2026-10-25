//! The working directories of a group (task 2145 C1, PLAN §1.1): the
//! supervisor's, each worker's, and the git worktrees made for them, one row
//! per **real** directory.
//!
//! **Worked out each time, never stored.** A terminal that goes takes its
//! directory with it; nothing here has to be told. The only thing kept
//! between two answers is an id, and that is derived from the real path, so
//! it is the same one again.
//!
//! **One row per real path.** Two terminals standing in the same directory
//! -- one of them through a symlink -- are one row with two names on it, so
//! the page shows whose directory it is rather than listing it twice.
//!
//! **The id is a hash of the real path and never an index.** An index names
//! "the third row", and the third row is somebody else's when a terminal
//! goes; a preview that kept the index would be reading another directory.
//!
//! Pure but for `realpath`, which is the point: the answer is only right if
//! links are followed, so the tests make real ones.

const Workdirs = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
/// The one place that says whether a path is under a directory; the same rule
/// decides this page's rows and what `Access` will read, so it is not written
/// twice.
const inside = @import("Access.zig").inside;

pub const Role = enum { supervisor, worker, own };

/// One terminal of one group. A terminal in two groups is two of these, with
/// the same `id`.
pub const Term = struct {
    id: u64,
    title: []const u8,
    role: Role,
    group: []const u8,
    /// Where the shell last said it was; null when it never said.
    cwd: ?[]const u8,
};

/// A git worktree Polter made (`worktree.Entry`), as far as this needs it.
pub const Tree = struct {
    name: []const u8,
    path: []const u8,
    /// The terminals the ledger remembers for it (`by`, `terminal`); they do
    /// not survive a restart, so a tree whose terminals are gone belongs to
    /// no group and is left out.
    terminals: []const u64,
};

pub const Who = struct { id: u64, title: []const u8, role: Role };

/// Where a row came from. A worktree is not a terminal and must not be drawn
/// as one: it has no terminal id, and a row that showed one as `0x0` would
/// make a tree and a terminal indistinguishable to the host.
pub const Kind = enum { terminal, tree };

/// Why a row may not be read from. One value so far, and the field is an enum
/// rather than a bool so that a second reason cannot be added without the
/// hosts being told about it.
pub const Why = enum {
    /// `/`, the home directory, or the directory above it: a preview of one
    /// of these is a preview of the whole machine. The row is still listed --
    /// "which directory is this" is worth saying -- but nothing in it is read
    /// (`Access.Request.too_wide`).
    too_wide,

    pub fn say(self: Why) []const u8 {
        return switch (self) {
            .too_wide => "this directory is too wide to read from",
        };
    }
};

pub const Dir = struct {
    /// 16 hex digits of a hash of `path`.
    id: []const u8,
    /// Real: every link followed.
    path: []const u8,
    /// `path` with the home directory written `~`; the path itself when it
    /// is not under it.
    short: []const u8,
    /// `.tree` when a worktree of the ledger is this directory, whether or
    /// not a terminal is standing in it.
    kind: Kind,
    /// The worktree's name, when `kind` is `.tree`; null otherwise.
    tree_name: ?[]const u8,
    /// **The terminals** in this directory. Empty for a worktree nobody is
    /// standing in -- which is a row with nothing in `who`, not a row with a
    /// made-up terminal in it.
    who: []const Who,
    /// Other groups a terminal of this row is in.
    also_in: []const []const u8,
    /// False for a row the page lists but nothing may be read from; the
    /// reason is in `why`.
    readable: bool,
    why: ?Why,
    /// Files an agent is changing now (C5); 0 until then.
    editing: u32,
};

pub fn idOf(buf: *[16]u8, real_path: []const u8) []const u8 {
    const h = std.hash.Wyhash.hash(0, real_path);
    return std.fmt.bufPrint(buf, "{x:0>16}", .{h}) catch unreachable;
}

fn shortOf(arena: Allocator, home: ?[]const u8, path: []const u8) Allocator.Error![]const u8 {
    const h = home orelse return path;
    if (h.len == 0) return path;
    if (std.mem.eql(u8, path, h)) return "~";
    if (std.mem.startsWith(u8, path, h) and path.len > h.len and path[h.len] == std.fs.path.sep) {
        return std.fmt.allocPrint(arena, "~{s}", .{path[h.len..]});
    }
    return path;
}

fn rank(r: Role) u8 {
    return switch (r) {
        .supervisor => 0,
        .worker => 1,
        .own => 2,
    };
}

/// The directories of `group`, in the order to draw them: the supervisor's,
/// then the workers', then the person's own, **then the worktrees** -- a tree
/// that a terminal of the group is standing in merges into that terminal's
/// row; every other tree of the group's terminals follows the terminals.
/// `terms` is every terminal of every group (that is how `also_in` is known).
pub fn compute(
    arena: Allocator,
    io: Io,
    group: []const u8,
    terms: []const Term,
    trees: []const Tree,
    home: ?[]const u8,
) Allocator.Error![]const Dir {
    var out: std.ArrayListUnmanaged(Dir) = .empty;
    var whos: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Who)) = .empty;

    // **The home directory, made real once.** A home directory that is itself
    // a link (`/home -> /usr/home`) or that is spelled with a trailing
    // separator is otherwise the one case that slips past `tooWide`, and the
    // rows it is compared against are real paths.
    //
    // **A home directory that cannot be made real does not become "no home
    // directory".** Those are two different facts and they call for opposite
    // answers: no home directory at all means there is nothing above to
    // bound, so only a root is too wide; a home directory that is there but
    // could not be looked at (it is on a volume that is not mounted, a
    // permission says no) must still bound the rows above it, or `/Users`
    // becomes readable because `$HOME` went missing. So the walk falling over
    // falls back to the path **as spelled** (`std.fs.path.resolve`, which
    // settles `.` and `..` but asks nothing of the filesystem) -- weaker than
    // the real path, and still a bound.
    const home_real: ?[]const u8 = if (home) |h| blk: {
        // An empty home directory is the same as none (`App.controlHome`
        // answers `""` when it cannot find one).
        if (h.len == 0) break :blk null;
        break :blk (if (std.Io.Dir.cwd().realPathFileAlloc(io, h, arena)) |real| real else |_| null) orelse try std.fs.path.resolve(arena, &.{h});
    } else null;

    // This group's terminals, supervisor first, stable within a role.
    var mine: std.ArrayListUnmanaged(Term) = .empty;
    for (terms) |t| if (std.mem.eql(u8, t.group, group)) try mine.append(arena, t);
    std.mem.sort(Term, mine.items, {}, struct {
        fn less(_: void, a: Term, b: Term) bool {
            return rank(a.role) < rank(b.role);
        }
    }.less);

    for (mine.items) |t| {
        const cwd = t.cwd orelse continue;
        try add(arena, io, &out, &whos, cwd, null, .{ .id = t.id, .title = t.title, .role = t.role }, home_real);
    }
    for (trees) |tree| {
        const belongs = for (tree.terminals) |tid| {
            if (for (mine.items) |m| {
                if (m.id == tid) break true;
            } else false) break true;
        } else false;
        if (!belongs) continue;
        try add(arena, io, &out, &whos, tree.path, tree.name, null, home_real);
    }

    for (out.items, whos.items) |*d, *w| {
        d.who = w.items;
        var also: std.ArrayListUnmanaged([]const u8) = .empty;
        for (w.items) |who| for (terms) |t| {
            if (t.id != who.id or std.mem.eql(u8, t.group, group)) continue;
            const seen = for (also.items) |g| {
                if (std.mem.eql(u8, g, t.group)) break true;
            } else false;
            if (!seen) try also.append(arena, t.group);
        };
        d.also_in = also.items;
        d.short = try shortOf(arena, home_real, d.path);
    }
    return out.items;
}

/// Whether a directory is one the page lists but nothing may be read from:
/// **any root** (nothing above it to bound it), and **the person's home
/// directory or anything above it** -- `~`, and `/home` when the home
/// directory is `/home/me`. A terminal left standing in one of those would
/// otherwise make a preview of `~/.ssh` one ticket away
/// (`Access.Request.too_wide`).
///
/// `home_real` is the home directory **already made real** by `compute`: a
/// home directory that is itself a link (`/home -> /usr/home`) or that
/// arrives with a trailing separator must not be the one case that slips
/// through. This is compared against the real path of the row, so a terminal
/// standing in the home directory through a link is caught as well.
fn tooWide(real: []const u8, home_real: ?[]const u8) bool {
    // Nothing above it: `/`, `C:\`, a UNC share, a device root. On Windows
    // this is the only test that catches `C:\`, since its length is 3.
    if (std.fs.path.dirname(real) == null) return true;
    const h = home_real orelse return false;
    if (h.len == 0) return false;
    // The home directory itself, or any directory above it.
    return inside(real, h);
}

/// `who` is null for a worktree, which is nobody's terminal: the row is a
/// tree (`.kind`, `.tree_name`) and `who` stays empty unless a terminal of
/// the group is standing in the same directory, in which case this call
/// merges into that terminal's row and marks it a tree as well.
fn add(
    arena: Allocator,
    io: Io,
    out: *std.ArrayListUnmanaged(Dir),
    whos: *std.ArrayListUnmanaged(std.ArrayListUnmanaged(Who)),
    path: []const u8,
    tree_name: ?[]const u8,
    who: ?Who,
    home: ?[]const u8,
) Allocator.Error!void {
    // A directory that is gone, or never was, is not a row: there is nothing
    // to read there, and a preview opened on it could only say so.
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch return;
    // **The row is found by its path, not by its id.** The id is a hash of
    // the path, and two different paths could collide; the path cannot.
    for (out.items, whos.items) |*d, *w| {
        if (!std.mem.eql(u8, d.path, real)) continue;
        if (who) |x| try w.append(arena, x);
        if (tree_name) |n| {
            d.kind = .tree;
            d.tree_name = n;
        }
        return;
    }
    var w: std.ArrayListUnmanaged(Who) = .empty;
    if (who) |x| try w.append(arena, x);
    try whos.append(arena, w);
    var buf: [16]u8 = undefined;
    const wide = tooWide(real, home);
    try out.append(arena, .{
        .id = try arena.dupe(u8, idOf(&buf, real)),
        .path = real,
        .short = real,
        .kind = if (tree_name != null) .tree else .terminal,
        .tree_name = tree_name,
        .who = &.{},
        .also_in = &.{},
        .readable = !wide,
        .why = if (wide) .too_wide else null,
        .editing = 0,
    });
}

pub fn roleName(r: Role) []const u8 {
    return @tagName(r);
}

/// The page's answer. Every key is always there (`API.md` §2.0).
pub fn writeJson(w: *Io.Writer, group: []const u8, dirs: []const Dir) Io.Writer.Error!void {
    try w.print("{{\"page\":\"workdirs\",\"group\":{f},\"dirs\":[", .{std.json.fmt(group, .{})});
    for (dirs, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{f},\"path\":{f},\"short\":{f},\"kind\":\"{s}\",\"tree_name\":", .{
            std.json.fmt(d.id, .{}), std.json.fmt(d.path, .{}), std.json.fmt(d.short, .{}),
            @tagName(d.kind),
        });
        if (d.tree_name) |n| try w.print("{f}", .{std.json.fmt(n, .{})}) else try w.writeAll("null");
        try w.writeAll(",\"who\":[");
        for (d.who, 0..) |x, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("{{\"id\":\"0x{x}\",\"title\":{f},\"role\":\"{s}\"}}", .{ x.id, std.json.fmt(x.title, .{}), roleName(x.role) });
        }
        try w.writeAll("],\"also_in\":[");
        for (d.also_in, 0..) |g, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("{f}", .{std.json.fmt(g, .{})});
        }
        try w.print("],\"readable\":{},\"why\":", .{d.readable});
        if (d.why) |why| try w.print("\"{s}\"", .{@tagName(why)}) else try w.writeAll("null");
        try w.print(",\"editing\":{d}}}", .{d.editing});
    }
    try w.writeAll("]}");
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .root = undefined };
        f.root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return f;
    }
    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }
    fn dir(f: *Fixture, arena: Allocator, name: []const u8) ![]const u8 {
        try f.tmp.dir.createDirPath(testing.io, name);
        return std.fs.path.join(arena, &.{ f.root, name });
    }
};

test "2145 C1: the supervisor's directory comes first, the person's own last" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terms = [_]Term{
        .{ .id = 3, .title = "me", .role = .own, .group = "g", .cwd = try fx.dir(a, "own") },
        .{ .id = 2, .title = "api", .role = .worker, .group = "g", .cwd = try fx.dir(a, "api") },
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "g", .cwd = try fx.dir(a, "boss") },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, null);
    try testing.expectEqual(@as(usize, 3), dirs.len);
    try testing.expectEqualStrings("boss", dirs[0].who[0].title);
    try testing.expectEqualStrings("api", dirs[1].who[0].title);
    try testing.expectEqualStrings("me", dirs[2].who[0].title);
}

test "2145 C1: two terminals in one real directory are one row, whichever way they spell it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real = try fx.dir(a, "shared");
    try fx.tmp.dir.symLink(testing.io, "shared", "link", .{ .is_directory = true });
    const via_link = try std.fs.path.join(a, &.{ fx.root, "link" });
    const terms = [_]Term{
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "g", .cwd = real },
        .{ .id = 2, .title = "api", .role = .worker, .group = "g", .cwd = via_link },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, null);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqual(@as(usize, 2), dirs[0].who.len);
    try testing.expectEqualStrings(real, dirs[0].path);
}

test "2145 C1: the id is the same again, and does not depend on the order or on which terminals are there" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try fx.dir(a, "one");
    const two = try fx.dir(a, "two");
    const both = [_]Term{
        .{ .id = 1, .title = "a", .role = .supervisor, .group = "g", .cwd = one },
        .{ .id = 2, .title = "b", .role = .worker, .group = "g", .cwd = two },
    };
    const first = try compute(a, testing.io, "g", &both, &.{}, null);
    // The supervisor goes: "two" is now row 0, and must still be "two".
    const gone = [_]Term{both[1]};
    const after = try compute(a, testing.io, "g", &gone, &.{}, null);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqualStrings(first[1].id, after[0].id);
    try testing.expect(!std.mem.eql(u8, first[0].id, first[1].id));
    try testing.expectEqual(@as(usize, 16), first[0].id.len);
}

test "2145 C1: a terminal that is in another group too says so, and a directory that is gone is no row" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real = try fx.dir(a, "x");
    const terms = [_]Term{
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "web", .cwd = real },
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "billing", .cwd = real },
        .{ .id = 2, .title = "ghost", .role = .worker, .group = "web", .cwd = try std.fs.path.join(a, &.{ fx.root, "never-was" }) },
        .{ .id = 3, .title = "quiet", .role = .worker, .group = "web", .cwd = null },
    };
    const dirs = try compute(a, testing.io, "web", &terms, &.{}, null);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqual(@as(usize, 1), dirs[0].also_in.len);
    try testing.expectEqualStrings("billing", dirs[0].also_in[0]);
}

test "2145 C1: a worktree of a terminal in the group is a row, one of nobody's is not, and it merges with the terminal standing in it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wt = try fx.dir(a, "wt-api");
    const stranger = try fx.dir(a, "wt-other");
    const terms = [_]Term{.{ .id = 2, .title = "api", .role = .worker, .group = "g", .cwd = wt }};
    const trees = [_]Tree{
        .{ .name = "wt-api", .path = wt, .terminals = &.{2} },
        .{ .name = "wt-other", .path = stranger, .terminals = &.{99} },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &trees, null);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqualStrings("api", dirs[0].who[0].title);
    try testing.expectEqual(Kind.tree, dirs[0].kind);
    try testing.expectEqualStrings("wt-api", dirs[0].tree_name.?);
    // With no terminal standing in it, the tree is a row of its own, and it
    // is a tree: no terminal is invented for it.
    const none = try compute(a, testing.io, "g", &[_]Term{.{ .id = 2, .title = "api", .role = .worker, .group = "g", .cwd = null }}, &trees, null);
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expectEqual(Kind.tree, none[0].kind);
    try testing.expectEqualStrings("wt-api", none[0].tree_name.?);
    try testing.expectEqual(@as(usize, 0), none[0].who.len);
}

test "2145 C1: a tree of a terminal in another group is not this group's row" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mine = try fx.dir(a, "wt-mine");
    const theirs = try fx.dir(a, "wt-theirs");
    // Terminal 7 is in "billing" and nowhere else; terminal 2 is ours.
    const terms = [_]Term{
        .{ .id = 2, .title = "api", .role = .worker, .group = "g", .cwd = null },
        .{ .id = 7, .title = "bill", .role = .worker, .group = "billing", .cwd = null },
    };
    const trees = [_]Tree{
        .{ .name = "wt-mine", .path = mine, .terminals = &.{2} },
        .{ .name = "wt-theirs", .path = theirs, .terminals = &.{7} },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &trees, null);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqualStrings("wt-mine", dirs[0].tree_name.?);
}

test "2145 C1: same directory said twice is one row, and the merge is by path" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try fx.dir(a, "one");
    const two = try fx.dir(a, "two");
    const terms = [_]Term{
        .{ .id = 1, .title = "a", .role = .supervisor, .group = "g", .cwd = one },
        .{ .id = 2, .title = "b", .role = .worker, .group = "g", .cwd = two },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, null);
    try testing.expectEqual(@as(usize, 2), dirs.len);
    // Same directory said twice is one row, whichever way it is spelled --
    // the merge is by path, and the path in the row is the real one.
    const again = [_]Term{
        .{ .id = 1, .title = "a", .role = .supervisor, .group = "g", .cwd = one },
        .{ .id = 3, .title = "c", .role = .worker, .group = "g", .cwd = try std.fs.path.join(a, &.{ one, "..", "one" }) },
    };
    const merged = try compute(a, testing.io, "g", &again, &.{}, null);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(@as(usize, 2), merged[0].who.len);
    try testing.expectEqualStrings(one, merged[0].path);
}

test "2145 C1: the root, the home directory and the one above it are listed and not readable" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A home directory of our own, whose parent directory we can name
    // exactly, and a sibling of it that must stay readable.
    const home = try fx.dir(a, "above/home");
    const above = try fx.dir(a, "above");
    const sibling = try fx.dir(a, "above/other");
    const proj = try fx.dir(a, "proj");
    const terms = [_]Term{
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "g", .cwd = home },
        .{ .id = 2, .title = "api", .role = .worker, .group = "g", .cwd = above },
        .{ .id = 3, .title = "me", .role = .own, .group = "g", .cwd = proj },
        .{ .id = 4, .title = "root", .role = .worker, .group = "g", .cwd = "/" },
        .{ .id = 5, .title = "near", .role = .worker, .group = "g", .cwd = sibling },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, home);
    try testing.expectEqual(@as(usize, 5), dirs.len);
    var wide_seen: usize = 0;
    for (dirs) |d| {
        const wide = std.mem.eql(u8, d.path, home) or std.mem.eql(u8, d.path, above) or std.mem.eql(u8, d.path, "/");
        // The row is always there: which directory this is, is worth saying.
        try testing.expect(d.path.len > 0);
        try testing.expectEqual(!wide, d.readable);
        if (wide) {
            wide_seen += 1;
            try testing.expectEqual(Why.too_wide, d.why.?);
        } else {
            try testing.expectEqual(@as(?Why, null), d.why);
        }
        // `~` is still written as `~`, wide or not.
        if (std.mem.eql(u8, d.path, home)) try testing.expectEqualStrings("~", d.short);
    }
    try testing.expectEqual(@as(usize, 3), wide_seen);
    // The directory beside the home directory is not the one above it: the
    // rule is about the home directory itself, not about a shared parent.
    for (dirs) |d| if (std.mem.eql(u8, d.path, sibling)) try testing.expect(d.readable);
    inline for (@typeInfo(Why).@"enum".fields) |f| {
        const why: Why = @enumFromInt(f.value);
        try testing.expect(why.say().len > 0);
    }
}

test "2145 C1: a directory above the home directory is too wide, however far above it is" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The home directory two levels down: both the directory above it and the
    // one above that are above it, and neither may be read.
    const home = try fx.dir(a, "x/y/me");
    const above = try fx.dir(a, "x/y");
    const grandparent = try fx.dir(a, "x");
    const sibling = try fx.dir(a, "x/y/other");
    const terms = [_]Term{
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "g", .cwd = grandparent },
        .{ .id = 2, .title = "up", .role = .worker, .group = "g", .cwd = above },
        .{ .id = 3, .title = "side", .role = .worker, .group = "g", .cwd = sibling },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, home);
    try testing.expectEqual(@as(usize, 3), dirs.len);
    try testing.expectEqualStrings(grandparent, dirs[0].path);
    try testing.expect(!dirs[0].readable);
    try testing.expectEqual(Why.too_wide, dirs[0].why.?);
    try testing.expectEqualStrings(above, dirs[1].path);
    try testing.expect(!dirs[1].readable);
    try testing.expectEqual(Why.too_wide, dirs[1].why.?);
    // **Beside the home directory is not above it**: a shared parent is not
    // what this is about.
    try testing.expectEqualStrings(sibling, dirs[2].path);
    try testing.expect(dirs[2].readable);
    try testing.expectEqual(@as(?Why, null), dirs[2].why);
}

test "2268: a home directory that cannot be made real still bounds the rows above it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const users = try fx.dir(a, "Users");
    const other = try fx.dir(a, "other");
    // **`$HOME` pointing at a directory that is not there.** It is still the
    // home directory as far as this is concerned -- the person's `~` -- and
    // the directory above it must not become readable because the walk
    // could not be made. `realpath` fails on it (nothing is at that path);
    // the spelled-out path is what this falls back to. Note the fixture has
    // to leave it absent: a home directory that exists would be made real
    // and this would never reach the fallback at all.
    const absent = try std.fs.path.join(a, &.{ fx.root, "Users", "absent" });
    const terms = [_]Term{
        .{ .id = 1, .title = "up", .role = .worker, .group = "g", .cwd = users },
        .{ .id = 2, .title = "side", .role = .worker, .group = "g", .cwd = other },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, absent);
    try testing.expectEqual(@as(usize, 2), dirs.len);
    try testing.expectEqualStrings(users, dirs[0].path);
    try testing.expect(!dirs[0].readable);
    try testing.expectEqual(Why.too_wide, dirs[0].why.?);
    // **And it does not swallow everything.** A directory that is neither
    // the home directory nor above it stays readable: the fallback bounds
    // the rows above the home directory, it does not make every row wide.
    try testing.expectEqualStrings(other, dirs[1].path);
    try testing.expect(dirs[1].readable);
}

test "2268: no home directory at all is not the same as one that could not be looked at" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const users = try fx.dir(a, "Users");
    const terms = [_]Term{.{ .id = 1, .title = "up", .role = .worker, .group = "g", .cwd = users }};
    // With nothing known about a home directory there is nothing above to
    // bound, and a directory that is merely high up is readable. This is the
    // half the other test would otherwise cover up: the two facts have
    // different answers, so a fallback that collapsed them would pass one of
    // these and fail the other.
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, null);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expect(dirs[0].readable);
    // An empty home directory is the same as none: `App.controlHome` answers
    // `""` when it cannot find one, and `""` is not a directory above
    // everything.
    const empty = try compute(a, testing.io, "g", &terms, &.{}, "");
    try testing.expectEqual(@as(usize, 1), empty.len);
    try testing.expect(empty[0].readable);
}

test "2145 C1: a root is too wide even when no home directory is known" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // **Nothing above it is a reason on its own.** With no home directory to
    // compare against, the only thing that catches `/` -- and `C:\` on
    // Windows, where the home directory may be on another drive entirely and
    // `inside` is false of it -- is that there is nothing above it.
    const terms = [_]Term{
        .{ .id = 1, .title = "root", .role = .worker, .group = "g", .cwd = "/" },
        .{ .id = 2, .title = "proj", .role = .worker, .group = "g", .cwd = try fx.dir(a, "proj") },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, null);
    try testing.expectEqual(@as(usize, 2), dirs.len);
    try testing.expectEqualStrings("/", dirs[0].path);
    try testing.expect(!dirs[0].readable);
    try testing.expectEqual(Why.too_wide, dirs[0].why.?);
    try testing.expect(dirs[1].readable);
}

test "2145 C1: a home directory that arrives through a link is the same home directory" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The home directory as this is handed it is a link (`/home -> /usr/home`
    // is the everyday one): it is made real before anything is compared
    // against it, or a terminal standing in the home directory is a row the
    // page would hand over.
    const real_home = try fx.dir(a, "realhome");
    try fx.tmp.dir.symLink(testing.io, "realhome", "homelink", .{ .is_directory = true });
    const home_link = try std.fs.path.join(a, &.{ fx.root, "homelink" });
    const terms = [_]Term{.{ .id = 1, .title = "boss", .role = .supervisor, .group = "g", .cwd = real_home }};
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, home_link);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqualStrings(real_home, dirs[0].path);
    try testing.expect(!dirs[0].readable);
    try testing.expectEqual(Why.too_wide, dirs[0].why.?);
    // And it is still the home directory to look at: `~`.
    try testing.expectEqualStrings("~", dirs[0].short);
}

test "2145 C1: a terminal standing in the home directory through a link is too wide" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real_home = try fx.dir(a, "me");
    const beside = try fx.dir(a, "beside");
    // A link that points at the home directory, and a terminal standing in it.
    try fx.tmp.dir.symLink(testing.io, "me", "into-home", .{ .is_directory = true });
    const via = try std.fs.path.join(a, &.{ fx.root, "into-home" });
    const terms = [_]Term{
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "g", .cwd = via },
        .{ .id = 2, .title = "side", .role = .worker, .group = "g", .cwd = beside },
    };
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, real_home);
    try testing.expectEqual(@as(usize, 2), dirs.len);
    try testing.expectEqualStrings(real_home, dirs[0].path);
    try testing.expect(!dirs[0].readable);
    try testing.expectEqual(Why.too_wide, dirs[0].why.?);
    try testing.expectEqualStrings(beside, dirs[1].path);
    try testing.expect(dirs[1].readable);
}

test "2145 C1: a tree, a terminal and a terminal that came in by a link are three answers and two rows" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try fx.dir(a, "A");
    const two = try fx.dir(a, "B");
    // A link standing in for B, so the third terminal says the same directory
    // in a way this cannot recognise by the string.
    try fx.tmp.dir.symLink(testing.io, "B", "into-B", .{ .is_directory = true });
    const via = try std.fs.path.join(a, &.{ fx.root, "into-B" });
    const terms = [_]Term{
        .{ .id = 1, .title = "boss", .role = .supervisor, .group = "g", .cwd = one },
        .{ .id = 2, .title = "w1", .role = .worker, .group = "g", .cwd = two },
        .{ .id = 3, .title = "w2", .role = .worker, .group = "g", .cwd = via },
    };
    const trees = [_]Tree{.{ .name = "wt-b", .path = two, .terminals = &.{2} }};
    const dirs = try compute(a, testing.io, "g", &terms, &trees, null);
    // A, then B -- and B is one row although three things were said about it:
    // two terminals (one of them by another spelling) and the tree.
    try testing.expectEqual(@as(usize, 2), dirs.len);
    try testing.expectEqualStrings(one, dirs[0].path);
    try testing.expectEqual(@as(usize, 1), dirs[0].who.len);
    try testing.expectEqual(Kind.terminal, dirs[0].kind);
    try testing.expectEqualStrings(two, dirs[1].path);
    try testing.expectEqual(@as(usize, 2), dirs[1].who.len);
    try testing.expectEqual(Kind.tree, dirs[1].kind);
    try testing.expectEqualStrings("wt-b", dirs[1].tree_name.?);
}

test "2145 C1: the page's answer has every key, and writes the home directory as ~" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const real = try fx.dir(a, "proj");
    const terms = [_]Term{.{ .id = 0xab, .title = "boss \"b\"", .role = .supervisor, .group = "g", .cwd = real }};
    const dirs = try compute(a, testing.io, "g", &terms, &.{}, fx.root);
    var w: Io.Writer.Allocating = .init(a);
    try writeJson(&w.writer, "g", dirs);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, w.written(), .{});
    const d = parsed.object.get("dirs").?.array.items[0].object;
    try testing.expectEqualStrings("~/proj", d.get("short").?.string);
    try testing.expectEqualStrings(real, d.get("path").?.string);
    try testing.expect(d.get("also_in") != null);
    try testing.expectEqual(@as(i64, 0), d.get("editing").?.integer);
    try testing.expectEqualStrings("terminal", d.get("kind").?.string);
    try testing.expectEqual(std.json.Value.null, d.get("tree_name").?);
    try testing.expect(d.get("readable").?.bool);
    try testing.expectEqual(std.json.Value.null, d.get("why").?);
    const who = d.get("who").?.array.items[0].object;
    try testing.expectEqualStrings("0xab", who.get("id").?.string);
    try testing.expectEqualStrings("boss \"b\"", who.get("title").?.string);
    try testing.expectEqualStrings("supervisor", who.get("role").?.string);
    // Nothing at all is still a whole answer.
    var e: Io.Writer.Allocating = .init(a);
    try writeJson(&e.writer, "g", &.{});
    try testing.expectEqualStrings("{\"page\":\"workdirs\",\"group\":\"g\",\"dirs\":[]}", e.written());
}
