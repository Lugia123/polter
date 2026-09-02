const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.shell_integration);

/// The three reasons no integration was injected, as named constants.
///
/// **They are constants so that a test can hold them against each other.**
/// The defect these replace was one sentence covering all three: a user whose
/// own `-Command` had correctly suppressed the injection was told their shell
/// could not be detected, and went to look for a fault in their shell
/// configuration that was not there. The floor for that fix is that the
/// wordings stay distinguishable, and a floor nobody can run is a hope --
/// `messages stay distinguishable` below is that floor.
const msg_undetected =
    "shell could not be detected, no automatic shell integration will be injected";
const msg_declined =
    "shell integration for {s} was not injected; the shell was detected " ++
    "but its integration declined to run";
const msg_powershell_terminal_arg =
    "shell integration not injected: the configured command already " ++
    "contains {s}, which consumes the rest of the command line. " ++
    "Remove it to get automatic integration, or keep it and set " ++
    "up the integration by hand.";

/// Shell types we support
pub const Shell = enum {
    bash,
    elvish,
    fish,
    nushell,
    // **One member, two executables.** `powershell.exe` is Windows
    // PowerShell 5.1 and ships on every Windows; `pwsh.exe` is PowerShell 7+
    // and is installed separately. They take the same options for what this
    // file does, so they are one integration -- but supporting only `pwsh`
    // would leave the shell that is actually everywhere uncovered, which is
    // the situation this integration exists to fix.
    powershell,
    zsh,
};

/// The result of setting up a shell integration.
pub const ShellIntegration = struct {
    /// The successfully-integrated shell.
    shell: Shell,

    /// The command to use to start the shell with the integration.
    /// In most cases this is identical to the command given but for
    /// bash in particular it may be different.
    ///
    /// The memory is allocated in the arena given to setup.
    command: config.Command,
};

/// Set up the command execution environment for automatic
/// integrated shell integration and return a ShellIntegration
/// struct describing the integration.  If integration fails
/// (shell type couldn't be detected, etc.), this will return null.
///
/// The allocator is used for temporary values and to allocate values
/// in the ShellIntegration result. It is expected to be an arena to
/// simplify cleanup.
pub fn setup(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: config.Command,
    env: *EnvMap,
    force_shell: ?Shell,
) !?ShellIntegration {
    const shell: Shell = force_shell orelse
        try detectShell(alloc_arena, command) orelse {
        // **This sentence lives here because this is the only place that
        // knows it is true.** It used to be logged by the caller, on the
        // `null` this function returns -- and that `null` has three
        // different meanings by the time it arrives there. Saying "could
        // not be detected" for all of them sent a user whose shell had
        // been detected perfectly well off to check their shell
        // configuration.
        log.warn(
            "shell could not be detected, no automatic shell integration will be injected",
            .{},
        );
        return null;
    };

    const new_command: config.Command = switch (shell) {
        .bash => try setupBash(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .nushell => try setupNushell(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .zsh => try setupZsh(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .powershell => try setupPowershell(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .elvish, .fish => xdg: {
            if (!try setupXdgDataDirs(alloc_arena, resource_dir, env)) return null;
            break :xdg try command.clone(alloc_arena);
        },
    } orelse {
        // Detected, and declined. A different fact from the one above, and it
        // points a reader somewhere different: the shell is fine, the setup
        // for it did not go ahead. The specific reason, when there is one, is
        // logged by the `setup*` function that knows it -- naming the shell
        // here is what makes those lines findable.
        log.warn(msg_declined, .{@tagName(shell)});
        return null;
    };

    return .{
        .shell = shell,
        .command = new_command,
    };
}

test "force shell" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).@"enum".fields) |field| {
        const shell = @field(Shell, field.name);

        var res: TmpResourcesDir = try .init(shell);
        defer res.deinit();

        const result = try setup(
            alloc,
            res.path,
            .{ .shell = "sh" },
            &env,
            shell,
        );
        try testing.expectEqual(shell, result.?.shell);
    }
}

test "shell integration failure" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const result = try setup(
        alloc,
        "/nonexistent",
        .{ .shell = "sh" },
        &env,
        null,
    );

    try testing.expect(result == null);
    try testing.expectEqual(0, env.count());
}

