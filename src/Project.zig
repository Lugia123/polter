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
    cwd: []const u8,

    /// What the pane's tab/title said.
    title: []const u8,

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
    history: []const u8,

    /// This pane's scrollback snapshot, as a name relative to the project
    /// file's snapshot directory: `<ASCII digits>.snap`, or empty for none.
    /// Never a path. The directory is derived by whoever reads the file,
    /// from the file's own path (`<file without its extension>.scrollback/`),
    /// never by sanitizing the project name again -- the three
    /// implementations sanitize names differently (issue #23).
    ///
    /// The number belongs to the pane for its whole life, not to its place
    /// in the tree: swapping two panes must not swap their histories.
    ///
    /// Only a name `isScrollbackName` accepts is read; anything else reads
    /// as empty. The core deletes a snapshot it cannot decode, so this one
    /// field makes a project file a list of files the core may delete, and
    /// `../../elsewhere/keep.snap` passes the core's own `.snap` check.
    scrollback: []const u8,
};

/// Whether `name` is a snapshot name this format writes: 1 to 20 ASCII
/// digits, then `.snap`, and nothing else -- so no separator, drive or `..`
/// can get through. The same rule as `is_scrollback_name` in
/// `windows/host/src/project.rs` and `ProjectScrollback.isSnapshotFilename`
/// on macOS.
pub fn isScrollbackName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".snap")) return false;
    const digits = name[0 .. name.len - ".snap".len];
    if (digits.len == 0 or digits.len > 20) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

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
    root: ?*const Node,

    /// The next scrollback snapshot number this project will hand out
    /// (`next_scrollback` on the wire), or null in a file written before
    /// snapshots existed. Only ever grows, so a number that belonged to a
    /// pane since closed is never handed to a new one -- which would open
    /// the new pane with the old one's history.
    ///
    /// Read and written back even though nothing here allocates: a writer
    /// that dropped a counter it did not use would reset it for the
    /// implementations that do. Anything but a non-negative integer reads
    /// as null, the same as `windows/host/src/project.rs` (`as_u64`).
    next_scrollback: ?u64,
};

// **No field of the file's shape may have a default.** This format has
// three implementations -- this file, `windows/host/src/project.rs`, and
// `macos/Sources/Features/Projects/ProjectDocument.swift` -- and nothing
// compiles all three. A field added here with `= ""` compiles everywhere
// it is not mentioned, `parseNode` included, so the reader could silently
// never fill it. Without a default, every place that builds one of these
// is a compile error naming the field until it says what goes there.
//
// What this cannot see is the other two implementations: the test
// "every field in the shared sample survives this build, and every field
// this build has is in the sample" does that, against
// `test/project-format/all_fields.json`, which the other two read as well.
comptime {
    for (.{ Leaf, Split, Snapshot }) |T| {
        for (std.meta.fields(T)) |f| {
            if (f.default_value_ptr != null) @compileError(
                @typeName(T) ++ "." ++ f.name ++
                    " has a default value; fields of the project file may not" ++
                    " (see the comment above this check in src/Project.zig)",
            );
        }
    }
}

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
/// The name is sanitized into a filename by the rule in `sanitizeFilename`
/// (the same rule as macOS and Windows, pinned by one table they all run).
/// Two names
/// that sanitize to the same filename collide -- last write wins -- which
/// is an accepted rough edge for a first version, the same trade Session.zig
/// makes elsewhere in this codebase for the sake of not needing a second,
/// stable identifier the user never sees. The `name` field inside the file
/// is what's authoritative for display either way.
///
/// `error.InvalidName` for an empty name, the only name nothing survives
/// sanitizing: every other scalar or byte becomes itself or `_`. This used to
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

/// Past this many UTF-8 bytes (the `.json` not counted) a name is cut.
const max_filename_len = 200;

/// Where the rule lives, relative to the repository root. Read by the test
/// "every row of the shared filename table", as are the macOS and Windows
/// implementations' tests (issue #838).
const filename_table_path = "test/fixtures/project-filenames.tsv";

