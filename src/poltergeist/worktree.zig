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
//! And one of its own: **nothing here deletes a tree that is dirty or not
//! merged**, and nothing deletes one at all unless asked (`remove`). There
//! is no `--force` anywhere in this file.
//!
//! ⚠️ **Making a tree is checking out a repository**, which for this one is
//! six thousand files and seconds of disk. So it is split in two: `plan`
//! runs git and nothing else, and may run anywhere -- in the app, on a
//! thread of its own (`Job`), because the app thread is every terminal's
//! thread and the person's whole window waits on it; `commit` writes the
//! ledger and runs where the ledger lives. `prepare` is the two in a row,
//! for callers that may wait.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

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

    pub fn dupe(self: Entry, alloc: Allocator) Allocator.Error!Entry {
        var e = self;
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

/// What `terminal_list` says of a terminal standing in a tree.
pub const Tag = struct {
    name: []const u8,
    branch: []const u8,
    path: []const u8,
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
        return .{ .name = e.name, .branch = e.branch, .path = e.path };
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
    if (exists(git.io, path)) return .{ .refused = .{
        .code = "WorktreeExists",
        .message = try std.fmt.allocPrint(
            arena,
            "{s} is already there and Polter did not make it; nothing was opened. Pick another name.",
            .{path},
        ),
    } };

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

    const head = git.run(arena, req.dir, &.{ "rev-parse", "--verify", "HEAD" }) catch |err|
        return gitFailure(arena, err);
    if (!head.ok) return refuse(
        "NoCommits",
        "that repository has no commit to base a worktree on; nothing was opened.",
    );
    const base = head.out;

    if (req.location == .inside) ensureExcluded(arena, git.io, repo.common) catch |err| return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(
            arena,
            "could not write {s} into the repository's info/exclude ({t}), so a tree inside it " ++
                "could be committed; nothing was made.",
            .{ exclude_line, err },
        ),
    } };

    const add = git.run(arena, repo.main, &.{ "worktree", "add", "-b", branch, path, base }) catch |err|
        return gitFailure(arena, err);
    if (!add.ok) return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(arena, "git worktree add failed; nothing was opened: {s}", .{add.err}),
    } };

    // What git made it, not what was asked for: the two differ wherever a
    // path goes through a link (`/tmp` on macOS), and a terminal's `cwd` is
    // matched against this.
    const real = git.run(arena, path, &.{ "rev-parse", "--show-toplevel" }) catch null;
    const entry: Entry = .{
        .name = req.name,
        .repo = repo.main,
        .path = if (real) |r| (if (r.ok and r.out.len > 0) r.out else path) else path,
        .branch = branch,
        .base = base,
        .created_ms = req.now_ms,
        .by = req.by,
    };
    return .{ .tree = .{ .entry = entry, .reused = false } };
}

/// `plan` on a thread of its own (task 1702).
///
/// **Why a thread and not the caller's.** In the app the caller is the app
/// thread, which every terminal's events and the person's window go
/// through; `git worktree add` on this repository checks out six thousand
/// files, and the window would stand still for as long as that takes -- on
/// a larger repository or a slower disk, longer. So the app starts one of
/// these, parks the request, and answers it when `done` says so.
///
/// Owns copies of everything it reads, in its own arena, because the
/// request that asked may be answered -- and freed -- by somebody else (the
/// server shutting down) while git is still running.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    git: Git,
    req: Request,
    known: []const Entry,
    /// Set on the job's thread before `finished`; read after it.
    result: ?Prepared = null,
    finished: std.atomic.Value(bool) = .init(false),
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
        req: Request,
        known: []const Entry,
        done: *const fn (ctx: *anyopaque, job: *Job) void,
        done_ctx: *anyopaque,
    ) Allocator.Error!*Job {
        const job = try child.create(Job);
        errdefer child.destroy(job);
        job.* = .{
            .arena = .init(child),
            .git = git,
            .req = req,
            .known = &.{},
            .done = done,
            .done_ctx = done_ctx,
        };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.req.dir = try a.dupe(u8, req.dir);
        job.req.name = try a.dupe(u8, req.name);
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
        self.result = plan(self.git, self.arena.allocator(), self.known, self.req) catch .{ .refused = .{
            .code = "WorktreeFailed",
            .message = "ran out of memory making the worktree; it may be half made.",
        } };
        self.finished.store(true, .release);
        self.done(self.done_ctx, self);
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
};

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

