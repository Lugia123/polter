//! Stopping a child we started, and never signalling somebody else's.
//!
//! **A signal rather than `std.process.Child.kill`.** That call also reaps,
//! and reaping from over here would leave the thread that is waiting on the
//! child with no child left to wait for. One reaper, one waiter: this
//! thread sends the signal, the other one collects the corpse.
//!
//! **Why there is a lock at all.** A pid names a process only for as long
//! as that process is unreaped. Once the waiter has reaped it the kernel is
//! free to hand the same number to somebody else, and a signal sent a
//! moment later lands on a stranger. `retire` takes the same lock the
//! signal is sent under, so a signal is either sent while the child is
//! definitely alive or not sent at all -- there is no third case.
//!
//! One reaper serves both plugin lifetimes, which is why this is a file of
//! its own rather than a private struct in `Plugin.zig`. A one-shot plugin
//! gets one child and one deadline and is done. A resident one hands over a
//! fresh child on every restart (`rearm`), pushes the deadline out each
//! time the plugin answers (`allow`), and at shutdown asks for the deadline
//! to be now (`hurry`).

const builtin = @import("builtin");
const std = @import("std");

const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.poltergeist);

/// Stop a child, hard, without reaping it.
///
/// **Windows has no signals**, and the nearest thing to `SIGKILL` is
/// `TerminateProcess`: both end the process where it stands, with no chance
/// to clean up and nothing it can install to refuse. The one difference
/// that matters here is which name the process is held by -- a pid on
/// POSIX, a handle on Windows -- and a handle is the *stronger* of the two
/// for this file's purposes, because it names one process for as long as it
/// is open and so cannot be reused out from under us the way a reaped pid
/// can. The lock in this file is still what POSIX needs; Windows simply
/// gets a guarantee it did not have to ask for.
pub fn kill(id: std.process.Child.Id) !void {
    switch (builtin.os.tag) {
        .windows => {
            const k32 = internal_os.windows.exp.kernel32;

            // 1 rather than 0: a process killed from outside did not
            // succeed at whatever it was doing, and anything reading the
            // exit code should be able to tell.
            if (k32.TerminateProcess(id, 1) == internal_os.windows.FALSE) {
                return error.PermissionDenied;
            }
        },
        else => try std.posix.kill(id, std.posix.SIG.KILL),
    }
}

