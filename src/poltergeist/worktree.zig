//! Git worktrees made and taken down by Polter, and the record of which is
//! which (task 1702, `dev-docs/poltergeist/v0.10.md` §4).
//!
//! **Why the product does this rather than every supervisor.** In 0.9 the
//! supervisor typed `git worktree add` itself, and three things went wrong:
//! which tree was whose lived only in its head, so a restart or a compaction
//! meant finding out again; every supervisor spelled it differently; and
//! nobody took the trees down, so their build caches filled the disk. So the
//! making and the taking down are here, written down in a file that outlives
//! the process, and *when* to use one and how to merge it are the
//! `supervising` skill's.
//!
//! Three rules the user set (§4.3), each held by a test below:
//!
//!   * where a tree goes is a setting: beside the repository by default
//!     (`<repo>-wt/<name>`), or inside it -- and inside, the directory is
//!     written into that repository's `.git/info/exclude` so it can never be
//!     committed, without touching the user's `.gitignore`;
//!   * there is no merge here. What is here says whether it is merged;
//!   * a directory that is not a git repository is opened as it is, and the
//!     answer **says** no tree was made (`Prepared.not_git`). A caller told
//!     nothing would believe it was isolated.
//!
//! And one of its own: **nothing here deletes a tree whose work has not
//! landed** (`landed`), and nothing deletes one at all unless asked
//! (`remove`) or a task is closed (`closeout`). A tree's work is *landed*
//! when every path it changed holds, on the mainline's HEAD, exactly what the
//! tree holds -- not "the branch has no commits the mainline lacks", which in
//! this repository's own workflow (workers do not commit; the supervisor
//! applies their patch on the main tree) is always true and says nothing.
//! `--force` appears in this file **once**: in `removeIndex`, after `landed`
//! is true and has been checked a second time. A tree with work in it is
//! "dirty" to git, so without it git would refuse; with it, nothing but a
//! landed tree can get that far (a test holds the command log to this).
//!
//! ⚠️ **Making a tree is checking out a repository**, which for this one is
//! six thousand files and seconds of disk. So it is split in two: `plan`
//! runs git and nothing else, and may run anywhere -- in the app, on a
//! thread of its own (`Job`), because the app thread is every terminal's
//! thread and the person's whole window waits on it; `commit` writes the
//! ledger and runs where the ledger lives. `prepare` is the two in a row,
//! for callers that may wait.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const daylog = @import("daylog.zig");
const Tasks = @import("Tasks.zig");

const log = std.log.scoped(.poltergeist);

/// Where a new tree goes (`poltergeist-worktree-location`).
pub const Location = enum {
    /// `<parent of the repository>/<repository's name>-wt/<name>`.
    beside,
    /// `<repository>/.polter-worktrees/<name>`, excluded from git.
    inside,
};

/// The directory trees go in under `inside`.
pub const inside_dir = ".polter-worktrees";

/// What a tree's branch is called: this, then its name.
pub const branch_prefix = "wt/";

/// The longest name taken.
pub const max_name = 64;

/// Whether `name` can be both a directory and a branch: letters, digits,
/// `.`, `_` and `-`, not starting with `.` or `-`, no `..`, and not ending in
/// `.lock` (which git refuses for a ref).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.endsWith(u8, name, ".lock")) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

// ------------------------------------------------------------------ git

/// How git is run. `env` replaces git's environment when set: the tests use
/// it to keep the user's own git configuration out of their fixtures.
pub const Git = struct {
    io: Io,
    env: ?*const std.process.Environ.Map = null,
    /// The program run as git. A test puts a slow stand-in here.
    exe: []const u8 = "git",

    pub const Ran = struct {
        ok: bool,
        out: []const u8,
        err: []const u8,
        /// `out` before trimming. A `-z` listing is read from this: its
        /// first record can start with a space (` M path`) and the trim
        /// would eat it.
        raw: []const u8 = "",
    };

    pub const Error = error{ GitNotRunnable, OutOfMemory };

    /// `git -C dir args...`, with its output trimmed, in `arena`.
    pub fn run(self: Git, arena: Allocator, dir: []const u8, args: []const []const u8) Error!Ran {
        const argv = try std.mem.concat(arena, []const u8, &.{ &.{ self.exe, "-C", dir }, args });
        const r = std.process.run(arena, self.io, .{
            .argv = argv,
            .environ_map = self.env,
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{
                .raw = .fromMilliseconds(60 * std.time.ms_per_s),
                .clock = .awake,
            } },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GitNotRunnable,
        };
        return .{
            .ok = switch (r.term) {
                .exited => |code| code == 0,
                else => false,
            },
            .out = std.mem.trim(u8, r.stdout, " \t\r\n"),
            .err = std.mem.trim(u8, r.stderr, " \t\r\n"),
            .raw = r.stdout,
        };
    }
};

/// The repository a directory belongs to, as the place trees are made from.
pub const Repo = struct {
    /// The main working tree (the parent of `.git`), even when the
    /// directory asked about is itself one of its worktrees -- so a tree made
    /// from inside a tree lands beside the others, not inside it.
    main: []const u8,
    /// `git rev-parse --git-common-dir`, absolute.
    common: []const u8,
};

/// Null when `dir` is not in a git repository.
pub fn discover(git: Git, arena: Allocator, dir: []const u8) Git.Error!?Repo {
    const r = try git.run(arena, dir, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    if (!r.ok or r.out.len == 0) return null;
    const common = r.out;
    const main = if (std.mem.eql(u8, std.fs.path.basename(common), ".git"))
        std.fs.path.dirname(common) orelse common
    else
        common;
    return .{ .main = main, .common = common };
}

/// Where a tree called `name` of `repo` goes under `location`.
pub fn treePath(arena: Allocator, repo: Repo, location: Location, name: []const u8) Allocator.Error![]const u8 {
    return switch (location) {
        .beside => blk: {
            const parent = std.fs.path.dirname(repo.main) orelse repo.main;
            const wt = try std.fmt.allocPrint(arena, "{s}-wt", .{std.fs.path.basename(repo.main)});
            break :blk try std.fs.path.join(arena, &.{ parent, wt, name });
        },
        .inside => try std.fs.path.join(arena, &.{ repo.main, inside_dir, name }),
    };
}

// ------------------------------------------------- a task's tree: its names

/// The leaf of a task's directory: `wt-<task>`. Task numbers are global, so
/// two groups never share a leaf and the group segment above it is for the
/// reader, not for telling trees apart.
fn leafName(buf: *[24]u8, task: u64) []const u8 {
    return std.fmt.bufPrint(buf, "wt-{d}", .{task}) catch unreachable;
}

/// The one place a group name becomes a path segment and a branch segment
/// (`dev-docs`: the directory and the branch use the same string, so they
/// always match).
///
/// A name `Chat.isValidName` would take (`[a-z0-9-]`, 1-48 bytes) is used as
/// it is. Anything else -- a hand-edited file, a caller that went around the
/// model -- goes through `daylog.encodeSegment`, and then two more rules that
/// only a directory *and* a git ref have:
///
///   * a Windows device name (`con`, `prn`, `aux`, `nul`, `com1`-`com9`,
///     `lpt1`-`lpt9`, any case, with or without an extension) cannot be a path
///     segment there, and git keeps loose refs as files, so its first byte is
///     written `%XX` (`con` -> `%63on`);
///   * git refuses `..`, a name ending in `.lock` and a name ending in `.`,
///     so every `.` is written `%2E`.
///
/// Still injective: a literal `%` is already `%25` by then, so `%63` and
/// `%2E` can only have come from here.
pub fn groupSegment(alloc: Allocator, group: []const u8) Allocator.Error![]const u8 {
    if (plainGroup(group) and !isDeviceName(group)) return alloc.dupe(u8, group);

    const encoded = try daylog.encodeSegment(alloc, group);
    var seg: []const u8 = encoded;
    if (std.mem.indexOf(u8, seg, "..") != null or
        std.mem.endsWith(u8, seg, ".lock") or
        std.mem.endsWith(u8, seg, "."))
    {
        const dots = std.mem.count(u8, seg, ".");
        var out = try std.ArrayList(u8).initCapacity(alloc, seg.len + dots * 2);
        for (seg) |c| {
            if (c == '.') out.appendSliceAssumeCapacity("%2E") else out.appendAssumeCapacity(c);
        }
        seg = out.items;
    }
    if (isDeviceName(seg)) {
        const hex = "0123456789ABCDEF";
        return std.fmt.allocPrint(alloc, "%{c}{c}{s}", .{ hex[seg[0] >> 4], hex[seg[0] & 0xf], seg[1..] });
    }
    return seg;
}

fn plainGroup(group: []const u8) bool {
    if (group.len == 0 or group.len > 48) return false;
    for (group) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Whether `seg`, up to its first `.`, is a name Windows keeps for a device.
fn isDeviceName(seg: []const u8) bool {
    const base = seg[0 .. std.mem.indexOfScalar(u8, seg, '.') orelse seg.len];
    var buf: [8]u8 = undefined;
    if (base.len == 0 or base.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, base);
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |n| if (std.mem.eql(u8, lower, n)) return true;
    if (lower.len == 4 and (std.mem.startsWith(u8, lower, "com") or std.mem.startsWith(u8, lower, "lpt")))
        return lower[3] >= '1' and lower[3] <= '9';
    return false;
}

/// A task tree's ledger name: `<group segment>/wt-<task>`.
pub fn taskTreeName(alloc: Allocator, group: []const u8, task: u64) Allocator.Error![]const u8 {
    var buf: [24]u8 = undefined;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ try groupSegment(alloc, group), leafName(&buf, task) });
}

/// A task tree's branch: `wt/<group segment>/<task>`.
pub fn taskBranch(alloc: Allocator, group: []const u8, task: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(alloc, branch_prefix ++ "{s}/{d}", .{ try groupSegment(alloc, group), task });
}

/// Where a task's tree goes: `<repo>-wt/<group>/wt-<task>` beside, or
/// `<repo>/.polter-worktrees/<group>/wt-<task>` inside.
pub fn taskTreePath(
    arena: Allocator,
    repo: Repo,
    location: Location,
    group: []const u8,
    task: u64,
) Allocator.Error![]const u8 {
    var buf: [24]u8 = undefined;
    const seg = try groupSegment(arena, group);
    const leaf = leafName(&buf, task);
    return switch (location) {
        .beside => blk: {
            const parent = std.fs.path.dirname(repo.main) orelse repo.main;
            const wt = try std.fmt.allocPrint(arena, "{s}-wt", .{std.fs.path.basename(repo.main)});
            break :blk try std.fs.path.join(arena, &.{ parent, wt, seg, leaf });
        },
        .inside => try std.fs.path.join(arena, &.{ repo.main, inside_dir, seg, leaf }),
    };
}

/// The line `inside` writes into `.git/info/exclude`.
pub const exclude_line = "/" ++ inside_dir ++ "/";

/// Make sure `exclude_line` is in `<common>/info/exclude`, appending it when
/// it is not. The user's `.gitignore` is never touched.
pub fn ensureExcluded(arena: Allocator, io: Io, common: []const u8) !void {
    const info = try std.fs.path.join(arena, &.{ common, "info" });
    const path = try std.fs.path.join(arena, &.{ info, "exclude" });
    const cwd = Io.Dir.cwd();
    const old: []const u8 = cwd.readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), exclude_line)) return;
    }
    try cwd.createDirPath(io, info);
    const sep: []const u8 = if (old.len == 0 or old[old.len - 1] == '\n') "" else "\n";
    const new = try std.mem.concat(arena, u8, &.{ old, sep, exclude_line, "\n" });
    try cwd.writeFile(io, .{ .sub_path = path, .data = new });
}

pub fn pathExists(io: Io, path: []const u8) bool {
    return exists(io, path);
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// --------------------------------------------------------------- ledger

/// One tree, as it is written down.
pub const Entry = struct {
    name: []const u8,
    /// `Repo.main` of the repository it was made from.
    repo: []const u8,
    path: []const u8,
    branch: []const u8,
    /// The commit it was made at.
    base: []const u8,
    created_ms: i64 = 0,
    /// The terminal that asked for it. For reading only: terminal ids do not
    /// survive a restart, which is why the tie that has to is `task`.
    by: u64 = 0,
    /// The terminal opened in it, when one was there by the time the
    /// answer was written (a split is not). Same caveat as `by`.
    terminal: ?u64 = null,
    /// The task whose work is in it: set by `task_assign` to a terminal
    /// standing in the tree (`Ledger.tieTask`). What the panel shows after a
    /// restart.
    task: ?u64 = null,
    /// The group the task was in when the tree was made (a task tree's
    /// directory and branch carry it). Empty for a `manual` tree.
    group: []const u8 = "",
    kind: Kind = .manual,

    /// Whose a tree is. `manual`: asked for by name (`terminal_open` /
    /// `role_launch` `worktree`); `task`: made for a task, named from its
    /// group and number, and the task is the tree's identity.
    pub const Kind = enum { manual, task };

    pub fn dupe(self: Entry, alloc: Allocator) Allocator.Error!Entry {
        var e = self;
        e.group = try alloc.dupe(u8, self.group);
        errdefer alloc.free(e.group);
        e.name = try alloc.dupe(u8, self.name);
        errdefer alloc.free(e.name);
        e.repo = try alloc.dupe(u8, self.repo);
        errdefer alloc.free(e.repo);
        e.path = try alloc.dupe(u8, self.path);
        errdefer alloc.free(e.path);
        e.branch = try alloc.dupe(u8, self.branch);
        errdefer alloc.free(e.branch);
        e.base = try alloc.dupe(u8, self.base);
        return e;
    }

    fn free(self: Entry, alloc: Allocator) void {
        alloc.free(self.group);
        alloc.free(self.name);
        alloc.free(self.repo);
        alloc.free(self.path);
        alloc.free(self.branch);
        alloc.free(self.base);
    }

    /// Whether `dir` is this tree or somewhere inside it.
    pub fn holds(self: Entry, dir: []const u8) bool {
        return within(self.path, dir);
    }
};

/// Whether `dir` is `root` or inside it.
pub fn within(root: []const u8, dir: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "/\\");
    if (r.len == 0 or !std.mem.startsWith(u8, dir, r)) return false;
    if (dir.len == r.len) return true;
    return dir[r.len] == '/' or dir[r.len] == '\\';
}

/// Whether a terminal whose directory is `cwd` stands in the tree at `root`.
/// `within` compares text, and the two texts come from different mouths: git
/// reports the tree's real path, a shell reports the path it was walked in
/// by -- through a link, with a `..`, in other letter case. So both go through
/// `realpath` first; one that cannot (the directory is gone) is cleaned of
/// `.` and `..` by hand and, on Windows, compared without regard to case.
pub fn standsIn(io: Io, arena: Allocator, root: []const u8, cwd: []const u8) Allocator.Error!bool {
    const r = try canonical(io, arena, root);
    const c = try canonical(io, arena, cwd);
    return within(r, c);
}

fn canonical(io: Io, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const real = Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return lexical(arena, path),
    };
    return if (builtin.os.tag == .windows) lowered(arena, real) else real;
}

fn lowered(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, path);
    for (out) |*ch| ch.* = if (ch.* == '\\') '/' else std.ascii.toLower(ch.*);
    return out;
}

/// `path` with `.` and `..` resolved by text alone.
fn lexical(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const src = if (builtin.os.tag == .windows) try lowered(arena, path) else path;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, seg);
    }
    var out: std.ArrayList(u8) = .empty;
    if (src.len > 0 and src[0] == '/') try out.append(arena, '/');
    for (parts.items, 0..) |seg, i| {
        if (i > 0) try out.append(arena, '/');
        try out.appendSlice(arena, seg);
    }
    return out.items;
}

/// Whether `dir` is in a git repository, told by looking for a `.git` on the
/// way up -- no process, so the app thread may ask it. **Only a guess at what
/// `discover` will say** (a stray `.git` file is not a repository), good for
/// deciding that a task *plans* a tree; the tree is made, or found not to be
/// makeable, by `planTask` on the job's thread.
pub fn looksLikeRepo(io: Io, dir: []const u8) bool {
    var cur: []const u8 = std.mem.trimEnd(u8, dir, "/\\");
    while (cur.len > 0) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dot_git = std.fmt.bufPrint(&buf, "{s}/.git", .{cur}) catch return false;
        if (exists(io, dot_git)) return true;
        cur = std.fs.path.dirname(cur) orelse return false;
    }
    return false;
}

/// Where a working directory stands against a task's tree.
pub const CwdRelation = enum {
    /// The tree itself or somewhere in it.
    in_tree,
    /// Outside the tree, but in the same repository: its main checkout, or
    /// the directory the repository's trees are made in. A task's terminal
    /// there would be working beside its tree rather than in it.
    same_repo,
    /// Somewhere else altogether -- not this repository's.
    elsewhere,
};

/// Pure: names only, no git. A tree is `<root>/<group>/wt-<n>` (or
/// `<root>/wt-<n>` for a manual one), so `<root>` is a level or two up; both
/// are tried, and the repository's own directory counts.
pub fn cwdRelation(entry: Entry, cwd: []const u8) CwdRelation {
    if (within(entry.path, cwd)) return .in_tree;
    if (within(entry.repo, cwd)) return .same_repo;
    if (std.fs.path.dirname(entry.path)) |group_dir| {
        if (within(group_dir, cwd)) return .same_repo;
        if (std.fs.path.dirname(group_dir)) |root| {
            // Not the whole of `/`, or `/tmp`: only a directory that is
            // named for this repository's trees.
            const leaf = std.fs.path.basename(root);
            if ((std.mem.endsWith(u8, leaf, "-wt") or std.mem.eql(u8, leaf, inside_dir)) and within(root, cwd))
                return .same_repo;
        }
    }
    return .elsewhere;
}

/// What `terminal_list` says of a terminal standing in a tree.
pub const Tag = struct {
    name: []const u8,
    branch: []const u8,
    path: []const u8,
    /// The task whose own tree it is; null for a manual one.
    task: ?u64 = null,
};

/// Every tree Polter made and has not taken down, kept in a file so it is
/// still known after a restart. Not locked: its owner holds `mutex` around
/// every use.
pub const Ledger = struct {
    alloc: Allocator,
    /// Where it is kept; null keeps it in memory only.
    file: ?[]const u8 = null,
    entries: std.ArrayList(Entry) = .empty,
    mutex: Io.Mutex = .init,

    pub const max_file_bytes = 4 * 1024 * 1024;

    pub fn init(alloc: Allocator, file: ?[]const u8) Allocator.Error!Ledger {
        return .{ .alloc = alloc, .file = if (file) |f| try alloc.dupe(u8, f) else null };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.entries.items) |e| e.free(self.alloc);
        self.entries.deinit(self.alloc);
        if (self.file) |f| self.alloc.free(f);
        self.* = undefined;
    }

    const OnDisk = struct {
        version: u32 = 1,
        trees: []const Entry = &.{},
    };

    /// Read the file back. A file that is not there is an empty ledger; one
    /// that does not parse is logged and left alone, so the next `save` does
    /// not silently replace what a person may want to read.
    pub fn load(self: *Ledger, io: Io) void {
        const file = self.file orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();
        const bytes = Io.Dir.cwd().readFileAlloc(io, file, aa, .limited(max_file_bytes)) catch |err| {
            if (err != error.FileNotFound) log.warn("worktree: could not read {s}: {t}", .{ file, err });
            return;
        };
        const parsed = std.json.parseFromSliceLeaky(OnDisk, aa, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
            log.warn("worktree: {s} does not parse ({t}); the trees in it are not known", .{ file, err });
            return;
        };
        for (parsed.trees) |e| {
            if (self.find(e.repo, e.name) != null) continue;
            const owned = e.dupe(self.alloc) catch return;
            self.entries.append(self.alloc, owned) catch {
                owned.free(self.alloc);
                return;
            };
        }
    }

    pub fn save(self: *const Ledger, io: Io) !void {
        const file = self.file orelse return;
        const json = try std.json.Stringify.valueAlloc(
            self.alloc,
            OnDisk{ .trees = self.entries.items },
            .{ .whitespace = .indent_2 },
        );
        defer self.alloc.free(json);
        try writeReplacing(self.alloc, io, file, json);
    }

    pub fn find(self: *const Ledger, repo: []const u8, name: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.repo, repo) and std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    pub const Lookup = union(enum) {
        none,
        one: usize,
        /// The name is in more than one repository; `repo` says which.
        ambiguous: usize,
    };

    /// By name, and by repository when one is given.
    pub fn lookup(self: *const Ledger, name: []const u8, repo: []const u8) Lookup {
        var hit: ?usize = null;
        var n: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            if (repo.len > 0 and !std.mem.eql(u8, e.repo, repo)) continue;
            hit = i;
            n += 1;
        }
        if (n > 1) return .{ .ambiguous = n };
        return if (hit) |i| .{ .one = i } else .none;
    }

    pub fn put(self: *Ledger, e: Entry) Allocator.Error!void {
        const owned = try e.dupe(self.alloc);
        errdefer owned.free(self.alloc);
        if (self.find(e.repo, e.name)) |i| {
            self.entries.items[i].free(self.alloc);
            self.entries.items[i] = owned;
            return;
        }
        try self.entries.append(self.alloc, owned);
    }

    pub fn removeAt(self: *Ledger, i: usize) void {
        self.entries.orderedRemove(i).free(self.alloc);
    }

    /// The tree `dir` stands in: the deepest one, when trees are nested.
    pub fn containing(self: *const Ledger, dir: []const u8) ?usize {
        if (dir.len == 0) return null;
        var best: ?usize = null;
        for (self.entries.items, 0..) |e, i| {
            if (!e.holds(dir)) continue;
            if (best) |b| if (self.entries.items[b].path.len >= e.path.len) continue;
            best = i;
        }
        return best;
    }

    pub fn tagAt(self: *const Ledger, dir: []const u8) ?Tag {
        const i = self.containing(dir) orelse return null;
        const e = self.entries.items[i];
        return .{
            .name = e.name,
            .branch = e.branch,
            .path = e.path,
            .task = if (e.kind == .task) e.task else null,
        };
    }

    /// `task_assign` gave `task` to `terminal`, which stands in `cwd`: the
    /// tree that terminal was opened in, or the one `cwd` is in, is that
    /// task's. Whether anything changed.
    pub fn tieTask(self: *Ledger, task: u64, terminal: u64, cwd: []const u8) bool {
        const i = for (self.entries.items, 0..) |e, j| {
            if (e.terminal == terminal) break j;
        } else self.containing(cwd) orelse return false;
        if (self.entries.items[i].task == task) return false;
        self.entries.items[i].task = task;
        return true;
    }

    /// Which tree a caller means: by `task` when one is given (the tree
    /// made for it, else any tied to it), else by name. `task` is the way a
    /// supervisor need not remember a name with a slash in it.
    pub fn select(self: *const Ledger, name: []const u8, repo: []const u8, task: u64) Lookup {
        if (task == 0) return self.lookup(name, repo);
        var hit: ?usize = null;
        var n: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            if (e.task != task) continue;
            if (repo.len > 0 and !std.mem.eql(u8, e.repo, repo)) continue;
            // A task's own tree wins over one that was merely tied to it.
            if (hit) |h| if (self.entries.items[h].kind == .task and e.kind != .task) continue;
            if (hit) |h| if (self.entries.items[h].kind != .task and e.kind == .task) {
                hit = i;
                n = 1;
                continue;
            };
            hit = i;
            n += 1;
        }
        if (n > 1) return .{ .ambiguous = n };
        return if (hit) |i| .{ .one = i } else .none;
    }

    /// The tree made for `task` (not one merely tied to it).
    pub fn taskTree(self: *const Ledger, task: u64) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.kind == .task and e.task == task) return i;
        }
        return null;
    }

    /// The tree tied to `task`, or the one its owner stands in.
    pub fn forTask(self: *const Ledger, task: u64, owner_cwd: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| if (e.task == task) return i;
        return self.containing(owner_cwd);
    }
};