fn detectShell(alloc: Allocator, command: config.Command) !?Shell {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    const arg0 = arg_iter.next() orelse return null;
    const exe = std.fs.path.basename(arg0);

    if (std.mem.eql(u8, "bash", exe)) {
        // Apple distributes their own patched version of Bash 3.2
        // on macOS that disables the ENV-based POSIX startup path.
        // This means we're unable to perform our automatic shell
        // integration sequence in this specific environment.
        //
        // If we're running "/bin/bash" on Darwin, we can assume
        // we're using Apple's Bash because /bin is non-writable
        // on modern macOS due to System Integrity Protection.
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (std.mem.eql(u8, "/bin/bash", arg0)) {
                return null;
            }
        }
        return .bash;
    }

    if (std.mem.eql(u8, "elvish", exe)) return .elvish;
    if (std.mem.eql(u8, "fish", exe)) return .fish;
    if (std.mem.eql(u8, "nu", exe)) return .nushell;
    if (std.mem.eql(u8, "zsh", exe)) return .zsh;

    // Both PowerShells, with and without the extension: a Windows shell
    // configured as `pwsh` and one configured as `pwsh.exe` are the same
    // shell, and a user writes whichever they have in their PATH.
    // Case-insensitive because Windows paths are.
    for ([_][]const u8{ "pwsh", "powershell" }) |name| {
        if (std.ascii.eqlIgnoreCase(name, exe)) return .powershell;
        if (exe.len == name.len + 4 and
            std.ascii.eqlIgnoreCase(name, exe[0..name.len]) and
            std.ascii.eqlIgnoreCase(".exe", exe[name.len..])) return .powershell;
    }

    return null;
}

test detectShell {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(try detectShell(alloc, .{ .shell = "sh" }) == null);
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash" }));
    try testing.expectEqual(.elvish, try detectShell(alloc, .{ .shell = "elvish" }));
    try testing.expectEqual(.fish, try detectShell(alloc, .{ .shell = "fish" }));
    try testing.expectEqual(.nushell, try detectShell(alloc, .{ .shell = "nu" }));
    try testing.expectEqual(.zsh, try detectShell(alloc, .{ .shell = "zsh" }));

    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(try detectShell(alloc, .{ .shell = "/bin/bash" }) == null);
    }

    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash -c 'command'" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "\"/a b/bash\"" }));
}

/// Set up the shell integration features environment variable.
pub fn setupFeatures(
    env: *EnvMap,
    features: config.ShellIntegrationFeatures,
    cursor_blink: bool,
) !void {
    const fields = @typeInfo(@TypeOf(features)).@"struct".fields;
    const capacity: usize = capacity: {
        comptime var n: usize = fields.len - 1; // commas
        inline for (fields) |field| n += field.name.len;
        n += ":steady".len; // cursor value
        break :capacity n;
    };

    var buf: [capacity]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Sort the fields so that the output is deterministic. This is
    // done at comptime so it has no runtime cost
    const fields_sorted: [fields.len][]const u8 = comptime fields: {
        var fields_sorted: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| fields_sorted[i] = field.name;
        std.mem.sortUnstable(
            []const u8,
            &fields_sorted,
            {},
            (struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
                }
            }).lessThan,
        );
        break :fields fields_sorted;
    };

    inline for (fields_sorted) |name| {
        if (@field(features, name)) {
            if (writer.end > 0) try writer.writeByte(',');
            try writer.writeAll(name);

            if (std.mem.eql(u8, name, "cursor")) {
                try writer.writeAll(if (cursor_blink) ":blink" else ":steady");
            }
        }
    }

    if (writer.end > 0) {
        try env.put("GHOSTTY_SHELL_FEATURES", buf[0..writer.end]);
    }
}

