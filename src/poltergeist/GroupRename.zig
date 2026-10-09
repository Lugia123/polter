//! Renaming a group on disk: every record filed under its name, rewritten
//! under the new one.
//!
//! **A group's name is its identity.** There is no id behind it, so when the
//! name changes everything that used the old one has to change with it --
//! the directories under `chat/`, `tasks/` and `stats/`, the `group` field of
//! every line in them, and the lines of the files every group shares. This
//! file does the disk half; `App.chatRename` does the memory half, and the
//! list of what there is to do lives in `group_stores.zig`.
//!
//! ## How it is done: write new, check, swap
//!
//! Nothing is rewritten in place. The new files are written beside the old
//! ones (`<state>/rename-work/`), checked against them, and only then put in
//! the old ones' place -- the old ones **moved, not copied and not deleted,**
//! into `<state>/rename-backup/<stamp>-<old>-to-<new>/`. The record red line
//! gives way here and only here, and only as far as renaming: the bytes of
//! the old files are all still there, and the new files differ from them in
//! one thing, the value of the `group` field on the lines that were this
//! group's.
//!
//! A line is changed by replacing the bytes of that one value and nothing
//! else. It is not parsed and printed again: a line written by an older
//! build, or by another program, keeps whatever spelling it had.
//!
//! ## The intent, and what a crash leaves
//!
//! The swap is many `rename`s and cannot be one. So before anything is
//! touched there is `<state>/rename-intent.json` saying "turning `a` into
//! `b`", and it is removed last. A start that finds it finishes the job
//! (`recover`, which runs before any log is opened):
//!
//!   * `staging`  -- the new files may be half written. The old ones have
//!     not been touched. Start the writing again.
//!   * `staged`   -- the new files are written and checked. Swap.
//!   * `swapping` -- some items are swapped and some are not. Each item says
//!     which by which of its three paths exist (see `swapItem`); carry on.
//!
//! **Forward only.** Up to the check, a failure leaves the disk exactly as
//! it was. After it, there is nothing to go back to that is better than
//! carrying on, and carrying on is always possible from the state alone.
//!
//! ## Handles
//!
//! Whoever has a file of the old set open must let go of it before the swap
//! (`Hooks.close_handles`): a write to a handle that follows the moved file
//! succeeds, and lands in the backup. Windows would refuse the rename
//! instead, which is the kinder failure.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");
const group_stores = @import("group_stores.zig");
const Tasks = @import("Tasks.zig");
const TaskLog = @import("TaskLog.zig");

const log = std.log.scoped(.poltergeist);

pub const intent_name = "rename-intent.json";
pub const lock_name = "rename-intent.lock";
pub const work_name = "rename-work";
pub const backup_name = "rename-backup";

/// The most one file is read whole. Day files stop at `daylog.day_bytes`
/// and the stream rotates at 8MB, so this is a wall and not a measurement.
const max_file_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{
    /// The new name already has records on disk. Nothing was touched.
    Blocked,

    /// Another rename is under way, or one was left and could not be
    /// finished.
    Locked,

    /// The new files did not match the old ones, or could not be written.
    /// Nothing was touched.
    Failed,

    /// The disk is in a state the swap does not know how to continue from.
    /// Nothing more is touched; the intent stays for a person to read.
    Anomaly,

    /// A test stopped the process here, as a kill would.
    InjectedCrash,
} || Allocator.Error;

/// What a caller of `rename` tells its own caller, one name for each way it
/// can fail, and **a `switch` with no `else`** so that a new failure cannot
/// be reported as some other one by default. Before this, `Locked` -- another
/// Polter in the middle of renaming -- was answered as "the records could not
/// be moved", which the log contradicted and the caller could not act on.
pub const Refusal = error{
    RenameBlocked,
    RenameBusy,
    RenameUnfinished,
    RenameFailed,
    OutOfMemory,
};