/// Write `bytes` to `path` by way of a file beside it, so a crash never
/// leaves half a ledger.
fn writeReplacing(alloc: Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.{x}.tmp", .{ path, &raw });
    defer alloc.free(tmp);
    {
        var f = try cwd.createFile(io, tmp, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
}

// ------------------------------------------------------------- prepare

/// A refusal: a code for a program and a sentence for a person, both in
/// the arena the call was given.
pub const Refusal = struct {
    code: []const u8,
    message: []const u8,
};

/// What `prepare` made of a request to open a terminal in a tree.
pub const Prepared = union(enum) {
    /// Open the terminal in `entry.path`.
    tree: struct {
        entry: Entry,
        /// It was already there and in the ledger; nothing was made.
        reused: bool,
    },
    /// `dir` is not in a git repository: open the terminal there, and say
    /// that no tree was made (§4.3-3).
    not_git: []const u8,
    /// Nothing is to be opened.
    refused: Refusal,

    /// A copy whose strings are all in `alloc`.
    pub fn dupe(self: Prepared, alloc: Allocator) Allocator.Error!Prepared {
        return switch (self) {
            .tree => |t| .{ .tree = .{ .entry = try t.entry.dupe(alloc), .reused = t.reused } },
            .not_git => |d| .{ .not_git = try alloc.dupe(u8, d) },
            .refused => |r| .{ .refused = .{
                .code = try alloc.dupe(u8, r.code),
                .message = try alloc.dupe(u8, r.message),
            } },
        };
    }

    /// The directory the terminal goes in, unless refused.
    pub fn dir(self: Prepared) ?[]const u8 {
        return switch (self) {
            .tree => |t| t.entry.path,
            .not_git => |d| d,
            .refused => null,
        };
    }
};

/// The sentence `Prepared.not_git` is answered with.
pub fn notGitNote(arena: Allocator, dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{s} is not in a git repository, so no worktree was made: the terminal is in that " ++
            "directory itself and is not isolated from anything else working there.",
        .{dir},
    );
}

pub const Request = struct {
    /// The directory the tree is made from; its `HEAD` is the base.
    dir: []const u8,
    name: []const u8,
    location: Location = .beside,
    by: u64 = 0,
    now_ms: i64 = 0,
};

/// Find or make the tree `req` asks for, and write it down. The ledger is
/// saved before this returns whenever it changed. **Waits for git**: the
/// app uses `Job` instead.
pub fn prepare(git: Git, arena: Allocator, ledger: *Ledger, req: Request) Allocator.Error!Prepared {
    return commit(git.io, ledger, try plan(git, arena, ledger.entries.items, req));
}

/// Write down what `plan` made. Where the ledger lives; runs no git.
pub fn commit(io: Io, ledger: *Ledger, planned: Prepared) Allocator.Error!Prepared {
    switch (planned) {
        .tree => |t| if (!t.reused) {
            // `put` replaces an entry of the same repository and name: one
            // whose directory had gone, which `plan` made again.
            try ledger.put(t.entry);
            ledger.save(io) catch |err| log.warn("worktree: could not save the ledger: {t}", .{err});
            log.info("worktree: made {s} at {s} on {s} from {s}", .{ t.entry.name, t.entry.path, t.entry.branch, t.entry.base });
        },
        .not_git, .refused => {},
    }
    return planned;
}

/// The git half of `prepare`: finds the repository, and makes the tree if
/// it is not there. `known` is what the ledger held when this was asked --
/// a copy, so this can run on a thread the ledger is not on. Writes nothing
/// down; `commit` does.
pub fn plan(git: Git, arena: Allocator, known: []const Entry, req: Request) Allocator.Error!Prepared {
    if (!validName(req.name)) return refuse(
        "BadParams",
        "a worktree name is 1 to 64 letters, digits, '.', '_' or '-', not starting with '.' or '-', with no '..'.",
    );

    const repo = (discover(git, arena, req.dir) catch |err| return gitFailure(arena, err)) orelse
        return .{ .not_git = req.dir };

    const branch = try std.fmt.allocPrint(arena, branch_prefix ++ "{s}", .{req.name});

    // Asked for again: the same tree, when it is still there. One whose
    // directory has gone is made again, and `commit` replaces its entry.
    for (known) |k| {
        if (!std.mem.eql(u8, k.repo, repo.main) or !std.mem.eql(u8, k.name, req.name)) continue;
        if (exists(git.io, k.path)) return .{ .tree = .{
            .entry = try k.dupe(arena),
            .reused = true,
        } };
        log.info("worktree: {s} was written down but {s} is gone; making it again", .{ req.name, k.path });
    }

    const path = try treePath(arena, repo, req.location, req.name);
    const ref = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{branch});
    const has_branch = git.run(arena, repo.main, &.{ "rev-parse", "--verify", "--quiet", ref }) catch |err|
        return gitFailure(arena, err);
    if (has_branch.ok) return .{ .refused = .{
        .code = "BranchExists",
        .message = try std.fmt.allocPrint(
            arena,
            "branch {s} already exists; nothing was opened. Pick another name, or delete the branch with git.",
            .{branch},
        ),
    } };

    // The other direction: `wt/<name>/<n>` is a task's branch, and `wt/<name>`
    // cannot be made beside it.
    const under = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{branch});
    const below = git.run(arena, repo.main, &.{ "for-each-ref", "--count=1", "--format=%(refname)", under }) catch |err|
        return gitFailure(arena, err);
    if (below.ok and below.out.len > 0) return .{ .refused = .{
        .code = "BranchExists",
        .message = try std.fmt.allocPrint(
            arena,
            "branch {s} cannot be made: {s} exists under it (a group's task branches); nothing was opened. " ++
                "Pick another name.",
            .{ branch, below.out },
        ),
    } };

    if (exists(git.io, path)) return .{ .refused = .{
        .code = "WorktreeExists",
        .message = try std.fmt.allocPrint(
            arena,
            "{s} is already there and Polter did not make it; nothing was opened. Pick another name.",
            .{path},
        ),
    } };

    return addTree(git, arena, repo, req.dir, .{
        .name = req.name,
        .branch = branch,
        .path = path,
        .location = req.location,
        .by = req.by,
        .now_ms = req.now_ms,
    });
}

/// What `addTree` writes down besides where it is.
const NewTree = struct {
    name: []const u8,
    branch: []const u8,
    path: []const u8,
    location: Location,
    by: u64,
    now_ms: i64,
    group: []const u8 = "",
    kind: Entry.Kind = .manual,
    task: ?u64 = null,
};

/// The part of making a tree that is the same for both kinds: a base to make
/// it at, the exclude line for `inside`, `git worktree add`, and the entry
/// with the path git itself reports.
fn addTree(git: Git, arena: Allocator, repo: Repo, dir: []const u8, nt: NewTree) Allocator.Error!Prepared {
    const head = git.run(arena, dir, &.{ "rev-parse", "--verify", "HEAD" }) catch |err|
        return gitFailure(arena, err);
    if (!head.ok) return refuse(
        "NoCommits",
        "that repository has no commit to base a worktree on; nothing was opened.",
    );
    const base = head.out;

    if (nt.location == .inside) ensureExcluded(arena, git.io, repo.common) catch |err| return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(
            arena,
            "could not write {s} into the repository's info/exclude ({t}), so a tree inside it " ++
                "could be committed; nothing was made.",
            .{ exclude_line, err },
        ),
    } };

    const add = git.run(arena, repo.main, &.{ "worktree", "add", "-b", nt.branch, nt.path, base }) catch |err|
        return gitFailure(arena, err);
    if (!add.ok) return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(arena, "git worktree add failed; nothing was opened: {s}", .{add.err}),
    } };

    // What git made it, not what was asked for: the two differ wherever a
    // path goes through a link (`/tmp` on macOS), and a terminal's `cwd` is
    // matched against this.
    const real = git.run(arena, nt.path, &.{ "rev-parse", "--show-toplevel" }) catch null;
    const entry: Entry = .{
        .name = nt.name,
        .repo = repo.main,
        .path = if (real) |r| (if (r.ok and r.out.len > 0) r.out else nt.path) else nt.path,
        .branch = nt.branch,
        .base = base,
        .created_ms = nt.now_ms,
        .by = nt.by,
        .task = nt.task,
        .group = nt.group,
        .kind = nt.kind,
    };
    return .{ .tree = .{ .entry = entry, .reused = false } };
}

pub const TaskRequest = struct {
    /// The directory the tree is made from; its `HEAD` is the base.
    dir: []const u8,
    /// The group the task is in, now.
    group: []const u8,
    task: u64,
    location: Location = .beside,
    by: u64 = 0,
    now_ms: i64 = 0,
};

/// `prepare` for a task's own tree. Same two halves as `plan`/`commit`.
pub fn prepareTask(git: Git, arena: Allocator, ledger: *Ledger, req: TaskRequest) Allocator.Error!Prepared {
    return commit(git.io, ledger, try planTask(git, arena, ledger.entries.items, req));
}

/// The git half of making the tree *for a task*: `<repo>-wt/<group>/wt-<n>` on
/// `wt/<group>/<n>`, with `group` and `task` written into the entry **now**
/// -- not later, by `task_assign` finding a terminal standing in it.
///
/// Asked for again, it is the same tree. A manual branch called `wt/<group>`
/// would make `wt/<group>/<n>` impossible (git keeps a ref as a file, and a
/// file cannot also be a directory), so that is refused first, by name,
/// without touching the other branch.
pub fn planTask(git: Git, arena: Allocator, known: []const Entry, req: TaskRequest) Allocator.Error!Prepared {
    if (req.task == 0) return refuse("BadParams", "a task's worktree needs the task's number.");

    const repo = (discover(git, arena, req.dir) catch |err| return gitFailure(arena, err)) orelse
        return .{ .not_git = req.dir };

    const name = try taskTreeName(arena, req.group, req.task);
    const seg = try groupSegment(arena, req.group);
    const branch = try taskBranch(arena, req.group, req.task);

    for (known) |k| {
        if (k.kind != .task or k.task != req.task) continue;
        if (!std.mem.eql(u8, k.repo, repo.main)) continue;
        if (exists(git.io, k.path)) return .{ .tree = .{
            .entry = try k.dupe(arena),
            .reused = true,
        } };
        log.info("worktree: {s} was written down but {s} is gone; making it again", .{ k.name, k.path });
    }

    const path = try taskTreePath(arena, repo, req.location, req.group, req.task);

    const prefix = try std.fmt.allocPrint(arena, "refs/heads/" ++ branch_prefix ++ "{s}", .{seg});
    const taken = git.run(arena, repo.main, &.{ "rev-parse", "--verify", "--quiet", prefix }) catch |err|
        return gitFailure(arena, err);
    if (taken.ok) return .{ .refused = .{
        .code = "BranchPrefixTaken",
        .message = try std.fmt.allocPrint(
            arena,
            "branch {s}{s} exists, so no branch can be made under {s}{s}/ (git keeps a branch as a file " ++
                "and a file cannot also be a directory); nothing was opened. Rename or delete that " ++
                "branch with git, or move this task to another group.",
            .{ branch_prefix, seg, branch_prefix, seg },
        ),
    } };
    const ref = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{branch});
    const has_branch = git.run(arena, repo.main, &.{ "rev-parse", "--verify", "--quiet", ref }) catch |err|
        return gitFailure(arena, err);
    if (has_branch.ok) {
        // Somebody (an earlier request for this very task, racing this one)
        // has made the tree and the ledger has not heard yet: it is the
        // task's tree, and is used as it stands.
        if (try checkedOutAt(git, arena, repo.main, ref)) |at| {
            // Only the place this task's tree goes. The branch checked out
            // in the main working tree, or in a tree somebody made by hand
            // elsewhere, is theirs and is not taken for the task's: the
            // task's tree would be the main repository, and closing the
            // task would clear *its* build output.
            const here = try canonical(git.io, arena, at);
            const there = try canonical(git.io, arena, path);
            const main = try canonical(git.io, arena, repo.main);
            if (!samePath(here, there) or samePath(here, main)) return .{ .refused = .{
                .code = "BranchExists",
                .message = try std.fmt.allocPrint(
                    arena,
                    "branch {s} is checked out at {s}, which is not where this task's worktree goes; " ++
                        "nothing was opened. Look at it with git before doing anything to it.",
                    .{ branch, at },
                ),
            } };
            const base = git.run(arena, repo.main, &.{ "merge-base", "HEAD", ref }) catch |err|
                return gitFailure(arena, err);
            return .{ .tree = .{ .entry = .{
                .name = name,
                .repo = repo.main,
                .path = at,
                .branch = branch,
                .base = if (base.ok) base.out else "",
                .created_ms = req.now_ms,
                .by = req.by,
                .task = req.task,
                .group = req.group,
                .kind = .task,
            }, .reused = false } };
        }
        // Nothing has it checked out: it is a branch somebody made, and may
        // hold their work. Not for Polter to say what becomes of it.
        return .{ .refused = .{
            .code = "BranchExists",
            .message = try std.fmt.allocPrint(
                arena,
                "branch {s} already exists and no worktree has it checked out; nothing was opened. " ++
                    "It may hold work: look at it with git before doing anything to it.",
                .{branch},
            ),
        } };
    }

    // A manual tree (or any directory) sitting where the group's directory
    // goes: a tree is a directory with a `.git` in it, and a task tree must
    // not be made inside another tree.
    const group_dir = std.fs.path.dirname(path) orelse path;
    const dot_git = try std.fs.path.join(arena, &.{ group_dir, ".git" });
    if (exists(git.io, dot_git)) return .{ .refused = .{
        .code = "WorktreeExists",
        .message = try std.fmt.allocPrint(
            arena,
            "{s}, where this group's task trees go, is itself a worktree that Polter did not make for a " ++
                "task; nothing was opened. Remove it or pick another group.",
            .{group_dir},
        ),
    } };
    if (exists(git.io, path)) return .{ .refused = .{
        .code = "WorktreeExists",
        .message = try std.fmt.allocPrint(
            arena,
            "{s} is already there and Polter did not make it; nothing was opened.",
            .{path},
        ),
    } };

    return addTree(git, arena, repo, req.dir, .{
        .name = name,
        .branch = branch,
        .path = path,
        .location = req.location,
        .by = req.by,
        .now_ms = req.now_ms,
        .group = req.group,
        .kind = .task,
        .task = req.task,
    });
}

/// The path of the worktree that has `ref` (a full ref name) checked out,
/// as `git worktree list` reports it.
fn checkedOutAt(git: Git, arena: Allocator, repo: []const u8, ref: []const u8) Allocator.Error!?[]const u8 {
    const r = git.run(arena, repo, &.{ "worktree", "list", "--porcelain" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!r.ok) return null;
    var path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "worktree ")) {
            path = l["worktree ".len..];
        } else if (std.mem.startsWith(u8, l, "branch ")) {
            if (std.mem.eql(u8, l["branch ".len..], ref)) return path;
        }
    }
    return null;
}

/// What a `Job` is to do. Every one of them runs git, several times, and
/// some delete a directory; none of that may happen on the app thread.
pub const Work = union(enum) {
    /// A tree asked for by name (`plan`).
    manual: Request,
    /// A task's own tree (`planTask`).
    task: TaskRequest,
    /// What closing or cancelling a task does to its tree (`closeout`).
    closeout: CloseWork,
    /// `worktree_status`: the tree `Selector` names, or every one when it
    /// names none (a `repo` alone narrows the list).
    status: Selector,
    /// `worktree_remove`.
    remove: Selector,

    fn dupe(self: Work, a: Allocator) Allocator.Error!Work {
        return switch (self) {
            .manual => |r| blk: {
                var c = r;
                c.dir = try a.dupe(u8, r.dir);
                c.name = try a.dupe(u8, r.name);
                break :blk .{ .manual = c };
            },
            .task => |r| blk: {
                var c = r;
                c.dir = try a.dupe(u8, r.dir);
                c.group = try a.dupe(u8, r.group);
                break :blk .{ .task = c };
            },
            .closeout => |w| .{ .closeout = .{ .task = w.task, .in = try w.in.dupe(a) } },
            .status => |s| .{ .status = try s.dupe(a) },
            .remove => |s| .{ .remove = try s.dupe(a) },
        };
    }
};

pub const CloseWork = struct { task: u64, in: CloseIn };

/// What a `Job` made. Its strings are in the job's arena and live until the
/// job is destroyed: the owner copies what it keeps.
pub const Result = union(enum) {
    prepared: Prepared,
    closeout: Closeout,
    /// `worktree_status`. `single` when one tree was named: the answer is
    /// that object rather than an array.
    statuses: struct { rows: []const Status, single: bool },
    removed: struct {
        what: Removed,
        /// The tree's identity if it is gone from the ledger now.
        gone: ?Gone,
    },
    /// Nothing was done: `Selector` named no tree, or named two.
    refused: Refusal,

    /// The tree this result took out of the ledger, if it did -- for the
    /// owner, which keeps the real ledger, to forget it too.
    pub fn goneTree(self: Result) ?Gone {
        return switch (self) {
            .closeout => |c| switch (c.outcome) {
                .removed, .forgotten => .{ .repo = c.repo, .name = c.name, .path = c.path, .created_ms = c.created_ms },
                else => null,
            },
            .removed => |r| r.gone,
            else => null,
        };
    }
};

/// Which row went. `path` and `created_ms` are in it because a manual tree's
/// name can be used again: a tree made under the same name while the job ran
/// is another row and must stay.
pub const Gone = struct { repo: []const u8, name: []const u8, path: []const u8, created_ms: i64 };

/// Take `result`'s tree out of the real ledger, as the job's private copy
/// already did, and save. Run where the ledger lives. Whether it changed.
pub fn forgetGone(io: Io, ledger: *Ledger, result: Result) bool {
    const gone = result.goneTree() orelse return false;
    const i = ledger.find(gone.repo, gone.name) orelse return false;
    const row = ledger.entries.items[i];
    if (!std.mem.eql(u8, row.path, gone.path) or row.created_ms != gone.created_ms) return false;
    ledger.removeAt(i);
    ledger.save(io) catch |err| log.warn("worktree: could not save the ledger: {t}", .{err});
    return true;
}

/// A `Work` on a thread of its own (task 1702, extended for tasks).
///
/// **Why a thread and not the caller's.** In the app the caller is the app
/// thread, which every terminal's events and the person's window go
/// through; `git worktree add` on this repository checks out six thousand
/// files, and the window would stand still for as long as that takes -- on
/// a larger repository or a slower disk, longer. The same goes for the rest
/// of `Work`: `landed` runs a handful of git commands and a removal deletes
/// the directory. So the app starts one of these, parks the request, and
/// answers it when `done` says so.
///
/// Owns copies of everything it reads, in its own arena, because the
/// request that asked may be answered -- and freed -- by somebody else (the
/// server shutting down) while git is still running. **It works on a private
/// copy of the ledger** (`known`), never the real one; `forgetGone` brings
/// the real one into line afterwards.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    git: Git,
    work: Work,
    known: []const Entry,
    /// Set on the job's thread before `finished`; read after it.
    result: ?Result = null,
    finished: std.atomic.Value(bool) = .init(false),
    /// Set by `done`'s owner when it could not hand the finished job back to
    /// the app thread: nothing will dispatch its request again, so `round`
    /// settles it on whichever request comes next.
    undelivered: std.atomic.Value(bool) = .init(false),
    /// Called on the job's thread once `result` is set: the last thing the
    /// thread does with the job. Must not wait for the job's owner.
    done: *const fn (ctx: *anyopaque, job: *Job) void,
    done_ctx: *anyopaque,
    /// The owner's, for `done` to find what this job was for.
    user: ?*anyopaque = null,
    thread: ?std.Thread = null,

    /// `child` must be safe to use from another thread.
    pub fn create(
        child: Allocator,
        git: Git,
        work: Work,
        known: []const Entry,
        done: *const fn (ctx: *anyopaque, job: *Job) void,
        done_ctx: *anyopaque,
    ) Allocator.Error!*Job {
        const job = try child.create(Job);
        errdefer child.destroy(job);
        job.* = .{
            .arena = .init(child),
            .git = git,
            .work = undefined,
            .known = &.{},
            .done = done,
            .done_ctx = done_ctx,
        };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.work = try work.dupe(a);
        const copies = try a.alloc(Entry, known.len);
        for (known, copies) |k, *c| c.* = try k.dupe(a);
        job.known = copies;
        return job;
    }

    /// Start it, and return without waiting for git.
    pub fn start(self: *Job) std.Thread.SpawnError!void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Job) void {
        self.result = self.execute() catch .{ .refused = .{
            .code = "WorktreeFailed",
            .message = "ran out of memory working on the worktree; it may be half done.",
        } };
        self.finished.store(true, .release);
        self.done(self.done_ctx, self);
    }

    /// The work itself. Public so a test can run it without a thread.
    pub fn execute(self: *Job) Allocator.Error!Result {
        const a = self.arena.allocator();
        switch (self.work) {
            .manual => |req| return .{ .prepared = try plan(self.git, a, self.known, req) },
            .task => |req| return .{ .prepared = try planTask(self.git, a, self.known, req) },
            else => {},
        }
        // The rest read and may change the ledger: its private copy, which
        // writes nowhere (`file` is null).
        var ledger: Ledger = .{ .alloc = a, .file = null };
        try ledger.entries.appendSlice(a, self.known);
        switch (self.work) {
            .manual, .task => unreachable,
            .closeout => |w| return .{ .closeout = try closeout(self.git, a, &ledger, w.task, w.in) },
            .remove => |sel| {
                const who: ?Gone = switch (ledger.select(sel.name, sel.repo, sel.task)) {
                    // Copied: the removal frees the entry these come from.
                    .one => |i| .{
                        .repo = try a.dupe(u8, ledger.entries.items[i].repo),
                        .name = try a.dupe(u8, ledger.entries.items[i].name),
                        .path = try a.dupe(u8, ledger.entries.items[i].path),
                        .created_ms = ledger.entries.items[i].created_ms,
                    },
                    else => null,
                };
                const what = try removeSel(self.git, a, &ledger, sel);
                const gone = switch (what) {
                    .removed, .forgotten => who,
                    .refused => null,
                };
                return .{ .removed = .{ .what = what, .gone = gone } };
            },
            .status => |sel| {
                if (sel.name.len > 0 or sel.task != 0) {
                    const i = switch (ledger.select(sel.name, sel.repo, sel.task)) {
                        .none => return .{ .refused = .{
                            .code = "NoSuchWorktree",
                            .message = "Polter has no worktree by that name; leave name out to list them all.",
                        } },
                        .ambiguous => return .{ .refused = .{
                            .code = "BadParams",
                            .message = "more than one repository has a worktree by that name; say which with repo.",
                        } },
                        .one => |i| i,
                    };
                    const rows = try a.alloc(Status, 1);
                    rows[0] = try statusFull(self.git, a, ledger.entries.items[i]);
                    return .{ .statuses = .{ .rows = rows, .single = true } };
                }
                var rows: std.ArrayList(Status) = .empty;
                for (ledger.entries.items) |e| {
                    if (sel.repo.len > 0 and !std.mem.eql(u8, e.repo, sel.repo)) continue;
                    try rows.append(a, try statusFull(self.git, a, e));
                }
                return .{ .statuses = .{ .rows = rows.items, .single = false } };
            },
        }
    }

    /// Wait for the thread to have left `run`. After `done` has been
    /// called that is a moment, not a wait for git.
    pub fn join(self: *Job) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn destroy(self: *Job) void {
        self.join();
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self);
    }
};

