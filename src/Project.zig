//! A user's "save this tab as a project": the whole split tree of one tab,
//! each pane's directory and title, and which command-history file (see
//! `CommandHistory.zig`) belongs to which pane -- so that loading the
//! project back can rebuild the tree in a new tab and give each rebuilt
//! pane the history it had when the project was saved.
//!
//! **This is not `poltergeist/Session.zig`.** Session.zig is material for a
//! restart: it is written continuously, its groups come back from disk with
//! nobody in them on purpose, and deciding which terminal on screen now is
//! which one from last night is left to a person. None of that applies
//! here. A project is written once, when the user asks for it, and loading
//! it is not a guess about which pane is which -- there is no ambiguity to
//! leave to a person, because the whole tree is the record. The two files
//! read similarly (hand-rolled JSON, tolerant of the state directory not
//! existing yet) because that shape has already been proven out in this
//! codebase, not because they are the same kind of file.
//!
//! **Reading is strict, on purpose, which is the other way this deviates
//! from Session.zig.** Session.zig treats a corrupt file as no different
//! from a missing one, because it is background material nobody asked for
//! by name. A project is the opposite: the user picked it by name and is
//! about to act on what comes back. Handing back half a tree -- the left
//! child of a split with no right child, because the file happened to be
//! cut off in a syntactically-still-valid place -- would rebuild a tab that
//! silently drops a pane the user had open. So `read` returns a named error
//! instead: `error.NotFound` when there is no such project, `error.Corrupt`
//! when the file exists but couldn't be read whole. Nothing in between.
const Project = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.project);

/// How a split arranges its two children.
///
/// The trap, inherited by every port of this shape so far (see
/// `macos/Sources/Features/Splits/SplitTree.swift` and
/// `windows/split-tree/src/lib.rs`): `horizontal` means the children sit
/// side by side, so the *divider* between them is a vertical line.
/// `vertical` means one above the other. The name describes the
/// arrangement, not the divider.
pub const Direction = enum {
    horizontal,
    vertical,
};

/// A pane: one leaf of the tree.
pub const Leaf = struct {
    /// Where the pane was working.
    cwd: []const u8 = "",

    /// What the pane's tab/title said.
    title: []const u8 = "",

    /// An opaque handle to this pane's history, or empty if it never ran a
    /// command that got captured. What it means is shell-dependent, which
    /// is why this is not called `history_file`:
    ///
    ///   - For shells whose history a Ghostty-owned file can drive (bash,
    ///     zsh), it's a filename under `CommandHistory.defaultDir` -- a
    ///     sibling of the projects directory, not inside it, because a
    ///     pane's history outlives any one project it gets saved into.
    ///   - For fish, it's a *session name*: fish keys its own history
    ///     store by the `fish_history` variable, which has to be set in
    ///     the environment before fish starts, and there is no file Ghostty
    ///     can hand it after the fact. Restoring a fish pane means spawning
    ///     it with `fish_history` set to this value, not pointing it at a
    ///     path.
    ///
    /// Never assume it's a path you can open directly -- check the pane's
    /// shell first.
    history: []const u8 = "",
};

/// A split: two children divided in some direction at some ratio.
pub const Split = struct {
    direction: Direction,

    /// Fraction of the space the left/top child gets, `0.0` to `1.0`.
    ratio: f64,

    left: *const Node,
    right: *const Node,
};

/// One node in the layout tree: either a pane or a split of two more nodes.
pub const Node = union(enum) {
    leaf: Leaf,
    split: Split,
};

/// The whole saved tab.
pub const Snapshot = struct {
    /// The name the user gave it. Also what the file on disk is named
    /// after -- see `pathFor`.
    name: []const u8,

    /// When it was saved, Unix seconds.
    saved_at: i64,

    /// The layout, or null for a tab with nothing worth saving (shouldn't
    /// happen in practice -- a tab always has at least one pane -- but an
    /// empty tree is not a corrupt file, so it round-trips rather than
    /// erroring).
    root: ?*const Node = null,
};

/// One entry from `list`: enough to show a picker without reading every
/// file whole.
pub const Entry = struct {
    name: []const u8,
    saved_at: i64,
};