test "setup features" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test: all features enabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = true, .sudo = true, .title = true, .@"ssh-env" = true, .@"ssh-terminfo" = true, .path = true }, true);
        try testing.expectEqualStrings("cursor:blink,path,ssh-env,ssh-terminfo,sudo,title", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: all features disabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, std.mem.zeroes(config.ShellIntegrationFeatures), true);
        try testing.expect(env.get("GHOSTTY_SHELL_FEATURES") == null);
    }

    // Test: mixed features
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = false, .sudo = true, .title = false, .@"ssh-env" = true, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("ssh-env,sudo", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: blinking cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("cursor:blink", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: steady cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, false);
        try testing.expectEqualStrings("cursor:steady", env.get("GHOSTTY_SHELL_FEATURES").?);
    }
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    var stack_fallback = std.heap.stackFallback(4096, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.get());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;
    try cmd.appendArg("--posix");

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var buf: [32]u8 = undefined;
    var inject: std.Io.Writer = .fixed(&buf);
    try inject.writeAll("1");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration script.
    //
    // Unsupported options:
    //  -c          -c is always non-interactive
    //  --posix     POSIX mode (a la /bin/sh)
    var rcfile: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.writeAll(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.writeAll(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            rcfile = iter.next();
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // '-c command' is always non-interactive
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Preserve an existing ENV value. We're about to overwrite it.
    if (env.get("ENV")) |v| {
        try env.put("GHOSTTY_BASH_ENV", v);
    }

    // Set our new ENV to point to our integration script.
    var script_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const script_path = try std.fmt.bufPrint(
        &script_path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    if (std.Io.Dir.openFileAbsolute(global.io(), script_path, .{})) |file| {
        file.close(global.io());
        try env.put("ENV", script_path);
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        _ = env.swapRemove("GHOSTTY_BASH_ENV");
        return null;
    }

    try env.put("GHOSTTY_BASH_INJECT", buf[0..inject.end]);
    if (rcfile) |v| {
        try env.put("GHOSTTY_BASH_RCFILE", v);
    }

    // In POSIX mode, HISTFILE defaults to ~/.sh_history, so unless we're
    // staying in POSIX mode (--posix), change it back to ~/.bash_history.
    if (env.get("HISTFILE") == null) {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        var home_buf: [1024]u8 = undefined;
        if (try homedir.home(global.io(), &environ_map, &home_buf)) |home| {
            var histfile_buf: [std.fs.max_path_bytes]u8 = undefined;
            const histfile = try std.fmt.bufPrint(
                &histfile_buf,
                "{s}/.bash_history",
                .{home},
            );
            try env.put("HISTFILE", histfile);
            try env.put("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeZ(u8, try cmd.toOwnedSlice()) };
}

test "bash" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("bash --posix", command.?.shell);
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "bash --posix",
        "bash --rcfile script.sh --posix",
        "bash --init-file script.sh --posix",
        "bash -c script.sh",
        "bash -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupBash(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expectEqual(0, env.count());
    }
}

test "bash: inject flags" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --norc" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --noprofile" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, .{ .shell = "bash --rcfile profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, .{ .shell = "bash --init-file profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: HISTFILE" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: ENV" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("ENV", "env.sh");

    _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("env.sh", env.get("GHOSTTY_BASH_ENV").?);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: additional arguments" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // "-" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash - --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix - --arg file1 file2", command.?.shell);
    }

    // "--" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash -- --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix -- --arg file1 file2", command.?.shell);
    }
}

test "bash: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupBash(alloc, .{ .shell = "bash" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Setup automatic shell integration for shells that include
/// their modules from paths in `XDG_DATA_DIRS` env variable.
///
/// The shell-integration path is prepended to `XDG_DATA_DIRS`.
/// It is also saved in the `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` variable
/// so that the shell can refer to it and safely remove this directory
/// from `XDG_DATA_DIRS` when integration is complete.
fn setupXdgDataDirs(
    alloc: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Get our path to the shell integration directory.
    const integ_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return false;
    };
    integ_dir.close(global.io());

    // Set an env var so we can remove this from XDG_DATA_DIRS later.
    // This happens in the shell integration config itself. We do this
    // so that our modifications don't interfere with other commands.
    try env.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", integ_path);

    // We attempt to avoid allocating by using the stack up to 4K.
    // Max stack size is considerably larger on mac
    // 4K is a reasonable size for this for most cases. However, env
    // vars can be significantly larger so if we have to we fall
    // back to a heap allocated value.
    var stack_alloc_state = std.heap.stackFallback(4096, alloc);
    const stack_alloc = stack_alloc_state.get();

    // If no XDG_DATA_DIRS set use the default value as specified.
    // This ensures that the default directories aren't lost by setting
    // our desired integration dir directly. See #2711.
    // <https://specifications.freedesktop.org/basedir-spec/0.6/#variables>
    const xdg_data_dirs_key = "XDG_DATA_DIRS";
    try env.put(
        xdg_data_dirs_key,
        try prependEnv(
            stack_alloc,
            env.get(xdg_data_dirs_key) orelse "/usr/local/share:/usr/share",
            integ_path,
        ),
    );

    return true;
}

