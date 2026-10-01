//! Whether the shell in a terminal is running something, for the shells that
//! cannot say so themselves (#991).
//!
//! `Surface.needsConfirmQuit` asks "is the cursor at a prompt?", which is
//! answered by the shell marking its prompt (OSC 133). bash, zsh, fish do; the
//! PowerShell integration deliberately does not (`ghostty.ps1` says at length
//! why), and cmd has no integration at all. So on Windows the answer was
//! always "not at a prompt", every terminal counted as running something, and
//! closing a window holding nothing but an idle PowerShell prompt put up
//! "Save as a Project Before Closing? The terminal still has a running
//! process" -- measured twice on the Windows test machine.
//!
//! The macOS question underneath is "is the foreground process the shell?".
//! Windows has no foreground process group, but it has the next best thing,
//! and for these shells it is the same fact: **a command the shell is running
//! is a child process of the shell.** An idle PowerShell has none; `ping`,
//! `claude`, `npm run dev` are each one.
//!
//! Everything that decides is a pure function below, tested on any machine;
//! the snapshot that feeds it is Windows-only and is the only part judged by
//! running the thing.

const std = @import("std");
const builtin = @import("builtin");

/// Whether the child-process answer applies to the shell at `path` (the
/// program the terminal started): the Windows shells that cannot mark their
/// prompt. **Only those**: a shell that marks its prompt keeps that answer,
/// and something like `wsl.exe` runs its commands as Linux processes that are
/// no Windows process's children -- asked this question, a WSL tab with vim
/// open would look idle and close without asking.
pub fn applies(path: []const u8) bool {
    const base = basename(path);
    const stem = if (std.ascii.endsWithIgnoreCase(base, ".exe")) base[0 .. base.len - 4] else base;
    for ([_][]const u8{ "powershell", "pwsh", "cmd" }) |name| {
        if (std.ascii.eqlIgnoreCase(stem, name)) return true;
    }
    return false;
}

fn basename(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return path;
    return path[cut + 1 ..];
}

/// One process, as the snapshot reports it.
pub const Proc = struct {
    pid: u32,
    parent: u32,
    /// When it started, in any unit that orders (a `FILETIME`), or null when
    /// it could not be read.
    created: ?u64,
    /// Its executable's file name, as the snapshot gives it.
    exe: []const u8,
};

/// Whether `procs` holds a process the shell `shell_pid`, started at
/// `shell_created`, is running.
///
/// ⚠️ **A parent id is not proof of parenthood.** Windows reuses process ids,
/// and a process whose real parent has exited keeps the dead parent's id --
/// which the shell may now have. So a candidate also has to have started no
/// earlier than the shell did; one that cannot say when it started is counted
/// (asking once too often is the safe way to be wrong here). This is the
/// trap `ParentProcessId` tree walks fall into when they "adopt" strangers.
///
/// The console host is not a command: it is the console's own process, not
/// something the person ran.
pub fn runsSomething(procs: []const Proc, shell_pid: u32, shell_created: ?u64) bool {
    for (procs) |p| {
        if (p.parent != shell_pid or p.pid == shell_pid) continue;
        if (std.ascii.eqlIgnoreCase(p.exe, "conhost.exe") or std.ascii.eqlIgnoreCase(p.exe, "OpenConsole.exe")) continue;
        const after = if (p.created) |c| if (shell_created) |s| c >= s else true else true;
        if (after) return true;
    }
    return false;
}

/// `needsConfirmQuit`'s `confirm-close-surface = true` arm: does closing need
/// asking? `at_prompt` is the prompt marks' answer; `busy` is this file's,
/// null where it does not apply (`applies`) or could not be had. A shell that
/// marks its prompt keeps its answer; one that cannot is asked about its
/// children instead. Unknown is "running" -- the old answer, and the one that
/// asks.
pub fn confirms(at_prompt: bool, busy: ?bool) bool {
    if (busy) |b| return b and !at_prompt;
    return !at_prompt;
}

/// The children of `shell` (a process handle) right now, as `runsSomething`
/// decides. Null when the snapshot could not be taken. Windows only.
pub fn shellBusy(shell: anytype) ?bool {
    if (comptime builtin.os.tag != .windows) return null;
    return win.busy(shell);
}

