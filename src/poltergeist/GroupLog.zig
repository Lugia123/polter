//! The group shells, so the list is still there in the morning.
//!
//! The panel came back before the group it belongs to did. That was the
//! inconsistency this file closes: `TaskLog.restore` put last night's tasks
//! on screen at nine the next morning while the group they were filed under
//! did not exist, because `Chat` was memory and nothing else.
//!
//! **What comes back is the shell: the name and the note. Never the
//! members.** `README.md`'s third open question refused an automatic
//! restore on the grounds that it would need the program to decide whether
//! the terminal on screen now is the one that was in this group last night,
//! and that is a judgement, and judgements are the supervisor's (P1). That
//! argument is entirely about the members. A group's name is a string.
//! Putting a string back decides nothing. So the line is drawn where the
//! argument actually falls: **the program restores what needs no judgement,
//! the supervisor restores what does**, which it already does by reading
//! `session_recall` and putting terminals back in.
//!
//! ## Where the list comes from, and why not from the session snapshot
//!
//! From `<state>/chat/<group>/` -- the record directories that are already
//! there. Three things follow, and each was a requirement:
//!
//!   * **The list never expires.** There is no telling when somebody will
//!     want last Tuesday's group back, and a group's directory lives as
//!     long as its records do, which is forever. Nothing here decides to
//!     drop one.
//!   * **The snapshot does not grow.** Putting the list in `Session` would
//!     have made a file that is written after every change grow without
//!     bound for as long as Polter is ever used.
//!   * **One truth, not two.** The snapshot is *material*: rendered out of
//!     what `Chat` holds so a supervisor can read it, never read back into
//!     the program. This is the only thing read back. A group name is
//!     therefore written down in exactly one place that matters -- the
//!     directory name -- and turned back into a name by `daylog`, the same
//!     file that turned it into a directory. `gaps.md`'s third section is
//!     about precisely the failure of having two rules for that.
//!
//! ## Where the note lives, and why beside the record rather than in it
//!
//! The directory says the name and nothing else, so the note needs a home.
//! It goes in `<state>/chat/<group>/group.json`, one small file per group,
//! rewritten whole.
//!
//! Beside the day files rather than inside them because it is not an event.
//! Everything in a `daylog` tree is append-only and says a thing happened
//! at a moment; the note is a single current value the supervisor replaces
//! (`Chat.setBrief` replaces rather than appends, deliberately -- it is one
//! memo kept current, not a history of intentions). Appending notes to the
//! record would put them in `group_history` and in front of the person
//! reading last night back, which is not where a memo belongs.
//!
//! In the group's own directory rather than in a file of its own listing
//! every group, because that second file would be the two-truths problem
//! back again: a table of names beside a tree of directories, free to
//! disagree about which groups exist. Here the directory *is* the entry and
//! the file is only what the directory cannot say.
//!
//! ## What `d` in the view removes
//!
//! The listing, and nothing else. `listed: false` in `group.json` is the
//! whole of it -- **no day file is touched, moved, or shortened.** The
//! record red line in `gaps.md` says nothing is ever deleted from it, and
//! `group_compact` took the same position for the same reason: it writes
//! the summary *after* the messages rather than over them. Removing a group
//! from a list the person reads is housekeeping; removing what was said is
//! not ours to do.
//!
//! Failure is a warning and nothing else, like the record it sits in: not
//! being able to write down what a group is for is not a reason to stop the
//! terminals working tonight.

const GroupLog = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");

const log = std.log.scoped(.poltergeist);

/// What one `group.json` may be. It holds a note and a flag; a file past
/// this came from somewhere else.
const max_meta_bytes: usize = 64 * 1024;

/// How much of the end of a day file is read looking for the last `at_ms`.
///
/// One line of chat is capped well under this, so the only way this comes
/// back without a whole line in it is a file somebody else wrote -- which
/// is a group that sorts by its name, not a reason to fail.
const tail_probe_bytes: usize = 16 * 1024;

alloc: Allocator,
io: std.Io,

/// `<state>/chat`, the same root `ChatLog`'s record hangs under. Owned.
dir: []const u8,

/// Borrowed only for its path arithmetic and its directory listing --
/// nothing here holds a file open. `probe` is null because the lines this
/// reads are dated, not numbered.
tree: daylog.Tree,

/// One group as the disk remembers it.
///
/// Everything is owned by the allocator passed to `restore`; free the whole
/// list with `free`.
pub const Shell = struct {
    name: []const u8,
    brief: []const u8,

    /// When anything was last written into this group's record, or zero
    /// when nothing ever was -- a group made and never spoken in, or one
    /// whose files this cannot read. Zero sorts to the bottom of the
    /// inactive half, which is where a group nobody can date belongs.
    last_ms: u64,
};

