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
    pub fn rearm(self: *Reaper, pid: ?std.process.Child.Id, ms: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pid = pid;
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
                    log.warn("plugin {s}: out of time, stopping it", .{self.key});
                    self.fired.store(true, .release);
                    kill(pid) catch |err| {
                        log.warn(
                            "plugin {s}: could not stop it err={}",
                            .{ self.key, err },
                        );
                    };
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
fn sleeper(io: std.Io) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
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
    _ = child.wait(io) catch {};
    reaper.retire();
    if (thread) |t| t.join();

    try testing.expect(reaper.killed());
    // Would sit here for a minute if `hurry` only took effect at the
    // original deadline, which is exactly the shutdown cost it exists to
    // avoid.
    const took = started.durationTo(.now(io, .awake)).toMilliseconds();
    try testing.expect(took < 5 * std.time.ms_per_s);
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
    reaper.rearm(child.id, 60 * std.time.ms_per_s);

    const thread = std.Thread.spawn(.{}, Reaper.run, .{&reaper}) catch null;
    _ = child.wait(io) catch {};
    reaper.retire();
    if (thread) |t| t.join();

    try testing.expect(reaper.killed());
}
