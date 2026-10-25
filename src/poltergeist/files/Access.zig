//! May this path be read, and which workdir does it belong to (task 2145 C2,
//! PLAN §1.2)? **One place that decides**, as `os/link_policy.zig` is for
//! links: the hosts, the preview plugins and the html page ask this, none of
//! them writes the rule again.
//!
//! **Nothing outside the workdir is asked of the filesystem.** The path is
//! reduced by its own spelling first -- `.`, `..`, a double separator -- and
//! a path that leaves the workdir is refused there, before anything is
//! opened or stat'ed. Only then is the realpath taken, for the links that no
//! amount of string work can follow. That order is not a detail: asking
//! `realpath` about a path outside answers whether it exists, which is a
//! question a page that runs scripts and reaches the network (the html page)
//! must not be able to ask about `~/.ssh/id_rsa`; and on Windows an absolute
//! UNC path would have the SMB exchange -- credentials included -- with a
//! stranger's server happen *during* that realpath.
//!
//! **The answer is about the real file.** Once the path is inside by its
//! spelling, every link in it is followed, and only then is it asked again
//! whether it lies in the workdir it was said to belong to. A link inside the
//! workdir that leads out of it lands outside and is refused: what was asked
//! for is not a file of that workdir, whatever it is called.
//!
//! **A file belongs to one workdir, its own.** `workdir` is that directory,
//! already real (`Workdirs.Dir.path`); another worker's directory, the
//! supervisor's, and the repository above a worktree are all "outside" to a
//! file of this one. A workdir that is empty, is not absolute, or is one the
//! page itself marks too wide to read (`Workdirs.Dir.why`) refuses
//! everything: an empty root used to make `inside` true of any absolute path,
//! which is the whole disk.
//!
//! **A refusal says why, and is never a "no such file".** The page that shows
//! it writes where the file was and why it was not opened, and a preview that
//! fell back to the system's opener would be handing the very path that was
//! refused to a program that acts on it (the lesson of #2122).
//!
//! **Outside and missing are one answer.** Whether a path the caller may not
//! have exists is not the caller's business, so a path that is outside and a
//! path that is not there come back as the same refusal; what they were is
//! written in the log, where the person looking at Polter's own output can
//! tell them apart.

const Access = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.poltergeist);

/// How much of the workdir a ticket reaches (PLAN §3.1 `reads`).
pub const Scope = enum {
    /// Only the file the ticket was made for.
    file,
    /// Files in the same directory as that file.
    siblings,
    /// Anything in the workdir.
    workdir,
};

pub const Refusal = enum {
    /// Nothing was asked for.
    empty,
    /// A NUL byte: the path would be cut short by whatever it reaches.
    bad_path,
    /// The workdir itself is unusable: empty, or not absolute.
    bad_workdir,
    /// The workdir is one that may only be listed, not read (`/`, the home
    /// directory, the directory above it): anything in it is out of reach.
    too_wide,
    /// Not in the workdir it was said to belong to -- **or** there is nothing
    /// at that path. One answer on purpose; see the note at the top.
    outside,
    /// In the workdir, but not within the ticket's scope.
    out_of_scope,
    /// A name starting with `.` below the workdir, for a reader that may not
    /// have them (`Request.hide_dotfiles`).
    dotfile,
    /// It could not be looked at (permission, a loop of links, a device).
    unreadable,
    /// A device, a socket or a pipe: not something to read as a file.
    not_a_file,

    /// For the log and for the page.
    pub fn say(self: Refusal) []const u8 {
        return switch (self) {
            .empty => "no path was given",
            .bad_path => "the path contains a NUL byte",
            .bad_workdir => "this preview has no working directory",
            .too_wide => "this working directory is one that is not read from",
            .outside => "it is not in this working directory, or there is nothing at that path",
            .out_of_scope => "it is outside what this preview may read",
            .dotfile => "names that start with a dot are not shown here",
            .unreadable => "it could not be looked at",
            .not_a_file => "it is not a file or a directory",
        };
    }
};