/// The rule that turns a project name into a filename. It is written three
/// times -- here, `sanitize_filename` in `windows/host/src/project.rs`, and
/// `macos/Sources/Features/Projects/ProjectFilename.swift` -- and the three
/// disagreed for most of their lives without anything noticing (issue #23),
/// so the rule is pinned by `test/fixtures/project-filenames.tsv`, which all
/// three run row by row.
///
///   - Walk the name by Unicode scalar. No normalization: NFC and NFD
///     spellings of one name are two filenames.
///   - **Not by grapheme cluster.** The three standard libraries carry
///     different Unicode versions, so a grapheme cut cannot be guaranteed to
///     agree between them. A scalar is the same scalar in all three.
///   - Replace with `_`: every scalar up to U+001F, U+007F, `/`, `\`, and the
///     seven NTFS refuses in a filename, `: * ? " < > |`. (`:` is the one
///     that matters most: NTFS takes `a:b.json` without an error and writes an
///     alternate data stream of a file called `a`.)
///   - Stop before the scalar that would take the result past
///     `max_filename_len` UTF-8 bytes, never inside it -- cutting mid-scalar
///     leaves bytes that are not UTF-8, which APFS refuses as a filename.
///   - Nothing left (only an empty name) is `error.InvalidName`.
///   - Append `.json`.
///
/// **Bytes that are not UTF-8 each become `_`.** Only this implementation
/// needs this rule, because only it can be handed such input: the name is a
/// byte slice here, and a string in Swift and Rust cannot hold invalid
/// UTF-8. It is the same replacement the rule already makes, extended, so
/// the rule stays a total function from bytes to a filename -- a failure
/// path only Zig could reach would be exactly the kind of one-sided
/// behaviour issue #23 was about. Pinned by this file's own test, not the
/// shared table, whose inputs are UTF-8 by construction.
fn sanitizeFilename(alloc: Allocator, name: []const u8) (error{InvalidName} || Allocator.Error)![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    var i: usize = 0;
    while (i < name.len) {
        // One step is one scalar, or one byte that does not start one.
        const scalar: ?[]const u8 = scalar: {
            const len = std.unicode.utf8ByteSequenceLength(name[i]) catch break :scalar null;
            if (i + len > name.len) break :scalar null;
            _ = std.unicode.utf8Decode(name[i..][0..len]) catch break :scalar null;
            break :scalar name[i..][0..len];
        };
        const step = if (scalar) |sc| sc.len else 1;
        const out: []const u8 = if (scalar) |sc|
            if (sc.len == 1 and replaced(sc[0])) "_" else sc
        else
            "_";

        if (buf.items.len + out.len > max_filename_len) break;
        try buf.appendSlice(alloc, out);
        i += step;
    }

    if (buf.items.len == 0) {
        return error.InvalidName;
    }

    try buf.appendSlice(alloc, ".json");
    return buf.toOwnedSlice(alloc);
}