pub fn open(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!GroupLog {
    const dir = try std.fs.path.join(alloc, &.{ state_dir, "chat" });
    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .tree = .{
            .alloc = alloc,
            .io = io,
            .dir = dir,
            .label = "group log",
            .probe = null,
        },
    };
}

pub fn deinit(self: *GroupLog) void {
    self.tree.deinit();
    self.alloc.free(self.dir);
    self.* = undefined;
}

/// Write down what a group is for, and that it belongs in the list.
///
/// Called when a group is made and whenever its note changes. Writing it on
/// creation as well as on `setBrief` is what makes a group that was never
/// spoken in come back at all: it has no day files, so the directory this
/// makes is the only trace it leaves.
pub fn note(self: *GroupLog, name: []const u8, brief: []const u8) void {
    self.writeMeta(name, brief, true);
}

/// Take a group off the list, leaving every word ever said in it in place.
///
/// The note is carried over rather than blanked. Taking a group off the
/// list is not saying it was never for anything, and putting it back should
/// not lose what it was for.
pub fn forget(self: *GroupLog, name: []const u8) void {
    var kept: ?[]u8 = null;
    defer if (kept) |k| self.alloc.free(k);

    if (self.readMeta(self.alloc, name)) |m| {
        kept = m.brief;
    }

    self.writeMeta(name, if (kept) |k| k else "", false);
}

fn writeMeta(self: *GroupLog, name: []const u8, brief: []const u8, listed: bool) void {
    const seg = daylog.encodeSegment(self.alloc, name) catch return;
    defer self.alloc.free(seg);

    const dir = std.fs.path.join(self.alloc, &.{ self.dir, seg }) catch return;
    defer self.alloc.free(dir);

    std.Io.Dir.cwd().createDirPath(self.io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            warn(err);
            return;
        },
    };

    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();

    var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
    render(&s, brief, listed) catch |err| {
        warn(err);
        return;
    };

    var d = std.Io.Dir.cwd().openDir(self.io, dir, .{}) catch |err| {
        warn(err);
        return;
    };
    defer d.close(self.io);

    // Atomic and owner-only, the same as the session snapshot: this is
    // rewritten in place rather than appended to, so a run that died half
    // way through must not leave a file that parses as something else.
    var atomic = d.createFileAtomic(self.io, meta_name, .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    }) catch |err| {
        warn(err);
        return;
    };
    defer atomic.deinit(self.io);

    atomic.file.writeStreamingAll(self.io, buf.written()) catch |err| {
        warn(err);
        return;
    };
    atomic.replace(self.io) catch |err| warn(err);
}

const meta_name = "group.json";

fn render(s: *std.json.Stringify, brief: []const u8, listed: bool) std.Io.Writer.Error!void {
    try s.beginObject();
    if (brief.len > 0) {
        try s.objectField("brief");
        try s.write(brief);
    }

    // Only when it is false. Being in the list is what a group directory
    // already means, so the ordinary file is a note and nothing else, and
    // the flag is there to say the one thing the directory cannot.
    if (!listed) {
        try s.objectField("listed");
        try s.write(false);
    }
    try s.endObject();
}

const Meta = struct {
    /// Owned by the caller's allocator. Empty rather than null: a group
    /// with no note and a group whose note is empty are the same group.
    brief: []u8,
    listed: bool,
};

/// What `group.json` says, or null when there is no readable one.
///
/// A missing file is not a failure and not an absence from the list. It is
/// what every group directory written before this file existed looks like,
/// and what a group whose note could not be written looks like: the records
/// are there, so the group is there, with no note.
fn readMeta(self: *const GroupLog, alloc: Allocator, name: []const u8) ?Meta {
    const seg = daylog.encodeSegment(self.alloc, name) catch return null;
    defer self.alloc.free(seg);
    return self.readMetaIn(alloc, seg);
}