/// What was really wrong, for the log. One outward refusal can be several
/// facts inside: a path that left the workdir, a path that is not there, a
/// path inside the workdir that could not be looked at. The log is where a
/// person diagnoses a plugin that cannot open the file it should, so the
/// facts are kept there and only there.
const Inner = enum {
    empty,
    bad_path,
    bad_workdir,
    too_wide,
    /// Left the workdir by its own spelling.
    outside,
    /// Left the workdir once its links were followed.
    link_out,
    /// Inside the workdir, and nothing there.
    missing,
    /// Inside the workdir, and could not be looked at.
    unreadable,
    /// The walk itself failed -- a link that loops, a link that points at a
    /// path whose parent is not a directory, a link that may not be followed.
    /// Nothing about where it ended up can be said, so nothing is learned
    /// from it: outward this is the same answer as `outside`.
    unresolved,
    out_of_scope,
    dotfile,
};

pub const Kind = enum { file, directory };

pub const Resolved = struct {
    /// Real: every link followed. What is read is this, never the path asked.
    path: []const u8,
    kind: Kind,
    size: u64,
    /// Nanoseconds since the epoch.
    mtime_ns: i128,
};

pub const Verdict = union(enum) {
    ok: Resolved,
    refuse: Refusal,
};

pub const Request = struct {
    /// The workdir the file belongs to, real.
    workdir: []const u8,
    /// Absolute, or relative to `workdir`.
    path: []const u8,
    scope: Scope = .workdir,
    /// The file the ticket was made for, real; needed for `.file` and
    /// `.siblings`, ignored for `.workdir`.
    anchor: ?[]const u8 = null,
    /// Refuse a name that starts with `.` anywhere below the workdir:
    /// `.env`, `.git/config`. The html page asks for this (the user's
    /// decision 2026-10-24): a page that runs scripts and may use the network
    /// is the one that must not be able to read them.
    hide_dotfiles: bool = false,
    /// The workdir is a row the page lists with `readable: false`
    /// (`Workdirs.Dir.why`): `/`, the home directory, any directory above it.
    /// Nothing in it is read, whatever the scope and whatever the ticket.
    ///
    /// **No default on purpose.** A caller that hands over a workdir's path
    /// and forgets this one would be asking for the whole disk to be
    /// readable; with a default of `false` that is what it would silently
    /// get. There is no default, so forgetting is `error: missing struct
    /// field: 'too_wide'` where the call is written -- the same shape as
    /// `Workdirs.Dir.why`, which cannot be left out either.
    too_wide: bool,

    fn why(self: Request, got: Inner) Refusal {
        log.debug("files: refused {s} workdir={s} path={s}", .{
            @tagName(got), self.workdir, self.path,
        });
        return switch (got) {
            .empty => .empty,
            .bad_path => .bad_path,
            .bad_workdir => .bad_workdir,
            .too_wide => .too_wide,
            .outside, .link_out, .missing, .unresolved => .outside,
            .out_of_scope => .out_of_scope,
            .dotfile => .dotfile,
            .unreadable => .unreadable,
        };
    }
};