pub const ReadError = error{
    /// No project by this name exists.
    NotFound,

    /// A project by this name exists but the file could not be read as a
    /// complete, well-formed project. Covers JSON that won't parse at all
    /// (e.g. truncated mid-token) and JSON that parses but is missing a
    /// field a complete project must have (e.g. a split with no `right`) --
    /// both are the same promise to the caller: never a half a tree.
    Corrupt,

    /// `name` sanitizes to nothing a file can be named -- see
    /// `sanitizeFilename`. Reading (or writing, or renaming to) a name
    /// like that can never have succeeded, so this is not a variant of
    /// `NotFound`.
    InvalidName,
} || Allocator.Error;

/// Where projects live, given the state directory Ghostty's xdg helper
/// (`src/os/xdg.zig`'s `state`) returns for the `polter` subdir -- the
/// same root `poltergeist/Session.zig` and friends use. `projects` is a
/// sibling of what lives directly there (`session.json`, `chat/`, ...),
/// not nested inside any of it: a project is a terminal feature, not a
/// Poltergeist one, and has to work with Poltergeist entirely absent.
pub fn defaultDir(alloc: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "projects" });
}

/// The path a project with this name is stored at, under `dir`
/// (`defaultDir`'s return value). Caller owns the returned path.
///
/// The name is sanitized into a filename: path separators, NUL, and other
/// control bytes become `_`, and the result is capped in length. Two names
/// that sanitize to the same filename collide -- last write wins -- which
/// is an accepted rough edge for a first version, the same trade Session.zig
/// makes elsewhere in this codebase for the sake of not needing a second,
/// stable identifier the user never sees. The `name` field inside the file
/// is what's authoritative for display either way.
///
/// `error.InvalidName` when nothing survives sanitizing (an empty name, or
/// one made entirely of the characters that get replaced). This used to
/// fall back to a fixed filename instead, which was worse in two ways at
/// once: `list` filters by `.json` and the fallback didn't have that
/// suffix, so a project saved under it was unfindable forever; and even
/// fixing the suffix would only have moved the bug, since that fallback
/// name collides with any project a user names "project" literally --
/// except this collision silently overwrites the whole file, `name` field
/// included, which is not the accepted rough edge above, because that one
/// only ever happens between two names a user actually chose.
pub fn pathFor(alloc: Allocator, dir: []const u8, name: []const u8) (error{InvalidName} || Allocator.Error)![]const u8 {
    const filename = try sanitizeFilename(alloc, name);
    defer alloc.free(filename);
    return std.fs.path.join(alloc, &.{ dir, filename });
}

const max_filename_len = 200;

fn sanitizeFilename(alloc: Allocator, name: []const u8) (error{InvalidName} || Allocator.Error)![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    for (name) |c| {
        if (buf.items.len >= max_filename_len) break;
        const safe: u8 = switch (c) {
            0...0x1f, 0x7f, '/', '\\' => '_',
            else => c,
        };
        try buf.append(alloc, safe);
    }

    if (buf.items.len == 0) {
        return error.InvalidName;
    }

    try buf.appendSlice(alloc, ".json");
    return buf.toOwnedSlice(alloc);
}

/// Write the snapshot, replacing whatever project of this name was there.
///
/// Written whole and atomically: a half-written project file would be
/// exactly the "half a tree" this whole module exists to never hand back.
pub fn write(
    alloc: Allocator,
    io: std.Io,
    dir: []const u8,
    snapshot: Snapshot,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try writeJson(&s, snapshot);

    const path = try pathFor(alloc, dir, snapshot.name);
    defer alloc.free(path);
    const filename = std.fs.path.basename(path);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var atomic = try d.createFileAtomic(io, filename, .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, buf.written());
    try atomic.replace(io);
}

fn writeJson(s: *std.json.Stringify, snapshot: Snapshot) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(snapshot.name);
    try s.objectField("saved_at");
    try s.write(snapshot.saved_at);
    if (snapshot.root) |root| {
        try s.objectField("root");
        try writeNode(s, root.*);
    }
    try s.endObject();
}