pub fn refusal(err: Error) Refusal {
    return switch (err) {
        error.Blocked => error.RenameBlocked,
        error.Locked => error.RenameBusy,
        // An earlier rename is on disk unfinished (`rename-intent.json`),
        // or the swap met a state it does not know: not "could not be
        // moved" -- nothing was tried.
        error.Anomaly => error.RenameUnfinished,
        error.Failed => error.RenameFailed,
        error.InjectedCrash => error.RenameFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// What to say, to the supervisor and to the person, when `recover` could
/// not be finished at start and the logs stay closed. Also exhaustive.
pub fn startupProblem(err: Error) []const u8 {
    return switch (err) {
        error.Locked => "another Polter process is in the middle of renaming a group and did not finish within the time allowed",
        error.Anomaly => "a group rename was left in a state this version does not know how to continue from",
        error.Failed => "an unfinished group rename could not be finished",
        error.Blocked => "an unfinished group rename is blocked by records already under its new name",
        error.InjectedCrash => "a group rename was stopped",
        error.OutOfMemory => "there was not enough memory to finish a group rename",
    };
}

/// The whole sentence the supervisor (`group_list`'s `warning`) and the
/// person are given when the records could not be opened. Pure, so that what
/// is said can be checked without a window to say it in.
pub fn problemText(alloc: Allocator, state_dir: []const u8, why: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "Polter could not open its records: {s}. Nothing on disk was changed or lost, but " ++
            "the groups saved in {s} are NOT loaded and nothing new is being recorded; " ++
            "groups made now exist only in memory. Quit every Polter and start one again; " ++
            "if this stays, do not delete anything in that directory (see rename-intent.json, " ++
            "rename-work and rename-backup there).",
        .{ why, state_dir },
    );
}

pub const Phase = enum { staging, staged, swapping };

pub const Options = struct {
    alloc: Allocator,
    io: std.Io,

    /// Absolute.
    state_dir: []const u8,

    /// Tests: stop (as though killed) at the Nth durable step.
    crash_at: ?usize = null,

    /// Tests: read the clock as this.
    now_ms: ?i64 = null,

    /// Tests: damage the new files after they are written and before they
    /// are checked, to see that the check is what stops the swap.
    sabotage: ?Sabotage = null,
};

pub const Sabotage = enum { drop_line, change_text, change_other_group, drop_task_event };

pub const Hooks = struct {
    ctx: ?*anyopaque = null,

    /// Let go of every handle into the files being replaced
    /// (`group_stores.Handle`). Called once, before the first swap.
    close_handles: ?*const fn (ctx: ?*anyopaque) void = null,
};

/// What a rename did, for the report and the tests.
pub const Report = struct {
    /// Files written to the new set.
    files: usize = 0,

    /// Lines in them, and how many of those had their group changed.
    lines: usize = 0,
    changed: usize = 0,

    /// Lines that could not be read as an object and were copied as they
    /// were.
    passthrough: usize = 0,
};

pub const Recovered = struct {
    /// There was an intent and it was finished.
    finished: bool = false,

    /// There was an intent and it was dropped, because its new files did
    /// not match. The disk is as it was before the rename began.
    abandoned: bool = false,
};

// -- the entry points ---------------------------------------------------------

/// Rename `old` to `new` on disk. The caller has checked both are valid
/// names and that `old` is a group.
///
/// On `Blocked`, `Locked` and `Failed` the disk is as it was. On `Anomaly`
/// it is whatever the swap found, and the intent is left.
pub fn rename(
    opts: Options,
    old: []const u8,
    new: []const u8,
    hooks: Hooks,
) Error!Report {
    var run: Run = .init(opts);
    defer run.deinit();

    try run.lock();
    defer run.unlock();

    // An unfinished rename is not something to start another on top of.
    if (try run.exists(try run.path(&.{intent_name}))) return error.Anomaly;
    try run.checkTargetFree(new);

    const stamp = run.nowMs();
    const backup = try run.print("{s}/{s}/{d}-{s}-to-{s}", .{ opts.state_dir, backup_name, stamp, old, new });
    try run.writeIntent(.{ .from = old, .to = new, .phase = .staging, .backup = backup, .started_ms = stamp });
    try run.tick();

    const report = run.stageAndCheck(old, new) catch |err| {
        // Up to here the old files were only read. Put the disk back to
        // what it was: our own work directory and our own intent. (A test's
        // pretend kill cleans up nothing, as a real one would not.)
        if (err != error.InjectedCrash) run.abandon();
        return err;
    };

    try run.finish(old, new, backup, hooks);
    return report;
}

/// Finish a rename a previous run left. Runs before any log is opened, so
/// nothing is holding a file of either set.
pub fn recover(opts: Options) Error!Recovered {
    var run: Run = .init(opts);
    defer run.deinit();

    // No state directory yet is a first run: nothing to finish, and
    // nowhere to put a lock.
    if (!try run.exists(opts.state_dir)) return .{};

    // The lock before the look at the intent, so that a rename another
    // process is in the middle of is waited for and not mistaken for
    // "nothing to do" by one that has just not written its intent yet.
    try run.lock();
    defer run.unlock();

    const ipath = try run.path(&.{intent_name});
    if (!try run.exists(ipath)) return .{};

    const intent = run.readIntent(ipath) orelse {
        // An intent that cannot be read says nothing about what to do.
        // Doing something anyway is how records get lost.
        log.warn("group rename: {s} is unreadable; leaving the disk alone", .{ipath});
        return error.Anomaly;
    };

    switch (intent.phase) {
        .staging => {
            _ = run.stageAndCheck(intent.from, intent.to) catch |err| switch (err) {
                error.InjectedCrash => return err,
                error.OutOfMemory => return err,
                else => {
                    // The old files were never touched; drop the attempt.
                    log.warn("group rename: could not redo {s} -> {s} ({}); dropped", .{ intent.from, intent.to, err });
                    run.abandon();
                    return .{ .abandoned = true };
                },
            };
        },
        .staged, .swapping => {},
    }

    try run.finish(intent.from, intent.to, intent.backup, .{});
    return .{ .finished = true };
}

pub const Wait = struct {
    /// The longest to wait for a rename another process is in the middle of.
    ///
    /// A rename is sub-second to a few seconds of work: on a copy of the
    /// largest real group (a few MB of chat, the 13MB shared stream) the
    /// slowest took 3.2 s in a Debug build, which is the slow build. Ten
    /// seconds is three times that, and still short enough that a start
    /// held up by it is a start that waited, not one that looks hung.
    max_ms: u64 = 10_000,

    /// How often to look again.
    step_ms: u64 = 100,
};

/// `recover`, waiting for the lock if somebody else has it.
///
/// `Locked` now means one thing: a live process holds the lock -- the
/// kernel lets go of a dead one's -- and a live process holding it is
/// renaming a group right now. Waiting for it to finish is the right
/// response, and giving up at once is what turned a held lock into every
/// group disappearing. After `max_ms` the lock is still held and `Locked`
/// is returned; what to do then is the caller's, and it must not be to carry
/// on quietly.
pub fn recoverWaiting(opts: Options, wait: Wait) Error!Recovered {
    var waited: u64 = 0;
    while (true) {
        return recover(opts) catch |err| switch (err) {
            error.Locked => {
                if (waited >= wait.max_ms) return err;
                opts.io.sleep(.fromMilliseconds(@intCast(wait.step_ms)), .awake) catch return err;
                waited += wait.step_ms;
                continue;
            },
            else => return err,
        };
    }
}

// -- the run ------------------------------------------------------------------

const Intent = struct {
    from: []const u8,
    to: []const u8,
    phase: Phase,
    backup: []const u8,
    started_ms: i64,
};

const Item = struct {
    /// What is live now, what the new file is called while it is being
    /// checked, and where the old one goes.
    src: []const u8,
    staged: []const u8,
    backup: []const u8,

    /// Where the new file ends up. The same as `src` for a stream.
    dest: []const u8,

    is_dir: bool,
};

const Run = struct {
    o: Options,
    arena: std.heap.ArenaAllocator,
    n: usize = 0,
    report: Report = .{},
    lock_file: ?std.Io.File = null,

    fn init(o: Options) Run {
        return .{ .o = o, .arena = .init(o.alloc) };
    }

    fn deinit(self: *Run) void {
        self.arena.deinit();
    }

    fn a(self: *Run) Allocator {
        return self.arena.allocator();
    }

    fn print(self: *Run, comptime fmt: []const u8, args: anytype) Allocator.Error![]u8 {
        return std.fmt.allocPrint(self.a(), fmt, args);
    }

    fn path(self: *Run, parts: []const []const u8) Allocator.Error![]u8 {
        const all = try self.a().alloc([]const u8, parts.len + 1);
        all[0] = self.o.state_dir;
        @memcpy(all[1..], parts);
        return std.fs.path.join(self.a(), all);
    }

    fn nowMs(self: *Run) i64 {
        return self.o.now_ms orelse daylog.nowMs(self.o.io);
    }

    /// One durable step done. A test can stop the process after any of them.
    fn tick(self: *Run) Error!void {
        self.n += 1;
        if (self.o.crash_at) |at| if (self.n == at) return error.InjectedCrash;
    }

    fn exists(self: *Run, p: []const u8) Error!bool {
        std.Io.Dir.cwd().access(self.o.io, p, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.Failed,
        };
        return true;
    }

    // -- the lock ---------------------------------------------------------

    fn ownPid(self: *Run) u32 {
        _ = self;
        if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
        return @intCast(std.c.getpid());
    }

    /// Where in the lock file the holder writes who it is. **Not byte 0:**
    /// on Windows the lock is a byte-range lock on byte 0, and a range lock
    /// there is mandatory -- another process reading the locked byte is
    /// refused. Everything past it can be read by anyone.
    const holder_at: u64 = 16;
    const holder_len: usize = 64;

    /// The lock on renaming, held for as long as `lock_file` is open.
    ///
    /// **The operating system holds it, not this program.** `rename-intent.lock`
    /// is opened and locked exclusively and not-blocking
    /// (`flock(LOCK_EX|LOCK_NB)` on POSIX, an exclusive `LockFileEx`-style
    /// range lock on Windows -- `std.Io.File.tryLock` does both), and the
    /// lock lives exactly as long as the open handle. A process that exits,
    /// is killed or crashes closes its handles, and the kernel lets go: the
    /// next process gets the lock straight away, with nothing to compare.
    ///
    /// What this replaces compared a pid and a timestamp written in the
    /// file. On Windows it did not look at the pid at all and went by the
    /// age -- ten minutes -- so a host killed mid-rename could not be
    /// started again, and could not recover its own half-done rename,
    /// for ten minutes.
    ///
    /// **The file is never deleted.** Deleting it is how two processes end
    /// up each holding "the" lock on a different file: one waits on the old
    /// one, the other makes a new one. A lock file left on disk says nothing
    /// about whether a rename was left half-done; only `rename-intent.json`
    /// does, and that is what `recover` looks at.
    ///
    /// What is written in it (the holder's pid and the time) is for the log
    /// line that says who is in the way, and for nothing else.
    fn lock(self: *Run) Error!void {
        const p = try self.path(&.{lock_name});

        const f = std.Io.Dir.cwd().createFile(self.o.io, p, .{ .read = true, .truncate = false }) catch |err| {
            // No state directory to hold a lock in is not a lock.
            log.warn("group rename: could not open the lock file err={}", .{err});
            return error.Failed;
        };

        const got = f.tryLock(self.o.io, .exclusive) catch |err| {
            f.close(self.o.io);
            log.warn("group rename: could not lock {s} err={}", .{ p, err });
            return error.Failed;
        };
        if (!got) {
            var who: [holder_len]u8 = undefined;
            const n = f.readPositionalAll(self.o.io, &who, holder_at) catch 0;
            log.warn("group rename: another process holds the rename lock ({s})", .{std.mem.trim(u8, who[0..n], " \n\x00")});
            f.close(self.o.io);
            return error.Locked;
        }

        var line: [holder_len]u8 = @splat(' ');
        const text = std.fmt.bufPrint(&line, "{d} {d}\n", .{ self.ownPid(), self.nowMs() }) catch line[0..0];
        _ = text;
        f.writePositionalAll(self.o.io, &line, holder_at) catch {};

        self.lock_file = f;
    }

    fn unlock(self: *Run) void {
        const f = self.lock_file orelse return;
        f.unlock(self.o.io);
        f.close(self.o.io);
        self.lock_file = null;
    }

    // -- the intent -------------------------------------------------------

    fn writeIntent(self: *Run, intent: Intent) Error!void {
        var buf: std.Io.Writer.Allocating = .init(self.a());
        var s: std.json.Stringify = .{ .writer = &buf.writer, .options = .{} };
        s.write(.{
            .op = "group_rename",
            .from = intent.from,
            .to = intent.to,
            .phase = @tagName(intent.phase),
            .backup = intent.backup,
            .started_ms = intent.started_ms,
        }) catch return error.OutOfMemory;
        try self.writeAtomic(intent_name, buf.written());
    }

    fn setPhase(self: *Run, intent: Intent, phase: Phase) Error!void {
        var next = intent;
        next.phase = phase;
        try self.writeIntent(next);
        try self.tick();
    }

    fn readIntent(self: *Run, p: []const u8) ?Intent {
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, p, self.a(), .limited(64 * 1024)) catch return null;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.a(), bytes, .{}) catch return null;
        const obj = switch (parsed) {
            .object => |o| o,
            else => return null,
        };
        const from = strField(obj, "from") orelse return null;
        const to = strField(obj, "to") orelse return null;
        const backup = strField(obj, "backup") orelse return null;
        const phase = std.meta.stringToEnum(Phase, strField(obj, "phase") orelse return null) orelse return null;
        const started: i64 = switch (obj.get("started_ms") orelse return null) {
            .integer => |n| n,
            else => return null,
        };
        return .{ .from = from, .to = to, .phase = phase, .backup = backup, .started_ms = started };
    }

    fn removeIntent(self: *Run) void {
        const p = self.path(&.{intent_name}) catch return;
        std.Io.Dir.cwd().deleteFile(self.o.io, p) catch {};
    }

    /// Atomic and owner-only, like the other small files in here.
    fn writeAtomic(self: *Run, name: []const u8, bytes: []const u8) Error!void {
        var d = std.Io.Dir.cwd().openDir(self.o.io, self.o.state_dir, .{}) catch return error.Failed;
        defer d.close(self.o.io);

        var atomic = d.createFileAtomic(self.o.io, name, .{
            .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
                .fromMode(0o600)
            else
                .default_file,
            .replace = true,
        }) catch return error.Failed;
        defer atomic.deinit(self.o.io);

        atomic.file.writeStreamingAll(self.o.io, bytes) catch return error.Failed;
        atomic.replace(self.o.io) catch return error.Failed;
    }

    /// Our own work directory and our own intent -- never a record.
    fn abandon(self: *Run) void {
        const w = self.path(&.{work_name}) catch return;
        std.Io.Dir.cwd().deleteTree(self.o.io, w) catch {};
        self.removeIntent();
    }

    // -- checking the target ----------------------------------------------

    /// The new name must not already have records. A group that was
    /// destroyed leaves its directories behind, and a rename onto them
    /// would be two histories under one name.
    fn checkTargetFree(self: *Run, new: []const u8) Error!void {
        const seg = daylog.encodeSegment(self.a(), new) catch return error.OutOfMemory;
        inline for (std.enums.values(group_stores.Root)) |root| {
            const p = try self.path(&.{ root.subdir(), seg });
            if (try self.exists(p)) return error.Blocked;
        }
    }

    // -- staging ----------------------------------------------------------

    fn stageAndCheck(self: *Run, old: []const u8, new: []const u8) Error!Report {
        self.report = .{};
        const w = try self.path(&.{work_name});
        std.Io.Dir.cwd().deleteTree(self.o.io, w) catch return error.Failed;
        std.Io.Dir.cwd().createDirPath(self.o.io, w) catch return error.Failed;

        const old_seg = daylog.encodeSegment(self.a(), old) catch return error.OutOfMemory;
        const new_seg = daylog.encodeSegment(self.a(), new) catch return error.OutOfMemory;

        // Every directory of a group's records.
        inline for (std.enums.values(group_stores.Root)) |root| {
            try self.stageDir(root, old, new, old_seg, new_seg);
        }

        // Every file the groups share.
        inline for (std.enums.values(group_stores.Stream)) |stream| {
            try self.stageStream(stream, old, new);
        }

        if (self.o.sabotage) |how| try self.sabotage(how, new_seg);

        try self.checkAll(old, new, old_seg, new_seg);
        try self.tick();
        return self.report;
    }

    /// Test only. Damage one new file, the way a bug in the rewrite would.
    fn sabotage(self: *Run, how: Sabotage, new_seg: []const u8) Error!void {
        const file = switch (how) {
            .drop_task_event => try self.path(&.{ work_name, "tasks", new_seg, "x" }),
            else => try self.path(&.{ work_name, "stream", "chat.jsonl" }),
        };
        var target = file;
        if (how == .drop_task_event) {
            const dir = try self.path(&.{ work_name, "tasks", new_seg });
            const names = try self.listFiles(dir);
            target = try self.path(&.{ work_name, "tasks", new_seg, names[0] });
        }
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, target, self.a(), .limited(max_file_bytes)) catch return error.Failed;
        const damaged: []const u8 = switch (how) {
            .drop_line => bytes[(std.mem.indexOfScalar(u8, bytes, '\n') orelse 0) + 1 ..],
            .change_text => try std.mem.replaceOwned(u8, self.a(), bytes, "hello beta", "hello bata"),
            .change_other_group => try std.mem.replaceOwned(u8, self.a(), bytes, "\"group\":\"beta\"", "\"group\":\"gamma\""),
            .drop_task_event => bytes[(std.mem.indexOfScalar(u8, bytes, '\n') orelse 0) + 1 ..],
        };
        std.Io.Dir.cwd().writeFile(self.o.io, .{ .sub_path = target, .data = damaged }) catch return error.Failed;
    }

    fn stageDir(
        self: *Run,
        comptime root: group_stores.Root,
        old: []const u8,
        new: []const u8,
        old_seg: []const u8,
        new_seg: []const u8,
    ) Error!void {
        const src = try self.path(&.{ root.subdir(), old_seg });
        if (!try self.exists(src)) return;

        const dst = try self.path(&.{ work_name, root.subdir(), new_seg });
        std.Io.Dir.cwd().createDirPath(self.o.io, dst) catch return error.Failed;

        var d = std.Io.Dir.cwd().openDir(self.o.io, src, .{ .iterate = true }) catch return error.Failed;
        defer d.close(self.o.io);

        var it = d.iterate();
        while (it.next(self.o.io) catch return error.Failed) |e| {
            const kind = if (e.kind != .unknown) e.kind else (d.statFile(self.o.io, e.name, .{ .follow_symlinks = false }) catch return error.Failed).kind;
            // Nothing in a group's directory is a directory. If something
            // is, this is not a layout the rewrite understands.
            if (kind != .file) return error.Failed;

            const from = try self.path(&.{ root.subdir(), old_seg, e.name });
            const to = try self.path(&.{ work_name, root.subdir(), new_seg, e.name });
            const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, from, self.a(), .limited(max_file_bytes)) catch return error.Failed;

            const out = if (std.mem.indexOf(u8, e.name, ".jsonl") != null)
                (try self.rewrite(bytes, old, new)).bytes
            else
                bytes;
            self.report.files += 1;

            std.Io.Dir.cwd().writeFile(self.o.io, .{ .sub_path = to, .data = out }) catch return error.Failed;
            try self.tick();
        }
    }

    fn stageStream(
        self: *Run,
        comptime stream: group_stores.Stream,
        old: []const u8,
        new: []const u8,
    ) Error!void {
        const src = try self.path(&.{stream.path()});
        if (!try self.exists(src)) return;

        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, src, self.a(), .limited(max_file_bytes)) catch return error.Failed;
        const r = try self.rewrite(bytes, old, new);

        // A file that does not mention the group is not part of this
        // rename: not rewritten, not swapped, not backed up.
        if (r.changed == 0) return;

        const to = try self.path(&.{ work_name, "stream", std.fs.path.basename(stream.path()) });
        std.Io.Dir.cwd().createDirPath(self.o.io, std.fs.path.dirname(to).?) catch return error.Failed;
        std.Io.Dir.cwd().writeFile(self.o.io, .{ .sub_path = to, .data = r.bytes }) catch return error.Failed;
        self.report.files += 1;
        try self.tick();
    }

    const Rewritten = struct { bytes: []u8, changed: usize };

    /// Every line of `bytes`, with the group changed on the ones that are
    /// `old`'s. The line breaks, and a missing one at the very end, are
    /// kept exactly.
    fn rewrite(self: *Run, bytes: []const u8, old: []const u8, new: []const u8) Error!Rewritten {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var changed: usize = 0;

        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const line = if (nl) |i| rest[0..i] else rest;
            rest = if (nl) |i| rest[i + 1 ..] else rest[0..0];

            switch (try self.rewriteLine(line, old, new, &out)) {
                .changed => changed += 1,
                .same => {},
                .passthrough => self.report.passthrough += 1,
            }
            if (nl != null) try out.append(self.a(), '\n');
            self.report.lines += 1;
        }
        self.report.changed += changed;
        return .{ .bytes = out.items, .changed = changed };
    }

    const LineKind = enum { changed, same, passthrough };

    fn rewriteLine(
        self: *Run,
        line: []const u8,
        old: []const u8,
        new: []const u8,
        out: *std.ArrayListUnmanaged(u8),
    ) Error!LineKind {
        const span = (findGroupValue(self.o.alloc, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        }) orelse {
            try out.appendSlice(self.a(), line);
            return .passthrough;
        };

        defer self.o.alloc.free(span.value);

        if (!std.mem.eql(u8, span.value, old)) {
            try out.appendSlice(self.a(), line);
            return .same;
        }

        try out.appendSlice(self.a(), line[0..span.start]);
        var enc: std.Io.Writer.Allocating = .init(self.a());
        var s: std.json.Stringify = .{ .writer = &enc.writer, .options = .{} };
        s.write(new) catch return error.OutOfMemory;
        try out.appendSlice(self.a(), enc.written());
        try out.appendSlice(self.a(), line[span.end..]);
        return .changed;
    }

    // -- checking ---------------------------------------------------------

    fn fail(why: []const u8, args: anytype) Error {
        log.warn("group rename: check failed: " ++ "{s}", .{why});
        _ = args;
        return error.Failed;
    }

    /// Old against new, everything, before any of it is swapped.
    ///
    /// Two independent ways of reading a line are used on purpose: the
    /// rewrite finds the bytes to change with a token scanner, and this
    /// parses both lines as values and compares them. A rewrite that
    /// changed the wrong thing has to fool both.
    fn checkAll(self: *Run, old: []const u8, new: []const u8, old_seg: []const u8, new_seg: []const u8) Error!void {
        inline for (std.enums.values(group_stores.Root)) |root| {
            const src = try self.path(&.{ root.subdir(), old_seg });
            const dst = try self.path(&.{ work_name, root.subdir(), new_seg });
            const have_src = try self.exists(src);
            const have_dst = try self.exists(dst);
            if (have_src != have_dst) return fail("a directory is missing from one side", .{});

            if (have_src) {
                const names = try self.listFiles(src);
                const names_dst = try self.listFiles(dst);
                if (names.len != names_dst.len) return fail("the file sets differ", .{});
                for (names, names_dst) |x, y| if (!std.mem.eql(u8, x, y)) return fail("the file sets differ", .{});

                for (names) |name| {
                    const a_bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, try self.path(&.{ root.subdir(), old_seg, name }), self.a(), .limited(max_file_bytes)) catch return error.Failed;
                    const b_bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, try self.path(&.{ work_name, root.subdir(), new_seg, name }), self.a(), .limited(max_file_bytes)) catch return error.Failed;
                    if (std.mem.indexOf(u8, name, ".jsonl") != null) {
                        const seen = try self.compareLines(a_bytes, b_bytes, old, new, true);
                        if (seen.lines_with_other_group != 0) return fail("a line in a group's own directory is another group's", .{});
                    } else if (!std.mem.eql(u8, a_bytes, b_bytes)) {
                        return fail("a file that is copied differs", .{});
                    }
                }
            }
        }

        inline for (std.enums.values(group_stores.Stream)) |stream| {
            const src = try self.path(&.{stream.path()});
            const dst = try self.path(&.{ work_name, "stream", std.fs.path.basename(stream.path()) });
            if (try self.exists(dst)) {
                const a_bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, src, self.a(), .limited(max_file_bytes)) catch return error.Failed;
                const b_bytes = std.Io.Dir.readFileAlloc(.cwd(), self.o.io, dst, self.a(), .limited(max_file_bytes)) catch return error.Failed;
                _ = try self.compareLines(a_bytes, b_bytes, old, new, false);
            }
        }

        try self.checkTasks(old, new, old_seg, new_seg);
    }

    fn listFiles(self: *Run, dir: []const u8) Error![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var d = std.Io.Dir.cwd().openDir(self.o.io, dir, .{ .iterate = true }) catch return error.Failed;
        defer d.close(self.o.io);
        var it = d.iterate();
        while (it.next(self.o.io) catch return error.Failed) |e| {
            try list.append(self.a(), try self.a().dupe(u8, e.name));
        }
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return list.items;
    }

    const Seen = struct {
        lines_with_other_group: usize = 0,
    };

    /// Line by line. `own_dir` says every parsable line of this file is
    /// expected to be `old`'s; a stream's lines are not, and the ones that
    /// are not must come through byte for byte.
    fn compareLines(
        self: *Run,
        a_bytes: []const u8,
        b_bytes: []const u8,
        old: []const u8,
        new: []const u8,
        own_dir: bool,
    ) Error!Seen {
        var seen: Seen = .{};
        var ra = a_bytes;
        var rb = b_bytes;
        var max_a: u64 = 0;
        var max_b: u64 = 0;
        var objects_a: usize = 0;
        var objects_b: usize = 0;

        while (ra.len > 0 or rb.len > 0) {
            if (ra.len == 0 or rb.len == 0) return fail("the line counts differ", .{});

            const na = std.mem.indexOfScalar(u8, ra, '\n');
            const nb = std.mem.indexOfScalar(u8, rb, '\n');
            if ((na == null) != (nb == null)) return fail("a final line break differs", .{});
            const la = if (na) |i| ra[0..i] else ra;
            const lb = if (nb) |i| rb[0..i] else rb;
            ra = if (na) |i| ra[i + 1 ..] else ra[0..0];
            rb = if (nb) |i| rb[i + 1 ..] else rb[0..0];

            var arena: std.heap.ArenaAllocator = .init(self.o.alloc);
            defer arena.deinit();
            const va = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), la, .{}) catch null;
            const vb = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), lb, .{}) catch null;

            if ((va == null) != (vb == null)) return fail("a line stopped parsing, or started to", .{});
            if (va == null) {
                // Not a line anybody can read. It must be the same bytes.
                if (!std.mem.eql(u8, la, lb)) return fail("an unreadable line changed", .{});
                continue;
            }

            const oa = switch (va.?) {
                .object => |o| o,
                else => {
                    if (!std.mem.eql(u8, la, lb)) return fail("a non-object line changed", .{});
                    continue;
                },
            };
            const ob = switch (vb.?) {
                .object => |o| o,
                else => return fail("an object line became something else", .{}),
            };

            objects_a += 1;
            objects_b += 1;
            if (oa.get("seq")) |v| switch (v) {
                .integer => |n| max_a = @max(max_a, @as(u64, @intCast(@max(n, 0)))),
                else => {},
            };
            if (ob.get("seq")) |v| switch (v) {
                .integer => |n| max_b = @max(max_b, @as(u64, @intCast(@max(n, 0)))),
                else => {},
            };

            const ga = strField(oa, "group");
            const gb = strField(ob, "group");
            const is_old = ga != null and std.mem.eql(u8, ga.?, old);

            if (!is_old) {
                // Another group's line, or one with no group at all.
                // Not ours to touch.
                if (!std.mem.eql(u8, la, lb)) return fail("another group's line changed", .{});
                if (own_dir) seen.lines_with_other_group += 1;
                continue;
            }

            if (gb == null or !std.mem.eql(u8, gb.?, new)) return fail("a renamed line does not say the new name", .{});
            if (oa.count() != ob.count()) return fail("a renamed line gained or lost a field", .{});

            var it = oa.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "group")) continue;
                const other = ob.get(kv.key_ptr.*) orelse return fail("a renamed line lost a field", .{});
                if (!jsonEql(kv.value_ptr.*, other)) return fail("a renamed line changed more than its group", .{});
            }
        }

        if (objects_a != objects_b or max_a != max_b) return fail("message count or highest seq differs", .{});
        return seen;
    }

    /// Replay the old group's task events and the new ones' and compare
    /// what the panel would show.
    fn checkTasks(self: *Run, old: []const u8, new: []const u8, old_seg: []const u8, new_seg: []const u8) Error!void {
        const have_old = try self.exists(try self.path(&.{ "tasks", old_seg }));
        const have_new = try self.exists(try self.path(&.{ work_name, "tasks", new_seg }));
        if (!have_old and !have_new) return;

        var before: Tasks = .init(self.o.alloc, .{});
        defer before.deinit();
        var after: Tasks = .init(self.o.alloc, .{});
        defer after.deinit();

        var l1 = TaskLog.open(self.o.alloc, self.o.io, self.o.state_dir) catch return error.OutOfMemory;
        defer l1.deinit();
        l1.restore(&before);

        const w = try self.path(&.{work_name});
        var l2 = TaskLog.open(self.o.alloc, self.o.io, w) catch return error.OutOfMemory;
        defer l2.deinit();
        l2.restore(&after);

        const x = try before.inGroup(self.o.alloc, old);
        defer self.o.alloc.free(x);
        const y = try after.inGroup(self.o.alloc, new);
        defer self.o.alloc.free(y);

        if (x.len != y.len) return fail("the task counts differ", .{});
        for (x, y) |p, q| {
            if (p.id != q.id or p.owner != q.owner or p.state != q.state or
                p.progress != q.progress or p.kind != q.kind or
                !std.mem.eql(u8, p.title, q.title))
                return fail("a task differs", .{});
        }

        // The new panel holds nothing but this group's tasks.
        if (after.list.items.len != y.len) return fail("the new panel holds another group's tasks", .{});
    }

    // -- the swap ---------------------------------------------------------

    fn items(self: *Run, old: []const u8, new: []const u8, backup: []const u8) Error![]const Item {
        var list: std.ArrayListUnmanaged(Item) = .empty;
        const old_seg = daylog.encodeSegment(self.a(), old) catch return error.OutOfMemory;
        const new_seg = daylog.encodeSegment(self.a(), new) catch return error.OutOfMemory;

        inline for (std.enums.values(group_stores.Root)) |root| {
            try list.append(self.a(), .{
                .src = try self.path(&.{ root.subdir(), old_seg }),
                .staged = try self.path(&.{ work_name, root.subdir(), new_seg }),
                .backup = try std.fs.path.join(self.a(), &.{ backup, root.subdir(), old_seg }),
                .dest = try self.path(&.{ root.subdir(), new_seg }),
                .is_dir = true,
            });
        }
        inline for (std.enums.values(group_stores.Stream)) |stream| {
            const live = try self.path(&.{stream.path()});
            try list.append(self.a(), .{
                .src = live,
                .staged = try self.path(&.{ work_name, "stream", std.fs.path.basename(stream.path()) }),
                .backup = try std.fs.path.join(self.a(), &.{ backup, stream.path() }),
                .dest = live,
                .is_dir = false,
            });
        }
        return list.items;
    }

    fn finish(self: *Run, old: []const u8, new: []const u8, backup: []const u8, hooks: Hooks) Error!void {
        var intent: Intent = .{ .from = old, .to = new, .phase = .staging, .backup = backup, .started_ms = 0 };
        if (self.readIntent(try self.path(&.{intent_name}))) |i| intent = i;

        // Forward only: a phase already written is never written back.
        if (intent.phase == .staging) try self.setPhase(intent, .staged);
        if (intent.phase != .swapping) try self.setPhase(intent, .swapping);

        if (hooks.close_handles) |f| f(hooks.ctx);

        // The backup directory says what it is.
        std.Io.Dir.cwd().createDirPath(self.o.io, backup) catch return error.Failed;
        const readme = try self.print(
            "These are the files a rename of the group `{s}` to `{s}` replaced, moved here whole.\n" ++
                "Nothing in them was changed. The program never deletes this directory; once the\n" ++
                "renamed group has been checked it can be removed by hand.\n\n" ++
                "To undo the rename: quit Polter, move the `{s}` entries under chat/, tasks/ and stats/\n" ++
                "(and chat/chat.jsonl*, if it is here) out of the way, and move these back.\n",
            .{ old, new, new },
        );
        const rp = try std.fs.path.join(self.a(), &.{ backup, "README.txt" });
        std.Io.Dir.cwd().writeFile(self.o.io, .{ .sub_path = rp, .data = readme }) catch return error.Failed;

        for (try self.items(old, new, backup)) |item| try self.swapItem(item);

        const w = try self.path(&.{work_name});
        std.Io.Dir.cwd().deleteTree(self.o.io, w) catch {};
        self.removeIntent();
        try self.tick();
    }

    /// One item, from whatever state it is in to the end. Which state it is
    /// in is read off which of three paths exist:
    ///
    ///   * `src` and `staged`, no `backup`: not started. Move `src` aside.
    ///   * `staged` and `backup`, no `dest`: the old one is aside. Put the
    ///     new one in place.
    ///   * `dest` and `backup`, no `staged`: done.
    ///   * nothing staged and no `src`: the item was never part of this
    ///     rename (the group had no such directory, or the stream never
    ///     mentioned it).
    ///
    /// Anything else is not a state this knows how to continue from.
    fn swapItem(self: *Run, item: Item) Error!void {
        const has_src = try self.exists(item.src);
        const has_staged = try self.exists(item.staged);
        const has_backup = try self.exists(item.backup);
        const has_dest = if (item.is_dir) try self.exists(item.dest) else has_src;

        if (!has_staged and !has_backup) return; // not part of this rename
        if (!has_staged and has_backup and has_dest) return; // done

        if (has_staged and has_src and !has_backup) {
            if (std.fs.path.dirname(item.backup)) |parent| {
                std.Io.Dir.cwd().createDirPath(self.o.io, parent) catch return error.Failed;
            }
            std.Io.Dir.renameAbsolute(item.src, item.backup, self.o.io) catch return error.Failed;
            try self.tick();
            return self.swapItem(item);
        }

        if (has_staged and has_backup and !has_src) {
            if (std.fs.path.dirname(item.dest)) |parent| {
                std.Io.Dir.cwd().createDirPath(self.o.io, parent) catch return error.Failed;
            }
            std.Io.Dir.renameAbsolute(item.staged, item.dest, self.o.io) catch return error.Failed;
            try self.tick();
            return;
        }

        log.warn(
            "group rename: cannot continue {s}: src={} staged={} backup={} dest={}",
            .{ item.src, has_src, has_staged, has_backup, has_dest },
        );
        return error.Anomaly;
    }
};