/// Prepend a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
fn prependEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    return try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        value,
        std.fs.path.delimiter,
        current,
    });
}

test "xdg: empty XDG_DATA_DIRS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration:/usr/local/share:/usr/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: existing XDG_DATA_DIRS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("XDG_DATA_DIRS", "/opt/share");

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration:/opt/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(!try setupXdgDataDirs(alloc, resources_dir, &env));
    try testing.expectEqual(0, env.count());
}

/// Set up automatic Nushell shell integration. This works by adding our
/// shell resource directory to the `XDG_DATA_DIRS` environment variable,
/// which Nushell will use to load `nushell/vendor/autoload/ghostty.nu`.
///
/// We then add `--execute 'use ghostty ...'` to the nu command line to
/// automatically enable our shelll features.
fn setupNushell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Add our XDG_DATA_DIRS entry (for nushell/vendor/autoload/). This
    // makes our 'ghostty' module automatically available, even if any
    // of the later checks abort the rest of our automatic integration.
    if (!try setupXdgDataDirs(alloc, resource_dir, env)) return null;

    var stack_fallback = std.heap.stackFallback(4096, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.get());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;

    // Tell nu to immediately "use" all of the exported functions in our
    // 'ghostty' module.
    //
    // We can consider making this more specific based on the set of
    // enabled shell features (e.g. `use ghostty sudo`). At the moment,
    // shell features are all runtime-guarded in the nushell script.
    try cmd.appendArg("--execute 'use ghostty *'");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration module.
    //
    // Unsupported options:
    //  -c / --command      -c is always non-interactive
    //  --lsp               --lsp starts the language server
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--command") or std.mem.eql(u8, arg, "--lsp")) {
            return null;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeZ(u8, try cmd.toOwnedSlice()) };
}

test "nushell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupNushell(alloc, .{ .shell = "nu" }, res.path, &env);
    try testing.expectEqualStrings("nu --execute 'use ghostty *'", command.?.shell);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectStringStartsWith(
        env.get("XDG_DATA_DIRS").?,
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
    );
}

test "nushell: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "nu --command exit",
        "nu --lsp",
        "nu -c script.sh",
        "nu -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupNushell(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expect(env.get("XDG_DATA_DIRS") != null);
        try testing.expect(env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR") != null);
    }
}

