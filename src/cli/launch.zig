//! `polter +launch <role> [<cli>]` -- become an agent CLI wearing a role.
//!
//! This is what a "Launch with Role" click and a supervisor's `role_launch`
//! both end up typing into a fresh terminal. It runs **inside** that
//! terminal, which is the reason it exists at all:
//!
//!   * The command line is built by the CLI's adapter plugin, which runs a
//!     script. Doing that on the app thread would stall every terminal;
//!     doing it here stalls nobody but the terminal that asked.
//!   * What gets typed is a fixed, short line with nothing in it but a role
//!     key and a CLI key. The real command line -- JSON settings, a system
//!     prompt with quotes and newlines in it -- never passes through a
//!     shell, so there is no quoting for anybody to get wrong.
//!   * When something is wrong (the role was deleted, the plugin is off,
//!     `claude` is not installed) the reason is printed where the person is
//!     looking: in the terminal that did not start.
//!
//! The process then **replaces itself** with the CLI, so the CLI is the
//! shell's child exactly as if it had been typed, and inherits this
//! terminal's `GHOSTTY_POLTER_*` variables -- which is how its `+mcp` knows
//! which terminal it is in. Windows cannot replace a process, so there it
//! runs the CLI as a child on the same console and waits.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const persona = @import("../poltergeist/persona.zig");
const PersonaStore = @import("../poltergeist/PersonaStore.zig");
const agent_cli = @import("../poltergeist/agent_cli.zig");
const Plugin = @import("../poltergeist/Plugin.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `launch` command starts an agent CLI wearing a role defined in
/// Polter's role library.
///
///   polter +launch <role> [<cli>]
///
/// `<role>` is the role's key. `<cli>` is the key of the plugin that
/// manages the CLI (`claude-code`), and may be left out when the role is
/// set up for exactly one.
///
/// Normally this is not typed by hand: "Launch with Role" in a tab's menu,
/// and the supervisor's `role_launch`, open a terminal and type it there.
pub fn run(alloc: Allocator) !u8 {
    const io = global.io();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Before the writer's own `defer`, so it runs after that flush: the
    // console goes back to its code page only once everything we print
    // has been written in UTF-8.
    const console = Console.utf8();
    defer console.restore();

    var buffer: [4096]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writerStreaming(io, &buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    const parsed = parseArgs(aa) catch {
        try err_out.writeAll(
            \\Polter: `+launch` needs a role.
            \\
            \\    polter +launch <role> [<cli>]
            \\
        );
        return 2;
    };

    // --- the role
    const path = try PersonaStore.defaultPath(aa);
    // No file is a library of the built-in roles alone, as it is for the
    // app (`PersonaStore.load`).
    const bytes: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        aa,
        .limited(PersonaStore.max_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try err_out.print("Polter: could not read the role library at {s} ({t}).\n", .{ path, err });
            return 1;
        },
    };
    const set = if (bytes) |b| persona.parseLeaky(aa, b) catch |err| {
        try err_out.print("Polter: {s} does not read as a role library ({t}).\n", .{ path, err });
        return 1;
    } else persona.builtinSet();
    var p = set.find(parsed.role) orelse {
        try err_out.print("Polter: there is no role called \"{s}\".\n", .{parsed.role});
        return 1;
    };
    // A supervisor role's agent is told it is one (`persona.launchInstructions`).
    p.instructions = try persona.launchInstructions(aa, p);

    // --- which CLI
    const choice: persona.CliChoice = if (parsed.cli) |key|
        p.cli(key) orelse {
            try err_out.print(
                "Polter: the role \"{s}\" is not set up for {s}.\n",
                .{ p.name, key },
            );
            return 1;
        }
    else switch (p.clis.len) {
        1 => p.clis[0],
        0 => {
            try err_out.print(
                "Polter: the role \"{s}\" is not set up for any agent CLI. " ++
                    "Open the role library and pick one.\n",
                .{p.name},
            );
            return 1;
        },
        else => {
            try err_out.print(
                "Polter: the role \"{s}\" is set up for more than one CLI; say which:\n",
                .{p.name},
            );
            for (p.clis) |c| try err_out.print("    polter +launch {s} {s}\n", .{ p.key, c.cli });
            return 2;
        },
    };

    // --- the adapter
    var env = try global.environMap();
    defer env.deinit();

    const adapters = agent_cli.discover(aa, io, &env);
    const adapter = agent_cli.find(adapters, choice.cli) orelse {
        try whyNoAdapter(aa, io, &env, choice.cli, err_out);
        return 1;
    };

    const cwd = std.process.currentPathAlloc(io, aa) catch null;
    var request: std.Io.Writer.Allocating = .init(aa);
    try agent_cli.writeLaunchRequest(&request.writer, p, choice, cwd, env.get("HOME") orelse env.get("USERPROFILE"));

    const answer = switch (try agent_cli.ask(aa, io, &env, adapter, .launch, request.written())) {
        .ok => |json| json,
        .failed => |why| {
            try err_out.print("Polter: {s} could not build the command: {s}\n", .{ adapter.label, why });
            return 1;
        },
    };
    const launch = agent_cli.parseLaunch(aa, answer) catch {
        try err_out.print("Polter: {s} answered without a command to run.\n", .{adapter.label});
        return 1;
    };

    // One line before the CLI takes the screen, so that what this terminal
    // is wearing is on it in words, not only in a tab mark.
    try err_out.print("Polter · {s} · {s}", .{ p.name, adapter.label });
    if (launch.summary) |s| try err_out.print(" — {s}", .{s});
    try err_out.writeAll("\n");
    for (launch.notes) |n| try err_out.print("  {s}\n", .{n});
    try err_out.flush();

    for (launch.env) |kv| try env.put(kv[0], kv[1]);

    if (comptime std.process.can_replace) {
        const err = std.process.replace(io, .{ .argv = launch.argv, .environ_map = &env });
        try err_out.print("Polter: could not start {s} ({t}).", .{ launch.argv[0], err });
        if (err == error.FileNotFound) try err_out.print(" Is {s} installed?", .{adapter.bin});
        try err_out.writeAll("\n");
        return 127;
    }

    // The CLI gets the console the way the person had it: its code page
    // was ours to change for our own lines, not for somebody else's
    // program.
    try err_out.flush();
    console.restore();

    // **Windows has no exec.** So the CLI runs as a child sharing this
    // console -- this process is `polter-cli.exe`, the console build, for
    // exactly that reason (`App.launchPersona`) -- and its exit code is
    // handed back as ours, so the shell sees what it would have seen had
    // the CLI been typed.
    var child = std.process.spawn(io, .{
        .argv = launch.argv,
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try err_out.print("Polter: could not start {s} ({t}).", .{ launch.argv[0], err });
        if (err == error.FileNotFound) try err_out.print(" Is {s} installed?", .{adapter.bin});
        try err_out.writeAll("\n");
        return 127;
    };
    const term = child.wait(io) catch |err| {
        try err_out.print("Polter: lost track of {s} ({t}).\n", .{ launch.argv[0], err });
        return 1;
    };
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// Why `agent_cli.discover` offered no adapter for `key`, in the words the
/// person needs -- which are different for "there is no such plugin" and
/// "the plugin is here, but its adapter cannot run on this system".
///
/// The second used to be said as the first. Measured on the Windows
/// machine: the Claude Code plugin installed and switched on, its adapter a
/// `.py` file this system has nothing to run with, and the message said no
/// plugin was installed -- sending the person to reinstall something that
/// was already there.
///
/// ⚠️ **Only the wording is decided here.** Which adapters exist is
/// `discover`'s answer and nothing below changes it; this walks the same
/// search path (`Plugin.searchPath`, nearest first, first directory for a
/// key wins) only to pick the sentence. If the two walks ever disagree, the
/// cost is a less exact sentence, never a different launch.
fn whyNoAdapter(
    aa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    key: []const u8,
    out: *std.Io.Writer,
) !void {
    for (Plugin.searchPath(aa, io, env)) |base| {
        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '_') continue;
            const path = std.fmt.allocPrint(aa, "{s}/{s}", .{ base, entry.name }) catch continue;
            const manifest = Plugin.load(aa, io, path) catch continue;
            if (!std.mem.eql(u8, manifest.key, key)) continue;
            const cli = manifest.agent_cli orelse continue;

            if (!Plugin.settingsFor(aa, io, env, key).enabled) {
                try out.print(
                    "Polter: the plugin that manages \"{s}\" is installed but switched off.\n",
                    .{key},
                );
                return;
            }
            if (!cli.runnable) {
                const file = std.fs.path.basename(cli.adapter);
                try out.print(
                    "Polter: the plugin that manages \"{s}\" is installed and switched on, " ++
                        "but its adapter {s} cannot run on this system: Polter has no way " ++
                        "to start a {s} file here.\n",
                    .{ key, file, extensionOf(file) },
                );
                return;
            }
        }
    }
    try out.print(
        "Polter: no plugin that manages \"{s}\" is installed and switched on.\n",
        .{key},
    );
}

fn extensionOf(file: []const u8) []const u8 {
    const ext = std.fs.path.extension(file);
    return if (ext.len > 0) ext else file;
}

/// The Windows console's output code page, put to UTF-8 for the lines this
/// prints and put back afterwards.
///
/// **The lines are UTF-8 and the console was not.** On a Chinese Windows
/// the console starts in code page 936, and `Polter · Role · Claude Code —`
/// came out as `Polter 路 … 鈥?`: the `·` and `—` bytes read as GBK.
/// Changing the words to dodge the characters would fix one message and
/// leave the next one to find this again.
///
/// Put back, not left: the console belongs to the shell the person typed
/// into, and the CLI started next inherits it.
///
/// Nothing at all anywhere else -- a POSIX terminal takes the bytes as they
/// are.
const Console = struct {
    saved: u32 = 0,

    const k32 = struct {
        extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
        extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) i32;
    };
    const utf8_code_page: u32 = 65001;

    fn utf8() Console {
        if (comptime builtin.os.tag != .windows) return .{};
        // Zero means there is no console to ask about (output redirected
        // to a file, say), and then there is nothing to change or restore.
        const saved = k32.GetConsoleOutputCP();
        if (saved == 0 or saved == utf8_code_page) return .{};
        if (k32.SetConsoleOutputCP(utf8_code_page) == 0) return .{};
        return .{ .saved = saved };
    }

    /// Safe to call twice: the second puts back the same page again.
    fn restore(self: Console) void {
        if (comptime builtin.os.tag != .windows) return;
        if (self.saved == 0) return;
        _ = k32.SetConsoleOutputCP(self.saved);
    }
};

const Parsed = struct {
    role: []const u8,
    cli: ?[]const u8,
};

/// `<role> [<cli>]` after our own `+launch` token.
///
/// Read by hand for `+mcp-slot`'s reason: the shared iterator drops
/// anything beginning with `+`, and it takes no positionals.
fn parseArgs(aa: Allocator) !Parsed {
    var iter: std.process.Args.Iterator = try .initAllocator(global.args(), aa);
    defer iter.deinit();

    _ = iter.next(); // argv0
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "+launch")) break;
    } else return error.NoRole;

    const role = iter.next() orelse return error.NoRole;
    if (!persona.isValidKey(role)) return error.NoRole;
    const cli: ?[]const u8 = if (iter.next()) |c| try aa.dupe(u8, c) else null;
    return .{ .role = try aa.dupe(u8, role), .cli = cli };
}