// -- reading a line -------------------------------------------------------------

const Span = struct {
    /// The bytes of the value, quotes included.
    start: usize,
    end: usize,

    /// What the string says, unescaped. Owned by the allocator given.
    value: []u8,
};

/// Where the top-level `group` of a JSON object line is, if it is a string.
/// Null for anything that is not an object, has no such field, or whose
/// value is not a string -- all of which are lines this leaves alone.
fn findGroupValue(alloc: Allocator, line: []const u8) Allocator.Error!?Span {
    // Whole or not at all. A torn line is one nobody can read back, and
    // changing a name inside it would only make it a different torn line.
    const whole = std.json.validate(alloc, line) catch return error.OutOfMemory;
    if (!whole) return null;

    var scanner = std.json.Scanner.initCompleteInput(alloc, line);
    defer scanner.deinit();

    var depth: usize = 0;
    var want_key = false;

    while (true) {
        const tok = scanner.nextAlloc(alloc, .alloc_if_needed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };

        switch (tok) {
            .end_of_document => return null,
            .object_begin => {
                depth += 1;
                if (depth == 1) want_key = true;
            },
            .array_begin => depth += 1,
            .object_end, .array_end => {
                depth -|= 1;
                if (depth == 1) want_key = true;
            },
            .string, .allocated_string => |key| {
                const owned = tok == .allocated_string;
                defer if (owned) alloc.free(key);

                if (depth == 1 and want_key) {
                    want_key = false;
                    if (!std.mem.eql(u8, key, "group")) continue;

                    // The value: skip to its opening quote, then read it.
                    var i = scanner.cursor;
                    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == ':' or line[i] == '\n' or line[i] == '\r')) i += 1;
                    const start = i;

                    const vt = scanner.nextAlloc(alloc, .alloc_always) catch return null;
                    switch (vt) {
                        .allocated_string => |v| return .{ .start = start, .end = scanner.cursor, .value = v },
                        .allocated_number => |n| {
                            alloc.free(n);
                            return null;
                        },
                        else => return null,
                    }
                } else if (depth == 1) {
                    want_key = true;
                }
            },
            .number, .allocated_number, .true, .false, .null => {
                if (tok == .allocated_number) alloc.free(tok.allocated_number);
                if (depth == 1) want_key = true;
            },
            else => return null,
        }
    }
}

fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |v| v,
        else => null,
    };
}

fn jsonEql(x: std.json.Value, y: std.json.Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null => true,
        .bool => |v| v == y.bool,
        .integer => |v| v == y.integer,
        .float => |v| v == y.float,
        .number_string => |v| std.mem.eql(u8, v, y.number_string),
        .string => |v| std.mem.eql(u8, v, y.string),
        .array => |v| blk: {
            if (v.items.len != y.array.items.len) break :blk false;
            for (v.items, y.array.items) |p, q| if (!jsonEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != y.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |kv| {
                const other = y.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!jsonEql(kv.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "the group value is found by position and only at the top level" {
    const alloc = testing.allocator;

    const line =
        \\{"seq":1,"group":"build","text":"{\"group\":\"build\"} and \"group\":\"build\"","nested":{"group":"build"}}
    ;
    const span = (try findGroupValue(alloc, line)).?;
    defer alloc.free(span.value);
    try testing.expectEqualStrings("build", span.value);
    try testing.expectEqualStrings("\"build\"", line[span.start..span.end]);
    // The one at the top level, the first in the line.
    try testing.expectEqual(@as(usize, 17), span.start);
}

test "a line with no readable group is left alone" {
    const alloc = testing.allocator;
    for ([_][]const u8{
        "",
        "not json",
        "[1,2,3]",
        "{}",
        "{\"seq\":1}",
        "{\"group\":7}",
        "{\"nested\":{\"group\":\"build\"}}",
        "{\"group\":\"build\"", // torn
    }) |line| {
        if (try findGroupValue(alloc, line)) |span| {
            alloc.free(span.value);
            // Only the torn line could be mistaken, and it has no end.
            try testing.expect(false);
        }
    }
}

// -- tests that run a rename ----------------------------------------------------

const ChatLog = @import("ChatLog.zig");
const StatsLog = @import("StatsLog.zig");
const GroupLog = @import("GroupLog.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const t0: i64 = 1_700_000_000_000;
const day_ms: i64 = 24 * 60 * 60 * 1000;

fn scratch(alloc: Allocator, io: std.Io) ![]u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-grouprename-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// A state directory with two groups in it, written by the real writers:
/// `alpha` (the one that gets renamed) and `beta`, interleaved in the shared
/// stream, over two days, with tasks, stats and a note each.
fn build(alloc: Allocator, io: std.Io, state: []const u8) !void {
    var cl = try ChatLog.open(alloc, io, state);
    defer cl.deinit();
    _ = cl.append("alpha", 1, "boss", t0, false, "hello alpha");
    _ = cl.append("beta", 2, "worker", t0 + 1, false, "hello beta");
    _ = cl.append("alpha", 1, "boss", t0 + 2, false, "it says \"group\":\"alpha\" in the text, and that is only text");
    _ = cl.append("beta", 2, "worker", t0 + 3, false, "beta again");
    _ = cl.append("alpha", 1, "boss", t0 + day_ms, false, "next day, alpha");
    _ = cl.append("alpha", 1, "boss", t0 + day_ms + 1, true, "a summary of alpha");
    _ = cl.append("beta", 2, "worker", t0 + day_ms + 2, false, "beta next day");

    var tasks: Tasks = .init(alloc, .{});
    defer tasks.deinit();
    var tl = try TaskLog.open(alloc, io, state);
    defer tl.deinit();
    const one = try tasks.create("alpha", "first alpha task", .bug);
    tl.append(t0, .created, tasks.get(one).?);
    try tasks.assign(one, 0x2222);
    tl.append(t0 + 5, .assigned, tasks.get(one).?);
    const two = try tasks.create("alpha", "second alpha task", .feature);
    tl.append(t0 + 6, .created, tasks.get(two).?);
    try tasks.close(two);
    tl.append(t0 + 7, .closed, tasks.get(two).?);
    const three = try tasks.create("beta", "a beta task", .other);
    tl.append(t0 + 8, .created, tasks.get(three).?);

    var sl = try StatsLog.open(alloc, io, state);
    defer sl.deinit();
    sl.append(t0, "alpha", .{ .tasks = 2, .open = 1, .closed = 1 });
    sl.append(t0, "beta", .{ .tasks = 1, .open = 1 });

    var gl = try GroupLog.open(alloc, io, state);
    defer gl.deinit();
    gl.note("alpha", "what alpha is for");
    gl.note("beta", "");
}

/// Every file under `root` -- path and bytes -- as one hash, skipping the
/// names in `skip` at the top level.
fn digest(alloc: Allocator, io: std.Io, root: []const u8, skip: []const []const u8) ![Sha256.digest_length]u8 {
    var h = Sha256.init(.{});
    try digestDir(alloc, io, root, "", skip, &h);
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

fn digestDir(alloc: Allocator, io: std.Io, root: []const u8, rel: []const u8, skip: []const []const u8, h: *Sha256) !void {
    const here = if (rel.len == 0) try alloc.dupe(u8, root) else try std.fs.path.join(alloc, &.{ root, rel });
    defer alloc.free(here);

    var d = std.Io.Dir.cwd().openDir(io, here, .{ .iterate = true }) catch return;
    defer d.close(io);

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var kinds: std.ArrayListUnmanaged(std.Io.File.Kind) = .empty;
    defer kinds.deinit(alloc);

    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (rel.len == 0) {
            var skipped = false;
            for (skip) |s| if (std.mem.eql(u8, s, e.name)) {
                skipped = true;
            };
            if (skipped) continue;
        }
        try names.append(alloc, try alloc.dupe(u8, e.name));
        try kinds.append(alloc, e.kind);
    }

    // Sorted, with the kinds following their names.
    const idx = try alloc.alloc(usize, names.items.len);
    defer alloc.free(idx);
    for (idx, 0..) |*x, i| x.* = i;
    std.mem.sort(usize, idx, names.items, struct {
        fn lt(ns: [][]u8, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ns[a], ns[b]);
        }
    }.lt);

    for (idx) |i| {
        const sub = if (rel.len == 0) try alloc.dupe(u8, names.items[i]) else try std.fs.path.join(alloc, &.{ rel, names.items[i] });
        defer alloc.free(sub);
        h.update(sub);
        h.update("\x00");
        if (kinds.items[i] == .directory) {
            h.update("d\x00");
            try digestDir(alloc, io, root, sub, skip, h);
        } else {
            const full = try std.fs.path.join(alloc, &.{ root, sub });
            defer alloc.free(full);
            const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, full, alloc, .limited(max_file_bytes));
            defer alloc.free(bytes);
            h.update(bytes);
            h.update("\x00");
        }
    }
}

fn digestAt(alloc: Allocator, io: std.Io, parts: []const []const u8, skip: []const []const u8) ![Sha256.digest_length]u8 {
    const p = try std.fs.path.join(alloc, parts);
    defer alloc.free(p);
    return digest(alloc, io, p, skip);
}

fn dump(alloc: Allocator, io: std.Io, root: []const u8, rel: []const u8) void {
    const here = std.fs.path.join(alloc, &.{ root, rel }) catch return;
    defer alloc.free(here);
    var d = std.Io.Dir.cwd().openDir(io, here, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const sub = std.fs.path.join(alloc, &.{ rel, e.name }) catch return;
        defer alloc.free(sub);
        if (e.kind == .directory) {
            std.debug.print("  {s}/\n", .{sub});
            dump(alloc, io, root, sub);
        } else {
            const full = std.fs.path.join(alloc, &.{ root, sub }) catch return;
            defer alloc.free(full);
            const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
            std.debug.print("  {s} {d}\n", .{ sub, st.size });
        }
    }
}

const live_only: []const []const u8 = &.{ backup_name, work_name, intent_name, lock_name };

fn testOpts(alloc: Allocator, io: std.Io, state: []const u8) Options {
    return .{ .alloc = alloc, .io = io, .state_dir = state, .now_ms = 1_800_000_000_000 };
}

fn pathExists(io: std.Io, p: []const u8) bool {
    std.Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

fn readAll(alloc: Allocator, io: std.Io, parts: []const []const u8) ![]u8 {
    const p = try std.fs.path.join(alloc, parts);
    defer alloc.free(p);
    return std.Io.Dir.readFileAlloc(.cwd(), io, p, alloc, .limited(max_file_bytes));
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

test "#1267: a rename moves the records to the new name and rewrites only this group's lines" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    const beta_before = try digestAt(alloc, io, &.{ state, "chat", "beta" }, &.{});
    const stream_before = try readAll(alloc, io, &.{ state, "chat", "chat.jsonl" });
    defer alloc.free(stream_before);
    try testing.expectEqual(@as(usize, 4), count(stream_before, "\"group\":\"alpha\""));

    const report = try rename(testOpts(alloc, io, state), "alpha", "gamma", .{});
    try testing.expect(report.changed > 0);

    // The old name is gone from every root, the new one is there.
    for ([_][]const u8{ "chat", "tasks", "stats" }) |root| {
        const old_dir = try std.fs.path.join(alloc, &.{ state, root, "alpha" });
        defer alloc.free(old_dir);
        const new_dir = try std.fs.path.join(alloc, &.{ state, root, "gamma" });
        defer alloc.free(new_dir);
        try testing.expect(!pathExists(io, old_dir));
        try testing.expect(pathExists(io, new_dir));
    }

    // The stream: this group's lines changed, nobody else's. Text that
    // merely contains the words is text.
    const stream = try readAll(alloc, io, &.{ state, "chat", "chat.jsonl" });
    defer alloc.free(stream);
    try testing.expectEqual(@as(usize, 0), count(stream, "\"group\":\"alpha\",\"from\""));
    try testing.expectEqual(@as(usize, 4), count(stream, "\"group\":\"gamma\""));
    try testing.expectEqual(count(stream_before, "\"group\":\"beta\""), count(stream, "\"group\":\"beta\""));
    try testing.expectEqual(@as(usize, 1), count(stream, "it says \\\"group\\\":\\\"alpha\\\" in the text"));

    // Another group's directory is not touched by a byte.
    const beta_after = try digestAt(alloc, io, &.{ state, "chat", "beta" }, &.{});
    try testing.expectEqualSlices(u8, &beta_before, &beta_after);

    // The panel comes back under the new name, with its numbers.
    var tasks: Tasks = .init(alloc, .{});
    defer tasks.deinit();
    var tl = try TaskLog.open(alloc, io, state);
    defer tl.deinit();
    tl.restore(&tasks);
    const panel = try tasks.inGroup(alloc, "gamma");
    defer alloc.free(panel);
    try testing.expectEqual(@as(usize, 2), panel.len);
    try testing.expectEqual(@as(u64, 1), panel[0].id);
    try testing.expectEqual(@as(u64, 2), panel[1].id);
    const gone = try tasks.inGroup(alloc, "alpha");
    defer alloc.free(gone);
    try testing.expectEqual(@as(usize, 0), gone.len);

    // The record reads back under the new name, every message of it.
    var cl = try ChatLog.open(alloc, io, state);
    defer cl.deinit();
    const page = try cl.history(alloc, "gamma", 0, 50, .{});
    defer ChatLog.freePage(alloc, page);
    try testing.expectEqual(@as(usize, 4), page.entries.len);
    const none = try cl.history(alloc, "alpha", 0, 50, .{});
    defer ChatLog.freePage(alloc, none);
    try testing.expectEqual(@as(usize, 0), none.entries.len);

    // Nothing left over: no intent, no lock, no work directory; and the
    // old files are in the backup.
    for ([_][]const u8{ intent_name, work_name }) |n| {
        const p = try std.fs.path.join(alloc, &.{ state, n });
        defer alloc.free(p);
        try testing.expect(!pathExists(io, p));
    }
    const backups = try std.fs.path.join(alloc, &.{ state, backup_name });
    defer alloc.free(backups);
    try testing.expect(pathExists(io, backups));
}

test "#1267: renaming there and back leaves the live records exactly as they were" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);
    const before = try digest(alloc, io, state, live_only);

    _ = try rename(testOpts(alloc, io, state), "alpha", "gamma", .{});
    const between = try digest(alloc, io, state, live_only);
    try testing.expect(!std.mem.eql(u8, &before, &between));

    var o = testOpts(alloc, io, state);
    o.now_ms = 1_800_000_000_001;
    _ = try rename(o, "gamma", "alpha", .{});
    const after = try digest(alloc, io, state, live_only);
    try testing.expectEqualSlices(u8, &before, &after);
}

test "#1267: the first rename's backup is the original files, byte for byte" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    // What the old files hold, kept the long way round.
    const reference = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, reference) catch {};
        alloc.free(reference);
    }
    try build(alloc, io, reference);

    _ = try rename(testOpts(alloc, io, state), "alpha", "gamma", .{});

    const backup = try std.fmt.allocPrint(alloc, "{s}/{s}/1800000000000-alpha-to-gamma", .{ state, backup_name });
    defer alloc.free(backup);
    for ([_][]const u8{ "chat", "tasks", "stats" }) |root| {
        const a_path = try std.fs.path.join(alloc, &.{ reference, root, "alpha" });
        defer alloc.free(a_path);
        const b_path = try std.fs.path.join(alloc, &.{ backup, root, "alpha" });
        defer alloc.free(b_path);
        const x = try digest(alloc, io, a_path, &.{});
        const y = try digest(alloc, io, b_path, &.{});
        try testing.expectEqualSlices(u8, &x, &y);
    }
    const s1 = try readAll(alloc, io, &.{ reference, "chat", "chat.jsonl" });
    defer alloc.free(s1);
    const s2 = try readAll(alloc, io, &.{ backup, "chat", "chat.jsonl" });
    defer alloc.free(s2);
    try testing.expectEqualStrings(s1, s2);
}

