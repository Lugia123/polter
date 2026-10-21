//! Stopping what a pane's kill line said to stop (task 1993, #1985 §3.2):
//! `SIGTERM` to every process `ledger.stoppable` names, a wait of up to
//! `grace_ms` for them to go, then `SIGKILL` to whatever is still there.
//!
//! Off the app thread (`start`): the wait is seconds long. What is left
//! for the app -- the terminal's modes put back, the line in the pane, the
//! people told -- happens when `fire` says it is done.
//!
//! macOS and Linux only: a Windows pane is stopped through its Job Object
//! (task 1993 P6).

const Stopper = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How long after `SIGTERM` before `SIGKILL`.
pub const grace_ms: u64 = 5_000;
/// How often the wait looks whether they have gone.
const look_ms: u64 = 100;

pub const Outcome = struct {
    /// How many were sent `SIGTERM`.
    termed: u32,
    /// How many were still there after `grace_ms` and got `SIGKILL`.
    killed: u32,
};

/// Whether `pid` is a process (a zombie counts: it is gone once reaped).
pub fn alive(pid: u32) bool {
    if (comptime builtin.os.tag == .windows) return false;
    const p: std.c.pid_t = std.math.cast(std.c.pid_t, pid) orelse return false;
    const rc = std.c.kill(p, @enumFromInt(0));
    if (rc == 0) return true;
    // There, but not ours to signal: still a process.
    return std.posix.errno(rc) == .PERM;
}

fn signal(pid: u32, sig: std.posix.SIG) bool {
    const p: std.c.pid_t = std.math.cast(std.c.pid_t, pid) orelse return false;
    std.posix.kill(p, sig) catch return false;
    return true;
}

/// Stop `pids`, waiting on this thread. What `start` runs; called directly
/// by the tests.
pub fn stop(io: Io, pids: []const u32) Outcome {
    if (comptime builtin.os.tag == .windows) return .{ .termed = 0, .killed = 0 };
    var out: Outcome = .{ .termed = 0, .killed = 0 };
    for (pids) |pid| {
        if (signal(pid, std.posix.SIG.TERM)) out.termed += 1;
    }
    var waited: u64 = 0;
    while (waited < grace_ms) : (waited += look_ms) {
        const left = for (pids) |pid| {
            if (alive(pid)) break true;
        } else false;
        if (!left) return out;
        io.sleep(.fromMilliseconds(look_ms), .awake) catch return out;
    }
    for (pids) |pid| {
        if (alive(pid) and signal(pid, std.posix.SIG.KILL)) out.killed += 1;
    }
    return out;
}

pub const Job = struct {
    io: Io,
    alloc: Allocator,
    /// Owned by the job; freed when it is done.
    pids: []u32,
    /// The pane, handed back to `fire`.
    id: u64,
    fire: *const fn (ctx: *anyopaque, id: u64, out: Outcome) void,
    ctx: *anyopaque,
};

/// Stop `job.pids` on a thread of its own and call `job.fire` from it.
pub fn start(job: Job) std.Thread.SpawnError!void {
    const t = try std.Thread.spawn(.{}, run, .{job});
    t.detach();
}

fn run(job: Job) void {
    const out = stop(job.io, job.pids);
    job.alloc.free(job.pids);
    job.fire(job.ctx, job.id, out);
}

const testing = std.testing;
const procscan = @import("procscan.zig");
const ledger = @import("ledger.zig");
const judge = @import("judge.zig");
const limits = @import("limits.zig");