// ----------------------------------------------- the app's book of jobs
//
// What the app thread keeps about the jobs it started, kept here so that the
// two things that went wrong with it (task 2495) can be tested on real jobs
// and a real ledger: a second request for a task's tree started a second
// job, and a finished job whose request was then refused was never put in
// the ledger.

/// A running or finished `Job` and the request it parked. `held` is the
/// request's identity (an address) -- this file does not know its type.
pub const Wait = struct {
    job: *Job,
    held: *anyopaque,
    /// For a close or a cancel: what the reply says of the members. Owned
    /// by the app.
    preface: []u8 = &.{},
    /// The ledger already has what the job did (`settle`).
    settled: bool = false,
    /// A job nobody's request is waiting for (a closeout started because a
    /// task closed while its tree was being made): `held` is the job itself,
    /// and `round` collects it when it is done.
    orphan: bool = false,
};

/// A request for the tree of a task whose tree another request is already
/// making. It waits for that one rather than make a second.
pub const Follower = struct { task: u64, held: *anyopaque };

pub fn waitFor(waits: []const Wait, held: *const anyopaque) ?usize {
    for (waits, 0..) |w, i| if (w.held == held) return i;
    return null;
}

/// The job making `task`'s tree, started by any request.
pub fn taskLeader(waits: []const Wait, task: u64) ?usize {
    for (waits, 0..) |w, i| switch (w.job.work) {
        .task => |t| if (t.task == task) return i,
        else => {},
    };
    return null;
}

pub fn followerFor(followers: []const Follower, held: *const anyopaque) bool {
    for (followers) |f| if (f.held == held) return true;
    return false;
}

/// Put what a finished job did into the real ledger: the tree it made, the
/// tree it took down. **Before** the request that asked is dispatched again,
/// because that dispatch may refuse (the task was closed meanwhile, the seat
/// is taken) and then nothing else would ever look at the job -- and the
/// directory is on disk either way. Whether the ledger changed.
pub fn settle(io: Io, ledger: *Ledger, w: *Wait) bool {
    if (w.settled or !w.job.finished.load(.acquire)) return false;
    w.settled = true;
    const result = w.job.result orelse return false;
    var changed = false;
    switch (result) {
        .prepared => |p| switch (p) {
            .tree => |t| if (!t.reused) {
                _ = commit(io, ledger, p) catch |err| {
                    log.warn("worktree: could not write down a finished tree: {t}", .{err});
                    return false;
                };
                changed = true;
            },
            else => {},
        },
        else => {},
    }
    return forgetGone(io, ledger, result) or changed;
}

/// One request through the app's bookkeeping, in the only order that works.
/// `ctx` supplies what is the app's own:
///
///   - `dispatch(ctx) bool`        dispatch `held` now; whether it parked
///   - `wake(ctx, *anyopaque)`     dispatch a waiting follower again
///   - `taskOpen(ctx, u64) bool`   whether the task still takes work
///   - `closeOrphan(ctx, u64)`     start a closeout for a task already closed
///   - `release(ctx, Wait)`        free a wait that left the list
///
/// **Before** the dispatch: whatever finished jobs did goes into the ledger
/// (`settle`), and followers of a finished tree are woken -- the dispatch may
/// refuse the request, and then nothing else would look at the job. **After**
/// it: a job the dispatch did not take is dropped. Swapping the two leaves a
/// refused request's tree out of the ledger, or drops a job before it is read.
pub fn round(
    comptime Ctx: type,
    ctx: *Ctx,
    io: Io,
    alloc: Allocator,
    ledger: *Ledger,
    waits: *std.ArrayList(Wait),
    followers: *std.ArrayList(Follower),
    held: *anyopaque,
) void {
    sweep(Ctx, ctx, io, alloc, ledger, waits, followers);
    if (waitFor(waits.items, held)) |i| settleOne(Ctx, ctx, io, alloc, ledger, waits, followers, i);
    const parked = ctx.dispatch();
    if (parked) return;
    if (waitFor(waits.items, held)) |i| {
        const w = waits.items[i];
        if (w.settled and w.job.finished.load(.acquire)) {
            _ = waits.swapRemove(i);
            ctx.release(w);
        }
    }
}

fn settleOne(
    comptime Ctx: type,
    ctx: *Ctx,
    io: Io,
    alloc: Allocator,
    ledger: *Ledger,
    waits: *std.ArrayList(Wait),
    followers: *std.ArrayList(Follower),
    i: usize,
) void {
    const w = &waits.items[i];
    if (w.settled) return;
    _ = settle(io, ledger, w);
    if (!w.settled) return;
    const task = switch (w.job.work) {
        .task => |t| t.task,
        else => return,
    };
    if (takeFollowers(alloc, followers, task)) |woken| {
        defer alloc.free(woken);
        for (woken) |h| ctx.wake(h);
    } else |err| log.warn("worktree: could not wake the requests waiting on task {d}'s tree: {t}", .{ task, err });
    // The task was closed while its tree was being made, and the close saw
    // no tree. The tree is in the ledger now and nobody will close it out.
    if (!ctx.taskOpen(task) and ledger.taskTree(task) != null) ctx.closeOrphan(task);
}

/// Jobs that need no request to come back: an orphan closeout that is done,
/// and a job whose hand-back failed.
fn sweep(
    comptime Ctx: type,
    ctx: *Ctx,
    io: Io,
    alloc: Allocator,
    ledger: *Ledger,
    waits: *std.ArrayList(Wait),
    followers: *std.ArrayList(Follower),
) void {
    var i: usize = 0;
    while (i < waits.items.len) {
        const w = &waits.items[i];
        if (!w.job.finished.load(.acquire)) {
            i += 1;
            continue;
        }
        if (w.orphan) {
            _ = settle(io, ledger, w);
            const gone = waits.swapRemove(i);
            ctx.release(gone);
            continue;
        }
        if (w.job.undelivered.load(.acquire)) {
            settleOne(Ctx, ctx, io, alloc, ledger, waits, followers, i);
            const gone = waits.swapRemove(i);
            ctx.release(gone);
            continue;
        }
        i += 1;
    }
}

/// Whether a terminal counts as standing in a tree. One whose directory
/// cannot be read counts when it is a member of the task: a member that
/// cannot be placed is kept, not guessed gone.
pub fn stands(io: Io, arena: Allocator, root: []const u8, cwd: ?[]const u8, member: bool) Allocator.Error!bool {
    const c = cwd orelse return member;
    return standsIn(io, arena, root, c);
}

/// Every terminal that has held a place on `t`, now or before: the lead, the
/// places filled now, and everyone the task's record says sat in one.
///
/// **The record, not just the places.** Closing or cancelling a task first
/// takes every member's identity off (`Tasks.leave` writes `nobody` into the
/// place), and only then asks who is standing in the tree -- so the places
/// are empty at the one moment the answer matters. The spans keep the ids.
pub fn seatTerminals(alloc: Allocator, t: Tasks.Task) Allocator.Error![]const u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(alloc);
    const spans = try Tasks.spans(alloc, t);
    defer alloc.free(spans);
    const members = try Tasks.membersOf(alloc, t);
    defer alloc.free(members);
    try addSeat(alloc, &out, t.owner);
    for (members) |m| try addSeat(alloc, &out, m.id);
    for (spans) |sp| try addSeat(alloc, &out, sp.id);
    return out.toOwnedSlice(alloc);
}

fn addSeat(alloc: Allocator, out: *std.ArrayList(u64), id: u64) Allocator.Error!void {
    if (id == Tasks.nobody) return;
    if (std.mem.indexOfScalar(u64, out.items, id) != null) return;
    try out.append(alloc, id);
}

/// The followers of `task`, taken out of `followers`, for the app to
/// dispatch again now that the leader's tree is in the ledger.
pub fn takeFollowers(alloc: Allocator, followers: *std.ArrayList(Follower), task: u64) Allocator.Error![]const *anyopaque {
    var out: std.ArrayList(*anyopaque) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < followers.items.len) {
        if (followers.items[i].task != task) {
            i += 1;
            continue;
        }
        try out.append(alloc, followers.items[i].held);
        _ = followers.swapRemove(i);
    }
    return out.toOwnedSlice(alloc);
}

fn refuse(comptime code: []const u8, comptime message: []const u8) Prepared {
    return .{ .refused = .{ .code = code, .message = message } };
}

fn gitFailure(arena: Allocator, err: Git.Error) Allocator.Error!Prepared {
    _ = arena;
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.GitNotRunnable => refuse(
            "WorktreeFailed",
            "git could not be run here, so it cannot be told whether this is a repository; nothing was opened.",
        ),
    };
}

// -------------------------------------------------------------- status

pub const Status = struct {
    entry: Entry,
    exists: bool,
    /// Lines of `git status --porcelain`: changed and untracked files.
    /// Ignored files -- build directories -- are not counted.
    dirty: ?usize = null,
    /// Commits on the tree's branch that `mainline` does not have.
    ahead: ?usize = null,
    /// The branch the repository itself has checked out.
    mainline: ?[]const u8 = null,
    /// Everything on the branch is in `mainline`.
    merged: ?bool = null,
    /// Set when git could not answer.
    problem: ?[]const u8 = null,
    /// `landed` (below), filled by `statusFull`.
    landed: ?Landed = null,
    /// The group the task is in *now*; null when the caller does not know.
    /// Differs from `entry.group` after the group is renamed, which does not
    /// move the directory (`label_stale`).
    group_now: ?[]const u8 = null,
    /// Who holds the tree's build lease, when the caller knows.
    lease: ?LeaseView = null,
};

/// `status`, and whether the tree's work has landed. Costs a few more git
/// calls than `status`, so `remove` and `closeout` call `landed` themselves.
pub fn statusFull(git: Git, arena: Allocator, entry: Entry) Allocator.Error!Status {
    var s = try status(git, arena, entry);
    if (s.exists and s.problem == null) s.landed = try landed(git, arena, entry);
    return s;
}

pub fn status(git: Git, arena: Allocator, entry: Entry) Allocator.Error!Status {
    var s: Status = .{ .entry = entry, .exists = exists(git.io, entry.path) };
    if (!s.exists) return s;
    s.problem = problemOf(arena, statusInto(git, arena, &s)) catch |err| return err;
    return s;
}

fn problemOf(arena: Allocator, r: anyerror!void) Allocator.Error!?[]const u8 {
    r catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => try std.fmt.allocPrint(arena, "git could not answer ({t})", .{err}),
    };
    return null;
}

/// Whether git, asked in the tree, says the tree is its own repository root.
/// With the tree's `.git` gone git walks up and answers for whatever
/// repository is above -- the main one, for a tree made `inside` -- and every
/// answer after that is about the wrong place.
fn isOwnToplevel(git: Git, arena: Allocator, entry: Entry) !bool {
    const top = try git.run(arena, entry.path, &.{ "rev-parse", "--show-toplevel" });
    if (!top.ok) return false;
    return samePath(top.out, entry.path);
}

fn samePath(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a, "/\\");
    const y = std.mem.trimEnd(u8, b, "/\\");
    if (x.len != y.len) return false;
    for (x, y) |l, r| {
        const ln = if (l == '\\') '/' else l;
        const rn = if (r == '\\') '/' else r;
        if (ln == rn) continue;
        if (builtin.os.tag == .windows and std.ascii.toLower(ln) == std.ascii.toLower(rn)) continue;
        return false;
    }
    return true;
}

fn statusInto(git: Git, arena: Allocator, s: *Status) !void {
    if (!try isOwnToplevel(git, arena, s.entry)) return error.NotItsOwnRepo;
    const st = try git.run(arena, s.entry.path, &.{ "status", "--porcelain" });
    if (!st.ok) return error.StatusFailed;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, st.out, '\n');
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " \t\r").len > 0) n += 1;
    }
    s.dirty = n;

    const main_head = try git.run(arena, s.entry.repo, &.{ "rev-parse", "--verify", "HEAD" });
    if (!main_head.ok) return error.NoMainline;
    const main_name = try git.run(arena, s.entry.repo, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    s.mainline = if (main_name.ok and !std.mem.eql(u8, main_name.out, "HEAD"))
        main_name.out
    else
        try std.fmt.allocPrint(arena, "(detached at {s})", .{main_head.out[0..@min(main_head.out.len, 9)]});

    const range = try std.fmt.allocPrint(arena, "{s}..{s}", .{ main_head.out, s.entry.branch });
    const count = try git.run(arena, s.entry.repo, &.{ "rev-list", "--count", range });
    if (!count.ok) return error.NoBranch;
    const ahead = std.fmt.parseInt(usize, count.out, 10) catch return error.NoBranch;
    // The branch is not what the tree holds once a worker has detached HEAD:
    // count what the tree's own HEAD has that the mainline does not.
    const tree_ahead = try aheadOfTreeHead(git, arena, s.entry, main_head.out);
    s.ahead = @max(ahead, tree_ahead);
    s.merged = s.ahead == 0;
}

/// Commits on the *tree's* `HEAD` that `main_head` does not have. Asked in the
/// tree, because `HEAD` there is whatever the worker left it on -- a detached
/// commit is reachable from no branch and goes with the tree.
fn aheadOfTreeHead(git: Git, arena: Allocator, entry: Entry, main_head: []const u8) !usize {
    const range = try std.fmt.allocPrint(arena, "{s}..HEAD", .{main_head});
    const count = try git.run(arena, entry.path, &.{ "rev-list", "--count", range });
    if (!count.ok) return error.NoTreeHead;
    return std.fmt.parseInt(usize, count.out, 10) catch return error.NoTreeHead;
}

pub fn writeStatus(w: *std.json.Stringify, s: Status) std.Io.Writer.Error!void {
    const e = s.entry;
    try w.beginObject();
    try w.objectField("name");
    try w.write(e.name);
    try w.objectField("path");
    try w.write(e.path);
    try w.objectField("branch");
    try w.write(e.branch);
    try w.objectField("base");
    try w.write(e.base);
    try w.objectField("repo");
    try w.write(e.repo);
    try w.objectField("task");
    try w.write(e.task);
    try w.objectField("terminal");
    if (e.terminal) |t| {
        var buf: [18]u8 = undefined;
        try w.write(std.fmt.bufPrint(&buf, "0x{x:0>16}", .{t}) catch unreachable);
    } else try w.write(null);
    try w.objectField("exists");
    try w.write(s.exists);
    try w.objectField("dirty");
    try w.write(s.dirty);
    try w.objectField("ahead");
    try w.write(s.ahead);
    try w.objectField("mainline");
    try w.write(s.mainline);
    try w.objectField("merged");
    try w.write(s.merged);
    try w.objectField("kind");
    try w.write(@tagName(e.kind));
    try w.objectField("group");
    try w.write(e.group);
    try w.objectField("group_now");
    try w.write(s.group_now);
    try w.objectField("label_stale");
    try w.write(e.kind == .task and s.group_now != null and !std.mem.eql(u8, e.group, s.group_now.?));
    try w.objectField("lease");
    if (s.lease) |l| {
        try w.beginObject();
        try w.objectField("holder_alias");
        try w.write(l.alias);
        try w.objectField("holder");
        var buf: [18]u8 = undefined;
        try w.write(std.fmt.bufPrint(&buf, "0x{x:0>16}", .{l.terminal}) catch unreachable);
        try w.objectField("purpose");
        try w.write(@tagName(l.purpose));
        try w.objectField("since_ms");
        try w.write(l.since_ms);
        try w.objectField("expires_ms");
        try w.write(l.expires_ms);
        try w.endObject();
    } else try w.write(null);
    // `landed` is the answer to "can this tree be taken down"; `merged`
    // above is only "the branch has no commit the mainline lacks", which in a
    // workflow where nobody commits on the branch is always true.
    try w.objectField("landed");
    try w.write(if (s.landed) |l| l.landed else null);
    try w.objectField("landed_checked");
    try w.write(if (s.landed) |l| l.checked else null);
    try w.objectField("unlanded_count");
    try w.write(if (s.landed) |l| l.unlanded_count else null);
    try w.objectField("ignored_extra");
    try w.beginArray();
    if (s.landed) |l| for (l.ignored_extra) |f| try w.write(f);
    try w.endArray();
    try w.objectField("ignored_more");
    try w.write(if (s.landed) |l| l.ignored_more else null);
    try w.objectField("unlanded");
    try w.beginArray();
    if (s.landed) |l| for (l.unlanded[0..@min(l.unlanded.len, max_listed)]) |u| {
        try w.beginObject();
        try w.objectField("path");
        try w.write(u.path);
        try w.objectField("why");
        try w.write(@tagName(u.why));
        try w.endObject();
    };
    try w.endArray();
    if (s.landed) |l| if (l.reason) |r| {
        try w.objectField("landed_reason");
        try w.write(r);
    };
    if (s.problem) |p| {
        try w.objectField("problem");
        try w.write(p);
    }
    try w.endObject();
}

// -------------------------------------------------------------- landed

/// More changed paths than this and the answer is "not landed" without
/// looking: better to keep a tree than to spend minutes proving a big one.
pub const max_landed_paths = 2000;

/// How many unlanded paths an answer lists; the rest are only counted.
pub const max_listed = 20;

/// Paths per git call, so no command line is long on any platform.
const path_batch = 100;

/// Why one path does not match the mainline.
pub const Why = enum {
    /// In both, with different content.
    differs,
    /// In the tree (new or untracked), not on the mainline.
    extra,
    /// Deleted in the tree, still on the mainline.
    main_still_has,
    /// Same content, different mode (the executable bit, or a link).
    mode,
    /// A submodule, a file that became a directory, a conflict, something
    /// that could not be read.
    cannot_tell,
};

pub const Unlanded = struct { path: []const u8, why: Why };

pub const Landed = struct {
    landed: bool,
    /// Paths looked at.
    checked: usize = 0,
    /// Every path that does not match.
    unlanded: []const Unlanded = &.{},
    unlanded_count: usize = 0,
    /// Commits on the branch the mainline lacks, when that is what decided it.
    ahead: ?usize = null,
    /// Ignored by git and not on the `build_debris` list: a `.env`, a note
    /// under a `.gitignore`d name. Taking the tree down takes these too; they
    /// do not decide `landed`, but the receipt names them.
    ignored_extra: []const []const u8 = &.{},
    /// How many more there are than `ignored_extra` lists.
    ignored_more: usize = 0,
    /// Said in words when it is not the paths that decided it.
    reason: ?[]const u8 = null,
    /// git could not answer. Not the same as "no": the caller says so.
    unknown: bool = false,
};

/// Whether the work in a tree is already on the mainline: **every path the
/// tree changed or added holds, on the mainline's `HEAD`, exactly what the
/// tree holds** (content and mode), and every path it deleted is gone there
/// too. Read-only, and safe off the app thread.
///
/// Not "merged": in this repository's workflow a worker never commits -- the
/// supervisor applies the patch on the main tree and commits there -- so
/// `ahead` is always 0 and the branch looks merged from the first minute, and
/// the tree is always dirty to git. Neither says whether the work is in.
pub fn landed(git: Git, arena: Allocator, entry: Entry) Allocator.Error!Landed {
    return landedOf(git, arena, entry) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{
            .landed = false,
            .unknown = true,
            .reason = try std.fmt.allocPrint(arena, "git could not answer ({t})", .{err}),
        },
    };
}

fn landedOf(git: Git, arena: Allocator, entry: Entry) !Landed {
    if (!try isOwnToplevel(git, arena, entry)) return error.NotItsOwnRepo;
    // A commit on the branch is work this check cannot see in the path
    // list: the tree may be clean and still hold it. A worker that
    // committed anyway is the case, and it is not landed.
    const main_head = try git.run(arena, entry.repo, &.{ "rev-parse", "--verify", "HEAD" });
    if (!main_head.ok) return error.NoMainline;
    const range = try std.fmt.allocPrint(arena, "{s}..{s}", .{ main_head.out, entry.branch });
    const count = try git.run(arena, entry.repo, &.{ "rev-list", "--count", range });
    if (!count.ok) return error.NoBranch;
    const ahead = std.fmt.parseInt(usize, count.out, 10) catch return error.NoBranch;
    if (ahead > 0) return .{
        .landed = false,
        .ahead = ahead,
        .reason = try std.fmt.allocPrint(
            arena,
            "the branch has {d} commit{s} the mainline does not",
            .{ ahead, if (ahead == 1) "" else "s" },
        ),
    };

    const tree_ahead = try aheadOfTreeHead(git, arena, entry, main_head.out);
    if (tree_ahead > 0) return .{
        .landed = false,
        .ahead = tree_ahead,
        .reason = try std.fmt.allocPrint(
            arena,
            "the tree's HEAD has {d} commit{s} the mainline does not (HEAD is not necessarily on {s})",
            .{ tree_ahead, if (tree_ahead == 1) "" else "s", entry.branch },
        ),
    };

    // Renames are split into "deleted" and "added", directories into files,
    // and `-z` keeps a path with a space, a newline or a quote whole.
    const st = try git.run(arena, entry.path, &.{ "status", "--porcelain=v1", "-z", "--no-renames", "-uall" });
    if (!st.ok) return error.StatusFailed;

    const Item = struct { path: []const u8, deleted: bool, odd: bool };
    var items: std.ArrayList(Item) = .empty;
    var recs = std.mem.splitScalar(u8, st.raw, 0);
    while (recs.next()) |rec| {
        if (rec.len < 4) continue;
        const x = rec[0];
        const y = rec[1];
        try items.append(arena, .{
            .path = rec[3..],
            .deleted = y == 'D' or (x == 'D' and y == ' '),
            .odd = x == 'U' or y == 'U' or x == 'T' or y == 'T' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D'),
        });
    }
    if (items.items.len > max_landed_paths) return .{
        .landed = false,
        .checked = items.items.len,
        .ahead = 0,
        .reason = try std.fmt.allocPrint(
            arena,
            "too_many: {d} changed paths, more than the {d} that are checked",
            .{ items.items.len, max_landed_paths },
        ),
    };

    // What the mainline holds at each of those paths.
    const Head = struct { mode: []const u8, oid: []const u8 };
    var head: std.StringHashMapUnmanaged(Head) = .empty;
    var at: usize = 0;
    while (at < items.items.len) : (at += path_batch) {
        const end = @min(items.items.len, at + path_batch);
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "--literal-pathspecs", "ls-tree", "-r", "-z", "HEAD", "--" });
        for (items.items[at..end]) |it| try args.append(arena, it.path);
        const r = try git.run(arena, entry.repo, args.items);
        if (!r.ok) return error.LsTreeFailed;
        var rows = std.mem.splitScalar(u8, r.raw, 0);
        while (rows.next()) |row| {
            const tab = std.mem.indexOfScalar(u8, row, '\t') orelse continue;
            var f = std.mem.tokenizeScalar(u8, row[0..tab], ' ');
            const mode = f.next() orelse continue;
            _ = f.next() orelse continue;
            const oid = f.next() orelse continue;
            try head.put(arena, row[tab + 1 ..], .{ .mode = mode, .oid = oid });
        }
    }

    // `null` is "matches".
    const verdict = try arena.alloc(?Why, items.items.len);
    @memset(verdict, null);
    const work_exec = try arena.alloc(bool, items.items.len);
    @memset(work_exec, false);
    var to_hash: std.ArrayList(usize) = .empty;

    for (items.items, 0..) |it, i| {
        if (it.odd) {
            verdict[i] = .cannot_tell;
            continue;
        }
        const h = head.get(it.path);
        if (it.deleted) {
            if (h != null) verdict[i] = .main_still_has;
            continue;
        }
        const abs = try std.fs.path.join(arena, &.{ entry.path, it.path });
        const stat = Io.Dir.cwd().statFile(git.io, abs, .{ .follow_symlinks = false }) catch {
            verdict[i] = .cannot_tell;
            continue;
        };
        const hh = h orelse {
            verdict[i] = if (stat.kind == .file or stat.kind == .sym_link) .extra else .cannot_tell;
            continue;
        };
        if (std.mem.eql(u8, hh.mode, "160000")) {
            verdict[i] = .cannot_tell;
            continue;
        }
        switch (stat.kind) {
            .file => {
                work_exec[i] = Io.File.Permissions.has_executable_bit and
                    (stat.permissions.toMode() & 0o111) != 0;
                if (std.mem.eql(u8, hh.mode, "120000")) verdict[i] = .differs else try to_hash.append(arena, i);
            },
            .sym_link => {
                if (!std.mem.eql(u8, hh.mode, "120000")) {
                    verdict[i] = .differs;
                    continue;
                }
                var buf: [4096]u8 = undefined;
                const n = Io.Dir.cwd().readLink(git.io, abs, &buf) catch {
                    verdict[i] = .cannot_tell;
                    continue;
                };
                const oid = try blobOid(arena, hh.oid.len, buf[0..n]);
                if (!std.mem.eql(u8, oid, hh.oid)) verdict[i] = .differs;
            },
            else => verdict[i] = .cannot_tell,
        }
    }

    // A regular file is hashed by git in the tree, so the tree's own
    // filters (line endings, attributes) apply as `git add` would apply them.
    at = 0;
    while (at < to_hash.items.len) : (at += path_batch) {
        const chunk = to_hash.items[at..@min(to_hash.items.len, at + path_batch)];
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "hash-object", "--" });
        for (chunk) |i| try args.append(arena, items.items[i].path);
        const r = try git.run(arena, entry.path, args.items);
        if (!r.ok) return error.HashFailed;
        var lines = std.mem.splitScalar(u8, r.out, '\n');
        for (chunk) |i| {
            const oid = std.mem.trim(u8, lines.next() orelse return error.HashFailed, " \t\r");
            const hh = head.get(items.items[i].path).?;
            if (!std.mem.eql(u8, oid, hh.oid)) {
                verdict[i] = .differs;
                continue;
            }
            // Same content. The mode is the other half of "the same": a
            // file that only became executable is not on the mainline.
            if (Io.File.Permissions.has_executable_bit) {
                const want_exec = std.mem.eql(u8, hh.mode, "100755");
                if (work_exec[i] != want_exec) verdict[i] = .mode;
            }
        }
    }

    var list: std.ArrayList(Unlanded) = .empty;
    for (items.items, verdict) |it, v| if (v) |why| try list.append(arena, .{ .path = it.path, .why = why });
    const ignored = try ignoredExtra(git, arena, entry);
    return .{
        .landed = list.items.len == 0,
        .checked = items.items.len,
        .unlanded = list.items,
        .unlanded_count = list.items.len,
        .ahead = 0,
        .ignored_extra = ignored.items,
        .ignored_more = ignored.more,
    };
}