test "#1267: a name that already has records on disk is refused and nothing moves" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);
    const before = try digest(alloc, io, state, &.{lock_name});

    // `beta` has a directory in every root, as a destroyed group would.
    try testing.expectError(error.Blocked, rename(testOpts(alloc, io, state), "alpha", "beta", .{}));

    const after = try digest(alloc, io, state, &.{lock_name});
    try testing.expectEqualSlices(u8, &before, &after);
}

test "#1267: the handles are let go once, before anything is swapped" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    const Probe = struct {
        state: []const u8,
        io: std.Io,
        calls: usize = 0,
        old_dir_was_there: bool = false,

        fn close(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            var buf: [512]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}/chat/alpha", .{self.state}) catch return;
            self.old_dir_was_there = pathExists(self.io, p);
        }
    };
    var probe: Probe = .{ .state = state, .io = io };
    _ = try rename(testOpts(alloc, io, state), "alpha", "gamma", .{ .ctx = &probe, .close_handles = Probe.close });
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expect(probe.old_dir_was_there);
}

test "#1267: after a rename the log writes into the new files, not the backup" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    // The log is open across the rename, as the app's is.
    var cl = try ChatLog.open(alloc, io, state);
    defer cl.deinit();
    _ = cl.append("alpha", 1, "boss", t0 + 10 * day_ms, false, "written before");

    const Hook = struct {
        log: *ChatLog,
        fn close(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.log.closeHandles();
        }
    };
    var hook: Hook = .{ .log = &cl };
    _ = try rename(testOpts(alloc, io, state), "alpha", "gamma", .{ .ctx = &hook, .close_handles = Hook.close });
    cl.reopenHandles();

    _ = cl.append("gamma", 1, "boss", t0 + 11 * day_ms, false, "written after");

    const stream = try readAll(alloc, io, &.{ state, "chat", "chat.jsonl" });
    defer alloc.free(stream);
    try testing.expectEqual(@as(usize, 1), count(stream, "written after"));
    try testing.expectEqual(@as(usize, 1), count(stream, "written before"));

    const backup_stream = try std.fmt.allocPrint(alloc, "{s}/{s}/1800000000000-alpha-to-gamma/chat/chat.jsonl", .{ state, backup_name });
    defer alloc.free(backup_stream);
    const old = try std.Io.Dir.readFileAlloc(.cwd(), io, backup_stream, alloc, .limited(max_file_bytes));
    defer alloc.free(old);
    try testing.expectEqual(@as(usize, 0), count(old, "written after"));

    // And the day file: the new line is in the new directory's record.
    const page = try cl.history(alloc, "gamma", 0, 50, .{});
    defer ChatLog.freePage(alloc, page);
    try testing.expectEqual(@as(usize, 6), page.entries.len);
    try testing.expectEqualStrings("written after", page.entries[5].text);
}

