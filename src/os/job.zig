//! One Windows Job Object per terminal (task 1993 P6, #1985 §1): what a
//! pane's processes are on Windows, where there is no controlling terminal
//! and no `ppid` walk worth trusting.
//!
//! The shell is started suspended, put in a job of its own, and let go
//! (`Command.startWindows`). Everything it starts is in the job with it,
//! however far it wanders from its parent, so:
//! - **closing the pane stops all of it** (`terminate`). Until this,
//!   closing a tab ran `TerminateProcess` on the shell alone and left
//!   whatever it had started running (`Exec.killCommand`);
//! - the job is also `KILL_ON_JOB_CLOSE`: should Polter itself go, the
//!   system stops them when the last handle closes;
//! - a reading of the pane is the job's process list (`members`), and the
//!   kill line stops everything in it but the shell (`stoppable`).
//!
//! Memory is each process's `PrivateUsage` (its commit), summed -- the
//! figure Task Manager shows as "Commit size", and the one a machine runs
//! out of.
//!
//! The pure half (`summarise`, `stoppable`, the layouts) is tested on any
//! machine; the calls are Windows-only and judged on the test machine.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// One process in a pane's job.
pub const Member = struct {
    pid: u32,
    /// Bytes: `PrivateUsage`; zero when it could not be read.
    private: u64,
    /// The image's file name, narrowed to ASCII (`?` past it), cut at 16
    /// bytes as `p_comm` is on macOS.
    name: [16]u8,
    name_len: u8,

    pub fn nameOf(self: *const Member) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// What a pane's job comes to: the same figures `ledger.Usage` carries.
pub const Reading = struct {
    mem: u64,
    procs: u32,
    top: [16]u8,
    top_len: u8,
    top_count: u32,
    top_mem: u64,
};

pub fn summarise(members: []const Member) Reading {
    var r: Reading = .{ .mem = 0, .procs = 0, .top = @splat(0), .top_len = 0, .top_count = 0, .top_mem = 0 };
    for (members) |m| {
        r.mem += m.private;
        r.procs += 1;
    }
    for (members) |m| {
        var count: u32 = 0;
        var total: u64 = 0;
        for (members) |k| if (std.ascii.eqlIgnoreCase(k.nameOf(), m.nameOf())) {
            count += 1;
            total += k.private;
        };
        if (total > r.top_mem) {
            r.top_mem = total;
            r.top_count = count;
            r.top_len = m.name_len;
            @memcpy(r.top[0..m.name_len], m.nameOf());
        }
    }
    return r;
}

/// What the kill line stops on Windows: everything in the job but the shell
/// (the process the pane started) and the console host, which draws the
/// pane -- stopping that would leave the shell with no console. Pids, in
/// `alloc`. There is no `SIGTERM` to send first on Windows.
pub fn stoppable(alloc: Allocator, members: []const Member, shell_pid: u32) Allocator.Error![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    errdefer out.deinit(alloc);
    for (members) |m| {
        if (m.pid == shell_pid or isConsoleHost(m.nameOf())) continue;
        try out.append(alloc, m.pid);
    }
    return out.toOwnedSlice(alloc);
}

fn isConsoleHost(name: []const u8) bool {
    for ([_][]const u8{ "conhost.exe", "openconsole.exe" }) |host| {
        if (std.ascii.eqlIgnoreCase(name, host)) return true;
    }
    return false;
}

/// The file name of `path` (either separator), narrowed for `Member.name`.
pub fn narrowName(out: *[16]u8, path: []const u16) u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| if (c == '\\' or c == '/') {
        start = i + 1;
    };
    const base = path[start..];
    const n = @min(base.len, out.len);
    for (base[0..n], out[0..n]) |c, *o| o.* = if (c >= 0x20 and c < 0x7f) @intCast(c) else '?';
    return @intCast(n);
}

// ------------------------------------------------- layouts (64-bit Windows)

pub const BasicLimitInformation = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: u32,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: u32,
    Affinity: usize,
    PriorityClass: u32,
    SchedulingClass: u32,
};

pub const IoCounters = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

pub const ExtendedLimitInformation = extern struct {
    BasicLimitInformation: BasicLimitInformation,
    IoInfo: IoCounters,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

pub const ProcessMemoryCountersEx = extern struct {
    cb: u32,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
    PrivateUsage: usize,
};

comptime {
    // The sizes the SDK gives on x64 (winnt.h, psapi.h). Checked wherever
    // this is compiled for a 64-bit target, which the Windows host is.
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(BasicLimitInformation) == 64);
        std.debug.assert(@sizeOf(IoCounters) == 48);
        std.debug.assert(@sizeOf(ExtendedLimitInformation) == 144);
        std.debug.assert(@sizeOf(ProcessMemoryCountersEx) == 80);
    }
}

pub const JobObjectBasicProcessIdList: u32 = 3;
pub const JobObjectExtendedLimitInformation: u32 = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
pub const CREATE_SUSPENDED: u32 = 0x00000004;

// ------------------------------------------------------------ Windows only

