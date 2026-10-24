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
const Marks = @import("Chat.zig").Marks;
const LastSupervisor = @import("Chat.zig").LastSupervisor;
const ProjectTie = @import("Chat.zig").ProjectTie;

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
tree: daylog.GroupTree,

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

    /// What the person had said about it in the control room. `none` for
    /// every record written before there was one.
    marks: Marks,

    /// The supervisor it last had; `none` for every record written before
    /// that was kept, and for a group nobody minded. Its strings are owned
    /// like the rest.
    supervisor: LastSupervisor,

    /// The project it is tied to; `undecided` for every record written
    /// before there were ties. Owned like the rest.
    project: ProjectTie,
    /// How many times "Not Now" was said to joining the project of its
    /// name (task 1713).
    project_not_now: u8,
};

pub fn open(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error!GroupLog {
    const dir = try std.fs.path.join(alloc, &.{ state_dir, "chat" });
    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .tree = .{
            .owner = .chat,
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
    // The file is rewritten whole, so what it said about anything else has
    // to be read first or this would erase it.
    const was = self.readMeta(self.alloc, name);
    defer if (was) |m| m.free(self.alloc);
    self.writeMeta(name, .{
        .brief = brief,
        .listed = true,
        .marks = if (was) |m| m.marks else .none,
        .supervisor = if (was) |m| m.supervisor else .none,
        .project = if (was) |m| m.project else .undecided,
        .project_not_now = if (was) |m| m.project_not_now else 0,
    });
}

/// Write down what the person said about a group in the control room,
/// leaving its note and its place in the list as they were.
pub fn mark(self: *GroupLog, name: []const u8, marks: Marks) void {
    const was = self.readMeta(self.alloc, name);
    defer if (was) |m| m.free(self.alloc);
    self.writeMeta(name, .{
        .brief = if (was) |m| m.brief else "",
        .listed = if (was) |m| m.listed else true,
        .marks = marks,
        .supervisor = if (was) |m| m.supervisor else .none,
        .project = if (was) |m| m.project else .undecided,
        .project_not_now = if (was) |m| m.project_not_now else 0,
    });
}

/// Write down the supervisor a group has, leaving everything else as it
/// was: where it works, the role and the CLI it is, the session it is in
/// and when it was last heard from. It is what the control room offers to
/// start the next one from, the morning after.
///
/// The whole record, not a field of it: the caller holds the current one
/// (`Chat.lastSupervisorOf`), and a writer that named three of the five
/// would be erasing the other two.
pub fn supervisor(self: *GroupLog, name: []const u8, last: LastSupervisor) void {
    const was = self.readMeta(self.alloc, name);
    defer if (was) |m| m.free(self.alloc);
    self.writeMeta(name, .{
        .brief = if (was) |m| m.brief else "",
        .listed = if (was) |m| m.listed else true,
        .marks = if (was) |m| m.marks else .none,
        .supervisor = last,
        .project = if (was) |m| m.project else .undecided,
        .project_not_now = if (was) |m| m.project_not_now else 0,
    });
}

/// Write down the project a group is tied to, or that it has none,
/// leaving everything else as it was.
pub fn project(self: *GroupLog, name: []const u8, tie: ProjectTie) void {
    const was = self.readMeta(self.alloc, name);
    defer if (was) |m| m.free(self.alloc);
    self.writeMeta(name, .{
        .brief = if (was) |m| m.brief else "",
        .listed = if (was) |m| m.listed else true,
        .marks = if (was) |m| m.marks else .none,
        .supervisor = if (was) |m| m.supervisor else .none,
        .project = tie,
        .project_not_now = if (was) |m| m.project_not_now else 0,
    });
}

/// Write down how many times the person answered "Not Now" to joining a
/// group to the project of its name (task 1713): after the second, the
/// question is not put again (`Chat.Group.project_not_now`).
pub fn projectNotNow(self: *GroupLog, name: []const u8, times: u8) void {
    const was = self.readMeta(self.alloc, name);
    defer if (was) |m| m.free(self.alloc);
    self.writeMeta(name, .{
        .brief = if (was) |m| m.brief else "",
        .listed = if (was) |m| m.listed else true,
        .marks = if (was) |m| m.marks else .none,
        .supervisor = if (was) |m| m.supervisor else .none,
        .project = if (was) |m| m.project else .undecided,
        .project_not_now = times,
    });
}

/// Take a group off the list, leaving every word ever said in it in place.
///
/// The note is carried over rather than blanked. Taking a group off the
/// list is not saying it was never for anything, and putting it back should
/// not lose what it was for.
pub fn forget(self: *GroupLog, name: []const u8) void {
    const was = self.readMeta(self.alloc, name);
    defer if (was) |m| m.free(self.alloc);
    self.writeMeta(name, .{
        .brief = if (was) |m| m.brief else "",
        .listed = false,
        .marks = if (was) |m| m.marks else .none,
        .supervisor = if (was) |m| m.supervisor else .none,
        .project = if (was) |m| m.project else .undecided,
        .project_not_now = if (was) |m| m.project_not_now else 0,
    });
}

/// Everything one `group.json` says. **No defaults**: the file is rewritten
/// whole by every writer, so a writer that carried three of these over and
/// forgot the fourth would erase it without a word. Here it does not
/// compile.
const Entry = struct {
    brief: []const u8,
    listed: bool,
    marks: Marks,
    supervisor: LastSupervisor,
    project: ProjectTie,
    project_not_now: u8,
};

fn writeMeta(self: *GroupLog, name: []const u8, entry: Entry) void {
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
    render(&s, entry) catch |err| {
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

fn render(s: *std.json.Stringify, entry: Entry) std.Io.Writer.Error!void {
    const brief = entry.brief;
    const listed = entry.listed;
    const marks = entry.marks;
    try s.beginObject();
    if (brief.len > 0) {
        try s.objectField("brief");
        try s.write(brief);
    }

    // Only when somebody said: a group nobody minded has the file it
    // always had. **A part nobody knows is a key that is not there** --
    // never an empty string, which would read back as "known, and empty".
    const sup = entry.supervisor;
    if (!sup.isNone()) {
        try s.objectField("supervisor");
        try s.beginObject();
        if (sup.dir.len > 0) {
            try s.objectField("dir");
            try s.write(sup.dir);
            try s.objectField("dir_from");
            try s.write(@tagName(sup.dir_from));
        }
        inline for (.{ "role", "cli", "launcher", "session" }) |key| {
            if (@field(sup, key).len > 0) {
                try s.objectField(key);
                try s.write(@field(sup, key));
            }
        }
        if (sup.heard_ms) |ms| {
            try s.objectField("heard_ms");
            try s.write(ms);
        }
        try s.endObject();
    }

    // Only when somebody has said. Nobody having said is the key not
    // being there, which is what every older record already is; a group
    // whose supervisor said it has none says that in so many words.
    switch (entry.project) {
        .undecided => {},
        .declined => {
            try s.objectField("project");
            try s.beginObject();
            try s.objectField("declined");
            try s.write(true);
            try s.endObject();
        },
        .bound => |name| {
            try s.objectField("project");
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.endObject();
        },
    }

    // Only when it is not nought, which is what every older record is.
    if (entry.project_not_now > 0) {
        try s.objectField("project_not_now");
        try s.write(entry.project_not_now);
    }

    // Only when it is false. Being in the list is what a group directory
    // already means, so the ordinary file is a note and nothing else, and
    // the flag is there to say the one thing the directory cannot.
    if (!listed) {
        try s.objectField("listed");
        try s.write(false);
    }

    // Each only when there is one, so a group nobody has marked has the
    // file it always had.
    if (marks.seen_ms) |ms| {
        try s.objectField("seen_ms");
        try s.write(ms);
    }
    switch (marks.snooze) {
        .none => {},
        .next_event => |at| {
            try s.objectField("snooze");
            try s.beginObject();
            try s.objectField("at_ms");
            try s.write(at);
            try s.objectField("until");
            try s.write("next_event");
            try s.endObject();
        },
        .until => |u| {
            try s.objectField("snooze");
            try s.beginObject();
            try s.objectField("at_ms");
            try s.write(u.at_ms);
            try s.objectField("until");
            try s.write(u.until_ms);
            try s.endObject();
        },
    }
    // The control room's right-click marks (task 1659), on the same terms:
    // each only when there is one.
    if (marks.pinned) {
        try s.objectField("pinned");
        try s.write(true);
    }
    switch (marks.mute) {
        .none => {},
        .until => |until| {
            try s.objectField("mute");
            try s.beginObject();
            try s.objectField("until_ms");
            try s.write(until);
            try s.endObject();
        },
        .forever => {
            try s.objectField("mute");
            try s.write("forever");
        },
    }
    if (marks.archived_ms) |ms| {
        try s.objectField("archived_ms");
        try s.write(ms);
    }
    try s.endObject();
}

const Meta = struct {
    /// Owned by the caller's allocator. Empty rather than null: a group
    /// with no note and a group whose note is empty are the same group.
    brief: []u8,
    listed: bool,
    marks: Marks,
    /// Its strings are owned by the caller's allocator, like `brief`.
    /// `none` when the file names none.
    supervisor: LastSupervisor,
    /// Owned likewise. `undecided` when the file says nothing of one.
    project: ProjectTie,
    /// How many times "Not Now" was said to joining the project of the
    /// group's name (task 1713); nought when the file says nothing.
    project_not_now: u8,

    fn free(self: Meta, alloc: Allocator) void {
        alloc.free(self.brief);
        self.supervisor.free(alloc);
        self.project.free(alloc);
    }
};

/// What the file says of the group's project, borrowed from the parse.
/// Anything that is not one of the two shapes `render` writes is nobody
/// having said -- never a tie to a project named by a guess.
fn projectIn(obj: std.json.ObjectMap) ProjectTie {
    const o = switch (obj.get("project") orelse std.json.Value.null) {
        .object => |v| v,
        else => return .undecided,
    };
    const name = textIn(o, "name");
    if (name.len > 0) return .{ .bound = name };
    return switch (o.get("declined") orelse std.json.Value.null) {
        .bool => |b| if (b) .declined else .undecided,
        else => .undecided,
    };
}

fn textIn(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (obj.get(key) orelse std.json.Value.null) {
        .string => |v| v,
        else => "",
    };
}

/// What the file says of the group's last supervisor, borrowed from the
/// parse. Anything missing or of the wrong type is that part not known,
/// never an error.
///
/// **`supervisor_dir` at the top is what was written before there was a
/// section**, by a supervisor and by nobody else: it is read as the
/// section's `dir` when the section has none, and is not written again.
fn supervisorIn(obj: std.json.ObjectMap) LastSupervisor {
    var out: LastSupervisor = .none;
    switch (obj.get("supervisor") orelse std.json.Value.null) {
        .object => |o| {
            out.dir = textIn(o, "dir");
            out.role = textIn(o, "role");
            out.cli = textIn(o, "cli");
            // Absent from a record written before task 2156 v3: its CLI as
            // its plugin starts it.
            out.launcher = textIn(o, "launcher");
            out.session = textIn(o, "session");
            out.heard_ms = if (o.get("heard_ms")) |v| msOf(v) else null;
            if (out.dir.len > 0) {
                // A directory with nothing saying where it came from was a
                // supervisor's: that is the only thing there was to say
                // when the key was first written.
                out.dir_from = std.meta.stringToEnum(
                    LastSupervisor.DirFrom,
                    textIn(o, "dir_from"),
                ) orelse .supervisor;
                if (out.dir_from == .none) out.dir_from = .supervisor;
            }
        },
        else => {},
    }
    if (out.dir.len == 0) {
        const old = textIn(obj, "supervisor_dir");
        if (old.len > 0) {
            out.dir = old;
            out.dir_from = .supervisor;
        }
    }
    return out;
}

fn msOf(v: std.json.Value) ?u64 {
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

/// What the file says of the person's marks. Anything missing or not in
/// the shape `render` writes is no mark, never an error: every file from
/// before these fields existed is exactly that.
fn marksIn(obj: std.json.ObjectMap) Marks {
    var out: Marks = .none;
    if (obj.get("seen_ms")) |v| out.seen_ms = msOf(v);
    out.pinned = switch (obj.get("pinned") orelse std.json.Value.null) {
        .bool => |b| b,
        else => false,
    };
    out.mute = switch (obj.get("mute") orelse std.json.Value.null) {
        .string => |v| if (std.mem.eql(u8, v, "forever")) .forever else .none,
        .object => |o| if (msOf(o.get("until_ms") orelse .null)) |until| .{ .until = until } else .none,
        else => .none,
    };
    if (obj.get("archived_ms")) |v| out.archived_ms = msOf(v);

    const snooze = switch (obj.get("snooze") orelse std.json.Value.null) {
        .object => |o| o,
        else => return out,
    };
    const at = msOf(snooze.get("at_ms") orelse .null) orelse return out;
    switch (snooze.get("until") orelse std.json.Value.null) {
        .string => |v| if (std.mem.eql(u8, v, "next_event")) {
            out.snooze = .{ .next_event = at };
        },
        .integer => |v| if (v >= 0) {
            out.snooze = .{ .until = .{ .at_ms = at, .until_ms = @intCast(v) } };
        },
        else => {},
    }
    return out;
}

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

    const owned_brief = alloc.dupe(u8, brief) catch return null;
    const owned_last = supervisorIn(obj).dupe(alloc) catch {
        alloc.free(owned_brief);
        return null;
    };
    return .{
        .brief = owned_brief,
        .listed = listed,
        .marks = marksIn(obj),
        .supervisor = owned_last,
        .project = projectIn(obj).dupe(alloc) catch {
            alloc.free(owned_brief);
            owned_last.free(alloc);
            return null;
        },
        .project_not_now = switch (obj.get("project_not_now") orelse std.json.Value.null) {
            .integer => |n| std.math.cast(u8, n) orelse std.math.maxInt(u8),
            else => 0,
        },
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
            s.supervisor.free(alloc);
            s.project.free(alloc);
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
        defer if (meta) |m| m.free(alloc);

        if (meta) |m| if (!m.listed) {
            alloc.free(name);
            continue;
        };

        const brief = alloc.dupe(u8, if (meta) |m| m.brief else "") catch {
            alloc.free(name);
            continue;
        };

        const last = (if (meta) |m| m.supervisor else LastSupervisor.none).dupe(alloc) catch {
            alloc.free(name);
            alloc.free(brief);
            continue;
        };
        errdefer last.free(alloc);
        const said: ProjectTie = if (meta) |m| m.project else .undecided;
        const tie = said.dupe(alloc) catch {
            alloc.free(name);
            alloc.free(brief);
            last.free(alloc);
            continue;
        };
        errdefer tie.free(alloc);

        try out.append(alloc, .{
            .name = name,
            .brief = brief,
            .last_ms = self.lastSpokeIn(seg),
            .marks = if (meta) |m| m.marks else .none,
            .supervisor = last,
            .project = tie,
            .project_not_now = if (meta) |m| m.project_not_now else 0,
        });
    }

    return out.toOwnedSlice(alloc);
}

pub fn free(alloc: Allocator, shells: []Shell) void {
    for (shells) |s| {
        alloc.free(s.name);
        alloc.free(s.brief);
        s.supervisor.free(alloc);
        s.project.free(alloc);
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

fn seenAt(ms: u64) Marks {
    var m: Marks = .none;
    m.seen_ms = ms;
    return m;
}

test "GroupLog: the right-click marks come back as they were written, and an old file has none (task 1659)" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(state);

    var pinned: Marks = .none;
    pinned.pinned = true;
    pinned.mute = .{ .until = 1_700_000_900_000 };
    var archived: Marks = .none;
    archived.mute = .forever;
    archived.archived_ms = 1_700_000_000_042;
    {
        var gl = try GroupLog.open(alloc, io, state);
        defer gl.deinit();
        gl.note("pinned", "");
        gl.mark("pinned", pinned);
        gl.note("archived", "");
        gl.mark("archived", archived);
        gl.note("plain", "");
    }
    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();
    const shells = try gl.restore(alloc);
    defer GroupLog.free(alloc, shells);
    try testing.expectEqual(pinned, (shellNamed(shells, "pinned") orelse return error.TestGroupMissing).marks);
    try testing.expectEqual(archived, (shellNamed(shells, "archived") orelse return error.TestGroupMissing).marks);
    try testing.expectEqual(Marks.none, (shellNamed(shells, "plain") orelse return error.TestGroupMissing).marks);
}

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

    var tree: daylog.GroupTree = .{ .owner = .chat, .alloc = alloc, .io = io, .dir = dir };
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
        defer m.free(alloc);
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

fn shellNamed(shells: []const Shell, name: []const u8) ?Shell {
    for (shells) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

test "ControlRoom marks: a group that was seen is still seen after it is read back" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    var seen: Marks = .none;
    seen.seen_ms = 1_700_000_000_123;
    var snoozed: Marks = .none;
    snoozed.snooze = .{ .next_event = 1_700_000_000_456 };
    var timed: Marks = .none;
    timed.seen_ms = 1_700_000_000_001;
    timed.snooze = .{ .until = .{ .at_ms = 1_700_000_000_002, .until_ms = 1_700_000_900_000 } };
    {
        var gl = try GroupLog.open(alloc, io, state);
        defer gl.deinit();
        gl.note("build", "the build");
        gl.mark("build", seen);
        gl.note("research", "");
        gl.mark("research", snoozed);
        gl.note("nightly", "");
        gl.mark("nightly", timed);
        gl.note("plain", "");

        // Changing the note afterwards rewrites the file and keeps the marks.
        gl.note("build", "the build, again");
    }

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();
    const shells = try gl.restore(alloc);
    defer free(alloc, shells);

    const build = shellNamed(shells, "build") orelse return error.TestGroupMissing;
    try testing.expectEqual(seen, build.marks);
    try testing.expectEqualStrings("the build, again", build.brief);
    try testing.expectEqual(snoozed, (shellNamed(shells, "research") orelse return error.TestGroupMissing).marks);
    try testing.expectEqual(timed, (shellNamed(shells, "nightly") orelse return error.TestGroupMissing).marks);
    try testing.expectEqual(Marks.none, (shellNamed(shells, "plain") orelse return error.TestGroupMissing).marks);
}

test "ControlRoom marks: a record from before there were marks reads back with none" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try testDir(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }

    // The three files the old code wrote, byte for byte, and one with marks
    // in shapes this never writes.
    const old = [_]struct { []const u8, []const u8 }{
        .{ "noted", "{\"brief\":\"last night\"}" },
        .{ "bare", "{}" },
        .{ "odd", "{\"brief\":\"x\",\"seen_ms\":\"soon\",\"snooze\":{\"until\":\"next_event\"}}" },
    };
    for (old) |o| {
        const dir = try std.fs.path.join(alloc, &.{ state, "chat", o[0] });
        defer alloc.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = meta_name, .data = o[1] });
    }

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();
    const shells = try gl.restore(alloc);
    defer free(alloc, shells);

    try testing.expectEqual(@as(usize, 3), shells.len);
    for (shells) |s| try testing.expectEqual(Marks.none, s.marks);
    const noted = shellNamed(shells, "noted") orelse return error.TestGroupMissing;
    try testing.expectEqualStrings("last night", noted.brief);

    // And writing a note into one of them adds no mark fields.
    gl.note("bare", "now noted");
    const path = try std.fs.path.join(alloc, &.{ state, "chat", "bare", meta_name });
    defer alloc.free(path);
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(4096));
    defer alloc.free(bytes);
    try testing.expectEqualStrings("{\"brief\":\"now noted\"}", bytes);
}

test "ControlRoom resume: a group's last supervisor is written down whole and outlives every other write to the file" {
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

    const whole: LastSupervisor = .{
        .dir = "/work/repo",
        .dir_from = .supervisor,
        .role = "polter-supervisor",
        .cli = "claude-code",
        // Through an Agent CLI of the person's own (task 2156 v3): kept, so
        // going on with the session goes through it again.
        .launcher = "claude-deepseek-flash",
        .session = "eed9173b-c1fc-4493-aa00-187bacdc94cf",
        .heard_ms = 1_700_000_000_123,
    };

    gl.note("build", "why");
    gl.supervisor("build", whole);
    {
        const shells = try gl.restore(alloc);
        defer free(alloc, shells);
        try testing.expectEqual(@as(usize, 1), shells.len);
        try expectLast(whole, shells[0].supervisor);
        // What was there before it is still there.
        try testing.expectEqualStrings("why", shells[0].brief);
    }

    // Each of the other three writers rewrites the whole file.
    gl.note("build", "why, again");
    gl.mark("build", seenAt(1_700_000_000_000));
    gl.forget("build");
    gl.note("build", "why, again");

    const shells = try gl.restore(alloc);
    defer free(alloc, shells);
    try testing.expectEqual(@as(usize, 1), shells.len);
    try expectLast(whole, shells[0].supervisor);
    try testing.expectEqual(@as(?u64, 1_700_000_000_000), shells[0].marks.seen_ms);

    // A group nobody minded has none, and its file does not say the word.
    gl.note("quiet", "");
    const m = gl.readMeta(alloc, "quiet").?;
    defer m.free(alloc);
    try testing.expect(m.supervisor.isNone());
    const quiet = try metaText(alloc, io, state, "quiet");
    defer alloc.free(quiet);
    try testing.expect(std.mem.indexOf(u8, quiet, "supervisor") == null);
}

fn expectLast(want: LastSupervisor, got: LastSupervisor) !void {
    try testing.expectEqualStrings(want.dir, got.dir);
    try testing.expectEqual(want.dir_from, got.dir_from);
    try testing.expectEqualStrings(want.role, got.role);
    try testing.expectEqualStrings(want.cli, got.cli);
    try testing.expectEqualStrings(want.launcher, got.launcher);
    try testing.expectEqualStrings(want.session, got.session);
    try testing.expectEqual(want.heard_ms, got.heard_ms);
}

/// The bytes of a group's `group.json`. Caller frees.
fn metaText(alloc: Allocator, io: std.Io, state: []const u8, group: []const u8) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ state, "chat", group, meta_name });
    defer alloc.free(path);
    return try std.Io.Dir.readFileAlloc(.cwd(), io, path, alloc, .limited(max_meta_bytes));
}