/// The single-byte scalars the rule replaces with `_`. Every one of them is
/// ASCII, so a multi-byte scalar is never replaced.
fn replaced(c: u8) bool {
    return switch (c) {
        0...0x1f, 0x7f, '/', '\\', ':', '*', '?', '"', '<', '>', '|' => true,
        else => false,
    };
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
    if (snapshot.next_scrollback) |n| {
        try s.objectField("next_scrollback");
        try s.write(n);
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
            if (leaf.scrollback.len > 0) {
                try s.objectField("scrollback");
                try s.write(leaf.scrollback);
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

    const next_scrollback: ?u64 = if (obj.get("next_scrollback")) |v| switch (v) {
        .integer => |n| std.math.cast(u64, n),
        else => null,
    } else null;

    return .{ .name = name, .saved_at = saved_at, .root = root, .next_scrollback = next_scrollback };
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
        node.* = .{
            .leaf = .{
                .cwd = optionalStr(obj.get("cwd")) orelse "",
                .title = optionalStr(obj.get("title")) orelse "",
                .history = optionalStr(obj.get("history")) orelse "",
                // Invalid is absent, not corrupt: one bad field should not cost
                // the whole project, and an absent snapshot is an empty pane.
                .scrollback = if (optionalStr(obj.get("scrollback"))) |name|
                    if (isScrollbackName(name)) name else ""
                else
                    "",
            },
        };
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
        .next_scrollback = old.next_scrollback,
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
            try testing.expectEqualStrings(al.scrollback, bl.scrollback);
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

    const left: Node = .{ .leaf = .{ .cwd = "/work/repo", .title = "✳ retry.py", .history = "a1b2c3.history", .scrollback = "0.snap" } };
    const right: Node = .{ .leaf = .{ .cwd = "/work/repo/tests", .title = "✳ tests", .history = "", .scrollback = "" } };
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
        .next_scrollback = 4,
    };

    try write(alloc, io, dir, snapshot);

    const back = try read(alloc, io, dir, "写 retry 装饰器");
    try testing.expectEqualStrings(snapshot.name, back.name);
    try testing.expectEqual(snapshot.saved_at, back.saved_at);
    try testing.expectEqual(snapshot.next_scrollback, back.next_scrollback);
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

    try write(alloc, io, dir, .{ .name = "blank", .saved_at = 1, .root = null, .next_scrollback = null });

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

    const a: Node = .{ .leaf = .{ .cwd = "/a", .title = "", .history = "", .scrollback = "" } };
    const b: Node = .{ .leaf = .{ .cwd = "/b", .title = "", .history = "", .scrollback = "" } };
    const c: Node = .{ .leaf = .{ .cwd = "/c", .title = "", .history = "", .scrollback = "" } };
    const inner: Node = .{ .split = .{ .direction = .vertical, .ratio = 0.5, .left = &b, .right = &c } };
    const root: Node = .{ .split = .{ .direction = .horizontal, .ratio = 0.3, .left = &a, .right = &inner } };

    try write(alloc, io, dir, .{ .name = "nested", .saved_at = 2, .root = &root, .next_scrollback = null });

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

    const left: Node = .{ .leaf = .{ .cwd = "/a", .title = "", .history = "", .scrollback = "" } };
    const right: Node = .{ .leaf = .{ .cwd = "/b", .title = "", .history = "", .scrollback = "" } };
    const root: Node = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .left = &left, .right = &right } };
    try write(alloc, io, dir, .{ .name = "cutoff", .saved_at = 3, .root = &root, .next_scrollback = null });

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

    try testing.expectError(error.InvalidName, write(alloc, io, dir, .{ .name = "", .saved_at = 1, .root = null, .next_scrollback = null }));

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

    try write(alloc, io, dir, .{ .name = "/", .saved_at = 2, .root = null, .next_scrollback = null });
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

    try write(alloc, io, dir, .{ .name = "gone soon", .saved_at = 5, .root = null, .next_scrollback = null });
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

    const leaf: Node = .{ .leaf = .{ .cwd = "/work", .title = "", .history = "", .scrollback = "" } };
    try write(alloc, io, dir, .{ .name = "old name", .saved_at = 6, .root = &leaf, .next_scrollback = 3 });

    try rename(alloc, io, dir, "old name", "new name");

    const back = try read(alloc, io, dir, "new name");
    try testing.expectEqualStrings("new name", back.name);
    try testing.expectEqual(@as(i64, 6), back.saved_at);
    // Dropping the counter on a rename would let the next save hand out a
    // number a closed pane still has a snapshot under.
    try testing.expectEqual(@as(?u64, 3), back.next_scrollback);
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

    try write(alloc, io, dir, .{ .name = "alpha", .saved_at = 10, .root = null, .next_scrollback = null });
    try write(alloc, io, dir, .{ .name = "beta", .saved_at = 20, .root = null, .next_scrollback = null });

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