fn readMetaIn(self: *const GroupLog, alloc: Allocator, seg: []const u8) ?Meta {
    const path = std.fs.path.join(self.alloc, &.{ self.dir, seg, meta_name }) catch
        return null;
    defer self.alloc.free(path);

    const bytes = std.Io.Dir.readFileAlloc(
        .cwd(),
        self.io,
        path,
        self.alloc,
        .limited(max_meta_bytes),
    ) catch return null;
    defer self.alloc.free(bytes);

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        bytes,
        .{},
    ) catch return null;

    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };

    const brief: []const u8 = switch (obj.get("brief") orelse std.json.Value.null) {
        .string => |v| v,
        else => "",
    };

    const listed = switch (obj.get("listed") orelse std.json.Value.null) {
        .bool => |v| v,
        // Anything else, missing included: in the list. See `render`.
        else => true,
    };

    return .{
        .brief = alloc.dupe(u8, brief) catch return null,
        .listed = listed,
    };
}

/// Every group the disk still has a listing for.
///
/// Caller owns the result; free it with `free`. Order is whatever the
/// filesystem gives back -- putting them in the order they should be shown
/// is `Chat.groupsFor`'s job, and it is the one that knows who is in them.
pub fn restore(self: *GroupLog, alloc: Allocator) Allocator.Error![]Shell {
    var out: std.ArrayListUnmanaged(Shell) = .empty;
    errdefer {
        for (out.items) |s| {
            alloc.free(s.name);
            alloc.free(s.brief);
        }
        out.deinit(alloc);
    }

    var d = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch
        return out.toOwnedSlice(alloc);
    defer d.close(self.io);

    var it = d.iterate();
    while (it.next(self.io) catch null) |entry| {
        // `readdir` reports `unknown` on some filesystems, the same as the
        // task log's replay has to allow for.
        const kind = if (entry.kind != .unknown) entry.kind else k: {
            const st = d.statFile(self.io, entry.name, .{
                .follow_symlinks = false,
            }) catch continue;
            break :k st.kind;
        };
        if (kind != .directory) continue;

        const seg = alloc.dupe(u8, entry.name) catch continue;
        defer alloc.free(seg);

        // A directory this tree did not write has no name to give back, so
        // it is left alone rather than guessed at.
        const name = (daylog.decodeSegment(alloc, seg) catch continue) orelse continue;
        errdefer alloc.free(name);

        const meta = self.readMetaIn(alloc, seg);
        defer if (meta) |m| alloc.free(m.brief);

        if (meta) |m| if (!m.listed) {
            alloc.free(name);
            continue;
        };

        const brief = alloc.dupe(u8, if (meta) |m| m.brief else "") catch {
            alloc.free(name);
            continue;
        };

        try out.append(alloc, .{
            .name = name,
            .brief = brief,
            .last_ms = self.lastSpokeIn(seg),
        });
    }

    return out.toOwnedSlice(alloc);
}

pub fn free(alloc: Allocator, shells: []Shell) void {
    for (shells) |s| {
        alloc.free(s.name);
        alloc.free(s.brief);
    }
    alloc.free(shells);
}

/// The `at_ms` on the last complete line of the group's newest day file.
///
/// Read off the record rather than kept in `group.json`, because keeping it
/// there would mean rewriting a file on every message -- and because the
/// record is what the answer is actually about.
fn lastSpokeIn(self: *const GroupLog, seg: []const u8) u64 {
    var days = self.tree.daysIn(self.alloc, seg) catch return 0;
    defer days.deinit(self.alloc);
    if (days.items.len == 0) return 0;

    // `daysIn` sorts newest first, which for once is the direction wanted.
    const day = days.items[0];

    const path = self.tree.partPathIn(self.alloc, seg, day.day, day.part) catch
        return 0;
    defer self.alloc.free(path);

    const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return 0;
    defer file.close(self.io);

    const end = if (file.stat(self.io)) |st| st.size else |_| return 0;
    if (end == 0) return 0;

    const want: usize = @intCast(@min(end, tail_probe_bytes));
    const buf = self.alloc.alloc(u8, want) catch return 0;
    defer self.alloc.free(buf);

    const n = file.readPositionalAll(self.io, buf, end - want) catch return 0;
    const window = buf[0..n];

    // Backwards, taking the first line that parses. The last line of a file
    // a crash cut short is a torn one, which is a normal way for a record
    // to end -- see `daylog` -- and the line before it is a perfectly good
    // answer.
    var lines = std.mem.splitBackwardsScalar(u8, window, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (atMsOf(self.alloc, line)) |at| return at;
    }
    return 0;
}

fn atMsOf(alloc: Allocator, line: []const u8) ?u64 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        line,
        .{},
    ) catch return null;

    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };

    return switch (obj.get("at_ms") orelse return null) {
        .integer => |v| if (v < 0) null else @intCast(v),
        else => null,
    };
}