/// Ignored paths in the tree that are not `build_debris` (nor inside one).
/// `status` leaves ignored files out of its list, so `--force` takes them
/// with the tree without any check having looked at them. At most
/// `max_listed`; best effort -- git failing here says nothing.
fn ignoredExtra(git: Git, arena: Allocator, entry: Entry) Allocator.Error!Ignored {
    const r = git.run(arena, entry.path, &.{ "status", "--porcelain=v1", "-z", "--ignored=matching" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    if (!r.ok) return .{};
    var more: usize = 0;
    var out: std.ArrayList([]const u8) = .empty;
    var recs = std.mem.splitScalar(u8, r.raw, 0);
    next: while (recs.next()) |rec| {
        if (!std.mem.startsWith(u8, rec, "!! ")) continue;
        const rel = std.mem.trimEnd(u8, rec[3..], "/");
        for (build_debris) |d| if (within(d, rel)) continue :next;
        if (out.items.len >= max_listed) {
            more += 1;
            continue;
        }
        try out.append(arena, rel);
    }
    return .{ .items = out.items, .more = more };
}

const Ignored = struct { items: []const []const u8 = &.{}, more: usize = 0 };

/// " Files git ignores ... : a, b, and N more." or "" -- for a reply that
/// is about a tree being taken down, which takes these with it.
fn ignoredSentence(arena: Allocator, l: Landed, gone: bool) Allocator.Error![]const u8 {
    if (l.ignored_extra.len == 0) return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(if (gone)
        " Files git ignores went with it and were not checked against the mainline: "
    else
        " Files git ignores are in it too, and would go with it unchecked: ") catch return error.OutOfMemory;
    listStrings(w, l.ignored_extra) catch return error.OutOfMemory;
    if (l.ignored_more > 0) w.print(", and {d} more", .{l.ignored_more}) catch return error.OutOfMemory;
    w.writeAll(".") catch return error.OutOfMemory;
    return out.written();
}

/// The id git gives a blob holding `bytes`, in the hash `oid_len` hex digits
/// say the repository uses. Only for a link's target, which `hash-object`
/// would follow rather than read.
fn blobOid(arena: Allocator, oid_len: usize, bytes: []const u8) Allocator.Error![]const u8 {
    var head_buf: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&head_buf, "blob {d}\x00", .{bytes.len}) catch unreachable;
    if (oid_len == 64) {
        var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
        sha.update(h);
        sha.update(bytes);
        var d: [32]u8 = undefined;
        sha.final(&d);
        return std.fmt.allocPrint(arena, "{x}", .{&d});
    }
    var sha: std.crypto.hash.Sha1 = .init(.{});
    sha.update(h);
    sha.update(bytes);
    var d: [20]u8 = undefined;
    sha.final(&d);
    return std.fmt.allocPrint(arena, "{x}", .{&d});
}

/// "path (why), ..." for at most `max_listed` of them.
fn unlandedList(arena: Allocator, l: Landed) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const n = @min(l.unlanded.len, max_listed);
    for (l.unlanded[0..n], 0..) |u, i| {
        out.writer.print("{s}{s} ({t})", .{ if (i == 0) "" else ", ", u.path, u.why }) catch return error.OutOfMemory;
    }
    if (l.unlanded_count > n) out.writer.print(", and {d} more", .{l.unlanded_count - n}) catch return error.OutOfMemory;
    return out.written();
}

// -------------------------------------------------------------- remove

pub const Removed = union(enum) {
    /// The tree and its branch are gone, and so is the entry.
    removed: struct {
        path: []const u8,
        /// Null when the branch went too; otherwise why it is still there.
        branch_kept: ?[]const u8,
        /// `ignoredSentence` of what went with it; "" when nothing did.
        ignored: []const u8,
    },
    /// The directory was already gone; only the entry was forgotten.
    forgotten: []const u8,
    refused: Refusal,
};

/// Which tree: by `name` (and `repo` when two repositories have that name),
/// or by `task`.
pub const Selector = struct {
    name: []const u8 = "",
    repo: []const u8 = "",
    task: u64 = 0,

    fn dupe(self: Selector, a: Allocator) Allocator.Error!Selector {
        return .{ .name = try a.dupe(u8, self.name), .repo = try a.dupe(u8, self.repo), .task = self.task };
    }
};

/// `removeSel` by name.
pub fn remove(git: Git, arena: Allocator, ledger: *Ledger, name: []const u8, repo: []const u8) Allocator.Error!Removed {
    return removeSel(git, arena, ledger, .{ .name = name, .repo = repo });
}

/// Take a tree down -- **only when its work has landed** (`landed`), and say
/// why not otherwise. The entry is the one `sel` names.
pub fn removeSel(git: Git, arena: Allocator, ledger: *Ledger, sel: Selector) Allocator.Error!Removed {
    const i = switch (ledger.select(sel.name, sel.repo, sel.task)) {
        .none => return .{ .refused = .{
            .code = "NoSuchWorktree",
            .message = if (sel.task != 0)
                try std.fmt.allocPrint(arena, "Polter has no worktree for task {d}; worktree_status lists them.", .{sel.task})
            else
                try std.fmt.allocPrint(arena, "Polter has no worktree called {s}; worktree_status lists them.", .{sel.name}),
        } },
        .ambiguous => |n| return .{ .refused = .{
            .code = "BadParams",
            .message = try std.fmt.allocPrint(arena, "{d} repositories have that worktree; say which with repo.", .{n}),
        } },
        .one => |i| i,
    };
    return removeIndex(git, arena, ledger, i);
}

/// The one place a tree is taken down, for `remove` and for `closeout`.
///
/// ⚠️ **The only `--force` in this file**, and only after `landed` has said
/// yes twice. A tree whose work has landed is still "dirty" to git -- the
/// changes are in it, and on the mainline -- so git refuses to remove it
/// without. Nothing else reaches this line, and a test reads the command log
/// to hold it to that.
fn removeIndex(git: Git, arena: Allocator, ledger: *Ledger, i: usize) Allocator.Error!Removed {
    const entry = try ledger.entries.items[i].dupe(arena);

    const s = try status(git, arena, entry);
    if (!s.exists) {
        ledger.removeAt(i);
        ledger.save(git.io) catch |err| log.warn("worktree: could not save the ledger: {t}", .{err});
        return .{ .forgotten = entry.path };
    }
    if (s.problem) |p| return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(arena, "whether the work in {s} has landed could not be told, so it was kept: {s}", .{ entry.path, p }),
    } };
    if (!s.merged.?) return .{ .refused = .{
        .code = "WorktreeNotMerged",
        .message = try std.fmt.allocPrint(
            arena,
            "branch {s} has {d} commit{s} that {s} does not; nothing was removed. Merge them with git first.",
            .{ entry.branch, s.ahead.?, if (s.ahead.? == 1) "" else "s", s.mainline.? },
        ),
    } };

    const first = try landed(git, arena, entry);
    if (first.unknown) return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(arena, "whether the work in {s} has landed could not be told, so it was kept: {s}", .{ entry.path, first.reason.? }),
    } };
    if (!first.landed) return .{ .refused = try notLanded(arena, entry, first) };

    // The tree can change between the answer and the delete: whoever is
    // working in it does not wait for this. Ask again, as late as possible.
    const second = try landed(git, arena, entry);
    if (!second.landed) return .{ .refused = try notLanded(arena, entry, second) };

    const rm = git.run(arena, entry.repo, &.{ "worktree", "remove", "--force", entry.path }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GitNotRunnable => return .{ .refused = .{ .code = "WorktreeFailed", .message = "git could not be run; nothing was removed." } },
    };
    if (!rm.ok) return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(arena, "git worktree remove failed; the tree is still there: {s}", .{rm.err}),
    } };

    // `-d`, not `-D`: git checks once more that it is merged.
    const br = git.run(arena, entry.repo, &.{ "branch", "-d", entry.branch }) catch null;
    const kept: ?[]const u8 = if (br) |b| (if (b.ok) null else b.err) else "git could not be run";

    ledger.removeAt(i);
    ledger.save(git.io) catch |err| log.warn("worktree: could not save the ledger: {t}", .{err});
    log.info("worktree: removed {s} at {s}", .{ entry.name, entry.path });
    return .{ .removed = .{ .path = entry.path, .branch_kept = kept, .ignored = try ignoredSentence(arena, second, true) } };
}

fn notLanded(arena: Allocator, entry: Entry, l: Landed) Allocator.Error!Refusal {
    const why: []const u8 = if (l.reason) |r|
        r
    else
        try std.fmt.allocPrint(arena, "{d} of {d} changed path{s} {s} not on the mainline as they are here: {s}", .{
            l.unlanded_count,
            l.checked,
            if (l.checked == 1) "" else "s",
            if (l.unlanded_count == 1) "is" else "are",
            try unlandedList(arena, l),
        });
    return .{
        .code = "WorktreeNotLanded",
        .message = try std.fmt.allocPrint(
            arena,
            "the work in {s} has not landed; nothing was removed: {s}. Apply it on the mainline, or " ++
                "throw it away with git, then ask again.{s}",
            .{ entry.path, why, try ignoredSentence(arena, l, false) },
        ),
    };
}

// ------------------------------------------------------ build leftovers

/// What is cleared from a tree, by name and nothing else: the build output
/// that grows to tens of gigabytes. Not a pattern. A name here is deleted
/// only if git also says the path is ignored there, so a tracked directory
/// that happens to be called `zig-out` is never touched.
pub const build_debris = [_][]const u8{
    ".zig-cache",
    "zig-out",
    "macos/build",
    "macos/GhosttyKit.xcframework",
    "windows/target",
    "windows/split-tree/target",
};

pub const CacheFail = struct { path: []const u8, why: []const u8 };

pub const CacheResult = struct {
    /// Somebody holds the lease or is building: nothing was touched
    /// (`CacheBusy`), because removing what `zig build` is reading is the
    /// worst thing this file could do.
    busy: bool = false,
    cleaned: []const []const u8 = &.{},
    /// There, not ignored by git, left alone.
    kept: []const []const u8 = &.{},
    failed: []const CacheFail = &.{},
};

/// Clear `build_debris` out of the tree. Runs git, deletes directories:
/// off the app thread. `busy` is the caller's word that a lease is held or a
/// build is running -- nothing is touched then.
pub fn cleanCache(git: Git, arena: Allocator, entry: Entry, busy: bool) Allocator.Error!CacheResult {
    if (busy) return .{ .busy = true };
    const own = isOwnToplevel(git, arena, entry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GitNotRunnable => false,
    };
    if (!own) return .{ .failed = try arena.dupe(CacheFail, &.{.{
        .path = ".",
        .why = "git does not see this directory as the worktree, so nothing it calls ignored can be trusted",
    }}) };
    var cleaned: std.ArrayList([]const u8) = .empty;
    var kept: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList(CacheFail) = .empty;
    for (build_debris) |rel| {
        const abs = try std.fs.path.join(arena, &.{ entry.path, rel });
        if (!exists(git.io, abs)) continue;
        const ign = git.run(arena, entry.path, &.{ "check-ignore", "-q", "--", rel }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.GitNotRunnable => {
                try failed.append(arena, .{ .path = rel, .why = "git could not be run" });
                continue;
            },
        };
        if (!ign.ok) {
            try kept.append(arena, rel);
            continue;
        }
        // It is inside the tree by construction; this is the guard that
        // stays true if the list is ever edited carelessly.
        std.debug.assert(within(entry.path, abs));
        Io.Dir.cwd().deleteTree(git.io, abs) catch |err| {
            try failed.append(arena, .{ .path = rel, .why = try std.fmt.allocPrint(arena, "{t}", .{err}) });
            continue;
        };
        try cleaned.append(arena, rel);
    }
    return .{ .cleaned = cleaned.items, .kept = kept.items, .failed = failed.items };
}

// ------------------------------------------------------------- closeout

pub const CloseMode = enum { closed, cancelled };

pub const CloseIn = struct {
    mode: CloseMode,
    /// Terminals still standing in the tree, named for a person (an alias
    /// and an id). The caller has already taken the members' identity off
    /// and closed the idle ones, so what is left is busy, the user's, or
    /// could not be closed.
    standing: []const []const u8 = &.{},
    /// Who holds the tree's build lease.
    lease: ?LeaseView = null,
    /// Aliases whose process tree is running a build in it.
    building: []const []const u8 = &.{},

    /// A copy whose strings are all in `a`.
    pub fn dupe(self: CloseIn, a: Allocator) Allocator.Error!CloseIn {
        var c = self;
        c.standing = try dupeStrings(a, self.standing);
        c.building = try dupeStrings(a, self.building);
        if (self.lease) |l| {
            var v = l;
            v.alias = try a.dupe(u8, l.alias);
            c.lease = v;
        }
        return c;
    }
};

fn dupeStrings(a: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |it, *o| o.* = try a.dupe(u8, it);
    return out;
}

pub const Outcome = enum {
    /// The task has no tree in the ledger.
    no_tree,
    /// Landed, nobody in it, nobody building: taken down.
    removed,
    /// The directory was already gone; the entry was dropped.
    forgotten,
    /// Landed, but terminals still stand in it.
    kept_standing,
    /// Landed, but the lease is held or a build is running.
    kept_busy,
    /// Work in it is not on the mainline.
    kept_unlanded,
    /// The branch has commits the mainline lacks.
    kept_ahead,
    /// git could not say.
    kept_unknown,
};

pub const Closeout = struct {
    outcome: Outcome,
    mode: CloseMode,
    task: u64,
    /// `Entry.repo` of the tree, with `name` its identity in the ledger.
    repo: []const u8 = "",
    name: []const u8 = "",
    path: []const u8 = "",
    created_ms: i64 = 0,
    branch: []const u8 = "",
    landed: ?Landed = null,
    ahead: ?usize = null,
    problem: ?[]const u8 = null,
    standing: []const []const u8 = &.{},
    lease: ?LeaseView = null,
    building: []const []const u8 = &.{},
    branch_kept: ?[]const u8 = null,
    /// A removal that was due and was refused at the last moment.
    refusal: ?Refusal = null,
    /// Null when the tree went (its cache with it).
    cache: ?CacheResult = null,
    /// The sentence for the supervisor, from `renderCloseout`.
    note: []const u8 = "",
};

/// What closing or cancelling a task does to its tree. **The one function**:
/// `task_close`, `task_cancel`, `worktree_status` and `worktree_remove` all
/// say what they say from here, so there is one table and one sentence per
/// row, and the delete is `removeIndex` -- the same code, the same checks, the
/// same single `--force` -- as the manual one.
///
/// | state                                      | tree  | cache |
/// | landed, nobody in it, no lease or build    | taken down | with it |
/// | landed, terminals still in it              | kept, named | cleared |
/// | landed, lease held or a build running      | kept, holder named | **not** (`CacheBusy`) |
/// | not landed                                 | kept, paths listed | cleared |
/// | the branch has commits the mainline lacks  | kept, branch named | cleared |
/// | git could not say / too many paths         | kept, reason | cleared |
///
/// A cancelled task is the same table: an unlanded tree is kept, an empty
/// one has nothing to lose and goes. The caller has already released the
/// members' leases when cancelling.
pub fn closeout(git: Git, arena: Allocator, ledger: *Ledger, task: u64, in: CloseIn) Allocator.Error!Closeout {
    var c: Closeout = .{
        .outcome = .no_tree,
        .mode = in.mode,
        .task = task,
        .standing = in.standing,
        .lease = in.lease,
        .building = in.building,
    };
    const i = ledger.taskTree(task) orelse {
        c.note = try renderCloseout(arena, c);
        return c;
    };
    const entry = try ledger.entries.items[i].dupe(arena);
    c.repo = entry.repo;
    c.name = entry.name;
    c.path = entry.path;
    c.created_ms = entry.created_ms;
    c.branch = entry.branch;
    const busy = in.lease != null or in.building.len > 0;

    const s = try status(git, arena, entry);
    if (!s.exists) {
        ledger.removeAt(i);
        ledger.save(git.io) catch |err| log.warn("worktree: could not save the ledger: {t}", .{err});
        c.outcome = .forgotten;
        c.note = try renderCloseout(arena, c);
        return c;
    }

    if (s.problem) |p| {
        c.outcome = .kept_unknown;
        c.problem = p;
    } else if (!s.merged.?) {
        c.outcome = .kept_ahead;
        c.ahead = s.ahead;
    } else {
        const l = try landed(git, arena, entry);
        c.landed = l;
        if (l.unknown) {
            c.outcome = .kept_unknown;
            c.problem = l.reason;
        } else if (!l.landed) {
            c.outcome = .kept_unlanded;
        } else if (busy) {
            c.outcome = .kept_busy;
        } else if (in.standing.len > 0) {
            c.outcome = .kept_standing;
        } else switch (try removeIndex(git, arena, ledger, i)) {
            .removed => |r| {
                c.outcome = .removed;
                c.branch_kept = r.branch_kept;
            },
            .forgotten => c.outcome = .forgotten,
            .refused => |r| {
                // Due, and the last look said no (the tree changed, or git
                // refused). Kept, and the reason is the sentence.
                c.outcome = .kept_unlanded;
                c.refusal = r;
            },
        }
    }

    switch (c.outcome) {
        .removed, .forgotten, .no_tree => {},
        // git is not answering for this tree (a broken `.git` makes it walk up
        // to another repository): what it calls ignored is not to be trusted
        // with a delete.
        .kept_unknown => {},
        else => c.cache = try cleanCache(git, arena, entry, busy),
    }
    c.note = try renderCloseout(arena, c);
    return c;
}

/// The sentence for `c`: what became of the tree, and why, with the paths,
/// terminals or holder that decided it named.
pub fn renderCloseout(arena: Allocator, c: Closeout) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    renderInto(w, c) catch return error.OutOfMemory;
    if (c.cache) |cache| {
        w.writeAll(" ") catch return error.OutOfMemory;
        renderCache(w, cache) catch return error.OutOfMemory;
    }
    return out.written();
}

fn renderInto(w: *std.Io.Writer, c: Closeout) !void {
    const verb = switch (c.mode) {
        .closed => "closed",
        .cancelled => "cancelled",
    };
    switch (c.outcome) {
        .no_tree => try w.print("Task {d} {s}. It has no worktree.", .{ c.task, verb }),
        .forgotten => try w.print("Task {d} {s}. Its worktree {s} was already gone; Polter no longer lists it.", .{ c.task, verb, c.path }),
        .removed => {
            try w.print(
                "Task {d} {s}. Its worktree {s} was taken down: everything changed in it is already on the mainline.",
                .{ c.task, verb, c.path },
            );
            if (c.branch_kept) |why| try w.print(" Its branch {s} was kept: {s}", .{ c.branch, why });
            if (c.landed) |l| if (l.ignored_extra.len > 0) {
                try w.writeAll(" Files git ignores went with it and were not checked against the mainline: ");
                try listStrings(w, l.ignored_extra);
                if (l.ignored_more > 0) try w.print(", and {d} more", .{l.ignored_more});
                try w.writeAll(".");
            };
        },
        .kept_standing => {
            try w.print("Task {d} {s}. Its worktree {s} (branch {s}) is kept: its work has landed, but ", .{ c.task, verb, c.path, c.branch });
            try listStrings(w, c.standing);
            try w.writeAll(if (c.standing.len == 1) " is still standing in it." else " are still standing in it.");
        },
        .kept_busy => {
            try w.print("Task {d} {s}. Its worktree {s} (branch {s}) is kept: its work has landed, but ", .{ c.task, verb, c.path, c.branch });
            if (c.lease) |l| try w.print("{s} holds its {t} lease", .{ l.alias, l.purpose });
            if (c.lease != null and c.building.len > 0) try w.writeAll(" and ");
            if (c.building.len > 0) {
                try listStrings(w, c.building);
                try w.writeAll(" is building in it");
            }
            try w.writeAll(".");
        },
        .kept_unlanded => {
            try w.print("Task {d} {s}. Its worktree {s} (branch {s}) is KEPT: ", .{ c.task, verb, c.path, c.branch });
            if (c.refusal) |r| {
                try w.writeAll(r.message);
            } else if (c.landed) |l| {
                if (l.reason) |r| {
                    try w.writeAll(r);
                    try w.writeAll(".");
                } else {
                    try w.print("{d} of {d} changed path{s} {s} not on the mainline as they are in the tree:", .{
                        l.unlanded_count,
                        l.checked,
                        if (l.checked == 1) "" else "s",
                        if (l.unlanded_count == 1) "is" else "are",
                    });
                    const n = @min(l.unlanded.len, max_listed);
                    for (l.unlanded[0..n]) |u| try w.print(" {s} ({t});", .{ u.path, u.why });
                    if (l.unlanded_count > n) try w.print(" and {d} more.", .{l.unlanded_count - n});
                }
            }
            try w.writeAll(" Apply that work on the mainline, or throw it away, before the tree is taken down.");
        },
        .kept_ahead => try w.print(
            "Task {d} {s}. Its worktree {s} is KEPT: it (branch {s}, or the commit its HEAD is on) has {d} commit{s} the mainline does not.",
            .{ c.task, verb, c.path, c.branch, c.ahead orelse 0, if ((c.ahead orelse 0) == 1) "" else "s" },
        ),
        .kept_unknown => try w.print(
            "Task {d} {s}. Its worktree {s} (branch {s}) is kept: whether its work has landed could not be told ({s}); git is not sure what it is asking about, so its build output was not touched.",
            .{ c.task, verb, c.path, c.branch, c.problem orelse "no reason given" },
        ),
    }
}