pub fn resolve(arena: Allocator, io: Io, req: Request) Allocator.Error!Verdict {
    if (req.path.len == 0) return .{ .refuse = req.why(.empty) };
    if (std.mem.indexOfScalar(u8, req.path, 0) != null) return .{ .refuse = req.why(.bad_path) };
    // An empty or relative workdir cannot bound anything: `inside` is true of
    // every absolute path under an empty root, so a workdir that went missing
    // up the chain would turn one mis-set field into the whole disk.
    if (req.workdir.len == 0 or !std.fs.path.isAbsolute(req.workdir))
        return .{ .refuse = req.why(.bad_workdir) };
    if (req.too_wide) return .{ .refuse = req.why(.too_wide) };

    // **By its own spelling first, and the filesystem is not asked yet.** A
    // path that leaves the workdir is refused here, so a caller cannot learn
    // from this whether something outside exists.
    const lexical = if (std.fs.path.isAbsolute(req.path))
        try std.fs.path.resolve(arena, &.{req.path})
    else
        try std.fs.path.resolve(arena, &.{ req.workdir, req.path });
    if (!inside(req.workdir, lexical)) return .{ .refuse = req.why(.outside) };

    // **Every way the walk can fail is `outside` outward, and is told apart
    // only in the log.** The reason is not tidiness: a link inside the
    // workdir that points out of it fails differently depending on what is at
    // the other end -- a path that is not there is `FileNotFound`, a path
    // whose parent is not a directory is `NotDir`, one that may not be
    // followed is `AccessDenied` -- so answering those differently would let a
    // caller that may not read outside ask, one path at a time, where things
    // outside are. On Windows a link or a junction to a UNC path is followed
    // *during* this call, which is another reason for it to be the call that
    // answers least. What is inside and could not be read (`statFile` below)
    // still says so: by then nothing has been learned about outside.
    const real = Io.Dir.cwd().realPathFileAlloc(io, lexical, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .{ .refuse = req.why(.missing) },
        else => return .{ .refuse = req.why(.unresolved) },
    };

    // Followed its links out of the workdir.
    if (!inside(req.workdir, real)) return .{ .refuse = req.why(.link_out) };

    switch (req.scope) {
        .workdir => {},
        .file => {
            const a = req.anchor orelse return .{ .refuse = req.why(.out_of_scope) };
            if (!std.mem.eql(u8, a, real)) return .{ .refuse = req.why(.out_of_scope) };
        },
        .siblings => {
            const a = req.anchor orelse return .{ .refuse = req.why(.out_of_scope) };
            const here = std.fs.path.dirname(real) orelse return .{ .refuse = req.why(.out_of_scope) };
            const there = std.fs.path.dirname(a) orelse return .{ .refuse = req.why(.out_of_scope) };
            if (!std.mem.eql(u8, here, there)) return .{ .refuse = req.why(.out_of_scope) };
        },
    }

    if (req.hide_dotfiles and hasDotName(req.workdir, real)) return .{ .refuse = req.why(.dotfile) };

    const st = Io.Dir.cwd().statFile(io, real, .{}) catch return .{ .refuse = req.why(.unreadable) };
    const kind: Kind = switch (st.kind) {
        .file => .file,
        .directory => .directory,
        else => return .{ .refuse = .not_a_file },
    };
    return .{ .ok = .{
        .path = real,
        .kind = kind,
        .size = st.size,
        .mtime_ns = @as(i128, st.mtime.nanoseconds),
    } };
}

/// Whether `path` is `root` or lies under it. **A directory, not a prefix**:
/// `/w/ab` is not under `/w/a`. **An empty root is under nothing**: every
/// absolute path starts with it, so answering `true` here made one unset
/// field mean the whole disk.
pub fn inside(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    // A root that already ends in a separator (a drive root, `/`) has its
    // boundary in itself.
    if (root[root.len - 1] == std.fs.path.sep) return true;
    return path[root.len] == std.fs.path.sep;
}

/// Whether any part of `path` below `root` starts with a dot.
fn hasDotName(root: []const u8, path: []const u8) bool {
    if (!inside(root, path) or path.len == root.len) return false;
    var rest = path[root.len..];
    while (rest.len > 0 and rest[0] == std.fs.path.sep) rest = rest[1..];
    var it = std.mem.splitScalar(u8, rest, std.fs.path.sep);
    while (it.next()) |part| {
        if (part.len > 0 and part[0] == '.') return true;
    }
    return false;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    /// Real, and the workdir the tests are about: `<tmp>/w`.
    work: [:0]u8,
    /// Real: `<tmp>`, which holds the workdir and what is next to it.
    root: [:0]u8,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .work = undefined, .root = undefined };
        errdefer f.tmp.cleanup();
        try f.tmp.dir.createDirPath(testing.io, "w/sub");
        try f.tmp.dir.createDirPath(testing.io, "wx");
        try f.tmp.dir.createDirPath(testing.io, "other");
        f.root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(f.root);
        f.work = try f.tmp.dir.realPathFileAlloc(testing.io, "w", testing.allocator);
        return f;
    }

    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.work);
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn put(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn ask(f: *Fixture, arena: Allocator, path: []const u8, rest: Request) !Verdict {
        var r = rest;
        r.workdir = f.work;
        r.path = path;
        return resolve(arena, testing.io, r);
    }
};