/// A child and everything it starts, as one thing to end (task 3237).
///
/// **A pid is one process; what a plugin leaves behind is a tree.** Killing
/// the child alone left whatever it had started running: a helper that does
/// not read the plugin's stdin inherits nothing from its death and simply
/// stays, and on POSIX it is reparented to init and never heard from again.
/// The two systems hold a tree differently, and each one is asked for the
/// thing it actually has:
///
/// - **POSIX: a process group of its own.** `spawn` is given `pgid = 0`,
///   which makes the child a group leader, and everything it starts belongs
///   to that group unless it deliberately leaves (`setsid`). `kill(-pgid)`
///   is the whole tree.
/// - **Windows: a Job Object** (`os/job.zig`) with
///   `KILL_ON_JOB_CLOSE`. The child is started suspended, put in the job,
///   and only then let run -- that order is the whole point, because a
///   process that starts something before it is assigned to a job has
///   started something the job does not hold. `TerminateJobObject` ends it;
///   and because the handle is the job, the system ends every member when
///   Polter's last handle closes, even on a path that never reaches code of
///   ours at all (a crash, or the Windows host's quit that finds itself
///   inside a tick).
///
/// The graceful half is not here: it is end of input on the child's stdin
/// (`Resident.endForQuit`), offered before this is reached. A plugin that
/// takes it exits by itself and nothing here runs.
pub const Tree = struct {
    const WinHandle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else void;

    /// POSIX: the group the child leads, which is its own pid because
    /// `spawn` was asked for a new group. Zero when the spawn did not get
    /// one; killing is then skipped, because `kill(-0)` signals our own
    /// process group -- Polter itself.
    ///
    /// An `i64` and not `std.c.pid_t`: that one is a `HANDLE` on Windows,
    /// where this struct still exists (it lives in every `Resident`), and a
    /// field whose default is `0` would not compile there.
    group: i64 = 0,

    /// Windows: the job holding the child and everything it starts.
    job: ?WinHandle = null,

    /// `Live` holds a pointer to this. Written under `Live.mutex`.
    listed: bool = false,

    /// The child's number, for asking whether it is still there once its
    /// handle is gone (on Windows `wait` closes it). Zero before a child
    /// and after one is collected; `kill(-0)` would be our own group.
    pid: std.atomic.Value(u32) = .init(0),

    /// Make what the child will be held by. Call before the spawn.
    pub fn begin(self: *Tree) void {
        if (comptime builtin.os.tag == .windows) self.job = internal_os.job.win.create();
    }

    /// Whether the child must be spawned suspended so that it can be put in
    /// the tree before it runs anything. Windows with a job, and only then:
    /// a suspended POSIX child would need a signal this file has no way to
    /// send through `std.process`.
    pub fn mustSuspend(self: *const Tree) bool {
        return self.job != null;
    }

    /// Hand the freshly spawned child to the tree, and let it run if
    /// `mustSuspend` made it wait.
    pub fn adopt(self: *Tree, child: *const std.process.Child) void {
        const id = child.id orelse return;
        switch (builtin.os.tag) {
            .windows => {
                self.pid.store(internal_os.job.win.pidOf(id), .release);
                if (self.job) |job| {
                    if (!internal_os.job.win.assign(job, id)) {
                        // Nested jobs need Windows 8; a job with a limit
                        // that refuses nesting is the other way here. It is
                        // let go all the same, and what is lost is only the
                        // guarantee about what it starts.
                        log.warn(
                            "a child could not be put in its job; it runs without one",
                            .{},
                        );
                    }
                    internal_os.job.win.letRun(child.thread_handle);
                }
            },
            else => {
                const pid: u32 = @intCast(id);
                self.pid.store(pid, .release);
                self.group = pid;
            },
        }
    }

    /// Whether the child is still running.
    pub fn running(self: *const Tree) bool {
        const pid = self.pid.load(.acquire);
        return pid != 0 and pidRunning(pid);
    }

    /// Stop everything in the tree. No `SIGTERM` first: the graceful end
    /// was end of input, and a child still here after that is one that did
    /// not take it.
    pub fn kill(self: *const Tree) void {
        switch (builtin.os.tag) {
            .windows => if (self.job) |job| {
                if (!internal_os.job.win.terminate(job)) {
                    log.warn("could not terminate a child's job; it may outlive us", .{});
                }
            },
            else => {
                if (self.group <= 0) return;
                // The negative form is the group: `kill(-pgid, ...)`.
                const pgid = std.math.cast(std.c.pid_t, -self.group) orelse return;
                std.posix.kill(pgid, std.posix.SIG.KILL) catch |err| switch (err) {
                    error.ProcessNotFound => {},
                    else => log.warn(
                        "could not end a child's process group err={}",
                        .{err},
                    ),
                };
            },
        }
    }

    /// Give the handle back. On Windows this is also what takes a helper
    /// the child left behind with it (`KILL_ON_JOB_CLOSE`); on POSIX the
    /// group needs no handle. Idempotent.
    pub fn close(self: *Tree) void {
        if (comptime builtin.os.tag == .windows) {
            if (self.job) |job| internal_os.job.win.close(job);
            self.job = null;
        }
    }
};