fn putMetaText(alloc: Allocator, io: std.Io, state: []const u8, group: []const u8, text: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ state, "chat", group });
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, meta_name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, text);
}

test "ControlRoom resume: what nobody knows of a last supervisor is a key that is not there, and reads back as not known" {
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

    // A supervisor that was heard from and whose CLI never named a
    // session: not the same record as no supervisor at all.
    const heard: LastSupervisor = .{
        .dir = "/work/repo",
        .dir_from = .supervisor,
        .role = "",
        .cli = "",
        .launcher = "",
        .session = "",
        .heard_ms = 42,
    };
    gl.supervisor("heard", heard);
    const text = try metaText(alloc, io, state, "heard");
    defer alloc.free(text);
    try testing.expectEqualStrings(
        "{\"supervisor\":{\"dir\":\"/work/repo\",\"dir_from\":\"supervisor\",\"heard_ms\":42}}",
        text,
    );
    const back = gl.readMeta(alloc, "heard").?;
    defer back.free(alloc);
    try expectLast(heard, back.supervisor);

    // A directory made up out of the old session snapshot: no supervisor
    // was recorded, and the file says where the directory is from.
    var guessed: LastSupervisor = .none;
    guessed.dir = "/old/place";
    guessed.dir_from = .session_snapshot;
    gl.supervisor("guessed", guessed);
    const g = gl.readMeta(alloc, "guessed").?;
    defer g.free(alloc);
    try expectLast(guessed, g.supervisor);
    try testing.expectEqual(@as(?u64, null), g.supervisor.heard_ms);
}

