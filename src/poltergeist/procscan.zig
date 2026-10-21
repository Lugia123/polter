//! One reading of every process on the machine that this user may read:
//! its parent, its controlling terminal and how much memory it holds
//! (task 1993, #1985). What a pane's process tree is made of is worked out
//! from this by `ledger.zig`; this file only asks the system.
//!
//! **Why the whole machine and not each pane's tree.** A pane's tree is its
//! child's descendants, and macOS has no call that lists a process's
//! descendants -- only every process and each one's parent. So the machine
//! is read once and every pane is accounted from the same reading, rather
//! than the machine being read once per pane. Measured on the machine this
//! was designed on (1011 processes, 473 readable): listing 0.15 ms, every
//! parent 0.84 ms, every footprint 1.52 ms -- about 2.5 ms a reading, every
//! two seconds, off the app thread (`ResourceSampler`).
//!
//! macOS: `proc_listallpids`, then per pid `proc_pidinfo(PROC_PIDTBSDINFO)`
//! (the layout `process_info.zig` measured: parent, controlling terminal's
//! device, name) and `proc_pid_rusage(RUSAGE_INFO_V4)`'s `ri_phys_footprint`
//! -- the figure Activity Monitor calls "Memory" and the one jetsam judges
//! by. A process of another user, `/usr/bin/login` among them, cannot be
//! read: it is left out, and whatever runs under it is still found by its
//! own parent link (`ledger.zig`).
//!
//! Elsewhere nothing is read (an empty table): Windows accounts a pane by
//! the Job Object it runs in (`os/job.zig`), and Linux is not a target of
//! this feature.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Proc = struct {
    pid: u32,
    ppid: u32,
    /// The controlling terminal's device, or `no_tty`.
    tdev: u32,
    /// Bytes, `ri_phys_footprint`; zero when it could not be read.
    footprint: u64,
    /// The short name the kernel keeps (`p_comm`), up to 16 bytes.
    comm: [16]u8,
    comm_len: u8,
    /// User and system time so far, nanoseconds (task 2015); zero when it
    /// could not be read.
    cpu_ns: u64 = 0,
    /// When it started, wall-clock milliseconds; zero when unknown.
    start_ms: i64 = 0,

    pub fn name(self: *const Proc) []const u8 {
        return self.comm[0..self.comm_len];
    }
};

/// `e_tdev` of a process with no controlling terminal (`NODEV`).
pub const no_tty: u32 = 0xFFFF_FFFF;

/// Every readable process, in `alloc`. Empty where nothing is read.
pub fn scan(alloc: Allocator) Allocator.Error![]Proc {
    return switch (builtin.os.tag) {
        .macos => darwin(alloc),
        else => &.{},
    };
}

/// `MEMORYSTATUSEX` (sysinfoapi.h), for the Windows reading below.
const MemoryStatusEx = extern struct {
    dwLength: u32,
    dwMemoryLoad: u32,
    ullTotalPhys: u64,
    ullAvailPhys: u64,
    ullTotalPageFile: u64,
    ullAvailPageFile: u64,
    ullTotalVirtual: u64,
    ullAvailVirtual: u64,
    ullAvailExtendedVirtual: u64,
};

comptime {
    std.debug.assert(@sizeOf(MemoryStatusEx) == 64);
}

const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MemoryStatusEx) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

/// The machine's physical memory in bytes, or null where it is not read:
/// `hw.memsize` on macOS, `GlobalMemoryStatusEx` on Windows (task 1993 P6,
/// for lines drawn as a share of the machine).
pub fn physicalMemory() ?u64 {
    if (builtin.os.tag == .windows) {
        var m: MemoryStatusEx = std.mem.zeroes(MemoryStatusEx);
        m.dwLength = @sizeOf(MemoryStatusEx);
        if (win.GlobalMemoryStatusEx(&m) == .FALSE) return null;
        return m.ullTotalPhys;
    }
    if (builtin.os.tag != .macos) return null;
    var v: u64 = 0;
    var len: usize = @sizeOf(u64);
    if (std.c.sysctlbyname("hw.memsize", &v, &len, null, 0) != 0) return null;
    return v;
}