fn writeNode(s: *std.json.Stringify, node: Node) !void {
    switch (node) {
        .leaf => |leaf| {
            try s.beginObject();
            try s.objectField("kind");
            try s.write("leaf");
            if (leaf.cwd.len > 0) {
                try s.objectField("cwd");
                try s.write(leaf.cwd);
            }
            if (leaf.title.len > 0) {
                try s.objectField("title");
                try s.write(leaf.title);
            }
            if (leaf.history.len > 0) {
                try s.objectField("history");
                try s.write(leaf.history);
            }
            try s.endObject();
        },
        .split => |split| {
            try s.beginObject();
            try s.objectField("kind");
            try s.write("split");
            try s.objectField("direction");
            try s.write(@tagName(split.direction));
            try s.objectField("ratio");
            try s.write(split.ratio);
            try s.objectField("left");
            try writeNode(s, split.left.*);
            try s.objectField("right");
            try writeNode(s, split.right.*);
            try s.endObject();
        },
    }
}

/// Read a project by name. Everything it borrows comes from `arena`.
pub fn read(arena: Allocator, io: std.Io, dir: []const u8, name: []const u8) ReadError!Snapshot {
    const path = try pathFor(arena, dir, name);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };

    return parse(arena, bytes);
}

/// The same, for bytes already in hand.
pub fn parse(arena: Allocator, bytes: []const u8) ReadError!Snapshot {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.Corrupt,
    };

    const name = switch (obj.get("name") orelse return error.Corrupt) {
        .string => |s| s,
        else => return error.Corrupt,
    };

    const saved_at: i64 = switch (obj.get("saved_at") orelse return error.Corrupt) {
        .integer => |n| n,
        else => return error.Corrupt,
    };

    const root: ?*const Node = if (obj.get("root")) |r|
        try parseNode(arena, r)
    else
        null;

    return .{ .name = name, .saved_at = saved_at, .root = root };
}

fn parseNode(arena: Allocator, value: std.json.Value) ReadError!*const Node {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.Corrupt,
    };

    const kind = switch (obj.get("kind") orelse return error.Corrupt) {
        .string => |s| s,
        else => return error.Corrupt,
    };

    const node = try arena.create(Node);

    if (std.mem.eql(u8, kind, "leaf")) {
        node.* = .{ .leaf = .{
            .cwd = optionalStr(obj.get("cwd")) orelse "",
            .title = optionalStr(obj.get("title")) orelse "",
            .history = optionalStr(obj.get("history")) orelse "",
        } };
        return node;
    }

    if (std.mem.eql(u8, kind, "split")) {
        const direction_str = switch (obj.get("direction") orelse return error.Corrupt) {
            .string => |s| s,
            else => return error.Corrupt,
        };
        const direction = std.meta.stringToEnum(Direction, direction_str) orelse return error.Corrupt;

        const ratio: f64 = switch (obj.get("ratio") orelse return error.Corrupt) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.Corrupt,
        };

        // Both children are required. A split with only a `left` is
        // exactly the "half a tree" this reader promises never to hand
        // back, so a missing child fails the whole read rather than
        // producing a lopsided node.
        const left = try parseNode(arena, obj.get("left") orelse return error.Corrupt);
        const right = try parseNode(arena, obj.get("right") orelse return error.Corrupt);

        node.* = .{ .split = .{
            .direction = direction,
            .ratio = ratio,
            .left = left,
            .right = right,
        } };
        return node;
    }

    return error.Corrupt;
}