test "ControlRoom resume: a record from before there was a section reads its directory as a supervisor's and nothing else as known" {
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

    // What 0.10.1843 wrote, byte for byte in shape.
    try putMetaText(alloc, io, state, "old", "{\"brief\":\"b\",\"supervisor_dir\":\"/work/repo\",\"seen_ms\":7}");
    {
        const m = gl.readMeta(alloc, "old").?;
        defer m.free(alloc);
        var want: LastSupervisor = .none;
        want.dir = "/work/repo";
        want.dir_from = .supervisor;
        try expectLast(want, m.supervisor);
    }

    // The next writer of anything moves it into the section, once, and
    // loses nothing on the way.
    gl.mark("old", seenAt(8));
    const text = try metaText(alloc, io, state, "old");
    defer alloc.free(text);
    try testing.expectEqualStrings(
        "{\"brief\":\"b\",\"supervisor\":{\"dir\":\"/work/repo\",\"dir_from\":\"supervisor\"},\"seen_ms\":8}",
        text,
    );

    // A section wins over the old key, and a part of the wrong type is a
    // part not known rather than a file that cannot be read.
    try putMetaText(alloc, io, state, "both",
        \\{"supervisor_dir":"/old","supervisor":{"dir":"/new","role":7,"cli":"claude-code","session":"s-1","heard_ms":-3}}
    );
    const m = gl.readMeta(alloc, "both").?;
    defer m.free(alloc);
    try testing.expectEqualStrings("/new", m.supervisor.dir);
    try testing.expectEqual(LastSupervisor.DirFrom.supervisor, m.supervisor.dir_from);
    try testing.expectEqualStrings("", m.supervisor.role);
    try testing.expectEqualStrings("claude-code", m.supervisor.cli);
    // Written before task 2156 v3: no Agent CLI of the person's own.
    try testing.expectEqualStrings("", m.supervisor.launcher);
    try testing.expectEqualStrings("s-1", m.supervisor.session);
    try testing.expectEqual(@as(?u64, null), m.supervisor.heard_ms);
}