/// What the machine's memory holds in use, bytes, or null where it is not
/// read (task 2015, the performance page's first line). macOS: what
/// Activity Monitor calls "Memory Used" -- app memory (internal pages less
/// the purgeable), wired, and compressed -- from `host_statistics64`.
/// Windows: the physical memory less what is available.
pub fn machineUsed() ?u64 {
    if (builtin.os.tag == .windows) {
        var m: MemoryStatusEx = std.mem.zeroes(MemoryStatusEx);
        m.dwLength = @sizeOf(MemoryStatusEx);
        if (win.GlobalMemoryStatusEx(&m) == .FALSE) return null;
        return m.ullTotalPhys -| m.ullAvailPhys;
    }
    if (builtin.os.tag != .macos) return null;
    var vm: VmStatistics64 = undefined;
    var count: u32 = @sizeOf(VmStatistics64) / @sizeOf(u32);
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, &vm, &count) != 0) return null;
    var page: u64 = 0;
    var len: usize = @sizeOf(u64);
    if (std.c.sysctlbyname("hw.pagesize", &page, &len, null, 0) != 0) return null;
    const app = @as(u64, vm.internal_page_count) -| vm.purgeable_count;
    return (app + vm.wire_count + vm.compressor_page_count) * page;
}

/// Swap in use, bytes; null where it is not read (Windows: its page file is
/// not a figure a person reads as swap).
pub fn swapUsed() ?u64 {
    if (builtin.os.tag != .macos) return null;
    var x: XswUsage = undefined;
    var len: usize = @sizeOf(XswUsage);
    if (std.c.sysctlbyname("vm.swapusage", &x, &len, null, 0) != 0) return null;
    return x.xsu_used;
}

/// `vm_statistics64` (mach/vm_statistics.h).
const VmStatistics64 = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

/// `struct xsw_usage` (sys/sysctl.h).
const XswUsage = extern struct {
    xsu_total: u64,
    xsu_avail: u64,
    xsu_used: u64,
    xsu_pagesize: u32,
    xsu_encrypted: bool,
};

comptime {
    // The SDK's sizes: 152 (`HOST_VM_INFO64_COUNT` is 38 natural_t) and 32.
    std.debug.assert(@sizeOf(VmStatistics64) == 152);
    std.debug.assert(@sizeOf(XswUsage) == 32);
}

const HOST_VM_INFO64: c_int = 4;
extern "c" fn mach_host_self() u32;
extern "c" fn host_statistics64(host: u32, flavor: c_int, info: *anyopaque, count: *u32) c_int;

/// The kernel's memory pressure level, `kern.memorystatus_vm_pressure_level`:
/// 1 normal, 2 warn, 4 critical. Null where it is not read.
pub fn pressureLevel() ?u32 {
    if (builtin.os.tag != .macos) return null;
    var v: u32 = 0;
    var len: usize = @sizeOf(u32);
    if (std.c.sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &len, null, 0) != 0) return null;
    return v;
}

// ---------------------------------------------------------------- macOS

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
    // The same layout `process_info.zig` measured against the SDK.
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
}

const PROC_PIDTBSDINFO: c_int = 3;
const RUSAGE_INFO_V4: c_int = 4;
/// `ri_phys_footprint`'s place in `rusage_info_v4`: a 16-byte uuid, then
/// seven `u64`s before it (user time, system time, idle wakeups, interrupt
/// wakeups, pageins, wired size, resident size). Measured: a reading of
/// this machine's processes at this offset summed to what Activity Monitor
/// shows.
const footprint_offset = 16 + 7 * 8;
/// `ri_user_time` and `ri_system_time`: the first two after the uuid. In
/// the units of `mach_absolute_time`, not nanoseconds, on Apple silicon
/// (one tick is 125/3 ns there): `mach_timebase_info` turns them.
const user_time_offset = 16;
const system_time_offset = 24;

const MachTimebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *MachTimebase) c_int;

/// Mach ticks to nanoseconds, by the machine's timebase.
fn ticksToNs(ticks: u64, tb: MachTimebase) u64 {
    if (tb.denom == 0) return ticks;
    return @intCast(@as(u128, ticks) * tb.numer / tb.denom);
}

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: ?*anyopaque) c_int;