test "#1267: a check that fails leaves the disk as it was" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);
    const before = try digest(alloc, io, state, &.{lock_name});

    for ([_]Sabotage{ .drop_line, .change_text, .change_other_group, .drop_task_event }) |how| {
        var o = testOpts(alloc, io, state);
        o.sabotage = how;
        try testing.expectError(error.Failed, rename(o, "alpha", "gamma", .{}));
        const after = try digest(alloc, io, state, &.{lock_name});
        try testing.expectEqualSlices(u8, &before, &after);
    }
}

test "#1267: every stopping point is recoverable, and lands where an uninterrupted rename does" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The answer: one that is never interrupted.
    const reference = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, reference) catch {};
        alloc.free(reference);
    }
    try build(alloc, io, reference);
    _ = try rename(testOpts(alloc, io, reference), "alpha", "gamma", .{});
    const want_live = try digest(alloc, io, reference, live_only);
    const want_backup = try digestAt(alloc, io, &.{ reference, backup_name }, &.{});

    var stop: usize = 1;
    var crashed_at_least_once = false;
    while (stop < 200) : (stop += 1) {
        const state = try scratch(alloc, io);
        defer {
            std.Io.Dir.cwd().deleteTree(io, state) catch {};
            alloc.free(state);
        }
        try build(alloc, io, state);

        var o = testOpts(alloc, io, state);
        o.crash_at = stop;
        // A process that is gone, so its lock can be taken over.
        if (rename(o, "alpha", "gamma", .{})) |_| {
            // Ran to the end without being stopped: there are no more
            // points to try.
            const live = try digest(alloc, io, state, live_only);
            try testing.expectEqualSlices(u8, &want_live, &live);
            break;
        } else |err| {
            try testing.expectEqual(error.InjectedCrash, err);
            crashed_at_least_once = true;
        }

        // The next start.
        const done = try recover(testOpts(alloc, io, state));

        // Stopped after the last step there is nothing left to finish; the
        // disk is then already the answer.
        if (!done.abandoned) {
            const live = try digest(alloc, io, state, live_only);
            testing.expectEqualSlices(u8, &want_live, &live) catch |e| {
                std.debug.print("stopped at step {d}: live records differ\n", .{stop});
                dump(alloc, io, state, "");
                std.debug.print("-- reference\n", .{});
                dump(alloc, io, reference, "");
                return e;
            };
            const bk = try digestAt(alloc, io, &.{ state, backup_name }, &.{});
            testing.expectEqualSlices(u8, &want_backup, &bk) catch |e| {
                std.debug.print("stopped at step {d}: backup differs\n", .{stop});
                return e;
            };
        }

        // Nothing left over, and a second recovery has nothing to do.
        for ([_][]const u8{ intent_name, work_name }) |n| {
            const p = try std.fs.path.join(alloc, &.{ state, n });
            defer alloc.free(p);
            try testing.expect(!pathExists(io, p));
        }
        const again = try recover(testOpts(alloc, io, state));
        try testing.expect(!again.finished and !again.abandoned);
    }
    try testing.expect(crashed_at_least_once);
    try testing.expect(stop < 200);
}

/// Open the lock file the way the rename does and take the lock: a second
/// holder, in this process.
fn holdLock(io: std.Io, state: []const u8) !std.Io.File {
    var buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ state, lock_name });
    const f = try std.Io.Dir.cwd().createFile(io, p, .{ .read = true, .truncate = false });
    errdefer f.close(io);
    try testing.expect(try f.tryLock(io, .exclusive));
    return f;
}

test "#1276: a lock somebody holds refuses a rename, and one let go does not" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    // Held by another open file description: what a second process holding
    // it looks like to the kernel. (Whether the kernel lets go when that
    // process dies is the kernel's, and is not tested here; the next two
    // tests are about what the program does with a lock file nobody holds.)
    const holder = try holdLock(io, state);
    const before = try digest(alloc, io, state, live_only);
    try testing.expectError(error.Locked, rename(testOpts(alloc, io, state), "alpha", "gamma", .{}));
    const after = try digest(alloc, io, state, live_only);
    try testing.expectEqualSlices(u8, &before, &after);

    holder.unlock(io);
    holder.close(io);
    _ = try rename(testOpts(alloc, io, state), "alpha", "gamma", .{});
}

test "#1276: a lock file nobody holds is not a lock, whatever it says" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    // What a killed holder leaves: the file, naming a process that is long
    // gone -- and, to be sure the contents are not what decides, naming one
    // that is this very process, and a time of a moment ago.
    const lock_path = try std.fs.path.join(alloc, &.{ state, lock_name });
    defer alloc.free(lock_path);
    const mine = try std.fmt.allocPrint(alloc, "{d} {d}\n", .{ @as(u32, @intCast(std.c.getpid())), @as(i64, 1_800_000_000_000) });
    defer alloc.free(mine);
    for ([_][]const u8{ "2000000000 1\n", mine, "garbage" }) |content| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = content });
        const state2 = try scratch(alloc, io);
        defer {
            std.Io.Dir.cwd().deleteTree(io, state2) catch {};
            alloc.free(state2);
        }
        try build(alloc, io, state2);
        const lp = try std.fs.path.join(alloc, &.{ state2, lock_name });
        defer alloc.free(lp);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lp, .data = content });
        _ = try rename(testOpts(alloc, io, state2), "alpha", "gamma", .{});
    }
}