test "1993: a pane over its kill line loses its agent, and keeps its shell" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The pane's child (`login`'s place) runs a shell, which runs an
    // "agent" that takes 300 MB and sits on it. After the agent the shell
    // goes on: a pane at its prompt.
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "/bin/sh -c 'perl -e \"\\$x = q(a) x 300_000_000; sleep 120\"; sleep 120'; sleep 120" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const root: u32 = @intCast(child.id.?);
    defer {
        // Whatever is left of the tree, then the child itself.
        if (procscan.scan(testing.allocator)) |procs| {
            defer testing.allocator.free(procs);
            if (ledger.stoppable(testing.allocator, procs, .{ .id = 1, .root = root, .tty = null })) |rest| {
                defer testing.allocator.free(rest);
                for (rest) |pid| _ = signal(pid, std.posix.SIG.KILL);
            } else |_| {}
            for (procs) |p| if (p.ppid == root) {
                _ = signal(p.pid, std.posix.SIG.KILL);
            };
        } else |_| {}
        child.kill(io);
    }
    const pane: ledger.Pane = .{ .id = 0x1993, .root = root, .tty = null };

    // A kill line of 100 MB: 300 MB is past one and a half times it, so
    // the judge kills at the first reading that sees it, with no wait.
    var why: []const u8 = "";
    const lim = blk: {
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"memory\": {\"kill\": \"100M\"}}", .{});
        defer p.deinit();
        break :blk try limits.parse(p.value, &why);
    };
    var state: judge.State = .fresh;
    var verdict: ?judge.Event = null;
    var shell: u32 = 0;
    var agent: u32 = 0;
    var t: u64 = 0;
    while (t < 20_000 and verdict == null) : (t += 200) {
        try io.sleep(.fromMilliseconds(200), .awake);
        const procs = try procscan.scan(testing.allocator);
        defer testing.allocator.free(procs);
        const us = try ledger.account(testing.allocator, procs, &.{pane});
        defer testing.allocator.free(us);
        for (procs) |p| {
            if (p.ppid == root) shell = p.pid;
            if (std.mem.eql(u8, p.name(), "perl")) agent = p.pid;
        }
        const v = judge.step(&state, &lim, .{ .mem = us[0].mem, .procs = us[0].procs }, @intCast(t), procscan.physicalMemory().?, .none);
        verdict = v.kill();
    }
    const kill = verdict orelse return error.NeverOverTheLine;
    try testing.expect(kill.isFast());
    try testing.expect(agent != 0 and shell != 0);

    const procs = try procscan.scan(testing.allocator);
    defer testing.allocator.free(procs);
    const targets = try ledger.stoppable(testing.allocator, procs, pane);
    defer testing.allocator.free(targets);
    try testing.expect(std.mem.indexOfScalar(u32, targets, agent) != null);
    try testing.expect(std.mem.indexOfScalar(u32, targets, shell) == null);
    try testing.expect(std.mem.indexOfScalar(u32, targets, root) == null);

    const out = stop(io, targets);
    try testing.expect(out.termed >= 1);
    // perl goes on SIGTERM; its shell reaps it and is still there, and so
    // is the pane's own process.
    var gone = false;
    for (0..50) |_| {
        if (!alive(agent)) {
            gone = true;
            break;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    try testing.expect(gone);
    try testing.expect(alive(shell));
    try testing.expect(alive(root));
}

test "1993: what does not go on SIGTERM gets SIGKILL after the grace" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const pid: u32 = @intCast(child.id.?);
    var reaped = false;
    // Not `child.kill`: that is `SIGTERM`, which this child ignores.
    defer if (!reaped) {
        _ = signal(pid, std.posix.SIG.KILL);
        _ = child.wait(io) catch {};
    };
    // Give the shell the moment it needs to set its trap.
    try io.sleep(.fromMilliseconds(300), .awake);
    const out = stop(io, &.{pid});
    try testing.expectEqual(@as(u32, 1), out.termed);
    try testing.expectEqual(@as(u32, 1), out.killed);
    // Reaped here, as the shell reaps an agent in a pane -- without
    // blocking, so a process that did not go fails rather than hangs.
    var status: c_int = 0;
    for (0..20) |_| {
        if (std.c.waitpid(@intCast(pid), &status, std.c.W.NOHANG) == @as(std.c.pid_t, @intCast(pid))) {
            reaped = true;
            break;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    try testing.expect(reaped);
    try testing.expect(!alive(pid));
}