test "a scrollback name that could name anything but a snapshot here reads as empty" {
    // Accepted: what a writer of this format produces.
    for ([_][]const u8{ "0.snap", "7.snap", "12345678901234567890.snap" }) |ok| {
        try testing.expect(isScrollbackName(ok));
    }
    // Refused: a path, a separator, a drive, no digits, too many digits,
    // something that is not a digit, the wrong suffix.
    for ([_][]const u8{
        "../../elsewhere/keep.snap", "/abs/0.snap", "a/0.snap",                   "..\\0.snap",
        "C:0.snap",                  ".snap",       "123456789012345678901.snap", "1a.snap",
        "-1.snap",                   "0.snap/",     "0.SNAP",                     "0.snapx",
        "",
    }) |bad| {
        try testing.expect(!isScrollbackName(bad));
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const snap = try parse(arena.allocator(),
        \\{"name":"p","saved_at":1,"root":{"kind":"split","direction":"vertical","ratio":0.5,
        \\  "left":{"kind":"leaf","cwd":"/a","scrollback":"../../elsewhere/keep.snap"},
        \\  "right":{"kind":"leaf","cwd":"/b","scrollback":"4.snap"}}}
    );
    // The bad name costs that one field, not the project.
    try testing.expectEqualStrings("", snap.root.?.split.left.leaf.scrollback);
    try testing.expectEqualStrings("/a", snap.root.?.split.left.leaf.cwd);
    try testing.expectEqualStrings("4.snap", snap.root.?.split.right.leaf.scrollback);
}

test "every row of the shared filename table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const table = std.Io.Dir.cwd().readFileAlloc(
        io,
        filename_table_path,
        alloc,
        .limited(1024 * 1024),
    ) catch |err| {
        std.debug.print(
            "cannot read the filename table {s} ({s}): this test runs from the repository root\n",
            .{ filename_table_path, @errorName(err) },
        );
        return err;
    };

    var declared: ?usize = null;
    var rows: usize = 0;
    var failed: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        // Only a trailing \r goes (a Windows checkout). Never trim: the
        // empty-name row *starts* with a tab, and trimming it would shift
        // every column of that row one to the left.
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "# rows: ")) {
                declared = try std.fmt.parseInt(usize, line["# rows: ".len..], 10);
            }
            continue;
        }

        var field: [4][]const u8 = undefined;
        var count: usize = 0;
        var fields = std.mem.splitScalar(u8, line, '\t');
        while (fields.next()) |f| : (count += 1) {
            if (count < field.len) field[count] = f;
        }
        if (count != field.len) {
            std.debug.print(
                "{s}:{d}: {d} fields, want 4 (input, expected, status, note)\n",
                .{ filename_table_path, number, count },
            );
            return error.TestUnexpectedResult;
        }
        const input_hex, const expected_hex, const status, const note = field;
        rows += 1;

        const input = try alloc.alloc(u8, input_hex.len / 2);
        _ = try std.fmt.hexToBytes(input, input_hex);

        const got: []const u8 = sanitizeFilename(alloc, input) catch |err| switch (err) {
            error.InvalidName => "ERR:InvalidName",
            else => return err,
        };
        const want: []const u8 = if (std.mem.eql(u8, expected_hex, "ERR:InvalidName"))
            expected_hex
        else want: {
            const bytes = try alloc.alloc(u8, expected_hex.len / 2);
            _ = try std.fmt.hexToBytes(bytes, expected_hex);
            break :want bytes;
        };

        // `draft` rows are run and counted, not asserted: see the table's
        // header.
        if (std.mem.eql(u8, status, "draft")) continue;
        if (!std.mem.eql(u8, got, want)) {
            failed += 1;
            std.debug.print(
                "{s}:{d} ({s}): src/Project.zig sanitizeFilename gave {x} want {x}\n",
                .{ filename_table_path, number, note, got, want },
            );
        }
    }

    // A reader that finds nothing, or finds less than the table has, passes
    // every row it did find. This is what fails it.
    const want_rows = declared orelse {
        std.debug.print("{s}: no '# rows: N' line\n", .{filename_table_path});
        return error.TestUnexpectedResult;
    };
    if (rows != want_rows or rows == 0) {
        std.debug.print("{s}: read {d} rows, the table says {d}\n", .{ filename_table_path, rows, want_rows });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

test "bytes that are not UTF-8 each become an underscore, and nothing is cut inside a scalar" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // A byte that starts nothing.
        .{ .in = "\xff", .want = "_.json" },
        // A lone continuation byte.
        .{ .in = "a\x80b", .want = "a_b.json" },
        // `写` cut after two of its three bytes: both left over.
        .{ .in = "a\xe5\x86", .want = "a__.json" },
        // Two bytes of `写`, then a character that is not a continuation.
        .{ .in = "\xe5\x86z", .want = "__z.json" },
        // An overlong `/`: not UTF-8, so not a separator either -- two
        // underscores, not one.
        .{ .in = "\xc0\xaf", .want = "__.json" },
        // A surrogate half.
        .{ .in = "\xed\xa0\x80", .want = "___.json" },
        // Past U+10FFFF.
        .{ .in = "\xf4\x90\x80\x80", .want = "____.json" },
        // Valid scalars around the invalid ones are kept as they are.
        .{ .in = "\xe5\x86\x99\xff\xe5\x86\x99", .want = "\xe5\x86\x99_\xe5\x86\x99.json" },
    };
    for (cases) |c| {
        const got = try sanitizeFilename(alloc, c.in);
        try testing.expectEqualSlices(u8, c.want, got);
        try testing.expect(std.unicode.utf8ValidateSlice(got));
    }

    // Each invalid byte counts one toward the cap, like the `_` it becomes.
    const long = [_]u8{0xff} ** 250;
    const got = try sanitizeFilename(alloc, &long);
    try testing.expectEqual(@as(usize, max_filename_len + ".json".len), got.len);
}