/// Whether the process with this **number** is still running.
///
/// `kill` takes a pid; `exitCode` takes a `Child.Id`, which is a handle on
/// Windows. This is the one that can be asked about a process named on
/// paper -- the reading a test can take, and the line in the log a person
/// can check against Task Manager.
pub fn pidRunning(pid: u32) bool {
    switch (builtin.os.tag) {
        .windows => {
            const k32 = internal_os.windows.exp.kernel32;
            const h = k32.OpenProcess(0x1000, .FALSE, pid) orelse return false;
            defer _ = k32.CloseHandle(h);
            var code: internal_os.windows.DWORD = 0;
            if (k32.GetExitCodeProcess(h, &code) == internal_os.windows.FALSE) return false;
            // `STILL_ACTIVE` is 259. A process whose real exit code is 259
            // reads as running here; nothing started by Polter exits with
            // it, and the alternative is a thread query nothing needs.
            return code == 259;
        },
        else => {
            const p: std.c.pid_t = std.math.cast(std.c.pid_t, pid) orelse return false;
            const rc = std.c.kill(p, @enumFromInt(0));
            // There, but not ours to signal: still a process.
            if (rc != 0) return std.posix.errno(rc) == .PERM;
            return true;
        },
    }
}

/// End the process with this number, hard.
///
/// `kill` takes a `Child.Id`, which is a handle on Windows; this takes the
/// number `pidRunning` asks about. The two together are what a reading
/// needs: something exists, and then it does not.
pub fn pidKill(pid: u32) void {
    switch (builtin.os.tag) {
        .windows => {
            const k32 = internal_os.windows.exp.kernel32;
            // `PROCESS_TERMINATE`.
            const h = k32.OpenProcess(0x0001, .FALSE, pid) orelse return;
            defer _ = k32.CloseHandle(h);
            _ = k32.TerminateProcess(h, 1);
        },
        else => {
            const p: std.c.pid_t = std.math.cast(std.c.pid_t, pid) orelse return;
            _ = std.c.kill(p, std.posix.SIG.KILL);
        },
    }
}

/// Every child the core started whose own thread has not collected it yet.
///
/// **This is the quit-time backstop, and nothing else uses it.** A resident
/// has a thread that lives to collect its child; an adapter has a `defer`.
/// Both are gone the instant the process is -- a `defer` on a thread that
/// dies with `exit` never runs -- so the one thing that can still stop the
/// child then is a list that somebody else walks. Quitting walks it
/// (`App.writeDownBeforeQuit`), after offering every resident end of input
/// and waiting a moment for the ones that take it.
///
/// A **pointer** registry: each tree lives on the stack of the thread that
/// spawned it, and the list shares the pointer rather than a copy. `add`
/// and `forget` are the owner's; `endAll` is the quitter's. The mutex is
/// also what keeps `close` from running under a `kill` of the same handle
/// (`forget` closes under it).
///
/// Fixed size, and a count that overflowed is said out loud rather than
/// dropped: the app runs a single-digit number of residents and adapters at
/// once, so 64 is not a limit anything real reaches.
pub const Live = struct {
    const max = 64;

    var mutex: std.Io.Mutex = .init;
    var items: [max]?*Tree = @splat(null);

    /// Put `tree` on the list. False when the list is full.
    pub fn add(io: std.Io, tree: *Tree) bool {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        for (&items) |*slot| {
            if (slot.* != null) continue;
            slot.* = tree;
            tree.listed = true;
            return true;
        }
        return false;
    }

    /// The owner is done with `tree`: take it off the list, and give back
    /// whatever the tree holds (on Windows, closing the job is also what
    /// ends a helper the child left in it). Idempotent.
    pub fn forget(io: std.Io, tree: *Tree) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (tree.listed) {
            for (&items) |*slot| if (slot.* == tree) {
                slot.* = null;
                break;
            };
            tree.listed = false;
        }
        tree.close();
        tree.pid.store(0, .release);
    }

    /// Stop one tree, unless its owner has already forgotten it -- which
    /// means it has been collected and its handle is about to be given
    /// back, so there is nothing left to stop.
    ///
    /// Under the same mutex as `forget`, and that is the point: a handle
    /// closed by one thread while another is inside `TerminateJobObject`
    /// with it is exactly the kind of "the number names something else now"
    /// this file exists to avoid.
    pub fn killOne(io: std.Io, tree: *Tree) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (!tree.listed) return;
        tree.kill();
    }

    /// Stop every tree still on the list. How many there were.
    pub fn endAll(io: std.Io) u32 {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        var n: u32 = 0;
        for (items) |slot| {
            const tree = slot orelse continue;
            tree.kill();
            n += 1;
        }
        return n;
    }

    /// How many are listed now. For the test that checks `add`/`forget`
    /// balance; the quit path reads `endAll`'s own count.
    pub fn count(io: std.Io) u32 {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        var n: u32 = 0;
        for (items) |slot| if (slot != null) {
            n += 1;
        };
        return n;
    }
};

