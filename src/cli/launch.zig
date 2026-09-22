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
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const persona = @import("../poltergeist/persona.zig");
const PersonaStore = @import("../poltergeist/PersonaStore.zig");
const agent_cli = @import("../poltergeist/agent_cli.zig");

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
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        aa,
        .limited(PersonaStore.max_bytes),
    ) catch |err| {
        try err_out.print("Polter: could not read the role library at {s} ({t}).\n", .{ path, err });
        return 1;
    };
    const set = persona.parseLeaky(aa, bytes) catch |err| {
        try err_out.print("Polter: {s} does not read as a role library ({t}).\n", .{ path, err });
        return 1;
    };
    const p = set.find(parsed.role) orelse {
        try err_out.print("Polter: there is no role called \"{s}\".\n", .{parsed.role});
        return 1;
    };

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
        try err_out.print(
            "Polter: no plugin that manages \"{s}\" is installed and switched on.\n",
            .{choice.cli},
        );
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