test "nushell: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupNushell(alloc, .{ .shell = "nu" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Setup the zsh automatic shell integration. This works by setting
/// ZDOTDIR to our resources dir so that zsh will load our config. This
/// config then loads the true user config.
/// Set up the PowerShell integration.
///
/// # Why this returns a `direct` command and not a `shell` string
///
/// **`Exec.zig` splits a `shell` command string on whitespace on Windows and
/// says outright that it "does not honor Windows CLI quoting rules"**
/// (`Exec.zig:2071`). Every other integration gets away with a string because
/// their arguments have no spaces -- `bash --posix`, `nu --execute '...'`
/// is quoted for *nushell*, not for the splitter. PowerShell's `-Command`
/// takes a script fragment, which does have spaces, so a string would arrive
/// at the process as three broken arguments. The `direct` form is passed
/// through as an argv array, which is what the same comment recommends.
///
/// # Why the path travels in the environment
///
/// The script's path can contain spaces (it does on a default install:
/// `C:\\Program Files\\...`) and a quote is legal in a Windows directory
/// name. Putting the path in `-Command` would mean quoting it for PowerShell
/// *inside* an argument that is itself being quoted for the process
/// creation API. Passing it in an environment variable has no quoting rules
/// at all -- and `. $env:X` hands the whole value to the dot-source operator
/// as one path however many spaces it holds. bash's integration uses `ENV`
/// for the same reason.
///
/// # What is refused
///
/// `-Command`, `-File` and `-EncodedCommand` all consume the rest of the
/// command line, so a user who passed one is running something specific and
/// appending ours would either be ignored or would change what they asked
/// for. Those bail out, and the shell starts without integration rather than
/// with a command line that means something else.
fn setupPowershell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // The script has to exist before the command line promises to load it:
    // dot-sourcing a missing path prints an error at the user's first prompt.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const integ_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/powershell/ghostty.ps1",
        .{resource_dir},
    );
    std.Io.Dir.accessAbsolute(global.io(), integ_path, .{}) catch |err| {
        log.warn("unable to access {s}: {}", .{ integ_path, err });
        return null;
    };
    try env.put("GHOSTTY_POWERSHELL_INTEGRATION", integ_path);

    var args: std.ArrayList([:0]const u8) = .empty;

    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    const exe = iter.next() orelse return null;
    try args.append(alloc, try alloc.dupeZ(u8, exe));

    while (iter.next()) |arg| {
        // Prefixes, because PowerShell accepts any unambiguous abbreviation:
        // `-com`, `-Command` and `-c` are the same switch.
        if (isPowershellTerminalArg(arg)) {
            // **Names the switch, because "one of your arguments" is not
            // actionable.** The user wrote it; telling them which one turns
            // the message into an instruction.
            log.warn(msg_powershell_terminal_arg, .{arg});
            return null;
        }
        try args.append(alloc, try alloc.dupeZ(u8, arg));
    }

    // **`-ExecutionPolicy Bypass` applies to this process only.** The default
    // on a Windows client is `Restricted`, under which dot-sourcing any .ps1
    // fails -- and it fails the way everything in this port fails, by the
    // feature simply not happening. The alternative, `-EncodedCommand`, is
    // not subject to the policy either but arrives in the log and the process
    // list as base64: unreadable exactly when somebody needs to read it.
    try args.append(alloc, "-ExecutionPolicy");
    try args.append(alloc, "Bypass");
    // Without this, `-Command` runs and exits; there would be no shell.
    try args.append(alloc, "-NoExit");
    // Last, because everything after `-Command` belongs to it.
    try args.append(alloc, "-Command");
    try args.append(alloc, ". $env:GHOSTTY_POWERSHELL_INTEGRATION");

    return .{ .direct = try args.toOwnedSlice(alloc) };
}

/// Whether an argument makes PowerShell consume the rest of the command line.
fn isPowershellTerminalArg(arg: []const u8) bool {
    if (arg.len < 2) return false;
    if (arg[0] != '-' and arg[0] != '/') return false;
    const name = arg[1..];
    // PowerShell allows any unambiguous prefix of a parameter name, so the
    // check is on prefixes rather than on the full spellings. `-c` is the
    // documented short form of `-Command`.
    for ([_][]const u8{ "command", "file", "encodedcommand", "ec" }) |full| {
        if (name.len <= full.len and std.ascii.eqlIgnoreCase(name, full[0..name.len])) {
            return true;
        }
    }
    return false;
}

test "the three not-injected messages stay distinguishable" {
    const testing = std.testing;

    // **The floor for task 117, as a test rather than as an eyeball.**
    //
    // The defect was one sentence used for three different situations. Two of
    // them send a reader in opposite directions: "your shell was not
    // recognised" means go and look at the shell configuration, "your own
    // `-Command` suppressed this" means the configuration is fine and the
    // choice was yours. Only the first may carry the old wording.
    const detect_phrase = "could not be detected";
    try testing.expect(std.mem.indexOf(u8, msg_undetected, detect_phrase) != null);
    try testing.expect(std.mem.indexOf(u8, msg_declined, detect_phrase) == null);
    try testing.expect(std.mem.indexOf(u8, msg_powershell_terminal_arg, detect_phrase) == null);

    // Pairwise distinct, which is what "distinguishable" has to mean when the
    // reader is grepping a log.
    try testing.expect(!std.mem.eql(u8, msg_undetected, msg_declined));
    try testing.expect(!std.mem.eql(u8, msg_declined, msg_powershell_terminal_arg));
    try testing.expect(!std.mem.eql(u8, msg_undetected, msg_powershell_terminal_arg));

    // The two that can name something must actually take a parameter -- a
    // message that says "one of your arguments" is not an instruction.
    try testing.expect(std.mem.indexOf(u8, msg_declined, "{s}") != null);
    try testing.expect(std.mem.indexOf(u8, msg_powershell_terminal_arg, "{s}") != null);
}