fn expectRefused(want: Refusal, got: Verdict) !void {
    switch (got) {
        .ok => |r| {
            std.debug.print("expected {s}, but {s} was allowed\n", .{ @tagName(want), r.path });
            return error.TestExpectedRefusal;
        },
        .refuse => |why| try testing.expectEqual(want, why),
    }
}

fn expectOk(got: Verdict) !Resolved {
    switch (got) {
        .ok => |r| return r,
        .refuse => |why| {
            std.debug.print("expected a file, but it was refused: {s}\n", .{@tagName(why)});
            return error.TestExpectedAllowed;
        },
    }
}

test "2145 C2: a file in the workdir is read, named relatively or absolutely, and the answer is the real path" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("w/sub/a.txt", "hello");

    const rel = try expectOk(try fx.ask(a, "sub/a.txt", .{ .workdir = "", .path = "", .too_wide = false }));
    try testing.expectEqual(Kind.file, rel.kind);
    try testing.expectEqual(@as(u64, 5), rel.size);
    try testing.expect(rel.mtime_ns > 0);
    const abs = try expectOk(try fx.ask(a, try std.fs.path.join(a, &.{ fx.work, "sub", "a.txt" }), .{ .workdir = "", .path = "", .too_wide = false }));
    try testing.expectEqualStrings(rel.path, abs.path);
    // `..` that stays inside is fine, and is gone from the answer.
    const dots = try expectOk(try fx.ask(a, "sub/../sub/a.txt", .{ .workdir = "", .path = "", .too_wide = false }));
    try testing.expectEqualStrings(rel.path, dots.path);
    // The workdir itself, and a directory in it.
    try testing.expectEqual(Kind.directory, (try expectOk(try fx.ask(a, "sub", .{ .workdir = "", .path = "", .too_wide = false }))).kind);
    try testing.expectEqual(Kind.directory, (try expectOk(try fx.ask(a, fx.work, .{ .workdir = "", .path = "", .too_wide = false }))).kind);
}

test "2145 C2: what is not in the workdir is refused, whatever way it is spelled" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("other/secret.txt", "s");
    try fx.put("wx/near.txt", "n");
    try fx.put("top.txt", "t");

    const blank: Request = .{ .workdir = "", .path = "", .too_wide = false };
    try expectRefused(.outside, try fx.ask(a, "../other/secret.txt", blank));
    try expectRefused(.outside, try fx.ask(a, try std.fs.path.join(a, &.{ fx.root, "other", "secret.txt" }), blank));
    try expectRefused(.outside, try fx.ask(a, "../top.txt", blank));
    // **A directory, not a prefix**: `<root>/wx` begins with `<root>/w`.
    try expectRefused(.outside, try fx.ask(a, "../wx/near.txt", blank));
    try expectRefused(.outside, try fx.ask(a, try std.fs.path.join(a, &.{ fx.root, "wx" }), blank));
    // Deeper than the workdir can go and still not out of it: sub/../../.
    try expectRefused(.outside, try fx.ask(a, "sub/../../other", blank));
}

test "2145 C2: a link inside the workdir that leads out is refused, one that stays inside is read" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("other/secret.txt", "s");
    try fx.put("w/real.txt", "r");
    try fx.tmp.dir.symLink(testing.io, "../other/secret.txt", "w/out.txt", .{});
    try fx.tmp.dir.symLink(testing.io, "../other", "w/outdir", .{ .is_directory = true });
    try fx.tmp.dir.symLink(testing.io, "real.txt", "w/in.txt", .{});

    const blank: Request = .{ .workdir = "", .path = "", .too_wide = false };
    try expectRefused(.outside, try fx.ask(a, "out.txt", blank));
    try expectRefused(.outside, try fx.ask(a, "outdir/secret.txt", blank));
    const through = try expectOk(try fx.ask(a, "in.txt", blank));
    try testing.expect(std.mem.endsWith(u8, through.path, "real.txt"));
}