fn warn(err: anyerror) void {
    log.warn("group log: could not write err={}", .{err});
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn testDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-grouplog-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// A group with a record in it, written the way `ChatLog` writes one.
fn saySomething(
    alloc: Allocator,
    io: std.Io,
    state_dir: []const u8,
    group: []const u8,
    at_ms: i64,
) !void {
    const dir = try std.fs.path.join(alloc, &.{ state_dir, "chat" });
    defer alloc.free(dir);

    var tree: daylog.Tree = .{ .alloc = alloc, .io = io, .dir = dir };
    defer tree.deinit();

    const line = try std.fmt.allocPrint(
        alloc,
        "{{\"seq\":1,\"at_ms\":{d},\"group\":\"{s}\",\"text\":\"hi\"}}\n",
        .{ at_ms, group },
    );
    defer alloc.free(line);

    tree.write(group, at_ms, line);
}

test "a group shell comes back with its name and its note" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    {
        var gl = try GroupLog.open(alloc, io, state);
        defer gl.deinit();
        gl.note("build", "last night's build work");
        gl.note("research", "");
    }

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();

    const shells = try gl.restore(alloc);
    defer free(alloc, shells);

    try testing.expectEqual(@as(usize, 2), shells.len);

    var seen_build = false;
    for (shells) |s| {
        if (std.mem.eql(u8, s.name, "build")) {
            seen_build = true;
            try testing.expectEqualStrings("last night's build work", s.brief);
        }
    }
    try testing.expect(seen_build);
}

test "a group taken off the list stays off it and keeps every record" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    try saySomething(alloc, io, state, "build", 1_700_000_000_000);
    try saySomething(alloc, io, state, "keep", 1_700_000_000_000);

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();
    gl.note("build", "a note worth keeping");
    gl.note("keep", "");

    // Both listed to begin with, which is the control: without this the
    // test below could pass because `restore` never found either.
    {
        const before = try gl.restore(alloc);
        defer free(alloc, before);
        try testing.expectEqual(@as(usize, 2), before.len);
    }

    gl.forget("build");

    const after = try gl.restore(alloc);
    defer free(alloc, after);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqualStrings("keep", after[0].name);

    // And the record is untouched, which is the half the confirmation box
    // promises the person. The day file is still there with its line in it.
    const seg = try daylog.encodeSegment(alloc, "build");
    defer alloc.free(seg);

    var days = try gl.tree.daysIn(alloc, seg);
    defer days.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), days.items.len);

    const path = try gl.tree.partPathIn(alloc, seg, days.items[0].day, days.items[0].part);
    defer alloc.free(path);

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(1 << 16));
    defer alloc.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"group\":\"build\"") != null);
}

test "a group put back on the list keeps the note it had" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();

    gl.note("build", "why this group exists");
    gl.forget("build");

    // Off the list, and the note survived being taken off it.
    {
        const m = gl.readMeta(alloc, "build").?;
        defer alloc.free(m.brief);
        try testing.expect(!m.listed);
        try testing.expectEqualStrings("why this group exists", m.brief);
    }

    gl.note("build", "why this group exists");

    const shells = try gl.restore(alloc);
    defer free(alloc, shells);
    try testing.expectEqual(@as(usize, 1), shells.len);
    try testing.expectEqualStrings("why this group exists", shells[0].brief);
}

test "when a group last spoke is read off its record" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    try saySomething(alloc, io, state, "spoken", 1_700_000_000_000);

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();
    gl.note("spoken", "");
    gl.note("silent", "");

    const shells = try gl.restore(alloc);
    defer free(alloc, shells);
    try testing.expectEqual(@as(usize, 2), shells.len);

    for (shells) |s| {
        if (std.mem.eql(u8, s.name, "spoken")) {
            try testing.expectEqual(@as(u64, 1_700_000_000_000), s.last_ms);
        } else {
            // Never spoken in, so there is no time to give and zero says
            // so rather than the clock lying about it.
            try testing.expectEqual(@as(u64, 0), s.last_ms);
        }
    }
}

test "a directory the tree did not write is not a group" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();
    gl.note("real", "");

    // A shortened name's marker is deliberately not invertible, and a
    // stray directory is somebody else's. Neither may turn up as a group
    // under a name it never had.
    for ([_][]const u8{ "%%00112233445566", "not%valid", "%" }) |junk| {
        const path = try std.fs.path.join(alloc, &.{ state, "chat", junk });
        defer alloc.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
    }

    const shells = try gl.restore(alloc);
    defer free(alloc, shells);

    try testing.expectEqual(@as(usize, 1), shells.len);
    try testing.expectEqualStrings("real", shells[0].name);
}