test "powershell: a command line carrying -Command declines through setup, not just setupPowershell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    // End to end through `setup`, because that is the path the caller takes
    // and the one whose `null` used to be mislabelled.
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        const result = try setup(alloc, res.path, .{ .shell = "pwsh -Command Get-Date" }, &env, null);
        try testing.expect(result == null);
    }

    // And the floor from the other direction: the same command line without
    // that switch is injected. Without this, an implementation that declined
    // everything would satisfy the test above.
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        const result = try setup(alloc, res.path, .{ .shell = "pwsh -NoLogo" }, &env, null);
        try testing.expect(result != null);
        try testing.expectEqual(Shell.powershell, result.?.shell);
    }
}

test "powershell: the command line is direct, not a shell string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = (try setupPowershell(
        alloc,
        .{ .shell = "pwsh" },
        res.path,
        &env,
    )).?;

    // **`direct`, and this is the point of the test.** A `shell` string is
    // split on whitespace on Windows with no regard for quoting, so
    // `-Command ". $env:X"` would arrive as three arguments and the shell
    // would start without integration -- silently, since a shell that starts
    // is a shell that looks fine.
    const args = switch (command) {
        .direct => |v| v,
        .shell => return error.ExpectedDirectCommand,
    };

    try testing.expectEqualStrings("pwsh", args[0]);
    try testing.expectEqualStrings("-ExecutionPolicy", args[args.len - 5]);
    try testing.expectEqualStrings("Bypass", args[args.len - 4]);
    try testing.expectEqualStrings("-NoExit", args[args.len - 3]);
    try testing.expectEqualStrings("-Command", args[args.len - 2]);
    // The fragment has a space in it. That space is exactly what a `shell`
    // string could not have carried.
    try testing.expectEqualStrings(". $env:GHOSTTY_POWERSHELL_INTEGRATION", args[args.len - 1]);

    // The path travels in the environment, where nothing has to be quoted.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(
            &path_buf,
            "{s}/shell-integration/powershell/ghostty.ps1",
            .{res.path},
        ),
        env.get("GHOSTTY_POWERSHELL_INTEGRATION").?,
    );
}

test "powershell: the user's own arguments are kept, in order, before ours" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = (try setupPowershell(
        alloc,
        .{ .shell = "pwsh -NoLogo -NoProfileLoadTime" },
        res.path,
        &env,
    )).?;
    const args = switch (command) {
        .direct => |v| v,
        .shell => return error.ExpectedDirectCommand,
    };

    try testing.expectEqualStrings("pwsh", args[0]);
    try testing.expectEqualStrings("-NoLogo", args[1]);
    try testing.expectEqualStrings("-NoProfileLoadTime", args[2]);
    // **Ours come after.** `-Command` consumes everything following it, so an
    // implementation that appended the user's arguments last would hand them
    // to PowerShell as part of our script fragment.
    try testing.expectEqualStrings("-ExecutionPolicy", args[3]);
}

test "powershell: arguments that swallow the command line are refused" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    // Each of these takes over the rest of the line. Adding our `-Command`
    // after one of them either does nothing or changes what the user asked
    // for; starting without integration is the honest outcome.
    const refused = [_][:0]const u8{
        "pwsh -Command Get-Date",
        "pwsh -c Get-Date",
        "pwsh -File script.ps1",
        "pwsh -EncodedCommand ZwBlAHQA",
        // Abbreviations, which PowerShell accepts for any unambiguous prefix.
        "pwsh -com Get-Date",
        "pwsh -fi script.ps1",
        // Windows-style slash.
        "pwsh /Command Get-Date",
    };
    for (refused) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        const result = try setupPowershell(alloc, .{ .shell = cmdline }, res.path, &env);
        try testing.expect(result == null);
    }
}