test "2145 C2: another workdir's file is outside, the file's own workdir decides" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("w/mine.txt", "m");
    try fx.put("other/theirs.txt", "t");
    const theirs = try std.fs.path.join(a, &.{ fx.root, "other", "theirs.txt" });
    const other = try fx.tmp.dir.realPathFileAlloc(testing.io, "other", a);

    // From the other workdir's side it is its own file...
    _ = try expectOk(try resolve(a, testing.io, .{ .workdir = other, .path = theirs, .too_wide = false }));
    // ...and from this one's, outside.
    try expectRefused(.outside, try resolve(a, testing.io, .{ .workdir = fx.work, .path = theirs, .too_wide = false }));
}

test "2145 C2: a ticket reaches the file, its directory or the workdir, and no further" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("w/sub/a.md", "a");
    try fx.put("w/sub/b.png", "b");
    try fx.put("w/c.txt", "c");
    const anchor = try std.fs.path.join(a, &.{ fx.work, "sub", "a.md" });

    const file_scope: Request = .{ .workdir = "", .path = "", .too_wide = false, .scope = .file, .anchor = anchor };
    _ = try expectOk(try fx.ask(a, "sub/a.md", file_scope));
    try expectRefused(.out_of_scope, try fx.ask(a, "sub/b.png", file_scope));

    const sib: Request = .{ .workdir = "", .path = "", .too_wide = false, .scope = .siblings, .anchor = anchor };
    _ = try expectOk(try fx.ask(a, "sub/b.png", sib));
    try expectRefused(.out_of_scope, try fx.ask(a, "c.txt", sib));

    const all: Request = .{ .workdir = "", .path = "", .too_wide = false, .scope = .workdir, .anchor = anchor };
    _ = try expectOk(try fx.ask(a, "c.txt", all));
    // A scope never widens past the workdir.
    try expectRefused(.outside, try fx.ask(a, "../other", all));
    // A narrow scope with no anchor reaches nothing.
    try expectRefused(.out_of_scope, try fx.ask(a, "sub/a.md", .{ .workdir = "", .path = "", .too_wide = false, .scope = .file }));
}

test "2145 C2: names starting with a dot are refused for a reader that may not have them, only below the workdir" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("w/.env", "SECRET=1");
    try fx.tmp.dir.createDirPath(testing.io, "w/.git");
    try fx.put("w/.git/config", "c");
    try fx.put("w/page.html", "p");
    try fx.put("w/a.env", "x");
    try fx.tmp.dir.symLink(testing.io, ".env", "w/looks-innocent", .{});

    const hide: Request = .{ .workdir = "", .path = "", .too_wide = false, .hide_dotfiles = true };
    try expectRefused(.dotfile, try fx.ask(a, ".env", hide));
    try expectRefused(.dotfile, try fx.ask(a, ".git/config", hide));
    try expectRefused(.dotfile, try fx.ask(a, ".git", hide));
    // **The real name counts, not the one asked for**: a link to `.env`.
    try expectRefused(.dotfile, try fx.ask(a, "looks-innocent", hide));
    _ = try expectOk(try fx.ask(a, "page.html", hide));
    _ = try expectOk(try fx.ask(a, "a.env", hide));
    // The workdir itself may sit under a dot directory (`~/.cache/x`):
    // only what is below it is judged.
    _ = try expectOk(try fx.ask(a, ".", hide));
    // For a reader that may have them, they are files like any other.
    _ = try expectOk(try fx.ask(a, ".env", .{ .workdir = "", .path = "", .too_wide = false }));
}