test "Projects: a group's tie to a project is written down in its own words and outlives every other write to the file" {
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

    // Nobody has said: the key is not there, as in every older record.
    gl.note("build", "why");
    {
        const text = try metaText(alloc, io, state, "build");
        defer alloc.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "project") == null);
        const m = gl.readMeta(alloc, "build").?;
        defer m.free(alloc);
        try testing.expect(m.project == .undecided);
    }

    gl.project("build", .{ .bound = "scratch" });
    {
        const text = try metaText(alloc, io, state, "build");
        defer alloc.free(text);
        try testing.expectEqualStrings("{\"brief\":\"why\",\"project\":{\"name\":\"scratch\"}}", text);
    }

    // Each of the other writers rewrites the whole file.
    gl.note("build", "why, again");
    gl.mark("build", seenAt(7));
    gl.supervisor("build", .none);
    gl.forget("build");
    gl.note("build", "why, again");
    {
        const shells = try gl.restore(alloc);
        defer free(alloc, shells);
        try testing.expectEqual(@as(usize, 1), shells.len);
        try testing.expectEqualStrings("scratch", shells[0].project.bound);
    }

    // "Not Now" to joining a project (task 1713): written only once said,
    // carried through every other writer, and back on restore.
    {
        const text = try metaText(alloc, io, state, "build");
        defer alloc.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "project_not_now") == null);
    }
    gl.projectNotNow("build", 2);
    gl.note("build", "why, a third time");
    gl.project("build", .declined);
    {
        const shells = try gl.restore(alloc);
        defer free(alloc, shells);
        try testing.expectEqual(@as(u8, 2), shells[0].project_not_now);
        try testing.expect(shells[0].project == .declined);
    }

    // "Has none, its supervisor said so" is not "nobody has said".
    gl.project("build", .declined);
    {
        const text = try metaText(alloc, io, state, "build");
        defer alloc.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "\"project\":{\"declined\":true}") != null);
        const m = gl.readMeta(alloc, "build").?;
        defer m.free(alloc);
        try testing.expect(m.project == .declined);
    }
    gl.project("build", .undecided);
    {
        const text = try metaText(alloc, io, state, "build");
        defer alloc.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "\"project\":") == null);
        // The "Not Now" count is not the tie: it stays (task 1713).
        try testing.expect(std.mem.indexOf(u8, text, "\"project_not_now\":2") != null);
    }

    // Anything that is not one of the two shapes is nobody having said.
    for ([_][]const u8{
        "{\"project\":\"scratch\"}",
        "{\"project\":{\"name\":\"\"}}",
        "{\"project\":{\"name\":7}}",
        "{\"project\":{\"declined\":false}}",
        "{\"project\":{\"declined\":\"yes\"}}",
        "{\"project\":null}",
    }) |odd| {
        try putMetaText(alloc, io, state, "odd", odd);
        const m = gl.readMeta(alloc, "odd").?;
        defer m.free(alloc);
        try testing.expect(m.project == .undecided);
    }
}