/// `note` with `preface` after its first sentence, "Task N closed." The
/// reply to a close says what became of the members first and of the tree
/// next, and the tree's sentence begins with that header.
pub fn withPreface(arena: Allocator, note: []const u8, preface: []const u8, task: u64, mode: CloseMode) Allocator.Error![]const u8 {
    if (preface.len == 0) return note;
    const header = try std.fmt.allocPrint(arena, "Task {d} {s}.", .{ task, switch (mode) {
        .closed => "closed",
        .cancelled => "cancelled",
    } });
    if (!std.mem.startsWith(u8, note, header)) return std.fmt.allocPrint(arena, "{s}{s}", .{ preface, note });
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ header, preface, note[header.len..] });
}

fn listStrings(w: *std.Io.Writer, items: []const []const u8) !void {
    for (items, 0..) |it, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", it });
}

fn renderCache(w: *std.Io.Writer, r: CacheResult) !void {
    if (r.busy) return w.writeAll("CacheBusy: its build output was not cleared because a lease is held or a build is running; it was left as it is, and Polter does not come back to clear it later.");
    if (r.cleaned.len > 0) {
        try w.writeAll("Build output cleared (");
        try listStrings(w, r.cleaned);
        try w.writeAll("); the next build in this tree is a cold one.");
    } else if (r.failed.len == 0) {
        try w.writeAll("There was no build output to clear.");
    }
    for (r.failed) |f| try w.print(" Could not clear {s}: {s}.", .{ f.path, f.why });
}

// ---------------------------------------------------------------- lease

/// What a lease is held for. Advice, not enforcement: Polter cannot stop an
/// agent's editor or see the `zig build` it types, so a lease is a note
/// everyone can read ("who, since when, for what"), kept so a tester does
/// not start a build while a developer is still writing.
pub const Purpose = enum { build, @"test", edit };

/// How long a lease lasts without being renewed.
pub const default_lease_ttl_ms: i64 = 30 * 60 * 1000;

pub const LeaseView = struct {
    alias: []const u8,
    terminal: u64,
    purpose: Purpose,
    since_ms: i64,
    expires_ms: i64,
};

/// Why a lease stopped being held.
pub const LeaseWhy = enum {
    /// Its holder let go.
    released,
    /// The holder's terminal is gone.
    terminal_closed,
    /// The holder's turn ended and nothing of theirs runs in the background.
    idle,
    /// Not renewed within the TTL.
    expired,
    /// The supervisor took it back.
    supervisor,
};

/// One lease let go: for the task's record, so the morning can say who held
/// it, for how long and why it stopped.
pub const LeaseEvent = struct {
    task: u64,
    why: LeaseWhy,
    alias: []const u8,
    terminal: u64,
    held_ms: i64,
};

/// What `sweep` is told of a terminal that holds a lease. A holder that is
/// not listed is gone.
pub const Liveness = enum { busy, idle, waiting_on_background };

pub const Seen = struct { terminal: u64, state: Liveness };

/// The leases on task trees: one holder per tree, in memory only. After a
/// restart nobody holds anything -- the agent sessions have to reconnect and
/// the old holders cannot be trusted to still be doing what they said.
pub const Leases = struct {
    alloc: Allocator,
    ttl_ms: i64 = default_lease_ttl_ms,
    held: std.ArrayList(Held) = .empty,

    const Held = struct {
        task: u64,
        alias: []u8,
        terminal: u64,
        purpose: Purpose,
        since_ms: i64,
        expires_ms: i64,

        fn view(self: Held) LeaseView {
            return .{
                .alias = self.alias,
                .terminal = self.terminal,
                .purpose = self.purpose,
                .since_ms = self.since_ms,
                .expires_ms = self.expires_ms,
            };
        }
    };

    pub fn init(alloc: Allocator) Leases {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Leases) void {
        for (self.held.items) |h| self.alloc.free(h.alias);
        self.held.deinit(self.alloc);
    }

    fn find(self: *const Leases, task: u64) ?usize {
        for (self.held.items, 0..) |h, i| if (h.task == task) return i;
        return null;
    }

    /// Who holds `task`'s tree. The alias is borrowed until the next change.
    pub fn status(self: *const Leases, task: u64) ?LeaseView {
        const i = self.find(task) orelse return null;
        return self.held.items[i].view();
    }

    pub const Acquired = union(enum) {
        /// The caller holds it now; `renewed` when it already did.
        granted: struct { view: LeaseView, renewed: bool },
        /// Somebody else does: `LeaseHeld`, with who and since when.
        held: LeaseView,
    };

    /// Take the lease, or renew it when the caller already holds it. Never
    /// waits and never queues: a tool call that blocked would hold up the
    /// agent's whole turn.
    pub fn acquire(
        self: *Leases,
        task: u64,
        alias: []const u8,
        terminal: u64,
        purpose: Purpose,
        now_ms: i64,
    ) Allocator.Error!Acquired {
        if (self.find(task)) |i| {
            const h = &self.held.items[i];
            if (h.terminal != terminal) return .{ .held = h.view() };
            h.purpose = purpose;
            h.expires_ms = now_ms + self.ttl_ms;
            return .{ .granted = .{ .view = h.view(), .renewed = true } };
        }
        const owned = try self.alloc.dupe(u8, alias);
        errdefer self.alloc.free(owned);
        try self.held.append(self.alloc, .{
            .task = task,
            .alias = owned,
            .terminal = terminal,
            .purpose = purpose,
            .since_ms = now_ms,
            .expires_ms = now_ms + self.ttl_ms,
        });
        return .{ .granted = .{ .view = self.held.items[self.held.items.len - 1].view(), .renewed = false } };
    }

    pub const Released = union(enum) {
        released: LeaseEvent,
        /// Nobody holds it -- including a holder from before a restart.
        not_held,
        /// Somebody else does, and the caller is not the supervisor.
        not_holder: LeaseView,
    };

    /// Let go. The holder may; the supervisor may let go of anyone's.
    pub fn release(
        self: *Leases,
        arena: Allocator,
        task: u64,
        terminal: u64,
        supervisor: bool,
        now_ms: i64,
    ) Allocator.Error!Released {
        const i = self.find(task) orelse return .not_held;
        const h = self.held.items[i];
        if (h.terminal != terminal and !supervisor) return .{ .not_holder = h.view() };
        const why: LeaseWhy = if (h.terminal == terminal) .released else .supervisor;
        const ev = try self.eventOf(arena, h, why, now_ms);
        self.drop(i);
        return .{ .released = ev };
    }

    /// The task is over: let go of whoever holds it, whoever that is.
    pub fn releaseTask(self: *Leases, arena: Allocator, task: u64, now_ms: i64) Allocator.Error!?LeaseEvent {
        const i = self.find(task) orelse return null;
        const ev = try self.eventOf(arena, self.held.items[i], .supervisor, now_ms);
        self.drop(i);
        return ev;
    }

    fn eventOf(self: *const Leases, arena: Allocator, h: Held, why: LeaseWhy, now_ms: i64) Allocator.Error!LeaseEvent {
        _ = self;
        return .{
            .task = h.task,
            .why = why,
            .alias = try arena.dupe(u8, h.alias),
            .terminal = h.terminal,
            .held_ms = now_ms - h.since_ms,
        };
    }

    fn drop(self: *Leases, i: usize) void {
        self.alloc.free(self.held.items[i].alias);
        _ = self.held.orderedRemove(i);
    }

    /// Let go of every lease whose holder cannot be holding it any more, and
    /// say each one. A holder's turn ending (`idle`) is a reason to let go
    /// unless something of theirs is running in the background -- a build
    /// they started and are waiting for.
    pub fn sweep(self: *Leases, arena: Allocator, now_ms: i64, seen: []const Seen) Allocator.Error![]const LeaseEvent {
        var events: std.ArrayList(LeaseEvent) = .empty;
        var i: usize = 0;
        while (i < self.held.items.len) {
            const h = self.held.items[i];
            const state: ?Liveness = for (seen) |s| {
                if (s.terminal == h.terminal) break s.state;
            } else null;
            const why: ?LeaseWhy = if (state == null)
                .terminal_closed
            else if (state.? == .idle)
                .idle
            else if (now_ms >= h.expires_ms)
                .expired
            else
                null;
            if (why) |wh| {
                try events.append(arena, try self.eventOf(arena, h, wh, now_ms));
                self.drop(i);
                continue;
            }
            i += 1;
        }
        return events.items;
    }
};

// --------------------------------------------------------------- tests
//
// ⚠️ Every repository these touch is made here, under `/tmp`, and deleted
// afterwards. Each fixture checks git sees the repository it made before
// anything is done to it, so a failed `git init` cannot fall through to
// whatever repository the test was started in.

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    /// Real path: on macOS `/tmp` is a link, and git answers in real paths.
    root: []const u8,
    repo: []const u8,

    fn init(fx: *Fixture) !void {
        const io = testing.io;
        fx.arena = .init(testing.allocator);
        errdefer fx.arena.deinit();
        const aa = fx.arena.allocator();

        fx.env = .init(aa);
        // Not the user's git: no global or system config, no hooks, no
        // signing -- and a name to commit under.
        try fx.env.put("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin");
        try fx.env.put("HOME", "/nonexistent");
        try fx.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try fx.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try fx.env.put("GIT_AUTHOR_NAME", "t");
        try fx.env.put("GIT_AUTHOR_EMAIL", "t@example.invalid");
        try fx.env.put("GIT_COMMITTER_NAME", "t");
        try fx.env.put("GIT_COMMITTER_EMAIL", "t@example.invalid");

        var raw: [6]u8 = undefined;
        io.random(&raw);
        const made = try std.fmt.allocPrint(aa, "/tmp/polter-wt-test-{x}", .{&raw});
        try Io.Dir.cwd().createDirPath(io, made);
        fx.root = try Io.Dir.cwd().realPathFileAlloc(io, made, aa);
        fx.repo = try std.fs.path.join(aa, &.{ fx.root, "proj" });
        try Io.Dir.cwd().createDirPath(io, fx.repo);

        const g = fx.git();
        try fx.must(fx.repo, &.{ "init", "-q", "-b", "main" });
        // The guard: the repository git sees is the one just made.
        const top = try g.run(aa, fx.repo, &.{ "rev-parse", "--show-toplevel" });
        try testing.expect(top.ok);
        try testing.expectEqualStrings(fx.repo, top.out);
        try fx.write(fx.repo, "a.txt", "one\n");
        try fx.must(fx.repo, &.{ "add", "a.txt" });
        try fx.must(fx.repo, &.{ "commit", "-q", "-m", "first" });
    }

    fn deinit(fx: *Fixture) void {
        std.debug.assert(std.mem.startsWith(u8, fx.root, "/private/tmp/polter-wt-test-") or
            std.mem.startsWith(u8, fx.root, "/tmp/polter-wt-test-"));
        Io.Dir.cwd().deleteTree(testing.io, fx.root) catch {};
        fx.arena.deinit();
    }

    fn git(fx: *Fixture) Git {
        return .{ .io = testing.io, .env = &fx.env };
    }

    fn al(fx: *Fixture) Allocator {
        return fx.arena.allocator();
    }

    fn must(fx: *Fixture, dir: []const u8, args: []const []const u8) !void {
        const r = try fx.git().run(fx.al(), dir, args);
        if (!r.ok) {
            std.debug.print("git {s} failed: {s}\n", .{ args[0], r.err });
            return error.TestGitFailed;
        }
    }

    fn out(fx: *Fixture, dir: []const u8, args: []const []const u8) ![]const u8 {
        const r = try fx.git().run(fx.al(), dir, args);
        try testing.expect(r.ok);
        return r.out;
    }

    fn write(fx: *Fixture, dir: []const u8, name: []const u8, data: []const u8) !void {
        const p = try std.fs.path.join(fx.al(), &.{ dir, name });
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = data });
    }

    fn ledgerFile(fx: *Fixture) ![]const u8 {
        return std.fs.path.join(fx.al(), &.{ fx.root, "state", "worktrees.json" });
    }
};

test "worktree: names that can be a directory and a branch" {
    try testing.expect(validName("fix-1702"));
    try testing.expect(validName("a.b_c"));
    try testing.expect(!validName(""));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("-x"));
    try testing.expect(!validName("a..b"));
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName("x.lock"));
    try testing.expect(!validName("a b"));
    try testing.expect(!validName("x" ** (max_name + 1)));
}

test "worktree: standsIn 先 realpath：经符号链接、带 .. 进树的终端也算站在树里；旁边同前缀的目录不算" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);

    // Through a link to the tree's parent.
    const link = try std.fs.path.join(a, &.{ fx.root, "via" });
    try Io.Dir.cwd().symLink(testing.io, std.fs.path.dirname(e.path).?, link, .{ .is_directory = true });
    const through = try std.fs.path.join(a, &.{ link, "wt-2435" });
    try testing.expect(!within(e.path, through));
    try testing.expect(try standsIn(testing.io, a, e.path, through));

    // Walked in by `..`.
    const out_and_back = try std.fmt.allocPrint(a, "{s}/../../{s}/wt-2435", .{ e.path, std.fs.path.basename(std.fs.path.dirname(e.path).?) });
    try testing.expect(try standsIn(testing.io, a, e.path, out_and_back));

    // `..` that leaves the tree is not standing in it, though the text starts with its path.
    const outside = try std.fmt.allocPrint(a, "{s}/../..", .{e.path});
    try testing.expect(within(e.path, outside));
    try testing.expect(!(try standsIn(testing.io, a, e.path, outside)));

    // A sibling that merely shares the prefix.
    const sibling = try std.fmt.allocPrint(a, "{s}x", .{e.path});
    try testing.expect(!(try standsIn(testing.io, a, e.path, sibling)));
}

test "worktree: within matches the tree and below it, not a sibling with the same prefix" {
    try testing.expect(within("/r/p-wt/x", "/r/p-wt/x"));
    try testing.expect(within("/r/p-wt/x/", "/r/p-wt/x/src"));
    try testing.expect(!within("/r/p-wt/x", "/r/p-wt/xy"));
    try testing.expect(!within("/r/p-wt/x", "/r/p-wt"));
}

test "worktree: made beside the repository, on a new branch, at its HEAD, and written down" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();

    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();

    const head = try fx.out(fx.repo, &.{ "rev-parse", "HEAD" });
    const p = try prepare(fx.git(), a, &ledger, .{ .dir = fx.repo, .name = "w1", .by = 7 });
    try testing.expect(p == .tree);
    const e = p.tree.entry;
    try testing.expect(!p.tree.reused);

    const want = try std.fs.path.join(a, &.{ fx.root, "proj-wt", "w1" });
    try testing.expectEqualStrings(want, e.path);
    try testing.expectEqualStrings("wt/w1", e.branch);
    try testing.expectEqualStrings(head, e.base);
    try testing.expectEqualStrings(fx.repo, e.repo);

    // The tree is there, on that branch, at that commit.
    try testing.expectEqualStrings("wt/w1", try fx.out(e.path, &.{ "rev-parse", "--abbrev-ref", "HEAD" }));
    try testing.expectEqualStrings(head, try fx.out(e.path, &.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(e.path, try fx.out(e.path, &.{ "rev-parse", "--show-toplevel" }));

    // And a restart -- a ledger read back from the file -- still knows it,
    // whose it was and which tree a terminal standing in it is in.
    var again = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer again.deinit();
    again.load(testing.io);
    try testing.expectEqual(@as(usize, 1), again.entries.items.len);
    const back = again.entries.items[0];
    try testing.expectEqualStrings("w1", back.name);
    try testing.expectEqualStrings(e.path, back.path);
    try testing.expectEqualStrings(head, back.base);
    try testing.expectEqual(@as(u64, 7), back.by);
    const sub = try std.fs.path.join(a, &.{ e.path, "src" });
    try testing.expectEqualStrings("w1", again.tagAt(sub).?.name);
    try testing.expect(again.tagAt(fx.repo) == null);
}

test "worktree: a task tied in the ledger is still tied after a restart" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();

    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();
    const p = try prepare(fx.git(), a, &ledger, .{ .dir = fx.repo, .name = "w1" });
    ledger.entries.items[0].terminal = 0x42;

    try testing.expect(ledger.tieTask(1702, 0x42, ""));
    try ledger.save(testing.io);

    var again = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer again.deinit();
    again.load(testing.io);
    try testing.expectEqual(@as(?u64, 1702), again.entries.items[0].task);
    try testing.expectEqual(@as(?usize, 0), again.forTask(1702, ""));
    // By where the owner stands, when nothing tied it.
    try testing.expectEqual(@as(?usize, 0), again.forTask(9, p.tree.entry.path));
    try testing.expect(again.forTask(9, fx.repo) == null);
}

test "worktree: the same name again is the same tree, not a second one" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const first = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    const second = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    try testing.expect(second == .tree);
    try testing.expect(second.tree.reused);
    try testing.expectEqualStrings(first.tree.entry.path, second.tree.entry.path);
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

test "worktree: a directory or branch Polter did not make is refused, not taken over" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    try fx.must(fx.repo, &.{ "branch", "wt/taken" });
    const b = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "taken" });
    try testing.expect(b == .refused);
    try testing.expectEqualStrings("BranchExists", b.refused.code);

    const there = try std.fs.path.join(fx.al(), &.{ fx.root, "proj-wt", "there" });
    try Io.Dir.cwd().createDirPath(testing.io, there);
    const d = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "there" });
    try testing.expect(d == .refused);
    try testing.expectEqualStrings("WorktreeExists", d.refused.code);

    const n = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "../up" });
    try testing.expectEqualStrings("BadParams", n.refused.code);
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
}

test "worktree: not a git repository -- no tree, and the answer says so" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const plain = try std.fs.path.join(fx.al(), &.{ fx.root, "plain" });
    try Io.Dir.cwd().createDirPath(testing.io, plain);
    const p = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = plain, .name = "w1" });
    try testing.expect(p == .not_git);
    // The terminal still opens, where it was asked to.
    try testing.expectEqualStrings(plain, p.dir().?);
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    try testing.expect(!exists(testing.io, try std.fs.path.join(fx.al(), &.{ fx.root, "plain-wt" })));
    const note = try notGitNote(fx.al(), plain);
    try testing.expect(std.mem.indexOf(u8, note, "not in a git repository") != null);
    try testing.expect(std.mem.indexOf(u8, note, "no worktree was made") != null);
}

test "worktree: inside the repository, excluded so git status does not see it" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const p = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1", .location = .inside });
    try testing.expect(p == .tree);
    const want = try std.fs.path.join(fx.al(), &.{ fx.repo, inside_dir, "w1" });
    try testing.expectEqualStrings(want, p.tree.entry.path);
    try testing.expectEqualStrings("", try fx.out(fx.repo, &.{ "status", "--porcelain" }));

    // The user's .gitignore is not where it was said.
    try testing.expect(!exists(testing.io, try std.fs.path.join(fx.al(), &.{ fx.repo, ".gitignore" })));

    // Said once, however many trees.
    _ = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w2", .location = .inside });
    const ex = try Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(fx.al(), &.{ fx.repo, ".git", "info", "exclude" }), fx.al(), .limited(1 << 20));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, ex, exclude_line));
}

test "worktree: a tree made from inside a tree goes beside the others" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const first = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    const second = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = first.tree.entry.path, .name = "w2" });
    try testing.expectEqualStrings(
        try std.fs.path.join(fx.al(), &.{ fx.root, "proj-wt", "w2" }),
        second.tree.entry.path,
    );
    try testing.expectEqualStrings(fx.repo, second.tree.entry.repo);
}

test "worktree: a job makes the tree off the calling thread, which carries on meanwhile" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;

    // A git that takes two seconds over `worktree`, and is git otherwise.
    const slow = try std.fs.path.join(fx.al(), &.{ fx.root, "slow-git" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = slow, .data =
        \\#!/bin/sh
        \\case "$3" in worktree) sleep 2;; esac
        \\exec git "$@"
        \\
    });
    const chmod = try std.process.run(fx.al(), io, .{ .argv = &.{ "/bin/chmod", "+x", slow } });
    try testing.expect(chmod.term == .exited and chmod.term.exited == 0);
    var git = fx.git();
    git.exe = slow;

    const Done = struct {
        count: std.atomic.Value(u32) = .init(0),
        fn done(ctx: *anyopaque, _: *Job) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.count.fetchAdd(1, .acq_rel);
        }
    };
    var told: Done = .{};

    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    const job = try Job.create(std.heap.smp_allocator, git, .{ .manual = .{ .dir = fx.repo, .name = "w1" } }, ledger.entries.items, Done.done, &told);
    defer job.destroy();

    const t0: Io.Timestamp = .now(io, .awake);
    try job.start();
    const took = t0.untilNow(io, .awake).toMilliseconds();
    // The floor: run inline, `start` would take the two seconds itself.
    try testing.expect(took < 500);

    // And the caller is free the whole time: it keeps turning until told.
    // **Counted in time, not in turns** (task 1919): a full run, with
    // xcodebuild's tests beside it, stretched the 20 ms sleeps past 80 ms
    // and came back with fewer than 25 turns across the two seconds. What
    // is claimed is that the caller came back more than once while git was
    // still at it, and that git took its two seconds on the other thread.
    const t1: Io.Timestamp = .now(io, .awake);
    var turns: usize = 0;
    while (!job.finished.load(.acquire)) : (turns += 1) {
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    const waited = t1.untilNow(io, .awake).toMilliseconds();
    try testing.expect(turns >= 2);
    try testing.expect(waited >= 1_500);
    job.join();
    try testing.expectEqual(@as(u32, 1), told.count.load(.acquire));

    // Written down on the caller's side, from what the job made.
    const p = try commit(io, &ledger, job.result.?.prepared);
    try testing.expect(p == .tree);
    try testing.expect(!p.tree.reused);
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    try testing.expectEqualStrings("wt/w1", try fx.out(p.tree.entry.path, &.{ "rev-parse", "--abbrev-ref", "HEAD" }));
}

test "worktree: a tree with work that is not on the mainline is not removed, and the refusal names the path" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const p = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    const path = p.tree.entry.path;
    try fx.write(path, "a.txt", "changed\n");

    const s = try status(fx.git(), fx.al(), p.tree.entry);
    try testing.expectEqual(@as(?usize, 1), s.dirty);
    try testing.expectEqual(@as(?bool, true), s.merged);

    const r = try remove(fx.git(), fx.al(), &ledger, "w1", "");
    try testing.expect(r == .refused);
    try testing.expectEqualStrings("WorktreeNotLanded", r.refused.code);
    try testing.expect(std.mem.indexOf(u8, r.refused.message, "a.txt (differs)") != null);
    try testing.expect(exists(testing.io, path));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