test "2145 C2: nothing, a NUL, and a path that is not there are refused with their own reasons" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blank: Request = .{ .workdir = "", .path = "", .too_wide = false };
    try expectRefused(.empty, try fx.ask(a, "", blank));
    try expectRefused(.bad_path, try fx.ask(a, "a\x00b", blank));
    // **A path that is not there and a path that is not ours are one
    // answer**: neither may tell the caller what is outside the workdir.
    try expectRefused(.outside, try fx.ask(a, "no/such/file", blank));
    try expectRefused(.outside, try fx.ask(a, try std.fs.path.join(a, &.{ fx.root, "other", "never-was.txt" }), blank));
    // Every refusal has words for the page.
    inline for (@typeInfo(Refusal).@"enum".fields) |f| {
        const r: Refusal = @enumFromInt(f.value);
        try testing.expect(r.say().len > 0);
    }
    // And every one of them is reachable from `why`, so none of them is a
    // refusal nothing can produce.
    inline for (@typeInfo(Inner).@"enum".fields) |f| {
        const got: Inner = @enumFromInt(f.value);
        _ = blank.why(got);
    }
}

test "2145 C2: a workdir that is empty or not absolute refuses everything" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An empty root used to be inside of everything: `startsWith("", p)` is
    // true, and an absolute path's first byte is the separator. One workdir
    // that went missing in the chain meant the whole disk.
    try expectRefused(.bad_workdir, try resolve(a, testing.io, .{ .workdir = "", .path = "/etc/hosts", .too_wide = false }));
    try expectRefused(.bad_workdir, try resolve(a, testing.io, .{ .workdir = "", .path = "relative.txt", .too_wide = false }));
    // A relative workdir bounds nothing either: it is resolved against
    // whatever the process's directory happens to be.
    try expectRefused(.bad_workdir, try resolve(a, testing.io, .{ .workdir = "w", .path = "sub/a.txt", .too_wide = false }));
    // A workdir being bad is answered before any path is turned into a real
    // one -- but after the path itself was found empty, which is the earlier
    // question of the two.
    try expectRefused(.empty, try resolve(a, testing.io, .{ .workdir = "", .path = "", .too_wide = false }));
    try expectRefused(.bad_workdir, try resolve(a, testing.io, .{ .workdir = "", .path = "a.txt", .too_wide = false }));
}

test "2145 C2: a path outside the workdir is refused without the filesystem being asked" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("other/secret.txt", "s");
    const blank: Request = .{ .workdir = "", .path = "", .too_wide = false };

    // There and not there are the same refusal, both for a path that left by
    // its spelling and for one that left through a link. If they differed, a
    // caller could map the filesystem outside its workdir one path at a time.
    const there = try std.fs.path.join(a, &.{ fx.root, "other", "secret.txt" });
    const not_there = try std.fs.path.join(a, &.{ fx.root, "other", "no-such.txt" });
    try expectRefused(.outside, try fx.ask(a, there, blank));
    try expectRefused(.outside, try fx.ask(a, not_there, blank));
    try expectRefused(.outside, try fx.ask(a, "../other/secret.txt", blank));
    try expectRefused(.outside, try fx.ask(a, "../other/no-such.txt", blank));
    // **The filesystem is not asked at all**, which is the only way to tell
    // this order from the other one: a path outside that the filesystem
    // cannot answer about (a loop of links) is still simply outside. If
    // `realpath` ran first, this one would come back "it could not be looked
    // at" -- a word about a path the caller may not have.
    try fx.tmp.dir.symLink(testing.io, "loop-out", "other/loop-out", .{});
    try expectRefused(.outside, try fx.ask(a, "../other/loop-out", blank));
    // A link inside that leads out is refused with the same word.
    try fx.tmp.dir.symLink(testing.io, "../other/secret.txt", "w/to-secret", .{});
    try expectRefused(.outside, try fx.ask(a, "to-secret", blank));
}

