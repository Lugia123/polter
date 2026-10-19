//! Putting a Windows terminal's console into UTF-8 (`windows-console-utf8`,
//! task 1778).
//!
//! **What is wrong without it.** A pseudo console starts in the system's OEM
//! code page, which on a Simplified Chinese Windows is 936 (GBK). A program
//! that writes UTF-8 bytes -- `git`, Python, anything built with Rust or Go --
//! has them decoded as GBK on the way to the screen. Windows PowerShell 5.1
//! adds a second fault of its own: `$OutputEncoding` is ASCII, so a string it
//! pipes into a native program arrives with every Chinese character as `?`.
//! PowerShell 7 fixes only that second one; `[Console]::OutputEncoding` still
//! follows the code page, so "start pwsh" alone is not the repair.
//!
//! **Why per session and not a profile or the system setting.** A parent
//! cannot set the code page of a pseudo console it created -- the call
//! applies to the caller's own console -- so the shell inside has to do it.
//! The shell is ours to start, so we hand it the instruction: PowerShell
//! through the integration script it already dot-sources (an environment
//! variable the script reads), `cmd.exe` through `/K chcp 65001`. Nothing is
//! written to the user's `$PROFILE`, the registry, or the system-wide "Beta:
//! UTF-8" switch; a console opened outside Polter is exactly as it was.
//!
//! **Every outcome is its own value**, logged with its own sentence. "Did not
//! switch" covers a user who turned it off, a PowerShell whose integration did
//! not load, a `cmd.exe` with its own arguments, and a shell we have nothing
//! to say to (WSL), and a reader of the log acts differently on each.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const config = @import("../config.zig");
const shell_integration = @import("shell_integration.zig");

/// The environment variable `ghostty.ps1` reads. `1` means switch.
pub const env_key = "GHOSTTY_CONSOLE_UTF8";

/// What was done, and why when nothing was.
pub const Outcome = enum {
    /// `windows-console-utf8 = false`.
    off,
    /// PowerShell with its integration injected: `env_key` is set and the
    /// script switches.
    powershell,
    /// PowerShell, but the integration was not injected (turned off, or the
    /// user's own `-Command`), so there is no script to do it.
    powershell_not_injected,
    /// `cmd.exe` with no arguments, now started as `cmd.exe /K chcp 65001`.
    cmd,
    /// `cmd.exe` with arguments of its own. They are the user's; adding `/K`
    /// beside a `/C` would change what they wrote.
    cmd_has_args,
    /// Anything else -- `wsl.exe`, a program run directly. Nothing to say.
    other,

    /// The log line for this outcome.
    pub fn message(self: Outcome) []const u8 {
        return switch (self) {
            .off => "console UTF-8: off by configuration (windows-console-utf8 = false)",
            .powershell => "console UTF-8: PowerShell will switch to UTF-8 as its shell integration loads",
            .powershell_not_injected => "console UTF-8: not switched; PowerShell needs its shell integration to do it, " ++
                "and it was not injected (an earlier line says why)",
            .cmd => "console UTF-8: cmd.exe started with chcp 65001",
            .cmd_has_args => "console UTF-8: not switched; cmd.exe has arguments of its own, which are left as written",
            .other => "console UTF-8: not switched; this is not a shell Polter knows how to switch",
        };
    }
};

pub const Result = struct {
    outcome: Outcome,
    command: config.Command,
};

/// Decide, and make the change: set `env_key` in `env` or return a rewritten
/// command. `injected` is the shell integration actually injected, or null.
///
/// **Pure: no filesystem, no Windows calls**, so every outcome is testable on
/// the machine this is written on. The caller decides it only runs on
/// Windows.
pub fn apply(
    alloc: Allocator,
    command: config.Command,
    env: *EnvMap,
    injected: ?shell_integration.Shell,
    enabled: bool,
) !Result {
    if (!enabled) return .{ .outcome = .off, .command = command };

    if (injected == .powershell) {
        try env.put(env_key, "1");
        return .{ .outcome = .powershell, .command = command };
    }

    var it = try command.argIterator(alloc);
    defer it.deinit();
    const arg0 = it.next() orelse return .{ .outcome = .other, .command = command };
    const exe = try alloc.dupeZ(u8, arg0);
    const name = std.fs.path.basenameWindows(exe);

    if (isExe(name, "pwsh") or isExe(name, "powershell")) {
        return .{ .outcome = .powershell_not_injected, .command = command };
    }

    if (isExe(name, "cmd")) {
        if (it.next() != null) return .{ .outcome = .cmd_has_args, .command = command };

        // Four arguments rather than one `chcp 65001>nul`: an argument with a
        // space in it gets quoted on its way to the command line, and how
        // `cmd /K` treats a quoted string with a `>` in it is a rule worth not
        // depending on. Unquoted, cmd joins everything after `/K` itself.
        const args = try alloc.alloc([:0]const u8, 4);
        args[0] = exe;
        args[1] = "/K";
        args[2] = "chcp";
        args[3] = "65001>nul";
        return .{ .outcome = .cmd, .command = .{ .direct = args } };
    }

    return .{ .outcome = .other, .command = command };
}