// **The floor for the test above.** A predicate that returned true for every
// argument would refuse everything and pass it, while quietly disabling the
// integration for anyone who passes any option at all.
test "powershell: ordinary arguments are not mistaken for terminal ones" {
    const testing = std.testing;
    try testing.expect(!isPowershellTerminalArg("-NoLogo"));
    try testing.expect(!isPowershellTerminalArg("-NoExit"));
    try testing.expect(!isPowershellTerminalArg("-WorkingDirectory"));
    try testing.expect(!isPowershellTerminalArg("-ExecutionPolicy"));
    try testing.expect(!isPowershellTerminalArg("Bypass"));
    try testing.expect(!isPowershellTerminalArg("-"));
    try testing.expect(isPowershellTerminalArg("-Command"));
    try testing.expect(isPowershellTerminalArg("-c"));
    try testing.expect(isPowershellTerminalArg("-File"));
}

// **The two lists that have to agree, and the reason this is a test rather
// than a convention.**
//
// `Config.ShellIntegration` is what a person may write in their config;
// `Shell` above is what this file knows how to inject. They are two enums in
// two files, and they disagreed: `powershell` was here and not there, so
// `shell-integration = powershell` was rejected with a diagnostic **while the
// integration itself worked**, because `detect` -- the default -- finds
// `powershell.exe` on its own. The person gets a red box and working
// software, and concludes the documentation is wrong.
//
// **Both directions are asserted, and they fail differently:**
//
//  - A config value with no shell here parses and then injects nothing: a red
//    box, and the feature silently absent.
//  - A shell here with no config value **cannot be asked for**: that is the
//    defect above, and it is the worse of the two to find, because the
//    symptom is a rejected setting on top of a feature that works anyway.
//    Nothing about the running terminal is wrong -- only the person's belief
//    about what they are allowed to write.
//
// Written with `@typeInfo` over both enums rather than a list of names: a
// hand-written second list is exactly what failed here, and repeating one
// inside the test that checks for it would make the test blind in the same
// way the code was.
/// Does `E` have a member spelled `name`?
///
/// **Both loops below and the anchors that check them go through here**, and
/// that is the whole point of it being a function. An anchor that called
/// `std.meta.stringToEnum` directly would pin the standard library, not this
/// test's instrument: replace the lookup inside the loops with something that
/// always says yes, and the loops go green while such an anchor still passes,
/// because it asked a different question.
fn hasName(comptime E: type, name: []const u8) bool {
    return std.meta.stringToEnum(E, name) != null;
}

test "the config's shell-integration values and this file's shells are the same set" {
    const testing = std.testing;
    const Configurable = config.Config.ShellIntegration;

    // **The anchors come first, because they are what says the loops below
    // are looking at anything.** Every assertion in those loops is of the
    // form "nothing was missing", and the three counts only say how many
    // times the loop went round -- **not what the lookup decided**. A lookup
    // that always answered yes satisfies both loops and all three counts.

    // A name that will never be a shell. `hasName` must be able to say no.
    try testing.expect(!hasName(Shell, "not_a_shell_zz"));
    try testing.expect(!hasName(Configurable, "not_a_shell_zz"));

    // And the member this test was written for. **Deleting `powershell` from
    // both enums at once -- the shape of an ordinary "nobody uses this,
    // clean it up" -- keeps the two tables agreeing, drops both counts from
    // 6 to 5, and leaves `>= 5` and the equality both satisfied. This pair of
    // lines is the only thing that would notice.**
    try testing.expect(hasName(Configurable, "powershell"));
    try testing.expect(hasName(Shell, "powershell"));

    // `none` and `detect` are not shells; every other config value must name
    // one this file can inject.
    var configurable: usize = 0;
    inline for (@typeInfo(Configurable).@"enum".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "none") and
            !std.mem.eql(u8, field.name, "detect"))
        {
            configurable += 1;
            if (!hasName(Shell, field.name)) {
                std.debug.print(
                    "config allows shell-integration = {s}, but termio.shell_integration.Shell " ++
                        "has no such member: the value parses and then nothing injects it\n",
                    .{field.name},
                );
                return error.ConfigurableShellHasNoIntegration;
            }
        }
    }

    // And every shell this file injects must be nameable in the config, or it
    // can only ever be reached by `detect`.
    var injectable: usize = 0;
    inline for (@typeInfo(Shell).@"enum".fields) |field| {
        injectable += 1;
        if (!hasName(Configurable, field.name)) {
            std.debug.print(
                "this file injects {s}, but Config.ShellIntegration has no such value: " ++
                    "`shell-integration = {s}` is rejected with a diagnostic while `detect` " ++
                    "keeps injecting it, so the rejection changes nothing that can be seen\n",
                .{ field.name, field.name },
            );
            return error.InjectableShellIsNotConfigurable;
        }
    }

    // **The numbers that say the loops did any work.** An `inline for` over an
    // enum that stopped having fields would satisfy every branch above and
    // read exactly like a clean run.
    try testing.expect(configurable >= 5);
    try testing.expect(injectable >= 5);
    try testing.expectEqual(configurable, injectable);
}