test "2145 C2: a workdir the page marks too wide refuses everything in it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.tmp.dir.createDirPath(testing.io, "w/.ssh");
    try fx.put("w/.ssh/x", "key");
    try fx.put("w/a.txt", "a");

    // The person's home directory is listed as a workdir and is not read:
    // `~/.ssh` and `~/.claude.json` are one ticket away otherwise.
    const wide: Request = .{ .workdir = "", .path = "", .too_wide = true };
    try expectRefused(.too_wide, try fx.ask(a, ".ssh/x", wide));
    try expectRefused(.too_wide, try fx.ask(a, "a.txt", wide));
    try expectRefused(.too_wide, try fx.ask(a, ".", wide));
    // With the mark off -- the same directory, the same ticket -- it reads.
    _ = try expectOk(try fx.ask(a, "a.txt", .{ .workdir = "", .path = "", .too_wide = false }));
}

test "2145 C2: a siblings ticket whose anchor is outside is capped by the workdir" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("other/secret.txt", "s");
    try fx.put("other/theirs.txt", "t");
    try fx.put("w/mine.txt", "m");
    const anchor_out = try std.fs.path.join(a, &.{ fx.root, "other", "secret.txt" });

    // The anchor is outside, so the directory it asks about is outside too:
    // an anchor must not be able to carry a ticket out of the workdir. Every
    // scope is capped, not only `workdir`.
    const sib: Request = .{ .workdir = "", .path = "", .too_wide = false, .scope = .siblings, .anchor = anchor_out };
    try expectRefused(.outside, try fx.ask(a, "../other/theirs.txt", sib));
    try expectRefused(.outside, try fx.ask(a, try std.fs.path.join(a, &.{ fx.root, "other", "theirs.txt" }), sib));
    const one: Request = .{ .workdir = "", .path = "", .too_wide = false, .scope = .file, .anchor = anchor_out };
    try expectRefused(.outside, try fx.ask(a, "../other/secret.txt", one));
    // And a path inside with an anchor outside is out of scope, not allowed.
    try expectRefused(.out_of_scope, try fx.ask(a, "mine.txt", sib));
}

test "2145 C2: a link out that cannot be walked is the same refusal as one that can" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fx.put("other/here.txt", "h");
    try fx.put("top.txt", "t");
    // Three ways for `realpath` to fail, all of them about a place outside:
    // nothing at the other end, a path whose parent is a file, and a loop.
    try fx.tmp.dir.symLink(testing.io, "../other/gone", "w/to-gone", .{});
    try fx.tmp.dir.symLink(testing.io, "../top.txt/under", "w/under-a-file", .{});
    try fx.tmp.dir.symLink(testing.io, "loop-b", "w/loop-a", .{});
    try fx.tmp.dir.symLink(testing.io, "loop-a", "w/loop-b", .{});
    // The one that does resolve, for contrast: same workdir, same shape.
    try fx.tmp.dir.symLink(testing.io, "../other/here.txt", "w/to-here", .{});

    const blank: Request = .{ .workdir = "", .path = "", .too_wide = false };
    for ([_][]const u8{ "to-gone", "under-a-file", "loop-a" }) |p| {
        // **One word for all of them.** Telling them apart would let a caller
        // that may not read outside learn, one path at a time, what is out
        // there -- and none of these is a fact about the workdir.
        try expectRefused(.outside, try fx.ask(a, p, blank));
    }
    // A link out that does resolve is the same word, so the word carries no
    // news either way.
    try expectRefused(.outside, try fx.ask(a, "to-here", blank));
}

test "2145 C2: inside() is about directories, and an empty root is under nothing" {
    try testing.expect(inside("/w/a", "/w/a"));
    try testing.expect(inside("/w/a", "/w/a/b"));
    try testing.expect(!inside("/w/a", "/w/ab"));
    try testing.expect(!inside("/w/a", "/w"));
    try testing.expect(inside("/", "/anything"));
    // Every absolute path starts with the empty string, so `true` here made
    // one unset workdir mean the whole disk.
    try testing.expect(!inside("", "/etc/hosts"));
    try testing.expect(!inside("", "/"));
}