pub const win = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;
    const DWORD = windows.DWORD;

    const PROCESS_TERMINATE: DWORD = 0x0001;
    const PROCESS_VM_READ: DWORD = 0x0010;
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

    extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, JobObjectInformationClass: DWORD, lpJobObjectInformation: *anyopaque, cbJobObjectInformationLength: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateJobObject(hJob: HANDLE, uExitCode: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn QueryInformationJobObject(hJob: HANDLE, JobObjectInformationClass: DWORD, lpJobObjectInformation: *anyopaque, cbJobObjectInformationLength: DWORD, lpReturnLength: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
    extern "kernel32" fn K32GetProcessMemoryInfo(Process: HANDLE, ppsmemCounters: *ProcessMemoryCountersEx, cb: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    /// A job whose processes all stop when its last handle closes. Null when
    /// the system will not make one: the shell then runs without, as before.
    pub fn create() ?HANDLE {
        const job = CreateJobObjectW(null, null) orelse return null;
        var info: ExtendedLimitInformation = std.mem.zeroes(ExtendedLimitInformation);
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, @sizeOf(ExtendedLimitInformation)) == .FALSE) {
            _ = CloseHandle(job);
            return null;
        }
        return job;
    }

    /// Put the suspended `process` in `job` and let its first thread run.
    /// False when it could not be put in: it is let go all the same.
    pub fn adopt(job: HANDLE, process: HANDLE, thread: HANDLE) bool {
        const ok = AssignProcessToJobObject(job, process) != .FALSE;
        _ = ResumeThread(thread);
        return ok;
    }

    /// Stop everything in the job, the shell with it.
    pub fn terminate(job: HANDLE) bool {
        return TerminateJobObject(job, 1) != .FALSE;
    }

    pub fn close(job: HANDLE) void {
        _ = CloseHandle(job);
    }

    pub fn pidOf(process: HANDLE) u32 {
        return GetProcessId(process);
    }

    /// The job's processes, read now. In `alloc`.
    pub fn members(alloc: Allocator, job: HANDLE) Allocator.Error![]Member {
        // The header and room for 512 ids; a pane with more is read as the
        // first 512, which is still far over any line worth drawing.
        const List = extern struct { assigned: DWORD, listed: DWORD, ids: [512]usize };
        const list = try alloc.create(List);
        defer alloc.destroy(list);
        if (QueryInformationJobObject(job, JobObjectBasicProcessIdList, list, @sizeOf(List), null) == .FALSE) return &.{};
        const n = @min(list.listed, list.ids.len);

        var out: std.ArrayListUnmanaged(Member) = .empty;
        errdefer out.deinit(alloc);
        for (list.ids[0..n]) |id| {
            const pid: DWORD = @intCast(id);
            var m: Member = .{ .pid = pid, .private = 0, .name = @splat(0), .name_len = 0 };
            if (OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, .FALSE, pid)) |h| {
                defer _ = CloseHandle(h);
                var c: ProcessMemoryCountersEx = std.mem.zeroes(ProcessMemoryCountersEx);
                c.cb = @sizeOf(ProcessMemoryCountersEx);
                if (K32GetProcessMemoryInfo(h, &c, c.cb) != .FALSE) m.private = c.PrivateUsage;
                var path: [512]u16 = undefined;
                var len: DWORD = path.len;
                if (QueryFullProcessImageNameW(h, 0, &path, &len) != .FALSE) m.name_len = narrowName(&m.name, path[0..len]);
            }
            try out.append(alloc, m);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Stop each of `pids`. How many were stopped.
    pub fn stop(pids: []const u32) u32 {
        var n: u32 = 0;
        for (pids) |pid| {
            const h = OpenProcess(PROCESS_TERMINATE, .FALSE, pid) orelse continue;
            defer _ = CloseHandle(h);
            if (TerminateProcess(h, 1) != .FALSE) n += 1;
        }
        return n;
    }
} else struct {};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn M(pid: u32, mb: u64, name: []const u8) Member {
    var m: Member = .{ .pid = pid, .private = mb << 20, .name = @splat(0), .name_len = @intCast(name.len) };
    @memcpy(m.name[0..name.len], name);
    return m;
}

test "1993: a Windows pane is its job, summed, with the name holding the most" {
    const members = [_]Member{
        M(10, 60, "pwsh.exe"),     M(11, 9, "conhost.exe"),   M(12, 400, "node.exe"),
        M(13, 7000, "python.exe"), M(14, 7000, "Python.exe"), M(15, 300, "node.exe"),
    };
    const r = summarise(&members);
    try testing.expectEqual(@as(u32, 6), r.procs);
    try testing.expectEqual(@as(u64, (60 + 9 + 400 + 14000 + 300) << 20), r.mem);
    try testing.expectEqualStrings("python.exe", r.top[0..r.top_len]);
    try testing.expectEqual(@as(u32, 2), r.top_count);
    try testing.expectEqual(@as(u64, 14000 << 20), r.top_mem);

    const empty = summarise(&.{});
    try testing.expectEqual(@as(u32, 0), empty.procs);
    try testing.expectEqual(@as(u8, 0), empty.top_len);
}

test "1993: a Windows kill stops everything in the job but the shell and its console host" {
    const members = [_]Member{
        M(10, 60, "pwsh.exe"), M(11, 9, "ConHost.exe"), M(12, 400, "node.exe"), M(13, 7000, "python.exe"), M(16, 9, "OpenConsole.exe"),
    };
    const got = try stoppable(testing.allocator, &members, 10);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u32, &.{ 12, 13 }, got);
}

test "1993: an image path becomes a short ASCII name" {
    var out: [16]u8 = undefined;
    const path = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\nodejs\\node.exe");
    const n = narrowName(&out, path);
    try testing.expectEqualStrings("node.exe", out[0..n]);
    const long = std.unicode.utf8ToUtf16LeStringLiteral("D:/tools/a-very-long-program-name.exe");
    try testing.expectEqualStrings("a-very-long-prog", out[0..narrowName(&out, long)]);
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("C:\\工具\\工具.exe");
    try testing.expectEqualStrings("??.exe", out[0..narrowName(&out, wide)]);
}