fn darwin(alloc: Allocator) Allocator.Error![]Proc {
    // The count first, with room for the processes started in between.
    const n = proc_listallpids(null, 0);
    if (n <= 0) return &.{};
    const pids = try alloc.alloc(c_int, @as(usize, @intCast(n)) + 64);
    defer alloc.free(pids);
    const got = proc_listallpids(pids.ptr, @intCast(pids.len * @sizeOf(c_int)));
    if (got <= 0) return &.{};

    var out: std.ArrayListUnmanaged(Proc) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, @intCast(got));
    var usage: [512]u8 align(8) = undefined;
    var tb: MachTimebase = .{ .numer = 1, .denom = 1 };
    _ = mach_timebase_info(&tb);
    for (pids[0..@min(pids.len, @as(usize, @intCast(got)))]) |pid| {
        if (pid <= 0) continue;
        var info: ProcBsdInfo = undefined;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, @sizeOf(ProcBsdInfo)) != @sizeOf(ProcBsdInfo)) continue;
        var footprint: u64 = 0;
        var cpu_ns: u64 = 0;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, &usage) == 0) {
            footprint = std.mem.readInt(u64, usage[footprint_offset..][0..8], .little);
            const ticks = std.mem.readInt(u64, usage[user_time_offset..][0..8], .little) +
                std.mem.readInt(u64, usage[system_time_offset..][0..8], .little);
            cpu_ns = ticksToNs(ticks, tb);
        }
        var p: Proc = .{
            .pid = info.pbi_pid,
            .ppid = info.pbi_ppid,
            .tdev = info.e_tdev,
            .footprint = footprint,
            .comm = info.pbi_comm,
            .comm_len = 0,
            .cpu_ns = cpu_ns,
            .start_ms = @intCast(info.pbi_start_tvsec * 1000 + info.pbi_start_tvusec / 1000),
        };
        p.comm_len = @intCast(std.mem.indexOfScalar(u8, &info.pbi_comm, 0) orelse info.pbi_comm.len);
        out.appendAssumeCapacity(p);
    }
    return out.toOwnedSlice(alloc);
}

test "procscan: this process is in the reading, with its parent and some memory" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const procs = try scan(testing.allocator);
    defer testing.allocator.free(procs);
    const me: u32 = @intCast(std.c.getpid());
    const parent: u32 = @intCast(std.c.getppid());
    const mine = for (procs) |p| {
        if (p.pid == me) break p;
    } else return error.NotFound;
    try testing.expectEqual(parent, mine.ppid);
    // A running test binary holds more than a megabyte.
    try testing.expect(mine.footprint > 1 << 20);
    try testing.expect(mine.name().len > 0);
    try testing.expect(physicalMemory().? > 1 << 30);
    const level = pressureLevel().?;
    try testing.expect(level == 1 or level == 2 or level == 4);
}

test "2015: the machine's memory in use is under all of it, and swap is read" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const phys = physicalMemory().?;
    const used = machineUsed().?;
    // A machine running this holds something, and not more than it has.
    try testing.expect(used > 256 << 20);
    try testing.expect(used < phys);
    _ = swapUsed().?;
}

test "2015: a process's CPU time is in nanoseconds, and its start is when it started" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const me: u32 = @intCast(std.c.getpid());
    const before = try readOne(testing.allocator, me);
    const ru0 = cpuSelf();
    // Spin until the kernel's own account, in microseconds, says this
    // process has used 200 ms more -- however long that takes under load;
    // a fixed wall time measured nothing when the machine was busy and
    // this ran at background priority.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const t0 = std.Io.Timestamp.now(io, .awake);
    var x: u64 = 0;
    while (cpuSelf() - ru0 < 200 * std.time.ns_per_ms) {
        for (0..100_000) |_| x +%= 1;
        if (t0.untilNow(io, .awake).toSeconds() > 30) return error.SkipZigTest;
    }
    std.mem.doNotOptimizeAway(x);
    const after = try readOne(testing.allocator, me);
    const ru1 = cpuSelf();
    const spent = after.cpu_ns - before.cpu_ns;
    const said = ru1 - ru0;
    // Ticks read as nanoseconds would be 24 times too few on Apple
    // silicon. The two accounts are of the same time, read at slightly
    // different moments: within a fifth of each other.
    try testing.expect(spent * 5 > said * 4);
    try testing.expect(spent * 4 < said * 5);
    const wall: i64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    try testing.expect(after.start_ms <= wall);
    try testing.expect(after.start_ms > wall - 24 * 3600 * 1000);
}

/// This process's user and system time by `getrusage`, nanoseconds: the
/// account in units nobody has to convert.
fn cpuSelf() u64 {
    var ru: std.c.rusage = undefined;
    _ = std.c.getrusage(std.c.rusage.SELF, &ru);
    const us = @as(u64, @intCast(ru.utime.sec)) * 1_000_000 + @as(u64, @intCast(ru.utime.usec)) +
        @as(u64, @intCast(ru.stime.sec)) * 1_000_000 + @as(u64, @intCast(ru.stime.usec));
    return us * 1000;
}

fn readOne(alloc: Allocator, pid: u32) !Proc {
    const procs = try scan(alloc);
    defer alloc.free(procs);
    for (procs) |p| if (p.pid == pid) return p;
    return error.NotFound;
}