/// Our ends of a child's pipes, which a fired deadline cuts as well as
/// signalling the child.
///
/// **A kill does not end a read on its own.** It ends the process, and the
/// read ends when the *last* holder of the pipe's other end lets go -- which
/// is the child only while nothing else has a copy. On Windows something
/// else often does: `spawn` creates the child's ends inheritable, nothing
/// serialises one spawn against another, and a plugin or a shell started in
/// that moment walks off with a copy that keeps the pipe open for as long as
/// it lives. #1672 is that shape: the spawn trace shows four plugins
/// started inside the same 16ms, and the one that exited by itself was
/// never read to its end -- which process kept the copy was not
/// identified. A plugin that exits by itself then leaves the host
/// reading a pipe nobody will ever write to or close, and `TerminateProcess`
/// on the corpse answers `ACCESS_DENIED` and changes nothing. A child that
/// forks a helper without redirecting it does the same thing on POSIX.
///
/// So the end that is blocking is cut from our side, the way #26 ended the
/// pty reader: by not caring who holds the far end.
pub const Ends = struct {
    /// The end we read the child's answers from.
    read: ?std.Io.File.Handle = null,

    /// The end we write to the child on. Windows only: a POSIX pipe has no
    /// way to fail a write in flight from another thread.
    write: ?std.Io.File.Handle = null,

    pub const none: Ends = .{};
};

/// Make a read blocked on `ends.read`, and every read after it, end at once;
/// on Windows, a write blocked on `ends.write` as well.
///
/// Windows: both are the server ends of named pipes (`spawn` makes them with
/// `NtCreateNamedPipeFile`), and `DisconnectNamedPipe` ends what is in
/// flight with `STATUS_PIPE_DISCONNECTED` -- an ordinary error, read as "the
/// child is gone" -- and is sticky. Never `CancelIoEx`: see `Resident.hush`.
///
/// POSIX: `shutdown(SHUT_RD)`, which needs a socket. A pipe answers
/// `ENOTSOCK` and nothing happens, which is no worse than before this
/// existed.
pub fn sever(ends: Ends) void {
    switch (builtin.os.tag) {
        .windows => {
            const k32 = internal_os.windows.exp.kernel32;
            if (ends.read) |h| _ = k32.DisconnectNamedPipe(h);
            if (ends.write) |h| _ = k32.DisconnectNamedPipe(h);
        },
        else => if (ends.read) |fd| {
            _ = std.c.shutdown(fd, std.c.SHUT.RD);
        },
    }
}

/// The exit code of a child that has already exited, for a log line; null
/// while it is running, and always null off Windows (there the only way to
/// ask is to reap, and reaping is not this file's to do).
fn exitedWith(id: std.process.Child.Id) ?u32 {
    if (comptime builtin.os.tag != .windows) return null;
    const k32 = internal_os.windows.exp.kernel32;
    if (k32.WaitForSingleObject(id, 0) != 0) return null;
    var code: internal_os.windows.DWORD = 0;
    if (k32.GetExitCodeProcess(id, &code) == internal_os.windows.FALSE) return null;
    return code;
}