/// `name` is `base` or `base.exe`, ignoring case, because Windows paths do.
fn isExe(name: []const u8, base: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, base)) return true;
    return name.len == base.len + 4 and
        std.ascii.eqlIgnoreCase(name[0..base.len], base) and
        std.ascii.eqlIgnoreCase(name[base.len..], ".exe");
}

const testing = std.testing;

test "console utf8: PowerShell with its integration gets the variable and keeps its command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);

    const cmd: config.Command = .{ .shell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" };
    const r = try apply(alloc, cmd, &env, .powershell, true);
    try testing.expectEqual(Outcome.powershell, r.outcome);
    try testing.expectEqualStrings("1", env.get(env_key).?);
    try testing.expectEqualStrings(cmd.shell, r.command.shell);
}

test "console utf8: off means nothing is touched, for every shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);

    for ([_]config.Command{
        .{ .shell = "pwsh.exe" },
        .{ .shell = "cmd.exe" },
    }) |cmd| {
        const r = try apply(alloc, cmd, &env, .powershell, false);
        try testing.expectEqual(Outcome.off, r.outcome);
        try testing.expectEqualStrings(cmd.shell, r.command.shell);
    }
    try testing.expectEqual(0, env.count());
}

test "console utf8: PowerShell without its integration is told apart and left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);

    for ([_][:0]const u8{ "pwsh", "PWSH.EXE", "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "powershell.exe" }) |exe| {
        const args = [_][:0]const u8{ exe, "-Command", "Get-Date" };
        const r = try apply(alloc, .{ .direct = &args }, &env, null, true);
        try testing.expectEqual(Outcome.powershell_not_injected, r.outcome);
    }
    try testing.expectEqual(0, env.count());
}

test "console utf8: a bare cmd.exe is started with chcp 65001" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);

    for ([_]config.Command{
        .{ .shell = "cmd.exe" },
        .{ .shell = "CMD" },
        .{ .direct = &.{"C:\\Windows\\System32\\cmd.exe"} },
    }) |cmd| {
        const r = try apply(alloc, cmd, &env, null, true);
        try testing.expectEqual(Outcome.cmd, r.outcome);
        const args = r.command.direct;
        try testing.expectEqual(4, args.len);
        try testing.expectEqualStrings("/K", args[1]);
        try testing.expectEqualStrings("chcp", args[2]);
        try testing.expectEqualStrings("65001>nul", args[3]);
    }
    try testing.expectEqual(0, env.count());
}

test "console utf8: cmd.exe with its own arguments keeps them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);

    const cmd: config.Command = .{ .shell = "cmd.exe /C build.bat" };
    const r = try apply(alloc, cmd, &env, null, true);
    try testing.expectEqual(Outcome.cmd_has_args, r.outcome);
    try testing.expectEqualStrings(cmd.shell, r.command.shell);
}

test "console utf8: WSL and anything else are left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);

    for ([_]config.Command{
        .{ .shell = "wsl.exe -d Ubuntu --cd ~" },
        // Not cmd, however close the spelling.
        .{ .shell = "cmdx.exe" },
    }) |cmd| {
        const r = try apply(alloc, cmd, &env, null, true);
        try testing.expectEqual(Outcome.other, r.outcome);
    }
    try testing.expectEqual(0, env.count());
}

test "console utf8: every outcome has its own sentence" {
    const fields = @typeInfo(Outcome).@"enum".fields;
    inline for (fields, 0..) |a, i| {
        inline for (fields[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(
                u8,
                @field(Outcome, a.name).message(),
                @field(Outcome, b.name).message(),
            ));
        }
    }
}

test "console utf8: the script reads the variable this file sets, and switches without a byte order mark" {
    // **The two halves live in two languages**, and the half that would go
    // quiet is the script: a renamed variable on either side leaves every
    // console in GBK with no error anywhere. So the script is read here.
    const script = @embedFile("../shell-integration/powershell/ghostty.ps1");
    try testing.expect(std.mem.indexOf(u8, script, "$env:" ++ env_key ++ " -eq '1'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "New-Object System.Text.UTF8Encoding $false") != null);
    try testing.expect(std.mem.indexOf(u8, script, "[Console]::OutputEncoding = $GhosttyUtf8") != null);
    try testing.expect(std.mem.indexOf(u8, script, "[Console]::InputEncoding = $GhosttyUtf8") != null);
    try testing.expect(std.mem.indexOf(u8, script, "$global:OutputEncoding = $GhosttyUtf8") != null);
}