test "powershell: a missing script means no integration, not a broken shell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // Dot-sourcing a path that is not there prints an error at the user's
    // first prompt, so the check happens before the command line promises it.
    const result = try setupPowershell(alloc, .{ .shell = "pwsh" }, "/nonexistent", &env);
    try testing.expect(result == null);
    try testing.expect(env.get("GHOSTTY_POWERSHELL_INTEGRATION") == null);
}

test "powershell: both executables are detected, with and without .exe" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][:0]const u8{
        "pwsh",
        "pwsh.exe",
        "powershell",
        "powershell.exe",
        "PowerShell.exe",
        // A path with a space has to be quoted in a shell command string --
        // the argument iterator splits on whitespace otherwise, and arg0
        // becomes `C:/Program`. That is the iterator's rule, not this
        // function's, and getting it wrong here was a test bug.
        "\"C:/Program Files/PowerShell/7/pwsh.exe\"",
        "pwsh -NoLogo",
    }) |cmdline| {
        try testing.expectEqual(
            Shell.powershell,
            (try detectShell(alloc, .{ .shell = cmdline })).?,
        );
    }

    // **5.1 is the one that matters most**: `powershell.exe` ships on every
    // Windows, `pwsh.exe` is a separate install. Supporting only the latter
    // would leave this integration in the same position as bash -- available
    // only to people who installed something.
    try testing.expectEqual(
        Shell.powershell,
        (try detectShell(alloc, .{ .shell = "powershell.exe" })).?,
    );

    // The floor: a name that merely starts the same way is a different shell.
    try testing.expect(try detectShell(alloc, .{ .shell = "pwshx" }) == null);
    try testing.expect(try detectShell(alloc, .{ .shell = "powershellish" }) == null);
}

fn setupZsh(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Preserve an existing ZDOTDIR value. We're about to overwrite it.
    if (env.get("ZDOTDIR")) |old| {
        try env.put("GHOSTTY_ZSH_ZDOTDIR", old);
    }

    // Set our new ZDOTDIR to point to our shell resource directory.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const integ_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return null;
    };
    integ_dir.close(global.io());
    try env.put("ZDOTDIR", integ_path);

    return try command.clone(alloc);
}

test "zsh" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expect(env.get("GHOSTTY_ZSH_ZDOTDIR") == null);
}

test "zsh: ZDOTDIR" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try env.put("ZDOTDIR", "$HOME/.config/zsh");

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expectEqualStrings("$HOME/.config/zsh", env.get("GHOSTTY_ZSH_ZDOTDIR").?);
}

test "zsh: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupZsh(alloc, .{ .shell = "zsh" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Test helper that creates a temporary resources directory with shell integration paths.
const TmpResourcesDir = struct {
    tmp_dir: std.testing.TmpDir,
    path: [:0]const u8,
    shell_path: []const u8,

    fn init(shell: Shell) !TmpResourcesDir {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const relative_shell_path = try std.fmt.bufPrint(
            &path_buf,
            "shell-integration/{s}",
            .{@tagName(shell)},
        );
        try tmp_dir.dir.createDirPath(std.testing.io, relative_shell_path);

        const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);

        const shell_path = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}/{s}",
            .{ path, relative_shell_path },
        );
        errdefer std.testing.allocator.free(shell_path);

        switch (shell) {
            .bash => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/bash/ghostty.bash",
                .data = "",
            }),
            // `setupPowershell` checks the script is there before promising
            // to dot-source it, so the fixture has to provide one.
            .powershell => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/powershell/ghostty.ps1",
                .data = "",
            }),
            else => {},
        }

        return .{
            .tmp_dir = tmp_dir,
            .path = path,
            .shell_path = shell_path,
        };
    }

    fn deinit(self: *TmpResourcesDir) void {
        std.testing.allocator.free(self.shell_path);
        std.testing.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};