/// A number for this child that means something to a person reading a log.
///
/// `Child.Id` is the process *handle* on Windows, and printing a handle
/// gives a pointer nobody can look up in Task Manager. `GetProcessId` turns
/// it back into the number that is on screen everywhere else.
pub fn pidNumber(id: std.process.Child.Id) u32 {
    return switch (builtin.os.tag) {
        // Zero if the handle has lost the right to ask, which is a fine
        // answer for a log line and not worth a branch at the call site.
        .windows => internal_os.windows.exp.kernel32.GetProcessId(id),
        else => @intCast(id),
    };
}

/// How often the clock is looked at.
///
/// Polled rather than slept through in one go, so that a plugin finishing
/// in 50ms does not leave a thread parked for the whole ten seconds, and so
/// that a `hurry` at shutdown is acted on within a tick rather than
/// whenever the original deadline happened to fall.
pub const tick_ms: u64 = 50;

pub const Reaper = struct {
    io: std.Io,

    /// Borrowed, for log lines only. Must outlive the reaper.
    key: []const u8,

    mutex: std.Io.Mutex = .init,

    /// Null once the waiter has reaped: nothing left to signal.
    pid: ?std.process.Child.Id = null,

    /// Cut along with the signal. Valid for exactly as long as `pid` is
    /// non-null: whoever closes them retires the reaper first, and this is
    /// only read under the lock.
    ends: Ends = .none,

    /// What to end along with the child when the deadline fires (task 3237).
    /// Null for a caller that holds no tree (a one-shot test fixture).
    ///
    /// Borrowed, and read only under this reaper's lock. The owner retires
    /// the reaper before it closes the tree (`Tree.close`), so a fired
    /// deadline never reaches a handle somebody has given back.
    tree: ?*Tree = null,

    /// Milliseconds still allowed before the kill. Zero means "at the next
    /// tick".
    left_ms: u64 = 0,

    /// Sticky. Once set, no child handed to this reaper afterwards gets any
    /// grace -- which is what closes the window between spawning a child
    /// and noticing that shutdown began. Without it a resident host could
    /// fork one last plugin a microsecond before being told to stop, and
    /// that child would hold the whole shutdown open for its full timeout.
    stopping: bool = false,

    /// Whether this reaper is the reason the child is gone. Read by the
    /// waiter after it has joined, so an ordinary atomic is enough.
    fired: std.atomic.Value(bool) = .init(false),

    pub fn init(
        io: std.Io,
        key: []const u8,
        pid: ?std.process.Child.Id,
        ms: u64,
    ) Reaper {
        return .{
            .io = io,
            .key = key,
            .pid = pid,
            .left_ms = ms,
        };
    }

    /// Take charge of a freshly spawned child, replacing whatever came
    /// before.
    ///
    /// A `hurry` that already happened is honoured: the new child gets no
    /// grace either, because the reason to stop has not gone away just
    /// because the process has changed.
    pub fn rearm(self: *Reaper, pid: ?std.process.Child.Id, ms: u64, ends: Ends) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pid = pid;
        self.ends = ends;
        self.left_ms = if (self.stopping) 0 else ms;
    }

    /// Give the live child `ms` more from now.
    ///
    /// What a resident plugin earns by answering: the timeout bounds one
    /// exchange, not the whole life of the process.
    pub fn allow(self: *Reaper, ms: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.stopping) self.left_ms = ms;
    }

    /// Kill it at the next tick, and every child after this one too.
    pub fn hurry(self: *Reaper) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopping = true;
        self.left_ms = 0;
    }

    /// The child has been reaped; there is no longer anything to signal.
    pub fn retire(self: *Reaper) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pid = null;
        self.ends = .none;
    }

    /// Whether this reaper is the reason the child is gone.
    pub fn killed(self: *const Reaper) bool {
        return self.fired.load(.acquire);
    }

    /// The thread body: `std.Thread.spawn(.{}, Reaper.run, .{&reaper})`.
    ///
    /// Looks at the clock **before** sleeping rather than after. Sleeping
    /// first would mean a `hurry` issued a microsecond after the thread
    /// parked still waits out a whole tick, and shutdown pays that tick for
    /// no reason at all.
    pub fn run(self: *Reaper) void {
        while (true) {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);

                const pid = self.pid orelse return;
                if (self.left_ms == 0) {
                    // Inside the lock: see the module comment. Between
                    // dropping it and calling `kill` the pid could already
                    // belong to somebody else.
                    self.fired.store(true, .release);
                    if (exitedWith(pid)) |code| {
                        log.warn(
                            "plugin {s}: it exited by itself (code {d}) " ++
                                "without answering; cutting its pipes",
                            .{ self.key, code },
                        );
                    } else {
                        log.warn("plugin {s}: out of time, stopping it", .{self.key});
                        // The child and whatever it started. On POSIX the
                        // group is what a helper of the plugin is in; on
                        // Windows the job. `kill` below is still the direct
                        // child, for a tree the spawn never got.
                        if (self.tree) |tree| tree.kill();
                        kill(pid) catch |err| {
                            log.warn(
                                "plugin {s}: could not stop it err={}; " ++
                                    "cutting its pipes instead",
                                .{ self.key, err },
                            );
                        };
                    }

                    // Whatever the kill did. Without this a read whose
                    // far end somebody else holds waits for ever, and the
                    // thread waiting in it is the one that would restart
                    // the plugin and tell the person.
                    sever(self.ends);
                    return;
                }
            }

            std.Io.sleep(self.io, .fromMilliseconds(tick_ms), .awake) catch return;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.left_ms -|= tick_ms;
        }
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// A child that will sit there until something stops it.
///
/// **`/bin/sh` is not on Windows, and these three tests were red for that and
/// only that.** The product already had its Windows arm -- `kill` reaches for
/// `TerminateProcess` -- but the fixture could not start a child there, so
/// that arm had never once been executed. Translating this one function is
/// what runs it for the first time.
///
/// **Not `timeout` on Windows.** It reads the console input handle and
/// refuses outright when stdin is redirected, which is exactly how these
/// tests run it (`.stdin = .ignore`). Pinging loopback waits without a
/// console and without touching a network.
///
/// The Windows name is bare rather than absolute, unlike the paths this
/// project insists on in product code. The stakes differ: a product that
/// cannot find its helper fails as a user's secret quietly not resolving,
/// while a fixture that cannot find its helper fails as a red test with the
/// spawn error in it. Loud is an acceptable failure mode for a fixture.
fn sleeper(io: std.Io) !std.process.Child {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "ping.exe", "-n", "31", "127.0.0.1" },
        else => &.{ "/bin/sh", "-c", "sleep 30" },
    };
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Assert that the child was ended by `kill`, rather than having finished.
///
/// **Green is not the criterion; having run `kill` is.** A test that only
/// looks at `reaper.killed()` reads a flag this file sets before it does
/// anything, so it would stay green on a platform where the signal never
/// landed -- which is the state Windows was in until this fixture could
/// start a child at all.
///
/// The two systems say it differently, and both are the product's own
/// choice rather than something invented here. `kill` passes `1` to
/// `TerminateProcess` on purpose -- its comment: "a process killed from
/// outside did not succeed at whatever it was doing, and anything reading
/// the exit code should be able to tell" -- and the sleeper exits `0` when
/// left alone, so `1` is not a value it can reach by itself. On POSIX
/// `SIGKILL` shows up as a signal, which no ordinary exit produces.
fn expectEndedByKill(term: std.process.Child.Term) !void {
    switch (builtin.os.tag) {
        .windows => try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, term),
        else => try testing.expectEqual(
            std.process.Child.Term{ .signal = std.posix.SIG.KILL },
            term,
        ),
    }
}