test "worktree: an unmerged tree is not removed, and the refusal says by how much" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const p = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    const path = p.tree.entry.path;
    try fx.write(path, "b.txt", "new\n");
    try fx.must(path, &.{ "add", "b.txt" });
    try fx.must(path, &.{ "commit", "-q", "-m", "work" });

    const s = try status(fx.git(), fx.al(), p.tree.entry);
    try testing.expectEqual(@as(?usize, 0), s.dirty);
    try testing.expectEqual(@as(?usize, 1), s.ahead);
    try testing.expectEqualStrings("main", s.mainline.?);
    try testing.expectEqual(@as(?bool, false), s.merged);

    const r = try remove(fx.git(), fx.al(), &ledger, "w1", "");
    try testing.expect(r == .refused);
    try testing.expectEqualStrings("WorktreeNotMerged", r.refused.code);
    try testing.expect(std.mem.indexOf(u8, r.refused.message, "1 commit that main does not") != null);
    try testing.expect(exists(testing.io, path));

    // Merged, it goes -- tree, branch and entry.
    try fx.must(fx.repo, &.{ "merge", "-q", "--ff-only", "wt/w1" });
    const ok = try remove(fx.git(), fx.al(), &ledger, "w1", "");
    try testing.expect(ok == .removed);
    try testing.expect(ok.removed.branch_kept == null);
    try testing.expect(!exists(testing.io, path));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    const br = try fx.git().run(fx.al(), fx.repo, &.{ "rev-parse", "--verify", "--quiet", "refs/heads/wt/w1" });
    try testing.expect(!br.ok);
}

test "worktree: a clean, merged tree is removed, ignored build output and all" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();

    try fx.write(fx.repo, ".gitignore", "zig-out/\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });

    const p = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    const path = p.tree.entry.path;
    // A build directory is not a change anybody would lose.
    const built = try std.fs.path.join(fx.al(), &.{ path, "zig-out" });
    try Io.Dir.cwd().createDirPath(testing.io, built);
    try fx.write(built, "bin", "x");

    const r = try remove(fx.git(), fx.al(), &ledger, "w1", "");
    try testing.expect(r == .removed);
    try testing.expect(!exists(testing.io, path));

    var again = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer again.deinit();
    again.load(testing.io);
    try testing.expectEqual(@as(usize, 0), again.entries.items.len);

    const none = try remove(fx.git(), fx.al(), &ledger, "w1", "");
    try testing.expectEqualStrings("NoSuchWorktree", none.refused.code);
}

// ------------------------------------------------- task trees (task 2465)
//
// Every repository below is the Fixture's, made under /tmp and deleted by
// `deinit`. The tests that delete a tree delete one the test itself made in
// that repository, never one of the working copy's.

/// The tree for `task` of `group`, made beside `fx.repo`.
fn taskTreeOf(fx: *Fixture, ledger: *Ledger, group: []const u8, task: u64) !Entry {
    const p = try prepareTask(fx.git(), fx.al(), ledger, .{ .dir = fx.repo, .group = group, .task = task });
    try testing.expect(p == .tree);
    return p.tree.entry;
}

/// What a worker leaves in its tree: `a.txt` changed, `b.txt` new.
fn workerWork(fx: *Fixture, dir: []const u8) !void {
    try fx.write(dir, "a.txt", "two\n");
    try fx.write(dir, "b.txt", "new\n");
}

/// The supervisor applying that work on the main tree and committing it.
fn landOnMain(fx: *Fixture) !void {
    try workerWork(fx, fx.repo);
    try fx.must(fx.repo, &.{ "add", "a.txt", "b.txt" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "land" });
}

fn chmodPlus(fx: *Fixture, mode: []const u8, path: []const u8) !void {
    const r = try std.process.run(fx.al(), testing.io, .{ .argv = &.{ "/bin/chmod", mode, path } });
    try testing.expect(r.term == .exited and r.term.exited == 0);
}

fn statusJson(fx: *Fixture, s: Status) !std.json.Value {
    var out: std.Io.Writer.Allocating = .init(fx.al());
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try writeStatus(&w, s);
    return try std.json.parseFromSliceLeaky(std.json.Value, fx.al(), out.written(), .{});
}

fn whyOf(l: Landed, path: []const u8) ?Why {
    for (l.unlanded) |u| if (std.mem.eql(u8, u.path, path)) return u.why;
    return null;
}

/// A git that writes every call it is given to `<root>/git.log`, and -- on
/// its `late_on`th `status --porcelain=v1`, when that is not 0 -- first puts
/// `late.txt` into the tree it is run in: somebody working while Polter
/// decides. Everything else is real git.
fn loggingGit(fx: *Fixture, late_on: u32) !Git {
    const io = testing.io;
    const script = try std.fs.path.join(fx.al(), &.{ fx.root, "logged-git" });
    const body = try std.fmt.allocPrint(fx.al(),
        \\#!/bin/sh
        \\echo "$*" >> "{s}/git.log"
        \\case " $* " in
        \\*" --porcelain=v1 "*)
        \\  n=$(cat "{s}/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "{s}/count"
        \\  if [ "$n" = "{d}" ]; then echo late > "$2/late.txt"; fi;;
        \\esac
        \\exec git "$@"
        \\
    , .{ fx.root, fx.root, fx.root, late_on });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = body });
    try chmodPlus(fx, "+x", script);
    var g = fx.git();
    g.exe = script;
    return g;
}

fn gitLog(fx: *Fixture) ![]const u8 {
    const p = try std.fs.path.join(fx.al(), &.{ fx.root, "git.log" });
    return Io.Dir.cwd().readFileAlloc(testing.io, p, fx.al(), .limited(1 << 20)) catch "";
}

test "worktree: 任务树的目录与分支由群和任务号拼出，beside 与 inside 两种位置都对" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ fx.root, "proj-wt", "polter", "wt-2435" }), e.path);
    try testing.expectEqualStrings("wt/polter/2435", e.branch);
    try testing.expectEqualStrings("polter/wt-2435", e.name);
    try testing.expectEqualStrings("wt/polter/2435", try fx.out(e.path, &.{ "rev-parse", "--abbrev-ref", "HEAD" }));

    const inside = try prepareTask(fx.git(), a, &ledger, .{
        .dir = fx.repo,
        .group = "polter",
        .task = 2436,
        .location = .inside,
    });
    try testing.expect(inside == .tree);
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ fx.repo, inside_dir, "polter", "wt-2436" }),
        inside.tree.entry.path,
    );
    try testing.expectEqualStrings("wt/polter/2436", inside.tree.entry.branch);
    // The excluded directory covers the group level too: git sees nothing.
    try testing.expectEqualStrings("", try fx.out(fx.repo, &.{ "status", "--porcelain" }));
}

test "worktree: groupSegment 对合法群名原样返回，对不合法名走 encodeSegment，目录与分支用同一个结果" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const plain = try groupSegment(aa, "demo-15r");
    try testing.expectEqualStrings("demo-15r", plain);

    const odd = try groupSegment(aa, "My Group/1");
    const enc = try daylog.encodeSegment(aa, "My Group/1");
    try testing.expectEqualStrings(enc, odd);
    try testing.expectEqualStrings("My%20Group%2F1", odd);

    // The directory and the branch are spelled from the same string.
    const path = try taskTreePath(aa, .{ .main = "/r/proj", .common = "/r/proj/.git" }, .beside, "My Group/1", 7);
    const branch = try taskBranch(aa, "My Group/1", 7);
    const name = try taskTreeName(aa, "My Group/1", 7);
    try testing.expect(std.mem.indexOf(u8, path, odd) != null);
    try testing.expect(std.mem.indexOf(u8, branch, odd) != null);
    try testing.expect(std.mem.startsWith(u8, name, odd));
    // Two different odd names stay different (a '_' stand-in would not).
    const other = try groupSegment(aa, "My Group_1");
    try testing.expect(!std.mem.eql(u8, other, odd));
}

test "worktree: groupSegment 转义 Windows 保留设备名（con、nul、com1）和 .lock 结尾" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "con", "%63on" },
        .{ "nul", "%6Eul" },
        .{ "com1", "%63om1" },
        .{ "lpt9", "%6Cpt9" },
        .{ "CON", "%43ON" },
        .{ "x.lock", "x%2Elock" },
        .{ "a..b", "a%2E%2Eb" },
        .{ ".hidden", "%2Ehidden" },
        // Near misses are not device names.
        .{ "console", "console" },
        .{ "com0", "com0" },
        .{ "com10", "com10" },
    };
    for (cases) |c| {
        const got = try groupSegment(a, c[0]);
        testing.expectEqualStrings(c[1], got) catch |err| {
            std.debug.print("groupSegment({s})\n", .{c[0]});
            return err;
        };
    }
    // A literal "%63on" cannot be mistaken for the escaped "con".
    const lit = try groupSegment(a, "%63on");
    try testing.expect(!std.mem.eql(u8, lit, "%63on"));
}

test "worktree: 已有手动分支 wt/<群> 时，建 wt/<群>/<号> 被拒 BranchPrefixTaken 并点名那个分支，没建任何东西" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    // A manual tree whose name happens to be the group's.
    const manual = try prepare(fx.git(), a, &ledger, .{ .dir = fx.repo, .name = "polter" });
    try testing.expect(manual == .tree);
    const before = try fx.out(fx.repo, &.{ "branch", "--list" });

    const p = try prepareTask(fx.git(), a, &ledger, .{ .dir = fx.repo, .group = "polter", .task = 2435 });
    try testing.expect(p == .refused);
    try testing.expectEqualStrings("BranchPrefixTaken", p.refused.code);
    try testing.expect(std.mem.indexOf(u8, p.refused.message, "wt/polter") != null);
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    try testing.expectEqualStrings(before, try fx.out(fx.repo, &.{ "branch", "--list" }));
    // Not a directory under the manual tree either.
    try testing.expect(!exists(testing.io, try std.fs.path.join(a, &.{ manual.tree.entry.path, "wt-2435" })));

    // The other way round: with `wt/other/9` there, a manual `other` cannot be made.
    const t = try prepareTask(fx.git(), a, &ledger, .{ .dir = fx.repo, .group = "other", .task = 9 });
    try testing.expect(t == .tree);
    const m = try prepare(fx.git(), a, &ledger, .{ .dir = fx.repo, .name = "other" });
    try testing.expect(m == .refused);
    try testing.expectEqualStrings("BranchExists", m.refused.code);
    try testing.expect(std.mem.indexOf(u8, m.refused.message, "wt/other/9") != null);
}

test "worktree: 任务树的叶子 wt-<号> 在两个只差大小写的群之间不冲突" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const x = try taskTreeOf(&fx, &ledger, "Polter", 1);
    const y = try taskTreeOf(&fx, &ledger, "polter", 2);
    try testing.expect(!std.mem.eql(u8, x.path, y.path));
    try testing.expectEqual(@as(usize, 2), ledger.entries.items.len);
    try testing.expectEqualStrings("wt-1", std.fs.path.basename(x.path));
    try testing.expectEqualStrings("wt-2", std.fs.path.basename(y.path));
}

test "worktree: 任务建树时账本 task 就写了，不靠 task_assign" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try testing.expectEqual(@as(?u64, 2435), e.task);
    try testing.expectEqualStrings("polter", e.group);
    try testing.expectEqual(Entry.Kind.task, e.kind);
    // In the ledger as it is now, and as it is after a restart.
    try testing.expectEqual(@as(?usize, 0), ledger.taskTree(2435));
    var again = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer again.deinit();
    again.load(testing.io);
    try testing.expectEqual(@as(?usize, 0), again.taskTree(2435));
    try testing.expectEqualStrings("polter", again.entries.items[0].group);
    // By task number, or by the name with the slash in it: the same tree.
    try testing.expectEqual(Ledger.Lookup{ .one = 0 }, again.select("", "", 2435));
    try testing.expectEqual(Ledger.Lookup{ .one = 0 }, again.select("polter/wt-2435", "", 0));
    try testing.expectEqual(Ledger.Lookup.none, again.select("", "", 9));

    // Asked for again, the same tree.
    const second = try prepareTask(fx.git(), fx.al(), &again, .{ .dir = fx.repo, .group = "polter", .task = 2435 });
    try testing.expect(second == .tree and second.tree.reused);
}

test "worktree: 旧账本行读出来是 manual 且 group 为空" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const file = try fx.ledgerFile();
    try writeReplacing(testing.allocator, testing.io, file,
        \\{"version":1,"trees":[{"name":"w1","repo":"/r/proj","path":"/r/proj-wt/w1","branch":"wt/w1","base":"abc","created_ms":5,"by":3,"terminal":null,"task":42}]}
    );
    var ledger = try Ledger.init(testing.allocator, file);
    defer ledger.deinit();
    ledger.load(testing.io);
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    const e = ledger.entries.items[0];
    try testing.expectEqual(Entry.Kind.manual, e.kind);
    try testing.expectEqualStrings("", e.group);
    try testing.expectEqual(@as(?u64, 42), e.task);
    // A manual tree is not "the tree made for" its task.
    try testing.expectEqual(@as(?usize, null), ledger.taskTree(42));
    try testing.expectEqual(Ledger.Lookup{ .one = 0 }, ledger.select("", "", 42));
}

test "worktree: 补丁已在主线提交 → landed，closeout 删树" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);
    // The worker did not commit; the supervisor applied the patch on main.
    try landOnMain(&fx);

    const s = try status(fx.git(), fx.al(), e);
    // The old fields: this is exactly the case they cannot tell apart.
    try testing.expectEqual(@as(?bool, true), s.merged);
    try testing.expect(s.dirty.? > 0);

    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(l.landed);
    try testing.expectEqual(@as(usize, 2), l.checked);
    try testing.expectEqual(@as(usize, 0), l.unlanded_count);

    const c = try closeout(fx.git(), fx.al(), &ledger, 2435, .{ .mode = .closed });
    try testing.expectEqual(Outcome.removed, c.outcome);
    try testing.expect(!exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    const br = try fx.git().run(fx.al(), fx.repo, &.{ "rev-parse", "--verify", "--quiet", "refs/heads/wt/polter/2435" });
    try testing.expect(!br.ok);
}

test "worktree: 树里多一个未跟踪的源文件 → 不 landed，保留，unlanded 点名该路径（extra）" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);
    try fx.write(e.path, "c.zig", "pub const x = 1;\n");
    try landOnMain(&fx);

    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(!l.landed);
    try testing.expectEqual(@as(usize, 1), l.unlanded_count);
    try testing.expectEqual(@as(?Why, .extra), whyOf(l, "c.zig"));

    const c = try closeout(fx.git(), fx.al(), &ledger, 2435, .{ .mode = .closed });
    try testing.expectEqual(Outcome.kept_unlanded, c.outcome);
    try testing.expect(exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    try testing.expect(std.mem.indexOf(u8, c.note, "c.zig (extra)") != null);
}

test "worktree: 主线后来又改过同一个文件 → 不 landed，保留，unlanded 点名该路径（differs）" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);
    try landOnMain(&fx);
    // Main moved on: somebody changed a.txt again.
    try fx.write(fx.repo, "a.txt", "three\n");
    try fx.must(fx.repo, &.{ "commit", "-q", "-am", "later" });

    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(!l.landed);
    try testing.expectEqual(@as(usize, 1), l.unlanded_count);
    try testing.expectEqual(@as(?Why, .differs), whyOf(l, "a.txt"));

    const c = try closeout(fx.git(), fx.al(), &ledger, 2435, .{ .mode = .closed });
    try testing.expectEqual(Outcome.kept_unlanded, c.outcome);
    try testing.expect(exists(testing.io, e.path));
    try testing.expect(std.mem.indexOf(u8, c.note, "a.txt (differs)") != null);
}

test "worktree: 树里删了文件且主线也没有 → landed；树里删了而主线还有 → 不 landed（main_still_has）" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try Io.Dir.cwd().deleteFile(testing.io, try std.fs.path.join(fx.al(), &.{ e.path, "a.txt" }));

    // Main still has it.
    const still = try landed(fx.git(), fx.al(), e);
    try testing.expect(!still.landed);
    try testing.expectEqual(@as(?Why, .main_still_has), whyOf(still, "a.txt"));

    // Main deleted it too.
    try fx.must(fx.repo, &.{ "rm", "-q", "a.txt" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "drop a" });
    const gone = try landed(fx.git(), fx.al(), e);
    try testing.expect(gone.landed);
    try testing.expectEqual(@as(usize, 1), gone.checked);
}

test "worktree: 只有可执行位不同 → 不 landed（mode）" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try chmodPlus(&fx, "+x", try std.fs.path.join(fx.al(), &.{ e.path, "a.txt" }));
    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(!l.landed);
    try testing.expectEqual(@as(?Why, .mode), whyOf(l, "a.txt"));
}

test "worktree: 被 .gitignore 的构建产物不算改动" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    try fx.write(fx.repo, ".gitignore", "zig-out/\n.zig-cache/\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    for ([_][]const u8{ "zig-out", ".zig-cache" }) |d| {
        const dir = try std.fs.path.join(fx.al(), &.{ e.path, d });
        try Io.Dir.cwd().createDirPath(testing.io, dir);
        try fx.write(dir, "big", "x");
    }
    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(l.landed);
    try testing.expectEqual(@as(usize, 0), l.checked);
}

test "worktree: 路径含空格、中文、引号时判据仍正确" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const names = [_][]const u8{ "sp ace.txt", "中文.txt", "q\"uote.txt" };
    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    for (names) |n| {
        try fx.write(e.path, n, "same\n");
        try fx.write(fx.repo, n, "same\n");
    }
    for (names) |n| try fx.must(fx.repo, &.{ "add", "--", n });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "names" });

    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(l.landed);
    try testing.expectEqual(@as(usize, 3), l.checked);

    // And one of them different on main is named, whole.
    try fx.write(fx.repo, "中文.txt", "other\n");
    try fx.must(fx.repo, &.{ "commit", "-q", "-am", "diverge" });
    const d = try landed(fx.git(), fx.al(), e);
    try testing.expect(!d.landed);
    try testing.expectEqual(@as(?Why, .differs), whyOf(d, "中文.txt"));
    try testing.expectEqual(@as(usize, 1), d.unlanded_count);
}

test "worktree: 重命名按\"删旧+加新\"处理" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try fx.must(e.path, &.{ "mv", "a.txt", "c.txt" });

    // Main has the new name but still the old one: the deletion is not there.
    try fx.write(fx.repo, "c.txt", "one\n");
    try fx.must(fx.repo, &.{ "add", "c.txt" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "copy" });
    const half = try landed(fx.git(), fx.al(), e);
    try testing.expect(!half.landed);
    try testing.expectEqual(@as(?Why, .main_still_has), whyOf(half, "a.txt"));
    try testing.expectEqual(@as(usize, 2), half.checked);

    try fx.must(fx.repo, &.{ "rm", "-q", "a.txt" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "rename" });
    const whole = try landed(fx.git(), fx.al(), e);
    try testing.expect(whole.landed);
}

test "worktree: ahead > 0（worker 真提交了）→ 不 landed，即使路径集合为空" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try fx.write(e.path, "b.txt", "new\n");
    try fx.must(e.path, &.{ "add", "b.txt" });
    try fx.must(e.path, &.{ "commit", "-q", "-m", "work" });
    // Clean: nothing for the path list to say.
    try testing.expectEqualStrings("", try fx.out(e.path, &.{ "status", "--porcelain" }));

    const l = try landed(fx.git(), fx.al(), e);
    try testing.expectEqual(@as(usize, 0), l.unlanded_count);
    try testing.expect(!l.landed);
    try testing.expectEqual(@as(?usize, 1), l.ahead);
    try testing.expect(std.mem.indexOf(u8, l.reason.?, "1 commit") != null);

    // Taking it down by hand is refused for the same reason, and does nothing.
    const r = try removeSel(fx.git(), fx.al(), &ledger, .{ .task = 2435 });
    try testing.expect(r == .refused);
    try testing.expectEqualStrings("WorktreeNotMerged", r.refused.code);
    try testing.expect(exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    const c = try closeout(fx.git(), fx.al(), &ledger, 2435, .{ .mode = .cancelled });
    try testing.expectEqual(Outcome.kept_ahead, c.outcome);
    try testing.expect(exists(testing.io, e.path));
}

test "worktree: 在游离 HEAD 上提交（分支没动，工作区干净）→ 不 landed、不 merged、closeout 不删树" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try fx.must(e.path, &.{ "checkout", "-q", "--detach" });
    try fx.write(e.path, "b.txt", "new\n");
    try fx.must(e.path, &.{ "add", "b.txt" });
    try fx.must(e.path, &.{ "commit", "-q", "-m", "detached work" });
    try testing.expectEqualStrings("", try fx.out(e.path, &.{ "status", "--porcelain" }));
    // The branch the ledger names has not moved.
    const br = try fx.out(fx.repo, &.{ "rev-list", "--count", "HEAD..wt/polter/2435" });
    try testing.expectEqualStrings("0", br);

    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(!l.landed);
    try testing.expectEqual(@as(?usize, 1), l.ahead);
    const s = try status(fx.git(), fx.al(), e);
    try testing.expectEqual(@as(?bool, false), s.merged);
    try testing.expectEqual(@as(?usize, 1), s.ahead);

    const c = try closeout(fx.git(), fx.al(), &ledger, 2435, .{ .mode = .closed });
    try testing.expectEqual(Outcome.kept_ahead, c.outcome);
    try testing.expect(exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

test "worktree: 被 git 忽略、不在构建产物名单里的文件，随树删除前写进回执" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    try fx.write(fx.repo, ".gitignore", ".zig-cache/\n*.local.json\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);
    try landOnMain(&fx);
    try fx.write(e.path, "secrets.local.json", "{}\n");
    const cache = try std.fs.path.join(a, &.{ e.path, ".zig-cache" });
    try Io.Dir.cwd().createDirPath(testing.io, cache);
    try fx.write(cache, "o", "x");

    const c = try closeout(fx.git(), a, &ledger, 2435, .{ .mode = .closed });
    try testing.expectEqual(Outcome.removed, c.outcome);
    const extra = c.landed.?.ignored_extra;
    try testing.expectEqual(@as(usize, 1), extra.len);
    try testing.expectEqualStrings("secrets.local.json", extra[0]);
    try testing.expect(std.mem.indexOf(u8, c.note, "secrets.local.json") != null);
}

test "worktree: 树的 .git 没了（inside 布局下 git 会往上找到主仓库）→ 不清缓存、不当成已落地" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    try fx.write(fx.repo, ".gitignore", ".zig-cache/\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });

    const p = try prepareTask(fx.git(), a, &ledger, .{ .dir = fx.repo, .group = "polter", .task = 2435, .location = .inside });
    try testing.expect(p == .tree);
    const e = p.tree.entry;
    const cache = try std.fs.path.join(a, &.{ e.path, ".zig-cache" });
    try Io.Dir.cwd().createDirPath(testing.io, cache);
    try fx.write(cache, "o", "x");
    try Io.Dir.cwd().deleteFile(testing.io, try std.fs.path.join(a, &.{ e.path, ".git" }));

    const direct = try cleanCache(fx.git(), a, e, false);
    try testing.expectEqual(@as(usize, 0), direct.cleaned.len);
    try testing.expect(exists(testing.io, cache));

    const c = try closeout(fx.git(), a, &ledger, 2435, .{ .mode = .closed });
    try testing.expectEqual(Outcome.kept_unknown, c.outcome);
    try testing.expect(c.cache == null);
    try testing.expect(exists(testing.io, cache));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

test "worktree: forgetGone 只忘掉 job 删的那一行：同名但 path 或 created_ms 不同的新行留着" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();
    var ctx: u8 = 0;

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);
    try landOnMain(&fx);
    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .closeout = .{
        .task = 2435,
        .in = .{ .mode = .closed },
    } }, ledger.entries.items, noteDone, &ctx);
    defer job.destroy();
    try runJob(job);
    try testing.expectEqual(Outcome.removed, job.result.?.closeout.outcome);

    // While the job ran, somebody made another row under the same name.
    ledger.entries.items[0].created_ms += 1;
    try testing.expect(!forgetGone(testing.io, &ledger, job.result.?));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    ledger.entries.items[0].created_ms -= 1;
    try testing.expect(forgetGone(testing.io, &ledger, job.result.?));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
}