/// Stop a rename after its intent is written and the new files are begun,
/// the way a kill would, and leave a lock file behind as one would.
fn killMidStaging(alloc: Allocator, io: std.Io, state: []const u8) !void {
    var o = testOpts(alloc, io, state);
    o.crash_at = 4;
    try testing.expectError(error.InjectedCrash, rename(o, "alpha", "gamma", .{}));
    const written = try readAll(alloc, io, &.{ state, intent_name });
    defer alloc.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"staging\"") != null);
}

test "#1276: a rename killed mid-staging is finished at the next start, whatever the lock file says" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);
    try killMidStaging(alloc, io, state);

    // The lock file the dead process left, with a time that is "now" -- the
    // case the age rule got wrong on Windows.
    const lock_path = try std.fs.path.join(alloc, &.{ state, lock_name });
    defer alloc.free(lock_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = "23424 1800000000000\n" });

    const done = try recoverWaiting(testOpts(alloc, io, state), .{ .max_ms = 0 });
    try testing.expect(done.finished);

    const live = try std.fs.path.join(alloc, &.{ state, "chat", "gamma" });
    defer alloc.free(live);
    try testing.expect(pathExists(io, live));
    const old = try std.fs.path.join(alloc, &.{ state, "chat", "alpha" });
    defer alloc.free(old);
    try testing.expect(!pathExists(io, old));
}

const Release = struct {
    file: std.Io.File,
    io: std.Io,
    after_ms: i64,

    fn run(self: *Release) void {
        self.io.sleep(.fromMilliseconds(self.after_ms), .awake) catch {};
        self.file.unlock(self.io);
        self.file.close(self.io);
    }
};

test "#1276: a start waits for a rename in progress and carries on when it ends" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);
    try killMidStaging(alloc, io, state);

    // Somebody else is holding the lock, and lets go in a moment.
    var rel: Release = .{ .file = try holdLock(io, state), .io = io, .after_ms = 150 };
    const t = try std.Thread.spawn(.{}, Release.run, .{&rel});

    const started = daylog.nowMs(io);
    const done = try recoverWaiting(testOpts(alloc, io, state), .{ .max_ms = 5_000, .step_ms = 10 });
    const took = daylog.nowMs(io) - started;
    t.join();

    try testing.expect(done.finished);
    // It did wait for the holder, and did not wait for the whole allowance.
    try testing.expect(took >= 100);
    try testing.expect(took < 4_000);
}

test "#1276: a holder that never lets go ends the wait with Locked, and nothing is touched" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);
    try killMidStaging(alloc, io, state);

    const holder = try holdLock(io, state);
    defer {
        holder.unlock(io);
        holder.close(io);
    }
    const before = try digest(alloc, io, state, &.{lock_name});

    const started = daylog.nowMs(io);
    try testing.expectError(error.Locked, recoverWaiting(testOpts(alloc, io, state), .{ .max_ms = 200, .step_ms = 20 }));
    const took = daylog.nowMs(io) - started;
    try testing.expect(took >= 180);

    const after = try digest(alloc, io, state, &.{lock_name});
    try testing.expectEqualSlices(u8, &before, &after);
}

test "#1267: an unreadable intent is not acted on" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);
    const ip = try std.fs.path.join(alloc, &.{ state, intent_name });
    defer alloc.free(ip);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ip, .data = "{not json" });
    const before = try digest(alloc, io, state, &.{lock_name});

    try testing.expectError(error.Anomaly, recover(testOpts(alloc, io, state)));
    try testing.expectError(error.Anomaly, rename(testOpts(alloc, io, state), "alpha", "gamma", .{}));

    const after = try digest(alloc, io, state, &.{lock_name});
    try testing.expectEqualSlices(u8, &before, &after);
}

test "#1267: a swap that finds a state it does not know stops" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    // Stopped after staging, then somebody makes the backup directory's
    // entry by hand: staged, source and backup all exist.
    var o = testOpts(alloc, io, state);
    o.crash_at = 10; // the intent has just been marked `swapping`
    try testing.expectError(error.InjectedCrash, rename(o, "alpha", "gamma", .{}));
    const written = try readAll(alloc, io, &.{ state, intent_name });
    defer alloc.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"swapping\"") != null);

    const clash = try std.fmt.allocPrint(alloc, "{s}/{s}/1800000000000-alpha-to-gamma/chat/alpha", .{ state, backup_name });
    defer alloc.free(clash);
    try std.Io.Dir.cwd().createDirPath(io, clash);

    try testing.expectError(error.Anomaly, recover(testOpts(alloc, io, state)));

    // The records are where they were: the swap did not guess.
    const live = try std.fs.path.join(alloc, &.{ state, "chat", "alpha" });
    defer alloc.free(live);
    try testing.expect(pathExists(io, live));
    // And the intent is still there for a person.
    const ip = try std.fs.path.join(alloc, &.{ state, intent_name });
    defer alloc.free(ip);
    try testing.expect(pathExists(io, ip));
}

// -- lines ------------------------------------------------------------------------

fn rewriteOne(alloc: Allocator, io: std.Io, line: []const u8) !struct { kind: Run.LineKind, text: []u8 } {
    var run: Run = .init(.{ .alloc = alloc, .io = io, .state_dir = "/nonexistent" });
    defer run.deinit();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const kind = try run.rewriteLine(line, "alpha", "gamma", &out);
    return .{ .kind = kind, .text = try alloc.dupe(u8, out.items) };
}

test "#1267: a line is changed by its group value alone" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Case = struct { in: []const u8, kind: Run.LineKind, out: []const u8 };
    const cases = [_]Case{
        // Field order and spacing are the line's own.
        .{ .in = "{\"seq\":1,\"group\":\"alpha\",\"text\":\"x\"}", .kind = .changed, .out = "{\"seq\":1,\"group\":\"gamma\",\"text\":\"x\"}" },
        .{ .in = "{\"text\":\"x\",\"group\" :  \"alpha\"  }", .kind = .changed, .out = "{\"text\":\"x\",\"group\" :  \"gamma\"  }" },
        .{ .in = "{\"group\":\"alpha\"}", .kind = .changed, .out = "{\"group\":\"gamma\"}" },
        // Words in the text are text.
        .{ .in = "{\"group\":\"alpha\",\"text\":\"\\\"group\\\":\\\"alpha\\\"\"}", .kind = .changed, .out = "{\"group\":\"gamma\",\"text\":\"\\\"group\\\":\\\"alpha\\\"\"}" },
        .{ .in = "{\"text\":\"\\\"group\\\":\\\"alpha\\\"\",\"group\":\"alpha\"}", .kind = .changed, .out = "{\"text\":\"\\\"group\\\":\\\"alpha\\\"\",\"group\":\"gamma\"}" },
        // Non-ASCII elsewhere in the line is not touched.
        .{ .in = "{\"group\":\"alpha\",\"text\":\"日本語 \\u00e9\"}", .kind = .changed, .out = "{\"group\":\"gamma\",\"text\":\"日本語 \\u00e9\"}" },
        // Another group's line, and lines that are not this group's to change.
        .{ .in = "{\"group\":\"beta\",\"text\":\"x\"}", .kind = .same, .out = "{\"group\":\"beta\",\"text\":\"x\"}" },
        .{ .in = "{\"group\":\"alphabet\"}", .kind = .same, .out = "{\"group\":\"alphabet\"}" },
        .{ .in = "{\"nested\":{\"group\":\"alpha\"}}", .kind = .passthrough, .out = "{\"nested\":{\"group\":\"alpha\"}}" },
        .{ .in = "{\"group\":7}", .kind = .passthrough, .out = "{\"group\":7}" },
        .{ .in = "{}", .kind = .passthrough, .out = "{}" },
        .{ .in = "", .kind = .passthrough, .out = "" },
        .{ .in = "[\"group\",\"alpha\"]", .kind = .passthrough, .out = "[\"group\",\"alpha\"]" },
        // Torn: nobody can read it back, so it is left exactly as it is.
        .{ .in = "{\"seq\":1,\"group\":\"alpha\",\"text\":\"cut o", .kind = .passthrough, .out = "{\"seq\":1,\"group\":\"alpha\",\"text\":\"cut o" },
    };
    for (cases) |c| {
        const got = try rewriteOne(alloc, io, c.in);
        defer alloc.free(got.text);
        try testing.expectEqual(c.kind, got.kind);
        try testing.expectEqualStrings(c.out, got.text);
    }
}

test "#1267: breaks between lines, and a missing last one, survive" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var run: Run = .init(.{ .alloc = alloc, .io = io, .state_dir = "/nonexistent" });
    defer run.deinit();

    const text = "{\"group\":\"alpha\",\"seq\":1}\n\n{\"group\":\"beta\"}\n{\"group\":\"alpha\"}";
    const r = try run.rewrite(text, "alpha", "gamma");
    try testing.expectEqualStrings("{\"group\":\"gamma\",\"seq\":1}\n\n{\"group\":\"beta\"}\n{\"group\":\"gamma\"}", r.bytes);
    try testing.expectEqual(@as(usize, 2), r.changed);
    try testing.expectEqual(@as(usize, 1), run.report.passthrough);
}

// -- a real state directory, when somebody has pointed this at a copy ---------------

fn copyTree(alloc: Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dst);
    var d = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const from = try std.fs.path.join(alloc, &.{ src, e.name });
        defer alloc.free(from);
        const to = try std.fs.path.join(alloc, &.{ dst, e.name });
        defer alloc.free(to);
        if (e.kind == .directory) {
            try copyTree(alloc, io, from, to);
        } else {
            const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, from, alloc, .limited(max_file_bytes));
            defer alloc.free(bytes);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = to, .data = bytes });
        }
    }
}

fn linesIn(alloc: Allocator, io: std.Io, parts: []const []const u8) !usize {
    const bytes = try readAll(alloc, io, parts);
    defer alloc.free(bytes);
    return std.mem.count(u8, bytes, "\n");
}