test "a reaper that is retired never signals" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var child = try sleeper(io);

    // A deadline far past anything this test will take, so the only way
    // `fired` could be set is the bug this guards: signalling a pid after
    // the waiter has reaped it, when the number may name somebody else.
    var reaper: Reaper = .init(io, "retired", child.id, 60 * std.time.ms_per_s);
    const thread = std.Thread.spawn(.{}, Reaper.run, .{&reaper}) catch null;

    reaper.retire();
    if (thread) |t| t.join();
    try testing.expect(!reaper.killed());

    if (child.id) |pid| kill(pid) catch {};
    _ = child.wait(io) catch {};
}

test "a reaper told to hurry does not wait out its deadline" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var child = try sleeper(io);

    var reaper: Reaper = .init(io, "hurry", child.id, 60 * std.time.ms_per_s);
    const thread = std.Thread.spawn(.{}, Reaper.run, .{&reaper}) catch null;

    const started: std.Io.Timestamp = .now(io, .awake);
    reaper.hurry();

    // Returns because the process is gone, not because anything here has a
    // timeout of its own.
    const term = try child.wait(io);
    reaper.retire();
    if (thread) |t| t.join();

    try testing.expect(reaper.killed());
    // `killed()` is this file's own flag. This is the child agreeing.
    try expectEndedByKill(term);
    // Would sit here for a minute if `hurry` only took effect at the
    // original deadline, which is exactly the shutdown cost it exists to
    // avoid.
    const took = started.durationTo(.now(io, .awake)).toMilliseconds();
    try testing.expect(took < 5 * std.time.ms_per_s);
}