test "worktree: 路径数超过上限 → 不 landed（too_many）" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    const dir = try std.fs.path.join(fx.al(), &.{ e.path, "many" });
    try Io.Dir.cwd().createDirPath(testing.io, dir);
    var i: usize = 0;
    while (i < max_landed_paths + 1) : (i += 1) {
        var buf: [32]u8 = undefined;
        try fx.write(dir, try std.fmt.bufPrint(&buf, "f{d}.txt", .{i}), "x");
    }
    const l = try landed(fx.git(), fx.al(), e);
    try testing.expect(!l.landed);
    try testing.expectEqual(max_landed_paths + 1, l.checked);
    try testing.expect(std.mem.startsWith(u8, l.reason.?, "too_many"));
}

test "worktree: 删除前复核——判据与删除之间树里又多了一个文件 → 不删" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);
    try landOnMain(&fx);

    // The second `status --porcelain=v1` -- the re-check -- finds a file the
    // first one did not.
    const git = try loggingGit(&fx, 2);
    const r = try removeSel(git, fx.al(), &ledger, .{ .task = 2435 });
    try testing.expect(r == .refused);
    try testing.expectEqualStrings("WorktreeNotLanded", r.refused.code);
    try testing.expect(std.mem.indexOf(u8, r.refused.message, "late.txt") != null);
    try testing.expect(exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    try testing.expect(std.mem.indexOf(u8, try gitLog(&fx), "worktree remove") == null);
}

test "worktree_remove: 未落地 → WorktreeNotLanded 且命令记录里没有 --force；已落地 → 恰有一次 --force 且在复核之后" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    const a = fx.al();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);

    // Not landed: refused, and no `--force` was ever asked of git.
    const git = try loggingGit(&fx, 0);
    const no = try removeSel(git, a, &ledger, .{ .task = 2435 });
    try testing.expect(no == .refused);
    try testing.expectEqualStrings("WorktreeNotLanded", no.refused.code);
    try testing.expect(std.mem.indexOf(u8, try gitLog(&fx), "--force") == null);
    try testing.expect(std.mem.indexOf(u8, try gitLog(&fx), "worktree remove") == null);
    try testing.expect(exists(testing.io, e.path));

    // Landed: exactly one `--force`, and it comes after the last look.
    try landOnMain(&fx);
    const yes = try removeSel(git, a, &ledger, .{ .task = 2435 });
    try testing.expect(yes == .removed);
    const log_text = try gitLog(&fx);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, log_text, "--force"));
    const force_at = std.mem.indexOf(u8, log_text, "worktree remove --force").?;
    const last_look = std.mem.lastIndexOf(u8, log_text, "--porcelain=v1").?;
    try testing.expect(last_look < force_at);
    // Two looks since it landed (the check and the re-check), plus the one
    // before it was landed.
    try testing.expect(std.mem.count(u8, log_text, "--porcelain=v1") >= 3);
}

test "rpc: worktree_status 带 kind/group/group_now/label_stale，改群名后 label_stale 为真且目录没动" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    var s = try status(fx.git(), fx.al(), e);

    s.group_now = "polter";
    const same = try statusJson(&fx, s);
    try testing.expectEqualStrings("task", same.object.get("kind").?.string);
    try testing.expectEqualStrings("polter", same.object.get("group").?.string);
    try testing.expectEqualStrings("polter", same.object.get("group_now").?.string);
    try testing.expect(!same.object.get("label_stale").?.bool);
    try testing.expectEqual(@as(i64, 2435), same.object.get("task").?.integer);

    // The group was renamed. Nothing is moved: the directory, the branch and
    // the ledger's group are what they were, and only the label is stale.
    s.group_now = "renamed";
    const stale = try statusJson(&fx, s);
    try testing.expect(stale.object.get("label_stale").?.bool);
    try testing.expectEqualStrings("polter", stale.object.get("group").?.string);
    try testing.expectEqualStrings("renamed", stale.object.get("group_now").?.string);
    try testing.expect(exists(testing.io, e.path));
    try testing.expectEqualStrings("wt/polter/2435", try fx.out(e.path, &.{ "rev-parse", "--abbrev-ref", "HEAD" }));

    // A manual tree has neither a group nor a stale label.
    const m = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    var ms = try status(fx.git(), fx.al(), m.tree.entry);
    ms.group_now = "anything";
    const mj = try statusJson(&fx, ms);
    try testing.expectEqualStrings("manual", mj.object.get("kind").?.string);
    try testing.expect(!mj.object.get("label_stale").?.bool);
}

test "rpc: worktree_status 带 landed/unlanded 与旧的 merged/dirty/ahead；在 worker 不提交的夹具里 merged 恒 true，而 landed 随内容变" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);

    // Work not on main.
    const before = try statusJson(&fx, try statusFull(fx.git(), fx.al(), e));
    try testing.expect(before.object.get("merged").?.bool);
    try testing.expectEqual(@as(i64, 2), before.object.get("dirty").?.integer);
    try testing.expectEqual(@as(i64, 0), before.object.get("ahead").?.integer);
    try testing.expect(!before.object.get("landed").?.bool);
    try testing.expectEqual(@as(i64, 2), before.object.get("unlanded_count").?.integer);
    try testing.expectEqual(@as(i64, 2), before.object.get("landed_checked").?.integer);
    const listed = before.object.get("unlanded").?.array;
    try testing.expectEqual(@as(usize, 2), listed.items.len);
    try testing.expectEqualStrings("differs", listed.items[0].object.get("why").?.string);

    // The same work on main: `merged` and `dirty` do not move, `landed` does.
    try landOnMain(&fx);
    const after = try statusJson(&fx, try statusFull(fx.git(), fx.al(), e));
    try testing.expect(after.object.get("merged").?.bool);
    try testing.expectEqual(@as(i64, 2), after.object.get("dirty").?.integer);
    try testing.expect(after.object.get("landed").?.bool);
    try testing.expectEqual(@as(usize, 0), after.object.get("unlanded").?.array.items.len);
}

/// One row of the closeout table, built from nothing, for both modes.
const Row = enum { free, empty, standing, leased, building, unlanded, ahead, unknown, gone };

fn closeoutRow(row: Row, mode: CloseMode) !void {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    try fx.write(fx.repo, ".gitignore", ".zig-cache/\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    const cache = try std.fs.path.join(a, &.{ e.path, ".zig-cache" });
    try Io.Dir.cwd().createDirPath(testing.io, cache);
    try fx.write(cache, "o", "x");

    switch (row) {
        .free, .standing, .leased, .building => {
            try workerWork(&fx, e.path);
            try landOnMain(&fx);
        },
        // Nothing was done in it: nothing in it to lose.
        .empty => {},
        .unlanded => try workerWork(&fx, e.path),
        .ahead => {
            try fx.write(e.path, "b.txt", "n\n");
            try fx.must(e.path, &.{ "add", "b.txt" });
            try fx.must(e.path, &.{ "commit", "-q", "-m", "work" });
        },
        .unknown => try Io.Dir.cwd().deleteFile(testing.io, try std.fs.path.join(a, &.{ e.path, ".git" })),
        .gone => try Io.Dir.cwd().deleteTree(testing.io, e.path),
    }

    const standing = [_][]const u8{"dev-1 (0x00ab)"};
    const building = [_][]const u8{"builder"};
    const c = try closeout(fx.git(), a, &ledger, 2435, .{
        .mode = mode,
        .standing = if (row == .standing) &standing else &.{},
        .building = if (row == .building) &building else &.{},
        .lease = if (row == .leased) .{
            .alias = "tester",
            .terminal = 7,
            .purpose = .build,
            .since_ms = 0,
            .expires_ms = 1,
        } else null,
    });
    const word = if (mode == .closed) "closed" else "cancelled";
    try testing.expect(std.mem.indexOf(u8, c.note, word) != null);

    switch (row) {
        .free, .empty => {
            try testing.expectEqual(Outcome.removed, c.outcome);
            try testing.expect(!exists(testing.io, e.path));
            try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
            try testing.expect(c.cache == null);
        },
        .gone => {
            try testing.expectEqual(Outcome.forgotten, c.outcome);
            try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
        },
        else => {
            // Every other row keeps the tree and its ledger row.
            try testing.expect(exists(testing.io, e.path));
            try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
            const cleared = !exists(testing.io, cache);
            switch (row) {
                .standing => {
                    try testing.expectEqual(Outcome.kept_standing, c.outcome);
                    try testing.expect(std.mem.indexOf(u8, c.note, "dev-1 (0x00ab)") != null);
                    try testing.expect(cleared);
                },
                .leased => {
                    try testing.expectEqual(Outcome.kept_busy, c.outcome);
                    try testing.expect(c.cache.?.busy);
                    try testing.expect(!cleared);
                    try testing.expect(std.mem.indexOf(u8, c.note, "tester holds its build lease") != null);
                    try testing.expect(std.mem.indexOf(u8, c.note, "CacheBusy") != null);
                },
                .building => {
                    // A build running in it counts as a lease would: kept,
                    // named, and its build output is not touched.
                    try testing.expectEqual(Outcome.kept_busy, c.outcome);
                    try testing.expect(c.cache.?.busy);
                    try testing.expect(!cleared);
                    try testing.expect(std.mem.indexOf(u8, c.note, "builder is building in it") != null);
                    try testing.expect(std.mem.indexOf(u8, c.note, "CacheBusy") != null);
                },
                .unlanded => {
                    try testing.expectEqual(Outcome.kept_unlanded, c.outcome);
                    try testing.expect(std.mem.indexOf(u8, c.note, "a.txt (differs)") != null);
                    try testing.expect(cleared);
                },
                .ahead => {
                    try testing.expectEqual(Outcome.kept_ahead, c.outcome);
                    try testing.expect(std.mem.indexOf(u8, c.note, "wt/polter/2435") != null);
                    try testing.expect(std.mem.indexOf(u8, c.note, "1 commit") != null);
                    try testing.expect(cleared);
                },
                .unknown => try testing.expectEqual(Outcome.kept_unknown, c.outcome),
                else => unreachable,
            }
        },
    }
}

test "worktree: closeout 的收尾表各一行" {
    inline for (.{ CloseMode.closed, CloseMode.cancelled }) |mode| {
        inline for (@typeInfo(Row).@"enum".fields) |f| {
            closeoutRow(@enumFromInt(f.value), mode) catch |err| {
                std.debug.print("closeout row {s} ({t})\n", .{ f.name, mode });
                return err;
            };
        }
    }
}

test "worktree: 保留的树也清缓存；被忽略但不在名单里的目录不动；未被 git 忽略的同名目录不动" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    try fx.write(fx.repo, ".gitignore", ".zig-cache/\nother-cache/\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    // `zig-out` is on the list but git does not ignore it here; `other-cache`
    // is ignored but is not on the list.
    for ([_][]const u8{ ".zig-cache", "zig-out", "other-cache" }) |d| {
        const dir = try std.fs.path.join(a, &.{ e.path, d });
        try Io.Dir.cwd().createDirPath(testing.io, dir);
        try fx.write(dir, "f", "x");
    }
    const r = try cleanCache(fx.git(), a, e, false);
    try testing.expect(!r.busy);
    try testing.expectEqual(@as(usize, 1), r.cleaned.len);
    try testing.expectEqualStrings(".zig-cache", r.cleaned[0]);
    try testing.expectEqual(@as(usize, 1), r.kept.len);
    try testing.expectEqualStrings("zig-out", r.kept[0]);
    try testing.expect(!exists(testing.io, try std.fs.path.join(a, &.{ e.path, ".zig-cache" })));
    try testing.expect(exists(testing.io, try std.fs.path.join(a, &.{ e.path, "zig-out", "f" })));
    try testing.expect(exists(testing.io, try std.fs.path.join(a, &.{ e.path, "other-cache", "f" })));
    // The tree itself is untouched.
    try testing.expect(exists(testing.io, try std.fs.path.join(a, &.{ e.path, "a.txt" })));
}

test "worktree: 有租约时清缓存被拒 CacheBusy，松开后再调一次就清（生产里没有自动补做）" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    try fx.write(fx.repo, ".gitignore", ".zig-cache/\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });
    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    const cache = try std.fs.path.join(a, &.{ e.path, ".zig-cache" });
    try Io.Dir.cwd().createDirPath(testing.io, cache);
    try fx.write(cache, "o", "x");

    var leases = Leases.init(testing.allocator);
    defer leases.deinit();
    const got = try leases.acquire(2435, "tester", 7, .build, 0);
    try testing.expect(got == .granted);

    const busy = try cleanCache(fx.git(), a, e, leases.status(2435) != null);
    try testing.expect(busy.busy);
    try testing.expectEqual(@as(usize, 0), busy.cleaned.len);
    try testing.expect(exists(testing.io, cache));

    const rel = try leases.release(a, 2435, 7, false, 10);
    try testing.expect(rel == .released);
    const done = try cleanCache(fx.git(), a, e, leases.status(2435) != null);
    try testing.expect(!done.busy);
    try testing.expectEqual(@as(usize, 1), done.cleaned.len);
    try testing.expect(!exists(testing.io, cache));
}

test "worktree: 清缓存失败写进事件并出现在回执里，不吞" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    try fx.write(fx.repo, ".gitignore", ".zig-cache/\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });
    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);

    // A directory inside the cache that cannot be written to cannot be
    // emptied, so the cache cannot be removed.
    const locked = try std.fs.path.join(a, &.{ e.path, ".zig-cache", "locked" });
    try Io.Dir.cwd().createDirPath(testing.io, locked);
    try fx.write(locked, "f", "x");
    try chmodPlus(&fx, "555", locked);
    defer chmodPlus(&fx, "755", locked) catch {};

    const c = try closeout(fx.git(), a, &ledger, 2435, .{ .mode = .closed });
    try testing.expectEqual(Outcome.kept_unlanded, c.outcome);
    try testing.expectEqual(@as(usize, 1), c.cache.?.failed.len);
    try testing.expectEqualStrings(".zig-cache", c.cache.?.failed[0].path);
    try testing.expectEqual(@as(usize, 0), c.cache.?.cleaned.len);
    try testing.expect(std.mem.indexOf(u8, c.note, "Could not clear .zig-cache") != null);
}

test "worktree: select by task finds the tree made for the task, not one merely tied to it" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const manual = try prepare(fx.git(), fx.al(), &ledger, .{ .dir = fx.repo, .name = "w1" });
    try testing.expect(manual == .tree);
    ledger.entries.items[0].task = 5;
    _ = try taskTreeOf(&fx, &ledger, "polter", 5);
    try testing.expectEqual(@as(usize, 2), ledger.entries.items.len);
    try testing.expectEqual(Ledger.Lookup{ .one = 1 }, ledger.select("", "", 5));
    try testing.expectEqual(Ledger.Lookup{ .one = 1 }, ledger.select("polter/wt-5", "", 0));
    // And remove by task takes that one down: the other is untouched.
    const r = try removeSel(fx.git(), fx.al(), &ledger, .{ .task = 5 });
    try testing.expect(r == .removed);
    try testing.expectEqualStrings("w1", ledger.entries.items[0].name);
}

test "lease: acquire 独占；LeaseHeld 带持有者与 since；同一持有者再 acquire = 续期" {
    var leases = Leases.init(testing.allocator);
    defer leases.deinit();

    const first = try leases.acquire(7, "dev-1", 0x11, .edit, 1_000);
    try testing.expect(first == .granted);
    try testing.expect(!first.granted.renewed);
    try testing.expectEqual(@as(i64, 1_000 + default_lease_ttl_ms), first.granted.view.expires_ms);

    // Someone else is refused, and told who and since when.
    const other = try leases.acquire(7, "tester", 0x22, .build, 2_000);
    try testing.expect(other == .held);
    try testing.expectEqualStrings("dev-1", other.held.alias);
    try testing.expectEqual(@as(u64, 0x11), other.held.terminal);
    try testing.expectEqual(@as(i64, 1_000), other.held.since_ms);
    try testing.expectEqual(Purpose.edit, other.held.purpose);

    // The holder asking again renews: same since, later expiry, new purpose.
    const again = try leases.acquire(7, "dev-1", 0x11, .@"test", 5_000);
    try testing.expect(again == .granted and again.granted.renewed);
    try testing.expectEqual(@as(i64, 1_000), again.granted.view.since_ms);
    try testing.expectEqual(@as(i64, 5_000 + default_lease_ttl_ms), again.granted.view.expires_ms);
    try testing.expectEqual(Purpose.@"test", again.granted.view.purpose);

    // Another task's tree is its own lease.
    const elsewhere = try leases.acquire(8, "tester", 0x22, .build, 2_000);
    try testing.expect(elsewhere == .granted);
    try testing.expectEqual(@as(?LeaseView, null), leases.status(9));

    // Not the holder: refused, and still held.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const no = try leases.release(arena.allocator(), 7, 0x22, false, 6_000);
    try testing.expect(no == .not_holder);
    try testing.expect(leases.status(7) != null);
}

test "lease: 持有者终端关了 / agent idle 且无后台 / 超时 / 总管 release，四种松开各写一条带原因的事件" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var leases = Leases.init(testing.allocator);
    defer leases.deinit();
    leases.ttl_ms = 100;

    // Task 1: its terminal closes. 2: its turn ends. 3: it times out.
    // 4: the supervisor takes it back. 5: its turn ended but a build of its
    // own is still running -- it must be kept, until it times out too.
    _ = try leases.acquire(1, "a", 11, .build, 0);
    _ = try leases.acquire(2, "b", 12, .build, 0);
    _ = try leases.acquire(3, "c", 13, .build, 0);
    _ = try leases.acquire(4, "d", 14, .edit, 0);
    _ = try leases.acquire(5, "e", 15, .build, 0);

    // t=50: nobody has timed out. 11 is not listed (gone), 12 is idle, 15 is
    // idle-with-a-background-job, 13 and 14 are working.
    const first = try leases.sweep(a, 50, &.{
        .{ .terminal = 12, .state = .idle },
        .{ .terminal = 13, .state = .busy },
        .{ .terminal = 14, .state = .busy },
        .{ .terminal = 15, .state = .waiting_on_background },
    });
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqual(@as(u64, 1), first[0].task);
    try testing.expectEqual(LeaseWhy.terminal_closed, first[0].why);
    try testing.expectEqualStrings("a", first[0].alias);
    try testing.expectEqual(@as(u64, 2), first[1].task);
    try testing.expectEqual(LeaseWhy.idle, first[1].why);
    try testing.expectEqual(@as(i64, 50), first[1].held_ms);
    // The counter-example: waiting on a background job is not idle.
    try testing.expect(leases.status(5) != null);

    // The supervisor takes 4 back.
    const sup = try leases.release(a, 4, 999, true, 60);
    try testing.expect(sup == .released);
    try testing.expectEqual(LeaseWhy.supervisor, sup.released.why);
    try testing.expectEqualStrings("d", sup.released.alias);

    // t=150: 13 and 15 are past their time.
    const late = try leases.sweep(a, 150, &.{
        .{ .terminal = 13, .state = .busy },
        .{ .terminal = 15, .state = .waiting_on_background },
    });
    try testing.expectEqual(@as(usize, 2), late.len);
    try testing.expectEqual(LeaseWhy.expired, late[0].why);
    try testing.expectEqual(LeaseWhy.expired, late[1].why);
    try testing.expectEqual(@as(usize, 0), leases.held.items.len);
}

test "lease: 重启后租约不恢复，旧持有者的 release 得到 NotHeld" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var before = Leases.init(testing.allocator);
    _ = try before.acquire(7, "dev-1", 0x11, .edit, 0);
    try testing.expect(before.status(7) != null);
    before.deinit();

    // The process restarted: a fresh registry holds nothing, and the old
    // holder letting go is told so rather than silently believed.
    var after = Leases.init(testing.allocator);
    defer after.deinit();
    try testing.expectEqual(@as(?LeaseView, null), after.status(7));
    const r = try after.release(a, 7, 0x11, false, 10);
    try testing.expect(r == .not_held);
    // And the tree is free for whoever asks next.
    const fresh = try after.acquire(7, "tester", 0x22, .build, 20);
    try testing.expect(fresh == .granted and !fresh.granted.renewed);
}

test "worktree: 取消任务时树里没有任何改动 → 删；有未落地的改动 → 留" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try testing.expect(exists(testing.io, e.path));
    const c = try closeout(fx.git(), fx.al(), &ledger, 2435, .{ .mode = .cancelled });
    try testing.expectEqual(Outcome.removed, c.outcome);
    try testing.expect(!exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    try testing.expect(std.mem.startsWith(u8, c.note, "Task 2435 cancelled."));

    // The same task cancelled with work in the tree that is nowhere else.
    const again = try taskTreeOf(&fx, &ledger, "polter", 2436);
    try workerWork(&fx, again.path);
    const kept = try closeout(fx.git(), fx.al(), &ledger, 2436, .{ .mode = .cancelled });
    try testing.expectEqual(Outcome.kept_unlanded, kept.outcome);
    try testing.expect(exists(testing.io, again.path));
}

/// Start `job` and wait for its thread, as the app does without waiting.
fn runJob(job: *Job) !void {
    try job.start();
    var waited: usize = 0;
    while (!job.finished.load(.acquire)) : (waited += 1) {
        try testing.expect(waited < 3000);
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
    job.join();
}

fn noteDone(_: *anyopaque, _: *Job) void {}

test "worktree: Job 在线程里建任务树，commit 才落账；再问是同一棵" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();
    var ctx: u8 = 0;

    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .task = .{
        .dir = fx.repo,
        .group = "polter",
        .task = 2472,
        .by = 9,
    } }, ledger.entries.items, noteDone, &ctx);
    defer job.destroy();
    try runJob(job);

    // Made, and not yet written down: the ledger is the caller's to write.
    const made = job.result.?.prepared;
    try testing.expect(made == .tree);
    try testing.expect(!made.tree.reused);
    try testing.expect(exists(testing.io, made.tree.entry.path));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    try testing.expectEqualStrings("wt/polter/2472", made.tree.entry.branch);
    try testing.expectEqual(Entry.Kind.task, made.tree.entry.kind);

    _ = try commit(testing.io, &ledger, made);
    try testing.expect(ledger.taskTree(2472) != null);
    // What `terminal_list` says of a terminal standing in it: whose tree.
    try testing.expectEqual(@as(?u64, 2472), ledger.tagAt(made.tree.entry.path).?.task);

    // Asked again with the ledger as it is now: found, not made.
    const second = try Job.create(std.heap.smp_allocator, fx.git(), .{ .task = .{
        .dir = fx.repo,
        .group = "polter",
        .task = 2472,
    } }, ledger.entries.items, noteDone, &ctx);
    defer second.destroy();
    try runJob(second);
    try testing.expect(second.result.?.prepared.tree.reused);
}

test "worktree: 同一任务的第二个请求拿着过期账本来：分支已检出在树里 → 当作复用，不拒绝" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var first_ledger = try Ledger.init(testing.allocator, null);
    defer first_ledger.deinit();
    var stale = try Ledger.init(testing.allocator, null);
    defer stale.deinit();

    const first = try taskTreeOf(&fx, &first_ledger, "polter", 2435);
    // The racer's copy of the ledger was taken before the first one wrote.
    const second = try prepareTask(fx.git(), a, &stale, .{ .dir = fx.repo, .group = "polter", .task = 2435 });
    try testing.expect(second == .tree);
    try testing.expectEqualStrings(first.path, second.tree.entry.path);
    try testing.expectEqualStrings("wt/polter/2435", second.tree.entry.branch);
    try testing.expectEqual(@as(?u64, 2435), second.tree.entry.task);
    try testing.expect(exists(testing.io, first.path));
}