fn optionalStr(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Delete a saved project. `error.NotFound` if there was no such project.
pub fn delete(alloc: Allocator, io: std.Io, dir: []const u8, name: []const u8) !void {
    const path = try pathFor(alloc, dir, name);
    defer alloc.free(path);

    const filename = std.fs.path.basename(path);
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return error.NotFound;
    defer d.close(io);

    d.deleteFile(io, filename) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
}

/// Rename a saved project: same tree, same history file references, new
/// display name -- and, since the filename is derived from the name (see
/// `pathFor`), a new file. `error.NotFound` if `old_name` doesn't exist.
///
/// Not atomic across the two files: the new file is written before the old
/// one is removed, so a crash in between leaves both on disk rather than
/// neither. That is the safe order to fail in -- the project still exists
/// under one of the two names either way.
pub fn rename(
    alloc: Allocator,
    io: std.Io,
    dir: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const old = try read(arena.allocator(), io, dir, old_name);
    try write(alloc, io, dir, .{
        .name = new_name,
        .saved_at = old.saved_at,
        .root = old.root,
    });

    if (!std.mem.eql(u8, old_name, new_name)) {
        delete(alloc, io, dir, old_name) catch |err| switch (err) {
            // The old file is already gone (e.g. both names sanitize to
            // the same filename, so the write above replaced it in
            // place) -- not a failure of the rename.
            error.NotFound => {},
            else => return err,
        };
    }
}

/// List saved projects. Best-effort: an entry this build cannot make sense
/// of is skipped rather than failing the whole listing, because this is an
/// inventory for a picker, not a load -- unlike `read`, nobody asked for
/// any one of these by name yet. Everything is arena-owned.
pub fn list(arena: Allocator, io: std.Io, dir: []const u8) Allocator.Error![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;

    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return entries.items;
    defer d.close(io);

    var it = d.iterate();
    while (true) {
        const dirent = it.next(io) catch break orelse break;
        if (dirent.kind != .file) continue;
        if (!std.mem.endsWith(u8, dirent.name, ".json")) continue;

        const bytes = d.readFileAlloc(
            io,
            dirent.name,
            arena,
            .limited(64 * 1024 * 1024),
        ) catch continue;

        const snapshot = parse(arena, bytes) catch continue;
        try entries.append(arena, .{ .name = snapshot.name, .saved_at = snapshot.saved_at });
    }

    return entries.items;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn tmpDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-project-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn expectNodesEqual(a: Node, b: Node) !void {
    switch (a) {
        .leaf => |al| {
            const bl = switch (b) {
                .leaf => |v| v,
                .split => return error.TestExpectedEqual,
            };
            try testing.expectEqualStrings(al.cwd, bl.cwd);
            try testing.expectEqualStrings(al.title, bl.title);
            try testing.expectEqualStrings(al.history, bl.history);
        },
        .split => |as| {
            const bs = switch (b) {
                .split => |v| v,
                .leaf => return error.TestExpectedEqual,
            };
            try testing.expectEqual(as.direction, bs.direction);
            try testing.expectEqual(as.ratio, bs.ratio);
            try expectNodesEqual(as.left.*, bs.left.*);
            try expectNodesEqual(as.right.*, bs.right.*);
        },
    }
}

test "what is written comes back exactly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const left: Node = .{ .leaf = .{ .cwd = "/work/repo", .title = "✳ retry.py", .history = "a1b2c3.history" } };
    const right: Node = .{ .leaf = .{ .cwd = "/work/repo/tests", .title = "✳ tests" } };
    const root: Node = .{ .split = .{
        .direction = .horizontal,
        .ratio = 0.62,
        .left = &left,
        .right = &right,
    } };

    const snapshot: Snapshot = .{
        .name = "写 retry 装饰器",
        .saved_at = 1_757_000_000,
        .root = &root,
    };

    try write(alloc, io, dir, snapshot);

    const back = try read(alloc, io, dir, "写 retry 装饰器");
    try testing.expectEqualStrings(snapshot.name, back.name);
    try testing.expectEqual(snapshot.saved_at, back.saved_at);
    try expectNodesEqual(root, back.root.?.*);
}

test "a project with no layout round-trips as an empty root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, .{ .name = "blank", .saved_at = 1 });

    const back = try read(alloc, io, dir, "blank");
    try testing.expect(back.root == null);
}

test "a nested tree round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const a: Node = .{ .leaf = .{ .cwd = "/a" } };
    const b: Node = .{ .leaf = .{ .cwd = "/b" } };
    const c: Node = .{ .leaf = .{ .cwd = "/c" } };
    const inner: Node = .{ .split = .{ .direction = .vertical, .ratio = 0.5, .left = &b, .right = &c } };
    const root: Node = .{ .split = .{ .direction = .horizontal, .ratio = 0.3, .left = &a, .right = &inner } };

    try write(alloc, io, dir, .{ .name = "nested", .saved_at = 2, .root = &root });

    const back = try read(alloc, io, dir, "nested");
    try expectNodesEqual(root, back.root.?.*);
}

test "reading a project that was never saved is a named error, not a crash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expectError(error.NotFound, read(alloc, io, dir, "no such project"));
}

test "reading from a directory that does not exist yet is NotFound too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectError(
        error.NotFound,
        read(alloc, io, "/tmp/polter-project-does-not-exist-9c1f", "whatever"),
    );
}