const win = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;
    const FILETIME = windows.FILETIME;

    const TH32CS_SNAPPROCESS: DWORD = 0x2;
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

    const PROCESSENTRY32W = extern struct {
        dwSize: DWORD,
        cntUsage: DWORD,
        th32ProcessID: DWORD,
        th32DefaultHeapID: usize,
        th32ModuleID: DWORD,
        cntThreads: DWORD,
        th32ParentProcessID: DWORD,
        pcPriClassBase: i32,
        dwFlags: DWORD,
        szExeFile: [260]u16,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetProcessTimes(
        hProcess: HANDLE,
        lpCreationTime: *FILETIME,
        lpExitTime: *FILETIME,
        lpKernelTime: *FILETIME,
        lpUserTime: *FILETIME,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    fn created(h: HANDLE) ?u64 {
        var c: FILETIME = undefined;
        var e: FILETIME = undefined;
        var k: FILETIME = undefined;
        var u: FILETIME = undefined;
        if (GetProcessTimes(h, &c, &e, &k, &u) == .FALSE) return null;
        return (@as(u64, c.dwHighDateTime) << 32) | c.dwLowDateTime;
    }

    fn createdOf(pid: DWORD) ?u64 {
        const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse return null;
        defer _ = CloseHandle(h);
        return created(h);
    }

    fn busy(shell: HANDLE) ?bool {
        const shell_pid = GetProcessId(shell);
        if (shell_pid == 0) return null;
        const shell_created = created(shell);

        const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == windows.INVALID_HANDLE_VALUE) return null;
        defer _ = CloseHandle(snap);

        var e: PROCESSENTRY32W = undefined;
        e.dwSize = @sizeOf(PROCESSENTRY32W);
        if (Process32FirstW(snap, &e) == .FALSE) return null;
        while (true) {
            if (e.th32ParentProcessID == shell_pid and e.th32ProcessID != shell_pid) {
                // The name, narrowed for the one comparison `runsSomething`
                // makes; anything past ASCII is not conhost.
                var name: [260]u8 = undefined;
                const n = std.mem.indexOfScalar(u16, &e.szExeFile, 0) orelse e.szExeFile.len;
                for (e.szExeFile[0..n], 0..) |c, i| name[i] = if (c < 0x80) @intCast(c) else '?';
                const one = [_]Proc{.{
                    .pid = e.th32ProcessID,
                    .parent = e.th32ParentProcessID,
                    .created = createdOf(e.th32ProcessID),
                    .exe = name[0..n],
                }};
                if (runsSomething(&one, shell_pid, shell_created)) return true;
            }
            if (Process32NextW(snap, &e) == .FALSE) break;
        }
        return false;
    }
} else struct {};

test "#991: only the Windows shells that cannot mark their prompt are asked about children" {
    const testing = std.testing;
    try testing.expect(applies("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"));
    try testing.expect(applies("pwsh"));
    try testing.expect(applies("C:/Program Files/PowerShell/7/PWSH.EXE"));
    try testing.expect(applies("cmd.exe"));
    // WSL's commands are not Windows children
    try testing.expect(!applies("C:\\Windows\\System32\\wsl.exe"));
    // bash marks its prompt
    try testing.expect(!applies("C:\\Program Files\\Git\\bin\\bash.exe"));
    try testing.expect(!applies("/bin/zsh"));
    try testing.expect(!applies("pwsh-preview.exe"));
}

test "#991: an idle shell runs nothing; a command it started is running" {
    const testing = std.testing;
    const shell: u32 = 100;
    const t0: u64 = 1_000;
    // An idle PowerShell: other processes about, none of them its children.
    const idle = [_]Proc{
        .{ .pid = shell, .parent = 4, .created = t0, .exe = "powershell.exe" },
        .{ .pid = 200, .parent = 4, .created = 900, .exe = "explorer.exe" },
        .{ .pid = 300, .parent = 50, .created = 1_200, .exe = "conhost.exe" },
    };
    try testing.expect(!runsSomething(&idle, shell, t0));
    // `ping` running under it.
    const ping = idle ++ [_]Proc{.{ .pid = 400, .parent = shell, .created = 1_500, .exe = "PING.EXE" }};
    try testing.expect(runsSomething(&ping, shell, t0));
    // `claude` -- node -- running under it.
    const claude = idle ++ [_]Proc{.{ .pid = 401, .parent = shell, .created = 1_600, .exe = "node.exe" }};
    try testing.expect(runsSomething(&claude, shell, t0));
}

test "#991: a stranger wearing a reused parent id is not the shell's child" {
    const testing = std.testing;
    const shell: u32 = 100;
    // Started before the shell: its real parent was an earlier process 100.
    const orphan = [_]Proc{.{ .pid = 500, .parent = shell, .created = 10, .exe = "svchost.exe" }};
    try testing.expect(!runsSomething(&orphan, shell, 1_000));
    // When it cannot say when it started, it is counted: asking is the safe
    // way to be wrong.
    const unknown = [_]Proc{.{ .pid = 501, .parent = shell, .created = null, .exe = "x.exe" }};
    try testing.expect(runsSomething(&unknown, shell, 1_000));
    // The console host is the console, not a command.
    const host = [_]Proc{.{ .pid = 502, .parent = shell, .created = 2_000, .exe = "conhost.exe" }};
    try testing.expect(!runsSomething(&host, shell, 1_000));
}

test "#991: the prompt marks still answer for the shells that have them" {
    const testing = std.testing;
    // No child-process answer (macOS, bash, zsh, WSL): exactly the old rule.
    try testing.expect(!confirms(true, null));
    try testing.expect(confirms(false, null));
    // PowerShell idle at its (unmarked) prompt: not running, no question.
    try testing.expect(!confirms(false, false));
    // PowerShell running ping: the question.
    try testing.expect(confirms(false, true));
}