fn statusInto(git: Git, arena: Allocator, s: *Status) !void {
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
    s.ahead = ahead;
    s.merged = ahead == 0;
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
    if (s.problem) |p| {
        try w.objectField("problem");
        try w.write(p);
    }
    try w.endObject();
}

// -------------------------------------------------------------- remove

pub const Removed = union(enum) {
    /// The tree and its branch are gone, and so is the entry.
    removed: struct {
        path: []const u8,
        /// Null when the branch went too; otherwise why it is still there.
        branch_kept: ?[]const u8,
    },
    /// The directory was already gone; only the entry was forgotten.
    forgotten: []const u8,
    refused: Refusal,
};

/// Take a tree down -- **only when it is clean and merged**, and say why not
/// otherwise. Never forced.
pub fn remove(git: Git, arena: Allocator, ledger: *Ledger, name: []const u8, repo: []const u8) Allocator.Error!Removed {
    const i = switch (ledger.lookup(name, repo)) {
        .none => return .{ .refused = .{
            .code = "NoSuchWorktree",
            .message = try std.fmt.allocPrint(arena, "Polter has no worktree called {s}; worktree_status lists them.", .{name}),
        } },
        .ambiguous => |n| return .{ .refused = .{
            .code = "BadParams",
            .message = try std.fmt.allocPrint(arena, "{d} repositories have a worktree called {s}; say which with repo.", .{ n, name }),
        } },
        .one => |i| i,
    };
    const entry = try ledger.entries.items[i].dupe(arena);

    const s = try status(git, arena, entry);
    if (!s.exists) {
        ledger.removeAt(i);
        ledger.save(git.io) catch |err| log.warn("worktree: could not save the ledger: {t}", .{err});
        return .{ .forgotten = entry.path };
    }
    if (s.problem) |p| return .{ .refused = .{
        .code = "WorktreeFailed",
        .message = try std.fmt.allocPrint(arena, "whether {s} is clean and merged could not be told, so it was kept: {s}", .{ entry.path, p }),
    } };
    if (s.dirty.? > 0) return .{ .refused = .{
        .code = "WorktreeDirty",
        .message = try std.fmt.allocPrint(
            arena,
            "{d} uncommitted change{s} in {s}; nothing was removed. Commit, apply or discard them with git first.",
            .{ s.dirty.?, if (s.dirty.? == 1) "" else "s", entry.path },
        ),
    } };
    if (!s.merged.?) return .{ .refused = .{
        .code = "WorktreeNotMerged",
        .message = try std.fmt.allocPrint(
            arena,
            "branch {s} has {d} commit{s} that {s} does not; nothing was removed. Merge them with git first.",
            .{ entry.branch, s.ahead.?, if (s.ahead.? == 1) "" else "s", s.mainline.? },
        ),
    } };

    const rm = git.run(arena, entry.repo, &.{ "worktree", "remove", entry.path }) catch |err| switch (err) {
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
    return .{ .removed = .{ .path = entry.path, .branch_kept = kept } };
}

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
    const job = try Job.create(std.heap.smp_allocator, git, .{ .dir = fx.repo, .name = "w1" }, ledger.entries.items, Done.done, &told);
    defer job.destroy();

    const t0: Io.Timestamp = .now(io, .awake);
    try job.start();
    const took = t0.untilNow(io, .awake).toMilliseconds();
    // The floor: run inline, `start` would take the two seconds itself.
    try testing.expect(took < 500);

    // And the caller is free the whole time: it keeps turning until told.
    var turns: usize = 0;
    while (!job.finished.load(.acquire)) : (turns += 1) {
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    try testing.expect(turns >= 25);
    job.join();
    try testing.expectEqual(@as(u32, 1), told.count.load(.acquire));

    // Written down on the caller's side, from what the job made.
    const p = try commit(io, &ledger, job.result.?);
    try testing.expect(p == .tree);
    try testing.expect(!p.tree.reused);
    try testing.expectEqual(@as(usize, 1), ledger.entries.items.len);
    try testing.expectEqualStrings("wt/w1", try fx.out(p.tree.entry.path, &.{ "rev-parse", "--abbrev-ref", "HEAD" }));
}

test "worktree: a dirty tree is not removed, and the refusal says how dirty" {
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
    try testing.expectEqualStrings("WorktreeDirty", r.refused.code);
    try testing.expect(std.mem.indexOf(u8, r.refused.message, "1 uncommitted change ") != null);
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