test "3237: a tree kill takes what the child started, not just the child" {
    // **The defect, in the form a reading can hold.** The child starts a
    // helper of its own and then waits; killing the child alone leaves the
    // helper running, reparented and never heard from again. The helper's
    // pid is read from a file the child writes, so what is checked is a
    // process that really exists rather than anything this file thinks.
    //
    // The tree is the group `spawn` makes (`pgid = 0`), which is what
    // `Resident` and `agent_cli` ask for. The `alive` assertion before the
    // kill is the negative control: it says the helper was really there,
    // so a kill that never happened cannot pass this by killing nothing.
    if (comptime builtin.os.tag != .windows) {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var raw: [6]u8 = undefined;
        io.random(&raw);
        const dir = try std.fmt.allocPrint(testing.allocator, "/tmp/polter-tree-{x}", .{&raw});
        defer testing.allocator.free(dir);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const pidfile = try std.fmt.allocPrint(testing.allocator, "{s}/grand", .{dir});
        defer testing.allocator.free(pidfile);

        const script = try std.fmt.allocPrint(
            testing.allocator,
            "sleep 300 & echo $! > {s}; wait",
            .{pidfile},
        );
        defer testing.allocator.free(script);

        var tree: Tree = .{};
        tree.begin();
        var child = try std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", script },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        });
        tree.adopt(&child);

        const grand = waitForPid(io, pidfile, 3 * std.time.ms_per_s) orelse {
            if (child.id) |id| kill(id) catch {};
            _ = child.wait(io) catch {};
            tree.close();
            return error.TestExpectedGrandchild;
        };
        // It is really there, and the kill below is what has to end it.
        try testing.expect(pidRunning(grand));

        tree.kill();
        // Read first, then take everything away: a floor that made `kill`
        // do nothing must fail here rather than sit in `wait` for the
        // minute the fixture sleeps.
        const gone = waitForGone(io, grand, 3 * std.time.ms_per_s);
        if (child.id) |id| kill(id) catch {};
        if (!gone) pidKill(grand);
        _ = child.wait(io) catch {};
        tree.close();

        // The reading: it was there before the kill, and it is not after.
        try testing.expect(gone);
    }

    // **Windows: the job.** The child here is `cmd.exe` running `ping`,
    // which is a process the job has to hold for this to mean anything:
    // one member would prove only that the direct child was stopped.
    if (comptime builtin.os.tag == .windows) {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var tree: Tree = .{};
        tree.begin();
        try testing.expect(!tree.mustSuspend() or tree.job != null);
        var child = try std.process.spawn(io, .{
            .argv = &.{ "cmd.exe", "/c", "ping.exe -n 31 127.0.0.1" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
            .start_suspended = tree.mustSuspend(),
        });
        tree.adopt(&child);

        // Two: `cmd.exe` and the ping it is waiting for.
        var members: usize = 0;
        var waited: u64 = 0;
        while (waited < 3 * std.time.ms_per_s) : (waited += 25) {
            members = countMembers(&tree);
            if (members >= 2) break;
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
        }
        try testing.expect(members >= 2);

        tree.kill();
        if (child.id) |id| kill(id) catch {};
        _ = child.wait(io) catch {};
        members = countMembers(&tree);
        waited = 0;
        while (members != 0 and waited < 3 * std.time.ms_per_s) : (waited += 25) {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            members = countMembers(&tree);
        }
        tree.close();
        try testing.expectEqual(@as(usize, 0), members);
    }
}

test "3237: the quit list holds a child until its owner forgets it" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const before = Live.count(io);

    var a: Tree = .{};
    var b: Tree = .{};
    try testing.expect(Live.add(io, &a));
    try testing.expect(Live.add(io, &b));
    try testing.expectEqual(before + 2, Live.count(io));

    Live.forget(io, &a);
    try testing.expectEqual(before + 1, Live.count(io));

    // The quitter's reading: one tree still listed, and it is the one
    // whose owner has not forgotten it yet.
    try testing.expect(Live.endAll(io) >= 1);

    Live.forget(io, &b);
    try testing.expectEqual(before, Live.count(io));
}