test "a truncated file does not read out half a tree" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const left: Node = .{ .leaf = .{ .cwd = "/a" } };
    const right: Node = .{ .leaf = .{ .cwd = "/b" } };
    const root: Node = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .left = &left, .right = &right } };
    try write(alloc, io, dir, .{ .name = "cutoff", .saved_at = 3, .root = &root });

    // Cut the file off partway through, the way a crash mid-write might
    // leave it (atomic replace makes this specific case unreachable in
    // practice, but the reader shouldn't rely on the writer for safety).
    const path = try pathFor(alloc, dir, "cutoff");
    const whole = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    {
        var f = try d.createFile(io, std.fs.path.basename(path), .{});
        defer f.close(io);
        try f.writeStreamingAll(io, whole[0 .. whole.len / 2]);
    }

    try testing.expectError(error.Corrupt, read(alloc, io, dir, "cutoff"));
}

test "a split missing its right child is Corrupt, not a lopsided tree" {
    // Syntactically valid JSON -- this is not the truncation case above --
    // but semantically incomplete. The strict field check has to catch
    // this on its own; a truncated-JSON test alone wouldn't exercise it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes =
        \\{"name":"lopsided","saved_at":4,"root":{"kind":"split",
        \\"direction":"horizontal","ratio":0.5,
        \\"left":{"kind":"leaf","cwd":"/a"}}}
    ;

    try testing.expectError(error.Corrupt, parse(alloc, bytes));
}

test "an empty name is rejected at write, not saved unfindably" {
    // The bug W3 found mirroring this algorithm: sanitizing an empty (or
    // all-illegal-characters) name used to fall back to a fixed filename
    // with no `.json` suffix, so `list` -- which filters by that suffix --
    // could never find it again. The project existed, forever, invisibly.
    // Rejecting it here is the fix; see `pathFor`'s doc comment for the
    // second trap a bare suffix fix would have opened (a collision with a
    // project named "project" that overwrites *its* `name` field too).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expectError(error.InvalidName, write(alloc, io, dir, .{ .name = "", .saved_at = 1 }));

    // Nothing was written under any name a picker could show.
    const entries = try list(alloc, io, dir);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "a name made entirely of illegal characters still sanitizes to something, and is fine" {
    // Sanitizing substitutes one-for-one ('/' -> '_', a control byte ->
    // '_'), it never drops a byte outright -- so the only name that
    // sanitizes to nothing is one with nothing in it to begin with.
    // Worth a test precisely because it looks like it should hit the same
    // bug and doesn't: this is the case `pathFor`'s doc comment says still
    // round-trips like any other name.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, .{ .name = "/", .saved_at = 2 });
    const back = try read(alloc, io, dir, "/");
    try testing.expectEqualStrings("/", back.name);
}

test "delete removes a project and reading it after is NotFound" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, .{ .name = "gone soon", .saved_at = 5 });
    try delete(alloc, io, dir, "gone soon");

    try testing.expectError(error.NotFound, read(alloc, io, dir, "gone soon"));
}

test "deleting a project that doesn't exist is a named error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expectError(error.NotFound, delete(alloc, io, dir, "never existed"));
}

test "rename keeps the tree and moves the name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const leaf: Node = .{ .leaf = .{ .cwd = "/work" } };
    try write(alloc, io, dir, .{ .name = "old name", .saved_at = 6, .root = &leaf });

    try rename(alloc, io, dir, "old name", "new name");

    const back = try read(alloc, io, dir, "new name");
    try testing.expectEqualStrings("new name", back.name);
    try testing.expectEqual(@as(i64, 6), back.saved_at);
    try expectNodesEqual(leaf, back.root.?.*);

    try testing.expectError(error.NotFound, read(alloc, io, dir, "old name"));
}

test "list finds every saved project and skips a corrupt one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, .{ .name = "alpha", .saved_at = 10 });
    try write(alloc, io, dir, .{ .name = "beta", .saved_at = 20 });

    {
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer d.close(io);
        var f = try d.createFile(io, "garbage.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{not json");
    }

    const entries = try list(alloc, io, dir);
    try testing.expectEqual(@as(usize, 2), entries.len);

    var saw_alpha = false;
    var saw_beta = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "alpha")) saw_alpha = true;
        if (std.mem.eql(u8, e.name, "beta")) saw_beta = true;
    }
    try testing.expect(saw_alpha);
    try testing.expect(saw_beta);
}

test "listing a directory that does not exist yet is empty, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = try list(alloc, io, "/tmp/polter-project-does-not-exist-4a1f");
    try testing.expectEqual(@as(usize, 0), entries.len);
}