test "worktree: 分支存在但没有树检出它 → BranchExists，文案不叫人删分支" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    try fx.must(fx.repo, &.{ "branch", "wt/polter/2435" });
    const p = try prepareTask(fx.git(), a, &ledger, .{ .dir = fx.repo, .group = "polter", .task = 2435 });
    try testing.expect(p == .refused);
    try testing.expectEqualStrings("BranchExists", p.refused.code);
    try testing.expect(std.ascii.indexOfIgnoreCase(p.refused.message, "delete") == null);
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
}

test "worktree: 同一任务已有建树 job 在跑 → taskLeader 认出它，后来的请求排成 follower，job 收完一并取走" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;
    var a_req: u8 = 0;
    var b_req: u8 = 0;

    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .task = .{
        .dir = fx.repo,
        .group = "polter",
        .task = 2435,
    } }, ledger.entries.items, noteDone, &ctx);
    defer job.destroy();
    var waits: std.ArrayList(Wait) = .empty;
    defer waits.deinit(testing.allocator);
    try waits.append(testing.allocator, .{ .job = job, .held = &a_req });

    try testing.expectEqual(@as(?usize, 0), taskLeader(waits.items, 2435));
    try testing.expectEqual(@as(?usize, null), taskLeader(waits.items, 2436));
    try testing.expectEqual(@as(?usize, 0), waitFor(waits.items, &a_req));
    try testing.expectEqual(@as(?usize, null), waitFor(waits.items, &b_req));

    var followers: std.ArrayList(Follower) = .empty;
    defer followers.deinit(testing.allocator);
    try followers.append(testing.allocator, .{ .task = 2435, .held = &b_req });
    try followers.append(testing.allocator, .{ .task = 7, .held = &ctx });
    try testing.expect(followerFor(followers.items, &b_req));

    try runJob(job);
    const woken = try takeFollowers(testing.allocator, &followers, 2435);
    defer testing.allocator.free(woken);
    try testing.expectEqual(@as(usize, 1), woken.len);
    try testing.expect(woken[0] == @as(*anyopaque, &b_req));
    // The other task's follower stays.
    try testing.expectEqual(@as(usize, 1), followers.items.len);
    try testing.expectEqual(@as(u64, 7), followers.items[0].task);
}

test "worktree: 挂起的 job 做完、请求被再分派拒掉 → settle 已先把树记进账本，且只记一次" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();
    var ctx: u8 = 0;
    var req: u8 = 0;

    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .task = .{
        .dir = fx.repo,
        .group = "polter",
        .task = 2435,
    } }, ledger.entries.items, noteDone, &ctx);
    defer job.destroy();
    var w: Wait = .{ .job = job, .held = &req };

    // Not finished: nothing to put down.
    try testing.expect(!settle(testing.io, &ledger, &w));
    try runJob(job);
    const made = job.result.?.prepared.tree.entry.path;
    try testing.expect(exists(testing.io, made));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);

    // The request is refused after this and never calls the job's owner.
    try testing.expect(settle(testing.io, &ledger, &w));
    try testing.expect(ledger.taskTree(2435) != null);
    try testing.expect(!settle(testing.io, &ledger, &w));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

test "worktree: 主仓库或别处的树检出了 wt/g/N → 不当成任务树（BranchExists），账本为空" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();

    // The main working tree has the task's branch checked out.
    try fx.must(fx.repo, &.{ "checkout", "-q", "-b", "wt/polter/2435" });
    const p = try prepareTask(fx.git(), a, &ledger, .{ .dir = fx.repo, .group = "polter", .task = 2435 });
    try testing.expect(p == .refused);
    try testing.expectEqualStrings("BranchExists", p.refused.code);
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);

    // A tree somebody made by hand, elsewhere, on that branch.
    try fx.must(fx.repo, &.{ "checkout", "-q", "main" });
    const elsewhere = try std.fs.path.join(a, &.{ fx.root, "mine" });
    try fx.must(fx.repo, &.{ "worktree", "add", "-q", elsewhere, "wt/polter/2435" });
    const q = try prepareTask(fx.git(), a, &ledger, .{ .dir = fx.repo, .group = "polter", .task = 2435 });
    try testing.expect(q == .refused);
    try testing.expectEqualStrings("BranchExists", q.refused.code);
    try testing.expect(std.mem.indexOf(u8, q.refused.message, "mine") != null);
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
}

/// The app's side of `round`, counting what it is asked.
const RoundFake = struct {
    ledger: *Ledger,
    waits: *std.ArrayList(Wait),
    task: u64,
    parks: bool = false,
    open: bool = true,
    dispatched: bool = false,
    tree_in_ledger_at_dispatch: bool = false,
    waits_at_dispatch: usize = 0,
    woken: usize = 0,
    woken_before_dispatch: bool = false,
    orphans: usize = 0,
    released: usize = 0,

    fn dispatch(self: *RoundFake) bool {
        self.dispatched = true;
        self.tree_in_ledger_at_dispatch = self.ledger.taskTree(self.task) != null;
        self.waits_at_dispatch = self.waits.items.len;
        self.woken_before_dispatch = self.woken > 0;
        return self.parks;
    }
    fn wake(self: *RoundFake, _: *anyopaque) void {
        self.woken += 1;
    }
    fn taskOpen(self: *RoundFake, _: u64) bool {
        return self.open;
    }
    fn closeOrphan(self: *RoundFake, _: u64) void {
        self.orphans += 1;
    }
    fn release(self: *RoundFake, _: Wait) void {
        self.released += 1;
    }
};

/// A finished tree-making job for task 2435, waiting on `req`.
fn finishedTreeJob(fx: *Fixture, ledger: *Ledger, req: *u8, ctx: *u8) !*Job {
    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .task = .{
        .dir = fx.repo,
        .group = "polter",
        .task = 2435,
    } }, ledger.entries.items, noteDone, ctx);
    errdefer job.destroy();
    _ = req;
    try runJob(job);
    return job;
}

test "worktree: round 先 settle 再分派：分派那一刻树已在账本里、job 还在单子上；没挂起则分派后丢掉" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;
    var req: u8 = 0;
    const job = try finishedTreeJob(&fx, &ledger, &req, &ctx);
    defer job.destroy();
    var waits: std.ArrayList(Wait) = .empty;
    defer waits.deinit(testing.allocator);
    var followers: std.ArrayList(Follower) = .empty;
    defer followers.deinit(testing.allocator);
    try waits.append(testing.allocator, .{ .job = job, .held = &req });

    var fake: RoundFake = .{ .ledger = &ledger, .waits = &waits, .task = 2435 };
    round(RoundFake, &fake, testing.io, testing.allocator, &ledger, &waits, &followers, &req);
    try testing.expect(fake.dispatched);
    try testing.expect(fake.tree_in_ledger_at_dispatch);
    try testing.expectEqual(@as(usize, 1), fake.waits_at_dispatch);
    // The dispatch did not take the job: dropped.
    try testing.expectEqual(@as(usize, 0), waits.items.len);
    try testing.expectEqual(@as(usize, 1), fake.released);
}

test "worktree: round 遇到挂起的分派 → job 留在单子上，不丢" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;
    var req: u8 = 0;
    const job = try finishedTreeJob(&fx, &ledger, &req, &ctx);
    defer job.destroy();
    var waits: std.ArrayList(Wait) = .empty;
    defer waits.deinit(testing.allocator);
    var followers: std.ArrayList(Follower) = .empty;
    defer followers.deinit(testing.allocator);
    try waits.append(testing.allocator, .{ .job = job, .held = &req });

    var fake: RoundFake = .{ .ledger = &ledger, .waits = &waits, .task = 2435, .parks = true };
    round(RoundFake, &fake, testing.io, testing.allocator, &ledger, &waits, &followers, &req);
    try testing.expectEqual(@as(usize, 1), waits.items.len);
    try testing.expectEqual(@as(usize, 0), fake.released);
}

test "worktree: round 在分派前叫醒同任务的 follower；别的任务的不动" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;
    var req: u8 = 0;
    var b: u8 = 0;
    var c: u8 = 0;
    const job = try finishedTreeJob(&fx, &ledger, &req, &ctx);
    defer job.destroy();
    var waits: std.ArrayList(Wait) = .empty;
    defer waits.deinit(testing.allocator);
    var followers: std.ArrayList(Follower) = .empty;
    defer followers.deinit(testing.allocator);
    try waits.append(testing.allocator, .{ .job = job, .held = &req });
    try followers.append(testing.allocator, .{ .task = 2435, .held = &b });
    try followers.append(testing.allocator, .{ .task = 7, .held = &c });

    var fake: RoundFake = .{ .ledger = &ledger, .waits = &waits, .task = 2435 };
    round(RoundFake, &fake, testing.io, testing.allocator, &ledger, &waits, &followers, &req);
    try testing.expectEqual(@as(usize, 1), fake.woken);
    try testing.expect(fake.woken_before_dispatch);
    try testing.expectEqual(@as(usize, 1), followers.items.len);
    try testing.expectEqual(@as(u64, 7), followers.items[0].task);
}

test "worktree: 建树期间任务被关 → round 补做 closeout（开着的任务不补）" {
    inline for (.{ false, true }) |open| {
        var fx: Fixture = undefined;
        try fx.init();
        defer fx.deinit();
        var ledger = try Ledger.init(testing.allocator, null);
        defer ledger.deinit();
        var ctx: u8 = 0;
        var req: u8 = 0;
        const job = try finishedTreeJob(&fx, &ledger, &req, &ctx);
        defer job.destroy();
        var waits: std.ArrayList(Wait) = .empty;
        defer waits.deinit(testing.allocator);
        var followers: std.ArrayList(Follower) = .empty;
        defer followers.deinit(testing.allocator);
        try waits.append(testing.allocator, .{ .job = job, .held = &req });

        var fake: RoundFake = .{ .ledger = &ledger, .waits = &waits, .task = 2435, .open = open };
        round(RoundFake, &fake, testing.io, testing.allocator, &ledger, &waits, &followers, &req);
        try testing.expect(ledger.taskTree(2435) != null);
        try testing.expectEqual(@as(usize, if (open) 0 else 1), fake.orphans);
    }
}

test "worktree: job 做完却没交回 app 线程 → 下一个请求的 round 替它 settle、放走 follower、丢掉" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;
    var lost: u8 = 0;
    var b: u8 = 0;
    var other: u8 = 0;
    const job = try finishedTreeJob(&fx, &ledger, &lost, &ctx);
    defer job.destroy();
    job.undelivered.store(true, .release);
    var waits: std.ArrayList(Wait) = .empty;
    defer waits.deinit(testing.allocator);
    var followers: std.ArrayList(Follower) = .empty;
    defer followers.deinit(testing.allocator);
    try waits.append(testing.allocator, .{ .job = job, .held = &lost });
    try followers.append(testing.allocator, .{ .task = 2435, .held = &b });

    var fake: RoundFake = .{ .ledger = &ledger, .waits = &waits, .task = 2435 };
    round(RoundFake, &fake, testing.io, testing.allocator, &ledger, &waits, &followers, &other);
    try testing.expectEqual(@as(usize, 1), fake.woken);
    try testing.expect(ledger.taskTree(2435) != null);
    try testing.expectEqual(@as(usize, 0), waits.items.len);
    try testing.expectEqual(@as(usize, 1), fake.released);
}

test "worktree: 补做的 closeout（无请求的 orphan）做完后，round 把它的结果记进账本并丢掉" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;
    var other: u8 = 0;
    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);
    try landOnMain(&fx);
    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .closeout = .{
        .task = 2435,
        .in = .{ .mode = .closed },
    } }, ledger.entries.items, noteDone, &ctx);
    defer job.destroy();
    try runJob(job);
    var waits: std.ArrayList(Wait) = .empty;
    defer waits.deinit(testing.allocator);
    var followers: std.ArrayList(Follower) = .empty;
    defer followers.deinit(testing.allocator);
    try waits.append(testing.allocator, .{ .job = job, .held = job, .orphan = true });

    var fake: RoundFake = .{ .ledger = &ledger, .waits = &waits, .task = 2435 };
    round(RoundFake, &fake, testing.io, testing.allocator, &ledger, &waits, &followers, &other);
    try testing.expect(!exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    try testing.expectEqual(@as(usize, 0), waits.items.len);
    try testing.expectEqual(@as(usize, 1), fake.released);
}

test "worktree: seatTerminals：成员先 leave（id 置 nobody）再算，坐过座位的终端仍在名单里" {
    var t: Tasks = .init(testing.allocator, .{});
    defer t.deinit();
    const id = try t.create("polter", "squad", .other);
    try t.join(id, "dev", "developer", 0xa1, "", 0, true);
    try t.join(id, "test", "tester", 0xb2, "", 0, false);
    // What `closeTask` does before it asks who is standing.
    try t.leave(id, "dev", 10);
    try t.leave(id, "test", 10);

    const task = t.get(id).?;
    const places = try Tasks.membersOf(testing.allocator, task);
    defer testing.allocator.free(places);
    for (places) |m| try testing.expectEqual(Tasks.nobody, m.id);

    const seats = try seatTerminals(testing.allocator, task);
    defer testing.allocator.free(seats);
    try testing.expectEqual(@as(usize, 2), seats.len);
    try testing.expect(std.mem.indexOfScalar(u64, seats, 0xa1) != null);
    try testing.expect(std.mem.indexOfScalar(u64, seats, 0xb2) != null);
}

test "worktree: stands：cwd 取不到时，任务成员算站着、旁人不算" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    try testing.expect(try stands(testing.io, a, fx.repo, null, true));
    try testing.expect(!(try stands(testing.io, a, fx.repo, null, false)));
    try testing.expect(try stands(testing.io, a, fx.repo, fx.repo, false));
}

test "worktree: 手动 worktree_remove 的回执和 worktree_status 都带 ignored_extra，超过 20 条写还有多少" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.al();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    try fx.write(fx.repo, ".gitignore", "*.local\n");
    try fx.must(fx.repo, &.{ "add", ".gitignore" });
    try fx.must(fx.repo, &.{ "commit", "-q", "-m", "ignore" });
    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    var i: usize = 0;
    while (i < max_listed + 5) : (i += 1) {
        const name = try std.fmt.allocPrint(a, "n{d:0>2}.local", .{i});
        try fx.write(e.path, name, "x\n");
    }

    const s = try statusFull(fx.git(), a, e);
    try testing.expectEqual(@as(usize, max_listed), s.landed.?.ignored_extra.len);
    try testing.expectEqual(@as(usize, 5), s.landed.?.ignored_more);
    const js = try statusJson(&fx, s);
    try testing.expectEqual(@as(usize, max_listed), js.object.get("ignored_extra").?.array.items.len);
    try testing.expectEqual(@as(i64, 5), js.object.get("ignored_more").?.integer);

    const r = try removeSel(fx.git(), a, &ledger, .{ .task = 2435 });
    try testing.expect(r == .removed);
    try testing.expect(std.mem.indexOf(u8, r.removed.ignored, "n00.local") != null);
    try testing.expect(std.mem.indexOf(u8, r.removed.ignored, "and 5 more") != null);
}

test "worktree: closeout 的 Job 在私有账本上删树，真账本等 forgetGone 才跟上并落盘" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer ledger.deinit();
    var ctx: u8 = 0;

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try ledger.save(testing.io);
    try workerWork(&fx, e.path);
    try landOnMain(&fx);

    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .closeout = .{
        .task = 2435,
        .in = .{ .mode = .closed },
    } }, ledger.entries.items, noteDone, &ctx);
    defer job.destroy();
    try runJob(job);

    // The directory is gone; the caller's ledger has not been touched by a thread.
    const c = job.result.?.closeout;
    try testing.expectEqual(Outcome.removed, c.outcome);
    try testing.expect(!exists(testing.io, e.path));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);

    try testing.expect(forgetGone(testing.io, &ledger, job.result.?));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
    // Written down: a fresh ledger read from the file has none either.
    var reread = try Ledger.init(testing.allocator, try fx.ledgerFile());
    defer reread.deinit();
    reread.load(testing.io);
    try testing.expectEqual(@as(usize, 0), reread.entries.items.len);
    // And once is enough.
    try testing.expect(!forgetGone(testing.io, &ledger, job.result.?));
}

test "worktree: closeout 的 Job 遇到未落地的改动 → 树和账本都不动，forgetGone 什么也不做" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);

    const job = try Job.create(std.heap.smp_allocator, fx.git(), .{ .closeout = .{
        .task = 2435,
        .in = .{ .mode = .closed },
    } }, ledger.entries.items, noteDone, &ctx);
    defer job.destroy();
    try runJob(job);
    try testing.expectEqual(Outcome.kept_unlanded, job.result.?.closeout.outcome);
    try testing.expect(exists(testing.io, e.path));
    try testing.expect(!forgetGone(testing.io, &ledger, job.result.?));
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
}

test "worktree: status 与 remove 的 Job：点名、列表、没有这棵、未落地不删" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var ledger = try Ledger.init(testing.allocator, null);
    defer ledger.deinit();
    var ctx: u8 = 0;

    const e = try taskTreeOf(&fx, &ledger, "polter", 2435);
    try workerWork(&fx, e.path);

    const one = try Job.create(std.heap.smp_allocator, fx.git(), .{ .status = .{ .task = 2435 } }, ledger.entries.items, noteDone, &ctx);
    defer one.destroy();
    try runJob(one);
    const rows = one.result.?.statuses;
    try testing.expect(rows.single);
    try testing.expectEqual(@as(usize, 1), rows.rows.len);
    try testing.expect(!rows.rows[0].landed.?.landed);

    const all = try Job.create(std.heap.smp_allocator, fx.git(), .{ .status = .{} }, ledger.entries.items, noteDone, &ctx);
    defer all.destroy();
    try runJob(all);
    try testing.expect(!all.result.?.statuses.single);

    const none = try Job.create(std.heap.smp_allocator, fx.git(), .{ .status = .{ .task = 7 } }, ledger.entries.items, noteDone, &ctx);
    defer none.destroy();
    try runJob(none);
    try testing.expectEqualStrings("NoSuchWorktree", none.result.?.refused.code);

    // Not landed: the removal is refused and the real ledger is unchanged.
    const rm = try Job.create(std.heap.smp_allocator, fx.git(), .{ .remove = .{ .task = 2435 } }, ledger.entries.items, noteDone, &ctx);
    defer rm.destroy();
    try runJob(rm);
    try testing.expectEqualStrings("WorktreeNotLanded", rm.result.?.removed.what.refused.code);
    try testing.expect(rm.result.?.removed.gone == null);
    try testing.expect(exists(testing.io, e.path));

    // Landed: removed, and the job says which tree to forget.
    try landOnMain(&fx);
    const rm2 = try Job.create(std.heap.smp_allocator, fx.git(), .{ .remove = .{ .task = 2435 } }, ledger.entries.items, noteDone, &ctx);
    defer rm2.destroy();
    try runJob(rm2);
    try testing.expect(rm2.result.?.removed.what == .removed);
    try testing.expectEqualStrings(e.name, rm2.result.?.removed.gone.?.name);
    try testing.expect(!exists(testing.io, e.path));
    try testing.expect(forgetGone(testing.io, &ledger, rm2.result.?));
    try testing.expectEqual(@as(usize, 0), ledger.entries.items.len);
}

test "worktree: looksLikeRepo 在仓库和仓库的子目录里为真，在普通目录里为假，不起进程" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const sub_dir = try std.fs.path.join(fx.al(), &.{ fx.repo, "src", "deep" });
    try Io.Dir.cwd().createDirPath(testing.io, sub_dir);
    const plain = try std.fs.path.join(fx.al(), &.{ fx.root, "plain" });
    try Io.Dir.cwd().createDirPath(testing.io, plain);

    try testing.expect(looksLikeRepo(testing.io, fx.repo));
    try testing.expect(looksLikeRepo(testing.io, sub_dir));
    try testing.expect(!looksLikeRepo(testing.io, plain));
    try testing.expect(!looksLikeRepo(testing.io, "/"));
}

test "worktree: cwdRelation 分树里、同仓库树外、别处" {
    const e: Entry = .{
        .name = "build/wt-1",
        .repo = "/src/proj",
        .path = "/src/proj-wt/build/wt-1",
        .branch = "wt/build/1",
        .base = "x",
        .kind = .task,
        .task = 1,
    };
    try testing.expectEqual(CwdRelation.in_tree, cwdRelation(e, "/src/proj-wt/build/wt-1"));
    try testing.expectEqual(CwdRelation.in_tree, cwdRelation(e, "/src/proj-wt/build/wt-1/src"));
    // The checkout itself, the group's directory, another task's tree.
    try testing.expectEqual(CwdRelation.same_repo, cwdRelation(e, "/src/proj"));
    try testing.expectEqual(CwdRelation.same_repo, cwdRelation(e, "/src/proj/src"));
    try testing.expectEqual(CwdRelation.same_repo, cwdRelation(e, "/src/proj-wt/build"));
    try testing.expectEqual(CwdRelation.same_repo, cwdRelation(e, "/src/proj-wt/build/wt-9"));
    try testing.expectEqual(CwdRelation.same_repo, cwdRelation(e, "/src/proj-wt/other/wt-2"));
    // Not this repository's: a sibling with the same prefix, an unrelated place.
    try testing.expectEqual(CwdRelation.elsewhere, cwdRelation(e, "/src/proj-other"));
    try testing.expectEqual(CwdRelation.elsewhere, cwdRelation(e, "/src"));
    try testing.expectEqual(CwdRelation.elsewhere, cwdRelation(e, "/other/repo"));

    // Trees made inside the repository.
    var inside = e;
    inside.path = "/src/proj/.polter-worktrees/build/wt-1";
    try testing.expectEqual(CwdRelation.in_tree, cwdRelation(inside, "/src/proj/.polter-worktrees/build/wt-1/x"));
    try testing.expectEqual(CwdRelation.same_repo, cwdRelation(inside, "/src/proj/.polter-worktrees/build/wt-2"));
    try testing.expectEqual(CwdRelation.same_repo, cwdRelation(inside, "/src/proj/lib"));
}

test "worktree: withPreface 把成员的话放在第一句之后；开头对不上时放在前面" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "Task 5 closed. Closed dev. Its worktree is kept.",
        try withPreface(a, "Task 5 closed. Its worktree is kept.", " Closed dev.", 5, .closed),
    );
    try testing.expectEqualStrings(
        "Task 5 cancelled. Told. It has no worktree.",
        try withPreface(a, "Task 5 cancelled. It has no worktree.", " Told.", 5, .cancelled),
    );
    // Nothing to add: the sentence as it is.
    try testing.expectEqualStrings("Task 5 closed. X", try withPreface(a, "Task 5 closed. X", "", 5, .closed));
    // A header that is not the one asked for: the preface goes first, nothing is lost.
    try testing.expectEqualStrings(" Z.Task 6 closed. X", try withPreface(a, "Task 6 closed. X", " Z.", 5, .closed));
}

test "lease: releaseTask 放掉任何人的租约并记原因，没人持有时什么也没有" {
    var leases = Leases.init(testing.allocator);
    defer leases.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try leases.releaseTask(a, 7, 100)) == null);
    _ = try leases.acquire(7, "tester", 0x77, .build, 10);
    try testing.expect(leases.status(7) != null);
    const ev = (try leases.releaseTask(a, 7, 100)).?;
    try testing.expectEqual(LeaseWhy.supervisor, ev.why);
    try testing.expectEqualStrings("tester", ev.alias);
    try testing.expectEqual(@as(i64, 90), ev.held_ms);
    try testing.expect(leases.status(7) == null);
    // Another task's lease is not touched.
    _ = try leases.acquire(8, "other", 0x88, .edit, 10);
    try testing.expect((try leases.releaseTask(a, 7, 100)) == null);
    try testing.expect(leases.status(8) != null);
}