// -- the shared sample --------------------------------------------------------

/// One project with every field of the format filled in, each with its own
/// value. It is read by the tests of all three implementations of this
/// format -- this one, `windows/host/src/project.rs`, and
/// `macos/Tests/Projects/SharedProjectSampleTests.swift` -- and each of them
/// checks the same things against it: every key in it survives that
/// implementation's read-then-write, and every field that implementation
/// has is a key in it. **Adding a field means adding it there first**; the
/// test in each implementation that has not caught up yet then goes red
/// and names the key.
///
/// It lives under `test/`, not beside this file, because it is the judge
/// between three implementations rather than a fixture of this one. That
/// puts it outside this module's package path, so it cannot be
/// `@embedFile`d ("embed of file outside package path") and is read at
/// test time instead, relative to the repository root -- which is where
/// `zig build test` runs. Not finding it is a failure, never a skip.
const all_fields_sample_path = "test/project-format/all_fields.json";

/// The keys found on each kind of object in a project file. `kind` is the
/// discriminator, not a field, so it is in none of them.
const KeySets = struct {
    snapshot: std.StringArrayHashMapUnmanaged(void) = .empty,
    leaf: std.StringArrayHashMapUnmanaged(void) = .empty,
    split: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn of(alloc: Allocator, file: std.json.Value) !KeySets {
        var sets: KeySets = .{};
        const obj = switch (file) {
            .object => |o| o,
            else => return error.Corrupt,
        };
        var it = obj.iterator();
        while (it.next()) |e| try sets.snapshot.put(alloc, e.key_ptr.*, {});
        if (obj.get("root")) |root| try sets.addNode(alloc, root);
        return sets;
    }

    fn addNode(self: *KeySets, alloc: Allocator, node: std.json.Value) !void {
        const obj = switch (node) {
            .object => |o| o,
            else => return error.Corrupt,
        };
        const kind = switch (obj.get("kind") orelse return error.Corrupt) {
            .string => |s| s,
            else => return error.Corrupt,
        };
        const set = if (std.mem.eql(u8, kind, "leaf"))
            &self.leaf
        else if (std.mem.eql(u8, kind, "split"))
            &self.split
        else
            return error.Corrupt;
        var it = obj.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "kind")) continue;
            try set.put(alloc, e.key_ptr.*, {});
        }
        if (set == &self.split) {
            try self.addNode(alloc, obj.get("left") orelse return error.Corrupt);
            try self.addNode(alloc, obj.get("right") orelse return error.Corrupt);
        }
    }
};