fn countMembers(tree: *const Tree) usize {
    if (comptime builtin.os.tag == .windows) {
        const job = tree.job orelse return 0;
        const members = internal_os.job.win.members(testing.allocator, job) catch return 0;
        defer testing.allocator.free(members);
        return members.len;
    }
    return 0;
}

/// The pid the child wrote down, once it has: null if it never did.
fn waitForPid(io: std.Io, path: []const u8, limit_ms: u64) ?u32 {
    var waited: u64 = 0;
    while (waited <= limit_ms) : (waited += 25) {
        if (readPid(io, path)) |pid| return pid;
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch return null;
    }
    return readPid(io, path);
}

fn readPid(io: std.Io, path: []const u8) ?u32 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        testing.allocator,
        .limited(64),
    ) catch return null;
    defer testing.allocator.free(bytes);
    const text = std.mem.trim(u8, bytes, " \t\r\n");
    return std.fmt.parseInt(u32, text, 10) catch null;
}

/// Whether `pid` is still there after waiting for it to go, at most
/// `limit_ms`.
fn waitForGone(io: std.Io, pid: u32, limit_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < limit_ms) : (waited += 25) {
        if (!pidRunning(pid)) return true;
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch return false;
    }
    return !pidRunning(pid);
}

test "a child handed over after hurry gets no grace either" {
    // The window shutdown would otherwise leave open: `stop` is called
    // while the resident host is between two spawns, and the child born a
    // microsecond later holds the whole exit open for its full timeout.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var reaper: Reaper = .init(io, "late", null, 0);
    reaper.hurry();

    var child = try sleeper(io);
    reaper.rearm(child.id, 60 * std.time.ms_per_s, .none);

    const thread = std.Thread.spawn(.{}, Reaper.run, .{&reaper}) catch null;
    const term = try child.wait(io);
    reaper.retire();
    if (thread) |t| t.join();

    try testing.expect(reaper.killed());
    try expectEndedByKill(term);
}
