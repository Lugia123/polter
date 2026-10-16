//! What the system says about one process: whether it is a zombie, and when
//! it started (task 1668).
//!
//! **Why "is it running" needs more than `kill(pid, 0)`.** An agent's
//! connection to Polter dropping while its program still runs is reported
//! (`Bus.considerLinks`), and the first cut asked the question with signal
//! 0. On the test machine (#1669 c1669-12) a Codex that had quit with
//! `/exit` was reported as still running 40 s later, and its pid was gone
//! from the process table by the end of the run: signal 0 answers yes for a
//! process that has exited and not been reaped, and for whatever process
//! the number was given to next. So the state is read (a zombie is not
//! running), and the start time is kept beside the pid and compared (the
//! same number on a later process is not the same program).
//!
//! macOS: `proc_pidinfo(PROC_PIDTBSDINFO)`, whose layout was measured with
//! `zig cc` against the SDK's `<sys/proc_info.h>`: 136 bytes, `pbi_status`
//! at 4, `pbi_start_tvsec` at 120, `pbi_start_tvusec` at 128; `SZOMB` is 5.
//! For a zombie it fails with ESRCH (measured: a forked child that has
//! exited and not been collected, while `kill(pid, 0)` still answers 0),
//! which `of` returns as null -- not running.
//! Linux: `/proc/<pid>/stat`, state and `starttime` (field 22). Elsewhere --
//! Windows, where no pid is read for this at all -- nothing is known.

const std = @import("std");
const builtin = @import("builtin");

pub const Info = struct {
    /// It has exited and its parent has not collected it.
    zombie: bool,
    /// When it started, in a unit of this system's own: microseconds since
    /// the epoch on macOS, clock ticks since boot on Linux. Only ever
    /// compared with another reading of the same kind.
    started: u64,
};

/// What is known of `pid`, or null when there is no such process or it
/// could not be read -- which callers take as "not running": a report that
/// a program still runs is only worth making when that is certain.
pub fn of(pid: u64) ?Info {
    return switch (builtin.os.tag) {
        .macos => darwin(pid),
        .linux => linux(pid),
        else => null,
    };
}

const ProcBsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [16]u8,
    pbi_name: [32]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};

comptime {
    // As measured (see the top of this file).
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_status") == 4);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_start_tvsec") == 120);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_start_tvusec") == 128);
}

const PROC_PIDTBSDINFO: c_int = 3;
const SZOMB: u32 = 5;

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;

fn darwin(pid: u64) ?Info {
    const p = std.math.cast(c_int, pid) orelse return null;
    if (p <= 0) return null;
    var info: ProcBsdInfo = undefined;
    const n = proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, @sizeOf(ProcBsdInfo));
    if (n != @sizeOf(ProcBsdInfo)) return null;
    if (info.pbi_pid != p) return null;
    return .{
        .zombie = info.pbi_status == SZOMB,
        .started = info.pbi_start_tvsec *| std.time.us_per_s +| info.pbi_start_tvusec,
    };
}

fn linux(pid: u64) ?Info {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [1024]u8 = undefined;
    const fd = std.c.open(path, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    return parseLinuxStat(buf[0..@intCast(n)]);
}

/// `pid (comm) S ppid ... starttime ...`: the command may hold spaces and
/// parentheses, so the fields are counted from the last `)`. The state is
/// field 3 and `starttime` field 22.
fn parseLinuxStat(stat: []const u8) ?Info {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    const state = fields.next() orelse return null;
    // Fields 4 to 21, then 22.
    var i: usize = 4;
    while (i < 22) : (i += 1) _ = fields.next() orelse return null;
    const start = fields.next() orelse return null;
    return .{
        .zombie = state.len > 0 and state[0] == 'Z',
        .started = std.fmt.parseInt(u64, start, 10) catch return null,
    };
}

const testing = std.testing;

test "1668: a Linux stat line is read from its last parenthesis" {
    const line = "4242 (co dex) (x)) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 3 0 987654 123 45";
    const info = parseLinuxStat(line).?;
    try testing.expect(!info.zombie);
    try testing.expectEqual(@as(u64, 987654), info.started);
    const dead = parseLinuxStat("7 (sh) Z 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 55 0 0").?;
    try testing.expect(dead.zombie);
    try testing.expect(parseLinuxStat("7 (sh) S 1") == null);
}

test "1668: this process is running, and its start time reads the same twice" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const me: u64 = @intCast(std.c.getpid());
    const a = of(me) orelse return error.TestExpectedInfo;
    const b = of(me) orelse return error.TestExpectedInfo;
    try testing.expect(!a.zombie);
    try testing.expect(a.started > 0);
    try testing.expectEqual(a.started, b.started);
    // A pid nothing has.
    try testing.expect(of(0) == null);
    try testing.expect(of(std.math.maxInt(i32)) == null);
}

test "1668: a child that has exited and not been collected is not running, though signal 0 says it is" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pid = std.c.fork();
    if (pid == 0) std.c._exit(0);
    try testing.expect(pid > 0);
    defer _ = std.c.waitpid(pid, null, 0);
    // Give it the moment it takes to exit; it cannot be collected before
    // `waitpid`, so it stays a zombie until then.
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        const info = of(@intCast(pid)) orelse break;
        if (info.zombie) break;
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    } else return error.TestStillRunning;
    // Measured on macOS 26: a zombie has no task, so `proc_pidinfo` fails
    // with ESRCH -- while signal 0 still succeeds, which is the answer the
    // first cut took for "still running".
    try testing.expectEqual(@as(c_int, 0), std.c.kill(pid, @enumFromInt(0)));
    if (of(@intCast(pid))) |info| try testing.expect(info.zombie);
}