/// Prints one line per key the two sets disagree on, saying which file to
/// change. Returns whether they agreed.
fn sampleKeysAgree(
    comptime what: []const u8,
    sample: std.StringArrayHashMapUnmanaged(void),
    written: std.StringArrayHashMapUnmanaged(void),
) bool {
    var ok = true;
    for (sample.keys()) |k| if (!written.contains(k)) {
        ok = false;
        std.debug.print(
            "src/Project.zig loses {s}.{s}: it is in test/project-format/all_fields.json" ++
                " but does not come back out of parse + writeJson -- carry it in the type," ++
                " parseNode/parse and writeNode/writeJson\n",
            .{ what, k },
        );
    };
    for (written.keys()) |k| if (!sample.contains(k)) {
        ok = false;
        std.debug.print(
            "src/Project.zig writes {s}.{s}, which test/project-format/all_fields.json" ++
                " does not have -- add it there, then to windows/host/src/project.rs and" ++
                " macos/Sources/Features/Projects/ProjectDocument.swift, whose tests read" ++
                " the same file\n",
            .{ what, k },
        );
    };
    return ok;
}

/// Every field of `T` is a key of `sample`. Catches the one case the
/// read-then-write comparison cannot: a field this build has that it
/// neither writes nor finds in the sample. Relies on field names being the
/// JSON keys, which is true of every field today.
fn fieldsAreInSample(
    comptime T: type,
    comptime what: []const u8,
    sample: std.StringArrayHashMapUnmanaged(void),
) bool {
    var ok = true;
    inline for (std.meta.fields(T)) |f| if (!sample.contains(f.name)) {
        ok = false;
        std.debug.print(
            "Project." ++ what ++ " has a field `" ++ f.name ++ "` but" ++
                " test/project-format/all_fields.json has no " ++ what ++ "." ++ f.name ++
                " -- add it to the sample, and make writeNode/writeJson write it\n",
            .{},
        );
    };
    return ok;
}

fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    const num = struct {
        fn of(v: std.json.Value) ?f64 {
            return switch (v) {
                .integer => |n| @floatFromInt(n),
                .float => |f| f,
                else => null,
            };
        }
    };
    if (num.of(a)) |x| return if (num.of(b)) |y| x == y else false;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |p, q| {
            if (!jsonEql(p, q)) break false;
        } else true,
        .object => |x| b == .object and x.count() == b.object.count() and for (x.keys()) |k| {
            const other = b.object.get(k) orelse break false;
            if (!jsonEql(x.get(k).?, other)) break false;
        } else true,
        else => false,
    };
}

test "every field in the shared sample survives this build, and every field this build has is in the sample" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const all_fields_sample = std.Io.Dir.cwd().readFileAlloc(
        io,
        all_fields_sample_path,
        alloc,
        .limited(1024 * 1024),
    ) catch |err| {
        std.debug.print(
            "cannot read the shared sample {s} ({s}): this test runs from the repository root\n",
            .{ all_fields_sample_path, @errorName(err) },
        );
        return err;
    };

    const sample = try std.json.parseFromSliceLeaky(std.json.Value, alloc, all_fields_sample, .{});

    var buf: std.Io.Writer.Allocating = .init(alloc);
    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    try writeJson(&s, try parse(alloc, all_fields_sample));
    const written = try std.json.parseFromSliceLeaky(std.json.Value, alloc, buf.written(), .{});

    const want: KeySets = try .of(alloc, sample);
    const got: KeySets = try .of(alloc, written);

    // Each is its own line so that one disagreement does not hide the next.
    var ok = true;
    if (!sampleKeysAgree("snapshot", want.snapshot, got.snapshot)) ok = false;
    if (!sampleKeysAgree("leaf", want.leaf, got.leaf)) ok = false;
    if (!sampleKeysAgree("split", want.split, got.split)) ok = false;
    if (!fieldsAreInSample(Snapshot, "snapshot", want.snapshot)) ok = false;
    if (!fieldsAreInSample(Leaf, "leaf", want.leaf)) ok = false;
    if (!fieldsAreInSample(Split, "split", want.split)) ok = false;
    try testing.expect(ok);

    // Same keys is not same values: a writer that put `title` under `cwd`
    // and `cwd` under `title` passes everything above.
    if (!jsonEql(sample, written)) {
        std.debug.print("src/Project.zig read + wrote the shared sample back as:\n{s}\n", .{buf.written()});
        return error.TestExpectedEqual;
    }
}