// **Runs only when `POLTER_RENAME_FIXTURE` names a directory holding
// copies of `chat`, `tasks` and `stats`** (a copy of somebody's real state
// directory -- never the real one), and `POLTER_RENAME_ORIGINAL` names an
// untouched second copy to compare against. It changes the first and reads
// the second. What it prints is counts and durations only: nothing in those
// records is for anyone else to read.
test "#1267: a real state directory survives every group being renamed and renamed back" {
    const alloc = testing.allocator;
    var env = try std.testing.environ.createMap(alloc);
    defer env.deinit();
    const fixture = env.get("POLTER_RENAME_FIXTURE") orelse return error.SkipZigTest;
    const original = env.get("POLTER_RENAME_ORIGINAL") orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const want = try digest(alloc, io, original, live_only);
    const start = try digest(alloc, io, fixture, live_only);
    try testing.expectEqualSlices(u8, &want, &start);

    var groups: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (groups.items) |g| alloc.free(g);
        groups.deinit(alloc);
    }
    {
        const chat_dir = try std.fs.path.join(alloc, &.{ fixture, "chat" });
        defer alloc.free(chat_dir);
        var d = try std.Io.Dir.cwd().openDir(io, chat_dir, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory) continue;
            try groups.append(alloc, try alloc.dupe(u8, e.name));
        }
    }

    var renamed: usize = 0;
    var skipped: usize = 0;
    var changed_lines: usize = 0;
    var slowest_ms: i64 = 0;
    var total_ms: i64 = 0;
    var i: usize = 0;
    while (i < groups.items.len) : (i += 1) {
        const g = groups.items[i];
        // Only names the program would have made; a directory somebody made
        // by hand is not a group.
        if (!@import("Chat.zig").isValidName(g)) {
            skipped += 1;
            continue;
        }

        const before_chat = digestAt(alloc, io, &.{ fixture, "chat", g }, &.{}) catch unreachable;
        _ = before_chat;

        const t_start = daylog.nowMs(io);
        const report = try rename(.{ .alloc = alloc, .io = io, .state_dir = fixture }, g, "zz-probe", .{});
        const took = daylog.nowMs(io) - t_start;
        slowest_ms = @max(slowest_ms, took);
        total_ms += took;
        changed_lines += report.changed;

        _ = try rename(.{ .alloc = alloc, .io = io, .state_dir = fixture, .now_ms = daylog.nowMs(io) + 1 }, "zz-probe", g, .{});

        const now = try digest(alloc, io, fixture, live_only);
        try testing.expectEqualSlices(u8, &want, &now);
        renamed += 1;
    }

    std.debug.print(
        "\nreal-state rename: {d} groups renamed and back, {d} skipped, {d} lines rewritten, slowest rename {d} ms, mean {d} ms\n",
        .{ renamed, skipped, changed_lines, slowest_ms, @divTrunc(total_ms, @as(i64, @intCast(@max(renamed, 1)))) },
    );
    try testing.expect(renamed > 0);

    // Stopped at every step, on the smallest group, and finished at the
    // next start: the live records come out the same as an uninterrupted
    // rename's, every time.
    var smallest: usize = 0;
    var smallest_bytes: u64 = std.math.maxInt(u64);
    var largest: usize = 0;
    var largest_bytes: u64 = 0;
    for (groups.items, 0..) |g, gi| {
        const p = try std.fs.path.join(alloc, &.{ fixture, "chat", g });
        defer alloc.free(p);
        var bytes: u64 = 0;
        var d = try std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            const st = try d.statFile(io, e.name, .{});
            bytes += st.size;
        }
        if (bytes < smallest_bytes) {
            smallest_bytes = bytes;
            smallest = gi;
        }
        if (bytes > largest_bytes) {
            largest_bytes = bytes;
            largest = gi;
        }
    }
    for ([_]usize{ smallest, largest }) |which| try crashPoints(alloc, io, fixture, groups.items[which]);
}

fn crashPoints(alloc: Allocator, io: std.Io, fixture: []const u8, g: []const u8) !void {
    const probe_dir = try std.fmt.allocPrint(alloc, "{s}-crash", .{fixture});
    defer alloc.free(probe_dir);
    defer std.Io.Dir.cwd().deleteTree(io, probe_dir) catch {};

    std.Io.Dir.cwd().deleteTree(io, probe_dir) catch {};
    try copyTree(alloc, io, fixture, probe_dir);
    _ = try rename(.{ .alloc = alloc, .io = io, .state_dir = probe_dir, .now_ms = 1_800_000_000_000 }, g, "zz-probe", .{});
    const answer = try digest(alloc, io, probe_dir, live_only);
    const answer_backup = try digestAt(alloc, io, &.{ probe_dir, backup_name }, &.{});

    var points: usize = 0;
    var stop: usize = 1;
    while (stop < 300) : (stop += 1) {
        std.Io.Dir.cwd().deleteTree(io, probe_dir) catch {};
        try copyTree(alloc, io, fixture, probe_dir);

        const o: Options = .{ .alloc = alloc, .io = io, .state_dir = probe_dir, .now_ms = 1_800_000_000_000, .crash_at = stop };
        if (rename(o, g, "zz-probe", .{})) |_| break else |err| try testing.expectEqual(error.InjectedCrash, err);
        points += 1;

        _ = try recover(.{ .alloc = alloc, .io = io, .state_dir = probe_dir, .now_ms = 1_800_000_000_000 });
        const live = try digest(alloc, io, probe_dir, live_only);
        const bk = try digestAt(alloc, io, &.{ probe_dir, backup_name }, &.{});
        try testing.expectEqualSlices(u8, &answer, &live);
        try testing.expectEqualSlices(u8, &answer_backup, &bk);
    }
    std.debug.print("real-state crash points: {d} tried, all finished to the same records and the same backup\n", .{points});
    try testing.expect(points > 5);
}

test "#1267: compareLines notices a line that is missing from the new file" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var run: Run = .init(.{ .alloc = alloc, .io = io, .state_dir = "/nonexistent" });
    defer run.deinit();

    const old_text = "{\"seq\":1,\"group\":\"alpha\"}\n{\"seq\":2,\"group\":\"alpha\"}\n";
    const good = "{\"seq\":1,\"group\":\"gamma\"}\n{\"seq\":2,\"group\":\"gamma\"}\n";
    _ = try run.compareLines(old_text, good, "alpha", "gamma", true);

    // One line short, in either direction.
    try testing.expectError(error.Failed, run.compareLines(old_text, "{\"seq\":1,\"group\":\"gamma\"}\n", "alpha", "gamma", true));
    try testing.expectError(error.Failed, run.compareLines("{\"seq\":1,\"group\":\"alpha\"}\n", good, "alpha", "gamma", true));
}

test "#1267: the replayed panel has to match as well as the lines" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    var run: Run = .init(testOpts(alloc, io, state));
    defer run.deinit();

    // Staged properly, the panel matches.
    _ = try run.stageAndCheck("alpha", "gamma");
    try run.checkTasks("alpha", "gamma", "alpha", "gamma");

    // A task event gone from the new file: the panel would come back one
    // task short, whatever the line check says.
    const f = try std.fs.path.join(alloc, &.{ state, work_name, "tasks", "gamma", "2023-11-15.jsonl" });
    defer alloc.free(f);
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, f, alloc, .limited(max_file_bytes));
    defer alloc.free(bytes);
    const cut = std.mem.lastIndexOf(u8, bytes[0 .. bytes.len - 1], "\n").? + 1;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f, .data = bytes[0..cut] });
    try testing.expectError(error.Failed, run.checkTasks("alpha", "gamma", "alpha", "gamma"));

    // Both events of the second task gone: a task short, which is the count
    // and not the content.
    const cut2 = std.mem.lastIndexOf(u8, bytes[0 .. cut - 1], "\n").? + 1;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f, .data = bytes[0..cut2] });
    try testing.expectError(error.Failed, run.checkTasks("alpha", "gamma", "alpha", "gamma"));
}

test "#1282: every way a rename can be refused is reported as itself" {
    try testing.expectEqual(error.RenameBlocked, refusal(error.Blocked));
    try testing.expectEqual(error.RenameBusy, refusal(error.Locked));
    try testing.expectEqual(error.RenameUnfinished, refusal(error.Anomaly));
    try testing.expectEqual(error.RenameFailed, refusal(error.Failed));
    try testing.expectEqual(error.OutOfMemory, refusal(error.OutOfMemory));

    // And what really happens: a live holder is Busy, an unfinished rename
    // on disk is Unfinished -- neither is "could not be moved".
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    const holder = try holdLock(io, state);
    const busy = rename(testOpts(alloc, io, state), "alpha", "gamma", .{});
    try testing.expectError(error.Locked, busy);
    try testing.expectEqual(error.RenameBusy, refusal(if (busy) |_| unreachable else |e| e));
    holder.unlock(io);
    holder.close(io);

    const ip = try std.fs.path.join(alloc, &.{ state, intent_name });
    defer alloc.free(ip);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ip, .data = "{\"phase\":\"bogus\"}" });
    const unfinished = rename(testOpts(alloc, io, state), "alpha", "gamma", .{});
    try testing.expectError(error.Anomaly, unfinished);
    try testing.expectEqual(error.RenameUnfinished, refusal(if (unfinished) |_| unreachable else |e| e));
}

test "#1282: an intent nobody can read gives a problem that says what and where" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state = try scratch(alloc, io);
    defer {
        std.Io.Dir.cwd().deleteTree(io, state) catch {};
        alloc.free(state);
    }
    try build(alloc, io, state);

    // Exactly what the Windows test machine did to the host at start.
    const ip = try std.fs.path.join(alloc, &.{ state, intent_name });
    defer alloc.free(ip);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ip, .data = "{\"op\":\"group_rename\",\"from\":\"x\",\"to\":\"y\",\"phase\":\"bogus\"}" });
    const before = try digest(alloc, io, state, &.{lock_name});

    const err = recoverWaiting(testOpts(alloc, io, state), .{ .max_ms = 0 });
    try testing.expectError(error.Anomaly, err);

    const text = try problemText(alloc, state, startupProblem(error.Anomaly));
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "does not know how to continue") != null);
    try testing.expect(std.mem.indexOf(u8, text, state) != null);
    try testing.expect(std.mem.indexOf(u8, text, "NOT loaded") != null);

    // Nothing was touched while finding out.
    const after = try digest(alloc, io, state, &.{lock_name});
    try testing.expectEqualSlices(u8, &before, &after);

    // Every cause has words of its own.
    const causes = [_]Error{ error.Locked, error.Anomaly, error.Failed, error.Blocked, error.InjectedCrash, error.OutOfMemory };
    for (causes, 0..) |a, i| for (causes[i + 1 ..]) |b| {
        try testing.expect(!std.mem.eql(u8, startupProblem(a), startupProblem(b)));
    };
}
